# Pull card images for a set's high-rarity targets straight from Lorcast.
#
# Deliberately independent of tcgplayer_id: Lorcast publishes art and rarities
# well before TCGplayer ids exist, so the pricing-oriented filter in
# exploration/identify_enchanteds.R would drop a whole unreleased set. Images
# don't need an id, so this script pulls them as soon as they're revealed.
#
# Usage: Rscript pipeline/ingestion/pull_set_images.R [set_code]   (default: 14)

library(tidyverse)
library(jsonlite)

TARGET_RARITIES <- c("Enchanted", "Iconic", "Epic")
root_dir <- "data/enchanteds/images"

args <- commandArgs(trailingOnly = TRUE)
set_code <- if (length(args) > 0) args[1] else "14"

message(sprintf("📥 Fetching set '%s' from Lorcast...", set_code))
cards <- fromJSON(paste0("https://api.lorcast.com/v0/sets/", set_code, "/cards"))

if (length(cards) == 0 || !"rarity" %in% names(cards)) {
  stop(sprintf("No cards returned for set '%s'.", set_code), call. = FALSE)
}

targets <- cards %>%
  filter(rarity %in% TARGET_RARITIES) %>%
  mutate(
    image_url = image_uris$digital$normal,
    set_name  = set$name,
    # Same convention R/setup.R uses to build image_path, so the dashboard
    # finds these without any extra mapping.
    folder_name = str_replace_all(set_name, "[ ']", "_")
  ) %>%
  select(id, name, rarity, collector_number, set_name, folder_name, image_url) %>%
  filter(!is.na(image_url))

if (nrow(targets) == 0) {
  message("⚠️ No Enchanted/Iconic/Epic cards with images revealed yet. Nothing to do.")
  quit(save = "no", status = 0)
}

message(sprintf("🎯 %d target-rarity cards found in '%s'.", nrow(targets), targets$set_name[1]))

options(timeout = max(1000, getOption("timeout")))

n_ok <- 0; n_skip <- 0; n_fail <- 0

download_card_image <- function(url, folder_name, card_id) {
  set_path <- file.path(root_dir, folder_name)
  if (!dir.exists(set_path)) dir.create(set_path, recursive = TRUE)

  dest_file <- file.path(set_path, paste0(card_id, ".avif"))
  if (file.exists(dest_file)) {
    n_skip <<- n_skip + 1
    return(invisible(NULL))
  }

  tryCatch({
    download.file(url, dest_file, mode = "wb", quiet = TRUE)
    n_ok <<- n_ok + 1
  }, error = function(e) {
    n_fail <<- n_fail + 1
    message(sprintf("   ✗ %s: %s", card_id, conditionMessage(e)))
    # Don't leave a truncated file behind to be skipped on the next run.
    if (file.exists(dest_file)) unlink(dest_file)
  })
}

pwalk(list(targets$image_url, targets$folder_name, targets$id), download_card_image)

message(sprintf("✨ Done: %d downloaded, %d already present, %d failed.", n_ok, n_skip, n_fail))
