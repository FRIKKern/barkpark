#!/usr/bin/env bash
# main-red-predicate.sh — WHAT IS RED ON MAIN, BY PREDICATE, NOT BY MEMORY.
#
# WHY THIS EXISTS. Main's previous ledger re-ran THE SCRIPTS IT ALREADY KNEW
# ABOUT and called the result "main's red ledger". That instrument can only
# confirm or clear a KNOWN red; it is structurally incapable of finding a new
# one. gates found `gate-map.test.mjs` failing on pristine main — invisible to
# all four instruments main was running, because its workflow is paths-filtered
# and HAS NO COMPLETED RUN ON MAIN AT ALL. A red that cannot be observed on the
# branch it is red on.
#
# THE PREDICATE: enumerate every workflow carrying a `push:` arm, then ask GitHub
# for its most recent COMPLETED run on main. Three buckets, and the third is the
# point:
#     RED         a completed main run concluded failure
#     GREEN       a completed main run concluded success
#     CANNOT READ no completed main run exists  <-- NOT green. Debt accrues here.
#
# FAILS CLOSED. An unreadable workflow list, or an unreadable run feed, refuses
# rather than reporting an empty red set. A zero-red verdict from a broken query
# is the exact failure this file exists to stop.
#
# CONTROL, run every invocation: the run feed must return MORE THAN ONE distinct
# workflow name. A feed that sees one thing cannot discriminate, and its silence
# about the other 40 is not evidence.
set -uo pipefail
# --------------------------------------------------------- SMOKE SELFTEST (no network) -------
# ADDED WHEN THIS FILE WAS VENDORED (2026-09-16). Everything below the selftest is the r19
# scratchpad tool verbatim. A vendored file that nothing executes rots silently, so
# `main-red-predicate.sh --selftest` proves WITHOUT ONE NETWORK CALL that the file is not
# truncated, that its FOUR interpreters exist (bash, gh, jq AND python3 — the tags-only
# partition is a python3 heredoc, and a missing python3 would silently mis-bucket every
# workflow), and that the verdicts that matter still discriminate.
#
# THE ARM THAT EARNS ITS KEEP IS "laundered run counted red". The job descent added on
# 2026-09-16 exists because a RUN conclusion launders a failing job: continue-on-error makes
# the run read `success` while a job inside it reads `failure`. The FIRST draft of that descent
# was VACUOUS — it keyed on `.databaseId` while the `gh run list --json` projection did not ASK
# for databaseId, so it would have printed "job descent NOT performed" for every workflow
# forever while looking like a fix. That arm reds if the descent cannot fire, and the
# "no-databaseId is loud" arm pins the branch that made the vacuity visible in the first place.
# A fix that cannot fire is the same disease one layer out, so it gets its own assertion.
_MRP_SELF="${BASH_SOURCE[0]}"; case "$_MRP_SELF" in */*) _MRP_DIR="${_MRP_SELF%/*}";; *) _MRP_DIR=".";; esac
_MRP_DIR=$(cd "$_MRP_DIR" 2>/dev/null && pwd) || _MRP_DIR="."
_MRP_SELF="$_MRP_DIR/${_MRP_SELF##*/}"

