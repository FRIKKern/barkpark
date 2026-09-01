#!/usr/bin/env bash
#
# already-fixed.test.sh — the harness for the content-not-merged-flag verdict.
#
# FULLY HERMETIC. `git` and `gh` are stubs on PATH driven entirely by files in
# $STUB, so no case can reach the network and none can read the real repo. A
# harness that needs credentials is a harness CI eventually skips (D26).
#
# The cases that matter are the ones that prove the instrument can be WRONG if
# built naively:
#
#   * a PR that reports merged:true while its task text is NOT on main must
#     still verdict ABSENT (case 13) — the entire reason this script exists
#   * origin/main unreadable must exit 2 with a HOLD, never verdict ABSENT
#     (case 11): "I could not look" is not "it is not there"
#   * a failed gh call in --task mode must SAY the PR list is incomplete
#     (case 15), because a short list reads as "nobody did this yet"
#
#   scripts/already-fixed.test.sh

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/already-fixed.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/already-fixed-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "-- $* --"; }

# D37: never read the exit status of `producer | grep -q`. Here-strings only.
has()      { grep -qF -- "$2" <<<"$1"; }
has_re()   { grep -qE -- "$2" <<<"$1"; }
first_line() { head -1 <<<"$1"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"

# ── the git stub ─────────────────────────────────────────────────────────────
# Every behaviour is a file in $STUB, so each case builds its own world.

cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/git-calls.log"
case "${1:-}" in
  fetch)
    exit "$(cat "$STUB/fetch.rc" 2>/dev/null || echo 0)" ;;
  rev-parse)
    case "$*" in
      *--short*) echo "abc1234"; exit 0 ;;
      *) exit "$(cat "$STUB/have-main.rc" 2>/dev/null || echo 0)" ;;
    esac ;;
  show)
    p="${2#origin/main:}"
    if [ -f "$STUB/tree/$p" ]; then cat "$STUB/tree/$p"; exit 0; fi
    echo "fatal: path '$p' does not exist in 'origin/main'" >&2; exit 128 ;;
  grep)
    if [ -s "$STUB/gitgrep.out" ]; then cat "$STUB/gitgrep.out"; exit 0; fi
    exit 1 ;;
  log)
    case "$*" in
      *--grep=*) f="$STUB/log-grep.out" ;;
      *)         f="$STUB/log-S.out" ;;
    esac
    [ -f "$f" ] && cat "$f"
    exit 0 ;;
  remote)
    echo "https://github.com/FRIKKern/barkpark.git"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/git"

# ── the gh stub ──────────────────────────────────────────────────────────────

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/gh-calls.log"
if [ "${1:-}" = "search" ]; then
  [ -f "$STUB/gh-search.rc" ] && exit "$(cat "$STUB/gh-search.rc")"
  cat "$STUB/search.json" 2>/dev/null || echo '[]'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  [ -f "$STUB/gh-list.rc" ] && exit "$(cat "$STUB/gh-list.rc")"
  cat "$STUB/pr-list.json" 2>/dev/null || echo '[]'
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  cat "$STUB/pr-view-$3.txt" 2>/dev/null || exit 1
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"

# fresh_world — a clean $STUB with a default readable origin/main.
fresh_world() {
  STUB="$TMP/w-$1"
  rm -rf "$STUB"
  mkdir -p "$STUB/tree"
  export STUB
}

# run <args...> — captures stdout+stderr and the exit code into OUT / RC.
run() {
  OUT="$("$SCRIPT" "$@" 2>&1)"
  RC=$?
}

echo "== already-fixed.sh — content beats merged:true =="

# ═══ usage errors: exit 2, never a verdict ══════════════════════════════════

section "1-5  usage errors exit 2 and print NO verdict"
fresh_world usage

run
if [ "$RC" = 2 ]; then ok "1  no arguments -> exit 2"; else bad "1  no arguments -> exit $RC (want 2)"; fi
# The usage text QUOTES both verdict strings in its exit table, so the check
# has to be positional: a verdict is only a verdict when it is line 1.
case "$(first_line "$OUT")" in
  "PRESENT on origin/main"|"ABSENT from origin/main")
    bad "1b a usage error opened with a verdict line" ;;
  *) ok "1b a usage error never OPENS with a verdict" ;;
esac

run --no-fetch onlyonepath
if [ "$RC" = 2 ]; then ok "2  path mode with one argument -> exit 2"; else bad "2  got exit $RC (want 2)"; fi

