#!/usr/bin/env bash
#
# selftest-wiring-census.sh — every standalone self-test under scripts/ is
# either EXECUTED by CI or carries a machine-readable exemption naming why.
# A harness added tomorrow with neither is a RED here, not a silent omission.
#
# THE CORPUS HAS TWO HALVES, and the second exists because the first is
# NAME-KEYED and a name cannot see a property of a file's CONTENTS.
#
#   N  STANDALONE  — `*.test.sh`, `*.test.mjs`, `*_test.sh`, `*-selftest.sh`.
#                    The FILE is the suite, so executing it runs the arms.
#   C  IN-FILE     — any script under scripts/ or
#                    .claude/skills/orchestrate-tasks/helpers/ that HANDLES a
#                    `--selftest` argument of its own. The suite is a function
#                    inside a tool with a plain name, so executing the file is
#                    NOT running the arms: only `<script> … --selftest` is.
#
# WHY THE SECOND HALF WAS ADDED (task-13bfa649df851d5f, 2026-09-23). With the
# corpus keyed on names alone this census printed `OK — 119 run, 4 exempt, 0
# orphaned` on origin/main c9c481959 while scripts/pr-required.sh — 766 lines,
# 33 arms, mirrored into .claude/skills/orchestrate-tasks/helpers/, the
# instrument every lane in the campaign runs before merging — was named by ZERO
# files under .github/workflows/. So was scripts/stranded-worktree-report.sh
# and its 49 arms. That 0 was not a measurement of the codebase; it was a
# measurement of the naming convention. MEASURED on the same commit, over the
# corrected corpus: 155 in-file self-tests, 107 dispatchable, 48 orphaned.
#
# `grep` searches CONTENT, `find` searches NAMES, and a census that probes only
# one index is blind to whatever the other one holds.
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
#   R1 DIRECT   its basename appears in a workflow on an EXECUTION line — one
#               carrying an invoking verb (bash/sh/node/exec/source), a
#               `run: <command>`, a backslash continuation of either, or a bare
#               scripts/… command at the head of a run: block. A basename that
#               appears only in a `paths:`/`filters:` entry or in the
#               dispatcher's `<job-id> <path>` roster is a TRIGGER or an INPUT
#               declaration, never an execution, and does NOT satisfy R1.
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
# THE GRANDFATHER LEDGER. Landing the C half found 48 orphans where the name
# half saw 0. Wiring 48 harnesses in one PR is not reviewable, so the 45 this
# PR does not wire are enumerated BY PATH below, under `backlog_rows`. That
# list is a DEBT REGISTER, not a budget: it is a ratchet with two failure
# directions, and BOTH of them are reds here —
#
#   a C-mode orphan that is NOT a listed row        -> ORPHAN        (rc=1)
#   a listed row that is no longer an orphan, or
#   whose file is gone, or which lost its --selftest -> STALE-BACKLOG (rc=1)
#
# so the only way to make a red go away is to WIRE the harness and DELETE its
# row in the same commit. There is no number to raise. A row added to this list
# is an edit to this file and is visible in review as exactly what it is.
#
# EXIT: 0 every file is RUN, exempt or an honest backlog row · 1 at least one
#       is neither, or a backlog row went stale · 2 cannot measure.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ROOT="${CENSUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

