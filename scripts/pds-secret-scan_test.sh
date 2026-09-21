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
# ARMS F-I do the same job for the BUNDLE member loop in `scan_bundle`
# (task-57fbebcb2d5339ff) — the other half of the same CLEAN. Their own
# commentary sits above arm F.
#
# ARMS J-M do it for the DENIED-MEMBER loop in `check_deny_members`
# (task-068696cdce7db36b) — the third loop of the shape, and the one whose
# verdict PRINTS its coverage number. Their own commentary sits above arm J.
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

# ═══ THE BUNDLE MEMBER LOOP (task-57fbebcb2d5339ff) ═════════════════════════
# The same defect one function up, in `scan_bundle`. It reads its member list
# on fd 0 and produces the OTHER half of the very same "RESULT: VALUE SCAN
# CLEAN" the arms above guard. Its two pre-existing floors (`members -eq 0`,
# `table_members -eq 0`) are `-eq 0` floors, so they separate "nothing" from
# "something" and never "some" from "all".
#
# THE PLANT IS CONDITIONAL, AND THAT IS THE POINT. A drain on the FIRST
# iteration is caught by accident on a real bundle shape: `find | sort` puts
# `manifest.json` ahead of `tables/…`, so a 1-member scan trips the
# "no tables/ member" floor — with the WRONG message, and only by sort order.
# `[ "$members" -ge 2 ] && cat >/dev/null` drains from the second iteration on,
# which leaves members=2 and table_members=1: BOTH floors cleared, and on
# origin/main that run prints CLEAN over 2 of 4 members in exactly the words a
# full scan uses. That run is the RED this arm converts into a refusal.
#
#   F  CONTROL     an intact bundle scan reports "4 of 4 enumerated" and PRINTS
#                  its verdict, exit 0
#   G  SHORT READ  the drain is spliced into the member loop body; the identity
#                  must REFUSE naming BOTH numbers ("examined 2 of 4 member(s)"),
#                  exit 2, with NO `RESULT:` line on either stream and neither
#                  floor's message borrowed
#   H  MUTATION    the bundle identity block is CUT between its markers; arm G
#                  must then go GREEN and print CLEAN over 2 of 4 — the defect,
#                  reproduced — while F is unchanged
#   I  ZERO        a tar holding no regular file still fires its OWN
#                  "ZERO members" refusal and is not mis-reported as short
#
# No psql, no database, no network: a bundle scan is tar + find + grep.

BFIX="$TMP/bundle"
mkdir -p "$BFIX/tables"
echo '{"format":"bp-export-v1","tables":["alpha","beta","gamma"]}' > "$BFIX/manifest.json"
for t in alpha beta gamma; do printf '1\trow-for-%s\n' "$t" > "$BFIX/tables/$t.copy"; done
BTAR="$TMP/bundle.tar"
tar -cf "$BTAR" -C "$BFIX" . 2>/dev/null || unavailable "cannot build the fixture bundle tar"
# 4 regular files: manifest.json + three tables/*.copy. Asserted, not assumed —
# every "N of 4" below is a claim about THIS number.
n_files=$(find "$BFIX" -type f | wc -l | tr -d ' ')
[ "$n_files" = "4" ] || unavailable "fixture bundle holds $n_files regular files, expected 4"

EMPTY_DIR="$TMP/emptybundle"
mkdir -p "$EMPTY_DIR/tables"
ETAR="$TMP/empty.tar"
tar -cf "$ETAR" -C "$EMPTY_DIR" . 2>/dev/null || unavailable "cannot build the empty fixture tar"

run_bundle_scan() { # script bundle outprefix
  local script="$1" tar_path="$2" pre="$3" rc=0
  bash "$script" scan --bundle "$tar_path" --value "s3cret-ammo-value-xyz" \
    >"$pre.out" 2>"$pre.err" || rc=$?
  echo "$rc"
}

# G's PLANT: a stdin-draining child in the MEMBER loop body, from the second
# iteration on. Anchor asserted UNIQUE and the diff asserted non-empty — a
# mutation that did not land is a green about nothing.
BPLANT="$TMP/bundle-planted.sh"
banchor='    members=$((members + 1))'
bdrain='    [ "$members" -ge 2 ] && cat >/dev/null'
n_banchor=$(grep -cF "$banchor" "$SCAN")
if [ "$n_banchor" != "1" ]; then
  unavailable "the bundle plant anchor matched $n_banchor times, expected exactly 1: $banchor"
