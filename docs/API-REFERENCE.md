# API Reference

Reference for the The Weather Company / Weather Underground **PWS v2**
endpoints used by this app, plus the fields they return.

Base URL: `https://api.weather.com`

---

## Authentication

Authentication is via the **`apiKey` query parameter**, not a header.

```
GET https://api.weather.com/v2/pws/observations/current
    ?stationId=YOUR_STATION_ID
    &format=json
    &units=m
    &numericPrecision=decimal
    &apiKey=YOUR_API_KEY
```

Two headers are worth setting:

| Header | Value | Why |
|--------|-------|-----|
| `Accept-Encoding` | `gzip` | Required in practice; responses are large |
| `User-Agent` | any string | Identifies your client |

### Parameters

| Parameter | Values | Notes |
|-----------|--------|-------|
| `stationId` | string | Your PWS station ID |
| `format` | `json` | Only `json` is used here |
| `units` | `m` / `e` / `h` | metric / imperial / UK hybrid |
| `numericPrecision` | `decimal` | **Only `decimal` is accepted.** `integer` returns HTTP 400. Optional — omitting it is fine |
| `apiKey` | string | Your API key |
| `date` | `YYYYMMDD` | `history/all` only |
| `startDate`, `endDate` | `YYYYMMDD` | `history/hourly` and `history/daily`; max 31 days per request |

---

## Endpoints

### `GET /v2/pws/observations/current`

The latest reading. Returns a single observation.

- **Resolution:** instantaneous
- **Returns HTTP 204 when the station is offline** — this is the normal,
  expected response, not an error

### `GET /v2/pws/observations/all/1day`

All observations for the current day.

- **Resolution:** raw samples, roughly one every 5 minutes
- Typically 200-300 rows for a full day

### `GET /v2/pws/history/all`

All observations for one specific date.

- **Resolution:** raw samples, roughly one every 5 minutes
- **One date per request** — there is no range form
- Retention is short. Expect only a few days of history to be available
- May return HTTP 204 **or** HTTP 200 with an empty array when the date is
  outside retention. Both mean "no data"

### `GET /v2/pws/history/hourly`

Hourly aggregates over a date range.

- **Resolution: hourly aggregate** — the underlying 5 minute samples are **not**
  recoverable from this response
- Accepts `startDate` and `endDate`, maximum 31 days

### `GET /v2/pws/history/daily`

Daily aggregates over a date range.

- **Resolution: daily aggregate**
- Accepts `startDate` and `endDate`, maximum 31 days

> **On `observations/hourly/1day`:** this endpoint exists in the API but requires
> a subscription tier that many PWS keys do not have. It returns HTTP **401**
> permanently when not entitled. `history/hourly` provides the same hourly
> aggregates and is generally available, so the app uses that instead.

---

## Response structure

This is the part that breaks most implementations.

### Unit-bearing fields are nested

With `units=m`, values live inside a sub-object called **`metric`**. The
sub-object is named after the unit system:

| `units` | Sub-object |
|---------|-----------|
| `m` | `metric` |
| `e` | `imperial` |
| `h` | `uk_hybrid` |

Unit-less fields sit at the **root** alongside it.

```jsonc
{
  "observations": [{
    "stationID": "YOUR_STATION_ID",
    "tz": "Europe/Amsterdam",
    "obsTimeUtc": "2026-01-15 08:35:12",
    "obsTimeLocal": "2026-01-15 09:35:12",
    "epoch": 1768466112,
    "lat": 0.0,
    "lon": 0.0,
    "humidity": 62,              // root   -- unit-less
    "winddir": 214,              // root   -- unit-less
    "solarRadiation": 641.2,     // root   -- unit-less
    "uv": 6,                     // root   -- unit-less
    "qcStatus": -1,              // root
    "metric": {                  // <-- unit-bearing values live here
      "temp": 28.4,
      "dewpt": 20.1,
      "heatIndex": 30.2,
      "windChill": 28.4,
      "windSpeed": 11.3,
      "windGust": 18.0,
      "pressure": 1013.2,
      "precipRate": 0.0,
      "precipTotal": 0.0,
      "elev": 42
    }
  }]
}
```

So `observations[0]["metric"]["temp"]`, **not** `observations[0]["temp"]`.

### `current` and `all/1day` use different field names

These are genuinely different shapes, not a naming inconsistency in your code:

