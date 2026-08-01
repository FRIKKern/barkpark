#!/usr/bin/env bash
#
# console-path-escape-check.test.sh — the harness for the console path ratchet
# AND for console-harness.yml's skip shim.
#
# Charter D26: a harness nobody runs is not a ratchet. This one is executed by
# console-harness.yml's `path-escape` job (unfiltered, so it can never go dark)
# and by the slice gate, via `console-path-escape-check.sh --selftest`.
#
# The cases that matter are the ones that prove the instruments can FAIL:
#   * an uncovered repo-root read must red                  (case 3)
#   * an uncovered read in an UNTRACKED file must red       (case 4)
#   * a neutered scanner must red rather than report clean  (case 5)
#   * the aggregator must red on every not-a-pass result    (case 9)
#   * the dispatcher must red rather than emit all-false    (case 10)
#   * the cssom wrapper must tell REFUSED from DEFECT, and
#     green neither                                         (case 11)
# A harness with only green cases is the defect, not the proof.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/console-path-escape-check.sh"
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
# ELSE branch — reporting a FALSE failure for a match that did occur. A
# here-string has no writer process to kill, so these are deterministic on every
# platform. Use them for EVERY match against a captured string.
has()      { grep -q  -- "$2" <<<"$1"; }   # substring/BRE anywhere in $1
has_line() { grep -qx -- "$2" <<<"$1"; }   # a whole line of $1 equals the BRE

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/console-path-escape-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# Build a synthetic mini-repo whose console tree reads known repo-root paths,
# in BOTH idioms the real harness uses: the literal `path.join(REPO_ROOT, "…")`
# and the interpolated DATA TABLE (guard / measured_by / measured_in_ci).
make_fixture() {
  local root="$1"
  mkdir -p "$root/cloud/priv/static/__preview__" \
    "$root/internal/taskboard/testdata" "$root/internal/pdrender/testdata" \
    "$root/.github/workflows" "$root/design" \
    "$root/cloud/test/barkpark_cloud/web"
  : >"$root/internal/taskboard/testdata/styleguide_lifecycle.txt"
  : >"$root/internal/pdrender/testdata/styleguide_tokens.txt"
  : >"$root/.github/workflows/cloud.yml"
  : >"$root/design/emit-fence.test.mjs"
  : >"$root/cloud/test/barkpark_cloud/web/router_test.exs"
  : >"$root/cloud/test/barkpark_cloud/web/router_oauth_test.exs"
  # Six covered reads — comfortably over the floor of 4 so the coverage cases
  # exercise coverage, not the floor.
  cat >"$root/cloud/priv/static/__app.test.mjs" <<'JS'
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const LIFECYCLE_FIXTURE = path.join(REPO_ROOT, "internal/taskboard/testdata/styleguide_lifecycle.txt");
const TOKENS_FIXTURE = path.join(REPO_ROOT, "internal/pdrender/testdata/styleguide_tokens.txt");
JS
  cat >"$root/cloud/priv/static/__preview__/seal-predicate.mjs" <<'JS'
const KNOWN_DEFECTS = [
  {
    id: 'a',
    measured_by: ['cloud/test/barkpark_cloud/web/router_test.exs'],
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test', paths: 'cloud/**' },
  },
  {
    id: 'b',
    measured_by: [
      'cloud/test/barkpark_cloud/web/router_oauth_test.exs',
      'cloud/test/barkpark_cloud/web/router_DELETED_test.exs',
    ],
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test', paths: 'cloud/**' },
  },
  { id: 'c', guard: 'design/emit-fence.test.mjs' },
];
const guardPath = `${REPO}/${d.guard}`;
JS
}

echo "console-path-escape-check.test.sh"
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
n="$(printf '%s' "$out" | sed -n 's/^console-path-escape-check: \([0-9]*\) distinct.*/\1/p')"
if [ "${n:-0}" -ge 8 ]; then
  ok "resolved $n repo-root reads (measured population is 9)"
else
  no "resolved only ${n:-0} repo-root reads — scanner is under-matching"
fi
echo

# ── case 2: the census carries the three families NOBODY had declared ───────
# These are the reads the old workflow-level filters missed entirely: the seal
# predicate's tests pass `--repo <the real repo root>`, so the predicate reaches
# all three. Deleting cloud.yml's paths key reds 7 of 31 harness tests; moving
# emit-fence.test.mjs reds 1; moving a measured_by file reds 6.
echo "case 2: the census carries the three previously-undeclared families"
census="$("$SCRIPT" --list-escapes | cut -f1 | sort -u)"
for want in .github/workflows/cloud.yml design/emit-fence.test.mjs \
  cloud/test/barkpark_cloud/web/router_test.exs; do
  if has_line "$census" "$want"; then
    ok "census carries $want"
  else
    no "census MISSES $want"
  fi
done
# …and the dispatcher predicate agrees with the census, which is the half that
# actually decides whether the harness runs.
m() { "$SCRIPT" --match "$2" <<<"$1"; }
for want in .github/workflows/cloud.yml design/emit-fence.test.mjs \
  cloud/test/barkpark_cloud/web/router_test.exs; do
  got="$(m "$want" console)"
  if [ "$got" = "true" ]; then
    ok "--match console: '$want' -> true"
  else
    no "--match console: '$want' -> $got, wanted true"
  fi
done
# The two internal/ entries are EXACT FILES, never internal/*/testdata/** —
# those trees carry hundreds of unrelated goldens and the harness reads two.
sets="$("$SCRIPT" --print-set console)"
if has_line "$sets" 'internal/taskboard/testdata/styleguide_lifecycle.txt'; then
  ok "internal/taskboard read is declared as an exact file"
else
  no "the taskboard golden is not declared as an exact file"
fi
if has_line "$sets" 'internal/pdrender/testdata/\*\*'; then
  no "internal/pdrender/testdata/** is declared — measured over-inclusion"
else
  ok "internal/pdrender/testdata/** is not declared (over-inclusion)"
fi
echo

# ── case 3: an uncovered repo-root read REDS (tracked file) ─────────────────
echo "case 3: an uncovered repo-root read reds (mutation)"
FX="$TMPROOT/tracked"
make_fixture "$FX"
mkdir -p "$FX/nowhere"
: >"$FX/nowhere/secret.json"
cat >"$FX/cloud/priv/static/escaping.test.mjs" <<'JS'
const BAD = path.join(REPO_ROOT, "nowhere/secret.json");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FX" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc (non-zero) on an uncovered read"; else no "PASSED with an uncovered read — vacuous"; fi
if has "$out" "UNCOVERED repo-root read: nowhere/secret.json"; then
  ok "names the uncovered path"
else
  no "did not name the uncovered path: $out"
fi
if has "$out" "read from: cloud/priv/static/escaping.test.mjs"; then
  ok "names the file that reads it"
else
  no "did not attribute the read: $out"
fi
# …and the DATA TABLE half of the scanner must red too. This is the idiom a
# literal-string scanner cannot see: the read site is `${REPO}/${d.guard}`.
FXT="$TMPROOT/table"
make_fixture "$FXT"
mkdir -p "$FXT/elsewhere"
: >"$FXT/elsewhere/oracle.mjs"
cat >>"$FXT/cloud/priv/static/__preview__/seal-predicate.mjs" <<'JS'
const MORE = [{ id: 'd', guard: 'elsewhere/oracle.mjs' }];
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXT" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on an uncovered DATA TABLE read"
else
  no "PASSED with an uncovered guard: — the table walk is blind"
fi
if has "$out" "UNCOVERED repo-root read: elsewhere/oracle.mjs"; then
  ok "names the uncovered guard"
else
  no "did not name the uncovered guard: $out"
fi
# …and the WALK-UP idiom (`"../../../x"`, resolved against the reading file's
# own directory) must red too. Nothing in the tree writes reads that way today;
# it is the obvious next way out of cloud/priv/static, and a census that only
# saw yesterday's idioms is one refactor from blind.
FXW="$TMPROOT/walkup"
make_fixture "$FXW"
mkdir -p "$FXW/faraway"
: >"$FXW/faraway/table.json"
cat >"$FXW/cloud/priv/static/__preview__/walkup.mjs" <<'JS'
const BAD = readFileSync(new URL("../../../../faraway/table.json", import.meta.url));
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXW" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on an uncovered WALK-UP read"
else
  no "PASSED with an uncovered '../…' read — the walk-up idiom is invisible"
fi
if has "$out" "UNCOVERED repo-root read: faraway/table.json"; then
  ok "resolves the walk-up against the reading file's own directory"
else
  no "did not resolve the walk-up read: $out"
fi
# The existence filter keeps the mutation fixtures out: seal-predicate.test.mjs
# carries a deliberately-nonexistent measured_by entry, and it is asserted on,
# never read.
census_fx="$(CONSOLE_PATH_ESCAPE_ROOT="$FX" "$SCRIPT" --list-escapes | cut -f1 | sort -u)"
if has_line "$census_fx" 'cloud/test/barkpark_cloud/web/router_DELETED_test.exs'; then
  no "a nonexistent measured_by entry entered the census — the existence filter is off"
else
  ok "a nonexistent measured_by entry is not a read"
fi
# …and the multi-line measured_by array IS walked (the wrapped entry is real).
if has_line "$census_fx" 'cloud/test/barkpark_cloud/web/router_oauth_test.exs'; then
  ok "a WRAPPED measured_by array entry is in the census"
else
  no "the multi-line measured_by array was half-read"
fi
# …and THE TEMPLATE-LITERAL IDIOM, `${REPO}/some/path`, must red too. This is
# not a variant of the join(REPO, "…") grep: a backtick template carries no
# comma and no quotes, so that grep cannot see it. It is the shape the seal
# predicate's rung-2 leg A uses to read .github/required-checks.json — written
# by a SIBLING slice, on a branch this ratchet never saw. Measured on the merged
# pair before this case existed: the census reported "OK, 9 reads" with that
# read live and undeclared. A cross-slice blind spot is still a blind spot.
FXT="$TMPROOT/template"
make_fixture "$FXT"
mkdir -p "$FXT/policy"
: >"$FXT/policy/required.json"
cat >"$FXT/cloud/priv/static/__preview__/tmpl.mjs" <<'JS'
const p = `${REPO}/policy/required.json`;
const q = readFileSync(p, 'utf8');
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXT" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on an uncovered TEMPLATE-LITERAL read"
else
  no "PASSED with an uncovered \${REPO}/… read — the template idiom is invisible"
fi
if has "$out" "UNCOVERED repo-root read: policy/required.json"; then
  ok "resolves \${REPO}/… to a repo-relative path"
else
  no "did not resolve the template-literal read: $out"
fi
# The real read this idiom exists for is DECLARED, so the real tree stays green.
if printf '%s\n' "$("$SCRIPT" --print-set console)" | grep -qx '.github/required-checks.json'; then
  ok ".github/required-checks.json is in the declared set (the sibling slice's leg-A read)"
else
  no ".github/required-checks.json is not declared — the merged pair would red on main"
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
cat >"$FX2/cloud/priv/static/untracked.test.mjs" <<'JS'
const BAD = path.join(REPO_ROOT, "nowhere/secret.json");
JS
# sanity: the fixture really is invisible to git
if git -C "$FX2" ls-files --error-unmatch cloud/priv/static/untracked.test.mjs >/dev/null 2>&1; then
  no "fixture setup wrong — the mutation file is TRACKED, so this case proves nothing"
else
  ok "fixture is genuinely untracked (git ls-files does not see it)"
fi
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FX2" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — the working-tree scan sees untracked code"
else
  no "PASSED on an untracked uncovered read — this is the git ls-files vacuous pass (D31)"
fi
if has "$out" "read from: cloud/priv/static/untracked.test.mjs"; then
  ok "attributes the read to the untracked file"
else
  no "did not attribute the untracked read: $out"
fi
echo

# ── case 5: a neutered scanner reds on the floor, never reports clean ───────
echo "case 5: the min-escapes floor catches a neutered scanner"
FX3="$TMPROOT/thin"
mkdir -p "$FX3/cloud/priv/static" "$FX3/design"
: >"$FX3/design/emit-fence.test.mjs"
cat >"$FX3/cloud/priv/static/one.test.mjs" <<'JS'
const A = path.join(REPO_ROOT, "design/emit-fence.test.mjs");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FX3" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
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
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FX3" CONSOLE_ESCAPE_MIN=1 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "CONSOLE_ESCAPE_MIN in the environment cannot lower the floor"
else
  no "the floor was lowered by an env var — that is a one-line CI bypass"
fi
echo

# ── case 6: --match, the predicate console-harness.yml dispatches on ────────
echo "case 6: --match agrees with the declared set"
check_match() {
  local got
  got="$(m "$1" "$2")"
  if [ "$got" = "$3" ]; then
    ok "$2: '$1' -> $3"
  else
    no "$2: '$1' -> $got, wanted $3"
  fi
}
check_match "cloud/priv/static/app.js" console true
check_match "cloud/priv/static/__preview__/smoke.mjs" console true
check_match ".github/workflows/console-harness.yml" console true
check_match "scripts/console-path-escape-check.sh" console true
check_match "scripts/console-path-escape-check.test.sh" console true
check_match "cloud/test/barkpark_cloud/web/router_test.exs" console true
check_match "internal/taskboard/testdata/styleguide_lifecycle.txt" console true
check_match "docs/ops/merge-gates.md" console false
check_match "README.md" console false
check_match "api/lib/barkpark.ex" console false
check_match "web/src/app/page.tsx" console false
check_match ".github/workflows/elixir.yml" console false
# exact-file entries must not match by prefix
check_match ".github/workflows/cloud.yml.bak" console false
check_match "internal/pdrender/testdata/styleguide_tokens.txt.orig" console false
check_match "internal/pdrender/testdata/card.golden.json" console false
# every declared glob is matched by a probe under it
while IFS= read -r g; do
  [ -n "$g" ] || continue
  probe="${g%/\*\*}"
  case "$g" in */'**') probe="$probe/probe.txt" ;; esac
  check_match "$probe" console true
done <<EOF
$("$SCRIPT" --print-set console)
EOF
echo

# ── case 7: a bad set name is an error, not a silent false ──────────────────
echo "case 7: an unknown set name errors"
out="$("$SCRIPT" --match nonsense <<<'cloud/priv/static/app.js' 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown set"; else no "unknown set returned '$out' instead of failing"; fi
out="$("$SCRIPT" --bogus-flag 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "exit $rc on an unknown flag"; else no "unknown flag silently accepted"; fi
echo

# ── case 8: console-harness.yml's structural invariants ────────────────────
# These are the ones a reviewer's eye slides over and a required-check spec
# cannot recover from. Asserted mechanically, against the real file.
echo "case 8: console-harness.yml structural invariants"
WF="$REAL_ROOT/.github/workflows/console-harness.yml"
if [ ! -f "$WF" ]; then
  no "console-harness.yml not found at $WF"
else
  # Written to a file, not captured inline: bash 3.2 (macOS, and therefore the
  # local gate) mis-parses a heredoc inside a command substitution.
  #
  # The emitter itself is a FILE rather than an inline heredoc so the mutation
  # proof below can run the very same code over deliberately-broken copies of
  # console-harness.yml. A detector that is never pointed at a broken input has
  # not been shown to detect anything.
  FACTS="$TMPROOT/console-yml-facts.txt"
  EMIT="$TMPROOT/emit-console-yml-facts.py"
  cat >"$EMIT" <<'PY'
import re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
out = open(sys.argv[2], "w")
on = wf.get(True, wf.get("on"))            # PyYAML parses bare `on:` as True
jobs = wf["jobs"]
def emit(k, v): out.write(f"{k}={v}\n")
# D18: a workflow-level paths filter emits NO check run — the required name then
# sits "is expected." forever and the PR is BLOCKED with nothing to fix.
emit("workflow_paths", any(
    isinstance(v, dict) and ("paths" in v or "paths-ignore" in v)
    for v in (on or {}).values()))
agg = jobs.get("console-gate", {})
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
# to this workflow but never wired into `needs`. The aggregator cannot judge a
# job nobody told it about, so it would green while that job is red.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != "console-gate"}
emit("blocking_not_in_needs", ",".join(sorted(blocking - set(agg.get("needs", [])))))
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
for n in ("console-unit", "cssom-parity"):
    emit(f"if::{n}", str(jobs.get(n, {}).get("if", "")))
# The cssom wrapper's own vocabulary, read off the real step body.
cst = next((s for s in jobs.get("cssom-parity", {}).get("steps", [])
            if "cssom-parity.mjs" in str(s.get("run", ""))), {})
body = str(cst.get("run", ""))
emit("cssom_refused", "title=CSSOM parity REFUSED" in body)
emit("cssom_defect", "title=CSSOM parity DEFECT" in body)
emit("cssom_set_e", bool(re.search(r"set -[a-z]*e[a-z]*u?o? ", body)))
out.close()
PY
  python3 "$EMIT" "$WF" "$FACTS"
  fact() { sed -n "s|^$1=||p" "$FACTS"; }
  assert_fact() {
    if [ "$(fact "$1")" = "$2" ]; then ok "$1 = $2"; else no "$1 = '$(fact "$1")', wanted '$2'"; fi
  }
  # A lower bound, never an equality: pinning the exact roster here would red
  # this harness the day a legitimate blocking job is added, which is churn, not
  # safety. The bound only has to exclude ZERO — the value a broken parser
  # returns.
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
  assert_fact agg_name "Console gate"
  assert_fact coe_jobs ""
  assert_fact coe_in_needs ""
  # Every blocking job must be in the aggregator's needs set. Without this, a
  # future slice can add a blocking job and the required context stays green
  # while that job reds — the aggregator's one structural blind spot.
  assert_fact blocking_not_in_needs ""
  # …and every job that IS in needs must actually be judged (D36).
  assert_fact needs_without_decide ""
  assert_fact_min needs_count 4
  assert_fact_min needs_results_count 4
  assert_fact_min decide_consumes_count 4
  assert_fact dispatcher_if ""
  assert_fact dispatcher_matrix False
  assert_fact dispatcher_outputs "console"
  assert_fact escape_if ""
  assert_fact escape_needs ""
  assert_fact "if::console-unit" "needs.changes.outputs.console == 'true'"
  assert_fact "if::cssom-parity" "needs.changes.outputs.console == 'true'"
  assert_fact cssom_refused True
  assert_fact cssom_defect True
  # `set -e` in that wrapper would kill the shell at the `node` line before the
  # case could ever read `rc` — the refusal/defect vocabulary would never print.
  assert_fact cssom_set_e False

  # ── D36 mutation proof: the fifth fact must FIRE, and must go quiet ────────
  # Four deliberately-broken copies of the REAL console-harness.yml, one per
  # direction the guard has to tell apart. This is the only thing separating a
  # guard from a decoration: `needs_without_decide = ""` above proves nothing
  # unless the same emitter, on the same file, returns a non-empty answer when
  # the wiring is genuinely broken.
  MUT="$TMPROOT/mutate-console-yml.py"
  cat >"$MUT" <<'PY'
import sys, yaml
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(src))
agg = wf["jobs"]["console-gate"]
step = next(s for s in agg["steps"] if "run" in s)
assert mode in ("clean", "needs", "env", "wired"), mode   # a typo'd mode is not a pass
if mode in ("needs", "env", "wired"):
    # a BLOCKING job (no continue-on-error), wired into the aggregator's needs
    wf["jobs"]["a11y-ceiling"] = {"runs-on": "ubuntu-latest",
                                  "steps": [{"run": "exit 1"}]}
    agg["needs"] = list(agg["needs"]) + ["a11y-ceiling"]
if mode in ("env", "wired"):
    step.setdefault("env", {})["R_A11Y"] = "${{ needs.a11y-ceiling.result }}"
if mode == "wired":
    step["run"] = step["run"].replace(
        'decide "changes (dispatcher)"',
        'decide "a11y ceiling"           "${R_A11Y}" "NEVER"\n'
        'decide "changes (dispatcher)"', 1)
yaml.safe_dump(wf, open(dst, "w"))
PY
  # direction <mode> <expected needs_without_decide>
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
  direction clean ""                           # untouched tree — silent
  direction needs "a11y-ceiling"               # in needs, no env binding
  direction env   "a11y-ceiling"               # in needs + env, never decided
  direction wired ""                           # fully wired — silent again

  # …and the workflow_paths fact must be able to FIRE. Without this, "False"
  # above is indistinguishable from an emitter that stopped reading `on:`.
  PMUT="$TMPROOT/paths-mutant.yml"
  python3 - "$WF" "$PMUT" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.pop(True, None) or wf.pop("on", None)
on["pull_request"] = {"paths": ["cloud/priv/static/**"]}
wf["on"] = on
yaml.safe_dump(wf, open(sys.argv[2], "w"))
PY
  python3 "$EMIT" "$PMUT" "$TMPROOT/paths.facts"
  if [ "$(sed -n 's|^workflow_paths=||p' "$TMPROOT/paths.facts")" = "True" ]; then
    ok "  mutation[paths]: re-adding on:pull_request:paths is DETECTED"
  else
    no "  mutation[paths]: a workflow-level paths key was NOT detected — the D18 fact is decorative"
  fi
fi
echo

# ── case 9: the aggregator's allow-set, driven by mutation ─────────────────
# The step body is EXTRACTED FROM console-harness.yml and executed, so this
# cannot drift from what CI runs (charter D26: a harness must execute the step
# body, not a paraphrase of it). Each case supplies exactly the env GitHub would.
echo "case 9: the Console gate decides, and can be made red on purpose"
AGG="$TMPROOT/console-gate-step.sh"
python3 - "$WF" "$AGG" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["console-gate"]["steps"] if "run" in s][0]
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
  # So also require the aggregator to have reached its own conclusion.
  local verdict
  if [ "$want" -eq 0 ]; then
    verdict="Console gate: every upstream job either succeeded"
  else
    verdict="::error::Console gate: at least one upstream job is not in the allow-set"
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

