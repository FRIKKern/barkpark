#!/usr/bin/env bash
# Hot-reload for TUI apps: rebuild + restart on file change.
# Press q in the TUI to quit, it restarts with latest code.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building..."
go build -o ./tmp/sanity-tui . 2>&1
if [ $? -ne 0 ]; then
  echo "Build failed. Waiting for changes..."
fi

mkdir -p tmp

while true; do
  go build -o ./tmp/sanity-tui . 2>&1
  if [ $? -eq 0 ]; then
    echo "Starting sanity-tui (press q to restart with latest changes)..."
    ./tmp/sanity-tui || true
  else
    echo ""
    echo "Build failed. Press Enter to retry..."
    read -r
  fi
done