fi
awk -v a="$banchor" -v d="$bdrain" '{ print; if ($0 == a) print d }' "$SCAN" > "$BPLANT"
if cmp -s "$SCAN" "$BPLANT"; then unavailable "the bundle stdin-drain plant produced an identical file"; fi
ok "bundle plant landed: a stdin-draining child spliced into the member loop body at the unique anchor"

# H's CUT: the bundle identity decision removed between its markers.
BCUT="$TMP/bundle-cut.sh"
n_bmut=$(grep -c 'MUT-ANCHOR: bundle-count-identity' "$SCAN")
if [ "$n_bmut" != "1" ]; then
  unavailable "the bundle identity MUT-ANCHOR matched $n_bmut times, expected exactly 1"
fi
sed '/MUT-ANCHOR: bundle-count-identity/,/MUT-END: bundle-count-identity/d' "$SCAN" > "$BCUT"
if cmp -s "$SCAN" "$BCUT"; then unavailable "the bundle identity cut produced an identical file"; fi
BCUTPLANT="$TMP/bundle-cut-planted.sh"
awk -v a="$banchor" -v d="$bdrain" '{ print; if ($0 == a) print d }' "$BCUT" > "$BCUTPLANT"
cmp -s "$BCUT" "$BCUTPLANT" && unavailable "the bundle plant did not land on the cut copy"
ok "bundle cut landed: the bundle-count-identity block removed from the scratch copy"

# ── F: CONTROL — an intact bundle scan examines every enumerated member ─────
rc=$(run_bundle_scan "$SCAN" "$BTAR" "$TMP/f")
if [ "$rc" = "0" ]; then ok "F control: intact bundle scan over 4 members exits 0"
else bad "F control: expected exit 0, got $rc"; sed -n '1,5p' "$TMP/f.err" >&2; fi
if has "$TMP/f.out" 'members scanned: 4 of 4 enumerated'; then
  ok "F control: reports 'members scanned: 4 of 4 enumerated'"
else bad "F control: no '4 of 4 enumerated' line"; cat "$TMP/f.out" >&2; fi
if has "$TMP/f.out" 'RESULT: VALUE SCAN CLEAN'; then
  ok "F control: PRINTS its verdict (RESULT: VALUE SCAN CLEAN)"
else bad "F control: the verdict line is missing"; fi

# ── G: SHORT READ — the identity refuses, naming both numbers ───────────────
rc=$(run_bundle_scan "$BPLANT" "$BTAR" "$TMP/g")
if [ "$rc" = "2" ]; then ok "G short read: refuses with exit 2"
else bad "G short read: expected exit 2, got $rc"; cat "$TMP/g.err" >&2; fi
if has "$TMP/g.err" 'SHORT BUNDLE SCAN'; then
  ok "G short read: fires the SHORT BUNDLE SCAN refusal"
else bad "G short read: the short-scan refusal did not fire"; cat "$TMP/g.err" >&2; fi
if has "$TMP/g.err" 'examined 2 of 4 member'; then
  ok "G short read: the refusal names BOTH numbers ('examined 2 of 4 member(s)')"
else bad "G short read: the refusal does not name both numbers"; cat "$TMP/g.err" >&2; fi
if has "$TMP/g.out" 'RESULT:' || has "$TMP/g.err" 'RESULT:'; then
  bad "G short read: a RESULT: verdict was printed over a partial bundle scan"
else ok "G short read: NO verdict printed — no RESULT: line on either stream"; fi
if has "$TMP/g.err" 'ZERO members' || has "$TMP/g.err" 'no tables/ member'; then
  bad "G short read: borrowed a floor's message instead of its own"
else ok "G short read: distinct from both -eq 0 floors (neither message present)"; fi

# ── H: MUTATION — cut the identity and arm G must go GREEN over 2 of 4 ─────
rc=$(run_bundle_scan "$BCUTPLANT" "$BTAR" "$TMP/h")
if [ "$rc" = "0" ]; then
  ok "H mutation: without the identity the SHORT bundle scan exits 0 — the defect, reproduced"
