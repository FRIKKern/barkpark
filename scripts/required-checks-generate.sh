#!/usr/bin/env bash
# required-checks-generate.sh — GENERATE the branch-protection spec from check
# runs that were actually observed, because a required context is the one string
# in this repo that GitHub will accept without validating and then deadlock main
# with forever (honest-gates D20, D21, D42).
#
# WHY THIS IS NOT A HAND-TYPED LIST
#
# `PUT …/branches/main/protection` with `Test (Elixir 1.18.1 / OTP 27.O)` — a
# capital O for the zero — returns 200 and reads the typo back verbatim. Nothing
# ever publishes that name, so the PR sits "expected" forever and the repo is
# bricked until someone with admin notices. So every context in the spec must be
# a byte-for-byte copy of a name GitHub was OBSERVED to publish.
#
# TWO STAGES, AND THEY ARE DIFFERENT JOBS
#
#   1. THE POISON FILTER (R0–R4). Throws out names that can never report, or
#      that come from the wrong namespace. Measured on real heads: this filter
#      alone accepts 15 of 16 names, including `Format (… advisory) (27.0,
#      1.18.1)`, which is RED ON MAIN. A filter is not a policy (D42).
#   2. THE SELECTION (S1–S5). Decides which of the surviving names may carry
#      branch protection: present on every sampled path shape, not advisory by
#      intent, not paths-filtered (an ABSENT check is a permanent "expected"),
#      not already subsumed by an aggregator, and not red on main.
#
# THE FIVE REJECTIONS, each measured:
#
#   R0 SOURCE   The candidate must come from `/commits/<sha>/check-runs`.
#               `/commits/<sha>/status` shares the required-context namespace and
#               returns exactly `Vercel – barkpark` + `Vercel – demo`, `failure`
#               on every sha ever sampled. R0 is the only rule that catches a
#               LEGITIMATE name arriving through the poisoned feed.
#   R1 TEMPLATE Any name containing `${{`. A job that never STARTED publishes
#               its uninterpolated template: `Prod compile gate (Elixir
#               ${{ matrix.elixir }} / OTP ${{ matrix.otp }})` is live on real
#               heads right now.
#   R2 SAMPLE   conclusion `skipped`, `cancelled`, or absent. The same job
#               publishes a usable name when it runs and a template name when it
#               skips, so the cheapest PR to sample (a docs-only one) is the
#               most poisoned.
#   R3 LEGACY   The legacy commit-status namespace, denied by NORMALIZED bytes.
#               The separator in `Vercel – barkpark` is EN DASH U+2013, not a
#               hyphen; a transcription error mis-keys silently in BOTH
#               directions, so the denylist is written in ASCII and normalized.
#   R4 APP      app.id != 15368 (GitHub Actions). Vercel's app 8329 publishes
#               `Vercel Preview Comments` into the same check-run feed.
#
# The rules are individually disarmable through RC_DISABLE_RULES — that seam
# exists so scripts/required-checks.test.sh can prove each rule fires ALONE
# (disarm it, watch the specimen turn ACCEPTED). Never set it in anger.
#
# THE MATRIX SUFFIX IS READ FROM THE WORKFLOW SOURCE, NEVER FROM THE NAME.
# Six legitimate names carry literal parentheses (`Boundary gate (advisory)`),
# so stripping a trailing parenthetical mangles them. This script matches a
# rendered name against each job's `name:` TEMPLATE and only tolerates a
# trailing `(…)` when the source says that job is matrixed AND its name
# interpolates no matrix value — which is exactly when GitHub appends the tuple.
#
# USAGE
#   scripts/required-checks-generate.sh --sha <sha> --sha <sha> [--out FILE]
#   scripts/required-checks-generate.sh --sha <sha> --explain      # the ledger
#
# The spec is regenerated immediately before any protection flip; it has a shelf
# life of about one merged workflow change.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

REPO="${RC_REPO:-FRIKKern/barkpark}"
BRANCH="${RC_BRANCH:-main}"
ACTIONS_APP_ID=15368
WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
FIXTURE_DIR=""
OUT=""
EXPLAIN=0
SOURCE_FEED="check_runs"
ALLOW_SINGLE_SHA=0
MAIN_WINDOW=10
MAIN_SHAS=""
SHAS=()

