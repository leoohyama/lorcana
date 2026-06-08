library(DBI)
library(duckdb)
library(tidyverse)
library(lubridate)

# ==========================================
# 1. CONNECT & PULL FROM MOTHERDUCK
# ==========================================
print("1. Connecting to MotherDuck & Pulling Filtered Data...")

md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
if (md_token == "") {
  stop("MotherDuck token is missing! Check your environment configurations.")
}

Sys.setenv(motherduck_token = md_token)
con <- dbConnect(duckdb::duckdb())

# Load extensions and set the context
dbExecute(con, "INSTALL motherduck; LOAD motherduck;")
dbExecute(con, "INSTALL icu; LOAD icu;")
dbExecute(con, "ATTACH 'md:'")
dbExecute(con, "USE my_db;")

# Pulls daily prices ONLY for cards with >= 90 days of history
daily_prices <- dbGetQuery(con, "
  SELECT 
    tcgplayer_id AS card_id,
    pull_date AS date,
    market_price AS price
  FROM justtcg_prices
  WHERE tcgplayer_id IN (
    SELECT tcgplayer_id
    FROM justtcg_prices
    GROUP BY tcgplayer_id
    HAVING COUNT(DISTINCT pull_date) >= 90
  )
  ORDER BY tcgplayer_id, pull_date
")

# Cleanly shutdown the DuckDB instance
dbDisconnect(con, shutdown = TRUE)

# ==========================================
# 2. STATIC METADATA
# ==========================================
print("2. Loading Static Data & Grabbing Card Names...")
static <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  filter(!str_detect(set_name, "Promo")) 

# We only need the name so we can filter for specific cards in Python
static_names <- static %>%
  mutate(tcgplayer_id = as.character(tcgplayer_id)) %>%
  select(tcgplayer_id, name)

# ==========================================
# 3. FILLING TIME GAPS
# ==========================================
print("3. Cleaning Temporal Data & Filling Gaps...")
temporal_clean <- daily_prices %>%
  mutate(
    date = as.Date(date),
    price = as.numeric(price),
    card_id = as.character(card_id)
  ) %>%
  # Chronos STRICTLY requires continuous sequences without missing dates.
  group_by(card_id) %>%
  # THE GUARDRAIL: Added na.rm = TRUE to prevent crashing on NULL dates
  complete(date = seq.Date(min(date, na.rm = TRUE), max(date, na.rm = TRUE), by = "day")) %>%
  fill(price, .direction = "down") %>%
  ungroup()

# ==========================================
# 4. FINAL MERGE & EXPORT
# ==========================================
print("4. Final Merge...")
df_chronos_ready <- temporal_clean %>%
  left_join(static_names, by = c("card_id" = "tcgplayer_id")) %>%
  drop_na(name) %>%
  arrange(card_id, date)

print("5. Exporting to Python...")
# THE DIRECTORY PROTECTION: Ensure the folder exists before writing
dir.create("data", showWarnings = FALSE, recursive = TRUE)

write_csv(df_chronos_ready, "data/chronos_ready_prices.csv")
print("✨ Export complete. Ready for Chronos.")