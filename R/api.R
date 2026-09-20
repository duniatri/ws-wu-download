# =============================================================================
#  R/api.R  --  API client for The Weather Company / Weather Underground PWS v2
#
#  Key findings from direct verification (see docs/FIELD-NOTES.md):
#   - Auth is via the `apiKey` query parameter, not a header
#   - Unit-bearing fields live in a sub-object (`metric` / `imperial` /
#     `uk_hybrid`); unit-less fields live at the root
#   - HTTP 204 = no data (NOT an authentication failure)
#   - HTTP 401 = the API key is not entitled to the product
#   - API-level errors can arrive as HTTP 200 with {"errors":[...]}
#   - `numericPrecision` only accepts "decimal"
# =============================================================================

WC_BASE <- "https://api.weather.com"

# --- HTTP layer ---------------------------------------------------------------

#' Call a single PWS endpoint. Always returns a structured list and never
#' throws, so the UI can surface a clear message instead of a stack trace.
#'
#' @return list(ok, status, code, message, observations)
wc_request <- function(path, params, api_key, timeout_s = 30) {

  q <- c(params, list(format = "json", apiKey = api_key))

  # Drop NULL parameters. Without this, as.character(NULL) yields character(0)
  # and the vapply() below fails with a cryptic "values must be length 1"
  # instead of simply omitting the parameter. Real trigger: a config.json that
  # explicitly contains "numeric_precision": null.
  if (length(q)) q <- q[!vapply(q, is.null, logical(1))]

  # The query string is built by hand so encoding is deterministic and does not
  # depend on dynamic dots.
  enc <- function(x) utils::URLencode(as.character(x), reserved = TRUE)
  qs  <- paste0(names(q), "=", vapply(q, enc, character(1)), collapse = "&")
  url <- paste0(WC_BASE, path, "?", qs)

  req <- httr2::request(url)
  req <- httr2::req_headers(req,
                            `Accept-Encoding` = "gzip",
                            `User-Agent`      = "ws-wu-download/1.0")
  req <- httr2::req_timeout(req, timeout_s)
  req <- httr2::req_error(req, is_error = function(resp) FALSE)  # classify manually

  resp <- tryCatch(httr2::req_perform(req), error = function(e) e)

  if (inherits(resp, "error")) {
    return(list(ok = FALSE, status = NA_integer_, code = "network",
                message = paste("Could not reach the server:",
                                conditionMessage(resp)),
                observations = list()))
  }

  status <- httr2::resp_status(resp)
  # 204 has no body -- resp_body_string() throws if called on it directly
  body <- tryCatch(httr2::resp_body_string(resp), error = function(e) "")

  if (status == 204L) {
    return(list(ok = TRUE, status = 204L, code = "empty",
                message = paste("HTTP 204 \u2014 the server has no data for this request.",
                                "Common causes: the station is offline, or the time range",
                                "falls outside the data retention window."),
                observations = list()))
  }
  if (status == 401L) {
    return(list(ok = FALSE, status = 401L, code = "unauthorized",
                message = paste("HTTP 401 \u2014 the API key is not entitled to this endpoint.",
                                "The product is probably not part of your subscription."),
                observations = list()))
  }
  if (status == 400L) {
    return(list(ok = FALSE, status = 400L, code = "bad_request",
                message = paste("HTTP 400 \u2014 invalid request parameters.",
                                substr(body, 1, 300)),
                observations = list()))
  }
  if (status == 429L) {
    return(list(ok = FALSE, status = 429L, code = "rate_limit",
                message = "HTTP 429 \u2014 rate limit exceeded. Try again shortly.",
                observations = list()))
  }
  if (status >= 500L) {
    return(list(ok = FALSE, status = status, code = "server_error",
                message = paste0("HTTP ", status, " \u2014 server-side failure."),
                observations = list()))
  }
  if (status != 200L) {
    return(list(ok = FALSE, status = status, code = "http_error",
                message = paste0("HTTP ", status, " \u2014 ", substr(body, 1, 300)),
                observations = list()))
  }

  json <- tryCatch(jsonlite::fromJSON(body, simplifyVector = FALSE),
                   error = function(e) NULL)
  if (is.null(json)) {
    return(list(ok = FALSE, status = 200L, code = "bad_json",
                message = "Response is not valid JSON.",
                observations = list()))
  }

  # API-level errors can arrive with HTTP 200
  if (!is.null(json$errors)) {
    msg <- paste(vapply(json$errors, function(e) {
      if (is.list(e)) paste(unlist(e), collapse = " | ") else as.character(e)
    }, character(1)), collapse = "; ")
    return(list(ok = FALSE, status = 200L, code = "api_error",
                message = paste("Server returned an error (HTTP 200):", msg),
                observations = list()))
  }

  obs <- json$observations
  if (is.null(obs) || length(obs) == 0L) {
    return(list(ok = TRUE, status = 200L, code = "empty",
                message = paste("Request succeeded but returned no observations",
                                "for this range (likely outside the retention window)."),
                observations = list()))
  }

  list(ok = TRUE, status = 200L, code = "ok",
       message = paste(length(obs), "observations received."),
       observations = obs)
}

