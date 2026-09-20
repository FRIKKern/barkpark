#!/usr/bin/env bash
# mktemp-portability-check — REFUSE a `mktemp` template that GNU coreutils rejects.
#
# THE DEFECT THIS GUARDS
#   `mktemp -t NAME` with a template carrying no `XXXXXX` is a BSD/macOS-only
#   form. GNU coreutils mktemp — every GitHub Actions ubuntu runner — refuses it:
#       mktemp: too few X's in template 'NAME'
#   Two failure shapes follow, and the SECOND is the dangerous one:
#     1. LOUD   — `mktemp ... || die` exits, the arm reds, someone fixes it.
#     2. SILENT — `X="$(mktemp -t name)"` sets X to the EMPTY string and does NOT
#        trip `set -e` (a failing command substitution inside an assignment does
#        not). The script carries on, every `>"$X"` writes to "", every read
#        finds nothing, the measurement becomes vacuous — and the arm reports
#        SUCCESS.
#   Shape 2 was live on main: scripts/pds-personal-local-smoke_test.sh printed
#   "0 of  doc anchor(s) resolved" in CI while its leg stayed green.
#
# THE PORTABLE FORM
#   mktemp     "${TMPDIR:-/tmp}/name.XXXXXX"
#   mktemp -d  "${TMPDIR:-/tmp}/name.XXXXXX"
#   Identical on BSD and GNU, and no literal XXXXXX survives in the resulting
#   name — which `mktemp -t name.XXXXXX` DOES leave behind under BSD.
#
# WHAT IS FLAGGED
#   A `mktemp` invocation, IN COMMAND POSITION, whose template argument contains
#   no XXXXXX. Command position is decided by a quote-state walk of the line, so
#   `die "mktemp failed"` and `grep 'mktemp …'` are prose and are not flagged,
#   while `"$(mktemp …)"` is. A bare `mktemp` / `mktemp -d` with NO template is
#   portable and is NOT flagged.
#
# ARMS
#   (default)    scan the tracked tree; nonzero on any violation
#   --selftest   POSITIVE CONTROL: plant violating lines in a throwaway fixture
#                and assert the scanner SEES each one, plus negative controls it
#                must NOT flag, plus prose controls it must not mistake for code.
#                A guard that cannot demonstrate a red is theatre.
# Both arms REFUSE on an empty population: a tree scan that reached fewer than
# 50 files, or a selftest that ran zero cases, is a FAILURE, not a pass — that
# vacuity is the exact bug this file exists to catch.
set -uo pipefail

EX_OK=0; EX_VIOLATION=1; EX_REFUSED=2

