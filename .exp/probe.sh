#!/usr/bin/env bash
set -u
echo "=== LIVE: the SHIPPED script under the workflow's own GITHUB_TOKEN ==="
t0=$(date +%s)
bash scripts/stale-verdict-watch.sh --repo FRIKKern/barkpark; rc=$?
t1=$(date +%s)
echo "=== script rc=$rc wall=$((t1-t0))s ==="
