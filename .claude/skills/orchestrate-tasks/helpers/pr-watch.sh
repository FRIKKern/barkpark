#!/usr/bin/env bash
# pr-watch.sh <pr-number>... — THE watcher. Every lead calls this instead of writing its own loop.
#
# WHY THIS FILE EXISTS. Every lead writes an ad-hoc `for p in $prs` PR watcher, and this harness's
# shell is zsh, which does NOT word-split an unquoted parameter expansion:
#
#   zsh  -c 'prs="1 2 3"; for p in $prs; do echo "[$p]"; done'   ->  ONE line:   [1 2 3]
#   bash -c 'prs="1 2 3"; for p in $prs; do echo "[$p]"; done'   ->  THREE lines: [1] [2] [3]
#
# The zsh watcher then polls PR "17098 17090" — a number that does not exist — and prints CANNOT
# READ all shift, or reports merges that never happened. The lesson has been written in
# LEAD-BRIEF.md since 2026-09-02 and the campaign hit it TWICE anyway: a written finding does not
# fire by itself. So the loop lives HERE, under bash, and PRs arrive as ARGUMENTS, never as a
# string. A caller under zsh that passes `$prs` unquoted hands us ONE argv element containing
# spaces; we re-split it ourselves (in bash) and then refuse anything that is not a bare number,
# so the caller's shell cannot silently decide how many PRs we poll.
#
# WATCHER RULES it implements (LEAD-BRIEF.md, "A monitor that watches merged PRs is a rate-limit
# leak with no reader" + "A watcher keyed on the happy-path string goes silent"):
#   * REST only (`gh api repos/O/R/pulls/N`), never GraphQL, never `gh pr view`.
#   * CHANGE-KEYED: prints a PR's verdict only when it DIFFERS from that PR's previous verdict.
#   * Drops a merged PR from the watch list and announces the drop.
#   * EXITS 0 the moment the watch list is empty (including when it starts empty).
#   * Interval floor 300 s (5 min). PR_WATCH_ALLOW_FAST=1 lifts it — selftest only.
#   * A failed read prints a distinct `CANNOT READ` line, is NOT recorded as a verdict, and makes
#     the final exit non-zero (3). It is a refusal, not a "not yet" and not a zero.
#   * Any line from pr-required.sh that is not a recognised verdict is reported as
#     `UNRECOGNISED:` and treated as still-waiting — never as "resolved".
#   * Second channel: everything also appends to --log (default $ORCH/pr-watch.log when ORCH is
#     set), so a watcher that gets backgrounded is not silent.
#
# USAGE
#   pr-watch.sh --repo FRIKKern/barkpark 17098 17090 17085
#   pr-watch.sh --once --repo FRIKKern/barkpark 17098      # one pass, then exit
#   pr-watch.sh --selftest                                 # hermetic, no network
#
# FLAGS
#   --repo O/R     owner/repo (else $GH_REPO, else the cwd's origin remote). Refuses if empty:
#                  an empty repo makes every read a 404, which reads exactly like "all red".
#   --interval N   seconds between passes (default 300, floor 300).
#   --passes N     stop after N passes (default: forever). --once == --passes 1.
#   --log FILE     append every line here too (default $ORCH/pr-watch.log if ORCH is set).
#   --pr-required PATH   the verdict oracle (default: pr-required.sh beside this file, then PATH).
#
# EXIT: 0 = watch list drained (or passes exhausted) with every read answered.
#       2 = bad arguments / unresolvable repo. 3 = at least one read REFUSED (CANNOT READ).
set -u
SELF="${BASH_SOURCE[0]}"; case "$SELF" in */*) SELFDIR="${SELF%/*}";; *) SELFDIR=".";; esac

# ------------------------------------------------------------------ SELFTEST (no network) ----
# Drives the helper against a stub `gh` and a stub `pr-required.sh` on PATH. Six arms:
#   1 change-emitted-once + unchanged-silent   2 merged dropped & announced, list drains, exit 0
#   3 empty list exits 0                       4 failed read -> distinct CANNOT READ, no verdict,
#                                                 exit 3, and the retained verdict stays silent
#   5 THE ZSH ARM: invoked through `zsh -c` with an unquoted multi-PR string, it must still poll
#     EACH PR (three verdict lines, one per PR)
#   6 unrecognised oracle output -> UNRECOGNISED, still-waiting, never "resolved"
# MUTATION that must red it: collapse the argv normalisation to `PRS=(${ARGV[@]+"${ARGV[*]}"})`
# — i.e. re-join the PR list into ONE quoted string, which is exactly what a zsh caller's
# unquoted `$prs` already handed us. Arm 5 goes red (4 assertions), and no other arm does: the
# single-PR arms cannot tell the two spellings apart, which is precisely why the trap survived
# two campaigns of hand-written watchers.
selftest() {
  local d rc out fails=0
  _ind() { while IFS= read -r _l; do printf '      | %s\n' "$_l"; done; }
  d=$(mktemp -d) || return 1
  mkdir -p "$d/bin" "$d/verdicts" "$d/merged" "$d/count"

  # Stub gh: answers ONLY the REST merged-flag read this helper makes. It emits the raw field the
  # helper asks for; it never emits the helper's own output strings.
  cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || { echo "stub gh: unexpected verb '$1'" >&2; exit 9; }
path="$2"; pr="${path##*/}"
if [ "${GH_STUB_BREAK:-}" = "$pr" ]; then exit 1; fi
f="$STUB_DIR/merged/$pr"
n=1; [ -f "$STUB_DIR/count/gh.$pr" ] && n=$(cat "$STUB_DIR/count/gh.$pr")
echo $((n+1)) > "$STUB_DIR/count/gh.$pr"
if [ -f "$f" ]; then sed -n "${n}p" "$f" | grep . || tail -1 "$f"; else echo false; fi
STUB
  # Stub pr-required.sh: line N of verdicts/<pr> on pass N (last line repeats). A line beginning
  # "CANNOT READ" is emitted and exits 3, exactly like the real oracle's refusal.
  cat > "$d/bin/pr-required.sh" <<'STUB'
