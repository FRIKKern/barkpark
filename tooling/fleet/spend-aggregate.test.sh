#!/bin/bash
# spend-aggregate.test.sh — arms for tooling/fleet/spend-aggregate.py.
#
# The task this guards (pdf-bl-orchestrator-spend-producer) is about a gate that
# reported protecting while protecting nothing, so these arms are built to the same
# standard the gate failed: every one of them must RED when the fix is reverted, and
# STAY QUIET when it should. Two of them are explicit CONTROLS that run the REVERTED
# reader against the same fixture and assert it gets the WRONG answer — present-in-file
# is not fires-when-it-should, so the discrimination is measured, not asserted.
#
#   bash tooling/fleet/spend-aggregate.test.sh
# No network, no server, no real fleet. Exits non-zero on the first failing arm's tally.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGG="$HERE/spend-aggregate.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/spend-agg.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$*"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$*"; }

row(){ # $1 order_id  $2 cost_usd literal (JSON)  $3 verdict
  printf '{"ts":"2026-09-17T00:00:00Z","order_id":"%s","agent":"claude","cost_usd":%s,"tokens":null,"source":"claude-cli-json","klass":"standard","verdict":"%s"}\n' "$1" "$2" "${3:-PASS}"
}

# A fleet home whose ONLY producer is record_spend's per-worker path — i.e. production.
mkhome(){ # $1 = name ; echoes the path
  local h="$TMP/$1"; mkdir -p "$h/muscle-1" "$h/muscle-2"
  { row o-1 0.25; row o-2 0.50; } > "$h/muscle-1/spend.jsonl"
  { row o-3 1.25; }              > "$h/muscle-2/spend.jsonl"
  echo "$h"
}

# THE REVERTED READER: dispatch.sh's pre-fix behaviour, verbatim in shape — one file,
# absent file sums to 0. Kept here so the controls measure the real difference.
reverted_total(){ # $1 = fleet home
  local L="$1/orchestrator/spend.jsonl"
  [ -f "$L" ] || { echo "0.0000"; return 0; }
  python3 -c '
import json,sys
t=0.0
for l in open(sys.argv[1]):
    l=l.strip()
    if l: t+=float(json.loads(l).get("cost_usd") or 0)
print("%.4f"%t)' "$L"
}

echo "spend-aggregate arms"

# ── 1. THE DEFECT ITSELF: per-worker ledgers, no orchestrator file ──────────────
H=$(mkhome prod)
T=$(python3 "$AGG" --fleet-home "$H" --total); RC=$?
[ "$RC" = 0 ] && [ "$T" = "2.0000" ] \
  && ok "1  per-worker ledgers with no orchestrator file total \$2.0000 (rc=0)" \
  || no "1  expected rc=0 total 2.0000, got rc=$RC total '$T'"

# ── 1c. CONTROL: the reverted reader gets 0.00 on that SAME fixture ─────────────
RT=$(reverted_total "$H")
[ "$RT" = "0.0000" ] \
  && ok "1c CONTROL the reverted single-file reader says \$$RT on \$2.00 of real spend — arm 1 reds on revert" \
  || no "1c CONTROL did not discriminate: reverted reader also said '$RT' (arm 1 proves nothing)"

# ── 2. QUIET ARM: the orchestrator-only shape (pdf-efficiency-proof) still works ─
H2="$TMP/proofshape"; mkdir -p "$H2/orchestrator"
{ row p-1 3.00; row p-2 4.00; } > "$H2/orchestrator/spend.jsonl"
T=$(python3 "$AGG" --fleet-home "$H2" --total); RC=$?
RT=$(reverted_total "$H2")
[ "$RC" = 0 ] && [ "$T" = "7.0000" ] && [ "$RT" = "7.0000" ] \
  && ok "2  QUIET orchestrator-only shape unchanged: aggregator \$$T == reverted reader \$$RT" \
  || no "2  orchestrator-only shape drifted: rc=$RC aggregator '$T' reverted '$RT'"

# ── 3. the union sums both, per distinct FILE, no row de-dup ────────────────────
H3=$(mkhome union); mkdir -p "$H3/orchestrator"; row u-1 0.75 > "$H3/orchestrator/spend.jsonl"
T=$(python3 "$AGG" --fleet-home "$H3" --total)
[ "$T" = "2.7500" ] && ok "3  union of per-worker + orchestrator = \$2.7500" \
                    || no "3  union expected 2.7500, got '$T'"

# ── 4. CANNOT READ is not a compliant zero ─────────────────────────────────────
H4="$TMP/empty-home"; mkdir -p "$H4"
OUT=$(python3 "$AGG" --fleet-home "$H4" --total 2>"$TMP/e4"); RC=$?
if [ "$RC" = 13 ] && [ -z "$OUT" ] && grep -q 'NO_SPEND_LEDGER' "$TMP/e4"; then
  ok "4  no ledger anywhere → rc=13 NO_SPEND_LEDGER, NO total printed (never \$0.00 'dispatch allowed')"
else
  no "4  expected rc=13 + empty stdout + NO_SPEND_LEDGER; got rc=$RC stdout='$OUT'"
fi
# ── 4c. CONTROL: the reverted reader renders that same state as a compliant zero ─
RT=$(reverted_total "$H4")
[ "$RT" = "0.0000" ] \
  && ok "4c CONTROL the reverted reader renders the unreadable ledger as \$$RT — the exact defect" \
  || no "4c CONTROL did not discriminate: reverted reader said '$RT'"

