#!/usr/bin/env bash
#
# selftest-wiring-census.sh — every standalone self-test under scripts/ is
# either EXECUTED by CI or carries a machine-readable exemption naming why.
# A harness added tomorrow with neither is a RED here, not a silent omission.
#
# WHY IT EXISTS (task-8780f3b465edea5b, 2026-09-06). shell-harnesses.yml names
# its tenants ONE BY ONE, so adding scripts/foo.test.sh does not add it to CI.
# A census run by hand on 2026-09-06 put the orphan count at "14 of 66"; that
# number was WRONG IN BOTH DIRECTIONS, because a grep for the basename over
# .github/workflows/ has three faults this script exists to not repeat:
#
#   FALSE RUN     — the basename appears only inside a `#` COMMENT.
#                   (__studio-wide-deletion-diff.test.mjs, cloud-path-escape-check.test.sh)
#   FALSE ORPHAN  — the runner names a GLOB, not the file
#                   (studio-instrument-selftests.yml runs 'scripts/studio-desk-*.test.mjs')
#   FALSE ORPHAN  — the test is reached INDIRECTLY, by a route the grep cannot see.
#
# So execution is resolved over FOUR routes, and a file is RUN if any holds:
#
#   R1 DIRECT   its basename appears in a workflow, on a line that is not a
#               whole-line comment.
#   R2 GLOB     a workflow names a scripts/… glob that the file matches.
#   R3 PARENT   a script in scripts/ dispatches to it (a `--selftest` exec, say)
#               AND that parent's own basename appears in a workflow.
#               e.g. elixir.yml:  bash scripts/elixir-impacted-tests.sh --selftest
#   R4 DOOR     an ExUnit test under api/test/ System.cmd's it, so the REQUIRED
#               Elixir gate runs it.  e.g. api/test/barkpark/pds_pull_proof_test.exs
#
# THE EXEMPTION is a grep-able header line in the file's first 60 lines:
#
#     MANUAL PROOF — not wired: <reason>
#
# It is deliberately the same line a human reads. A browser-coupled or
# machine-specific proof is a LEGITIMATE answer — wiring a slow or
# environment-dependent harness into every PR is its own defect — but it must
# be DECLARED, so the un-exempted remainder means something.
#
# HONEST LIMIT, stated once: R4 keys on api/test/**, which is NOT in this
# workflow's paths, so a door added there does not re-trigger this census on
# that PR. The push-to-main arm catches it. R2 and R3 are resolved from the
# tree, not from a cached list, so neither can go stale.
#
# EXIT: 0 every file is RUN or exempt · 1 at least one is neither · 2 cannot measure.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ROOT="${CENSUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

