library(tidyverse)
library(lubridate)
library(DBI)
library(RPostgres)

# ==========================================
# 1. AUTHENTICATION & SETUP
# ==========================================
print("🚀 Connecting to Neon via .Renviron...")

con <- dbConnect(
  RPostgres::Postgres(),
  host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
  dbname   = "neondb",
  user     = "neondb_owner",
  password = Sys.getenv("NEON_PASSWORD"),
  port     = 5432,
  sslmode  = "require"
)

# ==========================================
# 2. LOAD DATA (LOCAL & NEON)
# ==========================================
print("📥 Loading Model Forecasts (Local) and History (Neon)...")

# Force dates to Date objects on load to prevent join/math errors
date_cols <- cols(run_date = col_date(), target_date = col_date())

# Local Forecasts (The Backtest Diagnostics)
gru_15 <- read_csv("data/pytorch/gru_forecast_tidy_15.csv", col_types = cols(card_id = col_character(), run_date = col_date(), target_date = col_date()), show_col_types = FALSE) 
gru_30 <- read_csv("data/pytorch/gru_forecast_tidy_30.csv", col_types = cols(card_id = col_character(), run_date = col_date(), target_date = col_date()), show_col_types = FALSE)
gru_45 <- read_csv("data/pytorch/gru_forecast_tidy_45.csv", col_types = cols(card_id = col_character(), run_date = col_date(), target_date = col_date()), show_col_types = FALSE) 
chronos_preds <- read_csv("data/pytorch/chronos_forecast_tidy.csv", col_types = cols(card_id = col_character(), run_date = col_date(), target_date = col_date()), show_col_types = FALSE)

# Live History from Neon
history_df <- dbGetQuery(con, "SELECT tcgplayer_id, pull_date, market_price FROM justtcg_prices") %>%
  rename(
    card_id = tcgplayer_id,
    price_date = pull_date,
    price = market_price
  ) %>%
  mutate(
    price_date = as.Date(price_date),
    card_id = as.character(card_id) # THE FIX: Force to Character for joins
  ) %>%
  as_tibble()

# ==========================================
# 3. CALCULATE ENSEMBLE & STANDARDIZE
# ==========================================
print("📊 Processing Ensemble and cleaning prediction frames...")

ensemble_preds <- bind_rows(gru_15, gru_30, gru_45) %>%
  group_by(card_id, run_date, target_date) %>%
  summarize(
    pred_price = mean(pred_price, na.rm = TRUE), 
    conf_low = mean(conf_low, na.rm = TRUE), 
    conf_high = mean(conf_high, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  mutate(model = "GRU Ensemble")

# Combine all "Production" models for evaluation
all_preds_raw <- bind_rows(
  gru_30 %>% mutate(model = "Single GRU"), 
  ensemble_preds,
  chronos_preds %>% mutate(model = "Chronos")
) %>%
  select(-any_of("actual_price")) # Ensure we rely exclusively on the Neon Ground Truth

# ==========================================
# 4. LIFETIME CHAOS INDEX (VOLATILITY)
# ==========================================
print("🌀 Calculating Lifetime Chaos Index...")

volatility_metrics <- history_df %>%
  group_by(card_id) %>%
  arrange(price_date) %>%
  # Exclude the 30-day test window to prevent data leakage in metrics
  filter(n() > 30) %>%
  slice(1:(n() - 30)) %>% 
  summarize(
    # Dollar values rounded to 2 decimal places
    net_change = round(abs(last(price) - first(price)), 2),
    sum_of_changes = round(sum(abs(diff(price)), na.rm = TRUE), 2),
    # Ratios rounded to 4 decimal places
    efficiency_ratio = round(if_else(sum_of_changes > 0, net_change / sum_of_changes, 1), 4),
    span_range = round((max(price) - min(price)) / mean(price), 4),
    volatility_cv = round(span_range * (1 - efficiency_ratio), 4),
    .groups = "drop"
  ) %>%
  mutate(volatility_tier = ntile(volatility_cv, 3))

# ==========================================
# 5. CONSTRUCT GRANULAR DIAGNOSTIC TABLES
# ==========================================
print("📈 Finalizing Granular Diagnostic Tables...")

current_run_timestamp <- Sys.Date()

# This is our 'Master Residual' pool
diagnostic_pool <- all_preds_raw %>%
  left_join(
    history_df %>% select(card_id, price_date, actual_price = price), 
    by = c("card_id", "target_date" = "price_date")
  ) %>%
  left_join(volatility_metrics, by = "card_id") %>%
  filter(!is.na(actual_price), !is.na(volatility_tier)) %>%
  mutate(
    ape = abs(actual_price - pred_price) / actual_price,
    day_offset = as.numeric(target_date - run_date),
    diagnostic_run_date = current_run_timestamp
  )

# Table A: Accuracy by Card (The Leaderboard)
card_accuracy_summary <- diagnostic_pool %>%
  group_by(card_id, model, volatility_tier, diagnostic_run_date) %>% 
  summarize(
    mape = round(mean(ape, na.rm = TRUE), 4),
    max_error = round(max(ape, na.rm = TRUE), 4),
    .groups = "drop"
  )

# Table B: Accuracy by Target Date (The Event Monitor)
daily_performance_summary <- diagnostic_pool %>%
  group_by(target_date, model, diagnostic_run_date) %>% 
  summarize(
    daily_mape = round(mean(ape, na.rm = TRUE), 4),
    .groups = "drop"
  )

# Table C: Volatility History (Tracking Regime Shifts)
card_volatility_history <- volatility_metrics %>% 
  mutate(diagnostic_run_date = current_run_timestamp)

# Table D: Horizon Degradation (Model Selection)
model_degradation_summary <- diagnostic_pool %>%
  group_by(model, day_offset, volatility_tier, diagnostic_run_date) %>% 
  summarize(
    horizon_mape = round(mean(ape, na.rm = TRUE), 4), 
    .groups = "drop"
  )
# ==========================================
# 6. PUSH TO NEON (SMART APPEND)
# ==========================================
print("☁️ Syncing diagnostics to Neon...")

# List of tables to sync
tables_to_sync <- list(
  "card_accuracy_summary" = card_accuracy_summary,
  "daily_performance_summary" = daily_performance_summary,
  "card_volatility_history" = card_volatility_history,
  "model_degradation_summary" = model_degradation_summary
)

for (table_name in names(tables_to_sync)) {
  df <- tables_to_sync[[table_name]]
  
  if (dbExistsTable(con, table_name)) {
    # SAFETY CHECK: Remove existing data for TODAY only 
    # This makes the script 'idempotent' (you can run it 100x today and only get 1 set of rows)
    delete_query <- glue::glue_sql("DELETE FROM {`table_name`} WHERE diagnostic_run_date = {current_run_timestamp}", .con = con)
    dbExecute(con, delete_query)
    
    print(glue::glue("Checking for existing data in {table_name}... Any rows for today were cleared. Appending..."))
    dbWriteTable(con, table_name, df, append = TRUE, row.names = FALSE)
  } else {
    # If the table doesn't exist at all, create it
    print(glue::glue("Table {table_name} does not exist. Creating it now..."))
    dbWriteTable(con, table_name, df, row.names = FALSE)
  }
}

dbDisconnect(con)
print("✨ Smart sync complete! Historical data preserved, today's run updated.")