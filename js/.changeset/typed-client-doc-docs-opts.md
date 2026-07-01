---
"@barkpark/core": patch
---

typedClient `doc()`/`docs()` regain the `expand`/`fields`/`signal`/`perspective` options — restoring parity with the untyped client (the overloads previously dropped `opts` even though the runtime supports it).
