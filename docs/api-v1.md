<!-- doc-tier: agent | canonical-for: http-api-v1-contract | budget: 3500tok -->
# Barkpark HTTP API — v1 Reference

## 1. Overview

Frozen contract for all `/v1` endpoints. Breaking changes require a `/v2` prefix bump (§11).

## 1a. Workspace → Project → Dataset hierarchy

A **Workspace** is the tenancy boundary — every token is bound to exactly one; every content read/write is workspace-scoped. Workspaces contain **Projects**; Projects contain **Datasets**; a Dataset holds **Documents** (§3). All content endpoints live under the scoped prefix, with `:dataset` still a string path segment (e.g. `production`; first-class datasets table planned for Wave 2):

```
/w/:workspace_slug/p/:project_slug/v1/data/...
```

**Flat alias — applies to every endpoint below.** The old flat paths (`/v1/data/:dataset/*`, `/v1/schemas/*`, and other unprefixed `/v1/*` content routes) still work, resolving to the `Default` workspace + `Default` project (existing content was auto-backfilled there, zero data loss). New integrations should use the scoped prefix; this doc shows scoped paths as canonical.

## 2. Base URL & Authentication

```
Base URL: http://<host>:4000
```

Private endpoints require `Authorization: Bearer <token>`. Dev token: `barkpark-dev-token` (read + write + admin), bound to the `Default` workspace. CORS is open (`*`) on all `/v1` routes.

**Tenancy enforcement.** Workspace + project resolve from the path; the token's workspace must match. Unknown `:workspace_slug` → `404 not_found`; known workspace but token not a member → `403 forbidden`. Binding, membership, write gate: `docs/auth.md`.

Markers: **[public]** = no token (restricted by schema visibility) · **[token]** = any valid token · **[admin]** = admin permission.

## 3. Document Envelope

Every response wraps its payload under `result`, plus four outer metadata keys:

| Outer key | Type | Description |
|-----------|------|-------------|
| `schemaHash` | string | Hex digest of the dataset's schema; changes when any schema changes. For schema-sensitive cache keys. |
| `etag` | string | Content fingerprint; use with `If-None-Match` for conditional GET (304 Not Modified). |
| `ms` | integer | Server processing time, milliseconds. |
| `syncTags` | string[] | Cache-tag hints for on-demand ISR revalidation (e.g. `["bp:ds:production:type:post","bp:ds:production:doc:p1"]`). |

For query responses, `result` is `{count, offset, limit, perspective, documents:[...]}` (example in §4). For single-doc responses, `result` is the document envelope object (§5).

**Document envelope keys** (inside `result` for a single doc; each `result.documents[]` element for queries):

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

## 4. `GET /w/:workspace_slug/p/:project_slug/v1/data/query/:dataset/:type` [public]

List documents. 404 if the schema's `visibility` is `"private"`; 404/403 per §2 on unknown workspace / non-member token.

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

**Response** (`result.count` = documents returned in this response, not the dataset total; outer keys per §3):

```json
{ "result": { "perspective": "published",
    "documents": [ /* array of document envelopes */ ],
    "count": 3, "limit": 100, "offset": 0 },
  "schemaHash": "a96f9af3ab66badc",
  "etag": "b0c8615a3f8ce2363e3d64725adb2736",
  "ms": 2, "syncTags": ["bp:ds:production:type:post"] }
```

```bash
curl "$API/w/acme/p/web/v1/data/query/production/post?limit=2&order=_createdAt:desc"
```

## 5. `GET /w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id` [public]

Fetch a single document by id. `result` is the document envelope, with the same outer keys (`schemaHash`, `etag`, `ms`, `syncTags`) as every endpoint. 404 if not found or if the schema's `visibility` is `"private"`.

```bash
curl $API/w/acme/p/web/v1/data/doc/production/post/p1
```

### 5a. Reference Expansion

