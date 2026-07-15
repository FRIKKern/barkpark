# Legendary Cycle experiment contract

Experiment before mass repair so hundreds of agents do not reproduce a weak format.

## Five rounds

| Round | Three independent assignments | Durable result |
| --- | --- | --- |
| 1. Baseline | measure current format on representative good, bad, and edge fixtures | baseline scores and failure taxonomy |
| 2. Diverge | build three materially different candidate formats | runnable candidates, not prose sketches |
| 3. Attack | test candidates on Studio, TUI, email, CLI/API, narrow widths, long content, missing fields, and malformed legacy data as applicable | failure matrix and rejected candidates |
| 4. Converge | independently refine the strongest candidate, accessibility behavior, and migration/idempotence behavior | one candidate plus frozen rubric |
| 5. Pilot | run three disjoint representative batches through the full proposed builder gate | chosen format, golden fixtures, capacity, time, and failure rate |

All 15 assignments are required and exact for one immutable wave. Further iteration requires a new wave and does not erase earlier evidence. Experiment assignments are rejected after the build-plan seal.

## Rubric

Declare measurable thresholds before Round 2. Include, where applicable:

- reader visibility and structural completeness;
- width/overflow behavior in TUI and email;
- PortableDoc or schema validity;
- accessibility semantics and reading order;
- idempotent reruns and preservation of authored content;
- render/test gate pass rate;
- time per unit and safe batch capacity;
- rollback or quarantine behavior.

Use real fixtures sampled from the numeric inventory. Include at least one known-good control, one known-bad example, and adversarial length/shape cases. A format cannot win when a declared target surface was not exercised.

## Boundaries

Experimenters may edit only their isolated candidate worktree or scratch artifact. They do not mutate production data, the wave Paper, or authoritative build tasks. The leader records results, selects the winner, and freezes golden fixtures.

If no candidate clears every hard threshold after the exact 15 assignments,
close the wave as unsuccessful and open a new immutable wave for renewed
Experiment and Pilot. Do not add a sixth round to the current wave or average
away a hard reader failure with higher scores elsewhere.
