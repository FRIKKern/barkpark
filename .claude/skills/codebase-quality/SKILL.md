---
name: codebase-quality
description: Use when the user asks "how good is the codebase", "what's the code quality", "what should we improve / refactor", "where's our technical debt", "is this worth refactoring", "score the repo", "audit the codebase", or wants a quality assessment + a prioritized improvement plan. Produces a scored quality SCORECARD (6 dimensions, A-F grade) and an IMPROVEMENT PLAN ranked by ROI (impact ÷ effort). Programmatic scans do all the measuring for free; agents are spent only on judgment a parser can't make, and only on what changed. Lives in tooling/.
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

## The 6 quality dimensions

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

## Procedure

**1. Coverage gate (free; usually the whole job).**
```
node tooling/research-coverage/coverage.mjs scan
```
If `stale==0 && new==0`: the ledger is current — skip straight to step 5. Else research the drift:
`coverage.mjs prune && coverage.mjs batches` → dispatch `batch-count.txt` Sonnet agents (read each, write `results/batch-NNN.json` `[{path,role,description,score,what_breaks_if_wrong,confidence}]`) → `coverage.mjs record` → `coverage.mjs scan` (verify 100%). First run: `coverage.mjs seed` from a prior importance run, or treat all as new.

**2. Refresh the objective signals (free).**
```
node tooling/blast-radius/build-index.mjs --skip-elixir     # reverse-dep graph (fan-in, dead code)
node tooling/file-importance/build-signals.mjs 10            # priors + churn
node tooling/ergonomics/ergonomics.mjs                       # size-class + refactor_worth
node tooling/risk/risk.mjs                                   # test-presence proxy + defect history
```

**3. Consistency scan + judge (agents only on outliers/issues).**
```
node tooling/consistency/consistency.mjs scan
node tooling/consistency/consistency.mjs batches            # one task per outlier GROUP
```
Dispatch one Sonnet agent per `consistency/batches/group-NNN.json` → write `consistency/results/group-NNN.json` `{dir, canonical_pattern, verdicts:[{file, verdict:"drift"|"intentional"|"refactor", recommendation}]}`. Then `consistency.mjs merge`.

**4. Verify the architecture/dup issues (2 agents — critical, cheap).**
Dispatch 2 agents that read `consistency-report.json` and write:
- `consistency/results/_layering.json` `[{file, rule, verdict:"violation"|"acceptable", reason, fix}]` — judge each layering back-edge (real violation vs justified, e.g. the plugin route highway).
- `consistency/results/_dup.json` `[{a, b, verdict:"extract"|"acceptable", reason}]` — extract-worthy vs benign config boilerplate.

**5. Synthesize (free).**
```
node tooling/combined/combine.mjs        # importance × consistency worklist
node tooling/quality/quality.mjs         # → quality-report.{html,json}: scorecard + improvement plan
```
Report the grade, the dimension scores, and the top of the improvement plan (ranked by impact, with effort). Open `quality-report.html`.

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