die() { echo "mktemp-portability-check: REFUSING — $*" >&2; exit "$EX_REFUSED"; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || die "cannot resolve repo root"
command -v python3 >/dev/null 2>&1 || die "python3 not found; the scanner cannot run"

SCANNER="$(mktemp "${TMPDIR:-/tmp}/mktemp-portability-scanner.XXXXXX")" || die "mktemp failed"
[ -n "$SCANNER" ] || die "mktemp returned an EMPTY path"
trap 'rm -f "$SCANNER"' EXIT

cat > "$SCANNER" <<'PYEOF'
import sys

def walk(line):
    """Yield indices where a `mktemp` word starts in COMMAND context.

    A tiny shell-quoting state machine: single quotes are opaque, double quotes
    are opaque EXCEPT that `$(` and a backtick re-enter command context. A `#`
    in command context at line start or after whitespace begins a comment.
    """
    i, n = 0, len(line)
    stack = ["code"]          # top of stack is the current context
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
        # command context
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
            return                                  # rest of line is a comment
        if line.startswith("mktemp", i):
            after = line[i+6] if i + 6 < n else " "
            if not (after.isalnum() or after in "_-.") and in_command_position(line, i):
                yield i
        i += 1

# A `mktemp` WORD is only an invocation when it starts a command. Everything
# before it on the line must end in a shell operator (or nothing at all). This
# is what keeps `for t in mkdir mktemp mv; do` and a prose `... a mktemp -d it
# removes ...` out of the population — a scanner that reds on its own comments
# gets disabled, and a disabled guard guards nothing.
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
    """The argument text of the mktemp starting at `start`, to its separator."""
    i = start + 6
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
            j, depth = i + 2, 1                     # ${...} is ONE opaque unit:
            while j < n and depth:                  # its `}` is not a separator
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

def template_of(args):
    """The template argument, or None when the invocation names no template."""
    toks = [t for t in args.split() if t]
    # `mktemp -d 2>/dev/null` stops at the `>`, leaving a bare fd number that is
    # a REDIRECT, never a template. Drop it.
    if toks and toks[-1].isdigit(): toks.pop()
    k = 0
    while k < len(toks):
        t = toks[k]
        if t in ("-t", "--tmpdir", "-p", "--suffix"):
            if t == "--suffix": k += 2; continue
            return toks[k+1] if k + 1 < len(toks) else None
        if t.startswith("--tmpdir="): return t[len("--tmpdir="):]
        if t.startswith("--suffix="): k += 1; continue
        if t.startswith("-"): k += 1; continue
        return t
    return None

# GNU coreutils' ACTUAL rule, measured against coreutils mktemp and BSD mktemp
# on 2026-09-20 (both accept 3, both accept 4, GNU refuses 1 and 2):
#     a template needs at least THREE consecutive X. Fewer -> "too few X's".
# The repo house style is six, but three is the portability line and the guard
# must enforce the real rule, not the style — a guard stricter than the fault
# reds correct code (`/tmp/pds.XXXX` is portable) and gets switched off.
import re
MIN_X = re.compile("X{3,}")

def unquote(t):
    while len(t) >= 2 and t[0] == t[-1] and t[0] in "\"'":
        t = t[1:-1]
    return t.replace('"', "").replace("'", "")

hits = 0
for path in (l.rstrip("\n") for l in sys.stdin):
    if not path: continue
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        continue
    for lno, line in enumerate(lines, 1):
        line = line.rstrip("\n")
        for start in walk(line):
            tmpl = template_of(invocation(line, start))
            if tmpl is None:            # bare mktemp / mktemp -d: portable
                continue
            if not MIN_X.search(unquote(tmpl)):
                print("%s:%d:%s" % (path, lno, line.strip()))
                hits += 1
print("__HITS__%d" % hits, file=sys.stderr)
PYEOF

# Reads file paths on stdin, prints "path:line:text" per violation on stdout.
# Exposed as a function so the selftest drives the SAME code the tree scan does.
scan_files() { python3 "$SCANNER" 2>/dev/null; }

# ---------------------------------------------------------------- exclusions
# One "path:line|reason" per excluded site. An exclusion is a DEBT, so it is
# ratcheted in BOTH directions: the selftest asserts every excluded site STILL
# violates and reds if one has been fixed — which is the cue to delete its line,
# not to leave it rotting into permanent amnesty.
EXCLUSIONS_LIST=$(cat <<'EXC'
internal/apiclient/testdata/regen-capabilities.sh:52|OUTSIDE THIS LANE FENCE: everything under internal/ belongs to the CLI lane. The fix is to replace `mktemp -t bp-caps` with `mktemp "${TMPDIR:-/tmp}/bp-caps.XXXXXX"` plus a loud failure, and it has been REQUESTED of that lane. Delete this line when it lands.
EXC
)

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

# THIS FILE IS HELD OUT OF THE TREE SCAN, and for a reason worth stating: its
# selftest fixtures and its own refusal message are FULL of deliberately
# violating lines, so scanning itself it would red permanently — and a guard
# that reds on its own fixtures gets switched off, which is worse than no guard.
# The hold-out is NOT amnesty: SELF CONTROL below scans this file with its
# fixture/message heredocs stripped, so every mktemp this script actually RUNS
# is still checked by the very scanner it ships.
SELF_PATH="$REPO_ROOT/scripts/mktemp-portability-check.sh"

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
  # EMPTY-POPULATION REFUSAL: a near-empty scan is a broken scan, not a clean tree.
  [ "${count:-0}" -ge 50 ] || die "scanned only ${count:-0} shell file(s); expected >= 50. A near-empty population certifies nothing."

  local raw; raw="$(printf '%s\n' "$files" | scan_files)"
  hits="$(printf '%s\n' "$raw" | filter_exclusions)"
  nhits="$(printf '%s' "$hits" | grep -c . || true)"

  echo "mktemp-portability-check: scanned $count tracked shell file(s)"
  local nexc; nexc="$(excluded_keys | grep -c . || true)"
  [ "${nexc:-0}" -eq 0 ] || echo "mktemp-portability-check: $nexc site(s) EXCLUDED with a written reason (see EXCLUSIONS_LIST)"
  if [ "${nhits:-0}" -eq 0 ]; then
    echo "PASS — 0 non-portable mktemp template(s)"
    return "$EX_OK"
  fi
  echo "FAIL — $nhits non-portable mktemp template(s):" >&2
  printf '%s\n' "$hits" | sed "s|^$REPO_ROOT/||" | sed 's/^/  /' >&2
  cat >&2 <<'MSG'

  GNU coreutils mktemp refuses a template with fewer than THREE consecutive X:
      mktemp: too few X's in template 'NAME'
  Use the portable form instead:
      mktemp    "${TMPDIR:-/tmp}/name.XXXXXX"
      mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"
  and make the failure LOUD — never let an empty path flow onward.
MSG
  return "$EX_VIOLATION"
}

