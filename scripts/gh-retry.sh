#!/usr/bin/env bash
# gh-retry.sh — run ONE `gh` invocation with a bounded retry on transient
# upstream faults only.
#
# WHY (task-86883bb93fe61df7): .github/workflows/release-artifact.yml publishes
# the precompiled api/_build artifact with `gh release create` / `gh release
# upload`. Those calls had no retry, so a single transient GitHub upload-API
# fault reddened main's tip AND threw away a completed Elixir prod compile.
# Both failures measured on 2026-09-17 were upstream, not the commit:
#   run 35271553511 (0a3c99cc3): HTTP 500: Error saving asset (uploads.github.com)
#   run 35255063820 (01f82c949): HTTP 403: API rate limit exceeded for installation
# — with run 35263849125 (8ba623ca5) succeeding between them.
#
# THE POINT IS THE CLASSIFIER, NOT THE LOOP. A blanket `|| retry` would swallow
# real breakage. Only these retry:
#   * any HTTP 5xx (500/502/503/504 and friends)
#   * HTTP 403 whose body says rate limit / secondary rate limit / abuse detection
#   * transport faults (timeout, connection reset/refused, EOF, TLS handshake)
# Everything else — 401, 404, 409, 422, a plain permission-denied 403, bad args,
# a missing file — exits immediately with gh's own status and gh's own message.
#
# Usage:  bash scripts/gh-retry.sh release upload "$TAG" file... --clobber
# Env:    GH_RETRY_MAX_ATTEMPTS (default 5)
#         GH_RETRY_BASE_SLEEP   (seconds, default 5; doubles per attempt, cap 60)
#         GH_BIN                (default "gh"; the selftest points it at a stub)
set -uo pipefail

MAX_ATTEMPTS="${GH_RETRY_MAX_ATTEMPTS:-5}"
BASE_SLEEP="${GH_RETRY_BASE_SLEEP:-5}"
GH_BIN="${GH_BIN:-gh}"

if [ "$#" -eq 0 ]; then
  echo "[gh-retry] usage: gh-retry.sh <gh args...>" >&2
  exit 2
fi

# Returns 0 when the captured gh output describes a fault worth retrying.
gh_retry_is_retryable() {
  local out="$1"
  # 5xx from the API or the uploads host.
  if [[ "$out" =~ HTTP\ 5[0-9][0-9] ]]; then return 0; fi
  # Throttling. GitHub returns these as 403 (primary/secondary limits) or 429.
  if [[ "$out" =~ HTTP\ 429 ]]; then return 0; fi
  if [[ "$out" =~ [Rr]ate\ limit\ exceeded ]] \
  || [[ "$out" =~ [Ss]econdary\ rate\ limit ]] \
  || [[ "$out" =~ abuse\ detection ]] \
  || [[ "$out" =~ submitted\ too\ quickly ]]; then return 0; fi
  # Transport-level faults never reach an HTTP status at all.
  if [[ "$out" =~ [Tt]imeout ]] \
  || [[ "$out" =~ [Tt]imed\ out ]] \
  || [[ "$out" =~ connection\ reset ]] \
  || [[ "$out" =~ connection\ refused ]] \
  || [[ "$out" =~ unexpected\ EOF ]] \
  || [[ "$out" =~ EOF$ ]] \
  || [[ "$out" =~ TLS\ handshake ]] \
  || [[ "$out" =~ no\ such\ host ]] \
  || [[ "$out" =~ server\ misbehaving ]]; then return 0; fi
  return 1
}

# Pull the HTTP status out of gh's message for the log line, or say "no-status".
gh_retry_status_of() {
  local out="$1"
  if [[ "$out" =~ HTTP\ ([0-9]{3}) ]]; then
    printf '%s' "HTTP ${BASH_REMATCH[1]}"
  else
    printf '%s' "no-status"
  fi
}

attempt=1
sleep_for="$BASE_SLEEP"
while :; do
  echo "[gh-retry] attempt ${attempt}/${MAX_ATTEMPTS}: ${GH_BIN} $*"
  out="$("$GH_BIN" "$@" 2>&1)"
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"

  if [ "$rc" -eq 0 ]; then
    echo "[gh-retry] attempt ${attempt}: OK (exit 0)"
    exit 0
  fi

  status="$(gh_retry_status_of "$out")"

  if ! gh_retry_is_retryable "$out"; then
    echo "[gh-retry] attempt ${attempt}: ${status} exit ${rc} — NOT retryable, failing fast" >&2
    exit "$rc"
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "[gh-retry] attempt ${attempt}: ${status} exit ${rc} — retryable but attempts exhausted (${MAX_ATTEMPTS})" >&2
    exit "$rc"
  fi

  echo "[gh-retry] attempt ${attempt}: ${status} exit ${rc} — retryable, sleeping ${sleep_for}s"
  sleep "$sleep_for"
  attempt=$((attempt + 1))
  sleep_for=$((sleep_for * 2))
  [ "$sleep_for" -gt 60 ] && sleep_for=60
done
