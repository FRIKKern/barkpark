#!/usr/bin/env bash
# required4.sh <pr> [owner/repo] — the required four, BY NAME, PRESENCE FIRST.
#
# WHY THIS EXISTS. Main spent the whole round reading the required four with:
#     [.statusCheckRollup[]|select(.name==<one of four>)|.conclusion] | join(",")
# That COUNTS ROWS, IT DOES NOT CHECK NAMES. On #18322 it printed
# "SUCCESS,SUCCESS,SUCCESS,SUCCESS" from TWO `PR references an active task` rows
# plus Cloud and Console — while `Elixir gate` HAD RENDERED NO ROW AT ALL.
# Main reported "#18322 IS 4/4" and told the lane its PR was ready. It was 3/4.
#
# That is console's "assert presence before status" and gates' 8th merge-check arm,
# committed by main in its own monitoring command AFTER logging the rule twice.
# The remedy is not to remember it. It is this file.
#
# THREE STATES, NOT TWO — a row that RENDERED but has NOT CONCLUDED is a WAIT.
#   ABSENT    no row at all              -> not a pass
#   PENDING   a row, no conclusion yet   -> a wait; nothing has failed
#   CONCLUDED a verdict                  -> green or not
# v1 folded PENDING into "not all green", the same collapse console corrected in
# this tool author own reading of #18329. (No apostrophes below this line inside the
# jq program: one in a comment closed the single quote and broke the whole script.)
#
# TWO DISTINCT FAILURES, and only one of them is visible as a wrong conclusion:
#   ABSENT   the aggregate has not rendered (its `needs` have not completed).
#            An absence is NOT a pass.
#   STALE    a superseded row from an earlier attempt. An old SUCCESS is as
#            misleading as an old FAILURE — and MORE dangerous, because it points
#            at the merge button. Dedupe newest-per-name AND check existence.
set -uo pipefail
# --------------------------------------------------------- SMOKE SELFTEST (no network) -------
# ADDED WHEN THIS FILE WAS VENDORED (2026-09-16). Everything else in this file is the r19
# scratchpad tool verbatim. A vendored file that nothing executes rots silently, so
# `required4.sh --selftest` proves WITHOUT ONE NETWORK CALL that the file is not truncated,
# that its interpreter and helpers exist, and that the fault this tool was WRITTEN for still
# cannot get past it: on #18322 a row-COUNTING read printed SUCCESS,SUCCESS,SUCCESS,SUCCESS
# from TWO `PR references an active task` rows while `Elixir gate` had rendered NO ROW AT ALL.
# Arm "dup rows never make 4/4" replays exactly that rollup. Arm "all four green" is its
# CONTROL: without it a tool that refused everything would pass the arm that matters.
_R4_SELF="${BASH_SOURCE[0]}"; case "$_R4_SELF" in */*) _R4_DIR="${_R4_SELF%/*}";; *) _R4_DIR=".";; esac
_R4_DIR=$(cd "$_R4_DIR" 2>/dev/null && pwd) || _R4_DIR="."
_R4_SELF="$_R4_DIR/${_R4_SELF##*/}"

