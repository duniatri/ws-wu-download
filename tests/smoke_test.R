# =============================================================================
#  tests/smoke_test.R  --  Functional test without the UI
#
#  Run:  Rscript tests/smoke_test.R
#
#  Works with or without credentials:
#    - config.json present and filled in -> full suite including live API calls
#    - no credentials                    -> offline suite only (catalogue,
#                                           plotting, export, interval helpers)
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(tibble); library(ggplot2); library(lubridate)
})

APP_DIR <- local({
  a <- commandArgs(FALSE)
  f <- grep("^--file=", a, value = TRUE)
  if (length(f)) dirname(dirname(normalizePath(sub("^--file=", "", f[1])))) else getwd()
})
setwd(APP_DIR)

source("R/params.R"); source("R/api.R"); source("R/plot.R")

pass <- 0L; fail <- 0L; skip <- 0L
chk <- function(label, cond, extra = "") {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat(sprintf("  [PASS] %s %s\n", label, extra)) }
  else              { fail <<- fail + 1L; cat(sprintf("  [FAIL] %s %s\n", label, extra)) }
  invisible(isTRUE(cond))
}
skip_sec <- function(label) {
  skip <<- skip + 1L; cat(sprintf("  [SKIP] %s\n", label)); invisible(NULL)
}

# --- Configuration ------------------------------------------------------------

read_cfg <- function() {
  cfg <- list(api_key = "", station_id = "", units = "m",
              numeric_precision = "decimal")
  for (p in c("config.json", "config.example.json")) {
    if (file.exists(p)) {
      j <- tryCatch(jsonlite::fromJSON(p), error = function(e) NULL)
      if (is.list(j)) {
        for (k in intersect(names(cfg), names(j))) cfg[[k]] <- j[[k]]
        break
      }
    }
  }
  cfg$numeric_precision <- "decimal"
  cfg
}

cfg <- read_cfg()
has_creds <- nzchar(cfg$api_key) && !grepl("YOUR|ISI_|CHANGEME", cfg$api_key) &&
             nzchar(cfg$station_id) && !grepl("YOUR|DEMO", cfg$station_id)

cat("Station :", if (nzchar(cfg$station_id)) cfg$station_id else "(none)",
    "  units:", cfg$units, "\n")
cat("Mode    :", if (has_creds) "LIVE (credentials found)" else
                     "OFFLINE (no credentials - network sections skipped)", "\n\n")

# Synthetic dataset so plotting/export can be tested without the network
make_synth <- function(n = 60L) {
  t0 <- as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  tibble::tibble(
    time_local        = t0 + seq(0, by = 300, length.out = n),
    time_utc          = t0 + seq(0, by = 300, length.out = n),
    time_epoch        = t0 + seq(0, by = 300, length.out = n),
    source            = "observations/all/1day",
    stationID         = "DEMO0000",
    tz                = "UTC",
    qcStatus          = -1,
    tempAvg           = 25 + 8 * sin(seq(0, 3, length.out = n)),
    humidityAvg       = 70 - 20 * sin(seq(0, 3, length.out = n)),
    solarRadiationHigh = pmax(0, 900 * sin(seq(0, 3, length.out = n))),
    windspeedAvg      = 5 + 3 * cos(seq(0, 3, length.out = n))
  )
}

# =============================================================================
cat("1. Parameter catalogue\n")
pm <- param_table(c("time_local","tempAvg","tempHigh","humidityAvg","winddirAvg",
                    "windspeedAvg","windgustHigh","windchillLow","heatindexAvg",
                    "precipTotal","solarRadiationHigh","uvHigh","pressureTrend",
                    "epoch","neighborhood"), "m")
chk("15 columns mapped", nrow(pm) == 15L)
chk("Temperature category detected", any(pm$category == "Temperature"))
chk("temperature unit = deg C", pm$unit[pm$param == "tempAvg"] == "\u00b0C")
chk("radiation unit = W/m2", pm$unit[pm$param == "solarRadiationHigh"] == "W/m\u00b2")
chk("aggregate label present", grepl("interval max", pm$label[pm$param == "tempHigh"]))
chk("pressureTrend has a dedicated label",
    pm$label[pm$param == "pressureTrend"] == "Pressure Trend")

