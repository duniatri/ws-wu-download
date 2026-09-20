#!/usr/bin/env bash
# =============================================================================
#  tests/app_boot_test.sh  --  Verify the Shiny app actually starts and serves
#
#  Run:  bash tests/app_boot_test.sh
#
#  Starts the app on a local port, waits for it to answer, and checks that the
#  response is HTTP 200 carrying the expected page title. Catches start-up
#  crashes that a syntax check cannot see (missing package, bad config
#  handling, port binding failure).
#
#  CI runs this with no config.json present -- the same state a new user gets
#  after cloning. The app must still boot and show its "not configured" screen.
#
#  Environment:
#    PORT     port to bind (default 8100)
#    TIMEOUT  seconds to wait for the first good response (default 40)
#    RSCRIPT  path to Rscript if it is not on PATH
# =============================================================================

set -euo pipefail

PORT="${PORT:-8100}"
TIMEOUT="${TIMEOUT:-40}"
EXPECTED_TITLE="Weather Station Explorer"
RSCRIPT="${RSCRIPT:-Rscript}"

if ! command -v "$RSCRIPT" >/dev/null 2>&1; then
  echo "FAIL: Rscript not found (looked for '${RSCRIPT}')"
  echo "Install R, put it on PATH, or set RSCRIPT=/full/path/to/Rscript"
  echo "Typical locations:"
  echo "  macOS  /usr/local/bin/Rscript  or  /Library/Frameworks/R.framework/Resources/bin/Rscript"
  echo "  Linux  /usr/bin/Rscript  or  /usr/lib/R/bin/Rscript"
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMPDIR_RUN="$(mktemp -d)"
APP_LOG="$TMPDIR_RUN/app.log"
PAGE="$TMPDIR_RUN/page.html"

cleanup() {
  if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_RUN"
}
trap cleanup EXIT

echo "Starting app on port ${PORT} (working dir: ${ROOT})"
echo "Using Rscript: $(command -v "$RSCRIPT")"

"$RSCRIPT" -e "shiny::runApp('.', port = ${PORT}, host = '127.0.0.1', launch.browser = FALSE)" \
  > "$APP_LOG" 2>&1 &
APP_PID=$!

for _ in $(seq 1 "$TIMEOUT"); do
  sleep 1

  # The process may have died already -- no point waiting out the full timeout.
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: app process exited before it served anything"
    echo "--- app log ---"
    cat "$APP_LOG"
    exit 1
  fi

  CODE="$(curl -s -o "$PAGE" -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"

  if [ "$CODE" = "200" ] && grep -q "$EXPECTED_TITLE" "$PAGE"; then
    echo "PASS: app served HTTP 200 with title \"${EXPECTED_TITLE}\""
    exit 0
  fi
done

echo "FAIL: app did not serve its UI within ${TIMEOUT}s"
echo "last HTTP status: ${CODE:-none}"
echo "--- app log ---"
cat "$APP_LOG"
exit 1
