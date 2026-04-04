# Lorcana Market Data Analysis & Forecasting

### 🎯 Project Roadmap & To-Dos
1.  **LLM Fine-Tuning:** Explore LoRA (Low-Rank Adaptation) to train the **Gemma 4.0 2B** model on "edge-case" Lorcana titles (e.g., misspellings or rare promotional jargon).
2.  **Attention Mechanisms:** Utilize attention layers in the GRU architecture to capture key market events and weigh them more heavily in forecasts.
3.  **Confidence Intervals:** Integrate model confidence percentages for individual price forecasts to show prediction reliability.
4.  **Blue Chip Index:** Develop a weighted index (e.g., Top 50 Enchanteds) to assess overall Lorcana market health.
5.  **UI Enhancements:** Add a "Last Trained" timestamp to the dashboard and implement a "Filter by Grade" (PSA, CGC, etc.) feature.

---

### Project Overview
This repository contains a professional-grade data pipeline and forecasting engine for the Disney Lorcana TCG. It utilizes a **Hybrid Local-Cloud Architecture** that combines high-frequency cloud scraping with local **Large Language Model (LLM)** inference to ensure institutional-grade data cleanliness.

### 🤖 AI Data Cleaning (Gemma 4.0)
To solve the "noise" problem inherent in eBay TCG data (proxies, digital codes, and "repack" scams), this project utilizes **Gemma 4.0 (2B Effective)** running locally via **Ollama** on a self-hosted Apple Silicon runner. 

* **Title Validation:** Gemma performs a character-and-subtitle check to ensure the listing matches the target card exactly, ignoring seller "keyword stuffing."
* **Structured Extraction:** The model extracts structured JSON data from raw strings, identifying:
    * **Match Validity:** (Match/No Match)
    * **Grading Status:** (True/False)
    * **Grading Company:** (PSA, BGS, CGC, SGC, PCG)
    * **Grade Value:** (e.g., 10, 9.5, 9)
* **Incremental Processing:** The pipeline uses a "Delta-only" approach, cross-referencing `item_ids` against a metadata table to ensure each listing is only analyzed by the AI once.

### 🏗️ System Architecture Workflow

<p align="center">
  <img src="https://github.com/user-attachments/assets/13e49a31-7878-49d9-a841-d6633839729e" alt="Lorcana Workflow Diagram" style="max-width: 100%; height: auto;" />
</p>

1.  **Sourcing (Cloud):** GitHub Actions (Ubuntu-latest) retrieves daily data from **eBay** and **JustTCG** and pushes raw logs to **Neon (Postgres)**.
2.  **AI Cleaning (Local MacBook Runner):** Upon completion of the scrape, a self-hosted runner wakes up on a local MacBook Air. It pulls new `item_ids`, runs **Gemma 4.0** via **Ollama**, and populates the `llm_listing_metadata` table.
3.  **Deployment (Shiny App):** The dashboard performs a relational join between price logs and AI-verified metadata, allowing for real-time filtering of "dirty" or mismatched data.

---

# Context & Market Dynamics

Trading card games (TCGs) like Pokémon, Yu-Gi-Oh!, and Magic: The Gathering provide entertainment for both players and collectors. Introduced in 2023, **Disney Lorcana** leverages Disney's vast library of intellectual property. 

The secondary market for these cards is both volatile and speculative. Key factors driving this market:

### 1. Rarity & Grading
Lorcana utilizes several rarity classifications, including: "Common", "Uncommon", "Rare", "Super Rare", "Legendary", "Epic", "Enchanted", and "Iconic". Beyond raw rarity, the "Graded" market (PSA, CGC, BGS) creates significant price premiums for high-quality "slabs."

### 2. Artwork & Nostalgia
Special artwork and beloved Disney characters evoke powerful emotional connections, creating significant intrinsic value and high demand among collectors.

---

# Forecasting Models

We approach price forecasting as a multi-modal time-series problem. We currently evaluate two distinct architectures:

### 1. Hybrid Gated Recurrent Unit (GRU)
A custom **PyTorch** model designed to utilize more than just temporal sequences.
* **Mechanism:** Ingests both temporal data (historical prices) and static metadata (rarity, ink color).
* **Advantage:** By concatenating static embeddings with recurrent outputs, the model better contextualizes movements (e.g., how "Enchanted" volatility differs from "Rare" cards).

### 2. Pre-trained Transformer (Amazon Chronos)
We leverage **Chronos**, a time-series forecasting framework based on language model architectures.
* **Mechanism:** Chronos tokenizes price values and uses a transformer to predict the next tokens. 
* **Advantage:** Provides strong zero-shot forecasting capabilities, essential for cards with limited historical data.

---

# Training & Inference Schedule

* **Weekly Training:** The **GRU model** is retrained on the full historical dataset every week. Performance is validated against a hold-out test set using **Absolute Percentage Error** metrics.
* **Daily Inference:**
    * **Gemma 4.0:** Processes new eBay listings immediately following the daily scrape.
    * **Chronos/GRU:** Generates the latest 30-day forecasts based on the previous day's closing prices.

---

### Monitoring & Health
Current monitoring focuses on:
* **Model Divergence:** Tracking the performance of the Hybrid GRU vs. Chronos.
* **Data Integrity:** Monitoring the "Match" rate from Gemma to identify changes in eBay listing patterns or seller jargon.
* **Outlier Detection:** Identifying cards where price predictions diverge significantly from actual market behavior.
