#!/usr/bin/env bash
#
# registration-sample.sh — the registration precondition, as an instrument that
# can REFUSE, instead of a paragraph a later phase re-measures by hand.
#
# WHAT DECISION THIS MAKES
# ------------------------
# Wave 9 shipped the `Console gate` and `Cloud gate` aggregator shims and
# deliberately did NOT register them as required contexts. That refusal was
# correct: registering a required context that has never rendered deadlocks main
# with a permanent "is expected" that `--admin` cannot bypass (honest-gates D18),
# and at the time zero post-shim heads qualified. But the precondition itself was
# prose. Prose is re-measured by hand, by a different reader, at a different
# hour, from a feed that lags — which is precisely the shape this epic exists to
# abolish (D115). So it becomes this script.
#
# THE BAR (wave 9's own precondition, and .github/required-checks.json's
# `_readme` sampling rule):
#
#   * at least TWO qualifying heads — `Console gate` AND `Cloud gate` both
#     RENDERED and both concluded `success`;
#   * at least ONE of those qualifying heads touches NEITHER declared path set,
#     because a shim that only renders when its own paths are touched is exactly
#     the workflow-level paths filter it replaced, wearing a job-level costume;
#   * ZERO shim defects.
#
# Below the bar this script exits NON-ZERO. That is the point: a partial
# registration is worse than none.
#
# NEVER RE-IMPLEMENT PATH LOGIC
# -----------------------------
# Classification shells out to `console-path-escape-check.sh --match console` and
# `cloud-path-escape-check.sh --match cloud`. That is the same code the two
# dispatchers call, so the sampler and the workflows cannot disagree about what
# the path sets contain. This file therefore contains no glob of its own — if
# you find yourself adding one, you are building the disagreement.
#
# The changed-path feed is `-z --no-renames --quotepath=false` hardened. The
# sampler inherits the dispatcher's false-green otherwise, and here the
# consequence is WORSE: a head touching a non-ASCII path would be quoted, miss
# both sets, and score NEITHER — the exact shape the bar counts as PROOF.
#
# ABSENCE HAS FOUR CAUSES, AND CONFLATING THEM IS THE WHOLE POINT
# ---------------------------------------------------------------
#   NO-RUN       no workflow run at that head at all — a workflow-level paths
#                filter, or the workflow did not exist yet. Nothing to rescue:
#                re-running a workflow that did not exist at that sha produces
#                nothing.
#   CADENCE      a run EXISTS and concluded `cancelled` (or `skipped`). A run
#                evicted while still pending emits NO check run, so `if: always()`
#                on the aggregator cannot rescue it. Not a defect — a cadence
#                artefact of concurrency groups.
#   SHIM-DEFECT  the run CONCLUDED (success/failure) and the named check is
#                STILL absent. This is the only cause that is a bug, it carries
#                its own counter, and it forces a non-zero exit EVEN WHEN the
#                count bar is satisfied.
#   IN-FLIGHT    the run is not `completed` yet. The head is UNSETTLED and leaves
#                the numerator AND the denominator. Measured: at 22:50 local,
#                21ab0e50d read `Console gate`=success / `Cloud gate` ABSENT
#                although its cloud run had completed at 20:51:13Z — the commits
#                check-run feed lags behind the runs feed by minutes. Counting
#                that head as a non-qualifier would silently REFUSE a legal
#                registration.
#
# A head is UNSETTLED whenever ANY workflow run at it is not yet completed, not
# only the two this script reads. While the feed is still churning, absence is
# not yet evidence of anything. This can only SHRINK the sample; it can never
# manufacture a qualifier, and `--since` means the window only grows.
#
# TWO MEASURED TRAPS
# ------------------
# (1) `actions/runs?head_sha=` matches only the FULL oid. An abbreviated sha
#     returns zero runs and mis-reports CADENCE (and SHIM-DEFECT) as NO-RUN, so
#     every ref is normalised through `git rev-parse "$ref^{commit}"` first.
# (2) An EMPTY diff makes `--match` answer `false` with exit 0. A revert pair or
#     a merge commit would then score NEITHER and could INFLATE the
#     neither-shape count — the one number the bar most depends on. Empty-diff
#     heads are excluded exactly like IN-FLIGHT ones, and the summary says so.
#
# USAGE
#   scripts/registration-sample.sh                        # last --limit heads of origin/main
#   scripts/registration-sample.sh --since <sha>          # every head AFTER <sha> (preferred)
#   scripts/registration-sample.sh --limit 12
#   scripts/registration-sample.sh --ref origin/main
#   scripts/registration-sample.sh --repo OWNER/NAME
#   scripts/registration-sample.sh --fixture-dir DIR      # offline, for the harness
#   scripts/registration-sample.sh --selftest
#   scripts/registration-sample.sh <sha> [<sha>…]         # sample exactly these heads
#                                                         # (abbreviated shas are fine)
#
# EXIT   0 = the bar is cleared, registration is legal
#        1 = below the bar (or a shim defect) — do NOT register
#        2 = the instrument could not measure (unreadable feed, bad usage)
#
# FIXTURE DIRECTORY LAYOUT (--fixture-dir)
#   heads.txt              one sha per line, newest first
#   changed-<sha>.txt      the head's changed paths, one per line (may be empty)
#   checkruns-<sha>.json   the /commits/<sha>/check-runs payload
#   runs-<sha>.json        the /actions/runs?head_sha=<sha> payload

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/check-runs.sh
. "$REPO_ROOT/scripts/lib/check-runs.sh"