# (a) the happy path: a console PR, everything ran and passed
gate "full run, all green" 0 \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true

# (b) a legitimate docs-only skip greens the required context
gate "docs-only PR, console jobs legitimately skipped" 0 \
  R_CHANGES=success R_UNIT=skipped R_CSSOM=skipped R_TIER=skipped R_OVERFLOW=skipped R_ESCAPE=success \
  O_CONSOLE=false
gate_says "legitimately not dispatched" "…and says so, rather than claiming the harness passed"

# (c) an upstream FAILURE reds it — 720 red harness tests may never merge green
gate "console-unit failed" 1 \
  R_CHANGES=success R_UNIT=failure R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true

# (d) THE BYPASS THIS SLICE EXISTS TO CLOSE: cssom-parity `skipped` only because
#     its dependency died, while the dispatcher said it WAS needed.
gate "cssom-parity skipped behind a live gate (upstream died)" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=skipped R_TIER=skipped R_OVERFLOW=skipped R_ESCAPE=success \
  O_CONSOLE=true
gate_says "its gate is 'true', not 'false'" "…and names the reason (a skip is not a pass)"

# (e) the dispatcher itself failing reds it, with empty outputs
gate "dispatcher failed, output empty" 1 \
  R_CHANGES=failure R_UNIT=skipped R_CSSOM=skipped R_TIER=skipped R_OVERFLOW=skipped R_ESCAPE=success \
  O_CONSOLE=

