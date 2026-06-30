---
'@barkpark/core': patch
---

Docs: document `patch().append()` / `patch().prepend()` (#509/#510, standalone + transaction) in the README; remove the now-obsolete "transaction patch is set-only" note (the scalar + array ops all work in transactions now); fix the `patch.ts` comment. Only positional `insert` + `diffMatchPatch` remain unimplemented.
