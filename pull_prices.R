library(tidyverse)
library(jsonlite)

# 1. Fetch all set IDs
lorcast_url <- "https://api.lorcast.com/v0/sets"
raw_data <- fromJSON(lorcast_url)

set_ids <- raw_data$results %>%
  select(id)

# 2. Loop over unique set ids to get cards
list_of_data <- list()

for(i in 1:nrow(set_ids)){
  lorcast_set_url <- paste0("https://api.lorcast.com/v0/sets/", set_ids$id[i], "/cards")
  raw_cards <- fromJSON(lorcast_set_url)
  
  # Extract just the ID and the nested price columns
  price_data <- tibble(
    id = raw_cards$id,
    price_usd = raw_cards$prices$usd,
    price_usd_foil = raw_cards$prices$usd_foil
  )
  
  list_of_data[[i]] <- price_data
}

# 3. Combine into one dataframe and add a date column for easy tracking later
final_prices <- bind_rows(list_of_data) %>%
  mutate(pull_date = Sys.Date())

# 4. Define the save directory and create it if it doesn't exist
save_dir <- "data/running_data"
if (!dir.exists(save_dir)) {
  dir.create(save_dir, recursive = TRUE)
}

# 5. Save the file with the current date in the name
file_name <- file.path(save_dir, paste0("lorcana_prices_", Sys.Date(), ".csv"))
write_csv(final_prices, file_name)

print(paste("Successfully saved price data to:", file_name))