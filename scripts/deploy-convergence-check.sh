#!/usr/bin/env bash
# deploy-convergence-check.sh — supersession is decided by COMMIT ANCESTRY, and
# the box must SERVE the newest deploy-relevant commit on main.
#
# ── THE DEFECT (task-0c3069135d1b4bfd, GitHub #4463) ─────────────────────────
#
# Measured 2026-07-19: commit 10bfdfb40 (feat(tenancy) profile-aware
# dataset-granular export, 5 api/ files, PR #4438) had its deploy CANCELLED as
# superseded at 18:56Z. The 19:01Z run succeeded on 93fd1e2d8, which does NOT
# contain 10bfdfb40 — `git merge-base --is-ancestor` says so. main carried the
# dialect, guerrilla did not, and the four later commits were docs/tooling that
# correctly failed the path filter, so NOTHING was queued to carry it. The
# ledger said success. Production served older code. Nothing went red.
#
# THE ORDERING THAT CREATED IT. GitHub resolves a concurrency group by WALL
# CLOCK: the run that arrived last wins and the other is cancelled. Wall clock
# and commit ancestry are DIFFERENT ORDERS. A run can start later and still
# carry the older commit — a re-run of an old workflow is the pure case, and a
# burst merge is the common one. So the surviving run is not necessarily the run
# that carries the newest code, and every downstream instrument that trusts
# "latest run" inherits that lie.
#
#   THE INVARIANT, and it is the whole file: the run that survives supersession
#   must be the one whose commit is a DESCENDANT of every superseded run's
#   commit — never the one that started last.
#
# ── WHAT THIS IS *NOT*: it is not task-7a85d1b5f471af8f ──────────────────────
#
# That row is crown-reconcile's TORN READ — a newer crown snapshot compared
# against an older run list, ~95s apart, which calls a healthy row WRONG. It is
# a false POSITIVE in an instrument: the run is fine, the row is fine, the
# COMPARISON is wrong.
#
# This row is the opposite sign. Here the deploy genuinely did not happen, every
# instrument agrees it did, and the report is GREEN. A false NEGATIVE in
# production state. Different mechanism (dispatch/supersession vs. sampling),
# different consequence (stale prod vs. a noisy alarm), different fix.
#
# They meet at exactly ONE point, and this file honours it rather than diverging:
# the torn-read row's general remedy is "sample both sides at ONE instant, or
# exclude anything whose deploy run is not terminal at the moment the list is
# taken". So `converged` takes its `--tip` from the caller as a SINGLE snapshot,
# and `--owed-before` excludes commits too new to have owed a terminated deploy.
# Without that this gate would red on every commit that merged while the deploy
# was in flight — i.e. it would BE the torn read, one axis over.
#
# ── MODES ────────────────────────────────────────────────────────────────────
#
#   survivor                         # stdin: "run_id sha started_at" lines
#       Which run must survive supersession, decided by ancestry. Prints the
#       wall-clock pick too, so a log SHOWS the divergence when there is one.
#
#   converged --served SHA --tip SHA [--owed-before ISO|--grace-seconds N]
#       The post-deploy assertion. `--served` is what the BOX SAYS IT SERVES —
#       never `github.sha`, which is only what triggered a run. Reds when a
#       deploy-relevant commit reachable from `--tip` is absent from `--served`.
#
#   adjudicate --stranded true|false [--unchecked true|false]
#              [--in-flight-source ok|unknown]
#              [--instance-result success|failure|cancelled|skipped]
#              [--instance-state converged|stranded|unchecked|absent]
#              [--instance-served SHA] [--instance-tip SHA]
#              [--strand-since ISO] [--strand-served SHA] [--strand-newest SHA]
#              [--now ISO] [--deploy-yml PATH]
#                                                # stdin: "run_id sha status" lines
#       Turns the per-leg findings into the JOB'S CONCLUSION. Exits 1 — the run
#       goes red — for "stranded and no deploy is in flight", and, since
#       task-c5955c660c7b9e55, for THIS run's own instance leg having concluded
#       FAILURE while the box is still behind (or unreadable) afterwards, and,
#       since task-a077f2e24350d3af, for a strand OLDER than twice the deploy
#       lock wait (STALLED) whatever is in flight. See the block above the mode
#       for why an in-flight deploy is a delay and not a waiver, why a failed
#       ATTEMPT is exempt from that delay, and why the delay now EXPIRES.
#
#   --selftest
#       Hermetic. Builds real git repos in mktemp, reproduces the 2026-07-19
#       shape, and proves the naive wall-clock rule gets it WRONG.
#
# ── EXIT CODES — a refusal is never a pass ───────────────────────────────────
#
#   0  converged / a survivor was decided
#   1  STRANDED / no survivor is safe by ancestry — a real finding
#   2  HARNESS-UNAVAILABLE — could not look (missing git, unresolvable sha,
#      unreadable deploy.yml). NEVER 0: "I could not check" is not "it is fine".
#   3  CANNOT READ (adjudicate only) — a strand is being suppressed as
#      in-flight but its AGE cannot be established: no/unparseable
#      --strand-since or --now, a strand start in the future, or the deploy
#      lock wait could not be read out of the deploy scripts. The suppression
#      needs an expiry to be honest, and an expiry it cannot compute is not
#      "age 0" — it fails CLOSED, by its own name.
#
# Relevance comes from deploy.yml's own `on.push.paths`, minus any entry marked
# `deploy-filter-exempt:` and minus any file matched by a `!`-prefixed EXCLUSION
# entry — the same list, read the same way, as
# scripts/check-deployyml-filters.sh. Authoring it twice is how the two drift.
# The exclusion half matters here or this gate manufactures outages: deploy.yml
# deliberately does not deploy an api/test-only merge (task-75f45c6baba2e633),
# and a relevance set that still counts it reports production STRANDED over a
# commit production was never meant to carry.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_YML_DEFAULT="$REPO_ROOT/.github/workflows/deploy.yml"

# The ONE job/step boundary, shared with scripts/check-deploy-smoke.sh and
# scripts/check-deployyml-filters.sh. This file carried the FIFTH hand-rolled
# copy of `/^  [a-zA-Z0-9_-]+:/` (in extract_target_ere), and that rule matches
# TEXT: a top-level block scalar with a 2-space body — `run-name: |` is valid
# YAML and GitHub accepts it — reads as the `changes` job, so a workflow could
# hand THIS gate its own relevance filter as a string literal. See the lib
# header, and selftest 13 below, which is that fixture.
# shellcheck source=scripts/lib/deploy-yaml-scope.sh
. "$REPO_ROOT/scripts/lib/deploy-yaml-scope.sh"

# Fallback window when the caller cannot name the instant the deploy pulled. A
# commit younger than this has not yet owed a TERMINATED deploy run, so counting
# it would manufacture the torn read described above. 900s is deliberately
# generous: this gate exists to catch a strand that persists, not to race.
DEFAULT_GRACE_SECONDS=900

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ── clocks, portably ───────────────────────────────────────────────
#
# `date -u -d` is GNU-only. The CI runner has GNU coreutils, a maintainer's
# laptop has BSD date, and this file's selftest must be able to run on both — a
# harness that only runs where CI runs is a harness nobody exercises before they
# push. Both directions try GNU first and fall back to BSD's `-j -f` / `-r`, and
# an unparseable input yields EMPTY so the caller refuses rather than inventing
# an epoch. NEVER `|| echo 0`: epoch 0 would place every commit before the
# cutoff and green a real strand.
iso_to_epoch() {
  local v
  v="$(date -u -d "$1" +%s 2>/dev/null || true)"
  [ -n "$v" ] || v="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true)"
  [ -n "$v" ] || v="$(date -u -j -f '%Y-%m-%dT%H:%M:%S%z' "$1" +%s 2>/dev/null || true)"
  printf '%s' "$v"
}

epoch_to_iso() {
  local v
  v="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  [ -n "$v" ] || v="$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  printf '%s' "$v"
}

# ── relevance: deploy.yml's own path filters ─────────────────────────────────

