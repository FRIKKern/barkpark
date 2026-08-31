---
name: codebase-quality
description: Use when the user asks "how good is the codebase", "what's the code quality", "what should we improve / refactor", "where's our technical debt", "score the repo", "audit the codebase", "build the codebase knowledge graph", "what is each file for / how important / how useful", "what intentions / goals does the code serve", "what open work is highest-leverage", or "publish the codebase into Barkpark". Four arcs: ASSESS (13-dimension quality scorecard + ROI improvement plan), ENRICH (per-file importance, reach+why, intentions, ownership, git history), PUBLISH (one Barkpark paper per file, typed references, interconnected graph), RELATE (co-change + tasks as a third graph layer, plus triage of open work by predicted impact). Programmatic scans measure for free; agents are spent only on judgment a parser can't make, and only on what changed. Lives in tooling/.
---

# Codebase Quality & Knowledge Graph

Four arcs over one codebase: **ASSESS** how good it is (scorecard + plan),
**ENRICH** every file with metadata a parser can't produce (importance, reach,
intentions, ownership, git history), **PUBLISH** it all into Barkpark as an
interconnected graph of papers, and **RELATE** — co-change + Barkpark tasks
layered onto that graph (triage, churn provenance). Each arc reuses the same
outputs; run only what you need.

## The doctrine (the whole point)

1. **Programmatic first.** Graphs, hashing, churn, file size, layering, cycles,
   duplication, git mining — computed exactly and for free. An LLM is never asked
   to do what a parser does perfectly.
2. **Agents only on judgment, only on drift.** Content hashes gate every agent
   call; a clean re-run costs zero tokens; one changed file re-evaluates one file.
3. **Measure each root signal ONCE; compose only ACROSS roots (v2).** The nine
   canonical roots (reach · churn · complexity · defects · tests · conventions ·
   ownership · relationships · filebase — see `tooling/SIGNALS.md`) are each owned by exactly
   one pass. Composites (hotspot, priority, refactor-worth, critical-untested) read
   clean roots from `scoring-config.json` — no root reaches a composite twice.
4. **VERIFY before you trust.** Findings (layering, dup, drift) are adversarially
   judged before they drive the plan. The composite-driving judgment — file
   **criticality** — can be **multi-voted**: dispatch the batch K times into
   `results/vote-1/ … vote-K/`; `file-importance/merge` consensus's the votes
   (median + agreement, `tooling/lib/consensus.mjs`) and flags a `contested`
   judgment the panel disagreed on instead of silently averaging it (cqv3-p2). Flat
   `results/` = one vote, exactly as before. The same lib exposes
   `categoricalConsensus` for the consistency-drift verdicts (the wiring point when
   those judgments need hardening too).
5. **Reach-weight everything.** `reach` (normalized transitive dependents) is the
   single value root — a problem in a high-reach file outranks the same in a leaf.
   The old `usefulness` "value axis" is gone; its agent prose survives as a `why`
   description, not a score.

`tooling/` has one Node script (no deps) per pass; all derived outputs (ledgers,
indexes, reports, batches, results, nodes.json) are gitignored — regenerate,
never commit. Agent fan-out uses the `Workflow` tool, Opus (operator model policy: never Sonnet/Haiku), ~10 files/batch,
each agent seeded with pre-computed signals.

---

## ARC 1 — ASSESS (quality scorecard + improvement plan)

One command runs the whole programmatic chain (~2s, free), regenerates the report
from cached verdicts, and prints **FRESH** or the exact pending agent work:
```
node tooling/status/status.mjs
```
- **FRESH** → report the grade, the dimensions (Evaluated, Consistency,
  Architecture, **Hotspots** churn×complexity, Modularity, Tested, Reliability,
  Duplication, Dead-code), and the four composite worklists — **Priority** (reach ×
  severity × defect × untested), **Hotspot map** (churn × complexity),
  **Critical-untested** (reach × ¬coverage), **Refactor-worth** (bloat × churn ×
  separability). Open `tooling/quality/quality-report.html`.
