#!/usr/bin/env bash
# format-diff-scope.sh — turns the format verdict into a DIFF-SCOPED one.
#
# ─────────────────────────────────────────────────────────────────────────────
#  WHY THIS EXISTS (task-e31b816b4b416db6)
# ─────────────────────────────────────────────────────────────────────────────
#  The `format` job in .github/workflows/elixir.yml was ADVISORY
#  (continue-on-error) and nothing read it. So unformatted Elixir merged, and
#  from then on the job was red on EVERY pull request for drift the author
#  never touched. A permanently-red advisory gate teaches the fleet to skip the
#  one red that is real — measured on main run 33843359350 (2026-09-04 06:12Z):
#  three inherited files, red for everyone.
#
#  Making the job simply BLOCKING is the wrong cure: it would red every PR in
#  the fleet for drift someone else merged, which is the same "not my red"
#  lesson with a merge button attached. THE VERDICT HAS TO BE SCOPED TO THE
#  DIFF. A file the formatter objects to is YOUR red only if your diff touches
#  it; everything else is printed and stays NEUTRAL.
#
#  This file is the whole decision, in one testable place — deliberately not
#  inline YAML, because inline YAML cannot be run on a laptop and cannot have
#  a mutation harness pointed at it.
#
# ─────────────────────────────────────────────────────────────────────────────
#  A REFUSAL IS NOT A VERDICT — inherited from scripts/format-check.sh
# ─────────────────────────────────────────────────────────────────────────────
#  format-check.sh exits 0 (clean), 1 (genuinely unformatted) or 3/4/5/6 (it
#  REFUSED to answer: wrong Elixir, unfetched deps, unreadable pin, formatter
#  never ran). This reader honours that split: only rc 1 carries a file list.
#  A refusal is printed loudly and scores NEUTRAL — no claim was made, so no
#  claim may be enforced.
#
#  THE VACUITY TRAP, closed by exit 2. `mix format --check-formatted` names its
#  offenders in a shape that has already changed once (1.18 printed
#  `  * lib/foo.ex`; 1.19.5 prints an ABSOLUTE path plus a coloured diff). If
#  the parser stops matching, the intersection is empty and this gate goes
#  green FOREVER while the tree rots — the exact failure mode this repo keeps
#  meeting. So: rc 1 with ZERO offenders parsed is NOT a pass. It is exit 2,
#  "cannot tell", and it is RED.
#
# ─────────────────────────────────────────────────────────────────────────────
#  USAGE
# ─────────────────────────────────────────────────────────────────────────────
#    format-diff-scope.sh --verdict-log F --guard-rc N --changed F [--root D]
#    format-diff-scope.sh --selftest
#
#  --verdict-log  the captured stdout+stderr of `bash scripts/format-check.sh`
#  --guard-rc     that script's exit code (the refusal/verdict discriminator)
#  --changed      the PR's changed paths, one repo-relative path per line.
#                 AN EMPTY FILE IS THE push:main CASE and is meaningful: there
#                 is no PR diff, so nothing can be diff-scoped and the answer is
#                 NEUTRAL by construction. Said in words, not implied.
#  --root         repo root, used to make absolute offender paths repo-relative
#                 (default: git rev-parse --show-toplevel, else $PWD)
#
#  EXIT CODES:
#    0  no offender is in this diff (inherited drift may exist; it is PRINTED)
#    1  at least one file THIS DIFF TOUCHES is unformatted — the red
#    2  CANNOT TELL — bad arguments, or an exit-1 verdict this parser could not
#       read a single filename out of. Red on purpose; never green.
#
#  If $GITHUB_OUTPUT is set it also writes:
#    unformatted_in_diff=<comma-joined repo-relative paths>   (may be empty)
#    unformatted_total=<count of ALL unformatted files, diff or not>
set -uo pipefail

say() { printf '%s\n' "$*"; }

