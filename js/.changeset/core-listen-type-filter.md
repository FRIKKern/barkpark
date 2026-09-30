---
'@barkpark/core': patch
---

`client.listen('post')` now yields only mutations of the requested type(s). The server's listen route ignores `?types=` and streams every type in scope, so a type-scoped subscription used to receive other types' mutations. The type list, which may be comma-separated, is now applied in the client. Welcome frames still pass, and no type still means every type.
