#this file cleans up the tabular data for usage in the neural network
require(tidyverse)


#read in the data
pre_process_df_meta = readRDS(file = "data/enchanteds/enchanted_list.rds")

#first select only the relevant columns we need 
#combine pricing
#also combine inks

columns<-pre_process_df %>%
  mutate(price_list_foil = as.numeric(price_list_foil),
        price_list_nonfoil= as.numeric(price_list_foil)) %>%
  mutate(final_price = ifelse(is.na(price_list_foil), price_list_nonfoil, price_list_foil)) %>%
  select(id, name, released_at,type_clean, cost,ink, strength, willpower, lore, rarity, final_price)   %>%
  mutate(final_price = as.numeric(final_price))


#clean columns
#if strength willpower or loe is NA just make them zero

tabular_matrix_prep <- columns %>%
  mutate(
    # 1. Create the 'is_character' mask (Crucial for the NN to ignore the 0s)
    is_character = ifelse(str_detect(type_clean, "Character"), 1, 0),
    # 2. Convert NAs to 0
    across(c(strength, willpower, lore), ~replace_na(as.numeric(.), 0)),
    # 3. Log-transform the target now (Easier to do in R)
    log_price = log(final_price + 1) 
  ) 


#this is to be used for using embeddings in pytorch
#this is how we can deal with string features that have high cardinality
#and would result in too large of a matrix if one hot encoded
tabular_matrix_prep = tabular_matrix_prep %>% mutate(
  # Convert name to a factor, then to an integer
  # Python's Embedding layer expects integers from 0 to (N-1)
  character_id = as.integer(as.factor(name)) - 1
)


# Define the 6 primary inks
primary_inks <- c("Amber", "Amethyst", "Emerald", "Ruby", "Sapphire", "Steel")

# Create a column for each ink the foolproof way
clean_ink_df <- tabular_matrix_prep %>%
  # 1. Clean up the literal "NA" strings first
  mutate(across(everything(), ~na_if(as.character(.), "NA"))) %>% 
  
  # 2. Explicitly create the 6 ink columns. 
  # It takes 5 seconds to write, but it will never, ever break.
  mutate(
    ink_Amber    = as.integer(str_detect(ink, "Amber")),
    ink_Amethyst = as.integer(str_detect(ink, "Amethyst")),
    ink_Emerald  = as.integer(str_detect(ink, "Emerald")),
    ink_Ruby     = as.integer(str_detect(ink, "Ruby")),
    ink_Sapphire = as.integer(str_detect(ink, "Sapphire")),
    ink_Steel    = as.integer(str_detect(ink, "Steel"))
  ) %>%
  
  # 3. Handle cases where the original 'ink' column was NA (like for some items)
  # This ensures we get 0s instead of NAs in our new columns
  mutate(across(starts_with("ink_"), ~replace_na(., 0))) %>%
  
  # 4. Drop the original string column
  select(-ink)

#ok now we need to one hot encode ink and character
tabular_matrix_prep %>%
  count(ink)
require(fastDummies)
df_one_hot <- clean_ink_df %>%
  dummy_cols(select_columns = c("type_clean","rarity"),
             remove_selected_columns = TRUE)
  

str(df_one_hot)


# Final Cleanup for Python Matrix
final_matrix <- df_one_hot %>%
  mutate(
    # 1. Fix Numeric Types (Crucial step!)
    across(c(cost, strength, willpower, lore, final_price, 
             is_character, log_price, character_id), as.numeric),
    
    # 2. Handle the Date: Days since Lorcana's first release (Aug 18, 2023)
    release_date = as.Date(released_at),
    days_since_launch = as.numeric(release_date - as.Date("2023-08-18")),
    
    # 3. Normalize continuous variables (Z-score: mean=0, sd=1)
    across(c(cost, strength, willpower, lore, days_since_launch), 
           ~ as.vector(scale(.)))
  ) %>%
  # 4. Remove columns we no longer need
  # We keep 'id' to match with image filenames in Python later
  select(-name, -released_at, -release_date, -final_price)

# Double check the types one last time
str(final_matrix)

final_matrix_to_save <- final_matrix %>%
  # Ensure these are strictly integers for the Embedding layer
  mutate(character_id = as.integer(character_id)) %>%
  # Ensure the target is a float
  mutate(log_price = as.numeric(log_price)) %>%
  relocate(log_price, .after = days_since_launch)

# Save for Python - Parquet is best for preserving these numeric types
# install.packages("arrow")
library(arrow)
write_parquet(final_matrix_to_save, "data/tabular/ready_for_pytorch.parquet")


require(fs)
fs::dir_tree("lorcana_images/", recurse = TRUE)
