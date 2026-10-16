library(tidyverse)
library(jsonlite)
library(httr)
library(DBI)
library(duckdb)

# ==========================================
# 1. THE GEMMA JSON FUNCTION (SEQUENTIAL)
# ==========================================
# Grading is pure pattern-matching, so regex does it instead of the model: it is
# exact, free, and removes the model's worst failure mode (reading the 10 in
# "PSA 10" as card number 10 and rejecting a valid listing). The model is left
# with the one judgement call — does this listing match this printing.
GRADE_RX <- regex("(psa|bgs|beckett|cgc|sgc|pcg|ace|tag)\\s*#?\\s*([0-9]+(?:\\.[0-9])?)",
                  ignore_case = TRUE)

extract_grading <- function(ebay_title) {
  m <- str_match(ebay_title, GRADE_RX)
  if (is.na(m[1, 1])) {
    return(list(is_graded = FALSE, grading_company = "NA", grade_value = "NA"))
  }
  comp <- toupper(m[1, 2])
  if (comp == "BECKETT") comp <- "BGS"
  list(is_graded = TRUE, grading_company = comp, grade_value = m[1, 3])
}

ask_gemma_json <- function(target_card, ebay_title) {
  grading <- extract_grading(ebay_title)

  # Strip grading scores before the model sees the title, so no grade can be
  # mistaken for a collector number.
  clean_title <- str_squish(str_remove_all(ebay_title, GRADE_RX))

  prompt_text <- paste0(
    "You are a strict data extraction assistant for Disney Lorcana TCG.\n",
    "Decide if an eBay listing is the SAME printing as the Target Card.\n",
    "The Target Card string ends with its collector number.\n\n",
    "DECISION PROCEDURE for 'validity' - follow in order:\n",
    "STEP 1. Find any card number in the eBay Title (forms: '205', '025/204', '19/204').\n",
    "STEP 2. If NO card number appears in the title: output 'Match' as long as the character name and subtitle match the target. A missing number is NOT a reason to reject. This is common and valid.\n",
    "STEP 3. If a card number IS present: compare it to the target number, ignoring leading zeros and any '/204' denominator. Equal -> 'Match'. Different -> 'No Match'.\n",
    "STEP 4. If the character name or subtitle is a different card entirely -> 'No Match'.\n\n",
    "EXAMPLES:\n",
    "Target: Aurora - Delightful Musician - Enchanted - 223 | Title: 'Disney Lorcana Aurora - Delightful Musician ENCHANTED NM' -> Match (no number present)\n",
    "Target: Aurora - Delightful Musician - Enchanted - 223 | Title: 'Disney Lorcana - Hyperia City - Aurora - Delightful Musician ENCHANTED NM' -> Match (set name is not a card number)\n",
    "Target: Aurora - Delightful Musician - Enchanted - 223 | Title: 'Aurora - Delightful Musician 19/204 Nm' -> No Match (19 != 223)\n",
    "Target: Aurora - Delightful Musician - Enchanted - 223 | Title: 'Aurora Delightful Musician 223/204' -> Match (223 == 223)\n\n",
    "Target Card: ", target_card, "\n",
    "eBay Title: ", clean_title, "\n",
    "JSON Output:"
  )

  # Constrained decoding pins the key, so the model cannot invent one and make
  # parsing silently fail (without it, it emitted {"Match": "Match"}).
  response_schema <- list(
    type = "object",
    properties = list(
      validity = list(type = "string", enum = c("Match", "No Match"))
    ),
    required = c("validity")
  )

  res <- tryCatch({
    POST(
      url = "http://localhost:11434/api/generate",
      body = list(
        model = "gemma4:e2b",
        prompt = prompt_text,
        stream = FALSE,
        format = response_schema,
        # gemma4:e2b is a thinking model and its reasoning was ~94% of every
        # response (609 generated tokens for a ~40-token answer), then thrown
        # away unread. Disabling it is the bulk of the ~13x speed-up.
        think = FALSE,
        options = list(temperature = 0.0)
      ),
      encode = "json",
      timeout(30)
    )
  }, error = function(e) return(NULL))

  fallback <- list(validity = "ERROR", is_graded = FALSE,
                   grading_company = "NA", grade_value = "NA")

  if (!is.null(res) && status_code(res) == 200) {
    validity <- tryCatch({
      fromJSON(fromJSON(content(res, "text", encoding = "UTF-8"))$response)$validity
    }, error = function(e) NULL)
    if (is.null(validity)) return(fallback)
    return(c(list(validity = validity), grading))
  }
  fallback
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

# Explicit install/load/attach — the "md:" dbdir shortcut silently creates a
# LOCAL file literally named "md:my_db" when the duckdb package can't autoload
# the motherduck extension, making this script see an empty database and exit.
con <- dbConnect(duckdb::duckdb())
dbExecute(con, "INSTALL motherduck;")
dbExecute(con, "LOAD motherduck;")
dbExecute(con, "ATTACH 'md:my_db' AS my_db;")
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
force_full_rerun <- FALSE

if(force_full_rerun) {
  print("⚠️ WARNING: Truncating table for a full LLM rerun over all data...")
  dbExecute(con, "TRUNCATE TABLE llm_listing_metadata;")
}

# ==========================================
# 4. FETCH & PRE-FILTER QUEUE (THE SHORT-CIRCUIT)
# ==========================================
print("📥 Fetching processing queue...")

# SAFEGUARD: Ensure the upstream scraper has actually created the table
if (!dbExistsTable(con, "lorcana_active_listings")) {
  message("⚠️ Table 'lorcana_active_listings' not found. The upstream eBay scraper needs to populate it first. Exiting gracefully.")
  dbDisconnect(con, shutdown = TRUE)
  quit(save = "no", status = 0)
}

query <- "
  SELECT DISTINCT a.item_id, a.id, a.listing_title 
  FROM lorcana_active_listings a
  LEFT JOIN llm_listing_metadata m ON a.item_id = m.item_id
  WHERE m.item_id IS NULL
"
processing_queue <- dbGetQuery(con, query)

if(nrow(processing_queue) == 0) {
  # stop() exits 1, which marks the whole workflow failed on a day when there is
  # simply nothing new to clean. Exit 0 like the missing-table guard above.
  message("✅ All unique listings checked. No new data to process. Exiting gracefully.")
  dbDisconnect(con, shutdown = TRUE)
  quit(save = "no", status = 0)
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
    has_forbidden_words = str_detect(title_lower, "\\b(legendary|promo|proxy|custom|oversized|jumbo|championship|cold foil|keychain|artwork)\\b")
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

# ==========================================
# --- 4b. REUSE PRIOR VERDICTS FOR REPEAT LISTINGS ---
# ==========================================
# 40-60% of each day's "new" item_ids are relists of a title this pipeline has
# already judged. The verdict depends on the (target card, title) PAIR, not the
# title alone — 2,449 titles in the table map to 2+ different target cards — so
# the pair is the cache key. card_language is still recomputed per row above.
prior_verdicts <- dbGetQuery(con, "
  SELECT DISTINCT ON (a.id, a.listing_title)
         a.id, a.listing_title, m.is_valid, m.is_graded, m.grading_company, m.grade_val
  FROM lorcana_active_listings a
  JOIN llm_listing_metadata m ON a.item_id = m.item_id
  ORDER BY a.id, a.listing_title, m.item_id
")

cached_hits <- llm_queue %>%
  inner_join(prior_verdicts, by = c("id", "listing_title")) %>%
  select(item_id, id, is_valid, is_graded, grading_company, grade_val, card_language)

llm_queue <- llm_queue %>%
  anti_join(prior_verdicts, by = c("id", "listing_title"))

print(sprintf("📉 Pre-filtered %d rows natively, %d reused from prior verdicts. Processing remaining %d rows via LLM sequentially...",
              nrow(deterministic_mismatches), nrow(cached_hits), nrow(llm_queue)))

# ==========================================
# 5. SEQUENTIAL LLM PROCESSING (INCREMENTAL COMMITS)
# ==========================================

# Flush helper: delete conflicting item_ids then bulk-append the batch. Called
# incrementally during the loop so an interrupted run keeps its progress instead
# of losing hours of sequential LLM work on a large queue.
flush_payload <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(invisible(0))
  item_id_list <- paste0("'", df$item_id, "'", collapse = ",")
  dbExecute(con, sprintf("DELETE FROM llm_listing_metadata WHERE item_id IN (%s)", item_id_list))
  dbWriteTable(con, "llm_listing_metadata", df, append = TRUE)
  invisible(nrow(df))
}

# Commit the deterministic regex rejects and cache hits up front — no LLM needed
flush_payload(deterministic_mismatches)
flush_payload(cached_hits)

total_written <- nrow(deterministic_mismatches) + nrow(cached_hits)
n_errors <- 0
FLUSH_EVERY <- 250
llm_results_list <- list()

if(nrow(llm_queue) > 0) {
  print("🧠 Running sequential LLM processing...")

  for (i in 1:nrow(llm_queue)) {
    cat(sprintf("\rProcessing %d of %d...", i, nrow(llm_queue)))

    res <- ask_gemma_json(llm_queue$cardname[i], llm_queue$listing_title[i])

    # SKIP on ERROR: an unreachable / timed-out Ollama must NOT be recorded as
    # is_valid = FALSE (that permanently blacklists good listings). Leaving the
    # item unwritten keeps it in the queue so it is retried on the next run.
    if (is.null(res$validity) || identical(res$validity, "ERROR")) {
      n_errors <- n_errors + 1
      # Abort early if literally every call so far has failed — Ollama is down.
      if (n_errors >= 25 && n_errors == i) {
        flush_payload(bind_rows(llm_results_list))
        dbDisconnect(con, shutdown = TRUE)
        stop("🛑 First 25 LLM calls all failed — is Ollama running? Aborting; unprocessed items will be retried next run.")
      }
      next
    }

    is_valid_flag <- isTRUE(res$validity == "Match")
    is_graded_flag <- isTRUE(as.logical(res$is_graded))
    # Coerce possibly-missing LLM JSON fields to length-1 strings before testing
    comp_raw <- if (is.null(res$grading_company)) NA_character_ else as.character(res$grading_company)[1]
    g_raw <- if (is.null(res$grade_value)) NA_character_ else as.character(res$grade_value)[1]
    comp_val <- ifelse(is.na(comp_raw) || comp_raw %in% c("NA", "ERROR"), NA_character_, comp_raw)
    g_val <- ifelse(is.na(g_raw) || g_raw %in% c("NA", "ERROR"), NA_character_, g_raw)

    if (is.na(comp_val) || trimws(comp_val) == "") {
      is_graded_flag <- FALSE
      comp_val <- NA_character_
      g_val <- NA_character_
    }
    if(!is.na(comp_val) && toupper(comp_val) == "BECKETT") comp_val <- "BGS"

    llm_results_list[[length(llm_results_list) + 1]] <- tibble(
      item_id = llm_queue$item_id[i],
      id = llm_queue$id[i],
      is_valid = is_valid_flag,
      is_graded = is_graded_flag,
      grading_company = comp_val,
      grade_val = g_val,
      card_language = llm_queue$card_language[i]
    )

    # Periodic incremental commit
    if (length(llm_results_list) >= FLUSH_EVERY) {
      total_written <- total_written + flush_payload(bind_rows(llm_results_list))
      llm_results_list <- list()
    }
  }
  cat("\n")
}

# ==========================================
# 6. FINAL FLUSH & SUMMARY
# ==========================================
total_written <- total_written + flush_payload(bind_rows(llm_results_list))

print(sprintf("✨ Pipeline complete! %d rows written, %d LLM errors skipped (left in queue for next run).", total_written, n_errors))
dbDisconnect(con, shutdown = TRUE)
