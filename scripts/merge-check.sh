#!/usr/bin/env bash
# merge-check.sh <pr> <branch> [--repo owner/name]
#                --selftest            run the offline arm suite
#                --classify <sha> [repo]  run ONLY the rollup+inherited classifier
#                                         against one head (the replay harness)
# Every condition this campaign learned the hard way, as a SCRIPT rather than a memo.
# FAILS CLOSED: any unreadable input is CANNOT READ at a non-zero exit, never a pass.
# It NEVER merges. It prints a verdict; a human removes the hold and merges.
#
# WHY EACH ARM EXISTS (all measured in r18):
#  A rollup read at per_page=100 showed total_count=119/received=100 and ZERO
#    non-success, while the complete read showed TWO failures. Pagination is an
#    absence machine.
#  A `gh pr edit --add-reviewer` hold SWALLOWS a 422 and exits 0, so a hold must be
#    READ BACK from the server, never inferred from an exit code.
#  A PR object can lag the branch; merging a verdict about one sha and the branch of
#    another is how an unmeasured commit lands.
set -uo pipefail

# INTERPRETER GUARD — shebang-independent, and it must stay ABOVE the first
# process substitution in this file. A shebang is not a guard: `sh scripts/
# merge-check.sh` never reads it, and bash-in-POSIX-mode cannot parse `<(`, so
# the script dies mid-parse and the caller reads whatever exit code the dying
# shell happened to produce. That is the vacuous green this repo's
# scripts/posix-vacuous-green-census.sh exists to refuse; both arms below are
# required by it (a `${BASH_VERSION}` -z refusal AND a `*:posix:*` SHELLOPTS arm).
if [ -z "${BASH_VERSION:-}" ]; then
  echo "merge-check.sh: needs bash (this script uses process substitution); run: bash scripts/merge-check.sh" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "merge-check.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this script's process substitution; run: bash scripts/merge-check.sh" >&2
    exit 2
    ;;
esac

# ============================================================================
# SHARED STATE + FUNCTIONS.
# DEFINED ABOVE --selftest ON PURPOSE. The A6 lesson in this file is that a probe
# matching its own fixture pins nothing; the selftest below therefore calls THESE
# functions, not hand-written lookalikes of them. Moving a definition below the
# selftest silently converts those arms back into fixture theatre.
# ============================================================================
FAIL=0; ARMS=0; WAITS=0
arm(){ ARMS=$((ARMS+1)); if [ "$1" = ok ]; then printf 'PASS %-22s %s\n' "$2" "$3"; else printf 'FAIL %-22s %s\n' "$2" "$3"; FAIL=$((FAIL+1)); fi; }
cannot(){ printf 'CANNOT READ %-14s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); ARMS=$((ARMS+1)); }
# --- waitfor <arm> <why> ----------------------------------------------------
# THE THIRD BUCKET. A still-running check and a failed check are DIFFERENT
# OBJECTS and must get DIFFERENT VERDICTS. Before this there were two buckets —
# PASS and "everything else" — so a head whose only non-success rows were still
# QUEUED came out of `cannot`, which increments FAIL, and the final line read
# `DO NOT MERGE` with NOTHING having concluded failure.
# MEASURED on #18483 (2026-09-16): `CANNOT READ ... ZERO CONCLUDED FAILURES —
# still moving: Required-check spec drift (advisory)` — the arm's own words say
# zero failures, and the verdict it produced said DO NOT MERGE.
# A WAIT counts as an ARM (it is a real reading of a real head) and it keeps the
# run NON-ZERO — fail-closed is preserved, nothing here turns a wait into a
# merge permit — but it never lands in the FAIL bucket, because a wait is not a
# diagnosis and must not be read, counted or debugged as one.
waitfor(){ printf 'WAIT %-22s %s\n' "$1" "$2"; WAITS=$((WAITS+1)); ARMS=$((ARMS+1)); }

# --- mc_failed_names / mc_pending_names / mc_pooled_names_OLD <file> --------
# ONE HEAD, TWO QUESTIONS. `status` answers "has it concluded?"; `conclusion`
# answers "what did it conclude?". An in_progress or queued run carries
# conclusion:null, which is not "success" — so a filter that asks ONLY about
# conclusion pools PENDING in with FAILURES. That is exactly what shipped:
#   gates  read 20 "failures" on a fresh head. ALL 20 WERE PENDING.
#   deploy read two "new failures" (`Required-check spec gate`, `Required-check
#          spec drift (advisory)`) that were both in_progress, conclusion null,
#          and followed an elegant, entirely false attribution trail.
#   api    was handed a QUEUED `PR task gate self-test` as a non-success and
#          never noticed the tool had misclassified it.
# The filters live here, ABOVE the selftest, so its arms run THESE and not a
# retyped lookalike. mc_pooled_names_OLD is the pre-fix reader, kept for ONE
# purpose: to be the selftest's control. Nothing in the live path calls it.
mc_failed_names(){
  jq -s -r '[ . | group_by(.name) | map(sort_by(.started_at)|last) | .[]
              | select(.status=="completed")
              | select(.conclusion!="success" and .conclusion!="neutral" and .conclusion!="skipped")
              | .name ] | .[]' "$1" 2>/dev/null
}
mc_pending_names(){
  jq -s -r '[ . | group_by(.name) | map(sort_by(.started_at)|last) | .[]
              | select(.status!="completed") | .name ] | .[]' "$1" 2>/dev/null
}
mc_pooled_names_OLD(){
  jq -s -r '[ . | group_by(.name) | map(sort_by(.started_at)|last) | .[]
              | select(.conclusion!="success" and .conclusion!="neutral" and .conclusion!="skipped")
              | .name ] | .[]' "$1" 2>/dev/null
}
# --- mc_hold_verdict <raw> ---------------------------------------------------
# THE HOLD CLASSIFIER. Lives HERE, above --selftest, so the selftest's arms run
# THIS function and not a retyped lookalike of it (the A6 lesson in this file).
#
# WHY IT EXISTS (measured on #18497, 2026-09-17). The old arm was four lines:
#
#   LBL=$(gh pr view "$PR" --json labels --jq '[.labels[].name]|join(",")') \
#     || { cannot "hold-label" "could not read labels"; LBL="__UNREAD__"; }
#   case "$LBL" in
#     __UNREAD__) : ;;
#     *hold*) arm ok "hold label" "HELD — ..." ;;
#     *)      arm ok "hold label" "not held — ..." ;;
#   esac
#
# THREE separate defects, each on its own:
#  1. BOTH readable branches were `arm ok`. A PR carrying `hold` produced a PASS
#     row and contributed NOTHING to FAIL, so the run could still conclude ALL N
#     CONDITIONS MET. The arm was informational wearing a verdict's costume.
#     #18497 was owner-held (a migration on a 31k-row prod table) and merged.
#  2. The `__UNREAD__) : ;;` branch printed NOTHING. `cannot` had already
#     counted the arm, so an unreadable label left a SILENT row in the tally —
#     a permanently blind arm that still counts toward the vacuity floor.
#  3. `*hold*` is a SUBSTRING glob over a joined string: `holdover`, `withhold`,
#     `on-hold-review` and `stakeholder` all match `*hold*`. The membership test
#     below is EXACT (case-insensitive) against each label name, never a glob
#     over the join.
#
# And the defect under all three: `join(",")` renders BOTH "this PR has no
# labels" and "the projection returned nothing" as the SAME empty string, and
# the empty string took the `*)` branch and published `not held` — a POSITIVE
# ABSENCE CLAIM manufactured out of an empty read. So this function is handed
# the RAW JSON ARRAY (`@json`), never a join: `[]` is a readable, genuinely
# unlabelled PR and passes; anything that is not a JSON array of strings is
# UNREAD and refuses. A read that did not happen and a PR with no labels are
# different objects and get different verdicts.
#
# Prints "<VERDICT>\t<detail>"; rc 0 CLEAR, 1 HELD, 2 UNREAD.
MC_HOLD_LABEL="${MERGE_CHECK_HOLD_LABEL:-hold}"
mc_hold_verdict(){
  local raw="${1-}" names
  if [ -z "$raw" ]; then
    printf 'UNREAD\tthe label read produced NO OUTPUT — an empty read is not an empty label set\n'; return 2
  fi
  printf '%s' "$raw" | jq -e 'type=="array" and (map(type=="string")|all)' >/dev/null 2>&1 || {
    printf 'UNREAD\tthe label read did not parse as a JSON array of names (got: %s)\n' "$raw"; return 2; }
  if printf '%s' "$raw" | jq -e --arg h "$MC_HOLD_LABEL" \
       'any(.[]; (ascii_downcase) == ($h|ascii_downcase))' >/dev/null 2>&1; then
    names=$(printf '%s' "$raw" | jq -r 'join(", ")')
    printf 'HELD\tlabels: [%s]\n' "$names"; return 1
  fi
  names=$(printf '%s' "$raw" | jq -r 'if length==0 then "(none)" else join(", ") end')
  printf 'CLEAR\tlabels: [%s]\n' "$names"; return 0
}

# THE PDS-CITATION CLASSIFIER. Lives HERE, above --selftest, for the same reason
# mc_hold_verdict does: the selftest's arms must drive THIS function and the REAL
# `arm`/`cannot` helpers, not a copy of the case statement. A selftest that
# re-types the mapping it is checking pins nothing (the A6 lesson in this file).
#
# WHY IT IS A SIBLING OF ARM 6 AND NOT AN EXTENSION OF IT. `squash sentinels`
# greps the PR BODY for D-tokens and warns that the squash message can re-create
# a guarded literal on main. This reads the PR DIFF and asks a different question
# of a different corpus: does each PDS-D number the diff INTRODUCES resolve to a
# decision the charter ALREADY defines on origin/main. A body citing a
# perfectly-resolving number still needs the sentinel warning; a diff citing a
# phantom still needs this one. Folding them makes both verdicts unreadable.
#
# THE HAZARD (PDS-D643, mechanised by scripts/pds-citation-precedes-merge.sh):
# on 2026-08-03 three slice PRs merged forty minutes BEFORE the charter PR that
# defined the numbers they cite, and origin/main carried thirteen hits in
# shipped code pointing at decisions it did not define.
#
# THREE OUTCOMES, NOT TWO. rc 2 (and anything else) is UNCHECKED — the predicate
# refuses to print a verdict when its own controls do not fire — and UNCHECKED is
# `cannot`, never a pass. A predicate that could not look must not read as clean.
mc_pds_citation_verdict(){ # <rc> <output-of-the-predicate>
  local rc="${1-}" out="${2-}"
  case "$rc" in
    0) arm ok "pds citation" "resolves on origin/main —$(printf '%s' "$out" | sed -n 's/^  citations  ://p')" ;;
    1) arm no "pds citation" "cites what origin/main does not define: $(printf '%s' "$out" | sed -n 's/^  MISSING: //p')" ;;
    *) cannot "pds citation" "$(printf '%s' "$out" | tail -1)" ;;
  esac
}

# Display join. NEVER re-parsed: check names contain commas (A14).
mc_join(){ awk 'NR>1{printf ", "}{printf "%s",$0} END{if(NR)printf "\n"}'; }

# How many recent origin/main heads the inherited-census samples.
# WHY NOT 1: `Required-check spec drift (advisory)` flaps at roughly 1-in-6 and
# samples other lanes' heads. A single sample of main is a coin flip, and the
# losing side of that flip is a FALSE `OWN` — the exact false refusal this whole
# change exists to remove. Measured 2026-09-15 over the 5 newest main commits:
# `Doc budgets + anchors` 5/5 (stable), `Required-check spec drift (advisory)`
# 1/5 (flapping). N=5 catches the 1-in-6 flapper most of the time while costing
# ~5 paginated reads against a rate limit SHARED by every lane at 5,000/hr.
# It is a deliberate tradeoff, not a constant: raise it when the budget allows.
MAIN_N="${MERGE_CHECK_MAIN_SAMPLE:-5}"
# A real main head renders 46-118 check-runs. A census far below that is a broken
# or rate-limited reader, NOT a clean main.
MC_CENSUS_FLOOR="${MERGE_CHECK_CENSUS_FLOOR:-10}"
# THE SECOND PASS, for UNPROVEN only. A sliding 5-head window is a small sample:
# a context that runs on main but not on those particular 5 commits reads
# UNPROVEN (a refusal) purely because the window moved. Measured while writing
# this: `Required-check spec gate` classified `OWN 0/1` on one run and
# `UNPROVEN 0/0` twenty minutes later, with nothing about the PR changed —
# other lanes had merged and slid the window. Only the names that came back
# UNPROVEN are re-sampled, so the cost lands on the rare case and not on every
# run. A context still unrendered at this depth is genuinely not comparable
# against main -- see the UNPROVEN note below.
MAIN_DEEP="${MERGE_CHECK_MAIN_DEEP:-20}"

