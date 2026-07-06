import pandas as pd
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import os
import gc
import datetime

# set seeds for reproducibility
torch.manual_seed(42)
np.random.seed(42)

# hardware selection
if torch.backends.mps.is_available(): device = torch.device("mps"); print("hardware: apple silicon gpu (mps) detected.")
elif torch.cuda.is_available(): device = torch.device("cuda"); print("hardware: nvidia gpu (cuda) detected.")
else: device = torch.device("cpu"); print("hardware: gpu not found, using cpu.")

# dataset definition (PURE PRODUCTION MODE)
class LorcanaDataset(Dataset):
    def __init__(self, csv_file, seq_length=30, pred_length=30, split='train'):
        df = pd.read_csv(csv_file, dtype={'card_id': str}, low_memory=False)
        
        df['date'] = pd.to_datetime(df['date'])
        
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
            if len(group) < (seq_length + pred_length + 15): continue
            
            # --- PRODUCTION SPLIT LOGIC ---
            # Train gets 100% of the data. 
            sub_group = group # 100% of available history
            
            if len(sub_group) < (seq_length + pred_length): continue
                
            prices, days = sub_group['price_scaled'].values, sub_group['days_scaled'].values
            static_cat = sub_group[['set_idx', 'rarity_idx', 'ink_idx']].iloc[0].values
            static_cont = sub_group[['cost_scaled', 'inkwell']].iloc[0].values
            c_min, c_max = sub_group['card_min_price'].iloc[0], sub_group['card_max_price'].iloc[0]
            
            dates = sub_group['date'].apply(lambda x: x.timestamp()).values
            
            for i in range(len(sub_group) - seq_length - pred_length + 1):
                dyn = np.column_stack((prices[i:i+seq_length], days[i:i+seq_length]))
                # Add noise to training to prevent extreme overfitting
                dyn[:, 0] += np.random.normal(0, 0.001, seq_length)
                
                self.X_dynamic.append(dyn)
                self.y.append(prices[i+seq_length : i+seq_length+pred_length])
                self.X_cat.append(static_cat)
                self.X_cont.append(static_cont)
                self.mins.append(c_min)
                self.maxs.append(c_max)
                self.card_ids.append(card_id)
                self.target_dates.append(dates[i+seq_length : i+seq_length+pred_length])

        self.X_dynamic = torch.tensor(np.array(self.X_dynamic), dtype=torch.float32)
        self.X_cat = torch.tensor(np.array(self.X_cat), dtype=torch.long)
        self.X_cont = torch.tensor(np.array(self.X_cont), dtype=torch.float32)
        self.y = torch.tensor(np.array(self.y), dtype=torch.float32)
        self.mins = torch.tensor(np.array(self.mins), dtype=torch.float32)
        self.maxs = torch.tensor(np.array(self.maxs), dtype=torch.float32)
        self.target_dates = torch.tensor(np.array(self.target_dates), dtype=torch.float64) 
        
        print(f"Dataset 100% PRODUCTION ready: {len(self.y)} sequences.")

    def __len__(self): return len(self.y)
    def __getitem__(self, idx): return (self.X_dynamic[idx], self.X_cat[idx], self.X_cont[idx], self.y[idx], self.mins[idx], self.maxs[idx], self.card_ids[idx], self.target_dates[idx])

# architecture
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
        
        self.fc = nn.Sequential(nn.Linear(hidden_size + 16, 64), nn.ReLU(), nn.Dropout(0.5), nn.Linear(64, pred_length))
        
    def forward(self, x_d, x_ca, x_co):
        last_p = x_d[:, -1, 0].unsqueeze(1)
        
        out, _ = self.gru(x_d) 
        
        attn_weights = torch.softmax(self.attention(out), dim=1)
        context = torch.sum(attn_weights * out, dim=1)
        
        embs = torch.cat([self.emb_set(x_ca[:, 0]), self.emb_rarity(x_ca[:, 1]), self.emb_ink(x_ca[:, 2])], dim=1)
        
        return last_p + (torch.tanh(self.fc(torch.cat([context, embs, x_co], dim=1))) * 0.1)

