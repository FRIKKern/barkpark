# E18 — deterministic canonical replay and fail-closed decision

E18 is the direct recovery record for the split OMX tasks 1 and 2. It does not
rerun real-surface probes, mutate frozen evidence, select a winner, or authorize
a pilot. It replays every file in the E16 and E17 output directories twice,
seals fixture-identity records before scoring, reconciles every E03 adversarial
fixture, and proves rollback/quarantine coverage.

Because E17 is `FAIL/REWORK` with zero accepted captures out of 180, E18 rejects
the candidate through the inherited hard-gate rule and returns `FAIL/REWORK`.

```bash
.omx/state/legendary-experiments/E18/scripts/replay.sh
```
