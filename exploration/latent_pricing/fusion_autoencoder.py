"""Intermediate-fusion autoencoder for TCG latent pricing.

Two branches -> project to a common width -> LayerNorm each -> concat ->
fusion MLP -> bottleneck z -> decode both modalities (+ optional price head).

Design notes (see README.md for the full review):
- Vision branch is FROZEN; reconstruct its *embedding*, never pixels.
- Each branch is LayerNorm'd at the same width before fusion so neither
  modality dominates by scale or dimensionality.
- Modality dropout stops the trainable tabular path from shortcutting the
  frozen visual path.
- latent_dim defaults to 16: at N=284 a 64-128D trained bottleneck memorizes.
  Raise it only when training on the full all-rarities card pool.
- price_head=True turns this into a supervised bottleneck (hedonic model with
  reconstruction as auxiliary regularizer) - the recommended training mode.
"""

from dataclasses import dataclass, field

import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision.models import resnet50, ResNet50_Weights


@dataclass
class FusionConfig:
    # cardinality per categorical column, e.g. {"character_id": 180, "set_id": 9}
    cat_cardinalities: dict = field(default_factory=dict)
    n_continuous: int = 8
    branch_dim: int = 64        # common width both branches project to
    latent_dim: int = 16        # bottleneck; see docstring before raising
    fusion_hidden: int = 128
    dropout: float = 0.25
    modality_dropout: float = 0.15  # p of zeroing a whole branch during training
    price_head: bool = True


