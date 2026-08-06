# E09 — hostile terminal and platform attack matrix

E09 attacks the three isolated Diverge candidates E04, E05, and E06. It does not deploy them, call production, mutate a Paper or Task, or induce a live failure. Unavailable interactive, authenticated, delivered-client, and transport cells are typed `BLOCKED`; static artifacts never proxy-pass those cells.

The runnable probe covers widths 20/40/80/120/1 over all four sealed Papers, terminal control bytes, interaction parity, state/history/Related/recovery, CLI/API discovery agreement, safe error and timeout behavior, conditional validators, request and identity carriers, full-content bounds, deterministic replay, timing, credential scanning, and a deterministic evidence archive.

Run from the worktree root:

```sh
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E09/scripts/replay.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E09/scripts/verify.py
```

Observed failures and blocks are evidence, not format preference. E09 does not choose a winner.
