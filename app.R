library(shiny)
library(tidyverse)
library(bslib)
library(DT)
library(thematic)

thematic_shiny()

# ==========================================
# 0. The Security Bypass for Images
# ==========================================
# This tells Shiny: "Whenever I ask for a URL starting with 'card_photos/', 
# look inside the 'data/enchanteds/images' folder on my hard drive."
addResourcePath("card_photos", "data/enchanteds/images")

# ==========================================
# 1. Load the Data & Setup Variables
# ==========================================
daily_dive <- read_rds("data/shiny_prep/daily_summary.rds")
latest_date <- max(daily_dive$date_pulled, na.rm = TRUE)
available_cards <- sort(unique(daily_dive$cardname))


# ==========================================
# 2. User Interface (UI)
# ==========================================
ui <- page_sidebar(
  title = "Lorcana Market Terminal",
  theme = bs_theme(preset = "darkly"), 
  
  sidebar = sidebar(
    h4("Market Filters"),
    
    selectInput(
      inputId = "selected_card",
      label = "Select a Card:",
      choices = available_cards,
      selected = available_cards[1],
      selectize = TRUE 
    ),
    
    hr(),
    
    # --- NEW: The Image Output Container ---
    uiOutput("card_image_display"),
    
    hr(),
    p(paste("Data current as of:", latest_date), style = "color: #adb5bd; font-size: 0.9em;")
  ),
  
  # Main Content Area
  card(
    card_header("1. Current Active Inventory (Select rows to chart)"),
    DTOutput("summary_table") 
  ),
  
  card(
    card_header("2. Active Float Trend"),
    plotOutput("trend_plot", height = "300px")
  )
)


# ==========================================
# 3. Server Logic
# ==========================================
server <- function(input, output, session) {
  
  # --- NEW: Render the Card Image ---
  output$card_image_display <- renderUI({
    
    # 1. Find the metadata for the currently selected card
    card_meta <- daily_dive %>%
      filter(cardname == input$selected_card) %>%
      slice(1) 
    
    req(nrow(card_meta) > 0) 
    
    # 2. Extract the raw set name and ID
    raw_set_name <- card_meta$set_name
    image_id     <- card_meta$id
    
    # 3. THE FIX: Clean the folder name right here in Shiny!
    # This automatically converts "Ursula's Return" -> "Ursula_s_Return"
    clean_folder_name <- str_replace_all(raw_set_name, "[ ']", "_")
    
    # 4. Construct the virtual URL
    img_url <- paste0("card_photos/", clean_folder_name, "/", image_id, ".avif")
    
    # Print to the console so we can verify the path is perfect
    message("Successfully built path: ", img_url)
    
    # 5. Push the HTML Image tag to the UI
    tags$img(
      src = img_url, 
      style = "width: 100%; border-radius: 10px; box-shadow: 0px 4px 8px rgba(0,0,0,0.5);"
    )
  })

  # --- 1. Prepare Current Table Data ---
  current_market_data <- reactive({
    daily_dive %>%
      filter(
        date_pulled == latest_date,
        cardname == input$selected_card
      ) %>%
      arrange(language, desc(is_graded)) %>%
      mutate(
        Condition = if_else(is_graded == TRUE, "Graded (Slab)", "Raw / Ungraded"),
        `Floor Price` = paste0("$", formatC(true_floor_price, format = "f", digits = 2)),
        `Average Ask` = paste0("$", formatC(avg_ask_price, format = "f", digits = 2)),
        Plot_Key = paste(language, Condition, sep = " - ")
      ) %>%
      select(
        Language = language,
        Condition,
        `Active Listings` = active_listings,
        `Floor Price`,
        `Average Ask`,
        Plot_Key
      )
  })
  
  # --- 2. Render Interactive Table ---
  output$summary_table <- renderDT({
    datatable(
      current_market_data() %>% select(-Plot_Key),
      selection = "multiple", 
      rownames = FALSE,
      options = list(dom = 't', ordering = FALSE)
    )
  })
  
  # --- 3. Render the Reactive Plot ---
  output$trend_plot <- renderPlot({
    selected_rows <- input$summary_table_rows_selected
    validate(need(length(selected_rows) > 0, "👆 Click on one or more rows in the table above to reveal historical trends."))
    
    selected_keys <- current_market_data()$Plot_Key[selected_rows]
    
    plot_data <- daily_dive %>%
      filter(cardname == input$selected_card) %>%
      mutate(
        Condition = if_else(is_graded == TRUE, "Graded (Slab)", "Raw / Ungraded"),
        Plot_Key = paste(language, Condition, sep = " - ")
      ) %>%
      filter(Plot_Key %in% selected_keys) 
    
    ggplot(plot_data, aes(x = date_pulled, y = active_listings, color = Plot_Key, group = Plot_Key)) +
      geom_line(linewidth = 1.2) +
      geom_point(size = 3) +
      geom_text(aes(label = active_listings), vjust = -1.5, size = 5, fontface = "bold", show.legend = FALSE) +
      scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.15))) + 
      scale_x_date(date_breaks = "1 day", date_labels = "%b %d") +
      labs(x = NULL, y = "Total Active Listings on eBay", color = "Listing Type") +
      theme_minimal(base_size = 14) +
      theme(legend.position = "bottom", panel.grid.minor = element_blank())
  })
  
}

shinyApp(ui, server)