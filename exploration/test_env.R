# test_env.R
message("🚀 Starting Environment Smoke Test on MacBook Air...")

# 1. Core Data Manipulation
message("Loading tidyverse...")
suppressPackageStartupMessages(library(tidyverse))

message("Loading lubridate...")
suppressPackageStartupMessages(library(lubridate))

# 2. Database Connections
message("Loading DBI & RPostgres...")
suppressPackageStartupMessages(library(DBI))
suppressPackageStartupMessages(library(RPostgres))

# 3. High-Performance Data
message("Loading arrow...")
suppressPackageStartupMessages(library(arrow))

message("✨ SUCCESS: All R packages loaded perfectly!")