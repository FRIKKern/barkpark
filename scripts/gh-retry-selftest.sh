#!/usr/bin/env bash
# gh-retry-selftest.sh — executable proof that scripts/gh-retry.sh RETRIES the
# transient class and FAILS FAST on everything else (task-86883bb93fe61df7).
#
# Each arm points GH_BIN at a stub that replays a scripted sequence of real gh
# error strings (copied verbatim from the failing release-artifact.yml runs) and
# counts its own invocations, so an arm asserts BOTH the exit code AND the
# number of attempts. An arm that merely checked the exit code would pass on a
# retry loop that never looped.
#
# Run:  bash scripts/gh-retry-selftest.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETRY="$ROOT/scripts/gh-retry.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# Build a stub `gh` that emits $1..$n on successive calls. A line of "OK" means
# exit 0; anything else is printed to stderr and exits 1.
make_stub() {
  local name="$1"; shift
  local stub="$WORK/$name"
  mkdir -p "$stub"
  : > "$stub/count"
  printf '%s\n' "$@" > "$stub/script"
  cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
n=$(( $(cat "$d/count") + 1 ))
echo "$n" > "$d/count"
line="$(sed -n "${n}p" "$d/script")"
[ -z "$line" ] && line="$(tail -n 1 "$d/script")"
if [ "$line" = "OK" ]; then
  echo "Created release build-deadbeef"
  exit 0
fi
echo "$line" >&2
exit 1
STUB
  chmod +x "$stub/gh"
  printf '%s' "$stub"
}

arm() {
  local label="$1" expect_rc="$2" expect_calls="$3" stub="$4"
  echo
  echo "=== ARM: $label"
  local out rc calls
  out="$(GH_BIN="$stub/gh" GH_RETRY_MAX_ATTEMPTS="${ARM_MAX:-5}" GH_RETRY_BASE_SLEEP=0 \
        bash "$RETRY" release upload build-deadbeef artifact/api-build.tar.zst --clobber 2>&1)"
  rc=$?
  calls="$(cat "$stub/count")"
  printf '%s\n' "$out"
  echo "--- exit=$rc (expected $expect_rc)   gh invocations=$calls (expected $expect_calls)"
  if [ "$rc" = "$expect_rc" ] && [ "$calls" = "$expect_calls" ]; then
    echo "--- PASS"; pass=$((pass+1))
  else
    echo "--- FAIL"; fail=$((fail+1))
  fi
}

# (a) NON-RETRYABLE: a real error must fail fast and loud — one call, no loop.
arm "422 Validation Failed is NOT retryable -> fails on attempt 1" 1 1 \
  "$(make_stub nonretryable \
      'HTTP 422: Validation Failed (https://api.github.com/repos/FRIKKern/barkpark/releases)')"

# (a2) THE QUIET ARM for the unexplained-403 widening. A permission 403 carries a
# MESSAGE, so it is not the unexplained class and must still die on attempt 1. If
# the widening is ever loosened to "any 403", this arm reads 3 calls and FAILS.
arm "403 permission denied is NOT retryable -> fails on attempt 1" 1 1 \
  "$(make_stub forbidden \
      'HTTP 403: Resource not accessible by integration (https://api.github.com/repos/FRIKKern/barkpark/releases)')"

# (a3) SECOND QUIET ARM: a 403 explained with a message we have never seen before
# is still EXPLAINED, so it is still one call. Guards the classifier against
# keying on a permission-word allowlist instead of on the presence of a message.
arm "403 with an unfamiliar message still fails on attempt 1" 1 1 \
  "$(make_stub explained403 \
      'HTTP 403: Repository rulesets forbid this operation (https://api.github.com/repos/FRIKKern/barkpark/releases)')"

# (b3) THE ARM THAT REDS WHEN THE UNEXPLAINED-403 FIX IS REVERTED. Verbatim from
# run 35289781362 (job `build`, main @ 9ef5d7223): a 403 with NO message at all.
# Before the fix this exits 1 after ONE call ("NOT retryable, failing fast") and
# throws away a completed prod compile. After it, one retry clears it.
arm "unexplained HTTP 403 once -> succeeds on attempt 2" 0 2 \
  "$(make_stub bare403 \
      'error checking for existing release: HTTP 403 (https://api.github.com/repos/FRIKKern/barkpark/releases/tags/build-9ef5d7223d9bcb2fe2e216979677260886372682)' \
      'OK')"

# (c2) THE UNEXPLAINED 403 IS BOUNDED BY ITS OWN BUDGET, NOT THE GENERAL ONE.
# GH_RETRY_MAX_ATTEMPTS is the default 5 here; a permanently unexplained 403 must
# stop at GH_RETRY_MAX_403_ATTEMPTS (3). An arm asserting only "exit 1" would pass
# on a loop that burned all 5 — the call COUNT is the whole assertion.
arm "persistent unexplained 403 -> bounded at 3 calls, not 5" 1 3 \
  "$(make_stub bare403persist \
      'error checking for existing release: HTTP 403 (https://api.github.com/repos/FRIKKern/barkpark/releases/tags/build-deadbeef)')"

# (b) RETRYABLE: the verbatim 500 from run 35271553511, twice, then success.
arm "HTTP 500 Error saving asset twice -> succeeds on attempt 3" 0 3 \
  "$(make_stub transient500 \
      'HTTP 500: Error saving asset (https://uploads.github.com/repos/FRIKKern/barkpark/releases/391043232/assets?label=&name=api-build.tar.zst)' \
      'HTTP 500: Error saving asset (https://uploads.github.com/repos/FRIKKern/barkpark/releases/391043232/assets?label=&name=api-build.tar.zst)' \
      'OK')"

# (b2) The verbatim 403 rate-limit from run 35255063820, once, then success.
arm "HTTP 403 rate limit exceeded once -> succeeds on attempt 2" 0 2 \
  "$(make_stub ratelimit \
      'HTTP 403: API rate limit exceeded for installation. If you reach out to GitHub Support for help, please include the request ID CB81:1CD1:5C701D:80F905:6AAC28DC (https://uploads.github.com/repos/FRIKKern/barkpark/releases/390935006/assets?label=&name=api-build.tar.zst)' \
      'OK')"

# (c) BOUNDED: a persistent outage stops at MAX_ATTEMPTS instead of burning the runner.
ARM_MAX=3 arm "persistent 503 -> bounded at 3 attempts, then fails" 1 3 \
  "$(make_stub persistent 'HTTP 503: Service Unavailable (https://uploads.github.com/)')"

echo
echo "=== gh-retry selftest: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
