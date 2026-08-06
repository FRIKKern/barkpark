# E03 — terminal/navigation/identity/discovery baseline

Independent Round-1 baseline for the four frozen Paper revisions. It captures TUI-equivalent ANSI256 and human NoColor projections at widths 20/40/80/120, machine CLI/API JSON, history/provenance, Paper schema, capabilities, source negotiation, and typed error behavior. It builds no repair candidate and performs no external writes.

```sh
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E03/scripts/build_baseline.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E03/scripts/verify.py
python3 .omx/state/legendary-paper-reader-upgrade-experiments/E03/scripts/verify.py
```

Observed facts, inferences, and preferences are separated in `reports/baseline.json`. Timing and verification records are excluded from the stable artifact-set hash.
