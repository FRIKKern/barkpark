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
#   * a read the census is STRUCTURALLY BLIND to must still be
#     DISPATCHED on                                          (case 6) — the
#     emit-fence guard the seal predicate SPAWNS copies its tree from an
#     IMPORTED list (design/emit.mjs's ARTIFACTS), so no literal-extracting
#     door can ever resolve those paths. Measured: a comment appended to
#     web/lib/tokens.gen.ts reds that guard while --match console said
#     false. A declared entry has no census row to protect it, so the
#     harness is the only guard a deletion has to get past.
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

# Build a synthetic mini-repo whose console tree reads known repo-root paths in
# EVERY idiom the scanner carries — literal-join, ident-join, data-table,
# measured-by, template and walk-up.
#
# ALL SIX, AND THAT IS A REQUIREMENT NOW, NOT TIDINESS. The floor became
# PER-IDIOM (see CONSOLE_ESCAPE_IDIOM_MIN), so a fixture missing an idiom reds
# on the floor before the coverage loop ever runs — and every coverage case
# built on this fixture would then be asserting on output the run never
# reached. The old fixture carried three idioms and would have done exactly
# that. Each read below is COVERED by the declared set, so the fixture's
# baseline verdict is clean and a mutation case reds for its own reason only.
make_fixture() {
  local root="$1"
  mkdir -p "$root/cloud/priv/static/__preview__" \
    "$root/internal/taskboard/testdata" "$root/internal/pdrender/testdata" \
    "$root/.github/workflows" "$root/design" "$root/deploy/lib" \
    "$root/cloud/test/barkpark_cloud/web"
  : >"$root/internal/taskboard/testdata/styleguide_lifecycle.txt"
  : >"$root/internal/pdrender/testdata/styleguide_tokens.txt"
  : >"$root/.github/workflows/cloud.yml"
  : >"$root/.github/required-checks.json"
  : >"$root/design/emit-fence.test.mjs"
  : >"$root/deploy/site-deploy-node.sh"
  : >"$root/deploy/lib/site-deploy-common.sh"
  : >"$root/cloud/test/barkpark_cloud/web/router_test.exs"
  : >"$root/cloud/test/barkpark_cloud/web/router_oauth_test.exs"
  : >"$root/cloud/test/barkpark_cloud/web/router_sse_ticket_test.exs"
  cat >"$root/cloud/priv/static/__app.test.mjs" <<'JS'
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const LIFECYCLE_FIXTURE = path.join(REPO_ROOT, "internal/taskboard/testdata/styleguide_lifecycle.txt");
const TOKENS_FIXTURE = path.join(REPO_ROOT, "internal/pdrender/testdata/styleguide_tokens.txt");
const NODE_DEPLOY = path.join(REPO_ROOT, "deploy/site-deploy-node.sh");
// the walk-up idiom, resolved against this file's own directory
const COMMON = new URL("../../../deploy/lib/site-deploy-common.sh", import.meta.url);
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
      'cloud/test/barkpark_cloud/web/router_sse_ticket_test.exs',
      'cloud/test/barkpark_cloud/web/router_DELETED_test.exs',
    ],
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test', paths: 'cloud/**' },
  },
  { id: 'c', guard: 'design/emit-fence.test.mjs' },
];
const guardPath = `${REPO}/${d.guard}`;
// the template-literal idiom, the shape the rung-2 leg A read is written in
const REQUIRED = readFileSync(`${REPO}/.github/required-checks.json`, 'utf8');
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
#
# NO HARD-CODED POPULATION HERE. This assertion used to read `-ge 8` under a
# label claiming the measured population was 9 — a PASSING test whose own name
# contradicted the number the run printed (15), and a threshold so far under the
# live population that the census could have lost SEVEN reads and still said ok.
# The number is gone from every site in both files now. Both halves are
# now DERIVED, and neither can rot:
#   (a) --check's count must agree with --list-escapes' own distinct count. Two
#       modes, one census; if they disagree, one of them is lying.
#   (b) every idiom the script declares a floor for must actually clear that
#       floor in --list-escapes. Computed from --list-escapes and --print-floors,
#       so it does not just re-read --check's arithmetic back to itself.
n="$(printf '%s' "$out" | sed -n 's/^console-path-escape-check: \([0-9]*\) distinct.*/\1/p')"
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
    no "idiom $fidiom resolved $fgot read(s) but its floor is $fmin — this idiom is blind"
    thin_idioms=$((thin_idioms + 1))
  fi
done <<<"$floors"
if [ "$thin_idioms" -eq 0 ]; then
  ok "every declared idiom clears its own floor on the real tree"
else
  no "$thin_idioms idiom(s) are under their floor"
fi
echo

# ── case 2: the census carries the three families NOBODY had declared ───────
# These are the reads the old workflow-level filters missed entirely: the seal
# predicate's tests pass `--repo <the real repo root>`, so the predicate reaches
# all three. Measured when wave 9 cut this: deleting cloud.yml's paths key reds
# 7 seal-predicate tests, moving emit-fence.test.mjs reds 1, moving a
# measured_by file reds 6. NO DENOMINATOR — those counts were written "of 31"
# and seal-predicate.test.mjs carries 75 `test(` calls now, so the denominator
# was wrong by more than a factor of two. Cite the derivation, not the number.
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

# ── case 4b: THE SOURCE SET — three independent blind legs ─────────────────
# Each of these was PROVED ALONE on origin/main with a control, because each one
# alone leaves the others' probes green and a builder who fixed only the first
# would have concluded the fix failed.
echo "case 4b: the three source-set blind legs"