selftest() {
  local root fails=0 cases=0 out n
  root="$(mktemp -d "${TMPDIR:-/tmp}/mktemp-portability-selftest.XXXXXX")" || die "mktemp -d failed"
  [ -n "$root" ] || die "mktemp -d returned an EMPTY path"
  # shellcheck disable=SC2064
  trap "rm -rf '$root'; rm -f '$SCANNER'" EXIT

  # POSITIVE CONTROLS — 5 planted violations the guard MUST see.
  cat > "$root/violating.sh" <<'FIX'
#!/usr/bin/env bash
a="$(mktemp -t pds-art-before)"
b="$(mktemp -d -t some-dir-name)"
c="$(mktemp --tmpdir=prefix-no-x)"
d="$(mktemp /tmp/bare-positional)"
e="$(mktemp -t "pds-crown-c${idx}")"
FIX
  # NEGATIVE CONTROLS — 6 portable forms the guard must NOT flag.
  cat > "$root/clean.sh" <<'FIX'
#!/usr/bin/env bash
a="$(mktemp "${TMPDIR:-/tmp}/ok.XXXXXX")"
b="$(mktemp -d "${TMPDIR:-/tmp}/okdir.XXXXXX")"
c="$(mktemp)"
d="$(mktemp -d)" || die "mktemp failed"
e="$(mktemp -t still-ok.XXXXXX)"
f=$(mktemp -d) || { echo "mktemp -d failed" >&2; exit 2; }
g="$(mktemp -d 2>/dev/null || printf '')"
h="$(mktemp -d /tmp/pds.XXXX)"
FIX
  # PROSE CONTROLS — `mktemp` words that are NOT invocations. A scanner that
  # cannot tell code from prose reds the tree on its own comments.
  cat > "$root/prose.sh" <<'FIX'
#!/usr/bin/env bash
# the old script leaked one mktemp -d per run, so we reap it here
say "FATAL: mktemp broken-name failed"
echo "TEST HARNESS FAIL: mktemp" >&2
grep -q 'mktemp bp-caps' "$somefile"
z="$(mktemp "${TMPDIR:-/tmp}/z.XXXXXX")"   # mktemp lvd-cookies in a trailing comment
for t in awk basename mkdir mktemp mv printf rm; do command -v "$t" >/dev/null; done
FIX

  out="$(printf '%s\n' "$root/violating.sh" | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 5 ]; then
    echo "  PASS  positive control — guard SEES all 5 planted violations (it can demonstrate a RED)"
  else
    echo "  FAIL  positive control — guard saw ${n:-0} of 5 planted violations" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  out="$(printf '%s\n' "$root/clean.sh" | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 0 ]; then
    printf '  PASS  negative control — guard flags 0 of 8 portable forms (incl. the 3-X minimum and a 2>/dev/null redirect)\n'
  else
    echo "  FAIL  negative control — guard false-positived on ${n:-0} portable form(s)" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  out="$(printf '%s\n' "$root/prose.sh" | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 0 ]; then
    printf '  PASS  prose control — guard flags 0 of 6 mktemp WORDS that are comments, message strings or for-in list members\n'
  else
    printf '  FAIL  prose control — guard mistook %s prose mention(s) for an invocation\n' "${n:-0}" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  # EMPTY-POPULATION CONTROL. An empty file list yields zero hits, which is
  # exactly why "zero hits" can never be the pass predicate on its own: the tree
  # scan gates on the FILE COUNT first. Assert both halves.
  out="$(printf '' | scan_files)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 0 ]; then
    echo "  PASS  empty-population control — an empty list yields 0 hits, hence run_tree_scan REFUSES below 50 files rather than reading 0 hits as a pass"
  else
    echo "  FAIL  empty-population control produced hits" >&2; fails=$((fails+1))
  fi

  # SELF CONTROL — this script is held out of the tree scan (see SELF_PATH), so
  # prove the hold-out costs nothing: strip the fixture and message heredocs,
  # then scan what is LEFT — the code that actually runs — and demand 0 hits.
  local selfsrc
  selfsrc="$root/self-stripped.sh"
  awk '
    # Generic quoted-heredoc skipper: a line ending in <<\x27WORD\x27 opens a
    # block that ends at a line which is exactly WORD. Everything between is
    # fixture or message text, never code this script runs.
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
    echo "  PASS  self control — every mktemp this script RUNS is portable (held out of the tree scan only because its fixtures violate ON PURPOSE)"
  else
    echo "  FAIL  self control — this guard uses ${n:-0} non-portable mktemp itself" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  # STALE-EXCLUSION CONTROL — a ratchet has two failure directions. Every
  # excluded site must STILL violate; one fixed elsewhere must be deleted from
  # the list, or the list quietly grants permanent amnesty to a clean file.
  local keys nkeys stale=0 key live
  keys="$(excluded_keys)"
  nkeys="$(printf '%s\n' "$keys" | grep -c . || true)"
  cases=$((cases+1))
  if [ "${nkeys:-0}" -eq 0 ]; then
    echo "  PASS  stale-exclusion control — the exclusion list is EMPTY (nothing to go stale)"
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

  # The selftest refuses its own vacuous run.
  [ "$cases" -ge 6 ] || die "selftest ran only $cases case(s); an empty tally is not a pass"
  printf '\n=== selftest: %s case(s), %s failure(s) ===\n' "$cases" "$fails"
  [ "$fails" -eq 0 ] || return "$EX_VIOLATION"
  return "$EX_OK"
}

case "${1:-}" in
  --selftest) selftest ;;
  ""|--scan)  run_tree_scan ;;
  -h|--help)  sed -n '2,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *)          die "unknown argument: $1" ;;
esac
