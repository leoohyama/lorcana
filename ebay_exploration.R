# Load required libraries
library(DBI)
library(RPostgres)
library(dplyr)

# 1. Connect to Neon Serverless PostgreSQL
# Neon requires an SSL connection, which is handled via sslmode = "require"
con <- dbConnect(
  RPostgres::Postgres(),
  host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
  dbname   = "neondb", 
  user     = "neondb_owner",
  password = Sys.getenv("NEON_PASSWORD"), 
  port     = 5432, 
  sslmode  = "require"
)
# 2. Download the datasets into memory
cat("Downloading active_listings...\n")
active_listings <- dbReadTable(con, "lorcana_active_listings")

cat("Downloading llm_listing_metadata...\n")
llm_listing_metadata <- dbReadTable(con, "llm_listing_metadata")

# Optional: You can also execute a direct SQL join to save memory/processing 
# if you need them merged immediately for your PyTorch prep:
#
# joined_market_data <- dbGetQuery(con, "
#   SELECT a.*, l.card_name, l.set_name, l.rarity, l.foil, l.grade
#   FROM active_listings a
#   LEFT JOIN llm_listing_metadata l ON a.item_id = l.item_id
# ")

# 3. Disconnect securely
dbDisconnect(con)

# 4. Verify the data
glimpse(active_listings)
glimpse(llm_listing_metadata)

#get rid of unneeded graded column in active listings
active_listings = active_listings %>%
  select(-is_graded)

#clean llm data
llm_listing_metadata = llm_listing_metadata %>%
  filter(is_valid == "TRUE")

#now add identifer data so we know which cards are associated with which id
metacard = read.csv("data/target_cards_with_epids2.csv")


metacard=metacard %>%
  select(id, set_name, name, version, rarity) %>%
  mutate(card_full = paste(name, version, rarity, sep = " "),
.keep = "unused")


#join meta with unique listings
left_join(llm_listing_metadata, metacard, by = "id")

glimpse(active_listings)
glimpse(llm_listing_metadata)


library(tidyr) # for replace_na/coalesce

# 1. Properly stitch all three tables together
# We use inner_join on the LLM data because you filtered it for is_valid == TRUE
# This ensures we only analyze accurately parsed cards.
master_data <- active_listings %>%
  inner_join(llm_listing_metadata, by = c("item_id", "id")) %>%
  left_join(metacard, by = "id")

wtf=master_data  %>%
  filter(set_name == "Wilds Unknown")

# 2. Find the entry and exit dates for EVERY unique eBay listing
listing_lifespans <- master_data %>%
  group_by(item_id, card_full) %>%
  summarize(
    first_seen = min(date_pulled),
    last_seen = max(date_pulled),
    .groups = "drop"
  )

# Get the boundaries of your dataset to filter out edge-case artifacts
global_min_date <- min(listing_lifespans$first_seen)
global_max_date <- max(listing_lifespans$last_seen)

# 3. Calculate New Listings per day, per card
new_listings_summary <- listing_lifespans %>%
  filter(first_seen > global_min_date) %>% # Ignore the massive Day 1 bulk-load artifact
  group_by(date = first_seen, card_full) %>%
  summarize(new_listings = n(), .groups = "drop")

# 4. Calculate Disappeared Listings per day, per card
disappeared_summary <- listing_lifespans %>%
  filter(last_seen < global_max_date) %>% # Ignore currently active listings
  mutate(date = last_seen + 1) %>%        # It disappeared the day AFTER we last saw it
  group_by(date, card_full) %>%
  summarize(disappeared_listings = n(), .groups = "drop")



# 4b. Calculate Total Active Listings per day, per card
total_active_summary <- master_data %>%
  group_by(date = date_pulled, card_full) %>%
  summarize(total_active = n(), .groups = "drop")

# 5. Combine into a final Daily Inventory Ledger
daily_inventory_flow <- full_join(
  new_listings_summary, 
  disappeared_summary, 
  by = c("date", "card_full")
) %>%
  # Join the total active listings we just calculated
  full_join(total_active_summary, by = c("date", "card_full")) %>%
  mutate(
    new_listings = coalesce(new_listings, 0),
    disappeared_listings = coalesce(disappeared_listings, 0),
    # If a date exists but has no active listings, fill with 0
    total_active = coalesce(total_active, 0) 
  ) %>%
  arrange(date, card_full)

# Check the results
glimpse(daily_inventory_flow)


# Check the results
glimpse(daily_inventory_flow)
head(daily_inventory_flow %>% filter(card_full == "Elsa Enchanted")) # Example check

library(ggplot2)
library(dplyr)

selectedcard = "Mickey Mouse Brave Little Prince Iconic"

# 1. Filter for the selected card
card_flow <- daily_inventory_flow %>%
  filter(card_full == selectedcard)

