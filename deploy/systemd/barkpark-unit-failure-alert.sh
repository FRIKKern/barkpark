#!/usr/bin/env bash
# barkpark-unit-failure-alert — what barkpark-unit-failure-alert@.service runs.
# Installed to /usr/local/bin/barkpark-unit-failure-alert.
#
# Usage: barkpark-unit-failure-alert <failed-unit-name>
#
# ── WHAT CHANNEL THIS USES, AND WHY IT IS NOT THE CI ONE ─────────────────────
# The row that asked for this cited .github/workflows/renew-mail-cert.yml as the
# pattern. That step runs scripts/file-ci-failure-issue.sh on a hosted runner
# with the built-in GITHUB_TOKEN, and files a GitHub issue. It is the right
# POLICY and the wrong MECHANISM: neither box that runs these timers has a
# GITHUB_TOKEN, and neither is reachable from a workflow — being off-CI is the
# whole reason these jobs fail invisibly.
#
# MEASURED, on origin/main, before choosing: there is no notification channel on
# either box that a unit could already reach.
#   * The control host (barkpark-image-bake) loads /etc/barkpark-provisioner.env
#     — HCLOUD_TOKEN, S3 keys, bundle KEK, SMTP_RELAY_* (a relay CREDENTIAL for
#     the app's outbound mail, with no MTA or mail(1) on the box to use it).
#     No GitHub credential of any kind.
#   * The prod app box (barkpark-rotate-public-token) loads /opt/barkpark/.env,
#     which carries no SMTP and no GitHub credential at all.
#   * They are DIFFERENT HOSTS. Anything keyed on the control host's env would
#     be dead on the rotation box, which is where the weekly-token failure lands.
# So the honest answer is: nothing existed. This is the smallest real channel.
#
# ── THE TWO THINGS THIS DOES, IN THIS ORDER ──────────────────────────────────
# 1. RECORD, always, with no dependency on anything being configured:
#      * a journald record at priority `err` under a stable syslog identifier
#        (`barkpark-alert`), so `journalctl -t barkpark-alert -p err` is the
#        one query that finds every firing on either box; and
#      * a durable stamp file under /var/lib/barkpark/failed-units/, because
#        journald rotates and a weekly job's failure has to still be visible
#        the following week.
# 2. DELIVER, when BARKPARK_ALERT_WEBHOOK is set in /etc/barkpark/alert.env:
#      POST a small JSON body to it. One URL, one secret, no new package.
#
# NEVER A SILENT NO-OP. If the webhook is unset, or the POST fails, that is
# recorded at `err` too, naming the fact that the alert was NOT delivered.
# A notifier that quietly does nothing manufactures confidence — the same rule
# scripts/file-ci-failure-issue.sh states in its own header, carried across.
#
# NEVER FAILS THE PARENT. It exits 0 even when delivery fails: the handler's own
# non-zero exit would add a second failed unit and tell nobody anything the
# journald record above does not already say.
set -uo pipefail

UNIT="${1:-unknown.unit}"
TAG=barkpark-alert
STATE_DIR="${BARKPARK_ALERT_STATE_DIR:-/var/lib/barkpark/failed-units}"
HOST="$(uname -n 2>/dev/null || echo unknown-host)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { # log <priority> <message> — journald if available, stderr otherwise
  if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n' "$2" | systemd-cat -t "$TAG" -p "$1"
  else
    printf '[%s][%s] %s\n' "$TAG" "$1" "$2" >&2
  fi
}

# Last 20 journal lines of the failing unit, when journalctl exists. Context is
# what makes the alert actionable; its absence must not stop the alert.
CTX="$(journalctl -u "$UNIT" -n 20 --no-pager 2>/dev/null || echo '(journalctl unavailable)')"
RESULT="$(systemctl show "$UNIT" -p Result --value 2>/dev/null || echo unknown)"

log err "UNIT FAILED: $UNIT on $HOST at $NOW (Result=$RESULT). A scheduled Barkpark job did not complete. Check: journalctl -u $UNIT -n 50"

# The durable stamp. Best-effort: a read-only or full /var must not swallow the
# journald record above.
if mkdir -p "$STATE_DIR" 2>/dev/null; then
  printf 'unit=%s\nhost=%s\nat=%s\nresult=%s\n\n%s\n' \
    "$UNIT" "$HOST" "$NOW" "$RESULT" "$CTX" >"$STATE_DIR/$UNIT" 2>/dev/null \
    || log warning "could not write the failure stamp $STATE_DIR/$UNIT — the journald record above is the only trace"
else
  log warning "could not create $STATE_DIR — the journald record above is the only trace"
fi

WEBHOOK="${BARKPARK_ALERT_WEBHOOK:-}"
if [ -z "$WEBHOOK" ]; then
  log err "ALERT NOT DELIVERED: $UNIT failed and BARKPARK_ALERT_WEBHOOK is unset in /etc/barkpark/alert.env, so no human was notified. The failure is recorded locally ONLY. Set the webhook, or this box's scheduled jobs fail where nobody is watching."
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  log err "ALERT NOT DELIVERED: $UNIT failed and curl is not installed, so the configured webhook could not be reached."
  exit 0
fi

BODY="$(printf '{"text":"Barkpark scheduled unit FAILED: %s on %s at %s (Result=%s). Run: journalctl -u %s -n 50"}' \
  "$UNIT" "$HOST" "$NOW" "$RESULT" "$UNIT")"

if curl -fsS --max-time 20 -X POST -H 'Content-Type: application/json' \
     -d "$BODY" "$WEBHOOK" >/dev/null 2>&1; then
  log info "alert for $UNIT delivered to BARKPARK_ALERT_WEBHOOK"
else
  log err "ALERT NOT DELIVERED: $UNIT failed and the POST to BARKPARK_ALERT_WEBHOOK did not succeed. The failure is recorded locally ONLY."
fi
exit 0