_r4_selftest() {
  local d fails=0 pass=0 out rc row
  _ok(){ printf 'PASS %-26s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
  _no(){ printf 'FAIL %-26s %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

  if bash -n "$_R4_SELF" 2>/dev/null; then _ok "parses" "bash -n clean"
  else _no "parses" "bash -n FAILED — file truncated or malformed"; fi
  if grep -qF 'ABSENT — no row rendered; an absence is NOT a pass' "$_R4_SELF" \
  && grep -qF 'probe_absent "$@"' "$_R4_SELF"; then _ok "not truncated" "presence-first text + absent-probe call both present"
  else _no "not truncated" "a load-bearing line is missing — file truncated"; fi
  for t in gh jq; do
    if command -v "$t" >/dev/null 2>&1; then _ok "dep $t" "$(command -v "$t")"
    else _no "dep $t" "NOT ON PATH — this tool cannot run at all"; fi
  done

  d=$(mktemp -d) || { echo "SELFTEST: CANNOT READ — no tmpdir"; return 1; }
  mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Only the rollup read answers. Every other call (probe_absent's headRefOid/headRefName,
# gh run list) exits 1, so probe_absent returns early and NOTHING here touches the network.
[ -n "${R4_DEAD:-}" ] && exit 1
case " $* " in *statusCheckRollup*) cat "$R4_FIX"; exit 0;; esac
exit 1
STUB
  chmod +x "$d/bin/gh"
  _row(){ printf '{"name":"%s","status":"%s","conclusion":"%s","startedAt":"2026-01-01T00:00:0%s Z"}' "$1" "$2" "$3" "${4:-0}"; }
  # A: all four rendered, concluded, SUCCESS.
  printf '{"statusCheckRollup":[%s,%s,%s,%s]}' \
    "$(_row 'Cloud gate' COMPLETED SUCCESS)" "$(_row 'Console gate' COMPLETED SUCCESS)" \
    "$(_row 'Elixir gate' COMPLETED SUCCESS)" "$(_row 'PR references an active task' COMPLETED SUCCESS)" > "$d/a.json"
  # B: THE #18322 SHAPE — Elixir gate absent, the task gate rendered TWICE. Four SUCCESS rows.
  printf '{"statusCheckRollup":[%s,%s,%s,%s]}' \
    "$(_row 'Cloud gate' COMPLETED SUCCESS)" "$(_row 'Console gate' COMPLETED SUCCESS)" \
    "$(_row 'PR references an active task' COMPLETED SUCCESS 1)" \
    "$(_row 'PR references an active task' COMPLETED SUCCESS 2)" > "$d/b.json"
  # C: a row that RENDERED but has NOT CONCLUDED is a WAIT, never a failure.
  printf '{"statusCheckRollup":[%s,%s,%s,%s]}' \
    "$(_row 'Cloud gate' IN_PROGRESS '')" "$(_row 'Console gate' COMPLETED SUCCESS)" \
    "$(_row 'Elixir gate' COMPLETED SUCCESS)" "$(_row 'PR references an active task' COMPLETED SUCCESS)" > "$d/c.json"

  _arm(){ # label fixture want-exit needle [forbidden-needle]
    local lbl="$1" fix="$2" wrc="$3" need="$4" bad="${5:-}"
    out=$(cd "$d" && PATH="$d/bin:$PATH" R4_FIX="$fix" bash "$_R4_SELF" 42 acme/widget 2>&1); rc=$?
    if [ "$rc" != "$wrc" ]; then _no "$lbl" "exit=$rc (want $wrc)"; return; fi
    case "$out" in *"$need"*) : ;; *) _no "$lbl" "output lacks [$need]"; return;; esac
    if [ -n "$bad" ]; then case "$out" in *"$bad"*) _no "$lbl" "output CONTAINS the forbidden [$bad]"; return;; esac; fi
    _ok "$lbl" "$(printf '%s\n' "$out" | grep -m1 '^VERDICT')"
  }
  _arm "all four green"        "$d/a.json" 0 "VERDICT: 4/4"
  _arm "dup rows never make 4/4" "$d/b.json" 1 "Elixir gate: ABSENT" "VERDICT: 4/4"
  _arm "pending is not failing" "$d/c.json" 1 "Cloud gate: PENDING" "VERDICT: 4/4"
  # Fail-closed: an unreadable rollup must REFUSE, never render a count it did not measure.
  out=$(cd "$d" && PATH="$d/bin:$PATH" R4_DEAD=1 bash "$_R4_SELF" 42 acme/widget 2>&1); rc=$?
  case "$rc:$out" in
    3:*"CANNOT READ"*) _ok "unreadable refuses" "exit=3 CANNOT READ" ;;
    *) _no "unreadable refuses" "exit=$rc — a dead read must refuse, not count" ;;
  esac
  rm -rf "$d"
  local total=$((pass+fails))
  if [ "$total" -lt 8 ]; then echo "SELFTEST: CANNOT READ — only $total arm(s) ran; this tally measures nothing"; return 1; fi
  [ "$fails" = 0 ] && { echo "SELFTEST: $pass/$total arms pass"; return 0; }
  echo "SELFTEST: $fails of $total arm(s) FAILED"; return 1
}
[ "${1:-}" = "--selftest" ] && { _r4_selftest; exit $?; }

PR="${1:?usage: required4.sh <pr> [owner/repo]}"
REPO="${2:-FRIKKern/barkpark}"
J=$(gh pr view "$PR" --repo "$REPO" --json statusCheckRollup 2>&1) || {
  echo "CANNOT READ: rollup unreadable for #$PR"; exit 3; }
printf '%s' "$J" | jq -e '.statusCheckRollup|type=="array"' >/dev/null 2>&1 || {
  echo "CANNOT READ: rollup is not an array — refusing to render a verdict"; exit 3; }

