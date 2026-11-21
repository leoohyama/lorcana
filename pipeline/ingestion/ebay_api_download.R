library(tidyverse)
library(httr)
library(httr2)
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

# Test knobs: point at a smaller roster and/or skip the MotherDuck push
# (EBAY_PUSH=FALSE writes the result to EBAY_DRY_RUN_OUT instead).
ROSTER_PATH <- Sys.getenv("EBAY_ROSTER", "data/target_cards_with_epids2.csv")
PUSH        <- as.logical(Sys.getenv("EBAY_PUSH", "TRUE"))

PAGE_SIZE  <- 200    # Browse API maximum
MAX_ITEMS  <- 10000  # Browse API won't page past offset 10,000
MAX_ACTIVE <- 8      # concurrent requests

master_target_cards <- read_csv(
  ROSTER_PATH,
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

# The Browse search quota is 5,000 calls/day (resets 08:00 UTC). Logged before and
# after the scrape: when it runs out, every remaining call 429s and those cards
# silently come back short. The analytics call itself doesn't count against it.
# eBay's counter lags by a few minutes, so the "after" reading can look unchanged.
browse_quota_remaining <- function() {
  tryCatch({
    res <- GET(
      "https://api.ebay.com/developer/analytics/v1_beta/rate_limit/",
      query = list(api_context = "buy", api_name = "browse"),
      add_headers("Authorization" = paste("Bearer", ebay_token))
    )
    limits <- fromJSON(content(res, "text", encoding = "UTF-8"), simplifyVector = FALSE)$rateLimits
    for (api in limits) for (r in api$resources) {
      if (r$name == "buy.browse") return(r$rates[[1]]$remaining)
    }
    NA_integer_
  }, error = function(e) NA_integer_)
}
quota_before <- browse_quota_remaining()
message("Browse API quota remaining before scrape: ", quota_before)

# ==========================================
# --- STEP 2: Build the de-duplicated query set ---
# ==========================================
# Each card runs up to three searches. The Lorcana-anchored one only uses the
# character name, so every version of a character (9 Mickeys, 6 Belles, ...)
# issued the exact same multi-page search. Queries are now keyed by their exact
# parameters, fetched once, and shared by every card that uses them; each card
# still applies its own filter, so per-card output is unchanged.

# Negative exclusions added to the direct query string context
negatives <- "-case -box -proxy -replica -wafer -custom"

card_queries <- master_target_cards %>%
  mutate(
    api_name = str_squish(str_replace_all(name, "-", " ")),
    api_version = str_squish(str_replace_all(version, "-", " ")),
    # Query 1: Lorcana-anchored. eBay AND-s query words against the title, so this
    # only sees listings that literally contain "Lorcana".
    q_lorcana = paste0("Lorcana \"", api_name, "\" ", negatives),
    # Query 2: name + version phrase. Many sellers title listings "Disney ...",
    # "Ravensburger ...", "The First Chapter ...", or with no set word at all, so the
    # Lorcana-anchored query never returns them. The version phrase is specific enough
    # to stand in as the anchor and recover those. Skipped for version-less cards.
    q_namever = if_else(api_version != "", paste0("\"", api_name, "\" \"", api_version, "\" ", negatives), NA_character_),
    epid = if_else(!is.na(epid) & epid != "", epid, NA_character_)
  )

queries <- bind_rows(
  card_queries %>% distinct(q = q_lorcana) %>% transmute(key = paste0("q:", q), param = "q", value = q, source = "Text"),
  card_queries %>% filter(!is.na(q_namever)) %>% distinct(q = q_namever) %>% transmute(key = paste0("q:", q), param = "q", value = q, source = "Text"),
  card_queries %>% filter(!is.na(epid)) %>% distinct(epid) %>% transmute(key = paste0("epid:", epid), param = "epid", value = epid, source = "EPID")
) %>%
  distinct(key, .keep_all = TRUE)

message(sprintf("%d cards -> %d unique queries (was %d before de-duplication)",
                nrow(card_queries), nrow(queries),
                nrow(card_queries) + sum(!is.na(card_queries$q_namever)) + sum(!is.na(card_queries$epid))))

# ==========================================
# --- STEP 3: Fetch every page, in parallel ---
# ==========================================
template <- tibble(
  item_id = character(), listing_title = character(), price_val = numeric(),
  item_url = character(), is_graded = logical(), pull_source = character(),
  posted_date = character(), listing_type = character()
)

search_request <- function(param, value, offset) {
  request("https://api.ebay.com/buy/browse/v1/item_summary/search") %>%
    # No price floor: the historical dataset (pre 2026-07-08) was collected without
    # one (eBay ignored the old price:[20.00..] filter because priceCurrency was
    # missing), and cheap cards — Epics especially, median ~$5 — live under $20.
    # Adding a floor here creates a regime break in listing volume.
    req_url_query(
      !!param := value,
      filter = "buyingOptions:{FIXED_PRICE|AUCTION}",
      limit = PAGE_SIZE,
      offset = offset
    ) %>%
    req_headers(
      "Authorization" = paste("Bearer", ebay_token),
      "X-EBAY-C-MARKETPLACE-ID" = "EBAY_US"
    ) %>%
    req_retry(
      max_tries = 3,
      is_transient = function(resp) resp_status(resp) %in% c(429, 500, 502, 503, 504),
      backoff = function(i) 2^i
    ) %>%
    req_error(is_error = function(resp) FALSE)
}

# Runs a batch of page requests; returns one entry per request: the parsed JSON on
# success, NULL on failure. Failures are warned about (never silently dropped).
n_calls <- 0
n_failed <- 0
perform_pages <- function(pages) {
  if (nrow(pages) == 0) return(list())
  reqs <- pmap(list(pages$param, pages$value, pages$offset), search_request)
  resps <- req_perform_parallel(reqs, on_error = "continue", max_active = MAX_ACTIVE, progress = FALSE)
  n_calls <<- n_calls + length(resps)
  map2(resps, seq_along(resps), function(resp, i) {
    if (inherits(resp, "httr2_response") && resp_status(resp) == 200) {
      return(fromJSON(resp_body_string(resp)))
    }
    n_failed <<- n_failed + 1
    detail <- if (inherits(resp, "httr2_response")) {
      paste(resp_status(resp), "-", resp_body_string(resp))
    } else {
      conditionMessage(resp)
    }
    warning(sprintf("eBay API Error [%s offset %d]: %s", pages$key[i], pages$offset[i], detail))
    NULL
  })
}

parse_page <- function(data, source_name) {
  if (is.null(data) || is.null(data$total) || data$total == 0 || is.null(data$itemSummaries)) return(NULL)

  items <- data$itemSummaries

  p_fixed <- if ("price" %in% names(items)) items$price$value else rep(NA_character_, nrow(items))
  p_bid   <- if ("currentBidPrice" %in% names(items)) items$currentBidPrice$value else rep(NA_character_, nrow(items))
  p_combined <- coalesce(as.character(p_fixed), as.character(p_bid))

  raw_opts <- if ("buyingOptions" %in% names(items)) items$buyingOptions else NULL
  l_type <- if (!is.null(raw_opts)) map_chr(raw_opts, ~ paste(.x, collapse = ", ")) else rep("UNKNOWN", nrow(items))

  tibble(
    item_id       = items$itemId,
    listing_title = items$title,
    price_val     = as.numeric(str_remove_all(p_combined, "[^0-9.]")),
    item_url      = items$itemWebUrl,
    is_graded     = str_detect(tolower(items$title), "psa|cgc|bgs|sgc|grade|graded|slab"),
    pull_source   = source_name,
    listing_type  = l_type,
    posted_date   = if ("itemCreationDate" %in% names(items)) substr(items$itemCreationDate, 1, 10) else NA_character_
  )
}

message("Starting streamlined market scrape...")
t_start <- Sys.time()

# Wave 1: first page of every query. That page's `total` tells us exactly which
# further offsets exist, so all remaining pages can be requested at once in wave 2.
first_pages <- queries %>% mutate(offset = 0)
first_data <- perform_pages(first_pages)

later_pages <- first_pages %>%
  mutate(
    total = map_dbl(first_data, ~ .x$total %||% 0),
    has_next = map_lgl(first_data, ~ !is.null(.x$`next`))
  ) %>%
  filter(has_next, total > PAGE_SIZE) %>%
  mutate(offset = map(total, ~ seq(PAGE_SIZE, min(.x, MAX_ITEMS) - 1, by = PAGE_SIZE))) %>%
  select(-total, -has_next) %>%
  unnest(offset)
message(sprintf("Wave 1: %d first pages. Wave 2: %d further pages.", nrow(first_pages), nrow(later_pages)))
later_data <- perform_pages(later_pages)

# Listings per query key, in page order.
pool <- bind_rows(
  first_pages %>% mutate(data = first_data),
  later_pages %>% mutate(data = later_data)
) %>%
  arrange(key, offset) %>%
  mutate(df = map2(data, source, parse_page)) %>%
  group_by(key) %>%
  summarise(listings = list(bind_rows(template, df)), .groups = "drop")
pool <- set_names(pool$listings, pool$key)

message(sprintf("Fetched %d pages (%d failed) in %.1f min.",
                n_calls, n_failed, as.numeric(difftime(Sys.time(), t_start, units = "mins"))))

# ==========================================
# --- STEP 4: The Streamlined Bouncer (per card) ---
# ==========================================
filter_card_listings <- function(card_name, version, rarity, coll_num, q_lorcana, q_namever, epid_code) {
  from_pool <- function(key) if (is.na(key)) template else (pool[[key]] %||% template)

  combined_unique <- bind_rows(
    from_pool(paste0("q:", q_lorcana)),
    from_pool(if (is.na(q_namever)) NA_character_ else paste0("q:", q_namever)),
    from_pool(if (is.na(epid_code)) NA_character_ else paste0("epid:", epid_code))
  ) %>%
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

final_gold_scrape <- card_queries %>%
  mutate(active_listings = pmap(
    list(name, version, rarity, collector_number, q_lorcana, q_namever, epid),
    filter_card_listings
  )) %>%
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

message("\nBrowse API quota remaining after scrape: ", browse_quota_remaining())

# ==========================================
# --- STEP 5: PUSH TO MOTHERDUCK (DAILY LOGIC) ---
# ==========================================
if (!PUSH) {
  out <- Sys.getenv("EBAY_DRY_RUN_OUT", "ebay_dry_run.csv")
  write_csv(final_gold_scrape, out)
  message("EBAY_PUSH=FALSE: wrote ", nrow(final_gold_scrape), " rows to ", out, " (MotherDuck untouched).")
} else if (nrow(final_gold_scrape) > 0) {
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
