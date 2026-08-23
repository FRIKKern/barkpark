#!/usr/bin/env bash
#
# elixir-path-escape-check.test.sh — the harness for the Elixir path ratchet.
#
# Charter D26: a harness nobody runs is not a ratchet. This one is executed by
# elixir.yml's `path-escape` job (unfiltered, so it can never go dark) and by
# the slice gate, via `elixir-path-escape-check.sh --selftest`.
#
# The cases that matter are the ones that prove the ratchet can FAIL:
#   * an uncovered repo-root read must red                  (case 3)
#   * an uncovered read in an UNTRACKED file must red       (case 4) — the
#     measured vacuous pass this ratchet was redesigned to avoid: a prototype
#     enumerating via `git ls-files` printed "OK: every repo-root read is
#     covered" and exited 0 with the mutation fixture sitting untracked on disk
#   * a neutered scanner must red rather than report clean  (case 5)
#   * a PARTIALLY neutered scanner must red too             (case 5b) — the
#     mutation the old whole-population floor could not see: deleting `api/test`
#     from list_escapes' `find` collapsed the census 29 -> 11 on origin/main and
#     still printed OK, exit 0, inside the REQUIRED Elixir gate. Case 5 only
#     ever exercised a TOTAL collapse, so it certified a floor that could not
#     fire on the failure its own comment named.
#   * a scanner door with no declared floor must red        (case 5c)
# A harness with only green cases is the defect, not the proof.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/elixir-path-escape-check.sh"
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

# ── charter D37: never `printf … | grep -q` ────────────────────────────────
# `printf '%s\n' "$x" | grep -q …` under `set -o pipefail` is a SIGPIPE trap on
# BSD grep (macOS): grep exits 0 the instant it matches, printf is killed by
# SIGPIPE, pipefail promotes 141 over grep's success, and the `if` takes the
# ELSE branch — reporting a FALSE failure for a match that did occur. Six
# consecutive local runs gave 6, 4, 3, 4, 5, 5 failures, never zero, while the
# same harness was 12/12 green on ubuntu/bash-5. That is wave 1's disease
# inverted: an assertion inside the anti-vacuous-pass harness returning a
# verdict for a reason foreign to what it tests.
#
# A here-string has no writer process to kill, so these are deterministic on
# every platform. Use them for EVERY match against a captured string; matches
# against a FILE (`grep -q … "$f"`) were never at risk and stay as they are.
has()      { grep -q  -- "$2" <<<"$1"; }   # substring/BRE anywhere in $1
has_line() { grep -qx -- "$2" <<<"$1"; }   # a whole line of $1 equals the BRE

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/elixir-path-escape-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Build a synthetic mini-repo whose api/ tree escapes to known repo-root paths.
# `covered_rel` is a path INSIDE a declared set; `uncovered_rel` is not in any.
#
# THE FIXTURE MUST CLEAR EVERY IDIOM FLOOR, not one aggregate number. The
# ratchet now floors each of its four doors separately (`--print-floors`:
# test-cwd 8, test-dir 8, lib-cwd 5, lib-dir 5), so a fixture that reads only
# from api/test would red on `lib-*: 0` and the coverage cases below would
# "prove" coverage using a floor failure. Every `../../../…` literal written
# from api/{lib,test}/barkpark resolves identically under BOTH bases — the
# file's own directory and `api/` — so one literal feeds one `-dir` row and one
# `-cwd` row. Hence: ten literals in the api/test file, six in the api/lib file,
# which leaves real headroom over 8 and 5 rather than sitting exactly on them.
make_fixture() {
  local root="$1"
  mkdir -p "$root/api/lib/barkpark" "$root/api/test/barkpark" \
    "$root/internal/taskboard" "$root/internal/chat/testdata" \
    "$root/internal/pdrender/testdata" "$root/cmd/barkpark/testdata" \
    "$root/.codex/skills/epic-cycle/scripts" "$root/design" "$root/web/__tests__/fixtures"
  : >"$root/internal/taskboard/components.go"
  : >"$root/internal/taskboard/tokens_gen.go"
  : >"$root/internal/chat/testdata/workflow_summary.json"
  : >"$root/internal/pdrender/testdata/blocks.json"
  : >"$root/cmd/barkpark/testdata/preview-parity.json"
  : >"$root/.codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py"
  : >"$root/design/status-manifest.json"
  : >"$root/design/tokens.json"
  : >"$root/web/__tests__/fixtures/preview-parity.json"
  # Ten covered reads from api/test -> test-dir 10, test-cwd 10 (floors: 8, 8).
  cat >"$root/api/test/barkpark/covered_test.exs" <<'EX'
  @a Path.expand("../../../internal/taskboard/components.go", __DIR__)
  @b Path.expand("../../../internal/taskboard/tokens_gen.go", __DIR__)
  @c Path.expand("../../../internal/chat/testdata/workflow_summary.json", __DIR__)
  @d Path.expand("../../../.codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py", __DIR__)
  @e Path.expand("../../../design/status-manifest.json", __DIR__)
  @f Path.expand("../../../web/__tests__/fixtures/preview-parity.json", __DIR__)
  @g Path.expand("../../../internal/chat/testdata", __DIR__)
  @h Path.expand("../../../web/__tests__/fixtures", __DIR__)
  @j Path.expand("../../../internal/pdrender/testdata/blocks.json", __DIR__)
  @k Path.expand("../../../cmd/barkpark/testdata/preview-parity.json", __DIR__)
  @i File.read!("../design/status-manifest.json")
  # traversal-attack fixtures: asserted on, never read — must NOT be counted
  @x "../etc/passwd"
  @y "../up"
EX
  # Six covered reads from api/lib -> lib-dir 6, lib-cwd 6 (floors: 5, 5). The
  # real tree reads across both halves (mix tasks in api/lib, tests in
  # api/test); a fixture that only had one half could not exercise the doors
  # that catch the other half going blind.
  cat >"$root/api/lib/barkpark/covered.ex" <<'EX'
  @a Path.expand("../../../design/status-manifest.json", __DIR__)
  @b Path.expand("../../../design/tokens.json", __DIR__)
  @c Path.expand("../../../cmd/barkpark/testdata/preview-parity.json", __DIR__)
  @d Path.expand("../../../internal/pdrender/testdata/blocks.json", __DIR__)
  @e Path.expand("../../../internal/taskboard/components.go", __DIR__)
  @f Path.expand("../../../internal/chat/testdata/workflow_summary.json", __DIR__)
EX
}