# Advisory BY INTENT: names that run green, are not paths-filtered, and are not
# subsumed — but must still never gate a merge. Each needs one line of why.
ADVISORY_BY_INTENT_NAMES=(
  "PR task gate self-test"
)
ADVISORY_BY_INTENT_REASONS=(
  "the task gate's own harness — it proves the gate CAN fail; requiring it makes the tripwire's tripwire load-bearing"
)

die() { echo "FAIL: $*" >&2; exit 1; }
note() { [ "$EXPLAIN" -eq 1 ] && echo "$*" >&2 || true; }

rule_enabled() {
  case ",${RC_DISABLE_RULES:-}," in
    *",$1,"*) return 1 ;;
    *) return 0 ;;
  esac
}

# ── normalization (R3) ───────────────────────────────────────────────────────
# Unicode dashes and NBSP collapse to their ASCII shapes, then case-fold. The
# denylist below is written in ASCII on purpose: if normalization is ever
# disarmed the real EN DASH name stops matching, which is what makes RC_NORMALIZE
# a mutation proof rather than a decoration.
LEGACY_DENYLIST=(
  "Vercel - barkpark"
  "Vercel - demo"
)

normalize_ctx() {
  if [ "${RC_NORMALIZE:-1}" = "0" ]; then
    printf '%s' "$1"
    return
  fi
  printf '%s' "$1" \
    | sed $'s/\xe2\x80\x93/-/g; s/\xe2\x80\x94/-/g; s/\xe2\x88\x92/-/g; s/\xc2\xa0/ /g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/  */ /g; s/^ *//; s/ *$//'
}

# The codepoints that normalization had to move, printed on an R3 hit so a
# hyphen/en-dash transcription error is visible instead of silent.
odd_codepoints() {
  printf '%s' "$1" | LC_ALL=C grep -o $'\xe2\x80\x93\|\xe2\x80\x94\|\xe2\x88\x92\|\xc2\xa0' \
    | sort -u | while IFS= read -r ch; do
        case "$ch" in
          $'\xe2\x80\x93') printf 'U+2013 EN DASH ' ;;
          $'\xe2\x80\x94') printf 'U+2014 EM DASH ' ;;
          $'\xe2\x88\x92') printf 'U+2212 MINUS ' ;;
          $'\xc2\xa0')     printf 'U+00A0 NBSP ' ;;
        esac
      done
}

is_legacy_context() {
  local norm entry
  norm="$(normalize_ctx "$1")"
  for entry in "${LEGACY_DENYLIST[@]}"; do
    [ "$norm" = "$(normalize_ctx "$entry")" ] && return 0
  done
  return 1
}

# ── the poison filter ────────────────────────────────────────────────────────
# Returns ACCEPT or the id of the FIRST rule that rejected. Order is fixed so
# the ledger is reproducible; the test suite isolates each rule by disarming its
# co-catchers, so ordering never hides a decorative rule.
classify_row() {
  local name="$1" conclusion="$2" app_id="$3" source="$4"

  if rule_enabled R0 && [ "$source" != "check_runs" ]; then
    echo "R0"; return
  fi
  if rule_enabled R1 && case "$name" in *'${{'*) true ;; *) false ;; esac; then
    echo "R1"; return
  fi
  if rule_enabled R2; then
    case "$conclusion" in
      skipped|cancelled|null|"") echo "R2"; return ;;
    esac
  fi
  if rule_enabled R3 && is_legacy_context "$name"; then
    echo "R3"; return
  fi
  if rule_enabled R4 && [ "$app_id" != "$ACTIONS_APP_ID" ]; then
    echo "R4"; return
  fi
  echo "ACCEPT"
}

