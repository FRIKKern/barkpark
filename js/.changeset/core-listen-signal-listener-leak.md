---
'@barkpark/core': patch
---

Fix an abort-listener leak in `listen()`: a caller-supplied `signal`'s `'abort'` listener is now removed on `handle.unsubscribe()` (and on iterator self-teardown), so a long-lived signal reused across many handles no longer accumulates one dead listener per torn-down handle.