# API field names are inconsistent: tempAvg but windspeedAvg (lower-case).
chk("windspeedAvg -> Wind", pm$category[pm$param == "windspeedAvg"] == "Wind",
    sprintf("(%s)", pm$label[pm$param == "windspeedAvg"]))
chk("windgustHigh -> Wind", pm$category[pm$param == "windgustHigh"] == "Wind")
chk("windchillLow -> Temperature", pm$category[pm$param == "windchillLow"] == "Temperature")
chk("heatindexAvg -> Temperature", pm$category[pm$param == "heatindexAvg"] == "Temperature")
chk("wind unit km/h", pm$unit[pm$param == "windspeedAvg"] == "km/h")
chk("no column falls through to Other", !any(pm$category == "Other"),
    paste(pm$param[pm$category == "Other"], collapse = ", "))

# =============================================================================
# Live data (or synthetic fallback)
df_live <- NULL

if (has_creds) {
  cat("\n2. observations/all/1day (today)\n")
  res_today <- fetch_weather(cfg, "today")
  chk("data returned", nrow(res_today$df) > 0L,
      sprintf("(%d rows x %d cols)", nrow(res_today$df), ncol(res_today$df)))
  chk("time_local column present", "time_local" %in% names(res_today$df))
  chk("time_local is POSIXct", inherits(res_today$df$time_local, "POSIXct"))
  chk("data sorted ascending", !is.unsorted(res_today$df$time_local))
  chk("no duplicate timestamps", !any(duplicated(res_today$df$time_local)))
  chk("unit-bearing fields flattened (tempAvg present)",
      any(grepl("^temp", names(res_today$df))))
  chk("unit sub-objects no longer columns",
      !any(c("metric","imperial","uk_hybrid") %in% names(res_today$df)))
  chk("station timezone detected from the API",
      is.character(detect_tz(res_today$df)) && nzchar(detect_tz(res_today$df)),
      sprintf("(%s)", detect_tz(res_today$df)))

  # Catalogue coverage: no real column may fall through to "Other"
  pm_live <- param_table(names(res_today$df), "m")
  chk("every live column categorised", !any(pm_live$category == "Other"),
      paste(pm_live$param[pm_live$category == "Other"], collapse = ", "))
  chk("default parameters resolve",
      length(default_params(names(res_today$df))) > 0L,
      sprintf("(%d parameters)", length(default_params(names(res_today$df)))))

  if (nrow(res_today$df)) {
    d <- res_today$df
    if ("tempAvg" %in% names(d)) {
      chk("temperature within a plausible 15-50 C band",
          all(is.na(d$tempAvg) | (d$tempAvg > 15 & d$tempAvg < 50)))
    }
    if ("humidityAvg" %in% names(d)) {
      chk("humidity within 0-100 %",
          all(is.na(d$humidityAvg) | (d$humidityAvg >= 0 & d$humidityAvg <= 100)))
    }
  }

  cat("\n3. observations/current\n")
  res_cur <- wc_current(cfg)
  cat(sprintf("  HTTP %s | code=%s | %s\n",
              ifelse(is.na(res_cur$status), "-", res_cur$status), res_cur$code,
              substr(res_cur$message, 1, 90)))
  chk("does not throw, returns a structure",
      is.list(res_cur) && !is.null(res_cur$code))
  chk("204/200 handled without crashing", res_cur$code %in% c("ok", "empty"))

  df_live <- res_today$df
} else {
  cat("\n2. observations/all/1day (today)\n"); skip_sec("no credentials")
  cat("\n3. observations/current\n"); skip_sec("no credentials")
}

# Use synthetic data when live data is unavailable, so the rest still runs.
using_synth <- is.null(df_live) || !nrow(df_live)
if (using_synth) {
  df_live <- make_synth()
  cat("\n  (using a synthetic dataset for the plotting sections)\n")
}
sel <- default_params(names(df_live))
pm_all <- param_table(names(df_live), "m")