# ── feeds ────────────────────────────────────────────────────────────────────
# Every fetch is fail-closed: an unreadable feed is a hard error, never an empty
# candidate set that would generate a cheerfully empty spec.
fetch_check_runs() {
  local sha="$1" json
  if [ -n "$FIXTURE_DIR" ]; then
    [ -f "$FIXTURE_DIR/checkruns-$sha.json" ] || die "no fixture checkruns-$sha.json in $FIXTURE_DIR"
    json="$(cat "$FIXTURE_DIR/checkruns-$sha.json")"
  else
    json="$(gh api "repos/$REPO/commits/$sha/check-runs?per_page=100" 2>/dev/null)" \
      || die "cannot read check-runs for $sha (unreadable feed is a failure, not an empty set)"
  fi
  [ "$(printf '%s' "$json" | jq -r '.check_runs | length')" -gt 0 ] \
    || die "check-runs for $sha is EMPTY — refusing to generate a spec from nothing"
  # latest row per name wins (a re-run leaves both); sorted ascending, awk keeps last.
  printf '%s' "$json" | jq -r '
      .check_runs | sort_by(.started_at // "") | .[]
      | [ .name, (.conclusion // "null"), ((.app.id // 0)|tostring) ] | @tsv' \
    | awk -F'\t' '{ seen[$1] = $0 } END { for (n in seen) print seen[n] }' \
    | sort
}

fetch_status_contexts() {
  local sha="$1" json
  if [ -n "$FIXTURE_DIR" ]; then
    [ -f "$FIXTURE_DIR/status-$sha.json" ] || die "no fixture status-$sha.json in $FIXTURE_DIR"
    json="$(cat "$FIXTURE_DIR/status-$sha.json")"
  else
    json="$(gh api "repos/$REPO/commits/$sha/status" 2>/dev/null)" \
      || die "cannot read /status for $sha"
  fi
  printf '%s' "$json" | jq -r '.statuses[] | [ .context, (.state // "null"), "0" ] | @tsv' | sort
}

# ── the workflow-source index ────────────────────────────────────────────────
# One row per job: file, job id, the `name:` TEMPLATE verbatim, whether the job
# is matrixed, whether it is continue-on-error, whether its workflow is
# paths-filtered on pull_request, and its `needs`. Everything the selection
# stage decides is derived from THIS, not from the shape of a rendered string.
build_workflow_index() {
  local f
  for f in "$WORKFLOW_DIR"/*.yml; do
    [ -f "$f" ] || continue
    awk -v file="$(basename "$f")" '
      function flush() {
        if (job != "") {
          printf "%s\t%s\t%s\t%d\t%d\t%d\t%s\n", file, job,
                 (jname == "" ? job : jname), matrixed, coe, pf, needs
        }
        job = ""; jname = ""; matrixed = 0; coe = 0; needs = ""
      }
      BEGIN { inon = 0; inpr = 0; injobs = 0; pf = 0; instrategy = 0; inneeds = 0 }

      # ---- workflow-level triggers: is pull_request paths-filtered? ----
      /^on:/            { inon = 1; next }
      inon && /^[a-z]/  { inon = 0; inpr = 0 }
      inon && /^  pull_request:/ { inpr = 1; next }
      inon && /^  [a-z_]+:/      { inpr = 0 }
      inon && inpr && /^    paths(-ignore)?:/ { pf = 1; next }

      # ---- jobs ----
      /^jobs:/ { flush(); injobs = 1; next }
      injobs && /^[a-z]/ { flush(); injobs = 0 }

      injobs && /^  [A-Za-z0-9_.-]+:/ {
        flush()
        job = $0
        sub(/^  /, "", job); sub(/:.*$/, "", job)
        next
      }

      injobs && job != "" {
        # strategy block: a `matrix:` inside it means GitHub may append a tuple
        if ($0 ~ /^    strategy:/) { instrategy = 1; next }
        if (instrategy && $0 ~ /^    [a-z]/) { instrategy = 0 }
        if (instrategy && $0 ~ /^      matrix:/) { matrixed = 1; next }

        if ($0 ~ /^    name:/) {
          v = $0; sub(/^    name: */, "", v)
          gsub(/^["'\'']|["'\'']$/, "", v)
          sub(/[ \t]+$/, "", v)
          jname = v; next
        }
        if ($0 ~ /^    continue-on-error: *true/) { coe = 1; next }
        if ($0 ~ /^    needs: *\[/) {
          v = $0; sub(/^    needs: *\[/, "", v); sub(/\].*$/, "", v)
          gsub(/ /, "", v); needs = v; inneeds = 0; next
        }
        if ($0 ~ /^    needs: *$/) { inneeds = 1; next }
        if (inneeds && $0 ~ /^      - /) {
          v = $0; sub(/^      - */, "", v); gsub(/[ \t]+$/, "", v)
          needs = (needs == "" ? v : needs "," v); next
        }
        if (inneeds && $0 !~ /^      /) { inneeds = 0 }
      }
      END { flush() }
    ' "$f"
  done
}

# A job `name:` template turned into an anchored ERE. Metacharacters are escaped
# AFTER the `${{ … }}` holes are punched out, so literal parens in a name stay
# literal and only real interpolations become wildcards.
tmpl_to_regex() {
  local t="$1"
  t="$(printf '%s' "$t" | sed -E 's/\$\{\{[^}]*\}\}/@@MX@@/g')"
  t="$(printf '%s' "$t" | sed -E 's/[][\.^$*+?(){}|\\]/\\&/g')"
  t="$(printf '%s' "$t" | sed 's/@@MX@@/.+/g')"
  printf '%s' "$t"
}

# A name template that matches an ARBITRARY string is a CATCH-ALL, and a
# catch-all is not a match — it is a takeover. `.github/workflows/cp-ops.yml`
# declared `jobs.run.name: ${{ inputs.operation }}`, which tmpl_to_regex turns
# into `^.+$`; job_for_name returns the FIRST match in a directory read in
# `sort` order, so cp-ops.yml claimed every name from doc-gates.yml, elixir.yml,
# pr-task-gate.yml and reland-check.yml and handed each one ITS OWN provenance:
# coe=0, pf=0, needs="". Those are exactly the three fields S2/S3/S4 exclude on,
# so the run emitted SIX contexts at exit 0 — promoting a paths-filtered name
# whose absence would have deadlocked main with a permanent "is expected."
#
# The refusal is deliberately at INDEX-BUILD time, not at match time: a
# catch-all is a defect in the workflow source, so whether it happens to win a
# race against some sampled name must not decide whether the run is trusted.
# The probe carries no space and no parenthesis so that legitimately partial
# templates (`Test (${{ matrix.otp }})`, `${{ matrix.pkg }} lint`) are NOT
# flagged — only a template that matches literally anything is.
CATCHALL_PROBE='rc-catchall-probe-9f2c1dz'

assert_no_catchall_job_names() {
  local idx="$1" file job tmpl re
  while IFS=$'\t' read -r file job tmpl _matrixed _coe _pf _needs; do
    [ -n "$job" ] || continue
    re="$(tmpl_to_regex "$tmpl")"
    if grep -qE "^${re}$" <<<"$CATCHALL_PROBE"; then
      die "CATCH-ALL JOB NAME: $file job '$job' declares \`name: $tmpl\`, whose match regex is ^${re}\$ — it matches EVERY rendered check-run name and would misattribute other workflows' checks to this job (erasing continue-on-error / paths-filter / needs). Give the job a STATIC name and move the interpolation into a STEP name."
    fi
  done <<EOF
$idx
EOF
}

# rendered check-run name -> "file<TAB>job<TAB>coe<TAB>pf<TAB>needs", or empty.
#
# Every grep here is fed by a HERE-STRING, never by a pipe. Under `set -o
# pipefail` a `grep -q` that matches exits immediately, the upstream `printf`
# takes SIGPIPE, and the pipeline reports 141 — so a successful match reads as a
# failure, intermittently. That is a coin-flip bug in a name matcher whose whole
# job is to be exact.
job_for_name() {
  local target="$1" idx="$2"
  local file job tmpl matrixed coe pf needs re
  while IFS=$'\t' read -r file job tmpl matrixed coe pf needs; do
    [ -n "$job" ] || continue
    re="$(tmpl_to_regex "$tmpl")"
    if grep -qE "^${re}$" <<<"$target"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$job" "$coe" "$pf" "$needs"; return 0
    fi
    # The matrix suffix, taken from the SOURCE: only a matrixed job whose name
    # interpolates nothing can gain a trailing `(tuple)`.
    if [ "$matrixed" = "1" ] && ! grep -q '\${{' <<<"$tmpl"; then
      if grep -qE "^${re} \(.+\)$" <<<"$target"; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$job" "$coe" "$pf" "$needs"; return 0
      fi
    fi
  done <<EOF
$idx
EOF
  return 1
}

# Every job the given job transitively `needs`, as file<TAB>jobid — those are
# SUBSUMED once the aggregator itself is required.
#
# JOB IDENTITY, not name: the rendered name of a matrixed upstream carries a
# suffix its `name:` template does not, so comparing strings here silently keeps
# `Test (Elixir 1.18.1 / OTP 27.0)` in the required set while dropping its
# unsuffixed siblings.
subsumed_jobs() {
  local file="$1" needs="$2" idx="$3"
  local queue="$needs" seen="" cur rest jf jj jneeds
  while [ -n "$queue" ]; do
    cur="${queue%%,*}"
    rest="${queue#*,}"
    [ "$rest" = "$queue" ] && rest=""
    queue="$rest"
    [ -n "$cur" ] || continue
    case ",$seen," in *",$cur,"*) continue ;; esac
    seen="$seen,$cur"
    while IFS=$'\t' read -r jf jj _t _m _c _p jneeds; do
      [ "$jf" = "$file" ] && [ "$jj" = "$cur" ] || continue
      printf '%s\t%s\n' "$jf" "$jj"
      [ -n "$jneeds" ] && queue="${queue:+$queue,}$jneeds"
    done <<EOF
$idx
EOF
  done
}

