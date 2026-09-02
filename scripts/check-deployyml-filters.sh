#!/usr/bin/env bash
# check-deployyml-filters.sh — the paths↔regex drift gate for the production
# deploy workflow (stw9, charter D57a).
#
# THE BUG THIS EXISTS FOR
#
# .github/workflows/deploy.yml keeps TWO lists that must agree and nothing made
# them:
#
#   1. `on.push.paths` — which merges RUN the workflow at all;
#   2. the `changes` job's `grep -qE '^(...)/'` regexes — which of the two deploy
#      jobs (control-plane / instance) a run actually TARGETS.
#
# `templates/**` was added to (1) and never to (2). The consequence is the worst
# shape a CI failure can take: a templates-only merge STARTED the deploy
# workflow, both job filters evaluated false, nothing deployed — and the run
# reported GREEN. Sites kept building from a stale template with a green tick
# above them. (Other instances of this class: internal/cmd was fixed in
# 96879b11c; scripts/connectors — once absent from BOTH lists, so a runner-only
# merge never reached guerrilla — was fixed by Connectors W35, charter D275, and
# is pinned below by the required-path allowlist.)
#
# THE ASSERTION, IN BOTH DIRECTIONS
#
#   forward  every `on.push.paths` entry must be matched by at least one job
#            filter regex — every merge that can START this workflow must be
#            able to DEPLOY something. A path that is deliberately targetless
#            (editing the workflow file itself) must say so with a
#            `deploy-filter-exempt:` comment in the block ABOVE it, which makes
#            the exception explicit and reviewable instead of invisible.
#
#   reverse  every alternation prefix inside a `changes` job filter must be
#            REACHABLE from `on.push.paths` — a prefix the workflow never starts
#            for is dead text that deploys only when another path co-triggers.
#
#   presence a small allowlist of paths that must stay LISTED, because a path
#            deleted together with its regex prefix leaves nothing for either
#            direction to judge.
#
# `--selftest` PROVES the tripwire on temp copies (plants nothing in the tree):
# the real file passes, a copy with `templates` stripped from the instance regex
# FAILS, an unexplained targetless path FAILS, an unreachable job-filter prefix
# FAILS, a deleted required path FAILS, and a copy that is not parseable YAML at
# all FAILS. Modelled on scripts/connectors-catalog-drift-check.sh's bundled
# selftest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_YML_DEFAULT=".github/workflows/deploy.yml"

# ── yaml validity (runs BEFORE any text scan) ────────────────────────────────

# THE HOLE THIS ARM CLOSES
#
# Everything below this line is an awk/grep TEXT scan. A text scanner cannot see
# that its input stopped being a workflow. Measured: append a heredoc body
# indented at two spaces inside a `run: |` block — that is LESS than the block
# scalar's content indent, so the scalar terminates and the following lines are
# parsed as YAML keys. `yaml.safe_load` raises "could not find expected ':'" at
# that line, and BOTH deploy gates still printed `OK[...]` at rc=0, real run and
# --selftest alike. GitHub answers such a file with a `startup_failure` run
# carrying total_jobs=0: report-deploy-failure never runs, no issue is filed,
# and the `changes` job's `gh run list --status=success` anchor freezes.
#
# So: parse first, fail CLOSED, and never confuse "I could not look" with "it is
# fine" — a missing python3/PyYAML is HARNESS-UNAVAILABLE at a NON-ZERO exit,
# never a silent pass.
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

  echo "FAIL[$label]: not a parseable YAML workflow — the path/regex scan was NOT run" >&2
  echo "  $detail" >&2
  echo "Cause: almost always a heredoc body indented LESS than its enclosing 'run: |' block scalar's" >&2
  echo "content indent. That terminates the scalar, and every following line is parsed as YAML keys." >&2
  echo "Cure: re-indent the heredoc payload INSIDE the run block, at or past the block's content indent" >&2
  echo "(the terminator line included), then re-run this gate." >&2
  echo "Why this arm fails closed: GitHub answers an unparseable workflow with a startup_failure run" >&2
  echo "carrying total_jobs=0 — report-deploy-failure never runs, no issue is filed, and the 'changes'" >&2
  echo "job's 'gh run list --status=success' anchor freezes. Do NOT skip past this to the text scan:" >&2
  echo "awk and grep cannot see that the file stopped being a workflow." >&2
  return 1
}

