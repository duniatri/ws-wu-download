# =============================================================================
#  R/plot.R  --  Trend visualisation
#
#  Single source of truth: build_trend_plot() returns a ggplot object.
#  Interactive view = ggplotly(the same object)
#  PNG export       = ggsave(the same object)
#  So what you see is what gets saved.
# =============================================================================

# --- Safe statistics helpers (avoid Inf/-Inf when everything is NA) -----------

.safe_min <- function(x) { x <- x[is.finite(x)]; if (!length(x)) NA_real_ else min(x) }
.safe_max <- function(x) { x <- x[is.finite(x)]; if (!length(x)) NA_real_ else max(x) }
.safe_mean <- function(x) { x <- x[is.finite(x)]; if (!length(x)) NA_real_ else mean(x) }

.o <- function(opts, key, default) if (is.null(opts[[key]])) default else opts[[key]]

# --- Temporal aggregation -----------------------------------------------------

AGG_CHOICES <- c(
  "Raw data (server interval)"                   = "raw",
  "Hourly average"                               = "hourly",
  "Daily average"                                = "daily",
  "Daily range (average + min\u2013max)"          = "daily_range"
)

.agg_series <- function(long, agg) {
  if (agg == "raw") return(long)

  if (agg == "hourly") {
    return(long |>
      dplyr::mutate(t = lubridate::floor_date(time_local, "hour")) |>
      dplyr::group_by(t, param, series_label) |>
      dplyr::summarise(value = .safe_mean(value), .groups = "drop") |>
      dplyr::rename(time_local = t))
  }
  if (agg == "daily") {
    return(long |>
      dplyr::mutate(t = lubridate::floor_date(time_local, "day")) |>
      dplyr::group_by(t, param, series_label) |>
      dplyr::summarise(value = .safe_mean(value), .groups = "drop") |>
      dplyr::rename(time_local = t))
  }
  if (agg == "daily_range") {
    return(long |>
      dplyr::mutate(t = lubridate::floor_date(time_local, "day")) |>
      dplyr::group_by(t, param, series_label) |>
      dplyr::summarise(lo = .safe_min(value),
                       hi = .safe_max(value),
                       value = .safe_mean(value), .groups = "drop") |>
      dplyr::rename(time_local = t))
  }
  long
}

# --- X axis break picker ------------------------------------------------------

.x_scale <- function(time_vec) {
  rng <- suppressWarnings(range(as.POSIXct(time_vec), na.rm = TRUE))
  span_h <- as.numeric(difftime(rng[2], rng[1], units = "hours"))
  if (!is.finite(span_h) || span_h <= 0) span_h <- 24

  if (span_h <= 36)          list(brk = "1 hour",  lab = "%H:%M")
  else if (span_h <= 24 * 8) list(brk = "6 hours", lab = "%d %b\n%H:%M")
  else if (span_h <= 24 * 45) list(brk = "1 day",  lab = "%d %b")
  else                        list(brk = "1 week", lab = "%d %b")
}

# --- Build the plot -----------------------------------------------------------

