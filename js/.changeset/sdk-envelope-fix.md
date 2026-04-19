---
"@barkpark/core": patch
---

fix: SDK query()/doc() now read Phoenix's flat envelope shape (`data.documents` and `data` directly), not the non-existent `data.result` wrapper. Resolves shake-down defects #16 and #18.
