#!/usr/bin/env bash
#
# workflow-portability-check.test.sh — the mutation harness for the workflow
# portability tripwire.
#
# HOUSE LAW: a harness with only green cases is the defect, not the proof. A
# check is worth its runner minutes only once it has been shown to LOSE on the
# exact input it claims to catch, so every clause below gets a fixture that
# breaks it, and the control cases exist to prove the reds are not just a
# permanently-angry script.
#
# Every case is hermetic: a mktemp git repo with its own HEAD, its own corpus,
# and no reach into this checkout — except case 17, which deliberately runs the
# tripwire against the REAL corpus, because an instrument that has never met real
# input is not yet an instrument.
#
# The cases that matter most:
#   case 2   the syntax mutant a `node --check` clause reports GREEN
#   case 6   a reference that EXISTS on this disk but is untracked — the
#            working-tree oracle's false pass, and the whole reason clause G is
#            the deliberate inverse of cloud-path-escape-check.sh's D31 rule
#   case 7   an empty corpus is RED, not "all 0 engines pass"
#   case 12  node --check's vacuity, re-derived from scratch rather than quoted
#   case 18  a runner with no node REDS instead of skipping

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/workflow-portability-check.sh"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "  ok   — $1"
}
no() {
  fail=$((fail + 1))
  echo "  FAIL — $1" >&2
}

# ── honest-gates D37: never `printf … | grep -q` ───────────────────────────
# Under `set -o pipefail`, BSD grep (macOS) exits 0 the instant it matches, the
# writer dies of SIGPIPE, pipefail promotes 141 over grep's success, and the `if`
# takes the ELSE branch — a FALSE failure for a match that did occur. Here-strings
# have no writer to kill.
has() { grep -q -- "$2" <<<"$1"; }
count() { grep -c -- "$2" <<<"$1" || true; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/workflow-portability-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# A fresh hermetic fixture repo, printed on stdout. `mktemp -d`, never a counter:
# every caller is a command substitution, which runs in a SUBSHELL, so a counter
# incremented here never survives — every fixture would silently reuse ONE
# directory and the second `git commit` would fail INTO the captured path.
newrepo() {
  local root
  root="$(mktemp -d "$TMPROOT/case.XXXXXX")"
  mkdir -p "$root/.claude/workflows"
  git -C "$root" init -q >/dev/null
  git -C "$root" config user.email harness@example.invalid
  git -C "$root" config user.name "portability harness"
  printf 'fixture\n' >"$root/README.md"
  git -C "$root" add README.md
  git -C "$root" commit -qm 'fixture seed' >/dev/null
  printf '%s' "$root"
}

# A VALID engine in the real dialect: `export const meta` first, a pure meta
# literal, top-level await AND top-level return. That combination is the point —
# it parses under no stock node mode, only under the harness's acorn options and
# this script's async-body mirror.
write_engine() {
  cat >"$1" <<'ENGINE'
export const meta = {
  name: 'fixture-engine',
  description: 'A fixture engine used only by the portability harness.',
  whenToUse: 'Never in anger — the harness builds and discards it.',
  phases: [
    { title: 'One', detail: 'the first announced phase' },
    { title: 'Two', detail: 'the second announced phase' },
  ],
};

phase('One');
const seeded = await Promise.resolve(1);
if (!seeded) { return { ok: false }; }
phase('Two');
return { ok: true };
ENGINE
}

# Run the tripwire over a fixture corpus; sets $out and $rc.
run_on() {
  out="$("$SCRIPT" "$1/.claude/workflows" 2>&1)" && rc=0 || rc=$?
}

echo "workflow-portability-check.test.sh"
echo

# ── case 1: the clean control is GREEN ─────────────────────────────────────
echo "case 1: a clean engine in a clean fixture repo passes"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 0 ]; then ok "exit 0 on a clean corpus"; else no "expected 0, got $rc: $out"; fi
if has "$out" "OK: every engine parses"; then ok "prints the OK verdict"; else no "no OK verdict: $out"; fi
if has "$out" "1 engine(s) checked, 0 failure(s)"; then
  ok "reports the corpus size it actually walked"
