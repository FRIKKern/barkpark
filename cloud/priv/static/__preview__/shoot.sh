#!/usr/bin/env bash
# shoot.sh — headless-Chrome screenshots of every committed Cloud SPA scenario.
#
# Boots serve.mjs, then drives Chrome once per (scenario × theme × width),
# writing PNGs into a gitignored out dir. This is the "LOOK AT IT" capability
# (charter D63): review any screen state — including the ones that are painful
# to reach live (mid-provision, failed, suspended) — without a backend.
#
#   make cloud-shots                              # the full matrix (all scenarios)
#   CHROME="/path/to/chrome" OUT=/tmp/shots ./shoot.sh
#   SCEN=billing-trial,billing-past-due ./shoot.sh          # only these scenarios
#   ACCENT=iris,ember ./shoot.sh                            # add the identity axis
#   SCEN=billing-trial ACCENT=iris ./shoot.sh              # one targeted look
#
# Bare ./shoot.sh keeps the ORIGINAL full-matrix behavior (every scenario ×
# light/dark × 1440/768, evergreen identity, evergreen filenames unchanged).
#
# WHY the poll-kill wrapper: this host's Chrome reliably WRITES each PNG and then
# HANGS instead of exiting, so the old synchronous `--timeout=15000` path paid
# the full 15s per shot even though the screenshot landed in ~3.6s. shot() now
# backgrounds Chrome, polls for the PNG to SETTLE (two equal non-zero sizes),
# and force-kills the moment it does — measured 89s→17s for a 4-shot batch,
# ~3.6s for a single shot. (macOS has no timeout(1), so this is hand-rolled.)
#
# Env:
#   CHROME  chrome/chromium binary (auto-detected on macOS/Linux otherwise)
#   OUT     output dir (default: cloud/priv/static/__preview__/__shots__/, gitignored)
#   PORT    preview server port (default: 4180)
#   SCEN    comma-list of scenario names to shoot (default: all, from scenarios.mjs)
#   ACCENT  comma-list of accent identities — evergreen|ember|fjord|charple|iris —
#           each appends &accent=<name> to the URL (mock.js:70 seam) and -<name>
#           to the filename. Unset ⇒ one pass, no ?accent=, filenames unchanged.
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

# Scenario names + their deep links straight from the single source of truth
# (scenarios.mjs → SCENARIOS[name].deepLink). The deep link matters: the
# provisioning/failed money shot is the #instance/<id> timeline, not #overview.
SCEN_TSV="$(HERE="$HERE" node --input-type=module -e '
  const m = await import(new URL("scenarios.mjs", "file://" + process.env.HERE + "/").href);
  for (const [name, s] of Object.entries(m.SCENARIOS)) console.log(name + "\t" + (s.deepLink || ""));
')"
THEMES=(light dark)
WIDTHS=(1440 768) # desktop + tablet — the second pass the slice mandates

# ── optional SCEN filter (comma-list) ────────────────────────────────────────
# Unset ⇒ shoot every scenario. Set ⇒ shoot only the named ones (an unknown
# name simply never matches — no error, so a typo is visible as a missing PNG).
# A space-padded allowlist; membership is a padded-substring test so this runs
# on bash 3.2 (macOS default — no associative arrays).
WANT_SCEN=""
if [[ -n "${SCEN:-}" ]]; then WANT_SCEN=" ${SCEN//,/ } "; fi

# ── optional ACCENT axis (comma-list) ────────────────────────────────────────
# Unset ⇒ a single pass with NO ?accent= (evergreen fallback in CSS) and the
# ORIGINAL filename. Set ⇒ one shot per identity, -<accent> suffixed on the file.
ACCENTS=()
if [[ -n "${ACCENT:-}" ]]; then
  IFS=',' read -ra ACCENTS <<< "$ACCENT"
else
  ACCENTS=("") # the empty accent = old behavior (no ?accent=, no filename suffix)
fi

mkdir -p "$OUT"

