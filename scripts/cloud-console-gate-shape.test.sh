#!/usr/bin/env bash
#
# cloud-console-gate-shape.test.sh — the shape ratchet for the two REQUIRED
# aggregators that had none of their own: `Cloud gate` (.github/workflows/
# cloud.yml) and `Console gate` (.github/workflows/console-harness.yml),
# measured against `Elixir gate` (.github/workflows/elixir.yml) as the
# reference implementation. Modelled on scripts/security-gate-shape.test.sh,
# whose emitter/mutant idiom it reuses deliberately.
#
# ── WHAT THE FILING ASKED FOR, AND WHY THIS FILE DOES NOT DO IT ────────────
#
# cch-w11-bl-aggregator-decide-shape-ratchet was filed on 2026-07-31 on a
# measurement (D138) that the three `decide()` bodies were BYTE-IDENTICAL —
# "three-way diff exit 0, 32 lines each" — and asked for a ratchet pinning
# that identity. MEASURED ON THIS TREE, that premise is dead:
#
#   decide() body            elixir.yml   cloud.yml   console-harness.yml
#   lines (raw)                      81          44                    98
#   lines (comments stripped)        56          42                    78
#
# The divergence is not rot, it is two DELIBERATE, documented improvements
# that landed after the filing:
#
#   * elixir.yml SPLIT `cancelled)` out of the `failure)` arm (charter D57 /
#     D102) so a superseded head reads "CANCELLED … push a fresh head sha"
#     instead of "failure". cloud.yml and console-harness.yml still fold the
#     two into `failure | cancelled)`.
#   * console-harness.yml's `decide` grew a FOURTH positional argument, the
#     per-job `verdict` channel (OK / REFUSED / MEASURED_DEFECT), because its
#     instruments can refuse to measure. elixir and cloud have no such channel.
#
# A byte-identity ratchet would therefore have to be RED on the shipped tree,
# and the only way to green it would be to REVERT both improvements. Pinning
# text identity across three files that are each allowed to get better is a
# churn machine, not a ratchet.
#
# So this harness pins the invariant the filing's own Purpose paragraph was
# actually reaching for — the one D138 MEASURED rather than the one it
# described: "executing both over the full 6-results-by-4-gate-values matrix
# gives identical verdicts — exactly 5 PASS cells". That is BEHAVIOURAL
# equivalence on the shared decision surface, and it survives a workflow
# improving its prose, its annotations, or its extra channels. CASE 4 below
# drives all three real `decide()` bodies over that whole matrix and demands
# one identical grid; CASE 3 pins the case-ARM POLARITY map so a text change
# that adds or re-signs an arm is named even where the matrix cannot reach it.
#
# ── WHAT WAS ALREADY COVERED, AND IS NOT RE-LITIGATED HERE ─────────────────
#
# The filing also said only security.yml has a committed shape ratchet. Also
# false: scripts/cloud-path-escape-check.test.sh and
# scripts/console-path-escape-check.test.sh already assert, per file,
# `agg_matrix=False`, `agg_if=always()`, `agg_name`, `coe_jobs=""`,
# `coe_in_needs=""`, `blocking_not_in_needs=""` and `needs_without_decide=""`.
# Those facts are re-derived here anyway — this file must be readable alone,
# and a cross-file harness that trusted a sibling's silence would be exactly
# the "reasoning from an instrument two commands from the source" failure —
# but they are NOT the new content. The new content is:
#
#   1. gate_if_mismatch — every `decide` GATE ARGUMENT is resolved back to the
#      dispatcher outputs it depends on and compared against that job's actual
#      `if:`. Reaching `needs` (the siblings' `needs_without_decide`) proves a
#      job is judged; it does NOT prove it is judged against ITS OWN gate. A
#      job gated on `console` but decided against `${O_SOMETHING_ELSE}` skips
#      legitimately in a world the aggregator thinks is live, or — worse —
#      is forgiven a skip in a world where it should have run.
#   2. The three-way behavioural equivalence + arm-polarity map (above).
#   3. Case 2 — the required-context NAME is unique repo-wide.
#      Branch protection keys on the name, not on workflow+job: a second job
#      anywhere called "Cloud gate" makes the required context ambiguous.
#   4. The gate='' (EMPTY STRING) skip shape, asserted EXPLICITLY. The filing
#      is right about this one and it is the subtlest cell in the grid: the
#      gated jobs need only `changes`, and a FAILED dispatcher yields an EMPTY
#      output, never 'true'. So `skipped + gate=true` is close to unreachable
#      while `skipped + gate=''` is the shape that actually happens, and a
#      `[ "$gate" != "false" ]` softened to `[ -n "$gate" ] && …` would pass
#      every gate=true probe and green the real one.
#
# A harness with only green cases is the defect, not the proof, so case 5
# plants a mutant for every assertion and requires it to FIRE.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"
WFDIR="$REAL_ROOT/.github/workflows"
REF_WF="$WFDIR/elixir.yml"
REF_AGG="elixir-gate"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "  ok   — $1"
}
no() {
  fail=$((fail + 1))
  echo "  FAIL — $1" >&2
}

