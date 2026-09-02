#!/usr/bin/env bash
# deploy-concurrency-check.test.sh — the harness for the deploy-starvation fix
# (task-8e5eae5c71635a5e). Two subjects, one file, because they are two halves
# of one promise: a merge to main must reach production.
#
# PART A — the GATE (scripts/deploy-concurrency-check.sh). Drives it end-to-end
# against planted workflow fixtures and asserts on the EXIT CODE of the whole
# program, not on scan text. Case A2 is the pre-fix stanza VERBATIM as it stood
# on main at e7870b5f17 — the gate must red on it, or it certifies rather than
# measures. Case A1 runs it over the REAL .github/workflows/deploy.yml in this
# tree, so the harness is also the live guard and cannot go green-by-fixture.
#
# PART B — the ALREADY-COVERED EXIT in deploy.yml's `changes` job. The step body
# is EXTRACTED from the workflow with a YAML parser rather than copied, so an
# edit to that step is measured here instead of drifting away from a stale copy.
# It runs against a throwaway git repo with a stubbed `gh` and planted shas; the
# GitHub expressions are substituted, and an unsubstituted `${{` left in the body
# is a hard refusal (exit 2), never a silent pass.
#
# Nothing here reaches the network, a credential, or the real repository. python3
# with PyYAML and git are the only dependencies; their absence is exit 2.
#
# EXIT CODES
#   0  every case passed
#   1  at least one case FAILED
#   2  the harness could not run (no python3/PyYAML/git, extraction failed)
set -uo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
GATE="$REPO_ROOT/scripts/deploy-concurrency-check.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/deploy.yml"

command -v python3 >/dev/null || { echo "HARNESS-UNAVAILABLE: no python3" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "HARNESS-UNAVAILABLE: no PyYAML" >&2; exit 2; }
command -v git >/dev/null || { echo "HARNESS-UNAVAILABLE: no git" >&2; exit 2; }
[ -f "$GATE" ] || { echo "HARNESS-UNAVAILABLE: $GATE missing" >&2; exit 2; }
[ -f "$WORKFLOW" ] || { echo "HARNESS-UNAVAILABLE: $WORKFLOW missing" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }

# expect_rc <label> <want-rc> <file>
expect_rc() {
  local label="$1" want="$2" file="$3" got=0 out
  out="$(DEPLOY_CONCURRENCY_TARGET="$file" bash "$GATE" 2>&1)" || got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$label (rc=$got)"
  else
    bad "$label — wanted rc=$want, got rc=$got" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  fi
}

echo "── PART A: the gate ────────────────────────────────────────────────────"

# A1 — the LIVE workflow. If this ever reds, the fix regressed on main.
expect_rc "the real .github/workflows/deploy.yml passes" 0 "$WORKFLOW"

# A2 — THE RED-BEFORE. Verbatim the stanza that shipped on main at e7870b5f17
# and starved six consecutive push runs on 2026-09-02.
cat >"$TMP/prefix.yml" <<'EOF'
name: Deploy (production)
on:
  push:
    branches: [main]
concurrency:
  group: deploy-production
  cancel-in-progress: false
jobs:
  changes:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF
expect_rc "the PRE-FIX bare literal group reds" 1 "$TMP/prefix.yml"

# A3 — the fix.
cat >"$TMP/fixed.yml" <<'EOF'
name: Deploy (production)
on:
  push:
    branches: [main]
concurrency:
  group: deploy-production-${{ github.event_name == 'push' && github.sha || 'dispatch' }}
  cancel-in-progress: false
jobs:
  changes:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF
expect_rc "a per-sha group with never-cancel passes" 0 "$TMP/fixed.yml"

# A4 — THE NEAR MISS. github.ref is per-BRANCH, so every push to main lands in
# one group again. A gate that only asked for an expression would green this.
cat >"$TMP/perref.yml" <<'EOF'
name: Deploy (production)
on:
  push:
    branches: [main]
concurrency:
  group: deploy-production-${{ github.ref }}
  cancel-in-progress: false
jobs:
  changes:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF
expect_rc "a per-REF group reds — every push to main shares it" 1 "$TMP/perref.yml"

# A5 — per-sha but cancel-in-progress:true. Nothing is evicted, but a re-run of
# the same sha kills a deploy mid-swap.
cat >"$TMP/persha-cancel.yml" <<'EOF'
name: Deploy (production)
on:
  push:
    branches: [main]
