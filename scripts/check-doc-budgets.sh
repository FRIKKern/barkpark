#!/usr/bin/env bash
# check-doc-budgets.sh — CI byte-gates for the doc spine (strategy §5 + A6).
#
# Every cap below is BINDING. On overflow the remedy is documented in the
# failure message: split to the owning contract/runbook or retire content —
# never raise the cap.
#
# bash 3.2 compatible (stock macOS): no associative arrays, no mapfile.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0
REMEDY="split to the owning contract/runbook or retire content — never raise the cap"

check_cap() {
  # $1 = path, $2 = byte cap
  local path="$1" cap="$2" size
  if [ ! -f "$path" ]; then
    echo "FAIL: $path is missing (budget-gated file must exist)"
    FAIL=1
    return
  fi
  size=$(wc -c < "$path" | tr -d ' ')
  if [ "$size" -gt "$cap" ]; then
    echo "FAIL: $path is ${size}B, cap is ${cap}B — $REMEDY"
    FAIL=1
  else
    echo "ok:   $path ${size}B <= ${cap}B"
  fi
}

# --- fixed caps (path<space>bytes) -----------------------------------------
while read -r path cap; do
  [ -z "$path" ] && continue
  check_cap "$path" "$cap"
done <<'CAPS'
CLAUDE.md 10000
api/CLAUDE.md 6500
js/CLAUDE.md 2500
AGENTS.md 700
docs/INDEX.md 1200
docs/contracts/bokbasen.md 6000
docs/contracts/onix-field-map.md 5600
docs/contracts/webhook-realtime.md 3200
docs/contracts/schema-v2.md 7200
docs/contracts/portable-doc-inline.md 6800
docs/contracts/tenancy.md 8300
README.md 7400
docs/ops/PROD_OPS.md 6000

docs/api-v1.md 14000

docs/auth.md 5600
docs/auth-user-sessions.md 16000
docs/setup/QUICKSTART.md 6000
docs/setup/TASK-SYSTEM.md 16000
docs/cheatsheets/bp.md 2400
docs/cheatsheets/tui.md 2400
docs/cheatsheets/tasks.md 2400
docs/cheatsheets/http-api.md 2400
docs/cheatsheets/papers.md 2400
CAPS

# --- cards: each <= 2400 B, count must equal exactly 7 (G2, A6) -------------
CARD_COUNT=0
for card in docs/cards/*.md; do
  [ -e "$card" ] || continue
  CARD_COUNT=$((CARD_COUNT + 1))
  check_cap "$card" 2400
done

if [ "$CARD_COUNT" -ne 7 ]; then
  echo "FAIL: docs/cards/ holds $CARD_COUNT cards, hard cap is exactly 7 (G2)." \
       "A new card requires retiring or merging one — $REMEDY"
  FAIL=1
else
  echo "ok:   card count is exactly 7"
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "check-doc-budgets: FAILED — $REMEDY"
  exit 1
fi
echo "check-doc-budgets: PASS"
