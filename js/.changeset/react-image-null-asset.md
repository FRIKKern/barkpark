---
'@barkpark/react': patch
---

`BarkparkImage` no longer throws on a `null`/`undefined` asset (an unset optional image field) — it renders nothing. The `asset` prop type now accepts `null`/`undefined` so optional fields type-check cleanly. Previously the `getAsset*` helpers' `'…' in asset` checks threw a `TypeError` on a nullish asset.
