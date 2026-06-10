<!-- doc-tier: agent | canonical-for: http-api-v1-contract | budget: 3500tok -->
# Barkpark HTTP API — v1 Reference

## 1. Overview

Barkpark v1 HTTP API. This document is the frozen contract for all `/v1` endpoints. Any breaking change to the shapes documented here requires bumping the URL prefix to `/v2`.

## 1a. Workspace → Project → Dataset hierarchy

Content lives in a three-level hierarchy:

- A **Workspace** is the tenancy boundary. Every API token is bound to exactly one workspace, and every content read and write is scoped by workspace.
- A **Workspace** contains **Projects**.
- A **Project** contains **Datasets**.
- A **Dataset** is a collection of **Documents** (the envelopes described in Section 3).

All content/data endpoints are addressed under the workspace + project prefix:

```
/w/:workspace_slug/p/:project_slug/v1/data/...
```

`:dataset` is still a string path segment within that prefix (e.g. `production`). A first-class datasets table is planned for Wave 2; in Wave 1 the dataset is addressed by the existing string segment.

**Back-compat alias.** The old flat paths — `/v1/data/:dataset/*` and the other `/v1/*` content routes without a `/w/.../p/...` prefix — still work. They resolve to a `"Default"` workspace and `"Default"` project. Existing content was auto-backfilled into `Default`/`Default` with zero data loss, so flat callers keep working unchanged. New integrations should use the scoped prefix.

Throughout this document each endpoint shows the **scoped path** as canonical; the flat form is noted as the alias.

## 2. Base URL & Authentication

```
Base URL: http://<host>:4000
```

Private endpoints require `Authorization: Bearer <token>`. The development token is `barkpark-dev-token` (read + write + admin), bound to the `Default` workspace. CORS is open (`*`) on all `/v1` routes.

**Tenancy enforcement.** A request resolves its workspace and project from the path. The token's workspace must match:

- Unknown `:workspace_slug` → `404 not_found`.
- Known workspace, but the token's principal is not a member → `403 forbidden`.

See `docs/auth.md` for token→workspace binding, membership, and the write-permission gate.

Endpoints marked **[public]** work without a token (restricted by schema visibility). Endpoints marked **[token]** require any valid token. Endpoints marked **[admin]** require a token with admin permission.

## 3. Document Envelope

Every response body wraps its payload under a `result` key, alongside four outer metadata keys:

| Outer key | Type | Description |
|-----------|------|-------------|
| `schemaHash` | string | Hex digest of the dataset's schema at response time; changes when any schema changes. Use for schema-sensitive cache keys. |
| `etag` | string | Content fingerprint; use with `If-None-Match` for conditional GET (304 Not Modified). |
| `ms` | integer | Server processing time in milliseconds. |
| `syncTags` | string[] | Cache-tag hints for on-demand ISR revalidation (e.g. `["bp:ds:production:type:post","bp:ds:production:doc:p1"]`). |

For query responses, `result` is an object `{count, offset, limit, perspective, documents:[...]}`. For single-doc responses, `result` is the document envelope object. See Sections 4 and 5 for examples.

**Document envelope keys** (the object inside `result` for a single doc, or each element of `result.documents` for queries):

| Key | Type | Description |
|-----|------|-------------|
| `_id` | string | Full document id, including `drafts.` prefix when the document is a draft |
| `_type` | string | Document type (matches schema name) |
| `_rev` | string | 32-char hex, changes on every write |
| `_draft` | boolean | `true` if `_id` starts with `drafts.` |
| `_publishedId` | string | Id with `drafts.` prefix stripped |
| `_createdAt` | string | ISO 8601 UTC, `Z` suffix (e.g. `2026-04-12T09:11:20Z`) |
| `_updatedAt` | string | ISO 8601 UTC, `Z` suffix |

All other keys come from stored document content plus `title`. User fields cannot override reserved keys — they are silently dropped on write.

See Section 5 for a concrete single-doc response example.

---

## 4. `GET /w/:workspace_slug/p/:project_slug/v1/data/query/:dataset/:type` [public]

> Flat alias: `GET /v1/data/query/:dataset/:type` → resolves the `Default` workspace + project.

List documents. Returns 404 if the schema's `visibility` is `"private"` (and 404/403 per Section 2 if the workspace is unknown / the token is a non-member).

**Query parameters:**