# charter D37: never `printf … | grep -q`. Under `set -o pipefail` on BSD grep
# the writer is SIGPIPE'd the instant grep matches, pipefail promotes 141 over
# grep's success, and a match reads as a miss. A here-string has no writer.
has() { grep -q -- "$2" <<<"$1"; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloud-console-gate-shape.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

echo "cloud-console-gate-shape.test.sh"
echo

for f in "$WFDIR/cloud.yml" "$WFDIR/console-harness.yml" "$REF_WF"; do
  if [ ! -f "$f" ]; then
    echo "  FAIL — $f does not exist" >&2
    exit 1
  fi
done

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "  FAIL — python3 with PyYAML is required to read the workflows structurally." >&2
  echo "         Refusing to fall back to regex: a regex reader silently agrees with" >&2
  echo "         every shape, which is the failure mode this ratchet exists to remove." >&2
  exit 1
fi

# ── the emitter ────────────────────────────────────────────────────────────
# A FILE, not an inline heredoc, so the mutation proofs in case 5 run the very
# same code over deliberately-broken copies. A detector never pointed at a
# broken input has not been shown to detect anything.
EMIT="$TMPROOT/emit-gate-facts.py"
cat >"$EMIT" <<'PY'
import hashlib
import re
import sys

import yaml

WF, AGG, OUT = sys.argv[1], sys.argv[2], sys.argv[3]

wf = yaml.safe_load(open(WF))
jobs = wf["jobs"]
agg = jobs.get(AGG, {})
out = open(OUT, "w")


def emit(k, v):
    out.write(f"{k}={v}\n")


needs = list(agg.get("needs", []))
step = next((s for s in agg.get("steps", []) if "run" in s), {})
run = step.get("run", "")
env = {k: str(v) for k, v in (step.get("env") or {}).items()}

emit("agg_present", bool(agg))
emit("agg_matrix", "strategy" in agg and "matrix" in agg.get("strategy", {}))
emit("agg_if", str(agg.get("if")).strip())
emit("agg_name", agg.get("name"))
emit("agg_needs", ",".join(needs))
emit("needs_count", len(needs))

# DERIVED, never hardcoded. A continue-on-error job that exits 1 CONCLUDES
# FAILURE and renders a red check run, but `needs.<job>.result` reads
# `success` — the red is destroyed before the aggregator's shell starts, so no
# rewrite of decide() can recover it. Neither of these two workflows has any
# today, and the assertion is that it stays that way.
coe = [n for n, j in jobs.items() if j.get("continue-on-error") is True]
emit("coe_jobs", ",".join(sorted(coe)))
emit("coe_in_needs", ",".join(sorted(set(coe) & set(needs))))

# THE POST-VERDICT CATEGORY. Exactly one shape of blocking job legitimately
# cannot live in `needs`: a reporter that runs AFTER the aggregator concluded,
# to carry main's own red to a human. Wiring it in is not a trade-off, it is a
# CYCLE (<agg> -> reporter -> <agg>) and GitHub refuses to load the workflow.
# A PREDICATE, not a skip list — a named exemption goes stale the moment a
# second reporter is added, and would also exempt a job that merely borrowed
# the name. Three clauses, each independently provable (case 5):
#   (1) needs == [AGG] EXACTLY — the cycle is real, not a wiring decision
#       somebody declined to make;
#   (2) its `if:` starts with an ANCHORED failure(). The loose \bfailure\(\)
#       admits `success() || failure()` — a job that runs on EVERY GREEN
#       wearing post-verdict clothes;
#   (3) it is NOT continue-on-error, so it keeps its own exit-1. A MUTED
#       reporter cannot report its own non-delivery.
POST_VERDICT_IF = re.compile(r"^failure\(\)(\s|&|$)")


def post_verdict_shape(j):
    return (list(j.get("needs") or []) == [AGG]
            and bool(POST_VERDICT_IF.match(str(j.get("if", "")).strip())))


post_verdict = {n for n, j in jobs.items()
                if post_verdict_shape(j) and j.get("continue-on-error") is not True}
post_verdict_muted = {n for n, j in jobs.items()
                      if post_verdict_shape(j) and j.get("continue-on-error") is True}
emit("post_verdict_jobs", ",".join(sorted(post_verdict)))
emit("post_verdict_muted", ",".join(sorted(post_verdict_muted)))

# THE NEEDS-SET COVERS EVERY JOB IN THE FILE. A blocking job the aggregator was
# never told about is a job it cannot judge: it greens while that job reds.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != AGG}
emit("blocking_count", len(blocking))
emit("blocking_not_in_needs",
     ",".join(sorted(blocking - set(needs) - post_verdict)))

# Reaching `needs` alone changes nothing: `needs.<job>.result` is consulted
# only if it is bound to a step env var AND that var is passed to `decide`.
# Walk the chain per job — needs entry -> env var bound to needs.<job>.result
# -> decide's SECOND positional argument. The second argument, never the first:
# the first is a human label that deliberately does not match the job name.
var_for = {}
for var, expr in env.items():
    m = re.search(r"needs\.([A-Za-z0-9_.-]+)\.result", expr)
    if m:
        var_for[m.group(1)] = var

DECIDE_CALL = re.compile(
    r'^\s*decide\s+"([^"]*)"\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"\s+"([^"]*)"',
    re.M)
calls = DECIDE_CALL.findall(run)
gate_for_var = {var: gate for _label, var, gate in calls}
consumed = set(gate_for_var)
emit("needs_without_decide",
     ",".join(sorted(j for j in needs if var_for.get(j) not in consumed)))
emit("needs_results_count", len(var_for))
emit("decide_consumes_count", len(consumed))

# ── THE NEW ASSERTION: every decide GATE ARGUMENT matches that job's `if:` ──
#
# Resolve a gate argument down to the set of DISPATCHER OUTPUT KEYS it depends
# on, then compare that set against the keys the job's own `if:` reads.
#   * "NEVER"        -> {} ; the job must carry NO `if:` at all (unfiltered).
#   * "${O_X}"       -> the single key in env["O_X"] = needs.changes.outputs.K.
#   * "${derived}"   -> a shell local computed in the step body (cloud.yml's
#                      `census_gate` is a CONJUNCTION of two outputs). Resolve
#                      through the `case` whose body assigns it, recursively.
# Anything that does not resolve is a MISMATCH, never a pass: an unresolvable
# gate is precisely the state where nobody can say what it gates on.
OUTPUT_KEY = re.compile(r"needs\.changes\.outputs\.([A-Za-z0-9_-]+)")
VARREF = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
CASE_BLOCK = re.compile(r"^[ \t]*case[ \t]+(.+?)[ \t]+in[ \t]*$(.*?)^[ \t]*esac",
                        re.S | re.M)


def gate_keys(gate, seen=()):
    g = gate.strip()
    if g == "NEVER":
        return frozenset()
    m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}?", g)
    if not m:
        return None
    var = m.group(1)
    if var in seen:                       # a cycle resolves to nothing knowable
        return None
    if var in env:
        ks = OUTPUT_KEY.findall(env[var])
        return frozenset(ks) if ks else None
    # derived: the variable is assigned somewhere in the step body. NOT
    # anchored to the start of a line — cloud.yml assigns `census_gate` INSIDE
    # a case arm (`false:*)    census_gate=false ;;`), and a `^[ \t]*` anchor
    # read that as "never assigned" and returned None for a gate that resolves
    # perfectly well.
    if not re.search(r"(?:^|[;\s])" + re.escape(var) + r"=", run, re.M):
        return None
    keys = set()
    resolved = False
    for subject, body in CASE_BLOCK.findall(run):
        if not re.search(r"\b" + re.escape(var) + r"=", body):
            continue
        resolved = True
        for v in VARREF.findall(subject):
            k = gate_keys("${%s}" % v, seen + (var,))
            if k is None:
                return None
            keys |= k
    return frozenset(keys) if resolved else None


