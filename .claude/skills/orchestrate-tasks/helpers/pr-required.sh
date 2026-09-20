#!/usr/bin/env bash
# pr-required.sh <pr-number> [owner/repo] — the truth about a PR's REQUIRED checks, by head sha.
# `gh pr checks` renders cancelled/queued in the same column as fail; this reads check-runs for the
# PR's current head and prints one line per required context with its real status/conclusion.
#
# CONTRACT: the verdict line ("MERGEABLE: 4/4 …" / "NOT YET: n/4 …" / "CONFLICTING: 4/4 … DIRTY") is ALWAYS THE LAST LINE. MERGEABLE now also means not DIRTY.
# The verdict line now carries a VERDICT-AGE annotation AFTER the count — either
# " [verdict <n> min old, <m> commit(s) behind <base>]" or, when the verdict is stale,
# " (STALE VERDICT: <n> min old, <m> commits behind - update-branch before merging)". The
# LEADING TOKEN IS UNCHANGED: merge-sweep.sh (MERGEABLE*), pr-watch.sh (MERGEABLE:*) and
# merge-check.sh (MERGEABLE*) all prefix-match, so an appended clause is invisible to them.
# Callers do `| tail -1`. Anything appended after it silently swaps what every wrapper reads
# (measured 2026-09-02: an EARLY RED section appended here made a lane's watcher report a job
# name where the verdict should be, and would have stopped the merge sweep merging anything).
#
# SELFTEST: `pr-required.sh --selftest` drives its arms (healthy PR / unreadable repo /
# unreadable head sha / unfetchable check-runs / a head with NO check runs / repo-arg omitted /
# genuine 0/4 / stale-head guard with a FAILED re-read / stale-head guard with BOTH reads
# disagreeing / stale-head guard SELF-HEALING: REST agrees with the branch, so the script adopts
# the REST sha and CONTINUES to an ordinary verdict about the BRANCH commit / the fetch refspec
# CREATING the tracking ref in a repo with NO default refspec / the FORCED refspec surviving a
# non-fast-forward update, which a non-forced refspec skips the entire guard on / a STALE
# verdict / a FRESH verdict that must NOT be annotated stale / a verdict 0 commits behind that
# must NOT be annotated stale / an unreadable compare that says CANNOT READ instead of zero /
# a MUTANT with the staleness clause removed, which proves the stale arm is load-bearing / the
# MIRROR copy under .claude/skills/orchestrate-tasks/helpers/ being byte-identical to this one)
# against a stub `gh` on PATH,
# from a cwd that is NOT a git repo, and asserts for each that `| tail -1` reads the verdict or
# the refusal — never an intermediate line — that no refusal contains the string "0/4", and
# that an HONEST 0/4 (four required contexts present, all failed) still verdicts at exit 0.
# It makes NO network calls. Run it after ANY edit to this file.
set -u
SELF="${BASH_SOURCE[0]}"; case "$SELF" in */*) SELFDIR="${SELF%/*}";; *) SELFDIR=".";; esac
# VENDORED 2026-09-16: absolutise both. The selftest arms `cd` into a temp dir and then
# re-invoke `bash "$SELF"`, so a RELATIVE $SELF (what `bash scripts/pr-required.sh --selftest`
# from the repo root yields) resolves to nothing and every such arm dies at exit 127 — a
# 17-of-21 FAIL that is entirely an artefact of how the script was invoked. The tool itself was
# fine; its selftest just could not find itself. SELFDIR keeps pointing at the same directory
# (so the `_repo_from_git "$SELFDIR"` fallback is unchanged), it is merely now absolute.
SELFDIR=$(cd "$SELFDIR" 2>/dev/null && pwd) || SELFDIR="."
SELF="$SELFDIR/${SELF##*/}"
# ------------------------------------------------------------------ SELFTEST (no network) ----
_selftest_body() {
  local d rc out last fails=0 label want wantrc brk REALSHA STALE_TAIL STALE_A STALE_B _guard OTHERSHA
  d=$(mktemp -d) || return 1
  mkdir -p "$d/bin" "$d/bin2" "$d/norepo"
  cat > "$d/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh. GH_STUB_BREAK names the ONE read that fails; everything else answers healthily,
# so a refusal proves specificity, not a blanket refusal.
# RAW API SHAPE. The compare endpoint answers a JSON OBJECT, so this stub emits that object and
# then applies `--jq` to it exactly as real gh does. The arms therefore exercise THIS SCRIPT'S
# OWN projection of behind_by/ahead_by; a stub that handed back a pre-chewed number would leave
# the projection — the part that can be wrong — unmeasured.
_gh_stub_compare() {
  local j f="" nx=0 x
  j="{\"status\":\"behind\",\"ahead_by\":${GH_STUB_AHEAD:-1},\"behind_by\":${GH_STUB_BEHIND:-0},\"total_commits\":${GH_STUB_AHEAD:-1}}"
  for x in "$@"; do
    [ "$nx" = 1 ] && { f="$x"; break; }
    [ "$x" = "--jq" ] && nx=1
  done
  if [ -n "$f" ]; then printf '%s\n' "$j" | jq -r "$f"; else printf '%s\n' "$j"; fi
}
case "$1 $2" in
  "repo view"*) [ "${GH_STUB_BREAK:-}" = repo ] && exit 1; echo "acme/widget"; exit 0;;
  "pr view"*)   [ "${GH_STUB_BREAK:-}" = sha ]  && exit 1; echo "aaaaaaaaaa11112222333344445555666677778888"; exit 0;;