# =============================================================================
cat("\n4. build_trend_plot\n")
cat("  default parameters:", paste(sel, collapse = ", "), "\n")
res_plot <- build_trend_plot(df_live, sel, pm_all,
                             list(agg = "raw", facet = TRUE, points = FALSE,
                                  title = "Test", subtitle = "sub"))
chk("plot object built", !is.null(res_plot) && inherits(res_plot$plot, "ggplot"))
chk("series count > 0", res_plot$n_series > 0L, sprintf("(%d series)", res_plot$n_series))

for (a in c("raw", "hourly", "daily", "daily_range")) {
  r <- build_trend_plot(df_live, sel, pm_all, list(agg = a, facet = TRUE))
  chk(paste("aggregation", a), !is.null(r) && inherits(r$plot, "ggplot"))
}

r_norm <- build_trend_plot(df_live, sel, pm_all,
                           list(agg = "raw", facet = FALSE, normalize = TRUE))
chk("normalise + overlay mode", !is.null(r_norm) && inherits(r_norm$plot, "ggplot"))

# Time/identity columns accidentally selected must not break the plot
r_time <- build_trend_plot(df_live,
                           c("time_local", "epoch", "lat", "lon", "qcStatus", "tempAvg"),
                           pm_all, list(agg = "raw"))
chk("time/identity columns ignored when plotting",
    !is.null(r_time) && inherits(r_time$plot, "ggplot"),
    sprintf("(%d series)", if (is.null(r_time)) 0L else r_time$n_series))

# An all-empty parameter must be skipped, not raise an error
df_na <- df_live
df_na$empty_col <- NA_real_
pm_na <- param_table(c(names(df_live), "empty_col"), "m")
r_na <- build_trend_plot(df_na, c("tempAvg", "empty_col"), pm_na, list(agg = "raw"))
chk("empty series skipped without error",
    !is.null(r_na) && "empty_col" %in% r_na$dropped)

# =============================================================================
cat("\n5. PNG export\n")
png_path <- file.path(tempdir(), "smoke_trend.png")
save_plot_png(res_plot$plot, png_path, 12, 6, 300)
chk("PNG written", file.exists(png_path), sprintf("(%s bytes)", file.info(png_path)$size))
chk("PNG not empty", file.info(png_path)$size > 20000)

# =============================================================================
cat("\n6. XLSX export + time round-trip\n")
if (requireNamespace("readxl", quietly = TRUE) && requireNamespace("writexl", quietly = TRUE)) {
  xl <- file.path(tempdir(), "smoke_wx.xlsx")
  d  <- as.data.frame(df_live[, c("time_local", intersect(sel, names(df_live)))])
  writexl::write_xlsx(list(data = d), xl)
  chk("XLSX written", file.exists(xl), sprintf("(%s bytes)", file.info(xl)$size))

  back <- readxl::read_excel(xl)
  chk("row count preserved", nrow(back) == nrow(d))

  # Excel does not store timezones. The correct invariant is the WALL CLOCK
  # reading, not the absolute instant: readxl labels the Excel serial as
  # tz="UTC", so an absolute comparison shows an offset even though no data was
  # lost. Comparing wall-clock strings is what actually matters.
  wall_in  <- format(d$time_local, "%Y-%m-%d %H:%M:%S")
  wall_out <- format(back$time_local, "%Y-%m-%d %H:%M:%S")
  chk("wall-clock round-trip intact", identical(wall_in, wall_out),
      sprintf("(%d/%d match)", sum(wall_in == wall_out), length(wall_in)))
  cat("  sample time :", wall_in[1], "->", wall_out[1], "\n")
  cat("  tz label    :", attr(d$time_local, "tzone"), "->",
      attr(back$time_local, "tzone"),
      "(Excel artefact, not lost data)\n")
} else {
  skip_sec("readxl/writexl not installed")
}

