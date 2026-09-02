#!/usr/bin/env bash
# breakglass.sh — the only sanctioned way to lower main's admin-bypass gate,
# and it CANNOT open without writing an attributable record first.
#
# WHY A REPO-SIDE RECORD AND NOT AN AUDIT LOG (honest-gates D60)
#
# There is no audit log to read. The owner is a User, so no org audit log can
# exist: `orgs/…/audit-log`, `users/…/audit-log` and `repos/…/audit-log` all
# 404, `/activity` carries only branch/push/merge events, there are zero
# webhooks, and the protection object itself carries NO actor and NO timestamp.
# A full PUT→DELETE→POST cycle was run on a throwaway branch and left no trace
# anywhere. Rulesets ARE self-attributing (`/rulesets/{id}/history` returns
# actor + ms timestamps) and are REFUSED anyway: deleting the ruleset destroys
# the history that justified it, so the mechanism fails on precisely the
# break-glass path it was chosen for. Classic protection stays; attributability
# moves here, into a record this script cannot skip.
#
# WHY THE RECORD IS A COMMITTED FILE AND NOT THE bp LEDGER (D49)
#
# `bp task create` was measured returning HTTP 500 deterministically, after
# 17–20s, during exactly the kind of outage a break-glass exists for. A recorder
# that needs a healthy remote is a recorder that is absent when it matters. The
# sink is docs/ops/break-glass-log.md, append-only, in this repo.
#
# THE ORDERING IS THE WHOLE POINT
#
#   1. refuse without --reason AND --task, before any API call at all
#   2. read the actor
#   3. read the PRE-STATE, so an already-open glass is detected, not doubled
#   4. WRITE the record and READ ITS ACKNOWLEDGEMENT BACK OFF DISK
#   5. only then DELETE …/branches/<b>/protection/enforce_admins
#
# A crash between 4 and 5 leaves a record for a glass that never opened — a
# FALSE POSITIVE, which the watch screams about and a human clears in seconds.
# The reverse ordering leaves a SILENT OPEN, which is the failure this epic
# exists to make impossible. False positives are recoverable; silence is not.
#
# TWO SCOPES, ONE RECORDER (honest-gates wave 5, S4)
#
#   narrow (default)  DELETE …/branches/<b>/protection/enforce_admins
#                     Required checks still apply to everyone; admins may
#                     bypass them, and an admin `git push` to main also lands
#                     ("remote: Bypassed rule violations", D39).
#   total  (--total)  DELETE …/branches/<b>/protection
#                     The whole protection object goes. This is the hammer
#                     `required-checks-apply.sh --disable` used to swing with no
#                     record at all; it now delegates HERE, so the total form is
#                     recorded on exactly the same path as the narrow one.
#
# The record carries `- scope: narrow|total`, and --close reads it back: a total
# glass is closed by PUTting the FULL committed spec, never by POSTing
# enforce_admins alone. A partial restore followed by a close record saying
# "closed" is a new lie, and this script refuses to write one.
#
# --close INVERTS THAT ORDERING, ON PURPOSE
#
# Restoring protection is the safe direction, so --close POSTs first, verifies
# the read-back, and only then writes the close record. A crash mid-close
# therefore leaves the log still saying OPEN while the glass is actually shut —
# over-reporting again, never under-reporting. --close is symmetric in its
# REFUSALS (no --reason, no --task, or no matching open record ⇒ non-zero), not
# in its write order; symmetry there would invert the safety.
#
# A STALE CHECKOUT IS THE ONE HOLE THIS ORDERING CANNOT SEE (wave 11)
#
# On 2026-07-31 a verifier ran `required-checks-apply.sh --disable --confirm`
# from the PRIMARY checkout, 131 commits behind origin/main. That copy predates
# b4ba2bdb1a (#6928): its whole --disable block was one --confirm check, an
# echo, and a bare `gh api -X DELETE` — no --reason/--task refusal, no record,
# no delegation to here. main's protection was down for ~74 seconds and
# docs/ops/break-glass-log.md gained ZERO rows, so breakglass-watch.sh's
# committed-log authority — the offline leg, trusted precisely because it needs
# no API — saw nothing. Fixing the runbook sentence does not fix that; the tree
# is what was wrong.
#
# So --open and --close now refuse from a checkout that does not carry the
# record-first apply.sh, naming the commit and the remedy. Two legs, because
# neither alone answers everywhere:
#
#   ANCESTRY  HEAD must contain b4ba2bdb1a. Decisive when the object is in the
#             store; a `git merge-base --is-ancestor` that says NO is a refusal.
#   CONTENT   the sibling scripts/required-checks-apply.sh must carry the
#             record-first delegation. This leg is the one that answers in a
#             SHALLOW clone (actions/checkout is depth 1, so the 2026-07-29
#             object is simply absent and ancestry cannot be computed) and in a
#             tarball with no git at all.
#
# --close is guarded too, and that is deliberate rather than paranoid: a
# pre-#6928 tree's .github/required-checks.json is 131 commits stale, so closing
# a TOTAL glass from it would PUT an outdated protection object onto main and
# then write a close record saying it was restored — the same shape of lie the
# scope read-back exists to refuse. The remedy costs seconds and needs no
# network beyond a fetch, so refusing here never traps protection down.
#
# BOUNDED, and the bound is the incident itself: no repo-side script can guard a
# copy of ITSELF that predates the guard. A checkout old enough to lack
# breakglass.sh entirely (it landed in 557b5af40a, #6686) still reaches the API
# with nothing to stop it. That residual is why the 2026-07-31 row in
# docs/ops/break-glass-log.md is hand-written and says so.
#
# USAGE
#   scripts/breakglass.sh --open  --reason "…" --task <task-id> [--total] [--dry-run]
#   scripts/breakglass.sh --close --reason "…" --task <task-id> [--record BG-…]
#   scripts/breakglass.sh --status
#
# EXIT CODES  0 = did what it said · 1 = refused / failed · 2 = glass is open
#                                                              (--status only)
#
# AFTER OPENING: commit and push docs/ops/break-glass-log.md. The scream
# (.github/workflows/breakglass-watch.yml) reads the committed log offline, so a
# pushed record reds main even when the GitHub API cannot be read at all.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SPEC="$REPO_ROOT/.github/required-checks.json"
LOG="$REPO_ROOT/docs/ops/break-glass-log.md"
MODE=""
REASON=""
TASK=""
RECORD_ID=""
REPO_OVERRIDE=""
BRANCH_OVERRIDE=""
DRY_RUN=0
SCOPE="narrow"

