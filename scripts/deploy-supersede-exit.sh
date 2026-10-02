#!/usr/bin/env bash
# deploy-supersede-exit.sh — decide, BY COMMIT ANCESTRY, whether THIS deploy run
# is superseded and must exit at its START, before any remote box mutation.
#
# ── THE DEFECT (task-01f48337d83a0d15, GitHub #18005) ────────────────────────
#
# .github/workflows/deploy.yml runs one full ~35-min "Deploy (production)" per
# merged main sha under a per-sha concurrency group (`deploy-production-<sha>`,
# `cancel-in-progress: false`). A merge storm therefore queues N runs instead of
# coalescing them: MEASURED 2026-09-11T19:44Z, 8 in_progress + 4 queued
# (30d7c357c..3a9faf139) while only the NEWEST sha matters. The box serialises
# them on its deploy lock and each older one hits instance-deploy.sh's coalesce
# arm ("already deployed healthy — nothing to do"), so nothing is WRONG — but
# each superseded run still holds a runner, an SSH session and the deploy lock
# for minutes. deploy.yml's existing "already covered" exit only fires once a
# newer sha has COMPLETED, so it cannot drain a pile that is still in flight.
#
# This decides the OTHER half: a run exits at START when a newer main-ancestry
# sha deploy is ALREADY in_progress or queued.
#
#   THE INVARIANT. "Newer" is DESCENDANCY on main, decided by
#   `git merge-base --is-ancestor`, NEVER by run-creation time. Wall clock and
#   ancestry are different orders (a re-run, or a burst merge, starts a run
#   later that carries an OLDER commit), and trusting wall clock is the exact
#   shape scripts/deploy-convergence-check.sh was written to forbid. This file
#   borrows that file's `is_ancestor` discipline rather than re-deriving a
#   looser one.
#
# ── WHY EXIT-AT-START AND NEVER A CANCEL (honest-gates D12) ──────────────────
#
# This run decides ONLY about ITSELF and, when superseded, sets the deploy
# jobs' targets to false so they SKIP — it never calls `gh run cancel`, never
# touches another run, and the newest run is never classified as superseded (no
# candidate is its strict descendant). deploy.yml keeps `cancel-in-progress:
# false`; scripts/never-cancel-main-check.sh stays green because nothing here
# adds a bare `cancel-in-progress: true` to a push-to-main workflow.
#
# ── FAIL-OPEN, DELIBERATELY ──────────────────────────────────────────────────
#
# A run must exit at start ONLY when it is CERTAIN a strict descendant is in
# flight. Every doubt — an unresolvable candidate sha, a git that cannot relate
# two commits, an empty or unreadable run list, our own sha unresolvable —
# resolves to PROCEED (rc 0/2), because a redundant deploy merely coalesces on
# the box while a wrongly-skipped deploy STRANDS a commit, which is strictly
# worse. Only a clean, ancestry-proven "a newer run is in flight" returns the
# superseded code.
#
# ── MODE ─────────────────────────────────────────────────────────────────────
#
#   decide --our-run-id ID --our-sha SHA [--git-dir DIR]   # stdin: run lines
#       stdin is one candidate per line: "<run_id> <sha> <status> <created_at>".
#       created_at is READ AND IGNORED — it is carried only so a caller (and the
#       harness) can prove the decision follows ANCESTRY, not time. A candidate
#       whose run_id equals --our-run-id is skipped (that is us). A candidate is
#       "in flight" iff its status is queued/in_progress/waiting/requested/
#       pending. We are SUPERSEDED iff some in-flight candidate's sha is a
#       STRICT DESCENDANT of --our-sha (our sha is-ancestor-of it AND differs).
#
#   --selftest
#       Hermetic. Builds real git repos in mktemp and proves both directions,
#       proves ancestry beats a reversed created-at order, and proves the
#       fail-open cases do NOT return the superseded code. Plants nothing.
#
# ── EXIT CODES — a doubt is never the superseded verdict ─────────────────────
#
#   0  PROCEED — we are the newest deployable in flight, or nothing supersedes us
#   3  SUPERSEDED — a strictly-newer main-ancestry run is in_progress/queued;
#      the caller must skip the deploy jobs and end this run without touching
#      any box. Prints the distinct named conclusion DEPLOY_SUPERSEDED_AT_START.
#   2  CANNOT DECIDE — a read failed (missing git, unresolvable OUR sha, bad
#      args). The caller treats this like PROCEED (fail-open), but the distinct
#      code and text keep "I could not look" from being read as a verdict.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# The distinct named conclusion. It is a LOG string for humans and the harness;
# no failure-report or deploy_stalled reader keys on it — those read job
# RESULTS, and a superseded run's deploy legs are SKIPPED, which trips neither.
NAMED_CONCLUSION="DEPLOY_SUPERSEDED_AT_START"

