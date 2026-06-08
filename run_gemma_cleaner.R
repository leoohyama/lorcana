library(tidyverse)
library(httr)
library(jsonlite)
library(DBI)
library(duckdb)

# ==========================================
# 1. THE GEMMA JSON FUNCTION (UPDATED PROMPT)
# ==========================================
ask_gemma_json <- function(target_card, ebay_title) {
  
  prompt_text <- paste0(
    "You are a strict data extraction assistant for Disney Lorcana TCG. ",
    "Analyze the eBay title against the target card name and output ONLY a valid JSON object. Do not include markdown formatting.\n\n",
    "RULES:\n",
    "1. 'validity': 'Match' ONLY if the title represents the Character Name and Subtitle of the target card. 'No Match' if it is a different version/subtitle, proxy, digital code, empty box or if title contains words like playmat, promo, set championship, or play mat.\n",
    "2. COLLECTOR NUMBERS: The target card ends with a number. It is still a 'Match' if the eBay title formats it differently or omits it entirely, as long as the names match.\n",
    "3. 'is_graded': true or false. STRICT RULE: Set to false if the title implies the card *could* be graded but isn't currently (e.g., 'worthy', 'ready', 'candidate', 'potential').\n",
    "4. 'grading_company': Extract company ('PSA', 'BGS', 'Beckett', 'CGC', 'SGC', 'PCG', 'ACE', 'TAG'). Output 'NA' if ungraded.\n",
    "5. 'grade_value': Extract the numeric grade (e.g., '10', '9.5'). STRICT RULE: If no valid grading company is found, you MUST output 'NA'. Do not extract random numbers (like lot sizes) as grades.\n\n",
    
    "EXAMPLES:\n",
    "Target Card: Alice - Growing Girl - Enchanted - 213\n",
    "eBay Title: 2023 DISNEY LORCANA EN 2-RISE OF THE FLOODBORN #213 ALICE - GROWING GIRL PSA 10\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": true, \"grading_company\": \"PSA\", \"grade_value\": \"10\"}\n\n",
    
    "Target Card: Elsa - Spirit of Winter - Enchanted - 207\n",
    "eBay Title: Elsa Spirit of Winter Enchanted PSA 10 Worthy! Pack Fresh\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": false, \"grading_company\": \"NA\", \"grade_value\": \"NA\"}\n\n",
    
    "Target Card: Tinker Bell - Giant Fairy - Enchanted - 215\n",
    "eBay Title: 5x Tinker Bell Giant Fairy Enchanted Lorcana TCG\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": false, \"grading_company\": \"NA\", \"grade_value\": \"NA\"}\n\n",
    
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
      timeout(15) 
    )
  }, error = function(e) return(NULL))
  
  fallback <- list(validity="ERROR", is_graded=NA, grading_company="ERROR", grade_value="ERROR")
  
  if (!is.null(res) && status_code(res) == 200) {
    parsed <- content(res, "parsed")
    unpacked <- tryCatch(
      fromJSON(parsed$response),
      error = function(e) return(fallback)
    )
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
    cardname = paste(name, replace_na(version, ""), rarity, collector_number, sep = " - ")
  ) %>%
  select(id, cardname) %>%
  distinct(id, .keep_all = TRUE)

print("🚀 Connecting to MotherDuck...")
md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
if (md_token == "") {
  stop("MotherDuck token is missing! Check your environment configurations.")
}

Sys.setenv(motherduck_token = md_token)
con <- dbConnect(duckdb::duckdb())
dbExecute(con, "INSTALL motherduck; LOAD motherduck;")
dbExecute(con, "ATTACH 'md:'")
dbExecute(con, "USE my_db;")

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
force_full_rerun <- TRUE

if(force_full_rerun) {
  print("⚠️ WARNING: Truncating table for a full LLM rerun over all data...")
  dbExecute(con, "TRUNCATE TABLE llm_listing_metadata;")
}

# ==========================================
# 4. FETCH UNIQUE ITEM IDs QUEUE
# ==========================================
print("📥 Fetching unique item_ids missing from the metadata table...")
query <- "
  SELECT DISTINCT a.item_id, a.id, a.listing_title 
  FROM lorcana_active_listings a
  LEFT JOIN llm_listing_metadata m ON a.item_id = m.item_id
  WHERE m.item_id IS NULL
"
processing_queue <- dbGetQuery(con, query)

if(nrow(processing_queue) == 0) {
  print("✅ All unique listings have been checked! Exiting.")
  dbDisconnect(con, shutdown = TRUE)
  quit()
}

processing_queue <- processing_queue %>%
  left_join(master_dict, by = "id") %>%
  drop_na(cardname, listing_title)

# ==========================================
# 5. EVALUATE & INSERT (WITH DETERMINISTIC SAFETY)
# ==========================================
print(paste("🔎 Evaluating", nrow(processing_queue), "unique listings..."))

for (i in 1:nrow(processing_queue)) {
  
  curr_item_id <- processing_queue$item_id[i]