echo "elixir-path-escape-check.test.sh"
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
#
# NO HARD-CODED POPULATION HERE. This assertion used to read `-ge 20` under a
# label claiming the measured population was 24 — a PASSING test whose own name
# was stale by five (the tree measures 29), and a threshold nine under the live
# population, so the census could have lost nine reads and still said ok. Both
# halves are DERIVED now, and neither can rot:
#   (a) --check's count must agree with --list-escapes' own distinct count. Two
#       modes, one census; if they disagree, one of them is lying.
#   (b) every idiom the script declares a floor for must actually clear that
#       floor in --list-escapes. Computed from --list-escapes and --print-floors,
#       so it does not just re-read --check's arithmetic back to itself.
n="$(printf '%s' "$out" | sed -n 's/^elixir-path-escape-check: \([0-9]*\) distinct.*/\1/p')"
listed="$("$SCRIPT" --list-escapes | cut -f1 | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
if [ "${n:-0}" = "$listed" ] && [ "${n:-0}" -gt 0 ]; then
  ok "--check's count ($n) agrees with --list-escapes' distinct census"
else
  no "--check says ${n:-0} reads, --list-escapes says $listed — the two modes disagree"
fi
census_tagged="$("$SCRIPT" --list-escapes | cut -f1,3 | sed '/^$/d' | sort -u)"
floors="$("$SCRIPT" --print-floors)"
thin_idioms=0
while IFS= read -r frow; do
  [ -n "$frow" ] || continue
  fidiom="${frow%%	*}"
  fmin="${frow##*	}"
  fgot="$(printf '%s\n' "$census_tagged" | awk -F'\t' -v k="$fidiom" '$2 == k' | wc -l | tr -d ' ')"
  if [ "$fgot" -ge "$fmin" ]; then
    ok "idiom $fidiom is live: $fgot read(s), floor $fmin"
  else
    no "idiom $fidiom resolved $fgot read(s) but its floor is $fmin — this door is blind"
    thin_idioms=$((thin_idioms + 1))
  fi
done <<<"$floors"
if [ "$thin_idioms" -eq 0 ]; then
  ok "every declared idiom clears its own floor on the real tree"
else
  no "$thin_idioms idiom(s) are under their floor"
fi
if has "$out" "exempt: scripts/claude-pinned-version.txt"; then
  ok "the :real_binary-only read is reported as exempt, not silently dropped"
else
  no "exemption not reported"
fi
echo

