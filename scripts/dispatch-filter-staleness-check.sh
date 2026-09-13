#!/usr/bin/env bash
#
# dispatch-filter-staleness-check.sh — a PR whose head PREDATES a widening of a
# workflow's `pull_request: paths:` filter was dispatched under the OLD filter.
# The widened job never ran on that head, nothing red, and the ABSENCE of a run
# is byte-identical to a pass.
#
# ── THE DEFECT, MEASURED (task-9419f71d6aafe299, filed by deploy-w1 2026-09-13)
#
# PR #17939 merged at 2026-09-12T10:54:49Z (commit 019f60a8b) and added two
# entries to shell-harnesses.yml's `on.pull_request.paths`:
#   .claude/workflows/bp-pds-charter.md
#   tooling/pds/d-number-reservations.tsv
# PR #17933's head b1b11381a was committed at 2026-09-12T10:43:28Z — ELEVEN
# MINUTES EARLIER — and was never re-pushed. Its diff touched
# `.claude/workflows/bp-pds-charter.md` (it minted PDS-D719). The pull_request
# event had already fired against the OLD filter, so `Shell harnesses` never ran
# on that head: `gh api actions/runs?head_sha=b1b11381ad85c…` lists 23 runs and
# NONE of them is Shell harnesses (measured 2026-09-13, that is the control —
# an empty list would have meant a wrong sha, not an absent run). The PR merged
# at 12:26:55Z. The same job then ran on the push to main 24 minutes later and
# FAILED, and main carried that red.
#
# GitHub re-evaluates `paths:` only when an event FIRES. Moving main does not
# fire one. So every open PR is permanently dispatched under whatever filters
# existed at its last push — and the widening it missed is invisible from the
# PR page, because a filtered workflow that does not match emits NO check run at
# all. There is nothing to see and nothing to fix.
#
# ── WHAT THIS SCRIPT DOES, AND WHAT IT DELIBERATELY DOES NOT
#
# It re-evaluates the path filters ON THE MERGE. For each workflow under
# .github/workflows it reads TWO versions:
#   OLD  the file as it exists at the PR HEAD commit — what GitHub's dispatcher
#        actually had in hand when it evaluated that head's event.
#   NEW  the file as it exists at main's tip — what the merge will be governed by.
# A finding is a changed path in the PR's diff that NEW matches and OLD does not.
# That is precisely "a job that will run on main was never given this head."
#
# It does NOT make any filtered workflow required. It cannot: a workflow-level
# `paths:` filter emits no check run on a non-matching head, so a name pinned
# from one reports `is expected.` forever (honest-gates D18, and see
# scripts/shim-trigger-filter-check.sh). The remedy for a finding is a REBASE,
# not a new required context. This check therefore rides an ADVISORY lane that
# already runs on EVERY pull request (pr-meta.yml, unfiltered `on: pull_request`)
# and blocks nothing on its own. The required set — Cloud gate, Console gate,
# Elixir gate, PR references an active task — is untouched.
#
# ── HOW THIS GATE COULD GO BLIND, AND WHAT STOPS EACH
#
#   1. IT SCANS NOTHING. PyYAML resolves the bare key `on:` in a workflow to the
#      BOOLEAN True (YAML 1.1), so a parser that asks for doc["on"] finds no
#      trigger anywhere and reports a beautifully clean zero. The parser below
#      reads `doc.get("on", doc.get(True))`, and — the part that survives a
#      future edit — ZERO workflows carrying a pull_request paths filter is
#      exit 2 CANNOT READ, never exit 0. A repo with 60 workflows always has some.
#   2. AN EMPTY SUBJECT. No changed paths, an unreadable head, a missing tip ref,
#      no python3: each is its own `CANNOT READ:` line and exit 2. A zero finding
#      prints `OK: <n> changed paths x <m> filtered workflows` with both counts,
#      so "clean" is never inferred from silence.
#
# This file uses NO process substitution, so it is not a member of
# scripts/posix-vacuous-green-census.sh's population and needs no interpreter
# guard. Keep it that way.
#
# Exit codes: 0 no stale dispatch · 1 stale dispatch found (named) · 2 CANNOT
# READ — measured nothing · 3 usage.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEAD_REF=""
TIP_REF="origin/main"
PATHS_FILE=""
WORKFLOW_DIR=""
MODE=check
CENSUS_DAYS=30

