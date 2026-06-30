---
'@barkpark/core': patch
---

Export `ListenOptions` — the option type for the (already-exported) `createListenHandle` escape hatch (perspective / maxReconnects / reconnectBaseMs / signal). It was defined but not re-exported from the package entry, so a consumer using `createListenHandle` directly couldn't type its `opts`. Completes the listen public surface (`ListenFilter` / `ListenHandle` / `ListenEvent` were already exported).