| Param | Default | Notes |
|-------|---------|-------|
| `perspective` | `published` | `published` \| `drafts` \| `raw` |
| `limit` | `100` | Integer, min 1, max 1000 |
| `offset` | `0` | Integer |
| `order` | `_updatedAt:desc` | `_updatedAt:desc` \| `_updatedAt:asc` \| `_createdAt:desc` \| `_createdAt:asc` |
| `filter[<field>]` | — | Exact-match shorthand: `filter[title]=Alpha` |
| `filter[<field>][<op>]` | — | Operator form. `op` is one of `eq`, `in`, `contains`, `gt`, `gte`, `lt`, `lte`. `in` takes a comma-separated list: `filter[title][in]=A,B,C` |
| `expand` | — | `true` (expand all refs) \| comma list `field1,field2` (expand named fields). Depth 1 only. |

**Response body:**

```json
{
  "result": {
    "perspective": "published",
    "documents": [ /* array of document envelopes */ ],
    "count": 3,
    "limit": 100,
    "offset": 0
  },
  "schemaHash": "a96f9af3ab66badc",
  "etag": "b0c8615a3f8ce2363e3d64725adb2736",
  "ms": 2,
  "syncTags": ["bp:ds:production:type:post"]
}
```

`result.count` is the number of documents returned in this response (not the total in the dataset). The outer `schemaHash`, `etag`, `ms`, and `syncTags` are described in Section 3.

**Example:**

```bash
curl "localhost:4000/w/acme/p/web/v1/data/query/production/post?limit=2&order=_createdAt:desc"
```

```json
{
  "result": {
    "perspective": "published",
    "documents": [{ "_id": "p2", "_type": "post", "title": "Second Post", "..." : "..." },
                  { "_id": "p1", "_type": "post", "title": "Hello World", "..." : "..." }],
    "count": 2,
    "limit": 2,
    "offset": 0
  },
  "schemaHash": "a96f9af3ab66badc",
  "etag": "b0c8615a3f8ce2363e3d64725adb2736",
  "ms": 1,
  "syncTags": ["bp:ds:production:type:post", "bp:ds:production:doc:p2", "bp:ds:production:doc:p1"]
}
```

---

## 5. `GET /w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id` [public]

> Flat alias: `GET /v1/data/doc/:dataset/:type/:doc_id` → resolves the `Default` workspace + project.

Fetch a single document by id. Returns the document envelope inside `result`, with the same outer metadata keys (`schemaHash`, `etag`, `ms`, `syncTags`) as every other endpoint. Returns 404 if not found or if the schema's `visibility` is `"private"`.

**Example:**

```bash
curl localhost:4000/w/acme/p/web/v1/data/doc/production/post/p1
```

Response: a single envelope object (see Section 3).

---

### 5a. Reference Expansion

When a query or doc request carries `?expand=true` (or `?expand=author,category`), reference fields in the returned envelope are inlined with the full referenced document. Expansion is always **depth 1** — a referenced doc's own reference fields stay as raw id strings.

**Example request:**

    curl "localhost:4000/w/acme/p/web/v1/data/query/production/post?limit=1&expand=true"

**Example response (abbreviated):**

```json
{
  "result": {
    "documents": [{
      "_id": "p1", "_type": "post", "title": "Hello",
      "author": { "_id": "a1", "_type": "author", "title": "Jane", "category": "c1" }
    }],
    "count": 1, "limit": 1, "offset": 0, "perspective": "published"
  },
  "schemaHash": "...", "etag": "...", "ms": 2, "syncTags": ["..."]
}
```

Missing references (the referenced document does not exist in the dataset) stay as the raw id string so clients can tell them apart from expanded refs: maps vs. strings.

---

## 6. `POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset` [token]

> Flat alias: `POST /v1/data/mutate/:dataset` → resolves the `Default` workspace + project.

Apply a batch of mutations atomically.

**Write gate.** This endpoint enforces the `write` permission. A read-only token (no `write`) gets `403 forbidden`, even on its own workspace. Tenancy is still enforced first: a non-member token gets `403`, an unknown workspace gets `404`.

**Request body:**

```json
{ "mutations": [ <mutation>, ... ] }
```

The entire batch runs inside a single DB transaction. If any mutation fails, the whole batch rolls back and a single error envelope is returned.

### Mutation kinds

**`create`** — Creates a new draft. Errors with `conflict` if a draft already exists at that id.

```json
{ "create": { "_type": "post", "_id": "my-post", "title": "New Post" } }
```

**`createOrReplace`** — Upsert. Creates or overwrites the draft at that id.

```json
{ "createOrReplace": { "_type": "post", "_id": "my-post", "title": "Updated" } }
```

