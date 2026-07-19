"""Project a (N, 64) latent tensor to 2D with UMAP, colored by mispricing.

Dashboard readout: X/Y = structural similarity (cards near each other share
intrinsic DNA), color = mispricing delta (log market price - fair value).
Diverging colormap: blue = underpriced, red = overpriced, gray = fairly priced.

Run: python umap_projection.py   (writes umap_mispricing.png next to itself)
Swap `make_dummy_latents()` for the real bottleneck + OOF residuals.
"""

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import umap
from matplotlib.colors import LinearSegmentedColormap, TwoSlopeNorm
from sklearn.preprocessing import StandardScaler

SEED = 42
N_CARDS = 284
LATENT_DIM = 64

# Chart ink/chrome (light mode)
SURFACE = "#fcfcfb"
INK_PRIMARY = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#898781"
GRID = "#e1e0d9"

# Diverging ramp: blue pole <- neutral gray midpoint -> red pole
CMAP = LinearSegmentedColormap.from_list(
    "mispricing",
    ["#104281", "#2a78d6", "#f0efec", "#e34948", "#8f2726"],
)


def make_dummy_latents(n=N_CARDS, d=LATENT_DIM, n_clusters=5, seed=SEED):
    """Clustered dummy latents + a residual array loosely tied to clusters,
    mimicking 'structural neighborhoods with pockets of mispricing'."""
    rng = np.random.default_rng(seed)
    centers = rng.normal(0, 2.2, size=(n_clusters, d))
    labels = rng.integers(0, n_clusters, size=n)
    z = centers[labels] + rng.normal(0, 0.8, size=(n, d))
    cluster_bias = rng.normal(0, 0.25, size=n_clusters)
    residuals = cluster_bias[labels] + rng.normal(0, 0.18, size=n)
    return z.astype(np.float32), residuals.astype(np.float32)


def project_2d(latents: np.ndarray, seed=SEED) -> np.ndarray:
    z = StandardScaler().fit_transform(latents)
    reducer = umap.UMAP(
        n_neighbors=15,     # ~5% of N; raise for more global structure
        min_dist=0.1,
        metric="euclidean",
        random_state=seed,
    )
    return reducer.fit_transform(z)


def plot(xy: np.ndarray, residuals: np.ndarray, out_path: Path,
         card_names: list[str] | None = None):
    fig, ax = plt.subplots(figsize=(9, 7), facecolor=SURFACE)
    ax.set_facecolor(SURFACE)

    lim = float(np.abs(residuals).max())
    norm = TwoSlopeNorm(vmin=-lim, vcenter=0.0, vmax=lim)

    sc = ax.scatter(
        xy[:, 0], xy[:, 1],
        c=residuals, cmap=CMAP, norm=norm,
        s=55, edgecolors=SURFACE, linewidths=0.6, zorder=3,
    )

    # Direct-label only the extremes - the cards a trader would act on
    k = 3
    for group in (np.argsort(residuals)[:k], np.argsort(residuals)[-k:]):
        # spread labels vertically in the same order as their points sit,
        # so near-coincident extremes don't overprint each other
        for rank, idx in enumerate(group[np.argsort(xy[group, 1])]):
            name = card_names[idx] if card_names else f"card {idx}"
            ax.annotate(
                f"{name} ({residuals[idx]:+.2f})",
                xy=(xy[idx, 0], xy[idx, 1]),
                xytext=(8, (rank - (k - 1) / 2) * 18),
                textcoords="offset points", fontsize=8, color=INK_SECONDARY,
            )

    cbar = fig.colorbar(sc, ax=ax, shrink=0.8, pad=0.02)
    cbar.set_label("Mispricing Δ  (log market − fair value)",
                   color=INK_SECONDARY, fontsize=9)
    cbar.ax.tick_params(colors=INK_MUTED, labelsize=8)
    cbar.outline.set_visible(False)

    ax.set_title("Latent card space — colored by mispricing",
                 color=INK_PRIMARY, fontsize=13, loc="left", pad=12)
    ax.set_xlabel("UMAP 1", color=INK_MUTED, fontsize=9)
    ax.set_ylabel("UMAP 2", color=INK_MUTED, fontsize=9)
    ax.tick_params(colors=INK_MUTED, labelsize=8)
    ax.grid(True, color=GRID, linewidth=0.6, zorder=0)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)

    fig.tight_layout()
    fig.savefig(out_path, dpi=150, facecolor=SURFACE)
    print(f"saved {out_path}")


if __name__ == "__main__":
    latents, residuals = make_dummy_latents()
    xy = project_2d(latents)
    plot(xy, residuals, Path(__file__).parent / "umap_mispricing.png")
