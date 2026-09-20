# Installation

Complete setup guide for **ws-wu-download**, including the failure modes that
actually happen.

---

## 1. Prerequisites

| Requirement | Version | Why |
|-------------|---------|-----|
| **R** | **>= 4.1** | The code uses the native pipe `\|>` |
| R packages | 15, listed below | |
| A Weather Underground PWS station | — | Must be publishing data |
| The Weather Company API key | — | See section 3 |

Check your R version and architecture:

```bash
R --version | head -1
Rscript -e 'cat(R.version$arch, "\n")'
```

On Apple Silicon you want `aarch64-apple-darwin20`. An Intel build of R running
under Rosetta will install packages painfully slowly and may fail to compile
`ragg` and `ggplot2` altogether.

### Installing R on macOS

Download from CRAN and pick the **arm64** build on Apple Silicon:

- Apple Silicon: <https://cran.r-project.org/bin/macosx/big-sur-arm64/base/>
- Intel: <https://cran.r-project.org/bin/macosx/>

---

## 2. Install the R packages

```bash
Rscript -e 'install.packages(c(
  "shiny", "bslib", "plotly", "DT",
  "dplyr", "tidyr", "tibble", "ggplot2", "lubridate",
  "httr2", "jsonlite", "readxl", "writexl",
  "ragg", "shinycssloaders"
), repos = "https://cloud.r-project.org")'
```

Expect **10-20 minutes** on the first run — `ragg` and `ggplot2` compile C/C++
from source.

Verify:

```bash
Rscript -e 'p <- c("shiny","bslib","plotly","DT","dplyr","tidyr","tibble",
  "ggplot2","lubridate","httr2","jsonlite","readxl","writexl","ragg",
  "shinycssloaders");
  miss <- p[!vapply(p, requireNamespace, logical(1), quietly=TRUE)];
  if (length(miss)) cat("MISSING:", paste(miss, collapse=", "), "\n") else cat("All 15 packages present\n")'
```

---

## 3. Get an API key and station ID

1. Your station must publish to Weather Underground. Its **station ID** looks
   like `IXXXXXXXX` — it is in the URL of your station dashboard.
2. Request an API key for the **PWS** product from The Weather Company
   (Weather Underground developer portal).
3. Check which products your key is entitled to. Not every subscription includes
   every endpoint — see section 6.

> **Note on endpoint availability.** Some PWS endpoints require a specific
> subscription tier. If an endpoint returns HTTP **401**, the key is valid but
> not entitled to that product. The app surfaces this as a clear message rather
> than a crash. There is usually a working alternative: for example
> `history/hourly` provides hourly aggregates even where
> `observations/hourly/1day` is not entitled.

---

## 4. Configure

```bash
cp config.example.json config.json
```

Edit `config.json`:

```json
{
  "api_key": "your-api-key",
  "station_id": "your-station-id",
  "units": "m",
  "numeric_precision": "decimal"
}
```

| Key | Values | Notes |
|-----|--------|-------|
| `api_key` | string | Required |
| `station_id` | string | Required, case-insensitive |
| `units` | `m` / `e` / `h` | metric / imperial / UK hybrid |
| `numeric_precision` | `decimal` | **Only `decimal` is accepted** |

Environment variables override the file, which is handy for deployment:

```bash
export WC_API_KEY="your-api-key"
export WC_STATION_ID="your-station-id"
export WC_UNITS="m"
export WC_TZ="Europe/Amsterdam"   # optional fallback timezone
```

`config.json` is git-ignored. **Never commit it.**

---

## 5. Run

```bash
cd ws-wu-download
Rscript -e 'shiny::runApp(".", port = 8085, launch.browser = TRUE)'
```

Then open <http://127.0.0.1:8085>.

Self-test first if you prefer:

```bash
Rscript tests/smoke_test.R
```

This works **with or without** credentials: with them it runs 68 assertions
including live API calls; without them it runs 46 offline assertions covering the
parameter catalogue, the plot builder, PNG and XLSX export and the resolution
helpers.

---

## 6. Which endpoints actually work

Every endpoint has a different native resolution. This is an API constraint, not
an app setting.

| Need | Endpoint | Resolution |
|------|----------|------------|
| Latest reading | `v2/pws/observations/current` | instant, 1 row |
| Today | `v2/pws/observations/all/1day` | **~5 min raw** |
| History detail | `v2/pws/history/all` | **~5 min raw** |
| Hourly history | `v2/pws/history/hourly` | hourly aggregate |
| Daily history | `v2/pws/history/daily` | daily aggregate |

**If you want ~5 minute data, use Today or History detail.** The aggregate
endpoints cannot give you the raw samples back — that information is not in the
response.

### Retention

