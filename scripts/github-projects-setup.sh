#!/usr/bin/env bash
# Create the Barkpark bridge Projects v2 board + its Status/Priority/Worker/Goal
# fields via the gh CLI, and print the board node id (the `project_id` setting).
#
# Uses YOUR gh token (not the App) — user-owned Projects v2 is not writable by a
# GitHub App installation token, so the board is provisioned with your own creds
# and the plugin projects the fields onto it. Needs the `project` scope:
#     gh auth refresh -s project
#
# Usage: scripts/github-projects-setup.sh [board title] [owner]
#   owner defaults to the authenticated user (@me). Pass an org login for an org board.
set -euo pipefail

TITLE="${1:-Barkpark Bridge}"
OWNER="${2:-@me}"

command -v gh >/dev/null || { echo "gh not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated" >&2; exit 1; }
if ! gh auth status 2>&1 | grep -q 'project'; then
  echo "!! Your gh token lacks the 'project' scope. Run:  gh auth refresh -s project" >&2
  exit 2
fi

echo ">> Creating Projects v2 board '$TITLE' (owner: $OWNER) ..."
CREATE_JSON="$(gh project create --owner "$OWNER" --title "$TITLE" --format json)"
NUMBER="$(echo "$CREATE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["number"])')"
NODE_ID="$(echo "$CREATE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')"
echo "   board #$NUMBER  node_id=$NODE_ID"

# A new board ships with a default single-select "Status" field; add the rest.
# Priority + Worker as single-select (the projector matches option NAMES
# case-insensitively); Goal as free text (it carries a goal slug).
add_single_select() {
  local name="$1"; shift
  echo ">> field: $name (single-select: $*)"
  gh project field-create "$NUMBER" --owner "$OWNER" \
    --name "$name" --data-type SINGLE_SELECT \
    --single-select-options "$(IFS=,; echo "$*")" >/dev/null
}
add_text() {
  echo ">> field: $1 (text)"
  gh project field-create "$NUMBER" --owner "$OWNER" --name "$1" --data-type TEXT >/dev/null
}

# Status options mirror the task lifecycle-derived status labels.
add_single_select "Priority" "P0" "P1" "P2" "P3" "P4"
add_single_select "Worker"   "unassigned" "agent" "human"
add_text          "Goal"

echo
echo "DONE. Set this as github.project_id:"
echo "  $NODE_ID"
