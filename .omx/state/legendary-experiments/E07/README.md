# E07 canonical Legendary five-surface attack

E07 attacks the E04, E05, and E06 candidates against all 36 frozen E03 fixtures on authenticated Studio, public reader, TUI, CLI/API, and real-client email.

Replay:

```sh
bash .omx/state/legendary-experiments/E07/run.sh
```

`result.json` is the machine-readable verdict. Candidate-local records count only for CLI/API. E03 source probes never proxy-pass candidate rendering, and unavailable authenticated Studio or real-client email capabilities remain `BLOCKED`.

`timing.json` preserves the original measured E07 run as immutable evidence. Each replay writes current wall-clock telemetry only to ignored `.replay/timing.json`; two full logical replays must reproduce every tracked artifact byte-for-byte.