_mrp_selftest() {
  local d fails=0 pass=0 out rc
  _ok(){ printf 'PASS %-28s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-28s %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

  if bash -n "$_MRP_SELF" 2>/dev/null; then _ok "parses" "bash -n clean"
  else _no "parses" "bash -n FAILED — file truncated or malformed"; fi
  if grep -qF 'CANNOT READ: run feed shows' "$_MRP_SELF" \
  && grep -qF 'branch-driven push workflows' "$_MRP_SELF"; then _ok "not truncated" "control text + summary line both present"
  else _no "not truncated" "a load-bearing line is missing — file truncated"; fi
  # THE DESCENT MUST BE ABLE TO FIRE. The run-list projection must ASK for databaseId, or the
  # descent keys on a field that is never delivered and silently degrades to a run-level read.
  if grep -q 'json conclusion,headSha,createdAt,status,databaseId' "$_MRP_SELF" \
  && grep -q 'actions/runs/\$RID/jobs' "$_MRP_SELF"; then _ok "descent can fire" "databaseId requested AND runs/<id>/jobs called"
  else _no "descent can fire" "the job descent cannot fire — databaseId not requested, or no runs/<id>/jobs call"; fi
  for t in gh jq python3 git; do
    if command -v "$t" >/dev/null 2>&1; then _ok "dep $t" "$(command -v "$t")"
    else _no "dep $t" "NOT ON PATH — this tool cannot run correctly"; fi
  done

  d=$(mktemp -d) || { echo "SELFTEST: CANNOT READ — no tmpdir"; return 1; }
  mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
# MRP_FEED drives the discrimination CONTROL, MRP_CONC the per-workflow RUN conclusion,
# MRP_FJOB the name of a FAILING JOB inside that run (empty = no failing job), and
# MRP_NOID drops databaseId from the run row to exercise the loud no-descent branch.
# Nothing here reaches the network. The /jobs arm must come FIRST.
case " $* " in
  *"/jobs"*)
    if [ -n "${MRP_FJOB:-}" ]; then printf '{"jobs":[{"name":"%s","conclusion":"failure"}]}\n' "$MRP_FJOB"
    else printf '{"jobs":[{"name":"fine","conclusion":"success"}]}\n'; fi
    exit 0;;
  *"--json name"*)
    case "${MRP_FEED:-many}" in
      dead) exit 1;;
      one)  echo '[{"name":"only-one"}]'; exit 0;;
      *)    echo '[{"name":"a"},{"name":"b"},{"name":"c"}]'; exit 0;;
    esac;;
  *"--json conclusion,headSha,createdAt,status"*)
    # MRP_CANC=1 prepends a NEWER cancelled row in front of the verdict row (the
    # main-collapse shape: a merge evicts the pending run, destroying its verdict
    # while older, genuine verdicts sit right behind it). MRP_CANC=only emits a
    # feed of nothing BUT cancels, which must still read CANNOT READ.
    if [ -n "${MRP_NOID:-}" ]; then _ID=""; else _ID=',"databaseId":4242'; fi
    _CANCROW='{"conclusion":"cancelled","headSha":"cccccccccccccccc","createdAt":"2026-02-02T00:00:00Z","status":"completed"'"$_ID"'}'
    _VERDROW='{"conclusion":"'"${MRP_CONC:-failure}"'","headSha":"abcdef1234567890","createdAt":"2026-01-01T00:00:00Z","status":"completed"'"$_ID"'}'
    case "${MRP_CANC:-}" in
      only) printf '[%s]\n' "$_CANCROW";;
      ?*)   printf '[%s,%s]\n' "$_CANCROW" "$_VERDROW";;
      *)    printf '[%s]\n' "$_VERDROW";;
    esac
    exit 0;;
