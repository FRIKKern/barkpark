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
# THE SECOND BUG: ALIVE IS NOT NEW (dr-w21-s1)
#
# Everything above proves a box ANSWERS. Nothing proved it MOVED. A deploy that
# never flipped Caddy, or that took instance-deploy.sh's coalesce branch and
# exited 0 without touching the box, passed every probe in this file while
# production served last week's tree. So both jobs now assert ancestry: the
# served commit must be identical to, or a descendant of, ${{ github.sha }},
# via the GitHub compare API. NOT equality — cp-deploy.sh reads the sha at
# pull time, and docs-only merges land with no deploy run at all, so the box
# legitimately runs AHEAD (live: production served 572d51e13, ten commits ahead
# of the run's 7f5f10b8d, behind_by 0).
#
# AND THIS TRIPWIRE WAS STRUCTURALLY BLIND TO EXACTLY THAT ASSERTION. The old
# extractor printed only the lines inside a control-plane step literally named
# /Smoke test/. Mutation-proved: a deploy.yml carrying a full sha assertion in a
# new step named `Assert serving sha` matched ZERO extractor lines and this
# script printed OK, RC=0 — a green guard over a completely unguarded
# invariant. The extractor now takes the WHOLE job's `run:` bodies, per job, so
# a rename cannot blind it again.
#
# THE ASSERTIONS, against the real deploy.yml
#
#   1. 404 is NOT in the control-plane smoke's accept-list for `/`.
#   2. A DB-touching login probe is present in that job, asserting EXACTLY 401
#      — so 5xx (500 storm) and 000 (dead box / dead pool) fail.
#   3. That probe uses an invalid address on the reserved .example TLD, so no
#      credential and no authentication is introduced by the gate itself.
#   4. BOTH deploy jobs compare the served sha to ${{ github.sha }} through
#      `gh api .../compare/${{ github.sha }}...$served`, accept ONLY
#      `^(ahead|identical)$`, never compare the two shas for equality, split the
#      missing-key arm from the null arm (`has(...)` + `jq -er ... // empty`),
#      and bound the settle window with a cap that expires into a FAILURE.
#
# `--selftest` PROVES the tripwire on temp copies (plants nothing in the tree):
# the real file passes, and seven mutations are run — six that must RED (404
# re-added, DB probe deleted, sha assertion deleted, null arm weakened, an
# equality comparison re-introduced, the assertion removed from ONE job only)
# and one that must stay GREEN (the assertion moved into a differently-named
# step — the mutation that fooled the old extractor). A guard that cannot lose
# is a sentence with an exit code. Modelled on scripts/check-deployyml-filters.sh,
# the house pattern.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_YML_DEFAULT=".github/workflows/deploy.yml"

# ── extraction ───────────────────────────────────────────────────────────────

# Every `run:` body in ONE job, unioned — NOT one hardcoded step name.
#
# Step names are the thing that drifts: the old version of this function keyed
# off /Smoke test/ and went silently blind the moment an assertion lived in a
# step called anything else. Job boundaries (2-space keys under `jobs:`) are
# structural, so the instance job's bodies can never be mistaken for the control
# plane's — which is what makes "assertion present in the OTHER job" still a
# failure here.
#
# Only `run:` bodies are printed, never step comments: a commented-out assertion
# must not satisfy a grep. Both the `run: |` block form and the one-line
# `run: bash …` form are handled.
extract_job_runs() {
  awk -v target="$2" '
    /^  [a-zA-Z0-9_-]+:/ {
      j = $0; sub(/^  /, "", j); sub(/:.*$/, "", j)
      job = j; inrun = 0
    }
    job != target { next }
    { match($0, /^ */); ind = RLENGTH }
    inrun {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if (ind > runind) { print; next }
      inrun = 0
    }
    /^[[:space:]]*run:/ {
      runind = ind
      body = $0
      sub(/^[[:space:]]*run:[[:space:]]*/, "", body)
      if (body != "" && body !~ /^[|>]-?$/) print body
      inrun = 1
      next
    }
  ' "$1"
}

# ── the check ────────────────────────────────────────────────────────────────

