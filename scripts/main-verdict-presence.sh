#!/usr/bin/env bash
# main-verdict-presence.sh — main's tip carries a VERDICT from every workflow
# that claims to guard main, or this screams. Keyed on ABSENCE, never on red.
#
# THE HOLE IT FILLS (measured 2026-09-06, task-6cd940f66125a079)
#
# scripts/main-gate-watch.sh watches the four contexts branch protection
# requires. A workflow that is NOT in that set and whose run on the tip never
# executed publishes NO context at all — and an absent context is not a red
# context, so that watch has nothing to look at. Two real main shas prove it:
#
#   0097c711f209293924e9672fa9f4de78afeff015
#   3b5d07ca69a3af5c40bb074e31f1d603ccf55a66
#
# On BOTH, the runs for compose-smoke, go-format, go-tests,
# required-checks-drift and search-template-gates concluded `cancelled` — the
# next merge collapsed them under `cancel-in-progress: true`. Zero verdicts,
# zero alarms. go-tests caught two real main-reds that same day (#16366,
# #16474), so a silently absent go-tests verdict is an untested main that looks
# fine.
#
# WHY NOT "JUST MAKE THEM REQUIRED" (the tempting wrong answer)
#
# Promoting the six to the protected set re-creates the 55-context blast the CI
# diet (#16500/#16502) removed, and makes a CANCELLABLE context required — a
# context that can be collapsed to nothing cannot be a precondition for
# anything. This script therefore renders NO context that any merge waits on. It
# is an observer of main's tip, and it has no authority over any pull request.
#
# ── WHAT "A VERDICT" MEANS HERE, AND WHAT IT DOES NOT ────────────────────────
#
# PRESENT: a workflow run on the tip that is `completed` with a conclusion in
# the enumerated verdict set — success, failure, neutral, timed_out,
# action_required. The question is whether the workflow ANSWERED, never whether
# it answered green: a red verdict is already scripts/main-gate-watch.sh's
# subject and this file deliberately stays silent about it.
#
# So the run-rollup laundering class (a `continue-on-error` job that reds while
# the run rolls up `success`) cannot mislead this read: laundering moves a
# verdict from `failure` to `success`, and BOTH are PRESENT. The rollup is read
# only for existence, and existence is the one property it cannot fake.
#
# ABSENT, and each of these screams:
#   CANCELLED        completed, conclusion `cancelled`. The measured shape.
#   STARTUP_FAILURE  completed, conclusion `startup_failure` — valid YAML,
#                    invalid job shape: a 0s run with zero jobs. Matched as a
#                    WHOLE TOKEN, because a substring test for `failure` also
#                    matches this and would silently file it as a verdict.
#   NO_RUN           no run of that workflow on this sha at all, for a workflow
#                    that is OWED one unconditionally (see the tiers below).
#
# DECLINED, printed and NOT screamed: completed with conclusion `skipped` —
# every job's `if:` was false. The workflow was asked and it declined on
# purpose. That IS a verdict-shaped absence and it is a real defect class ("a
# path-filtered job that SKIPS reports success"), but it is a DIFFERENT one with
# a different owner; folding it in here would drown this read in a baseline.
# Counted and printed on its own line so it can never be silently zero.
#
# ── THE EXPECTED SET IS DERIVED FROM THE TREE, IN TWO TIERS ──────────────────
#
# There is no hand-written list of watched workflows anywhere in this file. The
# set is computed by parsing every .github/workflows/*.yml and keeping those
# whose `on.push` arm reaches branch main. An allowlist here would BE the
# defect: it goes stale the day somebody adds a workflow, and the staleness is
# invisible by construction — which is the same disease one level up.
#
#   ALWAYS      the push arm carries no `paths:`/`paths-ignore:` filter, so
#               EVERY push to main owes this workflow a run. NO_RUN is a scream.
#   CONDITIONAL the push arm is paths-filtered, so whether a run is owed depends
#               on what the commit touched. A run's EXISTENCE proves it was
#               owed; its ABSENCE is indistinguishable from a filter that
#               correctly declined. So for these, a CANCELLED or
#               STARTUP_FAILURE run screams, and NO_RUN is reported as
#               NOT_OWED and stays silent.
#
# THAT BOUND IS STATED, NOT HIDDEN. Re-implementing GitHub's filter-pattern
# glob semantics (`**`, `*`, `?`, `!`) to decide owed-ness for the CONDITIONAL
# tier would put a second, subtly-wrong matcher in the tree, and a matcher that
# under-matches produces exactly the silent green this file exists to abolish.
# The tier split buys the whole measured population anyway: go-tests,
# go-format, compose-smoke, required-checks-drift and search-template-gates all
# HAD runs on both specimen shas — cancelled ones.
#
# ── THE RATCHET ──────────────────────────────────────────────────────────────
#
# .github/main-push-workflows.txt is a committed transcript of the derived set,
# one `<path> <tier>` row each. It is NOT consulted to build the expected set —
# the tree is, every run — it is compared against it. A workflow that joins or
# leaves the main-push population, or moves between tiers, makes the derived set
# differ from the transcript and this exits 3. `--write-manifest` regenerates
# it, and doing so is a diff a human reads. A ratchet is not an allowlist: an
# allowlist decides WHAT is watched, this one only notices that what is watched
# CHANGED.
#
# ── THE WAITING ARM (the same discriminator as main-gate-watch.sh) ───────────
#
# A tip whose runs are still being created or are still executing has absences
# that mean "not yet", not "never". If ANY run on the tip is not `completed`,
# every absence on that tip is WAITING (exit 2). If the tip carries ZERO runs
# at all, that is WAITING too and not a mass scream: an empty payload on a
# seconds-old tip is the shape that made a `push:` trigger a regression for the
# sibling watch. No age threshold ships here — that constant was measured and
# rejected in scripts/main-gate-watch.sh's header, and the rejection holds
# verbatim: `grep -c GRACE scripts/main-verdict-presence.sh` is 0.
#
# EXIT CODES  0 = every OWED workflow published a verdict on the tip
#             1 = SCREAM — at least one owed workflow published none
#             2 = WAITING — a run on the tip is not terminal, or the tip has no
#                 runs yet; absences on it are premature
#             3 = CONFIGURATION FAULT — the tree, the manifest, or the runs feed
#                 could not be read, or the derived set drifted from the manifest
#
# USAGE
#   scripts/main-verdict-presence.sh
#   scripts/main-verdict-presence.sh --repo O/R --branch main
#   scripts/main-verdict-presence.sh --sha <sha> --runs-file <f> \
#       [--workflows-dir <d>] [--manifest <f>] [--no-manifest]
#   scripts/main-verdict-presence.sh --write-manifest

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$REPO_ROOT/.github/required-checks.json"
WORKFLOWS_DIR="$REPO_ROOT/.github/workflows"
MANIFEST="$REPO_ROOT/.github/main-push-workflows.txt"