# ── case 2: the census carries the three families the obvious list misses ───
echo "case 2: the census carries the three easily-missed families"
census="$("$SCRIPT" --list-escapes | cut -f1 | sort -u)"
for want in internal/taskboard/components.go internal/chat/testdata \
  .codex/skills/epic-cycle/scripts/run_concurrency_benchmark.py; do
  if has_line "$census" "$want"; then
    ok "census carries $want"
  else
    no "census MISSES $want"
  fi
done
# and the two measured over-inclusions are absent from the declared sets
sets="$("$SCRIPT" --print-set test)"
if has_line "$sets" 'templates/\*\*'; then
  no "repo-root templates/** is declared — measured over-inclusion"
else
  ok "repo-root templates/** is not declared"
fi
if has_line "$sets" 'scripts/claude-pinned-version.txt'; then
  no "scripts/claude-pinned-version.txt is declared — measured over-inclusion"
else
  ok "scripts/claude-pinned-version.txt is not declared"
fi
echo

# ── case 3: an uncovered repo-root read REDS (tracked file) ─────────────────
echo "case 3: an uncovered repo-root read reds (mutation)"
FX="$TMPROOT/tracked"
make_fixture "$FX"
mkdir -p "$FX/nowhere"
: >"$FX/nowhere/secret.json"
cat >"$FX/api/test/barkpark/escaping_test.exs" <<'EX'
  @bad Path.expand("../../../nowhere/secret.json", __DIR__)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc (non-zero) on an uncovered read"; else no "PASSED with an uncovered read — vacuous"; fi
if has "$out" "UNCOVERED repo-root read: nowhere/secret.json"; then
  ok "names the uncovered path"
else
  no "did not name the uncovered path: $out"
fi
if has "$out" "read from: api/test/barkpark/escaping_test.exs"; then
  ok "names the file that reads it"
else
  no "did not attribute the read: $out"
fi
echo

# ── case 4: THE UNTRACKED CASE — the measured vacuous pass ──────────────────
# Same mutation, but inside a real git repo where the offending fixture is
# present on disk and NOT tracked. A `git ls-files` enumeration reports clean
# here; a working-tree enumeration reds.
echo "case 4: an uncovered read in an UNTRACKED file still reds"
FX2="$TMPROOT/untracked"
make_fixture "$FX2"
git -C "$FX2" init -q
git -C "$FX2" add -A >/dev/null 2>&1
git -C "$FX2" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
mkdir -p "$FX2/nowhere"
: >"$FX2/nowhere/secret.json"
cat >"$FX2/api/test/barkpark/untracked_escape_test.exs" <<'EX'
  @bad Path.expand("../../../nowhere/secret.json", __DIR__)
EX
# sanity: the fixture really is invisible to git
if git -C "$FX2" ls-files --error-unmatch api/test/barkpark/untracked_escape_test.exs >/dev/null 2>&1; then
  no "fixture setup wrong — the mutation file is TRACKED, so this case proves nothing"
else
  ok "fixture is genuinely untracked (git ls-files does not see it)"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX2" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — the working-tree scan sees untracked code"
else
  no "PASSED on an untracked uncovered read — this is the git ls-files vacuous pass (D31)"
fi
if has "$out" "read from: api/test/barkpark/untracked_escape_test.exs"; then
  ok "attributes the read to the untracked file"
else
  no "did not attribute the untracked read: $out"
fi
echo

# ── case 5: a neutered scanner reds on the floor, never reports clean ───────
echo "case 5: the min-escapes floor catches a neutered scanner"
FX3="$TMPROOT/thin"
mkdir -p "$FX3/api/lib" "$FX3/api/test" "$FX3/design"
: >"$FX3/design/status-manifest.json"
cat >"$FX3/api/test/one_test.exs" <<'EX'
  @a Path.expand("../../design/status-manifest.json", __DIR__)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX3" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
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
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX3" ELIXIR_ESCAPE_IDIOM_MIN='test-dir	0
test-cwd	0
lib-dir	0
lib-cwd	0' "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "ELIXIR_ESCAPE_IDIOM_MIN in the environment cannot lower the floors"
else
  no "the floors were lowered by an env var — that is a one-line CI bypass"
fi
echo