usage() {
  cat <<'USAGE'
usage: bash scripts/dispatch-filter-staleness-check.sh [options]

  --head <ref>        the PR head commit (default: HEAD)
  --tip <ref>         the merge target (default: origin/main)
  --paths-from <file> newline-separated changed paths (default: git diff
                      --name-only $(git merge-base <tip> <head>)..<head>)
  --workflow-dir <d>  directory of workflow YAML (default: <tip>:.github/workflows
                      for NEW, <head>:.github/workflows for OLD)
  --census [--days N] measure the population: every PR merged in the last N days
                      (default 30) whose head predated a filter widening that
                      matched its diff. Needs `gh` and network.
  --selftest          hermetic fixture matrix, both directions. No git, no network.
  --help

exit: 0 clean · 1 stale dispatch found · 2 CANNOT READ (measured nothing) · 3 usage
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --head) HEAD_REF="${2:-}"; shift 2 ;;
    --tip) TIP_REF="${2:-}"; shift 2 ;;
    --paths-from) PATHS_FILE="${2:-}"; shift 2 ;;
    --workflow-dir) WORKFLOW_DIR="${2:-}"; shift 2 ;;
    --census) MODE=census; shift ;;
    --days) CENSUS_DAYS="${2:-}"; shift 2 ;;
    --selftest) MODE=selftest; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "CANNOT READ: unknown argument '$1'" >&2; usage >&2; exit 3 ;;
  esac
done

have_python() {
  command -v python3 >/dev/null 2>&1
}

# ── The matcher. GitHub's paths globs, in one place, used by every mode. ──────
# `**` spans separators, `*` and `?` do not, a leading `!` NEGATES and the LAST
# matching pattern wins (GitHub's documented rule). Written as a python module so
# the selftest can exercise it directly with no git and no YAML.
PY_MATCHER='
import fnmatch, re, sys

def _rx(pat):
    out, i = [], 0
    while i < len(pat):
        c = pat[i]
        if c == "*":
            if pat[i:i+2] == "**":
                out.append(".*"); i += 2
                continue
            out.append("[^/]*"); i += 1
            continue
        if c == "?":
            out.append("[^/]"); i += 1
            continue
        out.append(re.escape(c)); i += 1
    return re.compile("^" + "".join(out) + "$")

def matches(path, patterns):
    """True if PATH is selected by this paths list. Last match wins; a bare
    negation-only list selects everything not excluded."""
    verdict = None
    for p in patterns:
        neg = p.startswith("!")
        body = p[1:] if neg else p
        if _rx(body).match(path):
            verdict = not neg
    if verdict is None:
        # no pattern spoke. An all-negation list defaults to selected.
        return any(p.startswith("!") for p in patterns)
    return verdict
'

PY_TRIGGERS='
import yaml

def pr_paths(text):
    """The on.pull_request.paths list of a workflow, or None when the workflow
    has no pull_request trigger at all, or [] when it is unfiltered."""
    doc = yaml.safe_load(text)
    if not isinstance(doc, dict):
        return None
    # PyYAML resolves the bare key `on:` to the BOOLEAN True under YAML 1.1.
    on = doc.get("on", doc.get(True))
    if on is None:
        return None
    if isinstance(on, str):
        return [] if on == "pull_request" else None
    if isinstance(on, list):
        return [] if "pull_request" in on else None
    if not isinstance(on, dict):
        return None
    if "pull_request" not in on:
        return None
    pr = on.get("pull_request")
    if not isinstance(pr, dict):
        return []
    paths = pr.get("paths")
    if paths is None:
        return []
    return [str(p) for p in paths]
'