GIT_DIR_ARG="."

# `merge-base --is-ancestor` answers a THREE-way question with an rc: 0 yes,
# 1 no, anything else broken. The broken case is read EXPLICITLY — folding it
# into "no" would hide a gc'd/unfetched object, and folding it into "yes" would
# skip a deploy on a git error. Mirrors scripts/deploy-convergence-check.sh.
is_ancestor() {
  local rc=0
  git -C "$GIT_DIR_ARG" merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# Resolve a hex sha to a full commit in this clone, or empty on any doubt.
resolve() {
  local raw="$1" full
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -n "$raw" ] || { printf ''; return 0; }
  case "$raw" in
    *[!0-9a-fA-F]*) printf ''; return 0 ;;
  esac
  full="$(git -C "$GIT_DIR_ARG" rev-parse --verify --quiet "${raw}^{commit}" 2>/dev/null || true)"
  printf '%s' "$full"
}

mode_decide() {
  local our_run_id="" our_sha=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --our-run-id) our_run_id="${2:-}"; shift 2 ;;
      --our-sha)    our_sha="${2:-}";    shift 2 ;;
      --git-dir)    GIT_DIR_ARG="${2:-}"; shift 2 ;;
      *) warn "CANNOT DECIDE: unknown argument '$1' to decide"; return 2 ;;
    esac
  done

  if [ -z "$our_run_id" ]; then
    warn "CANNOT DECIDE: --our-run-id is required."; return 2
  fi
  local our_full
  our_full="$(resolve "$our_sha")"
  if [ -z "$our_full" ]; then
    warn "CANNOT DECIDE: our sha '$our_sha' is not a commit in this clone (a shallow"
    warn "checkout is the usual cause — the changes job needs fetch-depth: 0). Proceeding."
    return 2
  fi
  say "our run ${our_run_id} carries ${our_full}"

  local id sha status created full n_inflight=0
  local superseded_by_run="" superseded_by_sha=""
  while read -r id sha status created _rest; do
    [ -n "${id:-}" ] || continue
    case "$id" in \#*) continue ;; esac
    # Ourselves — never supersede a run by itself.
    [ "$id" != "$our_run_id" ] || continue
    case "${status:-}" in
      queued|in_progress|waiting|requested|pending) : ;;
      *) continue ;;   # a terminal run is not in flight; it cannot supersede.
    esac
    n_inflight=$((n_inflight + 1))
    full="$(resolve "$sha")"
    if [ -z "$full" ]; then
      warn "note: candidate run ${id} sha '${sha}' is unresolvable here — not treated as superseding."
      continue
    fi
    # Identical sha is NOT supersession: the per-sha concurrency group already
    # serialises same-sha runs, and skipping on it would make BOTH exit.
    [ "$full" != "$our_full" ] || continue
    local rc=0
    is_ancestor "$our_full" "$full" || rc=$?
    case "$rc" in
      0) # our sha is an ancestor of this candidate → candidate is strictly newer.
         superseded_by_run="$id"; superseded_by_sha="$full"; break ;;
      1) : ;;   # not our descendant — does not supersede us.
      *) warn "note: git could not relate ${our_full} to ${full} — not treated as superseding." ;;
    esac
  done

  say "in-flight candidates other than us: ${n_inflight}"
  if [ -n "$superseded_by_run" ]; then
    say ""
    say "${NAMED_CONCLUSION}: our sha ${our_full} is a STRICT ANCESTOR of run ${superseded_by_run}'s"
    say "sha ${superseded_by_sha}, which is in flight. That run carries this change and a newer one;"
    say "this run is superseded and must exit at START — no box is touched, nothing is cancelled."
    return 3
  fi
  say "PROCEED: no in-flight run carries a strict descendant of our sha — we are the newest deployable."
  return 0
}