With `?expand=true` (or `?expand=author,category`) on a query or doc request, reference fields are inlined with the full referenced document. Always **depth 1** — a referenced doc's own reference fields stay raw id strings. Missing references (target absent from the dataset) also stay raw id strings, so clients distinguish expanded vs. unexpanded as maps vs. strings.

```json
{ "result": { "documents": [{ "_id": "p1", "_type": "post", "title": "Hello",
      "author": { "_id": "a1", "_type": "author", "title": "Jane", "category": "c1" } }],
    "count": 1, "limit": 1, "offset": 0, "perspective": "published" },
  "schemaHash": "...", "etag": "...", "ms": 2, "syncTags": ["..."] }
```

## 6. `POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset` [token]

Apply a batch of mutations atomically. Body: `{ "mutations": [ <mutation>, ... ] }`. The batch runs in one DB transaction; if any mutation fails, the whole batch rolls back and a single error envelope is returned.

**Write gate.** Requires the `write` permission: a read-only token gets `403 forbidden` even on its own workspace. Tenancy first (non-member → 403, unknown workspace → 404).

### Mutation kinds

**`create`** — new draft; `conflict` if a draft already exists at that id.

```json
{ "create": { "_type": "post", "_id": "my-post", "title": "New Post" } }
```

**`createOrReplace`** — upsert: creates or overwrites the draft.

```json
{ "createOrReplace": { "_type": "post", "_id": "my-post", "title": "Updated" } }
```

**`createIfNotExists`** — creates only if no draft exists; otherwise returns the existing document with `operation: "noop"`.

```json
{ "createIfNotExists": { "_type": "post", "_id": "my-post", "title": "New Post" } }
```

**`patch`** — merges `set` fields into the existing document. Optional `ifRevisionID` for optimistic concurrency; mismatch → 409 `rev_mismatch`. The result's operation field is `"update"`.

```json
{ "patch": { "id": "drafts.my-post", "type": "post",
             "set": { "title": "Revised", "status": "draft" },
             "ifRevisionID": "a3f8c2d1e9b04567f2a1c3e5d7890abc" } }
```

**`publish`** — copies `drafts.<id>` to `<id>`, deletes the draft.

```json
{ "publish": { "id": "my-post", "type": "post" } }
```

**`unpublish`** — moves `<id>` back to `drafts.<id>`.

```json
{ "unpublish": { "id": "my-post", "type": "post" } }
```

**`discardDraft`** — deletes `drafts.<id>` without touching the published document.

```json
{ "discardDraft": { "id": "my-post", "type": "post" } }
```

**`delete`** — deletes both `<id>` and `drafts.<id>` if they exist.

```json
{ "delete": { "id": "my-post", "type": "post" } }
```

### Success response

```json
{ "transactionId": "d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9",
  "results": [ { "id": "drafts.my-post", "operation": "create",
                 "document": { /* full envelope */ } } ] }
```

`operation` values: `"create"`, `"createOrReplace"`, `"noop"`, `"update"`, `"publish"`, `"unpublish"`, `"discardDraft"`, `"delete"`.

Failures use the §9 error envelope; `validation_failed` adds a `details` map of field-level errors.

```bash
curl -X POST $API/w/acme/p/web/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"hello","title":"Hello"}}]}'
```

## 7. `GET /w/:workspace_slug/p/:project_slug/v1/data/listen/:dataset` [token]

Server-Sent Events stream of document mutations, scoped to the resolved workspace + project.

**Resuming:** send `Last-Event-ID: <int>` header (or `?lastEventId=<int>` for browsers that cannot set headers). The server replays all `mutation_events` rows with `id > last-event-id` for that workspace/project/dataset, oldest first, then streams live.

