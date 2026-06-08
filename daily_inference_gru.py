import pandas as pd
import torch
import torch.nn as nn
import numpy as np
import datetime
import os
from dotenv import load_dotenv
import duckdb

# --- 1. CONFIG & AUTHENTICATION ---
load_dotenv()
MD_TOKEN = os.getenv("MOTHERDUCK_TOKEN")
if not MD_TOKEN:
    raise ValueError("⚠️ MOTHERDUCK_TOKEN not found. Please check your .env file!")

# TOGGLE YOUR ACTIVE MODEL HERE (15, 30, or 45)
ACTIVE_WINDOW = 15

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
        
        self.attention = nn.Sequential(
            nn.Linear(hidden_size, 64),
            nn.Tanh(),
            nn.Linear(64, 1)
        )
        
        self.emb_set = nn.Embedding(vocab_sizes[0], 4)
        self.emb_rarity = nn.Embedding(vocab_sizes[1], 8)
        self.emb_ink = nn.Embedding(vocab_sizes[2], 2)
        
        self.fc = nn.Sequential(
            nn.Linear(hidden_size + 16, 64), 
            nn.ReLU(), 
            nn.Dropout(0.5), 
            nn.Linear(64, pred_length)
        )
        
    def forward(self, x_d, x_ca, x_co):
        last_p = x_d[:, -1, 0].unsqueeze(1)
        
        out, _ = self.gru(x_d) 
        
        attn_weights = torch.softmax(self.attention(out), dim=1)
        context = torch.sum(attn_weights * out, dim=1)
        
        embs = torch.cat([
            self.emb_set(x_ca[:, 0]), 
            self.emb_rarity(x_ca[:, 1]), 
            self.emb_ink(x_ca[:, 2])
        ], dim=1)
        
        return last_p + (torch.tanh(self.fc(torch.cat([context, embs, x_co], dim=1))) * 0.1)

# --- 3. EXECUTION ---
if __name__ == "__main__":
    print(f"Initializing inference on {device}...")
    df = pd.read_csv(csv_path, dtype={'card_id': str}, low_memory=False)
    
    df['price_scaled'] = df.groupby('card_id')['price_scaled'].transform(lambda x: x.bfill().ffill()).fillna(0.5)
    for col in ['inkwell', 'cost_scaled', 'days_scaled']: 
        df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0)
    for col in ['set_idx', 'rarity_idx', 'ink_idx']: 
        df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0).astype(int)

    vocabs = [int(df[c].max() + 1) for c in ['set_idx', 'rarity_idx', 'ink_idx']]

    for seq_len in [ACTIVE_WINDOW]:
        print(f"Generating future forecasts for {seq_len}-day window...")
        weights_path = f'data/pytorch/lorcana_gru_weights_{seq_len}.pth'
        
        if not os.path.exists(weights_path):
            print(f"Weights not found at {weights_path}. Skipping.")
            continue

        model = HybridLorcanaGRU(vocabs).to(device)
        model.load_state_dict(torch.load(weights_path))
        model.eval()

        all_card_forecasts = []

        for card_id, group in df.groupby('card_id'):
            recent = group.sort_values('date').tail(seq_len)
            if len(recent) < seq_len: continue
            
            x_dyn = torch.tensor(np.column_stack((recent['price_scaled'].values, recent['days_scaled'].values)), dtype=torch.float32).unsqueeze(0).to(device)
            x_cat = torch.tensor(recent[['set_idx', 'rarity_idx', 'ink_idx']].iloc[0].values, dtype=torch.long).unsqueeze(0).to(device)
            x_cont = torch.tensor(recent[['cost_scaled', 'inkwell']].iloc[0].values, dtype=torch.float32).unsqueeze(0).to(device)
            
            pmin, pmax = recent['card_min_price'].iloc[0], recent['card_max_price'].iloc[0]
            
            with torch.no_grad():
                samples = []
                model.train() 
                for _ in range(50):
                    pred_scaled = model(x_dyn, x_cat, x_cont).cpu().numpy()[0]
                    samples.append(pred_scaled * (pmax - pmin) + pmin)
                
                med_pred = np.median(samples, axis=0)
                
            for day, price in enumerate(med_pred):
                all_card_forecasts.append({
                    'card_id': card_id,
                    'target_date': datetime.date.today() + datetime.timedelta(days=day+1),
                    'pred_price': round(float(price), 2) 
                })

        # --- 4. NORMALIZED MOTHERDUCK UPLOAD ---
        if all_card_forecasts:
            final_df = pd.DataFrame(all_card_forecasts)
            
            print(f"Syncing results to MotherDuck...")
            
            con = duckdb.connect(f"md:?motherduck_token={MD_TOKEN}")
            con.execute("USE my_db;")
            
            today_str = datetime.date.today().strftime('%Y-%m-%d')
            model_name = 'GRU'

            # 1. SMART IDEMPOTENT LOGIC WITH NULL HANDLING
            check_query = f"SELECT run_id FROM model_runs WHERE run_date = '{today_str}' AND model_type = '{model_name}'"
            existing_runs = con.execute(check_query).fetchall()

            if existing_runs:
                # Filter out the broken None/NULL values so they don't break the SQL query
                valid_ids = [str(r[0]) for r in existing_runs if r[0] is not None]
                
                if valid_ids:
                    existing_ids_str = ", ".join(valid_ids)
                    print(f"⚠️ Found existing runs for today (Run IDs: {existing_ids_str}). Overwriting with fresh test data...")
                    con.execute(f"DELETE FROM gru_predictions WHERE run_id IN ({existing_ids_str})")
                    con.execute(f"DELETE FROM model_runs WHERE run_id IN ({existing_ids_str})")
                
                # Automatically clean up the broken NULL run from the failed execution
                if any(r[0] is None for r in existing_runs):
                    con.execute(f"DELETE FROM model_runs WHERE run_date = '{today_str}' AND model_type = '{model_name}' AND run_id IS NULL")
                    print("🗑️ Cleared orphaned NULL runs from the database.")
            
            # 2. BULLETPROOF INSERT USING COALESCE
            # This completely bypasses the broken table sequence and generates a valid integer
            insert_meta_query = f"""
                INSERT INTO model_runs (run_id, run_date, window_size, model_type) 
                VALUES ((SELECT COALESCE(MAX(run_id), 0) + 1 FROM model_runs), '{today_str}', {seq_len}, '{model_name}') 
                RETURNING run_id
            """
            run_id = con.execute(insert_meta_query).fetchone()[0] 
            
            # 3. Attach the run_id to predictions
            final_df['run_id'] = run_id
            
            # 4. Push to 'gru_predictions'
            print(f"🚀 Pushing {len(final_df)} predictions for Run ID: {run_id}")
            con.execute("INSERT INTO gru_predictions SELECT * FROM final_df")
            
            con.close()
            print(f"{seq_len}-day window complete. MotherDuck Sync successful.")
        else:
            print("No card data met the minimum length requirements for inference.")

    print("All tasks finished successfully.")