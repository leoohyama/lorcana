library(tidyverse)
library(httr)
library(jsonlite)
library(DBI)
library(RPostgres)

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
    "4. 'is_graded': true or false.\n",
    "5. 'grading_company': Extract company ('PSA', 'BGS', 'CGC', 'SGC', 'PCG'). Output 'NA' if ungraded.\n",
    "6. 'grade_value': Extract the numeric grade (e.g., '10', '9.5'). Output 'NA' if ungraded.\n\n",
    
    "EXAMPLES:\n",
    "Target Card: Alice - Growing Girl - Enchanted - 213\n",
    "eBay Title: 2023 DISNEY LORCANA EN 2-RISE OF THE FLOODBORN #213 ALICE - GROWING GIRL PSA 10\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": true, \"grading_company\": \"PSA\", \"grade_value\": \"10\"}\n\n",
    
    "Target Card: RLS Legacy - Solar Galleon - Enchanted - 216\n",
    "eBay Title: 1x RLS Legacy - Solar Galleon - 216/204 - Enchanted - Holofoil NM-Mint Disney Lorcana\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": false, \"grading_company\": \"NA\", \"grade_value\": \"NA\"}\n\n",
    
    "Target Card: Goofy - Super Goof - Enchanted - 214\n",
    "eBay Title: 2025 DISNEY LORCANA EN 10-ENCHANTED #223 GOOFY - GALUMPHING GUMSHOE PSA 10\n",
    "JSON Output: {\"validity\": \"No Match\", \"is_graded\": true, \"grading_company\": \"PSA\", \"grade_value\": \"10\"}\n\n",
    
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
# 2. DICTIONARY & NEW TABLE SETUP
# ==========================================
print("📂 Loading local master dictionary...")
master_dict <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  mutate(
    id = as.character(id), 
    cardname = paste(name, replace_na(version, ""), rarity, collector_number, sep = " - ")
  ) %>%
  select(id, cardname) %>%
  distinct(id, .keep_all = TRUE)

print("🚀 Connecting to Neon DB...")
con <- dbConnect(
  RPostgres::Postgres(),
  host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
  dbname   = "neondb",
  user     = "neondb_owner",
  password = Sys.getenv("NEON_PASSWORD"),
  port     = 5432,
  sslmode  = "require"
)

# Create the new static metadata table if it doesn't exist.
# item_id is the PRIMARY KEY, ensuring we never duplicate a listing's metadata.
create_table_query <- "
  CREATE TABLE IF NOT EXISTS llm_listing_metadata (
    item_id VARCHAR PRIMARY KEY,
    id VARCHAR,
    is_valid BOOLEAN,
    is_graded BOOLEAN,
    grading_company VARCHAR,
    grade_val VARCHAR
  );
"
dbExecute(con, create_table_query)

# ==========================================
# 3. FETCH UNIQUE ITEM IDs
# ==========================================
print("📥 Fetching unique item_ids missing from the metadata table...")

# This query finds distinct item_ids in your raw data that do NOT exist in the new table yet.
query <- "
  SELECT DISTINCT a.item_id, a.id, a.listing_title 
  FROM lorcana_active_listings a
  LEFT JOIN llm_listing_metadata m ON a.item_id = m.item_id
  WHERE m.item_id IS NULL
"
processing_queue <- dbGetQuery(con, query)

if(nrow(processing_queue) == 0) {
  print("✅ All unique listings have been checked! Exiting.")
  dbDisconnect(con)
  quit()
}

processing_queue <- processing_queue %>%
  left_join(master_dict, by = "id") %>%
  drop_na(cardname, listing_title)

# ==========================================
# 4. EVALUATE & INSERT
# ==========================================
print(paste("🔎 Evaluating", nrow(processing_queue), "unique listings..."))

for (i in 1:nrow(processing_queue)) {
  
  curr_item_id <- processing_queue$item_id[i]
  curr_id <- processing_queue$id[i]
  curr_title <- processing_queue$listing_title[i]
  curr_target <- processing_queue$cardname[i]
  
  cat(sprintf("\rProcessing %d of %d...", i, nrow(processing_queue)))
  
  result_list <- ask_gemma_json(curr_target, curr_title)
  
  is_valid_flag <- ifelse(result_list$validity == "Match", TRUE, FALSE)
  is_graded_flag <- as.logical(result_list$is_graded)
  company_val <- ifelse(result_list$grading_company == "NA" | is.na(result_list$grading_company), NA, result_list$grading_company)
  grade_val <- ifelse(result_list$grade_value == "NA" | is.na(result_list$grade_value), NA, as.character(result_list$grade_value))
  
  # Insert into the new table. If the item_id somehow gets processed twice, DO NOTHING (safeguard).
  # The SQL Fix: Use glue_sql to safely construct the query text locally
  insert_query <- glue::glue_sql("
    INSERT INTO llm_listing_metadata (item_id, id, is_valid, is_graded, grading_company, grade_val)
    VALUES ({curr_item_id}, {curr_id}, {is_valid_flag}, {is_graded_flag}, {company_val}, {grade_val})
    ON CONFLICT (item_id) DO NOTHING;
  ", .con = con)
  
  # Execute the raw text string directly
  dbExecute(con, insert_query)
}

cat("\n✨ Complete! The new llm_listing_metadata table is fully populated.\n")
dbDisconnect(con)