#' @param df     tibble (must contain a time_local column)
#' @param params vector of column names to plot
#' @param pmeta  data.frame from param_table()
#' @param opts   list(agg, facet, normalize, points, title, subtitle)
#' @return list(plot, dropped, n_series, n_params), or NULL when no valid data
build_trend_plot <- function(df, params, pmeta, opts = list()) {

  agg       <- .o(opts, "agg", "raw")
  facet     <- isTRUE(opts$facet)
  normalize <- isTRUE(opts$normalize)
  points    <- isTRUE(opts$points)
  title     <- .o(opts, "title", "")
  subtitle  <- .o(opts, "subtitle", "")

  params <- intersect(params, names(df))
  if (!length(params) || !"time_local" %in% names(df)) return(NULL)

  meta <- pmeta[pmeta$param %in% params, , drop = FALSE]
  # Time and identity columns are never plotted (CAT_TIME), and only numeric
  # columns can be plotted. This also stops pivot_longer from trying to mix
  # datetime values with doubles.
  meta <- meta[meta$category != CAT_TIME, , drop = FALSE]
  meta <- meta[vapply(df[meta$param], is.numeric, logical(1)), , drop = FALSE]
  params <- meta$param
  if (!length(params)) return(NULL)

  long <- df[, c("time_local", params), drop = FALSE] |>
    tidyr::pivot_longer(cols = dplyr::all_of(params),
                        names_to = "param", values_to = "value") |>
    dplyr::left_join(meta[, c("param", "series_label")], by = "param")

  long <- .agg_series(long, agg)

  # Drop series that are entirely empty (sensor not fitted / null)
  keep <- long |>
    dplyr::group_by(param) |>
    dplyr::summarise(n_ok = sum(is.finite(value)), .groups = "drop") |>
    dplyr::filter(n_ok > 0)
  dropped <- setdiff(unique(long$param), keep$param)
  long <- long[long$param %in% keep$param, , drop = FALSE]
  if (nrow(long) == 0L) return(NULL)

  n_par <- length(unique(long$param))

  # Normalisation only makes sense when overlaying parameters with different units
  if (normalize && n_par > 1L && !facet) {
    long <- long |>
      dplyr::group_by(param) |>
      dplyr::mutate(value = as.numeric(scale(value))) |>
      dplyr::ungroup()
    long$series_label <- paste0(long$series_label, " [z]")
    ylab <- "Normalised value (z-score)"
  } else if (n_par == 1L) {
    ylab <- meta$series_label[match(unique(long$param), meta$param)][1]
  } else {
    ylab <- "Value"
  }

  # For daily_range the ribbon needs lo/hi that were not normalised
  has_band <- agg == "daily_range" && all(c("lo", "hi") %in% names(long))
  if (has_band && normalize && n_par > 1L && !facet) has_band <- FALSE

  p <- ggplot2::ggplot(long, ggplot2::aes(x = time_local, y = value,
                                          colour = series_label))

  if (has_band) {
    p <- p + ggplot2::geom_ribbon(
      ggplot2::aes(ymin = lo, ymax = hi, fill = series_label),
      alpha = 0.15, colour = NA)
  }

  p <- p + ggplot2::geom_line(linewidth = 0.7)

  if (points && agg == "raw") {
    p <- p + ggplot2::geom_point(size = 1.1, alpha = 0.55)
  }

  if (facet && n_par > 1L) {
    p <- p + ggplot2::facet_wrap(~series_label, scales = "free_y", ncol = 1)
  }

  n_ser <- length(unique(long$series_label))
  pal <- if (n_ser <= 8) "Dark2" else "Set3"

  xs <- .x_scale(long$time_local)

  p <- p +
    ggplot2::scale_colour_brewer(palette = pal) +
    ggplot2::scale_fill_brewer(palette = pal) +
    ggplot2::scale_x_datetime(date_breaks = xs$brk, date_labels = xs$lab) +
    ggplot2::labs(title = title, subtitle = subtitle, x = NULL, y = ylab,
                  colour = NULL, fill = NULL) +
    ggplot2::theme_minimal(base_size = 12) +
    ggplot2::theme(
      legend.position  = if (facet && n_par > 1L) "none" else "bottom",
      legend.text      = ggplot2::element_text(size = 9),
      panel.grid.minor = ggplot2::element_blank(),
      plot.title       = ggplot2::element_text(face = "bold", size = 13),
      plot.subtitle    = ggplot2::element_text(size = 9, colour = "grey35"),
      plot.margin      = ggplot2::margin(10, 14, 8, 8)
    )

  list(plot = p, dropped = dropped, n_series = n_ser, n_params = n_par)
}

# --- PNG export ---------------------------------------------------------------

#' Save a ggplot object to PNG. Uses ragg when available: it writes DPI
#' metadata correctly (base R png() does not on macOS, which makes PowerPoint
#' treat the image as 72 dpi and insert it at the wrong physical size) and it
#' handles Unicode labels safely.
save_plot_png <- function(plot_obj, path, width_in, height_in, dpi) {
  device <- if (requireNamespace("ragg", quietly = TRUE)) ragg::agg_png else NULL
  ggplot2::ggsave(
    filename = path, plot = plot_obj,
    width = width_in, height = height_in, units = "in", dpi = dpi,
    bg = "white", device = device, limitsize = FALSE
  )
  path
}
