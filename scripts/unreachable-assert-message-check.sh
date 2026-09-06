#!/usr/bin/env bash
# unreachable-assert-message-check.sh — a custom ExUnit failure message that can
# never print is a guard that half-communicates.
#
# THE DEFECT
# ----------
# ExUnit's `assert/1` is a MACRO that special-cases `=` and reports a match
# failure well. `assert/2` is a plain FUNCTION. So in
#
#     assert [label | _] = LazyHTML.attribute(button, "aria-label"),
#            "a long, helpful explanation of what broke and how to fix it"
#
# the `[label | _] = expr` is evaluated FIRST as an ordinary match. On mismatch
# it raises MatchError and the process dies BEFORE `assert/2` is ever called —
# so the message is dead code on exactly the path it was written for. Proven
# side by side, same failing condition, same authored message:
#
#     1) test FIXED - bind first, then assert
#        THIS CUSTOM MESSAGE DOES APPEAR - it explains the fix
#     2) test DEFECTIVE - assert pattern = expr, message
#        ** (MatchError) no match of right hand side value: []
#
# SEVERITY, STATED HONESTLY: this is DIAGNOSTIC QUALITY, not a correctness hole.
# Every affected test still FAILS when it should — the MatchError is a real
# failure and the ExUnit title still names the case. That is precisely why every
# one of them survived unnoticed. What is lost is the authored explanation at the
# moment a debugger most needs it, and several are multi-line heredocs naming
# the file to edit. Do not let a reviewer price this as a live bug.
#
# WHY AN AST WALK AND NOT A REGEX
# -------------------------------
# A regex over these files reports ~400 files. `=` appears inside sigils
# (`~s(property="og:url")`) and inside `==`, and no character-level tightening
# fixes that reliably. This parses with `Code.string_to_quoted/2` and walks for
# the node `{:assert, _, [{:=, _, [_, _]}, _message]}`, with ZERO parse
# failures — so the count is a CENSUS and not a sample. The parse-failure count
# is PRINTED for exactly that reason: a future reader must be able to tell which
# of the two they are holding.
#
# THE CENSUS IS A SNAPSHOT, SO IT IS PINNED AND RE-DERIVABLE. As of
# origin/main 676504b3a4 (2026-09-01): 54 sites in 39 of 1212 files. This
# header previously read "75 sites in 45 of 1162 files" — a figure that had
# gone stale on all three numbers while reading as current, which is the same
# defect class this gate exists to catch. Do not trust the line above; re-derive
# it, and if you are editing this header, re-derive it again:
#
#   scripts/unreachable-assert-message-check.sh          # prints sites + files scanned
#   scripts/unreachable-assert-message-check.sh --list   # every site, file:line
#
# The BASELINE, not this comment, is the machine-checked truth: its per-file
# counts sum to the site total, and the gate compares against it every run.
#
# REFUSE, NEVER DEGRADE. A file the parser cannot read is a HARD FAILURE, not a
# silent skip. A scanner that quietly drops what it cannot understand reports a
# clean tree it never inspected — the "guard that looks like a guard" class.
#
# NEVER-WORSE, NOT CLEAN-TREE. Sites exist today. Demanding zero would red main
# on day one and get the gate disabled, and a disabled gate still looks like
# coverage. The baseline below is a RATCHET: counts may only fall.
#
# THE BASELINE IS PER-FILE COUNTS, DELIBERATELY NOT file:line. A line-anchored
# pin slides the moment anyone inserts a line above it, and the gate then names
# files the PR never touched. Counts are immune to that.
#
# THE EMPTY BASELINE IS LEGITIMATE — AND THAT IS WHY THE CORPUS NEEDS A FLOOR.
# ---------------------------------------------------------------------------
# .github/unreachable-assert-message.allow holds four comment lines and ZERO
# data rows. That is not rot: the 54 sites the header above records were all
# fixed, the census is now 0, and a ratchet grandfathering nothing is exactly
# right. What it cost is the back-stop. The FELL arm iterates the baseline, so
# with no rows it iterates nothing; the NEW/GROWN arm iterates the scan, so with
# no files it iterates nothing either. Both loops agree that an EMPTY CORPUS is
# a clean tree — measured 2026-09-06 on origin/main 500ab52fd:
#
#     $ mv api/test api/tests_renamed
#     $ scripts/unreachable-assert-message-check.sh; echo rc=$?
#     unreachable-assert-message-check: OK — 0 site(s) at or below baseline,
#       0 file(s) scanned, 0 parse failures
#     rc=0
#
# The verdict was derived from a file list derived from the tree being judged,
# so absence of the tree was indistinguishable from absence of the defect. Two
# things now stand between that and a green, and neither is computed from the
# tree:
#
#   1. A MISSING or EMPTY corpus REFUSES (exit 3), naming the directory. Shape
#      copied verbatim from the best-guarded sibling, refute-on-absence-capture-
#      log-check.sh — do not invent a third dialect for this.
#   2. SCAN_FLOOR, a COMMITTED LITERAL below, catches the case a zero-check
#      cannot: partial deletion. Half the tree gone still scans hundreds of
#      files and still reports a clean census. The floor is the only number here
#      that does not come from the tree, which is the only reason it can be
#      wrong when the tree shrinks. Same doctrine, same words, as
#      scripts/node-test-floor.mjs `--floor`.
#
# Usage:
#   scripts/unreachable-assert-message-check.sh            # check (CI + gate)
#   scripts/unreachable-assert-message-check.sh --list     # print every site, file:line
#   scripts/unreachable-assert-message-check.sh --baseline # emit a fresh baseline
#   scripts/unreachable-assert-message-check.sh --selftest  # prove the gate can fail
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so --selftest can drive synthetic trees in a temp dir and plant
# nothing in the real source.
SCANDIR="${UNREACHABLE_ASSERT_SCANDIR:-$ROOT/api/test}"
BASELINE="${UNREACHABLE_ASSERT_BASELINE:-$ROOT/.github/unreachable-assert-message.allow}"