run --frobnicate
if [ "$RC" = 2 ]; then ok "3  unknown flag -> exit 2"; else bad "3  got exit $RC (want 2)"; fi

run --symbol
if [ "$RC" = 2 ]; then ok "4  --symbol with no name -> exit 2"; else bad "4  got exit $RC (want 2)"; fi

run --symbol foo --task task-1234abcd
if [ "$RC" = 2 ]; then ok "5  two modes at once -> exit 2"; else bad "5  got exit $RC (want 2)"; fi

# ═══ path mode ══════════════════════════════════════════════════════════════

section "6-8  path mode reads the origin/main BLOB"
fresh_world path
mkdir -p "$STUB/tree/api/lib"
printf 'defmodule A do\n  def clamp_visibility(x), do: x\nend\n' > "$STUB/tree/api/lib/a.ex"
printf 'deadbeef1 fix(media): clamp the anonymous read (#14127)\n' > "$STUB/log-S.out"

run --no-fetch api/lib/a.ex 'clamp_visibility'
if [ "$RC" = 0 ]; then ok "6  pattern present -> exit 0"; else bad "6  got exit $RC (want 0)"; fi
if [ "$(first_line "$OUT")" = "PRESENT on origin/main" ]; then
  ok "6b the verdict is the FIRST line"
else
  bad "6b first line was: $(first_line "$OUT")"
fi
if has "$OUT" "api/lib/a.ex:2:"; then ok "6c prints WHERE as file:line"; else bad "6c no file:line in output"; fi
if has "$OUT" "deadbeef1 fix(media)"; then ok "6d prints the introducing commit (git log -S)"; else bad "6d no introducing commit"; fi
if has "$OUT" "--no-fetch: origin/main may be stale"; then
  ok "6e --no-fetch is DISCLOSED in the output, not silent"
else
  bad "6e --no-fetch staleness was not disclosed"
fi

run --no-fetch api/lib/a.ex 'no_such_symbol_zzz'
if [ "$RC" = 1 ]; then ok "7  file exists, pattern absent -> exit 1"; else bad "7  got exit $RC (want 1)"; fi
if [ "$(first_line "$OUT")" = "ABSENT from origin/main" ]; then
  ok "7b verdict line is ABSENT"
else
  bad "7b first line was: $(first_line "$OUT")"
fi

run --no-fetch api/lib/gone.ex 'anything'
if [ "$RC" = 1 ]; then ok "8  path not on main -> exit 1"; else bad "8  got exit $RC (want 1)"; fi
if has "$OUT" "the path itself does not exist on origin/main"; then
  ok "8b says the PATH is missing, not merely the pattern"
else
  bad "8b did not distinguish a missing path from a missing pattern"
fi

# ═══ symbol mode ════════════════════════════════════════════════════════════

section "9-10  symbol mode greps the origin/main TREE"
fresh_world symbol
printf 'origin/main:api/lib/graph.ex:789:  def reverse_referencers(id) do\n' > "$STUB/gitgrep.out"
printf 'cafe1234 feat(content): add reverse_referencers (#9001)\n' > "$STUB/log-S.out"

run --no-fetch --symbol reverse_referencers
if [ "$RC" = 0 ]; then ok "9  symbol found -> exit 0"; else bad "9  got exit $RC (want 0)"; fi
if has "$OUT" "api/lib/graph.ex:789:"; then
  ok "9b strips the origin/main: prefix and keeps file:line"
else
  bad "9b output did not carry a readable file:line"
fi

fresh_world symbol_absent
run --no-fetch --symbol never_written_anywhere
if [ "$RC" = 1 ]; then ok "10 symbol absent -> exit 1"; else bad "10 got exit $RC (want 1)"; fi
if [ "$(first_line "$OUT")" = "ABSENT from origin/main" ]; then
  ok "10b verdict ABSENT"
else
  bad "10b first line was: $(first_line "$OUT")"
fi

# ═══ the refusals ═══════════════════════════════════════════════════════════

section "11  origin/main unreadable is a HOLD, NOT an ABSENT"
fresh_world unreadable
echo 1 > "$STUB/have-main.rc"
run --no-fetch api/lib/a.ex 'anything'
if [ "$RC" = 2 ]; then ok "11 unreadable origin/main -> exit 2"; else bad "11 got exit $RC (want 2)"; fi
if has "$OUT" "HOLD: origin/main is not readable"; then
  ok "11b says HOLD"
