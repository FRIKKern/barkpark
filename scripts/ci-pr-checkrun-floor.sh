#!/usr/bin/env bash
# ci-pr-checkrun-floor.sh — HOW FEW CHECK RUNS CAN A PR PUSH PUBLISH?
#
# task-dee226be3107a98b, criterion 2: "check runs per PR push measured before and
# after; after is under 20".
#
# THE POINT OF THIS FILE IS THAT THE TARGET IS UNREACHABLE BY TRIGGER EDITS, and
# that this is a MEASURABLE fact rather than an opinion. A check run is published
# per JOB, not per workflow. The four required contexts live in four workflows,
# and those four workflows publish a fixed number of jobs on every head whatever
# the diff touches. That number is the FLOOR: no amount of moving advisory
# workflows to `push: main` can go below it, because none of the movable
# workflows are in it.
#
# MEASURED 2026-09-16 on PR #18492 head 0a193e12e4 (and reproduced on four more
# open heads, 65-69 runs, zero variance in the floor):
#     console-harness  9  (publishes `Console gate`)
#     elixir           8  (publishes `Elixir gate`)
#     cloud            7  (publishes `Cloud gate`)
#     pr-task-gate     2  (publishes `PR references an active task`)
#     ------------------
#     FLOOR           26   > 20, before one advisory workflow is considered.
#
# Reaching <20 therefore requires FOLDING JOBS inside the required workflows,
# which changes the published context names and the `.exclusions` rows in
# .github/required-checks.json — a branch-protection-adjacent OWNER RULING, not a
# lane's trigger edit. See $ORCH/BLOCKED-ON-USER.md.
#
# SECOND MEASUREMENT, because a raw count overstates the damage: roughly half the
# published rows are SKIPPED and cost no runner and no queue slot. `--skipped`
# reports the split. Rollup depth is not queue depth.
#
# usage: bash scripts/ci-pr-checkrun-floor.sh [--selftest] [<pr-number>|<sha>]
set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "ci-pr-checkrun-floor.sh: needs bash" >&2; exit 3
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*) echo "ci-pr-checkrun-floor.sh: refuses to run in POSIX mode" >&2; exit 3;;
esac

