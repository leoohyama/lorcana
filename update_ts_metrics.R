# ==========================================
# TIME SERIES METRICS ETL PIPELINE (30-DAY WINDOW)
# ==========================================
library(DBI)
library(RPostgres)
library(tidyverse)
library(pracma)  # For Sample Entropy and Hurst
library(moments) # For Skewness
library(glue)    # Added for pooler-safe SQL construction
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

# --- 2. CONNECT TO NEON ---
message("Connecting to Neon Database...")
con <- dbConnect(RPostgres::Postgres(),
                 host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
                 dbname   = "neondb", 
                 user     = "neondb_owner",
                 password = Sys.getenv("NEON_PASSWORD"), 
                 port     = 5432, 
                 sslmode  = "require")

# --- 3. FETCH HISTORICAL DATA ---
message("Downloading JustTCG price history...")
# Added immediate = TRUE
df_prices <- dbGetQuery(con, "
    SELECT tcgplayer_id, market_price, pull_date 
    FROM justtcg_prices 
    WHERE market_price IS NOT NULL
    ORDER BY tcgplayer_id, pull_date ASC
", immediate = TRUE)
<<<<<<< HEAD
=======

# Ensure dates are correctly formatted
df_prices$pull_date <- as.Date(df_prices$pull_date)
current_date <- Sys.Date()
thirty_days_ago <- current_date - days(30)
>>>>>>> 9cd02adce334c1eb73bb3a7fa5a56cae4398101f

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
  # Clean up the list column before upload
  select(-price_30d) %>%
  mutate(
    last_updated = current_date # Tag the run date
  )

# --- 5. UPLOAD TO NEON (POOLER-SAFE UPSERT) ---
message("Uploading results to Neon table: 'card_ts_metrics'...")

# 5a. Drop the old table schema to avoid column mismatch errors
dbExecute(con, "DROP TABLE IF EXISTS card_ts_metrics;", immediate = TRUE)

# 5b. Create the table explicitly with the new 30-day schema
dbExecute(con, "
  CREATE TABLE card_ts_metrics (
    tcgplayer_id VARCHAR PRIMARY KEY,
    lifetime_days INTEGER,
    days_in_30d INTEGER,
    current_price NUMERIC,
    avg_price_30d NUMERIC,
    cv_30d NUMERIC,
    samp_ent_30d NUMERIC,
    hurst_30d NUMERIC,
    lag1_corr_30d NUMERIC,
    skewness_30d NUMERIC,
    last_updated DATE
  );
<<<<<<< HEAD
", immediate = TRUE) # Added immediate = TRUE

# 5b. If the table was previously created by dbWriteTable, it won't have a Primary Key. 
# We try to add it safely so the ON CONFLICT logic works.
tryCatch({
  dbExecute(con, "ALTER TABLE card_ts_metrics ADD PRIMARY KEY (tcgplayer_id);", immediate = TRUE) # Added immediate = TRUE
}, error = function(e) {
  # Safe to ignore; means the PK already exists
})
=======
", immediate = TRUE)
>>>>>>> 9cd02adce334c1eb73bb3a7fa5a56cae4398101f

# 5c. The Pooler-Safe Loop Update
message(paste("Upserting", nrow(metrics_df), "rows securely..."))

for (i in 1:nrow(metrics_df)) {
  row <- metrics_df[i, ]
  
  # Handle NA, NaN, Inf conversions using explicit NA_real_ to prevent boolean typing
  curr_id <- as.character(row$tcgplayer_id)
  curr_lt_days <- as.integer(row$lifetime_days)
  curr_30d_days <- as.integer(row$days_in_30d)
  
  curr_cp <- ifelse(!is.finite(row$current_price), NA_real_, row$current_price)
  curr_avg <- ifelse(!is.finite(row$avg_price_30d), NA_real_, row$avg_price_30d)
  curr_cv <- ifelse(!is.finite(row$cv_30d), NA_real_, row$cv_30d)
  curr_entropy <- ifelse(!is.finite(row$samp_ent_30d), NA_real_, row$samp_ent_30d)
  curr_hurst <- ifelse(!is.finite(row$hurst_30d), NA_real_, row$hurst_30d)
  curr_lag <- ifelse(!is.finite(row$lag1_corr_30d), NA_real_, row$lag1_corr_30d)
  curr_skew <- ifelse(!is.finite(row$skewness_30d), NA_real_, row$skewness_30d)
  
  curr_date <- as.character(row$last_updated)
  
  # Construct the raw text string locally with explicit Postgres ::TYPE casting
  insert_query <- glue::glue_sql("
    INSERT INTO card_ts_metrics (
      tcgplayer_id, lifetime_days, days_in_30d, current_price, avg_price_30d, cv_30d, 
      samp_ent_30d, hurst_30d, lag1_corr_30d, skewness_30d, last_updated
    ) VALUES (
      {curr_id}::VARCHAR, 
      {curr_lt_days}::INTEGER, 
      {curr_30d_days}::INTEGER, 
      {curr_cp}::NUMERIC, 
      {curr_avg}::NUMERIC, 
      {curr_cv}::NUMERIC, 
      {curr_entropy}::NUMERIC, 
      {curr_hurst}::NUMERIC, 
      {curr_lag}::NUMERIC, 
      {curr_skew}::NUMERIC, 
      {curr_date}::DATE
    )
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
  ", .con = con)
  
  # Added immediate = TRUE here as well!
  dbExecute(con, insert_query, immediate = TRUE)
}

dbDisconnect(con)
message("✅ Pipeline complete! 30-Day Metrics successfully updated in the database.")