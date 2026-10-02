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
#   * an UNEXPLAINED 403 — one gh printed with NO message at all — under a
#     separate, tighter budget (see below)
# Everything else — 401, 404, 409, 422, an EXPLAINED permission-denied 403, bad
# args, a missing file — exits immediately with gh's own status and gh's message.
#
# THE UNEXPLAINED-403 CLASS (added 2026-09-18). release-artifact.yml reddened
# main at 9ef5d7223 (run 35289781362, job `build`) with, verbatim:
#   error checking for existing release: HTTP 403 (https://api.github.com/repos/FRIKKern/barkpark/releases/tags/build-9ef5d7223d9bcb2fe2e216979677260886372682)
#   [gh-retry] attempt 1: HTTP 403 exit 1 — NOT retryable, failing fast
# Note the SHAPE: `HTTP 403 (<url>)`. No colon, no message, no rate-limit words.
# gh renders `HTTP 403: <message>` whenever the API supplies a message, and this
# bare form only when it does not — and a genuine permission denial ALWAYS
# carries one ("Resource not accessible by integration", "Must have admin
# rights to Repository", ...). So "403 with no message" is a shape a real
# permission fault does not take, and it is transient on the releases API.
#
# THE TRADEOFF, STATED: if GitHub ever starts emitting a real permission denial
# with an empty message, this retries it — so it gets its OWN budget,
# GH_RETRY_MAX_403_ATTEMPTS (default 3), NOT the general one. A permanent
# unexplained 403 therefore costs 3 calls and ~15s, not MAX_ATTEMPTS. An
# EXPLAINED 403 still fails on attempt 1, which scripts/gh-retry-selftest.sh
# arm (a2) pins.
#
# Usage:  bash scripts/gh-retry.sh release upload "$TAG" file... --clobber
# Env:    GH_RETRY_MAX_ATTEMPTS     (default 5)
#         GH_RETRY_MAX_403_ATTEMPTS (default 3; unexplained-403 budget only)
#         GH_RETRY_BASE_SLEEP       (seconds, default 5; doubles per attempt, cap 60)
#         GH_BIN                    (default "gh"; the selftest points it at a stub)
set -uo pipefail

MAX_ATTEMPTS="${GH_RETRY_MAX_ATTEMPTS:-5}"
MAX_403_ATTEMPTS="${GH_RETRY_MAX_403_ATTEMPTS:-3}"
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

# Returns 0 for a 403 that GitHub did NOT explain: the literal `HTTP 403` with
# no message after it, i.e. `HTTP 403 (<url>)` or `HTTP 403` at end of line.
# DELIBERATELY NARROW. Any 403 carrying a message — including every permission
# denial GitHub actually emits — is NOT this class and still fails fast.
gh_retry_is_unexplained_403() {
  local out="$1"
  [[ "$out" =~ HTTP\ 403 ]] || return 1
  # An explained 403 reads `HTTP 403: <message>`. If any occurrence carries a
  # colon-message, treat the whole output as explained and fail fast.
  if [[ "$out" =~ HTTP\ 403: ]]; then return 1; fi
  # Belt and braces: never retry a 403 that names a permission cause, whatever
  # punctuation it arrived with.
  if [[ "$out" =~ Resource\ not\ accessible ]] \
  || [[ "$out" =~ [Mm]ust\ have\ (admin|push|write) ]] \
  || [[ "$out" =~ not\ authorized ]] \
  || [[ "$out" =~ OAuth\ App\ access\ restrictions ]] \
  || [[ "$out" =~ SAML ]] \
  || [[ "$out" =~ [Ff]orbidden ]]; then return 1; fi
  return 0
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
unexplained403=0
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
    # SECOND CHANCE, ON ITS OWN BUDGET: the unexplained 403. See the header.
    if gh_retry_is_unexplained_403 "$out"; then
      unexplained403=$((unexplained403 + 1))
      if [ "$unexplained403" -ge "$MAX_403_ATTEMPTS" ]; then
        echo "[gh-retry] attempt ${attempt}: ${status} exit ${rc} — UNEXPLAINED 403 persisted for ${unexplained403} attempt(s) (budget ${MAX_403_ATTEMPTS}), failing fast" >&2
        exit "$rc"
      fi
      if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "[gh-retry] attempt ${attempt}: ${status} exit ${rc} — UNEXPLAINED 403 but attempts exhausted (${MAX_ATTEMPTS})" >&2
        exit "$rc"
      fi
      echo "[gh-retry] attempt ${attempt}: ${status} exit ${rc} — UNEXPLAINED 403 (no message body), retrying ${unexplained403}/$((MAX_403_ATTEMPTS - 1)), sleeping ${sleep_for}s"
      sleep "$sleep_for"
      attempt=$((attempt + 1))
      sleep_for=$((sleep_for * 2))
      [ "$sleep_for" -gt 60 ] && sleep_for=60
      continue
    fi
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
