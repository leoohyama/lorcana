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

# eBay market structure (same aggregation as buy_hold_sell_multinom.R): valid,
# ungraded, English, fixed-price listings; per-day IQR-fenced ask median plus
# listing counts for churn/flow covariates. Sparse before 2026-03-25 -- Chronos-2
# tolerates NaN covariates, so we leave gaps as NA rather than inventing values.
ebay_daily <- dbGetQuery(con, "
  WITH v AS (
    SELECT l.id AS ebay_id, a.item_id, DATE(a.date_pulled) AS d, a.price_val AS px, a.listing_type
    FROM lorcana_active_listings a JOIN llm_listing_metadata l ON a.item_id = l.item_id
    WHERE l.is_valid AND l.is_graded IS FALSE AND l.card_language = 'English' AND a.price_val > 0),
  life    AS (SELECT ebay_id, item_id, MIN(d) fs, MAX(d) ls FROM v GROUP BY 1, 2),
  active  AS (SELECT ebay_id, d, COUNT(DISTINCT item_id) active FROM v GROUP BY 1, 2),
  newl    AS (SELECT ebay_id, fs AS d, COUNT(*) n_new FROM life GROUP BY 1, 2),
  reml    AS (SELECT ebay_id, ls AS d, COUNT(*) n_rem FROM life GROUP BY 1, 2),
  vp      AS (SELECT ebay_id, d, px FROM v WHERE listing_type NOT LIKE '%AUCTION%'),
  bounds  AS (SELECT ebay_id, d, COUNT(*) n, quantile_cont(px,0.25) q1, quantile_cont(px,0.75) q3
              FROM vp GROUP BY 1, 2),
  fenced  AS (SELECT vp.ebay_id, vp.d, vp.px FROM vp JOIN bounds b ON vp.ebay_id=b.ebay_id AND vp.d=b.d
              WHERE b.n >= 3 AND vp.px BETWEEN b.q1-1.5*(b.q3-b.q1) AND b.q3+1.5*(b.q3-b.q1)),
  med     AS (SELECT ebay_id, d, median(px) ebay_median FROM fenced GROUP BY 1, 2),
  maxd    AS (SELECT MAX(d) m FROM v)
  SELECT active.ebay_id, active.d AS date, active.active,
         COALESCE(newl.n_new, 0) AS n_new,
         CASE WHEN active.d < (SELECT m FROM maxd) THEN COALESCE(reml.n_rem, 0) END AS n_rem,
         med.ebay_median
  FROM active
  LEFT JOIN newl ON active.ebay_id=newl.ebay_id AND active.d=newl.d
  LEFT JOIN reml ON active.ebay_id=reml.ebay_id AND active.d=reml.d
  LEFT JOIN med  ON active.ebay_id=med.ebay_id  AND active.d=med.d")

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

# Map eBay aggregates onto TCG card ids
ebay_daily <- ebay_daily %>%
  mutate(ebay_id = as.character(ebay_id), date = as_date(date)) %>%
  inner_join(static %>% transmute(ebay_id = as.character(id),
                                  card_id = as.character(tcgplayer_id)),
             by = "ebay_id") %>%
  transmute(card_id, date, active, ebay_median,
            churn_rate = if_else(active > 0 & !is.na(n_rem), pmin(n_rem / active, 1), NA_real_),
            net_flow   = if_else(active > 0 & !is.na(n_rem), (n_new - n_rem) / active, NA_real_))

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
print("4. Final Merge + eBay covariates...")
# Covariates for Chronos-2 (all leakage-safe, known as of each date):
#   anchor_gap : log(eBay ask median / TCG price) minus the card's own expanding
#                mean of that premium -- the validated correction signal
#   log_active / churn_rate / net_flow : supply-demand structure of the listing queue
# All are NA before eBay coverage begins (2026-03-25); Chronos-2 handles NaN.
df_chronos_ready <- temporal_clean %>%
  left_join(static_names, by = c("card_id" = "tcgplayer_id")) %>%
  drop_na(name) %>%
  left_join(ebay_daily, by = c("card_id", "date")) %>%
  group_by(card_id) %>%
  arrange(date, .by_group = TRUE) %>%
  mutate(
    log_active = log1p(active),
    ebay_prem  = log(ebay_median / price)
  ) %>%
  fill(ebay_prem, .direction = "down") %>%
  mutate(
    anchor_gap = {
      n_seen   <- cumsum(!is.na(ebay_prem))
      run_mean <- cumsum(replace_na(ebay_prem, 0)) / pmax(n_seen, 1)
      if_else(n_seen > 0, ebay_prem - run_mean, NA_real_)
    }
  ) %>%
  ungroup() %>%
  select(card_id, date, price, name, anchor_gap, log_active, churn_rate, net_flow) %>%
  arrange(card_id, date)

print("5. Exporting to Python...")
# THE DIRECTORY PROTECTION: Ensure the folder exists before writing
dir.create("data", showWarnings = FALSE, recursive = TRUE)

write_csv(df_chronos_ready, "data/chronos_ready_prices.csv")
print("✨ Export complete. Ready for Chronos.")