def if_keys(j):
    return frozenset(OUTPUT_KEY.findall(str(j.get("if") or "")))


mismatch = []
for job in needs:
    var = var_for.get(job)
    if var is None or var not in gate_for_var:
        continue                          # already named by needs_without_decide
    j = jobs.get(job, {})
    gk = gate_keys(gate_for_var[var])
    ik = if_keys(j)
    if gk is None or gk != ik:
        mismatch.append(job)
        continue
    # A single-key gate must also be read with the EXACT comparison the
    # dispatcher emits. `!= 'false'` or a bare truthiness test would run the
    # job in worlds the gate says are dead, and `decide` only forgives a skip
    # against the literal string 'false'.
    if len(gk) == 1:
        key = next(iter(gk))
        if str(j.get("if") or "").strip() != "needs.changes.outputs.%s == 'true'" % key:
            mismatch.append(job)
    elif len(gk) == 0 and str(j.get("if") or "").strip():
        mismatch.append(job)
emit("gate_if_mismatch", ",".join(sorted(set(mismatch))))
emit("gate_resolved_count",
     sum(1 for job in needs
         if var_for.get(job) in gate_for_var
         and gate_keys(gate_for_var[var_for[job]]) is not None))

# ── decide()'s shape: the case-arm POLARITY map ────────────────────────────
# The result-space each arm covers, and whether that arm is RED (`bad=1`).
# Text-independent: comments, annotation prose and extra channels do not move
# it, but adding an arm, deleting one, or re-signing one does.
dm = re.search(r"^decide\(\)\s*\{(.*?)^\}", run, re.S | re.M)
body = dm.group(1) if dm else ""
emit("decide_present", bool(dm))
emit("decide_sha_raw", hashlib.sha1(
    (dm.group(0) if dm else "").encode()).hexdigest()[:12])
