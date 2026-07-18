# ==============================================================================
# SECTION 1: R BACKEND DATA PIPELINE & PRE-FILTERING (Runs Once at Build)
# ==============================================================================

library(tidyverse)
library(jsonlite)
library(httr)
library(DBI)
library(duckdb)

# --- 1.1 Environment Variable & Auth Guard ---
md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
if (md_token == "") {
  stop("MotherDuck token missing! The dashboard cannot fetch current data.")
}

# --- 1.2 Target Roster Dictionary Prep ---
master_dict <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  mutate(
    id = as.character(id), 
    target_num = as.character(collector_number),
    tcgplayer_id = as.integer(tcgplayer_id), 
    cardname = paste(name, replace_na(version, ""), rarity, collector_number, sep = " - "),
    folder_name = str_replace_all(set_name, "[ ']", "_"),
    image_path = paste0("data/enchanteds/images/", folder_name, "/", id, ".avif")
  ) %>%
  distinct(id, .keep_all = TRUE)

# --- 1.3 MotherDuck Engine Attachment ---
Sys.setenv(motherduck_token = md_token)

# Connect to a plain local duckdb session first (no "md:" shortcut)
con <- dbConnect(duckdb::duckdb())

# Explicitly install + load motherduck — don't rely on dbdir="md:..." to autoload it
dbExecute(con, "INSTALL motherduck;")
dbExecute(con, "LOAD motherduck;")
dbExecute(con, "INSTALL icu; LOAD icu;")

# Explicitly attach the MotherDuck database, then switch into it
dbExecute(con, "ATTACH 'md:my_db' AS my_db;")
dbExecute(con, "USE my_db;")

