#!/usr/bin/env bash
# Barkpark project-local pre-tool-use hook override.
#
# Purpose (Task #38): allow `git push --force-with-lease` when the caller has
# explicitly opted in by setting DOEY_ALLOW_FORCE_PUSH=1 on the command. This
# unblocks PR #60's rebase-update VCS path while keeping unsafe `--force`
# (without lease) blocked unconditionally and preserving every other rule in
# the upstream hook (Subtaskmaster role guards, --no-verify, etc.).
#
# Behavior:
#   1. Capture stdin (Claude Code hook payload, JSON).
#   2. If TOOL=Bash AND command contains `git push` AND `--force-with-lease`
#      AND no bare `--force` (after stripping `--force-with-lease[=…]`)
#      AND DOEY_ALLOW_FORCE_PUSH=1 → log audit line, exit 0 (allow).
#   3. Otherwise → replay stdin to the upstream hook so all other rules fire.

set -u

PAYLOAD=$(cat)

UPSTREAM="$HOME/.local/share/doey-repo/.claude/hooks/on-pre-tool-use.sh"

_fall_through() {
  if [ -x "$UPSTREAM" ]; then
    printf '%s' "$PAYLOAD" | "$UPSTREAM" "$@"
    exit $?
  fi
  exit 0
}

# Only attempt the opt-in path when the flag is set.
if [ "${DOEY_ALLOW_FORCE_PUSH:-}" != "1" ]; then
  _fall_through "$@"
fi

# Extract tool name + command. jq if available, fallback to grep.
TOOL=""
CMD=""
if command -v jq >/dev/null 2>&1; then
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null || true)
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
fi

if [ "$TOOL" != "Bash" ] || [ -z "$CMD" ]; then
  _fall_through "$@"
fi

# Must contain `git push` and `--force-with-lease`.
case "$CMD" in
  *"git push"*"--force-with-lease"*) : ;;
  *) _fall_through "$@" ;;
esac

# Strip every `--force-with-lease` (with optional =value) and check for a
# remaining bare `--force` — that variant is the unsafe one we keep blocked.
STRIPPED=$(printf '%s' "$CMD" | sed 's/--force-with-lease[=A-Za-z0-9_:./@%-]*//g')
case "$STRIPPED" in
  *"--force"*)
    # Unsafe `--force` present alongside lease — fall through to upstream block.
    _fall_through "$@" ;;
esac

# Audit log on the chosen path.
DBG_DIR="${DOEY_DEBUG_DIR:-/tmp/doey/${DOEY_PROJECT_NAME:-barkpark}/debug}"
mkdir -p "$DBG_DIR" 2>/dev/null || true
{
  printf '%s allow_force_push_opted_in cmd=%s\n' "$(date -Iseconds 2>/dev/null || date)" "$CMD"
} >> "$DBG_DIR/pretool.log" 2>/dev/null || true

exit 0
