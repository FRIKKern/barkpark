# E05 — preservation-first compatibility envelope

This isolated Round-2 candidate keeps the original payload as the sole authority and derives reader views, provenance, Task annotations, explicit supported errors, and rollback evidence around it. It never mutates product code, production data, the wave Paper, or authoritative Tasks.

## Replay

```bash
.omx/state/legendary-experiments/E05/scripts/replay.sh
```

Expected terminal line: `E05 REPLAY PASS`.

Ordinary replay is byte-stable. `outputs/timing.json` preserves the accepted measured timing evidence, while the current replay observation is written outside the repository to `$E05_VOLATILE_TIMING_PATH` (default: the system temporary directory). Set `E05_REFRESH_TIMING=1` only when intentionally replacing the committed timing evidence; that explicit maintenance mode is expected to create a reviewable diff.

The fixture bundle contains exact frozen E03 bytes: 12 Papers, 18 Tasks, and 6 adversarial fixtures. The candidate emits 36 envelopes and a 180-cell five-surface matrix. Authenticated Studio and real-client email remain `BLOCKED`; scratch output is not promoted to real-surface proof. Consequently the honest experiment verdict is `PARTIAL / REWORK`, and this candidate does not select itself as winner.

## Evidence

- `candidate.json` — fallback, authority, annotation, and rollback contract.
- `fixtures/manifest.json` — exact source membership and hashes.
- `outputs/envelopes.jsonl` — runnable candidate output.
- `outputs/rollback-manifest.json` — per-fixture pre-image restoration and residue check.
- `outputs/quarantine.json` — explicit malformed/empty-source containment.
- `outputs/surface-matrix.json` — 36 × 5 reader evidence cells.
- `outputs/scorecard.json` — all 13 frozen E03 thresholds.
- `outputs/hashes.json`, `outputs/timing.json`, `result.json` — replay hashes, timing, result contract, and verdict.