# ── the two aggregators under test, and the workflow that must publish each ──
# The pairing is what turns "the name is missing" into a diagnosable cause: the
# check-run name lives in the commits feed, the run that owed it lives in the
# runs feed, and only the two together separate a defect from a cadence artefact.
CONSOLE_CHECK='Console gate'
CONSOLE_WORKFLOW='.github/workflows/console-harness.yml'
CLOUD_CHECK='Cloud gate'
CLOUD_WORKFLOW='.github/workflows/cloud.yml'

# THE BAR
MIN_QUALIFYING=2
MIN_NEITHER=1

REF='origin/main'
SINCE=''
LIMIT=10
FIXTURE_DIR=''
REPO=''

die() { echo "registration-sample: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --since)       SINCE="${2:?--since needs a sha}"; shift 2 ;;
    --limit)       LIMIT="${2:?--limit needs a count}"; shift 2 ;;
    --ref)         REF="${2:?--ref needs a ref}"; shift 2 ;;
    --repo)        REPO="${2:?--repo needs OWNER/NAME}"; shift 2 ;;
    --fixture-dir) FIXTURE_DIR="${2:?--fixture-dir needs a path}"; shift 2 ;;
    --selftest)    exec bash "$REPO_ROOT/scripts/registration-sample.test.sh" ;;
    -h|--help)
      sed -n '/^# USAGE/,/^#        2 = /p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --) shift; break ;;
    -*) die "unknown argument '$1' (try --help)" ;;
    # Anything else is an EXPLICIT head to sample. This is the mode that makes
    # trap 1 reachable by hand: `registration-sample.sh dc17c949e` must produce
    # the same rows as the full oid, and it only does because every ref is
    # normalised through `git rev-parse "$ref^{commit}"` before the runs query.
    *) break ;;
  esac
done
EXPLICIT_HEADS="$*"

case "$LIMIT" in
  ''|*[!0-9]*) die "--limit must be a positive integer, got '$LIMIT'" ;;
esac
[ "$LIMIT" -gt 0 ] || die "--limit must be a positive integer, got '$LIMIT'"

if [ -z "$REPO" ]; then
  REPO="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null || true)"
  REPO="${REPO%.git}"
  REPO="${REPO##*github.com/}"
  REPO="${REPO##*github.com:}"
  [ -n "$REPO" ] || REPO='FRIKKern/barkpark'
fi

# ── head enumeration ─────────────────────────────────────────────────────────
heads=''
if [ -n "$EXPLICIT_HEADS" ]; then
  heads="$(tr ' ' '\n' <<<"$EXPLICIT_HEADS")"