# (f) the unfiltered ratchet may never skip
gate "path-escape skipped" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=skipped \
  O_CONSOLE=true

# (g) cancelled is not success
gate "a cancelled upstream" 1 \
  R_CHANGES=success R_UNIT=cancelled R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true

# (h) anything unrecognised is red — "cannot tell" is a failure, not a pass
gate "an unrecognised result value" 1 \
  R_CHANGES=success R_UNIT=neutral R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true

# (i) an EMPTY result (a job silently dropped from `needs`) is red
gate "an empty result string" 1 \
  R_CHANGES=success R_UNIT= R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true

# (j) a garbage gate value must not license a skip
gate "skip against a garbage gate value" 1 \
  R_CHANGES=success R_UNIT=skipped R_CSSOM=skipped R_TIER=skipped R_OVERFLOW=skipped R_ESCAPE=success \
  O_CONSOLE=maybe

# (k1) THE SILENT OMISSION, MADE LOUD (D209). Adding a job to `needs:` and to
#      `env:` without adding its `decide` line is the one wiring mistake this
#      aggregator cannot report on itself: the job's result is bound, unread,
#      and the gate greens over it. This case fails the overflow-guard job and
#      demands the gate go red AND name it — delete the `decide "overflow-guard"`
#      line and this test is the thing that notices.
gate "overflow-guard failed" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=success R_OVERFLOW=failure R_ESCAPE=success \
  O_CONSOLE=true