_SELF="${BASH_SOURCE[0]}"; case "$_SELF" in */*) _D="${_SELF%/*}";; *) _D=".";; esac
_D=$(cd "$_D" 2>/dev/null && pwd); _DEFAULT_ROOT="$(cd "$_D/.." && pwd)"
REPO="${CPF_REPO:-FRIKKern/barkpark}"
TARGET=20

# The four workflows that publish a required context. DERIVED from the spec file,
# never typed: a hand-typed list is wrong the day the required set changes.
required_workflows() {
  local root="${CPF_ROOT:-$_DEFAULT_ROOT}"
  python3 - "$root" <<'PY'
import json, os, re, sys
root = sys.argv[1]
spec = os.path.join(root, '.github', 'required-checks.json')
ctxs = [c['context'] for c in
        json.load(open(spec))['protection']['required_status_checks']['checks']]
d = os.path.join(root, '.github', 'workflows')
hits = {}
for f in sorted(os.listdir(d)):
    if not f.endswith(('.yml', '.yaml')):
        continue
    t = open(os.path.join(d, f), encoding='utf-8', errors='replace').read()
    for c in ctxs:
        # a job publishes its `name:` as the context; match the literal string
        if re.search(r'name:\s*["\']?' + re.escape(c) + r'["\']?\s*$', t, re.M):
            hits.setdefault(f, []).append(c)
if len(hits) != len(ctxs):
    print("REFUSE: %d required contexts map to %d workflow files — the map is incomplete"
          % (len(ctxs), len(hits)), file=sys.stderr)
    sys.exit(4)
for f, cs in sorted(hits.items()):
    print("%s\t%s" % (f, ",".join(cs)))
PY
}

measure() {
  local ref="$1" sha
  if printf '%s' "$ref" | grep -qE '^[0-9]+$'; then
    sha=$(gh pr view "$ref" --repo "$REPO" --json headRefOid -q .headRefOid) \
      || { echo "REFUSE: cannot read PR $ref" >&2; return 4; }
  else sha="$ref"; fi
  [ -n "$sha" ] || { echo "REFUSE: empty sha" >&2; return 4; }

  local reqmap; reqmap=$(required_workflows) || return 4
  echo "── head $sha  (repo $REPO) ──"
  echo "required-context workflows, derived from .github/required-checks.json:"
  printf '%s\n' "$reqmap" | sed 's/^/  /'

  local runs; runs=$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null) \
    || { echo "REFUSE: cannot read run feed for $sha" >&2; return 4; }
  local nruns; nruns=$(printf '%s' "$runs" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["workflow_runs"]))')
  [ "${nruns:-0}" -gt 1 ] || { echo "REFUSE: control failed — $nruns run(s) on this head; a feed that sees one thing cannot discriminate" >&2; return 4; }

  REQMAP="$reqmap" python3 - "$REPO" "$runs" "$TARGET" <<'PY'
import json, os, subprocess, sys
repo, runs_json, target = sys.argv[1], sys.argv[2], int(sys.argv[3])
reqfiles = {l.split('\t')[0] for l in os.environ['REQMAP'].strip().splitlines()}
runs = json.loads(runs_json)['workflow_runs']
floor = tot = skipped = 0
rows = []
for r in runs:
    j = json.loads(subprocess.run(
        ['gh', 'api', f"repos/{repo}/actions/runs/{r['id']}/jobs?per_page=100"],
        capture_output=True, text=True).stdout or '{"jobs":[]}')
    jobs = j.get('jobs', [])
    base = os.path.basename(r['path'])
    sk = sum(1 for x in jobs if x.get('conclusion') == 'skipped')
    tot += len(jobs); skipped += sk
    if base in reqfiles:
        floor += len(jobs)
    rows.append((len(jobs), sk, base, base in reqfiles))
rows.sort(key=lambda x: -x[0])
print()
for n, sk, b, req in rows:
    print(f"  {n:3d} jobs ({sk:2d} skipped)  {'REQUIRED ' if req else 'advisory '} {b}")
print()
print(f"TOTAL check runs on this head : {tot}")
print(f"  of which SKIPPED (no runner): {skipped}")
print(f"  of which EXECUTED           : {tot - skipped}")
print(f"FLOOR (required workflows)    : {floor}")
print(f"MOVABLE CEILING               : {tot - floor}  (every advisory job, if all moved)")
print(f"TARGET                        : under {target}")
if floor >= target:
    print(f"VERDICT: UNREACHABLE BY TRIGGER EDITS. The floor is {floor}, which is >= {target}, "
          f"so moving 100% of the advisory jobs off the PR path still lands at {floor}. "
          f"Getting under {target} requires folding jobs INSIDE the required workflows, "
          f"which moves published context names and .exclusions rows: an OWNER ruling.")
    sys.exit(2)
print(f"VERDICT: reachable — the floor {floor} is under the target {target}.")
PY
}

run_selftest() {
  local pass=0 fail=0 tmp out rc
  _ok(){ printf 'PASS %-32s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-32s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
  bash -n "$_SELF" && _ok "parses" "bash -n clean" || _no "parses" "FAILED"

  # QUIET ARM: against the real tree, the four required contexts must all map to a
  # workflow file. This is the arm that reds if a required context is renamed or a
  # required workflow is deleted — i.e. if the floor stops meaning what it says.
  out=$(required_workflows 2>&1); rc=$?
  local n; n=$(printf '%s\n' "$out" | grep -c . )
  if [ $rc -eq 0 ] && [ "$n" -eq 4 ]; then _ok "QUIET: 4 required workflows" "$(printf '%s' "$out" | tr '\n' ' ')"
  else _no "QUIET: 4 required workflows" "rc=$rc n=$n: $out"; fi

  # RED ARM: a spec naming a context no workflow publishes must REFUSE, not
  # silently map three of four and report a smaller floor. An under-counted floor
  # is exactly how "under 20" would be falsely declared reachable.
  tmp=$(mktemp -d) || return 4
  mkdir -p "$tmp/.github/workflows"
  cp "$_DEFAULT_ROOT/.github/workflows/cloud.yml" "$tmp/.github/workflows/" 2>/dev/null
  cat > "$tmp/.github/required-checks.json" <<'EOF'
{"protection":{"required_status_checks":{"checks":[
  {"context":"Cloud gate"},{"context":"A Context No Workflow Publishes"}]}}}
EOF
  out=$(CPF_ROOT="$tmp" required_workflows 2>&1); rc=$?
  if [ $rc -eq 4 ] && printf '%s' "$out" | grep -q 'map is incomplete'; then
    _ok "RED: unmappable context refuses" "exit 4"
  else _no "RED: unmappable context refuses" "rc=$rc: $out"; fi

  # QUIET ARM on the same fixture shape: one context, one workflow, maps cleanly.
  cat > "$tmp/.github/required-checks.json" <<'EOF'
{"protection":{"required_status_checks":{"checks":[{"context":"Cloud gate"}]}}}
EOF
  out=$(CPF_ROOT="$tmp" required_workflows 2>&1); rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '^cloud.yml'; then
    _ok "QUIET: fixture maps cleanly" "cloud.yml"
  else _no "QUIET: fixture maps cleanly" "rc=$rc: $out"; fi

  rm -rf "$tmp"
  echo "── $pass passed, $fail failed ──"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) run_selftest; exit $? ;;
  "") echo "usage: bash scripts/ci-pr-checkrun-floor.sh [--selftest] [<pr>|<sha>]" >&2; exit 2 ;;
  *) measure "$1"; exit $? ;;
esac
