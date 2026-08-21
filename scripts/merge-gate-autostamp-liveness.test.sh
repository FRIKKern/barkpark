#!/usr/bin/env bash
# merge-gate-autostamp-liveness.test.sh — BOTH ARMS of the liveness check.
#
# A check that has only ever been observed RED is not a check, it is an opinion.
# This drives the detector over hermetic fixtures (no gh, no bp, no network) and
# proves it distinguishes the four states it claims to: a dead path REDS, a live
# path GREENS, an empty corpus REFUSES to green, and a delivery the handler would
# have refused anyway is not counted against the path.
#
# The BROKEN fixture is not invented: it is the real merged payload of PR #12210
# and the real stored shape of task-lifecycle-visibility-wave-6-log. The LIVE
# fixture is that same pair with the one field the bridge writes — nothing else
# differs — so a green here means the oracle, not the fixture, moved.
#
#   scripts/merge-gate-autostamp-liveness.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/merge-gate-autostamp-liveness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

# A mergedAt inside any sane --days window.
NOW="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

# ── fixture builder ──────────────────────────────────────────────────────────
# mk <dir> <body> <with_gate:0|1> <with_bridge_write:0|1>
mk() {
  local dir="$1" body="$2" gate="$3" bridge="$4"
  mkdir -p "$dir/tasks"
  BODY="$body" NOW="$NOW" python3 - "$dir/prs.json" <<'PY'
import json, os, sys
json.dump([{
    "number": 12210,
    "mergedAt": os.environ["NOW"],
    "body": os.environ["BODY"],
    "mergeCommit": {"oid": "209cd542e83b09e11fcd970a4d712f49d4f531f8"},
}], open(sys.argv[1], "w"))
PY
  GATE="$gate" BRIDGE="$bridge" python3 - "$dir/tasks/task-lifecycle-visibility-wave-6-log.json" <<'PY'
import json, os, sys
crit = {
    "criterion": "PR merged to main (LEAD closes this criterion on merge)",
    "met": True,
    "evidence": "hand-stamped by the lead",
}
if os.environ["GATE"] == "1":
    crit["merge_gate"] = True
content = {"kind": "task", "acceptance_criteria": [crit]}
if os.environ["BRIDGE"] == "1":
    # The single field Tasks.Close.reconcile_merge_gate/3 writes. Nothing else
    # differs from the BROKEN fixture.
    content["merge_gate_autostamp"] = {"merge_event": {
        "verified": True, "source": "github_merge_event",
        "indices": [0], "asserted_worker": "github-merge",
        "landed": "PR #12210 (commit 209cd542e83b09e11fcd970a4d712f49d4f531f8)",
    }}
json.dump({"doc": {"content": content}}, open(sys.argv[1], "w"))
PY
}

run() { "$CHECK" --fixture "$1" --days 30 >"$TMP/out" 2>"$TMP/err"; echo $?; }

TRAILER_BODY="Wave-6 reconciliation.

Task: task-lifecycle-visibility-wave-6-log"

echo "merge-gate autostamp liveness — detector proofs"

# ── ARM 1: the path is dead → BROKEN (exit 1) ────────────────────────────────
mk "$TMP/broken" "$TRAILER_BODY" 1 0
rc="$(run "$TMP/broken")"
if [ "$rc" = "1" ]; then ok "1.1 a merge-gated merge with no bridge write REDS (exit 1)"
else bad "1.1 expected exit 1, got $rc"; cat "$TMP/out"; fi
if grep -F "PR #12210" "$TMP/out" >/dev/null 2>&1; then
  ok "1.2 ...and NAMES the merge that went unstamped"
else bad "1.2 the failure did not name PR #12210"; fi

# ── ARM 2: the path works → LIVE (exit 0) ────────────────────────────────────
# Same PR, same task, same criterion. ONLY the bridge's own provenance field is
# added. If this greens, the detector is reading the oracle and not the weather.
mk "$TMP/live" "$TRAILER_BODY" 1 1
rc="$(run "$TMP/live")"
if [ "$rc" = "0" ]; then ok "2.1 the SAME corpus plus the bridge write GREENS (exit 0)"
else bad "2.1 expected exit 0, got $rc"; cat "$TMP/out"; cat "$TMP/err"; fi

# ── ARM 3: an empty corpus must NOT green ────────────────────────────────────
mk "$TMP/nogate" "$TRAILER_BODY" 0 0
rc="$(run "$TMP/nogate")"
if [ "$rc" = "2" ]; then ok "3.1 a window with no merge-gated merge is INCONCLUSIVE (exit 2), never a pass"
else bad "3.1 expected exit 2, got $rc"; cat "$TMP/out"; fi

# ── ARM 4: trailer grammar parity with the handler ───────────────────────────
# Two distinct trailers is `:ambiguous_trailer` — the handler REFUSES it by
# design, so it must not be scored as a broken path.
mk "$TMP/ambig" "Task: task-lifecycle-visibility-wave-6-log
Task: some-other-task" 1 0
rc="$(run "$TMP/ambig")"
if [ "$rc" = "2" ]; then ok "4.1 an ambiguous-trailer merge is not counted against the path (exit 2)"
else bad "4.1 expected exit 2, got $rc"; cat "$TMP/out"; fi

# ── ARM 5: the oracle is the SOURCE, not the presence of the key ─────────────
# A record whose source is anything else (e.g. the close-time autostamp) must
# not satisfy the check — that is the forgery the whole finding turns on.
mk "$TMP/forged" "$TRAILER_BODY" 1 1
python3 - "$TMP/forged/tasks/task-lifecycle-visibility-wave-6-log.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["doc"]["content"]["merge_gate_autostamp"]["merge_event"]["source"] = "lead_close"
json.dump(d, open(p, "w"))
PY
rc="$(run "$TMP/forged")"
if [ "$rc" = "1" ]; then ok "5.1 a merge_event record NOT sourced github_merge_event still REDS"
else bad "5.1 expected exit 1, got $rc"; cat "$TMP/out"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
