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


echo "── PART C: the main-run gate (scripts/main-run-concurrency-check.sh) ──────"
MGATE="$REPO_ROOT/scripts/main-run-concurrency-check.sh"
[ -f "$MGATE" ] || { echo "HARNESS-UNAVAILABLE: $MGATE missing" >&2; exit 2; }
# expect_mrc <label> <want-rc> <targets…>
expect_mrc() {
  local label="$1" want="$2"; shift 2
  local got=0 out
  out="$(MAIN_CONCURRENCY_TARGETS="$*" bash "$MGATE" 2>&1)" || got=$?
  if [ "$got" -eq "$want" ]; then ok "$label (rc=$got)"; else bad "$label — wanted rc=$want, got rc=$got" "$(printf '%s' "$out" | grep -E '^FAIL|HARNESS' | head -2 | tr '\n' ' ')"; fi
}
# C1 — the LIVE workflows. If this ever reds, the fix regressed on main.
expect_mrc "C1 live elixir.yml + doc-gates.yml keep one group per main sha" 0 \
  "$REPO_ROOT/.github/workflows/elixir.yml" "$REPO_ROOT/.github/workflows/doc-gates.yml"
# C2 — THE RED-BEFORE. Verbatim the stanza both workflows carried on main before
# this fix: per-REF group, never-cancel-main guard. 37 of 40 main runs since
# 10:27Z on 2026-09-02 were cancelled under it.
cat > "$TMP/c2.yml" <<'YML'
name: elixir
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: elixir-${{ github.ref }}
  cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: true
YML
expect_mrc "C2 the pre-fix per-ref main group REDS" 1 "$TMP/c2.yml"
# C3 — per-sha on main but a bare cancel-in-progress:true — never-cancel-main
# is the other half; a RUNNING main run must not be killed either.
sed 's/cancel-in-progress: .*/cancel-in-progress: true/; s/group: .*/group: elixir-${{ github.ref == '"'"'refs\/heads\/main'"'"' \&\& github.sha || github.ref }}/' "$TMP/c2.yml" > "$TMP/c3.yml"
expect_mrc "C3 per-sha group + bare cancel-in-progress:true REDS" 1 "$TMP/c3.yml"
# C4 — per-sha on main with the literal false is also accepted (the deploy shape).
sed 's/cancel-in-progress: .*/cancel-in-progress: false/' "$TMP/c3.yml" > "$TMP/c4.yml"
expect_mrc "C4 per-sha group + literal false is accepted" 0 "$TMP/c4.yml"
# C5 — mentions github.sha but with NO main condition: a per-sha group on PR
# refs too would stop superseding pushes on a branch; the property is per-sha
# ON MAIN, and the expression must say so.
sed 's/group: .*/group: elixir-${{ github.sha }}/' "$TMP/c4.yml" > "$TMP/c5.yml"
expect_mrc "C5 github.sha without a refs\/heads\/main condition REDS" 1 "$TMP/c5.yml"
# C6 — no concurrency block at all: an absence is not a decision (rc 2).
grep -v -E '^concurrency:|^  group:|^  cancel-in-progress:' "$TMP/c4.yml" > "$TMP/c6.yml"
expect_mrc "C6 no concurrency block cannot be measured" 2 "$TMP/c6.yml"
# C7 — one good file and one bad file: the verdict is the worst one (rc 1).
expect_mrc "C7 a green file does not launder a red sibling" 1 "$TMP/c4.yml" "$TMP/c2.yml"
# C8 — a missing target is a refusal, never a pass.
expect_mrc "C8 a missing target is rc 2" 2 "$TMP/does-not-exist.yml"
# C9 — the terminal refusal on a stray argument.
got=0; bash "$MGATE" --bogus >/dev/null 2>&1 || got=$?
if [ "$got" -eq 2 ]; then ok "C9 unknown argument is rc 2 (rc=$got)"; else bad "C9 unknown argument — wanted rc=2, got rc=$got"; fi

echo ""
echo "── PART D: the ssh keepalive leg (task-8811b4b25c529dbe) ───────────────"

# The SECOND half of "a merge to main must reach production": a run that is
# merely QUEUED behind the on-box deploy lock must not be reported FAILED. The
# on-box wait is silent, so without a client keepalive the runner NAT drops the
# ssh session after ~5 min and ssh exits 255 (ten of the last fourteen failed
# deploy.yml runs on main, 2026-09-05..06). PART A case A1 already runs the gate
# over the live workflow; these cases prove the keepalive leg is what makes that
# green MEAN something — that it can still LOSE, and that it is not vacuous on
# the real file.

# grep_out <label> <file> <pattern> — the gate over <file> must print <pattern>.
grep_out() {
  local label="$1" file="$2" pat="$3" out
  out="$(DEPLOY_CONCURRENCY_TARGET="$file" bash "$GATE" 2>&1)" || true
  # A HERESTRING, never `printf | grep -q`: this harness runs under `set -o
  # pipefail` and grep -q exits the moment it matches, so printf dies of SIGPIPE
  # with 141 and the pipeline reports FAILURE on the very case that PASSED.
  if grep -qE "$pat" <<<"$out"; then
    ok "$label"
  else
    bad "$label — no line matching /$pat/" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
}