# LEG 1 — RECURSION. The scan is `find cloud/priv/static`, so a read expressed
# one call frame down, inside a file the harness SPAWNS, was structurally
# invisible. Measured on origin/main with the ONLY variable being which file
# carried it: the identical `join(REPO_ROOT, "api/mix.exs")` gave 15 reads /
# RC=0 / unnamed inside design/emit-fence.test.mjs (declared, never scanned) and
# 16 / UNCOVERED / RC=1 inside the directly-scanned __app.test.mjs.
FXR="$TMPROOT/recurse"
make_fixture "$FXR"
mkdir -p "$FXR/faraway"
: >"$FXR/faraway/nested.json"
# design/emit-fence.test.mjs is a FRONTIER file: it is resolved by the data
# table's `guard:` and it is not under cloud/priv/static, so only the recursion
# can open it. Its root variable is camelCase on purpose — that is how the real
# one is written.
cat >"$FXR/design/emit-fence.test.mjs" <<'JS'
const repoRoot = join(here, "..");
const NESTED = readFileSync(join(repoRoot, "faraway/nested.json"), "utf8");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXR" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a read one call frame down"
else
  no "PASSED with an uncovered read inside a declared-but-unscanned input"
fi
if has "$out" "UNCOVERED repo-root read: faraway/nested.json"; then
  ok "names the read the recursion found"
else
  no "the frontier file's read is invisible: $out"
fi
# ATTRIBUTION IS THE PROOF IT CAME THROUGH THE RECURSION: no file under
# cloud/priv/static carries this literal, so only the second pass could name it.
if has "$out" "read from: design/emit-fence.test.mjs"; then
  ok "attributes it to the FRONTIER file, not to the console tree"
else
  no "did not attribute the recursed read to the frontier file: $out"
fi
# …and DEPTH IS BOUNDED AT ONE, which is a declared limit, not an oversight. A
# read TWO frames down must NOT be resolved — if it were, this census would
# crawl the repo through whatever the frontier happens to import.
mkdir -p "$FXR/second"
: >"$FXR/second/deep.json"
cat >"$FXR/design/second-level.mjs" <<'JS'
const DEEP = readFileSync(join(repoRoot, "second/deep.json"), "utf8");
JS
cat >>"$FXR/design/emit-fence.test.mjs" <<'JS'
const LEVEL2 = join(repoRoot, "design/second-level.mjs");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXR" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if has "$out" "UNCOVERED repo-root read: second/deep.json"; then
  no "depth is UNBOUNDED — a level-2 read was resolved"
else
  ok "depth stops at one level (the level-2 read is out of reach by declaration)"
fi

# LEG 2 — IDIOM, proved ALONE with no recursion in play. The shipped regex was
# `(REPO_ROOT|REPO)`, case-sensitive, so the scanner's vocabulary was coupled to
# how one file names its root variable. Measured on origin/main:
# `path.join(repoRootLocal, "api/mix.exs")` in a DIRECTLY scanned file was
# invisible at 15 reads / RC=0.
FXI="$TMPROOT/idiom"
make_fixture "$FXI"
mkdir -p "$FXI/elsewhere"
: >"$FXI/elsewhere/camel.json"
cat >"$FXI/cloud/priv/static/camel.test.mjs" <<'JS'
const repoRootLocal = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const CAMEL = path.join(repoRootLocal, "elsewhere/camel.json");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXI" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a camelCase root identifier"
else
  no "PASSED with a join(<ident>, …) read — the idiom vocabulary is still coupled to one file"
fi
if has "$out" "UNCOVERED repo-root read: elsewhere/camel.json"; then
  ok "the generic join idiom names the read"
else
  no "the generic join idiom did not resolve it: $out"
fi

# LEG 3 — BARE WORD. Any literal without a `/` used to be dropped outright, so a
# read of ANY repo-root top-level file was structurally unrepresentable: the
# census could not have named Makefile / README.md / mix.lock if it tried.
FXB="$TMPROOT/bareword"
make_fixture "$FXB"
: >"$FXB/TOPLEVEL.md"
cat >"$FXB/cloud/priv/static/bare.test.mjs" <<'JS'
const TOP = path.join(REPO_ROOT, "TOPLEVEL.md");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXB" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) on a bare-word repo-root read"
else
  no "PASSED with an undeclared top-level file read — bare words are still unrepresentable"
fi
if has "$out" "UNCOVERED repo-root read: TOPLEVEL.md"; then
  ok "names the top-level file"
else
  no "the bare-word read never entered the census: $out"
fi
# …AND THE BARE-WORD RULE HAS A CEILING, which is the half that keeps it usable:
# a bare word is admitted only from an idiom whose base is PROVABLY the repo
# root. `join(<unknownIdent>, "TOPLEVEL.md")` is usually a temp dir, not a repo
# read, so it must NOT enter.
rm -f "$FXB/cloud/priv/static/bare.test.mjs"
cat >"$FXB/cloud/priv/static/bare.test.mjs" <<'JS'
const tmp = mkdtempSync(join(tmpdir(), "x-"));
const TOP = path.join(tmp, "TOPLEVEL.md");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXB" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "a bare word joined to an UNKNOWN identifier is not a repo read (exit 0)"
else
  no "the bare-word rule over-fires on join(<unknownIdent>, 'x'): $out"
fi
# …and `.git` never enters, in EITHER checkout shape. It is a directory in a
# clone but a regular FILE in a git worktree, which is where this gate's local
# runs happen — admitting it would make the ratchet red locally and pass in
# Actions.
rm -f "$FXB/cloud/priv/static/bare.test.mjs"
printf 'gitdir: /somewhere/else\n' >"$FXB/.git"
cat >"$FXB/cloud/priv/static/bare.test.mjs" <<'JS'
const G = spawnSync("git", ["-C", REPO_ROOT, ".git", "rev-parse"]);
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FXB" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok ".git is not a read even when it is a regular file (the worktree shape)"
else
  no ".git entered the census — this gate would red locally and pass in CI: $out"
fi
rm -f "$FXB/.git"
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
# …and it names WHICH idiom went blind, which is the whole reason the floor is
# per-idiom: "the population is thin" does not tell you where to look.
if has "$out" "idiom 'data-table' resolved only 0"; then
  ok "names the idiom that resolved nothing"
