<!-- doc-tier: human -->
# tooling/ — Codebase Intelligence

> One question, answered four ways: **how good is this codebase, what do we fix
> first, how does every file relate to every other, and which open work matters
> most?** Built for a polyglot monorepo — Go, Elixir, TypeScript — where no single
> language server sees the whole picture.

One discipline runs through all of it:

> **Parsers do everything they can for free. Agents are spent only on the judgment
> a machine can't produce, only on what changed, and only after the finding is
> verified.** A clean re-run costs zero tokens. A one-file change re-evaluates one
> file.

The result is a scorecard you can trust, an improvement plan ranked by leverage,
and a live Barkpark graph where files, the goals they serve, and the tasks moving
them all hang together.

---

## The model — nine roots, each measured once

Every score traces back to a set of **canonical signals**, each owned by one
pass and never double-counted. Composites are built only by combining roots
*across* passes — so no signal silently votes twice (`SIGNALS.md`).

| Root | Means | Owner |
|---|---|---|
| **reach** | normalized transitive-dependent count — the single *value* axis | `usefulness` |
| **churn** | how often a file changes (git) | `file-importance` |
| **complexity** | size / bloat / fragmentation | `ergonomics` |
| **defects** | bug-fix + revert density (git-subject mining) | `risk` |
| **tests** | real line coverage where a suite runs, presence proxy elsewhere | `risk` |
| **conventions** | per-group norm; drift vs intentional; layering; duplication | `consistency` |
| **ownership** | bus-factor — primary-author share + author count | `risk` |
| **relationships** | what a change reaches; the cross-language wire seams | `blast-radius` |
| **filebase** | tree tidiness — root clutter, tracked build artifacts, dead docs/tasks, YAGNI orphans | `aesthetics` |

The first eight are *per-file* code-quality roots. **filebase** is the odd one
out and deliberately so: it measures the **shape of the tree itself** — not any
one file's graph properties — so it is orthogonal to all of them and cannot
double-count. It is the only root whose ethos is **YAGNI** (*You Aren't Gonna
Need It*): it rewards ABSENCE — a clean, navigable tree scores high; speculative
files, committed build output, a cold-doc graveyard, and dead tasks score low.

Four **composites** recombine clean roots, with weights *learned from the
codebase's own incident history* (see The standing loop):

```
Priority          = reach × severity × defect-amp × untested-boost   → fix-first list
Hotspot           = churn × complexity                                → refactor targets
Critical-untested = reach × ¬coverage                                 → test-first list
Refactor-worth    = bloat × churn × separability                      → safe-to-split list
```

---

## The pipeline

```
        ROOTS (programmatic, free)                      COMPOSED
  ┌─────────────────────────────────────┐      ┌───────────────────────────┐
  research-coverage  every file evaluated? ──┐
  blast-radius       reach + wire seams ──────┤
  file-importance    churn + importance ──────┼──▶ combined   reach × consistency
  usefulness         reach (+ why prose) ─────┤    quality    13-dim scorecard (A–F)
  ergonomics         bloat vs fragmentation ──┤               + 4 composite worklists
  risk               tests · defects · owner ─┤    fit        LEARNS the weights
  consistency        norm · drift · dup ──────┘               (logistic, AUC-scored)
  ├── cochange        files that change together → real / aspirational / accidental
  ├── intentions      the goals each file serves  → a second edge type
  ├── tasks           Barkpark work as a 3rd node → triage open work by impact
  └── scope           task/intention → context pack (exploration → lookup)
```

Every box is a dependency-free Node script. Agents enter only where a parser
can't judge — file criticality, whether a style deviation is real drift or an
intentional exception — and only for files/groups whose content hash changed.

---

## Four arcs

| Arc | Question | What you get |
|---|---|---|
| **ASSESS** | How good is it? What first? | 13-dimension scorecard (A–F) + the four ranked worklists |
| **ENRICH** | What is each file *for*? | per-file importance, reach + why, intentions, ownership, git history |
| **PUBLISH** | Show me the whole web | one Barkpark paper per file, typed references, an interconnected graph |
| **RELATE** | How does it all connect? | co-change coupling + Barkpark tasks as a third node layer, with triage |

The scorecard dimensions: **Evaluated · Consistency · Architecture · Hotspots ·
Modularity · Tested · Reliability · Duplication · Dead-code** (the code-quality
core) **· Contract · Dependencies** (wire seams + supply chain) **· Bloat ·
Aesthetics** (the *filebase* axis — root clutter + build artifacts; dead docs +
dead tasks + YAGNI orphans) — each keyed to one root, each carrying a one-line
note and a weight. The two filebase dims carry a light weight (~0.05 each) so the
tree-mess axis moves the grade without swamping code quality.

---

## One command

```bash
node tooling/status/status.mjs
```

The entry point for ASSESS, ENRICH, and PUBLISH. It runs the whole programmatic
chain (~2s, free), regenerates the comprehensive report from cached verdicts, and
prints **FRESH** or the exact pending agent work — never a vague "run some agents."
Re-runs are cheap: every agent pass (research, consistency, issues) is content-hash
cached, so unchanged files are never re-judged. (RELATE — co-change + task triage —
is partially wired in but not yet surfaced as a separate arc in the status board.)