# ── the parser ───────────────────────────────────────────────────────────────
# Both shapes the formatter has been observed to emit, and nothing else:
#   1.19.5   an ANSI-coloured ABSOLUTE path on a line of its own, then a diff
#   1.18.x   `  * lib/foo.ex`, relative to the mix project
# Everything is normalised to a repo-relative path. Relative offenders get the
# `api/` prefix because that is the mix project this workflow formats; absolute
# ones get $ROOT stripped.
parse_offenders() { # $1 verdict log, $2 root
  local log="$1" root="$2"
  # strip ANSI SGR sequences first — 1.19.5 wraps the filename in them, so an
  # un-stripped line matches no path pattern at all.
  sed $'s/\033\\[[0-9;]*m//g' "$log" \
  | awk -v root="$root" '
      { line = $0; sub(/\r$/, "", line) }
      # `  * some/path.ex`  (1.18-shaped)
      line ~ /^[[:space:]]*\*[[:space:]]+[^[:space:]]+\.exs?$/ {
        p = line; sub(/^[[:space:]]*\*[[:space:]]+/, "", p)
        print (p ~ /^\// ? p : "api/" p); next
      }
      # `/abs/path.ex` on a line of its own (1.19-shaped)
      line ~ /^\/[^[:space:]]+\.exs?$/ {
        p = line
        if (index(p, root "/") == 1) p = substr(p, length(root) + 2)
        print p; next
      }
    ' \
  | sed 's#^\./##' | sort -u
}

if [ "${1:-}" != "--selftest" ]; then
  LOG=""; RC=""; CHANGED=""; ROOT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --verdict-log) LOG="${2:-}"; shift 2 ;;
      --guard-rc)    RC="${2:-}";  shift 2 ;;
      --changed)     CHANGED="${2:-}"; shift 2 ;;
      --root)        ROOT="${2:-}"; shift 2 ;;
      *) say "!! CANNOT TELL (exit 2): unknown argument '$1'."; exit 2 ;;
    esac
  done
  [ -n "$ROOT" ] || ROOT="${FORMAT_DIFF_SCOPE_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  ROOT="${ROOT%/}"

  if [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
    say "!! CANNOT TELL (exit 2): no readable --verdict-log (got '${LOG:-<unset>}')."
    say "   NO CLAIM is being made about formatting, and this is RED rather than green:"
    say "   a missing verdict is a broken instrument, not a clean tree."
    exit 2
  fi
  case "$RC" in
    ''|*[!0-9]*) say "!! CANNOT TELL (exit 2): --guard-rc must be the numeric exit code of scripts/format-check.sh (got '${RC:-<unset>}')."; exit 2 ;;
  esac
  if [ -z "$CHANGED" ] || [ ! -f "$CHANGED" ]; then
    say "!! CANNOT TELL (exit 2): no readable --changed file (got '${CHANGED:-<unset>}')."
    say "   An ABSENT diff is not an EMPTY diff. An empty file says 'this event has no PR"
    say "   diff' and is fine; a missing one means the caller never computed one."
    exit 2
  fi

  # ── refusals: loud, and NEUTRAL ────────────────────────────────────────────
  if [ "$RC" != 0 ] && [ "$RC" != 1 ]; then
    say "== FORMAT: NO VERDICT (guard exit $RC) — a REFUSAL, not a reading. =="
    sed 's/^/   | /' "$LOG"
    say ""
    say "   scripts/format-check.sh refused to answer (wrong Elixir / unfetched deps /"
    say "   unreadable pin / the formatter never ran). Nothing was measured, so nothing"
    say "   is enforced. NEUTRAL — this step passes and makes NO claim about this diff."
    exit 0
  fi

  if [ "$RC" = 0 ]; then
    say "== FORMAT: the whole tree is formatted under the gate's Elixir. =="
    say "   Nothing to scope. NEUTRAL and green."
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      { printf 'unformatted_in_diff=\n'; printf 'unformatted_total=0\n'; } >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi

  # ── rc == 1: a real verdict. Read the offenders. ──────────────────────────
  offenders="$(parse_offenders "$LOG" "$ROOT")"
  if [ -z "$offenders" ]; then
    say "!! CANNOT TELL (exit 2): the guard returned 1 — a REAL 'unformatted' verdict —"
    say "   but this reader parsed ZERO filenames out of it."
    say ""
    say "   That is a BROKEN PARSER, not a clean diff, and it is red on purpose: an"
    say "   empty offender list would intersect to empty and green this gate forever"
    say "   while the tree rots. \`mix format\`'s output shape has already changed once"
    say "   (1.18 printed '  * lib/foo.ex'; 1.19.5 prints an absolute path plus a diff)."
    say "   Fix parse_offenders() in scripts/format-diff-scope.sh. What it was reading:"
    sed 's/^/   | /' "$LOG"
    exit 2
  fi

  total="$(printf '%s\n' "$offenders" | wc -l | tr -d ' ')"
  # grep -x -F -f: a fixed-string, whole-line intersection. Never a regex —
  # a path contains dots, and `.` matching any character would over-match.
  in_diff=""
  if [ -s "$CHANGED" ]; then
    in_diff="$(printf '%s\n' "$offenders" | grep -xFf "$CHANGED" || true)"
  fi

  say "== FORMAT: $total file(s) are unformatted under the gate's Elixir. =="
  printf '%s\n' "$offenders" | sed 's/^/   - /'
  say ""

  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { printf 'unformatted_in_diff=%s\n' "$(printf '%s\n' "$in_diff" | grep -v '^$' | paste -sd, - 2>/dev/null || true)"
      printf 'unformatted_total=%s\n' "$total"; } >> "$GITHUB_OUTPUT"
  fi

  if [ -z "$in_diff" ]; then
    if [ -s "$CHANGED" ]; then
      say "NEUTRAL — none of them is in THIS diff. Every one above is INHERITED from main:"
      say "someone else merged it, and it is not this pull request's red. Printed, not enforced."
    else
      say "NEUTRAL — there is no PR diff on this event (push to main, or a diff that could"
      say "not be computed), so NOTHING can be diff-scoped. The list above is the standing"
      say "debt: it is reported here and nowhere enforced. Owner: whoever touches the file next."
    fi
    exit 0
  fi

  say "!! UNFORMATTED IN THIS DIFF — this pull request touches these unformatted files:"
  printf '%s\n' "$in_diff" | sed 's/^/     /'
  say ""
  say "   Fix with: (cd api && mix format <file>...) under the Elixir the gate pins,"
  say "   then push. Only the files above are yours; the rest of the list is inherited."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
