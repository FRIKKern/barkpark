---
'@barkpark/core': minor
---

`search()` now respects the client's `perspective` (like `doc`/`docs` reads), with a per-call `perspective` override in `SearchOptions`. Previously search ignored perspective entirely, so `withConfig({ perspective: 'drafts' }).search(…)` silently searched published.
