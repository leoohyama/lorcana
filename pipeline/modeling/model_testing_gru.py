import pandas as pd
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
import os
import gc
import datetime

torch.manual_seed(42)
np.random.seed(42)

if torch.backends.mps.is_available(): device = torch.device("mps"); print("hardware: apple silicon gpu (mps) detected.")
elif torch.cuda.is_available(): device = torch.device("cuda"); print("hardware: nvidia gpu (cuda) detected.")
else: device = torch.device("cpu"); print("hardware: gpu not found, using cpu.")

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
    def save_checkpoint(self, model): torch.save(model.state_dict(), self.path)

class LorcanaDataset(Dataset):
    def __init__(self, csv_file, seq_length=30, pred_length=30, split='train', fold=0):
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
            
            if fold > 0:
                offset = fold * pred_length
                if len(group) <= offset: continue 
                group = group.iloc[:-offset]
            
            min_required_days = seq_length + pred_length + 40
            if len(group) < min_required_days: continue
            
            if split == 'test': sub_group = group.tail(seq_length + pred_length)
            elif split == 'val': sub_group = group.iloc[-(seq_length + pred_length + 20) : -20]
            else: sub_group = group.iloc[:-40]
            
            if len(sub_group) < (seq_length + pred_length): continue
                
            prices, days = sub_group['price_scaled'].values, sub_group['days_scaled'].values
            static_cat = sub_group[['set_idx', 'rarity_idx', 'ink_idx']].iloc[0].values
            static_cont = sub_group[['cost_scaled', 'inkwell']].iloc[0].values
            c_min, c_max = sub_group['card_min_price'].iloc[0], sub_group['card_max_price'].iloc[0]
            
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
                self.target_dates.append(dates[i+seq_length : i+seq_length+pred_length])

        self.X_dynamic = torch.tensor(np.array(self.X_dynamic), dtype=torch.float32)
        self.X_cat = torch.tensor(np.array(self.X_cat), dtype=torch.long)
        self.X_cont = torch.tensor(np.array(self.X_cont), dtype=torch.float32)
        self.y = torch.tensor(np.array(self.y), dtype=torch.float32)
        self.mins = torch.tensor(np.array(self.mins), dtype=torch.float32)
        self.maxs = torch.tensor(np.array(self.maxs), dtype=torch.float32)
        self.target_dates = torch.tensor(np.array(self.target_dates), dtype=torch.float64) 
        
        print(f"Dataset {split.upper()} (Fold {fold}) ready: {len(self.y)} sequences.")

    def __len__(self): return len(self.y)
    def __getitem__(self, idx): return (self.X_dynamic[idx], self.X_cat[idx], self.X_cont[idx], self.y[idx], self.mins[idx], self.maxs[idx], self.card_ids[idx], self.target_dates[idx])

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

def generate_tidy_csv(model, dataloader, device, model_label, num_samples=100):
    model.train() 
    rows = []
    with torch.no_grad():
        for x_d, x_ca, x_co, y, pmin, pmax, cids, t_dates in dataloader:
            x_d, x_ca, x_co, y = x_d.to(device), x_ca.to(device), x_co.to(device), y.to(device)
            samples = []
            for _ in range(num_samples):
                p_usd = model(x_d, x_ca, x_co) * (pmax.to(device).unsqueeze(1) - pmin.to(device).unsqueeze(1)) + pmin.to(device).unsqueeze(1)
                samples.append(p_usd.cpu().numpy())
            med, low, high = np.median(samples, 0), np.percentile(samples, 10, 0), np.percentile(samples, 90, 0)
            
            for i in range(len(cids)):
                card_dates = pd.to_datetime(t_dates[i].cpu().numpy(), unit='s')
                run_date = card_dates[0].date() - datetime.timedelta(days=1)
                for day in range(30):
                    rows.append({
                        'card_id': cids[i], 'run_date': run_date, 'target_date': card_dates[day].date(), 
                        'pred_price': round(float(med[i, day]), 2), 'conf_low': round(float(low[i, day]), 2), 
                        'conf_high': round(float(high[i, day]), 2), 'model': model_label
                    })
    return pd.DataFrame(rows)

