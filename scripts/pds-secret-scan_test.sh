#!/usr/bin/env bash
#
# pds-secret-scan_test.sh — the COUNT IDENTITY in scripts/pds-secret-scan.sh:
# a DB scan may print a verdict only when the number of tables it EXAMINED
# equals the number its own enumeration put into the table list.
#
# WHY IT EXISTS (task-4121ac48f4e4f71e). `scan_db` reads its table list on fd 0
# (`while IFS= read -r table; do … done < "$tlist"`) and runs psql in the body.
# A body child that reads stdin swallows the rest of the list, the loop ENDS
# EARLY with no error and no non-zero status, and the scan prints
# "RESULT: VALUE SCAN CLEAN" over one table of forty in the same words it uses
# for forty of forty. The pre-existing floor (`[ "$tables" -eq 0 ]`) cannot see
# that: `-eq 0` separates "nothing" from "something", never "some" from "all".
#
# THE ARMS. Four, and the fourth is what makes the first three mean anything:
#
#   A  CONTROL       an intact scan over a 3-table fixture reports "3 of 3
#                    enumerated" and PRINTS its verdict, exit 0
#   B  SHORT READ    a `cat >/dev/null` is SPLICED into the loop body of a
#                    scratch copy (anchor matched EXACTLY ONCE, diff non-empty),
#                    so the body drains fd 0 exactly as a stdin-reading psql
#                    would. The identity must REFUSE naming BOTH numbers
#                    ("examined 1 of 3"), exit 2, and NO `RESULT:` line may be
#                    printed
#   C  ZERO TABLES   an empty enumeration still fires its OWN distinct refusal
#                    ("ZERO base tables") and must NOT be reported as a short
#                    scan — two failures, two messages
#   D  MUTATION      the identity block is CUT from a scratch copy (between its
#                    MUT-ANCHOR/MUT-END markers). Arm B must then go GREEN and
#                    print CLEAN over 1 of 3 — the defect, reproduced — while A
#                    and C stay unchanged. A guard whose removal changes nothing
#                    was never the guard.
#
# psql is STUBBED (a shell script first on PATH); no database, no network, no
# credential. bash 3.2 compatible (macOS system bash).
#
# EXIT CODES: 0 all assertions pass · 1 at least one failed · 2 cannot measure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="${PDS_SECRET_SCAN:-$REPO_ROOT/scripts/pds-secret-scan.sh}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
unavailable() { echo "HARNESS-UNAVAILABLE: $*" >&2; exit 2; }

[ -f "$SCAN" ] || unavailable "scan script not found: $SCAN"
command -v awk >/dev/null 2>&1 || unavailable "awk is required"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pdsss.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── the psql stub ───────────────────────────────────────────────────────────
# Two behaviours, keyed off the SQL the scan sends: the enumeration query names
# `relname`, every other query is a per-table count. The table list comes from
# $STUB_TABLES (newline-separated, possibly empty). It NEVER reads stdin — the
# stub is not the plant; the plant is spliced into the scan's own loop body, so
# the identity is proven against a SHORT SCAN, not against one particular cause.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/psql" <<'STUB'
#!/usr/bin/env bash
sql=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) sql="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$sql" in
  # Real psql -At terminates every row with a newline. $STUB_TABLES is
  # whitespace-separated and deliberately UNQUOTED here so an empty value
  # prints nothing at all (not one blank line) — arm C needs a truly empty
  # enumeration, and a blank line would be a different fixture.
  *relname*) [ -n "${STUB_TABLES:-}" ] && printf '%s\n' ${STUB_TABLES} ;;
  *)         echo 0 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/psql"

THREE="alpha beta gamma"

run_scan() { # script stub_tables outprefix
  local script="$1" tbl="$2" pre="$3" rc=0
  PATH="$TMP/bin:$PATH" STUB_TABLES="$tbl" \
    bash "$script" scan --db "host=stub dbname=stub" --value "s3cret-ammo-value" \
    >"$pre.out" 2>"$pre.err" || rc=$?
  echo "$rc"
}

