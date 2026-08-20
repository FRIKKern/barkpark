#!/usr/bin/env bash
# ONE-COMMAND D11 measurement run: all four axes + parse + verdict.
# Prereq: the spike app is installed on the attached device
#   (cd tooling/webview-spike && npm install && npx expo run:android --variant release)
# Release build strongly preferred — debug JS + dev-mode WebView skew every axis.
# Usage: scripts/run-all.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_device
echo "== device =="
device_info

echo "== axis 1: cold-load inline (10 runs) =="
bash "$SPIKE_DIR/scripts/run-cold-load.sh" inline 10
echo "== axis 4: cold-load file/baseUrl (10 runs) =="
bash "$SPIKE_DIR/scripts/run-cold-load.sh" file 10
echo "== axis 2: scroll (inline) =="
bash "$SPIKE_DIR/scripts/run-scroll.sh" inline
echo "== axis 3: memory (warm WebViews) =="
bash "$SPIKE_DIR/scripts/run-memory.sh"

echo "== parse + verdict =="
node "$SPIKE_DIR/scripts/parse-results.mjs"
echo
echo "RESULTS: $RESULTS/RESULTS.md"
