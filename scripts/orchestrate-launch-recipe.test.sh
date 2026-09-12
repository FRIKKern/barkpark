#!/usr/bin/env bash
#
# orchestrate-launch-recipe.test.sh — the POSITIVE CONTROL over the
# orchestrate-tasks skill's launch recipes and its per-session lane files.
#
# WHY IT EXISTS. Two findings, both of which were written down as prose and
# both of which prose alone cannot hold:
#
#   task-018fc84f61c33923 — a headless builder launched as
#     `nohup claude -p … --model opus --dangerously-skip-permissions`
#     terminates its own background tasks at 600 s, mid-Elixir-compile, and
#     exits looking like a calm finish. Five builders, five deaths, one cause
#     (2026-09-05). The fix is one env var in the recipe — and a recipe is
#     exactly the kind of line someone retypes from memory without it.
#
#   task-50d7d1a599dd14dd — two sessions of ONE lane shared one set of
#     filenames; a live row vanished from a pulse list and a status file was
#     rewritten 149 lines -> 94 (2026-09-07). The remedy is per-SESSION names,
#     which rot the moment a doc or a reader goes back to `status.md`.
#
# THE CONTROL IS THE POINT: this harness DERIVES the recipe set by grepping the
# skill for `claude -p` / `nohup claude`, so a recipe added tomorrow is checked
# without anyone editing this file, and it REFUSES (exit 2) when it finds zero
# recipes rather than passing vacuously. Arm 9 mutates a scratch copy — the env
# var deleted — and asserts this harness REDS on it; a guard that never fires on
# a broken tree is a guard nobody can trust.
#
# EXIT: 0 all arms pass · 1 a named violation · 2 cannot measure.
# bash 3.2 compatible (macOS system bash): no associative arrays, no mapfile.

set -uo pipefail

ROOT="${SKILL_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SKILL="$ROOT/.claude/skills/orchestrate-tasks"
CEILING_VAR='CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS'
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }

[ -d "$SKILL" ] || { echo "orchestrate-launch-recipe.test.sh: CANNOT READ $SKILL — not a measurement, a refusal" >&2; exit 2; }

# Every file in the skill that composes a headless launch. DERIVED, never listed.
recipes=$(grep -rl -e 'claude -p' -e 'nohup claude' "$SKILL" 2>/dev/null | sort)
n_recipes=$(printf '%s\n' "$recipes" | grep -c . | tr -d ' ')

echo "== arm 1: the recipe set is DERIVED and NON-EMPTY (a zero here is a broken instrument, not a pass)"
if [ "$n_recipes" -lt 1 ]; then
  echo "  CANNOT MEASURE: no file under $SKILL mentions 'claude -p' or 'nohup claude'." >&2
  echo "  Either the skill stopped launching headless builders (delete this harness and say so" >&2
  echo "  in the PR), or the grep broke. Refusing to report a vacuous pass." >&2
  exit 2
fi
ok "$n_recipes file(s) carry a launch recipe:"
printf '%s\n' "$recipes" | sed "s|^$ROOT/|       |"

echo "== arm 2 (criterion 0): EVERY launch recipe sets $CEILING_VAR"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -q "$CEILING_VAR" "$f"; then
    ok "$(basename "$f") names $CEILING_VAR: $(grep -m1 -o "$CEILING_VAR=[0-9]*" "$f")"
  else
    bad "$(basename "$f") composes a headless launch WITHOUT $CEILING_VAR — it will die at 600 s"
  fi
done <<EOF
$recipes
EOF

echo "== arm 3 (criterion 0): the value is 0, or a comment justifies a non-zero ceiling"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  grep -q "$CEILING_VAR" "$f" || continue
  if grep -q "$CEILING_VAR=0" "$f"; then
    ok "$(basename "$f") sets it to 0 (wait indefinitely)"
  elif grep -qi "$CEILING_VAR=[0-9]* *#.*because\|justif" "$f"; then
    ok "$(basename "$f") sets a justified non-zero ceiling"
  else
    bad "$(basename "$f") sets $CEILING_VAR to something other than 0 with no written justification"
  fi
done <<EOF
$recipes
EOF

echo "== arm 4 (criterion 1): the builder prompt template says COMMIT AND PUSH BEFORE REPORTING"
if grep -rqi 'COMMIT AND PUSH BEFORE REPORTING' "$SKILL"; then
  ok "instruction present: $(grep -rhoi 'COMMIT AND PUSH BEFORE REPORTING[^.]*' "$SKILL" | head -1)"
else
  bad "no COMMIT AND PUSH BEFORE REPORTING instruction anywhere in the skill"
fi
if grep -rqi 'pushed branch survives' "$SKILL"; then
  ok "and it says WHY (a pushed branch survives a killed session)"
else
  bad "the instruction carries no reason, so the next editor will trim it"
fi

echo "== arm 5 (criterion 2): the ceiling-kill SIGNATURE is documented, and a wrapper decides it"
if grep -rq 'Background tasks still running after' "$SKILL"; then
  ok "the terminating line is quoted verbatim in the skill"