# ── extraction ───────────────────────────────────────────────────────────────

# The `on.push.paths` entries, one per line, unquoted. Reads only the block
# between `paths:` and the next top-level key, so a `paths:` elsewhere in the
# file (or a job-level one) can never widen the set. An entry whose preceding
# comment block carries `deploy-filter-exempt:` is emitted with a trailing
# "\tEXEMPT" column.
extract_paths() {
  awk '
    # `on:` and its quoted spellings are the same key to GitHub (YAML 1.1
    # resolves a bare `on` to the BOOLEAN true, which is why yamllint pushes
    # authors to quote it). A `/^on:/` byte anchor reads a quoted workflow as
    # having no `on.push.paths` at all and this gate then compares an EMPTY
    # path set — a green earned over nothing. Same three spellings as
    # scripts/required-checks-generate.sh build_workflow_index.
    /^("on"|\047on\047|on)[ \t]*:/ { in_on = 1; next }
    in_on && /^[A-Za-z"\047]/ { in_on = 0 }
    in_on && /^    paths:/    { in_paths = 1; exempt = 0; next }
    in_paths && /^    [a-z]/  { in_paths = 0 }
    in_paths && /^ *#/        { if ($0 ~ /deploy-filter-exempt:/) exempt = 1; next }
    in_paths && /^ *- / {
      line = $0
      sub(/^ *- */, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      if (line == "") next
      print line "\t" (exempt ? "EXEMPT" : "REQUIRED")
      exempt = 0
    }
  ' "$1"
}

# Every job-filter regex: the `grep -qE '<re>'` patterns the `changes` job uses
# to decide which target changed — and ONLY those.
#
# Scoped to the `changes` job by the same 2-space job-boundary technique
# check-deploy-smoke.sh's extract_cp_smoke uses, because an unscoped grep over
# the whole file let the workflow DISARM ITS OWN GATE: any other job whose shell
# happens to contain a single-quoted `grep -qE '^(...|templates|...)/'` — a
# deploy RECORDER classifying the same paths is the obvious one — was harvested
# as if it were a dispatch filter, so stripping `templates` from the real
# instance filter still read `OK ... 7 path(s) ... target at least one deploy
# job` at rc=0. Worse, a VERBATIM copy defeated `--selftest` too: the drift the
# gate exists for became invisible in the exact run meant to prove the gate can
# lose. A regex outside the `changes` job dispatches nothing, so it may not
# answer for a path.
extract_regexes() {
  awk '
    /^  [a-zA-Z0-9_-]+:/ {
      job = $0; sub(/^  /, "", job); sub(/:.*$/, "", job)
    }
    job == "changes"
  ' "$1" | { grep -oE "grep -qE '[^']+'" || true; } | sed -E "s/^grep -qE '//; s/'$//"
}

# A path glob reduced to ONE representative file path, which is what the job
# regexes are actually run against (`git diff --name-only` output).
#   "cloud/**"                    -> cloud/x
#   ".github/workflows/deploy.yml"-> .github/workflows/deploy.yml
sample_for() {
  case "$1" in
    */\*\*) printf '%sx\n' "${1%\*\*}" ;;
    *\**)   printf '%s\n' "${1%\**}x" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

# ── required-path presence allowlist ─────────────────────────────────────────

# THE HOLE THIS ARM CLOSES
#
# The drift scan (check_file below) only judges paths that are PRESENT: it proves
# every LISTED on.push.paths entry targets some deploy job. It is blind to a path
# that was DELETED — once both the `- "scripts/connectors/**"` push-path line AND
# its instance-regex prefix are gone, nothing is left to drift, so the drift scan
# reads GREEN. That is a false pass that silently re-opens exactly the gap W35
# closed (charter D275): a runner-only merge under scripts/connectors/** lands on
# main and never reaches guerrilla.
#
# So: pin the paths that MUST stay listed. A merge under one of these trees
# deploys a real artifact (scripts/connectors/** installs the cloud-sandbox-runner
# via instance-deploy.sh), so dropping its filter strands that artifact on main.
# Deleting the line now reds THIS arm even though the drift arm sees nothing.
REQUIRED_PATHS=(
  "scripts/connectors/**"
)

# Assert every REQUIRED_PATHS entry appears in extract_paths() output (either
# REQUIRED or EXEMPT column — presence is what matters here, drift is the other
# arm's job). Fails closed if any is absent.
check_required_paths() {
  local yml="$1" label="$2"
  local present missing=0 req
  present="$(extract_paths "$yml" | cut -f1)"
  for req in "${REQUIRED_PATHS[@]}"; do
    if printf '%s\n' "$present" | grep -qxF "$req"; then
      echo "  present  $req (required on.push.paths entry)"
    else
      echo "  MISSING  $req  ->  required on.push.paths entry absent (a merge here would deploy nothing)" >&2
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    echo "FAIL[$label]: $missing required path(s) absent from on.push.paths." >&2
    echo "Fix: restore the '- \"<path>\"' entry under on.push.paths AND its matching prefix in the" >&2
    echo "'changes' job instance regex — deleting both is the false-green this allowlist exists to catch." >&2
    return 1
  fi
  return 0
}

# ── reverse direction: every job-filter prefix must be REACHABLE ──────────────

# THE HOLE THIS ARM CLOSES
#
# check_file proves paths -> regex. The CONVERSE was never asserted anywhere,
# and it is a different silent failure with the same shape: a `changes`-job
# filter can name a prefix that `on.push.paths` cannot deliver. The workflow
# then never STARTS for a merge under that tree, so the filter arm that would
# have deployed it is dead text — it fires only when some OTHER listed path
# co-triggers the run. That is exactly how scripts/connectors/** behaved before
# W35 (charter D275): the box was byte-identical to main "only by piggyback,
# never by its own deploy". The forward arm reads GREEN through all of it,
# because a prefix that is not a path is not a path the forward arm judges.
#
# So: decompose each `changes` filter into its alternation prefixes and assert
# each one has an on.push.paths entry that would deliver a file under it.
#
# This does NOT subsume the required-path allowlist above and cannot: delete the
# push-path line AND its regex prefix together and no prefix is left to be
# unreachable, so only the allowlist reds (selftest case 9 pins exactly that).
# The two arms catch the two halves of the same deletion.

# The alternation prefixes of one job filter, one per line.
#   "^(cloud|deploy|internal|cmd)/" -> cloud / deploy / internal / cmd
#
# A filter this cannot decompose returns non-zero and is a FAILURE upstream,
# never a skip. extract_regexes is already scoped to the `changes` job, so every
# regex it yields dispatches a deploy — and a dispatch this arm cannot read is a
# dispatch it cannot answer for. Passing over it silently would be the same
# "could not look" == "it is fine" confusion the YAML arm above refuses.
prefixes_of() {
  local re="$1" body
  case "$re" in
    '^('*')/') body="${re#'^('}"; body="${body%')/'}" ;;
    *)         return 1 ;;
  esac
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | tr '|' '\n'
}

