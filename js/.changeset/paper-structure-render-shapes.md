---
'@barkpark/react': patch
---

PortableDoc tables now tolerate legacy cell and row wrapper objects while the
write path canonicalizes them, preventing stored prose from rendering as empty
table cells during a safe corpus migration.