concurrency:
  group: deploy-production-${{ github.sha }}
  cancel-in-progress: true
jobs:
  changes:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF
expect_rc "per-sha + cancel-in-progress:true reds" 1 "$TMP/persha-cancel.yml"

# A6 — the ref-guard expression. never-cancel-main-check.sh accepts it (it only
# forbids the literal true); here it is not good enough, because it is a promise
# re-evaluated against whatever refs the workflow gains later.
cat >"$TMP/refguard.yml" <<'EOF'
name: Deploy (production)
on:
  push:
    branches: [main]
concurrency:
  group: deploy-production-${{ github.sha }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  changes:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF
expect_rc "per-sha + the ref-guard EXPRESSION reds — only the literal false passes" 1 "$TMP/refguard.yml"

# A7 — no concurrency block at all. An absence is not a decision.
cat >"$TMP/none.yml" <<'EOF'
name: Deploy (production)
on:
  push:
    branches: [main]
jobs:
  changes:
    runs-on: ubuntu-latest
    steps: [{ run: "true" }]
EOF
expect_rc "a MISSING concurrency block is exit 2, not a pass" 2 "$TMP/none.yml"

# A8 — unparseable YAML must refuse, never certify.
printf 'concurrency:\n  group: [unclosed\n' >"$TMP/broken.yml"
expect_rc "an unparseable workflow is exit 2, not a pass" 2 "$TMP/broken.yml"

# A9 — a typo'd override must not green over nothing.
expect_rc "a MISSING target file is exit 2, not a pass" 2 "$TMP/does-not-exist.yml"

# A10 — the terminal refusal.
argrc=0
bash "$GATE" --whatever >/dev/null 2>&1 || argrc=$?
if [ "$argrc" -eq 2 ]; then ok "an unknown argument refuses at exit 2 (rc=2)"
else bad "an unknown argument must exit 2, got rc=$argrc"; fi

echo ""
echo "── PART B: the already-covered exit in the changes job ──────────────────"

# Extract the `changes` job's detect step body from the REAL workflow.
BODY="$TMP/detect-step.sh"
if ! python3 - "$WORKFLOW" >"$BODY" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["changes"]["steps"]
hit = [s for s in steps if s.get("id") == "f"]
if len(hit) != 1:
    sys.stderr.write("extraction failed: expected exactly one step with id f, got %d\n" % len(hit))
    sys.exit(2)
body = hit[0]["run"]
body = body.replace("${{ github.sha }}", "${TEST_SHA}")
body = body.replace("${{ github.event.before }}", "${TEST_BEFORE}")
sys.stdout.write(body)
PY
then
  echo "HARNESS-UNAVAILABLE: could not extract the changes/f step from deploy.yml" >&2
  exit 2
fi

# NON-VACUITY. If the step grows a GitHub expression this harness does not
# substitute, the body below would run with a literal "${{ ... }}" in it and
# could pass for the wrong reason. Refuse instead.
if grep -q '\${{' "$BODY"; then
  echo "HARNESS-UNAVAILABLE: the extracted step still holds an unsubstituted GitHub expression:" >&2
  grep -n '\${{' "$BODY" >&2
  echo "  add it to the replace() list in this harness before trusting any result." >&2
  exit 2
fi
if ! grep -q 'already covered' "$BODY"; then
  echo "HARNESS-UNAVAILABLE: the extracted step has no already-covered arm — this harness would measure nothing." >&2
  exit 2
fi

# A throwaway repo: A -> B -> C, with an api/ file so the instance filter can fire.
FIX="$TMP/repo"
mkdir -p "$FIX"
(
  cd "$FIX" || exit 2
  git init -q -b main .
  git config user.email h@example.invalid
  git config user.name harness
  mkdir -p docs api
  echo a >docs/a.md; git add -A; git commit -qm A
  echo b >api/b.ex;  git add -A; git commit -qm B
  echo c >api/c.ex;  git add -A; git commit -qm C
) || { echo "HARNESS-UNAVAILABLE: could not build the fixture repo" >&2; exit 2; }
SHA_A="$(git -C "$FIX" rev-parse HEAD~2)"
SHA_B="$(git -C "$FIX" rev-parse HEAD~1)"
SHA_C="$(git -C "$FIX" rev-parse HEAD)"

# A `gh` stub whose `run list` answers with the sha in GH_LAST_SUCCESS_SHA.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# harness stub: only `gh run list ... --jq .[0].headSha` is reachable from the
# extracted step. Anything else is a loud failure, not a silent empty answer.
if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${GH_LAST_SUCCESS_SHA:-}"
  exit 0
fi
echo "gh stub: unexpected invocation: $*" >&2
exit 97
EOF
chmod +x "$TMP/bin/gh"

# run_step <event> <sha> <last-success-sha> <dispatch-targets>
# echoes "<cp> <instance> <marker>" where marker is COVERED or RAN.
run_step() {
  local event="$1" sha="$2" success="$3" targets="${4:-}"
  local outfile="$TMP/gh-output.$RANDOM"
  : >"$outfile"
  local log
  log="$(
    cd "$FIX" &&
    PATH="$TMP/bin:$PATH" \
    GH_LAST_SUCCESS_SHA="$success" \
    GITHUB_EVENT_NAME="$event" \
    GITHUB_OUTPUT="$outfile" \
    TEST_SHA="$sha" \
    TEST_BEFORE="" \
    DISPATCH_TARGETS="$targets" \
    DISPATCH_REASON="harness" \
    bash -eo pipefail "$BODY" 2>&1
  )"
  local rc=$?
  local cp inst marker
  cp="$(grep -m1 '^cp=' "$outfile" | cut -d= -f2)"
  inst="$(grep -m1 '^instance=' "$outfile" | cut -d= -f2)"
  marker=RAN
  grep -q 'already covered' <<<"$log" && marker=COVERED
  printf '%s %s %s rc=%s\n' "${cp:-<none>}" "${inst:-<none>}" "$marker" "$rc"
  [ "$rc" -eq 0 ] || printf '%s\n' "$log" >&2
}