printf '%s' "$J" | jq -r '
  ["Cloud gate","Console gate","Elixir gate","PR references an active task"] as $req
  | (.statusCheckRollup // []) as $all
  | ($all|length) as $n
  | ($req | map(. as $name
      | ($all | map(select(.name==$name))
             | sort_by(.startedAt // .completedAt // "") | last) as $row
      | if $row == null then {name:$name, state:"ABSENT — no row rendered; an absence is NOT a pass"}
        elif (($row.conclusion // "") == "") then {name:$name, state:"PENDING — row rendered, status \($row.status // "?"), NO CONCLUSION YET; a wait, not a pass and not a failure"}
        else {name:$name, state:(($row.conclusion // $row.status // "?")
              + (if ($all|map(select(.name==$name))|length) > 1
                 then "  (newest of \($all|map(select(.name==$name))|length) rows — older ones SUPERSEDED)"
                 else "" end))} end)) as $rows
  | ($rows | map(select(.state|startswith("ABSENT"))) | length) as $absent
  | ($rows | map(select(.state|startswith("SUCCESS"))) | length) as $green
  | ($rows | map(select(.state|startswith("PENDING"))) | length) as $pending
  | "rollup rows on this PR: \($n)   (CONTROL: non-zero means the read reached something)",
    ($rows[] | "  \(.name): \(.state)"),
    "",
    (($absent + $pending) as $waiting
      | (4 - $green - $waiting) as $red
      | if $green == 4 then "VERDICT: 4/4 — all four RENDERED, CONCLUDED and SUCCESS"
        elif $waiting > 0 and $red == 0
          then "VERDICT: \($green)/4 GREEN, \($absent) NOT RENDERED, \($pending) PENDING — NOT MERGEABLE, and NOTHING HAS FAILED"
        elif $waiting > 0
          then "VERDICT: \($green)/4 GREEN, \($absent) NOT RENDERED, \($pending) PENDING, \($red) CONCLUDED NOT-GREEN"
        else "VERDICT: \($green)/4 — all four concluded, \($red) NOT GREEN" end)'
printf '%s' "$J" | jq -e '
  ["Cloud gate","Console gate","Elixir gate","PR references an active task"]
  | all(. as $n | ($n|length)>0)' >/dev/null
G=$(printf '%s' "$J" | jq -r '
  ["Cloud gate","Console gate","Elixir gate","PR references an active task"] as $req
  | (.statusCheckRollup // []) as $all
  | [$req[] | . as $name | ($all|map(select(.name==$name))|sort_by(.startedAt // .completedAt // "")|last)
     | select(. != null and .conclusion=="SUCCESS")] | length')
# ---------------------------------------------------------------------------
# ABSENT IS TWO DIFFERENT STATES AND THE CHECK-RUNS API CANNOT TELL THEM APART.
# deploy-r19, 2026-09-15: a required context with no check-run row looks IDENTICAL
# whether its workflow is RUNNING (a bounded WAIT) or was NEVER TRIGGERED (a
# PERMANENT BLOCK). The first says "wait"; the second says "hand it back now".
# They are separated by reading the WORKFLOW RUNS AND THEIR JOBS, never the rollup.
# Everything above this line reported both as "ABSENT — no row rendered", which is
# true and useless. This block says WHICH.
probe_absent() {
  # ABSENT IS TWO STATES AND THE CHECK-RUNS API CANNOT SEPARATE THEM.
  #   workflow RUNNING          -> a bounded WAIT
  #   workflow NEVER TRIGGERED  -> a PERMANENT BLOCK; hand the PR back now
  # Only the WORKFLOW RUNS and their JOBS tell them apart.
  #
  # THIS FUNCTION PRINTS NO PARSED STATUS FIELD, DELIBERATELY. An earlier version
  # split a joined string and printed `status=completed conclusion=success` for a
  # run that was QUEUED — a tool reporting a SUCCESS that had not happened, which
  # is the worst failure this file exists to prevent. The parse was the fault, not
  # the API, so the parse is gone: every field below comes straight out of jq.
  # And `gh run list --commit <sha>` SILENTLY MATCHES NOTHING on this repo
  # (0 rows for a sha whose runs exist), so this lists --branch and filters headSha.
  local pr="$1" repo="${2:-FRIKKern/barkpark}" sha br wf
  sha=$(gh pr view "$pr" --repo "$repo" --json headRefOid -q .headRefOid 2>/dev/null) || return 0
  br=$(gh pr view "$pr" --repo "$repo" --json headRefName -q .headRefName 2>/dev/null) || return 0
  [ -n "$sha" ] && [ -n "$br" ] || return 0
  echo ""
  echo "ABSENT-PROBE (workflow runs + jobs, never the rollup) — head ${sha:0:9}"
  for wf in cloud elixir console-harness pr-task-gate; do
    local line
    line=$(gh run list --repo "$repo" --workflow "$wf.yml" --branch "$br" --limit 30 \
             --json databaseId,status,conclusion,headSha \
             -q "[.[]|select(.headSha==\"$sha\")]|if length==0 then \"NO-RUN\" else (.[0]|\"run \\(.databaseId) status=\\(.status) conclusion=\\(.conclusion // \"none-yet\")\") end" 2>/dev/null)
    case "$line" in
      ""|null) echo "  $wf: CANNOT READ — the run list itself failed. NOT evidence of anything." ;;
      NO-RUN)  echo "  $wf: NO RUN ON THIS HEAD — never triggered. PERMANENT BLOCK, hand it back." ;;
      *)       echo "  $wf: $line"
               gh run view "${line#run }" --repo "$repo" --json jobs \
                 -q '.jobs[]|select(.status!="completed")|"      still moving: \(.name) [\(.status)]"' 2>/dev/null | head -5 ;;
    esac
  done
  echo '  A queued aggregate whose needs: are all green is waiting on a RUNNER.'
  echo '  A needs:-dependent rollup cannot render until its upstream job concludes —'
  echo '  that absence is BY DESIGN, not starvation. NO-RUN is the only hand-back.'
}

probe_absent "$@"

[ "$G" = "4" ] && exit 0 || exit 1

