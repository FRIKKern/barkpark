---
'@barkpark/core': minor
---

`patch().setIfMissing(fields)` is now implemented (Phase-1B). It writes fields only where the document doesn't already have them — `client.patch(id).setIfMissing({ lang: 'en' }).commit()` — composing with set/unset/inc/dec in one commit (`set()` overrides `setIfMissing()` on the same key). Validated client-side like `set()` (plain object, no system fields). This completes the scalar patch surface (set/setIfMissing/unset/inc/dec). Requires the server's `patch.setIfMissing` support (shipped in #485).