RUNS_FILE=""
SHA_OVERRIDE=""
REPO_OVERRIDE=""
BRANCH_OVERRIDE=""
WRITE_MANIFEST=0
CHECK_MANIFEST=1

say() { echo "$*"; }
red() { echo "$*" >&2; }

spec_repo()   { [ -f "$SPEC" ] && jq -r '.repo   // empty' "$SPEC" 2>/dev/null || echo ""; }
spec_branch() { [ -f "$SPEC" ] && jq -r '.branch // empty' "$SPEC" 2>/dev/null || echo ""; }

# ── authority 1: the tree ────────────────────────────────────────────────────
# Prints TSV `<workflow path> <tier>` for every workflow whose push arm reaches
# main, or the single token UNREADABLE. `on:` is deliberately fetched under BOTH
# the string key and the boolean True: YAML 1.1 resolves a bare `on:` to a
# boolean, so a parser that only looks for the string finds NOTHING in every
# GitHub workflow ever written and reports a serenely empty expected set.
derive_expected_set() {
  local dir="$1" out rc
  out="$(python3 - "$dir" 2>&1 <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML is not importable\n")
    sys.exit(2)

d = sys.argv[1]
if not os.path.isdir(d):
    sys.stderr.write("not a directory: %s\n" % d)
    sys.exit(2)

