import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader, random_split
from torchvision import transforms
from torchvision.models import resnet18, ResNet18_Weights
from PIL import Image
import os
import pillow_avif # Essential for parsing the .avif card scans

# --- 1. SETUP DEVICE (Cross-Platform) ---
if torch.cuda.is_available():
    device = torch.device("cuda") # Triggers on your Windows gaming rig
elif torch.backends.mps.is_available():
    device = torch.device("mps")  # Triggers on your Macbook Pro
else:
    device = torch.device("cpu")  # Fallback

print(f"✅ Using device: {device}")

# --- 1. SETUP DEVICE ---
device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
print(f"✅ Using device: {device}")

# --- 2. DEFINE TRANSFORMATIONS (Image Preprocessing & Augmentation) ---
image_transforms = transforms.Compose([
    transforms.Resize((224, 224)),
    transforms.RandomAffine(degrees=5, translate=(0.05, 0.05)), 
    transforms.ColorJitter(brightness=0.1, contrast=0.1),       
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
])

# --- 3. THE MULTIMODAL DATASET CLASS ---
class LorcanaMultiModalDataset(Dataset):
    def __init__(self, parquet_file, root_dir, transform=None):
        full_df = pd.read_parquet(parquet_file)
        self.root_dir = root_dir
        self.transform = transform
        
        # Map physical image files
        self.image_map = {}
        for root, _, files in os.walk(root_dir):
            for file in files:
                if file.endswith(".avif"):
                    img_id = file.split(".")[0]
                    self.image_map[img_id] = os.path.join(root, file)
        
        # The Double Filter: Must have an image AND a non-NaN price
        self.data = full_df[
            (full_df['id'].isin(self.image_map.keys())) & 
            (full_df['log_price'].notna())
        ].reset_index(drop=True)
        
        dropped_count = len(full_df) - len(self.data)
        print(f"✅ Dataset initialized. Dropped {dropped_count} cards (missing images or NaN prices).")
        print(f"✅ Total usable cards: {len(self.data)}")

    def __len__(self):
        return len(self.data)

    def __getitem__(self, idx):
        row = self.data.iloc[idx]
        img_id = row['id']
        img_path = self.image_map.get(img_id)
        
        image = Image.open(img_path).convert("RGB")
        if self.transform:
            image = self.transform(image)

        # Separate the variables
        char_id = torch.tensor(row['character_id'], dtype=torch.long)
        other_features = row.drop(['id', 'character_id', 'log_price'])
        tabular_tensor = torch.tensor(other_features.values.astype(float), dtype=torch.float32)
        target = torch.tensor(row['log_price'], dtype=torch.float32)
        
        return image, char_id, tabular_tensor, target

# --- 4. INSTANTIATE & SPLIT (The 70/15/15 Rule) ---
full_dataset = LorcanaMultiModalDataset(
    parquet_file="data/tabular/ready_for_pytorch.parquet",
    root_dir="lorcana_images/",
    transform=image_transforms
)

total_size = len(full_dataset)
train_size = int(0.70 * total_size)
val_size = int(0.15 * total_size)
test_size = total_size - train_size - val_size # The Vault

train_subset, val_subset, test_subset = random_split(
    full_dataset, [train_size, val_size, test_size]
)

# Create the Loaders
train_loader = DataLoader(train_subset, batch_size=32, shuffle=True)
val_loader = DataLoader(val_subset, batch_size=32, shuffle=False)
test_loader = DataLoader(test_subset, batch_size=32, shuffle=False) # DO NOT touch during training loop

print(f"✅ Data Split: {train_size} Train / {val_size} Val / {test_size} Test")

