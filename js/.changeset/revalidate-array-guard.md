---
'@barkpark/nextjs': patch
---

`revalidateBarkpark`: guard `sync_tags` / `ids` / `types` with `Array.isArray` instead of a truthy check. Because the function is public and documented to accept a raw `await req.json()` body, a hand-built or legacy payload could carry a non-array value for these fields. A number/object threw `TypeError: not iterable`, and — more insidiously — a bare **string** (`sync_tags: "bp:ds:…"`) is truthy and iterable, so `for...of` walked it character-by-character, adding single-char garbage tags and never invalidating the intended one (silent stale content). A non-array is now simply ignored; the trusted Phoenix dispatcher (which always sends arrays) is unaffected.
