#!/usr/bin/env bash
#
# main-red-owner.sh — GIVE A RED ON MAIN'S TIP AN OWNER.
#
# WHY A GITHUB ISSUE AND NOT ANOTHER RED CHECK. The defect this file answers
# (task-6005859f86872319) is an ADVISORY workflow that failed on main's tip for
# eleven hours across eight consecutive runs with nobody on it: a lane close-out
# reads its own PRs, never main's health, so an advisory red that cannot block a
# merge has NO OWNER BY CONSTRUCTION — and painting a NINTH advisory check red
# reproduces the disease exactly one layer out. An issue is the smallest artifact
# in this repo that has an assignee, a notification, a state a human must clear,
# and a place a lane's close-out can be told to look, so this tool converts the
# predicate's verdict into ONE deduped issue that it opens, keeps current, and
# CLOSES ITSELF when main goes green.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THE VERDICT COMES FROM scripts/main-red-predicate.sh, NOT FROM THIS FILE
# ─────────────────────────────────────────────────────────────────────────────
# That script already enumerates every workflow carrying a `push:` arm, asks per
# workflow (never from a windowed feed) for its most recent COMPLETED main run,
# and DESCENDS INTO JOBS so a `continue-on-error` run that launders a failing job
# into `success` is still counted red. It is the instrument; this file is the
# TRIGGER and the DELIVERY it never had. Nothing scheduled ran it, and a verdict
# printed into a terminal nobody opened is the same silence one command earlier.
#
# ─────────────────────────────────────────────────────────────────────────────
#  THIS RUN'S CONCLUSION MEANS "DELIVERY WORKED", NOT "MAIN IS GREEN"
# ─────────────────────────────────────────────────────────────────────────────
# Deliberate, and it is the whole argument above made mechanical: if a red on
# main made THIS job red, the mechanism would be one more unowned advisory red.
# So a successfully delivered red exits 0 and says so loudly in the step summary
# and the issue; the NON-ZERO exits are reserved for the states where ownership
# was NOT delivered:
#
#   0  delivered — issue opened / refreshed / closed, or there was nothing to say
#   3  usage
#   4  the predicate CANNOT READ its inputs. An issue is still raised (a blind
#      instrument is itself an unowned condition) and the run fails besides.
#   5  the issue API is unreadable or the write was refused: ownership could NOT
#      be delivered, so the run conclusion is the only channel left. FAILS CLOSED
#      — never "no reds" — because a zero-red report from a broken query is the
#      exact failure the predicate was written to stop.
#
# ─────────────────────────────────────────────────────────────────────────────
#  DEDUPE, AND WHY THE BODY CARRIES A MACHINE-READABLE RED SET
# ─────────────────────────────────────────────────────────────────────────────
# One issue at a time, found by EXACT TITLE among open issues (a title match
# survives a repo with no `main-red` label and a token that may not create one;
# the label is applied best-effort as a convenience for humans, never relied on).
# The body carries `<!-- main-red-owner REDSET: a.yml,b.yml -->`. Every run
# rewrites the body, so the issue is always current; a COMMENT — the thing that
# notifies — is posted only when the red SET CHANGES, so a red standing for a day
# produces one notification, not forty-eight. A new red joining an existing issue
# therefore still pages someone.
#
# NO PROCESS SUBSTITUTION IN THIS FILE, on purpose: it keeps the file out of
# scripts/posix-vacuous-green-census.sh's population. The interpreter guard is
# carried anyway, below, because `sh main-red-owner.sh` reaching the GitHub write
# path in POSIX mode is not a trade worth having.
#
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

# Shebang-independent interpreter guard. A shebang is not a guard: a caller
# running `sh scripts/main-red-owner.sh` never reads it.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "main-red-owner.sh: needs bash; run: bash scripts/main-red-owner.sh" >&2
  exit 3
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*) echo "main-red-owner.sh: refuses to run in POSIX mode" >&2; exit 3;;
esac

_MRO_SELF="${BASH_SOURCE[0]}"; case "$_MRO_SELF" in */*) _MRO_DIR="${_MRO_SELF%/*}";; *) _MRO_DIR=".";; esac
_MRO_DIR=$(cd "$_MRO_DIR" 2>/dev/null && pwd) || _MRO_DIR="."
_MRO_SELF="$_MRO_DIR/${_MRO_SELF##*/}"

