#!/usr/bin/env bash
#
# failure-copy-scrub-order-check.sh — the ORDER tripwire over
# `BarkparkCloud.FailureCopy`'s two display-boundary verbs.
#
# WHY THIS EXISTS
# ---------------
# `FailureCopy.strip_ansi/1` removes CSI runs; `FailureCopy.scrub/1` redacts
# credentials. The order is load-bearing in ONE direction only:
#
#     strip_ansi |> scrub    the escapes are gone, so scrub's key clause sees
#                            `api_key=…` with nothing wedged in front of it and
#                            redacts it.
#     scrub |> strip_ansi    a CSI run parks an alphanumeric immediately left of
#                            the key, the key clause never fires, and the
#                            TRAILING strip then removes the very escapes that
#                            blocked it — the credential lands on the surface in
#                            clean CLEARTEXT.
#
# dr-w22-s1 fixed three `scrub_entry/2` boundaries. The wave REVIEW then found a
# FOURTH — `Web.Router.deployment_json/1`'s `failure_reason_raw`, which had
# hand-piped `scrub` before `strip_ansi`. BOTH instances were found by a human
# reading the file. Nothing in the tree reds when a FIFTH boundary is added the
# same way. This is that red.
#
# WHAT IT REFUSES (the rule, in words)
# ------------------------------------
# Over every `cloud/lib/**/*.ex` EXCEPT `failure_copy.ex` (the module's own
# definitions — `humanize/1` legitimately ends `scrub |> strip_ansi`, and
# `raw/1` is the one blessed composition), for every expression that mentions
# `FailureCopy.scrub`:
#
#   (a) REVERSED ORDER — the expression also mentions `FailureCopy.strip_ansi`,
#       and `scrub` comes FIRST. Expressions are read as LOGICAL lines: a line
#       ending in `|>`, or followed by a line starting with `|>`, is joined to
#       its neighbour, so a multi-line pipe chain is one expression. The nested
#       spelling `FailureCopy.scrub(FailureCopy.strip_ansi(x))` is CORRECT
#       (scrub is textually first but semantically outermost) and is exempted
#       explicitly, not by accident.
#
#   (b) UNPROVEN INPUT — the expression does NOT mention `FailureCopy.strip_ansi`
#       at all, i.e. a bare `FailureCopy.scrub(x)` / `x |> FailureCopy.scrub()`.
#       That is refused UNLESS `x` is PROVABLY the strip_ansi output, which this
#       check defines as exactly one thing it can verify from the text:
#
#           `x` is a plain identifier, and somewhere between the enclosing
#           `def`/`defp` head and this expression there is an assignment
#           `x = …strip_ansi…`.
#
#       Anything else — a field access, a function call, a literal, an
#       identifier with no such binding — is NOT proven and is a red. The
#       message says which of the two clauses fired, so the author knows whether
#       to reorder or to name the binding.
#
# COMMENTS AND DOC LINES ARE IN SCOPE, deliberately. A `@moduledoc` line that
# PRESCRIBES the order is measured like code — `sites/deploy.ex:120` reads as an
# ordered site today, and a doc line that told the next author to scrub first
# would red. Prose that teaches the leaky order is the same defect one step
# upstream.
#
# POSITIVE CONTROL. A zero from an empty scan is indistinguishable from a zero
# from a clean tree, so the check PRINTS its denominator: files scanned, .ex
# files read, `FailureCopy.scrub` expressions seen, and every ordered-correct
# site it recognised, `file:line`. A run that reports 0 violations over 0
# expressions is a scan that measured nothing, and the check says so and fails.
#
# EXIT CODES: 0 clean · 1 at least one violation · 2 cannot measure.
#
# bash 3.2 compatible (macOS runs it too). POSIX awk only — no gensub, no
# ENDFILE, no associative-array iteration order assumptions.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN_ROOT="${SCRUB_ORDER_SCAN_ROOT:-$REPO_ROOT/cloud/lib}"
EXCLUDE_BASENAME="${SCRUB_ORDER_EXCLUDE:-failure_copy.ex}"

MODE="check"
case "${1:-}" in
  --selftest) MODE="selftest" ;;
  --root) SCAN_ROOT="${2:?--root needs a directory}"; shift 2 ;;
  "") ;;
  *) echo "usage: $0 [--selftest] [--root DIR]" >&2; exit 2 ;;