# One on.push.paths glob as an anchored ERE, with GitHub's path-filter
# semantics: `**` crosses directory separators, `*` and `?` do not, and an entry
# with no wildcard is an exact file path. Deliberately STRICTER than a bash glob
# match (where `*` also crosses `/`), because an over-matching translation here
# would manufacture reachability — a false PASS — and this arm exists to catch
# unreachability.
glob_to_regex() {
  awk -v g="$1" 'BEGIN {
    out = "^"
    n = length(g)
    i = 1
    while (i <= n) {
      c = substr(g, i, 1)
      if (c == "*") {
        if (substr(g, i + 1, 1) == "*") { out = out ".*"; i += 2 }
        else                            { out = out "[^/]*"; i += 1 }
      } else if (c == "?") {
        out = out "[^/]"; i += 1
      } else if (index("\\^$.[]|()+{}", c) > 0) {
        out = out "\\" c; i += 1
      } else {
        out = out c; i += 1
      }
    }
    print out "$"
  }'
}

# Set by check_reverse so the OK line can report BOTH directions with counts —
# a summary that names only one direction is how a half-run gate reads whole.
REVERSE_PREFIXES=0

check_reverse() {
  local yml="$1" label="$2"
  local regexes paths_globs path_res entry entry_re line
  local re body prefix sample matched seen="" unreachable=""
  local checked=0 failures=0

  regexes="$(extract_regexes "$yml")"
  if [ -z "$regexes" ]; then
    echo "FAIL[$label]: no 'grep -qE' job filters found inside the 'changes' job — the extractor is broken" >&2
    return 1
  fi

  paths_globs="$(extract_paths "$yml" | cut -f1)"

  # Every LISTED path counts, EXEMPT included: `deploy-filter-exempt` says the
  # entry targets no deploy job, not that it cannot start the workflow — and
  # starting the workflow is the entire question this direction asks.
  path_res=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    line="$(glob_to_regex "$entry")"
    path_res="${path_res}${line}"$'\t'"${entry}"$'\n'
  done <<EOF
$paths_globs
EOF

  while IFS= read -r re; do
    [ -n "$re" ] || continue
    if ! body="$(prefixes_of "$re")"; then
      echo "FAIL[$label]: the 'changes' job carries a filter this arm cannot decompose: $re" >&2
      echo "Expected the house shape '^(a|b|c)/' — an anchored alternation of path prefixes." >&2
      echo "This fails CLOSED rather than skipping the filter: a dispatch that cannot be read" >&2
      echo "cannot be answered for. Teach prefixes_of the new shape deliberately." >&2
      return 1
    fi

    while IFS= read -r prefix; do
      [ -n "$prefix" ] || continue
      # One verdict per distinct prefix even though `internal` and `deploy`
      # appear in BOTH filters — a duplicate would inflate the count the OK line
      # reports and make the summary a worse number than no number.
      case "$seen" in *"|$prefix|"*) continue ;; esac
      seen="$seen|$prefix|"
      checked=$((checked + 1))

      # The representative file the filter would fire on, matched against the
      # push globs exactly as GitHub matches a changed-file list.
      sample="$prefix/x"
      matched=""
      while IFS=$'\t' read -r entry_re entry; do
        [ -n "$entry_re" ] || continue
        if printf '%s\n' "$sample" | grep -qE "$entry_re"; then
          matched="$entry"
          break
        fi
      done <<EOF