# The exact command line, requoted, so the record carries what was actually run.
CMDLINE="scripts/breakglass.sh"

fail() { echo "REFUSED: $*" >&2; exit 1; }
say()  { echo "$*"; }

# ── the log, parsed ──────────────────────────────────────────────────────────
# The format is markdown a human reads and awk parses: one `### BG-<id>` block
# per event, `- key: value` lines inside it. No JSON sidecar — a second file is
# a second thing to forget to commit.

record_block() { # id [file]
  awk -v id="$1" '
    $0 == "### " id { inb = 1; print; next }
    inb && /^### / { inb = 0 }
    inb { print }
  ' "${2:-$LOG}"
}

record_field() { # id key [file]
  record_block "$1" "${3:-$LOG}" \
    | awk -v k="- $2: " 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
}

# Every `open` record with no `close` record pointing back at it.
open_glasses() { # [file]
  local f="${1:-$LOG}"
  [ -f "$f" ] || return 0
  awk '
    /^### BG-/       { id = $2; next }
    /^- event: open/ { if (id != "") opens[id] = 1; next }
    /^- closes: /    { closed[$3] = 1; next }
    END { for (i in opens) if (!(i in closed)) print i }
  ' "$f" | sort
}

# ── the GitHub reads (this script writes exactly one endpoint, and only in --open/--close) ──

