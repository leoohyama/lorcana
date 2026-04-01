library(shiny)
library(tidyverse)
library(bslib)
library(DT)
library(thematic)
library(DBI)
library(RPostgres)
library(bit64) 
library(plotly) 

# ==========================================
# 0.5 LOAD STATIC CARD DICTIONARY
# ==========================================
master_dict <- read_csv("data/target_cards_with_epids2.csv", show_col_types = FALSE) %>%
  mutate(
    id = as.character(id), 
    tcgplayer_id = as.integer(tcgplayer_id), 
    cardname = paste(name, replace_na(version, ""), rarity, sep = " - "),
    folder_name = str_replace_all(set_name, "[ ']", "_")
  ) %>%
  select(id, tcgplayer_id, cardname, set_name, folder_name) %>%
  distinct(id, .keep_all = TRUE)

thematic_shiny()
addResourcePath("card_photos", "data/enchanteds/images")

# ==========================================
# 1. USER INTERFACE (UI)
# ==========================================
ui <- page_navbar(
  title = tags$span(style = "color: #18bc9c; font-weight: bold; font-size: 22px;", "Lorcana Market Float Explorer"),
  id = "main_nav",
  theme = bs_theme(version = 5, bootswatch = "darkly"),
  
  nav_spacer(),
  nav_item(actionButton("refresh_db", " Refresh Data", icon = icon("sync"), class = "btn-info btn-sm")),
  
  header = tags$head(
    tags$style(HTML("
      /* --- High Contrast Navbar --- */
      .navbar { background-color: #0f171e !important; border-bottom: 2px solid #18bc9c; }
      .navbar .nav-link { color: #ecf0f1 !important; font-size: 16px; opacity: 0.7; transition: 0.3s ease; }
      .navbar .nav-link:hover { opacity: 1; color: #18bc9c !important; }
      .navbar .nav-link.active { color: #18bc9c !important; font-weight: bold; opacity: 1; }
      .nav-underline .nav-link.active { color: #18bc9c !important; font-weight: bold; border-bottom: 3px solid #18bc9c !important; opacity: 1; }
      
      /* --- Card Widgets --- */
      .flip-card { width: 150px; height: 242px; perspective: 1000px; cursor: pointer; }
      .flip-card-inner { position: relative; width: 100%; height: 100%; transition: transform 0.6s; transform-style: preserve-3d; }
      .flip-card-inner.is-flipped { transform: rotateY(180deg); }
      .flip-card-front, .flip-card-back { position: absolute; width: 100%; height: 100%; backface-visibility: hidden; border-radius: 10px; box-shadow: 0 4px 10px rgba(0,0,0,0.6); }
      .flip-card-front { background-color: transparent; }
      .flip-card-front img { width: 100%; height: 100%; border-radius: 10px; object-fit: cover; }
      .flip-card-back { background-color: #2b3e50; color: white; transform: rotateY(180deg); border: 2px solid #18bc9c; display: flex; flex-direction: column; justify-content: center; align-items: center; padding: 10px; text-align: center; }
      .badge-custom { position: absolute; top: -10px; right: -25px; background-color: #dc3545; color: white; border-radius: 12px; padding: 4px 10px; font-weight: bold; font-size: 15px; z-index: 20; border: 2px solid #222; }
      .badge-rank { position: absolute; top: -10px; left: -15px; background-color: #f39c12; color: white; border-radius: 50%; width: 38px; height: 38px; display: flex; justify-content: center; align-items: center; font-weight: bold; font-size: 18px; z-index: 20; border: 2px solid #222; }
      
      .scrolling-wrapper { height: 850px; overflow-y: auto; overflow-x: hidden; position: relative; }
      .scrolling-wrapper::-webkit-scrollbar { width: 8px; }
      .scrolling-wrapper::-webkit-scrollbar-thumb { background: #18bc9c; border-radius: 4px; }
      
      .momentum-box { background: linear-gradient(135deg, #2b3e50, #1a252f); border-left: 5px solid #f39c12; padding: 15px; border-radius: 8px; margin-bottom: 15px; color: #ecf0f1; font-size: 15px;}
      .green-text { color: #2ecc71; font-weight: bold; }
      .red-text { color: #e74c3c; font-weight: bold; }
      .staleness-box { background-color: #2b3e50; border-left: 5px solid #18bc9c; padding: 15px; border-radius: 5px; margin-bottom: 15px; color: #ecf0f1;}
    ")),
    tags$script(HTML("document.addEventListener('DOMContentLoaded', function() { setInterval(function() { var ticker = document.getElementById('top10-ticker'); if (ticker && !ticker.matches(':hover')) { ticker.scrollTop += 1; if (ticker.scrollTop >= (ticker.scrollHeight / 2)) { ticker.scrollTop = 0; } } }, 30); });"))
  ),

  nav_panel(title = "Market Overview", value = "Market Overview",
    layout_columns(
      col_widths = c(10, 2), # TIGHTENED COLUMN WIDTH
      div(
        uiOutput("momentum_statement"),
        navset_card_underline(
          title = "Market Trends",
          nav_panel("Active Listings (Volume)", plotlyOutput("overview_plot", height = "450px")),
          nav_panel("Raw Float Value (Market Cap)", plotlyOutput("market_cap_plot", height = "450px"))
        )
      ),
      card(card_header("Top 10 Most Active Cards"), div(id = "top10-ticker", class = "scrolling-wrapper", uiOutput("top10_gallery")))
    )
  ),
  
  nav_panel(title = "Ebay Data", value = "Ebay Data",
    layout_sidebar(
      sidebar = sidebar(title = "Card Selection", uiOutput("card_selector_ui"), br(), uiOutput("sidebar_card_image")),
      uiOutput("staleness_statement"),
      layout_columns(col_widths = c(6, 6), card(card_header("Listing Volume"), plotlyOutput("volume_plot", height = "350px")), card(card_header("Listing Age"), plotlyOutput("staleness_plot", height = "350px"))),
      card(card_header("Live eBay Floor"), DTOutput("listings_table"))
    )
  ),
  
  nav_panel(title = "Pricing", value = "Pricing",
    layout_sidebar(
      sidebar = sidebar(title = "Pricing Selection", uiOutput("pricing_selector_ui"), hr(), checkboxGroupInput("show_models", "Forecasts:", choices = c("Chronos (Dashed)", "GRU (Dotted)"), selected = "Chronos (Dashed)")),
      layout_columns(col_widths = c(9, 3), card(card_header("Market History & Forecasts"), plotlyOutput("pricing_plot", height = "600px")), card(card_header("Selected Cards"), div(style = "height: 600px; overflow-y: auto; overflow-x: hidden;", uiOutput("pricing_images_ui"))))
    )
  )
)

# ==========================================
# 2. SERVER LOGIC
# ==========================================
server <- function(input, output, session) {

  get_neon_con <- function() {
    dbConnect(RPostgres::Postgres(),
      host = "ep-frosty-unit-amykrca9-pooler.c-5.us-east-1.aws.neon.tech",
      dbname = "neondb", user = "neondb_owner",
      password = Sys.getenv("NEON_PASSWORD"), port = 5432, sslmode = "require")
  }

  # --- GLOBAL DARK THEME FUNCTION ---
  my_dark_theme <- function() {
    theme_minimal() +
    theme(
      text = element_text(color = "#ecf0f1"),
      axis.text = element_text(color = "#ecf0f1", face = "bold", size = 14),
      axis.title = element_text(color = "#ecf0f1", face = "bold", size = 16),
      panel.grid.major = element_line(color = "#34495e", linewidth = 0.3),
      panel.grid.minor = element_blank(),
      plot.background = element_rect(fill = "#1a252f", color = NA),
      panel.background = element_rect(fill = "#1a252f", color = NA),
      legend.text = element_text(color = "#ecf0f1", size = 14),
      legend.title = element_blank(),
      legend.background = element_rect(fill = "transparent", color = NA)
    )
  }

  # --- 1. SUPER LEAN SUMMARY DATA ---
  summary_data <- eventReactive(input$refresh_db, ignoreNULL = FALSE, {
    withProgress(message = 'Crunching Market Summaries...', value = 0.5, {
      con <- get_neon_con()
      
      vol_hist <- dbGetQuery(con, "SELECT date_pulled, is_graded, count(*) as n FROM lorcana_active_listings GROUP BY date_pulled, is_graded")
      
      df_cap_raw <- dbGetQuery(con, "SELECT id, date_pulled FROM lorcana_active_listings WHERE is_graded IN ('No', 'false', '0')")
      latest_prices <- dbGetQuery(con, "SELECT DISTINCT ON (tcgplayer_id) tcgplayer_id, market_price, pull_date FROM justtcg_prices ORDER BY tcgplayer_id, pull_date DESC")
      past_prices <- dbGetQuery(con, "SELECT DISTINCT ON (tcgplayer_id) tcgplayer_id, market_price, pull_date FROM justtcg_prices WHERE pull_date <= CURRENT_DATE - INTERVAL '7 days' ORDER BY tcgplayer_id, pull_date DESC")
      top_10_snap <- dbGetQuery(con, sprintf("SELECT id, count(*) as total FROM lorcana_active_listings WHERE date_pulled = '%s' GROUP BY id ORDER BY total DESC LIMIT 10", max(vol_hist$date_pulled)))
      dbDisconnect(con)
      
      cap_hist <- df_cap_raw %>%
        mutate(date_pulled = as.Date(date_pulled), id = as.character(id)) %>%
        left_join(master_dict, by = "id") %>%
        left_join(latest_prices, by = "tcgplayer_id") %>%
        group_by(date_pulled) %>%
        summarise(total_cap = sum(market_price, na.rm = TRUE), .groups = 'drop')
      
      list(vol = vol_hist, cap = cap_hist, latest = latest_prices, past = past_prices, top10 = top_10_snap)
    })
  })

  # --- 2. ON-DEMAND DETAIL PULLS ---
  card_details <- reactive({
    req(input$selected_card)
    id_char <- master_dict$id[master_dict$cardname == input$selected_card][1]
    withProgress(message = "Pulling Listing Details...", {
      con <- get_neon_con()
      df <- dbGetQuery(con, sprintf("SELECT listing_title, price_val, is_graded, date_pulled, posted_date, item_id, listing_type FROM lorcana_active_listings WHERE id = '%s'", id_char))
      dbDisconnect(con)
      df %>% mutate(date_pulled = as.Date(date_pulled))
    })
  })

  pricing_details <- reactive({
    req(input$pricing_selected_cards)
    ids <- master_dict$tcgplayer_id[master_dict$cardname %in% input$pricing_selected_cards]
    id_list <- paste(ids, collapse = ",")
    id_str_list <- paste0("'", ids, "'", collapse = ",")
    
    withProgress(message = "Pulling Price History...", {
      con <- get_neon_con()
      hist <- dbGetQuery(con, sprintf("SELECT tcgplayer_id, market_price, pull_date FROM justtcg_prices WHERE tcgplayer_id IN (%s)", id_list))
      chronos <- tryCatch(dbGetQuery(con, sprintf("SELECT card_id as tcgplayer_id, target_date, pred_price, conf_low, conf_high, run_id FROM chronos_predictions WHERE card_id IN (%s)", id_str_list)), error = function(e) data.frame())
      gru <- tryCatch(dbGetQuery(con, sprintf("SELECT card_id as tcgplayer_id, target_date, pred_price, run_id FROM gru_predictions WHERE card_id IN (%s)", id_str_list)), error = function(e) data.frame())
      dbDisconnect(con)
      
      list(
        hist = hist %>% mutate(pull_date = as.Date(pull_date)) %>% left_join(master_dict, by = "tcgplayer_id"),
        chronos = if(nrow(chronos) > 0) chronos %>% mutate(target_date = as.Date(target_date), tcgplayer_id = as.integer(tcgplayer_id)) %>% left_join(master_dict, by = "tcgplayer_id") %>% group_by(tcgplayer_id) %>% filter(run_id == max(run_id)) %>% ungroup() else chronos,
        gru = if(nrow(gru) > 0) gru %>% mutate(target_date = as.Date(target_date), tcgplayer_id = as.integer(tcgplayer_id)) %>% left_join(master_dict, by = "tcgplayer_id") %>% group_by(tcgplayer_id) %>% filter(run_id == max(run_id)) %>% ungroup() else gru
      )
    })
  })

  pred_cards_available <- reactive({
    withProgress(message = 'Checking predictions...', value = 0.5, {
      con <- get_neon_con()
      c_cards <- tryCatch(dbGetQuery(con, "SELECT DISTINCT card_id FROM chronos_predictions")$card_id, error = function(e) character(0))
      g_cards <- tryCatch(dbGetQuery(con, "SELECT DISTINCT card_id FROM gru_predictions")$card_id, error = function(e) character(0))
      dbDisconnect(con)
      pool_ids <- unique(c(c_cards, g_cards))
      master_dict %>% filter(as.character(tcgplayer_id) %in% pool_ids) %>% pull(cardname)
    })
  })

  # --- MOVERS LOGIC ---
  market_movers <- reactive({
    req(summary_data())
    s <- summary_data()
    momentum <- s$latest %>% inner_join(s$past, by = "tcgplayer_id", suffix = c("_cur", "_past")) %>%
      mutate(pct = (market_price_cur - market_price_past)/market_price_past * 100, abs = market_price_cur - market_price_past) %>%
      left_join(master_dict, by = "tcgplayer_id") %>% arrange(desc(pct))
    
    if(nrow(momentum) == 0) return(NULL)
    
    top_pct_g <- momentum %>% arrange(desc(pct)) %>% slice(1) %>% mutate(Category = "Top % Gainer")
    top_pct_l <- momentum %>% arrange(pct) %>% slice(1) %>% mutate(Category = "Top % Loser")
    top_abs_g <- momentum %>% arrange(desc(abs)) %>% slice(1) %>% mutate(Category = "Top $ Gainer")
    top_abs_l <- momentum %>% arrange(abs) %>% slice(1) %>% mutate(Category = "Top $ Loser")
    
    bind_rows(top_pct_g, top_pct_l, top_abs_g, top_abs_l)
  })

  # --- TAB 1 VIZ ---
  output$overview_plot <- renderPlotly({
    req(summary_data())
    p <- summary_data()$vol %>% mutate(date_pulled = as.Date(date_pulled)) %>%
      ggplot(aes(x = date_pulled, y = n, color = is_graded)) + 
      geom_line(linewidth = 1.2) + geom_point(size = 3) + my_dark_theme() + 
      labs(y = "Active Listings", x = "Date", color = "Graded?")
      
    ggplotly(p, tooltip = "y") %>% 
      style(hovertemplate = "%{y}<extra></extra>") %>%
      layout(hovermode = "x unified", legend = list(orientation = "h", x = 0.5, y = -0.2, xanchor = "center")) %>% 
      config(displayModeBar = FALSE)
  })

  output$market_cap_plot <- renderPlotly({
    req(summary_data())
    p <- summary_data()$cap %>% mutate(date_pulled = as.Date(date_pulled)) %>%
      ggplot(aes(x = date_pulled, y = total_cap)) + 
      geom_area(fill = "#18bc9c", alpha = 0.3) + 
      geom_line(color = "#18bc9c", linewidth = 1.5) + 
      my_dark_theme() + 
      labs(y = "Raw Float Value", x = "Date")
      
    ggplotly(p, tooltip = "y") %>% 
      style(hovertemplate = "%{y:$,.2f}<extra></extra>") %>%
      layout(hovermode = "x unified", yaxis = list(tickprefix = "$")) %>% 
      config(displayModeBar = FALSE)
  })

  output$momentum_statement <- renderUI({
    info <- market_movers(); req(info)
    
    t_pct_g <- info %>% filter(Category == "Top % Gainer") %>% slice(1)
    t_pct_l <- info %>% filter(Category == "Top % Loser") %>% slice(1)
    t_abs_g <- info %>% filter(Category == "Top $ Gainer") %>% slice(1)
    t_abs_l <- info %>% filter(Category == "Top $ Loser") %>% slice(1)
    
    build_mover_card <- function(row, lab) {
      p_c <- ifelse(row$pct >= 0, "green-text", "red-text")
      tags$div(style = "display: flex; flex-direction: column; align-items: center; width: 180px; text-align: center; margin: 10px;",
               tags$div(style = "font-size: 14px; font-weight: bold; color: #18bc9c; text-transform: uppercase; margin-bottom: 5px;", lab),
               tags$img(src = paste0("card_photos/", row$folder_name, "/", row$id, ".avif"), style = "width: 100%; border-radius: 8px; border: 2px solid #2b3e50; box-shadow: 0 4px 8px rgba(0,0,0,0.5);"),
               tags$div(style = "margin-top: 8px; font-size: 14px; font-weight: bold; color: #ecf0f1; height: 35px; line-height: 1.2;", row$cardname),
               tags$div(class = p_c, style = "font-size: 16px; font-weight: bold;", sprintf("%s%s (%.1f%%)", ifelse(row$abs >= 0, "+", ""), scales::dollar(row$abs), row$pct)))
    }

    tagList(
      div(class="momentum-box", tags$strong("7-Day Market Momentum: "), sprintf("The biggest jump was %s (+%.1f%%).", t_pct_g$cardname, t_pct_g$pct)),
      tags$div(style = "display: flex; justify-content: space-around; background: #1a252f; padding: 10px; border-radius: 8px 8px 0 0;", 
               build_mover_card(t_pct_g, "Top % Gainer"), build_mover_card(t_pct_l, "Top % Loser"), 
               build_mover_card(t_abs_g, "Top $ Gainer"), build_mover_card(t_abs_l, "Top $ Loser")),
      tags$div(style = "background: #1a252f; border-radius: 0 0 8px 8px; padding-bottom: 10px; margin-bottom: 20px;", 
               plotlyOutput("movers_plot", height = "150px"))
    )
  })

  output$movers_plot <- renderPlotly({
    info <- market_movers(); req(info)
    
    con <- get_neon_con()
    id_list <- paste(unique(info$tcgplayer_id), collapse=",")
    hist_data <- dbGetQuery(con, sprintf("SELECT tcgplayer_id, pull_date, market_price FROM justtcg_prices WHERE tcgplayer_id IN (%s) AND pull_date >= CURRENT_DATE - INTERVAL '7 days'", id_list))
    dbDisconnect(con)
    
    hist_data <- hist_data %>% mutate(pull_date = as.Date(pull_date))
    
    plot_data <- info %>% select(tcgplayer_id, Category) %>%
      left_join(hist_data, by = "tcgplayer_id") %>%
      mutate(Category = factor(Category, levels = c("Top % Gainer", "Top % Loser", "Top $ Gainer", "Top $ Loser")))
    
    p <- ggplot(plot_data, aes(x = pull_date, y = market_price, color = Category)) + 
      geom_line(linewidth = 1.2) + 
      facet_wrap(~Category, scales = "free_y", nrow = 1) + 
      scale_color_manual(values = c("Top % Gainer" = "#2ecc71", "Top % Loser" = "#e74c3c", "Top $ Gainer" = "#2ecc71", "Top $ Loser" = "#e74c3c")) + 
      my_dark_theme() + 
      theme(
        axis.text.y = element_blank(), axis.title.y = element_blank(), axis.ticks.y = element_blank(),
        axis.text.x = element_text(size = 14), strip.text = element_blank(), panel.grid = element_blank()
      ) + labs(x = NULL)
      
    ggplotly(p, tooltip = "y") %>% 
      style(hovertemplate = "%{y:$.2f}<extra></extra>") %>% 
      layout(hovermode = "x unified", yaxis = list(tickprefix = "$"), showlegend = FALSE) %>% 
      config(displayModeBar = FALSE)
  })

  output$top10_gallery <- renderUI({
    req(summary_data())
    
    latest_prices <- summary_data()$latest
    top10 <- summary_data()$top10 %>% 
      left_join(master_dict, by = "id") %>%
      left_join(latest_prices, by = "tcgplayer_id") %>%
      mutate(rank = row_number())
    
    cards <- purrr::map(1:nrow(top10), function(i) {
      row <- top10[i,]
      img <- paste0("card_photos/", row$folder_name, "/", row$id, ".avif")
      formatted_price <- ifelse(is.na(row$market_price), "N/A", scales::dollar(row$market_price))
      
      tags$div(
        style = "position: relative; display: flex; flex-direction: column; align-items: center; margin-bottom: 35px; margin-top: 15px;",
        tags$div(
          class = "flip-card",
          onclick = "this.querySelector('.flip-card-inner').classList.toggle('is-flipped');",
          tags$div(
            class = "flip-card-inner",
            tags$div(
              class = "flip-card-front",
              tags$img(src = img),
              tags$div(class = "badge-rank", paste0("#", row$rank)),
              tags$div(class = "badge-custom", paste(row$total, "listings"))
            ),
            tags$div(
              class = "flip-card-back",
              tags$h5(style = "font-weight: bold; border-bottom: 1px solid #18bc9c; padding-bottom: 5px;", "Card Stats"),
              tags$div(style = "font-size: 14px; margin-top: 5px;", tags$strong("Set:"), tags$br(), row$set_name),
              tags$div(style = "font-size: 14px; margin-top: 10px;", tags$strong("Market Price:"), tags$br(), 
                       tags$span(style = "color: #f39c12; font-weight: bold; font-size: 18px;", formatted_price)),
              tags$div(style = "font-size: 16px; margin-top: 10px; color: #18bc9c; font-weight: bold;", paste("Vol:", row$total))
            )
          )
        ),
        tags$div(style = "margin-top: 15px; font-size: 15px; color: #bbb; max-width: 200px; text-align: center; font-weight: bold;", row$cardname),
        tags$div(style = "margin-top: 4px; font-size: 16px; color: #f39c12; font-weight: bold;", formatted_price)
      )
    })
    div(style="display: flex; flex-direction: column;", cards, cards)
  })

  # --- TAB 2 VIZ ---
  output$card_selector_ui <- renderUI({ selectInput("selected_card", "Select Card:", choices = sort(unique(master_dict$cardname))) })
  output$sidebar_card_image <- renderUI({ req(input$selected_card); info <- master_dict %>% filter(cardname == input$selected_card) %>% slice(1); tags$img(src=paste0("card_photos/", info$folder_name, "/", info$id, ".avif"), style="width:100%; border-radius:10px;") })
  
  output$volume_plot <- renderPlotly({ 
    req(card_details())
    p <- card_details() %>% group_by(date_pulled, is_graded) %>% summarise(n=n(), .groups='drop') %>% 
      ggplot(aes(x=date_pulled, y=n, color=is_graded)) + geom_line(linewidth=1.5) + geom_point(size=3) + my_dark_theme() + labs(y="Active Listings", x="Date", color="Graded?")
    
    ggplotly(p, tooltip = c("color", "y")) %>% layout(hovermode = "x unified", legend = list(orientation = "h", x = 0.5, y = -0.2, xanchor = "center")) %>% config(displayModeBar = FALSE)
  })
  
  output$staleness_statement <- renderUI({ req(card_details()); lat <- max(card_details()$date_pulled); curr <- card_details() %>% filter(date_pulled == lat); div(class="staleness-box", sprintf("%s has %d active listings as of %s.", tags$strong(input$selected_card), nrow(curr), format(lat, "%B %d"))) })
  
  output$staleness_plot <- renderPlotly({ 
    req(card_details(), summary_data()); lat <- max(card_details()$date_pulled)
    card_age <- card_details() %>% filter(date_pulled == lat, !is.na(posted_date)) %>% mutate(days = as.numeric(as.Date(lat) - as.Date(posted_date)), Group = "Selected Card")
    p <- ggplot(card_age, aes(x=Group, y=days)) + geom_boxplot(fill="#f39c12", alpha=0.6) + geom_jitter(width=0.1, color="#18bc9c", size=3) + my_dark_theme() + labs(y="Days Listed", x=NULL)
    ggplotly(p, tooltip = "y") %>% config(displayModeBar = FALSE)
  })
  
  output$listings_table <- renderDT({ req(card_details()); card_details() %>% filter(date_pulled == max(date_pulled)) %>% arrange(price_val) %>% select(Title = listing_title, Price = price_val, `Graded?` = is_graded, `Type` = listing_type) %>% datatable(options=list(pageLength=10, dom='tp'), rownames=FALSE) %>% formatCurrency("Price") })

  # --- TAB 3 VIZ ---
  output$pricing_selector_ui <- renderUI({ 
    all_cards <- sort(unique(master_dict$cardname))
    pool <- pred_cards_available()
    if(length(pool) == 0) pool <- all_cards
    
    set.seed(as.integer(Sys.Date()))
    start_card <- sample(pool, 1)
    
    selectizeInput("pricing_selected_cards", "Select up to 3 Cards:", choices = all_cards, selected = start_card, multiple = TRUE, options = list(maxItems = 3)) 
  })
  
  output$pricing_plot <- renderPlotly({
    req(pricing_details()); d <- pricing_details()
    latest_pull <- max(d$hist$pull_date, na.rm = TRUE)
    
    p <- ggplot() + 
      geom_vline(xintercept = as.numeric(latest_pull), color = "#cccccb", linetype = "solid", linewidth = 1) +
      geom_line(data=d$hist, aes(x=pull_date, y=market_price, color=cardname, group=cardname), linewidth=1.2)
      
    if("Chronos (Dashed)" %in% input$show_models && nrow(d$chronos) > 0) {
      p <- p + geom_line(data=d$chronos, aes(x=target_date, y=pred_price, color=cardname, group=cardname), linetype="dashed", linewidth=1) + 
               geom_ribbon(data=d$chronos, aes(x=target_date, ymin=conf_low, ymax=conf_high, fill=cardname, group=cardname), alpha=0.15)
    }
    if("GRU (Dotted)" %in% input$show_models && nrow(d$gru) > 0) {
      p <- p + geom_line(data=d$gru, aes(x=target_date, y=pred_price, color=cardname, group=cardname), linetype="dotted", linewidth=1.2)
    }
    
    ggplotly(p + my_dark_theme() + labs(x="Date", y="Market Price"), dynamicTicks = TRUE) %>% 
      style(hovertemplate = "%{y:$.2f}<extra></extra>") %>% 
      layout(
        showlegend = FALSE, 
        hovermode = "x unified", 
        plot_bgcolor = "#1a252f", 
        paper_bgcolor = "#1a252f",
        font = list(color = "#ecf0f1"),
        xaxis = list(
          rangeslider = list(visible = TRUE, thickness = 0.08, bgcolor = "#34495e"), 
          fixedrange = FALSE,
          showspikes = TRUE, spikemode = "across", spikethickness = 1, spikedash = "dot", spikecolor = "rgba(255,255,255,0.3)"
        ),
        yaxis = list(tickprefix = "$", fixedrange = TRUE) 
      ) %>% config(displayModeBar = FALSE)
  })
  
  output$pricing_images_ui <- renderUI({ 
    req(input$pricing_selected_cards)
    info <- master_dict %>% filter(cardname %in% input$pricing_selected_cards)
    ims <- purrr::map(1:nrow(info), function(i) { 
      tags$div(style="margin-bottom:25px;", 
               tags$img(src=paste0("card_photos/", info$folder_name[i], "/", info$id[i], ".avif"), style="width:180px; border-radius:10px; box-shadow: 0 4px 8px rgba(0,0,0,0.6);"), 
               div(style="font-size:13px; font-weight:bold; color:#bbb; text-align:center; margin-top:10px;", info$cardname[i])) 
    })
    div(style="display:flex; flex-direction:column; align-items:center;", ims) 
  })
}

# ==========================================
# 3. LAUNCH
# ==========================================
shinyApp(ui, server)