$path_res
EOF

      if [ -n "$matched" ]; then
        echo "  reach    $prefix/  <-  $matched"
      else
        echo "  UNREACHABLE  $prefix/  ->  matched by the job filter but no on.push.paths entry can deliver it" >&2
        unreachable="$unreachable $prefix"
        failures=$((failures + 1))
      fi
    done <<EOF
$body
EOF
  done <<EOF
$regexes
EOF

  REVERSE_PREFIXES="$checked"

  if [ "$checked" -eq 0 ]; then
    echo "FAIL[$label]: no job-filter prefixes extracted — the reverse extractor is broken, not the workflow" >&2
    return 1
  fi

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label] reverse:$unreachable is matched by the job filter but no on.push.paths entry can deliver it —" >&2
    echo "a change there deploys via the filter ONLY when some other listed path co-triggers the run." >&2
    echo "Fix: add the tree to on.push.paths (it is meant to deploy), or drop the prefix from the" >&2
    echo "'changes' job regex (it is dead text). Leaving it is deploy-by-coincidence." >&2
    return 1
  fi

  echo "  reverse: $checked regex prefix(es), all reachable from on.push.paths"
  return 0
}

# ── the check ────────────────────────────────────────────────────────────────

check_file() {
  local yml="$1" label="$2"
  local failures=0 checked=0 exempted=0

  # Parse first. Everything below is a text scan and is meaningless — worse,
  # falsely reassuring — on a file GitHub itself cannot load.
  local yaml_rc=0
  assert_parseable_yaml "$yml" "$label" || yaml_rc=$?
  [ "$yaml_rc" -eq 0 ] || return "$yaml_rc"

  local regexes
  regexes="$(extract_regexes "$yml")"
  if [ -z "$regexes" ]; then
    echo "FAIL[$label]: no 'grep -qE' job filters found inside the 'changes' job — the extractor is broken, not the workflow" >&2
    echo "Cause: extract_regexes ends the job at the next line indented exactly two spaces and ending in ':'," >&2
    echo "so a 2-space-indented heredoc body (or any such line) inside the job truncates the scan. Re-indent it," >&2
    echo "or teach the awk boundary about it — do NOT widen the scan back to the whole file (a regex outside the" >&2
    echo "'changes' job dispatches nothing and would let a new job green this gate for free)." >&2
    return 1
  fi

  local path state sample matched re
  while IFS=$'\t' read -r path state; do
    [ -n "$path" ] || continue
    if [ "$state" = "EXEMPT" ]; then
      exempted=$((exempted + 1))
      echo "  exempt   $path (deploy-filter-exempt)"
      continue
    fi

    checked=$((checked + 1))
    sample="$(sample_for "$path")"
    matched=""
    while IFS= read -r re; do
      [ -n "$re" ] || continue
      if printf '%s\n' "$sample" | grep -qE "$re"; then
        matched="$re"
        break
      fi
    done <<EOF
$regexes
EOF

    if [ -n "$matched" ]; then
      echo "  ok       $path  ->  $matched"
    else
      echo "  DRIFT    $path  ->  matched by NO job filter (a merge here runs the workflow and deploys nothing)" >&2
      failures=$((failures + 1))
    fi
  done <<EOF
$(extract_paths "$yml")
EOF

  if [ "$checked" -eq 0 ]; then
    echo "FAIL[$label]: no on.push.paths entries found — the extractor is broken" >&2
    return 1
  fi

  # Required-path presence: the drift loop above only judges PRESENT paths; a
  # DELETED required path leaves nothing to drift, so this arm asserts it too.
  local presence_rc=0
  check_required_paths "$yml" "$label" || presence_rc=$?

  # The other direction: a job filter naming a prefix on.push.paths cannot
  # deliver. Run unconditionally so ONE run reports every drift it can see —
  # a gate that stops at the first arm teaches authors to fix one thing per CI
  # round trip.
  local reverse_rc=0
  check_reverse "$yml" "$label" || reverse_rc=$?

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures path(s) start the deploy workflow but target no deploy job." >&2
    echo "Fix: add the prefix to the matching job's grep -qE regex in the 'changes' job," >&2
    echo "or, if it is deliberately targetless, add a '# deploy-filter-exempt: <why>' comment above it." >&2
    return 1
  fi

  if [ "$presence_rc" -ne 0 ] || [ "$reverse_rc" -ne 0 ]; then
    return 1
  fi

  echo "OK[$label]: $checked path(s) each target at least one deploy job ($exempted exempt); reverse: $REVERSE_PREFIXES regex prefix(es), all reachable from on.push.paths."
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
  local out sub_rc

  echo "selftest 1/10: the real workflow passes"
  if ! check_file "$real" "real"; then
    echo "SELFTEST FAIL: the real deploy.yml does not pass" >&2
    rc=1
  fi

  echo
  echo "selftest 2/10: dropping 'templates' from the instance regex must FAIL (the original bug)"
  sed "s#|connectors|templates|scripts/connectors)/#|connectors|scripts/connectors)/#" "$real" > "$tmp/mutated.yml"
  if cmp -s "$real" "$tmp/mutated.yml"; then
    echo "SELFTEST FAIL: the mutation changed nothing — the instance regex no longer looks as expected" >&2
    rc=1
  elif check_file "$tmp/mutated.yml" "mutated" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a templates-less regex read GREEN — the gate cannot fail" >&2
    rc=1
  else
    echo "  ok: the gate reds when templates/** loses its target"
  fi

  echo
  echo "selftest 3/10: an unexplained targetless path must FAIL"
  awk '{ print } /^      - "connectors\/\*\*"$/ { print "      - \"totally-unrouted/**\"" }' \
    "$real" > "$tmp/orphan.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/orphan.yml"; then
    echo "SELFTEST FAIL: the orphan-path injection changed nothing" >&2
    rc=1
  else
    out="$(check_file "$tmp/orphan.yml" "orphan" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an unrouted path read GREEN" >&2
      rc=1
    elif ! printf '%s\n' "$out" | grep -q 'DRIFT    totally-unrouted/\*\*'; then
      # The FORWARD arm must still own this verdict. Once a second direction
      # exists, "it red" stops being evidence that the direction under test red
      # — so the diagnostic is pinned by name.
      echo "SELFTEST FAIL: it red, but not on the forward drift arm naming the path" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds on a path no job targets (forward arm, by name)"
    fi
  fi

  echo
  echo "selftest 4/10: another job's own regex must NOT rescue a drifted dispatch filter"
  # The disarm shape, verbatim: strip `templates` from the instance filter AND
  # append a recorder job whose shell carries a copy of the same regex. Before
  # extract_regexes was scoped to `changes`, this read OK at rc=0.
  sed "s#|connectors|templates|scripts/connectors)/#|connectors|scripts/connectors)/#" "$real" > "$tmp/disarm.yml"
  cat >> "$tmp/disarm.yml" <<'YML'

  selftest-recorder:
    runs-on: ubuntu-latest
    steps:
      - run: |
          if echo "$changed" | grep -qE '^(api|internal|deploy|connectors|templates)/'; then echo instance; fi
YML
  if ! grep -q 'selftest-recorder' "$tmp/disarm.yml"; then
    echo "SELFTEST FAIL: the recorder job was not appended" >&2
    rc=1
  elif check_file "$tmp/disarm.yml" "disarm" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a non-dispatching job's regex greened the gate — it is disarmable again" >&2
    rc=1
  else
    echo "  ok: only the 'changes' job's own filters answer for a path"
  fi

  echo
  echo "selftest 5/10: the YAML arm must PASS the real workflow and FAIL an unparseable one"
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

  echo
  echo "selftest 6/10: deleting the required scripts/connectors/** path must FAIL (the presence allowlist)"
  # Mirror of case 2, but for DELETION not drift: strip the required push-path
  # line entirely. The drift arm now sees nothing to judge — the false-green W35
  # exists to close (charter D275). (Since the reverse arm landed, this half also
  # reds there: the instance regex still names `scripts/connectors` and nothing
  # delivers it. Case 9 removes BOTH halves, which is the shape only the presence
  # allowlist can catch.)
  grep -v '^      - "scripts/connectors/\*\*"$' "$real" > "$tmp/nopath.yml"
  if cmp -s "$real" "$tmp/nopath.yml"; then
    echo "SELFTEST FAIL: the path-strip mutation changed nothing — scripts/connectors/** is not listed as expected" >&2
    rc=1
  elif check_file "$tmp/nopath.yml" "nopath" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a copy missing scripts/connectors/** read GREEN — the presence allowlist cannot fail" >&2
    rc=1
  else
    echo "  ok: the gate reds when a required path is deleted from on.push.paths"
  fi

  echo
  echo "selftest 7/10: a job-filter prefix absent from on.push.paths must FAIL (the reverse direction)"
  # `web` is dispatched by the control-plane filter, but no on.push.paths entry
  # delivers a web/ file — so a web-only merge never starts the workflow and that
  # arm of the filter can only ever fire on somebody else's co-triggering merge.
  sed "s#(cloud|deploy|internal|cmd)/#(cloud|deploy|internal|cmd|web)/#" "$real" > "$tmp/unreachable.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/unreachable.yml"; then
    echo "SELFTEST FAIL: the reverse mutation changed nothing — the cp filter no longer looks as expected" >&2
    rc=1
  else
    out="$(check_file "$tmp/unreachable.yml" "unreachable" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an unreachable job-filter prefix read GREEN — the reverse arm cannot fail" >&2
      rc=1
    elif ! printf '%s\n' "$out" | grep -q 'UNREACHABLE  web/'; then
      echo "SELFTEST FAIL: the gate red, but not on the reverse arm and not naming 'web'" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds, BY NAME, on a prefix on.push.paths cannot deliver"
    fi
  fi

  echo
  echo "selftest 8/10: the reverse arm must actually RUN on the real workflow (non-vacuity)"
  # A direction that silently checks nothing is worse than no direction: it puts
  # the word "reverse" in a green line. So the count must be non-zero AND the
  # per-prefix verdicts must be present, on the REAL file.
  sub_rc=0
  out="$(check_file "$real" "reverse-count" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the real deploy.yml did not pass with the reverse arm wired in" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! printf '%s\n' "$out" | grep -qE 'reverse: [1-9][0-9]* regex prefix\(es\), all reachable'; then
    echo "SELFTEST FAIL: no non-zero reverse count in the output — the arm ran vacuously" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! printf '%s\n' "$out" | grep -q 'reach    scripts/connectors/'; then
    echo "SELFTEST FAIL: the reverse arm did not judge the scripts/connectors prefix (charter D275)" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    printf '%s\n' "$out" | grep -E '^  reverse: [0-9]+ regex prefix' | sed 's/^ */  ok: /'
  fi

  echo
  echo "selftest 9/10: deleting BOTH halves must still FAIL — on the presence allowlist ALONE"
  # The D275 shape, and the reason the allowlist is not made redundant by the
  # reverse arm: with the push-path line AND its regex prefix both gone, the
  # forward arm has no path to judge and the reverse arm has no prefix to judge.
  # Both read clean. Only the allowlist reds.
  grep -v '^      - "scripts/connectors/\*\*"$' "$real" \
    | sed "s#|templates|scripts/connectors)/#|templates)/#" > "$tmp/bothgone.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/bothgone.yml"; then
    echo "SELFTEST FAIL: the both-halves mutation changed nothing" >&2
    rc=1
  else
    out="$(check_file "$tmp/bothgone.yml" "bothgone" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: both halves deleted read GREEN — the presence allowlist cannot fail" >&2
      rc=1
    elif ! printf '%s\n' "$out" | grep -q 'MISSING  scripts/connectors/\*\*'; then
      echo "SELFTEST FAIL: it red, but not on the presence allowlist" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif printf '%s\n' "$out" | grep -qE 'DRIFT|UNREACHABLE'; then
      echo "SELFTEST FAIL: the drift or reverse arm also red — this fixture is meant to prove" >&2
      echo "               they see NOTHING once both halves are gone, which is why the" >&2
      echo "               presence allowlist is load-bearing and not redundant" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: forward and reverse both read clean; only the presence allowlist reds"
    fi
  fi

  echo
  echo "selftest 10/10: a 'changes' filter the reverse arm cannot decompose must FAIL, not be skipped"
  # The fail-closed arm of prefixes_of, proven rather than asserted. A dispatch
  # filter that is not an anchored alternation is a filter this direction cannot
  # answer for — and "could not look" must never print as "it is fine". Without
  # this case that branch is unexercised code, which is how a fail-closed arm
  # quietly becomes a fail-open one.
  sed "s#grep -qE '\^(cloud|deploy|internal|cmd)/'#grep -qE 'cloud|deploy'#" "$real" > "$tmp/badshape.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/badshape.yml"; then
    echo "SELFTEST FAIL: the shape mutation changed nothing — the cp filter no longer looks as expected" >&2
    rc=1
  else
    out="$(check_file "$tmp/badshape.yml" "badshape" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an undecomposable dispatch filter read GREEN — the arm fails OPEN" >&2
      rc=1
    elif ! printf '%s\n' "$out" | grep -q 'cannot decompose'; then
      echo "SELFTEST FAIL: it red, but not on the undecomposable-filter arm" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: an unreadable dispatch filter reds instead of being passed over"
    fi
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
