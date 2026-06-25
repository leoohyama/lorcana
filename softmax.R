# ==============================================================================
# PROJECT PLAN: GLOBAL MARKET INFERENCE MODEL (SOFTMAX REGRESSION)
# OBJECTIVE: Quantify the exact impact of short-term volume dynamics, asset 
#            properties, and listing composition on TCG price fluctuations.
# PERSPECTIVE: Statistical Inference (Market Physics) vs. Black-Box Prediction
# ==============================================================================

# 1. CORE ARCHITECTURE
# ------------------------------------------------------------------------------
# * Framework: Pooled Global Multinomial Logistic (Softmax) Regression.
# * Justification: Rather than training uninterpretable card-specific models on 
#   narrow windows, a single global model tracks universal market behaviors.
# * Core Engine: nnet::multinom() interpreted via broom::tidy().

# 2. VARIABLE & FEATURE SPECIFICATION
# ------------------------------------------------------------------------------
# * Target Variable (Y): 
#   - 5-Tier Price Movement Category (Down Big, Down, Stagnant, Up, Up Big).
#   - Grounded in high-frequency eBay listing prices (leading indicator).
#
# * Predictor Variables (X):
#   - Short-Term Volume Ratio: Ratio of listings added vs. removed over a 14-day window.
#   - Volume Composition (% Graded): The proportion of active listings that are 
#     graded vs. raw (captures player liquidation vs. investor speculation psychology).
#   - Supply Control: Temporal age since the card's set was officially released.
#
# * Critical Interaction Terms: 
#   - (Volume Ratio * Rarity Tier) 
#   - Essential for modeling differential price elasticity of supply (e.g., how an 
#     influx of supply dampens prices for an Epic vs. an Enchanted card).

# 3. ANALYTICAL PIPELINE (MOTHERDUCK -> R)
# ------------------------------------------------------------------------------
# * Step A (In-DB): Compute normalized, stationary features (ratios/percentages) 
#   across historical 14-day sliding windows inside MotherDuck using dbplyr/SQL.
# * Step B (Local): Pull the compact, aggregated historical panel dataset into 
#   local R environment memory using collect().
# * Step C (Modeling): Fit the pooled global softmax model across all historical 
#   windows simultaneously to establish robust baseline behaviors.
# * Step D (Daily Execution): Run new 14-day operational snapshots through the 
#   fitted model daily to flag anomalous shifts and structural market changes.

# 4. EVALUATION & INFERENCE METRICS
# ------------------------------------------------------------------------------
# * Shift focus from pure classification accuracy to coefficient analysis.
# * Exponentiate model coefficients (e^beta) to compute explicit Odds Ratios.
# * Quantify the exact margin: "For every X% increase in graded card volume, the 
#   relative odds of entering a 'Down Big' state change by Y%."
# * Utilize Wald test / p-values to isolate true structural signals from noise.
# ==============================================================================

#first step is download data from motherduck to get this done
require(DBI)
require(duckdb)
require(dbplyr)

md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
Sys.setenv(motherduck_token = md_token)

# Connect to a plain local duckdb session first (no "md:" shortcut)
con <- dbConnect(duckdb::duckdb())

# Explicitly install + load motherduck — don't rely on dbdir="md:..." to autoload it
dbExecute(con, "INSTALL motherduck;")
dbExecute(con, "LOAD motherduck;")
dbExecute(con, "INSTALL icu; LOAD icu;")

# Explicitly attach the MotherDuck database, then switch into it
dbExecute(con, "ATTACH 'md:my_db' AS my_db;")
dbExecute(con, "USE my_db;")


# 1. Create virtual references to your MotherDuck tables (does not load into RAM)
prices_tbl <- tbl(con, "justtcg_prices")
listings_tbl <- tbl(con, "lorcana_active_listings")
metrics_tbl <- tbl(con, "card_ts_metrics")
unique_listings_tbl <- tbl(con, "llm_listing_metadata")


#first thing is to get 


unique_listings_tbl %>% 
  group_by(is_graded) %>%
  summarize(count = n(), .groups = "drop") 

# 2. Aggregate Volume: Get weekly listing counts per card
weekly_volume <- listings_tbl %>%
  mutate(week_start = date_trunc('week', posted_date)) %>%
  group_by(tcgplayer_id, week_start) %>%
  summarize(
    active_listings_count = n(),
    avg_listing_price = mean(price_val, na.rm = TRUE),
    .groups = "drop"
  )

# 3. Aggregate Prices: Get the weekly market price and calculate week-over-week change
weekly_prices <- prices_tbl %>%
  mutate(week_start = date_trunc('week', pull_date)) %>%
  group_by(tcgplayer_id, week_start) %>%
  summarize(
    market_price = mean(market_price, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  # Use window functions to get the previous week's price and next week's price
  group_by(tcgplayer_id) %>%
  arrange(week_start) %>%
  mutate(
    prev_week_price = lag(market_price, 1),
    next_week_price = lead(market_price, 1),
    # Calculate the future percentage change (This is what we want to predict!)
    future_pct_change = (next_week_price - market_price) / market_price
  ) %>%
  ungroup()

# 4. Join Volume and Prices together
analytical_dataset_query <- weekly_prices %>%
  inner_join(weekly_volume, by = c("tcgplayer_id", "week_start")) %>%
  filter(!is.na(future_pct_change), !is.na(prev_week_price))

# 5. Execute the query in MotherDuck and pull the finalized dataset into R's memory
# We only collect() once the data is aggregated and filtered!
df_local <- analytical_dataset_query %>% collect()