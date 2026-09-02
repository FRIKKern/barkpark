#!/usr/bin/env bash
#
# cloud-path-escape-check.test.sh — the harness for the Cloud path ratchet AND
# for cloud.yml's own structural invariants.
#
# Honest-gates D26: a harness nobody runs is not a ratchet. This one is executed
# by cloud.yml's `path-escape` job (unfiltered, so it can never go dark) and by
# the slice gate, via `cloud-path-escape-check.sh --selftest`.
#
# The cases that matter are the ones that prove the instruments can FAIL:
#   * an uncovered repo-root read must red                  (case 3)
#   * an uncovered read in an UNTRACKED file must red       (case 4) — the
#     measured vacuous pass this shape was designed around: a prototype
#     enumerating via `git ls-files` printed "OK: every repo-root read is
#     covered" and exited 0 with the mutation fixture sitting untracked on disk
#   * a neutered scanner must red rather than report clean  (case 5)
#   * the aggregator must be makeable red on purpose        (case 9)
#   * the dispatcher must FAIL, never skip, when it cannot tell (case 10)
# A harness with only green cases is the defect, not the proof.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/cloud-path-escape-check.sh"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"

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

# ── honest-gates D37: never read the status of a pipeline into `grep -q` ───
# THE RULE IS ABOUT THE WRITER, NOT ABOUT WHAT IS BEING SEARCHED. Any
# `A | grep -q …` whose exit status you read is unsafe whenever A can still have
# bytes to write: `grep -q` exits the instant it matches, A takes SIGPIPE (141)
# or EPIPE (2) on its next write, and `set -o pipefail` promotes that over
# grep's success — so the `if` takes the ELSE branch for a match that DID occur.
# The same applies to `| head` and `| grep -m N`, which also close early.
#
# A is not only `printf`. `sed … "$f" | grep -q`, `grep … "$f" | grep -q`, and
# `awk … "$f" | grep -q` are pipelines with writers, NOT file matches — the
# earlier wording of this rule ("matches against a FILE were never at risk")
# was read that way and let exactly those three shapes survive; #12754 and
# task-4f3acc2d18a7f047 are the cleanup. Only `grep -q PAT "$f"` with NO pipe
# is a file match.
#
# Nor is it macOS-only: this was first seen on BSD grep, but the failure that
# opened #12754 was GNU grep on Linux CI. It is a scheduling race, so a quiet
# host can pass it a thousand times and a loaded runner still lose it.
#
# Triage note — the direction decides how bad it is. Where a MATCH means "the
# good thing is present", a misread only costs a spurious red. Where a MATCH
# means "the bad thing is present", a misread SILENTLY SKIPS the violation
# report: the check does not fail, it stops being able to fail.
#
# The fixes: a here-string (no writer process at all), or materialise the
# producer's output into a variable first and match that. Use them for EVERY
# match against a captured string.
has()      { grep -q  -- "$2" <<<"$1"; }   # substring/BRE anywhere in $1
has_line() { grep -qx -- "$2" <<<"$1"; }   # a whole line of $1 equals the BRE

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloud-path-escape-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Build a synthetic mini-repo whose cloud/ tree escapes to known repo-root paths.
make_fixture() {
  local root="$1"
  mkdir -p "$root/cloud/lib" "$root/cloud/test/barkpark_cloud" \
    "$root/internal/cli/cloud" "$root/scripts" \
    "$root/js/packages/create-barkpark-app/templates"
  : >"$root/internal/cli/cloud/providers_capabilities.json"
  : >"$root/scripts/async_env_seam_scan.exs"
  : >"$root/js/packages/create-barkpark-app/templates/package.json"
  : >"$root/cloud/docker-compose.yml"
  # Five covered reads — over the floor of 4 so the coverage cases exercise
  # coverage, not the floor.
  cat >"$root/cloud/test/barkpark_cloud/covered_test.exs" <<'EX'
  @a Path.expand("../../../internal/cli/cloud/providers_capabilities.json", __DIR__)
  @b Path.expand("../../../scripts/async_env_seam_scan.exs", __DIR__)
  @c Path.expand("../../../js/packages/create-barkpark-app/templates", __DIR__)
  @d Path.expand("../../../js/packages/create-barkpark-app/templates/package.json", __DIR__)
  @e Path.expand("../../../scripts/cloud-path-escape-check.sh", __DIR__)
  # traversal-attack fixtures: asserted on, never read — must NOT be counted
  @x "../etc/passwd"
  @y "../up"
EX
  cp "$SCRIPT" "$root/scripts/" 2>/dev/null || true
}

echo "cloud-path-escape-check.test.sh"
echo

# ── case 1: the real repo passes, and reports the measured population ───────
echo "case 1: the real repository is clean"
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0 on the real repo"; else no "expected exit 0, got $rc: $out"; fi
if has "$out" "OK: every repo-root read"; then
  ok "prints the OK verdict"
else
  no "missing OK verdict: $out"
fi
# The count is the anti-vacuity signal: a run that says "0 reads" is a broken
# scanner, and this case would notice it even if the floor were removed.
n="$(printf '%s' "$out" | sed -n 's/^cloud-path-escape-check: \([0-9]*\) distinct.*/\1/p')"
if [ "${n:-0}" -ge 6 ]; then
  ok "resolved $n repo-root reads (at least CLOUD_ESCAPE_MIN=6; the floor is a lower bound, not the population)"
else
  no "resolved only ${n:-0} repo-root reads — scanner is under-matching"
fi
if has "$out" "exempt: docker-compose.yml"; then
  ok "the __DIR__-anchored phantom is reported as exempt, not silently dropped"
else
  no "exemption not reported"
fi
echo

# ── case 2: the census carries the reads an eyeballed cloud/** filter misses ─
echo "case 2: the census carries the cross-tree reads"
census="$("$SCRIPT" --list-escapes | cut -f1 | sort -u)"
for want in internal/cli/cloud/providers_capabilities.json \
  scripts/async_env_seam_scan.exs \
  js/packages/create-barkpark-app/templates; do
  if has_line "$census" "$want"; then
    ok "census carries $want"
  else
    no "census MISSES $want"
  fi
done
# api/test/** is the DELIBERATE non-declaration (see CLOUD_PATHS' comment): an
# api-only PR must not spin up the Cloud suite plus Postgres. Pinned here so the
# omission stays a decision rather than becoming an accident.
sets="$("$SCRIPT" --print-set cloud)"
if has_line "$sets" 'api/test/\*\*'; then
  no "api/test/** is declared — that runs the whole Cloud suite on every api-only PR"
else
  ok "api/test/** is deliberately NOT declared"
fi
echo

# ── case 3: an uncovered repo-root read REDS (tracked file) ─────────────────
echo "case 3: an uncovered repo-root read reds (mutation)"
FX="$TMPROOT/tracked"
make_fixture "$FX"
mkdir -p "$FX/nowhere"
: >"$FX/nowhere/secret.json"
cat >"$FX/cloud/test/barkpark_cloud/escaping_test.exs" <<'EX'
  @bad Path.expand("../../../nowhere/secret.json", __DIR__)
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc (non-zero) on an uncovered read"; else no "PASSED with an uncovered read — vacuous"; fi
if has "$out" "UNCOVERED repo-root read: nowhere/secret.json"; then
  ok "names the uncovered path"
else
  no "did not name the uncovered path: $out"
fi
if has "$out" "read from: cloud/test/barkpark_cloud/escaping_test.exs"; then
  ok "names the file that reads it"
else
  no "did not attribute the read: $out"
fi
echo