spec_repo()   { [ -f "$SPEC" ] && jq -r '.repo'   "$SPEC" 2>/dev/null || echo ""; }
spec_branch() { [ -f "$SPEC" ] && jq -r '.branch' "$SPEC" 2>/dev/null || echo ""; }

read_actor() { # -> "login<TAB>id", or fails
  local out
  out="$(gh api user 2>&1)" || {
    echo "cannot read the actor (gh api user): $out" >&2
    return 1
  }
  local login id
  login="$(printf '%s' "$out" | jq -r '.login // empty' 2>/dev/null || true)"
  id="$(printf '%s' "$out" | jq -r '.id | if . == null then "" else tostring end' 2>/dev/null || true)"
  [ -n "$login" ] && [ -n "$id" ] || {
    echo "gh api user returned no login/id — an unattributable break-glass is not a break-glass" >&2
    return 1
  }
  printf '%s\t%s\n' "$login" "$id"
}

# Prints the live enforce_admins state as one of: true | false | UNPROTECTED,
# or fails (unreadable is a REFUSAL, never an assumption).
read_prestate() { # repo branch
  local repo="$1" branch="$2" out
  out="$(gh api "repos/$repo/branches/$branch/protection" 2>&1)" || {
    if grep -q "Branch not protected" <<<"$out"; then
      echo "UNPROTECTED"
      return 0
    fi
    echo "cannot read live protection for $repo/$branch: $out" >&2
    return 1
  }
  printf '%s' "$out" \
    | jq -r '.enforce_admins.enabled | if . == null then "MISSING" else tostring end'
}

# ── the record, written and acknowledged ─────────────────────────────────────

new_record_id() {
  local rnd
  rnd="$(od -An -tx1 -N3 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
  [ -n "$rnd" ] || rnd="$(printf '%06x' "$$")"
  printf 'BG-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$rnd"
}

