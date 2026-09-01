#!/usr/bin/env bash
# lane-status.sh [--once|--watch]  — read every lead's status.md under $ORCH.
# --once prints the table; --watch emits one line per changed file (for Monitor).
set -u
ORCH="${ORCH:?export ORCH=<scratchpad>/orchestrate}"
mode="${1:---once}"
if [ "$mode" = "--once" ]; then
  for f in "$ORCH"/lead-*/status.md; do [ -f "$f" ] || continue; echo "=== $(basename "$(dirname "$f")")"; cat "$f"; echo; done
  exit 0
fi
declare -A seen
while true; do
  for f in "$ORCH"/lead-*/status.md; do
    [ -f "$f" ] || continue
    sig=$(stat -f '%m %z' "$f" 2>/dev/null || stat -c '%Y %s' "$f")
    if [ "${seen[$f]:-}" != "$sig" ]; then
      seen[$f]="$sig"
      lane=$(basename "$(dirname "$f")")
      head -2 "$f" | tr '\n' ' '; echo
      grep -E '^(REQUEST|BLOCKED-ON-USER):' "$f" | sed "s/^/$lane /"
      echo "$lane: $(grep -cE '\| (merged|closed) ' "$f") merged/closed, $(grep -cE '\| (building|pr-open) ' "$f") in flight"
    fi
  done
  sleep 20
done
