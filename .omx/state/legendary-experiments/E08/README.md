# E08 — canonical Round-3 hostile-content attack

Read-only attack of the frozen E04, E05, and E06 candidates with the six E03
adversarial fixtures and thresholds. The harness never calls Barkpark APIs and
never mutates candidate, product, or production data.

Replay:

```sh
.omx/state/legendary-experiments/E08/scripts/run.sh
```

Expected terminal line: `E08 VERIFY PASS`. `result.json` is the explicit
candidate-by-candidate verdict. Authenticated Studio, real-client email, and
real narrow-reader evidence remain capability blocks rather than proxy passes.
