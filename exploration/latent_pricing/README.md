# Latent pricing PoC — architecture review & implementation notes

Goal: compress card "DNA" (intrinsic attributes + card image) into a latent
space, price cards off their latent position, and read mispricing as the
residual `log(market) − fair(z)`.

## Architecture review of the proposed fusion autoencoder

### 1. Sample size is the catastrophic bottleneck, not gradients (N = 284)

The Enchanted universe is 284 cards. A 64–128D bottleneck is not a compression
of 284 points — a single `Linear(512, 64)` layer already has ~100× more
parameters than we have cards. A trainable fusion AE at that scale memorizes:
reconstruction loss goes to zero, the latent becomes an arbitrary lookup table,
and distances in it are meaningless. Consequences:

- If we train anything, the bottleneck should be **8–16D**, with heavy weight
  decay, modality dropout, and early stopping. 64D is defensible only as the
  *frozen-embedding* width, not a trained one.
- The honest scale-up path: train on **all Lorcana printings** (thousands of
  cards across rarities), then embed the 284 Enchanteds into that space. The
  AE framework in `fusion_autoencoder.py` is written for that regime.

### 2. Leakage: market metrics must not enter the encoder

If the tabular branch sees market metrics (price, comps, momentum, spread),
then "expected price given latent" ≈ actual price and the residual collapses
toward zero wherever data is clean. You end up ranking cards by *data noise*,
not mispricing. Rules:

- **Encoder inputs = intrinsic DNA only**: ink, cost, strength/willpower, lore,
  set, character, franchise, artist, keywords, plus the image.
- Market-side quantities live on the **outcome side** (the thing being
  predicted) or as dashboard overlays — never inside `z`.
- Residuals must be **out-of-fold** (LOO or repeated K-fold at N=284). An
  in-sample residual from any flexible model is ≈0 by construction.

### 3. Gradient / scale domination (the question asked)

With a frozen vision branch and a trainable tabular branch there are two
distinct failure modes:

- **Dimensional swamping**: 2048 ResNet dims vs ~30 tabular dims at concat.
  Fix: project each branch to the **same width** with its own head, then
  `LayerNorm` (or L2-normalize) each branch output *before* fusion so both
  arrive with comparable norms.
- **Optimization shortcut**: the trainable tabular path can adapt to the loss;
  the frozen visual path cannot. The decoder learns to lean entirely on
  tabular and vision becomes dead weight. Fix: **modality dropout** (randomly
  zero one branch during training, p≈0.15 each) plus reconstruction targets
  for *both* modalities — reconstruct the vision **embedding**, never pixels.

Normalization checklist: standardize continuous features to z-scores *fitted
on train folds only*; embeddings for categoricals (dim ≈ `min(50, (n+1)//2)`);
LayerNorm after each branch projection; GELU + dropout in the fusion MLP.

### 4. Reconstruction is a misaligned objective — the alternative pitch

An AE latent is optimized to reconstruct its inputs, and most input variance
(art style, background pixels) is price-irrelevant. Two better framings:

- **Supervised bottleneck (recommended when training)**: same two-branch
  architecture, but the head predicts `log_price`; reconstruction becomes an
  auxiliary regularizer (λ ≈ 0.1–0.3). The latent then organizes around
  *price-relevant* structure. This is a hedonic model with a learned basis.
- **Contrastive (CLIP-style) alignment** between image and attribute views is
  the strongest representation learner here in principle — but it needs
  thousands of pairs; at N=284 it cannot be trained meaningfully. Park it for
  the all-rarities dataset.

## Recommended alternative workflow (what to run first)

Zero-training pipeline — same dashboard, no overfitting risk, ~an afternoon:

1. **Precompute** frozen image embeddings once (ResNet-50 avgpool 2048D, or
   CLIP/DINOv2 if installed) → parquet keyed by card id.
2. **PCA-whiten** vision to ~32 components (so 2048 dims don't drown 30
   tabular dims), standardize tabular intrinsics, concatenate → this *is* the
   64D "bottleneck", frozen and honest.
