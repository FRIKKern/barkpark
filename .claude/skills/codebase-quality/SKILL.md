---
name: codebase-quality
description: Use when the user asks "how good is the codebase", "what's the code quality", "what should we improve / refactor", "where's our technical debt", "score the repo", "audit the codebase", "build the codebase knowledge graph", "what is each file for / how important / how useful", "what intentions / goals does the code serve", or "publish the codebase into Barkpark". Three arcs: ASSESS (8-dimension quality scorecard + ROI improvement plan), ENRICH (per-file importance, usefulness+why, intentions, git history), PUBLISH (one Barkpark paper per file, typed references, interconnected graph). Programmatic scans measure for free; agents are spent only on judgment a parser can't make, and only on what changed. Lives in tooling/.
---

# Codebase Quality & Knowledge Graph

Three arcs over one codebase: **ASSESS** how good it is (scorecard + plan),
**ENRICH** every file with metadata a parser can't produce (importance,
usefulness, intentions, git history), and **PUBLISH** it all into Barkpark as an
interconnected graph of papers. Each arc reuses the same outputs; run only what
you need.

## The doctrine (the whole point)

1. **Programmatic first.** Graphs, hashing, churn, file size, layering, cycles,
   duplication, git mining — computed exactly and for free. An LLM is never asked
   to do what a parser does perfectly.
2. **Agents only on judgment, only on drift.** Content hashes gate every agent
   call; a clean re-run costs zero tokens; one changed file re-evaluates one file.
3. **Measure each root signal ONCE; compose only ACROSS roots (v2).** The eight
   canonical roots (reach · churn · complexity · defects · tests · conventions ·
   ownership · relationships — see `tooling/SIGNALS.md`) are each owned by exactly
   one pass. Composites (hotspot, priority, refactor-worth, critical-untested) read
   clean roots from `scoring-config.json` — no root reaches a composite twice.
4. **VERIFY before you trust.** Findings (layering, dup, drift) are adversarially
   judged before they drive the plan.
5. **Reach-weight everything.** `reach` (normalized transitive dependents) is the
   single value root — a problem in a high-reach file outranks the same in a leaf.
   The old `usefulness` "value axis" is gone; its agent prose survives as a `why`
   description, not a score.

`tooling/` has one Node script (no deps) per pass; all derived outputs (ledgers,
indexes, reports, batches, results, nodes.json) are gitignored — regenerate,
never commit. Agent fan-out uses the `Workflow` tool, Sonnet, ~10 files/batch,
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
    `batch-count.txt` Sonnet agents (read each file, write `results/batch-NNN.json`
    `[{path,role,description,score,what_breaks_if_wrong,confidence}]`) → `… record`.
  - *consistency groups changed* → dispatch one agent per `consistency/batches/*.json`
    (write `consistency/results/<slug>.json` `{dir, canonical_pattern, verdicts:[{file,
    verdict:"drift"|"intentional"|"refactor", recommendation}]}`) → `consistency.mjs record`.
  - *issues stale* → 2 agents judge layering (`violation`|`acceptable`) + dup
    (`extract`|`acceptable`) → `_layering.json`/`_dup.json` → `consistency.mjs record`.

`status.mjs` already chains: `blast-radius/build-index`, `file-importance/build-signals`,
`ergonomics/ergonomics`, `risk/risk`, `consistency scan+batches`, `combined/combine`,
`quality/quality`, `status/report`.

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
#   creates+publishes papers, sets TYPED references, ingests content blocks
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
```
node tooling/cochange/cochange.mjs        # co-change matrix + 3-way cross-validation
node tooling/tasks/tasks.mjs              # task↔file↔intention + predicted-vs-actual scope
node tooling/tasks/tasks.mjs publish      # add task nodes to the codebase graph
```

## Reading the output

- **Scorecard** = where the codebase stands; a low dimension is the headline.
- **Improvement plan** = what to fix, top-down by impact (reach × severity ×
  defect-amplifier); a file under multiple kinds is the highest-leverage target.
- **Per-file paper** = a complete briefing: source + importance + usefulness/why +
  intentions + dependencies (both directions) + git history. This is the
  metadata-first context pack that lets an agent understand a file without
  re-deriving anything (see agent-efficiency note below).
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

- Snapshot — the cache keeps it live, but a stale ledger weakens importance.
- Single-vote agent judgments (spot-check; not multi-voted by default).
- Scoring weights + composite forms live in `tooling/fit/scoring-config.json` (read
  by `tooling/lib/scoring.mjs`); when unfitted it falls back to defaults. Effort
  estimates are calibrated heuristics — trust ranking/tiers over the exact integer.
- **Tested is a PROXY** (sibling-test + module references), not line coverage.
- Defect-history is git-subject mining — only as good as commit hygiene.
- The file-level **dependency graph is sparse** (~35-47% of files) — the resolver is
  best-effort and **Elixir has no warm symbol graph** (no `mix xref`). Warming it
  is the lever for denser edges.

See `tooling/README.md` for the suite map.