else
  no "did not name the blind idiom: $out"
fi
# and the floor is NOT overridable outside the harness
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FX3" CONSOLE_ESCAPE_IDIOM_MIN='literal-join	0' "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "CONSOLE_ESCAPE_IDIOM_MIN in the environment cannot lower the floor"
else
  no "the floor was lowered by an env var — that is a one-line CI bypass"
fi
echo

# ── case 5b: THE FLOOR IS FILE-AWARE ────────────────────────────────────────
# A per-idiom floor is only as honest as what counts toward it. `[ -e ]` used to
# admit DIRECTORY rows, and a directory row names no file: blind the
# literal-join regex to dotted filenames on the real tree and that family
# collapses 6 -> 1 with the survivor being the directory `cloud/lib` — bound
# held, scanner blind. So a population made ENTIRELY of directory rows must red,
# not pass.
echo "case 5b: a directory-only population cannot satisfy a floor"
FX4="$TMPROOT/dironly"
make_fixture "$FX4"
# Every read this file expresses resolves to a DIRECTORY that really exists and
# really is dispatched on (cloud/lib/** is declared), so nothing here is an
# uncovered-read red — the only thing that can red is the floor.
mkdir -p "$FX4/cloud/lib/barkpark_cloud/sites" "$FX4/cloud/lib/barkpark_cloud/web"
rm -f "$FX4/cloud/priv/static/__app.test.mjs"
cat >"$FX4/cloud/priv/static/__app.test.mjs" <<'JS'
const A = path.join(REPO_ROOT, "cloud/lib");
const B = path.join(REPO_ROOT, "cloud/lib/barkpark_cloud");
const C = path.join(REPO_ROOT, "cloud/lib/barkpark_cloud/sites");
const D = path.join(REPO_ROOT, "cloud/lib/barkpark_cloud/web");
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FX4" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "exit $rc (non-zero) — four directory rows do not satisfy the literal-join floor"
else
  no "PASSED on a directory-only population — the floor counts rows that name no file"
fi
if has "$out" "idiom 'literal-join' resolved only 0"; then
  ok "the directory rows contributed ZERO to the idiom's count"
else
  no "directory rows were counted toward the floor: $out"
fi
# …and the same rows, pointed at FILES, clear the floor — so the case above
# reds for file-awareness, not because the fixture is broken.
: >"$FX4/cloud/lib/barkpark_cloud/router.ex"
: >"$FX4/cloud/lib/barkpark_cloud/sites/worker.ex"
: >"$FX4/cloud/lib/barkpark_cloud/web/plug.ex"
cat >"$FX4/cloud/priv/static/__app.test.mjs" <<'JS'
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const A = path.join(REPO_ROOT, "cloud/lib/barkpark_cloud/router.ex");
const B = path.join(REPO_ROOT, "cloud/lib/barkpark_cloud/sites/worker.ex");
const C = path.join(REPO_ROOT, "cloud/lib/barkpark_cloud/web/plug.ex");
const COMMON = new URL("../../../deploy/lib/site-deploy-common.sh", import.meta.url);
JS
out="$(CONSOLE_PATH_ESCAPE_ROOT="$FX4" "$SCRIPT" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "the same three rows as FILES clear the floor (exit 0) — the control"
else
  no "the file control did not pass, so case 5b proves nothing: $out"
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
# ── the emit ARTIFACTS: DECLARED, because the census is structurally blind ──
# `design/emit-fence.test.mjs` is a guard the seal predicate SPAWNS, and it
# copies its tree from `ARTIFACTS.map((a) => a.path)` plus the mirror module's
# two exported paths — an IMPORTED list, so no literal-extracting door in
# `file_lits` can ever resolve one of them, and the frontier recursion stops one
# frame short of `design/emit.mjs` by declaration. Measured on origin/main: a
# comment appended to `web/lib/tokens.gen.ts` took that guard from
# `# pass 9 / # fail 0` to `# pass 6 / # fail 3` while `--match console` printed
# `false` for it. Cases 3/3b cannot cover this: they prove the ratchet reds on a
# read the census SEES. These arms are the ONLY thing standing between a deleted
# declaration and a silent return to that hole.
#
# AND THE DECLARATION STAYS DERIVED RATHER THAN DECORATIVE: the list is read
# back out of the emitter itself, so an artifact added there without a line in
# CONSOLE_PATHS reds HERE, and retiring an artifact retires its arm with it.
# Deriving ZERO paths is itself a failure — otherwise the loop passes vacuously
# the day the grep stops matching, which is the exact shape this harness exists
# to refuse.
emit_src="$REAL_ROOT/design/emit.mjs"
if [ ! -f "$emit_src" ]; then
  no "design/emit.mjs is missing — the ARTIFACTS declarations cannot be re-derived"
