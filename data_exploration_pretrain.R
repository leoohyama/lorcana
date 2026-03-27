library(tidyverse)

#read in 180 days historical data

temporal_time = readRDS("data/tabular/price_history_long_initial.rds")
head(temporal_time)

#next read in static card data
static = read.csv("data/target_cards_with_epids2.csv")


unique_id = unique(temporal_time$card_id)


ggplot(data = temporal_time %>% filter(card_id == "633053")) +
  geom_line(aes(x = date, y = price))


temporal_time %>% select(card_id,date,price) %>%
  mutate(card_id = as.integer(card_id)) %>%
  left_join(., static %>% select(tcgplayer_id, set_name, rarity), by = c("card_id" = "tcgplayer_id")) %>%
  group_by(set_name, rarity, date) %>%
  summarise(mean_price = mean(price),
            median_price = median(price)) %>%
  ggplot(data = . ) +
  geom_line(aes(x = date, y = mean_price, color = rarity))+
  facet_wrap(~set_name, scales = "free_y") 


library(tidyverse)
library(scales) 

# The Okabe-Ito Colorblind-Friendly Palette
okabe_ito_palette <- c(
  "#E69F00", # Orange
  "#56B4E9", # Sky Blue
  "#009E73", # Bluish Green
  "#F0E442", # Yellow
  "#0072B2", # Blue
  "#D55E00", # Vermilion
  "#CC79A7"  # Reddish Purple
)

temporal_time %>% 
  select(card_id, date, price) %>%
  mutate(card_id = as.integer(card_id)) %>%
  left_join(static %>% select(tcgplayer_id, set_name, rarity), by = c("card_id" = "tcgplayer_id")) %>%
  filter(!str_detect(set_name, "Promo")) %>%
  
  # MANUALLY ORDER SETS CHRONOLOGICALLY
  # fct_relevel will put these in exact order, any sets not listed will naturally fall to the end
  mutate(set_name = fct_relevel(set_name, 
                                "The First Chapter", 
                                "Rise of the Floodborn", 
                                "Into the Inklands", 
                                "Ursula's Return", 
                                "Shimmering Skies", 
                                "Azurite Sea")) %>%
                                
  group_by(set_name, rarity, date) %>%
  summarise(
    mean_price = mean(price, na.rm = TRUE),
    median_price = median(price, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  pivot_longer(
    cols = c(mean_price, median_price), 
    names_to = "stat", 
    values_to = "price_value"
  ) %>%
  
  # PLOTTING
  ggplot(aes(x = date, y = price_value, color = rarity, linetype = stat)) +
  geom_line(linewidth = 1.2, alpha = 0.9) + 
  facet_wrap(~set_name, scales = "free_y") +
  
  # APPLY OKABE-ITO PALETTE
  scale_color_manual(values = okabe_ito_palette) +
  scale_x_date(date_labels = "%b %Y", date_breaks = "1 month") +
  
  labs(
    title = "Lorcana Price Trends: Mean vs Median by Set",
    subtitle = "Aggregated daily price points arranged in chronological release order",
    y = "Price ($)",
    x = "Timeline",
    linetype = "Statistic",
    color = "Rarity"
  ) +
  theme_minimal(base_size = 14) +
  theme(
    text = element_text(color = "#333333"),
    strip.text = element_text(face = "bold", size = 12),
    axis.text.x = element_text(angle = 45, hjust = 1),   
    panel.grid.minor = element_blank(),
    legend.position = "bottom",
    plot.title = element_text(face = "bold", size = 18)
  )