# ── main-branch health ───────────────────────────────────────────────────────
# A name whose latest COMPLETED run on main is a failure can never be required:
# it would red every PR from the moment protection lands. A name that never
# appears on main (a pull_request-only check) is NOT disqualified — absence here
# is expected, and the paths-filter stage is what catches genuine absence.
main_conclusions() {
  local shas
  if [ -n "$MAIN_SHAS" ]; then
    shas="$(printf '%s\n' "$MAIN_SHAS" | tr ',' '\n')"
  elif [ -n "$FIXTURE_DIR" ]; then
    [ -f "$FIXTURE_DIR/main-shas.txt" ] || die "fixture dir needs main-shas.txt"
    shas="$(cat "$FIXTURE_DIR/main-shas.txt")"
  else
    shas="$(gh api "repos/$REPO/commits?sha=$BRANCH&per_page=$MAIN_WINDOW" --jq '.[].sha' 2>/dev/null)" \
      || die "cannot read recent $BRANCH commits"
  fi
  [ -n "$shas" ] || die "no $BRANCH commits to read main-health from"
  local sha
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # Sub-shelled on purpose: a main commit with no check runs at all (a very
    # old one, or one still queueing) makes fetch_check_runs `die`, and `exit`
    # inside a function is NOT caught by `|| true` unless it is fenced here.
    ( fetch_check_runs "$sha" ) 2>/dev/null || true
  done <<EOF
$shas
EOF
  true
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha) SHAS+=("$2"); shift 2 ;;
      --main-sha) MAIN_SHAS="${MAIN_SHAS:+$MAIN_SHAS,}$2"; shift 2 ;;
      --main-window) MAIN_WINDOW="$2"; shift 2 ;;
      --repo) REPO="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --workflows) WORKFLOW_DIR="$2"; shift 2 ;;
      --fixture-dir) FIXTURE_DIR="$2"; shift 2 ;;
      --out) OUT="$2"; shift 2 ;;
      --explain) EXPLAIN=1; shift ;;
      --status-source) SOURCE_FEED="status"; shift ;;
      --allow-single-sha) ALLOW_SINGLE_SHA=1; shift ;;
      -h|--help) usage 0 ;;
      *) die "unknown argument: $1 (try --help)" ;;
    esac
  done

  [ "${#SHAS[@]}" -gt 0 ] || die "at least one --sha is required"
  if [ "${#SHAS[@]}" -lt 2 ] && [ "$ALLOW_SINGLE_SHA" -eq 0 ]; then
    die "at least TWO --sha are required (different path shapes) — a single-sha sample cannot tell a universal check from a paths-filtered one; pass --allow-single-sha only in tests"
  fi

  local idx
  idx="$(build_workflow_index)"
  [ -n "$idx" ] || die "the workflow index is empty — the parser is broken, not the repo"
  assert_no_catchall_job_names "$idx"

  # ── stage 1: the poison filter, per sha ──
  local sha rows accepted_all="" first=1 intersection=""
  local ledger=""
  for sha in "${SHAS[@]}"; do
    if [ "$SOURCE_FEED" = "status" ]; then
      rows="$(fetch_status_contexts "$sha")"
    else
      rows="$(fetch_check_runs "$sha")"
    fi
    local name conclusion app_id verdict accepted=""
    while IFS=$'\t' read -r name conclusion app_id; do
      [ -n "$name" ] || continue
      verdict="$(classify_row "$name" "$conclusion" "$app_id" "$SOURCE_FEED")"
      if [ "$verdict" = "R3" ]; then
        ledger="$ledger$sha	$verdict	$name	[legacy namespace; normalization moved: $(odd_codepoints "$name")]
