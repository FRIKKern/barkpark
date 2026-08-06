<!-- doc-tier: cold | canonical-for: legendary-paper-cycle-restart-2026-08-06 | budget: 1500tok -->
# Legendary Paper Cycle — immutable restart ruling

The original Cycle wave `legendary-paper-reader-upgrade-wave-2026-08-05` is historical evidence, but it cannot become a sealed Legendary wave. Its immutable revision is `a06716c4-2dd5-4bda-b9a9-a484b009abb2`; its 20-unit inventory digest is `3e480a9fcf44da65a07aa1fcad8e981911006568d23b89ad8891f26a5d96e69e`.

Survey completed 60/60 and Verify completed 30/30. Baseline experiments E01–E03 are committed, independently replayed, and useful. Their terminal Cycle result payloads nevertheless encoded `"round": 1` without the required canonical `round_name` or `round_key`. The server therefore records three completed Experiment assignments while correctly projecting `experiment.round_counts.baseline = 0`. Terminal results are append-only and a conflicting replacement is refused.

The ruling is deliberately narrow:

- keep the Survey, Verify, and E01–E03 artifacts as valid historical evidence;
- do not describe the original wave as sealed or sealable;
- do not weaken `Barkpark.CycleFleet.canonical_experiment_round`;
- do not mutate database history or overwrite terminal results;
- do not advance to Diverge until the current live authority reports Baseline 3/3.

The current authority is the fresh standard wave `legendary-paper-reader-upgrade-wave-2026-08-06-restart`, revision `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`, under epic `task-a768c69e659add58`. It freezes the same set of 20 Paper-reader unit IDs. The restart sorted those IDs, so its inventory digest is truthfully different: `227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc`. Same set does not mean byte-identical inventory record.

Because this is a standard Legendary wave rather than a correction projection, it must satisfy its own complete fleet: Survey 60, Verify 30, Experiment 15, computed Build at least 15, and Review 15. Existing artifacts may inform the work, but new assignments must make a fresh decision-relevant attestation rather than replaying duplicate prompts.

The restart Survey uses three distinct lenses for each immutable unit:

1. provenance and current revision/hash chain;
2. live reader regression against the frozen Round-1 gates;
3. negative capability, blocked-reader, and evidence-strength audit.

Experiment results in the restart use canonical string round names: `baseline`, `diverge`, `attack`, `converge`, and `pilot`. The leader reads back the live Cycle ledger after every round; a round advances only when its live count is exactly 3 with zero invalid results.

Reader-visible disclosure is published in Paper `legendary-paper-reader-upgrade-sweep-2026-08-03`, revision `7805eb5b2b6db1fa0ff0b64b2b594e17`. Both canonical `blocks` and `body.blocks` contain 43 blocks and project the restart wave revision, inventory digest, and 0/135 opening fleet state.
