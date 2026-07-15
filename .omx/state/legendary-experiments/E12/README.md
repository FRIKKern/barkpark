# E12 — migration, preservation, idempotence, quarantine, and rollback convergence

E12 executes the canonical Round-4 migration convergence assignment against the frozen E03 thresholds and accepted E03–E09 evidence. It does not mutate production or source fixtures.

Round 3 produced no winner: E04 and E06 were rejected, while E05 is only the strongest non-rejected candidate and remains `BLOCKED_REWORK`. E12 therefore freezes a dry-run manifest and replayable proofs without promoting E05 to a winner.

Run the complete gate:

```bash
.omx/state/legendary-experiments/E12/run.sh
```

The gate deterministically rebuilds all JSON evidence twice, verifies 36 unique selection routes, 36 two-run semantic-hash proofs, 36 pre-image restorations, zero residue keys, and three caught failure injections. The committed `timing.json` is refreshed only with `E12_REFRESH_TIMING=1` so ordinary replay cannot make evidence bytes volatile.

Hard blocks remain explicit: zero of the required 20 sealed paired blind records exist, authenticated Studio evidence is unavailable, and real-client email evidence is unavailable. The verdict is `REWORK`; no winner is selected.

The exact next complete-three experiment requirement is frozen in `result.json`: E13 seals and attacks paired blind records, E14 exercises all real readers against all 36 fixtures, and E15 repeats migration convergence only after an eligible candidate exists. All E03 thresholds remain unchanged.
