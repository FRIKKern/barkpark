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
#   curl http://localhost:4000/api/schemas
#   This is the legacy Go-TUI schemas endpoint and requires no auth — it is
#   public on the legacy path, returns JSON when the service is alive. If
#   `/api/schemas` is ever retired, switch the probe to `/studio` (HTML 200).
#   Do NOT swap to `/v1/schemas/production` — that path requires an admin
#   token and would couple the health check to credential management.
#
# Tested target: Ubuntu 22.04 ARM64 (Hetzner cax11). Bash 5.x. systemd 249+.

set -euo pipefail

if ! systemctl is-active --quiet barkpark; then
  echo "barkpark not active — starting"
  systemctl start barkpark
fi

sleep 2

if ! curl -fsS http://localhost:4000/api/schemas > /dev/null; then
  echo "FAIL: /api/schemas returned non-200 or unreachable" >&2
  systemctl status barkpark --no-pager | tail -20 >&2
  exit 1
fi

echo "PASS prod healthy ($(date -u +%FT%TZ))"