# The ancestry assertion, checked inside ONE job's run bodies.
# Prints its findings; returns the number of broken invariants.
check_sha_assertion() {
  local runs="$1" label="$2" job="$3" key="$4"
  local failures=0

  # a. the comparison exists AND is the ancestor form: github.sha ...served,
  #    through the compare API (which needs no checkout — see deploy.yml).
  if ! printf '%s\n' "$runs" | grep -qE 'compare/\$\{\{[[:space:]]*github\.sha[[:space:]]*\}\}\.\.\.'; then
    echo "  DRIFT    [$job] no \`compare/\${{ github.sha }}...<served>\` call — nothing proves the box MOVED" >&2
    echo "           (a 200 proves the box is ALIVE; only the compare proves it is NEW)" >&2
    failures=$((failures + 1))
  elif ! printf '%s\n' "$runs" | grep -qF '^(ahead|identical)$'; then
    echo "  DRIFT    [$job] the compare verdict is not matched against '^(ahead|identical)\$'" >&2
    echo "           behind/diverged must FAIL; anything else is a gate that cannot lose" >&2
    failures=$((failures + 1))
  else
    echo "  ok       [$job] served sha compared to \${{ github.sha }}, accepted only on ahead|identical"
  fi

  # b. equality is REFUSED. cp-deploy.sh reads the sha at pull time and
  #    docs-only merges deploy nothing, so the box legitimately runs ahead.
  if printf '%s\n' "$runs" | grep -qE '\$served"?[[:space:]]*(==|=|!=)[[:space:]]*"?\$\{\{[[:space:]]*github\.sha' \
     || printf '%s\n' "$runs" | grep -qE 'github\.sha[[:space:]]*\}\}"?[[:space:]]*(==|=|!=)[[:space:]]*"?\$served'; then
    echo "  DRIFT    [$job] an EQUALITY comparison between the served sha and \${{ github.sha }} is back" >&2
    echo "           live counterexample: production served 572d51e13, ten commits AHEAD of the run's" >&2
    echo "           7f5f10b8d with behind_by 0 — equality reds healthy merges. Ancestry only." >&2
    failures=$((failures + 1))
  else
    echo "  ok       [$job] no equality comparison (ancestry rule intact)"
  fi

  # c. missing-key arm SPLIT from the null arm: a broken reader is not a stale
  #    box and must not be reported as one.
  if ! printf '%s\n' "$runs" | grep -qF "has(\"$key\")"; then
    echo "  DRIFT    [$job] no \`has(\"$key\")\` arm — a body without the key would fall through to the comparison" >&2
    failures=$((failures + 1))
  else
    echo "  ok       [$job] missing \`$key\` key fails on its own arm, naming the reader"
  fi

  # d. NULL arm: `jq -r` prints the four-character string `null`, which would be
  #    handed to the compare API as if it were a sha.
  if ! printf '%s\n' "$runs" | grep -qF "jq -er '.$key // empty'"; then
    echo "  DRIFT    [$job] the served sha is not read with \`jq -er '.$key // empty'\`" >&2
    echo "           \`echo '{\"$key\":null}' | jq -r '.$key'\` prints the literal string null — never let it reach the oracle" >&2
    failures=$((failures + 1))
  else
    echo "  ok       [$job] null/empty \`$key\` can never reach the oracle"
  fi

  # e. the settle window is bounded, and it expires into a FAILURE.
  if ! printf '%s\n' "$runs" | grep -qE 'SETTLE_WINDOW_S=[0-9]+'; then
    echo "  DRIFT    [$job] no bounded settle window (SETTLE_WINDOW_S=<seconds>) — an unbounded wait is a hang, not a gate" >&2
    failures=$((failures + 1))
  elif ! printf '%s\n' "$runs" | grep -qF 'expired with no verdict'; then
    echo "  DRIFT    [$job] the settle window does not expire into a FAILURE — an unverified deploy would pass" >&2
    failures=$((failures + 1))
  else
    echo "  ok       [$job] settle window is capped and expires into a failure"
  fi

  # f. a clean `behind`/`diverged` is never retried away.
  if ! printf '%s\n' "$runs" | grep -qF 'DID NOT MOVE'; then
    echo "  DRIFT    [$job] no immediate hard failure on a clean behind/diverged verdict" >&2
    failures=$((failures + 1))
  fi

  return "$failures"
}

