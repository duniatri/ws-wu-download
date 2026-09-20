# =============================================================================
#  R/params.R  --  Weather parameter catalogue
#  Source: The Weather Company / Weather Underground PWS API v2
#
#  Contents: per-column metadata (category, English label, unit), the metadata
#  table, and the recommended default parameter set.
# =============================================================================

# Fallback timezone. The real station timezone is read from the API response
# (`tz` field) whenever it is present -- see detect_tz() below. Override the
# fallback with the WC_TZ environment variable.
STATION_TZ <- Sys.getenv("WC_TZ", unset = "UTC")

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0L) b else a

# Thousands separator for display.
fmt_int <- function(x) {
  formatC(as.integer(x), format = "d", big.mark = ",", decimal.mark = ".")
}

# --- Categories ---------------------------------------------------------------

CAT_TIME  <- "Identity & Time"
CAT_TEMP  <- "Temperature"
CAT_HUM   <- "Humidity"
CAT_WIND  <- "Wind"
CAT_PRESS <- "Pressure"
CAT_RAIN  <- "Precipitation"
CAT_RAD   <- "Radiation & UV"
CAT_OTHER <- "Other"

CAT_ORDER <- c(CAT_TIME, CAT_TEMP, CAT_HUM, CAT_WIND,
               CAT_PRESS, CAT_RAIN, CAT_RAD, CAT_OTHER)

# --- Helpers ------------------------------------------------------------------

# Pick the unit matching the unit system requested from the API
# (m = metric, e = imperial, h = uk_hybrid).
.unit <- function(units, m, e, h = NULL) {
  if (is.null(h)) h <- e
  switch(units, m = m, e = e, h = h, m)
}

# Historical endpoints use aggregate suffixes: tempAvg, tempHigh, tempLow, ...
.agg_label <- function(s) {
  switch(s,
    High = " \u2014 interval max",
    Max  = " \u2014 interval max",
    Low  = " \u2014 interval min",
    Min  = " \u2014 interval min",
    Avg  = " \u2014 interval avg",
    "")
}

.base_label <- function(b) {
  # The API lower-cases everything after the first word (windspeedHigh,
  # heatindexAvg, ...), so matching is done case-insensitively.
  switch(tolower(b),
    temp           = "Air Temperature",
    dewpt          = "Dew Point",
    heatindex      = "Heat Index",
    windchill      = "Wind Chill",
    humidity       = "Relative Humidity",
    windspeed      = "Wind Speed",
    windgust       = "Wind Gust",
    winddir        = "Wind Direction",
    pressure       = "Barometric Pressure",
    preciprate     = "Precipitation Rate",
    preciptotal    = "Precipitation Total",
    solarradiation = "Solar Radiation",
    uv             = "UV Index",
    b)
}

# --- Single-column metadata ---------------------------------------------------

#' Return list(category, label, unit) for one column name.
param_meta <- function(col, units = "m") {

  ident <- c("epoch", "obsTimeUtc", "obsTimeLocal", "stationID", "neighborhood",
             "country", "lat", "lon", "qcStatus", "softwareType", "elev", "tz",
             "time_local", "time_utc", "time_epoch", "source", "row_id")

  if (col %in% ident) {
    lab <- switch(col,
      epoch        = "Unix Epoch",
      obsTimeUtc   = "Observation Time (UTC)",
      obsTimeLocal = "Observation Time (station local)",
      stationID    = "Station ID",
      neighborhood = "Location Name",
      country      = "Country",
      lat          = "Latitude",
      lon          = "Longitude",
      qcStatus     = "QC Status",
      softwareType = "Software Type",
      elev         = "Elevation",
      tz           = "Station Timezone",
      time_local   = "Time (station local)",
      time_utc     = "Time (UTC)",
      time_epoch   = "Unix Epoch",
      source       = "Data Source",
      row_id       = "Row ID",
      col)
    u <- if (col == "elev") .unit(units, "m", "ft") else ""
    return(list(category = CAT_TIME, label = lab, unit = u))
  }

  if (col == "pressureTrend") {
    return(list(category = CAT_PRESS, label = "Pressure Trend",
                unit = .unit(units, "hPa", "inHg")))
  }

  # Split the aggregate suffix (High/Low/Avg/Max/Min) from the base name.
  m <- regmatches(col, regexec("^(.*?)(High|Low|Avg|Max|Min)$", col))[[1]]
  if (length(m) == 3L) { base <- m[2]; sfx <- m[3] } else { base <- col; sfx <- "" }

  lab <- paste0(.base_label(base), .agg_label(sfx))

  switch(tolower(base),
    temp           = list(category = CAT_TEMP,  label = lab, unit = .unit(units, "\u00b0C", "\u00b0F")),
    dewpt          = list(category = CAT_TEMP,  label = lab, unit = .unit(units, "\u00b0C", "\u00b0F")),
    heatindex      = list(category = CAT_TEMP,  label = lab, unit = .unit(units, "\u00b0C", "\u00b0F")),
    windchill      = list(category = CAT_TEMP,  label = lab, unit = .unit(units, "\u00b0C", "\u00b0F")),
    humidity       = list(category = CAT_HUM,   label = lab, unit = "%"),
    windspeed      = list(category = CAT_WIND,  label = lab, unit = .unit(units, "km/h", "mph")),
    windgust       = list(category = CAT_WIND,  label = lab, unit = .unit(units, "km/h", "mph")),
    winddir        = list(category = CAT_WIND,  label = lab, unit = "\u00b0"),
    pressure       = list(category = CAT_PRESS, label = lab, unit = .unit(units, "hPa", "inHg")),
    preciprate     = list(category = CAT_RAIN,  label = lab, unit = .unit(units, "mm/h", "in/h")),
    preciptotal    = list(category = CAT_RAIN,  label = lab, unit = .unit(units, "mm", "in")),
    solarradiation = list(category = CAT_RAD,   label = lab, unit = "W/m\u00b2"),
    uv             = list(category = CAT_RAD,   label = lab, unit = "index"),
    list(category = CAT_OTHER, label = col, unit = "")
  )
}