else
  no "no corpus-size line: $out"
fi
echo

# ── case 2: a syntax error AFTER meta — the mutant node --check calls green ─
echo "case 2 [P]: a syntax error after meta is RED (node --check reports it green)"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
printf 'const broken = ;\n' >>"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1 on a file that does not compile"; else no "expected 1, got $rc: $out"; fi
if has "$out" "workflow-portability-check\[P\]"; then ok "names clause P"; else no "clause P not named: $out"; fi
# The same bytes, through the clause this one replaces:
if node --check "$root/.claude/workflows/fixture.workflow.js" >/dev/null 2>&1; then
  ok "and \`node --check\` calls those same bytes GREEN — which is why clause P is an async-body compile"
else
  no "node --check REJECTED the mutant: the header's vacuity rationale needs re-deriving on this node"
fi
echo

# ── case 3: a /Users literal is RED ────────────────────────────────────────
echo "case 3 [A]: a /Users path is RED"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
printf "const home = '/Users/someone/notes.md';\n" >>"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
if has "$out" "machine-local absolute path"; then ok "names the failure in the reader's terms"; else no "no [A] message: $out"; fi
echo

# ── case 4: TWO /Volumes literals — BOTH reported ──────────────────────────
# First-match-only reporting turns one red into N rounds of whack-a-mole, and the
# second hit is usually in a different function than the first.
echo "case 4 [A]: two /Volumes literals are BOTH reported, not just the first"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
{
  printf "const a = '/Volumes/SATECHI/github/barkpark';\n"
  printf "const b = '/Volumes/SATECHI/dev-caches/tmp';\n"
} >>"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
n="$(count "$out" "machine-local absolute path")"
if [ "$n" -eq 2 ]; then ok "both offending lines reported (n=$n)"; else no "expected 2 [A] lines, got $n: $out"; fi
if has "$out" "SATECHI/dev-caches" && has "$out" "SATECHI/github"; then
  ok "each report carries its own line's text"
else
  no "the two reports are not distinguishable: $out"
fi
echo

# ── case 5: a dangling reference is RED ────────────────────────────────────
echo "case 5 [G]: a reference to a file that is nowhere is RED"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
printf "// see .claude/workflows/absent-charter.md\n" >>"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
if has "$out" "a dangling reference"; then ok "reported as dangling"; else no "no dangling message: $out"; fi
echo

# ── case 6: on disk, UNTRACKED — the working-tree oracle's false pass ──────
# THE CASE THIS CLAUSE EXISTS FOR. The file passes every `test -e` on the
# author's machine and is absent from every clone. A working-tree oracle (the
# D31 rule the cloud ratchet correctly uses for its own, different venue) reports
# this green.
echo "case 6 [G]: a reference present ON DISK but UNTRACKED is RED, with its own message"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
printf "// see .claude/workflows/local-only-charter.md\n" >>"$root/.claude/workflows/fixture.workflow.js"
printf 'never committed\n' >"$root/.claude/workflows/local-only-charter.md"
if [ ! -e "$root/.claude/workflows/local-only-charter.md" ]; then
  no "fixture broken: the untracked file was not created"
fi
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1 even though the file EXISTS on disk"; else no "expected 1, got $rc: $out"; fi
if has "$out" "UNTRACKED in HEAD"; then
  ok "distinct message: the fix is \`git add\`, not \"create the file\""
else
  no "untracked case not distinguished from dangling: $out"
fi
if has "$out" "a dangling reference"; then
  no "the untracked case was misreported as dangling"
else
  ok "not conflated with the dangling case"
fi
# The polarity that makes the clause meaningful: commit it, and the same corpus
# goes green. Without this the red above could be a script that hates all refs.
git -C "$root" add .claude/workflows/local-only-charter.md
git -C "$root" commit -qm 'track the charter'
run_on "$root"
if [ "$rc" -eq 0 ]; then ok "and GREEN once the same file is tracked in HEAD"; else no "still red after git add: $out"; fi
echo

