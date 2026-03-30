import pandas as pd
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import os

# Set seeds for reproducibility
torch.manual_seed(42)
np.random.seed(42)

# ==========================================
# 1. HARDWARE SELECTION (M4 Max Support)
# ==========================================
if torch.backends.mps.is_available():
    device = torch.device("mps")
    print("🚀 Hardware: Apple Silicon GPU (MPS) detected.")
elif torch.cuda.is_available():
    device = torch.device("cuda")
    print("🚀 Hardware: NVIDIA GPU (CUDA) detected.")
else:
    device = torch.device("cpu")
    print("⚠️ Hardware: GPU not found, using CPU.")

# ==========================================
# 2. EARLY STOPPING
# ==========================================
class EarlyStopping:
    def __init__(self, patience=10, path='data/pytorch/lorcana_gru_weights.pth'):
        self.patience = patience
        self.path = path
        self.counter = 0
        self.best_loss = None
        self.early_stop = False
        os.makedirs(os.path.dirname(self.path), exist_ok=True)

    def __call__(self, val_loss, model):
        if self.best_loss is None:
            self.best_loss = val_loss
            self.save_checkpoint(model)
        elif val_loss >= self.best_loss:
            self.counter += 1
            print(f"EarlyStopping counter: {self.counter} of {self.patience}")
            if self.counter >= self.patience:
                self.early_stop = True
        else:
            self.best_loss = val_loss
            self.save_checkpoint(model)
            self.counter = 0

    def save_checkpoint(self, model):
        torch.save(model.state_dict(), self.path)
        print("✅ Validation loss decreased. Model checkpoint saved.")

# ==========================================
# 3. DATASET DEFINITION (180-Day Filter & Splitting)
# ==========================================
class LorcanaDataset(Dataset):
    def __init__(self, csv_file, seq_length=30, pred_length=30, split='train'):
        df = pd.read_csv(csv_file, dtype={'card_id': str})
        
        self.X_dynamic, self.X_cat, self.X_cont, self.y = [], [], [], []
        self.mins, self.maxs, self.card_ids = [], [], []
        
        MIN_HISTORY = 180 
        
        for card_id, group in df.groupby('card_id'):
            group = group.sort_values('date')
            total_days = len(group)
            
            # THE 180-DAY FILTER: Only train on established cards
            if total_days < MIN_HISTORY:
                continue
            
            # SPLIT STRATEGY:
            # Test: The very last 60-day window available
            # Val: The window immediately preceding the test set
            # Train: Everything else
            if split == 'test':
                sub_group = group.tail(seq_length + pred_length)
            elif split == 'val':
                sub_group = group.iloc[-(seq_length + pred_length + 20) : -20]
            else:
                sub_group = group.iloc[:-40]
            
            if len(sub_group) < (seq_length + pred_length):
                continue
                
            prices, days = sub_group['price_scaled'].values, sub_group['days_scaled'].values
            static_cat = sub_group[['name_idx', 'set_idx', 'rarity_idx', 'ink_idx']].iloc[0].values
            static_cont = sub_group[['cost_scaled', 'inkwell']].iloc[0].values
            c_min, c_max = sub_group['card_min_price'].iloc[0], sub_group['card_max_price'].iloc[0]
            
            # Generate sliding windows
            for i in range(len(sub_group) - seq_length - pred_length + 1):
                self.X_dynamic.append(np.column_stack((prices[i:i+seq_length], days[i:i+seq_length])))
                self.y.append(prices[i+seq_length : i+seq_length+pred_length])
                self.X_cat.append(static_cat)
                self.X_cont.append(static_cont)
                self.mins.append(c_min)
                self.maxs.append(c_max)
                self.card_ids.append(card_id)
                
        if len(self.y) == 0:
            raise ValueError(f"No sequences found for {split}. Check if data has > 180 days history.")

        self.X_dynamic = torch.tensor(np.array(self.X_dynamic), dtype=torch.float32)
        self.X_cat = torch.tensor(np.array(self.X_cat), dtype=torch.long)
        self.X_cont = torch.tensor(np.array(self.X_cont), dtype=torch.float32)
        self.y = torch.tensor(np.array(self.y), dtype=torch.float32)
        self.mins = torch.tensor(np.array(self.mins), dtype=torch.float32)
        self.maxs = torch.tensor(np.array(self.maxs), dtype=torch.float32)
        print(f"Dataset {split.upper()} ready: {len(self.y)} sequences.")

    def __len__(self): return len(self.y)
    def __getitem__(self, idx): 
        return (self.X_dynamic[idx], self.X_cat[idx], self.X_cont[idx], 
                self.y[idx], self.mins[idx], self.maxs[idx], self.card_ids[idx])

