#this is the first neural network where we simply just use a cNN to predict log price BASED on just images

import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader, random_split
from torchvision import transforms
from PIL import Image
import pandas as pd
import os
import pillow_avif # Required for your .avif files

# --- 1. SETUP DEVICE ---
device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
print(f"✅ Using device: {device}")

# --- 2. DEFINE TRANSFORMATIONS (With Augmentation) ---
image_transforms = transforms.Compose([
    transforms.Resize((224, 224)),
    transforms.RandomAffine(degrees=5, translate=(0.05, 0.05)), # Augmentation
    transforms.ColorJitter(brightness=0.1, contrast=0.1),       # Augmentation
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225])
])

# --- 3. DEFINE THE DATASET CLASS ---
class LorcanaMultiModalDataset(Dataset):
    def __init__(self, parquet_file, root_dir, transform=None):
        full_df = pd.read_parquet(parquet_file)
        self.root_dir = root_dir
        self.transform = transform
        
        self.image_map = {}
        for root, _, files in os.walk(root_dir):
            for file in files:
                if file.endswith(".avif"):
                    img_id = file.split(".")[0]
                    self.image_map[img_id] = os.path.join(root, file)
        
        # Double Filter: Valid image AND valid price
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

        char_id = torch.tensor(row['character_id'], dtype=torch.long)
        other_features = row.drop(['id', 'character_id', 'log_price'])
        tabular_tensor = torch.tensor(other_features.values.astype(float), dtype=torch.float32)
        target = torch.tensor(row['log_price'], dtype=torch.float32)
        
        return image, char_id, tabular_tensor, target

# --- 4. CREATE INSTANCE & SPLIT DATA ---
full_dataset = LorcanaMultiModalDataset(
    parquet_file="data/tabular/ready_for_pytorch.parquet",
    root_dir="lorcana_images/",
    transform=image_transforms
)

# 80/20 Train/Validation Split
train_size = int(0.8 * len(full_dataset))
val_size = len(full_dataset) - train_size
train_subset, val_subset = random_split(full_dataset, [train_size, val_size])

train_loader = DataLoader(train_subset, batch_size=32, shuffle=True)
val_loader = DataLoader(val_subset, batch_size=32, shuffle=False)
print(f"✅ Data Split: {train_size} train / {val_size} val")

