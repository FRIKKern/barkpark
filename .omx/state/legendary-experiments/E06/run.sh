#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
python3 "$ROOT/scripts/build_fixtures.py"
python3 "$ROOT/scripts/dispatch.py"
python3 "$ROOT/scripts/verify.py"
