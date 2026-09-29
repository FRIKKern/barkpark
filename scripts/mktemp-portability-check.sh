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
# THE POPULATION, AND WHY IT IS DERIVED AND NOT LISTED
#   The property that matters is SHELL THAT EXECUTES ON THE CI RUNNER. That is
#   not the same set as "files named *.sh", and the first version of this guard
#   used the filename set — an ENUMERATION standing in for a PREDICATE. It
#   therefore could not see the one surface where the original defect was
#   actually wired. `derive_population` (and the EXTRACTOR it drives) states the
#   predicate in four clauses, each derived from the tree, none hand-listed:
#
#     sh-ext        tracked files named *.sh / *.bash                     (~482)
#     sh-shebang    tracked files with NO such extension whose FIRST LINE
#                   is a `#!… sh` shebang — bin/barkpark, .githooks/*,
#                   api/rel/overlays/bin/migrate, …                          (8)
#     legs-arm      every `arms[].run` body in .github/shell-harness-legs.json
#                   — inline shell the harness feeds to `bash` on the runner
#                                                                          (241)
#     workflow-run  every `run:` body in .github/workflows/*.yml           (681)
#
#   The last two are not files, so they are MATERIALISED into a scratch dir,
#   padded so that the scanner's line number IS the line number in the source
#   file, and then scanned by exactly the same scanner as the real files. Hits
#   are rendered back through a display map, so a violation inside a harness arm
#   prints as `.github/shell-harness-legs.json[<slug> / <arm>]:<line>`.
#
#   Each clause carries its own FLOOR (see POP_FLOOR_*). A clause that returns
#   fewer than its floor is a broken derivation, not a clean tree, and the guard
#   REFUSES — the same refusal the whole-population floor has always made.
#
# ARMS
#   (default)    scan the tracked tree; nonzero on any violation
#   --selftest   POSITIVE CONTROL: plant violating lines in a throwaway fixture
#                and assert the scanner SEES each one, plus negative controls it
#                must NOT flag, plus prose controls it must not mistake for code.
#                A guard that cannot demonstrate a red is theatre.
# Both arms REFUSE on an empty population: a scan that reached fewer than 50
# sources IN TOTAL or fewer than its floor in ANY clause, or a selftest that ran
# zero cases, is a FAILURE, not a pass — that vacuity is the exact bug this file
# exists to catch.
set -uo pipefail

EX_OK=0; EX_VIOLATION=1; EX_REFUSED=2

die() { echo "mktemp-portability-check: REFUSING — $*" >&2; exit "$EX_REFUSED"; }

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" || die "cannot resolve repo root"
command -v python3 >/dev/null 2>&1 || die "python3 not found; the scanner cannot run"

SCANNER="$(mktemp "${TMPDIR:-/tmp}/mktemp-portability-scanner.XXXXXX")" || die "mktemp failed"
[ -n "$SCANNER" ] || die "mktemp returned an EMPTY path"
EXTRACTOR="$(mktemp "${TMPDIR:-/tmp}/mktemp-portability-extractor.XXXXXX")" || die "mktemp failed"
[ -n "$EXTRACTOR" ] || die "mktemp returned an EMPTY path"
POP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mktemp-portability-pop.XXXXXX")" || die "mktemp -d failed"
[ -n "$POP_DIR" ] || die "mktemp -d returned an EMPTY path"
trap 'rm -f "$SCANNER" "$EXTRACTOR"; rm -rf "$POP_DIR"' EXIT

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

# ------------------------------------------------------------- the EXTRACTOR
# Derives the population from the PROPERTY ("shell that executes on the CI
# runner"), never from a hand-kept list. Prints one TAB-separated record per
# source:  <kind>\t<path-to-scan>\t<display-label>
# For the two embedded kinds the path is a MATERIALISED scratch file, padded
# with leading newlines so that the scanner's line number is the line number in
# the SOURCE file — a hit cites `.github/workflows/x.yml:412`, not a temp path.
cat > "$EXTRACTOR" <<'PYEOF2'
import json, os, re, subprocess, sys

root, dest = sys.argv[1], sys.argv[2]
SHEBANG = re.compile(r"^#!.*\b(ba|da|k|z|a)?sh\b")
RUNKEY  = re.compile(r"^(\s*)(?:-\s+)?run:\s*(.*)$")
BLOCK   = ("|", "|-", "|+", ">", ">-", ">+", "")
NL = chr(10)
TAB = chr(9)

