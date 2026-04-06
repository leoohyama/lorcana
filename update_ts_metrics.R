# ==========================================
# TIME SERIES METRICS ETL PIPELINE
# ==========================================
library(DBI)
library(RPostgres)
library(tidyverse)
library(pracma)  # For Sample Entropy and Hurst
library(moments) # For Skewness
library(glue)    # Added for pooler-safe SQL construction

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

# --- 4. CALCULATE & ROUND METRICS ---
message("Crunching advanced time-series metrics...")

metrics_df <- df_prices %>%
  group_by(tcgplayer_id) %>%
  filter(n() >= 10) %>% # Require at least 10 days of history
  summarise(
    n_days        = n(),
    current_price = round(last(market_price), 2),
    avg_price     = round(mean(market_price, na.rm = TRUE), 2),
    cv            = round(sd(market_price, na.rm = TRUE) / mean(market_price, na.rm = TRUE), 4),
    samp_entropy  = round(safe_entropy(market_price), 4),
    hurst_exp     = round(safe_hurst(market_price), 4),
    lag1_corr     = round(safe_autocorr(market_price), 4),
    skewness      = round(safe_skewness(market_price), 4),
    .groups       = 'drop'
  ) %>%
  mutate(
    last_updated = Sys.Date() # Tag the run date
  )

# --- 5. UPLOAD TO NEON (POOLER-SAFE UPSERT) ---
message("Uploading results to Neon table: 'card_ts_metrics'...")

# 5a. Create the table explicitly if it doesn't exist to define data types
dbExecute(con, "
  CREATE TABLE IF NOT EXISTS card_ts_metrics (
    tcgplayer_id VARCHAR PRIMARY KEY,
    n_days INTEGER,
    current_price NUMERIC,
    avg_price NUMERIC,
    cv NUMERIC,
    samp_entropy NUMERIC,
    hurst_exp NUMERIC,
    lag1_corr NUMERIC,
    skewness NUMERIC,
    last_updated DATE
  );
", immediate = TRUE) # Added immediate = TRUE

# 5b. If the table was previously created by dbWriteTable, it won't have a Primary Key. 
# We try to add it safely so the ON CONFLICT logic works.
tryCatch({
  dbExecute(con, "ALTER TABLE card_ts_metrics ADD PRIMARY KEY (tcgplayer_id);", immediate = TRUE) # Added immediate = TRUE
}, error = function(e) {
  # Safe to ignore; means the PK already exists
})

# 5c. The Pooler-Safe Loop Update
message(paste("Upserting", nrow(metrics_df), "rows securely..."))

for (i in 1:nrow(metrics_df)) {
  row <- metrics_df[i, ]
  
  # Handle NA conversions for SQL
  curr_id <- as.character(row$tcgplayer_id)
  curr_n_days <- as.integer(row$n_days)
  curr_cp <- ifelse(is.na(row$current_price), NA, row$current_price)
  curr_avg <- ifelse(is.na(row$avg_price), NA, row$avg_price)
  curr_cv <- ifelse(is.na(row$cv), NA, row$cv)
  curr_entropy <- ifelse(is.na(row$samp_entropy), NA, row$samp_entropy)
  curr_hurst <- ifelse(is.na(row$hurst_exp), NA, row$hurst_exp)
  curr_lag <- ifelse(is.na(row$lag1_corr), NA, row$lag1_corr)
  curr_skew <- ifelse(is.na(row$skewness), NA, row$skewness)
  curr_date <- as.character(row$last_updated)
  
  # Construct the raw text string locally
  insert_query <- glue::glue_sql("
    INSERT INTO card_ts_metrics (
      tcgplayer_id, n_days, current_price, avg_price, cv, 
      samp_entropy, hurst_exp, lag1_corr, skewness, last_updated
    ) VALUES (
      {curr_id}, {curr_n_days}, {curr_cp}, {curr_avg}, {curr_cv}, 
      {curr_entropy}, {curr_hurst}, {curr_lag}, {curr_skew}, {curr_date}
    )
    ON CONFLICT (tcgplayer_id) DO UPDATE SET 
      n_days = EXCLUDED.n_days,
      current_price = EXCLUDED.current_price,
      avg_price = EXCLUDED.avg_price,
      cv = EXCLUDED.cv,
      samp_entropy = EXCLUDED.samp_entropy,
      hurst_exp = EXCLUDED.hurst_exp,
      lag1_corr = EXCLUDED.lag1_corr,
      skewness = EXCLUDED.skewness,
      last_updated = EXCLUDED.last_updated;
  ", .con = con)
  
  # Added immediate = TRUE here as well!
  dbExecute(con, insert_query, immediate = TRUE)
}

dbDisconnect(con)
message("✅ Pipeline complete! Metrics successfully updated in the database.")