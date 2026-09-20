# =============================================================================
#  Weather Station Explorer  --  R Shiny
#  Data source: The Weather Company / Weather Underground PWS API v2
#
#  Run:
#     cd <this folder>
#     Rscript -e 'shiny::runApp(".", port = 8085, launch.browser = TRUE)'
#
#  Flow: 1) fetch data  ->  2) pick parameters & download .xlsx  ->  3) plot & save .png
# =============================================================================

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(plotly)
  library(DT)
  library(dplyr)
  library(tidyr)
  library(tibble)
  library(ggplot2)
  library(lubridate)
  library(shinycssloaders)
})

# --- App location (so source() works from any working directory) --------------
APP_DIR <- local({
  d <- getwd()
  if (!dir.exists(file.path(d, "R"))) {
    a <- commandArgs(FALSE)
    f <- grep("^--file=", a, value = TRUE)
    if (length(f)) {
      d2 <- dirname(normalizePath(sub("^--file=", "", f[1]), mustWork = FALSE))
      if (dir.exists(file.path(d2, "R"))) d <- d2
    }
  }
  d
})

source(file.path(APP_DIR, "R", "params.R"))
source(file.path(APP_DIR, "R", "api.R"))
source(file.path(APP_DIR, "R", "plot.R"))

# --- Configuration ------------------------------------------------------------

load_config <- function(dir = APP_DIR) {
  cfg <- list(api_key = "", station_id = "", units = "m",
              numeric_precision = "decimal")
  p <- file.path(dir, "config.json")
  if (file.exists(p)) {
    j <- tryCatch(jsonlite::fromJSON(p), error = function(e) NULL)
    if (is.list(j)) for (k in intersect(names(cfg), names(j))) cfg[[k]] <- j[[k]]
  }
  if (nzchar(Sys.getenv("WC_API_KEY")))    cfg$api_key    <- Sys.getenv("WC_API_KEY")
  if (nzchar(Sys.getenv("WC_STATION_ID"))) cfg$station_id <- Sys.getenv("WC_STATION_ID")
  if (nzchar(Sys.getenv("WC_UNITS")))      cfg$units      <- Sys.getenv("WC_UNITS")
  cfg
}

CFG0 <- load_config()

# --- UI constants -------------------------------------------------------------

# Labels deliberately state the RESOLUTION, because each endpoint returns a
# different one and that cannot be changed from the app (an API constraint,
# not a setting). Without this, users conclude the download is "wrong".
SOURCE_CHOICES <- c(
  "Latest reading (observations/current)"              = "current",
  "Today \u2014 ~5 min detail (observations/all/1day)"  = "today",
  "History detail ~5 min (history/all)"                = "detail",
  "Hourly history \u2014 aggregate (history/hourly)"    = "hourly",
  "Daily history \u2014 aggregate (history/daily)"      = "daily"
)

RANGE_SOURCES <- c("detail", "hourly", "daily")

cat_id <- function(cat) paste0("p_", gsub("[^A-Za-z0-9]+", "_", cat))

# =============================================================================
#  UI
# =============================================================================

