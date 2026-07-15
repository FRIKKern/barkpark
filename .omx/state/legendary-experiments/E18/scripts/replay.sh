#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -m py_compile "$ROOT"/scripts/*.py

# Execute both inherited replay gates twice; each gate internally performs its
# own clean deterministic rebuild comparison and validates every frozen hash.
for _ in 1 2; do
  "$ROOT/../E16/scripts/replay.sh"
  "$ROOT/../E17/scripts/replay.sh"
done

python3 "$ROOT/scripts/build.py" --stage seal
python3 "$ROOT/scripts/build.py" --stage score
python3 "$ROOT/scripts/verify.py"
