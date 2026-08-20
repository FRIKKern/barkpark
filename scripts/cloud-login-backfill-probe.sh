#!/usr/bin/env bash
#
# cloud-login-backfill-probe.sh — read-only, unauthenticated fleet inventory for
# the "Log in with Barkpark Cloud" backfill (Onboarding composition wave 5,
# onb-backlog-cloud-url-fleet-backfill).
#
# WHY THIS EXISTS
# ---------------
# caddy.go's setEnvVarStep now stamps BARKPARK_CLOUD_URL=https://barkpark.cloud
# on every NEW go-live provision, and deploy.go/deploy.sh thread + persist it on
# every `bp setup deploy` from this wave forward. Neither reaches a box that was
# provisioned BEFORE those landed: those instances have BARKPARK_CLOUD_URL unset,
# so :cloud_login_url is nil and /login renders NO Cloud button. gyldendal is the
# live example — zero `data-cloud-login` buttons today.
#
# This script does NOT fix anything. It is the READ-ONLY half: it probes each
# host over plain unauthenticated HTTPS and inventories which boxes need the
# backfill, which are already correct, which could not be reached, and which are
# excluded. The write half (ssh BARKPARK_CLOUD_URL=… bash -s < deploy.sh per
# host) stays a HUMAN GATE — a human runs it with the inventory in hand.
#
# TWO DEFECTS, KEPT SEPARATE
# --------------------------
# A host can fail TWO independent checks, and they have DIFFERENT remedies:
#
#   1. MISSING BUTTON  (GET /login has no `data-cloud-login`)
#        cause : BARKPARK_CLOUD_URL unset in .env
#        remedy: THIS backfill — thread the constant + restart. Idempotent.
#
#   2. IDENTITY LEAK   (GET /v1/capabilities server.base_url != https://<host>)
#        cause : PHX_HOST leaking http://localhost:4000 (gyldendal shows this)
#        remedy: a FULL REDEPLOY that sets PHX_HOST=<fqdn> — NOT this backfill.
#
# The button backfill inventory (changed/already-correct/failed/excluded) is the
# primary verdict. The identity check rides as a SEPARATE per-host column so the
# two are never conflated: a host can get the button and still leak localhost.
#
# EXIT: 0 always when the sweep completes (an unreachable host is a `failed` row,
# never an abort). Non-zero only on a usage error.
#
# USAGE:
#   scripts/cloud-login-backfill-probe.sh [host ...]
#     hosts default to the known managed fleet; pass bare hostnames to override.
#   BACKFILL_EXCLUDE="a.example b.example" scripts/cloud-login-backfill-probe.sh
#     comma/space-separated hosts to mark `excluded` (never probed).
#   PROBE_TIMEOUT=8  per-request curl timeout seconds (default 8).

set -u

# ── Fleet + exclusions ───────────────────────────────────────────────────────
DEFAULT_HOSTS="guerrilla.barkpark.cloud gyldendal.barkpark.cloud"
if [ "$#" -gt 0 ]; then
  HOSTS="$*"
else
  HOSTS="$DEFAULT_HOSTS"
fi

# Normalise the exclusion list to space-separated for a simple membership test.
EXCLUDE_RAW="${BACKFILL_EXCLUDE:-}"
EXCLUDE="$(printf '%s' "$EXCLUDE_RAW" | tr ',' ' ')"

TIMEOUT="${PROBE_TIMEOUT:-8}"

is_excluded() {
  local h="$1" e
  for e in $EXCLUDE; do
    [ "$e" = "$h" ] && return 0
  done
  return 1
}

# ── Tallies ──────────────────────────────────────────────────────────────────
n_changed=0        # button ABSENT but host reachable — backfill WOULD change it
n_correct=0        # button already present
n_failed=0         # unreachable / unexpected status (HTTP 000 lands here)
n_excluded=0       # skipped by request
n_leak=0           # SEPARATE: base_url != own host (PHX_HOST redeploy, not this)

printf '%s\n' "cloud-login-backfill-probe — read-only fleet inventory"
printf '%s\n' "  control-plane origin expected in the button: https://barkpark.cloud"
printf '%s\n\n' "  per-request timeout: ${TIMEOUT}s"