# ── case 4: THE UNTRACKED CASE — the measured vacuous pass ──────────────────
echo "case 4: an uncovered read in an UNTRACKED file still reds"
FX2="$TMPROOT/untracked"
make_fixture "$FX2"
git -C "$FX2" init -q
git -C "$FX2" add -A >/dev/null 2>&1
git -C "$FX2" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
mkdir -p "$FX2/nowhere"
: >"$FX2/nowhere/secret.json"
cat >"$FX2/cloud/test/barkpark_cloud/untracked_escape_test.exs" <<'EX'
  @bad Path.expand("../../../nowhere/secret.json", __DIR__)
EX
if git -C "$FX2" ls-files --error-unmatch cloud/test/barkpark_cloud/untracked_escape_test.exs >/dev/null 2>&1; then
  no "fixture setup wrong — the mutation file is TRACKED, so this case proves nothing"
else
  ok "fixture is genuinely untracked (git ls-files does not see it)"
fi
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX2" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — the working-tree scan sees untracked code"
else
  no "PASSED on an untracked uncovered read — this is the git ls-files vacuous pass (D31)"
fi
if has "$out" "read from: cloud/test/barkpark_cloud/untracked_escape_test.exs"; then
  ok "attributes the read to the untracked file"
else
  no "did not attribute the untracked read: $out"
fi
echo

# ── case 5: a neutered scanner reds on the floor, never reports clean ───────
echo "case 5: the min-escapes floor catches a neutered scanner"
FX3="$TMPROOT/thin"
mkdir -p "$FX3/cloud/lib" "$FX3/cloud/test" "$FX3/scripts"
: >"$FX3/scripts/async_env_seam_scan.exs"
cat >"$FX3/cloud/test/one_test.exs" <<'EX'
  @a Path.expand("../../scripts/async_env_seam_scan.exs", __DIR__)
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX3" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) when the population collapses below the floor"
else
  no "reported CLEAN with 1 read — a neutered scanner would pass"
fi
if has "$out" "SCANNER is broken, not the repo clean"; then
  ok "says the scanner is broken, not that the repo is clean"
else
  no "wrong diagnosis: $out"
fi
# and the floor is NOT overridable outside the harness
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX3" CLOUD_ESCAPE_MIN=1 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "CLOUD_ESCAPE_MIN in the environment cannot lower the floor"
else
  no "the floor was lowered by an env var — that is a one-line CI bypass"
fi
echo

# ── case 6: --match, the predicate cloud.yml actually dispatches on ─────────
echo "case 6: --match agrees with the declared set"
m() { "$SCRIPT" --match "$2" <<<"$1"; }
check_match() {
  local got
  got="$(m "$1" "$2")"
  if [ "$got" = "$3" ]; then
    ok "$2: '$1' -> $3"
  else
    no "$2: '$1' -> $got, wanted $3"
  fi
}
check_match "cloud/lib/barkpark_cloud/web/router.ex" cloud true
check_match "cloud/test/barkpark_cloud/web/router_test.exs" cloud true
check_match ".github/workflows/cloud.yml" cloud true
check_match "scripts/cloud-path-escape-check.sh" cloud true
check_match "scripts/cloud-path-escape-check.test.sh" cloud true
check_match "internal/cli/cloud/providers_capabilities.json" cloud true
check_match "scripts/async_env_seam_scan.exs" cloud true
# THE VENDORED-TEMPLATE DRIFT TRIPWIRE. It lived in the deleted workflow-level
# `on: paths:` block; losing it silently drops the #963→#969 guard, because
# AppFilesDriftTest only runs when the `test` job runs.
check_match "js/packages/create-barkpark-app/templates/package.json" cloud true
check_match "js/packages/create-barkpark-app/templates" cloud true
# …and the whole point of the shim: these must NOT run the Cloud suite.
check_match "docs/ops/merge-gates.md" cloud false
check_match "README.md" cloud false
check_match "api/lib/barkpark.ex" cloud false
check_match "api/test/barkpark/some_test.exs" cloud false
check_match "web/src/app/page.tsx" cloud false
check_match ".github/workflows/elixir.yml" cloud false
# exact-file entries must not match by prefix
check_match "scripts/async_env_seam_scan.exs.orig" cloud false
check_match ".github/workflows/cloud.yml.bak" cloud false
# every declared glob selects the set it is declared in
while IFS= read -r g; do
  [ -n "$g" ] || continue
  probe="${g%/\*\*}"
  case "$g" in */'**') probe="$probe/probe.txt" ;; esac
  check_match "$probe" cloud true
done <<EOF
$("$SCRIPT" --print-set cloud)
EOF
echo

# ── case 7: a bad set name is an error, not a silent false ──────────────────
echo "case 7: an unknown set name errors"
out="$("$SCRIPT" --match nonsense <<<'cloud/x' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown set"; else no "unknown set returned '$out' instead of failing"; fi
# elixir.yml's set names must not silently work here and select an empty pattern
out="$("$SCRIPT" --match compile <<<'cloud/x' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on elixir's set name"; else no "'compile' returned '$out' instead of failing"; fi
out="$("$SCRIPT" --bogus-flag 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown flag"; else no "unknown flag silently accepted"; fi
echo

# ── case 8: cloud.yml's structural invariants ──────────────────────────────
# These are the ones a reviewer's eye slides over and a required-check spec
# cannot recover from. Asserted mechanically, against the real file.
echo "case 8: cloud.yml structural invariants"
WF="$REAL_ROOT/.github/workflows/cloud.yml"
if [ ! -f "$WF" ]; then
  no "cloud.yml not found at $WF"
else
  # Written to a file, not captured inline: bash 3.2 (macOS, and therefore the
  # local gate) mis-parses a heredoc inside a command substitution.
  #
  # The emitter itself is a FILE rather than an inline heredoc so the mutation
  # proof below can run the very same code over deliberately-broken copies of
  # cloud.yml. A detector that is never pointed at a broken input has not been
  # shown to detect anything.
  FACTS="$TMPROOT/cloud-yml-facts.txt"
  EMIT="$TMPROOT/emit-cloud-yml-facts.py"
  cat >"$EMIT" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
out = open(sys.argv[2], "w")
on = wf.get(True, wf.get("on"))            # PyYAML parses bare `on:` as True
jobs = wf["jobs"]
def emit(k, v): out.write(f"{k}={v}\n")
# D18: a workflow-level paths filter emits NO check run, so a required name
# pointing here would report "expected" forever and deadlock the merge.
emit("workflow_paths", any(
    isinstance(v, dict) and ("paths" in v or "paths-ignore" in v)
    for v in (on or {}).values()))
agg = jobs.get("cloud-gate", {})
emit("agg_present", bool(agg))
emit("agg_matrix", "strategy" in agg and "matrix" in agg.get("strategy", {}))
emit("agg_if", str(agg.get("if")).strip())
emit("agg_name", agg.get("name"))
emit("agg_needs", ",".join(agg.get("needs", [])))
# continue-on-error jobs must never appear in the aggregator's needs set:
# needs.<job>.result reads `success` for a FAILED continue-on-error job.
coe = [n for n, j in jobs.items() if j.get("continue-on-error") is True]
emit("coe_jobs", ",".join(sorted(coe)))
emit("coe_in_needs", ",".join(sorted(set(coe) & set(agg.get("needs", [])))))
# THE POST-VERDICT CATEGORY. Exactly one shape of blocking job legitimately
# cannot live in `needs`: a reporter that runs AFTER the aggregator concluded,
# to carry main's own red to a human. Wiring it in is not a trade-off, it is a
# CYCLE (cloud-gate -> reporter -> cloud-gate) and GitHub refuses to load it.
# A job is post-verdict iff ALL THREE hold:
#   (1) needs == ["cloud-gate"] EXACTLY — so `needs` really is the cycle, not a
#       choice somebody declined to make;
#   (2) its `if:` starts with an ANCHORED failure(). The loose \bfailure\(\)
#       admits `success() || failure()` — a job that runs on EVERY GREEN
#       wearing post-verdict clothes. The anchor is load-bearing;
#   (3) it is NOT continue-on-error, so it keeps its own exit-1. That retained
#       can-lose property is what the exemption is granted in exchange for; a
#       muted reporter is named by post_verdict_muted below, never exempted.
POST_VERDICT_IF = re.compile(r"^failure\(\)(\s|&|$)")
def post_verdict_shape(j):
    return (list(j.get("needs") or []) == ["cloud-gate"]
            and bool(POST_VERDICT_IF.match(str(j.get("if", "")).strip())))
