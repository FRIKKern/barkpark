---
'@barkpark/core': patch
---

transaction.patch now throws a clear BarkparkValidationError on an empty document id (parity with createPatch and the other tx ops).
