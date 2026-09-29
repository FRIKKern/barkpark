#!/usr/bin/env bash
# breaker-measure-precondition.sh — CAN the main-red breaker's before/after value
# actually be MEASURED yet, decomposed by VERDICT? (task-33682262f429d104)
#
# WHY THIS EXISTS. task-33682262f429d104 asks for the breaker's value measured
# before/after over 3 clean days post-9cc549964, DECOMPOSED BY VERDICT:
# INHERITED-FROM-MAIN vs OWNERSHIP-UNDETERMINED vs this-PR's-own. Two independent
# preconditions have to hold before that number means anything, and BOTH of them
# rot silently:
#
#   1. THE WINDOW. 9cc549964 (#16265) is not the only intervention in the window —
#      ad80d3bce (#16572) changed the breaker AGAIN 19h21m later. A window drawn
#      across that second boundary measures the sum of two changes and attributes
#      it to one. This script derives the three windows from the two commits and
#      the CLOCK, so nobody has to remember that the boundary exists.
#
#   2. THE INSTRUMENT. `ci-measure.sh --breaker` reads the verdict out of the job
#      log with breaker_verdict(), which is TWO-VALUED: INHERITED-FROM-MAIN, or
#      NONE. main-red-breaker.sh emits THREE verdicts. OWNERSHIP-UNDETERMINED —
#      the verdict #16265 ADDED, and the exact column this measurement is supposed
#      to decompose by — lands in NONE, the same bucket as a PR's own red and a
#      green job. So the three-way split is NOT DERIVABLE from that instrument at
#      any window, however clean. That is an instrument gap, not a data gap, and a
#      table printed anyway would look complete.
#
# THE READER IS NOT COPIED, IT IS EXTRACTED. breaker_verdict() is lifted out of
# ci-measure.sh at runtime, so the day someone teaches it a third verdict this
# check goes quiet on its own. A second copy of the rule living here would be free
# to drift from the copy that actually produces the number.
#
# USAGE
#   bash scripts/breaker-measure-precondition.sh              # report; rc 0 iff both preconditions hold
#   bash scripts/breaker-measure-precondition.sh --selftest   # arms + control, no network, no clock
#
# EXIT  0 both preconditions hold — the decomposed measurement can be taken
#       1 a precondition FAILS — the report names which, and what would clear it
#       2 the check itself could not measure (missing input, or a generator that
#         produced too few distinct verdicts to discriminate anything)
set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CI_MEASURE="${CI_MEASURE:-$SCRIPT_DIR/ci-measure.sh}"
BREAKER="${BREAKER_SCRIPT:-$SCRIPT_DIR/main-red-breaker.sh}"

# The two interventions inside the nominal window. Both are stated as SHAs so the
# boundary is auditable; the timestamps are read from git, never typed.
V3_SHA="${V3_SHA:-9cc549964acc8cd2509a528623fb5181b47b4064}"   # #16265
V4_SHA="${V4_SHA:-ad80d3bcef9f5ef8abf58d3a6b29046df85fa2ab}"   # #16572

# ---------------------------------------------------------------------------
# extract_reader — breaker_verdict(), lifted verbatim out of ci-measure.sh.
# Printed to stdout as shell source. Fails loudly if the function is not found:
# an empty extraction would eval to nothing and every verdict would read empty,
# which is a collapse this script would then report as a finding. A missing
# function is a BROKEN CHECK (rc 2), not a finding.
# ---------------------------------------------------------------------------
extract_reader() {
  local f="$1"
  [ -r "$f" ] || { echo "breaker-measure-precondition: cannot read $f" >&2; return 2; }
  awk '
    /^breaker_verdict\(\)[[:space:]]*\{/ { inf=1 }
    inf { print }
    inf && /^\}/ { exit }
  ' "$f"
}

