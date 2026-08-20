# E03 canonical Legendary baseline

Read-only Round-1 artifacts for 12 frozen Papers, 18 frozen Tasks, and six pre-hashed adversarial scratch fixtures. No product/source or production data is mutated.

Replay integrity and result-contract checks:

```sh
python3 .omx/state/legendary-experiments/E03/scripts/verify.py
```

Re-run live read-only surface probes (overwrites E03 raw captures only):

```sh
.omx/state/legendary-experiments/E03/scripts/probe.sh
python3 .omx/state/legendary-experiments/E03/scripts/sanitize_captures.py
python3 .omx/state/legendary-experiments/E03/scripts/build_report.py
python3 .omx/state/legendary-experiments/E03/scripts/verify.py
```

`result.json` is the machine-readable verdict. `thresholds.json` and `failure-taxonomy.json` are frozen for E04–E15. Studio and real-client email remain explicit capability blocks, never PASS.
