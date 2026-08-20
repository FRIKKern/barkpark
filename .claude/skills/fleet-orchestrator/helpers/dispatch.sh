#!/bin/bash
# dispatch.sh <orders.json> — the LIVE dispatch glue: cap gate → roster → transform → route → file.
#
# One batch, every decision printed with its reason:
#   1. CAP GATE first, before anything else: re-read the orchestrator spend ledger
#      (${FLEET_HOME:-$HOME/.barkpark-fleet}/orchestrator/spend.jsonl) ON EVERY INVOCATION —
#      never cached (the cap proof's R6 control zeroes the file mid-run and expects the freeze
#      to lift on the next batch). A malformed ledger row is a NAMED ABORT, never coerced
#      (PDF-D37): a ledger you cannot read is a brake you cannot trust.
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
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDERS_FILE="${1:?usage: dispatch.sh <orders.json>}"
FLEET_HOME="${FLEET_HOME:-$HOME/.barkpark-fleet}"
LEDGER="$FLEET_HOME/orchestrator/spend.jsonl"
FILE_ORDER="${FLEET_FILE_ORDER_BIN:-$SCRIPT_DIR/file-order.sh}"

[ -f "$ORDERS_FILE" ] || { echo "ABORT: orders file not found: $ORDERS_FILE"; exit 10; }

# ---- 1. cap gate — RE-READ the ledger every invocation, malformed row = named abort ----
SPENT="0"
if [ -f "$LEDGER" ]; then
  SPENT=$(python3 - "$LEDGER" <<'PY'
import json, sys
total = 0.0
for n, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except ValueError:
        sys.stderr.write(f"ABORT: MALFORMED_SPEND_LEDGER_ROW line {n}: not JSON: {line[:100]}\n")
        sys.exit(12)
    # PDF-D37 ONE row format: {ts, order_id, agent, cost_usd|null, ...} — the SAME
    # key record_spend writes. cost_usd:null is a CANONICAL row (an honest
    # "couldn't price it"): skipped, matching the runner's measure_budget (fails
    # slightly open, documented). A MISSING key or non-numeric value is malformed.
    usd = row.get("cost_usd", "MISSING") if isinstance(row, dict) else "MISSING"
    if usd is None:
        continue
    if isinstance(usd, bool) or not isinstance(usd, (int, float)):
        sys.stderr.write(f"ABORT: MALFORMED_SPEND_LEDGER_ROW line {n}: missing/non-numeric 'cost_usd': {line[:100]}\n")
        sys.exit(12)
    total += usd
print(f"{total:.4f}")
PY
  ) || { echo "ABORT: MALFORMED_SPEND_LEDGER at $LEDGER — refusing to coerce a brake input (PDF-D37)"; exit 12; }
fi

CAP_REACHED=0
CAP_FLAG=()
if [ -n "${FLEET_SPEND_CAP:-}" ]; then
  CAP_REACHED=$(python3 -c "import sys; print(1 if float(sys.argv[1]) >= float(sys.argv[2]) else 0)" "$SPENT" "$FLEET_SPEND_CAP")
  if [ "$CAP_REACHED" = "1" ]; then
    CAP_FLAG=(--cap-reached)
  else
    echo "cap gate: spent \$$SPENT of cap \$$FLEET_SPEND_CAP — dispatch allowed"
  fi
else
  echo "cap gate: no FLEET_SPEND_CAP set — batch cap gate off (route.py per-listener budgets still apply)"
fi

# ---- 2. the live roster; excluded-offline rows printed BY NAME before routing ----
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fleet-dispatch.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT
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