names = [n for n in sorted(os.listdir(d)) if n.endswith((".yml", ".yaml"))]
if not names:
    sys.stderr.write("zero workflow files in %s\n" % d)
    sys.exit(2)

rows = []
for n in names:
    path = os.path.join(d, n)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        first = str(exc).splitlines()[0] if str(exc).strip() else exc.__class__.__name__
        sys.stderr.write("%s: not parseable as YAML: %s\n" % (path, first))
        sys.exit(2)
    if not isinstance(doc, dict):
        continue

    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        on = {on: None}
    elif isinstance(on, list):
        on = dict((k, None) for k in on)
    if not isinstance(on, dict):
        continue
    if "push" not in on:
        continue
    push = on.get("push")
    if push is None:
        push = {}
    if not isinstance(push, dict):
        continue

    branches = push.get("branches")
    ignore = push.get("branches-ignore")
    tags = push.get("tags")
    if branches is None and ignore is None and tags is not None:
        # A tags-only push arm never fires on a branch push.
        continue
    if branches is not None:
        if not isinstance(branches, list) or "main" not in branches:
            continue
    if ignore is not None and isinstance(ignore, list) and "main" in ignore:
        continue

    filtered = ("paths" in push) or ("paths-ignore" in push)
    rows.append((".github/workflows/" + n, "CONDITIONAL" if filtered else "ALWAYS"))

if not rows:
    sys.stderr.write("derived an EMPTY main-push set from %s\n" % d)
    sys.exit(2)

for path, tier in rows:
    sys.stdout.write("%s\t%s\n" % (path, tier))
PY
)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    red "  tree read: $out"
    echo "UNREADABLE"
    return 0
  fi
  printf '%s\n' "$out"
}

