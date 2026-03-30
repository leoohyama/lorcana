import pandas as pd
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader
import matplotlib.pyplot as plt

# ==========================================
# 1. DATASET CLASS (Must match Training)
# ==========================================
class LorcanaDataset(Dataset):
    def __init__(self, csv_file, seq_length=30, pred_length=7, split='train'):
        df = pd.read_csv(csv_file)
        self.X_dynamic, self.X_cat, self.X_cont, self.y, self.mins, self.maxs = [], [], [], [], [], []
        
        for card_id, group in df.groupby('card_id'):
            group = group.sort_values('date')
            total_days = len(group)
            if total_days < seq_length + pred_length + 10: continue
            
            train_cutoff = int(total_days * 0.70)
            val_cutoff = int(total_days * 0.85)
            
            if split == 'train':
                sub_group = group.iloc[:train_cutoff]
            elif split == 'val':
                sub_group = group.iloc[train_cutoff - seq_length + pred_length : val_cutoff]
            elif split == 'test':
                sub_group = group.iloc[val_cutoff - seq_length + pred_length :]
            else:
                raise ValueError("Split error")
                
            prices, days = sub_group['price_scaled'].values, sub_group['days_scaled'].values
            static_cat = sub_group[['name_idx', 'set_idx', 'rarity_idx', 'ink_idx']].iloc[0].values
            static_cont = sub_group[['cost_scaled', 'inkwell']].iloc[0].values
            c_min, c_max = sub_group['card_min_price'].iloc[0], sub_group['card_max_price'].iloc[0]
            
            for i in range(len(sub_group) - seq_length - pred_length + 1):
                self.X_dynamic.append(np.column_stack((prices[i : i + seq_length], days[i : i + seq_length])))
                self.y.append(prices[i + seq_length : i + seq_length + pred_length])
                self.X_cat.append(static_cat)
                self.X_cont.append(static_cont)
                self.mins.append(c_min)
                self.maxs.append(c_max)
                
        self.X_dynamic = torch.tensor(np.array(self.X_dynamic), dtype=torch.float32)
        self.X_cat = torch.tensor(np.array(self.X_cat), dtype=torch.long)
        self.X_cont = torch.tensor(np.array(self.X_cont), dtype=torch.float32)
        self.y = torch.tensor(np.array(self.y), dtype=torch.float32)
        self.mins = torch.tensor(np.array(self.mins), dtype=torch.float32)
        self.maxs = torch.tensor(np.array(self.maxs), dtype=torch.float32)

    def __len__(self): return len(self.y)
    def __getitem__(self, idx): 
        return self.X_dynamic[idx], self.X_cat[idx], self.X_cont[idx], self.y[idx], self.mins[idx], self.maxs[idx]

# ==========================================
# 2. ARCHITECTURE (Must match Training)
# ==========================================
class HybridLorcanaGRU(nn.Module):
    def __init__(self, dynamic_input_size=2, hidden_size=256, num_layers=3, pred_length=7, 
                 cat_vocab_sizes=[165, 11, 3, 6], embedding_dims=[16, 4, 2, 2], static_cont_size=2):
        super(HybridLorcanaGRU, self).__init__()
        self.gru = nn.GRU(input_size=dynamic_input_size, hidden_size=hidden_size, num_layers=num_layers, batch_first=True, dropout=0.3)
        self.emb_name = nn.Embedding(cat_vocab_sizes[0], embedding_dims[0])
        self.emb_set = nn.Embedding(cat_vocab_sizes[1], embedding_dims[1])
        self.emb_rarity = nn.Embedding(cat_vocab_sizes[2], embedding_dims[2])
        self.emb_ink = nn.Embedding(cat_vocab_sizes[3], embedding_dims[3])
        
        combined_size = hidden_size + sum(embedding_dims) + static_cont_size
        self.fc = nn.Sequential(
            nn.Linear(combined_size, 128),
            nn.ReLU(),
            nn.Linear(128, 64),
            nn.ReLU(),
            nn.Linear(64, pred_length)
        )
        
    def forward(self, x_dynamic, x_cat, x_cont):
        last_price = x_dynamic[:, -1, 0].unsqueeze(1) 
        _, hidden = self.gru(x_dynamic)
        last_hidden = hidden[-1, :, :]
        
        embs = torch.cat([
            self.emb_name(x_cat[:, 0]), 
            self.emb_set(x_cat[:, 1]), 
            self.emb_rarity(x_cat[:, 2]), 
            self.emb_ink(x_cat[:, 3])
        ], dim=1)
        
        # Apply the Tanh Anchor logic
        deltas = torch.tanh(self.fc(torch.cat([last_hidden, embs, x_cont], dim=1))) * 0.5
        return last_price + deltas

# ==========================================
# 3. PLOTTING LOGIC
# ==========================================
def plot_random_prediction():
    device = torch.device('cuda' if torch.cuda.is_available() else 'mps' if torch.backends.mps.is_available() else 'cpu')
    print(f"Plotting using device: {device}")
    
    # Initialize and load model
    model = HybridLorcanaGRU().to(device)
    try:
        model.load_state_dict(torch.load("data/pytorch/lorcana_gru_weights.pth", map_location=device))
        print("Successfully loaded trained weights.")
    except FileNotFoundError:
        print("ERROR: Weights file not found.")
        return

    # Load test data
    dataset = LorcanaDataset("data/pytorch/lorcana_pytorch_ready.csv", split='test')
    loader = DataLoader(dataset, batch_size=1, shuffle=True)
    
    # Get a random sample
    x_d, x_ca, x_co, y, pmin, pmax = next(iter(loader))
    
    model.eval()
    with torch.no_grad():
        p = model(x_d.to(device), x_ca.to(device), x_co.to(device)).cpu().numpy()[0]
    
    # Prepare for plotting
    h_scaled = x_d[0,:,0].numpy()
    a_scaled = y[0].numpy()
    p_scaled = p
    
    c_min, c_max = pmin[0].item(), pmax[0].item()
    def unscale(v): return v * (c_max - c_min) + c_min

    plt.figure(figsize=(10, 6))
    
    # History (Past 30 days)
    plt.plot(range(-30, 0), unscale(h_scaled), label='30-Day History', color='blue', marker='o', markersize=4)
    
    # Actual vs Predicted (Next 7 days)
    # Note: We anchor the plot at Day 0 using the last historical point
    future_range = range(0, 7)
    plt.plot(future_range, unscale(a_scaled), label='Actual Future', color='green', marker='o', markersize=4)
    plt.plot(future_range, unscale(p_scaled), label='Predicted Future', color='red', linestyle='--', marker='x')
    
    plt.axvline(0, color='black', linestyle='-', alpha=0.3)
    plt.title("Lorcana Anchored Delta Forecast (Actual USD)")
    plt.xlabel("Days")
    plt.ylabel("Price (USD)")
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.gca().yaxis.set_major_formatter(plt.FuncFormatter(lambda x, pos: f'${x:.2f}'))
    
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    plot_random_prediction()