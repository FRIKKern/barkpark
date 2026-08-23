---
"@barkpark/codegen": patch
---

Name collation is pinned: the three name sorts (schemas, fields, composite subs) go through one module-level `Intl.Collator('en-US')` instead of bare `localeCompare`, so emitted member order is a function of the names alone — never of the host machine's LANG/LC_ALL. Proven byte-identical to the committed generated types under every locale measured (zero regen).
