library(tidyverse)
library(jsonlite)
library(httr)

# --- STEP 1: Setup and Load Target Cards ---
api_key <- "tcg_ed83c7138fff417098cd323bcdaaaa8b"
base_url <- "https://api.justtcg.com/v1/cards"

# Read the target cards you saved from your first script
target_cards <- readRDS("data/enchanteds/enchanted_list.rds")

# Split IDs into batches of 20 to respect the API limits
card_batches <- split(target_cards$tcgplayer_id, ceiling(seq_along(target_cards$tcgplayer_id)/20))
all_price_data <- list()

message(paste("Fetching daily prices from JustTCG in", length(card_batches), "batches..."))

for(i in seq_along(card_batches)) {
  # 1. Keep the payload strictly focused on identifying the cards
  payload <- map(card_batches[[i]], ~ list(
    tcgplayerId = as.character(.x),
    condition = "NM"
  ))
  
  # 2. Send the POST request
  response <- POST(
    url = base_url,
    add_headers(`X-API-Key` = api_key, `Content-Type` = "application/json"),
    body = toJSON(payload, auto_unbox = TRUE)
  )
  
  # 3. Parse the data
  if(status_code(response) == 200) {
    batch_data <- fromJSON(content(response, "text"), flatten = TRUE)$data
    if(length(batch_data) > 0) {
      all_price_data[[i]] <- as_tibble(batch_data) %>% unnest(variants, names_sep = "_")
    }
  } else {
    warning(paste("Batch", i, "failed with status", status_code(response)))
  }
  
  # 4. Smart Rate Limiter
  if (i %% 10 == 0) {
    message(paste("Reached batch", i, "- pausing for 60 seconds to respect API burst limits..."))
    Sys.sleep(60) 
  } else {
    Sys.sleep(3)
  }
}

# --- STEP 3: Clean and Save Data ---
# Select only the specific columns you care about to keep the CSV clean
daily_prices <- bind_rows(all_price_data) %>%
  select(
    card_id = tcgplayerId,
    name,
    set,
    variant_id = variants_id,
    condition = variants_condition,
    current_price = variants_price
  ) %>%
  mutate(pull_date = Sys.Date())

# Save to the running data folder
save_path <- "data/running_data"
if (!dir.exists(save_path)) dir.create(save_path, recursive = TRUE)

file_name <- file.path(save_path, paste0("daily_prices_", Sys.Date(), ".csv"))
write_csv(daily_prices, file_name)

message(paste("Successfully saved daily prices to:", file_name))