# =============================================================================
cat("\n7. Error handling\n")
if (has_creds) {
  bad <- cfg; bad$api_key <- "wrong-key-000"
  r_bad <- wc_current(bad)
  chk("bad key handled without crashing", is.list(r_bad) && !r_bad$ok,
      sprintf("(code=%s)", r_bad$code))

  bad2 <- cfg; bad2$station_id <- "NOSUCHSTN999"
  r_bad2 <- fetch_weather(bad2, "today")
  chk("unknown station handled", is.data.frame(r_bad2$df))

  r_hist <- wc_history_daily(cfg, Sys.Date() - 1, Sys.Date() - 1)
  chk("history/daily returns a structure", is.list(r_hist),
      sprintf("(HTTP %s, code=%s)", r_hist$status, r_hist$code))
} else {
  skip_sec("no credentials")
}

# =============================================================================
cat("\n8. History detail (history/all, looped per date)\n")
r_det <- NULL
if (has_creds) {
  r_det <- fetch_weather(cfg, "detail", Sys.Date() - 1, Sys.Date())
  chk("date loop completed without error", is.data.frame(r_det$df))
  chk("log recorded per date", nrow(r_det$log) == 2L,
      sprintf("(%d entries)", nrow(r_det$log)))
  cat("  rows:", nrow(r_det$df), "| status:",
      paste(r_det$log$status, collapse = ", "),
      "| HTTP:", paste(r_det$log$http, collapse = ", "), "\n")
} else {
  skip_sec("no credentials")
}

# =============================================================================
cat("\n9. Resolution & interval helpers\n")

chk("endpoint today -> ~5 min detail",
    identical(endpoint_resolution("observations/all/1day"), "~5 min detail"))
chk("endpoint hourly -> hourly aggregate",
    identical(endpoint_resolution("history/hourly"), "hourly aggregate"))
chk("endpoint daily -> daily aggregate",
    identical(endpoint_resolution("history/daily"), "daily aggregate"))
chk("history/all + date still recognised",
    identical(endpoint_slug("history/all 2026-09-19"), "detail"))
chk("slug used in the filename",
    identical(endpoint_slug("observations/all/1day"), "today"))
chk("is_detail5 true for today",  isTRUE(is_detail5("observations/all/1day")))
chk("is_detail5 false for hourly", isFALSE(is_detail5("history/hourly")))

chk("fmt_interval 5 min",              identical(fmt_interval(5), "5 min"))
chk("fmt_interval 60 min stays minutes", identical(fmt_interval(60), "60 min"))
chk("fmt_interval 180 min -> hours",   grepl(" h$", fmt_interval(180)),
    sprintf("(%s)", fmt_interval(180)))
chk("fmt_interval 2880 min -> days",   grepl(" d$", fmt_interval(2880)),
    sprintf("(%s)", fmt_interval(2880)))
chk("fmt_interval NA",                 identical(fmt_interval(NA_real_), "\u2014"))

m_syn <- describe_data(df_live)
chk("describe_data: slug resolved", !identical(m_syn$slug, ""))
chk("describe_data: detail5 for raw source", isTRUE(m_syn$detail5))
chk("describe_data: median interval plausible (1-15 min)",
    is.finite(m_syn$interval) && m_syn$interval >= 1 && m_syn$interval <= 15,
    sprintf("(%s)", fmt_interval(m_syn$interval)))

if (!is.null(r_det)) {
  m_det <- describe_data(r_det$df)
  chk("describe_data: multi-date set stays detail5", isTRUE(m_det$detail5))
}

# Regression: provenance must remain readable even when the SELECTED columns do
# not contain the `source` column (it is not selected by default). This bug was
# real: the first version of info_sheet read the endpoint from the selected data
# and always reported "—".
sel_sub <- df_live[, intersect(c("time_local", "tempAvg", "humidityAvg"),
                               names(df_live)), drop = FALSE]
chk("selected subset really has no source column", !"source" %in% names(sel_sub))

inf <- info_sheet(sel_sub, list(station_id = "DEMO0000", units = "m"), df_live)
getv <- function(k) inf$value[match(k, inf$field)]
chk("info_sheet: endpoint read from the full data set",
    !identical(getv("Source endpoint"), "\u2014"),
    sprintf("(%s)", getv("Source endpoint")))
