import pandas as pd
import torch
import numpy as np
from chronos import ChronosPipeline
import os
import time
from tqdm import tqdm # Great for watching logs in GitHub Actions

print("🚀 Hardware: Apple Silicon GPU (MPS) detected.")
print("Loading Chronos v1 Base Model (Optimized)...")

# OPTIMIZATION: Use 'base' and 'bfloat16' to save massive amounts of RAM
pipeline = ChronosPipeline.from_pretrained(
    "amazon/chronos-t5-base", 
    device_map="mps", 
    torch_dtype=torch.bfloat16 # Half the RAM, same accuracy for this task
)

df = pd.read_csv('data/chronos_ready_prices.csv', parse_dates=['date'], dtype={'card_id': str})

prediction_length = 30
max_context_length = 256 # Transformers are O(n^2), 256 is a good sweet spot
batch_size = 8 # Lowered to prevent SSD swapping

print("Grouping data and preparing tensors...")
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

print(f"✅ Prep complete. {len(valid_card_ids)} cards found.")
print(f"Starting batched inference (Batch size: {batch_size})...")

all_forecast_samples = []
start_infer = time.time()

# Added a progress bar so you can see movement in the logs
for i in tqdm(range(0, len(context_tensors), batch_size)):
    batch = context_tensors[i : i + batch_size]
    
    with torch.no_grad():
        # Chronos handles the float32 -> bfloat16 conversion internally
        forecasts = pipeline.predict(batch, prediction_length)
        
    for f in forecasts:
        all_forecast_samples.append(f.cpu().numpy())
    
    # Optional: Clear MPS cache periodically to keep RAM fresh
    if i % (batch_size * 10) == 0:
        torch.mps.empty_cache()

print(f"✨ Inference complete in {time.time() - start_infer:.2f}s.")

# ... [The rest of your Tidy Export logic remains the same] ...