gate_says "overflow-guard: failure" "…and names overflow-guard (its decide line is really invoked)"
#      (The arithmetic half of that invariant — one `decide` per `needs:` entry
#      — is already owned by the D36 `needs_without_decide` emitter above, which
#      walks needs -> env var -> decide's 2nd argument and is mutation-proven in
#      four directions. This case is its behavioural companion, not a second
#      copy of it.)

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
mkdir -p "$DR/cloud/priv/static" "$DR/docs" "$DR/.github/workflows" "$DR/scripts"
cp "$SCRIPT" "$HERE/console-path-escape-check.test.sh" "$DR/scripts/"
: >"$DR/cloud/priv/static/app.js"
# NON-EMPTY on purpose: the rename cases below need git's rename detection to
# actually fire, and an empty blob is not a rename source worth the name.
printf 'moved-a\nmoved-b\nmoved-c\n' >"$DR/cloud/priv/static/moved.js"
: >"$DR/docs/guide.md"
: >"$DR/.github/workflows/cloud.yml"
git -C "$DR" init -q
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
BASE_SHA="$(git -C "$DR" rev-parse HEAD)"

# dispatch <label> <expected-rc> <expected-console> <event> <base>
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
  gotc="$(sed -n 's/^console=//p' "$TMPROOT/gh_output")"
  if [ "$gotc" = "$wc" ]; then
    ok "  …emits console=$gotc"
  else
    no "  …emitted console=$gotc, wanted console=$wc"
  fi
}