post_verdict = {n for n, j in jobs.items()
                if post_verdict_shape(j) and j.get("continue-on-error") is not True}
post_verdict_muted = {n for n, j in jobs.items()
                      if post_verdict_shape(j) and j.get("continue-on-error") is True}
emit("post_verdict_jobs", ",".join(sorted(post_verdict)))
emit("post_verdict_muted", ",".join(sorted(post_verdict_muted)))
# …and the mirror hazard, which the allow-set cannot see: a BLOCKING job added
# to cloud.yml but never wired into `needs`. The aggregator cannot judge a job
# nobody told it about, so it would green while that job is red. Post-verdict
# jobs are subtracted — they are judged by the pinned roster instead, which is
# STRICTER than this set difference, not laxer.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != "cloud-gate"}
emit("blocking_not_in_needs",
     ",".join(sorted(blocking - set(agg.get("needs", [])) - post_verdict)))
# D36 — THE OTHER HALF OF THAT GUARD. Reaching `needs` alone changes nothing:
# `needs.<job>.result` is only consulted if the job is bound to a step env var
# AND that var is passed to `decide`. So walk the whole chain per job —
#   needs entry -> env var bound to needs.<job>.result -> decide's 2nd argument
# — and name every job that falls out of it. The decide side keys on the SECOND
# positional argument, which is label-independent: the first argument is a human
# label that deliberately does not match the job name.
agg_needs = list(agg.get("needs", []))
step = next((s for s in agg.get("steps", []) if "run" in s), {})
var_for = {}
for var, expr in (step.get("env") or {}).items():
    m = re.search(r"needs\.([A-Za-z0-9_.-]+)\.result", str(expr))
    if m:
        var_for[m.group(1)] = var
consumed = set(re.findall(
    r'^\s*decide\s+"[^"]*"\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"',
    step.get("run", ""), re.M))
emit("needs_without_decide",
     ",".join(sorted(j for j in agg_needs if var_for.get(j) not in consumed)))
# Companion cardinalities. An empty difference is only meaningful if the three
# sets it is computed from are populated: a regex that stops matching would
# report a serene "" forever. These make a NEUTERED detector red instead.
emit("needs_count", len(agg_needs))
emit("needs_results_count", len(var_for))
emit("decide_consumes_count", len(consumed))
disp = jobs.get("changes", {})
emit("dispatcher_if", str(disp.get("if", "")))
emit("dispatcher_matrix", "strategy" in disp)
emit("dispatcher_outputs", ",".join(sorted(disp.get("outputs", {}))))
esc = jobs.get("path-escape", {})
emit("escape_if", str(esc.get("if", "")))
emit("escape_needs", ",".join(esc.get("needs", [])))
for n in ("compile", "test"):
    emit(f"if::{n}", str(jobs.get(n, {}).get("if", "")))
    emit(f"matrix::{n}", "strategy" in jobs.get(n, {}))
out.close()
PY
  python3 "$EMIT" "$WF" "$FACTS"
  fact() { sed -n "s|^$1=||p" "$FACTS"; }
  assert_fact() {
    if [ "$(fact "$1")" = "$2" ]; then ok "$1 = $2"; else no "$1 = '$(fact "$1")', wanted '$2'"; fi
  }
  assert_fact_min() {
    local got
    got="$(fact "$1")"
    case "$got" in
      '' | *[!0-9]*) no "$1 = '$got' — not a number, the emitter is broken" ;;
      *)
        if [ "$got" -ge "$2" ]; then ok "$1 = $got (>= $2)"; else
          no "$1 = $got, wanted >= $2 — the detector is neutered, not the tree clean"
        fi
        ;;
    esac
  }
  # THE REGISTRABILITY INVARIANTS. Each one is a way `Cloud gate` stops being a
  # safe required context.
  assert_fact workflow_paths False
  assert_fact agg_present True
  assert_fact agg_matrix False
  assert_fact agg_if "always()"
  assert_fact agg_name "Cloud gate"
  assert_fact coe_jobs ""
  assert_fact coe_in_needs ""
  assert_fact blocking_not_in_needs ""
  # THE POST-VERDICT ROSTER IS AN EXACT PIN, AND THAT DELIBERATELY DIVERGES
  # FROM `assert_fact_min`'s "a lower bound, never an equality" convention two
  # helpers up. Do NOT "fix" this into a _min bound: a lower bound is a blanket
  # hole in BOTH directions. It passes a SMUGGLED second post-verdict-shaped
  # job (a job that reaches `if: failure()` and is then exempt from every other
  # structural check here), and it passes the reporter being DELETED (">= 1"
  # cannot tell an empty roster from a full one once the bound is 0). Nothing
  # else in this harness catches either — both are proven below. Adding a
  # second post-verdict job is supposed to cost a human naming it right here.
  #
  # The roster is now EXACT: report-main-failure ships in this workflow, so the
  # empty alternative that covered its absence is gone (PR #10155). Deleting the
  # reporter now reds this ratchet directly, not only via the mutation matrix.
  #
  # ONE ENCODING OF THE ROSTER, consulted by the live assertion below AND by the
  # mutation matrix's pin_reds. It used to be written twice, and the second copy
  # drifted immediately: the matrix printed "the exact pin REDS it" for the
  # DELETED mutant while the shipped pin, carrying the transitional "", happily
  # accepted it. A ratchet that reports catching what it does not catch is the
  # exact lie this harness exists to refuse, so the roster is a function and
  # there is nothing left to keep in sync.
  post_verdict_roster_ok() {
    case "$1" in
      "report-main-failure") return 0 ;;
      *) return 1 ;;
    esac
  }
  if post_verdict_roster_ok "$(fact post_verdict_jobs)"; then
    ok "post_verdict_jobs = '$(fact post_verdict_jobs)' (inside the pinned roster)"
  else
    no "post_verdict_jobs = '$(fact post_verdict_jobs)' — outside the pinned roster {report-main-failure}"
  fi
  # A post-verdict job that mutes its own exit-1 has spent the exemption's
  # price without paying it. Named as its own fact so it cannot hide inside
  # `coe_jobs` if that assertion is ever relaxed.
  assert_fact post_verdict_muted ""
  assert_fact needs_without_decide ""
  assert_fact_min needs_count 4
  assert_fact_min needs_results_count 4
  assert_fact_min decide_consumes_count 4
  assert_fact dispatcher_if ""
  assert_fact dispatcher_matrix False
  assert_fact dispatcher_outputs "cloud"
  assert_fact escape_if ""
  assert_fact escape_needs ""
  assert_fact "if::compile" "needs.changes.outputs.cloud == 'true'"
  assert_fact "if::test" "needs.changes.outputs.cloud == 'true'"
  # …and the reason the aggregator had to be a NEW job rather than a rename of a
  # leaf: both gated jobs ARE matrixed, so their published names carry the matrix
  # tuple (or the uninterpolated template when they never start).
  assert_fact "matrix::compile" True
  assert_fact "matrix::test" True

  # ── D36 mutation proof: the fifth fact must FIRE, and must go quiet ────────
  # `needs_without_decide = ""` above proves nothing unless the same emitter, on
  # the same file, returns a non-empty answer when the wiring is genuinely
  # broken. Three increasingly-complete stages of adding a blocking job.
  MUT="$TMPROOT/mutate-cloud-yml.py"
  cat >"$MUT" <<'PY'
