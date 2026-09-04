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
# script was backstopped; the OUTER workflow smoke was not.
#
# THE INSTANCE JOB IS NOT THE COUNTEREXAMPLE (charter D369 NARROWS D344 here; it
# does not retract it). Its hard `test "$code" = "200"` on the DB-touching
# /api/schemas genuinely covers the DEAD-POOL class, and has FIRED on it: run
# 30686555528 logged `guerrilla /api/schemas = 500` and failed the step. It
# covers that class AND NOTHING ELSE. Mutation-proved: the bare 200 predicate
# PASSES against a server answering 200 with body `[]`, and the route is
# deliberately not token-gated, so the whole authenticated stack can be dead
# under a green. So the instance smoke is held to the SAME two-oracle bar as the
# control plane — a non-empty catalog AND an independent bad-creds 401 — instead
# of being cited as the standard the control plane should aspire to.
#
# THE ASSERTIONS, against the real deploy.yml
#
#   1. 404 is NOT in the control-plane smoke's accept-list for `/`.
#   2. A DB-touching login probe is present in that same step, asserting
#      EXACTLY 401 — so 5xx (500 storm) and 000 (dead box / dead pool) fail.
#   3. That probe uses an invalid address on the reserved .example TLD, so no
#      credential and no authentication is introduced by the gate itself.
#   3b. The INSTANCE smoke carries the same two oracles: /api/schemas asserted
#      NON-EMPTY (a bare 200 passes on `[]`), plus its own bad-creds 401 probe on
#      a different pipeline. And it declares no `env:` it never reads — a
#      GUERRILLA_HOST secret repointed at one box must not certify another,
#      which a step that hardcodes the URL while declaring the secret invites.
#   4. BOTH deploy jobs assert the SERVED COMMIT — that what the box answers with
#      is the merged commit or a descendant of it. Every probe above proves the
#      box is ALIVE; none proves it MOVED. Measured offline against a fake box
#      serving a commit two behind, with '/' at 200, bad-creds login at 401 and
#      /api/schemas at 200: both jobs' smoke steps exited 0 and nothing ever
#      asked what was being served. A green deploy that deployed nothing is the
#      most expensive lie this system can tell, because the ledger, the crown and
#      the next deploy's diff base all trust it.
#
# WHY THE SERVED-COMMIT ARMS USE A DIFFERENT EXTRACTOR
#
# extract_cp_smoke is pinned to the step literally named `Smoke test`, and that
# scoping is load-bearing for assertions 1-3 (selftest 4 proves a trailing step
# cannot answer for them). It is exactly wrong for assertion 4: the served-commit
# check is a NEW step, so a name-pinned extractor matches zero of its lines and
# the guard certifies an invariant it never looked at. Mutation-proved on this
# very file before the arms below existed — a deploy.yml carrying a full
# `- name: Assert serving sha` step scored `OK[...]` at rc 0.
#
# So assertion 4 reads the WHOLE job and asserts against the union, in two views:
#
#   extract_job_lines  every line of the job, YAML/shell comments stripped — a
#                      comment must never satisfy a gate.
#   logic_view         the above, minus BARE `echo`/`printf` lines (a line that
#                      pipes into something is logic, not a log line) — so the
#                      deploy job cannot satisfy its own gate with a log line,
#                      the D344 lesson that selftest 4 encodes for the smoke.
#
# A name-pinned second extractor was rejected outright: it just goes blind again
# on the next rename, which is the defect being fixed, not a smaller version of it.
#
# `--selftest` PROVES the tripwire on temp copies (plants nothing in the tree):
# the real file passes, a copy with 404 re-added FAILS, a copy with the login
# probe deleted FAILS, and a copy that is not parseable YAML at all FAILS. A
# guard that cannot lose is a sentence with an exit code. Modelled on
# scripts/check-deployyml-filters.sh, the house pattern.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_YML_DEFAULT=".github/workflows/deploy.yml"

# ── yaml validity (runs BEFORE any text scan) ────────────────────────────────

