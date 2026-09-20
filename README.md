# ws-wu-download

[![CI](https://github.com/duniatri/ws-wu-download/actions/workflows/ci.yml/badge.svg)](https://github.com/duniatri/ws-wu-download/actions/workflows/ci.yml)

An R Shiny app for **fetching, exploring and exporting data from a personal
weather station** published to Weather Underground, using The Weather Company
PWS API v2.

Fetch current readings or history, choose exactly which parameters you want,
export a self-describing `.xlsx`, and plot the trend as an interactive chart or
a high-resolution `.png`.

---

## Features

| # | Feature |
|---|---------|
| 1 | **Fetch any parameter the server exposes** — 5 data sources, 41 columns across 7 categories, with human-readable labels and units |
| 2 | **Export to `.xlsx`** — a `data` sheet (original API field names), an `info` sheet (provenance) and a `summary` sheet (counts, min, mean, median, max) |
| 3 | **Plot the trend and save it as `.png`** — interactive plotly view, aggregation (raw / hourly / daily / daily range), per-parameter panels, z-score overlay, and PNG export with control over width, height and dpi |

Plus quick-pick buttons (Select all / Clear / Recommended / Numeric only) and a
**Check station status** button that reports online/offline without disturbing
the data currently on screen.

---

## The thing that trips everyone up: data resolution

Every endpoint has a **different native resolution**, and it cannot be changed
from the app — it is an API constraint, not a setting.

| Source | Endpoint | Resolution |
|--------|----------|------------|
| Latest reading | `observations/current` | instant, 1 row |
| **Today** | `observations/all/1day` | **~5 min raw samples** |
| **History detail** | `history/all` | **~5 min raw samples** |
| Hourly history | `history/hourly` | hourly aggregate |
| Daily history | `history/daily` | daily aggregate |

`history/hourly` and `history/daily` return **server-computed aggregates**. The
underlying ~5 minute samples cannot be recovered from them. If you want ~5
minute data, use **Today** (current day only) or **History detail** (one request
per day).

This is a real failure mode: a downloaded spreadsheet looked hourly while the
on-screen preview showed 5 minute rows, because the data had been fetched from
`history/hourly`. Excel does not record where data came from, so the app now:

1. states the resolution in the source dropdown labels,
2. shows the endpoint and median interval in a banner above the download panel,
3. writes an `info` sheet **into the workbook itself**, so the file can explain
   its own provenance after it has been emailed around.

---

## Quick start

```bash
git clone https://github.com/duniatri/ws-wu-download.git
cd ws-wu-download

# 1. Configure credentials
cp config.example.json config.json
#    then edit config.json

# 2. Optional but recommended
Rscript tests/smoke_test.R

# 3. Run
Rscript -e 'shiny::runApp(".", port = 8085, launch.browser = TRUE)'
```

Requires **R >= 4.1** (the code uses the native pipe `|>`). See
[docs/INSTALL.md](docs/INSTALL.md) for the full package list, platform notes and
a troubleshooting section.

---

## Configuration

Credentials are read from `config.json` (git-ignored) and can be overridden by
environment variables, which is convenient for deployment:

| Key | Env var | Notes |
|-----|---------|-------|
| `api_key` | `WC_API_KEY` | Your The Weather Company API key |
| `station_id` | `WC_STATION_ID` | Your PWS station ID |
| `units` | `WC_UNITS` | `m` metric, `e` imperial, `h` UK hybrid |
| `numeric_precision` | — | Only `decimal` is accepted by the API |

```json
{
  "api_key": "YOUR_API_KEY_HERE",
  "station_id": "YOUR_STATION_ID",
  "units": "m",
  "numeric_precision": "decimal"
}
```

**Never commit `config.json`.** It is already listed in `.gitignore`.

---

## Endpoints used

All requests go to `https://api.weather.com`, authenticated with an `apiKey`
**query parameter** (not a header).

```
GET /v2/pws/observations/current    ?stationId=..&format=json&units=m&numericPrecision=decimal&apiKey=..
GET /v2/pws/observations/all/1day   ?...
GET /v2/pws/history/all             ?...&date=YYYYMMDD
GET /v2/pws/history/hourly          ?...&startDate=YYYYMMDD&endDate=YYYYMMDD
GET /v2/pws/history/daily           ?...&startDate=YYYYMMDD&endDate=YYYYMMDD
```

### Reading the HTTP status codes

| Code | Meaning |
|------|---------|
| `200` | Success — but still check whether `observations` is empty |
| `204` | **No data. Not an authentication problem.** Usually an offline station or a range outside the retention window |
| `401` | The key is not entitled to this product |
| `400` | Invalid request parameters |
| `429` | Rate limit exceeded |

Note that the status code for an empty date is **not consistent** — some dates
return `204`, others return `200` with an empty array. Never conclude "no data"
from the status code alone.

API-level errors can also arrive as **HTTP 200** with a body of
`{"errors":[...]}`, so the body must be inspected.

---

## Data structure notes

These were established by direct verification, not from the docs — see
[docs/FIELD-NOTES.md](docs/FIELD-NOTES.md) for the raw observations.

- **Unit-bearing fields are nested.** With `units=m` the values live in a
  sub-object called `metric` (`imperial` for `e`, `uk_hybrid` for `h`), while
  unit-less fields such as `humidity`, `winddir` and `solarRadiation` sit at the
  root. The app flattens both levels into one table.
- **`history/*` returns aggregates, not instantaneous values** — `tempAvg`,
  `tempHigh`, `tempLow` and friends, one row per reporting interval.
- **The upload interval is not uniform** — observed gaps ranged from 2 to 112
  minutes. Deduplicate on `epoch`, never on a timestamp.
- **`qcStatus` separates real rows from empty ones.** `-1` means the row carries
  measurements; `1` means it is a heartbeat upload with every sensor `NA`. The
  app deliberately keeps those rows so the gap is visible rather than hidden —
  the `summary` sheet reports the missing count.
- **`numericPrecision` only accepts `decimal`.** Anything else returns HTTP 400.
- **Field naming is inconsistent** (`tempAvg` but `windspeedAvg`), so all
  parameter matching is case-insensitive.
- **The station timezone is read from the `tz` field returned by the API**, so
  no timezone is hard-coded and the same build works for any station.

---

## Project layout

```
ws-wu-download/
├── app.R                  UI + server
├── R/
│   ├── params.R           parameter catalogue, timezone + resolution helpers
│   ├── api.R              API client, JSON flattening, fetch orchestration
│   └── plot.R             ggplot builder + PNG export
├── tests/
│   ├── smoke_test.R       functional test, runs with or without credentials
│   └── app_boot_test.sh   verifies the app starts and serves its UI
├── .github/
│   └── workflows/
│       └── ci.yml         CI: syntax check, smoke test, app boot
├── docs/
│   ├── INSTALL.md         installation and troubleshooting
│   ├── API-REFERENCE.md   endpoint and field reference
│   └── FIELD-NOTES.md     verification findings
├── config.example.json
└── .gitignore
```

---

## Testing

```bash
Rscript tests/smoke_test.R      # functional test
bash tests/app_boot_test.sh     # app starts and serves its UI
```

The smoke suite runs in two modes:

- **With credentials** in `config.json` — the full suite, including live API
  calls (68 assertions).
- **Without credentials** — an offline suite covering the parameter catalogue,
  the plot builder, PNG and XLSX export, the time round-trip, and the resolution
  helpers (46 assertions, 5 skipped).

That second mode exists so anyone cloning the repo can verify it works without
needing someone else's API key.

`app_boot_test.sh` starts the app on a local port and checks it answers with
HTTP 200 and the expected page title. It catches start-up failures a syntax
check cannot see — a missing package, a bad config value, a port that will not
bind. Set `PORT` and `TIMEOUT` to change the defaults, or `RSCRIPT` if `Rscript`
is not on your `PATH`.

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request to `main`:
R syntax check, the offline smoke suite, and the app boot test. No credentials
are stored in the repository, so CI exercises exactly the path a new user takes
after cloning.

---

## Requirements

R >= 4.1, and the packages: `shiny`, `bslib`, `plotly`, `DT`, `dplyr`, `tidyr`,
`tibble`, `ggplot2`, `lubridate`, `httr2`, `jsonlite`, `readxl`, `writexl`,
`ragg`, `shinycssloaders`.

---

## License

MIT — see [LICENSE](LICENSE).

This project is not affiliated with The Weather Company or Weather Underground.
You need your own API key and a station that publishes to Weather Underground.