def rec(kind, path, display):
    print(kind + TAB + path + TAB + display.replace(TAB, " "))

def emit(kind, name, display, pad, body):
    """Write body into dest/name preceded by pad blank lines, so that the
    scanner's line number equals the line number in the SOURCE file."""
    p = os.path.join(dest, name)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(NL * pad)
        fh.write(NL.join(body))
        fh.write(NL)
    rec(kind, p, display)

# --- clauses 1+2: tracked files that ARE shell -----------------------------
try:
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                         capture_output=True, check=True).stdout.decode("utf-8", "replace")
except Exception as exc:
    sys.stderr.write("EXTRACTOR: git ls-files failed: %s%s" % (exc, NL))
    sys.exit(3)

for rel in (x for x in out.split(chr(0)) if x):
    ap = os.path.join(root, rel)
    if rel.endswith((".sh", ".bash")):
        rec("sh-ext", ap, rel)
        continue
    # A file with no shell extension is still shell when its SHEBANG says so.
    # This is the clause that reaches bin/barkpark and .githooks/* -- and it is
    # a RULE, so it also reaches the next such file nobody remembers to list.
    if os.path.islink(ap) or not os.path.isfile(ap):
        continue
    try:
        with open(ap, "rb") as fh:
            first = fh.readline(400).decode("utf-8", "replace").rstrip(chr(13) + NL)
    except OSError:
        continue
    if SHEBANG.match(first):
        rec("sh-shebang", ap, rel)

# --- clause 3: inline arms[].run bodies in the shell-harness legs -----------
legs_rel = ".github/shell-harness-legs.json"
legs = os.path.join(root, legs_rel)
if os.path.isfile(legs):
    raw = open(legs, encoding="utf-8", errors="replace").read()
    doc = json.loads(raw)
    # Physical line of each run KEY, in document order. A run key that appears
    # inside an arm BODY is escaped in JSON and is excluded by the negative
    # lookbehind, so the Nth key here is the Nth arm-with-run below.
    keylines = [raw.count(NL, 0, m.start()) + 1
                for m in re.finditer(r'(?<!\\)"run"\s*:', raw)]
    arms = [(leg, arm) for leg in doc
            for arm in (leg.get("arms") or []) if "run" in arm]
    # ASSERT the alignment rather than trusting it: drift here would mis-cite
    # every hit, and a guard that points at the wrong line gets ignored.
    if len(keylines) != len(arms):
        sys.stderr.write("EXTRACTOR: legs.json run-key/arm mismatch (%d keys, %d arms)%s"
                         % (len(keylines), len(arms), NL))
        sys.exit(3)
    for k, (leg, arm) in enumerate(arms):
        disp = "%s[%s / %s]" % (legs_rel, leg.get("slug", "?"), arm.get("name", "?"))
        emit("legs-arm", "leg-%04d.sh" % k, disp.replace(":", "-"),
             keylines[k] - 1, str(arm["run"]).split(NL))

