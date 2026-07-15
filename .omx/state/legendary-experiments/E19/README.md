# E19 — isolated deployment and three-surface provenance gate

E19 executes the immutable Round 6 assignment against the frozen 36-fixture
E03 corpus and the E16 lossless semantic-tree candidate. The runtime did not
provide a proven isolated deployment target, expiry control, teardown command,
or authenticated Studio browser session. The stop-before-deployment rule
therefore applies.

The artifact records exactly 108 explicit blocked attempts (36 fixtures across
authenticated Studio, public reader, and CLI/API), zero accepted captures, zero
proxies, and no production mutation. Every attempt is bound to the physical E16
candidate capsule digest. No credentials or credential-derived values are
persisted.

Run the bounded capability probe and build the fail-closed evidence:

```bash
python3 .omx/state/legendary-experiments/E19/scripts/preflight.py
python3 .omx/state/legendary-experiments/E19/scripts/build.py
```

Replay the sealed evidence:

```bash
.omx/state/legendary-experiments/E19/scripts/replay.sh
```

Expected output:

`E19 REPLAY PASS verdict=BLOCKED captures=0 attempts=108 rollback=36/36`
