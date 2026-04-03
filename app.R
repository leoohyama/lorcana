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
      .flip-card { width: 180px; height: 252px; perspective: 1000px; cursor: pointer; }
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
      col_widths = c(10, 2), 
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
      sidebar = sidebar(
        title = "Pricing Selection", 
        uiOutput("pricing_selector_ui"), 
        hr(), 
        checkboxGroupInput("show_models", "Forecasts & Models:", 
                           choices = c("Chronos Forecast", "Chronos Shadow (Backtest)", "GRU Forecast", "GRU Shadow (Backtest)"), 
                           selected = c("Chronos Forecast", "Chronos Shadow (Backtest)"))
      ),
      div(
        card(card_header("Asset Profiles & Predictability"), uiOutput("pricing_images_ui")),
        card(card_header("Micro View: 30-Day History & Backtest (Auto-Scaled)"), plotlyOutput("pricing_zoom_plot", height = "450px")),
        card(
          card_header("Macro View: All-Time History & Long Term Forecast"),
          plotlyOutput("pricing_plot", height = "450px"),
          accordion(
            open = FALSE,
            accordion_panel(
              title = "Time-Series Metrics Guide", icon = icon("info-circle"),
              HTML("<div style='color: #ecf0f1; font-size: 14px;'><p><strong style='color:#18bc9c;'>Sample Entropy:</strong> Lower = Predictable trend. Higher = Erratic noise.</p><p><strong style='color:#18bc9c;'>Hurst Exponent:</strong> > 0.5 = Trending. < 0.5 = Mean-reverting. ~0.5 = Random walk.</p><p><strong style='color:#18bc9c;'>Vol (CV):</strong> Standard deviation relative to mean. Standardizes risk comparison.</p><p><strong style='color:#18bc9c;'>Skew:</strong> Positive = Prone to spikes. Negative = Prone to flash crashes.</p></div>")
            )
          )
        )
      )
    )
  )
)

