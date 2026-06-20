<!-- doc-tier: human -->
# tooling/ — Codebase Quality suite

Scores **how good the codebase is** and **what it takes to improve it**. One
discipline runs through all of it: **programmatic scripts do everything they can
for free; agents are spent only on the judgment a machine can't produce, on what
changed, and to verify a finding before it drives the plan.**

```
research-coverage ─ every file evaluated? content-hash ledger; agents only on drift
file-importance   ─ per-file importance = blast-radius prior × agent criticality
consistency       ─ relational: per-group norm, drift vs intentional, layering, dup
ergonomics        ─ agent-cost: bloat (god-files) vs fragmentation → refactor_worth
risk              ─ test-presence proxy + defect-history (git bug-fix mining)
blast-radius      ─ what a change affects; cross-language seam guard (pre-push hook)
        ├───── combined  ─ importance × consistency → prioritized worklist
        └───── quality   ─ 8-dimension scorecard (A–F) + ROI-ranked improvement plan
```

| Dir | What it answers | Entry |
|---|---|---|
| `research-coverage/` | "Is every file currently evaluated? What changed?" | `coverage.mjs scan` |
| `file-importance/` | "How important is each file?" | `build-signals.mjs` → agents → `merge.mjs` |
| `consistency/` | "Do we follow a style? Where do we break it?" | `consistency.mjs scan` |
| `ergonomics/` | "Which files are too bloated to work with efficiently?" | `ergonomics.mjs` |
| `risk/` | "Is important code tested? Where do bugs actually land?" | `risk.mjs` |
| `blast-radius/` | "What does this change affect? Did it touch the wire contract?" | `check.mjs` (pre-push) |
| `combined/` | "What's both important AND inconsistent?" | `combine.mjs` |
| `quality/` | "How good is the codebase? What do we fix first?" | `quality.mjs` |
| `usefulness/` | "How useful (value/leverage) is each file, and why?" | `usefulness.mjs` → agents → `merge` |
| `intentions/` | "What objectives does each file serve?" (2nd edge type) | `review.mjs` → discovery → tag → `merge` |
| `barkpark-sync/` | "Publish every file as an interconnected Barkpark paper" | `generate.mjs` → `push.mjs` → `graph-view.mjs` |
| `status/` | **the entry point** — full quality report, incremental | `status.mjs` |

`node tooling/status/status.mjs` is the one command: it runs the whole programmatic
chain (~2s, free), regenerates the comprehensive 8-dimension report from cached
verdicts, and prints **FRESH** or the exact pending agent work. Re-runs are cheap
because every agent pass (research, consistency, issues) is content-hash cached —
unchanged files/groups are never re-judged.

Beyond the quality report, the suite has two more arcs (see the `codebase-quality`
skill): **ENRICH** — `usefulness` + `intentions` add the per-file knowledge layer;
**PUBLISH** — `barkpark-sync` ships every file as a Barkpark paper (source + all
axes + git history) wired by typed references (`dependencies` + `intentions`) into
an interconnected, filterable graph, in an isolated `codebase` dataset.

Orchestrated by the **`codebase-quality`** skill (`.claude/skills/`). Each pass is a
plain Node script (no deps); all derived outputs (ledgers, indexes, charts, reports,
batches, results, nodes.json) are gitignored — regenerate, never commit. Agent
fan-out uses the `Workflow` tool; read each pass's `README` / `config.json` for details.

## Design invariants

- **Programmatic first.** Dependency graphs, hashing, churn, naming, layering,
  duplication — all computed exactly and freely. An LLM is never asked to do what
  a parser does perfectly.
- **Agents on drift only.** Content hashes gate every agent call; a clean re-run
  costs zero tokens. A one-file change re-researches one file.
- **Blend, don't replace.** Final scores anchor an objective prior with agent
  judgment, so the result is correct, calibrated, and auditable.