# THE HOLE THIS ARM CLOSES
#
# extract_cp_smoke below is an awk TEXT scan, and a text scan cannot see that its
# input stopped being a workflow. Measured: append a heredoc body indented at two
# spaces inside a `run: |` block — less than the block scalar's content indent, so
# the scalar terminates and the following lines are parsed as YAML keys.
# `yaml.safe_load` raises "could not find expected ':'", and BOTH deploy gates
# still printed `OK[...]` at rc=0, real run and --selftest alike. GitHub answers
# such a file with a `startup_failure` run carrying total_jobs=0: the smoke never
# runs, report-deploy-failure never runs, no issue is filed, and the `changes`
# job's `gh run list --status=success` anchor freezes.
#
# Note this is the SAME two-space line that breaks extract_cp_smoke's job
# boundary (cause #1 in the diagnostic below) — but that path only reds when the
# broken indent lands inside the control-plane job. Parsing first catches it
# wherever it lands, and names it as what it is.
#
# Fails CLOSED, and never confuses "I could not look" with "it is fine": a
# missing python3/PyYAML is HARNESS-UNAVAILABLE at a NON-ZERO exit, never a
# silent pass.
assert_parseable_yaml() {
  local yml="$1" label="$2"
  local detail rc=0

  if ! command -v python3 >/dev/null 2>&1; then
    echo "HARNESS-UNAVAILABLE[$label]: python3 not on PATH — could not verify that the file parses as YAML." >&2
    echo "This is NOT a verdict on the workflow, and NOT a pass: a gate that cannot read its input" >&2
    echo "must not certify it. Install python3 + PyYAML (pip install pyyaml) and re-run." >&2
    return 2
  fi

  # The probe is materialised into a variable first: a heredoc cannot be fed to a
  # command substitution that closes on the same line (`$(python3 - <<'PY')`),
  # which bash rejects outright with a syntax error.
  local probe
  probe="$(cat <<'PY'
import sys

try:
    import yaml
except ImportError:
    print("PyYAML not importable")
    sys.exit(2)

try:
    with open(sys.argv[1], "rb") as fh:
        yaml.safe_load(fh)
except Exception as exc:
    print(" ".join(str(exc).split()))
    sys.exit(1)
PY
)"

  # `|| rc=$?` is load-bearing: under `set -e` a bare assignment from a failing
  # command substitution aborts here and DISCARDS the captured diagnostic, which
  # is how a harness problem becomes an empty log indistinguishable from a find.
  detail="$(printf '%s\n' "$probe" | python3 - "$yml" 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    return 0
  fi

  if [ "$rc" -eq 2 ]; then
    echo "HARNESS-UNAVAILABLE[$label]: $detail — could not verify that the file parses as YAML." >&2
    echo "This is NOT a verdict on the workflow, and NOT a pass: a gate that cannot read its input" >&2
    echo "must not certify it. Install PyYAML (pip install pyyaml) and re-run." >&2
    return 2
  fi

  echo "FAIL[$label]: not a parseable YAML workflow — the control-plane smoke invariants were NOT checked" >&2
  echo "  $detail" >&2
  echo "Cause: almost always a heredoc body indented LESS than its enclosing 'run: |' block scalar's" >&2
  echo "content indent. That terminates the scalar, and every following line is parsed as YAML keys." >&2
  echo "Cure: re-indent the heredoc payload INSIDE the run block, at or past the block's content indent" >&2
  echo "(the terminator line included), then re-run this gate." >&2
  echo "Why this arm fails closed: GitHub answers an unparseable workflow with a startup_failure run" >&2
  echo "carrying total_jobs=0 — the smoke step never executes, report-deploy-failure never runs, no" >&2
  echo "issue is filed, and the 'changes' job's 'gh run list --status=success' anchor freezes. awk and" >&2
  echo "grep cannot see any of that, which is why this arm runs before them." >&2
  return 1
}

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

# The INSTANCE job's `Smoke test` step, verbatim. A deliberate near-copy of
# extract_cp_smoke rather than a shared parameterised helper: the job-boundary
# awk is shared prose with scripts/check-deployyml-filters.sh, and unifying the
# three is its own held task (dr-w25-followup-yaml-job-scope-helper). Copying
# eight lines is cheaper than a refactor nobody asked for, and the step-boundary
# rule ('      - ', not '      - name: ') is copied WITH it — that rule is what
# stops an unnamed trailing step from answering for the smoke, the disarm shape
# selftest 4 encodes.
extract_instance_smoke() {
  awk '
    /^  [a-zA-Z0-9_-]+:/ {
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job)
      instep = 0
    }
    job == "instance" && /^      - / { instep = ($0 ~ /^      - name: .*Smoke test/) ? 1 : 0 }
    job == "instance" && instep { print }
  ' "$1"
}