# ── 5. a present-but-empty ledger IS a real readable zero (distinct from arm 4) ──
H5="$TMP/realzero"; mkdir -p "$H5/muscle-1"; : > "$H5/muscle-1/spend.jsonl"
T=$(python3 "$AGG" --fleet-home "$H5" --total); RC=$?
[ "$RC" = 0 ] && [ "$T" = "0.0000" ] \
  && ok "5  a present, empty ledger is a READ zero (rc=0, \$0.0000) — not conflated with arm 4" \
  || no "5  expected rc=0 0.0000 for an empty ledger, got rc=$RC '$T'"

# ── 6-9. malformed rows abort loudly, print no total, coerce to neither 0 nor inf ─
i=6
for spec in "notjson:::not json at all" \
            "missing:::{\"ts\":\"t\",\"order_id\":\"x\",\"agent\":\"claude\"}" \
            "string:::{\"order_id\":\"x\",\"cost_usd\":\"1.00\"}" \
            "bool:::{\"order_id\":\"x\",\"cost_usd\":true}"; do
  name="${spec%%:::*}"; body="${spec#*:::}"
  HB="$TMP/bad-$name"; mkdir -p "$HB/muscle-1"
  { row good-1 1.00; printf '%s\n' "$body"; } > "$HB/muscle-1/spend.jsonl"
  OUT=$(python3 "$AGG" --fleet-home "$HB" --total 2>"$TMP/e$i"); RC=$?
  if [ "$RC" = 12 ] && [ -z "$OUT" ] && grep -q 'MALFORMED_SPEND_LEDGER_ROW' "$TMP/e$i" \
     && grep -q 'line 2' "$TMP/e$i"; then
    ok "$i  malformed ($name) → rc=12, names line 2, NO total on stdout (not 0, not inf)"
  else
    no "$i  malformed ($name): expected rc=12 + empty stdout + named line; got rc=$RC stdout='$OUT' stderr='$(cat "$TMP/e$i")'"
  fi
  i=$((i+1))
done

# ── 10. cost_usd:null is canonical, skipped, counted as unpriced ────────────────
H10="$TMP/nullrow"; mkdir -p "$H10/muscle-1"
{ row n-1 0.40; row n-2 null; } > "$H10/muscle-1/spend.jsonl"
J=$(python3 "$AGG" --fleet-home "$H10"); RC=$?
TU=$(printf '%s' "$J" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["total_usd"],d["unpriced_rows"],d["priced_rows"])')
[ "$RC" = 0 ] && [ "$TU" = "0.4 1 1" ] \
  && ok "10 cost_usd:null skipped as an honest 'couldn't price it' (total 0.4, unpriced 1, priced 1)" \
  || no "10 expected rc=0 '0.4 1 1', got rc=$RC '$TU'"

# ── 11. a MISS row still counts toward spend, and is reported separately ────────
H11="$TMP/missrow"; mkdir -p "$H11/muscle-1"
{ row m-1 0.10 PASS; row m-2 0.00 MISS; row m-3 0.20 MISS; } > "$H11/muscle-1/spend.jsonl"
MU=$(python3 "$AGG" --fleet-home "$H11" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["total_usd"],d["miss_rows"])')
[ "$MU" = "0.3 2" ] \
  && ok "11 MISS rows still sum (\$0.30) and are reported separately (miss_rows=2) — a \$0 failure is not a cheap win" \
  || no "11 expected '0.3 2', got '$MU'"

# ── 12. NEVER auto-reset: the aggregator has no write path, on success OR abort ──
H12=$(mkhome noreset); mkdir -p "$H12/orchestrator"; printf 'garbage\n' > "$H12/orchestrator/spend.jsonl"
BEFORE=$(find "$H12" -type f -exec shasum {} \; | sort)
python3 "$AGG" --fleet-home "$H12" --total >/dev/null 2>&1; RC=$?
python3 "$AGG" --fleet-home "$(mkhome noreset2)" --total >/dev/null 2>&1
AFTER=$(find "$H12" -type f -exec shasum {} \; | sort)
if [ "$RC" = 12 ] && [ "$BEFORE" = "$AFTER" ]; then
  ok "12 aborting on a malformed ledger left every ledger byte-identical (PDF-D37 never-auto-reset)"
else
  no "12 expected rc=12 with unchanged bytes; rc=$RC, ledgers changed: $(diff <(echo "$BEFORE") <(echo "$AFTER") | head -3)"
fi

# ── 12b. a ledger that is not valid UTF-8 is a NAMED abort, not a traceback ─────
# Found by probing, not by reading: the first cut raised UnicodeDecodeError and exited
# 1 with a stack trace. rc=1 still fails closed, but it is not the contract, and the
# obvious "fix" — errors="replace" — would coerce undecodable bytes to U+FFFD and feed
# them to json.loads, which is the same coercion by another route.
H12B="$TMP/binary"; mkdir -p "$H12B/muscle-1"
printf '{"order_id":"a","cost_usd":1.0}\n\200\201\376\n' > "$H12B/muscle-1/spend.jsonl"
OUT=$(python3 "$AGG" --fleet-home "$H12B" --total 2>"$TMP/e12b"); RC=$?
if [ "$RC" = 12 ] && [ -z "$OUT" ] && grep -q 'not valid UTF-8' "$TMP/e12b" \
   && ! grep -q 'Traceback' "$TMP/e12b"; then
  ok "12b a non-UTF-8 ledger aborts rc=12 by NAME (no traceback, no total, no U+FFFD coercion)"
else
  no "12b expected rc=12 + named UTF-8 abort + empty stdout; got rc=$RC stdout='$OUT' stderr='$(head -2 "$TMP/e12b")'"
fi

# ── 13. --total is a bare number a shell gate can consume ───────────────────────
T=$(python3 "$AGG" --fleet-home "$(mkhome bare)" --total)
case "$T" in ''|*[!0-9.]*) no "13 --total emitted a non-numeric '$T'";;
  *) ok "13 --total emits a bare number ('$T') — safe for \$(...) in a gate";; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