run_check() {
  have_python || { echo "CANNOT READ: python3 is not on PATH; the YAML parser is python3" >&2; exit 2; }
  python3 -c 'import yaml' 2>/dev/null || { echo "CANNOT READ: python3 cannot import yaml (PyYAML); nothing was parsed" >&2; exit 2; }

  cd "$REPO_ROOT" || { echo "CANNOT READ: cannot cd to $REPO_ROOT" >&2; exit 2; }

  local head tip
  head="${HEAD_REF:-HEAD}"
  head="$(git rev-parse --verify "$head^{commit}" 2>/dev/null)" || {
    echo "CANNOT READ: head ref '${HEAD_REF:-HEAD}' does not resolve to a commit" >&2; exit 2; }
  tip="$(git rev-parse --verify "$TIP_REF^{commit}" 2>/dev/null)" || {
    echo "CANNOT READ: tip ref '$TIP_REF' does not resolve to a commit (fetch it first)" >&2; exit 2; }

  local paths_tmp
  paths_tmp="$(mktemp)" || { echo "CANNOT READ: mktemp failed" >&2; exit 2; }
  if [ -n "$PATHS_FILE" ]; then
    [ -r "$PATHS_FILE" ] || { echo "CANNOT READ: --paths-from '$PATHS_FILE' is not readable" >&2; rm -f "$paths_tmp"; exit 2; }
    grep -v '^[[:space:]]*$' "$PATHS_FILE" > "$paths_tmp"
  else
    local mb
    mb="$(git merge-base "$tip" "$head" 2>/dev/null)" || mb=""
    [ -n "$mb" ] || { echo "CANNOT READ: no merge-base between $TIP_REF and the head; the histories are unrelated" >&2; rm -f "$paths_tmp"; exit 2; }
    git diff --name-only "$mb".."$head" > "$paths_tmp" 2>/dev/null || {
      echo "CANNOT READ: git diff $mb..$head failed" >&2; rm -f "$paths_tmp"; exit 2; }
  fi
  local npaths
  npaths="$(grep -c . "$paths_tmp")"
  if [ "$npaths" -eq 0 ]; then
    echo "CANNOT READ: the changed-path set is EMPTY — this run measured nothing" >&2
    rm -f "$paths_tmp"; exit 2
  fi

  local old_tmp new_tmp
  old_tmp="$(mktemp -d)"; new_tmp="$(mktemp -d)"
  if [ -n "$WORKFLOW_DIR" ]; then
    # fixture mode: <dir>/old and <dir>/new
    [ -d "$WORKFLOW_DIR/old" ] && [ -d "$WORKFLOW_DIR/new" ] || {
      echo "CANNOT READ: --workflow-dir '$WORKFLOW_DIR' must contain old/ and new/" >&2
      rm -rf "$old_tmp" "$new_tmp"; rm -f "$paths_tmp"; exit 2; }
    cp "$WORKFLOW_DIR"/old/*.yml "$old_tmp"/ 2>/dev/null
    cp "$WORKFLOW_DIR"/new/*.yml "$new_tmp"/ 2>/dev/null
  else
    local f name
    for f in $(git ls-tree -r --name-only "$tip" -- .github/workflows); do
      case "$f" in *.yml|*.yaml) ;; *) continue ;; esac
      name="$(basename "$f")"
      git show "$tip:$f" > "$new_tmp/$name" 2>/dev/null || :
      git show "$head:$f" > "$old_tmp/$name" 2>/dev/null || :
      [ -s "$old_tmp/$name" ] || rm -f "$old_tmp/$name"
    done
  fi

  local nnew
  nnew="$(ls -1 "$new_tmp" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$nnew" -eq 0 ]; then
    echo "CANNOT READ: zero workflow files read at the tip — the subject is EMPTY" >&2
    rm -rf "$old_tmp" "$new_tmp"; rm -f "$paths_tmp"; exit 2
  fi

  local rc
  OLD_DIR="$old_tmp" NEW_DIR="$new_tmp" PATHS_TMP="$paths_tmp" HEAD_SHA="$head" TIP_SHA="$tip" \
  python3 -c "
$PY_MATCHER
$PY_TRIGGERS
import os, sys

old_dir, new_dir = os.environ['OLD_DIR'], os.environ['NEW_DIR']
changed = [l.strip() for l in open(os.environ['PATHS_TMP']) if l.strip()]

filtered = 0
findings = []
for name in sorted(os.listdir(new_dir)):
    if not name.endswith(('.yml', '.yaml')):
        continue
    try:
        new_paths = pr_paths(open(os.path.join(new_dir, name)).read())
    except Exception as e:
        print('CANNOT READ: %s failed to parse at the tip: %s' % (name, e), file=sys.stderr)
        sys.exit(2)
    if new_paths is None or new_paths == []:
        continue          # no pull_request trigger, or unfiltered: never stale
    filtered += 1
    old_file = os.path.join(old_dir, name)
    if os.path.exists(old_file):
        try:
            old_paths = pr_paths(open(old_file).read())
        except Exception:
            old_paths = None
    else:
        old_paths = None
    newly = []
    for p in changed:
        hit_new = matches(p, new_paths)
        hit_old = (old_paths is not None and old_paths != [] and matches(p, old_paths)) or (old_paths == [])
        if hit_new and not hit_old:
            newly.append(p)
    if newly:
        findings.append((name, newly, 'absent at head' if old_paths is None else 'filter widened'))

if filtered == 0:
    print('CANNOT READ: zero workflows carry an on.pull_request.paths filter. '
          'The parser saw nothing — check the PyYAML bare-\`on:\`-is-True trap.', file=sys.stderr)
    sys.exit(2)

print('subject: %d changed paths x %d path-filtered workflows (head %s, tip %s)'
      % (len(changed), filtered, os.environ['HEAD_SHA'][:9], os.environ['TIP_SHA'][:9]))
if not findings:
    print('OK: no workflow filter widened onto this head after it was pushed.')
    sys.exit(0)
for name, newly, why in findings:
    print('STALE DISPATCH: %s (%s) now matches %s' % (name, why, ', '.join(newly)))
    print('  the pull_request event on this head was evaluated against the OLD filter,')
    print('  so that workflow emitted NO check run — an absence indistinguishable from a pass.')
print('REFUSED: %d workflow(s) will govern this merge that never ran on this head. Rebase and re-push.'
      % len(findings))
sys.exit(1)
"
  rc=$?
  rm -rf "$old_tmp" "$new_tmp"; rm -f "$paths_tmp"
  exit "$rc"
}

# ── CENSUS: the measured population (criterion 0) ─────────────────────────────
run_census() {
  command -v gh >/dev/null 2>&1 || { echo "CANNOT READ: gh is not on PATH; the census reads merged PRs from the API" >&2; exit 2; }
  cd "$REPO_ROOT" || { echo "CANNOT READ: cannot cd to $REPO_ROOT" >&2; exit 2; }
  local since
  since="$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=int(sys.argv[1]))).strftime('%Y-%m-%d'))" "$CENSUS_DAYS" 2>/dev/null)"
  [ -n "$since" ] || { echo "CANNOT READ: could not compute the census window" >&2; exit 2; }
  echo "# census window: PRs merged since $since (${CENSUS_DAYS}d), repo FRIKKern/barkpark"
  local list
  list="$(gh pr list --state merged --limit 1000 --search "merged:>=$since" --json number,headRefOid,mergedAt,title 2>/dev/null)"
  [ -n "$list" ] || { echo "CANNOT READ: gh pr list returned nothing for the window" >&2; exit 2; }
  local total
  total="$(printf '%s' "$list" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  [ "$total" -gt 0 ] || { echo "CANNOT READ: the census window holds ZERO merged PRs — it measured nothing" >&2; exit 2; }
  echo "# merged PRs in window: $total"
  local n flagged=0 unreadable=0
  while IFS=$'\t' read -r n sha merged_at title; do
    [ -n "$sha" ] || continue
    if ! git rev-parse --verify "$sha^{commit}" >/dev/null 2>&1; then
      git fetch -q origin "$sha" 2>/dev/null || true
    fi
    if ! git rev-parse --verify "$sha^{commit}" >/dev/null 2>&1; then
      unreadable=$((unreadable+1))
      echo "UNREADABLE #$n $sha (head object not in this clone)"
      continue
    fi
    local out rc
    out="$("$0" --head "$sha" --tip "$TIP_REF" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ]; then
      flagged=$((flagged+1))
      echo "FLAGGED #$n merged=$merged_at head=${sha:0:9} :: $title"
      printf '%s\n' "$out" | sed -n 's/^STALE DISPATCH/    STALE DISPATCH/p'
    elif [ "$rc" -eq 2 ]; then
      unreadable=$((unreadable+1))
      echo "UNREADABLE #$n ${sha:0:9} :: $(printf '%s' "$out" | sed -n 's/^CANNOT READ: //p' | head -1)"
    fi
  done <<< "$(printf '%s' "$list" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    print("%s\t%s\t%s\t%s" % (r["number"], r["headRefOid"], r["mergedAt"], r["title"][:70]))')"
  echo "# population: $flagged of $total merged PRs dispatched under a stale filter; $unreadable unreadable"
  [ "$flagged" -eq 0 ] && [ "$unreadable" -eq 0 ] && echo "# clean window"
  return 0
}

# ── SELFTEST: hermetic, both directions, no git and no network ───────────────
run_selftest() {
  have_python || { echo "CANNOT READ: python3 is not on PATH" >&2; exit 2; }
  python3 -c 'import yaml' 2>/dev/null || { echo "CANNOT READ: PyYAML is absent" >&2; exit 2; }
  local pass=0 fail=0
  t() { # t <name> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1 (rc=$3)";
    else fail=$((fail+1)); echo "  FAIL $1 (expected rc=$2, got rc=$3)"; fi
  }

  local fx; fx="$(mktemp -d)"
  mkdir -p "$fx/wf/old" "$fx/wf/new"
  # The REAL shape: shell-harnesses gained .claude/workflows/bp-pds-charter.md.
  cat > "$fx/wf/old/shell-harnesses.yml" <<'YEOF'
name: Shell harnesses
on:
  pull_request:
    paths:
      - "scripts/doctor.sh"
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
YEOF
  cat > "$fx/wf/new/shell-harnesses.yml" <<'YEOF'
name: Shell harnesses
on:
  pull_request:
    paths:
      - "scripts/doctor.sh"
      - ".claude/workflows/bp-pds-charter.md"
      - "tooling/pds/d-number-reservations.tsv"
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
YEOF
  # A control workflow that never filters — must never produce a finding.
  cat > "$fx/wf/old/pr-meta.yml" <<'YEOF'
name: pr-meta
on:
  pull_request:
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
YEOF
  cp "$fx/wf/old/pr-meta.yml" "$fx/wf/new/pr-meta.yml"

  # ARM 1 — the #17933 shape: the head's diff touches the newly-filtered path.
  printf '%s\n' '.claude/workflows/bp-pds-charter.md' 'api/lib/barkpark/application.ex' > "$fx/p17933"
  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/p17933" --workflow-dir "$fx/wf" >"$fx/o1" 2>&1
  t "ARM1 #17933's path set is REFUSED" 1 $?
  grep -q 'STALE DISPATCH: shell-harnesses.yml' "$fx/o1" || { fail=$((fail+1)); echo "  FAIL ARM1 names the workflow"; }
  grep -q 'bp-pds-charter.md' "$fx/o1" || { fail=$((fail+1)); echo "  FAIL ARM1 names the path"; }

  # ARM 2 — THE OTHER DIRECTION. Same widening, a diff that does not touch it.
  printf '%s\n' 'api/lib/barkpark/application.ex' 'docs/openapi.json' > "$fx/pclean"
  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/pclean" --workflow-dir "$fx/wf" >"$fx/o2" 2>&1
  t "ARM2 a correctly-dispatched PR is NOT flagged" 0 $?
  grep -q '^OK: no workflow filter widened' "$fx/o2" || { fail=$((fail+1)); echo "  FAIL ARM2 prints the OK line"; }
  grep -q 'subject: 2 changed paths x 1 path-filtered workflows' "$fx/o2" || { fail=$((fail+1)); echo "  FAIL ARM2 prints both counts (a zero must show what it measured)"; }

  # ARM 3 — an already-present filter entry is NOT a finding (no widening).
  printf '%s\n' 'scripts/doctor.sh' > "$fx/pold"
  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/pold" --workflow-dir "$fx/wf" >/dev/null 2>&1
  t "ARM3 a path the OLD filter already matched is clean" 0 $?

  # ARM 4 — a workflow that did not exist at the head at all.
  mkdir -p "$fx/wf2/old" "$fx/wf2/new"
  cp "$fx/wf/new/shell-harnesses.yml" "$fx/wf2/new/brand-new.yml"
  cp "$fx/wf/old/pr-meta.yml" "$fx/wf2/old/pr-meta.yml"; cp "$fx/wf/old/pr-meta.yml" "$fx/wf2/new/pr-meta.yml"
  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/p17933" --workflow-dir "$fx/wf2" >"$fx/o4" 2>&1
  t "ARM4 a workflow ABSENT at the head is refused" 1 $?
  grep -q 'absent at head' "$fx/o4" || { fail=$((fail+1)); echo "  FAIL ARM4 says why"; }

  # ARM 5..8 — THE LOUD REFUSALS. None may be byte-identical to a zero finding.
  : > "$fx/pempty"
  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/pempty" --workflow-dir "$fx/wf" >"$fx/o5" 2>&1
  t "ARM5 an EMPTY changed-path set is CANNOT READ, not clean" 2 $?
  grep -q '^CANNOT READ: the changed-path set is EMPTY' "$fx/o5" || { fail=$((fail+1)); echo "  FAIL ARM5 distinct line"; }
  grep -q '^OK:' "$fx/o5" && { fail=$((fail+1)); echo "  FAIL ARM5 must not also print OK"; }

  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/nope-not-here" --workflow-dir "$fx/wf" >"$fx/o6" 2>&1
  t "ARM6 an unreadable --paths-from is CANNOT READ" 2 $?
  grep -q '^CANNOT READ: --paths-from' "$fx/o6" || { fail=$((fail+1)); echo "  FAIL ARM6 distinct line"; }

  mkdir -p "$fx/wfempty/old" "$fx/wfempty/new"
  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/p17933" --workflow-dir "$fx/wfempty" >"$fx/o7" 2>&1
  t "ARM7 ZERO workflows read is CANNOT READ, not clean" 2 $?
  grep -q '^CANNOT READ: zero workflow files' "$fx/o7" || { fail=$((fail+1)); echo "  FAIL ARM7 distinct line"; }

  mkdir -p "$fx/wfnofilter/old" "$fx/wfnofilter/new"
  cp "$fx/wf/old/pr-meta.yml" "$fx/wfnofilter/old/pr-meta.yml"
  cp "$fx/wf/old/pr-meta.yml" "$fx/wfnofilter/new/pr-meta.yml"
  bash "$0" --head HEAD --tip HEAD --paths-from "$fx/p17933" --workflow-dir "$fx/wfnofilter" >"$fx/o8" 2>&1
  t "ARM8 ZERO path-FILTERED workflows is CANNOT READ (the PyYAML True trap)" 2 $?
  grep -q "bare-\`on:\`-is-True" "$fx/o8" || { fail=$((fail+1)); echo "  FAIL ARM8 names the trap"; }

  bash "$0" --frobnicate >"$fx/o9" 2>&1
  t "ARM9 an unknown argument is usage (3), never a clean 0" 3 $?

  # ARM 10..13 — the matcher itself, the part a YAML change cannot reach.
  python3 -c "
$PY_MATCHER
import sys
c=[('a/b.md',['a/*.md'],True),
   ('a/b/c.md',['a/*.md'],False),
   ('a/b/c.md',['a/**'],True),
   ('x.md',['**','!x.md'],False),
   ('y.md',['**','!x.md'],True),
   ('tooling/pds/d-number-reservations.tsv',['tooling/pds/d-number-reservations.tsv'],True)]
bad=[t for t in c if matches(t[0],t[1])!=t[2]]
print('  ok   ARM10 glob matcher: %d/%d' % (len(c)-len(bad), len(c)))
sys.exit(1 if bad else 0)
" || { fail=$((fail+1)); echo "  FAIL ARM10 glob matcher"; }
  pass=$((pass+1))

  # ARM 11 — the bare-`on:`-is-True parse, asserted DIRECTLY.
  python3 -c "
$PY_TRIGGERS
import sys
txt='''name: x
on:
  pull_request:
    paths: ['a/*.md']
'''
p = pr_paths(txt)
assert p == ['a/*.md'], p
import yaml
d = yaml.safe_load(txt)
assert 'on' not in d and True in d, 'PyYAML no longer folds bare on: to True — revisit the parser'
print('  ok   ARM11 bare \`on:\` reads as boolean True and the parser still finds the filter')
" || { fail=$((fail+1)); echo "  FAIL ARM11 PyYAML True fold"; }
  pass=$((pass+1))

  rm -rf "$fx"
  echo "selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

case "$MODE" in
  check) run_check ;;
  census) run_census ;;
  selftest) run_selftest; exit $? ;;
  *) usage >&2; exit 3 ;;
esac
