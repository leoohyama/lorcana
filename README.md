<table>
  <tr>
    <td align="center" valign="middle">
      <img width="250" alt="Lorecaster Logo" src="https://github.com/user-attachments/assets/758700b9-df52-47de-9c61-a168fadc9467" />
    </td>
    <td valign="middle">
      <h1>Lorecaster:<br>Lorcana Market Data Analysis & Forecasting</h1>
    </td>
  </tr>
</table>




<p align="center">
  <img src="https://img.shields.io/badge/R-276DC3?style=for-the-badge&logo=r&logoColor=white" alt="R" />
  <img src="https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python" />
  <img src="https://img.shields.io/badge/PyTorch-EE4C2C?style=for-the-badge&logo=pytorch&logoColor=white" alt="PyTorch" />
  <img src="https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL" />
  <img src="https://img.shields.io/badge/Quarto-4B9EAA?style=for-the-badge&logo=quarto&logoColor=white" alt="Quarto" />
  <img src="https://img.shields.io/badge/GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white" alt="GitHub Actions" />
</p>

> **Note:** This is an ongoing personal project and the README might occasionally be out of date as new features are tested. 

🚀 **UPDATE: Lorecaster is up and is also mobile friendly!**

[![Lorecaster Dashboard Preview](https://github.com/user-attachments/assets/5890e5b9-3c4a-43de-b9ef-a480722ce660)](http://lorecaster.ink)
*Click the image above to explore the live market forecasts.*


---

## Table of Contents
- [Project Overview](#project-overview)
- [Context & Market Dynamics](#context--market-dynamics)
- [Data Pipeline & Ecosystem](#data-pipeline--ecosystem)
- [Forecasting Models](#forecasting-models)
- [Training & Inference Schedule](#training--inference-schedule)
- [Project Roadmap & To-Dos](#project-roadmap--to-dos)

---

## Brief Overview
This repository houses my personal data pipeline and forecasting experiments for the Disney Lorcana TCG. I've set up a **Hybrid Local-Cloud Architecture** that combines cloud scraping with local **Large Language Model (LLM)** inference. 

Trading card games (TCGs) have incredibly speculative and volatile secondary markets. The main goal of this project is to clean up inherently messy secondary market data as much as possible before feeding it into predictive models, ultimately providing stable forecasts and market health metrics.

This project also blends both Python and R using Positron, an IDE that runs both pretty well. All of this is packaged up using quarto and JavaScript. IMPORTANT DISCLOSURE: AI has been used to help develop the JS and clean up code. However, the business logic, context, domain knowledge, modelling logic/context was all developed by me, myself, and I. 

---

## Context
Trading cards have evolved from niche collectibles into a global asset class, yet the secondary market remains largely unmapped by advanced predictive analytics. While current public platforms rely on basic moving averages, accurately forecasting card prices presents complex challenges similar to those found in traditional stock markets. This project aims to solve that problem by developing a robust predictive analytical pipeline for trading card valuations, powered by machine learning and automated MLOps.

## Lorcana

Introduced in 2023, **Disney Lorcana** is an interesting case study because it leverages Disney's massive library of intellectual property. The pricing of cards is a combination of multiple factors, and to accurately forecast prices, we have to understand the specific dynamics driving this secondary market.

<details>
<summary><strong>Click to read more about Lorcana Market Dynamics & Project Context</strong></summary>

### 1. The Collectible vs. Playable Divide (Rarity)
Different rarities delineate whether a card is viewed primarily as a collectible or as a useful game piece. While both views exist, this project assumes that cards of higher rarities play more into the collectible aspect of demand. They are harder to "pull" from a pack and feature unique artworks. Because of this, Lorecaster focuses on the higher-end card rarities: **Epic, Enchanted, and Iconic**. Combining all rarities (including common/uncommon) would make modeling much more difficult, as lower-tier card prices fluctuate wildly based on the game's current competitive meta.

### 2. Artwork & Nostalgia
Special artwork and beloved Disney characters (like Stitch, a major focus for my own collection) evoke powerful emotional connections. This creates intrinsic value and high demand among collectors that doesn't always align with a card's actual playability.

### 3. Grading 
A card's baseline value is tied to its pull rate, but the "Graded" market introduces wild price premiums. A graded card has been certified (usually on a scale of 1-10) by a third-party company (PSA, CGC, BGS) based on condition, centering, and aesthetics. 

**Note:** My models currently predict the prices of **UNGRADED** cards. Graded cards, especially higher grades (9-10), sell for much higher premiums and swing much more steeply. It is also difficult to consistently capture graded pricing data due to a lack of freely available sources.

### 4. The eBay Factor
eBay is one of the major marketplaces for high-end TCG cards, making it a treasure trove for transaction data—especially since it permits the sale of graded cards (unlike TCGPlayer). 
Listing prices on eBay can act as a strong indicator of future market prices when examined alongside listing volume history. While upper-echelon listing prices (Buy It Now / Best Offer) can be outliers, they often indicate:
1. The card is rare/new, and a market price hasn't been established.
2. The seller is misreading the market.
3. Simple listing errors.

<div align="center">
  <table>
    <tr>
      <td align="center">
        <img src="https://github.com/user-attachments/assets/ac994ded-bbc2-4e2c-90b5-9f5ac32a3a62" alt="Mickey Mouse - Steamboat Pilot" width="200" />
        <br>
        <em>Iconic: Mickey Mouse </em>
      </td>
      <td align="center">
        <img src="https://github.com/user-attachments/assets/2730aea0-cd07-43c9-9b88-7fff7d8fcfd3" alt="Stitch - Alien Dancer" width="200" />
        <br>
        <em>Enchanted: Mickey Mouse</em>
      </td>
      <td align="center">
        <img src="https://github.com/user-attachments/assets/48e6dd34-c113-48bd-b07d-8ea6ef18c733" alt="Epic Rarity Card" width="200" />
        <br>
        <em>Epic: Stitch </em>
      </td>
    </tr>
  </table>
</div>


</details>
---

## Data Pipeline & Ecosystem

```mermaid
graph LR
    %% Define Nodes
    A([eBay])
    B([JustTCG])
    C[Downloads via<br>GitHub Actions]
    D[(MotherDuck for storage)]
    E[Macbook runner via<br>GitHub Actions: runs MLOps<br>and saves ML data]
    F[Lorecaster.ink<br>Quarto Document via GitHub Actions<br>pulls data and renders<br>static HTML dashboard daily]

    %% Define Connections
    A --> C
    B --> C
    C --> D
    D <--> E
    D --> F

    %% Styling to loosely match your original blueprint
    style A fill:#0f5b78,stroke:#002b3d,stroke-width:2px,color:#fff
    style B fill:#0f5b78,stroke:#002b3d,stroke-width:2px,color:#fff
    style C fill:#166a8f,stroke:#002b3d,stroke-width:2px,color:#fff,rx:10,ry:10
    style D fill:#166a8f,stroke:#002b3d,stroke-width:2px,color:#fff
    style E fill:#166a8f,stroke:#002b3d,stroke-width:2px,color:#fff,rx:10,ry:10
    style F fill:#166a8f,stroke:#002b3d,stroke-width:2px,color:#fff,rx:10,ry:10
```

1. **Sourcing (Cloud):** GitHub Actions (Ubuntu-latest) runs a daily scrape of **eBay** and **JustTCG**, pushing the raw, unfiltered logs to a **Neon (PostgreSQL)** database.
2. **AI Cleaning (Local MacBook Runner):** After the cloud scrape finishes, a self-hosted runner wakes up on my local MacBook Air. It pulls new `item_ids`, runs them through **Gemma 4.0** via my local **Ollama** instance, and updates the `llm_listing_metadata` table.
    * **Title Validation:** Gemma performs a character-and-subtitle check to verify the listing matches the target card exactly, filtering out seller "keyword stuffing."
    * **Structured Extraction:** The model extracts structured JSON data from messy eBay listing strings to identify:
        * **Match Validity:** (Match/No Match)
        * **Grading Status:** (True/False)
        * **Grading Company:** (PSA, BGS, CGC, SGC, PCG)
        * **Grade Value:** (e.g., 10, 9.5, 9)
    * **Incremental Processing:** To save on compute time, a "Delta-only" approach cross-references new `item_ids` against existing metadata. Each listing only goes through the AI extraction process once.
3. **Preprocessing:** Data is preprocessed primarily in **R** to filter out items unsuitable for the deep learning process and to remove problematic data structures.
4. **Forecasting:** Managed via **PyTorch** (detailed in the [Forecasting Models](#forecasting-models) section below).
5. **Deployment (Quarto):** Forecasts and market metrics are presented via the Lorecaster dashboard, an html page updated daily to show the latest pricing, forecasts, and ebay data. 
---

## Forecasting Models

I'm approaching price forecasting as a multi-modal time-series problem. I am currently testing two different architectures to see what handles the volatility best:

### 1. Hybrid Gated Recurrent Unit (GRU)
I built a custom **PyTorch** model that ingests both temporal data (historical prices) and static metadata (card rarity, ink color). By concatenating static embeddings with recurrent outputs, the model better contextualizes price movements (e.g., learning that an "Enchanted" card's volatility behaves differently than a "Rare" card's).

**Why a Hybrid GRU?**
Standard time-series models treat every variable identically. Our hybrid approach separates them:
1. **Temporal Branch:** A multi-layer GRU processes sequences of normalized price data and relative days.
2. **Static Branch:** Categorical attributes are mapped into dense vector spaces using PyTorch `nn.Embedding` layers. 
3. **The Merge:** Sequence features and static embeddings are concatenated and passed through a final multi-layer perceptron (MLP) to generate the 30-day forecast.

#### The Attention Mechanism
To handle the erratic nature of the secondary market, I implemented an **Additive Attention Mechanism** over the GRU outputs. Instead of relying on a final hidden state to summarize a 30-day window, the attention layer calculates a dynamic weight for *every* day. This "Context Vector" allows the model to prioritize sudden price shocks or market shifts.

**Key Features of the Training Pipeline:**
* **Multi-Window Training:** Models are trained across different historical lookback windows (15, 30, and 45 days) to find the optimal signal-to-noise ratio, evaluated via metrics like **wMAPE** (Volume-Weighted MAPE).
* **Rolling-Origin Backtesting:** A time-traveling validation approach that simulates past market eras to stress-test the architecture against historical regime changes and set releases.
* **Custom "Horizon Trend" Loss Function:** Uses `SmoothL1Loss` (Huber Loss) as a base to handle extreme outliers, but adds a dynamic penalty for guessing the wrong market direction. It ignores daily pricing noise but heavily punishes missing the long-term macro destination.
* **Residual Forecasting:** The model predicts the *delta* (change in price) from the last known data point rather than the raw absolute value, greatly improving stability.

### 2. Pre-trained Transformer (Amazon Chronos)
I'm also experimenting with **Chronos**, a time-series forecasting framework built on language model architectures.
* **Mechanism:** Chronos tokenizes price values and uses a transformer to predict the next tokens in the sequence. 
* **Theory:** It provides solid zero-shot forecasting out of the box, which is incredibly helpful for newly released cards that lack the historical data required to train the GRU effectively.

---

## Training & Inference Schedule

To bridge the gap between academic model evaluation and real-world deployment, the GRU forecasting engine operates on a strict **Two-Script Pipeline**:

1. **The Evaluator (`model_testing_gru.py`):** Runs weekly. This acts as the "Honest Grader," performing rolling-origin backtesting across three historical eras. The most recent fold acts as an unseen holdout set, isolating real-world performance metrics and exporting them to `lorcana_global_metrics.csv` for the dashboard.
2. **The Production Brain (`train_lorcana_model.py`):** Runs weekly after evaluation. A lean script that trains the model on **100% of the historical dataset** for a fixed "sweet spot" of epochs. This creates the smartest possible `.pth` weights file without locking the most recent 30 days of market momentum behind a test-set wall. 
3. **Daily Inference (`daily_inference_gru.py`):** Runs daily. It loads the production weights, generates the 30-day future forecast, and pushes predictions to the Neon PostgreSQL database.

### Monitoring & Health
* **Model Divergence:** Tracking how wildly the Hybrid GRU and Chronos predictions differ from one another.
* **Data Integrity:** Monitoring the "Match" rate coming out of Gemma. A sudden drop usually means eBay listing patterns or seller jargon have changed, requiring prompt adjustments.
* **Outlier Detection:** Flagging cards where price predictions diverge significantly from the actual market, usually highlighting a data flaw or an unpredictable market buyout.
---

## Project Roadmap & To-Dos
- [ ] **Blue Chip Index:** Develop a weighted index (e.g., tracking the Top 50 Enchanteds) to get a quick pulse on the overall health of the Lorcana market.
- [ ] **Modularize index.qmd
- [ ] **Diffusion Transformers & Sentiment:** Begin experimenting with diffusion transformer models and using LLMs to capture textual market sentiment.
- [ ] **rework landing page to include more interesting statistics
- [ ] **Possibly develop a "buy" vs "sell" decision maker leveraging models and data

## Project changelog (significant change logs)
- I have switched databases from neonDB to motherduck, realized that my use didn't require some of their features (June-12-2026)
- I have removed the digitial ocean/docker approach as I realized that an html page could better support web traffic but also show daily data and market changes
- The shiny app code is still available in the repo but is not being actively used and is out-of-date
