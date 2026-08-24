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
#
# Relevance comes from deploy.yml's own `on.push.paths`, minus any entry marked
# `deploy-filter-exempt:` — the same list, read the same way, as
# scripts/check-deployyml-filters.sh. Authoring it twice is how the two drift.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_YML_DEFAULT="$REPO_ROOT/.github/workflows/deploy.yml"

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
      if (!exempt) print line
      exempt = 0
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
# Scoped to the `changes` job by the same 2-space job-boundary technique
# check-deployyml-filters.sh's extract_regexes uses, and for the same reason: a
# `grep -qE` outside that job dispatches nothing, so it may not answer for a
# target. The line is keyed on the assignment it guards (`cp=true` /
# `instance=true`), so a renamed output breaks LOUDLY here instead of silently
# selecting the other host's filter.
#
# THE TAIL IS awk NR==1 AND NOT head -1. head exits after the first line and
# SIGPIPEs sed; with set -o pipefail that dead writer becomes this pipeline's
# status, so the extractor reports failure on a filter it read perfectly well.
# awk reads to EOF and prints only the first line: same answer, no broken pipe.
extract_target_ere() {
  local yml="$1" target="$2"
  awk -v want="${target}=true" '
    /^  [a-zA-Z0-9_-]+:/ { job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job) }
    job == "changes" && index($0, want) > 0
  ' "$yml" | { grep -oE "grep -qE '[^']+'" || true; } | sed -E "s/^grep -qE '//; s/'\$//" | awk 'NR==1'
}

RELEVANT_ERE=""
load_relevance() {
  local yml="$1" target="${2:-}"
  if [ ! -f "$yml" ]; then
    warn "HARNESS-UNAVAILABLE: $yml is not a file — the relevant path set cannot be read."
    warn "This is NOT a verdict on production. A gate that cannot read its filter must not certify a box."
    return 2
  fi

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
  local yml="$DEPLOY_YML_DEFAULT" label="production" target=""

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

  local stranded="" pending=0 irrelevant=0 gap=0 sha ct relrc
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

  say ""
  say "STRANDED: $label serves $served, which does NOT contain $stranded —"
  say "          $(git -C "$GIT_DIR_ARG" show -s --format='%h %s' "$stranded")"
  say "          merged $(git -C "$GIT_DIR_ARG" show -s --format=%cI "$stranded"), a deploy-relevant change that reached main and never reached the box."
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
  echo "selftest 1/12: supersession must keep the DESCENDANT, not the run that started last"
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
  echo "selftest 2/12: the naive wall-clock rule gets this WRONG — that is the defect"
  naive="$(printf '%s\n' "31000001 $B 2026-07-19T18:56:00Z" "31000002 $A 2026-07-19T19:01:00Z" \
          | sort -k3 | tail -1 | awk '{print $1}')"
  if [ "$naive" = "31000002" ]; then
    echo "  ok: latest-start picks 31000002, whose sha $A does not contain $B"
  else
    echo "SELFTEST FAIL: the naive picker did not reproduce the defect ($naive)" >&2; rc=1
  fi

  # ── 3. THE INCIDENT, as a convergence verdict ─────────────────────────────
  echo "selftest 3/12: box on the OLDER commit while main carries a newer api change must be STRANDED"
  local c3=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$A" --tip "$B" --owed-before "$OWED_ALL" 2>&1)"; c3=$?
  set -e
  if [ "$c3" -eq 1 ] && [[ "$out" == *$'\n'"STRANDED:"* ]]; then
    echo "  ok: exit 1, and it names $B"
  else
    echo "SELFTEST FAIL: the incident shape did not red (rc=$c3)" >&2; echo "$out" >&2; rc=1
  fi

  echo "selftest 4/12: the same box, once it serves the newer commit, is CONVERGED"
  local c4=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$B" --tip "$B" --owed-before "$OWED_ALL" 2>&1)"; c4=$?
  set -e
  if [ "$c4" -eq 0 ]; then echo "  ok: exit 0"
  else echo "SELFTEST FAIL: a current box read as stranded (rc=$c4)" >&2; echo "$out" >&2; rc=1; fi

  # ── 5. The docs-only tail: the row's own "4 later commits are docs/tooling" ─
  echo "selftest 5/12: a docs-only tail past the box must NOT red (it deploys nothing)"
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
  echo "selftest 6/12: a relevant commit too NEW to be owed must not red (the torn-read guard)"
  local c6=0
  set +e
  out="$("$0" converged --repo "$repo" --deploy-yml "$tmp/wf/deploy.yml" --served "$A" --tip "$B" --grace-seconds 86400 2>&1)"; c6=$?
  set -e
  if [ "$c6" -eq 0 ] && [[ "$out" == *"1 too new to be owed yet"* ]]; then
    echo "  ok: exit 0 while B is inside the grace window — its own deploy may still be in flight"
  else
    echo "SELFTEST FAIL: the guard did not hold a too-new commit (rc=$c6)" >&2; echo "$out" >&2; rc=1
  fi

  echo "selftest 7/12: NEGATIVE ARM — the guard must not blind the instrument"
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
  echo "selftest 8/12: diverged candidates must REFUSE, never silently pick one"
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
  echo "selftest 9/12: an unresolvable sha and an unreadable filter must exit 2, never 0"
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
  echo "selftest 10/12: an api-only commit must strand the INSTANCE and NOT the control plane"
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
  echo "selftest 11/12: a decoy job's identical grep must not answer for a target"
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
  echo "selftest 12/12: an unusable filter must REFUSE, never resolve to nothing-to-deploy"
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
      say "       deploy-convergence-check.sh filters [DEPLOY_YML]   # what it derives, and refuse if nothing"
      say "       deploy-convergence-check.sh --selftest"
      return 2
      ;;
    *) warn "HARNESS-UNAVAILABLE: unknown mode '$mode'"; return 2 ;;
  esac
}

main "$@"
