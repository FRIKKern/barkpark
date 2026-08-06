# Restart Experiment 02 — human-reader baseline

This directory is the isolated, read-only Round-1 baseline for public, Studio,
and email behavior across the four frozen Papers. Missing authentication,
assistive technology, or delivered mail clients is recorded as `BLOCKED`, never
as a proxy pass. HTTP email preview and browser accessibility trees are
observations only.

Run from the campaign worktree root:

```sh
BARKPARK_MANIFEST=docs/cli/fixtures/full-manifest.json \
  python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E02/scripts/capture.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E02/scripts/build_report.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E02/scripts/verify.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E02/scripts/verify.py
```

`reflow200` is a 640-CSS-pixel viewport at device scale factor 2, the
200%-equivalent reflow of a 1280-device-pixel canvas. `desktop`, `390`, and
`320` use 1440, 390, and 320 CSS pixels respectively.
