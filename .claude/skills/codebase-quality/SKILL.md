---
name: codebase-quality
description: Use when the user asks "how good is the codebase", "what's the code quality", "what should we improve / refactor", "where's our technical debt", "is this worth refactoring", "score the repo", "audit the codebase", or wants a quality assessment + a prioritized improvement plan. Produces a scored quality SCORECARD (8 dimensions, A-F grade) and an IMPROVEMENT PLAN ranked by ROI (impact ÷ effort). Programmatic scans do all the measuring for free; agents are spent only on judgment a parser can't make, and only on what changed. Lives in tooling/.
---

# Codebase Quality

Answers two questions: **how good is this codebase**, and **what does it take to
make it better**. Output = a scored scorecard + an ROI-ranked improvement plan.

## The doctrine (the whole point)

1. **Programmatic first.** Dependency graphs, hashing, churn, file size, naming,
   layering, duplication, cycles — all computed exactly and for free. An LLM is
   never asked to do what a parser does perfectly.
2. **Agents only on judgment, only on drift.** Content hashes gate every agent
   call; a clean re-run costs zero tokens. Agents decide what a machine can't:
   is a deviation drift or intentional, is a layering hit real or the plugin
   highway, is duplication worth extracting.
3. **Anchor judgment with objective priors.** Importance = blend(fan-in/churn
   prior 45%, agent criticality 55%) — correct, calibrated, auditable.
4. **VERIFY before you trust.** Findings are adversarially judged before they
   drive the plan. (The layering pass overturned 4 of 9 candidates as false.)
5. **Importance-weight everything.** A problem in a critical file outranks the
   same problem in a leaf: impact = importance × severity.

## The 8 quality dimensions

| Dimension | Measures | Source |
|---|---|---|
| Evaluated | every file evaluated & current? | research-coverage ledger |
| Consistency | drift vs the group's own pattern (vs intentional) | consistency + agent verdicts |
| Architecture | layering back-edges (verified) · compile-DAG acyclic? | consistency + issue-judgment |
| Modularity | context-bloat: god-files read on every change | ergonomics (size × churn × defs) |
| Tested | do important files have test presence? (proxy) | risk (sibling test + module refs) |
| Reliability | where do bugs actually land? | risk (git bug-fix/revert mining) |
| Duplication | extract-worthy copy-paste (verified, not config) | consistency dup + agent verdicts |
| Dead code | unreferenced packages | blast-radius index |

Impact is amplified by defect-history: a finding on a file where bugs actually
land outranks the same finding on a stable file. The sharpest worklist entries
are **important × bloated × untested × defect-prone** at once.

`quality.mjs` blends these into an A–F grade and an improvement plan where each
finding carries `impact = importance × severity` and `effort` (refactor size).

## Procedure — the status-quo run

**Step 1 — one command (free, ~2s).** It runs the whole programmatic chain
(graph, signals, ergonomics, risk, consistency scan, coverage scan), regenerates
the comprehensive report from whatever verdicts are cached, and prints either
**FRESH** or the exact pending agent work. It is idempotent.
```
node tooling/status/status.mjs
```
- **FRESH** → done. Report the grade + 8 dimensions + top of the improvement plan;
  open `tooling/quality/quality-report.html`. **Zero agent tokens.**
- **PENDING** → do only the listed work below, then re-run `status.mjs` (→ FRESH).

**Step 2 — only the stale agent work (the incremental part).**
Each pass is content-hash cached, so you touch only what changed:

- **Coverage drift** (`N file(s) need research`):
  `coverage.mjs prune && coverage.mjs batches` → dispatch `batch-count.txt` Sonnet
  agents (read each `batches/batch-NNN.json`, write `results/batch-NNN.json`
  `[{path,role,description,score,what_breaks_if_wrong,confidence}]`) →
  `coverage.mjs record`. (First ever run: `coverage.mjs seed`, or treat all as new.)

- **Consistency groups changed** (`M group(s) changed`): dispatch one Sonnet agent
  per file in `consistency/batches/` (each reads `batches/<name>.json`, writes
  `consistency/results/<name>.json` `{dir, canonical_pattern, verdicts:[{file,
  verdict:"drift"|"intentional"|"refactor", recommendation}]}`) →
  `consistency.mjs record`. Unchanged groups are reused from `verdict-cache.json` —
  not re-judged.

- **Layering/dup findings changed** (`issues STALE`): dispatch 2 agents reading
  `consistency-report.json` → `consistency/results/_layering.json` `[{file, rule,
  verdict:"violation"|"acceptable", reason, fix}]` and `_dup.json` `[{a, b,
  verdict:"extract"|"acceptable", reason}]` → `consistency.mjs record`.

**Step 3 — re-run `status.mjs`.** It folds the new verdicts, regenerates the
report, and should now print **FRESH**.

The first ever run does the full fan-out (~hundreds of agents over every file);
every run after that is incremental — usually a handful of agents, often none.

## Reading the output

- **Scorecard** = where the codebase stands. A low dimension is the headline issue
  (e.g. Modularity 31 = god-files dominate; Architecture & Consistency strong).
- **Improvement plan** = what to do, top-down. Each row: impact, importance, kind,
  effort, target file, concrete action. `impact ÷ effort` is the ROI; the top is
  what to fix first. A file appearing under multiple kinds (e.g. content.ex as #1
  importance AND a bloat split) is the highest-leverage target.

## Honest limits (state these with the report)

- Snapshot — the cache keeps it live, but a stale ledger weakens importance.
- Single-vote agent judgments (spot-check; not adversarially multi-voted by default).
- Scoring weights and effort estimates are calibrated heuristics, not measurements —
  trust the ranking and tiers over the exact integer.
- **Tested is a PROXY** (sibling-test existence + module references in the suite),
  not line coverage. Real coverage (`go test -cover`, `mix test --cover`, vitest
  JSON) can be ingested into `risk.mjs` later for ground truth.
- Defect-history is git-subject mining — only as good as commit hygiene.

See `tooling/README.md` for the suite map.