# The non-exempt `on.push.paths` globs, one per line. The same extraction as
# check-deployyml-filters.sh's extract_paths (including the three `on:` spellings
# YAML 1.1 makes equivalent), reduced to the REQUIRED column — an exempt path
# deploys nothing, so a merge touching only it can never strand anything.
extract_relevant_globs() {
  awk '
    /^("on"|\047on\047|on)[ \t]*:/ { in_on = 1; next }
    in_on && /^[A-Za-z"\047]/ { in_on = 0 }
    in_on && /^    paths:/    { in_paths = 1; exempt = 0; next }
    in_paths && /^    [a-z]/  { in_paths = 0 }
    in_paths && /^ *#/        { if ($0 ~ /deploy-filter-exempt:/) exempt = 1; next }
    in_paths && /^ *- / {
      line = $0
      sub(/^ *- */, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      if (line == "") next
      # A leading "!" is a GitHub path-filter EXCLUSION (task-75f45c6baba2e633).
      # It delivers nothing, so folding it into the POSITIVE union is at best
      # dead text — `!api/test/.*` matches no path git ever prints — and at
      # worst reads as a trigger. extract_exclusion_globs below is what reads it.
      if (substr(line, 1, 1) == "!") next
      if (!exempt) print line
      exempt = 0
    }
  ' "$1"
}

# The EXCLUSION globs — the `!`-prefixed on.push.paths entries with the `!`
# stripped, one per line (task-75f45c6baba2e633).
#
# WHY THIS GATE NEEDS THEM. Relevance here is "would a deploy carry this
# commit?". deploy.yml excludes api/test/** from BOTH its push filter and its
# `changes` classifier, so an api/test-only merge no longer deploys — by design,
# since a prod build compiles only api/lib (api/mix.exs elixirc_paths(_)). Read
# the positive filters alone and this gate calls such a commit relevant, finds it
# absent from the box, and files a STRANDED verdict against production for a
# commit production was never meant to carry: a FABRICATED outage, the exact
# failure the --target split exists to avoid one class of.
#
# Read out of on.push.paths rather than out of the classifier on purpose: a
# commit GitHub will not even start the workflow for cannot strand anything, and
# the push list is the one both deploy arms are held to by
# scripts/check-deployyml-filters.sh's exclusion arm.
extract_exclusion_globs() {
  awk '
    /^("on"|\047on\047|on)[ \t]*:/ { in_on = 1; next }
    in_on && /^[A-Za-z"\047]/ { in_on = 0 }
    in_on && /^    paths:/    { in_paths = 1; next }
    in_paths && /^    [a-z]/  { in_paths = 0 }
    in_paths && /^ *#/        { next }
    in_paths && /^ *- / {
      line = $0
      sub(/^ *- */, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      if (substr(line, 1, 1) != "!") next
      print substr(line, 2)
    }
  ' "$1"
}

# One anchored ERE matching every relevant glob, for `git diff --name-only`
# output. GitHub's `**` crosses directory separators and a lone `*` does not, so
# the two are translated differently — collapsing them would make
# `scripts/connectors/**` match `scripts/other/x` and turn a docs merge into a
# false strand.
globs_to_ere() {
  awk '
    {
      g = $0
      if (g == "") next
      gsub(/[.+^$(){}|\[\]\\]/, "\\\\&", g)
      gsub(/\*\*/, "\001", g)
      gsub(/\*/, "[^/]*", g)
      gsub(/\001/, ".*", g)
      out = (out == "" ? g : out "|" g)
    }
    END { if (out != "") printf "^(%s)$\n", out }
  '
}

# ONE TARGET'S OWN DISPATCH FILTER, read out of the `changes` job rather than
# copied. Relevance is NOT the same for both hosts: the control plane deploys on
# `^(cloud|deploy|internal|cmd)/` and the content instance on
# `^(api|internal|deploy|connectors|templates|scripts/connectors)/`. Judging the
# control plane against the UNION would red it for an api-only merge it is not
# supposed to carry — a false outage report on a box that is exactly right.
#
# Scoped to the `changes` job by the SHARED boundary
# check-deployyml-filters.sh's extract_regexes uses, and for the same reason: a
# `grep -qE` outside that job dispatches nothing, so it may not answer for a
# target. The line is keyed on the assignment it guards (`cp=true` /
# `instance=true`), so a renamed output breaks LOUDLY here instead of silently
# selecting the other host's filter.
#
# The boundary is a real YAML parse (deploy_yaml_job_lines), not the 2-space
# awk rule this function used to carry. That rule read the CONTENT of a
# top-level block scalar as job lines, so a `run-name: |` block indented two
# spaces could plant a wider `cp=true` filter that `awk NR==1` picked ahead of
# the real job's — the gate answering itself with a string. Selftest 13 is that
# exact fixture.
#
# THE TAIL IS awk NR==1 AND NOT head -1. head exits after the first line and
# SIGPIPEs sed; with set -o pipefail that dead writer becomes this pipeline's
# status, so the extractor reports failure on a filter it read perfectly well.
# awk reads to EOF and prints only the first line: same answer, no broken pipe.
extract_target_ere() {
  local yml="$1" target="$2"
  local job_lines rc=0
  job_lines="$(deploy_yaml_job_lines "$yml" changes)" || rc=$?
  # 2 (no python3/PyYAML) and 3 (unparseable) are REFUSALS, not an empty filter.
  # Returning nothing here lands in load_relevance's "extractor is broken" arm,
  # which exits 2 — never a green.
  [ "$rc" -eq 0 ] || return 0
  printf '%s\n' "$job_lines" \
    | { grep -F "${target}=true" || true; } \
    | { grep -oE "grep -qE '[^']+'" || true; } | sed -E "s/^grep -qE '//; s/'\$//" | awk 'NR==1'
}

RELEVANT_ERE=""
# Empty means "nothing is excluded", which is the pre-exclusion behaviour
# exactly. It is set from the SAME file as RELEVANT_ERE, in every mode, so no
# call site can end up with one and not the other.
EXCLUDED_ERE=""
load_relevance() {
  local yml="$1" target="${2:-}"
  if [ ! -f "$yml" ]; then
    warn "HARNESS-UNAVAILABLE: $yml is not a file — the relevant path set cannot be read."
    warn "This is NOT a verdict on production. A gate that cannot read its filter must not certify a box."
    return 2
  fi

  EXCLUDED_ERE="$(extract_exclusion_globs "$yml" | globs_to_ere)"

  if [ -n "$target" ]; then
    case "$target" in
      cp|instance) ;;
      *) warn "HARNESS-UNAVAILABLE: --target must be 'cp' or 'instance', not '$target'"; return 2 ;;
    esac
    RELEVANT_ERE="$(extract_target_ere "$yml" "$target")"
    if [ -z "$RELEVANT_ERE" ]; then
      warn "HARNESS-UNAVAILABLE: no 'grep -qE' filter guarding ${target}=true inside the 'changes' job of $yml."
      warn "The extractor is broken, or the job stopped writing that variable. An empty relevance set would"
      warn "certify EVERY box as converged, for free — so this refuses instead of passing."
      return 2
    fi
    return 0
  fi

  RELEVANT_ERE="$(extract_relevant_globs "$yml" | globs_to_ere)"
  if [ -z "$RELEVANT_ERE" ]; then
    warn "HARNESS-UNAVAILABLE: no non-exempt on.push.paths entries found in $yml — the extractor is broken,"
    warn "not the workflow. An empty relevance set would certify EVERY box as converged, for free."
    return 2
  fi
  return 0
}

# Does this commit touch anything a deploy would carry? A merge/squash commit is
# diffed against its FIRST parent, which is the same range GitHub's own path
# filter evaluates. A root commit has no parent, so it is listed wholesale rather
# than skipped — skipping it would make an initial-commit repo trivially green.
commit_is_relevant() {
  local sha="$1" files
  if git -C "$GIT_DIR_ARG" rev-parse --verify --quiet "${sha}^1^{commit}" >/dev/null 2>&1; then
    files="$(git -C "$GIT_DIR_ARG" diff --name-only "${sha}^1" "$sha")" || return 2
  else
    files="$(git -C "$GIT_DIR_ARG" show --pretty=format: --name-only "$sha")" || return 2
  fi
  # A HERESTRING, NEVER A PIPE. `grep -q` exits the instant it matches, and with
  # `set -o pipefail` the writer's SIGPIPE (141) becomes the pipeline's status —
  # so a commit that IS relevant answers 141, and the caller below reads any
  # non-zero-non-2 as "not relevant". That is a stranded commit silently
  # classed as nothing-to-deploy: a FALSE GREEN, in the one gate whose entire
  # purpose is to stop a silent green over stale production. Measured on this
  # machine at load average 119-161, where the identical construct in the
  # selftest failed 10 runs out of 10 with the matching text present all along.
  # `<<<` has no writer process, so there is no pipe to break.
  #
  # THE EXCLUDED FILES ARE DROPPED FIRST (task-75f45c6baba2e633), not tested
  # afterwards: the question is whether ANY file in the commit would make a
  # deploy carry it, so an excluded file must not be able to answer yes on its
  # own — while a commit that touches api/lib AND api/test stays relevant,
  # because the api/lib path survives the drop. `|| true` because grep -v exits
  # 1 when it drops every line, which is precisely the test-only case.
  if [ -n "$EXCLUDED_ERE" ]; then
    files="$(grep -vE "$EXCLUDED_ERE" <<<"$files" || true)"
  fi
  grep -qE "$RELEVANT_ERE" <<<"$files"
}

# ── git helpers ──────────────────────────────────────────────────────────────

GIT_DIR_ARG="."

resolve() {
  local raw="$1" label="$2" full
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if [ -z "$raw" ]; then
    warn "HARNESS-UNAVAILABLE: $label is empty — nothing to compare."
    return 2
  fi
  case "$raw" in
    *[!0-9a-fA-F]*)
      warn "HARNESS-UNAVAILABLE: $label is '$raw', which is not a hex sha."
      return 2
      ;;
  esac
  full="$(git -C "$GIT_DIR_ARG" rev-parse --verify --quiet "${raw}^{commit}" || true)"
  if [ -z "$full" ]; then
    warn "HARNESS-UNAVAILABLE: $label '$raw' is not a commit in this clone."
    warn "A shallow checkout is the usual cause — this gate needs fetch-depth: 0."
    return 2
  fi
  printf '%s' "$full"
}

# `merge-base --is-ancestor` answers a THREE-way question with an rc: 0 yes,
# 1 no, anything else broken. The third case is read explicitly — folding it
# into "no" would turn a gc'd object into a confident outage report.
is_ancestor() {
  local rc=0
  git -C "$GIT_DIR_ARG" merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# ── mode: survivor ───────────────────────────────────────────────────────────
#
# Input lines: "<run_id> <sha> <started_at>". started_at is carried only so the
# report can NAME the wall-clock pick it is refusing to trust.
mode_survivor() {
  local ids=() shas=() starts=()
  local id sha start full

  while read -r id sha start _rest; do
    [ -n "${id:-}" ] || continue
    case "$id" in \#*) continue ;; esac
    full="$(resolve "$sha" "run $id's sha")" || return 2
    ids+=("$id"); shas+=("$full"); starts+=("${start:-<unknown>}")
  done

  local n="${#ids[@]}"
  if [ "$n" -eq 0 ]; then
    warn "HARNESS-UNAVAILABLE: no candidate runs on stdin."
    return 2
  fi

  say "CANDIDATES ($n):"
  local i
  for ((i = 0; i < n; i++)); do
    say "  run ${ids[$i]}  sha ${shas[$i]}  started ${starts[$i]}"
  done

  # The wall-clock pick, computed ONLY so the divergence can be printed. It is
  # never the answer; it is the bug.
  local wall_i=0
  for ((i = 1; i < n; i++)); do
    if [[ "${starts[$i]}" > "${starts[$wall_i]}" ]]; then wall_i=$i; fi
  done

  # The ancestry pick: the one candidate every other candidate is an ancestor of.
  local anc_i=-1 j ok rc
  for ((i = 0; i < n; i++)); do
    ok=1
    for ((j = 0; j < n; j++)); do
      [ "$i" -ne "$j" ] || continue
      [ "${shas[$i]}" != "${shas[$j]}" ] || continue
      rc=0; is_ancestor "${shas[$j]}" "${shas[$i]}" || rc=$?
      if [ "$rc" -eq 2 ]; then
        warn "HARNESS-UNAVAILABLE: git could not relate ${shas[$j]} to ${shas[$i]}."
        return 2
      fi
      if [ "$rc" -ne 0 ]; then ok=0; break; fi
    done
    if [ "$ok" -eq 1 ]; then anc_i=$i; break; fi
  done

  if [ "$anc_i" -lt 0 ]; then
    say ""
    say "NO SAFE SURVIVOR: the candidates are not totally ordered by ancestry — they DIVERGED."
    say "Cancelling any of them drops commits the survivor does not contain. Deploy them in"
    say "ancestry order, or deploy a commit that merges them; do NOT let wall clock choose."
    say "The wall-clock pick would have been run ${ids[$wall_i]} (sha ${shas[$wall_i]})."
    return 1
  fi

  say ""
  say "SURVIVOR (by ancestry): run ${ids[$anc_i]}  sha ${shas[$anc_i]}"
  if [ "$anc_i" -ne "$wall_i" ]; then
    say "DIVERGENCE: the wall-clock rule would have kept run ${ids[$wall_i]} (sha ${shas[$wall_i]}),"
    say "which does NOT contain ${shas[$anc_i]}. That is task-0c3069135d1b4bfd's exact shape:"
    say "superseding by start time strands the newest commit while the ledger reports success."
  else
    say "The wall-clock rule agrees here. It is not relied on: agreement is a coincidence of this"
    say "input, not a property of the ordering."
  fi
  printf '%s %s\n' "${ids[$anc_i]}" "${shas[$anc_i]}"
  return 0
}

# ── mode: converged ──────────────────────────────────────────────────────────
mode_converged() {
  local served_raw="" tip_raw="" owed_before="" grace="$DEFAULT_GRACE_SECONDS"
  local yml="$DEPLOY_YML_DEFAULT" label="production" target="" emit_strand=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --served)         served_raw="${2:-}"; shift 2 ;;
      --tip)            tip_raw="${2:-}"; shift 2 ;;
      --owed-before)    owed_before="${2:-}"; shift 2 ;;
      --grace-seconds)  grace="${2:-}"; shift 2 ;;
      --deploy-yml)     yml="${2:-}"; shift 2 ;;
      --repo)           GIT_DIR_ARG="${2:-}"; shift 2 ;;
      --label)          label="${2:-}"; shift 2 ;;
      --target)         target="${2:-}"; shift 2 ;;
      --emit-strand)    emit_strand="${2:-}"; shift 2 ;;
      *) warn "HARNESS-UNAVAILABLE: unknown argument '$1'"; return 2 ;;
    esac
  done

  load_relevance "$yml" "$target" || return 2

  local served tip
  served="$(resolve "$served_raw" "--served (what the box says it serves)")" || return 2
  tip="$(resolve "$tip_raw" "--tip (the main snapshot)")" || return 2

  # The cutoff, in epoch seconds. A named instant is EXACT and is preferred: the
  # moment the deploy pulled. The grace window is the fallback and says so.
  local cutoff basis
  if [ -n "$owed_before" ]; then
    cutoff="$(iso_to_epoch "$owed_before")"
    if [ -z "$cutoff" ]; then
      warn "HARNESS-UNAVAILABLE: --owed-before '$owed_before' is not a date this system can parse."
      return 2
    fi
    basis="--owed-before $owed_before (the instant the deploy pulled)"
  else
    case "$grace" in
      ''|*[!0-9]*) warn "HARNESS-UNAVAILABLE: --grace-seconds '$grace' is not a non-negative integer"; return 2 ;;
    esac
    cutoff=$(( $(date -u +%s) - grace ))
    basis="now - ${grace}s (fallback: the caller named no pull instant)"
  fi

  say "TARGET:  $label"
  say "SERVED:  $served   (the box's own answer — never github.sha)"
  say "TIP:     $tip   (one snapshot of main, taken once by the caller)"
  say "OWED:    a relevant commit counts only if it predates $basis"
  if [ -n "$target" ]; then
    say "FILTER:  ${target}'s OWN dispatch regex, read from the changes job: $RELEVANT_ERE"
  else
    say "FILTER:  the union of every non-exempt on.push.paths glob"
  fi

  if [ "$served" = "$tip" ]; then
    say ""
    say "CONVERGED: the box serves the tip exactly."
    return 0
  fi

  local rc=0
  is_ancestor "$tip" "$served" || rc=$?
  if [ "$rc" -eq 2 ]; then
    warn "HARNESS-UNAVAILABLE: git could not relate $tip to $served."
    return 2
  fi
  if [ "$rc" -eq 0 ]; then
    say ""
    say "CONVERGED: the box serves a descendant of the tip (it pulled after the snapshot)."
    return 0
  fi

  # Everything on the tip that the box does not have. Newest first.
  local missing
  missing="$(git -C "$GIT_DIR_ARG" rev-list "${served}..${tip}")" || {
    warn "HARNESS-UNAVAILABLE: rev-list ${served}..${tip} failed."
    return 2
  }

  local stranded="" newest="" pending=0 irrelevant=0 gap=0 sha ct relrc
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    gap=$((gap + 1))
    relrc=0; commit_is_relevant "$sha" || relrc=$?
    # 0 = relevant, 1 = not. ANYTHING ELSE is the tool failing, not an answer,
    # and it must refuse rather than resolve to "not relevant" — the direction
    # that would hide the strand. `-gt 1` and not `-eq 2` for exactly that
    # reason: a signal death arrives as 128+n, never as 2.
    if [ "$relrc" -gt 1 ]; then
      warn "HARNESS-UNAVAILABLE: git could not diff $sha against its parent."
      return 2
    fi
    if [ "$relrc" -ne 0 ]; then
      irrelevant=$((irrelevant + 1))
      continue
    fi
    # rev-list is newest-first, so the FIRST relevant commit seen is the newest
    # deploy-relevant commit on the tip — owed or not. It is what the STALLED
    # red names as "what the box should be serving".
    [ -n "$newest" ] || newest="$sha"
    ct="$(git -C "$GIT_DIR_ARG" show -s --format=%ct "$sha")" || {
      warn "HARNESS-UNAVAILABLE: git could not read $sha's committer date."
      return 2
    }
    if [ "$ct" -ge "$cutoff" ]; then
      pending=$((pending + 1))
      continue
    fi
    # rev-list is newest-first, so the LAST one seen is the OLDEST stranded
    # commit — the one that has been missing longest, and the one to name.
    stranded="$sha"
  done <<RANGE_EOF
