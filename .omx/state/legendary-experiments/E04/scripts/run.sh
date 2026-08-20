#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 scripts/build_candidate.py
python3 scripts/verify.py
python3 scripts/build_report.py
