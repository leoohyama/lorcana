# Lorcana Market Data Analysis & Forecasting

This repository contains scripts and workflows designed to analyze market data for the Disney Lorcana Trading Card Game (TCG).

### Project Objectives

1.  **Data Collection & Visualization:** Collect market data from eBay and JustTCG, clean and summarize it, and present it through an interactive **Shiny app**. The app aims to provide users with up-to-date information regarding the pricing, liquidity, and market momentum of their cards.
2.  **Price Forecasting:** Develop price forecasting models via **PyTorch** to provide accurate price predictions for various cards. These forecasts will ultimately be integrated into the Shiny app.

### System Architecture Workflow

<p align="center">
  <img src="https://github.com/user-attachments/assets/13e49a31-7878-49d9-a841-d6633839729e" alt="Lorcana Workflow Diagram" style="max-width: 100%; height: auto;" />
</p>

---

# Context & Market Dynamics

Trading card games (TCGs) like Pokémon, Yu-Gi-Oh!, and Magic: The Gathering provide entertainment for both players and collectors. Introduced in 2023, **Disney Lorcana** leverages Disney's vast library of intellectual property. Due to the wide appeal of Disney characters across movies and television, Lorcana cards have been quickly adopted by collectors.

The secondary market for these cards is both volatile and speculative. Several key factors drive this market:

### 1. Rarity
The rarity of a card is determined by its pull rate (how often it appears when opening booster packs). For example, some cards are found in only 1 out of 96 packs. With packs costing between $4–$8 USD, the cost of finding specific rare cards can be high.

Lorcana utilizes several rarity classifications, including: "Common", "Uncommon", "Rare", "Super Rare", "Legendary", "Epic", "Enchanted", and "Iconic".

<p align="center">
  <img src="https://github.com/user-attachments/assets/75a184fa-0ac4-4f5a-aeb0-7a4f7dd58c29" alt="Mickey Mouse Brave Little Tailor Card (Iconic Rarity)" width="269" height="375" />
  <br>
  <em>Example: Mickey Mouse - Brave Little Tailor (Iconic Rarity)</em>
</p>

### 2. Artwork
Certain cards feature special or alternative artwork, often tied to their rarity. This makes them highly exclusive and provides a strong incentive for collectors.

### 3. Nostalgia
Disney characters are globally recognized, evoking powerful emotional connections. Cards representing these beloved characters possess significant intrinsic value to collectors who grew up watching them.

---

# Data Pipeline & Architecture

The ingestion, storage, and modeling architecture operates on a hybrid local-cloud setup. A dedicated local server handles high-frequency data extraction and feature engineering, while cloud infrastructure supports the public-facing dashboard.

### The Pipeline Flow:
1.  **Sourcing (Local Runner):** A dedicated MacBook server acts as a local runner, retrieving data daily from **eBay** and **JustTCG**.
2.  **Processing & Local Storage:** The data is cleaned, filtered for outliers, and stored in a persistent local database (e.g., PostgreSQL/DuckDB). This creates a rich historical ledger crucial for training machine learning models.
3.  **Cloud Storage Sync:** Processed, analysis-ready data is uploaded to a cloud **PostgreSQL database (Neon)**.
4.  **Deployment:** A **Shiny app**, deployed via Posit Connect Cloud, accesses the Neon database to summarize and visualize the market data.

## Data Sources

* **eBay:** Listings are downloaded using the developer API. The data is cleaned and filtered to minimize outliers (e.g., extremely high "Buy It Now" or "Best Offer" prices) and ensure listings represent specified cards accurately.
* **JustTCG:** This API provides daily updates on average card pricing. These averages are used to cross-reference and stabilize the raw eBay listing data.

## Automation

Pipeline tasks are automated using a combination of local cron scheduling (for database ingestion and model training on the local runner) and **GitHub Actions** (for CI/CD and cloud synchronization).

---

# Forecasting Models

Because the Lorcana market is relatively new and subject to rapid hype cycles, this project approaches price forecasting as a time-series problem influenced by both historical price momentum and static card attributes. 

We currently evaluate and deploy two distinct forecasting architectures to predict 30-day price trajectories:

### 1. Hybrid Gated Recurrent Unit (GRU)
To establish a custom baseline for the relatively smaller TCG dataset, we developed a Hybrid GRU model using PyTorch. 
* **Mechanism:** Unlike standard RNNs, this model ingests both temporal data (the historical sequence of market prices) and static metadata (card attributes such as rarity, character, and ink color). 
* **Advantage:** By concatenating static embeddings with the recurrent outputs, the model can better contextualize price movements. For example, it learns that a sharp price increase for an "Enchanted" card behaves differently than a similar percentage increase for a "Rare" card.

### 2. Pre-trained Transformer Model (Amazon Chronos)
To leverage the power of foundational models, we implemented **Chronos**, a time-series forecasting framework based on language model architectures.
* **Mechanism:** Chronos tokenizes time-series values into discrete buckets and trains a transformer model to predict the next tokens. We feed the model all available historical price data for a given card.
* **Advantage:** Because Chronos is pre-trained on a massive corpus of open-domain time-series data, it provides strong zero-shot forecasting capabilities, helping to generate robust 30-day forecasts even for newer cards with limited historical data.
