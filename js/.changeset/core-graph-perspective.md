---
'@barkpark/core': patch
---

`getGraph()` now respects the client's `perspective` (like `doc`/`docs`/`search` reads), falling back to the configured perspective when no per-call `perspective` opt is given. Previously it only forwarded `opts.perspective`, so `withConfig({ perspective: 'drafts' }).getGraph(id)` silently traversed the published graph. Only a `'drafts'` config is forwarded — the client's `'raw'` perspective (unsupported by the graph route) is not.