# --- JSON normalisation -------------------------------------------------------

# Unit-bearing fields are nested in a sub-object. Flatten to a single level.
.flatten_one <- function(o) {
  unit_keys <- c("metric", "imperial", "uk_hybrid")
  out <- list()
  for (nm in names(o)) {
    v <- o[[nm]]
    if (nm %in% unit_keys && is.list(v)) {
      for (nm2 in names(v)) out[[nm2]] <- v[[nm2]]
    } else if (!is.null(v) && !is.list(v)) {
      out[[nm]] <- v
    }
  }
  out
}

.to_num <- function(x) {
  if (is.list(x)) {
    x <- vapply(x, function(z) if (is.null(z)) NA_real_ else as.numeric(z)[1],
                numeric(1))
  }
  if (!is.numeric(x)) x <- suppressWarnings(as.numeric(as.character(x)))
  x
}

#' Turn the raw observation list into a tibble with one row per observation.
flatten_observations <- function(obs, source_label = NA_character_) {
  if (length(obs) == 0L) return(tibble::tibble())

  df <- dplyr::bind_rows(lapply(obs, .flatten_one))
  if (nrow(df) == 0L) return(tibble::tibble())

  # The station timezone comes from the API response itself when present, so
  # nothing is hard-coded and the same build works for any station worldwide.
  tz_use <- detect_tz(df)

  # --- time columns
  if ("obsTimeLocal" %in% names(df)) {
    df$time_local <- as.POSIXct(df$obsTimeLocal, format = "%Y-%m-%d %H:%M:%S",
                                tz = tz_use)
  }
  if ("obsTimeUtc" %in% names(df)) {
    df$time_utc <- as.POSIXct(df$obsTimeUtc, format = "%Y-%m-%d %H:%M:%S",
                              tz = "UTC")
  }
  if ("epoch" %in% names(df)) {
    df$time_epoch <- as.POSIXct(.to_num(df$epoch), origin = "1970-01-01",
                                tz = "UTC")
  }
  if (!"time_local" %in% names(df) && "time_epoch" %in% names(df)) {
    df$time_local <- lubridate::with_tz(df$time_epoch, tz_use)
  }

  # --- numeric coercion for everything except text and derived time columns
  #     (time columns MUST be excluded: as.numeric(POSIXct) destroys them)
  txt <- c("obsTimeUtc", "obsTimeLocal", "stationID", "neighborhood",
           "country", "softwareType", "tz",
           "time_local", "time_utc", "time_epoch", "source")
  for (nm in setdiff(names(df), txt)) df[[nm]] <- .to_num(df[[nm]])

  df$source <- source_label

  # --- dedupe + chronological order
  key <- if ("epoch" %in% names(df)) "epoch" else "time_local"
  df <- df[!duplicated(df[[key]]), , drop = FALSE]
  if ("time_local" %in% names(df)) df <- df[order(df$time_local), , drop = FALSE]

  # --- column order: time & identity first
  front <- intersect(c("time_local", "time_utc", "time_epoch", "source",
                       "stationID", "neighborhood", "country",
                       "lat", "lon", "qcStatus", "tz"), names(df))
  df <- df[, c(front, setdiff(names(df), front)), drop = FALSE]

  tibble::as_tibble(df)
}

