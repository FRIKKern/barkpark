#!/usr/bin/env bash
# taskboard-drive — the committed, re-runnable SGR gesture harness for the Go
# task-board TUI (charter D110, task ttw17-bl-live-tmux-drive).
#
# WHAT IT DOES
#   Builds the real binary from ./cmd/barkpark (never `go build .` — the repo
#   root has no Go files), launches it in DETACHED tmux sessions at 130x40
#   (wide) and 70x24 (narrow) against the user's configured Barkpark server,
#   injects raw SGR-1006 mouse bytes per gesture via `tmux send-keys -l`,
#   captures frames with `capture-pane [-e] -p -J`, and asserts each gesture's
#   visible delta. Evidence (normalized frames + located single rows + a
#   machine-written report) lands in scripts/taskboard-drive/evidence/ — the
#   committed copy is the last judged run.
#
# WIRE GRAMMAR (proven in tooling/grip/ledger/task-tui-w19-tmux-sgr-drive-
# protocol-2026-08-17.md, PR #11799):
#   ESC[<Cb;Cx;CyM press / ...m release — Cb: wheel up 64 / down 65, left 0,
#   hover motion 35, drag motion 32, shift 4. Cx/Cy are 1-BASED terminal cells;
#   the app sees ev.X = Cx-1 and composes at cx = Cx-2 (1-col body pad).
#   `tmux new-session -d -x W -y H` alone fixes detached geometry on tmux 3.4.
#
# EVIDENCE LAW (D110): frames churn (braille spinners, elapsed stamps, live SSE
# rows, the conn header flap — filed as ttw19-bl-conn-state-flap) — every
# assert here is either scoped to a single LOCATED row or made on a normalized
# frame (normalize()). Coordinates are LOCATED from a capture each time (the
# persisted details_pane_ratio moves the divider) — never hard-coded.
#
# GRAMMAR TRUTHS the asserts encode (do not "fix" them into failures):
#   - There is NO click-again-descend: a single click is select+activate — a
#     leaf descends on the FIRST click; a click on an epic root toggles its
#     section (partial default -> FULL list -> collapsed -> full; charter
#     D51/D54 — collapse only from the fully-expanded mode).
#   - The divider glyph form encodes focus: "│ " board-focused, " │" reader-
#     focused, "↔↔" while dragging; the ↔ affordance lives on the header row at
#     the gutter columns and RECOLORS on hover (it is always present).
#   - Shift-click reaching the app acts as a plain click; the terminal-native
#     selection bypass is unprovable via send-keys, so it is NOT scored here.
#   - The M-toggle footer note sheds below a 102-col inner board width by
#     design; M is asserted FUNCTIONALLY at wide widths (off → clicks ignored,
#     on → clicks land); the visible note is asserted only on the narrow
#     reading frame, where it fits.
#
# SIDE EFFECTS: the divider-drag gesture rewrites the user's
# taskboard-preferences.json (that IS the persistence proof); the original file
# is backed up first and restored on exit, pass or fail. Two concurrent runs
# would race on that file — run one at a time.
#
# ROW IDENTITY (D118): a row's identity is its rendered TITLE, never its
# absolute line. The board reorders live (spineRows sorts, SSE refetches), so
# every churn-coupled assert — G1 wheel-return, G2/G8 click-landing, G3 root
# fold, narrow wheel — captures the target's title with row_ident() at
# locate-time and re-verifies the SAME task after the gesture (re-locating by
# title with line_of_ident() before each click). The slug/doc_id is the only
# 1:1-unique key but is never painted (task rows and the reader heading render
# Title only), and a 12-char title cut aliased 244/1000 live rows — so the full
# rendered title is the strongest capture-pane identity available.
#
# FLAKINESS: title-anchored asserts survive reorder; the residual risk is two
# visible rows sharing a full title (≤3 groups in a 1000-row census, none within
# one ~40-row viewport in practice). A red run against a healthy board is
# re-runnable; a repeatable red is a finding.
#
# MODES (charter D122, task ttw21-hermetic-drive)
#   DRIVE_MODE=live (default) — the full assert matrix against the user's
#     configured Barkpark server, exactly as before. Churn-coupled asserts
#     (selection identity, fold state, click landing) belong here.
#   DRIVE_MODE=hermetic — the churn-independent geometry/grammar/file-state
#     subset (D118 class) against the committed fixture server
#     (fixture/main.go): a stdlib-only HTTP server serving a fixed corpus over
#     the board's LIVE-pinned surface (list + prime + a held-open SSE listen
#     whose welcome frame pins ● live). The run is byte-deterministic: two
#     consecutive hermetic runs produce identical assert transcripts
#     (hermetic-proof.sh proves it). Hermetic runs point the board at the
#     fixture via BARKPARK_SERVER/BARKPARK_API_TOKEN and redirect
#     XDG_CONFIG_HOME into the run's tempdir, so the user's config and prefs
#     are never read OR written — the G6 drag persistence proof runs against
#     the hermetic prefs file instead.
#   THE CONN MASK BECOMES AN ASSERT: live mode keeps normalize()'s conn-flap
#     mask (offline|live|polling -> CONN); hermetic mode DROPS it and asserts
#     the literal "● live" header glyph at boot and again at run end — the
#     ttw19 conn-flap defect class now has a deterministic tripwire.
#
# USAGE
#   bash scripts/taskboard-drive/drive.sh            # full run; exits 0 on all-pass
#   DRIVE_MODE=hermetic bash .../drive.sh            # fixture-served deterministic subset
#   bash scripts/taskboard-drive/hermetic-proof.sh   # two hermetic runs, empty-diff proof
#   BP_DRIVE_BIN=/path/to/bp bash .../drive.sh       # skip the build step
#   BP_DRIVE_KEEP=1 bash .../drive.sh                # keep tmux server for inspection
set -u -o pipefail