| `current` | `all/1day` and `history/*` |
|-----------|---------------------------|
| `temp` | `tempAvg`, `tempHigh`, `tempLow` |
| `humidity` | `humidityAvg`, `humidityHigh`, `humidityLow` |
| `windSpeed` | `windspeedAvg`, `windspeedHigh`, `windspeedLow` |
| `winddir` | `winddirAvg` |
| `solarRadiation` | `solarRadiationHigh` |
| `uv` | `uvHigh` |
| `heatIndex` | `heatindexAvg`, `heatindexHigh`, `heatindexLow` |
| `windChill` | `windchillAvg`, `windchillHigh`, `windchillLow` |
| — | `pressureMax`, `pressureMin`, `pressureTrend` |

Also note the casing: `tempAvg` uses camelCase but `windspeedAvg`,
`windchillHigh` and `heatindexAvg` are all lower-case after the first word.
**Match case-insensitively.**

### Historical responses are aggregates

Every entry in `all/1day` and `history/*` represents one reporting interval and
carries High / Low / Avg for each sensor — not a single instantaneous value.
There is no plain `temp` field; use `tempAvg`.

---

## Field reference

### Root fields (no unit)

| Field | Description | Type | Example |
|-------|-------------|------|---------|
| `stationID` | Station identifier | string | `IXXXXXXXX` |
| `tz` | Station IANA timezone | string | `Europe/Amsterdam` |
| `obsTimeUtc` | Observation time, UTC | string | `2026-01-15 08:35:12` |
| `obsTimeLocal` | Observation time, station local | string | `2026-01-15 09:35:12` |
| `epoch` | Unix timestamp | integer | `1768466112` |
| `lat` | Latitude | double | `0.0` |
| `lon` | Longitude | double | `0.0` |
| `humidity` / `humidityAvg` | Relative humidity | integer | `62` |
| `winddir` / `winddirAvg` | Wind direction | integer | `214` |
| `solarRadiation` / `solarRadiationHigh` | Solar radiation | double | `641.2` |
| `uv` / `uvHigh` | UV index | integer | `6` |
| `qcStatus` | Row quality flag — see below | integer | `-1` |
| `neighborhood` | Location label | string | — |
| `country` | Country | string | — |
| `softwareType` | Station software | string | — |

### Fields inside the unit sub-object

With `units=m`:

| Field | Unit | Description |
|-------|------|-------------|
| `temp` / `tempAvg` / `tempHigh` / `tempLow` | °C | Air temperature |
| `dewpt` / `dewptAvg` | °C | Dew point |
| `heatIndex` / `heatindexAvg` | °C | Heat index |
| `windChill` / `windchillAvg` | °C | Wind chill |
| `windSpeed` / `windspeedAvg` | km/h | Wind speed |
| `windGust` / `windgustAvg` | km/h | Wind gust |
| `pressure` / `pressureMax` / `pressureMin` | hPa | Barometric pressure |
| `pressureTrend` | hPa | Pressure trend (aggregates only) |
| `precipRate` | mm/h | Precipitation rate |
| `precipTotal` | mm | Accumulated precipitation |
| `elev` | m | Station elevation |

With `units=e`, temperatures are °F, speeds mph, precipitation inches, pressure
inHg, elevation feet.

---

## `qcStatus`

This field is easy to misread. Verified behaviour:

| Value | Meaning |
|-------|---------|
| **`-1`** | The row **carries measurements** |
| **`1`** | Heartbeat upload — **every sensor is `NA`** |

In other words `-1` is the *good* value, which is the opposite of the intuitive
reading. On one station, roughly **12%** of rows in a day were heartbeat-only.

The app keeps these rows so the gap is visible. Filter with `qcStatus == -1` for
measurements only.

---

## HTTP status codes

| Code | Meaning | Action |
|------|---------|--------|
| `200` | Success | Still check whether `observations` is empty |
| `204` | **No data** — not an auth failure | Station offline, or range outside retention |
| `400` | Invalid request parameter | Check `numericPrecision`, date format |
| `401` | Key not entitled to this product | Different endpoint or subscription |
| `429` | Rate limit exceeded | Back off and retry |
| `5xx` | Server-side failure | Retry later |

**The status code for an empty date is not consistent.** Some dates return
`204`; others return `200` with an empty array. Treat both as "no data".

**API-level errors can arrive as HTTP 200** with a body of `{"errors":[...]}`.
The body must be inspected, not just the status code.

---

## Practical notes

- **Upload interval is not uniform.** Observed gaps ranged from 2 to 112 minutes
  on a single station. Deduplicate on `epoch`.
- **Retention is short** for the raw endpoints — a few days. Collect on a
  schedule rather than trying to backfill later.
- **Rate limiting:** a 5-minute polling schedule is 288 requests per day, well
  within typical limits. When looping over dates, insert a short delay between
  requests.
- **The timezone comes from the response** (`tz`), so there is no need to
  hard-code one.
