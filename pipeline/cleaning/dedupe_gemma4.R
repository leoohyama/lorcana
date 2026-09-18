# ==========================================
# GEMMA 4 DEDUPE - LIVE DELETION MODE (MOTHERDUCK)
# File: dedupe_gemma4.R
# ==========================================

library(DBI)
library(duckdb)
library(tidyverse)
library(httr)
library(jsonlite)

# ==========================================
# 1. THE JSON GEMMA FUNCTION
# ==========================================
ask_gemma_json <- function(target_card, ebay_title) {
  
  prompt_text <- paste0(
    "You are a strict data extraction assistant for Disney Lorcana TCG. ",
    "Analyze the eBay title against the target card name and output ONLY a valid JSON object. Do not include markdown formatting.\n\n",
    "RULES:\n",
    "1. 'validity': 'Match' ONLY if the title represents the Character Name and Subtitle of the target card. 'No Match' if it is a different version/subtitle, proxy, digital code, or empty box.\n",
    "2. COLLECTOR NUMBERS: The target card ends with a number (e.g., '- 213'). It is still a 'Match' if the eBay title formats it differently (e.g., '213/204') or omits the number entirely, as long as the names match.\n",
    "3. IGNORE set names, foil types, and eBay seller jargon (e.g., 'IN HAND', 'PSA','CGC','BGS', 'GRADED','US SHIP', 'Pack Fresh') when determining validity.\n",
    
    "EXAMPLES:\n",
    "Target Card: Alice - Growing Girl - Enchanted - 213\n",
    "eBay Title: 2023 DISNEY LORCANA EN 2-RISE OF THE FLOODBORN #213 ALICE - GROWING GIRL PSA 10\n",
    "JSON Output: {\"validity\": \"Match\"}\n\n",
    
    "Target Card: RLS Legacy - Solar Galleon - Enchanted - 216\n",
    "eBay Title: 1x RLS Legacy - Solar Galleon - 216/204 - Enchanted - Holofoil NM-Mint Disney Lorcana\n",
    "JSON Output: {\"validity\": \"Match\"}\n\n",
    
    "Target Card: Goofy - Super Goof - Enchanted - 214\n",
    "eBay Title: 2025 DISNEY LORCANA EN 10-ENCHANTED #223 GOOFY - GALUMPHING GUMSHOE PSA 10\n",
    "JSON Output: {\"validity\": \"No Match\"}\n\n",
    
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
  
  fallback <- list(validity="ERROR")
  
  if (!is.null(res) && status_code(res) == 200) {
    parsed <- content(res, "parsed")
    unpacked <- tryCatch(fromJSON(parsed$response), error = function(e) return(fallback))
    return(unpacked)
  } else {
    return(fallback)
  }
}

# ==========================================
# 2. CONNECT & PREPARE THE VERDICT LEDGER
# ==========================================
message("🔌 Connecting to MotherDuck...")
md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
if (md_token == "") {
  stop("MotherDuck token is missing! Check your environment configurations.")
}

Sys.setenv(motherduck_token = md_token)

# Explicit install/load/attach — the "md:" dbdir shortcut silently creates a
# LOCAL file literally named "md:my_db" when the duckdb package can't autoload
# the motherduck extension, making this script see an empty database and exit.
connect_motherduck <- function() {
  con <- dbConnect(duckdb::duckdb())
  dbExecute(con, "INSTALL motherduck;")
  dbExecute(con, "LOAD motherduck;")
  dbExecute(con, "ATTACH 'md:my_db' AS my_db;")
  dbExecute(con, "USE my_db;")
  con
}

con <- connect_motherduck()

# SAFEGUARD: Ensure the upstream scraper has actually created the table
if (!dbExistsTable(con, "lorcana_active_listings")) {
  message("⚠️ Table 'lorcana_active_listings' not found. The upstream scraper needs to populate it first. Exiting gracefully.")
  dbDisconnect(con, shutdown = TRUE)
  quit(save = "no", status = 0)
}

# PERSISTENT VERDICT LEDGER. Without this every (item_id, id) conflict Gemma has
# ever approved stays conflicted in the table forever and gets re-asked on every
# single run — the queue grows monotonically and never drains.
dbExecute(con, "
  CREATE TABLE IF NOT EXISTS llm_dedupe_verdicts (
    item_id VARCHAR,
    id VARCHAR,
    is_valid BOOLEAN,
    evaluated_on DATE,
    PRIMARY KEY (item_id, id)
  );
")

# ==========================================
# 3. RE-APPLY KNOWN REJECTIONS (NO LLM)
# ==========================================
# The scraper re-inserts a fresh snapshot every day, so pairs deleted yesterday
# reappear this morning. Re-killing them from the ledger is pure SQL — it must
# never cost another Gemma call.
n_repurged <- dbExecute(con, "
  DELETE FROM lorcana_active_listings t
  WHERE EXISTS (
    SELECT 1 FROM llm_dedupe_verdicts v
    WHERE v.item_id = t.item_id AND v.id = t.id AND v.is_valid = FALSE
  );
")
message(sprintf("♻️ Re-purged %d resurrected rows from previously rejected pairs.", n_repurged))

# ==========================================
# 4. BUILD THE INCREMENTAL QUEUE
# ==========================================
# Scoped to the newest scrape day: a conflict on a listing that stopped being
# returned by eBay months ago is dead weight, and re-judging it changes nothing.
# Anti-joined against the ledger so each pair is judged exactly once.
message("🔍 Identifying new cross-pollinated listings...")
processing_queue <- dbGetQuery(con, "
  WITH live AS (
    SELECT DISTINCT item_id, id, listing_title
    FROM lorcana_active_listings
    WHERE date_pulled = (SELECT max(date_pulled) FROM lorcana_active_listings)
  ),
  conflicted AS (
    SELECT item_id FROM live GROUP BY item_id HAVING count(DISTINCT id) > 1
  )
  SELECT l.item_id, l.id, l.listing_title
  FROM live l
  JOIN conflicted c ON l.item_id = c.item_id
  LEFT JOIN llm_dedupe_verdicts v
    ON v.item_id = l.item_id AND v.id = l.id
  WHERE v.item_id IS NULL
")

if (nrow(processing_queue) == 0) {
  message("✅ No unjudged cross-pollinated duplicates found! Database is clean.")
  dbDisconnect(con, shutdown = TRUE)
  quit(save = "no", status = 0)
}

message(sprintf("⚠️ Found %d new listing conflicts to evaluate.", nrow(processing_queue)))

metadata <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  mutate(
    id = as.character(id),
    card_name = paste(name, replace_na(version, ""), rarity, collector_number, sep = " - ")
  ) %>%
  select(id, card_name)

processing_queue <- processing_queue %>%
  mutate(item_id = as.character(item_id), id = as.character(id)) %>%
  left_join(metadata, by = "id") %>%
  drop_na(card_name, listing_title)

if (nrow(processing_queue) == 0) {
  message("✅ No conflicts left after joining the card dictionary.")
  dbDisconnect(con, shutdown = TRUE)
  quit(save = "no", status = 0)
}

# VERY IMPORTANT: Disconnect to release DuckDB's memory back to the OS so Ollama
# can use maximum RAM. The flush helper reconnects only for the brief writes.
dbDisconnect(con, shutdown = TRUE)
message("🔒 Disconnected from MotherDuck to free resources for Ollama.")

# ==========================================
# 5. RUN GEMMA EVALUATIONS (INCREMENTAL COMMITS)
# ==========================================
# Record the verdict AND action it in the same transaction window, every
# FLUSH_EVERY rows, so an interrupted run keeps its progress instead of
# re-asking Gemma for the same pairs tomorrow.
flush_verdicts <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(invisible(0))
  con <- connect_motherduck()
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # Composite-key upsert. Both statements run entirely cloud-side (no local temp
  # table joined against a MotherDuck table), matching the pattern the cleaner uses.
  pair_keys <- paste0("'", df$item_id, "|", df$id, "'", collapse = ",")
  dbExecute(con, sprintf(
    "DELETE FROM llm_dedupe_verdicts WHERE (item_id || '|' || id) IN (%s)", pair_keys))
  dbWriteTable(con, "llm_dedupe_verdicts", df, append = TRUE)

  # Action the rejections. Idempotent and ledger-driven, so it also re-kills
  # anything the scraper resurrected mid-run.
  n_del <- dbExecute(con, "
    DELETE FROM lorcana_active_listings t
    WHERE EXISTS (
      SELECT 1 FROM llm_dedupe_verdicts v
      WHERE v.item_id = t.item_id AND v.id = t.id AND v.is_valid = FALSE
    );
  ")
  message(sprintf("💾 Committed %d verdicts (%d listing rows deleted).", nrow(df), n_del))
  invisible(nrow(df))
}

message(paste("🤖 Asking Gemma to evaluate", nrow(processing_queue), "combinations..."))
message("--------------------------------------------------")

FLUSH_EVERY <- 250
pending <- list()
n_judged <- 0
n_errors <- 0
today <- Sys.Date()

for (i in 1:nrow(processing_queue)) {

  curr_title  <- processing_queue$listing_title[i]
  curr_target <- processing_queue$card_name[i]

  result_list <- ask_gemma_json(curr_target, curr_title)

  # SKIP on ERROR: an unreachable / timed-out Ollama must NOT count as "No Match" —
  # that would DELETE legitimate listings. Writing no verdict leaves the pair in
  # the queue so it is re-evaluated on the next run.
  if (is.null(result_list$validity) || identical(result_list$validity, "ERROR")) {
    n_errors <- n_errors + 1
    message(sprintf("[%d/%d] ⚠️ LLM ERROR — skipping (will re-evaluate next run)", i, nrow(processing_queue)))
    message(sprintf("   Target : %s", curr_target))
    message(sprintf("   Listing: %s", curr_title))
    message("--------------------------------------------------")

    # Abort early if literally every call so far has failed — Ollama is down.
    if (n_errors >= 25 && n_errors == i) {
      flush_verdicts(bind_rows(pending))
      stop("🛑 First 25 LLM calls all failed — is Ollama running? Aborting; unjudged pairs will be retried next run.")
    }
    next
  }

  is_match <- isTRUE(result_list$validity == "Match")

  pending[[length(pending) + 1]] <- tibble(
    item_id      = processing_queue$item_id[i],
    id           = processing_queue$id[i],
    is_valid     = is_match,
    evaluated_on = today
  )

  # Action-friendly logging
  eval_status <- ifelse(is_match, "✅ MATCH", "❌ NO MATCH (WILL DELETE)")
  message(sprintf("[%d/%d] %s", i, nrow(processing_queue), eval_status))
  message(sprintf("   Target : %s", curr_target))
  message(sprintf("   Listing: %s", curr_title))
  message("--------------------------------------------------")

  if (length(pending) >= FLUSH_EVERY) {
    n_judged <- n_judged + flush_verdicts(bind_rows(pending))
    pending <- list()
  }
}

# ==========================================
# 6. FINAL FLUSH & SUMMARY
# ==========================================
n_judged <- n_judged + flush_verdicts(bind_rows(pending))

message("\n==================================================")
message(sprintf("✨ Dedupe complete! %d pairs judged and recorded, %d LLM errors left in queue.",
                n_judged, n_errors))
message("==================================================")