has() { grep -q "$2" "$1" 2>/dev/null; }

# ── the scratch copies ──────────────────────────────────────────────────────
# B's PLANT: a stdin-draining child inside the loop body, spliced right after
# the iteration tally. Anchor asserted UNIQUE and the diff asserted non-empty —
# a mutation that did not land is a green about nothing.
PLANT="$TMP/planted.sh"
anchor='    tables=$((tables + 1))'
n_anchor=$(grep -cF "$anchor" "$SCAN")
if [ "$n_anchor" != "1" ]; then
  unavailable "the plant anchor matched $n_anchor times, expected exactly 1: $anchor"
fi
awk -v a="$anchor" '{ print; if ($0 == a) print "    cat >/dev/null" }' "$SCAN" > "$PLANT"
if cmp -s "$SCAN" "$PLANT"; then unavailable "the stdin-drain plant produced an identical file"; fi
ok "plant landed: 'cat >/dev/null' spliced into the loop body at the unique anchor"

# D's CUT: the identity decision removed between its markers.
CUT="$TMP/cut.sh"
n_mut=$(grep -c 'MUT-ANCHOR: table-count-identity' "$SCAN")
if [ "$n_mut" != "1" ]; then
  unavailable "the identity MUT-ANCHOR matched $n_mut times, expected exactly 1"
fi
sed '/MUT-ANCHOR: table-count-identity/,/MUT-END: table-count-identity/d' "$SCAN" > "$CUT"
if cmp -s "$SCAN" "$CUT"; then unavailable "the identity cut produced an identical file"; fi
ok "cut landed: the table-count-identity block removed from the scratch copy"

# B's PLANT ON TOP OF D's CUT — arm D needs the short read WITHOUT the guard.
CUTPLANT="$TMP/cut-planted.sh"
awk -v a="$anchor" '{ print; if ($0 == a) print "    cat >/dev/null" }' "$CUT" > "$CUTPLANT"
cmp -s "$CUT" "$CUTPLANT" && unavailable "the plant did not land on the cut copy"

# ── A: CONTROL — an intact scan examines every enumerated table ─────────────
rc=$(run_scan "$SCAN" "$THREE" "$TMP/a")
if [ "$rc" = "0" ]; then ok "A control: intact scan over 3 tables exits 0"
else bad "A control: expected exit 0, got $rc"; sed -n '1,5p' "$TMP/a.err" >&2; fi
if has "$TMP/a.out" 'tables scanned: 3 of 3 enumerated'; then
  ok "A control: reports 'tables scanned: 3 of 3 enumerated'"
else bad "A control: no '3 of 3 enumerated' line"; fi
if has "$TMP/a.out" 'RESULT: VALUE SCAN CLEAN'; then
  ok "A control: PRINTS its verdict (RESULT: VALUE SCAN CLEAN)"
else bad "A control: the verdict line is missing"; fi

# ── B: SHORT READ — the identity refuses, naming both numbers ───────────────
rc=$(run_scan "$PLANT" "$THREE" "$TMP/b")
if [ "$rc" = "2" ]; then ok "B short read: refuses with exit 2"
else bad "B short read: expected exit 2, got $rc"; fi
if has "$TMP/b.err" 'SHORT TABLE SCAN'; then
  ok "B short read: fires the SHORT TABLE SCAN refusal"
else bad "B short read: the short-scan refusal did not fire"; cat "$TMP/b.err" >&2; fi
if has "$TMP/b.err" 'examined 1 of 3 table'; then
  ok "B short read: the refusal names BOTH numbers ('examined 1 of 3 table(s)')"
else bad "B short read: the refusal does not name both numbers"; cat "$TMP/b.err" >&2; fi
if has "$TMP/b.out" 'RESULT:' || has "$TMP/b.err" 'RESULT:'; then
  bad "B short read: a RESULT: verdict was printed over a partial scan"
else ok "B short read: NO verdict printed — no RESULT: line on either stream"; fi
if has "$TMP/b.err" 'ZERO base tables'; then
  bad "B short read: fired the zero-tables message instead of its own"
