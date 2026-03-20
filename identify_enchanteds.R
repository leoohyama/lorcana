library(tidyverse)
library(jsonlite)
library(httr)

# --- STEP 1: Loop through sets via Lorcast ---
message("Fetching sets and cards from Lorcast...")

lorcast_url <- "https://api.lorcast.com/v0/sets"
raw_data <- fromJSON(lorcast_url)

set_ids <- raw_data$results %>% select(id, name)
list_of_data <- list()

for(i in 1:nrow(set_ids)){
  lorcast_set_url <- paste0("https://api.lorcast.com/v0/sets/", set_ids$id[i], "/cards")
  raw_set_data <- fromJSON(lorcast_set_url)
  
  list_of_data[[i]] <- as_tibble(raw_set_data)
}

all_lorcast_cards <- bind_rows(list_of_data)


# --- STEP 2: Filter and Extract Image Data ---
message("Filtering for Enchanted and Iconic cards...")
all_lorcast_cards$purchase_uris
target_cards <- all_lorcast_cards %>%
  filter(rarity %in% c("Enchanted", "Iconic", "Epic")) %>%
  mutate(
    image_url = image_uris$digital$normal,
    set_name = set$name,
    
    # 1. Flatten the 'inks' list column into a single string separated by a space
    ink_flat = map_chr(inks, ~ paste(.x, collapse = " ")),
    
    # 2. Handle edge cases (turn empty strings into NA)
    ink_flat = na_if(ink_flat, ""),
    
    # 3. Coalesce: Use 'ink_flat' if it exists, otherwise fall back to the basic 'ink' column
    ink_clean = coalesce(ink_flat, ink)
  ) %>%
  # Make sure to select your newly created 'ink_clean' column here!
  select(id, tcgplayer_id, name, version, set_name, rarity,released_at, cost, inkwell, ink_clean, image_url) %>%
  filter(!is.na(tcgplayer_id))

# Save the target list for your Price Tracking script
saveRDS(target_cards, "data/enchanteds/enchanted_list.rds")


# --- STEP 3: The Image Download Pipeline ---
message("Starting image downloads...")

# 1. Create a root folder for these specific images
root_dir <- "data/enchanteds/images"
if (!dir.exists(root_dir)) dir.create(root_dir, recursive = TRUE)

# 2. Recreate your download function
download_organized_images <- function(url, set_name, card_id) {
  # Skip if there's somehow no URL
  if (is.na(url)) return() 
  
  # Clean up the set name for safe folder creation
  safe_set_name <- str_replace_all(set_name, "[^[:alnum:]]", "_")
  set_path <- file.path(root_dir, safe_set_name)
  
  if (!dir.exists(set_path)) dir.create(set_path, recursive = TRUE)
  
  # Use the Lorcast ID for the filename just like before
  dest_file <- file.path(set_path, paste0(card_id, ".avif"))
  
  # Download only if the file doesn't already exist
  if (!file.exists(dest_file)) {
    tryCatch({
      download.file(url, dest_file, mode = "wb", quiet = TRUE)
    }, error = function(e) {
      message(paste("Error downloading ID:", card_id, "from set:", set_name))
    })
  }
}

# 3. Increase timeout for safety
options(timeout = max(1000, getOption("timeout")))

# 4. Execute the loop over your filtered target_cards
pwalk(list(
  target_cards$image_url, 
  target_cards$set_name, 
  target_cards$id
), download_organized_images)

message("Pipeline complete! Images and metadata are saved.")