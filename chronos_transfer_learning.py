import pandas as pd
import torch
import numpy as np
from chronos import ChronosPipeline
import os
import time
from tqdm import tqdm
from sqlalchemy import create_engine, text
import datetime
from dotenv import load_dotenv

# ==========================================
# 1. SETUP & AUTHENTICATION
# ==========================================
load_dotenv()
NEON_PASSWORD = os.getenv("NEON_PASSWORD")
if not NEON_PASSWORD:
    raise ValueError("⚠️ NEON_PASSWORD not found. Please check your .env file!")

NEON_HOST = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech"
DB_URL = f"postgresql://neondb_owner:{NEON_PASSWORD}@{NEON_HOST}/neondb?sslmode=require"
engine = create_engine(DB_URL)

if torch.backends.mps.is_available(): device = "mps"; print("🚀 Hardware: Apple Silicon GPU (MPS) detected.")
elif torch.cuda.is_available(): device = "cuda"; print("🚀 Hardware: NVIDIA GPU (CUDA) detected.")
else: device = "cpu"; print("⚠️ Hardware: GPU not found, using CPU.")

# ==========================================
# 2. LOAD MODEL & DATA
# ==========================================
print("Loading Chronos v1 Base Model (Optimized)...")
pipeline = ChronosPipeline.from_pretrained(
    "amazon/chronos-t5-base", 
    device_map=device, 
    torch_dtype=torch.bfloat16 # Half the RAM, same accuracy
)

print("Loading preprocessed prices...")
df = pd.read_csv('data/chronos_ready_prices.csv', parse_dates=['date'], dtype={'card_id': str})

prediction_length = 30
max_context_length = 256 
batch_size = 8 

# ==========================================
# 3. PREP TENSORS (FUTURE INFERENCE)
# ==========================================
print("Grouping data and preparing tensors...")
context_tensors = []
valid_card_ids = []

for cid, group in df.groupby('card_id'):
    group = group.sort_values('date')
    if len(group) < 180:
        continue
        
    # INFERENCE FIX: Grab the absolute latest data available to predict the future
    context_data = group.tail(max_context_length)
    prices = context_data['price'].values
    
    context_tensors.append(torch.tensor(prices, dtype=torch.float32))
    valid_card_ids.append(cid)

print(f"✅ Prep complete. {len(valid_card_ids)} cards found.")

# ==========================================
# 4. RUN BATCHED INFERENCE
# ==========================================
print(f"Starting batched inference (Batch size: {batch_size})...")
all_forecast_samples = []
start_infer = time.time()

for i in tqdm(range(0, len(context_tensors), batch_size)):
    batch = context_tensors[i : i + batch_size]
    
    with torch.no_grad():
        forecasts = pipeline.predict(batch, prediction_length)
        
    for f in forecasts:
        all_forecast_samples.append(f.cpu().numpy())
    
    if i % (batch_size * 10) == 0 and device == "mps":
        torch.mps.empty_cache()

print(f"✨ Inference complete in {time.time() - start_infer:.2f}s.")

# ==========================================
# 5. THE MISSING "TIDY" LOGIC
# ==========================================
print("Formatting forecasts and confidence intervals...")
rows = []
run_date = datetime.date.today()

for i, cid in enumerate(valid_card_ids):
    # samples shape is (num_samples, prediction_length)
    samples = all_forecast_samples[i] 
    
    # Calculate median and 80% confidence interval natively from Chronos output
    med = np.median(samples, axis=0)
    low = np.percentile(samples, 10, axis=0)
    high = np.percentile(samples, 90, axis=0)
    
    for day in range(prediction_length):
        rows.append({
            'card_id': cid,
            'run_date': run_date,
            'target_date': run_date + datetime.timedelta(days=day+1),
            'pred_price': med[day],
            'conf_low': low[day],
            'conf_high': high[day],
            'model': 'Chronos'
        })

final_chronos_df = pd.DataFrame(rows)

# Optional: Still save locally to GitHub Actions workspace just in case you want the CSV
os.makedirs('data/pytorch', exist_ok=True)
final_chronos_df.to_csv("data/pytorch/chronos_inference_latest.csv", index=False)

# ==========================================
# 6. NORMALIZED NEON DATABASE UPLOAD
# ==========================================
if final_chronos_df.empty:
    print("⚠️ No Chronos forecasts generated.")
else:
    print(f"☁️ Syncing Chronos results to Neon (Normalized Schema)...")
    
    # 1. Round prices and prep for database
    final_chronos_df['pred_price'] = final_chronos_df['pred_price'].round(2)
    final_chronos_df['conf_low'] = final_chronos_df['conf_low'].round(2)
    final_chronos_df['conf_high'] = final_chronos_df['conf_high'].round(2)

    with engine.connect() as conn:
        # A. Insert Metadata into 'model_runs' (Matches the GRU table)
        run_meta = {
            'run_date': datetime.date.today(),
            'window_size': 30, # Chronos is fixed at 30
            'model_type': 'Chronos'
        }
        
        # This will return the next available run_id
        res = conn.execute(
            text("INSERT INTO model_runs (run_date, window_size, model_type) VALUES (:run_date, :window_size, :model_type) RETURNING run_id"),
            run_meta
        )
        run_id = res.fetchone()[0]
        
        # B. Attach the run_id to predictions
        final_chronos_df['run_id'] = run_id
        
        # C. Push to a specific 'chronos_predictions' table
        # We keep the confidence intervals here since Chronos provides them!
        slim_chronos = final_chronos_df[['card_id', 'target_date', 'pred_price', 'conf_low', 'conf_high', 'run_id']]
        
        print(f"🚀 Pushing {len(slim_chronos)} rows to 'chronos_predictions' (Run ID: {run_id})...")
        slim_chronos.to_sql('chronos_predictions', engine, if_exists='append', index=False)
        
        conn.commit()
    print("✨ Chronos database sync complete.")