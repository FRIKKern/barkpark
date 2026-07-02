---
'@barkpark/core': minor
---

Add `client.getSearchSuggestions(prefix?, opts?)` — typeahead suggestions for a **document** search box, backed by the public `GET /v1/data/search/:dataset/suggestions` route. Returns `{ recent, popular, nohits }` query buckets (the caller's recent queries, the dataset's popular ones, and recent no-hit queries), each filtered by the typed `prefix`. This closes a layer-parity gap: the SDK already shipped the identical capability for media (`getAssetSearchSuggestions`), but the document search surface had no equivalent — so building a search-box autocomplete required a raw fetch. Mirrors the media method exactly (scoped path, `limit` paging guard, tolerant `result` unwrap, buckets default to `[]`).
