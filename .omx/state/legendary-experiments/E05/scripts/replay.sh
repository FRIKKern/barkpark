#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/build_fixture_manifest.py
python3 scripts/build_candidate.py
python3 scripts/test_adapter.py
python3 scripts/verify.py
echo "E05 REPLAY PASS"
