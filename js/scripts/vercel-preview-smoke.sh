#!/usr/bin/env bash
# TODO(Phase-5): wire three smoke assertions:
#   1. One RSC page renders
#   2. One edge route responds
#   3. client.listen() throws on edge runtime
set -euo pipefail
URL="${1:-}"
if [ -z "$URL" ]; then echo "usage: $0 <preview-url>" >&2; exit 2; fi
echo "vercel-preview-smoke: stub (Phase 5)"
echo "preview url: $URL"
exit 0