# NESTING-AWARE, by line and by depth. A regex split on `;;` cannot do this:
# console-harness.yml's `skipped`… no — its FAILURE arm contains a whole nested
# `case "$verdict" in`, whose arms (OK / REFUSED / MEASURED_DEFECT / *) a naive
# split hoists to the top level and whose `*)` then reports `ok`, inverting the
# polarity of the catch-all. Only the OUTER `case "$result" in` is read here.
arms = []
depth = 0
started = False
cur = None
cur_red = False
for ln in body.splitlines():
    t = ln.strip()
    if not started:
        if re.match(r'^case\s+"\$result"\s+in$', t):
            started, depth = True, 1
        continue
    if re.match(r"^case\b", t):
        depth += 1
        continue
    if t == "esac":
        depth -= 1
        if depth == 0:
            break
        continue
    if depth != 1:
        continue
    if t == ";;":
        if cur is not None:
            arms.append("%s:%s" % (cur, "RED" if cur_red else "ok"))
            cur, cur_red = None, False
        continue
    m = re.match(r"^([^\n;]*?)\)$", t)
    if m and cur is None:
        cur, cur_red = re.sub(r"\s+", "", m.group(1)), False
        continue
    if t == "bad=1":
        cur_red = True
if cur is not None:
    arms.append("%s:%s" % (cur, "RED" if cur_red else "ok"))
emit("decide_arms", " ".join(arms))
out.close()
PY

# ── the repo-wide name scan ────────────────────────────────────────────────
# Branch protection keys a required context on the NAME. Two jobs anywhere in
# .github/workflows/ carrying the same name make the required context
# ambiguous: the wrong one can satisfy it, or neither can.
NAMESCAN="$TMPROOT/scan-job-names.py"
cat >"$NAMESCAN" <<'PY'
import collections
import glob
import sys

import yaml

c = collections.Counter()
for p in sorted(glob.glob(sys.argv[1] + "/*.yml")):
    try:
        d = yaml.safe_load(open(p))
    except Exception:
        continue
    for _n, j in (d.get("jobs") or {}).items():
        if isinstance(j, dict) and j.get("name"):
            c[str(j["name"])] += 1
print(c[sys.argv[2]])
PY

facts_for() { # <label> <workflow> <aggjob> -> writes $TMPROOT/<label>.facts
  python3 "$EMIT" "$2" "$3" "$TMPROOT/$1.facts"
}

