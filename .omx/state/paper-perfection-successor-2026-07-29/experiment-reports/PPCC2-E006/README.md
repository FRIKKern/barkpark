# PPCC2-E006 reader-adaptive candidate

This directory is the isolated Round 2 candidate owned by `worker-3`.

The candidate keeps the exact authored PortableDoc blocks as the canonical
record and derives an ordered semantic-node index once. Studio, TUI at 80 and
40 columns, email, and CLI/API are deterministic projections of that same
canonical candidate. No production Paper, CycleFleet record, root task, Wave
Paper, or repository source is mutated.

Run the complete nine-fixture experiment:

```bash
python3 candidate.py run \
  --assignment-map /Volumes/SATECHI/github/barkpark/.omx/state/paper-perfection-successor-2026-07-29/experiment-assignments.json \
  --output artifacts
```

Validate the implementation and generated artifacts:

```bash
python3 -m unittest -v test_candidate.py
python3 candidate.py verify --output artifacts
```

`artifacts/run-summary.json` contains the measured cross-surface results.
`report.json` is the durable assignment report. The report hash is intentionally
recorded outside the report itself to avoid a self-referential digest.