def embedding_dim(cardinality: int) -> int:
    return min(50, (cardinality + 1) // 2)


class VisionEncoder(nn.Module):
    """Frozen ResNet-50 avgpool features (2048D) -> projection to branch_dim.

    Only the projection head trains. For efficiency, precompute
    `backbone_features` once for the whole dataset (see README checklist) and
    call `forward(precomputed=...)` at train time.
    """

    BACKBONE_DIM = 2048

    def __init__(self, branch_dim: int, dropout: float):
        super().__init__()
        backbone = resnet50(weights=ResNet50_Weights.IMAGENET1K_V2)
        backbone.fc = nn.Identity()
        backbone.eval()
        for p in backbone.parameters():
            p.requires_grad = False
        self.backbone = backbone

        self.project = nn.Sequential(
            nn.Linear(self.BACKBONE_DIM, branch_dim),
            nn.GELU(),
            nn.Dropout(dropout),
            nn.LayerNorm(branch_dim),
        )

    def train(self, mode: bool = True):
        super().train(mode)
        self.backbone.eval()  # frozen BN stats stay frozen
        return self

    @torch.no_grad()
    def backbone_features(self, images: torch.Tensor) -> torch.Tensor:
        """(B, 3, 224, 224) -> (B, 2048). Use once to precompute embeddings."""
        return self.backbone(images)

    def forward(self, images: torch.Tensor | None = None,
                precomputed: torch.Tensor | None = None) -> torch.Tensor:
        if precomputed is None:
            precomputed = self.backbone_features(images)
        return self.project(precomputed)


class TabularEncoder(nn.Module):
    """Categorical embeddings + standardized continuous -> MLP -> branch_dim.

    Continuous inputs are assumed z-scored upstream (fit scalers on train
    folds only). Intrinsic card DNA only - no market metrics (see README §2).
    """

    def __init__(self, cfg: FusionConfig):
        super().__init__()
        self.embeddings = nn.ModuleDict({
            name: nn.Embedding(card, embedding_dim(card))
            for name, card in cfg.cat_cardinalities.items()
        })
        emb_total = sum(embedding_dim(c) for c in cfg.cat_cardinalities.values())
        in_dim = emb_total + cfg.n_continuous

        self.mlp = nn.Sequential(
            nn.Linear(in_dim, cfg.fusion_hidden),
            nn.GELU(),
            nn.Dropout(cfg.dropout),
            nn.Linear(cfg.fusion_hidden, cfg.branch_dim),
            nn.GELU(),
            nn.LayerNorm(cfg.branch_dim),
        )

    def forward(self, cats: dict[str, torch.Tensor],
                conts: torch.Tensor) -> torch.Tensor:
        parts = [self.embeddings[name](idx) for name, idx in cats.items()]
        parts.append(conts)
        return self.mlp(torch.cat(parts, dim=-1))


class FusionAutoencoder(nn.Module):
    def __init__(self, cfg: FusionConfig):
        super().__init__()
        self.cfg = cfg
        self.vision = VisionEncoder(cfg.branch_dim, cfg.dropout)
        self.tabular = TabularEncoder(cfg)

        self.fusion = nn.Sequential(
            nn.Linear(2 * cfg.branch_dim, cfg.fusion_hidden),
            nn.GELU(),
            nn.Dropout(cfg.dropout),
            nn.Linear(cfg.fusion_hidden, cfg.latent_dim),
        )

        # Decoders: tabular continuous (MSE), one logit head per categorical
        # (CE), and the vision *embedding* at backbone width (MSE) - keeping a
        # vision target is what forces z to retain visual information.
        self.decode_shared = nn.Sequential(
            nn.Linear(cfg.latent_dim, cfg.fusion_hidden),
            nn.GELU(),
        )
        self.decode_cont = nn.Linear(cfg.fusion_hidden, cfg.n_continuous)
        self.decode_cats = nn.ModuleDict({
            name: nn.Linear(cfg.fusion_hidden, card)
            for name, card in cfg.cat_cardinalities.items()
        })
        self.decode_vision = nn.Linear(cfg.fusion_hidden, VisionEncoder.BACKBONE_DIM)

        self.price = (
            nn.Sequential(
                nn.Linear(cfg.latent_dim, cfg.latent_dim),
                nn.GELU(),
                nn.Linear(cfg.latent_dim, 1),
            )
            if cfg.price_head else None
        )

    def _modality_dropout(self, v: torch.Tensor, t: torch.Tensor):
        if not self.training or self.cfg.modality_dropout <= 0:
            return v, t
        b = v.shape[0]
        drop_v = torch.rand(b, 1, device=v.device) < self.cfg.modality_dropout
        drop_t = torch.rand(b, 1, device=t.device) < self.cfg.modality_dropout
        keep_both = drop_v & drop_t  # never drop both
        drop_v, drop_t = drop_v & ~keep_both, drop_t & ~keep_both
        return v.masked_fill(drop_v, 0.0), t.masked_fill(drop_t, 0.0)

    def forward(self, cats: dict[str, torch.Tensor], conts: torch.Tensor,
                images: torch.Tensor | None = None,
                vision_precomputed: torch.Tensor | None = None) -> dict:
        v = self.vision(images, precomputed=vision_precomputed)  # (B, branch)
        t = self.tabular(cats, conts)                            # (B, branch)
        v, t = self._modality_dropout(v, t)

        z = self.fusion(torch.cat([v, t], dim=-1))               # (B, latent)

        h = self.decode_shared(z)
        out = {
            "z": z,
            "recon_cont": self.decode_cont(h),
            "recon_cats": {n: head(h) for n, head in self.decode_cats.items()},
            "recon_vision": self.decode_vision(h),
        }
        if self.price is not None:
            out["log_price_pred"] = self.price(z).squeeze(-1)
        return out

    @torch.no_grad()
    def embed(self, cats, conts, images=None, vision_precomputed=None) -> torch.Tensor:
        """Latent codes for downstream pricing / UMAP (no modality dropout)."""
        was_training = self.training
        self.eval()
        z = self.forward(cats, conts, images, vision_precomputed)["z"]
        self.train(was_training)
        return z


def autoencoder_loss(out: dict, cats: dict[str, torch.Tensor],
                     conts: torch.Tensor, vision_target: torch.Tensor,
                     log_price: torch.Tensor | None = None,
                     recon_weight: float = 1.0,
                     price_weight: float = 1.0) -> dict:
    """Combined loss. Supervised mode: price_weight=1, recon_weight~0.2.

    `vision_target` is the frozen 2048D backbone embedding (the precomputed
    features), NOT pixels.
    """
    losses = {
        "cont": F.mse_loss(out["recon_cont"], conts),
        # embeddings have much larger raw MSE than z-scored conts; normalize
        "vision": F.mse_loss(out["recon_vision"], vision_target) / vision_target.var(),
    }
    for name, logits in out["recon_cats"].items():
        losses[f"cat_{name}"] = F.cross_entropy(logits, cats[name])

    total = recon_weight * sum(losses.values())
    if log_price is not None and "log_price_pred" in out:
        losses["price"] = F.mse_loss(out["log_price_pred"], log_price)
        total = total + price_weight * losses["price"]

    losses["total"] = total
    return losses


if __name__ == "__main__":
    # Smoke test with dummy shapes
    cfg = FusionConfig(
        cat_cardinalities={"character_id": 180, "set_id": 9, "ink": 6},
        n_continuous=8,
    )
    model = FusionAutoencoder(cfg)
    B = 4
    cats = {n: torch.randint(0, c, (B,)) for n, c in cfg.cat_cardinalities.items()}
    conts = torch.randn(B, cfg.n_continuous)
    vis = torch.randn(B, VisionEncoder.BACKBONE_DIM)  # precomputed features
    log_price = torch.randn(B)

    out = model(cats, conts, vision_precomputed=vis)
    losses = autoencoder_loss(out, cats, conts, vis, log_price, recon_weight=0.2)
    losses["total"].backward()

    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"z: {tuple(out['z'].shape)}  price: {tuple(out['log_price_pred'].shape)}")
    print(f"losses: { {k: round(v.item(), 3) for k, v in losses.items()} }")
    print(f"trainable params: {trainable:,} (vs N=284 cards - mind the gap)")
