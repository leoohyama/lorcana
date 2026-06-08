import pandas as pd
import torch
import numpy as np
from chronos import ChronosPipeline
import os
import time
from tqdm import tqdm
import datetime
from dotenv import load_dotenv
import duckdb

# ==========================================
# 1. SETUP & AUTHENTICATION
# ==========================================
load_dotenv()
MD_TOKEN = os.getenv("MOTHERDUCK_TOKEN")
if not MD_TOKEN:
    raise ValueError("⚠️ MOTHERDUCK_TOKEN not found. Please check your .env file!")

# We will open the database connection right before we need it in Step 6 
# to avoid holding network connections open during long ML runs.

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
    if len(group) < 91:
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

os.makedirs('data/pytorch', exist_ok=True)
final_chronos_df.to_csv("data/pytorch/chronos_inference_latest.csv", index=False)

# ==========================================
# 6. NORMALIZED MOTHERDUCK DATABASE UPLOAD
# ==========================================
if final_chronos_df.empty:
    print("⚠️ No Chronos forecasts generated.")
else:
    print(f"☁️ Syncing Chronos results to MotherDuck...")
    
    # 1. Round prices and prep for database
    final_chronos_df['pred_price'] = final_chronos_df['pred_price'].round(2)
    final_chronos_df['conf_low'] = final_chronos_df['conf_low'].round(2)
    final_chronos_df['conf_high'] = final_chronos_df['conf_high'].round(2)

    # 2. Connect to the cloud database
    con = duckdb.connect(f"md:?motherduck_token={MD_TOKEN}")
    con.execute("USE my_db;")
    
    today_str = run_date.strftime('%Y-%m-%d')
    model_name = 'Chronos'
    
    # --- SMART IDEMPOTENT LOGIC ---
    # Check if we already have a run for today
    check_query = f"SELECT run_id FROM model_runs WHERE run_date = '{today_str}' AND model_type = '{model_name}'"
    existing_runs = con.execute(check_query).fetchall()

    if existing_runs:
        existing_ids = [str(r[0]) for r in existing_runs]
        existing_ids_str = ", ".join(existing_ids)
        print(f"⚠️ Found existing runs for today (Run IDs: {existing_ids_str}). Overwriting with fresh test data...")

        # Delete child predictions FIRST to prevent orphans
        con.execute(f"DELETE FROM chronos_predictions WHERE run_id IN ({existing_ids_str})")
        # Delete parent run record
        con.execute(f"DELETE FROM model_runs WHERE run_id IN ({existing_ids_str})")
        print("🗑️ Cleared old data for today.")
    # ------------------------------

    # A. Insert Metadata into 'model_runs' and grab the ID
    insert_meta_query = f"""
        INSERT INTO model_runs (run_date, window_size, model_type) 
        VALUES ('{today_str}', 30, '{model_name}') 
        RETURNING run_id
    """
    run_id = con.execute(insert_meta_query).fetchone()[0]
    
    # B. Attach the run_id to predictions
    final_chronos_df['run_id'] = run_id
    
    # C. Push to 'chronos_predictions' using DuckDB's native Pandas reader
    slim_chronos = final_chronos_df[['card_id', 'target_date', 'pred_price', 'conf_low', 'conf_high', 'run_id']]
    
    print(f"🚀 Pushing {len(slim_chronos)} rows to 'chronos_predictions' (Run ID: {run_id})...")
    
    # DuckDB automatically sees 'slim_chronos' in your local python variables
    con.execute("INSERT INTO chronos_predictions SELECT * FROM slim_chronos")
    
    con.close()
    print("✨ MotherDuck database sync complete. Data is pristine.")