$missing
RANGE_EOF

  say ""
  say "GAP:     $gap commit(s) on the tip are absent from the box"
  say "         $irrelevant deploy-irrelevant (docs/tooling — correctly carried by nothing)"
  say "         $pending too new to be owed yet (their own deploy may still be in flight)"

  if [ -z "$stranded" ]; then
    say ""
    say "CONVERGED: every commit the box is missing is either deploy-irrelevant or not yet owed."
    return 0
  fi

  # THE STRAND START (task-a077f2e24350d3af). The box has been behind since
  # the OLDEST deploy-relevant commit it lacks reached main: before that
  # instant the served commit WAS the newest deploy-relevant one. A merge or
  # squash on main carries the merge instant as its committer date, so %ct of
  # that commit is when the strand began. adjudicate turns it into STRAND AGE,
  # which is what lets in-flight suppression expire (see the block above that
  # mode). Normalised to UTC Z so every reader parses the same shape and a
  # plain sort orders two legs chronologically.
  local strand_ct strand_since
  strand_ct="$(git -C "$GIT_DIR_ARG" show -s --format=%ct "$stranded")" || {
    warn "HARNESS-UNAVAILABLE: git could not read $stranded's committer date."
    return 2
  }
  strand_since="$(epoch_to_iso "$strand_ct")"
  if [ -z "$strand_since" ]; then
    warn "HARNESS-UNAVAILABLE: could not render $stranded's committer date ($strand_ct) as ISO."
    return 2
  fi
  if [ -n "$emit_strand" ]; then
    # One line: strand_since served newest_relevant oldest_missing. The caller
    # (deploy.yml's check step) hands the oldest line across legs to adjudicate.
    printf '%s %s %s %s\n' "$strand_since" "$served" "${newest:-$stranded}" "$stranded" > "$emit_strand" || {
      warn "HARNESS-UNAVAILABLE: could not write the strand record to $emit_strand."
      return 2
    }
  fi

  say ""
  say "STRANDED: $label serves $served, which does NOT contain $stranded —"
  say "          $(git -C "$GIT_DIR_ARG" show -s --format='%h %s' "$stranded")"
  say "          merged $(git -C "$GIT_DIR_ARG" show -s --format=%cI "$stranded"), a deploy-relevant change that reached main and never reached the box."
  say "STRAND-SINCE: $strand_since   (the box has been behind the newest deploy-relevant commit since then)"
  say "NEWEST-RELEVANT: ${newest:-$stranded}"
  say ""
  say "This is the silent shape: every run is green, the ledger reports success, and production"
  say "serves older code. It does not self-heal — a docs-only tail after the strand triggers"
  say "nothing, so the gap persists until an UNRELATED code merge happens to drag it along."
  say ""
  say "REPAIR: re-run deploy.yml against main's tip with the workflow_dispatch this gate ships"
  say "beside — 'Deploy (production)' -> Run workflow -> targets: both. It is the authenticated"
  say "replay path, and it needs no unrelated merge to carry it."
  return 1
}

