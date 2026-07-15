#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/scripts/test_candidate.py"
python3 "$ROOT/scripts/verify.py"
echo "E16 REPLAY PASS"