esac
if [ "$1" = api ]; then
  for a in "$@"; do
    case "$a" in
      */check-runs*)   [ "${GH_STUB_BREAK:-}" = runs ] && exit 1
                       # GH_STUB_BREAK=empty: the fetch SUCCEEDS and returns nothing. A head
                       # with zero check runs is a fourth unreadable input, not a 0/4.
                       [ "${GH_STUB_BREAK:-}" = empty ] && exit 0
                       # GH_STUB_ALLRED: the four required contexts EXIST on this head and every
                       # one concluded failure — a real, measured 0/4, not a failed read.
                       c=success; [ "${GH_STUB_ALLRED:-}" = 1 ] && c=failure
                       # 5th column = .completed_at, the field the verdict-age read projects.
                       k="${GH_STUB_COMPLETED:-2026-01-01T00:00:00Z}"
                       printf '%s\n' \
                         "Cloud gate	completed	$c	2026-01-01T00:00:00Z	$k" \
                         "Console gate	completed	$c	2026-01-01T00:00:00Z	$k" \
                         "Elixir gate	completed	$c	2026-01-01T00:00:00Z	$k" \
                         "PR references an active task	completed	$c	2026-01-01T00:00:00Z	$k"
                       exit 0;;
      */actions/runs*) echo 0; exit 0;;
      */compare/*)     [ "${GH_STUB_BREAK:-}" = compare ] && exit 1
                       _gh_stub_compare "$@"; exit 0;;
      */pulls/*)       [ "${GH_STUB_BREAK:-}" = sha ] && exit 1
                       case " $* " in
                         *" .mergeable_state"*) echo clean;;
                         *" .base.ref"*)        echo "${GH_STUB_BASE:-main}";;
                         *) echo "aaaaaaaaaa11112222333344445555666677778888";;
                       esac
                       exit 0;;
    esac
  done
fi
exit 0
STUB
  chmod +x "$d/bin/gh"
  _arm() { # label  expected-LAST-line-prefix  expected-exit  GH_STUB_BREAK  args...
    label="$1"; want="$2"; wantrc="$3"; brk="$4"; shift 4
    out=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_STUB_BREAK="$brk" GH_STUB_ALLRED="${ALLRED:-}" GH_REPO="" bash "$SELF" "$@" 2>/dev/null ); rc=$?
    last=$(printf '%s\n' "$out" | tail -1)
    if [ "$rc" = "$wantrc" ] && case "$last" in "$want"*) true;; *) false;; esac; then
      printf 'PASS %-20s exit=%s | tail -1: %s\n' "$label" "$rc" "$last"
    else
      printf 'FAIL %-20s exit=%s (want %s) | tail -1: %s (want prefix %s)\n' "$label" "$rc" "$wantrc" "$last" "$want"; fails=$((fails+1))
    fi
    if [ "$want" = "CANNOT READ" ]; then
      case "$out" in *0/4*) printf 'FAIL %-20s the string 0/4 appears in a refusal\n' "$label"; fails=$((fails+1));; esac
    fi
  }
  _arm "healthy PR"       "MERGEABLE: 4/4"  0 ""     42 acme/widget
  cp "$SELF" "$d/norepo/pr-required.sh"   # arm 2 runs a copy that has NO git remote at its own dir
  out=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_STUB_BREAK=repo GH_REPO="" bash "$d/norepo/pr-required.sh" 42 2>/dev/null ); rc=$?
  last=$(printf '%s\n' "$out" | tail -1)
  case "$rc:$last" in
    3:"CANNOT READ"*) printf 'PASS %-20s exit=3 | tail -1: %s\n' "unreadable repo" "$last";;
    *) printf 'FAIL %-20s exit=%s | tail -1: %s\n' "unreadable repo" "$rc" "$last"; fails=$((fails+1));;
  esac
  case "$out" in *0/4*) printf 'FAIL %-20s the string 0/4 appears in a refusal\n' "unreadable repo"; fails=$((fails+1));; esac
  _arm "unreadable sha"   "CANNOT READ"     3 sha    42 acme/widget
  _arm "unfetchable runs" "CANNOT READ"     3 runs   42 acme/widget
  _arm "no check runs"    "CANNOT READ"     3 empty  42 acme/widget
  # Arm 5: NO repo argument and `gh repo view` dead — the git-remote fallback must still resolve
  # owner/repo from the directory the SCRIPT lives in, so a lead calling `pr-required.sh <pr>`
  # from any cwd gets a verdict instead of the empty-repo lie. This is the cwd trigger.
  git init -q "$d/r" 2>/dev/null && git -C "$d/r" remote add origin git@github.com:acme/widget.git 2>/dev/null
  cp "$SELF" "$d/r/pr-required.sh"
  out=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_STUB_BREAK=repo GH_REPO="" bash "$d/r/pr-required.sh" 42 2>/dev/null ); rc=$?
  last=$(printf '%s\n' "$out" | tail -1)
  case "$rc:$last" in
    0:MERGEABLE:*) printf 'PASS %-20s exit=0 | tail -1: %s\n' "git-remote default" "$last";;
    *) printf 'FAIL %-20s exit=%s | tail -1: %s\n' "git-remote default" "$rc" "$last"; fails=$((fails+1));;
  esac
  # Arm 6 — ANTI-OVER-REACH. A head whose four required contexts all EXIST and all concluded
  # failure is a genuine, measured zero. The refusal must NOT swallow it: the verdict stays
  # "NOT YET: 0/4 …" at exit 0. This arm FAILS if anyone widens the CANNOT READ guard to cover
  # "no required context is green", which would make an honest red indistinguishable from a
  # broken read in the opposite direction.
  ALLRED=1 _arm "genuine 0/4"    "NOT YET: 0/4"    0 ""     42 acme/widget
  unset ALLRED
  # ------------------------------- arms: VERDICT AGE + COMMITS BEHIND (2026-09-20) ----------
  # The verdict is a SNAPSHOT; these arms pin that it now says how old a snapshot and how far the
  # base moved under it, and — the load-bearing half — that it only cries STALE when BOTH the age
  # AND the distance say so. The stub answers the compare endpoint with the RAW API object and
  # applies --jq to it as gh does, so the projection under test is this script's own.
  # completed_at is computed RELATIVE TO NOW, not pinned: a fixed timestamp makes "is this older
  # than 60 minutes" answer the same from the day it is written until the end of time, i.e. it
  # would stop measuring the comparison the moment it was committed.
  _iso_ago() { # $1 = minutes ago; prints an ISO-8601 Z timestamp, GNU date then BSD date
    date -u -d "-$1 minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
    date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
    return 1
  }
  _age_arm() { # label  minutes-ago  behind_by  GH_STUB_BREAK  must-contain  must-NOT-contain
    local lbl="$1" mins="$2" beh="$3" brk="$4" must="$5" mustnot="$6" o r l comp
    if [ "$mins" = "-" ]; then comp="2026-01-01T00:00:00Z"; else
      comp=$(_iso_ago "$mins") || { printf 'FAIL %-20s date(1) could not build a timestamp %s minutes ago — vacuous arm\n' "$lbl" "$mins"; fails=$((fails+1)); return; }
    fi
    o=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_REPO="" GH_STUB_BREAK="$brk" \
         GH_STUB_COMPLETED="$comp" GH_STUB_BEHIND="$beh" GH_STUB_AHEAD=2 \
         bash "$SELF" 42 acme/widget 2>/dev/null ); r=$?
    l=$(printf '%s\n' "$o" | tail -1)
    if [ "$r" != 0 ] || case "$l" in MERGEABLE:*) false;; *) true;; esac; then
      printf 'FAIL %-20s exit=%s (want 0) | tail -1: %s (want a MERGEABLE verdict — the leading token must survive every annotation)\n' "$lbl" "$r" "$l"; fails=$((fails+1)); return
    fi
    if case "$l" in *"$must"*) false;; *) true;; esac; then
      printf 'FAIL %-20s tail -1: %s (does NOT contain: %s)\n' "$lbl" "$l" "$must"; fails=$((fails+1)); return
    fi
    if [ -n "$mustnot" ] && case "$l" in *"$mustnot"*) true;; *) false;; esac; then
      printf 'FAIL %-20s tail -1: %s (must NOT contain: %s)\n' "$lbl" "$l" "$mustnot"; fails=$((fails+1)); return
    fi
    printf 'PASS %-20s exit=%s | tail -1: %s\n' "$lbl" "$r" "$l"
  }
  # STALE: 120 min old AND 5 commits behind. Exact wording, because pr-watch.sh and bp-merge.sh
  # read the tail and a lead reads the words.
  _age_arm "stale verdict"  120 5 "" "commits behind - update-branch before merging)" ""
  # FRESH: 5 min old but STILL 5 behind — NOT stale. Without this arm, an annotation that fired
  # on "behind" alone would look correct: every merge candidate in this repo is behind something.
  _age_arm "fresh not stale"  5 5 "" "commit(s) behind main]" "STALE VERDICT"
  # UP TO DATE: 120 min old but 0 behind — NOT stale. The other half of the AND.
  _age_arm "in-sync not stale" 120 0 "" "0 commit(s) behind main]" "STALE VERDICT"
  # A FAILED COMPARE IS NOT ZERO. The whole point of the block: an unreadable compare must not
  # render as "0 commits behind", which reads as "nothing moved, go ahead".
  # The must-NOT needle is the PLAIN annotation's own shape, " commit(s) behind ". Do NOT use the
  # literal "0 commits behind" here: the honest refusal deliberately contains the words "not 0
  # commits behind", so that needle reds the very sentence it is meant to protect (measured).
  _age_arm "compare unreadable" 120 5 compare "CANNOT READ" " commit(s) behind "
  # ...and the indented detail line must say so too, in its own words.
  out=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_REPO="" GH_STUB_BREAK=compare \
         GH_STUB_COMPLETED="$(_iso_ago 120)" GH_STUB_BEHIND=5 bash "$SELF" 42 acme/widget 2>/dev/null )
  if printf '%s\n' "$out" | grep -qE '^  VERDICT AGE: CANNOT READ'; then
    printf 'PASS %-20s the detail line refuses too, above the verdict\n' "cannot-read detail"
  else
    printf 'FAIL %-20s no "  VERDICT AGE: CANNOT READ" line in the output\n' "cannot-read detail"; fails=$((fails+1))
  fi
  # ------------------------------- THE MUTATION CONTROL for the stale arm ----------------
  # "stale verdict" above asserts a string is present. That is only worth something if a build
  # WITHOUT the clause fails it — otherwise it is an assertion with no subject. This arm removes
  # the clause from a COPY of this very file and proves the stale fixture then produces a
  # MERGEABLE line with no STALE VERDICT in it. It also refuses if the mutation changed nothing
  # (a stale probe) or broke the script outright (a mutant that cannot verdict proves nothing).
  _mutation_arm() {
    local lbl="mutation reds stale" m o r l comp
    m="$d/mutant-pr-required.sh"
    sed 's/^    STALE_ANN=" (STALE VERDICT:.*$/    STALE_ANN=""/' "$SELF" > "$m" 2>/dev/null
    if [ ! -s "$m" ] || cmp -s "$m" "$SELF"; then
      printf 'FAIL %-20s the mutation changed NOTHING — this control measures nothing; the sed probe is stale\n' "$lbl"; fails=$((fails+1)); return
    fi
    comp=$(_iso_ago 120) || { printf 'FAIL %-20s date(1) unusable — vacuous arm\n' "$lbl"; fails=$((fails+1)); return; }
    o=$( cd "$d/norepo" && PATH="$d/bin:$PATH" GH_REPO="" GH_STUB_BREAK="" \
         GH_STUB_COMPLETED="$comp" GH_STUB_BEHIND=5 GH_STUB_AHEAD=2 \
         bash "$m" 42 acme/widget 2>/dev/null ); r=$?
    l=$(printf '%s\n' "$o" | tail -1)
    case "$l" in
      *"STALE VERDICT"*)
        printf 'FAIL %-20s the mutant STILL printed STALE VERDICT — the stale arm passes with the clause gone, so it is not load-bearing\n' "$lbl"; fails=$((fails+1));;
      MERGEABLE:*)
        printf 'PASS %-20s clause removed -> stale arm would red | mutant tail: %s\n' "$lbl" "$l";;
      *)
        printf 'FAIL %-20s mutant produced no MERGEABLE verdict (exit=%s, tail: %s) — it broke the script, so it says nothing about the clause\n' "$lbl" "$r" "$l"; fails=$((fails+1));;
    esac
  }
  _mutation_arm
  # ---------------------------------------------- arms 8-9: THE STALE-HEAD GUARD, BOTH PATHS ----
  # The v3 guard only runs when `git fetch origin <branch>` SUCCEEDS, so these two arms need a
  # REAL branch: a bare repo with a pushed branch, and a cwd repo whose origin is that bare repo.
  # The stub then reports a DIFFERENT GraphQL head, which forces the guard into its divergence
  # limb, where exactly two outcomes are legal and they must stay distinct:
  #   arm 8  the REST re-read itself FAILS      -> HEAD-READ-FAILED  (exit 3)
  #   arm 9  REST re-read AGREES with GraphQL   -> STALE-PR-OBJECT   (exit 3)
  # Before 2026-09-13 NEITHER path had an arm, and a wrong guard collapsing them shipped inside
  # the hour. A mutation that makes one path print the other's line must red exactly one of these
  # while arm 6 ("genuine 0/4") stays green — arm 6 is the control that stops a widened guard from
  # turning every read into a refusal.
  cat > "$d/bin2/gh" <<'STUB2'
#!/usr/bin/env bash
# Stub gh for the stale-head arms. It answers the compare endpoint with the RAW API object and
# applies --jq to it the way gh does (see _gh_stub_compare in the first stub).
_gh_stub_compare() {
  local j f="" nx=0 x
  j="{\"status\":\"behind\",\"ahead_by\":${GH_STUB_AHEAD:-1},\"behind_by\":${GH_STUB_BEHIND:-0},\"total_commits\":${GH_STUB_AHEAD:-1}}"
  for x in "$@"; do
    [ "$nx" = 1 ] && { f="$x"; break; }
    [ "$x" = "--jq" ] && nx=1
  done
  if [ -n "$f" ]; then printf '%s\n' "$j" | jq -r "$f"; else printf '%s\n' "$j"; fi
}
# Original note: Every call is appended to $GH_STUB_LOG, so an arm can PROVE
# the stub was actually reached (a fixture that never reaches the code under test is a green with
# no subject). The .head.sha answers come from a FILE-BACKED counter: the script runs each read
# inside its own $( ) subshell, so an in-shell counter is always zero and would hand back a
# perfect-looking bound that measured nothing. GH_STUB_RESTSHAS is a space-separated list, one
# entry per successive .head.sha read; the literal FAIL makes that read exit non-zero.
[ -n "${GH_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_STUB_LOG"
if [ "${1:-} ${2:-}" = "pr view" ]; then printf '%s\n' "${GH_STUB_GQL_SHA:-}"; exit 0; fi
if [ "${1:-}" = api ]; then
  case " $* " in
    */compare/*)    _gh_stub_compare "$@"; exit 0;;
    *" .base.ref"*) printf '%s\n' "${GH_STUB_BASE:-main}"; exit 0;;
    *" .head.ref"*) printf '%s\n' "${GH_STUB_BRANCH:-}"; exit 0;;
    *" .head.sha"*)
      n=0; [ -s "${GH_STUB_CTR:-}" ] && n=$(cat "$GH_STUB_CTR")
      n=$((n+1)); [ -n "${GH_STUB_CTR:-}" ] && printf '%s' "$n" > "$GH_STUB_CTR"
      i=0
      for s in ${GH_STUB_RESTSHAS:-}; do
        i=$((i+1))
        if [ "$i" = "$n" ]; then
          [ "$s" = FAIL ] && exit 1
          printf '%s\n' "$s"; exit 0
        fi
      done
      exit 1;;
    *mergeable_state*) echo clean; exit 0;;
    */check-runs*) printf '%s\n' \
        "Cloud gate	completed	success	2026-01-01T00:00:00Z	2026-01-01T00:00:00Z" \
        "Console gate	completed	success	2026-01-01T00:00:00Z	2026-01-01T00:00:00Z" \
        "Elixir gate	completed	success	2026-01-01T00:00:00Z	2026-01-01T00:00:00Z" \
        "PR references an active task	completed	success	2026-01-01T00:00:00Z	2026-01-01T00:00:00Z"
      exit 0;;
  esac
