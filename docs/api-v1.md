# Barkpark HTTP API — v1 Reference

## 1. Overview

Barkpark v1 HTTP API. This document is the frozen contract for all `/v1` endpoints. Any breaking change to the shapes documented here requires bumping the URL prefix to `/v2`.

## 2. Base URL & Authentication

```
Base URL: http://<host>:4000
```

Private endpoints require `Authorization: Bearer <token>`. The development token is `barkpark-dev-token` (read + write + admin). CORS is open (`*`) on all `/v1` routes.

Endpoints marked **[public]** work without a token (restricted by schema visibility). Endpoints marked **[token]** require any valid token. Endpoints marked **[admin]** require a token with admin permission.

## 3. Document Envelope

Every document is returned as a flat JSON object. Reserved keys:

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

**Example:**

```bash
curl localhost:4000/v1/data/doc/production/post/p1 | jq
```

```json
{
  "_id": "p1",
  "_type": "post",
  "_rev": "a3f8c2d1e9b04567f2a1c3e5d7890abc",
  "_draft": false,
  "_publishedId": "p1",
  "_createdAt": "2026-04-12T09:11:20Z",
  "_updatedAt": "2026-04-12T10:03:45Z",
  "title": "Hello World",
  "status": "published",
  "category": "Tech"
}
```

---

## 4. `GET /v1/data/query/:dataset/:type` [public]

List documents. Returns 404 if the schema's `visibility` is `"private"`.

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
  "perspective": "published",
  "documents": [ /* array of envelopes */ ],
  "count": 3,
  "limit": 100,
  "offset": 0
}
```

`count` is the number of documents returned in this response (not the total in the dataset).

**Example:**

```bash
curl "localhost:4000/v1/data/query/production/post?limit=2&order=_createdAt:desc"
```

```json
{
  "perspective": "published",
  "documents": [
    {
      "_id": "p2",
      "_type": "post",
      "_rev": "b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6",
      "_draft": false,
      "_publishedId": "p2",
      "_createdAt": "2026-04-13T08:00:00Z",
      "_updatedAt": "2026-04-13T08:00:00Z",
      "title": "Second Post"
    },
    {
      "_id": "p1",
      "_type": "post",
      "_rev": "a3f8c2d1e9b04567f2a1c3e5d7890abc",
      "_draft": false,
      "_publishedId": "p1",
      "_createdAt": "2026-04-12T09:11:20Z",
      "_updatedAt": "2026-04-12T10:03:45Z",
      "title": "Hello World"
    }
  ],
  "count": 2,
  "limit": 2,
  "offset": 0
}
```

---

## 5. `GET /v1/data/doc/:dataset/:type/:doc_id` [public]

Fetch a single document by id. Returns the envelope directly at the top level (no wrapper object). Returns 404 if not found or if the schema's `visibility` is `"private"`.

**Example:**

```bash
curl localhost:4000/v1/data/doc/production/post/p1
```

Response: a single envelope object (see Section 3).

---

### 5a. Reference Expansion

When a query or doc request carries `?expand=true` (or `?expand=author,category`), reference fields in the returned envelope are inlined with the full referenced document. Expansion is always **depth 1** — a referenced doc's own reference fields stay as raw id strings.

**Example request:**

    curl "localhost:4000/v1/data/query/production/post?limit=1&expand=true"

**Example response (abbreviated):**

```json
{
  "documents": [
    {
      "_id": "p1",
      "_type": "post",
      "title": "Hello",
      "author": {
        "_id": "a1",
        "_type": "author",
        "title": "Jane",
        "category": "c1"
      }
    }
  ]
}
```

Missing references (the referenced document does not exist in the dataset) stay as the raw id string so clients can tell them apart from expanded refs: maps vs. strings.

---

## 6. `POST /v1/data/mutate/:dataset` [token]

Apply a batch of mutations atomically.

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
curl -X POST localhost:4000/v1/data/mutate/production \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mutations":[{"create":{"_type":"post","_id":"hello","title":"Hello"}}]}'
```

---

## 7. `GET /v1/data/listen/:dataset` [token]

Server-Sent Events stream of document mutations.

**Resuming:** Supply `Last-Event-ID: <int>` request header (or `?lastEventId=<int>` query param for browsers that cannot set headers). The server replays all `mutation_events` rows with `id > last-event-id` for that dataset (oldest first), then streams live events.

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
| `previousRev` | string\|null | Always `null` in v1 (reserved) |
| `result` | object | Full document envelope at the time of the event |

**Keepalive:** `: keepalive` comment frame sent every 30 seconds when idle.

**Example:**

```bash
TOKEN="barkpark-dev-token"
curl -N -H "Authorization: Bearer $TOKEN" \
     -H "Last-Event-ID: 0" \
     localhost:4000/v1/data/listen/production
```

---

## 8. Schema endpoints [admin]

### `GET /v1/schemas/:dataset`

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

### `GET /v1/schemas/:dataset/:name`

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

### `POST /v1/schemas/:dataset`

Upsert a schema definition. Returns 201 with the schema object on success.

### `DELETE /v1/schemas/:dataset/:name`

```json
{ "deleted": "post" }
```

**Example:**

```bash
TOKEN="barkpark-dev-token"
curl -H "Authorization: Bearer $TOKEN" \
     localhost:4000/v1/schemas/production | jq '._schemaVersion'
```

---

## 9. Error Codes

All errors return `{"error": {"code": "...", "message": "..."}}` (plus `details` for `validation_failed`).

| Code | HTTP Status | Meaning |
|------|-------------|---------|
| `not_found` | 404 | Document or schema not found |
| `unauthorized` | 401 | Missing or invalid token |
| `forbidden` | 403 | Token lacks required permission |
| `schema_unknown` | 404 | No schema registered for this type |
| `rev_mismatch` | 409 | `ifRevisionID` did not match current rev |
| `conflict` | 409 | Document already exists (on `create`) |
| `malformed` | 400 | Request body is malformed or missing `mutations` key |
| `validation_failed` | 422 | Document failed validation; `details` map contains per-field errors |
| `internal_error` | 500 | Unexpected server error |

---

## 10. Legacy `/api/*` Routes

The following legacy routes are deprecated and will be removed after 2026-12-31:

```
GET  /api/documents/:type
GET  /api/documents/:type/:id
POST /api/documents/:type
DELETE /api/documents/:type/:id
GET  /api/schemas
```

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

## 12. Known Limitations (v1.0)

- `previousRev` is always `null`; full rev history is in a separate revisions table (not part of v1 HTTP contract).
- Draft/published merging (`perspective=drafts`) happens after LIMIT/OFFSET, so a page can return fewer than `limit` rows.
- PubSub broadcasts fire even on transaction rollback (events table is consistent; stream may see ghost events).
- Rate limiting is not enforced.
