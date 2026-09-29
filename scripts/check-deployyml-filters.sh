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
#            `deploy-filter-exempt[<job>,…]:` comment in the block ABOVE it,
#            which makes the exception explicit and reviewable instead of
#            invisible — and BOUNDED: the annotation names the job(s) it
#            deliberately does not target, each named job's regex must indeed
#            NOT match the entry, the entry must still target every job it did
#            not name, and an entry exempt from EVERY job must be a single file.
#            A tree (`x/**`) that starts the workflow deploys something, so a
#            tree can never be fully exempt. Measured (task-9ece1f95b89111cf):
#            an unbounded `deploy-filter-exempt:` over `internal/**` plus
#            `internal|` stripped from both regexes read OK at rc=0 — the
#            annotation silenced the forward arm, the reverse arm had no prefix
#            left to judge, and TARGET_PAIRS did not list internal.
#
#   reverse  every alternation prefix inside a `changes` job filter must be
#            REACHABLE from `on.push.paths` — a prefix the workflow never starts
#            for is dead text that deploys only when another path co-triggers.
#
#   presence a small allowlist of paths that must stay LISTED, because a path
#            deleted together with its regex prefix leaves nothing for either
#            direction to judge.

#   target   a declared table of (path prefix -> the job that MUST fire for it),
#            each row derived from what a deploy script actually BUILDS from that
#            tree. Forward/reverse/presence all read a path routed to the WRONG
#            job as a path routed — first match wins — so none of them can see
#            `cmd/` matching the control-plane filter while instance-deploy.sh is
#            the only thing that builds the agent binary out of it.
#
#   coverage the table above is an ENUMERATION, and an enumeration is a
#            snapshot: a path it omits is a path the target arm never judges.
#            So it is held to `on.push.paths` as a PREDICATE, both ways: every
#            listed entry that is not exempt from every job must have a row
#            naming a job it is not exempt from (UNDECLARED otherwise), and
#            every row's prefix must be a listed entry (UNLISTED otherwise —
#            a row whose tree cannot start the workflow guards nothing).
#
# `--selftest` PROVES the tripwire on temp copies (plants nothing in the tree):
# the real file passes, a copy with `templates` stripped from the instance regex
# FAILS, an unexplained targetless path FAILS, an unreachable job-filter prefix
# FAILS, a deleted required path FAILS, a copy with `cmd` stripped from the
# instance regex FAILS ON THE TARGET ARM ALONE (every other arm reads clean —
# that is the whole point of the arm), a copy that is not parseable YAML at
# all FAILS, a tree exempted from every job with its prefix stripped from both
# regexes (Mutation C) FAILS, an unbounded exemption FAILS, an exemption whose
# named job still matches FAILS, and a routed path with no TARGET_PAIRS row
# FAILS on the coverage predicate alone. For the api/test exclusion, four more,
# each ISOLATING one arm: deleting the `!api/test/**` push-path line FAILS on the
# presence allowlist alone, neutering the classifier's `grep -vE` half FAILS on
# the BEHAVIOURAL arm alone, widening the exclusion to all of `api/` FAILS on the
# CONTROL alone, and dropping the whole diff instead of just the excluded files
# FAILS on the MIXED case alone. Modelled on
# scripts/connectors-catalog-drift-check.sh's bundled selftest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The ONE job/step boundary, shared with scripts/check-deploy-smoke.sh. The awk
# rule this file used to carry (`/^  [a-zA-Z0-9_-]+:/`) matched TEXT, so a
# top-level block scalar with a 2-space body could hand it a STRING that reads as
# the `changes` job — see the lib header.
# shellcheck source=scripts/lib/deploy-yaml-scope.sh
. "$REPO_ROOT/scripts/lib/deploy-yaml-scope.sh"

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
# comment block carries `deploy-filter-exempt[<jobs>]:` is emitted with a
# trailing "\tEXEMPT:<jobs>" column (`EXEMPT:cp,instance`); the legacy
# unbounded spelling `deploy-filter-exempt:` yields "\tEXEMPT:" with an EMPTY
# job list, which the forward arm reds as UNBOUNDED — an exemption that names
# nothing exempts from everything, which is how Mutation C read green.
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
    in_paths && /^ *#/ {
      if ($0 ~ /deploy-filter-exempt/) {
        exempt = 1
        jobs = ""
        if (match($0, /deploy-filter-exempt\[[^]]*\]/)) {
          # "deploy-filter-exempt[" is 21 bytes; drop it and the closing "]".
          jobs = substr($0, RSTART + 21, RLENGTH - 22)
          gsub(/[ \t]/, "", jobs)
        }
      }
      next
    }
    in_paths && /^ *- / {
      line = $0
      sub(/^ *- */, "", line)
      gsub(/"/, "", line)
      gsub(/\047/, "", line)
      if (line == "") next
      # A leading "!" is a GitHub path-filter EXCLUSION, not a trigger: it can
      # never START the workflow, so the forward/reverse/coverage arms must not
      # judge it as one (each would read it as a path targeting no deploy job).
      # It gets its own arm instead — check_exclusions below.
      if (substr(line, 1, 1) == "!") { print line "\tEXCLUSION"; exempt = 0; jobs = ""; next }
      print line "\t" (exempt ? "EXEMPT:" jobs : "REQUIRED")
      exempt = 0
      jobs = ""
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
  deploy_yaml_job_lines "$1" changes \
    | { grep -oE "grep -qE '[^']+'" || true; } | sed -E "s/^grep -qE '//; s/'$//"
}

# The same filters, each PAIRED with the job flag its line sets — one
# "<job>\t<regex>" per line (`cp\t^(cloud|…)/`). The bounded-exemption arm needs
# to know WHICH job a regex dispatches: an exemption that names `cp` is a claim
# about the cp regex specifically. Same scope as extract_regexes; a filter line
# that sets no `<job>=true` is not a dispatch and is not paired.
extract_job_regexes() {
  deploy_yaml_job_lines "$1" changes \
    | { grep -oE "grep -qE '[^']+'; then [a-z_]+=true" || true; } \
    | sed -E "s/^grep -qE '([^']+)'; then ([a-z_]+)=true$/\2\t\1/"
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

# The mirror of REQUIRED_PATHS for the other direction (task-75f45c6baba2e633).
# An EXCLUSION is invisible to every arm that judges triggers, so deleting the
# `- "!api/test/**"` line leaves nothing to drift and the gate would read green
# over a workflow that redeploys production for a change a prod build cannot
# compile (api/mix.exs elixirc_paths(_) is ["lib"]). Measured before the
# exclusion landed: 86 of 890 deploy-triggering merges in seven days matched
# ONLY because of files under api/test/.
#
# This pins PRESENCE. check_exclusions below pins BEHAVIOUR — the two halves of
# the same deletion, exactly as REQUIRED_PATHS and the drift arm are.
REQUIRED_EXCLUSIONS=(
  "!api/test/**"
)

# Assert every REQUIRED_PATHS entry appears in extract_paths() output (either
# REQUIRED or EXEMPT column — presence is what matters here, drift is the other
# arm's job). Fails closed if any is absent.
check_required_paths() {
  local yml="$1" label="$2"
  local present missing=0 req
  present="$(extract_paths "$yml" | cut -f1)"
  for req in "${REQUIRED_PATHS[@]}"; do
    # HERE-STRING, NOT A PIPE. `printf ... | grep -q` races: grep -q exits on the
    # first match, printf takes SIGPIPE, and `set -o pipefail` hands the whole
    # pipeline 141 — so a MATCH intermittently reads as a MISS. Measured on
    # origin/main at ~0.7% per call (2 misses in 300), which is a required gate
    # printing `MISSING scripts/connectors/**` against a file that lists it.
    # Every `grep -q` test in this file is fed by a here-string for that reason.
    if grep -qxF "$req" <<<"$present"; then
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

# Assert every REQUIRED_EXCLUSIONS entry is still listed under on.push.paths.
check_required_exclusions() {
  local yml="$1" label="$2"
  local present missing=0 req
  present="$(extract_paths "$yml" | cut -f1)"
  for req in "${REQUIRED_EXCLUSIONS[@]}"; do
    # Here-string, not a pipe — same pipefail+SIGPIPE reason as above.
    if grep -qxF "$req" <<<"$present"; then
      echo "  present  $req (required on.push.paths EXCLUSION)"
    else
      echo "  MISSING  $req  ->  required on.push.paths exclusion absent (a merge under that subtree would deploy production again)" >&2
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    echo "FAIL[$label]: $missing required exclusion(s) absent from on.push.paths." >&2
    echo "Fix: restore the '- \"!<path>\"' entry AFTER the positive entry it narrows (GitHub applies the" >&2
    echo "LAST matching pattern per changed file) AND keep the matching 'grep -vE' line in the 'changes'" >&2
    echo "job. Deleting either half is the regression this allowlist exists to catch." >&2
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

  # Every LISTED path counts, EXEMPT included: `deploy-filter-exempt` says the
  # entry targets no deploy job, not that it cannot start the workflow — and
  # starting the workflow is the entire question this direction asks. An
  # EXCLUSION is the one thing that does NOT count: a `!` entry cannot deliver a
  # file to anything, so treating it as a deliverer would manufacture
  # reachability — a false PASS in the one arm that exists to catch its absence.
  paths_globs="$(extract_paths "$yml" | awk -F'\t' '$2 != "EXCLUSION" { print $1 }')"
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
        if grep -qE "$entry_re" <<<"$sample"; then
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

# ── behaviour: the changed-file PRODUCER, driven, not grepped ────────────────
#
# THE BUG THIS ARM EXISTS FOR
#
# Everything above judges the two LISTS. It says nothing about the line that
# feeds them. The `changes` job built `$changed` with the plain producer:
#
#     changed="$(git diff --name-only "$base" "${{ github.sha }}")"
#
# and that line drops files SILENTLY in two shapes, both of which decide whether
# PRODUCTION ROLLS:
#
#   • `--name-only` prints a path containing `"` QUOTED (`"cloud/we\"ird.ex"`),
#     even under core.quotepath=false, so the anchored `^(cloud|…)/` filter
#     misses it — cp=false, control plane does not deploy, run reports GREEN;
#   • rename detection prints only the DESTINATION, so `cloud/x.ex` renamed to
#     `docs/x.ex` never appears as a cloud/ path at all. Code LEFT the control
#     plane's tree and the control plane was never rebuilt.
#
# Neither shape is visible to a text scan of the two lists — every fixture the
# arms above use is ASCII and rename-free, which is exactly why the drift gate
# could pass over this for as long as it did.
#
# So this arm EXTRACTS the `changes` step body out of the file under test and
# EXECUTES it against real git fixtures. It cannot paraphrase what CI runs. The
# `${{ … }}` expressions are substituted from the environment (the only way to
# run an Actions body outside Actions) and `gh` is stubbed to return nothing, so
# the base resolution falls to the supplied anchor and no network is touched.
#
# --selftest case 11 restores the pre-fix producer on a copy and proves both
# shapes go RED here, so this arm has been shown to lose.

PRODUCER_TMP=""
producer_cleanup() { [ -n "$PRODUCER_TMP" ] && rm -rf "$PRODUCER_TMP"; return 0; }
trap 'producer_cleanup; anchor_cleanup' EXIT

# Built once and reused: every fixture branch hangs off one base commit, so the
# repeated check_file calls inside --selftest do not each pay for a git init.
producer_fixture() {
  [ -n "$PRODUCER_TMP" ] && return 0
  PRODUCER_TMP="$(mktemp -d)"
  local dr="$PRODUCER_TMP/repo"
  mkdir -p "$dr/cloud" "$dr/docs" "$dr/api"
  printf 'plain\n' >"$dr/api/thing.ex"
  # NON-EMPTY on purpose — rename detection needs a real similarity source.
  printf 'cp-a\ncp-b\ncp-c\ncp-d\n' >"$dr/cloud/moved.ex"
  printf 'guide\n' >"$dr/docs/guide.md"
  git -C "$dr" init -q
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  PRODUCER_BASE="$(git -C "$dr" rev-parse HEAD)"

  # (1) a control-plane file whose name contains a DOUBLE QUOTE. Written from a
  # variable, never threaded through a nested quoting layer: this arm is ABOUT
  # quote-bearing paths and a fixture that breaks on its own quoting proves
  # nothing.
  local dq='cloud/we"ird.ex'
  git -C "$dr" checkout -q -b dquote "$PRODUCER_BASE"
  printf 'weird\n' >"$dr/$dq"
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm dquote >/dev/null 2>&1

  # (2) a control-plane file renamed OUT of cloud/. The CP must still roll: code
  # it used to build just left its tree.
  git -C "$dr" checkout -q -b renameout "$PRODUCER_BASE"
  git -C "$dr" mv cloud/moved.ex docs/moved.ex >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm renameout >/dev/null 2>&1

  # (3) the control: a docs-only change must still classify cp=false, so a pass
  # above is a filter answering, not a tautology that says true to everything.
  git -C "$dr" checkout -q -b docsonly "$PRODUCER_BASE"
  printf 'more\n' >>"$dr/docs/guide.md"
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm docsonly >/dev/null 2>&1

  # the gh stub: `gh run list` answers empty, so `base` falls through to the
  # anchor this harness supplies. No token, no network, no live GitHub.
  mkdir -p "$PRODUCER_TMP/bin"
  printf '#!/bin/sh\nexit 0\n' >"$PRODUCER_TMP/bin/gh"
  chmod +x "$PRODUCER_TMP/bin/gh"
  return 0
}

# extract_changes_step <yml> <dest.sh> — fails loudly rather than writing an
# empty body that would "pass" every case below.
extract_changes_step() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for s in wf["jobs"]["changes"]["steps"] if s.get("id") == "f"]
if len(steps) != 1 or "run" not in steps[0]:
    sys.exit("expected exactly 1 run-bearing step id 'f' in the changes job, found %d"
             % len(steps))
body = (steps[0]["run"]
        .replace("${{ github.sha }}", "${T_SHA}")
        .replace("${{ github.event.before }}", "${T_BEFORE}"))
open(sys.argv[2], "w").write(body)
PY
}

# classify <step.sh> <branch> <key> -> prints the emitted value, or nothing
classify() {
  local step="$1" br="$2" key="$3" dr="$PRODUCER_TMP/repo"
  local out="$PRODUCER_TMP/gh_output"
  git -C "$dr" checkout -q "$br"
  : >"$out"
  ( cd "$dr" && env -u DISPATCH_TARGETS -u DISPATCH_REASON \
      PATH="$PRODUCER_TMP/bin:$PATH" \
      GITHUB_EVENT_NAME=push \
      GITHUB_OUTPUT="$out" \
      T_SHA="$(git -C "$dr" rev-parse HEAD)" \
      T_BEFORE="$PRODUCER_BASE" \
      bash --noprofile --norc "$step" ) >"$PRODUCER_TMP/step.out" 2>&1 || true
  sed -n "s/^${key}=//p" "$out" | tail -1
}

# check_producer <yml> <label> — 0 if both false-green shapes still classify
# correctly, 1 otherwise.
check_producer() {
  local yml="$1" label="$2" step got rc=0
  if ! command -v python3 >/dev/null 2>&1; then
    echo "HARNESS-UNAVAILABLE[$label]: python3 not on PATH — the producer arm cannot run." >&2
    return 2
  fi
  producer_fixture
  step="$PRODUCER_TMP/changes-step.sh"
  if ! extract_changes_step "$yml" "$step" 2>"$PRODUCER_TMP/extract.err"; then
    echo "FAIL[$label]: could not extract the 'changes' job's step id 'f': $(cat "$PRODUCER_TMP/extract.err")" >&2
    return 1
  fi

  got="$(classify "$step" dquote cp)"
  if [ "$got" = "true" ]; then
    echo "  produce  a cloud/ path containing a double quote  ->  cp=true"
  else
    echo "  ESCAPE   a cloud/ path containing a double quote  ->  cp=${got:-<none>}, wanted true" >&2
    echo "           The producer prints it QUOTED, so the anchored ^(cloud|...)/ filter misses it" >&2
    echo "           and the control plane silently does not deploy under a GREEN run. Fix:" >&2
    echo "           git -c core.quotepath=false diff -z --name-only --no-renames <range> | tr '\\0' '\\n'" >&2
    rc=1
  fi

  got="$(classify "$step" renameout cp)"
  if [ "$got" = "true" ]; then
    echo "  produce  a cloud/ file renamed OUT of cloud/       ->  cp=true"
  else
    echo "  ESCAPE   a cloud/ file renamed OUT of cloud/       ->  cp=${got:-<none>}, wanted true" >&2
    echo "           Rename detection prints only the DESTINATION, so code that LEFT the control" >&2
    echo "           plane's tree never appears as a cloud/ path. Fix: --no-renames." >&2
    rc=1
  fi

  # The control. Without it, a producer that emitted every path in the repo
  # would satisfy both cases above and this arm would certify a tautology.
  got="$(classify "$step" docsonly cp)"
  if [ "$got" = "false" ]; then
    echo "  produce  a docs-only change                        ->  cp=false (the filter still answers)"
  else
    echo "  FAIL     a docs-only change  ->  cp=${got:-<none>}, wanted false — the filter says true to" >&2
    echo "           everything, so the two cases above prove nothing." >&2
    rc=1
  fi

  return "$rc"
}

# ── anchor: the last run that DEPLOYED, not the last that SUCCEEDED ──────────
#
# THE BUG THIS ARM EXISTS FOR (task-220b847a8072f82e)
#
# The `changes` step anchors its diff to a previous run of this workflow. It
# used to pick that run with `gh run list --status=success --limit=1` — a
# RUN-LEVEL conclusion. But two arms of that same step finish a run in seconds
# having deployed NOTHING: "superseded at start" (deploy-supersede-exit.sh rc 3)
# and "already covered". Both write cp=false + instance=false and exit 0, and a
# run whose only job succeeded IS a success run. So the anchor was routinely a
# run that never touched a box, the next run's range collapsed to
# <superseded sha>..<its sha>, and every deployable file merged BEFORE that sha
# dropped silently out of the classification under a GREEN run.
#
# MEASURED 2026-09-18: run 35334681747 (bfbdd50ff) exited superseded -> success;
# run 35335602083 (ffb3b90c9) then printed `diff base: bfbdd50ff…` and
# classified instance=false while api/lib changes from #19327 sat undeployed.
#
# No LIST arm can see this — the two path lists are untouched, the producer line
# is untouched, and the classifier answers correctly about the range it was
# given. Only the RANGE is wrong. So this arm, like the producer arm, EXTRACTS
# the real `changes` step body and EXECUTES it, against a real git fixture and a
# `gh` stub that serves a run history in which the newest success deployed
# nothing. The stub applies the workflow's own `--jq` filters with real jq, so
# the jq expressions are under test rather than paraphrased.

ANCHOR_TMP=""
ANCHOR_BASE_SHA=""
ANCHOR_DEPLOYED_SHA=""
ANCHOR_SUPERSEDED_SHA=""
ANCHOR_HEAD_SHA=""
anchor_cleanup() { [ -n "$ANCHOR_TMP" ] && rm -rf "$ANCHOR_TMP"; return 0; }

# The history, in merge order:
#   C0 base
#   C1 cloud/a.ex      <- head of run 111, the run that ACTUALLY deployed
#   C2 api/lib/x.ex    <- the deployable merge a collapsed range loses (#19327)
#   C3 docs only       <- head of run 222, which exited SUPERSEDED (no leg ran)
#   C4 docs only       <- this run's sha
# C4's own push is docs-only, so instance=true is reachable ONLY by anchoring
# back past C3 to C1. That is the whole defect, expressed as a fixture.
anchor_fixture() {
  [ -n "$ANCHOR_TMP" ] && return 0
  ANCHOR_TMP="$(mktemp -d)"
  local dr="$ANCHOR_TMP/repo"
  mkdir -p "$dr/docs" "$dr/api/lib" "$dr/cloud"
  git -C "$dr" init -q
  printf 'guide\n' >"$dr/docs/guide.md"
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm c0 >/dev/null 2>&1
  ANCHOR_BASE_SHA="$(git -C "$dr" rev-parse HEAD)"

  printf 'cp\n' >"$dr/cloud/a.ex"
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm c1-deployed >/dev/null 2>&1
  ANCHOR_DEPLOYED_SHA="$(git -C "$dr" rev-parse HEAD)"

  printf 'x\n' >"$dr/api/lib/x.ex"
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm c2-stranded >/dev/null 2>&1

  printf 'more\n' >>"$dr/docs/guide.md"
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm c3-superseded >/dev/null 2>&1
  ANCHOR_SUPERSEDED_SHA="$(git -C "$dr" rev-parse HEAD)"

  printf 'more2\n' >>"$dr/docs/guide.md"
  git -C "$dr" add -A >/dev/null 2>&1
  git -C "$dr" -c user.email=t@t -c user.name=t commit -qm c4-head >/dev/null 2>&1
  ANCHOR_HEAD_SHA="$(git -C "$dr" rev-parse HEAD)"

  mkdir -p "$ANCHOR_TMP/bin"
  cat >"$ANCHOR_TMP/bin/gh" <<'GHSTUB'
#!/bin/sh
# gh stub. Answers `run list` and `api .../runs/<id>/jobs` from two fixture
# files, then applies the caller's REAL --jq filter with real jq.
filter=""; prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && filter="$a"
  prev="$a"
done
case "$1" in
  run)
    # The supersede enumeration above asks WITHOUT --status; answer it empty so
    # this fixture measures the anchor and nothing else.
    case " $* " in
      *" --status success "*|*" --status=success "*) ;;
      *) exit 0 ;;
    esac
    # Assigned in two steps on purpose: bash 3.2 (macOS /bin/sh) mis-parses a
    # single-quoted awk program nested inside "$( … )" and brace-expands the
    # braces of the JSON object, which silently yields an EMPTY run list — i.e. a
    # green arm that measured nothing.
    rows=$(awk '{ printf "%s{\"databaseId\":%s,\"headSha\":\"%s\"}", (NR>1 ? "," : ""), $1, $2 }' "$ANCHOR_RUNS_FILE")
    printf '[%s]' "$rows" | jq -r "$filter"
    ;;
  api)
    id=$(printf '%s' "$2" | sed -n 's#.*/runs/\([0-9][0-9]*\)/jobs.*#\1#p')
    # `changes` succeeds on EVERY run, superseded ones included — a stub that
    # omitted it would let a name-blind selector pass.
    if grep -qx "$id" "$ANCHOR_LEGS_FILE" 2>/dev/null; then
      printf '{"jobs":[{"name":"changes","conclusion":"success"},{"name":"control-plane","conclusion":"skipped"},{"name":"instance","conclusion":"success"}]}'
    else
      printf '{"jobs":[{"name":"changes","conclusion":"success"},{"name":"control-plane","conclusion":"skipped"},{"name":"instance","conclusion":"skipped"}]}'
    fi | jq -r "$filter"
    ;;
