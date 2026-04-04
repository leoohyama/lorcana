# Lorcana Market Data Analysis & Forecasting

Things to do:

1. Utilize attention layer in gru to capture key events and weigh them more
2. Work on structure to set up model confidence percentages for individual forecasts etc.
3. Add a label showing when the model was last trained. 
4. create a blue chip index to assess market health
5. Keep fixing app aesthetics

This repository contains scripts and workflows designed to analyze market data for the Disney Lorcana Trading Card Game (TCG) using a hybrid local-cloud architecture and deep learning forecasting models.

### Project Objectives

1.  **Data Collection & Visualization:** Collect market data from eBay and JustTCG, clean and summarize it, and present it through an interactive **Shiny app**. The app aims to provide users with up-to-date information regarding the pricing, liquidity, and market momentum of their cards.
2.  **Price Forecasting:** Develop price forecasting models via **PyTorch** to provide accurate price predictions for various cards. These forecasts will ultimately be integrated into the Shiny app.

### System Architecture Workflow

<p align="center">
  <img src="https://github.com/user-attachments/assets/13e49a31-7878-49d9-a841-d6633839729e" alt="Lorcana Workflow Diagram" style="max-width: 100%; height: auto;" />
</p>

---

# Context & Market Dynamics

Trading card games (TCGs) like Pokémon, Yu-Gi-Oh!, and Magic: The Gathering provide entertainment for both players and collectors. Introduced in 2023, **Disney Lorcana** leverages Disney's vast library of intellectual property. 

The secondary market for these cards is both volatile and speculative. Several key factors drive this market:

### 1. Rarity
The rarity of a card is determined by its pull rate. Lorcana utilizes several rarity classifications, including: "Common", "Uncommon", "Rare", "Super Rare", "Legendary", "Epic", "Enchanted", and "Iconic".

<p align="center">
  <img src="https://github.com/user-attachments/assets/75a184fa-0ac4-4f5a-aeb0-7a4f7dd58c29" alt="Mickey Mouse Brave Little Tailor Card (Iconic Rarity)" width="269" height="375" />
  <br>
  <em>Example: Mickey Mouse - Brave Little Tailor (Iconic Rarity)</em>
</p>

### 2. Artwork & Nostalgia
Special artwork and beloved Disney characters evoke powerful emotional connections, creating significant intrinsic value and high demand among collectors.

---

# Data Pipeline & Architecture

The ingestion, storage, and modeling architecture operates on a hybrid local-cloud setup. A dedicated local server handles high-frequency data extraction and feature engineering, while cloud infrastructure supports the public-facing dashboard.

### The Pipeline Flow:
1.  **Sourcing (Local Runner):** A dedicated MacBook server acts as a local runner, retrieving data daily from **eBay** and **JustTCG**.
2.  **Processing & Local Storage:** The data is cleaned, filtered for outliers, and stored in a persistent local database (e.g., PostgreSQL/DuckDB). This creates a rich historical ledger crucial for training machine learning models.
3.  **Cloud Storage Sync:** Processed, analysis-ready data is uploaded to a cloud **PostgreSQL database (Neon)**.
4.  **Deployment:** A **Shiny app**, deployed via Posit Connect Cloud, accesses the Neon database to summarize and visualize the market data.

## Data Sources
* **eBay:** Listings are downloaded daily using the developer API and filtered to minimize outliers.
* **JustTCG:** This API provides daily updates on average card pricing, used to cross-reference and stabilize raw eBay data.

## Automation
Pipeline tasks are automated using local cron scheduling for ingestion and model training, and **GitHub Actions** for CI/CD and cloud synchronization.

---

# Forecasting Models

We approach price forecasting as a time-series problem influenced by both historical price momentum and static card attributes. We currently evaluate two distinct forecasting architectures:

### 1. Hybrid Gated Recurrent Unit (GRU)
A custom PyTorch model designed to utilize more than just temporal sequences.
* **Mechanism:** Ingests both temporal data (historical price sequences) and static metadata (rarity, character, and ink color).
* **Advantage:** By concatenating static embeddings with recurrent outputs, the model better contextualizes movements (e.g., how "Enchanted" volatility differs from "Rare" cards).

### 2. Pre-trained Transformer (Amazon Chronos)
We leverage **Chronos**, a time-series forecasting framework based on language model architectures.
* **Mechanism:** Chronos tokenizes price values and uses a transformer to predict the next tokens. We feed the model all available historical price data for a given card.
* **Advantage:** Provides strong zero-shot forecasting capabilities, which is essential for newer cards with limited local historical data.

---

# Training & Inference Schedule

### Weekly Training
The **GRU model** is trained on a growing dataset every week. Simultaneously, we run a weekly iteration of **Chronos** on the same dataset that the GRU training is fitted on.

### Daily Inference
* **GRU:** Forecasts are updated daily using the model weights established during the weekly training session.
* **Chronos:** We use zero-shot forecasting on a daily schedule to generate the newest 30-day forecasts.

---

# Assessment of Forecast and Model Health

### Weekly Training Validation
During every weekly training session, we test the models against a hold-out test set. We collect performance metrics, specifically **Absolute Percentage Error**, to maintain a running assessment of model accuracy.

### Monitoring
This allows for a continuous evaluation of how the models are performing over time. Current monitoring focuses on:
* **Model Accuracy:** Tracking the performance of the Hybrid GRU vs. Chronos.
* **Individual Card Forecasts:** Identifying specific cards where price predictions are diverging significantly from actual market behavior.