else bad "H mutation: expected the cut copy to exit 0 on a short read, got $rc"; cat "$TMP/h.err" >&2; fi
if has "$TMP/h.out" 'RESULT: VALUE SCAN CLEAN'; then
  ok "H mutation: prints CLEAN over 2 of 4 members — exactly what arm G now refuses"
else bad "H mutation: expected a CLEAN verdict from the un-guarded short bundle scan"; cat "$TMP/h.out" >&2; fi
if has "$TMP/h.err" 'SHORT BUNDLE SCAN'; then
  bad "H mutation: the refusal survived the cut — the cut did not remove the decision"
else ok "H mutation: the refusal is GONE once its block is cut (RED-before is real)"; fi
rc=$(run_bundle_scan "$BCUT" "$BTAR" "$TMP/h2")
if [ "$rc" = "0" ] && has "$TMP/h2.out" 'RESULT: VALUE SCAN CLEAN'; then
  ok "H mutation: arm F is unaffected by the cut (intact bundle scan still clean, exit 0)"
else bad "H mutation: the cut changed arm F, so the cut is not surgical (rc=$rc)"; fi

# ── I: ZERO MEMBERS — the pre-existing floor keeps its own message ──────────
rc=$(run_bundle_scan "$SCAN" "$ETAR" "$TMP/i")
if [ "$rc" = "2" ]; then ok "I zero members: refuses with exit 2"
else bad "I zero members: expected exit 2, got $rc"; cat "$TMP/i.err" >&2; fi
if has "$TMP/i.err" 'ZERO members'; then
  ok "I zero members: fires its OWN message (bundle contains ZERO members)"
else bad "I zero members: the zero-members refusal did not fire"; cat "$TMP/i.err" >&2; fi
if has "$TMP/i.err" 'SHORT BUNDLE SCAN'; then
  bad "I zero members: mis-reported as a short scan (0 of 0 is an identity, not a shortfall)"
else ok "I zero members: NOT reported as a short scan — two refusals, two messages"; fi
if has "$TMP/i.out" 'RESULT:'; then
  bad "I zero members: a verdict was printed over an empty container"
else ok "I zero members: no verdict printed"; fi

# ═══ THE DENIED-MEMBER LOOP (task-068696cdce7db36b) ═════════════════════════
# The third loop in this file with the same shape, and the one whose verdict
# carries the coverage number in its own text. `check_deny_members` reads the
# deny list on fd 0 (`done < "$DENY_MEMBERS_FILE"`) and the final verdict used
# to read its figure off `wc -l` of that INPUT FILE:
#
#     RESULT: DENIED MEMBERS ABSENT — 6 checked path(s), none present …
#
# A loop that ended after row 1 leaves MEMBER_HITS=0, so that line printed "6
# checked path(s)" over one path examined — a coverage claim sourced from the
# enumeration, which by construction cannot notice that the work stopped.
# There is no -eq 0 floor here at all, so nothing else was watching.
#
#   J  CONTROL     an intact deny check over 3 rows prints
#                  "DENIED MEMBERS ABSENT — 3 checked path(s)", exit 0; and a
#                  deny path that IS in the bundle still reports PRESENT, exit 1
#   K  SHORT READ  a stdin-draining child is spliced into the deny loop body;
#                  the identity must REFUSE naming BOTH numbers ("examined 1 of
#                  3 denied path(s)"), exit 2, and NO ABSENT verdict may print
#   L  CUT         the identity block is CUT between its markers; arm K's short
#                  read must then print the OLD line — "DENIED MEMBERS ABSENT —
#                  3 checked path(s)" over a loop that examined 1 — at exit 0.
#                  That is the defect reproduced verbatim, and it is what makes
#                  arms J and K mean anything
#   M  BLANK ROW   a blank deny row must not manufacture a refusal: the loop
#                  skips it before tallying, so the enumeration side counts with
#                  `awk NF`. A guard that reds on correct input gets deleted.
#
# No psql, no database, no network: a deny check is tar + find + grep.

DENY_ABSENT_ARGS='--deny-member tables/webhooks.copy --deny-member tables/api_tokens.copy --deny-member tables/access_grants.copy'

