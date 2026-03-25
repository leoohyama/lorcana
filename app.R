library(shiny)
library(tidyverse)
library(bslib)
library(DT)
library(thematic)
library(DBI)
library(RPostgres)

# ==========================================
# 0.5 LOAD STATIC CARD DICTIONARY (Memory Join)
# ==========================================
master_dict <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  # FORCE id to be character so it matches Neon's text type
  mutate(
    id = as.character(id), 
    version = replace_na(version, ""),
    cardname = paste(name, version, rarity, sep = " - "),
    folder_name = str_replace_all(set_name, "[ ']", "_"),
    language = "English" 
  ) %>%
  select(id, tcgplayer_id, cardname, set_name, folder_name, language) %>%
  distinct(id, .keep_all = TRUE)

# Style all ggplot2 figures to match the Darkly theme automatically
thematic_shiny()

# ==========================================
# 0. GLOBAL CONFIG & IMAGE ROUTING
# ==========================================
addResourcePath("card_photos", "data/enchanteds/images")

# ==========================================
# 1. USER INTERFACE (UI)
# ==========================================
ui <- page_navbar(
  title = "Lorcana Market Float Explorer",
  id = "main_nav",
  theme = bs_theme(version = 5, bootswatch = "darkly"),
  
  # --- INJECT CUSTOM CSS FOR 3D CARD FLIP ---
  tags$head(
    tags$style(HTML("
      /* The 3D space container */
      .flip-card { width: 140px; height: 196px; perspective: 1000px; cursor: pointer; }
      
      /* The inner wrapper that actually rotates */
      .flip-card-inner { position: relative; width: 100%; height: 100%; transition: transform 0.6s; transform-style: preserve-3d; }
      
      /* The class added by JavaScript on click */
      .flip-card-inner.is-flipped { transform: rotateY(180deg); }
      
      /* Hide the back of the card when facing forward */
      .flip-card-front, .flip-card-back { position: absolute; width: 100%; height: 100%; -webkit-backface-visibility: hidden; backface-visibility: hidden; border-radius: 10px; box-shadow: 0 4px 10px rgba(0,0,0,0.6); }
      
      /* Front Styling */
      .flip-card-front { background-color: transparent; }
      .flip-card-front img { width: 100%; height: 100%; border-radius: 10px; object-fit: cover; }
      
      /* Back Styling */
      .flip-card-back { background-color: #2b3e50; color: white; transform: rotateY(180deg); border: 2px solid #18bc9c; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 10px; text-align: center; }
      
      /* Custom Notification Badge */
      .badge-custom { position: absolute; top: -10px; right: -25px; background-color: #dc3545; color: white; border-radius: 12px; padding: 4px 10px; font-weight: bold; font-size: 13px; box-shadow: 0 2px 5px rgba(0,0,0,0.8); border: 2px solid #222; white-space: nowrap; z-index: 10; }
    "))
  ),

  sidebar = sidebar(
    title = "Controls",
    # Added the global disclaimer here!
    p(em("Tracking active float exclusively across eBay.", style = "color: #18bc9c; font-size: 12px;")),
    actionButton("refresh_db", " Refresh Data", 
                 icon = icon("sync"), 
                 class = "btn-primary w-100 mb-3"),
    hr(),
    conditionalPanel(
      condition = "input.main_nav === 'Card Details'",
      uiOutput("card_selector_ui")
    )
  ),

  nav_panel(title = "Market Overview", value = "Market Overview",
    layout_column_wrap(
      width = 1, 
      card(
        card_header("Market-Wide Daily Listing Volume"), 
        plotOutput("overview_plot", height = "300px")
      ),
      card(
        card_header("Top 10 Most Active Cards (Click to Flip!)"), 
        uiOutput("top10_gallery")
      )
    )
  ),
  
  nav_panel(title = "Card Details", value = "Card Details",
    layout_sidebar(
      sidebar = sidebar(
        position = "right",
        title = "Card Preview",
        uiOutput("card_image")
      ),
      card(
        card_header("Active Listings Trend (Float)"),
        full_screen = TRUE,
        plotOutput("volume_plot")
      ),
      card(
        card_header("Current Market Floor (Latest Pull)"), 
        DTOutput("listings_table")
      )
    )
  )
)

# ==========================================
# 2. SERVER LOGIC
# ==========================================
server <- function(input, output, session) {

  raw_data <- eventReactive(input$refresh_db, ignoreNULL = FALSE, {
    withProgress(message = 'Connecting to Neon Cloud Vault...', value = 0.5, {
      con <- dbConnect(RPostgres::Postgres(),
        host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
        dbname   = "neondb", user = "neondb_owner",
        password = Sys.getenv("NEON_PASSWORD"), port = 5432, sslmode  = "require")
      
      df <- dbGetQuery(con, "SELECT * FROM lorcana_active_listings")
      dbDisconnect(con)
      
      # The Magic Memory Join! 
      joined_df <- df %>% 
        mutate(
          date_pulled = as.Date(date_pulled),
          id = as.character(id) # Force character here too
        ) %>%
        left_join(master_dict, by = "id")
      
      # DIAGNOSTIC: Check if it worked
      if(any(is.na(joined_df$cardname))) {
        warning("JOIN ALERT: Some IDs from Neon could not be found in the CSV dictionary!")
      }
      
      return(joined_df)
    })
  })

  daily_dive <- reactive({
    req(raw_data())
    raw_data() %>%
      group_by(tcgplayer_id, cardname, set_name, folder_name, id, language, is_graded, date_pulled) %>%
      summarise(
        active_listings = n(),
        true_floor_price = quantile(price_val, probs = 0.05, na.rm = TRUE),
        avg_ask_price = mean(price_val, na.rm = TRUE),
        .groups = "drop"
      )
  })

  output$card_selector_ui <- renderUI({
    req(daily_dive())
    cards <- sort(unique(daily_dive()$cardname))
    selectInput("selected_card", "Select Card:", choices = cards)
  })

  # --- PLOT 1: Fixed Axes Colors & eBay Disclaimer ---
  output$overview_plot <- renderPlot({
    req(raw_data())
    raw_data() %>%
      count(date_pulled, is_graded) %>%
      ggplot(aes(x = date_pulled, y = n, color = is_graded)) +
      geom_line(linewidth = 1.2) +
      geom_point(size = 3) +
      theme_minimal() +
      theme(
        # Stark, bold text for maximum legibility
        text = element_text(color = "#070707"),
        axis.text = element_text(color = "#070707", face = "bold", size = 12),
        axis.title = element_text(color = "#070707", face = "bold", size = 14),
        # Make gridlines super faint and remove minor lines entirely
        panel.grid.major = element_line(color = "grey", linewidth = 0.4),
        panel.grid.minor = element_blank(),
        plot.subtitle = element_text(color = "#070707", face = "italic", size = 11)
      ) +
      scale_y_continuous(breaks = scales::pretty_breaks()) +
      labs(y = "Total Active Listings", x = "Date", color = "Graded?",
           subtitle = "Data sourced exclusively from live eBay inventory.")
  })

  # --- TOP 10 ANIMATED GALLERY ---
  output$top10_gallery <- renderUI({
    req(raw_data())
    latest_date <- max(raw_data()$date_pulled, na.rm = TRUE)
    
    # Brought set_name and language into the summary so we can print them on the back
    top_10 <- raw_data() %>%
      filter(date_pulled == latest_date) %>%
      group_by(cardname, folder_name, id, set_name, language) %>%
      summarise(total_listings = n(), .groups = "drop") %>%
      arrange(desc(total_listings)) %>%
      head(10)
    
    image_cards <- purrr::map(1:nrow(top_10), function(i) {
      row <- top_10[i, ]
      img_path <- paste0("card_photos/", row$folder_name, "/", row$id, ".avif")
      
      # The Outer Wrapper to hold the card and title
      tags$div(
        style = "display: inline-block; margin: 15px 25px; text-align: center;",
        
        # The 3D Flip Card Container (with the click-to-flip JavaScript)
        tags$div(
          class = "flip-card",
          onclick = "this.querySelector('.flip-card-inner').classList.toggle('is-flipped');",
          
          tags$div(
            class = "flip-card-inner",
            
            # FRONT OF CARD
            tags$div(
              class = "flip-card-front",
              tags$img(src = img_path),
              tags$div(class = "badge-custom", paste(row$total_listings, "listings"))
            ),
            
            # BACK OF CARD
            tags$div(
              class = "flip-card-back",
              tags$h6(style = "font-weight: bold; border-bottom: 1px solid #18bc9c; padding-bottom: 5px;", "Card Stats"),
              tags$div(style = "font-size: 12px; margin-top: 5px;", tags$strong("Set:"), tags$br(), row$set_name),
              tags$div(style = "font-size: 12px; margin-top: 10px;", tags$strong("Lang:"), tags$br(), row$language),
              tags$div(style = "font-size: 13px; margin-top: 10px; color: #18bc9c; font-weight: bold;", paste("Vol:", row$total_listings))
            )
          )
        ),
        
        # The title sits underneath the 3D space
        tags$div(
          style = "margin-top: 8px; font-size: 11px; color: #bbb; max-width: 140px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;",
          row$cardname
        )
      )
    })
    
    div(style = "display: flex; flex-wrap: wrap; justify-content: center;", image_cards)
  })

  # --- PLOT 2: Fixed Axes Colors ---
  # --- PLOT 2: Individual Volume Plot (Updated Aesthetics) ---
  output$volume_plot <- renderPlot({
    req(input$selected_card, daily_dive())
    
    daily_dive() %>%
      filter(cardname == input$selected_card) %>%
      ggplot(aes(x = date_pulled, y = active_listings, color = is_graded)) +
      geom_line(linewidth = 1.5) +
      geom_point(size = 4) +
      theme_minimal() +
      theme(
        # Matched to Plot 1: Stark, bold text for maximum legibility
        text = element_text(color = "#070707"),
        axis.text = element_text(color = "#070707", face = "bold", size = 12),
        axis.title = element_text(color = "#070707", face = "bold", size = 14),
        # Make gridlines match the grey style
        panel.grid.major = element_line(color = "grey", linewidth = 0.4),
        panel.grid.minor = element_blank(),
        plot.subtitle = element_text(color = "#070707", face = "italic", size = 11)
      ) +
      scale_y_continuous(breaks = scales::pretty_breaks()) +
      labs(title = paste("Listing Volume Trend:", input$selected_card), 
           subtitle = "Data sourced exclusively from live eBay inventory.",
           y = "Total Active Listings", x = "Date", color = "Graded?")
  })

  output$card_image <- renderUI({
    req(input$selected_card, daily_dive())
    card_info <- daily_dive() %>% filter(cardname == input$selected_card) %>% slice(1)
    img_path <- paste0("card_photos/", card_info$folder_name, "/", card_info$id, ".avif")
    tags$img(src = img_path, 
             style = "width: 100%; max-width: 320px; display: block; margin: auto; border-radius: 15px; box-shadow: 0 4px 8px rgba(0,0,0,0.5);",
             alt = "Card Image")
  })

  output$listings_table <- renderDT({
    req(input$selected_card, raw_data())
    card_data <- raw_data() %>% filter(cardname == input$selected_card)
    req(nrow(card_data) > 0)
    latest_pull <- max(card_data$date_pulled, na.rm = TRUE)
    
    card_data %>%
      filter(date_pulled == latest_pull) %>%
      arrange(price_val) %>%
      select(
        Title = listing_title,
        `Item ID` = item_id,
        Price = price_val,
        `Listing Type` = listing_type,
        `Graded?` = is_graded
      ) %>%
      datatable(
        options = list(pageLength = 10, dom = 'tp', scrollX = TRUE), 
        rownames = FALSE
      ) %>%
      formatCurrency("Price")
  })
}

# ==========================================
# 3. LAUNCH
# ==========================================
shinyApp(ui, server)