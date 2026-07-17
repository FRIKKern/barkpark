# Scaffy W6 — the duel harness

The measurement rig for the Scaffy benchmark (epic Wave 6). It runs **duel cells** —
one chore × one arm × one repetition — on a pinned, pre-warmed worktree, captures a
**real token meter**, scores by **parsed assert statuses** (never exit codes), and
proves **byte-consistency + reversibility**. Pre-registered before any scored agent
spends a token (the honesty law). The registered matrix is [`matrix.json`](matrix.json);
this rig runs only what is registered there.

> This slice builds and smoke-proves the rig (arm C, one cell). The full matrix is
> driven by the round-2 `scaffy-w6-run-duels` slice, which writes `results/` and gates
> on `validate_results.py`. **Do not run the full matrix from here.**

## The arms (D65)

| arm | what it is | cap |
|-----|-----------|-----|
| `C`  | the raw engine, **no agent**: `bp scaffy run <cmd> --var … -o json` | $0 (no LLM) |
| `A`  | agent armed with the catalog, **instructed catalog-first** | $1.50 |
| `Ap` | A-prime: scaffy present on disk but **not mentioned in the brief** — the doctrine-gap arm (does the agent reach for the catalog unprompted? L2, D71) | $1.50 |
| `B`  | bare agent **hand-editing**, told not to use scaffy | $3.00 |

The letters follow the **published prereg paper** (`scaffy-duels-prereg`) — its rep
counts and predictions reference exactly these semantics. Every agent brief is the
chore's registered `brief` from `matrix.json` (the CONCRETE task, including the
registered var values, so all arms attempt the *same chore instance*) plus the arm
doctrine sentence above.

Boundary cells (`boundary--*`) run at the $3.00 cap; they have **no arm C** — the
ExecRunner-deadline chore is a judgement edit no scaffy command expresses (that is the
point: the boundary is where Scaffy *loses*).

## Spawn shape (D66) — verbatim

Arms A / Ap / B spawn the pinned Claude CLI; the shell **must not be sandboxed** (`bp`
needs network — a sandboxed spawn SIGKILLs it, exit 137):

```
claude -p "<brief>" \
  --model sonnet \
  --output-format json \
  --permission-mode bypassPermissions \
  --no-session-persistence \
  --max-budget-usd <cap>
```

with `cwd` = the cell worktree. **Arm C never spawns `claude`** — it calls
`bp scaffy run` directly.

## Meter law (D66) — verbatim

LLM spend is read from the Claude CLI's own `--output-format json` envelope:
top-level `total_cost_usd` + `usage{input_tokens, output_tokens, cache_*}`. This is
**proven equal** to the de-duplicated JSONL transcript sum.

> **Naive line-by-line JSONL summation is BANNED** — it double-counts streamed deltas.

Arm C is the engine alone: no LLM, `total_cost_usd = 0`, `usage = null`.

## Gates law (D67)

Green/red is decided by the **parsed assert statuses** in the run's `-o json` envelope
(`asserts[].status` ∈ `pass` / `fail` / `deferred`), on a **pre-warmed** tree — **never
the process exit code** (exit 5 conflates a validation error with an assert failure).
`deferred` asserts are TIER-ci gates the engine does not run locally; the harness
**force-runs** them in the warmed tree (`chores.<chore>.tier_ci_force`) and folds their
return codes into `gates_green`. An **empty assert list is never green** — an engine
refusal (bad `--var`, exit 2) produces no asserts, and silence must not score as
success.

**Agent arms are never green by trust**: the harness re-runs the chore's registered
mechanical gates itself (`chores.<chore>.agent_gate`, plus any `tier_ci_force`) after
the agent finishes, and `gates_green` requires at least one such check to have run and
all of them to pass. `validate_results.py` rejects an LLM-arm cell that claims green
with zero recorded checks. The boundary chore's judgment legs (the new test is
functionally equivalent to the fix commit's two subtests; the `CommandRunner` signature
is byte-unchanged) are scored by the run-duels reviewer on top of the mechanical gate.

