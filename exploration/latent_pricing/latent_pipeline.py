"""Block B of the latent-measurement pipeline: position each card's latent
TRUE value (from reconcile_true_value.py) in a fused feature space and read
mispricing as the gap between market-reconciled value and feature-implied
value.

Target = true_log_value (Block A's reconciliation of eBay raw/graded asks +
JustTCG into one realized value per card) - NOT a single raw price.

Fused frozen space = PCA-whitened ResNet-50 art features + standardized
tabular block. Two feature sets, two fair values:
- structural: intrinsic DNA + art only. delta_structural = true value vs
  what the card fundamentally IS (the full scarcity/hype premium).
- full: + demand block (character popularity, churn/volume, volatility,
  liquidity). delta_full = mispricing after everything we can measure about
  demand is accounted for - the actionable cross-sectional signal.
  premium_component = delta_structural - delta_full = the part of the
  premium that measurable demand explains.

Plus an EXECUTION table: cheapest live raw ask vs true value (buyable
dislocations) and per-tier graded-ask arbitrage vs the premium ladder.

Inputs: true_value.parquet, premium_ladder.parquet/csv,
  listing_observations.parquet, card_ts_metrics.parquet,
  vision_embeddings.parquet, card_names.csv,
  ../../data/tabular/ready_for_pytorch.parquet

Outputs: mispricing_deltas.csv, execution_signals.csv, model_scoreboard.csv,
  umap_mispricing_real.png (structural), umap_demand_adjusted.png (full)
"""

from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.decomposition import PCA
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.gaussian_process import GaussianProcessRegressor
from sklearn.gaussian_process.kernels import RBF, ConstantKernel, WhiteKernel
from sklearn.linear_model import RidgeCV
from sklearn.metrics import mean_absolute_error, r2_score
from sklearn.model_selection import LeaveOneOut, cross_val_predict
from sklearn.neighbors import KNeighborsRegressor
from sklearn.preprocessing import StandardScaler

from umap_projection import plot, project_2d

HERE = Path(__file__).parent
SEED = 42
N_VISION_COMPS = 32
UNIVERSE_RARITIES = {"Enchanted", "Iconic"}  # Epics excluded: different market tier

# Intrinsic DNA only - no market metrics enter the feature space (README §2).
# character_id is deliberately dropped: too high-cardinality for N~250, and
# the image embedding already carries character identity via the art.
TABULAR_COLS = [
    "cost", "strength", "willpower", "lore", "is_character",
    "ink_Amber", "ink_Amethyst", "ink_Emerald", "ink_Ruby",
    "ink_Sapphire", "ink_Steel",
    "type_clean_Action", "type_clean_Action Song", "type_clean_Character",
    "type_clean_Item", "type_clean_Location",
    "rarity_Enchanted", "rarity_Epic", "rarity_Iconic",
    "days_since_launch",
]
# Demand block. Deliberately excludes any price LEVEL or near-copy of it.
# - popularity: how often a character is printed / premium-treated (publisher
#   revealed demand, from the full 2,594-printing pool - fully exogenous).
# - activity: price-shape stats + listing depth/turnover. These are counts,
#   dispersions, and mean-reversion, not levels.
# NOTE: card_ts_metrics.days_in_30d was DROPPED - it correlates 0.96 with the
# true-value target (a volume channel co-measured with price), so including it
# collapses the mispricing signal. That's the leakage rule in action.
# Scarcity note: listing *share* of the total is 0.999 collinear with
# log_n_listings (the total is a per-snapshot constant), so it adds nothing.
# A supply-per-print scarcity ratio (log_n_listings - log_n_printings) has the
# right sign in isolation (-0.18 vs +0.26 for the raw count) but is a linear
# combination of two features already here, so Ridge forms it implicitly and
# adding it explicitly gave no OOF lift - left out to keep the model lean.
POPULARITY_COLS = ["log_n_printings", "log_n_premium"]
ACTIVITY_COLS = ["cv_30d", "hurst_30d", "log_n_listings", "log_median_age"]
DEMAND_COLS = POPULARITY_COLS + ACTIVITY_COLS


