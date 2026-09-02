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
# THE EMIT IS A MERGE, NOT AN OVERWRITE (wave 11)
#
# This script used to build the spec with `jq -n` and `> $OUT`, i.e. a pure
# overwrite by the S1 intersection. That silently DE-REGISTERS any committed
# context the sample could not have rendered — `PR references an active task` is
# the standing casualty, because `pr-task-gate.yml` is `on: pull_request` only
# and therefore renders on NO main head, in any window, ever. No sample can save
# it; only a merge can. So `--out` now JQ-MERGES onto the committed spec
# (`--merge-base`, default `.github/required-checks.json`; `--no-merge` for a
# greenfield emit and for the hermetic tests), and the union is taken on the
# context string with the base's app_id winning.
#
# AND A LOSS IS REFUSED BEFORE IT CAN BE MERGED AWAY (wave 11)
#
# The merge alone is not the guard. A committed name that failed to render is a
# FACT about the sample, and it is refused BY NAME — never by a count, because
# the emitted count on this repo is 0, 6 and 7 across three windows inside one
# hour (D130), so no count threshold can tell a healthy window from a dead one.
# The check sits immediately after the S1 `comm -12`, because stage 2 iterates
# the intersection and is therefore structurally incapable of noticing a name
# that never entered it. A name that genuinely cannot render on the sampled
# shapes is acknowledged ONE AT A TIME with `--expect-unrendered <name>`, which
# is a decision somebody typed, not a threshold that drifted.
#
# AND `.exclusions` GETS THE SAME PAIR (wave 57)
#
# `.exclusions` is a ledger of DECISIONS — the reason prose is the only record of
# why a green, correct check is held out — and it was emitted from the derived
# array alone, eleven lines below the check list's union. Over the frozen fixture
# pair that took 25 rows IN and wrote 18 OUT, exit 0, nothing on stderr. It is
# now the SAME union (the DERIVED reason winning where both sides carry a row) so
# the merge CARRIES a row the sample could not restate, and the SAME refusal so
# the carry is never silent: `--expect-unrendered <name>` acknowledges an absence
# one name at a time. A committed exclusion this run SELECTS as required is a
# CONTRADICTION rather than an absence and takes `--expect-promoted <name>`,
# which DROPS the row instead of carrying it.
#
# AND THE SAME CONTRADICTION POINTS BOTH WAYS
#
# The mirror — a name the committed spec REQUIRES that this run derives as
# EXCLUDED — had no clause at all: the check list's base-first union carried the
# required row while the derived exclusion was appended beside it, so adding
# `continue-on-error: true` to an already-required job emitted ONE CONTEXT ON
# BOTH LISTS at exit 0, and `required-checks-verify.sh` reads no `.exclusions`,
# so nothing downstream could notice. It is refused at the emit and acknowledged
# with `--expect-demoted <name>`, which DROPS THE REQUIRED row — a protection
# change, hence a name a human types.
#
# AND AN EXCLUDED AGGREGATOR DEMOTES ITS LEAVES, NEVER PROMOTES THEM (wave 11)
#
# S3 subsumption is computed against the SURVIVORS. So when a stage excludes an
# aggregator, its `needs` upstreams stop being subsumed by anything and get
# PROMOTED instead — the exact inversion of the intent. `Security gate` is the
# standing case (S5 red on main when this was written, S7 held-by-decision since
# 95ace3150 cleared it — the demotion keys on the EXCLUSION, not on which stage
# produced it); without S6 the flip would have required its three green leaves,
# quietly re-implementing at leaf granularity, forever, the aggregator the run
# just disqualified.
#
# USAGE
#   scripts/required-checks-generate.sh --sha <sha> --sha <sha> [--out FILE]
#   scripts/required-checks-generate.sh --sha <sha> --explain      # the ledger
#   scripts/required-checks-generate.sh --sha … --enforced true --out FILE
#
#   --expect-unrendered <name>  the sample could not render it; the MERGE carries it
#   --expect-promoted   <name>  committed EXCLUSION this run requires; DROPS the exclusion row
#   --expect-demoted    <name>  committed REQUIREMENT this run excludes; DROPS the required row
#
# The spec is regenerated immediately before any protection flip; it has a shelf
# life of about one merged workflow change.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── the shared check-runs reader ─────────────────────────────────────────────
# `fetch_check_runs` below used to hand-roll the jq/awk pipeline that
# scripts/lib/check-runs.sh owns, and required-checks-verify.sh kept a third
# copy of the same function. One reader, one dedup, one sort. Resolution is
# FAIL-CLOSED: no lib, no run — a private fallback copy is the defect being
# removed here.
#
# BARKPARK_CHECK_RUNS_LIB exists for exactly one caller, and it is not a
# production knob: required-checks.test.sh proves clauses by running sed-mutated
# COPIES of this file out of a temp directory, whose $0-derived REPO_ROOT is
# that temp directory. It is the same accommodation the mutants already make for
# --workflows and --prose.
CHECK_RUNS_LIB="${BARKPARK_CHECK_RUNS_LIB:-$REPO_ROOT/scripts/lib/check-runs.sh}"
[ -f "$CHECK_RUNS_LIB" ] || {
  echo "FAIL: no check-runs reader at $CHECK_RUNS_LIB — refusing to run without the shared primitive" >&2
  exit 1
}
# shellcheck source=scripts/lib/check-runs.sh
. "$CHECK_RUNS_LIB"

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
ENFORCED="false"
MERGE_BASE=""
NO_MERGE=0
EXPECT_UNRENDERED=()
EXPECT_PROMOTED=()
EXPECT_DEMOTED=()

# Advisory BY INTENT: names that run green, are not paths-filtered, and are not
# subsumed — but must still never gate a merge. Each needs one line of why.
ADVISORY_BY_INTENT_NAMES=(
  "PR task gate self-test"
)
ADVISORY_BY_INTENT_REASONS=(
  "the task gate's own harness — it proves the gate CAN fail; requiring it makes the tripwire's tripwire load-bearing"
)