# --- Per-endpoint wrappers ----------------------------------------------------

.base_params <- function(cfg) {
  list(stationId        = cfg$station_id,
       units            = cfg$units,
       numericPrecision = cfg$numeric_precision)
}

wc_current <- function(cfg) {
  wc_request("/v2/pws/observations/current", .base_params(cfg), cfg$api_key)
}

wc_today <- function(cfg) {
  wc_request("/v2/pws/observations/all/1day", .base_params(cfg), cfg$api_key)
}

wc_history_all <- function(cfg, date) {
  # as.Date() with origin is safe for both Date and numeric input
  date <- as.Date(date, origin = "1970-01-01")
  wc_request("/v2/pws/history/all",
             c(.base_params(cfg), list(date = format(date, "%Y%m%d"))),
             cfg$api_key)
}

wc_history_hourly <- function(cfg, start, end) {
  start <- as.Date(start, origin = "1970-01-01")
  end   <- as.Date(end,   origin = "1970-01-01")
  wc_request("/v2/pws/history/hourly",
             c(.base_params(cfg), list(startDate = format(start, "%Y%m%d"),
                                       endDate   = format(end,   "%Y%m%d"))),
             cfg$api_key)
}

wc_history_daily <- function(cfg, start, end) {
  start <- as.Date(start, origin = "1970-01-01")
  end   <- as.Date(end,   origin = "1970-01-01")
  wc_request("/v2/pws/history/daily",
             c(.base_params(cfg), list(startDate = format(start, "%Y%m%d"),
                                       endDate   = format(end,   "%Y%m%d"))),
             cfg$api_key)
}

# --- Fetch orchestration ------------------------------------------------------

MAX_RANGE_DAYS <- 31L

#' Fetch data for the selected source.
#'
#' @param source one of: current | today | detail | hourly | daily
#' @param start,end Date (used by detail/hourly/daily)
#' @param progress optional callback(Date) for the progress bar
#' @return list(df = tibble, log = data.frame)
fetch_weather <- function(cfg, source, start = NULL, end = NULL,
                          progress = NULL) {

  log_rows <- list()
  parts    <- list()

  record <- function(res, label) {
    log_rows[[length(log_rows) + 1L]] <<- data.frame(
      source   = label,
      http     = ifelse(is.na(res$status), "\u2014", as.character(res$status)),
      status   = if (res$ok) "OK" else "FAILED",
      message  = res$message,
      n        = length(res$observations),
      stringsAsFactors = FALSE
    )
    if (length(res$observations) > 0L) {
      parts[[length(parts) + 1L]] <<-
        flatten_observations(res$observations, label)
    }
  }

  if (source == "current") {
    record(wc_current(cfg), "observations/current")

  } else if (source == "today") {
    record(wc_today(cfg), "observations/all/1day")

  } else if (source == "detail") {
    days <- seq(as.Date(start, origin = "1970-01-01"),
                as.Date(end,   origin = "1970-01-01"), by = "day")
    if (length(days) > MAX_RANGE_DAYS) days <- days[seq_len(MAX_RANGE_DAYS)]
    # Iteration MUST use an index: `for (d in days)` over a Date vector strips
    # the Date class, so format(d, ...) fails.
    for (i in seq_along(days)) {
      d <- days[i]
      if (!is.null(progress)) progress(d)
      record(wc_history_all(cfg, d), paste0("history/all ", format(d, "%Y-%m-%d")))
      Sys.sleep(0.2)   # be polite to the rate limiter
    }

  } else if (source == "hourly") {
    record(wc_history_hourly(cfg, start, end), "history/hourly")

  } else if (source == "daily") {
    record(wc_history_daily(cfg, start, end), "history/daily")
  }

  df <- if (length(parts)) dplyr::bind_rows(parts) else tibble::tibble()

  if (nrow(df) > 0L && "time_local" %in% names(df)) {
    df <- df[!duplicated(df$time_local), , drop = FALSE]
    df <- df[order(df$time_local), , drop = FALSE]
  }

  list(df  = tibble::as_tibble(df),
       log = if (length(log_rows)) do.call(rbind, log_rows) else data.frame())
}
