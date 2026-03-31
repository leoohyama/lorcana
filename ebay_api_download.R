library(tidyverse)
library(httr)
library(jsonlite)
library(base64enc)
library(DBI)
library(RPostgres)

# ==========================================
# --- CONFIGURATION & SECRETS ---
# ==========================================
ebay_client <- trimws(Sys.getenv("EBAY_CLIENT_ID"))
ebay_secret <- trimws(Sys.getenv("EBAY_CLIENT_SECRET"))
neon_pass   <- trimws(Sys.getenv("NEON_PASSWORD"))

if (ebay_client == "" || ebay_secret == "" || neon_pass == "") {
  stop("Missing credentials. Check your .Renviron file.")
}

master_target_cards <- read_csv(
  "data/target_cards_with_epids2.csv",
  col_types = cols(
    epid = col_character(),
    collector_number = col_character()
  )
) %>%
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
  body = list(
    grant_type = "client_credentials",
    scope = "https://api.ebay.com/oauth/api_scope"
  ),
  encode = "form"
)

ebay_token <- content(token_res)$access_token

# ==========================================
# --- STEP 2: The Streamlined Bouncer ---
# ==========================================
get_ebay_active_listings <- function(card_name, version, rarity, token, coll_num, epid_code = NA_character_) {
  
  template <- tibble(
    item_id = character(), listing_title = character(), price_val = numeric(),
    item_url = character(), is_graded = logical(), pull_source = character(),
    posted_date = character(), listing_type = character()
  )

  fetch_and_parse <- function(query_params, source_name) {
    query_params$filter <- "buyingOptions:{FIXED_PRICE|AUCTION}"
    
    res <- GET(
      "https://api.ebay.com/buy/browse/v1/item_summary/search",
      query = query_params,
      add_headers(
        "Authorization" = paste("Bearer", token),
        "X-EBAY-C-MARKETPLACE-ID" = "EBAY_US"
      )
    )
    
    if (status_code(res) == 200) {
      data <- fromJSON(content(res, "text", encoding = "UTF-8"))
      if (data$total > 0 && !is.null(data$itemSummaries)) {
        items <- data$itemSummaries
        
        p_fixed <- if ("price" %in% names(items)) items$price$value else rep(NA_character_, nrow(items))
        p_bid   <- if ("currentBidPrice" %in% names(items)) items$currentBidPrice$value else rep(NA_character_, nrow(items))
        p_combined <- coalesce(as.character(p_fixed), as.character(p_bid))
        
        raw_opts <- if ("buyingOptions" %in% names(items)) items$buyingOptions else NULL
        l_type <- if (!is.null(raw_opts)) map_chr(raw_opts, ~ paste(.x, collapse = ", ")) else rep("UNKNOWN", nrow(items))
        
        df <- tibble(
          item_id       = items$itemId,
          listing_title = items$title,
          price_val     = as.numeric(str_remove_all(p_combined, "[^0-9.]")),
          item_url      = items$itemWebUrl,
          is_graded     = str_detect(tolower(items$title), "psa|cgc|bgs|sgc|grade|graded|slab"),
          pull_source   = source_name,
          listing_type  = l_type,
          posted_date   = if ("itemCreationDate" %in% names(items)) substr(items$itemCreationDate, 1, 10) else NA_character_
        )
        return(df)
      }
    }
    return(template)
  }
  
  api_name <- str_replace_all(card_name, "-", " ") %>% str_squish()
  search_string <- paste0("Lorcana ", "\"", api_name, "\"") 
  
  text_results <- fetch_and_parse(list(q = search_string, limit = 200), "Text")
  epid_results <- if (!is.na(epid_code) && epid_code != "") {
    fetch_and_parse(list(epid = epid_code, limit = 200), "EPID")
  } else {
    template
  }
  
  combined_unique <- bind_rows(text_results, epid_results) %>% 
    distinct(item_id, .keep_all = TRUE)
  
  if (nrow(combined_unique) > 0) {
    # 1. Prepare Keys
    name_keys <- str_split(tolower(card_name), "\\s+|-")[[1]] %>% str_subset("...")
    rarity_synonyms <- unique(c(tolower(rarity), "enchanted", "promo", "alt art", "aa", "variant"))
    
    raw_v_keys <- str_split(tolower(str_replace_all(version, "[[:punct:]]", " ")), "\\s+")[[1]]
    version_keys <- raw_v_keys[nchar(raw_v_keys) > 3] 

    # 2. Blacklist
    blacklist <- "case|box|proxy|replica|repro|custom|fan art|digital|wafer"

    # 3. Vectorized Filter Logic
    final_df <- combined_unique %>% 
      mutate(lower_title = tolower(listing_title)) %>%
      mutate(
        pass_name  = map_lgl(lower_title, ~ all(str_detect(.x, fixed(name_keys)))),
        has_rarity = map_lgl(lower_title, ~ any(str_detect(.x, fixed(rarity_synonyms)))),
        has_num    = if (!is.na(coll_num) && coll_num != "") {
          str_detect(lower_title, paste0("\\b", coll_num, "\\b"))
        } else {
          FALSE
        },
        has_ver    = if (length(version_keys) > 0) {
          map_lgl(lower_title, ~ any(str_detect(.x, fixed(version_keys))))
        } else {
          FALSE
        }
      ) %>%
      filter(
        pass_name,
        (pull_source == "EPID") | (has_rarity & (has_num | has_ver)),
        !str_detect(lower_title, blacklist),
        !is.na(price_val) & price_val >= 20.00
      ) %>%
      select(-lower_title, -pass_name, -has_rarity, -has_num, -has_ver)
    
    cat(sprintf("\n  [%s]\n    |-- Unique: %d | Final: %d\n", card_name, nrow(combined_unique), nrow(final_df)))
    return(final_df)
  }
  return(template)
}

