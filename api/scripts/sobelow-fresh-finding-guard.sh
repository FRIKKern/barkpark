#!/usr/bin/env bash
set -euo pipefail

API_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROBE="$API_DIR/lib/barkpark/sobelow_fresh_finding_guard.ex"
QUARANTINE=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-fresh-finding.XXXXXX")
OUTPUT="$QUARANTINE/sobelow.out"

if [[ -e $PROBE ]]; then
  echo "error: refusing to overwrite existing probe path: $PROBE" >&2
  exit 2
fi
cleanup() {
  if [[ -e $PROBE ]]; then
    mv -f -- "$PROBE" "$QUARANTINE/sobelow_fresh_finding_guard.ex"
  fi
}
trap cleanup EXIT

cat > "$PROBE" <<'PROBE'
defmodule Barkpark.SobelowFreshFindingGuard do
  def leak(key), do: String.to_atom(key)
end
PROBE

set +e
(
  cd -- "$API_DIR"
  CC="${CC:-/usr/bin/clang}" mix sobelow --skip --exit Low
) >"$OUTPUT" 2>&1
status=$?
set -e
cat "$OUTPUT"

if [[ $status -ne 1 ]]; then
  echo "error: expected fresh Sobelow finding to exit 1, got $status" >&2
  exit 1
fi
if ! grep -q 'DOS.StringToAtom' "$OUTPUT" ||
   ! grep -q 'sobelow_fresh_finding_guard.ex' "$OUTPUT"; then
  echo "error: Sobelow red did not identify the planted String.to_atom finding" >&2
  exit 1
fi

cleanup
trap - EXIT
if [[ -e $PROBE ]]; then
  echo "error: planted Sobelow probe was not removed from the worktree" >&2
  exit 1
fi
printf 'PASS: fresh unskipped DOS.StringToAtom finding red; probe restored absent\n'
