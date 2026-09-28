#!/usr/bin/env bash
# =============================================================================
#  Build the public-safe bundle for shinyapps.io
#
#  The bundle is SELF-CONTAINED (app.R + R/) and carries a PUBLIC_MODE marker
#  that switches the app into public mode: stored credentials -- config.json and
#  the WC_* environment variables -- are never read, so every visitor must type
#  their own API key and Station ID. See the PUBLIC_MODE block in app.R.
#
#  The bundle is a COPY, not a link. Re-run this after editing app.R or R/*.R,
#  otherwise you will deploy a stale version.
#
#  Usage:  ./build-public-bundle.sh          -> ./shinyapps-public
#          OUT=/tmp/x ./build-public-bundle.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$ROOT/shinyapps-public}"

# Wipe the output first. Without this, a file deleted from the source (or a
# renamed marker) lingers in the bundle and ships to the host -- and a stale
# file is invisible in review because the listing only shows what is added.
if [ -d "$OUT" ] && [ "$OUT" != "$ROOT" ]; then
  find "$OUT" -mindepth 1 -delete
fi

# Only the three sources app.R actually needs, plus the marker. Anything else
# would be uploaded to the host for no reason.
mkdir -p "$OUT/R"

cp "$ROOT/app.R" "$OUT/app.R"
cp "$ROOT/R/api.R" "$ROOT/R/params.R" "$ROOT/R/plot.R" "$OUT/R/"

# Marker -> PUBLIC_MODE. Not a dotfile on purpose: dotfiles are dropped by some
# copy and archive tools, and a lost marker would silently disable the guard.
: > "$OUT/PUBLIC_MODE"

# Guard against the most damaging mistake: shipping real credentials. The bundle
# must never contain config.json.
if [ -e "$OUT/config.json" ]; then
  echo "ERROR: config.json found in the bundle -- refusing." >&2
  exit 1
fi

echo "Bundle written to $OUT"
echo
(cd "$OUT" && find . -type f | sort | sed 's|^\./|  |')

echo
echo "Deploy with:"
echo "  rsconnect::deployApp(appDir = \"$OUT\")"
echo
echo "Do NOT set WC_API_KEY / WC_STATION_ID on the host -- public mode ignores"
echo "them, and their presence only makes the deployment harder to reason about."