# SCAN_FLOOR — a COMMITTED LITERAL, deliberately not derived.
#
# DERIVATION (re-derive and re-commit when you edit this line): on origin/main
# 2fe7ddd3a, 2026-09-06, `scripts/unreachable-assert-message-check.sh` printed
# "1494 file(s) scanned" over api/test. 1200 is that number less ~20% headroom,
# so ordinary churn — a directory consolidated, a plugin's suite retired — does
# not red the required Elixir gate, while a corpus gutted to a fraction does.
# Raise it when api/test grows past ~1500 and the margin stops meaning anything;
# NEVER lower it to make a red go away without saying which files legitimately
# left. A floor computed from the tree it checks agrees with a gutted tree by
# construction, which is the whole defect this closes.
#
# Overridable ONLY so --selftest can drive synthetic trees of two or three
# files. CI passes nothing, so CI gets the literal.
SCAN_FLOOR="${UNREACHABLE_ASSERT_SCAN_FLOOR:-1200}"

command -v elixir >/dev/null 2>&1 || {
  echo "unreachable-assert-message-check: elixir is not on PATH — REFUSING." >&2
  echo "  This gate parses Elixir with Code.string_to_quoted/2; without the" >&2
  echo "  compiler it cannot inspect anything, and reporting a clean tree it" >&2
  echo "  never read is the failure it exists to prevent." >&2
  exit 3
}

# REFUSE, NEVER DEGRADE — the corpus itself. A scan tree that is missing or
# unreadable is exit 3, distinctly from a RED (1). Shape copied from
# scripts/refute-on-absence-capture-log-check.sh. Checked BEFORE the scanner is
# written, so the refusal does not depend on anything the scan produces.
if [ ! -d "$SCANDIR" ] || [ ! -r "$SCANDIR" ]; then
  echo "unreachable-assert-message-check: REFUSING — scan corpus is not a readable directory:" >&2
  echo "    $SCANDIR" >&2
  echo "  A verdict over a corpus that was never opened is not a verdict. This" >&2
  echo "  gate previously printed OK on \"0 file(s) scanned\" here. Fix the path," >&2
  echo "  or fix the caller." >&2
  exit 3
fi

SCANNER="$(mktemp -t uamc-scan-XXXXXX).exs"
trap 'rm -f "$SCANNER"' EXIT

cat > "$SCANNER" <<'ELIXIR'
# Emits one line per defective site: "<path>\t<line>", then a trailing
# "PARSE_FAILURES\t<n>" and one "PARSE_FAIL\t<path>" per unreadable file.
root = System.get_env("UAMC_SCANDIR")
files = Path.wildcard(Path.join(root, "**/*.{ex,exs}")) |> Enum.sort()