# ── authority 2: the workflow runs on the tip ────────────────────────────────
# Prints TSV `<path> <status> <conclusion>`, one row per workflow PATH (the
# highest run id wins, so a re-run supersedes the attempt it replaced), or the
# single token FORBIDDEN / UNREADABLE. Keyed on `.path`, never on `.name`:
# renaming a workflow's `name:` would otherwise silently retire its row.
read_workflow_runs() {
  local body sha repo
  sha="$1"
  if [ -n "$RUNS_FILE" ]; then
    [ -f "$RUNS_FILE" ] || { echo "UNREADABLE"; return 0; }
    body="$(cat "$RUNS_FILE")"
  else
    repo="${REPO_OVERRIDE:-$(spec_repo)}"
    if [ -z "$repo" ]; then echo "UNREADABLE"; return 0; fi
    body="$(gh api --paginate -X GET -f head_sha="$sha" -f per_page=100 "repos/$repo/actions/runs" 2>&1)" || {
      if grep -qE 'HTTP 401|HTTP 403|Bad credentials|Resource not accessible by integration|equires authentication' <<<"$body"; then
        echo "FORBIDDEN"; return 0
      fi
      echo "UNREADABLE"; return 0
    }
  fi
  jq -e . >/dev/null 2>&1 <<<"$body" || { echo "UNREADABLE"; return 0; }
  # `gh api --paginate` on an OBJECT endpoint emits one JSON document PER PAGE,
  # so the whole stream is slurped before it groups — grouping per document
  # would let a page-1 row decide a workflow whose newest run is on page 2.
  jq -e -s 'all(.[]; .workflow_runs | type == "array")' >/dev/null 2>&1 <<<"$body" \
    || { echo "UNREADABLE"; return 0; }
  jq -r -s '
    map(.workflow_runs // [])
    | (add // [])
    | map({path: (.path // ""), status: (.status // ""),
           conclusion: (.conclusion // ""), id: (.id // 0)})
    | sort_by(.id)
    | group_by(.path)
    | map(last)
    | .[]
    | [.path, .status, .conclusion]
    | @tsv
  ' <<<"$body"
}

resolve_tip_sha() {
  local repo branch
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  branch="${BRANCH_OVERRIDE:-$(spec_branch)}"
  [ -n "$repo" ] && [ -n "$branch" ] || return 0
  gh api "repos/$repo/commits/$branch" -q '.sha' 2>/dev/null
}

# A verdict is one of these, matched as a WHOLE token. `startup_failure`
# contains `failure`; a substring test files a workflow that never compiled as
# one that answered.
is_verdict() {
  case "$1" in
    success|failure|neutral|timed_out|action_required) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --runs-file)      RUNS_FILE="${2:-}"; shift 2 ;;
      --sha)            SHA_OVERRIDE="${2:-}"; shift 2 ;;
      --repo)           REPO_OVERRIDE="${2:-}"; shift 2 ;;
      --branch)         BRANCH_OVERRIDE="${2:-}"; shift 2 ;;
      --spec)           SPEC="${2:-}"; shift 2 ;;
      --workflows-dir)  WORKFLOWS_DIR="${2:-}"; shift 2 ;;
      --manifest)       MANIFEST="${2:-}"; shift 2 ;;
      --no-manifest)    CHECK_MANIFEST=0; shift ;;
      --write-manifest) WRITE_MANIFEST=1; shift ;;
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) red "unknown argument: $1"; exit 3 ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || { red "CONFIGURATION FAULT — jq is not installed; this read cannot see anything."; return 3; }

  local expected
  expected="$(derive_expected_set "$WORKFLOWS_DIR")"
  if [ "$expected" = "UNREADABLE" ]; then
    red "CONFIGURATION FAULT — the main-push workflow set could not be derived from $WORKFLOWS_DIR."
    red "The expected set is derived from the tree on purpose; with no tree to read there is nothing"
    red "honest to say, so this run FAILS rather than reporting an empty green."
    return 3
  fi

  # ── the ratchet ────────────────────────────────────────────────────────────
  if [ "$WRITE_MANIFEST" = "1" ]; then
    {
      echo "# main-push-workflows.txt — the DERIVED transcript of every workflow whose"
      echo "# push arm reaches main, regenerated by scripts/main-verdict-presence.sh"
      echo "# --write-manifest. It is not an allowlist: it does not decide what is"
      echo "# watched, it only makes a CHANGE to what is watched show up in a diff."
      echo "#"
      echo "#   ALWAYS       unfiltered push arm — every push to main owes it a run"
      echo "#   CONDITIONAL  paths-filtered push arm — owed-ness depends on the commit"
      printf '%s\n' "$expected"
    } > "$MANIFEST"
    say "wrote $MANIFEST"
    return 0
  fi

  if [ "$CHECK_MANIFEST" = "1" ]; then
    if [ ! -f "$MANIFEST" ]; then
      red "CONFIGURATION FAULT — the ratchet transcript $MANIFEST does not exist."
      red "Run: scripts/main-verdict-presence.sh --write-manifest"
      return 3
    fi
    local committed
    committed="$(grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$')"
    if [ "$committed" != "$expected" ]; then
      red "CONFIGURATION FAULT — the main-push workflow set drifted from $MANIFEST."
      red "A workflow joined, left, or changed tier, and this read has not been told:"
      diff <(printf '%s\n' "$committed") <(printf '%s\n' "$expected") >&2 || true
      red ""
      red "Regenerate with: scripts/main-verdict-presence.sh --write-manifest"
      red "and read the diff — a workflow that quietly stops guarding main is the whole subject here."
      return 3
    fi
  fi

  local sha
  sha="${SHA_OVERRIDE:-$(resolve_tip_sha)}"
  if [ -z "$sha" ]; then
    red "CONFIGURATION FAULT — could not resolve the tip sha of ${BRANCH_OVERRIDE:-$(spec_branch)}."
    return 3
  fi

  local runs
  runs="$(read_workflow_runs "$sha")"
  case "$runs" in
    FORBIDDEN)
      red "CONFIGURATION FAULT — this run's credential cannot read the workflow runs on the tip (401/403)."
      red "REMEDY: whatever credential \$GH_TOKEN carries needs Actions: read on this repository."
      red "  A workflow permissions: block granting actions: read is enough for the DEFAULT github.token."
      red "  A fine-grained PAT supplied through a secret OVERRIDES that token and must carry the"
      red "  permission itself, or this 403s on every scheduled run while other reads look fine."
      return 3 ;;
    UNREADABLE)
      red "CONFIGURATION FAULT — the workflow runs on $sha could not be read (repos/<repo>/actions/runs)."
      red "A read that cannot see whether a workflow answered must not decide that it did."
      return 3 ;;
  esac

  say "main-verdict-presence — tip $sha"

  # ── the in-flight discriminator, read BEFORE any verdict ───────────────────
  local inflight="" run_rows=0 rpath rstatus rconcl
  while IFS="$(printf '\t')" read -r rpath rstatus rconcl; do
    [ -n "$rpath" ] || continue
    run_rows=$((run_rows + 1))
    [ "$rstatus" = "completed" ] && continue
    inflight="$inflight$rpath (status=$rstatus)