printf '%-34s  %-14s  %-22s  %s\n' "HOST" "BUTTON" "IDENTITY (base_url)" "VERDICT"
printf '%-34s  %-14s  %-22s  %s\n' "----" "------" "-------------------" "-------"

# fetch_status URL → echoes the HTTP status code (000 on connect failure).
# curl's -w '%{http_code}' already prints 000 when the connection never
# completes, so we take its stdout verbatim and only substitute 000 if curl
# emitted nothing at all (never double it — "000000" would dodge the ==000 arm).
fetch_status() {
  local code
  code="$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "$1" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

# fetch_body URL → echoes the response body (empty on connect failure).
fetch_body() {
  curl -s -m "$TIMEOUT" "$1" 2>/dev/null || printf ''
}

# extract_base_url JSON → echoes the server.base_url value, or "" if absent.
# Prefers jq; falls back to a grep/sed that reads the first "base_url" string.
extract_base_url() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r '.server.base_url // ""' 2>/dev/null
    return
  fi
  printf '%s' "$json" \
    | grep -o '"base_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/'
}

for host in $HOSTS; do
  if is_excluded "$host"; then
    n_excluded=$((n_excluded + 1))
    printf '%-34s  %-14s  %-22s  %s\n' "$host" "-" "-" "excluded"
    continue
  fi

  own_origin="https://$host"
  cap_url="$own_origin/v1/capabilities"
  login_url="$own_origin/login"

  cap_status="$(fetch_status "$cap_url")"
  login_status="$(fetch_status "$login_url")"

  # Unreachable on EITHER probe → failed, and the sweep keeps going.
  if [ "$cap_status" = "000" ] || [ "$login_status" = "000" ]; then
    n_failed=$((n_failed + 1))
    printf '%-34s  %-14s  %-22s  %s\n' \
      "$host" "?" "?" "failed (unreachable: cap=$cap_status login=$login_status)"
    continue
  fi
  if [ "$cap_status" != "200" ] || [ "$login_status" != "200" ]; then
    n_failed=$((n_failed + 1))
    printf '%-34s  %-14s  %-22s  %s\n' \
      "$host" "?" "?" "failed (status: cap=$cap_status login=$login_status)"
    continue
  fi

  # BUTTON check — GET /login must carry a data-cloud-login attribute.
  login_body="$(fetch_body "$login_url")"
  if printf '%s' "$login_body" | grep -q 'data-cloud-login'; then
    button="present"
  else
    button="ABSENT"
  fi

  # IDENTITY check (SEPARATE defect) — capabilities server.base_url must equal
  # this instance's own https origin; a localhost value is the PHX_HOST leak.
  cap_body="$(fetch_body "$cap_url")"
  base_url="$(extract_base_url "$cap_body")"
  if [ "$base_url" = "$own_origin" ]; then
    identity="ok"
    id_note=""
  else
    identity="LEAK"
    id_note=" [identity-leak: redeploy w/ PHX_HOST, NOT this backfill]"
    n_leak=$((n_leak + 1))
  fi

  # PRIMARY verdict is the button backfill state only.
  if [ "$button" = "present" ]; then
    n_correct=$((n_correct + 1))
    verdict="already-correct${id_note}"
  else
    n_changed=$((n_changed + 1))
    verdict="changed (needs backfill)${id_note}"
  fi

  # Show the base_url we saw (or <none>) so the identity column is auditable.
  shown_base="${base_url:-<none>}"
  printf '%-34s  %-14s  %-22s  %s\n' "$host" "$button" "$shown_base" "$verdict"
done

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n%s\n' "── inventory ─────────────────────────────────────────────"
printf '  changed (needs backfill) : %d\n' "$n_changed"
printf '  already-correct          : %d\n' "$n_correct"
printf '  failed (unreachable/err) : %d\n' "$n_failed"
printf '  excluded                 : %d\n' "$n_excluded"
printf '\n%s\n' "── SEPARATE defect (NOT this backfill) ───────────────────"
printf '  identity-leak base_url   : %d   → full redeploy with PHX_HOST\n' "$n_leak"
printf '\n%s\n' "This probe is read-only. The write half — ssh BARKPARK_CLOUD_URL=… bash -s"
printf '%s\n' "< deploy.sh per changed host, then a redeploy for any identity-leak host —"
printf '%s\n' "is a HUMAN GATE. Run it with this inventory in hand."

exit 0