else
  # `|| true` is LOAD-BEARING, and it covers ONLY the grep. Under this harness's
  # `set -euo pipefail` a grep that matches nothing exits 1, the command
  # substitution inherits it, and the ASSIGNMENT kills the whole run — no FAIL
  # line, no tally, just a stop, which is a red for a reason foreign to what is
  # being tested. Split across two substitutions so pipefail still governs the
  # sed|sort that follows.
  art_paths="$(awk '/^export const ARTIFACTS = \[/,/^\];/' "$emit_src" \
    | { grep -Eoh 'path: "[^"]*"' || true; })"
  art_paths="$(sed -E 's/^path: "//; s/"$//' <<<"$art_paths" | LC_ALL=C sort -u | sed '/^$/d')"
  if [ -z "$art_paths" ]; then
    no "derived ZERO artifact paths from design/emit.mjs — the derivation went blind and the arms below would pass vacuously"
  else
    ok "derived $(printf '%s\n' "$art_paths" | wc -l | tr -d ' ') ARTIFACTS path(s) from design/emit.mjs"
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      check_match "$a" console true
    done <<EOF
$art_paths
EOF
  fi
fi
# The same treatment for the two paths the guard imports from the mirror module.
# SURFACE_PATH is also an ARTIFACTS row; BUNDLE_PATH is not, and it reds the
# same guard when a line is spliced inside its generated mirror region — so it
# is declared on its own measurement and re-derived on its own grep.
mirror_src="$REAL_ROOT/design/paper-editor-mirror.mjs"
if [ ! -f "$mirror_src" ]; then
  no "design/paper-editor-mirror.mjs is missing — the SURFACE_PATH/BUNDLE_PATH declarations cannot be re-derived"
else
  mirror_paths="$({ grep -Eoh '^export const (SURFACE_PATH|BUNDLE_PATH) = "[^"]*"' "$mirror_src" || true; })"
  mirror_paths="$(sed -E 's/.*"([^"]*)"$/\1/' <<<"$mirror_paths" | LC_ALL=C sort -u | sed '/^$/d')"
  if [ -z "$mirror_paths" ]; then
    no "derived ZERO paths from design/paper-editor-mirror.mjs — the derivation went blind and the arm below would pass vacuously"
  else
    ok "derived the mirror module's path exports: $(tr '\n' ' ' <<<"$mirror_paths")"
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      check_match "$a" console true
    done <<EOF
$mirror_paths
EOF
  fi
fi
# …and the declaration is EXACT FILES, never the trees they live in: widening to
# a directory would bill every api/ and web/ PR for a console harness run, which
# is the over-inclusion the script's own header refuses.
check_match "api/lib/barkpark_web/controllers/user_controller.ex" console false
check_match "web/lib/other.ts" console false
check_match "internal/semrole/role.go" console false
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
  # The emitter READS the instruments a job invokes (see the D776 block inside
  # it), so it needs the real repo root even when the YAML it is pointed at is a
  # mutated copy in a temp dir.
  export CONSOLE_YML_REPO="$REAL_ROOT"
  cat >"$EMIT" <<'PY'
import os, re, sys, yaml
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
# THE POST-VERDICT CATEGORY. Exactly one shape of blocking job legitimately
# cannot live in `needs`: a reporter that runs AFTER the aggregator concluded,
# to carry main's own red to a human. Wiring it in is not a trade-off, it is a
# CYCLE (console-gate -> reporter -> console-gate) and GitHub refuses to load
# it. A job is post-verdict iff ALL THREE hold:
#   (1) needs == ["console-gate"] EXACTLY — so `needs` really is the cycle, not
#       a choice somebody declined to make;
#   (2) its `if:` starts with an ANCHORED failure(). The loose \bfailure\(\)
#       admits `success() || failure()` — a job that runs on EVERY GREEN
#       wearing post-verdict clothes. The anchor is load-bearing;
#   (3) it is NOT continue-on-error, so it keeps its own exit-1. That retained
#       can-lose property is what the exemption is granted in exchange for; a
#       muted reporter is named by post_verdict_muted below, never exempted.
POST_VERDICT_IF = re.compile(r"^failure\(\)(\s|&|$)")
def post_verdict_shape(j):
    return (list(j.get("needs") or []) == ["console-gate"]
            and bool(POST_VERDICT_IF.match(str(j.get("if", "")).strip())))
post_verdict = {n for n, j in jobs.items()
                if post_verdict_shape(j) and j.get("continue-on-error") is not True}
post_verdict_muted = {n for n, j in jobs.items()
                      if post_verdict_shape(j) and j.get("continue-on-error") is True}
emit("post_verdict_jobs", ",".join(sorted(post_verdict)))
emit("post_verdict_muted", ",".join(sorted(post_verdict_muted)))
# …and the mirror hazard, which the allow-set cannot see: a BLOCKING job added
# to this workflow but never wired into `needs`. The aggregator cannot judge a
# job nobody told it about, so it would green while that job is red.
# Post-verdict jobs are subtracted — they are judged by the pinned roster
# instead, which is STRICTER than this set difference, not laxer.
blocking = {n for n, j in jobs.items()
            if j.get("continue-on-error") is not True and n != "console-gate"}
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
for n in ("console-unit", "cssom-parity"):
    emit(f"if::{n}", str(jobs.get(n, {}).get("if", "")))
# The cssom wrapper's own vocabulary, read off the real step body.
cst = next((s for s in jobs.get("cssom-parity", {}).get("steps", [])
            if "cssom-parity.mjs" in str(s.get("run", ""))), {})
body = str(cst.get("run", ""))
emit("cssom_refused", "title=CSSOM parity REFUSED" in body)
emit("cssom_defect", "title=CSSOM parity DEFECT" in body)
emit("cssom_set_e", bool(re.search(r"set -[a-z]*e[a-z]*u?o? ", body)))
# ── D776 — THE VERDICT CHANNEL, AS A STRUCTURAL FACT ───────────────────────
# `exit 2` means "this instrument REFUSED TO MEASURE": it made no claim in
# either direction. `exit 1` means it measured a real defect. Both reach the
# aggregate as `result: failure` and nothing else, so a job with no verdict
# channel reads at the merge button exactly like a job that found a bug — which
# is how run 31322709682 sent a reader hunting for an environment fault that was
# not there. Wave 63 wired console-unit and left `path-escape` one job over.
#
# EXIT-2 CAPABILITY IS DERIVED, NOT LISTED. A job qualifies if any of its step
# bodies can raise a 2 itself (a literal `exit 2`) or invokes an instrument that
# can — the invoked file is READ, and shell scripts are searched for `exit 2`,
# node instruments for `process.exit(2)`. So a new exit-2-capable job cannot
# join this workflow without either declaring a channel or being named in the
# exemption below; neither is possible by accident.
# The repo root, NOT derived from argv[1]: the mutation matrix below runs this
# same emitter over COPIES of the workflow in a temp dir, and a derived root
# would silently make every invoked instrument unreadable — every job would
# then look exit-2-incapable and the whole fact would go quietly vacuous.
REPO = os.environ["CONSOLE_YML_REPO"]
_seen = {}
def file_can_exit_2(rel):
    if rel not in _seen:
        p = os.path.join(REPO, rel)
        try:
            txt = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            _seen[rel] = False
        else:
            _seen[rel] = bool(re.search(r"(^|\n)\s*exit 2\b", txt)
                              or "process.exit(2)" in txt)
    return _seen[rel]

def job_can_exit_2(j):
    bodies = "\n".join(str(s.get("run", "")) for s in j.get("steps", []))
    if re.search(r"(^|\n)\s*exit 2\b", bodies):
        return True
    refs = re.findall(r"(?:bash|sh)\s+(scripts/[\w./-]+\.sh)", bodies)
    refs += re.findall(r"node\s+([\w./-]+\.mjs)", bodies)
    return any(file_can_exit_2(r) for r in refs)

# THE DECIDE ARITY, per job: a channel that is declared but never passed to
# `decide` is a channel the aggregate cannot read. Keyed on the SECOND
# positional argument for the same reason `consumed` above is — the first is a
# human label that deliberately does not match the job name.
decide_arity = {}
for m in re.finditer(
        r'^\s*decide\s+"[^"]*"\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"\s+"[^"]*"(\s+"[^"]*")?',
        step.get("run", ""), re.M):
    decide_arity[m.group(1)] = bool(m.group(2))

exit2 = sorted(n for n, j in jobs.items() if n != "console-gate" and job_can_exit_2(j))
emit("exit2_jobs", ",".join(exit2))
# THE NAMED EXEMPTION, and there is exactly one. `changes` reaches an exit 2
# through the ratchet's `--match` mode, but it is the DISPATCHER: it publishes
# path outputs, not a verdict, and its own fail-closed contract already forbids
# it to emit a path answer it could not measure. Giving it a channel is real
# work in its own right and is filed, not smuggled in here
# (cch-w64-bl-dispatcher-has-no-verdict-channel). It is written out as a fact so
# extending the exemption costs a human an edit in this file.
EXEMPT = {"changes"}
emit("exit2_exempt", ",".join(sorted(EXEMPT)))
emit("exit2_without_verdict_output",
     ",".join(n for n in exit2
              if n not in EXEMPT and "verdict" not in (jobs[n].get("outputs") or {})))
emit("exit2_without_decide_verdict",
     ",".join(n for n in exit2
              if n not in EXEMPT and not decide_arity.get(var_for.get(n), False)))
# Cardinality, for the same reason the three above carry one: an empty
# difference proves nothing if the set it was computed from is empty. A parser
# that stops matching `run:` bodies would report a serene "" forever.
emit("exit2_jobs_count", len(exit2))
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
  # D776 — every exit-2-capable job publishes a verdict AND the aggregate reads
  # it. Two facts, because either half alone is a channel nobody can hear: a
  # declared `outputs.verdict` that no `decide` call takes as a 4th argument is
  # never consulted, and a 4th argument bound to a job that publishes nothing is
  # always the empty string.
  assert_fact exit2_without_verdict_output ""
  assert_fact exit2_without_decide_verdict ""
  # The exemption is pinned, not open-ended: extending it must cost an edit here.
  assert_fact exit2_exempt "changes"
  # …and the population it was computed from is real. "" over an empty set is
  # the shape a neutered parser returns.
  assert_fact_min exit2_jobs_count 5
  # THE POST-VERDICT ROSTER IS AN EXACT PIN, AND THAT DELIBERATELY DIVERGES
  # FROM `assert_fact_min`'s "a lower bound, never an equality" convention
  # above. Do NOT "fix" this into a _min bound: a lower bound is a blanket hole
  # in BOTH directions. It passes a SMUGGLED second post-verdict-shaped job (a
  # job that reaches `if: failure()` and is then exempt from every other
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

  # ── post-verdict mutation matrix ──────────────────────────────────────────
  # The exemption above is worth exactly as much as its ability to REFUSE. Nine
  # copies of the REAL console-harness.yml, one per way a job can wear
  # post-verdict clothes without being one.
  PVMUT="$TMPROOT/mutate-console-postverdict.py"
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
            "needs": ["console-gate"],
            "if": "failure() && github.ref == 'refs/heads/main'",
            "runs-on": "ubuntu-latest",
            "steps": [{"run": "bash scripts/file-ci-failure-issue.sh"}]}
# Every mutant starts from the SAME base — the real console-harness.yml with any
# reporter removed — so these expectations hold whether or not #10155 has
# merged. The matrix must not change meaning the day the tree it reads gains the
# job.
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
    r["needs"] = ["console-gate", "changes"]            # no longer a pure cycle
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

  # ── D776 verdict-channel mutation matrix ─────────────────────────────────
  # `exit2_without_verdict_output = ""` and `exit2_without_decide_verdict = ""`
  # are worth nothing until the same emitter, on deliberately broken copies of
  # the REAL console-harness.yml, returns a non-empty answer. Both directions,
  # because they fail differently: an existing job losing its channel, and a NEW
  # exit-2-capable job arriving without one.
  VCMUT="$TMPROOT/mutate-console-verdict.py"
  cat >"$VCMUT" <<'PY'
import sys, yaml
src, dst, mode = sys.argv[1], sys.argv[2], sys.argv[3]
wf = yaml.safe_load(open(src))
jobs = wf["jobs"]
assert mode in ("clean", "drop-outputs", "drop-decide-arg", "fake-exit2"), mode
if mode == "drop-outputs":
    # The `outputs:` block this slice added, taken back out — the state
    # path-escape shipped in until D776.
    jobs["path-escape"].pop("outputs", None)
elif mode == "drop-decide-arg":
    # The channel is declared but the aggregate stops reading it: a verdict
    # published into a line nobody consults.
    step = next(s for s in jobs["console-gate"]["steps"] if "run" in s)
    step["run"] = step["run"].replace(
        'decide "path-escape ratchet"     "${R_ESCAPE}"  "NEVER"          "${V_ESCAPE:-}"',
        'decide "path-escape ratchet"     "${R_ESCAPE}"  "NEVER"', 1)
elif mode == "fake-exit2":
    # A NEW blocking job that can refuse to measure, wired in the ordinary way
    # and carrying no channel at all — the exact arrival this fact exists to
    # refuse. It is wired all the way through `needs`/`env`/`decide` so the
    # OTHER structural facts stay silent and only this one speaks.
    jobs["a11y-ceiling"] = {"runs-on": "ubuntu-latest",
                            "steps": [{"run": "exit 2"}]}
    agg = jobs["console-gate"]
    agg["needs"] = list(agg["needs"]) + ["a11y-ceiling"]
    step = next(s for s in agg["steps"] if "run" in s)
    step.setdefault("env", {})["R_A11Y"] = "${{ needs.a11y-ceiling.result }}"
    step["run"] = step["run"].replace(
        'decide "changes (dispatcher)"',
        'decide "a11y ceiling"           "${R_A11Y}" "NEVER"\n'
        'decide "changes (dispatcher)"', 1)
yaml.safe_dump(wf, open(dst, "w"))
PY
  # vc <mode> <exit2_without_verdict_output> <exit2_without_decide_verdict>
  vc() {
    local mode="$1" f="$TMPROOT/vc-$1.yml" ff="$TMPROOT/vc-$1.facts" key want got
    python3 "$VCMUT" "$WF" "$f" "$mode"
    python3 "$EMIT" "$f" "$ff"
    for key in exit2_without_verdict_output exit2_without_decide_verdict; do
      case "$key" in
        exit2_without_verdict_output) want="$2" ;;
        *) want="$3" ;;
      esac
      got="$(sed -n "s|^$key=||p" "$ff")"
      if [ "$got" = "$want" ]; then
        ok "  verdict-channel[$mode]: $key = '$got'"
      else
        no "  verdict-channel[$mode]: $key = '$got', wanted '$want'"
      fi
    done
  }
  vc clean           ""             ""
  vc drop-outputs    "path-escape"  ""
  vc drop-decide-arg ""             "path-escape"
  vc fake-exit2      "a11y-ceiling" "a11y-ceiling"
  # …and the fake job must be invisible to the OTHER structural facts, so the
  # red above is this fact's and not a neighbour's borrowed alarm.
  if [ "$(sed -n 's|^blocking_not_in_needs=||p' "$TMPROOT/vc-fake-exit2.facts")" = "" ] \
    && [ "$(sed -n 's|^needs_without_decide=||p' "$TMPROOT/vc-fake-exit2.facts")" = "" ]; then
    ok "  verdict-channel[fake-exit2]: the wiring facts stay silent — only the channel fact speaks"
  else
    no "  verdict-channel[fake-exit2]: a neighbouring fact fired too; the channel fact is not what caught it"
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
  #
  # THE RED PATH HAS TWO CONCLUSION LINES, NOT ONE, and until this slice only
  # the plain one was ever reached: no case here supplied a verdict, so the
  # refusals branch — and with it the whole REFUSED arm of `decide` — had never
  # executed under test. Either line proves the body decided; neither is
  # optional, so a run that printed NEITHER still reports a crash.
  local verdict
  if [ "$want" -eq 0 ]; then
    verdict="Console gate: every upstream job either succeeded"
    if grep -qF -- "$verdict" "$GATE_OUT"; then
      ok "  …and reached its own verdict line"
    else
      no "  …but printed NO verdict line — the step body crashed rather than decided"
      sed 's/^/        /' "$GATE_OUT" >&2
    fi
  else
    if grep -qF -- "::error::Console gate: at least one upstream job is not in the allow-set" "$GATE_OUT" \
      || grep -qF -- "title=Console gate RED — an instrument REFUSED TO MEASURE" "$GATE_OUT"; then
      ok "  …and reached its own verdict line"
    else
      no "  …but printed NO verdict line — the step body crashed rather than decided"
      sed 's/^/        /' "$GATE_OUT" >&2
    fi
  fi
}
gate_says() {
  if grep -q -- "$1" "$GATE_OUT"; then ok "$2"; else no "$2 (not in the step output)"; fi
}
# The negative half, and the one that pins a SENTENCE rather than a branch. A
# copy edit is unwitnessable without it: the wording this gate must NOT use is
# not absent by accident, it was removed on purpose (D760), and only an
# assertion that reds when it comes back keeps it removed.
gate_denies() {
  if grep -q -- "$1" "$GATE_OUT"; then no "$2 (the step output still says it)"; else ok "$2"; fi
}
# gate_names <must-name> <must-not-name> — D770/D771.
#
# `gate_says` and `gate_denies` read the whole step OUTPUT, which has always
# named the failing job in its log. This reads the `::error::` ANNOTATION ONLY —
# the single line the check-run API carries, and therefore the only line a human
# at the merge button or the merge queue ever sees. Until this slice that line
# said "at least one upstream job" and stopped, on every red where no upstream
# published a REFUSED verdict.
#
# It is a PAIR by construction: naming the job that failed is worth nothing on
# its own (a hardcoded sentence satisfies it), so the same call also refuses an
# annotation that names a job which PASSED in this very run. Everything after
# the first `%0A` belongs to a later clause (the measured-defect list).
gate_names() {
  local ann named nl='%0A'
  ann="$(grep '^::error' "$GATE_OUT" | tr '\n' ' ')"
  named="${ann#*NOT IN THE ALLOW-SET: }"
  if [ -z "$ann" ] || [ "$named" = "$ann" ]; then
    no "  …but the annotation names no job at all: ${ann:-<no ::error:: line>}"
    return 0
  fi
  named="${named%%$nl*}"
  case "$named" in
    *"$1"*) ok "  …and the annotation names the refusing '$1'" ;;
    *) no "  …but the annotation never named the refusing '$1': $ann" ;;
  esac
  case "$named" in
    *"$2"*) no "  …and it names '$2', which PASSED in this run: $ann" ;;
    *) ok "  …and does not name the passing '$2'" ;;
  esac
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
gate_names "console-unit" "cssom-parity"

