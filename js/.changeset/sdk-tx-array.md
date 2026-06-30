---
'@barkpark/core': minor
---

Transaction patches now support `append`/`prepend`, not just the scalar ops — `client.transaction().patch(id, b => b.append('tags[-1]', ['new']))` works (the server handles them in one mutate batch, #507). The selector→field translation is now shared between the standalone and transaction patch builders (`selectorField` extracted), so a selector means the same thing in either. `insert`/`diffMatchPatch` remain Phase-1A throws.
