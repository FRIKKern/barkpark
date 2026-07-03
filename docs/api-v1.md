<!-- doc-tier: agent | canonical-for: http-api-v1-contract | budget: 3500tok -->
# Barkpark HTTP API — v1 Reference

## 1. Overview

Frozen contract for all `/v1` endpoints: breaking changes to the shapes below bump the prefix to `/v2`; additive changes (new optional fields, error codes, mutation kinds) stay in v1.

## 1a. Workspace → Project → Dataset hierarchy

A **Workspace** is the tenancy boundary — every token binds to exactly one, every content read/write is workspace-scoped. Workspaces contain **Projects**, Projects contain **Datasets**, a Dataset holds **Documents** (§3). Content endpoints live under the scoped prefix `/w/:workspace_slug/p/:project_slug/v1/data/...` (`:dataset` is a string segment, e.g. `production`).

**Flat alias — applies to every endpoint below.** Old flat paths (`/v1/data/:dataset/*`, `/v1/schemas/*`, other unprefixed `/v1/*` content routes) still work, resolving to `Default`/`Default`. New integrations should use the scoped prefix (canonical here).

## 2. Base URL & Authentication

```
Base URL: http://<host>:4000
```

Private endpoints require `Authorization: Bearer <token>`. Dev token: `barkpark-dev-token` (read + write + admin), bound to the `Default` workspace. CORS reflects only origins in a per-dataset allow-list (`cors_origins` per schema, unioned with `DEFAULT_CORS_ORIGINS` + Barkpark Cloud origins).

**Tenancy enforcement.** Workspace + project resolve from the path; the token's workspace must match — unknown `:workspace_slug` → `404`, non-member → `403`. Binding, membership, write gate: `docs/auth.md`.

Markers: **[public]** = no token (restricted by schema visibility) · **[token]** = any valid token · **[admin]** = admin permission.

**Discovery.** A machine-readable **OpenAPI 3.1** descriptor of `/v1` is at `GET /openapi.json` (public; manifest-generated, never drifts).

## 3. Document Envelope

Every response wraps its payload under `result`, plus four outer metadata keys:

| Outer key | Type | Description |
|-----------|------|-------------|
| `schemaHash` | string | Hex digest of the dataset's schema; changes when any schema changes. |
| `etag` | string | Content fingerprint; use with `If-None-Match` for conditional GET (304 Not Modified). |
| `ms` | integer | Server processing time, milliseconds. |
| `syncTags` | string[] | Cache-tag hints for ISR revalidation (e.g. `["bp:ds:production:type:post","bp:ds:production:doc:p1"]`). |

For query responses, `result` is `{count, offset, limit, perspective, documents:[...]}` (§4). For single-doc responses, `result` is the document envelope object (§5).

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

All other keys come from stored document content plus `title`. User fields cannot shadow reserved keys (silently dropped on write).

## 4. `GET /w/:workspace_slug/p/:project_slug/v1/data/query/:dataset/:type` [public]

List documents. 404 if the schema's `visibility` is `"private"`; 404/403 per §2 on unknown workspace / non-member token.

**Query parameters:**

| Param | Default | Notes |
|-------|---------|-------|
| `perspective` | `published` | `published` \| `drafts` \| `raw`; tokenless callers pinned to `published` |
| `limit` | `100` | Integer, min 1, max 1000 |
| `offset` | `0` | Integer |
| `fields` | — | Project to named content fields (CSV, e.g. `title,slug`); smaller payloads, system fields always kept |
| `order` | `_updatedAt:desc` | any field `<field>:asc`\|`:desc`; comma-join secondary sorts (`a:asc,b:desc`) |
| `count` | `false` | `true` adds `result.total` |
| `filter[<field>]` | — | Exact-match shorthand: `filter[title]=Alpha` |
| `filter[<field>][<op>]` | — | Ops `op` ∈ `eq`, `neq`, `in`, `nin` (`A,B`), `has`, `contains`, `startsWith`, `endsWith`, `gt`/`gte`/`lt`/`lte`, `is` (`null`/`notnull`). `neq`/`nin` exclude NULL. |
| `expand` | — | `true` (all refs) \| `field1,field2` (named refs). Depth 1. |

**Response:** `result` is `{perspective, documents:[envelopes], count, limit, offset}` (`count` = rows on this page); outer keys per §3. Example: `curl "$API/w/acme/p/web/v1/data/query/production/post?limit=2&order=_createdAt:desc"`.

## 5. `GET /w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id` [public]

Fetch a single document by id. 404 if not found or if the schema's `visibility` is `"private"`. Also takes `?fields=`/`?expand=` (§5a).

### 5a. Reference Expansion

