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
# WHY the reap watchdog (charter GR99): the poll-kill above bounded only the
# PNG-settle poll, never the REAP, and this harness wedged FOUR times across
# waves — ~28min, 7h18m, 7h46m, 10h30m+ — always in the same place. `sample` on
# a live wedged run: 2395 of ~2400 stack frames in __wait4, i.e. blocked in
# `wait "$cpid"`, PAST the SIGTERM, so the following `kill -9` this file used to
# call "a guaranteed KILL" was unreachable code. bash `wait` has no timeout, so
# only an EXTERNAL watchdog can bound it — see the reap block in shot().
#
# CLEANING UP AFTER A WEDGE — USE reap-orphans.sh, NOT A pkill SWEEP. The
# watchdog above is scoped to processes THIS run spawned. For the leftovers a
# wedged or killed run leaves on the host, run ./reap-orphans.sh (dry run by
# default, --kill to act). It matches on a SIGNATURE plus PPID=1 plus an
# elapsed floor, never on a name or a port: a broad `headless|serve.mjs` sweep
# once killed a two-minute-old serve.mjs belonging to a CONCURRENT sibling
# worktree, silently corrupting that run. Many sessions share this checkout.
#
# THE HARNESS'S OWN FALSE-GREEN CLASSES, now guarded (charter GR98). Each of
# these shipped a full-looking matrix that was wrong:
#   - server dies mid-run ⇒ every remaining shot is an ERR_CONNECTION_REFUSED
#     page with a non-zero size, and the old `png_size > 0` gate printed `ok`
#     for all of them. Liveness is now re-checked PER SHOT, not once at boot.
#   - two runs sharing one $OUT interleave silently (measured: 49 files against
#     44 `ok` lines). A concurrent run is now refused by a lock in $OUT, and the
#     completion line counts THIS run's shots instead of `find`ing the whole
#     directory — so stale or foreign files can no longer inflate the proof.
#   - an unknown SCEN name was silently dropped and the run still printed
#     ">> Done". Unmatched SCEN entries now abort before anything is shot.
#
# Env:
#   CHROME  chrome/chromium binary (auto-detected on macOS/Linux otherwise)
#   OUT     output dir (default: cloud/priv/static/__preview__/__shots__/, gitignored)
#   PORT    preview server port (default: 4180)
#   SCEN    comma-list of scenario names to shoot (default: all, from scenarios.mjs)
#   ACCENT  comma-list of accent identities — evergreen|ember|fjord|charple|iris —
#           each appends &accent=<name> to the URL (mock.js:70 seam) and -<name>
#           to the filename. Unset ⇒ one pass, no ?accent=, filenames unchanged.
#   REAP_BUDGET  seconds the watchdog gives one Chrome reap before killing the
#           process TREE (default: 10).
#   OUT_REUSE=1  silence the "$OUT already holds N PNGs" notice. It is only a
#           notice — a CONCURRENT run is refused by the lock, always.
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
REAP_BUDGET="${REAP_BUDGET:-10}"

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

# ── the live census, DERIVED ─────────────────────────────────────────────────
# Never hand-write these numbers. A frozen count in a comment goes stale the
# next time scenarios.mjs grows and then lies to every reader (GR53/GR80/GR83);
# the header here said "72 of 81" long after the truth was 73 of 86.
ALL_SCEN="$(printf '%s\n' "$SCEN_TABLE" | cut -d$'\x1f' -f1 | grep -v '^$' || true)"
SCEN_TOTAL="$(printf '%s\n' "$ALL_SCEN" | grep -c . || true)"
SCEN_DEEP="$(printf '%s\n' "$SCEN_TABLE" | cut -d$'\x1f' -f2 | grep -c . || true)"