# ── case 5b: THE PARTIAL BLINDING — one door goes dark, on the REAL tree ────
# This is the case the old whole-population floor could not have: it never
# exercised anything but a TOTAL collapse (case 5's one-read fixture), so it
# certified a floor that could not fire on the failure its own comment named.
#
# Measured on origin/main at the time this case was written: deleting `api/test`
# from list_escapes' `find` — ONE WORD — collapsed the census 29 -> 11, a 62%
# loss of scanner coverage, and the ratchet printed `OK` and exited 0 inside the
# REQUIRED Elixir gate. The surviving api/lib reads alone cleared the old floor
# of 8. So the mutation is applied to a COPY of the real script and run against
# the REAL repository: a partially-blinded scanner must red, and it must accuse
# itself rather than the repo.
echo "case 5b: blinding ONE door (api/test) reds on the real tree"
MUT="$TMPROOT/mutant-no-api-test.sh"
sed 's|find api/lib api/test|find api/lib|' "$SCRIPT" >"$MUT"
if ! cmp -s "$MUT" "$SCRIPT"; then
  ok "the mutation applied (the find in list_escapes really changed)"
else
  no "the mutation did NOT apply — this case would prove nothing"
fi
out="$(ELIXIR_PATH_ESCAPE_ROOT="$REAL_ROOT" bash "$MUT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) when the api/test door goes blind"
else
  no "a scanner that lost api/test reported CLEAN — the exact origin/main defect"
fi
if has "$out" "idiom 'test-dir' resolved only 0 repo-root read"; then
  ok "names the blind door: test-dir"
else
  no "did not name the blind door: $out"
fi
if has "$out" "idiom 'test-cwd' resolved only 0 repo-root read"; then
  ok "names the blind door: test-cwd"
else
  no "did not name the blind door: $out"
fi
if has "$out" "SCANNER is broken, not the repo clean"; then
  ok "accuses the scanner, not the repository"
else
  no "wrong diagnosis: $out"
fi
# …and the surviving door is reported LIVE in the same breath, so the operator
# can see which half went dark instead of guessing.
if has "$out" "idiom lib-dir: "; then
  ok "still reports the surviving door's population"
else
  no "no per-idiom breakdown to diagnose from: $out"
fi
echo

# ── case 5c: a door with NO floor entry is an unguarded door ────────────────
# The floor table doubles as the idiom inventory. Widening list_escapes' `find`
# without adding a floor would ship a new door that nothing can catch going
# blind, so the tag it emits (`other-*`) must red on sight.
echo "case 5c: a scanner door with no floor entry reds"
MUT2="$TMPROOT/mutant-undeclared-door.sh"
sed 's|find api/lib api/test|find api/lib api/test scripts|' "$SCRIPT" >"$MUT2"
FX4="$TMPROOT/newdoor"
make_fixture "$FX4"
mkdir -p "$FX4/scripts"
cat >"$FX4/scripts/probe.exs" <<'EX'
  @a Path.expand("../design/status-manifest.json", __DIR__)
EX
out="$(ELIXIR_PATH_ESCAPE_ROOT="$FX4" bash "$MUT2" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) when the scanner emits an undeclared idiom"
else
  no "an undeclared door shipped with no floor and the ratchet said OK"
fi
if has "$out" "has no entry in ELIXIR_ESCAPE_IDIOM_MIN"; then
  ok "names the unguarded door"
else
  no "did not name the unguarded door: $out"
fi
echo

# ── case 6: --match, the predicate elixir.yml actually dispatches on ────────
echo "case 6: --match agrees with the declared sets"
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
check_match "api/lib/barkpark.ex" compile true
check_match "design/status-manifest.json" compile true
check_match ".github/workflows/elixir.yml" compile true
check_match "scripts/elixir-path-escape-check.sh" compile true
check_match "docs/ops/merge-gates.md" compile false
check_match "docs/ops/merge-gates.md" test false
check_match "README.md" test false
check_match "web/src/app/page.tsx" test false
check_match "internal/taskboard/components.go" test true
check_match "internal/taskboard/components.go" compile false
check_match "internal/chat/testdata" test true
check_match "docs/openapi.json" test true
check_match "docs/api-v1.md" test true
# exact-file entries must not match by prefix
check_match "docs/openapi.json.bak" test false
check_match "scripts/async_env_seam_scan.exs.orig" test false
# Every compile path is also a test path. The invariant belongs to the SETS,
# not to any `needs` edge between the jobs: compile ⊆ test must hold however
# the graph is wired. elixir.yml's dispatcher asserts it at runtime and hard-
# fails ("compile=true but test=…"), so a set edit that broke containment would
# deadlock every api/** PR rather than mis-dispatch one. Proven statically here
# so that failure lands in the harness instead of on a stranger's PR.
while IFS= read -r g; do
  [ -n "$g" ] || continue
  probe="${g%/\*\*}"
  case "$g" in */'**') probe="$probe/probe.txt" ;; esac
  check_match "$probe" test true