facts_for cloud "$WFDIR/cloud.yml" cloud-gate
facts_for console "$WFDIR/console-harness.yml" console-gate
facts_for elixir "$REF_WF" "$REF_AGG"

fact() { sed -n "s|^$2=||p" "$TMPROOT/$1.facts"; }
assert_fact() {
  local got
  got="$(fact "$1" "$2")"
  if [ "$got" = "$3" ]; then ok "[$1] $2 = $3"; else no "[$1] $2 = '$got', wanted '$3'"; fi
}
# A lower bound, never an equality: pinning the exact roster would red this
# harness the day a legitimate job is added, which is churn, not safety. The
# bound only has to exclude ZERO — what a broken parser returns.
assert_fact_min() {
  local got
  got="$(fact "$1" "$2")"
  case "$got" in
    '' | *[!0-9]*) no "[$1] $2 = '$got' — not a number, the emitter is broken" ;;
    *)
      if [ "$got" -ge "$3" ]; then ok "[$1] $2 = $got (>= $3)"; else
        no "[$1] $2 = $got, wanted >= $3 — the detector is neutered, not the tree clean"
      fi
      ;;
  esac
}

echo "case 1: both aggregators carry the required shape"
for s in cloud console; do
  assert_fact "$s" agg_present True
  assert_fact "$s" agg_matrix False
  assert_fact "$s" agg_if "always()"
  assert_fact "$s" coe_jobs ""
  assert_fact "$s" coe_in_needs ""
  assert_fact "$s" blocking_not_in_needs ""
  assert_fact "$s" post_verdict_jobs "report-main-failure"
  assert_fact "$s" post_verdict_muted ""
  assert_fact "$s" needs_without_decide ""
  # THE NEW ONE: every decide gate argument matches its job's actual `if:`.
  assert_fact "$s" gate_if_mismatch ""
  assert_fact "$s" decide_present True
  assert_fact_min "$s" needs_count 5
  assert_fact_min "$s" needs_results_count 5
  assert_fact_min "$s" decide_consumes_count 5
  assert_fact_min "$s" blocking_count 5
  assert_fact_min "$s" gate_resolved_count 5
done
assert_fact cloud agg_name "Cloud gate"
assert_fact console agg_name "Console gate"
echo "  info — Cloud gate needs:   $(fact cloud agg_needs)"
echo "  info — Console gate needs: $(fact console agg_needs)"
echo

echo "case 2: the required-context NAME is unique repo-wide"
for n in "Cloud gate" "Console gate"; do
  got="$(python3 "$NAMESCAN" "$WFDIR" "$n")"
  if [ "$got" = "1" ]; then ok "exactly one job named '$n' in .github/workflows/"; else
    no "'$n' names $got jobs — a required context must be unambiguous"
  fi
done
echo

echo "case 3: decide() arm polarity is identical across the three aggregators"
# TEXT-INDEPENDENT, by construction. elixir.yml splits `cancelled)` into its
# own arm; cloud and console fold it into `failure | cancelled)`. Both spellings
# cover the same result-space with the same RED polarity, which is why the map
# is normalised to (covered result -> polarity) before comparison.
norm_arms() { # <label> -> "result:POLARITY" lines, sorted
  local a
  a="$(fact "$1" decide_arms)"
  tr ' ' '\n' <<<"$a" | awk -F: 'NF==2{n=split($1,ps,"|"); for(i=1;i<=n;i++){p=ps[i]; gsub(/^\047|\047$/,"",p); if(p=="")p="<empty>"; print p":"$2}}' | sort
}
REF_ARMS="$(norm_arms elixir)"
awk '{print "    " $0}' <<<"$REF_ARMS"
for s in cloud console; do
  if [ "$(norm_arms "$s")" = "$REF_ARMS" ]; then
    ok "[$s] decide() covers the same results with the same polarity as elixir.yml"
  else
    no "[$s] decide() arm map diverges from elixir.yml:
$(diff <(echo "$REF_ARMS") <(norm_arms "$s") || true)"
  fi
done
# The map must be POPULATED. An empty map compares equal to an empty map, so a
# regex that stopped matching would report three serene agreements forever.
arm_lines="$(wc -l <<<"$REF_ARMS" | tr -d ' ')"
if [ "$arm_lines" -ge 5 ]; then ok "the arm map is populated ($arm_lines results covered)"; else
  no "the arm map covers $arm_lines results — the extractor is broken, not the tree uniform"
