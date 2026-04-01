library(DBI)
library(RPostgres)
library(tidyverse)
library(lubridate)

# ==========================================
# 1. PULL LIVE DATA FROM NEON (WITH FILTER)
# ==========================================
print("1. Connecting to Neon & Pulling Filtered Data...")
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

# Pulls daily prices ONLY for cards with >= 180 days of history
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
    HAVING COUNT(DISTINCT pull_date) >= 180
  )
  ORDER BY tcgplayer_id, pull_date
")

dbDisconnect(con)

# ==========================================
# 2. FILLING TIME GAPS
# ==========================================
print("2. Filling Temporal Gaps...")
temporal_clean <- daily_prices %>%
  mutate(
    date = as.Date(date),
    price = as.numeric(price),
    card_id = as.character(card_id)
  ) %>%
  # Even though Neon has daily entries, the scraper might have missed a weekend.
  # This guarantees an unbroken sequence for the GRU sliding window.
  group_by(card_id) %>%
  complete(date = seq.Date(min(date), max(date), by = "day")) %>%
  fill(price, .direction = "down") %>%
  ungroup()

# ==========================================
# 3. STATIC METADATA MERGE
# ==========================================
print("3. Cleaning Static Metadata & Merging...")
static <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  filter(!str_detect(set_name, "Promo")) 

static_clean <- static %>%
  mutate(
    tcgplayer_id = as.character(tcgplayer_id),
    released_at = mdy(released_at), 
    inkwell = as.integer(inkwell)   
  ) %>%
  select(tcgplayer_id, name, set_name, rarity, released_at, cost, inkwell, ink_clean)

df_merged <- temporal_clean %>%
  left_join(static_clean, by = c("card_id" = "tcgplayer_id")) %>%
  mutate(
    days_since_release = as.integer(date - released_at),
    days_since_release = if_else(days_since_release < 0, 0L, days_since_release) 
  ) %>%
  drop_na(name)

# ==========================================
# 4. SCALING & ENCODING
# ==========================================
print("4. Scaling and Encoding for Neural Networks...")

# Global min-max function
min_max_scale_global <- function(x) {
  (x - min(x, na.rm = TRUE)) / (max(x, na.rm = TRUE) - min(x, na.rm = TRUE))
}

df_final <- df_merged %>%
  # --- LOCAL SCALING (PER CARD) ---
  group_by(card_id) %>%
  mutate(
    # Save the real dollar bounds so Python can reverse the math later
    card_min_price = min(price, na.rm = TRUE),
    card_max_price = max(price, na.rm = TRUE),
    
    # Scale price locally. If max == min (price never changed), set to 0.5
    price_scaled = if_else(
      card_max_price == card_min_price, 
      0.5, 
      (price - card_min_price) / (card_max_price - card_min_price)
    )
  ) %>%
  ungroup() %>%
  
  # --- GLOBAL SCALING ---
  mutate(
    cost_scaled = min_max_scale_global(cost),
    days_scaled = min_max_scale_global(days_since_release)
  ) %>%
  
  # --- LABEL ENCODING (0-Indexed for PyTorch) ---
  mutate(
    name_idx = as.integer(as.factor(name)) - 1L,
    set_idx = as.integer(as.factor(set_name)) - 1L,
    rarity_idx = as.integer(as.factor(rarity)) - 1L,
    ink_idx = as.integer(as.factor(ink_clean)) - 1L
  ) %>%
  arrange(card_id, date)

# ==========================================
# 5. EXPORT
# ==========================================
print("5. Exporting to Python...")
# Create directory if it doesn't exist to prevent write errors
dir.create("data/pytorch", showWarnings = FALSE, recursive = TRUE)

write_csv(df_final, "data/pytorch/lorcana_pytorch_ready.csv")
print("✨ Export complete. Data is formatted, scaled, and ready for PyTorch.")