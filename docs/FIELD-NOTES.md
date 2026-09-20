# Field Notes

Findings from verifying this API directly against a live personal weather
station, rather than relying on the published documentation.

Several of these contradict the documentation. They are recorded here because
each one cost real debugging time.

**Method:** a single PWS station was polled across its full endpoint surface
over several days, starting from a cold start (a brand-new station with no
history), then re-verified once the station came online.

---

## 1. Endpoint availability

| Endpoint | Result | Notes |
|----------|--------|-------|
| `observations/current` | **200** | Returns HTTP **204** when the station is offline |
| `observations/all/1day` | **200** | Raw ~5 minute samples |
| `observations/hourly/1day` | **401** | **Permanently not entitled** on this subscription — not a transient error |
| `history/all` | 200 / 204 | Works per date |
| `history/hourly` | **200** | Works, and provides the same aggregates the 401 endpoint would |
| `history/daily` | 200 / 204 | Works |

The important practical result: **`history/hourly` is a working substitute for
`observations/hourly/1day`** when the latter is not entitled. Same hourly
aggregates, generally available.

---

## 2. The documentation is wrong about `history/*`

The published documentation states that `history/*` endpoints **cannot** be used
for the current day.

**They can.** Verified: `history/all` for the current date returned exactly the
same set of observations as `observations/all/1day`.

This matters because it means there is a viable per-date path for the current
day, not only `all/1day`.

---

## 3. The status code for an empty date is inconsistent

This is the single most misleading behaviour found.

Scanning 21 consecutive days:

| Date range | HTTP status |
|------------|-------------|
| 15-17 Sep | **204** |
| 9-14 Sep | **200** with an empty `observations` array |

Both were outside the retention window. Both meant "no data". The status code
differed.

**Never conclude "no data" from the status code alone.** Check for `204` *or*
`200` with an empty array. Conversely, do not conclude "auth is fine" from a
`204` — the two are independent.

---

## 4. `qcStatus` marks heartbeat rows, and the good value is the negative one

This was misread initially and the note is worth keeping as a caution.

| `qcStatus` | Rows | Content |
|------------|------|---------|
| **`-1`** | 113 | **Complete measurements** |
| **`1`** | 15 | **Every sensor `NA`** (except `precipRate = 0`) |

Zero exceptions across 128 observations. The separation was perfect.

So `-1` is the *valid* row and `1` is the *empty* one — the opposite of the
intuitive reading, where a positive "1" suggests a quality flag being set.

Roughly **12%** of a day's rows were heartbeat-only uploads. The gaps were
clustered, not evenly spread — several consecutive empty rows at a time.

**Implication:** any analysis must either filter `qcStatus == -1` or explicitly
account for missing rows. Silently treating `NA` as zero would bias every
average.

The app deliberately keeps these rows and reports the missing count in the
`summary` sheet, so the gap is visible rather than hidden.

---

## 5. Upload interval is not uniform

Measured on a single station over one day:

| Statistic | Value |
|-----------|-------|
| Minimum gap | **2 minutes** |
| Maximum gap | **112 minutes** |
| Mean gap | ~5.8 minutes |
| Median gap | ~5 minutes |

A 112-minute gap is not a rounding artefact — it is a real dropout.

**Implication:** never assume a fixed sampling rate, and never deduplicate or
join on a timestamp. Use `epoch`, which is unique per observation.

---

## 6. Retention is short

With a brand-new station, scanning backwards found data for only the most recent
**3 days**. Nothing earlier existed.

Data outside the retention window is **gone permanently**. There is no way to
backfill it later. If a long series is needed, it must be collected on a
schedule from the moment the station comes online.

This is the reason a collector is worth setting up early rather than waiting
until the analysis is needed.

---

## 7. Response structure

Confirmed by inspection:

- Unit-bearing fields are nested in a sub-object: `metric` for `units=m`,
  `imperial` for `e`, `uk_hybrid` for `h`.
- Unit-less fields (`humidity`, `winddir`, `solarRadiation`, `uv`, `epoch`,
  `qcStatus`, `tz`, ...) are at the root.
- `current` and `all/1day` use **different field names** for the same quantity
  (`temp` vs `tempAvg`, `windSpeed` vs `windspeedAvg`). See
  [API-REFERENCE.md](API-REFERENCE.md) for the full mapping.
- Casing is inconsistent: `tempAvg` is camelCase but `windspeedAvg`,
  `windchillHigh` and `heatindexAvg` are lower-case after the first word.

**A case-insensitive parameter catalogue matched 41/41 live columns and 27/27
`current` columns with zero falling through to "Other".** A case-sensitive one
missed 12 columns.

---

## 8. Parameter quirks

- **`numericPrecision` accepts only `decimal`.** Passing `integer` returns
  HTTP 400 with a clear message. Omitting it entirely works.
- **Unknown parameters return HTTP 400** with an explanatory message — the API
  is helpful here.