if __name__ == "__main__":
    csv_path = "data/pytorch/lorcana_pytorch_ready.csv"
    temp_df = pd.read_csv(csv_path, low_memory=False)
    for col in ['set_idx', 'rarity_idx', 'ink_idx']: temp_df[col] = pd.to_numeric(temp_df[col], errors='coerce').fillna(0).astype(int)
    vocabs = [int(temp_df[c].max() + 1) for c in ['set_idx', 'rarity_idx', 'ink_idx']]
    
    global_metrics_rows = []
    num_folds = 3 
    
    # 🟢 MASTER LOOP: Now iterates through 15, 30, and 45-day windows
    for seq_len in [15, 30, 45]:
        cv_wmapes_d1 = []
        cv_wmapes_d30 = []
        cv_trend_accs = []
        cv_macro_accs = []
        
        print(f"\n==================================================")
        print(f"🌊 STARTING ROLLING-ORIGIN PIPELINE: {seq_len}-DAY WINDOW")
        print(f"==================================================")

        for fold in range(num_folds):
            print(f"\n--- {seq_len}-DAY WINDOW | FOLD {fold + 1}/{num_folds} (Simulating {fold * 30} days past) ---")
            
            label = f"GRU-{seq_len}" if seq_len != 30 else "Single GRU"
            weights_path = f'data/pytorch/lorcana_gru_weights_{seq_len}_fold{fold}.pth'
            output_csv_path = f'data/pytorch/gru_forecast_tidy_{seq_len}.csv'
            
            train_loader = DataLoader(LorcanaDataset(csv_path, seq_len, split='train', fold=fold), batch_size=128, shuffle=True)
            val_loader = DataLoader(LorcanaDataset(csv_path, seq_len, split='val', fold=fold), batch_size=128)
            test_loader = DataLoader(LorcanaDataset(csv_path, seq_len, split='test', fold=fold), batch_size=128)

            model = HybridLorcanaGRU(vocabs).to(device)
            optimizer = optim.AdamW(model.parameters(), lr=0.001, weight_decay=1e-2)
            scheduler = optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='min', factor=0.5, patience=3)
            
            criterion = HorizonTrendLoss(pred_length=30, max_penalty=0.5).to(device)
            early_stop = EarlyStopping(patience=15, path=weights_path)

            for epoch in range(100):
                model.train(); t_loss = 0.0
                for x_d, x_ca, x_co, y, _, _, _, _ in train_loader: 
                    optimizer.zero_grad()
                    last_price = x_d[:, -1, 0].unsqueeze(1).to(device)
                    preds = model(x_d.to(device), x_ca.to(device), x_co.to(device))
                    loss = criterion(preds, y.to(device), last_price)
                    loss.backward(); torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=0.5); optimizer.step()
                    t_loss += loss.item() * x_d.size(0)
                
                model.eval()
                v_loss, val_mape_d1, val_mape_d30, val_mda, val_macro_mda = 0.0, 0.0, 0.0, 0.0, 0.0
                
                with torch.no_grad():
                    for x_d, x_ca, x_co, y, pmin, pmax, _, _ in val_loader: 
                        x_d, x_ca, x_co, y = x_d.to(device), x_ca.to(device), x_co.to(device), y.to(device)
                        pmin, pmax = pmin.to(device).unsqueeze(1), pmax.to(device).unsqueeze(1)
                        
                        last_price = x_d[:, -1, 0].unsqueeze(1).to(device)
                        preds = model(x_d, x_ca, x_co)
                        v_loss += criterion(preds, y, last_price).item() * x_d.size(0)
                        
                        preds_usd = preds * (pmax - pmin) + pmin
                        y_usd = y * (pmax - pmin) + pmin
                        last_price_usd = x_d[:, -1, 0].unsqueeze(1) * (pmax - pmin) + pmin
                        
                        mape_seq = torch.abs((y_usd - preds_usd) / (y_usd + 1e-6))
                        val_mape_d1 += mape_seq[:, 0].sum().item()
                        val_mape_d30 += mape_seq[:, 29].sum().item()
                        
                        actual_dir = torch.sign(y_usd - last_price_usd)
                        pred_dir = torch.sign(preds_usd - last_price_usd)
                        correct_dirs = (actual_dir == pred_dir).float().sum().item()
                        val_mda += correct_dirs / 30.0
                        
                        macro_actual = torch.sign(y_usd[:, -1] - last_price_usd.squeeze(1))
                        macro_pred = torch.sign(preds_usd[:, -1] - last_price_usd.squeeze(1))
                        val_macro_mda += (macro_actual == macro_pred).float().sum().item()
                
                n_val = max(len(val_loader.dataset), 1)
                v_loss /= n_val
                mape_d1 = (val_mape_d1 / n_val) * 100 
                mape_d30 = (val_mape_d30 / n_val) * 100 
                mda = (val_mda / n_val) * 100 
                macro_mda = (val_macro_mda / n_val) * 100
                
                print(f"Ep {epoch+1:02d} | Train L1: {t_loss/len(train_loader.dataset):.4f} | Val L1: {v_loss:.4f} | D1 Err: {mape_d1:.1f}% | D30 Err: {mape_d30:.1f}% | Trend Acc: {mda:.1f}% | Macro Trend: {macro_mda:.1f}%")
                
                scheduler.step(v_loss); early_stop(v_loss, model)
                if early_stop.early_stop: print(f"early stopping triggered."); break

            print(f"\nevaluating {label} on unseen test data for Fold {fold}...")
            model.load_state_dict(torch.load(weights_path))
            model.eval()
            
            total_test_samples = 0
            test_mae_sums = np.zeros(30)
            test_actual_sums = np.zeros(30)
            test_mda_sums = np.zeros(30)
            test_macro_mda_sum = 0.0
            
            with torch.no_grad():
                for x_d, x_ca, x_co, y, pmin, pmax, _, _ in test_loader: 
                    x_d, x_ca, x_co, y = x_d.to(device), x_ca.to(device), x_co.to(device), y.to(device)
                    pmin, pmax = pmin.to(device).unsqueeze(1), pmax.to(device).unsqueeze(1)
                    
                    preds = model(x_d, x_ca, x_co)
                    preds_usd = preds * (pmax - pmin) + pmin
                    y_usd = y * (pmax - pmin) + pmin
                    last_price_usd = x_d[:, -1, 0].unsqueeze(1) * (pmax - pmin) + pmin
                    
                    mae_seq = torch.abs(y_usd - preds_usd)
                    test_mae_sums += mae_seq.sum(dim=0).cpu().numpy()
                    test_actual_sums += y_usd.sum(dim=0).cpu().numpy()
                    
                    actual_dir = torch.sign(y_usd - last_price_usd)
                    pred_dir = torch.sign(preds_usd - last_price_usd)
                    correct_dirs = (actual_dir == pred_dir).float()
                    test_mda_sums += correct_dirs.sum(dim=0).cpu().numpy()
                    
                    macro_actual = torch.sign(y_usd[:, -1] - last_price_usd.squeeze(1))
                    macro_pred = torch.sign(preds_usd[:, -1] - last_price_usd.squeeze(1))
                    test_macro_mda_sum += (macro_actual == macro_pred).float().sum().item()
                    
                    total_test_samples += x_d.size(0)
                    
            avg_wmapes = (test_mae_sums / test_actual_sums) * 100
            avg_maes = test_mae_sums / total_test_samples
            avg_mdas = (test_mda_sums / total_test_samples) * 100
            avg_macro_mda = (test_macro_mda_sum / total_test_samples) * 100
            
            cv_wmapes_d1.append(avg_wmapes[0])
            cv_wmapes_d30.append(avg_wmapes[-1])
            cv_trend_accs.append(avg_mdas.mean())
            cv_macro_accs.append(avg_macro_mda)
            
            print(f"🏆 {seq_len}D FOLD {fold+1} RESULTS | D30 wMAPE: {avg_wmapes[-1]:.1f}% | Macro Acc: {avg_macro_mda:.1f}%\n")
            
            if fold == 0:
                for day in range(30):
                    global_metrics_rows.append({
                        'model': label,
                        'horizon_day': day + 1,
                        'wmape_error_pct': round(avg_wmapes[day], 2),
                        'mae_error_usd': round(avg_maes[day], 2),
                        'trend_accuracy_pct': round(avg_mdas[day], 2),
                        'macro_trend_accuracy_pct': round(avg_macro_mda, 2) 
                    })

                print(f"💾 generating tidy csv for live predictions ({label})...")
                tidy_df = generate_tidy_csv(model, test_loader, device, model_label=label)
                tidy_df.to_csv(output_csv_path, index=False)
                print(f"✨ saved to {output_csv_path}")
            
            del model, train_loader, val_loader, test_loader
            if torch.cuda.is_available(): torch.cuda.empty_cache()
            elif torch.backends.mps.is_available(): torch.mps.empty_cache()
            gc.collect()

        print(f"\n==================================================")
        print(f"📊 FINAL CV RESULTS FOR {seq_len}-DAY WINDOW")
        print(f"==================================================")
        print(f"Mean D1 wMAPE: {np.mean(cv_wmapes_d1):.1f}%")
        print(f"Mean D30 wMAPE: {np.mean(cv_wmapes_d30):.1f}%")
        print(f"Mean Avg Trend Acc: {np.mean(cv_trend_accs):.1f}%")
        print(f"Mean Macro Trend Acc: {np.mean(cv_macro_accs):.1f}%")
        print(f"==================================================\n")

    # 🟢 FINAL EXPORT: Saves all collected global metrics for 15, 30, and 45-day models
    global_metrics_df = pd.DataFrame(global_metrics_rows)
    global_metrics_path = 'data/pytorch/lorcana_global_metrics.csv'
    os.makedirs(os.path.dirname(global_metrics_path), exist_ok=True)
    global_metrics_df.to_csv(global_metrics_path, index=False)
    print(f"🎉 pipeline complete. saved consolidated global metrics to {global_metrics_path}")