fi
echo "  info — decide() raw sha: elixir=$(fact elixir decide_sha_raw) cloud=$(fact cloud decide_sha_raw) console=$(fact console decide_sha_raw)"
echo "  info — the three bodies are NOT byte-identical and are not required to be; see this file's header."
echo

# ── case 4: the matrix, EXECUTED ───────────────────────────────────────────
echo "case 4: all three decide() bodies are driven over 6 results x 4 gate values"
DRIVER="$TMPROOT/build-driver.py"
cat >"$DRIVER" <<'PY'
import re
import sys

import yaml

WF, AGG, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(WF))
run = next(s for s in wf["jobs"][AGG]["steps"] if "run" in s)["run"]
m = re.search(r"^decide\(\)\s*\{.*?^\}", run, re.S | re.M)
if not m:
    sys.exit("no decide() in %s / %s" % (WF, AGG))
# The counters and accumulators decide() touches, so it can run OUTSIDE the
# aggregator's step body without `set -u` killing it for the wrong reason.
open(OUT, "w").write(
    "set -u\n"
    "bad=0\nreds=\"\"\ndispatched=0\nnot_dispatched=\"\"\n"
    "refusals=\"\"\nmeasured=\"\"\n"
    + m.group(0) + "\n"
    'decide "probe" "${T_RESULT}" "${T_GATE}" >/dev/null 2>&1\n'
    "exit \"$bad\"\n")
PY

RESULTS=(success skipped failure cancelled "" neutral)
GATES=(true false "" NEVER)

grid_for() { # <label> <workflow> <aggjob> -> prints the verdict grid
  local d="$TMPROOT/$1.driver.sh" r g rc
  python3 "$DRIVER" "$2" "$3" "$d"
  for r in "${RESULTS[@]}"; do
    for g in "${GATES[@]}"; do
      rc=0
      env -i PATH="$PATH" HOME="$HOME" T_RESULT="$r" T_GATE="$g" \
        bash --noprofile --norc "$d" || rc=$?
      printf '%s|%s=%s\n' "${r:-<empty>}" "${g:-<empty>}" \
        "$([ "$rc" -eq 0 ] && echo PASS || echo RED)"
    done
  done
}

# The EXPECTED grid, written out in full rather than computed — a grid derived
# from the same code it judges agrees with itself by construction.
read -r -d '' EXPECTED <<'GRID' || true
success|true=PASS
success|false=PASS
success|<empty>=PASS
success|NEVER=PASS
skipped|true=RED
skipped|false=PASS
skipped|<empty>=RED
skipped|NEVER=RED
failure|true=RED
failure|false=RED
failure|<empty>=RED
failure|NEVER=RED
cancelled|true=RED
cancelled|false=RED
cancelled|<empty>=RED
cancelled|NEVER=RED
<empty>|true=RED
<empty>|false=RED
<empty>|<empty>=RED
<empty>|NEVER=RED
neutral|true=RED
neutral|false=RED
neutral|<empty>=RED
neutral|NEVER=RED
GRID

CLOUD_GRID="$(grid_for cloud "$WFDIR/cloud.yml" cloud-gate)"
CONSOLE_GRID="$(grid_for console "$WFDIR/console-harness.yml" console-gate)"
ELIXIR_GRID="$(grid_for elixir "$REF_WF" "$REF_AGG")"

for pair in "cloud:$CLOUD_GRID" "console:$CONSOLE_GRID" "elixir:$ELIXIR_GRID"; do
  label="${pair%%:*}"
  got="${pair#*:}"
  if [ "$got" = "$EXPECTED" ]; then
    ok "[$label] the 24-cell grid matches the expected verdicts exactly"
  else
    no "[$label] grid diverges:
$(diff <(echo "$EXPECTED") <(echo "$got") || true)"
  fi
done
npass="$(grep -c '=PASS$' <<<"$CLOUD_GRID" || true)"
if [ "$npass" -eq 5 ]; then ok "exactly 5 PASS cells (D138's own measurement)"; else
  no "$npass PASS cells, wanted 5"
fi
echo

