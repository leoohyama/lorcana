library(DBI)
library(RPostgres)
library(tidyverse)
library(lubridate)
library(reticulate) # To trigger your Chronos Python script

# --- 1. CONNECT & PULL LATEST 30 DAYS ---
con <- dbConnect(RPostgres::Postgres(), dbname="neondatabase", host="...", user="alex", password="...", port=5432, sslmode="require")

# Get the most recent 30 days for ALL cards that meet the 180-day filter
latest_data <- dbGetQuery(con, "
  SELECT tcgplayer_id AS card_id, pull_date AS date, market_price AS price
  FROM justtcg_prices
  WHERE tcgplayer_id IN (
    SELECT tcgplayer_id FROM justtcg_prices 
    GROUP BY tcgplayer_id HAVING COUNT(*) >= 180
  )
  AND pull_date >= (SELECT MAX(pull_date) FROM justtcg_prices) - INTERVAL '30 days'
  ORDER BY card_id, date
")

# --- 2. RUN MODELS ---

# A. RUN CHRONOS (Triggering your Python script)
# Ensure your Python script is set up to read 'latest_data' or a temp CSV
write_csv(latest_data, "data/temp_inference_input.csv")
system("python3 4_run_chronos_mps.py") # This generates your 'chronos_forecast_tidy.csv'
chronos_preds <- read_csv("data/chronos_forecast_tidy.csv")

# B. RUN GRU MODELS (Assuming you have a function 'get_gru_forecast')
# For this example, let's assume you've wrapped your PyTorch logic in a script
source("scripts/inference_gru.R") 
gru_single <- get_gru_forecast(latest_data, model_type = "single")
gru_ensemble <- get_gru_forecast(latest_data, model_type = "ensemble")

# --- 3. CALCULATE CONSENSUS ---
all_preds <- bind_rows(
  chronos_preds %>% mutate(model_name = "Chronos"),
  gru_single %>% mutate(model_name = "Single GRU"),
  gru_ensemble %>% mutate(model_name = "GRU Ensemble")
)

consensus <- all_preds %>%
  group_by(card_id, day_offset) %>%
  summarize(
    forecast_date = Sys.Date() + day_offset,
    pred_price = mean(pred_price),
    conf_low = mean(conf_low),
    conf_high = mean(conf_high),
    .groups = "drop"
  ) %>%
  mutate(model_name = "Consensus", run_date = Sys.Date())

# --- 4. SAVE TO NEON ---
# We save both the individual models AND the consensus for maximum transparency
final_upload <- all_preds %>%
  mutate(forecast_date = Sys.Date() + day_offset, run_date = Sys.Date()) %>%
  select(card_id, forecast_date, pred_price, conf_low, conf_high, model_name, run_date) %>%
  bind_rows(consensus)

dbWriteTable(con, "forecast_history", final_upload, append = TRUE, row.names = FALSE)

dbDisconnect(con)
print("🚀 Forecasts generated and stored in Neon!")