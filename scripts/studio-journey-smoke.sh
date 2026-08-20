#!/usr/bin/env bash
# studio-journey-smoke.sh — the one entry point for the Studio create-type-save
# browser journey (studio space-priority desk, wave 18).
#
# WHAT THIS IS FOR. The owner's report was "the buttons look inert and I cannot
# add things." Wave 17 fixed three real defects on that seam; the confirmation
# that the fix WORKS was then driven by hand and written down as English. This
# epic has six logged overturns of exactly that shape. So the confirmation is an
# instrument, and this script is how it is invoked — by a human on a laptop and
# by the scheduled CI lane, with no divergence between the two.
#
#   scripts/studio-journey-smoke.sh self-test     # offline, no network, no creds
#   scripts/studio-journey-smoke.sh live          # DEPLOYED guerrilla, verdict
#   scripts/studio-journey-smoke.sh report        # DEPLOYED, never exits 1
#
# EXIT CODES, passed straight through from the harness (nothing here swallows
# one — a wrapper that `|| true`s an instrument is how a red becomes invisible):
#   0  the journey is whole (or report mode, which never fails on content)
#   1  a LEG A beat FAILED — a fact about the PRODUCT
#   2  GUARD — the ENVIRONMENT or the invocation: no Chrome, no Node 22, no
#      credentials, a ticket that would not mint, or a deploy that landed
#      mid-run. Never a claim about the Studio.
#
# CREDENTIALS. `live` and `report` need an admin token for the target host. It
# comes from ~/.config/barkpark/config.json (the `guerrilla` entry, i.e. what
# `bp login` wrote) or, where there is no such file, from JOURNEY_BASE +
# JOURNEY_TOKEN together. `self-test` needs neither and reaches no network.
#
# THIS IS NOT A MERGE GATE and cannot be made one — see the header of
# .github/workflows/studio-journey-smoke.yml for why.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$HERE/tooling/studio-journey/journey.mjs"
MODE="${1:-self-test}"
shift || true

if [ ! -f "$HARNESS" ]; then
  echo "!! GUARD (exit 2): harness not found at $HARNESS" >&2
  exit 2
fi

# Node 22 or refuse. The harness speaks CDP over a bare global WebSocket, and on
# an older build it exits 2 on its own — this check just says so earlier and with
# the version in the message.
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "!! GUARD (exit 2): node 22+ required for a native global WebSocket (found $(node -v 2>/dev/null || echo 'no node'))" >&2
  exit 2
fi

case "$MODE" in
  self-test)
    # Syntax first: a typo in a 1,400-line harness should cost a millisecond,
    # not a Chrome launch.
    node --check "$HARNESS"
    exec node "$HARNESS" --self-test "$@"
    ;;
  live)
    exec node "$HARNESS" "$@"
    ;;
  report)
    exec node "$HARNESS" --report "$@"
    ;;
  -h|--help|help)
    sed -n '2,32p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "!! GUARD (exit 2): unknown mode '$MODE' (want self-test | live | report)" >&2
    exit 2
    ;;
esac