esac
exit 0
GHSTUB
  chmod +x "$ANCHOR_TMP/bin/gh"
  return 0
}

# anchor_run <step.sh> <runs> <legs> -> "<observed base sha>|<instance>"
# <runs> is "<id> <sha>" per line, NEWEST FIRST; <legs> lists the ids whose
# instance job concluded success.
anchor_run() {
  local step="$1" runs="$2" legs="$3" dr="$ANCHOR_TMP/repo"
  local out="$ANCHOR_TMP/gh_output"
  printf '%s\n' "$runs" >"$ANCHOR_TMP/runs.txt"
  printf '%s\n' "$legs" >"$ANCHOR_TMP/legs.txt"
  : >"$out"
  # T_BEFORE is C0, deliberately DIFFERENT from both candidate anchors: a base
  # that silently fell through to the github.event.before fallback is then
  # visible as C0 rather than masquerading as a correct answer.
  ( cd "$dr" && env -u DISPATCH_TARGETS -u DISPATCH_REASON \
      PATH="$ANCHOR_TMP/bin:$PATH" \
      GITHUB_EVENT_NAME=push \
      GITHUB_REPOSITORY=FRIKKern/barkpark \
      GITHUB_RUN_ID=999 \
      GITHUB_OUTPUT="$out" \
      ANCHOR_RUNS_FILE="$ANCHOR_TMP/runs.txt" \
      ANCHOR_LEGS_FILE="$ANCHOR_TMP/legs.txt" \
      T_SHA="$ANCHOR_HEAD_SHA" \
      T_BEFORE="$ANCHOR_BASE_SHA" \
      bash --noprofile --norc "$step" ) >"$ANCHOR_TMP/step.out" 2>&1 || true
  printf '%s|%s' \
    "$(sed -n 's/^diff base: //p' "$ANCHOR_TMP/step.out" | tail -1)" \
    "$(sed -n 's/^instance=//p' "$out" | tail -1)"
}

# anchor_plant_drain <step.sh> <dst.sh> — the extracted step body with a
# STDIN-DRAINING CHILD planted as the first statement of the anchor loop.
#
# WHY A PLANT AND NOT A FIXTURE. The hazard is not in the candidate list; it is
# in the loop's own fd 0. `cat >/dev/null` in the body is the smallest exact
# stand-in for the shapes that actually appear in deploy code — `ssh` without
# -n, a `-` operand, `docker exec -i` — each of which reads the REST of the
# heredoc and ends the loop after one iteration. deploy-w5 measured this on a
# copy: every child in the real body processes 3 of 3 candidates, an unguarded
# `cat` processes 1 of 3. So the plant is a MEASURED shape, not an invented one.
#
# It refuses rather than writing a copy that is silently unmutated: a plant that
# did not apply would make the arm below certify nothing at all.
anchor_plant_drain() {
  local src="$1" dst="$2" n
  n="$(grep -c '^[[:space:]]*while read -r cand_id cand_sha; do$' "$src" || true)"
  if [ "${n:-0}" -ne 1 ]; then
    echo "PLANT-REFUSED: the anchor loop header matched ${n:-0} time(s) in the extracted step, wanted 1 — the loop no longer looks as this arm expects. Fix the arm, do not loosen it." >&2
    return 1
  fi
  awk '{ print; if ($0 ~ /^[[:space:]]*while read -r cand_id cand_sha; do$/) print "  cat >/dev/null 2>&1 || true" }' \
    "$src" >"$dst"
  if cmp -s "$src" "$dst"; then
    echo "PLANT-REFUSED: the stdin-draining child produced an IDENTICAL file — it did not apply." >&2
    return 1
  fi
  return 0
}

