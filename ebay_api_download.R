library(tidyverse) # Handles purrr, dplyr, readr, stringr, etc.
library(httr)      # Handles API GET/POST requests
library(jsonlite)  # Handles JSON parsing
library(base64enc) # Handles the OAuth encoding


# --- CONFIGURATION ---
# Safely pull secrets from GitHub Actions environment
ebay_client <- Sys.getenv("EBAY_CLIENT_ID")
ebay_secret <- Sys.getenv("EBAY_CLIENT_SECRET")

# Safety check so the script fails cleanly if secrets are missing
if (ebay_client == "" || ebay_secret == "") {
  stop("Missing eBay API credentials. Check GitHub Secrets.")
}

# Load your target lists
target_cards <- readRDS("data/enchanteds/enchanted_list.rds")
master_target_cards <- read_csv("data/target_cards_with_epids.csv", col_types = cols(epid = col_character())) %>%
  mutate(version = replace_na(version, ""))


# --- STEP 1: Get eBay OAuth Token ---
message("Authenticating with eBay...")
auth_string <- base64encode(charToRaw(paste0(ebay_client, ":", ebay_secret)))

token_res <- POST(
  url = "https://api.ebay.com/identity/v1/oauth2/token",
  add_headers(
    "Authorization" = paste("Basic", auth_string),
    "Content-Type" = "application/x-www-form-urlencoded"
  ),
  body = list(grant_type = "client_credentials", 
              scope = "https://api.ebay.com/oauth/api_scope"),
  encode = "form"
)

ebay_token <- content(token_res)$access_token
# ==========================================
# 1. The Dual-Routed eBay API Function
# ==========================================
get_ebay_active_listings <- function(card_name, version, rarity, token, epid_code = NA_character_) {
  
  query_params <- list(limit = 200)
  
  if (!is.na(epid_code) && epid_code != "") {
    query_params$epid <- epid_code
  } else {
    query_params$q <- trimws(paste("Lorcana", card_name, rarity))
    query_params$category_ids <- "261328" 
  }
  
  res <- GET(
    url = "https://api.ebay.com/buy/browse/v1/item_summary/search",
    query = query_params,
    add_headers(
      "Authorization" = paste("Bearer", token),
      "X-EBAY-C-MARKETPLACE-ID" = "EBAY_US"
    )
  )
  
  if(status_code(res) == 200) {
    data <- fromJSON(content(res, "text", encoding = "UTF-8"))
    
    if (data$total > 0 && !is.null(data$itemSummaries)) {
      items <- data$itemSummaries
      
      parsed_items <- tibble(
        item_id       = items$itemId, 
        listing_title = items$title,
        price_val     = as.numeric(items$price$value),
        listing_type  = map_chr(items$buyingOptions, ~ paste(.x, collapse = ", ")),
        item_url      = items$itemWebUrl,
        is_graded     = str_detect(tolower(items$title), "psa|cgc|bgs|sgc|grade|graded|slab"),
        
        # --- NEW SELLER METRICS ---
        # Defensively extracted in case a listing hides the seller object
        seller_name   = if ("seller" %in% names(items)) items$seller$username else NA_character_,
        feedback_pct  = if ("seller" %in% names(items)) as.numeric(items$seller$feedbackPercentage) else NA_real_,
        feedback_num  = if ("seller" %in% names(items)) as.numeric(items$seller$feedbackScore) else NA_real_
      )
      
      if ("itemCreationDate" %in% names(items)) {
        parsed_items$posted_date <- substr(items$itemCreationDate, 1, 10)
      } else {
        parsed_items$posted_date <- NA_character_
      }
      
      return(parsed_items)
    }
  }
  
  # MUST include the new columns here to prevent unnest() crashes on zero-result cards
  return(tibble(
    item_id = character(), listing_title = character(), price_val = numeric(), 
    listing_type = character(), item_url = character(), is_graded = logical(), 
    posted_date = character(),
    seller_name = character(), feedback_pct = numeric(), feedback_num = numeric()
  ))
}



message("Starting full granular eBay listings pull (This will take a few minutes)...")

granular_ebay_data <- master_target_cards %>%
  mutate(
    active_listings = pmap(list(name, version, rarity, epid), ~ {
      message(paste("Fetching listings for:", ..1, ..2))
      Sys.sleep(0.5) 
      get_ebay_active_listings(..1, ..2, ..3, ebay_token, ..4)
    })
  ) %>%
  unnest(active_listings) %>%
  mutate(date_pulled = Sys.Date())

# Save the Dataset
dir.create("data/granular_listings", recursive = TRUE, showWarnings = FALSE)
file_name <- paste0("data/granular_listings/active_inventory_", Sys.Date(), ".csv")
write_csv(granular_ebay_data, file_name)

message("Pipeline complete! Granular snapshot saved to: ", file_name)