# One line per field, order fixed, values single-line (a newline in --reason
# would break the block boundary and therefore the parser).
oneline() { printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ *//; s/ *$//'; }

# Appends the block, flushes it, then READS IT BACK OFF DISK and requires every
# field to round-trip. Returns non-zero if it cannot — the caller must not
# proceed to the API write.
write_record_and_ack() { # id event k=v...
  local id="$1" event="$2"; shift 2
  local tmpblock; tmpblock="$(mktemp)"
  {
    printf '\n### %s\n' "$id"
    printf -- '- event: %s\n' "$event"
    local kv
    for kv in "$@"; do
      printf -- '- %s: %s\n' "${kv%%=*}" "$(oneline "${kv#*=}")"
    done
  } > "$tmpblock"

  # `return 1`, never `fail`: the CALLER decides what an unwritable record means,
  # and the caller's decision is "do not touch protection".
  [ -f "$LOG" ] || { echo "no break-glass log at $LOG — the sink must exist and be committed before the glass can open" >&2; return 1; }
  cat "$tmpblock" >> "$LOG" || { rm -f "$tmpblock"; echo "could not append to $LOG" >&2; return 1; }
  rm -f "$tmpblock"
  command -v sync >/dev/null 2>&1 && sync 2>/dev/null || true

  # THE ACKNOWLEDGEMENT: re-read the file we just wrote and verify the record is
  # there, complete, and says what we meant. An append that "succeeded" into a
  # full disk, a symlink, or a file another process truncated does not.
  local got
  got="$(record_field "$id" event)"
  [ "$got" = "$event" ] || { echo "record $id did not read back (event: '$got')" >&2; return 1; }
  local kv key want
  for kv in "$@"; do
    key="${kv%%=*}"; want="$(oneline "${kv#*=}")"
    got="$(record_field "$id" "$key")"
    [ "$got" = "$want" ] || {
      echo "record $id field '$key' did not read back: wrote '$want', read '$got'" >&2
      return 1
    }
  done
  return 0
}

# ── the stale-checkout guard ─────────────────────────────────────────────────
# Pinned by SHA, not by tag or by "recent": the property is "does THIS tree
# contain the commit that made the total hammer record before it deletes", and
# only the SHA states that.

RECORD_FIRST_COMMIT="b4ba2bdb1a8548fb6a3e5a13a4dea718c1cb4721"
RECORD_FIRST_REF="#6928 — fix(ops): the break-glass cannot be left open silently"

# Prints one of: contains | behind | unanswerable
head_contains_record_first() {
  command -v git >/dev/null 2>&1 || { echo unanswerable; return 0; }
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo unanswerable; return 0; }
  # The object must actually be in the store. In a depth-1 CI clone it is not,
  # and `--is-ancestor` against a missing commit exits non-zero — which reads
  # exactly like "behind". Refusing every shallow checkout would ground the
  # break-glass in CI, so absence is reported as UNANSWERABLE and the content
  # leg decides.
  git -C "$REPO_ROOT" cat-file -e "$RECORD_FIRST_COMMIT^{commit}" 2>/dev/null \
    || { echo unanswerable; return 0; }
  if git -C "$REPO_ROOT" merge-base --is-ancestor "$RECORD_FIRST_COMMIT" HEAD 2>/dev/null; then
    echo contains
  else
    echo behind
  fi
}

stale_remedy() {
  printf '%s' "REMEDY: do not \`git pull\` this tree mid-incident — cut a fresh one and run from there:
    git -C \"$REPO_ROOT\" fetch origin
    git -C \"$REPO_ROOT\" worktree add /tmp/glass origin/main
    bash /tmp/glass/scripts/breakglass.sh <the same arguments>"
}

# Runs BEFORE the actor read, before the pre-state read, before anything that
# could mutate protection. A stale tree is refused, not argued with.
require_record_first_checkout() {
  local apply="$REPO_ROOT/scripts/required-checks-apply.sh"
  local ancestry; ancestry="$(head_contains_record_first)"

  if [ "$ancestry" = "behind" ]; then
    fail "STALE CHECKOUT — $REPO_ROOT is at a commit that PREDATES the record-first break-glass.
  HEAD ($(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')) does not contain $RECORD_FIRST_COMMIT
  ($RECORD_FIRST_REF), the commit that made \`required-checks-apply.sh --disable\` refuse
  without --reason/--task and write the record BEFORE the DELETE.
  A tree this old took main's protection down for ~74 seconds on 2026-07-31 and left ZERO rows in
  docs/ops/break-glass-log.md — the offline authority saw nothing. This is that refusal.
  $(stale_remedy)"
  fi

  # CONTENT leg. Not a proxy for the ancestry leg — the thing the commit
  # INSTALLED, checked in the tree that is about to be used.
  [ -f "$apply" ] || fail "STALE OR PARTIAL CHECKOUT — there is no $apply next to this script.
  A tree that cannot show the record-first apply.sh cannot be shown to contain $RECORD_FIRST_COMMIT
  ($RECORD_FIRST_REF), and an unprovable tree does not get to touch main's protection.
  $(stale_remedy)"

  grep -q 'exec bash "$REPO_ROOT/scripts/breakglass.sh"' "$apply" \
    && grep -q -- '--disable needs --reason' "$apply" \
    || fail "STALE CHECKOUT — $apply is the PRE-$RECORD_FIRST_COMMIT shape: its --disable neither refuses
  without --reason/--task nor delegates here, so it DELETEs main's protection with no record at all.
  ($RECORD_FIRST_REF is the commit that installed both.)
  That is the exact tree that opened an unrecorded 74-second glass on 2026-07-31.
  $(stale_remedy)"

  if [ "$ancestry" = "unanswerable" ]; then
    # Said out loud rather than swallowed: an instrument that cannot run one of
    # its two legs reports which leg carried the verdict.
    echo "NOTE: $RECORD_FIRST_COMMIT is not in this checkout's object store (shallow clone, or no git) — the ancestry leg could not run and the content check of scripts/required-checks-apply.sh carried the verdict." >&2
  fi
}

# ── modes ────────────────────────────────────────────────────────────────────

require_reason_and_task() {
  # BEFORE ANY API CALL. Not a formality: the record is the only artefact that
  # survives, and a record without a why and a task id is a shrug.
  [ -n "$REASON" ] || fail "--reason is required; a break-glass with no stated reason records nothing worth reading"
  [ -n "$TASK" ]   || fail "--task is required; the record must point at the work that justified it"
}

do_open() {
  require_record_first_checkout
  require_reason_and_task

  local repo branch
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  branch="${BRANCH_OVERRIDE:-$(spec_branch)}"
  [ -n "$repo" ] && [ -n "$branch" ] || fail "cannot determine repo/branch (no $SPEC and no --repo/--branch)"

  # An open record already standing means the log believes a glass is open.
  # Opening a second one detaches the record from the reality it describes.
  local standing
  standing="$(open_glasses)"
  [ -z "$standing" ] || fail "the log already carries an OPEN break-glass: $(printf '%s' "$standing" | tr '\n' ' ')— close it first (scripts/breakglass.sh --close --reason … --task …)"

  local endpoint what
  case "$SCOPE" in
    narrow) endpoint="repos/$repo/branches/$branch/protection/enforce_admins"
            what="admin bypass" ;;
    total)  endpoint="repos/$repo/branches/$branch/protection"
            what="ALL protection (total hammer)" ;;
    *) fail "unknown scope '$SCOPE'" ;;
  esac

  say "── break-glass: opening $what on $repo/$branch ──"
  say "[1/5] preflight: --reason and --task present (no API call has been made yet)"

  local actor login actor_id
  actor="$(read_actor)" || fail "the actor is unreadable"
  login="${actor%%	*}"; actor_id="${actor##*	}"
  say "[2/5] actor: $login (id $actor_id)"

  local pre pre_ts
  pre_ts="$(date -u +%FT%TZ)"
  pre="$(read_prestate "$repo" "$branch")" || fail "the pre-state is unreadable — refusing to open a glass onto a state nobody can see"
  say "[3/5] pre-state: enforce_admins.enabled=$pre (read $pre_ts)"
  case "$pre" in
    true) : ;;
    false) fail "enforce_admins is ALREADY false on $repo/$branch — a glass is open with no standing record. Write one by hand in $LOG, or --close to restore." ;;
    UNPROTECTED) fail "$repo/$branch is NOT PROTECTED — there is no glass to break" ;;
    *) fail "enforce_admins reads '$pre' — refusing to act on a state that is neither true nor false" ;;
  esac

  local id; id="$(new_record_id)"

  if [ "$DRY_RUN" -eq 1 ]; then
    say "[4/5] WOULD write record $id (scope $SCOPE) to $LOG and read it back — and would ABORT here if it did not"
    say "[5/5] WOULD then DELETE $endpoint"
    say
    say "DRY RUN — nothing written, nothing deleted. The record is written and acknowledged BEFORE the delete, always."
    return 0
  fi

  say "[4/5] writing record $id to $LOG and reading it back"
  write_record_and_ack "$id" open \
    "utc=$pre_ts" \
    "actor=$login (id $actor_id)" \
    "task=$TASK" \
    "repo=$repo" \
    "branch=$branch" \
    "scope=$SCOPE" \
    "command=$CMDLINE" \
    "pre-state=enforce_admins.enabled=$pre (read $pre_ts)" \
    "reason=$REASON" \
    || fail "the record could not be written and acknowledged — NOT touching protection. An unrecorded break-glass does not open."

  say "[5/5] DELETE $endpoint"
  local rc=0
  gh api -X DELETE "$endpoint" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf -- '- outcome: DELETE FAILED (rc %s) — this record may be a false positive; verify with scripts/breakglass-watch.sh\n' "$rc" >> "$LOG"
    fail "the DELETE failed (rc $rc). The record STANDS — a false-positive record is the safe residue, and the watch will red until it is closed."
  fi

  local post
  post="$(read_prestate "$repo" "$branch" || echo UNREADABLE)"
  printf -- '- outcome: opened (post-state enforce_admins.enabled=%s)\n' "$post" >> "$LOG"

  say
  say "OPEN — $repo/$branch $what is DOWN (scope $SCOPE). Record: $id"
  say "  * commit and push $LOG NOW; the watch reads the committed log offline."
  say "  * close it the moment the merge lands: scripts/breakglass.sh --close --reason … --task $TASK"
  return 0
}

do_close() {
  require_record_first_checkout
  require_reason_and_task

  local repo branch
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  branch="${BRANCH_OVERRIDE:-$(spec_branch)}"
  [ -n "$repo" ] && [ -n "$branch" ] || fail "cannot determine repo/branch (no $SPEC and no --repo/--branch)"

  local standing count target
  standing="$(open_glasses)"
  count="$(printf '%s' "$standing" | grep -c . || true)"
  [ "$count" -gt 0 ] || fail "no matching OPEN break-glass record in $LOG — there is nothing to close, and closing what was never recorded would write a lie"
  if [ -n "$RECORD_ID" ]; then
    printf '%s\n' "$standing" | grep -qx "$RECORD_ID" \
      || fail "$RECORD_ID is not an open record in $LOG (open: $(printf '%s' "$standing" | tr '\n' ' '))"
    target="$RECORD_ID"
  else
    [ "$count" -eq 1 ] \
      || fail "$count open records ($(printf '%s' "$standing" | tr '\n' ' ')) — name one with --record BG-…"
    target="$standing"
  fi

  # The RECORD decides how much has to come back, not the flags on this
  # invocation. A total glass closed with the narrow POST would restore
  # enforce_admins onto a branch with no required checks, no review rule and no
  # force-push block — and then write a close record saying it was closed. That
  # record would be a new lie, so the scope is read back off disk.
  local scope
  scope="$(record_field "$target" scope)"
  [ -n "$scope" ] || scope="narrow"   # records written before scopes existed
  case "$scope" in
    narrow|total) : ;;
    *) fail "record $target carries scope '$scope', which is neither narrow nor total — refusing to guess how much protection to restore" ;;
  esac

  say "── break-glass: closing $target (scope $scope) on $repo/$branch ──"
  local actor login actor_id
  actor="$(read_actor)" || fail "the actor is unreadable"
  login="${actor%%	*}"; actor_id="${actor##*	}"

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$scope" = "total" ]; then
      say "WOULD PUT the FULL committed spec ($SPEC) to repos/$repo/branches/$branch/protection, verify the read-back, THEN write the close record for $target"
    else
      say "WOULD POST repos/$repo/branches/$branch/protection/enforce_admins, verify the read-back, THEN write the close record for $target"
    fi
    say "DRY RUN — nothing restored, nothing written."
    return 0
  fi

  # Restore FIRST: see the header. A crash after this and before the record
  # leaves the log over-reporting (says open, is shut) — the safe direction.
  local rc=0
  if [ "$scope" = "total" ]; then
    # One payload builder in this repo, and it lives in required-checks-apply.sh
    # (D41: every field, including the falses, or the PUT does not converge).
    # Borrowed, never re-implemented — two builders drift and one of them ships.
    local payload
    payload="$(bash "$REPO_ROOT/scripts/required-checks-apply.sh" --payload --spec "$SPEC" 2>&1)" \
      || fail "cannot build the full protection payload from $SPEC: $payload"
    say "restoring the FULL protection object from $SPEC (scope total)"
    printf '%s' "$payload" | gh api -X PUT "repos/$repo/branches/$branch/protection" --input - >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "the full-restore PUT failed (rc $rc) — protection is still down and $target is still open. Retry, or restore by hand."
  else
    gh api -X POST "repos/$repo/branches/$branch/protection/enforce_admins" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || fail "the POST failed (rc $rc) — protection is still down and $target is still open. Retry, or restore by hand."
  fi

  local post
  post="$(read_prestate "$repo" "$branch")" || fail "restored, but the read-back is unreadable — verify by hand before writing a close record"
  [ "$post" = "true" ] \
    || fail "POSTed, but enforce_admins reads '$post' — refusing to write a close record for a glass that is still open"

  local ts; ts="$(date -u +%FT%TZ)"
  write_record_and_ack "$target-close" close \
    "closes=$target" \
    "utc=$ts" \
    "actor=$login (id $actor_id)" \
    "task=$TASK" \
    "repo=$repo" \
    "branch=$branch" \
    "scope=$scope" \
    "command=$CMDLINE" \
    "post-state=enforce_admins.enabled=$post (read $ts)" \
    "reason=$REASON" \
    || fail "protection IS restored, but the close record could not be written — the log still says OPEN and the watch will keep screaming until it is fixed by hand. That is the intended direction of the error."

  say "CLOSED — enforce_admins is back up on $repo/$branch. Record: $target-close"
  say "  * commit and push $LOG."
  return 0
}

do_status() {
  local standing repo branch live
  standing="$(open_glasses)"
  repo="${REPO_OVERRIDE:-$(spec_repo)}"
  branch="${BRANCH_OVERRIDE:-$(spec_branch)}"

  if [ -n "$standing" ]; then
    say "LOG: OPEN break-glass record(s):"
    printf '%s\n' "$standing" | while IFS= read -r id; do
      [ -n "$id" ] || continue
      say "  $id  scope=$(record_field "$id" scope || true)  task=$(record_field "$id" task)  actor=$(record_field "$id" actor)"
      say "     reason: $(record_field "$id" reason)"
    done
  else
    say "LOG: no open break-glass records in $LOG"
  fi

  if [ -n "$repo" ] && [ -n "$branch" ]; then
    live="$(read_prestate "$repo" "$branch" 2>/dev/null || echo UNREADABLE)"
    say "LIVE: $repo/$branch enforce_admins.enabled=$live"
    [ "$live" = "true" ] || return 2
  fi
  [ -z "$standing" ] || return 2
  return 0
}

main() {
  local a
  for a in "$@"; do CMDLINE="$CMDLINE $(printf '%q' "$a")"; done

  while [ $# -gt 0 ]; do
    case "$1" in
      --open)   MODE="open";   shift ;;
      --close)  MODE="close";  shift ;;
      --status) MODE="status"; shift ;;
      --reason) REASON="${2:-}"; shift 2 ;;
      --task)   TASK="${2:-}";   shift 2 ;;
      --record) RECORD_ID="${2:-}"; shift 2 ;;
      --total)  SCOPE="total";  shift ;;
      --narrow) SCOPE="narrow"; shift ;;
      --log)    LOG="${2:-}";    shift 2 ;;
      --spec)   SPEC="${2:-}";   shift 2 ;;
      --repo)   REPO_OVERRIDE="${2:-}";   shift 2 ;;
      --branch) BRANCH_OVERRIDE="${2:-}"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      # By SHAPE, not a hard-coded line range: the range silently truncates the
      # moment anyone adds a line to a comment above it.
      -h|--help) awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
      *) fail "unknown argument: $1 (try --help)" ;;
    esac
  done

  case "$MODE" in
    open)   do_open ;;
    close)  do_close ;;
    status) do_status ;;
    *) fail "one of --open, --close or --status is required" ;;
  esac
}

main "$@"
