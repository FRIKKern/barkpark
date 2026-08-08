#!/usr/bin/env bash
# check-deploy-smoke.sh — the "can this gate actually lose?" tripwire for the
# control-plane smoke test in the production deploy workflow (charter D344).
#
# THE BUG THIS EXISTS FOR
#
# .github/workflows/deploy.yml's control-plane job ends in a Smoke test that was
# the LAST gate in the control-plane deploy path — and it could not fail on the
# failure that actually happened:
#
#   code="$(curl ... "https://barkpark.cloud/")"
#   echo "$code" | grep -qE '^(200|301|302|404)$'
#
# It ACCEPTED 404, and `/` is `send_dashboard/1` -> send_file(200,
# priv/static/index.html) with ZERO Repo access in the path. So the probe was
# STRUCTURALLY INCAPABLE of failing on a DB-dead box: a box serving nothing but
# a 404 handler passed. Proven live, without touching prod:
# `curl https://barkpark.cloud/definitely-not-a-route-xyz` -> 404, accepted.
#
# The fix already existed 80 lines away, in deploy/cp-deploy.sh:129-141, whose
# own comment names the incident: the '/' gate "stayed green through a 16h
# outage where every DB-backed route 500'd", so the inner script requires a
# bad-creds POST /v1/auth/login to answer 401 before it flips slots. The INNER
# script was backstopped; the OUTER workflow smoke was not. (deploy.yml's
# INSTANCE job is the counterexample proving that asymmetry is a defect, not a
# design: it is a hard `test "$code" = "200"` on the DB-touching /api/schemas.)
#
# THE ASSERTIONS, against the real deploy.yml
#
#   1. 404 is NOT in the control-plane smoke's accept-list for `/`.
#   2. A DB-touching login probe is present in that same step, asserting
#      EXACTLY 401 — so 5xx (500 storm) and 000 (dead box / dead pool) fail.
#   3. That probe uses an invalid address on the reserved .example TLD, so no
#      credential and no authentication is introduced by the gate itself.
#
# `--selftest` PROVES the tripwire on temp copies (plants nothing in the tree):
# the real file passes, a copy with 404 re-added FAILS, and a copy with the
# login probe deleted FAILS. A guard that cannot lose is a sentence with an exit
# code. Modelled on scripts/check-deployyml-filters.sh, the house pattern.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_YML_DEFAULT=".github/workflows/deploy.yml"

# ── extraction ───────────────────────────────────────────────────────────────

# The control-plane job's `Smoke test` step, verbatim. Job boundaries are the
# 2-space keys under `jobs:`; step boundaries EVERY 6-space `- ` list item — so
# the instance job's (already-correct) smoke can never be mistaken for this one,
# and neither can a later step of this job.
#
# The step boundary is `- `, not `- name: `, because a step is not required to
# have a name. Keying on `- name: ` meant an UNNAMED trailing step (`- run: |`,
# `- uses:`) never closed the smoke, so its body was read as part of the smoke:
# deleting the /v1/auth/login DB probe from the real probe and echoing those
# same strings from a trailing recorder step read
# `OK: the control-plane smoke can fail on a DB-dead box` — a full false green
# on exactly the invariant this file exists to hold. The deploy job cannot be
# allowed to satisfy its own gate with a log line.
extract_cp_smoke() {
  awk '
    /^  [a-zA-Z0-9_-]+:/ {
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job)
      instep = 0
    }
    job == "control-plane" && /^      - / { instep = ($0 ~ /^      - name: .*Smoke test/) ? 1 : 0 }
    job == "control-plane" && instep { print }
  ' "$1"
}

# ── the check ────────────────────────────────────────────────────────────────

check_file() {
  local yml="$1" label="$2"
  local failures=0

  local step
  step="$(extract_cp_smoke "$yml" || true)"
  if [ -z "$step" ]; then
    echo "FAIL[$label]: no 'Smoke test' step found in the control-plane job — the extractor is broken, not the workflow" >&2
    echo "Cause, in order of likelihood:" >&2
    echo "  1. A line indented EXACTLY two spaces and ending in ':' appeared inside the control-plane job" >&2
    echo "     — typically a heredoc body written at that indent inside a 'run: |' block. extract_cp_smoke" >&2
    echo "     reads that line as the next JOB key, so everything after it is attributed to a job named" >&2
    echo "     after your heredoc line and the smoke step is never seen. Re-indent the heredoc body." >&2
    echo "  2. The step was renamed: the boundary matches '      - name: ' containing 'Smoke test'." >&2
    echo "  3. The job was renamed from 'control-plane'." >&2
    return 1
  fi

  # 1. the '/' accept-list must exist, and must not accept 404.
  local accept
  accept="$(printf '%s\n' "$step" | grep -oE "grep -qE '\^\([0-9|]+\)\\\$'" | head -n1 || true)"
  if [ -z "$accept" ]; then
    echo "FAIL[$label]: no HTTP accept-list regex (grep -qE '^(...)\$') in the control-plane smoke — the extractor is broken, or the probe was rewritten" >&2
    failures=$((failures + 1))
  elif printf '%s\n' "$accept" | grep -q '404'; then
    echo "  DRIFT    accept-list accepts 404: $accept" >&2
    echo "           '/' is send_dashboard -> send_file(200, index.html), no Repo in the path:" >&2
    echo "           a 404-accepting gate certifies a box serving nothing but a 404 handler." >&2
    failures=$((failures + 1))
  else
    echo "  ok       accept-list rejects 404  ->  $accept"
  fi

  # 2. a DB-touching login probe asserting EXACTLY 401.
  if ! printf '%s\n' "$step" | grep -q '/v1/auth/login'; then
    echo "  DRIFT    no /v1/auth/login probe in the control-plane smoke — nothing in this gate touches the DB" >&2
    echo "           (mirror deploy/cp-deploy.sh:129-141: bad-creds login must answer 401)" >&2
    failures=$((failures + 1))
  elif ! printf '%s\n' "$step" | grep -qE '=[[:space:]]*"?401"?[[:space:]]*$'; then
    echo "  DRIFT    the login probe does not assert EXACTLY 401 — 5xx/000 could pass" >&2
    failures=$((failures + 1))
  else
    echo "  ok       login probe present and pinned to 401 (5xx/000 fail the step)"
  fi

  # 3. no credential smuggled in: the probe address is deliberately invalid.
  if printf '%s\n' "$step" | grep -q '/v1/auth/login' \
     && ! printf '%s\n' "$step" | grep -q '@invalid\.example'; then
    echo "  DRIFT    the login probe does not use an invalid .example address — a deploy gate must introduce no credential" >&2
    failures=$((failures + 1))
  fi

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures control-plane smoke invariant(s) broken." >&2
    echo "Fix: the smoke step must reject 404 on '/' AND require a bad-creds POST to" >&2
    echo "/v1/auth/login to answer exactly 401, mirroring deploy/cp-deploy.sh:129-141." >&2
    return 1
  fi

  echo "OK[$label]: the control-plane smoke can fail on a DB-dead box."
  return 0
}