# ==========================================
# --- STEP 3: RUN & SCRAPE ---
# ==========================================
message("Starting streamlined market scrape...")

final_gold_scrape <- master_target_cards %>% 
  mutate(active_listings = pmap(list(name, version, rarity, epid, collector_number), ~ {
    Sys.sleep(0.4) 
    get_ebay_active_listings(..1, ..2, ..3, ebay_token, ..5, ..4) 
  })) %>%
  unnest(active_listings) %>%
  mutate(
    date_pulled = Sys.Date(),
    cardname = paste(name, version, rarity, sep = " - "),
    folder_name = str_replace_all(set_name, "[ ']", "_"),
    language = "English" 
  ) %>%
  select(
    item_id, id, price_val, is_graded, listing_type, 
    listing_title, date_pulled, posted_date, pull_source
  ) %>%
  filter(!str_detect(
    listing_title, 
    regex("D23|repack|pin|proxy|custom|oversized|coin|sleeve", ignore_case = TRUE)
  ))

# ==========================================
# --- STEP 4: PUSH TO NEON (DAILY LOGIC) ---
# ==========================================
if (nrow(final_gold_scrape) > 0) {
  message("\nConnecting to Neon...")
  con <- dbConnect(RPostgres::Postgres(),
    host = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
    dbname = "neondb", user = "neondb_owner",
    password = neon_pass, port = 5432, sslmode = "require"
  )

  # Clean out today's data to prevent duplicates on re-runs
  dbExecute(con, paste0("DELETE FROM lorcana_active_listings WHERE date_pulled = '", Sys.Date(), "';"))
  
  # Append the new data
  dbWriteTable(con, "lorcana_active_listings", final_gold_scrape, append = TRUE) 
  
  dbDisconnect(con)
  message("Daily pull complete. Added ", nrow(final_gold_scrape), " rows.")
} else {
  message("No data found to push to Neon.")
}