else ok "B short read: distinct from the zero-tables refusal (that message absent)"; fi

# ── C: ZERO TABLES — the pre-existing refusal, still its own message ────────
rc=$(run_scan "$SCAN" "" "$TMP/c")
if [ "$rc" = "2" ]; then ok "C zero tables: refuses with exit 2"
else bad "C zero tables: expected exit 2, got $rc"; fi
if has "$TMP/c.err" 'ZERO base tables'; then
  ok "C zero tables: fires its OWN message (schema public holds ZERO base tables)"
else bad "C zero tables: the zero-tables refusal did not fire"; cat "$TMP/c.err" >&2; fi
if has "$TMP/c.err" 'SHORT TABLE SCAN'; then
  bad "C zero tables: mis-reported as a short scan (0 of 0 is an identity, not a shortfall)"
else ok "C zero tables: NOT reported as a short scan — two refusals, two messages"; fi
if has "$TMP/c.out" 'RESULT:'; then
  bad "C zero tables: a verdict was printed over an empty corpus"
else ok "C zero tables: no verdict printed"; fi

# ── D: MUTATION — cut the identity and arm B must go GREEN over 1 of 3 ─────
rc=$(run_scan "$CUTPLANT" "$THREE" "$TMP/d")
if [ "$rc" = "0" ]; then
  ok "D mutation: without the identity the SHORT scan exits 0 — the defect, reproduced"
else bad "D mutation: expected the cut copy to exit 0 on a short read, got $rc"; cat "$TMP/d.err" >&2; fi
if has "$TMP/d.out" 'RESULT: VALUE SCAN CLEAN'; then
  ok "D mutation: prints CLEAN over 1 of 3 tables — exactly what arm B now refuses"
else bad "D mutation: expected a CLEAN verdict from the un-guarded short scan"; fi
if has "$TMP/d.err" 'SHORT TABLE SCAN'; then
  bad "D mutation: the refusal survived the cut — the cut did not remove the decision"
else ok "D mutation: the refusal is GONE once its block is cut (RED-before is real)"; fi
# and the cut must not disturb the other two arms
rc=$(run_scan "$CUT" "$THREE" "$TMP/d2")
if [ "$rc" = "0" ] && has "$TMP/d2.out" 'RESULT: VALUE SCAN CLEAN'; then
  ok "D mutation: arm A is unaffected by the cut (intact scan still clean, exit 0)"
else bad "D mutation: the cut changed arm A, so the cut is not surgical (rc=$rc)"; fi
rc=$(run_scan "$CUT" "" "$TMP/d3")
if [ "$rc" = "2" ] && has "$TMP/d3.err" 'ZERO base tables'; then
  ok "D mutation: arm C is unaffected by the cut (zero-tables refusal still fires)"
else bad "D mutation: the cut changed arm C, so the cut is not surgical (rc=$rc)"; fi

# ── E: UNTERMINATED LAST LINE — the identity must not refuse a GOOD scan ───
# A guard that reds on correct input gets deleted the first week it costs
# someone a scan. Found by arm A on the first run of this harness: a table list
# whose final line carries no newline was dropped by a plain `while read`, and
# the identity correctly refused "2 of 3" over a complete list. The loop now
# carries `|| [ -n "$table" ]`; this arm is why.
cat > "$TMP/bin/psql" <<'STUB2'
#!/usr/bin/env bash
sql=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) sql="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$sql" in
  *relname*) printf 'alpha\nbeta\ngamma' ;;
  *)         echo 0 ;;
esac
exit 0
STUB2
chmod +x "$TMP/bin/psql"
rc=$(run_scan "$SCAN" "$THREE" "$TMP/e")
if [ "$rc" = "0" ] && has "$TMP/e.out" 'tables scanned: 3 of 3 enumerated'; then
  ok "E unterminated last line: still 3 of 3 — no false refusal on a complete list"
else
  bad "E unterminated last line: expected 3 of 3 and exit 0, got rc=$rc"
  cat "$TMP/e.err" >&2
fi

echo "── pds-secret-scan count identity: $((PASS + FAIL)) checks, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
