---
'@barkpark/core': patch
---

core: fail-closed input guards on three previously-broken client inputs.
`client.search()` now throws when both `type` and a non-empty `types` are
passed — the server ANDs them (`type == x AND type IN [...]`), so disjoint
values silently returned zero hits. `client.getDocuments()` validates its
arguments before any network call: a non-empty string `type`, an actual array
of `ids`, and non-empty string id elements (a bare-string id like `'p1'` used
to slip past the empty-array check and die at `ids.map is not a function`).
`client.uploadAsset()` duck-types the `Blob`/`File` contract (cross-realm safe,
no `instanceof`) so passing `null` or a path string throws a self-explaining
`BarkparkValidationError` instead of an opaque `DOMException`. All additive,
non-breaking.