- **PENDING** → do only the listed agent work, then re-run `status.mjs`:
  - *coverage drift* → `research-coverage/coverage.mjs prune && … batches` → dispatch
    `batch-count.txt` Opus agents (read each file, write `results/batch-NNN.json`
    `[{path,role,description,score,what_breaks_if_wrong,confidence}]`) → `… record`.
  - *consistency groups changed* → dispatch one agent per `consistency/batches/*.json`
    (write `consistency/results/<slug>.json` `{dir, canonical_pattern, verdicts:[{file,
    verdict:"drift"|"intentional"|"refactor", recommendation}]}`) → `consistency.mjs record`.
  - *issues stale* → 2 agents judge layering (`violation`|`acceptable`) + dup
    (`extract`|`acceptable`) → `_layering.json`/`_dup.json` → `consistency.mjs record`.
  - *multi-vote (optional, cqv3-p2)* → to harden the file-criticality judgment,
    dispatch the SAME `file-importance` batch K times (K=3 typical) writing to
    `results/vote-1/ … vote-K/` instead of flat `results/`. `file-importance/merge`
    consensus's the numeric votes (median + agreement) via
    `tooling/lib/consensus.mjs` and marks `contested` rows (tier `contested`) for
    review. Spend the extra votes only on the judgments that actually move a composite.

`status.mjs` is the single all-arcs entry — it chains the whole programmatic
pipeline: ARC 1 (`blast-radius/build-index`, `file-importance/build-signals`,
`ergonomics`, `risk`, `consistency scan+batches+merge`, `research-coverage scan`,
`combined`, `quality`, `report`), the ARC 2 enrich merges (`usefulness merge`,
`intentions merge`), ARC 4 (`cochange`), and ARC 3 `generate` — with `push` +
`graph-view` run only on `--publish` (and only when Barkpark is reachable). Pass
`--no-coverage` to skip the heavy go/mix suites (proxy test everywhere; real
defect-mining + reach still run) and `--skip-elixir` to use the regex resolver on
hosts without the Elixir toolchain.

**Standing loop (CI, cqv3-p1).** `.github/workflows/codebase-intel.yml` runs the
calibration as a loop, not a one-shot: a **calibrate** job on every release re-runs
`status.mjs --no-coverage` → `fit.mjs`, appends one line to `tooling/fit/auc-history.jsonl`
(the one tracked, non-gitignored fit output) and uploads the calibrated config +
report, so AUC is tracked as incident history grows; a weekly **drift-guard** job
runs the cheap chain and surfaces ledger drift in the job summary (never blocks).
Both run coverage-free, so no Postgres/test DB is needed.

---

## ARC 2 — ENRICH (per-file knowledge layer)

Build the per-file metadata that powers the graph + agent-efficiency use. Each is
content-hash friendly; re-run only when files changed.

**Importance** — `blast-radius/build-index` + `file-importance/build-signals 10`
→ agents per `file-importance/batches/*` (write `{path,role,description,criticality,
what_breaks_if_wrong}`) → `file-importance/merge.mjs`. (The coverage ledger also
carries importance, so this is optional once `status.mjs` has run.)

**Reach (+ why)** — the single value root (v2). `reach` is now PURE programmatic:
a normalized (0–100) transitive-dependent count computed by the merge — no agent
produces the number. The agent `why_useful` prose is kept as a `why` *description*
(graded reusability), never a score:
```
node tooling/usefulness/usefulness.mjs batches      # prior from transitive-dependent reach
# (optional) dispatch agents → results/batch-NNN.json [{path,why_useful}]  — DESCRIPTION only
node tooling/usefulness/usefulness.mjs merge         # computes reach + folds why → usefulness-report.json
```

