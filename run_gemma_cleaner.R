library(tidyverse)
library(jsonlite)
library(httr)
library(DBI)
library(duckdb)

# ==========================================
# 1. THE GEMMA JSON FUNCTION (SEQUENTIAL)
# ==========================================
ask_gemma_json <- function(target_card, ebay_title) {
  prompt_text <- paste0(
    "You are a strict data extraction assistant for Disney Lorcana TCG. ",
    "Your primary job is to identify and filter out standard versions of cards that sellers are mislabeling with high-value terms like 'Iconic', 'Enchanted', 'Epic'.\n\n",
    "RULES:\n",
    "1. 'validity': Output 'Match' or 'No Match'.\n",
    "2. THE COLLECTOR NUMBER MATCH (CRITICAL): The Target Card string ends with a specific collector number. Inspect the eBay Title for any isolated card numbers or fractional identifiers (e.g., '191/204'). If the eBay title explicitly contains a DIFFERENT card number than the target number, you MUST output 'No Match'. NOTE: A fractional format in the title like '242/204' is an EXACT match for a target number of '242'.\n",
    "3. OMITTED NUMBERS: If the title omits any card number but matches the exact character name and subtitle, it can be a 'Match'.\n",
    "4. 'is_graded': true or false.\n",
    "5. 'grading_company': Extract ('PSA', 'BGS', 'Beckett', 'CGC', 'SGC', 'PCG', 'ACE', 'TAG'). Output 'NA' if ungraded.\n",
    "6. 'grade_value': Extract numeric grade. Output 'NA' if ungraded.\n\n",
    "Target Card: ", target_card, "\n",
    "eBay Title: ", ebay_title, "\n",
    "JSON Output:"
  )
  
  res <- tryCatch({
    POST(
      url = "http://localhost:11434/api/generate",
      body = list(
        model = "gemma4:e2b", 
        prompt = prompt_text,
        stream = FALSE,
        format = "json",
        options = list(temperature = 0.0) 
      ),
      encode = "json",
      timeout(10) 
    )
  }, error = function(e) return(NULL))
  
  fallback <- list(validity="ERROR", is_graded=FALSE, grading_company="NA", grade_value="NA")
  
  if (!is.null(res) && status_code(res) == 200) {
    unpacked <- tryCatch({
      raw_text <- content(res, "text", encoding = "UTF-8")
      parsed <- fromJSON(raw_text)
      fromJSON(parsed$response)
    }, error = function(e) return(fallback))
    return(unpacked)
  } else {
    return(fallback)
  }
}

# ==========================================
# 2. DICTIONARY & DB SETUP
# ==========================================
print("📂 Loading local master dictionary...")
master_dict <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  mutate(
    id = as.character(id), 
    target_num = as.character(collector_number),
    cardname = paste(name, replace_na(version, ""), rarity, collector_number, sep = " - ")
  ) %>%
  select(id, cardname, target_num) %>%
  distinct(id, .keep_all = TRUE)

print("🚀 Connecting to MotherDuck...")
md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
Sys.setenv(motherduck_token = md_token)
con <- dbConnect(duckdb::duckdb())
dbExecute(con, "INSTALL motherduck; LOAD motherduck; ATTACH 'md:'; USE my_db;")

create_table_query <- "
  CREATE TABLE IF NOT EXISTS llm_listing_metadata (
    item_id VARCHAR PRIMARY KEY,
    id VARCHAR,
    is_valid BOOLEAN,
    is_graded BOOLEAN,
    grading_company VARCHAR,
    grade_val VARCHAR,
    card_language VARCHAR
  );
"
dbExecute(con, create_table_query)

# ==========================================
# 3. THE FULL RERUN TOGGLE
# ==========================================
force_full_rerun <- FALSE

if(force_full_rerun) {
  print("⚠️ WARNING: Truncating table for a full LLM rerun over all data...")
  dbExecute(con, "TRUNCATE TABLE llm_listing_metadata;")
}

# ==========================================
# 4. FETCH & PRE-FILTER QUEUE (THE SHORT-CIRCUIT)
# ==========================================
print("📥 Fetching processing queue...")
query <- "
  SELECT DISTINCT a.item_id, a.id, a.listing_title 
  FROM lorcana_active_listings a
  LEFT JOIN llm_listing_metadata m ON a.item_id = m.item_id
  WHERE m.item_id IS NULL
"
processing_queue <- dbGetQuery(con, query)

if(nrow(processing_queue) == 0) {
  dbDisconnect(con, shutdown = TRUE)
  stop("✅ All unique listings checked. No new data to process. Exiting gracefully.", call. = FALSE)
}