# The instance smoke's own invariants. Until this existed the instance job had
# ZERO tripwire by construction: every arm above is scoped `job == "control-plane"`,
# so the weakest oracle in the workflow was also the only unguarded one.
check_instance_smoke() {
  local yml="$1" label="$2"
  local step failures=0

  step="$(extract_instance_smoke "$yml" || true)"
  if [ -z "$step" ]; then
    echo "FAIL[$label]: no 'Smoke test' step found in the instance job — the extractor is broken, or the step was renamed" >&2
    echo "  Same four causes as the control-plane message above; the boundary rules are identical." >&2
    return 1
  fi

  local logic
  logic="$(printf '%s\n' "$step" | grep -v '^[[:space:]]*#' | logic_view)"

  # i1. THE EMPTY-CATALOG ARM. `test "$code" = "200"` alone is green on a server
  #     answering 200 with body `[]` — measured, against a local stub. The chain
  #     /api/schemas -> Content.list_schemas/2 -> Repo.all() -> Enum.map has no
  #     emptiness check, so a wiped or wrong-database box reads as a live one.
  #     Keyed on the ASSERTION, not on the word jq: reading a length and never
  #     comparing it is the shape this whole file refuses.
  if ! grep -qE 'test[[:space:]]+"\$count"[[:space:]]+-gt[[:space:]]+0' <<<"$logic"; then
    echo "  DRIFT    instance: the smoke never asserts a NON-EMPTY catalog — a 200 with body '[]' passes" >&2
    echo "           (expected a literal 'test \"\$count\" -gt 0' over the parsed /api/schemas body)" >&2
    failures=$((failures + 1))
  elif ! grep -q 'jq' <<<"$logic"; then
    echo "  DRIFT    instance: the count is not parsed out of the body with jq — a substring match is not a catalog" >&2
    failures=$((failures + 1))
  else
    echo "  ok       instance smoke asserts a NON-EMPTY catalog (a 200 on '[]' fails)"
  fi

  # i2. THE SECOND ORACLE. /api/schemas is deliberately NOT token-gated, so it
  #     answers 200 over a completely dead auth stack. The bad-creds login probe
  #     is a different pipeline with a different failure mode, pinned to EXACTLY
  #     401 so 5xx and 000 fail — the same predicate the control plane runs.
  if ! grep -q '/v1/auth/login' <<<"$logic"; then
    echo "  DRIFT    instance: no /v1/auth/login probe — the smoke rests on ONE predicate over a route that is not token-gated" >&2
    failures=$((failures + 1))
  elif ! grep -qE '=[[:space:]]*"?401"?[[:space:]]*$' <<<"$logic"; then
    echo "  DRIFT    instance: the login probe does not assert EXACTLY 401 — 5xx/000 could pass" >&2
    failures=$((failures + 1))
  elif ! grep -q '@invalid\.example' <<<"$step"; then
    echo "  DRIFT    instance: the login probe does not use an invalid .example address — a deploy gate must introduce no credential" >&2
    failures=$((failures + 1))
  else
    echo "  ok       instance smoke has a SECOND oracle: bad-creds login pinned to 401"
  fi

  # i3. NO UNREAD SECRET ON THE STEP. GUERRILLA_HOST is the SSH target; the URLs
  #     here are the public origin. A step that declares the secret and never
  #     reads it looks host-parameterised and is not: repoint the secret and this
  #     step still certifies the OLD box while the deploy moved a different one.
  # The COMMENT-STRIPPED view, deliberately: this step's prose explains WHY the
  # secret is absent, and a gate that reds on its own rationale teaches people to
  # delete the rationale.
  if grep -q 'GUERRILLA_HOST' <<<"$logic" && ! grep -q '\${GUERRILLA_HOST}' <<<"$logic"; then
    echo "  DRIFT    instance: the smoke declares GUERRILLA_HOST as env: and never reads it — wire it into the URL or drop it" >&2
    echo "           (a secret pointing elsewhere would move one box and certify another)" >&2
    failures=$((failures + 1))
  else
    echo "  ok       instance smoke declares no env it does not read"
  fi

  return "$failures"
}