{hits, parse_failures} =
  Enum.reduce(files, {[], []}, fn file, {hits, fails} ->
    case File.read(file) do
      {:ok, src} ->
        case Code.string_to_quoted(src, columns: true) do
          {:ok, ast} ->
            {_ast, found} =
              Macro.prewalk(ast, [], fn
                # assert/2 whose FIRST argument is a top-level match. The message
                # is the second argument and is unreachable on the failing path.
                {:assert, meta, [{:=, _, [_lhs, _rhs]}, _message]} = node, acc ->
                  {node, [Keyword.get(meta, :line) | acc]}

                node, acc ->
                  {node, acc}
              end)

            {hits ++ Enum.map(Enum.sort(found), &{file, &1}), fails}

          {:error, _} ->
            {hits, [file | fails]}
        end

      {:error, reason} ->
        {hits, ["#{file} (#{inspect(reason)})" | fails]}
    end
  end)

for {f, l} <- hits, do: IO.puts("HIT\t#{Path.relative_to(f, File.cwd!())}\t#{l}")
for f <- Enum.sort(parse_failures),
    do: IO.puts("PARSE_FAIL\t#{Path.relative_to(f, File.cwd!())}")
IO.puts("SCANNED\t#{length(files)}")
IO.puts("PARSE_FAILURES\t#{length(parse_failures)}")
ELIXIR

run_scan() {
  ( cd "$ROOT" && UAMC_SCANDIR="$SCANDIR" elixir "$SCANNER" )
}

# --- selftest ---------------------------------------------------------------
# Arms (0) and (a)-(d) drive SYNTHETIC trees in a TEMP dir. Arm (0) is what
# stops the others passing vacuously: a scanner that always reports "clean"
# would satisfy a naive can-it-red test while measuring nothing.
#
# Arms (e)-(h) drive the REAL corpus path, on a SCRATCH COPY of api/test made
# here — never the live tree, which these arms mutate. They exist because five
# synthetic arms proved only that the gate reds over trees the harness itself
# planted; not one of them ever touched $ROOT/api/test, so every one of them
# stayed green through the transcript in the header where the real corpus was
# renamed away and the gate said OK. An arm that cannot lose when the protected
# thing is gutted is not evidence. Each of (f)-(h) ASSERTS ITS MUTATION APPLIED
# before reading a verdict — a mutation that silently did not happen turns a
# can-it-fail arm back into a can-it-pass arm.
if [ "${1:-}" = "--selftest" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -f "$SCANNER"; rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/test"
  fails=0
  arm() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fails=$((fails+1)); return 0; }

  echo "unreachable-assert-message-check --selftest"
  echo

  # (0) a CLEAN file with a bind-then-assert must PASS, and a bare
  #     `assert pattern = expr` with NO message must NOT be flagged (that is
  #     the assert/1 macro form and it reports matches correctly).
  cat > "$TMP/test/clean_test.exs" <<'EX'
defmodule CleanTest do
  use ExUnit.Case
  test "bound first" do
    labels = attrs()
    assert labels != [], "a message that CAN print"
  end
  test "bare match assert, no message" do
    assert {:ok, _v} = fetch()
  end
  test "comparison with a message" do
    assert count() == 1, "also fine"
  end
end
EX
  printf '0\n' > "$TMP/baseline"
  if UNREACHABLE_ASSERT_SCAN_FLOOR=1 UNREACHABLE_ASSERT_SCANDIR="$TMP/test" UNREACHABLE_ASSERT_BASELINE="$TMP/baseline" \
     bash "$0" >/dev/null 2>&1; then
    arm "ok" "(0) clean tree passes — bare match-assert and == are NOT flagged"
  else
    arm "FAIL" "(0) clean tree REDDENED — the scanner over-matches; every other arm is now meaningless"
  fi

  # (a) a DEFECTIVE site over baseline must RED, naming the file.
  cat > "$TMP/test/bad_test.exs" <<'EX'
defmodule BadTest do
  use ExUnit.Case
  test "unreachable message" do
    assert [_label | _] = attrs(),
           "THIS MESSAGE CAN NEVER PRINT"
  end
