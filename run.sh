#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

API_DIR="$(cd "$(dirname "$0")/api" 2>/dev/null && pwd || echo "")"
API_URL="${SANITY_API_URL:-http://localhost:4000}"

# Check if Phoenix is running
if ! curl -s "$API_URL/api/schemas" > /dev/null 2>&1; then
  if [ -n "$API_DIR" ]; then
    echo "Starting Phoenix API..."
    (cd "$API_DIR" && mix phx.server &) 2>/dev/null
    # Wait for it to be ready
    for i in $(seq 1 15); do
      if curl -s "$API_URL/api/schemas" > /dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  else
    echo "Error: Phoenix API not running and ./api not found."
    echo "Start it manually: cd api && mix phx.server"
    exit 1
  fi
fi

if ! command -v go &>/dev/null; then
  echo "Go not found. Installing via Homebrew..."
  if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew is required. Install it from https://brew.sh" >&2
    exit 1
  fi
  brew install go
fi

go mod tidy
go run .