echo "case 4b: the gate='' (EMPTY STRING) skip is asserted explicitly"
# THE REACHABILITY CORRECTION the filing is right about. The gated jobs need
# only `changes`; a FAILED dispatcher yields an EMPTY output, never 'true'. So
# `skipped + gate=true` is close to unreachable in these graphs while
# `skipped + gate=''` is the shape that ACTUALLY happens — and a gate check
# softened from `= "false"` to a truthiness test passes every gate=true probe
# and greens the real one. Asserted per workflow, not inferred from the grid.
for pair in "cloud:$CLOUD_GRID" "console:$CONSOLE_GRID" "elixir:$ELIXIR_GRID"; do
  label="${pair%%:*}"
  got="${pair#*:}"
  if has "$got" 'skipped|<empty>=RED'; then
    ok "[$label] skipped against an EMPTY gate is RED"
  else
    no "[$label] skipped against an EMPTY gate is not RED"
  fi
  if has "$got" 'skipped|false=PASS'; then
    ok "[$label] skipped against gate='false' is the ONE legitimate skip"
  else
    no "[$label] skipped against gate='false' is not a pass"
  fi
done
echo

# ── case 5: the mutants — every assertion above must be able to FIRE ───────
echo "case 5: each assertion is proven able to fail"
MUT="$TMPROOT/mutate.py"
cat >"$MUT" <<'PY'
import re
import sys

import yaml

SRC, DST, AGG, MODE = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
wf = yaml.safe_load(open(SRC))
jobs = wf["jobs"]
agg = jobs[AGG]
step = next(s for s in agg["steps"] if "run" in s)
assert MODE in ("clean", "soften-skip", "extra-job", "gate-swap", "gate-loosen",
                "coe", "matrix", "drop-need"), MODE

if MODE == "soften-skip":
    # THE DIRECTION THE FILING NAMES FIRST: soften the skipped arm so any skip
    # is forgiven. The grid must stop matching.
    body = step["run"]
    new = re.sub(
        r'(^\s*skipped\)\s*\n)(\s*)if \[ "\$gate" = "false" \]; then',
        r'\1\2if [ "$gate" != "false" ] || true; then',
        body, count=1, flags=re.M)
    assert new != body, "the skipped arm was not found to soften"
    step["run"] = new
elif MODE == "extra-job":
    # THE SECOND DIRECTION: a blocking job present in the file and absent from
    # the aggregator's needs. It reds while the gate greens.
    jobs["a11y-ceiling"] = {"runs-on": "ubuntu-latest", "steps": [{"run": "exit 1"}]}
elif MODE == "gate-swap":
    # A job decided against SOMEBODY ELSE'S gate: its `if:` reads one
    # dispatcher output, `decide` is handed another.
    changes_out = list(jobs["changes"].get("outputs", {}))
    victim = next(n for n in agg["needs"]
                  if n not in ("changes",) and jobs[n].get("if"))
    other = next(k for k in changes_out
                 if "needs.changes.outputs.%s" % k not in str(jobs[victim]["if"]))
    jobs[victim]["if"] = "needs.changes.outputs.%s == 'true'" % other
elif MODE == "gate-loosen":
    # Same key, LOOSER comparison: the job now runs in every world the gate did
    # not explicitly call dead, including the empty one.
    victim = next(n for n in agg["needs"]
                  if n not in ("changes",) and jobs[n].get("if"))
    jobs[victim]["if"] = str(jobs[victim]["if"]).replace("== 'true'", "!= 'false'")
elif MODE == "coe":
    victim = next(n for n in agg["needs"] if n != "changes")
    jobs[victim]["continue-on-error"] = True
elif MODE == "matrix":
    agg["strategy"] = {"matrix": {"otp": ["27.0"]}}
elif MODE == "drop-need":
    victim = next(n for n in agg["needs"] if n != "changes")
    agg["needs"] = [n for n in agg["needs"] if n != victim]

yaml.safe_dump(wf, open(DST, "w"))
PY

# mutant <label> <workflow> <aggjob> <mode> <fact> <expected>
mutant() {
  local label="$1" wfp="$2" aggj="$3" mode="$4" key="$5" want="$6"
  local f="$TMPROOT/mut-$label-$mode.yml" ff="$TMPROOT/mut-$label-$mode.facts" got
  # `clean` goes through the SAME load/dump round-trip as the broken copies, so
  # the only variable between them is the mutation itself.
  python3 "$MUT" "$wfp" "$f" "$aggj" "$mode"
  python3 "$EMIT" "$f" "$aggj" "$ff"
  got="$(sed -n "s|^${key}=||p" "$ff")"
  if [ "$got" = "$want" ]; then
    ok "mutation[$label/$mode]: $key = '${got}'"
  else
    no "mutation[$label/$mode]: $key = '${got}', wanted '${want}'"
  fi
}