# --- Metadata table for a whole column set ------------------------------------

#' data.frame(param, category, label, unit, series_label) for a vector of names.
param_table <- function(cols, units = "m") {
  cols <- unique(cols)
  if (!length(cols)) {
    return(data.frame(param = character(), category = character(), label = character(),
                      unit = character(), series_label = character(),
                      cat_rank = integer(), stringsAsFactors = FALSE))
  }
  rows <- lapply(cols, function(cl) {
    m <- param_meta(cl, units)
    data.frame(param = cl, category = m$category, label = m$label, unit = m$unit,
               stringsAsFactors = FALSE)
  })
  df <- do.call(rbind, rows)
  df$cat_rank <- match(df$category, CAT_ORDER)
  df$series_label <- ifelse(nzchar(df$unit),
                            paste0(df$label, " (", df$unit, ")"),
                            df$label)
  df <- df[order(df$cat_rank, df$param), , drop = FALSE]
  rownames(df) <- NULL
  df
}

# --- Recommended parameters ---------------------------------------------------

#' A sensible default set for drying / crop-monitoring style workflows.
#' Matching is case-insensitive because the API is not consistent with casing
#' (tempAvg vs windspeedAvg).
default_params <- function(cols) {
  cand <- c("temp", "tempavg", "humidity", "humidityavg",
            "dewpt", "dewptavg",
            "solarradiation", "solarradiationhigh", "uv", "uvhigh",
            "windspeed", "windspeedavg", "winddir", "winddiravg",
            "preciptotal", "preciprate",
            "pressure", "pressureavg")
  cols[tolower(cols) %in% cand]
}

# =============================================================================
#  Timezone detection
# =============================================================================

#' Read the station timezone from the flattened data (the API returns a `tz`
#' field per observation). Falls back to STATION_TZ when absent.
#'
#' This keeps the app portable: no timezone is hard-coded, so the same build
#' works for any station worldwide.
detect_tz <- function(d, fallback = STATION_TZ) {
  if (is.data.frame(d) && "tz" %in% names(d)) {
    z <- unique(stats::na.omit(as.character(d$tz)))
    z <- z[nzchar(z)]
    if (length(z)) return(z[1])
  }
  fallback
}

# =============================================================================
#  Data resolution & interval
#
#  IMPORTANT: every endpoint has a DIFFERENT resolution. This is not an
#  application setting you can change -- if an endpoint returns hourly
#  aggregates, the underlying ~5 minute samples cannot be recovered from it.
#
#     observations/all/1day  -> raw per-upload samples (~5 min)
#     history/all            -> raw per-upload samples (~5 min)
#     history/hourly         -> hourly aggregate   (NOT 5 min)
#     history/daily          -> daily aggregate    (NOT 5 min)
#
#  Real-world case: a downloaded XLSX looked hourly while the on-screen preview
#  showed 5 minute rows. The data had been fetched from history/hourly.
#  Resolution is therefore surfaced in the UI and written into the XLSX itself.
# =============================================================================

ENDPOINT_RESOLUTION <- c(
  "observations/current"  = "instant value \u2014 1 row",
  "observations/all/1day" = "~5 min detail",
  "history/all"           = "~5 min detail",
  "history/hourly"        = "hourly aggregate",
  "history/daily"         = "daily aggregate"
)