# Every line of one job. Job boundaries are the 2-space keys under `jobs:` — the
# same rule extract_cp_smoke uses, so the two agree on where a job ends.
extract_job_lines() {
  awk -v want="$2" '
    /^  [a-zA-Z0-9_-]+:/ {
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job)
    }
    job == want { print }
  ' "$1" | grep -v '^[[:space:]]*#' || true
}

# The logic half: drop BARE echo/printf lines. A line that pipes into a test
# (`printf ... | grep -qE ...`) is logic and stays; a bare `echo "::error ..."`
# is a log line and goes. Without this, a step could satisfy every structural
# arm below by printing the strings it is supposed to execute.
logic_view() {
  grep -vE '^[[:space:]]*(echo|printf)([[:space:]]|$)[^|]*$' || true
}

# ── the served-commit arms ───────────────────────────────────────────────────

# check_served_assertion <yml> <label> <job> <url-fragment> <jq-key> <reader-cite>
# Returns the number of broken invariants on stdout is NOT used; it echoes
# diagnostics and returns non-zero count via the caller's accumulator.
check_served_assertion() {
  local yml="$1" label="$2" job="$3" url="$4" key="$5" cite="$6"
  local all logic failures=0

  all="$(extract_job_lines "$yml" "$job")"
  if [ -z "$all" ]; then
    echo "  DRIFT    job '$job' not found in $label — the extractor is broken, or the job was renamed" >&2
    return 1
  fi
  logic="$(printf '%s\n' "$all" | logic_view)"

  # a) the oracle is called, with the MERGED commit as the base and the SERVED
  #    commit as the head. Keyed on `compare/` — the `prev`/`served` recorder
  #    steps already read a sha and already run jq, so presence of a sha read is
  #    NOT evidence that anything is asserted about it.
  if ! grep -q 'compare/${{ github.sha }}\.\.\.' <<<"$logic"; then
    echo "  DRIFT    $job: no 'compare/\${{ github.sha }}...<served>' call — nothing asks the oracle whether the box moved" >&2
    echo "           (reading a sha is not asserting one: the recorder steps in this job already read it)" >&2
    failures=$((failures + 1))
  fi

  # b) the ANCESTOR verdict set, verbatim. Equality is refused: cp-deploy.sh and
  #    instance-deploy.sh both pull origin/main's TIP, so a run fired for one
  #    commit routinely delivers a DESCENDANT (7f5f10b8d...572d51e13 = ahead 10,
  #    behind 0). An equality gate reds healthy merges and gets ignored.
  if ! grep -qF "'^(ahead|identical)$'" <<<"$logic"; then
    echo "  DRIFT    $job: the compare verdict is not matched against '^(ahead|identical)\$'" >&2
    failures=$((failures + 1))
  fi

  # c) NO equality comparison against the merged sha.
  if grep -qE '(\[\[?|test)[^|]*\$\{\{ github\.sha \}\}|==[[:space:]]*"?\$\{\{ github\.sha \}\}|\$served"?[[:space:]]*==' <<<"$logic"; then
    echo "  DRIFT    $job: an EQUALITY comparison against \${{ github.sha }} is back — the ancestor rule was the fix, not an approximation" >&2
    failures=$((failures + 1))
  fi

  # d) NULL ARM. `jq -r '.k'` prints the literal four-character string `null` for
  #    a null value and would hand it to the oracle as if it were a commit:
  #      $ echo '{"git_sha":null}' | jq -r '.git_sha'
  #      null
  #    `-e` plus `// empty` turns both a null and an absent key into an EMPTY
  #    string at a non-zero exit, which the step then reports as a missing key.
  #
  #    ONE literal, not two loose halves: the control-plane job's `prev` recorder
  #    step already contains `jq -r '.git_sha // empty'` (no -e), so a `jq -er`
  #    arm and a `// empty` arm checked SEPARATELY are both satisfiable by a step
  #    that asserts nothing — the sibling-answers-for-the-broken-one shape this
  #    file exists to refuse.
  if ! grep -qF "jq -er '$key // empty'" <<<"$logic"; then
    echo "  DRIFT    $job: the served sha is not read as exactly \"jq -er '$key // empty'\" — a null or absent key would reach the oracle as the four-character string 'null'" >&2
    echo "           (a nearby recorder step's 'jq -r $key // empty' does NOT count: no -e, and it asserts nothing)" >&2
    failures=$((failures + 1))
  fi

  # e) the reader it depends on is NAMED, so a missing key sends the reader
  #    onward instead of surfacing as a bare comparison failure. This one arm
  #    reads the message text, so it uses the comment-stripped view, not `logic`.
  if ! grep -qF "$cite" <<<"$all"; then
    echo "  DRIFT    $job: the missing-key failure does not name the reader it depends on ($cite)" >&2
    failures=$((failures + 1))
  fi

  # f) the source it reads.
  if ! grep -qF "$url" <<<"$logic"; then
    echo "  DRIFT    $job: nothing reads $url" >&2
    failures=$((failures + 1))
  fi

  # g) a BOUNDED settle window that EXPIRES INTO A FAILURE, with the cap stated
  #    in the code. A window with no cap is a hang; a window that expires into a
  #    pass is the blindness with extra steps.
  if ! grep -qE 'SETTLE_CAP_SECONDS=[0-9]+' <<<"$logic"; then
    echo "  DRIFT    $job: no SETTLE_CAP_SECONDS=<n> — the settle window has no stated cap" >&2
    failures=$((failures + 1))
  fi
  if ! grep -q 'deadline' <<<"$logic"; then
    echo "  DRIFT    $job: the settle window never compares against a deadline" >&2
    failures=$((failures + 1))
  fi
  if ! grep -qF 'settle window expired' <<<"$all"; then
    echo "  DRIFT    $job: expiry does not announce itself as a failure — an unanswerable question must not be a pass" >&2
    failures=$((failures + 1))
  fi

  if [ "$failures" -eq 0 ]; then
    echo "  ok       $job asserts the SERVED commit (ancestor rule, null-armed, bounded window)"
  fi
  return "$failures"
}