# ── selftest ──────────────────────────────────────────────────────────────────
selftest() {
  command -v git >/dev/null || { warn "HARNESS-UNAVAILABLE: no git"; exit 2; }
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  local repo="$tmp/repo"
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q
    git config user.email t@t.t; git config user.name t
    git commit -q --allow-empty -m A; A=$(git rev-parse HEAD)
    git commit -q --allow-empty -m B; B=$(git rev-parse HEAD)
    git commit -q --allow-empty -m C; C=$(git rev-parse HEAD)
    printf '%s %s %s\n' "$A" "$B" "$C" > "$tmp/shas"
  )
  read -r A B C < "$tmp/shas"

  local PASS=0 FAIL=0
  ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
  bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
  # run decide against $repo; capture rc without a pipe.
  dec() { # want-rc our-run our-sha  (stdin = fixture file path in $4)
    local want="$1" run="$2" sha="$3" fixture="$4" name="$5" got=0
    "$0" decide --our-run-id "$run" --our-sha "$sha" --git-dir "$repo" \
        < "$fixture" >/dev/null 2>&1 || got=$?
    if [ "$got" -eq "$want" ]; then ok "$name (rc=$got)"; else bad "$name — wanted rc=$want got rc=$got"; fi
  }

  # A superseded by C (in flight). Our run is 100 (sha A), candidate 200 (sha C).
  printf '200 %s in_progress 2020-01-01T00:00:00Z\n' "$C" > "$tmp/newer-inflight"
  dec 3 100 "$A" "$tmp/newer-inflight" "A superseded by an in_progress C"

  # C is the newest; A is in flight (older). Our run is 300 (sha C). Must PROCEED.
  printf '400 %s in_progress 2020-01-01T00:00:00Z\n' "$A" > "$tmp/older-inflight"
  dec 0 300 "$C" "$tmp/older-inflight" "C is newest, older A in flight -> PROCEED"

  # ── ANCESTRY, NOT CREATED-AT ────────────────────────────────────────────────
  # Our run (A) was CREATED LATER than the candidate run (C), yet C is an
  # ANCESTRY-newer commit. The decision must follow ANCESTRY: SUPERSEDED (rc 3).
  # A created-at comparison would call us the newest and PROCEED — so swapping
  # the is_ancestor test for a created-at comparison reds THIS arm.
  printf '200 %s in_progress 2000-01-01T00:00:00Z\n' "$C" > "$tmp/anc-beats-time"
  dec 3 100 "$A" "$tmp/anc-beats-time" "ancestry beats created-at (our run newer by time, older by ancestry)"

  # The reverse: our run (C) CREATED EARLIER than candidate (A), but C is the
  # descendant. Must PROCEED. A created-at rule would supersede us here.
  printf '400 %s in_progress 2099-01-01T00:00:00Z\n' "$A" > "$tmp/anc-beats-time-rev"
  dec 0 300 "$C" "$tmp/anc-beats-time-rev" "ancestry beats created-at, reversed (proceed)"

  # A queued (not yet started) newer run also supersedes us.
  printf '200 %s queued 2020-01-01T00:00:00Z\n' "$C" > "$tmp/newer-queued"
  dec 3 100 "$A" "$tmp/newer-queued" "A superseded by a QUEUED C"

  # A TERMINAL newer run does NOT supersede (it is not in flight; the
  # already-covered exit handles a completed newer deploy). Must PROCEED.
  printf '200 %s completed 2020-01-01T00:00:00Z\n' "$C" > "$tmp/newer-terminal"
  dec 0 100 "$A" "$tmp/newer-terminal" "a COMPLETED newer run is not in-flight -> PROCEED"

  # Only our own run in flight -> PROCEED (a run never supersedes itself).
  printf '100 %s in_progress 2020-01-01T00:00:00Z\n' "$A" > "$tmp/only-us"
  dec 0 100 "$A" "$tmp/only-us" "only our own run in flight -> PROCEED"

  # Identical sha on another run -> NOT superseded (per-sha group serialises).
  printf '200 %s in_progress 2020-01-01T00:00:00Z\n' "$A" > "$tmp/same-sha"
  dec 0 100 "$A" "$tmp/same-sha" "identical sha on another run -> PROCEED"

  # Empty run list -> PROCEED (nothing in flight).
  : > "$tmp/empty"
  dec 0 100 "$A" "$tmp/empty" "empty run list -> PROCEED"

  # Our sha unresolvable -> CANNOT DECIDE (rc 2), fail-open.
  dec 2 100 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$tmp/newer-inflight" "our sha unresolvable -> CANNOT DECIDE (fail-open)"

  # A candidate sha unresolvable is IGNORED, and if it was the only one -> PROCEED.
  printf '200 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef in_progress 2020-01-01T00:00:00Z\n' > "$tmp/cand-bad"
  dec 0 100 "$A" "$tmp/cand-bad" "unresolvable candidate is ignored -> PROCEED"

  echo ""
  if [ "$FAIL" -ne 0 ]; then
    echo "deploy-supersede-exit selftest: ${PASS} ok, ${FAIL} FAILED" >&2
    exit 1
  fi
  echo "deploy-supersede-exit selftest OK — ${PASS} arms: superseded exits (rc 3) only on a strict-descendant in-flight run; newest and every fail-open case PROCEED (rc 0/2); the decision follows ancestry, not created-at."
  exit 0
}

main() {
  local mode="${1:-}"
  case "$mode" in
    decide)    shift; mode_decide "$@"; exit $? ;;
    --selftest) selftest ;;
    "" ) warn "usage: $0 decide --our-run-id ID --our-sha SHA [--git-dir DIR] | $0 --selftest"; exit 2 ;;
    *) warn "deploy-supersede-exit: unknown mode '$mode' (expected 'decide' or '--selftest')"; exit 2 ;;
  esac
}

main "$@"
