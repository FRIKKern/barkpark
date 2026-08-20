#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../../../"
python3 .omx/state/legendary-experiments/E11/scripts/verify.py
