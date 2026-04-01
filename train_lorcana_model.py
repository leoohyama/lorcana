import pandas as pd
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import os
import gc
import datetime

# Set seeds for reproducibility
torch.manual_seed(42)
np.random.seed(42)

# 1. HARDWARE SELECTION
if torch.backends.mps.is_available(): device = torch.device("mps"); print("🚀 Hardware: Apple Silicon GPU (MPS) detected.")
elif torch.cuda.is_available(): device = torch.device("cuda"); print("🚀 Hardware: NVIDIA GPU (CUDA) detected.")
else: device = torch.device("cpu"); print("⚠️ Hardware: GPU not found, using CPU.")

# 2. EARLY STOPPING
class EarlyStopping:
    def __init__(self, patience=15, path='data/pytorch/lorcana_gru_weights.pth'): 
        self.patience = patience; self.path = path; self.counter = 0; self.best_loss = None; self.early_stop = False
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
    def __call__(self, val_loss, model):
        if self.best_loss is None: self.best_loss = val_loss; self.save_checkpoint(model)
        elif val_loss >= self.best_loss:
            self.counter += 1; print(f"EarlyStopping counter: {self.counter} of {self.patience}")
            if self.counter >= self.patience: self.early_stop = True
        else: self.best_loss = val_loss; self.save_checkpoint(model); self.counter = 0
    def save_checkpoint(self, model): torch.save(model.state_dict(), self.path); print(f"✅ Validation improvement. Model saved to {self.path}")

# 3. DATASET DEFINITION (With Date Tracking)
class LorcanaDataset(Dataset):
    def __init__(self, csv_file, seq_length=30, pred_length=30, split='train'):
        df = pd.read_csv(csv_file, dtype={'card_id': str}, low_memory=False)
        
        # Ensure date is a proper datetime object
        df['date'] = pd.to_datetime(df['date'])
        
        # 🧹 THE ANTIDOTE
        df['price_scaled'] = df.groupby('card_id')['price_scaled'].transform(lambda x: x.bfill().ffill()).fillna(0.5)
        for col in ['inkwell', 'cost_scaled', 'days_scaled']:
            df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0)
        for col in ['set_idx', 'rarity_idx', 'ink_idx']:
            df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0).astype(int)

        self.split = split
        self.X_dynamic, self.X_cat, self.X_cont, self.y = [], [], [], []
        self.mins, self.maxs, self.card_ids, self.target_dates = [], [], [], []
        
        for card_id, group in df.groupby('card_id'):
            group = group.sort_values('date')
            if len(group) < 180: continue
            
            # The Split Logic
            if split == 'test': sub_group = group.tail(seq_length + pred_length)
            elif split == 'val': sub_group = group.iloc[-(seq_length + pred_length + 20) : -20]
            else: sub_group = group.iloc[:-40]
            
            if len(sub_group) < (seq_length + pred_length): continue
                
            prices, days = sub_group['price_scaled'].values, sub_group['days_scaled'].values
            static_cat = sub_group[['set_idx', 'rarity_idx', 'ink_idx']].iloc[0].values
            static_cont = sub_group[['cost_scaled', 'inkwell']].iloc[0].values
            c_min, c_max = sub_group['card_min_price'].iloc[0], sub_group['card_max_price'].iloc[0]
            
            # Convert dates to Unix timestamps (floats) so PyTorch can handle them easily in the DataLoader
            dates = sub_group['date'].apply(lambda x: x.timestamp()).values
            
            for i in range(len(sub_group) - seq_length - pred_length + 1):
                dyn = np.column_stack((prices[i:i+seq_length], days[i:i+seq_length]))
                if self.split == 'train': dyn[:, 0] += np.random.normal(0, 0.001, seq_length)
                
                self.X_dynamic.append(dyn)
                self.y.append(prices[i+seq_length : i+seq_length+pred_length])
                self.X_cat.append(static_cat)
                self.X_cont.append(static_cont)
                self.mins.append(c_min)
                self.maxs.append(c_max)
                self.card_ids.append(card_id)
                # Capture the actual historical dates we are predicting
                self.target_dates.append(dates[i+seq_length : i+seq_length+pred_length])

        self.X_dynamic = torch.tensor(np.array(self.X_dynamic), dtype=torch.float32)
        self.X_cat = torch.tensor(np.array(self.X_cat), dtype=torch.long)
        self.X_cont = torch.tensor(np.array(self.X_cont), dtype=torch.float32)
        self.y = torch.tensor(np.array(self.y), dtype=torch.float32)
        self.mins = torch.tensor(np.array(self.mins), dtype=torch.float32)
        self.maxs = torch.tensor(np.array(self.maxs), dtype=torch.float32)
        self.target_dates = torch.tensor(np.array(self.target_dates), dtype=torch.float64) # Float64 for timestamps
        
        print(f"Dataset {split.upper()} ready: {len(self.y)} sequences.")

    def __len__(self): return len(self.y)
    # Return 8 items now, including the target dates
    def __getitem__(self, idx): return (self.X_dynamic[idx], self.X_cat[idx], self.X_cont[idx], self.y[idx], self.mins[idx], self.maxs[idx], self.card_ids[idx], self.target_dates[idx])

