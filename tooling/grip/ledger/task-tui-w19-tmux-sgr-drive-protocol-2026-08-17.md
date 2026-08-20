# Task-TUI W19 — tmux SGR drive protocol, proven end-to-end (2026-08-17)

Verifier: tmux-drive-spike. The greenfield live-drive harness mechanics, each re-derivable.

## Build (the assignment's literal command is WRONG — repo root has no Go files)

    CC=/usr/bin/clang go build -o "$SCRATCH/bp" ./cmd/barkpark

## Launch (tmux 3.4, host window-size=latest)

    tmux new-session -d -x 130 -y 40 -s bpdrive "$SCRATCH/bp tasks"   # wide
    tmux new-session -d -x 70  -y 24 -s bpnarrow "$SCRATCH/bp tasks"  # narrow
    tmux display -p -t bpdrive '#{window_width}x#{window_height}'     # → 130x40

`-x/-y` alone is sufficient detached (no client attached, "latest" falls back to
creation size); `set -g window-size manual` NOT needed.

## Wire bytes (SGR 1006, 1-based coords; ev.X = col-1, cx = col-2, cy = row-2)

Both delivery forms land identically; `-l` passes a lone ESC cleanly on tmux 3.4:

    tmux send-keys -t bpdrive -l $'\033[<65;10;9M'                       # wheel down
    tmux send-keys -t bpdrive -H 1b 5b 3c 36 35 3b 31 30 3b 39 4d        # same, hex
    tmux send-keys -t bpdrive -l $'\033[<0;10;10M'; tmux send-keys -t bpdrive -l $'\033[<0;10;10m'  # click press+release
    tmux send-keys -t bpdrive -l $'\033[<35;10;6M'                       # hover motion (DELIVERS under WithMouseAllMotion)
    # divider drag: press 0 on gutter col, motion 32, release 0-m
    tmux send-keys -t bpdrive -l $'\033[<0;70;10M'; tmux send-keys -t bpdrive -l $'\033[<32;60;10M'; tmux send-keys -t bpdrive -l $'\033[<0;60;10m'

Capture: `sleep 0.3; tmux capture-pane -t bpdrive -e -p -J`. Stable at rest
(byte-identical 300ms apart) but NOT across time: spinner glyphs (⠋⠙…), elapsed
stamps (43m, 2m↔), and live SSE updates churn frames — normalize spinners +
elapsed + strip SGR before diffing, or diff single target rows.

## Ground truth found (wide 130x40, ratio 0.4444 → boardW=68)

- Gutter = EXACTLY 2 cols (wire cols boardW+2 .. boardW+3); hover lights gutter │
  dim 81;81;91 → neutral 161;161;170 + the ↔ affordance on compose row 0 (wire
  row 2, end of header); drag paints ↔↔ bold accent 63;207;142.
- Click grammar is SINGLE-click activate (boardClickActivate = cursor move +
  Enter reducer): epic root toggles fold/unfold, leaf descends into reading
  frame on the FIRST click. "click-again-descend" is a stale premise.
- Shift-click bytes (Cb=4), if they reach the app, act as a plain click
  (bubbletea drops no modifier); real terminals swallow shift-click natively.
- M toggle proven functionally (off → clicks ignored; on → clicks land) but the
  footer etiquette note sheds below 102-col inner width — invisible at default
  board-pane widths; narrow READING footer does show "M mouse" at 70 cols.
- DetailsPaneRatio persists: drag release rewrote
  ~/.config/barkpark/taskboard-preferences.json 0.6054→0.4444; kill + relaunch
  repainted divider at the dragged column. (Original value restored after.)
- Conn header flapped ✗ offline ↔ ● live across sessions while `bp task ready`
  succeeded throughout — live-channel state, not API reachability.