import sys, yaml
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(src))
agg = wf["jobs"]["cloud-gate"]
step = next(s for s in agg["steps"] if "run" in s)
assert mode in ("clean", "needs", "env", "wired"), mode   # a typo'd mode is not a pass
if mode in ("needs", "env", "wired"):
    # a BLOCKING job (no continue-on-error), wired into the aggregator's needs
    wf["jobs"]["seed-ceiling"] = {"runs-on": "ubuntu-latest",
                                  "steps": [{"run": "exit 1"}]}
    agg["needs"] = list(agg["needs"]) + ["seed-ceiling"]
if mode in ("env", "wired"):
    step.setdefault("env", {})["R_SEED"] = "${{ needs.seed-ceiling.result }}"
if mode == "wired":
    step["run"] = step["run"].replace(
        'decide "changes (dispatcher)"',
        'decide "seed ceiling"           "${R_SEED}" "NEVER"\n'
        'decide "changes (dispatcher)"', 1)
yaml.safe_dump(wf, open(dst, "w"))
PY
  direction() {
    local mode="$1" want="$2" f="$TMPROOT/mut-$1.yml" ff="$TMPROOT/mut-$1.facts" got
    # `clean` goes through the same load/dump round-trip as the three broken
    # copies, so the ONLY variable between the four is the mutation itself.
    python3 "$MUT" "$WF" "$f" "$mode"
    python3 "$EMIT" "$f" "$ff"
    got="$(sed -n 's|^needs_without_decide=||p' "$ff")"
    if [ "$got" = "$want" ]; then
      ok "  mutation[$mode]: needs_without_decide = '${got}'"
    else
      no "  mutation[$mode]: needs_without_decide = '${got}', wanted '${want}'"
    fi
  }
  direction clean ""                             # untouched tree — silent
  direction needs "seed-ceiling"                 # in needs, no env binding
  direction env   "seed-ceiling"                 # in needs + env, never decided
  direction wired ""                             # fully wired — silent again

  # …and the workflow_paths fact must be able to fire too. Put the deleted
  # `on: pull_request: paths:` block back and it must report True, or the
  # `assert_fact workflow_paths False` above is a decoration.
  PMUT="$TMPROOT/mutate-cloud-paths.py"
  cat >"$PMUT" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
key = True if True in wf else "on"
wf[key]["pull_request"] = {"paths": ["cloud/**"]}
yaml.safe_dump(wf, open(sys.argv[2], "w"))
PY
  python3 "$PMUT" "$WF" "$TMPROOT/mut-paths.yml"
  python3 "$EMIT" "$TMPROOT/mut-paths.yml" "$TMPROOT/mut-paths.facts"
  if [ "$(sed -n 's|^workflow_paths=||p' "$TMPROOT/mut-paths.facts")" = "True" ]; then
    ok "  mutation[paths]: a restored workflow-level paths filter is DETECTED"
  else
    no "  mutation[paths]: the workflow_paths fact does not fire — it proves nothing"
  fi

  # ── post-verdict mutation matrix ──────────────────────────────────────────
  # The exemption above is worth exactly as much as its ability to REFUSE. Nine
  # copies of the REAL cloud.yml, one per way a job can wear post-verdict
  # clothes without being one.
  PVMUT="$TMPROOT/mutate-cloud-postverdict.py"
  cat >"$PVMUT" <<'PY'
import sys, yaml
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(src))
jobs = wf["jobs"]
assert mode in ("clean", "reporter", "coe", "always", "loose", "extra-needs",
                "ordinary", "smuggled", "deleted"), mode   # a typo'd mode is not a pass
def reporter():
    # PR #10155's job, reproduced in shape: needs the aggregator, anchored
    # failure(), main-only, no continue-on-error.
    return {"name": "Report main-push failure to a human",
            "needs": ["cloud-gate"],
            "if": "failure() && github.ref == 'refs/heads/main'",
            "runs-on": "ubuntu-latest",
            "steps": [{"run": "bash scripts/file-ci-failure-issue.sh"}]}
# Every mutant starts from the SAME base — the real cloud.yml with any reporter
# removed — so these expectations hold whether or not #10155 has merged. The
# matrix must not change meaning the day the tree it reads gains the job.
jobs.pop("report-main-failure", None)
if mode not in ("clean", "deleted"):
    jobs["report-main-failure"] = reporter()
r = jobs.get("report-main-failure")
if mode == "coe":
    r["continue-on-error"] = True                       # mutes its own exit-1
elif mode == "always":
    r["if"] = "always() && github.ref == 'refs/heads/main'"
elif mode == "loose":
    r["if"] = "(success() || failure()) && github.ref == 'refs/heads/main'"
elif mode == "extra-needs":
    r["needs"] = ["cloud-gate", "changes"]              # no longer a pure cycle
elif mode == "ordinary":
    jobs["ordinary-lint"] = {"runs-on": "ubuntu-latest",
                             "steps": [{"run": "exit 1"}]}
elif mode == "smuggled":
    jobs["sneaky-lint"] = reporter()                    # a second post-verdict shape
# `deleted` is the #10155 shape with the reporter taken back out — byte-identical
# to `clean`, which is exactly the point: nothing in the FILE distinguishes "no
# reporter yet" from "the reporter was removed", so only the pinned roster can.
yaml.safe_dump(wf, open(dst, "w"))
PY
  # pv <mode> <post_verdict_jobs> <post_verdict_muted> <blocking_not_in_needs>
  pv() {
    local mode="$1" f="$TMPROOT/pv-$1.yml" ff="$TMPROOT/pv-$1.facts" key want got
    python3 "$PVMUT" "$WF" "$f" "$mode"
    python3 "$EMIT" "$f" "$ff"
    for key in post_verdict_jobs post_verdict_muted blocking_not_in_needs; do
      case "$key" in
        post_verdict_jobs) want="$2" ;;
        post_verdict_muted) want="$3" ;;
        *) want="$4" ;;
      esac
      got="$(sed -n "s|^$key=||p" "$ff")"
      if [ "$got" = "$want" ]; then
        ok "  post-verdict[$mode]: $key = '$got'"
      else
        no "  post-verdict[$mode]: $key = '$got', wanted '$want'"
      fi
    done
  }
  pv clean       ""                    ""                    ""
  pv reporter    "report-main-failure" ""                    ""
  pv coe         ""                    "report-main-failure" ""
  pv always      ""                    ""                    "report-main-failure"
  pv loose       ""                    ""                    "report-main-failure"
  pv extra-needs ""                    ""                    "report-main-failure"
  pv ordinary    "report-main-failure" ""                    "ordinary-lint"
  pv smuggled    "report-main-failure,sneaky-lint" ""        ""
  pv deleted     ""                    ""                    ""
  # The muted reporter reds TWICE: post_verdict_muted names it, and so does the
  # `coe_jobs = ""` assertion above. Both, so relaxing either one alone leaves
  # the escape closed.
  if [ "$(sed -n 's|^coe_jobs=||p' "$TMPROOT/pv-coe.facts")" = "report-main-failure" ]; then
    ok "  post-verdict[coe]: coe_jobs = report-main-failure — the SECOND red"
  else
    no "  post-verdict[coe]: coe_jobs did not name the muted reporter"
  fi
  # And the exactness of the pin, proven in both directions. A `_min`-style
  # lower bound of 1 would PASS both of these — the smuggled job only adds a
  # name, the deleted reporter only removes one — so only equality against the
  # named roster reds them.
  # pin_reds runs the mutant's fact through post_verdict_roster_ok — the SHIPPED
  # roster, not a second copy of it — so it reports what this ratchet actually
  # does on that tree, and cannot drift away from the assertion it describes.
  pin_reds() {
    local got
    got="$(sed -n 's|^post_verdict_jobs=||p' "$TMPROOT/pv-$1.facts")"
    if post_verdict_roster_ok "$got"; then
      no "  post-verdict[$1]: the pin does NOT red it — post_verdict_jobs = '$got'"
    else
      ok "  post-verdict[$1]: the shipped roster REDS it (post_verdict_jobs = '$got')"
    fi
  }
  pin_reds smuggled
  # …and the DELETED mutant. This USED to be a known gap: the transitional ""
  # alternative accepted a deleted reporter, so the harness could not red it.
  # PR #10155 ships report-main-failure and drops that alternative, so the
  # roster is now EXACT and this mutant reds like any other. Closes
  # cch-w46-s4-followup-drop-empty-post-verdict-alternative.
  pin_reds deleted