# a docs-only PR is the whole point of the shim: skip the harness, honestly —
# and, unlike the old workflow-level filter, still publish a check run.
git -C "$DR" checkout -q -b docs-only
: >"$DR/docs/another.md"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm docs >/dev/null 2>&1
dispatch "docs-only PR" 0 false pull_request "$BASE_SHA"

# a console change selects the set
git -C "$DR" checkout -q -b console "$BASE_SHA"
printf 'x\n' >"$DR/cloud/priv/static/app.js"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm console >/dev/null 2>&1
dispatch "cloud/priv/static PR" 0 true pull_request "$BASE_SHA"

# THE FAMILY THE OLD FILTERS DROPPED: a cloud.yml-only PR. seal-predicate.mjs
# reads that workflow, so this MUST dispatch — under the old on:paths it did not.
git -C "$DR" checkout -q -b cloudyml "$BASE_SHA"
printf 'x\n' >"$DR/.github/workflows/cloud.yml"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm cloudyml >/dev/null 2>&1
dispatch ".github/workflows/cloud.yml-only PR" 0 true pull_request "$BASE_SHA"

# push to main never skips, regardless of what changed
dispatch "push event" 0 true push ""

# ── THE FIVE FALSE-GREEN CLASSES the plain `--name-only` producer let through ─
# Every probe above this line is ASCII and rename-free, which is exactly why the
# harness could never have caught either family. These two are the ones that
# matter: `git diff --name-only` QUOTES a path containing `"` (even under
# core.quotepath=false), and rename detection prints only the DESTINATION.
# Both classify FALSE on the pre-fix line — a green required context over a
# harness that never looked at the file that changed.

