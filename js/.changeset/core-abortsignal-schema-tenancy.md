---
'@barkpark/core': patch
---

Add optional `opts?: { signal?: AbortSignal }` to the four remaining uncancellable reads — `schemas()` / `getSchema()` / `listWorkspaces()` / `listProjects()` — bringing them to cancellation parity with every other read (doc/docs/search/graph/history/auth.me/media). Purely additive; the signal threads through to `fetch`, so StrictMode/route-change teardown no longer strands these requests.