run_deny_scan() { # script bundle outprefix extra-args...
  local script="$1" tar_path="$2" pre="$3" rc=0
  shift 3
  bash "$script" scan --bundle "$tar_path" "$@" >"$pre.out" 2>"$pre.err" || rc=$?
  echo "$rc"
}

# K's PLANT: a stdin-draining child in the DENY loop body, spliced right after
# the iteration tally. Anchor asserted UNIQUE and the diff asserted non-empty —
# a mutation that did not land is a green about nothing.
DPLANT="$TMP/deny-planted.sh"
danchor='    checked=$((checked + 1))'
n_danchor=$(grep -cF "$danchor" "$SCAN")
if [ "$n_danchor" != "1" ]; then
  unavailable "the deny plant anchor matched $n_danchor times, expected exactly 1: $danchor"
fi
awk -v a="$danchor" '{ print; if ($0 == a) print "    cat >/dev/null" }' "$SCAN" > "$DPLANT"
if cmp -s "$SCAN" "$DPLANT"; then unavailable "the deny stdin-drain plant produced an identical file"; fi
ok "deny plant landed: 'cat >/dev/null' spliced into the deny loop body at the unique anchor"

# L's CUT: the deny identity decision removed between its markers.
DCUT="$TMP/deny-cut.sh"
n_dmut=$(grep -c 'MUT-ANCHOR: deny-count-identity' "$SCAN")
if [ "$n_dmut" != "1" ]; then
  unavailable "the deny identity MUT-ANCHOR matched $n_dmut times, expected exactly 1"
fi
sed '/MUT-ANCHOR: deny-count-identity/,/MUT-END: deny-count-identity/d' "$SCAN" > "$DCUT"
if cmp -s "$SCAN" "$DCUT"; then unavailable "the deny identity cut produced an identical file"; fi
DCUTPLANT="$TMP/deny-cut-planted.sh"
awk -v a="$danchor" '{ print; if ($0 == a) print "    cat >/dev/null" }' "$DCUT" > "$DCUTPLANT"
cmp -s "$DCUT" "$DCUTPLANT" && unavailable "the deny plant did not land on the cut copy"
ok "deny cut landed: the deny-count-identity block removed from the scratch copy"

# ── J: CONTROL — an intact deny check examines every enumerated deny row ─────
rc=$(run_deny_scan "$SCAN" "$BTAR" "$TMP/j" $DENY_ABSENT_ARGS)
if [ "$rc" = "0" ]; then ok "J control: intact deny check over 3 absent paths exits 0"
else bad "J control: expected exit 0, got $rc"; sed -n '1,5p' "$TMP/j.err" >&2; fi
if has "$TMP/j.out" 'RESULT: DENIED MEMBERS ABSENT — 3 checked path(s)'; then
  ok "J control: prints 'DENIED MEMBERS ABSENT — 3 checked path(s)' — the ITERATION count"
else bad "J control: the ABSENT verdict is missing or carries the wrong count"; cat "$TMP/j.out" >&2; fi
if has "$TMP/j.err" 'SHORT DENIED-MEMBER CHECK'; then
  bad "J control: the identity refused a COMPLETE deny list"
else ok "J control: no false refusal on a complete list"; fi
# and the check still FIRES: a deny path that IS in the bundle is reported
rc=$(run_deny_scan "$SCAN" "$BTAR" "$TMP/j2" --deny-member tables/alpha.copy --deny-member tables/api_tokens.copy)
if [ "$rc" = "1" ]; then ok "J control: a PRESENT denied member still exits 1 — the check FIRES"
else bad "J control: expected exit 1 for a present denied member, got $rc"; cat "$TMP/j2.err" >&2; fi
if has "$TMP/j2.out" 'RESULT: 1 DENIED MEMBER(S) PRESENT'; then
  ok "J control: reports 'RESULT: 1 DENIED MEMBER(S) PRESENT'"
else bad "J control: the PRESENT verdict is missing"; cat "$TMP/j2.out" >&2; fi

# ── K: SHORT READ — the identity refuses, naming both numbers ───────────────
rc=$(run_deny_scan "$DPLANT" "$BTAR" "$TMP/k" $DENY_ABSENT_ARGS)
if [ "$rc" = "2" ]; then ok "K short read: refuses with exit 2"
else bad "K short read: expected exit 2, got $rc"; cat "$TMP/k.err" >&2; fi
if has "$TMP/k.err" 'SHORT DENIED-MEMBER CHECK'; then
  ok "K short read: fires the SHORT DENIED-MEMBER CHECK refusal"