TITLE="${MRO_TITLE:-[main-red] a workflow is red on the tip of main}"
LABEL="main-red"
PREDICATE="${MRO_PREDICATE:-$_MRO_DIR/main-red-predicate.sh}"
WORKFLOW_FILE="${MRO_WORKFLOW:-$_MRO_DIR/../.github/workflows/main-red-owner.yml}"

usage() {
  cat <<'USAGE'
usage: bash scripts/main-red-owner.sh [--selftest] [--dry-run] [owner/repo]

  (no args)   run the predicate against main's tip and give any red an OWNER:
              open / refresh one deduped GitHub issue, or close it when green.
  --dry-run   do everything except the issue writes; print what it would do.
  --selftest  hermetic arms with a stubbed gh and a stubbed predicate. No network.

exit: 0 delivered · 3 usage · 4 predicate CANNOT READ · 5 issue API refused
USAGE
}

# ── selftest ────────────────────────────────────────────────────────────────
# THE ARMS EXIST BECAUSE PRESENT-IN-FILE IS NOT FIRES-WHEN-IT-SHOULD. Two of
# them are the pair the brief demands: `mechanism reverted` (the scheduled
# trigger, the issues:write permission, or the invocation removed from the
# workflow file) must RED, and `main genuinely green` must stay QUIET — no
# create, no comment, exit 0. The rest pin the fail-closed edges, because a
# delivery tool that silently reports "no reds" when it could not read is the
# original defect wearing this file's name.
_mro_selftest() {
  local d fails=0 pass=0 out rc
  _ok(){ printf 'PASS %-30s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-30s %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

  if bash -n "$_MRO_SELF" 2>/dev/null; then _ok "parses" "bash -n clean"
  else _no "parses" "bash -n FAILED — file truncated or malformed"; fi
  for t in gh jq; do
    if command -v "$t" >/dev/null 2>&1; then _ok "dep $t" "$(command -v "$t")"
    else _no "dep $t" "NOT ON PATH"; fi
  done

  # ── THE MECHANISM-REVERTED ARM ────────────────────────────────────────────
  # A script nothing runs is the disease. These assertions red if the workflow
  # file loses its schedule, its manual arm, its issues:write token, or its call
  # to this script — i.e. if the trigger is reverted while the script survives.
  if [ -f "$WORKFLOW_FILE" ]; then
    local wf; wf=$(cat "$WORKFLOW_FILE")
    case "$wf" in *"schedule:"*) _ok "trigger: schedule" "cron arm present";;
      *) _no "trigger: schedule" "NO schedule: in $WORKFLOW_FILE — the level trigger is gone";; esac
    case "$wf" in *"workflow_dispatch:"*) _ok "trigger: dispatch" "manual arm present";;
      *) _no "trigger: dispatch" "NO workflow_dispatch: — cannot be taken on demand";; esac
    case "$wf" in *"issues: write"*) _ok "token: issues write" "the delivery scope is granted";;
      *) _no "token: issues write" "NO 'issues: write' — every issue write will 403";; esac
    case "$wf" in *"main-red-owner.sh"*) _ok "workflow calls this file" "invocation present";;
      *) _no "workflow calls this file" "the workflow no longer runs this script";; esac
    case "$wf" in *"--selftest"*) _ok "workflow runs the arms" "selftest wired into the job";;
      *) _no "workflow runs the arms" "nothing executes --selftest — these arms rot";; esac
  else
    _no "workflow file exists" "$WORKFLOW_FILE MISSING — the trigger has been reverted"
  fi

  d=$(mktemp -d) || { echo "SELFTEST: CANNOT READ — no tmpdir"; return 1; }
  mkdir -p "$d/bin"

  # A stubbed predicate. MRO_P_RC is its exit code, MRO_P_RED the red rows.
  cat > "$d/pred" <<'PSTUB'
#!/usr/bin/env bash
echo "control: run feed sees 12 distinct workflow names on main"
echo
if [ -n "${MRO_P_RED:-}" ]; then
  echo "RED ON MAIN (1):"
  echo "  $MRO_P_RED"
else
  echo "RED ON MAIN (0):"
  echo "  (none)"
fi
echo
echo "NO SUCCESS/FAILURE VERDICT ON MAIN — CANNOT READ, NOT GREEN (0):"
echo "  (none)"
echo
echo "branch-driven push workflows = 53 · red ${MRO_P_N:-0} · green 53 · unread 0 · n/a 2"
exit "${MRO_P_RC:-0}"
PSTUB
  chmod +x "$d/pred"

  # A stubbed gh. MRO_G_OPEN=<number> pretends an issue is already open;
  # MRO_G_DEAD makes the issue LIST unreadable; MRO_G_WFAIL makes every WRITE
  # fail. Every call is appended to $MRO_G_LOG so an arm can assert what was
  # NOT called — the quiet arm is worthless without that.
  cat > "$d/bin/gh" <<'GSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MRO_G_LOG:-/dev/null}"