elif [ -n "$FIXTURE_DIR" ]; then
  [ -f "$FIXTURE_DIR/heads.txt" ] || die "no heads.txt in $FIXTURE_DIR"
  heads="$(grep -v '^[[:space:]]*$' "$FIXTURE_DIR/heads.txt" || true)"
elif [ -n "$SINCE" ]; then
  git -C "$REPO_ROOT" rev-parse --verify --quiet "$SINCE^{commit}" >/dev/null \
    || die "--since '$SINCE' is not a commit in this checkout"
  heads="$(git -C "$REPO_ROOT" log --format=%H --max-count="$LIMIT" "$SINCE..$REF" || true)"
else
  heads="$(git -C "$REPO_ROOT" log --format=%H --max-count="$LIMIT" "$REF" || true)"
fi
[ -n "$heads" ] || die "no heads to sample (ref=$REF since=${SINCE:-<none>})"

# ── the changed-path feed ────────────────────────────────────────────────────
# -z + --no-renames + core.quotepath=false: three separate false-greens, all of
# which land on the same side here (paths mangled -> matches nothing -> NEITHER,
# which the bar reads as PROOF). --no-renames so a rename reports BOTH sides;
# a rename out of a declared set is a change to that set.
changed_paths() {
  local sha="$1"
  if [ -n "$FIXTURE_DIR" ]; then
    if [ -f "$FIXTURE_DIR/changed-$sha.txt" ]; then
      cat "$FIXTURE_DIR/changed-$sha.txt"
    fi
    return 0
  fi
  git -C "$REPO_ROOT" -c core.quotepath=false show --pretty= -z --name-only --no-renames "$sha" \
    | tr '\0' '\n'
}

# ── run existence, latest run per workflow path ──────────────────────────────
# `path<TAB>status<TAB>conclusion`. A re-run leaves two rows for one workflow;
# the newest wins, because the newest is what the check-run feed reflects.
runs_rows() {
  local sha="$1" json
  if [ -n "$FIXTURE_DIR" ]; then
    [ -f "$FIXTURE_DIR/runs-$sha.json" ] || { echo "registration-sample: no fixture runs-$sha.json in $FIXTURE_DIR" >&2; return 2; }
    json="$(cat "$FIXTURE_DIR/runs-$sha.json")"
  else
    json="$(gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" 2>/dev/null)" || {
      echo "registration-sample: cannot read workflow runs for $sha (unreadable feed is a failure, not an empty set)" >&2
      return 2
    }
  fi
  jq -e 'has("workflow_runs") and (.workflow_runs | type == "array")' >/dev/null 2>&1 <<<"$json" || {
    echo "registration-sample: malformed workflow-runs payload for $sha" >&2
    return 2
  }
  jq -r '
      .workflow_runs | sort_by(.run_started_at // .created_at // "") | .[]
      | [ .path, (.status // "null"), (.conclusion // "null") ] | @tsv' <<<"$json" \
    | awk -F'\t' '{ seen[$1] = $0 } END { for (p in seen) print seen[p] }' \
    | LC_ALL=C sort
}

run_field() { # <rows> <path> <field-index 2=status 3=conclusion>
  local rows="$1" path="$2" idx="$3"
  awk -F'\t' -v want="$path" -v i="$idx" '$1 == want { print $i; exit }' <<<"$rows"
}

# Any run at this head still moving? Then the commits feed is still churning and
# absence proves nothing yet.
any_run_pending() {
  local rows="$1"
  awk -F'\t' '$2 != "completed" { pending = 1 } END { exit(pending ? 0 : 1) }' <<<"$rows"
}

# ── the four-cause absence classifier ────────────────────────────────────────
# Returns the aggregator's state for one head: a conclusion when the check
# RENDERED, otherwise `ABSENT:<cause>`.
aggregator_state() {
  local check_rows="$1" run_rows="$2" check_name="$3" workflow_path="$4"
  local conclusion run_status run_conclusion

  conclusion="$(check_runs_conclusion "$check_rows" "$check_name")"
  if [ -n "$conclusion" ]; then
    printf '%s' "$conclusion"
    return 0
  fi

  run_status="$(run_field "$run_rows" "$workflow_path" 2)"
  if [ -z "$run_status" ]; then
    printf 'ABSENT:NO-RUN'
    return 0
  fi
  if [ "$run_status" != "completed" ]; then
    printf 'ABSENT:IN-FLIGHT'
    return 0
  fi
  run_conclusion="$(run_field "$run_rows" "$workflow_path" 3)"
  case "$run_conclusion" in
    cancelled|skipped|null|'') printf 'ABSENT:CADENCE' ;;
    *)                         printf 'ABSENT:SHIM-DEFECT' ;;
  esac
}