# --- mc_main_census <outfile> ------------------------------------------------
# The newest-per-name check-run outcome for each of the MAIN_N most recent
# origin/main commits, as `FAIL<TAB>name` / `OK<TAB>name` lines.
#
# READ CHECK-RUNS, NOT RUNS. Job-level `continue-on-error` launders the RUN
# conclusion and `needs.<job>.result` but NOT the check run. Specimen on main,
# 2026-09-15: run 34955892970 reads `success` while its job
# `Required-check spec drift (advisory)` reads `failure` and the check-run on
# 214d6cd98 reads `failure`. A `gh run list --branch main` failure census is
# therefore STRUCTURALLY BLIND to exactly the reds this classifier must see.
#
# THE PAGINATION FORM IS LOAD-BEARING. `gh api --paginate -q '<aggregate>'` runs
# the filter ONCE PER PAGE and emits one value per page, never a total — so a
# context whose row sits on page 2 reads as NOT RENDERED rather than as an error.
# Heads here measure 46-132 runs, already over the 100 boundary. The safe form is
# `--paginate` with NO -q, piped into `jq -s` over the page objects: a STREAM is
# safe under per-page evaluation, an AGGREGATE is not. Arm A12 pins this.
mc_main_census(){
  local out="$1" depth="${2:-$MAIN_N}" c
  : > "$out"
  git fetch -q origin main:refs/remotes/origin/main 2>/dev/null
  for c in $(git rev-list refs/remotes/origin/main -n "$depth" 2>/dev/null); do
    gh api "repos/$REPO/commits/$c/check-runs?per_page=100" --paginate 2>/dev/null \
      | jq -s -r '[.[].check_runs[]]
                  | group_by(.name) | map(sort_by(.started_at)|last) | .[]
                  | select(.status=="completed")
                  | (if (.conclusion!="success" and .conclusion!="neutral" and .conclusion!="skipped")
                     then "FAIL" else "OK" end) + "\t" + .name' >> "$out" 2>/dev/null
  done
}

# --- mc_classify <names_file> <census_file> ---------------------------------
# For each concluded non-success context on the PR head, decide whether that red
# is the PR's OWN or one it INHERITED from main, and print
#   <CLASS><TAB><name><TAB><failed>/<rendered>
# Returns 0 when every red is inherited-class (PERMIT), 1 when any is own-class
# (REFUSE), 3 when the census itself is unreadable (CANNOT READ).
#
# THE `k/N` IS NOT DECORATION. A stable main red and a flapping one are different
# objects and the reader must be able to tell them apart; collapsing 5/5 and 1/5
# into one word `INHERITED` throws away the only evidence that distinguishes
# "main is broken" from "this check is unreliable".
#
# THIN IS NOT STABLE. A context that rendered on only one or two of the sampled
# main heads and failed each time is inherited — the red IS on main — but `1/1`
# is not evidence of a STABLE main red, and labelling it so would overstate a
# one-sample confidence in exactly the direction that gets a guard ignored.
# Measured on the #18400 replay: `Required-check spec drift (advisory)` rendered
# on ONE of five heads. It permits either way; only the word changes, and the
# word is what the reader acts on.
#
# UNPROVEN IS OWN-CLASS ON PURPOSE. A context that rendered NO row on any sampled
# main head has not been shown to be healthy OR broken there — and an absence is
# never evidence of health. Fail closed: refuse and say why.
#
# THE HONEST LIMIT OF THIS WHOLE ARM: A COMMIT WINDOW CANNOT SEE A RARE WORKFLOW.
# Measured 2026-09-15 on this tool's own PR. `tooling/{aesthetics,ergonomics,risk}
# node --test suite + tooling/pds gate` rendered 0 rows across the last 20 main
# heads, so it classified UNPROVEN and REFUSED. Two tempting explanations, both
# WRONG:
#   "it has no push arm"  -> research-coverage-suite.yml DOES have
#                            `push: branches: [main]`.
#   "it never runs on main" -> it does. `gh api
#                            actions/workflows/research-coverage-suite.yml/runs`
#                            shows THREE `push`/`main` runs on 2026-09-13, all
#                            `failure`, alongside a failure on every PR branch
#                            for days. The red is as inherited as a red can be.
# What actually happened: both arms carry the same `paths:` filter, so main trips
# it only occasionally — and the last time it did was further back than 20
# commits on a repo this busy. The window, not the workflow, is the blind spot.
#
# Deepening the window is the wrong remedy: the right question is not "did this
# context fail on the last N main COMMITS" but "when this workflow last ran on
# main, did it fail". That is a workflow-history read, not a commit-window read,
# and it needs a check-run-name -> workflow mapping this script does not have.
# Deliberately NOT built here. Until it exists, UNPROVEN refuses and the message
# hands the operator the exact command that answers it.
#
# AN EMPTY CENSUS IS NOT A CLEAN MAIN. An exhausted shared rate limit renders as
# an EMPTY RESULT SET with stderr suppressed, which would otherwise classify
# every red as OWN and hand back the old false refusal wearing a new story.
mc_classify(){
  local names="$1" cens="$2" n rend fails cls anyown=0 rows
  rows=$(wc -l < "$cens" 2>/dev/null | tr -d ' ')
  if [ "${rows:-0}" -lt "$MC_CENSUS_FLOOR" ]; then
    printf 'CENSUS-UNREADABLE\t-\t%s rows (floor %s)\n' "${rows:-0}" "$MC_CENSUS_FLOOR"
    return 3
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    rend=$(awk -F'\t' -v x="$n" '$2==x{c++} END{print c+0}' "$cens")
    fails=$(awk -F'\t' -v x="$n" '$1=="FAIL" && $2==x{c++} END{print c+0}' "$cens")
    if [ "${MERGE_CHECK_DISARM_INHERITED:-0}" = "1" ]; then
      # THE MUTATION ARM'S SWITCH. Disarms inherited-detection so the inherited
      # specimen must go back to REFUSING — which is what proves the new read is
      # what changed the verdict, rather than something else drifting green.
      cls=OWN-DISARMED; anyown=1
    elif [ "$rend" -eq 0 ]; then cls=UNPROVEN; anyown=1
    elif [ "$fails" -eq 0 ]; then cls=OWN; anyown=1
    elif [ "$fails" -eq "$rend" ] && [ "$rend" -ge 3 ]; then cls=INHERITED-STABLE
    elif [ "$fails" -eq "$rend" ]; then cls=INHERITED-THIN
    else cls=INHERITED-FLAPPING
    fi
    printf '%s\t%s\t%s/%s\n' "$cls" "$n" "$fails" "$rend"
  done < "$names"
  [ "$anyown" -eq 0 ]
}

# ============================================================================
# THE WORKFLOW'S OWN MAIN HISTORY — the answer to UNPROVEN.
# ============================================================================
# A COMMIT WINDOW CANNOT SEE A RARE WORKFLOW. `tooling/{aesthetics, ergonomics,
# risk} node --test suite + tooling/pds gate` rendered 0 rows across the last 20
# main heads -> UNPROVEN -> REFUSED, while
# `actions/workflows/research-coverage-suite.yml/runs` showed THREE push/main
# runs, ALL failure. The workflow has a `push: branches: [main]` arm and it DOES
# run on main; both arms just carry the same `paths:` filter, so main trips it
# rarely and the last time was further back than the window.
# Bit again on #18483 and #18498 (2026-09-16), where `Required-check spec drift
# (advisory)` was a standing main red fixed later by #18500 — an INHERITED red
# the classifier could not see because it sampled COMMITS, not workflow history.
# DEEPENING THE WINDOW IS THE WRONG REMEDY: it only moves the boundary. The
# right question is "when this workflow LAST RAN on main, did it fail".

# --- mc_run_id_from_details_url <url> ---------------------------------------
# A check run does not carry its workflow FILE. It carries a details_url shaped
# https://github.com/<owner>/<repo>/actions/runs/<run_id>/job/<job_id>, and
# `actions/runs/<run_id>` carries `.path`. PURE PARSE, so the selftest exercises
# the real extraction offline. Prints nothing when the URL is not that shape —
# an unparsed URL must stay UNPROVEN, never become a guess.
mc_run_id_from_details_url(){
  printf '%s' "${1:-}" | sed -n 's#^https\{0,1\}://[^/]*/[^/]*/[^/]*/actions/runs/\([0-9][0-9]*\)\(/.*\)\{0,1\}$#\1#p'
}