case " $* " in
  *" issue list "*)
    [ -n "${MRO_G_DEAD:-}" ] && { echo "HTTP 503" >&2; exit 1; }
    if [ -n "${MRO_G_OPEN:-}" ]; then
      printf '[{"number":%s,"title":"%s"}]\n' "$MRO_G_OPEN" "${MRO_TITLE:-[main-red] a workflow is red on the tip of main}"
    else echo '[]'; fi
    exit 0;;
  *" issue view "*)
    printf '%s\n' "${MRO_G_BODY:-stale body<!-- main-red-owner REDSET: OLD.yml -->}"
    exit 0;;
  *" issue create "*|*" issue edit "*|*" issue comment "*|*" issue close "*)
    [ -n "${MRO_G_WFAIL:-}" ] && { echo "HTTP 403" >&2; exit 1; }
    echo "https://github.com/acme/widget/issues/${MRO_G_OPEN:-99}"; exit 0;;
  *" label "*) exit 0;;
  *" api "*) echo "deadbeefcafe"; exit 0;;
esac
exit 0
GSTUB
  chmod +x "$d/bin/gh"

  _arm(){ # label RED N PRC OPEN DEAD WFAIL want-exit needle [forbidden-in-ghlog]
    local lbl="$1" red="$2" n="$3" prc="$4" open="$5" dead="$6" wfail="$7" wrc="$8" need="$9" bad="${10:-}"
    local log="$d/ghlog"; : > "$log"
    out=$(PATH="$d/bin:$PATH" MRO_PREDICATE="$d/pred" MRO_G_LOG="$log" \
          MRO_P_RED="$red" MRO_P_N="$n" MRO_P_RC="$prc" MRO_G_OPEN="$open" \
          MRO_G_DEAD="$dead" MRO_G_WFAIL="$wfail" \
          bash "$_MRO_SELF" acme/widget 2>&1); rc=$?
    if [ "$rc" != "$wrc" ]; then _no "$lbl" "exit=$rc (want $wrc) | $(printf '%s\n' "$out" | tail -1)"; return; fi
    case "$out" in *"$need"*) : ;; *) _no "$lbl" "output lacks [$need] | $(printf '%s\n' "$out"|tail -1)"; return;; esac
    if [ -n "$bad" ] && grep -q -- "$bad" "$log" 2>/dev/null; then
      _no "$lbl" "gh was called with the FORBIDDEN [$bad]"; return
    fi
    _ok "$lbl" "$(printf '%s\n' "$out" | tail -1)"
  }

  # A RED GETS AN OWNER: no issue open -> one is CREATED.
  _arm "red opens an issue"      "failure abc123 x posix-vacuous-green-census.yml" 1 1 "" "" "" 0 "OPENED issue"
  # DEDUPE: an issue already open -> refreshed, never a second one created.
  _arm "red dedupes to one issue" "failure abc123 x posix-vacuous-green-census.yml" 1 1 77 "" "" 0 "REFRESHED issue #77" "issue create"
  # THE QUIET ARM: main genuinely green -> no create, no comment, no close, exit 0.
  _arm "green stays quiet"        "" 0 0 "" "" "" 0 "no reds on main's tip" "issue create"
  # SELF-CLEARING: green while an issue stands -> it is CLOSED, so a stale issue
  # cannot become the next thing nobody owns.
  _arm "green closes the issue"   "" 0 0 77 "" "" 0 "CLOSED issue #77"
  # FAILS CLOSED 1: the issue list is unreadable -> refuse, never "no reds".
  _arm "dead issue API refuses"   "failure abc123 x foo.yml" 1 1 "" 1 "" 5 "CANNOT READ" "issue create"
  # FAILS CLOSED 2: the predicate itself cannot read -> an issue is still raised
  # AND the run fails. A blind instrument is its own unowned condition.
  _arm "predicate blind is loud"  "" 0 4 "" "" "" 4 "CANNOT READ"
  # FAILS CLOSED 3: the write is refused -> ownership was NOT delivered, so the
  # run conclusion is the only channel left and it must be red.
  _arm "refused write is loud"    "failure abc123 x foo.yml" 1 1 "" "" 1 5 "COULD NOT DELIVER"
  # NOTIFY ONLY ON CHANGE: the stub body carries REDSET: OLD.yml, so a different
  # red set must COMMENT; an unchanged set must not.
  local log="$d/ghlog"; : > "$log"
  out=$(PATH="$d/bin:$PATH" MRO_PREDICATE="$d/pred" MRO_G_LOG="$log" \
        MRO_P_RED="failure abc123 x NEW.yml" MRO_P_N=1 MRO_P_RC=1 MRO_G_OPEN=77 \
        bash "$_MRO_SELF" acme/widget 2>&1)
  if grep -q "issue comment" "$log"; then _ok "changed red set notifies" "comment posted"
  else _no "changed red set notifies" "no comment for a CHANGED red set"; fi
  : > "$log"
  out=$(PATH="$d/bin:$PATH" MRO_PREDICATE="$d/pred" MRO_G_LOG="$log" \
        MRO_G_BODY='x<!-- main-red-owner REDSET: SAME.yml -->' \
        MRO_P_RED="failure abc123 x SAME.yml" MRO_P_N=1 MRO_P_RC=1 MRO_G_OPEN=77 \
        bash "$_MRO_SELF" acme/widget 2>&1)
  if grep -q "issue comment" "$log"; then _no "unchanged set stays silent" "commented on an UNCHANGED red set — 48 pages a day"
  else _ok "unchanged set stays silent" "body refreshed, no comment"; fi

  rm -rf "$d"
  local total=$((pass+fails))
  if [ "$total" -lt 12 ]; then echo "SELFTEST: CANNOT READ — only $total arm(s) ran; this tally measures nothing"; return 1; fi
  [ "$fails" = 0 ] && { echo "SELFTEST: $pass/$total arms pass"; return 0; }
  echo "SELFTEST: $fails of $total arm(s) FAILED"; return 1
}

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) _mro_selftest; exit $?;;
    --dry-run)  DRY=1; shift;;
    -h|--help)  usage; exit 0;;
    -*)         usage >&2; exit 3;;
    *)          break;;
  esac
