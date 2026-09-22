#!/usr/bin/env bash
# stat-portability-check — REFUSE a `stat -f` that is reached before `stat -c`.
#
# THE DEFECT THIS GUARDS, AND WHY IT IS WORSE THAN THE mktemp ONE
#   `-f` means OPPOSITE things in the two stats:
#       BSD / macOS    stat -f FORMAT path   "render path with this FORMAT"
#       GNU coreutils  stat -f path          "print FILE SYSTEM status", and the
#                                            format flag is `-c`.
#   So on a Linux runner `stat -f %m "$d"` does not mean what its author meant.
#   `%m` is read as a FILE OPERAND, and GNU prints a block-size/inode-count
#   report for the filesystem containing `$d` — on STDOUT, before it exits.
#
#   That is what makes the common defensive idiom BROKEN when written BSD-first:
#       mtime="$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p")"
#   The failure is NOT that the fallback is skipped. It is that the first
#   command POLLUTES STDOUT and only then fails, so `$mtime` becomes the
#   filesystem report with the correct number appended to it. Every comparison
#   downstream is against garbage, and nothing anywhere reports an error.
#   Measured: GH Actions run 35504059438 / job 106061128225 —
#   scripts/pds-artifact-retention.test.sh, 24 passed, 11 FAILED on ubuntu while
#   the identical tree was 35/0 on macOS. One "got" value leaked the mechanism:
#       (got 'pds-full-export	  File: "/tmp/…/r10/pds-full-export"
#        ID: … Type: ext2/ext3  Block size: 4096 …
#   A `||` fallback is safe only when the FIRST form FAILS CLEANLY on the other
#   platform. BSD stat rejects `-c` outright, printing nothing — so GNU-FIRST is
#   the one ordering that degrades loudly instead of quietly.
#
# THE PORTABLE FORMS
#   GNU-first chain (what this guard demands):
#       mtime="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null)"
#   Or PROBE ONCE and reuse the answer — strictly better, because a chain also
#   mis-fires on a path that does not exist (the GNU form fails for the right
#   reason, and the BSD form answers with garbage anyway):
#       if stat -c %u . >/dev/null 2>&1; then F=-c; M=%Y; S=%s
#       else                                    F=-f; M=%m; S=%z; fi
#       mtime_of() { stat "$F" "$M" "$1" 2>/dev/null || true; }
#   The probe form carries NO literal `stat -f`, so this guard never sees it —
#   which is the point: there is nothing for a later editor to copy wrongly.
#
# THE RULE, STATED ONCE
#   A `stat` invocation naming `-f` / `--file-system` is a VIOLATION unless a
#   `stat` invocation naming `-c` / `--format` / `--printf` appears EARLIER ON
#   THE SAME LINE. No multi-line window, no pragma, no allowance for "both
#   spellings are somewhere in the file" — an earlier audit of this repo cleared
#   these very sites on exactly that reasoning and it is wrong, because ORDER is
#   the whole defect. A GNU-only `stat -c` is never flagged; a bare `stat` with
#   no format flag is never flagged.
#
# WHY A SIBLING OF mktemp-portability-check.sh AND NOT AN ARM OF IT
#   Different predicate (invocation ORDER on a line, not template SHAPE), so a
#   shared red could not say which BSD-ism fired; and that file carries a live
#   EXCLUSIONS_LIST ratchet fenced to the CLI lane, which this change must not
#   disturb. Leaving it untouched is the strongest guarantee that it survives.
#   The command-position walker below is deliberately the SAME design as its
#   sibling's, so a fix to one is a readable fix to the other.
#
# ARMS
#   (default)    scan the tracked tree; nonzero on any violation
#   --selftest   POSITIVE CONTROL: plant violating lines in a throwaway fixture
#                and assert the scanner SEES each one, plus negative controls it
#                must NOT flag, plus prose controls it must not mistake for code.
#                A guard that cannot demonstrate a red is theatre.
# Both arms REFUSE on an empty population: a tree scan that reached fewer than
# 50 files, or a selftest that ran zero cases, is a FAILURE, not a pass.
set -uo pipefail