# --- 5. THE TRANSFER LEARNING MODEL ---
class LorcanaTransferModel(nn.Module):
    def __init__(self, num_characters, num_tabular_features):
        super(LorcanaTransferModel, self).__init__()
        
        # Branch 1: Vision (Frozen ResNet18)
        self.resnet = resnet18(weights=ResNet18_Weights.DEFAULT)
        for param in self.resnet.parameters():
            param.requires_grad = False
        self.resnet.fc = nn.Identity() # Bypasses classification, outputs 512 raw features
        
        # Branch 2: Character Embeddings
        self.char_embed = nn.Embedding(num_embeddings=num_characters, embedding_dim=50)
        
        # Branch 3: Tabular Stats (Lore, Strength, Ink)
        self.tabular_mlp = nn.Sequential(
            nn.Linear(num_tabular_features, 64),
            nn.ReLU(),
            nn.Dropout(0.3)
        )
        
        # Fusion Head: 512 (ResNet) + 50 (Embed) + 64 (Tabular) = 626
        self.fusion_head = nn.Sequential(
            nn.Linear(626, 256),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(256, 1)
        )

    def forward(self, img, char_id, tab):
        x_img = self.resnet(img)
        x_char = self.char_embed(char_id)
        x_tab = self.tabular_mlp(tab)
        
        combined = torch.cat((x_img, x_char, x_tab), dim=1)
        return self.fusion_head(combined)

# --- 6. INITIALIZE MODEL & OPTIMIZER ---
num_stats = len(full_dataset.data.columns) - 3 
max_char_id = full_dataset.data['character_id'].max() + 1 

model = LorcanaTransferModel(num_characters=max_char_id, num_tabular_features=num_stats).to(device)
criterion = nn.MSELoss()
optimizer = optim.Adam(model.parameters(), lr=0.0001)

num_epochs = 30 # Let it cook to find the true bottom

# --- 7. THE TRAINING LOOP ---
print("🚀 Starting Training Pipeline...")
for epoch in range(num_epochs):
    
    # -- TRAIN --
    model.train()
    train_running_loss = 0.0
    for images, char_ids, tabs, targets in train_loader:
        images, char_ids, tabs, targets = images.to(device), char_ids.to(device), tabs.to(device), targets.to(device).float()
        
        optimizer.zero_grad()
        outputs = model(images, char_ids, tabs)
        loss = criterion(outputs.squeeze(), targets.view(-1))
        
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
        optimizer.step()
        train_running_loss += loss.item()
        
    avg_train_loss = train_running_loss / len(train_loader)
    
    # -- VALIDATE --
    model.eval()
    val_running_loss = 0.0
    with torch.no_grad():
        for images, char_ids, tabs, targets in val_loader:
            images, char_ids, tabs, targets = images.to(device), char_ids.to(device), tabs.to(device), targets.to(device).float()
            
            outputs = model(images, char_ids, tabs)
            loss = criterion(outputs.squeeze(), targets.view(-1))
            val_running_loss += loss.item()
            
    avg_val_loss = val_running_loss / len(val_loader)
    print(f"Epoch {epoch+1:02d}/{num_epochs:02d} | Train Loss: {avg_train_loss:.4f} | Val Loss: {avg_val_loss:.4f}")

print("🎉 Model Training Complete! The Test Vault remains untouched.")

import numpy as np

print("🔓 Cracking open the Test Vault...")

# 1. Set model to evaluation mode (turns off Dropout)
model.eval()
test_running_loss = 0.0

# Store some samples to print later
sample_actuals = []
sample_preds = []

# 2. Turn off gradients to save memory and speed up inference
with torch.no_grad():
    for i, (images, char_ids, tabs, targets) in enumerate(test_loader):
        # Move data to GPU/MPS
        images = images.to(device)
        char_ids = char_ids.to(device)
        tabs = tabs.to(device)
        targets = targets.to(device).float()
        
        # Make the predictions
        outputs = model(images, char_ids, tabs)
        loss = criterion(outputs.squeeze(), targets.view(-1))
        test_running_loss += loss.item()
        
        # Grab the first 5 cards from the very first batch to inspect
        if i == 0:
            # Reverse the log(price + 1) transformation
            preds_dollars = torch.exp(outputs.squeeze()) - 1
            targets_dollars = torch.exp(targets.view(-1)) - 1
            
            # Move back to CPU for easy printing
            sample_preds = preds_dollars.cpu().numpy()[:5]
            sample_actuals = targets_dollars.cpu().numpy()[:5]

