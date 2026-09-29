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
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/bp-curl.sh"   # 429 backoff, shared (task-c2f96f8121c64601)

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

# PIN THE COLOR PROFILE THE WAY WE PIN THE GEOMETRY. The board resolves its
# lipgloss profile from the PANE's environment (termenv ColorProfile: TERM +
# COLORTERM + TERM_PROGRAM), and tmux hands a pane whatever `default-terminal`
# says — plain "screen" when no ~/.tmux.conf sets otherwise. termenv maps a bare
# "screen" to **Ascii**, so on such a host the board paints with NO SGR AT ALL
# and every style-keyed assert here is silently unmeasurable — it compares two
# unstyled rows and reports "no response" rather than "I could not see".
#
# MEASURED on ubuntu-latest (PR #18858's first advisory run): capture-pane -e
# returned the header row with ZERO escape sequences, and G7 read {} responding
# columns on a healthy gutter. Darwin hosts pass only because the developer's
# tmux.conf happens to set a 256color default-terminal.
#
# So the harness pins it: COLORTERM=truecolor + TERM_PROGRAM=tmux take termenv's
# truecolor branch for a "screen*" TERM, and terminal-features RGB keeps tmux
# from downsampling the 38;2;r;g;b it stores and re-emits. Same bytes on every
# host — the same reason -x/-y is pinned rather than inherited.
# MEASURED, in this order, on ubuntu-latest: tmux's own `default-terminal`
# option plus `new-session -e` did NOT style the pane; forcing TERM/COLORTERM on
# the app's command line did NOT either. The actual gate is `CI`:
#
#   termenv.go:28  func (o *Output) isTTY() bool {
#   termenv.go:32    if len(o.environ.Getenv("CI")) > 0 { return false }
#
# and ColorProfile() returns Ascii the moment isTTY() is false — before TERM or
# COLORTERM is read at all. Every GitHub runner exports CI=true, so the board
# painted with zero SGR and every style-keyed assert here was unmeasurable.
#
# The pane genuinely IS a tty, so `env -u CI` is the honest correction, not a
# workaround: it tells termenv the truth about the thing it is asking about.
# TERM/COLORTERM/TERM_PROGRAM stay pinned so the profile is TrueColor rather
# than whatever the host's tmux.conf happens to imply, and terminal-features RGB
# keeps tmux from downsampling the 38;2;r;g;b it stores and re-emits — the same
# captured bytes on every host. BP_ENV is the launch prefix every new-session
# uses.
pin_pane_color() {
  TMX set-option -g  default-terminal  screen-256color >/dev/null 2>&1 || true
  TMX set-option -ga terminal-features ",*:RGB"        >/dev/null 2>&1 || true
}
PANE_ENV=(-e COLORTERM=truecolor -e TERM_PROGRAM=tmux -e TERM=screen-256color)
BP_ENV="env -u CI TERM=screen-256color COLORTERM=truecolor TERM_PROGRAM=tmux"

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
# NEVER `snap … | grep -q`.  Under this script's `set -o pipefail` a matching
# `grep -q` exits on the FIRST hit, capture-pane takes SIGPIPE, and pipefail
# hands the pipeline 141 — so a pane that DOES show the thing reads as "not
# there".  A full pane capture is 20-60 lines with the match usually near the
# top, which is exactly the many-lines/early-match shape that fires it (a
# ~512 B pipe on darwin, 64 KB on the Linux runners).  Capture first, then
# match a here-string: no producer process is left to kill.
snap_has()  { grep -q  "$2" <<<"$(snap "$1")"; }
snap_hasE() { grep -qE "$2" <<<"$(snap "$1")"; }
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
# save_row's normalized twin. A raw row save is only byte-stable if the row
# carries no churn — a CLAIMED row paints a live braille spinner, so saving one
# raw makes two otherwise identical hermetic runs differ by one glyph (measured:
# ⠧ vs ⠦ on the same assert). Any row save that can land on a claimed task goes
# through normalize().
save_row_norm()   { snap "$1"  | sed -n "$2p" | normalize >"$EVID/$3"; }
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