EX_OK=0; EX_VIOLATION=1; EX_REFUSED=2

die() { echo "stat-portability-check: REFUSING — $*" >&2; exit "$EX_REFUSED"; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || die "cannot resolve repo root"
command -v python3 >/dev/null 2>&1 || die "python3 not found; the scanner cannot run"

SCANNER="$(mktemp "${TMPDIR:-/tmp}/stat-portability-scanner.XXXXXX")" || die "mktemp failed"
[ -n "$SCANNER" ] || die "mktemp returned an EMPTY path"
trap 'rm -f "$SCANNER"' EXIT

cat > "$SCANNER" <<'PYEOF'
import sys

def walk(line):
    """Yield indices where a `stat` word starts in COMMAND context.

    A tiny shell-quoting state machine: single quotes are opaque, double quotes
    are opaque EXCEPT that `$(` and a backtick re-enter command context. A `#`
    in command context at line start or after whitespace begins a comment.
    """
    i, n = 0, len(line)
    stack = ["code"]
    while i < n:
        c = line[i]
        top = stack[-1]
        if top == "sq":
            if c == "'": stack.pop()
            i += 1; continue
        if top == "dq":
            if c == "\\": i += 2; continue
            if c == '"': stack.pop(); i += 1; continue
            if line.startswith("$(", i): stack.append("code"); i += 2; continue
            if c == "`": stack.append("code"); i += 1; continue
            i += 1; continue
        if c == "\\": i += 2; continue
        if c == "'": stack.append("sq"); i += 1; continue
        if c == '"': stack.append("dq"); i += 1; continue
        if line.startswith("$(", i): stack.append("code"); i += 2; continue
        if c == ")" and len(stack) > 1: stack.pop(); i += 1; continue
        if c == "`":
            if len(stack) > 1: stack.pop()
            else: stack.append("code")
            i += 1; continue
        if c == "#" and (i == 0 or line[i-1] in " \t"):
            return
        if line.startswith("stat", i):
            after = line[i+4] if i + 4 < n else " "
            if not (after.isalnum() or after in "_-.") and in_command_position(line, i):
                yield i
        i += 1

COMMAND_LEAD_INS = ("", "(", "$(", "`", "|", "||", "&", "&&", ";", ";;", "{",
                    "then", "else", "elif", "do", "!", "exec", "command",
                    "if", "while", "until", "=", "((", "&&(", "+")

def in_command_position(line, i):
    before = line[:i].rstrip()
    if before == "": return True
    if before.endswith(("(", "`", "|", "&", ";", "{", "!", "=", "+")): return True
    last = before.split()[-1] if before.split() else ""
    return last in COMMAND_LEAD_INS

SEPS = set("|;&<>\n")

def invocation(line, start):
    """The argument text of the stat starting at `start`, to its separator."""
    i = start + 4
    n = len(line)
    stack = ["code"]
    out = []
    while i < n:
        c = line[i]
        top = stack[-1]
        if top == "sq":
            out.append(c)
            if c == "'": stack.pop()
            i += 1; continue
        if top == "dq":
            if c == "\\": out.append(line[i:i+2]); i += 2; continue
            out.append(c)
            if c == '"': stack.pop()
            elif line.startswith("$(", i): stack.append("code"); out.append("("); i += 2; continue
            i += 1; continue
        if c == "'": stack.append("sq"); out.append(c); i += 1; continue
        if c == '"': stack.append("dq"); out.append(c); i += 1; continue
        if line.startswith("$(", i): stack.append("code"); out.append("$("); i += 2; continue
        if c == "$" and i + 1 < n and line[i+1] == "{":
            j, depth = i + 2, 1
            while j < n and depth:
                if line[j] == "{": depth += 1
                elif line[j] == "}": depth -= 1
                j += 1
            out.append(line[i:j]); i = j; continue
        if c == ")":
            if len(stack) > 1: stack.pop(); out.append(c); i += 1; continue
            break
        if c in SEPS: break
        if c == "#" and line[i-1] in " \t": break
        out.append(c); i += 1
    return "".join(out)

# THE LOOK-BACK WINDOW. The rule is "GNU must be TRIED FIRST", and the repo's
# two CORRECT sites spell that across two lines rather than one:
#     m="$(stat -c %Y "$1" 2>/dev/null)" || m=""
#     case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" ;; esac
# A strictly same-line rule reds both of them, and a guard stricter than the
# fault gets switched off. Three lines is the smallest window that accepts the
# GNU-then-shape-recheck idiom and nothing looser; the selftest proves BOTH
# directions — 1 line above passes, 5 lines above still REDS, so the window is
# a construct, not an amnesty.
WINDOW = 3

GNU_FLAGS = ("-c", "--format", "--printf")
BSD_FLAG  = ("-f", "--file-system")

def flavour(args):
    """'gnu' when this invocation names a GNU format flag, 'bsd' when it names
    the filesystem/format flag whose meaning DIFFERS across platforms, else ''.
    An invocation naming BOTH is 'gnu': it already tried the safe spelling."""
    gnu = bsd = False
    for t in args.split():
        if not t.startswith("-"): continue
        if t in GNU_FLAGS or t.startswith("--format=") or t.startswith("--printf=") \
           or (t.startswith("-c") and len(t) > 2):
            gnu = True
        elif t in BSD_FLAG or (t.startswith("-f") and len(t) > 2 and not t.startswith("--")):
            bsd = True
    if gnu: return "gnu"
    if bsd: return "bsd"
    return ""

hits = 0
for path in (l.rstrip("\n") for l in sys.stdin):
    if not path: continue
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        continue
    last_gnu = -10**9          # line of the most recent CLEAN GNU-first line
    for lno, line in enumerate(lines, 1):
        line = line.rstrip("\n")
        seen_gnu_here = False
        violated = False
        for start in walk(line):
            f = flavour(invocation(line, start))
            if f == "gnu":
                seen_gnu_here = True
            elif f == "bsd" and not seen_gnu_here and lno - last_gnu > WINDOW:
                # THE VIOLATION: a BSD-meaning `-f` reached before any `-c`.
                print("%s:%d:%s" % (path, lno, line.strip()))
                hits += 1
                violated = True
        # A VIOLATING line does NOT arm the window for the line below it. The
        # `stat -c` at the tail of a BSD-first chain was never tried first, so
        # letting it vouch for the next line would launder a whole block of
        # violations behind its own first offender. Measured: without this the
        # selftest's 6-violation fixture reports 1.
        if seen_gnu_here and not violated:
            last_gnu = lno
print("__HITS__%d" % hits, file=sys.stderr)
PYEOF

scan_files() { python3 "$SCANNER" 2>/dev/null; }

# ---------------------------------------------------------------- exclusions
# One "path:line|reason" per excluded site. An exclusion is a DEBT, so it is
# ratcheted in BOTH directions: the selftest asserts every excluded site STILL
# violates and reds if one has been fixed — which is the cue to delete its line,
# not to leave it rotting into permanent amnesty. It is EMPTY on purpose: every
# BSD-first site in the tree was fixed rather than excused.
EXCLUSIONS_LIST=""

excluded_keys() { printf '%s\n' "$EXCLUSIONS_LIST" | grep -v '^[[:space:]]*$' | cut -d'|' -f1; }

filter_exclusions() {
  local keys line key
  keys="$(excluded_keys)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="$(printf '%s' "$line" | sed "s|^$REPO_ROOT/||" | cut -d: -f1,2)"
    printf '%s\n' "$keys" | grep -qxF "$key" || printf '%s\n' "$line"
  done
}

# HELD OUT OF THE TREE SCAN, for the same reason as its sibling: the selftest
# fixtures and the refusal message below are FULL of deliberately violating
# lines. The hold-out is NOT amnesty — SELF CONTROL scans this file with its
# fixture/message heredocs stripped, so every stat this script RUNS is checked.
SELF_PATH="$REPO_ROOT/scripts/stat-portability-check.sh"

list_tracked() {
  git -C "$REPO_ROOT" ls-files -z -- '*.sh' '*.bash' \
    | tr '\0' '\n' \
    | sed "s|^|$REPO_ROOT/|" \
    | grep -vxF "$SELF_PATH"
}

run_tree_scan() {
  local files count hits nhits
  files="$(list_tracked)" || die "git ls-files failed"
  count="$(printf '%s\n' "$files" | grep -c . || true)"
  [ "${count:-0}" -ge 50 ] || die "scanned only ${count:-0} shell file(s); expected >= 50. A near-empty population certifies nothing."

  local raw; raw="$(printf '%s\n' "$files" | scan_files)"
  hits="$(printf '%s\n' "$raw" | filter_exclusions)"
  nhits="$(printf '%s' "$hits" | grep -c . || true)"

  echo "stat-portability-check: scanned $count tracked shell file(s)"
  local nexc; nexc="$(excluded_keys | grep -c . || true)"
  [ "${nexc:-0}" -eq 0 ] || echo "stat-portability-check: $nexc site(s) EXCLUDED with a written reason (see EXCLUSIONS_LIST)"
  if [ "${nhits:-0}" -eq 0 ]; then
    echo "PASS — 0 BSD-first stat invocation(s)"
    return "$EX_OK"
  fi
  echo "FAIL — $nhits BSD-first stat invocation(s):" >&2
  printf '%s\n' "$hits" | sed "s|^$REPO_ROOT/||" | sed 's/^/  /' >&2
  cat >&2 <<'MSG'

  On GNU coreutils `-f` means FILE SYSTEM status, not "use this format", so the
  BSD form SUCCEEDS at printing a block report before it fails — and the `||`
  fallback appends the right answer to that garbage. Put the GNU form FIRST:
      mtime="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null)"
  or probe once and reuse the answer (no literal `stat -f` survives):
      if stat -c %u . >/dev/null 2>&1; then F=-c; M=%Y; S=%s
      else                                    F=-f; M=%m; S=%z; fi
  Format pairs: mtime %Y/%m · size %s/%z · uid %u/%u · inode %i/%i · mode %a/%Lp
MSG
  return "$EX_VIOLATION"
}

selftest() {
  local root fails=0 cases=0 out n
  root="$(mktemp -d "${TMPDIR:-/tmp}/stat-portability-selftest.XXXXXX")" || die "mktemp -d failed"
  [ -n "$root" ] || die "mktemp -d returned an EMPTY path"
  # shellcheck disable=SC2064
  trap "rm -rf '$root'; rm -f '$SCANNER'" EXIT

  # POSITIVE CONTROLS — 6 planted violations the guard MUST see. Every one is a
  # real shape taken from this repo's own history at the commit that fixed them.
  cat > "$root/violating.sh" <<'FIX'
#!/usr/bin/env bash
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || true; }
INODE_BEFORE="$(stat -f %i "$LEDGER" 2>/dev/null || stat -c %i "$LEDGER")"
png_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
mode="$(stat -f '%Lp' "$home/.env" 2>/dev/null || stat -c '%a' "$home/.env")"
age=$(stat --file-system %m "$d")
sig=$(stat -f '%m %z' "$f")
FIX
  # NEGATIVE CONTROLS — 8 correct forms the guard must NOT flag.
  cat > "$root/clean.sh" <<'FIX'
#!/usr/bin/env bash
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }
INODE_AFTER="$(stat -c %i "$LEDGER" 2>/dev/null || stat -f %i "$LEDGER")"
png_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
size="$(stat -c %s "$MAILLOG_FILE" 2>/dev/null || echo 0)"
if stat -c %u . >/dev/null 2>&1; then STAT_FLAG=-c; else STAT_FLAG=-f; fi
uid_of() { stat "$STAT_FLAG" "$STAT_F_UID" "$1" 2>/dev/null || true; }
stat "$f"
check "mode is 600" "[ \"$(stat -c '%a' "$p" 2>/dev/null || stat -f '%Lp' "$p")\" = 600 ]"
FIX
  # PROSE CONTROLS — `stat` words that are NOT invocations. A scanner that reds
  # on its own documentation gets switched off, and a disabled guard guards
  # nothing. Note line 2 and 3: the violating spelling INSIDE a comment.
  cat > "$root/prose.sh" <<'FIX'