# ── start the preview server ─────────────────────────────────────────────────
node "$HERE/serve.mjs" --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Wait for the server to answer — and fail fast if it never does (dead node,
# EADDRINUSE, …) instead of emitting 20 confusing per-shot failures.
up=""
for _ in $(seq 1 50); do
  if curl -sf "http://localhost:$PORT/" >/dev/null 2>&1; then up=1; break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
  sleep 0.1
done
if [[ -z "$up" ]]; then
  echo "!! preview server never answered on :$PORT (port in use? node error?)" >&2
  echo "   try: node $HERE/serve.mjs --port $PORT" >&2
  exit 1
fi

echo ">> Chrome: $CHROME_BIN"
echo ">> Shooting into: $OUT"

# Portable file size (macOS `stat -f%z`, GNU `stat -c%s`), 0 if absent.
png_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

shot() {
  local scen="$1" theme="$2" width="$3" deep="${4:-}" accent="${5:-}"
  local accent_q="" accent_sfx=""
  if [[ -n "$accent" ]]; then accent_q="&accent=$accent"; accent_sfx="-$accent"; fi
  # ORDER MATTERS: $accent_q is a QUERY param and $deep is the URL FRAGMENT, so
  # the accent MUST come first. mock.js:32 reads accent from location.search,
  # which excludes everything past `#`, and falls back to evergreen SILENTLY —
  # so the old `$deep$accent_q` ordering dropped the accent for the 72 of 81
  # scenarios that carry a deepLink, making every accent-suffixed filename a lie
  # (charter GR58). Do not reorder.
  local url="http://localhost:$PORT/?scen=$scen&theme=$theme$accent_q$deep"
  local png="$OUT/${scen}-${theme}-${width}${accent_sfx}.png"
  # Fresh --user-data-dir per shot dodges the shared-profile lock (the local
  # Chrome-drive gotcha) and keeps runs hermetic.
  local profile
  profile="$(mktemp -d)"
  rm -f "$png"
  # Background Chrome, then poll — it writes the PNG and HANGS, so we can't wait
  # on it exiting. See the header note for the measured win.
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
    "$url" >/dev/null 2>&1 &
  local cpid=$!
  # Poll every 100ms; kill Chrome the instant the PNG has SETTLED (two equal,
  # non-zero sizes — so we never grab a half-flushed file). Hard cap at 15s so a
  # genuinely stuck shot can't wedge the whole run.
  local waited=0 last=-1 cur
  while (( waited < 15000 )); do
    if [[ -f "$png" ]]; then
      cur="$(png_size "$png")"
      if [[ "$cur" -gt 0 && "$cur" == "$last" ]]; then break; fi
      last="$cur"
    fi
    # Chrome exited on its own (rare on this host, but honor it).
    kill -0 "$cpid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 100))
  done
  # Reap: TERM, then a beat, then a guaranteed KILL — proof the spawned Chrome
  # is never left alive (kill -0 returns non-zero once it's gone).
  kill "$cpid" 2>/dev/null || true
  wait "$cpid" 2>/dev/null || true
  kill -9 "$cpid" 2>/dev/null || true
  rm -rf "$profile"
  if [[ "$(png_size "$png")" -gt 0 ]]; then
    echo "  ok  $(basename "$png")"
  else
    echo "  !! failed: ${scen}/${theme}/${width}${accent_sfx}"
  fi
}

while IFS=$'\t' read -r scen deep; do
  [[ -z "$scen" ]] && continue
  # SCEN filter: when set, skip any scenario not on the list.
  if [[ -n "$WANT_SCEN" && "$WANT_SCEN" != *" $scen "* ]]; then continue; fi
  for theme in "${THEMES[@]}"; do
    for width in "${WIDTHS[@]}"; do
      for accent in "${ACCENTS[@]}"; do
        shot "$scen" "$theme" "$width" "$deep" "$accent"
      done
    done
  done
done <<< "$SCEN_TSV"

echo ">> Done. $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') PNGs in $OUT"
