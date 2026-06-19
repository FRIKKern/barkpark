<!-- doc-tier: human -->
# tooling/ — Codebase Intelligence suite

A living, prioritized map of every file in the repo. One discipline runs through
all of it: **programmatic scripts do everything they can for free; agents are
spent only on the judgment a machine can't produce, and only on what changed.**

```
research-coverage ─ every file evaluated? content-hash ledger; agents only on drift
file-importance   ─ per-file importance score (blast-radius prior × agent criticality)
consistency       ─ relational: per-group norm, drift vs intentional, layering, dup
blast-radius      ─ what a change affects; cross-language seam guard (pre-push hook)
        └────────────────────────┬───────────────────────────────────────────────┘
combined          ─ importance × consistency → the prioritized worklist
```

| Dir | What it answers | Entry |
|---|---|---|
| `research-coverage/` | "Is every file currently evaluated? What changed?" | `coverage.mjs scan` |
| `file-importance/` | "How important is each file?" | `build-signals.mjs` → agents → `merge.mjs` |
| `consistency/` | "Do we follow a style? Where do we break it?" | `consistency.mjs scan` |
| `blast-radius/` | "What does this change affect? Did it touch the wire contract?" | `check.mjs` (pre-push) |
| `combined/` | "What's both important AND inconsistent?" (the worklist) | `combine.mjs` |

Orchestrated by the **`codebase-intelligence`** skill (`.claude/skills/`). Each pass
is a plain Node script (no deps); all derived outputs (ledgers, indexes, charts,
batches, results) are gitignored — regenerate, never commit. Agent fan-out uses
the `Workflow` tool; read each pass's `README` / `config.json` for details.

## Design invariants

- **Programmatic first.** Dependency graphs, hashing, churn, naming, layering,
  duplication — all computed exactly and freely. An LLM is never asked to do what
  a parser does perfectly.
- **Agents on drift only.** Content hashes gate every agent call; a clean re-run
  costs zero tokens. A one-file change re-researches one file.
- **Blend, don't replace.** Final scores anchor an objective prior with agent
  judgment, so the result is correct, calibrated, and auditable.
