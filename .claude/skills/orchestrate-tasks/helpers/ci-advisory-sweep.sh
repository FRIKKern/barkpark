#!/usr/bin/env bash
# Cancel QUEUED advisory workflow runs on campaign branches so the four required checks get runner slots.
# Keeps: elixir, cloud, console-harness, pr-task-gate (required), go-tests, mobile, Grip suite; doc-gates on docs/*; security on security/* + sec2/*.
#
# ── THE COUNT IDENTITY (task-c767be8a820a9300) ──────────────────────────────
# The loop below is fed by a FILE on fd 0, and its body runs CHILDREN — `gh run
# cancel` and `gh api -X POST` — that INHERIT fd 0. Any command in that body
# that reads stdin (a future `gh` subcommand that prompts, a `jq -`, a bare
# `read`) swallows the rest of the list, the loop ends early AT EXIT 0, and the
# summary line below reports "cancelled N" over the runs it happened to reach
# while saying nothing about the ones it never looked at. A sweep that cancels
# 1 of 40 and prints "cancelled 1" is indistinguishable from a sweep that found
# 1 to cancel.
#
# The guard is a COUNT COMPARISON — lines handled vs lines handed in — and
# deliberately not fd discipline: fd discipline is a property of every child in
# this body forever, which nothing can hold, while the identity is one
# assertion that notices no matter WHY the loop came up short. No `</dev/null`
# is attached to the children here for exactly that reason: it would silence
# the symptom this check exists to catch and leave the check unfalsifiable.
# See the identity arms in `--selftest`.
set -u
SELF="${BASH_SOURCE[0]}"

# ── selftest ────────────────────────────────────────────────────────────────
# Hermetic: a stub `gh` first on PATH, no network. The two stubs differ by
# EXACTLY ONE LINE — `cat > /dev/null` — so the only variable between the red
# arm and the green one is whether a child in the loop body reads fd 0.
selftest() {
  local d fails=0 out rc
  _chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$3], wanted [$2]"; fails=$((fails+1)); fi; }
  _has() { # _has <label> <needle> <haystack>
    case "$3" in *"$2"*) echo "ok   $1";; *) echo "FAIL $1: output lacks [$2]"; fails=$((fails+1)); printf '%s\n' "$3" | sed -e 's/^/      | /';; esac; }
  d=$(mktemp -d) || return 1
  mkdir -p "$d/a" "$d/b"

  # THREE queued runs, all on a campaign prefix, none on the keep list — so the
  # ONLY thing that can change the verdict between the arms is the count.
  cat > "$d/a/gh" <<STUBA
#!/usr/bin/env bash
if [ "\$1" = run ] && [ "\$2" = list ]; then
  case "\$*" in *length*) echo 3; exit 0;; esac
  printf '%s\t%s\t%s\n' 101 advisory-one gates/x 102 advisory-two gates/y 103 advisory-three gates/z
  exit 0
fi
cat > /dev/null
echo call >> "$d/calls-a"
exit 0
STUBA
  # THE CONTROL: byte-identical minus the stdin read.
  sed -e '/^cat > \/dev\/null$/d' -e "s#$d/calls-a#$d/calls-b#" "$d/a/gh" > "$d/b/gh"
  chmod +x "$d/a/gh" "$d/b/gh"
  : > "$d/calls-a"; : > "$d/calls-b"

  echo "== arm 0: POSITIVE CONTROL — the stubs differ by exactly the stdin read"
  _chk "arm0 one line of difference" 1 "$(diff "$d/a/gh" "$d/b/gh" | grep -c '^< cat > /dev/null$')"

  echo "== arm i1: a stdin-reading child is REFUSED, and the refusal states BOTH numbers"
  out=$(PATH="$d/a:$PATH" bash "$SELF" 2>&1); rc=$?
  _chk "i1 exits 3" 3 "$rc"
  _has "i1 names 1 of the 3"            "handled 1 of the 3" "$out"
  _has "i1 is not a finding about CI"   "NOT a finding about CI" "$out"
  _has "i1 names the stdin mechanism"   "READS STDIN" "$out"
  _has "i1 forbids deleting the count"  "Do NOT satisfy this by deleting the count check" "$out"
  _has "i1 never prints a cancelled-N summary" "ci-sweep: REFUSING" "$out"
  _chk "i1 printed no 'cancelled' tally" 0 "$(printf '%s\n' "$out" | grep -c 'cancelled ')"

  echo "== arm i2: THE CONTROL — same stub minus the read reaches all three"
  out=$(PATH="$d/b:$PATH" bash "$SELF" 2>&1); rc=$?
  _chk "i2 exits 0" 0 "$rc"
  _has "i2 cancelled all three" "cancelled 3 advisory" "$out"
  _has "i2 says how many it reached" "handled 3 of the 3" "$out"

  echo "== arm i3: the truncation is visible in the CHILD CALL TALLY, independently of the verdict"
  : > "$d/calls-a"; : > "$d/calls-b"
  PATH="$d/a:$PATH" bash "$SELF" >/dev/null 2>&1
  PATH="$d/b:$PATH" bash "$SELF" >/dev/null 2>&1
  # 2 children per reached line (`run cancel` then `api -X POST`): 1 line -> 2, 3 lines -> 6.
  _chk "i3 stdin stub issued calls for ONE line" 2 "$(grep -c . "$d/calls-a" | tr -d ' ')"
  _chk "i3 control issued calls for THREE"       6 "$(grep -c . "$d/calls-b" | tr -d ' ')"

  echo "== arm i4: MUTANT — the identity removed goes GREEN over the truncated list"
  # shellcheck disable=SC2016  # the $-names are THIS file's text to match, not ours to expand
  sed -e 's/^if \[ "\$reached" != "\$fed" \]; then$/if false; then/' "$SELF" > "$d/nocount.sh"
  if ! grep -q '^if false; then$' "$d/nocount.sh"; then
    echo "FAIL i4: the mutation did not apply — the identity guard was reworded"; fails=$((fails+1))
  else
    out=$(PATH="$d/a:$PATH" bash "$d/nocount.sh" 2>&1); rc=$?
    _chk "i4 mutant exits 0" 0 "$rc"
    _has "i4 mutant reports a SILENT undercount" "cancelled 1 advisory" "$out"
  fi

  rm -rf "$d"
  if [ "$fails" -gt 0 ]; then echo "ci-advisory-sweep.sh selftest: $fails FAILED"; return 1; fi
  echo "ci-advisory-sweep.sh selftest: all arms passed"; return 0
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