**Response headers:** `Content-Type: text/event-stream` · `Cache-Control: no-cache` · `Connection: keep-alive`.

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
| `eventId` | integer | Auto-incrementing id; use as `Last-Event-ID` to resume |
| `mutation` | string | Mutation kind that produced this event |
| `type` | string | Document type |
| `documentId` | string | Full document id (with `drafts.` if a draft) |
| `rev` | string | Rev after this mutation |
| `previousRev` | string\|null | Rev *before* this mutation; `null` for `create`, populated for `update`/`publish`/`unpublish`/`discardDraft`/`delete` |
| `result` | object | Full document envelope at event time |

**Keepalive:** `: keepalive` comment frame every 30 seconds when idle.

```bash
curl -N -H "Authorization: Bearer $TOKEN" -H "Last-Event-ID: 0" \
     $API/w/acme/p/web/v1/data/listen/production
```

## 8. Schema endpoints [admin]

Scoped like the rest of the content surface; flat `/v1/schemas/*` forms remain the `Default`/`Default` alias. Below, `P` = `/w/:workspace_slug/p/:project_slug`. A schema object is `{"name":"post","title":"Post","icon":"file-text","visibility":"public","fields":[...]}`.

- `GET P/v1/schemas/:dataset` → `{"_schemaVersion": 1, "schemas": [ <schema>, ... ]}`
- `GET P/v1/schemas/:dataset/:name` → `{"_schemaVersion": 1, "schema": <schema>}`
- `POST P/v1/schemas/:dataset` — upsert a schema definition; returns 201 with the schema object.
- `DELETE P/v1/schemas/:dataset/:name` → `{"deleted": "post"}`

```bash
curl -H "Authorization: Bearer $TOKEN" $API/w/acme/p/web/v1/schemas/production | jq '._schemaVersion'
```

## 9. Error Codes

All errors return `{"error": {"code": "...", "message": "...", "request_id": "..."}}` — `request_id` mirrors `x-request-id` when available; `details` for `validation_failed`; optional `hint` fix-suggestion for known codes (additive, v1+v2).

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

## 10. Legacy `/api/*` Routes

Deprecated; removed (404) after the 2026-12-31 sunset. Migrate to `/v1`.

```
GET  /api/documents/:type        [token]
GET  /api/documents/:type/:id    [token]
POST /api/documents/:type        [token]
DELETE /api/documents/:type/:id  [token]
GET  /api/schemas                [public]
```

`/api/documents/*` requires a valid token (`:require_token`); only `/api/schemas` remains unauthenticated. Responses carry:

```
Deprecation: true
Sunset: 2026-12-31
Link: </v1/data/query>; rel="successor-version"
```

## 11. Stability Guarantee

Any breaking change to the shapes documented above requires bumping the URL prefix to `/v2`. Additive changes (new optional fields, new error codes, new mutation kinds) are allowed within v1.

## 12. Rate Limiting

All `/v1/*` endpoints are rate-limited per token (when present) or per IP, with separate buckets per **method class** and per **dataset**: reads (`GET`/`HEAD`) and writes (all other verbs) bill independent buckets. Defaults: **300 read req/min**, **60 write req/min**; per-dataset overrides via `config :barkpark, :rate_limits`; defaults tunable via `BARKPARK_RATE_LIMIT_READ` / `BARKPARK_RATE_LIMIT_WRITE`. Over the limit → `429 Too Many Requests` + `Retry-After: <seconds>` header + `rate_limited` envelope (§9); honor it and back off.

## 13. Known Limitations (v1.0)

- Reference expansion is **depth 1 only**: a referenced doc's own reference fields stay as raw id strings. Clients needing deeper chains issue multiple queries.

## 14. Open items

- **Does `delete` require `type`? — needs-verification against prod.** In code, `Content.apply_one/3` matches `%{"delete" => %{"id" => _, "type" => _}}`; a `delete` without `type` falls to the catch-all → `400 malformed`, matching §6's shape. NOT yet tested against the prod mutate endpoint — confirm there before relying on the without-`type` error shape; file a task if prod diverges.
