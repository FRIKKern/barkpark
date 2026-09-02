#!/usr/bin/env bash
# with-slot.sh <cmd...> — machine-wide semaphore for heavy gates (mix compile/test, go test).
# At most $SLOTS (default 3) run at once across every lead and worker; others wait.
# Runs the command as a CHILD (not exec) so the slot is released on exit; a dead holder is reaped.
set -u
SLOTS="${SLOTS:-3}"; DIR="${ORCH:-$(dirname "$0")}/.slots"; mkdir -p "$DIR"
while :; do
  for i in $(seq 1 "$SLOTS"); do
    if mkdir "$DIR/$i" 2>/dev/null; then
      echo $$ > "$DIR/$i/pid"; SLOT="$DIR/$i"
      trap 'rm -rf "$SLOT"' INT TERM
      "$@"; rc=$?; rm -rf "$SLOT"; exit $rc
    fi
    if [ -f "$DIR/$i/pid" ] && ! kill -0 "$(cat "$DIR/$i/pid" 2>/dev/null)" 2>/dev/null; then rm -rf "$DIR/$i"; fi
  done
  sleep 5
done
