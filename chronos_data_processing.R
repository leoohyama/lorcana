library(tidyverse)
library(lubridate)

temporal_time <- readRDS("data/tabular/price_history_long_initial.rds") 
static <- read.csv("data/target_cards_with_epids2.csv") %>%
  filter(!str_detect(set_name, "Promo")) 

print("1. Cleaning Temporal Data & Filling Gaps...")
temporal_clean <- temporal_time %>%
  mutate(date = as.Date(date)) %>%
  group_by(card_id, date) %>%
  summarize(price = mean(price, na.rm = TRUE), .groups = 'drop') %>%
  group_by(card_id) %>%
  complete(date = seq.Date(min(date), max(date), by = "day")) %>%
  fill(price, .direction = "down") %>%
  ungroup()

print("2. Grabbing Card Names...")
# We only need the name so we can filter for specific cards in Python
static_names <- static %>%
  mutate(tcgplayer_id = as.character(tcgplayer_id)) %>%
  select(tcgplayer_id, name)

print("3. Final Merge...")
df_chronos_ready <- temporal_clean %>%
  left_join(static_names, by = c("card_id" = "tcgplayer_id")) %>%
  drop_na(name) %>%
  arrange(card_id, date)

print("4. Exporting to Python...")
write_csv(df_chronos_ready, "data/chronos_ready_prices.csv")
print("Export complete. Ready for Chronos.")