library(tidyverse) # Handles purrr, dplyr, readr, stringr, etc.
library(httr)      # Handles API GET/POST requests
library(jsonlite)  # Handles JSON parsing
library(base64enc) # Handles the OAuth encoding
library(arrow)     # Handles high-performance Parquet saving

# ==========================================
# --- CONFIGURATION & SECRETS ---
# ==========================================
ebay_client <- trimws(Sys.getenv("EBAY_CLIENT_ID"))
ebay_secret <- trimws(Sys.getenv("EBAY_CLIENT_SECRET"))

if (ebay_client == "" || ebay_secret == "") {
  stop("Missing eBay API credentials. Check your environment variables.")
}

target_cards <- readRDS("data/enchanteds/enchanted_list.rds")
master_target_cards <- read_csv("data/target_cards_with_epids.csv", col_types = cols(epid = col_character())) %>%
  mutate(version = replace_na(version, ""))

# ==========================================
# --- STEP 1: Get eBay OAuth Token ---
# ==========================================
message("Authenticating with eBay...")
auth_string <- base64encode(charToRaw(paste0(ebay_client, ":", ebay_secret)))

token_res <- POST(
  url = "https://api.ebay.com/identity/v1/oauth2/token",
  add_headers(
    "Authorization" = paste("Basic", auth_string),
    "Content-Type" = "application/x-www-form-urlencoded"
  ),
  body = list(grant_type = "client_credentials", scope = "https://api.ebay.com/oauth/api_scope"),
  encode = "form"
)

ebay_token <- content(token_res)$access_token

if (is.null(ebay_token) || ebay_token == "") {
  stop("Could not generate eBay OAuth token. Script aborted.")
} else {
  message("Token generated successfully!")
}

# ==========================================
# --- STEP 2: The Dual-Routed eBay API Function ---
# ==========================================
get_ebay_active_listings <- function(card_name, version, rarity, token, epid_code = NA_character_) {
  
  # --- INTERNAL HELPER: Fetches and parses JSON ---
  fetch_and_parse <- function(query_params, source_name) {
    res <- GET(
      url = "https://api.ebay.com/buy/browse/v1/item_summary/search",
      query = query_params,
      add_headers("Authorization" = paste("Bearer", token), "X-EBAY-C-MARKETPLACE-ID" = "EBAY_US")
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
          seller_name   = if ("seller" %in% names(items)) items$seller$username else NA_character_,
          feedback_pct  = if ("seller" %in% names(items)) as.numeric(items$seller$feedbackPercentage) else NA_real_,
          feedback_num  = if ("seller" %in% names(items)) as.numeric(items$seller$feedbackScore) else NA_real_,
          pull_source   = source_name
        )
        
        if ("itemCreationDate" %in% names(items)) {
          parsed_items$posted_date <- substr(items$itemCreationDate, 1, 10)
        } else {
          parsed_items$posted_date <- NA_character_
        }
        
        return(parsed_items)
      }
    }
    
    # Fallback tibble
    return(tibble(
      item_id = character(), listing_title = character(), price_val = numeric(), 
      listing_type = character(), item_url = character(), is_graded = logical(), 
      posted_date = character(),
      seller_name = character(), feedback_pct = numeric(), feedback_num = numeric(),
      pull_source = character()
    ))
  }
  
  # --- ROUTE A: The Text Search (API-SIDE STRICT MATCH) ---
  api_name    <- str_replace_all(card_name, "-", " ") %>% str_squish()
  api_version <- str_replace_all(version, "-", " ") %>% str_squish()
  
  search_string <- trimws(paste0("Lorcana ", api_name, " ", api_version, " \"", rarity, "\""))
  search_string <- str_replace_all(search_string, "\\s+", " ")
  
  message("    -> Searching Text: '", search_string, "'")
  
  text_query <- list(q = search_string,  limit = 200)
  text_results <- fetch_and_parse(text_query, "Text")
  
  message("    -> Text Results Fetched: ", nrow(text_results))
  
  # 2. R-SIDE CLEAN: The "Nuclear" Match 
  if (nrow(text_results) > 0) {
    
    strict_name    <- str_replace_all(card_name, "[[:punct:]]|\\s+", "") %>% tolower()
    strict_version <- str_replace_all(version, "[[:punct:]]|\\s+", "") %>% tolower()
    strict_rarity  <- str_replace_all(rarity, "[[:punct:]]|\\s+", "") %>% tolower()
    
    text_results <- text_results %>%
      mutate(
        safe_title = str_replace_all(listing_title, "[[:punct:]]|\\s+", "") %>% tolower()
      ) %>%
      filter(
        str_detect(safe_title, strict_name) & 
        str_detect(safe_title, strict_rarity)
      )
    
    if (strict_version != "") {
      text_results <- text_results %>% filter(str_detect(safe_title, strict_version))
    }
    
    text_results <- text_results %>% select(-safe_title)
  }
  
  message("    -> Text Results Kept: ", nrow(text_results))
  
  # --- ROUTE B: The EPID Search ---
  if (!is.na(epid_code) && epid_code != "") {
    epid_query <- list(epid = epid_code, limit = 200)
    epid_results <- fetch_and_parse(epid_query, "EPID")
    message("    -> EPID Results Found: ", nrow(epid_results))
  } else {
    epid_results <- tibble() 
  }
  
  # --- ROUTE C: The Master Merge ---
  combined_results <- bind_rows(text_results, epid_results) %>%
    distinct(item_id, .keep_all = TRUE)
  
  message("    -> Total UNIQUE Listings Kept: ", nrow(combined_results), "\n")
  
  return(combined_results)
}

# ==========================================
# --- STEP 3: Execute the Pull (TESTING MODE) ---
# ==========================================
message("Starting strict eBay listings pull (TESTING FIRST 10 ONLY)...")

granular_ebay_data <- master_target_cards %>%
  mutate(
    active_listings = pmap(list(name, version, rarity, epid), ~ {
      message(paste("Fetching:", ..1, "-", ..2))
      Sys.sleep(0.5) 
      get_ebay_active_listings(..1, ..2, ..3, ebay_token, ..4)
    })
  ) %>%
  unnest(active_listings) %>%
  mutate(date_pulled = Sys.Date()) %>%
  select(
    tcgplayer_id, 
    item_id, 
    price_val, 
    listing_type,
    seller_name,
    feedback_pct,
    feedback_num,
    posted_date,
    is_graded, 
    date_pulled, 
    pull_source,
    listing_title
  )


# ==========================================
# --- STEP 4: Save the Dataset as Parquet ---
# ==========================================
dir.create("data/granular_listings", recursive = TRUE, showWarnings = FALSE)

file_name <- paste0("data/granular_listings/ebay_inventory_", Sys.Date(), ".parquet")
write_parquet(granular_ebay_data, file_name)

message("Test complete! Compressed Parquet snapshot saved.")
