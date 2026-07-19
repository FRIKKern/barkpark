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
#
# ROUTE FIDELITY (GR66): each shot requests the scenario's OWN pathname and
# search, not always "/". app.js gates isNewFlow/isActivateFlow on the exact
# pathname and reads ?code=/?template=/?bp=/?billing=portal out of
# location.search, so the flat-"/" harness filed 13 scenarios (5 /activate,
# 4 /new, 3 account-modal, billing-portal-return) under names their PNGs did
# not show. Filenames are unchanged; only the URL got honest.
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

# Scenario names + their ROUTE straight from the single source of truth
# (scenarios.mjs → SCENARIOS[name]). Three fields matter, not one:
#   deepLink  the URL fragment — the provisioning/failed money shot is the
#             #instance/<id> timeline, not #overview.
#   pathname  app.js gates whole flows on the EXACT pathname (isNewFlow,
#             isActivateFlow), so requesting "/" for a "/activate" scenario
#             renders the logged-out card and files it under an activate name.
#   search    app.js reads ?code=, ?template=, ?bp= and ?billing=portal out of
#             location.search; dropping it silently voids the scenario's state.
#
# ── \x1f, NEVER TAB ──────────────────────────────────────────────────────────
# The fields are joined and split on \x1f (US, the ASCII unit separator).
# The obvious `IFS=$'\t'` version is BROKEN and fails SILENTLY: tab is IFS
# WHITESPACE, so bash collapses runs of it and drops empty fields — a row like
# "account-modal<TAB><TAB>/<TAB>" reads back shifted (deep="/", pathname empty),
# yielding an unloadable URL such as http://localhost:4189account?scen=… .
# Chrome then screenshots its NEW TAB PAGE, the PNG is non-empty, and shoot.sh
# prints "ok" — a false green whose only tell is byte-identical PNGs (72611 B)
# across different themes AND different scenarios. \x1f is not IFS whitespace,
# so empty fields survive. Do not "simplify" this back to a tab.
SCEN_TABLE="$(HERE="$HERE" node --input-type=module -e '
  const m = await import(new URL("scenarios.mjs", "file://" + process.env.HERE + "/").href);
  const US = String.fromCharCode(31);
  for (const [name, s] of Object.entries(m.SCENARIOS)) {
    console.log([name, s.deepLink || "", s.pathname || "", s.search || ""].join(US));
  }
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
  local scen="$1" theme="$2" width="$3" deep="${4:-}" accent="${5:-}" spath="${6:-}" ssearch="${7:-}"
  local accent_q="" accent_sfx=""
  if [[ -n "$accent" ]]; then accent_q="&accent=$accent"; accent_sfx="-$accent"; fi
  # The scenario's own query string, folded in as extra params (its leading "?"
  # dropped — ours already opened the query with ?scen=).
  local search_q=""
  if [[ -n "$ssearch" ]]; then search_q="&${ssearch#\?}"; fi
  # The account modal opens on a CLICK, so no deepLink can reach it; mock.js:133
  # drives the REAL openAccountModal() on ?modal=account. The flag is derived
  # from the "account-modal" NAME PREFIX here rather than from a scenarios.mjs
  # field, deliberately: scenarios.mjs is a tail-zone collision anchor this wave.
  # TRADEOFF, stated honestly: this is a naming CONVENTION, not a contract — a
  # future account-modal scenario named otherwise is silently shot without the
  # modal. Promote it to a scenarios.mjs field once the tail zone is quiet.
  local modal_q=""
  case "$scen" in account-modal*) modal_q="&modal=account" ;; esac
  # ORDER MATTERS: everything above is a QUERY param and $deep is the URL
  # FRAGMENT, so the fragment MUST come LAST. mock.js:32 reads accent from
  # location.search, which excludes everything past `#`, and falls back to
  # evergreen SILENTLY — so the old `$deep$accent_q` ordering dropped the accent
  # for the 72 of 81 scenarios that carry a deepLink, making every
  # accent-suffixed filename a lie (charter GR58). Do not reorder.
  local url="http://localhost:$PORT${spath:-/}?scen=$scen&theme=$theme$accent_q$search_q$modal_q$deep"
  # …and this is the tripwire that makes "do not reorder" enforceable. shoot.sh
  # has no automated coverage at all, which is exactly how the original bug
  # survived long enough to void every accent proof this epic ever cited. A
  # re-swap would once again produce plausible-looking PNGs under lying
  # filenames; this aborts the run instead.
  # Tripwire for the field-shift class described at SCEN_TABLE: a pathname that
  # does not start with "/" means the table split misaligned, and the resulting
  # URL would be unloadable — Chrome would screenshot its New Tab Page and this
  # script would print "ok". Abort instead of shipping a lying PNG.
  if [[ -n "$spath" && "$spath" != /* ]]; then
    echo "!! shoot.sh: scenario '$scen' produced pathname '$spath' (no leading /)." >&2
    echo "!! The scenario table split misaligned — check the \\x1f join, not a tab." >&2
    exit 1
  fi
  if [[ -n "$accent_q" && "${url%%#*}" != *"accent=$accent"* ]]; then
    echo "!! shoot.sh: ACCENT=$accent landed inside the URL FRAGMENT, not the query." >&2
    echo "!! mock.js reads location.search and would silently render evergreen." >&2
    echo "!! url: $url" >&2
    exit 1
  fi
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

# IFS is \x1f (US) — see the SCEN_TABLE note above for why a tab here is a
# silent-corruption bug, not a style choice.
while IFS=$'\x1f' read -r scen deep spath ssearch; do
  [[ -z "$scen" ]] && continue
  # SCEN filter: when set, skip any scenario not on the list.
  if [[ -n "$WANT_SCEN" && "$WANT_SCEN" != *" $scen "* ]]; then continue; fi
  for theme in "${THEMES[@]}"; do
    for width in "${WIDTHS[@]}"; do
      for accent in "${ACCENTS[@]}"; do
        shot "$scen" "$theme" "$width" "$deep" "$accent" "$spath" "$ssearch"
      done
    done
  done
done <<< "$SCEN_TABLE"

echo ">> Done. $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') PNGs in $OUT"
