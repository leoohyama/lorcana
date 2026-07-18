"""Weekly Chronos-2 backtest: hide the last 30 days, re-forecast them with the
same setup as production inference (TCG target + eBay covariates), and save the
tidy CSV the diagnostics R script compares against actuals."""
import os

import pandas as pd
import torch
from chronos import Chronos2Pipeline

from chronos2_common import PREDICTION_LENGTH, build_context, forecast, load_prices

device = "mps" if torch.backends.mps.is_available() else (
    "cuda" if torch.cuda.is_available() else "cpu")
print("Loading Chronos-2 for Backtest Diagnostics...")
pipeline = Chronos2Pipeline.from_pretrained("amazon/chronos-2", device_map=device)

df = load_prices()
last_date = df["date"].max()
cutoff = last_date - pd.Timedelta(days=PREDICTION_LENGTH)

print(f"Hiding {PREDICTION_LENGTH} days after {cutoff.date()}...")
ctx, spot = build_context(df, origin_date=cutoff)
print(f"{ctx['id'].nunique()} cards found. Starting inference...")

pred = forecast(pipeline, ctx)

out = pred.rename(columns={"id": "card_id", "timestamp": "target_date"})
out["target_date"] = pd.to_datetime(out["target_date"]).dt.date
out["run_date"] = cutoff.date()
out["pred_price"] = out["0.5"].round(2)
out["conf_low"] = out["0.1"].round(2)
out["conf_high"] = out["0.9"].round(2)
out["model"] = "Chronos"
out = out[["card_id", "run_date", "target_date", "pred_price",
           "conf_low", "conf_high", "model"]]

os.makedirs("data/pytorch", exist_ok=True)

# THIS is the file the R script needs for apples-to-apples comparison!
out.to_csv("data/pytorch/chronos_forecast_tidy.csv", index=False)
print(f"Chronos-2 diagnostic CSV saved ({len(out)} rows). Ready for R script.")
