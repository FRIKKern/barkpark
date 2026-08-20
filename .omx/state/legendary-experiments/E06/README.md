# E06 — Cohort-specific repair rails with quarantine

This is an isolated Round-2 candidate. It copies the frozen E03 fixtures and gate
contracts into `fixtures/` and `frozen/`, routes every Paper cohort and Task class
through exactly one explicit rail, and writes only inside this directory.

Run:

```sh
bash .omx/state/legendary-experiments/E06/run.sh
```

The candidate never mutates production or repository product/source files. Accepted
outputs are scratch documents. Quarantined inputs retain exact pre-images and hashes.
The three survey-only empty draft Papers (which have no E03 raw rows) and the three E03
`probe` Tasks carrying `retire` are explicit evidence-gated exclusions; they are not
deleted, silently padded, or assigned invented source hashes. Authenticated Studio, real-client email, and
reader/accessibility/width rendering remain `BLOCKED`, never `PASS`.

Replay timing is measured on every run and written to ignored scratch path
`.replay/timing.json`. The tracked `timing.json` records the evidence policy and the
representative Round-2 measurement, so canonical replay never rewrites tracked bytes.
Volatile timing is intentionally excluded from deterministic artifact hashes and from
`result.json`; `scripts/verify.py` still requires a positive fresh measurement.

`result.json` is the verdict. `PARTIAL/REWORK` records that the isolated rail mechanics
are runnable while frozen surface gates remain blocked; it is not a winner selection.