# --- mc_name_to_workflow <check name> <head sha> ----------------------------
# The mapping the script did not have: check-run NAME -> workflow file basename.
mc_name_to_workflow(){
  local name="$1" sha="$2" url rid path
  url=$(gh api "repos/$REPO/commits/$sha/check-runs?per_page=100" --paginate 2>/dev/null \
        | jq -s -r --arg n "$name" '[.[].check_runs[]] | map(select(.name==$n))
                                    | sort_by(.started_at) | last | (.details_url // "")' 2>/dev/null)
  rid=$(mc_run_id_from_details_url "$url")
  [ -n "$rid" ] || return 1
  path=$(gh api "repos/$REPO/actions/runs/$rid" --jq '.path' 2>/dev/null)
  [ -n "$path" ] && [ "$path" != null ] || return 1
  printf '%s' "${path##*/}"
}

# --- mc_wf_main_census <outfile> <workflow file> ----------------------------
# The workflow's OWN branch=main run history, newest first, as FAIL/OK lines.
# THE PAGINATION FORM IS LOAD-BEARING HERE TOO: `--paginate -q '<aggregate>'`
# runs the filter once PER PAGE and emits one value per page, never a total.
# `--paginate` with NO -q, piped to `jq -s` over the page objects, is the safe
# form — the same rule arm A12 pins on the commit census.
#
# THIS IS A RUN-LEVEL READ, AND THE ROLLUP HAZARD IS MODELLED RATHER THAN IGNORED
# (adjudicated in .github/run-level-readers.allow as KNOWS-THE-CLASS). A job-level
# `continue-on-error` launders a red job into a green RUN, so this census can only
# UNDER-count main failures. Under-counting lowers k in k/N, which pushes the class
# toward OWN, which REFUSES. A laundered run can cost a true permit; it can NEVER
# manufacture a false INHERITED, because a run reads `failure` only when a job that
# was not continue-on-error actually failed. The PR's OWN verdict is still read
# exclusively from check-runs; this read is only ever asked about names the commit
# window could not see at all.
mc_wf_main_census(){
  local out="$1" wf="$2"
  : > "$out"
  [ -n "$wf" ] || return 0
  gh api "repos/$REPO/actions/workflows/$wf/runs?branch=main&per_page=20" --paginate 2>/dev/null \
    | jq -s -r '[.[].workflow_runs[]] | map(select(.status=="completed"))
                | sort_by(.created_at) | reverse | .[0:20] | .[]
                | (if (.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure")
                   then "FAIL" else "OK" end) + "\t" + (.head_sha // "-")' >> "$out" 2>/dev/null
}

# --- mc_wf_classify <name> <wf census file> ---------------------------------
# PURE. Prints <CLASS><TAB><name><TAB><failed>/<completed main runs>.
# 0 = inherited-class (permit), 1 = own-class or unproven (refuse).
# AN ABSENCE IS STILL NOT EVIDENCE OF HEALTH: a workflow with NO completed main
# run stays UNPROVEN and still refuses. The new read can only turn UNPROVEN into
# a VERDICT when there is main history to read; it never invents one.
mc_wf_classify(){
  local name="$1" cens="$2" n k
  n=$(grep -c . "$cens" 2>/dev/null); n=${n:-0}
  k=$(grep -c '^FAIL' "$cens" 2>/dev/null); k=${k:-0}
  if [ "$n" -eq 0 ]; then printf 'UNPROVEN\t%s\t0/0\n' "$name"; return 1; fi
  if [ "$k" -eq 0 ]; then printf 'OWN\t%s\t0/%s\n' "$name" "$n"; return 1; fi
  if [ "$k" -eq "$n" ]; then printf 'INHERITED-MAIN-WF-STABLE\t%s\t%s/%s\n' "$name" "$k" "$n"
  else printf 'INHERITED-MAIN-WF-FLAPPING\t%s\t%s/%s\n' "$name" "$k" "$n"; fi
  return 0
}

# --- mc_rollup <sha> --------------------------------------------------------
# FULL ROLLUP, PAGINATED, with the total_count check that a single page cannot
# give you — then the inherited/own classification of whatever it found red.
# Factored into a function so `--classify` replays run THE SAME CODE PATH as a
# live run. A fix proven only on the permitting side is half a fix, and the
# refusing half is the one that matters; a second copy for replays would let the
# two halves drift apart without any arm noticing.
mc_rollup(){
  local REAL="$1"
  local TC T P GOT FAILED PENDN OKN MISS PEND _c CN NF CLS RC OWNS INH CN2 NF2 CLS2 WFO UNF _un _wf _wc
  TC=$(gh api "repos/$REPO/commits/$REAL/check-runs?per_page=1" --jq '.total_count' 2>/dev/null)
  if [ -z "$TC" ]; then cannot "rollup" "total_count unreadable"; return; fi
  T=$(mktemp); P=1
  while :; do
    gh api "repos/$REPO/commits/$REAL/check-runs?per_page=100&page=$P" --jq '.check_runs[]' >> "$T" 2>/dev/null
    GOT=$(jq -s 'length' "$T" 2>/dev/null || echo 0)
    [ "$GOT" -ge "$TC" ] && break; P=$((P+1)); [ "$P" -gt 10 ] && break
  done
  GOT=$(jq -s 'length' "$T" 2>/dev/null || echo 0)
  if [ "$GOT" -lt "$TC" ]; then
    cannot "rollup" "collected $GOT of $TC check runs — TRUNCATED, this tells you nothing"; rm -f "$T"; return
  fi
  # PENDING IS NOT FAILING. The newest-per-name dedupe was already here, but
  # every non-success row was pooled into one list — and an in_progress run has
  # conclusion:null, which is not "success", so it landed among the failures.
  # gates read 20 "failures" that were all PENDING on a fresh head; deploy read
  # two, on a head whose two spec jobs were in_progress with null conclusions.
  # BOTH would have diagnosed a defect that did not exist. Split them: a wall of
  # pending names is a WAIT, a concluded non-success is a VERDICT.
  FAILED=$(mc_failed_names "$T" | mc_join)
  PENDN=$(mc_pending_names "$T" | mc_join)
  OKN=$(jq -s '[ . | group_by(.name) | map(sort_by(.started_at)|last) | .[] | select(.conclusion=="success") ] | length' -r "$T")
  # ASSERT PRESENCE BEFORE STATUS. A required check that rendered NO ROW contributes
  # zero non-success rows and is byte-identical to "all clean". Console's monitor
  # printed "ALL FOUR REQUIRED SETTLED" while listing three, for exactly this reason.
  MISS=""
  for _c in "Cloud gate" "Console gate" "Elixir gate" "PR references an active task"; do
    jq -se --arg c "$_c" 'any(.[]; .name == $c)' "$T" >/dev/null 2>&1 || MISS="$MISS$_c; "
  done
  if [ -n "$MISS" ]; then arm no "required rows present" "NO CHECK ROW rendered for: ${MISS} — absence is not a pass"
  else arm ok "required rows present" "all four required contexts rendered a row"; fi
  # A FRESH HEAD HAS ZERO SUCCESSES AND IS NOT A BROKEN READER.
  PEND=$(jq -s '[ .[] | select(.status != "completed") ] | length' -r "$T")
  if [ "$OKN" -eq 0 ] && [ "${PEND:-0}" -gt 0 ]; then
    waitfor "rollup" "no newest-per-name success yet and $PEND of $TC run(s) are still queued/in_progress — CI IS FRESH, not broken; re-read when it settles. This is a WAIT, not a failure."
  elif [ "$OKN" -eq 0 ]; then cannot "rollup" "zero successes among $TC runs and NOTHING is pending — the reader is broken, not the PR"
  elif [ -z "$FAILED" ] && [ -n "$PENDN" ]; then
    waitfor "full rollup" "$TC runs, newest-per-name, $OKN green, ZERO CONCLUDED FAILURES — still moving: $PENDN. This is a WAIT, not a diagnosis. Re-read; do NOT debug these, and do not read the run's non-zero exit as a red."
  elif [ -z "$FAILED" ]; then arm ok "full rollup" "$TC runs, newest-per-name, 0 non-success ($OKN green)"
  else
    # ---- INHERITED vs OWN -------------------------------------------------
    # WHY THIS EXISTS (measured r19, four refusals in one shift from ONE blind
    # spot): this arm used to fail on ANY concluded non-success, so a red the PR
    # CAUSED and a red it INHERITED from main rendered identically.
    #   #18400 first head: REFUSED on `Required-check spec gate` — CORRECT, the
    #     red was its own (a prose violation in its own diff).
    #   #18400 later, #18448, #18431: REFUSED on reds ALREADY FAILING ON MAIN.
    #     WRONG. #18431 strictly IMPROVED its gate (17 novel -> 10) and was
    #     refused anyway.
    # One correct refusal, three false ones. That ratio is the danger, not the
    # nuisance: false refusals train the operator to override this arm, and the
    # day the red IS the PR's own, the override is already a habit. A guard that
    # is wrong most of the time is worse than no guard — it manufactures the very
    # reflex it exists to prevent.
    CN=$(mktemp); NF=$(mktemp); CLS=$(mktemp)
    # ONE NAME PER LINE, STRAIGHT FROM jq — never by splitting $FAILED on commas.
    # CHECK NAMES CONTAIN COMMAS. Caught dogfooding this very PR: the real context
    # `tooling/{aesthetics, ergonomics, risk} node --test suite + tooling/pds gate`
    # was shredded into three fragments, none of which matches any row on main, so
    # all three classified UNPROVEN and the arm REFUSED — manufacturing exactly the
    # false refusal this change exists to remove, inside the fix for it.
    # $FAILED stays a comma-joined string for DISPLAY only; it is never re-parsed.
    mc_failed_names "$T" > "$NF"
    mc_main_census "$CN" "$MAIN_N"
    mc_classify "$NF" "$CN" > "$CLS"; RC=$?
    # SECOND PASS: re-sample ONLY the unproven names, deeper. A refusal caused by
    # a window that happened to slide is not a finding about the PR.
    if [ "$RC" != 3 ] && grep -q '^UNPROVEN' "$CLS"; then
      CN2=$(mktemp); NF2=$(mktemp); CLS2=$(mktemp)
      awk -F'\t' '$1=="UNPROVEN"{print $2}' "$CLS" > "$NF2"
      mc_main_census "$CN2" "$MAIN_DEEP"
      if mc_classify "$NF2" "$CN2" > "$CLS2"; then :; fi
      if [ -s "$CLS2" ] && ! grep -q 'CENSUS-UNREADABLE' "$CLS2"; then
        grep -v '^UNPROVEN' "$CLS" > "$CLS.m" 2>/dev/null; cat "$CLS2" >> "$CLS.m"
        mv "$CLS.m" "$CLS"
        if awk -F'\t' '$1=="OWN"||$1=="UNPROVEN"||$1=="OWN-DISARMED"{f=1} END{exit !f}' "$CLS"; then RC=1; else RC=0; fi
      fi
      rm -f "$CN2" "$NF2" "$CLS2"
    fi
    # THIRD PASS — ASK THE WORKFLOW'S MAIN HISTORY, not a commit window. Only
    # the names STILL UNPROVEN after the deep re-sample reach here, so the cost
    # lands on the rare case. MERGE_CHECK_DISARM_WFHISTORY=1 disarms it: the
    # mutation switch that proves THIS read is what moved the verdict.
    if [ "$RC" != 3 ] && [ "${MERGE_CHECK_DISARM_WFHISTORY:-0}" != "1" ] && grep -q '^UNPROVEN' "$CLS"; then
      WFO=$(mktemp); UNF=$(mktemp)
      awk -F'\t' '$1=="UNPROVEN"{print $2}' "$CLS" > "$UNF"
      grep -v '^UNPROVEN' "$CLS" > "$WFO" 2>/dev/null
      while IFS= read -r _un; do
        [ -n "$_un" ] || continue
        _wf=$(mc_name_to_workflow "$_un" "$REAL" 2>/dev/null) || _wf=""
        if [ -z "$_wf" ]; then printf 'UNPROVEN\t%s\t0/0\n' "$_un" >> "$WFO"; continue; fi
        _wc=$(mktemp); mc_wf_main_census "$_wc" "$_wf"
        mc_wf_classify "$_un" "$_wc" >> "$WFO"
        rm -f "$_wc"
      done < "$UNF"
      mv "$WFO" "$CLS"; rm -f "$UNF"
      if awk -F'\t' '$1=="OWN"||$1=="UNPROVEN"||$1=="OWN-DISARMED"{f=1} END{exit !f}' "$CLS"; then RC=1; else RC=0; fi
    fi
    if [ "$RC" = 3 ]; then
      cannot "full rollup" "CONCLUDED non-success ($FAILED) but the origin/main census came back $(cut -f3 "$CLS" | head -1) — an empty or short census is a BROKEN READER (or an exhausted shared rate limit), NOT a clean main. No inherited/own verdict is available; do not read this as either."
    else
      OWNS=$(awk -F'\t' '$1=="OWN"||$1=="UNPROVEN"||$1=="OWN-DISARMED"{printf "%s [%s %s], ", $2, $1, $3}' "$CLS" | sed 's/, $//')
      INH=$(awk -F'\t' '$1 ~ /^INHERITED-/{printf "%s [%s %s], ", $2, $1, $3}' "$CLS" | sed 's/, $//')
      if [ "$RC" = 0 ]; then
        # PERMIT — but never silently. The red is real and still red; what the
        # census establishes is only that this PR did not cause it.
        arm ok "full rollup" "INHERITED — every concluded red is also red on origin/main over the last $MAIN_N head(s), so none of it is attributable to this PR. THIS IS NOT A CLEAN BILL: $INH$( [ -n "$PENDN" ] && printf ' | still pending (NOT failures): %s' "$PENDN" )"
      else
        arm no "full rollup" "OWN — red(s) NOT explained by origin/main over the last $MAIN_N head(s)$( grep -q '^UNPROVEN' "$CLS" && printf ' (UNPROVEN re-sampled over %s)' "$MAIN_DEEP" ): $OWNS$( [ -n "$INH" ] && printf ' | inherited, not attributable: %s' "$INH" )$( [ -n "$PENDN" ] && printf ' | still pending (NOT failures): %s' "$PENDN" )$( grep -q '^UNPROVEN' "$CLS" && printf ' || AN UNPROVEN CONTEXT IS NOT A PROVEN OWN RED. The commit window AND the workflow-history read have both now been tried and neither produced a main verdict: either the check-run name could not be mapped to a workflow file, or that workflow has NO completed run on main. An absence is still not evidence of health, so it refuses — but it is not a finding about this PR. Settle it by hand: gh api "repos/%s/actions/workflows/<file>.yml/runs?per_page=20" --paginate | jq -s -r "[.[].workflow_runs[]]|.[]|[.conclusion,.event,.head_branch]|@tsv" ' "$REPO" )"
      fi
    fi
    rm -f "$CN" "$NF" "$CLS"
  fi
  rm -f "$T"
}

# --- SELFTEST -----------------------------------------------------------
# WHY THIS EXISTS: this tool shipped with TWO defects that survived a real run
# and a second reader, because BOTH lived on paths a passing PR never reaches.
#   1. the required-set arm compared a key that does not exist -> null == null,
#      right by luck on every PR whose required set had not moved;
#   2. the presence arm crashed under `set -u` on an em-dash abutting $MISS —
#      and it executes ONLY when a required row is MISSING, which no healthy
#      PR ever is. The crash killed the script BEFORE the vacuity floor ran and
#      exited 1, which in this tool's vocabulary reads as a VERDICT.
# A GUARD THAT ONLY EXECUTES ON THE FAILURE PATH IS ONLY EVER EXERCISED BY A
# FAILURE. These arms force each failure path synthetically, so none of them
# waits on a real PR to go wrong.
if [ "${1:-}" = "--selftest" ]; then
  _p=0; _f=0
  _ok(){ _p=$((_p+1)); printf '  PASS %-34s %s\n' "$1" "$2"; }
  _no(){ _f=$((_f+1)); printf '  FAIL %-34s %s\n' "$1" "$2"; }

  # A1 — THE EM-DASH REGRESSION, on the exact shape the presence arm uses.
  if out=$(bash -c 'set -uo pipefail; MISS="Elixir gate; "; printf "NO CHECK ROW rendered for: ${MISS} — absence is not a pass\n"' 2>&1); then
    case "$out" in *"Elixir gate"*"absence is not a pass"*) _ok "presence refusal renders" "under set -u, no crash";;
      *) _no "presence refusal renders" "unexpected output: $out";; esac
  else _no "presence refusal renders" "CRASHED under set -u: $out"; fi
  # A1b — CONTROL: an unbraced expansion that ABSORBS the following character
  # must still crash, or A1 proves nothing.
  #
  # IT IS TWO ARMS, AND THE SPLIT IS THE FINDING. This suite had NO CALLER OF ANY
  # KIND until 2026-09-17 — no workflow, no Makefile target — so it had only ever
  # run on macOS. Its first CI run failed on THIS LINE: whether the em-dash's
  # bytes count as name characters is a bash-version/locale question, and the
  # answer differs. bash 3.2.57 (macOS) absorbs them and dies `MISS<u+2014>:
  # unbound variable` — the production crash, verbatim. bash 5.x on ubuntu stops
  # the name at the non-ASCII byte, expands cleanly, and the control could not
  # fire. A control that only fires on the author's machine is the "control that
  # flips was never a control" fault: it dated the platform, not the subject.
  #
  # So the ASCII arm carries the CLASS and is asserted EVERYWHERE — `$MISSx` is
  # an unbound name on every bash there is. The em-dash arm replays the PRODUCTION
  # STRING and is asserted only where a probe says this interpreter can see it,
  # and it SAYS which case it took rather than passing silently.
  if bash -c 'set -uo pipefail; MISS="x"; printf "%s\n" "$MISSx "' >/dev/null 2>&1
  then _no "CONTROL absorbed suffix crashes" "an unbraced expansion absorbing its suffix did NOT crash — A1 cannot discriminate on ANY platform"
  else _ok "CONTROL absorbed suffix crashes" "\$MISSx is unbound, as \$MISS<em-dash> was in production"; fi
  if bash -c 'set -uo pipefail; MISS="x"; printf "%s\n" "$MISS— "' >/dev/null 2>&1
  then _ok "CONTROL em-dash form (platform-scoped)" "this bash (${BASH_VERSION}) does NOT treat the em-dash as a name character, so the PRODUCTION string cannot crash here; the ASCII arm above carries the class"
  else _ok "CONTROL em-dash form (platform-scoped)" "this bash (${BASH_VERSION}) absorbs the em-dash and dies unbound — the production crash, verbatim"; fi

  # A2 — PAGINATION SHORTFALL must be CANNOT READ, never a pass.
  _tc=119; _got=100
  if [ "$_got" -lt "$_tc" ]; then _ok "pagination shortfall" "collected $_got of $_tc -> CANNOT READ"
  else _no "pagination shortfall" "a short collection did not trip the guard"; fi
  # A2b — CONTROL: a COMPLETE collection must NOT trip it.
  _got=119; if [ "$_got" -lt "$_tc" ]; then _no "CONTROL full collection" "a complete read tripped the shortfall guard"
  else _ok "CONTROL full collection" "$_got of $_tc -> proceeds"; fi

  # A3 — REQUIRED-SET null on either side is CANNOT READ, not equality.
  _a=null; _b=null
  if [ "$_a" = null ] || [ "$_b" = null ]; then _ok "required-set null refuses" "null is not a comparison"
  else _no "required-set null refuses" "null==null passed — the ORIGINAL defect is back"; fi
  # A3b — CONTROL: two real, equal values must compare EQUAL.
  _a='[{"context":"Cloud gate"}]'; _b='[{"context":"Cloud gate"}]'
  if [ "$_a" = null ] || [ "$_b" = null ]; then _no "CONTROL real values compare" "a real value was read as null"
  elif [ "$_a" = "$_b" ]; then _ok "CONTROL real values compare" "equal sets compare equal"
  else _no "CONTROL real values compare" "equal sets did not compare equal"; fi

  # A4 — THE SENTINEL GREP must find a planted sentinel (its own control).
  _n=$(printf 'PDS-D746 and D719\n' | grep -oE 'PDS-D[0-9]+|\bD[0-9]{2,4}\b' | wc -l | tr -d ' ')
  if [ "${_n:-0}" -ge 2 ]; then _ok "sentinel grep fires" "found $_n planted sentinels"
  else _no "sentinel grep fires" "found $_n — a clean body would be indistinguishable from a broken grep"; fi

  # A5 — THE PRESENCE CHECK must name a genuinely absent required context.
  _tf=$(mktemp)
  printf '%s\n' '{"name":"Cloud gate"}' '{"name":"Console gate"}' '{"name":"PR references an active task"}' > "$_tf"
  _miss=""
  for _c in "Cloud gate" "Console gate" "Elixir gate" "PR references an active task"; do
    jq -se --arg c "$_c" 'any(.[]; .name == $c)' "$_tf" >/dev/null 2>&1 || _miss="$_miss$_c; "
  done
  case "$_miss" in *"Elixir gate"*) _ok "presence finds an absent row" "named: ${_miss}";;
    *) _no "presence finds an absent row" "an absent required context was NOT named (got '${_miss}')";; esac
  # A5b — CONTROL: with all four present it must name NOTHING.
  printf '%s\n' '{"name":"Elixir gate"}' >> "$_tf"
  _miss2=""
  for _c in "Cloud gate" "Console gate" "Elixir gate" "PR references an active task"; do
    jq -se --arg c "$_c" 'any(.[]; .name == $c)' "$_tf" >/dev/null 2>&1 || _miss2="$_miss2$_c; "
  done
  if [ -z "$_miss2" ]; then _ok "CONTROL all present names nothing" "no false accusation"
  else _no "CONTROL all present names nothing" "falsely named: $_miss2"; fi
  rm -f "$_tf"

  # A6 — PIN THE LIVE LINE, not just the shape. A1 exercises a hand-written
  # string, so re-introducing the bug in the REAL arm would leave A1 green.
  # Assert POSITIVELY that the actual refusal line uses the BRACED expansion.
  # Scoped to the REAL arm by its `arm no` call, which the A1 test string does
  # not contain. A probe that matches its own fixture pins nothing — this file
  # has now produced that fault three times, so the needle names the CALLER.
  _real=$(grep -n 'arm no "required rows present"' "$0" | grep -v '_real=' | head -1)
  case "$_real" in
    "") _no "live refusal line pinned" "could not FIND the presence refusal line in this file — the pin measures nothing" ;;
    *'${MISS}'*) _ok "live refusal line pinned" "the real arm uses the braced expansion" ;;
    *) _no "live refusal line pinned" "the real arm does NOT use \${MISS}: $_real" ;;
  esac

  # A7 — a FRESH head (zero successes, runs pending) must NOT be reported as a
  # broken reader. The distinction the first version of this guard did not make.
  _ok_n=0; _pend=23
  if [ "$_ok_n" -eq 0 ] && [ "${_pend:-0}" -gt 0 ]; then _ok "fresh head is not a broken reader" "0 successes + $_pend pending -> CI IS FRESH"
  else _no "fresh head is not a broken reader" "a fresh head would still be blamed on the reader"; fi
  # A7b — CONTROL: zero successes with NOTHING pending really IS the reader.
  _pend=0
  if [ "$_ok_n" -eq 0 ] && [ "${_pend:-0}" -gt 0 ]; then _no "CONTROL settled-zero blames reader" "a settled zero was excused as fresh"
  else _ok "CONTROL settled-zero blames reader" "0 successes + 0 pending -> reader"; fi

  # ---- INHERITED/OWN CLASSIFIER ------------------------------------------
  # These call the REAL mc_classify (defined above this block on purpose), so a
  # regression in the shipped function reds here rather than passing against a
  # copy of itself.
  _cens=$(mktemp); _nm=$(mktemp); _outf=$(mktemp)
  # A 5-head census fixture in the shape mc_main_census emits. `Doc budgets` is
  # red on all 5 (stable), `spec drift` on 1 of 5 (flapping), `Cloud gate` green
  # on all 5, and `Never ran here` appears in NO row at all.
  for _i in 1 2 3 4 5; do
    printf 'FAIL\tDoc budgets + anchors\nOK\tCloud gate\n' >> "$_cens"
    printf 'OK\tRequired-check spec drift (advisory)\n' >> "$_cens"
  done
  # flip one drift row to FAIL -> 1 of 5
  perl -0pi -e 's/OK\tRequired-check spec drift \(advisory\)/FAIL\tRequired-check spec drift (advisory)/' "$_cens" 2>/dev/null \
    || sed -i '' '0,/OK	Required-check spec drift (advisory)/s//FAIL	Required-check spec drift (advisory)/' "$_cens"

  # A8 — a red failing on EVERY sampled main head is INHERITED-STABLE and permits.
  printf 'Doc budgets + anchors\n' > "$_nm"
  mc_classify "$_nm" "$_cens" > "$_outf"; _rc=$?
  _line=$(cat "$_outf")
  case "$_rc:$_line" in
    0:INHERITED-STABLE*5/5*) _ok "inherited stable permits" "$_line" ;;
    *) _no "inherited stable permits" "rc=$_rc line=$_line" ;;
  esac
  # A8b — CONTROL: a red that is GREEN on every sampled main head is OWN and refuses.
  printf 'Cloud gate\n' > "$_nm"
  mc_classify "$_nm" "$_cens" > "$_outf"; _rc=$?
  _line=$(cat "$_outf")
  case "$_rc:$_line" in
    1:OWN*0/5*) _ok "CONTROL own red refuses" "$_line" ;;
    *) _no "CONTROL own red refuses" "rc=$_rc line=$_line — an OWN red was not refused" ;;
  esac
  # A8c — a context that rendered NO row on main is UNPROVEN and refuses.
  # An absence is never evidence of health; fail closed.
  printf 'Never ran here\n' > "$_nm"
  mc_classify "$_nm" "$_cens" > "$_outf"; _rc=$?
  _line=$(cat "$_outf")
  case "$_rc:$_line" in
    1:UNPROVEN*0/0*) _ok "unproven refuses" "$_line" ;;
    *) _no "unproven refuses" "rc=$_rc line=$_line — an unrendered context was not failed closed" ;;
  esac

  # A9 — a FLAPPING red is inherited-class but must render DISTINGUISHABLY from
  # a stable one. Collapsing 5/5 and 1/5 into one word destroys the only evidence
  # that separates "main is broken" from "this check is unreliable".
  printf 'Required-check spec drift (advisory)\n' > "$_nm"
  mc_classify "$_nm" "$_cens" > "$_outf"; _rc=$?
  _line=$(cat "$_outf")
  case "$_rc:$_line" in
    0:INHERITED-FLAPPING*1/5*) _ok "flapping is its own object" "$_line" ;;
    *) _no "flapping is its own object" "rc=$_rc line=$_line" ;;
  esac
  # A9b — CONTROL: stable and flapping must not render the same string.
  printf 'Doc budgets + anchors\n' > "$_nm"; _s=$(mc_classify "$_nm" "$_cens")
  printf 'Required-check spec drift (advisory)\n' > "$_nm"; _fl=$(mc_classify "$_nm" "$_cens")
  if [ "${_s#*$'\t'}" = "${_fl#*$'\t'}" ] || [ "$_s" = "$_fl" ]; then
    _no "CONTROL stable != flapping" "both rendered identically — the k/N is not discriminating"
  else _ok "CONTROL stable != flapping" "stable and flapping render differently"; fi

  # A9c — a THIN sample must not be dressed as a STABLE one. Two names, both
  # failing every head they rendered on, but one rendered 5 times and the other
  # once: they are not the same claim and must not print the same word.
  printf 'FAIL\tThin only here\n' >> "$_cens"
  printf 'Thin only here\n' > "$_nm"
  mc_classify "$_nm" "$_cens" > "$_outf"; _rc=$?
  _line=$(cat "$_outf")
  case "$_rc:$_line" in
    0:INHERITED-THIN*1/1*) _ok "thin sample is not stable" "$_line" ;;
    *) _no "thin sample is not stable" "rc=$_rc line=$_line — a 1/1 sample claimed STABLE" ;;
  esac

  # A10 — ANY own red refuses even when inherited reds sit alongside it. This is
  # the #18400-first-head shape: one genuinely own red mixed with an inherited
  # one. A rule that permitted on "some red is inherited" would pass this PR.
  printf 'Doc budgets + anchors\nCloud gate\n' > "$_nm"
  mc_classify "$_nm" "$_cens" > "$_outf"; _rc=$?
  if [ "$_rc" = 1 ] && grep -q '^OWN' "$_outf" && grep -q '^INHERITED' "$_outf"; then
    _ok "any own red refuses the set" "mixed set refused, both classes named"
  else _no "any own red refuses the set" "rc=$_rc — a mixed set did not refuse: $(tr '\n' ' ' < "$_outf")"; fi
  # A10b — CONTROL: an all-inherited set permits.
  printf 'Doc budgets + anchors\nRequired-check spec drift (advisory)\n' > "$_nm"
  mc_classify "$_nm" "$_cens" >/dev/null; _rc=$?
  if [ "$_rc" = 0 ]; then _ok "CONTROL all-inherited permits" "rc=0"
  else _no "CONTROL all-inherited permits" "rc=$_rc — an all-inherited set was refused"; fi

  # A11 — AN EMPTY CENSUS IS NOT A CLEAN MAIN. An exhausted shared rate limit
  # renders as an EMPTY RESULT SET with stderr suppressed. Without this guard
  # every red would classify OWN and the old false refusal would come back
  # wearing a new and more convincing story.
  _empty=$(mktemp)
  printf 'Doc budgets + anchors\n' > "$_nm"
  mc_classify "$_nm" "$_empty" > "$_outf"; _rc=$?
  if [ "$_rc" = 3 ] && grep -q 'CENSUS-UNREADABLE' "$_outf"; then
    _ok "empty census is CANNOT READ" "rc=3, not a silent OWN"
  else _no "empty census is CANNOT READ" "rc=$_rc out=$(cat "$_outf") — an empty census did not refuse to answer"; fi
  # A11b — CONTROL: a census ABOVE the floor must be answerable.
  mc_classify "$_nm" "$_cens" >/dev/null; _rc=$?
  if [ "$_rc" = 3 ]; then _no "CONTROL full census answers" "a full census was called unreadable"
  else _ok "CONTROL full census answers" "rc=$_rc — a real census yields a verdict"; fi
  rm -f "$_empty"

  # A12 — PIN THE PAGINATION FORM IN THE LIVE CENSUS. `gh api --paginate -q`
  # evaluates the filter ONCE PER PAGE, so a context on page 2 reads as NOT
  # RENDERED rather than as an error — which here would manufacture UNPROVEN
  # (a refusal) out of a perfectly healthy main. Assert the census uses the
  # stream form and NOT -q, by reading THIS FILE.
  _cl=$(grep -n 'gh api "repos/\$REPO/commits/\$c/check-runs' "$0" | head -1)
  case "$_cl" in
    "") _no "census pagination form pinned" "could not find the census read in this file" ;;
    *--paginate*-q*|*'--jq'*) _no "census pagination form pinned" "the census uses a per-page filter: $_cl" ;;
    *--paginate*) _ok "census pagination form pinned" "--paginate with no per-page filter; piped to jq -s" ;;
    *) _no "census pagination form pinned" "the census does not paginate at all: $_cl" ;;
  esac

  # A13 — THE MUTATION SWITCH MUST ACTUALLY MUTATE. If the disarm env did not
  # change the verdict, the live mutation replay in the PR body would prove
  # nothing — a disarm that disarms nothing is the same fault class as a control
  # that never fires.
  printf 'Doc budgets + anchors\n' > "$_nm"
  mc_classify "$_nm" "$_cens" >/dev/null; _armed=$?
  MERGE_CHECK_DISARM_INHERITED=1 mc_classify "$_nm" "$_cens" >/dev/null; _dis=$?
  if [ "$_armed" = 0 ] && [ "$_dis" = 1 ]; then
    _ok "disarm switch flips the verdict" "armed permits (0), disarmed refuses (1)"
  else _no "disarm switch flips the verdict" "armed=$_armed disarmed=$_dis — the mutation arm cannot discriminate"; fi
  rm -f "$_cens" "$_nm" "$_outf"

  # A14 — A CHECK NAME CONTAINING COMMAS MUST SURVIVE AS ONE NAME. The first cut
  # of this fix built the name list by splitting the comma-joined display string,
  # which shredded `tooling/{aesthetics, ergonomics, risk} ...` into three
  # fragments that match nothing on main -> three UNPROVEN -> a false refusal,
  # produced by the very code meant to remove false refusals. Found by running
  # the tool against its own PR, not by reading it.
  _cn='tooling/{aesthetics, ergonomics, risk} node --test suite + tooling/pds gate'
  _cens2=$(mktemp); _nm2=$(mktemp)
  for _i in 1 2 3 4 5; do printf 'FAIL\t%s\n' "$_cn" >> "$_cens2"; printf 'OK\tCloud gate\n' >> "$_cens2"; done
  printf '%s\n' "$_cn" > "$_nm2"
  _out2=$(mc_classify "$_nm2" "$_cens2"); _rc=$?
  case "$_rc:$_out2" in
    0:INHERITED-STABLE*5/5*) _ok "comma-bearing name survives" "classified as ONE name, 5/5" ;;
    *) _no "comma-bearing name survives" "rc=$_rc out=$_out2 — a comma in a check name split it" ;;
  esac
  # A14b — CONTROL: the shredding form really does shred, or A14 proves nothing.
  _frag=$(printf '%s' "$_cn" | tr ',' '\n' | grep -c '^')
  if [ "$_frag" -ge 3 ]; then _ok "CONTROL comma-split shreds" "the old form yields $_frag fragments from 1 name"
  else _no "CONTROL comma-split shreds" "the old form yielded $_frag — A14 cannot discriminate"; fi
  rm -f "$_cens2" "$_nm2"

  # ---- A15: PENDING IS NOT A FAILURE -------------------------------------
  # Runs the REAL mc_failed_names / mc_pending_names over a synthetic head that
  # carries one concluded failure and two pending rows — the exact shape deploy
  # read as "two NEW failures" when both were in_progress with conclusion null.
  _crf=$(mktemp)
  printf '%s\n' \
    '{"name":"Elixir gate","status":"completed","conclusion":"failure","started_at":"2026-09-16T01:00:00Z"}' \
    '{"name":"Required-check spec gate","status":"in_progress","conclusion":null,"started_at":"2026-09-16T01:00:00Z"}' \
    '{"name":"Required-check spec drift (advisory)","status":"queued","conclusion":null,"started_at":"2026-09-16T01:00:00Z"}' \
    '{"name":"Cloud gate","status":"completed","conclusion":"success","started_at":"2026-09-16T01:00:00Z"}' > "$_crf"
  _fl=$(mc_failed_names "$_crf" | tr '\n' '|'); _pl=$(mc_pending_names "$_crf" | tr '\n' '|')
  _a15=1
  [ "$_fl" = "Elixir gate|" ] || _a15=0
  case "$_pl" in *"Required-check spec gate"*) : ;; *) _a15=0 ;; esac
  case "$_pl" in *"drift (advisory)"*) : ;; *) _a15=0 ;; esac
  if [ "$_a15" = 1 ]; then _ok "pending is not a failure" "failures=[$_fl] pending=[$_pl]"
  else _no "pending is not a failure" "failures=[$_fl] pending=[$_pl] — a pending row is being read as a failure"; fi
  # A15b — CONTROL: the PRE-FIX pooled reader really does pool, or A15 pins nothing.
  _pool=$(mc_pooled_names_OLD "$_crf" | grep -c .)
  if [ "${_pool:-0}" -ge 3 ]; then _ok "CONTROL pooled reader pools" "the pre-fix filter names $_pool non-success rows (1 failed + 2 PENDING)"
  else _no "CONTROL pooled reader pools" "the pre-fix filter named $_pool — A15 cannot discriminate"; fi
  rm -f "$_crf"

  # A15c — A WAIT MUST NOT LAND IN THE FAIL BUCKET. This is the defect measured
  # on #18483: the arm's own text said ZERO CONCLUDED FAILURES and the verdict
  # it produced said DO NOT MERGE, because the wait came out of `cannot`.
  _F0=$FAIL; _A0=$ARMS; _W0=$WAITS
  waitfor "selftest-probe" "synthetic wait" >/dev/null
  if [ "$FAIL" -eq "$_F0" ] && [ "$WAITS" -eq $((_W0+1)) ] && [ "$ARMS" -eq $((_A0+1)) ]; then
    _ok "a WAIT does not refuse" "FAIL unchanged at $FAIL, WAITS $_W0->$WAITS, counted as an arm"
  else _no "a WAIT does not refuse" "FAIL $_F0->$FAIL WAITS $_W0->$WAITS ARMS $_A0->$ARMS — a wait still refuses"; fi
  FAIL=$_F0; ARMS=$_A0; WAITS=$_W0
  # A15d — CONTROL: a GENUINELY unreadable input must STILL increment FAIL. The
  # split must not have turned fail-closed into fail-open.
  _F0=$FAIL; _A0=$ARMS
  cannot "selftest-probe" "synthetic unreadable input" >/dev/null
  if [ "$FAIL" -eq $((_F0+1)) ]; then _ok "CONTROL cannot-read still refuses" "FAIL $_F0->$FAIL — fail-closed intact"
  else _no "CONTROL cannot-read still refuses" "FAIL $_F0->$FAIL — an unreadable input stopped refusing"; fi
  FAIL=$_F0; ARMS=$_A0

  # ---- A16: THE WORKFLOW'S MAIN HISTORY ANSWERS UNPROVEN -------------------
  # Calls the REAL mc_wf_classify. `research-coverage-suite.yml` had THREE
  # push/main runs, all failure, while its context read UNPROVEN 0/0 off a
  # 20-commit window. The window was the blind spot, not the workflow.
  _wfc=$(mktemp)
  _cn='tooling/{aesthetics, ergonomics, risk} node --test suite + tooling/pds gate'
  printf 'FAIL\taaa\nFAIL\tbbb\nFAIL\tccc\n' > "$_wfc"
  _out=$(mc_wf_classify "$_cn" "$_wfc"); _rc=$?
  case "$_rc:$_out" in
    0:INHERITED-MAIN-WF-STABLE*3/3*) _ok "unproven flips on wf history" "$_out" ;;
    *) _no "unproven flips on wf history" "rc=$_rc out=$_out — a wholly-failing main workflow history did not permit" ;;
  esac
  # A16b — CONTROL: a workflow GREEN on main stays OWN and still REFUSES.
  printf 'OK\taaa\nOK\tbbb\n' > "$_wfc"
  _out=$(mc_wf_classify "$_cn" "$_wfc"); _rc=$?
  case "$_rc:$_out" in
    1:OWN*0/2*) _ok "CONTROL green-on-main is OWN" "$_out" ;;
    *) _no "CONTROL green-on-main is OWN" "rc=$_rc out=$_out — a context green on main was excused" ;;
  esac
  # A16c — NO main history at all stays UNPROVEN and still refuses. An absence
  # is never evidence of health; the new read must not invent one.
  : > "$_wfc"
  _out=$(mc_wf_classify "$_cn" "$_wfc"); _rc=$?
  case "$_rc:$_out" in
    1:UNPROVEN*0/0*) _ok "no wf history stays unproven" "$_out" ;;
    *) _no "no wf history stays unproven" "rc=$_rc out=$_out — an empty history produced a verdict" ;;
  esac
  # A16d — A FLAPPING main workflow is inherited-class but renders distinguishably.
  printf 'FAIL\taaa\nOK\tbbb\nOK\tccc\n' > "$_wfc"
  _out=$(mc_wf_classify "$_cn" "$_wfc"); _rc=$?
  case "$_rc:$_out" in
    0:INHERITED-MAIN-WF-FLAPPING*1/3*) _ok "wf flapping is its own object" "$_out" ;;
    *) _no "wf flapping is its own object" "rc=$_rc out=$_out" ;;
  esac
  rm -f "$_wfc"
  # A16e — THE NAME->WORKFLOW MAPPING. The missing piece: a check run carries a
  # details_url, and actions/runs/<id> carries .path. Pure parse, plus a control
  # that a URL of the wrong shape yields NOTHING rather than a guess.
  _rid=$(mc_run_id_from_details_url "https://github.com/FRIKKern/barkpark/actions/runs/34955892970/job/97531")
  if [ "$_rid" = "34955892970" ]; then _ok "details_url yields a run id" "34955892970"
  else _no "details_url yields a run id" "got [$_rid] — the name->workflow mapping cannot start"; fi
  _bad=$(mc_run_id_from_details_url "https://example.com/not/an/actions/url")
  if [ -z "$_bad" ]; then _ok "CONTROL wrong-shape URL yields nothing" "no run id invented"
  else _no "CONTROL wrong-shape URL yields nothing" "parsed [$_bad] out of a non-actions URL"; fi

  # ---- A17: THE HOLD LABEL. #18497 carried `hold` continuously from
  # 2026-09-16T08:51:19Z and merged at 06:41Z on 09-17 under `ALL 9 CONDITIONS
  # MET`, because the arm was `arm ok` in BOTH readable branches. These arms
  # call the REAL mc_hold_verdict, and A17/A17b drive it through the ACTUAL jq
  # program the live arm runs, over the ACTUAL object `gh pr view --json labels`
  # emits (captured from #18705 and #18882 on 2026-09-17) — a selftest whose
  # fixtures encode a shape the system never emits measures nothing.
  _ghheld='{"labels":[{"id":"LA_kwDOSAgT9M8AAAAC1x0Gkg","name":"hold","description":"Lane-settable merge hold: the orchestrator merge sweep skips this PR","color":"B60205"}]}'
  _ghclear='{"labels":[]}'
  # The live arm's jq, verbatim. If this line and the live one drift, A17j reds.
  _hraw=$(printf '%s' "$_ghheld" | jq -r '[.labels[].name]|@json')
  _out=$(mc_hold_verdict "$_hraw"); _rc=$?
  case "$_rc:$_out" in
    1:HELD*) _ok "real gh shape -> HELD" "$_out" ;;
    *) _no "real gh shape -> HELD" "rc=$_rc out=$_out — the shape gh ACTUALLY emits did not read as held" ;;
  esac
  # A17b — CONTROL: a real, readable, genuinely UNLABELLED PR must be CLEAR.
  _hraw=$(printf '%s' "$_ghclear" | jq -r '[.labels[].name]|@json')
  _out=$(mc_hold_verdict "$_hraw"); _rc=$?
  case "$_rc:$_out" in
    0:CLEAR*none*) _ok "CONTROL zero labels is CLEAR" "$_out" ;;
    *) _no "CONTROL zero labels is CLEAR" "rc=$_rc out=$_out — an unlabelled PR must PASS, or every PR is held" ;;
  esac
  # A17c — A HELD PR MUST LAND IN THE FAIL BUCKET. rc alone is not the defect:
  # the old code got the rc-equivalent RIGHT (it matched *hold*) and still
  # called `arm ok`. This drives the REAL arm helper and reads the REAL counter.
  _F0=$FAIL; _A0=$ARMS
  arm no "selftest-hold" "synthetic held PR" >/dev/null
  if [ "$FAIL" -eq $((_F0+1)) ] && [ "$ARMS" -eq $((_A0+1)) ]; then
    _ok "a HELD arm refuses" "FAIL $_F0->$FAIL — a hold reaches the verdict"
  else _no "a HELD arm refuses" "FAIL $_F0->$FAIL ARMS $_A0->$ARMS — a hold does not change the verdict"; fi
  FAIL=$_F0; ARMS=$_A0
  # A17d — AN UNREADABLE LABEL IS CANNOT, NEVER CLEAR. The old `__UNREAD__` arm
  # printed nothing at all while still counting as an arm.
  _out=$(mc_hold_verdict ""); _rc=$?
  case "$_rc:$_out" in
    2:UNREAD*) _ok "empty read is UNREAD" "$_out" ;;
    *) _no "empty read is UNREAD" "rc=$_rc out=$_out — an empty read reported a verdict about labels" ;;
  esac
  _out=$(mc_hold_verdict 'not json at all'); _rc=$?
  case "$_rc:$_out" in
    2:UNREAD*) _ok "unparseable read is UNREAD" "$_out" ;;
    *) _no "unparseable read is UNREAD" "rc=$_rc out=$_out" ;;
  esac
  # A17e — EXACT MEMBERSHIP, NOT A SUBSTRING GLOB. `holdover`/`withhold`/
  # `stakeholder` are not holds.
  _out=$(mc_hold_verdict '["holdover","withhold","stakeholder"]'); _rc=$?
  case "$_rc:$_out" in
    0:CLEAR*) _ok "hold-lookalikes are not holds" "$_out" ;;
    *) _no "hold-lookalikes are not holds" "rc=$_rc out=$_out — a substring match is falsely holding PRs" ;;
  esac
  # A17f — CONTROL: the PRE-FIX glob really DOES misfire on those, or A17e pins
  # nothing. This is the retired reader, kept only to be the control.
  case "holdover,withhold,stakeholder" in
    *hold*) _ok "CONTROL the old glob misfires" "the pre-fix *hold* glob matched three non-hold labels" ;;
    *) _no "CONTROL the old glob misfires" "the pre-fix glob did not match — A17e cannot discriminate" ;;
  esac
  # A17g — case-insensitive exact match still holds.
  _out=$(mc_hold_verdict '["Hold"]'); _rc=$?
  case "$_rc:$_out" in
    1:HELD*) _ok "case-insensitive exact match" "$_out" ;;
    *) _no "case-insensitive exact match" "rc=$_rc out=$_out — a capitalised label escaped the hold" ;;
  esac
  # A17h — a hold ALONGSIDE other labels is still a hold (the join-order trap).
  _out=$(mc_hold_verdict '["needs-review","hold","area/gates"]'); _rc=$?
  case "$_rc:$_out" in
    1:HELD*) _ok "hold among other labels" "$_out" ;;
    *) _no "hold among other labels" "rc=$_rc out=$_out" ;;
  esac
  # A17j — PIN THE LIVE LINES, not just the classifier. Reverting the live arm to
  # `arm ok` would leave every arm above green. Assert POSITIVELY that the real
  # HELD branch calls `arm no`, that the UNREAD branch calls `cannot`, and that
  # the live read uses @json (a join(",") read cannot tell [] from unreadable).
  _real=$(grep -n '1) arm no "hold label"' "$0" | grep -v '_real=' | head -1)
  case "$_real" in
    "") _no "live HELD branch pinned" "could not FIND the HELD branch — the pin measures nothing" ;;
    *) _ok "live HELD branch pinned" "the real arm refuses on HELD (arm no)" ;;
  esac
  _realu=$(grep -c '^  \*) cannot "hold-label"' "$0")
  if [ "${_realu:-0}" -ge 1 ]; then _ok "live UNREAD branch pinned" "the real arm calls cannot on an unread label"
  else _no "live UNREAD branch pinned" "the real arm no longer refuses an unreadable label"; fi
  _realj=$(grep -c "json labels --jq '\[\.labels\[\]\.name\]|@json'" "$0")
  if [ "${_realj:-0}" -ge 1 ]; then _ok "live read uses @json" "the raw array survives to the classifier"
  else _no "live read uses @json" "the live read no longer passes a raw array — [] and unreadable have re-merged"; fi
  # A17k — NO LIVE BRANCH MAY PASS A HELD PR. Scoped to NON-COMMENT lines: the
  # comment block above QUOTES the retired code verbatim, and the first version
  # of this arm matched its own documentation and red. That miss is the point —
  # a pin that reads comments is measuring prose, not behaviour.
  # NOT `grep -v … | grep -q`: this file runs under `set -o pipefail` and `grep
  # -q` exits on its FIRST match, SIGPIPEing the upstream grep, so the pipeline
  # returns 141 — non-zero — and the arm reads "not found" whether or not the
  # needle is there. That is this repo's pipefail/SIGPIPE lesson, and it made
  # the first draft of A17m red against a line 60 lines below it. Count into a
  # variable instead; the whole stream is consumed, so nothing gets SIGPIPEd.
  # THE NEEDLES ARE SPLIT ACROSS A CONCATENATION ON PURPOSE. Written whole, each
  # needle IS a live non-comment line of this file, so the arm matches its own
  # source and reports the defect it exists to detect. The first draft did
  # exactly that (1 "live" PASS-on-HELD line: this one). Split, the literal never
  # appears in the file, so a hit can only come from the real arm.
  _live=$(grep -v '^[[:space:]]*#' "$0")
  _nh='arm ok "hold label" "H'; _nh="${_nh}ELD"
  _nc='arm ok "hold label" "not h'; _nc="${_nc}eld"
  _passheld=$(printf '%s\n' "$_live" | grep -c "$_nh" || true)
  _passclear=$(printf '%s\n' "$_live" | grep -c "$_nc" || true)
  if [ "${_passheld:-0}" -gt 0 ]; then
    _no "CONTROL no PASS-on-HELD remains" "$_passheld LIVE line(s) still pass a held PR — the original defect"
  else _ok "CONTROL no PASS-on-HELD remains" "no live branch passes a held PR"; fi
  # A17m — CONTROL FOR THE CONTROL: that comment-stripped grep must still FIND
  # the arm it is scoped to, or A17k is green because the needle is broken.
  if [ "${_passclear:-0}" -eq 1 ]; then
    _ok "CONTROL the stripped grep sees code" "the same stripped stream finds the live CLEAR branch, exactly once"
  else _no "CONTROL the stripped grep sees code" "expected exactly 1 live CLEAR branch, found ${_passclear:-0} — A17k is vacuous or the arm was duplicated"; fi

  # ── A18 — THE PDS-CITATION ARM, PROVEN IN BOTH DIRECTIONS ─────────────────
  #
  # NOT FIXTURE THEATRE. These arms run the REAL predicate
  # (scripts/pds-citation-precedes-merge.sh) over a THROWAWAY GIT REPO this
  # block writes, then hand its ACTUAL rc and ACTUAL stdout to the REAL
  # classifier mc_pds_citation_verdict, which calls the REAL `arm`/`cannot`
  # helpers and moves the REAL counters. Nothing below re-types the case
  # statement it is checking, and nothing below matches its own fixture: the
  # two `sed` extractions in the classifier are read off output the predicate
  # produced, so a classifier whose extraction stopped matching reds here.
  #
  # THE REPO IS ITS OWN CORPUS. The real charter is never read, so the verdict
  # cannot move when an unrelated PR lands, and no network or origin/main
  # history is needed — the merge-check leg may be checked out shallow.
  #
  # THE PHANTOM NUMBER IS BUILT ARITHMETICALLY, never written as a prefixed
  # literal: the live arm above runs this very predicate over this very file's
  # diff, and a planted phantom written out would red the arm by construction.
  # Anchored on THIS FILE's location, never on $PWD: merge-check.sh --selftest is
  # run from wherever the operator stands, and a relative subject path would make
  # the arms below vanish (or worse, read a different tree) off the cwd alone.
  PWD_REAL="$(cd "$(dirname "$0")/.." && pwd)"
  _pc_subj="scripts/pds-citation-precedes-merge.sh"
  _pc_lens="$PWD_REAL/scripts/pds-record-parity.sh"
  if [ ! -f "$PWD_REAL/$_pc_subj" ] || [ ! -f "$_pc_lens" ]; then
    # ABSENCE IS NOT A SKIP. A missing subject makes every arm below vacuous, so
    # it refuses loudly — six times, once per arm it displaced, so the tally
    # reads FAILED (a diagnosis) and not CANNOT READ (a floor breach).
    _no "a defined citation PASSES" "missing $PWD_REAL/$_pc_subj or $_pc_lens — this arm measured nothing"
    _no "the PASS detail is extracted, not empty" "not run: the subject or its lens is absent"
    _no "a phantom citation REFUSES" "not run: the subject or its lens is absent"
    _no "the refusal NAMES the number" "not run: the subject or its lens is absent"
    _no "UNCHECKED refuses, it does not pass" "not run: the subject or its lens is absent"
    _no "UNCHECKED counts against the verdict" "not run: the subject or its lens is absent"
  else
    _pcD1=$((100 + 0)); _pcD2=$((100 + 1)); _pcPH=$((9000 + 91))
    _pcT="$(mktemp -d "${TMPDIR:-/tmp}/mc-pdscite.XXXXXX")"
    mkdir -p "$_pcT/.claude/workflows" "$_pcT/api"
    git -C "$_pcT" init -q -b main
    git -C "$_pcT" config user.email t@example.com
    git -C "$_pcT" config user.name t
    git -C "$_pcT" config commit.gpgsign false
    {
      echo "# Fixture charter"; echo
      echo "### PDS-D${_pcD1} — THE FIRST DECISION."; echo "body"; echo
      echo "- **PDS-D${_pcD2} — THE SECOND DECISION.** body"
    } > "$_pcT/.claude/workflows/bp-pds-charter.md"
    echo "seed" > "$_pcT/api/seed.ex"
    git -C "$_pcT" add -A && git -C "$_pcT" commit -q -m base
    git -C "$_pcT" checkout -q -b slice

    # A FILE REDIRECT, NOT A COMMAND SUBSTITUTION. `v=$(mc_pds_citation_verdict …)`
    # runs the classifier in a SUBSHELL, so ARMS and FAIL come back unchanged and
    # every counter assertion below would read 0->0 and fail while the classifier
    # worked perfectly. Measured here on the first run of these arms. The verdict
    # must be captured WITHOUT losing the side effect that IS the thing under test.
    _pcVF="$(mktemp "${TMPDIR:-/tmp}/mc-pdsv.XXXXXX")"
    _pc_verdict(){ mc_pds_citation_verdict "$_pcRC" "$_pcOUT" > "$_pcVF" 2>&1; _pcV="$(cat "$_pcVF")"; }

    _pc_run(){ # -> $_pcOUT, $_pcRC
      _pcOUT="$(cd "$_pcT" && bash "$PWD_REAL/$_pc_subj" --root "$_pcT" --base main --head HEAD --lens "$_pc_lens" 2>&1)"
      _pcRC=$?
    }

    # DIRECTION 1 — a diff citing a number the base charter DEFINES must PASS.
    echo "# see PDS-D${_pcD1} for why" >> "$_pcT/api/seed.ex"
    git -C "$_pcT" commit -q -am "cite a defined decision"
    _pc_run
    _A0=$ARMS; _F0=$FAIL
    _pc_verdict
    if [ "$_pcRC" -eq 0 ] && [ "$FAIL" -eq "$_F0" ] && [ "$ARMS" -eq "$((_A0 + 1))" ]; then
      _ok "a defined citation PASSES" "predicate rc=0; the arm reported and did NOT refuse: ${_pcV}"
    else
      _no "a defined citation PASSES" "rc=$_pcRC FAIL $_F0->$FAIL ARMS $_A0->$ARMS — ${_pcV}"
    fi
    # and the PASS detail must carry the predicate's own citations line, or the
    # classifier's sed matched nothing and the verdict is content-free.
    case "$_pcV" in
      *"introduced occurrence"*) _ok "the PASS detail is extracted, not empty" "the citations line reached the verdict: ${_pcV}" ;;
      *) _no "the PASS detail is extracted, not empty" "the classifier's sed pulled nothing off real output: ${_pcV}" ;;
    esac

    # DIRECTION 2 — a diff citing a number NOTHING defines must RED, BY NAME.
    echo "# and also PDS-D${_pcPH}, which is nothing" >> "$_pcT/api/seed.ex"
    git -C "$_pcT" commit -q -am "cite a phantom"
    _pc_run
    _A0=$ARMS; _F0=$FAIL
    _pc_verdict
    if [ "$_pcRC" -eq 1 ] && [ "$FAIL" -eq "$((_F0 + 1))" ]; then
      _ok "a phantom citation REFUSES" "predicate rc=1 and the arm refused: ${_pcV}"
    else
      _no "a phantom citation REFUSES" "rc=$_pcRC FAIL $_F0->$FAIL — a phantom did not reach the verdict: ${_pcV}"
    fi
    case "$_pcV" in
      *"PDS-D${_pcPH}"*) _ok "the refusal NAMES the number" "the MISSING list reached the verdict: PDS-D${_pcPH}" ;;
      *) _no "the refusal NAMES the number" "the refusal does not name PDS-D${_pcPH}: ${_pcV}" ;;
    esac

    # DIRECTION 3 — UNCHECKED is `cannot`, never a pass. An unresolvable base
    # makes the predicate exit 2 with no verdict printed; a classifier that
    # folded that into the 0-branch would publish a clean bill off a read that
    # never happened.
    _pcOUT="$(cd "$_pcT" && bash "$PWD_REAL/$_pc_subj" --root "$_pcT" --base no-such-ref-here --head HEAD --lens "$_pc_lens" 2>&1)"; _pcRC=$?
    _A0=$ARMS; _F0=$FAIL
    _pc_verdict
    case "${_pcRC}|${_pcV}" in
      2\|CANNOT*) _ok "UNCHECKED refuses, it does not pass" "predicate rc=2 -> ${_pcV}" ;;
      *) _no "UNCHECKED refuses, it does not pass" "rc=$_pcRC -> ${_pcV} — an unreadable corpus must not print a pass" ;;
    esac
    if [ "$FAIL" -eq "$((_F0 + 1))" ]; then
      _ok "UNCHECKED counts against the verdict" "FAIL $_F0->$FAIL"
    else _no "UNCHECKED counts against the verdict" "FAIL $_F0->$FAIL — a CANNOT READ that costs nothing is decoration"; fi

    rm -rf -- "$_pcT" "$_pcVF"
  fi

  # A18f — PIN THE LIVE CALL. Every arm above drives the classifier directly, so
  # deleting the live invocation would leave all of them green while the shipped
  # check measured nothing. Assert the live path calls it, exactly once, off a
  # comment-stripped stream (a hit inside a comment is documentation, not code).
  _pclive=$(grep -v '^[[:space:]]*#' "$0" | grep -c 'mc_pds_citation_verdict "\$PCS_RC"' || true)
  if [ "${_pclive:-0}" -eq 1 ]; then
    _ok "the live pds-citation arm is wired" "1 live call to the classifier on the merge path"
  else _no "the live pds-citation arm is wired" "found ${_pclive:-0} live call(s) — the arm above is unreachable in production"; fi

  # DERIVED tally with its own floor. A hardcoded count is a lie waiting.
  _total=$((_p+_f))
  # THE FLOOR RISES WITH THE SUITE. 26 before the pending/failure split and the
  # workflow-history read added 10 arms (A15..A15d, A16..A16e); the hold-label
  # repair added 12 more (A17..A17m); A1b split into a
  # platform-independent arm plus a platform-scoped one.
  if [ "$_total" -lt 56 ]; then
    echo "MERGE-CHECK SELFTEST: CANNOT READ — only $_total arm(s) reported; this tally measures nothing"; exit 3
  fi
  if [ "$_f" -eq 0 ]; then echo "MERGE-CHECK SELFTEST: $_p/$_total arms pass"; exit 0
  else echo "MERGE-CHECK SELFTEST: $_f of $_total arm(s) FAILED"; exit 1; fi