# ==========================================
# 4. ARCHITECTURE (MC-Dropout Capable)
# ==========================================
class HybridLorcanaGRU(nn.Module):
    def __init__(self, vocab_sizes, pred_length=30, hidden_size=256, num_layers=3):
        super(HybridLorcanaGRU, self).__init__()
        
        self.gru = nn.GRU(input_size=2, hidden_size=hidden_size, num_layers=num_layers, 
                          batch_first=True, dropout=0.3)
        
        self.emb_name = nn.Embedding(vocab_sizes[0], 16)
        self.emb_set = nn.Embedding(vocab_sizes[1], 4)
        self.emb_rarity = nn.Embedding(vocab_sizes[2], 2)
        self.emb_ink = nn.Embedding(vocab_sizes[3], 2)
        
        combined_size = hidden_size + 16 + 4 + 2 + 2 + 2 # Static cont features (cost, inkwell)
        
        self.fc = nn.Sequential(
            nn.Linear(combined_size, 128),
            nn.ReLU(),
            nn.Dropout(0.2), # Enabled during MC Dropout generation
            nn.Linear(128, 64),
            nn.ReLU(),
            nn.Linear(64, pred_length)
        )
        
    def forward(self, x_dynamic, x_cat, x_cont):
        last_price = x_dynamic[:, -1, 0].unsqueeze(1) 
        _, hidden = self.gru(x_dynamic)
        last_hidden = hidden[-1, :, :]
        
        embs = torch.cat([
            self.emb_name(x_cat[:, 0]), self.emb_set(x_cat[:, 1]), 
            self.emb_rarity(x_cat[:, 2]), self.emb_ink(x_cat[:, 3])
        ], dim=1)
        
        deltas = torch.tanh(self.fc(torch.cat([last_hidden, embs, x_cont], dim=1))) * 0.5
        return last_price + deltas

# ==========================================
# 5. TIDY FORECAST LOGIC (With Actuals)
# ==========================================
def generate_tidy_csv(model, dataloader, device, num_samples=100):
    model.train() # KEEP DROPOUT ON
    rows = []
    print(f"Generating Tidy predictions + actuals using {num_samples} samples per card...")
    
    with torch.no_grad():
        for x_d, x_ca, x_co, y, pmin, pmax, cids in dataloader:
            x_d, x_ca, x_co, y = x_d.to(device), x_ca.to(device), x_co.to(device), y.to(device)
            
            # Denormalize actual prices
            actual_usd = y * (pmax.to(device).unsqueeze(1) - pmin.to(device).unsqueeze(1)) + pmin.to(device).unsqueeze(1)
            actual_usd = actual_usd.cpu().numpy()

            # MC Dropout Sampling for Predictions
            samples = []
            for _ in range(num_samples):
                p_usd = model(x_d, x_ca, x_co) * (pmax.to(device).unsqueeze(1) - pmin.to(device).unsqueeze(1)) + pmin.to(device).unsqueeze(1)
                samples.append(p_usd.cpu().numpy())
            
            samples = np.array(samples)
            med = np.median(samples, 0)
            low = np.percentile(samples, 10, 0)
            high = np.percentile(samples, 90, 0)
            
            for i in range(len(cids)):
                for day in range(30):
                    rows.append({
                        'card_id': cids[i],
                        'day_offset': day + 1,
                        'actual_price': actual_usd[i, day],
                        'pred_price': med[i, day],
                        'conf_low': low[i, day],
                        'conf_high': high[i, day]
                    })
    return pd.DataFrame(rows)

# ==========================================
# 6. RUN PIPELINE
# ==========================================
if __name__ == "__main__":
    csv_path = "data/pytorch/lorcana_pytorch_ready.csv"
    
    # Check dynamic vocab sizes
    temp_df = pd.read_csv(csv_path)
    vocabs = [int(temp_df[c].max() + 1) for c in ['name_idx', 'set_idx', 'rarity_idx', 'ink_idx']]
    
    # Prepare Data
    train_ds = LorcanaDataset(csv_path, split='train')
    val_ds = LorcanaDataset(csv_path, split='val')
    test_ds = LorcanaDataset(csv_path, split='test')

    train_loader = DataLoader(train_ds, batch_size=128, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=128, shuffle=False)
    test_loader = DataLoader(test_ds, batch_size=128, shuffle=False)

    model = HybridLorcanaGRU(vocab_sizes=vocabs).to(device)
    optimizer = optim.Adam(model.parameters(), lr=0.001)
    criterion = nn.L1Loss()
    early_stop = EarlyStopping()

    print("\n🚀 Starting Training on " + str(device))
    for epoch in range(100):
        model.train()
        t_loss = 0.0
        for x_d, x_ca, x_co, y, _, _, _ in train_loader:
            x_d, x_ca, x_co, y = x_d.to(device), x_ca.to(device), x_co.to(device), y.to(device)
            optimizer.zero_grad()
            loss = criterion(model(x_d, x_ca, x_co), y)
            loss.backward(); optimizer.step()
            t_loss += loss.item() * x_d.size(0)
            
        model.eval()
        v_loss = 0.0
        with torch.no_grad():
            for x_d, x_ca, x_co, y, _, _, _ in val_loader:
                v_loss += criterion(model(x_d.to(device), x_ca.to(device), x_co.to(device)), y.to(device)).item() * x_d.size(0)
        
        v_loss /= max(len(val_ds), 1)
        print(f"Epoch {epoch+1:02d} | Train MAE: {t_loss/len(train_ds):.6f} | Val MAE: {v_loss:.6f}")
        early_stop(v_loss, model)
        if early_stop.early_stop: break

    # Final Audit & Tidy Export
    print("\n💾 Training complete. Generating Tidy CSV for R Backtesting...")
    model.load_state_dict(torch.load('data/pytorch/lorcana_gru_weights.pth'))
    tidy_df = generate_tidy_csv(model, test_loader, device)
    tidy_df.to_csv("data/pytorch/gru_forecast_tidy.csv", index=False)
    print("✨ Process complete! 'data/pytorch/gru_forecast_tidy.csv' is ready for R.")