`?expand=true` (or `?expand=author,category`) inlines reference fields with the full referenced document — both single refs and `arrayOf`-of-reference lists, each value a plain id string or a `{_ref: id}` object. **Depth 1** only — the inlined doc's own refs and missing targets stay raw (expanded = map, raw = string). Example: `"author":"a1"` becomes `"author":{"_id":"a1","_type":"author","title":"Jane",…}`.

### 5b. Backlinks — `GET /v1/data/backlinks/:dataset/:id` [public]

Inbound refs (reverse of §5a) — docs referencing `:id`: `{result:{backlinks:[<docs>], count:N}}`. Visibility/scope-filtered (out-of-tenant/hidden omitted).

### 5c. History [token]

Under `/v1/data`: `GET history/:dataset/:type/:doc_id` → `{revisions:[{id,action,timestamp}], count}`; `GET revision/:dataset/:id` → `{revision:{…content}}`; `POST revision/:dataset/:id/restore` restores it as a draft.

## 6. `POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset` [token]

Apply a batch of mutations atomically (one DB transaction). Body: `{ "mutations": [ <mutation>, ... ] }`. Any failure rolls back the entire batch.

**Write gate.** Requires the `write` permission (read-only token → `403`, even on its own workspace); tenancy checked first (§2).

### Mutation kinds

**`create`** — new draft; `conflict` if a draft already exists at that id: `{ "create": { "_type": "post", "_id": "my-post", "title": "New Post" } }`.

**`createOrReplace`** — upsert: creates or overwrites the draft. Same shape as `create`.

**`createIfNotExists`** — creates only if no draft exists; else returns it with `operation: "noop"`; shape as `create`.

**`replace`** — overwrites an *existing* draft (`not_found` if none); honors `ifRevisionID`. Same shape (`doc_id` = `_id` alias).

**`patch`** — `{ "patch": { "id": "drafts.my-post", "type": "post", "set": {…}, "ifRevisionID": "<rev>" } }` merges `set` fields into the existing document. Optional `ifRevisionID` for optimistic concurrency (mismatch → `412`, §9). Result operation is `"update"`. It also composes `setIfMissing`/`unset`/`inc`/`dec`/`append`/`prepend` with `set` in one op; `ifMatch` is an `ifRevisionID` alias; a 1-mutation batch inherits the `If-Match` header. Server-owned `status`/`_id`/`_type`/`_rev` are dropped; `title` is promoted.

The next four all take the same shape — `{ "<kind>": { "id": "my-post", "type": "post" } }`:

- **`publish`** — copies `drafts.<id>` to `<id>`, deletes the draft.
- **`unpublish`** — moves `<id>` back to `drafts.<id>`.
- **`discardDraft`** — deletes `drafts.<id>` without touching the published document.
- **`delete`** — deletes both `<id>` and `drafts.<id>` if they exist. Requires `type` (else `400 malformed`); honors `ifRevisionID`.

**Success response:** `{ "transactionId": "<hex>", "results": [ { "id": "drafts.my-post", "operation": "create", "document": {…envelope} } ] }`. `operation` values: `"create"`, `"createOrReplace"`, `"noop"`, `"update"`, `"replace"`, `"publish"`, `"unpublish"`, `"discardDraft"`, `"delete"`.

Failures use the §9 error envelope; `validation_failed` adds a `details` map of field-level errors.

## 7. `GET /w/:workspace_slug/p/:project_slug/v1/data/listen/:dataset` [token]

Server-Sent Events stream of document mutations, scoped to the resolved workspace + project.

**Resuming:** send `Last-Event-ID: <int>` header (or `?lastEventId=<int>` for browser clients). The server replays all events with `id > last-event-id` for that workspace/project/dataset, oldest first, then streams live.

**Response headers:** `Content-Type: text/event-stream` · `Cache-Control: no-cache` · `Connection: keep-alive`. **First frame** on connect: `event: welcome` / `data: {"type":"welcome"}`.

**Mutation frame** — SSE lines `id: <n>` / `event: mutation` / `data: <json>`, where `data` fields are: `eventId` (integer, use as `Last-Event-ID` to resume), `mutation` (kind), `type`, `documentId` (full id, `drafts.` if a draft), `rev` (after the write), `previousRev` (string\|null — rev *before*, carried identically in real-time **and** replayed events, `null` on a `create`), `result` (full envelope), `syncTags` (cache-tag hints, outer-`syncTags` format). **Keepalive:** `: keepalive` comment frame every 30 s when idle.

## 8. Schema endpoints [admin]

Flat `/v1/schemas/*` forms remain the `Default`/`Default` alias, gated on the global `admin` permission; scoped `P` forms gate on workspace role (`owner`/`admin`) instead. Below, `P` = `/w/:workspace_slug/p/:project_slug`. A schema object is `{name,title,icon,visibility,fields:[...]}`.