# check_anchor <yml> <label> — 0 if a run that deployed nothing is never the
# anchor AND a run that did deploy still is.
check_anchor() {
  local yml="$1" label="$2" step got base inst rc=0 hist
  if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "HARNESS-UNAVAILABLE[$label]: python3 and jq are both required — the anchor arm cannot run." >&2
    return 2
  fi
  anchor_fixture
  step="$ANCHOR_TMP/changes-step.sh"
  if ! extract_changes_step "$yml" "$step" 2>"$ANCHOR_TMP/extract.err"; then
    echo "FAIL[$label]: could not extract the 'changes' job's step id 'f': $(cat "$ANCHOR_TMP/extract.err")" >&2
    return 1
  fi
  hist="222 $ANCHOR_SUPERSEDED_SHA
111 $ANCHOR_DEPLOYED_SHA"

  # THE INVARIANT. Newest success (222) had BOTH legs skipped; the older run
  # (111) deployed. The anchor must be 111's head, and the api/lib/ file merged
  # between them must come back into the range.
  got="$(anchor_run "$step" "$hist" "111")"
  base="${got%%|*}"; inst="${got##*|}"
  if [ "$base" = "$ANCHOR_DEPLOYED_SHA" ] && [ "$inst" = "true" ]; then
    echo "  anchor   newest success deployed NOTHING  ->  diff base: $base (run 111, the last that deployed), instance=true"
  else
    echo "  ESCAPE   newest success deployed NOTHING  ->  diff base: ${base:-<none>}, instance=${inst:-<none>}" >&2
    echo "           wanted diff base: $ANCHOR_DEPLOYED_SHA (run 111, instance job concluded success) and instance=true." >&2
    echo "           run 222's head is $ANCHOR_SUPERSEDED_SHA — it exited superseded-at-start, so both" >&2
    echo "           legs SKIPPED and no box moved; github.event.before is $ANCHOR_BASE_SHA." >&2
    echo "           Anchoring on a run-level 'success' collapses the range and strands every deployable" >&2
    echo "           file merged before it. Fix: select the newest run whose control-plane or instance" >&2
    echo "           JOB concluded success (gh api repos/<repo>/actions/runs/<id>/jobs)." >&2
    rc=1
  fi

  # THE COUNT, PRINTED. A healthy scan examines every candidate it was handed,
  # and the log must SAY so — an identity nobody can read is an identity nobody
  # can act on, and the shortfall arm below is only trustworthy if the same line
  # is present and equal when nothing is wrong.
  if grep -q '^anchor: candidates examined 2 of 2 listed$' "$ANCHOR_TMP/step.out"; then
    echo "  anchor   healthy scan                     ->  candidates examined 2 of 2 listed (identity holds)"
  else
    echo "  ESCAPE   healthy scan did not print an EQUAL examined/listed count" >&2
    echo "           wanted the line 'anchor: candidates examined 2 of 2 listed' in the step log." >&2
    echo "           got: $(grep -c '^anchor: candidates examined' "$ANCHOR_TMP/step.out" || true) count line(s):" >&2
    grep '^anchor: candidates examined' "$ANCHOR_TMP/step.out" >&2 || echo "           (none)" >&2
    echo "           Without the count the next arm's shortfall test has no baseline: a loop that" >&2
    echo "           ALWAYS reads short would look identical to one that never does." >&2
    rc=1
  fi

  # THE POSITIVE CONTROL. Without it, a selector that simply always reached one
  # run further back would satisfy the case above and this arm would certify a
  # rule nobody stated.
  got="$(anchor_run "$step" "$hist" "222
111")"
  base="${got%%|*}"; inst="${got##*|}"
  if [ "$base" = "$ANCHOR_SUPERSEDED_SHA" ] && [ "$inst" = "false" ]; then
    echo "  anchor   newest success DID deploy       ->  diff base: $base (run 222), instance=false (the range still answers)"
  else
    echo "  FAIL     newest success DID deploy       ->  diff base: ${base:-<none>}, instance=${inst:-<none>}," >&2
    echo "           wanted diff base: $ANCHOR_SUPERSEDED_SHA (run 222) and instance=false. The selector reaches" >&2
    echo "           past a run that DID deploy, so the case above proves nothing about leg conclusions." >&2
    rc=1
  fi

  # ── THE SHORTFALL ARM (task-5c4cd03a726b0a0c) ──────────────────────────────
  #
  # Both cases above hand the loop input it fully consumes. This one STEALS the
  # input mid-scan and asks what base comes out. A three-run history in which NO
  # run proved a leg is the arm's own control: scanned whole it walks to the
  # OLDEST candidate (111 / C1, the widest the window holds); scanned short it
  # stops at the NEWEST (333 / C4, this run's own sha — an EMPTY range). The two
  # answers are at opposite ends of the same list, so a narrowed base cannot be
  # mistaken for a correct one.
  #
  # The fix must not answer C4 and must not answer C1 either: a scan that ended
  # early has not SEEN the window, so C1 is unproven. It must widen to the safe
  # base the file already falls through to, github.event.before (C0) — WIDER
  # than every candidate — and say in the log that it did.
  local drain="$ANCHOR_TMP/changes-step-drained.sh" hist3 want
  hist3="333 $ANCHOR_HEAD_SHA
222 $ANCHOR_SUPERSEDED_SHA
111 $ANCHOR_DEPLOYED_SHA"

  # (a) The control: the SAME history, the SAME no-leg answer, no plant. If this
  # does not reach C1 then the plant below proves nothing — the scan would have
  # been short for some other reason.
  got="$(anchor_run "$step" "$hist3" "")"
  base="${got%%|*}"; inst="${got##*|}"
  if [ "$base" = "$ANCHOR_DEPLOYED_SHA" ] && [ "$inst" = "true" ]; then
    echo "  anchor   no leg anywhere, scan INTACT     ->  diff base: $base (run 111, the oldest scanned), instance=true"
  else
    echo "  FAIL     no leg anywhere, scan INTACT     ->  diff base: ${base:-<none>}, instance=${inst:-<none>}," >&2
    echo "           wanted diff base: $ANCHOR_DEPLOYED_SHA (the OLDEST of the three candidates) and instance=true." >&2
    echo "           This is the shortfall arm's control: without it a base of $ANCHOR_BASE_SHA below would" >&2
    echo "           prove only that this fixture never reaches the end of its list." >&2
    rc=1
  fi

  # (b) The plant.
  if ! anchor_plant_drain "$step" "$drain"; then
    echo "FAIL[$label]: could not plant the stdin-draining child — the shortfall arm proves nothing." >&2
    rc=1
  else
    got="$(anchor_run "$drain" "$hist3" "")"
    base="${got%%|*}"; inst="${got##*|}"
    want="$ANCHOR_BASE_SHA"
    if [ "$base" = "$want" ] && [ "$inst" = "true" ] &&
       grep -q 'anchor scan short read' "$ANCHOR_TMP/step.out"; then
      echo "  anchor   a body child DRAINS stdin       ->  diff base: $base (github.event.before, the WIDEST safe base), instance=true, shortfall named in the log"
    else
      echo "  SHORTFALL a body child DRAINS stdin      ->  diff base: ${base:-<none>}, instance=${inst:-<none>}" >&2
      echo "           wanted diff base: $want (github.event.before) and instance=true, plus an 'anchor scan" >&2
      echo "           short read' line in the log. The loop was handed 3 candidates and a child in its body" >&2
      echo "           read fd 0, so it saw 1. The list is NEWEST FIRST: \$anchor_widest then holds $ANCHOR_HEAD_SHA" >&2
      echo "           (this run's own sha, an EMPTY range) instead of $ANCHOR_DEPLOYED_SHA. Nothing in the loop" >&2
      echo "           notices, because 'read returned non-zero' is the same exit whether stdin was exhausted" >&2
      echo "           or STOLEN. Fix: count the candidates handed in, count the ones examined, and when they" >&2
      echo "           differ WITHOUT a leg-proven break, discard \$anchor_widest and fall through to the safe" >&2
      echo "           base. A narrowed base strands a commit (deploy.yml:171, task-220b847a8072f82e)." >&2
      rc=1
    fi
  fi

  return "$rc"
}

# ── target direction: the RIGHT job, not merely SOME job ─────────────────────

# THE HOLE THIS ARM CLOSES
#
# Every arm above asks whether a path targets AT LEAST ONE deploy job, and the
# forward loop stops at the FIRST regex that matches. So a path routed to the
# WRONG job reads exactly like a path routed correctly: `ok cmd/** -> ^(cloud|
# deploy|internal|cmd)/`, rc=0. That is how `cmd/` sat outside the INSTANCE
# filter unseen — cmd/** matched the control-plane regex, the gate was satisfied,
# and a cmd/-only merge deployed the control plane while never running
# instance-deploy.sh, the ONLY thing that rebuilds /usr/local/bin/barkpark-agent
# (instance-deploy.sh:1071). Green run, stale agent. No mutation of the instance
# regex could red the gate, because `cmd` was never in it to remove.
#
# So: a DECLARED table of (path prefix -> job that MUST fire), each row derived
# from what a deploy script actually BUILDS from that tree — not from what the
# regexes currently say, which would make this a tautology. For each row we DRIVE
# the real `changes` step body (the same extract_changes_step/classify pair the
# producer arm uses — the regexes are never re-typed here) against a synthetic
# change containing only `<prefix>/x`, and assert the named job flag comes back
# true. A row may name a prefix BOTH jobs must claim; `cmd` is exactly that.
#
# This subsumes nothing above and is subsumed by nothing: forward asks "some
# job?", reverse asks "can this prefix even start the run?", presence asks "is
# the path still listed?" — only this arm asks "the job that BUILDS it?".

# prefix|job|why this job must fire for that tree. The `why` is the evidence the
# row is derived from the deploy scripts and not from the regexes under test.
TARGET_PAIRS=(
  "cmd|instance|instance-deploy.sh:1071 builds /usr/local/bin/barkpark-agent from ./cmd/barkpark-agent"
  "cmd|cp|deploy.yml's control-plane job cross-builds bp-provisioner from ./cmd/barkpark-provisioner"
  "connectors|instance|instance-deploy.sh npm-installs connectors/ and restarts barkpark-connectors"
  "scripts/connectors|instance|instance-deploy.sh installs the cloud-sandbox-runner from that tree (D275)"
  "templates|instance|the content box builds sites FROM templates/ (charter D57a)"
  "api|instance|instance-deploy.sh builds and releases the api/ Phoenix app onto the box"
  "cloud|cp|the control plane is what cloud/ runs on"
  "internal|cp|deploy.yml's control-plane job cross-builds bp-provisioner from ./cmd/barkpark-provisioner, which imports internal/cli/cloud, internal/hetzner, internal/provisioner (cmd/barkpark-provisioner/main.go); an internal-only fix must roll the CP or the stale binary keeps provisioning (bit us 2026-07-24)"
  "internal|instance|instance-deploy.sh's 'go build ./cmd/barkpark-agent' pulls internal/agent (cmd/barkpark-agent imports it) — the agent binary is rebuilt ONLY there"
  "deploy|cp|deploy.yml's control-plane job scp's deploy/cp-deploy.sh onto the CP and runs it — the deploy script IS the artifact"
  "deploy|instance|deploy.yml's instance job scp's deploy/instance-deploy.sh onto guerrilla and runs it, and it installs deploy/systemd/*.service"
)

# ── coverage: the table above held to on.push.paths as a PREDICATE ───────────
#
# THE HOLE THIS ARM CLOSES
#
# TARGET_PAIRS is an enumeration. Measured (task-9ece1f95b89111cf, Mutation C):
# with `internal/**` annotated exempt and `internal|` stripped from BOTH job
# regexes, forward said "exempt", reverse had no `internal` prefix left to find
# unreachable, presence only pins scripts/connectors, and the target arm — the
# one arm that could have driven internal/x through the step — had no row for
# it. Green at rc=0 over a workflow where an internal-only merge fires neither
# deploy job. A path the table omits is a path the target arm never judges, and
# nothing said the table had to be complete.
#
# So: every on.push.paths entry that is not exempt from EVERY job must have at
# least one TARGET_PAIRS row for its prefix naming a job it is not exempt from
# (UNDECLARED otherwise), and every row's prefix must be a listed entry
# (UNLISTED otherwise — a row for a tree that cannot start the workflow guards
# nothing, and it is how a deleted path+regex pair hides behind a still-green
# target line). A row naming a job the entry is exempt from is a CONTRADICTION.
# The bounded-exemption rule in check_file (a tree can never be fully exempt)
# is what stops an author from escaping this predicate by annotation.

# The prefix a TARGET_PAIRS row would carry for one on.push.paths glob:
#   "cloud/**" -> cloud   "scripts/connectors/**" -> scripts/connectors
# A shape this cannot reduce (a mid-path wildcard, a bare file) is printed
# verbatim, so it can only be satisfied by a row spelling it the same way — a
# new shape must be taught here deliberately, never passed over.
prefix_of_glob() {
  case "$1" in
    */\*\*) printf '%s\n' "${1%/\*\*}" ;;
    */\*)    printf '%s\n' "${1%/\*}" ;;
    *)      printf '%s\n' "$1" ;;
  esac
}

# check_target_coverage <yml> <label> — 0 if the predicate holds both ways.
check_target_coverage() {
  local yml="$1" label="$2"
  local path state ex_jobs prefix pair p_prefix p_job rows failures=0 covered
  local listed=""

  while IFS=$'\t' read -r path state; do
    [ -n "$path" ] || continue
    # An EXCLUSION names no deploy target by construction and can never start
    # the workflow, so it neither needs a TARGET_PAIRS row nor counts as a
    # listing that would satisfy one. check_exclusions is its arm.
    [ "$state" = "EXCLUSION" ] && continue
    prefix="$(prefix_of_glob "$path")"
    listed="${listed}|${prefix}|"
    ex_jobs=""
    case "$state" in EXEMPT:*) ex_jobs="${state#EXEMPT:}" ;; esac

    rows=0; covered=0
    for pair in "${TARGET_PAIRS[@]}"; do
      p_prefix="${pair%%|*}"
      p_job="${pair#*|}"; p_job="${p_job%%|*}"
      [ "$p_prefix" = "$prefix" ] || continue
      rows=$((rows + 1))
      case ",$ex_jobs," in
        *",$p_job,"*)
          echo "  CONTRADICTION  $path  ->  exempt from '$p_job' yet TARGET_PAIRS says $prefix must reach $p_job" >&2
          failures=$((failures + 1)) ;;
        *) covered=$((covered + 1)) ;;
      esac
    done

    if [ "$covered" -gt 0 ]; then
      echo "  covered  $path  ->  $covered TARGET_PAIRS row(s) for $prefix"
      continue
    fi

    # No row names a job this entry must reach. That is fine ONLY for an entry
    # exempt from every job — and check_file has already required such an entry
    # to be a single file (a tree can never be fully exempt). So a fully-exempt
    # entry here is a file the forward arm vouched for; anything else is an
    # entry the target arm never judges.
    case "$state" in
      EXEMPT:?*)
        if [ "$rows" -eq 0 ] && [ -n "$ex_jobs" ] && exempt_covers_every_job "$yml" "$ex_jobs"; then
          echo "  covered  $path  ->  exempt from every job; no row expected"
          continue
        fi ;;
    esac
    echo "  UNDECLARED  $path  ->  no TARGET_PAIRS row names a job '$prefix' must reach; the target arm never judges it" >&2
    failures=$((failures + 1))
  done <<EOF