**`createIfNotExists`** — Creates only if no draft exists. If the draft already exists, returns the existing document with `operation: "noop"`.

```json
{ "createIfNotExists": { "_type": "post", "_id": "my-post", "title": "New Post" } }
```

**`patch`** — Merges `set` fields into the existing document. Supports optional `ifRevisionID` for optimistic concurrency; a rev mismatch returns 409 `rev_mismatch`. Note: the operation field in the result is `"update"`.

```json
{
  "patch": {
    "id": "drafts.my-post",
    "type": "post",
    "set": { "title": "Revised Title", "status": "draft" },
    "ifRevisionID": "a3f8c2d1e9b04567f2a1c3e5d7890abc"
  }
}
```

**`publish`** — Copies `drafts.<id>` to `<id>`, deletes the draft.

```json
{ "publish": { "id": "my-post", "type": "post" } }
```

**`unpublish`** — Moves `<id>` back to `drafts.<id>`.

```json
{ "unpublish": { "id": "my-post", "type": "post" } }
```

**`discardDraft`** — Deletes `drafts.<id>` without touching the published document.

```json
{ "discardDraft": { "id": "my-post", "type": "post" } }
```

**`delete`** — Deletes both `<id>` and `drafts.<id>` if they exist.

```json
{ "delete": { "id": "my-post", "type": "post" } }
```

### Success response

```json
{
  "transactionId": "d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9",
  "results": [
    {
      "id": "drafts.my-post",
      "operation": "create",
      "document": { /* full envelope */ }
    }
  ]
}
```

`operation` values: `"create"`, `"createOrReplace"`, `"noop"`, `"update"`, `"publish"`, `"unpublish"`, `"discardDraft"`, `"delete"`.

### Failure response

```json
{
  "error": {
    "code": "conflict",
    "message": "document already exists"
  }
}
```

For `validation_failed`, a `details` map of field-level errors is included.

**Example:**

```bash
TOKEN="barkpark-dev-token"
curl -X POST localhost:4000/w/acme/p/web/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"hello","title":"Hello"}}]}'
```

---

## 7. `GET /w/:workspace_slug/p/:project_slug/v1/data/listen/:dataset` [token]

> Flat alias: `GET /v1/data/listen/:dataset` → resolves the `Default` workspace + project.

Server-Sent Events stream of document mutations. The stream is scoped to the resolved workspace + project.

**Resuming:** Supply `Last-Event-ID: <int>` request header (or `?lastEventId=<int>` query param for browsers that cannot set headers). The server replays all `mutation_events` rows with `id > last-event-id` for that workspace/project/dataset (oldest first), then streams live events.

**Response headers:**

```
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

**First frame — always sent on connect:**

```
event: welcome
data: {"type":"welcome"}

```

**Mutation frame:**

```
id: 42
event: mutation
data: {"eventId":42,"mutation":"create","type":"post","documentId":"drafts.hello","rev":"d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9","previousRev":null,"result":{...envelope...}}

```

| Field | Type | Description |
|-------|------|-------------|
| `eventId` | integer | Auto-incrementing id, use as `Last-Event-ID` for resume |
| `mutation` | string | Mutation kind that produced this event |
| `type` | string | Document type |
| `documentId` | string | Full document id (with `drafts.` if a draft) |
| `rev` | string | Rev of the document after this mutation |
| `previousRev` | string\|null | Rev of the document *before* this mutation. `null` for `create` (no prior revision); populated for `update`/`publish`/`unpublish`/`discardDraft`/`delete` |
| `result` | object | Full document envelope at the time of the event |

**Keepalive:** `: keepalive` comment frame sent every 30 seconds when idle.

**Example:**

```bash
TOKEN="barkpark-dev-token"
curl -N -H "Authorization: Bearer $TOKEN" \
     -H "Last-Event-ID: 0" \
     localhost:4000/w/acme/p/web/v1/data/listen/production
