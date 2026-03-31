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



library(tidyverse)
library(scales)

# 1. Load the Historical Data
history_df <- read_csv("data/chronos_ready_prices.csv", col_types = cols(card_id = col_character()))

# 2. Calculate "Pre-Test" Volatility (FIXED)
volatility_metrics <- history_df %>%
  # PRE-FILTER: Only calculate this for cards we actually tested
  filter(card_id %in% accuracy_summary$card_id) %>%
  group_by(card_id) %>%
  arrange(date) %>%
  # SAFETY CHECK: Ensure the group actually has more than 30 rows
  filter(n() > 30) %>%
  slice(1:(n() - 30)) %>% # Drop the 30-day test window
  summarize(
    hist_mean_price = mean(price, na.rm = TRUE),
    hist_sd_price = sd(price, na.rm = TRUE),
    # Coefficient of Variation (Higher % = More Volatile)
    volatility_cv = hist_sd_price / hist_mean_price, 
    .groups = "drop"
  )

# 3. Join with your existing 'accuracy_summary'
diagnostic_data <- accuracy_summary %>%
  left_join(volatility_metrics, by = "card_id") %>%
  filter(!is.na(volatility_cv))

# 4. Plotting the Relationship
ggplot(diagnostic_data, aes(x = volatility_cv, y = MAPE, color = model)) +
  geom_point(alpha = 0.5, size = 2) +
  geom_smooth(method = "lm", se = FALSE, size = 1.2) +
  theme_minimal(base_size = 14) +
  scale_color_manual(values = c("GRU" = "#e74c3c", "Chronos" = "#3498db")) +
  scale_x_continuous(labels = label_percent()) +
  scale_y_continuous(labels = label_percent()) +
  labs(
    title = "Model Breakdown: Does Volatility cause Errors?",
    subtitle = "X-Axis: Historical Price Swing % | Y-Axis: Model Prediction Error %",
    x = "Historical Volatility (Coefficient of Variation)",
    y = "Prediction Error (MAPE)",
    color = "Model"
  ) +
  theme(legend.position = "top")


# 1. Define your target card
target_label <- "Arthur: Wizard's Apprentice (Enchanted)"

# Get the specific card_id for Bambi from your combined data
target_id <- combined_data %>% 
  filter(card_label == target_label) %>% 
  pull(card_id) %>% 
  first()

# 2. Prepare the Historical Data (The "Runway")
# We filter the raw history, drop the 30-day test window, and assign negative days
bambi_history <- history_df %>%
  filter(card_id == target_id) %>%
  arrange(date) %>%
  slice(1:(n() - 30)) %>% # Remove the 30 days that make up our test window
  mutate(
    # Create a countdown to Day 0 (e.g., -180, -179... 0)
    day_offset = seq(-n() + 1, 0)
  )

# 3. Prepare the Prediction Data
bambi_preds <- combined_data %>% 
  filter(card_label == target_label)

# 4. Plot the Full Timeline
ggplot() +
  
  # A. THE HISTORY (Gray line leading up to the forecast)
  geom_line(data = bambi_history, aes(x = day_offset, y = price), 
            color = "darkgray", size = 1) +
  
  # B. THE GROUND TRUTH (Black line for the actual 30-day test window)
  geom_line(data = bambi_preds, aes(x = day_offset, y = actual_price), 
            color = "black", size = 1.2) +
  
  # C. THE MODEL PREDICTIONS (Colored lines branching off)
  geom_line(data = bambi_preds, aes(x = day_offset, y = pred_price, color = model), 
            size = 1) +
  geom_point(data = bambi_preds, aes(x = day_offset, y = pred_price, color = model), 
             size = 1.5) +
  
  # D. THE "MOMENT OF TRUTH" LINE
  # A vertical dashed line to show exactly where the models had to start guessing
  geom_vline(xintercept = 0.5, linetype = "dashed", color = "black", alpha = 0.5) +
  
  # Formatting & Labels
  theme_minimal(base_size = 14) +
  scale_y_continuous(labels = label_dollar()) +
  scale_color_manual(values = c("GRU" = "#e74c3c", "Chronos" = "#3498db")) +
  labs(
    title = paste("Full Context Showdown:", target_label),
    subtitle = "Gray = Historical Runway | Black = Actual Price | Colored = Model Predictions",
    x = "Days (0 = Moment of Prediction)",
    y = "Price ($)",
    color = "Model"
  ) +
  theme(legend.position = "top")