# ── selftest ─────────────────────────────────────────────────────────────────

selftest() {
  # No RETURN trap: bash 3.2 (macOS) does not scope one to this function, so it
  # re-fires in the caller where $tmp is gone and `set -u` kills the run AFTER a
  # green selftest — a false red, the exact dishonesty this file is about.
  local tmp
  tmp="$(mktemp -d)"

  local real="$REPO_ROOT/$DEPLOY_YML_DEFAULT"
  local rc=0

  echo "selftest 1/4: the real workflow passes"
  if ! check_file "$real" "real"; then
    echo "SELFTEST FAIL: the real deploy.yml does not pass" >&2
    rc=1
  fi

  echo
  echo "selftest 2/4: re-adding 404 to the accept-list must FAIL (the original bug)"
  sed "s/\^(200|301|302)\\\$/^(200|301|302|404)\$/" "$real" > "$tmp/mutated404.yml"
  if cmp -s "$real" "$tmp/mutated404.yml"; then
    echo "SELFTEST FAIL: the mutation changed nothing — the accept-list no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/mutated404.yml" "mutated404" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a 404-accepting smoke read GREEN — the gate cannot fail" >&2
    rc=1
  else
    echo "  ok: the gate reds when 404 comes back into the accept-list"
  fi

  echo
  echo "selftest 3/4: deleting the DB (login) probe must FAIL"
  awk '
    /dbcode="\$\(curl/ { drop = 1 }
    !drop { print }
    drop && /test "\$dbcode" = "401"/ { drop = 0 }
  ' "$real" > "$tmp/noprobe.yml"
  if cmp -s "$real" "$tmp/noprobe.yml"; then
    echo "SELFTEST FAIL: the probe-deletion changed nothing — the probe no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/noprobe.yml" "noprobe" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a smoke with no DB probe read GREEN" >&2
    rc=1
  else
    echo "  ok: the gate reds when the DB probe is removed"
  fi

  echo
  echo "selftest 4/4: an UNNAMED trailing step must not be absorbed into the smoke"
  # The disarm shape, verbatim: the probe is deleted from the smoke and its
  # strings reappear in a later, unnamed `- run:` step of the same job — where
  # they assert nothing. Before the step boundary became `- ` this read
  # "OK: the control-plane smoke can fail on a DB-dead box".
  awk '
    /dbcode="\$\(curl/ { drop = 1 }
    !drop && /^  instance:/ {
      print "      - run: |"
      print "          echo \047probe reference: /v1/auth/login bad creds should be 401\047"
      print "          echo \047address used elsewhere: probe@invalid.example\047"
      print "          : \"$dbcode\" = \"401\""
      print ""
    }
    !drop { print }
    drop && /test "\$dbcode" = "401"/ { drop = 0 }
  ' "$real" > "$tmp/trailing.yml"
  if ! grep -q 'probe reference' "$tmp/trailing.yml"; then
    echo "SELFTEST FAIL: the trailing-step injection changed nothing" >&2
    rc=1
  elif check_file "$tmp/trailing.yml" "trailing" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a trailing step's echo satisfied the smoke's invariants — the gate is disarmable" >&2
    rc=1
  else
    echo "  ok: only the Smoke test step's own body answers for the invariants"
  fi

  rm -rf "$tmp"

  echo
  if [ "$rc" -eq 0 ]; then
    echo "SELFTEST OK — the tripwire can both pass and fail."
  fi
  return "$rc"
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    --selftest) selftest ;;
    "")         check_file "$REPO_ROOT/$DEPLOY_YML_DEFAULT" "deploy.yml" ;;
    *)          check_file "$1" "$(basename "$1")" ;;
  esac
}

main "$@"