$(extract_paths "$yml")
EOF

  for pair in "${TARGET_PAIRS[@]}"; do
    p_prefix="${pair%%|*}"
    case "$listed" in
      *"|$p_prefix|"*) ;;
      *)
        echo "  UNLISTED  $p_prefix  ->  TARGET_PAIRS names it but no on.push.paths entry is '$p_prefix/**'; a merge there never starts the workflow, so the row guards nothing" >&2
        failures=$((failures + 1)) ;;
    esac
  done

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label] coverage: $failures on.push.paths <-> TARGET_PAIRS mismatch(es)." >&2
    echo "Fix: for UNDECLARED, add a '<prefix>|<job>|<why>' row derived from what a deploy script BUILDS from" >&2
    echo "that tree (never from the regexes under test). For UNLISTED, list the tree under on.push.paths" >&2
    echo "or delete the row. For CONTRADICTION, the exemption and the row disagree — one of them is wrong." >&2
    return 1
  fi
  return 0
}

# exempt_covers_every_job <yml> <cp,instance> — 0 iff the comma list names
# every job the `changes` job dispatches.
exempt_covers_every_job() {
  local yml="$1" ex_jobs="$2" jr_job jr_re
  while IFS=$'\t' read -r jr_job jr_re; do
    [ -n "$jr_job" ] || continue
    case ",$ex_jobs," in
      *",$jr_job,"*) ;;
      *) return 1 ;;
    esac
  done <<EOF
$(extract_job_regexes "$yml")
EOF
  return 0
}

# Set by check_target so the OK line can report a NON-ZERO count — an arm that
# silently checked nothing is a green line that means nothing.
TARGET_CHECKED=0

# One fixture branch per prefix, built lazily off the shared base and reused:
# a single new file at <prefix>/x, which is exactly the `git diff --name-only`
# shape the job filters run against.
target_branch() {
  local prefix="$1" dr="$PRODUCER_TMP/repo" br
  br="target-$(printf '%s' "$prefix" | tr '/' '-')"
  if ! git -C "$dr" rev-parse --verify -q "refs/heads/$br" >/dev/null 2>&1; then
    git -C "$dr" checkout -q -b "$br" "$PRODUCER_BASE"
    mkdir -p "$dr/$prefix"
    printf 'x\n' >"$dr/$prefix/x"
    git -C "$dr" add -A >/dev/null 2>&1
    git -C "$dr" -c user.email=t@t -c user.name=t commit -qm "$br" >/dev/null 2>&1
  fi
  printf '%s\n' "$br"
}

# check_target <yml> <label> — 0 if every declared pair reaches its named job.
check_target() {
  local yml="$1" label="$2" step rc=0 pair prefix job why br got failures=0
  if ! command -v python3 >/dev/null 2>&1; then
    echo "HARNESS-UNAVAILABLE[$label]: python3 not on PATH — the target arm cannot run." >&2
    return 2
  fi
  producer_fixture
  step="$PRODUCER_TMP/changes-step.sh"
  if ! extract_changes_step "$yml" "$step" 2>"$PRODUCER_TMP/extract.err"; then
    echo "FAIL[$label]: could not extract the 'changes' job's step id 'f' for the target arm: $(cat "$PRODUCER_TMP/extract.err")" >&2
    return 1
  fi

  TARGET_CHECKED=0
  for pair in "${TARGET_PAIRS[@]}"; do
    prefix="${pair%%|*}"
    why="${pair##*|}"
    job="${pair#*|}"; job="${job%%|*}"
    br="$(target_branch "$prefix")"
    got="$(classify "$step" "$br" "$job")"
    TARGET_CHECKED=$((TARGET_CHECKED + 1))
    if [ "$got" = "true" ]; then
      echo "  target   $prefix/x  ->  $job=true"
    else
      echo "  WRONG-JOB  $prefix/x  ->  $job=${got:-<none>}, wanted true" >&2
      echo "             $why" >&2
      failures=$((failures + 1))
      rc=1
    fi
  done

  # Non-vacuity, asserted and not assumed: an empty table would otherwise print
  # a clean arm forever.
  if [ "$TARGET_CHECKED" -eq 0 ]; then
    echo "FAIL[$label]: the target arm checked 0 pair(s) — TARGET_PAIRS is empty, so the arm certified nothing" >&2
    return 1
  fi

  # Completeness, asserted and not assumed: a non-empty table that omits a
  # listed tree certified nothing ABOUT THAT TREE.
  local coverage_rc=0
  check_target_coverage "$yml" "$label" || coverage_rc=$?
  if [ "$coverage_rc" -ne 0 ]; then
    rc=1
  fi

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures declared (prefix -> job) pair(s) reached the WRONG job." >&2
    echo "Fix: add the prefix to that job's grep -qE regex in the 'changes' job. A prefix already" >&2
    echo "matched by the OTHER job's regex is invisible to the forward arm — that is this arm's job." >&2
  fi
  return "$rc"
}

# ── exclusions: the subtree a merge must NOT deploy (task-75f45c6baba2e633) ──
#
# THE HOLE THIS ARM CLOSES
#
# `on.push.paths` carried `- "api/**"` with no test exclusion and the `changes`
# classifier matched `^(api|...)/` with none either, so a merge confined to
# api/test/** started the production deploy and swapped the guerrilla instance —
# for a change a prod build cannot compile (api/mix.exs: elixirc_paths(_) is
# ["lib"]). MEASURED 2026-09-07 on origin/main --first-parent --since="7 days
# ago": 86 of the 890 deploy-triggering merges (9.7%, ~12/day) matched ONLY
# because of files under api/test/.
#
# The exclusion therefore has TWO halves that must agree, and fixing one is
# inert: the push-path `!` entry stops the workflow STARTING, and the classifier
# `grep -vE` stops it DISPATCHING when an api/test file rides in on another run's
# diff range (the `changes` diff is anchored to the last successful deploy, not
# to this push). Nothing above can see either half — every arm there judges
# TRIGGERS, and an exclusion is the absence of one.
#
# So this arm is a PREDICATE over whatever `!` entries the file lists, never an
# enumeration, and it is BEHAVIOURAL: it drives the real `changes` step body (the
# same extract_changes_step/classify pair the producer and target arms use — the
# regexes are never re-typed here) against fixture trees and reads the job flags
# the step actually emits. For each exclusion `!P/**` it asserts four things:
#
#   parent   some POSITIVE on.push.paths entry matches a file under P. An
#            exclusion that narrows nothing is dead text, and dead text is what
#            the next author copies.
#   negative a tree state touching only `P/x` — and only `P/a/b/x`, to prove the
#            match is not depth-one — emits FALSE for every job the classifier
#            dispatches.
#   control  a tree state touching only `<parent>/x`, differing from the
#            negative one ONLY in which file it touches, emits TRUE for some
#            job. Without it a classifier that said false to everything would
#            satisfy the negative case and this arm would certify a dead filter.
#   mixed    a tree state touching `<parent>/x` AND `P/x` together still emits
#            TRUE. An exclusion implemented as "drop the whole diff when any
#            excluded file is present" passes negative+control and strands a real
#            code change the moment a test file rides along with it.

EXCLUSIONS_CHECKED=0

# One fixture branch carrying exactly the named files, built lazily off the
# shared base and reused. `git diff --name-only` over it yields exactly that set,
# which is the shape the classifier runs against.
exclusion_branch() {
  local br="$1"; shift
  local dr="$PRODUCER_TMP/repo" f
  if ! git -C "$dr" rev-parse --verify -q "refs/heads/$br" >/dev/null 2>&1; then
    git -C "$dr" checkout -q -b "$br" "$PRODUCER_BASE"
    for f in "$@"; do
      mkdir -p "$dr/$(dirname "$f")"
      printf 'x\n' >"$dr/$f"
    done
    git -C "$dr" add -A >/dev/null 2>&1
    git -C "$dr" -c user.email=t@t -c user.name=t commit -qm "$br" >/dev/null 2>&1
  fi
  printf '%s\n' "$br"
}

# "true" if ANY job the classifier dispatches came back true for this branch,
# "false" if every one came back false. A job flag the step did not emit at all
# is reported as `<none>` by classify and counts as not-true — which is the safe
# reading here only because the control case demands a true, so a step that
# emitted nothing reds rather than passing.
any_job_true() {
  local step="$1" br="$2" yml="$3" jr_job jr_re got
  while IFS=$'\t' read -r jr_job jr_re; do
    [ -n "$jr_job" ] || continue
    got="$(classify "$step" "$br" "$jr_job")"
    if [ "$got" = "true" ]; then printf 'true\n'; return 0; fi
  done <<EOF
$(extract_job_regexes "$yml")
EOF
  printf 'false\n'
  return 0
}

# ── the README arm: the PUBLISHED routing must equal the classifier ──────────
#
# THE HOLE THIS ARM CLOSES
#
# `deploy/README.md` is `canonical-for: cd-pipeline`. It published the trigger
# paths for both deploy jobs in TWO hand-maintained enumerations (an ASCII
# routing diagram and a table column), and NOTHING read either of them. Measured
# on origin/main before this arm existed: the page omitted `deploy/**` from BOTH
# jobs, omitted `cmd/**`, `templates/**` and `scripts/connectors/**` from the
# instance job, and never mentioned the `api/test/**` exclusion at all. Every one
# of those prefixes was added to deploy.yml deliberately, with a task id; not one
# of them moved the README. The page's third sentence asserted that "a docs-only
# commit never rebuilds a server" while `deploy/README.md` itself classifies
# cp=true instance=true — editing the claim deploys two boxes.
#
# The other arms in this file hold deploy.yml's two internal lists to each other.
# This one holds the PUBLISHED copy to the same predicate, so the doc cannot
# drift from the workflow in either direction.
#
# DIRECTION: the workflow is the truth, the README is the asserted value. This
# arm only ever READS the README — it never rewrites it, and it never learns its
# expected set from the page it is judging.
#
# The README rows are DERIVED FROM, not enumerated against, the job list: the
# arm walks whatever job flags the `changes` step dispatches, so a third deploy
# job demands a third published row the day it lands.
README_DEFAULT="deploy/README.md"
README_ROWS=0

# The backticked `x/**` globs published after "deploys on" on one README row.
# Measured in CHARACTERS off the matched row, never with a line-based context
# window: this page's pipeline table is one ~900-character line per target.
readme_globs_of_row() {
  printf '%s\n' "$1" | sed -E 's/^.*deploys on //' \
    | { grep -oE '`[^`]+`' || true; } | tr -d '`' | sort -u
}

# set_minus <a> <b> — the lines of <a> absent from <b>, one per line.
#
# Written with a single awk stream rather than `comm <(…) <(…)`: process
# substitution is bash-only, and scripts/posix-vacuous-green-census.sh reds an
# unguarded procsub in this tree because a script that dies on `(` under `sh`
# exits having compared NOTHING and still reads as a pass. No procsub, no guard
# needed, and the comparison runs wherever this file does.
set_minus() {
  printf '%s\n\x01\n%s\n' "$2" "$1" | awk '
    !seen && $0 == "\001" { seen = 1; next }
    !seen { b[$0] = 1; next }
    length($0) && !($0 in b) { print }'
}