library(tidyverse)
library(scales)

# 1. Join Volatility to the RAW Daily Predictions
# (Assuming 'combined_data' and 'volatility_metrics' are already in your environment)
daily_error_data <- combined_data %>%
  left_join(volatility_metrics, by = "card_id") %>%
  filter(!is.na(volatility_cv)) %>%
  mutate(
    # Calculate the error for this exact day
    APE = abs(actual_price - pred_price) / actual_price,
    
    # Split the portfolio into 3 equal Volatility Tiers
    volatility_tier = ntile(volatility_cv, 3),
    volatility_label = case_when(
      volatility_tier == 1 ~ "1. Low Volatility (Stable)",
      volatility_tier == 2 ~ "2. Medium Volatility",
      volatility_tier == 3 ~ "3. High Volatility (Chaotic)"
    )
  )

# 2. Calculate Average Daily Error (MAPE per day, per tier, per model)
daily_mape_summary <- daily_error_data %>%
  group_by(day_offset, model, volatility_label) %>%
  summarize(
    Daily_MAPE = mean(APE, na.rm = TRUE), 
    .groups = "drop"
  )

# 3. Plot 1: The Forecast Horizon Plot
ggplot(daily_mape_summary, aes(x = day_offset, y = Daily_MAPE, color = model)) +
  geom_line(size = 1.2) +
  geom_point(size = 2, alpha = 0.8) +
  
  # Facet by our Volatility Tiers
  facet_wrap(~volatility_label, ncol = 3) +
  
  theme_minimal(base_size = 14) +
  scale_y_continuous(labels = label_percent()) +
  scale_color_manual(values = c("GRU" = "#e74c3c", "Chronos" = "#3498db")) +
  labs(
    title = "Forecast Degradation: How Error Grows Over Time",
    subtitle = "Tracking Average Error from Day 1 to Day 30 across Volatility Tiers",
    x = "Days into the Future",
    y = "Average Daily Error (MAPE)",
    color = "Model"
  ) +
  theme(legend.position = "top", strip.text = element_text(face = "bold", size = 12))


# 4. Plot 2: Volatility vs. Error at Specific Milestones
milestone_data <- daily_error_data %>%
  # Look at Day 1, End of Week 1, End of Week 2, and End of Month
  filter(day_offset %in% c(1, 7, 14, 30)) %>%
  mutate(day_label = paste("Day", day_offset, "Forecast")) %>%
  # Ensure the facets order correctly
  mutate(day_label = fct_reorder(day_label, day_offset))

ggplot(milestone_data, aes(x = volatility_cv, y = APE, color = model)) +
  # Use alpha to make the dense scatter points readable
  geom_point(alpha = 0.2, size = 1.5) +
  
  # The trend line is the most important part here
  geom_smooth(method = "lm", se = FALSE, size = 1.2) +
  
  facet_wrap(~day_label, ncol = 4) +
  theme_minimal(base_size = 14) +
  scale_x_continuous(labels = label_percent()) +
  scale_y_continuous(labels = label_percent()) +
  scale_color_manual(values = c("GRU" = "#e74c3c", "Chronos" = "#3498db")) +
  labs(
    title = "The Horizon Effect: Volatility vs. Error over Time",
    subtitle = "Does high historical volatility break the models immediately, or only later?",
    x = "Historical Volatility (CV)",
    y = "Absolute % Error (APE)",
    color = "Model"
  ) +
  theme(legend.position = "top")
