#!/usr/bin/env bash
set -euo pipefail

TUI_DIR="$(cd "$(dirname "$0")" && pwd)"
API_DIR="$(cd "$TUI_DIR/../sanity_api" 2>/dev/null && pwd || echo "")"
SESSION="sanity-dev"

# ── Prerequisites ────────────────────────────────────────────────────────────

if ! command -v air &>/dev/null; then
  echo "Installing air (Go hot reload)..."
  go install github.com/air-verse/air@latest
fi

if [ -n "$API_DIR" ] && [ ! -d "$API_DIR/_build" ]; then
  echo "Compiling Phoenix API for first run..."
  (cd "$API_DIR" && mix deps.get && mix compile)
fi

# ── Tmux session ─────────────────────────────────────────────────────────────

tmux kill-session -t "$SESSION" 2>/dev/null || true

# Create session
tmux new-session -d -s "$SESSION" -x "$(tput cols)" -y "$(tput lines)"

# Layout: [CC 10%] [TUI 45%] [Phoenix 45%]
# Split right for Phoenix
tmux split-window -h -t "$SESSION"
# Split left for CC
tmux split-window -h -t "$SESSION:0.0"

# Resize: pane 0 = CC (10%), pane 1 = TUI (45%), pane 2 = Phoenix (45%)
COLS=$(tmux display-message -p '#{window_width}')
CC_WIDTH=$(( COLS / 10 ))
if [ "$CC_WIDTH" -lt 30 ]; then
  CC_WIDTH=30
fi
TUI_WIDTH=$(( (COLS - CC_WIDTH) / 2 ))

tmux resize-pane -t "$SESSION:0.0" -x "$CC_WIDTH"
tmux resize-pane -t "$SESSION:0.1" -x "$TUI_WIDTH"

# Pane 0: Claude Code
tmux send-keys -t "$SESSION:0.0" "cd $TUI_DIR && claude" Enter

# Pane 1: Go TUI (press q to rebuild + restart with latest changes)
tmux send-keys -t "$SESSION:0.1" "cd $TUI_DIR && ./watch.sh" Enter

# Pane 2: Phoenix API with hot reload
if [ -n "$API_DIR" ]; then
  tmux send-keys -t "$SESSION:0.2" "cd $API_DIR && mix phx.server" Enter
else
  tmux send-keys -t "$SESSION:0.2" "echo 'Phoenix API not found at ../sanity_api'" Enter
fi

# Attach
tmux attach-session -t "$SESSION"