# check_readme_routing <yml> <readme> <label>
check_readme_routing() {
  local yml="$1" readme="$2" label="$3"
  local failures=0 jr_job jr_re row rows n derived published

  if [ ! -r "$readme" ]; then
    echo "FAIL[$label]: cannot read $readme — the published routing cannot be judged, so this arm fails CLOSED rather than reporting a clean page." >&2
    return 1
  fi

  README_ROWS=0
  while IFS=$'\t' read -r jr_job jr_re; do
    [ -n "$jr_job" ] || continue

    # EXACTLY ONE row per job. Zero is a reworded heading that silently disarms
    # the arm; two is an enumeration that can disagree with itself.
    rows="$({ grep -E "^- \`$jr_job\` " "$readme" || true; })"
    n="$(printf '%s' "$rows" | grep -c . || true)"
    if [ "$n" != 1 ]; then
      echo "  UNANCHORED  $jr_job  ->  expected exactly ONE '- \`$jr_job\` … deploys on …' row in $readme, found $n. The arm reads that row to learn the published prefix set; restore it (a list item opening with the backticked job flag) in the SAME commit." >&2
      failures=$((failures + 1))
      continue
    fi
    row="$rows"

    if ! derived="$(prefixes_of "$jr_re")"; then
      echo "  UNDECOMPOSABLE  $jr_job  ->  the filter '$jr_re' is not the '^(a|b|c)/' alternation this arm can decompose; fail CLOSED rather than judge a shape we cannot read." >&2
      failures=$((failures + 1))
      continue
    fi
    derived="$(printf '%s\n' "$derived" | sed 's:$:/**:' | sort -u)"
    published="$(readme_globs_of_row "$row")"

    if [ "$derived" != "$published" ]; then
      echo "  PUBLISHED  $jr_job  ->  $readme publishes a prefix set the '$jr_job' classifier does not use." >&2
      echo "          workflow (truth):  $(printf '%s' "$derived"   | tr '\n' ' ')" >&2
      echo "          README (asserted): $(printf '%s' "$published" | tr '\n' ' ')" >&2
      echo "          only in the workflow: $(set_minus "$derived" "$published" | tr '\n' ' ')" >&2
      echo "          only in the README:   $(set_minus "$published" "$derived" | tr '\n' ' ')" >&2
      failures=$((failures + 1))
      continue
    fi
    echo "  readme   $jr_job  ->  $(printf '%s' "$published" | tr '\n' ' ') (published set equals the classifier's)"
    README_ROWS=$((README_ROWS + 1))
  done <<EOF
$(extract_job_regexes "$yml")
EOF

  # Non-vacuity. A run that judged no row at all must not read as a clean page.
  if [ "$README_ROWS" -eq 0 ] && [ "$failures" -eq 0 ]; then
    echo "FAIL[$label]: the README arm judged ZERO job rows — the job extractor returned nothing, so this arm measured nothing. A silent pass here is the vacuous green the rest of this file exists to refuse." >&2
    return 1
  fi

  # The exclusion, published too: it is the single highest-traffic routing fact
  # on the page and the README never mentioned it.
  local ex_re ex_derived ex_rows ex_n ex_published
  ex_re="$(deploy_yaml_job_lines "$yml" changes | { grep -oE "grep -vE '[^']+'" || true; } | sed -E "s/^grep -vE '//; s/'\$//" | sed -n '1p')"
  if [ -n "$ex_re" ]; then
    ex_derived="$(printf '%s\n' "${ex_re#^}" | sed -E 's:/?$:/**:' | sort -u)"
    ex_rows="$({ grep -E '^- excluded from both: ' "$readme" || true; })"
    ex_n="$(printf '%s' "$ex_rows" | grep -c . || true)"
    if [ "$ex_n" != 1 ]; then
      echo "  UNANCHORED  exclusion  ->  expected exactly ONE '- excluded from both: …' row in $readme, found $ex_n." >&2
      failures=$((failures + 1))
    else
      ex_published="$(printf '%s\n' "$ex_rows" | sed -E 's/^- excluded from both: //' | { grep -oE '`[^`]+`' || true; } | tr -d '`' | sort -u)"
      if [ "$ex_derived" != "$ex_published" ]; then
        echo "  PUBLISHED  exclusion  ->  the classifier drops '$ex_derived' before either job runs; $readme publishes '$ex_published'." >&2
        failures=$((failures + 1))
      else
        echo "  readme   exclusion  ->  $ex_published (published exclusion equals the classifier's)"
      fi
    fi
  fi

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures published routing row(s) in $readme disagree with the 'changes' classifier in $yml." >&2
    echo "Fix: the WORKFLOW is the truth. Update the README rows to the prefix set printed above, in the SAME" >&2
    echo "commit that changed the regex — or, if the README is right and the regex is wrong, fix the regex." >&2
    echo "Never edit this gate's expectation: it derives the set from deploy.yml and has no list of its own." >&2
    return 1
  fi
  return 0
}

# check_exclusions <yml> <label> — 0 if every listed exclusion narrows a real
# positive entry and the classifier agrees with it on real input.
check_exclusions() {
  local yml="$1" label="$2" step rc=0
  local path state prefix parent parent_entry entry entry_state entry_re
  local br verdict
  if ! command -v python3 >/dev/null 2>&1; then
    echo "HARNESS-UNAVAILABLE[$label]: python3 not on PATH — the exclusion arm cannot run." >&2
    return 2
  fi
  producer_fixture
  step="$PRODUCER_TMP/changes-step.sh"
  if ! extract_changes_step "$yml" "$step" 2>"$PRODUCER_TMP/extract.err"; then
    echo "FAIL[$label]: could not extract the changes job step id f for the exclusion arm: $(cat "$PRODUCER_TMP/extract.err")" >&2
    return 1
  fi

  EXCLUSIONS_CHECKED=0
  while IFS=$'\t' read -r path state; do
    [ -n "$path" ] || continue
    [ "$state" = "EXCLUSION" ] || continue
    EXCLUSIONS_CHECKED=$((EXCLUSIONS_CHECKED + 1))
    prefix="$(prefix_of_glob "${path#!}")"

    # parent: the positive entry this exclusion narrows.
    parent_entry=""
    while IFS=$'\t' read -r entry entry_state; do
      [ -n "$entry" ] || continue
      [ "$entry_state" = "EXCLUSION" ] && continue
      entry_re="$(glob_to_regex "$entry")"
      if grep -qE "$entry_re" <<<"$prefix/x"; then parent_entry="$entry"; break; fi
    done <<EOF
$(extract_paths "$yml")
EOF
    if [ -z "$parent_entry" ]; then
      echo "  DEAD-EXCLUSION  $path  ->  no positive on.push.paths entry delivers a file under $prefix/, so this line narrows nothing" >&2
      echo "                  Fix: drop it, or add the positive entry it was written for. GitHub applies the" >&2
      echo "                  LAST matching pattern per file — an exclusion before its positive is also inert." >&2
      rc=1
      continue
    fi
    parent="$(prefix_of_glob "$parent_entry")"
    echo "  narrows  $path  <-  $parent_entry"

    # negative, shallow and deep
    for br in "$(exclusion_branch "excl-$(printf '%s' "$prefix" | tr '/' '-')" "$prefix/x")" \
              "$(exclusion_branch "excl-deep-$(printf '%s' "$prefix" | tr '/' '-')" "$prefix/a/b/x")"; do
      verdict="$(any_job_true "$step" "$br" "$yml")"
      if [ "$verdict" = "false" ]; then
        echo "  exclude  a change confined to $prefix/ (branch $br)  ->  every deploy job false"
      else
        echo "  LEAKS    a change confined to $prefix/ (branch $br)  ->  a deploy job came back TRUE" >&2
        echo "           on.push.paths carries [$path] but the changes classifier does not drop the same" >&2
        echo "           subtree, so the merge still deploys whenever it reaches the classifier diff range." >&2
        echo "           Fix: in the changes job, subtract the subtree from the changed-file list BEFORE the" >&2
        echo "           dispatch filters run, with a grep -vE anchored at ^$prefix/ — and keep it OUT of the" >&2
        echo "           single-quoted -qE shape the dispatch-filter extractors harvest." >&2
        rc=1
      fi
    done

    # control: the parent tree must STILL deploy
    br="$(exclusion_branch "excl-ctl-$(printf '%s' "$parent" | tr '/' '-')" "$parent/x")"
    verdict="$(any_job_true "$step" "$br" "$yml")"
    if [ "$verdict" = "true" ]; then
      echo "  control  a change under $parent/ but NOT $prefix/ (branch $br)  ->  a deploy job is true"
    else
      echo "  OVER-EXCLUDED  $parent/x  ->  every deploy job came back false; the exclusion swallowed its own parent tree" >&2
      echo "                 A classifier that says false to everything satisfies the negative case above and" >&2
      echo "                 deploys NOTHING. That is a worse failure than the one the exclusion fixes." >&2
      rc=1
    fi

    # mixed: the parent tree and the excluded subtree together
    br="$(exclusion_branch "excl-mix-$(printf '%s' "$prefix" | tr '/' '-')" "$parent/x" "$prefix/x")"
    verdict="$(any_job_true "$step" "$br" "$yml")"
    if [ "$verdict" = "true" ]; then
      echo "  mixed    $parent/x + $prefix/x together (branch $br)  ->  a deploy job is true"
    else
      echo "  STRANDS-MIXED  $parent/x + $prefix/x  ->  every deploy job false; a real code change that happens" >&2
      echo "                 to ship alongside an excluded file would never reach production." >&2
      echo "                 The exclusion must drop the excluded FILES from the list, never the whole diff." >&2
      rc=1
    fi
  done <<EOF
$(extract_paths "$yml")
EOF

  if [ "$EXCLUSIONS_CHECKED" -eq 0 ]; then
    # Not a failure: a workflow with no exclusions is a valid state. It is
    # reported so the OK line can never imply this arm judged something it did
    # not. check_required_exclusions is what stops a listed exclusion vanishing.
    echo "  exclusions: none listed (0 judged)"
  fi
  return "$rc"
}

# ── the check ────────────────────────────────────────────────────────────────

check_file() {
  local yml="$1" label="$2"
  local failures=0 checked=0 exempted=0 excluded=0

  # Parse first. Everything below is a text scan and is meaningless — worse,
  # falsely reassuring — on a file GitHub itself cannot load.
  local yaml_rc=0
  assert_parseable_yaml "$yml" "$label" || yaml_rc=$?
  [ "$yaml_rc" -eq 0 ] || return "$yaml_rc"

  local regexes
  regexes="$(extract_regexes "$yml")"
  if [ -z "$regexes" ]; then
    echo "FAIL[$label]: no 'grep -qE' job filters found inside the 'changes' job — the extractor is broken, not the workflow" >&2
    echo "Cause: the 'changes' job is absent or renamed, or its filters no longer use single-quoted" >&2
    echo "\`grep -qE '...'\`. The job boundary is now a real YAML parse (scripts/lib/deploy-yaml-scope.sh)," >&2
    echo "so a heredoc or any string body can no longer truncate the scan — and must NOT be blamed for this." >&2
    echo "Do NOT widen the scan back to the whole file: a regex outside the 'changes' job dispatches nothing" >&2
    echo "and would let a new job green this gate for free." >&2
    return 1
  fi

  # The bounded-exemption arm needs regex -> job. A `changes` filter this
  # pairing cannot read is a dispatch the arm cannot answer for: fail CLOSED.
  local job_regexes all_jobs="" jr_job jr_re
  job_regexes="$(extract_job_regexes "$yml")"
  if [ -z "$job_regexes" ]; then
    echo "FAIL[$label]: no \"grep -qE '…'; then <job>=true\" filters found inside the 'changes' job — the" >&2
    echo "job pairing is broken, so no exemption can be bounded and no path can be judged." >&2
    return 1
  fi
  while IFS=$'\t' read -r jr_job jr_re; do
    [ -n "$jr_job" ] || continue
    all_jobs="$all_jobs|$jr_job|"
  done <<EOF
$job_regexes
EOF

  local path state sample matched re regexes_for_path
  local ex_jobs ex_job ex_bad ex_full remaining
  while IFS=$'\t' read -r path state; do
    [ -n "$path" ] || continue
    sample="$(sample_for "$path")"

    case "$state" in
      EXCLUSION)
        # Not a trigger. The drift arm asks "does this path reach a deploy job?"
        # and the answer for a `!` entry is "it must not" — judging it here would
        # red every exclusion forever. check_exclusions proves it behaviourally.
        excluded=$((excluded + 1))
        echo "  exclude  $path (a GitHub path-filter exclusion; judged by the exclusion arm, not by drift)"
        continue
        ;;
      EXEMPT:*)
        exempted=$((exempted + 1))
        ex_jobs="${state#EXEMPT:}"
        if [ -z "$ex_jobs" ]; then
          echo "  UNBOUNDED  $path  ->  'deploy-filter-exempt:' names no job; write 'deploy-filter-exempt[<job>,…]:' naming the job(s) it deliberately does not target" >&2
          failures=$((failures + 1))
          continue
        fi
        # Every named job must exist, and its regex must NOT match the entry —
        # an exemption over a path the job DOES target is a false statement,
        # and a false statement is what the next author copies.
        ex_bad=0
        while IFS= read -r ex_job; do
          [ -n "$ex_job" ] || continue
          case "$all_jobs" in
            *"|$ex_job|"*) ;;
            *)
              echo "  UNKNOWN-JOB  $path  ->  deploy-filter-exempt names '$ex_job', but no 'changes' filter sets ${ex_job}=true" >&2
              ex_bad=1; continue ;;
          esac
          while IFS=$'\t' read -r jr_job jr_re; do
            [ "$jr_job" = "$ex_job" ] || continue
            if grep -qE "$jr_re" <<<"$sample"; then
              echo "  STALE-EXEMPT  $path  ->  exempt from '$ex_job', but the $ex_job filter $jr_re matches it — the annotation is false" >&2
              ex_bad=1
            fi
          done <<EOF
$job_regexes
EOF
        done <<EOF
$(printf '%s\n' "$ex_jobs" | tr ',' '\n')
EOF
        if [ "$ex_bad" -ne 0 ]; then
          failures=$((failures + 1))
          continue
        fi
        # Which jobs did the annotation NOT name? Those it must still target.
        ex_full=1; remaining=""
        while IFS=$'\t' read -r jr_job jr_re; do
          [ -n "$jr_job" ] || continue
          case ",$ex_jobs," in
            *",$jr_job,"*) ;;
            *) ex_full=0; remaining="${remaining}${jr_re}"$'\n' ;;
          esac
        done <<EOF
$job_regexes
EOF
        if [ "$ex_full" -eq 1 ]; then
          # Fully targetless. Only a single FILE may be that: a tree that starts
          # the workflow is listed because something is built from it, and a
          # tree exempt from every job is exactly the green-over-nothing this
          # gate exists for (Mutation C).
          case "$path" in
            *\**)
              echo "  TARGETLESS-TREE  $path  ->  a tree (glob) cannot be exempt from every deploy job; a merge under it starts the workflow and deploys nothing" >&2
              failures=$((failures + 1))
              continue ;;
          esac
          echo "  exempt   $path (deploy-filter-exempt[$ex_jobs]; single file, no job's filter matches it)"
          continue
        fi
        # Partially exempt: judged like any other path, against the jobs it
        # did NOT exempt itself from.
        echo "  exempt   $path from [$ex_jobs] only; must still target another job:"
        regexes_for_path="$remaining"
        ;;
      *)
        regexes_for_path="$regexes"
        ;;
    esac

    checked=$((checked + 1))
    matched=""
    while IFS= read -r re; do
      [ -n "$re" ] || continue
      if grep -qE "$re" <<<"$sample"; then
        matched="$re"
        break
      fi
    done <<EOF
$regexes_for_path
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
  check_required_exclusions "$yml" "$label" || presence_rc=$?

  # The other direction: a job filter naming a prefix on.push.paths cannot
  # deliver. Run unconditionally so ONE run reports every drift it can see —
  # a gate that stops at the first arm teaches authors to fix one thing per CI
  # round trip.
  local reverse_rc=0
  check_reverse "$yml" "$label" || reverse_rc=$?

  if [ "$failures" -gt 0 ]; then
    echo "FAIL[$label]: $failures path(s) start the deploy workflow but target no deploy job (or carry an exemption that is unbounded, false, or over a tree)." >&2
    echo "Fix: add the prefix to the matching job's grep -qE regex in the 'changes' job," >&2
    echo "or, ONLY for a single file that deploys nothing, add a '# deploy-filter-exempt[<job>,…]: <why>'" >&2
    echo "comment above it naming every job it does not target. A tree can never be fully exempt." >&2
    return 1
  fi

  # The behaviour arm: the lists are only as good as the producer that feeds
  # them. Runs unconditionally alongside the others so ONE run reports every
  # drift it can see.
  local producer_rc=0
  check_producer "$yml" "$label" || producer_rc=$?
  if [ "$producer_rc" -eq 2 ]; then
    return 2
  fi

  # The target arm: the RIGHT job, not merely some job. Runs unconditionally
  # alongside the others so ONE run reports every drift it can see.
  local target_rc=0
  check_target "$yml" "$label" || target_rc=$?
  if [ "$target_rc" -eq 2 ]; then
    return 2
  fi

  # The exclusion arm: the subtree a merge must NOT deploy, proved on real input.
  local exclusion_rc=0
  check_exclusions "$yml" "$label" || exclusion_rc=$?
  if [ "$exclusion_rc" -eq 2 ]; then
    return 2
  fi

  # The anchor arm: the RANGE the classifier is handed. Every arm above judges
  # what the classifier does with a diff; this one judges which previous run the
  # diff is taken FROM — and a run that deployed nothing must never be it.
  local anchor_rc=0
  check_anchor "$yml" "$label" || anchor_rc=$?
  if [ "$anchor_rc" -eq 2 ]; then
    return 2
  fi

  # The README arm: the PUBLISHED copy of the same predicate. Runs
  # unconditionally alongside the others so ONE run reports every drift it can
  # see. $README_FOR_CHECK exists only so --selftest can point the arm at a
  # mutated copy; the real run always judges the tree's own page.
  local readme_rc=0
  check_readme_routing "$yml" "${README_FOR_CHECK:-$REPO_ROOT/$README_DEFAULT}" "$label" || readme_rc=$?

  if [ "$presence_rc" -ne 0 ] || [ "$reverse_rc" -ne 0 ] || [ "$producer_rc" -ne 0 ] || [ "$target_rc" -ne 0 ] || [ "$exclusion_rc" -ne 0 ] || [ "$anchor_rc" -ne 0 ] || [ "$readme_rc" -ne 0 ]; then
    return 1
  fi

  echo "OK[$label]: $checked path(s) each target at least one deploy job ($exempted exempt, each bounded; $excluded exclusion(s) not judged here); reverse: $REVERSE_PREFIXES regex prefix(es), all reachable from on.push.paths; target: $TARGET_CHECKED declared (prefix -> job) pair(s), each reaching the job that builds it, and every listed tree has a row; exclusions: $EXCLUSIONS_CHECKED judged behaviourally (negative shallow+deep, control, mixed); README: $README_ROWS published routing row(s) equal the classifier, exclusion included; anchor: the diff base is the newest run with a leg-proven deploy, proved against a history whose newest success deployed nothing."
  return 0
}

# fixture_readme <yml> <out> — the real page with its routing rows REWRITTEN to
# match <yml>'s classifier, printed as a path.
#
# FIXTURE PLUMBING ONLY, and deliberately unreachable from the real run. Every
# --selftest mutation below edits deploy.yml; a classifier mutation makes the
# published page genuinely wrong, so without this the README arm would red in
# every one of those fixtures and each fixture's isolation claim ("only arm X
# reds") would quietly stop being true. Pointing each fixture at a page
# consistent with its OWN workflow keeps those claims exactly as strong as they
# were, and keeps this arm's own three cases the only place the README is
# judged against a DIFFERENT workflow.
#
# This writes only to a caller-supplied temp path. The real run judges
# $REPO_ROOT/$README_DEFAULT and never calls this.
fixture_readme() {
  local yml="$1" out="$2" jr_job jr_re globs
  cp "$REPO_ROOT/$README_DEFAULT" "$out"
  while IFS=$'\t' read -r jr_job jr_re; do
    [ -n "$jr_job" ] || continue
    globs="$(prefixes_of "$jr_re" 2>/dev/null | sed 's:^:`:; s:$:/**`:' | sort | tr '\n' ' ')" || continue
    [ -n "$globs" ] || continue
    globs="${globs% }"
    awk -v job="$jr_job" -v g="$globs" '
      $0 ~ "^- `" job "` " { sub(/deploys on .*$/, "deploys on " g) }
      { print }' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
  done <<EOF
$(extract_job_regexes "$yml")
EOF
  printf '%s\n' "$out"
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

  echo "selftest 1/23: the real workflow passes"
  if ! check_file "$real" "real"; then
    echo "SELFTEST FAIL: the real deploy.yml does not pass" >&2
    rc=1
  fi

  echo
  echo "selftest 2/23: dropping 'templates' from the instance regex must FAIL (the original bug)"
  sed "s#|connectors|templates|scripts/connectors)/#|connectors|scripts/connectors)/#" "$real" > "$tmp/mutated.yml"
  if cmp -s "$real" "$tmp/mutated.yml"; then
    echo "SELFTEST FAIL: the mutation changed nothing — the instance regex no longer looks as expected" >&2
    rc=1
  elif README_FOR_CHECK="$(fixture_readme "$tmp/mutated.yml" "$tmp/mutated.readme.md")" check_file "$tmp/mutated.yml" "mutated" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a templates-less regex read GREEN — the gate cannot fail" >&2
    rc=1
  else
    echo "  ok: the gate reds when templates/** loses its target"
  fi

  echo
  echo "selftest 3/23: an unexplained targetless path must FAIL"
  awk '{ print } /^      - "connectors\/\*\*"$/ { print "      - \"totally-unrouted/**\"" }' \
    "$real" > "$tmp/orphan.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/orphan.yml"; then
    echo "SELFTEST FAIL: the orphan-path injection changed nothing" >&2
    rc=1
  else
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/orphan.yml" "$tmp/orphan.readme.md")" check_file "$tmp/orphan.yml" "orphan" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an unrouted path read GREEN" >&2
      rc=1
    elif ! grep -q 'DRIFT    totally-unrouted/\*\*' <<<"$out"; then
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
  echo "selftest 4/23: another job's own regex must NOT rescue a drifted dispatch filter"
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
  elif README_FOR_CHECK="$(fixture_readme "$tmp/disarm.yml" "$tmp/disarm.readme.md")" check_file "$tmp/disarm.yml" "disarm" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a non-dispatching job's regex greened the gate — it is disarmable again" >&2
    rc=1
  else
    echo "  ok: only the 'changes' job's own filters answer for a path"
  fi

  echo
  echo "selftest 5/23: the YAML arm must PASS the real workflow and FAIL an unparseable one"
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
  elif README_FOR_CHECK="$(fixture_readme "$tmp/badyaml.yml" "$tmp/badyaml.readme.md")" check_file "$tmp/badyaml.yml" "yaml-fail" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: the arm red but check_file still certified the file — the arm is not wired in" >&2
    rc=1
  else
    echo "  ok: a 2-space heredoc body inside 'run: |' reds the arm AND the whole gate"
  fi

  echo
  echo "selftest 6/23: deleting the required scripts/connectors/** path must FAIL (the presence allowlist)"
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
  elif README_FOR_CHECK="$(fixture_readme "$tmp/nopath.yml" "$tmp/nopath.readme.md")" check_file "$tmp/nopath.yml" "nopath" >/dev/null 2>&1; then
    echo "SELFTEST FAIL: a copy missing scripts/connectors/** read GREEN — the presence allowlist cannot fail" >&2
    rc=1
  else
    echo "  ok: the gate reds when a required path is deleted from on.push.paths"
  fi

  echo
  echo "selftest 7/23: a job-filter prefix absent from on.push.paths must FAIL (the reverse direction)"
  # `web` is dispatched by the control-plane filter, but no on.push.paths entry
  # delivers a web/ file — so a web-only merge never starts the workflow and that
  # arm of the filter can only ever fire on somebody else's co-triggering merge.
  sed "s#(cloud|deploy|internal|cmd)/#(cloud|deploy|internal|cmd|web)/#" "$real" > "$tmp/unreachable.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/unreachable.yml"; then
    echo "SELFTEST FAIL: the reverse mutation changed nothing — the cp filter no longer looks as expected" >&2
    rc=1
  else
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/unreachable.yml" "$tmp/unreachable.readme.md")" check_file "$tmp/unreachable.yml" "unreachable" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an unreachable job-filter prefix read GREEN — the reverse arm cannot fail" >&2
      rc=1
    elif ! grep -q 'UNREACHABLE  web/' <<<"$out"; then
      echo "SELFTEST FAIL: the gate red, but not on the reverse arm and not naming 'web'" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds, BY NAME, on a prefix on.push.paths cannot deliver"
    fi
  fi

  echo
  echo "selftest 8/23: the reverse arm must actually RUN on the real workflow (non-vacuity)"
  # A direction that silently checks nothing is worse than no direction: it puts
  # the word "reverse" in a green line. So the count must be non-zero AND the
  # per-prefix verdicts must be present, on the REAL file.
  sub_rc=0
  out="$(check_file "$real" "reverse-count" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the real deploy.yml did not pass with the reverse arm wired in" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -qE 'reverse: [1-9][0-9]* regex prefix\(es\), all reachable' <<<"$out"; then
    echo "SELFTEST FAIL: no non-zero reverse count in the output — the arm ran vacuously" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -q 'reach    scripts/connectors/' <<<"$out"; then
    echo "SELFTEST FAIL: the reverse arm did not judge the scripts/connectors prefix (charter D275)" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    printf '%s\n' "$out" | grep -E '^  reverse: [0-9]+ regex prefix' | sed 's/^ */  ok: /'
  fi

  echo
  echo "selftest 9/23: deleting BOTH halves must still FAIL — on the presence allowlist ALONE"
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
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/bothgone.yml" "$tmp/bothgone.readme.md")" check_file "$tmp/bothgone.yml" "bothgone" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: both halves deleted read GREEN — the presence allowlist cannot fail" >&2
      rc=1
    elif ! grep -q 'MISSING  scripts/connectors/\*\*' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the presence allowlist" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -qE 'DRIFT|UNREACHABLE' <<<"$out"; then
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
  echo "selftest 10/23: a 'changes' filter the reverse arm cannot decompose must FAIL, not be skipped"
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
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/badshape.yml" "$tmp/badshape.readme.md")" check_file "$tmp/badshape.yml" "badshape" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an undecomposable dispatch filter read GREEN — the arm fails OPEN" >&2
      rc=1
    elif ! grep -q 'cannot decompose' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the undecomposable-filter arm" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: an unreadable dispatch filter reds instead of being passed over"
    fi
  fi

  echo
  echo "selftest 11/23: restoring the PRE-FIX producer must FAIL (the behaviour arm)"
  # THE MUTATION THAT MATTERS. Every case above mutates a LIST; this one mutates
  # the line that feeds them, back to exactly what deploy.yml carried before the
  # wave-10 sweep. Both false-green shapes must reappear, or the behaviour arm is
  # a green line that has never been shown to lose.
  #
  # The anchor is asserted to match EXACTLY ONCE and the copy asserted to DIFFER:
  # a mutation that never applied yields a red meaning nothing and, worse, a
  # green meaning less.
  python3 - "$real" "$tmp/prefix-producer.yml" <<'PYMUT'
import sys
s = open(sys.argv[1]).read()
new = ('          changed="$(git -c core.quotepath=false diff -z --name-only '
       '--no-renames "$base" "${{ github.sha }}" | tr \'\\0\' \'\\n\')"\n')
old = '          changed="$(git diff --name-only "$base" "${{ github.sha }}")"\n'
n = s.count(new)
if n != 1:
    sys.exit("MUTATION ANCHOR matched %d times, wanted exactly 1 — the producer line no "
             "longer looks as this selftest expects. Fix the anchor, do not loosen it." % n)
out = s.replace(new, old)
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PYMUT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the producer mutation could not be applied — case 11 proves nothing" >&2
    rc=1
  elif cmp -s "$real" "$tmp/prefix-producer.yml"; then
    echo "SELFTEST FAIL: the producer mutation changed nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/prefix-producer.yml" "$tmp/prefix-producer.readme.md")" check_file "$tmp/prefix-producer.yml" "prefix-producer" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: the PRE-FIX producer read GREEN — the behaviour arm cannot fail" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'ESCAPE   a cloud/ path containing a double quote' <<<"$out"; then
      echo "SELFTEST FAIL: the quote-bearing path did not escape under the pre-fix producer" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'ESCAPE   a cloud/ file renamed OUT of cloud/' <<<"$out"; then
      echo "SELFTEST FAIL: the rename-out case did not escape under the pre-fix producer" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -qE 'DRIFT|UNREACHABLE|MISSING' <<<"$out"; then
      echo "SELFTEST FAIL: a LIST arm also red — this fixture is meant to prove the list arms" >&2
      echo "               see NOTHING when only the producer regresses, which is why the" >&2
      echo "               behaviour arm is load-bearing and not redundant" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: both false-green shapes escape; the list arms read clean, only behaviour reds"
    fi
  fi

  echo
  echo "selftest 12/23: stripping 'cmd' from the instance regex must FAIL — on the TARGET arm ALONE"
  # THE MUTATION THIS ARM EXISTS FOR, and the one no other arm can feel. cmd/**
  # stays listed in on.push.paths and stays matched by the CONTROL-PLANE regex,
  # so the forward arm still prints `ok`, the reverse arm still finds every
  # prefix reachable, the presence allowlist still finds its path, and the
  # producer still classifies correctly. Only the declared pair
  # cmd -> instance can notice that the tree whose ./cmd/barkpark-agent build
  # lives in instance-deploy.sh:1071 no longer reaches the instance job.
  #
  # Anchor asserted to match EXACTLY ONCE and the copy asserted to DIFFER: a
  # mutation that never applied yields a red meaning nothing and a green meaning
  # less.
  python3 - "$real" "$tmp/nocmd.yml" <<'PYMUT'
import sys
s = open(sys.argv[1]).read()
new = "'^(api|internal|cmd|deploy|connectors|templates|scripts/connectors)/'"
old = "'^(api|internal|deploy|connectors|templates|scripts/connectors)/'"
n = s.count(new)
if n != 1:
    sys.exit("MUTATION ANCHOR matched %d times, wanted exactly 1 — the instance regex no "
             "longer looks as this selftest expects. Fix the anchor, do not loosen it." % n)
out = s.replace(new, old)
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PYMUT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the cmd mutation could not be applied — case 12 proves nothing" >&2
    rc=1
  elif cmp -s "$real" "$tmp/nocmd.yml"; then
    echo "SELFTEST FAIL: the cmd mutation changed nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/nocmd.yml" "$tmp/nocmd.readme.md")" check_file "$tmp/nocmd.yml" "nocmd" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: a cmd-less instance regex read GREEN — the target arm cannot fail" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'WRONG-JOB  cmd/x  ->  instance=false' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the target arm naming the cmd -> instance pair" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -qE 'DRIFT|UNREACHABLE|MISSING|ESCAPE' <<<"$out"; then
      echo "SELFTEST FAIL: another arm also red — this fixture is meant to prove every other arm" >&2
      echo "               reads a WRONG-JOB path as a routed path, which is why the target arm" >&2
      echo "               is load-bearing and not redundant" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q '  ok       cmd/\*\*  ->  ' <<<"$out"; then
      echo "SELFTEST FAIL: the forward arm did not print its cheerful 'ok' for cmd/** — the" >&2
      echo "               false-green this arm exists for is not present in the fixture" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: forward still prints 'ok cmd/**'; only the target arm reds, naming cmd -> instance"
    fi
  fi

  echo
  echo "selftest 13/23: Mutation C — a TREE exempted from every job, its prefix stripped from BOTH regexes, must FAIL"
  # THE MEASURED FALSE GREEN (task-9ece1f95b89111cf). Before the bounded
  # exemption: `# deploy-filter-exempt:` above `- "internal/**"` plus
  # `internal|` removed from the cp AND instance filters read
  # `OK … 7 path(s) … (2 exempt); reverse: 7 regex prefix(es), all reachable`
  # at rc=0 — the annotation silenced forward, reverse had no prefix left, and
  # TARGET_PAIRS had no internal row. This case uses the STRONGEST spelling an
  # author could reach for (bounded, naming both jobs) so the tree rule is the
  # detector, not the UNBOUNDED spelling case 14 pins. The reverse arm must
  # read clean (there is no internal prefix left for it to find), the presence
  # arm must read clean, and the red must name internal/** as TARGETLESS-TREE.
  python3 - "$real" "$tmp/mutation-c.yml" <<'PYMUT'