# ── the check ────────────────────────────────────────────────────────────────

check_file() {
  local yml="$1" label="$2"
  local failures=0

  # Parse first. Everything below is a text scan and is meaningless — worse,
  # falsely reassuring — on a file GitHub itself cannot load.
  local yaml_rc=0
  assert_parseable_yaml "$yml" "$label" || yaml_rc=$?
  [ "$yaml_rc" -eq 0 ] || return "$yaml_rc"

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
    echo "  4. A line inside the Smoke test step's own 'run: |' body is indented EXACTLY six spaces and" >&2
    echo "     starts with '- ' (a bullet inside an echo, say). The step boundary is every 6-space '- '" >&2
    echo "     list item — that is what stops an UNNAMED trailing step from being absorbed into the smoke —" >&2
    echo "     so such a line closes the step early and the invariants after it go unseen. This direction" >&2
    echo "     fails CLOSED (you are reading this message, not an OK), but the fix is to re-indent the body," >&2
    echo "     never to loosen the boundary back to '- name: '." >&2
    return 1
  fi

  # 1. the '/' accept-list must exist, and must not accept 404.
  local accept
  accept="$(grep -oE "grep -qE '\^\([0-9|]+\)\\\$'" <<<"$step" | awk 'NR==1' || true)"
  if [ -z "$accept" ]; then
    echo "FAIL[$label]: no HTTP accept-list regex (grep -qE '^(...)\$') in the control-plane smoke — the extractor is broken, or the probe was rewritten" >&2
    failures=$((failures + 1))
  elif grep -q '404' <<<"$accept"; then
    echo "  DRIFT    accept-list accepts 404: $accept" >&2
    echo "           '/' is send_dashboard -> send_file(200, index.html), no Repo in the path:" >&2
    echo "           a 404-accepting gate certifies a box serving nothing but a 404 handler." >&2
    failures=$((failures + 1))
  else
    echo "  ok       accept-list rejects 404  ->  $accept"
  fi

  # 2. a DB-touching login probe asserting EXACTLY 401.
  if ! grep -q '/v1/auth/login' <<<"$step"; then
    echo "  DRIFT    no /v1/auth/login probe in the control-plane smoke — nothing in this gate touches the DB" >&2
    echo "           (mirror deploy/cp-deploy.sh:129-141: bad-creds login must answer 401)" >&2
    failures=$((failures + 1))
  elif ! grep -qE '=[[:space:]]*"?401"?[[:space:]]*$' <<<"$step"; then
    echo "  DRIFT    the login probe does not assert EXACTLY 401 — 5xx/000 could pass" >&2
    failures=$((failures + 1))
  else
    echo "  ok       login probe present and pinned to 401 (5xx/000 fail the step)"
  fi

  # 3. no credential smuggled in: the probe address is deliberately invalid.
  if grep -q '/v1/auth/login' <<<"$step" \
     && ! grep -q '@invalid\.example' <<<"$step"; then
    echo "  DRIFT    the login probe does not use an invalid .example address — a deploy gate must introduce no credential" >&2
    failures=$((failures + 1))
  fi

  # 3b. the instance smoke's own two oracles — until these existed the instance
  #     job had no tripwire at all (every arm above is control-plane-scoped).
  local inst_rc=0
  check_instance_smoke "$yml" "$label" || inst_rc=$?
  failures=$((failures + inst_rc))

  # 4. BOTH jobs assert the SERVED COMMIT. Everything above proves the box is
  #    alive; only this proves it moved.
  local served_rc=0
  check_served_assertion "$yml" "$label" "control-plane" \
    "https://barkpark.cloud/health" ".git_sha" "#10605" || served_rc=$?
  failures=$((failures + served_rc))
  served_rc=0
  check_served_assertion "$yml" "$label" "instance" \
    "https://guerrilla.barkpark.cloud/status.json" ".commit" "#6422" || served_rc=$?
  failures=$((failures + served_rc))

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures deploy-gate invariant(s) broken." >&2
    echo "Fix: the smoke step must reject 404 on '/' AND require a bad-creds POST to" >&2
    echo "/v1/auth/login to answer exactly 401, mirroring deploy/cp-deploy.sh:129-141;" >&2
    echo "AND both deploy jobs must assert that what the box SERVES is the merged" >&2
    echo "commit or a descendant of it, via the GitHub compare API under the ancestor" >&2
    echo "rule. A box that never moved passes every other gate in this workflow." >&2
    return 1
  fi

  echo "OK[$label]: both smokes carry two oracles (a DB-dead box and an empty catalog both fail), and neither target can exit 0 over a box that did not move."
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

  echo "selftest 1/12: the real workflow passes"
  if ! check_file "$real" "real"; then
    echo "SELFTEST FAIL: the real deploy.yml does not pass" >&2
    rc=1
  fi

  echo
  echo "selftest 2/12: re-adding 404 to the accept-list must FAIL (the original bug)"
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
  echo "selftest 3/12: deleting the DB (login) probe must FAIL"
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
  echo "selftest 4/12: an UNNAMED trailing step must not be absorbed into the smoke"
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

  echo
  echo "selftest 5/12: the YAML arm must PASS the real workflow and FAIL an unparseable one"
  # The measured shape, verbatim: a heredoc body written at two spaces inside a
  # `run: |` block. Two spaces is LESS than the block scalar's content indent, so
  # the scalar ends there and the line is parsed as a YAML key with no ':'.
  cp "$real" "$tmp/badyaml.yml"
  cat >> "$tmp/badyaml.yml" <<'YML'

  selftest-unparseable:
    runs-on: ubuntu-latest
    steps:
      - run: |
          cat > /tmp/payload <<'EOF'
  a heredoc body at two spaces terminates the block scalar
EOF
YML
  if assert_parseable_yaml "$real" "yaml-pass" >/dev/null 2>&1; then
    echo "  ok: the arm passes today's real deploy.yml"
  else
    echo "SELFTEST FAIL: the YAML arm did not pass the real deploy.yml (a real parse error, or no python3/PyYAML)" >&2
    rc=1
  fi
  if assert_parseable_yaml "$tmp/badyaml.yml" "yaml-fail" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: an unparseable workflow read GREEN — the YAML arm cannot fail" >&2
    rc=1
  elif check_file "$tmp/badyaml.yml" "yaml-fail" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: the arm red but check_file still certified the file — the arm is not wired in" >&2
    rc=1
  else
    echo "  ok: a 2-space heredoc body inside 'run: |' reds the arm AND the whole gate"
  fi

  # ── the served-commit arms ─────────────────────────────────────────────────
  #
  # Every one of these is a plant that a real edit could ship. The arms are worth
  # nothing until each has been SEEN to red: this file's own history is the
  # argument — its name-pinned extractor scored OK at rc 0 over a deploy.yml
  # carrying a complete, correct served-sha step, because the step had a new name.

  echo
  echo "selftest 6/12: DELETING both served-commit assertions must FAIL"
  awk '
    /^      - name: Assert the (control plane|content instance) serves this commit/ { drop = 1; next }
    drop && (/^      - / || /^  [a-zA-Z0-9_-]+:/) { drop = 0 }
    !drop { print }
  ' "$real" > "$tmp/nosha.yml"
  if cmp -s "$real" "$tmp/nosha.yml"; then
    echo "SELFTEST FAIL: the deletion changed nothing — the assertion steps no longer look as expected" >&2
    rc=1
  elif check_file "$tmp/nosha.yml" "nosha" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a workflow with NO served-commit assertion read GREEN — this is the whole defect" >&2
    rc=1
  else
    echo "  ok: the gate reds when neither job asks what the box is serving"
  fi

  echo
  echo "selftest 7/12: WEAKENING the null arm (jq -er '.k // empty' -> jq -r '.k') must FAIL"
  # `jq -r '.git_sha'` prints the literal four-character string `null` for a null
  # value, and that string would be handed to the compare API as if it were a
  # commit. D343's six boxes read `update_state: current` at 4/227/592/886/2,468
  # commits behind — unearned green of exactly this shape.
  sed -E "s|jq -er '(\.[a-z_]+) // empty'|jq -r '\1'|g" "$real" > "$tmp/nullpass.yml"
  if cmp -s "$real" "$tmp/nullpass.yml"; then
    echo "SELFTEST FAIL: the weakening changed nothing — the null arm no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/nullpass.yml" "nullpass" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a workflow that would hand the string 'null' to the oracle read GREEN" >&2
    rc=1
  else
    echo "  ok: the gate reds when a null or absent key would reach the oracle"
  fi

  echo
  echo "selftest 8/12: re-introducing an EQUALITY comparison must FAIL"
  # Equality was refuted by run (charter D359): both deploy scripts pull
  # origin/main's TIP, so a run fired for one commit routinely delivers a
  # DESCENDANT. compare 7f5f10b8d...572d51e13 = ahead, ahead_by 10, behind_by 0.
  awk '
    /grep -qE .\^\(ahead\|identical\)\$.; then$/ {
      match($0, /^ */); ind = substr($0, 1, RLENGTH)
      print ind "if test \"$served\" = \"${{ github.sha }}\"; then"
      next
    }
    { print }
  ' "$real" > "$tmp/equality.yml"
  if cmp -s "$real" "$tmp/equality.yml"; then
    echo "SELFTEST FAIL: the equality plant changed nothing — the ancestor test no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/equality.yml" "equality" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: an equality gate read GREEN — it would red ten healthy merges and get ignored" >&2
    rc=1
  else
    echo "  ok: the gate reds when the ancestor rule is downgraded to equality"
  fi

  echo
  echo "selftest 9/12: MOVING the assertion OUT of the job it guards must FAIL"
  # The step is lifted out of control-plane, renamed, and re-planted in `changes`
  # — where it runs BEFORE the deploy and answers for nothing. A gate scoped to
  # the job it guards must red on this; a gate scoped to a step NAME cannot see
  # it at all, which is how this file previously certified an absent invariant.
  awk -v out="$tmp/cpstep.txt" '
    /^      - name: Assert the control plane serves this commit/ { grab = 1; print > out; next }
    grab && (/^      - / || /^  [a-zA-Z0-9_-]+:/) { grab = 0 }
    grab { print > out; next }
    { print }
  ' "$real" > "$tmp/nocp.yml"
  sed -i.bak 's/Assert the control plane serves this commit or a descendant/Verify serving sha/' "$tmp/cpstep.txt"
  awk -v inc="$tmp/cpstep.txt" '
    /^      - name: Assert neither deploy target can pass/ {
      while ((getline line < inc) > 0) print line
      close(inc)
    }
    { print }
  ' "$tmp/nocp.yml" > "$tmp/moved.yml"
  if ! grep -q 'Verify serving sha' "$tmp/moved.yml"; then
    echo "SELFTEST FAIL: the move planted nothing" >&2
    rc=1
  elif ! grep -q 'compare/' "$tmp/moved.yml"; then
    echo "SELFTEST FAIL: the move lost the assertion body — this would red for the wrong reason" >&2
    rc=1
  elif check_file "$tmp/moved.yml" "moved" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: the assertion answered for a job it does not run in — the gate is scope-blind" >&2
    rc=1
  else
    echo "  ok: an assertion outside the control-plane job does not answer for the control-plane job"
  fi

  echo
  echo "selftest 10/12: RENAMING the assertion step IN PLACE must still PASS"
  # The positive control, and the reason the served-commit arms read the whole
  # job instead of a step name. This exact shape — a correct assertion under a
  # name the extractor did not know — is what scored OK at rc 0 before the arms
  # existed. A gate that reds on a rename teaches people to delete the gate.
  sed 's/- name: Assert the control plane serves this commit or a descendant/- name: Verify the box actually moved/' "$real" > "$tmp/renamed.yml"
  if cmp -s "$real" "$tmp/renamed.yml"; then
    echo "SELFTEST FAIL: the rename changed nothing — the step name no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/renamed.yml" "renamed" >/dev/null 2>&1; then
    echo "  ok: a renamed-but-present assertion still passes (the arms are not name-pinned)"
  else
    echo "SELFTEST FAIL: renaming the step reds the gate — the served-commit arms went name-pinned again" >&2
    rc=1
  fi

  echo
  echo "selftest 11/12: STRIPPING the instance non-empty-catalog assertion must FAIL"
  # The defect this task closes, planted back. Without the arm the mutated file
  # is a workflow whose instance smoke is exactly `test "$code" = "200"` — and
  # that predicate is green against a server answering 200 with body `[]`,
  # measured against a local stub before this arm was written.
  grep -v 'test "$count" -gt 0' "$real" > "$tmp/emptyok.yml"
  if cmp -s "$real" "$tmp/emptyok.yml"; then
    echo "SELFTEST FAIL: the strip changed nothing — the non-empty assertion no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/emptyok.yml" "emptyok" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: an instance smoke that cannot fail on an EMPTY catalog read GREEN" >&2
    rc=1
  else
    echo "  ok: the gate reds when the instance smoke stops asserting a non-empty catalog"
  fi

  echo
  echo "selftest 12/12: DELETING the instance login probe must FAIL"
  # The second oracle removed. /api/schemas is deliberately not token-gated, so
  # without this probe the whole authenticated stack can be dead under a green.
  awk '
    /^  instance:/ { injob = 1 }
    /^  [a-zA-Z0-9_-]+:/ && !/^  instance:/ { injob = 0 }
    injob && /dbcode="\$\(curl/ { drop = 1 }
    !drop { print }
    drop && /test "\$dbcode" = "401"/ { drop = 0 }
  ' "$real" > "$tmp/noinstprobe.yml"
  if cmp -s "$real" "$tmp/noinstprobe.yml"; then
    echo "SELFTEST FAIL: the instance-probe deletion changed nothing" >&2
    rc=1
  elif ! grep -q 'barkpark.cloud/v1/auth/login' "$tmp/noinstprobe.yml"; then
    echo "SELFTEST FAIL: the deletion removed the CONTROL-PLANE probe too — this would red for the wrong reason" >&2
    rc=1
  elif check_file "$tmp/noinstprobe.yml" "noinstprobe" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: an instance smoke with a single oracle read GREEN" >&2
    rc=1
  else
    echo "  ok: the gate reds when the instance smoke loses its second oracle"
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