#  --selftest: every arm must be able to fire
# ─────────────────────────────────────────────────────────────────────────────
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ck() { # name want_rc must_say must_not_say rc out
  local name="$1" want="$2" yes="$3" no="$4" rc="$5" out="$6"
  if [ "$rc" -ne "$want" ]; then say "  FAIL  $name — expected exit $want, got $rc"; fails=$((fails+1)); return; fi
  if [ -n "$yes" ] && ! printf '%s' "$out" | grep -q -e "$yes"; then
    say "  FAIL  $name — exit $rc right, but the message never says '$yes'"; fails=$((fails+1)); return; fi
  if [ -n "$no" ] && printf '%s' "$out" | grep -q -e "$no"; then
    say "  FAIL  $name — the message ALSO says '$no'"; fails=$((fails+1)); return; fi
  say "  ok    $name (exit $rc)"
}
SELF="${BASH_SOURCE[0]}"
say "=== format-diff-scope selftest: the scope must red on yours and stay neutral on theirs ==="

R="$tmp/repo"; mkdir -p "$R"
# THE REAL 1.19.5 SHAPE, ANSI codes and all — copied from main run 33843359350.
printf '>> deps        resolved in api/deps\n\n** (Mix) mix format failed due to --check-formatted.\nThe following files are not formatted:\n\n\033[1m\033[31m%s/api/lib/barkpark/content/papers/block_ops.ex\n\033[0m\n           |\n 454  454  |    case enforce_blocks_wall(x) do\n 456      -|        persist_blocks_doc(a, b)\n\n\033[1m\033[31m%s/api/test/barkpark/content/errors_envelope_table_test.exs\n\033[0m\n' "$R" "$R" > "$tmp/v119.log"
# THE 1.18 SHAPE, so a formatter downgrade does not silently neuter the parser.
printf '** (Mix) mix format failed due to --check-formatted.\nThe following files are not formatted:\n\n  * lib/barkpark/content/papers/block_ops.ex\n  * test/barkpark/content/errors_envelope_table_test.exs\n' > "$tmp/v118.log"

printf 'api/lib/barkpark/content/papers/block_ops.ex\napi/lib/other.ex\n' > "$tmp/changed-touches.txt"
printf 'docs/cards/cli.md\napi/lib/untouched.ex\n'                        > "$tmp/changed-misses.txt"
: > "$tmp/changed-empty.txt"

run() { out="$(FORMAT_DIFF_SCOPE_ROOT="$R" bash "$SELF" "$@" 2>&1)"; rc=$?; }

# 1/2. THE WHOLE POINT, both directions, on the SAME unformatted state.
run --verdict-log "$tmp/v119.log" --guard-rc 1 --changed "$tmp/changed-touches.txt"
ck "a touched unformatted file REDS and names itself" 1 "block_ops.ex" "" "$rc" "$out"
ck "…and it says UNFORMATTED IN THIS DIFF, not just 'unformatted'" 1 "UNFORMATTED IN THIS DIFF" "" "$rc" "$out"
run --verdict-log "$tmp/v119.log" --guard-rc 1 --changed "$tmp/changed-misses.txt"
ck "the SAME drift in files this diff never touched is NEUTRAL" 0 "INHERITED from main" "UNFORMATTED IN THIS DIFF" "$rc" "$out"
ck "…and the inherited files are still PRINTED, never hidden" 0 "block_ops.ex" "" "$rc" "$out"

