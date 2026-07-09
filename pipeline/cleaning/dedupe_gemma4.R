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
# 2. DOWNLOAD & IDENTIFY DUPES
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

message("📥 Downloading raw eBay identifiers...")
raw_listings <- dbGetQuery(con, "SELECT DISTINCT item_id, id, listing_title FROM lorcana_active_listings")

# VERY IMPORTANT: Disconnect to release DuckDB's memory back to the OS so Ollama can use maximum RAM
dbDisconnect(con, shutdown = TRUE)
message("🔒 Disconnected from MotherDuck to free resources.")

message("🔍 Identifying cross-pollinated listings...")
suspected_dupes <- raw_listings %>%
  group_by(item_id) %>%
  mutate(ndistinctcardid = n_distinct(id)) %>%
  filter(ndistinctcardid > 1) %>% 
  ungroup()

if(nrow(suspected_dupes) == 0) {
  message("✅ No cross-pollinated duplicates found! Database is clean.")
  quit()
}

message(sprintf("⚠️ Found %d listing conflicts to evaluate.", nrow(suspected_dupes)))

# ==========================================
# 3. PREP METADATA & LLM QUEUE
# ==========================================
metadata <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  mutate(
    id = as.character(id),
    card_name = paste(name, replace_na(version, ""), rarity, collector_number, sep = " - ")
  ) %>%
  select(id, card_name)

processing_queue <- suspected_dupes %>%
  mutate(id = as.character(id)) %>%
  left_join(metadata, by = "id") %>%
  drop_na(card_name, listing_title)

evaluations <- processing_queue %>% mutate(is_valid = NA)

# ==========================================
# 4. RUN GEMMA EVALUATIONS
# ==========================================
message(paste("🤖 Asking Gemma to evaluate", nrow(processing_queue), "combinations..."))
message("--------------------------------------------------")

for (i in 1:nrow(processing_queue)) {
  
  curr_title <- processing_queue$listing_title[i]
  curr_target <- processing_queue$card_name[i]
  
  result_list <- ask_gemma_json(curr_target, curr_title)

  # SKIP on ERROR: an unreachable / timed-out Ollama must NOT count as "No Match" —
  # that would DELETE legitimate listings. Leaving is_valid = NA excludes the row
  # from the kill list, and the conflict is re-evaluated on the next run.
  if (is.null(result_list$validity) || identical(result_list$validity, "ERROR")) {
    message(sprintf("[%d/%d] ⚠️ LLM ERROR — skipping (will re-evaluate next run)", i, nrow(processing_queue)))
    message(sprintf("   Target : %s", curr_target))
    message(sprintf("   Listing: %s", curr_title))
    message("--------------------------------------------------")
    next
  }

  is_match <- isTRUE(result_list$validity == "Match")
  evaluations$is_valid[i] <- is_match

  # Action-friendly logging
  eval_status <- ifelse(is_match, "✅ MATCH", "❌ NO MATCH (WILL DELETE)")
  message(sprintf("[%d/%d] %s", i, nrow(processing_queue), eval_status))
  message(sprintf("   Target : %s", curr_target))
  message(sprintf("   Listing: %s", curr_title))
  message("--------------------------------------------------")
}

# ==========================================
# 5. EXECUTE CLOUD DELETIONS
# ==========================================
kill_list <- evaluations %>% filter(is_valid == FALSE)

message("\n==================================================")
message("☠️ EXECUTING LIVE DELETIONS")
message("==================================================")

if(nrow(kill_list) > 0) {
  message(sprintf("Gemma identified %d false matches. Reconnecting to MotherDuck...", nrow(kill_list)))
  
  # RECONNECT with the explicit extension load (see connect_motherduck above)
  con <- connect_motherduck()
  
  for(i in 1:nrow(kill_list)) {
    # Use standard parameterized queries (safer and cleaner than glue_sql)
    dbExecute(
      con,
      "DELETE FROM lorcana_active_listings WHERE item_id = ? AND id = ?",
      params = list(kill_list$item_id[i], kill_list$id[i])
    )
  }
  
  dbDisconnect(con, shutdown = TRUE)
  message("✅ Deletions complete! Database is clean.")
  
} else {
  message("✅ Gemma determined all pairings were somehow valid. No deletions made.")
}
