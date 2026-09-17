#!/usr/bin/env bash
set -euo pipefail

# THRESHOLD DECISION — `--exit Low` STAYS (2026-09-17, api/r21w6).
# The workflow runs `mix sobelow --skip --exit Low`. The recurring proposal to
# relax it to `--exit Medium` is REFUSED, and this is the measurement behind
# the refusal (Elixir 1.19.5/OTP28, api/ at the shrink to 24 baseline rows):
#
#   mix sobelow --format compact            -> 214 findings: 18 high, 10 medium, 186 low
#   mix sobelow --skip --format compact     ->   0 findings
#   mix sobelow --skip --exit Low           ->   exit 0
#
#   the 24 baseline rows, keyed file:line against that 214: 7 high, 0 medium, 17 low
#
# Two things follow. (1) `--exit Low` costs NOTHING today — with the baseline
# applied the run is empty, so Low and Medium are the same verdict, and the
# threshold is not what keeps the job advisory. (2) Dropping to Medium would
# permanently blind the gate to 186 of the 214 findings this codebase carries:
# Traversal.FileModule, DOS.StringToAtom and XSS.Raw are ALL reported at low
# confidence, and those three families are exactly what the inline-annotation
# migration exists to make reviewable. A gate that cannot see the class you are
# curating is not a gate.
#
# The older note that "50 of the 51 gate-reddening findings are Low, so Medium
# would leave one" was measured on 2026-07-27 and is STALE: zero findings red
# the gate at either threshold now. Re-measure with the three commands above
# before re-opening this; do not quote the integers, quote the commands.

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

# THE SET DIFF — the artifact a reviewer can actually act on.
#
# `sobelow-skips.diff` above is a LINE diff of two files whose ROW ORDER is
# non-deterministic: `--mark-skip-all` re-emits the same finding set in a
# different order on every run. MEASURED on run 35250633882 (main 8bd4a8c1a,
# Elixir 1.18.1 / OTP 27): that line diff showed 10 removed and 10 added rows
# while the row SET was byte-identical to the committed baseline — 24 rows both
# sides, zero membership change. A reviewer reading it would have been asked to
# adjudicate twenty rows, none of which changed anything.
#
# So the reconciliation now also emits a membership-only verdict. The question
# that matters is "does the regenerated baseline SWALLOW anything the committed
# one did not", and only an ADDED row answers yes. Its exit code is recorded,
# never enforced here: this script produces an artifact for human review and
# must not start failing the job on a finding-set change it was built to REPORT.
setdiff_status=0
bash "$API_DIR/scripts/sobelow-baseline-setdiff.sh" "$backup" "$BASELINE" \
  > "$ARTIFACT_DIR/sobelow-skips.setdiff" 2>&1 || setdiff_status=$?

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
  printf 'setdiff_exit=%s  # 0 membership identical, 1 membership changed, 2 fail-closed\n' "$setdiff_status"
  grep -E '^(membership_added|membership_removed|reordering_only)=' \
    "$ARTIFACT_DIR/sobelow-skips.setdiff" || true
  printf 'review=human-required;never-auto-commit\n'
} > "$ARTIFACT_DIR/metadata.txt"

restore_baseline
trap - EXIT
if ! cmp -s -- "$backup" "$BASELINE"; then
  echo "error: tracked baseline was not restored byte-for-byte" >&2
  exit 1
fi
printf 'Sobelow reconciliation artifact ready for human review: %s\n' "$ARTIFACT_DIR"
