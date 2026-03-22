library(tidyverse)

# ==========================================
# 1. Load the Data
# ==========================================
ebayfile_path <- "data/granular_listings/"
filenames <- list.files(ebayfile_path, pattern = "\\.csv$", full.names = TRUE)

# Map and Bind in one swoop (No loops or rbinds needed!)
fullset <- map_dfr(filenames, read_csv)



# ==========================================
# 2. Clean and Flag
# ==========================================
fullset <- fullset %>%
  mutate(
    language = case_when(
      str_detect(tolower(listing_title), "japanese|jpn|\\bjp\\b") ~ "Japanese",
      str_detect(tolower(listing_title), "chinese|\\bchn\\b|\\bcn\\b") ~ "Chinese",
      str_detect(tolower(listing_title), "french|\\bfr\\b") ~ "French",
      str_detect(tolower(listing_title), "german|\\bger\\b") ~ "German",
      str_detect(tolower(listing_title), "italian|\\bita\\b") ~ "Italian",
      TRUE ~ "English" 
    ),
    # Create a clean display name for the dashboard
    cardname = paste(name, version, rarity, sep = " - "),
    
    # --- UPGRADED: Catch spaces AND apostrophes ---
    folder_name = str_replace_all(set_name, "[ ']", "_")
  )


# ==========================================
# 3. Aggregate for the Dashboard (The Daily Dive)
# ==========================================
daily_dive <- fullset %>%
  # Group by Date first, then the card dimensions
  group_by(date_pulled, set_name, id, cardname, tcgplayer_id, language, is_graded) %>%
  summarise(
    active_listings = n(),
    
    # Calculate daily pricing metrics inside the summarise!
    # Using 5th percentile to automatically slice off the fake/proxy cards
    true_floor_price = quantile(price_val, probs = 0.05, na.rm = TRUE),
    avg_ask_price    = mean(price_val, na.rm = TRUE),
    max_ask_price    = max(price_val, na.rm = TRUE),
    
    .groups = "drop" # This ungroups the data so it doesn't cause issues later
  ) %>%
  arrange(date_pulled, cardname)


# ==========================================
# 4. Save the Dashboard Feed
# ==========================================
# Save this lightweight, aggregated file specifically for your Shiny app to read
dir.create("data/shiny_prep", recursive = TRUE, showWarnings = FALSE)
write_rds(daily_dive, "data/shiny_prep/daily_summary.rds")

message("Data prep complete. Ready for Shiny!")