census() {
  local root="$1" files wf_nc invocations doors globs rc=0 n_run=0 n_exempt=0 n_red=0
  [ -d "$root/scripts" ] || { echo "selftest-wiring-census: REFUSING — no scripts/ under $root" >&2; return 2; }
  [ -d "$root/.github/workflows" ] || { echo "selftest-wiring-census: REFUSING — no .github/workflows/ under $root" >&2; return 2; }

  # Workflow corpus with WHOLE-LINE comments removed. Only whole-line, never
  # `sed 's/#.*//'`: a `#` inside a real run: line would truncate a genuine
  # reference and manufacture a false orphan. And with bare YAML SEQUENCE ITEMS removed as well. A `paths:` entry is a
  # TRIGGER, not an execution: `- "scripts/foo.test.sh"` under on.pull_request
  # says when a run starts, never that anything runs the file. Counting those
  # made this census report "70 run, 0 exempt" the moment the census's own
  # `scripts/*.test.mjs` trigger glob landed — every self-test in the repo
  # resolved as RUN through a path filter. Only bare scalar items are dropped,
  # so `- run: bash scripts/x.test.sh` and `- name: …` survive.
  wf_nc="$(mktemp "${TMPDIR:-/tmp}/wfnc.XXXXXX")"
  grep -hv '^[[:space:]]*#' "$root"/.github/workflows/*.yml 2>/dev/null \
    | grep -vE '^[[:space:]]*-[[:space:]]*"?'"'"'?[A-Za-z0-9_./*{}-]+"?'"'"'?[[:space:]]*$' > "$wf_nc"

  # R3's INDEX, built once: every INVOCATION line of every scripts/ file whose
  # own basename a workflow names, prefixed with that basename. Built once
  # rather than re-grepping ~400 scripts per test file (that draft was 12 s;
  # this is under 2 s, and the census runs five times inside --selftest).
  #
  # MENTION IS NOT EXECUTION, so a line qualifies only if it carries an invoking
  # verb. scripts/elixir-path-escape-check.sh LISTS four harnesses as allowed
  # paths, one bare line each; counting those made three pds harnesses resolve
  # through the wrong route in the first draft. And the verb must be a WORD:
  # anchoring on `sh` without a following space matched the `.sh` extension in
  # every one of those bare lines, which is how that draft passed at all.
  invocations="$(mktemp "${TMPDIR:-/tmp}/inv.XXXXXX")"
  local p pbase
  for p in $(find "$root/scripts" -type f \( -name '*.sh' -o -name '*.mjs' \) 2>/dev/null); do
    pbase="$(basename "$p")"
    grep -qF "$pbase" "$wf_nc" || continue
    grep -v '^[[:space:]]*#' "$p" 2>/dev/null \
      | grep -E '(^|[[:space:]]|[(;&|])(exec|bash|sh|node|source)[[:space:]]' \
      | sed "s|^|$pbase |" >> "$invocations"
  done

  # R4's INDEX, same shape: every line of every api/test/**.exs that both
  # System.cmd's something and BINDS a path (a @…_rel / @…_path attribute or the
  # System.cmd line itself). api/test/barkpark/pds_door_census_test.exs asserts a
  # census OUTPUT names these harnesses — a mention, not a run.
  doors="$(mktemp "${TMPDIR:-/tmp}/doors.XXXXXX")"
  if [ -d "$root/api/test" ]; then
    local door
    for door in $(find -H "$root/api/test" -name '*.exs' -exec grep -lE 'System\.cmd' {} + 2>/dev/null | LC_ALL=C sort); do
      grep -v '^[[:space:]]*#' "$door" 2>/dev/null \
        | grep -E 'System\.cmd|@[a-z_]*(rel|path|harness|selftest|script)' \
        | sed "s|^|${door#"$root"/} |" >> "$doors"
    done
  fi

  # Every scripts/… glob a workflow ACTUALLY RUNS, collected ONCE (see R2).
  #
  # A glob only counts from a COMMAND LINE or its backslash continuation. Two
  # other places in these files name globs and neither executes anything: the
  # `paths:` trigger lists (already dropped above) and the dispatcher's own
  # roster, whose rows are `<job-id> <path>` pairs. Counting the roster made
  # `scripts/*.test.mjs` resolve EVERY .test.mjs in the repo as RUN — the census
  # marking itself green off its own trigger declaration.
  globs="$(awk '
      { verb = ($0 ~ /(^|[[:space:]]|[(;&|])(exec|bash|sh|node|source)[[:space:]]/) }
      (verb || cont) { print }
      { cont = ($0 ~ /\\[[:space:]]*$/) }
    ' "$wf_nc" \
    | grep -oE "scripts/[A-Za-z0-9_./-]*\*[A-Za-z0-9_./*-]*\.test\.(sh|mjs)" | LC_ALL=C sort -u)"

  files="$(find "$root/scripts" -type f \( -name '*.test.sh' -o -name '*.test.mjs' -o -name '*_test.sh' \) 2>/dev/null | LC_ALL=C sort)"
  [ -n "$files" ] || { echo "selftest-wiring-census: REFUSING — found ZERO self-tests under $root/scripts. Reporting a clean census over an empty corpus is the failure this gate exists to prevent." >&2; rm -f "$wf_nc" "$invocations" "$doors"; return 2; }

  local f base rel route
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    rel="${f#"$root"/}"
    route=""

    # R1 DIRECT
    if grep -qF "$base" "$wf_nc"; then route="R1-direct"; fi

    # R2 GLOB — every scripts/…*…test.{sh,mjs} glob any workflow names.
    # `set -f` is load-bearing: without it the unquoted expansion of the
    # pattern list is PATHNAME-EXPANDED by this shell, the loop iterates over
    # files that happen to exist instead of over patterns, and R2 silently
    # degenerates into "the file exists" — green for the wrong reason, and
    # blind to a glob whose first member has not been written yet.
    if [ -z "$route" ]; then
      local pat
      set -f
      for pat in $globs; do
        # shellcheck disable=SC2254
        case "$rel" in $pat) route="R2-glob:$pat"; break ;; esac
      done
      set +f
    fi

    # R3 PARENT — a sibling script execs it, and that script is itself wired.
    #
    # NO `cmd | grep -q` ANYWHERE BELOW. Under `set -o pipefail` a `grep -q`
    # that exits on its first match SIGPIPEs its producer, the pipeline reports
    # 141, and the test reads FALSE — a false orphan produced by the plumbing.
    # Every membership question here is asked through a command substitution.
    if [ -z "$route" ]; then
      local hit
      hit="$(grep -F "$base" "$invocations" | sed -n '1s/ .*//p')"
      [ -n "$hit" ] && route="R3-parent:$hit"
    fi

    # R4 DOOR — an ExUnit test shells out to it (the required Elixir gate).
    if [ -z "$route" ] && [ -s "$doors" ]; then
      local hit
      hit="$(grep -F "$base" "$doors" | sed -n '1s/ .*//p')"
      [ -n "$hit" ] && route="R4-door:$hit"
    fi

    if [ -n "$route" ]; then
      n_run=$((n_run + 1))
      [ -n "${CENSUS_VERBOSE:-}" ] && echo "  RUN     $rel  ($route)"
    elif [ "$(head -60 "$f" | grep -c 'MANUAL PROOF .* not wired:')" -gt 0 ]; then
      n_exempt=$((n_exempt + 1))
      echo "  EXEMPT  $rel  — $(head -60 "$f" | grep 'MANUAL PROOF .* not wired:' | sed -n '1s/^.*not wired: *//p' | cut -c1-90)"
    else
      n_red=$((n_red + 1)); rc=1
      echo "  ORPHAN  $rel  — no workflow runs it and it declares no exemption."
    fi
  done <<EOF
$files
EOF

  rm -f "$wf_nc" "$invocations" "$doors"
  if [ "$rc" -ne 0 ]; then
    echo "selftest-wiring-census: FAILED — ${n_red} self-test(s) are neither executed by CI nor exempt."
    echo "  Fix one of two ways: wire it (a tenant of .github/workflows/shell-harnesses.yml, or a"
    echo "  --selftest step on its parent in the workflow that already runs the subject), or add a"
    echo "  header line in its first 60 lines reading:  MANUAL PROOF — not wired: <reason>"
  else
    echo "selftest-wiring-census: OK — ${n_run} run, ${n_exempt} exempt, 0 orphaned ($((n_run + n_exempt)) self-tests under scripts/)."
  fi
  return $rc
}

