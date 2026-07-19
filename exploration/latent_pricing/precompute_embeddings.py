"""Stage A of the zero-training pipeline: run every card scan through a
frozen ResNet-50 exactly once and cache the 2048D avgpool features.

Output: vision_embeddings.parquet (id + emb_0000..emb_2047), keyed by the
lorcast crd_ id. Re-run only when new card images arrive.
"""

import glob
import os
from pathlib import Path

import pandas as pd
import pillow_avif  # noqa: F401  (registers the .avif decoder in PIL)
import torch
from PIL import Image
from torchvision import transforms
from torchvision.models import resnet50, ResNet50_Weights

HERE = Path(__file__).parent
IMAGE_ROOT = HERE.parents[1] / "data" / "enchanteds" / "images"
OUT = HERE / "vision_embeddings.parquet"
BATCH = 32

device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")

preprocess = transforms.Compose([
    transforms.Resize((224, 224)),
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
])


def main():
    paths = sorted(glob.glob(str(IMAGE_ROOT / "**" / "*.avif"), recursive=True))
    ids = [os.path.basename(p).split(".")[0] for p in paths]
    print(f"{len(paths)} card scans under {IMAGE_ROOT}")

    backbone = resnet50(weights=ResNet50_Weights.IMAGENET1K_V2)
    backbone.fc = torch.nn.Identity()
    backbone.eval().to(device)

    feats = []
    with torch.no_grad():
        for i in range(0, len(paths), BATCH):
            batch = torch.stack([
                preprocess(Image.open(p).convert("RGB"))
                for p in paths[i:i + BATCH]
            ]).to(device)
            feats.append(backbone(batch).cpu())
            print(f"  {min(i + BATCH, len(paths))}/{len(paths)}")

    emb = torch.cat(feats).numpy()
    df = pd.DataFrame(emb, columns=[f"emb_{j:04d}" for j in range(emb.shape[1])])
    df.insert(0, "id", ids)
    df.to_parquet(OUT)
    print(f"wrote {OUT} {df.shape}")


if __name__ == "__main__":
    main()