# ---------------------------------------------------------------------------
# probe_reader — drive the GENERATOR over fixtures that force each of its three
# verdicts, pipe each real log through the READER, and report the mapping.
# Emits one "<generator-verdict>\t<reader-verdict>" line per fixture.
# ---------------------------------------------------------------------------
probe_reader() {
  local gen="$1" tmpd; tmpd="$(mktemp -d)"
  # main ALSO fails our step -> INHERITED-FROM-MAIN
  printf '%s\n' '{"jobs":[{"name":"J","conclusion":"failure","steps":[{"name":"guard","conclusion":"failure"}]}]}' > "$tmpd/inherited.json"
  # main carries no job of this name -> OWNERSHIP-UNDETERMINED (the M1 shape)
  printf '%s\n' '{"jobs":[{"name":"Other","conclusion":"success","steps":[{"name":"x","conclusion":"success"}]}]}' > "$tmpd/undetermined.json"
  # main's jobs body is empty -> OWNERSHIP-UNDETERMINED under CANNOT READ
  printf '%s\n' '{"jobs":[]}' > "$tmpd/unreadable.json"
  local fx out gv rv
  for fx in inherited undetermined unreadable; do
    out=$(STEP_OUTCOMES='{"s1":{"outcome":"failure"}}' STEP_NAMES='{"s1":"guard"}' \
          JOB_NAME='J' WORKFLOW_FILE='doc-gates.yml' GITHUB_EVENT_NAME=pull_request \
          MAIN_RED_BREAKER_FIXTURE="$tmpd/$fx.json" GITHUB_STEP_SUMMARY=/dev/null \
          bash "$gen" 2>&1)
    gv=$(printf '%s\n' "$out" | sed -n 's/^main-red-breaker: \([A-Z][A-Z-]*\).*/\1/p' | head -1)
    [ -z "$gv" ] && gv=UNPARSED
    rv=$(printf '%s\n' "$out" | breaker_verdict)
    printf '%s\t%s\n' "$gv" "$rv"
  done
  rm -rf "$tmpd"
}

# ---------------------------------------------------------------------------
# judge_mapping — the DETECTOR. Mapping lines on stdin.
#   rc 0  every distinct generator verdict maps to a distinct reader verdict
#   rc 1  two distinct generator verdicts COLLAPSE onto one reader verdict
#   rc 2  the generator produced fewer than 2 distinct verdicts, so this probe
#         discriminates nothing and a "no collapse" verdict would be VACUOUS.
#         The precondition is asserted, never assumed from a clean exit code.
# ---------------------------------------------------------------------------
judge_mapping() {
  # The python source goes to a FILE, never a heredoc: a heredoc on `python3 -`
  # replaces stdin, so the mapping lines never arrive and every arm reads ZERO
  # fixtures. That failure is silent-shaped — it exits 2 with a plausible REFUSE
  # sentence about the generator, which is a true sentence about the wrong thing.
  local pyf; pyf="$(mktemp)"
  cat > "$pyf" <<'PYEOF'
import sys, collections

# THE NO-VERDICT TOKENS. breaker_verdict()'s `else` branch is NONE — the value it
# also returns for a green job, for a log it could not read, and for a log that
# never reached a verdict at all. A generator verdict that reads back as one of
# these is not merely renamed, it is INDISTINGUISHABLE FROM NOTHING HAPPENING,
# and a column counted off it is structurally zero.
NOVERDICT = {"NONE", "", "UNREAD", "UNPARSED"}

pairs = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line: continue
    g, _, r = line.partition("\t")
    pairs.append((g, r))

gens = {g for g, _ in pairs}
if len(gens) < 2:
    print("REFUSE: the generator emitted %d distinct verdict(s) %s over %d fixtures - "
          "this probe discriminates nothing, so any verdict here would be vacuous."
          % (len(gens), sorted(gens), len(pairs)), file=sys.stderr)
    raise SystemExit(2)

byreader = collections.defaultdict(set)
for g, r in pairs:
    byreader[r].add(g)

for g, r in pairs:
    print("    generator %-24s -> reader %s" % (g, r))
print("    (%d distinct generator verdicts, %d distinct reader values)" % (len(gens), len(byreader)))

bad = False
swallowed = sorted({g for g, r in pairs if r in NOVERDICT})
if swallowed:
    bad = True
    for g in swallowed:
        print("  FAIL the reader reports %s as a NO-VERDICT value - the same value a green job, an "
              "unread log and an unparsed log get. A count decomposed by this verdict is "
              "structurally zero, at every window." % g)
collapsed = {r: sorted(gs) for r, gs in byreader.items() if len(gs) > 1}
for r, gs in sorted(collapsed.items()):
    bad = True
    print("  FAIL the reader collapses %s onto the single value %r" % (" and ".join(gs), r))
if bad:
    raise SystemExit(1)
print("  ok   every generator verdict is reported by the reader as its own value")
PYEOF
  python3 "$pyf"
  local rc=$?
  rm -f "$pyf"
  return $rc
}

