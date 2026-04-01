import pandas as pd
import torch
import numpy as np
from chronos import ChronosPipeline
import datetime
import os

# --- SETUP ---
device = "mps" if torch.backends.mps.is_available() else "cpu"
print("Loading Chronos for Backtest Diagnostics...")
pipeline = ChronosPipeline.from_pretrained("amazon/chronos-t5-base", device_map=device, torch_dtype=torch.bfloat16)

df = pd.read_csv('data/chronos_ready_prices.csv', parse_dates=['date'], dtype={'card_id': str})

prediction_length = 30
max_context = 256
batch_size = 8
context_tensors, valid_card_ids, target_dates_list = [], [], []

print("Preparing Tensors (Hiding the last 30 days)...")
for cid, group in df.groupby('card_id'):
    group = group.sort_values('date')
    if len(group) < 180: continue
    
    # 🛑 HIDE THE LAST 30 DAYS FOR BACKTESTING
    history = group.iloc[:-prediction_length]
    future = group.iloc[-prediction_length:] # The actual past dates we are evaluating
    
    if len(future) != prediction_length: continue
        
    context_tensors.append(torch.tensor(history.tail(max_context)['price'].values, dtype=torch.float32))
    valid_card_ids.append(cid)
    target_dates_list.append(future['date'].dt.date.values)

print(f"✅ Found {len(valid_card_ids)} cards. Starting inference...")

# --- INFERENCE ---
all_forecast_samples = []
for i in range(0, len(context_tensors), batch_size):
    batch = context_tensors[i : i + batch_size]
    with torch.no_grad():
        forecasts = pipeline.predict(batch, prediction_length)
    for f in forecasts: all_forecast_samples.append(f.cpu().numpy())

# --- SAVE TIDY DIAGNOSTIC CSV ---
print("Formatting Backtest Output...")
rows = []
for i, cid in enumerate(valid_card_ids):
    samples = all_forecast_samples[i]
    med, low, high = np.median(samples, 0), np.percentile(samples, 10, 0), np.percentile(samples, 90, 0)
    card_dates = target_dates_list[i]
    run_date = card_dates[0] - datetime.timedelta(days=1)
    
    for day in range(prediction_length):
        rows.append({
            'card_id': cid,
            'run_date': run_date,
            'target_date': card_dates[day], # Real historical dates
            'pred_price': round(float(med[day]), 2),
            'conf_low': round(float(low[day]), 2),
            'conf_high': round(float(high[day]), 2),
            'model': 'Chronos'
        })

final_chronos_df = pd.DataFrame(rows)
os.makedirs('data/pytorch', exist_ok=True)

# THIS is the file the R Script needs for Apple-to-Apples comparison!
final_chronos_df.to_csv("data/pytorch/chronos_forecast_tidy.csv", index=False)
print("✨ Chronos Diagnostic CSV saved! Ready for R Script.")