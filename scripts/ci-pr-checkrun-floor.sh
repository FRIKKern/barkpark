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
# RE-MEASURED 2026-09-16 AFTER REBASING ONTO origin/main (the first filing of this
# number was taken against a main 35 commits older, so it was re-derived rather
# than inherited). On the two heads whose four required runs had all CONCLUDED:
#     console-harness  9  (publishes `Console gate`)
#     elixir           8  (publishes `Elixir gate`)
#     cloud            7  (publishes `Cloud gate`)
#     pr-task-gate     2  (publishes `PR references an active task`)
#     ------------------
#     FLOOR           26   > 20, before one advisory workflow is considered.
#
# THE FIRST FILING ALSO CLAIMED "ZERO VARIANCE IN THE FLOOR" AND THAT CLAIM WAS
# FALSE — RETRACTED HERE RATHER THAN QUIETLY DROPPED. Re-measuring four open heads
# read 26 (#18568), 26 (#18554), 24 (#18558) and 22 (#18573). The spread is NOT a
# property of the repo; it is THIS SCRIPT reading a run that had not finished
# creating its job rows. Proved by asking the run feed directly: every head that
# read low had a required run at `status: in_progress` (#18573 elixir + cloud,
# #18558 console-harness), and every head that read 26 had all four at
# `completed`. A job count taken mid-run is a PREFIX of the real one, so the old
# "zero variance" line was reporting the instrument's own sampling noise as a
# property of the subject.
#
# THAT IS WHY `measure` NOW REFUSES ON AN UNFINISHED HEAD (exit 4) instead of
# printing the smaller number. The undercount direction is the fail-safe one — a
# short count argues AGAINST this script's own verdict — but a number that is
# wrong in a safe direction is still wrong, and the number is what gets quoted.
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

# THE COMPLETENESS CONTROL. Reads a run feed and the required-workflow file set
# and prints one `<file>\t<status>` row per required run that has NOT concluded.
# Silence means every required run is `completed` and the job counts below are
# final. Split out of `measure` so the selftest can drive it from FIXTURES — a
# control that can only be exercised against the live API is a control nobody
# ever sees fire.
incomplete_required_runs() {
  REQMAP="$1" python3 - "$2" <<'PY'
import json, os, sys
reqfiles = {l.split('\t')[0] for l in os.environ['REQMAP'].strip().splitlines() if l.strip()}
for r in json.loads(sys.argv[1]).get('workflow_runs', []):
    if os.path.basename(r.get('path', '')) in reqfiles and r.get('status') != 'completed':
        print("%s\t%s" % (os.path.basename(r['path']), r.get('status')))
PY
}

# THE TRUNCATION CONTROL. `gh api ... ?per_page=100` WITHOUT `--paginate` returns
# AT MOST 100 items and says nothing about it: the JSON simply ends. Every count
# below is then a PREFIX of the real one, in the direction that argues FOR this
# script's own verdict — a short total makes the movable ceiling look smaller and
# the floor look closer to the whole story. That is the worst possible direction
# for a measurement instrument to be wrong in.
#
# Measured 2026-09-17 on head 1743cdd15b: run feed total_count=23, largest jobs
# feed (Shell harnesses) total_count=54. NEITHER TRUNCATES TODAY, so this guard
# is a RATCHET, not a bug fix — it exists so that the day a head crosses 100 the
# script REFUSES instead of quietly reporting a prefix. A fleet lead read a
# FALSE "required context absent" off exactly this trap today on a head that
# rendered 133 check-run names.
#
# Takes a feed and the key holding its item array; prints a `<label>\t<got>/<total>`
# row when the page is short, and NOTHING when it is complete.
feed_truncated() {
  LABEL="$1" KEY="$2" python3 - "$3" <<'PY'
import json, os, sys
d = json.loads(sys.argv[1])
items = d.get(os.environ['KEY'], [])
total = d.get('total_count')
if total is not None and len(items) < total:
    print("%s\t%d/%d" % (os.environ['LABEL'], len(items), total))
PY
}