# 2. Create the Plot
ggplot(card_flow) +
  # New Listings (Positive bars)
  geom_col(aes(x = as.Date(date), y = new_listings, fill = "New Listings")) +
  
  # Disappeared Listings (Negative bars)
  geom_col(aes(x = as.Date(date), y = -disappeared_listings, fill = "Listings Gone")) +
  
  # Total Active (Trend line) - Replaced net_change
  geom_line(aes(x = as.Date(date), y = total_active, color = "Total Active"), linewidth = 1) +
  geom_point(aes(x = as.Date(date), y = total_active, color = "Total Active"), size = 2) +
  
  # Formatting
  theme_minimal() +
  scale_y_continuous(labels = abs) + # Keeps y-axis labels positive for the negative bars
  labs(
    title = selectedcard,
    subtitle = "Daily Supply Injections vs. Sales/Delistings & Total Active Inventory",
    x = "Date",
    y = "Volume of Listings",
    fill = "Activity Type",
    color = "Overall Supply"
  ) +
  scale_fill_manual(values = c("New Listings" = "#1b9e77", "Listings Gone" = "#d95f02")) +
  scale_color_manual(values = c("Total Active" = "black")) +
  theme(legend.position = "bottom")


glimpse(master_data)



####ebay data pricing

library(ggplot2)
library(dplyr)
library(scales)
library(stringr)

# Prepare Auction Data
auction_data <- master_data %>%
  filter(
    card_full == selectedcard, 
    str_detect(listing_type, "AUCTION")
  ) %>%
  mutate(
    # Create a clean label for faceting
    grade_status = if_else(is_graded, "Graded", "Raw / Ungraded")
  )

# Create the Auction Plot
auction_plot <- ggplot(auction_data, aes(x = date_pulled, y = price_val, group = item_id, color = grade_status)) +
  # geom_line connects the same listing over time; geom_point ensures 1-day listings still show up
  geom_line(alpha = 0.5, linewidth = 0.8) +
  geom_point(alpha = 0.5, size = 1.2) +
  
  # Facet by Graded vs Raw (free_y allows the scales to adjust independently if needed)
  facet_wrap(~grade_status, scales = "free_y") +
  
  # Formatting
  scale_y_continuous(labels = label_dollar()) +
  scale_x_date(date_labels = "%b %d", date_breaks = "1 week") +
  scale_color_manual(values = c("Graded" = "#619CFF", "Raw / Ungraded" = "#F8766D")) +
  theme_minimal() +
  labs(
    title = paste("Auction Bid Trajectories:", selectedcard),
    subtitle = "Tracking individual auction listings over time",
    x = "Date",
    y = "Current Bid / Final Price ($)"
  ) +
  theme(
    legend.position = "none", # Legend is redundant due to facets
    strip.background = element_rect(fill = "gray95", color = NA),
    strip.text = element_text(face = "bold")
  )

# Display the plot
print(auction_plot)


# Prepare Buy It Now Data
bin_trend_data <- master_data %>%
  filter(
    card_full == selectedcard, 
    str_detect(listing_type, "FIXED_PRICE")
  ) %>%
  mutate(
    grade_status = if_else(is_graded, "Graded", "Raw / Ungraded")
  ) %>%
  # Group by date AND grade status to calculate independent medians
  group_by(date_pulled, grade_status) %>%
  summarize(
    median_price = median(price_val, na.rm = TRUE),
    .groups = "drop"
  )

# Create the Buy It Now Plot
bin_plot <- ggplot(bin_trend_data, aes(x = date_pulled, y = median_price, color = grade_status)) +
  geom_line(linewidth = 1.2) +
  geom_point(size = 2) +
  
  # Formatting
  scale_y_continuous(labels = label_dollar()) +
  scale_x_date(date_labels = "%b %d", date_breaks = "1 week") +
  scale_color_manual(values = c("Graded" = "#619CFF", "Raw / Ungraded" = "#F8766D")) +
  theme_minimal() +
  labs(
    title = paste("Buy It Now - Median Market Price:", selectedcard),
    subtitle = "Tracking median listing price to filter out extreme 'Best Offer' outliers",
    x = "Date",
    y = "Median Listing Price ($)",
    color = "Condition"
  ) +
  theme(
    legend.position = "bottom"
  )

# Display the plot
print(bin_plot)


library(plotly)
library(crosstalk)
library(dplyr)

# 1. Prepare the data
# Filter out bad data and convert columns to factors for the dropdowns
interactive_data <- master_data %>%
  filter(card_full == selectedcard, price_val > 0) %>%
  mutate(
    type_simple = if_else(str_detect(listing_type, "AUCTION"), "Auction", "Buy It Now"),
    grade_val = replace_na(grade_val, "Raw"),
    grading_company = replace_na(grading_company, "Raw")
  ) %>%
  select(item_id, price_val, grading_company, grade_val, type_simple, date_pulled)

# 2. Create a Crosstalk SharedData object
shared_market <- SharedData$new(interactive_data)

# 3. Create the interactive Plotly chart
p <- plot_ly(shared_market, 
             x = ~grading_company, 
             y = ~price_val, 
             color = ~grade_val,
             type = "scatter", 
             mode = "markers",
             hoverinfo = "text",
             text = ~paste("Price: $", price_val, 
                           "<br>Grade:", grading_company, grade_val,
                           "<br>Type:", type_simple,
                           "<br>Date:", date_pulled),
             marker = list(size = 8, opacity = 0.6)) %>%
  layout(title = paste("Interactive Explorer:", selectedcard),
         yaxis = list(title = "Price ($)"),
         xaxis = list(title = "Grading Company"))

# 4. Wrap it in a crosstalk layout with UI filters
bscols(
  widths = c(3, 9), # Left column for filters, right column for plot
  list(
    filter_select("comp", "Grading Company", shared_market, ~grading_company),
    filter_select("grade", "Grade", shared_market, ~grade_val),
    filter_select("type", "Listing Type", shared_market, ~type_simple)
  ),
  p
)
