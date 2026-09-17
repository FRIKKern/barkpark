#!/bin/bash
# dispatch.sh <orders.json> — the LIVE dispatch glue: cap gate → roster → transform → route → file.
#
# One batch, every decision printed with its reason:
#   1. CAP GATE first, before anything else: re-read the spend ledger SET ON EVERY
#      INVOCATION through tooling/fleet/spend-aggregate.py — every
#      ${FLEET_HOME:-$HOME/.barkpark-fleet}/<worker>/spend.jsonl that record_spend actually
#      writes, plus the orchestrator's own orchestrator/spend.jsonl when it exists. Never
#      cached (the cap proof's R6 control zeroes a ledger mid-run and expects the freeze to
#      lift on the next batch). A malformed row is a NAMED ABORT, never coerced (PDF-D37),
#      and NO readable ledger is CANNOT READ (exit 13) — never a compliant $0.00, because a
#      ledger you cannot read is a brake you cannot trust (PDF-D105).
#   2. Fetch the live roster (`bp fleet roster -o json`) and print every excluded-offline row
#      BY NAME before routing — route.py cannot distinguish no-such-box from
#      sole-box-offline (PDF-D38), so the exclusions must be visible at the edge.
#   3. Pipe roster → transform.py → route.py --route (route.py stays pure and byte-untouched).
#   4. Per assignment: print `order → worker (klass): <reason>` and file it via file-order.sh.
#      Per unplaceable: print `order UNPLACEABLE: <reason>`.
#   5. Cap tripped: ONE loud freeze line, every order printed spend_cap, file-order.sh is
#      NEVER invoked. Frozen is a reported state, not a silent empty round.
#
# Orders JSON: [{id, klass, fence?, title?, brief?, criterion?}, ...] (or {"orders": [...]}).
# Env: FLEET_SPEND_CAP        hard cap in $ (unset = no cap gate; the per-listener budget
#                             inside route.py still applies — the second brake)
#      FLEET_HOME             fleet root (default ~/.barkpark-fleet)
#      FLEET_ROSTER_JSON      read the roster from this file instead of `bp fleet roster`
#                             (stub rosters for proofs/tests — no live server needed)
#      FLEET_FILE_ORDER_BIN   override the filing helper (stubbed in proofs)
#      FLEET_SPEND_AGGREGATE_BIN  path to tooling/fleet/spend-aggregate.py (default: resolved
#                             relative to this skill's checkout / the enclosing git toplevel)
# Exits: 10 no orders file · 12 malformed ledger row · 13 no readable ledger (CANNOT READ,
#        with a cap set) · 14 the aggregator failed for another reason.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDERS_FILE="${1:?usage: dispatch.sh <orders.json>}"
FLEET_HOME="${FLEET_HOME:-$HOME/.barkpark-fleet}"
FILE_ORDER="${FLEET_FILE_ORDER_BIN:-$SCRIPT_DIR/file-order.sh}"

[ -f "$ORDERS_FILE" ] || { echo "ABORT: orders file not found: $ORDERS_FILE"; exit 10; }

# ---- 1. cap gate — RE-READ the ledger set every invocation via the AGGREGATING READER ----
# SPENT comes from tooling/fleet/spend-aggregate.py, which sums every ledger that
# actually HAS a producer ($FLEET_HOME/<worker>/spend.jsonl, written by record_spend
# in tooling/fleet/fleet-run.sh) plus the orchestrator's own
# $FLEET_HOME/orchestrator/spend.jsonl when it exists. The old inline reader here read
# ONLY the orchestrator path, which nothing ever writes — so it summed a missing file
# to $0.00 and printed "dispatch allowed" forever: a brake with no input (PDF-D105).
# THREE exit codes, three DISTINCT verdicts — never collapsed:
#   0  a real total (a present-but-empty ledger is a real, readable 0.0000)
#  12  MALFORMED row — the named abort, never coerced to 0 (brake off) or inf (brake stuck)
#  13  NO readable ledger — CANNOT READ. With a cap set this REFUSES the batch; it must
#      never fall through to "dispatch allowed", because an unreadable brake input is not
#      evidence of $0.00 spent (same shape as the unreadable-hold-label defect, PR #18893).
SPEND_AGGREGATE="${FLEET_SPEND_AGGREGATE_BIN:-}"
if [ -z "$SPEND_AGGREGATE" ]; then
  REPO_ROOT_GUESS="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  for cand in "$SCRIPT_DIR/../../../../tooling/fleet/spend-aggregate.py" \
              ${REPO_ROOT_GUESS:+"$REPO_ROOT_GUESS/tooling/fleet/spend-aggregate.py"}; do
    if [ -f "$cand" ]; then SPEND_AGGREGATE="$cand"; break; fi
  done