```

---

## 8. Schema endpoints [admin]

Schema endpoints are scoped under the workspace + project prefix like the rest of the content surface. The flat `/v1/schemas/*` forms remain as the `Default`/`Default` back-compat alias.

### `GET /w/:workspace_slug/p/:project_slug/v1/schemas/:dataset`

> Flat alias: `GET /v1/schemas/:dataset`.

```json
{
  "_schemaVersion": 1,
  "schemas": [
    {
      "name": "post",
      "title": "Post",
      "icon": "file-text",
      "visibility": "public",
      "fields": [ /* field definitions */ ]
    }
  ]
}
```

### `GET /w/:workspace_slug/p/:project_slug/v1/schemas/:dataset/:name`

> Flat alias: `GET /v1/schemas/:dataset/:name`.

```json
{
  "_schemaVersion": 1,
  "schema": {
    "name": "post",
    "title": "Post",
    "icon": "file-text",
    "visibility": "public",
    "fields": [ /* field definitions */ ]
  }
}
```

### `POST /w/:workspace_slug/p/:project_slug/v1/schemas/:dataset`

> Flat alias: `POST /v1/schemas/:dataset`.

Upsert a schema definition. Returns 201 with the schema object on success.

### `DELETE /w/:workspace_slug/p/:project_slug/v1/schemas/:dataset/:name`

> Flat alias: `DELETE /v1/schemas/:dataset/:name`.

```json
{ "deleted": "post" }
```

**Example:**

```bash
TOKEN="barkpark-dev-token"
curl -H "Authorization: Bearer $TOKEN" \
     localhost:4000/w/acme/p/web/v1/schemas/production | jq '._schemaVersion'
```

---

## 9. Error Codes

All errors return `{"error": {"code": "...", "message": "..."}}` (plus `details` for `validation_failed`).

| Code | HTTP Status | Meaning |
|------|-------------|---------|
| `not_found` | 404 | Document or schema not found, or unknown `:workspace_slug` |
| `unauthorized` | 401 | Missing or invalid token |
| `forbidden` | 403 | Token lacks required permission, OR is not a member of the resolved workspace, OR is read-only on a write endpoint |
| `schema_unknown` | 404 | No schema registered for this type |
| `rev_mismatch` | 409 | `ifRevisionID` did not match current rev |
| `conflict` | 409 | Document already exists (on `create`) |
| `malformed` | 400 | Request body is malformed or missing `mutations` key |
| `validation_failed` | 422 | Document failed validation; `details` map contains per-field errors |
| `internal_error` | 500 | Unexpected server error |
| `rate_limited` | 429 | Too many requests from this token/IP. Retry after the `Retry-After` header's value |

---

## 10. Legacy `/api/*` Routes

The following legacy routes are deprecated and will be removed after 2026-12-31:

```
GET  /api/documents/:type        [token]
GET  /api/documents/:type/:id    [token]
POST /api/documents/:type        [token]
DELETE /api/documents/:type/:id  [token]
GET  /api/schemas                [public]
```

The `/api/documents/*` routes now require a valid token (`:require_token`). Only `/api/schemas` remains public (unauthenticated) read.

Responses from these routes include:

```
Deprecation: true
Sunset: 2026-12-31
Link: </v1/data/query>; rel="successor-version"
```

Migrate to the `/v1` endpoints. The legacy routes will return 404 after sunset.

---

## 11. Stability Guarantee

Any breaking change to the shapes documented above requires bumping the URL prefix to `/v2`. Additive changes (new optional fields, new error codes, new mutation kinds) are allowed within v1.

---

## 12. Rate Limiting

All `/v1/*` endpoints are rate-limited per token (when present) or per IP, with separate buckets per **method class** and per **dataset**. Reads (`GET`/`HEAD`) and writes (all other verbs) are billed against independent token buckets. Default limits: **300 read requests per minute** and **60 write requests per minute**. Per-dataset overrides are supported via `config :barkpark, :rate_limits`, and the read/write defaults can be tuned with the `BARKPARK_RATE_LIMIT_READ` / `BARKPARK_RATE_LIMIT_WRITE` env vars. When a client exceeds the limit, the response is:

    HTTP/1.1 429 Too Many Requests
    Content-Type: application/json
    Retry-After: <seconds>

    {
      "error": {
        "code": "rate_limited",
        "message": "rate limit exceeded"
      }
    }

Clients should honor the `Retry-After` header and back off.

---

## 13. Known Limitations (v1.0)

- Reference expansion is **depth 1 only**: a referenced doc's own reference fields stay as raw id strings. Clients that need deeper chains issue multiple queries.

---

## 14. Open items

- **Does `delete` require `type`? — needs-verification against prod.** In current code, `Content.apply_one/3` pattern-matches `%{"delete" => %{"id" => _, "type" => _}}`; a `delete` mutation without `type` falls through to the catch-all clause and returns `400 malformed`. That matches §6's documented shape (`{"delete": {"id": ..., "type": ...}}`). This has deliberately NOT been tested against the prod mutate endpoint (2026-06 doc refactor ran no prod requests) — confirm on prod before relying on the without-`type` error shape, and file a bd issue if prod diverges from the code reading.
