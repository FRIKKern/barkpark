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
  && grep -qF 'STALE FEED' "$_MRP_SELF" \
  && grep -qF '2H PREDICATE' "$_MRP_SELF" \
  && grep -qF 'streak=' "$_MRP_SELF" \
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
  *"actions/workflows/"*"/runs"*)
    # THE AUTHORITATIVE FRESHNESS SOURCE. MRP_AUTHTS drives the newest main run's
    # timestamp; the default matches the verdict row, i.e. NO lag. MRP_TC drives
    # total_count, which the unread arm reads off this same response.
    printf '{"total_count":%s,"workflow_runs":[{"id":4242,"created_at":"%s"}]}\n' \
      "${MRP_TC:-7}" "${MRP_AUTHTS:-2026-01-01T00:00:00Z}"
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
    _VERDROW='{"conclusion":"'"${MRP_CONC:-failure}"'","headSha":"abcdef1234567890","createdAt":"'"${MRP_TS:-2026-01-01T00:00:00Z}"'","status":"completed"'"$_ID"'}'
    # MRP_CANC=two adds a SECOND, OLDER verdict row (MRP_OLD) behind the first.
    # This is web-fork-drift.yml's real shape and the only one that can tell
    # "newest verdict wins" apart from "any verdict behind the cancel wins".
    _OLDROW='{"conclusion":"'"${MRP_OLD:-failure}"'","headSha":"0123456789abcdef","createdAt":"2025-12-01T00:00:00Z","status":"completed"'"$_ID"'}'
    # MRP_STALE_ONCE: serve a stale page ONCE (per workflow is not distinguishable
    # here, so once per stub process tree via a marker file), then fresh. This is
    # the only way to exercise the retry: a stateless stub can express "always
    # stale" and "never stale" but not "stale then fixed", which is the actual
    # shape of the live fault.
    if [ -n "${MRP_STALE_ONCE:-}" ]; then
      if [ ! -f "$MRP_STALE_ONCE" ]; then : > "$MRP_STALE_ONCE"
        printf '[{"conclusion":"success","headSha":"0000000000000000","createdAt":"2026-01-01T00:00:00Z","status":"completed","databaseId":9}]\n'
        exit 0
      fi
    fi
    case "${MRP_CANC:-}" in
      only) printf '[%s]\n' "$_CANCROW";;
      two)  printf '[%s,%s,%s]\n' "$_CANCROW" "$_VERDROW" "$_OLDROW";;
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
          MRP_CANC="${MRP_CANC_ARM:-}" MRP_OLD="${MRP_OLD_ARM:-}" \
          MRP_AUTHTS="${MRP_AUTHTS_ARM:-}" MRP_TS="${MRP_TS_ARM:-}" \
          MRP_STALE_ONCE="${MRP_STALE_ONCE_ARM:-}" bash "$_MRP_SELF" acme/widget 2>&1); rc=$?
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
  # ── NEWEST VERDICT WINS, NOT "ANY VERDICT BEHIND THE CANCEL" (gates-r20b, 2026-09-16) ──
  # web-fork-drift.yml's real main feed is cancel / success(newest) / ... / failure(older).
  # EVERY cancel arm above carries exactly ONE verdict row behind the cancel, so all of them
  # pass unchanged under a selector that reaches past the newest verdict to an older one --
  # which would report web-fork-drift RED off a 2026-09-03 failure that thirteen later
  # successes have already superseded. These two arms are the pair that discriminates: the
  # SAME two rows, order swapped, must reach OPPOSITE verdicts. One alone proves nothing
  # (a selector hard-wired to "green" passes the first; one hard-wired to "red" passes the
  # second); it is the disagreement between them that pins the ordering.
  MRP_CANC_ARM=two MRP_OLD_ARM=failure _arm "newest success outranks an older failure" many success "" "" 0 "red 0 · green"
  MRP_CANC_ARM=two MRP_OLD_ARM=success _arm "newest failure outranks an older success" many failure "" "" 1 "RED ON MAIN"
  # ── THE FRESHNESS ARMS (gates-r21-w6, 2026-09-17, task-0a48c7b64d5ab0f1) ────
  # REPRODUCED LIVE, twice, before these were written: `gh run list
  # --workflow=elixir.yml --branch main --limit 50` served a page whose newest row
  # was 2026-08-23T16:53Z while the REST endpoint, queried seconds later, served
  # 2026-09-17T08:37Z. The same command repeated 3/3 immediately after returned
  # today's rows. Nothing in the stale response says it is stale, so without this
  # control a 25-day-old run is published as the CURRENT state of main — which is
  # exactly what happened to elixir.yml in the r21 lane brief.
  #
  # THE DISCRIMINATING PAIR. One arm alone proves nothing: a rule that refused
  # EVERY feed would pass the stale arm and be useless, and a rule that refused
  # NONE would pass the race arm. It is their disagreement that pins the
  # threshold. SAME inputs, only the authority's timestamp moves.
  #   stale (25 days of lag) -> no verdict taken, bucketed unread, exit 2
  #   race  (10 min of lag)  -> the verdict still stands, RED ON MAIN, exit 1
  # NO `forbidden` HERE: the script prints the literal header "RED ON MAIN (0):"
  # on every invocation, so a forbidden-string check on it fires over the tool's
  # own prose rather than over behaviour (the same trap the cancel arms document).
  # The exit code carries "no red was manufactured", and the arm below states it
  # positively off the summary line.
  MRP_AUTHTS_ARM=2026-09-17T08:37:00Z _arm "a stale feed yields no verdict" many failure "" "" 2 "STALE FEED"
  MRP_AUTHTS_ARM=2026-09-17T08:37:00Z _arm "a stale feed manufactures no red" many failure "" "" 2 "red 0 · green 0"
  MRP_AUTHTS_ARM=2026-01-01T00:10:00Z _arm "a seconds-scale race still reports" many failure "" "" 1 "RED ON MAIN"
  # ...and the stale row must NAME both timestamps, or the refusal is unactionable.
  MRP_AUTHTS_ARM=2026-09-17T08:37:00Z _arm "the stale row names both clocks" many failure "" "" 2 "authoritative REST newest is 2026-09-17T08:37:00Z"
  # THE RETRY. A page that is stale ONCE and fresh on the re-read must yield a
  # verdict, not a refusal — otherwise the control converts an intermittent API
  # fault into permanent unread debt for a handful of workflows every sweep.
  # Paired with the always-stale arm above: same control, opposite outcomes,
  # and only the retry distinguishes them.
  MRP_STALE_ONCE_ARM="$d/staleonce" MRP_AUTHTS_ARM=2026-09-17T08:37:00Z MRP_TS_ARM=2026-09-17T08:37:00Z \
    _arm "a feed stale ONCE is re-read, not refused" many failure "" "" 1 "RED ON MAIN" "STALE FEED"
  # ── THE 2H AGE ARMS (c0's actual predicate) ────────────────────────────────
  # A bare red set cannot answer "red for more than 2 hours". These two arms are
  # the pair: the SAME failing run, only its age moves, must reach OPPOSITE
  # readings of the 2H PREDICATE line.
  _arm "an ancient red is OVER-2H" many failure "" "" 1 "OVER-2H"
  MRP_TS_ARM="$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=9)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
    _arm "a nine-minute red is not OVER-2H" many failure "" "" 1 "under-2h" "OVER-2H"
  # ...and a young red must NOT falsify the 2h predicate, or every merge reds it.
  MRP_TS_ARM="$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=9)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
    _arm "a young red leaves the 2h predicate TRUE" many failure "" "" 1 "2H PREDICATE: TRUE"
  # ...while an ancient one falsifies it. Without this the arm above is satisfied
  # by a predicate line hard-wired to TRUE.
  _arm "an ancient red falsifies the 2h predicate" many failure "" "" 1 "2H PREDICATE: FALSE"
  # UNREAD IS NOT A PASS. A workflow with no readable verdict has no measurable
  # age, so the predicate must refuse rather than report TRUE over its silence.
  MRP_CANC_ARM=only _arm "unread leaves the 2h predicate CANNOT READ" many failure "" "" 2 "2H PREDICATE: CANNOT READ"

  # ── THE RED-STREAK ARMS (gates-r21f-w4) ────────────────────────────────────
  # THE FAULT: the age used to come off the NEWEST run, so a push-triggered
  # workflow that reds on every push reset the clock on every merge and could be
  # red for hours while reporting `age=0h4m under-2h`. The age must be the
  # elapsed time since the workflow last SUCCEEDED.
  # These arms are a PAIR over MRP_OLD: the newest failure is nine minutes old in
  # BOTH, and only what sits behind it moves. If the age still came off the
  # newest run, both would read under-2h and the pair would be indistinguishable.
  _MRP_YOUNG="$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(minutes=9)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
  # FIRES WHEN THE FIX IS REVERTED: a young red with an OLDER failure behind it
  # (no success between) is an unbroken streak reaching back to 2025-12-01.
  MRP_CANC_ARM=two MRP_OLD_ARM=failure MRP_TS_ARM="$_MRP_YOUNG" \
    _arm "a young red on an OLD streak is OVER-2H" many failure "" "" 1 "OVER-2H" "under-2h"
  MRP_CANC_ARM=two MRP_OLD_ARM=failure MRP_TS_ARM="$_MRP_YOUNG" \
    _arm "an old streak falsifies the 2h predicate" many failure "" "" 1 "2H PREDICATE: FALSE"
  # ...and the streak must be NAMED, not just folded into the age, or the lead
  # cannot tell a long streak from a slow clock.
  MRP_CANC_ARM=two MRP_OLD_ARM=failure MRP_TS_ARM="$_MRP_YOUNG" \
    _arm "the streak length and start are printed" many failure "" "" 1 "streak=2x since=2025-12-01"
  # THE QUIET ARM: the SAME young red, but a SUCCESS sits behind it. The streak is
  # one run long, so this is a merge landing, not standing debt — it must stay
  # under-2h and leave the predicate TRUE. Without this arm the fix above is
  # satisfied by an age hard-wired to the oldest row in the window.
  MRP_CANC_ARM=two MRP_OLD_ARM=success MRP_TS_ARM="$_MRP_YOUNG" \
    _arm "a young red behind a SUCCESS stays under-2h" many failure "" "" 1 "under-2h" "OVER-2H"
  MRP_CANC_ARM=two MRP_OLD_ARM=success MRP_TS_ARM="$_MRP_YOUNG" \
    _arm "a one-run streak leaves the 2h predicate TRUE" many failure "" "" 1 "2H PREDICATE: TRUE"
  MRP_CANC_ARM=two MRP_OLD_ARM=success MRP_TS_ARM="$_MRP_YOUNG" \
    _arm "a one-run streak is named as 1x" many failure "" "" 1 "streak=1x"
  # A WINDOW WITH NO SUCCESS AT ALL IS A FLOOR, AND MUST SAY SO. Otherwise a
  # workflow red for a month reads as red only as far back as the 50-run page.
  MRP_TS_ARM="$_MRP_YOUNG" \
    _arm "an all-red window is marked FLOOR" many failure "" "" 1 "FLOOR(no success in the 50-run window)"

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
red=0; green=0; unseen=0; total=0; na=0; over2h=0
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
  # WHY web-fork-drift's CANCEL IS NOT A CONCURRENCY EVICTION -- measured
  # 2026-09-16 by gates-r20b (task-690e90b601f5b276), because the sentence above
  # sits under a main-collapse heading and a reader will otherwise apply the
  # main-collapse remedy to a workflow that does not have that disease:
  #   * web-fork-drift.yml is NOT one of the main-collapse workflows
  #     (`grep -l 'main-collapse: harness-ok' .github/workflows/*.yml` does not
  #     list it), and its main concurrency group has been PER-SHA since #15730
  #     landed 2026-09-03 -- ten days BEFORE the cancel. A per-sha group cannot
  #     evict itself.
  #   * At head d58a0985, 24 of the 27 workflow runs on main were cancelled
  #     within one second of each other -- architecture, ci, doc-gates, js-tests,
  #     twoslash and nineteen more, in unrelated concurrency groups. Concurrency
  #     is per-group and cannot cross workflow files, so this was a repo-wide
  #     mass cancel of one sha, not an eviction. Changing any concurrency group
  #     would have fixed nothing.
  # The defect was in THIS SELECTOR, not in web-fork-drift.yml, and #18556 fixed
  # it: the workflow now reads GREEN off its 2026-09-12T11:39Z success, annotated
  # with the destroyed verdict it stepped over.
  # So: the verdict is the newest run that actually CONCLUDED one. Cancelled,
  # skipped, neutral and action_required are NOT verdicts; they are skipped over,
  # and the fact that they were is ANNOTATED, never silently swallowed. A feed
  # containing ONLY non-verdicts still reads CANNOT READ — the absence is real
  # there. The limit is 50, not 20, because a collapse storm can cancel more than
  # 20 consecutive runs of one workflow.
  WFEED=$(gh run list --repo "$REPO" --workflow="$BASE" --branch main --limit 50 \
          --json conclusion,headSha,createdAt,status,databaseId 2>/dev/null)
  # ── FRESHNESS CONTROL: THE FEED ITSELF CAN BE STALE ────────────────────────
  # FOUND 2026-09-17 by gates-r21-w6 (task-0a48c7b64d5ab0f1), REPRODUCED LIVE.
  # `gh run list --workflow=elixir.yml --branch main --limit 50` returned a page
  # whose NEWEST row was 2026-08-23T16:53Z — TWENTY-FIVE DAYS OLD — while the
  # authoritative REST endpoint, queried seconds later, returned runs from
  # 2026-09-17T08:37Z. The SAME command repeated 3/3 immediately afterwards
  # returned today's rows. It is intermittent and it is SILENT: nothing in the
  # response says "this page is stale".
  #
  # WHAT THAT COST. On that stale page the newest completed rows were Aug-23
  # cancels; the selector stepped over 43 of them, landed on 7c57c7d52
  # (2026-08-23T14:21:58Z, RUN=success), descended to its jobs, found the
  # ADVISORY `Format` job red, and reported elixir.yml RED ON MAIN. The lead's
  # 08:30:32Z run of this file reported exactly that row. A twenty-five-day-old
  # run was published as the CURRENT state of main, and every downstream reader
  # — the hourly main-red-owner issue, the r21 lane brief, this row's own c0 —
  # inherited it. The workflow was never red; the INSTRUMENT was.
  #
  # THE CONTROL. Read the workflow's newest main run from the authoritative REST
  # endpoint and compare its timestamp against the feed's newest row. A genuine
  # race between the two calls is SECONDS; the observed fault was 25 DAYS. More
  # than one hour of daylight between them means the feed is stale, and a stale
  # feed yields NO VERDICT — it is bucketed CANNOT READ, where debt accrues, and
  # is NEVER reported red. Reporting a months-old run as today's red is strictly
  # worse than reporting nothing, because it is indistinguishable from a real red.
  #
  # ASYMMETRIC ON PURPOSE: only the feed lagging the authority is a fault. The
  # authority lagging the feed is the harmless direction (our feed is ahead), and
  # is not flagged.
  RETRIED=""
  AUTHROW=$(gh api "repos/$REPO/actions/workflows/$BASE/runs?branch=main&per_page=1" 2>/dev/null)
  AUTH_TS=$(printf '%s' "$AUTHROW" | jq -r '.workflow_runs[0].created_at // empty' 2>/dev/null)
  FEED_TS=$(printf '%s' "$WFEED" | jq -r 'sort_by(.createdAt)|reverse|.[0].createdAt // empty' 2>/dev/null)
  if [ -n "$AUTH_TS" ] && [ -n "$FEED_TS" ]; then
    # jq, not python3: this runs once per workflow (55x per invocation) and the
    # selftest runs the whole sweep ~22 times, so a python3 spawn here costs
    # minutes. `fromdateiso8601` is exact for the Z-suffixed stamps GitHub emits.
    LAG=$(jq -n --arg a "$AUTH_TS" --arg f "$FEED_TS" \
          '(($a|fromdateiso8601) - ($f|fromdateiso8601))|floor' 2>/dev/null)
    # RETRY ONCE BEFORE GIVING UP. MEASURED 2026-09-17T08:50Z on the live repo:
    # three workflows tripped this control in a SINGLE sweep — mobile.yml (13
    # days of lag), required-checks-drift.yml (12 days), crown-reconcile.yml
    # (4 hours). The fault is not a rare one-off, so refusing on first sight
    # would park a handful of workflows in the unread bucket on most runs and
    # bury the real debt under noise. The stale page is intermittent, so one
    # fresh request usually clears it. If the SECOND read is also stale we stop
    # and refuse — a retry loop that keeps asking until it likes the answer is
    # how an instrument talks itself into a verdict.
    if [ -n "$LAG" ] && [ "$LAG" -gt 3600 ] 2>/dev/null; then
      WFEED=$(gh run list --repo "$REPO" --workflow="$BASE" --branch main --limit 50 \
              --json conclusion,headSha,createdAt,status,databaseId 2>/dev/null)
      FEED_TS=$(printf '%s' "$WFEED" | jq -r 'sort_by(.createdAt)|reverse|.[0].createdAt // empty' 2>/dev/null)
      LAG=$(jq -n --arg a "$AUTH_TS" --arg f "${FEED_TS:-1970-01-01T00:00:00Z}" \
            '(($a|fromdateiso8601) - ($f|fromdateiso8601))|floor' 2>/dev/null)
      RETRIED=" (re-read once; still stale)"
    fi
    if [ -n "$LAG" ] && [ "$LAG" -gt 3600 ] 2>/dev/null; then
      unseen=$((unseen+1))
      printf '%s\tSTALE FEED — no verdict taken: run-list newest is %s but the authoritative REST newest is %s (%ss of lag). A stale page is NOT a verdict.\n' \
        "$BASE" "$FEED_TS" "$AUTH_TS" "$LAG${RETRIED:-}" >> "$UNSEEN_LIST"
      continue
    fi
  fi
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
    TC=$(printf '%s' "$AUTHROW" | jq -r '.total_count // empty' 2>/dev/null)
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
      # AGE IS PART OF THE VERDICT (task-0a48c7b64d5ab0f1 c0). "No workflow has
      # been red on its newest completed run for more than 2 hours" cannot be
      # evaluated from a bare red set: a red four minutes old is a merge landing,
      # a red four hours old is an unowned standing failure. Emit the age so the
      # 2h predicate is READ OFF THIS OUTPUT rather than recomputed by every
      # consumer. Printed even when the age cannot be computed, as `age=?`, so an
      # unreadable clock is never silently rendered as a young red.
      # THE AGE OF WHAT, THOUGH -- see the streak block immediately below.
      # ── THE AGE IS THE RED STREAK, NOT THE LATEST RUN ────────────────────────
      # FOUND 2026-09-18 (gates-r21f-w4). This block used to age `$WHEN`, the
      # createdAt of the NEWEST run. For a push-triggered workflow that reds on
      # EVERY push, every merge to main starts a fresh run, so the clock RESET on
      # each merge and the 2h predicate could never trip no matter how long the
      # workflow had been broken.
      # SPECIMEN: `stale-verdict-watch` reported `age=0h4m under-2h` while it had
      # been red continuously since 22:17:43Z — ~3h20m, ~17 consecutive failures,
      # ZERO greens in between. `cli-release-cadence` and `doc-gates` carry the
      # same exposure. Only a rare-trigger workflow (`scaffy-catalog-drift`,
      # 8h45m) ever accumulated age under the old logic — i.e. the predicate
      # measured TRIGGER FREQUENCY and called it health.
      # THE FIX: age the UNBROKEN RED STREAK — walk the verdict rows newest-first
      # and stop at the first `success`; the oldest row before that success is
      # when the workflow last worked. The 2h threshold is UNCHANGED.
      # TWO DELIBERATE FLOORS, both annotated rather than hidden:
      #   * the streak is walked on RUN conclusions only. A laundered green
      #     (RUN=success over a failing job) inside the streak ends the walk
      #     early, so the streak is a floor, never an overcount. Descending jobs
      #     for 50 rows x 55 workflows is not affordable here.
      #   * if the whole 50-row window is red with no success, the streak reaches
      #     only as far back as the window and is marked FLOOR.
      STREAK_JSON=$(printf '%s' "$WFEED" | jq -c '
        [.[]|select(.status=="completed" and (.conclusion|IN("success","failure","timed_out","startup_failure")))]
        | sort_by(.createdAt) | reverse
        | (map(.conclusion=="success")|index(true)) as $i
        | (if $i == null then . else .[0:$i] end) as $streak
        | {truncated: ($i == null), n: ($streak|length), oldest: ($streak[-1].createdAt // null)}' 2>/dev/null)
      STREAK_WHEN=$(printf '%s' "$STREAK_JSON" | jq -r '.oldest // empty' 2>/dev/null)
      STREAK_N=$(printf '%s' "$STREAK_JSON" | jq -r '.n // empty' 2>/dev/null)
      # FAIL TOWARD THE OLD READING, NOT TOWARD SILENCE: an unreadable streak
      # falls back to the newest run's own timestamp, which is what this block
      # did before. It can only ever UNDER-report age, never invent one.
      [ -n "$STREAK_WHEN" ] || { STREAK_WHEN="$WHEN"; STREAK_N="${STREAK_N:-1}"; }
      STREAK=" streak=${STREAK_N:-1}x since=${STREAK_WHEN}"
      if [ "$(printf '%s' "$STREAK_JSON" | jq -r '.truncated' 2>/dev/null)" = "true" ]; then
        STREAK="$STREAK FLOOR(no success in the 50-run window)"
      fi
      AGE_S=$(jq -n --arg w "$STREAK_WHEN" '(now - ($w|fromdateiso8601))|floor' 2>/dev/null)
      if [ -n "$AGE_S" ] && [ "$AGE_S" -ge 0 ] 2>/dev/null; then
        AGE_H=$(( AGE_S / 3600 )); AGE_M=$(( (AGE_S % 3600) / 60 ))
        if [ "$AGE_S" -gt 7200 ]; then AGE=" age=${AGE_H}h${AGE_M}m OVER-2H"; over2h=$((over2h+1))
        else AGE=" age=${AGE_H}h${AGE_M}m under-2h"; fi
      else
        AGE=" age=? UNREADABLE-CLOCK"; over2h=$((over2h+1))
      fi
      red=$((red+1)); printf '%s\t%s\t%s\t%s%s%s%s%s\n' "$CONC" "$SHA" "$WHEN" "$BASE" "$AGE" "$STREAK" "$LAUNDERED" "$EVICTED" >> "$RED_LIST";;
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
# THE 2H PREDICATE, STATED AS A LINE A WATCHER CAN GREP. An unread workflow is
# NOT a pass: it is a workflow whose age we could not measure, so it can never
# satisfy "has not been red for more than 2 hours".
if [ "$over2h" -gt 0 ]; then
  echo "2H PREDICATE: FALSE -- $over2h workflow(s) red for more than 2 hours (or with an unreadable clock)"
elif [ "$unseen" -gt 0 ]; then
  echo "2H PREDICATE: CANNOT READ -- $unseen workflow(s) have no readable verdict; absence is not a pass"
else
  echo "2H PREDICATE: TRUE -- 0 of $total branch-driven push workflows red for more than 2 hours"
fi
if [ "$total" -lt 5 ]; then
  echo "CANNOT READ: only $total workflow(s) carried a push: arm — this measures nothing"; exit 4
fi
rm -f "$RED_LIST" "$UNSEEN_LIST"
[ "$red" -gt 0 ] && exit 1
[ "$unseen" -gt 0 ] && exit 2
exit 0
