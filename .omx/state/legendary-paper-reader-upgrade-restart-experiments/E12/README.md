# E12 — Converge rejection replay and replacement-wave contract

E12 independently replays the sealed E04–E06 terminal/platform rejection matrix and freezes an executable contract for a future authorized replacement wave. It does not refine or select a candidate, authorize Pilot, deploy code, call production, or mutate any Paper, Task, Cycle ledger, or campaign artifact.

Every required cell must be `PASS` for a future candidate to become eligible. `FAIL`, `BLOCKED`, missing, proxy, or static-only evidence is ineligible. The current candidates therefore have no winner.

Run from the worktree root:

```sh
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E12/scripts/replay.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E12/scripts/verify.py
```

Observations are recorded separately from preference. E12 records no preference.