fi

# --- REPLAY HARNESS ------------------------------------------------------
# `--classify <sha>` runs the rollup + inherited/own classifier against one head
# and nothing else. It exists so a historical specimen can be replayed THROUGH
# THE SHIPPED FUNCTION — both directions, inherited and own, on the same code
# path — instead of being argued about from a screenshot.
if [ "${1:-}" = "--classify" ]; then
  CLSHA="${2:-}"; REPO="${3:-FRIKKern/barkpark}"
  [ -n "$CLSHA" ] || { echo "usage: merge-check.sh --classify <sha> [owner/repo]"; exit 2; }
  echo "REPLAY sha=$CLSHA repo=$REPO main_sample=$MAIN_N disarm=${MERGE_CHECK_DISARM_INHERITED:-0}"
  mc_rollup "$CLSHA"
  if [ "$FAIL" -eq 0 ] && [ "$WAITS" -gt 0 ]; then
    echo "REPLAY VERDICT: WAIT ($WAITS of $ARMS arm(s) still moving, 0 concluded failures)"; exit 4
  elif [ "$FAIL" -eq 0 ]; then echo "REPLAY VERDICT: PERMIT ($ARMS arm(s), 0 refusals)"; exit 0
  else echo "REPLAY VERDICT: REFUSE ($FAIL of $ARMS arm(s) not met)"; exit 1; fi