# 3. push:main — no PR diff at all. Neutral, and it SAYS why.
run --verdict-log "$tmp/v119.log" --guard-rc 1 --changed "$tmp/changed-empty.txt"
ck "no PR diff (push to main) is NEUTRAL and says so in words" 0 "no PR diff on this event" "UNFORMATTED IN THIS DIFF" "$rc" "$out"

# 4. the 1.18 output shape still parses — a formatter downgrade must not neuter it.
run --verdict-log "$tmp/v118.log" --guard-rc 1 --changed "$tmp/changed-touches.txt"
ck "the 1.18 '  * path' shape parses too" 1 "block_ops.ex" "" "$rc" "$out"

# 5. THE VACUITY TRAP. An exit-1 verdict this parser cannot read is RED, not green.
printf 'unformatted, but in some shape from the future\n' > "$tmp/unparsable.log"
run --verdict-log "$tmp/unparsable.log" --guard-rc 1 --changed "$tmp/changed-touches.txt"
ck "an exit-1 verdict with ZERO parsed files is CANNOT TELL, never a pass" 2 "BROKEN PARSER" "" "$rc" "$out"

# 6. refusals are neutral and never reported as a formatting verdict.
printf '!! FORMAT CHECK REFUSED (exit 3): WRONG ELIXIR\n' > "$tmp/refusal.log"
for r in 3 4 5 6; do
  run --verdict-log "$tmp/refusal.log" --guard-rc "$r" --changed "$tmp/changed-touches.txt"
  ck "guard exit $r is a REFUSAL: neutral, and no claim" 0 "NO VERDICT (guard exit $r)" "UNFORMATTED IN THIS DIFF" "$rc" "$out"
done

# 7. a clean tree.
printf 'FORMAT OK\n' > "$tmp/clean.log"
run --verdict-log "$tmp/clean.log" --guard-rc 0 --changed "$tmp/changed-touches.txt"
ck "a formatted tree is green and scopes nothing" 0 "whole tree is formatted" "" "$rc" "$out"

# 8. broken wiring is RED, never green — an absent diff is not an empty one.
run --verdict-log "$tmp/v119.log" --guard-rc 1 --changed "$tmp/nope.txt"
ck "a MISSING --changed file cannot tell (absent != empty)" 2 "ABSENT diff is not an EMPTY diff" "" "$rc" "$out"
run --verdict-log "$tmp/nope.log" --guard-rc 1 --changed "$tmp/changed-touches.txt"
ck "a missing verdict log cannot tell" 2 "no readable --verdict-log" "" "$rc" "$out"
run --verdict-log "$tmp/v119.log" --guard-rc "" --changed "$tmp/changed-touches.txt"
ck "a non-numeric guard-rc cannot tell" 2 "--guard-rc must be the numeric exit code" "" "$rc" "$out"

# 9. $GITHUB_OUTPUT carries the list the aggregator prints, and it is COMMA-joined:
#    a path contains no comma, and job names/paths contain spaces, so a
#    space-joined list cannot be read back as a set.
go="$tmp/gh-out.txt"; : > "$go"
out="$(FORMAT_DIFF_SCOPE_ROOT="$R" GITHUB_OUTPUT="$go" bash "$SELF" \
        --verdict-log "$tmp/v119.log" --guard-rc 1 --changed "$tmp/changed-touches.txt" 2>&1)"; rc=$?
if grep -q '^unformatted_in_diff=api/lib/barkpark/content/papers/block_ops.ex$' "$go"; then
  say "  ok    the job output carries exactly the diff-scoped list"
else
  say "  FAIL  the job output is wrong: $(tr '\n' ' ' < "$go")"; fails=$((fails+1))
fi
if grep -q '^unformatted_total=2$' "$go"; then
  say "  ok    the job output carries the FULL count too (2), so a reader can see the debt"
else
  say "  FAIL  unformatted_total missing/wrong: $(tr '\n' ' ' < "$go")"; fails=$((fails+1))
fi
go2="$tmp/gh-out2.txt"; : > "$go2"
FORMAT_DIFF_SCOPE_ROOT="$R" GITHUB_OUTPUT="$go2" bash "$SELF" \
  --verdict-log "$tmp/v119.log" --guard-rc 1 --changed "$tmp/changed-misses.txt" >/dev/null 2>&1
if grep -q '^unformatted_in_diff=$' "$go2"; then
  say "  ok    an inherited-only run writes an EMPTY diff-scoped list (the aggregator's neutral)"
else
  say "  FAIL  inherited-only run wrote: $(tr '\n' ' ' < "$go2")"; fails=$((fails+1))
fi

say ""
if [ "$fails" -eq 0 ]; then
  say "SELFTEST OK — the scope reds on the diff's own files and stays neutral on inherited drift."
  exit 0
fi
say "SELFTEST FAILED — $fails case(s)." >&2
exit 1