fi
echo

# ── case 9: the aggregator's allow-set, driven by mutation ─────────────────
# The step body is EXTRACTED FROM cloud.yml and executed, so this cannot drift
# from what CI runs (D26: a harness must execute the step body, not a paraphrase
# of it). Each case supplies exactly the env GitHub would.
echo "case 9: the aggregator decides, and can be made red on purpose"
AGG="$TMPROOT/cloud-gate-step.sh"
python3 - "$WF" "$AGG" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["cloud-gate"]["steps"] if "run" in s][0]
open(sys.argv[2], "w").write(step["run"])
PY

# gate <label> <expected-rc> KEY=VAL...
#
# The step's output lands in $GATE_OUT, never on stdout: a `gate` call wrapped
# in `$( … )` would run its ok/no in a SUBSHELL and silently lose the counter —
# a pass that proves nothing, which is the exact defect class this epic exists
# to remove. Follow-up assertions read the file.
GATE_OUT="$TMPROOT/gate.out"
gate() {
  local label="$1" want="$2"
  shift 2
  local rc
  env -i PATH="$PATH" HOME="$HOME" "$@" bash --noprofile --norc "$AGG" >"$GATE_OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label -> exit $rc"
  else
    no "$label -> exit $rc, wanted $want"
    sed 's/^/        /' "$GATE_OUT" >&2
  fi
  # The exit code ALONE is not a verdict. Most cases below expect exit 1 — and a
  # step body that never decided anything exits 1 too: an unbound variable under
  # `set -u`, a syntax error, a `decide` renamed out from under its call sites.
  # Every one of those would read as `ok` here while proving nothing about the
  # allow-set. So also require the aggregator to have reached its own
  # conclusion, in the polarity expected.
  local verdict
  if [ "$want" -eq 0 ]; then
    verdict="Cloud gate: every upstream job either succeeded"
  else
    verdict="::error::Cloud gate: at least one upstream job is not in the allow-set"
  fi
  if grep -qF -- "$verdict" "$GATE_OUT"; then
    ok "  …and reached its own verdict line"
  else
    no "  …but printed NO verdict line — the step body crashed rather than decided"
    sed 's/^/        /' "$GATE_OUT" >&2
  fi
}
gate_says() {
  if grep -q -- "$1" "$GATE_OUT"; then ok "$2"; else no "$2 (not in the step output)"; fi
}
# gate_names <must-name> <must-not-name> — D770/D771.
#
# `gate_says` reads the whole step OUTPUT, which has always named the failing
# job in its log. This reads the `::error::` ANNOTATION ONLY — the single line
# the check-run API carries, and therefore the only line a human at the merge
# button or the merge queue ever sees. Until this slice that line said "at least
# one upstream job" and stopped.
#
# It is a PAIR by construction: naming the job that failed is worth nothing on
# its own (a hardcoded sentence satisfies it), so the same call also refuses an
# annotation that names a job which PASSED in this very run.
gate_names() {
  local ann named
  ann="$(grep '^::error' "$GATE_OUT" | tr '\n' ' ')"
  named="${ann#*NOT IN THE ALLOW-SET: }"
  if [ -z "$ann" ] || [ "$named" = "$ann" ]; then
    no "  …but the annotation names no job at all: ${ann:-<no ::error:: line>}"
    return 0
  fi
  case "$named" in
    *"$1"*) ok "  …and the annotation names the refusing '$1'" ;;
    *) no "  …but the annotation never named the refusing '$1': $ann" ;;
  esac
  case "$named" in
    *"$2"*) no "  …and it names '$2', which PASSED in this run: $ann" ;;
    *) ok "  …and does not name the passing '$2'" ;;
  esac
}

# (a) the happy path: a full cloud/** PR, everything ran and passed
gate "full run, all green" 0 \
  R_CHANGES=success R_COMPILE=success R_TEST=success R_ESCAPE=success O_CLOUD=true

# (b) THE DEADLOCK-FREE SKIP: a docs-only / api-only / js-only PR. This is the
#     case a workflow-level paths filter could not express without making the
#     required context ABSENT. Here the name is PRESENT and GREEN.
gate "docs-only PR, expensive jobs legitimately skipped" 0 \
  R_CHANGES=success R_COMPILE=skipped R_TEST=skipped R_ESCAPE=success O_CLOUD=false
gate_says "legitimately not dispatched" "…and says so, rather than claiming the suite passed"

# (c) an upstream FAILURE reds it
gate "test failed" 1 \
  R_CHANGES=success R_COMPILE=success R_TEST=failure R_ESCAPE=success O_CLOUD=true
gate_names "test" "compile"

# (d) THE BYPASS THIS SHAPE EXISTS TO CLOSE: `test` skipped only because an
#     upstream died, while the dispatcher said it WAS needed.
gate "test skipped behind a live gate (upstream died)" 1 \
  R_CHANGES=success R_COMPILE=success R_TEST=skipped R_ESCAPE=success O_CLOUD=true
gate_says "its gate is 'true', not 'false'" "…and names the reason (a skip is not a pass)"
# …and the SKIP arm accumulates too, not just the failure arm: this red never
# passes through `failure`, so an accumulator wired only there would leave the
# annotation contentless on exactly the bypass this shape exists to close.
gate_names "test" "compile"

# (e) the dispatcher itself failing reds it, with an empty output
gate "dispatcher failed, output empty" 1 \
  R_CHANGES=failure R_COMPILE=skipped R_TEST=skipped R_ESCAPE=success O_CLOUD=

# (f) the unfiltered ratchet may never skip
gate "path-escape skipped" 1 \
  R_CHANGES=success R_COMPILE=success R_TEST=success R_ESCAPE=skipped O_CLOUD=true

# (g) cancelled is not success
gate "a cancelled upstream" 1 \
  R_CHANGES=success R_COMPILE=success R_TEST=cancelled R_ESCAPE=success O_CLOUD=true

# (h) anything unrecognised is red — "cannot tell" is a failure, not a pass
gate "an unrecognised result value" 1 \
  R_CHANGES=success R_COMPILE=success R_TEST=neutral R_ESCAPE=success O_CLOUD=true

# (i) an EMPTY result (a job silently dropped from `needs`) is red
gate "an empty result string" 1 \
  R_CHANGES=success R_COMPILE=success R_TEST= R_ESCAPE=success O_CLOUD=true

