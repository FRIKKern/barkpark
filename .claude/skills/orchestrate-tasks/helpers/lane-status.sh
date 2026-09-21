#!/usr/bin/env bash
# lane-status.sh [--once|--watch]  — read every lead's status file under $ORCH.
#
# PER-SESSION STATUS FILES (task-50d7d1a599dd14dd). A lane dir now holds ONE
# status file PER SESSION — status.<session>.md — because two concurrent
# sessions of one lane sharing status.md destroyed three sections of it on
# 2026-09-07 (149 lines -> 94). The glob below therefore matches BOTH shapes:
# status.md (legacy / single-session lanes) and status.*.md. The watch key is
# the lane dir PLUS the file name, so two sessions of one lane are two rows
# here rather than one row that flaps between them.
# --once prints the table; --watch emits one line per changed file (for Monitor).
# bash 3.2-safe (macOS): no associative arrays; signatures live in a temp dir.
set -u
ORCH="${ORCH:?export ORCH=<scratchpad>/orchestrate}"
mode="${1:---once}"
if [ "$mode" = "--once" ]; then
  for f in "$ORCH"/lead-*/status.md "$ORCH"/lead-*/status.*.md; do [ -f "$f" ] || continue; echo "=== $(basename "$(dirname "$f")")/$(basename "$f")"; cat "$f"; echo; done
  exit 0
fi
SIG="$ORCH/.lane-status-sigs"; mkdir -p "$SIG"
while true; do
  for f in "$ORCH"/lead-*/status.md "$ORCH"/lead-*/status.*.md; do
    [ -f "$f" ] || continue
    [ -L "$(dirname "$f")" ] && continue   # skip symlinked resume aliases (lead-<lane>-r -> lead-<lane>)
    # lane+session, so two sessions of one lane are two independent watch keys.
    lane="$(basename "$(dirname "$f")")/$(basename "$f" .md)"
    # GNU FIRST, BSD second — never the reverse. On GNU coreutils `-f` means
    # FILESYSTEM status, so `stat -f %s` SUCCEEDS on Linux with a
    # block-count report instead of failing, and a BSD-first `||` chain
    # never reaches the GNU form. BSD stat rejects `-c` outright, so
    # GNU-first fails loudly on the wrong platform instead of quietly.
    sig=$(stat -c '%Y %s' "$f" 2>/dev/null || stat -f '%m %z' "$f")
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
