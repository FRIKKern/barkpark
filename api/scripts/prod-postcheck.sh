#!/bin/bash
# prod-postcheck.sh — health verification after any systemctl operation on barkpark.
#
# Usage:
#   ./api/scripts/prod-postcheck.sh
#
#   # From a workstation:
#   ssh root@<prod-host> "cd /opt/barkpark && ./api/scripts/prod-postcheck.sh"
#
# Exit codes:
#   0  — service active and HTTP probe returned 2xx
#   1  — HTTP probe failed (or curl unavailable / network error); diagnostic
#        `systemctl status` tail is written to stderr before exit
#   non-zero — any other shell error (set -e); typically a missing systemctl
#              or curl on the host
#
# Behaviour:
#   - If `barkpark.service` is not active, the script starts it (`systemctl
#     start`) before probing. This is intentional: the script is a *recovery*
#     guardrail for workflows that may have left the service stopped without
#     a paired restart, not a passive monitor. Operators who want a stopped
#     service to stay stopped should NOT run this script.
#   - Sleeps 2 s after the (possible) start to let the BEAM bind :4000 before
#     the HTTP probe. Adjust if Phoenix boot ever exceeds 2 s on the target
#     host.
#
# Health endpoint:
#   curl http://localhost:4000/api/schemas  (via scripts/lib/bp-curl.sh)
#   This is the legacy Go-TUI schemas endpoint and requires no auth — it is
#   public on the legacy path, returns JSON when the service is alive. If
#   `/api/schemas` is ever retired, switch the probe to `/studio` (HTML 200).
#   Do NOT swap to `/v1/schemas/production` — that path requires an admin
#   token and would couple the health check to credential management.
#
# Tested target: Ubuntu 22.04 ARM64 (Hetzner cax11). Bash 5.x. systemd 249+.

set -euo pipefail

# The HTTP probe below rides scripts/lib/bp-curl.sh so a 429 from the API is a
# bounded, Retry-After-honouring retry instead of a FAIL verdict. The old
# `curl -fsS` was class C-f: `-f` collapsed every status — 429 included — into
# exit 22 before any branch could see it, so backpressure read as "prod is down"
# and printed a systemctl tail at an operator.
#
# This script runs ON THE PROD BOX from the /opt/barkpark checkout, so the helper
# is sourced RELATIVE TO THIS FILE, not relative to $PWD or a repo root guess.
BP_CURL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/bp-curl.sh"
if [ ! -f "$BP_CURL_LIB" ]; then
  echo "FAIL: $BP_CURL_LIB is missing — this checkout cannot run the 429-aware probe." >&2
  echo "      Refusing to fall back to a bare curl: that is the defect this script was fixed for." >&2
  exit 1
fi
# shellcheck source=../../scripts/lib/bp-curl.sh disable=SC1091
. "$BP_CURL_LIB"

if ! systemctl is-active --quiet barkpark; then
  echo "barkpark not active — starting"
  systemctl start barkpark
fi

sleep 2

# bp_curl_body is the `-sf` drop-in: 2xx -> body + 0; any other status -> empty
# stdout, the status named on stderr, exit 22 (curl -f's own code). A 429 is
# backed off and retried inside the helper first, and its narration goes to
# STDERR — never merged into this branch's verdict.
if ! bp_curl_body -sS -o /dev/null http://localhost:4000/api/schemas > /dev/null; then
  echo "FAIL: /api/schemas returned non-200 or unreachable" >&2
  systemctl status barkpark --no-pager | tail -20 >&2
  exit 1
fi

echo "PASS prod healthy ($(date -u +%FT%TZ))"