- `GET P/v1/schemas/:dataset` → `{"_schemaVersion": 1, "schemas": [ <schema>, ... ]}`
- `GET P/v1/schemas/:dataset/:name` → `{"_schemaVersion": 1, "schema": <schema>}`
- `POST P/v1/schemas/:dataset` — upsert a schema definition; returns 201 with the schema object.
- `DELETE P/v1/schemas/:dataset/:name` → `{"deleted": "post"}`

## 8a. Tickets plugin — `/v1/tickets`

A named **`bptk_` key IS an identity**: an operator mints one per outsider, who files and reads tickets with only that key (no account). Present only when the plugin is on. `status` is **server-derived, never client-set**: `open` = operator's move, `answered` = submitter's; a submitter reply auto-reopens, an operator close → `closed`.

| Persona (auth) | Routes (`/v1` prefix) |
|---|---|
| Submitter (`bptk_` bearer) | `POST /tickets` `{subject,body}` · `GET /tickets` · `GET /tickets/:id` (stamps `submitter_seen_at`) · `POST /tickets/:id/messages` `{body}` · `POST /tickets/:id/attachments` · `GET /tickets/:id/attachments/:asset_id` |
| Operator (normal bearer) | `GET /tickets/inbox` (all; open first, oldest-waiting) · `GET /tickets/inbox/:id[/attachments/:asset_id]` · `POST /tickets/:id/answer` `{body,close?}` (→ answered; `close:true`→closed) · `POST /tickets/:id/close` |
| Admin (`/v1/plugins/tickets/keys`) | `POST` mint · `GET` ls · `POST /:id/{rotate,pause,unpause}` · `DELETE /:id` revoke |

**Auth.** A valid `bptk_` key is the whole identity; it is refused by every non-ticket route — it projects tier `"none"` from `/v1/capabilities`, so `bp` (the operator's tool) never surfaces ticket verbs to it; the submitter's tool is the mint card. **Paused** → `403` `key paused` (reversible, thread kept); **revoked** → `401` (indistinguishable from no token); **rotate** = new secret, same identity row (history kept).

**Attachments** (upload: submitter-only): MIME from magic bytes (client `Content-Type` ignored), allowlist `png/jpeg/gif/webp/pdf/txt/log/zip`, ≤10 MB/file, ≤10/ticket; a foreign ticket/asset → `404` (existence never leaked). **Write rate limits** (per key, per class; reads exempt): create **10/hr**, message **60/hr**, attachment **30/hr**; over → `429` + `Retry-After` (§9). **Mint** returns the raw key **once** plus a `quickstart` card of curls (file · list · read) — the outsider's ~2-minute onboarding.

## 9. Error Codes

All errors: `{"error":{"code","message","request_id"}}`; `request_id` mirrors `x-request-id`; `details` on `validation_failed`; optional `hint`.

| Code | HTTP Status | Meaning |
|------|-------------|---------|
| `not_found` | 404 | Document or schema not found, or unknown `:workspace_slug` |
| `unauthorized` | 401 | Missing or invalid token |
| `forbidden` | 403 | Token lacks permission, isn't a member of the resolved workspace, or is read-only on a write endpoint |
| `schema_unknown` | 404 | No schema registered for this type |
| `precondition_failed` | 412 | `ifRevisionID` didn't match the document's current `_rev`; `details.expected`/`.actual` carry both |
| `invalid_filter` | 400 | Unknown filter operator (fail-closed; ops in §4) |
| `conflict` | 409 | Document already exists (on `create`) |
| `malformed` | 400 | Malformed body or missing `mutations` key |
| `validation_failed` | 422 | Document failed validation; `details` map contains per-field errors |
| `internal_error` | 500 | Unexpected server error |
| `rate_limited` | 429 | Too many requests; retry after the `Retry-After` header value |

Additive: `halted` 409 (plugin-hook veto on mutate) · `forbidden_field` 422 (filter/order on an unreadable field) · `cors_forbidden`/`csrf_required` 403 (browser-origin / cookie-authed mutation guards) · bare `rev_mismatch` 409 (concurrent writer).

## 10. Legacy `/api/*` Routes

Deprecated (404 after the 2026-12-31 sunset; migrate to `/v1`): `GET/POST/DELETE /api/documents/:type[/:id]` (token), `GET /api/schemas` (public). Responses carry `Deprecation: true` / `Sunset: 2026-12-31` / `Link` successor headers.

## 11. Rate Limiting

All `/v1/*` endpoints are rate-limited per token (or IP), separate read/write buckets per dataset. Defaults **300 read** / **60 write** req/min (`config :barkpark, :rate_limits`, or `BARKPARK_RATE_LIMIT_READ`/`_WRITE`). Over → `429` + `Retry-After` + `rate_limited` (§9). Ticket keys use their own per-key write buckets (§8a).