done

REPO="${1:-${GITHUB_REPOSITORY:-FRIKKern/barkpark}}"

[ -x "$PREDICATE" ] || [ -f "$PREDICATE" ] || {
  echo "CANNOT READ: no predicate at $PREDICATE — refusing to report on main's health"; exit 4; }

OUT=$(bash "$PREDICATE" "$REPO" 2>&1); PRC=$?
echo "$OUT"
echo
echo "── main-red-owner: predicate exit=$PRC ──"

# The red rows: everything between the RED header and the next section header.
REDS=$(printf '%s\n' "$OUT" | awk '/^RED ON MAIN \(/{f=1;next} /^NO SUCCESS\/FAILURE/{f=0} f' \
       | sed 's/^  *//' | grep -v '^(none)$' | grep -v '^$')
# The workflow basenames, for the dedupe key. A red row ends with the basename
# (possibly followed by a bracketed laundering annotation), so take the field
# that looks like a workflow file.
REDSET=$(printf '%s\n' "$REDS" | grep -o '[A-Za-z0-9_.-]*\.ya*ml' | sort -u | tr '\n' ',' | sed 's/,$//')

_gh_issue_number() {
  local js n
  js=$(gh issue list --repo "$REPO" --state open --limit 100 --json number,title 2>&1) || return 1
  printf '%s' "$js" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  n=$(printf '%s' "$js" | jq -r --arg t "$TITLE" '[.[]|select(.title==$t)|.number]|first // empty')
  printf '%s' "$n"
}

NUM=$(_gh_issue_number); LRC=$?
if [ "$LRC" != 0 ]; then
  echo "CANNOT READ: the issue list for $REPO is unreadable — refusing to report a clean main." >&2
  echo "CANNOT READ: ownership could not be delivered." >&2
  exit 5
fi

BODYFILE=$(mktemp)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$PRC" = 4 ]; then
  {
    echo "**scripts/main-red-predicate.sh CANNOT READ its inputs** as of \`$NOW\`."
    echo
    echo "A blind instrument is an unowned condition in its own right: while this stands,"
    echo "nothing in this repo can tell you whether main's tip is green."
    echo
    echo '```'
    printf '%s\n' "$OUT" | tail -30
    echo '```'
    echo
    echo "<!-- main-red-owner REDSET: CANNOT-READ -->"
  } > "$BODYFILE"
  NEWSET="CANNOT-READ"
  WANT=open
