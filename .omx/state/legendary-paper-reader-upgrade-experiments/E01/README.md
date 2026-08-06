# E01 — canonical losslessness/structure baseline

Round 1 baseline only. This artifact freezes the four revision-pinned published Papers, real CLI/API/source/public/email/TUI80 captures, dimension controls, known-bad targets, adversarial fixtures, hard denominators, and a failure taxonomy. It does not build or choose a repair candidate and does not mutate a Paper, task, Cycle result, or product source.

Reproduce from the repository root:

```sh
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E01/scripts/build_baseline.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E01/scripts/verify.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E01/scripts/verify.py
```

The builder fails closed if any published revision differs from the assignment pin. The verifier is read-only and idempotent. Its two outputs must have the same `artifact_set_sha256`.

Observed facts live in `reports/census.json`, `reports/reader-probes.json`, and `reports/failure-taxonomy.json`. Preferences are explicitly separated and E01 selects no format. Timing is observational and excluded from the stable artifact-set hash.
