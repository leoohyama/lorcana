import pandas as pd
import torch
import numpy as np
from chronos import ChronosPipeline # Back to the stable v1 pipeline!
import os

# ==========================================
# 1. SETUP (Chronos v1 API)
# ==========================================
print("🚀 Hardware: Apple Silicon GPU (MPS) detected.")
print("Loading Chronos v1 Large Model...")

pipeline = ChronosPipeline.from_pretrained(
    "amazon/chronos-t5-large", # The most powerful v1 model
    device_map="mps", 
    torch_dtype=torch.float32  
)

# Load Data
df = pd.read_csv('data/chronos_ready_prices.csv', parse_dates=['date'], dtype={'card_id': str})

prediction_length = 30
results_list = []
all_card_ids = df['card_id'].unique()

print(f"Starting Tidy batch processing for {len(all_card_ids)} cards...")

# ==========================================
# 2. THE BATCH LOOP
# ==========================================
for cid in all_card_ids:
    card_data = df[df['card_id'] == cid].sort_values('date')
    
    # 180-Day Filter
    if len(card_data) < 180:
        continue
    
    # Split for backtesting
    context_data = card_data.iloc[:-prediction_length] 
    actual_data = card_data.iloc[-prediction_length:]  
    
    if len(actual_data) != prediction_length:
        continue
    
    # ----------------------------------------------------
    # FORECAST GENERATION (The Clean v1 Way)
    # ----------------------------------------------------
    # V1 accepts a simple 1D array of prices. No reshaping required!
    context_tensor = torch.tensor(context_data['price'].values)
    
    with torch.no_grad():
        forecast = pipeline.predict(context_tensor, prediction_length)
    
    # V1 returns a single tensor. Grab the first index and convert to NumPy.
    forecast_samples = forecast[0].cpu().numpy()
    
    # Extract median and 80% confidence intervals
    low, median, high = np.quantile(forecast_samples, [0.1, 0.5, 0.9], axis=0)
    actual_prices = actual_data['price'].values
    
    # ----------------------------------------------------
    # BUILD THE TIDY FORMAT
    # ----------------------------------------------------
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

# ==========================================
# 3. EXPORT
# ==========================================
tidy_df = pd.DataFrame(results_list)
output_path = 'data/chronos_forecast_tidy.csv'
os.makedirs(os.path.dirname(output_path), exist_ok=True)
tidy_df.to_csv(output_path, index=False)

print(f"\n✨ Process complete! Exported {len(tidy_df)} rows to {output_path}.")