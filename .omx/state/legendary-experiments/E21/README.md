<!-- doc-tier: human | canonical-for: legendary-e21-pre-seal-decision | budget: 900tok -->
# E21 — sealed blind decision dependency gate

E21 is the immutable round-06 decision gate after E19 and E20. It reconciles
all 180 expected reader cells (108 from E19 and 72 from E20) without promoting
blocked attempts, proxy evidence, or evidence from earlier experiments.

The upstream dependencies are both `BLOCKED` with zero accepted
candidate-specific real-reader captures. E21 therefore stops before blind
sealing or scoring, records `BLOCKED/REWORK`, selects no winner, authorizes no
pilot, and performs no production mutation.

Run the deterministic two-replay verification:

```bash
.omx/state/legendary-experiments/E21/scripts/replay.sh
```

Expected final line:

```text
E21 VERIFY PASS verdict=BLOCKED/REWORK cells=180 accepted=0 adversarial=6/6 quarantined=180/180 winner=false pilot=false seal=false scoring=false
```