# (j) a garbage gate value must not license a skip
gate "skip against a garbage gate value" 1 \
  R_CHANGES=success R_COMPILE=skipped R_TEST=skipped R_ESCAPE=success O_CLOUD=maybe

# (k) the aggregator's own step body must be able to fail. If the extracted
#     script were empty or unparseable every case above would "pass" at exit 0
#     for the wrong reason — so assert it produced a real verdict line.
if [ -s "$AGG" ] && grep -q "unrecognised result" "$AGG"; then
  ok "the extracted step body is the real one (non-empty, carries the allow-set)"
else
  no "extracted an empty or wrong step body — every case above proved nothing"
fi
echo

# ── case 10: the dispatcher, driven against a real git repo ────────────────
# Same extraction discipline as case 9. The two `${{ … }}` expressions are
# substituted from the environment so the body can run outside Actions.
echo "case 10: the dispatcher fails rather than skips when it cannot tell"
DISP="$TMPROOT/dispatch-step.sh"
python3 - "$WF" "$DISP" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["changes"]["steps"] if s.get("id") == "sets"][0]
body = (step["run"]
        .replace("${{ github.event_name }}", "${T_EVENT}")
        .replace("${{ github.event.pull_request.base.sha }}", "${T_BASE}"))
open(sys.argv[2], "w").write(body)
PY

DR="$TMPROOT/dispatchrepo"
mkdir -p "$DR/cloud/lib" "$DR/docs" "$DR/api/lib" "$DR/scripts" \
  "$DR/js/packages/create-barkpark-app/templates"
cp "$SCRIPT" "$REAL_ROOT/scripts/cloud-path-escape-check.test.sh" "$DR/scripts/"
: >"$DR/cloud/lib/a.ex"
# NON-EMPTY on purpose: the rename cases below need git's rename detection to
# actually fire, and an empty blob is not a rename source worth the name.
printf 'moved-a\nmoved-b\nmoved-c\n' >"$DR/cloud/lib/moved.ex"
: >"$DR/docs/guide.md"
: >"$DR/api/lib/a.ex"
: >"$DR/js/packages/create-barkpark-app/templates/package.json"
git -C "$DR" init -q
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
BASE_SHA="$(git -C "$DR" rev-parse HEAD)"

# dispatch <label> <expected-rc> <expected-cloud> <event> <base>
dispatch() {
  local label="$1" want="$2" wc="$3" ev="$4" bs="$5"
  local rc gotc
  : >"$TMPROOT/gh_output"
  (cd "$DR" && env T_EVENT="$ev" T_BASE="$bs" GITHUB_OUTPUT="$TMPROOT/gh_output" \
    bash --noprofile --norc "$DISP") >"$GATE_OUT" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label -> exit $rc"
  else
    no "$label -> exit $rc, wanted $want"
    sed 's/^/        /' "$GATE_OUT" >&2
    return 0
  fi
  # A bare `return` here would propagate the test's exit status and, under
  # `set -e`, abort the whole harness mid-run — silently truncating the
  # remaining cases into an apparent pass.
  [ "$want" -eq 0 ] || return 0
  gotc="$(sed -n 's/^cloud=//p' "$TMPROOT/gh_output")"
  if [ "$gotc" = "$wc" ]; then
    ok "  …emits cloud=$gotc"
  else
    no "  …emitted cloud=$gotc, wanted cloud=$wc"
  fi
}

# a docs-only PR is the whole point of the shim: skip the suite, honestly, and
# STILL publish the required context.
git -C "$DR" checkout -q -b docs-only
: >"$DR/docs/another.md"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm docs >/dev/null 2>&1
dispatch "docs-only PR" 0 false pull_request "$BASE_SHA"

# an api-only PR must ALSO skip — this is the one D89 named as the deadlock the
# workflow-level filter caused, and the shim's reason for existing.
git -C "$DR" checkout -q -b apionly "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/a.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm api >/dev/null 2>&1
dispatch "api-only PR" 0 false pull_request "$BASE_SHA"

# the vendored-template SOURCE selects the set — the #963→#969 drift guard
git -C "$DR" checkout -q -b templates "$BASE_SHA"
printf 'x\n' >"$DR/js/packages/create-barkpark-app/templates/package.json"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm templates >/dev/null 2>&1
dispatch "create-barkpark-app templates PR" 0 true pull_request "$BASE_SHA"

# a cloud/** change selects the set
git -C "$DR" checkout -q -b cloudchange "$BASE_SHA"
printf 'x\n' >"$DR/cloud/lib/a.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm cloud >/dev/null 2>&1
dispatch "cloud/** PR" 0 true pull_request "$BASE_SHA"

# push to main never skips, regardless of what changed
dispatch "push event" 0 true push ""

# ── THE FIVE FALSE-GREEN CLASSES the plain `--name-only` producer let through ─
# Every probe above this line is ASCII and rename-free, which is exactly why the
# harness could never have caught either family. These two are the ones that
# matter: `git diff --name-only` QUOTES a path containing `"` (even under
# core.quotepath=false), and rename detection prints only the DESTINATION.
# Both classify FALSE on the pre-fix line — a green required context over a
# suite that never ran.

# (1) a DOUBLE-QUOTE path inside the declared set. Not merely a non-ASCII one:
#     core.quotepath=false silences the octal escaping and leaves this class
#     wide open, so a fix tested only against é would certify a hole.
git -C "$DR" checkout -q -b dquote "$BASE_SHA"
printf 'x\n' >"$DR/cloud/lib/we\"ird.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm dquote >/dev/null 2>&1
dispatch 'a path containing a double quote' 0 true pull_request "$BASE_SHA"

# (2) a rename OUT of the declared set. cloud/** just lost a file — the suite
#     MUST run — but rename detection names only docs/.
git -C "$DR" checkout -q -b renameout "$BASE_SHA"
git -C "$DR" mv cloud/lib/moved.ex docs/moved.ex >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renameout >/dev/null 2>&1
dispatch "a rename OUT of the declared set" 0 true pull_request "$BASE_SHA"

# (3) …and a rename INTO the set still classifies true — `--no-renames` prints
#     BOTH sides, so closing (2) must not have cost the obvious direction.
git -C "$DR" checkout -q -b renamein "$BASE_SHA"
git -C "$DR" mv docs/guide.md cloud/lib/guide.md >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renamein >/dev/null 2>&1
dispatch "a rename INTO the declared set" 0 true pull_request "$BASE_SHA"

# THE FAILURE PATHS — the polarity that makes the shim safe.
# An empty diff is the ONE "cannot tell" that does not fail: a revert pair or a
# branch-sync PR nets to nothing and is perfectly legal, and the old ::error::
# left its author with a permanently red required context and no self-service
# fix. It dispatches TRUE — expensive, never wrong. Everything else still reds.
git -C "$DR" checkout -q -b emptydiff "$BASE_SHA"
dispatch "empty diff (base == HEAD)" 0 true pull_request "$(git -C "$DR" rev-parse HEAD)"
gate_says "changed-file set is EMPTY" "  …and names the shape"
gate_says "::warning" "  …as a WARNING, not a brick"
gate_says "rather than skipping it" "  …and says it is running everything instead"
dispatch "unresolvable base sha" 1 - pull_request 0000000000000000000000000000000000000000
gate_says "not resolvable in this checkout" "  …and refuses to guess a base"
dispatch "missing base sha" 1 - pull_request ""
gate_says "carries no base sha" "  …and says why"

