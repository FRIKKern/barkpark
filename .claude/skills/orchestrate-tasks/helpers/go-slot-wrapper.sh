#!/usr/bin/env bash
# barkpark orchestrate-tasks compile throttle (installed 2026-09-02 by the orchestrator; remove this file to disable).
# Wraps the real go for test/compile so at most $BP_GO_SLOTS (3) heavy runs share this Mac. BP_NO_SLOT=1 bypasses.
REAL=/opt/homebrew/bin/go
case " $* " in *" test"*|*" build"*|*" vet"*) ;; *) exec "$REAL" "$@";; esac
[ -n "${BP_NO_SLOT:-}" ] && exec "$REAL" "$@"
SLOTS="${BP_GO_SLOTS:-3}"; DIR="$HOME/.cache/barkpark-slots/go"; mkdir -p "$DIR"; waited=0
while :; do
  for i in $(seq 1 "$SLOTS"); do
    if mkdir "$DIR/$i" 2>/dev/null; then
      echo $$ > "$DIR/$i/pid"; SLOT="$DIR/$i"
      trap 'rm -rf "$SLOT"' INT TERM
      "$REAL" "$@"; rc=$?; rm -rf "$SLOT"; exit $rc
    fi
    if [ -f "$DIR/$i/pid" ] && ! kill -0 "$(cat "$DIR/$i/pid" 2>/dev/null)" 2>/dev/null; then rm -rf "$DIR/$i"; fi
  done
  [ $waited -eq 0 ] && echo "go: waiting for a compile slot ($SLOTS machine-wide; BP_NO_SLOT=1 bypasses)" >&2; waited=1
  sleep 5
done
