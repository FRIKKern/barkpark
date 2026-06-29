---
'@barkpark/core': patch
---

`.order()` now accepts nested dot-paths (e.g. `price.amount:desc`), matching the server, which orders nested paths the same as top-level fields (numeric-aware). Previously the order-spec regex rejected any field containing a `.`.