# a base with NO common ancestor: `git diff base...HEAD` exits 128 with a bare
# `fatal: … no merge base` and zero annotation. Named, not fatalled.
git -C "$DR" checkout -q --orphan noancestor >/dev/null 2>&1
git -C "$DR" rm -rq --cached . >/dev/null 2>&1 || true
rm -rf "${DR:?}/cloud" "${DR:?}/docs" "${DR:?}/api" "${DR:?}/js"
mkdir -p "$DR/cloud/lib"
printf 'z\n' >"$DR/cloud/lib/orphan.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm orphan >/dev/null 2>&1
dispatch "a base with no common ancestor" 1 - pull_request "$BASE_SHA"
gate_says "share NO common ancestor" "  …and names the condition, not a raw git fatal"
gate_says "refusing a two-dot fallback" "  …and refuses the fallback that sweeps in the whole base"
echo

# ── case 11: the in-image reader arm reds a cloud/lib escape, both directions ─
# The cloud/lib reader arm (cch-w69-s1) is FATAL for any census row whose reader
# lives under cloud/lib/, covered or not — cloud/lib compiles INTO the
# control-plane image, the image builds from cloud/ alone, so a repo-root read
# there is green everywhere except the deploy's `mix compile` (the #11723 / D841
# class). s1 mutation-proved that arm by hand; this case makes the proof STANDING
# — a future edit that reorders the arm behind the coverage exit, or breaks its
# tab-IFS parse, reds here instead of staying green. It can lose in BOTH
# directions: the cloud/lib reader must red, and its cloud/test twin must pass
# (tests never run inside the image). Fixtures are built here, census-independent.
echo "case 11: the in-image reader arm reds a cloud/lib escape (both directions)"

# (a) a cloud/lib reader that Path.expand-escapes to a DECLARED repo-root file is
#     FATAL. deploy/site-deploy.sh IS in CLOUD_PATHS, so dispatch coverage is not
#     the question — the file cannot exist in the docker build context, and no
#     declaration can put it there. This must red the in-image arm, not surface
#     as a coverage miss that invites declaring an already-declared path.
FX4="$TMPROOT/in-image-lib"
make_fixture "$FX4"
mkdir -p "$FX4/deploy"
: >"$FX4/deploy/site-deploy.sh"
cat >"$FX4/cloud/lib/audit_reader.ex" <<'EX'
  @actions Path.expand("../../deploy/site-deploy.sh", __DIR__)
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX4" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — a cloud/lib reader escaping to a declared file reds"
else
  no "PASSED with a cloud/lib reader escaping the image — the #11723/D841 hole"
fi
if has "$out" "IN-IMAGE READER ESCAPES THE BUILD CONTEXT: cloud/lib/audit_reader.ex reads deploy/site-deploy.sh"; then
  ok "the violation line names both the reader and the escaped path"
else
  no "in-image violation did not name reader+path: $out"
fi
# It must red HERE — as the in-image arm — never as an UNCOVERED coverage miss:
# the arm runs FIRST for exactly this reason, so a declared path never gets a
# missing-declaration red that would invite declaring what dispatch cannot place
# inside the build context.
if has "$out" "UNCOVERED repo-root read: deploy/site-deploy.sh"; then
  no "the declared read surfaced as a coverage miss — the in-image arm did not claim it first"
else
  ok "the declared read did not surface as a coverage miss — the in-image arm claimed it"
fi

# (b) the SAME read moved under cloud/test must NOT trip the arm. Tests never run
#     inside the control-plane image, so a cloud/test escape to a declared file
#     is the coverage ratchet's business and passes clean.
FX5="$TMPROOT/in-image-test"
make_fixture "$FX5"
mkdir -p "$FX5/deploy"
: >"$FX5/deploy/site-deploy.sh"
cat >"$FX5/cloud/test/barkpark_cloud/audit_reader_test.exs" <<'EX'
  @actions Path.expand("../../../deploy/site-deploy.sh", __DIR__)
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX5" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "exit 0 — the same escape under cloud/test does not trip the in-image arm"
else
  no "a cloud/test escape to a declared file red (rc=$rc): $out"
fi
if has "$out" "IN-IMAGE READER ESCAPES THE BUILD CONTEXT"; then
  no "the in-image arm fired on a cloud/test reader — it must judge cloud/lib only"
else
  ok "the in-image arm stayed silent on the cloud/test reader"
fi
echo

# ── case 12: the census reads a SEGMENT LIST, not only the quoted literal ───
# cch-w53. The census used to extract exactly `grep -Eoh '"\.\./[^"]*"'`, which
# made this ratchet evadable BY AUTHORING STYLE ALONE. Measured on origin/main:
#
#   Path.expand("../../../internal/provisioner", __DIR__)
#       -> exit 1, `UNCOVERED repo-root read: internal/provisioner`
#   Path.join([__DIR__, "..", "..", "..", "internal", "provisioner"])
#       -> exit 0, `OK: every repo-root read … is dispatched on`, census flat
#
# The two resolve to the IDENTICAL directory, so the second one is precisely the
# hole this shim exists to close: a Cloud test reads a repo-root path the
# dispatcher does not dispatch on, a PR touching that path skips the only suite
# that checks it, and the ratchet says OK. The forms must be indistinguishable
# to this script, and these arms are what keep them that way.
echo "case 12: a segment-list read is seen exactly like a quoted literal"

# The fixture adds a SIXTH covered read to make_fixture's five, written ONLY as
# a segment list. That is deliberate: it clears the floor of 6 only BECAUSE the
# segment-list reader works, so a future edit that neuters that reader reds
# these cases on the floor instead of leaving them quietly green.
# A red from any fixture below must be THE COVERAGE RED, never the floor red.
# Without this, a neutered segment-list reader drops these fixtures under the
# floor of 6 and every rc-only arm reports `ok` for a failure that has nothing
# to do with the form under test — a vacuous green wearing a pass's clothes.
# Measured: against origin/main's extractor this discrimination turns four
# wrong-reason passes into four honest reds.
not_floor() {
  if has "$1" "SCANNER is broken, not the repo clean"; then
    no "$2 — it red on the FLOOR, not on the read under test"
  else
    ok "$2"
  fi
}

seg_fixture() {
  local root="$1"
  make_fixture "$root"
  mkdir -p "$root/deploy"
  : >"$root/deploy/site-deploy.sh"
  cat >"$root/cloud/test/barkpark_cloud/seg_covered_test.exs" <<'EX'
  @f Path.join([__DIR__, "..", "..", "..", "deploy", "site-deploy.sh"])
EX
}

# (a) an UNDECLARED repo-root read written as a segment list must red, and must
#     name the resolved path and the file that reads it — same words the quoted
#     form gets in case 3.
FX6="$TMPROOT/seg-uncovered"
seg_fixture "$FX6"
mkdir -p "$FX6/nowhere"
: >"$FX6/nowhere/secret.json"
SEGFILE="$FX6/cloud/test/barkpark_cloud/seg_escape_test.exs"
cat >"$SEGFILE" <<'EX'
  @bad Path.join([__DIR__, "..", "..", "..", "nowhere", "secret.json"])