esac
if [ "${1:-}" = "--root" ]; then SCAN_ROOT="${2:?--root needs a directory}"; fi

# ── the scanner ─────────────────────────────────────────────────────────────
# Emits, on stdout, one record per interesting site:
#   OK   <file>:<line> ordered   <text>
#   OK   <file>:<line> nested    <text>
#   OK   <file>:<line> bound:<id> <text>
#   BAD  <file>:<line> (a) …
#   BAD  <file>:<line> (b) …
# and one `SEEN <n>` line per file (count of scrub expressions).
scan_file() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function lasttok(s,   n, a) {
      s = trim(s)
      gsub(/[()\[\]{},]/, " ", s)
      n = split(s, a, /[ \t]+/)
      return n ? a[n] : ""
    }
    # the argument of the FIRST FailureCopy.scrub( in s, paren-balanced
    function scrubarg(s,   p, i, d, c, out) {
      p = index(s, "FailureCopy.scrub(")
      if (p == 0) return ""
      i = p + length("FailureCopy.scrub(")
      d = 1; out = ""
      while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == "(") d++
        else if (c == ")") { d--; if (d == 0) break }
        out = out c
        i++
      }
      return trim(out)
    }
    { line[NR] = $0
      t = trim($0)
      if (t ~ /^(def|defp)[ \t(]/) lastdef[NR] = 1
    }
    END {
      n = NR
      # enclosing def head for every line
      cur = 0
      for (i = 1; i <= n; i++) { if (lastdef[i]) cur = i; owner[i] = cur }

      seen = 0
      i = 1
      while (i <= n) {
        # build the logical expression starting at i
        start = i
        text = line[i]
        while (i < n) {
          a = trim(line[i]); b = trim(line[i + 1])
          if (a ~ /\|>$/ || b ~ /^\|>/) { i++; text = text " " trim(line[i]) }
          else break
        }
        i++

        if (index(text, "FailureCopy.scrub") == 0) continue
        seen++
        ip = index(text, "FailureCopy.scrub")
        is = index(text, "FailureCopy.strip_ansi")

        if (is > 0 && is < ip) {
          printf "OK\t%s:%d\tordered\t%s\n", FN, start, trim(text)
          continue
        }
        if (is > 0 && is > ip) {
          # the nested spelling is correct: scrub(strip_ansi(x))
          probe = substr(text, ip)
          sub(/^FailureCopy\.scrub\([ \t]*/, "", probe)
          if (probe ~ /^FailureCopy\.strip_ansi\(/) {
            printf "OK\t%s:%d\tnested\t%s\n", FN, start, trim(text)
            continue
          }
          printf "BAD\t%s:%d\t(a) FailureCopy.scrub is applied BEFORE FailureCopy.strip_ansi in one expression — a colourised credential survives scrub and the trailing strip then unmasks it. Use FailureCopy.raw/1, or strip_ansi first.\t%s\n", FN, start, trim(text)
          next_bad = 1
          continue
        }

        # bare scrub: is the input provably the strip_ansi output?
        pre = substr(text, 1, ip - 1)
        if (pre ~ /\|>[ \t]*$/) {
          sub(/\|>[ \t]*$/, "", pre)
          src = lasttok(pre)
        } else {
          src = scrubarg(text)
        }
        if (src ~ /^[a-z_][a-zA-Z0-9_]*[?!]?$/) {
          # look back to the enclosing def head for `src = …strip_ansi…`
          top = owner[start]; if (top == 0) top = 1
          found = 0
          for (j = top; j < start; j++) {
            l = line[j]
            if (index(l, "strip_ansi") == 0) continue
            pat = "(^|[^a-zA-Z0-9_.])" src "[ \t]*="
            if (l ~ pat) { found = j; break }
          }
          if (found) {
            printf "OK\t%s:%d\tbound:%s@%d\t%s\n", FN, start, src, found, trim(text)
            continue
          }
        }
        printf "BAD\t%s:%d\t(b) bare FailureCopy.scrub on an input this check cannot prove is strip_ansi output (arg: %s). Pipe strip_ansi first, call FailureCopy.raw/1, or bind the stripped value in this function.\t%s\n", FN, start, (src == "" ? "<none>" : src), trim(text)
      }
      printf "SEEN\t%d\n", seen
    }
  ' FN="$2" "$1"
}

run_scan() {
  local root="$1"
  local files=0 exfiles=0 seen=0 bad=0 ok=0
  local out rc
  [ -d "$root" ] || { echo "HARNESS-UNAVAILABLE: scan root not found: $root" >&2; return 2; }

  echo "── FailureCopy scrub/strip_ansi ORDER check ──"
  echo "scan root: $root  (excluding basename: $EXCLUDE_BASENAME)"
  echo

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/scruborder.XXXXXX")"
  # shellcheck disable=SC2044
  while IFS= read -r f; do
    exfiles=$((exfiles + 1))
    case "$(basename "$f")" in "$EXCLUDE_BASENAME") continue ;; esac
    files=$((files + 1))
    scan_file "$f" "${f#"$root"/}" >>"$tmp"
  done < <(find "$root" -type f -name '*.ex' | LC_ALL=C sort)

  seen=$(awk -F'\t' '$1=="SEEN" { s += $2 } END { print s + 0 }' "$tmp")
  ok=$(awk -F'\t' '$1=="OK"' "$tmp" | wc -l | tr -d ' ')
  bad=$(awk -F'\t' '$1=="BAD"' "$tmp" | wc -l | tr -d ' ')

  echo "POSITIVE CONTROL — the sites this scan actually READ:"
  if [ "$ok" -eq 0 ]; then
    echo "  (none)"
  else
    awk -F'\t' '$1=="OK" { printf "  ok  %-58s %-14s %s\n", $2, $3, $4 }' "$tmp"
  fi
  echo
  echo "scanned: $exfiles .ex files ($files after the failure_copy.ex exclusion)"
  echo "FailureCopy.scrub expressions seen: $seen   correct: $ok   violations: $bad"
  echo

  if [ "$bad" -gt 0 ]; then
    # Annotations must be REPO-RELATIVE or GitHub drops them silently, so the
    # scan root is re-expressed against the repo root before it is emitted.
    local relbase="${root#"$REPO_ROOT"/}"
    [ "$relbase" = "$root" ] && relbase=""
    awk -F'\t' -v base="$relbase" '
      $1=="BAD" {
        split($2, loc, ":")
        f = (base == "" ? loc[1] : base "/" loc[1])
        printf "::error file=%s,line=%s::scrub-order: %s\n", f, loc[2], $3
        printf "  RED %s\n    %s\n    > %s\n", $2, $3, $4
      }' "$tmp"
    rm -f "$tmp"
    echo "FAILED: $bad boundary/boundaries order FailureCopy.scrub wrongly."
    return 1
  fi

  rm -f "$tmp"
  if [ "$seen" -eq 0 ]; then
    echo "REFUSED: zero FailureCopy.scrub expressions were seen — a clean scan and an EMPTY scan are indistinguishable, and this is the empty one."
    return 2
  fi
  echo "OK: every FailureCopy.scrub site strips ANSI first (or is a proven-stripped binding)."
  return 0
}

# ── selftest ────────────────────────────────────────────────────────────────
selftest() {
  local pass=0 fail=0
  ok()  { pass=$((pass + 1)); echo "ok   - $*"; }
  bad() { fail=$((fail + 1)); echo "FAIL - $*"; }

  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/scruborder-st.XXXXXX")"
  trap 'rm -rf "$d"' RETURN

  # F1 correct single-line pipe + F2 the proven binding
  mkdir -p "$d/good"
  cat >"$d/good/good.ex" <<'EX'
defmodule Good do
  def a(d), do: d |> FailureCopy.strip_ansi() |> FailureCopy.scrub()

  def b(v) do
    stripped = FailureCopy.strip_ansi(v)
    capture = FailureCopy.scrub(stripped)
    capture
  end

  def c(v), do: FailureCopy.scrub(FailureCopy.strip_ansi(v))
end
EX
  # the module's own file must be EXCLUDED even when it holds the leaky order
  cat >"$d/good/failure_copy.ex" <<'EX'
defmodule FailureCopy do
  def humanize(r), do: r |> FailureCopy.scrub() |> FailureCopy.strip_ansi()
end
EX

  # F3 reversed, single line
  mkdir -p "$d/rev"
  cat >"$d/rev/rev.ex" <<'EX'
defmodule Rev do
  def a(d), do: d |> FailureCopy.scrub() |> FailureCopy.strip_ansi()
end
EX

  # F4 reversed, MULTI-LINE pipe
  mkdir -p "$d/multi"
  cat >"$d/multi/multi.ex" <<'EX'
defmodule Multi do
  def a(d) do
    d
    |> FailureCopy.scrub()
    |> FailureCopy.strip_ansi()
  end
end
EX

  # F5 bare scrub on an UNKNOWN binding
  mkdir -p "$d/bare"
  cat >"$d/bare/bare.ex" <<'EX'
defmodule Bare do
  def a(d) do
    whatever = d.failure_reason
    FailureCopy.scrub(whatever)
  end
end
EX

  # F6 bare scrub on a field access (never provable)
  mkdir -p "$d/field"
  cat >"$d/field/field.ex" <<'EX'
defmodule Field do
  def a(d), do: FailureCopy.scrub(d.failure_reason)
end
EX

  # F7 a binding from ANOTHER function must not vouch (scope discipline)
  mkdir -p "$d/scope"
  cat >"$d/scope/scope.ex" <<'EX'
defmodule Scope do
  def a(v) do
    stripped = FailureCopy.strip_ansi(v)
    stripped
  end

  def b(v) do
    stripped = v.raw
    FailureCopy.scrub(stripped)
  end
end
EX

  # F8 nothing to see — the empty-scan refusal must fire, not a green
  mkdir -p "$d/empty"
  cat >"$d/empty/empty.ex" <<'EX'
defmodule Empty do
  def a(v), do: v
end
EX

  local out rc

  out="$(run_scan "$d/good" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then ok "correct order is GREEN (single-line pipe, proven binding, nested spelling)"
  else bad "correct order should be green, got exit $rc"; echo "$out" | sed 's/^/       /'; fi
  if printf '%s' "$out" | grep -q "expressions seen: 3"; then ok "positive control counted all 3 correct sites"
  else bad "positive control did not count 3 sites"; printf '%s\n' "$out" | sed 's/^/       /'; fi
  # NOT a whole-output grep: the header line prints the excluded basename, so
  # `grep failure_copy.ex` over $out matches on a CORRECT run. Assert on a
  # CITATION (`failure_copy.ex:<line>`) instead — and prove the assertion can
  # fail by re-running with the exclusion pointed elsewhere, which must red.
  if printf '%s' "$out" | grep -q "failure_copy\.ex:[0-9]"; then bad "failure_copy.ex was NOT excluded"
  else ok "failure_copy.ex is excluded (its leaky humanize order does not red)"; fi
  out="$(EXCLUDE_BASENAME=__none__ run_scan "$d/good" 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "failure_copy\.ex:2"; then
    ok "the exclusion is LOAD-BEARING: with it pointed elsewhere the same tree reds at failure_copy.ex:2"
  else bad "non-vacuity: dropping the exclusion should red failure_copy.ex:2, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(run_scan "$d/rev" 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "rev.ex:2" && printf '%s' "$out" | grep -q "(a)"; then
    ok "reversed order is RED and names rev.ex:2 with clause (a)"
  else bad "reversed order should red at rev.ex:2 (a), got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(run_scan "$d/multi" 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "multi.ex:3" && printf '%s' "$out" | grep -q "(a)"; then
    ok "MULTI-LINE reversed pipe is RED and names multi.ex:3"
  else bad "multi-line reversed pipe should red at multi.ex:3, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(run_scan "$d/bare" 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "(b)" && printf '%s' "$out" | grep -q "whatever"; then
    ok "bare scrub on an unknown binding is RED and names the argument"
  else bad "bare scrub on unknown binding should red (b), got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(run_scan "$d/field" 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "(b)"; then ok "bare scrub on a field access is RED"
  else bad "bare scrub on a field access should red (b), got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(run_scan "$d/scope" 2>&1)"; rc=$?
  if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "(b)"; then
    ok "a strip_ansi binding in a DIFFERENT function does not vouch (the lookback stops at the def head)"
  else bad "cross-function binding must not vouch, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  out="$(run_scan "$d/empty" 2>&1)"; rc=$?
  if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q "REFUSED"; then
    ok "an EMPTY scan refuses (exit 2) instead of reporting a green zero"
  else bad "empty scan should refuse with exit 2, got exit $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi

  echo
  echo "selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

if [ "$MODE" = "selftest" ]; then
  selftest
  exit $?
fi

run_scan "$SCAN_ROOT"
exit $?
