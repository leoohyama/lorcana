import pandas as pd
import torch
import numpy as np
from chronos import ChronosPipeline
import os

# 1. HARDWARE SELECTION (M4 Max Support)
if torch.backends.mps.is_available():
    device = "mps"
    print("🚀 Hardware: Apple Silicon GPU (MPS) detected.")
elif torch.cuda.is_available():
    device = "cuda"
    print("🚀 Hardware: NVIDIA GPU (CUDA) detected.")
else:
    device = "cpu"
    print("⚠️ Hardware: GPU not found, using CPU.")

# 2. LOAD CHRONOS
print("Loading Chronos Zero-Shot Model...")
pipeline = ChronosPipeline.from_pretrained(
    "amazon/chronos-t5-small",
    device_map=device,
    # MPS occasionally has issues with bfloat16, using float32 is safer for Macs
    torch_dtype=torch.float32 if device == "mps" else torch.bfloat16,
)

# 3. LOAD DATA
# Make sure to read card_id as a string to match TCGPlayer IDs!
df = pd.read_csv('data/chronos_ready_prices.csv', parse_dates=['date'], dtype={'card_id': str})

prediction_length = 30
results_list = []
all_card_ids = df['card_id'].unique()

print(f"Starting Tidy batch processing for {len(all_card_ids)} cards...")

# 4. THE BATCH LOOP
for cid in all_card_ids:
    card_data = df[df['card_id'] == cid].sort_values('date')
    
    # EXACT GRU MATCH: The 180-Day Filter
    if len(card_data) < 180:
        continue
    
    # SPLIT: Hide the last 30 days for testing
    context_data = card_data.iloc[:-prediction_length] 
    actual_data = card_data.iloc[-prediction_length:]  
    
    # Safety check
    if len(actual_data) != prediction_length:
        continue
    
    # 5. GENERATE ZERO-SHOT FORECAST
    # Chronos expects the context as a tensor
    context_tensor = torch.tensor(context_data['price'].values)
    forecast = pipeline.predict(context_tensor, prediction_length)
    
    # Extract median and 80% confidence intervals (10th and 90th percentiles)
    low, median, high = np.quantile(forecast[0].numpy(), [0.1, 0.5, 0.9], axis=0)
    actual_prices = actual_data['price'].values
    
    # 6. BUILD THE TIDY FORMAT (30 rows per card)
    for day in range(prediction_length):
        results_list.append({
            'card_id': cid,
            'day_offset': day + 1,
            'actual_price': actual_prices[day],
            'pred_price': median[day],
            'conf_low': low[day],
            'conf_high': high[day],
            'model': 'Chronos' # Tagging this so we can split it in ggplot
        })

# 7. EXPORT TO CSV
tidy_df = pd.DataFrame(results_list)

output_path = 'data/chronos_forecast_tidy.csv'
os.makedirs(os.path.dirname(output_path), exist_ok=True)
tidy_df.to_csv(output_path, index=False)

print(f"\n✨ Process complete! Exported {len(tidy_df)} rows to '{output_path}'.")