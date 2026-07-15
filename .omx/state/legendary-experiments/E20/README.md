# E20 — real TUI and delivered-email dependency gate

E20 is fail-closed because its immutable prerequisite, E19, is `BLOCKED` with
no deployment id and zero accepted captures. The E20 stop condition therefore
forbids starting TUI sessions, delivery, or client capture.

The evidence accounts for all 72 required cells as explicit `NOT_STARTED`
dependency blocks: 36 real interactive `bp` TUI cells and 36 delivered
real-client email cells. It contains no proxy captures, receipts, client-open
claims, production mutations, or persisted secrets.

Build and replay the deterministic evidence:

```bash
python3 .omx/state/legendary-experiments/E20/scripts/build.py
.omx/state/legendary-experiments/E20/scripts/replay.sh
```

Expected final line:

`E20 REPLAY PASS verdict=BLOCKED cells=72 accepted=0 proxies=0`