# S7 EXCLUDED BY DECISION: names that pass every mechanical stage — green on
# main, unfiltered, unsubsumed, blocking — and are still held OUT on purpose.
# This list is hand-maintained ON PURPOSE and each entry carries a dated ground
# and a re-evaluation trigger, so it reads as a hold rather than a permanent
# verdict. Nothing else in this script can express "correct, but not yet".
#
# TREAT ANY GROWTH OF THIS LIST AS A RED FLAG (wave 11 review). It is the one
# place a name can be parked without mechanical evidence. Every entry must say
# what would retire it.
EXCLUDED_BY_DECISION_NAMES=(
  "Required-check spec gate"
  "Security gate"
)
EXCLUDED_BY_DECISION_REASONS=(
  "S7 EXCLUDED BY DECISION: structurally clean, but it does NOT render on #8222's merge ref — that PR's base is stale and predates #8253, which created the job. CORRECTED IN REVIEW 2026-07-31: the original wording said requiring it would deadlock 'the one open PR whose merge clears Security gate'. #8222 no longer clears anything — 95ace3150 already did — and #8222 is itself CONFLICTING/DIRTY, so it is deadlocked on its own and must be rebased before it can land at all. CORRECTED AGAIN 2026-08-06, wave 36, BY HAND: this row asserted two things it could not support. (1) 'green on main' was FALSE — on main head 070c7584b \`bash scripts/required-checks.test.sh --hermetic\` ended '115 passed, 1 failed', its §18 protection-claim census reddening on the wave-35 write-up OF ITSELF. That specific failure is fixed by the quoted-pattern fence in the same commit as this correction, but the greenness claim is DROPPED rather than re-asserted: a spec file cannot know a check's colour, only the run can, and a stale colour written here is exactly the kind of claim this epic exists to delete. (2) 'Re-evaluate once #8222 lands or is rebased' was a trigger that can NEVER FIRE — #8222 is CLOSED with mergedAt null (\`gh pr view 8222 --json state,mergedAt\`), so the exclusion sealed itself shut and would have outlived every reason it names. THE HOLD ITSELF STANDS, on ground that is live and re-measurable: required-checks-drift.yml is deliberately path-UNFILTERED, so every open PR renders this name from its own head; today those verdicts are stale (rendered 07-31..08-05, before the ledger merge) and three of the seven open PRs are CONFLICTING and do not render the name at all — registering it today deadlocks 7 of 7 under enforce_admins. THE REPLACEMENT TRIGGER, checkable by anyone and owned by nobody's memory: the spec gate is green on main HEAD, and a fresh \`scripts/registration-deadlock-sweep.sh\` run for this context reports zero casualties. Tracked as cch-w37-bl-register-spec-gate-human-gate."
  "S7 EXCLUDED BY DECISION. CORRECTED IN REVIEW 2026-07-31 — this row was generated as 'S5 RED ON MAIN' from a window (e34031104) where that was true, and the ground EVAPORATED under the wave: 95ace3150 landed the req bump from outside this epic and \`Security gate\` is green on main head 6e53d2782. Re-running this generator against the post-bump window PROMOTES the name into required protection — measured, not feared — so the hold was moved into the generator's hand-maintained S7 list. The ground is now forward-looking rather than historical: its sole blocking upstream is \`mix-audit\`, which runs mix_audit against a LIVE advisory database, so a CVE published tomorrow reds it on every open PR with no change to this repo — a permanently correct red that no PR can clear, which is exactly what branch protection must never pin. Registering it needs its own wave: a documented policy for who clears a fleet-wide advisory red, plus a fresh deadlock sweep. Its leaves go down WITH it via S6."
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
#
# THE READ IS THE LIB'S; THE RULING ON EMPTINESS IS NOT, AND THAT LINE MATTERS.
# check_runs_rows_ext returns an empty feed as ZERO ROWS AND EXIT 0 on purpose:
# for the registration sampler a head whose feed is empty is the cadence datum,
# so a primitive that died there could not be shared. For a GENERATOR the
# opposite holds — a spec generated from nothing is a cheerfully empty required
# set, i.e. a branch protected by nothing. So the refusal stays HERE, at the
# call site, and §4 of required-checks.test.sh mutation-proves that it fires.
# Inheriting the lib's permissiveness would turn this fail-closed guard into a
# fail-open one.
fetch_check_runs() {
  local sha="$1" rows rc=0
  rows="$(check_runs_rows_ext "$REPO" "$sha" "$FIXTURE_DIR")" || rc=$?
  [ "$rc" -eq 0 ] \
    || die "cannot read check-runs for $sha (unreadable feed is a failure, not an empty set)"
  [ -n "$rows" ] \
    || die "check-runs for $sha is EMPTY — refusing to generate a spec from nothing"
  # The lib emits five columns; this feed's consumers read three, and
  # fetch_status_contexts emits the same three — so project here rather than
  # widening the reader loop, and the two feeds stay interchangeable.
  printf '%s\n' "$rows" | cut -f1,2,5
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
# is matrixed, the job-level `continue-on-error` LITERAL (empty when the job is
# blocking), whether its workflow is paths-filtered on pull_request, its
# `needs`, and whether EVERY decision-bearing step in it is advisory (the
# advisory literal is `-` when the job is blocking, never empty — see flush).
# Everything the selection stage decides is derived from THIS, not from the
# shape of a rendered string.
#
# THE TRIGGER KEY IS NOT ALWAYS THE BYTES `on:`. YAML 1.1 resolves a BARE `on`
# to the BOOLEAN true, which is why yamllint's `truthy` rule pushes authors to
# write `"on":` — and GitHub accepts it (the official workflow schema demands a
# key literally named `on`, and public workflows carry the quoted form). A byte
# anchor of `/^on:/` therefore reads a perfectly legal workflow as having NO
# triggers at all: `pf` never gets set, `/^jobs:/` still matches, and a
# paths-filtered job is emitted REQUIRED at exit 0 — the D18/D20 deadlock,
# manufactured by the script written to prevent it. Match all three spellings.
#
# THE GLOB IS `*.yml` AND `*.yaml`. GitHub reads both; a `*.yml`-only index
# leaves a `.yaml` job UNMAPPED and reports the factually false S0 reason "no
# job in <dir> publishes this name". scripts/never-cancel-main-check.sh:96
# already globs both — this is the repo's own standard, not a judgement call.
build_workflow_index() {
  local f
  for f in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    awk -v file="$(basename "$f")" '
      function indent_of(s) { match(s, /^ */); return RLENGTH }

      # A step ends when the next one starts, when the `steps:` block ends, or
      # when the job does. A step that carries neither `run:` nor `uses:` makes
      # no decision (it is a `with:`-less `name:`-only stanza or a comment), so
      # it neither counts toward the laundering shape nor rescues a job from it.
      function stepflush() {
        if (instep && sdecision) { ndec++; if (scoe) ndeccoe++ }
        instep = 0; sdecision = 0; scoe = 0; inblock = 0
      }
      function flush() {
        stepflush()
        if (job != "") {
          # TAB IS IFS WHITESPACE. `IFS=$'\t' read` COLLAPSES a run of tabs,
          # so an EMPTY field silently shifts every later one — which is why
          # `needs`, the only field that is legitimately empty, stays LAST and
          # why a blocking job writes the sentinel `-` rather than "".
          printf "%s\t%s\t%s\t%d\t%s\t%d\t%d\t%s\n", file, job,
                 (jname == "" ? job : jname), matrixed, (coe == "" ? "-" : coe),
                 pf, (ndec > 0 && ndec == ndeccoe) ? 1 : 0, needs
        }
        job = ""; jname = ""; matrixed = 0; coe = ""; needs = ""
        insteps = 0; ndec = 0; ndeccoe = 0
      }
      BEGIN { inon = 0; inpr = 0; injobs = 0; pf = 0; instrategy = 0; inneeds = 0
              coe = ""; insteps = 0; ndec = 0; ndeccoe = 0 }

      # ---- workflow-level triggers: is pull_request paths-filtered? ----
      # A quoted trigger key is the same key to GitHub. The anchor spells the
      # single quote as awk escape \047 so it needs no shell quote gymnastics
      # (the idiom is already in scripts/check-deployyml-filters.sh).
      /^("on"|\047on\047|on)[ \t]*:/ { inon = 1; next }
      inon && /^[A-Za-z"\047]/  { inon = 0; inpr = 0 }
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
        # A job key at depth 4 ends the `steps:` block, wherever it sits.
        if (insteps && $0 ~ /^    [A-Za-z]/) { stepflush(); insteps = 0 }

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
        # THE VALUE, NOT THE BYTES `true`. `'\''true'\''`, `"true"`, `yes` and a
        # `${{ … }}` expression are all continue-on-error to GitHub and all
        # escaped a `: *true` literal match. Anything that is not a literal
        # `false` is advisory — a `${{ … }}` is statically unknowable, and
        # classifying an unknowable job as advisory is the direction that
        # cannot pin a check which may not be able to fail. The literal is
        # carried through to the S2 reason so the operator reads what it saw.
        if ($0 ~ /^    continue-on-error:/) {
          v = $0; sub(/^    continue-on-error:[ \t]*/, "", v)
          sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); gsub(/\t/, " ", v)
          if (v == "") v = "(empty)"
          # `false`, `"false"`, a single-quoted false and an absent value are
          # all FALSE to GitHub, so all four leave the job BLOCKING. Normalising
          # them is the protective direction: classifying a blocking job as
          # advisory drops it out of the required set, which LOSES a gate, and
          # losing protection is never a safe default here. Every other
          # spelling — `true`, `"true"`, `yes`, `${{ … }}` — stays advisory.
          vn = v; gsub(/^["\047]|["\047]$/, "", vn)
          coe = (vn == "false" || v == "(empty)") ? "" : v
          next
        }
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

        # ---- steps: the laundering shape ----
        # A job with NO job-level key whose every decision-bearing step carries
        # continue-on-error cannot fail either, and no single boolean can tell
        # it from js-tests.yml'"'"'s `test` job, which mixes three advisory steps
        # among genuinely blocking ones. So this counts rather than classifies,
        # and the refusal that reads it is LOUD (see assert_no_laundered_jobs):
        # silently demoting a mixed job would EXCLUDE a real gate, and losing
        # protection is not a safe direction in either wave'"'"'s doctrine.
        if ($0 ~ /^    steps:/) { stepflush(); insteps = 1; next }
        if (insteps) {
          # A block scalar (`run: |`) carries arbitrary text, including the
          # literal `continue-on-error:` in a shell heredoc — skip its body.
          if (inblock) { if ($0 ~ /^[ \t]*$/ || indent_of($0) > blockind) next; inblock = 0 }
          if ($0 ~ /^      - /) { stepflush(); instep = 1 }
          if (instep) {
            line = $0; ind = indent_of($0)
            sub(/^ +/, "", line)
            if (sub(/^- +/, "", line)) ind = ind + 2
            if (line ~ /^(run|uses):/) sdecision = 1
            if (line ~ /^continue-on-error:/) {
              v = line; sub(/^continue-on-error:[ \t]*/, "", v)
              sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
              # Same normalisation as the job level, and for the same
              # reason inverted: a quoted false step read as advisory could
              # push a mixed job into the laundering refusal, which is a loud
              # FALSE red rather than a lost gate — still worth not doing.
              vn = v; gsub(/^["\047]|["\047]$/, "", vn)
              if (vn != "false" && vn != "") scoe = 1
            }
            if (line ~ /^[A-Za-z_-]+:[ \t]*[|>][-+0-9]*[ \t]*$/) { inblock = 1; blockind = ind }
          }
          next
        }
      }
      END { flush() }
    ' "$f"
  done
}

# A job that cannot fail, spelled one step at a time. Refused at INDEX-BUILD
# time and BY NAME, never silently classified: `coe` is a single boolean and a
# job whose every decision step is advisory looks identical to one whose steps
# are merely mostly advisory, so a classifier would have to choose between
# emitting a check that can never red and EXCLUDING a genuine gate. Both are
# wrong; the operator gets the sentence instead. Fires on ZERO jobs in
# .github/workflows today — js-tests.yml `test` carries three advisory steps
# among blocking ones and is correctly untouched.
assert_no_laundered_jobs() {
  local idx="$1" file job tmpl launder
  while IFS=$'\t' read -r file job tmpl _matrixed _coe _pf launder _needs; do
    [ -n "$job" ] || continue
    [ "$launder" = "1" ] || continue
    die "EVERY DECISION-BEARING STEP IS ADVISORY: $file job '$job' declares no job-level \`continue-on-error\`, but every one of its \`run:\`/\`uses:\` steps carries one — the job publishes a check that CANNOT report a failure, while reading as blocking here. Either put \`continue-on-error: true\` on the JOB (which S2 excludes, honestly), or take the flag off the steps that are supposed to decide. This refusal names the job rather than classifying it because a job that MIXES advisory and blocking steps (js-tests.yml job 'test') is legitimate, and demoting one to catch the other would EXCLUDE a real gate."
  done <<EOF
$idx
EOF
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
  while IFS=$'\t' read -r file job tmpl _matrixed _coe _pf _launder _needs; do
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
  while IFS=$'\t' read -r file job tmpl matrixed coe pf _launder needs; do
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
    while IFS=$'\t' read -r jf jj _t _m _c _p _l jneeds; do
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
#
# THE ROW ORDER IS THE CONTRACT, AND S5 READS IT (wave 10). This function emits
# one `name<TAB>conclusion` row per (sha, name) in the order the shas arrive,
# and `GET /commits` returns them NEWEST FIRST — so for any given name the FIRST
# row is the most recent head in the window and the LAST row is the oldest. S5
# used to take `tail -1`, i.e. the OLDEST head, while its own comment and its own
# exclusion string both said "latest". Mutation-proven on identical fixtures in
# §3e of the test suite: the two orderings disagree, and the disagreement is
# exactly the shape that excludes a freshly-green aggregator because it was red
# ten commits ago. `--main-sha` and the fixture `main-shas.txt` MUST therefore be
# supplied newest-first too.
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

# By SHAPE, not a line range: a range silently truncates the moment anyone adds
# a paragraph to the header above it — which wave 11 did, three times.
usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit "${1:-0}"
}

# Does this workflow have any trigger that fires on a BRANCH HEAD? A workflow
# that is `on: pull_request` only publishes check runs against the PR's merge
# ref and NEVER against a commit on main — so no sampling window, however wide,
# will ever see its name, and widening the window in response is wasted motion.
workflow_has_head_trigger() {
  [ -f "$1" ] || return 1
  # SAME THREE SPELLINGS as build_workflow_index: with a byte anchor of
  # `/^on:/` a `"on":` workflow that plainly carries `push:` draws the
  # factually FALSE hint "PULL_REQUEST-ONLY: it can never render on a branch
  # head", sending the operator to widen a sampling window that was never the
  # problem.
  awk '
    /^("on"|\047on\047|on)[ \t]*:/ { inon = 1; next }
    inon && /^[A-Za-z"\047]/ { exit }
    inon && /^  (push|schedule|workflow_dispatch|merge_group):/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# One line of provenance for a committed name the sample did not render, so the
# operator can tell "this window is unlucky, re-sample" from "no window can ever
# help, the merge is the only carrier".
unrenderable_hint() {
  local name="$1" idx="$2" hit file job
  if hit="$(job_for_name "$name" "$idx")"; then
    file="$(cut -f1 <<<"$hit")"
    job="$(cut -f2 <<<"$hit")"
    if workflow_has_head_trigger "$WORKFLOW_DIR/$file"; then
      printf '  [%s job %s — it DOES trigger on a branch head, so this window is the anomaly: re-sample]' "$file" "$job"
    else
      printf '  [%s job %s — PULL_REQUEST-ONLY: it can never render on a branch head, so only the merge can carry it]' "$file" "$job"
    fi
  else
    printf '  [no job in %s publishes this name any more — renamed or deleted?]' "$WORKFLOW_DIR"
  fi
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
      --enforced)
        case "$2" in
          true|false) ENFORCED="$2" ;;
          *) die "--enforced takes exactly 'true' or 'false' (got '$2') — protection is not a truthy string" ;;
        esac
        shift 2 ;;
      --merge-base) MERGE_BASE="$2"; NO_MERGE=0; shift 2 ;;
      --no-merge) NO_MERGE=1; shift ;;
      --expect-unrendered) EXPECT_UNRENDERED+=("$2"); shift 2 ;;
      --expect-promoted) EXPECT_PROMOTED+=("$2"); shift 2 ;;
      --expect-demoted) EXPECT_DEMOTED+=("$2"); shift 2 ;;
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

  # ── the merge base ──
  # An unreadable base is a hard failure, never a silent fall-back to greenfield:
  # a greenfield emit is exactly the overwrite this stage exists to prevent, and
  # it would look identical in the diff.
  local base_json='null' committed_required="" committed_excluded=""
  if [ "$NO_MERGE" -eq 0 ]; then
    local base_file="${MERGE_BASE:-$REPO_ROOT/.github/required-checks.json}"
    [ -f "$base_file" ] || die "no merge base at $base_file — pass --no-merge for a deliberate greenfield emit; a missing base must never silently become one"
    jq -e . "$base_file" >/dev/null 2>&1 || die "$base_file is not valid JSON — refusing to merge onto a file that cannot be read"
    base_json="$(cat "$base_file")"
    committed_required="$(jq -r '.protection.required_status_checks.checks[]?.context // empty' "$base_file" | sort -u)"
    committed_excluded="$(jq -r '.exclusions[]?.context // empty' "$base_file" | sort -u)"
  fi

  local idx
  idx="$(build_workflow_index)"
  [ -n "$idx" ] || die "the workflow index is empty — the parser is broken, not the repo"
  assert_no_catchall_job_names "$idx"
  assert_no_laundered_jobs "$idx"

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

  # ── S1-LOSS: a committed name that failed to render, refused BY NAME ─────────
  #
  # THIS IS THE ONLY PLACE THE LOSS IS VISIBLE. Stage 2 below iterates the
  # INTERSECTION; a name that never entered it is not excluded, it is absent, so
  # `.exclusions` — the only ledger stage 2 writes — is structurally incapable of
  # recording it. Hence the check sits here, between the `comm -12` and the
  # selection, and not one line later.
  #
  # KEYED ON NAMES, NEVER ON A COUNT. Measured on this repo inside one hour, the
  # emitted count over three sampling windows was 0, then 6, then 7 (D130): three
  # of the newest ten main heads carry ZERO check runs at all, and `Elixir gate`
  # renders on two of them. Any `>= N` threshold is therefore either satisfied by
  # a window that lost the repo's only blocking gate, or unsatisfiable by a
  # healthy one. The set difference against the committed spec is the only
  # statement that means the same thing in every window.
  #
  # ACKNOWLEDGEMENT IS PER NAME AND IS TYPED BY A HUMAN. `--expect-unrendered
  # <name>` says "this name provably cannot render on the shapes I sampled, and I
  # am relying on the MERGE to carry it." `PR references an active task` is the
  # standing case: `pr-task-gate.yml` is `on: pull_request` only, so it renders on
  # no main head in any window ever, and no better sample exists.
  if [ -n "$committed_required" ]; then
    local lost_names="" cname acked ack
    while IFS= read -r cname; do
      [ -n "$cname" ] || continue
      grep -qxF "$cname" <<<"$intersection" && continue
      acked=0
      for ack in ${EXPECT_UNRENDERED[@]+"${EXPECT_UNRENDERED[@]}"}; do
        [ "$ack" = "$cname" ] && acked=1 && break
      done
      if [ "$acked" -eq 1 ]; then
        note "  unrendered (ACKNOWLEDGED) $cname — carried by the merge, not by this sample"
        continue
      fi
      lost_names="$lost_names  LOST  $cname$(unrenderable_hint "$cname" "$idx")