# ---------------------------------------------------------------------------
# WINDOW PRECONDITION
# ---------------------------------------------------------------------------
window_report() {
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local t3 t4
  t3="$(git show -s --format=%cI "$V3_SHA" 2>/dev/null)"
  t4="$(git show -s --format=%cI "$V4_SHA" 2>/dev/null)"
  if [ -z "$t3" ] || [ -z "$t4" ]; then
    echo "  REFUSE: one of the boundary commits is not in this checkout ($V3_SHA / $V4_SHA)" >&2
    return 2
  fi
  NOW="$now" T3="$t3" T4="$t4" S3="$V3_SHA" S4="$V4_SHA" python3 - <<'PY'
import datetime, os, sys
def p(s): return datetime.datetime.fromisoformat(s).astimezone(datetime.timezone.utc)
now, t3, t4 = p(os.environ["NOW"].replace("Z","+00:00")), p(os.environ["T3"]), p(os.environ["T4"])
print("    clock (date -u)            %s" % now.isoformat())
print("    %s  #16265  %s" % (os.environ["S3"][:9], t3.isoformat()))
print("    %s  #16572  %s   <- SECOND intervention, inside the nominal window" % (os.environ["S4"][:9], t4.isoformat()))
print()
print("    W1 BEFORE   3 full UTC days ending before %s" % t3.isoformat())
between = t4 - t3
print("    W2 BETWEEN  %s .. %s  = %s" % (t3.isoformat(), t4.isoformat(), between))
print("    W3 AFTER    full UTC days beginning >24h after %s (the marker-transition window)" % t4.isoformat())
print()
ok = True
if between < datetime.timedelta(days=3):
    print("  FAIL W2 spans %s — it cannot be 3 clean days, and it lies wholly inside the" % between)
    print("       ~24h window in which main's logs carry no MAIN-FAILED-STEP marker. Report it")
    print("       UNMEASURED; folding it into either neighbour attributes two changes to one.")
    ok = False
else:
    print("  ok   W2 spans %s — long enough to stand alone" % between)
elapsed = now - (t4 + datetime.timedelta(days=1))
if elapsed >= datetime.timedelta(days=3):
    print("  ok   W3 has %d full days available past the transition window — 3 clean days EXIST" % elapsed.days)
else:
    earliest = t4 + datetime.timedelta(days=4)
    print("  FAIL W3 has only %s past the transition window; earliest 3-clean-day reading: %s"
          % (elapsed, earliest.date().isoformat()))
    ok = False
raise SystemExit(0 if ok else 1)
PY
}

