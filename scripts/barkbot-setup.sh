#!/usr/bin/env bash
# BarkBot Setup - Idempotent Opt-In Installation
#
# Creates workspace and verifies Claude Code installation.
# Safe to run multiple times.
#
# Usage:
#   ./scripts/barkbot-setup.sh --bot-id my-bot [--workspace-path /path] [--dry-run]
#
# Flags:
#   --bot-id ID        Bot identifier (required)
#   --workspace-path   Custom workspace path (default: /barkpark/workspaces/BOT_ID)
#   --dry-run          Show what would be done, don't modify anything
#   --help             Show this help

set -euo pipefail

# Defaults
BOT_ID=""
WORKSPACE_PATH=""
DRY_RUN=false
CLAUDE_BIN="claude"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --bot-id)
      BOT_ID="$2"
      shift 2
      ;;
    --workspace-path)
      WORKSPACE_PATH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help)
      head -n 15 "$0" | tail -n +2
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Run with --help for usage"
      exit 1
      ;;
  esac
done

# Validate required args
if [[ -z "$BOT_ID" ]]; then
  echo "Error: --bot-id is required"
  echo "Run with --help for usage"
  exit 1
fi

# Set default workspace path
if [[ -z "$WORKSPACE_PATH" ]]; then
  WORKSPACE_PATH="/barkpark/workspaces/$BOT_ID"
fi

echo "========================================"
echo "BarkBot Setup"
echo "========================================"
echo ""
echo "Bot ID: $BOT_ID"
echo "Workspace: $WORKSPACE_PATH"
echo "Dry Run: $DRY_RUN"
echo ""

# Function to execute or show command
run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] $*"
  else
    echo "[EXEC] $*"
    "$@"
  fi
}

# 1. Check Claude Code
echo "Step 1: Checking Claude Code installation..."
if command -v "$CLAUDE_BIN" &> /dev/null; then
  CLAUDE_PATH=$(command -v "$CLAUDE_BIN")
  echo "✓ Claude Code found: $CLAUDE_PATH"
  
  # Check version (may fail if not authenticated, that's OK)
  CLAUDE_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null || echo "unknown")
  echo "  Version: $CLAUDE_VERSION"
else
  echo "✗ Claude Code not found"
  echo ""
  echo "Please install from: https://code.claude.com/docs/en/setup"
  echo ""
  echo "Example (Debian/Ubuntu):"
  echo "  wget https://storage.googleapis.com/claude-code/latest/claude-code_amd64.deb"
  echo "  sudo dpkg -i claude-code_amd64.deb"
  exit 1
fi

# 2. Check authentication
echo ""
echo "Step 2: Checking Claude Code authentication..."
AUTH_STATUS="unknown"

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  echo "✓ CLAUDE_CODE_OAUTH_TOKEN environment variable is set"
  AUTH_STATUS="authenticated"
elif [[ -f ~/.config/claude-code/token ]]; then
  echo "✓ Token file exists: ~/.config/claude-code/token"
  AUTH_STATUS="authenticated"
else
  echo "⚠ No authentication detected"
  echo ""
  echo "After setup completes, run:"
  echo "  claude setup-token"
  AUTH_STATUS="not_authenticated"
fi

# 3. Create workspace directory
echo ""
echo "Step 3: Creating workspace directory..."
if [[ -d "$WORKSPACE_PATH" ]]; then
  echo "✓ Workspace already exists: $WORKSPACE_PATH"
else
  echo "Creating workspace: $WORKSPACE_PATH"
  run_cmd sudo mkdir -p "$WORKSPACE_PATH"
  
  # Set ownership to barkpark user if it exists
  if id -u barkpark &>/dev/null; then
    run_cmd sudo chown barkpark:barkpark "$WORKSPACE_PATH"
    echo "✓ Set ownership to barkpark:barkpark"
  else
    echo "⚠ User 'barkpark' doesn't exist, leaving as root"
    echo "  Consider creating: sudo useradd -m -s /bin/bash barkpark"
  fi
  
  run_cmd sudo chmod 755 "$WORKSPACE_PATH"
  echo "✓ Set permissions: 755"
fi

# 4. Test workspace access
echo ""
echo "Step 4: Testing workspace access..."
if [[ "$DRY_RUN" == false ]]; then
  if [[ -w "$WORKSPACE_PATH" ]]; then
    echo "✓ Workspace is writable"
  elif sudo -u barkpark test -w "$WORKSPACE_PATH" 2>/dev/null; then
    echo "✓ Workspace is writable by barkpark user"
  else
    echo "⚠ Workspace may not be writable, check permissions"
  fi
fi

# 5. Detect host info
echo ""
echo "Step 5: Detecting host information..."
HOSTNAME=$(hostname)
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "unknown")

if [[ "$(uname)" == "Linux" ]]; then
  MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  MEMORY_GB=$(echo "scale=1; $MEMORY_KB / 1024 / 1024" | bc)
elif [[ "$(uname)" == "Darwin" ]]; then
  MEMORY_BYTES=$(sysctl -n hw.memsize)
  MEMORY_GB=$(echo "scale=1; $MEMORY_BYTES / 1024 / 1024 / 1024" | bc)
else
  MEMORY_GB="unknown"
fi

# Detect location from hostname
if [[ "$HOSTNAME" == *"nbg"* ]]; then
  LOCATION="Hetzner Nuremberg"
elif [[ "$HOSTNAME" == *"fsn"* ]]; then
  LOCATION="Hetzner Falkenstein"
elif [[ "$HOSTNAME" == *"hel"* ]]; then
  LOCATION="Hetzner Helsinki"
else
  LOCATION="Unknown location"
fi

echo "✓ Hostname: $HOSTNAME"
echo "✓ CPU Cores: $CPU_CORES"
echo "✓ Memory: ${MEMORY_GB} GB"
echo "✓ Location: $LOCATION"

# 6. Output summary
echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""

if [[ "$AUTH_STATUS" != "authenticated" ]]; then
  echo "⚠ NEXT STEP: Authenticate Claude Code"
  echo "  Run: claude setup-token"
  echo ""
fi

echo "Bot Configuration:"
echo ""
cat <<EOF
{
  "bot_id": "$BOT_ID",
  "name": "$BOT_ID",
  "description": "BarkBot on $HOSTNAME",
  "provider": "claude-code",
  "claude_bin_path": "$CLAUDE_PATH",
  "workspace_path": "$WORKSPACE_PATH",
  "hostname": "$HOSTNAME",
  "cpu_cores": $CPU_CORES,
  "memory_gb": $MEMORY_GB,
  "location": "$LOCATION",
  "enabled": true
}
EOF

echo ""
echo "Use this JSON to create the bot via API or UI."
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "This was a DRY RUN - nothing was modified."
  echo "Run without --dry-run to apply changes."
fi