# ── the deploy lock wait, READ from the deploy scripts ─────────────────────
#
# task-a077f2e24350d3af. The in-flight suppression expires at TWICE the time a
# queued deploy may wait for the box's deploy lock. That wait is not a constant
# of this file: it is whatever the deploy scripts that deploy.yml ships to the
# boxes (its `$SCP deploy/<x>-deploy.sh` lines) pass to queue_for_deploy_lock —
# a literal (`queue_for_deploy_lock 1800`) or a variable whose default is a
# literal (`queue_budget="${BARKPARK_DEPLOY_LOCK_QUEUE_SECS:-1800}"`). That
# helper is the heartbeat-stepped replacement for one long `flock -w <budget>`
# with the same total (see either script), so the budget IS the flock -w value.
#
# The LONGEST wait across the named scripts wins: a queued run on either box
# may legitimately sit that long. Anything unreadable — no script named, a
# script missing, no call site, a call site whose budget resolves to no integer
# — prints nothing and returns 3. NEVER a fallback number: a guessed threshold
# is a guessed verdict.
#
# Prints "<secs> <script>:<secs>[,<script>:<secs>…]".
lock_wait_secs() {
  local yml="$1" root scripts script body calls call arg var val max="" src=""
  if [ ! -f "$yml" ]; then
    warn "CANNOT READ: $yml is not a file, so the deploy scripts it ships cannot be named."
    return 3
  fi
  root="$(cd "$(dirname "$yml")/../.." 2>/dev/null && pwd)" || root=""
  if [ -z "$root" ]; then
    warn "CANNOT READ: could not resolve the repo root above $yml."
    return 3
  fi
  scripts="$(grep -vE '^[[:space:]]*#' "$yml" | grep -oE '\$SCP[[:space:]]+deploy/[A-Za-z0-9_.-]+-deploy\.sh' | sed -E 's/^\$SCP[[:space:]]+//' | sort -u || true)"
  if [ -z "$scripts" ]; then
    warn "CANNOT READ: $yml ships no deploy/<x>-deploy.sh via \$SCP — the lock wait has no source."
    return 3
  fi
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    if [ ! -f "$root/$script" ]; then
      warn "CANNOT READ: $yml ships $script, which is not a file under $root."
      return 3
    fi
    body="$(grep -vE '^[[:space:]]*#' "$root/$script" || true)"
    calls="$(grep -oE 'queue_for_deploy_lock[[:space:]]+("?\$[A-Za-z_][A-Za-z0-9_]*"?|[0-9]+)' <<<"$body" || true)"
    if [ -z "$calls" ]; then
      warn "CANNOT READ: no queue_for_deploy_lock call site in $script — the lock wait is not readable."
      return 3
    fi
    while IFS= read -r call; do
      [ -n "$call" ] || continue
      arg="$(sed -E 's/^queue_for_deploy_lock[[:space:]]+//; s/"//g' <<<"$call")"
      case "$arg" in
        \$*)
          var="${arg#\$}"
          val="$(grep -oE "^[[:space:]]*${var}=\"?(\\\$\\{[A-Za-z_][A-Za-z0-9_]*:-)?[0-9]+" <<<"$body" \
                 | grep -oE '[0-9]+$' | awk 'NR==1' || true)"
          ;;
        *) val="$arg" ;;
      esac
      case "$val" in
        ''|*[!0-9]*)
          warn "CANNOT READ: $script calls '$call' and its budget does not resolve to an integer."
          return 3 ;;
      esac
      src="${src:+$src,}$script:$val"
      if [ -z "$max" ] || [ "$val" -gt "$max" ]; then max="$val"; fi
    done <<<"$calls"
  done <<<"$scripts"
  if [ -z "$max" ] || [ "$max" -le 0 ]; then
    warn "CANNOT READ: the lock wait read as '${max}' — not a positive number of seconds."
    return 3
  fi
  printf '%s %s\n' "$max" "$src"
}