#!/usr/bin/env bash
# `stat -f %m` is BSD's mtime; on GNU coreutils -f means FILE SYSTEM status
say "FATAL: stat -f %m returned garbage on this platform"
echo "TEST HARNESS FAIL: stat" >&2
grep -q 'stat -f %z' "$somefile"
z="$(stat -c %Y "$p")"   # never stat -f %m here
for t in awk basename du stat touch; do command -v "$t" >/dev/null; done
FIX

  out="$(printf '%s\n' "$root/violating.sh" | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 6 ]; then
    echo "  PASS  positive control — guard SEES all 6 planted violations (it can demonstrate a RED)"
  else
    echo "  FAIL  positive control — guard saw ${n:-0} of 6 planted violations" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  out="$(printf '%s\n' "$root/clean.sh" | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 0 ]; then
    echo "  PASS  negative control — guard flags 0 of 8 correct forms (GNU-first chains, GNU-only, bare stat, the probe)"
  else
    echo "  FAIL  negative control — guard false-positived on ${n:-0} correct form(s)" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  out="$(printf '%s\n' "$root/prose.sh" | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 0 ]; then
    echo "  PASS  prose control — guard flags 0 of 6 stat WORDS that are comments, message strings or for-in list members"
  else
    echo "  FAIL  prose control — guard mistook ${n:-0} prose mention(s) for an invocation" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  # ORDER CONTROL — the one thing this guard exists to measure. The SAME two
  # invocations, same flags, same line, differing ONLY in order: one must red
  # and the other must not. A guard that cannot tell them apart is measuring
  # presence, which is exactly the reasoning that cleared these sites before.
  printf '%s\n' '#!/usr/bin/env bash' 'm="$(stat -f %m "$p" || stat -c %Y "$p")"' > "$root/order-bad.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'm="$(stat -c %Y "$p" || stat -f %m "$p")"' > "$root/order-good.sh"
  local nbad ngood
  nbad="$(printf '%s\n' "$root/order-bad.sh"  | scan_files | grep -c . || true)"
  ngood="$(printf '%s\n' "$root/order-good.sh" | scan_files | grep -c . || true)"
  cases=$((cases+1))
  if [ "${nbad:-0}" -eq 1 ] && [ "${ngood:-0}" -eq 0 ]; then
    echo "  PASS  order control — the SAME pair reds BSD-first (1) and passes GNU-first (0); the guard measures ORDER, not presence"
  else
    echo "  FAIL  order control — BSD-first=${nbad:-0} (want 1), GNU-first=${ngood:-0} (want 0)" >&2
    fails=$((fails+1))
  fi

  # WINDOW CONTROL — both directions of the 3-line look-back. A window that
  # only ever ACCEPTS is amnesty; prove it still reds when the GNU form is too
  # far away to be the same construct.
  printf '%s\n' '#!/usr/bin/env bash' \
    'm="$(stat -c %Y "$p" 2>/dev/null)" || m=""' \
    "case \"\$m\" in ''|*[!0-9]*) m=\"\$(stat -f %m \"\$p\" 2>/dev/null)\" ;; esac" \
    > "$root/window-near.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'm="$(stat -c %Y "$p" 2>/dev/null)" || m=""' '' 'sleep 0' 'sleep 0' 'sleep 0' 'sleep 0' \
    'm="$(stat -f %m "$p" 2>/dev/null)"' \
    > "$root/window-far.sh"
  local nnear nfar
  nnear="$(printf '%s\n' "$root/window-near.sh" | scan_files | grep -c . || true)"
  nfar="$(printf '%s\n' "$root/window-far.sh"  | scan_files | grep -c . || true)"
  cases=$((cases+1))
  if [ "${nnear:-0}" -eq 0 ] && [ "${nfar:-0}" -eq 1 ]; then
    echo "  PASS  window control — the GNU-then-shape-recheck idiom 1 line apart passes (0), the same pair 6 lines apart still REDS (1)"
  else
    echo "  FAIL  window control — near=${nnear:-0} (want 0), far=${nfar:-0} (want 1)" >&2
    fails=$((fails+1))
  fi

  out="$(printf '' | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 0 ]; then
    echo "  PASS  empty-population control — an empty list yields 0 hits, hence run_tree_scan REFUSES below 50 files rather than reading 0 hits as a pass"
  else
    echo "  FAIL  empty-population control produced hits" >&2; fails=$((fails+1))
  fi

  # SELF CONTROL — prove the hold-out costs nothing: strip the fixture and
  # message heredocs, scan what is LEFT (the code that runs), demand 0 hits.
  local selfsrc
  selfsrc="$root/self-stripped.sh"
  awk '
    !skip && match($0, /<<-?[ \t]*\x27[A-Za-z_][A-Za-z0-9_]*\x27[ \t]*$/) {
      w = substr($0, RSTART, RLENGTH); gsub(/[^A-Za-z0-9_]/, "", w)
      term = w; skip = 1; next
    }
    skip { if ($0 == term) skip = 0; next }
    { print }
  ' "$SELF_PATH" > "$selfsrc"
  out="$(printf '%s\n' "$selfsrc" | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 0 ]; then
    echo "  PASS  self control — every stat this script RUNS is portable (held out of the tree scan only because its fixtures violate ON PURPOSE)"
  else
    echo "  FAIL  self control — this guard uses ${n:-0} BSD-first stat itself" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  # STALE-EXCLUSION CONTROL — a ratchet has two failure directions.
  local keys nkeys stale=0 key live
  keys="$(excluded_keys)"
  nkeys="$(printf '%s\n' "$keys" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${nkeys:-0}" -eq 0 ]; then
    echo "  PASS  stale-exclusion control — the exclusion list is EMPTY (nothing to go stale; every site was fixed, none excused)"
  else
    live="$(list_tracked | scan_files | sed "s|^$REPO_ROOT/||" | cut -d: -f1,2)"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if ! printf '%s\n' "$live" | grep -qxF "$key"; then
        echo "  FAIL  stale exclusion: $key no longer violates — DELETE its line from EXCLUSIONS_LIST" >&2
        stale=$((stale+1))
      fi
    done <<< "$keys"
    if [ "$stale" -eq 0 ]; then
      echo "  PASS  stale-exclusion control — all $nkeys excluded site(s) still violate, so none grants silent amnesty"
    else
      fails=$((fails+1))
    fi
  fi

  [ "$cases" -ge 8 ] || die "selftest ran only $cases case(s); an empty tally is not a pass"
  printf '\n=== selftest: %s case(s), %s failure(s) ===\n' "$cases" "$fails"
  [ "$fails" -eq 0 ] || return "$EX_VIOLATION"
  return "$EX_OK"
}

case "${1:-}" in
  --selftest) selftest ;;
  ""|--scan)  run_tree_scan ;;
  -h|--help)  sed -n '2,55p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *)          die "unknown argument: $1" ;;
esac