# THE STYLED DIVIDER CELL of a captured header row: the ↔ affordance together
# with the SGR state that applies to it. Compose paints the ENTIRE divider —
# every gutter cell, every row — with ONE style (compose.go: dividerRestStyle,
# swapped for dividerHoverStyle when m.wideDividerHover, dividerGrabbedStyle
# while dragging), so this one cell is a complete and faithful readout of the
# gutter hit-test's answer for the whole gutter.
#
# WHY G7 READS THIS AND NOT THE WHOLE HEADER ROW. The header row's TAIL is the
# reading pane's preview heading, and that heading reverts from the hovered
# board row's title to the cursor's title the instant the pointer leaves the
# board. A whole-row diff therefore calls EVERY off-board column "responding",
# accent or not: col boardW+2 sits inside the reader pane, carries no hover
# accent SGR at all, and still differed from the off-gutter baseline — by the
# heading alone ("Harbor lights epic" vs "Mulch the seedling beds") — so a
# healthy 2-cell gutter measured as three responding columns. That is churn
# coupling, the one thing this harness's evidence law forbids (it is why G1/G2/
# G3/G4/G8 are banished to live mode). The fix is to narrow what the probe
# MEASURES, never to widen paneGutter2 to satisfy it.
#
# Reads one styled row on stdin, prints "<active SGR><↔>", or NO-DIVIDER when
# the row carries no affordance. It never exits early mid-pipe: a `grep -q`-
# shaped SIGPIPE under this script's pipefail is exactly how a probe lies (see
# snap_has above).
divider_cell_styled() {
  perl -CSD -Mutf8 -ne '
    chomp;
    my $s = $_;
    my @st;
    my $cell = "NO-DIVIDER";
    while (length $s) {
      if ($s =~ s/^\e\[([0-9;]*)m//) {
        my $p = $1;
        if ($p eq "" || $p eq "0") { @st = () } else { push @st, "\e[" . $p . "m" }
        next;
      }
      $s =~ s/^(.)//s;
      if (ord($1) == 0x2194) { $cell = join("", @st) . $1; last }
    }
    print $cell, "\n";
  '
}

# 1-based line number of the ▎ selection marker
marker_line() { snap "$1" | grep -n '▎' | head -1 | cut -d: -f1; }

# 1-based line numbers of the BOARD spine's COUNTED overflow affordances —
# windowSpine's "↑ N more above" / "↓ N more below" (render.go). The count is
# what distinguishes them from the reading/preview pane's COUNTLESS "↑ more
# above" / "↓ more below" affordance (rightPaneMarkerAt), which is a different
# thing entirely: the counted board markers are click-targets that step the
# cursor (D119, wideBoardMarkerAt -> moveCursor), the countless ones are not.
# The `^ *` anchor keeps the match on the board side of the gutter — the reader
# pane's marker is always indented past the divider.
board_down_marker_line() { snap "$1" | grep -nE '^ *↓ [0-9]+ more below' | head -1 | cut -d: -f1; }
board_up_marker_line()   { snap "$1" | grep -nE '^ *↑ [0-9]+ more above' | head -1 | cut -d: -f1; }

# press a key literally and let the board settle
key() { sgr "$1" "$2"; sleep 0.4; }

# drive the cursor to the very top: moveCursor clamps at row 0, so N k-presses
# for any N past the spine length is an idempotent "go home" — used to restore
# the pre-gesture state so the asserts that follow see the same board.
cursor_home() {
  local i=0
  while [ "$i" -lt 60 ]; do sgr "$1" "k"; i=$((i+1)); done
  sleep 0.6
}

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
    if snap_hasE "$s" '⇄|barkpark · tasks' && snap_has "$s" '^ *[├└]─'; then
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

if ! grep -qE 'tmux (3\.[4-9]|[4-9])' <<<"$(tmux -V 2>&1)"; then
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
  until bp_curl_body -sS "http://127.0.0.1:$FIXTURE_PORT/v1/tasks?limit=1" >/dev/null 2>&1; do
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
pin_pane_color
TMX new-session -d "${PANE_ENV[@]}" -x 130 -y 40 -s "$WIDE" "$BP_ENV $BP tasks"
TMX new-session -d "${PANE_ENV[@]}" -x 70 -y 24 -s "$NARROW" "$BP_ENV $BP tasks"

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
  while [ "$tries" -lt 30 ] && ! snap_has "$WIDE" '● live'; do
    sleep 0.5; tries=$((tries+1))
  done
  if snap_has "$WIDE" '● live'; then
    ok "hermetic header pins the literal '● live' glyph (welcome frame upgraded polling->live; CONN mask dropped)"
  else
    bad "hermetic header never showed '● live' within 15s (header: '$(snap "$WIDE" | sed -n "1p")')"
  fi
fi

save_frame "$WIDE" baseline-wide.txt
HL=$(header_line "$WIDE")
note "wide header located on line $HL"

# ── G9+G10 (hermetic): the COUNTED spine overflow markers paint, and a click
# ── on one steps the cursor exactly one row (D119, D130) ─────────────────────
# PRECONDITION, not decoration: windowSpine paints these affordances only while
# len(spineLines) > avail. The 11-doc fixture corpus did not overflow the wide
# spine at 130x40, so before ttw22-fixture-overflow-enrichment grew it these
# asserts could not have fired AT ALL — and a gesture class that cannot fire is
# indistinguishable from one that passes. The enriched corpus (fixture/main.go,
# floors in auditCorpus) makes the overflow a boot-time fact, and the first
# assert below is the tripwire that says so out loud if it ever stops being one.
#
# "Exactly one step" is measured DIFFERENTIALLY, against the keyboard: one `j`
# is the definition of one step, so the marker click is required to land on the
# SAME task one `j` lands on — no line arithmetic, no assumption about which row
# follows which, and immune to the window scrolling under the gesture.
if [ "$MODE" = hermetic ]; then
  MK_DOWN=$(board_down_marker_line "$WIDE")
  MK_UP=$(board_up_marker_line "$WIDE")
  if [ -n "$MK_DOWN" ]; then
    save_row_norm "$WIDE" "$MK_DOWN" g9-marker-down-boot.txt
    ok "G9 wide spine OVERFLOWS at 130x40: counted '$(snap "$WIDE" | sed -n "${MK_DOWN}p" | sed 's/│.*$//; s/^ *//; s/ *$//')' painted on board line $MK_DOWN"
  else
    bad "G9 no counted '↓ N more below' on the wide board — the fixture corpus no longer overflows the spine, so every marker assert below is measuring nothing"
  fi
  # At boot the window is pinned at the top (slideTop top=0), so the UP marker
  # must be ABSENT. This is the quiet arm: it says the markers track the window
  # rather than being unconditional chrome.
  if [ -z "$MK_UP" ]; then
    ok "G9 no counted '↑ N more above' at boot (window pinned at top=0 — the markers track the window, they are not unconditional chrome)"
  else
    bad "G9 counted up-marker painted at boot on line $MK_UP (window should be pinned at top=0)"
  fi

  # ── G10: click the DOWN marker == one `j` ──────────────────────────────────
  M0=$(marker_line "$WIDE"); T0=$(row_ident "$WIDE" "$M0")
  key "$WIDE" "j"
  MJ=$(marker_line "$WIDE"); TJ=$(row_ident "$WIDE" "$MJ")
  key "$WIDE" "k"
  MB=$(marker_line "$WIDE"); TB=$(row_ident "$WIDE" "$MB")
  if [ -n "$TJ" ] && [ "$TJ" != "$T0" ] && [ "$TB" = "$T0" ]; then
    note "G10 calibrated one keyboard step: \"$T0\" -j-> \"$TJ\" -k-> \"$TB\""
  else
    bad "G10 keyboard calibration failed (\"$T0\" -j-> \"${TJ:-none}\" -k-> \"${TB:-none}\") — the click comparison below would be vacuous"
  fi
  MK_DOWN=$(board_down_marker_line "$WIDE")
  if [ -n "$MK_DOWN" ] && [ -n "$TJ" ] && [ "$TJ" != "$T0" ]; then
    click "$WIDE" 8 "$MK_DOWN"
    MC=$(marker_line "$WIDE"); TC=$(row_ident "$WIDE" "$MC")
    save_row_norm "$WIDE" "$MC" g10-marker-click-selected-row.txt
    if [ "$TC" = "$TJ" ]; then
      ok "G10 click on the counted ↓ overflow marker (line $MK_DOWN) stepped the cursor EXACTLY one row: \"$T0\" -> \"$TC\", the same task one \`j\` selects (D119 wideBoardMarkerAt -> moveCursor)"
    else
      bad "G10 ↓ marker click did not step exactly one row (\"$T0\" -> \"${TC:-none}\", one \`j\` gives \"$TJ\")"
    fi
  else
    bad "G10 could not run: down-marker line '${MK_DOWN:-none}', keyboard step \"$T0\" -> \"${TJ:-none}\""
  fi

  # ── G10b: scroll the window off the top, then click the UP marker == one `k` ─
  # Walk DOWN from the top one row at a time until the window first slides —
  # the instant the ↑ marker appears, top has just left 0 while the spine tail
  # is still hidden, so BOTH counted markers are on screen. Walking to the
  # condition is a PREDICATE; a hard-coded press count would be a guess that
  # silently lands on the wrong window the moment the corpus or the pane
  # geometry changes (and at the spine's bottom only the ↑ marker paints, so
  # "press a lot" is not the same gesture at all).
  cursor_home "$WIDE"
  i=0
  MK_UP=$(board_up_marker_line "$WIDE")
  while [ "$i" -lt 60 ] && [ -z "$MK_UP" ]; do
    sgr "$WIDE" "j"; sleep 0.2; i=$((i+1))
    MK_UP=$(board_up_marker_line "$WIDE")
  done
  MK_DOWN=$(board_down_marker_line "$WIDE")
  note "G9 walked $i rows down from the top before the window first slid"
  if [ -n "$MK_UP" ] && [ -n "$MK_DOWN" ]; then
    save_row_norm "$WIDE" "$MK_UP" g9-marker-up-scrolled.txt
    ok "G9 both counted markers paint once the window has scrolled off the top (↑ line $MK_UP, ↓ line $MK_DOWN)"
  else
    bad "G9 scrolled window did not paint both counted markers (↑ '${MK_UP:-none}', ↓ '${MK_DOWN:-none}')"
  fi
  MS=$(marker_line "$WIDE"); TS=$(row_ident "$WIDE" "$MS")
  key "$WIDE" "k"
  MK=$(marker_line "$WIDE"); TK=$(row_ident "$WIDE" "$MK")
  key "$WIDE" "j"
  MK_UP=$(board_up_marker_line "$WIDE")
  if [ -n "$MK_UP" ] && [ -n "$TK" ] && [ "$TK" != "$TS" ]; then
    click "$WIDE" 8 "$MK_UP"
    MU=$(marker_line "$WIDE"); TU=$(row_ident "$WIDE" "$MU")
    if [ "$TU" = "$TK" ]; then
      ok "G10b click on the counted ↑ overflow marker (line $MK_UP) stepped the cursor EXACTLY one row BACK: \"$TS\" -> \"$TU\", the same task one \`k\` selects"
    else
      bad "G10b ↑ marker click did not step exactly one row back (\"$TS\" -> \"${TU:-none}\", one \`k\` gives \"$TK\")"
    fi
  else
    bad "G10b could not run: up-marker line '${MK_UP:-none}', keyboard step \"$TS\" -> \"${TK:-none}\""
  fi

  # Restore the pre-gesture board: every assert after this one was written
  # against the boot cursor position.
  cursor_home "$WIDE"
  MH=$(marker_line "$WIDE"); TH=$(row_ident "$WIDE" "$MH")
  if [ "$TH" = "$T0" ]; then
    ok "G10 board restored to its boot cursor row (\"$T0\") — the asserts that follow see the baseline board"
  else
    bad "G10 board not restored after the marker gestures (▎ on \"${TH:-none}\", want \"$T0\")"
  fi
fi

# ── G5+G7: divider hover accent + exact 2-col gutter bounds ──────────────────
# The ↔ affordance recolors and the gutter │ lights on hover; the responding
# column set, probed from behavior, must be EXACTLY the 2 gutter cells.
#
# G7's per-column probe reads the STYLED DIVIDER CELL (divider_cell_styled),
# not the whole header row — see that helper for why the whole-row form was a
# churn-coupled probe that read a healthy 2-cell gutter as three. G5's restore
# assert below DOES keep the whole-row comparison on purpose: "the accent
# restored exactly" is a claim about the entire painted row, and both of its
# captures are taken from the same parked pointer position, so no heading churn
# separates them.
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
# PRECONDITION, LOUD AND NAMED. The divider hover accent is a STYLE, so a
# capture carrying no SGR at all cannot answer G7 either way — it would report
# an empty responding set, which reads exactly like "the hit-test responds
# nowhere" and is in fact "this probe could not see". That is precisely how the
# unstyled-pane defect hid: on a host whose tmux hands the pane a bare "screen"
# TERM, termenv resolves Ascii and the board paints with zero escapes. An
# absence is never caught by inspecting the result; assert the precondition.
if grep -q $'\033\[' <<<"$REST"; then
  ok "G7 precondition: the captured header row carries SGR — the pane is styled, so a hover-accent probe can see"
else
  bad "G7 precondition: the captured header row carries NO SGR — the pane is UNSTYLED (termenv resolved Ascii; check the pane's TERM/COLORTERM, pin_pane_color) and every style-keyed assert below is unmeasurable, not merely failing"
fi
RESPOND=""
for c in $((A-2)) $((A-1)) "$A" $((A+1)) $((A+2)); do
  hover "$WIDE" 10 12
  base=$(snape "$WIDE" | sed -n "${HL}p" | divider_cell_styled)
  hover "$WIDE" "$c" 12
  currow=$(snape "$WIDE" | sed -n "${HL}p")
  cur=$(printf '%s\n' "$currow" | divider_cell_styled)
  if [ "$cur" != "$base" ]; then
    RESPOND="$RESPOND $c"
    printf '%s\n' "$currow" >"$EVID/g5-hover-header-col$c.txt"
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
    ok "G7 divider hover bounds: exactly 2 contiguous cols light the divider cell ($RESPOND); neighbours $((first-1)) and $((second+1)) do not"
    GUTL=$first
  else
    bad "G7 divider-cell-lighting cols not contiguous: $RESPOND"
  fi
else
  bad "G7 divider hover bounds: cols lighting the divider cell {$RESPOND} (want exactly 2)"
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
  # A builtin `case` over the two captured lines — a pipe into `grep -qF`
  # would return 141 whenever the heading is long enough to fill the buffer.
  if case "$RP1"$'\n'"$RP2" in *"$TITLE"*) true ;; *) false ;; esac; then
    ok "G4 reading pane heading (right of the gutter) shows the clicked task (\"$TITLE\")"
  else
    bad "G4 reading pane heading does not show \"$TITLE\""
  fi