# ── case 7: an empty corpus is RED, never "all 0 engines pass" ─────────────
echo "case 7 [N]: an empty corpus is RED"
root="$(newrepo)"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1 on 0 engines"; else no "expected 1, got $rc: $out"; fi
if has "$out" "corpus is EMPTY"; then ok "says so out loud"; else no "no empty-corpus message: $out"; fi
echo

# ── case 8: meta must be the FIRST STATEMENT ───────────────────────────────
echo "case 8 [M1]: a statement before meta is RED"
write_engine "$TMPROOT/engine-body.js"
root="$(newrepo)"
{
  printf "const setupFirst = 1;\n"
  cat "$TMPROOT/engine-body.js"
} >"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
if has "$out" "first statement is not"; then ok "names the body[0] rule"; else no "no [M1] message: $out"; fi
echo

# ── case 9: leading COMMENTS are allowed (the M1 control) ──────────────────
# The harness checks body[0] of the parsed program, not byte 0. Without this
# control, clause M1 could be a byte-0 string match and nobody would notice until
# the first engine that opens with a licence header went red for nothing.
echo "case 9 [M1 control]: leading comments and blank lines before meta are ALLOWED"
root="$(newrepo)"
{
  printf '// A leading comment.\n'
  printf '/* and a block one\n   over two lines */\n\n'
  cat "$TMPROOT/engine-body.js"
} >"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 0 ]; then ok "exit 0 — comments are not statements"; else no "expected 0, got $rc: $out"; fi
echo

# ── case 10: an impure meta is RED ─────────────────────────────────────────
echo "case 10 [M2]: a meta that calls out to code is RED"
root="$(newrepo)"
{
  printf 'export const meta = {\n'
  printf "  name: 'fixture-engine',\n"
  printf "  description: 'Built at load time.'.toUpperCase(),\n"
  printf "  whenToUse: 'never',\n"
  printf '  phases: [],\n'
  printf '};\n'
} >"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
if has "$out" "not a pure literal"; then ok "names the purity rule"; else no "no [M2] purity message: $out"; fi
echo

# ── case 11: an oversize engine is RED ─────────────────────────────────────
echo "case 11 [S]: a file over the 524288-byte harness cap is RED"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
# One long comment line — bytes only, no change to any other clause's verdict.
{
  printf '// '
  head -c 530000 /dev/zero | tr '\0' 'x'
  printf '\n'
} >>"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
if has "$out" "over the harness cap of 524288"; then ok "names the cap"; else no "no [S] message: $out"; fi
echo

# ── case 12: node --check's vacuity, RE-DERIVED (never quoted) ─────────────
# If a future node ever fixes this, THIS case fails and the header's rationale
# gets re-derived — rather than the comment quietly becoming a lie.
echo "case 12 [P rationale]: \`node --check\` is vacuous on any export-bearing file"
probe="$TMPROOT/probe"
mkdir -p "$probe"
printf 'const broken = ;\n' >"$probe/plain.js"
printf 'export const x = 1;\nconst broken = ;\n' >"$probe/exported.js"
if node --check "$probe/plain.js" >/dev/null 2>&1; then rc_plain=0; else rc_plain=1; fi
if node --check "$probe/exported.js" >/dev/null 2>&1; then rc_export=0; else rc_export=1; fi
if [ "$rc_plain" -eq 1 ]; then ok "node --check REJECTS the plain CJS syntax error"; else no "node --check accepted a real syntax error"; fi
if [ "$rc_export" -eq 0 ]; then
  ok "node --check ACCEPTS the identical error once an \`export\` precedes it — vacuous, exactly as the header states"
else
  no "node --check now rejects the export-bearing mutant: re-derive the header's clause-P rationale"
