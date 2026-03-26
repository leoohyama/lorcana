library(tidyverse)
library(jsonlite)
library(httr)
library(DBI)
library(RPostgres)

# ==========================================
# --- STEP 1: Setup and Load Target Cards ---
# ==========================================
# Pulling secrets from the environment for security
api_key   <- trimws(Sys.getenv("JUSTTCG_API_KEY"))
neon_pass <- trimws(Sys.getenv("NEON_PASSWORD"))

if (api_key == "" || neon_pass == "") {
  stop("Missing credentials. Check your .Renviron file or GitHub Secrets.")
}

base_url <- "https://api.justtcg.com/v1/cards"

# Read target cards from the master CSV to ensure consistency across all scripts
target_cards <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  filter(!is.na(tcgplayer_id)) %>%
  distinct(tcgplayer_id)

# Split IDs into batches of 20 to respect the API limits
card_batches <- split(target_cards$tcgplayer_id, ceiling(seq_along(target_cards$tcgplayer_id)/20))
all_price_data <- list()

message(paste("Fetching daily prices from JustTCG in", length(card_batches), "batches..."))

# ==========================================
# --- STEP 2: Execute API Batches ---
# ==========================================
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
    batch_data <- fromJSON(content(response, "text", encoding = "UTF-8"), flatten = TRUE)$data
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

# ==========================================
# --- STEP 3: Clean & Format for Neon ---
# ==========================================
daily_prices_lean <- bind_rows(all_price_data) %>%
  select(
    tcgplayer_id = tcgplayerId,
    market_price = variants_price
  ) %>%
  mutate(
    tcgplayer_id = as.integer(tcgplayer_id),
    market_price = as.numeric(market_price),
    pull_date = Sys.Date()
  ) %>%
  # Safety catch: ensure no duplicates sneak in from the batching process
  distinct(tcgplayer_id, pull_date, .keep_all = TRUE)

# ==========================================
# --- STEP 4: Push to Neon Database ---
# ==========================================
if (nrow(daily_prices_lean) > 0) {
  message("Pushing lean price data to Neon...")
  
  con <- dbConnect(RPostgres::Postgres(),
    host = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
    dbname = "neondb", user = "neondb_owner",
    password = neon_pass, port = 5432, sslmode = "require"
  )

  # 1. Clean out today's data (so you can run the script multiple times without duplicates)
  dbExecute(con, paste0("DELETE FROM justtcg_prices WHERE pull_date = '", Sys.Date(), "';"))
  
  # 2. Add the new lean data to the existing table
  dbWriteTable(con, "justtcg_prices", daily_prices_lean, append = TRUE) 
  
  dbDisconnect(con)
  message("Neon push complete. Added ", nrow(daily_prices_lean), " rows.")
} else {
  message("No price data retrieved. Skipping database push.")
}

# --- STEP 1: Setup and Load Target Cards ---
api_key <- "tcg_ed83c7138fff417098cd323bcdaaaa8b"
base_url <- "https://api.justtcg.com/v1/cards"