"
    done <<EOF
$committed_required
EOF
    if [ -n "$lost_names" ]; then
      {
        echo "S1 LOSS — the sample did not render context(s) the COMMITTED spec already requires."
        echo "Every line below is live branch protection today. Emitting from this sample and"
        echo "committing the result is how a required gate stops being one, silently:"
        printf '%s' "$lost_names"
        echo
        echo "Sampled shas: ${SHAS[*]}"
        echo "This is NOT a count problem and no threshold can express it: the emitted count on"
        echo "this repo was 0, 6 and 7 across three windows inside one hour (D130)."
        echo "Either sample heads on which the name actually rendered, or — if it provably"
        echo "cannot render on any head of this shape — acknowledge it ONE NAME AT A TIME with"
        echo "  --expect-unrendered '<name>'"
        echo "which relies on the merge to carry it and leaves your decision in the command line."
      } >&2
      exit 1
    fi
  fi

  # ── stage 2: selection ──
  local main_rows=""
  main_rows="$(main_conclusions)"

  local selected="" exclusions_json="[]" excluded_meta="" n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    local hit file job coe pf needs reason=""
    if hit="$(job_for_name "$n" "$idx")"; then
      IFS=$'\t' read -r file job coe pf needs <<EOF
$hit
EOF
    else
      file=""; job=""; coe="-"; pf=0; needs=""
      reason="S0 UNMAPPED: no job in $WORKFLOW_DIR publishes this name — it cannot be traced to source"
    fi

    # S2 advisory by intent
    # ANY value other than a literal `false` is advisory, and the literal it
    # actually carries is printed: `'"'"'true'"'"'`, `"true"`, `yes` and `${{ … }}` are
    # all continue-on-error to GitHub, and a reason that says "carries
    # continue-on-error:true" for a job spelled `yes` reads as a transcription
    # error rather than as the classification it is.
    if [ -z "$reason" ] && [ "$coe" != "-" ]; then
      reason="S2 ADVISORY: $file job '$job' carries continue-on-error: $coe — needs.<job>.result reads success even when it failed (anything but a literal \`false\` is advisory; a \`\${{ … }}\` expression is statically unknowable and is classified advisory rather than pinned)"
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
      # The FIRST matching row, not the last: main_rows is newest-first (see
      # main_conclusions). `exit` inside awk rather than `| head -1`, because a
      # `head` that closes the pipe early takes awk out with SIGPIPE and this
      # script runs under `set -o pipefail`.
      mc="$(printf '%s\n' "$main_rows" | awk -F'\t' -v k="$n" '$1 == k && $2 != "null" && $2 != "" { print $2; exit }' || true)"
      if [ -n "$mc" ] && [ "$mc" != "success" ]; then
        reason="S5 RED ON MAIN: latest completed conclusion on $BRANCH is '$mc' — requiring it reds every PR from day one"
      fi
    fi

    # S7 excluded by decision — correct, green, and held out on purpose
    if [ -z "$reason" ]; then
      local d=0
      while [ "$d" -lt "${#EXCLUDED_BY_DECISION_NAMES[@]}" ]; do
        if [ "$n" = "${EXCLUDED_BY_DECISION_NAMES[$d]}" ]; then
          reason="${EXCLUDED_BY_DECISION_REASONS[$d]}"
          break
        fi
        d=$((d + 1))
      done
    fi

    if [ -n "$reason" ]; then
      exclusions_json="$(printf '%s' "$exclusions_json" | jq --arg c "$n" --arg r "$reason" '. + [{context: $c, reason: $r}]')"
      note "  exclude  $n  — $reason"
      # Recorded so S6 can find the LEAVES of an excluded aggregator. Without
      # this row the demotion has nothing to key on: `.exclusions` carries the
      # name and the prose, and neither one resolves back to a job's `needs`.
      excluded_meta="$excluded_meta$n	$file	$job	$needs