#!/usr/bin/env bash
pr="$1"
f="$STUB_DIR/verdicts/$pr"
n=1; [ -f "$STUB_DIR/count/v.$pr" ] && n=$(cat "$STUB_DIR/count/v.$pr")
echo $((n+1)) > "$STUB_DIR/count/v.$pr"
line=$(sed -n "${n}p" "$f"); [ -n "$line" ] || line=$(tail -1 "$f")
echo "some intermediate line that is NOT the verdict"
echo "$line"
case "$line" in "CANNOT READ"*) exit 3;; esac
exit 0
STUB
  chmod +x "$d/bin/gh" "$d/bin/pr-required.sh"

  _run() { # _run <label> <expected-exit> -- <args...>   ; stdout in $out, rc in $rc
    local label="$1" wantrc="$2"; shift 3
    out=$(PATH="$d/bin:$PATH" STUB_DIR="$d" ORCH='' PR_WATCH_ALLOW_FAST=1 \
          bash "$SELF" --pr-required "$d/bin/pr-required.sh" --interval 0 "$@" 2>&1); rc=$?
    if [ "$rc" != "$wantrc" ]; then
      echo "FAIL $label: exit $rc, wanted $wantrc"; echo "$out" | _ind; fails=$((fails+1)); return 1
    fi
    echo "ok   $label (exit $rc)"; return 0
  }
  _want() { # _want <label> <count> <grep-pattern>
    local label="$1" want="$2" pat="$3" got
    got=$(printf '%s\n' "$out" | grep -cE "$pat")
    if [ "$got" != "$want" ]; then
      echo "FAIL $label: $got line(s) matching /$pat/, wanted $want"; printf '%s\n' "$out" | _ind; fails=$((fails+1))
    else echo "ok   $label ($got matching /$pat/)"; fi
  }

  echo "== arm 1: a verdict CHANGE is emitted once; an UNCHANGED verdict is silent"
  rm -f "$d/count/"*; printf '%s\n' "NOT YET: 3/4 required green on aaaaaaaaaa" \
    "NOT YET: 3/4 required green on aaaaaaaaaa" \
    "MERGEABLE: 4/4 required green on bbbbbbbbbb" > "$d/verdicts/101"
  if _run "arm1 runs" 0 -- --repo acme/widget --passes 3 101; then
    _want "arm1 NOT YET printed once"    1 '#101 .*NOT YET: 3/4'
    _want "arm1 MERGEABLE printed once"  1 '#101 .*MERGEABLE: 4/4'
  fi

  echo "== arm 2: a merged PR is DROPPED and announced; the drained list exits 0"
  rm -f "$d/count/"*; printf '%s\n' "NOT YET: 3/4 required green on aaaaaaaaaa" > "$d/verdicts/102"
  printf '%s\n' "false" "true" > "$d/merged/102"
  if _run "arm2 runs" 0 -- --repo acme/widget --passes 5 102; then
    _want "arm2 announces the merge" 1 '#102 MERGED'
    _want "arm2 drains and exits"    1 'watch list empty'
    _want "arm2 no verdict after the drop" 1 '#102 .*NOT YET'
  fi

  echo "== arm 3: an EMPTY watch list exits 0"
  rm -f "$d/count/"*
  if _run "arm3 runs" 0 -- --repo acme/widget --passes 3; then
    _want "arm3 says the list is empty" 1 'watch list empty'
    _want "arm3 polls nothing"          0 '#[0-9]'
  fi

  echo "== arm 4: a FAILED read is a distinct CANNOT READ, is not a verdict, and exits 3"
  rm -f "$d/count/"*; printf '%s\n' "NOT YET: 3/4 required green on aaaaaaaaaa" \
    "CANNOT READ: check-runs for acme/widget@aaaaaaaaaa could not be fetched" \
    "NOT YET: 3/4 required green on aaaaaaaaaa" > "$d/verdicts/103"
  if _run "arm4 runs" 3 -- --repo acme/widget --passes 3 103; then
    _want "arm4 prints CANNOT READ once"          1 'CANNOT READ #103'
    _want "arm4 does not print it as a verdict"   0 '#103 .*(MERGEABLE|NOT YET: ).*CANNOT'
    _want "arm4 keeps the pre-refusal verdict, so pass 3 is silent" 1 '#103 .*NOT YET: 3/4'
  fi
  echo "== arm 4b: a failed MERGED read is also a refusal, not 'not merged'"
  rm -f "$d/count/"*; printf '%s\n' "NOT YET: 3/4 required green on aaaaaaaaaa" > "$d/verdicts/104"
  out=$(PATH="$d/bin:$PATH" STUB_DIR="$d" ORCH='' PR_WATCH_ALLOW_FAST=1 GH_STUB_BREAK=104 \
        bash "$SELF" --pr-required "$d/bin/pr-required.sh" --interval 0 --repo acme/widget --passes 1 104 2>&1); rc=$?
  if [ "$rc" = 3 ]; then echo "ok   arm4b (exit 3)"; else echo "FAIL arm4b: exit $rc, wanted 3"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
  _want "arm4b names the unread merged flag" 1 'CANNOT READ #104'

  echo "== arm 5: THE ZSH ARM — an unquoted multi-PR string from zsh still polls EACH PR"
  rm -f "$d/count/"*
  for p in 201 202 203; do printf '%s\n' "NOT YET: 3/4 required green on aaaaaaaaaa" > "$d/verdicts/$p"; done
  if command -v zsh >/dev/null 2>&1; then
    # zsh does NOT word-split $prs: the helper receives ONE argv element, "201 202 203".
    out=$(PATH="$d/bin:$PATH" STUB_DIR="$d" ORCH='' PR_WATCH_ALLOW_FAST=1 zsh -c \
      'prs="201 202 203"; exec bash "$1" --pr-required "$2" --interval 0 --repo acme/widget --passes 1 $prs' \
      zshrun "$SELF" "$d/bin/pr-required.sh" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then echo "ok   arm5 runs (exit 0)"; else echo "FAIL arm5: exit $rc, wanted 0"; printf '%s\n' "$out" | _ind; fails=$((fails+1)); fi
    _want "arm5 polls 201" 1 '#201 .*NOT YET'
    _want "arm5 polls 202" 1 '#202 .*NOT YET'
    _want "arm5 polls 203" 1 '#203 .*NOT YET'
    # Control: prove the trap is REAL in this zsh, so a green arm 5 is not "zsh split after all".
    local zsplit; zsplit=$(zsh -c 'prs="1 2 3"; for p in $prs; do echo "[$p]"; done' | wc -l | tr -d ' ')
    if [ "$zsplit" = 1 ]; then echo "ok   arm5 control (zsh really does NOT word-split: 1 iteration)"
    else echo "FAIL arm5 control: zsh produced $zsplit iterations — the trap this helper guards did not reproduce"; fails=$((fails+1)); fi
  else
    echo "SKIP arm5: no zsh on PATH (the trap cannot be reproduced here)"
  fi

  echo "== arm 6: an UNRECOGNISED oracle line is reported and treated as still-waiting"
  rm -f "$d/count/"*; printf '%s\n' "  RED non-required job (blocks nothing): Format" > "$d/verdicts/105"
  if _run "arm6 runs" 0 -- --repo acme/widget --passes 2 105; then
    # Reported on EVERY pass, not change-keyed: "still waiting, AND TELL ME" is the rule, and a
    # shape the watcher cannot read is exactly what must not go quiet. 2 passes -> 2 lines.
    _want "arm6 flags it on every pass"  2 'UNRECOGNISED: #105'
    _want "arm6 never calls it resolved" 0 'watch list empty'
  fi

  rm -rf "$d"
  if [ "$fails" -gt 0 ]; then echo "pr-watch.sh selftest: $fails FAILED"; return 1; fi
  echo "pr-watch.sh selftest: all arms passed"; return 0
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

# ------------------------------------------------------------------ ARGUMENTS ----------------
REPO="${GH_REPO:-}"; INTERVAL=300; PASSES=0; LOG="${ORCH:+$ORCH/pr-watch.log}"; ORACLE=""
ARGV=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)         REPO="${2:-}"; shift 2;;
    --interval)     INTERVAL="${2:-}"; shift 2;;
    --passes)       PASSES="${2:-}"; shift 2;;
    --once)         PASSES=1; shift;;
    --log)          LOG="${2:-}"; shift 2;;
    --pr-required)  ORACLE="${2:-}"; shift 2;;
    -h|--help)      sed -n '2,50p' "$SELF"; exit 0;;
    --*)            echo "pr-watch.sh: unknown flag '$1'" >&2; exit 2;;
    *)              ARGV+=("$1"); shift;;
  esac
