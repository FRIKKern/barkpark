#!/usr/bin/env bash
set -euo pipefail

API_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BASELINE="$API_DIR/.sobelow-skips"
ARTIFACT_DIR=${1:-}

if [[ ${CI:-} != "true" ]]; then
  echo "error: Sobelow baseline reconciliation is CI-only" >&2
  exit 2
fi
if [[ -z $ARTIFACT_DIR ]]; then
  echo "usage: $0 ARTIFACT_DIR" >&2
  exit 2
fi

versions=$(elixir --version)
if ! grep -Eq '^Erlang/OTP 27([.[:space:]]|$)' <<<"$versions" ||
   ! grep -Eq '^Elixir 1\.18\.1([[:space:]]|$)' <<<"$versions"; then
  printf 'error: expected Elixir 1.18.1 / OTP 27, got:\n%s\n' "$versions" >&2
  exit 2
fi
if [[ ! -s $BASELINE ]]; then
  echo "error: tracked baseline is missing or empty: $BASELINE" >&2
  exit 2
fi

mkdir -p -- "$ARTIFACT_DIR"
backup=$(mktemp "${TMPDIR:-/tmp}/sobelow-skips.XXXXXX")
cp -f -- "$BASELINE" "$backup"
restore_baseline() {
  cp -f -- "$backup" "$BASELINE"
}
trap restore_baseline EXIT

(
  cd -- "$API_DIR"
  mix sobelow --clear-skip
)
if [[ -e $BASELINE ]]; then
  echo "error: mix sobelow --clear-skip did not remove the baseline" >&2
  exit 1
fi
# `--skip` is LOAD-BEARING here, not decoration. Sobelow 0.14.1 only pairs an
# inline `# sobelow_skip [...]` annotation with its function when `--skip` is
# set (sobelow.ex:420-421 — `combine_skips` short-circuits on `get_env(:skip)`),
# and the pairing suppresses the finding UPSTREAM of the writer
# (sobelow.ex:403-410 does `mods -- skip_mods`, so the check never runs).
# Without it, an inline-waived finding is generated, fingerprinted and written
# into the baseline — so the file silently swallows its own waivers, and a
# refactor that detaches an annotation from its function stops being visible.
(
  cd -- "$API_DIR"
  mix sobelow --skip --mark-skip-all
)
if [[ ! -s $BASELINE ]]; then
  echo "error: mix sobelow --skip --mark-skip-all did not create a baseline" >&2
  exit 1
fi

cp -f -- "$BASELINE" "$ARTIFACT_DIR/.sobelow-skips"
diff -u \
  --label a/api/.sobelow-skips \
  --label b/api/.sobelow-skips \
  "$backup" "$BASELINE" > "$ARTIFACT_DIR/sobelow-skips.diff" || diff_status=$?
if [[ ${diff_status:-0} -gt 1 ]]; then
  echo "error: could not diff the Sobelow baselines" >&2
  exit "$diff_status"
fi

if command -v sha256sum >/dev/null 2>&1; then
  baseline_sha=$(sha256sum "$BASELINE" | awk '{print $1}')
else
  baseline_sha=$(shasum -a 256 "$BASELINE" | awk '{print $1}')
fi
{
  printf '%s\n' "$versions"
  printf 'baseline_lines=%s\n' "$(wc -l < "$BASELINE" | tr -d ' ')"
  printf 'baseline_sha256=%s\n' "$baseline_sha"
  printf 'sequence=clear-skip,skip+mark-skip-all\n'
  printf 'review=human-required;never-auto-commit\n'
} > "$ARTIFACT_DIR/metadata.txt"

restore_baseline
trap - EXIT
if ! cmp -s -- "$backup" "$BASELINE"; then
  echo "error: tracked baseline was not restored byte-for-byte" >&2
  exit 1
fi
printf 'Sobelow reconciliation artifact ready for human review: %s\n' "$ARTIFACT_DIR"
