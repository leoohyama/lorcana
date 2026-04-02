library(DBI)
library(RPostgres)

print("🔌 Connecting to Neon Database...")
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
# 1. UPDATE GRANULAR LIVE TABLE (The Heavy Lifting)
# ==========================================
print("🧮 Calculating granular residuals in-database...")

# --- A. Process GRU Predictions ---
calc_gru_sql <- "
INSERT INTO model_residuals_live (card_id, model_type, horizon, actual_price, pred_price, error_abs_pct, target_date, run_date)
SELECT 
    p.card_id, 
    m.model_type,
    (p.target_date - m.run_date) as horizon,
    a.market_price as actual_price,
    p.pred_price,
    ROUND((ABS(a.market_price - p.pred_price) / NULLIF(a.market_price, 0))::numeric, 4) as error_abs_pct,
    p.target_date,
    m.run_date
FROM gru_predictions p
JOIN justtcg_prices a ON p.card_id = a.tcgplayer_id::text AND p.target_date = a.pull_date
JOIN model_runs m ON p.run_id = m.run_id
WHERE p.target_date <= CURRENT_DATE
ON CONFLICT (card_id, model_type, run_date, target_date) DO NOTHING;
"
dbExecute(con, calc_gru_sql)
print("✅ GRU granular residuals updated.")

# --- B. Process Chronos Predictions ---
calc_chronos_sql <- "
INSERT INTO model_residuals_live (card_id, model_type, horizon, actual_price, pred_price, error_abs_pct, target_date, run_date)
SELECT 
    p.card_id, 
    m.model_type,
    (p.target_date - m.run_date) as horizon,
    a.market_price as actual_price,
    p.pred_price,
    ROUND((ABS(a.market_price - p.pred_price) / NULLIF(a.market_price, 0))::numeric, 4) as error_abs_pct,
    p.target_date,
    m.run_date
FROM chronos_predictions p
JOIN justtcg_prices a ON p.card_id = a.tcgplayer_id::text AND p.target_date = a.pull_date
JOIN model_runs m ON p.run_id = m.run_id
WHERE p.target_date <= CURRENT_DATE
ON CONFLICT (card_id, model_type, run_date, target_date) DO NOTHING;
"
dbExecute(con, calc_chronos_sql)
print("✅ Chronos granular residuals updated.")

# ==========================================
# 2. ROLL UP TO AGGREGATE TABLE (The Permanent Record)
# ==========================================
print("📊 Rolling up daily averages into history table...")

rollup_sql <- "
INSERT INTO model_performance_history (model_type, horizon, target_date, mean_error_pct, median_error_pct, card_count)
SELECT 
    model_type,
    horizon,
    target_date,
    ROUND(AVG(error_abs_pct)::numeric, 4) as mean_error_pct,
    ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY error_abs_pct))::numeric, 4) as median_error_pct,
    COUNT(card_id) as card_count
FROM model_residuals_live
GROUP BY model_type, horizon, target_date
ON CONFLICT (model_type, horizon, target_date) DO NOTHING;
"
dbExecute(con, rollup_sql)
print("✅ Historical aggregates updated.")

# ==========================================
# 3. THE KILL SWITCH (Pruning the Granular Data)
# ==========================================
print("✂️ Pruning granular data older than 90 days to save space...")

prune_sql <- "
DELETE FROM model_residuals_live 
WHERE target_date < CURRENT_DATE - INTERVAL '90 days';
"
deleted_rows <- dbExecute(con, prune_sql)
print(paste("🗑️ Pruned", deleted_rows, "old granular rows."))

dbDisconnect(con)
print("🎉 Residual pipeline execution complete!")




library(tidyverse)
library(DBI)
library(RPostgres)

print("🔌 Connecting to Neon Database...")
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
# 1. MACRO CHECK: Row Counts
# ==========================================
# This proves that both models successfully populated the table
print("📊 Total Rows by Model:")
counts <- dbGetQuery(con, "
    SELECT model_type, COUNT(*) as total_rows 
    FROM model_residuals_live 
    GROUP BY model_type
")
print(counts)

# ==========================================
# 2. MICRO CHECK: Structure & Data Types
# ==========================================
# Pulling just 5 rows so we don't blow up the console
sample_data <- dbGetQuery(con, "SELECT * FROM model_residuals_live LIMIT 5") %>% as_tibble()

print("🔍 Base R Structure (str):")
str(sample_data)

print("👀 Tidyverse Glimpse (Cleaner view):")
glimpse(sample_data)

dbDisconnect(con)
print("✅ Verification complete.")
