---
'@barkpark/core': minor
---

Transaction patches now support `setIfMissing` / `unset` / `inc` / `dec`, not just `set`. The inner patch builder inside `client.transaction().patch(id, b => …)` previously threw "not implemented in Phase 1A" for every op but `set`, even though the server's mutate endpoint handles them all (#477/#481/#485). Now a transaction patch can `b.set({…}).setIfMissing({…}).unset([…]).inc({…}).dec({…})`, validated consistently with the standalone `client.patch()` builder, and an op-only patch (e.g. just `inc`) no longer requires a `set()`.
