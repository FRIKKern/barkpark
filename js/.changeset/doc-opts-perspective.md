---
"@barkpark/core": patch
---

`doc()` opts now surface the per-call `perspective` override on all three surfaces (untyped `BarkparkClient`, `TypedClient`, and the runtime impl). The runtime already honored `opts.perspective` (`getDoc` reads `opts?.perspective ?? config.perspective`) and passed it straight through, but the opts type omitted it — so `bp.doc('post', id, { perspective: 'drafts' })` was a spurious TS excess-property error. Pure type widening, no behavior change; closes the drift with the `typed-client-doc-docs-opts` changeset that promised it.
