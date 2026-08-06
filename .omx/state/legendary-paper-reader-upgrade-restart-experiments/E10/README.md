# E10 — Converge no-winner proof and replacement-wave contract

E10 independently replays E07's hostile preservation/schema probe, synthesizes the sealed E07–E09 failures without selecting a candidate, and proves that E04, E05, and E06 each fail at least one zero-threshold hard gate. Pilot is not authorized.

The repair manifest is an executable minimum contract for a new immutable replacement wave. It covers alias conflicts, malformed structures, long-token geometry, revision-fenced write CAS, exact rollback and quarantine, terminal sanitization, and five reader adapters. It does not claim those repairs exist in a runnable candidate or that unavailable real readers passed.

Reproduce from the worktree root:

```sh
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E10/scripts/replay.py
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E10/scripts/verify.py
```

Expected final lines are `E10 REPLAY PASS` and a canonical JSON verification record with `"status":"PASS"`. The verifier is run twice by replay and its byte-identical outputs are retained.
