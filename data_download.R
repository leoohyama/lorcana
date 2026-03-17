library(tidyverse)
library(jsonlite)
library(httr)
library(tidyverse)

#this is historic data as off 3/17/2026
#this will be fed into our models


# --- STEP 3: Fetch Prices from JustTCG ---
api_key <- "tcg_ed83c7138fff417098cd323bcdaaaa8b"
base_url <- "https://api.justtcg.com/v1/cards"
target_cards<-readRDS("data/enchanteds/enchanted_list.rds")


# Split the IDs into batches of 20 (JustTCG free tier limit per request)
card_batches <- split(target_cards$tcgplayer_id, ceiling(seq_along(target_cards$tcgplayer_id)/20))

all_price_data <- list()

message(paste("Fetching prices from JustTCG in", length(card_batches), "batches..."))
for(i in seq_along(card_batches)) {
  # 1. Keep the payload strictly focused on identifying the cards
  payload <- map(card_batches[[i]], ~ list(
    tcgplayerId = as.character(.x),
    condition = "NM"
  ))
  
  # 2. Move the duration and stats rules to the query parameters
  response <- POST(
    url = base_url,
    query = list(
      priceHistoryDuration = "180d",
      include_statistics = "allTime"
    ),
    add_headers(`X-API-Key` = api_key, `Content-Type` = "application/json"),
    body = toJSON(payload, auto_unbox = TRUE)
  )
  
  if(status_code(response) == 200) {
    # Parse the response and unnest the variants to get the price
    batch_data <- fromJSON(content(response, "text"), flatten = TRUE)$data
    if(length(batch_data) > 0) {
      all_price_data[[i]] <- as_tibble(batch_data) %>% unnest(variants, names_sep = "_")
    }
  } else {
    warning(paste("Batch", i, "failed with status", status_code(response)))
  }
  
  # A tiny pause so we don't accidentally get blocked for spamming the server
  Sys.sleep(0.5)
}

# 1. Combine all the batches from your list into one master dataframe
master_df <- bind_rows(all_price_data)
master_df$tcgplayerId
# 2. Create Table A: Card Metadata
# We select the identifiers and drop the heavy list-columns
card_metadata <- master_df %>%
  select(
    card_id = tcgplayerId,                  # The main card ID
    name, 
    set, 
    variant_id = variants_id,      # The specific ID for this finish/condition
    condition = variants_condition, 
    printing = variants_printing
  ) %>%
  distinct() # Ensure we only have one row per card variant

# 3. Create Table B: Price History (Time-Series)
# We keep the IDs so we can join it back to the metadata later, then unnest
price_history_long <- master_df %>%
  select(card_id = tcgplayerId, variant_id = variants_id, variants_priceHistory) %>%
  # This cracks open the list of dataframes into a long format
  unnest(variants_priceHistory) %>%
  # Decode the Unix timestamps and clean up column names
  mutate(
    timestamp = as_datetime(t),
    date = as_date(timestamp),     # Extracts just the YYYY-MM-DD
    price = p
  ) %>%
  # Drop the old 'p' and 't' columns to keep it clean
  select(card_id, variant_id, timestamp, date, price)

# Look at your beautiful new relational data:
print("Card Metadata:")
head(card_metadata)

print("Price History:")
head(price_history_long)