"
    else
      selected="$selected$n
$file	$job	$needs
"
      note "  keep     $n  ($file job '$job')"
    fi
  done <<EOF
$intersection
EOF

  # ── S6: an EXCLUDED aggregator DEMOTES its leaves ───────────────────────────
  #
  # S3 (below) subsumes upstreams of the aggregators that SURVIVED. The mirror
  # case is the one that bites: when S5 excludes `Security gate` for being red on
  # main, its `needs` upstreams stop being subsumed by anything and fall through
  # every remaining stage green — so the run PROMOTES `Dispatch (security paths)`,
  # `Security gate shape ratchet` and `Sobelow baseline does not swallow its own
  # inline waivers (blocking)`, re-implementing at leaf granularity, and forever,
  # exactly the aggregator the sample just disqualified. That is the inversion of
  # the intent: an aggregator was excluded because requiring it is wrong TODAY,
  # not because its internals should each become a contract.
  #
  # Membership is by file+job id, never by rendered name — a matrixed upstream's
  # rendered name carries a suffix its `name:` template does not.
  local demoted="" ex_name ex_file ex_job ex_needs df dj
  while IFS=$'\t' read -r ex_name ex_file ex_job ex_needs; do
    [ -n "$ex_file" ] && [ -n "$ex_needs" ] || continue
    while IFS=$'\t' read -r df dj; do
      [ -n "$dj" ] || continue
      demoted="$demoted$df	$dj	$ex_name