done <<EOF
$("$SCRIPT" --print-set compile)
EOF
echo

# ── case 7: a bad set name is an error, not a silent false ──────────────────
echo "case 7: an unknown set name errors"
out="$("$SCRIPT" --match nonsense <<<'api/x' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown set"; else no "unknown set returned '$out' instead of failing"; fi
out="$("$SCRIPT" --bogus-flag 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown flag"; else no "unknown flag silently accepted"; fi
echo

# ── case 8: elixir.yml's structural invariants ─────────────────────────────
# These are the ones a reviewer's eye slides over and a required-check spec
# cannot recover from. Asserted mechanically, against the real file.
echo "case 8: elixir.yml structural invariants"
WF="$REAL_ROOT/.github/workflows/elixir.yml"
if [ ! -f "$WF" ]; then
  no "elixir.yml not found at $WF"
else
  # Written to a file, not captured inline: bash 3.2 (macOS, and therefore the
  # local gate) mis-parses a heredoc inside a command substitution.
  #
  # The emitter itself is a FILE rather than an inline heredoc so the mutation
  # proof below can run the very same code over deliberately-broken copies of
  # elixir.yml. A detector that is never pointed at a broken input has not been
  # shown to detect anything.
  FACTS="$TMPROOT/elixir-yml-facts.txt"
  EMIT="$TMPROOT/emit-elixir-yml-facts.py"
  cat >"$EMIT" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
out = open(sys.argv[2], "w")
on = wf.get(True, wf.get("on"))            # PyYAML parses bare `on:` as True
jobs = wf["jobs"]
def emit(k, v): out.write(f"{k}={v}\n")
# D18: a workflow-level paths filter deadlocks any required name pointing here.
emit("workflow_paths", any(
    isinstance(v, dict) and ("paths" in v or "paths-ignore" in v)
    for v in (on or {}).values()))
agg = jobs.get("elixir-gate", {})
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
# …and the mirror hazard, which the allow-set cannot see: a BLOCKING job added
# to elixir.yml but never wired into `needs`. The aggregator cannot judge a job
# nobody told it about, so it would green while that job is red.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != "elixir-gate"}
emit("blocking_not_in_needs", ",".join(sorted(blocking - set(agg.get("needs", [])))))
# D36 — THE OTHER HALF OF THAT GUARD. `blocking_not_in_needs` proves a job
# reached the aggregator's `needs`. Nothing proved the step body actually
# JUDGES it, and reaching `needs` alone changes nothing: `needs.<job>.result`
# is only consulted if the job is bound to a step env var AND that var is
# passed to `decide`. Measured: add a blocking job, wire it into `needs` and
# into `env:` as R_CEILING but omit its `decide` line, and every fact above is
# byte-identical to a clean tree while the real extracted step body greens at
# EXIT=0 with R_CEILING=failure. So walk the whole chain per job —
#   needs entry -> env var bound to needs.<job>.result -> decide's 2nd argument
# — and name every job that falls out of it. The decide side keys on the
# SECOND positional argument, which is label-independent: the first argument is
# a human label ("changes (dispatcher)") that deliberately does not match the
# job name, so matching on it would be a guard that reds on a rename.
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
# sets it is computed from are populated: a regex that stops matching, or a
# `needs` list read as empty, would report a serene "" forever. These make a
# NEUTERED detector red instead of clean.
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
for n in ("mix-test", "mix-prod-compile", "validation-perf"):
    emit(f"if::{n}", str(jobs.get(n, {}).get("if", "")))