The raw endpoints keep only a short window — expect **a few days**. Data older
than the retention window is gone permanently and cannot be retrieved later. If
you need a long series, collect it on a schedule rather than trying to backfill.

### Date format

`YYYYMMDD`, not ISO. `history/all` takes one date per request; the range
endpoints accept up to **31 days** per request.

---

## 7. Troubleshooting

### The app starts but the page is blank or the log shows `cannot open the connection`

The `R/` sub-folder is missing or empty. `app.R` calls `source()` on three files
inside it. When extracting a zip, make sure the folder structure is preserved:

```
ws-wu-download/
├── app.R
└── R/
    ├── api.R
    ├── params.R
    └── plot.R
```

### `unexpected input` / syntax errors on startup

Your R is older than 4.1. The code uses the native pipe `|>`. Check with
`R --version`.

### `there is no package called 'ragg'`

Not fatal — `save_plot_png()` falls back to base R `png()`. But on macOS base R
does **not** write the PNG `pHYs` chunk, so the file has no DPI metadata and
PowerPoint will treat it as 72 dpi and insert it at roughly eight times the
intended physical size. Install `ragg`:

```bash
Rscript -e 'install.packages("ragg", repos="https://cloud.r-project.org")'
```

### "No data" — is my key broken?

Almost certainly not. Check the HTTP code:

- **204** — the server has no data. Usually the station is offline, or the range
  is outside retention. Not an authentication problem.
- **200 with an empty `observations` array** — same meaning, different status
  code. The status code for an empty date is **not consistent**.
- **401** — the key is not entitled to this product. This *is* a key problem.
- **400** — a bad request parameter.

API-level errors can also arrive as HTTP 200 with `{"errors":[...]}` in the body.

### The downloaded spreadsheet looks hourly but the preview shows 5 minute rows

You fetched from an aggregate endpoint. Check the `info` sheet inside the
workbook — it records the source endpoint and the median interval. Re-fetch with
**Today** or **History detail** for ~5 minute data.

This is exactly why the `info` sheet exists: once a file has been saved and
emailed, nothing else records where it came from.

### Some rows have every sensor `NA`

Those are heartbeat uploads. `qcStatus` distinguishes them: `-1` means the row
carries measurements, `1` means it does not. The app keeps these rows
deliberately so the gap is visible; the `summary` sheet reports the missing
count per parameter. Filter them out with `qcStatus == -1` if you want only real
measurements.

### The `info` sheet says "unknown" for the source endpoint

That should not happen — it is covered by a regression test. It would mean the
`source` column is missing from the fetched data. Please open an issue with the
output of `Rscript tests/smoke_test.R`.

### `values must be length 1, but FUN(X[[3]]) result is length 0`

Fixed. It happened when `config.json` explicitly contained
`"numeric_precision": null`, because `as.character(NULL)` yields `character(0)`.
If you see it, you are running an old version — update.

### Times are off by a fixed number of hours after exporting to Excel

Excel does not store timezones. `readxl` labels the Excel serial as `UTC`, so an
absolute comparison shows an offset even though no data was lost. The wall-clock
reading round-trips correctly, and that is what the test asserts. If you need
absolute instants, use the `time_utc` or `epoch` column.

### Port already in use

```bash
Rscript -e 'shiny::runApp(".", port = 8086, launch.browser = TRUE)'
```

---

## 8. Data notes worth knowing before you analyse anything

- **The upload interval is not uniform.** Observed gaps ranged from 2 to 112
  minutes on a single station. Never assume a fixed sampling rate, and
  deduplicate on `epoch` rather than on a timestamp.
- **Aggregate endpoints report High/Low/Avg per interval**, not instantaneous
  values. There is no plain `temp` field in those responses — use `tempAvg`.
- **Field naming is inconsistent** (`tempAvg` but `windspeedAvg`), which is why
  parameter matching is case-insensitive.
- **The station timezone comes from the API** (`tz` field), so nothing is
  hard-coded. `WC_TZ` only supplies a fallback for the rare response that omits
  it.
- **`numericPrecision` accepts only `decimal`.**

---

## 9. A note on derived parameters

The app fetches and exports what the API provides. It does not compute derived
quantities, so if you need something like **VPD** (vapour pressure deficit), you
can compute it from the exported columns.

VPD is often more informative than temperature alone for drying and
evapotranspiration work, because it captures the actual evaporative driving force
rather than just the heat.

```r
# VPD in kPa from temperature (deg C) and relative humidity (%)
vpd_kpa <- function(temp_c, rh) {
  es <- 6.112 * exp(17.67 * temp_c / (temp_c + 243.5))  # saturation vapour
                                                        # pressure, hPa
  es * (1 - rh / 100) / 10                              # -> kPa
}
```

Note the `/ 10`: the Magnus formula returns hPa, not kPa. Forgetting it gives an
answer ten times too large.