elif [ "$PRC" = 1 ] && [ -n "$REDS" ]; then
  {
    echo "**Red on main's tip** as of \`$NOW\` (repo \`$REPO\`)."
    echo
    echo "These workflows' most recent COMPLETED run on \`main\` concluded failure —"
    echo "read at JOB level, so a \`continue-on-error\` run that laundered a failing job"
    echo "into \`success\` is counted red here."
    echo
    printf '%s\n' "$REDS" | sed 's/^/- `/; s/$/`/'
    echo
    echo "**An advisory red has no owner by construction.** It cannot block a merge, so no"
    echo "PR surfaces it and no lane close-out reads it; the incident that produced this"
    echo "mechanism (\`task-6005859f86872319\`) stood for 11 hours across 8 consecutive main"
    echo "runs. **This issue is the owner.** Assign it, fix the red, and it closes itself on"
    echo "the next run once main's tip is green."
    echo
    echo "Reproduce locally: \`bash scripts/main-red-predicate.sh $REPO\`"
    echo "Raised by \`scripts/main-red-owner.sh\` via \`.github/workflows/main-red-owner.yml\`."
    echo
    echo "<!-- main-red-owner REDSET: $REDSET -->"
  } > "$BODYFILE"
  NEWSET="$REDSET"
  WANT=open
else
  NEWSET=""
  WANT=close
fi

if [ "$WANT" = close ]; then
  if [ -n "$NUM" ]; then
    if [ "$DRY" = 1 ]; then echo "DRY-RUN: would have CLOSED issue #$NUM"
    else
      if gh issue close "$NUM" --repo "$REPO" \
           --comment "main's tip is green as of \`$NOW\` — \`scripts/main-red-owner.sh\` closing this automatically." >/dev/null 2>&1; then
        echo "CLOSED issue #$NUM — no reds on main's tip"
      else
        echo "COULD NOT DELIVER: issue #$NUM could not be closed" >&2; rm -f "$BODYFILE"; exit 5
      fi
    fi
  else
    echo "no reds on main's tip, and no issue stands. Nothing to own."
  fi
  rm -f "$BODYFILE"
  [ "$PRC" = 4 ] && exit 4
  exit 0
fi

# best-effort: the label is a convenience for humans, never the dedupe key.
gh label create "$LABEL" --repo "$REPO" --color B60205 \
   --description "main's tip is red and this is its owner" >/dev/null 2>&1

if [ "$DRY" = 1 ]; then
  echo "DRY-RUN: would have ${NUM:+REFRESHED issue #$NUM}${NUM:-OPENED an issue} with REDSET=$NEWSET"
  sed 's/^/  | /' "$BODYFILE"; rm -f "$BODYFILE"
  [ "$PRC" = 4 ] && exit 4
  exit 0
fi

if [ -z "$NUM" ]; then
  URL=$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODYFILE" --label "$LABEL" 2>&1) \
    || URL=$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODYFILE" 2>&1)
  if [ $? != 0 ]; then
    echo "COULD NOT DELIVER: issue create refused: $URL" >&2; rm -f "$BODYFILE"; exit 5
  fi
  echo "OPENED issue for the red on main's tip: $URL"
else
  OLD=$(gh issue view "$NUM" --repo "$REPO" --json body -q .body 2>/dev/null)
  OLDSET=$(printf '%s' "$OLD" | grep -o 'main-red-owner REDSET: [^-]*' | sed 's/main-red-owner REDSET: //' | sed 's/ *$//')
  if ! gh issue edit "$NUM" --repo "$REPO" --body-file "$BODYFILE" >/dev/null 2>&1; then
    echo "COULD NOT DELIVER: issue #$NUM could not be refreshed" >&2; rm -f "$BODYFILE"; exit 5
  fi
  echo "REFRESHED issue #$NUM (redset: $NEWSET)"
  if [ "$OLDSET" != "$NEWSET" ]; then
    gh issue comment "$NUM" --repo "$REPO" \
      --body "The red set on main's tip CHANGED at \`$NOW\`: was \`${OLDSET:-unknown}\`, now \`$NEWSET\`." >/dev/null 2>&1 \
      && echo "commented: red set changed (${OLDSET:-unknown} -> $NEWSET)"
  fi
fi
rm -f "$BODYFILE"
[ "$PRC" = 4 ] && exit 4
exit 0