| Flag | Effect |
|---|---|
| *(none)* | full chain; publishes to Barkpark only with `--publish` |
| `--no-coverage` | skip the heavy `go test` / `mix test` suites (real defect-mining + reach still run) |
| `--skip-elixir` | use the regex resolver on hosts without the Elixir toolchain |
| `--publish` | also ship the graph into the isolated `codebase` dataset |

Open `tooling/quality/quality-report.html` for the rendered scorecard, or
`tooling/status/status-report.html` for the full 13-dimension board.

---

## The standing loop (CI)

Scoring is a **loop, not a one-shot**. `.github/workflows/codebase-intel.yml`:

- **calibrate** — on every release: re-runs the chain and re-fits the scoring
  weights against the codebase's own defect history, then appends one line to
  `tooling/fit/auc-history.jsonl` so **AUC is tracked over time** as incident
  history grows. (Current full-sample AUC ≈ **0.86**; temporal hold-out (CV) AUC ≈ **0.74**.)
- **drift-guard** — weekly: runs the cheap chain and surfaces a stale research /
  consistency ledger in the job summary. Never blocks.

Both run coverage-free — no Postgres or test DB needed.

## Verification — multi-vote

The judgments that move a composite (file criticality) can be **multi-voted**:
dispatch the batch K times into `results/vote-1/ … vote-K/`. The merge consensus's
the votes (median + agreement, `lib/consensus.mjs`) and flags a **contested**
judgment the panel disagreed on — surfaced for review, never silently averaged.
Flat `results/` = one vote, exactly as before.

---

## Directory map

| Dir | What it answers | Entry |
|---|---|---|
| `research-coverage/` | Is every file currently evaluated? What changed? | `coverage.mjs scan` |
| `blast-radius/` | What does this change affect? Did it touch the wire contract? | `check.mjs` (pre-push) |
| `file-importance/` | How important is each file? | `build-signals.mjs` → agents → `merge.mjs` |
| `usefulness/` | How depended-on is each file (reach), and why reusable? | `usefulness.mjs merge` |
| `ergonomics/` | Which files are too bloated to work in efficiently? | `ergonomics.mjs` |
| `risk/` | Is important code tested? Where do bugs actually land? | `risk.mjs` |
| `consistency/` | Do we follow a style? Where do we break it? | `consistency.mjs scan` |
| `intentions/` | What objectives does each file serve? (2nd edge type) | `review.mjs` → tag → `merge` |
| `cochange/` | Which files change together — real, aspirational, or accidental? | `cochange.mjs` |
| `combined/` | What's both important *and* inconsistent? | `combine.mjs` |
| `fit/` | What weights/forms do the composites use? | `fit.mjs` → `scoring-config.json` |
| `quality/` | How good is the codebase? What do we fix first? | `quality.mjs` |
| `aesthetics/` | Is the *filebase* clean — root clutter, tracked build artifacts, dead docs/tasks, YAGNI orphans? | `aesthetics.mjs` |
| `tasks/` | How does work relate to code? What open work is highest-leverage? | `tasks.mjs [triage\|publish]` |
| `scope/` | What's the file set for this task — context pack, no crawl? | `scope.mjs <intention\|task>` |
| `barkpark-sync/` | Publish every file as an interconnected Barkpark paper | `generate.mjs` → `push.mjs` → `graph-view.mjs` |
| `status/` | **the entry point** — full report, incremental | `status.mjs` |
| `lib/` | shared engines — `scoring.mjs` (composites), `consensus.mjs` (multi-vote) | — |

---

## What's real vs. what's a proxy

Be honest about the edges, because the system is:

- **Coverage is REAL** where a suite runs — Go (`go test -cover`), Elixir (`mix
  test --cover`), and JS (vitest `coverage-final.json`, ingested free even under
  `--no-coverage`). It falls back to a sibling-test *presence proxy* elsewhere.
- **The Elixir dependency graph is warm.** `build-index.mjs` auto-compiles when
  `api/_build` is absent, so `mix xref` yields the dense module graph (~286 files)
  on a fresh clone and in CI — not contingent on a manual `mix compile`. JS/Go
  edges remain best-effort.
- **Defect history is git-subject mining** — only as good as commit hygiene.
- **Task triage is a heuristic** until more work carries the `(task-id)` commit
  convention; it sharpens as that history grows.

## Safety

Code papers live **only** in the isolated `codebase` dataset. `push.mjs` defaults
to `codebase` and **refuses `--dataset production`** (exit 2) — production is never
polluted with per-file papers.

---

## Design invariants

- **Programmatic first.** Dependency graphs, hashing, churn, naming, layering,
  duplication — computed exactly and freely. An LLM is never asked to do what a
  parser does perfectly.
- **Agents on drift only.** Content hashes gate every agent call; a clean re-run
  costs zero tokens; a one-file change re-researches one file.
- **One root, one owner.** Each signal is measured once; composites combine roots
  only across passes, so nothing double-counts.
- **Blend, don't assert.** Final scores anchor an objective prior with agent
  judgment and *calibrated* weights — correct, auditable, and learned from history.

Orchestrated by the **`codebase-quality`** skill (`.claude/skills/`). All derived
outputs (ledgers, indexes, charts, reports, batches, results, `nodes.json`) are
gitignored — regenerate, never commit; the one exception is the tracked AUC ledger.
Agent fan-out uses the `Workflow` tool. See each pass's `README` / `config.json`,
and `SIGNALS.md` for the canonical root definitions.
