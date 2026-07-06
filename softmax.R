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

# ==============================================================================
# PIPELINE: 21-Day Volume Turnover & 7-Day Price Movement Model Dataset
# ==============================================================================

# ---------------------------------------------------------
# Part 1: Define the exact boundary dates locally
# ---------------------------------------------------------
d_today <- Sys.Date()
d_7_ago <- d_today - 7
d_21_ago <- d_today - 21

# ---------------------------------------------------------
# Part 2: Calculate Unique Listing Turnover (In-Database)
# Compares exact item_ids present 21 days ago vs 7 days ago
# ---------------------------------------------------------
turnover_df <- listings_tbl %>%
  filter(date_pulled == d_21_ago | date_pulled == d_7_ago) %>%
  group_by(id, item_id) %>%
  summarise(
    was_start = max(case_when(date_pulled == d_21_ago ~ 1, TRUE ~ 0), na.rm = TRUE),
    was_end = max(case_when(date_pulled == d_7_ago ~ 1, TRUE ~ 0), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  group_by(id) %>%
  summarise(
    unique_listings_added = sum(case_when(was_start == 0 & was_end == 1 ~ 1, TRUE ~ 0), na.rm = TRUE),
    unique_listings_removed = sum(case_when(was_start == 1 & was_end == 0 ~ 1, TRUE ~ 0), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  collect()

# ---------------------------------------------------------
# Part 3: Get the total number of listings and median price for each card over the last 21 days
# ---------------------------------------------------------
card_spec_summary_df <- listings_tbl %>%
  filter(date_pulled >= d_21_ago) %>%
  group_by(id) %>%
  summarise(
    total_listings = n(),
    median_price = median(price_val, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  collect()


listing_s <- listings_tbl %>%
  filter(date_pulled >= d_21_ago) %>%
  group_by(id) %>%
  summarise(
    total_listings = n(),
    median_price = median(price_val, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  collect()

# ---------------------------------------------------------
# Part 4: Now get the number of unique listings added and removed over the first 14 of 21 days
# ---------------------------------------------------------
daily_summary_df %>%
  group_by(id) %>%
  # Keep the row if its date is the absolute newest OR the absolute oldest
  filter(date_pulled == min(date_pulled) | date_pulled == max(date_pulled)) %>%
  arrange(id, date_pulled) %>%
  ungroup()

daily_summary_df  %>% filter(id == "crd_248b8f0ae7a84f368e48086307f50ff7")
daily_summary_df %>%
  group_by(id) %>%
  arrange(date_pulled) %>%
  slice_max(date_pulled, n = 1) %>%
  slice_min(date_pulled, n = 1) %>%
  mutate(
    listings_start_14d = lag(total_listings, 12),
    listings_end_14d = lag(total_listings, 7),
    .groups = "drop"
  ) %>%
  arrange(desc(total_listings)) %>%
  print(n = 20)

# ---------------------------------------------------------
# Part 4: Calculate Price Metrics & Net Volume Changes 
# ---------------------------------------------------------
final_analytical_dataset <- daily_summary_df %>%
  # Ensure chronological order before using lag()
  arrange(id, date_pulled) %>% 
  group_by(id) %>%
  mutate(
    # A. 7-Day Price Metrics (d_7_ago to d_today)
    price_initial = lag(median_price, 7),
    price_final = median_price,
    price_change_pct = (price_final - price_initial) / price_initial * 100,
    
    # B. The 3-Tier Categorization
    price_change_category = case_when(
      price_change_pct <= -5 ~ "Down",
      price_change_pct > -5 & price_change_pct < 5 ~ "Stagnant",
      price_change_pct >= 5 ~ "Up"
    ),
    
    # C. Prior 14-Day Net Volume Metrics (d_21_ago to d_7_ago)
    listings_start_14d = lag(total_listings, 21),
    listings_end_14d = lag(total_listings, 7),
    listing_total_change_prior_14d = listings_end_14d - listings_start_14d
  ) %>%
  # Lock in the most recent date for each card
  slice_max(date_pulled, n = 1) %>% 
  ungroup() %>%
  # Ensure we have a full 21 days of history for the card
  filter(!is.na(price_initial), !is.na(listings_start_14d)) %>%
  
  # ---------------------------------------------------------
  # Part 5: Join the Turnover Metrics
  # ---------------------------------------------------------
  left_join(turnover_df, by = "id") %>%
  # Clean up the final view to only show the needed modeling columns
  select(
    id, 
    date_pulled,
    price_change_category, 
    price_change_pct,
    listing_total_change_prior_14d,
    unique_listings_added,
    unique_listings_removed
  )
