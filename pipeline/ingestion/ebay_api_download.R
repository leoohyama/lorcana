library(tidyverse)
library(httr)
library(jsonlite)
library(base64enc)
library(DBI)
library(duckdb)

# ==========================================
# --- CONFIGURATION & SECRETS ---
# ==========================================
ebay_client <- trimws(Sys.getenv("EBAY_CLIENT_ID"))
ebay_secret <- trimws(Sys.getenv("EBAY_CLIENT_SECRET"))
md_token    <- trimws(Sys.getenv("MOTHERDUCK_TOKEN"))

if (ebay_client == "" || ebay_secret == "" || md_token == "") {
  stop("Missing credentials. Check your .Renviron configuration.")
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
    # Price filtering pushed to API to conserve execution runtime & bandwidth.
    # priceCurrency is REQUIRED for the price bound to take effect; without it eBay
    # silently ignores the whole price filter and returns everything (incl. sub-$20).
    query_params$filter <- "buyingOptions:{FIXED_PRICE|AUCTION},price:[20.00..],priceCurrency:USD"
    query_params$limit <- 200 
    
    all_pages <- list()
    offset <- 0
    max_items <- 10000 
    
    repeat {
      query_params$offset <- offset
      
      res <- GET(
        "https://api.ebay.com/buy/browse/v1/item_summary/search",
        query = query_params,
        add_headers(
          "Authorization" = paste("Bearer", token),
          "X-EBAY-C-MARKETPLACE-ID" = "EBAY_US"
        )
      )
      
      # UNMASK REJECTIONS: Prevent silent failures by printing out errors if the API rejects the pull
      if (status_code(res) != 200) {
        warning(paste("eBay API Error:", status_code(res), "-", content(res, "text", encoding = "UTF-8")))
        break
      }
      
      data <- fromJSON(content(res, "text", encoding = "UTF-8"))
      
      if (is.null(data$total) || data$total == 0 || is.null(data$itemSummaries)) break
      
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
      
      all_pages[[length(all_pages) + 1]] <- df
      
      if (is.null(data$`next`) || (offset + 200) >= data$total || (offset + 200) >= max_items) {
        break
      }
      
      offset <- offset + 200
      Sys.sleep(0.5) 
    }
    
    if (length(all_pages) == 0) return(template)
    return(bind_rows(all_pages))
  }
  
  api_name <- str_replace_all(card_name, "-", " ") %>% str_squish()
  api_version <- str_squish(str_replace_all(version, "-", " "))

  # Negative exclusions added to the direct query string context
  negatives <- "-case -box -proxy -replica -wafer -custom"

  # Query 1: Lorcana-anchored. eBay AND-s query words against the title, so this
  # only sees listings that literally contain "Lorcana".
  q_lorcana <- paste0("Lorcana \"", api_name, "\" ", negatives)

  # Query 2: name + version phrase. Many sellers title listings "Disney ...",
  # "Ravensburger ...", "The First Chapter ...", or with no set word at all, so the
  # Lorcana-anchored query never returns them. The version phrase is specific enough
  # to stand in as the anchor and recover those. Skipped for version-less cards.
  q_namever <- if (api_version != "") {
    paste0("\"", api_name, "\" \"", api_version, "\" ", negatives)
  } else {
    NA_character_
  }

  text_results <- fetch_and_parse(list(q = q_lorcana), "Text")
  namever_results <- if (!is.na(q_namever)) {
    fetch_and_parse(list(q = q_namever), "Text")
  } else {
    template
  }
  epid_results = if (!is.na(epid_code) && epid_code != "") {
    fetch_and_parse(list(epid = epid_code), "EPID")
  } else {
    template
  }

  combined_unique <- bind_rows(text_results, namever_results, epid_results) %>%
    distinct(item_id, .keep_all = TRUE)
  
  if (nrow(combined_unique) > 0) {
    name_keys <- str_split(tolower(card_name), "\\s+|-")[[1]] %>% str_subset("...")
    rarity_synonyms <- unique(c(tolower(rarity), "enchanted", "promo", "alt art", "aa", "variant"))
    
    raw_v_keys <- str_split(tolower(str_replace_all(version, "[[:punct:]]", " ")), "\\s+")[[1]]
    version_keys <- raw_v_keys[nchar(raw_v_keys) > 3] 

    # Whole-word matching is REQUIRED here: a bare substring "pin" matches inside
    # "shipping" / "shopping", "case" inside "showcase", etc., which silently
    # discards legitimate listings (e.g. any title saying "Free Shipping").
    # NOTE: \\b word boundaries do NOT work in this machine's stringi/ICU build, so
    # we use explicit lookaround boundaries. The trailing s? tolerates plurals
    # ("pins", "cases") while still anchoring on a word edge.
    blacklist <- "(?<![a-zA-Z])(case|box|proxy|replica|repro|custom|fan art|digital|wafer|sleeve|coin|playmat|play mat|promo|set championship|legendary|artwork|keychain|pin|pinback)s?(?![a-zA-Z])"

    final_df <- combined_unique %>% 
      mutate(lower_title = tolower(listing_title)) %>%
      mutate(
        pass_name  = map_lgl(lower_title, ~ all(str_detect(.x, fixed(name_keys)))),
        has_rarity = map_lgl(lower_title, ~ any(str_detect(.x, fixed(rarity_synonyms)))),
        has_num    = if (!is.na(coll_num) && coll_num != "") {
          str_detect(lower_title, paste0("\\b", coll_num, "\\b"))
        } else {
          FALSE
        }
      ) %>%
      mutate(
        has_ver    = if (length(version_keys) > 0) {
          map_lgl(lower_title, ~ any(str_detect(.x, fixed(version_keys))))
        } else {
          FALSE
        }
      ) %>%
      filter(
        pass_name,
        # A collector number above the base set size (e.g. 207/204) uniquely
        # identifies the Enchanted/variant printing, so has_num alone is sufficient;
        # otherwise fall back to needing a rarity word AND the version phrase.
        (pull_source == "EPID") | has_num | (has_rarity & has_ver),
        !str_detect(lower_title, blacklist)
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
    # 2.5 second delay keeps requests gentle enough to preserve daily endpoint quotas
    Sys.sleep(2.5) 
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
    # Whole-word lookaround boundaries (see blacklist note): same "pin"-inside-
    # "shipping" hazard, and \\b does not work in this stringi/ICU build.
    regex("(?<![a-zA-Z])(D23|repack|pin|proxy|custom|oversized|coin|sleeve)s?(?![a-zA-Z])", ignore_case = TRUE)
  ))