# (d) THE BYPASS THIS SLICE EXISTS TO CLOSE: cssom-parity `skipped` only because
#     its dependency died, while the dispatcher said it WAS needed.
gate "cssom-parity skipped behind a live gate (upstream died)" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=skipped R_TIER=skipped R_OVERFLOW=skipped R_ESCAPE=success \
  O_CONSOLE=true
gate_says "its gate is 'true', not 'false'" "…and names the reason (a skip is not a pass)"
# …and the SKIP arm accumulates too, not just the failure arm: this red never
# passes through `failure`, so an accumulator wired only there would leave the
# annotation contentless on exactly the bypass this shape exists to close.
gate_names "cssom-parity" "console-unit"

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

# ── THE VERDICT CHANNEL, DRIVEN — cases (l)-(r) ───────────────────────────
# MEASURED BEFORE THIS BLOCK EXISTED: `grep -c 'V_CSSOM\|V_TIER\|V_OVERFLOW'`
# over this file returned 0. Not one case above supplies a verdict, so the
# REFUSED arm of `decide`, the `refusals`/`measured` tallies and the refusal
# banner had NEVER been executed by any test — gutting the entire `REFUSED)`
# arm AND replacing the banner's title with `MUTATED — THE MOON IS MADE OF
# CHEESE` still yielded `205 passed, 0 failed`. The copy in that arm was
# therefore unwitnessable, which is how it came to assert, for two waves, a
# Chrome bring-up failure for refusals that had parsed the stylesheet fine.
# These cases make the arm able to lose, in both directions: what it must say,
# and what it must never say again.

