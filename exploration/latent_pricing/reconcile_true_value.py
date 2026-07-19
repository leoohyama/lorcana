"""Block A of the latent-measurement pipeline: reconcile many noisy price
observations per card into one latent true (raw NM) value today.

Every observable price is modeled as:

    log(price) = V_card  +  premium[tier]  +  staleness(age)  +  noise

where V_card is the latent true log RAW value (the anchor), premium[tier] is
a pooled fixed effect per (grading company x grade) - raw ask is the
reference tier at 0 - and older asks are down-weighted (an unsold ask is a
loose upper bound on true value). Fitting is a weighted two-way fixed-effects
regression; card coefficients + intercept = V_card.

Channels: eBay raw asks, eBay graded asks (per company x grade), JustTCG raw
market price. Grade/company come parsed from llm_listing_metadata; listing
age comes from tracking each item_id across ~115 daily snapshots.

Outputs: listing_observations.parquet, true_value.parquet, premium_ladder.csv
"""

import os
import re
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

HERE = Path(__file__).parent
WINDOW_DAYS = 14         # trailing window of eBay snapshots pooled per card
MIN_TIER_LISTINGS = 15   # tiers rarer than this collapse into a catch-all
AGE_HALFLIFE = 30.0      # days; staleness down-weighting of asks
PRICE_FLOOR = 1.0


def connect():
    tok = re.search(r'MOTHERDUCK_TOKEN\s*=\s*"?([^"\n]+)"?',
                    open(os.path.expanduser("~/.Renviron")).read()).group(1).strip()
    return duckdb.connect(f"md:my_db?motherduck_token={tok}")


def build_observations() -> pd.DataFrame:
    con = connect()
    names = pd.read_csv(HERE / "card_names.csv")  # crd id <-> tcgplayer_id

    # eBay asks over a trailing WINDOW_DAYS window (not just the newest
    # snapshot): each listing's most recent price within the window, with age
    # measured from its full-history first-sighting. Pooling ~2 weeks lifts
    # thin cards (latest-snapshot p25 was 18 listings/card, 14d ~26) while
    # 14-day price drift is negligible (median 30d CV ~5%). Recency is handled
    # downstream by the age-decay weight, so blending stays minimal.
    ebay = con.execute(f"""
        WITH life AS (
            SELECT item_id,
                   date_diff('day', min(date_pulled), max(date_pulled)) AS age_days
            FROM lorcana_active_listings GROUP BY item_id
        ),
        recent AS (
            SELECT item_id, id, price_val
            FROM lorcana_active_listings
            WHERE date_pulled > (SELECT max(date_pulled) FROM lorcana_active_listings)
                              - INTERVAL {WINDOW_DAYS} DAY
              AND price_val IS NOT NULL
            QUALIFY row_number() OVER (PARTITION BY item_id
                                       ORDER BY date_pulled DESC) = 1
        )
        SELECT r.id AS card_id, r.price_val,
               m.is_valid, m.is_graded, m.grading_company, m.grade_val,
               life.age_days
        FROM recent r
        JOIN llm_listing_metadata m USING (item_id)
        LEFT JOIN life USING (item_id)
    """).df()

    # JustTCG raw market price -> one observation per card, current (age 0)
    jtcg = con.execute("""
        SELECT tcgplayer_id, market_price
        FROM justtcg_prices
        QUALIFY row_number() OVER (PARTITION BY tcgplayer_id
                                   ORDER BY pull_date DESC) = 1
    """).df().merge(names[["id", "tcgplayer_id"]], on="tcgplayer_id")

    # --- clean eBay ---
    ebay = ebay[(ebay.is_valid) & (ebay.price_val >= PRICE_FLOOR)].copy()
    ebay["age_days"] = ebay.age_days.fillna(0).clip(lower=0)
    ebay["tier"] = np.where(
        ~ebay.is_graded, "raw",
        ebay.grading_company.fillna("UNK") + "_" + ebay.grade_val.fillna("NA").astype(str))
    ebay = ebay.rename(columns={"price_val": "price"})[
        ["card_id", "price", "tier", "age_days"]]

    # --- JustTCG as its own raw-ish channel ---
    jtcg = jtcg[jtcg.market_price >= PRICE_FLOOR].copy()
    jtcg["tier"], jtcg["age_days"] = "justtcg", 0.0
    jtcg = jtcg.rename(columns={"market_price": "price", "id": "card_id"})[
        ["card_id", "price", "tier", "age_days"]]

    obs = pd.concat([ebay, jtcg], ignore_index=True)

    # collapse ultra-rare tiers so their premium isn't estimated on <15 points
    counts = obs.tier.value_counts()
    rare = counts[counts < MIN_TIER_LISTINGS].index
    obs.loc[obs.tier.isin(rare), "tier"] = "graded_other"

    # Robust per-(card,tier) junk removal. eBay is full of proxies, lots,
    # damaged cards, and mislabels; because the fit tracks the geometric mean
    # of log price, a low junk tail (a $6 listing on a $128 card) drags the
    # estimate down. A single card's single-condition asks realistically sit
    # within a factor BAND of their median, so drop anything outside that
    # (tiers with >=5 obs; thinner tiers lean on the reliability weights).
    obs["log_price"] = np.log(obs.price)
    BAND = np.log(2.5)
    def _trim(g):
        if len(g) < 5:
            return g
        return g[(g.log_price - g.log_price.median()).abs() <= BAND]
    obs = obs.groupby(["card_id", "tier"], group_keys=False).apply(_trim)

    # weight = staleness decay x channel reliability. Raw asks & JustTCG are
    # direct measurements of raw value; graded obs require dividing out an
    # uncertain pooled premium, so they inform V less when direct evidence
    # exists. JustTCG (realized market) is the most trustworthy level anchor.
    reliability = {"justtcg": 1.5, "raw": 1.0}
    obs["weight"] = (0.5 ** (obs.age_days / AGE_HALFLIFE)) * obs.tier.map(
        lambda t: reliability.get(t, 0.5))          # graded -> 0.5
    obs.loc[obs.tier == "justtcg", "weight"] = 1.5  # current, no staleness

    obs.to_parquet(HERE / "listing_observations.parquet")
    print(f"observations: {len(obs)} across {obs.card_id.nunique()} cards")
    print(obs.tier.value_counts().to_string())
    return obs