# --- clause 4: run: bodies in .github/workflows/*.yml ----------------------
# NO YAML LIBRARY, DELIBERATELY. The harness leg that runs this guard does not
# pip-install PyYAML, so a parser dependency would make the guard REFUSE in the
# exact place it is wired. Instead: an indentation reader that is OVER-inclusive
# by construction (a defaults-run mapping is captured too; captured shell is
# never missed), which is the safe direction for a population. The selftest
# CROSS-CHECKS it against PyYAML whenever PyYAML happens to be importable.
wf = os.path.join(root, ".github", "workflows")
if os.path.isdir(wf):
    for fn in sorted(os.listdir(wf)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        rel = ".github/workflows/" + fn
        lines = open(os.path.join(wf, fn), encoding="utf-8", errors="replace").read().split(NL)
        i, w = 0, 0
        while i < len(lines):
            m = RUNKEY.match(lines[i])
            if not m:
                i += 1
                continue
            indent = len(lines[i]) - len(lines[i].lstrip())
            rest = m.group(2).strip()
            w += 1
            stem = "wf-%s-%04d.sh" % (fn.replace(".", "_"), w)
            if rest in BLOCK:
                j, body = i + 1, []
                while j < len(lines):
                    l = lines[j]
                    if l.strip() == "" or (len(l) - len(l.lstrip())) > indent:
                        body.append(l)
                        j += 1
                        continue
                    break
                emit("workflow-run", stem, rel, i + 1, body)
                i = j
            else:
                emit("workflow-run", stem, rel, i, [rest])
                i += 1
PYEOF2

# Clause floors. A clause below its floor is a BROKEN DERIVATION reported as a
# clean tree — the precise failure this guard exists to refuse. Set well under
# today's counts so ordinary churn does not red them, and far above zero so a
# clause that silently stops matching cannot pass.
POP_FLOOR_sh_ext=400          # 482 today
POP_FLOOR_sh_shebang=5        # 8 today
POP_FLOOR_legs_arm=200        # 241 today
POP_FLOOR_workflow_run=300    # 681 today (662 by PyYAML; the reader is
                              # over-inclusive on purpose, see clause 4)
POP_FLOOR_TOTAL=50            # the original whole-population refusal

# Indirection through a `case` and not through `eval`, so that every floor is a
# LITERAL use shellcheck can see: an unreferenced-looking constant is the shape
# a dead floor takes, and a dead floor is a refusal that never fires.
pop_floor() {
  case "$1" in
    sh-ext)       printf '%s\n' "$POP_FLOOR_sh_ext" ;;
    sh-shebang)   printf '%s\n' "$POP_FLOOR_sh_shebang" ;;
    legs-arm)     printf '%s\n' "$POP_FLOOR_legs_arm" ;;
    workflow-run) printf '%s\n' "$POP_FLOOR_workflow_run" ;;
    *)            die "no floor declared for population clause '$1'" ;;
  esac
}

# THIS FILE IS HELD OUT OF THE TREE SCAN, and for a reason worth stating: its
# selftest fixtures and its own refusal message are FULL of deliberately
# violating lines, so scanning itself it would red permanently — and a guard
# that reds on its own fixtures gets switched off, which is worse than no guard.
# The hold-out is NOT amnesty: SELF CONTROL below scans this file with its
# fixture/message heredocs stripped, so every mktemp this script actually RUNS
# is still checked by the very scanner it ships.
SELF_PATH="$REPO_ROOT/scripts/mktemp-portability-check.sh"

# derive_population <repo-root> <materialise-dir>
# Prints the raw records. Callers cache them; nothing here is hand-listed.
derive_population() {
  python3 "$EXTRACTOR" "$1" "$2" || die "population derivation failed for $1"
}

# From a record stream on stdin: the paths to scan, minus this file.
population_paths() { cut -f2 | grep -vxF "$SELF_PATH"; }

# From a record stream on stdin: "<scan path>\t<display label>", the map that
# turns a scratch path back into a citable source location.
population_display_map() { cut -f2,3; }

# Rewrites "path:line:text" into "display:line:text" using a map file ($1).
render_hits() {
  awk -F'\t' 'NR==FNR { m[$1] = $2; next }
              { i = index($0, ":"); if (i == 0) { print; next }
                p = substr($0, 1, i - 1); r = substr($0, i)
                print ((p in m) ? m[p] : p) r }' "$1" -
}