# (l) A REFUSAL IS NAMED AS A REFUSAL — and names a cause SET, never one cause.
gate "cssom-parity REFUSED (a verdict is published)" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=failure R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true V_CSSOM=REFUSED
gate_says "REFUSED TO MEASURE" "…and says the instrument refused, not that CSS is broken"
gate_says "ONE code over MANY causes" "…and says exit 2 is one code over many causes"
gate_says "COVERAGE fault in cloud/priv/static/__preview__" "…and lists the console-side cause the old copy DENIED"
gate_says "READ THAT JOB'S OWN SUMMARY LINE" "…and sends the reader to the instrument that measured it (per-job arm)"
gate_says "READ THE REFUSING JOB'S OWN SUMMARY LINE" "…and again in the aggregate banner"
# The negative half. Every needle below is verbatim from the copy this slice
# removed; each one asserted a single cause the refusing job's own log refutes.
gate_denies "The browser never came up" "…and no longer asserts the browser never came up"
gate_denies "could not bring headless Chrome up" "…and no longer asserts a Chrome bring-up failure"
gate_denies "NOT ONE rule or element was measured" "…and no longer claims nothing was parsed"
gate_denies "Fix the ENVIRONMENT, not the CSS" "…and no longer sends the reader to the runner"
gate_denies "ENVIRONMENT REFUSAL" "…and no longer labels every refusal an environment refusal"