census() {
  local root="$1" files wf_nc wf_exec invocations selfdispatch doors globs rc=0 n_run=0 n_exempt=0 n_red=0
  local name_keyed content_keyed c_only ck_sorted nk_sorted backlog seen_backlog n_backlog=0 n_stale=0
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

  # THE MATRIX COLLAPSE MOVED 234 EXECUTION LINES OUT OF THE YAML
  # (task-1afb6eaf3a04b8ea). shell-harnesses.yml's 53 sibling jobs became ONE
  # matrix job whose per-leg `run:` bodies live in
  # .github/shell-harness-legs.json; the `harness` job executes them verbatim
  # through scripts/shell-harness-run.sh. Those bodies ARE workflow execution,
  # so they belong in this corpus — MEASURED: with the legs file omitted this
  # census reported 14 wired self-tests as ORPHANED on the very commit that
  # wired them, which is the census printing the opposite of the truth.
  # Decoded through python3 so a JSON-escaped newline becomes a real line and
  # the verb filter below sees `bash scripts/x.test.sh` at the head of a line.
  # Absent file or absent python3: the corpus is simply the YAML, exactly as
  # before — this widens the corpus, it can never narrow it.
  if [ -f "$root/.github/shell-harness-legs.json" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$root/.github/shell-harness-legs.json" >>"$wf_nc" <<'LEGS'
import json, sys
try:
    legs = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
for leg in legs if isinstance(legs, list) else []:
    for arm in leg.get("arms") or []:
        for line in str(arm.get("run", "")).split("\n"):
            if line.strip() and not line.strip().startswith("#"):
                print(line)
LEGS
  fi

  # R1's corpus: the EXECUTION LINES of that workflow text.
  #
  # WHY A SECOND FILTER (task-1484df07d2d226c2). Dropping bare scalar sequence
  # items is not enough. Measured on 2026-09-11: a harness named ONLY in the
  # dispatcher's `changes` roster (`<job-id> scripts/foo.test.sh`, two tokens,
  # no leading `-`) and in a `paths:` entry carrying a trailing `# comment`
  # (also no longer a BARE scalar) still resolved R1-direct. So a harness that
  # nothing executes read WIRED, and the ORPHAN verdict — the one that keeps an
  # unwired harness from shipping — could not fire for it.
  #
  # The rule is LINE-level, not block-level. Scoping to `run:` BLOCKS would
  # readmit the roster, which lives inside a `run: |` heredoc. A line qualifies
  # only if it carries an invoking verb as a WORD (the same idiom R3 and R2
  # already use), or is a `run:` with a command on it (`run: |` alone is not),
  # or continues either across a trailing backslash, or is a bare scripts/…
  # command at the head of a run: block.
  #
  # HONEST LIMIT: a harness invoked inside a `run: |` block by a shape none of
  # those four cover reads ORPHAN — loud and fixable, never a silent WIRED.
  wf_exec="$(mktemp "${TMPDIR:-/tmp}/wfexec.XXXXXX")"
  awk '
      { verb = ($0 ~ /(^|[[:space:]]|[(;&|])(exec|bash|sh|node|source)[[:space:]]/) \
               || ($0 ~ /run:[[:space:]]*[^|>[:space:]]/) \
               || ($0 ~ /^[[:space:]]*\.?\/?scripts\/[A-Za-z0-9_.\/*-]+\.(sh|mjs)/) }
      (verb || cont) { print }
      { cont = ($0 ~ /\\[[:space:]]*$/) }
    ' "$wf_nc" > "$wf_exec"

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
  # C-MODE'S OWN PARENT INDEX, and it exists because of a MEASURED false red.
  # scripts/landed-mark.test.sh — itself wired — runs the subject's arms on its
  # line 44: `ARMED_OUT="$(bash "$SUBJECT" --selftest …)"`, where line 31 reads
  # `SUBJECT="$ROOT/scripts/landed-mark.sh"`. The basename and the flag are on
  # DIFFERENT LINES, so the line-level R3 test cannot see the pairing and
  # scripts/landed-mark.sh read ORPHAN on a tree that genuinely runs its arms on
  # every PR. In a REQUIRED venue a false red is worse than a missed one: it
  # teaches the fleet to route around the gate.
  #
  # THE RULE IS THE VARIABLE, not the file. A first draft asked only "does a
  # wired parent name this harness on a bind-shaped line, and does that parent
  # mention --selftest anywhere" — two independent facts about one file, which
  # is not a dispatch. MEASURED, on this tree, that draft resolved
  # scripts/pr-required.sh itself as RUN (parent merge-sweep.sh) and
  # scripts/roster-drift-check.sh as RUN (parent docs-anchors-check.sh, which
  # merely lists it), and let scripts/registration-sample.sh resolve through
  # ITSELF. A census that greens its own headline subject is worse than the one
  # it replaced. So the two halves must be JOINED BY A NAME:
  #
  #   VAR=<anything>/<harness-basename>      the bind
  #   … "$VAR" --selftest …                  an invocation OF THAT VAR
  #
  # and the parent must be named on a workflow EXECUTION line (wf_exec), not
  # merely appear somewhere in the workflow text.
  selfdispatch="$(mktemp "${TMPDIR:-/tmp}/selfd.XXXXXX")"
  local p pbase
  for p in $(find -H "$root/scripts" "$root/.claude/skills/orchestrate-tasks/helpers" -type f \( -name '*.sh' -o -name '*.mjs' \) 2>/dev/null); do
    pbase="$(basename "$p")"
    grep -qF "$pbase" "$wf_nc" || continue
    grep -v '^[[:space:]]*#' "$p" 2>/dev/null \
      | grep -E '(^|[[:space:]]|[(;&|])(exec|bash|sh|node|source)[[:space:]]' \
      | sed "s|^|$pbase |" >> "$invocations"

    # The C half of the index: only for a parent a workflow actually EXECUTES.
    grep -qF "$pbase" "$wf_exec" || continue
    grep -v '^[[:space:]]*#' "$p" 2>/dev/null | awk -v pb="$pbase" -v me="$pbase" '
        # pass 1 is impossible on a stream, so collect then decide at END.
        { line[NR] = $0 }
        match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/) {
          v = $0; sub(/^[[:space:]]*/, "", v); sub(/=.*$/, "", v)
          rest = $0
          if (match(rest, /[A-Za-z0-9_][A-Za-z0-9_.-]*\.(sh|mjs)/)) {
            b = substr(rest, RSTART, RLENGTH)
            if (b != me) bind[v] = b
          }
        }
        END {
          for (v in bind) {
            pat = "[$]\\{?" v "\\}?\"?[[:space:]]+--self-?test"
            for (i = 1; i <= NR; i++) if (line[i] ~ pat) { print pb " " bind[v]; break }
          }
        }
      ' >> "$selfdispatch"
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

  # THE CORPUS IS NAME-KEYED, so a naming shape missing from this list is not
  # an orphan the census failed to resolve — it is a file the census never
  # LOOKED at, and the difference is invisible in the output. Measured
  # 2026-09-15 (task-d64ecb4727209800): scripts/ledger/claim-health-selftest.sh
  # was referenced by no workflow, no Makefile and no other script, and this
  # census printed "OK - 102 run, 4 exempt, 0 orphaned" without naming it once.
  # `*-selftest.sh` is now in the corpus for that reason. A shape added later
  # has the same fault, which is why the number in the OK line is a count of
  # what was examined and not a claim about scripts/.
  name_keyed="$(find "$root/scripts" -type f \( -name '*.test.sh' -o -name '*.test.mjs' -o -name '*_test.sh' -o -name '*-selftest.sh' \) 2>/dev/null | LC_ALL=C sort)"
  [ -n "$name_keyed" ] || { echo "selftest-wiring-census: REFUSING — found ZERO self-tests under $root/scripts. Reporting a clean census over an empty corpus is the failure this gate exists to prevent." >&2; rm -f "$wf_nc" "$wf_exec" "$invocations" "$selfdispatch" "$doors"; return 2; }

  # THE C HALF: a file that HANDLES `--selftest` as its own argument. The shape
  # is matched on NON-COMMENT lines only — every third script in this tree
  # documents the flag in its header, and a usage line is a description of an
  # entry point, never one. Three real shapes, measured over this tree:
  #     --selftest)                 a case arm
  #     [ "${1:-}" = "--selftest" ] a test against $1
  #     == "--selftest"             the [[ ]] form
  # A fourth shape written tomorrow reads as "not in the corpus", which is the
  # same fault the N half has; it is bounded the same way — loudly, by adding
  # the shape — and never by a silent green, because the C half can only WIDEN
  # what is examined.
  local ck_roots ckr cf
  ck_roots="$root/scripts"
  [ -d "$root/.claude/skills/orchestrate-tasks/helpers" ] && ck_roots="$ck_roots $root/.claude/skills/orchestrate-tasks/helpers"
  # Two-stage, for cost: ONE recursive grep narrows ~450 files to the ~160 that
  # carry the token anywhere (comments included), then each candidate is
  # re-read with whole-line comments stripped. The pre-filter can only ever be
  # a SUPERSET of the answer — a file with no `--selftest` byte in it cannot
  # have a `--selftest` entry point — so it costs nothing in coverage.
  content_keyed=""
  for ckr in $ck_roots; do
    # ENUMERATION THROUGH `find -H`, NOT `grep -R`. The selftest's fixture tree
    # reaches the helpers root through a SYMLINK, and neither `grep -r` nor
    # `grep -R` descended it here: MEASURED, `grep -RlE` returned 196 candidates
    # under the fixture's scripts/ and ZERO under its symlinked helpers/, so six
    # ledger rows read "the --selftest entry point is gone" against files that
    # still carry it. `find -H` follows a symlink given on the command line and
    # is what every other index in this file already uses.
    for cf in $(find -H "$ckr" -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.exs' \) -print0 2>/dev/null \
                | xargs -0 grep -lE -- '--self-?test' 2>/dev/null); do
      # NO `cmd | grep -q`: under pipefail the early-exiting grep SIGPIPEs its
      # producer and a TRUE membership reads FALSE (see R3's note). Counted.
      [ "$(grep -v '^[[:space:]]*#' "$cf" 2>/dev/null | grep -cE -- '(^|[[:space:]|(])--self-?test\)|(=|==)[[:space:]]*"?'"'"'?--self-?test|case[[:space:]]+["'"'"']--self-?test["'"'"']')" -gt 0 ] \
        && content_keyed="$content_keyed
$cf"
    done
  done
  content_keyed="$(printf '%s\n' "$content_keyed" | grep -v '^$' | LC_ALL=C sort -u)"

  # The ledger. Paths are repo-relative and are matched against `rel`.
  backlog="$(mktemp "${TMPDIR:-/tmp}/backlog.XXXXXX")"
  seen_backlog="$(mktemp "${TMPDIR:-/tmp}/seenbl.XXXXXX")"
  cat > "$backlog" <<'BACKLOG'
.claude/skills/orchestrate-tasks/helpers/ci-advisory-sweep.sh
.claude/skills/orchestrate-tasks/helpers/held-liveness.sh
.claude/skills/orchestrate-tasks/helpers/lane-open-prs.sh
.claude/skills/orchestrate-tasks/helpers/pr-watch.sh
.claude/skills/orchestrate-tasks/helpers/pulse-loop.sh
.claude/skills/orchestrate-tasks/helpers/session-files.sh
scripts/ancestry-guard.sh
scripts/charter-citation-check.sh
scripts/ci-log-gap-census.sh
scripts/ci-measure.sh
scripts/closed-row-tree-disagreement-sweep.mjs
scripts/cloud-format-check.sh
scripts/cmux-smoke.sh
scripts/console-export-tree.sh
scripts/console-harness.sh
scripts/dependabot-task-trailer.sh
scripts/dispatch-blobless-proof.sh
scripts/docblock-enumeration-check.sh
scripts/elixir-main-red-attribution.sh
scripts/false-open-sweep.mjs
scripts/file-line-citation-check.mjs
scripts/merge-gates-elixir-anchor-check.sh
scripts/pds-blind-spot-check.sh
scripts/pds-charter-ledger-sweep.sh
scripts/pds-climb-preflight.sh
scripts/pds-control-char-census.sh
scripts/pds-door-census.sh
scripts/pds-draft-only-task-census.sh
scripts/pds-draft-twin-sweep.sh
scripts/pds-export-drift-watch.sh
scripts/pds-live-bp-write-receipt.sh
scripts/pds-pre-gate-papers-check.sh
scripts/pds-published-artifact-door.sh
scripts/pds-stranded-draft-cause.sh
scripts/pds-task-anchor-report.sh
scripts/reap-test-databases.sh
scripts/registration-sample.sh
scripts/registry-impact-check.sh
scripts/required4.sh
scripts/rerun-transition-collect.sh
scripts/roster-drift-check.sh
scripts/stranded-branch-report.sh
scripts/test-partition-cleanup.sh
scripts/workflow-portability-check.sh
BACKLOG

  # MODE-TAGGED corpus. A file in BOTH halves is judged as C: the stricter
  # question ("is the --selftest dispatched?") subsumes the looser one.
  # A file in BOTH halves is judged as N, and the direction matters. For a
  # `*.test.sh` the FILE is the suite: CI executing it runs the arms whether or
  # not it also accepts a `--selftest` flag. Judging such a file as C would ask
  # the wrong question of it — MEASURED: scripts/main-red-breaker.test.sh, wired
  # and running today, read ORPHAN under C-first precedence, which is a census
  # reddening a harness CI already runs.
  # TWO TEMP FILES, not `comm -23 - <(…)`. A process substitution here would put
  # this script on posix-vacuous-green-census's RED list: it is a bashism, and
  # under `sh` the construct is a parse error that a `sh -n`-style check answers
  # 0 on while the script compares NOTHING. MEASURED on this branch — the census
  # reddened this file by name until the substitution came out.
  ck_sorted="$(mktemp "${TMPDIR:-/tmp}/cksort.XXXXXX")"
  nk_sorted="$(mktemp "${TMPDIR:-/tmp}/nksort.XXXXXX")"
  printf '%s\n' "$content_keyed" | grep -v '^$' | LC_ALL=C sort > "$ck_sorted"
  printf '%s\n' "$name_keyed"    | grep -v '^$' | LC_ALL=C sort > "$nk_sorted"
  c_only="$(LC_ALL=C comm -23 "$ck_sorted" "$nk_sorted")"
  rm -f "$ck_sorted" "$nk_sorted"
  files="$( { printf '%s\n' "$c_only"     | grep -v '^$' | sed 's|^|C |'
              printf '%s\n' "$name_keyed" | grep -v '^$' | sed 's|^|N |'; } \
            | LC_ALL=C sort -k2,2)"

  # C-MODE ROUTES. For an in-file self-test the question is NOT "does CI run
  # this file" — CI runs scripts/docs-anchors-check.sh on every doc PR and runs
  # none of its arms. The question is "does CI run it WITH --selftest", so each
  # route below is re-asked against lines that carry the flag. Getting this
  # wrong would be the worst outcome available here: 107 of 155 in-file
  # self-tests would resolve RUN off their tool's ordinary invocation, and the
  # census would print a bigger, more confident version of the same zero.
  local mode f base rel route selfline
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mode="${line%% *}"
    f="${line#* }"
    [ -n "$f" ] || continue
    base="$(basename "$f")"
    rel="${f#"$root"/}"
    route=""

    # R1 DIRECT — an EXECUTION line names it (never a paths:/roster mention).
    if [ "$mode" = "C" ]; then
      selfline="$(grep -F "$base" "$wf_exec" | grep -- '--self-\{0,1\}test' | sed -n '1p')"
      [ -n "$selfline" ] && route="R1-direct"
    elif grep -qF "$base" "$wf_exec"; then route="R1-direct"; fi

    # R2 GLOB — every scripts/…*…test.{sh,mjs} glob any workflow names.
    # `set -f` is load-bearing: without it the unquoted expansion of the
    # pattern list is PATHNAME-EXPANDED by this shell, the loop iterates over
    # files that happen to exist instead of over patterns, and R2 silently
    # degenerates into "the file exists" — green for the wrong reason, and
    # blind to a glob whose first member has not been written yet.
    if [ -z "$route" ] && [ "$mode" = "N" ]; then
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
      if [ "$mode" = "C" ]; then
        # NEVER ITSELF, and the exclusion is anchored on FIELD 1 — the parent —
        # never on the row. scripts/registration-sample.sh carries `bash
        # …/registration-sample.sh --selftest` in its own usage path and resolved
        # R3-parent:registration-sample.sh: a harness certifying its own wiring.
        # A first fix used `grep -vF "$base "`, which also drops rows whose
        # parent is a DIFFERENT file that merely names this one mid-line —
        # MEASURED: it manufactured four false orphans (breaker-measure-
        # precondition.sh, go-path-escape-check.sh, lib/task-trailers.sh,
        # main-red-breaker.test.sh) whose genuine parents were being filtered out.
        hit="$(grep -F "$base" "$invocations" | awk -v b="$base" '$1 != b' | grep -- '--self-\{0,1\}test' | sed -n '1s/ .*//p')"
        [ -n "$hit" ] || hit="$(grep -E "^[^ ]+ ${base}\$" "$selfdispatch" | awk -v b="$base" '$1 != b' | sed -n '1s/ .*//p')"
      else
        hit="$(grep -F "$base" "$invocations" | sed -n '1s/ .*//p')"
      fi
      [ -n "$hit" ] && route="R3-parent:$hit"
    fi

    # R4 DOOR — an ExUnit test shells out to it (the required Elixir gate).
    if [ -z "$route" ] && [ -s "$doors" ]; then
      local hit
      if [ "$mode" = "C" ]; then
        hit="$(grep -F "$base" "$doors" | grep -- '--self-\{0,1\}test' | sed -n '1s/ .*//p')"
      else
        hit="$(grep -F "$base" "$doors" | sed -n '1s/ .*//p')"
      fi
      [ -n "$hit" ] && route="R4-door:$hit"
    fi

    if [ -n "$route" ]; then
      n_run=$((n_run + 1))
      [ -n "${CENSUS_VERBOSE:-}" ] && echo "  RUN     $rel  ($route)"
      # A row that is now WIRED is a row that must be DELETED. Recorded here so
      # the stale sweep below can red on it — a ratchet that only refuses new
      # debt lets a cleared row sit forever and quietly overstate the debt.
      [ "$(grep -cxF "$rel" "$backlog")" -gt 0 ] && echo "WIRED $rel" >> "$seen_backlog"
    elif [ "$(head -60 "$f" | grep -c 'MANUAL PROOF .* not wired:')" -gt 0 ]; then
      n_exempt=$((n_exempt + 1))
      echo "  EXEMPT  $rel  — $(head -60 "$f" | grep 'MANUAL PROOF .* not wired:' | sed -n '1s/^.*not wired: *//p' | cut -c1-90)"
      [ "$(grep -cxF "$rel" "$backlog")" -gt 0 ] && echo "WIRED $rel" >> "$seen_backlog"
    elif [ "$mode" = "C" ] && [ "$(grep -cxF "$rel" "$backlog")" -gt 0 ]; then
      n_backlog=$((n_backlog + 1))
      echo "  BACKLOG $rel  — in-file self-test, dispatched by no workflow (grandfathered, task-13bfa649df851d5f)."
      echo "OK $rel" >> "$seen_backlog"
    else
      n_red=$((n_red + 1)); rc=1
      echo "  ORPHAN  $rel  — no workflow runs it and it declares no exemption."
    fi
  done <<EOF
$files
EOF

  # THE OTHER DIRECTION. A listed row whose file is gone, whose --selftest was
  # removed, or which a workflow now dispatches is a row that no longer
  # describes anything, and leaving it in would let the ledger outlive its
  # subject. Each is named individually — the count alone would not tell a
  # reviewer which line to delete.
  local bl
  while IFS= read -r bl; do
    [ -n "$bl" ] || continue
    if [ ! -e "$root/$bl" ]; then
      n_stale=$((n_stale + 1)); rc=1
      echo "  STALE-BACKLOG $bl  — the file is GONE; delete this row from the ledger in scripts/selftest-wiring-census.sh."
    elif [ "$(grep -c "^WIRED $bl\$" "$seen_backlog" 2>/dev/null)" -gt 0 ]; then
      n_stale=$((n_stale + 1)); rc=1
      echo "  STALE-BACKLOG $bl  — a workflow now dispatches its --selftest; delete this row from the ledger."
    elif [ "$(grep -c "^OK $bl\$" "$seen_backlog" 2>/dev/null)" -eq 0 ]; then
      n_stale=$((n_stale + 1)); rc=1
      echo "  STALE-BACKLOG $bl  — it is no longer in the in-file self-test corpus (the --selftest entry point is gone); delete this row."
    fi
  done < "$backlog"

  rm -f "$wf_nc" "$wf_exec" "$invocations" "$selfdispatch" "$doors" "$backlog" "$seen_backlog"
  if [ "$rc" -ne 0 ]; then
    echo "selftest-wiring-census: FAILED — ${n_red} self-test(s) are neither executed by CI nor exempt; ${n_stale} grandfathered row(s) went stale."
    echo "  Fix one of two ways: wire it (a tenant of .github/workflows/shell-harnesses.yml, or a"
    echo "  --selftest step on its parent in the workflow that already runs the subject), or add a"
    echo "  header line in its first 60 lines reading:  MANUAL PROOF — not wired: <reason>"
    echo "  An in-file self-test (a --selftest arm inside a plainly-named tool) is only RUN when a"
    echo "  workflow line carries BOTH its basename AND --selftest. Running the tool is not running"
    echo "  its arms. A STALE-BACKLOG row is cleared by DELETING the row, never by editing a number."
  else
    echo "selftest-wiring-census: OK — ${n_run} run, ${n_exempt} exempt, ${n_backlog} grandfathered backlog, 0 orphaned ($((n_run + n_exempt + n_backlog)) self-tests examined)."
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
  # The legs file is half the execution corpus now; a fixture tree without it
  # would green this control while the real tree reds, which is the exact
  # disagreement between suite and subject this census exists to catch.
  [ -f "$ROOT/.github/shell-harness-legs.json" ] && cp "$ROOT/.github/shell-harness-legs.json" "$tmp/.github/shell-harness-legs.json"
  [ -d "$ROOT/api/test" ] && { mkdir -p "$tmp/api"; ln -s "$ROOT/api/test" "$tmp/api/test"; }
  # The C half's second root. Without it every `.claude/skills/...` row in the
  # grandfather ledger resolves "the file is GONE" and the POSITIVE CONTROL
  # below reds on the fixture's shape rather than on the tree's — the suite
  # disagreeing with its subject for a reason that has nothing to do with either.
  if [ -d "$ROOT/.claude/skills/orchestrate-tasks/helpers" ]; then
    mkdir -p "$tmp/.claude/skills/orchestrate-tasks"
    ln -s "$ROOT/.claude/skills/orchestrate-tasks/helpers" "$tmp/.claude/skills/orchestrate-tasks/helpers"
  fi

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

  echo "== A TRIGGER IS NOT AN EXECUTION: paths: + roster mention only must ORPHAN =="
  # task-1484df07d2d226c2. The fixture names the harness three ways a real
  # workflow names one — an on.*.paths entry, the same entry carrying a trailing
  # comment (so it is no longer a BARE scalar), and a `<job-id> <path>` row in
  # the dispatcher's roster inside a `run: |` heredoc — and EXECUTES it nowhere.
  # Before the R1 exec-line filter this read `RUN … (R1-direct)`.
  #
  # The control step below writes its `run:` line through printf rather than a
  # heredoc ON PURPOSE: this file's own basename is named by a workflow, so any
  # line HERE holding both an invoking verb and the fixture's basename lands in
  # R3's invocation index and resolves the fixture as R3-parent — this script
  # wiring its own fixture through its own source. Measured: it turned this arm
  # green for the wrong reason.
  local tfix=__census-trigger-only.test.sh
  printf '%s\n' '#!/usr/bin/env bash' '# planted: named by triggers, executed by nothing' 'exit 0' \
    > "$tmp/scripts/$tfix"
  cat > "$tmp/.github/workflows/__census-fixture.yml" <<'FIXTURE'
name: Census fixture
on:
  pull_request:
    paths:
      - "scripts/__census-trigger-only.test.sh"
      - "scripts/__census-trigger-only.test.sh" # an input, not a runner
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - name: roster
        run: |
          cat <<'ROSTER'
          census-fixture scripts/__census-trigger-only.test.sh
          ROSTER
FIXTURE
  out="$(CENSUS_ROOT="$tmp" CENSUS_VERBOSE=1 census "$tmp" 2>&1)"; rc=$?
  has 'ORPHAN .*__census-trigger-only.test.sh' \
    && ok "a harness named ONLY in paths:/filters:/roster rows is ORPHAN, not RUN" \
    || bad "a harness that NOTHING executes read as wired — R1 is matching the basename outside an execution line"
  [ "$rc" -eq 1 ] && ok "the trigger-only fixture reds the census (rc=1)" \
                  || bad "the trigger-only fixture did not red the census (rc=$rc)"

  echo "== CONTROL: the SAME fixture with a run: step reads RUN (R1-direct) =="
  {
    printf '  run-it:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - run: %s scripts/%s\n' bash "$tfix"
  } >> "$tmp/.github/workflows/__census-fixture.yml"
  out="$(CENSUS_ROOT="$tmp" CENSUS_VERBOSE=1 census "$tmp" 2>&1)"; rc=$?
  has 'RUN .*__census-trigger-only.test.sh  (R1-direct)' \
    && ok "adding a run: step flips the same file to RUN (R1-direct)" \
    || bad "a genuine run: step did NOT resolve R1 — the exec-line filter is too narrow"
  [ "$rc" -eq 0 ] && ok "the executed fixture is green (rc=0)" \
                  || bad "the executed fixture did not go green (rc=$rc)"
  rm -f "$tmp/scripts/$tfix" "$tmp/.github/workflows/__census-fixture.yml"

  echo "== THE C HALF: an IN-FILE --selftest under a plain name =="
  # The whole point of the content-keyed corpus. Every literal below is built
  # through a variable and printf, never typed beside an invoking verb on one
  # line: this file's own basename IS in the workflow text, so a line here
  # holding a verb, the fixture's name and --selftest would land in R3's
  # invocation index and wire the fixture through this suite's own source. The
  # existing trigger-only arm records that exact self-wiring going green for
  # the wrong reason; the C routes are strictly easier to fool, not harder.
  local cfix=__census-inline-canary.sh
  printf '%s\n' '#!/usr/bin/env bash' '# a plainly-named tool whose suite lives INSIDE it' \
    'case "${1:-}" in' '  --selftest) echo ok; exit 0 ;;' '  *) exit 0 ;;' 'esac' \
    > "$tmp/scripts/$cfix"
  out="$(CENSUS_ROOT="$tmp" CENSUS_VERBOSE=1 census "$tmp" 2>&1)"; rc=$?
  has "ORPHAN .*$cfix" \
    && ok "a --selftest inside a plainly-named script IS in the corpus and reads ORPHAN" \
    || bad "the content-keyed half did not examine $cfix at all — this is the 0-orphaned fault the N half had"
  [ "$rc" -eq 1 ] && ok "the in-file canary reds the census (rc=1)" \
                  || bad "the in-file canary did not red the census (rc=$rc)"

  echo "== RUNNING THE TOOL IS NOT RUNNING ITS ARMS =="
  # THE LOAD-BEARING ARM. CI runs scripts/docs-anchors-check.sh on every doc PR
  # and runs none of its arms. If a bare invocation satisfied a C-mode file,
  # 107 of the 155 in-file self-tests measured on origin/main c9c481959 would
  # have resolved RUN off their tool's ordinary invocation, and this census
  # would print a larger, more confident version of the zero it used to print.
  {
    printf 'name: Census C fixture\non:\n  pull_request:\njobs:\n'
    printf '  bare:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - run: %s scripts/%s --check\n' bash "$cfix"
  } > "$tmp/.github/workflows/__census-c-fixture.yml"
  out="$(CENSUS_ROOT="$tmp" CENSUS_VERBOSE=1 census "$tmp" 2>&1)"; rc=$?
  has "ORPHAN .*$cfix" \
    && ok "a workflow that EXECUTES the tool without --selftest leaves it ORPHAN" \
    || bad "a bare invocation resolved the in-file self-test as RUN — the C routes are not asking for the flag"

  echo "== CONTROL: the same line WITH --selftest flips it to RUN =="
  {
    printf 'name: Census C fixture\non:\n  pull_request:\njobs:\n'
    printf '  armed:\n    runs-on: ubuntu-latest\n    steps:\n'
    printf '      - run: %s scripts/%s %s\n' bash "$cfix" --selftest
  } > "$tmp/.github/workflows/__census-c-fixture.yml"
  out="$(CENSUS_ROOT="$tmp" CENSUS_VERBOSE=1 census "$tmp" 2>&1)"; rc=$?
  has "RUN .*$cfix  (R1-direct)" \
    && ok "adding the flag to the SAME line flips it to RUN (R1-direct)" \
    || bad "a genuine --selftest dispatch did NOT resolve — the C route is too narrow, which is a FALSE RED in a required venue"
  [ "$rc" -eq 0 ] && ok "the armed C fixture is green (rc=0)" \
                  || bad "the armed C fixture did not go green (rc=$rc)"
  rm -f "$tmp/scripts/$cfix" "$tmp/.github/workflows/__census-c-fixture.yml"

  echo "== THE RATCHET'S OTHER DIRECTION: a cleared backlog row must RED =="
  # A ledger that only refuses NEW debt lets a row outlive its subject and
  # quietly overstate what is unwired. This arm takes a REAL row — the first
  # one under scripts/, read out of the ledger rather than typed here, so it
  # cannot drift from the list it checks — and dispatches its --selftest in a
  # fixture workflow. The census must then demand the row's DELETION, which is
  # the only way a row ever leaves: never by editing a number, because there is
  # no number.
  local bl_row bl_base
  bl_row="$(CENSUS_ROOT="$tmp" census "$tmp" 2>&1 | sed -n 's/^  BACKLOG \(scripts\/[^ ]*\) .*/\1/p' | sed -n '1p')"
  if [ -z "$bl_row" ]; then
    bad "no BACKLOG row to exercise — the grandfather ledger is empty, so this arm proved nothing"
  else
    bl_base="$(basename "$bl_row")"
    {
      printf 'name: Census stale fixture\non:\n  pull_request:\njobs:\n'
      printf '  cleared:\n    runs-on: ubuntu-latest\n    steps:\n'
      printf '      - run: %s scripts/%s %s\n' bash "$bl_base" --selftest
    } > "$tmp/.github/workflows/__census-stale-fixture.yml"
    out="$(CENSUS_ROOT="$tmp" census "$tmp" 2>&1)"; rc=$?
    has "STALE-BACKLOG $bl_row" \
      && ok "wiring a listed row makes the census demand its DELETION ($bl_row)" \
      || bad "a listed row that is now wired did NOT read STALE-BACKLOG — the ledger can only grow"
    [ "$rc" -eq 1 ] && ok "a stale ledger row reds the census (rc=1)" \
                    || bad "a stale ledger row did not red the census (rc=$rc)"
    rm -f "$tmp/.github/workflows/__census-stale-fixture.yml"
  fi

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
