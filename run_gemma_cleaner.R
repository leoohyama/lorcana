library(tidyverse)
library(httr)
library(jsonlite)
library(DBI)
library(RPostgres)

# ==========================================
# 1. THE UPDATED JSON GEMMA FUNCTION
# ==========================================
ask_gemma_json <- function(target_card, ebay_title) {
  
  prompt_text <- paste0(
    "You are a strict data extraction assistant for Disney Lorcana TCG. ",
    "Analyze the eBay title against the target card name and output ONLY a valid JSON object. Do not include markdown formatting.\n\n",
    "RULES:\n",
    "1. 'validity': 'Match' ONLY if the title represents the Character Name and Subtitle of the target card. 'No Match' if it is a different version/subtitle, proxy, digital code, or empty box.\n",
    "2. COLLECTOR NUMBERS: The target card ends with a number (e.g., '- 213'). It is still a 'Match' if the eBay title formats it differently (e.g., '213/204') or omits the number entirely, as long as the names match.\n",
    "3. IGNORE set names, foil types, and eBay seller jargon (e.g., 'IN HAND', 'US SHIP', 'Pack Fresh') when determining validity.\n",
    "4. 'is_graded': true or false.\n",
    "5. 'grading_company': Extract company ('PSA', 'BGS', 'CGC', 'SGC', 'PCG'). Output 'NA' if ungraded.\n",
    "6. 'grade_value': Extract the numeric grade (e.g., '10', '9.5'). Output 'NA' if ungraded.\n\n",
    
    "EXAMPLES:\n",
    # Notice the Target Cards now match your new format with the numbers!
    "Target Card: Alice - Growing Girl - Enchanted - 213\n",
    "eBay Title: 2023 DISNEY LORCANA EN 2-RISE OF THE FLOODBORN #213 ALICE - GROWING GIRL PSA 10\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": true, \"grading_company\": \"PSA\", \"grade_value\": \"10\"}\n\n",
    
    "Target Card: RLS Legacy - Solar Galleon - Enchanted - 216\n",
    "eBay Title: 1x RLS Legacy - Solar Galleon - 216/204 - Enchanted - Holofoil NM-Mint Disney Lorcana\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": false, \"grading_company\": \"NA\", \"grade_value\": \"NA\"}\n\n",
    
    "Target Card: Cinderella - Ballroom Sensation - Enchanted - 205\n",
    "eBay Title: Lorcana Cinderella Ballroom Sensation Enchanted PSA 10 Gem Mint\n",
    "JSON Output: {\"validity\": \"Match\", \"is_graded\": true, \"grading_company\": \"PSA\", \"grade_value\": \"10\"}\n\n",
    
    "Target Card: Goofy - Super Goof - Enchanted - 214\n",
    "eBay Title: 2025 DISNEY LORCANA EN 10-ENCHANTED #223 GOOFY - GALUMPHING GUMSHOE PSA 10\n",
    "JSON Output: {\"validity\": \"No Match\", \"is_graded\": true, \"grading_company\": \"PSA\", \"grade_value\": \"10\"}\n\n",
    
    "Target Card: ", target_card, "\n",
    "eBay Title: ", ebay_title, "\n",
    "JSON Output:"
  )
  
  res <- tryCatch({
    POST(
      url = "http://localhost:11434/api/generate",
      body = list(
        model = "gemma4:e2b", 
        prompt = prompt_text,
        stream = FALSE,
        format = "json",
        options = list(temperature = 0.0) 
      ),
      encode = "json",
      timeout(15) 
    )
  }, error = function(e) return(NULL))
  
  fallback <- list(validity="ERROR", is_graded=NA, grading_company="ERROR", grade_value="ERROR")
  
  if (!is.null(res) && status_code(res) == 200) {
    parsed <- content(res, "parsed")
    unpacked <- tryCatch(
      fromJSON(parsed$response),
      error = function(e) return(fallback)
    )
    return(unpacked)
  } else {
    return(fallback)
  }
}

# ==========================================
# 2. LOAD DICTIONARY & FETCH DB SAMPLE
# ==========================================
print("📂 Loading local master dictionary...")
master_dict <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  mutate(
    id = as.character(id), 
    cardname = paste(name, replace_na(version, ""), rarity, collector_number, sep = " - ")
  ) %>%
  select(id, cardname) %>%
  distinct(id, .keep_all = TRUE)

print("🚀 Connecting to Neon DB...")
con <- dbConnect(
  RPostgres::Postgres(),
  host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
  dbname   = "neondb",
  user     = "neondb_owner",
  password = Sys.getenv("NEON_PASSWORD"),
  port     = 5432,
  sslmode  = "require"
)

print("📥 Fetching 40 random listings from Neon...")
query <- "
  SELECT item_id, id, listing_title 
  FROM lorcana_active_listings 
  ORDER BY RANDOM() 
  LIMIT 100
"
sample_raw <- dbGetQuery(con, query)
dbDisconnect(con)

test_sample <- sample_raw %>%
  left_join(master_dict, by = "id") %>%
  select(item_id, cardname, listing_title) %>%
  drop_na(cardname, listing_title)

# ==========================================
# 3. RUN THE TEST
# ==========================================
print(paste("🧠 Starting Gemma JSON Extraction on", nrow(test_sample), "rows..."))

verdict_list <- character(nrow(test_sample))
graded_list <- logical(nrow(test_sample))
company_list <- character(nrow(test_sample))
grade_val_list <- character(nrow(test_sample))

for (i in 1:nrow(test_sample)) {
  cat(sprintf("\rEvaluating %d of %d...", i, nrow(test_sample)))
  
  result_list <- ask_gemma_json(test_sample$cardname[i], test_sample$listing_title[i])
  
  verdict_list[i] <- result_list$validity
  graded_list[i] <- as.logical(result_list$is_graded)
  company_list[i] <- result_list$grading_company
  grade_val_list[i] <- as.character(result_list$grade_value)
}
cat("\n✅ Done!\n")

test_sample <- test_sample %>%
  mutate(
    llm_verdict = verdict_list,
    is_graded = graded_list,
    grading_company = na_if(company_list, "NA"),
    grade = na_if(grade_val_list, "NA")
  )

View(test_sample)