else bad "K short read: the short-check refusal did not fire"; cat "$TMP/k.err" >&2; fi
if has "$TMP/k.err" 'examined 1 of 3 denied path'; then
  ok "K short read: the refusal names BOTH numbers ('examined 1 of 3 denied path(s)')"
else bad "K short read: the refusal does not name both numbers"; cat "$TMP/k.err" >&2; fi
# The VERDICT LINE, not the bare phrase: the refusal's own text quotes the
# words it is refusing to print ("must never print DENIED MEMBERS ABSENT in the
# same words as a full one"), so a bare-phrase assertion matches the refusal
# itself and fails on a run that behaved perfectly. Found by this arm on its
# first run.
if has "$TMP/k.out" 'RESULT: DENIED MEMBERS ABSENT' || has "$TMP/k.err" 'RESULT: DENIED MEMBERS ABSENT'; then
  bad "K short read: an ABSENT verdict was printed over a partial deny check"
else ok "K short read: NO ABSENT verdict line printed on either stream"; fi
if has "$TMP/k.err" 'SHORT BUNDLE SCAN'; then
  bad "K short read: borrowed the bundle loop's message instead of its own"
else ok "K short read: distinct from the bundle-loop refusal (that message absent)"; fi

# ── L: CUT-IDENTITY — the OLD line, printed over a short read ───────────────
# This is the RED-WITHOUT. Without the identity block the very same drained run
# prints the enumeration's number — 3 — over one path examined, in exactly the
# words a complete check uses, and exits 0.
rc=$(run_deny_scan "$DCUTPLANT" "$BTAR" "$TMP/l" $DENY_ABSENT_ARGS)
if [ "$rc" = "0" ]; then
  ok "L cut: without the identity the SHORT deny check exits 0 — the defect, reproduced"
else bad "L cut: expected the cut copy to exit 0 on a short read, got $rc"; cat "$TMP/l.err" >&2; fi
if has "$TMP/l.out" 'RESULT: DENIED MEMBERS ABSENT — 3 checked path(s)'; then
  ok "L cut: prints the OLD line — '3 checked path(s)' over 1 examined — exactly what arm K now refuses"
else bad "L cut: expected the old wc-of-the-input ABSENT line from the un-guarded short check"; cat "$TMP/l.out" >&2; fi
if has "$TMP/l.err" 'SHORT DENIED-MEMBER CHECK'; then
  bad "L cut: the refusal survived the cut — the cut did not remove the decision"
else ok "L cut: the refusal is GONE once its block is cut (RED-before is real)"; fi
rc=$(run_deny_scan "$DCUT" "$BTAR" "$TMP/l2" $DENY_ABSENT_ARGS)
if [ "$rc" = "0" ] && has "$TMP/l2.out" 'RESULT: DENIED MEMBERS ABSENT'; then
  ok "L cut: arm J is unaffected by the cut (intact deny check still ABSENT, exit 0)"
else bad "L cut: the cut changed arm J, so the cut is not surgical (rc=$rc)"; fi

# ── M: BLANK DENY ROW — the identity must not refuse a GOOD check ───────────
# The loop skips blank rows BEFORE it tallies, so the enumeration side counts
# with `awk NF`. A `wc -l` there would read 4 against 3 iterations and refuse a
# complete deny list — the false refusal that gets a guard deleted.
rc=$(run_deny_scan "$SCAN" "$BTAR" "$TMP/m" --deny-member tables/webhooks.copy --deny-member '' --deny-member tables/api_tokens.copy --deny-member tables/access_grants.copy)
if [ "$rc" = "0" ] && has "$TMP/m.out" 'RESULT: DENIED MEMBERS ABSENT — 3 checked path(s)'; then
  ok "M blank row: a blank deny row is skipped by BOTH sides — still 3 checked, no false refusal"
else
  bad "M blank row: expected '3 checked path(s)' and exit 0, got rc=$rc"
  cat "$TMP/m.err" >&2; grep 'DENIED MEMBERS' "$TMP/m.out" >&2
fi

echo "── pds-secret-scan count identity: $((PASS + FAIL)) checks, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
