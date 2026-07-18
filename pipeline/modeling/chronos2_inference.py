"""Daily Chronos-2 inference on TCG prices with eBay market-structure covariates.

Replaces chronos_transfer_learning.py (Chronos v1, univariate). Outputs:
  1. chronos_predictions (+ model_runs row) -- same schema as before, so the
     dashboard fan charts and residual tracking keep working unchanged.
  2. chronos_stack_features -- today's forecast summary features consumed by
     the buy/hold/sell multinomial (the stacking layer).
"""
import datetime
import os
import time

import duckdb
import torch
from chronos import Chronos2Pipeline

from chronos2_common import (PREDICTION_LENGTH, build_context, forecast,
                             load_prices, stack_features, write_stack_features)

MD_TOKEN = os.getenv("MOTHERDUCK_TOKEN", "").strip()
if not MD_TOKEN:
    raise ValueError("MOTHERDUCK_TOKEN not found in environment.")

if torch.backends.mps.is_available():
    device = "mps"
elif torch.cuda.is_available():
    device = "cuda"
else:
    device = "cpu"
print(f"Hardware: {device}")

print("Loading Chronos-2...")
pipeline = Chronos2Pipeline.from_pretrained("amazon/chronos-2", device_map=device)

print("Building context (TCG target + eBay covariates)...")
df = load_prices()
ctx, spot = build_context(df)
n_cards = ctx["id"].nunique()
print(f"{n_cards} cards ready.")

t0 = time.time()
pred = forecast(pipeline, ctx)
print(f"Inference complete in {time.time() - t0:.1f}s.")

run_date = datetime.date.today()

# --- 1. Fan-chart table (schema-compatible with the old Chronos v1 output) ---
fan = pred.rename(columns={"id": "card_id", "timestamp": "target_date"})
fan["pred_price"] = fan["0.5"].round(2)
fan["conf_low"] = fan["0.1"].round(2)
fan["conf_high"] = fan["0.9"].round(2)
fan = fan[["card_id", "target_date", "pred_price", "conf_low", "conf_high"]]

os.makedirs("data/pytorch", exist_ok=True)
fan.assign(run_date=run_date, model="Chronos").to_csv(
    "data/pytorch/chronos_inference_latest.csv", index=False)

# --- 2. Stacking features for the buy/hold/sell model ---
feats = stack_features(pred, spot, run_date)
print(f"Stack features: {len(feats)} rows ({feats['card_id'].nunique()} cards).")

# --- 3. Push both to MotherDuck (idempotent per run_date) ---
print("Syncing to MotherDuck...")
con = duckdb.connect(f"md:?motherduck_token={MD_TOKEN}")
con.execute("USE my_db;")

today_str = run_date.strftime("%Y-%m-%d")
model_name = "Chronos"

existing = con.execute(
    f"SELECT run_id FROM model_runs WHERE run_date = '{today_str}' AND model_type = '{model_name}'"
).fetchall()
if existing:
    valid_ids = [str(r[0]) for r in existing if r[0] is not None]
    if valid_ids:
        ids = ", ".join(valid_ids)
        print(f"Overwriting existing runs for today (run_ids: {ids}).")
        con.execute(f"DELETE FROM chronos_predictions WHERE run_id IN ({ids})")
        con.execute(f"DELETE FROM model_runs WHERE run_id IN ({ids})")
    if any(r[0] is None for r in existing):
        con.execute(f"DELETE FROM model_runs WHERE run_date = '{today_str}' "
                    f"AND model_type = '{model_name}' AND run_id IS NULL")

run_id = con.execute(f"""
    INSERT INTO model_runs (run_id, run_date, window_size, model_type)
    VALUES ((SELECT COALESCE(MAX(run_id), 0) + 1 FROM model_runs),
            '{today_str}', {PREDICTION_LENGTH}, '{model_name}')
    RETURNING run_id
""").fetchone()[0]

fan_push = fan.assign(run_id=run_id)  # noqa: F841
con.execute("INSERT INTO chronos_predictions SELECT * FROM fan_push")
print(f"Pushed {len(fan)} forecast rows (run_id {run_id}).")

n_feat = write_stack_features(con, feats)
print(f"Pushed {n_feat} stack-feature rows for origin {today_str}.")

con.close()
print("MotherDuck sync complete.")
