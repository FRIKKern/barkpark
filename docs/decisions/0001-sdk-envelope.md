<!-- doc-tier: agent | canonical-for: sdk-envelope-contract | budget: 300tok -->
# 0001 — SDK envelope contract: flat Phoenix shape

**Status:** Accepted 2026-04-19. Full record attic'd: `_attic/docs-2026-06/docs/adr/0001-sdk-envelope-contract.md`.

**The SDK is wrong; the API is canonical.** Phoenix returns flat envelopes and the SDK adapts to them — never the reverse:

| Endpoint | Canonical shape |
|---|---|
| `GET /v1/data/query/{dataset}/{type}` | `{count, offset, limit, documents:[...], perspective}` |
| `GET /v1/data/doc/{dataset}/{type}/{id}` | `{_id, _type, _rev, ...fields}` |

Fix shipped in `@barkpark/core@1.0.0-preview.1` (reads `data.documents` / `data` directly; preview.0 never worked, so: patch, not breaking).

Rejected: `{result: {...}}` wrapping — breaks every live REST consumer (curl, Go TUI, Studio, third parties), forces an API version bump.

**Binding:**
- Any envelope change requires an API version bump and a new ADR.
- Regression fixtures in `js/packages/core/tests` fail any PR re-introducing `data.result.*` unwrapping.

## Code anchors

- `js/packages/core/src/client.ts` — flat-envelope reads
- `api/lib/barkpark_web/controllers/query_controller.ex` — envelope producer