end
EX
  out="$(UNREACHABLE_ASSERT_SCAN_FLOOR=1 UNREACHABLE_ASSERT_SCANDIR="$TMP/test" UNREACHABLE_ASSERT_BASELINE="$TMP/baseline" \
        bash "$0" 2>&1 || true)"
  if grep -q "bad_test.exs" <<<"$out"; then
    arm "ok" "(a) a NEW defective site reds, naming bad_test.exs"
  else
    arm "FAIL" "(a) a new defective site did NOT red — the gate is asleep"
  fi

  # (b) the same site AT baseline must PASS (never-worse, not clean-tree).
  #     The baseline is generated BY THE TOOL rather than hand-written: the
  #     scanner emits repo-root-relative paths, and a hand-typed path silently
  #     matches nothing — which reads as "the ratchet does not grandfather"
  #     when the truth is "the baseline names a file that does not exist".
  #     Generating it here also exercises --baseline, which CI never runs.
  UNREACHABLE_ASSERT_SCAN_FLOOR=1 UNREACHABLE_ASSERT_SCANDIR="$TMP/test" bash "$0" --baseline > "$TMP/baseline2" 2>/dev/null
  if UNREACHABLE_ASSERT_SCAN_FLOOR=1 UNREACHABLE_ASSERT_SCANDIR="$TMP/test" UNREACHABLE_ASSERT_BASELINE="$TMP/baseline2" \
     bash "$0" >/dev/null 2>&1; then
    arm "ok" "(b) a site AT baseline passes — the ratchet grandfathers, it does not demand zero"
  else
    arm "FAIL" "(b) a baselined site reddened — this gate would red main on day one and get disabled"
  fi

  # (c) a count that FELL below baseline must RED, telling you to lower it.
  #     Same generated baseline with the count inflated, so the path is real.
  awk '/^#/{print; next} {printf "%d %s\n", $1 + 4, $2}' "$TMP/baseline2" > "$TMP/baseline3"
  out="$(UNREACHABLE_ASSERT_SCAN_FLOOR=1 UNREACHABLE_ASSERT_SCANDIR="$TMP/test" UNREACHABLE_ASSERT_BASELINE="$TMP/baseline3" \
        bash "$0" 2>&1 || true)"
  if grep -qi "lower the baseline\|ratchet" <<<"$out"; then
    arm "ok" "(c) a FIXED site reds until the baseline is lowered — the ratchet cannot rust"
  else
    arm "FAIL" "(c) a fallen count did not demand the baseline be lowered — the ratchet goes stale"
  fi

  # (d) an UNPARSEABLE file must RED, not be silently skipped.
  printf 'defmodule Broken do\n  test "x" do\n    assert (((\n' > "$TMP/test/broken_test.exs"
  out="$(UNREACHABLE_ASSERT_SCAN_FLOOR=1 UNREACHABLE_ASSERT_SCANDIR="$TMP/test" UNREACHABLE_ASSERT_BASELINE="$TMP/baseline2" \
        bash "$0" 2>&1 || true)"
  if grep -q "broken_test.exs" <<<"$out"; then
    arm "ok" "(d) an unparseable file REFUSES by name — never a silent skip"
  else
    arm "FAIL" "(d) an unparseable file was skipped silently — the scanner reports a tree it never read"
  fi

  # ---- REAL corpus path, on a scratch copy -------------------------------
  # cp -R, find and mv only: POSIX on both the macOS box this is written on and
  # the ubuntu runner it is judged on. No `cp -a`, no GNU-only flags.
  REAL="$TMP/real/test"
  mkdir -p "$TMP/real"
  if cp -R "$ROOT/api/test" "$REAL" 2>/dev/null; then
    real_n="$(find "$REAL" \( -name '*.ex' -o -name '*.exs' \) -type f | wc -l | tr -d ' ')"

    # (e) the real corpus, copied intact, must PASS at the COMMITTED floor.
    #     No floor override here — this is the arm that would red if SCAN_FLOOR
    #     were ever raised above what api/test actually holds.
    if UNREACHABLE_ASSERT_SCANDIR="$REAL" bash "$0" >/dev/null 2>&1; then
      arm "ok" "(e) the REAL corpus ($real_n files) passes at the committed floor $SCAN_FLOOR"
    else
      arm "FAIL" "(e) the REAL corpus REDDENED at floor $SCAN_FLOOR — the floor outran api/test, or the tree is dirty"
    fi

    # (f) corpus MOVED AWAY (the realistic cause: a rename) must REFUSE.
    mv "$REAL" "$TMP/real/moved"
    if [ ! -d "$REAL" ] && [ -d "$TMP/real/moved" ]; then
      rc_f=0; out="$(UNREACHABLE_ASSERT_SCANDIR="$REAL" bash "$0" 2>&1)" || rc_f=$?
      if [ "$rc_f" != 0 ] && grep -q "REFUSING" <<<"$out" && grep -qF "$REAL" <<<"$out"; then
        arm "ok" "(f) a MOVED corpus refuses (rc $rc_f), naming the directory — this is the case that printed OK"
      else
        arm "FAIL" "(f) a MOVED corpus did not refuse (rc $rc_f) — the gate still reads absence as clean"
      fi
    else
      arm "FAIL" "(f) MUTATION DID NOT APPLY — the corpus was not moved, so this arm proved nothing"
    fi
    mv "$TMP/real/moved" "$REAL"

    # (g) corpus PRESENT but EMPTIED must REFUSE on the zero-file scan.
    mkdir -p "$TMP/emptied"
    if [ -d "$TMP/emptied" ] && [ -z "$(find "$TMP/emptied" -type f)" ]; then
      rc_g=0; out="$(UNREACHABLE_ASSERT_SCANDIR="$TMP/emptied" bash "$0" 2>&1)" || rc_g=$?
      if [ "$rc_g" != 0 ] && grep -q "0 file(s) scanned" <<<"$out"; then
        arm "ok" "(g) an EMPTIED corpus refuses (rc $rc_g) on the zero-file scan"
      else
        arm "FAIL" "(g) an EMPTIED corpus was read as a clean tree (rc $rc_g)"
      fi
    else
      arm "FAIL" "(g) MUTATION DID NOT APPLY — the emptied corpus is not empty"
    fi

    # (h) corpus PARTLY deleted — the case a zero-check cannot catch — must
    #     refuse on the FLOOR. Keep 5 files; assert the deletion landed.
    find "$REAL" \( -name '*.ex' -o -name '*.exs' \) -type f | sort | tail -n +6 | while read -r f; do
      rm -f "$f"
    done
    left_n="$(find "$REAL" \( -name '*.ex' -o -name '*.exs' \) -type f | wc -l | tr -d ' ')"
    if [ "$left_n" -lt "$real_n" ] && [ "$left_n" -gt 0 ]; then
      rc_h=0; out="$(UNREACHABLE_ASSERT_SCANDIR="$REAL" bash "$0" 2>&1)" || rc_h=$?
      if [ "$rc_h" != 0 ] && grep -q "below floor" <<<"$out"; then
        arm "ok" "(h) a corpus cut from $real_n to $left_n files refuses on the floor (rc $rc_h)"
      else
        arm "FAIL" "(h) a corpus cut from $real_n to $left_n files still reported clean (rc $rc_h)"
      fi
    else
      arm "FAIL" "(h) MUTATION DID NOT APPLY — files went $real_n -> $left_n"
    fi
  else
    arm "FAIL" "(e-h) could not copy $ROOT/api/test — the real-corpus arms could not run"
    arm "FAIL" "(f) not run"
    arm "FAIL" "(g) not run"
    arm "FAIL" "(h) not run"
  fi

  echo
  if [ "$fails" -gt 0 ]; then
    echo "SELFTEST FAILED: $fails of 9 arms failed"
    exit 1
  fi
  echo "SELFTEST PASSED: 9 of 9 arms"
  exit 0