GRADED_ADJ_SD = 0.30   # prior SD (log) of a card's graded-premium deviation
REF = "justtcg"        # reference tier -> V_card is realized market value


def _is_graded(tier: pd.Series) -> np.ndarray:
    return ((tier != REF) & ~tier.str.startswith("raw")).to_numpy()


def _solve(obs: pd.DataFrame, tier_col: str) -> dict:
    """Weighted, partially-pooled fixed-effects solve in log space:

        log_price = V_card + premium[tier] + graded_adj[card]*1[graded] + noise

    graded_adj is L2-shrunk toward the pooled ladder (Tikhonov). Returns the
    coefficient blocks and per-coefficient SEs.
    """
    cards = sorted(obs.card_id.unique())
    tiers = sorted(t for t in obs[tier_col].unique() if t != REF)
    graded = _is_graded(obs[tier_col])
    adj_cards = sorted(obs.loc[graded, "card_id"].unique())

    c_idx = {c: i for i, c in enumerate(cards)}
    t_idx = {t: len(cards) + i for i, t in enumerate(tiers)}
    a_idx = {c: len(cards) + len(tiers) + i for i, c in enumerate(adj_cards)}

    n = len(obs)
    p = len(cards) + len(tiers) + len(adj_cards)
    X = np.zeros((n, p))
    rows = np.arange(n)
    X[rows, obs.card_id.map(c_idx).to_numpy()] = 1.0
    non_ref = obs[tier_col] != REF
    X[rows[non_ref.to_numpy()], obs[tier_col][non_ref].map(t_idx).to_numpy()] = 1.0
    g_rows = rows[graded]
    X[g_rows, obs.card_id.iloc[g_rows].map(a_idx).to_numpy()] = 1.0

    w = obs.weight.to_numpy()
    yw = obs.log_price.to_numpy() * np.sqrt(w)
    Xw = X * np.sqrt(w)[:, None]
    XtWX = Xw.T @ Xw

    sigma2_0 = float((w * (obs.log_price.to_numpy()
                     - X @ (np.linalg.pinv(XtWX) @ (Xw.T @ yw)))**2).sum() / max(n - p, 1))
    lam = sigma2_0 / GRADED_ADJ_SD**2
    penalty = np.zeros(p)
    penalty[len(cards) + len(tiers):] = lam

    A_inv = np.linalg.pinv(XtWX + np.diag(penalty))
    beta = A_inv @ (Xw.T @ yw)
    resid = obs.log_price.to_numpy() - X @ beta
    sigma2 = float((w * resid**2).sum() / max(n - p, 1))
    se = np.sqrt(np.clip(np.diag(A_inv) * sigma2, 0, None))
    return dict(cards=cards, tiers=tiers, adj_cards=adj_cards, a_idx=a_idx,
                V=beta[:len(cards)], V_se=se[:len(cards)],
                premium=beta[len(cards):len(cards) + len(tiers)],
                graded_adj=beta[[a_idx[c] for c in adj_cards]],
                lam=lam, sigma2=sigma2, n=n, p=p)