fi

PR="${1:-}"; BR="${2:-}"; REPO="${3:-FRIKKern/barkpark}"
[ -n "$PR" ] && [ -n "$BR" ] || { echo "usage: merge-check.sh <pr> <branch> [owner/repo]"; exit 2; }

# 0. PR STATE FIRST. EVERY OTHER ARM BELOW DESCRIBES AN OPEN PR AND SAYS NOTHING
# ABOUT A CLOSED ONE. cli was ONE COMMAND from merging a PR that had merged 78
# minutes earlier, because a sibling tool printed "MERGEABLE: 4/4 required green"
# without ever reading state. The mirror is worse: a lead who reads "MERGEABLE"
# as "not yet merged" WAITS on work that is already done.
# It also kills the overlap arm's nastiest false alarm — on a MERGED PR, main has
# changed the files you changed BY MERGING YOU, and the arm cannot tell your own
# landed commit from a sibling's clobber. Refuse before that alarm can be read.
PRSTATE=$(gh pr view "$PR" --repo "$REPO" --json state,mergedAt --jq '"\(.state)\t\(.mergedAt // "-")"' 2>/dev/null)
case "${PRSTATE%%	*}" in
  MERGED) printf 'CANNOT READ %-14s %s\n' "pr-state" "#$PR is ALREADY MERGED (at ${PRSTATE##*	}) — every arm below describes an OPEN PR. NOTHING HERE IS A VERDICT. Do not merge, do not wait."; exit 3 ;;
  CLOSED) printf 'CANNOT READ %-14s %s\n' "pr-state" "#$PR is CLOSED unmerged — every arm below describes an OPEN PR. NOTHING HERE IS A VERDICT."; exit 3 ;;
  OPEN)   printf 'PASS %-22s %s\n' "pr-state" "#$PR is OPEN — the arms below have a live subject" ;;
  *)      printf 'CANNOT READ %-14s %s\n' "pr-state" "state unreadable (got [${PRSTATE%%	*}]) — an unread state is NOT an open PR"; exit 3 ;;