fi

# --- scan -------------------------------------------------------------------
SCAN_OUT="$(run_scan)"

PARSE_FAILS="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="PARSE_FAIL"{print $2}')"
SCANNED="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="SCANNED"{print $2}')"
NFAIL="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="PARSE_FAILURES"{print $2}')"

# THE BACK-STOP THE COMMENT-ONLY BASELINE LEFT MISSING. Placed BEFORE --list and
# --baseline on purpose: `--baseline` over an empty corpus would emit an empty
# allow-file and cement the blindness as the committed truth.
if [ "${SCANNED:-0}" -eq 0 ]; then
  echo "unreachable-assert-message-check: REFUSING — 0 file(s) scanned:" >&2
  echo "    $SCANDIR" >&2
  echo "  The corpus is empty, so \"0 site(s)\" says nothing about the defect —" >&2
  echo "  it is absence of the tree, not absence of the finding. Neither loop in" >&2
  echo "  this gate can tell those apart on its own: NEW/GROWN iterates the scan" >&2
  echo "  and FELL iterates a baseline that legitimately holds zero rows." >&2
  exit 3
fi

if [ "$SCANNED" -lt "$SCAN_FLOOR" ]; then
  echo "unreachable-assert-message-check: REFUSING — corpus below floor:" >&2
  echo "    scanned $SCANNED file(s) under $SCANDIR, floor is $SCAN_FLOOR" >&2
  echo "  A partly-deleted corpus still scans cleanly, because every count here" >&2
  echo "  is derived from the tree being judged. The floor is the one number" >&2
  echo "  that is not, so it is the one thing that can be wrong when the tree" >&2
  echo "  shrinks. If the shrink is legitimate, say WHICH files left and lower" >&2
  echo "  SCAN_FLOOR in this script with a fresh derivation and date." >&2
  exit 3