run_tree_scan() {
  local records total hits nhits map raw
  records="$(derive_population "$REPO_ROOT" "$POP_DIR")"
  [ -n "$records" ] || die "population derivation produced no records"

  # Per-clause floors FIRST: a near-empty clause certifies nothing.
  local kind floor n
  for kind in sh-ext sh-shebang legs-arm workflow-run; do
    n="$(printf '%s\n' "$records" | cut -f1 | grep -cxF "$kind" || true)"
    floor="$(pop_floor "$kind")"
    [ "${n:-0}" -ge "${floor:-1}" ] || die "population clause '$kind' yielded ${n:-0} source(s); expected >= ${floor}. A near-empty clause certifies nothing."
    printf 'mktemp-portability-check: %-13s %5d source(s)  (floor %d)\n' "$kind" "${n:-0}" "$floor"
  done

  total="$(printf '%s\n' "$records" | grep -c . || true)"
  [ "${total:-0}" -ge "$POP_FLOOR_TOTAL" ] || die "scanned only ${total:-0} source(s); expected >= $POP_FLOOR_TOTAL. A near-empty population certifies nothing."

  map="$POP_DIR/.display-map"
  printf '%s\n' "$records" | population_display_map > "$map"

  raw="$(printf '%s\n' "$records" | population_paths | scan_files | render_hits "$map")"
  hits="$(printf '%s\n' "$raw" | filter_exclusions)"
  nhits="$(printf '%s' "$hits" | grep -c . || true)"

  echo "mktemp-portability-check: scanned $total source(s) of runner shell (files + embedded run bodies)"
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
  trap "rm -rf '$root' '$POP_DIR'; rm -f '$SCANNER' '$EXTRACTOR'" EXIT

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
    # Measured over the FULL derived population, not the old filename set —
    # a widening must not quietly move an excluded site out of view, which
    # would turn the ratchet into permanent amnesty by omission.
    local exrecs exmap
    mkdir -p "$root/pop-excl"
    exrecs="$(derive_population "$REPO_ROOT" "$root/pop-excl")" || die "stale-exclusion control could not derive the population"
    exmap="$root/pop-excl/.map"
    printf '%s\n' "$exrecs" | population_display_map > "$exmap"
    live="$(printf '%s\n' "$exrecs" | population_paths | scan_files | render_hits "$exmap" | sed "s|^$REPO_ROOT/||" | cut -d: -f1,2)"
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

  # ── WIDENED-POPULATION POSITIVE CONTROL ────────────────────────────────────
  # The three clauses this guard could NOT see before are the three planted
  # below, each in its own surface, inside ONE throwaway repo. The population is
  # then DERIVED from that repo by the very function the tree scan uses, so this
  # proves the derivation reaches them — not that a bespoke test path does.
  local fix pop recs popmap
  fix="$root/fixture"
  mkdir -p "$fix/.github/workflows" "$fix/bin" "$root/pop"
  pop="$root/pop"
  cat > "$fix/.github/shell-harness-legs.json" <<'FIX'
[{"slug":"planted","name":"planted leg","arms":[
  {"name":"clean arm","run":"a=\"$(mktemp \"${TMPDIR:-/tmp}/ok.XXXXXX\")\""},
  {"name":"violating arm","run":"b=\"$(mktemp -t planted-arm-body)\""}
]}]
FIX
  cat > "$fix/.github/workflows/w.yml" <<'FIX'
name: t
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: |
          c="$(mktemp -t planted-workflow-body)"
FIX
  cat > "$fix/bin/planted-tool" <<'FIX'
#!/usr/bin/env bash
d="$(mktemp -t planted-extensionless)"
FIX
  git -C "$fix" init -q >/dev/null 2>&1 && git -C "$fix" add -A >/dev/null 2>&1 \
    || die "selftest could not build its fixture repo (git init/add failed)"

  recs="$(derive_population "$fix" "$pop")" || die "selftest population derivation failed"
  popmap="$root/popmap"
  printf '%s\n' "$recs" | population_display_map > "$popmap"
  out="$(printf '%s\n' "$recs" | cut -f2 | scan_files | render_hits "$popmap")"
  n="$(printf '%s' "$out" | grep -c . || true)"
  # `grep -c`, never `grep -q`: -q exits on the first match, and under
  # `set -o pipefail` that SIGPIPEs the producer into rc 141 — the repo's
  # recurring way to make a control lie under load. -c drains its input.
  local missed="" seen
  seen="$(printf '%s\n' "$out" | grep -cF 'shell-harness-legs.json[planted / violating arm]' || true)"
  [ "${seen:-0}" -ge 1 ] || missed="$missed legs-arm"
  seen="$(printf '%s\n' "$out" | grep -cxF '.github/workflows/w.yml:8:c="$(mktemp -t planted-workflow-body)"' || true)"
  [ "${seen:-0}" -ge 1 ] || missed="$missed workflow-run(line-8)"
  seen="$(printf '%s\n' "$out" | grep -cxF 'bin/planted-tool:2:d="$(mktemp -t planted-extensionless)"' || true)"
  [ "${seen:-0}" -ge 1 ] || missed="$missed sh-shebang(line-2)"
  cases=$((cases+1))
  if [ "${n:-0}" -eq 3 ] && [ -z "$missed" ]; then
    echo "  PASS  widened-population control — a planted mktemp REDS in all 3 previously-invisible surfaces (harness arm body, workflow run: block, extensionless shebang file), each cited at its REAL source line, and the clean arm beside it does not"
  else
    echo "  FAIL  widened-population control — saw ${n:-0} of 3 planted violations; missing:${missed:- (none named, count wrong)}" >&2
    printf '%s\n' "$out" >&2; fails=$((fails+1))
  fi

  # ── WIDENED-POPULATION FLOOR CONTROL ───────────────────────────────────────
  # A clause that silently stops matching returns ZERO and reads as a clean
  # tree. Assert BOTH directions: the real repo is above every floor, and the
  # 4-source fixture above is below every floor — so the floors would actually
  # catch a collapsed clause instead of decorating the output.
  local realrecs kind floor rn fn floorbad=""
  mkdir -p "$root/pop-real"
  realrecs="$(derive_population "$REPO_ROOT" "$root/pop-real")" || die "selftest could not derive the real population"
  for kind in sh-ext sh-shebang legs-arm workflow-run; do
    floor="$(pop_floor "$kind")"
    rn="$(printf '%s\n' "$realrecs" | cut -f1 | grep -cxF "$kind" || true)"
    fn="$(printf '%s\n' "$recs"     | cut -f1 | grep -cxF "$kind" || true)"
    [ "${rn:-0}" -ge "${floor:-1}" ] || floorbad="$floorbad ${kind}:real=${rn}<${floor}"
    [ "${fn:-0}" -lt "${floor:-1}" ] || floorbad="$floorbad ${kind}:fixture=${fn}>=${floor}"
  done
  cases=$((cases+1))
  if [ -z "$floorbad" ]; then
    echo "  PASS  population-floor control — all 4 clauses clear their floor on the real tree AND fall under it on a 4-source fixture, so a collapsed clause REFUSES instead of reporting a clean tree"
  else
    echo "  FAIL  population-floor control —$floorbad" >&2; fails=$((fails+1))
  fi

  # ── WORKFLOW-EXTRACTOR CROSS-CHECK (runs only where PyYAML is importable) ──
  # The workflow clause reads indentation, not YAML, because the harness leg
  # that runs this guard installs no PyYAML. Where PyYAML IS present, prove the
  # cheap reader loses nothing: every line of every YAML-parsed `run:` body that
  # exists VERBATIM in the workflow file must also be inside the extracted
  # bodies. (A folded `>` scalar joins lines into text that appears nowhere in
  # the file; those are excluded by that same verbatim test, not waved through.)
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    local xcheck
    xcheck="$root/yaml-crosscheck.py"
    cat > "$xcheck" <<'PYX'
import glob, os, sys
import yaml
root, popdir = sys.argv[1], sys.argv[2]
NL = chr(10)
captured = {}
for rel_map in open(os.path.join(popdir, ".xmap"), encoding="utf-8"):
    tmp, rel = rel_map.rstrip(NL).split(chr(9), 1)
    if not rel.startswith(".github/workflows/"):
        continue
    for line in open(tmp, encoding="utf-8", errors="replace"):
        s = line.strip()
        if s:
            captured.setdefault(rel, set()).add(s)
missing = 0
checked = 0
for path in sorted(glob.glob(os.path.join(root, ".github/workflows/*.yml")) +
                   glob.glob(os.path.join(root, ".github/workflows/*.yaml"))):
    rel = ".github/workflows/" + os.path.basename(path)
    text = open(path, encoding="utf-8", errors="replace").read()
    verbatim = set(l.strip() for l in text.split(NL) if l.strip())
    try:
        doc = yaml.safe_load(text)
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    for job in (doc.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        for step in (job.get("steps") or []):
            if not (isinstance(step, dict) and "run" in step):
                continue
            for line in str(step["run"]).split(NL):
                s = line.strip()
                if not s or s not in verbatim:
                    continue          # folded-scalar join: in no file line
                checked += 1
                if s not in captured.get(rel, ()):
                    missing += 1
                    if missing <= 5:
                        sys.stderr.write("    UNCAPTURED %s: %s%s" % (rel, s[:90], NL))
print("%d %d" % (checked, missing))
PYX
    printf '%s\n' "$realrecs" | population_display_map > "$root/pop-real/.xmap"
    local xout xchecked xmissing
    xout="$(python3 "$xcheck" "$REPO_ROOT" "$root/pop-real")" || xout=""
    xchecked="${xout%% *}"; xmissing="${xout##* }"
    cases=$((cases+1))
    if [ -n "$xout" ] && [ "${xmissing:-1}" -eq 0 ] && [ "${xchecked:-0}" -ge 1000 ]; then
      echo "  PASS  workflow-extractor cross-check — the indentation reader captured all $xchecked verbatim line(s) of every PyYAML-parsed run: body; the library-free reader loses nothing"
    else
      echo "  FAIL  workflow-extractor cross-check — ${xmissing:-?} of ${xchecked:-?} PyYAML run: body line(s) were NOT captured (a floor of 1000 checked lines guards against a vacuous compare)" >&2
      fails=$((fails+1))
    fi
  else
    echo "  SKIP  workflow-extractor cross-check — PyYAML not importable here (it is not a dependency of this guard; the check runs where it is present)"
  fi

  # ── THE VERDICT WIRING, graded on the whole program (task-92a213f01ca30817) ─
  # Every case above grades scan_files / derive_population IN PROCESS; none
  # executes run_tree_scan's `return "$EX_VIOLATION"`, which IS the process
  # exit code, so flipping it to `return "$EX_OK"` kept this selftest green
  # while the tree scan certified a planted template. Same idiom as PR #13405 /
  # #20180: RE-EXEC THE WHOLE PROGRAM on a fixture repo and assert the PROCESS
  # exit. REPO_ROOT derives from the script's own location, so a copy at
  # <fixture>/scripts/ scans only the fixture — no override is added — and the
  # fixture is generated just above every clause floor, so the plant is the
  # only thing that can move the verdict.
  local e2e rc_planted rc_removed rc_empty i
  e2e="$root/e2e"
  mkdir -p "$e2e/scripts" "$e2e/bin" "$e2e/.github/workflows" "$root/e2e-empty/scripts"
  cp "$SELF_PATH" "$e2e/scripts/mktemp-portability-check.sh"
  cp "$SELF_PATH" "$root/e2e-empty/scripts/mktemp-portability-check.sh"
  i=0; while [ "$i" -lt "$POP_FLOOR_sh_ext" ]; do printf 'echo %s\n' "$i" > "$e2e/scripts/s$i.sh"; i=$((i+1)); done
  i=0; while [ "$i" -lt "$POP_FLOOR_sh_shebang" ]; do printf '#!/usr/bin/env bash\necho %s\n' "$i" > "$e2e/bin/t$i"; i=$((i+1)); done
  python3 - "$e2e" "$POP_FLOOR_legs_arm" "$POP_FLOOR_workflow_run" <<'PYE2E'
import json, os, sys
root, arms, runs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
legs = [{"slug": "e2e", "name": "e2e", "arms": [{"name": "a%d" % k, "run": "echo %d" % k} for k in range(arms)]}]
open(os.path.join(root, ".github/shell-harness-legs.json"), "w").write(json.dumps(legs, indent=1))
steps = "".join("      - run: echo %d\n" % k for k in range(runs))
open(os.path.join(root, ".github/workflows/w.yml"), "w").write(
    "name: t\non: [push]\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n" + steps)
PYE2E
  git -C "$e2e" init -q >/dev/null 2>&1 && git -C "$e2e" add -A >/dev/null 2>&1 \
    && git -C "$root/e2e-empty" init -q >/dev/null 2>&1 && git -C "$root/e2e-empty" add -A >/dev/null 2>&1 \
    || die "selftest could not build its E2E fixture repo (git init/add failed)"
  printf 'x="$(mktemp -t planted-e2e)"\n' > "$e2e/scripts/s0.sh"
  bash "$e2e/scripts/mktemp-portability-check.sh" >/dev/null 2>&1; rc_planted=$?
  printf 'x="$(mktemp "${TMPDIR:-/tmp}/planted-e2e.XXXXXX")"\n' > "$e2e/scripts/s0.sh"
  bash "$e2e/scripts/mktemp-portability-check.sh" >/dev/null 2>&1; rc_removed=$?
  bash "$root/e2e-empty/scripts/mktemp-portability-check.sh" >/dev/null 2>&1; rc_empty=$?
  cases=$((cases+1))
  if [ "$rc_planted" -eq "$EX_VIOLATION" ] && [ "$rc_removed" -eq "$EX_OK" ] && [ "$rc_empty" -ne "$EX_OK" ]; then
    echo "  PASS  verdict-wiring control — the WHOLE PROGRAM exits $rc_planted on a planted template, $rc_removed once it is removed, and $rc_empty (never 0) on an empty repo"
  else
    echo "  FAIL  verdict-wiring control — whole program exited planted=$rc_planted (want $EX_VIOLATION), removed=$rc_removed (want $EX_OK), empty=$rc_empty (want non-zero)" >&2
    fails=$((fails+1))
  fi

  # The selftest refuses its own vacuous run.
  [ "$cases" -ge 8 ] || die "selftest ran only $cases case(s); an empty tally is not a pass"
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