ui <- page_navbar(
  title = tags$span("\U0001F326\uFE0F Weather Station Explorer"),
  theme = bs_theme(version = 5, bootswatch = "flatly", primary = "#0B6E4F"),
  fillable = FALSE,

  # header= (not a direct child) to avoid the
  # "Navigation containers expect a collection of nav_panel()" warning
  header = tags$style(HTML("
    .picker-cat { font-weight:600; font-size:.78rem; text-transform:uppercase;
                  letter-spacing:.04em; color:#0B6E4F; margin-bottom:.25rem; }
    .shiny-input-container { margin-bottom:.4rem; }
    .note-box { background:#f8f9fa; border-left:3px solid #adb5bd;
                padding:.6rem .8rem; border-radius:.25rem; font-size:.84rem; }
  ")),

  # ===== TAB 1 : FETCH DATA ===================================================
  nav_panel("1 \u00b7 Fetch Data", icon = icon("cloud-arrow-down"),
    layout_sidebar(
      sidebar = sidebar(
        width = 350, title = "Fetch settings", open = "always",

        accordion(
          open = FALSE,
          accordion_panel("Credentials", icon = icon("key"),
            textInput("station_id", "Station ID", value = CFG0$station_id),
            passwordInput("api_key", "API key", value = CFG0$api_key),
            selectInput("units", "Unit system",
              choices = c("Metric (\u00b0C, km/h, mm, hPa)" = "m",
                          "Imperial (\u00b0F, mph, in)"     = "e",
                          "UK Hybrid"                      = "h"),
              selected = CFG0$units),
            helpText("Initial values are read from config.json. They can be",
                     "overridden with the WC_API_KEY / WC_STATION_ID",
                     "environment variables.")
          )
        ),

        selectInput("source", "Data source",
                    choices = SOURCE_CHOICES, selected = "today"),

        conditionalPanel(
          condition = paste(sprintf("input.source == '%s'", RANGE_SOURCES),
                            collapse = " || "),
          dateInput("date_start", "Start date", value = Sys.Date()),
          dateInput("date_end",   "End date",   value = Sys.Date()),
          helpText("Maximum 31 days per request.")
        ),

        actionButton("btn_fetch", "Fetch data",
                     class = "btn-primary w-100", icon = icon("download")),
        div(class = "mt-2"),
        actionButton("btn_status", "Check station status",
                     class = "btn-outline-secondary w-100",
                     icon = icon("heart-pulse")),

        hr(),
        div(class = "note-box",
          HTML("<b>Note.</b> <code>history/*</code> endpoints <i>can</i> be used for the",
               "current day (verified) \u2014 but <i>Today</i> is still leaner because",
               "it needs only one request.",
               "HTTP <b>204</b> <i>or</i> <b>200</b> with an empty array both mean",
               "\"no data\" (not a key problem); HTTP <b>401</b> means the key is not",
               "entitled to the product.")
        )
      ),

      uiOutput("status_box"),
      uiOutput("summary_boxes"),
      card(
        card_header(icon("table"), "Data preview"),
        card_body(DTOutput("tbl_raw"))
      ),
      card(
        card_header(icon("list-check"), "Server request log"),
        card_body(DTOutput("tbl_log"))
      )
    )
  ),

  # ===== TAB 2 : SELECT PARAMETERS & DOWNLOAD =================================
  nav_panel("2 \u00b7 Select & Download", icon = icon("file-excel"),
    uiOutput("src_info"),
    card(
      card_header(
        div(class = "d-flex justify-content-between align-items-center",
          tags$span(icon("sliders"), " Parameters available on the server"),
          tags$span(class = "text-muted small", textOutput("sel_count", inline = TRUE))
        )
      ),
      card_body(
        div(class = "d-flex flex-wrap gap-2 mb-3",
          actionButton("btn_all",     "Select all",  class = "btn-sm btn-outline-primary"),
          actionButton("btn_none",    "Clear",       class = "btn-sm btn-outline-secondary"),
          actionButton("btn_default", "Recommended", class = "btn-sm btn-outline-success"),
          actionButton("btn_numeric", "Numeric only", class = "btn-sm btn-outline-info")
        ),
        uiOutput("picker")
      )
    ),
    layout_columns(
      col_widths = c(5, 7),
      card(
        card_header(icon("file-arrow-down"), "Download"),
        card_body(
          checkboxInput("incl_summary", "Include the summary statistics sheet", TRUE),
          helpText("The workbook always contains an ", tags$code("info"),
                   " sheet (source endpoint, resolution, median interval) and a ",
                   tags$code("data"), " sheet. The summary sheet holds the valid ",
                   "count, missing count, min, mean, median and max."),
          downloadButton("dl_xlsx", "Download as .xlsx",
                         class = "btn-success w-100")
        )
      ),
      card(
        card_header(icon("eye"), "Preview of the selected data"),
        card_body(DTOutput("tbl_sel"))
      )
    )
  ),

  # ===== TAB 3 : TREND CHART ==================================================
  nav_panel("3 \u00b7 Trend Chart", icon = icon("chart-line"),
    layout_sidebar(
      sidebar = sidebar(
        width = 330, title = "Chart settings", open = "always",
        selectInput("agg", "Time aggregation",
                    choices = AGG_CHOICES, selected = "raw"),
        checkboxInput("facet",     "Split into one panel per parameter (free scale)", TRUE),
        checkboxInput("normalize", "z-score normalisation (for overlay)", FALSE),
        checkboxInput("points",    "Show data points", FALSE),
        textInput("plot_title", "Chart title", value = "",
                  placeholder = "Leave blank for an automatic title"),
        hr(),
        h6(class = "text-muted small text-uppercase fw-bold", "PNG export"),
        numericInput("png_w",   "Width (inches)",  value = 12,  min = 4,  max = 40,  step = 1),
        numericInput("png_h",   "Height (inches)", value = 6,   min = 3,  max = 40,  step = 1),
        numericInput("png_dpi", "Resolution (dpi)", value = 300, min = 72, max = 600, step = 50),
        downloadButton("dl_png", "Download chart .png",
                       class = "btn-success w-100")
      ),
      uiOutput("plot_note"),
      card(
        card_header(icon("chart-line"), "Trend of the selected parameters"),
        card_body(withSpinner(plotlyOutput("trend", height = "560px")))
      )
    )
  ),

  # ===== TAB 4 : API INFO =====================================================
  nav_panel("API Info", icon = icon("circle-info"),
    card(
      card_header("Endpoints used by this app"),
      card_body(
        tags$table(class = "table table-sm table-striped",
          tags$thead(tags$tr(tags$th("Need"), tags$th("Endpoint"),
                             tags$th("Data resolution"), tags$th("Notes"))),
          tags$tbody(
            tags$tr(tags$td("Latest reading"), tags$td(tags$code("v2/pws/observations/current")),
                    tags$td(tags$b("instant value")),
                    tags$td("204 when the station is offline.")),
            tags$tr(tags$td("Today"), tags$td(tags$code("v2/pws/observations/all/1day")),
                    tags$td(tags$b("~5 min")),
                    tags$td("Raw sample per upload.")),
            tags$tr(tags$td("History detail"), tags$td(tags$code("v2/pws/history/all")),
                    tags$td(tags$b("~5 min")),
                    tags$td("One date per request. Retention is short (~3 days).")),
            tags$tr(tags$td("Hourly history"), tags$td(tags$code("v2/pws/history/hourly")),
                    tags$td(class = "text-danger", tags$b("hourly aggregate")),
                    tags$td("Accepts a range, maximum 31 days.")),
            tags$tr(tags$td("Daily history"), tags$td(tags$code("v2/pws/history/daily")),
                    tags$td(class = "text-danger", tags$b("daily aggregate")),
                    tags$td("Accepts a range, maximum 31 days."))
          )
        ),
        div(class = "note-box mt-3",
          HTML("<b>Resolution cannot be changed.</b> The <code>history/hourly</code>",
               " and <code>history/daily</code> endpoints return server-computed",
               " aggregates \u2014 the underlying ~5 minute samples <i>cannot</i> be",
               " recovered from them. For ~5 minute data use <b>Today</b> (current day",
               " only) or <b>History detail</b> (one request per day, and retention",
               " is only a few days)."))
      )
    ),
    card(
      card_header("What the HTTP status codes mean"),
      card_body(tags$ul(
        tags$li(tags$b("200"), " \u2014 success. Still check whether ",
                tags$code("observations"), " is empty."),
        tags$li(tags$b("204"), " \u2014 no data. Not an API key problem."),
        tags$li(tags$b("401"), " \u2014 the key is not entitled to this product."),
        tags$li(tags$b("400"), " \u2014 invalid request parameters."),
        tags$li(tags$b("429"), " \u2014 rate limit exceeded."),
        tags$li("API-level errors can arrive as ", tags$b("HTTP 200"),
                " with a body containing ", tags$code("{\"errors\":[...]}"), ".")
      ))
    ),
    card(
      card_header("Data structure notes"),
      card_body(tags$ul(
        tags$li("Unit-bearing fields live in a sub-object ", tags$code("metric"),
                " (or ", tags$code("imperial"), " / ", tags$code("uk_hybrid"),
                "). This app flattens them into a single table."),
        tags$li(tags$code("history/*"), " endpoints return High/Low/Avg aggregates",
                " per interval, not instantaneous values."),
        tags$li("Upload interval is ", tags$b("not uniform"), " \u2014 observed 2 to 112",
                " minutes. Expect gaps; deduplicate on ",
                tags$code("epoch"), ", not on a timestamp."),
        tags$li("The station timezone is read from the ", tags$code("tz"),
                " field returned by the API, so nothing is hard-coded."),
        tags$li(tags$code("numericPrecision"), " only accepts ",
                tags$code("decimal"), "."),
        tags$li(tags$code("qcStatus"), ": ", tags$b("\u22121"), " = row carries measurements, ",
                tags$b("1"), " = heartbeat upload with no measurements (all sensors NA).",
                " The app keeps these rows so the gap is visible rather than hidden."),
        tags$li("Rows are deduplicated on ", tags$code("epoch"), ".")
      ))
    )
  )
)

# =============================================================================
#  SERVER
# =============================================================================

server <- function(input, output, session) {

  r_data  <- reactiveVal(tibble::tibble())
  r_log   <- reactiveVal(NULL)
  r_meta  <- reactiveVal(NULL)
  r_state <- reactiveVal(list(
    kind  = "info",
    title = "No data yet",
    msg   = "Choose a data source in the left panel, then click Fetch data."
  ))

  current_cfg <- reactive({
    list(api_key           = trimws(input$api_key %||% ""),
         station_id        = toupper(trimws(input$station_id %||% "")),
         units             = input$units %||% "m",
         numeric_precision = "decimal")
  })

  cats_now <- reactive({
    pm <- r_meta()
    if (is.null(pm) || !nrow(pm)) return(character())
    intersect(CAT_ORDER, unique(pm$category))
  })

  # --- Fetch data -------------------------------------------------------------
  observeEvent(input$btn_fetch, {
    cfg <- current_cfg()

    if (!nzchar(cfg$station_id)) {
      showNotification("Station ID is empty.", type = "error"); return()
    }
    if (!nzchar(cfg$api_key)) {
      showNotification("API key is empty.", type = "error"); return()
    }

    src <- input$source
    # as.Date() keeps validation robust for both Date and character from the client
    d_start <- as.Date(input$date_start, origin = "1970-01-01")
    d_end   <- as.Date(input$date_end,   origin = "1970-01-01")

    if (src %in% RANGE_SOURCES) {
      if (is.na(d_start) || is.na(d_end)) {
        showNotification("The date range is incomplete.", type = "error"); return()
      }
      if (d_end < d_start) {
        showNotification("The end date is earlier than the start date.",
                         type = "error"); return()
      }
      if (as.numeric(d_end - d_start) > MAX_RANGE_DAYS) {
        showNotification(sprintf("Maximum range is %d days.", MAX_RANGE_DAYS),
                         type = "error"); return()
      }
    }

    res <- withProgress(message = "Fetching data from the server\u2026", value = 0, {
      fetch_weather(cfg, src, d_start, d_end,
        progress = function(d) {
          incProgress(1 / MAX_RANGE_DAYS,
                      detail = paste("Fetching", format(d, "%d %b %Y")))
        })
    })

    r_data(res$df)
    r_log(res$log)

    if (nrow(res$df) == 0L) {
      r_meta(NULL)
      msg <- if (nrow(res$log)) res$log$message[1] else "The server returned no data."
      r_state(list(kind = "warn", title = "No data", msg = msg))
    } else {
      r_meta(param_table(names(res$df), cfg$units))
      r_state(list(kind = "ok",
                   title = "Data fetched successfully",
                   msg = sprintf("%s rows \u00d7 %s columns from station %s.",
                                 fmt_int(nrow(res$df)),
                                 ncol(res$df), cfg$station_id)))
    }
  })

  # --- Station status check ---------------------------------------------------
  observeEvent(input$btn_status, {
    cfg <- current_cfg()
    if (!nzchar(cfg$station_id) || !nzchar(cfg$api_key)) {
      showNotification("Enter the Station ID and API key first.", type = "error"); return()
    }

    res <- withProgress(message = "Contacting the station\u2026", value = 0.5, {
      wc_current(cfg)
    })

    online <- isTRUE(res$ok) && res$code == "ok"
    df <- if (online) flatten_observations(res$observations, "status-check") else NULL

    body <- if (online && !is.null(df) && nrow(df) > 0L) {
      tagList(
        tags$p(class = "mb-2", tags$b("Status:"), " \U0001F7E2 ONLINE"),
        tags$p(class = "mb-1", "Last reading: ",
               tags$b(format(df$time_local[1], "%d %b %Y %H:%M:%S"))),
        tags$p(class = "mb-0 text-muted small", res$message)
      )
    } else {
      tagList(
        tags$p(class = "mb-2", tags$b("Status:"),
               " \U0001F534 OFFLINE / no data"),
        tags$p(class = "mb-0", res$message)
      )
    }

    showModal(modalDialog(
      title = paste("Station status", cfg$station_id),
      body, easyClose = TRUE, footer = modalButton("Close")
    ))
  })

  # --- Status box & summary boxes ---------------------------------------------
  output$status_box <- renderUI({
    st <- r_state()
    cls <- switch(st$kind,
      ok   = "alert alert-success",
      warn = "alert alert-warning",
      info = "alert alert-secondary")
    div(class = cls, role = "alert", tags$b(st$title), tags$br(), st$msg)
  })

  output$summary_boxes <- renderUI({
    d <- r_data()
    if (!nrow(d)) return(NULL)
    rng <- if ("time_local" %in% names(d)) {
      paste0(format(min(d$time_local), "%d %b %Y %H:%M"), " \u2013 ",
             format(max(d$time_local), "%d %b %Y %H:%M"))
    } else "\u2014"

    layout_columns(col_widths = c(3, 3, 3, 3),
      value_box("Rows", fmt_int(nrow(d)), showcase = icon("list-ol")),
      value_box("Columns", ncol(d), showcase = icon("table-columns")),
      value_box("Numeric parameters",
                sum(vapply(d, is.numeric, logical(1))), showcase = icon("ruler")),
      value_box("Time range", tags$span(class = "fs-6", rng),
                showcase = icon("clock"))
    )
  })

  # --- Data provenance & resolution -------------------------------------------
  # Read from the `source` column INSIDE the data, not from input$source: the
  # dropdown can be changed after fetching without the data changing, so a
  # label derived from input$source would lie.
  output$src_info <- renderUI({
    d <- r_data()
    if (!nrow(d)) return(NULL)
    m <- describe_data(d)

    rng <- if (!is.na(m$t_start) && !is.na(m$t_end)) {
      paste0(format(m$t_start, "%d %b %Y %H:%M"), " \u2013 ",
             format(m$t_end,   "%d %b %Y %H:%M"))
    } else "\u2014"

    slow <- m$detail5 && is.finite(m$interval) && m$interval > 15

    hint <- if (!m$detail5) {
      div(class = "small mt-2",
        tags$b("\u26a0 This endpoint returns "), tags$b(m$resolution),
        tags$b(", not raw ~5 minute data."),
        " For a ~5 minute interval choose the ",
        tags$b("Today \u2014 ~5 min detail"), " or ",
        tags$b("History detail ~5 min"), " source on tab 1.")
    } else if (slow) {
      div(class = "small mt-2",
        tags$b("\u26a0 Median interval "), tags$b(fmt_interval(m$interval)),
        tags$b(" \u2014 sparser than ~5 minutes."),
        " The station appears to be missing some uploads.")
    }

    div(class = "alert alert-info py-2 px-3 mb-3", role = "alert",
      tags$div(
        tags$b("Data source: "), m$resolution,
        tags$span(class = "text-muted", "  \u00b7  "),
        tags$code(m$endpoint_txt)
      ),
      tags$div(class = "small text-muted",
        fmt_int(m$n), " rows \u00b7 median interval ",
        tags$b(fmt_interval(m$interval)), " \u00b7 ", rng,
        " (", m$tz, ")"),
      hint
    )
  })

  output$tbl_raw <- renderDT({
    d <- r_data()
    if (!nrow(d)) {
      return(datatable(data.frame(message = "No data yet."), rownames = FALSE,
                       options = list(dom = "t")))
    }
    datatable(d, rownames = FALSE, filter = "top",
              options = list(scrollX = TRUE, pageLength = 10, autoWidth = TRUE))
  })

  output$tbl_log <- renderDT({
    lg <- r_log()
    if (is.null(lg) || !nrow(lg)) {
      return(datatable(data.frame(message = "\u2014"), rownames = FALSE,
                       options = list(dom = "t")))
    }
    datatable(lg, rownames = FALSE, options = list(dom = "t", scrollX = TRUE))
  })

  # --- Parameter picker -------------------------------------------------------
  output$picker <- renderUI({
    pm <- r_meta()
    if (is.null(pm) || !nrow(pm)) {
      return(div(class = "text-muted p-3",
                 "No data yet. Open the ", tags$b("1 \u00b7 Fetch Data"),
                 " tab and click ", tags$b("Fetch data"), "."))
    }
    defaults <- default_params(names(r_data()))

    div(class = "row",
      lapply(cats_now(), function(ct) {
        sub <- pm[pm$category == ct, , drop = FALSE]
        ch  <- stats::setNames(sub$param, sub$series_label)
        div(class = "col-lg-4 col-md-6",
          div(class = "mb-3",
            div(class = "picker-cat", ct,
                tags$span(class = "badge text-bg-light ms-1", nrow(sub))),
            checkboxGroupInput(cat_id(ct), NULL, choices = ch,
                               selected = intersect(defaults, sub$param),
                               width = "100%")
          )
        )
      })
    )
  })

  sel_params <- reactive({
    pm <- r_meta()
    if (is.null(pm) || !nrow(pm)) return(character())
    vals <- unlist(lapply(cats_now(), function(ct) input[[cat_id(ct)]]),
                   use.names = FALSE)
    intersect(as.character(vals), pm$param)
  })

  output$sel_count <- renderText({
    sprintf("%d parameters selected", length(sel_params()))
  })

  set_selection <- function(cols) {
    pm <- r_meta()
    if (is.null(pm) || !nrow(pm)) return(invisible(NULL))
    for (ct in cats_now()) {
      sub <- pm[pm$category == ct, , drop = FALSE]
      updateCheckboxGroupInput(session, cat_id(ct),
                               selected = intersect(cols, sub$param))
    }
    invisible(NULL)
  }

  observeEvent(input$btn_all,     set_selection(r_meta()$param))
  observeEvent(input$btn_none,    set_selection(character(0)))
  observeEvent(input$btn_default, set_selection(default_params(names(r_data()))))

  observeEvent(input$btn_numeric, {
    d <- r_data()
    if (!nrow(d)) return()
    num <- names(d)[vapply(d, is.numeric, logical(1))]
    num <- setdiff(num, c("epoch", "lat", "lon", "qcStatus"))
    set_selection(num)
  })

  # --- Selected data ----------------------------------------------------------
  selected_df <- reactive({
    d <- r_data()
    if (!nrow(d)) return(NULL)
    cols <- intersect(unique(c("time_local", sel_params())), names(d))
    if (length(cols) < 2L) return(NULL)
    d[, cols, drop = FALSE]
  })

  output$tbl_sel <- renderDT({
    d <- selected_df()
    if (is.null(d)) {
      return(datatable(data.frame(message = "No parameters selected."),
                       rownames = FALSE, options = list(dom = "t")))
    }
    datatable(d, rownames = FALSE,
              options = list(scrollX = TRUE, pageLength = 8, autoWidth = TRUE))
  })

  # --- XLSX export ------------------------------------------------------------
  smedian <- function(x) {
    if (any(is.finite(x))) stats::median(x, na.rm = TRUE) else NA_real_
  }

  summary_sheet <- function(d) {
    num <- d[, vapply(d, is.numeric, logical(1)), drop = FALSE]
    num <- num[, setdiff(names(num), c("epoch", "lat", "lon", "qcStatus")),
               drop = FALSE]
    if (!ncol(num)) return(data.frame(field = "No numeric columns"))

    pm <- r_meta()
    lab <- if (!is.null(pm)) pm$series_label[match(names(num), pm$param)] else names(num)
    lab[is.na(lab)] <- names(num)[is.na(lab)]

    data.frame(
      parameter = names(num),
      label     = lab,
      n_valid   = vapply(num, function(x) sum(is.finite(x)), integer(1)),
      n_missing = vapply(num, function(x) sum(!is.finite(x)), integer(1)),
      minimum   = vapply(num, .safe_min,  numeric(1)),
      mean      = vapply(num, .safe_mean, numeric(1)),
      median    = vapply(num, smedian,    numeric(1)),
      maximum   = vapply(num, .safe_max,  numeric(1)),
      stringsAsFactors = FALSE
    )
  }

  output$dl_xlsx <- downloadHandler(
    filename = function() {
      sl <- describe_data(r_data())$slug
      paste0("weather_", current_cfg()$station_id, "_", sl, "_",
             format(Sys.time(), "%Y%m%d_%H%M%S"), ".xlsx")
    },
    content = function(file) {
      d <- selected_df()
      if (is.null(d)) {
        writexl::write_xlsx(
          list(message = data.frame(message = "No data selected.")), file)
        return()
      }
      # `info` deliberately comes first so provenance is immediately visible.
      sheets <- list(info = info_sheet(d, current_cfg(), r_data()),
                     data = as.data.frame(d))
      if (isTRUE(input$incl_summary)) sheets[["summary"]] <- summary_sheet(d)
      writexl::write_xlsx(sheets, file)
    }
  )

  # --- Plot -------------------------------------------------------------------
  plot_subtitle <- reactive({
    d <- r_data()
    if (!nrow(d) || !"time_local" %in% names(d)) return("")
    paste0(format(min(d$time_local), "%d %b %Y %H:%M"), " \u2013 ",
           format(max(d$time_local), "%d %b %Y %H:%M"),
           "  \u00b7  ", fmt_int(nrow(d)), " observations",
           "  \u00b7  ", detect_tz(d))
  })

  r_plot <- reactive({
    d <- r_data(); pm <- r_meta()
    if (!nrow(d) || is.null(pm)) return(NULL)
    sel <- sel_params()
    if (!length(sel)) return(NULL)

    ttl <- trimws(input$plot_title %||% "")
    if (!nzchar(ttl)) ttl <- paste("Weather parameter trend \u2014",
                                   current_cfg()$station_id)

    build_trend_plot(d, sel, pm, opts = list(
      agg       = input$agg %||% "raw",
      facet     = isTRUE(input$facet),
      normalize = isTRUE(input$normalize),
      points    = isTRUE(input$points),
      title     = ttl,
      subtitle  = plot_subtitle()
    ))
  })

  output$plot_note <- renderUI({
    if (!nrow(r_data())) {
      return(div(class = "alert alert-secondary",
                 "No data yet. Fetch data on tab 1 first."))
    }
    if (!length(sel_params())) {
      return(div(class = "alert alert-warning",
                 "No parameters selected. Pick some on tab 2 first."))
    }
    res <- r_plot()
    if (is.null(res)) {
      return(div(class = "alert alert-warning",
                 "No valid values in the selected parameters."))
    }
    if (length(res$dropped)) {
      pm <- r_meta()
      lab <- pm$series_label[match(res$dropped, pm$param)]
      lab[is.na(lab)] <- res$dropped[is.na(lab)]
      return(div(class = "alert alert-warning",
                 tags$b("Skipped (no values): "),
                 paste(lab, collapse = ", ")))
    }
    NULL
  })

  output$trend <- renderPlotly({
    res <- r_plot()
    validate(need(!is.null(res), "No data to plot."))
    plotly::ggplotly(res$plot, dynamicTicks = TRUE) |>
      plotly::config(displaylogo = FALSE,
                     modeBarButtonsToRemove = c("lasso2d", "select2d"))
  })

  output$dl_png <- downloadHandler(
    filename = function() {
      paste0("trend_", current_cfg()$station_id, "_",
             format(Sys.time(), "%Y%m%d_%H%M%S"), ".png")
    },
    content = function(file) {
      res <- r_plot()
      validate(need(!is.null(res), "No chart to save."))
      w  <- max(4,   input$png_w   %||% 12)
      h  <- max(3,   input$png_h   %||% 6)
      dp <- max(72,  input$png_dpi %||% 300)
      withProgress(message = "Saving PNG\u2026", value = 0.5, {
        save_plot_png(res$plot, file, w, h, dp)
      })
    }
  )
}

shinyApp(ui, server)