expect_step() {
  local label="$1" want="$2"; shift 2
  local got
  got="$(run_step "$@")"
  if [ "$got" = "$want" ]; then ok "$label"
  else bad "$label" "wanted [$want], got [$got]"; fi
}

# B1 — THE FIX. Our sha is B; the last successful deploy shipped C, which
# descends from B. The box already serves a descendant: stop in one short job.
expect_step "push whose sha is already contained in the last deploy -> cp=false instance=false, COVERED" \
  "false false COVERED rc=0" push "$SHA_B" "$SHA_C"

# B2 — the identical sha. A re-push of exactly what was deployed is covered too.
expect_step "push of the EXACT deployed sha -> COVERED" \
  "false false COVERED rc=0" push "$SHA_C" "$SHA_C"

# B3 — THE CONTROL, and the one that keeps B1 from being a gate that always
# skips: a genuinely new tip must still deploy. api/ moved between A and C.
expect_step "push ahead of the last deploy -> instance=true, NOT covered" \
  "false true RAN rc=0" push "$SHA_C" "$SHA_A"

# B4 — no successful deploy on record. `last_deployed` is empty, so the
# already-covered test must not fire on a fallback diff anchor.
expect_step "no successful run on record -> NOT covered, falls through to the diff" \
  "false true RAN rc=0" push "$SHA_C" ""

# B5 — THE MANUAL REPAIR SURVIVES. A dispatch with targets:both must deploy even
# when the anchor already covers its ref; that is the whole point of the repair
# report-convergence-failure tells a human to run.
expect_step "workflow_dispatch targets=both, anchor already covers -> both true, NOT covered" \
  "true true RAN rc=0" workflow_dispatch "$SHA_B" "$SHA_C" both

# B6 — and a dispatch on `auto` is likewise never short-circuited by the anchor.
# It falls through to the ordinary path diff, which here runs C..B (the ref is
# BEHIND the anchor) and still sees api/ move — so `auto` deploys the instance
# rather than reporting "nothing to do" on a box a human just called stale.
expect_step "workflow_dispatch targets=auto, anchor already covers -> NOT covered, the path diff decides" \
  "false true RAN rc=0" workflow_dispatch "$SHA_B" "$SHA_C" auto

echo ""
printf 'deploy-concurrency-check.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$PASS" -eq 0 ]; then
  echo "HARNESS-UNAVAILABLE: zero cases ran — a green over an empty matrix is not a verdict" >&2
  exit 2
fi
[ "$FAIL" -eq 0 ] || exit 1