# ---------------------------------------------------------------------------
# SELFTEST — fixtures only. No network, no clock, no live repo state.
# Three arms, and the third is the reason the first two mean anything.
# ---------------------------------------------------------------------------
selftest() {
  local pass=0 fail=0 out rc

  # A1 — THE DETECTOR REDS when the reader is two-valued (today's ci-measure.sh).
  out=$(printf 'INHERITED-FROM-MAIN\tINHERITED-FROM-MAIN\nOWNERSHIP-UNDETERMINED\tNONE\nFAIL\tNONE\n' | judge_mapping 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'collapses'; then
    pass=$((pass+1)); echo "  ok   a1 a two-valued reader REDS (rc 1) and NAMES the collapsed verdicts"
  else
    fail=$((fail+1)); echo "  FAIL a1 rc=$rc — the detector did not red on the exact shape it exists to catch: $out"
  fi

  # A2 — THE DETECTOR IS QUIET when the reader learns the third verdict. This is
  # the arm that proves a1 is a finding about the READER and not a script that
  # reds on everything it is shown.
  out=$(printf 'INHERITED-FROM-MAIN\tINHERITED-FROM-MAIN\nOWNERSHIP-UNDETERMINED\tOWNERSHIP-UNDETERMINED\nFAIL\tFAIL\n' | judge_mapping 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'its own value'; then
    pass=$((pass+1)); echo "  ok   a2 a three-valued reader is QUIET (rc 0) — the check clears itself when ci-measure is fixed"
  else
    fail=$((fail+1)); echo "  FAIL a2 rc=$rc — the check would still red after the fix landed, which makes it unactionable: $out"
  fi

  # A3 — THE CONTROL. A generator that says one thing for every input makes a1's
  # question unanswerable: with one verdict there is nothing to collapse, and a
  # "no collapse" would be a green with no subject. The detector must REFUSE
  # (rc 2), not pass and not red.
  out=$(printf 'FAIL\tNONE\nFAIL\tNONE\nFAIL\tNONE\n' | judge_mapping 2>&1); rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSE'; then
    pass=$((pass+1)); echo "  ok   a3 CONTROL: a single-verdict generator REFUSES (rc 2) instead of printing a vacuous pass"
  else
    fail=$((fail+1)); echo "  FAIL a3 rc=$rc — a probe that discriminates nothing would report 'no collapse' as a finding: $out"
  fi

  # A4 — THE EXTRACTOR sees the real function, and an empty extraction is rc 2.
  # An empty reader would make every verdict read as '' — a total collapse this
  # script would happily report as a finding about ci-measure.sh.
  if extract_reader "$CI_MEASURE" | grep -q '^breaker_verdict()'; then
    pass=$((pass+1)); echo "  ok   a4 breaker_verdict() is EXTRACTED from $(basename "$CI_MEASURE"), not copied — it tracks the real reader"
  else
    fail=$((fail+1)); echo "  FAIL a4 breaker_verdict() not found in $CI_MEASURE — the reader under test would be empty"
  fi
  out=$(extract_reader /dev/null 2>&1); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    pass=$((pass+1)); echo "  ok   a5 an extraction that finds nothing does not silently yield an all-collapsing reader"
  else
    fail=$((fail+1)); echo "  FAIL a5 extract_reader returned content for an empty file"
  fi

  # A6 — a reader that is INJECTIVE but reports a verdict as its no-verdict value
  # must still FAIL. Distinctness is not identification: 'NONE' is the value a
  # green job gets, so counting UNDETERMINED off it counts nothing. This is the
  # arm that catches the exact green-with-no-subject this check printed on its
  # first live run, when the rule was 'no two verdicts share a value'.
  out=$(printf 'INHERITED-FROM-MAIN\tINHERITED-FROM-MAIN\nOWNERSHIP-UNDETERMINED\tNONE\n' | judge_mapping 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'NO-VERDICT value'; then
    pass=$((pass+1)); echo "  ok   a6 an INJECTIVE reader that reports a verdict as NONE still REDS — distinctness is not identification"
  else
    fail=$((fail+1)); echo "  FAIL a6 rc=$rc — a verdict swallowed by the no-verdict bucket would pass as decomposable: $out"
  fi

  echo "SELFTEST: $pass passed, $fail failed."
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
main() {
  case "${1:---report}" in
    --selftest) selftest; exit $? ;;
    --report|"") : ;;
    *) sed -n '2,40p' "$0"; exit 2 ;;
  esac

  local src; src="$(extract_reader "$CI_MEASURE")" || exit 2
  [ -n "$src" ] || { echo "breaker-measure-precondition: breaker_verdict() not found in $CI_MEASURE" >&2; exit 2; }
  eval "$src"

  echo "BREAKER MEASUREMENT PRECONDITIONS — task-33682262f429d104"
  echo
  echo "1. THE WINDOW"
  window_report; local wrc=$?
  echo
  echo "2. THE INSTRUMENT ($(basename "$CI_MEASURE") breaker_verdict vs $(basename "$BREAKER"))"
  [ -r "$BREAKER" ] || { echo "  REFUSE: $BREAKER not readable" >&2; exit 2; }
  probe_reader "$BREAKER" | judge_mapping; local irc=$?
  echo
  if [ "$wrc" -eq 2 ] || [ "$irc" -eq 2 ]; then
    echo "VERDICT: CANNOT MEASURE — this check could not run (see the REFUSE line above)."; exit 2
  fi
  if [ "$wrc" -eq 0 ] && [ "$irc" -eq 0 ]; then
    echo "VERDICT: both preconditions hold — the verdict-decomposed measurement can be taken."; exit 0
  fi
  echo "VERDICT: NOT YET MEASURABLE. Window precondition rc=$wrc, instrument precondition rc=$irc."
  echo "         A decomposed table produced now would be arithmetically right and tell the wrong story."
  exit 1
}
main "$@"
