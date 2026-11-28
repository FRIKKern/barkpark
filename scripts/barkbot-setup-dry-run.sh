#!/usr/bin/env bash
# BarkBot Setup Dry-Run Helper
#
# Detects current host configuration and outputs JSON for bot creation.
# NEVER modifies live servers - read-only inspection only.
#
# Usage:
#   ./scripts/barkbot-setup-dry-run.sh
#   ./scripts/barkbot-setup-dry-run.sh --bot-id my-assistant

set -euo pipefail

BOT_ID="${1:---bot-id}"
BOT_ID="${2:-my-barkbot}"

echo "========================================"
echo "BarkBot Setup Dry-Run"
echo "========================================"
echo ""
echo "This script inspects the current host and outputs configuration."
echo "It NEVER modifies any files or installs anything."
echo ""

# Detect hostname
HOSTNAME=$(hostname)
echo "✓ Detected hostname: $HOSTNAME"

# Detect CPU cores
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "unknown")
echo "✓ Detected CPU cores: $CPU_CORES"

# Detect memory (GB)
if [[ "$(uname)" == "Linux" ]]; then
  MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  MEMORY_GB=$(echo "scale=1; $MEMORY_KB / 1024 / 1024" | bc)
elif [[ "$(uname)" == "Darwin" ]]; then
  MEMORY_BYTES=$(sysctl -n hw.memsize)
  MEMORY_GB=$(echo "scale=1; $MEMORY_BYTES / 1024 / 1024 / 1024" | bc)
else
  MEMORY_GB="unknown"
fi
echo "✓ Detected memory: ${MEMORY_GB} GB"

# Detect location (basic heuristic from hostname)
if [[ "$HOSTNAME" == *"nbg"* ]]; then
  LOCATION="Hetzner Nuremberg"
elif [[ "$HOSTNAME" == *"fsn"* ]]; then
  LOCATION="Hetzner Falkenstein"
elif [[ "$HOSTNAME" == *"hel"* ]]; then
  LOCATION="Hetzner Helsinki"
elif [[ "$HOSTNAME" == *"ash"* ]]; then
  LOCATION="Hetzner Ashburn"
else
  LOCATION="Unknown location"
fi
echo "✓ Detected location: $LOCATION"

# Check for Claude Code
echo ""
echo "Checking for Claude Code..."
if command -v claude &> /dev/null; then
  CLAUDE_PATH=$(command -v claude)
  echo "✓ Claude Code found: $CLAUDE_PATH"
  
  # Try to detect version (may not work if not authenticated)
  CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
  echo "  Version: $CLAUDE_VERSION"
  
  # Check authentication (without triggering interactive flow)
  echo ""
  echo "Checking Claude Code authentication..."
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    echo "✓ CLAUDE_CODE_OAUTH_TOKEN environment variable is set"
    AUTH_STATUS="authenticated"
  elif [[ -f ~/.config/claude-code/token ]]; then
    echo "✓ Token file exists: ~/.config/claude-code/token"
    AUTH_STATUS="authenticated"
  else
    echo "⚠ No authentication detected"
    echo "  Run: claude setup-token"
    AUTH_STATUS="not_authenticated"
  fi
else
  echo "✗ Claude Code not found"
  echo "  Install from: https://code.claude.com/docs/en/setup"
  CLAUDE_PATH="claude"
  CLAUDE_VERSION="not_installed"
  AUTH_STATUS="not_installed"
fi

# Suggest workspace path
WORKSPACE_PATH="/barkpark/workspaces/${BOT_ID}"
echo ""
echo "Suggested workspace: $WORKSPACE_PATH"

# Check if workspace exists
if [[ -d "$WORKSPACE_PATH" ]]; then
  echo "✓ Workspace already exists"
  WORKSPACE_EXISTS=true
else
  echo "  Workspace does not exist (will need creation)"
  WORKSPACE_EXISTS=false
fi

# Output JSON configuration
echo ""
echo "========================================"
echo "Bot Configuration (JSON)"
echo "========================================"
echo ""

cat <<EOF
{
  "bot_id": "${BOT_ID}",
  "name": "${BOT_ID}",
  "description": "BarkBot running on ${HOSTNAME}",
  "provider": "claude-code",
  "claude_bin_path": "${CLAUDE_PATH}",
  "workspace_path": "${WORKSPACE_PATH}",
  "auth_status": "${AUTH_STATUS}",
  "hostname": "${HOSTNAME}",
  "cpu_cores": ${CPU_CORES},
  "memory_gb": ${MEMORY_GB},
  "location": "${LOCATION}",
  "max_tokens": 4096,
  "temperature": 1.0,
  "timeout_seconds": 300,
  "enabled": true
}
EOF

echo ""
echo "========================================"
echo "Next Steps"
echo "========================================"
echo ""

if [[ "$AUTH_STATUS" != "authenticated" ]]; then
  echo "1. Authenticate Claude Code:"
  echo "   $ claude setup-token"
  echo ""
fi

if [[ "$WORKSPACE_EXISTS" == false ]]; then
  echo "2. Create workspace directory:"
  echo "   $ sudo mkdir -p ${WORKSPACE_PATH}"
  echo "   $ sudo chown barkbot:barkbot ${WORKSPACE_PATH}"
  echo ""
fi

echo "3. Create bot via BarkBot API:"
echo "   $ curl -X POST http://localhost:4000/v1/plugins/barkbot/bots \\"
echo "     -H 'Authorization: Bearer YOUR_TOKEN' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d @- <<'JSON'"
echo "   {JSON output above}"
echo "   JSON"
echo ""

echo "4. Test via UI:"
echo "   Open: http://localhost:4000/barkbot/chat"
echo ""

echo "This script did NOT modify any files or install anything."
echo "It only inspected the current host configuration."