# ==========================================
# 2. SERVER LOGIC
# ==========================================
server <- function(input, output, session) {

  get_neon_con <- function(retries = 3) {
    for (i in 1:retries) {
      con <- tryCatch({
        dbConnect(RPostgres::Postgres(),
          host = "ep-frosty-unit-amykrca9.c-5.us-east-1.aws.neon.tech",
          dbname = "neondb", 
          user = "neondb_owner",
          password = Sys.getenv("NEON_PASSWORD"), 
          port = 5432, 
          sslmode = "require",
          connect_timeout = 10 
        )
      }, error = function(e) {
        message(paste("Database connection attempt", i, "failed:", e$message))
        if (i < retries) Sys.sleep(1.5)
        NULL
      })
      if (!is.null(con)) return(con)
    }
    stop("Failed to connect to Neon database after multiple attempts.")
  }

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

  # --- Cleaned Tooltips ---
  clean_plotly_tooltips <- function(p_ly) {
    for (i in seq_along(p_ly$x$data)) {
      trace <- p_ly$x$data[[i]]
      if (!is.null(trace$fill) && trace$fill != "none") {
        p_ly$x$data[[i]]$hoverinfo <- "skip"
      } else {
        # Strictly applies the R-generated text and blocks JS auto-formatting
        p_ly$x$data[[i]]$hovertemplate <- "%{text}<extra></extra>"
      }
    }
    return(p_ly)
  }

  force_pure_date <- function(date_col) {
    as.Date(substr(as.character(date_col), 1, 10))
  }

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
        mutate(date_pulled = force_pure_date(date_pulled), id = as.character(id)) %>%
        left_join(master_dict, by = "id") %>%
        left_join(latest_prices, by = "tcgplayer_id") %>%
        group_by(date_pulled) %>%
        summarise(total_cap = sum(market_price, na.rm = TRUE), .groups = 'drop')
      
      list(vol = vol_hist, cap = cap_hist, latest = latest_prices, past = past_prices, top10 = top_10_snap)
    })
  })

  card_details <- reactive({
    req(input$selected_card)
    id_char <- master_dict$id[master_dict$cardname == input$selected_card][1]
    withProgress(message = "Pulling Listing Details...", {
      con <- get_neon_con()
      df <- dbGetQuery(con, sprintf("SELECT listing_title, price_val, is_graded, date_pulled, posted_date, item_id, listing_type FROM lorcana_active_listings WHERE id = '%s'", id_char))
      dbDisconnect(con)
      df %>% mutate(date_pulled = force_pure_date(date_pulled))
    })
  })

  pricing_details <- reactive({
    req(input$pricing_selected_cards)
    ids <- master_dict$tcgplayer_id[master_dict$cardname %in% input$pricing_selected_cards]
    id_list <- paste(ids, collapse = ",")
    id_str_list <- paste0("'", ids, "'", collapse = ",")
    
    withProgress(message = "Pulling Deep Forecasting Data...", {
      con <- get_neon_con()
      hist <- dbGetQuery(con, sprintf("SELECT tcgplayer_id, market_price, pull_date FROM justtcg_prices WHERE tcgplayer_id IN (%s)", id_list))
      metrics <- tryCatch(dbGetQuery(con, sprintf("SELECT * FROM card_ts_metrics WHERE tcgplayer_id IN (%s)", id_list)), error = function(e) data.frame())
      
      runs_tbl <- tryCatch(dbGetQuery(con, "SELECT run_id, run_date FROM model_runs"), error = function(e) data.frame(run_id = integer(), run_date = as.Date(character())))
      runs_tbl <- runs_tbl %>% mutate(run_date = force_pure_date(run_date))

      c_pred <- tryCatch(dbGetQuery(con, sprintf("SELECT card_id as tcgplayer_id, target_date, pred_price, conf_low, conf_high, run_id FROM chronos_predictions WHERE card_id IN (%s)", id_str_list)), error = function(e) data.frame())
      g_pred <- tryCatch(dbGetQuery(con, sprintf("SELECT card_id as tcgplayer_id, target_date, pred_price, run_id FROM gru_predictions WHERE card_id IN (%s)", id_str_list)), error = function(e) data.frame())
      dbDisconnect(con)
      
      hist <- hist %>% 
        mutate(pull_date = force_pure_date(pull_date)) %>% 
        group_by(tcgplayer_id, pull_date) %>% slice_tail(n = 1) %>% ungroup() %>% 
        left_join(master_dict, by = "tcgplayer_id")

      if(nrow(c_pred) > 0) {
        c_pred <- c_pred %>% 
          mutate(target_date = force_pure_date(target_date), tcgplayer_id = as.integer(tcgplayer_id)) %>% 
          left_join(runs_tbl, by = "run_id") %>% 
          group_by(tcgplayer_id, target_date, run_id) %>% slice_tail(n = 1) %>% ungroup() %>% 
          left_join(master_dict, by = "tcgplayer_id")
          
        max_c_run <- max(c_pred$run_id, na.rm = TRUE)
        chronos_cur <- c_pred %>% filter(run_id == max_c_run)
        chronos_shadow <- c_pred %>% filter(run_id < max_c_run)
      } else { 
        chronos_cur <- data.frame(); chronos_shadow <- data.frame() 
      }
      
      if(nrow(g_pred) > 0) {
        g_pred <- g_pred %>% 
          mutate(target_date = force_pure_date(target_date), tcgplayer_id = as.integer(tcgplayer_id)) %>% 
          left_join(runs_tbl, by = "run_id") %>% 
          group_by(tcgplayer_id, target_date, run_id) %>% slice_tail(n = 1) %>% ungroup() %>% 
          left_join(master_dict, by = "tcgplayer_id")
          
        max_g_run <- max(g_pred$run_id, na.rm = TRUE)
        gru_cur <- g_pred %>% filter(run_id == max_g_run)
        gru_shadow <- g_pred %>% filter(run_id < max_g_run)
      } else { 
        gru_cur <- data.frame(); gru_shadow <- data.frame() 
      }

      list(hist = hist, chronos = chronos_cur, chronos_shadow = chronos_shadow, gru = gru_cur, gru_shadow = gru_shadow, metrics = metrics)
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

  market_movers <- reactive({
    req(summary_data())
    s <- summary_data()
    momentum <- s$latest %>% inner_join(s$past, by = "tcgplayer_id", suffix = c("_cur", "_past")) %>% mutate(pct = (market_price_cur - market_price_past)/market_price_past * 100, abs = market_price_cur - market_price_past) %>% left_join(master_dict, by = "tcgplayer_id") %>% arrange(desc(pct))
    if(nrow(momentum) == 0) return(NULL)
    top_pct_g <- momentum %>% arrange(desc(pct)) %>% slice(1) %>% mutate(Category = "Top % Gainer")
    top_pct_l <- momentum %>% arrange(pct) %>% slice(1) %>% mutate(Category = "Top % Loser")
    top_abs_g <- momentum %>% arrange(desc(abs)) %>% slice(1) %>% mutate(Category = "Top $ Gainer")
    top_abs_l <- momentum %>% arrange(abs) %>% slice(1) %>% mutate(Category = "Top $ Loser")
    bind_rows(top_pct_g, top_pct_l, top_abs_g, top_abs_l)
  })

  output$overview_plot <- renderPlotly({
    req(summary_data())
    p <- summary_data()$vol %>% mutate(date_pulled = force_pure_date(date_pulled)) %>% ggplot(aes(x = date_pulled, y = n, color = is_graded)) + geom_line(linewidth = 1.2) + geom_point(size = 3) + my_dark_theme() + labs(y = "Active Listings", x = "Date")
    ggplotly(p, tooltip = "y") %>% style(hovertemplate = "%{y}<extra></extra>") %>% layout(hovermode = "x unified", legend = list(orientation = "h", x = 0.5, y = -0.2, xanchor = "center")) %>% config(displayModeBar = FALSE)
  })

  output$market_cap_plot <- renderPlotly({
    req(summary_data())
    p <- summary_data()$cap %>% mutate(date_pulled = force_pure_date(date_pulled)) %>% ggplot(aes(x = date_pulled, y = total_cap)) + geom_area(fill = "#18bc9c", alpha = 0.3) + geom_line(color = "#18bc9c", linewidth = 1.5) + my_dark_theme() + labs(y = "Raw Float Value", x = "Date")
    ggplotly(p, tooltip = "y") %>% style(hovertemplate = "%{y:$,.2f}<extra></extra>") %>% layout(hovermode = "x unified", yaxis = list(tickprefix = "$")) %>% config(displayModeBar = FALSE)
  })

  output$momentum_statement <- renderUI({
    info <- market_movers(); req(info)
    t_pct_g <- info %>% filter(Category == "Top % Gainer") %>% slice(1); t_pct_l <- info %>% filter(Category == "Top % Loser") %>% slice(1); t_abs_g <- info %>% filter(Category == "Top $ Gainer") %>% slice(1); t_abs_l <- info %>% filter(Category == "Top $ Loser") %>% slice(1)
    build_mover_card <- function(row, lab) {
      p_c <- ifelse(row$pct >= 0, "green-text", "red-text")
      tags$div(style = "display: flex; flex-direction: column; align-items: center; width: 180px; text-align: center; margin: 10px;", tags$div(style = "font-size: 14px; font-weight: bold; color: #18bc9c; text-transform: uppercase; margin-bottom: 5px;", lab), tags$img(src = paste0("card_photos/", row$folder_name, "/", row$id, ".avif"), style = "width: 100%; border-radius: 8px; border: 2px solid #2b3e50; box-shadow: 0 4px 8px rgba(0,0,0,0.5);"), tags$div(style = "margin-top: 8px; font-size: 14px; font-weight: bold; color: #ecf0f1; height: 35px; line-height: 1.2;", row$cardname), tags$div(class = p_c, style = "font-size: 16px; font-weight: bold;", sprintf("%s%s (%.1f%%)", ifelse(row$abs >= 0, "+", ""), scales::dollar(row$abs), row$pct)))
    }
    tagList(div(class="momentum-box", tags$strong("7-Day Market Momentum: "), sprintf("The biggest jump was %s (+%.1f%%).", t_pct_g$cardname, t_pct_g$pct)), tags$div(style = "display: flex; justify-content: space-around; background: #1a252f; padding: 10px; border-radius: 8px 8px 0 0;", build_mover_card(t_pct_g, "Top % Gainer"), build_mover_card(t_pct_l, "Top % Loser"), build_mover_card(t_abs_g, "Top $ Gainer"), build_mover_card(t_abs_l, "Top $ Loser")), tags$div(style = "background: #1a252f; border-radius: 0 0 8px 8px; padding-bottom: 10px; margin-bottom: 20px;", plotlyOutput("movers_plot", height = "150px")))
  })

  output$movers_plot <- renderPlotly({
    info <- market_movers(); req(info)
    con <- get_neon_con(); id_list <- paste(unique(info$tcgplayer_id), collapse=","); hist_data <- dbGetQuery(con, sprintf("SELECT tcgplayer_id, pull_date, market_price FROM justtcg_prices WHERE tcgplayer_id IN (%s) AND pull_date >= CURRENT_DATE - INTERVAL '7 days'", id_list)); dbDisconnect(con)
    hist_data <- hist_data %>% mutate(pull_date = force_pure_date(pull_date))
    plot_data <- info %>% select(tcgplayer_id, Category) %>% left_join(hist_data, by = "tcgplayer_id") %>% mutate(Category = factor(Category, levels = c("Top % Gainer", "Top % Loser", "Top $ Gainer", "Top $ Loser")))
    p <- ggplot(plot_data, aes(x = pull_date, y = market_price, color = Category)) + geom_line(linewidth = 1.2) + facet_wrap(~Category, scales = "free_y", nrow = 1) + scale_color_manual(values = c("Top % Gainer" = "#2ecc71", "Top % Loser" = "#e74c3c", "Top $ Gainer" = "#2ecc71", "Top $ Loser" = "#e74c3c")) + my_dark_theme() + theme(axis.text.y = element_blank(), axis.title.y = element_blank(), axis.ticks.y = element_blank(), axis.text.x = element_text(size = 14), strip.text = element_blank(), panel.grid = element_blank()) + labs(x = NULL)
    ggplotly(p, tooltip = "y") %>% style(hovertemplate = "%{y:$.2f}<extra></extra>") %>% layout(hovermode = "x unified", yaxis = list(tickprefix = "$"), showlegend = FALSE) %>% config(displayModeBar = FALSE)
  })

  output$top10_gallery <- renderUI({
    req(summary_data())
    latest_prices <- summary_data()$latest
    top10 <- summary_data()$top10 %>% left_join(master_dict, by = "id") %>% left_join(latest_prices, by = "tcgplayer_id") %>% mutate(rank = row_number())
    cards <- purrr::map(1:nrow(top10), function(i) {
      row <- top10[i,]; img <- paste0("card_photos/", row$folder_name, "/", row$id, ".avif"); formatted_price <- ifelse(is.na(row$market_price), "N/A", scales::dollar(row$market_price))
      tags$div(style = "position: relative; display: flex; flex-direction: column; align-items: center; margin-bottom: 35px; margin-top: 15px;", tags$div(class = "flip-card", onclick = "this.querySelector('.flip-card-inner').classList.toggle('is-flipped');", tags$div(class = "flip-card-inner", tags$div(class = "flip-card-front", tags$img(src = img), tags$div(class = "badge-rank", paste0("#", row$rank)), tags$div(class = "badge-custom", paste(row$total, "listings"))), tags$div(class = "flip-card-back", tags$h5(style = "font-weight: bold; border-bottom: 1px solid #18bc9c; padding-bottom: 5px;", "Card Stats"), tags$div(style = "font-size: 14px; margin-top: 5px;", tags$strong("Set:"), tags$br(), row$set_name), tags$div(style = "font-size: 14px; margin-top: 10px;", tags$strong("Market Price:"), tags$br(), tags$span(style = "color: #f39c12; font-weight: bold; font-size: 18px;", formatted_price)), tags$div(style = "font-size: 16px; margin-top: 10px; color: #18bc9c; font-weight: bold;", paste("Vol:", row$total))))), tags$div(style = "margin-top: 15px; font-size: 15px; color: #bbb; max-width: 200px; text-align: center; font-weight: bold;", row$cardname), tags$div(style = "margin-top: 4px; font-size: 16px; color: #f39c12; font-weight: bold;", formatted_price))
    })
    div(style="display: flex; flex-direction: column;", cards, cards)
  })

  output$card_selector_ui <- renderUI({ selectInput("selected_card", "Select Card:", choices = sort(unique(master_dict$cardname))) })
  output$sidebar_card_image <- renderUI({ req(input$selected_card); info <- master_dict %>% filter(cardname == input$selected_card) %>% slice(1); tags$img(src=paste0("card_photos/", info$folder_name, "/", info$id, ".avif"), style="width:100%; border-radius:10px;") })
  output$volume_plot <- renderPlotly({ req(card_details()); p <- card_details() %>% group_by(date_pulled, is_graded) %>% summarise(n=n(), .groups='drop') %>% ggplot(aes(x=date_pulled, y=n, color=is_graded)) + geom_line(linewidth=1.5) + geom_point(size=3) + my_dark_theme() + labs(y="Active Listings", x="Date", color="Graded?"); ggplotly(p, tooltip = c("color", "y")) %>% layout(hovermode = "x unified", legend = list(orientation = "h", x = 0.5, y = -0.2, xanchor = "center")) %>% config(displayModeBar = FALSE) })
  output$staleness_statement <- renderUI({ req(card_details()); lat <- max(card_details()$date_pulled); curr <- card_details() %>% filter(date_pulled == lat); div(class="staleness-box", sprintf("%s has %d active listings as of %s.", tags$strong(input$selected_card), nrow(curr), format(lat, "%B %d"))) })
  output$staleness_plot <- renderPlotly({ req(card_details(), summary_data()); lat <- max(card_details()$date_pulled); card_age <- card_details() %>% filter(date_pulled == lat, !is.na(posted_date)) %>% mutate(days = as.numeric(as.Date(lat) - as.Date(posted_date)), Group = "Selected Card"); p <- ggplot(card_age, aes(x=Group, y=days)) + geom_boxplot(fill="#f39c12", alpha=0.6) + geom_jitter(width=0.1, color="#18bc9c", size=3) + my_dark_theme() + labs(y="Days Listed", x=NULL); ggplotly(p, tooltip = "y") %>% config(displayModeBar = FALSE) })
  output$listings_table <- renderDT({ req(card_details()); card_details() %>% filter(date_pulled == max(date_pulled)) %>% arrange(price_val) %>% select(Title = listing_title, Price = price_val, `Graded?` = is_graded, `Type` = listing_type) %>% datatable(options=list(pageLength=10, dom='tp'), rownames=FALSE) %>% formatCurrency("Price") })

  output$pricing_selector_ui <- renderUI({ 
    all_cards <- sort(unique(master_dict$cardname))
    pool <- pred_cards_available()
    if(length(pool) == 0) pool <- all_cards
    set.seed(as.integer(Sys.Date())); start_card <- sample(pool, 1)
    selectizeInput("pricing_selected_cards", "Select up to 3 Cards:", choices = all_cards, selected = start_card, multiple = TRUE, options = list(maxItems = 3)) 
  })
  
  output$pricing_images_ui <- renderUI({ 
    req(input$pricing_selected_cards, pricing_details())
    info <- master_dict %>% filter(cardname %in% input$pricing_selected_cards)
    metrics_data <- pricing_details()$metrics
    
    ims <- purrr::map(1:nrow(info), function(i) { 
      c_id <- info$tcgplayer_id[i]
      m_row <- if(!is.null(metrics_data) && nrow(metrics_data) > 0) metrics_data %>% filter(tcgplayer_id == c_id) else data.frame()
      
      tags$div(
        style = "display:flex; flex-direction:row; background: #1a252f; border-radius: 12px; padding: 15px; border: 1px solid #34495e; align-items: center; flex: 1; min-width: 320px; max-width: 450px; box-shadow: 0 4px 8px rgba(0,0,0,0.5);",
        tags$img(src=paste0("card_photos/", info$folder_name[i], "/", info$id[i], ".avif"), style="width:100px; border-radius:8px; box-shadow: 0 4px 8px rgba(0,0,0,0.8); margin-right: 20px;"), 
        tags$div(
          style = "display:flex; flex-direction:column; justify-content:center; flex-grow: 1;",
          tags$div(style="font-size:14px; font-weight:bold; color:#ecf0f1; margin-bottom: 8px; border-bottom: 1px solid #18bc9c; padding-bottom: 4px;", info$cardname[i]),
          if(nrow(m_row) > 0) {
            tags$div(
              style = "font-size: 12px; color: #bbb; line-height: 1.6;",
              tags$div(tags$strong(style="color:#f39c12;", "Entropy: "), m_row$samp_entropy),
              tags$div(tags$strong(style="color:#f39c12;", "Hurst: "), m_row$hurst_exp),
              tags$div(tags$strong(style="color:#f39c12;", "Vol (CV): "), m_row$cv),
              tags$div(tags$strong(style="color:#f39c12;", "Skew: "), m_row$skewness)
            )
          } else {
            tags$div(style = "font-size: 12px; font-style: italic; color: #bbb;", "Metrics pipeline not executed.")
          }
        )
      )
    })
    div(style="display:flex; flex-direction:row; justify-content:center; flex-wrap:wrap; gap: 20px; padding: 10px;", ims) 
  })

  # THE 30-DAY ZOOMED PLOT & BACKTEST
  output$pricing_zoom_plot <- renderPlotly({
    req(pricing_details()); d <- pricing_details()
    latest_pull <- max(d$hist$pull_date, na.rm = TRUE)
    
    # UNIFY AXIS NAMES: Everything mapped to "plot_date"
    z_hist <- d$hist %>% filter(pull_date >= latest_pull - 30) %>% rename(plot_date = pull_date)
    
    p <- ggplot() + 
      geom_line(data=z_hist, aes(x=plot_date, y=market_price, color=cardname, group=cardname, 
                                 text=paste0("<b>Actual Price:</b> ", scales::dollar(market_price))), linewidth=1.5)
      
    if("Chronos Forecast" %in% input$show_models && nrow(d$chronos) > 0) {
      z_chronos <- d$chronos %>% filter(target_date >= latest_pull & target_date <= latest_pull + 30) %>% rename(plot_date = target_date)
      if(nrow(z_chronos)>0){
        p <- p + geom_line(data=z_chronos, aes(x=plot_date, y=pred_price, color=cardname, group=cardname, 
                                               text=paste0("<b>Chronos Forecast:</b> ", scales::dollar(pred_price))), linetype="dashed", linewidth=1.2) + 
                 geom_ribbon(data=z_chronos, aes(x=plot_date, ymin=conf_low, ymax=conf_high, fill=cardname, group=cardname), alpha=0.15)
      }
    }
    
    if("Chronos Shadow (Backtest)" %in% input$show_models && nrow(d$chronos_shadow) > 0) {
      z_c_shadow <- d$chronos_shadow %>% filter(target_date <= latest_pull + 30) %>% rename(plot_date = target_date)
      if(nrow(z_c_shadow)>0){
        p <- p + 
          geom_line(data=z_c_shadow, aes(x=plot_date, y=pred_price, group=interaction(cardname, run_id), 
                                         text=paste0("<b>Chronos Shadow:</b> ", scales::dollar(pred_price), "<br>Run ID: ", run_id)), color="#ff0055", linetype="dashed", linewidth=1.5, alpha=0.6)
      }
    }
    
    if("GRU Forecast" %in% input$show_models && nrow(d$gru) > 0) {
      z_gru <- d$gru %>% filter(target_date >= latest_pull & target_date <= latest_pull + 30) %>% rename(plot_date = target_date)
      if(nrow(z_gru)>0){
        p <- p + geom_line(data=z_gru, aes(x=plot_date, y=pred_price, color=cardname, group=cardname, 
                                           text=paste0("<b>GRU Forecast:</b> ", scales::dollar(pred_price))), linetype="dotted", linewidth=1.2)
      }
    }

    if("GRU Shadow (Backtest)" %in% input$show_models && nrow(d$gru_shadow) > 0) {
      z_g_shadow <- d$gru_shadow %>% filter(target_date <= latest_pull + 30) %>% rename(plot_date = target_date)
      if(nrow(z_g_shadow)>0){
        p <- p + 
          geom_line(data=z_g_shadow, aes(x=plot_date, y=pred_price, group=interaction(cardname, run_id), 
                                         text=paste0("<b>GRU Shadow:</b> ", scales::dollar(pred_price), "<br>Run ID: ", run_id)), color="#00e5ff", linetype="dotted", linewidth=1.5, alpha=0.6)
      }
    }
    
    p_ly <- ggplotly(p + my_dark_theme() + labs(x="Date", y="Market Price"), dynamicTicks = TRUE, tooltip = "text")
    p_ly <- clean_plotly_tooltips(p_ly)
    
    p_ly %>% 
      layout(
        showlegend = FALSE, hovermode = "x unified", plot_bgcolor = "#1a252f", paper_bgcolor = "#1a252f",
        font = list(color = "#ecf0f1"), xaxis = list(fixedrange = FALSE, showspikes = TRUE, spikemode = "across", spikethickness = 1, spikedash = "dot", spikecolor = "rgba(255,255,255,0.3)"),
        yaxis = list(tickprefix = "$", fixedrange = FALSE) 
      ) %>% config(displayModeBar = FALSE)
  })

  # THE ALL-TIME MACRO PLOT
  output$pricing_plot <- renderPlotly({
    req(pricing_details()); d <- pricing_details()
    latest_pull <- max(d$hist$pull_date, na.rm = TRUE)
    
    # UNIFY AXIS NAMES
    m_hist <- d$hist %>% rename(plot_date = pull_date)
    
    p <- ggplot() + 
      geom_line(data=m_hist, aes(x=plot_date, y=market_price, color=cardname, group=cardname, 
                                 text=paste0("<b>Actual Price:</b> ", scales::dollar(market_price))), linewidth=1.2)
      
    if("Chronos Forecast" %in% input$show_models && nrow(d$chronos) > 0) {
      m_chronos <- d$chronos %>% filter(target_date >= latest_pull) %>% rename(plot_date = target_date)
      if(nrow(m_chronos) > 0) {
        p <- p + geom_line(data=m_chronos, aes(x=plot_date, y=pred_price, color=cardname, group=cardname, 
                                               text=paste0("<b>Chronos Forecast:</b> ", scales::dollar(pred_price))), linetype="dashed", linewidth=1) + 
                 geom_ribbon(data=m_chronos, aes(x=plot_date, ymin=conf_low, ymax=conf_high, fill=cardname, group=cardname), alpha=0.15)
      }
    }
    
    if("Chronos Shadow (Backtest)" %in% input$show_models && nrow(d$chronos_shadow) > 0) {
      m_c_shadow <- d$chronos_shadow %>% filter(target_date <= latest_pull) %>% rename(plot_date = target_date)
      if(nrow(m_c_shadow)>0){
        p <- p + 
          geom_line(data=m_c_shadow, aes(x=plot_date, y=pred_price, group=interaction(cardname, run_id), 
                                         text=paste0("<b>Chronos Shadow:</b> ", scales::dollar(pred_price), "<br>Run ID: ", run_id)), color="#ff0055", linetype="dashed", linewidth=1.5, alpha=0.6)
      }
    }

    if("GRU Forecast" %in% input$show_models && nrow(d$gru) > 0) {
      m_gru <- d$gru %>% filter(target_date >= latest_pull) %>% rename(plot_date = target_date)
      if(nrow(m_gru) > 0) {
        p <- p + geom_line(data=m_gru, aes(x=plot_date, y=pred_price, color=cardname, group=cardname, 
                                           text=paste0("<b>GRU Forecast:</b> ", scales::dollar(pred_price))), linetype="dotted", linewidth=1.2)
      }
    }

    if("GRU Shadow (Backtest)" %in% input$show_models && nrow(d$gru_shadow) > 0) {
      m_g_shadow <- d$gru_shadow %>% filter(target_date <= latest_pull) %>% rename(plot_date = target_date)
      if(nrow(m_g_shadow)>0){
        p <- p + 
          geom_line(data=m_g_shadow, aes(x=plot_date, y=pred_price, group=interaction(cardname, run_id), 
                                         text=paste0("<b>GRU Shadow:</b> ", scales::dollar(pred_price), "<br>Run ID: ", run_id)), color="#00e5ff", linetype="dotted", linewidth=1.5, alpha=0.6)
      }
    }
    
    p_ly <- ggplotly(p + my_dark_theme() + labs(x="Date", y="Market Price"), dynamicTicks = TRUE, tooltip = "text")
    p_ly <- clean_plotly_tooltips(p_ly)
    
    p_ly %>% 
      layout(
        showlegend = FALSE, hovermode = "x unified", plot_bgcolor = "#1a252f", paper_bgcolor = "#1a252f",
        font = list(color = "#ecf0f1"), xaxis = list(rangeslider = list(visible = TRUE, thickness = 0.08, bgcolor = "#34495e"), fixedrange = FALSE, showspikes = TRUE, spikemode = "across", spikethickness = 1, spikedash = "dot", spikecolor = "rgba(255,255,255,0.3)"),
        yaxis = list(tickprefix = "$", fixedrange = TRUE) 
      ) %>% config(displayModeBar = FALSE)
  })
}

# ==========================================
# 3. LAUNCH
# ==========================================
shinyApp(ui, server)