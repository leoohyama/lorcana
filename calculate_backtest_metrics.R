# ==============================================================
# calculate_backtest_metrics.R
# Calculates 30-day forecast errors and uploads to MotherDuck
# ==============================================================
library(tidyverse)
library(DBI)
library(duckdb)

# ==========================================
# --- STEP 1: CONNECT TO MOTHERDUCK ---
# ==========================================
md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))

if (md_token == "") {
  stop("MotherDuck token is missing! Check your environment configurations.")
}

message("Connecting to MotherDuck...")
Sys.setenv(motherduck_token = md_token)

# 1. Start with a completely blank in-memory session
con <- dbConnect(duckdb::duckdb())

# 2. Load the core extensions inside the session explicitly
dbExecute(con, "INSTALL motherduck; LOAD motherduck;")
dbExecute(con, "INSTALL icu; LOAD icu;")

# 3. Mount the specific cloud database database explicitly
dbExecute(con, "ATTACH 'md:my_db' AS my_db;")

# 4. Force the active session context into the cloud catalog
dbExecute(con, "USE my_db;")

# ==========================================
# --- STEP 2: FETCH DATA ---
# ==========================================
message("Fetching historical actuals...")
hist_query <- "
  SELECT tcgplayer_id, pull_date as date, market_price as actual_price 
  FROM justtcg_prices 
  WHERE pull_date >= CURRENT_DATE - INTERVAL '120 days';
"
hist_data <- dbGetQuery(con, hist_query) %>%
  mutate(date = as.Date(date))

message("Fetching prediction runs...")
c_preds <- dbGetQuery(con, "SELECT 'Chronos' as model, card_id as tcgplayer_id, target_date as date, pred_price, run_id FROM chronos_predictions WHERE target_date <= CURRENT_DATE")
g_preds <- dbGetQuery(con, "SELECT 'GRU' as model, card_id as tcgplayer_id, target_date as date, pred_price, run_id FROM gru_predictions WHERE target_date <= CURRENT_DATE")

all_preds <- bind_rows(c_preds, g_preds) %>%
  mutate(date = as.Date(date), pred_price = as.numeric(pred_price)) %>%
  arrange(model, tcgplayer_id, run_id, date) %>%
  group_by(model, tcgplayer_id, run_id) %>%
  mutate(horizon = row_number()) %>% 
  ungroup()

# ==========================================
# --- STEP 3: BACKTEST CALCULATIONS ---
# ==========================================
message("Calculating Anchor Prices for Naive Baseline...")
run_anchors <- all_preds %>%
  mutate(tcgplayer_id = as.integer(tcgplayer_id)) %>%
  group_by(model, tcgplayer_id, run_id) %>%
  summarize(first_date = min(date), .groups = "drop") %>%
  left_join(hist_data, by = "tcgplayer_id", relationship = "many-to-many") %>%
  filter(date < first_date) %>%
  group_by(model, tcgplayer_id, run_id) %>%
  arrange(desc(date)) %>%
  slice(1) %>% 
  select(model, tcgplayer_id, run_id, anchor_price = actual_price) %>%
  ungroup()

message("Grading Forecasts...")
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
  mutate(across(c(mdape, naive_mdape, min_err, max_err), ~round(.x, 4)))

# ==========================================
# --- STEP 4: UPLOAD & DISCONNECT ---
# ==========================================
if (nrow(final_metrics) > 0) {
  message("Uploading to MotherDuck...")
  
  # Explicitly drop the table first if it exists to ensure an atomic, clean rebuild
  dbExecute(con, "DROP TABLE IF EXISTS model_backtest_metrics;")
  
  # Recreate and populate the metrics table safely
  dbWriteTable(con, "model_backtest_metrics", final_metrics, append = TRUE)
  
  # Safe shutdown to commit all changes smoothly
  dbDisconnect(con, shutdown = TRUE)
  message("Success! Metrics calculated and stored in MotherDuck.")
} else {
  dbDisconnect(con, shutdown = TRUE)
  message("No metrics calculated. Skipping database upload.")
}