MODE="${DRIVE_MODE:-live}"
case "$MODE" in
  hermetic|live) ;;
  *) echo "FATAL: DRIVE_MODE must be 'hermetic' or 'live' (got '$MODE')" >&2; exit 2 ;;
esac

# True when the churn-coupled (selection-identity) asserts should run — they
# need a real, reordering board to mean anything and stay live-mode (D118).
live_mode() { [ "$MODE" = live ]; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)
# Evidence splits by mode so a hermetic run never clobbers the committed live
# run's artifacts (and vice versa) — each dir is the last judged run OF THAT
# MODE. Hermetic frames pass through normalize() with the conn mask dropped,
# so they too are byte-stable across runs.
if [ "$MODE" = hermetic ]; then
  EVID="$SCRIPT_DIR/evidence-hermetic"
else
  EVID="$SCRIPT_DIR/evidence"
fi
REPORT="$EVID/report.md"
SOCK="tbdrive-$$"
WIDE=wide
NARROW=narrow
TMPD=$(mktemp -d)

# Hermetic isolation happens BEFORE the prefs path is computed: the board
# resolves its config dir from XDG_CONFIG_HOME (internal/cli/config.go), so
# redirecting it into TMPD gives every hermetic run the same virgin config
# state (no user server config, no persisted pane ratio) — determinism AND
# zero side effects on the user's real files. BARKPARK_API_URL is set too
# (envContext prefers it over BARKPARK_SERVER, cli.go envContext) so a value
# inherited from the caller's shell can never re-point a hermetic run.
FIXTURE_PORT="${BP_DRIVE_FIXTURE_PORT:-4799}"
FIXTURE_PID=""
if [ "$MODE" = hermetic ]; then
  export XDG_CONFIG_HOME="$TMPD/xdg"
  mkdir -p "$XDG_CONFIG_HOME/barkpark"
  export BARKPARK_SERVER="http://127.0.0.1:$FIXTURE_PORT"
  export BARKPARK_API_URL="$BARKPARK_SERVER"
  export BARKPARK_API_TOKEN="drive-hermetic"
fi
PREFS="${XDG_CONFIG_HOME:-$HOME/.config}/barkpark/taskboard-preferences.json"
PASS=0
FAIL=0

TMX() { tmux -L "$SOCK" "$@"; }

cleanup() {
  if [ "${BP_DRIVE_KEEP:-}" = "" ]; then
    TMX kill-server 2>/dev/null || true
  else
    echo "keeping tmux server: tmux -L $SOCK attach -t $WIDE"
  fi
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
  fi
  # Restore the user's pane-ratio prefs AFTER the sessions are gone (the app
  # writes the file on drag release only, so post-kill restore is safe).
  if [ -f "$TMPD/prefs.bak" ]; then
    cp "$TMPD/prefs.bak" "$PREFS"
  elif [ "${PREFS_EXISTED:-yes}" = "no" ]; then
    rm -f "$PREFS"
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); echo "PASS  $1"; echo "- PASS — $1" >>"$REPORT"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; echo "- **FAIL** — $1" >>"$REPORT"; }
note(){ echo "        $1"; echo "  - $1" >>"$REPORT"; }

snap()  { TMX capture-pane -t "$1" -p -J; }
snape() { TMX capture-pane -t "$1" -e -p -J; }
sgr()   { TMX send-keys -t "$1" -l "$2"; }

# press+release left click at 1-based terminal cell (col,row)
click() {
  local s=$1 c=$2 r=$3 p rl
  printf -v p '\033[<0;%d;%dM' "$c" "$r"
  printf -v rl '\033[<0;%d;%dm' "$c" "$r"
  sgr "$s" "$p"; sgr "$s" "$rl"
  sleep 0.6
}

# n wheel steps (btn 64 up / 65 down) at (col,row)
wheel() {
  local s=$1 btn=$2 c=$3 r=$4 n=$5 seq i
  printf -v seq '\033[<%d;%d;%dM' "$btn" "$c" "$r"
  i=0; while [ "$i" -lt "$n" ]; do sgr "$s" "$seq"; i=$((i+1)); done
  sleep 0.6
}

# hover motion (btn 35) at (col,row)
hover() {
  local s=$1 c=$2 r=$3 seq
  printf -v seq '\033[<35;%d;%dM' "$c" "$r"
  sgr "$s" "$seq"
  sleep 0.4
}