# ── mode: adjudicate ─────────────────────────────────────────────────────────
#
# THE BOUNDARY THIS FILE EXISTS TO DRAW (task-103b5cc5ec4a8ccd).
#
# `converged` answers one leg: does THIS box serve what it is owed. It cannot
# answer the question the JOB has to answer, which is whether the run should
# CONCLUDE non-zero — because a red that fires on every ordinary in-flight
# deploy is waived inside a day, and a tripwire that is waived has stopped
# discriminating. So the verdict is decided here, once, from two facts:
#
#   STRANDED      at least one leg came back rc=1 from `converged`.
#   IN FLIGHT     another deploy.yml run on main is queued or in_progress
#                 right now — one that has not yet had its chance to move the
#                 box. Read on stdin as "run_id sha status" lines, the same
#                 shape `survivor` takes, so it is testable with no network.
#
# THE RULE, and it is the whole mode:
#
#   not stranded                    -> 0   converged
#   stranded AND a deploy in flight -> 0   NOT-CONVERGED-YET. Suppressed.
#   stranded AND nothing in flight  -> 1   the run must go red.
#
# WHY SUPPRESSION IS NOT A WAIVER, which is the part that matters. Suppression
# silences THIS run's exit code and NOTHING ELSE: the caller still emits
# converged=false, so report-convergence-failure still files (or appends to) the
# convergence issue on the very same run. A strand is therefore never silent —
# it is loud on every run, and RED as soon as no deploy is left running to
# explain it. An ordinary in-flight deploy can delay the red; it can never
# cancel it, because the next run re-asks with that deploy finished.
#
# WHY "ANY IN-FLIGHT RUN" AND NOT A CLEVERER TEST. A descendancy test on the
# in-flight run's sha does not discriminate — a docs-only run after a strand
# also carries a descendant of the served sha and also deploys nothing — so it
# would buy precision it cannot actually deliver while adding a way to be wrong.
# The honest reading is coarse and stated: something is running, so the picture
# is still moving, so do not conclude from it yet.
#
# AN UNREADABLE RUN LIST IS TREATED AS IN FLIGHT, deliberately and out loud.
# "I could not look" must not manufacture an outage report any more than it may
# green one: the issue still files (converged=false is the caller's), only the
# exit code is withheld. That is the same law as this file's rc=2.
#
# ── THE SUPPRESSION EXPIRES ON STRAND AGE (task-a077f2e24350d3af) ──────────
#
# What the middle row let through. "A deploy in flight" was satisfied by ANY
# queued sibling, and a queue behind a held box lock is never empty: deploy.yml
# gives every push its own concurrency group, each queued run waits up to the
# lock budget and then exits 15, and every merge adds a fresh queued run. On
# 2026-09-22 fifteen of sixteen deploy.yml runs with a FAILED instance job
# (07:27Z-11:58Z) concluded this check SUCCESS. #19859 reds a run whose OWN
# instance leg failed; a run whose instance leg was skipped, cancelled or
# succeeded while the box sat stranded still read NOT CONVERGED YET, exit 0,
# for as long as the queue lasted.
#
# A PER-RUN expiry cannot fix that: the in-flight set is ALWAYS young, because
# the oldest queued run gives up after one lock budget and a newer one replaces
# it. What grows without bound in a stall is the STRAND: how long the box has
# served a commit behind the newest deploy-relevant main commit. `converged`
# measures it from the committer (= merge) date of the oldest deploy-relevant
# commit the box lacks, and the caller passes it here as --strand-since.
#
# THE BOUND is 2 x the deploy lock wait READ from the deploy scripts
# (lock_wait_secs above; 1800 s today, so 60 min). One budget is the longest a
# legitimately queued deploy waits for the lock; the second covers the deploy
# ahead of it plus its own. A strand older than that is not explained by any
# deploy in flight — something is stuck — so the row reads:
#
#   stranded AND a deploy in flight AND strand age <= bound -> 0 GREEN-BECAUSE-WAITING
#   stranded AND a deploy in flight AND strand age >  bound -> 1 STALLED
#   stranded AND suppression needed AND age unknowable      -> 3 CANNOT READ
#
# The same bound applies to the withheld-conclusion arm (in-flight lookup
# failed): a strand older than any deploy could take is stalled whether or not
# the run list could be read.
#
# THE COST, stated because this is a boundary and not a bug fix. A deploy
# chain that is genuinely slow — one budget of queueing plus a long build
# ahead — reds STALLED past the bound even though it would have landed. That
# is intended: a box more than an hour behind main is what this check exists
# to say, and the red is a delay-bounded one, not the every-merge red that got
# the original middle row designed.
mode_adjudicate() {
  local stranded="" label="production" source="ok" unchecked="false"
  local inst_result="" inst_state="absent" inst_served="" inst_tip=""
  local strand_since="" strand_served="" strand_newest="" now_iso=""
  local yml="$DEPLOY_YML_DEFAULT"

  while [ $# -gt 0 ]; do
    case "$1" in
      --stranded)         stranded="${2:-}"; shift 2 ;;
      --unchecked)        unchecked="${2:-}"; shift 2 ;;
      --in-flight-source) source="${2:-}"; shift 2 ;;
      --label)            label="${2:-}"; shift 2 ;;
      --instance-result)  inst_result="${2:-}"; shift 2 ;;
      --instance-state)   inst_state="${2:-}"; shift 2 ;;
      --instance-served)  inst_served="${2:-}"; shift 2 ;;
      --instance-tip)     inst_tip="${2:-}"; shift 2 ;;
      --strand-since)     strand_since="${2:-}"; shift 2 ;;
      --strand-served)    strand_served="${2:-}"; shift 2 ;;
      --strand-newest)    strand_newest="${2:-}"; shift 2 ;;
      --now)              now_iso="${2:-}"; shift 2 ;;
      --deploy-yml)       yml="${2:-}"; shift 2 ;;
      *) warn "HARNESS-UNAVAILABLE: unknown argument '$1'"; return 2 ;;
    esac
  done

  case "$stranded" in
    true|false) : ;;
    *) warn "HARNESS-UNAVAILABLE: --stranded must be exactly 'true' or 'false' (got '$stranded')"
       warn "A missing verdict is not 'false' — that default is how a gate greens on its own breakage."
       return 2 ;;
  esac
  case "$unchecked" in true|false) : ;; *)
    warn "HARNESS-UNAVAILABLE: --unchecked must be 'true' or 'false' (got '$unchecked')"; return 2 ;;
  esac
  case "$source" in ok|unknown) : ;; *)
    warn "HARNESS-UNAVAILABLE: --in-flight-source must be 'ok' or 'unknown' (got '$source')"; return 2 ;;
  esac
  # An unrecognised leg result is a HARNESS fault, never "probably fine". The
  # empty string is the ONLY permitted silence and it means "the caller did not
  # wire this leg" — every wired caller passes one of the four Actions results.
  case "$inst_result" in ''|success|failure|cancelled|skipped) : ;; *)
    warn "HARNESS-UNAVAILABLE: --instance-result must be one of success|failure|cancelled|skipped (got '$inst_result')"
    return 2 ;;
  esac
  case "$inst_state" in converged|stranded|unchecked|absent) : ;; *)
    warn "HARNESS-UNAVAILABLE: --instance-state must be one of converged|stranded|unchecked|absent (got '$inst_state')"
    return 2 ;;
  esac

  # stdin is optional and routinely empty — that is the "nothing is coming"
  # case, and it must read as zero rows rather than as a hang. The caller always
  # redirects (`< file` or `</dev/null`); a bare terminal invocation gets the
  # same treatment because `read` on a closed stdin simply ends the loop.
  local flight=0 line rid rsha rstatus
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    # shellcheck disable=SC2086
    set -- $line
    rid="${1:-?}"; rsha="${2:-?}"; rstatus="${3:-?}"
    case "$rstatus" in
      queued|in_progress|waiting|requested|pending)
        flight=$((flight + 1))
        say "IN FLIGHT: run $rid on $rsha is $rstatus — a deploy that has not had its turn yet"
        ;;
      *)
        say "not in flight: run $rid on $rsha is '$rstatus' — a terminal run explains nothing"
        ;;
    esac
  done

  say ""
  say "ADJUDICATION for $label"
  say "  stranded:          $stranded"
  say "  unchecked legs:    $unchecked"
  say "  deploys in flight: $flight"
  say "  instance leg:      result=${inst_result:-<not wired>} state=${inst_state}"

  # ── THIS RUN'S OWN INSTANCE LEG: TRIED AND DID NOT MOVE ────────────────────
  #
  # task-c5955c660c7b9e55. Everything below this block answers "is the PICTURE
  # still moving". That question is the right one for a box that is merely
  # behind, and it is the WRONG one for the shape that produced three
  # consecutive vacuous greens on 2026-09-22 (runs 35722816309 / 35720835901 /
  # 35718876385): the `instance` JOB concluded FAILURE, the box kept serving
  # e02e4296d, and this job concluded SUCCESS every time — because sibling
  # deploy runs were queued, and the in-flight suppression below has no expiry.
  # During that window 11 of 12 runs timed out at exit 15, so each failing run
  # was suppressed by the presence of its equally-failing siblings. A check
  # whose NAME promises production is current was green for hours while
  # production was frozen.
  #
  # THE PREDICATE, and it is the whole of this row. Two cases have to be told
  # apart, and only one of them is a defect:
  #
  #   TRIED AND DID NOT MOVE   `instance` concluded FAILURE on THIS run and the
  #                            box is still behind. The deploy was attempted,
  #                            against this box, and it did not land. No sibling
  #                            run explains that: another run being queued says
  #                            nothing about whether THIS run's own attempt
  #                            worked. -> RED, naming both shas.
  #
  #   NEVER GOING TO MOVE IT   `instance` was SKIPPED (the path filter found
  #                            nothing deploy-relevant for this host), CANCELLED
  #                            (superseded), or SUCCEEDED (it did its job — a
  #                            box still behind after that is the ordinary
  #                            already-covered / in-flight picture). None of
  #                            these is an attempt that failed, so none of them
  #                            reds here and the existing rules decide.
  #
  # So the discriminator is the instance leg's OWN conclusion on THIS run, not
  # a comparison of the served sha against the run's head. A superseded,
  # already-covered or no-op run never reaches this block.
  #
  # WHY IT REDS RATHER THAN SKIPS, which the row names as the other wrong fix.
  # Making the job `needs: instance` and skipping otherwise trades a false green
  # for a silent one: a SKIPPED liveness check reads as "not applicable" and
  # vanishes from the one surface meant to tell an operator production is stale.
  # So when the leg failed and the box could not be READ at all, that is CANNOT
  # READ and it reds by that name — an unreadable box after a failed deploy is
  # the least safe moment to assume anything.
  if [ "$inst_result" = "failure" ]; then
    case "$inst_state" in
      stranded)
        say ""
        say "VERDICT: THE INSTANCE JOB TRIED AND THE SHA DID NOT MOVE. The \`instance\` leg of THIS"
        say "run concluded FAILURE, and the content instance is still behind afterwards."
        say "  served (content instance): ${inst_served:-<unread>}"
        say "  main snapshot (owed):      ${inst_tip:-<unread>}"
        say "No other run explains this: a sibling deploy being queued says nothing about whether"
        say "THIS run's own attempt landed. In-flight suppression does NOT apply to a failed attempt."
        say ""
        say "REPAIR: Actions -> Deploy (production) -> Run workflow, against main, targets: both."
        return 1
        ;;
      unchecked|absent)
        say ""
        say "VERDICT: CANNOT READ. The \`instance\` leg of THIS run concluded FAILURE and the content"
        say "instance did not say what it serves (state=${inst_state}), so whether the sha moved is"
        say "UNKNOWN at the exact moment it is least safe to assume it did."
        say "  served (content instance): ${inst_served:-<unread>}"
        say "  main snapshot (owed):      ${inst_tip:-<unread>}"
        say "This FAILS rather than skipping: a skipped liveness check reads as 'not applicable' and"
        say "disappears from the one surface meant to tell an operator that production is stale."
        return 1
        ;;
      converged)
        say ""
        say "The instance leg FAILED but the box is converged anyway — something else carried the"
        say "commit. Not this row's defect; the ordinary rules below decide."
        ;;
    esac
  fi

  if [ "$stranded" != "true" ]; then
    if [ "$unchecked" = "true" ]; then
      say ""
      say "NOT STRANDED, but at least one leg was UNCHECKED. UNCHECKED is an absence of"
      say "evidence and is reported as one — it is not a finding, so it does not red here."
    fi
    say ""
    say "VERDICT: CONVERGED — no leg reported a strand. Exit 0."
    say "GREEN-BECAUSE-SHIPPED: every box serves what main owes it."
    return 0
  fi

  # ── SUPPRESSION NEEDS AN EXPIRY: establish the strand age ────────────────
  # Only when a suppression arm is about to withhold the red. Every refusal
  # below is CANNOT READ, exit 3 — never "age 0", which is the vacuous green.
  local lw lock_secs="" lock_src="" bound bound_mins="" now_ep since_ep age mins="" lrc=0
  if [ "$source" = "unknown" ] || [ "$flight" -gt 0 ]; then
    lw="$(lock_wait_secs "$yml")" || lrc=$?
    if [ "$lrc" -ne 0 ] || [ -z "$lw" ]; then
      say ""
      say "VERDICT: CANNOT READ — the deploy lock wait could not be read from the deploy scripts"
      say "deploy.yml ships, so the in-flight suppression has no expiry to measure against."
      say "An unbounded suppression is the vacuous green this arm exists to end; refusing instead."
      return 3
    fi
    lock_secs="${lw%% *}"; lock_src="${lw#* }"
    bound=$(( 2 * lock_secs ))
    bound_mins=$(( bound / 60 ))
    # SHAPE FIRST, then parse. GNU `date -d` reads "yesterday" or "now" as a
    # date, which would turn a garbled input into a plausible age; only a
    # literal ISO-8601 instant is an instant.
    local iso_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:?[0-9]{2})$'
    now_ep=""; since_ep=""
    if [ -z "$now_iso" ]; then now_ep="$(date -u +%s)"
    elif [[ "$now_iso" =~ $iso_re ]]; then now_ep="$(iso_to_epoch "$now_iso")"; fi
    if [[ "$strand_since" =~ $iso_re ]]; then since_ep="$(iso_to_epoch "$strand_since")"; fi
    case "$now_ep" in ''|*[!0-9]*) now_ep="" ;; esac
    case "$since_ep" in ''|*[!0-9]*) since_ep="" ;; esac
    if [ -z "$now_ep" ] || [ -z "$since_ep" ] || [ "$since_ep" -gt "$now_ep" ]; then
      say ""
      say "VERDICT: CANNOT READ — the box is STRANDED and a suppression arm would withhold the red,"
      say "but the strand age is unknowable (--strand-since '${strand_since:-<none>}', --now '${now_iso:-<clock>}')."
      say "  served:                  ${strand_served:-<unread>}"
      say "  newest deploy-relevant:  ${strand_newest:-<unread>}"
      say "A missing or future strand start is not age 0. Failing closed."
      return 3
    fi
    age=$(( now_ep - since_ep ))
    mins=$(( age / 60 ))
    if [ "$age" -gt "$bound" ]; then
      say ""
      # The lookup-fails arm names itself on the headline (main ruling
      # 2026-09-23T19:21Z), so a reader tells it from the queued-sibling case.
      [ "$source" = "unknown" ] && say "STALLED: in-flight lookup failed, stranded ${mins} min"
      say "VERDICT: STALLED — production has served ${strand_served:-<unread>} for ${mins} min behind the"
      say "newest deploy-relevant main commit ${strand_newest:-<unread>} (strand began ${strand_since})."
      say "  served:                  ${strand_served:-<unread>}"
      say "  newest deploy-relevant:  ${strand_newest:-<unread>}"
      say "  strand age:              ${mins} min"
      say "  bound:                   ${bound_mins} min = 2 x the ${lock_secs}s deploy lock wait (${lock_src})"
      if [ "$source" = "unknown" ]; then
        say "  in-flight lookup:        FAILED — irrelevant past the bound"
      else
        say "  deploys in flight:       ${flight} — none of them explains a strand this old"
      fi
      say "No legitimately queued deploy waits longer than one lock budget, and none takes a second"
      say "one to land. A queue behind a held lock renews itself every merge; the strand does not."
      say ""
      say "REPAIR: find who holds the box's deploy lock (the instance leg logs the holder), then"
      say "Actions -> Deploy (production) -> Run workflow, against main, targets: both."
      return 1
    fi
  fi

  if [ "$source" = "unknown" ]; then
    say ""
    say "VERDICT: STRANDED, and the in-flight lookup itself failed — the exit code is WITHHELD."
    say "The finding is not: the caller still reports converged=false and the convergence issue"
    say "still files on this run. Only the conclusion waits for a run that could actually look."
    say "GREEN-BECAUSE-WAITING: stranded ${mins} min of a ${bound_mins} min bound (2 x ${lock_secs}s lock wait)."
    say "  served ${strand_served:-<unread>}, newest deploy-relevant ${strand_newest:-<unread>}, since ${strand_since}"
    return 0
  fi

  if [ "$flight" -gt 0 ]; then
    say ""
    say "VERDICT: NOT CONVERGED **YET** — ${flight} deploy run(s) are still queued or running,"
    say "and any of them resets the box to origin/main's tip. This is the ordinary in-flight"
    say "case and it stays GREEN, which is what keeps this gate from being waived."
    say "It is NOT silent: converged=false is still emitted, so the convergence issue files on"
    say "this run, and the next run re-asks with those deploys finished. A delay, never a pass."
    say "GREEN-BECAUSE-WAITING: stranded ${mins} min of a ${bound_mins} min bound (2 x ${lock_secs}s lock wait)."
    say "  served ${strand_served:-<unread>}, newest deploy-relevant ${strand_newest:-<unread>}, since ${strand_since}"
    say "  Past the bound this reds STALLED; this is NOT production serving the newest commit."
    return 0
  fi

  say ""
  say "VERDICT: STRANDED AND NOTHING IS COMING. No deploy run is queued or in progress, so"
  say "no further work exists that would carry the missing commit — a docs-only tail triggers"
  say "nothing at all. This run CONCLUDES NON-ZERO, by name, which is the entire point of"
  say "task-103b5cc5ec4a8ccd: an instrument that cannot fail cannot inform."
  say ""
  say "REPAIR: Actions -> Deploy (production) -> Run workflow, against main, targets: both."
  return 1
}