# ── the walk ─────────────────────────────────────────────────────────────────
n_heads=0
n_qualifying=0
n_qualifying_neither=0
n_unsettled=0
n_empty_diff=0
n_shim_defects=0
shim_defect_detail=''

echo "registration-sample: repo=$REPO ref=${FIXTURE_DIR:+<fixtures>}${FIXTURE_DIR:-$REF}${SINCE:+ since=$SINCE}"
echo "required: >= $MIN_QUALIFYING qualifying heads, >= $MIN_NEITHER of them NEITHER-shape, 0 shim defects"
echo
printf '%-12s  %-8s  %-20s  %-20s  %s\n' 'HEAD' 'SHAPE' "$CONSOLE_CHECK" "$CLOUD_CHECK" 'VERDICT'
printf '%-12s  %-8s  %-20s  %-20s  %s\n' '------------' '--------' '--------------------' '--------------------' '-------'

while IFS= read -r head; do
  [ -n "$head" ] || continue
  n_heads=$((n_heads + 1))

  if [ -n "$FIXTURE_DIR" ]; then
    full="$head"
  else
    # TRAP 1: actions/runs?head_sha= matches the FULL oid only.
    full="$(git -C "$REPO_ROOT" rev-parse --verify --quiet "$head^{commit}" || true)"
    [ -n "$full" ] || die "'$head' is not a commit in this checkout"
  fi
  short="${full:0:9}"

  paths="$(changed_paths "$full")"

  # TRAP 2: an empty diff makes --match answer `false`, which would score the
  # head NEITHER and inflate the one count the bar leans on hardest.
  if [ -z "$(tr -d '[:space:]' <<<"$paths")" ]; then
    n_empty_diff=$((n_empty_diff + 1))
    printf '%-12s  %-8s  %-20s  %-20s  %s\n' "$short" '-' '-' '-' 'EXCLUDED (empty diff — cannot be scored NEITHER)'
    continue
  fi

  # HERE-STRING, never `printf … | script` (honest-gates D37): `--match` ends in
  # `grep -Eq`, which exits the instant it matches; a writer process on the other
  # end of that pipe takes SIGPIPE, pipefail promotes 141 over the match, and a
  # head that DID touch a set reads as an error. A here-string has no writer.
  console_touch="$(bash "$REPO_ROOT/scripts/console-path-escape-check.sh" --match console <<<"$paths")"
  cloud_touch="$(bash "$REPO_ROOT/scripts/cloud-path-escape-check.sh" --match cloud <<<"$paths")"
  case "$console_touch:$cloud_touch" in
    true:true)   shape='BOTH' ;;
    true:false)  shape='CONSOLE' ;;
    false:true)  shape='CLOUD' ;;
    false:false) shape='NEITHER' ;;
    *) die "$short: uninterpretable path verdict console='$console_touch' cloud='$cloud_touch'" ;;
  esac

  check_rows="$(check_runs_rows "$REPO" "$full" "$FIXTURE_DIR")" || exit 2
  run_rows="$(runs_rows "$full")" || exit 2

  console_state="$(aggregator_state "$check_rows" "$run_rows" "$CONSOLE_CHECK" "$CONSOLE_WORKFLOW")"
  cloud_state="$(aggregator_state "$check_rows" "$run_rows" "$CLOUD_CHECK" "$CLOUD_WORKFLOW")"

  # UNSETTLED, for either reason: a named run still moving, or ANY run at the
  # head still moving (the commits feed lags the runs feed by minutes).
  unsettled=0
  case "$console_state:$cloud_state" in *IN-FLIGHT*) unsettled=1 ;; esac
  if [ -n "$run_rows" ] && any_run_pending "$run_rows"; then
    unsettled=1
  fi

  if [ "$unsettled" -eq 1 ]; then
    n_unsettled=$((n_unsettled + 1))
    printf '%-12s  %-8s  %-20s  %-20s  %s\n' "$short" "$shape" "$console_state" "$cloud_state" \
      'UNSETTLED (runs still moving — out of numerator AND denominator)'
    continue
  fi

  # A settled head is the only place a missing name can be called a defect.
  for pair in "$CONSOLE_CHECK=$console_state" "$CLOUD_CHECK=$cloud_state"; do
    case "$pair" in
      *=ABSENT:SHIM-DEFECT)
        n_shim_defects=$((n_shim_defects + 1))
        shim_defect_detail="$shim_defect_detail
  $short  ${pair%%=*} never rendered although its workflow run CONCLUDED — the shim did not publish its aggregator"
        ;;
    esac
  done

  if [ "$console_state" = 'success' ] && [ "$cloud_state" = 'success' ]; then
    n_qualifying=$((n_qualifying + 1))
    verdict='QUALIFIES'
    if [ "$shape" = 'NEITHER' ]; then
      n_qualifying_neither=$((n_qualifying_neither + 1))
      verdict='QUALIFIES (neither-shape)'
    fi
  else
    verdict='no'
  fi

  printf '%-12s  %-8s  %-20s  %-20s  %s\n' "$short" "$shape" "$console_state" "$cloud_state" "$verdict"
