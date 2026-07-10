#!/usr/bin/env bash
# Studio Claude-chat NIGHTLY wire smoke (charter D67). A thin, cron-friendly
# wrapper around scripts/claude-chat-e2e.sh: it fixes CLAUDE_BIN for the bare
# cron environment (cron's PATH is minimal and the cmux wrapper / stale npm
# global are NOT what we want), timestamps a log, and preserves the child's exit
# code so the cron mailer / monitor sees a real red on failure.
#
# The e2e script it wraps does the actual work: it asserts the pinned version
# (scripts/claude-pinned-version.txt) — REFUSING on mismatch — then drives the
# real `claude` binary through OUR seam and proves the resume premise (~$0.43,
# ~40s per run).
#
#   scripts/claude-chat-nightly.sh
#   CLAUDE_BIN=/usr/local/bin/claude scripts/claude-chat-nightly.sh
#   CLAUDE_CHAT_LOG_DIR=/var/log/barkpark scripts/claude-chat-nightly.sh
#
# INSTALL (guerrilla, explicit ops step): docs/ops/claude-chat-harness.md.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# ── CLAUDE_BIN precedence for the cron environment ───────────────────────────
# 1. explicit CLAUDE_BIN (an operator override) always wins.
# 2. else the guerrilla native install: root `claude auth login`, autoUpdates
#    off, pinned — /usr/local/bin/claude. This is the ONLY authenticated binary
#    on the host, and cron does NOT inherit an interactive PATH, so name it.
# 3. else let claude-chat-e2e.sh run its own PATH/well-known-location resolver
#    (leave CLAUDE_BIN unset).
if [ -z "${CLAUDE_BIN:-}" ] && [ -x "/usr/local/bin/claude" ]; then
  CLAUDE_BIN="/usr/local/bin/claude"
fi
[ -n "${CLAUDE_BIN:-}" ] && export CLAUDE_BIN

# ── logging ──────────────────────────────────────────────────────────────────
LOG_DIR="${CLAUDE_CHAT_LOG_DIR:-$REPO_ROOT/tmp/claude-chat-nightly}"
mkdir -p "$LOG_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/nightly-$STAMP.log"

{
  echo "==> claude-chat nightly smoke @ $STAMP (host: $(hostname))"
  echo "==> repo: $REPO_ROOT"
  echo "==> CLAUDE_BIN: ${CLAUDE_BIN:-<e2e will resolve>}"
  echo "----------------------------------------------------------------------"
  bash "$REPO_ROOT/scripts/claude-chat-e2e.sh"
} 2>&1 | tee "$LOG_FILE"

# tee masks the child's status; recover it from the pipe.
STATUS="${PIPESTATUS[0]}"
if [ "$STATUS" -eq 0 ]; then
  echo "==> nightly smoke PASSED — log: $LOG_FILE"
else
  echo "==> nightly smoke FAILED (exit $STATUS) — log: $LOG_FILE" >&2
fi
exit "$STATUS"