fi
TMX send-keys -t "$WIDE" Escape
sleep 0.5
if snap_has "$WIDE" 'esc back'; then
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
was_child() { grep -q '^ *[├└]─' <<<"$1"; }
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
if case "$MID" in *'↔↔'*) true ;; *) false ;; esac; then
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
pin_pane_color
TMX new-session -d "${PANE_ENV[@]}" -x 130 -y 40 -s "$WIDE" "$BP_ENV $BP tasks"
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
if snap_has "$NARROW" 'M mouse'; then
  bad "narrow BOARD footer already shows 'M mouse' (expected shed below 102-col inner)"
else
  ok "narrow board footer sheds the M note (shed-ladder design, <102-col inner)"
fi
# Re-locate the same leaf by title before the descend click (the two wheel
# passes and live SSE can have reordered the board since NL was first read).
NL=$(line_of_ident "$NARROW" "$NLTITLE"); [ -n "$NL" ] || NL=$(leaf_line "$NARROW")
click "$NARROW" 6 "$NL"
save_frame "$NARROW" n-narrow-reading.txt
if snap_has "$NARROW" 'M mouse'; then
  ok "narrow first-click descend reached the reading frame (footer shows the M mouse note)"
else
  bad "narrow reading footer does not show 'M mouse' after leaf click"