def fit_reconciliation(obs: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Two-pass fit. Pass 1 estimates each card's value with a single pooled
    raw-ask premium. Pass 2 splits the raw premium BY VALUE TIER, because ask
    inflation shrinks with price (a $1,000 card is listed near $1,100, not
    $1,600) - a single global 1.6x over-deflated grails below market. Grading
    premium stays partially pooled per card (v2).
    """
    ref = REF
    pass1 = _solve(obs, "tier")
    V0 = pd.Series(pass1["V"], index=pass1["cards"])

    # value terciles from the first-pass estimate; split raw asks accordingly
    bucket = pd.qcut(V0, 3, labels=["lo", "mid", "hi"])
    obs = obs.copy()
    b = obs.card_id.map(bucket)
    obs["tier2"] = np.where(obs.tier == "raw", "raw_" + b.astype(str), obs.tier)

    fit = _solve(obs, "tier2")
    cards, tiers = fit["cards"], fit["tiers"]

    per_card = (obs.groupby("card_id")
                   .agg(n_obs=("price", "size"),
                        n_raw=("tier", lambda s: (s == "raw").sum()),
                        n_graded=("tier", lambda s: _is_graded(s).sum()),
                        median_age=("age_days", "median")).reset_index())
    graded_adj = pd.Series(fit["graded_adj"], index=fit["adj_cards"])
    tv = pd.DataFrame({
        "card_id": cards, "true_log_value": fit["V"], "true_value_se": fit["V_se"],
    })
    tv["graded_adj_log"] = tv.card_id.map(graded_adj).fillna(0.0)
    tv["value_tier"] = tv.card_id.map(bucket).astype(str)
    tv["true_value_usd"] = np.exp(tv.true_log_value)
    tv["lo_usd"] = np.exp(tv.true_log_value - tv.true_value_se)
    tv["hi_usd"] = np.exp(tv.true_log_value + tv.true_value_se)
    tv = tv.merge(per_card, on="card_id")

    ladder = pd.DataFrame({
        "tier": [ref] + tiers,
        "premium_log": np.concatenate([[0.0], fit["premium"]]),
    })
    ladder["multiplier_vs_market"] = np.exp(ladder.premium_log)
    ladder = ladder.merge(obs.tier2.value_counts().rename("n_listings"),
                          left_on="tier", right_index=True).sort_values(
                              "multiplier_vs_market", ascending=False)
    lam, sigma2, n, p = fit["lam"], fit["sigma2"], fit["n"], fit["p"]
    adj_cards = fit["adj_cards"]

    tv.to_parquet(HERE / "true_value.parquet")
    ladder.to_csv(HERE / "premium_ladder.csv", index=False)
    ladder.to_parquet(HERE / "premium_ladder.parquet")
    print(f"\ngraded-premium partial pooling: lambda {lam:.1f}, "
          f"{len(adj_cards)} cards with own adjustment; "
          f"card graded-premium SD {graded_adj.std():.2f} log "
          f"(range {np.exp(graded_adj.min()):.2f}x-{np.exp(graded_adj.max()):.2f}x vs ladder)")
    raw_inf = ladder[ladder.tier.str.startswith("raw_")].set_index("tier").multiplier_vs_market
    print("raw-ask inflation by value tier: "
          + ", ".join(f"{t.replace('raw_','')} {raw_inf[t]:.2f}x"
                      for t in ("raw_lo", "raw_mid", "raw_hi") if t in raw_inf.index))
    print(f"fit: {n} obs, {p} params, resid sigma {np.sqrt(sigma2):.3f}")
    return tv, ladder


if __name__ == "__main__":
    obs = build_observations()
    tv, ladder = fit_reconciliation(obs)
    print("\n=== pooled premium ladder (multiplier vs realized market) ===")
    print(ladder.round(2).to_string(index=False))
    print("\n=== widest-uncertainty cards (thin/noisy evidence) ===")
    print(tv.nlargest(5, "true_value_se")[
        ["card_id", "true_value_usd", "lo_usd", "hi_usd", "n_obs", "n_raw"]
    ].round(0).to_string(index=False))
