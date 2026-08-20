#!/usr/bin/env bash
#
# workflow-module-exec-smoke.test.sh — the mutation harness for the workflow
# module-scope EXECUTION gate.
#
# HOUSE LAW (borrowed verbatim in spirit from workflow-portability-check.test.sh):
# a harness with only green cases is the defect, not the proof. This file exists
# to show scripts/workflow-module-exec-smoke.sh LOSING on the exact inputs it
# claims to catch.
#
# THE TWO CASES THIS TASK EXISTS FOR — each is run against BOTH gates, because
# the finding is not "the new gate reds", it is "the new gate reds on something
# the old gate calls green":
#
#   case 2  a module-scope TDZ            parse-only: GREEN   exec: RED
#   case 3  a schema `required` key that  parse-only: GREEN   exec: RED
#           is not in `properties`
#
# The controls matter as much: case 4 proves the exec gate did not LOSE the
# parse coverage it sits beside, and case 5 proves an unknown runner global is
# a red rather than a silent skip.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXEC_GATE="$HERE/workflow-module-exec-smoke.sh"
PARSE_GATE="$HERE/workflow-module-smoke.sh"
REAL_ROOT="$(cd -- "$HERE/.." && pwd)"
REAL_ENGINE="$REAL_ROOT/.claude/workflows/bp-epic-cycle.workflow.js"

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  ok   — $1"; }
no()  { fail=$((fail + 1)); echo "  FAIL — $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── case 1 — control: the live corpus loads ─────────────────────────────────
echo "case 1: the real corpus executes module scope cleanly"
if out=$(bash "$EXEC_GATE" 2>&1); then
  n=$(printf '%s\n' "$out" | grep -c 'MODULE-EXEC-OK' || true)
  if [ "$n" -ge 3 ]; then ok "live corpus green ($n engines)"
  else no "expected >=3 engines, saw $n"; fi
else
  no "the real corpus RED — $out"
fi

# ── case 2 — THE TDZ MUTANT, against both gates ─────────────────────────────
echo "case 2: a module-scope TDZ is invisible to parse, caught by exec"
cat > "$TMP/tdz.workflow.js" <<'EOF'
export const meta = { name: 'tdz-mutant', description: 'x', phases: [] }
const USES_IT = `${LATER_CONST}`
const LATER_CONST = 'defined after its use'
EOF
if bash "$PARSE_GATE" "$TMP/tdz.workflow.js" >/dev/null 2>&1; then
  ok "parse-only gate reports it GREEN (the gap this task fixes)"
else
  no "parse-only gate red — the premise of this task no longer holds"
fi
if out=$(bash "$EXEC_GATE" "$TMP/tdz.workflow.js" 2>&1); then
  no "exec gate GREEN on a real TDZ — the gate cannot lose"
else
  case "$out" in
    *"Cannot access 'LATER_CONST' before initialization"*)
      ok "exec gate RED, naming the actual cause" ;;
    *) no "exec gate red but did not name the TDZ — $out" ;;
  esac
fi

# ── case 3 — THE SCHEMA TRIPWIRE MUTANT, on a REAL engine ───────────────────
echo "case 3: a required key missing from properties, mutated into a real engine"
# SURVEY_SCHEMA's `required` array gains a key that is defined nowhere. The
# engine's own module-scope tripwire throws on it — and only if something RUNS.
python3 - "$REAL_ENGINE" "$TMP/schema.workflow.js" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Target SURVEY_SCHEMA's OWN top-level `required`, not merely the first
# `required:` in the file: the engine's tripwire only walks SURVEY/VERIFY/
# STRATEGY, so a bogus key anywhere else (JOURNEY_FIELD's nested arrays, say)
# is a mutant the tripwire is not asked to catch and proves nothing.
i = src.index("const SURVEY_SCHEMA = {")
m = re.compile(r"^  required: \[", re.M).search(src, i)
assert m, "SURVEY_SCHEMA has no top-level required: [ — re-anchor this mutation"
new = src[:m.end()] + "'__ghost_key__', " + src[m.end():]
open(sys.argv[2], 'w').write(new)
PY
if bash "$PARSE_GATE" "$TMP/schema.workflow.js" >/dev/null 2>&1; then
  ok "parse-only gate reports the broken contract GREEN"
else
  no "parse-only gate red on a parseable file"
fi
if out=$(bash "$EXEC_GATE" "$TMP/schema.workflow.js" 2>&1); then
  no "exec gate GREEN on a schema whose required key is undefined"
else
  case "$out" in
    *"__ghost_key__"*|*"does not define it in properties"*)
      ok "exec gate RED, firing the engine's own module-scope tripwire" ;;
    *) no "exec gate red for the wrong reason — $out" ;;
  esac
fi

# ── case 4 — control: the exec gate did NOT lose parse coverage ─────────────
echo "case 4: a genuine syntax error is red on BOTH gates"
printf 'export const meta = { name: %s, description: %s, phases: [] }\nconst x = (((;\n' "'a'" "'b'" > "$TMP/syntax.workflow.js"
bash "$PARSE_GATE" "$TMP/syntax.workflow.js" >/dev/null 2>&1 && p=green || p=red
bash "$EXEC_GATE"  "$TMP/syntax.workflow.js" >/dev/null 2>&1 && e=green || e=red
if [ "$p" = red ] && [ "$e" = red ]; then ok "both gates red (parse coverage retained)"
else no "parse=$p exec=$e — expected red/red"; fi

# ── case 5 — an unknown runner global REDS, never skips ─────────────────────
echo "case 5: an unstubbed runner global is an actionable red, not a skip"
cat > "$TMP/unknown.workflow.js" <<'EOF'
export const meta = { name: 'unknown-global', description: 'x', phases: [] }
const V = someBrandNewRunnerGlobal()
EOF
if out=$(bash "$EXEC_GATE" "$TMP/unknown.workflow.js" 2>&1); then
  no "an unknown global passed — the gate looked away"
else
  case "$out" in
    *"someBrandNewRunnerGlobal"*"add"*STUBS*|*"someBrandNewRunnerGlobal"*STUBS*)
      ok "red, and the message says how to fix it" ;;
    *) no "red but not actionable — $out" ;;
  esac
fi

# ── case 6 — a missing file is red, not skipped ─────────────────────────────
echo "case 6: a named file that does not exist is red"
if bash "$EXEC_GATE" "$TMP/nope.workflow.js" >/dev/null 2>&1; then
  no "a missing file passed"
else ok "missing file red"; fi

# ── case 7 — an engine that never spends still passes ──────────────────────
echo "case 7: an engine with no spend at all loads clean (no false red)"
cat > "$TMP/nospend.workflow.js" <<'EOF'
export const meta = { name: 'no-spend', description: 'x', phases: [] }
const SCHEMA = { type: 'object', properties: { a: { type: 'string' } }, required: ['a'] }
log('nothing to spend here')
EOF
if bash "$EXEC_GATE" "$TMP/nospend.workflow.js" >/dev/null 2>&1; then
  ok "clean completion counts as a pass"
else no "a spendless engine was falsely red"; fi

echo
echo "workflow-module-exec-smoke.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