# (m) THE SECOND REFUSAL THE GATE USED TO MISS. console-unit exited 2 on run
#     31322709682 with the same refusal tier-floor-render published, and
#     rendered as a bare `FAIL console-unit: failure` — it had `outputs:` None
#     and its `decide` line took no verdict argument. Delete `V_UNIT` from the
#     workflow's `env:`, or the 4th argument from its `decide` line, and this
#     case is what notices.
gate "console-unit REFUSED (the refusal the gate could not see)" 1 \
  R_CHANGES=success R_UNIT=failure R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true V_UNIT=REFUSED
gate_says "console-unit: failure" "…and names console-unit"
gate_says "REFUSED TO MEASURE" "…and classifies it as a refusal rather than a bare failure"
gate_says "(exit 2): console-unit" "…and carries it into the refusals tally by name"

# (m2) THE THIRD REFUSAL, AND THE LAST ONE STANDING (D776). `path-escape` runs
#      scripts/console-path-escape-check.sh, whose `exit 2` sites include a path
#      set that resolved to an EMPTY pattern — reachable from the bare `--check`
#      invocation this job makes, with no argument at all. Until this slice the
#      ratchet had no `outputs:` block and its `decide` line took three
#      arguments, so that refusal reached the merge button as a bare
#      `FAIL path-escape ratchet: failure`: indistinguishable from a ratchet that
#      MEASURED an uncovered read. The structural half of this is the
#      exit2_without_verdict_output fact in case 8; this is the behavioural half.
gate "path-escape REFUSED (the last unwired refusal)" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=success R_OVERFLOW=success R_ESCAPE=failure \
  O_CONSOLE=true V_ESCAPE=REFUSED
gate_says "path-escape ratchet: failure" "…and names the ratchet"
gate_says "REFUSED TO MEASURE" "…and classifies it as a refusal, not a measured coverage defect"
gate_says "(exit 2): path-escape ratchet" "…and carries it into the refusals tally by name"

# (n) …and BOTH refusals in one run are both named, in decide order.
gate "console-unit and cssom-parity both REFUSED" 1 \
  R_CHANGES=success R_UNIT=failure R_CSSOM=failure R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true V_UNIT=REFUSED V_CSSOM=REFUSED
gate_says "(exit 2): console-unit cssom-parity" "…and the tally names two refusals, not one"

# (o) AN UNPUBLISHED VERDICT MUST STAY UNPUBLISHED. A job that fails without
#     publishing anything is judged exactly as it was before this channel
#     existed — the gate may not invent a refusal it was never told about, and
#     the un-wrapped steps in console-unit (node --check, the two --test runs,
#     smoke, the css gate) are precisely that case.
gate "cssom-parity failed, no verdict published" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=failure R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true
gate_says "cssom-parity: failure" "…and still names the failing job"
gate_denies "REFUSED TO MEASURE" "…and does NOT manufacture a refusal out of an absent verdict"
gate_says "not in the allow-set" "…and reaches the plain red conclusion"

