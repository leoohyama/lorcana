#here we explore the data for both justtcg and ebay

library(tidyverse)

#let's first load ebay data
#We first need to conctenate the files

ebaydata_list = list()

#get file path and list of filenames for the ebay data drop directory

ebayfile_path<-file.path("data/granular_listings/")
filenames<-list.files(ebayfile_path)
length(filenames)

for(i in 1:length(filenames)){
  ebaydata_list[[i]] = read.csv(paste0(ebayfile_path, filenames[[i]]))
}

#join ebay data together
fullset = do.call(rbind, ebaydata_list)
fullset

