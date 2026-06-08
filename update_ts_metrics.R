# ==========================================
# TIME SERIES METRICS ETL PIPELINE (30-DAY WINDOW)
# ==========================================
library(DBI)
library(duckdb)
library(tidyverse)
library(pracma)  # For Sample Entropy and Hurst
library(moments) # For Skewness
library(lubridate)

message(paste("Starting Metrics Job at", Sys.time()))

# --- 1. SAFE MATH WRAPPERS ---
safe_entropy <- function(x) {
  if(sd(x, na.rm = TRUE) == 0 || length(x) < 10) return(NA)
  tryCatch(sample_entropy(x, edim = 2, r = 0.2 * sd(x, na.rm = TRUE)), error = function(e) NA)
}

safe_hurst <- function(x) {
  if(sd(x, na.rm = TRUE) == 0 || length(x) < 10) return(NA)
  tryCatch(hurstexp(x, display = FALSE)$Hs, error = function(e) NA)
}

safe_autocorr <- function(x) {
  if(sd(x, na.rm = TRUE) == 0 || length(x) < 3) return(NA)
  tryCatch(cor(x[-1], x[-length(x)], use = "complete.obs"), error = function(e) NA)
}

safe_skewness <- function(x) {
  if(sd(x, na.rm = TRUE) == 0 || length(x) < 10) return(NA)
  tryCatch(skewness(x, na.rm = TRUE), error = function(e) NA)
}

# --- 2. CONNECT TO MOTHERDUCK ---
message("Connecting to MotherDuck...")
md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
if (md_token == "") {
  stop("MotherDuck token is missing! Check your environment configurations.")
}

Sys.setenv(motherduck_token = md_token)
con <- dbConnect(duckdb::duckdb())
dbExecute(con, "INSTALL motherduck; LOAD motherduck;")
dbExecute(con, "ATTACH 'md:'")
dbExecute(con, "USE my_db;")

# --- 3. FETCH HISTORICAL DATA ---
message("Downloading JustTCG price history...")
df_prices <- dbGetQuery(con, "
    SELECT CAST(tcgplayer_id AS VARCHAR) as tcgplayer_id, market_price, pull_date 
    FROM justtcg_prices 
    WHERE market_price IS NOT NULL
    ORDER BY tcgplayer_id, pull_date ASC
")

# Ensure dates are correctly formatted
df_prices$pull_date <- as.Date(df_prices$pull_date)
current_date <- Sys.Date()
thirty_days_ago <- current_date - days(30)

# --- 4. CALCULATE & ROUND METRICS ---
message("Crunching 30-day time-series metrics...")

metrics_df <- df_prices %>%
  group_by(tcgplayer_id) %>%
  filter(n() >= 10) %>% # Require at least 10 days of lifetime history
  summarise(
    # Lifetime Baseline
    lifetime_days = n(),
    current_price = round(last(market_price), 2),
    
    # 30-Day Window Calculations
    price_30d = list(market_price[pull_date >= thirty_days_ago]),
    days_in_30d = length(unlist(price_30d)),
    
    avg_price_30d = round(mean(unlist(price_30d), na.rm = TRUE), 2),
    cv_30d        = round(sd(unlist(price_30d), na.rm = TRUE) / mean(unlist(price_30d), na.rm = TRUE), 4),
    samp_ent_30d  = round(safe_entropy(unlist(price_30d)), 4),
    hurst_30d     = round(safe_hurst(unlist(price_30d)), 4),
    lag1_corr_30d = round(safe_autocorr(unlist(price_30d)), 4),
    skewness_30d  = round(safe_skewness(unlist(price_30d)), 4),
    .groups       = 'drop'
  ) %>%
  select(-price_30d) %>%
  mutate(
    tcgplayer_id = as.character(tcgplayer_id),
    lifetime_days = as.integer(lifetime_days),
    days_in_30d = as.integer(days_in_30d),
    last_updated = current_date
  ) %>%
  # Vectorized Clean: Natively swap NaN/Inf elements to NA before database write
  mutate(across(where(is.numeric), ~ ifelse(is.finite(.), ., NA_real_)))

# --- 5. UPLOAD TO MOTHERDUCK (BATCH STAGING UPSERT) ---
if (nrow(metrics_df) > 0) {
  message("Preparing MotherDuck target tables...")
  
  # Ensure target table exists with primary key constraints intact
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS card_ts_metrics (
      tcgplayer_id VARCHAR PRIMARY KEY,
      lifetime_days INTEGER,
      days_in_30d INTEGER,
      current_price DOUBLE,
      avg_price_30d DOUBLE,
      cv_30d DOUBLE,
      samp_ent_30d DOUBLE,
      hurst_30d DOUBLE,
      lag1_corr_30d DOUBLE,
      skewness_30d DOUBLE,
      last_updated DATE
    );
  ")

  # Write the clean data frame directly into a high-speed local temp staging table
  dbWriteTable(con, "temp_card_ts_metrics", metrics_df, overwrite = TRUE, temporary = TRUE)
  
  # Run a single optimized merge statement in the cloud
  message(paste("Upserting", nrow(metrics_df), "rows via atomic database transaction..."))
  upsert_sql <- "
    INSERT INTO card_ts_metrics (
      tcgplayer_id, lifetime_days, days_in_30d, current_price, avg_price_30d, 
      cv_30d, samp_ent_30d, hurst_30d, lag1_corr_30d, skewness_30d, last_updated
    )
    SELECT 
      tcgplayer_id, lifetime_days, days_in_30d, current_price, avg_price_30d, 
      cv_30d, samp_ent_30d, hurst_30d, lag1_corr_30d, skewness_30d, last_updated
    FROM temp_card_ts_metrics
    ON CONFLICT (tcgplayer_id) DO UPDATE SET 
      lifetime_days = EXCLUDED.lifetime_days,
      days_in_30d = EXCLUDED.days_in_30d,
      current_price = EXCLUDED.current_price,
      avg_price_30d = EXCLUDED.avg_price_30d,
      cv_30d = EXCLUDED.cv_30d,
      samp_ent_30d = EXCLUDED.samp_ent_30d,
      hurst_30d = EXCLUDED.hurst_30d,
      lag1_corr_30d = EXCLUDED.lag1_corr_30d,
      skewness_30d = EXCLUDED.skewness_30d,
      last_updated = EXCLUDED.last_updated;
  "
  dbExecute(con, upsert_sql)
  message("✅ Pipeline complete! 30-Day Metrics successfully updated.")
} else {
  message("No metrics processed. Skipping update step.")
}

dbDisconnect(con, shutdown = TRUE)