out.close()
PY
  python3 "$EMIT" "$WF" "$FACTS"
  fact() { sed -n "s|^$1=||p" "$FACTS"; }
  assert_fact() {
    if [ "$(fact "$1")" = "$2" ]; then ok "$1 = $2"; else no "$1 = '$(fact "$1")', wanted '$2'"; fi
  }
  # A lower bound, never an equality: pinning the exact roster here would red
  # this harness the day a legitimate blocking job is added (S4's format
  # ceiling is the next one), which is churn, not safety. The bound only has
  # to exclude ZERO — the value a broken parser returns.
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
  assert_fact workflow_paths False
  assert_fact agg_present True
  assert_fact agg_matrix False
  assert_fact agg_if "always()"
  assert_fact agg_name "Elixir gate"
  assert_fact coe_jobs format
  assert_fact coe_in_needs ""
  # Every blocking job must be in the aggregator's needs set. Without this, a
  # future slice (S4's format ceiling is the next one) can add a blocking job
  # and the required context stays green while that job reds — the aggregator's
  # one structural blind spot, closed here rather than left to a reviewer's eye.
  assert_fact blocking_not_in_needs ""
  # …and every job that IS in needs must actually be judged (D36). Empty means
  # every needs entry survives needs -> env -> decide. The three cardinalities
  # are the anti-vacuity companions: without them a detector that matched
  # nothing would report this same serene "".
  assert_fact needs_without_decide ""
  assert_fact_min needs_count 5
  assert_fact_min needs_results_count 5
  assert_fact_min decide_consumes_count 5
  assert_fact dispatcher_if ""
  assert_fact dispatcher_matrix False
  assert_fact dispatcher_outputs "compile,test"
  assert_fact escape_if ""
  assert_fact escape_needs ""
  assert_fact "if::mix-test" "needs.changes.outputs.test == 'true'"
  assert_fact "if::mix-prod-compile" "needs.changes.outputs.compile == 'true'"
  assert_fact "if::validation-perf" "needs.changes.outputs.compile == 'true'"

  # ── D36 mutation proof: the fifth fact must FIRE, and must go quiet ────────
  # Four deliberately-broken copies of the REAL elixir.yml, one per direction
  # the guard has to tell apart. This is the only thing separating a guard from
  # a decoration: `needs_without_decide = ""` above proves nothing unless the
  # same emitter, on the same file, returns a non-empty answer when the wiring
  # is genuinely broken. The mutation is the one measured in charter D36 — a
  # blocking `format-ceiling` job, added in three increasingly-complete stages.
  MUT="$TMPROOT/mutate-elixir-yml.py"
  cat >"$MUT" <<'PY'
import sys, yaml
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(src))
agg = wf["jobs"]["elixir-gate"]
step = next(s for s in agg["steps"] if "run" in s)
assert mode in ("clean", "needs", "env", "wired"), mode   # a typo'd mode is not a pass
if mode in ("needs", "env", "wired"):
    # a BLOCKING job (no continue-on-error), wired into the aggregator's needs
    wf["jobs"]["format-ceiling"] = {"runs-on": "ubuntu-latest",
                                    "steps": [{"run": "exit 1"}]}
    agg["needs"] = list(agg["needs"]) + ["format-ceiling"]
if mode in ("env", "wired"):
    step.setdefault("env", {})["R_CEILING"] = "${{ needs.format-ceiling.result }}"
if mode == "wired":
    step["run"] = step["run"].replace(
        'decide "changes (dispatcher)"',
        'decide "format ceiling"         "${R_CEILING}" "NEVER"\n'
        'decide "changes (dispatcher)"', 1)
yaml.safe_dump(wf, open(dst, "w"))
PY
  # direction <mode> <expected needs_without_decide>
  direction() {
    local mode="$1" want="$2" f="$TMPROOT/mut-$1.yml" ff="$TMPROOT/mut-$1.facts" got
    # `clean` goes through the same load/dump round-trip as the three broken
    # copies, so the ONLY variable between the four is the mutation itself —
    # not a YAML-dumper artefact.
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
  direction needs "format-ceiling"               # in needs, no env binding
  direction env   "format-ceiling"               # in needs + env, never decided
  direction wired ""                             # fully wired — silent again
fi
echo

# ── case 9: the aggregator's allow-set, driven by mutation ─────────────────
# The step body is EXTRACTED FROM elixir.yml and executed, so this cannot
# drift from what CI runs (charter D26: a harness must execute the step body,
# not a paraphrase of it). Each case supplies exactly the env GitHub would.
echo "case 9: the aggregator decides, and can be made red on purpose"
AGG="$TMPROOT/elixir-gate-step.sh"
python3 - "$WF" "$AGG" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["elixir-gate"]["steps"] if "run" in s][0]
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
  # The exit code ALONE is not a verdict. Eight of the ten cases below expect
  # exit 1 — and a step body that never decided anything exits 1 too: an
  # unbound variable under `set -u`, a syntax error, a `decide` that was
  # renamed out from under its call sites. Every one of those would have read
  # as `ok` here while proving nothing about the allow-set. So also require the
  # aggregator to have reached its own conclusion, in the polarity expected.
  local verdict
  if [ "$want" -eq 0 ]; then
    verdict="Elixir gate: every upstream job either succeeded"
  else
    verdict="::error::Elixir gate: at least one upstream job is not in the allow-set"
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