**Ownership** — bus-factor, programmatic + free (one `git log` pass in `risk.mjs`):
`primaryAuthorShare` (top author's % of commits) + `authorCount`. No agent step.

**Intentions** — the objectives each file advances (a second edge type linking
cross-cutting files). Derive the taxonomy from THREE grounded sources, then tag:
```
node tooling/intentions/intentions.mjs digest        # corpus for taxonomy
node tooling/intentions/review.mjs subsystems        # partition for code review
# Workflow DISCOVER: ~62 agents read each subsystem's real code + 1 agent mines
#   git-digest.txt (build it: git log scopes+subjects) + fold in the user's stated
#   session goals → CANONICALIZE (high-effort agent) → writes taxonomy.json
node tooling/intentions/intentions.mjs batches        # then dispatch ~66 tag agents
#   → results/batch-NNN.json [{path,intentions:[taxonomy-id]}]
node tooling/intentions/intentions.mjs merge          # → intentions-report.json {taxonomy,files,hubs}
```

**Git history** — no separate step; `generate.mjs` (Arc 3) computes per-file
commits/authors/dates in one `git log` pass.

---

## ARC 3 — PUBLISH (into Barkpark as an interconnected graph)

**Which Barkpark?** Every script (`push`, `graph-view`, `tasks`, `cody`) resolves
its target through `tooling/lib/barkpark-env.mjs`: `--host` flag > `BARKPARK_*`
env > repo-root `barkpark.json` > `localhost:4000`, with a `/v1/capabilities`
probe and a local→public fallover (so a down local server falls back to the
project's public host declared in `barkpark.json`). Each prints a one-line banner
of where it bound. `barkpark.json` is committed and **secret-free** — tokens live
in env, never there.

**Cody** (`tooling/cody/cody.mjs` — bound variables, code↔paper) gates on this:
`cody preflight` reports host + full-intelligence freshness (scanned + coverage ≥
`barkpark.json:intelligence.minCoveragePct` + no pending agent work + no drift)
and exits non-zero when stale. `apply`/`watch` (which rewrite source) **block** on
a non-green preflight (`--force` overrides); `scan`/`status`/`set` only warn.

Requires a running Barkpark with the **dataset-aware paper reader** (route
`/d/:dataset/papers/:slug`, ingest `dataset` param) and **field-typed content
edges** — both features shipped in `api/`. One paper per file in an isolated
`codebase` dataset (production untouched).
```
node tooling/barkpark-sync/generate.mjs              # → nodes.json: every file with all
#   axes (importance, usefulness+why, test/defect, size, consistency), content, git
#   history, dependency edges + intention edges + the intention HUB nodes
node tooling/barkpark-sync/push.mjs --dataset codebase
#   registers the paper schema (incl. typed `dependencies`+`intentions` ref fields),
#   creates+publishes papers, sets TYPED references, ingests content blocks.
#   SAFETY: push.mjs defaults to `codebase` and REFUSES `--dataset production`
#   (exit 2) — code papers must never leak into production (cqv3 hardening).
node tooling/barkpark-sync/graph-view.mjs --dataset codebase   # interactive graph HTML
```
View: papers at `http://localhost:4000/d/codebase/papers/<slug>` (source +
metrics + usefulness + intentions + deps both directions + git history); graph at
`/v1/graph?dataset=codebase` (edges typed `dependencies` vs `intentions`) and the
`codebase-graph.html` (toggle: All / Dependencies / Intentions, click a node →
its paper). Re-push registers the schema first (the content-edge extractor needs
it). The `dependencies` field on each doc is the inverse-correct dependents source.

---

## ARC 4 — RELATE (relationship layers + tasks)

Two more relationship layers beyond dependencies, plus a third node type — all
free git-mining + joins of the existing reports.

**Co-change** — `tooling/cochange/cochange.mjs`: one git pass → the temporal-
coupling matrix (files that commit together). Then cross-validates the THREE edge
types — dependency × intention × co-change: agree → **real** relationship ·
intention-only → **aspirational** (intended, not enacted) · co-change-only →
**accidental** coupling (a smell). Per-file `accidentalCoupling` flag.

**Tasks** — `tooling/tasks/tasks.mjs`: blends Barkpark tasks in as a THIRD graph
node-type. A task inherits the intentions of the files its commits changed (the
`(task-id)` commit-message convention is the join key) → links `task → file` and
`task → intention`. Cross-validates PREDICTED scope (`scope`) vs ACTUAL (git) →
on-target / scoped-untouched / scope-creep (graph-node files only); rolls child
commits up to the parent epic; computes impact (Σreach) + a fragile flag.

Three forward-looking signals on top (cqv3-p4):
- **Triage** (`tasks.mjs triage`) — ranks OPEN tasks by predicted impact (Σ of the
  `priority` composite) × `defectRisk`. Committed tasks scope precisely from their
  files; unstarted ones scope by matching the title against the intention taxonomy
  (`predictedVia: commits|title|none`) so even fresh work can be ordered.
- **Churn provenance** — `report.provenance`: for each top hotspot file, the author
  who owns the most churn + their share (bus-factor / review blind-spot signal).
- **Calibration-on-tasks** — per-task `defectRisk` (Σ defect-amp over the files it
  will touch). A HEURISTIC composite, not a trained model — too few closed tasks to
  fit yet; it sharpens as `(task-id)` history grows.
```
node tooling/cochange/cochange.mjs        # co-change matrix + 3-way cross-validation
node tooling/tasks/tasks.mjs              # task↔file↔intention + predicted-vs-actual scope
node tooling/tasks/tasks.mjs triage       # rank OPEN work by predicted impact × defect-risk
node tooling/tasks/tasks.mjs publish      # add task nodes to the codebase graph
```

## Reading the output

- **Scorecard** = where the codebase stands; a low dimension is the headline.
- **Improvement plan** = what to fix, top-down by impact (reach × severity ×
  defect-amplifier); a file under multiple kinds is the highest-leverage target.
- **Per-file paper** = a complete briefing: source + importance + reach/why +
  intentions + dependencies (both directions) + git history. This is the
  metadata-first context pack that lets an agent understand a file without
  re-deriving anything (see **Delivery — `scope`** below for how to consume it).
- **Graph** = three relationship layers — dependency (code structure), intention
  (shared goals, linking files that don't import each other), and co-change
  (temporal coupling) — cross-validated; plus **tasks** as a third node type
  (work → files/intentions), so the graph shows goals, code, *and* the work moving them.

## Delivery — `scope` (exploration → lookup)

The `scope` capability turns a task or intention into a **scoped context pack** so
an agent reads metadata instead of crawling the tree:
```
node tooling/scope/scope.mjs <intention-id>          # e.g. layered-auth
node tooling/scope/scope.mjs "harden auth scoping"   # free-text task → best intention(s)
node tooling/scope/scope.mjs --list                  # every intention + member count
node tooling/scope/scope.mjs <task> --json --top 40  # machine-readable, capped
```
The pack lists the files advancing the matched intention(s), ranked by **reach**,
each with its one-line role/why + reach + blast-radius + deps **both directions**.
Reads `tooling/barkpark-sync/nodes.json`. See the `scope` skill. The same data is
also queryable via the Barkpark graph/search or the per-file papers.

## Honest limits (state these with the report)

- Snapshot — the cache keeps it live; the weekly **drift-guard** CI job
  (`codebase-intel.yml`) now surfaces a stale ledger instead of letting it rot.
- Agent judgments are single-vote BY DEFAULT but can be **multi-voted** on demand
  (`results/vote-*/` → consensus + `contested` flag, `tooling/lib/consensus.mjs`,
  cqv3-p2). Spend the votes only on judgments that move a composite.
- Scoring weights + composite forms live in `tooling/fit/scoring-config.json` (read
  by `tooling/lib/scoring.mjs`); when unfitted it falls back to defaults. The
  **calibrate** CI job re-fits on every release and tracks AUC over time in
  `tooling/fit/auc-history.jsonl` (cqv3-p1). Effort estimates are calibrated
  heuristics — trust ranking/tiers over the exact integer.
- **Tested is REAL where a suite runs** (Go `go test -cover`, Elixir `mix test
  --cover`, JS via vitest `coverage-final.json`); a presence PROXY elsewhere. The
  JS line-coverage ingest is free (reads existing `coverage-final.json`) and runs
  even under `--no-coverage`; CI emits it as the `js-coverage` artifact (cqv3-p3).
- Defect-history is git-subject mining — only as good as commit hygiene.
- The file-level **dependency graph is sparse for JS/Go** (best-effort resolver),
  but **Elixir is now warm**: `build-index.mjs` auto-compiles when `api/_build` is
  absent, so `mix xref` yields the dense module graph (~286 files) on a fresh clone
  and in CI — no longer contingent on a manual `mix compile` (cqv3-p3).

See `tooling/README.md` for the suite map.