"
      else
        ledger="$ledger$sha	$verdict	$name
"
      fi
      [ "$verdict" = "ACCEPT" ] && accepted="$accepted$name
"
    done <<EOF
$rows
EOF
    accepted="$(printf '%s' "$accepted" | sort -u)"
    if [ "$first" -eq 1 ]; then
      intersection="$accepted"; first=0
    else
      intersection="$(comm -12 <(printf '%s\n' "$intersection") <(printf '%s\n' "$accepted"))"
    fi
    accepted_all="$accepted_all$accepted
"
  done

  if [ "$EXPLAIN" -eq 1 ]; then
    echo "── poison filter ledger (sha / verdict / name) ──" >&2
    printf '%s' "$ledger" >&2
    echo "── S1 intersection across ${#SHAS[@]} sha(s): $(printf '%s\n' "$intersection" | grep -c . || true) name(s) ──" >&2
  fi

  # ── stage 2: selection ──
  local main_rows=""
  main_rows="$(main_conclusions)"

  local selected="" exclusions_json="[]" n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    local hit file job coe pf needs reason=""
    if hit="$(job_for_name "$n" "$idx")"; then
      IFS=$'\t' read -r file job coe pf needs <<EOF
$hit
EOF
    else
      file=""; job=""; coe=0; pf=0; needs=""
      reason="S0 UNMAPPED: no job in $WORKFLOW_DIR publishes this name — it cannot be traced to source"
    fi

    # S2 advisory by intent
    if [ -z "$reason" ] && [ "$coe" = "1" ]; then
      reason="S2 ADVISORY: $file job '$job' carries continue-on-error:true — needs.<job>.result reads success even when it failed"
    fi
    if [ -z "$reason" ]; then
      local i=0
      while [ "$i" -lt "${#ADVISORY_BY_INTENT_NAMES[@]}" ]; do
        if [ "$n" = "${ADVISORY_BY_INTENT_NAMES[$i]}" ]; then
          reason="S2 ADVISORY BY INTENT: ${ADVISORY_BY_INTENT_REASONS[$i]}"
          break
        fi
        i=$((i + 1))
      done
    fi

    # S4 paths-filtered — an absent check is a permanent "expected"
    if [ -z "$reason" ] && [ "$pf" = "1" ]; then
      reason="S4 PATHS-FILTERED: $file only runs on matching paths, so on other PRs this name is ABSENT — a required absent context never reports"
    fi

    # S5 red on main
    if [ -z "$reason" ]; then
      local mc
      mc="$(printf '%s\n' "$main_rows" | awk -F'\t' -v k="$n" '$1 == k && $2 != "null" && $2 != "" { print $2 }' | tail -1 || true)"
      if [ -n "$mc" ] && [ "$mc" != "success" ]; then
        reason="S5 RED ON MAIN: latest completed conclusion on $BRANCH is '$mc' — requiring it reds every PR from day one"
      fi
    fi

    if [ -n "$reason" ]; then
      exclusions_json="$(printf '%s' "$exclusions_json" | jq --arg c "$n" --arg r "$reason" '. + [{context: $c, reason: $r}]')"
      note "  exclude  $n  — $reason"
    else
      selected="$selected$n