done

# --- THE NORMALISATION. Do not collapse this to `PRS=("$*")`. -------------------------------
# A caller under zsh writes `pr-watch.sh $prs` and zsh hands us ONE argv element, "17098 17090",
# because zsh does not word-split an unquoted parameter expansion. Re-split every argument HERE,
# in bash, on whitespace and commas, so the number of PRs polled is decided by this file and not
# by whichever shell invoked it. Then refuse anything that is not a bare number: a caller that
# manages to smuggle junk through gets a loud exit 2, never a silent poll of a nonexistent PR.
PRS=()
for _raw in ${ARGV[@]+"${ARGV[@]}"}; do
  _toks=()
  IFS=$' \t\n,' read -r -a _toks <<<"$_raw"
  for _t in ${_toks[@]+"${_toks[@]}"}; do [ -n "$_t" ] && PRS+=("$_t"); done
done
for _p in ${PRS[@]+"${PRS[@]}"}; do
  case "$_p" in
    ''|*[!0-9]*) echo "pr-watch.sh: '$_p' is not a PR number. PRs are positional ARGUMENTS, one per number (pr-watch.sh 17098 17090) — never a single string." >&2; exit 2;;
  esac
done
# --------------------------------------------------------------------------------------------

case "$INTERVAL" in ''|*[!0-9]*) echo "pr-watch.sh: --interval must be a whole number of seconds" >&2; exit 2;; esac
case "$PASSES"   in ''|*[!0-9]*) echo "pr-watch.sh: --passes must be a whole number" >&2; exit 2;; esac
if [ "$INTERVAL" -lt 300 ] && [ "${PR_WATCH_ALLOW_FAST:-}" != 1 ]; then
  echo "pr-watch.sh: --interval $INTERVAL is below the 5-minute floor; clamping to 300 (a per-lane 2-minute poll is where the GraphQL secondary limit went)" >&2
  INTERVAL=300