EX
# NON-VACUITY, asserted before the verdict: this file must be INVISIBLE to the
# old literal-only extractor. If it ever carries a `"../…"` literal, the case
# below would be re-proving case 3 and would pass even with the segment-list
# reader deleted.
old_form="$(grep -Eoh '"\.\./[^"]*"' "$SEGFILE" || true)"
if [ -z "$old_form" ]; then
  ok "the mutation file carries NO \"../…\" literal — only the new reader can see it"
else
  no "the mutation file carries a quoted literal ($old_form) — this case cannot fail for the right reason"
fi
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX6" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a segment-list read of an undeclared path"
else
  no "PASSED with a segment-list escape — the authoring-style hole is open: $out"
fi
not_floor "$out" "…and the red is the coverage red, not the floor"
if has "$out" "UNCOVERED repo-root read: nowhere/secret.json"; then
  ok "names the path the segment list resolves to"
else
  no "did not name the segment-list path: $out"
fi
if has "$out" "read from: cloud/test/barkpark_cloud/seg_escape_test.exs"; then
  ok "attributes the segment-list read to its file"
else
  no "did not attribute the segment-list read: $out"
fi

# (b) THE EQUIVALENCE. The same read written as a quoted literal must produce
#     the same verdict and the same path — the two forms are one read.
FX7="$TMPROOT/seg-equivalent"
seg_fixture "$FX7"
mkdir -p "$FX7/nowhere"
: >"$FX7/nowhere/secret.json"
cat >"$FX7/cloud/test/barkpark_cloud/seg_escape_test.exs" <<'EX'
  @bad Path.expand("../../../nowhere/secret.json", __DIR__)
EX
out2="$(CLOUD_PATH_ESCAPE_ROOT="$FX7" "$SCRIPT" 2>&1)" && rc2=0 || rc2=$?
if [ "$rc2" -eq "$rc" ]; then
  ok "the quoted twin of the same read exits identically ($rc2)"
else
  no "quoted form exits $rc2, segment form exits $rc — the forms are not one read"
fi
seg_paths="$(CLOUD_PATH_ESCAPE_ROOT="$FX6" "$SCRIPT" --list-escapes | cut -f1 | sort -u)"
lit_paths="$(CLOUD_PATH_ESCAPE_ROOT="$FX7" "$SCRIPT" --list-escapes | cut -f1 | sort -u)"
if [ "$seg_paths" = "$lit_paths" ]; then
  ok "both forms resolve to the identical census path set"
else
  no "census differs by authoring form: segment=[$seg_paths] literal=[$lit_paths]"
fi

# (c) a segment-list read of a DECLARED path is COVERED, not merely detected —
#     the new form participates in coverage, it is not a failure-only arm.
FX8="$TMPROOT/seg-covered"
seg_fixture "$FX8"
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX8" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "exit 0 — a segment-list read of a declared path is quiet"
else
  no "a declared segment-list read red (rc=$rc): $out"
fi
covered="$(CLOUD_PATH_ESCAPE_ROOT="$FX8" "$SCRIPT" --list-escapes | cut -f1 | sort -u)"
if has_line "$covered" 'deploy/site-deploy\.sh'; then
  ok "the declared path IS in the census (the read was seen, not skipped)"
else
  no "the segment-list read of a declared path never entered the census: $covered"
fi

# (d) THE GREEDY-JOIN CONTROL. A run ends at the first separator that is not a
#     comma. Without that, `Path.join([__DIR__, ".."]) == "nowhere/secret.json"`
#     would splice the right-hand side onto the path and invent a read that no
#     code performs — a FALSE RED that reads exactly like a true one.
FX9="$TMPROOT/seg-greedy"
seg_fixture "$FX9"
mkdir -p "$FX9/nowhere"
: >"$FX9/nowhere/secret.json"
cat >"$FX9/cloud/test/barkpark_cloud/compare_test.exs" <<'EX'
  test "the parent dir" do
    assert Path.join([__DIR__, ".."]) == "nowhere/secret.json"
  end
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX9" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "exit 0 — an equality against a path string is not spliced into a read"
else
  no "the joiner swallowed a non-comma-separated string (rc=$rc): $out"
fi

# (e) a list formatted ONE SEGMENT PER LINE is the shape a formatter produces.
#     The run has to survive the newline or the fix only covers single-line code.
FX10="$TMPROOT/seg-multiline"
seg_fixture "$FX10"
mkdir -p "$FX10/nowhere"
: >"$FX10/nowhere/secret.json"
cat >"$FX10/cloud/test/barkpark_cloud/multiline_test.exs" <<'EX'
  @bad Path.join([
         __DIR__,
         "..",
         "..",
         "..",
         "nowhere",
         "secret.json"
       ])
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX10" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — a multi-line segment list is seen"
else
  no "a formatted (one-segment-per-line) list slipped through: $out"
fi
not_floor "$out" "…and the multi-line red is the coverage red, not the floor"
if has "$out" "UNCOVERED repo-root read: nowhere/secret.json"; then
  ok "names the path a multi-line list resolves to"
else
  no "did not name the multi-line segment-list path: $out"
fi

# (f) the charlist form. Path/File take charlists, and the double-quote grep
#     cannot see one. Zero occurrences in the tree today — the arm closes the
#     form before it is used, and this is what proves the arm is wired at all.
FX11="$TMPROOT/seg-charlist"
seg_fixture "$FX11"
mkdir -p "$FX11/nowhere"
: >"$FX11/nowhere/secret.json"
cat >"$FX11/cloud/test/barkpark_cloud/charlist_test.exs" <<'EX'
  @bad Path.expand('../../../nowhere/secret.json', __DIR__)
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX11" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a single-quoted charlist read"
else
  no "a charlist read slipped through: $out"
fi
not_floor "$out" "…and the charlist red is the coverage red, not the floor"
if has "$out" "UNCOVERED repo-root read: nowhere/secret.json"; then
  ok "names the path a charlist read resolves to"
else
  no "did not name the charlist path: $out"
fi

# (g) the IN-IMAGE arm must see the new form too. A cloud/lib reader escaping
#     the docker build context is FATAL (the #11723 / D841 class); writing it as
#     a segment list must not buy an exemption from that.
FX12="$TMPROOT/seg-in-image"
seg_fixture "$FX12"
cat >"$FX12/cloud/lib/audit_reader.ex" <<'EX'
  @actions Path.join([__DIR__, "..", "..", "deploy", "site-deploy.sh"])
EX
out="$(CLOUD_PATH_ESCAPE_ROOT="$FX12" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — a cloud/lib segment-list escape is still fatal"
else
  no "a cloud/lib reader escaped the image via a segment list: $out"
fi
not_floor "$out" "…and the in-image red is the in-image red, not the floor"
if has "$out" "IN-IMAGE READER ESCAPES THE BUILD CONTEXT: cloud/lib/audit_reader.ex reads deploy/site-deploy.sh"; then
  ok "the in-image arm names the segment-list reader and its escaped path"
else
  no "in-image arm did not claim the segment-list read: $out"
fi

# (h) THE REAL TREE, not a fixture. billing_client_mirror_test.exs carries NO
#     `"../…"` literal at all — every path it reads is a segment list — so on
#     origin/main that file contributed NOTHING to the census while reading
#     cloud/docker-compose.yml. Its row is the standing proof that the reader
#     works on real code; neuter the reader and this row disappears.
real_census="$("$SCRIPT" --list-escapes)"
if has "$real_census" "docker-compose.yml	cloud/test/barkpark_cloud/billing_client_mirror_test.exs"; then
  ok "the real census attributes a read to a file with no quoted literal in it"
else
  no "the real census lost the segment-list-only reader — either the reader is neutered, or billing_client_mirror_test.exs stopped reading cloud/docker-compose.yml (if so, repoint this arm at another segment-list reader, do not delete it)"
fi
if [ -z "$(grep -Eoh '"\.\./[^"]*"' "$REAL_ROOT/cloud/test/barkpark_cloud/billing_client_mirror_test.exs" || true)" ]; then
  ok "…and that file genuinely has no \"../…\" literal for the old extractor to find"
else
  no "billing_client_mirror_test.exs now carries a quoted literal — arm (h) no longer proves the segment reader"
fi
echo

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
