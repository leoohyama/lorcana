library(tidyverse)
library(arrow) # Required for high-performance Parquet handling

# ==========================================
# 1. Load the Data (The Arrow Way)
# ==========================================
# open_dataset() scans the entire folder. It is incredibly fast because it 
# only "looks" at the files without loading them into RAM yet.
ds <- open_dataset("data/granular_listings/", 
  format = "parquet")

# We collect() to pull the data into your R session for processing.
# This replaces the old map_dfr(list.files...) loop.
fullset_lean <- ds %>% collect()

# Load the Master Reference Table (The Metadata)
# This contains the name, set_name, id, and rarity that we dropped from the daily pulls.
master_target_cards <- read_csv("data/target_cards_with_epids.csv", col_types = cols(epid = col_character())) %>%
  mutate(version = replace_na(version, ""))


# ==========================================
# 2. Join and Enrich
# ==========================================
# We join the lean daily data with our master reference using tcgplayer_id.
# This "re-attaches" the descriptive text to the numbers.
fullset <- fullset_lean %>%
  inner_join(master_target_cards, by = "tcgplayer_id") %>%
  mutate(
    # Language detection (Requires 'listing_title' to be in your scraper's select()!)
    language = case_when(
      str_detect(tolower(listing_title), "japanese|jpn|\\bjp\\b") ~ "Japanese",
      str_detect(tolower(listing_title), "chinese|\\bchn\\b|\\bcn\\b") ~ "Chinese",
      str_detect(tolower(listing_title), "french|\\bfr\\b") ~ "French",
      str_detect(tolower(listing_title), "german|\\bger\\b") ~ "German",
      str_detect(tolower(listing_title), "italian|\\bita\\b") ~ "Italian",
      TRUE ~ "English" 
    ),
    
    # Create the display name for the dashboard
    cardname = paste(name, version, rarity, sep = " - "),
    
    # Format the folder name for your image paths (converts spaces/apostrophes to underscores)
    folder_name = str_replace_all(set_name, "[ ']", "_")
  )


# ==========================================
# 3. Aggregate for the Dashboard (The Daily Dive)
# ==========================================
daily_dive <- fullset %>%
  # We group by everything the Shiny app needs to display or filter
  group_by(
    date_pulled, 
    set_name, 
    folder_name, 
    id, 
    cardname, 
    tcgplayer_id, 
    language, 
    is_graded
  ) %>%
  summarise(
    active_listings = n(),
    
    # Calculate daily pricing metrics
    # 5th percentile helps ignore "proxy" or "fake" outliers at the bottom
    true_floor_price = quantile(price_val, probs = 0.05, na.rm = TRUE),
    avg_ask_price    = mean(price_val, na.rm = TRUE),
    max_ask_price    = max(price_val, na.rm = TRUE),
    
    .groups = "drop" 
  ) %>%
  arrange(desc(date_pulled), cardname)


unique(daily_dive$date_pulled)


# ==========================================
# 4. Save the Dashboard Feed
# ==========================================
# This RDS file is what your Shiny app actually reads. 
# It's tiny, fast, and contains all your historical trends.
dir.create("data/shiny_prep", recursive = TRUE, showWarnings = FALSE)
write_rds(daily_dive, "data/shiny_prep/daily_summary.rds")

message("--- Data Prep Complete ---")
message(paste("Processed", nrow(fullset_lean), "total listings."))
message("Joined metadata and updated 'daily_summary.rds'. Ready for Shiny!")


# ==========================================
# 3b. Aggregate Market-Wide Datasets
# ==========================================
# First, dynamically find the absolute most recent date in your dataset
max_date <- max(fullset$date_pulled, na.rm = TRUE)

# 1. General Market Overview (Float by date, rarity, and graded status)
# Note: I added `name = "total_listings"` so the column isn't just called "n"
listingoverview <- fullset %>%
  count(date_pulled, rarity, is_graded, name = "total_listings") %>%
  ungroup()

# 2. Top 20 Most Listed Cards (Current Float)
top20 <- fullset %>%
  filter(date_pulled == max_date) %>% # <--- Filters for today's data only!
  count(cardname, name = "total_active") %>%
  arrange(desc(total_active)) %>%
  head(20)


# ==========================================
# 4. Save the Dashboard Feeds
# ==========================================
dir.create("data/shiny_prep", recursive = TRUE, showWarnings = FALSE)

# Save your original card-specific data
write_rds(daily_dive, "data/shiny_prep/daily_summary.rds")

# Save the two new market-wide datasets
write_rds(listingoverview, "data/shiny_prep/market_overview.rds")
write_rds(top20, "data/shiny_prep/top20_active.rds")

message("--- Data Prep Complete ---")
message("Saved daily_summary.rds, market_overview.rds, and top20_active.rds!")