else
  bad "the terminating line the CLI prints is nowhere in the skill — a lead cannot grep for it"
fi
CHECKER="$SKILL/helpers/launch-headless-builder.sh"
if [ -x "$CHECKER" ] && grep -q -- '--check' "$CHECKER"; then
  ok "launch-headless-builder.sh --check exists and is executable"
else
  bad "no executable --check wrapper at $CHECKER"
fi
if grep -rqi 'dirty worktree\|DIRTY WORKTREE' "$SKILL"; then
  ok "the second half of the signature (a dirty worktree) is written down too"
else
  bad "the dirt half of the signature is undocumented — the ceiling line is usually absent"
fi

echo "== arm 6 (task-50d7d1a599dd14dd criterion 0): the docs name PER-SESSION files, not lane-wide ones"
for doc in "$SKILL/SKILL.md" "$SKILL/LEAD-BRIEF.md"; do
  [ -f "$doc" ] || { bad "CANNOT READ $doc"; continue; }
  if grep -q 'status\.<session>\.md\|status\.s<N>\.md' "$doc"; then
    ok "$(basename "$doc") names a per-session status file"
  else
    bad "$(basename "$doc") still documents a lane-wide status file"
  fi
done
if grep -q 'held\.<session>\.txt\|held\.s<N>\.txt' "$SKILL/LEAD-BRIEF.md"; then
  ok "LEAD-BRIEF.md names a per-session held list"
else
  bad "LEAD-BRIEF.md still documents a lane-wide held.txt for the pulse loop"
fi

echo "== arm 7 (the reader half): every reader of a session-owned file follows the rename"
if grep -q 'status\.\*\.md' "$SKILL/helpers/lane-status.sh"; then
  ok "lane-status.sh globs status.*.md as well as status.md"
else
  bad "lane-status.sh reads only status.md — a renamed writer with an unrenamed reader is a silent gap"
fi
if grep -q -- '--session)' "$SKILL/helpers/held-liveness.sh" && grep -q -- '--held)' "$SKILL/helpers/held-liveness.sh"; then
  ok "held-liveness.sh takes --held/--session"
else
  bad "held-liveness.sh still hardcodes <lane-dir>/held.txt"
fi
if grep -q 'DECISIONS-FROM-MAIN.md. stays LANE-wide\|DECISIONS-FROM-MAIN.md` stays LANE-wide' "$SKILL/SKILL.md" "$SKILL/LEAD-BRIEF.md"; then
  ok "DECISIONS-FROM-MAIN.md is explicitly declared lane-wide and single-writer"
else
  bad "DECISIONS-FROM-MAIN.md's ownership is unstated — a reader cannot tell whether it was renamed"
fi

echo "== arm 8: both helper selftests pass, run to EOF (never piped to head/tail)"
for h in session-files launch-headless-builder; do
  out=$(bash "$SKILL/helpers/$h.sh" --selftest 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then ok "$h.sh --selftest: $(printf '%s' "$out" | grep -E 'passed, .* failed' | tail -1)"
  else bad "$h.sh --selftest exited $rc"; printf '%s\n' "$out" | sed 's/^/       /'; fi
done

# THE RECURSION FENCE. Arm 9 re-invokes this harness against a mutant copy. The
# mutant copy still carries recipes, so without this guard the inner run would
# mutate and re-invoke in turn, forever. SKILL_ROOT_OVERRIDE is set only by arm
# 9, so its presence IS "you are the inner run".
if [ -n "${SKILL_ROOT_OVERRIDE:-}" ]; then
  echo
  echo "orchestrate-launch-recipe.test.sh (mutant arm): $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

echo "== arm 9 (MUTATION): strip $CEILING_VAR from the recipes in a scratch copy — this harness must RED"
mut=$(mktemp -d) || { echo "CANNOT MEASURE: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$mut"' EXIT
mkdir -p "$mut/.claude/skills" "$mut/scripts"
cp -R "$SKILL" "$mut/.claude/skills/orchestrate-tasks"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel="${f#"$SKILL"/}"
  [ -f "$mut/.claude/skills/orchestrate-tasks/$rel" ] || continue
  sed -i.bak "s/$CEILING_VAR/BP_MUTANT_VAR_REMOVED/g" "$mut/.claude/skills/orchestrate-tasks/$rel"
  rm -f "$mut/.claude/skills/orchestrate-tasks/$rel.bak"
done <<EOF
$recipes
EOF
mout=$(SKILL_ROOT_OVERRIDE="$mut" bash "${BASH_SOURCE[0]}" 2>&1); mrc=$?
if [ "$mrc" -eq 1 ]; then
  ok "the mutant tree exits 1 (arm 2 fires: $(printf '%s' "$mout" | grep -c 'WITHOUT '"$CEILING_VAR" | tr -d ' ') recipe(s) named)"
else
  bad "the mutant tree exited $mrc — this harness cannot see a recipe that lost the env var"
fi

echo
echo "orchestrate-launch-recipe.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