# (1) a DOUBLE-QUOTE path inside the declared set. Not merely a non-ASCII one:
#     core.quotepath=false silences the octal escaping and leaves this class
#     wide open, so a fix tested only against é would certify a hole.
git -C "$DR" checkout -q -b dquote "$BASE_SHA"
printf 'x\n' >"$DR/cloud/priv/static/we\"ird.js"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm dquote >/dev/null 2>&1
dispatch 'a path containing a double quote' 0 true pull_request "$BASE_SHA"

# (2) a rename OUT of the declared set. The file under test left cloud/priv/
#     static — the harness MUST run — but rename detection names only docs/.
git -C "$DR" checkout -q -b renameout "$BASE_SHA"
git -C "$DR" mv cloud/priv/static/moved.js docs/moved.js >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm renameout >/dev/null 2>&1
dispatch "a rename OUT of the declared set" 0 true pull_request "$BASE_SHA"

# (3) …and a rename INTO the set still classifies true — `--no-renames` prints
#     BOTH sides, so closing (2) must not have cost the obvious direction.
git -C "$DR" checkout -q -b renamein "$BASE_SHA"
git -C "$DR" mv docs/guide.md cloud/priv/static/guide.md >/dev/null 2>&1
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
rm -rf "${DR:?}/cloud" "${DR:?}/docs"
mkdir -p "$DR/cloud/priv/static"
printf 'z\n' >"$DR/cloud/priv/static/orphan.js"
git -C "$DR" add -A >/dev/null 2>&1
git -C "$DR" -c user.email=t@t -c user.name=t commit -qm orphan >/dev/null 2>&1
dispatch "a base with no common ancestor" 1 - pull_request "$BASE_SHA"
gate_says "share NO common ancestor" "  …and names the condition, not a raw git fatal"
gate_says "refusing a two-dot fallback" "  …and refuses the fallback that sweeps in the whole base"
echo

