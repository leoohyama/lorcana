

library(httr)
library(jsonlite)
library(tidyverse)

# --- STEP 1: Get Enchanted IDs from Lorcast (No Quota Cost) ---
message("Finding Enchanted cards via Lorcast...")
lorcast_all_cards <- fromJSON("https://api.lorcast.com/v0/cards")

enchanted_ids <- lorcast_all_cards %>%
  filter(rarity == "Enchanted") %>%
  # JustTCG uses the TCGPlayer ID for its precise lookups
  select(tcgplayer_id, name, set_name = set.name) %>%
  filter(!is.na(tcgplayer_id))

# --- STEP 2: Prepare JustTCG Request ---
api_key <- Sys.getenv("tcg_ed83c7138fff417098cd323bcdaaaa8b")
base_url <- "https://api.justtcg.com/v1/cards"

# We must split our cards into groups of 20 because of JustTCG's free tier limit
card_batches <- split(enchanted_ids$tcgplayer_id, ceiling(seq_along(enchanted_ids$tcgplayer_id)/20))

all_price_data <- list()

# --- STEP 3: Fetch Prices from JustTCG ---
message(paste("Fetching prices for", nrow(enchanted_ids), "cards in", length(card_batches), "batches..."))

for(i in seq_along(card_batches)) {
  # Create the batch payload
  payload <- map(card_batches[[i]], ~ list(
    tcgplayerId = as.character(.x),
    condition = "Near Mint",
    printing = "Foil" # Enchanted cards only come in foil
  ))
  
  response <- POST(
    url = base_url,
    add_headers(`X-API-Key` = api_key, `Content-Type` = "application/json"),
    body = toJSON(payload, auto_unbox = TRUE)
  )
  
  if(status_code(response) == 200) {
    batch_data <- fromJSON(content(response, "text"), flatten = TRUE)$data
    all_price_data[[i]] <- as_tibble(batch_data) %>% unnest(variants)
  } else {
    warning(paste("Batch", i, "failed with status", status_code(response)))
  }
  
  # Optional: Add a small sleep to avoid hitting rate limits too fast
  Sys.sleep(0.5)
}

# --- STEP 4: Finalize and Save ---
final_enchanted_prices <- bind_rows(all_price_data) %>%
  select(id, name, set, price, lastUpdated) %>%
  mutate(pull_date = Sys.Date())

save_path <- "data/running_data"
if (!dir.exists(save_path)) dir.create(save_path, recursive = TRUE)

file_name <- file.path(save_path, paste0("enchanted_prices_", Sys.Date(), ".csv"))
write_csv(final_enchanted_prices, file_name)

message(paste("Successfully saved", nrow(final_enchanted_prices), "prices to", file_name))

api_key <- Sys.getenv("tcg_ed83c7138fff417098cd323bcdaaaa8b")

# 1. Get the list of Lorcana Sets (so we can loop through them)
sets_response <- GET(
  "https://api.justtcg.com/v1/sets",
  add_headers(`X-API-Key` = api_key),
  query = list(game = "lorcana")
)
all_sets <- fromJSON(content(sets_response, "text"))$data

list_of_all_cards <- list()

# 2. Loop through each set
for(set_id in all_sets$id) {
  
  # JustTCG uses 'limit' and 'offset' for pages. 
  # We'll start at 0 and keep going until we get no more cards.
  current_offset <- 0
  has_more_cards <- TRUE
  
  while(has_more_cards) {
    card_res <- GET(
      "https://api.justtcg.com/v1/cards",
      add_headers(`X-API-Key` = api_key),
      query = list(
        game = "lorcana",
        set = set_id,
        limit = 20,          # How many per 'page'
        offset = current_offset
      )
    )
    
    data_chunk <- fromJSON(content(card_res, "text"), flatten = TRUE)$data
    
    if (length(data_chunk) == 0) {
      has_more_cards <- FALSE
    } else {
      list_of_all_cards[[length(list_of_all_cards) + 1]] <- data_chunk
      current_offset <- current_offset + 20
    }
  }
}

# 3. Combine and Save
final_df <- bind_rows(list_of_all_cards) %>%
  mutate(pull_date = Sys.Date())

write_csv(final_df, paste0("data/running_data/justtcg_bulk_", Sys.Date(), ".csv"))