fi

SPENT=""
SPEND_STATE="ok"
SPEND_ERR="$(mktemp "${TMPDIR:-/tmp}/fleet-spend-err.XXXXXX")"
trap 'rm -f "$SPEND_ERR"' EXIT

if [ -z "$SPEND_AGGREGATE" ] || [ ! -f "$SPEND_AGGREGATE" ]; then
  # The reader itself is missing: that is CANNOT READ too, not a zero.
  echo "ABORT: CANNOT_READ_SPEND — tooling/fleet/spend-aggregate.py not found (set FLEET_SPEND_AGGREGATE_BIN); a spend total that cannot be computed is NOT \$0.00 spent" >&2
  SPEND_STATE="cannot_read"
else
  set +e
  SPENT="$(python3 "$SPEND_AGGREGATE" --fleet-home "$FLEET_HOME" --total 2>"$SPEND_ERR")"
  AGG_RC=$?
  set -e
  case "$AGG_RC" in
    0)  : ;;
    12) cat "$SPEND_ERR" >&2
        echo "ABORT: MALFORMED_SPEND_LEDGER under $FLEET_HOME (orchestrator/spend.jsonl and/or a per-worker spend.jsonl, cost_usd dialect) — refusing to coerce a brake input (PDF-D37)"
        exit 12 ;;
    13) cat "$SPEND_ERR" >&2
        SPEND_STATE="cannot_read" ;;
    *)  cat "$SPEND_ERR" >&2
        echo "ABORT: SPEND_AGGREGATE_FAILED rc=$AGG_RC — the cap gate has no trustworthy total; refusing"
        exit 14 ;;
  esac
fi

CAP_REACHED=0
CAP_FLAG=()
if [ -n "${FLEET_SPEND_CAP:-}" ]; then
  if [ "$SPEND_STATE" = "cannot_read" ]; then
    echo "cap gate: CANNOT READ the spend ledger set under $FLEET_HOME — dispatch REFUSED, 0 orders placed (an unreadable ledger is NOT \$0.00 spent; PDF-D37/D105)"
    exit 13
  fi
  CAP_REACHED=$(python3 -c "import sys; print(1 if float(sys.argv[1]) >= float(sys.argv[2]) else 0)" "$SPENT" "$FLEET_SPEND_CAP")
  if [ "$CAP_REACHED" = "1" ]; then
    CAP_FLAG=(--cap-reached)
  else
    echo "cap gate: spent \$$SPENT of cap \$$FLEET_SPEND_CAP — dispatch allowed"
  fi
else
  echo "cap gate: no FLEET_SPEND_CAP set — batch cap gate off (route.py per-listener budgets still apply)"
  if [ "$SPEND_STATE" = "cannot_read" ]; then
    echo "cap gate: note — NO readable spend ledger under $FLEET_HOME, so NO total was computed (CANNOT READ, not \$0.00)"
  fi
fi

# ---- 2. the live roster; excluded-offline rows printed BY NAME before routing ----
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fleet-dispatch.XXXXXX")
trap 'rm -rf "$WORKDIR"; rm -f "$SPEND_ERR"' EXIT
ROSTER_FILE="$WORKDIR/roster.json"
if [ -n "${FLEET_ROSTER_JSON:-}" ]; then
  cat "$FLEET_ROSTER_JSON" > "$ROSTER_FILE"