check_file() {
  local yml="$1" label="$2"
  local failures=0

  local step instance_runs
  step="$(extract_job_runs "$yml" control-plane || true)"
  instance_runs="$(extract_job_runs "$yml" instance || true)"
  if [ -z "$step" ]; then
    echo "FAIL[$label]: no run: bodies found in the control-plane job — the extractor is broken, not the workflow" >&2
    return 1
  fi
  if [ -z "$instance_runs" ]; then
    echo "FAIL[$label]: no run: bodies found in the instance job — the extractor is broken, not the workflow" >&2
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

  # 4. BOTH targets must assert the served commit — a live box is not a new one.
  local n
  n=0; check_sha_assertion "$step" "$label" "control-plane" "git_sha" || n=$?
  failures=$((failures + n))
  n=0; check_sha_assertion "$instance_runs" "$label" "instance" "commit" || n=$?
  failures=$((failures + n))

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures deploy-smoke invariant(s) broken." >&2
    echo "Fix: the control-plane smoke must reject 404 on '/' AND require a bad-creds POST to" >&2
    echo "/v1/auth/login to answer exactly 401, mirroring deploy/cp-deploy.sh:129-141; and BOTH" >&2
    echo "deploy jobs must assert the served commit is ahead-of-or-identical-to \${{ github.sha }}" >&2
    echo "via the GitHub compare API, with split missing-key/null arms and a bounded settle window." >&2
    return 1
  fi

  echo "OK[$label]: the control-plane smoke can fail on a DB-dead box, and neither job can exit 0 over a box that did not move."
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

  # must_red <mutated-file> <name> — the mutation has to change something AND
  # the guard has to lose over it. Either half missing is a selftest failure.
  must_red() {
    local f="$1" name="$2" note="$3"
    if cmp -s "$real" "$f"; then
      echo "SELFTEST FAIL[$name]: the mutation changed nothing — the code no longer looks as expected" >&2
      rc=1
    elif check_file "$f" "$name" >/dev/null 2>&1; then
      echo "SELFTEST FAIL[$name]: $note read GREEN — the gate cannot fail" >&2
      rc=1
    else
      echo "  ok: the gate reds when $note"
    fi
  }

  echo "selftest 1/8: the real workflow passes"
  if ! check_file "$real" "real"; then
    echo "SELFTEST FAIL: the real deploy.yml does not pass" >&2
    rc=1
  fi

  echo
  echo "selftest 2/8: re-adding 404 to the accept-list must FAIL (the original bug)"
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
  echo "selftest 3/8: deleting the DB (login) probe must FAIL"
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

  # ── the ancestry assertion (dr-w21-s1) ─────────────────────────────────────

  echo
  echo "selftest 4/8: DELETING the sha comparison must FAIL"
  grep -v 'compare/' "$real" > "$tmp/nocompare.yml" || true
  must_red "$tmp/nocompare.yml" "nocompare" "the served-sha comparison is deleted"

  echo
  echo "selftest 5/8: WEAKENING the null arm (jq -er // empty -> jq -r) must FAIL"
  sed "s|jq -er '\.git_sha // empty'|jq -r '.git_sha'|" "$real" > "$tmp/nullpass.yml"
  must_red "$tmp/nullpass.yml" "nullpass" "a null git_sha could reach the oracle as the string 'null'"

  echo
  echo "selftest 6/8: RE-INTRODUCING an equality comparison must FAIL"
  awk '
    { print }
    !done && /SETTLE_WINDOW_S=180/ {
      print "          test \"$served\" == \"${{ github.sha }}\""
      done = 1
    }
  ' "$real" > "$tmp/equality.yml"
  must_red "$tmp/equality.yml" "equality" "an equality comparison between the served sha and github.sha is back"

  echo
  echo "selftest 7/8: MOVING the assertion into a differently-named step must stay GREEN"
  echo "  (this is the mutation that fooled the old step-name-keyed extractor: it matched"
  echo "   0 lines and printed OK. A rename must NOT blind the guard — and must NOT red it.)"
  sed 's/- name: Assert the served commit is at-or-after this one/- name: Assert serving sha/' "$real" > "$tmp/renamed.yml"
  if cmp -s "$real" "$tmp/renamed.yml"; then
    echo "SELFTEST FAIL[renamed]: the rename changed nothing — the step no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/renamed.yml" "renamed" >/dev/null 2>&1; then
    echo "  ok: the guard still SEES the assertion under a different step name"
  else
    echo "SELFTEST FAIL[renamed]: the guard lost the assertion when the step was renamed — it is step-name-bound again" >&2
    rc=1
  fi

  echo
  echo "selftest 8/8: REMOVING the assertion from the control-plane job ONLY must FAIL"
  echo "  (the instance job keeps its copy — an assertion in the OTHER job must not count)"
  awk '
    /^      - name: Assert (the served commit is at-or-after this one|serving sha)$/ && !seen { drop = 1; seen = 1 }
    /^  instance:/ { drop = 0 }
    !drop { print }
  ' "$real" > "$tmp/cponly.yml"
  must_red "$tmp/cponly.yml" "cponly" "the control-plane job loses its assertion while the instance job keeps one"

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
