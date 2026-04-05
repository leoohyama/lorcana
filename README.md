# Lorcana Market Data Analysis & Forecasting

### 🎯 My Project Roadmap & To-Dos
1.  **LLM Fine-Tuning:** I'm exploring LoRA (Low-Rank Adaptation) to see if I can train the **Gemma 4.0 2B** model to better handle "edge-case" Lorcana titles (like seller misspellings or weird promotional jargon that currently trips up the pipeline).
2.  **Attention Mechanisms:** I want to try adding attention layers into my GRU architecture to see if it helps the model capture key market events and weigh them more heavily in the forecasts.
3.  **Confidence Intervals:** A major goal is integrating model confidence percentages for individual price forecasts so I have a better sense of when the model is basically just guessing.
4.  **Blue Chip Index:** I'm working on developing a weighted index (e.g., tracking the Top 50 Enchanteds) to get a quick pulse on the overall health of the Lorcana market.
5.  **UI Enhancements:** I need to add a "Last Trained" timestamp to the dashboard so I know if a run failed, and I'm currently implementing a "Filter by Grade" (PSA, CGC, etc.) feature for better granularity.

---

### Project Overview
This repository houses my personal data pipeline and forecasting experiments for the Disney Lorcana TCG. I've set up a **Hybrid Local-Cloud Architecture** that combines some cloud scraping with local **Large Language Model (LLM)** inference. My main goal here is to try and clean up the inherently messy secondary market data as much as possible before feeding it into any predictive models.

### 🤖 AI Data Cleaning (Gemma 4.0)
Trying to filter out the "noise" in eBay TCG data (proxies, digital codes, and "repack" scams) is a huge headache. To tackle this, I'm currently experimenting with **Gemma 4.0 (2B Effective)** running locally via **Ollama** on my Apple Silicon runner. 

* **Title Validation:** I have Gemma performing a character-and-subtitle check to try and verify that the listing matches the target card exactly, helping me filter out seller "keyword stuffing."
* **Structured Extraction:** I'm prompting the model to extract structured JSON data from the raw, messy eBay listing strings to identify:
    * **Match Validity:** (Match/No Match)
    * **Grading Status:** (True/False)
    * **Grading Company:** (PSA, BGS, CGC, SGC, PCG)
    * **Grade Value:** (e.g., 10, 9.5, 9)
* **Incremental Processing:** To save on compute time, the pipeline uses a "Delta-only" approach. It cross-references new `item_ids` against my existing metadata table so that each listing only goes through the AI extraction process once.

### 🏗️ System Architecture Workflow

<p align="center">
  <img src="https://github.com/user-attachments/assets/13e49a31-7878-49d9-a841-d6633839729e" alt="Lorcana Workflow Diagram" style="max-width: 100%; height: auto;" />
</p>

1.  **Sourcing (Cloud):** I use GitHub Actions (Ubuntu-latest) to run a daily scrape of **eBay** and **JustTCG**, pushing the raw, unfiltered logs to my **Neon (Postgres)** database.
2.  **AI Cleaning (Local MacBook Runner):** Once the cloud scrape finishes, a self-hosted runner wakes up on my local MacBook Air. It pulls down any new `item_ids`, runs them through **Gemma 4.0** via my local **Ollama** instance, and updates the `llm_listing_metadata` table.
3.  **Deployment (Shiny App):** On the frontend, my dashboard performs a relational join between the raw price logs and the AI-verified metadata. This lets me filter out "dirty" or mismatched data in real-time when I'm looking at the charts.

---

# Context & Market Dynamics

Trading card games (TCGs) have incredibly speculative and volatile secondary markets. Introduced in 2023, **Disney Lorcana** is an interesting case study because it leverages Disney's massive library of intellectual property. 

From what I've observed tracking this data, a few key factors drive the market:

### 1. Rarity & Grading
A card's baseline value is tied to its pull rate. Lorcana has several rarity classifications ("Common", "Uncommon", "Rare", "Super Rare", "Legendary", "Epic", "Enchanted", and "Iconic"). Beyond raw rarity, the "Graded" market (PSA, CGC, BGS) introduces wild price premiums for high-quality "slabs" that are hard to consistently track.

<p align="center">
  <img src="https://github.com/user-attachments/assets/75a184fa-0ac4-4f5a-aeb0-7a4f7dd58c29" alt="Mickey Mouse Brave Little Tailor Card (Iconic Rarity)" width="269" height="375" />
  <br>
  <em>Example: Mickey Mouse - Brave Little Tailor (Iconic Rarity)</em>
</p>

### 2. Artwork & Nostalgia
Special artwork and beloved Disney characters—like Stitch, which is a major focus for my own collection—evoke powerful emotional connections. This creates a sort of intrinsic value and high demand among collectors that doesn't always align with a card's actual playability in the game.

---

# Forecasting Models

I'm approaching the price forecasting aspect as a multi-modal time-series problem. Right now, I'm testing out two very different architectures to see what handles the volatility best:

### 1. Hybrid Gated Recurrent Unit (GRU)
I built a custom **PyTorch** model that tries to look at more than just the temporal price sequences.
* **Mechanism:** It ingests both the temporal data (historical prices) and static metadata (like the card's rarity and ink color).
* **Theory:** By concatenating static embeddings with the recurrent outputs, I'm hoping the model better contextualizes price movements (e.g., learning that an "Enchanted" card's volatility behaves very differently than a "Rare" card's).

### 2. Pre-trained Transformer (Amazon Chronos)
I'm also experimenting with **Chronos**, a time-series forecasting framework built on language model architectures.
* **Mechanism:** Chronos essentially tokenizes the price values and uses a transformer to predict the next tokens in the sequence. 
* **Theory:** I've found it provides pretty solid zero-shot forecasting out of the box, which is really helpful for newly released cards that don't have enough historical data to train the GRU effectively.

---

# My Training & Inference Schedule

* **Weekly Training:** I have the **GRU model** set to retrain on the full historical dataset once a week. I'm currently evaluating its performance against a hold-out test set using **Absolute Percentage Error** metrics to see if it's actually improving.
* **Daily Inference:**
    * **Gemma 4.0:** Processes the new batch of eBay listings immediately following the daily cloud scrape.
    * **Chronos/GRU:** Generates a fresh 30-day forecast based on the previous day's closing prices.

---

### Monitoring & Health
I'm still tweaking how I monitor the pipeline, but right now I'm focusing on:
* **Model Divergence:** Keeping an eye on how wildly the Hybrid GRU and Chronos predictions differ from one another.
* **Data Integrity:** Tracking the "Match" rate coming out of Gemma. If it suddenly drops, it usually means eBay listing patterns or seller jargon have changed and I need to adjust my prompts.
* **Outlier Detection:** Trying to flag cards where my price predictions diverge significantly from what's actually happening in the market, which usually highlights a flaw in my data or an unpredictable market buyout.