esac
exit 1
STUB
  chmod +x "$d/bin/gh"

  _arm(){ # label FEED CONC FJOB NOID want-exit needle [forbidden]
    local lbl="$1" feed="$2" conc="$3" fjob="$4" noid="$5" wrc="$6" need="$7" bad="${8:-}"
    out=$(PATH="$d/bin:$PATH" MRP_FEED="$feed" MRP_CONC="$conc" MRP_FJOB="$fjob" MRP_NOID="$noid" \
          MRP_CANC="${MRP_CANC_ARM:-}" bash "$_MRP_SELF" acme/widget 2>&1); rc=$?
    if [ "$rc" != "$wrc" ]; then _no "$lbl" "exit=$rc (want $wrc) | $(printf '%s\n' "$out" | tail -1)"; return; fi
    case "$out" in *"$need"*) : ;; *) _no "$lbl" "output lacks [$need]"; return;; esac
    if [ -n "$bad" ]; then case "$out" in *"$bad"*) _no "$lbl" "output CONTAINS the forbidden [$bad]"; return;; esac; fi
    _ok "$lbl" "$(printf '%s\n' "$out" | grep -m1 'branch-driven push workflows' || printf '%s\n' "$out" | tail -1)"
  }
  # FAIL CLOSED. A feed that cannot discriminate must refuse, never report "no reds".
  _arm "one-name feed refuses" one  failure ""  "" 4 "cannot discriminate" "RED ON MAIN"
  _arm "dead feed refuses"     dead failure ""  "" 4 "CANNOT READ"         "RED ON MAIN"
  # CLASSIFIES. Red and green must reach DIFFERENT verdicts, or neither measured anything.
  _arm "reds are reported"     many failure ""  "" 1 "RED ON MAIN"
  _arm "greens are not reds"   many success ""  "" 0 "red 0"               "RUN said success"
  # THE DESCENT. A run that says success while a job inside it failed must be counted RED and
  # ANNOTATED with what the run claimed, or the laundering is invisible again.
  _arm "laundered run counted red" many success "Spec drift (advisory)" "" 1 "RUN said success; FAILING JOB(S): Spec drift (advisory)"
  # THE VACUITY GUARD. With no databaseId the descent cannot run and the tool annotates the
  # row "job descent NOT performed". HISTORY, kept because it is the reason these arms exist:
  # when this file was vendored (PR #18469) that annotation was emitted ONLY from the
  # failure|timed_out|startup_failure arm -- the `success)` arm incremented green and printed
  # nothing. So an UNDESCENDED row that read `success` was counted GREEN with the warning
  # DISCARDED, silent on precisely the class where a missing descent can hide a laundered red.
  # MEASURED in both directions before the fix: NOID+success -> green 53, exit 0, annotation
  # count 0; NOID+failure -> 53 emissions. The vendoring arm was therefore deliberately
  # NARROW ("loud on reds"), because widening the label without widening the code would be an
  # assertion certifying a gap it never measured. THE CODE IS NOW WIDENED, so the assertions
  # are too -- both directions, plus a noise control.
  _arm "no-databaseId loud on reds"    many failure ""  1 1 "job descent NOT performed"
  _arm "no-databaseId loud on GREENS"  many success ""  1 0 "UNDESCENDED-GREEN"
  # THE NOISE CONTROL, and it is what makes the arm above mean something: when the descent DID
  # run, a green must stay SILENT. Without this, a rule that shouted UNDESCENDED-GREEN on every
  # green would pass the arm above and be useless.
  _arm "descended green stays silent"  many success ""  "" 0 "red 0" "UNDESCENDED-GREEN"
  # ── THE MAIN-COLLAPSE ARMS (gates-r20, task-9ee58a247b158826) ───────────────
  # A CANCELLED newest run is a DESTROYED verdict. Before this fix the selector
  # took the newest row with ANY conclusion, so `cancelled` won and the workflow
  # was bucketed CANNOT READ — which is how shell-harnesses.yml sat RED on main
  # for 11 consecutive completed runs, unseen by this instrument.
  # ARM THAT REDS WHEN THE FIX IS REVERTED: a cancelled row NEWER than a failure
  # must still report RED ON MAIN (exit 1). Under the old selector this returned
  # exit 2 with "CANNOT READ", so reverting the selector fails this arm.
  # THE NEEDLES ON THESE ARMS ARE COUNT-FREE ON PURPOSE. An earlier draft pinned the
  # literal "red 54 · green 0 · unread 0" and went stale INSIDE ITS OWN COMMIT: this PR
  # adds .github/workflows/main-collapse-gates.yml, a branch-driven push workflow, so
  # the denominator moved 54 -> 55 and both cancel arms failed against the very tree
  # that introduced them. What the arm actually asserts is "unread 0" -- every workflow
  # reached a verdict THROUGH the cancel -- which the pre-fix selector could not
  # produce (it bucketed all of them unread and exited non-zero).
  # NO `forbidden` ARGUMENT ON THESE ARMS: the predicate's own prose prints the
  # literals "RED ON MAIN" and "CANNOT READ" on every invocation, so a forbidden-string
  # check on either fires unconditionally and the arm would fail over its own
  # documentation rather than over behaviour. The exit code carries that half.
  MRP_CANC_ARM=1 _arm "red behind a cancel is seen" many failure "" "" 1 "green 0 · unread 0"
  # ...and it must SAY that it stepped over one, or the skip is silent.
  MRP_CANC_ARM=1 _arm "the skipped cancel is named" many failure "" "" 1 "DESTROYED VERDICT"
  # THE QUIET ARM: a cancelled row in front of a genuine SUCCESS is still green,
  # and must not manufacture a red. (Without this, "call everything behind a
  # cancel red" would pass the arm above and be worse than the bug.)
  MRP_CANC_ARM=1 _arm "green behind a cancel stays green" many success "" "" 0 "red 0 · green"
  # ...and it must still have READ every verdict. Split from the arm above because
  # unread rows are not reds: an assertion that only says "red 0" passes over a run
  # in which nothing was measured at all.
  MRP_CANC_ARM=1 _arm "green behind a cancel reads every verdict" many success "" "" 0 "· unread 0"
  # THE ABSENCE MUST SURVIVE: a feed of nothing but cancels has no verdict at
  # all and must still refuse — this is the case where CANNOT READ is TRUE.
  MRP_CANC_ARM=only _arm "cancels only still refuses" many failure "" "" 2 "verdicts were DESTROYED, not missing"
  # The tags-only partition must fire against this repo's real workflows.
  out=$(PATH="$d/bin:$PATH" MRP_FEED=many MRP_CONC=success MRP_FJOB= MRP_NOID= bash "$_MRP_SELF" acme/widget 2>&1)
  case "$out" in
    *"tags-only push arm"*) _ok "tags-only partition" "$(printf '%s\n' "$out" | grep -m1 'branch-driven push workflows')" ;;
    *) _no "tags-only partition" "no tags-only workflow was partitioned — the python3 arm is not firing" ;;
  esac
  rm -rf "$d"
  local total=$((pass+fails))
  if [ "$total" -lt 15 ]; then echo "SELFTEST: CANNOT READ — only $total arm(s) ran; this tally measures nothing"; return 1; fi
  [ "$fails" = 0 ] && { echo "SELFTEST: $pass/$total arms pass"; return 0; }
  echo "SELFTEST: $fails of $total arm(s) FAILED"; return 1
}
[ "${1:-}" = "--selftest" ] && { _mrp_selftest; exit $?; }