# ==========================================
# --- STEP 4: PUSH TO MOTHERDUCK (DAILY LOGIC) ---
# ==========================================
if (nrow(final_gold_scrape) > 0) {
  message("\nConnecting to MotherDuck...")
  
  Sys.setenv(motherduck_token = md_token)
  
  # 1. Start with a completely blank in-memory session
  con <- dbConnect(duckdb::duckdb())

  # 2. Load the extension explicitly inside the session
  dbExecute(con, "INSTALL motherduck;")
  dbExecute(con, "LOAD motherduck;")

  # 3. Mount the actual cloud infrastructure to the session alias
  dbExecute(con, "ATTACH 'md:my_db' AS my_db;")

  # 4. Point the cursor to the catalog
  dbExecute(con, "USE my_db;")

  # SAFEGUARD: Clean out today's data only if the table actually exists
  today_str <- as.character(Sys.Date())
  if (dbExistsTable(con, "lorcana_active_listings")) {
    dbExecute(con, paste0("DELETE FROM lorcana_active_listings WHERE date_pulled = '", today_str, "';"))
  }
  
  # Append data securely into the remote production tables
  dbWriteTable(con, "lorcana_active_listings", final_gold_scrape, append = TRUE) 
  
  dbDisconnect(con, shutdown = TRUE)
  message("Daily pull complete. Added ", nrow(final_gold_scrape), " rows.")
} else {
  message("No data found to push to MotherDuck.")
}