# 3. Calculate the final, unbiased Test Loss
final_test_loss = test_running_loss / len(test_loader)
print("-" * 40)
print(f"🏆 FINAL TEST LOSS: {final_test_loss:.4f}")
print("-" * 40)

# 4. Show the real-world dollar comparisons
print("💵 REAL DOLLAR PREDICTIONS (First 5 Cards):")
for i in range(5):
    actual = sample_actuals[i]
    predicted = sample_preds[i]
    difference = predicted - actual
    
    print(f"Card {i+1}:")
    print(f"   Actual Price:    ${actual:.2f}")
    print(f"   Predicted Price: ${predicted:.2f}")
    print(f"   Difference:      ${difference:+.2f}")
    print("-" * 20)


torch.save(model.state_dict(), "best_lorcana_model.pth")


print("🔓 Extracting all Test predictions...")

model.eval()
all_actuals = []
all_preds = []

with torch.no_grad():
    for images, char_ids, tabs, targets in test_loader:
        # Move to MPS/GPU
        images = images.to(device)
        char_ids = char_ids.to(device)
        tabs = tabs.to(device)
        
        # Get predictions
        outputs = model(images, char_ids, tabs)
        
        # Reverse the log(price + 1) transformation
        preds_dollars = torch.exp(outputs.squeeze()).cpu().numpy() - 1
        targets_dollars = torch.exp(targets.view(-1)).cpu().numpy() - 1
        
        # Store in our lists
        all_preds.extend(preds_dollars)
        all_actuals.extend(targets_dollars)

# Build the DataFrame
results_df = pd.DataFrame({
    'Actual_Price': all_actuals,
    'Predicted_Price': all_preds
})

# Calculate the difference
results_df['Difference'] = results_df['Predicted_Price'] - results_df['Actual_Price']

# Round everything to 2 decimal places for clean viewing
results_df = results_df.round(2)

# Save to a CSV so you can explore it later
results_df.to_csv("lorcana_test_predictions.csv", index=False)

# Print a sample to the console
print("\n💵 SAMPLE PREDICTIONS:")
print(results_df.head(15).to_markdown(index=False))
print(f"\n✅ Full table of all {len(results_df)} test cards saved to 'lorcana_test_predictions.csv'")


import matplotlib.pyplot as plt

# Your exact loss values from the 30-epoch Transfer Learning run
train_loss = [1.4515, 1.1104, 0.9263, 0.8538, 0.7952, 0.7715, 0.7225, 0.6623, 0.6434, 0.5969, 
              0.5576, 0.5227, 0.5076, 0.4643, 0.4923, 0.4458, 0.4371, 0.4132, 0.4171, 0.4148, 
              0.3809, 0.3778, 0.3815, 0.3376, 0.3647, 0.3425, 0.3429, 0.3262, 0.3179, 0.2929]

val_loss = [1.0523, 0.8936, 0.7891, 0.6351, 0.6738, 0.6013, 0.6045, 0.6240, 0.5556, 0.5263, 
            0.4737, 0.4375, 0.4436, 0.5171, 0.4461, 0.4379, 0.4091, 0.4305, 0.4177, 0.3913, 
            0.4005, 0.4151, 0.3843, 0.4143, 0.3781, 0.4074, 0.4344, 0.3937, 0.3696, 0.3595]

epochs = list(range(1, 31))

# Create the plot
plt.figure(figsize=(10, 6))
plt.plot(epochs, train_loss, label='Training Loss', color='blue', linewidth=2)
plt.plot(epochs, val_loss, label='Validation Loss', color='orange', linewidth=2)

plt.title('Multimodal Model Learning Curve (ResNet18 + Tabular)')
plt.xlabel('Epochs')
plt.ylabel('Mean Squared Error (Log Scale)')
plt.legend()
plt.grid(True, linestyle='--', alpha=0.7)

# Show the plot
plt.show()