"
  done <<EOF
$runs
EOF

  if [ "$run_rows" = "0" ]; then
    say "::notice::WAITING — this sha carries NO workflow runs at all yet. An empty payload on a fresh tip"
    say "  is 'not yet', not 'never'; screaming here is how a watch trained everyone to ignore it."
    return 2
  fi

  if [ -n "$inflight" ]; then
    say "  still in flight on this tip — an absent verdict may yet appear:"
    printf '%s' "$inflight" | while IFS= read -r line; do [ -n "$line" ] && say "    $line"; done
  fi

  local screams="" declined="" not_owed=0 present=0 path tier found status conclusion
  while IFS="$(printf '\t')" read -r path tier; do
    [ -n "$path" ] || continue
    found=""
    status=""
    conclusion=""
    while IFS="$(printf '\t')" read -r rpath rstatus rconcl; do
      [ "$rpath" = "$path" ] || continue
      found=1
      status="$rstatus"
      conclusion="$rconcl"
      break
    done <<EOF
$runs
EOF

    if [ -z "$found" ]; then
      if [ "$tier" = "CONDITIONAL" ]; then
        # No run and a paths filter: indistinguishable from a filter that
        # correctly declined. Counted, never screamed. See the header.
        not_owed=$((not_owed + 1))
        continue
      fi
      if [ -n "$inflight" ]; then
        say "  WAITING  $path — no run YET, and a run on this sha is still in flight"
        continue
      fi
      say "  MISSING  $path — NO_RUN: unfiltered push arm on main, and no run on this sha at all"
      screams="$screams$path (NO_RUN)
"
      continue
    fi

    if [ "$status" != "completed" ]; then
      say "  waiting  $path — status=$status"
      continue
    fi

    if is_verdict "$conclusion"; then
      present=$((present + 1))
      say "  ok       $path — verdict=$conclusion"
      continue
    fi

    if [ "$conclusion" = "skipped" ]; then
      say "  declined $path — every job's if: was false (a different defect class; not screamed here)"
      declined="$declined$path
"
      continue
    fi

    say "  MISSING  $path — $(printf '%s' "$conclusion" | tr '[:lower:]' '[:upper:]'): the run reached a terminal state carrying NO verdict"
    screams="$screams$path ($conclusion)
"
  done <<EOF
$expected
EOF

  say "  ---"
  say "  verdicts present: $present · declined (skipped): $(printf '%s' "$declined" | grep -c . || true) · paths-filtered with no run: $not_owed"

  if [ -n "$screams" ]; then
    red ""
    red "MAIN'S TIP CARRIES NO VERDICT FROM A WORKFLOW THAT GUARDS IT — $sha"
    printf '%s' "$screams" | while IFS= read -r line; do [ -n "$line" ] && red "  $line"; done
    red ""
    red "This is ABSENCE, not redness. A cancelled or never-created run publishes no context, and an"
    red "absent context is not a red one — so nothing else in this repository can see it. Re-run the"
    red "named workflows on this sha, or land the change that lets them run to a conclusion."
    return 1
  fi

  say "ok — every owed main-push workflow published a verdict on $sha"
  return 0
}

main "$@"
