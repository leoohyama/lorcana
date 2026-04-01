import pandas as pd
import torch
import numpy as np
from chronos import ChronosPipeline
import os
import time

print("🚀 Hardware: Apple Silicon GPU (MPS) detected.")
print("Loading Chronos v1 Large Model...")

pipeline = ChronosPipeline.from_pretrained(
    "amazon/chronos-t5-large", 
    device_map="mps", 
    torch_dtype=torch.float32  
)

df = pd.read_csv('data/chronos_ready_prices.csv', parse_dates=['date'], dtype={'card_id': str})

prediction_length = 30
max_context_length = 256
batch_size = 16

print("Grouping data and preparing tensors...")
start_prep = time.time()

context_tensors = []
actual_prices_list = []
valid_card_ids = []

for cid, group in df.groupby('card_id'):
    group = group.sort_values('date')
    if len(group) < 180:
        continue
        
    context_data = group.iloc[:-prediction_length] 
    actual_data = group.iloc[-prediction_length:]  
    
    if len(actual_data) != prediction_length:
        continue
        
    prices = context_data['price'].values[-max_context_length:]
    context_tensors.append(torch.tensor(prices, dtype=torch.float32))
    actual_prices_list.append(actual_data['price'].values)
    valid_card_ids.append(cid)

print(f"Prep complete in {time.time() - start_prep:.2f}s. {len(valid_card_ids)} valid cards found.")

print(f"Starting batched inference (Batch size: {batch_size})...")
start_infer = time.time()

all_forecast_samples = []

for i in range(0, len(context_tensors), batch_size):
    batch = context_tensors[i : i + batch_size]
    print(f"Processing batch {i//batch_size + 1}/{(len(context_tensors) + batch_size - 1)//batch_size}...")
    
    with torch.no_grad():
        forecasts = pipeline.predict(batch, prediction_length)
        
    for f in forecasts:
        # NOTE: Bug fix applied here. Keeping all samples for quantiles.
        all_forecast_samples.append(f.cpu().numpy())

print(f"Inference complete in {time.time() - start_infer:.2f}s.")

print("Building Tidy Export...")
results_list = []

for idx, cid in enumerate(valid_card_ids):
    samples = all_forecast_samples[idx]
    actual_prices = actual_prices_list[idx]
    
    low, median, high = np.quantile(samples, [0.1, 0.5, 0.9], axis=0)
    
    for day in range(prediction_length):
        results_list.append({
            'card_id': cid,
            'day_offset': day + 1,
            'actual_price': actual_prices[day],
            'pred_price': median[day],
            'conf_low': low[day],
            'conf_high': high[day],
            'model': 'Chronos' 
        })

tidy_df = pd.DataFrame(results_list)
output_path = 'data/chronos_forecast_tidy.csv'
os.makedirs(os.path.dirname(output_path), exist_ok=True)
tidy_df.to_csv(output_path, index=False)

print(f"✨ Process complete! Exported {len(tidy_df)} rows to {output_path}.")
