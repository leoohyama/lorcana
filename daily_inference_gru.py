import pandas as pd
import torch
import torch.nn as nn
import numpy as np
from sqlalchemy import create_engine, text
import datetime
import os
from dotenv import load_dotenv

# --- 1. CONFIG & AUTHENTICATION ---
load_dotenv()
NEON_PASSWORD = os.getenv("NEON_PASSWORD")
NEON_HOST = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech"
DB_URL = f"postgresql://neondb_owner:{NEON_PASSWORD}@{NEON_HOST}/neondb?sslmode=require"
engine = create_engine(DB_URL)

# Use your M4 Max power
if torch.backends.mps.is_available(): 
    device = torch.device("mps")
elif torch.cuda.is_available(): 
    device = torch.device("cuda")
else: 
    device = torch.device("cpu")

csv_path = "data/pytorch/lorcana_pytorch_ready.csv"

# --- 2. MODEL ARCHITECTURE ---
class HybridLorcanaGRU(nn.Module):
    def __init__(self, vocab_sizes, pred_length=30, hidden_size=128, num_layers=2):
        super().__init__()
        self.gru = nn.GRU(2, hidden_size, num_layers, batch_first=True, dropout=0.4)
        self.emb_set = nn.Embedding(vocab_sizes[0], 4)
        self.emb_rarity = nn.Embedding(vocab_sizes[1], 8)
        self.emb_ink = nn.Embedding(vocab_sizes[2], 2)
        # 16 = 4(set) + 8(rarity) + 2(ink) + 2(cost/inkwell)
        self.fc = nn.Sequential(
            nn.Linear(hidden_size + 16, 64), 
            nn.ReLU(), 
            nn.Dropout(0.5), 
            nn.Linear(64, pred_length)
        )
        
    def forward(self, x_d, x_ca, x_co):
        last_p = x_d[:, -1, 0].unsqueeze(1)
        _, h = self.gru(x_d)
        embs = torch.cat([
            self.emb_set(x_ca[:, 0]), 
            self.emb_rarity(x_ca[:, 1]), 
            self.emb_ink(x_ca[:, 2])
        ], dim=1)
        # h[-1] is the final hidden state
        return last_p + (torch.tanh(self.fc(torch.cat([h[-1], embs, x_co], dim=1))) * 0.1)

# --- 3. EXECUTION ---
if __name__ == "__main__":
    print(f"🚀 Initializing inference on {device}...")
    df = pd.read_csv(csv_path, dtype={'card_id': str}, low_memory=False)
    
    # Apply the Antidote for data cleaning
    df['price_scaled'] = df.groupby('card_id')['price_scaled'].transform(lambda x: x.bfill().ffill()).fillna(0.5)
    for col in ['inkwell', 'cost_scaled', 'days_scaled']: 
        df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0)
    for col in ['set_idx', 'rarity_idx', 'ink_idx']: 
        df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0).astype(int)

    vocabs = [int(df[c].max() + 1) for c in ['set_idx', 'rarity_idx', 'ink_idx']]

    # We are focusing on the 30-day window
    for seq_len in [30]:
        print(f"🔮 Generating future forecasts for {seq_len}-day window...")
        weights_path = f'data/pytorch/lorcana_gru_weights_{seq_len}.pth'
        
        if not os.path.exists(weights_path):
            print(f"⚠️ Weights not found at {weights_path}. Skipping.")
            continue

        model = HybridLorcanaGRU(vocabs).to(device)
        model.load_state_dict(torch.load(weights_path))
        model.eval()

        all_card_forecasts = []

        # Predict into the future
        for card_id, group in df.groupby('card_id'):
            recent = group.sort_values('date').tail(seq_len)
            if len(recent) < seq_len: continue
            
            x_dyn = torch.tensor(np.column_stack((recent['price_scaled'].values, recent['days_scaled'].values)), dtype=torch.float32).unsqueeze(0).to(device)
            x_cat = torch.tensor(recent[['set_idx', 'rarity_idx', 'ink_idx']].iloc[0].values, dtype=torch.long).unsqueeze(0).to(device)
            x_cont = torch.tensor(recent[['cost_scaled', 'inkwell']].iloc[0].values, dtype=torch.float32).unsqueeze(0).to(device)
            
            pmin, pmax = recent['card_min_price'].iloc[0], recent['card_max_price'].iloc[0]
            
            with torch.no_grad():
                samples = []
                model.train() # Monte Carlo Dropout for uncertainty
                for _ in range(50):
                    # BUG FIX: passing x_cont instead of the old x_co
                    pred_scaled = model(x_dyn, x_cat, x_cont).cpu().numpy()[0]
                    samples.append(pred_scaled * (pmax - pmin) + pmin)
                
                med_pred = np.median(samples, axis=0)
                
            for day, price in enumerate(med_pred):
                all_card_forecasts.append({
                    'card_id': card_id,
                    'target_date': datetime.date.today() + datetime.timedelta(days=day+1),
                    'pred_price': round(float(price), 2) # SLIMMED: 2 decimal places
                })

        # --- 4. NORMALIZED DATABASE UPLOAD (SMART APPEND) ---
        if all_card_forecasts:
            final_df = pd.DataFrame(all_card_forecasts)
            
            print(f"☁️ Syncing results to Neon (Normalized Schema)...")
            with engine.connect() as conn:
                # Ensure the table exists first
                conn.execute(text("""
                    CREATE TABLE IF NOT EXISTS model_runs (
                        run_id SERIAL PRIMARY KEY,
                        run_date DATE,
                        window_size INTEGER,
                        model_type TEXT
                    )
                """))
                conn.commit()
                
                today_date = datetime.date.today()
                model_name = 'GRU'

                # --- SMART IDEMPOTENT LOGIC ---
                # Check if we already have a run for today
                check_query = text("""
                    SELECT run_id FROM model_runs 
                    WHERE run_date = :run_date AND model_type = :model_type
                """)
                existing_runs = conn.execute(check_query, {'run_date': today_date, 'model_type': model_name}).fetchall()

                if existing_runs:
                    existing_ids = [str(r[0]) for r in existing_runs]
                    existing_ids_str = ", ".join(existing_ids)
                    print(f"⚠️ Found existing runs for today (Run IDs: {existing_ids_str}). Overwriting with fresh test data...")

                    # Delete child predictions FIRST to prevent orphans
                    conn.execute(text(f"DELETE FROM gru_predictions WHERE run_id IN ({existing_ids_str})"))
                    # Delete parent run record
                    conn.execute(text(f"DELETE FROM model_runs WHERE run_id IN ({existing_ids_str})"))
                    conn.commit()
                    print("🗑️ Cleared old data for today.")
                # ------------------------------
                
                # A. Create and Insert Metadata (The Header)
                run_meta = {
                    'run_date': today_date,
                    'window_size': seq_len,
                    'model_type': model_name
                }
                
                res = conn.execute(
                    text("INSERT INTO model_runs (run_date, window_size, model_type) VALUES (:run_date, :window_size, :model_type) RETURNING run_id"),
                    run_meta
                )
                run_id = res.fetchone()[0] # This is your model_identifier
                
                # B. Attach the run_id to every prediction (The Detail)
                final_df['run_id'] = run_id
                
                print(f"🚀 Pushing {len(final_df)} predictions for Run ID: {run_id}")
                final_df.to_sql('gru_predictions', engine, if_exists='append', index=False)
                
                conn.commit() 
            print(f"✨ 30-day window complete. Neon Sync successful. Data is pristine.")
        else:
            print("⚠️ No card data met the minimum length requirements for inference.")

    print("🎉 All tasks finished successfully.")