"
    done <<EOF
$(subsumed_jobs "$ex_file" "$ex_needs" "$idx")
EOF
  done <<EOF
$excluded_meta
EOF

  if [ -n "$demoted" ]; then
    local kept="" dp dtotal dj_i=1 dnm dmeta dfj dagg
    dp="$(printf '%s' "$selected")"
    dtotal="$(grep -c . <<<"$dp" || true)"
    while [ "$dj_i" -le "$dtotal" ]; do
      dnm="$(sed -n "${dj_i}p" <<<"$dp")"
      dmeta="$(sed -n "$((dj_i + 1))p" <<<"$dp")"
      dj_i=$((dj_i + 2))
      [ -n "$dnm" ] || continue
      dfj="$(cut -f1,2 <<<"$dmeta")"
      dagg="$(awk -F'\t' -v k="$dfj" '$1 "\t" $2 == k { print $3; exit }' <<<"$demoted")"
      if [ -n "$dagg" ]; then
        exclusions_json="$(jq --arg c "$dnm" \
          --arg r "S6 LEAF OF AN EXCLUDED AGGREGATOR: an upstream \`needs\` of \`$dagg\`, which this run EXCLUDED — promoting the leaves of a disqualified aggregator re-implements it at leaf granularity and pins its internals as a contract" \
          '. + [{context: $c, reason: $r}]' <<<"$exclusions_json")"
        note "  exclude  $dnm  — S6 LEAF OF AN EXCLUDED AGGREGATOR ($dagg)"
        continue
      fi
      kept="$kept$dnm
$dmeta
"
    done
    selected="$kept"
  fi

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

  # ── S1-LOSS MIRROR: a COMMITTED EXCLUSION this run did not reproduce ─────────
  #
  # `.exclusions` is a ledger of DECISIONS, not a scratch pad: its reason prose is
  # the only record of why a green, correct check is deliberately held out. Until
  # this block existed the emit read `exclusions: $exclusions` with no base at
  # all — eleven lines below the check list's base-first union — so a regeneration
  # took 25 rows IN and wrote 18 OUT, exit 0, nothing on stderr. The loss is
  # IRRECOVERABLE by re-running: stage 2 iterates the INTERSECTION, so a
  # paths-filtered name that did not render can never re-enter the derived array.
  #
  # THE MERGE ALONE IS NOT THE FIX, and that was measured, not assumed: a
  # base-first union buys IMMORTALITY as well as survival — a stale reason on a
  # live row and a ghost row for a job no workflow publishes any more BOTH ride
  # through unnoticed, because a union cannot tell "the sample could not see it"
  # from "it should not be here any more". So the merge CARRIES and this block
  # NOTICES, which is exactly the pair the check LIST has run since wave 11: the
  # union at the emit, the per-name refusal at :601. Same flag, same discipline —
  # `--expect-unrendered '<name>'` says "this name provably cannot render on the
  # shapes I sampled, and I am relying on the MERGE to carry its row."
  #
  # A row this run SELECTED as required is a different animal and gets a different
  # word: that is not an absence, it is a CONTRADICTION — carrying it would emit
  # one context as both required and excluded — so `--expect-unrendered`, which
  # means "the sample could not see it", must NOT silence it. Its own
  # acknowledgement is `--expect-promoted '<name>'`, and unlike the other one it
  # DROPS the committed row rather than carrying it: the operator is saying the
  # derivation is right and the held-out decision is spent.
  local promoted_drop='[]'
  if [ -n "$committed_excluded" ]; then
    local derived_excluded lost_ex="" xname xacked xack
    derived_excluded="$(jq -r '.[].context' <<<"$exclusions_json")"
    while IFS= read -r xname; do
      [ -n "$xname" ] || continue
      grep -qxF "$xname" <<<"$derived_excluded" && continue
      if grep -qxF "$xname" <<<"$final"; then
        xacked=0
        for xack in ${EXPECT_PROMOTED[@]+"${EXPECT_PROMOTED[@]}"}; do
          [ "$xack" = "$xname" ] && xacked=1 && break
        done
        if [ "$xacked" -eq 1 ]; then
          note "  promoted (ACKNOWLEDGED) $xname — this run REQUIRES it, so its committed exclusion row is dropped"
          promoted_drop="$(jq --arg c "$xname" '. + [$c]' <<<"$promoted_drop")"
          continue
        fi
        lost_ex="$lost_ex  STALE $xname  [this run SELECTED it as REQUIRED — carrying the row emits one context as both required and excluded; drop the committed row, re-state its ground, or acknowledge with --expect-promoted]
"
        continue
      fi
      xacked=0
      for xack in ${EXPECT_UNRENDERED[@]+"${EXPECT_UNRENDERED[@]}"}; do
        [ "$xack" = "$xname" ] && xacked=1 && break
      done
      if [ "$xacked" -eq 1 ]; then
        note "  unreproduced exclusion (ACKNOWLEDGED) $xname — carried by the merge with its committed reason"
        continue
      fi
      lost_ex="$lost_ex  LOST  $xname$(unrenderable_hint "$xname" "$idx")
"
    done <<EOF
$committed_excluded
EOF
    if [ -n "$lost_ex" ]; then
      {
        echo "EXCLUSION LOSS — this run did not reproduce exclusion row(s) the COMMITTED spec carries."
        echo "The merge below WILL carry every row listed, so nothing is being deleted — but a row the"
        echo "derivation cannot restate is a decision no longer grounded in anything this run observed:"
        printf '%s' "$lost_ex"
        echo
        echo "Sampled shas: ${SHAS[*]}"
        echo "A LOST row is usually a paths-filtered or pull_request-only name the sampled heads could"
        echo "not render — its reason is frozen at the committed text until a head that renders it is"
        echo "sampled. Either sample such a head, or acknowledge it ONE NAME AT A TIME with"
        echo "  --expect-unrendered '<name>'"
        echo "which relies on the merge to carry the row and leaves your decision in the command line."
        echo "A STALE row is a CONTRADICTION, not an absence — this run requires the very name the"
        echo "committed spec holds out — so --expect-unrendered does not answer for it. Either fix the"
        echo "committed spec, or say the derivation is right and the decision is spent with"
        echo "  --expect-promoted '<name>'"
        echo "which DROPS the committed row instead of carrying it."
      } >&2
      exit 1
    fi
  fi

  # ── THE CONTRADICTION, THE OTHER WAY ROUND ──────────────────────────────────
  #
  # The STALE refusal above covers committed-EXCLUDED × derived-REQUIRED. Its
  # MIRROR — a name the committed spec REQUIRES that this run derived as
  # EXCLUDED — had no clause and no refusal: the check list is a base-first
  # union, so the committed row rode through while the derived exclusion was
  # appended beside it, and the emit put ONE CONTEXT ON BOTH LISTS at exit 0.
  # Reproduced by adding `continue-on-error: true` to an already-required job:
  # `{"both":["Cloud gate"]}`, nothing on stderr. Nothing downstream can notice
  # it either — scripts/required-checks-verify.sh contains zero reads of
  # `.exclusions`, so the spec would go on requiring a context this run just
  # said must never gate a merge, with the sentence explaining why sitting in
  # the same file.
  #
  # This is a CONTRADICTION, not an absence, so `--expect-unrendered` (which
  # means "the sample could not see it") must not answer for it — and it points
  # the opposite way from `--expect-promoted`. Its acknowledgement is
  # `--expect-demoted '<name>'`, and like the other CONTRADICTION flag it DROPS
  # a row rather than carrying both: here the REQUIRED row goes, because the
  # operator is saying the derivation is right and the check must stop gating.
  # DROPPING A REQUIRED ROW IS A PROTECTION CHANGE, which is exactly why it is
  # a name an operator types and never a filter the derivation computes.
  #
  # It ships DORMANT: the committed spec's required × excluded intersection is
  # `[]` today (4 required, 25 exclusions), so an unplanted regeneration is
  # untouched by this block.
  local demoted_drop='[]'
  if [ -n "$committed_required" ]; then
    local derived_ex_now contra="" rxname rxacked rxack
    derived_ex_now="$(jq -r '.[].context' <<<"$exclusions_json")"
    while IFS= read -r rxname; do
      [ -n "$rxname" ] || continue
      grep -qxF "$rxname" <<<"$derived_ex_now" || continue
      rxacked=0
      for rxack in ${EXPECT_DEMOTED[@]+"${EXPECT_DEMOTED[@]}"}; do
        [ "$rxack" = "$rxname" ] && rxacked=1 && break
      done
      if [ "$rxacked" -eq 1 ]; then
        note "  demoted (ACKNOWLEDGED) $rxname — this run EXCLUDES it, so its committed REQUIRED row is dropped"
        demoted_drop="$(jq --arg c "$rxname" '. + [$c]' <<<"$demoted_drop")"
        continue
      fi
      contra="$contra  CONTRADICTION  $rxname  [$(jq -r --arg c "$rxname" '.[] | select(.context == $c) | .reason' <<<"$exclusions_json" | head -1)]
"
    done <<EOF
$committed_required
EOF
    if [ -n "$contra" ]; then
      {
        echo "REQUIRED × EXCLUDED — this run derived an EXCLUSION for context(s) the COMMITTED spec REQUIRES."
        echo "Every line below is live branch protection today, and the reason in brackets is this run's"
        echo "own statement that the name must not gate a merge. Emitting both is a spec that contradicts"
        echo "itself, and no verifier reads .exclusions, so nothing downstream would ever say so:"
        printf '%s' "$contra"
        echo
        echo "Sampled shas: ${SHAS[*]}"
        echo "This is a CONTRADICTION, not an absence, so --expect-unrendered does not answer for it."
        echo "Either the workflow change that produced the exclusion is the mistake — revert it and the"
        echo "name goes back to being a real gate — or the derivation is right and the check must stop"
        echo "gating, which is a PROTECTION CHANGE and is acknowledged ONE NAME AT A TIME with"
        echo "  --expect-demoted '<name>'"
        echo "which DROPS the committed required row instead of carrying it. Dropping a required row"
        echo "narrows protection: run scripts/required-checks-apply.sh from the same sitting so the"
        echo "branch and the file do not disagree."
      } >&2
      exit 1
    fi
  fi

  local checks_json
  checks_json="$(printf '%s' "$final" | grep . | jq -R --argjson a "$ACTIONS_APP_ID" '{context: ., app_id: $a}' | jq -s '.')"

  # ── the emit: a MERGE onto the committed base, never an overwrite ───────────
  #
  # WHAT THE GENERATOR OWNS AND WHAT THE BASE CARRIES. The generator owns every
  # field it derives — `enforced`, `repo`, `branch`, `generated_from_shas`, the
  # whole `protection` block bar the check LIST, and `exclusions` — plus exactly
  # three `_readme` paragraphs: the GENERATED banner, the enforced/reversal
  # paragraph (whose text is conditioned on the SAME variable that sets the
  # `enforced` field, so the file cannot say "not applied yet" while claiming to
  # be applied), and the sampling rule's sha trailer, TEMPLATED from $shas rather
  # than left as the literal of whichever wave wrote it last. Everything else in
  # `_readme` — the floor, the exclusions census, the merge protocol — is prose a
  # human maintains, and the merge carries it through unchanged.
  #
  # The check list is a UNION on the context string, base first so a committed
  # app_id pin wins over a freshly derived one, then sorted by context so the
  # diff of a regeneration is a diff of DECISIONS and not of sampling order.
  local spec
  spec="$(jq -n \
    --arg repo "$REPO" \
    --arg branch "$BRANCH" \
    --arg enforced "$ENFORCED" \
    --argjson base "$base_json" \
    --argjson checks "$checks_json" \
    --argjson exclusions "$exclusions_json" \
    --argjson promoted_drop "$promoted_drop" \
    --argjson demoted_drop "$demoted_drop" \
    --argjson shas "$(printf '%s\n' "${SHAS[@]}" | jq -R . | jq -s '.')" \
    '
    ($enforced == "true") as $on
    | ($shas | map(.[0:9]) | join(" and ")) as $shortshas
    | ($base | if type == "object" then . else {} end) as $b
    | [
        { k: "GENERATED by scripts/required-checks-generate.sh",
          t: "GENERATED by scripts/required-checks-generate.sh from check runs actually observed on the sampled shas. Never hand-edit a context string: GitHub validates neither the name nor the app_id, and a typo deadlocks the branch forever (honest-gates D21). The emit is a MERGE onto this file, not an overwrite: a committed context the sample could not render survives, and one that should have rendered and did not is REFUSED by name before the merge can hide it." },
        { k: "enforced=",
          t: (if $on then
                "enforced=true means protection IS applied to this branch. From this commit an unreadable or absent protection config is a HARD failure in scripts/required-checks-verify.sh — it is no longer a committed pre-flip state. THE REVERSAL IS TWO COMMANDS, and the first one WRITES A RECORD BEFORE it touches the API: `bash scripts/required-checks-apply.sh --disable --confirm --reason \"…\" --task <id>`, which execs `scripts/breakglass.sh --open --total`, refuses without both a reason and a task, and appends a row to docs/ops/break-glass-log.md before the DELETE; then `bash scripts/breakglass.sh --close --reason \"…\" --task <id>` to put the full object back. RUN BOTH FROM A CHECKOUT CUT FROM origin/main AT THAT MOMENT. A stale checkout carries the pre-#8253 apply.sh whose --disable block ends in a bare `gh api -X DELETE`: it removes protection, writes NO record, and a verifier who ran this runbook’s own documented string from a 131-commit-behind checkout took main’s protection down for ~74 seconds leaving ZERO rows in the log (D136)."
              else
                "enforced=false means protection has NOT been applied yet; the CI guard still runs the deadlock detector against real heads, so it is never vacuous. The PR that flips this to true is the PR that runs `scripts/required-checks-apply.sh --confirm --acknowledge-growth`, in the SAME sitting as the merge — from the instant a wider spec lands on main, scripts/bp-merge.sh reads the committed spec and refuses heads GitHub would still merge."
              end) },
        { k: "Every protection field is enumerated",
          t: "Every protection field is enumerated INCLUDING the falses: the PUT does not converge omitted state (allow_force_pushes resets, required_linear_history and required_conversation_resolution do NOT). See honest-gates D41." },
        { k: "No workflow carries a merge_group",
          t: "No workflow carries a merge_group trigger and this repo is user-owned (no merge queue), so queue semantics are not a variable today. If the repo ever moves to an org and the merge queue is enabled, every required check would sit Pending-forever in the merge group on day one." },
        { k: "OPERATIONAL:",
          t: "OPERATIONAL: a required context whose LATEST run on the head concluded `cancelled` blocks the merge with a third refusal shape (`... is cancelled.`, honest-gates D38) and clears only on a re-run or a push. elixir.yml sets cancel-in-progress on PR refs, so a superseded head can leave one behind. That is a correct red, not a deadlock — but the merge protocol must expect it, because the message is neither `is failing.` nor `is expected.`" }
      ] as $owned
    | ($b._readme // [])
    | reduce $owned[] as $o (.;
        if (map(startswith($o.k)) | any)
        then map(if startswith($o.k) then $o.t else . end)
        else . + [$o.t] end)
    # the sha trailer is TEMPLATED, never a literal: a regeneration that forgets
    # to retype it is exactly how the file starts naming heads it did not sample.
    | (if (map(startswith("THE SAMPLING RULE")) | any)
       then map(if startswith("THE SAMPLING RULE")
                then sub("This file was generated from .*$"; "This file was generated from " + $shortshas + ".")
                else . end)
       else . + ["THE SAMPLING RULE: the set below is the INTERSECTION over the sampled heads, so the sample decides what may be required. This file was generated from " + $shortshas + "."]
       end) as $readme
    | {
        "_readme": $readme,
        enforced: $on,
        repo: $repo,
        branch: $branch,
        generated_from_shas: $shas,
        protection: {
          required_status_checks: {
            strict: false,
            # `$demoted_drop` holds exactly the names an operator typed
            # after --expect-demoted, each of which this run EXCLUDED, so
            # keeping the committed row would emit one context on both lists —
            # the mirror of what `$promoted_drop` does to `exclusions` below.
            checks: (((($b.protection.required_status_checks.checks) // [])
                      | map(select(.context as $c | $demoted_drop | index($c) | not)))
                     + $checks
                     | unique_by(.context) | sort_by(.context))
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
        # `exclusions` is a UNION on the context string too, and for the same
        # reason the check list is one: it is a ledger of DECISIONS, and a
        # sample that could not render a name must not be able to delete the
        # sentence explaining why that name is held out. Base FIRST so the
        # grouping is stable, but the LAST row in each group wins — i.e. the
        # DERIVED reason beats the committed one when this run restated it, so
        # the union carries rows without freezing their grounds. `group_by`
        # already sorts by context; `sort_by` is kept explicit so the diff of a
        # regeneration stays a diff of decisions and not of stage order.
        # `$promoted_drop` is never a filter the derivation computes on its own:
        # it holds exactly the names an operator typed after --expect-promoted,
        # each of which this run selected as REQUIRED, so keeping the row would
        # emit one context on both lists.
        exclusions: ((($b.exclusions // [] | map(select(.context as $c | $promoted_drop | index($c) | not)))
                      + $exclusions)
                     | group_by(.context) | map(.[-1]) | sort_by(.context))
      }')"

  local emitted
  emitted="$(jq '.protection.required_status_checks.checks | length' <<<"$spec")"
  if [ -n "$OUT" ]; then
    printf '%s\n' "$spec" > "$OUT"
    echo "wrote $OUT ($emitted required context(s); $(printf '%s' "$final" | grep -c . || true) from this sample, the rest carried by the merge)"
  else
    printf '%s\n' "$spec"
  fi
}

main "$@"
