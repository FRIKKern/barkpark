---
name: codebase-intelligence
description: Use when the user asks to "research the codebase", "is every file evaluated", "bring coverage to 100%", "what changed since last research", "score file importance", "check our style / consistency", "are we consistent", "what's important and broken", or wants a prioritized map of the repo. Runs programmatic scans first (zero tokens) to detect drift, dispatches agents ONLY on what changed, and joins importance × consistency into a prioritized worklist. When nothing changed, it reports and stops without spending a single agent token. Lives in tooling/ (research-coverage, file-importance, consistency, blast-radius, combined).
---

# Codebase Intelligence

A living, prioritized map of every file. Discipline: **programmatic does everything
free; agents do only the judgment a machine can't, only on what changed.** Every
script is plain Node (no deps); all outputs are gitignored — regenerate, never commit.

```
1 coverage  (gate)   → which files are new/changed since last evaluated?   [free]
2 importance         → per-file score = blast-radius prior × agent crit
3 consistency        → per-group norm; drift vs intentional; layering; dup
4 combined           → importance × consistency = the worklist             [free]
```

Agent fan-out uses the `Workflow` tool, Sonnet (read-only), batched ~10/agent, each
agent SEEDED with pre-computed signals so it judges instead of rediscovering.

## 1 · Coverage gate (always first — usually the whole job)

```
node tooling/research-coverage/coverage.mjs scan      # → coverage-report.json {pct, stale, new, ...}
```
- **If `stale==0 && new==0 && orphaned==0`:** report `100% — last full research <date>`, STOP. **Zero tokens.**
- **Else:**
  ```
  node tooling/research-coverage/coverage.mjs prune     # drop deleted
  node tooling/research-coverage/coverage.mjs batches    # writes batches/, batch-count.txt — ONLY the drift
  ```
  Dispatch `N = batch-count.txt` agents. Each reads `tooling/research-coverage/batches/batch-NNN.json`
  (`[{path,hash}]`), Reads each file, writes `tooling/research-coverage/results/batch-NNN.json`:
  `[{path, role, description, score 0-100, what_breaks_if_wrong, confidence}]` (strict JSON).
  Rubric: 90-100 core infra/contracts/entrypoints · 70-89 important module · 40-69 standard · 20-39 leaf · 1-19 test/fixture.
  Then:
  ```
  node tooling/research-coverage/coverage.mjs record     # fold results, stamp hashes + lastFullResearch
  node tooling/research-coverage/coverage.mjs scan        # verify 100%
  ```
  First-time only: `coverage.mjs seed` bootstraps the ledger from a prior importance run.

## 2 · Importance (full rebuild of the chart, when asked)

```
node tooling/blast-radius/build-index.mjs --skip-elixir   # reverse-dep graph (fan-in)
node tooling/file-importance/build-signals.mjs 10          # signals + batches/ (priors)
```
Dispatch one agent per `tooling/file-importance/batches/batch-NNN.json` → write `results/batch-NNN.json`
`[{path, role, description, criticality 0-100, what_breaks_if_wrong, confidence}]`. Then:
```
node tooling/file-importance/merge.mjs                     # → importance-chart.{html,csv} (blend prior×agent)
```
Note: the coverage ledger already carries importance scores, so for most work step 2 is unnecessary — use the ledger.

## 3 · Consistency (relational — "do we follow a style?")

```
node tooling/consistency/consistency.mjs scan             # naming + structure(use/behaviour) + layering + dead-code + dup
node tooling/consistency/consistency.mjs batches           # one task per outlier GROUP
```
Dispatch one agent per `tooling/consistency/batches/group-NNN.json`. Each Globs the group dir,
reads 2-3 conforming peers + the outliers, writes `tooling/consistency/results/group-NNN.json`:
`{dir, canonical_pattern, verdicts:[{file, verdict: "drift"|"intentional"|"refactor", recommendation}]}`. Then:
```
node tooling/consistency/consistency.mjs merge            # → consistency-report.html (norms + verdicts)
```

## 4 · Combined (the worklist — pure join, free)

```
node tooling/combined/combine.mjs                         # → combined-report.{html,csv}
```
`priority = importance × inconsistency-severity` → quadrant {important&inconsistent ← act, important&clean, minor&inconsistent, minor&clean}. The top of the worklist is what to fix.

## Token honesty

`scan/batches/record/prune`, `build-index`, `build-signals`, `consistency scan`, `combine` are all
pure bookkeeping — milliseconds, zero tokens. Agents fire only on drift / outliers. A clean re-run of
the coverage gate spends nothing; a one-file change re-evaluates one file. See `tooling/README.md`.
