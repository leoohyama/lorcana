library(tidyverse)
library(scales)

# 1. Load both tidy files
gru_preds <- read_csv("data/pytorch/gru_forecast_tidy.csv", col_types = cols(card_id = col_character())) %>%
  mutate(model = "GRU") # Add the tag so it matches Chronos

chronos_preds <- read_csv("data/chronos_forecast_tidy.csv", col_types = cols(card_id = col_character()))

# 2. Stack them together and join with static metadata
combined_data <- bind_rows(gru_preds, chronos_preds) %>%
  left_join(read_csv("data/target_cards_with_epids2.csv", col_types = cols(tcgplayer_id = col_character())), 
            by = c("card_id" = "tcgplayer_id")) %>%
  mutate(card_label = paste0(name,": ",version," (", rarity, ")"))

# 3. Plot the Showdown for Hades
ggplot(combined_data %>% filter(card_label == "Bambi: Little Prince (Enchanted)"), 
       aes(x = day_offset)) +
  
  # Ground Truth
  geom_line(aes(y = actual_price), color = "black", size = 1.2) +
  
  # Model Predictions (Color mapped to the 'model' column)
  geom_line(aes(y = pred_price, color = model), size = 1) +
  geom_point(aes(y = pred_price, color = model), size = 1.5) +
  
  theme_minimal() +
  scale_y_continuous(labels = label_dollar()) +
  scale_color_manual(values = c("GRU" = "#e74c3c", "Chronos" = "#3498db")) +
  labs(
    title = "Model Showdown: Hades (Enchanted)",
    subtitle = "Solid Black = Actual Price | Colored = Model Prediction",
    x = "Days into Test Window",
    y = "Price ($)"
  )


# 1. Calculate Error Metrics per Card AND Model
accuracy_summary <- combined_data %>%
  group_by(card_id, name, version, rarity, set_name, card_label, model) %>%
  summarize(
    MAE = mean(abs(actual_price - pred_price)),
    MAPE = mean(abs(actual_price - pred_price) / actual_price),
    avg_price = mean(actual_price),
    .groups = "drop"
  )

# 2. The Head-to-Head "Showdown" Table
head_to_head <- accuracy_summary %>%
  select(card_label, rarity, set_name, avg_price, model, MAPE) %>%
  pivot_wider(names_from = model, values_from = MAPE, names_prefix = "MAPE_") %>%
  mutate(
    # Declare the winner
    Winner = if_else(MAPE_GRU < MAPE_Chronos, "GRU", "Chronos"),
    # Calculate by exactly HOW MUCH they won (absolute percentage difference)
    Win_Margin = abs(MAPE_GRU - MAPE_Chronos)
  ) %>%
  arrange(desc(Win_Margin)) # Sort by biggest blowouts first

# 3. View the Biggest Blowouts
print("Top 5 Cards where GRU destroyed Chronos:")
head_to_head %>% filter(Winner == "GRU") %>% head(5) %>% print(width = Inf)

print("Top 5 Cards where Chronos destroyed GRU:")
head_to_head %>% filter(Winner == "Chronos") %>% head(5) %>% print(width = Inf)



# Visualizing Accuracy by Rarity & Model
ggplot(accuracy_summary, aes(x = reorder(rarity, MAPE, FUN = median), y = MAPE, fill = model)) +
  # position_dodge puts the boxes side-by-side instead of stacking them
  geom_boxplot(alpha = 0.8, position = position_dodge(width = 0.8)) +
  scale_y_continuous(labels = label_percent()) +
  coord_flip() +
  facet_wrap(~set_name) +
  scale_fill_manual(values = c("GRU" = "#e74c3c", "Chronos" = "#3498db")) +
  theme_minimal(base_size = 14) +
  labs(
    title = "GRU vs Chronos: Error Distribution by Rarity",
    subtitle = "Lower MAPE is better. Outliers indicate unpredictable spikes/crashes.",
    x = "Rarity",
    y = "Mean Absolute % Error (MAPE)",
    fill = "Model"
  ) +
  theme(legend.position = "top")


# Find the card where GRU had the biggest advantage
gru_champ_label <- head_to_head %>% filter(Winner == "GRU") %>% pull(card_label) %>% first()

# Find the card where Chronos had the biggest advantage
chronos_champ_label <- head_to_head %>% filter(Winner == "Chronos") %>% pull(card_label) %>% first()

# Filter combined data for just these two cards
stress_test_data <- combined_data %>%
  filter(card_label %in% c(gru_champ_label, chronos_champ_label))

# Plot the Showdown
ggplot(stress_test_data, aes(x = day_offset)) +
  # The Ground Truth
  geom_line(aes(y = actual_price), color = "black", size = 1.2) +
  
  # The Predictions from BOTH models
  geom_line(aes(y = pred_price, color = model), size = 1, alpha = 0.8) +
  geom_point(aes(y = pred_price, color = model), size = 1.5) +
  
  # Facet by Card Label
  facet_wrap(~card_label, scales = "free_y", ncol = 1) + 
  
  scale_y_continuous(labels = label_dollar()) +
  scale_color_manual(values = c("GRU" = "#e74c3c", "Chronos" = "#3498db")) +
  theme_minimal(base_size = 14) +
  labs(
    title = "Tale of Two Models: The Biggest Discrepancies",
    subtitle = paste0(
      "Top plot: GRU outperforms. Bottom plot: Chronos outperforms.\n",
      "Solid Black = Actual Price"
    ),
    x = "Days into Test Window",
    y = "Price ($)",
    color = "Model"
  ) +
  theme(legend.position = "top", strip.text = element_text(face = "bold", size = 12))