# ── the full-oid gate (task-0a44c3bc96baa8cc) ────────────────────────────────
# `repos/<r>/actions/runs?head_sha=` matches the FULL 40-character oid ONLY.
# Handed an abbreviation it returns HTTP 200 with an EMPTY workflow_runs list —
# well-formed, so no transport or shape guard fires — and the caller then reads
# "no runs on this head" off a query the endpoint simply refused to match. That
# is the failed-read-equals-zero class; it was MEASURED on main-gate-watch.sh,
# where `--sha 769c39bd6` said MISSING/exit 1 in the same minute the full oid
# said WAITING/exit 2. Widen here, before the feed is queried, or refuse.
# Prints the 40-character oid, or the single token UNRESOLVED.
cpf_full_oid() {
  local sha="$1" full
  case "$sha" in
    ""|*[!0-9a-fA-F]*) echo "UNRESOLVED"; return 0 ;;
  esac
  if [ "${#sha}" -eq 40 ]; then printf '%s\n' "$sha" | tr 'A-F' 'a-f'; return 0; fi
  [ "${#sha}" -ge 4 ] || { echo "UNRESOLVED"; return 0; }
  full="$(git -C "$(cd "$(dirname "$0")/.." && pwd)" rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null)"
  [ "${#full}" -eq 40 ] || full="$(gh api "repos/$REPO/commits/$sha" 2>/dev/null | jq -r '.sha // ""' 2>/dev/null)"
  if [ "${#full}" -eq 40 ]; then printf '%s\n' "$full"; else echo "UNRESOLVED"; fi
}

