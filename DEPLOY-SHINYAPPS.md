# Deploying to shinyapps.io

The app can be published as a **public** web app where every visitor — the
operator included — supplies their own Weather Underground API key and Station
ID. This document covers what the public build changes, how to deploy it, and
exactly which protections are and are not in place.

---

## 1. What the public bundle is

```bash
./build-public-bundle.sh
```

produces `shinyapps-public/`, a **self-contained app directory**:

```
shinyapps-public/
├── PUBLIC_MODE        <- marker; switches the app into public mode
├── app.R
└── R/
    ├── api.R
    ├── params.R
    └── plot.R
```

That is the whole bundle. No `config.json`, no tests, no documentation, no
screenshots. Everything else in the repository is development material and has
no business travelling to the host.

> The bundle is a **copy**, not a link. Re-run the script after editing `app.R`
> or `R/*.R`, or you will deploy a stale version. The script wipes the output
> directory first, so a file you removed from the source cannot linger and ship.

---

## 2. What public mode changes

`PUBLIC_MODE` is read once at startup from the `PUBLIC_MODE` marker file next to
`app.R`, or from the `WC_PUBLIC` environment variable. When it is on:

| Behaviour | Normal build | Public build |
|---|---|---|
| Reads `config.json` | yes | **never** |
| Reads `WC_API_KEY` / `WC_STATION_ID` | yes | **never** |
| Station ID field starts | pre-filled | **empty** |
| API key field starts | pre-filled | **empty** |
| Credentials panel | collapsed | **open** |
| "Credentials required" notice | hidden | **shown** |
| Fetch with empty credentials | blocked | **blocked** |

The distinction that matters is not *"the box looks empty"* but *"the value was
never read"*. In public mode `load_config()` returns an empty configuration
before it ever touches the filesystem or the environment, so a stray
`WC_API_KEY` on the host cannot hand the operator's key to visitors.

Two independent triggers, deliberately redundant:

1. the `PUBLIC_MODE` marker file — travels with the code, so the mode does not
   depend on host settings being remembered
2. `WC_PUBLIC=1` — for hosts where dropping a file is inconvenient

The marker is **not** a dotfile. Dotfiles are silently dropped by some copy and
archive tools, and a lost marker would quietly disable the guard.

---

## 3. Deploy

Install the client once:

```r
install.packages("rsconnect")
```

Then, from a directory that is **not** the app directory:

```r
rsconnect::setAccountInfo(name = "<account>", token = "<token>", secret = "<secret>")
rsconnect::deployApp(appDir = "path/to/shinyapps-public")
```

Point `appDir` at `shinyapps-public/`, not at its parent — the parent has no
`app.R` and the deploy will fail with an unhelpful message.

From RStudio: open `shinyapps-public/app.R` and use *Publish*, accepting the
detected file list.

**Do not** set `WC_API_KEY` or `WC_STATION_ID` in the host's environment. Public
mode ignores them, so they change nothing — but their presence makes the
deployment harder to reason about, and if the marker were ever lost they would
be the first thing to leak.

---

## 4. What the visitor sees

1. The sidebar opens with an amber **"Credentials required"** notice and the
   *Credentials* panel expanded.
2. They enter a Station ID and API key. Either can be any Weather Underground
   PWS station — the app is not tied to one.
3. *Fetch data* is refused with a specific message until both are present.
4. From there the app behaves exactly as documented in `README.md`: fetch →
   choose parameters → download `.xlsx` → chart → save `.png`.

Credentials live in the Shiny session only. They are never written to disk and
are dropped when the browser tab closes.

---

## 5. Security model

### Protected

| Risk | Mitigation |
|---|---|
| Operator's API key baked into the build | Nothing to leak — the bundle ships no credentials |
| Operator's key injected via host environment | `WC_*` credential variables are never read in public mode |
| Credentials persisted server-side | Never written to disk; held in session memory only |
| API key echoed back in an error message | `redact_key()` scrubs every message before it reaches the UI or the request log |
| Credentials in the deploy log | Covered by the same redaction; the key travels in the query string, which transport errors can echo |
| Stale files shipping with the bundle | The build script wipes the output directory first |
| Real `config.json` shipped by accident | The build script refuses to produce a bundle containing one |

### Not protected

- **A shinyapps.io free-tier app is public.** Anyone with the URL can open it.
  Nothing in the app restricts who may use it.
- **Data, not credentials, is the exposure.** A visitor who knows a station ID
  can fetch that station's readings. The app never reveals the operator's
  station ID — but if you tell people what it is, they can read your data.
- **Visitors' API keys transit the server.** The API call is made server-side
  (the weather API does not permit browser CORS), so a key is sent to the host
  for the duration of the request. This is over HTTPS and the app stores
  nothing, but it is not end-to-end private.
- **No rate limiting or authentication.** Each visitor spends their own API
  quota, so a public app costs the operator nothing — but it can be hammered.
  Add `shinymanager` or a paid plan with authentication if that matters.
- **The Station ID appears in downloaded filenames** and in the `info` sheet of
  the workbook. That is the visitor's own ID, not the operator's.

---

## 6. Verify before you publish

```bash
Rscript tests/public_mode_test.R   # 21 checks: public mode ignores every credential channel
Rscript tests/smoke_test.R         # functional suite, runs without credentials
```

`public_mode_test.R` is the regression guard for this feature. It builds two
copies that differ only by the marker, feeds both a `config.json` **and** the
`WC_*` environment variables, and asserts that only the marked copy refuses all
of them. If a later edit reintroduces credential pre-filling in public mode,
that test fails.
