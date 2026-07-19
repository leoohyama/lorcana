"""Visualize what the reconciliation model does vs the naive estimates:
the modeled TRUE value against (a) the eBay raw-ask median and (b) the
JustTCG market price, per card. Points off the diagonal = where the model
disagrees with just taking a median.

Also dumps latent_dashboard_data.json for the interactive artifact.
"""

import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.colors import LinearSegmentedColormap, TwoSlopeNorm

HERE = Path(__file__).parent
SURFACE, INK, INK2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9"
CMAP = LinearSegmentedColormap.from_list(
    "mis", ["#104281", "#2a78d6", "#f0efec", "#e34948", "#8f2726"])


def assemble() -> pd.DataFrame:
    mis = pd.read_csv(HERE / "mispricing_deltas.csv")
    obs = pd.read_parquet(HERE / "listing_observations.parquet")
    raw_med = obs[obs.tier == "raw"].groupby("card_id").price.median().rename("ebay_raw_median")
    jt = obs[obs.tier == "justtcg"].set_index("card_id").price.rename("justtcg")
    df = (mis.merge(raw_med, left_on="id", right_index=True, how="left")
             .merge(jt, left_on="id", right_index=True, how="left"))
    return df


def _panel(ax, x, y, c, norm, title, xlabel):
    ok = x.notna() & y.notna()
    x, y, c = x[ok], y[ok], c[ok]
    lo, hi = 0.7 * min(x.min(), y.min()), 1.4 * max(x.max(), y.max())
    ax.plot([lo, hi], [lo, hi], color=MUTED, lw=1, ls="--", zorder=1)
    ax.scatter(x, y, c=c, cmap=CMAP, norm=norm, s=42, alpha=0.9,
               edgecolors=SURFACE, linewidths=0.5, zorder=3)
    ax.set(xscale="log", yscale="log", xlim=(lo, hi), ylim=(lo, hi))
    ax.set_title(title, color=INK, fontsize=12, loc="left", pad=8)
    ax.set_xlabel(xlabel, color=INK2, fontsize=10)
    ax.set_ylabel("Reconciled true value  ($)", color=INK2, fontsize=10)
    ax.tick_params(colors=MUTED, labelsize=8)
    ax.grid(True, color=GRID, lw=0.5, which="both")
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    # annotate: median ratio naive/true, to show systematic gap
    ratio = np.median(x / y)
    ax.text(0.03, 0.97, f"median  {xlabel.split(' ')[0]} / true = {ratio:.2f}×",
            transform=ax.transAxes, va="top", fontsize=9, color=INK2)


def main():
    df = assemble()
    lim = float(np.nanpercentile(np.abs(df.delta_char), 98))
    norm = TwoSlopeNorm(vmin=-lim, vcenter=0, vmax=lim)

    fig, axes = plt.subplots(1, 2, figsize=(13, 6), facecolor=SURFACE)
    for ax in axes:
        ax.set_facecolor(SURFACE)
    _panel(axes[0], df.ebay_raw_median, df.true_value_usd, df.delta_char, norm,
           "eBay raw-ask median vs true value", "eBay raw-ask median  ($)")
    _panel(axes[1], df.justtcg, df.true_value_usd, df.delta_char, norm,
           "JustTCG market vs true value", "JustTCG market  ($)")
    fig.suptitle("What reconciliation does to the naive price  "
                 "(points below the dashed line = naive estimate runs high)",
                 color=INK, fontsize=13, x=0.02, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.96))
    fig.savefig(HERE / "true_vs_naive.png", dpi=150, facecolor=SURFACE)
    print("saved true_vs_naive.png")

    # biggest disagreements between true value and the naive blend
    df["naive_blend"] = df[["ebay_raw_median", "justtcg"]].mean(axis=1)
    df["true_vs_naive_pct"] = df.true_value_usd / df.naive_blend - 1
    cols = ["name", "version", "justtcg", "ebay_raw_median",
            "true_value_usd", "true_vs_naive_pct"]
    print("\nModel most BELOW the naive blend (naive overstates):")
    print(df.nsmallest(8, "true_vs_naive_pct")[cols].round(2).to_string(index=False))

    # dump data for the interactive artifact
    keep = ["name", "version", "set_name", "rarity", "umap_x", "umap_y",
            "true_value_usd", "justtcg", "ebay_raw_median", "fair_char_usd",
            "delta_char", "fame_premium", "mispricing_pct"]
    out = df[keep].replace({np.nan: None}).round(3)
    (HERE / "latent_dashboard_data.json").write_text(
        json.dumps(out.to_dict(orient="records")))
    print(f"wrote latent_dashboard_data.json ({len(out)} cards)")


if __name__ == "__main__":
    main()
