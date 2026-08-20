# E11 — frozen accessibility and cross-reader convergence gate

E11 does not select or refine a winner. Round 3 produced no candidate that
cleared the frozen E03 hard gates: E08 rejected all three Round-2 candidates,
and E09 explicitly recorded `winner_selected: false`. E05 is retained only as
the strongest non-rejected candidate in E09's migration/evidence-truth lens;
it is not a convergence winner.

This packet freezes the consequence instead of proxy-passing inaccessible
readers:

- `accessibility-fixtures.json` hashes all 36 frozen E03 fixtures and declares
  the semantic, silent-fallback, and narrow-width assertions required for a
  future candidate.
- `five-surface-goldens.json` reconciles the required 180 cells and records
  zero accepted goldens because no Round-3 winner exists and four real reader
  surfaces lack candidate-specific evidence.
- `explicit-degradation.json` makes supported-error and long-token behavior
  testable rather than allowing silent blanks or clipping.
- `next-three-assignments.json` is the exact complete-three experiment round
  required before convergence can be reconsidered.
- `result.json` is the machine-readable `REWORK/NO_WINNER` verdict.

Replay the frozen gate:

```bash
bash .omx/state/legendary-experiments/E11/run.sh
```

Expected final line: `E11 VERIFY PASS — REWORK/NO_WINNER`.
