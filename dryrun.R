# ==========================================
# GEMMA 4 DEDUPE - DRY RUN / AUDIT MODE
# ==========================================

library(DBI)
library(RPostgres)
library(tidyverse)
library(httr)
library(jsonlite)
library(glue)

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
    "3. IGNORE set names, foil types, and eBay seller jargon (e.g., 'IN HAND', 'US SHIP', 'Pack Fresh') when determining validity.\n",
    
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
message("🔌 Connecting to Neon...")
con <- dbConnect(
  RPostgres::Postgres(),
  host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
  dbname   = "neondb", 
  user     = "neondb_owner",
  password = Sys.getenv("NEON_PASSWORD"), 
  port     = 5432, 
  sslmode  = "require"
)

message("📥 Downloading raw eBay identifiers...")
raw_listings <- dbGetQuery(con, "SELECT DISTINCT item_id, id, listing_title FROM lorcana_active_listings")

message("🔍 Identifying cross-pollinated listings...")
suspected_dupes <- raw_listings %>%
  group_by(item_id) %>%
  mutate(ndistinctcardid = n_distinct(id)) %>%
  filter(ndistinctcardid > 1) %>% 
  ungroup()

if(nrow(suspected_dupes) == 0) {
  message("✅ No cross-pollinated duplicates found! Exiting.")
  dbDisconnect(con)
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
  left_join(metadata, by = "id") %>%
  drop_na(card_name, listing_title)

evaluations <- processing_queue %>% mutate(is_valid = NA)

# ==========================================
# 4. RUN GEMMA EVALUATIONS (GitHub Actions Friendly Logging)
# ==========================================
message(paste("🤖 Asking Gemma to evaluate", nrow(processing_queue), "combinations..."))
message("--------------------------------------------------")

for (i in 1:nrow(processing_queue)) {
  
  curr_title <- processing_queue$listing_title[i]
  curr_target <- processing_queue$card_name[i]
  
  result_list <- ask_gemma_json(curr_target, curr_title)
  is_match <- ifelse(result_list$validity == "Match", TRUE, FALSE)
  evaluations$is_valid[i] <- is_match
  
  # Action-friendly logging: One clear line per evaluation
  eval_status <- ifelse(is_match, "✅ MATCH", "❌ NO MATCH (KILL)")
  message(sprintf("[%d/%d] %s", i, nrow(processing_queue), eval_status))
  message(sprintf("   Target : %s", curr_target))
  message(sprintf("   Listing: %s", curr_title))
  message("--------------------------------------------------")
}

# ==========================================
# 5. DRY RUN AUDIT (No Database Changes)
# ==========================================
kill_list <- evaluations %>% filter(is_valid == FALSE)

message("\n==================================================")
message("☠️ KILL LIST AUDIT (DRY RUN)")
message("==================================================")

if(nrow(kill_list) > 0) {
  message(sprintf("Gemma identified %d false matches that WOULD be deleted.", nrow(kill_list)))
  
  # Print the data frame cleanly to the GitHub Actions log
  print(kill_list %>% select(item_id, card_name, listing_title, is_valid), n = 50)
  
  # Save to CSV for artifact uploading
  write_csv(kill_list, "gemma_kill_list_audit.csv")
  message("\n💾 Saved to 'gemma_kill_list_audit.csv'.")
  message("You can add an 'actions/upload-artifact' step to your workflow to download this file!")
  
} else {
  message("✅ Gemma determined all pairings were somehow valid. Kill list is empty.")
}

dbDisconnect(con)