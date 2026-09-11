#!/usr/bin/env bash
#
# principal-gate.sh — ONE writing-principal gate for the shell harnesses that
# POST real side effects on an ambient credential.
#
# WHY IT EXISTS (task-226f1718bb56d489 + task-b512e2d54791f042, 2026-09-11,
# filed out of PR #17717's "FILED, not fixed here" section). Three harnesses —
# scripts/media-smoke.sh, scripts/pdf-efficiency-proof.sh and
# scripts/pdf-kill-listener-proof.sh — issued their FIRST POST before making
# any judgement at all about WHO the credential was or WHICH box it pointed at.
# The first judgement each made was the write's own HTTP status, by which time
# the write had landed. media-smoke.sh's default target was literally the prod
# box (BARKPARK_BASE default http://89.167.28.206), so a stale-but-valid
# BARKPARK_TOKEN in an operator's shell wrote prod media.
#
# The remedy is the one PR #17717 put on scripts/cmux-smoke.sh, factored out so
# there is ONE implementation to mutate and ONE table to keep honest:
#
#   * pg_writer_tier  — is this auth_tier allowed to WRITE? Fails CLOSED.
#   * pg_url_host     — the PARSED hostname of a URL. Never a substring match:
#                       `case $u in *guerrilla*)` accepts
#                       https://guerrilla.evil.example and rejects a legitimate
#                       port spelling. urlparse().hostname or nothing.
#   * pg_capabilities_tier — the auth_tier off GET <base>/v1/capabilities with
#                       the bearer the writes will use (the stance of
#                       scripts/demo-living-values.sh's `"auth_tier":"admin"`
#                       check, and of pds-live-bp-write-receipt.sh's preflight).
#                       A read-only or anonymous caller is refused on the
#                       receipt's SHAPE, never on its rc.
#
# The caller supplies the refusal verbs, because each harness owns its own exit
# code table:
#
#   pg_refuse()     print "REFUSED: <reason>" on stderr, exit non-zero
#   pg_cannot_read() print "CANNOT READ: <reason>" on stderr, exit non-zero
#
# Source it AFTER lib/bp-curl.sh (pg_capabilities_tier rides bp_curl_body, so a
# harness stubbing `curl` sees the probe in its argv log).
#
# bash 3.2 compatible (macOS system bash).

# pg_writer_tier TIER — 0 when this tier may write, 1 otherwise. Anything that
# is not a resolved writing principal fails CLOSED: "", "none", "read",
# "viewer", "anonymous" and every unknown future value land in the catch-all.
# Same table as scripts/cmux-smoke.sh:writer_tier and
# scripts/pds-live-bp-write-receipt.sh:writer_tier.
pg_writer_tier() {  # MUT: tier-predicate
  case "$1" in
    admin|editor|write|writer|operator) return 0 ;;
    *) return 1 ;;
  esac
}

# pg_url_host URL -> the hostname, '' when the URL has none.
pg_url_host() {
  printf '%s' "$1" | python3 -c '
import sys
from urllib.parse import urlparse
u = sys.stdin.read().strip()
print(urlparse(u).hostname or "")
' 2>/dev/null || true
}

# pg_host_matches DECLARED URL — 0 when URL parses to exactly DECLARED.
pg_host_matches() {  # MUT: host-compare
  local declared="$1" got
  got="$(pg_url_host "$2")"
  [ -n "$got" ] && [ "$got" = "$declared" ]
}

# pg_capabilities_tier BASE TOKEN -> the auth_tier string on stdout; rc 1 when
# the receipt could not be taken or parsed (the caller turns that into its own
# CANNOT READ, which is a different verdict from "the tier is wrong").
pg_capabilities_tier() {
  local base="$1" token="$2" tmp rc=0 out
  tmp="$(mktemp "${TMPDIR:-/tmp}/pg-cap.XXXXXX")" || return 1
  # No `printf ... | python3` boolean here: under `set -o pipefail` a consumer
  # that exits early turns the producer's SIGPIPE (141) into the pipeline's
  # verdict, which is how a gate lies under load. The body goes to a FILE and
  # python3 reads the file, so the rc that decides is python3's own.
  bp_curl_body -sS --max-time 20 "$base/v1/capabilities" \
    -H "Authorization: Bearer $token" >"$tmp" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return 1; fi
  out="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
t = d.get("auth_tier")
if t is None and isinstance(d.get("result"), dict):
    t = d["result"].get("auth_tier")
print(t or "")
' "$tmp" 2>/dev/null)" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s' "$out"
}