#' Match the `source` label stored inside the data (e.g. "history/all 2026-09-19")
#' against the keys of ENDPOINT_RESOLUTION.
endpoint_key <- function(ep) {
  if (is.null(ep) || !length(ep) || all(is.na(ep))) return(NA_character_)
  e <- as.character(ep[1])
  hit <- names(ENDPOINT_RESOLUTION)[
    vapply(names(ENDPOINT_RESOLUTION), function(k) startsWith(e, k), logical(1))]
  if (length(hit)) hit[1] else NA_character_
}

endpoint_resolution <- function(ep) {
  k <- endpoint_key(ep)
  if (is.na(k)) return("unknown")
  unname(ENDPOINT_RESOLUTION[[k]])
}

endpoint_slug <- function(ep) {
  k <- endpoint_key(ep)
  if (is.na(k)) return("data")
  switch(k,
    "observations/current"  = "current",
    "observations/all/1day" = "today",
    "history/all"           = "detail",
    "history/hourly"        = "hourly",
    "history/daily"         = "daily",
    "data")
}

#' TRUE when the endpoint returns raw ~5 minute samples.
is_detail5 <- function(ep) {
  k <- endpoint_key(ep)
  !is.na(k) && k %in% c("observations/all/1day", "history/all")
}

#' Median gap between observations, in minutes. NA when fewer than 2 timestamps.
median_interval_mins <- function(d) {
  if (!is.data.frame(d) || !"time_local" %in% names(d)) return(NA_real_)
  tt <- as.POSIXct(d$time_local)
  tt <- sort(tt[!is.na(tt)])
  if (length(tt) < 2L) return(NA_real_)
  dd <- as.numeric(difftime(tt[-1], tt[-length(tt)], units = "mins"))
  dd <- dd[is.finite(dd) & dd > 0]
  if (!length(dd)) return(NA_real_)
  stats::median(dd)
}

#' Human-readable interval label.
fmt_interval <- function(m) {
  if (is.null(m) || !length(m) || !is.finite(m)) return("\u2014")
  if (m < 1)    return(paste0(round(m * 60), " sec"))
  if (m < 90)   return(paste0(round(m), " min"))
  if (m < 2160) return(paste0(formatC(m / 60, format = "f", digits = 1,
                                      decimal.mark = "."), " h"))
  paste0(formatC(m / 1440, format = "f", digits = 1, decimal.mark = "."), " d")
}

#' Provenance and resolution summary. Shared by the UI (tab 2) and the `info`
#' sheet inside the XLSX so the two can never disagree.
describe_data <- function(d) {
  ep <- character()
  if (is.data.frame(d) && "source" %in% names(d)) {
    ep <- unique(stats::na.omit(as.character(d$source)))
    ep <- ep[nzchar(ep)]
  }
  tt <- if (is.data.frame(d) && "time_local" %in% names(d)) {
    x <- as.POSIXct(d$time_local); x[!is.na(x)]
  } else as.POSIXct(character())

  list(
    endpoint     = ep,
    endpoint_txt = if (length(ep)) paste(ep, collapse = " + ") else "\u2014",
    resolution   = endpoint_resolution(ep),
    slug         = endpoint_slug(ep),
    detail5      = is_detail5(ep),
    interval     = median_interval_mins(d),
    n            = if (is.data.frame(d)) nrow(d) else 0L,
    ncol         = if (is.data.frame(d)) ncol(d) else 0L,
    tz           = detect_tz(d),
    t_start      = if (length(tt)) min(tt) else as.POSIXct(NA),
    t_end        = if (length(tt)) max(tt) else as.POSIXct(NA)
  )
}

#' Contents of the `info` sheet in the XLSX. Makes the file self-describing:
#' without it, a downloaded XLSX cannot be told apart from one fetched at a
#' different resolution (raw ~5 min vs hourly aggregate).
#'
#' Provenance (endpoint/resolution) MUST be read from `src_d` = the FULL data
#' set, not from `d` = the selected columns: `source` is not part of the
#' selection, so reading it from `d` always yields "unknown".
info_sheet <- function(d, cfg, src_d = d) {
  m  <- describe_data(src_d)
  mi <- describe_data(d)
  fmt_dt <- function(x) if (is.na(x)) "\u2014" else format(x, "%Y-%m-%d %H:%M:%S")

  data.frame(
    field = c("Station", "Source endpoint", "Data resolution",
              "Row count", "Column count (data sheet)",
              "Median interval between observations",
              "Start time (station local)",
              "End time (station local)",
              "Timezone", "Unit system", "Downloaded at"),
    value = c(
      cfg$station_id %||% "\u2014", m$endpoint_txt, m$resolution,
      as.character(mi$n), as.character(mi$ncol),
      fmt_interval(mi$interval),
      fmt_dt(mi$t_start), fmt_dt(mi$t_end),
      mi$tz,
      switch(cfg$units %||% "m", m = "Metric", e = "Imperial",
             h = "UK Hybrid", cfg$units %||% "m"),
      format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
    stringsAsFactors = FALSE)
}
