library(tidyverse)
library(jsonlite)
library(httr)


# Lorcast has a bulk-style endpoint that includes prices
lorcast_url <- "https://api.lorcast.com/v0/sets"
raw_data <- fromJSON(lorcast_url)

#get unique ids for every set
set_ids<-raw_data$results %>%
  select(id, name)

#create empty list
list_of_data = list()

#now loop over unique set ids to get all cards
for(i in 1:nrow(set_ids)){
  lorcast_set_url  <- paste0("https://api.lorcast.com/v0/sets/", set_ids$id[i], "/cards")
  raw_data <- fromJSON(lorcast_set_url)
  
  # 1. Flatten the 'type' list into a character vector
  # This converts list("Action", "Song") -> "Action Song"
  type_flat <- map_chr(raw_data$type, ~ paste(.x, collapse = " "))
  type_inks <- map_chr(raw_data$inks, ~ paste(.x, collapse = " "))

  
  image_urls <- raw_data$image_uris$digital$normal
  price_list_nonfoil <- raw_data$prices$usd
  price_list_foil <- raw_data$prices$usd_foil
  setname <-raw_data$set$name
  
  # 2. Add the flattened type to your data
  combined_data <- cbind(raw_data, 
                          setname,
                         type_clean = type_flat, 
                         type_inks = type_inks,
                         price_list_nonfoil, 
                         price_list_foil, 
                         
                         image_urls)
  
  list_of_data[[i]] <- combined_data %>%
    select(-c('prices', 'image_uris', 'type')) # Drop the original list 'type'
}

final_df <- bind_rows(list_of_data)%>% mutate(type_inks = case_when(
  type_inks == "" ~ NA,
  type_inks == "NA" ~ NA,
  is.na(type_inks) ~ NA,
  type_inks == ink ~ NA,
  TRUE ~ type_inks
)) %>%
  mutate(ink = ifelse(!is.na(type_inks),type_inks, ink )) %>%
  relocate(type_inks, .after = inks) 

#now we download images


# 1. Create a root folder for all images
root_dir <- "lorcana_images"
if (!dir.exists(root_dir)) dir.create(root_dir)

# 2. Function to download and organize by [Set Name] -> [ID].avif
download_organized_images <- function(url, set_name, card_id) {
  
  # Clean up the set name so it's a valid folder name (removes special chars)
  safe_set_name <- str_replace_all(set_name, "[^[:alnum:]]", "_")
  set_path <- file.path(root_dir, safe_set_name)
  
  # Create the set folder if it doesn't exist yet
  if (!dir.exists(set_path)) {
    dir.create(set_path, recursive = TRUE)
  }
  
  # Define the final file path
  # We use the .avif extension since that's what the Lorcast URLs use
  dest_file <- file.path(set_path, paste0(card_id, ".avif"))
  
  # Download only if the file doesn't already exist (skips duplicates)
  if (!file.exists(dest_file)) {
    tryCatch({
      download.file(url, dest_file, mode = "wb", quiet = TRUE)
    }, error = function(e) {
      message(paste("Error downloading ID:", card_id, "from set:", set_name))
    })
  }
}

# 3. Increase timeout for long downloads
options(timeout = max(1000, getOption("timeout")))

# 4. Run the download
# This assumes your columns are named 'image_urls', 'name' (for set), and 'id'
# Adjust names if your final_df uses something else!
pwalk(list(
  final_df$image_urls, 
  final_df$setname, 
  final_df$id
), download_organized_images)



# 1. Recreate the path logic to see what SHOULD be there
# We use the same 'safe_set_name' logic we used in the download function
final_df_checked <- final_df %>%
  mutate(
    safe_set_name = str_replace_all(setname, "[^[:alnum:]]", "_"),
    expected_path = file.path("lorcana_images", safe_set_name, paste0(id, ".avif")),
    # Check if the file actually exists on your computer
    download_successful = file.exists(expected_path)
  )

# 2. Extract the failures into a separate tibble
failed_downloads <- final_df_checked %>%
  filter(!download_successful)

# 3. Clean your training data (Keep only the ones that actually downloaded)
clean_training_df <- final_df_checked %>%
  filter(download_successful)

# Summary
print(paste("Successful downloads:", nrow(clean_training_df)))
print(paste("Failed downloads:", nrow(failed_downloads)))

# Look at the failures to see why they broke
head(failed_downloads)

#remove the failed downloads from the final dataset

final_df_save=final_df %>%
  filter_out(id %in% failed_downloads$id)

saveRDS(final_df, file = "data/tabular/final_data.rds")

final=read.csv("lorcana_test_predictions.csv")
dput(final)