# --- 1.8 Fetch Core Dashboard Data (Latest Production Inferences Only) ---
global_stats <- tryCatch({
  dbGetQuery(con, "
    SELECT 
      (SELECT COUNT(DISTINCT item_id) FROM lorcana_active_listings) as total_ebay_listings,
      (SELECT COUNT(DISTINCT DATE(date_pulled)) FROM lorcana_active_listings) as ebay_days,
      (SELECT COUNT(DISTINCT pull_date) FROM justtcg_prices) as tcg_days,
      (SELECT CAST(MAX(pull_date) AS DATE) FROM justtcg_prices)::VARCHAR as last_updated
  ")
}, error = function(e) data.frame(total_ebay_listings=0, ebay_days=0, tcg_days=0, last_updated=NA_character_))

# --- 1.8.1 Fetch Daily Listing Churn (Past 60 Days) ---
daily_churn <- tryCatch({
  dbGetQuery(con, "
    WITH listing_lifecycle AS (
      SELECT 
        item_id,
        MIN(DATE(date_pulled)) AS first_seen,
        MAX(DATE(date_pulled)) AS last_seen
      FROM lorcana_active_listings
      GROUP BY item_id
    ),
    date_series AS (
      SELECT UNNEST(generate_series(CURRENT_DATE - INTERVAL '7 days', CURRENT_DATE, INTERVAL '1 day'))::DATE AS event_date
    ),
    arrivals AS (
      SELECT first_seen AS event_date, COUNT(*) AS new_listings
      FROM listing_lifecycle
      GROUP BY first_seen
    ),
    departures AS (
      SELECT (last_seen + INTERVAL '1 day')::DATE AS event_date, COUNT(*) AS disappeared_listings
      FROM listing_lifecycle
      GROUP BY last_seen
    )
    SELECT 
      s.event_date::VARCHAR as event_date,
      COALESCE(a.new_listings, 0) AS new_listings,
      COALESCE(d.disappeared_listings, 0) AS disappeared_listings
    FROM date_series s
    LEFT JOIN arrivals a ON s.event_date = a.event_date
    LEFT JOIN departures d ON s.event_date = d.event_date
    ORDER BY s.event_date ASC
  ")
}, error = function(e) data.frame(event_date=character(), new_listings=numeric(), disappeared_listings=numeric()))

latest_prices <- dbGetQuery(con, "SELECT DISTINCT ON (tcgplayer_id) tcgplayer_id, market_price, pull_date FROM justtcg_prices ORDER BY tcgplayer_id, pull_date DESC")
past_prices <- dbGetQuery(con, "SELECT DISTINCT ON (tcgplayer_id) tcgplayer_id, market_price, pull_date FROM justtcg_prices WHERE pull_date <= CURRENT_DATE - INTERVAL '7 days' ORDER BY tcgplayer_id, pull_date DESC")
hist_data <- dbGetQuery(con, "SELECT tcgplayer_id, pull_date, market_price FROM justtcg_prices WHERE pull_date >= CURRENT_DATE - INTERVAL '90 days'")
chronos_pred <- dbGetQuery(con, "SELECT card_id as tcgplayer_id, target_date, pred_price, conf_low, conf_high, run_id FROM chronos_predictions WHERE run_id = (SELECT MAX(run_id) FROM chronos_predictions)")
# NOTE: GRU forecasts are still generated & stored in `gru_predictions`, but are
# no longer surfaced on the front end (removed 2026-07 to avoid the confusing
# opposite-trend line vs. Chronos). Re-add the gru_pred query + forecast_flat
# branch below to restore it.
metrics_df <- tryCatch(dbGetQuery(con, "SELECT tcgplayer_id, samp_ent_30d, hurst_30d, cv_30d, skewness_30d FROM card_ts_metrics"), error = function(e) data.frame())
backtest_metrics <- tryCatch(dbGetQuery(con, "SELECT tcgplayer_id, model, horizon, mdape, naive_mdape, min_err, max_err, sample_size FROM model_backtest_metrics"), error = function(e) data.frame())
buy_signals <- tryCatch(dbGetQuery(con, "SELECT CAST(card_id AS INTEGER) AS tcgplayer_id, p_buy, p_hold, p_sell, call AS signal_call FROM buy_hold_sell_scores WHERE run_date = (SELECT MAX(run_date) FROM buy_hold_sell_scores)"), error = function(e) data.frame())
signal_metrics <- tryCatch(dbGetQuery(con, "SELECT horizon, auc, brier, logloss, avg_confidence, buy_pct, sell_pct, hold_pct, run_date FROM buy_hold_sell_metrics WHERE run_date = (SELECT MAX(run_date) FROM buy_hold_sell_metrics)"), error = function(e) data.frame())

# --- 1.9 Fetch Validated eBay Datasets (Extended Window to 40 Days) ---
# NOTE: auctions are intentionally retained here (no listing_type filter). The
# `is_auction` flag derived from listing_type in OJS EXCLUDES auctions from all
# price/median math while INCLUDING them in listing counts and supply volumes.
raw_ebay_sql <- tryCatch(dbGetQuery(con, "SELECT a.item_id::text AS item_id, a.price_val, a.listing_type, DATE(a.date_pulled) as date_pulled, l.id, l.grading_company, l.grade_val, l.card_language FROM lorcana_active_listings a INNER JOIN llm_listing_metadata l ON a.item_id::text = l.item_id WHERE l.is_valid IS TRUE AND a.price_val > 0 AND a.date_pulled >= CURRENT_DATE - INTERVAL '40 days' AND a.listing_title IS NOT NULL"), error = function(e) data.frame())
raw_ebay_titles <- tryCatch(dbGetQuery(con, "SELECT DISTINCT ON (a.item_id) a.item_id::text AS item_id, a.listing_title FROM lorcana_active_listings a INNER JOIN llm_listing_metadata l ON a.item_id::text = l.item_id WHERE l.is_valid IS TRUE AND a.price_val > 0 AND a.date_pulled >= CURRENT_DATE - INTERVAL '7 days' AND a.listing_title IS NOT NULL"), error = function(e) data.frame())

dbDisconnect(con)

# --- 1.10 Shape Final Structs & Flatten Matrices ---
momentum <- latest_prices %>% inner_join(past_prices, by = "tcgplayer_id", suffix = c("_cur", "_past")) %>% mutate(pct = (market_price_cur - market_price_past)/market_price_past * 100, abs = market_price_cur - market_price_past) %>% left_join(master_dict, by = "tcgplayer_id") %>% drop_na(cardname)
if(nrow(momentum) > 0) {
  movers <- bind_rows(momentum %>% arrange(desc(pct)) %>% slice(1) %>% mutate(Category = "Top % Gainer"), momentum %>% arrange(pct) %>% slice(1) %>% mutate(Category = "Top % Loser"), momentum %>% arrange(desc(abs)) %>% slice(1) %>% mutate(Category = "Top $Gainer"), momentum %>% arrange(abs) %>% slice(1) %>% mutate(Category = "Top$ Loser"))
} else { movers <- data.frame() }

forecast_flat <- chronos_pred %>% mutate(tcgplayer_id = as.integer(tcgplayer_id)) %>% left_join(master_dict, by = "tcgplayer_id") %>% mutate(model = "Chronos") %>% select(cardname, date = target_date, model, price = pred_price, conf_low, conf_high, run_id) %>% mutate(date = as.character(date)) %>% drop_na(cardname)
hist_flat <- hist_data %>% left_join(master_dict, by = "tcgplayer_id") %>% select(cardname, date = pull_date, price = market_price) %>% mutate(date = as.character(date)) %>% drop_na(cardname)
if(nrow(metrics_df) > 0) metrics_df$tcgplayer_id <- as.integer(metrics_df$tcgplayer_id)
unified <- master_dict %>% left_join(latest_prices %>% rename(current_price = market_price), by="tcgplayer_id") %>% left_join(metrics_df, by="tcgplayer_id")
if (nrow(buy_signals) > 0) unified <- unified %>% left_join(buy_signals, by = "tcgplayer_id")

# --- 1.10.1 Anchor gap (hype gauge) ---
# Latest per-card deviation of the eBay ask premium from that card's own norm,
# computed leakage-safe in pipeline/preprocessing/chronos_data_processing.R and
# committed daily as data/chronos_ready_prices.csv. Positive = asks running hot.
anchor_gaps <- tryCatch(
  read_csv("data/chronos_ready_prices.csv", show_col_types = FALSE) %>%
    mutate(tcgplayer_id = as.integer(card_id)) %>%
    group_by(tcgplayer_id) %>% slice_max(date, n = 1, with_ties = FALSE) %>% ungroup() %>%
    select(tcgplayer_id, anchor_gap),
  error = function(e) data.frame())
if (nrow(anchor_gaps) > 0) unified <- unified %>% left_join(anchor_gaps, by = "tcgplayer_id")

if(nrow(raw_ebay_sql) > 0) {
  ebay_master <- raw_ebay_sql %>% mutate(id = as.character(id)) %>% inner_join(master_dict %>% select(id, cardname), by = "id") %>% mutate(grade_val = replace_na(as.character(grade_val), "UNG"), grading_company = replace_na(as.character(grading_company), "UNG"), card_language = replace_na(as.character(card_language), "English"), date_pulled = as.character(date_pulled), price_val = round(as.numeric(price_val), 2), item_id = as.character(item_id), listing_type = replace_na(as.character(listing_type), "")) %>% select(item_id, cardname, date_pulled, price_val, grading_company, grade_val, card_language, listing_type)
} else { ebay_master <- data.frame(item_id=character(), cardname=character(), date_pulled=character(), price_val=numeric(), grading_company=character(), grade_val=character(), card_language=character(), listing_type=character()) }

if(nrow(raw_ebay_titles) > 0) { ebay_title_dict <- raw_ebay_titles %>% mutate(item_id = as.character(item_id), listing_title = replace_na(as.character(listing_title), "Unknown Title")) } else { ebay_title_dict <- data.frame(item_id=character(), listing_title=character()) }
