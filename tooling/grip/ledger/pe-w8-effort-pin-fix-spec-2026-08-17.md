# pe-w8 effort-pin fix spec — re-derivation recipes (2026-08-17)

Verifier: effort-pin-fix-spec. Read-only survey; no commits, no bp mutations.

## Drift confirmed on origin/main (NOT hot-fixed)
```
git fetch origin main && \
git show origin/main:tooling/paper-excellence/harness/spawn-cold.sh | \
  grep -nE 'COLD_MODEL|--model|--effort|COLD_EFFORT'
```
Expect: line 56 `COLD_MODEL="${COLD_MODEL:-opus}"`, line 104 exec passes `--model "$COLD_MODEL"` ONLY, ZERO `--effort` / `COLD_EFFORT` anywhere.

## CLI: --effort is a separate flag; opus@medium is an invalid token
```
/Users/pelle/.local/bin/claude --help 2>&1 | grep -iE 'effort|model'
```
Expect both `--effort <level>` and `--model <model>` as distinct flags.

Invalid-token proof (dummy key, self-kill ~10s):
```
env -i HOME=/tmp/fakehome PATH="/Users/pelle/.local/bin:/usr/bin:/bin" \
  ANTHROPIC_API_KEY=sk-ant-invalid-test \
  /Users/pelle/.local/bin/claude --bare --setting-sources '' \
  --model opus@medium -p x --output-format stream-json --verbose 2>&1 | head -3
```
Expect: `[claude-code:unrecognized_model] {"model":"opus@medium","query_source":"sdk"}` and init line echoes `"model":"opus@medium"` — the CLI does NOT hard-fail, it silently proceeds on a fallback → HARNESS VOID.

Correct form proof:
```
env -i HOME=/tmp/fakehome PATH="/Users/pelle/.local/bin:/usr/bin:/bin" \
  ANTHROPIC_API_KEY=sk-ant-invalid-test \
  /Users/pelle/.local/bin/claude --bare --setting-sources '' \
  --model opus --effort medium -p x --output-format stream-json --verbose 2>&1 | head -1
```
Expect init line resolves `"model":"claude-opus-5"`, ZERO `unrecognized_model` diagnostics.

## Gate for the follow-up PR
```
sed -n '30,40p' .github/workflows/shell-harnesses.yml   # header names main's required set
grep -n 'spawn-cold' .github/workflows/shell-harnesses.yml   # NO MATCH → not wired, no blocking test
```
Main's required contexts (verbatim from shell-harnesses header): Elixir gate, PR references an active task, Cloud gate, Console gate. A tooling/harness/*.sh-only PR triggers none of the code gates' real work; the one it MUST satisfy is **PR references an active task** (pr-task-gate) — put the run task id in the PR body. shell-harnesses RUNS (advisory) but does not BLOCK.
