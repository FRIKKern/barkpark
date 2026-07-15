#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/attack.py
python3 scripts/verify.py
python3 -m compileall -q scripts
echo "E08 REPLAY PASS"
