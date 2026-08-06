# E05 — shared read-time compatibility core

This isolated Round-2 candidate preserves the four pinned Paper JSON captures byte-for-byte and derives one lossless semantic core. Five thin adapters consume that core: public HTML, Studio JSON, TUI80 text, RFC-style email, and CLI/API JSON. No production source, Task, Paper, Cycle record, or campaign ledger is mutated.

Run the complete deterministic probe twice:

```sh
python3 .omx/state/legendary-paper-reader-upgrade-restart-experiments/E05/scripts/replay.py
```

Expected final line: `E05 REPLAY PASS`.

Authenticated Studio, real assistive technology, and delivered-mail client observations remain `BLOCKED`; generated adapter artifacts are never proxy evidence for those readers.
