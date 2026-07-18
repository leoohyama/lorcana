"""Shared helpers for Chronos-2 forecasting (daily inference + historical backfill).

The target is the TCG market price; eBay market-structure series (anchor_gap,
log_active, churn_rate, net_flow) ride along as past-only covariates. Chronos-2
tolerates NaN covariates, so the pre-eBay era needs no imputation.
"""
import datetime

import numpy as np
import pandas as pd

COVARIATES = ["anchor_gap", "log_active", "churn_rate", "net_flow"]
QUANTILE_LEVELS = [0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95]
PREDICTION_LENGTH = 30
MAX_CONTEXT_DAYS = 512
MIN_HISTORY_DAYS = 91
STACK_HORIZONS = [7, 14, 21, 30]
STACK_THRESHOLDS = [0.07, 0.10]


def load_prices(path="data/chronos_ready_prices.csv"):
    df = pd.read_csv(path, parse_dates=["date"], dtype={"card_id": str})
    return df.sort_values(["card_id", "date"])


def build_context(df, origin_date=None):
    """Long-format context frame ending at origin_date (inclusive).

    Returns (context_df, spot) where spot maps card_id -> price at origin.
    Cards with < MIN_HISTORY_DAYS of history by the origin are dropped.
    """
    if origin_date is not None:
        df = df[df["date"] <= pd.Timestamp(origin_date)]
    df = df.groupby("card_id").tail(MAX_CONTEXT_DAYS)
    counts = df.groupby("card_id")["date"].transform("size")
    df = df[counts >= MIN_HISTORY_DAYS]
    spot = df.groupby("card_id")["price"].last()
    ctx = df.rename(columns={"card_id": "id", "date": "timestamp", "price": "target"})
    return ctx[["id", "timestamp", "target"] + COVARIATES], spot


def forecast(pipeline, ctx_df):
    """Run Chronos-2 over all series in ctx_df; returns the long quantile frame."""
    return pipeline.predict_df(
        ctx_df,
        prediction_length=PREDICTION_LENGTH,
        quantile_levels=QUANTILE_LEVELS,
        id_column="id",
        timestamp_column="timestamp",
        target="target",
    )


def _prob_above(quantile_vals, levels, x):
    """P(X > x) from a discrete quantile curve, linearly interpolated on levels."""
    cdf = np.interp(x, quantile_vals, levels, left=levels[0] / 2, right=1 - (1 - levels[-1]) / 2)
    return float(np.clip(1.0 - cdf, 0.01, 0.99))


def stack_features(pred_df, spot, origin_date):
    """Per-card forecast summary features for the buy/hold/sell stacker.

    For each horizon h: expected h-day return (median forecast vs spot),
    forecast uncertainty (q90-q10 relative spread), and P(return beyond
    +/- each threshold) read off the quantile curve.
    """
    levels = np.array(QUANTILE_LEVELS)
    qcols = [str(q) for q in QUANTILE_LEVELS]
    rows = []
    for cid, grp in pred_df.groupby("id"):
        grp = grp.sort_values("timestamp").reset_index(drop=True)
        px0 = spot.get(cid)
        if px0 is None or px0 <= 0 or len(grp) < max(STACK_HORIZONS):
            continue
        for h in STACK_HORIZONS:
            q = grp.loc[h - 1, qcols].to_numpy(dtype=float)
            q = np.maximum.accumulate(q)  # enforce monotone quantiles
            med = q[qcols.index("0.5")]
            row = {
                "origin_date": origin_date,
                "card_id": cid,
                "horizon": h,
                "exp_ret": med / px0 - 1.0,
                "spread": (q[qcols.index("0.9")] - q[qcols.index("0.1")]) / px0,
            }
            for thr in STACK_THRESHOLDS:
                key = f"{int(thr * 100):02d}"
                row[f"p_up{key}"] = _prob_above(q, levels, px0 * (1 + thr))
                row[f"p_dn{key}"] = 1.0 - _prob_above(q, levels, px0 * (1 - thr))
            rows.append(row)
    return pd.DataFrame(rows).round(4)


def write_stack_features(con, feats_df):
    """Idempotent per-origin_date upsert into chronos_stack_features."""
    if feats_df.empty:
        return 0
    con.execute("""
        CREATE TABLE IF NOT EXISTS chronos_stack_features (
            origin_date DATE, card_id VARCHAR, horizon INTEGER,
            exp_ret DOUBLE, spread DOUBLE,
            p_up07 DOUBLE, p_dn07 DOUBLE, p_up10 DOUBLE, p_dn10 DOUBLE)
    """)
    origins = ", ".join(f"'{d}'" for d in feats_df["origin_date"].unique())
    con.execute(f"DELETE FROM chronos_stack_features WHERE origin_date IN ({origins})")
    cols = ["origin_date", "card_id", "horizon", "exp_ret", "spread",
            "p_up07", "p_dn07", "p_up10", "p_dn10"]
    push = feats_df[cols]  # noqa: F841 (registered with duckdb below)
    con.execute("INSERT INTO chronos_stack_features SELECT * FROM push")
    return len(push)