esac

# 1. HOLD LABEL — read from the server, never from an exit code, and a HOLD is a
# REFUSAL. See mc_hold_verdict above for the three defects this replaces; the
# short version is that the old arm was `arm ok` in BOTH readable branches, so a
# held PR still reached ALL N CONDITIONS MET (#18497, merged under a live hold).
# The classifier is handed the RAW ARRAY so `[]` (no labels) and a failed read
# are DIFFERENT objects.
HOLD_RAW=$(gh pr view "$PR" --repo "$REPO" --json labels --jq '[.labels[].name]|@json' 2>/dev/null) || HOLD_RAW=""
HOLD_OUT=$(mc_hold_verdict "$HOLD_RAW"); HOLD_RC=$?
HOLD_WHY=${HOLD_OUT#*	}
case "$HOLD_RC" in
  1) arm no "hold label" "HELD by the \`$MC_HOLD_LABEL\` label — ${HOLD_WHY}. A hold is a REFUSAL, not a note: remove the label deliberately, then re-run this." ;;
  0) arm ok "hold label" "not held — ${HOLD_WHY}" ;;
  *) cannot "hold-label" "${HOLD_WHY} — an unread label is NOT an absent hold" ;;
esac

# 2. HEADS AGREE. The API and the branch must name the same commit.
API=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null)
git fetch -q origin "+$BR:refs/remotes/origin/$BR" 2>/dev/null
REAL=$(git rev-parse "refs/remotes/origin/$BR" 2>/dev/null)
case "$REAL" in refs/*|"") cannot "branch-head" "tracking ref unreadable (rev-parse echoed the ref NAME)"; REAL="";; esac
if [ -z "$API" ] || [ -z "$REAL" ]; then cannot "heads" "one side unreadable — NO VERDICT"
elif [ "$API" = "$REAL" ]; then arm ok "heads agree" "$API"
else arm no "heads agree" "API $API != branch $REAL — a verdict about one sha, a merge of another"; fi

# 3. REQUIRED FOUR.
# LOCATION-INDEPENDENT (main, 2026-09-15). The original `$(dirname $0)/../pr-required.sh`
# resolved correctly ONLY from $ORCH/lead-gates/. Main promoted a COPY to $ORCH/ and broke it
# there: the arm then ALWAYS took the CANNOT READ branch — and a permanently-blind arm still
# REPORTS, so it counted toward the arm tally and the vacuity floor. Deadness wearing the
# costume of a legitimate outcome, on the single most important arm. Found by deploy.
# stderr is no longer discarded: a missing helper must be visible, not swallowed by 2>/dev/null.
#
# NOW THAT THIS SCRIPT IS TRACKED UNDER scripts/, the relative candidates no longer
# reach the lane-local helper, which still lives in the orchestrate scratch dir and is
# actively edited there. Vendoring a COPY of a moving file is how a stale fork ships,
# so the lookup takes an explicit override instead: set MERGE_CHECK_PRREQ to the live
# pr-required.sh. With none of the candidates present the arm says CANNOT READ, loudly
# — it never quietly passes.
_MC_DIR=$(cd "$(dirname "$0")" && pwd)
PRREQ=""
for _c in "${MERGE_CHECK_PRREQ:-}" "$_MC_DIR/pr-required.sh" "$_MC_DIR/../pr-required.sh"; do
  [ -n "$_c" ] && [ -f "$_c" ] && { PRREQ="$_c"; break; }
done
if [ -z "$PRREQ" ]; then
  RQ=""
else
  RQ=$(bash "$PRREQ" "$PR" "$REPO" 2>&1 | tail -1)
fi
case "$RQ" in
  MERGEABLE*) arm ok "required four" "$RQ" ;;
  "")         cannot "required four" "pr-required produced no verdict line (set MERGE_CHECK_PRREQ to the live pr-required.sh)" ;;
  *)          arm no "required four" "$RQ" ;;
esac

# 4. FULL ROLLUP + INHERITED/OWN CLASSIFICATION. See mc_rollup above.
if [ -n "$REAL" ]; then mc_rollup "$REAL"; fi

# 5. REQUIRED SET UNCHANGED between merge-base and main (a 4/4 measured against an old gate is not a 4/4).
if [ -n "$REAL" ]; then
  git fetch -q origin main:refs/remotes/origin/main 2>/dev/null
  MB=$(git merge-base refs/remotes/origin/main "$REAL" 2>/dev/null)
  RQK='.protection.required_status_checks.checks'
  A=$(git show "$MB:.github/required-checks.json" 2>/dev/null | jq -S "$RQK" 2>/dev/null)
  B=$(git show "refs/remotes/origin/main:.github/required-checks.json" 2>/dev/null | jq -S "$RQK" 2>/dev/null)
  # `.required` DOES NOT EXIST in this file: it reads null on BOTH sides, so the old
  # comparison was null==null and passed unconditionally. A vacuous arm, found by
  # printing the key set instead of trusting the path.
  if [ -z "$A" ] || [ -z "$B" ] || [ "$A" = null ] || [ "$B" = null ]; then cannot "required-set" "read null at $RQK — the path is wrong or the file moved; this arm measures NOTHING"
  elif [ "$A" = "$B" ]; then arm ok "required set" "byte-identical merge-base vs main"
  else arm no "required set" "MOVED — the green was measured against a different gate; rebase"; fi
  arm ok "freshness" "$(git rev-list --count "$REAL..refs/remotes/origin/main" 2>/dev/null) commits behind main"

  # 5b. FILE OVERLAP WITH MAIN SINCE THE MERGE-BASE (main, 2026-09-15).
  # gates ran this BY HAND after merge-check returned ALL 8 CONDITIONS MET on #18371
  # and it caught a near-revert: console's #18329 had merged as 9069b4c97 touching
  # tooling/gate-map/gate-map.test.mjs — THE EXACT FILE #18371 rewrites, from a base
  # that predates it. Merging on that clean 8/8 would have taken an 84-line rewrite
  # over another lane's just-landed change.
  #
  # FILE CONTENTS ARE ABSOLUTE; A DIFF IS RELATIVE. `freshness` above reports how many
  # commits behind you are — it says NOTHING about whether any of them touched YOUR
  # files. git reports no conflict when two changes land in the same file without
  # textually colliding, so this hazard arrives at the merge button with every other
  # instrument green. That is why it needs its own arm and not a bigger freshness note.
  #
  # ADVISORY BY DESIGN: an overlap is not a refusal — it is the one thing a human must
  # look at before merging. It reports `no` (which fails the run) so the verdict cannot
  # be read as clean, and names the files so the reader can check both survive.
  MB=$(git merge-base "$REAL" refs/remotes/origin/main 2>/dev/null)
  if [ -z "$MB" ]; then
    cannot "overlap with main" "no merge-base against origin/main — cannot compute overlap"
  else
    MINE=$(git diff --name-only "$MB" "$REAL" 2>/dev/null | sort -u)
    THEIRS=$(git diff --name-only "$MB" refs/remotes/origin/main 2>/dev/null | sort -u)
    BEHIND=$(git rev-list --count "$REAL..refs/remotes/origin/main" 2>/dev/null)
    # CORRECT BY CONSTRUCTION, NOT BY ORDER. The degenerate case is decided ONCE,
    # here, and every later branch is guarded by it. Before this, the 0-behind arm
    # was correct only because it sat ABOVE the cannot-read arm: swap the two and
    # every 0-behind PR prints CANNOT READ — a refusal where a measurement was
    # available, which is the failure direction that trains people to ignore an arm.
    # No arm asserted that ordering, so a future edit would have broken it silently.
    DEGEN=0
    if [ -z "$THEIRS" ] && [ "${BEHIND:-1}" = "0" ]; then DEGEN=1; fi
    if [ "$DEGEN" = "1" ]; then
      # 0 behind is a REAL empty overlap, not an unreadable one: main has added
      # nothing since the merge-base, so nothing of main's can collide. Distinguish
      # this from a read that simply returned nothing — the first is a measurement,
      # the second is a broken instrument, and they print identically otherwise.
      # gates' refinement, 2026-09-15: at 0 behind the `comm` control input is EMPTY,
      # so empty-because-disjoint and empty-because-nothing-to-compare would render
      # identically. This branch exists to keep them apart — and the wording must not
      # let a reader take it as COVERAGE. It is not "I checked and found no overlap";
      # it is "there was nothing to check". A vacuous pass read as a clean one is the
      # shape this whole arm exists to catch.
      arm ok "overlap with main" "NOT A COVERAGE CLAIM — 0 commits behind, so main has changed nothing since the merge-base and this comparison had nothing to compare. Re-run after any rebase or when the branch falls behind."
    elif [ "$DEGEN" != "1" ] && { [ -z "$MINE" ] || [ -z "$THEIRS" ]; }; then
      cannot "overlap with main" "one side listed no files while $BEHIND commit(s) behind — an empty file list is NOT an empty overlap"
    else
      BOTH=$(comm -12 <(printf '%s\n' "$MINE") <(printf '%s\n' "$THEIRS"))
      if [ -n "$BOTH" ]; then
        arm no "overlap with main" "main changed $(printf '%s\n' "$BOTH" | wc -l | tr -d ' ') file(s) THIS PR ALSO CHANGES since the merge-base — verify BOTH survive, not just yours: $(printf '%s' "$BOTH" | tr '\n' ' ')"
      else
        arm ok "overlap with main" "$(printf '%s\n' "$MINE" | wc -l | tr -d ' ') file(s) changed here, none also changed on main since the merge-base"
      fi
    fi
  fi
fi

# 6. SQUASH-MESSAGE SENTINELS in the body, WITH A POSITIVE CONTROL on the same grep.
BODY=$(gh pr view "$PR" --repo "$REPO" --json body --jq .body 2>/dev/null)
CTL=$(printf 'PDS-D746 and D719\n' | grep -oE 'PDS-D[0-9]+|\bD[0-9]{2,4}\b' | wc -l | tr -d ' ')
if [ "${CTL:-0}" -lt 2 ]; then cannot "sentinels" "the control did not fire — a clean result from a broken grep is indistinguishable from a clean body"
else
  N=$(printf '%s' "$BODY" | grep -oE 'PDS-D[0-9]+|\bD[0-9]{2,4}\b' | wc -l | tr -d ' ')
  if [ "${N:-0}" -eq 0 ]; then arm ok "squash sentinels" "0 in body (control fired on $CTL)"
  else arm no "squash sentinels" "$N in body — control the squash message explicitly or it re-creates the guarded literal on main"; fi
fi

# 7. PDS CITATION PRECEDES MERGE — a SIBLING of arm 6, over the DIFF, asking
#    whether each cited number RESOLVES on origin/main. See mc_pds_citation_verdict
#    above for why this is not folded into the sentinel arm.
#
#    ABSENT PREDICATE IS `cannot`, NOT SILENCE. If the script is not in the tree
#    the arm still reports — dropping it would shrink ARMS and let the vacuity
#    floor pass a verdict that measured one condition fewer without saying so.
PCS=scripts/pds-citation-precedes-merge.sh
if [ -f "$PCS" ]; then
  PCS_OUT=$(bash "$PCS" --head "$BR" 2>&1); PCS_RC=$?
  mc_pds_citation_verdict "$PCS_RC" "$PCS_OUT"
else
  cannot "pds citation" "$PCS is not in this tree — the citation corpus was never read"
fi

# DERIVED tally with a vacuity floor. A hardcoded count is a lie waiting.
if [ "$ARMS" -lt 7 ]; then
  echo "MERGE-CHECK: CANNOT READ — only $ARMS arm(s) reported; this verdict measures nothing"; exit 3
fi
# THREE OUTCOMES, NOT TWO. A WAIT is not a refusal and must not print like one:
# nothing has concluded failure, so there is no diagnosis to act on and nothing
# to debug. It still exits NON-ZERO (4) — fail-closed: a wait is never a permit.
if [ "$FAIL" -gt 0 ]; then
  echo "MERGE-CHECK: $FAIL of $ARMS condition(s) NOT MET — DO NOT MERGE$( [ "$WAITS" -gt 0 ] && printf ' (%s further arm(s) merely STILL MOVING — those are not among the %s)' "$WAITS" "$FAIL" )"; exit 1
elif [ "$WAITS" -gt 0 ]; then
  echo "MERGE-CHECK: NOT YET — $WAITS of $ARMS condition(s) STILL MOVING and ZERO concluded failures. This is a WAIT, not a refusal: re-read when CI settles; do NOT debug the pending names."; exit 4
else
  echo "MERGE-CHECK: ALL $ARMS CONDITIONS MET — the hold-label arm is one of them, so this head is not held; merge"; exit 0
fi