fi
exit 0
STUB2
  chmod +x "$d/bin2/gh"
  # Fixture: bare repo + pushed branch + a cwd repo that can fetch it. If ANY of this fails the
  # arms are vacuous, so the failure is loud and counts as an assertion failure.
  _stale_fixture() {
    git init -q --bare "$d/bare.git" >/dev/null 2>&1 || return 1
    git init -q "$d/wk" >/dev/null 2>&1 || return 1
    git -C "$d/wk" -c user.email=selftest@example.invalid -c user.name=selftest \
        commit -q --allow-empty -m seed >/dev/null 2>&1 || return 1
    git -C "$d/wk" remote add origin "$d/bare.git" >/dev/null 2>&1 || return 1
    git -C "$d/wk" push -q origin HEAD:refs/heads/stale-branch >/dev/null 2>&1 || return 1
    git init -q "$d/cwd" >/dev/null 2>&1 || return 1
    git -C "$d/cwd" remote add origin "$d/bare.git" >/dev/null 2>&1 || return 1
    REALSHA=$(git -C "$d/wk" rev-parse HEAD 2>/dev/null) || return 1
    [ -n "$REALSHA" ] || return 1
  }
  _stale_arm() { # id  label  restsha-list  expected-LAST-line-prefix
    local id="$1" lbl="$2" shas="$3" want="$4" o r l ctr log
    ctr="$d/ctr.$id"; log="$d/log.$id"; : > "$ctr"; : > "$log"
    o=$( cd "$d/cwd" && PATH="$d/bin2:$PATH" GH_REPO="" \
         GH_STUB_LOG="$log" GH_STUB_CTR="$ctr" GH_STUB_BRANCH=stale-branch \
         GH_STUB_GQL_SHA=bbbbbbbbbb11112222333344445555666677778888 \
         GH_STUB_RESTSHAS="$shas" bash "$SELF" 42 acme/widget 2>/dev/null ); r=$?
    l=$(printf '%s\n' "$o" | tail -1)
    if [ "$r" = 3 ] && case "$l" in "$want"*) true;; *) false;; esac; then
      printf 'PASS %-20s exit=%s | tail -1: %s\n' "$lbl" "$r" "$l"
    else
      printf 'FAIL %-20s exit=%s (want 3) | tail -1: %s (want prefix %s)\n' "$lbl" "$r" "$l" "$want"; fails=$((fails+1))
    fi
    # The fixture must have REACHED the guard, or the arm proved nothing: the branch read and at
    # least one head-sha read must both appear in the stub's own call log.
    if ! grep -q '\.head\.ref' "$log" || ! grep -q '\.head\.sha' "$log"; then
      printf 'FAIL %-20s stub NOT reached (no .head.ref / .head.sha call logged) — vacuous arm\n' "$lbl"; fails=$((fails+1))
    fi
    # A refusal must never carry a count it did not measure.
    case "$o" in *0/4*) printf 'FAIL %-20s the string 0/4 appears in a refusal\n' "$lbl"; fails=$((fails+1));; esac
    STALE_TAIL="$l"
  }
  if _stale_fixture; then
    _stale_arm rf "head-read-failed" "FAIL"       "HEAD-READ-FAILED"; STALE_A="$STALE_TAIL"
    _stale_arm sp "stale both reads" "cccccccccc11112222333344445555666677778888" "STALE-PR-OBJECT"; STALE_B="$STALE_TAIL"
    # The two refusals must not be byte-identical to each other: a collapse that makes one path
    # emit the other's text would otherwise pass both prefix checks in one direction.
    if [ "$STALE_A" = "$STALE_B" ]; then
      printf 'FAIL %-20s the read-failure and mismatch refusals are byte-identical\n' "refusals distinct"; fails=$((fails+1))
    else
      printf 'PASS %-20s the two refusals differ\n' "refusals distinct"
    fi
    # ------------------------------- ARM 11: THE SELF-HEAL OUTCOME — the guard's THIRD limb ----
    # The divergence limb has THREE outcomes, not two. Arms 8 and 9 cover the two REFUSALS. The
    # one that actually executes on nearly every call during a GraphQL wobble is the third: the
    # REST re-read AGREES with origin/<branch>, so the GraphQL read was the flake, the script
    # ADOPTS the REST sha and CONTINUES to an ordinary verdict. Until 2026-09-14 it had no arm,
    # and an unarmed success path is how a guard silently stops guarding: a change making
    # self-heal fall through to a refusal, AND a change making it keep the STALE sha and then
    # render a verdict about a commit the merge will not merge, BOTH passed the whole suite.
    # The second is the dangerous one — describing the wrong commit is the exact thing this
    # guard exists to prevent, and it would have said MERGEABLE while doing it.
    # This arm asserts three things, and needs all three:
    #   (a) CONTINUES — the tail is a verdict at exit 0, not a refusal at exit 3;
    #   (b) the verdict is computed against the BRANCH sha. GH_STUB_GQL_SHA is bbbbbbbbbb…,
    #       a value no git repo can produce, so adopting the stale sha is VISIBLE in the tail
    #       and the comparison is exact, not a prefix — a run that continues with the stale
    #       value reds here even though it "continued" correctly;
    #   (c) the guard was ENTERED and then LEFT FORWARD. Without (c) this arm would pass on any
    #       healthy read that never reached the guard at all — a green with no subject — so the
    #       stub's own call log must hold the .head.ref read and the .head.sha RE-read (entry)
    #       and the post-guard mergeable_state and check-runs calls (forward exit). Entry and
    #       forward-exit get DISTINCT failure messages so a vacuity control says which half died.
    _selfheal_arm() {
      local o r l ctr log want lbl="self-heal continues"
      ctr="$d/ctr.sh"; log="$d/log.sh"; : > "$ctr"; : > "$log"
      want="MERGEABLE: 4/4 required green on ${REALSHA:0:10}"
      o=$( cd "$d/cwd" && PATH="$d/bin2:$PATH" GH_REPO="" \
           GH_STUB_LOG="$log" GH_STUB_CTR="$ctr" GH_STUB_BRANCH=stale-branch \
           GH_STUB_GQL_SHA=bbbbbbbbbb11112222333344445555666677778888 \
           GH_STUB_RESTSHAS="$REALSHA" bash "$SELF" 42 acme/widget 2>/dev/null ); r=$?
      l=$(printf '%s\n' "$o" | tail -1)
      # PREFIX, not equality, since 2026-09-20: the verdict line now carries a verdict-age
      # annotation whose minute count is wall-clock derived. The sha assertion is UNWEAKENED —
      # "$want" ends in the full 10-char sha prefix, and bbbbbbbbbb cannot match it — and the
      # second check pins the annotation's own content, so nothing here got looser.
      if [ "$r" = 0 ] && case "$l" in "$want"*) true;; *) false;; esac \
         && case "$l" in *"0 commit(s) behind main]"*) true;; *) false;; esac; then
        printf 'PASS %-20s exit=%s | tail -1: %s\n' "$lbl" "$r" "$l"
      else
        printf 'FAIL %-20s exit=%s (want 0) | tail -1: %s (want prefix: %s plus a "0 commit(s) behind main]" annotation — a refusal here means self-heal fell through; the sha bbbbbbbbbb means it adopted the STALE value and is describing a commit that is not the branch)\n' "$lbl" "$r" "$l" "$want"; fails=$((fails+1))
      fi
      if ! grep -q '\.head\.ref' "$log" || ! grep -q '\.head\.sha' "$log"; then
        printf 'FAIL %-20s self-heal arm never ENTERED the guard (no .head.ref / .head.sha re-read logged) — vacuous arm, its verdict measured nothing\n' "$lbl"; fails=$((fails+1))
      elif ! grep -q 'mergeable_state' "$log" || ! grep -q 'check-runs' "$log"; then
        printf 'FAIL %-20s self-heal arm ENTERED the guard but never LEFT IT FORWARD (no mergeable_state / check-runs call logged) — the tail did not come from the adopted sha\n' "$lbl"; fails=$((fails+1))
      fi
    }
    _selfheal_arm
    # ARM 10 — the FETCH_HEAD race itself, in BOTH directions under the SAME interleaving.
    # This is the arm the previous two fixes lacked: it proves the OLD form is racy rather than
    # merely asserting the new one works, so a future edit back to FETCH_HEAD reds here.
    if git -C "$d/wk" -c user.email=selftest@example.invalid -c user.name=selftest \
           commit -q --allow-empty -m other >/dev/null 2>&1 \
       && git -C "$d/wk" push -q origin HEAD:refs/heads/other-branch >/dev/null 2>&1; then
      OTHERSHA=$(git -C "$d/wk" rev-parse HEAD 2>/dev/null)
      # OLD FORM: fetch our branch, read FETCH_HEAD, let another fetch interleave, read again.
      git -C "$d/cwd" fetch -q origin stale-branch >/dev/null 2>&1
      _o1=$(git -C "$d/cwd" rev-parse FETCH_HEAD 2>/dev/null || true)
      git -C "$d/cwd" fetch -q origin other-branch >/dev/null 2>&1
      _o2=$(git -C "$d/cwd" rev-parse FETCH_HEAD 2>/dev/null || true)
      # NEW FORM: same interleaving, but each fetch writes its OWN tracking ref.
      git -C "$d/cwd" fetch -q origin stale-branch:refs/remotes/origin/stale-branch >/dev/null 2>&1
      _n1=$(git -C "$d/cwd" rev-parse refs/remotes/origin/stale-branch 2>/dev/null || true)
      git -C "$d/cwd" fetch -q origin other-branch:refs/remotes/origin/other-branch >/dev/null 2>&1
      _n2=$(git -C "$d/cwd" rev-parse refs/remotes/origin/stale-branch 2>/dev/null || true)
      if [ -z "$_o1" ] || [ -z "$_n1" ] || [ -z "$OTHERSHA" ] || [ "$REALSHA" = "$OTHERSHA" ]; then
        printf 'FAIL %-20s fixture did not produce two distinct branches — vacuous arm\n' "fetch-head race"; fails=$((fails+1))
      elif [ "$_o1" = "$_o2" ]; then
        printf 'FAIL %-20s OLD form did not race (FETCH_HEAD unchanged across an intervening fetch) — arm proves nothing\n' "fetch-head race"; fails=$((fails+1))
      elif [ "$_n1" != "$_n2" ] || [ "$_n1" != "$REALSHA" ]; then
        printf 'FAIL %-20s NEW form is NOT immune: tracking ref moved %s -> %s (want %s)\n' "fetch-head race" "$_n1" "$_n2" "$REALSHA"; fails=$((fails+1))
      else
        printf 'PASS %-20s OLD FETCH_HEAD form races (%s -> %s), tracking-ref form immune (%s)\n' "fetch-head race" "${_o1%%${_o1#??????}}" "${_o2%%${_o2#??????}}" "${_n1%%${_n1#??????}}"
      fi
      # Arm 10 above proves WHY the tracking ref is the right read. This pins that the GUARD
      # still uses it: arm 10 exercises git, not this script, so a revert of the guard alone
      # would leave it green. Together they cover both halves.
      # Assert the guard's assignment POSITIVELY. A negative probe cannot work here: arm 10
      # deliberately contains the racy form to demonstrate it, and the probe LINE ITSELF would
      # contain its own needle — two self-matches in one block. A positive check cannot self-match.
      _guard=$(grep -E '^    _REAL=' "$SELF" | head -1)
      case "$_guard" in
        *"refs/remotes/origin/"*)
          printf 'PASS %-20s guard reads the tracking ref, not FETCH_HEAD\n' "guard uses ref" ;;
        "")
          printf 'FAIL %-20s could not find the guard assignment to check — probe is stale\n' "guard uses ref"; fails=$((fails+1)) ;;
        *)
          printf 'FAIL %-20s guard assignment is not the tracking ref: %s\n' "guard uses ref" "$_guard"; fails=$((fails+1)) ;;
      esac
    else
      printf 'FAIL %-20s could not create the second branch — arm 10 did not run\n' "fetch-head race"; fails=$((fails+1))
    fi
    # --------------- ARM 12: THE FETCH HALF. The refspec is what CREATES the tracking ref. ----
    # Arm 10 ("fetch-head race") and "guard uses ref" were shipped as covering "different halves"
    # of the v4 fix. They do not: BOTH cover the READ half. Measured 2026-09-14 — reverting ONLY
    # the fetch refspec on the `if git fetch` line, leaving the tracking-ref READ intact, left the
    # whole suite at 13/13 EXIT 0 with both of those arms green. The suite could not see the
    # refspec at all.
    # It passes in a plain fixture only because `git remote add` writes the default
    # `+refs/heads/*:refs/remotes/origin/*` and git then updates the tracking ref opportunistically.
    # Strip that default — which a bare `git init` + hand-written remote, a mirror clone, or a
    # `remote.origin.fetch` someone narrowed all do — and a plain `git fetch origin <branch>` exits
    # 0 having created NO ref. Then `git rev-parse` on a MISSING ref ECHOES THE REF NAME ON STDOUT
    # (measured: `_REAL=[refs/remotes/origin/b1]`) while `|| true` swallows the non-zero, so _REAL
    # becomes a literal string that can never equal a sha, and the guard prints a FALSE
    # STALE-PR-OBJECT on a PR that is perfectly in sync. The immunity is ONE LINE deep.
    # This arm is BEHAVIOURAL and it asserts POSITIVELY, twice:
    #   (a) in a no-default-refspec repo, with GraphQL and the branch AGREEING, the script must
    #       reach an ordinary verdict on the branch sha — a refusal here is the false STALE-PR-OBJECT;
    #   (b) the tracking ref must EXIST at the branch sha AFTER the run. The fixture never creates
    #       it, so only the script's own refspec can have. That is the fetch half, and no static
    #       grep of the read line can stand in for it.
    _refspec_arm() {
      local o r l log want lbl="fetch creates ref" ref
      log="$d/log.rs"; : > "$log"
      want="MERGEABLE: 4/4 required green on ${REALSHA:0:10}"
      # Fixture: origin with NO default fetch refspec, and NO tracking ref of its own.
      rm -rf "$d/cwdnr"; git init -q "$d/cwdnr" >/dev/null 2>&1
      git -C "$d/cwdnr" remote add origin "$d/bare.git" >/dev/null 2>&1
      git -C "$d/cwdnr" config --unset-all remote.origin.fetch >/dev/null 2>&1
      if [ -n "$(git -C "$d/cwdnr" config --get-all remote.origin.fetch 2>/dev/null)" ] \
         || git -C "$d/cwdnr" rev-parse --verify -q refs/remotes/origin/stale-branch >/dev/null 2>&1; then
        printf 'FAIL %-20s fixture still has a default refspec or a pre-made tracking ref — arm would pass without the refspec\n' "$lbl"; fails=$((fails+1)); return
      fi
      # GraphQL AGREES with the branch: with a working refspec there is no divergence at all.
      o=$( cd "$d/cwdnr" && PATH="$d/bin2:$PATH" GH_REPO="" \
           GH_STUB_LOG="$log" GH_STUB_CTR="$d/ctr.rs" GH_STUB_BRANCH=stale-branch \
           GH_STUB_GQL_SHA="$REALSHA" GH_STUB_RESTSHAS="$REALSHA" \
           bash "$SELF" 42 acme/widget 2>/dev/null ); r=$?
      l=$(printf '%s\n' "$o" | tail -1)
      if [ "$r" = 0 ] && case "$l" in "$want"*) true;; *) false;; esac \
         && case "$l" in *"0 commit(s) behind main]"*) true;; *) false;; esac; then
        printf 'PASS %-20s exit=%s | tail -1: %s\n' "$lbl" "$r" "$l"
      else
        printf 'FAIL %-20s exit=%s (want 0) | tail -1: %s (want prefix: %s plus a "0 commit(s) behind main]" annotation — a STALE-PR-OBJECT here is the FALSE refusal a plain `git fetch origin <branch>` produces when no default refspec creates the tracking ref)\n' "$lbl" "$r" "$l" "$want"; fails=$((fails+1))
      fi
      ref=$(git -C "$d/cwdnr" rev-parse refs/remotes/origin/stale-branch 2>/dev/null || true)
      if [ "$ref" != "$REALSHA" ]; then
        printf 'FAIL %-20s the script did not CREATE refs/remotes/origin/stale-branch (read back [%s], want %s) — the fetch refspec is gone, so the read half has nothing to read\n' "$lbl" "$ref" "$REALSHA"; fails=$((fails+1))
      fi
      if ! grep -q '\.head\.ref' "$log"; then
        printf 'FAIL %-20s stub NOT reached (no .head.ref call logged) — vacuous arm\n' "$lbl"; fails=$((fails+1))
      fi
    }
    _refspec_arm
    # ------------- ARM 13: THE `+`. Without it the guard SILENTLY STOPS RUNNING after a rebase. ----
    # `git fetch origin "<br>:refs/remotes/origin/<br>"` is a NON-FORCED refspec. On a
    # non-fast-forward update — i.e. EVERY rebase force-push, the most common PR event in this
    # campaign — it EXITS 1 and leaves the tracking ref at the OLD sha (measured: rc=1, tracking
    # unchanged). The script wraps that in `if git fetch …; then`, so a false there SKIPS THE WHOLE
    # GUARD. It fails OPEN: no refusal, no error, no line anywhere, and the stale-head check that
    # exists to stop a verdict about the wrong commit simply is not running. The fix is one
    # character, `+`, and the only thing that can hold it is an arm that fails without it.
    # Fixture makes the update genuinely non-fast-forward: the tracking ref is pre-pointed at
    # other-branch (a DESCENDANT of stale-branch), so moving it back to stale-branch is a rewind.
    # The precondition is ASSERTED, not assumed — a fixture that quietly produced a fast-forward
    # would make this arm green for the wrong reason.
    _force_arm() {
      local o r l log want lbl="forced refspec" pre post
      log="$d/log.ff"; : > "$log"
      want="MERGEABLE: 4/4 required green on ${REALSHA:0:10}"
      if [ -z "${OTHERSHA:-}" ] || [ "$OTHERSHA" = "$REALSHA" ]; then
        printf 'FAIL %-20s no second branch to rewind from — arm 13 cannot build a non-ff update\n' "$lbl"; fails=$((fails+1)); return
      fi
      rm -rf "$d/cwdff"; git init -q "$d/cwdff" >/dev/null 2>&1
      git -C "$d/cwdff" remote add origin "$d/bare.git" >/dev/null 2>&1
      git -C "$d/cwdff" config --unset-all remote.origin.fetch >/dev/null 2>&1
      git -C "$d/cwdff" fetch -q origin "other-branch:refs/remotes/origin/stale-branch" >/dev/null 2>&1
      pre=$(git -C "$d/cwdff" rev-parse refs/remotes/origin/stale-branch 2>/dev/null || true)
      if [ "$pre" != "$OTHERSHA" ]; then
        printf 'FAIL %-20s precondition failed: tracking ref is [%s], want the DESCENDANT %s — the update under test would not be non-ff\n' "$lbl" "$pre" "$OTHERSHA"; fails=$((fails+1)); return
      fi
      # GraphQL is stale, so the guard must run, self-heal off the REST read, and verdict on the
      # BRANCH sha. If the fetch is unforced it exits 1, the guard is skipped entirely, and the
      # tail carries the STALE GraphQL sha instead — visibly, because it is bbbbbbbbbb….
      o=$( cd "$d/cwdff" && PATH="$d/bin2:$PATH" GH_REPO="" \
           GH_STUB_LOG="$log" GH_STUB_CTR="$d/ctr.ff" GH_STUB_BRANCH=stale-branch \
           GH_STUB_GQL_SHA=bbbbbbbbbb11112222333344445555666677778888 \
           GH_STUB_RESTSHAS="$REALSHA" bash "$SELF" 42 acme/widget 2>/dev/null ); r=$?
      l=$(printf '%s\n' "$o" | tail -1)
      post=$(git -C "$d/cwdff" rev-parse refs/remotes/origin/stale-branch 2>/dev/null || true)
      if [ "$r" = 0 ] && case "$l" in "$want"*) true;; *) false;; esac \
         && case "$l" in *"0 commit(s) behind main]"*) true;; *) false;; esac; then
        printf 'PASS %-20s exit=%s | tail -1: %s\n' "$lbl" "$r" "$l"
      else
        printf 'FAIL %-20s exit=%s (want 0) | tail -1: %s (want prefix: %s plus a "0 commit(s) behind main]" annotation — the stale sha bbbbbbbbbb means the non-forced fetch exited 1 and the guard was SKIPPED, failing OPEN)\n' "$lbl" "$r" "$l" "$want"; fails=$((fails+1))
      fi
      if [ "$post" != "$REALSHA" ]; then
        printf 'FAIL %-20s tracking ref did not move across the non-ff update: [%s] -> [%s], want %s — the refspec is missing its leading +\n' "$lbl" "$pre" "$post" "$REALSHA"; fails=$((fails+1))
      fi
    }
    _force_arm
  else
    printf 'FAIL %-20s could not build the bare-repo/branch fixture — arms 8-9 did not run\n' "stale fixture"; fails=$((fails+1))
  fi
  # ----------------------------- ARM: THE MIRROR. TWO copies of this file live in this repo ----
  # scripts/pr-required.sh is CANONICAL — vendored 2026-09-16 (#18469) and the copy merge-check.sh
  # resolves. .claude/skills/orchestrate-tasks/helpers/pr-required.sh is a MIRROR: pr-watch.sh and
  # merge-sweep.sh each resolve "pr-required.sh beside this file", so THEY run the mirror. Nothing
  # compared the two, and the mirror silently lagged from 2026-09-16 to 2026-09-20 — 187 lines
  # against 543, i.e. it had no stale-head guard AT ALL — so the campaign's own watchers were
  # running a materially different tool from the one the merge gate ran. Two copies diverge in
  # BOTH directions the moment nothing measures them. This arm is that measurement.
  # When this copy is NOT inside a checkout holding both files (the arms run copies out of a temp
  # dir; leads run a scratchpad copy) it prints NOTE, not PASS: the tally counts only PASS/FAIL
  # lines, so an un-run comparison cannot inflate the score into a green that measured nothing.
  _mirror_arm() {
    local lbl="mirror in sync" top a b
    top=$(git -C "$SELFDIR" rev-parse --show-toplevel 2>/dev/null || true)
    a="$top/scripts/pr-required.sh"
    b="$top/.claude/skills/orchestrate-tasks/helpers/pr-required.sh"
    if [ -z "$top" ] || [ ! -f "$a" ] || [ ! -f "$b" ]; then
      printf 'NOTE %-20s NOT RUN: this copy is not inside a checkout holding both copies (toplevel: %s) — the mirror was NOT compared\n' "$lbl" "${top:-none}"
      return
    fi
    if cmp -s "$a" "$b"; then
      printf 'PASS %-20s the two repo copies are byte-identical\n' "$lbl"
    else
      printf 'FAIL %-20s scripts/pr-required.sh and .claude/skills/orchestrate-tasks/helpers/pr-required.sh DIFFER — merge-check.sh and the watchers are running different tools. Re-sync with: cp scripts/pr-required.sh .claude/skills/orchestrate-tasks/helpers/pr-required.sh\n' "$lbl"; fails=$((fails+1))
    fi
  }
  _mirror_arm
  rm -rf "$d"
  return "$fails"
}