# ── case 11: the cssom-parity wrapper keeps the instrument's vocabulary ─────
# cssom-parity.mjs exits 2 for a REFUSAL to measure (no Chrome, no baseline
# sidecar, wrong Node) and 1 for a real parity DEFECT. A bare `run:` collapses
# both into "the job failed" and sends the next reader hunting a CSS bug that
# does not exist. The step body is EXTRACTED and executed, same discipline as
# cases 9 and 10.
echo "case 11: REFUSED and DEFECT are told apart, and neither greens"
CSS="$TMPROOT/cssom-step.sh"
python3 - "$WF" "$CSS" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = [s for s in wf["jobs"]["cssom-parity"]["steps"]
        if "cssom-parity.mjs" in str(s.get("run", ""))][0]
open(sys.argv[2], "w").write(step["run"])
PY

# (a) the REFUSAL path, driven by the REAL instrument: a missing baseline sidecar
#     is an environment fault it exits 2 for, on the guard path, before any
#     browser is launched.
out="$( (cd "$REAL_ROOT" && HEADS_BASELINE=/nonexistent/cssom-heads.baseline \
  bash --noprofile --norc "$CSS") 2>&1 )" && rc=0 || rc=$?
if [ "$rc" -eq 1 ]; then
  ok "HEADS_BASELINE=/nonexistent -> the job exits 1 (a refusal is not a pass)"
