library(tidyverse)
library(arrow)
library(DBI)
library(RPostgres)

# ==========================================
# 1. Connect to Neon
# ==========================================
message("Connecting to Neon...")
con <- dbConnect(
  RPostgres::Postgres(),
  host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
  dbname   = "neondb",
  user     = "neondb_owner",
  password = trimws(Sys.getenv("NEON_PASSWORD")), 
  port     = 5432,
  sslmode  = "require"
)

# ==========================================
# 2. Load Historical Data
# ==========================================
message("Loading Parquets and Master CSV...")
ds <- open_dataset("data/granular_listings/", format = "parquet")
fullset_lean <- ds %>% collect()

master_target_cards <- read_csv("data/target_cards_with_epids.csv", 
                                col_types = cols(epid = col_character())) %>%
  mutate(version = replace_na(version, ""))

# Safe check: Only add pull_source if it doesn't already exist in your parquets
if (!"pull_source" %in% names(fullset_lean)) {
  fullset_lean$pull_source <- "Historical_Parquet"
}

# ==========================================
# 3. The Schema Migration
# ==========================================
message("Enriching data and aligning to the new schema...")
gold_data <- fullset_lean %>%
  inner_join(master_target_cards, by = "tcgplayer_id") %>%
  mutate(
    language = case_when(
      str_detect(tolower(listing_title), "japanese|jpn|\\bjp\\b") ~ "Japanese",
      str_detect(tolower(listing_title), "chinese|\\bchn\\b|\\bcn\\b") ~ "Chinese",
      str_detect(tolower(listing_title), "french|\\bfr\\b") ~ "French",
      str_detect(tolower(listing_title), "german|\\bger\\b") ~ "German",
      str_detect(tolower(listing_title), "italian|\\bita\\b") ~ "Italian",
      TRUE ~ "English" 
    ),
    cardname = paste(name, version, rarity, sep = " - "),
    folder_name = str_replace_all(set_name, "[ ']", "_")
    
    # Notice: The NA overwrites have been completely removed! 
    # Your real data will now safely pass through.
  ) %>%
  # The strict 16-column order for the new schema
  select(cardname, set_name, folder_name, id, tcgplayer_id, item_id, 
         price_val, is_graded, language, date_pulled, listing_title, 
         seller_name, feedback_pct, feedback_num, posted_date, pull_source)

# ==========================================
# 4. Wipe & Rebuild the Database Table
# ==========================================
message("Wiping the old table from Neon...")

# This explicitly deletes the entire table and its old schema from the database
dbExecute(con, "DROP TABLE IF EXISTS lorcana_active_listings;")

message("Rebuilding Neon table with new schema and historical data...")

# Now we write the fresh table
dbWriteTable(con, "lorcana_active_listings", gold_data)

dbDisconnect(con)
message("Success! Uploaded ", nrow(gold_data), " historical rows to the new schema.")