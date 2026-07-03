#!/usr/bin/env bash
# shoot.sh — headless-Chrome screenshots of every committed Cloud SPA scenario.
#
# Boots serve.mjs, then drives Chrome once per (scenario × theme × width),
# writing PNGs into a gitignored out dir. This is the "LOOK AT IT" capability
# (charter D63): review any screen state — including the ones that are painful
# to reach live (mid-provision, failed, suspended) — without a backend.
#
#   make cloud-shots
#   CHROME="/path/to/chrome" OUT=/tmp/shots ./shoot.sh
#
# Env:
#   CHROME  chrome/chromium binary (auto-detected on macOS/Linux otherwise)
#   OUT     output dir (default: cloud/priv/static/__preview__/__shots__/, gitignored)
#   PORT    preview server port (default: 4180)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${PORT:-4180}"
OUT="${OUT:-$HERE/__shots__}"

# ── locate a Chrome/Chromium binary ──────────────────────────────────────────
find_chrome() {
  if [[ -n "${CHROME:-}" ]]; then echo "$CHROME"; return; fi
  local candidates=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "/Applications/Chromium.app/Contents/MacOS/Chromium"
    "$(command -v google-chrome 2>/dev/null || true)"
    "$(command -v google-chrome-stable 2>/dev/null || true)"
    "$(command -v chromium 2>/dev/null || true)"
    "$(command -v chromium-browser 2>/dev/null || true)"
  )
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return; }
  done
  echo ""
}

CHROME_BIN="$(find_chrome)"
if [[ -z "$CHROME_BIN" ]]; then
  echo "!! No Chrome/Chromium found. Set CHROME=/path/to/chrome and retry." >&2
  exit 1
fi

SCENARIOS=(loggedout empty mixed-fleet provisioning failed)
THEMES=(light dark)
WIDTHS=(1440 768) # desktop + tablet — the second pass the slice mandates

mkdir -p "$OUT"

# ── start the preview server ─────────────────────────────────────────────────
node "$HERE/serve.mjs" --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the server to answer.
for _ in $(seq 1 50); do
  if curl -sf "http://localhost:$PORT/" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

echo ">> Chrome: $CHROME_BIN"
echo ">> Shooting into: $OUT"

shot() {
  local scen="$1" theme="$2" width="$3"
  local url="http://localhost:$PORT/?scen=$scen&theme=$theme"
  local png="$OUT/${scen}-${theme}-${width}.png"
  # Fresh --user-data-dir per shot dodges the shared-profile lock (the local
  # Chrome-drive gotcha) and keeps runs hermetic.
  local profile
  profile="$(mktemp -d)"
  "$CHROME_BIN" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --disable-dev-shm-usage \
    --hide-scrollbars \
    --no-first-run \
    --no-default-browser-check \
    --user-data-dir="$profile" \
    --force-device-scale-factor=2 \
    --window-size="${width},1000" \
    --virtual-time-budget=5000 \
    --timeout=15000 \
    --screenshot="$png" \
    "$url" >/dev/null 2>&1 || echo "  !! failed: $scen/$theme/$width"
  rm -rf "$profile"
  [[ -f "$png" ]] && echo "  ok  $(basename "$png")"
}

for scen in "${SCENARIOS[@]}"; do
  for theme in "${THEMES[@]}"; do
    for width in "${WIDTHS[@]}"; do
      shot "$scen" "$theme" "$width"
    done
  done
done

echo ">> Done. $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') PNGs in $OUT"