REPO="${1:-FRIKKern/barkpark}"
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 4

WF_DIR=.github/workflows
[ -d "$WF_DIR" ] || { echo "CANNOT READ: no $WF_DIR"; exit 4; }

# --- CONTROL 1: the run feed sees more than one workflow -----------------------
# NOTE, MEASURED 2026-09-15: a 200-row completed-main feed reaches back only
# ~49 MINUTES on this repo. An earlier version of this script bucketed "absent
# from that feed" as "no completed main run" — WHICH IS FALSE. `bp-graph-drift`
# was absent from the window and has a SUCCESS from 2026-09-13. That is the
# enumeration-read-as-a-predicate fault, committed inside the tool written to
# cure it. The feed is now used ONLY as a discrimination control; every verdict
# comes from a PER-WORKFLOW query, which is not windowed.
FEED=$(gh run list --repo "$REPO" --branch main --status completed --limit 200 --json name 2>&1)
if [ -z "$FEED" ] || ! printf '%s' "$FEED" | jq -e 'type=="array"' >/dev/null 2>&1; then
  echo "CANNOT READ: main run feed unreadable — refusing to report a red set"; exit 4
fi
DISTINCT=$(printf '%s' "$FEED" | jq -r '[.[].name]|unique|length')
if [ "${DISTINCT:-0}" -lt 2 ]; then
  echo "CANNOT READ: run feed shows $DISTINCT distinct workflow name(s) — cannot discriminate"; exit 4