def build_dataset() -> pd.DataFrame:
    tab = pd.read_parquet(HERE.parents[1] / "data/tabular/ready_for_pytorch.parquet")
    vis = pd.read_parquet(HERE / "vision_embeddings.parquet")
    names = pd.read_csv(HERE / "card_names.csv")
    tv = pd.read_parquet(HERE / "true_value.parquet")            # Block A target
    ts = pd.read_parquet(HERE / "card_ts_metrics.parquet")
    obs = pd.read_parquet(HERE / "listing_observations.parquet")

    # character popularity from the FULL card pool, before any filtering
    premium = tab[["rarity_Enchanted", "rarity_Epic", "rarity_Iconic",
                   "rarity_Legendary"]].sum(axis=1)
    pop = (tab.assign(premium=premium)
              .groupby("character_id")
              .agg(n_printings=("id", "size"), n_premium=("premium", "sum"))
              .reset_index())
    pop["log_n_printings"] = np.log1p(pop.n_printings)
    pop["log_n_premium"] = np.log1p(pop.n_premium)

    # market-activity block from card_ts_metrics + listing depth / turnover.
    # eBay listings only (drop the single JustTCG obs) for the depth count.
    ts = ts.copy()
    ts["tcgplayer_id"] = pd.to_numeric(ts.tcgplayer_id, errors="coerce")
    liq = (obs[obs.tier != "justtcg"].groupby("card_id")
              .agg(n_listings=("price", "size"), median_age=("age_days", "median"))
              .reset_index())
    liq["log_n_listings"] = np.log1p(liq.n_listings)
    liq["log_median_age"] = np.log1p(liq.median_age)

    df = (
        tab.merge(pop[["character_id", *POPULARITY_COLS]], on="character_id")
           .merge(names, on="id")
           .merge(tv[["card_id", "true_log_value", "true_value_usd",
                      "true_value_se"]], left_on="id", right_on="card_id")
           .merge(vis, on="id")
           .merge(ts[["tcgplayer_id", "cv_30d", "hurst_30d"]],
                  on="tcgplayer_id", how="left")
           .merge(liq[["card_id", "log_n_listings", "log_median_age"]],
                  on="card_id", how="left")
    )
    df = df[df.rarity.isin(UNIVERSE_RARITIES)].reset_index(drop=True)

    # median-impute the few cards missing activity metrics (keeps them in play)
    for c in ACTIVITY_COLS:
        df[c] = df[c].fillna(df[c].median())

    df["y"] = df.true_log_value  # regression target = reconciled true value
    print(f"universe: {len(df)} Enchanted+Iconic cards")
    print(df.rarity.value_counts().to_string())
    return df


def fuse(df: pd.DataFrame, tabular_cols: list[str]) -> np.ndarray:
    """PCA-whitened vision block + standardized tabular block, each block
    scaled to equal total variance so neither modality dominates distances."""
    emb_cols = [c for c in df.columns if c.startswith("emb_")]
    vision_block = PCA(n_components=N_VISION_COMPS, whiten=True,
                       random_state=SEED).fit_transform(df[emb_cols])

    tab_raw = df[tabular_cols].astype(float)
    keep = tab_raw.columns[tab_raw.std() > 0]  # drop constants in this universe
    tab_block = StandardScaler().fit_transform(tab_raw[keep])

    vision_block /= np.sqrt(vision_block.shape[1])
    tab_block /= np.sqrt(tab_block.shape[1])

    fused = np.hstack([vision_block, tab_block]).astype(np.float32)
    print(f"fused space: {fused.shape[1]}D "
          f"({N_VISION_COMPS} vision + {tab_block.shape[1]} tabular)")
    return fused


