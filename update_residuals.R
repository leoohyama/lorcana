library(DBI)
library(duckdb)

print("🔌 Connecting to MotherDuck...")

md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
if (md_token == "") {
  stop("MotherDuck token is missing! Check your environment configurations.")
}

Sys.setenv(motherduck_token = md_token)
con <- dbConnect(duckdb::duckdb())
dbExecute(con, "INSTALL motherduck; LOAD motherduck;")
dbExecute(con, "INSTALL icu; LOAD icu;")
dbExecute(con, "ATTACH 'md:'")
dbExecute(con, "USE my_db;")

# ==========================================
# 1. UPDATE GRANULAR LIVE TABLE (The Heavy Lifting)
# ==========================================
print("🧮 Calculating granular residuals in-database...")

# --- A. Process GRU Predictions ---
calc_gru_sql <- "
INSERT INTO model_residuals_live (card_id, model_type, horizon, actual_price, pred_price, error_abs_pct, target_date, run_date)
WITH new_residuals AS (
    SELECT 
        p.card_id, 
        m.model_type,
        CAST(p.target_date - m.run_date AS INTEGER) as horizon,
        a.market_price as actual_price,
        p.pred_price,
        ROUND((ABS(a.market_price - p.pred_price) / NULLIF(a.market_price, 0)), 4) as error_abs_pct,
        p.target_date,
        m.run_date
    FROM gru_predictions p
    JOIN justtcg_prices a ON p.card_id = CAST(a.tcgplayer_id AS VARCHAR) AND p.target_date = a.pull_date
    JOIN model_runs m ON p.run_id = m.run_id
    WHERE p.target_date <= CURRENT_DATE
)
SELECT * FROM new_residuals n
WHERE NOT EXISTS (
    SELECT 1 FROM model_residuals_live l
    WHERE l.card_id = n.card_id 
      AND l.model_type = n.model_type 
      AND l.run_date = n.run_date 
      AND l.target_date = n.target_date
);
"
dbExecute(con, calc_gru_sql)
print("✅ GRU granular residuals updated.")

# --- B. Process Chronos Predictions ---
calc_chronos_sql <- "
INSERT INTO model_residuals_live (card_id, model_type, horizon, actual_price, pred_price, error_abs_pct, target_date, run_date)
WITH new_residuals AS (
    SELECT 
        p.card_id, 
        m.model_type,
        CAST(p.target_date - m.run_date AS INTEGER) as horizon,
        a.market_price as actual_price,
        p.pred_price,
        ROUND((ABS(a.market_price - p.pred_price) / NULLIF(a.market_price, 0)), 4) as error_abs_pct,
        p.target_date,
        m.run_date
    FROM chronos_predictions p
    JOIN justtcg_prices a ON p.card_id = CAST(a.tcgplayer_id AS VARCHAR) AND p.target_date = a.pull_date
    JOIN model_runs m ON p.run_id = m.run_id
    WHERE p.target_date <= CURRENT_DATE
)
SELECT * FROM new_residuals n
WHERE NOT EXISTS (
    SELECT 1 FROM model_residuals_live l
    WHERE l.card_id = n.card_id 
      AND l.model_type = n.model_type 
      AND l.run_date = n.run_date 
      AND l.target_date = n.target_date
);
"
dbExecute(con, calc_chronos_sql)
print("✅ Chronos granular residuals updated.")

# ==========================================
# 2. ROLL UP TO AGGREGATE TABLE (The Permanent Record)
# ==========================================
print("📊 Rolling up daily averages into history table...")

rollup_sql <- "
INSERT INTO model_performance_history (model_type, horizon, target_date, mean_error_pct, median_error_pct, card_count)
WITH new_aggregates AS (
    SELECT 
        model_type,
        horizon,
        target_date,
        -- wMAPE: Sum of absolute dollar errors / Sum of actual dollars
        ROUND((SUM(ABS(actual_price - pred_price)) / NULLIF(SUM(actual_price), 0)), 4) as mean_error_pct,
        -- Native DuckDB Median implementation
        ROUND(MEDIAN(error_abs_pct), 4) as median_error_pct,
        COUNT(card_id) as card_count
    FROM model_residuals_live
    GROUP BY model_type, horizon, target_date
)
SELECT * FROM new_aggregates n
WHERE NOT EXISTS (
    SELECT 1 FROM model_performance_history h
    WHERE h.model_type = n.model_type 
      AND h.horizon = n.horizon 
      AND h.target_date = n.target_date
);
"
dbExecute(con, rollup_sql)
print("✅ Historical aggregates updated (wMAPE and MdAPE).")

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

dbDisconnect(con, shutdown = TRUE)
print("🎉 Residual pipeline execution complete!")