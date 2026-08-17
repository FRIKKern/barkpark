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
# FLAKINESS: asserts are row-scoped precisely so live SSE churn cannot red
# them, but a board reorder landing inside a gesture's ~2s window can still
# shift a located row. A red run against a healthy board is re-runnable; a
# repeatable red is a finding.
#
# USAGE
#   bash scripts/taskboard-drive/drive.sh            # full run; exits 0 on all-pass
#   BP_DRIVE_BIN=/path/to/bp bash .../drive.sh       # skip the build step
#   BP_DRIVE_KEEP=1 bash .../drive.sh                # keep tmux server for inspection
set -u -o pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)
EVID="$SCRIPT_DIR/evidence"
REPORT="$EVID/report.md"
SOCK="tbdrive-$$"
WIDE=wide
NARROW=narrow
TMPD=$(mktemp -d)
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
# spinner frames -> ⠿, the conn-state flap -> CONN (known live-channel defect,
# filed ttw19-bl-conn-state-flap), elapsed stamps/now -> T. Full-frame evidence
# is stored through this; row-scoped asserts compare located rows exactly.
normalize() {
  perl -CSD -Mutf8 -pe '
    s/\e\[[0-9;]*m//g;
    s/[\x{280B}\x{2819}\x{2839}\x{2838}\x{283C}\x{2834}\x{2826}\x{2827}\x{2807}\x{280F}]/\x{283F}/g;
    s/\x{2717} offline|\x{25CF} live|\x{25D0} polling/CONN/g;
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
ML0=$(marker_line "$WIDE")
save_row "$WIDE" "$ML0" g1-wheel-before.txt
wheel "$WIDE" 65 10 12 3
ML1=$(marker_line "$WIDE")
save_row "$WIDE" "$ML1" g1-wheel-after.txt
wheel "$WIDE" 64 10 12 3
ML2=$(marker_line "$WIDE")
save_row "$WIDE" "$ML2" g1-wheel-return.txt
if [ "$ML1" != "$ML0" ]; then
  ok "G1 wheel down x3 moved ▎ selection: line $ML0 -> $ML1"
else
  bad "G1 wheel down x3 did not move the ▎ selection (line $ML0)"
fi
if [ "$ML2" = "$ML0" ]; then
  ok "G1 wheel up x3 returned ▎ selection to line $ML0"
else
  bad "G1 wheel up x3 did not return selection: line $ML2, want $ML0"
fi

# ── G2+G4: single click on a leaf = select + activate (descend, first click) ─
LL=$(leaf_line "$WIDE")
TITLE=$(snap "$WIDE" | sed -n "${LL}p" | perl -CSD -Mutf8 -pe \
  's/^ *[├└]─ *\S+ *//; s/\s+$//; s/^(.{0,12}).*$/$1/')
save_frame "$WIDE" g2-leaf-click-before.txt
A_BEFORE=$(arrow_col "$WIDE")
click "$WIDE" 8 "$LL"
save_frame "$WIDE" g2-leaf-click-after.txt
MLC=$(marker_line "$WIDE")
A_AFTER=$(arrow_col "$WIDE")
if [ "$MLC" = "$LL" ]; then
  ok "G2 click selected the clicked leaf row (▎ moved to line $LL) in ONE gesture"
else
  bad "G2 click did not move ▎ to clicked line $LL (marker at ${MLC:-none})"
fi
# descend proof: focus flips to reader (↔ shifts to the gutter's right cell)
# AND the reading pane heading now carries the clicked row's title.
if [ "${A_AFTER:-0}" = "$((A_BEFORE+1))" ]; then
  ok "G4 leaf descended on FIRST click: divider form flipped board->reader (↔ col $A_BEFORE -> $A_AFTER)"
else
  bad "G4 no reader-focus flip after leaf click (↔ col $A_BEFORE -> ${A_AFTER:-none})"
fi
RP1=$(line_tail "$WIDE" "$((HL+1))" "$((GUTL+2))")
RP2=$(line_tail "$WIDE" "$((HL+2))" "$((GUTL+2))")
if printf '%s\n%s\n' "$RP1" "$RP2" | grep -qF "$TITLE"; then
  ok "G4 reading pane heading (right of the gutter) shows the clicked task (\"$TITLE\")"
else
  bad "G4 reading pane heading does not show \"$TITLE\""
fi
TMX send-keys -t "$WIDE" Escape
sleep 0.5
if snap "$WIDE" | grep -q 'esc back'; then
  ok "esc after descend: board footer still present (ascended cleanly)"
else
  bad "esc after descend: board footer missing"
fi

# ── G3: clicking an epic root toggles its section fold state ─────────────────
# The activate reducer's true grammar (charter D51/D54): a section showing ALL
# children collapses to just the header; any other mode (the partial
# focus/header default included) expands to the FULL list. So from the usual
# partial baseline the sequence is: click1 -> full, click2 -> collapsed,
# click3 -> full; from a fully-expanded baseline click1 collapses directly.
# board_region: the board-pane side of rows RL..RL+8, normalized (churn-law).
board_region() {
  snap "$WIDE" | sed -n "$1,$2p" | normalize | perl -CSD -Mutf8 -ne \
    'print substr($_, 0, '"$((GUTL-1))"'), "\n"'
}
was_child() { printf '%s' "$1" | grep -q '^ *[├└]─'; }
RL=$(root_line "$WIDE")
REGION0=$(board_region "$RL" "$((RL+8))")
save_row "$WIDE" "$RL,$((RL+8))" g3-fold-before.txt
click "$WIDE" 8 "$RL"
S1=$(snap "$WIDE" | sed -n "$((RL+1))p")
REGION1=$(board_region "$RL" "$((RL+8))")
save_row "$WIDE" "$RL,$((RL+8))" g3-fold-click1.txt
if ! was_child "$S1"; then
  # baseline was fully expanded: click1 collapsed the section to its header
  ok "G3 click on the epic root COLLAPSED it (row $((RL+1)) lost its ├─ child)"
  click "$WIDE" 8 "$RL"
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
  click "$WIDE" 8 "$RL"
  S2=$(snap "$WIDE" | sed -n "$((RL+1))p")
  save_row "$WIDE" "$RL,$((RL+8))" g3-fold-click2.txt
  if ! was_child "$S2"; then
    ok "G3 second click COLLAPSED the root to its header (row $((RL+1)) lost its ├─ child)"
  else
    bad "G3 second root click did not collapse (row $((RL+1)): '$S2')"
  fi
  click "$WIDE" 8 "$RL"
  S3=$(snap "$WIDE" | sed -n "$((RL+1))p")
  save_row "$WIDE" "$RL,$((RL+8))" g3-fold-click3.txt
  if was_child "$S3"; then
    ok "G3 third click EXPANDED the section again (├─ child back on row $((RL+1)))"
  else
    bad "G3 third root click did not expand (row $((RL+1)): '$S3')"
  fi
fi

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
sgr "$WIDE" "M"; sleep 0.4
LL=$(leaf_line "$WIDE")
MB=$(marker_line "$WIDE")
save_row "$WIDE" "$LL" g8-m-off-target-row.txt
click "$WIDE" 8 "$LL"
MA=$(marker_line "$WIDE")
if [ "$MA" = "$MB" ]; then
  ok "G8 with mouse released (M), a click is ignored (▎ stayed on line $MB)"
else
  bad "G8 mouse-off click still moved ▎ ($MB -> $MA)"
fi
sgr "$WIDE" "M"; sleep 0.4
click "$WIDE" 8 "$LL"
MA2=$(marker_line "$WIDE")
save_row "$WIDE" "$LL" g8-m-on-landed-row.txt
if [ "$MA2" = "$LL" ]; then
  ok "G8 after M re-enable, the same click lands (▎ moved to line $LL)"
else
  bad "G8 re-enabled click did not land (▎ at ${MA2:-none}, want $LL)"
fi

# ── narrow session: wheel, first-click descend, reading footer M note ────────
NL=$(leaf_line "$NARROW")
NM0=$(marker_line "$NARROW")
wheel "$NARROW" 65 10 8 2
NM1=$(marker_line "$NARROW")
wheel "$NARROW" 64 10 8 2
if [ "$NM1" != "$NM0" ]; then
  ok "narrow wheel moved ▎ selection ($NM0 -> $NM1)"
else
  bad "narrow wheel did not move ▎ selection"
fi
save_frame "$NARROW" n-narrow-board.txt
if snap "$NARROW" | grep -q 'M mouse'; then
  bad "narrow BOARD footer already shows 'M mouse' (expected shed below 102-col inner)"
else
  ok "narrow board footer sheds the M note (shed-ladder design, <102-col inner)"
fi
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
