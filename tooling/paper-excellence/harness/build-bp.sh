#!/usr/bin/env bash
# build-bp.sh — build the bp binary the cold run consumes, from this checkout.
#
#   bash tooling/paper-excellence/harness/build-bp.sh [out-path]
#
# Two traps this script exists to encode, both proven in the wave-7 verify
# round (ledger: pe-w7-slice-binary-scaffold-proof):
#
#   1. A repo-root `go build` fails — there is no `main` package at the root;
#      the CLI entrypoint is ./cmd/barkpark. Building the wrong directory dies
#      with "no Go files in <root>", so this script always names ./cmd/barkpark.
#   2. `cc` is a shell ALIAS for a claude wrapper on this host (see the router's
#      "cc-alias-shadows-compiler" gotcha). A cgo build therefore invokes the
#      wrong compiler. CGO_ENABLED=0 avoids the C toolchain entirely, and
#      CC=/usr/bin/clang pins the real compiler for the belt-and-braces case.
#
# The build is followed by a `bp version` smoke — a binary that builds but
# cannot print its own version is not a binary the cold run can trust.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../../.." && pwd)"

OUT_PATH="${1:-${BP_OUT:-$HARNESS_DIR/.bin/bp}}"
case "$OUT_PATH" in
  /*) : ;;
  *) OUT_PATH="$(cd "$(dirname "$OUT_PATH")" 2>/dev/null && pwd)/$(basename "$OUT_PATH")" || {
        echo "build-bp: cannot resolve out-path $OUT_PATH" >&2; exit 2; } ;;
esac
mkdir -p "$(dirname "$OUT_PATH")"

echo "build-bp: building ./cmd/barkpark -> $OUT_PATH"
( cd "$REPO_ROOT" && CGO_ENABLED=0 CC=/usr/bin/clang go build -o "$OUT_PATH" ./cmd/barkpark )

if [ ! -x "$OUT_PATH" ]; then
  echo "build-bp: FAIL — no executable at $OUT_PATH after build" >&2
  exit 1
fi

echo "build-bp: smoke — $OUT_PATH version"
SMOKE="$("$OUT_PATH" version 2>&1)" || {
  echo "build-bp: FAIL — the built binary cannot print its version:" >&2
  echo "$SMOKE" >&2
  exit 1
}
echo "$SMOKE"
echo "build-bp: PASS — $OUT_PATH"
# The path is the last line on stdout so a caller can `BP=$(build-bp.sh | tail -1)`.
printf '%s\n' "$OUT_PATH"
