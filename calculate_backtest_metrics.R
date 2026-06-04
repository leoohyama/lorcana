# ==============================================================
# calculate_backtest_metrics.R
# Calculates 30-day forecast errors and uploads to Neon
# ==============================================================
library(tidyverse)
library(DBI)
library(RPostgres)

message("Connecting to Neon...")
con <- dbConnect(RPostgres::Postgres(), 
                 host = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech", 
                 dbname = "neondb", 
                 user = "neondb_owner", 
                 password = Sys.getenv("NEON_PASSWORD"), 
                 port = 5432, sslmode = "require")

message("Fetching historical actuals...")
# We fetch 120 days to ensure we have enough history to grade recent 30-day forecasts
hist_data <- dbGetQuery(con, "SELECT tcgplayer_id, pull_date as date, market_price as actual_price FROM justtcg_prices WHERE pull_date >= CURRENT_DATE - INTERVAL '120 days'") %>%
  mutate(date = as.Date(date))

message("Fetching prediction runs...")
# We only care about historical shadow runs where we have actual data to compare against
c_preds <- dbGetQuery(con, "SELECT 'Chronos' as model, card_id as tcgplayer_id, target_date as date, pred_price, run_id FROM chronos_predictions WHERE target_date <= CURRENT_DATE")
g_preds <- dbGetQuery(con, "SELECT 'GRU' as model, card_id as tcgplayer_id, target_date as date, pred_price, run_id FROM gru_predictions WHERE target_date <= CURRENT_DATE")

all_preds <- bind_rows(c_preds, g_preds) %>%
  mutate(date = as.Date(date), pred_price = as.numeric(pred_price)) %>%
  arrange(model, tcgplayer_id, run_id, date) %>%
  group_by(model, tcgplayer_id, run_id) %>%
  mutate(horizon = row_number()) %>% # Assign day 1 to 30 for each run
  ungroup()

message("Calculating Anchor Prices for Naive Baseline...")
# Find the actual price on the day BEFORE the forecast started
run_anchors <- all_preds %>%
  mutate(tcgplayer_id = as.integer(tcgplayer_id)) %>%
  group_by(model, tcgplayer_id, run_id) %>%
  summarize(first_date = min(date), .groups = "drop") %>%
  left_join(hist_data, by = "tcgplayer_id", relationship = "many-to-many") %>%
  filter(date < first_date) %>%
  group_by(model, tcgplayer_id, run_id) %>%
  arrange(desc(date)) %>%
  slice(1) %>% # Get the most recent actual price before the forecast
  select(model, tcgplayer_id, run_id, anchor_price = actual_price) %>%
  ungroup()

message("Grading Forecasts...")
# Join predictions with actuals and anchors, then calculate APE
graded_runs <- all_preds %>%
  mutate(tcgplayer_id = as.integer(tcgplayer_id)) %>%
  inner_join(hist_data, by = c("tcgplayer_id", "date")) %>%
  inner_join(run_anchors, by = c("model", "tcgplayer_id", "run_id")) %>%
  filter(actual_price > 0, anchor_price > 0) %>%
  mutate(
    ape = abs(pred_price - actual_price) / actual_price,
    naive_ape = abs(anchor_price - actual_price) / actual_price
  )

message("Aggregating into Final Metrics...")
# Calculate the Median Absolute Percentage Error (MdAPE) for every card, model, and horizon
final_metrics <- graded_runs %>%
  group_by(tcgplayer_id, model, horizon) %>%
  summarize(
    mdape = median(ape),
    naive_mdape = median(naive_ape),
    min_err = min(ape),
    max_err = max(ape),
    sample_size = n(),
    .groups = "drop"
  ) %>%
  # Round to 4 decimal places to save DB space
  mutate(across(c(mdape, naive_mdape, min_err, max_err), ~round(.x, 4)))

message("Uploading to Neon...")
# Overwrite the table with fresh metrics
dbWriteTable(con, "model_backtest_metrics", final_metrics, overwrite = TRUE, row.names = FALSE)

# Create indices for hyper-fast querying later
dbExecute(con, "CREATE INDEX IF NOT EXISTS idx_backtest_tcg ON model_backtest_metrics(tcgplayer_id)")

dbDisconnect(con)
message("Success! Metrics calculated and stored.")
