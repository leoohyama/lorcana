library(DBI)
library(RPostgres)
library(tidyverse)
library(lubridate)

<<<<<<< HEAD
# ==========================================
# 1. CONNECT & PULL FROM NEON
# ==========================================
print("1. Connecting to Neon & Pulling Filtered Data...")
=======
print("1. Connecting to Neon Database...")
>>>>>>> 3785309 (commit)
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

<<<<<<< HEAD
# Pulls daily prices ONLY for cards with >= 180 days of history
daily_prices <- dbGetQuery(con, "
=======
print("2. Pulling >= 180-Day Filtered Data...")
# Applying the exact same filter to keep the card universe identical
filtered_history <- dbGetQuery(con, "
>>>>>>> 3785309 (commit)
  SELECT 
    tcgplayer_id AS card_id,
    pull_date AS date,
    market_price AS price
  FROM justtcg_prices
  WHERE tcgplayer_id IN (
    SELECT tcgplayer_id
    FROM justtcg_prices
    GROUP BY tcgplayer_id
    HAVING COUNT(DISTINCT pull_date) >= 180
  )
<<<<<<< HEAD
  ORDER BY tcgplayer_id, pull_date
=======
>>>>>>> 3785309 (commit)
")

dbDisconnect(con)

<<<<<<< HEAD
# ==========================================
# 2. STATIC METADATA
# ==========================================
print("2. Loading Static Data & Grabbing Card Names...")
=======
print("3. Loading Static Data & Filtering Promos...")
>>>>>>> 3785309 (commit)
static <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  filter(!str_detect(set_name, "Promo")) 

# We only need the name so we can filter for specific cards in Python
static_names <- static %>%
  mutate(tcgplayer_id = as.character(tcgplayer_id)) %>%
  select(tcgplayer_id, name)

<<<<<<< HEAD
# ==========================================
# 3. FILLING TIME GAPS
# ==========================================
print("3. Cleaning Temporal Data & Filling Gaps...")
temporal_clean <- daily_prices %>%
=======
print("4. Cleaning Temporal Data & Filling Gaps...")
temporal_clean <- filtered_history %>%
>>>>>>> 3785309 (commit)
  mutate(
    date = as.Date(date),
    price = as.numeric(price),
    card_id = as.character(card_id)
  ) %>%
<<<<<<< HEAD
  # Neon is already 1 price per day, so we skip the summarize(mean) step.
  # However, Chronos STRICTLY requires continuous sequences without missing dates.
=======
  # Chronos strictly requires continuous daily sequences
>>>>>>> 3785309 (commit)
  group_by(card_id) %>%
  complete(date = seq.Date(min(date), max(date), by = "day")) %>%
  fill(price, .direction = "down") %>%
  ungroup()

<<<<<<< HEAD
# ==========================================
# 4. FINAL MERGE & EXPORT
# ==========================================
print("4. Final Merge...")
=======
print("5. Final Merge...")
>>>>>>> 3785309 (commit)
df_chronos_ready <- temporal_clean %>%
  left_join(static_names, by = c("card_id" = "tcgplayer_id")) %>%
  drop_na(name) %>%
  arrange(card_id, date)

<<<<<<< HEAD
print("5. Exporting to Python...")
write_csv(df_chronos_ready, "data/chronos_ready_prices.csv")
print("✨ Export complete. Ready for Chronos.")
=======
print("6. Exporting to Python...")
write_csv(df_chronos_ready, "data/chronos_ready_prices.csv")
print("Export complete. Apples-to-apples comparison ready.")
>>>>>>> 3785309 (commit)