measure() {
  local ref="$1" sha
  if printf '%s' "$ref" | grep -qE '^[0-9]+$'; then
    sha=$(gh pr view "$ref" --repo "$REPO" --json headRefOid -q .headRefOid) \
      || { echo "REFUSE: cannot read PR $ref" >&2; return 4; }
  else
    # A bare ref is OPERATOR-SUPPLIED and can arrive abbreviated; headRefOid
    # above is always 40 chars. Widen or refuse BEFORE the run feed is queried
    # — see cpf_full_oid.
    sha="$(cpf_full_oid "$ref")"
    if [ "$sha" = "UNRESOLVED" ]; then
      echo "REFUSE: '$ref' is not a full 40-character commit oid and could not be widened to one; actions/runs?head_sha= matches the FULL oid only and would answer an EMPTY feed for it" >&2
      return 4
    fi
    [ "$sha" = "$ref" ] || echo "resolved '$ref' to the full oid $sha (the run feed matches the full oid only)" >&2
  fi
  [ -n "$sha" ] || { echo "REFUSE: empty sha" >&2; return 4; }

  local reqmap; reqmap=$(required_workflows) || return 4
  echo "── head $sha  (repo $REPO) ──"
  echo "required-context workflows, derived from .github/required-checks.json:"
  printf '%s\n' "$reqmap" | sed 's/^/  /'

  local runs; runs=$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null) \
    || { echo "REFUSE: cannot read run feed for $sha" >&2; return 4; }
  local nruns; nruns=$(printf '%s' "$runs" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["workflow_runs"]))')
  [ "${nruns:-0}" -gt 1 ] || { echo "REFUSE: control failed — $nruns run(s) on this head; a feed that sees one thing cannot discriminate" >&2; return 4; }

  local short; short=$(feed_truncated "run feed" workflow_runs "$runs")
  if [ -n "$short" ]; then
    echo "REFUSE: truncation control failed — the run feed is a PREFIX, so every count below would be short:" >&2
    printf '%s\n' "$short" | sed 's/^/  /' >&2
    echo "  (this endpoint needs --paginate; a short total understates the movable ceiling)" >&2
    return 4
  fi

  local unfinished; unfinished=$(incomplete_required_runs "$reqmap" "$runs")
  if [ -n "$unfinished" ]; then
    echo "REFUSE: completeness control failed — a required-context run on this head has not concluded, so its job rows are a PREFIX and the floor would read LOW:" >&2
    printf '%s\n' "$unfinished" | sed 's/^/  still /' >&2
    echo "  (re-run once these conclude; a mid-run count is the instrument, not the repo)" >&2
    return 4
  fi

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
    jtot = j.get('total_count')
    if jtot is not None and len(jobs) < jtot:
        sys.stderr.write(
            f"REFUSE: truncation control failed — jobs feed for {os.path.basename(r['path'])} "
            f"returned {len(jobs)} of {jtot}; the per-workflow counts below would be a PREFIX.\n")
        sys.exit(4)
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

  # ── THE COMPLETENESS CONTROL, DRIVEN BOTH WAYS OFF FIXTURES ──────────────
  # This is the arm that would have caught the retracted "zero variance" claim in
  # the header. The fixture map is deliberately the two-file shape, not the real
  # four, so the arms exercise nothing but the predicate.
  local rmap; rmap=$(printf 'cloud.yml\tCloud gate\nelixir.yml\tElixir gate\n')

  # RED ARM: one required run mid-flight must be NAMED. Revert the `!= completed`
  # test in incomplete_required_runs and this arm goes silent — which is exactly
  # the state that read 22 instead of 26.
  out=$(incomplete_required_runs "$rmap" '{"workflow_runs":[
    {"path":".github/workflows/cloud.yml","status":"completed"},
    {"path":".github/workflows/elixir.yml","status":"in_progress"}]}')
  if printf '%s' "$out" | grep -q '^elixir\.yml.in_progress$'; then
    _ok "RED: in-flight required run named" "$out"
  else _no "RED: in-flight required run named" "got: [$out]"; fi

  # QUIET ARM: the same shape with both concluded must print NOTHING. A control
  # that fires on a healthy head is a control the fleet learns to ignore.
  out=$(incomplete_required_runs "$rmap" '{"workflow_runs":[
    {"path":".github/workflows/cloud.yml","status":"completed"},
    {"path":".github/workflows/elixir.yml","status":"completed"}]}')
  if [ -z "$out" ]; then _ok "QUIET: all concluded is silent" "no rows"
  else _no "QUIET: all concluded is silent" "got: [$out]"; fi

  # DISCRIMINATION CONTROL: an ADVISORY workflow still running is irrelevant to
  # the floor (it is never summed into it), so it must NOT refuse. Without this
  # arm the predicate could be `status != completed` over ALL runs and both arms
  # above would still pass, while the script refused on nearly every live head.
  out=$(incomplete_required_runs "$rmap" '{"workflow_runs":[
    {"path":".github/workflows/cloud.yml","status":"completed"},
    {"path":".github/workflows/elixir.yml","status":"completed"},
    {"path":".github/workflows/doc-gates.yml","status":"in_progress"}]}')
  if [ -z "$out" ]; then _ok "CONTROL: advisory in-flight ignored" "no rows"
  else _no "CONTROL: advisory in-flight ignored" "got: [$out]"; fi

  # ── THE TRUNCATION CONTROL, DRIVEN BOTH WAYS OFF FIXTURES ────────────────
  # These are the arms that red if the `len(items) < total` test is removed. They
  # run offline: the trap is a property of the PAGE, not of the network.

  # RED ARM: a page holding 100 of 133 must be NAMED. Delete the comparison in
  # feed_truncated and this arm goes silent — which is the state in which the
  # script reports a prefix as if it were the whole count.
  out=$(feed_truncated "run feed" workflow_runs \
    "{\"total_count\":133,\"workflow_runs\":[$(python3 -c 'print(",".join(["{}"]*100))')]}")
  if printf '%s' "$out" | grep -q '^run feed.100/133$'; then
    _ok "RED: short page named" "$out"
  else _no "RED: short page named" "got: [$out]"; fi

  # QUIET ARM: a COMPLETE page must print nothing. A truncation guard that fires
  # on every healthy head is a guard the fleet disables. This is the live shape:
  # head 1743cdd15b's run feed really did read 23 of 23 on 2026-09-17.
  out=$(feed_truncated "run feed" workflow_runs \
    "{\"total_count\":23,\"workflow_runs\":[$(python3 -c 'print(",".join(["{}"]*23))')]}")
  if [ -z "$out" ]; then _ok "QUIET: complete page silent" "23/23"
  else _no "QUIET: complete page silent" "got: [$out]"; fi

  # DISCRIMINATION CONTROL: a feed with NO total_count key must not be called
  # short. Without this arm the predicate could be `len(items) < 100` — which
  # passes both arms above and then refuses on every small healthy head.
  out=$(feed_truncated "jobs feed" jobs '{"jobs":[{},{}]}')
  if [ -z "$out" ]; then _ok "CONTROL: absent total_count ignored" "no rows"
  else _no "CONTROL: absent total_count ignored" "got: [$out]"; fi

  # SECOND DISCRIMINATION CONTROL: the predicate must read the KEY it is given,
  # not a hardcoded one. A jobs feed of 54 of 54 is the real Shell-harnesses
  # shape measured 2026-09-17 — the largest single jobs feed in the repo.
  out=$(feed_truncated "jobs feed" jobs \
    "{\"total_count\":54,\"jobs\":[$(python3 -c 'print(",".join(["{}"]*54))')]}")
  if [ -z "$out" ]; then _ok "CONTROL: jobs key honoured (54/54)" "no rows"
  else _no "CONTROL: jobs key honoured (54/54)" "got: [$out]"; fi

  rm -rf "$tmp"
  echo "── $pass passed, $fail failed ──"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) run_selftest; exit $? ;;
  "") echo "usage: bash scripts/ci-pr-checkrun-floor.sh [--selftest] [<pr>|<sha>]" >&2; exit 2 ;;
  *) measure "$1"; exit $? ;;
esac
