#!/usr/bin/env bash
# comment-status-literal-check.sh — a fix whose own prose is indistinguishable
# from the defect it removed is a fix that hides the remaining work.
#
# THE DEFECT
# ----------
# PR #16888 tightened 32 test assertions that had accepted a DISJUNCTION of HTTP
# statuses (`assert conn.status in [401, 403, 404]`) down to the single status
# the door actually gives. In 20 of its explanatory comments it then QUOTED the
# bracket literal it had just removed:
#
#     # old `in [401, 403, 404]` was green on an unauthenticated 401 too
#
# The comment is honest and useful to a reader. It is also, to `grep`, byte-for-
# byte the thing being hunted. Every sweep for "which assertions still accept a
# status disjunction" then returned 20 hits in exactly the ten files that had
# already been fixed — the remaining work buried under the receipts of the work
# already done. PR #16918 rewords them into prose (unauthorized / forbidden /
# not-found), which names the same statuses and greps as nothing.
#
# WHY A GUARD AND NOT JUST THE CLEANUP. A cleanup removes INSTANCES; the
# population regrows at authorship rate. PR #16912 landed a FRESH one in
# api/test/barkpark/media/scoped_media_public_read_tier_audit_test.exs one
# commit after the defect was named — nobody had done anything wrong, they had
# simply never been told. This gate is the thing that meets the author.
#
# SEVERITY, STATED HONESTLY: this is SEARCHABILITY, not correctness. Not one
# affected test asserts anything different because of a comment. Nothing is
# mis-verified, nothing passes that should fail, and no user-visible behaviour
# depends on a single character here. What it costs is the reliability of the
# one instrument anyone uses to find the remaining instances of a class defect —
# and it costs it in the most expensive way, by returning CONFIDENT hits that
# are all false. Do not let a reviewer price this as a live bug.
#
# THE RULE
# --------
# A comment in api/test/**/*_test.exs must not reproduce a bracketed list of two
# or more HTTP status literals. Detection is `\[` then a 3-digit number then `,`
# inside comment text (regex /\[\s*\d{3}\s*,/) — the shape that makes a comment
# collide with a grep for the assertion form. A SINGLE status in brackets
# (`[403]`) is not flagged: it does not name a disjunction and does not collide.
#
# FIX: narrate the removed assertion in prose. "the old check also passed on an
# unauthenticated request" says more than the literal did, and greps as nothing.
#
# WHY THE PARSER AND NOT grep
# ---------------------------
# `#` is not a comment marker in Elixir when it is inside a string, a sigil, a
# heredoc, or a `#{}` interpolation. A line-based scanner cannot tell those
# apart, and one that guesses either over-reports (reddening on documentation
# strings) or silently under-reports. This uses
# `Code.string_to_quoted_with_comments/2`, which returns the tokenizer's OWN
# comment list — so a `#` the compiler does not consider a comment is not
# considered one here either. That makes this a CENSUS, not a sample, and the
# parse-failure count is PRINTED on every run so a future reader can tell which
# of the two they are holding. A file that will not parse is a HARD FAILURE.
#
# SCOPE, WIDER THAN THE ORIGINAL STATEMENT OF THE RULE. The defect was described
# as "a comment LINE" — a line whose first non-whitespace character is `#`. This
# gate flags BOTH own-line and TRAILING comments, because a trailing
# `assert x  # old \`in [401, 403]\`` collides with exactly the same grep for
# exactly the same reason. On the census below, trailing hits = 0, so the wider
# rule costs nothing today and closes the door on the variant. --list prints the
# kind of each site, so the two are never conflated.
#
# THE CENSUS IS A SNAPSHOT, SO IT IS PINNED AND RE-DERIVABLE. Derived on branch
# pr16918-comment-status-literal at ba1b02f86 (rebased onto origin/main
# bbffd09c7), 2026-09-08: 1 site, in 1 of 1645 files, 0 trailing, 0 parse
# failures. DO NOT TRUST THAT LINE — the sibling gate this is modelled on,
# scripts/unreachable-assert-message-check.sh, carried a census that had gone
# stale on all three of its numbers while still reading as current, which is the
# same defect class both gates exist to catch. Re-derive it, and re-derive it
# again if you edit this header:
#
#   scripts/comment-status-literal-check.sh          # sites + files scanned
#   scripts/comment-status-literal-check.sh --list   # every site, file:line
#
# The BASELINE, not this comment, is the machine-checked truth: its per-file
# counts sum to the site total, and the gate compares against it every run.
#
# REFUSE, NEVER DEGRADE. A file the parser cannot read, a missing corpus, an
# empty corpus, a corpus below the floor — all are hard failures, not silent
# skips. A scanner that quietly drops what it cannot understand reports a clean
# tree it never inspected.
#
# NEVER-WORSE, NOT CLEAN-TREE. One site exists today. The baseline is a RATCHET:
# counts may only FALL. It holds exactly ONE row, and that is deliberate — a
# tripwire that grows stops discriminating, because the eighth entry is waved
# through by the seven above it. If you are about to add a row, fix the site
# instead.
#
# THE BASELINE IS PER-FILE COUNTS, DELIBERATELY NOT file:line. A line-anchored
# pin slides the moment anyone inserts a line above it, and the gate then names
# files the PR never touched. Counts are immune to that.
#
# BASELINE KEYS ARE RELATIVE TO THE SCAN ROOT, NOT THE REPO ROOT. This was not
# the first shape: keying on repo-relative paths made the committed baseline
# unusable over a scratch COPY of api/test, so --selftest arm (e) — the one arm
# that judges the COMMITTED baseline and the COMMITTED floor — reddened and
# caught it. Scan-root keys make the same allow-file correct wherever the corpus
# is mounted. The repo-relative prefix is re-attached for OUTPUT only.
#
# Usage:
#   scripts/comment-status-literal-check.sh            # check (CI + gate)
#   scripts/comment-status-literal-check.sh --list     # every site, file:line
#   scripts/comment-status-literal-check.sh --baseline # emit a fresh baseline
#   scripts/comment-status-literal-check.sh --selftest # prove the gate can fail
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Overridable so --selftest can drive synthetic trees in a temp dir and plant
# nothing in the real source.
SCANDIR="${COMMENT_STATUS_LITERAL_SCANDIR:-$ROOT/api/test}"
BASELINE="${COMMENT_STATUS_LITERAL_BASELINE:-$ROOT/.github/comment-status-literal.allow}"