# (a) the happy path: a full api/** PR, everything ran and passed
gate "full run, all green" 0 \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true

# (b) a legitimate docs-only skip greens the required context
gate "docs-only PR, expensive jobs legitimately skipped" 0 \
  R_CHANGES=success R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=false O_TEST=false
gate_says "legitimately not dispatched" "…and says so, rather than claiming the suite passed"

# (c) an upstream FAILURE reds it
gate "mix-test failed" 1 \
  R_CHANGES=success R_TEST=failure R_PROD=skipped R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
gate_names "mix-test" "validation-perf"

# (d) THE BYPASS THIS SLICE EXISTS TO CLOSE: prod-compile `skipped` only
#     because its dependency died, while the dispatcher said it WAS needed.
gate "prod-compile skipped behind a live gate (upstream died)" 1 \
  R_CHANGES=success R_TEST=success R_PROD=skipped R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
gate_says "its gate is 'true', not 'false'" "…and names the reason (a skip is not a pass)"
# …and the SKIP arm accumulates too, not just the failure arm: this red never
# passes through `failure`, so an accumulator wired only there would leave the
# annotation contentless on exactly the bypass this shape exists to close.
gate_names "mix-prod-compile" "mix-test"

# (e) the dispatcher itself failing reds it, with empty outputs
gate "dispatcher failed, outputs empty" 1 \
  R_CHANGES=failure R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE= O_TEST=

# (f) the unfiltered ratchet may never skip
gate "path-escape skipped" 1 \
  R_CHANGES=success R_TEST=success R_PROD=success R_PERF=success R_ESCAPE=skipped \
  O_COMPILE=true O_TEST=true

# (g) cancelled is not success
gate "a cancelled upstream" 1 \
  R_CHANGES=success R_TEST=cancelled R_PROD=skipped R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true
gate_says "CANCELLED — this job did not fail" "…and the step log names CANCELLATION (the D57 arm), not a generic failure"
gate_names "mix-test (cancelled, not failed)" "validation-perf"

# (h) anything unrecognised is red — "cannot tell" is a failure, not a pass
gate "an unrecognised result value" 1 \
  R_CHANGES=success R_TEST=neutral R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true

# (i) an EMPTY result (a job silently dropped from `needs`) is red
gate "an empty result string" 1 \
  R_CHANGES=success R_TEST= R_PROD=success R_PERF=success R_ESCAPE=success \
  O_COMPILE=true O_TEST=true

# (j) a garbage gate value must not license a skip
gate "skip against a garbage gate value" 1 \
  R_CHANGES=success R_TEST=skipped R_PROD=skipped R_PERF=skipped R_ESCAPE=success \
  O_COMPILE=maybe O_TEST=maybe

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
mkdir -p "$DR/api/lib" "$DR/docs" "$DR/internal/taskboard" "$DR/scripts"
cp "$SCRIPT" "$REAL_ROOT/scripts/elixir-path-escape-check.test.sh" "$DR/scripts/"
: >"$DR/api/lib/a.ex"
# NON-EMPTY on purpose: the rename cases below need git's rename detection to
# actually fire, and an empty blob is not a rename source worth the name.
printf 'moved-a\nmoved-b\nmoved-c\n' >"$DR/api/lib/moved.ex"
: >"$DR/docs/guide.md"
: >"$DR/internal/taskboard/components.go"
git -C "$DR" init -q
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
BASE_SHA="$(git -C "$DR" rev-parse HEAD)"

# dispatch <label> <expected-rc> <expected-compile> <expected-test> <event> <base>
dispatch() {
  local label="$1" want="$2" wc="$3" wt="$4" ev="$5" bs="$6"
  local rc gotc gott
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
  gotc="$(sed -n 's/^compile=//p' "$TMPROOT/gh_output")"
  gott="$(sed -n 's/^test=//p' "$TMPROOT/gh_output")"
  if [ "$gotc" = "$wc" ] && [ "$gott" = "$wt" ]; then
    ok "  …emits compile=$gotc test=$gott"
  else
    no "  …emitted compile=$gotc test=$gott, wanted compile=$wc test=$wt"
  fi
}

# a docs-only PR is the whole point of the shim: skip the suite, honestly
git -C "$DR" checkout -q -b docs-only
: >"$DR/docs/another.md"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm docs >/dev/null 2>&1
dispatch "docs-only PR" 0 false false pull_request "$BASE_SHA"