# --- 5. DEFINE THE DEEPER CNN MODEL ---
class LorcanaDeepCNN(nn.Module):
    def __init__(self):
        super(LorcanaDeepCNN, self).__init__()
        
        # Block 1: 16 Filters 
        self.block1 = nn.Sequential(
            nn.Conv2d(3, 16, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.Conv2d(16, 16, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.MaxPool2d(2, 2)
        )
        
        # Block 2: 32 Filters 
        self.block2 = nn.Sequential(
            nn.Conv2d(16, 32, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.Conv2d(32, 32, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.MaxPool2d(2, 2)
        )
        
        # Block 3: 64 Filters 
        self.block3 = nn.Sequential(
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.Conv2d(64, 64, kernel_size=3, padding=1),
            nn.ReLU(),
            nn.MaxPool2d(2, 2)
        )
        
        self.fc_layers = nn.Sequential(
            nn.Flatten(),
            nn.Linear(64 * 28 * 28, 256),
            nn.ReLU(),
            nn.Dropout(0.5),
            nn.Linear(256, 1)
        )

    def forward(self, x):
        x = self.block1(x)
        x = self.block2(x)
        x = self.block3(x)
        return self.fc_layers(x)

# Initialize and send to device
model = LorcanaDeepCNN().to(device)

# --- 6. TRAINING SETUP ---
criterion = nn.MSELoss()
optimizer = optim.Adam(model.parameters(), lr=0.0001)
num_epochs = 15 # Bumped to 15 so you can see the validation trend

# --- 7. THE TRAINING & VALIDATION LOOP ---
print("🚀 Starting Training...")
for epoch in range(num_epochs):
    
    # --- TRAINING PHASE ---
    model.train()
    train_running_loss = 0.0
    for images, _, _, targets in train_loader:
        images, targets = images.to(device), targets.to(device).float()
        
        optimizer.zero_grad()
        outputs = model(images)
        loss = criterion(outputs.squeeze(), targets.view(-1))
        
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0) # Stop NaNs
        optimizer.step()
        
        train_running_loss += loss.item()
        
    avg_train_loss = train_running_loss / len(train_loader)
    
    # --- VALIDATION PHASE ---
    model.eval()
    val_running_loss = 0.0
    with torch.no_grad():
        for images, _, _, targets in val_loader:
            images, targets = images.to(device), targets.to(device).float()
            
            outputs = model(images)
            loss = criterion(outputs.squeeze(), targets.view(-1))
            val_running_loss += loss.item()
            
    avg_val_loss = val_running_loss / len(val_loader)
    
    # --- REPORTING ---
    print(f"Epoch {epoch+1:02d}/{num_epochs:02d} | Train Loss: {avg_train_loss:.4f} | Val Loss: {avg_val_loss:.4f}")

print("🎉 Finished Training!")




###now  we move on to a multidmodal model where we incorporate tabular data


class LorcanaMultiModalModel(nn.Module):
    def __init__(self, num_characters, num_tabular_features):
        super(LorcanaMultiModalModel, self).__init__()
        
        # --- BRANCH 1: THE VISION (Your Deep CNN) ---
        self.block1 = nn.Sequential(nn.Conv2d(3, 16, 3, padding=1), nn.ReLU(), nn.Conv2d(16, 16, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2, 2))
        self.block2 = nn.Sequential(nn.Conv2d(16, 32, 3, padding=1), nn.ReLU(), nn.Conv2d(32, 32, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2, 2))
        self.block3 = nn.Sequential(nn.Conv2d(32, 64, 3, padding=1), nn.ReLU(), nn.Conv2d(64, 64, 3, padding=1), nn.ReLU(), nn.MaxPool2d(2, 2))
        
        # We stop the image branch at 256 features instead of making a final prediction
        self.image_flatten = nn.Sequential(
            nn.Flatten(),
            nn.Linear(64 * 28 * 28, 256),
            nn.ReLU()
        )
        
        # --- BRANCH 2: CHARACTER EMBEDDING ---
        # In R, you would treat Character ID as a 'factor'. 
        # In deep learning, we use an Embedding layer to mathematically map relationships between characters.
        self.char_embed = nn.Embedding(num_embeddings=num_characters, embedding_dim=50)
        
        # --- BRANCH 3: THE TABULAR STATS (MLP) ---
        # Processes your Lore, Strength, Ink colors, etc.
        self.tabular_mlp = nn.Sequential(
            nn.Linear(num_tabular_features, 64),
            nn.ReLU(),
            nn.Dropout(0.3)
        )
        
        # --- THE FUSION HEAD ---
        # We glue the outputs of all three branches together: 
        # 256 (Image) + 50 (Character) + 64 (Stats) = 370 total features
        self.fusion_head = nn.Sequential(
            nn.Linear(370, 128),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(128, 1) # The final log_price prediction
        )

    def forward(self, img, char_id, tab):
        # 1. Run the image through the CNN
        x_img = self.block1(img)
        x_img = self.block2(x_img)
        x_img = self.block3(x_img)
        x_img = self.image_flatten(x_img)
        
        # 2. Run the character ID through the Embedding
        x_char = self.char_embed(char_id)
        
        # 3. Run the stats through the MLP
        x_tab = self.tabular_mlp(tab)
        
        # 4. FUSE them together along the feature dimension
        combined = torch.cat((x_img, x_char, x_tab), dim=1)
        
        # 5. Make the final prediction
        return self.fusion_head(combined)

# --- INITIALIZE THE MULTIMODAL MODEL ---
# Dynamically calculate the sizes based on your dataset
num_stats = len(full_dataset.data.columns) - 3 # Subtracting id, char_id, and log_price
max_char_id = full_dataset.data['character_id'].max() + 1 

model = LorcanaMultiModalModel(num_characters=max_char_id, num_tabular_features=num_stats).to(device)

criterion = nn.MSELoss()
optimizer = optim.Adam(model.parameters(), lr=0.0001)
num_epochs = 15

# --- REVISED TRAINING & VALIDATION LOOP ---
print("🚀 Starting Multimodal Training...")
for epoch in range(num_epochs):
    
    # --- TRAINING PHASE ---
    model.train()
    train_running_loss = 0.0
    for images, char_ids, tabs, targets in train_loader:
        # Move ALL inputs to the GPU/MPS
        images = images.to(device)
        char_ids = char_ids.to(device)
        tabs = tabs.to(device)
        targets = targets.to(device).float()
        
        optimizer.zero_grad()
        
        # Feed all three inputs to the model
        outputs = model(images, char_ids, tabs)
        loss = criterion(outputs.squeeze(), targets.view(-1))
        
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
        optimizer.step()
        
        train_running_loss += loss.item()
        
    avg_train_loss = train_running_loss / len(train_loader)
    
    # --- VALIDATION PHASE ---
    model.eval()
    val_running_loss = 0.0
    with torch.no_grad():
        for images, char_ids, tabs, targets in val_loader:
            images = images.to(device)
            char_ids = char_ids.to(device)
            tabs = tabs.to(device)
            targets = targets.to(device).float()
            
            # Feed all three inputs to the model
            outputs = model(images, char_ids, tabs)
            loss = criterion(outputs.squeeze(), targets.view(-1))
            val_running_loss += loss.item()
            
    avg_val_loss = val_running_loss / len(val_loader)
    
    print(f"Epoch {epoch+1:02d}/{num_epochs:02d} | Train Loss: {avg_train_loss:.4f} | Val Loss: {avg_val_loss:.4f}")

print("🎉 Finished Multimodal Training!")


from torchvision.models import resnet18, ResNet18_Weights
import torch.nn as nn
import torch

class LorcanaTransferModel(nn.Module):
    def __init__(self, num_characters, num_tabular_features):
        super(LorcanaTransferModel, self).__init__()
        
        # --- BRANCH 1: PRE-TRAINED VISION (ResNet18) ---
        # 1. Load the pre-trained ResNet18 model
        self.resnet = resnet18(weights=ResNet18_Weights.DEFAULT)
        
        # 2. FREEZE THE WEIGHTS: We don't want to accidentally destroy its pre-trained "brain"
        for param in self.resnet.parameters():
            param.requires_grad = False
            
        # 3. Strip the final classification head
        # ResNet usually tries to predict 1,000 different ImageNet categories.
        # Replacing the final layer with an 'Identity' layer just passes the raw 
        # 512 visual features directly to our Fusion Head.
        self.resnet.fc = nn.Identity()
        
        # --- BRANCH 2: CHARACTER EMBEDDING ---
        self.char_embed = nn.Embedding(num_embeddings=num_characters, embedding_dim=50)
        
        # --- BRANCH 3: THE TABULAR STATS (MLP) ---
        self.tabular_mlp = nn.Sequential(
            nn.Linear(num_tabular_features, 64),
            nn.ReLU(),
            nn.Dropout(0.3)
        )
        
        # --- THE FUSION HEAD ---
        # 512 (ResNet features) + 50 (Character vector) + 64 (Stats) = 626 total features
        self.fusion_head = nn.Sequential(
            nn.Linear(626, 256),
            nn.ReLU(),
            nn.Dropout(0.3),
            nn.Linear(256, 1) # Final log_price prediction
        )

    def forward(self, img, char_id, tab):
        # 1. Get 512 visual features from the frozen ResNet
        x_img = self.resnet(img)
        
        # 2. Get the 50-number character profile
        x_char = self.char_embed(char_id)
        
        # 3. Process the Lore, Strength, and Ink stats
        x_tab = self.tabular_mlp(tab)
        
        # 4. FUSE everything together
        combined = torch.cat((x_img, x_char, x_tab), dim=1)
        
        # 5. Predict the price
        return self.fusion_head(combined)


# Recalculate dimensions
num_stats = len(full_dataset.data.columns) - 3
max_char_id = full_dataset.data['character_id'].max() + 1 

# Initialize the NEW Transfer model and send to MPS (Mac GPU)
model = LorcanaTransferModel(num_characters=max_char_id, num_tabular_features=num_stats).to(device)

# --- 6. TRAINING SETUP ---

criterion = nn.MSELoss()
# Notice we keep learning rate slightly higher for the new MLPs
# We only train the new layers (the Fusion Head and MLPs) because ResNet is frozen!

optimizer = optim.Adam(model.parameters(), lr=0.0001) 

num_epochs = 30

# --- 7. THE TRAINING & VALIDATION LOOP ---
print("🚀 Starting Transfer Learning Training...")
for epoch in range(num_epochs):
    
    # --- TRAINING PHASE ---
    model.train()
    train_running_loss = 0.0
    for images, char_ids, tabs, targets in train_loader:
        # Move ALL inputs to the GPU/MPS
        images = images.to(device)
        char_ids = char_ids.to(device)
        tabs = tabs.to(device)
        targets = targets.to(device).float()
        
        optimizer.zero_grad()
        
        # Feed all three inputs to the new ResNet multimodal model
        outputs = model(images, char_ids, tabs)
        loss = criterion(outputs.squeeze(), targets.view(-1))
        
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
        optimizer.step()
        
        train_running_loss += loss.item()
        
    avg_train_loss = train_running_loss / len(train_loader)
    
    # --- VALIDATION PHASE ---
    model.eval()
    val_running_loss = 0.0
    with torch.no_grad():
        for images, char_ids, tabs, targets in val_loader:
            # Move validation data to GPU/MPS
            images = images.to(device)
            char_ids = char_ids.to(device)
            tabs = tabs.to(device)
            targets = targets.to(device).float()
            
            outputs = model(images, char_ids, tabs)
            loss = criterion(outputs.squeeze(), targets.view(-1))
            val_running_loss += loss.item()
            
    avg_val_loss = val_running_loss / len(val_loader)
    
    print(f"Epoch {epoch+1:02d}/{num_epochs:02d} | Train Loss: {avg_train_loss:.4f} | Val Loss: {avg_val_loss:.4f}")

print("🎉 Finished Transfer Learning!")