# Normalize the churn the live board legitimately produces: strip SGR, braille
# spinner frames -> ⠿, elapsed stamps/now -> T. Full-frame evidence is stored
# through this; row-scoped asserts compare located rows exactly.
#
# CONN MASK (live mode ONLY): the conn-state flap (✗ offline|● live|◐ polling
# -> CONN) is masked against a real server, where transient SSE hiccups are the
# network's business. In HERMETIC mode the mask is DROPPED — the fixture's
# held-open welcome stream makes ● live deterministic, so the glyph is asserted
# literally instead of hidden (the ttw19-bl-conn-state-flap tripwire).
normalize() {
  DRIVE_MASK_CONN="$([ "$MODE" = live ] && echo 1 || echo 0)" perl -CSD -Mutf8 -pe '
    s/\e\[[0-9;]*m//g;
    s/[\x{280B}\x{2819}\x{2839}\x{2838}\x{283C}\x{2834}\x{2826}\x{2827}\x{2807}\x{280F}]/\x{283F}/g;
    s/\x{2717} offline|\x{25CF} live|\x{25D0} polling/CONN/g if $ENV{DRIVE_MASK_CONN};
    s/\b\d+[smhdw]\b/T/g;
    s/\bnow\b/T/g;
  '
}

save_frame()      { snap "$1"  | normalize >"$EVID/$2"; }
save_row()        { snap "$1"  | sed -n "$2p" >"$EVID/$3"; }
save_row_styled() { snape "$1" | sed -n "$2p" >"$EVID/$3"; }

# 1-based line number of the compose header row. The header sheds its
# "barkpark · " prefix when the board pane is dragged narrow, so match the ⇄
# server chip first and fall back to the full title.
header_line() { snap "$1" | grep -n -E '⇄|barkpark · tasks' | head -1 | cut -d: -f1; }

# 1-based terminal column of the header's ↔ divider affordance (U+2194).
# The divider form puts it in the gutter's LEFT cell when the board pane is
# focused and the RIGHT cell when the reader is focused — locate, never assume.
arrow_col() {
  local s=$1 hl
  hl=$(header_line "$s")
  [ -n "$hl" ] || { echo ""; return; }
  snap "$s" | sed -n "${hl}p" | perl -CSD -Mutf8 -ne \
    'my $i=0; for my $ch (split //){ $i++; if (ord($ch)==0x2194){ print $i; exit } }'
}

# 1-based line number of the ▎ selection marker
marker_line() { snap "$1" | grep -n '▎' | head -1 | cut -d: -f1; }

# 1-based line number of the first child task row (├─ / └─ spine row)
leaf_line() { snap "$1" | grep -n '^ *[├└]─' | head -1 | cut -d: -f1; }

# 1-based line number of the first epic-root row (carries the "··· n/m" badge)
root_line() { snap "$1" | grep -n '···.*[0-9]/[0-9]' | head -1 | cut -d: -f1; }

# THE ROW-IDENTITY KEY (D118). The board reorders live — spineRows sorts, SSE
# refetches — so a row's ABSOLUTE line is not its identity; the rendered TITLE
# is. The doc_id/slug is the only 1:1-unique key (1000/1000 vs a 12-char title
# cut that aliased 244/1000 live rows), but the slug is never PAINTED: a task
# row renders Title only (components.go:89 rowTitle; DocID is the internal Ref)
# and the reader heading renders Title only (detail_render.go:141). So from a
# capture-pane frame the strongest available identity is the full rendered
# title, and the churn-coupled asserts key on THAT — never an absolute line.
# row_ident strips, in order: the reader pane (everything past the first │), the
# leading gutter tokens (tree ├─└─, ▎ marker, braille spinner, ✓✕○●! status
# glyph, and the ◆ reader-open marker a descended row wears), the "··· n/m"
# section badge, any inline right-meta (a 2+-space gap),
# and the trailing … truncation marker — leaving the task's visible title
# prefix. Works for leaf and epic-root rows, wide and narrow.
row_ident() { snap "$1" | sed -n "$2p" | perl -CSD -Mutf8 -ne '
  s/\x{2502}.*$//;
  s/^\s+//;
  1 while s/^(?:[\x{251C}\x{2514}]\x{2500}|\x{258E}|[\x{2800}-\x{28FF}]|[\x{2713}\x{2715}\x{25CB}\x{25CF}\x{25C6}!\@])\s*//;
  s/\s*\x{00B7}{2,}.*$//;
  s/\s{2,}.*$//;
  s/\s*\x{2026}\s*$//;
  s/\s+$//;
  print;
'; }

# 1-based line of the board row whose row_ident == $2 (empty if that task has
# scrolled/reordered out of view). Re-locate a target by identity immediately
# before each gesture — never reuse a stale absolute line across a reorder.
line_of_ident() {
  snap "$1" | IDENT_WANT="$2" perl -CSD -Mutf8 -ne '
    BEGIN{ $w=$ENV{IDENT_WANT}; }
    my $ln=$.;
    s/\x{2502}.*$//;
    s/^\s+//;
    1 while s/^(?:[\x{251C}\x{2514}]\x{2500}|\x{258E}|[\x{2800}-\x{28FF}]|[\x{2713}\x{2715}\x{25CB}\x{25CF}\x{25C6}!\@])\s*//;
    s/\s*\x{00B7}{2,}.*$//;
    s/\s{2,}.*$//;
    s/\s*\x{2026}\s*$//;
    s/\s+$//;
    if (length($w) && $_ eq $w){ print $ln; exit }
  '
}

# characters of line $2 from character-column $3 on (UTF-8 safe — cut is not)
line_tail() {
  snap "$1" | sed -n "$2p" | perl -CSD -Mutf8 -ne 'print substr($_, '"$(($3-1))"')'
}

wait_ready() {
  local s=$1 tries=0
  while [ "$tries" -lt 60 ]; do
    if snap "$s" | grep -q -E '⇄|barkpark · tasks' && snap "$s" | grep -q '^ *[├└]─'; then
      return 0
    fi
    sleep 0.5; tries=$((tries+1))
  done
  return 1
}

# ── setup ────────────────────────────────────────────────────────────────────
mkdir -p "$EVID"
rm -f "$EVID"/*.txt "$REPORT"
{
  echo "# taskboard-drive report"
  echo
  echo "- date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "- mode: $MODE"
  echo "- tmux: $(tmux -V)"
  echo "- host: $(uname -sm)"
  echo
} >"$REPORT"

if ! tmux -V | grep -Eq 'tmux (3\.[4-9]|[4-9])'; then
  echo "WARN: tmux >= 3.4 expected ($(tmux -V)) — detached -x/-y geometry may not stick" >&2
fi

if [ -f "$PREFS" ]; then
  cp "$PREFS" "$TMPD/prefs.bak"
  PREFS_EXISTED=yes
else
  PREFS_EXISTED=no
fi

# Hermetic mode: build + start the fixture server and wait for it to answer
# BEFORE the board launches — the board's first fetch must land on a live
# fixture, never a race. The fixture is built to a temp binary (not `go run`)
# so cleanup can kill the exact server pid, leaving no orphan child.
if [ "$MODE" = hermetic ]; then
  echo "building fixture (CC=/usr/bin/clang CGO_ENABLED=1 go build ./scripts/taskboard-drive/fixture)..."
  (cd "$REPO" && CC=/usr/bin/clang CGO_ENABLED=1 go build -o "$TMPD/tbfixture" ./scripts/taskboard-drive/fixture) || {
    echo "FATAL: fixture build failed" >&2; exit 1; }
  "$TMPD/tbfixture" -addr "127.0.0.1:$FIXTURE_PORT" >"$TMPD/fixture.log" 2>&1 &
  FIXTURE_PID=$!
  # disown: cleanup's kill must not print bash's "Terminated: … $TMPD/…" job
  # notice — it carries the pid and tempdir path, which would poison the
  # byte-determinism proof's transcript diff.
  disown "$FIXTURE_PID"
  tries=0
  until curl -fsS "http://127.0.0.1:$FIXTURE_PORT/v1/tasks?limit=1" >/dev/null 2>&1; do
    tries=$((tries+1))
    if [ "$tries" -ge 50 ]; then
      echo "FATAL: fixture never answered on 127.0.0.1:$FIXTURE_PORT (log: $(cat "$TMPD/fixture.log" 2>/dev/null))" >&2
      exit 1
    fi
    sleep 0.2
  done
  ok "hermetic fixture serving the live-pinned surface on 127.0.0.1:$FIXTURE_PORT"
fi

BP="${BP_DRIVE_BIN:-}"
if [ -z "$BP" ]; then
  echo "building bp (CC=/usr/bin/clang go build ./cmd/barkpark)..."
  (cd "$REPO" && CC=/usr/bin/clang go build -o "$TMPD/bp" ./cmd/barkpark) || {
    echo "FATAL: go build failed" >&2; exit 1; }
  BP="$TMPD/bp"
fi

TMX kill-server 2>/dev/null || true
TMX new-session -d -x 130 -y 40 -s "$WIDE" "$BP tasks"
TMX new-session -d -x 70 -y 24 -s "$NARROW" "$BP tasks"

geo=$(TMX display -p -t "$WIDE" '#{window_width}x#{window_height}')
if [ "$geo" = "130x40" ]; then ok "wide session geometry is 130x40 detached"; else bad "wide geometry: got $geo, want 130x40"; fi
geo=$(TMX display -p -t "$NARROW" '#{window_width}x#{window_height}')
if [ "$geo" = "70x24" ]; then ok "narrow session geometry is 70x24 detached"; else bad "narrow geometry: got $geo, want 70x24"; fi

if wait_ready "$WIDE"; then ok "wide board painted task rows (configured server reachable)"; else
  bad "wide board never painted task rows — is a Barkpark server configured and reachable?"
  save_frame "$WIDE" boot-wide.txt
  exit 1
fi
wait_ready "$NARROW" || bad "narrow board never painted task rows"

# ── hermetic: the conn glyph is an ASSERT, not masked churn ──────────────────
# The fixture's single welcome frame upgrades ◐ polling -> ● live (OnLivePulse)
# and the held-open stream keeps it there. Wait for the upgrade (sub-second in
# practice, budget 15s), then require the LITERAL glyph — the ttw19 conn-flap
# class now reds deterministically instead of hiding behind the CONN mask.
if [ "$MODE" = hermetic ]; then
  tries=0
  while [ "$tries" -lt 30 ] && ! snap "$WIDE" | grep -q '● live'; do
    sleep 0.5; tries=$((tries+1))
  done
  if snap "$WIDE" | grep -q '● live'; then
    ok "hermetic header pins the literal '● live' glyph (welcome frame upgraded polling->live; CONN mask dropped)"
  else
    bad "hermetic header never showed '● live' within 15s (header: '$(snap "$WIDE" | sed -n "1p")')"
  fi
fi

save_frame "$WIDE" baseline-wide.txt
HL=$(header_line "$WIDE")
note "wide header located on line $HL"

# ── G5+G7: divider hover accent + exact 2-col gutter bounds ──────────────────
# The ↔ affordance recolors and the gutter │ lights on hover; the responding
# column set, probed from behavior, must be EXACTLY the 2 gutter cells.
A=$(arrow_col "$WIDE")
if [ -n "$A" ]; then
  ok "header ↔ divider affordance located at col $A"
else
  bad "no ↔ on header row"
  A=50   # keep later arithmetic alive; asserts will fail honestly
fi
hover "$WIDE" 10 12   # park off-gutter
REST=$(snape "$WIDE" | sed -n "${HL}p")
printf '%s\n' "$REST" >"$EVID/g5-hover-header-rest.txt"
RESPOND=""
for c in $((A-2)) $((A-1)) "$A" $((A+1)) $((A+2)); do
  hover "$WIDE" 10 12
  base=$(snape "$WIDE" | sed -n "${HL}p")
  hover "$WIDE" "$c" 12
  cur=$(snape "$WIDE" | sed -n "${HL}p")
  if [ "$cur" != "$base" ]; then
    RESPOND="$RESPOND $c"
    printf '%s\n' "$cur" >"$EVID/g5-hover-header-col$c.txt"
  fi
done
hover "$WIDE" 10 12
OFF=$(snape "$WIDE" | sed -n "${HL}p")
printf '%s\n' "$OFF" >"$EVID/g5-hover-header-off.txt"
RESPOND=$(echo "$RESPOND" | sed 's/^ *//')
NRESP=$(echo "$RESPOND" | wc -w | tr -d ' ')
GUTL=$A
if [ "$NRESP" = "2" ]; then
  first=${RESPOND%% *}; second=${RESPOND##* }
  if [ "$second" = "$((first+1))" ]; then
    ok "G7 divider hover bounds: exactly 2 contiguous cols respond ($RESPOND); neighbours $((first-1)) and $((second+1)) do not"
    GUTL=$first
  else
    bad "G7 hover-responding cols not contiguous: $RESPOND"
  fi
else
  bad "G7 divider hover bounds: responding cols {$RESPOND} (want exactly 2)"
fi
if [ "$OFF" = "$REST" ]; then
  ok "G5 hover accent paints on gutter hover and restores exactly when the pointer leaves (styled header row diff)"
else
  bad "G5 hover accent did not restore after pointer left the gutter"
fi

# ── G1: wheel down/up moves the board cursor and returns exactly ─────────────
# Selection-identity class (D118) — live mode only.
if live_mode; then
ML0=$(marker_line "$WIDE"); T0=$(row_ident "$WIDE" "$ML0")
save_row "$WIDE" "$ML0" g1-wheel-before.txt
wheel "$WIDE" 65 10 12 3
ML1=$(marker_line "$WIDE"); T1=$(row_ident "$WIDE" "$ML1")
save_row "$WIDE" "$ML1" g1-wheel-after.txt
wheel "$WIDE" 64 10 12 3
ML2=$(marker_line "$WIDE"); T2=$(row_ident "$WIDE" "$ML2")
save_row "$WIDE" "$ML2" g1-wheel-return.txt
if [ -n "$T1" ] && [ "$T1" != "$T0" ]; then
  ok "G1 wheel down x3 moved ▎ selection to a different TASK (\"$T0\" -> \"$T1\")"
else
  bad "G1 wheel down x3 did not change the selected task (still \"$T0\")"
fi
# Return asserts same-TASK by title, never same absolute line: the board
# reorders live inside the gesture window, so ML2==ML0 is the documented flake.
if [ -n "$T2" ] && [ "$T2" = "$T0" ]; then
  ok "G1 wheel up x3 returned ▎ selection to the SAME task \"$T0\" (by title, not absolute line)"
else
  bad "G1 wheel up x3 did not return to task \"$T0\" (now \"$T2\")"
fi
fi  # live_mode G1

# ── G2+G4: single click on a leaf = select + activate (descend, first click) ─
# The GESTURE runs in both modes (the descend is what the hermetic G4 focus-
# flip and esc-grammar asserts observe); the selection-identity (G2) and
# reader-heading-title (G4 heading) asserts are churn-coupled -> live only.
LL=$(leaf_line "$WIDE")
# FULL rendered title as the row identity — NOT a 12-char cut (which aliased
# 244/1000 live rows, D118). row_ident yields the whole visible title prefix.
TITLE=$(row_ident "$WIDE" "$LL")
save_frame "$WIDE" g2-leaf-click-before.txt
A_BEFORE=$(arrow_col "$WIDE")
click "$WIDE" 8 "$LL"
save_frame "$WIDE" g2-leaf-click-after.txt
A_AFTER=$(arrow_col "$WIDE")
if live_mode; then
  MLC=$(marker_line "$WIDE"); TSEL=$(row_ident "$WIDE" "$MLC")
  if [ -n "$TSEL" ] && [ "$TSEL" = "$TITLE" ]; then
    ok "G2 click selected the clicked leaf TASK \"$TITLE\" (▎ on its row, verified by title not absolute line) in ONE gesture"
  else
    bad "G2 click did not select leaf \"$TITLE\" (▎ on task \"${TSEL:-none}\")"
  fi
fi
# descend proof: focus flips to reader (↔ shifts to the gutter's right cell)
# AND the reading pane heading now carries the clicked row's title.
if [ "${A_AFTER:-0}" = "$((A_BEFORE+1))" ]; then
  ok "G4 leaf descended on FIRST click: divider form flipped board->reader (↔ col $A_BEFORE -> $A_AFTER)"
else
  bad "G4 no reader-focus flip after leaf click (↔ col $A_BEFORE -> ${A_AFTER:-none})"
fi
if live_mode; then
  RP1=$(line_tail "$WIDE" "$((HL+1))" "$((GUTL+2))")
  RP2=$(line_tail "$WIDE" "$((HL+2))" "$((GUTL+2))")
  if printf '%s\n%s\n' "$RP1" "$RP2" | grep -qF "$TITLE"; then
    ok "G4 reading pane heading (right of the gutter) shows the clicked task (\"$TITLE\")"
  else
    bad "G4 reading pane heading does not show \"$TITLE\""
  fi
fi
TMX send-keys -t "$WIDE" Escape
sleep 0.5
if snap "$WIDE" | grep -q 'esc back'; then
  ok "esc after descend: board footer still present (ascended cleanly)"
else
  bad "esc after descend: board footer missing"
fi

# ── G3: clicking an epic root toggles its section fold state ─────────────────
# Selection-identity class (D118) — live mode only.
# The activate reducer's true grammar (charter D51/D54): a section showing ALL
# children collapses to just the header; any other mode (the partial
# focus/header default included) expands to the FULL list. So from the usual
# partial baseline the sequence is: click1 -> full, click2 -> collapsed,
# click3 -> full; from a fully-expanded baseline click1 collapses directly.
# board_region: the board-pane side of rows RL..RL+8, normalized (churn-law).
if live_mode; then
board_region() {
  snap "$WIDE" | sed -n "$1,$2p" | normalize | perl -CSD -Mutf8 -ne \
    'print substr($_, 0, '"$((GUTL-1))"'), "\n"'
}
was_child() { printf '%s' "$1" | grep -q '^ *[├└]─'; }
# Re-locate the SAME epic root by its title (never the first "··· n/m" badge via
# head -1 — every root paints one, so head -1 is order-dependent and the board
# reorders between clicks). Fall back to the first root only if that title has
# scrolled out of view. Call immediately before each click and each row read.
RTITLE=""
relocate_root() {
  local rl=""
  [ -n "$RTITLE" ] && rl=$(line_of_ident "$WIDE" "$RTITLE")
  [ -n "$rl" ] || rl=$(root_line "$WIDE")
  echo "$rl"
}
RL=$(root_line "$WIDE")
RTITLE=$(row_ident "$WIDE" "$RL")
note "G3 anchored epic root by title: \"$RTITLE\""
REGION0=$(board_region "$RL" "$((RL+8))")
save_row "$WIDE" "$RL,$((RL+8))" g3-fold-before.txt
RL=$(relocate_root)
click "$WIDE" 8 "$RL"
RL=$(relocate_root)
S1=$(snap "$WIDE" | sed -n "$((RL+1))p")
REGION1=$(board_region "$RL" "$((RL+8))")
save_row "$WIDE" "$RL,$((RL+8))" g3-fold-click1.txt
if ! was_child "$S1"; then
  # baseline was fully expanded: click1 collapsed the section to its header
  ok "G3 click on the epic root COLLAPSED it (row $((RL+1)) lost its ├─ child)"
  RL=$(relocate_root)
  click "$WIDE" 8 "$RL"
  RL=$(relocate_root)
  S2=$(snap "$WIDE" | sed -n "$((RL+1))p")
  save_row "$WIDE" "$RL,$((RL+8))" g3-fold-click2.txt
  if was_child "$S2"; then
    ok "G3 second click on the root EXPANDED it back (├─ child on row $((RL+1)))"
  else
    bad "G3 second root click did not expand (row $((RL+1)): '$S2')"
  fi
else
  # baseline was the partial default: click1 must have expanded to the full
  # list (the section's board-side region changes), click2 collapses, click3
  # expands again.
  if [ "$REGION1" != "$REGION0" ]; then
    ok "G3 click on the epic root toggled its section (partial -> full: board-side region changed)"
  else
    bad "G3 root click changed nothing in the section region"
  fi
  RL=$(relocate_root)
  click "$WIDE" 8 "$RL"
  RL=$(relocate_root)
  S2=$(snap "$WIDE" | sed -n "$((RL+1))p")
  save_row "$WIDE" "$RL,$((RL+8))" g3-fold-click2.txt
  if ! was_child "$S2"; then
    ok "G3 second click COLLAPSED the root to its header (row $((RL+1)) lost its ├─ child)"
  else
    bad "G3 second root click did not collapse (row $((RL+1)): '$S2')"
  fi
  RL=$(relocate_root)
  click "$WIDE" 8 "$RL"
  RL=$(relocate_root)
  S3=$(snap "$WIDE" | sed -n "$((RL+1))p")
  save_row "$WIDE" "$RL,$((RL+8))" g3-fold-click3.txt
  if was_child "$S3"; then
    ok "G3 third click EXPANDED the section again (├─ child back on row $((RL+1)))"
  else
    bad "G3 third root click did not expand (row $((RL+1)): '$S3')"
  fi
fi
fi  # live_mode G3

# ── G6: divider drag moves the split, persists, survives kill+relaunch ───────
RATIO_BEFORE=$(grep -o '"details_pane_ratio":[0-9.]*' "$PREFS" 2>/dev/null || echo none)
A0=$(arrow_col "$WIDE")
[ -n "$A0" ] || A0=$GUTL
TARGET=$((A0-10))
save_row "$WIDE" "$HL" g6-drag-before-header.txt
printf -v seq '\033[<0;%d;12M' "$GUTL";      sgr "$WIDE" "$seq"; sleep 0.2
printf -v seq '\033[<32;%d;12M' "$((A0-5))"; sgr "$WIDE" "$seq"; sleep 0.15
printf -v seq '\033[<32;%d;12M' "$TARGET";   sgr "$WIDE" "$seq"; sleep 0.3
MID=$(snap "$WIDE" | sed -n "${HL}p")
printf '%s\n' "$MID" >"$EVID/g6-drag-mid-header.txt"
printf -v seq '\033[<0;%d;12m' "$TARGET";    sgr "$WIDE" "$seq"; sleep 0.6
A1=$(arrow_col "$WIDE")
save_row "$WIDE" "$HL" g6-drag-after-header.txt
if printf '%s' "$MID" | grep -q '↔↔'; then
  ok "G6 drag-in-progress paints the ↔↔ grabbed affordance"
else
  bad "G6 no ↔↔ during drag (header: '$MID')"
fi
if [ -n "$A1" ] && [ "$A1" -ge "$((TARGET-1))" ] && [ "$A1" -le "$((TARGET+1))" ]; then
  ok "G6 divider followed the drag: ↔ col $A0 -> $A1 (target $TARGET)"
else
  bad "G6 divider did not land near target: ↔ col $A0 -> ${A1:-none}, want ~$TARGET"
fi
RATIO_AFTER=$(grep -o '"details_pane_ratio":[0-9.]*' "$PREFS" 2>/dev/null || echo none)
{
  echo "before: $RATIO_BEFORE"
  echo "after:  $RATIO_AFTER"
} >"$EVID/g6-prefs.txt"
if [ "$RATIO_AFTER" != "$RATIO_BEFORE" ] && [ "$RATIO_AFTER" != "none" ]; then
  ok "G6 drag release rewrote taskboard-preferences.json ($RATIO_BEFORE -> $RATIO_AFTER)"
else
  bad "G6 prefs not rewritten on release ($RATIO_BEFORE -> $RATIO_AFTER)"
fi
TMX kill-session -t "$WIDE"
TMX new-session -d -x 130 -y 40 -s "$WIDE" "$BP tasks"
if wait_ready "$WIDE"; then
  HL=$(header_line "$WIDE")
  A2=$(arrow_col "$WIDE")
  save_row "$WIDE" "$HL" g6-relaunch-header.txt
  if [ -n "$A2" ] && [ -n "$A1" ] && [ "$A2" -ge "$((A1-1))" ] && [ "$A2" -le "$((A1+1))" ]; then
    ok "G6 dragged split PERSISTED across kill+relaunch (↔ col $A2 ~ $A1)"
  else
    bad "G6 split did not persist: relaunch ↔ col ${A2:-none}, want ~${A1:-?}"
  fi
else
  bad "G6 relaunched wide board never painted"
fi

# ── G8: M toggle — mouse off ignores clicks, on lands them ───────────────────
# Click-landing identity class (D118) — live mode only.
if live_mode; then
sgr "$WIDE" "M"; sleep 0.4
LL=$(leaf_line "$WIDE")
LTITLE=$(row_ident "$WIDE" "$LL")
MB=$(marker_line "$WIDE"); TB=$(row_ident "$WIDE" "$MB")
save_row "$WIDE" "$LL" g8-m-off-target-row.txt
click "$WIDE" 8 "$LL"
MA=$(marker_line "$WIDE"); TA=$(row_ident "$WIDE" "$MA")
# "Ignored" means the SELECTED TASK is unchanged — by title, not absolute line
# (SSE churn can shift the selected row's line without any click landing).
if [ "$TA" = "$TB" ]; then
  ok "G8 with mouse released (M), a click is ignored (selection stayed on task \"$TB\")"
else
  bad "G8 mouse-off click still moved ▎ (task \"$TB\" -> \"$TA\")"
fi
sgr "$WIDE" "M"; sleep 0.4
# Re-locate the same leaf by title before the re-enable click (the board may
# have reordered while M was off).
LL=$(line_of_ident "$WIDE" "$LTITLE"); [ -n "$LL" ] || LL=$(leaf_line "$WIDE")
click "$WIDE" 8 "$LL"
MA2=$(marker_line "$WIDE"); TA2=$(row_ident "$WIDE" "$MA2")
save_row "$WIDE" "$LL" g8-m-on-landed-row.txt
if [ "$TA2" = "$LTITLE" ]; then
  ok "G8 after M re-enable, the same click lands (▎ moved to task \"$LTITLE\")"
else
  bad "G8 re-enabled click did not land (▎ on task \"${TA2:-none}\", want \"$LTITLE\")"
fi
fi  # live_mode G8

# ── narrow session: wheel, first-click descend, reading footer M note ────────
# The wheel-identity assert is churn-coupled -> live only; the footer-shed,
# reading-frame M note and esc-grammar asserts are geometry/grammar -> both.
NL=$(leaf_line "$NARROW"); NLTITLE=$(row_ident "$NARROW" "$NL")
if live_mode; then
  NM0=$(marker_line "$NARROW"); NT0=$(row_ident "$NARROW" "$NM0")
  wheel "$NARROW" 65 10 8 2
  NM1=$(marker_line "$NARROW"); NT1=$(row_ident "$NARROW" "$NM1")
  wheel "$NARROW" 64 10 8 2
  if [ -n "$NT1" ] && [ "$NT1" != "$NT0" ]; then
    ok "narrow wheel moved ▎ selection to a different TASK (\"$NT0\" -> \"$NT1\")"
  else
    bad "narrow wheel did not change the selected task (still \"$NT0\")"
  fi
fi
save_frame "$NARROW" n-narrow-board.txt
if snap "$NARROW" | grep -q 'M mouse'; then
  bad "narrow BOARD footer already shows 'M mouse' (expected shed below 102-col inner)"
else
  ok "narrow board footer sheds the M note (shed-ladder design, <102-col inner)"
fi
# Re-locate the same leaf by title before the descend click (the two wheel
# passes and live SSE can have reordered the board since NL was first read).
NL=$(line_of_ident "$NARROW" "$NLTITLE"); [ -n "$NL" ] || NL=$(leaf_line "$NARROW")
click "$NARROW" 6 "$NL"
save_frame "$NARROW" n-narrow-reading.txt
if snap "$NARROW" | grep -q 'M mouse'; then
  ok "narrow first-click descend reached the reading frame (footer shows the M mouse note)"
else
  bad "narrow reading footer does not show 'M mouse' after leaf click"
fi
TMX send-keys -t "$NARROW" Escape
sleep 0.5
if snap "$NARROW" | grep -q '^ *[├└]─'; then
  ok "narrow esc ascended back to the board"
else
  bad "narrow esc did not return to the board"
fi

# ── hermetic: ● live is STILL pinned at run end ──────────────────────────────
# The wide session was killed and relaunched inside G6, so this re-assert
# proves the relaunched board re-subscribed and the fixture stream held —
# stability across the whole run, not a lucky boot-time read. (No export
# endpoint exists on the fixture, so any silent fallback to polling reds here.)
if [ "$MODE" = hermetic ]; then
  tries=0
  while [ "$tries" -lt 10 ] && ! snap "$WIDE" | grep -q '● live'; do
    sleep 0.5; tries=$((tries+1))
  done
  if snap "$WIDE" | grep -q '● live'; then
    ok "hermetic '● live' still pinned at run end (held-open stream survived the G6 relaunch; no polling fallback)"
  else
    bad "hermetic '● live' lost by run end (header: '$(snap "$WIDE" | sed -n "1p")')"
  fi
fi

# ── verdict ──────────────────────────────────────────────────────────────────
{
  echo
  echo "## totals"
  echo
  echo "- pass: $PASS"
  echo "- fail: $FAIL"
} >>"$REPORT"
echo
echo "taskboard-drive: $PASS pass, $FAIL fail — evidence in $EVID"
[ "$FAIL" -eq 0 ]
