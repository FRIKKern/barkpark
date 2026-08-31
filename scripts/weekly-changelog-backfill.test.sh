#!/usr/bin/env bash
# Hermetic regression for the weekly-changelog backfill_all week-collection
# logic in .github/workflows/weekly-changelog.yml.
#
# A workflow YAML can't be executed locally, so this harness:
#   (a) extracts the week-collection snippet from the real workflow via
#       PyYAML and asserts it byte-for-byte matches the fixed shape, so a
#       drift back toward the old `mapfile -t weeks < <(...)` process
#       substitution (which discards the generator's exit status under
#       `set -eo pipefail`) REDs this check; and
#   (b) actually executes that extracted snippet under `set -eo pipefail`
#       against a stub `python3`, once failing (asserting a non-zero exit
#       plus an ::error:: line) and once succeeding with two weeks
#       (asserting both are collected).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/weekly-changelog.yml"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

if [ ! -f "$WORKFLOW" ]; then
  fail "workflow not found: $WORKFLOW"
fi

# ---------------------------------------------------------------------------
# Extract the "Create or refresh Barkpark Weekly editions" step's run block,
# then pull out just the if/else/fi that builds the `weeks` array.
# ---------------------------------------------------------------------------
run_block="$(python3 - "$WORKFLOW" <<'PY'
import sys
import yaml

with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)

steps = doc["jobs"]["publish"]["steps"]
for step in steps:
    if step.get("name") == "Create or refresh Barkpark Weekly editions":
        sys.stdout.write(step["run"])
        break
else:
    sys.exit("step 'Create or refresh Barkpark Weekly editions' not found in publish job")
PY
)"

# The awk state machine below stops capturing at the first column-0 `fi`,
# which is the outer if/else/fi (the inner `if [ "${#weeks[@]}" -eq 0 ]; then
# ... fi` is indented, so its `fi` does not match `^fi$`).
collection_snippet="$(printf '%s\n' "$run_block" | awk '
  /^if \[ "\$BACKFILL_ALL" = "true" \]; then$/ { capture=1 }
  capture { print }
  capture && /^fi$/ { exit }
')"

if [ -z "$collection_snippet" ]; then
  fail "could not locate the backfill_all week-collection if/else/fi in $WORKFLOW"
fi

expected_snippet='if [ "$BACKFILL_ALL" = "true" ]; then
  if ! weeks_raw="$(python3 scripts/weekly-changelog.py --list-editorial-weeks)"; then
    echo "::error::--list-editorial-weeks exited non-zero; refusing a silent no-op backfill"
    exit 1
  fi
  mapfile -t weeks <<< "$weeks_raw"
  non_empty_weeks=()
  for week in "${weeks[@]}"; do
    [ -n "$week" ] && non_empty_weeks+=("$week")
  done
  weeks=("${non_empty_weeks[@]}")
  if [ "${#weeks[@]}" -eq 0 ]; then
    echo "::error::--list-editorial-weeks produced no weeks; refusing a silent no-op backfill"
    exit 1
  fi
else
  weeks=("$WEEK")
fi'

if [ "$collection_snippet" != "$expected_snippet" ]; then
  fail "week-collection snippet in $WORKFLOW has drifted from the fixed shape.
--- expected ---
$expected_snippet
--- actual ---
$collection_snippet"
fi
echo "PASS: workflow collection snippet matches the fixed (exit-status-visible) shape"

# The fixed snippet relies on `mapfile`, a bash-4+ builtin. GitHub Actions
# runners ship bash 5, but the platform's own /bin/bash can be 3.2 (no
# mapfile at all), so find a bash new enough to actually exercise it.
find_modern_bash() {
  local candidates=() c major
  command -v bash >/dev/null 2>&1 && candidates+=("$(command -v bash)")
  candidates+=(/opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash)
  for c in "${candidates[@]}"; do
    [ -x "$c" ] || continue
    major="$("$c" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
    if [ "$major" -ge 4 ] 2>/dev/null; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

SNIPPET_BASH="$(find_modern_bash)" || fail "no bash >= 4 (mapfile support) found on PATH to exercise the snippet"

make_stub_python3() {
  local dir="$1" body="$2"
  cat > "$dir/python3" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$dir/python3"
}

# ---------------------------------------------------------------------------
# Case 1: the generator fails. The snippet, executed under set -eo pipefail,
# must halt with a non-zero exit and print an ::error:: line -- never fall
# through to an empty, silently-successful `weeks` array.
# ---------------------------------------------------------------------------
stub_dir_fail="$(mktemp -d)"
trap 'rm -rf "$stub_dir_fail" "${stub_dir_ok:-}"' EXIT
make_stub_python3 "$stub_dir_fail" 'exit 1'

set +e
fail_out="$(PATH="$stub_dir_fail:$PATH" BACKFILL_ALL=true WEEK=2026-08-03 \
  "$SNIPPET_BASH" -eo pipefail -c "$collection_snippet" 2>&1)"
fail_status=$?
set -e

if [ "$fail_status" -eq 0 ]; then
  fail "a failing generator must halt the snippet with a non-zero exit; got 0. Output:
$fail_out"
fi
if ! printf '%s' "$fail_out" | grep -q '::error::'; then
  fail "a failing generator must print an ::error:: line. Output:
$fail_out"
fi
echo "PASS: failing generator halts with non-zero exit ($fail_status) and an ::error:: line"
echo "$fail_out"

# ---------------------------------------------------------------------------
# Case 2: the generator succeeds and prints two editorial weeks. Both must
# land in the `weeks` array.
# ---------------------------------------------------------------------------
stub_dir_ok="$(mktemp -d)"
make_stub_python3 "$stub_dir_ok" 'printf "%s\n" "2026-08-03" "2026-08-10"'

ok_script="$collection_snippet"$'\nprintf "%s\\n" "${weeks[@]}"'

set +e
ok_out="$(PATH="$stub_dir_ok:$PATH" BACKFILL_ALL=true WEEK=2026-08-03 \
  "$SNIPPET_BASH" -eo pipefail -c "$ok_script" 2>&1)"
ok_status=$?
set -e

if [ "$ok_status" -ne 0 ]; then
  fail "a healthy generator must exit 0; got $ok_status. Output:
$ok_out"
fi
ok_count="$(printf '%s\n' "$ok_out" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$ok_count" -ne 2 ]; then
  fail "expected exactly 2 collected weeks; got $ok_count. Output:
$ok_out"
fi
if ! printf '%s\n' "$ok_out" | grep -qx "2026-08-03"; then
  fail "missing week 2026-08-03 in collected weeks. Output:
$ok_out"
fi
if ! printf '%s\n' "$ok_out" | grep -qx "2026-08-10"; then
  fail "missing week 2026-08-10 in collected weeks. Output:
$ok_out"
fi
echo "PASS: a healthy generator's two weeks are both collected"
echo "$ok_out"

echo "ALL PASS"
