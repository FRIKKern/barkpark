#!/usr/bin/env bash
# dependabot-task-trailer.sh — the PURE decision behind
# .github/workflows/dependabot-task-trailer.yml.
#
# WHY THIS EXISTS (task-361f1ad90eb1b46e, measured 2026-09-09). 33 of 33 open
# non-draft `dependabot/` PRs carry NO `Task:` trailer, so the required context
# `PR references an active task` reds on every one of them and not one can
# merge. The gate is right and the grouping is fine; there is simply no path by
# which a BOT can reference a ledger row. Remedy (c) of the row: ONE standing
# ledger row for dependency bumps, and this injector writes its trailer into the
# bot's PR body so the existing gate can evaluate it like any other PR.
#
# WHAT IT DELIBERATELY DOES NOT DO: it does not exempt anybody. The gate keeps
# its full authority — a HUMAN PR with no trailer still reds, which is the
# positive control in scripts/dependabot-task-trailer.test.sh section 3. This
# script only supplies a reference; the gate still decides.
#
# THE DECISION IS PURE so the harness can reach it: the workflow passes the PR
# event's fields in as env and this script prints the body it wants, never
# writing anything itself. The `gh pr edit` call is one step in the YAML.
#
#   Inputs (env):
#     ACTOR      required — github.actor of the triggering event
#     HEAD_REF   required — github.event.pull_request.head.ref
#     PR_BODY    the PR description (may be empty; an empty body is legal)
#     TRAILER_TASK_ID  optional — override the standing row (default below)
#
#   Exit codes:
#     0  APPEND — a new body is on stdout; the caller writes it back
#     3  NO-OP, NOT A DEPENDABOT PR — actor is not dependabot[bot], or the head
#        ref does not start with `dependabot/`. BOTH must hold. This is the arm
#        the positive control protects: a human PR leaves here, untouched.
#     4  NO-OP, ALREADY REFERENCED — the body already carries a column-0 `Task:`
#        trailer. IDEMPOTENCE, and it is not cosmetic: the gate's grammar
#        REFUSES a body carrying two DISTINCT ids (pr-task-gate.sh
#        --extract-task-id, exit 4), so a second append would turn a green PR
#        red. Any existing trailer wins, including a human-added one.
#     2  CANNOT MEASURE — required env absent. Never a silent success: a script
#        that cannot read its inputs must not report "nothing to do".
#
# The trailer grammar written here is exactly the one the gate reads: the label
# at COLUMN 0, one space, the bare id, no backticks (accepted either way, but a
# bare id is what the gate's own examples show).
set -uo pipefail

# The STANDING ROW. task-3e5d6364196a7cda — "Dependency bumps (dependabot) —
# the standing ledger row every dependabot PR references". One row, one trailer
# grammar, one auditable place a reviewer can look to see what the bot fleet is
# for. Read it with: bp task get task-3e5d6364196a7cda
DEFAULT_TASK_ID="task-3e5d6364196a7cda"
TASK_ID="${TRAILER_TASK_ID:-$DEFAULT_TASK_ID}"

MODE="decide"
case "${1:-}" in
  --selftest) MODE="selftest" ;;
  "") : ;;
  -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "dependabot-task-trailer: unknown option '$1'" >&2
     echo "dependabot-task-trailer: CANNOT MEASURE (rc 2)" >&2
     exit 2 ;;
esac

if [ "$MODE" = "selftest" ]; then
  exec bash "$(dirname "${BASH_SOURCE[0]}")/dependabot-task-trailer.test.sh"
fi

# CANNOT MEASURE, loudly and distinctly, when the event fields did not arrive.
# `ACTOR` unset and `ACTOR=""` are the same failure here: neither can be
# compared against the bot's login, and an empty compare would take the
# not-a-bot arm and look exactly like a legitimate human PR.
if [ -z "${ACTOR:-}" ]; then
  echo "dependabot-task-trailer: CANNOT MEASURE — ACTOR is empty or unset, so the author of this event cannot be established (rc 2)" >&2
  exit 2
fi
if [ -z "${HEAD_REF:-}" ]; then
  echo "dependabot-task-trailer: CANNOT MEASURE — HEAD_REF is empty or unset, so the head branch cannot be established (rc 2)" >&2
  exit 2
fi

# THE AUTHOR CLAUSE. Both halves are required and neither is redundant:
#   • ACTOR alone would fire on a `dependabot[bot]` event against a branch a
#     human pushed (dependabot comments and `@dependabot` commands re-trigger).
#   • HEAD_REF alone would let ANY author open a branch named `dependabot/x`
#     and be handed the standing row's trailer — a self-serve bypass of the
#     required gate, by branch name, available to anyone with push access.
# Together they say "this is the bot's own PR on the bot's own branch".
if [ "$ACTOR" != "dependabot[bot]" ]; then
  echo "dependabot-task-trailer: NO-OP — actor '${ACTOR}' is not dependabot[bot]; this PR is left exactly as its author wrote it and the task gate decides it on its own merits (rc 3)" >&2
  exit 3
fi
case "$HEAD_REF" in
  dependabot/*) : ;;
  *)
    echo "dependabot-task-trailer: NO-OP — head ref '${HEAD_REF}' does not start with 'dependabot/' (rc 3)" >&2
    exit 3 ;;
esac

# IDEMPOTENCE. The same column-0, case-insensitive grammar the gate reads
# (pr-task-gate.sh extract_task_ids). ANY existing trailer — this id or another
# — stops the append, because two DISTINCT ids is a REFUSAL in the gate, not a
# pick. A second run of this workflow therefore adds nothing.
if printf '%s' "${PR_BODY:-}" | grep -qiE '^task:[[:space:]]*`?[a-z0-9][a-z0-9._/-]*`?'; then
  echo "dependabot-task-trailer: NO-OP — the body already carries a column-0 'Task:' trailer, so nothing is appended (rc 4)" >&2
  exit 4
fi

# THE APPEND. A blank line before the trailer so it is at column 0 of its own
# line whatever the body ended with; `printf` and not `echo` so a body
# containing backslashes survives. An EMPTY body is legal and yields a body that
# is just the trailer.
if [ -n "${PR_BODY:-}" ]; then
  printf '%s\n\nTask: %s\n' "$PR_BODY" "$TASK_ID"
else
  printf 'Task: %s\n' "$TASK_ID"
fi
exit 0
