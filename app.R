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
  mutate(
    id = as.character(id), 
    tcgplayer_id = as.integer(tcgplayer_id), 
    version = replace_na(version, ""),
    cardname = paste(name, version, rarity, sep = " - "),
    folder_name = str_replace_all(set_name, "[ ']", "_"),
    language = "English" 
  ) %>%
  select(id, tcgplayer_id, cardname, set_name, folder_name, language) %>%
  distinct(id, .keep_all = TRUE)

thematic_shiny()

# ==========================================
# 0. GLOBAL CONFIG & IMAGE ROUTING
# ==========================================
addResourcePath("card_photos", "data/enchanteds/images")

# ==========================================
# 1. USER INTERFACE (UI)
# ==========================================
ui <- page_navbar(
  # Styled the main title to pop with the teal brand color
  title = tags$span(style = "color: #18bc9c; font-weight: bold; font-size: 22px;", "Lorcana Market Float Explorer"),
  id = "main_nav",
  theme = bs_theme(version = 5, bootswatch = "darkly"),
  
  nav_spacer(),
  nav_item(
    actionButton("refresh_db", " Refresh Data", icon = icon("sync"), class = "btn-info btn-sm")
  ),
  
  tags$head(
    tags$style(HTML("
      /* --- NEW: High Contrast Navbar & Tabs --- */
      .navbar { background-color: #0f171e !important; border-bottom: 2px solid #18bc9c; }
      .navbar .nav-link { color: #ecf0f1 !important; font-size: 16px; opacity: 0.7; transition: 0.3s ease; }
      .navbar .nav-link:hover { opacity: 1; color: #18bc9c !important; }
      .navbar .nav-link.active { color: #18bc9c !important; font-weight: bold; opacity: 1; }
      
      .nav-underline .nav-link { color: #ecf0f1 !important; font-size: 15px; opacity: 0.6; }
      .nav-underline .nav-link.active { color: #18bc9c !important; font-weight: bold; border-bottom: 3px solid #18bc9c !important; opacity: 1; }
      
      /* --- Existing Widget CSS --- */
      .flip-card { width: 140px; height: 196px; perspective: 1000px; cursor: pointer; }
      .flip-card-inner { position: relative; width: 100%; height: 100%; transition: transform 0.6s; transform-style: preserve-3d; }
      .flip-card-inner.is-flipped { transform: rotateY(180deg); }
      .flip-card-front, .flip-card-back { position: absolute; width: 100%; height: 100%; -webkit-backface-visibility: hidden; backface-visibility: hidden; border-radius: 10px; box-shadow: 0 4px 10px rgba(0,0,0,0.6); }
      .flip-card-front { background-color: transparent; }
      .flip-card-front img { width: 100%; height: 100%; border-radius: 10px; object-fit: cover; }
      .flip-card-back { background-color: #2b3e50; color: white; transform: rotateY(180deg); border: 2px solid #18bc9c; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 10px; text-align: center; }
      .badge-custom { position: absolute; top: -10px; right: -25px; background-color: #dc3545; color: white; border-radius: 12px; padding: 4px 10px; font-weight: bold; font-size: 13px; box-shadow: 0 2px 5px rgba(0,0,0,0.8); border: 2px solid #222; white-space: nowrap; z-index: 20; }
      .badge-rank { position: absolute; top: -10px; left: -15px; background-color: #f39c12; color: white; border-radius: 50%; width: 32px; height: 32px; display: flex; justify-content: center; align-items: center; font-weight: bold; font-size: 15px; box-shadow: 0 2px 5px rgba(0,0,0,0.8); border: 2px solid #222; z-index: 20; }
      .staleness-box { background-color: #2b3e50; border-left: 5px solid #18bc9c; padding: 15px; border-radius: 5px; margin-bottom: 15px; }
      
      .scrolling-wrapper { height: 850px; overflow-y: auto; overflow-x: hidden; position: relative; }
      .scrolling-wrapper::-webkit-scrollbar { width: 8px; }
      .scrolling-wrapper::-webkit-scrollbar-track { background: #2b3e50; border-radius: 4px; }
      .scrolling-wrapper::-webkit-scrollbar-thumb { background: #18bc9c; border-radius: 4px; }
      
      .momentum-box { background: linear-gradient(135deg, #2b3e50, #1a252f); border-left: 5px solid #f39c12; padding: 15px; border-radius: 8px; margin-bottom: 15px; color: #ecf0f1; font-size: 15px;}
      .green-text { color: #2ecc71; font-weight: bold; }
      .red-text { color: #e74c3c; font-weight: bold; }
    ")),
    
    tags$script(HTML("
      document.addEventListener('DOMContentLoaded', function() {
        setInterval(function() {
          var ticker = document.getElementById('top10-ticker');
          if (ticker && !ticker.matches(':hover')) {
            ticker.scrollTop += 1; 
            if (ticker.scrollTop >= (ticker.scrollHeight / 2)) {
              ticker.scrollTop = 0;
            }
          }
        }, 30); 
      });
    "))
  ),

  nav_panel(title = "Market Overview", value = "Market Overview",
    # --- NEW: Layout ratio changed to 9/3 (75% / 25%) to slim the Top 10 column ---
    layout_columns(
      col_widths = c(9, 3), 
      div(
        uiOutput("momentum_statement"),
        navset_card_underline(
          title = "Market Trends",
          nav_panel("Active Listings (Volume)", 
            plotOutput("overview_plot", height = "450px")
          ),
          nav_panel("Raw Float Value (Market Cap)", 
            plotOutput("market_cap_plot", height = "450px")
          )
        )
      ),
      card(
        card_header("Top 10 Most Active Cards"), 
        div(id = "top10-ticker", class = "scrolling-wrapper",
            uiOutput("top10_gallery")
        )
      )
    )
  ),
  
  nav_panel(title = "Ebay Data", value = "Ebay Data",
    layout_sidebar(
      sidebar = sidebar(
        title = "Card Controls",
        uiOutput("card_selector_ui"),
        br(),
        uiOutput("sidebar_card_image")
      ),
      uiOutput("staleness_statement"),
      layout_columns(
        col_widths = c(6, 6),
        card(
          card_header("Active Listings Trend (Float)"),
          plotOutput("volume_plot", height = "350px")
        ),
        card(
          card_header("Listing Age vs. Market Average"),
          plotOutput("staleness_plot", height = "350px")
        )
      ),
      card(
        card_header("Current Market Floor (Latest Pull)"), 
        DTOutput("listings_table")
      )
    )
  ),
  
  nav_panel(title = "Pricing", value = "Pricing",
    layout_sidebar(
      sidebar = sidebar(
        title = "Pricing Controls",
        uiOutput("pricing_selector_ui")
      ),
      layout_column_wrap(
        width = 1,
        card(
          card_header("Historical Market Price Comparison (JustTCG)"),
          full_screen = TRUE,
          plotOutput("pricing_plot", height = "400px")
        ),
        card(
          card_header("Selected Cards"),
          uiOutput("pricing_images_ui")
        )
      )
    )
  )
)

# ==========================================
# 2. SERVER LOGIC
# ==========================================
server <- function(input, output, session) {

  fetched_data <- eventReactive(input$refresh_db, ignoreNULL = FALSE, {
    withProgress(message = 'Connecting to Neon Cloud Vault...', value = 0.5, {
      con <- dbConnect(RPostgres::Postgres(),
        host     = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
        dbname   = "neondb", user = "neondb_owner",
        password = Sys.getenv("NEON_PASSWORD"), port = 5432, sslmode  = "require")
      
      df_ebay <- dbGetQuery(con, "SELECT * FROM lorcana_active_listings")
      df_tcg  <- dbGetQuery(con, "SELECT * FROM justtcg_prices")
      dbDisconnect(con)
      
      clean_tcg <- df_tcg %>%
        mutate(pull_date = as.Date(pull_date)) %>%
        left_join(master_dict, by = "tcgplayer_id")
      
      latest_prices <- clean_tcg %>%
        group_by(tcgplayer_id) %>%
        slice_max(order_by = pull_date, n = 1, with_ties = FALSE) %>%
        ungroup() %>%
        select(tcgplayer_id, market_price)
      
      clean_ebay <- df_ebay %>% 
        mutate(
          date_pulled = as.Date(date_pulled),
          id = as.character(id)
        ) %>%
        left_join(master_dict, by = "id") %>%
        left_join(latest_prices, by = "tcgplayer_id")
      
      list(ebay = clean_ebay, tcg = clean_tcg)
    })
  })

  raw_data <- reactive({ fetched_data()$ebay })
  tcg_history <- reactive({ fetched_data()$tcg })

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

  market_movers <- reactive({
    req(tcg_history())
    tcg <- tcg_history() %>% filter(!is.na(market_price))
    
    if(nrow(tcg) == 0) return(NULL)
    
    latest_date <- max(tcg$pull_date, na.rm = TRUE)
    target_past <- latest_date - 7
    
    past_dates <- unique(tcg$pull_date[tcg$pull_date <= target_past])
    
    if(length(past_dates) > 0) {
      past_date <- max(past_dates)
      time_label <- "7-Day"
    } else {
      past_date <- min(tcg$pull_date, na.rm = TRUE) 
      days_diff <- as.numeric(latest_date - past_date)
      if(days_diff < 2) return(NULL)
      time_label <- paste0(days_diff, "-Day")
    }
    
    latest_prices <- tcg %>% filter(pull_date == latest_date) %>% select(cardname, current = market_price)
    past_prices <- tcg %>% filter(pull_date == past_date) %>% select(cardname, past = market_price)
    
    momentum <- latest_prices %>%
      inner_join(past_prices, by = "cardname") %>%
      filter(past >= 5) %>% 
      mutate(
        pct_change = ((current - past) / past) * 100,
        abs_change = current - past
      ) %>%
      left_join(master_dict, by = "cardname") 
    
    if(nrow(momentum) == 0) return(NULL)
    
    top_pct_gainer <- momentum %>% arrange(desc(pct_change)) %>% slice(1) %>% mutate(Category = "Top % Gainer")
    top_pct_loser  <- momentum %>% arrange(pct_change) %>% slice(1) %>% mutate(Category = "Top % Loser")
    top_abs_gainer <- momentum %>% arrange(desc(abs_change)) %>% slice(1) %>% mutate(Category = "Top $ Gainer")
    top_abs_loser  <- momentum %>% arrange(abs_change) %>% slice(1) %>% mutate(Category = "Top $ Loser")
    
    selected_movers <- bind_rows(top_pct_gainer, top_pct_loser, top_abs_gainer, top_abs_loser) %>%
      mutate(Category = factor(Category, levels = c("Top % Gainer", "Top % Loser", "Top $ Gainer", "Top $ Loser")))
      
    list(data = selected_movers, time_label = time_label, past_date = past_date, latest_date = latest_date)
  })

  output$card_selector_ui <- renderUI({
    req(daily_dive())
    cards <- sort(unique(daily_dive()$cardname))
    selectInput("selected_card", "Select Card:", choices = cards)
  })

  output$pricing_selector_ui <- renderUI({
    req(tcg_history())
    cards <- sort(unique(tcg_history()$cardname[!is.na(tcg_history()$cardname)]))
    
    set.seed(as.integer(Sys.Date()))
    start_cards <- sample(cards, min(3, length(cards)))
    
    selectizeInput("pricing_selected_cards", "Select up to 3 Cards:", 
                   choices = cards, selected = start_cards, multiple = TRUE, 
                   options = list(maxItems = 3))
  })
  
  output$sidebar_card_image <- renderUI({
    req(input$selected_card, daily_dive())
    card_info <- daily_dive() %>% filter(cardname == input$selected_card) %>% slice(1)
    img_path <- paste0("card_photos/", card_info$folder_name, "/", card_info$id, ".avif")
    tags$img(src = img_path, 
             style = "width: 100%; max-width: 220px; display: block; margin: auto; border-radius: 10px; box-shadow: 0 4px 8px rgba(0,0,0,0.6);",
             alt = "Card Image")
  })

  output$momentum_statement <- renderUI({
    movers_info <- market_movers()
    
    if(is.null(movers_info)) {
      return(tags$div(class="momentum-box", "Gathering more data to calculate market momentum... Check back tomorrow!"))
    }
    
    df <- movers_info$data
    time_label <- movers_info$time_label
    
    top_pct_gainer <- df %>% filter(Category == "Top % Gainer") %>% slice(1)
    top_pct_loser  <- df %>% filter(Category == "Top % Loser") %>% slice(1)
    top_abs_gainer <- df %>% filter(Category == "Top $ Gainer") %>% slice(1)
    top_abs_loser  <- df %>% filter(Category == "Top $ Loser") %>% slice(1)
    
    pct_gainer_txt <- sprintf("<span class='green-text'>▲ %s (+%.1f%%)</span>", top_pct_gainer$cardname, top_pct_gainer$pct_change)
    pct_loser_txt  <- sprintf("<span class='red-text'>▼ %s (%.1f%%)</span>", top_pct_loser$cardname, top_pct_loser$pct_change)
    abs_gainer_txt <- sprintf("<span class='green-text'>▲ %s (+%s)</span>", top_abs_gainer$cardname, scales::dollar(top_abs_gainer$abs_change))
    abs_loser_txt  <- sprintf("<span class='red-text'>▼ %s (%s)</span>", top_abs_loser$cardname, scales::dollar(top_abs_loser$abs_change))
    
    text_block <- tags$div(
      class = "momentum-box",
      tags$div(tags$strong(paste0(time_label, " Relative Movers (%): ")), "The biggest jump was ", HTML(pct_gainer_txt), ", while ", HTML(pct_loser_txt), " saw the steepest drop."),
      tags$div(style = "margin-top: 8px;", tags$strong(paste0(time_label, " Absolute Movers ($): ")), "The highest value gained was ", HTML(abs_gainer_txt), ", and the most value lost was ", HTML(abs_loser_txt), ".")
    )
    
    build_mover_card <- function(row, title_label) {
      img_path <- paste0("card_photos/", row$folder_name, "/", row$id, ".avif")
      pct_color <- ifelse(row$pct_change >= 0, "green-text", "red-text")
      abs_color <- ifelse(row$abs_change >= 0, "green-text", "red-text")
      pct_str <- sprintf("%s%.1f%%", ifelse(row$pct_change >= 0, "+", ""), row$pct_change)
      abs_str <- sprintf("%s%s", ifelse(row$abs_change >= 0, "+", ""), scales::dollar(row$abs_change))
      
      tags$div(
        style = "display: flex; flex-direction: column; align-items: center; margin: 0 auto; width: 100%; max-width: 140px; text-align: center;",
        tags$div(style = "font-size: 12px; font-weight: bold; color: #18bc9c; margin-bottom: 5px; text-transform: uppercase;", title_label),
        tags$img(src = img_path, style = "width: 100%; border-radius: 8px; box-shadow: 0 4px 8px rgba(0,0,0,0.5); border: 2px solid #2b3e50;"),
        tags$div(style = "margin-top: 8px; font-size: 11px; font-weight: bold; line-height: 1.2; height: 30px; overflow: hidden; text-overflow: ellipsis; color: #ecf0f1;", row$cardname),
        tags$div(style = "display: flex; justify-content: center; gap: 10px; margin-top: 4px; background: #2b3e50; padding: 4px 8px; border-radius: 5px; width: 100%;",
          tags$span(class = abs_color, style = "font-size: 13px;", abs_str),
          tags$span(class = pct_color, style = "font-size: 13px;", pct_str)
        )
      )
    }
    
    gallery_block <- tags$div(
      style = "display: grid; grid-template-columns: repeat(4, 1fr); background: #1a252f; padding: 15px 10px 0px 10px; border-radius: 8px 8px 0 0; margin-bottom: 0px;",
      build_mover_card(top_pct_gainer, "Top % Gainer"),
      build_mover_card(top_pct_loser, "Top % Loser"),
      build_mover_card(top_abs_gainer, "Top $ Gainer"),
      build_mover_card(top_abs_loser, "Top $ Loser")
    )
    
    plot_block <- tags$div(
      style = "background: #1a252f; border-radius: 0 0 8px 8px; padding-bottom: 10px; margin-bottom: 20px; box-shadow: inset 0 -2px 5px rgba(0,0,0,0.5);",
      plotOutput("movers_plot", height = "180px")
    )
    
    tagList(text_block, gallery_block, plot_block)
  })

  output$movers_plot <- renderPlot({
    movers_info <- market_movers()
    req(movers_info)
    
    df_list <- lapply(1:nrow(movers_info$data), function(i) {
      row <- movers_info$data[i, ]
      tcg_history() %>%
        filter(
          cardname == row$cardname,
          pull_date >= movers_info$past_date,
          pull_date <= movers_info$latest_date
        ) %>%
        mutate(Category = row$Category)
    })
    
    plot_data <- bind_rows(df_list) %>%
      mutate(Category = factor(Category, levels = c("Top % Gainer", "Top % Loser", "Top $ Gainer", "Top $ Loser")))
    
    ggplot(plot_data, aes(x = pull_date, y = market_price, color = Category)) +
      geom_line(linewidth = 1.2) +
      geom_point(size = 3) +
      facet_wrap(~Category, scales = "free_y", nrow = 1) +
      scale_color_manual(values = c(
        "Top % Gainer" = "#2ecc71",
        "Top % Loser" = "#e74c3c",
        "Top $ Gainer" = "#2ecc71",
        "Top $ Loser" = "#e74c3c"
      )) +
      theme_minimal() +
      theme(
        text = element_text(color = "#ecf0f1"),
        axis.text.y = element_text(color = "#ecf0f1", face = "bold", size = 10),
        axis.text.x = element_text(color = "#ecf0f1", size = 9, angle = 45, hjust = 1),
        axis.title = element_blank(),
        strip.text = element_blank(), 
        panel.grid.major = element_line(color = "#34495e", linewidth = 0.4),
        panel.grid.minor = element_blank(),
        legend.position = "none",
        plot.background = element_rect(fill = "transparent", color = NA),
        panel.background = element_rect(fill = "transparent", color = NA),
        plot.margin = margin(t = 5, r = 10, b = 10, l = 10)
      ) +
      scale_y_continuous(labels = scales::dollar_format())
  })

  output$overview_plot <- renderPlot({
    req(raw_data())
    raw_data() %>%
      count(date_pulled, is_graded) %>%
      ggplot(aes(x = date_pulled, y = n, color = is_graded)) +
      geom_line(linewidth = 1.2) +
      geom_point(size = 3) +
      theme_minimal() +
      theme(
        text = element_text(color = "#ecf0f1"),
        axis.text = element_text(color = "#ecf0f1", face = "bold", size = 12),
        axis.title = element_text(color = "#ecf0f1", face = "bold", size = 14),
        panel.grid.major = element_line(color = "#34495e", linewidth = 0.4),
        panel.grid.minor = element_blank(),
        plot.subtitle = element_text(color = "#bdc3c7", face = "italic", size = 11),
        legend.position = "bottom",
        legend.text = element_text(color = "#ecf0f1"),
        plot.background = element_rect(fill = "transparent", color = NA),
        panel.background = element_rect(fill = "transparent", color = NA)
      ) +
      scale_y_continuous(breaks = scales::pretty_breaks()) +
      labs(y = "Total Active Listings", x = "Date", color = "Graded?",
           subtitle = "Data sourced exclusively from live eBay inventory.")
  })

  output$market_cap_plot <- renderPlot({
    req(raw_data())
    
    cap_summary <- raw_data() %>%
      filter(is_graded == FALSE | is_graded == "No" | is_graded == "false" | is_graded == 0) %>%
      group_by(date_pulled) %>%
      summarise(total_cap = sum(market_price, na.rm = TRUE), .groups = "drop")
      
    ggplot(cap_summary, aes(x = date_pulled, y = total_cap)) +
      geom_area(fill = "#18bc9c", alpha = 0.3) +
      geom_line(color = "#18bc9c", linewidth = 1.5) +
      geom_point(color = "#18bc9c", size = 4) +
      theme_minimal() +
      theme(
        text = element_text(color = "#ecf0f1"),
        axis.text = element_text(color = "#ecf0f1", face = "bold", size = 12),
        axis.title = element_text(color = "#ecf0f1", face = "bold", size = 14),
        panel.grid.major = element_line(color = "#34495e", linewidth = 0.4),
        panel.grid.minor = element_blank(),
        plot.subtitle = element_text(color = "#bdc3c7", face = "italic", size = 11),
        plot.background = element_rect(fill = "transparent", color = NA),
        panel.background = element_rect(fill = "transparent", color = NA)
      ) +
      scale_y_continuous(labels = scales::dollar_format(), breaks = scales::pretty_breaks()) +
      labs(y = "Total Value of Ungraded Float", x = "Date",
           subtitle = "Calculated by multiplying active ungraded eBay listings by current JustTCG prices.")
  })

  output$top10_gallery <- renderUI({
    req(raw_data())
    latest_date <- max(raw_data()$date_pulled, na.rm = TRUE)
    
    top_10 <- raw_data() %>%
      filter(date_pulled == latest_date) %>%
      group_by(cardname, folder_name, id, set_name, language, market_price) %>%
      summarise(total_listings = n(), .groups = "drop") %>%
      arrange(desc(total_listings)) %>%
      head(10) %>%
      mutate(rank = row_number()) 
    
    image_cards <- purrr::map(1:nrow(top_10), function(i) {
      row <- top_10[i, ]
      img_path <- paste0("card_photos/", row$folder_name, "/", row$id, ".avif")
      formatted_price <- ifelse(is.na(row$market_price), "N/A", scales::dollar(row$market_price))
      
      tags$div(
        style = "position: relative; display: flex; flex-direction: column; align-items: center; margin-bottom: 45px; margin-top: 15px;",
        tags$div(
          class = "flip-card",
          onclick = "this.querySelector('.flip-card-inner').classList.toggle('is-flipped');",
          tags$div(
            class = "flip-card-inner",
            tags$div(
              class = "flip-card-front",
              tags$img(src = img_path),
              tags$div(class = "badge-rank", paste0("#", row$rank)),
              tags$div(class = "badge-custom", paste(row$total_listings, "listings"))
            ),
            tags$div(
              class = "flip-card-back",
              tags$h6(style = "font-weight: bold; border-bottom: 1px solid #18bc9c; padding-bottom: 5px;", "Card Stats"),
              tags$div(style = "font-size: 13px; margin-top: 5px;", tags$strong("Set:"), tags$br(), row$set_name),
              tags$div(style = "font-size: 13px; margin-top: 10px;", tags$strong("Market Price:"), tags$br(), 
                       tags$span(style = "color: #f39c12; font-weight: bold; font-size: 15px;", formatted_price)),
              tags$div(style = "font-size: 14px; margin-top: 10px; color: #18bc9c; font-weight: bold;", paste("Vol:", row$total_listings))
            )
          )
        ),
        tags$div(style = "margin-top: 15px; font-size: 14px; color: #bbb; max-width: 220px; text-align: center; font-weight: bold;", row$cardname),
        tags$div(style = "margin-top: 4px; font-size: 15px; color: #f39c12; font-weight: bold;", formatted_price)
      )
    })
    
    looping_cards <- c(image_cards, image_cards)
    
    div(style = "display: flex; flex-direction: column; align-items: center;", looping_cards)
  })

  output$staleness_statement <- renderUI({
    req(input$selected_card, raw_data())
    
    card_data <- raw_data() %>% filter(cardname == input$selected_card)
    latest_pull <- max(card_data$date_pulled, na.rm = TRUE)
    
    current_listings <- card_data %>%
      filter(date_pulled == latest_pull, !is.na(posted_date)) %>%
      mutate(days_active = as.numeric(as.Date(latest_pull) - as.Date(posted_date)))
    
    if(nrow(current_listings) == 0) {
      return(tags$div(class = "staleness-box", "No active listings found to calculate age."))
    }
    
    n_list <- nrow(current_listings)
    med_days <- round(median(current_listings$days_active, na.rm = TRUE))
    min_days <- round(min(current_listings$days_active, na.rm = TRUE))
    max_days <- round(max(current_listings$days_active, na.rm = TRUE))
    
    txt <- sprintf(
      "%s has %d active listings as of %s. Of these listings, the median number of days they have been listed for is %d days, with a minimum of %d days and a maximum of %d days.",
      tags$strong(input$selected_card), n_list, format(latest_pull, "%B %d, %Y"),
      med_days, min_days, max_days
    )
    
    tags$div(class = "staleness-box", HTML(txt))
  })

  output$volume_plot <- renderPlot({
    req(input$selected_card, daily_dive())
    daily_dive() %>%
      filter(cardname == input$selected_card) %>%
      ggplot(aes(x = date_pulled, y = active_listings, color = is_graded)) +
      geom_line(linewidth = 1.5) +
      geom_point(size = 4) +
      theme_minimal() +
      theme(
        text = element_text(color = "#ecf0f1"),
        axis.text = element_text(color = "#ecf0f1", face = "bold", size = 12),
        axis.title = element_text(color = "#ecf0f1", face = "bold", size = 14),
        panel.grid.major = element_line(color = "#34495e", linewidth = 0.4),
        panel.grid.minor = element_blank(),
        plot.subtitle = element_text(color = "#bdc3c7", face = "italic", size = 11),
        plot.background = element_rect(fill = "transparent", color = NA),
        panel.background = element_rect(fill = "transparent", color = NA),
        legend.text = element_text(color = "#ecf0f1")
      ) +
      scale_y_continuous(breaks = scales::pretty_breaks()) +
      labs(title = "Listing Volume Trend", subtitle = "Data sourced exclusively from eBay.",
           y = "Active Listings", x = "Date", color = "Graded?")
  })

  output$staleness_plot <- renderPlot({
    req(input$selected_card, raw_data())
    latest_pull <- max(raw_data()$date_pulled, na.rm = TRUE)
    
    market_data <- raw_data() %>%
      filter(date_pulled == latest_pull, !is.na(posted_date)) %>%
      mutate(
        days_active = as.numeric(as.Date(latest_pull) - as.Date(posted_date)),
        Group = ifelse(cardname == input$selected_card, "Selected Card", "Rest of Market")
      )
    
    req(nrow(market_data) > 0)
    
    ggplot(market_data, aes(x = Group, y = days_active, fill = Group)) +
      geom_boxplot(alpha = 0.6, color = "#bdc3c7", outlier.alpha = 0.3) +
      geom_jitter(data = filter(market_data, Group == "Selected Card"), 
                  width = 0.15, size = 3, color = "#18bc9c", alpha = 0.9) +
      scale_fill_manual(values = c("Rest of Market" = "#34495e", "Selected Card" = "#f39c12")) +
      theme_minimal() +
      theme(
        text = element_text(color = "#ecf0f1"),
        axis.text = element_text(color = "#ecf0f1", face = "bold", size = 12),
        axis.title = element_text(color = "#ecf0f1", face = "bold", size = 14),
        panel.grid.major.y = element_line(color = "#34495e", linewidth = 0.4),
        panel.grid.major.x = element_blank(),
        panel.grid.minor = element_blank(),
        legend.position = "none",
        plot.background = element_rect(fill = "transparent", color = NA),
        panel.background = element_rect(fill = "transparent", color = NA)
      ) +
      labs(title = "Age Distribution vs. Market", y = "Days Listed", x = NULL)
  })

  output$listings_table <- renderDT({
    req(input$selected_card, raw_data())
    card_data <- raw_data() %>% filter(cardname == input$selected_card)
    req(nrow(card_data) > 0)
    latest_pull <- max(card_data$date_pulled, na.rm = TRUE)
    
    card_data %>%
      filter(date_pulled == latest_pull) %>%
      arrange(price_val) %>%
      select(Title = listing_title, `Item ID` = item_id, Price = price_val, `Listing Type` = listing_type, `Graded?` = is_graded) %>%
      datatable(options = list(pageLength = 10, dom = 'tp', scrollX = TRUE), rownames = FALSE) %>%
      formatCurrency("Price")
  })

  output$pricing_plot <- renderPlot({
    req(input$pricing_selected_cards, tcg_history())
    
    tcg_history() %>%
      filter(cardname %in% input$pricing_selected_cards) %>%
      ggplot(aes(x = pull_date, y = market_price, color = cardname)) +
      geom_line(linewidth = 1.5) +
      geom_point(size = 4) +
      theme_minimal() +
      theme(
        text = element_text(color = "#ecf0f1"),
        axis.text = element_text(color = "#ecf0f1", face = "bold", size = 12),
        axis.title = element_text(color = "#ecf0f1", face = "bold", size = 14),
        panel.grid.major = element_line(color = "#34495e", linewidth = 0.4),
        panel.grid.minor = element_blank(),
        plot.subtitle = element_text(color = "#bdc3c7", face = "italic", size = 11),
        legend.position = "bottom",
        legend.title = element_blank(),
        legend.text = element_text(size = 11, face = "bold", color = "#ecf0f1"),
        plot.background = element_rect(fill = "transparent", color = NA),
        panel.background = element_rect(fill = "transparent", color = NA)
      ) +
      scale_y_continuous(labels = scales::dollar_format(), breaks = scales::pretty_breaks()) +
      labs(y = "Market Price ($)", x = "Date")
  })

  output$pricing_images_ui <- renderUI({
    req(input$pricing_selected_cards, tcg_history())
    
    selected_info <- tcg_history() %>%
      filter(cardname %in% input$pricing_selected_cards) %>%
      distinct(cardname, folder_name, id)
      
    image_cards <- purrr::map(1:nrow(selected_info), function(i) {
      row <- selected_info[i, ]
      img_path <- paste0("card_photos/", row$folder_name, "/", row$id, ".avif")
      
      tags$div(
        style = "display: inline-block; margin: 15px; text-align: center;",
        tags$img(src = img_path, style = "width: 180px; border-radius: 10px; box-shadow: 0 4px 8px rgba(0,0,0,0.5);"),
        tags$div(style = "margin-top: 10px; font-size: 13px; font-weight: bold; color: #bbb; max-width: 180px; word-wrap: break-word;", row$cardname)
      )
    })
    
    div(style = "display: flex; justify-content: center; flex-wrap: wrap;", image_cards)
  })
}

# ==========================================
# 3. LAUNCH
# ==========================================
shinyApp(ui, server)