---
'@barkpark/react': minor
---

`<BarkparkReference>`: make client-derived resolution actually work by honoring a target document type. A reference value (`{_ref}` or a bare id) carries no type, but the API's only doc route is the 3-segment `/v1/data/doc/:dataset/:type/:id` (type required) — so the previously emitted 2-segment path always 404'd and every client-derived reference silently fell to `notFound`.

Now the component accepts an optional `type` prop and also reads a `_type` off the reference value; when a type is resolvable it routes through the client's type-aware `doc(type, id)` getter (or builds the canonical 3-segment path via `fetchRaw`), so typed references resolve. Backward-compatible: `type` is optional, no throw is added, and a reference with no available type keeps the current graceful `notFound` behavior. Existing `fetcher`-based and already-resolved-doc usage is unchanged.
