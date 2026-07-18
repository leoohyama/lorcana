"""One-time rolling-origin backfill of chronos_stack_features.

Re-forecasts history with the SAME Chronos-2 setup as daily inference so the
buy/hold/sell stacker trains on features distributed like the ones it will see
in production. Origins: weekly before eBay coverage begins (2026-03-25), daily
after. Leakage-safe: each origin's context is truncated at the origin date.

Resumable: origins already present in chronos_stack_features are skipped.
Run:  python pipeline/modeling/chronos2_backfill_features.py
"""
import datetime
import os
import time

import duckdb
import pandas as pd
import torch
from chronos import Chronos2Pipeline

from chronos2_common import (build_context, forecast, load_prices,
                             stack_features, write_stack_features)

EBAY_START = datetime.date(2026, 3, 25)

MD_TOKEN = os.getenv("MOTHERDUCK_TOKEN", "").strip()
if not MD_TOKEN:
    raise ValueError("MOTHERDUCK_TOKEN not found in environment.")

device = "mps" if torch.backends.mps.is_available() else (
    "cuda" if torch.cuda.is_available() else "cpu")
print(f"Hardware: {device}")
pipeline = Chronos2Pipeline.from_pretrained("amazon/chronos-2", device_map=device)

df = load_prices()

# Earliest origin: first date on which at least 20 cards clear the 91-day bar.
first_dates = df.groupby("card_id")["date"].min() + pd.Timedelta(days=91)
earliest = first_dates.sort_values().iloc[19].date()
yesterday = datetime.date.today() - datetime.timedelta(days=1)

origins = []
d = earliest
while d < EBAY_START:
    origins.append(d)
    d += datetime.timedelta(days=7)
d = EBAY_START
while d <= yesterday:
    origins.append(d)
    d += datetime.timedelta(days=1)

con = duckdb.connect(f"md:?motherduck_token={MD_TOKEN}")
con.execute("USE my_db;")
con.execute("""
    CREATE TABLE IF NOT EXISTS chronos_stack_features (
        origin_date DATE, card_id VARCHAR, horizon INTEGER,
        exp_ret DOUBLE, spread DOUBLE,
        p_up07 DOUBLE, p_dn07 DOUBLE, p_up10 DOUBLE, p_dn10 DOUBLE)
""")
done = {r[0] for r in con.execute(
    "SELECT DISTINCT origin_date FROM chronos_stack_features").fetchall()}
todo = [o for o in origins if o not in done]
print(f"{len(origins)} origins planned ({earliest} -> {yesterday}), "
      f"{len(done)} already present, {len(todo)} to run.")

t0 = time.time()
for i, origin in enumerate(todo, 1):
    ctx, spot = build_context(df, origin_date=origin)
    if ctx.empty:
        print(f"[{i}/{len(todo)}] {origin}: no eligible cards, skipping.")
        continue
    pred = forecast(pipeline, ctx)
    feats = stack_features(pred, spot, origin)
    n = write_stack_features(con, feats)
    if i % 10 == 0 or i == len(todo):
        rate = (time.time() - t0) / i
        print(f"[{i}/{len(todo)}] {origin}: {n} rows "
              f"({rate:.1f}s/origin, ~{rate * (len(todo) - i) / 60:.0f} min left)")

con.close()
print(f"Backfill complete in {(time.time() - t0) / 60:.1f} min.")