fi
# And the mirror this script actually uses tells the two apart:
if node -e 'const fs=require("fs");new (Object.getPrototypeOf(async function(){}).constructor)(fs.readFileSync(process.argv[1],"utf8").replace(/^export\s+/m,""))' "$probe/exported.js" >/dev/null 2>&1; then
  no "the async-body mirror ALSO passed the mutant — clause P would be vacuous too"
else
  ok "the async-body mirror rejects it — the clause can lose"
fi
echo

# ── case 13: declared vs announced phases must agree, both directions ──────
echo "case 13 [C]: phases declared-but-never-announced, and announced-but-undeclared, are RED"
root="$(newrepo)"
# Written whole rather than patched in place: an in-place edit needs sed -i or
# perl, whose grammars differ per platform, and a fixture that silently fails to
# apply produces a GREEN case that proves nothing.
cat >"$root/.claude/workflows/fixture.workflow.js" <<'DRIFT'
export const meta = {
  name: 'fixture-engine',
  description: 'A fixture engine whose phases drift in both directions.',
  whenToUse: 'Never in anger.',
  phases: [
    { title: 'One', detail: 'announced below' },
    { title: 'Phantom', detail: 'declared here, never announced anywhere' },
  ],
};

phase('One');
phase('Undeclared');
return { ok: true };
DRIFT
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
if has "$out" "phantom progress group"; then ok "reports the declared-never-announced direction"; else no "missing declared>announced: $out"; fi
if has "$out" "does not declare it"; then ok "reports the announced-never-declared direction"; else no "missing announced>declared: $out"; fi
echo

# ── case 14: a commented-out phase() is not an announcement ────────────────
# The control for case 13: clause C reads a comment-masked source, so a phase
# call inside a comment must NOT count. A raw text scan passes this fixture and
# is wrong.
echo "case 14 [C control]: a commented-out phase() does not count as announced"
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
printf "// phase('Three');\n" >>"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 0 ]; then ok "exit 0 — the comment is not an announcement"; else no "expected 0, got $rc: $out"; fi
echo

# ── case 15: meta without a description is RED ─────────────────────────────
echo "case 15 [M2]: a meta with no description is RED (the harness requires name AND description)"
root="$(newrepo)"
{
  printf 'export const meta = {\n'
  printf "  name: 'fixture-engine',\n"
  printf "  description: '',\n"
  printf '  phases: [],\n'
  printf '};\n'
} >"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 1 ]; then ok "exit 1"; else no "expected 1, got $rc: $out"; fi
if has "$out" "must be a non-empty string"; then ok "names the missing field"; else no "no [M2] field message: $out"; fi
echo

# ── case 16: home-relative paths are RED ───────────────────────────────────
echo "case 16 [H]: \$HOME, os.homedir() and a quoted ~/ are RED"
for probe_line in 'const p = process.env.HOME + "/x";' 'const p = os.homedir();' 'const p = "~/notes/x.md";' 'const p = `$HOME/x`;'; do
  root="$(newrepo)"
  write_engine "$root/.claude/workflows/fixture.workflow.js"
  printf '%s\n' "$probe_line" >>"$root/.claude/workflows/fixture.workflow.js"
  run_on "$root"
  if [ "$rc" -eq 1 ] && has "$out" "home-relative path"; then
    ok "RED: $probe_line"
  else
    no "expected a [H] red for: $probe_line (rc=$rc) $out"
  fi
done
echo

# ── case 17: the REAL corpus is green ──────────────────────────────────────
# An instrument that has only ever met synthetic input is not yet an instrument.
echo "case 17: the real .claude/workflows corpus passes"
if [ -d "$REAL_ROOT/.claude/workflows" ]; then
  out="$("$SCRIPT" "$REAL_ROOT/.claude/workflows" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then ok "exit 0 on the real corpus"; else no "the real corpus is RED: $out"; fi
  n="$(sed -n 's/^workflow-portability-check: \([0-9]*\) engine(s) checked.*/\1/p' <<<"$out")"
  if [ "${n:-0}" -ge 4 ]; then
    ok "walked $n real engines (a corpus that shrinks to 0 would be caught by clause N)"
  else
    no "only walked ${n:-0} real engines — the enumeration is under-matching"
  fi
