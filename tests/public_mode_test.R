# =============================================================================
#  tests/public_mode_test.R  --  the public build must never read stored creds
#
#  Run:  Rscript tests/public_mode_test.R
#
#  The property under test is NOT "the text box looks empty" but "the value was
#  never read". So each case feeds credentials through every channel the app
#  knows about -- config.json AND the WC_* environment variables -- and asserts
#  that public mode ignores all of them.
#
#  This is the regression guard for the deploy bundle: without it, a later edit
#  could quietly reintroduce credential pre-filling and nothing would fail.
# =============================================================================

ROOT <- local({
  a <- commandArgs(FALSE)
  f <- grep("^--file=", a, value = TRUE)
  if (length(f)) dirname(dirname(normalizePath(sub("^--file=", "", f[1])))) else getwd()
})

pass <- 0L; fail <- 0L
chk <- function(label, cond, extra = "") {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat(sprintf("  [PASS] %s %s\n", label, extra)) }
  else              { fail <<- fail + 1L; cat(sprintf("  [FAIL] %s %s\n", label, extra)) }
  invisible(isTRUE(cond))
}

# --- Two builds, differing only by the marker --------------------------------
TMP <- file.path(tempdir(), "wxpublic")
unlink(TMP, recursive = TRUE)
dir.create(TMP, recursive = TRUE, showWarnings = FALSE)

make_build <- function(name, with_marker) {
  d <- file.path(TMP, name)
  dir.create(file.path(d, "R"), recursive = TRUE, showWarnings = FALSE)
  file.copy(file.path(ROOT, "app.R"), file.path(d, "app.R"), overwrite = TRUE)
  file.copy(list.files(file.path(ROOT, "R"), full.names = TRUE),
            file.path(d, "R"), overwrite = TRUE)
  # A config.json is present in BOTH builds on purpose: proving public mode
  # ignores it is the whole point.
  writeLines('{"api_key":"CFG-KEY-VALUE","station_id":"CFGSTA1","units":"m"}',
             file.path(d, "config.json"))
  if (with_marker) file.create(file.path(d, "PUBLIC_MODE"))
  d
}

local_dir <- make_build("local",  FALSE)
pub_dir   <- make_build("public", TRUE)

probe <- function(dir) {
  old <- setwd(dir); on.exit(setwd(old), add = TRUE)
  e <- new.env()
  sys.source("app.R", envir = e)
  list(public = isTRUE(e$PUBLIC_MODE), station = e$CFG0$station_id, key = e$CFG0$api_key)
}

cat("Build under test:", ROOT, "\n")

# --- 1. Normal build keeps working -------------------------------------------
cat("\n1. Normal build (config.json, no marker) still pre-fills\n")
Sys.unsetenv(c("WC_API_KEY", "WC_STATION_ID", "WC_PUBLIC"))
a <- probe(local_dir)
chk("PUBLIC_MODE is off",      isFALSE(a$public))
chk("station from config",     identical(a$station, "CFGSTA1"))
chk("key from config",         identical(a$key, "CFG-KEY-VALUE"))

# --- 2. The bundle asks the visitor ------------------------------------------
cat("\n2. Public build ignores a config.json that IS present\n")
b <- probe(pub_dir)
chk("PUBLIC_MODE is on",           isTRUE(b$public))
chk("station NOT pre-filled",      !nzchar(b$station))
chk("key NOT pre-filled",          !nzchar(b$key))

# --- 3. The property that matters on a public host ---------------------------
cat("\n3. Public build ignores WC_* environment variables\n")
Sys.setenv(WC_API_KEY = "ENV-KEY-VALUE", WC_STATION_ID = "ENVSTA1", WC_UNITS = "e")
c1 <- probe(pub_dir)
chk("PUBLIC_MODE still on",   isTRUE(c1$public))
chk("station from env IGNORED", !nzchar(c1$station))
chk("key from env IGNORED",     !nzchar(c1$key))

# --- 4. WC_PUBLIC works on a build without the marker ------------------------
cat("\n4. WC_PUBLIC=1 forces public mode without the marker\n")
Sys.setenv(WC_PUBLIC = "1")
d <- probe(local_dir)
chk("PUBLIC_MODE on via env var", isTRUE(d$public))
chk("station from config IGNORED", !nzchar(d$station))
chk("key from config IGNORED",     !nzchar(d$key))

# --- 5. Falsy WC_PUBLIC values must not switch it on -------------------------
# Credential env vars from section 3 must be cleared first: in normal mode they
# override config.json, so leaving them set would make this read the env value
# and report a false failure.
cat("\n5. Falsy WC_PUBLIC values leave normal mode alone\n")
Sys.unsetenv(c("WC_API_KEY", "WC_STATION_ID", "WC_UNITS"))
for (v in c("0", "false", "no", "off", "FALSE", "Off")) {
  Sys.setenv(WC_PUBLIC = v)
  r <- probe(local_dir)
  chk(sprintf("WC_PUBLIC=%s -> normal mode", v),
      isFALSE(r$public) && identical(r$station, "CFGSTA1"))
}
Sys.unsetenv(c("WC_API_KEY", "WC_STATION_ID", "WC_UNITS", "WC_PUBLIC"))

# --- 6. The built bundle really carries the marker ---------------------------
cat("\n6. build-public-bundle.sh output carries the marker\n")
bundle <- file.path(ROOT, "shinyapps-public")
if (dir.exists(bundle)) {
  chk("PUBLIC_MODE marker present in bundle",
      file.exists(file.path(bundle, "PUBLIC_MODE")))
  chk("no config.json in bundle", !file.exists(file.path(bundle, "config.json")))
  chk("no stale .public from an older build",
      !file.exists(file.path(bundle, ".public")))
} else {
  cat("  [SKIP] bundle not built -- run ./build-public-bundle.sh\n")
}

cat("\n============================================\n")
cat(sprintf("  RESULT: %d PASS, %d FAIL\n", pass, fail))
cat("============================================\n")
if (fail > 0L) quit(status = 1L)
