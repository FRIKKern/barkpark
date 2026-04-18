#!/usr/bin/env bash
# Enforces ADR-002 L27 + masterplan L169:
# No `node:` imports allowed in edge-reachable code paths.
set -euo pipefail
DIRS=(
  "packages/core/src"
  "packages/nextjs/src/client"
  "packages/nextjs/src/server"
  "packages/nextjs/src/webhook"
  "packages/nextjs/src/draft-mode"
)
HITS=0
for dir in "${DIRS[@]}"; do
  if [ ! -d "$dir" ]; then continue; fi
  if grep -RnE "from ['\"]node:" "$dir" 2>/dev/null; then
    echo "FAIL: node: import found in $dir"
    HITS=$((HITS+1))
  fi
  if grep -RnE "require\(['\"]node:" "$dir" 2>/dev/null; then
    echo "FAIL: node: require found in $dir"
    HITS=$((HITS+1))
  fi
done
if [ "$HITS" -gt 0 ]; then
  echo "check-no-node-imports: $HITS violation(s)"
  exit 1
fi
echo "check-no-node-imports: clean"
