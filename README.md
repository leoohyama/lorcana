# General overview

This is a repo containing scripts to that market data of the trading card game Lorcana. These scripts and worflows aim to achieve several objectives:

1. Collect market data from both ebay and JustTCG that is cleaned and summarized through a shinyapp. The goals of this app is to provide users up-to-date data regarding the pricing, liquidity, market momentem of their cards.
2. Develop price forecasting models via pytorch to provide accurate price predictions for various cards using market data. These forecasts will then be fed into the shiny app.

The current workflow/schema for this project is as follows:
<img width="1585" height="863" alt="image" src="https://github.com/user-attachments/assets/13e49a31-7878-49d9-a841-d6633839729e" />

# Quick context
Trading card games (TCGs) are a source of entertainment and fun for both players and/or collectors. Other popular examples of TCGs include Pokemon, Yu-Gi Oh, and Magic the Gathering. Disney Lorcana is a TCG that was introduced in 2023 and uses Disney's intellectual properties in their game and cards. Because of the wide appeal of Disney through tv, movies, and other forms of entertainment, Lorcana cards have become appreciated by collectors for a variety of reasons including but not limited to their artwork, rarity, and ability to spark nostalgia. Because of this, there is a secondary market for these cards that is both volatile and speculative. Here are a few examples of what leads to these market characteristcs. 

Rarity: Rarity of a card is tied to how often it is actually found when opening packs of cards. For example some cards can only be found in 1 out of 96 packs of cards. With a pack costing anywhere from $4-$8USD, the cost of finding some of these cards add up. Rarity is also an actual feature of a card. In Lorcana there are different levels of rarity classes that cards fall within. These include but are not limited to: "Common", "Uncommon", "Rare", "Super Rare", "Legendary", "Epic", "Enchanted", and "Iconic". 

Here is an example of one of the rarer cards in Lorcana, the Mickey Mouse Brave Little Tailor Card (Iconic Rarity):
<img width="269" height="375" alt="image" src="https://github.com/user-attachments/assets/75a184fa-0ac4-4f5a-aeb0-7a4f7dd58c29" />


Artwork: Certain cards in Lorcana are given special artwork that is often tied to their rarity. This not only makes such cards more exclusive but provide colelctors with even more incentive to collect. 

Nostalgia: Disney characters are well-known and many adults today were brought up watching them. Certain characters can evoke powerful emotions and cards that represent these characters can provide intrinsic value. 

# Dataflow
The general flow/architecture for the ingestion and storage of new data depends on sourcing data from two sources (ebay and JustTCG), cleaning these data, uploading to a third-party PostgresSQL databases (Neon), and finally using a shinyapp deployed via Posit Connect Cloud to summarize and visualize these data.

## Data Sources
Ebay listings are downlaoded using their developer api access every day. The listings are cleaned and filtered to minimize inclusion of data that don't represent specified cards. 
JustTCG's api provide average pricing of cards that is updated daily. These prices are used rather than relying fully on ebay listings data as the latter can often be influenced by inclusion of outliers (e.g. extremely highly priced buy it now or best offers) among pther issues. 

## Automation
All the API downloads, and data uploads are managed with Github Actions. 

# Forecasting models

More soon!