3. **Fair value**: Ridge / Gaussian-process / LightGBM regression of
   `log_price` on that space with **LOO out-of-fold predictions**.
4. **Mispricing Δ** = `log_price − oof_fair_value`.
5. **UMAP** the same space for the dashboard (X/Y = structure, color = Δ).

This is the cross-sectional complement to the existing anchor-gap /Chronos-2
time-series signal: anchor-gap says "this card is cheap vs *its own* anchor";
the latent residual says "this card is cheap vs *its structural peers*".

## Files

- `fusion_autoencoder.py` — PyTorch framework: frozen vision branch, tabular
  branch with categorical embeddings, fusion, bottleneck, decoders, optional
  supervised price head, loss helper. (The scale-up path; not used by the
  zero-training run below.)
- `umap_projection.py` — UMAP 2D projection + diverging-residual scatter
  (blue↔red, gray at Δ=0). Importable; also runs standalone on dummy data.
- `precompute_embeddings.py` — Stage A: one-off frozen ResNet-50 pass over
  `data/enchanteds/images` → `vision_embeddings.parquet`.
- `reconcile_true_value.py` — **Block A**: reconcile eBay raw/graded asks +
  JustTCG into one true value per card (+ grade premium ladder, staleness).
  Run this first. Outputs `true_value.parquet`, `premium_ladder.csv`,
  `listing_observations.parquet`.
- `latent_pipeline.py` — **Block B**: position true value in the fused space →
  LOO fair value → structural + execution mispricing → UMAP. Outputs
  `mispricing_deltas.csv`, `execution_signals.csv`, `model_scoreboard.csv`,
  `umap_mispricing_real.png`, `umap_demand_adjusted.png`.

## Latent-measurement reconceptualization (2026-07-18)

The residual-of-one-price framing was replaced. New premise: each card has a
single unobserved **true value**; every price we see (eBay raw ask, eBay
graded ask, JustTCG) is that true value distorted by where it came from, and
every feature (art, stats, churn, volume) is a clue to where it sits. Two
blocks:

**Block A — reconcile prices → true value** (`reconcile_true_value.py`).
Weighted two-way fixed-effects fit in log space:
`log(price) = V_card + premium[tier] + noise`, with **JustTCG (realized
market) as the anchor** so `V_card` is realized true value, and each grading
`(company × grade)` tier a pooled premium that gets divided back out. Listing
age (from 115 daily snapshots) down-weights stale asks; graded obs are
down-weighted vs direct raw/JustTCG evidence. Outputs `true_value.parquet`
(value + ~68% band + listing counts) and `premium_ladder.csv`.

Premium ladder (× realized market): PSA 10 ≈ 6.7×, BGS 9.5 ≈ 5.4×,
CGC 10 ≈ 4.1×, PSA 9 ≈ 2.3×, **raw eBay ask ≈ 1.6×** (asks run ~60% over
market — the headline finding), PSA 8 ≈ 0.6× (played slab < raw NM).

**Block B — position true value in feature space** (`latent_pipeline.py`).
Fair value = LOO regression of `true_value` on the fused frozen space.
- structural (intrinsic DNA + art): OOF R² **0.47**.
- full (+ demand: popularity, price-shape stats, listing depth/turnover):
  OOF R² **0.62**.
- `delta_full` = true value − full fair value = the actionable
  cross-sectional mispricing; `premium_component` = what demand explains.

Two output signals:
- **structural** (`mispricing_deltas.csv`): market's reconciled value vs
  fundamentals. Grails (Elsa Spirit of Winter ~5× fair) sit above; value
  candidates (Robin Hood, Archimedes, Ratigan ~0.7× fair) sit below.
- **execution** (`execution_signals.csv`): cheapest *live* raw/graded ask vs
  true value — buyable dislocations, with a hard junk floor (drops asks >70%
  below tier fair, which are proxies/lots/damaged listings).

### Leakage caught during the build
`card_ts_metrics.days_in_30d` (a volume field) correlates **0.96** with the
true-value target and near-duplicates its distribution — including it faked an
OOF R² of 0.89 while hollowing out the mispricing signal. Dropped. The rule:
nothing co-measured with price (volume channels, price near-copies) goes in
the feature block; counts/dispersions/publisher data are fine.

