# ============================================================================
# BUY / HOLD / SELL  --  calibrated multinomial logistic (tidymodels)
#
# Produces, for every card it can score, three CALIBRATED probabilities that
# sum to 1:  P(buy), P(hold), P(sell).
#
# Label (looks HORIZON_DAYS forward from day t):
#   SELL  if the price is likely to FALL              (fwd return <= -SELL_THR)
#   BUY   if likely to RISE *and* currently at a LOW  (fwd >= +BUY_THR AND pos <= LOW_POS)
#   HOLD  otherwise (stable, or rising but already expensive)
#
# Predictors are all AS OF day t (leakage-safe): TCG price dynamics, each card's
# ALL-TIME high/low position, and -- where eBay data exists -- listing volume,
# churn (supply/demand) and the eBay/TCG premium (imputed on older days).
#
# Pipeline:
#   * BHS_SWEEP=TRUE  -> grid over {horizon x threshold}, report AUC / calibration
#                        / class-balance, then auto-pick a sensible config and
#                        persist it (bhs_config.csv) for daily sweep-off runs.
#   * ROLLING (walk-forward) recalibration: the probability calibrator is re-fit
#     on the most-recent slice preceding each scored window, so it tracks regime.
#   * BHS_PUSH=TRUE   -> write today's calibrated scores to MotherDuck.
# ============================================================================

suppressPackageStartupMessages({
  library(tidyverse); library(lubridate)
  library(DBI); library(duckdb)
  library(slider); library(moments)
  library(tidymodels); library(probably)
})
set.seed(42)

# --- knobs ------------------------------------------------------------------
# horizon/threshold precedence: explicit env var > last sweep's persisted pick
# (bhs_config.csv, written by the weekly BHS_SWEEP run) > hardcoded fallback.
CONFIG_PATH <- "data/pytorch/bhs_config.csv"
cfg <- if (file.exists(CONFIG_PATH)) read_csv(CONFIG_PATH, show_col_types = FALSE) else NULL
cfg_knob <- function(env, field, fallback) {
  v <- Sys.getenv(env, "")
  if (v != "") return(as.numeric(v))
  if (!is.null(cfg)) return(as.numeric(cfg[[field]]))
  fallback
}
if (!is.null(cfg)) message(sprintf("Using tuned config from %s (swept on %s).", CONFIG_PATH, cfg$tuned_on))
HORIZON_DAYS     <- as.integer(cfg_knob("BHS_HORIZON", "horizon", 21))
BUY_THR          <- cfg_knob("BHS_BUY_THR", "buy_thr", 0.07)
SELL_THR         <- cfg_knob("BHS_SELL_THR", "sell_thr", 0.07)
BUY_REQUIRES_LOW <- TRUE
LOW_POS          <- 0.50
MIN_HISTORY      <- 180   # min raw history to TRAIN/label a card (reliable fwd-return label + calibration)
SCORE_MIN_HISTORY <- as.integer(Sys.getenv("BHS_SCORE_MIN_HISTORY", "45"))  # min history to SCORE; newer cards get calibrated probs from the shared-dynamics model. Lower toward ~31 = thinner/imputed features
EMBARGO          <- HORIZON_DAYS
TEST_DAYS        <- 60       # future holdout window (also split into monthly walk-forward chunks)
CAL_DAYS         <- 60       # size of the recent slice used to (re)fit the calibrator
SWEEP            <- as.logical(Sys.getenv("BHS_SWEEP", "TRUE"))
PUSH             <- as.logical(Sys.getenv("BHS_PUSH", "TRUE"))

PRED <- c("log_price", "mom_7", "mom_14", "mom_30", "ma_gap_7", "ma_gap_30",
          "vol_14", "vol_30", "cv_30", "skew_30", "ac1_30",
          "pos_range", "pct_from_ath", "pct_from_atl", "pos_range_90",
          "log_active", "churn_rate", "net_flow", "ebay_prem",
          "days_since_release", "cost", "rarity", "ink_clean")