else
  bp fleet roster -o json > "$ROSTER_FILE"
fi

python3 - "$SCRIPT_DIR" "$ROSTER_FILE" <<'PY'
import json, sys, time
sys.path.insert(0, sys.argv[1])
from transform import transform_row  # the SAME decode the router will see
with open(sys.argv[2]) as f:
    doc = json.load(f)
rows = doc.get("documents", doc) if isinstance(doc, dict) else doc
now = time.time()
for row in rows:
    t = transform_row(row)
    status = t.get("status")
    if status == "offline":  # PDF-D20: the server's verdict is authoritative
        print(f"{t.get('worker')} excluded: offline/stale (server status=offline)")
    elif status is None:  # rows lacking a computed status: local fallback math, fail-closed
        last_seen, ttl = t.get("last_seen"), t.get("ttl_s", 120)
        if last_seen is None or (now - last_seen) > ttl:
            print(f"{t.get('worker')} excluded: offline/stale (no server status; heartbeat stale past ttl)")
PY

# ---- 3. roster → transform → route (route.py pure, byte-untouched) ----
N_ORDERS=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('orders', d) if isinstance(d, dict) else d))" "$ORDERS_FILE")
RESULT_FILE="$WORKDIR/result.json"
cat "$ROSTER_FILE" \
  | python3 "$SCRIPT_DIR/transform.py" --orders "$ORDERS_FILE" ${CAP_FLAG[@]+"${CAP_FLAG[@]}"} \
  | python3 "$SCRIPT_DIR/route.py" --route > "$RESULT_FILE"

# ---- 4/5. print every decision with its reason; file assignments (unless frozen) ----
if [ "$CAP_REACHED" = "1" ]; then
  echo "SPEND CAP REACHED (\$$SPENT >= \$$FLEET_SPEND_CAP) — dispatch halted, 0/$N_ORDERS orders placed"
  python3 -c 'import json, sys
r = json.load(open(sys.argv[1]))
for u in r["unplaceable"]:
    print("  {} {}".format(u["order"], u["reason"]))' "$RESULT_FILE"
  exit 0  # frozen is a reported state, not an error — and file-order.sh was never invoked
fi

PLAN="$WORKDIR/plan.jsonl"

python3 - "$RESULT_FILE" "$ORDERS_FILE" "$PLAN" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
orders_doc = json.load(open(sys.argv[2]))
orders = orders_doc.get("orders", orders_doc) if isinstance(orders_doc, dict) else orders_doc
by_id = {o["id"]: o for o in orders}
with open(sys.argv[3], "w") as plan:
    for a in result["assignments"]:
        o = by_id.get(a["order"], {})
        klass = a.get("klass", o.get("klass", "standard"))
        reason = f"best-fit: cheapest sufficient online box for {klass}"
        print(f"{a['order']} → {a['worker']} ({klass}): {reason}")
        plan.write(json.dumps({
            "id": a["order"],
            "title": o.get("title", a["order"]),
            "worker": a["worker"],
            "klass": klass,
            "brief": o.get("brief", f"Fleet order {a['order']} ({klass})."),
            "criterion": o.get("criterion", "Order executed and its artifact verified."),
        }) + "\n")
    for u in result["unplaceable"]:
        print(f"{u['order']} UNPLACEABLE: {u['reason']}")
PY

while IFS= read -r line; do
  eval "$(printf '%s' "$line" | python3 -c '
import json, shlex, sys
o = json.loads(sys.stdin.read())
for var, key in (("OID","id"),("OTITLE","title"),("OWHO","worker"),("OBRIEF","brief"),("OCRIT","criterion")):
    print(f"{var}={shlex.quote(str(o[key]))}")')"
  "$FILE_ORDER" "$OID" "$OTITLE" "$OWHO" "$OBRIEF" "$OCRIT"
done < "$PLAN"
