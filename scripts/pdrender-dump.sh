#!/usr/bin/env bash
# Render a PortableDoc fixture through the real terminal renderer, offline.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: scripts/pdrender-dump.sh <paper.json> [width]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$1"
WIDTH="${2:-80}"

cd "$ROOT"
exec env CC=/usr/bin/clang go run ./internal/pdrender/cmd/dump "$FIXTURE" "$WIDTH"
