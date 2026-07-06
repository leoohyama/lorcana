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


# ==============================================================================
# PIPELINE CONTINUATION
# ==============================================================================
require(tidyr)


# ---------------------------------------------------------
# Part 4 (Revised): Anchor the specific dates needed for the ML architecture
# ---------------------------------------------------------
listing_s <- listings_tbl %>%
  filter(date_pulled %in% c(d_21_ago, d_7_ago, d_today)) %>%
  group_by(id, date_pulled) %>%
  summarise(
    total_listings = n(),
    median_price = median(price_val, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  collect()

anchor_dates_df <- listing_s %>%
  # Assign explicit column names based on the date boundary
  mutate(
    time_marker = case_when(
      date_pulled == d_21_ago ~ "day_21",
      date_pulled == d_7_ago ~ "day_7",
      date_pulled == d_today ~ "day_0"
    )
  ) %>%
  select(-date_pulled) %>%
  pivot_wider(
    names_from = time_marker, 
    values_from = c(total_listings, median_price)
  )

# ---------------------------------------------------------
# Part 5: Calculate the % Graded Volume Feature
# ---------------------------------------------------------
graded_feature_df <- listings_tbl %>%
  filter(date_pulled >= d_21_ago) %>%
  # Get only the unique listings seen over the last 3 weeks
  distinct(id, item_id) %>% 
  # Join to the metadata table to check condition
  inner_join(unique_listings_tbl, by = c("id", "item_id")) %>%
  group_by(id) %>%
  summarise(
    total_unique_listings = n(),
    # Sum up the logical TRUEs for graded cards
    graded_count = sum(ifelse(is_graded == TRUE, 1, 0), na.rm = TRUE),
    .groups = "drop"
  ) %>%
  # Calculate the percentage
  mutate(pct_graded = (graded_count / total_unique_listings) * 100) %>%
  collect()

# ---------------------------------------------------------
# Part 6: The Final Join & Target Creation
# ---------------------------------------------------------
final_analytical_dataset <- anchor_dates_df %>%
  inner_join(turnover_df, by = "id") %>%
  inner_join(graded_feature_df, by = "id") %>%
  mutate(
    # A. Feature: Prior 14-Day Net Volume Change (Day 21 to Day 7)
    prior_14d_volume_change = total_listings_day_7 - total_listings_day_21,
    
    # B. Target: 7-Day Price Change % (Day 7 to Today)
    target_price_change_pct = (median_price_day_0 - median_price_day_7) / median_price_day_7 * 100,
    
    # C. Target: Categorical (3-Tier)
    price_change_category = case_when(
      target_price_change_pct <= -5 ~ "Down",
      target_price_change_pct > -5 & target_price_change_pct < 5 ~ "Stagnant",
      target_price_change_pct >= 5 ~ "Up"
    ),
    
    # D. Factorize the target for the nnet::multinom() model
    price_change_category = factor(price_change_category, levels = c("Stagnant", "Down", "Up")),
    #E. calculate new listing to old listing ratio
    ratio_listing = unique_listings_added / unique_listings_removed
  ) %>%
  # Remove any cards that didn't have data for all three time periods
  filter(!is.na(price_change_category), !is.na(prior_14d_volume_change)) %>%
  # Select only the features needed for the statistical model
  select(
    id,
    price_change_category,
    target_price_change_pct,
    prior_14d_volume_change,
    unique_listings_added,
    unique_listings_removed,
    pct_graded,
    ratio_listing
  )


ggplot(data = final_analytical_dataset) +
  geom_boxplot(aes(x = price_change_category, y = unique_listings_added)) 
