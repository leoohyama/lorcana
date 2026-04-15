# Lorecaster: Lorcana Market Data Analysis & Forecasting

<p align="center">
  <img src="https://img.shields.io/badge/R-276DC3?style=for-the-badge&logo=r&logoColor=white" alt="R" />
  <img src="https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python" />
  <img src="https://img.shields.io/badge/PyTorch-EE4C2C?style=for-the-badge&logo=pytorch&logoColor=white" alt="PyTorch" />
  <img src="https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white" alt="PostgreSQL" />
  <img src="https://img.shields.io/badge/Docker-2CA5E0?style=for-the-badge&logo=docker&logoColor=white" alt="Docker" />
  <img src="https://img.shields.io/badge/DigitalOcean-0080FF?style=for-the-badge&logo=digitalocean&logoColor=white" alt="DigitalOcean" />
  <img src="https://img.shields.io/badge/GitHub_Actions-2088FF?style=for-the-badge&logo=github-actions&logoColor=white" alt="GitHub Actions" />
</p>

**Please note** this is an ongoing project and the readme (for my own sanity) might be out of date. 

🚀 **UPDATE: Lorecaster is now live!**

[![Lorecaster Dashboard Preview](https://github.com/user-attachments/assets/103c05f6-bb5b-4c34-bd9d-0930aa1932dc)](http://lorecaster.ink)
*Click the image above to explore the live market forecasts.*

## Table of Contents
- [Project Overview](#project-overview)
- [Project Roadmap & To-Dos](#-my-project-roadmap--to-dos)
- [Data Pipeline & Ecosystem](#️-data-pipeline--ecosystem)
- [Context & Market Dynamics](#context--market-dynamics)
  - [1. Rarity & Grading](#1-rarity--grading)
  - [2. Artwork & Nostalgia](#2-artwork--nostalgia)
- [Forecasting Models](#forecasting-models)
  - [1. Hybrid Gated Recurrent Unit (GRU)](#1-hybrid-gated-recurrent-unit-gru)
  - [2. Pre-trained Transformer (Amazon Chronos)](#2-pre-trained-transformer-amazon-chronos)
- [My Training & Inference Schedule](#my-training--inference-schedule)
  - [Monitoring & Health](#monitoring--health)


### Project Overview
This repository houses my personal data pipeline and forecasting experiments for the Disney Lorcana TCG. I've set up a **Hybrid Local-Cloud Architecture** that combines some cloud scraping with local **Large Language Model (LLM)** inference. My main goal here is to try and clean up the inherently messy secondary market data as much as possible before feeding it into any predictive models.

---

### 🎯 My Project Roadmap & To-Dos
1.  **fix system graph** update to show shinyapp hosted of digital ocean
4.  **Blue Chip Index:** I'm working on developing a weighted index (e.g., tracking the Top 50 Enchanteds) to get a quick pulse on the overall health of the Lorcana market.
5.  figure out ebay data and how it can be used!!!


---

### 🏗️ Data Pipeline & Ecosystem


<p align="center">
  <img src="https://github.com/user-attachments/assets/13e49a31-7878-49d9-a841-d6633839729e" alt="Lorcana Workflow Diagram" style="max-width: 100%; height: auto;" />
</p>

1.  **Sourcing (Cloud):** I use GitHub Actions (Ubuntu-latest) to run a daily scrape of **eBay** and **JustTCG**, pushing the raw, unfiltered logs to my **Neon (Postgres)** database.
2.  **AI Cleaning (Local MacBook Runner):** Once the cloud scrape finishes, a self-hosted runner wakes up on my local MacBook Air. It pulls down any new `item_ids`, runs them through **Gemma 4.0** via my local **Ollama** instance, and updates the `llm_listing_metadata` table.
* **Title Validation:** I have Gemma performing a character-and-subtitle check to try and verify that the listing matches the target card exactly, helping me filter out seller "keyword stuffing."
* **Structured Extraction:** I'm prompting the model to extract structured JSON data from the raw, messy eBay listing strings to identify:
    * **Match Validity:** (Match/No Match)
    * **Grading Status:** (True/False)
    * **Grading Company:** (PSA, BGS, CGC, SGC, PCG)
    * **Grade Value:** (e.g., 10, 9.5, 9)
* **Incremental Processing:** To save on compute time, the pipeline uses a "Delta-only" approach. It cross-references new `item_ids` against my existing metadata table so that each listing only goes through the AI extraction process once.
3.  **Preprocessing** Data is preprocessed using primarily R in order to filter out items that can't be used in the deep learning process and to remove any problematic data structures.
4.  **Forecasting** Done using Pytorch with more info found [here](#forecasting-models) regarding training schedule and inference.
5.  **Deployment (Shiny App):** The forecast and general market metrics are all presented via a shinyapp dashboard (Lorecaster). This dashboard is hosted on a Digital Ocean Droplet which is done through containerizing the shinyapp via docker in a different repository. 


---

# Context & Market Dynamics

Trading card games (TCGs) have incredibly speculative and volatile secondary markets. Introduced in 2023, **Disney Lorcana** is an interesting case study because it leverages Disney's massive library of intellectual property. 

From what I've observed tracking this data, a few key factors drive the market:

### 1. Rarity & Grading
A card's baseline value is tied to its pull rate. Lorcana has several rarity classifications ("Common", "Uncommon", "Rare", "Super Rare", "Legendary", "Epic", "Enchanted", and "Iconic"). Beyond raw rarity, the "Graded" market (PSA, CGC, BGS) introduces wild price premiums for high-quality "slabs" that are hard to consistently track.

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


### 2. Artwork & Nostalgia
Special artwork and beloved Disney characters—like Stitch, which is a major focus for my own collection—evoke powerful emotional connections. This creates a sort of intrinsic value and high demand among collectors that doesn't always align with a card's actual playability in the game.

---

# Forecasting Models

I'm approaching the price forecasting aspect as a multi-modal time-series problem. Right now, I'm testing out two very different architectures to see what handles the volatility best:

### 1. Hybrid Gated Recurrent Unit (GRU)
I built a custom **PyTorch** model that tries to look at more than just the temporal price sequences.
* **Mechanism:** It ingests both the temporal data (historical prices) and static metadata (like the card's rarity and ink color).
* **Theory:** By concatenating static embeddings with the recurrent outputs, I'm hoping the model better contextualizes price movements (e.g., learning that an "Enchanted" card's volatility behaves very differently than a "Rare" card's).

**Why a Hybrid GRU?**
Standard time-series models treat every variable identically. Our hybrid approach separates the temporal data (price history) from the static metadata (card attributes):

1.  **Temporal Branch:** A multi-layer GRU processes sequences of normalized price data and relative days.
2.  **Static Branch:** Categorical attributes (Set, Rarity, Ink Cost) are mapped into dense vector spaces using PyTorch `nn.Embedding` layers. 
3.  **The Merge:** The sequence features and static embeddings are concatenated and passed through a final multi-layer perceptron (MLP) to generate the 30-day forecast.

#### The Attention Mechanism
To handle the erratic nature of the secondary market—where a single buyout can dictate a month's trend—we implemented an **Additive Attention Mechanism** over the GRU outputs.

Instead of relying solely on the final hidden state to summarize a 30-day window, the attention layer calculates a dynamic weight for *every* day in the sequence. This "Context Vector" allows the model to prioritize sudden price shocks or market shifts, ensuring that crucial historical signals are not lost in the sequence bottleneck.

**Key Features of the Training Pipeline:**
* **Multi-Window Training & Selection:** We train parallel models across different historical lookback windows (15, 30, and 45 days) to find the optimal signal-to-noise ratio. The final deployed model is selected based on a rigorous evaluation suite that prioritizes business-aligned metrics like **wMAPE** (Volume-Weighted MAPE) and **30-Day Macro Trend Accuracy**.
* **Rolling-Origin Backtesting (Time-Series CV):** To prevent data leakage and accurately gauge real-world reliability, the model is evaluated using a time-traveling validation approach. Instead of a single static test set, the script simulates past market eras (e.g., 30 days ago, 60 days ago) to stress-test the architecture against multiple historical regime changes and set releases.
* **Custom "Horizon Trend" Loss Function:** Standard loss functions are blind to trajectory. We engineered a custom loss function that uses `SmoothL1Loss` (Huber Loss) as a base to handle extreme TCG price outliers, but layers on a dynamic penalty for guessing the wrong market direction. This penalty scales with the forecast horizon and includes a "jitter threshold" to ignore daily pricing noise while aggressively punishing the model for missing the long-term macro destination.
* **Residual Forecasting:** The model predicts the *delta* (change in price) from the last known data point, rather than predicting the raw absolute value, greatly improving stability.

### 2. Pre-trained Transformer (Amazon Chronos)
I'm also experimenting with **Chronos**, a time-series forecasting framework built on language model architectures.
* **Mechanism:** Chronos essentially tokenizes the price values and uses a transformer to predict the next tokens in the sequence. 
* **Theory:** I've found it provides pretty solid zero-shot forecasting out of the box, which is really helpful for newly released cards that don't have enough historical data to train the GRU effectively.

---

# My Training & Inference Schedule

To bridge the gap between academic model evaluation and real-world deployment, the GRU forecasting engine operates on a strict **Two-Script Pipeline**. This ensures the live model is trained on 100% of available market data without sacrificing honest accuracy tracking.

1. **The Evaluator (`model_testing_gru.py`):** Run weekly. This script acts as the "Honest Grader." It performs the rolling-origin backtesting across three historical eras to ensure the architecture remains stable. The most recent fold acts as an unseen holdout set, successfully isolating real-world performance metrics and safely exporting them to `lorcana_global_metrics.csv` for the Shiny dashboard.
2. **The Production Brain (`train_lorcana_model.py`):** Run weekly after evaluation. This is a lean, ultra-fast script that strips away early-stopping and test splits. It trains the model on **100% of the historical dataset** for a fixed "sweet spot" of epochs (discovered via the Evaluator). This creates the smartest possible `.pth` weights file without locking the most recent 30 days of market momentum behind a test-set wall. 
3. **Daily Inference (`daily_inference_gru.py`):** Run daily. It wakes up, loads the fully-trained production `.pth` weights, generates the actual, unknown 30-day forecast for the future, and pushes the live predictions to the Neon PostgreSQL database.

### Monitoring & Health
I'm still tweaking how I monitor the pipeline, but right now I'm focusing on:
* **Model Divergence:** Keeping an eye on how wildly the Hybrid GRU and Chronos predictions differ from one another.
* **Data Integrity:** Tracking the "Match" rate coming out of Gemma. If it suddenly drops, it usually means eBay listing patterns or seller jargon have changed and I need to adjust my prompts.
* **Outlier Detection:** Trying to flag cards where my price predictions diverge significantly from what's actually happening in the market, which usually highlights a flaw in my data or an unpredictable market buyout.

<img width="1248" height="563" alt="Screenshot 2026-04-08 at 2 46 02 PM" src="https://github.com/user-attachments/assets/f9ffa787-2569-4384-b1ed-ea32fc89f124" />

<img width="233" height="591" alt="Screenshot 2026-04-08 at 2 44 56 PM" src="https://github.com/user-attachments/assets/3a23b88b-fd81-4097-84d9-a05169388301" />