# (p) a MEASURED defect is the opposite claim, and must not borrow the
#     refusal's words.
gate "tier-floor-render MEASURED_DEFECT" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=failure R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true V_TIER=MEASURED_DEFECT
gate_says "This one IS about the console's own bytes" "…and says the defect is real and console-side"
gate_denies "REFUSED TO MEASURE" "…and does not call a measured defect a refusal"

# (q) a verdict outside the published vocabulary is "cannot tell", not a pass.
gate "overflow-guard publishes an unknown verdict" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=success R_TIER=success R_OVERFLOW=failure R_ESCAPE=success \
  O_CONSOLE=true V_OVERFLOW=BANANA
gate_says "outside the published vocabulary" "…and refuses to interpret it"

# (r) verdict=OK on a FAILED job — the instrument said clean and the job died
#     anyway. Still red, and still says why it cannot tell.
gate "cssom-parity publishes OK but the job failed" 1 \
  R_CHANGES=success R_UNIT=success R_CSSOM=failure R_TIER=success R_OVERFLOW=success R_ESCAPE=success \
  O_CONSOLE=true V_CSSOM=OK
gate_says "the instrument said clean and the job" "…and names the contradiction"

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
  # Deliberately NOT "(an ENVIRONMENT fault)", which is what this label used to
  # say: the cause driven here is a MISSING cssom-heads.baseline sidecar — a
  # committed file in cloud/priv/static/__preview__, i.e. the exact repo-side
  # cause the banner's old copy denied could exist.
  ok "…and annotates it REFUSED (here: a missing committed sidecar, not the runner)"
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

# ── THE REFUSAL BANNER'S COPY, PINNED IN BOTH DIRECTIONS ────────────────────
# The aggregate's REFUSED arm stopped naming one cause (cases (l)-(r) above),
# but this per-instrument banner — a DIFFERENT step body, so none of those
# cases could see it — still said "an ENVIRONMENT fault … app.css was never
# parsed … fix the environment". Counted in cssom-parity.mjs, exit 2 has six
# shapes; three are committed files under cloud/priv/static/__preview__ and one
# fires after app.css has already been read. So the banner sent a reader to the
# runner for half of its own causes, while its two siblings (tier-floor-render,
# overflow-guard) already said "ENVIRONMENT or COVERAGE".
#
# This runs the REAL step body at rc=2 — the same extraction css_rc uses, so a
# copy edit that reinstates either removed claim reds here rather than shipping
# unwitnessed. Mutation-proved: restoring the old sentence in
# console-harness.yml turns the two `denies` rows red; deleting the cause-set
# clause turns the two `says` rows red.
# `|| true`: the step body EXITS 1 on a refusal (that is the point of it), and
# this file runs under `set -e`.
REFOUT="$(STUB_RC=2 PATH="$STUBBIN:$PATH" bash --noprofile --norc "$CSS" 2>&1 || true)"
css_copy() {
  if has "$REFOUT" "$1"; then ok "$2"; else no "$2 (the banner never says it)"; fi
}
css_copy_denies() {
  if has "$REFOUT" "$1"; then no "$2 (the banner still says it)"; else ok "$2"; fi
}
# ── THE DEFECT BANNER'S COPY, PINNED THE SAME WAY — AND WHY IT WAS NOT ──────
# The REFUSED banner above got its copy pinned in both directions. The DEFECT
# banner never did: `css_rc "a real parity miss" 1 1 "title=CSSOM parity DEFECT"`
# asserts only the TITLE, so the body could say anything at all and stay green.
# That asymmetry is not a footnote — it is the reason the body was able to
# promise "See the diff above" for THREE causes when only one prints a diff.
# A banner nobody pins is a banner that drifts, and the drift is invisible
# precisely because the title still matches.
#
# Driven at rc=1 through the same stub, so these read the REAL step body.
# `|| true`: the step body EXITS 1 on a defect, and this file runs under `set -e`.
DEFOUT="$(STUB_RC=1 PATH="$STUBBIN:$PATH" bash --noprofile --norc "$CSS" 2>&1 || true)"
def_copy() {
  if has "$DEFOUT" "$1"; then ok "$2"; else no "$2 (the banner never says it)"; fi
}
def_copy_denies() {
  if has "$DEFOUT" "$1"; then no "$2 (the banner still says it)"; else ok "$2"; fi
}
def_copy        "THREE causes"               "the defect banner names a cause SET, not one cause"
def_copy        "ZERO style rules parsed"    "…and names the cause that prints NO diff"
def_copy        "UNREADABLE stylesheet"      "…and names the other cause that prints no diff"
def_copy        "this is not a refusal"      "…and still separates itself from the REFUSED arm"
def_copy_denies "See the diff above."        "…and no longer promises a diff for every cause"
def_copy_denies "rules the browser dropped or rewrote" \
                                             "…and no longer names one cause's mechanism as all three"
# The DEFECT arm must not have drifted into sounding like a refusal — D101's
# line (bring-up refuses, everything after it is a claim about the stylesheet)
# is NOT re-litigated here, and this arm proves the wording change did not do it
# by accident.
def_copy_denies "REFUSED TO MEASURE"         "…and does not describe a measured defect as a refusal"
def_copy_denies "NO claim is being made"     "…and does not disclaim the claim it is making"

css_copy        "SIX causes"                "the refusal banner names a cause SET, not one cause"
css_copy        "cssom-heads.baseline"      "…and names the committed sidecar among them"
css_copy        "do NOT assume the environment" "…and tells the reader not to assume the runner"
css_copy_denies "an ENVIRONMENT fault, not a stylesheet defect" "…and no longer calls every refusal an environment fault"
css_copy_denies "app.css was never parsed"  "…and no longer claims the stylesheet was never read"
css_copy_denies "fix the environment"       "…and no longer sends the reader to the runner"
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