else
  no "HEADS_BASELINE=/nonexistent -> exit $rc, wanted 1: $out"
fi
if has "$out" "title=CSSOM parity REFUSED"; then
  ok "…and annotates it REFUSED (an ENVIRONMENT fault)"
else
  no "…but did not emit the REFUSED annotation: $out"
fi
if has "$out" "title=CSSOM parity DEFECT"; then
  no "…and ALSO claimed a CSS defect — the two are not told apart"
else
  ok "…and does NOT claim a stylesheet defect"
fi

# (b) the DEFECT path and the rest of the vocabulary, driven by a stub `node`
#     first on PATH. A real parity miss needs Chrome and a broken app.css; the
#     wrapper's job is to translate an exit code, so the exit code is what is
#     injected.
STUBBIN="$TMPROOT/stubbin"
mkdir -p "$STUBBIN"
cat >"$STUBBIN/node" <<'SH'
#!/bin/sh
echo "stub cssom-parity.mjs, exiting ${STUB_RC}"
exit "${STUB_RC}"
SH
chmod +x "$STUBBIN/node"

css_rc() {
  local label="$1" stub="$2" want="$3" needle="$4" out rc
  out="$(STUB_RC="$stub" PATH="$STUBBIN:$PATH" bash --noprofile --norc "$CSS" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "$label: instrument exit $stub -> job exit $rc"
  else
    no "$label: instrument exit $stub -> job exit $rc, wanted $want: $out"
  fi
  if [ -z "$needle" ] || has "$out" "$needle"; then
    ok "  …and says '${needle:-nothing to say}'"
  else
    no "  …but never printed '$needle': $out"
  fi
}
css_rc "a real parity miss"       1 1 "title=CSSOM parity DEFECT"
css_rc "an instrument refusal"    2 1 "title=CSSOM parity REFUSED"
css_rc "parity holds"             0 0 "authored CSS and the browser agree"
css_rc "an exit outside the set"  7 1 "title=CSSOM parity UNINTERPRETABLE"
# The stub must really be the thing that ran — otherwise every case above
# measured the real instrument (or nothing) and proves nothing about the wrapper.
out="$(STUB_RC=0 PATH="$STUBBIN:$PATH" bash --noprofile --norc "$CSS" 2>&1)"
if has "$out" "stub cssom-parity.mjs, exiting 0"; then
  ok "the injected exit code really came from the stub"
else
  no "the stub never ran — cases (b) measured something else entirely"
fi
echo

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