selftest() {
  local pass=0 fail=0 out rc
  # tmp is deliberately NOT local: the EXIT trap below runs after this function returns.
  tmp=""
  ok()  { pass=$((pass + 1)); echo "  ok   $*"; }
  bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
  # Membership via a HERESTRING, never `printf | grep -q`: under pipefail the early-exiting grep
  # SIGPIPEs printf (141) and a TRUE membership reads FALSE — measured 10 of 12 arms on macOS.
  has() { grep -q -- "$1" <<<"$out"; }

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/census-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.github"
  cp -R "$ROOT/scripts" "$tmp/scripts"
  cp -R "$ROOT/.github/workflows" "$tmp/.github/workflows"
  [ -d "$ROOT/api/test" ] && { mkdir -p "$tmp/api"; ln -s "$ROOT/api/test" "$tmp/api/test"; }

  echo "== POSITIVE CONTROL: the census must find the WIRED ones, by all four routes =="
  out="$(CENSUS_ROOT="$tmp" CENSUS_VERBOSE=1 census "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "the real tree is green (rc=0)" || bad "the real tree is NOT green (rc=$rc) — a census that starts red cannot prove anything below"
  has 'RUN .*scripts/doctor.test.sh  (R1-direct)' \
    && ok "R1 direct: doctor.test.sh" || bad "R1 direct: doctor.test.sh not resolved"
  has 'RUN .*scripts/studio-desk-sha-pin.test.mjs  (R2-glob' \
    && ok "R2 glob: studio-desk-sha-pin.test.mjs" || bad "R2 glob: studio-desk-sha-pin.test.mjs not resolved"
  has 'RUN .*scripts/elixir-impacted-tests.test.sh  (R3-parent' \
    && ok "R3 parent --selftest: elixir-impacted-tests.test.sh" || bad "R3 parent: elixir-impacted-tests.test.sh not resolved"
  has 'RUN .*scripts/pds-pull-proof_test.sh  (R4-door' \
    && ok "R4 ExUnit door: pds-pull-proof_test.sh" || bad "R4 door: pds-pull-proof_test.sh not resolved"

  echo "== NEGATIVE CONTROL: comment-only mention is NOT execution =="
  # __studio-wide-deletion-diff.test.mjs is named ONLY in a comment in
  # studio-instrument-selftests.yml. It must land as EXEMPT (its header
  # declares the exemption), never as RUN.
  has 'EXEMPT .*__studio-wide-deletion-diff.test.mjs' \
    && ok "a basename that appears only in a workflow COMMENT is not counted as run" \
    || bad "__studio-wide-deletion-diff.test.mjs did not land as EXEMPT — the comment-stripper or the header marker regressed"

  echo "== CAN-LOSE: an unlisted, unexempted harness must RED =="
  cat > "$tmp/scripts/__census-canary.test.sh" <<'CANARY'
#!/usr/bin/env bash
# a planted harness that no workflow names and that declares nothing
exit 0
CANARY
  out="$(CENSUS_ROOT="$tmp" census "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && ok "planting scripts/__census-canary.test.sh reds the census (rc=1)" \
                  || bad "the planted harness did NOT red the census (rc=$rc) — this gate cannot lose"
  has 'ORPHAN .*__census-canary.test.sh' \
    && ok "the census NAMES the planted file" || bad "the census reddened without naming the planted file"

  echo "== THE EXEMPTION IS HONOURED, and only by the declared marker =="
  printf '%s\n' '#!/usr/bin/env bash' '# MANUAL PROOF — not wired: planted by the selftest' 'exit 0' \
    > "$tmp/scripts/__census-canary.test.sh"
  out="$(CENSUS_ROOT="$tmp" census "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && ok "adding the MANUAL PROOF marker makes it green again (rc=0)" \
                  || bad "the exemption marker was not honoured (rc=$rc)"
  has 'EXEMPT .*__census-canary.test.sh  — planted by the selftest' \
    && ok "the exemption's REASON is echoed, so an empty excuse is visible" || bad "the exemption reason was not echoed"

  echo "== REMOVAL restores the baseline =="
  rm -f "$tmp/scripts/__census-canary.test.sh"
  CENSUS_ROOT="$tmp" census "$tmp" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "removing the planted file makes it green again (rc=0)" || bad "removal did not restore green (rc=$rc)"

  echo "== REFUSAL, not a clean report, when the corpus vanishes =="
  mkdir -p "$tmp/empty/scripts" "$tmp/empty/.github/workflows"
  out="$(CENSUS_ROOT="$tmp/empty" census "$tmp/empty" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] && ok "an empty scripts/ tree REFUSES (rc=2) instead of reporting 0 orphans" \
                  || bad "an empty corpus produced rc=$rc, not the refusal"

  echo
  echo "SELFTEST: ${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ]
}

case "${1:---check}" in
  --selftest) selftest ;;
  --check)    CENSUS_VERBOSE="${CENSUS_VERBOSE:-}" census "$ROOT" ;;
  --list)     CENSUS_VERBOSE=1 census "$ROOT" ;;
  *) echo "usage: $0 [--check|--list|--selftest]" >&2; exit 2 ;;
esac
