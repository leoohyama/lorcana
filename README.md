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

The ingestion and storage architecture relies on sourcing data from two locations, processing it, and storing it in a cloud database for visual consumption.

### The Pipeline Flow:
1.  **Sourcing:** Data is retrieved daily from **eBay** and **JustTCG**.
2.  **Processing:** The data is cleaned and filtered.
3.  **Storage:** Processed data is uploaded to a **PostgreSQL database (Neon)**.
4.  **Deployment:** A **Shiny app**, deployed via Posit Connect Cloud, accesses the database to summarize and visualize the data.

## Data Sources

* **eBay:** Listings are downloaded daily using the developer API. The data is cleaned and filtered to minimize outliers (e.g., extremely high "Buy It Now" or "Best Offer" prices) and ensure listings represent specified cards accurately.
* **JustTCG:** This API provides daily updates on average card pricing. These averages are used to cross-reference and stabilize the raw eBay listing data.

## Automation

All API downloads, data processing, and database uploads are managed automatically via **GitHub Actions**.

---

# Forecasting Models

*(Section in development. More details coming soon!)*

Notes for self

Currently approaching forecasting in two ways. 

1. Use recurrent neural networks, specifically gated recurrent units (GRU) to forecast price predictions for 30 days. This was chosen to just prototype and see what was possible given a relatively smaller dataset. Additionally the GRU that is trained is a hybrid GRU that uses both sequences of prices and static data (card attributes such as rarity, character).

2. Use a pre-trained transformer model, Chronos, that is fed all available price data for a given card tp produce a 30 day forecase. 