# a Go glyph-table change selects the TEST set but not the compile set — the
# family the obvious `api/**` filter silently drops (charter D31)
git -C "$DR" checkout -q -b taskboard "$BASE_SHA"
printf 'x\n' >"$DR/internal/taskboard/components.go"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm glyphs >/dev/null 2>&1
dispatch "internal/taskboard-only PR" 0 false true pull_request "$BASE_SHA"

# an api/** change selects everything
git -C "$DR" checkout -q -b apichange "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/a.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm api >/dev/null 2>&1
dispatch "api/** PR" 0 true true pull_request "$BASE_SHA"

# push to main never skips, regardless of what changed
dispatch "push event" 0 true true push ""

# ── THE FIVE FALSE-GREEN CLASSES the plain `--name-only` producer let through ─
# Every probe above this line is ASCII and rename-free, which is exactly why the
# harness could never have caught either family — and `Elixir gate` is a
# REGISTERED, enforced-today required context, so a false `compile=false
# test=false` here skips the whole suite under a green check. `git diff
# --name-only` QUOTES a path containing `"` (even under core.quotepath=false),
# and rename detection prints only the DESTINATION. Both classify FALSE on the
# pre-fix line.

# (1) a DOUBLE-QUOTE path inside the declared set. Not merely a non-ASCII one:
#     core.quotepath=false silences the octal escaping and leaves this class
#     wide open, so a fix tested only against é would certify a hole.
git -C "$DR" checkout -q -b dquote "$BASE_SHA"
printf 'x\n' >"$DR/api/lib/we\"ird.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm dquote >/dev/null 2>&1
dispatch 'a path containing a double quote' 0 true true pull_request "$BASE_SHA"

# (2) a rename OUT of the declared set. Compiled code just left api/** — the
#     suite MUST run — but rename detection names only docs/.
git -C "$DR" checkout -q -b renameout "$BASE_SHA"
git -C "$DR" mv api/lib/moved.ex docs/moved.ex >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renameout >/dev/null 2>&1
dispatch "a rename OUT of the declared set" 0 true true pull_request "$BASE_SHA"

# (3) …and a rename INTO the set still classifies true — `--no-renames` prints
#     BOTH sides, so closing (2) must not have cost the obvious direction.
git -C "$DR" checkout -q -b renamein "$BASE_SHA"
git -C "$DR" mv docs/guide.md api/lib/guide.md >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renamein >/dev/null 2>&1
dispatch "a rename INTO the declared set" 0 true true pull_request "$BASE_SHA"

# THE FAILURE PATHS — the polarity that makes the shim safe.
# An empty diff is the ONE "cannot tell" that does not fail: a revert pair or a
# branch-sync PR nets to nothing and is perfectly legal, and the old ::error::
# left its author with a permanently red required context and no self-service
# fix. It dispatches TRUE — the full suite, measured 9m31s-16m29s: expensive,
# never wrong. Everything else still reds.
git -C "$DR" checkout -q -b emptydiff "$BASE_SHA"
dispatch "empty diff (base == HEAD)" 0 true true pull_request "$(git -C "$DR" rev-parse HEAD)"
gate_says "changed-file set is EMPTY" "  …and names the shape"
gate_says "::warning" "  …as a WARNING, not a brick"
gate_says "9m31s-16m29s" "  …and names the cost it just chose to pay"
dispatch "unresolvable base sha" 1 - - pull_request 0000000000000000000000000000000000000000
gate_says "not resolvable in this checkout" "  …and refuses to guess a base"
dispatch "missing base sha" 1 - - pull_request ""
gate_says "carries no base sha" "  …and says why"

# a base with NO common ancestor: `git diff base...HEAD` exits 128 with a bare
# `fatal: … no merge base` and zero annotation. Named, not fatalled.
git -C "$DR" checkout -q --orphan noancestor >/dev/null 2>&1
git -C "$DR" rm -rq --cached . >/dev/null 2>&1 || true
rm -rf "${DR:?}/api" "${DR:?}/docs" "${DR:?}/internal"
mkdir -p "$DR/api/lib"
printf 'z\n' >"$DR/api/lib/orphan.ex"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm orphan >/dev/null 2>&1
dispatch "a base with no common ancestor" 1 - - pull_request "$BASE_SHA"
gate_says "share NO common ancestor" "  …and names the condition, not a raw git fatal"
gate_says "refusing a two-dot fallback" "  …and refuses the fallback that sweeps in the whole base"
echo

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