else
  bad "11b no HOLD message"
fi
if ! has "$OUT" "ABSENT from origin/main"; then
  ok "11c 'I could not look' was NOT reported as 'it is not there'"
else
  bad "11c an unreadable ref produced an ABSENT verdict — the vacuous answer"
fi

section "12  a failed fetch degrades to a LOUD stale read, not a refusal"
fresh_world stale_fetch
mkdir -p "$STUB/tree"
printf 'hello marker\n' > "$STUB/tree/f.txt"
echo 1 > "$STUB/fetch.rc"
run f.txt 'marker'
if [ "$RC" = 0 ]; then ok "12 fetch failure still answers -> exit 0"; else bad "12 got exit $RC (want 0)"; fi
if has "$OUT" "git fetch origin main FAILED"; then
  ok "12b the stale read is DISCLOSED"
else
  bad "12b a failed fetch was silent"
fi

# ═══ --task: the merged:true trap ═══════════════════════════════════════════

section "13  merged:true does NOT make a verdict — the whole point"
fresh_world task_absent
cat > "$STUB/pr-list.json" <<'JSON'
[{"number":13901,"title":"fix it","headRefName":"stacked-child","state":"MERGED","url":"u"}]
JSON
printf '#13901 MERGED stacked-child fix it\n' > "$STUB/pr-view-13901.txt"
echo '[]' > "$STUB/search.json"
# Deliberately EMPTY: no commit on main carries the task id, even though the PR
# above says MERGED. A stacked PR merges into its PARENT.
: > "$STUB/log-S.out"
: > "$STUB/log-grep.out"

run --no-fetch --task task-4f3acc2d18a7f047
if [ "$RC" = 1 ]; then
  ok "13 a MERGED PR whose text is not on main -> exit 1 (ABSENT)"
else
  bad "13 got exit $RC (want 1) — a merged flag was allowed to decide"
fi
if [ "$(first_line "$OUT")" = "ABSENT from origin/main" ]; then
  ok "13b verdict ABSENT despite state=MERGED"
else
  bad "13b first line was: $(first_line "$OUT")"
fi
if has "$OUT" "#13901 MERGED stacked-child"; then
  ok "13c the PR is still LISTED, with its head branch"
else
  bad "13c the PR was not listed"
fi
if has "$OUT" "merged:true is NOT evidence"; then
  ok "13d the reminder about stacked PRs is printed"
else
  bad "13d no stacked-PR reminder"
fi

section "14  --task with the text actually on main"
fresh_world task_present
echo '[]' > "$STUB/pr-list.json"
echo '[]' > "$STUB/search.json"
printf 'aaa1111 feat(scripts): land it (#14000)\n' > "$STUB/log-S.out"
: > "$STUB/log-grep.out"

run --no-fetch --task task-4f3acc2d18a7f047
if [ "$RC" = 0 ]; then ok "14 text on main -> exit 0"; else bad "14 got exit $RC (want 0)"; fi
if has "$OUT" "aaa1111 feat(scripts): land it"; then
  ok "14b names the commit on main that carries it"
else
  bad "14b did not name the commit"
fi

section "15  a failed gh call must SAY the PR list is incomplete"
fresh_world task_hold
echo 1 > "$STUB/gh-list.rc"
echo 1 > "$STUB/gh-search.rc"
: > "$STUB/log-S.out"
: > "$STUB/log-grep.out"

run --no-fetch --task task-4f3acc2d18a7f047
if has "$OUT" "HOLD: a gh call FAILED"; then
  ok "15 a failed gh enumeration is announced as a HOLD"
else
  bad "15 a failed gh call produced a silent short list"
fi
if has "$OUT" "(none readable — see the HOLD above)"; then
  ok "15b the empty list is labelled UNREADABLE, not 'none'"
else
  bad "15b an unreadable list was rendered as a plain '(none)'"
fi

section "16  --help exits 0 and prints the exit table"
fresh_world help
run --help
if [ "$RC" = 0 ]; then ok "16 --help -> exit 0"; else bad "16 got exit $RC (want 0)"; fi
if has_re "$OUT" '0 PRESENT on origin/main'; then
  ok "16b usage carries the exit table"
else
  bad "16b usage has no exit table"
fi

echo
echo "already-fixed.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