chk("info_sheet: resolution = ~5 min detail",
    identical(getv("Data resolution"), "~5 min detail"))
chk("info_sheet: median interval populated",
    grepl("min|h$|d$", getv("Median interval between observations")),
    sprintf("(%s)", getv("Median interval between observations")))
chk("info_sheet: row count matches",
    identical(getv("Row count"), as.character(nrow(sel_sub))))

# Interval derived from hourly aggregates must be much larger
if (has_creds) {
  r_hist_df <- tryCatch(fetch_weather(cfg, "hourly", Sys.Date() - 1, Sys.Date())$df,
                        error = function(e) tibble::tibble())
  if (nrow(r_hist_df) > 2L) {
    m_h <- describe_data(r_hist_df)
    chk("describe_data: hourly NOT flagged detail5", isFALSE(m_h$detail5))
    chk("describe_data: hourly interval > 30 min",
        is.finite(m_h$interval) && m_h$interval > 30,
        sprintf("(%s)", fmt_interval(m_h$interval)))
    cat("  interval today :", fmt_interval(m_syn$interval), "| n =", m_syn$n, "\n")
    cat("  interval hourly:", fmt_interval(m_h$interval), "| n =", m_h$n, "\n")
  }
} else {
  skip_sec("hourly interval comparison needs credentials")
}

# --- 10. Credential safety ----------------------------------------------------
# redact_key() is the only thing between a transport error (which can echo the
# request URL, and the key travels in its query string) and the browser. It must
# never let the key through, and never damage the rest of the message.
cat("\n10. Credential safety (redact_key)\n")

k_fake <- "abcdef0123456789abcdef0123456789"

chk("raw key value is masked",
    !grepl(k_fake, redact_key(paste0("GET /v2/pws?apiKey=", k_fake), k_fake),
           fixed = TRUE))
chk("generic apiKey= masked even when the key differs",
    !grepl("SOMEOTHERKEY",
           redact_key("https://api.weather.com/x?apiKey=SOMEOTHERKEY&y=1", k_fake),
           fixed = TRUE))
chk("rest of the message survives",
    grepl("Failed to connect",
          redact_key(paste0("Failed to connect: apiKey=", k_fake), k_fake),
          fixed = TRUE))
chk("NULL input is safe",            is.null(redact_key(NULL, k_fake)))
chk("text without a key is untouched",
    identical(redact_key("nothing secret here", k_fake), "nothing secret here"))
chk("missing key argument is safe",
    identical(redact_key("a?apiKey=b"), "a?apiKey=***"))
chk("empty key still applies the generic rule",
    identical(redact_key("a?apiKey=b", ""), "a?apiKey=***"))

# --- 11. info_sheet timezone --------------------------------------------------
# Same bug class as the `source` column, but silent: `tz` is not part of the
# user's column selection, so reading it from the selected subset falls back to
# UTC and mislabels every timestamp in the workbook. Runs without credentials.
cat("\n11. info_sheet timezone comes from the full data set\n")

tz_full <- tibble::tibble(
  time_local = as.POSIXct("2026-01-01 10:00:00", tz = "UTC"),
  tempAvg    = 30,
  tz         = "Asia/Makassar",
  source     = "observations/all/1day"
)
tz_sel <- tz_full[, c("time_local", "tempAvg")]
inf_tz <- info_sheet(tz_sel, list(station_id = "X", units = "m"), tz_full)
tz_got <- inf_tz$value[match("Timezone", inf_tz$field)]

chk("selected subset really has no tz column", !"tz" %in% names(tz_sel))
chk("info_sheet reports the station timezone, not the fallback",
    identical(tz_got, "Asia/Makassar"), sprintf("(%s)", tz_got))

# =============================================================================
cat("\n============================================\n")
cat(sprintf("  RESULT: %d PASS, %d FAIL, %d SKIP\n", pass, fail, skip))
cat("============================================\n")
if (fail > 0L) quit(status = 1L)