### v2 grading premium (done)
Block A now **partially pools** the grading premium: each card gets its own
deviation from the pooled tier ladder, L2-shrunk toward it by how much graded
data the card has (231 cards earn their own premium; SD 0.37 log, i.e. slab
premiums range ~0.3×–3× around the ladder). This fixes the v1 bias — e.g.
Elsa Ice Artisan's slabs command only ~0.5× the ladder, so its graded
listings no longer drag true value down. Also tightened junk removal: eBay
listings outside a 2.5× band of their tier median are dropped (a $6 ask on a
$128 card was pulling the geometric-mean fit down); ~680 junk listings
removed, and per-card true values now track the JustTCG/raw blend sensibly.

### Visualizations
- `true_vs_naive.png` (`viz_true_vs_naive.py`) — reconciled true value vs the
  eBay raw-ask median (runs **1.66× high**, all points below the diagonal)
  and vs JustTCG (**1.04×**, tracks true value with per-card disagreement).
- `latent_dashboard.html` (`build_dashboard.py`) — self-contained interactive
  explorer: latent-space scatter (hover a card → true value vs JustTCG/eBay
  bars + mispricing), a true-vs-naive view toggle, and under/over-priced
  leaderboards. Rebuild after any pipeline rerun.

### Value-tier ask inflation (done)
Raw-ask inflation now varies by value tercile (pass 1 estimates each card's
value, pass 2 splits the raw premium lo/mid/hi). Finding, contrary to the
guess that expensive cards are listed closer to market: **high-value raw asks
are the MOST inflated** (raw_hi 1.76× vs raw_mid 1.52× vs raw_lo 1.62×) —
aspirational grail listings sit furthest above realized value. So this did not
pull grails up to TCGplayer; instead it showed the grail gap is mostly a
genuine eBay-realizes-lower-than-TCGplayer venue disagreement (true/JustTCG
median 0.97 overall, 0.90 for high-tier), not a modeling artifact. Elsa Spirit
of Winter (0.65×) is a real per-card divergence. A censored (upper-bound)
treatment of asks is the remaining lever if TCGplayer is judged the truer
venue — left as a described option, not built.

### Character-fame premium (done)
Being e.g. a Mickey or Elsa card commands a premium beyond attributes and
printing-count popularity. Added as a **leave-one-out, shrunk character effect**
on the full-model residual (each card sees only OTHER same-character cards, so
leakage-safe; 121 singletons shrink to 0, 30 repeat characters earn a premium).
It **lifts OOF R² 0.688 → 0.712**, confirming character identity generalizes.
Top premiums: **Elsa +71%, Ariel +35%, Jasmine +28%, Snow White +27%,
Mickey +15%** (`character_premiums.csv`). `delta_char` (true value vs
fair-value-including-fame) is now the actionable mispricing column.

