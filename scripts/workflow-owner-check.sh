#!/usr/bin/env bash
# workflow-owner-check.sh — A WORKFLOW OFF THE PR PATH MUST HAVE A NAMED OWNER.
#
# task-dee226be3107a98b, criterion 4: "every workflow moved off the PR path has a
# named owner and a watcher that reports its main red within 15 minutes".
#
# THE ASYMMETRY THIS GUARDS. A workflow on the PR path has an owner by
# construction -- the author whose PR it reddens. Move it to `push: main` and the
# owner evaporates: it cannot block a merge, no PR surfaces it, and a lane's
# close-out reads its own PRs, never main's health. posix-vacuous-green-census.yml
# was red on main's tip for ELEVEN HOURS over EIGHT runs and cost nobody a second.
# scripts/main-red-owner.sh answers "somebody must be told"; THIS answers "who".
#
# THE POPULATION IS A PREDICATE, NOT A LIST (an enumeration is a snapshot; a
# predicate is a rule). Membership is recomputed from the workflow files every
# run: a workflow is OFF THE PR PATH iff it carries a `push:` arm and no
# `pull_request:` arm. A curated list would go stale in the commit that moved the
# next workflow -- and going stale SILENTLY is the exact failure mode here, since
# the newly-moved workflow is precisely the one nobody is watching.
#
# FIVE REFUSALS, each naming the workflow:
#   1 off the PR path but ABSENT from the registry   -> moved and unowned
#   2 in the registry but no longer off the PR path  -> stale row, owner is fictional
#   3 in the registry but the file does not exist    -> deleted workflow, dead row
#   4 owner is not one of the six repo lanes          -> a name nobody can be pointed at
#   5 a `push:` arm that does not include `main`      -> the watcher CANNOT SEE IT.
#     scripts/main-red-predicate.sh enumerates by push arm and asks for the most
#     recent completed run ON MAIN. A push arm on some other branch renders the
#     workflow invisible to the watcher while looking covered in this file.
#
# WHAT THIS DOES NOT ASSERT, stated rather than implied: the "within 15 minutes"
# half of the criterion. `--cadence` MEASURES the watcher's actual cadence and
# prints a verdict; it does not red, because the watcher
# (.github/workflows/main-red-owner.yml) is owned by another change and this file
# must not pin a number it cannot fix. Read the cadence line; do not infer it.
#
# usage: bash scripts/workflow-owner-check.sh [--selftest] [--cadence]
set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "workflow-owner-check.sh: needs bash; run: bash scripts/workflow-owner-check.sh" >&2
  exit 3
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*) echo "workflow-owner-check.sh: refuses to run in POSIX mode" >&2; exit 3;;
esac