done <<EOF
$heads
EOF

# ── the ruling ───────────────────────────────────────────────────────────────
echo
echo "heads walked          $n_heads"
echo "qualifying            $n_qualifying   (need >= $MIN_QUALIFYING)"
echo "  of which NEITHER    $n_qualifying_neither   (need >= $MIN_NEITHER)"
echo "unsettled (excluded)  $n_unsettled"
echo "empty-diff (excluded) $n_empty_diff"
echo "shim defects          $n_shim_defects   (need 0)"
echo

failures=0

if [ "$n_shim_defects" -gt 0 ]; then
  echo "REFUSE: $n_shim_defects shim defect(s) — a concluded run that published no aggregator.$shim_defect_detail" >&2
  echo "        This is the one absence cause that is a BUG, and it refuses registration even though" >&2
  echo "        the count bar reads $n_qualifying/$MIN_QUALIFYING. Fix the shim before requiring its name." >&2
  failures=$((failures + 1))
fi

if [ "$n_qualifying" -lt "$MIN_QUALIFYING" ]; then
  echo "REFUSE: only $n_qualifying qualifying head(s), need $MIN_QUALIFYING. Registering a context that has not" >&2
  echo "        demonstrably rendered deadlocks main with a permanent 'is expected' that --admin cannot bypass." >&2
  failures=$((failures + 1))
fi

if [ "$n_qualifying_neither" -lt "$MIN_NEITHER" ]; then
  echo "REFUSE: $n_qualifying_neither qualifying head(s) touch NEITHER path set, need $MIN_NEITHER. Without one, the" >&2
  echo "        sample only proves the aggregator renders when its OWN paths are touched — which is the" >&2
  echo "        workflow-level paths filter the shim was built to replace, wearing a job-level costume." >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo >&2
  echo "VERDICT: do NOT register '$CONSOLE_CHECK' / '$CLOUD_CHECK'. A partial registration is worse than none." >&2
  exit 1
fi

echo "VERDICT: the bar is cleared — registering '$CONSOLE_CHECK' and '$CLOUD_CHECK' is legal on this sample."
exit 0