# ============================================================================
# 1. PULL DATA
# ============================================================================
message("1. Pulling data from MotherDuck...")
md_token <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))
if (md_token == "") stop("MOTHERDUCK_TOKEN missing.")
Sys.setenv(motherduck_token = md_token)
con <- dbConnect(duckdb::duckdb())
dbExecute(con, "INSTALL motherduck; LOAD motherduck;")
dbExecute(con, "ATTACH 'md:'"); dbExecute(con, "USE my_db;")

prices <- dbGetQuery(con, sprintf("
  SELECT tcgplayer_id AS card_id, pull_date AS date, market_price AS price
  FROM justtcg_prices
  WHERE tcgplayer_id IN (SELECT tcgplayer_id FROM justtcg_prices
    GROUP BY 1 HAVING COUNT(DISTINCT pull_date) >= %d)
  ORDER BY 1, 2", SCORE_MIN_HISTORY))

# Per-card raw history length -> defines the two universes:
#   >= MIN_HISTORY days       : eligible to TRAIN/label (feat_train, below)
#   >= SCORE_MIN_HISTORY days : eligible to SCORE (the full `feat`)
# Training is unchanged from before; we only ADD newer cards at scoring time.
hist_tbl  <- prices %>% mutate(card_id = as.character(card_id)) %>%
  group_by(card_id) %>% summarise(hist_days = n_distinct(date), .groups = "drop")
train_ids <- hist_tbl %>% filter(hist_days >= MIN_HISTORY) %>% pull(card_id)

ebay <- dbGetQuery(con, "
  WITH v AS (
    SELECT l.id AS ebay_id, a.item_id, DATE(a.date_pulled) AS d, a.price_val AS px, a.listing_type
    FROM lorcana_active_listings a JOIN llm_listing_metadata l ON a.item_id = l.item_id
    WHERE l.is_valid AND l.is_graded IS FALSE AND l.card_language = 'English' AND a.price_val > 0),
  life    AS (SELECT ebay_id, item_id, MIN(d) fs, MAX(d) ls FROM v GROUP BY 1, 2),
  active  AS (SELECT ebay_id, d, COUNT(DISTINCT item_id) active FROM v GROUP BY 1, 2),
  newl    AS (SELECT ebay_id, fs AS d, COUNT(*) n_new FROM life GROUP BY 1, 2),
  reml    AS (SELECT ebay_id, ls AS d, COUNT(*) n_rem FROM life GROUP BY 1, 2),
  vp      AS (SELECT ebay_id, d, px FROM v WHERE listing_type NOT LIKE '%AUCTION%'),
  bounds  AS (SELECT ebay_id, d, COUNT(*) n, quantile_cont(px,0.25) q1, quantile_cont(px,0.75) q3
              FROM vp GROUP BY 1, 2),
  fenced  AS (SELECT vp.ebay_id, vp.d, vp.px FROM vp JOIN bounds b ON vp.ebay_id=b.ebay_id AND vp.d=b.d
              WHERE b.n >= 3 AND vp.px BETWEEN b.q1-1.5*(b.q3-b.q1) AND b.q3+1.5*(b.q3-b.q1)),
  med     AS (SELECT ebay_id, d, median(px) ebay_median FROM fenced GROUP BY 1, 2),
  maxd    AS (SELECT MAX(d) m FROM v)
  SELECT active.ebay_id, active.d AS date, active.active,
         COALESCE(newl.n_new, 0) AS n_new,
         CASE WHEN active.d < (SELECT m FROM maxd) THEN COALESCE(reml.n_rem, 0) END AS n_rem,
         med.ebay_median
  FROM active
  LEFT JOIN newl ON active.ebay_id=newl.ebay_id AND active.d=newl.d
  LEFT JOIN reml ON active.ebay_id=reml.ebay_id AND active.d=reml.d
  LEFT JOIN med  ON active.ebay_id=med.ebay_id  AND active.d=med.d")
dbDisconnect(con, shutdown = TRUE)

static <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  filter(!str_detect(set_name, "Promo")) %>%
  transmute(card_id = as.character(tcgplayer_id), ebay_id = as.character(id),
            name, rarity, ink_clean, cost = as.numeric(cost),
            released_at = as_date(parse_date_time(released_at, orders = c("ymd", "mdy"))))

ebay <- ebay %>%
  mutate(ebay_id = as.character(ebay_id), date = as_date(date)) %>%
  inner_join(static %>% select(ebay_id, card_id), by = "ebay_id") %>%
  transmute(card_id, date, active, ebay_median,
            churn_rate = if_else(active > 0 & !is.na(n_rem), pmin(n_rem / active, 1), NA_real_),
            net_flow   = if_else(active > 0 & !is.na(n_rem), (n_new - n_rem) / active, NA_real_))

# ============================================================================
# 2. FEATURES (as of t) -- horizon-independent; label added later
# ============================================================================
message("2. Building features...")
roll_sd   <- function(x, n) slide_dbl(x, sd,   .before = n - 1, .complete = TRUE)
roll_mean <- function(x, n) slide_dbl(x, mean, .before = n - 1, .complete = TRUE)
roll_max  <- function(x, n) slide_dbl(x, max,  .before = n - 1, .complete = TRUE)
roll_min  <- function(x, n) slide_dbl(x, min,  .before = n - 1, .complete = TRUE)
roll_skew <- function(x, n) slide_dbl(x, ~ if (length(.x) > 2) skewness(.x) else NA_real_,
                                      .before = n - 1, .complete = TRUE)
roll_ac1  <- function(x, n) slide_dbl(x, ~ if (sum(!is.na(.x)) > 3)
                                        suppressWarnings(cor(head(.x,-1), tail(.x,-1), use="complete.obs"))
                                      else NA_real_, .before = n - 1, .complete = TRUE)
safe_div  <- function(a, b) if_else(b == 0, 0.5, a / b)

feat <- prices %>%
  mutate(card_id = as.character(card_id), date = as_date(date), price = as.numeric(price)) %>%
  group_by(card_id) %>%
  complete(date = seq.Date(min(date), max(date), by = "day")) %>%
  fill(price, .direction = "down") %>%
  arrange(date, .by_group = TRUE) %>%
  mutate(
    ret_1 = price / lag(price, 1) - 1, log_price = log(price),
    mom_7  = price / lag(price, 7)  - 1, mom_14 = price / lag(price, 14) - 1,
    mom_30 = price / lag(price, 30) - 1,
    ma_gap_7  = price / roll_mean(price, 7)  - 1, ma_gap_30 = price / roll_mean(price, 30) - 1,
    vol_14 = roll_sd(ret_1, 14), vol_30 = roll_sd(ret_1, 30),
    cv_30  = roll_sd(price, 30) / roll_mean(price, 30),
    skew_30 = roll_skew(price, 30), ac1_30 = roll_ac1(ret_1, 30),
    ath = cummax(price), atl = cummin(price),
    pos_range   = safe_div(price - atl, ath - atl),
    pct_from_ath = price / ath - 1, pct_from_atl = price / atl - 1,
    pos_range_90 = safe_div(price - roll_min(price, 90), roll_max(price, 90) - roll_min(price, 90))
  ) %>% ungroup()

feat <- feat %>%
  left_join(ebay, by = c("card_id", "date")) %>%
  group_by(card_id) %>% arrange(date, .by_group = TRUE) %>%
  mutate(log_active = log1p(active), ebay_prem = log(ebay_median / price)) %>%
  fill(ebay_prem, .direction = "down") %>% ungroup() %>%
  left_join(static %>% select(card_id, name, rarity, ink_clean, cost, released_at), by = "card_id") %>%
  mutate(days_since_release = pmax(0L, as.integer(date - released_at))) %>%
  filter(!is.na(vol_30), !is.na(skew_30), !is.na(mom_30), !is.na(pos_range), !is.na(rarity))

# Veterans-only frame for training/labeling; the full `feat` (every card with a
# complete feature window) is used for the final scoring pass, so newer cards
# also receive calibrated probabilities from the same shared-dynamics model.
feat_train <- feat %>% filter(card_id %in% train_ids)
message(sprintf("   %d cards scoreable | %d eligible to train (>= %d days history)",
                n_distinct(feat$card_id), n_distinct(feat_train$card_id), MIN_HISTORY))

# ---- helpers ---------------------------------------------------------------
make_labeled <- function(df, horizon, buy_thr, sell_thr) {
  df %>% group_by(card_id) %>% arrange(date, .by_group = TRUE) %>%
    mutate(fwd_ret = lead(price, horizon) / price - 1) %>% ungroup() %>%
    mutate(label = case_when(
      fwd_ret <= -sell_thr ~ "sell",
      fwd_ret >=  buy_thr & (!BUY_REQUIRES_LOW | pos_range <= LOW_POS) ~ "buy",
      TRUE ~ "hold"),
      label = factor(label, levels = c("buy", "hold", "sell")))
}

recipe_for <- function(train_df) {
  recipe(label ~ ., data = train_df %>% select(label, card_id, name, date, all_of(PRED))) %>%
    update_role(card_id, name, date, new_role = "id") %>%
    step_impute_median(all_numeric_predictors()) %>%
    step_novel(all_nominal_predictors()) %>% step_dummy(all_nominal_predictors()) %>%
    step_zv(all_predictors()) %>% step_normalize(all_numeric_predictors())
}

# beta calibration is smoothest but its uniroot fit can fail on degenerate
# slices; fall back to isotonic (always solvable) so daily runs never crash.
fit_calibrator <- function(preds_df) {
  tryCatch(
    cal_estimate_beta(preds_df, truth = label, estimate = dplyr::starts_with(".pred_")),
    error = function(e) {
      message("   (beta calibration failed -> isotonic fallback)")
      cal_estimate_isotonic(preds_df, truth = label, estimate = dplyr::starts_with(".pred_"))
    })
}

tune_best <- function(train_df, grid_levels = c(6, 4)) {
  folds <- sliding_period(train_df %>% arrange(date), index = date,
                          period = "month", lookback = Inf, assess_stop = 1, skip = 1)
  wf <- workflow() %>% add_recipe(recipe_for(train_df)) %>%
    add_model(multinom_reg(penalty = tune(), mixture = tune()) %>%
                set_engine("glmnet") %>% set_mode("classification"))
  grid <- grid_regular(penalty(range = c(-4, -0.5)), mixture(range = c(0, 1)), levels = grid_levels)
  tuned <- tune_grid(wf, resamples = folds, grid = grid,
                     metrics = metric_set(roc_auc), control = control_grid(save_pred = FALSE))
  list(wf = wf, best = select_best(tuned, metric = "roc_auc"),
       cv_auc = show_best(tuned, metric = "roc_auc", n = 1)$mean)
}

# WALK-FORWARD calibrated evaluation: model fixed (fit on pre-test data); the
# beta calibrator is re-fit on the CAL_DAYS immediately before each monthly
# test chunk, tracking regime. Returns pooled calibrated predictions + metrics.
walkforward_eval <- function(labeled, wf, best, train_end, test_start) {
  mfit <- fit(finalize_workflow(wf, best), data = labeled %>% filter(date <= train_end))
  test <- labeled %>% filter(date > test_start) %>% mutate(mon = floor_date(date, "month"))
  out <- list()
  for (m in sort(unique(test$mon))) {
    chunk <- test %>% filter(mon == m)
    cal_slice <- labeled %>% filter(date < min(chunk$date), date >= min(chunk$date) - CAL_DAYS)
    if (nrow(cal_slice) < 200) next
    cmod <- fit_calibrator(augment(mfit, cal_slice))
    out[[as.character(m)]] <- cal_apply(augment(mfit, chunk), cmod)
  }
  pooled <- bind_rows(out)
  list(mfit = mfit,
       auc  = roc_auc(pooled, label, .pred_buy, .pred_hold, .pred_sell)$.estimate,
       brier = brier_class(pooled, label, .pred_buy, .pred_hold, .pred_sell)$.estimate,
       logloss = mn_log_loss(pooled, label, .pred_buy, .pred_hold, .pred_sell)$.estimate,
       pooled = pooled)
}

# ============================================================================
# 3. SWEEP horizon x threshold -> auto-pick a sensible config
# ============================================================================
choose <- list(h = HORIZON_DAYS, buy = BUY_THR, sell = SELL_THR)
if (SWEEP) {
  message("3. Sweeping horizon x threshold...")
  grid_cfg <- expand_grid(h = c(14L, 21L, 30L), thr = c(0.07, 0.10))
  res <- pmap_dfr(grid_cfg, function(h, thr) {
    lab <- make_labeled(feat_train, h, thr, thr) %>% filter(!is.na(fwd_ret))
    max_d <- max(lab$date); ts <- max_d - TEST_DAYS; te <- ts - h
    tr <- lab %>% filter(date <= te)
    tb <- tune_best(tr, grid_levels = c(5, 3))
    ev <- walkforward_eval(lab, tb$wf, tb$best, te, ts)
    bal <- lab %>% count(label) %>% mutate(p = n / sum(n))
    tibble(horizon = h, thr = thr,
           buy_pct = round(100 * bal$p[bal$label == "buy"], 1),
           sell_pct = round(100 * bal$p[bal$label == "sell"], 1),
           auc = round(ev$auc, 3), brier = round(ev$brier, 3), logloss = round(ev$logloss, 3))
  })
  cat("\n---------------- horizon x threshold sweep (walk-forward) ----------------\n")
  print(res, n = 50)
  # pick: best AUC among configs with buy% and sell% both >= 8% (actionable balance)
  ok <- res %>% filter(buy_pct >= 8, sell_pct >= 8)
  if (nrow(ok) == 0) ok <- res
  pick <- ok %>% slice_max(auc, n = 1)
  choose <- list(h = pick$horizon, buy = pick$thr, sell = pick$thr)
  cat(sprintf("\n>> chosen config: horizon=%d, buy/sell threshold=+/-%.0f%% (AUC %.3f, buy %.1f%%, sell %.1f%%)\n\n",
              choose$h, 100 * choose$buy, pick$auc, pick$buy_pct, pick$sell_pct))
  # persist the pick so daily (sweep-off) runs use it until the next sweep
  write_csv(tibble(horizon = choose$h, buy_thr = choose$buy, sell_thr = choose$sell,
                   auc = pick$auc, tuned_on = Sys.Date()), CONFIG_PATH)
  message(sprintf("   chosen config persisted to %s", CONFIG_PATH))
}

# ============================================================================
# 4. FINAL MODEL on the chosen config + walk-forward calibrated holdout
# ============================================================================
message("4. Final model on chosen config...")
HORIZON_DAYS <- choose$h; BUY_THR <- choose$buy; SELL_THR <- choose$sell; EMBARGO <- HORIZON_DAYS
labeled <- make_labeled(feat_train, HORIZON_DAYS, BUY_THR, SELL_THR) %>% filter(!is.na(fwd_ret))
max_date <- max(labeled$date); test_start <- max_date - TEST_DAYS; train_end <- test_start - EMBARGO
tb <- tune_best(labeled %>% filter(date <= train_end))
ev <- walkforward_eval(labeled, tb$wf, tb$best, train_end, test_start)

cat("\n============== BUY / HOLD / SELL  (multinomial logistic) ==============\n")
cat(sprintf("  Horizon %dd | buy>=+%.0f%% & pos<=%.2f | sell<=-%.0f%%\n",
            HORIZON_DAYS, 100*BUY_THR, LOW_POS, 100*SELL_THR))
cat(sprintf("  best penalty=%.4g mixture=%.2f | rolling-CV AUC=%.3f\n",
            tb$best$penalty, tb$best$mixture, tb$cv_auc))
cat(sprintf("  WALK-FORWARD holdout macro-AUC : %.3f\n", ev$auc))
cat(sprintf("  Calibrated Brier               : %.3f\n", ev$brier))
cat(sprintf("  Calibrated log-loss            : %.3f\n", ev$logloss))
cat("======================================================================\n\n")

cat("Calibration of P(buy) on walk-forward holdout (pred vs empirical):\n")
ev$pooled %>% mutate(bin = cut(.pred_buy, breaks = seq(0, 1, 0.1), include.lowest = TRUE)) %>%
  group_by(bin) %>% summarise(n = n(), mean_pred = round(mean(.pred_buy), 3),
            emp_buy = round(mean(label == "buy"), 3), .groups = "drop") %>%
  filter(n > 0) %>% print(n = 20)

# ============================================================================
# 5. SCORE THE MOST RECENT DAY FOR EVERY CARD (calibrated)
#    Deploy model is fit on all labeled history EXCEPT the last CAL_DAYS, whose
#    out-of-sample predictions fit the calibrator -- model + calibrator stay
#    consistent, and probabilities are clamped off 0/1 for stability.
# ============================================================================
message("\n5. Scoring latest day per card (calibrated)...")
cal_cut      <- max(labeled$date) - CAL_DAYS
deploy_model <- fit(finalize_workflow(tb$wf, tb$best), data = labeled %>% filter(date <= cal_cut))
cal_deploy   <- fit_calibrator(augment(deploy_model, labeled %>% filter(date > cal_cut)))

clamp_norm <- function(df) {  # keep each prob in [0.01, 0.98], renormalize -> no degenerate 0/1
  m <- as.matrix(df[c(".pred_buy", ".pred_hold", ".pred_sell")])
  m <- pmin(pmax(m, 0.01), 0.98); m <- m / rowSums(m)
  df$.pred_buy <- m[, 1]; df$.pred_hold <- m[, 2]; df$.pred_sell <- m[, 3]; df
}

score_df <- feat %>% group_by(card_id) %>% slice_max(date, n = 1) %>% ungroup() %>%
  select(card_id, name, date, all_of(PRED))
scored <- augment(deploy_model, score_df) %>% cal_apply(cal_deploy) %>% clamp_norm() %>%
  left_join(hist_tbl, by = "card_id") %>%
  transmute(card_id, name, score_date = date, horizon = HORIZON_DAYS,
            p_buy = round(.pred_buy, 3), p_hold = round(.pred_hold, 3), p_sell = round(.pred_sell, 3),
            call = c("buy", "hold", "sell")[max.col(cbind(.pred_buy, .pred_hold, .pred_sell))],
            hist_days, days_since_release = as.integer(days_since_release),
            is_new = !(card_id %in% train_ids))   # TRUE = outside training universe -> extrapolated

# today's decisiveness: how peaked the calls are (0.33 = coin-flip, 1 = certain)
avg_conf <- mean(pmax(scored$p_buy, scored$p_hold, scored$p_sell))
n_new    <- sum(scored$is_new)

write_csv(scored, "data/pytorch/buy_hold_sell_scores.csv")
cat(sprintf("\nScored %d cards (%d new / outside training universe) -> data/pytorch/buy_hold_sell_scores.csv (avg confidence %.1f%%)\n",
            nrow(scored), n_new, 100 * avg_conf))
cat("\nStrongest BUY signals right now:\n")
print(scored %>% arrange(desc(p_buy)) %>% select(name, p_buy, p_hold, p_sell, call, is_new) %>% head(10), n = 10)
cat("\nStrongest SELL signals right now:\n")
print(scored %>% arrange(desc(p_sell)) %>% select(name, p_buy, p_hold, p_sell, call, is_new) %>% head(10), n = 10)
if (n_new > 0) {
  cat("\nNEW-card calls (extrapolated -- treat with caution until outcomes accrue):\n")
  print(scored %>% filter(is_new) %>% arrange(desc(pmax(p_buy, p_sell))) %>%
        select(name, hist_days, days_since_release, p_buy, p_hold, p_sell, call) %>% head(15), n = 15)
}

# ============================================================================
# 6. PUSH TO MOTHERDUCK (idempotent per run_date)
# ============================================================================
if (PUSH) {
  message("\n6. Pushing scores to MotherDuck...")
  run_date <- Sys.Date()
  # Table schema unchanged: new cards are pushed alongside veterans (the extra
  # is_new/hist_days columns stay in the CSV). If you want the dashboard to flag
  # newer cards, join released_at / history there, or add an is_new column later.
  push_df <- scored %>% mutate(run_date = run_date) %>%
    select(run_date, score_date, card_id, name, horizon, p_buy, p_hold, p_sell, call)
  con <- dbConnect(duckdb::duckdb())
  dbExecute(con, "INSTALL motherduck; LOAD motherduck;")
  dbExecute(con, "ATTACH 'md:'"); dbExecute(con, "USE my_db;")
  dbExecute(con, "CREATE TABLE IF NOT EXISTS buy_hold_sell_scores (
      run_date DATE, score_date DATE, card_id VARCHAR, name VARCHAR, horizon INTEGER,
      p_buy DOUBLE, p_hold DOUBLE, p_sell DOUBLE, call VARCHAR)")
  dbExecute(con, sprintf("DELETE FROM buy_hold_sell_scores WHERE run_date = '%s'", run_date))
  duckdb::dbWriteTable(con, "buy_hold_sell_scores", push_df, append = TRUE)
  n <- dbGetQuery(con, sprintf("SELECT COUNT(*) n FROM buy_hold_sell_scores WHERE run_date='%s'", run_date))$n

  # --- model health metrics (one row per run) so the dashboard can show how the
  #     model is doing at a glance: discrimination (AUC), calibration (Brier),
  #     and today's decisiveness (avg_confidence). ---
  metrics_row <- data.frame(
    run_date = run_date, horizon = HORIZON_DAYS,
    auc = round(ev$auc, 3), brier = round(ev$brier, 3), logloss = round(ev$logloss, 3),
    cv_auc = round(tb$cv_auc, 3),
    buy_pct = round(100 * mean(labeled$label == "buy"), 1),
    sell_pct = round(100 * mean(labeled$label == "sell"), 1),
    hold_pct = round(100 * mean(labeled$label == "hold"), 1),
    n_examples = nrow(labeled), avg_confidence = round(avg_conf, 3)
  )
  dbExecute(con, "CREATE TABLE IF NOT EXISTS buy_hold_sell_metrics (
      run_date DATE, horizon INTEGER, auc DOUBLE, brier DOUBLE, logloss DOUBLE, cv_auc DOUBLE,
      buy_pct DOUBLE, sell_pct DOUBLE, hold_pct DOUBLE, n_examples INTEGER, avg_confidence DOUBLE)")
  dbExecute(con, sprintf("DELETE FROM buy_hold_sell_metrics WHERE run_date = '%s'", run_date))
  duckdb::dbWriteTable(con, "buy_hold_sell_metrics", metrics_row, append = TRUE)

  dbDisconnect(con, shutdown = TRUE)
  cat(sprintf("Pushed %d rows to buy_hold_sell_scores + metrics (AUC %.3f) for run_date %s.\n",
              n, ev$auc, run_date))
}