import sys
s = open(sys.argv[1]).read()
path = '      - "internal/**"\n'
cp_new = "'^(cloud|deploy|internal|cmd)/'"
cp_old = "'^(cloud|deploy|cmd)/'"
in_new = "'^(api|internal|cmd|deploy|connectors|templates|scripts/connectors)/'"
in_old = "'^(api|cmd|deploy|connectors|templates|scripts/connectors)/'"
for anchor in (path, cp_new, in_new):
    n = s.count(anchor)
    if n != 1:
        sys.exit("MUTATION ANCHOR %r matched %d times, wanted exactly 1 — deploy.yml no longer "
                 "looks as this selftest expects. Fix the anchor, do not loosen it." % (anchor, n))
out = (s.replace(path, '      # deploy-filter-exempt[cp,instance]: mutation C\n' + path)
        .replace(cp_new, cp_old).replace(in_new, in_old))
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PYMUT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the Mutation C copy could not be built — case 13 proves nothing" >&2
    rc=1
  elif cmp -s "$real" "$tmp/mutation-c.yml"; then
    echo "SELFTEST FAIL: Mutation C changed nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/mutation-c.yml" "$tmp/mutation-c.readme.md")" check_file "$tmp/mutation-c.yml" "mutation-c" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: Mutation C read GREEN — a tree exempt from every job passed the gate again" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'TARGETLESS-TREE  internal/\*\*' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the bounded-exemption arm naming internal/** as a targetless tree" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -qE 'DRIFT|UNREACHABLE|MISSING|UNBOUNDED' <<<"$out"; then
      echo "SELFTEST FAIL: another list arm also red — this fixture is meant to prove that forward," >&2
      echo "               reverse and presence all read CLEAN once the tree is annotated and its" >&2
      echo "               prefix is gone from both regexes, which is why the bound is load-bearing" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'reverse: 7 regex prefix(es), all reachable' <<<"$out"; then
      echo "SELFTEST FAIL: the reverse arm did not read the measured shape (7 prefixes, all reachable) —" >&2
      echo "               the fixture did not reach the state Mutation C describes" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: forward, reverse and presence read clean; only the tree rule reds, naming internal/**"
    fi
  fi

  echo
  echo "selftest 14/23: the legacy UNBOUNDED 'deploy-filter-exempt:' spelling must FAIL"
  # The spelling the measured green used. An exemption that names no job
  # exempts from every job — over a tree it is Mutation C, over a file it is a
  # claim nobody can check. Either way it is refused by name.
  python3 - "$real" "$tmp/unbounded.yml" <<'PYMUT'
import sys
s = open(sys.argv[1]).read()
path = '      - "internal/**"\n'
n = s.count(path)
if n != 1:
    sys.exit("MUTATION ANCHOR matched %d times, wanted exactly 1" % n)
out = s.replace(path, '      # deploy-filter-exempt: unbounded spelling\n' + path)
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PYMUT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the unbounded-exemption copy could not be built — case 14 proves nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/unbounded.yml" "$tmp/unbounded.readme.md")" check_file "$tmp/unbounded.yml" "unbounded" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an unbounded exemption read GREEN" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'UNBOUNDED  internal/\*\*' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not by naming internal/** as UNBOUNDED" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: an exemption that names no job is refused by name"
    fi
  fi

  echo
  echo "selftest 15/23: a listed, ROUTED tree with no TARGET_PAIRS row must FAIL — on the coverage predicate ALONE"
  # The enumeration hole with no exemption involved: add web/** to
  # on.push.paths AND to the cp regex. Forward prints its cheerful ok, reverse
  # finds web reachable, presence and producer read clean, every declared pair
  # still reaches its job — and nothing has ever driven web/x through the step.
  # Only the coverage predicate can say the table is missing a row.
  python3 - "$real" "$tmp/undeclared.yml" <<'PYMUT'
import sys
s = open(sys.argv[1]).read()
path = '      - "cloud/**"\n'
cp_new = "'^(cloud|deploy|internal|cmd)/'"
for anchor in (path, cp_new):
    n = s.count(anchor)
    if n != 1:
        sys.exit("MUTATION ANCHOR %r matched %d times, wanted exactly 1" % (anchor, n))
out = (s.replace(path, path + '      - "web/**"\n')
        .replace(cp_new, "'^(cloud|deploy|internal|cmd|web)/'"))
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PYMUT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the undeclared-tree copy could not be built — case 15 proves nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/undeclared.yml" "$tmp/undeclared.readme.md")" check_file "$tmp/undeclared.yml" "undeclared" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: a routed tree with no TARGET_PAIRS row read GREEN — the table is an unchecked enumeration again" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'UNDECLARED  web/\*\*' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the coverage predicate naming web/**" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -qE 'DRIFT|UNREACHABLE|MISSING|ESCAPE|WRONG-JOB|TARGETLESS|UNBOUNDED|STALE' <<<"$out"; then
      echo "SELFTEST FAIL: another arm also red — this fixture is meant to prove every other arm" >&2
      echo "               reads a routed-but-undeclared tree as fine, which is why the" >&2
      echo "               coverage predicate is load-bearing and not redundant" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q '  ok       web/\*\*  ->  ' <<<"$out"; then
      echo "SELFTEST FAIL: the forward arm did not print its 'ok' for web/** — the fixture is not routed" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: forward still prints 'ok web/**'; only the coverage predicate reds, naming web"
    fi
  fi

  echo
  echo "selftest 16/23: an exemption whose named job's filter STILL matches the path must FAIL"
  # A bounded exemption is a checkable claim; this is the check. cloud/** is
  # matched by the cp filter, so `deploy-filter-exempt[cp]` above it is false.
  python3 - "$real" "$tmp/stale-exempt.yml" <<'PYMUT'
import sys
s = open(sys.argv[1]).read()
path = '      - "cloud/**"\n'
n = s.count(path)
if n != 1:
    sys.exit("MUTATION ANCHOR matched %d times, wanted exactly 1" % n)
out = s.replace(path, '      # deploy-filter-exempt[cp]: a false claim\n' + path)
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(sys.argv[2], "w").write(out)
PYMUT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the stale-exemption copy could not be built — case 16 proves nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/stale-exempt.yml" "$tmp/stale-exempt.readme.md")" check_file "$tmp/stale-exempt.yml" "stale-exempt" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: a false exemption read GREEN — the bound is not checked" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q "STALE-EXEMPT  cloud/\*\*  ->  exempt from 'cp'" <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not by naming cloud/** as STALE-EXEMPT from cp" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: an exemption the filter contradicts is refused by name"
    fi
  fi

  echo
  echo "selftest 17/23: deleting the '!api/test/**' push-path exclusion must FAIL (the exclusion presence allowlist)"
  # The push arm alone. The classifier keeps its grep -vE, so the BEHAVIOURAL
  # arm still reads clean — only the presence allowlist can see this half go.
  grep -v '^      - "!api/test/\*\*"$' "$real" > "$tmp/noexcl.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/noexcl.yml"; then
    echo "SELFTEST FAIL: the exclusion-strip mutation changed nothing — !api/test/** is not listed as expected" >&2
    rc=1
  else
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/noexcl.yml" "$tmp/noexcl.readme.md")" check_file "$tmp/noexcl.yml" "noexcl" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: a copy missing !api/test/** read GREEN — the exclusion allowlist cannot fail" >&2
      rc=1
    elif ! grep -q 'MISSING  !api/test/\*\*' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not by naming the missing exclusion" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds when the push-path exclusion is deleted (by name)"
    fi
  fi

  echo
  echo "selftest 18/23: neutering the CLASSIFIER half must FAIL on the exclusion arm (LEAKS)"
  # The other half, and the one no arm could see before: on.push.paths still
  # carries the exclusion, so presence, forward, reverse, coverage and target all
  # read clean. Only driving the real step body against an api/test-only tree
  # catches it — which is the whole point of a behavioural arm.
  sed "s#grep -vE '\^api/test/'#grep -vE '^__this_prefix_never_matches__/'#" "$real" > "$tmp/leak.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/leak.yml"; then
    echo "SELFTEST FAIL: the classifier-neuter mutation changed nothing — the grep -vE line is not shaped as expected" >&2
    rc=1
  else
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/leak.yml" "$tmp/leak.readme.md")" check_file "$tmp/leak.yml" "leak" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: a classifier that still dispatches api/test-only merges read GREEN" >&2
      rc=1
    elif ! grep -q 'LEAKS    a change confined to api/test/' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the exclusion arm naming the leak" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -q 'MISSING  !api/test/\*\*' <<<"$out"; then
      echo "SELFTEST FAIL: the presence arm also red — this mutation must isolate the BEHAVIOURAL arm" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds when only the classifier half regresses (behavioural arm alone)"
    fi
  fi

  echo
  echo "selftest 19/23: widening the exclusion to the whole api/ tree must FAIL on the CONTROL (OVER-EXCLUDED)"
  # The opposite failure, and the reason the arm carries a control at all: a
  # classifier that says false to everything satisfies the negative case and
  # deploys nothing. Without this case, selftest 18 could be answered by simply
  # dropping more.
  sed "s#grep -vE '\^api/test/'#grep -vE '^api/'#" "$real" > "$tmp/overexcl.yml"
  sub_rc=0
  if cmp -s "$real" "$tmp/overexcl.yml"; then
    echo "SELFTEST FAIL: the over-exclusion mutation changed nothing" >&2
    rc=1
  else
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/overexcl.yml" "$tmp/overexcl.readme.md")" check_file "$tmp/overexcl.yml" "overexcl" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an exclusion that swallows all of api/ read GREEN" >&2
      rc=1
    elif ! grep -q 'OVER-EXCLUDED  api/x' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the control arm naming the over-exclusion" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds when the exclusion swallows its own parent tree (control arm, by name)"
    fi
  fi

  echo
  echo "selftest 20/23: dropping the WHOLE diff when an excluded file is present must FAIL on the MIXED case"
  # The third distinct way to get an exclusion wrong, and the one both cases
  # above pass: subtract the excluded FILES and a real code change riding
  # alongside a test file still deploys; subtract the whole DIFF and it strands.
  # Written with python3 rather than sed because the replacement carries the awk
  # program's own quoting; python3 is already a hard dependency of this arm.
  python3 - "$real" "$tmp/mixdrop.yml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = """grep -vE '^api/test/' || true)"""
new = ("""awk '/^api\\/test\\//{bad=1}{l[NR]=$0}"""
       """END{if(!bad)for(i=1;i<=NR;i++)print l[i]}')""")
assert s.count(old) == 1, "mixdrop anchor count=%d" % s.count(old)
open(dst, "w").write(s.replace(old, new, 1))
PY
  sub_rc=0
  if cmp -s "$real" "$tmp/mixdrop.yml"; then
    echo "SELFTEST FAIL: the whole-diff-drop mutation changed nothing" >&2
    rc=1
  else
    out="$(README_FOR_CHECK="$(fixture_readme "$tmp/mixdrop.yml" "$tmp/mixdrop.readme.md")" check_file "$tmp/mixdrop.yml" "mixdrop" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: an exclusion that drops the whole diff read GREEN" >&2
      rc=1
    elif ! grep -q 'STRANDS-MIXED  api/x + api/test/x' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the mixed case naming the strand" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -q 'LEAKS    a change confined to api/test/' <<<"$out"; then
      echo "SELFTEST FAIL: the negative case also red — this mutation must isolate the MIXED case" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -q 'OVER-EXCLUDED  api/x' <<<"$out"; then
      echo "SELFTEST FAIL: the control also red — this mutation must isolate the MIXED case" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds when the exclusion drops the whole diff (mixed case alone)"
    fi
  fi

  echo
  echo "selftest 21/23: restoring the RUN-LEVEL success anchor must FAIL (the anchor arm)"
  # THE MUTATION THIS ARM EXISTS FOR, and the one no other arm can feel. Every
  # list, every regex, the producer line and the exclusion all stay byte-identical;
  # only the RANGE the classifier is handed moves. Restoring
  # `--status=success --limit=1` makes the superseded run the anchor again — which
  # is exactly what shipped and what stranded #19327 on 2026-09-18.
  #
  # This mutation cuts the WHOLE anchor region, so the shortfall arm (which
  # lives inside it) reds here too — correctly, since the identity it tests is
  # gone. Cases 22 and 23 below cut the identity and the count line SURGICALLY,
  # which is where the isolation claim for those two lives.
  #
  # The POSITIVE CONTROL inside the arm must stay green under this mutation: a
  # run-level selector is RIGHT whenever the newest success did deploy. A
  # mutation that reddened both cases would prove the arm notices a diff, not
  # that it notices THIS defect.
  python3 - "$real" "$tmp/run-level-anchor.yml" <<'PYANCHOR'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
start_mark = '          base=""\n'
end_mark = '(already-covered stays disarmed)"\n          fi\n'
ns, ne = s.count(start_mark), s.count(end_mark)
if ns != 1 or ne != 1:
    sys.exit("MUTATION ANCHORS matched %d/%d times, wanted 1/1 — the anchor selection no "
             "longer looks as this selftest expects. Fix the anchor, do not loosen it." % (ns, ne))
start = s.index(start_mark)
end = s.index(end_mark) + len(end_mark)
if start >= end:
    sys.exit("MUTATION ANCHORS are out of order — refusing to cut a region backwards")
legacy = ('          base="$(gh run list --workflow=deploy.yml --branch=main --status=success \\\n'
          '                    --limit=1 --json headSha --jq \'.[0].headSha\' 2>/dev/null || true)"\n'
          '          last_deployed=""\n'
          '          if [ -n "$base" ] && git cat-file -e "$base^{commit}" 2>/dev/null; then\n'
          '            last_deployed="$base"\n'
          '          fi\n')
out = s[:start] + legacy + s[end:]
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(dst, "w").write(out)
PYANCHOR
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the run-level-anchor mutation could not be applied — case 21 proves nothing" >&2
    rc=1
  elif cmp -s "$real" "$tmp/run-level-anchor.yml"; then
    echo "SELFTEST FAIL: the run-level-anchor mutation changed nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(check_file "$tmp/run-level-anchor.yml" "run-level-anchor" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: the RUN-LEVEL success anchor read GREEN — the anchor arm cannot fail" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'ESCAPE   newest success deployed NOTHING' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the anchor arm naming the superseded run" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'anchor   newest success DID deploy' <<<"$out"; then
      echo "SELFTEST FAIL: the POSITIVE CONTROL also red — this mutation must isolate the" >&2
      echo "               superseded case; a selector that is wrong in BOTH directions" >&2
      echo "               would prove the arm notices a diff, not that it notices this defect." >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -qE 'DRIFT|UNREACHABLE|MISSING|LEAKS|OVER-EXCLUDED|STRANDS-MIXED|ESCAPE   a cloud/' <<<"$out"; then
      echo "SELFTEST FAIL: another arm also red — this fixture is meant to prove the list," >&2
      echo "               producer and exclusion arms see NOTHING when only the RANGE moves," >&2
      echo "               which is why the anchor arm is load-bearing and not redundant" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds when the anchor reverts to run-level success; every other arm reads clean"
    fi
  fi

  echo
  echo "selftest 22/23: removing the COUNT IDENTITY must FAIL (the shortfall arm ALONE)"
  # SURGICAL, unlike case 21: the candidate capture, the per-iteration counter,
  # the printed count and every regex stay byte-identical. Only the decision the
  # identity drives is cut. A run whose scan ends early then widens to
  # $anchor_widest exactly as it did before this fix — which, the list being
  # NEWEST FIRST, is the NARROWEST base in the window.
  python3 - "$real" "$tmp/no-anchor-identity.yml" <<'PYIDENT'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
block = ('          if [ "$anchor_broke" -eq 0 ] && [ "$anchor_examined" -ne "$anchor_listed" ]; then\n')
if s.count(block) != 1:
    sys.exit("MUTATION ANCHOR matched %d times, wanted 1 — the count identity no longer "
             "looks as this selftest expects. Fix the identity, do not loosen it." % s.count(block))
start = s.index(block)
end_mark = '            anchor_widest=""\n          fi\n'
if s.count(end_mark) != 1:
    sys.exit("MUTATION END ANCHOR matched %d times, wanted 1" % s.count(end_mark))
end = s.index(end_mark) + len(end_mark)
if end <= start:
    sys.exit("MUTATION ANCHORS are out of order — refusing to cut a region backwards")
out = s[:start] + s[end:]
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(dst, "w").write(out)
PYIDENT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the identity mutation could not be applied — case 22 proves nothing" >&2
    rc=1
  elif cmp -s "$real" "$tmp/no-anchor-identity.yml"; then
    echo "SELFTEST FAIL: the identity mutation changed nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(check_file "$tmp/no-anchor-identity.yml" "no-anchor-identity" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: a loop with no count identity read GREEN — the shortfall arm cannot fail" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'SHORTFALL a body child DRAINS stdin' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the shortfall arm naming the drained stdin" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'anchor   healthy scan' <<<"$out"; then
      echo "SELFTEST FAIL: the printed-count assertion also red — this mutation cuts only the" >&2
      echo "               DECISION, not the count line, so an arm that reds on both is judging" >&2
      echo "               the diff rather than the invariant." >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'anchor   no leg anywhere, scan INTACT' <<<"$out"; then
      echo "SELFTEST FAIL: the shortfall arm's own CONTROL also red — an intact scan must still" >&2
      echo "               reach the oldest candidate without the identity; a fixture that reads" >&2
      echo "               short in BOTH directions proves nothing about the plant." >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif grep -qE 'DRIFT|UNREACHABLE|MISSING|LEAKS|OVER-EXCLUDED|STRANDS-MIXED|ESCAPE   newest success' <<<"$out"; then
      echo "SELFTEST FAIL: another arm also red — this fixture is meant to prove that only the" >&2
      echo "               shortfall arm can feel a missing count identity" >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds when the count identity is cut; the count line, the control and every other arm read clean"
    fi
  fi

  echo
  echo "selftest 23/23: removing the PRINTED count must FAIL (the count assertion ALONE)"
  # The identity can be RIGHT and still unreadable. An operator reading a job log
  # cannot act on a decision that leaves no trace, and the shortfall arm's own
  # baseline is the healthy run's equal count. So the printed line is a separate
  # invariant with its own mutation.
  python3 - "$real" "$tmp/no-anchor-count.yml" <<'PYCOUNT'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
line = '          echo "anchor: candidates examined ${anchor_examined} of ${anchor_listed} listed"\n'
if s.count(line) != 1:
    sys.exit("MUTATION ANCHOR matched %d times, wanted 1 — the printed count no longer looks "
             "as this selftest expects." % s.count(line))
out = s.replace(line, "", 1)
if out == s:
    sys.exit("MUTATION produced an IDENTICAL file — it did not apply")
open(dst, "w").write(out)
PYCOUNT
  mut_rc=$?
  if [ "$mut_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the count-print mutation could not be applied — case 23 proves nothing" >&2
    rc=1
  else
    sub_rc=0
    out="$(check_file "$tmp/no-anchor-count.yml" "no-anchor-count" 2>&1)" || sub_rc=$?
    if [ "$sub_rc" -eq 0 ]; then
      echo "SELFTEST FAIL: a run that never prints its examined/listed count read GREEN" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'ESCAPE   healthy scan did not print an EQUAL examined/listed count' <<<"$out"; then
      echo "SELFTEST FAIL: it red, but not on the printed-count assertion" >&2
      printf '%s\n' "$out" >&2
      rc=1
    elif ! grep -q 'anchor   a body child DRAINS stdin' <<<"$out"; then
      echo "SELFTEST FAIL: the shortfall arm also red — deleting the count PRINT must not change" >&2
      echo "               the base a short scan chooses; an arm that reds on both is judging the diff." >&2
      printf '%s\n' "$out" >&2
      rc=1
    else
      echo "  ok: the gate reds when the count is computed but never printed; the shortfall decision still holds"
    fi
  fi

  echo
  echo "selftest: the exclusion arm must be NON-VACUOUS on the real workflow"
  sub_rc=0
  out="$(check_file "$real" "exclusion-count" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the real deploy.yml did not pass with the exclusion arm wired in" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -qE 'exclusions: [1-9][0-9]* judged behaviourally' <<<"$out"; then
    echo "SELFTEST FAIL: no non-zero exclusion count in the output — the arm ran vacuously" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -q '  narrows  !api/test/\*\*  <-  api/\*\*' <<<"$out"; then
    echo "SELFTEST FAIL: the exclusion arm did not bind !api/test/** to the api/** entry it narrows" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    printf '%s\n' "$out" | grep -oE 'exclusions: [0-9]+ judged behaviourally' | sed 's/^/  ok: /'
  fi

  echo
  echo "selftest: the target arm must be NON-VACUOUS on the real workflow"
  sub_rc=0
  out="$(check_file "$real" "target-count" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the real deploy.yml did not pass with the target arm wired in" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -qE 'target: [1-9][0-9]* declared \(prefix -> job\) pair\(s\)' <<<"$out"; then
    echo "SELFTEST FAIL: no non-zero target count in the output — the arm ran vacuously" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -q '  target   cmd/x  ->  instance=true' <<<"$out"; then
    echo "SELFTEST FAIL: the target arm did not judge the cmd -> instance pair" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -q '  covered  internal/\*\*  ->  ' <<<"$out"; then
    echo "SELFTEST FAIL: the coverage predicate did not judge internal/** on the real workflow" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    printf '%s\n' "$out" | grep -oE 'target: [0-9]+ declared \(prefix -> job\) pair\(s\)' | sed 's/^/  ok: /'
  fi

  # ── the README arm, both directions plus the anchor ───────────────────────
  #
  # Three mutations, each ISOLATING this arm: the WORKFLOW gains a prefix the
  # page does not publish, the PAGE loses a prefix the workflow uses, and the
  # page's row is reworded so the anchor matches nothing. A doc guard that can
  # only catch drift from one side is a guard against one author's habits.
  local real_readme="$REPO_ROOT/$README_DEFAULT"

  echo
  echo "selftest: the README arm must be NON-VACUOUS on the real page"
  sub_rc=0
  out="$(check_file "$real" "readme-count" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -ne 0 ]; then
    echo "SELFTEST FAIL: the real deploy.yml did not pass with the README arm wired in" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -qE 'README: [1-9][0-9]* published routing row\(s\)' <<<"$out"; then
    echo "SELFTEST FAIL: no non-zero README row count — the arm ran vacuously" >&2
    printf '%s\n' "$out" >&2
    rc=1
  elif ! grep -q '  readme   exclusion  ->  api/test/\*\*' <<<"$out"; then
    echo "SELFTEST FAIL: the README arm did not judge the published exclusion" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    printf '%s\n' "$out" | grep -oE 'README: [0-9]+ published routing row\(s\)' | sed 's/^/  ok: /'
  fi

  echo
  echo "selftest: a prefix added to the WORKFLOW but not to the README must FAIL"
  # `cloud` is already in on.push.paths and already declared for cp, so adding it
  # to the instance regex leaves forward/reverse/presence/target clean — the
  # README arm is the only thing that can see it. An isolated red is the proof.
  python3 - "$real" "$tmp/readme-wf.yml" <<'PYX'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "^(api|internal|cmd|deploy|connectors|templates|scripts/connectors)/"
new = "^(api|internal|cmd|deploy|connectors|templates|scripts/connectors|cloud)/"
assert s.count(old) == 1, "readme-wf anchor count=%d" % s.count(old)
open(dst, "w").write(s.replace(old, new, 1))
PYX
  sub_rc=0
  # NOT fixture_readme: this case exists to judge the mutated workflow against the
  # REAL page, which is the drift a workflow-side edit actually produces.
  out="$(README_FOR_CHECK="$real_readme" check_file "$tmp/readme-wf.yml" "readme-wf" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -eq 0 ]; then
    echo "SELFTEST FAIL: a workflow prefix the README does not publish read GREEN" >&2
    rc=1
  elif ! grep -q 'only in the workflow: cloud/\*\*' <<<"$out"; then
    echo "SELFTEST FAIL: it red, but without naming the prefix only the workflow has" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    echo "  ok: the gate reds, naming cloud/** as present in the workflow and absent from the README"
  fi

  echo
  echo "selftest: a prefix deleted from the README but not from the workflow must FAIL"
  mkdir -p "$tmp/readme-doc"
  python3 - "$real_readme" "$tmp/readme-doc/README.md" <<'PYX'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "`connectors/**` `deploy/**` `internal/**`"
new = "`connectors/**` `internal/**`"
assert s.count(old) == 1, "readme-doc anchor count=%d" % s.count(old)
open(dst, "w").write(s.replace(old, new, 1))
PYX
  sub_rc=0
  out="$(README_FOR_CHECK="$tmp/readme-doc/README.md" check_file "$real" "readme-doc" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -eq 0 ]; then
    echo "SELFTEST FAIL: a README missing a prefix the classifier uses read GREEN" >&2
    rc=1
  elif ! grep -q 'only in the workflow: deploy/\*\*' <<<"$out"; then
    echo "SELFTEST FAIL: it red, but without naming the prefix the README dropped" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    echo "  ok: the gate reds, naming deploy/** as dropped from the README"
  fi

  echo
  echo "selftest: a REWORDED README row must FAIL on the anchor, not skip silently"
  python3 - "$real_readme" "$tmp/readme-doc/anchor.md" <<'PYX'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
old = "- `instance` \u2192"
new = "- the content instance \u2192"
assert s.count(old) == 1, "anchor mutation count=%d" % s.count(old)
open(dst, "w").write(s.replace(old, new, 1))
PYX
  sub_rc=0
  out="$(README_FOR_CHECK="$tmp/readme-doc/anchor.md" check_file "$real" "readme-anchor" 2>&1)" || sub_rc=$?
  if [ "$sub_rc" -eq 0 ]; then
    echo "SELFTEST FAIL: a README whose routing row no longer matches the anchor read GREEN" >&2
    rc=1
  elif ! grep -q 'expected exactly ONE' <<<"$out"; then
    echo "SELFTEST FAIL: it red, but not on the missing anchor" >&2
    printf '%s\n' "$out" >&2
    rc=1
  else
    echo "  ok: the gate reds on a reworded routing row rather than matching nothing and passing"
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