fi
echo "control: run feed sees $DISTINCT distinct workflow names on main"

# --- enumerate workflows carrying a push: arm ----------------------------------
red=0; green=0; unseen=0; total=0; na=0
RED_LIST=$(mktemp); UNSEEN_LIST=$(mktemp); NA_LIST=$(mktemp)
for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*push:' "$f" || continue
  # TAGS-ONLY PUSH ARMS ARE NOT BRANCH-DRIVEN (cli, 2026-09-15). A `push:` arm whose
  # only key is `tags:` MATCHES this grep while being STRUCTURALLY INCAPABLE of a main
  # run — so an earlier version reported them as "no completed main run", i.e. as debt.
  # Measured: 53 workflows carry `branches:`, exactly 2 are tags-only
  # (cli-release.yml, release.yml), 0 are bare. CONTROL: the branches count is non-zero,
  # so the partition discriminates. Report these as N/A, never as unread.
  if python3 - "$f" <<'PYEOF'
import sys,re
lines=open(sys.argv[1]).read().split("\n")
pi=next((i for i,l in enumerate(lines) if re.match(r"^\s*push:\s*(#.*)?$", l)), None)
if pi is None: sys.exit(1)
ind=len(lines[pi])-len(lines[pi].lstrip()); keys=set()
for l in lines[pi+1:]:
    if not l.strip() or l.lstrip().startswith("#"): continue
    if len(l)-len(l.lstrip())<=ind: break
    if ":" in l: keys.add(l.strip().split(":")[0])
