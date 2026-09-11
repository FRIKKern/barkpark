#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

API_DIR="$(cd "$(dirname "$0")/api" 2>/dev/null && pwd || echo "")"
API_URL="${SANITY_API_URL:-http://localhost:4000}"

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib/bp-curl.sh"   # 429 backoff, shared (task-90059c5c680f6665)

# api_answers: 0 when the API answers AT ALL — any status, a 429 included.
# That is exactly what the bare `curl -s` this replaced measured (no -f), and
# the distinction matters: a rate-limited Phoenix is RUNNING, so starting a
# second `mix phx.server` on top of it would be the wrong remedy. bp_curl_code
# prints nothing and returns curl's rc on a transport failure, so `|| echo 000`
# is what turns "nobody is listening" into a value this test can read.
api_answers() {
  [ "$(bp_curl_code -s -o /dev/null "$API_URL/api/schemas" 2>/dev/null || echo 000)" != "000" ]
}

# Check if Phoenix is running
if ! api_answers; then
  if [ -n "$API_DIR" ]; then
    echo "Starting Phoenix API..."
    (cd "$API_DIR" && mix phx.server &) 2>/dev/null
    # Wait for it to be ready
    for i in $(seq 1 15); do
      if api_answers; then
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
go run ./cmd/barkpark