# Join dictionary and clean text patterns
processing_queue <- processing_queue %>%
  left_join(master_dict, by = "id") %>%
  drop_na(cardname, listing_title) %>%
  mutate(
    title_lower = str_to_lower(listing_title),
    # Language labeling logic
    card_language = case_when(
      str_detect(title_lower, "\\b(jap|japanese|jp|jpn|ja)\\b") ~ "Japanese",
      str_detect(title_lower, "\\b(german|deutsch|de)\\b")      ~ "German",
      str_detect(title_lower, "\\b(french|français|francais|fr)\\b") ~ "French",
      str_detect(title_lower, "\\b(italian|italiano|it)\\b")     ~ "Italian",
      str_detect(title_lower, "\\b(spanish|español|espanol|es)\\b") ~ "Spanish",
      str_detect(title_lower, "\\b(chinese|china|cn)\\b") ~ "Chinese",
      TRUE ~ "English"
    ),
    # INSTANT FAIL FILTER: Flag titles containing forbidden words (including legendary and promo)
    has_forbidden_words = str_detect(title_lower, "\\b(legendary|promo|proxy|custom|oversized|jumbo|championship|cold foil|keychain)\\b")
  )

# Separate clear deterministic mismatches from ambiguous ones needing the LLM
print("⚡ Splitting dataset via deterministic regex short-circuit...")
deterministic_mismatches <- processing_queue %>%
  filter(has_forbidden_words) %>%
  mutate(
    is_valid = FALSE,
    is_graded = FALSE,
    grading_company = NA_character_,
    grade_val = NA_character_
  ) %>%
  select(item_id, id, is_valid, is_graded, grading_company, grade_val, card_language)

llm_queue <- processing_queue %>%
  filter(!has_forbidden_words)

print(sprintf("📉 Pre-filtered out %d rows natively. Processing Remaining %d rows via LLM sequentially...", 
              nrow(deterministic_mismatches), nrow(llm_queue)))

# ==========================================
# 5. SEQUENTIAL LLM PROCESSING
# ==========================================
llm_results_list <- list()

if(nrow(llm_queue) > 0) {
  print("🧠 Running sequential LLM processing...")
  
  for (i in 1:nrow(llm_queue)) {
    cat(sprintf("\rProcessing %d of %d...", i, nrow(llm_queue)))
    
    res <- ask_gemma_json(llm_queue$cardname[i], llm_queue$listing_title[i])
    
    is_valid_flag <- ifelse(res$validity == "Match", TRUE, FALSE)
    is_graded_flag <- as.logical(res$is_graded)
    comp_val <- ifelse(res$grading_company %in% c("NA", "ERROR") || is.na(res$grading_company), NA_character_, res$grading_company)
    g_val <- ifelse(res$grade_value %in% c("NA", "ERROR") || is.na(res$grade_value), NA_character_, as.character(res$grade_value))
    
    if (is.na(comp_val) || trimws(comp_val) == "") {
      is_graded_flag <- FALSE
      comp_val <- NA_character_
      g_val <- NA_character_
    }
    if(!is.na(comp_val) && toupper(comp_val) == "BECKETT") comp_val <- "BGS"
    
    llm_results_list[[i]] <- tibble(
      item_id = llm_queue$item_id[i],
      id = llm_queue$id[i],
      is_valid = is_valid_flag,
      is_graded = is_graded_flag,
      grading_company = comp_val,
      grade_val = g_val,
      card_language = llm_queue$card_language[i]
    )
  }
  cat("\n") 
  llm_results <- bind_rows(llm_results_list)
  final_payload <- bind_rows(deterministic_mismatches, llm_results)
} else {
  final_payload <- deterministic_mismatches
}

# ==========================================
# 6. CHUNKED BULK DB WRITE (No Row-by-Row Latency)
# ==========================================
if(nrow(final_payload) > 0) {
  print("💾 Committing payloads to MotherDuck in a single chunk...")
  
  # Delete conflicting IDs in a single batch query
  item_id_list <- paste0("'", final_payload$item_id, "'", collapse = ",")
  dbExecute(con, sprintf("DELETE FROM llm_listing_metadata WHERE item_id IN (%s)", item_id_list))
  
  # Bulk append dataframe using DuckDB's optimized appender stream
  dbWriteTable(con, "llm_listing_metadata", final_payload, append = TRUE)
}

print("✨ Pipeline complete! Database sync complete.")
dbDisconnect(con, shutdown = TRUE)