# SCAN_FLOOR — a COMMITTED LITERAL, deliberately not derived.
#
# DERIVATION (re-derive and re-commit when you edit this line): on branch
# pr16918-comment-status-literal at ba1b02f86 (origin/main bbffd09c7),
# 2026-09-08, this script printed "1645 file(s) scanned" over api/test. 1300 is
# that number less ~20% headroom, so ordinary churn — a suite consolidated, a
# plugin retired — does not red the required Elixir gate, while a corpus gutted
# to a fraction does. Raise it when api/test grows past ~1900 and the margin
# stops meaning anything; NEVER lower it to make a red go away without saying
# which files legitimately left. A floor computed from the tree it checks agrees
# with a gutted tree by construction, which is the only reason this one number
# is not derived.
#
# Overridable ONLY so --selftest can drive synthetic trees of two or three
# files. CI passes nothing, so CI gets the literal.
SCAN_FLOOR="${COMMENT_STATUS_LITERAL_SCAN_FLOOR:-1300}"

command -v elixir >/dev/null 2>&1 || {
  echo "comment-status-literal-check: elixir is not on PATH — REFUSING." >&2
  echo "  This gate reads the tokenizer's own comment list via" >&2
  echo "  Code.string_to_quoted_with_comments/2; without the compiler it cannot" >&2
  echo "  tell a comment from a '#' inside a heredoc, and reporting a clean tree" >&2
  echo "  it never read is the failure it exists to prevent." >&2
  exit 3
}