def fair_value_oof(fused: np.ndarray, y: np.ndarray) -> tuple[pd.DataFrame, np.ndarray]:
    """LOO out-of-fold predictions from several regressors; returns the
    scoreboard and the OOF predictions of the winner."""
    alphas = np.logspace(-2, 3, 25)
    models = {
        "ridge": RidgeCV(alphas=alphas),
        "knn10": KNeighborsRegressor(n_neighbors=10, weights="distance"),
        "gp_rbf": GaussianProcessRegressor(
            kernel=ConstantKernel() * RBF(length_scale=np.sqrt(fused.shape[1]))
                   + WhiteKernel(),
            normalize_y=True, random_state=SEED),
        "hgb": HistGradientBoostingRegressor(
            max_iter=300, max_depth=3, learning_rate=0.05,
            l2_regularization=1.0, random_state=SEED),
    }
    rows, preds = [], {}
    for name, model in models.items():
        oof = cross_val_predict(model, fused, y, cv=LeaveOneOut(), n_jobs=-1)
        preds[name] = oof
        rows.append({"model": name,
                     "oof_r2": r2_score(y, oof),
                     "oof_mae_log": mean_absolute_error(y, oof),
                     "median_abs_pct_err": float(np.median(np.abs(np.expm1(oof - y))))})
    board = pd.DataFrame(rows).sort_values("oof_r2", ascending=False)
    winner = board.iloc[0].model
    print(board.to_string(index=False))
    print(f"-> fair-value model: {winner}")
    return board, preds[winner]


def character_effect(chars: np.ndarray, resid: np.ndarray, K: float = 2.5):
    """Leakage-safe character-fame premium: for each card, the shrunk mean of
    OTHER same-character cards' residuals (leave-one-out), so it can never see
    its own price. Captures whether being e.g. a Mickey Mouse card commands a
    premium BEYOND the card's attributes and printing-count popularity.
    Singletons (121 of 193) get 0. K sets how fast a character earns its own
    premium as its card count grows.

    Returns per-card LOO effect (for prediction) and a per-character summary
    with the in-sample shrunk premium (for reporting).
    """
    d = pd.DataFrame({"char": chars, "r": resid})
    g = d.groupby("char").r
    n, S = g.transform("size").to_numpy(), g.transform("sum").to_numpy()
    loo_mean = np.where(n > 1, (S - d.r.to_numpy()) / np.maximum(n - 1, 1), 0.0)
    loo_effect = np.where(n > 1, (n - 1) / (n - 1 + K), 0.0) * loo_mean

    summ = d.groupby("char").agg(n_cards=("r", "size"), mean_resid=("r", "mean"))
    summ["premium_log"] = summ.n_cards / (summ.n_cards + K) * summ.mean_resid
    summ["premium_pct"] = np.expm1(summ.premium_log)
    return loo_effect, summ.reset_index()


def execution_signals(df: pd.DataFrame) -> pd.DataFrame:
    """Buyable dislocations: cheapest live raw ask vs reconciled true value,
    and cheapest graded ask vs its tier's premium-implied value. Negative
    delta = the ask is below fair -> a deal you could actually take."""
    obs = pd.read_parquet(HERE / "listing_observations.parquet")
    ladder = pd.read_parquet(HERE / "premium_ladder.parquet").set_index("tier")
    tv = df.set_index("card_id")

    obs = obs[obs.card_id.isin(tv.index)].copy()
    obs["premium_log"] = obs.tier.map(ladder.premium_log).fillna(0.0)
    obs["true_log_value"] = obs.card_id.map(tv.true_log_value)
    # implied fair ask for this listing's tier = true value x tier premium
    obs["tier_fair_usd"] = np.exp(obs.true_log_value + obs.premium_log)
    obs["ask_vs_fair"] = np.log(obs.price) - (obs.true_log_value + obs.premium_log)

    # Junk floor: an ask >70% below its tier's fair value is almost always a
    # proxy/token/lot/damaged listing, not a real deal. The cheapest ask is
    # the single most pollution-prone statistic, so gate it hard.
    obs = obs[obs.ask_vs_fair > np.log(0.30)]

    # cheapest current listing per (card, coarse tier) that beats fair
    obs["tier_group"] = np.where(obs.tier == "raw", "raw",
                         np.where(obs.tier == "justtcg", "justtcg", "graded"))
    best = (obs.sort_values("ask_vs_fair")
               .groupby(["card_id", "tier_group"], as_index=False).first())
    best = best.merge(tv[["name", "version", "rarity", "true_value_usd"]],
                      left_on="card_id", right_index=True)
    best["deal_pct"] = np.expm1(best.ask_vs_fair)  # <0 => below fair
    return best.sort_values("ask_vs_fair")


