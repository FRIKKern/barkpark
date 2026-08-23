---
"@barkpark/core": minor
---

`client.search()` and `client.getSearchSuggestions()` accept an optional `sessionKey`, threaded as the `x-bp-search-client` header — the per-session identity the browser UI already mints. Tokenless SDK callers on a public dataset can pass the same UUID to both calls to keep a safe per-session `recent` view after the anonymous fail-close (which correctly returns `[]` recents to header-less anonymous callers). No key, no header: the fail-closed default is untouched.