_SELF="${BASH_SOURCE[0]}"; case "$_SELF" in */*) _DIR="${_SELF%/*}";; *) _DIR=".";; esac
_DIR=$(cd "$_DIR" 2>/dev/null && pwd) || { echo "cannot resolve own dir" >&2; exit 4; }
_DEFAULT_ROOT="$(cd "$_DIR/.." && pwd)"

LANES="api console deploy gates cli studio"

# ---- the predicate, in one place so the guard and its selftest cannot disagree --
# Prints, one per line: "<file>\t<off_pr:0|1>\t<push_main:0|1>"
_classify() {
  local wfdir="$1"
  python3 - "$wfdir" <<'PY'
import os, re, sys
d = sys.argv[1]
if not os.path.isdir(d):
    sys.exit(9)
for f in sorted(os.listdir(d)):
    if not f.endswith(('.yml', '.yaml')):
        continue
    t = open(os.path.join(d, f), encoding='utf-8', errors='replace').read()
    m = re.search(r'^on:\s*$(.*?)^\S', t, re.M | re.S)
    blk = m.group(1) if m else ''
    has = lambda k: re.search(r'^\s{2}' + k + r':', blk, re.M) is not None
    push, pr = has('push'), has('pull_request')
    off_pr = 1 if (push and not pr) else 0
    # push arm reaches main? absent `branches:` under push == every branch == main.
    pm = 0
    if push:
        pb = re.search(r'^\s{2}push:\s*$(.*?)(?=^\s{2}\S|\Z)', blk, re.M | re.S)
        body = pb.group(1) if pb else ''
        if not re.search(r'^\s{4}branches', body, re.M):
            pm = 1
        elif re.search(r'\bmain\b', body):
            pm = 1
    print(f"{f}\t{off_pr}\t{pm}")
PY
}

_registry_keys() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
for k in sorted(d.get('owners', {})):
    print(k)
PY
}

_registry_owner() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
print(d.get('owners', {}).get(sys.argv[2], {}).get('owner', ''))
PY
}

run_check() {
  # RESOLVED PER CALL, NOT AT LOAD. A root bound once at file scope makes every
  # fixture-driven selftest arm measure the REAL repo instead of its fixture:
  # all six refusal arms silently passed against a clean tree and reported the
  # same OK line. A guard whose arms cannot fire is the disease one layer out.
  local ROOT="${WOC_ROOT:-$_DEFAULT_ROOT}"
  local wfdir="$ROOT/.github/workflows"
  local reg="${WOC_REGISTRY:-$ROOT/.github/workflow-owners.json}"
  local fails=0

  [ -f "$reg" ] || { echo "REFUSE: registry not found: $reg" >&2; return 4; }
  python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$reg" 2>/dev/null \
    || { echo "REFUSE: registry is not valid JSON: $reg" >&2; return 4; }

  local cls
  cls=$(_classify "$wfdir") || { echo "REFUSE: cannot classify $wfdir" >&2; return 4; }
  [ -n "$cls" ] || { echo "REFUSE: zero workflows classified — a scan that sees nothing proves nothing" >&2; return 4; }

  # CONTROL, every invocation. If the classifier cannot find BOTH shapes it has
  # lost its ability to discriminate, and a clean verdict from it means nothing.
  local n_off n_on
  n_off=$(printf '%s\n' "$cls" | awk -F'\t' '$2==1' | wc -l | tr -d ' ')
  n_on=$(printf '%s\n' "$cls" | awk -F'\t' '$2==0' | wc -l | tr -d ' ')
  if [ "$n_off" -eq 0 ] || [ "$n_on" -eq 0 ]; then
    echo "REFUSE: control failed — classifier saw off_pr=$n_off on_pr=$n_on; it cannot discriminate" >&2
    return 4
  fi

  local keys; keys=$(_registry_keys "$reg")

  # 1 + 5: every off-the-PR-path workflow is registered AND visible to the watcher.
  local f off pm
  while IFS=$'\t' read -r f off pm; do
    [ "$off" = "1" ] || continue
    if ! printf '%s\n' "$keys" | grep -qxF "$f"; then
      echo "RED 1 unowned: $f is off the PR path (push, no pull_request) and has no row in .github/workflow-owners.json"
      fails=$((fails + 1))
      continue
    fi
    if [ "$pm" != "1" ]; then
      echo "RED 5 invisible: $f is registered but its push arm does not include main — scripts/main-red-predicate.sh cannot see its red"
      fails=$((fails + 1))
    fi
    local ow; ow=$(_registry_owner "$reg" "$f")
    if ! printf '%s\n' $LANES | grep -qxF "$ow"; then
      echo "RED 4 bad owner: $f names owner '$ow', which is not one of: $LANES"
      fails=$((fails + 1))
    fi
  done <<< "$cls"

  # 2 + 3: no stale rows.
  while read -r f; do
    [ -n "$f" ] || continue
    if [ ! -f "$wfdir/$f" ]; then
      echo "RED 3 dead row: .github/workflow-owners.json names $f, which does not exist"
      fails=$((fails + 1))
      continue
    fi
    local o2; o2=$(printf '%s\n' "$cls" | awk -F'\t' -v k="$f" '$1==k{print $2}')
    if [ "$o2" != "1" ]; then
      echo "RED 2 stale row: .github/workflow-owners.json claims an owner for $f, but it is back on the PR path — the row is fiction"
      fails=$((fails + 1))
    fi
  done <<< "$keys"

  if [ "$fails" -eq 0 ]; then
    echo "OK: $n_off workflow(s) off the PR path, all named-owned and visible to the main-red watcher; $n_on on the PR path (owned by their PR author)."
    return 0
  fi
  echo "workflow-owner-check: $fails refusal(s)." >&2
  return 1
}

# ---------------------------------------------------------------- cadence ------
run_cadence() {
  local ROOT="${WOC_ROOT:-$_DEFAULT_ROOT}"
  local wf="$ROOT/.github/workflows/main-red-owner.yml"
  echo "── watcher cadence (criterion 4, second half: 'reports its main red within 15 minutes') ──"
  if [ ! -f "$wf" ]; then
    echo "CANNOT READ: $wf is absent — the watcher is not on this ref. (#18483 open at time of writing.)"
    return 0
  fi
  local cron
  cron=$(grep -oE '^\s*- cron: *"[^"]+"' "$wf" | head -1 | sed 's/.*"\(.*\)"/\1/')
  echo "watcher schedule: ${cron:-<none>}"
  case "$cron" in
    '*/'[0-9]*' '*) echo "VERDICT: sub-hourly cron present — check the interval against 15m." ;;
    '') echo "VERDICT: NO cron. Event arms only." ;;
    *) echo "VERDICT: HOURLY OR COARSER — the 15-minute half of criterion 4 is NOT met by the schedule arm." ;;
  esac
  if grep -qE '^\s{2}push:' "$wf"; then
    echo "push arm on main: PRESENT — but it fires on the SAME push that starts the workflows it watches,"
    echo "  so a red caused by push N is first observable to the run started by push N+1 or the next cron."
    echo "  A push arm is therefore not a 15-minute guarantee; a workflow_run arm on the watched workflows would be."
  fi
  return 0
}