def main():
    df = build_dataset()
    y = df.y.to_numpy()

    print("\n--- structural model (intrinsic DNA + art only) ---")
    fused_struct = fuse(df, TABULAR_COLS)
    board_s, oof_s = fair_value_oof(fused_struct, y)

    print("\n--- full model (+ demand: popularity, churn/volume, liquidity) ---")
    fused_full = fuse(df, TABULAR_COLS + DEMAND_COLS)
    board_f, oof_f = fair_value_oof(fused_full, y)

    # character-fame premium: LOO-shrunk residual by base character name, added
    # on top of the full model. If it lifts OOF R2, being e.g. a Mickey card
    # genuinely predicts price beyond attributes+popularity (leakage-safe: each
    # card sees only OTHER same-character cards).
    fame_eff, fame_summary = character_effect(df.name.to_numpy(), y - oof_f)
    oof_c = oof_f + fame_eff
    r2_f, r2_c = r2_score(y, oof_f), r2_score(y, oof_c)
    print(f"\ncharacter-fame effect: OOF R2 {r2_f:.3f} -> {r2_c:.3f} "
          f"(+{r2_c - r2_f:.3f})")

    df["fair_structural_usd"] = np.exp(oof_s)
    df["fair_full_usd"] = np.exp(oof_f)
    df["fair_char_usd"] = np.exp(oof_c)
    df["fame_premium"] = fame_eff                       # log; per-card fame add
    df["delta_structural"] = y - oof_s   # true value vs what the card IS
    df["delta_full"] = y - oof_f         # net of measurable demand
    df["delta_char"] = y - oof_c         # + net of character fame (actionable)
    df["premium_component"] = df.delta_structural - df.delta_full
    df["mispricing_pct"] = np.expm1(df.delta_char)

    # map coordinates come from the structural space: X/Y = what the card IS
    xy = project_2d(fused_struct, seed=SEED)
    df["umap_x"], df["umap_y"] = xy[:, 0], xy[:, 1]

    label = (df.name + " (" + df.set_name.str.replace("The ", "", regex=False) + ")")
    plot(xy, df.delta_structural.to_numpy(),
         HERE / "umap_mispricing_real.png", card_names=label.tolist())
    plot(xy, df.delta_char.to_numpy(),
         HERE / "umap_demand_adjusted.png", card_names=label.tolist())

    out_cols = ["id", "tcgplayer_id", "name", "version", "set_name", "rarity",
                "true_value_usd", "true_value_se", "fair_structural_usd",
                "fair_full_usd", "fair_char_usd", "delta_structural",
                "delta_full", "delta_char", "premium_component", "fame_premium",
                "mispricing_pct", "umap_x", "umap_y"]
    out = df[out_cols].sort_values("delta_char")
    out.to_csv(HERE / "mispricing_deltas.csv", index=False)
    pd.concat([board_s.assign(model_set="structural"),
               board_f.assign(model_set="full")]
              ).to_csv(HERE / "model_scoreboard.csv", index=False)
    fame_summary.sort_values("premium_log", ascending=False).to_csv(
        HERE / "character_premiums.csv", index=False)

    execu = execution_signals(df)
    execu.to_csv(HERE / "execution_signals.csv", index=False)

    fmt = out[["name", "version", "true_value_usd", "fair_char_usd",
               "mispricing_pct"]].round(2)
    print("\nMarket values BELOW fundamentals (value candidates):")
    print(fmt.head(10).to_string(index=False))
    print("\nMarket values ABOVE fundamentals (scarcity/hype beyond model):")
    print(fmt.tail(10).iloc[::-1].to_string(index=False))
    print("\nBiggest character-fame premiums (>=2 cards, beyond attributes):")
    print(fame_summary[fame_summary.n_cards >= 2]
          .sort_values("premium_log", ascending=False).head(8)[
              ["char", "n_cards", "premium_pct"]].round(2).to_string(index=False))


if __name__ == "__main__":
    main()