- **`apiKey` is a query parameter**, not a header.
- **`Accept-Encoding: gzip` is required in practice.**
- **Most fields can be `null`** when a sensor is not fitted. Any consumer must
  tolerate nulls per field, not per row.

---

## 9. Sensors observed

All expected sensors were live, including solar radiation and UV:

| Quantity | Observed range |
|----------|----------------|
| Temperature | 32.2 - 36.9 °C |
| Humidity | 43.8 - 50.0 % |
| Dew point | 20.4 - 23.5 °C |
| Heat index | 34.7 - 43.6 °C |
| Pressure | 1009.82 - 1012.87 hPa |
| Wind speed | 0 - 5.6 km/h |
| Wind direction | 9 - 356 ° |
| Solar radiation | 0 - **1422.3 W/m²** |
| UV index | 0 - **10** |

---

## 10. Derived: vapour pressure deficit

VPD is worth computing because it captures the evaporative driving force, which
temperature alone does not.

```r
vpd_kpa <- function(temp_c, rh) {
  es <- 6.112 * exp(17.67 * temp_c / (temp_c + 243.5))   # hPa
  es * (1 - rh / 100) / 10                               # -> kPa
}
```

Measured over one afternoon, VPD ranged **0.24 to 3.10 kPa** with a mean of
**1.02 kPa**.

The diurnal pattern was strongly bimodal:

- Early morning: VPD near 0.24 kPa — evaporation essentially stops
- Midday: VPD up to 3.10 kPa — rapid evaporation
- VPD above 2 kPa occurred on only **34%** of observations, in a window from
  roughly 09:20 to 12:25

**Implication:** for any drying or evapotranspiration process, the effective
working window may be only about three hours in the middle of the day. That is a
much more actionable statement than a daily average.

> **Unit caution.** The Magnus formula above returns **hPa**, not kPa. Forgetting
> the `/ 10` produces values ten times too large — which is an easy mistake to
> make and easy to miss, since the numbers still look plausible for a different
> unit. This was hit once during verification and corrected.

---

## 11. Bugs found and fixed during verification

These are recorded because they are all easy to reintroduce.

### `for (d in days)` strips the `Date` class

Iterating a `Date` vector with `for` silently drops the class, so
`format(d, ...)` fails with `invalid 'trim' argument`. R converts the element to
numeric.

```r
# Wrong
for (d in days) { format(d, "%Y%m%d") }

# Right
for (i in seq_along(days)) { d <- days[i]; format(d, "%Y%m%d") }
```

### `resp_body_string()` throws on HTTP 204

A `204` has no body. Calling `resp_body_string()` on it raises an error rather
than returning an empty string. Must be wrapped:

```r
body <- tryCatch(httr2::resp_body_string(resp), error = function(e) "")
```

This is especially relevant here because `204` is the *normal* response for an
offline station.

### Numeric coercion destroys time columns

`as.numeric()` on a `POSIXct` yields `NA`. A blanket numeric coercion over all
non-text columns wipes out every time column. Time columns must be excluded
explicitly.

### `plotly` inherits aesthetic mappings from the base plot

When a base `plot_ly()` maps `color = ~variable`, any `add_trace()` overlay must
set `inherit = FALSE`, otherwise it fails with `object 'variable' not found`.

### `NULL` query parameters crash the request builder

`as.character(NULL)` is `character(0)`, which fails `vapply` with
`values must be length 1, but FUN(X[[3]]) result is length 0`.

The trigger is real: a `config.json` containing an explicit
`"numeric_precision": null` overrides the default and breaks every request. Null
parameters must be dropped before building the query string.

### Base R `png()` writes no DPI metadata on macOS

The quartz and cairo backends do not write the PNG `pHYs` chunk. PowerPoint then
treats the file as 72 dpi and inserts a 12-inch image at roughly 96 cm. Use
`ragg::agg_png()`, which writes the chunk correctly.

---

## 12. Verification method

The app is checked by a functional test suite that runs **without the UI** and
**with or without credentials**:

- **With credentials:** 68 assertions, including live API calls
- **Without credentials:** 46 assertions covering the parameter catalogue, the
  plot builder, PNG and XLSX export, the wall-clock round-trip, and the
  resolution helpers

The offline mode exists so that anyone cloning the repository can verify it
without needing an API key.

---

## 13. Still unverified

Honest list of what has not been tested, so the gaps are known:

- The sub-object name for `units=h` (`uk_hybrid`) was inferred from the pattern
  but never observed, because the test station was queried in metric only.
- **Rate limits were not measured.** A 5-minute polling schedule is 288 requests
  per day and worked, but the actual ceiling is unknown.
- Whether an API key is bound to a single station was not tested.
- Long-run retention drift was not characterised — only the 3-day window
  observed on a new station.
- `neighborhood` and `country` values were observed but not validated against
  the station's actual registered location.