# ── optional SCEN filter (comma-list) ────────────────────────────────────────
# Unset ⇒ shoot every scenario. Set ⇒ shoot only the named ones.
# A space-padded allowlist; membership is a padded-substring test so this runs
# on bash 3.2 (macOS default — no associative arrays).
#
# VALIDATED, because the padded-substring test is an EXACT match: a typo, or a
# scenario that does not exist yet, used to match nothing at all and be silently
# dropped while the run still printed ">> Done" over a short matrix. Fail here,
# naming the entry, before a single pixel is shot.
WANT_SCEN=""
if [[ -n "${SCEN:-}" ]]; then
  WANT_SCEN=" ${SCEN//,/ } "
  unknown=""
  for want in ${SCEN//,/ }; do
    if [[ " $(printf '%s ' $ALL_SCEN)" != *" $want "* ]]; then unknown="$unknown $want"; fi
  done
  if [[ -n "$unknown" ]]; then
    echo "!! shoot.sh: SCEN names match no scenario:$unknown" >&2
    echo "   $SCEN_TOTAL scenarios exist in scenarios.mjs." >&2
    for want in $unknown; do
      # Progressively shorter needles, first hit wins. The previous version
      # grepped ONLY on "${want%%-*}", which for a hyphen-FREE typo (`empy`) is
      # the whole typo and therefore matches nothing — so the commonest typo
      # shape printed a bare "Closest by prefix:" header with no entries under
      # it. An empty suggestion list reads as "there is nothing like this",
      # which is the opposite of the truth and sends the reader to the wrong
      # question. Suggest, or say plainly that there is no near match.
      hits=""
      for needle in "${want%%-*}" "${want:0:6}" "${want:0:4}" "${want:0:3}"; do
        [[ -z "$needle" ]] && continue
        hits="$(printf '%s\n' "$ALL_SCEN" | grep -i -- "$needle" || true)"
        if [[ -n "$hits" ]]; then break; fi
      done
      if [[ -n "$hits" ]]; then
        echo "   Did you mean (near '$want'):" >&2
        printf '%s\n' "$hits" | sed 's/^/     /' >&2
      else
        echo "   No scenario resembles '$want'. The names are the keys of" >&2
        echo "   SCENARIOS in $HERE/scenarios.mjs; leaving SCEN unset shoots all $SCEN_TOTAL." >&2
      fi
    done
    exit 1
  fi
fi

# ── optional ACCENT axis (comma-list) ────────────────────────────────────────
# Unset ⇒ a single pass with NO ?accent= (evergreen fallback in CSS) and the
# ORIGINAL filename. Set ⇒ one shot per identity, -<accent> suffixed on the file.
ACCENTS=()
if [[ -n "${ACCENT:-}" ]]; then
  IFS=',' read -ra ACCENTS <<< "$ACCENT"
else
  ACCENTS=("") # the empty accent = old behavior (no ?accent=, no filename suffix)
fi

# ── $OUT must be OURS ────────────────────────────────────────────────────────
# The measured defect was two runs writing into one $OUT AT THE SAME TIME: they
# interleave silently and the old whole-directory `find` counted the other run's
# files as this run's proof — 49 files against 44 `ok` lines, a matrix that read
# complete and was not.
#
# So the hard guard is a LOCK on the concurrent writer, NOT a ban on re-using a
# directory. Those are different things and conflating them would break the
# everyday path: `make cloud-shots` shoots into the DEFAULT $OUT every time, so
# refusing a non-empty dir would fail every second run for no safety gain. A
# sequential re-shoot is normal — shot() already overwrites each PNG it takes,
# and the per-run counter below means stale files can no longer inflate anyone.
mkdir -p "$OUT"
LOCK="$OUT/.shoot.lock"
if [[ -f "$LOCK" ]]; then
  other="$(cat "$LOCK" 2>/dev/null || true)"
  if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
    echo "!! shoot.sh: another shoot.sh (pid $other) is ALREADY writing into $OUT" >&2
    echo "   Concurrent runs interleave silently — that is how a 44-shot run" >&2
    echo "   once reported 49. Point this run at a different OUT= and retry." >&2
    exit 1
  fi
  echo ">> note: clearing a stale lock from pid ${other:-?} (no such process)"
fi
echo $$ > "$LOCK"

# The lock and the server both have to be released however we exit — including
# the loud aborts below, which are new exit paths.
cleanup() {
  # kill + wait, so bash's "Terminated" job notice never lands in a consumer's
  # captured output (the wait reaps the child inside cleanup, silently).
  if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  if [[ "$(cat "$LOCK" 2>/dev/null || true)" == "$$" ]]; then rm -f "$LOCK"; fi
}
trap cleanup EXIT

# Not a refusal — a disclosure. Stale PNGs in $OUT are fine, but you should know
# they are there, because THIS run only reports the shots it actually took.
existing_png="$(find "$OUT" -maxdepth 1 -name '*.png' 2>/dev/null | grep -c . || true)"
if [[ "$existing_png" -gt 0 && "${OUT_REUSE:-}" != "1" ]]; then
  echo ">> note: \$OUT already holds $existing_png PNG(s) from an earlier run."
  echo ">>       This run overwrites only what it re-shoots and counts only its own."
fi

# ── start the preview server ─────────────────────────────────────────────────
SERVE_ERR="$OUT/.serve-stderr"
node "$HERE/serve.mjs" --port "$PORT" >/dev/null 2>"$SERVE_ERR" &
SERVER_PID=$!
# (cleanup + EXIT trap are installed above, with the $OUT lock.)

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
  sed 's/^/   /' "$SERVE_ERR" >&2 2>/dev/null || true
  echo "   try: node $HERE/serve.mjs --port $PORT" >&2
  exit 1
fi

# ── the stale-server guard, CONSUMER SIDE (gr-blk-serve-stale-guard) ─────────
# "The port answers" is not "OUR server answers". A preview server left running
# by a FOREIGN worktree once squatted the port: our serve.mjs died EADDRINUSE
# unheard (stderr went to /dev/null), curl above got its 200 from the squatter,
# and every shot would have rendered ANOTHER TREE's bytes under this tree's
# name — the before/after false green measured live at Decide. serve.mjs now
# refuses and diagnoses on its own (exit 2, "STALE SERVER"), but this consumer
# polls the PORT, so it must also assert the answering server serves THIS
# tree's bytes. cmp, not wc: equal lengths with different bytes must fail too.
for canary in app.css app.js; do
  served_tmp="$OUT/.served-$canary"
  if ! curl -sf "http://localhost:$PORT/$canary" -o "$served_tmp"; then
    echo "!! shoot.sh: the server answered '/' but refused '/$canary' — not a usable preview server." >&2
    sed 's/^/   /' "$SERVE_ERR" >&2 2>/dev/null || true
    exit 1
  fi
  if ! cmp -s "$served_tmp" "$HERE/../$canary"; then
    echo "!! STALE SERVER on :$PORT — /$canary served $(wc -c <"$served_tmp" | tr -d ' ') B but this tree's disk has $(wc -c <"$HERE/../$canary" | tr -d ' ') B." >&2
    echo "   A server rooted at a DIFFERENT tree (a foreign worktree?) is squatting this port." >&2
    echo "   Shooting it would file another tree's pixels under this tree's name — refusing." >&2
    sed 's/^/   /' "$SERVE_ERR" >&2 2>/dev/null || true
    echo "   Find it: lsof -nP -iTCP:$PORT -sTCP:LISTEN" >&2
    exit 1
  fi
  rm -f "$served_tmp"
done

echo ">> Chrome: $CHROME_BIN"
echo ">> Shooting into: $OUT"
echo ">> Census (derived from scenarios.mjs): $SCEN_DEEP of $SCEN_TOTAL scenarios carry a deepLink"

# Portable file size (macOS `stat -f%z`, GNU `stat -c%s`), 0 if absent.
png_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# Is the preview server still answering? Checked ONCE at boot was not enough:
# when node died mid-run every remaining shot captured Chrome's
# ERR_CONNECTION_REFUSED page — non-zero bytes, so the old size-only gate
# printed `ok` for each one and delivered a FULL-COUNT matrix of wrong images.
server_alive() {
  kill -0 "$SERVER_PID" 2>/dev/null || return 1
  curl -sf -o /dev/null --max-time 5 "http://localhost:$PORT/" 2>/dev/null
}

# This run's own tally — never a whole-directory find (see the $OUT guard).
SHOTS_OK=0
SHOTS_FAILED=0

# fd 3 is the REAL stderr. The reap watchdog silences its own fd 2 so bash's
# "Terminated: 15 sleep" job notice — emitted every single shot, once the
# watchdog is retired early — does not bury the honest failures in this log.
# Its own alarm still has to be seen, so that goes to fd 3.
exec 3>&2

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
  # for every scenario that carries a deepLink — the large majority; the run
  # banner prints the live count, DERIVED, because the number this comment used
  # to freeze ("72 of 81") was already two scenario additions out of date —
  # making every accent-suffixed filename a lie (charter GR58). Do not reorder.
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
  # ── Reap, WATCHDOGGED ──────────────────────────────────────────────────────
  # TERM, then wait. The `wait` is the wedge: bash has no wait-with-timeout, and
  # a Chrome that ignores TERM parks this script in __wait4 forever (four
  # measured wedges, up to 10h30m — the `kill -9` below is unreachable until
  # `wait` returns, so it never saved anyone). macOS has no timeout(1), so the
  # bound has to come from OUTSIDE the wait: a watchdog that outlives it.
  #
  # It kills the process TREE. `pkill -9 -P` is NOT optional — a version that
  # killed only $cpid demonstrably left an orphaned renderer behind. Both kills
  # are scoped to a pid THIS script launched; never a broad pattern, because a
  # foreign shoot.sh may be running on the same host.
  kill "$cpid" 2>/dev/null || true
  (
    exec 2>/dev/null # only bash's job notice for our own sleep; alarm goes to fd 3
    sleep "$REAP_BUDGET"
    if kill -0 "$cpid"; then
      echo "  !! watchdog: chrome $cpid ignored TERM for ${REAP_BUDGET}s — killing tree" >&3
      pkill -9 -P "$cpid" || true
      kill -9 "$cpid" || true
    fi
  ) &
  local wd=$!
  wait "$cpid" 2>/dev/null || true
  # Retire the watchdog and its own sleep, so a fast shot leaves nothing behind.
  pkill -P "$wd" 2>/dev/null || true
  kill "$wd" 2>/dev/null || true
  wait "$wd" 2>/dev/null || true
  kill -9 "$cpid" 2>/dev/null || true
  rm -rf "$profile"
  # Size alone is NOT proof: an ERR_CONNECTION_REFUSED page is a perfectly
  # healthy non-empty PNG. Re-check the server before calling this shot good.
  if ! server_alive; then
    echo "!! shoot.sh: preview server on :$PORT stopped answering mid-run." >&2
    echo "!! ${scen}/${theme}/${width}${accent_sfx} and everything after it would be" >&2
    echo "!! Chrome's ERR_CONNECTION_REFUSED page — non-empty, and NOT the screen." >&2
    echo "!! Aborting: $SHOTS_OK shot(s) before this point are usable, this one is not." >&2
    exit 1
  fi
  if [[ "$(png_size "$png")" -gt 0 ]]; then
    SHOTS_OK=$((SHOTS_OK + 1))
    echo "  ok  $(basename "$png")"
  else
    SHOTS_FAILED=$((SHOTS_FAILED + 1))
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

# THIS run's tally, not `find "$OUT"` — the directory may legitimately hold a
# previous run's PNGs (OUT_REUSE=1), and counting those as ours is exactly the
# inflation that made a 44-shot run report 49.
if (( SHOTS_FAILED > 0 )); then
  echo ">> Done with FAILURES. $SHOTS_OK ok, $SHOTS_FAILED failed, into $OUT"
  exit 1
fi
echo ">> Done. $SHOTS_OK PNG(s) shot this run into $OUT"