sys.exit(0 if ("tags" in keys and not {"branches","branches-ignore"} & keys) else 1)
PYEOF
  then
    na=$((na+1)); printf '%s\ttags-only push arm — NOT branch-driven, a main run is impossible\n' "$(basename "$f")" >> "$NA_LIST"
    continue
  fi
  total=$((total+1))
  BASE=$(basename "$f")
  # PER-WORKFLOW, NOT WINDOWED. Take the most recent run with a real conclusion:
  # an in-progress run has conclusion null and must never be read as a verdict.
  # ── A CANCELLED NEWEST RUN IS A DESTROYED VERDICT, NOT A VERDICT ───────────
  # FOUND 2026-09-16 by gates-r20 (task-9ee58a247b158826). The five main-collapse
  # workflows (grep -l 'main-collapse: harness-ok' .github/workflows/*.yml) put
  # every main push in ONE concurrency group, so each merge EVICTS the pending
  # intermediate: the newest row on main is very often `completed/cancelled`.
  # This selector used to take the newest row with ANY non-null conclusion, so a
  # cancel landed in the `*)` arm and the workflow was bucketed CANNOT READ.
  # SPECIMENS, both measured the morning this was fixed:
  #   shell-harnesses.yml  newest 4 rows cancelled, and behind them ELEVEN
  #                        consecutive `failure` runs back to 2026-09-15T11:38Z
  #                        — a main red this instrument could not see.
  #   web-fork-drift.yml   newest row cancelled 2026-09-13T15:58Z, with 13
  #                        successes and one failure behind it.
  # So: the verdict is the newest run that actually CONCLUDED one. Cancelled,
  # skipped, neutral and action_required are NOT verdicts; they are skipped over,
  # and the fact that they were is ANNOTATED, never silently swallowed. A feed
  # containing ONLY non-verdicts still reads CANNOT READ — the absence is real
  # there. The limit is 50, not 20, because a collapse storm can cancel more than
  # 20 consecutive runs of one workflow.
  WFEED=$(gh run list --repo "$REPO" --workflow="$BASE" --branch main --limit 50 \
          --json conclusion,headSha,createdAt,status,databaseId 2>/dev/null)
  ROW=$(printf '%s' "$WFEED" \
        | jq -r '[.[]|select(.status=="completed" and (.conclusion|IN("success","failure","timed_out","startup_failure")))]
                 | sort_by(.createdAt) | reverse | .[0] // empty')
  NEWEST=$(printf '%s' "$WFEED" \
        | jq -r '[.[]|select(.status=="completed" and .conclusion!=null and .conclusion!="")]
                 | sort_by(.createdAt) | reverse | .[0].conclusion // empty')
  SKIPPED=$(printf '%s' "$WFEED" \
        | jq -r '[.[]|select(.status=="completed" and .conclusion!=null and .conclusion!=""
                             and (.conclusion|IN("success","failure","timed_out","startup_failure")|not))]|length' 2>/dev/null)
  EVICTED=""
  if [ -n "$NEWEST" ] && [ "$NEWEST" != "success" ] && [ "$NEWEST" != "failure" ] \
     && [ "$NEWEST" != "timed_out" ] && [ "$NEWEST" != "startup_failure" ]; then
    EVICTED=" [newest completed main run was $NEWEST — a DESTROYED VERDICT, not a verdict; ${SKIPPED:-?} non-verdict row(s) skipped to reach the run below]"
  fi
  if [ -z "$ROW" ]; then
    # No run ever CONCLUDED a verdict on main. Distinguish structural absence (no
    # run was created) from destroyed verdicts (runs exist, all cancelled), the
    # same way the `*)` arm used to.
    TC=$(gh api "repos/$REPO/actions/workflows/$BASE/runs?branch=main&per_page=1" --jq '.total_count' 2>/dev/null)
    CN=$(printf '%s' "$WFEED" | jq -r '[.[]|select(.conclusion=="cancelled")]|length' 2>/dev/null)
    unseen=$((unseen+1))
    if [ "${CN:-0}" -gt 0 ] 2>/dev/null; then
      # LOCAL EVIDENCE OUTRANKS total_count: we are HOLDING cancelled rows for
      # this workflow, so runs demonstrably exist even if the count query failed.
      printf '%s\tno main run ever concluded a VERDICT — %s cancelled row(s) in the last 50 (total %s on main): verdicts were DESTROYED, not missing\n' \
        "$BASE" "$CN" "${TC:-?}" >> "$UNSEEN_LIST"
    elif [ "${TC:-0}" = "0" ]; then
      printf '%s\tno completed main run EVER — and total_count=0: NO MAIN RUN WAS EVER CREATED (structural)\n' "$BASE" >> "$UNSEEN_LIST"
    else
      printf '%s\tno main run ever concluded a VERDICT — runs EXIST (total %s on main, %s cancelled in the last 50): verdicts were DESTROYED, not missing\n' \
        "$BASE" "${TC:-?}" "${CN:-?}" >> "$UNSEEN_LIST"
    fi
    continue
  fi
  # (the unread annotation below uses cli's discriminator — see the *: arm)
  CONC=$(printf '%s' "$ROW" | jq -r '.conclusion'); SHA=$(printf '%s' "$ROW" | jq -r '.headSha[0:9]')
  WHEN=$(printf '%s' "$ROW" | jq -r '.createdAt')
  # ── DESCEND TO JOBS. A RUN CONCLUSION LAUNDERS A FAILING JOB. ──────────────
  # Found 2026-09-15 by gates, after vendoring this file put it in front of the
  # repo's own run-level-reader census, which refused it BY NAME.
  # Job-level `continue-on-error: true` launders the RUN conclusion and
  # `needs.<job>.result` — it does NOT launder the job or its check run.
  # SPECIMEN, 3 of 3 on required-checks-drift.yml:
  #   run 34968620058 / 34964650694 / 34964615333  RUN=success
  #   failing job each time: "Required-check spec drift (advisory)"
  # So every count this file produced before today was a FLOOR, not a count.
  # THE IRONY ON THE RECORD: "read JOBS, not runs" was written into the round's
  # brief while the instrument producing every main-red count read runs.
  # Nobody looked, because it was the thing doing the looking.
  RID=$(printf '%s' "$ROW" | jq -r '.databaseId // empty')
  if [ -n "$RID" ]; then
    FJOBS=$(gh api "repos/$REPO/actions/runs/$RID/jobs" --paginate 2>/dev/null \
      | jq -s -r '[.[].jobs[]?|select(.conclusion=="failure")|.name]|join(", ")')
    if [ -n "$FJOBS" ] && [ "$CONC" = "success" ]; then
      CONC="failure"; LAUNDERED=" [RUN said success; FAILING JOB(S): $FJOBS]"
    else
      LAUNDERED=""
    fi
  else
    LAUNDERED=" [no databaseId — job descent NOT performed, this row is RUN-LEVEL ONLY]"
  fi
  case "$CONC" in
    failure|timed_out|startup_failure)
      red=$((red+1)); printf '%s\t%s\t%s\t%s%s%s\n' "$CONC" "$SHA" "$WHEN" "$BASE" "$LAUNDERED" "$EVICTED" >> "$RED_LIST";;
    success)
      # THE NO-DESCENT WARNING MUST FIRE ON GREEN TOO. Found by gates-r19-w11 while
      # vendoring this file, measured with a control: NOID+success -> green 53, exit 0,
      # annotation count 0; NOID+failure -> 53 emissions. The annotation exists to say
      # "this row is RUN-LEVEL ONLY", and it was emitted from the RED arm alone -- so it
      # was SILENT ON EXACTLY THE CLASS IT EXISTS FOR: an undescended row that reads
      # GREEN is precisely the one that might be laundering a failing job.
      # A WARNING THAT ONLY FIRES WHEN YOU WERE ALREADY GOING TO LOOK IS NOT A WARNING.
      # The verdict is deliberately NOT changed -- an undescended green is not a red,
      # it is an UNMEASURED green, and it belongs in the unseen list where debt accrues.
      green=$((green+1))
      case "$LAUNDERED" in
        *"NOT performed"*)
          printf 'UNDESCENDED-GREEN\t%s\t%s\t%s%s%s\n' "$SHA" "$WHEN" "$BASE" "$LAUNDERED" "$EVICTED" >> "$UNSEEN_LIST";;
      esac;;
    *) # UNREACHABLE BY CONSTRUCTION: the selector above admits only the four
       # verdict conclusions. If this fires, the selector and this case have
       # drifted apart — refuse loudly rather than bucket the row somewhere.
       echo "CANNOT READ: $BASE selected a non-verdict conclusion '$CONC' — selector/case drift"; exit 4;;
  esac
done

echo
echo "RED ON MAIN ($red):"
[ -s "$RED_LIST" ] && sort "$RED_LIST" | sed 's/^/  /' || echo "  (none)"
echo
echo "NO SUCCESS/FAILURE VERDICT ON MAIN — CANNOT READ, NOT GREEN ($unseen):"
[ -s "$UNSEEN_LIST" ] && sort "$UNSEEN_LIST" | sed 's/^/  /' || echo "  (none)"
echo
echo
echo "N/A — TAGS-ONLY push arm, a main run is structurally impossible ($na):"
[ -s "$NA_LIST" ] && sort "$NA_LIST" | sed 's/^/  /' || echo "  (none)"
echo
echo "branch-driven push workflows = $total · red $red · green $green · unread $unseen · n/a $na"
if [ "$total" -lt 5 ]; then
  echo "CANNOT READ: only $total workflow(s) carried a push: arm — this measures nothing"; exit 4
fi
rm -f "$RED_LIST" "$UNSEEN_LIST"
[ "$red" -gt 0 ] && exit 1
[ "$unseen" -gt 0 ] && exit 2
exit 0