tmp=$(mktemp); gh run list --status queued --limit 700 --json databaseId,headBranch,workflowName \
  --jq '.[]|select(.headBranch|test("^(security|security-r|sec2|gates|deploy|console|cli|cli2|studio|docs|pds|grip|instr|chat|media|sheets|papers|orch)/"))|"\(.databaseId)\t\(.workflowName)\t\(.headBranch)"' > "$tmp" 2>/dev/null
# HANDED IN: every physical line of the list, counted OUTSIDE the loop and from
# the same file the loop is about to read. awk counts a final unterminated line
# as a record, which is why the loop below carries the `|| [ -n ... ]` clause —
# the two readers must agree on what a line is or the identity is noise.
fed=$(awk 'END{print NR}' "$tmp"); [ -n "$fed" ] || fed=0
n=0; kept=0; reached=0
while IFS=$'\t' read -r id wf branch || [ -n "${id:-}" ]; do
  # COUNTED FIRST, before any `continue`: a line is "handled" once this loop has
  # read it and made a decision about it, kept or cancelled. Counting after the
  # case would make every keep look like a truncation.
  reached=$((reached+1))
  [ -n "${id:-}" ] || continue
  case "$wf" in elixir|cloud|console-harness|pr-task-gate|go-tests|mobile|"Grip suite") kept=$((kept+1)); continue;;
    doc-gates) case "$branch" in docs/*) kept=$((kept+1)); continue;; esac;;
    security) case "$branch" in security/*|sec2/*) kept=$((kept+1)); continue;; esac;; esac
  gh run cancel "$id" >/dev/null 2>&1; gh api -X POST "repos/FRIKKern/barkpark/actions/runs/$id/force-cancel" >/dev/null 2>&1 && n=$((n+1))
done < "$tmp"; rm -f "$tmp"
# THE IDENTITY, CHECKED BEFORE THE SUMMARY. Both numbers are in the sentence:
# "the loop is broken" is unactionable, "handled 1 of the 40 handed in" is not.
if [ "$reached" != "$fed" ]; then
  echo "$(date -u +%H:%MZ) ci-sweep: REFUSING — the cancel loop handled $reached of the $fed queued run(s) the gh read handed it, so this sweep CANNOT say anything about the other $((fed - reached)): not whether they were cancelled, not whether they were kept. It is NOT a finding about CI — it is this sweep failing to do its own work, and the near-certain cause is that something in the loop body now READS STDIN: the list is on fd 0 and the 'gh run cancel'/'gh api' children inherit fd 0, so one stdin read swallows the remaining lines and the loop ends after $reached iteration(s) at exit 0. Find the new stdin reader and give it its own input (for example '</dev/null'), then re-run. Do NOT satisfy this by deleting the count check: the count is the only thing that can see this at all." >&2
  exit 3
fi
echo "$(date -u +%H:%MZ) ci-sweep: cancelled $n advisory, kept $kept required/lane-relevant (handled $reached of the $fed queued run(s) handed in); queued now $(gh run list --status queued --limit 700 --json databaseId --jq 'length'), running $(gh run list --status in_progress --limit 100 --json databaseId --jq 'length')"
