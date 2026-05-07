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

# 5. Combine into a final Daily Inventory Ledger
daily_inventory_flow <- full_join(
  new_listings_summary, 
  disappeared_summary, 
  by = c("date", "card_full")
) %>%
  # Replace NA with 0 for days where a card only had additions or only subtractions
  mutate(
    new_listings = coalesce(new_listings, 0),
    disappeared_listings = coalesce(disappeared_listings, 0),
    net_change = new_listings - disappeared_listings
  ) %>%
  arrange(date, card_full)

# Check the results
glimpse(daily_inventory_flow)
head(daily_inventory_flow %>% filter(card_full == "Elsa Enchanted")) # Example check

library(ggplot2)
library(dplyr)


selectedcard = "Elsa Spirit of Winter Enchanted"
# 1. Filter for Mufasa
mufasa_flow <- daily_inventory_flow %>%
  filter(card_full == selectedcard)

# 2. Create the Diverging Bar Plot
ggplot(mufasa_flow) +
  # New Listings (Positive bars)
  geom_col(aes(x = as.Date(date), y = new_listings, fill = "New Listings")) +
  
  # Disappeared Listings (Negative bars)
  geom_col(aes(x = as.Date(date), y = -disappeared_listings, fill = "Listings Gone")) +
  
  # Net Change (Trend line)
  geom_line(aes(x = as.Date(date), y = net_change, color = "Net Change"), linewidth = 1) +
  geom_point(aes(x = as.Date(date), y = net_change, color = "Net Change"), size = 2) +
  
  # Formatting
  theme_minimal() +
  scale_y_continuous(labels = abs) + # Keep y-axis labels positive even for negative bars
  labs(
    title = selectedcard,
    subtitle = "Daily Supply Injections vs. Sales/Delistings",
    x = "Date",
    y = "Volume of Listings",
    fill = "Activity Type",
    color = "Trend"
  ) +
  scale_fill_manual(values = c("New Listings" = "#1b9e77", "Listings Gone" = "#d95f02")) +
  scale_color_manual(values = c("Net Change" = "black")) +
  theme(legend.position = "bottom")