else
  no "no real corpus at $REAL_ROOT/.claude/workflows"
fi
echo

# ── case 18: a runner with no node REDS, it does not skip ──────────────────
# A check that quietly stops checking when a tool goes missing is the exact shape
# this tripwire exists to remove.
echo "case 18 [N]: no node on PATH is RED, never a skip"
fakebin="$TMPROOT/fakebin"
mkdir -p "$fakebin"
# Everything the tripwire reaches for BEFORE its node probe, and bash itself
# (this case re-execs the script through it). Only ABSOLUTE resolutions are
# linked: `command -v printf` answers with the bare builtin name, and linking
# that would plant a dangling symlink in the fixture PATH.
for t in bash git dirname find grep wc sed cut tr sort mktemp rm cat head uname; do
  p="$(command -v "$t" 2>/dev/null || true)"
  case "$p" in /*) ln -sf "$p" "$fakebin/$t" ;; esac
done
root="$(newrepo)"
write_engine "$root/.claude/workflows/fixture.workflow.js"
# The probe is `bash -c 'command -v node'`, NOT a bare `command -v node`. Case 12
# ran node, which put it in THIS shell's command hash table, and a hashed name is
# resolved from the cache without consulting PATH at all — the bare form reported
# "node is still on PATH" and skipped this case even though the fixture was
# correct. A fresh bash starts with an empty hash table.
if [ -x "$fakebin/git" ] && ! PATH="$fakebin" bash -c 'command -v node' >/dev/null 2>&1; then
  out="$(PATH="$fakebin" bash "$SCRIPT" "$root/.claude/workflows" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 1 ]; then ok "exit 1 with no node on PATH"; else no "expected 1, got $rc: $out"; fi
  if has "$out" "node is not on PATH"; then ok "fails BY NAME"; else no "no clause-N message: $out"; fi
else
  no "could not build a node-free PATH fixture (git symlink missing, or node is not resolved via PATH here)"
fi
echo

# ── case 19: the listing cap WARNS and does not red ────────────────────────
# Clause W is the one advisory clause, and "advisory" is a claim that has to be
# proven in both directions: the warning must actually appear, and it must NOT
# move the exit code. A clause that reds when the header says it warns is a
# broken promise; one that stays silent is decoration.
echo "case 19 [W]: an over-long skill listing WARNS, names the cut point, and does NOT red"
root="$(newrepo)"
# 1500 chars of padding, then a repeated marker: the cut lands at listing char
# 1535, i.e. inside the markers, so the "what you stop seeing" preview must carry
# one whatever the exact offset. A single marker at the very END of the string
# would sit past the preview window and make this assertion a coin flip.
long="$(head -c 1500 /dev/zero | tr '\0' 'w')"
tail_markers=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do tail_markers="${tail_markers}CUTMARKER"; done
{
  printf 'export const meta = {\n'
  printf "  name: 'fixture-engine',\n"
  printf "  description: 'A fixture engine.',\n"
  printf "  whenToUse: '%s%s',\n" "$long" "$tail_markers"
  printf '  phases: [],\n'
  printf '};\n'
} >"$root/.claude/workflows/fixture.workflow.js"
run_on "$root"
if [ "$rc" -eq 0 ]; then ok "exit 0 — W is advisory, not a gate"; else no "expected 0, got $rc: $out"; fi
if has "$out" "::warning::"; then ok "emits a warning annotation"; else no "no warning emitted: $out"; fi
if has "$out" "it is cut at char 1535"; then
  ok "names the cut point (1536 - 1, the harness's own slice)"
else
  no "the cut point is not named: $out"
fi
if has "$out" "CUTMARKER"; then
  ok "quotes the text that stops being visible"
else
  no "the dropped tail is not shown: $out"
fi
echo

# ── verdict ────────────────────────────────────────────────────────────────
echo "----------------------------------------"
echo "$pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  exit 1
fi
