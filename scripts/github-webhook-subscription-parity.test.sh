#!/usr/bin/env bash
# github-webhook-subscription-parity.test.sh — mutation proofs for the parity
# tripwire.
#
# The load-bearing arm is 1.1: the check is run against the repo tree AS IT
# STOOD ON origin/main BEFORE this fix — a real historical defect, not a
# synthetic one — and must red naming `pull_request`. A tripwire that has only
# ever been observed green is indistinguishable from `exit 0`.
#
# Hermetic: every arm operates on a mktemp copy of the tree. No network.
#
#   scripts/github-webhook-subscription-parity.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/github-webhook-subscription-parity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

# A minimal tree copy: the three files the check reads.
mktree() {
  local d="$1"
  mkdir -p "$d/api/lib/barkpark_web/controllers" "$d/scripts" "$d/docs/ops"
  cp "$ROOT/api/lib/barkpark_web/controllers/github_webhook_controller.ex" \
     "$d/api/lib/barkpark_web/controllers/"
  cp "$ROOT/scripts/github-app-bootstrap.py" "$d/scripts/"
  cp "$ROOT/docs/ops/github-sync.md" "$d/docs/ops/"
}

run() { "$CHECK" --root "$1" >"$TMP/out" 2>"$TMP/err"; echo $?; }

echo "github webhook subscription parity — mutation proofs"

# ── 1. THE HISTORICAL DEFECT ─────────────────────────────────────────────────
# Restore the manifest and runbook to their pre-fix wording (default_events was
# `["issues"]`; the runbook said Issues only) while leaving the controller — which
# has consumed `pull_request` since #5742 — untouched. That is the exact tree
# that shipped, and the check must lose on it.
mktree "$TMP/historical"
python3 - "$TMP/historical" <<'PY'
import re, sys
d = sys.argv[1]
p = d + "/scripts/github-app-bootstrap.py"
s = open(p).read()
s = re.sub(r'"default_events"\s*:\s*\[[^\]]*\]', '"default_events": ["issues"]', s)
open(p, "w").write(s)
p = d + "/docs/ops/github-sync.md"
s = open(p).read()
s = re.sub(r"\*\*Subscribe to events\*\*:.*", "**Subscribe to events**: **Issues** only.", s)
open(p, "w").write(s)
PY
rc="$(run "$TMP/historical")"
if [ "$rc" = "1" ]; then ok "1.1 the pre-#5742-fix tree REDS (exit 1)"
else bad "1.1 the historical defect did not red — expected exit 1, got $rc"; cat "$TMP/out"; fi
if grep -F 'pull_request' "$TMP/out" >/dev/null 2>&1; then
  ok "1.2 ...and NAMES pull_request as the unsubscribed consumer"
else bad "1.2 the failure did not name pull_request"; cat "$TMP/out"; fi

# ── 2. The repaired tree passes ──────────────────────────────────────────────
mktree "$TMP/fixed"
rc="$(run "$TMP/fixed")"
if [ "$rc" = "0" ]; then ok "2.1 the repaired tree PASSES (exit 0)"
else bad "2.1 expected exit 0, got $rc"; cat "$TMP/out"; cat "$TMP/err"; fi

# ── 3. A FUTURE consumer added without a subscription reds ───────────────────
# This is the recurrence the tripwire is for: the next handler someone adds.
mktree "$TMP/future"
python3 - "$TMP/future" <<'PY'
import sys
p = sys.argv[1] + "/api/lib/barkpark_web/controllers/github_webhook_controller.ex"
s = open(p).read()
s = s.replace('      "ping" -> json(conn, %{ok: true})',
              '      "release" -> handle_release(conn, params)\n      "ping" -> json(conn, %{ok: true})')
open(p, "w").write(s)
PY
rc="$(run "$TMP/future")"
if [ "$rc" = "1" ]; then ok "3.1 a NEW unsubscribed consumer (\`release\`) reds (exit 1)"
else bad "3.1 expected exit 1, got $rc"; cat "$TMP/out"; fi
if grep -F 'release' "$TMP/out" >/dev/null 2>&1; then
  ok "3.2 ...and names it"
else bad "3.2 the failure did not name release"; fi

# ── 4. `ping` is NOT a subscription claim ────────────────────────────────────
# GitHub sends the install handshake regardless of the event list. If the check
# demanded `ping` in default_events it would red forever on a correct tree —
# proving the exclusion is real, not an accident of the current text.
mktree "$TMP/ping"
if grep -F '"ping"' "$TMP/ping/api/lib/barkpark_web/controllers/github_webhook_controller.ex" >/dev/null 2>&1; then
  rc="$(run "$TMP/ping")"
  if [ "$rc" = "0" ]; then ok "4.1 a controller that handles \`ping\` still passes with ping unsubscribed"
  else bad "4.1 ping was treated as a subscription claim — exit $rc"; cat "$TMP/out"; fi
else
  bad "4.1 fixture invalid: the controller no longer handles ping"
fi

# ── 5. Runbook drift alone is enough to red ──────────────────────────────────
# The runbook is what a human provisioning by hand follows. A manifest/runbook
# split produces two differently-wired Apps, so it loses on its own.
mktree "$TMP/drift"
python3 - "$TMP/drift" <<'PY'
import re, sys
p = sys.argv[1] + "/docs/ops/github-sync.md"
s = open(p).read()
s = re.sub(r"\*\*Subscribe to events\*\*:.*", "**Subscribe to events**: **Issues** only.", s)
open(p, "w").write(s)
PY
rc="$(run "$TMP/drift")"
if [ "$rc" = "1" ]; then ok "5.1 runbook/manifest drift reds even when the code is subscribed (exit 1)"
else bad "5.1 expected exit 1, got $rc"; cat "$TMP/out"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