fi
TMX send-keys -t "$NARROW" Escape
sleep 0.5
if snap_has "$NARROW" '^ *[├└]─'; then
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
  while [ "$tries" -lt 10 ] && ! snap_has "$WIDE" '● live'; do
    sleep 0.5; tries=$((tries+1))
  done
  if snap_has "$WIDE" '● live'; then
    ok "hermetic '● live' still pinned at run end (held-open stream survived the G6 relaunch; no polling fallback)"
  else
    bad "hermetic '● live' lost by run end (header: '$(snap "$WIDE" | sed -n "1p")')"
  fi
fi

# ── README floor arm (hermetic only) ──────────────────────────────
# A number written into a doc rots the moment someone adds an assert, and this
# README's floor had rotted by SEVEN (it said 18 while the run gave 25) before a
# human noticed. So the floor stops being prose the reader has to trust: the
# README states it as the literal phrase "<N>-assert hermetic floor", and this
# arm compares every occurrence of that phrase against the assert total THIS
# run actually produced.
#
# It is not counted as an assert of its own (no `ok`), so the floor it checks
# stays the number of BOARD asserts in the table and cannot chase its own tail.
# On disagreement it calls `bad`, which reds the run through the normal verdict
# — the local law and the advisory CI job both refuse a drifted README.
#
# Three ways it reds, all named:
#   - the phrase is absent or appears fewer than twice (someone deleted the
#     number instead of correcting it, which must not read as "no drift");
#   - two occurrences disagree with EACH OTHER (the heading says one thing and
#     THE LAW another);
#   - the stated floor disagrees with PASS+FAIL from this run.
# Hermetic only: the live matrix is server-shaped and has no fixed floor to pin.
if [ "$MODE" = hermetic ]; then
  DRIVE_README="$SCRIPT_DIR/README.md"
  TOTAL_ASSERTS=$((PASS + FAIL))
  if [ ! -f "$DRIVE_README" ]; then
    bad "README floor arm: $DRIVE_README is missing — the floor this run measured ($TOTAL_ASSERTS) is pinned by nothing"
  else
    # No `grep -q`, no early-exit pipe: capture whole, then match (pipefail).
    FLOOR_HITS=$(grep -oE '[0-9]+-assert hermetic floor' "$DRIVE_README" || true)
    FLOOR_N=$(printf '%s' "$FLOOR_HITS" | grep -c . || true)
    FLOOR_VALS=$(printf '%s\n' "$FLOOR_HITS" | sed 's/-assert hermetic floor//' | sort -u | tr '\n' ' ' | sed 's/ *$//')
    if [ "${FLOOR_N:-0}" -lt 2 ]; then
      bad "README floor arm: scripts/taskboard-drive/README.md carries ${FLOOR_N:-0} occurrence(s) of the literal '<N>-assert hermetic floor' (want at least 2 — THE LAW block and the floor section). This run measured $TOTAL_ASSERTS asserts. A deleted number is drift, not the absence of drift."
    elif [ "$(printf '%s' "$FLOOR_VALS" | tr ' ' '\n' | grep -c .)" -ne 1 ]; then
      bad "README floor arm: the README states MORE THAN ONE hermetic floor ($FLOOR_VALS) — its own occurrences disagree. This run measured $TOTAL_ASSERTS."
    elif [ "$FLOOR_VALS" != "$TOTAL_ASSERTS" ]; then
      bad "README floor arm: README says the hermetic floor is $FLOOR_VALS, this run measured $TOTAL_ASSERTS asserts ($PASS pass, $FAIL fail). Re-measure and correct scripts/taskboard-drive/README.md — both the '<N>-assert hermetic floor' phrases AND the per-assert table."
    else
      note "README floor arm: scripts/taskboard-drive/README.md states a $FLOOR_VALS-assert hermetic floor at $FLOOR_N places and this run measured $TOTAL_ASSERTS — agreed"
    fi
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