# ── selftest ─────────────────────────────────────────────────────────────────

# A real git repo, plus a real deploy.yml-shaped filter file. No network, no gh,
# no box. `git -c` supplies identity so a runner with no configured user commits.
st_git() { local r="$1"; shift; git -C "$r" -c user.email=t@example.com -c user.name=t "$@"; }

st_commit() {
  local repo="$1" path="$2" msg="$3"
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$msg" >> "$repo/$path"
  st_git "$repo" add -A
  st_git "$repo" commit -q -m "$msg"
  st_git "$repo" rev-parse HEAD
}

# NEVER `printf … | grep -q` IN HERE. `grep -q` exits on its first match and
# closes the pipe; under this file's `set -o pipefail` the writer's SIGPIPE (141)
# becomes the pipeline's status, so a SUCCESSFUL match reads as a failed
# assertion. It is a race on how much the writer had left to write, so it passes
# on an idle machine and fails on a loaded one — measured here at load average
# 119, where 10/10 selftest runs reported 4-7 false failures whose expected text
# was present in the captured output all along. Use `[[ $out == *"needle"* ]]`:
# a builtin, no pipe, no second process, no race.
selftest() {
  local rc=0 tmp
  tmp="$(mktemp -d)"

  # The filter fixture, shaped exactly like the real on.push.paths block so the
  # extractor is exercised, INCLUDING the exempt marker.
  mkdir -p "$tmp/wf"
  cat > "$tmp/wf/deploy.yml" <<'YML'
name: Deploy (production)
on:
  push:
    branches: [main]
    paths:
      - "api/**"
      - "cloud/**"
      # deploy-filter-exempt: editing this workflow deploys nothing by itself
      - ".github/workflows/deploy.yml"
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: |
          if echo "$changed" | grep -qE '^(cloud)/'; then cp=true; else cp=false; fi
          if echo "$changed" | grep -qE '^(api)/'; then instance=true; else instance=false; fi
  decoy:
    runs-on: ubuntu-latest
    steps:
      - run: |
          if echo "$changed" | grep -qE '^(api|cloud|docs)/'; then cp=true; instance=true; fi
YML

  local repo="$tmp/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  local A B C D E out naive
  A="$(st_commit "$repo" api/a.ex 'A: an api change')"
  B="$(st_commit "$repo" api/b.ex 'B: the newest api change (10bfdfb40 stand-in)')"
  C="$(st_commit "$repo" docs/c.md 'C: docs only')"
  D="$(st_commit "$repo" docs/d.md 'D: docs only')"

  # One instant just past every fixture commit: from here, all of them are owed.
  local OWED_ALL
  OWED_ALL="$(epoch_to_iso "$(( $(st_git "$repo" show -s --format=%ct "$D") + 1 ))")"

  # ── 1. THE RED-FIRST SPEC: the later-STARTED run carries the OLDER commit ──
  echo "selftest 1/15: supersession must keep the DESCENDANT, not the run that started last"
  set +e
  out="$(printf '%s\n' "31000001 $B 2026-07-19T18:56:00Z" "31000002 $A 2026-07-19T19:01:00Z" \
        | "$0" survivor --repo "$repo" 2>&1)"
  set -e
  if [[ "$out" == *"SURVIVOR (by ancestry): run 31000001"* ]]; then
    echo "  ok: kept run 31000001 (sha $B), the DESCENDANT"
  else
    echo "SELFTEST FAIL: ancestry did not pick the descendant" >&2; echo "$out" >&2; rc=1
  fi
  if [[ "$out" == *"DIVERGENCE: the wall-clock rule would have kept run 31000002"* ]]; then
    echo "  ok: and it NAMED the wall-clock rule's wrong answer (run 31000002, the older commit)"
  else
    echo "SELFTEST FAIL: the divergence was not reported — the bug would be invisible in the log" >&2; rc=1
  fi

  # The naive rule, run here so the spec shows it LOSING rather than asserting it does.
  echo "selftest 2/15: the naive wall-clock rule gets this WRONG — that is the defect"
  naive="$(printf '%s\n' "31000001 $B 2026-07-19T18:56:00Z" "31000002 $A 2026-07-19T19:01:00Z" \
          | sort -k3 | tail -1 | awk '{print $1}')"
  if [ "$naive" = "31000002" ]; then
    echo "  ok: latest-start picks 31000002, whose sha $A does not contain $B"
  else
    echo "SELFTEST FAIL: the naive picker did not reproduce the defect ($naive)" >&2; rc=1
  fi

  # ── 3. THE INCIDENT, as a convergence verdict ─────────────────────────────
  echo "selftest 3/15: box on the OLDER commit while main carries a newer api change must be STRANDED"
  local c3=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$A" --tip "$B" --owed-before "$OWED_ALL" 2>&1)"; c3=$?
  set -e
  if [ "$c3" -eq 1 ] && [[ "$out" == *$'\n'"STRANDED:"* ]]; then
    echo "  ok: exit 1, and it names $B"
  else
    echo "SELFTEST FAIL: the incident shape did not red (rc=$c3)" >&2; echo "$out" >&2; rc=1
  fi

  echo "selftest 4/15: the same box, once it serves the newer commit, is CONVERGED"
  local c4=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$B" --tip "$B" --owed-before "$OWED_ALL" 2>&1)"; c4=$?
  set -e
  if [ "$c4" -eq 0 ]; then echo "  ok: exit 0"
  else echo "SELFTEST FAIL: a current box read as stranded (rc=$c4)" >&2; echo "$out" >&2; rc=1; fi

  # ── 5. The docs-only tail: the row's own "4 later commits are docs/tooling" ─
  echo "selftest 5/15: a docs-only tail past the box must NOT red (it deploys nothing)"
  local c5=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$B" --tip "$D" --owed-before "$OWED_ALL" 2>&1)"; c5=$?
  set -e
  if [ "$c5" -eq 0 ] && [[ "$out" == *"2 deploy-irrelevant"* ]]; then
    echo "  ok: exit 0, both docs commits classed irrelevant ($C, $D)"
  else
    echo "SELFTEST FAIL: a docs tail produced a false strand (rc=$c5)" >&2; echo "$out" >&2; rc=1
  fi

  # ── 6/7. The torn-read guard, and the NEGATIVE ARM that it did not blind ──
  echo "selftest 6/15: a relevant commit too NEW to be owed must not red (the torn-read guard)"
  local c6=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$A" --tip "$B" --grace-seconds 86400 2>&1)"; c6=$?
  set -e
  if [ "$c6" -eq 0 ] && [[ "$out" == *"1 too new to be owed yet"* ]]; then
    echo "  ok: exit 0 while B is inside the grace window — its own deploy may still be in flight"
  else
    echo "SELFTEST FAIL: the guard did not hold a too-new commit (rc=$c6)" >&2; echo "$out" >&2; rc=1
  fi

  echo "selftest 7/15: NEGATIVE ARM — the guard must not blind the instrument"
  # Same repo, same pair, cutoff moved past B's commit date: it is owed again.
  local c7=0 owed_at bct
  bct="$(st_git "$repo" show -s --format=%ct "$B")"
  owed_at="$(epoch_to_iso "$((bct + 1))")"
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$A" --tip "$B" --owed-before "$owed_at" 2>&1)"; c7=$?
  set -e
  if [ "$c7" -eq 1 ] && [[ "$out" == *$'\n'"STRANDED:"* ]]; then
    echo "  ok: a genuinely owed strand still reds — the grace traded no false positive for a false negative"
  else
    echo "SELFTEST FAIL: the owed cutoff swallowed a real strand (rc=$c7)" >&2; echo "$out" >&2; rc=1
  fi

  # ── 8. Diverged candidates have no safe survivor ──────────────────────────
  echo "selftest 8/15: diverged candidates must REFUSE, never silently pick one"
  local c8=0
  st_git "$repo" checkout -q -b side "$A"
  E="$(st_commit "$repo" api/e.ex 'E: a divergent api change')"
  st_git "$repo" checkout -q main
  set +e
  out="$(printf '%s\n' "31000003 $B 2026-07-19T18:56:00Z" "31000004 $E 2026-07-19T19:01:00Z" \
        | "$0" survivor --repo "$repo" 2>&1)"; c8=$?
  set -e
  if [ "$c8" -eq 1 ] && [[ "$out" == *$'\n'"NO SAFE SURVIVOR:"* ]]; then
    echo "  ok: exit 1 with a named refusal"
  else
    echo "SELFTEST FAIL: a diverged set was silently resolved (rc=$c8)" >&2; echo "$out" >&2; rc=1
  fi

  # ── 9. Cannot-look is never a pass ────────────────────────────────────────
  echo "selftest 9/15: an unresolvable sha and an unreadable filter must exit 2, never 0"
  local c9a=0 c9b=0
  set +e
  "$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served deadbeefdeadbeef --tip "$B" --owed-before "$OWED_ALL" >/dev/null 2>&1; c9a=$?
  "$0" converged --repo "$repo" --deploy-yml "$tmp/wf/absent.yml" --served "$A" --tip "$B" >/dev/null 2>&1; c9b=$?
  set -e
  if [ "$c9a" -eq 2 ] && [ "$c9b" -eq 2 ]; then
    echo "  ok: both refusals exit 2 (unresolvable sha, missing deploy.yml)"
  else
    echo "SELFTEST FAIL: a refusal did not exit 2 (sha=$c9a yml=$c9b)" >&2; rc=1
  fi

  # ── 10. per-target relevance: an api commit is the instance's debt, not cp's ─
  echo "selftest 10/15: an api-only commit must strand the INSTANCE and NOT the control plane"
  local c10a=0 c10b=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --target instance \
         --served "$A" --tip "$B" --owed-before "$OWED_ALL" 2>&1)"; c10a=$?
  set -e
  if [ "$c10a" -eq 1 ] && [[ "$out" == *$'\n'"STRANDED:"* ]]; then
    echo "  ok: instance reds (api/ is in its filter)"
  else
    echo "SELFTEST FAIL: the instance did not red on an api commit (rc=$c10a)" >&2; echo "$out" >&2; rc=1
  fi
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --target cp \
         --served "$A" --tip "$B" --owed-before "$OWED_ALL" 2>&1)"; c10b=$?
  set -e
  if [ "$c10b" -eq 0 ]; then
    echo "  ok: cp stays green (api/ is not in its filter — judging it against the union would be a false outage)"
  else
    echo "SELFTEST FAIL: cp red on a commit it does not deploy (rc=$c10b)" >&2; echo "$out" >&2; rc=1
  fi

  # ── 11. the filter must come from the `changes` job and nowhere else ───────
  echo "selftest 11/15: a decoy job's identical grep must not answer for a target"
  # The fixture's `decoy` job carries a filter matching api/, cloud/ AND docs/.
  # If the extractor were unscoped it would harvest that one, and the docs tail
  # of case 5 would start reading as a strand. Prove cp's filter is cloud-only.
  local cpre
  cpre="$(extract_target_ere "$tmp/wf/deploy.yml" cp)"
  if [ "$cpre" = '^(cloud)/' ]; then
    echo "  ok: cp's filter is '$cpre' — the decoy job's wider regex was not harvested"
  else
    echo "SELFTEST FAIL: cp's filter read as '$cpre' — the extractor left the changes job" >&2; rc=1
  fi
  local c11=0
  set +e
  "$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --target bogus \
      --served "$A" --tip "$B" --owed-before "$OWED_ALL" >/dev/null 2>&1; c11=$?
  set -e
  if [ "$c11" -eq 2 ]; then
    echo "  ok: an unknown --target exits 2, never 0"
  else
    echo "SELFTEST FAIL: an unknown --target did not refuse (rc=$c11)" >&2; rc=1
  fi

  # ── 12. A BROKEN RELEVANCE TEST MUST REFUSE, NOT CALL EVERYTHING IRRELEVANT ─
  echo "selftest 12/15: an unusable filter must REFUSE, never resolve to nothing-to-deploy"
  # The direction matters more than the case. commit_is_relevant answers 0 for
  # relevant and 1 for not; ANY other status is the tool failing, and the caller
  # now treats >1 as a refusal rather than as "not relevant". Before that it read
  # `-eq 2`, so a grep that died on a signal (128+n, never 2) landed in the
  # not-relevant arm — a stranded commit classed as nothing-to-deploy, which is
  # a FALSE GREEN in the one gate built to stop exactly that. An unparseable ERE
  # is the reachable way to make grep exit non-0-non-1 on demand.
  mkdir -p "$tmp/badwf"
  sed 's#grep -qE .\^(api)/.#grep -qE '"'"'^(api['"'"'#' "$tmp/wf/deploy.yml" > "$tmp/badwf/deploy.yml"
  local c12=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/badwf/deploy.yml" --target instance \
         --served "$A" --tip "$B" --owed-before "$OWED_ALL" 2>&1)"; c12=$?
  set -e
  if [ "$c12" -eq 2 ]; then
    echo "  ok: exit 2 (refused) on an unusable filter — never 0"
  elif [ "$c12" -eq 0 ]; then
    echo "SELFTEST FAIL: an unusable filter read CONVERGED — the false-green arm is back" >&2
    echo "$out" >&2; rc=1
  else
    # A red is not the designed answer here, but it is not a false green either.
    echo "  ok: exit $c12 — not a pass, which is the property under test"
  fi

  # ── 13. A TOP-LEVEL BLOCK SCALAR MUST NOT ANSWER FOR THE `changes` JOB ─────
  echo "selftest 13/15: a 2-space block-scalar body must not be read as the changes job"
  # THE DEFEAT THIS CLOSES. extract_target_ere used to scan for
  # `/^  [a-zA-Z0-9_-]+:/` — a TEXT rule. `run-name: |` is a top-level block
  # scalar GitHub accepts, and its body is indented two spaces, so every line of
  # it looks like a job key or a job's contents. Planted BEFORE the real `jobs:`
  # mapping, a fake `changes:` in that string hands the extractor a WIDER
  # `cp=true` filter, and `awk NR==1` takes it ahead of the real one. The gate
  # then judges the control plane against a relevance set the workflow wrote for
  # it — a false green on demand, in the gate whose whole job is false greens.
  # The file is valid YAML and executes nothing, so no parse check rejects it.
  mkdir -p "$tmp/scalarwf"
  cat > "$tmp/scalarwf/deploy.yml" <<'YML'