fi
if [ -z "$REPO" ]; then
  u=$(git config --get remote.origin.url 2>/dev/null || true); u="${u%.git}"; u="${u%/}"
  case "$u" in *[:/]*/*) REPO="$(basename "$(dirname "$u")")/$(basename "$u")";; esac
fi
if [ -z "$REPO" ]; then
  echo "pr-watch.sh: CANNOT READ — owner/repo unresolved. Pass --repo O/R or set GH_REPO. Nothing was watched; this is NOT 'no PRs pending'." >&2
  exit 2
fi
[ -n "$ORACLE" ] || { [ -x "$SELFDIR/pr-required.sh" ] && ORACLE="$SELFDIR/pr-required.sh"; }
[ -n "$ORACLE" ] || ORACLE=$(command -v pr-required.sh 2>/dev/null || true)
if [ -z "$ORACLE" ]; then
  echo "pr-watch.sh: CANNOT READ — pr-required.sh not found beside this file or on PATH. Pass --pr-required PATH." >&2
  exit 2
fi

say() { # every line goes to stdout AND to the log: a backgrounded watcher must not be silent
  printf '%s %s\n' "$(date -u +%H:%MZ)" "$*"
  [ -n "$LOG" ] && printf '%s %s\n' "$(date -u +%H:%MZ)" "$*" >> "$LOG" 2>/dev/null
  return 0
}

# bash 3.2 has no associative arrays: last verdict per PR lives in a temp state dir.
STATE=$(mktemp -d) || exit 2
trap 'rm -rf "$STATE"' EXIT
REFUSALS=0; PASS=0

while :; do
  PASS=$((PASS+1))
  if [ "${#PRS[@]}" -eq 0 ]; then
    say "pr-watch: watch list empty — exiting (nothing left to watch)"
    [ "$REFUSALS" -gt 0 ] && exit 3
    exit 0
  fi
  NEXT=()
  for pr in "${PRS[@]}"; do
    # 1. MERGED? REST, one call. A failed read is a refusal, never "not merged".
    if ! merged=$(gh api "repos/$REPO/pulls/$pr" --jq '.merged' 2>/dev/null); then
      say "CANNOT READ #$pr: the merged flag for $REPO#$pr could not be fetched — this is NOT a verdict and NOT 'not merged'."
      REFUSALS=$((REFUSALS+1)); NEXT+=("$pr"); continue
    fi
    if [ "$merged" = true ]; then
      say "#$pr MERGED — dropped from the watch list"
      continue                                   # dropped: a merged PR is never polled again
    fi
    # 2. VERDICT. The oracle's contract: the verdict is its LAST line.
    v=$("$ORACLE" "$pr" "$REPO" 2>/dev/null | tail -1)
    case "$v" in
      "CANNOT READ"*)
        say "CANNOT READ #$pr: $(printf '%s' "$v" | cut -c1-140)"
        REFUSALS=$((REFUSALS+1)); NEXT+=("$pr"); continue;;   # not recorded: refusal != verdict
      MERGEABLE:*|"NOT YET:"*|CONFLICTING:*) ;;
      *)
        # Never key on the happy-path string: an unrecognised shape is "still waiting, and tell me".
        say "UNRECOGNISED: #$pr oracle said: $(printf '%s' "$v" | cut -c1-140) — treating as still waiting"
        NEXT+=("$pr"); continue;;
    esac
    prev=""; [ -f "$STATE/$pr" ] && prev=$(cat "$STATE/$pr")
    if [ "$v" != "$prev" ]; then
      say "#$pr $v"
      printf '%s' "$v" > "$STATE/$pr"
    fi                                            # unchanged verdict: silent, by design
    NEXT+=("$pr")
  done
  PRS=(${NEXT[@]+"${NEXT[@]}"})
  if [ "$PASSES" -gt 0 ] && [ "$PASS" -ge "$PASSES" ]; then
    [ "$REFUSALS" -gt 0 ] && exit 3
    exit 0
  fi
  [ "${#PRS[@]}" -eq 0 ] && continue              # drained: the top of the loop announces + exits
  sleep "$INTERVAL"
done