# The tally is DERIVED from the PASS/FAIL lines the run actually emitted, never pinned. The old
# literal "9/9" was already wrong before arm 10 existed — it printed 9 while ten arms ran — which
# is the same class of fault this script exists to catch: a count that cannot disagree with what
# happened. A floor refuses a run that emitted almost nothing, so a body that dies early cannot
# report a clean tally.
selftest() {
  local out rc total passed failed
  out=$(_selftest_body 2>&1); rc=$?
  printf '%s\n' "$out"
  total=$(printf '%s\n' "$out" | grep -cE '^(PASS|FAIL) ')
  passed=$(printf '%s\n' "$out" | grep -cE '^PASS ')
  failed=$(printf '%s\n' "$out" | grep -cE '^FAIL ')
  if [ "$total" -lt 14 ]; then
    echo "SELFTEST: CANNOT READ — only $total arm line(s) emitted; the body exited early and this tally measures nothing"
    return 1
  fi
  if [ "$rc" = 0 ] && [ "$failed" = 0 ]; then echo "SELFTEST: $passed/$total arms pass"; return 0; fi
  echo "SELFTEST: $failed of $total arm(s) FAILED"; return 1
}
[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }
PR="${1:?pr number}"
# RESOLVING owner/repo. `gh repo view --json` goes over GraphQL (its own per-user budget, which
# empties long before REST does) AND is resolved from the CALLER'S cwd — which resets between tool
# calls in this harness. Either failure yields an EMPTY $REPO, every URL below becomes "repos//…"
# which 404s, and this script printed "0/4" for a PR that was at 3/4 (measured 2026-09-02).
# The campaign's own LEAD-BRIEF tells leads to call this with NO repo argument, so the cwd trigger
# is live on every such call and needs no GraphQL outage to fire. Resolve cheapest-and-most-
# reliable first, GraphQL LAST:
#   1. arg 2   2. $GH_REPO   3. git remote of the dir this SCRIPT lives in (no network, no GraphQL,
#   cwd-independent)   4. git remote of the cwd   5. gh repo view (GraphQL) — and refuse if none.
_repo_from_git() { # $1 = directory to ask; prints owner/repo, or nothing
  local url
  url=$(git -C "$1" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$url" ] || return 0
  url="${url%.git}"; url="${url%/}"       # git@host:OWNER/REPO.git | https://host/OWNER/REPO.git | ssh://git@host/OWNER/REPO
  case "$url" in *[:/]*/*) printf '%s/%s\n' "$(basename "$(dirname "$url")")" "$(basename "$url")";; esac
}
REPO="${2:-}"
[ -n "$REPO" ] || REPO="${GH_REPO:-}"
[ -n "$REPO" ] || REPO=$(_repo_from_git "$SELFDIR")
[ -n "$REPO" ] || REPO=$(_repo_from_git ".")
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -z "$REPO" ]; then
  echo "CANNOT READ: no owner/repo — pass it as arg 2 (or set GH_REPO). No git remote at this script's own directory or at the cwd, and gh repo view (GraphQL) failed too. This is NOT a verdict, and NOT a count of zero green."
  exit 3
fi
REQ='Elixir gate|PR references an active task|Cloud gate|Console gate'
# READ THE HEAD SHA, AND REFUSE IF IT CANNOT BE READ (lead-silent, 2026-09-02).
# `gh pr view --json` goes over GraphQL, which has its OWN per-user limit that empties long
# before REST does — `gh api rate_limit` can report graphql 5000/5000 remaining while every
# gh pr view returns "API rate limit already exceeded for user ID". When that happened, SHA
# went EMPTY, the check-runs URL became .../commits//check-runs and 404'd, RUNS was empty, and
# this script printed "NOT YET: 0/4 required green on " AND EXITED 0. A failed read was
# byte-identical to "nothing is green" for every one of the eighteen lanes reading `| tail -1`,
# and the merge sweep would have stalled the whole campaign without one error anyone could see.
# So: fall back to REST (which still works when GraphQL is spent), and if BOTH fail, REFUSE on
# the LAST line with a non-zero exit rather than reporting a number we did not measure.
SHA=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null || true)

# STALE-PR-OBJECT GUARD, v3. v1 refused on one divergent read; v2 read twice — gates then
# measured v2 STILL refusing on #18181 whose heads were IDENTICAL by hand, because BOTH reads
# came from `gh pr view`, i.e. GraphQL, which has been 502-flaky since 09:12Z. Two reads of the
# same flaky source are not independent, and the "TWO reads" wording made a false verdict MORE
# convincing. v3 reads the head over REST, which has been reliable all day, and SELF-HEALS:
# if REST agrees with the branch, the GraphQL value was simply wrong and we continue with REST.
_BR=$(gh api "repos/$REPO/pulls/$PR" --jq .head.ref 2>/dev/null || true)
if [ -n "${_BR:-}" ] && [ -n "${SHA:-}" ]; then
  # v4 (2026-09-13, gates): NEVER read FETCH_HEAD here. It is ONE FILE in .git, last-writer-wins,
  # and every worktree of this repo shares one .git (`git rev-parse --git-common-dir`). Six lanes,
  # the sweep and every worker fetch into it continuously, so any fetch landing between our fetch
  # and our read makes us compare the PR against SOMEBODY ELSE'S BRANCH and declare a mismatch.
  # That — not GraphQL — was the real cause of the false STALE-PR-OBJECT refusals; v2 (a second
  # read) and v3 (confirm over REST) both hardened the reader while the thing it read stayed racy.
  # Fetching into the tracking ref and reading that ref is immune: a concurrent fetch writes a
  # DIFFERENT ref. Proved both directions by selftest arm 10.
  # The leading + is LOAD-BEARING (2026-09-14). Without it this is a NON-FORCED refspec: on a
  # non-fast-forward update — every rebase force-push — git EXITS 1 and leaves the tracking ref
  # at the OLD sha, so this `if` goes false and THE WHOLE GUARD IS SKIPPED. It fails OPEN:
  # no refusal, no error, nothing to notice, and the verdict is rendered against whatever
  # GraphQL said. Selftest arm 13 ("forced refspec") reds if the + is removed.
  if git fetch -q origin "+$_BR:refs/remotes/origin/$_BR" 2>/dev/null; then
    _REAL=$(git rev-parse "refs/remotes/origin/$_BR" 2>/dev/null || true)
    if [ -n "${_REAL:-}" ] && [ "$_REAL" != "$SHA" ]; then
      _RESTSHA=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)
      if [ -z "${_RESTSHA:-}" ]; then
        echo "HEAD-READ-FAILED: REST could not read the PR head — NO VERDICT, re-run this script"
        exit 3
      fi
      if [ "$_RESTSHA" = "$_REAL" ]; then
        SHA="$_RESTSHA"   # GraphQL was stale/flaky; REST agrees with the branch. Self-healed.
      else
        echo "  REST and the branch disagree, so this is not a GraphQL flake:"
        echo "  REST head     : $_RESTSHA"
        echo "  origin/$_BR : $_REAL"
        echo "  A verdict here would describe a commit that is not the branch, while a merge"
        echo "  merges the branch. RE-READ; do NOT close+reopen on one reading."
        echo "STALE-PR-OBJECT: REST head disagrees with origin/$_BR — NO VERDICT (re-read)"
        exit 3
      fi
    fi
  fi
fi
if [ -z "$SHA" ]; then
  SHA=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)
fi
if [ -z "$SHA" ]; then
  echo "CANNOT READ: pr #$PR head sha unreadable over BOTH GraphQL and REST — this is NOT a verdict, and NOT a count of zero green. Check \`gh auth status\` and \`gh api rate_limit\`; GraphQL empties before REST does."
  exit 3
fi
# MERGE STATE: four green checks do NOT mean the PR can merge; a DIRTY branch is refused by GitHub regardless.
# Read mergeable_state over REST (one call) so the LAST LINE never says MERGEABLE for a conflicting branch.
MSTATE=$(gh api "repos/$REPO/pulls/$PR" --jq '.mergeable_state // "-"' 2>/dev/null || echo "-")
if ! RUNS=$(gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" --paginate \
  --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion // "-")\t\(.started_at // "-")\t\(.completed_at // "-")"' 2>/dev/null); then
  echo "CANNOT READ: check-runs for $REPO@${SHA:0:10} could not be fetched — this is NOT a verdict, and NOT a count of zero green."
  exit 3
fi
# A head with ZERO check runs is also not a verdict: CI has not started, or the read was empty
# for a reason we cannot see. Saying "0/4" there is the same lie in a quieter voice.
if [ -z "$RUNS" ]; then
  echo "CANNOT READ: $REPO@${SHA:0:10} has NO check runs at all — CI has not started, or the read came back empty. This is NOT a verdict, and NOT a count of zero green."
  exit 3
fi

# ------------- HOW OLD IS THIS VERDICT, AND HOW FAR HAS THE BASE MOVED UNDER IT? (2026-09-20) --
# A 4/4 is a SNAPSHOT of the check runs on ONE head. It says nothing about WHEN those runs
# concluded or how many commits landed on the base underneath them, and "4/4 that is a day old on
# a head five commits behind main" is exactly the shape that merges something nobody's CI ever
# evaluated (measured on #19458 and #19505, both 5 behind). Every lead re-derived both numbers by
# hand before every merge; the instrument that produced the verdict is where they belong.
# BOTH ARE READ FROM THE API — check-runs `.completed_at`, and the compare endpoint's
# `.behind_by` — never from a local checkout, whose refs every worktree in this repo shares and
# which is routinely behind the branch it would be asked about.
# A FAILED READ IS NOT ZERO. Either half being unreadable prints CANNOT READ and suppresses the
# staleness test entirely, because "0 commits behind" is precisely the reassuring lie this block
# exists to stop: it would read as "freshly verified, nothing has moved".
STALE_MIN="${PR_REQUIRED_STALE_MIN:-60}"
_epoch_utc() { # $1 = ISO-8601 Z timestamp; prints epoch seconds on stdout, or nothing at exit 1
  local e
  e=$(date -u -d "$1" +%s 2>/dev/null) && [ -n "$e" ] && { printf '%s\n' "$e"; return 0; }
  e=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null) && [ -n "$e" ] && { printf '%s\n' "$e"; return 0; }
  return 1
}
AGE_MIN=""; AGE_WHY=""; BEHIND=""; AHEAD=""; BEHIND_WHY=""; BASEREF=""
PLAIN_ANN=""; STALE_ANN=""
# The NEWEST completed_at among the FOUR REQUIRED contexts — not among all check runs, because an
# advisory job re-run five minutes ago would otherwise make a day-old required set look fresh.
NEWEST=$(printf '%s\n' "$RUNS" | grep -E "^($REQ)	" | awk -F'\t' '$5!="-" && $5!=""{print $5}' | sort -r | head -1)
if [ -z "$NEWEST" ]; then
  AGE_WHY="no required check run on this head carries a completed_at (still running, or the field was absent)"
else
  _T_NEW=$(_epoch_utc "$NEWEST" || true)
  _T_NOW=$(date -u +%s 2>/dev/null || true)
  if [ -n "${_T_NEW:-}" ] && [ -n "${_T_NOW:-}" ]; then
    AGE_MIN=$(( (_T_NOW - _T_NEW) / 60 ))
  else
    AGE_WHY="completed_at [$NEWEST] could not be turned into epoch seconds by this host's date(1)"
  fi
fi
BASEREF=$(gh api "repos/$REPO/pulls/$PR" --jq .base.ref 2>/dev/null || true)
if [ -z "$BASEREF" ]; then
  BEHIND_WHY="the PR's base ref could not be read over REST"
else
  # compare/<base>...<head>: behind_by = commits on the BASE that this head does not have, which
  # is the number every lead was computing by hand with merge-base + rev-list --count.
  _CMP=$(gh api "repos/$REPO/compare/$BASEREF...$SHA?per_page=1" \
           --jq '[(.behind_by|tostring),(.ahead_by|tostring)]|join(" ")' 2>/dev/null || true)
  case "$_CMP" in
    [0-9]*" "[0-9]*) BEHIND="${_CMP%% *}"; AHEAD="${_CMP##* }";;
    *) BEHIND_WHY="compare $BASEREF...${SHA:0:10} returned no usable behind_by/ahead_by";;
  esac
fi
if [ -n "$AGE_MIN" ] && [ -n "$BEHIND" ]; then
  echo "  VERDICT AGE (read from the API): newest required completed_at=$NEWEST => $AGE_MIN min old; compare $BASEREF...${SHA:0:10} behind_by=$BEHIND ahead_by=$AHEAD (threshold PR_REQUIRED_STALE_MIN=$STALE_MIN)"
  PLAIN_ANN=" [verdict $AGE_MIN min old, $BEHIND commit(s) behind $BASEREF]"
  if [ "$BEHIND" -ge 1 ] && [ "$AGE_MIN" -gt "$STALE_MIN" ]; then
    STALE_ANN=" (STALE VERDICT: $AGE_MIN min old, $BEHIND commits behind - update-branch before merging)"
  fi
else
  _AGE_CR=""
  [ -z "$AGE_MIN" ] && _AGE_CR="age: ${AGE_WHY:-unknown}"
  [ -z "$BEHIND" ] && _AGE_CR="${_AGE_CR:+$_AGE_CR; }commits behind: ${BEHIND_WHY:-unknown}"
  echo "  VERDICT AGE: CANNOT READ — $_AGE_CR. This is NOT '0 min old' and NOT '0 commits behind'; the staleness test did not run."
  PLAIN_ANN=" [verdict age/commits-behind: CANNOT READ — not 0 min old, not 0 commits behind]"
fi

# EARLY RED, printed BEFORE the verdict: the aggregate "Elixir gate" context stays QUEUED for
# 20+ min while the `Test (Elixir …)` job it depends on has already FAILED. Advisory jobs are
# excluded by name — Format/Boundary/spec-drift are advisory and most api PRs carry one, so
# naming them here would make the line fire on everything and stop discriminating.
printf '%s\n' "$RUNS" | awk -F'\t' '$3=="failure"{print $1}' \
  | grep -viE 'advisory' | grep -vE "^($REQ)$" | sort -u \
  | sed 's/^/  OTHER RED JOB ON THIS HEAD — NOT NECESSARILY THE CAUSE of any required red. A required aggregate refuses only on a job in ITS OWN workflow needs; to find the real cause read the aggregator job log for "NOT IN THE ALLOW-SET: <job>". Job: /'

# ABSENT vs FAILED: a required context with NO check run on this head (its dispatcher was cancelled, or the run
# was evicted) reads as "3/4" exactly like a failing one, and needs the OPPOSITE remedy (re-fire the dispatcher /
# update-branch, not fix the code). Name the absent ones explicitly, before the verdict.
ABSENT=$(printf '%s\n' "$REQ" | tr '|' '\n' | while read -r ctx; do printf '%s\n' "$RUNS" | grep -qF "$ctx	" || printf '%s; ' "$ctx"; done)
# An aggregator's check run is not created until its run is scheduled, so "no check run yet" on a head whose
# workflow run is still queued/in_progress is PENDING, not absent. Only call it ABSENT when nothing is running.
if [ -n "$ABSENT" ]; then
  LIVE=$(gh api "repos/$REPO/actions/runs?head_sha=$SHA&per_page=50" --jq '[.workflow_runs[]|select(.status!="completed")]|length' 2>/dev/null || echo 0)
  if [ "${LIVE:-0}" -gt 0 ]; then echo "  PENDING required context (no check run yet, but $LIVE workflow run(s) still queued/in_progress on this head — wait, do not re-fire): ${ABSENT%; }"; ABSENT=""
  else echo "  ABSENT required context (no check run on this head and nothing running — re-fire with: gh api -X PUT repos/$REPO/pulls/$PR/update-branch): ${ABSENT%; }"; fi
fi
printf '%s\n' "$RUNS" | grep -E "^($REQ)	" | sort -t$'\t' -k1,1 -k4,4r | awk -F'\t' '!seen[$1]++' \
  | awk -F'\t' -v sha="$SHA" -v ms="$MSTATE" -v absent="$ABSENT" -v ann="$PLAIN_ANN" -v stale="$STALE_ANN" 'BEGIN{ok=0;n=0} {n++; printf "%-32s %-12s %s\n",$1,$2,$3; if($3=="success")ok++} END{ a=(ok==4 && stale!="")?stale:ann; if(ok==4 && ms=="dirty") printf "CONFLICTING: 4/4 required green on %s but the branch is DIRTY — rebase before merge%s\n",substr(sha,1,10),ann; else if(ok<4 && absent!="") printf "NOT YET: %d/4 required green on %s (%d ABSENT — re-fire, do not debug)%s\n",ok,substr(sha,1,10),4-n,ann; else printf "%s: %d/4 required green on %s%s\n",(ok==4?"MERGEABLE":"NOT YET"),ok,substr(sha,1,10),a}'