# mutant_grid <label> <workflow> <aggjob> <mode> — the grid must CHANGE
mutant_grid() {
  local label="$1" wfp="$2" aggj="$3" mode="$4"
  local f="$TMPROOT/mut-$label-$mode.yml" d="$TMPROOT/mut-$label-$mode.sh" r g rc got
  python3 "$MUT" "$wfp" "$f" "$aggj" "$mode"
  python3 "$DRIVER" "$f" "$aggj" "$d"
  got=""
  for r in "${RESULTS[@]}"; do
    for g in "${GATES[@]}"; do
      rc=0
      env -i PATH="$PATH" HOME="$HOME" T_RESULT="$r" T_GATE="$g" \
        bash --noprofile --norc "$d" || rc=$?
      got="${got}${r:-<empty>}|${g:-<empty>}=$([ "$rc" -eq 0 ] && echo PASS || echo RED)"$'\n'
    done
  done
  got="${got%$'\n'}"
  if [ "$mode" = "clean" ]; then
    if [ "$got" = "$EXPECTED" ]; then ok "mutation[$label/clean]: the grid is unchanged by the round-trip"; else
      no "mutation[$label/clean]: the round-trip ALONE moved the grid — the harness is measuring itself"
    fi
    return 0
  fi
  if [ "$got" = "$EXPECTED" ]; then
    no "mutation[$label/$mode]: the grid did NOT move — the softened skip is invisible"
  else
    ok "mutation[$label/$mode]: the grid moved ($(diff <(echo "$EXPECTED") <(echo "$got") | grep -c '^>' || true) cells) — a softened skip is DETECTED"
  fi
}

for pair in "cloud:$WFDIR/cloud.yml:cloud-gate" "console:$WFDIR/console-harness.yml:console-gate"; do
  IFS=: read -r L P A <<<"$pair"
  # the controls: a round-trip alone changes nothing
  mutant "$L" "$P" "$A" clean blocking_not_in_needs ""
  mutant "$L" "$P" "$A" clean gate_if_mismatch ""
  mutant "$L" "$P" "$A" clean coe_jobs ""
  mutant_grid "$L" "$P" "$A" clean
  # DIRECTION 1 (the filing's own words): softening the skipped arm reds it.
  mutant_grid "$L" "$P" "$A" soften-skip
  # DIRECTION 2: a job outside the needs-set reds it.
  mutant "$L" "$P" "$A" extra-job blocking_not_in_needs "a11y-ceiling"
  # …and the three the siblings never had.
  mutant "$L" "$P" "$A" gate-swap   gate_if_mismatch "$( \
    python3 - "$P" "$A" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf["jobs"]
print(next(n for n in jobs[sys.argv[2]]["needs"]
           if n != "changes" and jobs[n].get("if")))
PY
  )"
  mutant "$L" "$P" "$A" gate-loosen gate_if_mismatch "$( \
    python3 - "$P" "$A" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf["jobs"]
print(next(n for n in jobs[sys.argv[2]]["needs"]
           if n != "changes" and jobs[n].get("if")))
PY
  )"
  mutant "$L" "$P" "$A" matrix     agg_matrix "True"
  mutant "$L" "$P" "$A" drop-need  blocking_not_in_needs "$( \
    python3 - "$P" "$A" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(next(n for n in wf["jobs"][sys.argv[2]]["needs"] if n != "changes"))
PY
  )"
  # A continue-on-error job is named by coe_jobs AND, because it is no longer
  # `blocking`, it silently LEAVES the mirror set. Both are pinned so nobody
  # later reads the mirror guard's silence as cover.
  mutant "$L" "$P" "$A" coe coe_jobs "$( \
    python3 - "$P" "$A" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(next(n for n in wf["jobs"][sys.argv[2]]["needs"] if n != "changes"))
PY
  )"
  mutant "$L" "$P" "$A" coe coe_in_needs "$( \
    python3 - "$P" "$A" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(next(n for n in wf["jobs"][sys.argv[2]]["needs"] if n != "changes"))
PY
  )"
done
echo

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