# custom trend loss
class HorizonTrendLoss(nn.Module):
    def __init__(self, pred_length=30, max_penalty=0.5):
        super().__init__()
        self.smooth_l1 = nn.SmoothL1Loss(reduction='none')
        self.max_penalty = max_penalty
        self.register_buffer('time_weights', torch.linspace(0.0, 1.0, steps=pred_length))
        
    def forward(self, preds, targets, last_prices):
        base_loss = self.smooth_l1(preds, targets)
        actual_change = targets - last_prices
        pred_change = preds - last_prices
        wrong_direction = (torch.sign(actual_change) != torch.sign(pred_change)).float()
        threshold = last_prices * 0.02
        significant_move = (torch.abs(actual_change) > threshold).float()
        temporal_multiplier = self.max_penalty * self.time_weights.view(1, -1)
        active_penalty = wrong_direction * significant_move * temporal_multiplier
        weighted_loss = base_loss * (1.0 + active_penalty)
        return weighted_loss.mean()

# run pipeline
if __name__ == "__main__":
    csv_path = "data/pytorch/lorcana_pytorch_ready.csv"
    temp_df = pd.read_csv(csv_path, low_memory=False)
    for col in ['set_idx', 'rarity_idx', 'ink_idx']: temp_df[col] = pd.to_numeric(temp_df[col], errors='coerce').fillna(0).astype(int)
    vocabs = [int(temp_df[c].max() + 1) for c in ['set_idx', 'rarity_idx', 'ink_idx']]
    
    # Only training on the models you specify
    for seq_len in [15, 30, 45]:
        print(f"\n==================================================")
        print(f"🚀 STARTING PRODUCTION TRAINING: {seq_len}-DAY WINDOW")
        print(f"==================================================")
        
        label = f"GRU-{seq_len}" if seq_len != 30 else "Single GRU"
        weights_path = f'data/pytorch/lorcana_gru_weights_{seq_len}.pth'
        
        # Load 100% of data into the Train Loader. NO validation or test loaders needed.
        train_loader = DataLoader(LorcanaDataset(csv_path, seq_len, split='train'), batch_size=128, shuffle=True)

        model = HybridLorcanaGRU(vocabs).to(device)
        optimizer = optim.AdamW(model.parameters(), lr=0.001, weight_decay=1e-2)
        scheduler = optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='min', factor=0.5, patience=3)
        
        criterion = HorizonTrendLoss(pred_length=30, max_penalty=0.5).to(device)

        print(f"Training {label} on 100% of data for fixed 20 epochs...")
        
        for epoch in range(30):
            model.train()
            t_loss = 0.0
            
            for x_d, x_ca, x_co, y, _, _, _, _ in train_loader: 
                optimizer.zero_grad()
                last_price = x_d[:, -1, 0].unsqueeze(1).to(device)
                preds = model(x_d.to(device), x_ca.to(device), x_co.to(device))
                loss = criterion(preds, y.to(device), last_price)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=0.5)
                optimizer.step()
                t_loss += loss.item() * x_d.size(0)
            
            avg_train_loss = t_loss / len(train_loader.dataset)
            print(f"Ep {epoch+1:02d} | Train L1 Loss: {avg_train_loss:.4f}")
            
            scheduler.step(avg_train_loss)

        # Force save the model state after 20 epochs
        torch.save(model.state_dict(), weights_path)
        print(f"💾 Production weights strictly saved to {weights_path}")
        
        # Memory cleanup
        del model, train_loader
        if torch.cuda.is_available(): torch.cuda.empty_cache()
        elif torch.backends.mps.is_available(): torch.mps.empty_cache()
        gc.collect()

    print(f"\n🎉 Production pipeline complete. All models trained and ready for daily inference.")