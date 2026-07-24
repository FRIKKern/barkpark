<!-- doc-tier: agent | canonical-for: epic-memory-design | budget: 6000tok -->
# Epic Memory — journeys, telemetry, premium debrief (design)

Approved 2026-07-24. Alignment paper (proof of intent, component dry-run):
`https://guerrilla.barkpark.cloud/papers/epic-memory-design-alignment-2026-07-24`

## Vision

The epic cycle becomes a system that remembers. Every agent returns a
compelling journey; every wave folds those journeys into ONE beautiful wave
Paper (no dossiers, no per-agent papers); a standalone debrief agent can run
days later and compose the whole epic into a premium PortableDoc read —
narrative arc, numbers, friction, and how to run the process cheaper.

Forcing constraint: the debrief may run days after the last wave, when the
workflow run's session files are gone. If a fact is not in a Paper, the
ledger, the charter, or git, it does not exist.

## Decisions

- D1 **Journey field, required, every agent.** Surveyors, verifiers, builders
  and each Fable phase return `journey`: mission (one line), 2–5 key moments
  (turning point/surprise WITH the evidence that caused it), outcome, meaning.
  Written for a human reader, not a log.
- D2 **The wave Paper is the only per-wave artifact and is beautiful by
  contract.** Fable phases compose journeys with real components: journey
  cards per surveyor (Digest), decisions as callouts + proofs as terminal
  blocks + facts table with rerun commands (Decide), builder journeys +
  telemetry + retro (Review). Curation rule: keep turning points, surprises,
  refuted premises, real output; drop boilerplate. Workers still never write
  the shared Paper.
- D3 **No per-surveyor papers, no machine-tier dossiers.** (Earlier idea
  explicitly rejected: papers out of the process must be beautiful.)
- D4 **Verify-don't-re-research.** Strategist's first act every wave (not just
  founding): `bp search` prior wave Papers; questions already answered become
  drift-check missions — re-run the stored `rerun` commands, report
  confirmed/drifted per fact, link the prior Paper, spend fresh effort on the
  delta only.
- D5 **Doc-fact routing stays bounded.** Decide routes the few genuinely
  durable repo-facts into their owning docs/ card per the routing table,
  within byte budgets (doc gates already run on Decide's charter commit).
  Doesn't fit → backlog task instead. Never additive research dumps.
- D6 **Wave telemetry captured in-script, persisted by Review.** Tokens:
  `budget.spent()` sampled at phase boundaries → per-phase deltas (the honest
  grain; per-agent splits are not exposed). Wall-clock: Fable phases stamp
  `date -u` start/end; wave start via `args` (Date.now() is banned in
  scripts). Wave start is measured as the strategist's started_at — the
  strategist IS the wave's first act (deliberate narrowing of the earlier
  'via args' idea). Fleet shape: script counts. Interrupts: `agent()` nulls,
  builder BLOCKED reports, gate failures, resumed runs — attributed per phase.
  Review renders stats + a per-phase table in the Paper. Review's own token
  delta exists only in the run's return value (Review cannot know its cost
  before writing the Paper) — the LEAD pastes the returned telemetry into the
  charter wave-log entry when cross-wave Review-cost trends matter.
- D7 **Process retro with teeth.** Review writes one honest efficiency verdict
  per phase, each tied to a telemetry row or a journey moment (wasted
  surveys, duplicate verifies, builders burned on BLOCKED).
- D8 **Epic debrief = standalone skill, one Fable author agent.** Input: epic
  task id. Reads charter + every wave Paper + ledger + git history. Output:
  one premium debrief Paper — stage/pipeline arc, stat-grid numbers, roadmap
  shipped-vs-deferred, callouts for shaping decisions, terminal proof moments,
  task-board refs, cross-wave telemetry trends, top-3 process changes argued
  from evidence (optionally filed as bp backlog tasks).
- D9 **Honesty rule for telemetry.** Record what was measured at the grain it
  was measured; never invent precision.

## Component vocabulary (confirmed against api/lib/barkpark/portable_doc/render/)

eyebrow · byline · ingress · heading · paragraph · list · callout · note ·
pullquote · divider · table · sheet · stat/stats/stat-grid · gauge-list ·
chart · heatmap · diagram (mermaid) · pipeline · stage · steps · roadmap ·
cards/card · tabs · columns · expandable · toc · code · terminal ·
task-board/task-detail/task-list · status-legend.

## Touch points

- `.claude/workflows/bp-epic-cycle.workflow.js` — schemas (journey), prompts
  (PAPER_BLOCK beauty contract, strategist search-first, Digest roster,
  Decide doc-routing, Review telemetry+retro), script (budget sampling,
  interrupt counters, telemetry interpolation into Review prompt).
- New skill: epic debrief author (`.claude/skills/` or plugin layout — see plan).

## Wave log

2026-07-24 — D1–D9 implemented on feat/epic-memory-journeys-debrief (journey schemas+tripwire, drift-checks, clock stamps, beauty contract, telemetry+retro, doc routing, meta refresh, bp-epic-debrief skill). Authoritative gate: module-scope smoke harness (see plan Global Constraints); parse-only node --check is a false negative on this file.
