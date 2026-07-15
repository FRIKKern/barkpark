# E17 — canonical five-real-surface capture gate

E17 executes the exact E11 assignment against E16
`candidate-lossless-semantic-tree`. It owns only this directory.

The real-reader preflight did not provide a safe candidate deployment:

- authenticated Studio redirected to the login surface even with the available
  API bearer token;
- the public reader accepted the candidate-shaped URL, but no deployed record
  carried E16 candidate provenance;
- the real TUI failed during schema loading before a candidate document could be
  selected;
- Mail.app was present, but the candidate email endpoint returned 404, so no
  message was imported or proxy-rendered;
- `bp paper view` reported that every candidate-shaped slug was absent.

Accordingly, E17 records exactly 180 hashed **attempt artifacts** and 180
fixture/surface cells, but zero accepted candidate-specific captures. It never
promotes a proxy, source-only render, URL reflection, or synthetic substitution
to a real-reader capture. The hard gate therefore ends `FAIL / REWORK`.

Run the live preflight once:

```bash
python3 .omx/state/legendary-experiments/E17/scripts/probe.py
```

Seal and replay the frozen evidence:

```bash
python3 .omx/state/legendary-experiments/E17/scripts/build.py
python3 .omx/state/legendary-experiments/E17/scripts/finalize.py
.omx/state/legendary-experiments/E17/scripts/replay.sh
```

Expected final line: `E17 REPLAY PASS verdict=FAIL/REWORK captures=0 attempts=180`.