# REFUSE, NEVER DEGRADE — the corpus itself. Checked BEFORE the scanner is
# written, so the refusal does not depend on anything the scan produces.
if [ ! -d "$SCANDIR" ] || [ ! -r "$SCANDIR" ]; then
  echo "comment-status-literal-check: REFUSING — scan corpus is not a readable directory:" >&2
  echo "    $SCANDIR" >&2
  echo "  A verdict over a corpus that was never opened is not a verdict. Fix the" >&2
  echo "  path, or fix the caller." >&2
  exit 3
fi

SCANNER="$(mktemp -t cslc-scan-XXXXXX).exs"
trap 'rm -f "$SCANNER"' EXIT

cat > "$SCANNER" <<'ELIXIR'
# Emits "HIT\t<path>\t<line>\t<kind>\t<text>" per site, one "PARSE_FAIL\t<path>"
# per unreadable file, then "SCANNED\t<n>" and "PARSE_FAILURES\t<n>".
root = System.get_env("CSLC_SCANDIR")
files = Path.wildcard(Path.join(root, "**/*_test.exs")) |> Enum.sort()

# `[` then optional space, a 3-digit number, optional space, `,` — a bracketed
# list of TWO OR MORE status literals. `[403]` alone is deliberately not matched.
re = ~r/\[\s*\d{3}\s*,/

{hits, parse_failures} =
  Enum.reduce(files, {[], []}, fn file, {hits, fails} ->
    case File.read(file) do
      {:ok, src} ->
        case Code.string_to_quoted_with_comments(src, columns: true) do
          {:ok, _ast, comments} ->
            lines = String.split(src, "\n")

            found =
              for c <- comments, Regex.match?(re, c.text) do
                prefix = String.slice(Enum.at(lines, c.line - 1) || "", 0, max(c.column - 1, 0))
                kind = if String.trim(prefix) == "", do: "own-line", else: "trailing"
                {c.line, kind, String.slice(c.text, 0, 100)}
              end

            {hits ++ Enum.map(Enum.sort(found), fn {l, k, t} -> {file, l, k, t} end), fails}

          {:error, _} ->
            {hits, [file | fails]}
        end

      {:error, reason} ->
        {hits, ["#{file} (#{inspect(reason)})" | fails]}
    end
  end)

# Paths are emitted RELATIVE TO THE SCAN ROOT, never to the repo root. That is
# what makes the baseline valid over a scratch COPY of api/test — which is the
# only way the --selftest real-corpus arm can judge the COMMITTED baseline
# instead of a rewritten one. The shell re-attaches a display prefix.
for {f, l, k, t} <- hits,
    do: IO.puts("HIT\t#{Path.relative_to(f, root)}\t#{l}\t#{k}\t#{t}")

for f <- Enum.sort(parse_failures),
    do: IO.puts("PARSE_FAIL\t#{Path.relative_to(f, root)}")

IO.puts("SCANNED\t#{length(files)}")
IO.puts("PARSE_FAILURES\t#{length(parse_failures)}")
ELIXIR

run_scan() {
  ( cd "$ROOT" && CSLC_SCANDIR="$SCANDIR" elixir "$SCANNER" )
}

# Baseline keys are scan-root-relative (see the scanner). This re-attaches a
# human-readable prefix for OUTPUT ONLY — "api/test" in CI, the temp path under
# --selftest. Never used as a key.
DISPLAY_PREFIX="${SCANDIR#"$ROOT"/}"

# --- selftest ---------------------------------------------------------------
# Arms (0)-(d) drive SYNTHETIC trees in a TEMP dir. Arm (0) is what stops the
# others passing vacuously: a scanner that always reports "clean" would satisfy
# a naive can-it-red test while measuring nothing. It is also the arm that
# proves the parser is doing real work — it plants a `#` inside a sigil, a
# heredoc, a string and an interpolation, none of which may be flagged.
#
# Arms (e)-(h) drive the REAL corpus path, on a SCRATCH COPY of api/test made
# here — never the live tree, which these arms mutate. Synthetic arms only ever
# prove the gate reds over trees the harness itself planted; not one of them
# touches $ROOT/api/test, so every one of them would stay green if the real
# corpus were renamed away. Each of (f)-(h) ASSERTS ITS MUTATION APPLIED before
# reading a verdict — a mutation that silently did not happen turns a
# can-it-fail arm back into a can-it-pass arm.
if [ "${1:-}" = "--selftest" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -f "$SCANNER"; rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/test"
  fails=0
  arm() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fails=$((fails+1)); return 0; }

  echo "comment-status-literal-check --selftest"
  echo

  # (0) a CLEAN file must PASS — including the four shapes a line-based scanner
  #     gets wrong: a `#` inside a sigil, inside a heredoc, inside a string, and
  #     an interpolation `#{}`. Plus a single-status `[404]` in a real comment,
  #     which names no disjunction and must not be flagged.
  cat > "$TMP/test/clean_test.exs" <<'EX'
defmodule CleanTest do
  use ExUnit.Case

  # the old check also passed on an unauthenticated request — prose, not a literal
  test "prose comment" do
    assert conn.status == 403
  end

  test "a hash inside a sigil is not a comment" do
    assert ~s(# [401, 403, 404]) != ""
  end

  test "a hash inside a heredoc is not a comment" do
    doc = """
    # old `in [401, 403, 404]` was green on a 401 too
    """

    assert doc != ""
  end

  test "a hash inside a string and an interpolation" do
    s = "# [401, 403] and #{inspect([401, 403])}"
    assert s != ""
  end

  # a single status in brackets names no disjunction: [404]
  test "single status" do
    assert conn.status == 404
  end
end
EX
  printf '0\n' > "$TMP/baseline"
  if COMMENT_STATUS_LITERAL_SCAN_FLOOR=1 COMMENT_STATUS_LITERAL_SCANDIR="$TMP/test" COMMENT_STATUS_LITERAL_BASELINE="$TMP/baseline" \
     bash "$0" >/dev/null 2>&1; then
    arm "ok" "(0) clean tree passes — sigil/heredoc/string/interpolation '#' and a lone [404] are NOT flagged"
  else
    arm "FAIL" "(0) clean tree REDDENED — the scanner over-matches; every other arm is now meaningless"
  fi

  # (a) a DEFECTIVE own-line comment over baseline must RED, naming the file.
  cat > "$TMP/test/bad_test.exs" <<'EX'
defmodule BadTest do
  use ExUnit.Case

  # old `in [401, 403, 404]` was green on an unauthenticated 401 too
  test "reworded assertion" do
    assert conn.status == 403
  end
end
EX
  out="$(COMMENT_STATUS_LITERAL_SCAN_FLOOR=1 COMMENT_STATUS_LITERAL_SCANDIR="$TMP/test" COMMENT_STATUS_LITERAL_BASELINE="$TMP/baseline" \
        bash "$0" 2>&1 || true)"
  if grep -q "bad_test.exs" <<<"$out"; then
    arm "ok" "(a) a NEW own-line site reds, naming bad_test.exs"
  else
    arm "FAIL" "(a) a new site did NOT red — the gate is asleep"
  fi

  # (a2) a TRAILING comment carrying the same literal must RED too. Without
  #      this arm the wider scope claimed in the header is unproven.
  cat > "$TMP/test/trailing_test.exs" <<'EX'
defmodule TrailingTest do
  use ExUnit.Case

  test "trailing" do
    assert conn.status == 403  # was `in [401, 403]` before the split
  end
end
EX
  out="$(COMMENT_STATUS_LITERAL_SCAN_FLOOR=1 COMMENT_STATUS_LITERAL_SCANDIR="$TMP/test" COMMENT_STATUS_LITERAL_BASELINE="$TMP/baseline" \
        bash "$0" 2>&1 || true)"
  if grep -q "trailing_test.exs" <<<"$out"; then
    arm "ok" "(a2) a TRAILING comment with the same literal reds — the wider scope is real"
  else
    arm "FAIL" "(a2) a trailing comment was not flagged — the header overclaims the scope"
  fi
  rm -f "$TMP/test/trailing_test.exs"

  # (b) the same site AT baseline must PASS (never-worse, not clean-tree).
  #     The baseline is generated BY THE TOOL rather than hand-written: the
  #     scanner emits repo-root-relative paths, and a hand-typed path silently
  #     matches nothing — which reads as "the ratchet does not grandfather"
  #     when the truth is "the baseline names a file that does not exist".
  #     Generating it here also exercises --baseline, which CI never runs.
  COMMENT_STATUS_LITERAL_SCAN_FLOOR=1 COMMENT_STATUS_LITERAL_SCANDIR="$TMP/test" bash "$0" --baseline > "$TMP/baseline2" 2>/dev/null
  if COMMENT_STATUS_LITERAL_SCAN_FLOOR=1 COMMENT_STATUS_LITERAL_SCANDIR="$TMP/test" COMMENT_STATUS_LITERAL_BASELINE="$TMP/baseline2" \
     bash "$0" >/dev/null 2>&1; then
    arm "ok" "(b) a site AT baseline passes — the ratchet grandfathers, it does not demand zero"
  else
    arm "FAIL" "(b) a baselined site reddened — this gate would red main on day one and get disabled"
  fi

  # (c) a count that FELL below baseline must RED, telling you to lower it.
  awk '/^#/{print; next} NF{printf "%d %s\n", $1 + 4, $2}' "$TMP/baseline2" > "$TMP/baseline3"
  out="$(COMMENT_STATUS_LITERAL_SCAN_FLOOR=1 COMMENT_STATUS_LITERAL_SCANDIR="$TMP/test" COMMENT_STATUS_LITERAL_BASELINE="$TMP/baseline3" \
        bash "$0" 2>&1 || true)"
  if grep -qi "lower the baseline\|ratchet" <<<"$out"; then
    arm "ok" "(c) a FIXED site reds until the baseline is lowered — the ratchet cannot rust"
  else
    arm "FAIL" "(c) a fallen count did not demand the baseline be lowered — the ratchet goes stale"
  fi

  # (d) an UNPARSEABLE file must RED by name, not be silently skipped.
  printf 'defmodule Broken do\n  test "x" do\n    assert (((\n' > "$TMP/test/broken_test.exs"
  out="$(COMMENT_STATUS_LITERAL_SCAN_FLOOR=1 COMMENT_STATUS_LITERAL_SCANDIR="$TMP/test" COMMENT_STATUS_LITERAL_BASELINE="$TMP/baseline2" \
        bash "$0" 2>&1 || true)"
  if grep -q "broken_test.exs" <<<"$out"; then
    arm "ok" "(d) an unparseable file REFUSES by name — never a silent skip"
  else
    arm "FAIL" "(d) an unparseable file was skipped silently — the scanner reports a tree it never read"
  fi

  # ---- REAL corpus path, on a scratch copy -------------------------------
  # cp -R, find and mv only: POSIX on both the macOS box this is written on and
  # the ubuntu runner it is judged on.
  REAL="$TMP/real/test"
  mkdir -p "$TMP/real"
  if cp -R "$ROOT/api/test" "$REAL" 2>/dev/null; then
    real_n="$(find "$REAL" -name '*_test.exs' -type f | wc -l | tr -d ' ')"

    # (e) the real corpus, copied intact, must PASS at the COMMITTED floor and
    #     against the COMMITTED baseline. No overrides — this is the arm that
    #     reds if SCAN_FLOOR outran api/test or the baseline went stale.
    if COMMENT_STATUS_LITERAL_SCANDIR="$REAL" bash "$0" >/dev/null 2>&1; then
      arm "ok" "(e) the REAL corpus ($real_n files) passes at the committed floor $SCAN_FLOOR and committed baseline"
    else
      arm "FAIL" "(e) the REAL corpus REDDENED at floor $SCAN_FLOOR — the floor outran api/test, the baseline is stale, or the tree is dirty"
    fi

    # (f) corpus MOVED AWAY (the realistic cause: a rename) must REFUSE.
    mv "$REAL" "$TMP/real/moved"
    if [ ! -d "$REAL" ] && [ -d "$TMP/real/moved" ]; then
      rc_f=0; out="$(COMMENT_STATUS_LITERAL_SCANDIR="$REAL" bash "$0" 2>&1)" || rc_f=$?
      if [ "$rc_f" != 0 ] && grep -q "REFUSING" <<<"$out" && grep -qF "$REAL" <<<"$out"; then
        arm "ok" "(f) a MOVED corpus refuses (rc $rc_f), naming the directory"
      else
        arm "FAIL" "(f) a MOVED corpus did not refuse (rc $rc_f) — the gate reads absence as clean"
      fi
    else
      arm "FAIL" "(f) MUTATION DID NOT APPLY — the corpus was not moved, so this arm proved nothing"
    fi
    mv "$TMP/real/moved" "$REAL"

    # (g) corpus PRESENT but EMPTIED must REFUSE on the zero-file scan.
    mkdir -p "$TMP/emptied"
    if [ -d "$TMP/emptied" ] && [ -z "$(find "$TMP/emptied" -type f)" ]; then
      rc_g=0; out="$(COMMENT_STATUS_LITERAL_SCANDIR="$TMP/emptied" bash "$0" 2>&1)" || rc_g=$?
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
    find "$REAL" -name '*_test.exs' -type f | sort | tail -n +6 | while read -r f; do
      rm -f "$f"
    done
    left_n="$(find "$REAL" -name '*_test.exs' -type f | wc -l | tr -d ' ')"
    if [ "$left_n" -lt "$real_n" ] && [ "$left_n" -gt 0 ]; then
      rc_h=0; out="$(COMMENT_STATUS_LITERAL_SCANDIR="$REAL" bash "$0" 2>&1)" || rc_h=$?
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
    echo "SELFTEST FAILED: $fails of 10 arms failed"
    exit 1
  fi
  echo "SELFTEST PASSED: 10 of 10 arms"
  exit 0
fi

# --- scan -------------------------------------------------------------------
SCAN_OUT="$(run_scan)"

PARSE_FAILS="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="PARSE_FAIL"{print $2}')"
SCANNED="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="SCANNED"{print $2}')"
NFAIL="$(printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="PARSE_FAILURES"{print $2}')"

# Placed BEFORE --list and --baseline on purpose: `--baseline` over an empty
# corpus would emit an empty allow-file and cement the blindness as the
# committed truth.
if [ "${SCANNED:-0}" -eq 0 ]; then
  echo "comment-status-literal-check: REFUSING — 0 file(s) scanned:" >&2
  echo "    $SCANDIR" >&2
  echo "  The corpus is empty, so \"0 site(s)\" says nothing about the defect —" >&2
  echo "  it is absence of the tree, not absence of the finding. Neither loop in" >&2
  echo "  this gate can tell those apart on its own: NEW/GROWN iterates the scan," >&2
  echo "  and FELL iterates a baseline that could legitimately hold zero rows." >&2
  exit 3
fi

if [ "$SCANNED" -lt "$SCAN_FLOOR" ]; then
  echo "comment-status-literal-check: REFUSING — corpus below floor:" >&2
  echo "    scanned $SCANNED file(s) under $SCANDIR, floor is $SCAN_FLOOR" >&2
  echo "  A partly-deleted corpus still scans cleanly, because every count here" >&2
  echo "  is derived from the tree being judged. The floor is the one number" >&2
  echo "  that is not. If the shrink is legitimate, say WHICH files left and" >&2
  echo "  lower SCAN_FLOOR in this script with a fresh derivation and date." >&2
  exit 3
fi

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "$SCAN_OUT" | awk -F'\t' -v pre="$DISPLAY_PREFIX" '$1=="HIT"{printf "%s/%s:%s  [%s]  %s\n", pre, $2, $3, $4, $5}'
  printf '\nscanned %s file(s) matching api/test/**/*_test.exs, %s parse failure(s)\n' "$SCANNED" "$NFAIL"
  printf 'CENSUS (the comment list comes from the Elixir tokenizer, not a line regex), not a sample.\n'
  exit 0
fi

if [ "${1:-}" = "--baseline" ]; then
  printf '# Per-file counts of COMMENTS in api/test/**/*_test.exs that reproduce a\n'
  # shellcheck disable=SC2016  # the backticks are LITERAL prose in the emitted
  # allow-file header, not command substitution — single quotes are the point.
  printf '# bracketed list of two or more HTTP status literals (e.g. `[401, 403, 404]`).\n'
  printf '# Such a comment is byte-identical to the assertion form it describes, so it\n'
  printf '# answers every grep for the REMAINING work. Narrate it in prose instead.\n'
  printf '# RATCHET: counts may only FALL. Regenerate with --baseline after fixing.\n'
  printf '# Counts, NOT file:line — a line pin slides on any insertion above it.\n'
  printf '# KEEP THIS FILE SHORT. A tripwire that grows stops discriminating; the\n'
  printf '# eighth row is waved through by the seven above it. Fix the site instead.\n'
  printf '# Paths are RELATIVE TO THE SCAN ROOT (api/test), not the repo root, so this\n'
  printf '# same file is valid over a scratch copy — which is what lets --selftest arm\n'
  printf '# (e) judge THIS baseline rather than a rewritten one.\n'
  printf '%s\n' "$SCAN_OUT" | awk -F'\t' '$1=="HIT"{c[$2]++} END{for (f in c) printf "%d %s\n", c[f], f}' | sort -k2
  exit 0
fi

# REFUSE on any unreadable file, before judging anything.
if [ "${NFAIL:-0}" != "0" ]; then
  echo "comment-status-literal-check: REFUSING — $NFAIL file(s) could not be parsed:" >&2
  printf '%s\n' "$PARSE_FAILS" | sed 's/^/    /' >&2
  echo "" >&2
  echo "  A scanner that skips what it cannot read reports a clean tree it never" >&2
  echo "  inspected. Fix the syntax, or fix the scanner — do not let it degrade." >&2
  exit 1
fi

[ -f "$BASELINE" ] || { echo "comment-status-literal-check: baseline $BASELINE is missing" >&2; exit 3; }

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
    echo "RED  $DISPLAY_PREFIX/$f — $n comment(s) reproducing a bracketed status list, baseline $b" >&2
    printf '%s\n' "$SCAN_OUT" | awk -F'\t' -v p="$f" -v pre="$DISPLAY_PREFIX" '$1=="HIT" && $2==p{printf "       %s/%s:%s  [%s]  %s\n", pre, $2, $3, $4, $5}' >&2
    rc=1
  fi
done < "$TMPD/now"

# FELL — the ratchet must be tightened, or it rusts at a number nobody re-earns.
while read -r n f; do
  [ -z "${f:-}" ] && continue
  c="$(awk -v p="$f" '$2==p{print $1}' "$TMPD/now")"
  c="${c:-0}"
  if [ "$c" -lt "$n" ]; then
    echo "RATCHET  $DISPLAY_PREFIX/$f — now $c, baseline $n. Lower the baseline (counts may only fall):" >&2
    echo "         run: scripts/comment-status-literal-check.sh --baseline > .github/comment-status-literal.allow" >&2
    rc=1
  fi
done < "$TMPD/base"

TOTAL="$(awk '{s+=$1} END{print s+0}' "$TMPD/now")"
if [ "$rc" = 0 ]; then
  echo "comment-status-literal-check: OK — $TOTAL site(s) at or below baseline, $SCANNED file(s) scanned (floor $SCAN_FLOOR), 0 parse failures (CENSUS, not a sample)"
else
  echo "" >&2
  echo "  FIX: narrate the removed assertion in PROSE, naming the statuses in words:" >&2
  echo "       # the old check also passed on an unauthenticated request and on a" >&2
  echo "       # not-found id — this door gives forbidden, and only forbidden" >&2
  echo "  A comment that quotes the bracket literal is byte-identical to the thing" >&2
  echo "  the next sweep is hunting, so it answers that grep instead of the defect." >&2
fi
exit "$rc"