### Temporal frame (audit)
Everything is a **snapshot as of the latest daily pull (2026-07-18)** — this is
a *current* mispricing tool, not a time series:
- True value pools eBay listings over a **trailing 14-day window** (each
  item's most recent price; recency handled by the age-decay weight). Chosen
  because 14-day price drift is negligible (median 30-day CV ~5%) while
  pooling lifts thin cards from ~18 to ~26 listings at the 25th percentile.
- JustTCG = latest daily market price. `cv_30d`, `hurst_30d` = 30-day trailing
  price-shape stats. Listing age = full 115-snapshot history (Mar–Jul).
- Limitation: the target is still a point-in-time value, so it carries daily
  noise for thin cards; it is not smoothed across weeks and does not model
  price trend (that is the Chronos-2 time-series signal's job — this is the
  cross-sectional complement).

### Prevalence / scarcity (investigated, not added)
- **Listing share** of the total pool is **0.999 collinear** with
  `log_n_listings` (the total is a per-snapshot constant), so it carries no
  new information on its own.
- Raw listing count correlates **+0.26** with price — it's a *popularity*
  proxy (popular cards have both more listings and higher prices), the wrong
  sign for scarcity. A **supply-per-print** ratio
  (`log_n_listings − log_n_printings`) flips to the right sign (**−0.18**:
  scarcer float → premium), but it's a linear combination of two features
  already in the model, so Ridge forms it implicitly — adding it explicitly
  gave **zero OOF lift**. Scarcity is real and already captured; left out to
  keep the model lean.

### Remaining limitation / next step
Censored (upper-bound) ask treatment; pulling excluded non-Enchanted printings
into the character-premium estimate (Elsa has only 2 cards here, so +69% is
shrunk from thin data); optional gtrendsR search-interest as an external
fan-demand check (not installed on this machine).

## Earlier structural-only run (superseded)

- Universe: **193 cards** (187 Enchanted + 6 Iconic; Epics excluded as a
  different market tier) = scans in `data/enchanteds/images` ∩
  `ready_for_pytorch.parquet` intrinsics ∩ fresh MotherDuck
  `justtcg_prices`. Target = log of same-day market price.
- Two fair-value models over the fused space (32 PCA-whitened ResNet-50
  comps + standardized intrinsic tabular block; `character_id` dropped —
  the art embedding carries identity; set enters only via
  `days_since_launch`):
  - **structural** (intrinsic DNA only): GP-RBF, OOF R² **0.495**.
  - **demand-adjusted** (+ per-character printing / premium-treatment
    counts from the full 2,594-card pool as popularity proxies): Ridge,
    OOF R² **0.565**. Character popularity is worth ~7 pts of OOF R².
- `premium_component = delta_structural − delta_adjusted` isolates the
  priced-in popularity per card. Sanity check passed: the top five premiums
  are all Mickey Mouse printings (+0.5–0.6 log ≈ +65–85% of price).
- **Interpretation**: `delta_adjusted` is the actionable column (mispricing
  net of character popularity); `delta_structural` still includes the full
  collector premium. Grails (Elsa Spirit of Winter +8× fair) remain
  "overpriced" under both — treat those as premium measurements, not sell
  signals; the tradeable tail is the underpriced side.
- Possible next demand feature: gtrendsR search interest per character
  (anchor-chained batches of 5, category-filtered to avoid brand-level
  Mickey dominance; bare "Lorcana <character>" queries mostly return 0 —
  below Trends' volume floor). Pull once, static feature.
- Refresh cadence: rerun `latent_pipeline.py` any day — it pulls same-day
  prices from MotherDuck itself (cached parquet as offline fallback); rerun
  `precompute_embeddings.py` only when new card scans land.

## DataLoader checklist (images + tabular without GPU-memory pain)

The single biggest win: **the vision branch is frozen, so run it exactly once.**

1. **Two-stage loading.** Stage A (one-off): a plain `Dataset` yielding
   `(id, image_tensor)`, batch through the frozen backbone under
   `torch.no_grad()`, save `{id: 2048-dim tensor}` to one `.pt` / parquet
   file. Stage B (every epoch): a `Dataset` that returns
   `(vision_emb, cat_idx_tensor, cont_tensor, log_price)` — pure tensor
   indexing, no image decode, no backbone on the GPU at train time.
2. **If you must load raw images live** (e.g. fine-tuning later):
   - Decode-and-resize to 224 *inside* `__getitem__` (never keep full-res
     scans in memory); `.avif` needs `import pillow_avif` in each worker.
   - `num_workers=2–4`, `persistent_workers=True`; `pin_memory=True` only on
     CUDA (it is a no-op burning host RAM on MPS).
   - Keep the backbone in `eval()` and wrap its forward in `torch.no_grad()`
     so no activation graph is stored — that, not the images, is what
     usually blows up GPU memory with a frozen extractor.
3. **Return heterogeneous fields as a dict** from `__getitem__`; the default
   collate stacks each key — no custom `collate_fn` needed.
4. At N=284 the whole tabular side fits in one tensor: after Stage A, a
   full-batch `TensorDataset` is simpler and faster than any streaming.
