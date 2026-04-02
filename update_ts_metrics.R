# ==========================================
# TIME SERIES METRICS ETL PIPELINE
# ==========================================
library(DBI)
library(RPostgres)
library(tidyverse)
library(pracma)  # For Sample Entropy and Hurst
library(moments) # For Skewness

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
df_prices <- dbGetQuery(con, "
    SELECT tcgplayer_id, market_price, pull_date 
    FROM justtcg_prices 
    WHERE market_price IS NOT NULL
    ORDER BY tcgplayer_id, pull_date ASC
")

# --- 4. CALCULATE & ROUND METRICS ---
message("Crunching advanced time-series metrics...")

metrics_df <- df_prices %>%
  group_by(tcgplayer_id) %>%
  filter(n() >= 10) %>% # Require at least 10 days of history
  summarise(
    n_days        = n(),
    # Round prices to 2 decimals
    current_price = round(last(market_price), 2),
    avg_price     = round(mean(market_price, na.rm = TRUE), 2),
    
    # Round ML metrics to 4 decimals
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

# --- 5. UPLOAD TO NEON ---
message("Uploading results to Neon table: 'card_ts_metrics'...")

dbWriteTable(con, "card_ts_metrics", metrics_df, overwrite = TRUE, row.names = FALSE)

tryCatch({
  dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_metrics_tcgid ON card_ts_metrics(tcgplayer_id)")
}, error = function(e) message("Index already exists or couldn't be created."))

dbDisconnect(con)

message("Pipeline complete! Metrics successfully updated and rounded in the database.")