name: Deploy (production)
run-name: |
  changes:
    steps:
      - run: |
          if echo "$changed" | grep -qE '^(api|cloud|docs|anything)/'; then cp=true; else cp=false; fi
on:
  push:
    branches: [main]
    paths:
      - "api/**"
      - "cloud/**"
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: |
          if echo "$changed" | grep -qE '^(cloud)/'; then cp=true; else cp=false; fi
          if echo "$changed" | grep -qE '^(api)/'; then instance=true; else instance=false; fi
YML
  local scalar_re
  scalar_re="$(extract_target_ere "$tmp/scalarwf/deploy.yml" cp)"
  if [ "$scalar_re" = '^(cloud)/' ]; then
    echo "  ok: cp's filter is '$scalar_re' — read from the real job, not the string literal"
  else
    echo "SELFTEST FAIL: cp's filter read as '$scalar_re' — the block scalar answered for the job" >&2
    echo "  (the awk boundary is back; expected '^(cloud)/')" >&2
    rc=1
  fi
  # The fixture must really be the defeat, not merely a file that happens to
  # read right: the RETIRED awk rule must genuinely be fooled by it. Without
  # this the row could go vacuous the day the fixture stops planting anything.
  local naive_re
  naive_re="$(awk -v want="cp=true" '
    /^  [a-zA-Z0-9_-]+:/ { job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job) }
    job == "changes" && index($0, want) > 0
  ' "$tmp/scalarwf/deploy.yml" | { grep -oE "grep -qE '"'[^'"'"']+'"'" || true; } \
    | sed -E "s/^grep -qE '//; s/'\$//" | awk 'NR==1')"
  if [ "$naive_re" = '^(api|cloud|docs|anything)/' ]; then
    echo "  ok: and the retired 2-space awk rule IS fooled by it ('$naive_re') — the fixture is not vacuous"
  else
    echo "SELFTEST FAIL: the fixture no longer defeats the old awk rule (it read '$naive_re')" >&2
    echo "  A row that cannot fail before the fix proves nothing about the fix." >&2
    rc=1
  fi

  # ── 14. the api/test exclusion: relevance must SUBTRACT it ────────────────
  echo "selftest 14/15: an api/test-only commit must NOT strand, while api/lib still does"
  # Two filter files differing ONLY in the `- "!api/test/**"` line, and the same
  # commits run through both. The no-exclusion copy is the CONTROL: without it a
  # green here could mean the commits never reached the comparison at all.
  sed 's#      - "api/\*\*"#      - "api/**"\n      - "!api/test/**"#' \
    "$tmp/wf/deploy.yml" > "$tmp/wf/deploy-excl.yml"
  if cmp -s "$tmp/wf/deploy.yml" "$tmp/wf/deploy-excl.yml"; then
    echo "SELFTEST FAIL: the exclusion fixture is byte-identical to the base — the injection missed" >&2; rc=1
  fi
  local E14 F14 G14 OWED14 c14=0
  E14="$(st_commit "$repo" api/test/e_test.exs 'E: a test-only api change')"
  F14="$(st_commit "$repo" api/lib/f.ex 'F: a real api change')"
  G14="$(st_commit "$repo" api/lib/g.ex 'G: a real api change riding with a test')"
  st_commit "$repo" api/test/g_test.exs 'G2: the test that rides with G' >/dev/null
  G14="$(st_git "$repo" rev-parse HEAD)"
  OWED14="$(epoch_to_iso "$(( $(st_git "$repo" show -s --format=%ct "$G14") + 1 ))")"

  # NEGATIVE: served D, tip E — the only commit between them touches api/test.
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy-excl.yml" --target instance \
         --served "$D" --tip "$E14" --owed-before "$OWED14" 2>&1)"; c14=$?
  set -e
  if [ "$c14" -eq 0 ]; then
    echo "  ok: an api/test-only commit is not relevant — no fabricated strand"
  else
    echo "SELFTEST FAIL: an api/test-only commit still red (rc=$c14) — the exclusion is not subtracted" >&2
    echo "$out" >&2; rc=1
  fi

  # THE CONTROL, and it is what makes the line above mean anything: the SAME
  # commits against the SAME filters minus the exclusion must RED.
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --target instance \
         --served "$D" --tip "$E14" --owed-before "$OWED14" 2>&1)"; c14=$?
  set -e
  if [ "$c14" -eq 1 ] && [[ "$out" == *$'\n'"STRANDED:"* ]]; then
    echo "  ok: CONTROL — without the exclusion line the same commit reds, so the fixture reached the comparison"
  else
    echo "SELFTEST FAIL: the control did not red (rc=$c14) — the negative case above proves nothing" >&2
    echo "$out" >&2; rc=1
  fi

  # POSITIVE: an api/lib commit must still strand WITH the exclusion in place.
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy-excl.yml" --target instance \
         --served "$E14" --tip "$F14" --owed-before "$OWED14" 2>&1)"; c14=$?
  set -e
  if [ "$c14" -eq 1 ] && [[ "$out" == *$'\n'"STRANDED:"* ]]; then
    echo "  ok: an api/lib commit still reds with the exclusion in place"
  else
    echo "SELFTEST FAIL: an api/lib commit did not red (rc=$c14) — the exclusion swallowed the parent tree" >&2
    echo "$out" >&2; rc=1
  fi

  # MIXED: a commit touching api/lib AND api/test must stay relevant. The
  # exclusion drops FILES, never whole commits.
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy-excl.yml" --target instance \
         --served "$F14" --tip "$G14" --owed-before "$OWED14" 2>&1)"; c14=$?
  set -e
  if [ "$c14" -eq 1 ] && [[ "$out" == *$'\n'"STRANDED:"* ]]; then
    echo "  ok: api/lib + api/test together still reds — the drop is per FILE, not per commit"
  else
    echo "SELFTEST FAIL: a mixed commit did not red (rc=$c14) — a real change riding with a test would strand" >&2
    echo "$out" >&2; rc=1
  fi

  # ── 15. the strand record: the age input adjudicate expires suppression on ─
  echo "selftest 15/15: a STRANDED leg writes when the strand began, what it serves, and what is newest"
  # task-a077f2e24350d3af. Served A, tip G14 (case 14's last commit): the
  # relevant commits A lacks run from B (oldest) to G14 (newest), with the docs
  # commits C, D between them. So the strand began at B's committer date, G14
  # is the newest relevant commit, and B is the oldest missing — three
  # DIFFERENT answers, so a record that swapped any two fields cannot pass.
  local c15=0 rec15 want15 b15ct
  b15ct="$(st_git "$repo" show -s --format=%ct "$B")"
  want15="$(epoch_to_iso "$b15ct") $A $G14 $B"
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$A" --tip "$G14" \
         --owed-before "$OWED14" --emit-strand "$tmp/strand.rec" 2>&1)"; c15=$?
  set -e
  rec15="$(cat "$tmp/strand.rec" 2>/dev/null || true)"
  if [ "$c15" -eq 1 ] && [ "$rec15" = "$want15" ] && [[ "$out" == *"STRAND-SINCE: $(epoch_to_iso "$b15ct")"* ]]; then
    echo "  ok: '$rec15'"
  else
    echo "SELFTEST FAIL: strand record '$rec15' (rc=$c15), wanted '$want15'" >&2; echo "$out" >&2; rc=1
  fi
  # And a CONVERGED leg writes nothing — an empty record is "no strand here".
  : > "$tmp/strand2.rec"
  set +e
  "$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$B" --tip "$D" \
       --owed-before "$OWED_ALL" --emit-strand "$tmp/strand2.rec" >/dev/null 2>&1; c15=$?
  set -e
  if [ "$c15" -eq 0 ] && [ ! -s "$tmp/strand2.rec" ]; then
    echo "  ok: a converged leg leaves the record empty"
  else
    echo "SELFTEST FAIL: a converged leg wrote a strand record (rc=$c15): $(cat "$tmp/strand2.rec")" >&2; rc=1
  fi

  rm -rf "$tmp"
  echo
  if [ "$rc" -eq 0 ]; then
    echo "SELFTEST OK — ancestry beats wall clock, a real strand reds, and neither the docs tail"
    echo "nor the torn-read guard can green a strand that is genuinely owed."
  fi
  return "$rc"
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  local mode="${1:-}"
  case "$mode" in
    --selftest) selftest ;;
    survivor)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo) GIT_DIR_ARG="${2:-}"; shift 2 ;;
          *) warn "HARNESS-UNAVAILABLE: unknown argument '$1'"; return 2 ;;
        esac
      done
      mode_survivor
      ;;
    converged) shift; mode_converged "$@" ;;
    adjudicate) shift; mode_adjudicate "$@" ;;
    filters)
      # PRINT WHAT THE SCRIPT DERIVES, and refuse when it derives nothing. The
      # relevance sets are read out of deploy.yml rather than copied, which is
      # right (two lists that must agree and nothing making them is the defect
      # class this file guards) and also SILENT when it breaks: an empty filter
      # would certify every box as converged for free. CI calls this so a rename
      # inside the `changes` job reds on the PR that does it.
      shift
      local fyml="${1:-$DEPLOY_YML_DEFAULT}" t re frc=0
      say "on.push.paths union: $(extract_relevant_globs "$fyml" | globs_to_ere)"
      # Printed even when empty, with the word EXCLUSIONS either way: a line that
      # disappears when the set is empty is indistinguishable from a line the
      # extractor failed to produce.
      say "on.push.paths exclusions: $(extract_exclusion_globs "$fyml" | globs_to_ere)"
      # The stall bound's input (task-a077f2e24350d3af), read the same way
      # adjudicate reads it, so a rename in a deploy script reds HERE, on the PR
      # that does it, instead of as CANNOT READ in the middle of a strand.
      local lwv lwrc=0
      lwv="$(lock_wait_secs "$fyml")" || lwrc=$?
      if [ "$lwrc" -ne 0 ] || [ -z "$lwv" ]; then
        warn "CANNOT READ: the deploy lock wait is not readable from the scripts $fyml ships"
        frc=2
      else
        say "deploy lock wait: ${lwv%% *}s (${lwv#* }) — stall bound $(( 2 * ${lwv%% *} ))s"
      fi
      for t in cp instance; do
        re="$(extract_target_ere "$fyml" "$t")"
        if [ -z "$re" ]; then
          warn "HARNESS-UNAVAILABLE: no 'grep -qE' filter guarding ${t}=true inside the 'changes' job of $fyml"
          frc=2
        else
          say "target $t: $re"
        fi
      done
      return "$frc"
      ;;
    ""|-h|--help)
      say "usage: deploy-convergence-check.sh survivor            # stdin: 'run_id sha started_at'"
      say "       deploy-convergence-check.sh converged --served SHA --tip SHA [--target cp|instance]"
      say "                                             [--owed-before ISO|--grace-seconds N] [--label L]"
      say "       deploy-convergence-check.sh adjudicate --stranded true|false [--unchecked true|false]"
      say "                                             [--instance-result success|failure|cancelled|skipped]"
      say "                                             [--instance-state converged|stranded|unchecked|absent]"
      say "                                             [--instance-served SHA] [--instance-tip SHA]"
      say "                                             [--strand-since ISO] [--strand-served SHA] [--strand-newest SHA]"
      say "                                             [--now ISO] [--deploy-yml PATH]"
      say "                                             [--in-flight-source ok|unknown]   # stdin: 'run_id sha status'"
      say "       deploy-convergence-check.sh filters [DEPLOY_YML]   # what it derives, and refuse if nothing"
      say "       deploy-convergence-check.sh --selftest"
      return 2
      ;;
    *) warn "HARNESS-UNAVAILABLE: unknown mode '$mode'"; return 2 ;;
  esac
}

main "$@"