fi

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"{printf "%s:%s\n", $2, $3}'
  printf '\nscanned %s file(s), %s parse failure(s)\n' "$SCANNED" "$NFAIL"
  exit 0
fi

if [ "${1:-}" = "--baseline" ]; then
  printf '# Per-file counts of `assert <pattern> = <expr>, <message>` — a message\n'
  printf '# ExUnit can never print (assert/2 is a function; the match raises first).\n'
  printf '# RATCHET: counts may only FALL. Regenerate with --baseline after fixing.\n'
  printf '# Counts, NOT file:line — a line pin slides on any insertion above it.\n'
  printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"{c[$2]++} END{for (f in c) printf "%d %s\n", c[f], f}' | sort -k2
  exit 0
fi

# REFUSE on any unreadable file, before judging anything.
if [ "${NFAIL:-0}" != "0" ]; then
  echo "unreachable-assert-message-check: REFUSING — $NFAIL file(s) could not be parsed:" >&2
  printf '%s\n' "$PARSE_FAILS" | sed 's/^/    /' >&2
  echo "" >&2
  echo "  A scanner that skips what it cannot read reports a clean tree it never" >&2
  echo "  inspected. Fix the syntax, or fix the scanner — do not let it degrade." >&2
  exit 1
fi

[ -f "$BASELINE" ] || { echo "unreachable-assert-message-check: baseline $BASELINE is missing" >&2; exit 3; }

TMPD="$(mktemp -d)"; trap 'rm -f "$SCANNER"; rm -rf "$TMPD"' EXIT
printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"{c[$2]++} END{for (f in c) printf "%d %s\n", c[f], f}' | sort -k2 > "$TMPD/now"
grep -vE '^\s*#|^\s*$' "$BASELINE" | sort -k2 > "$TMPD/base" || true

rc=0
# NEW or GROWN
while read -r n f; do
  [ -z "${f:-}" ] && continue
  b="$(awk -v p="$f" '$2==p{print $1}' "$TMPD/base")"
  b="${b:-0}"
  if [ "$n" -gt "$b" ]; then
    echo "RED  $f — $n unreachable assert message(s), baseline $b" >&2
    printf '%s\n' "$SCAN_OUT" | awk -F'\t' -v p="$f" '$1=="HIT" && $2==p{printf "       %s:%s\n", $2, $3}' >&2
    rc=1
  fi
done < "$TMPD/now"

# FELL — the ratchet must be tightened, or it rusts at a number nobody re-earns.
while read -r n f; do
  [ -z "${f:-}" ] && continue
  c="$(awk -v p="$f" '$2==p{print $1}' "$TMPD/now")"
  c="${c:-0}"
  if [ "$c" -lt "$n" ]; then
    echo "RATCHET  $f — now $c, baseline $n. Lower the baseline (counts may only fall):" >&2
    echo "         run: scripts/unreachable-assert-message-check.sh --baseline > .github/unreachable-assert-message.allow" >&2
    rc=1
  fi
done < "$TMPD/base"

TOTAL="$(awk '{s+=$1} END{print s+0}' "$TMPD/now")"
if [ "$rc" = 0 ]; then
  echo "unreachable-assert-message-check: OK — $TOTAL site(s) at or below baseline, $SCANNED file(s) scanned (floor $SCAN_FLOOR), 0 parse failures"
else
  echo "" >&2
  echo "  FIX: bind first, then assert on a boolean, so assert/2 can use the message:" >&2
  echo "       labels = LazyHTML.attribute(button, \"aria-label\")" >&2
  echo "       assert labels != [], \"...the same message, now reachable...\"" >&2
  echo "  Or drop the message and keep the bare \`assert pattern = expr\` macro form," >&2
  echo "  which reports matches well on its own." >&2
fi
exit "$rc"