$file	$job	$needs
"
      note "  keep     $n  ($file job '$job')"
    fi
  done <<EOF
$intersection
EOF

  # S3 subsumed — computed last, against the survivors: a name that is a `needs`
  # upstream of a kept aggregator is already covered by it.
  local pairs subsumed="" i=1 total
  pairs="$(printf '%s' "$selected")"
  total="$(grep -c . <<<"$pairs" || true)"
  while [ "$i" -le "$total" ]; do
    local meta f nds
    meta="$(sed -n "$((i + 1))p" <<<"$pairs")"
    f="$(cut -f1 <<<"$meta")"
    nds="$(cut -f3 <<<"$meta")"
    if [ -n "$nds" ] && [ -n "$f" ]; then
      subsumed="$subsumed$(subsumed_jobs "$f" "$nds" "$idx")
"
    fi
    i=$((i + 2))
  done

  local final="" nm j=1
  while [ "$j" -le "$total" ]; do
    local meta fj
    nm="$(sed -n "${j}p" <<<"$pairs")"
    meta="$(sed -n "$((j + 1))p" <<<"$pairs")"
    j=$((j + 2))
    [ -n "$nm" ] || continue
    fj="$(cut -f1,2 <<<"$meta")"
    # Membership is by file+job id, never by name: a matrixed upstream's
    # RENDERED name carries a suffix its `name:` template does not.
    if grep -qxF "$fj" <<<"$subsumed"; then
      exclusions_json="$(jq --arg c "$nm" \
        --arg r "S3 SUBSUMED: an upstream \`needs\` of a required aggregator — the aggregator already fails when it fails" \
        '. + [{context: $c, reason: $r}]' <<<"$exclusions_json")"
      note "  exclude  $nm  — S3 SUBSUMED"
      continue
    fi
    final="$final$nm
"
  done

  [ -n "$(printf '%s' "$final" | grep -c . || true)" ] || true
  if [ "$(printf '%s' "$final" | grep -c . || true)" -eq 0 ]; then
    die "selection produced ZERO contexts — refusing to emit a spec that protects nothing"
  fi

  local checks_json
  checks_json="$(printf '%s' "$final" | grep . | jq -R --argjson a "$ACTIONS_APP_ID" '{context: ., app_id: $a}' | jq -s '.')"

  local spec
  spec="$(jq -n \
    --arg repo "$REPO" \
    --arg branch "$BRANCH" \
    --argjson checks "$checks_json" \
    --argjson exclusions "$exclusions_json" \
    --argjson shas "$(printf '%s\n' "${SHAS[@]}" | jq -R . | jq -s '.')" \
    '{
      "_readme": [
        "GENERATED by scripts/required-checks-generate.sh from check runs actually observed on the sampled shas. Never hand-edit a context string: GitHub validates neither the name nor the app_id, and a typo deadlocks the branch forever (honest-gates D21).",
        "enforced=false means protection has NOT been applied yet; the CI guard still runs the deadlock detector against real heads, so it is never vacuous. hgw2-s7 regenerates this file and flips enforced to true in the same PR.",
        "Every protection field is enumerated INCLUDING the falses: the PUT does not converge omitted state (allow_force_pushes resets, required_linear_history and required_conversation_resolution do NOT). See honest-gates D41.",
        "No workflow carries a merge_group trigger and this repo is user-owned (no merge queue), so queue semantics are not a variable today. If the repo ever moves to an org and the merge queue is enabled, every required check would sit Pending-forever in the merge group on day one.",
        "OPERATIONAL: a required context whose LATEST run on the head concluded `cancelled` blocks the merge with a third refusal shape (`... is cancelled.`, honest-gates D38) and clears only on a re-run or a push. elixir.yml sets cancel-in-progress on PR refs, so a superseded head can leave one behind. That is a correct red, not a deadlock — but the merge protocol must expect it, because the message is neither `is failing.` nor `is expected.`"
      ],
      enforced: false,
      repo: $repo,
      branch: $branch,
      generated_from_shas: $shas,
      protection: {
        required_status_checks: {
          strict: false,
          checks: $checks
        },
        enforce_admins: true,
        required_pull_request_reviews: null,
        restrictions: null,
        required_linear_history: false,
        allow_force_pushes: false,
        allow_deletions: false,
        block_creations: false,
        required_conversation_resolution: false,
        lock_branch: false,
        allow_fork_syncing: false
      },
      exclusions: $exclusions
    }')"

  if [ -n "$OUT" ]; then
    printf '%s\n' "$spec" > "$OUT"
    echo "wrote $OUT ($(printf '%s' "$final" | grep -c . || true) required context(s))"
  else
    printf '%s\n' "$spec"
  fi
}

main "$@"
