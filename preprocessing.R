#preprocessing


temporal_time = readRDS("data/tabular/price_history_long_initial.rds") 

static = read.csv("data/target_cards_with_epids2.csv") %>%
  filter(!str_detect(set_name, "Promo")) 
library(tidyverse)
library(lubridate)

# Assuming temporal_time and static are already in your environment

print("1. Cleaning Temporal Data...")
temporal_clean <- temporal_time %>%
  mutate(date = as.Date(date)) %>%
  # Aggregate intra-day prices to a daily average
  group_by(card_id, date) %>%
  summarize(price = mean(price, na.rm = TRUE), .groups = 'drop') %>%
  # Forward-fill missing days to ensure continuous sequence
  group_by(card_id) %>%
  complete(date = seq.Date(min(date), max(date), by = "day")) %>%
  fill(price, .direction = "down") %>%
  ungroup()

print("2. Cleaning Static Metadata...")
static_clean <- static %>%
  mutate(
    tcgplayer_id = as.character(tcgplayer_id),
    released_at = mdy(released_at), 
    inkwell = as.integer(inkwell)   
  ) %>%
  select(tcgplayer_id, name, set_name, rarity, released_at, cost, inkwell, ink_clean)

print("3. Merging and Feature Engineering...")
df_merged <- temporal_clean %>%
  left_join(static_clean, by = c("card_id" = "tcgplayer_id")) %>%
  mutate(
    days_since_release = as.integer(date - released_at),
    days_since_release = if_else(days_since_release < 0, 0L, days_since_release) 
  ) %>%
  drop_na(name)

print("4. Scaling and Encoding for Neural Networks...")
# Global min-max function for static continuous variables
min_max_scale_global <- function(x) {
  (x - min(x, na.rm = TRUE)) / (max(x, na.rm = TRUE) - min(x, na.rm = TRUE))
}

df_final <- df_merged %>%
  # --- LOCAL SCALING (PER CARD) ---
  group_by(card_id) %>%
  mutate(
    # Save the real dollar bounds so Python can reverse the math later
    card_min_price = min(price, na.rm = TRUE),
    card_max_price = max(price, na.rm = TRUE),
    
    # Scale price locally. If max == min (price never changed), set to 0.5 to avoid Div/0 Error
    price_scaled = if_else(
      card_max_price == card_min_price, 
      0.5, 
      (price - card_min_price) / (card_max_price - card_min_price)
    )
  ) %>%
  ungroup() %>%
  
  # --- GLOBAL SCALING ---
  mutate(
    cost_scaled = min_max_scale_global(cost),
    days_scaled = min_max_scale_global(days_since_release)
  ) %>%
  
  # --- LABEL ENCODING ---
  mutate(
    name_idx = as.integer(as.factor(name)) - 1L,
    set_idx = as.integer(as.factor(set_name)) - 1L,
    rarity_idx = as.integer(as.factor(rarity)) - 1L,
    ink_idx = as.integer(as.factor(ink_clean)) - 1L
  ) %>%
  arrange(card_id, date)

print("5. Exporting to Python...")
write_csv(df_final, "data/pytorch/lorcana_pytorch_ready.csv")
print("Export complete. Ready for PyTorch.")