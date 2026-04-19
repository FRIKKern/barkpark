# ADR 0001 — SDK envelope contract: flat Phoenix shape

**Status:** Accepted
**Date:** 2026-04-19
**Deciders:** Barkpark core team
**Related:** Task #24 (remediation A); defects #16, #18; slice 8.2 shake-down (task #8)

## Context

Slice 8.2 shake-down exercised @barkpark/core@1.0.0-preview.0 against the production API
at http://89.167.28.206:4000 and found two P0 defects with the same root cause:

- **#16** — `client.docs('post').find()` throws `TypeError: Cannot read properties of
  undefined (reading 'documents')`.
- **#18** — `client.doc('post', 'p1')` returns `undefined` instead of the document.

Root cause: the SDK unwrapped responses as `data.result.documents` and `data.result`,
but the Phoenix API returns flat envelopes:

| Endpoint | Actual shape |
|----------|--------------|
| `GET /v1/data/query/{dataset}/{type}` | `{count, offset, limit, documents:[...], perspective}` |
| `GET /v1/data/doc/{dataset}/{type}/{id}` | `{_id, _type, _rev, ...fields}` |

Evidence: verified via `curl -sSf http://89.167.28.206:4000/v1/data/query/production/post`
and `curl -sSf http://89.167.28.206:4000/v1/data/doc/production/post/p1` on 2026-04-19.

## Decision

**The SDK is wrong; the API is canonical.** We will change the SDK (`@barkpark/core`) to
read Phoenix's flat envelope directly (`data.documents` for queries, `data` for single
documents), and ship the fix in `@barkpark/core@1.0.0-preview.1` — a patch release over
preview.0.

No Phoenix API change. No other `@barkpark/*` package bump.

## Consequences

- Existing `@barkpark/core@1.0.0-preview.0` users are effectively broken for query/doc
  reads and MUST upgrade to `1.0.0-preview.1` — we treat this as a bugfix, not a breaking
  change, since the previous version never worked end-to-end.
- Phoenix response shape is now the documented contract. Any future envelope change
  requires an API version bump and a new ADR.
- Regression fixtures in `js/packages/core/tests` now match the flat shape; any future
  SDK PR that re-introduces `data.result.*` unwrapping will fail those tests.
- Changeset: `.changeset/sdk-envelope-fix.md` (patch bump, `@barkpark/core`).

## Alternatives considered

**Option A — wrap Phoenix responses in `{result: {...}}`.** Rejected: breaks every live
consumer of the REST API (curl users, the Go TUI at root, the LiveView Studio, third
parties); would require an API version bump and a coordinated migration. Cost vastly
exceeds the one-line SDK fix.

**Option B (chosen) — fix the SDK to read the flat envelope.** Pure SDK change. One
patch release (`1.0.0-preview.1`). No downstream impact outside the SDK itself.

## Implementation

- Branch: `phase-8/sdk-envelope-fix`
- Commit: `3db8a494870979ab565b322de2f7b9e50052d923`
- Files changed: `js/packages/core/src/*`, `js/packages/core/tests/*`,
  `js/packages/core/package.json` (version bump to 1.0.0-preview.1),
  `.changeset/sdk-envelope-fix.md`.
- Live regression: `client.docs('post').find()` and `client.doc('post','p1')` against
  http://89.167.28.206:4000 both return real documents (captured in commit body).