# D1 — NON-VACUITY on the REAL workflow. A1 greens whether the leg inspected
# seven strings or zero; this pins that it actually found them. The floor is a
# LOWER bound (strings get added), never an exact count.
KA_LIVE="$(DEPLOY_CONCURRENCY_TARGET="$WORKFLOW" bash "$GATE" 2>&1 | sed -n 's/^ssh keepalive: \([0-9][0-9]*\) ssh.*/\1/p')"
if [ -n "$KA_LIVE" ] && [ "$KA_LIVE" -ge 5 ]; then
  ok "D1 the live deploy.yml really has ssh/scp strings under the leg ($KA_LIVE >= 5)"
else
  bad "D1 the keepalive leg inspected ${KA_LIVE:-no} strings in the live workflow — a green over zero strings is not a verdict"
fi

# D2 — THE POSITIVE CONTROL. One string loses the pair; the gate must red.
# Every string, not the first: the defect this forbids is ONE forgotten option
# string on a leg nobody edited, which is exactly how the instance leg was the
# only job that died while the control-plane job in the same run stayed green.
KA_TOTAL_STRIPPED=0
KA_STRIPPED_RED=0
while IFS=: read -r ln _rest; do
  [ -n "$ln" ] || continue
  KA_TOTAL_STRIPPED=$((KA_TOTAL_STRIPPED + 1))
  sed "${ln}s/ -o ServerAliveInterval=[0-9]* -o ServerAliveCountMax=[0-9]*//" "$WORKFLOW" > "$TMP/ka-strip.yml"
  # The mutation must have APPLIED — an anchor that matched nothing would make
  # this case green by doing nothing at all.
  if cmp -s "$WORKFLOW" "$TMP/ka-strip.yml"; then
    bad "D2 line $ln: the strip mutation changed NOTHING — this case would be vacuous"
    continue
  fi
  krc=0
  DEPLOY_CONCURRENCY_TARGET="$TMP/ka-strip.yml" bash "$GATE" >/dev/null 2>&1 || krc=$?
  if [ "$krc" -eq 1 ]; then
    KA_STRIPPED_RED=$((KA_STRIPPED_RED + 1))
  else
    bad "D2 line $ln: stripping the keepalive pair left the gate at rc=$krc, wanted 1"
  fi
done <<EOF
$(grep -n 'SSH="ssh \|SCP="scp ' "$WORKFLOW")
EOF
if [ "$KA_TOTAL_STRIPPED" -gt 0 ] && [ "$KA_STRIPPED_RED" -eq "$KA_TOTAL_STRIPPED" ]; then
  ok "D2 stripping the pair from ANY ONE of the $KA_TOTAL_STRIPPED ssh/scp strings reds the gate"
else
  bad "D2 only $KA_STRIPPED_RED of $KA_TOTAL_STRIPPED stripped strings reddened the gate"
fi

# D3 — the pair is PRESENT but the window does not exceed the 1800 s on-box
# lock wait. A presence-only check would green this and ship a session that
# still dies mid-queue.
sed 's/ServerAliveInterval=30 -o ServerAliveCountMax=90/ServerAliveInterval=30 -o ServerAliveCountMax=60/g' "$WORKFLOW" > "$TMP/ka-short.yml"
cmp -s "$WORKFLOW" "$TMP/ka-short.yml" && bad "D3 the shrink mutation changed nothing — vacuous"
expect_rc "D3 a 30x60=1800s window does not EXCEED the 1800s lock wait — reds" 1 "$TMP/ka-short.yml"

# D4 — THE NEGATIVE DIRECTION. The gate must not be pinned to the literal
# 30/90 it happens to ship: any pair whose product clears the floor passes.
sed 's/ServerAliveInterval=30 -o ServerAliveCountMax=90/ServerAliveInterval=60 -o ServerAliveCountMax=31/g' "$WORKFLOW" > "$TMP/ka-other.yml"
cmp -s "$WORKFLOW" "$TMP/ka-other.yml" && bad "D4 the re-budget mutation changed nothing — vacuous"
expect_rc "D4 a different 60x31=1860s pair also passes (a floor, not a literal)" 0 "$TMP/ka-other.yml"

# D5 — a workflow with no ssh at all. It passes, but it must SAY it measured
# nothing rather than print the same sentence as a file with seven strings.
grep_out "D5 a workflow with no ssh/scp strings says so instead of greening silently" \
  "$TMP/fixed.yml" "ssh keepalive: no SSH=/SCP= strings"

echo ""
printf 'deploy-concurrency-check.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$PASS" -eq 0 ]; then
  echo "HARNESS-UNAVAILABLE: zero cases ran — a green over an empty matrix is not a verdict" >&2
  exit 2
fi
[ "$FAIL" -eq 0 ] || exit 1