# --------------------------------------------------------------- selftest ------
# BOTH ARMS, per the row: an arm that REDS when the guard is broken, and an arm
# that STAYS QUIET when the tree is genuinely fine. Present-in-file is not
# fires-when-it-should, so every refusal below is driven by a real fixture tree.
run_selftest() {
  local pass=0 fail=0 tmp
  _ok() { printf 'PASS %-34s %s\n' "$1" "${2:-}"; pass=$((pass + 1)); }
  _no() { printf 'FAIL %-34s %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

  bash -n "$_SELF" && _ok "parses" "bash -n clean" || _no "parses" "bash -n FAILED"

  tmp=$(mktemp -d) || { echo "mktemp failed" >&2; return 4; }
  mkdir -p "$tmp/.github/workflows"

  # A GENUINELY-FINE tree: one on-PR workflow, one off-PR workflow, registered.
  cat > "$tmp/.github/workflows/onpr.yml" <<'EOF'
name: onpr
on:
  pull_request:
  push:
    branches: [main]
jobs: {}
EOF
  cat > "$tmp/.github/workflows/offpr.yml" <<'EOF'
name: offpr
on:
  push:
    branches: [main]
jobs: {}
EOF
  cat > "$tmp/.github/workflow-owners.json" <<'EOF'
{"owners":{"offpr.yml":{"owner":"gates","why_off_pr":"fixture"}}}
EOF

  local out rc
  out=$(WOC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 0 ]; then _ok "QUIET ARM: clean tree" "exit 0 — ${out}"
  else _no "QUIET ARM: clean tree" "exit $rc, expected 0: $out"; fi

  # RED ARM 1 — the move happens and the registry is not updated. This is the
  # literal failure the criterion exists to stop.
  cat > "$tmp/.github/workflows/newly-moved.yml" <<'EOF'
name: newly-moved
on:
  push:
    branches: [main]
jobs: {}
EOF
  out=$(WOC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'RED 1 unowned: newly-moved.yml'; then
    _ok "RED ARM 1: moved + unregistered" "refused by name"
  else _no "RED ARM 1: moved + unregistered" "exit $rc: $out"; fi
  rm -f "$tmp/.github/workflows/newly-moved.yml"

  # RED ARM 5 — registered, but the push arm cannot reach main, so the watcher is
  # blind to it while this file reads as covered. The dangerous shape.
  cat > "$tmp/.github/workflows/offpr.yml" <<'EOF'
name: offpr
on:
  push:
    branches: [release]
jobs: {}
EOF
  out=$(WOC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'RED 5 invisible: offpr.yml'; then
    _ok "RED ARM 5: watcher-invisible" "refused by name"
  else _no "RED ARM 5: watcher-invisible" "exit $rc: $out"; fi

  # RED ARM 2 — the workflow comes BACK to the PR path; the owner row is now fiction.
  # keepoff.yml is created FIRST so the off-PR population stays non-empty: without
  # it the control fires (correctly) and arm 2 is never measured. A control that
  # pre-empts an arm leaves that arm unproven, which is indistinguishable from
  # passing it.
  cat > "$tmp/.github/workflows/keepoff.yml" <<'EOF'
name: keepoff
on:
  push:
    branches: [main]
jobs: {}
EOF
  cat > "$tmp/.github/workflows/offpr.yml" <<'EOF'
name: offpr
on:
  pull_request:
  push:
    branches: [main]
jobs: {}
EOF
  cat > "$tmp/.github/workflow-owners.json" <<'EOF'
{"owners":{"offpr.yml":{"owner":"gates"},"keepoff.yml":{"owner":"gates"}}}
EOF
  out=$(WOC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'RED 2 stale row: .*offpr.yml'; then
    _ok "RED ARM 2: stale registry row" "refused by name"
  else _no "RED ARM 2: stale registry row" "exit $rc: $out"; fi

  # RED ARM 3 — the workflow is deleted and the row outlives it.
  rm -f "$tmp/.github/workflows/offpr.yml"
  out=$(WOC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q 'RED 3 dead row: .*offpr.yml'; then
    _ok "RED ARM 3: dead registry row" "refused by name"
  else _no "RED ARM 3: dead registry row" "exit $rc: $out"; fi

  # RED ARM 4 — an owner string nobody can be pointed at.
  cat > "$tmp/.github/workflow-owners.json" <<'EOF'
{"owners":{"keepoff.yml":{"owner":"somebody"}}}
EOF
  out=$(WOC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "RED 4 bad owner: keepoff.yml"; then
    _ok "RED ARM 4: owner not a lane" "refused by name"
  else _no "RED ARM 4: owner not a lane" "exit $rc: $out"; fi

  # CONTROL ARM — a tree with NO on-PR workflow must REFUSE, not pass. A scan that
  # cannot see both shapes has lost its discrimination, and its silence is not
  # evidence. (Every arm above ran against a tree where the control held.)
  rm -f "$tmp/.github/workflows/onpr.yml"
  cat > "$tmp/.github/workflow-owners.json" <<'EOF'
{"owners":{"keepoff.yml":{"owner":"gates"}}}
EOF
  out=$(WOC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 4 ] && printf '%s' "$out" | grep -q 'control failed'; then
    _ok "CONTROL: no on-PR shape refuses" "exit 4"
  else _no "CONTROL: no on-PR shape refuses" "exit $rc: $out"; fi

  # THE REAL TREE stays quiet. This is the arm that fails if someone moves a
  # workflow off the PR path in this repo without a row.
  out=$(run_check 2>&1); rc=$?
  if [ $rc -eq 0 ]; then _ok "QUIET ARM: this repo" "${out}"
  else _no "QUIET ARM: this repo" "exit $rc: $out"; fi

  rm -rf "$tmp"
  echo "── $pass passed, $fail failed ──"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) run_selftest; exit $? ;;
  --cadence)  run_cadence;  exit $? ;;
  "")         run_check;    exit $? ;;
  *) echo "usage: bash scripts/workflow-owner-check.sh [--selftest] [--cadence]" >&2; exit 2 ;;
esac
