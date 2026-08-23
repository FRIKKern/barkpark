#!/usr/bin/env bash
# Edge-safety gate: no `node:` imports allowed in edge-reachable code paths
# (see the ADR-002 edge-contract row in docs/decisions/deferred.md).
set -euo pipefail
DIRS=(
  "packages/core/src"
  "packages/nextjs/src/client"
  "packages/nextjs/src/server"
  "packages/nextjs/src/webhook"
  "packages/nextjs/src/draft-mode"
  "packages/nextjs/src/csp"
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