# 4. ARCHITECTURE
class HybridLorcanaGRU(nn.Module):
    def __init__(self, vocab_sizes, pred_length=30, hidden_size=128, num_layers=2):
        super().__init__()
        self.gru = nn.GRU(2, hidden_size, num_layers, batch_first=True, dropout=0.4)
        self.emb_set = nn.Embedding(vocab_sizes[0], 4); self.emb_rarity = nn.Embedding(vocab_sizes[1], 8); self.emb_ink = nn.Embedding(vocab_sizes[2], 2)
        self.fc = nn.Sequential(nn.Linear(hidden_size + 16, 64), nn.ReLU(), nn.Dropout(0.5), nn.Linear(64, pred_length))
        
    def forward(self, x_d, x_ca, x_co):
        last_p = x_d[:, -1, 0].unsqueeze(1)
        _, h = self.gru(x_d); embs = torch.cat([self.emb_set(x_ca[:, 0]), self.emb_rarity(x_ca[:, 1]), self.emb_ink(x_ca[:, 2])], dim=1)
        return last_p + (torch.tanh(self.fc(torch.cat([h[-1], embs, x_co], dim=1))) * 0.1)

# 5. DIAGNOSTIC CSV GENERATOR (HISTORICAL DATES)
def generate_tidy_csv(model, dataloader, device, model_label, num_samples=100):
    model.train() # Keeping train() active for MC Dropout variance!
    rows = []
    
    with torch.no_grad():
        # Dataloader now provides 8 items, including t_dates
        for x_d, x_ca, x_co, y, pmin, pmax, cids, t_dates in dataloader:
            x_d, x_ca, x_co, y = x_d.to(device), x_ca.to(device), x_co.to(device), y.to(device)
            
            samples = []
            for _ in range(num_samples):
                p_usd = model(x_d, x_ca, x_co) * (pmax.to(device).unsqueeze(1) - pmin.to(device).unsqueeze(1)) + pmin.to(device).unsqueeze(1)
                samples.append(p_usd.cpu().numpy())
            
            med, low, high = np.median(samples, 0), np.percentile(samples, 10, 0), np.percentile(samples, 90, 0)
            
            for i in range(len(cids)):
                # Convert the Unix timestamps back to pandas Datetime objects
                card_dates = pd.to_datetime(t_dates[i].cpu().numpy(), unit='s')
                
                # The run date is logically the day before the first target date
                run_date = card_dates[0].date() - datetime.timedelta(days=1)
                
                for day in range(30):
                    rows.append({
                        'card_id': cids[i], 
                        'run_date': run_date,
                        'target_date': card_dates[day].date(), # The actual day the model was tested on!
                        'pred_price': round(float(med[i, day]), 2), 
                        'conf_low': round(float(low[i, day]), 2), 
                        'conf_high': round(float(high[i, day]), 2),
                        'model': model_label
                    })
    return pd.DataFrame(rows)

# 6. RUN PIPELINE
if __name__ == "__main__":
    csv_path = "data/pytorch/lorcana_pytorch_ready.csv"
    temp_df = pd.read_csv(csv_path, low_memory=False)
    for col in ['set_idx', 'rarity_idx', 'ink_idx']: temp_df[col] = pd.to_numeric(temp_df[col], errors='coerce').fillna(0).astype(int)
    vocabs = [int(temp_df[c].max() + 1) for c in ['set_idx', 'rarity_idx', 'ink_idx']]
    
    for seq_len in [15, 30, 45]:
        print(f"\n{'='*50}\n🌊 STARTING TRAINING PIPELINE: {seq_len}-DAY WINDOW\n{'='*50}")
        
        label = f"GRU-{seq_len}" if seq_len != 30 else "Single GRU"
        
        weights_path = f'data/pytorch/lorcana_gru_weights_{seq_len}.pth'
        output_csv_path = f'data/pytorch/gru_forecast_tidy_{seq_len}.csv'
        
        train_loader = DataLoader(LorcanaDataset(csv_path, seq_len, split='train'), batch_size=128, shuffle=True)
        val_loader = DataLoader(LorcanaDataset(csv_path, seq_len, split='val'), batch_size=128)
        test_loader = DataLoader(LorcanaDataset(csv_path, seq_len, split='test'), batch_size=128)

        model = HybridLorcanaGRU(vocabs).to(device)
        optimizer = optim.AdamW(model.parameters(), lr=0.001, weight_decay=1e-2)
        scheduler = optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='min', factor=0.5, patience=3)
        criterion = nn.SmoothL1Loss()
        early_stop = EarlyStopping(patience=15, path=weights_path)

        for epoch in range(100):
            model.train(); t_loss = 0.0
            for x_d, x_ca, x_co, y, _, _, _, _ in train_loader: # Unpack 8 items
                optimizer.zero_grad()
                loss = criterion(model(x_d.to(device), x_ca.to(device), x_co.to(device)), y.to(device))
                loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=0.5); optimizer.step()
                t_loss += loss.item() * x_d.size(0)
            
            model.eval(); v_loss = 0.0
            with torch.no_grad():
                for x_d, x_ca, x_co, y, _, _, _, _ in val_loader: # Unpack 8 items
                    v_loss += criterion(model(x_d.to(device), x_ca.to(device), x_co.to(device)), y.to(device)).item() * x_d.size(0)
            
            v_loss /= max(len(val_loader.dataset), 1)
            print(f"Epoch {epoch+1:02d} | LR: {optimizer.param_groups[0]['lr']:.6f} | Train: {t_loss/len(train_loader.dataset):.6f} | Val: {v_loss:.6f}")
            
            scheduler.step(v_loss); early_stop(v_loss, model)
            if early_stop.early_stop: print(f"🛑 Early stopping triggered."); break

        print(f"\n💾 Generating Standardized Tidy CSV for {label} (Using Real Historical Dates)...")
        model.load_state_dict(torch.load(weights_path))
        
        tidy_df = generate_tidy_csv(model, test_loader, device, model_label=label)
        tidy_df.to_csv(output_csv_path, index=False)
        print(f"✨ Saved to {output_csv_path}")
        
        del model, train_loader, val_loader, test_loader
        if torch.cuda.is_available(): torch.cuda.empty_cache()
        elif torch.backends.mps.is_available(): torch.mps.empty_cache()
        gc.collect()