The flagship's `RESOLVE_AT_RUN` sentinels (`CountBefore`/`CountAfter`,
`ParityCountBefore`/`ParityCountAfter`) are resolved by `run-cell.sh` from the cell
tree at run time (`toHaveLength(N)` in `js/packages/react/tests/PortableDoc.test.tsx`;
`EXPECTED_COUNT=` in `scripts/pd-parity-completeness.sh`) — fail-loud if unresolvable.

## Consistency + reversibility (D68)

* **Consistency** — `sha256(git diff)` per cell. The engine is byte-deterministic
  (identical across reps); agents drift. Boundary cells are **expected to vary**.
* **Reversibility** — `bp scaffy remove <cmd>.scaffy --var <same set>` (command + vars,
  **not** a receipt path), then `git diff --exit-code` must be 0. A failed gate still
  writes edits + a receipt, so remove is always attempted.

## Serial law (D66)

**One cell at a time.** No locking, no parallelism — the shared pin and the append-only
`results/RUNLOG.jsonl` timeline assume it. `validate_results.py` rejects any results dir
whose run records overlap.

## Pre-warm recipe (D64) — verbatim

`warm-worktree.sh <cell-slug> [--with-elixir]` (idempotent):

1. `git worktree add --detach <wt> 591fdcd53` under an isolated tmp root — **never the
   primary checkout**.
2. Copy `api/deps` from the primary checkout **after** asserting `mix.lock` byte-matches
   the pin (md5, fail-loud): mismatched deps = a silently different build.
3. With `--with-elixir`: run **one** scoped `mix test`
   (`errors_test.exs` + `error_code_coverage_test.exs`) to compile the app into
   `_build/test` (~170s cold, ~4s warm after). **Never** `mix ecto.create`/`ecto.migrate`
   — they force a second full `MIX_ENV=dev` compile and need a DB the scoped, DB-free
   tests do not.

The chore's own local `ASSERT CMD` (for `add-error-shape`, the same scoped `mix test`)
runs *inside* `bp scaffy run` against that warm `_build`.

Warm time is **excluded** from the measured wall-clock: `duration_ms` starts after the
warm + boundary staging finish (a cell measures WORK, not cold-build noise); the warm
cost is recorded separately as `warm_ms`.

## Files

| file | role |
|------|------|
| `matrix.json` | the D65 registered matrix as data (cells, caps, per-chore vars, meter/spawn law) |
| `warm-worktree.sh` | pin worktree + deps (md5-gated) + optional Elixir warm |
| `boundary-setup.sh` | stage the boundary bug (`git checkout 4adadf0e0~1 -- internal/agent/report{,_test}.go`) |
| `run-cell.sh` | run one cell: warm → run/spawn → parse asserts → force TIER-ci → sha256 → remove → diff-clean |
| `validate_results.py` | gate the results dir: every cell present, meter complete, caps respected, serial; `--self-test` proves it REDS on a broken fixture |
| `results/` | per-cell `<id>.json` + `RUNLOG.jsonl` (written by the run-duels slice; git-ignored here) |

## Usage

```sh
# smoke the rig end-to-end (arm C, one cell):
bash run-cell.sh add-error-shape C smoke

# validate a results dir against the registered matrix:
python3 validate_results.py results

# validate a subset (e.g. just the smoke cell):
python3 validate_results.py results --cells add-error-shape--C--smoke

# prove the validator is not vacuous (reds on broken fixtures):
python3 validate_results.py --self-test
```

## Honesty (the wish, verbatim)

> we don't want to use it unless it actually performs a lot better.

A benchmark that only flatters is worthless. The matrix deliberately includes the
**boundary** chore (Scaffy has no expression for it) and the flagship (the heaviest
gap). The flagship paper must state the crossover — where the engine wins, and where a
one-off judgement edit beats reaching for a command.
