---
'@barkpark/core': patch
---

Docs: note that `patch()` inside a `transaction()` is `set`-only for now — `inc`/`dec`/`unset` work standalone (#477/#484) but still throw inside transactions, a sharp edge the README's layout otherwise hid.
