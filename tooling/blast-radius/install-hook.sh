#!/bin/sh
# Installs the blast-radius pre-push hook into .git/hooks (additive, local-only,
# reversible — does not touch core.hooksPath or any existing pre-commit hook).
set -e
ROOT=$(git rev-parse --show-toplevel)
HOOK_DIR="$ROOT/.git/hooks"
SRC="$ROOT/tooling/blast-radius/pre-push"
DEST="$HOOK_DIR/pre-push"
if [ -e "$DEST" ] && ! grep -q "blast-radius" "$DEST" 2>/dev/null; then
  echo "refusing to overwrite existing $DEST (not a blast-radius hook)"; exit 1
fi
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "installed: $DEST"
echo "next: node tooling/blast-radius/build-index.mjs   # build the cached graph"
