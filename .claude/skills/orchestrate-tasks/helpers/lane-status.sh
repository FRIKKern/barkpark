#!/usr/bin/env bash
# lane-status.sh [--once|--watch]  — read every lead's status.md under $ORCH.
# --once prints the table; --watch emits one line per changed file (for Monitor).
# bash 3.2-safe (macOS): no associative arrays; signatures live in a temp dir.
set -u
ORCH="${ORCH:?export ORCH=<scratchpad>/orchestrate}"
mode="${1:---once}"
if [ "$mode" = "--once" ]; then
  for f in "$ORCH"/lead-*/status.md; do [ -f "$f" ] || continue; echo "=== $(basename "$(dirname "$f")")"; cat "$f"; echo; done
  exit 0
fi
SIG="$ORCH/.lane-status-sigs"; mkdir -p "$SIG"
while true; do
  for f in "$ORCH"/lead-*/status.md; do
    [ -f "$f" ] || continue
    lane=$(basename "$(dirname "$f")")
    sig=$(stat -f '%m %z' "$f" 2>/dev/null || stat -c '%Y %s' "$f")
    prev=$(cat "$SIG/$lane" 2>/dev/null || true)
    if [ "$prev" != "$sig" ]; then
      printf '%s' "$sig" > "$SIG/$lane"
      head -2 "$f" | tr '\n' ' '; echo
      grep -E '^(REQUEST|BLOCKED-ON-USER):' "$f" | sed "s/^/$lane /"
      echo "$lane: $(grep -cE '\| (merged|closed) ' "$f" || true) merged/closed, $(grep -cE '\| (building|pr-open) ' "$f" || true) in flight"
    fi
  done
  sleep 20
done
