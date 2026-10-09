<!-- doc-tier: agent | canonical-for: http-api-v1-contract | budget: 3500tok -->
# Barkpark HTTP API — v1 Reference

## 1. Overview

Frozen `/v1`: breaking changes need `/v2`; additive stay in v1.

**JS/TS:** use `@barkpark/core` (queries, mutations, media, listen) and `@barkpark/nextjs` (App Router). [SDK guide](cards/js-sdk.md).

## 1a. Workspace → Project → Dataset hierarchy

A **Workspace** is the token-bound tenant of **Projects**, **Datasets**, **Documents** (§3). Canonical paths start `/w/:workspace_slug/p/:project_slug/v1/data/...`.

**Flat alias.** Unprefixed `/v1/*` resolves to `Default`/`Default`. A scoped twin answers `Deprecation: true` + `rel="successor-version"` `Link`; no `Sunset`.

## 2. Base URL & Authentication

`http://<host>:4000`. Private endpoints need `Authorization: Bearer <token>`. Dev: `barkpark-dev-token` (all perms, `Default`). CORS: schema `cors_origins` + defaults + Cloud origins.

**Tenancy.** Path workspace/project are authoritative and must match the token: unknown → `404`, non-member → `403`. Binding/write gates: `docs/auth.md`.

Markers: **[public]** = no token (schema visibility) · **[token]** = any · **[admin]** = admin.

**Discovery.** OpenAPI 3.1: `GET /v1/openapi.json` (public).

## 3. Document Envelope

Payload under `result`, plus four outer keys: `schemaHash` · `etag` (change token = doc `_rev`; send back as `ifMatch`) — the `ETag` header DIFFERS: a cache validator folding `schemaHash`, 304 only on anonymous unshaped reads (no `?fields`/`?expand`/`?resolve`/`?count`) · `ms` (int) · `syncTags` (string[] ISR cache-tag hints, e.g. `bp:ds:production:type:post`).

**Read-envelope `syncTags` are metadata-only here** (webhook `sync_tags` are not; pin: `js/packages/core/tests/synctags-read-envelope-pin.test.ts`).

`result` for queries (§4): `{count, offset, limit, perspective, hasMore, documents:[...]}` (+`nextOffset` when more); for a single doc (§5), the envelope object.

**Document envelope keys** (`result`, or each `result.documents[]`): `_id` full id, `drafts.` prefix when draft · `_type` schema name · `_rev` 32-char hex, new per write · `_draft` bool · `_publishedId` `_id` minus `drafts.` · `_createdAt`/`_updatedAt` ISO 8601 UTC `Z` (all strings but `_draft`).

Other keys = stored content plus `title`; user fields shadowing reserved keys are dropped on write.

## 4. `GET /w/:workspace_slug/p/:project_slug/v1/data/query/:dataset/:type` [public]

List documents. 404 if the schema is `"private"`; 404/403 per §2.

**Query parameters:**

| Param | Default | Notes |
|-------|---------|-------|
| `perspective` | `published` | `published\|drafts\|raw`; unsupported → 400; tokenless pinned `published` |
| `limit` | `100` | Int 1–1000, clamped; non-integer → 400 |
| `offset` | `0` | Int, clamped; non-integer → 400 |
| `fields` | — | CSV content-field projection (`title,slug`); system fields kept |
| `order` | `_updatedAt:desc` | `<field>:asc\|desc`, comma-join secondaries |
| `count` | `false` | `true` adds `result.total` |
| `filter[<field>]` | — | Exact match: `filter[title]=Alpha` |
| `filter[<field>][<op>]` | — | `eq` `neq` `in` `nin` `nbetween` (`A,B`) `has` `nhas` `hasStrong` (`tag:min`) `contains` `notContains` `startsWith` `endsWith` `gt` `gte` `lt` `lte` `is` (`null`/`notnull`) `count{Eq,Neq,Gt,Gte,Lt,Lte}`. `neq`/`nin`/`nbetween` exclude NULL. `filter[_references]=<id>`: refs `id` |
| `filter[]` (repeated) | — | `filter[]=status=published&filter[]=price>10` — each parses like a lone `filter=`; clauses **AND** (no OR); different ops on one field compose; **same field+op twice → 400 `invalid_filter`** (use `in`); **one unparseable element fails the request** (400, never an unfiltered 200) |
| `expand` | — | `true` (all refs) \| `field1,field2` (named refs, §5a) |

**Response:** `result` + outer keys per §3; `count` = page rows; `hasMore` = a row exists past this page (exact, always present) — so **never infer truncation from `count == limit`**; `nextOffset` when more.

## 5. `GET /w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id` [public]

One document; 404 if missing or schema `"private"`. Takes `?fields=`/`?expand=` (§5a) and `?perspective=` (§4); `drafts` prefers the `drafts.` twin, else published, and `raw` prefers the exact id, else the twin — so a bare `_publishedId` reaches an unpublished doc under both, as `patch`/`publish`/`discardDraft`/`delete` do.

**Read-after-write is immediate** (`cache-control: max-age=0, private, must-revalidate`; ETags include `_id:_rev`). Writes to `drafts.<id>` appear under `?perspective=drafts`, or `raw` without a published row; `published` and `bp task get` read the exact ID.

### 5a. Reference Expansion

`?expand=true` (or `?expand=author,category`) inlines reference fields with the referenced document — single refs and `arrayOf`-of-reference lists, values plain ids or `{_ref: id}`. **Depth 1** only; nested refs and missing targets stay raw (expanded = map, raw = string). A non-reference field → 400.

### 5b/5c. Graph reads + history [token]

`/v1/data/{backlinks,related,tags,counts,history,revision}`: [contracts/document-graph-and-history.md](contracts/document-graph-and-history.md).

## 6. `POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset` [token]

Atomic: one failure rolls back all. Body: `{"mutations":[…]}`. `"dryRun":true` (or `?dryRun=true`): runs, rolls back, answers `results` + `dryRun:true`; non-boolean → `400`. Unknown keys → `mutate.unknown_key` warning.

**Write gate.** Needs `write` permission (read-only → `403`, own workspace too); tenancy first (§2). **Unscoped** (flat + workspace-less token): infers its ONE workspace into `resolvedScope`, else `422 workspace_scope_required`, no write.

**`Idempotency-Key`** (optional, this route). A repeat replays the original response, never re-applies; concurrent → `409 idempotency_key_in_use`. Token+path, 24h.

### Mutation kinds

**`deleteExactDraft`** — `{ "deleteExactDraft": { "id": "drafts.my-post", "type": "post", "ifRevisionID": "<rev>" } }`. Exact draft ID + revision (missing →404, stale →412). Removes only that draft, with recovery history; generic `delete` removes both variants. On a lost reply, reconcile; never retry against a recreated row.

**`create`** — new draft (`conflict` if one exists): `{ "create": { "_type": "post", "_id": "my-post", "title": "New Post" } }`.

**`createOrReplace`** — upserts the draft; **`createIfNotExists`** — creates only if no draft or published row holds the id, else `operation: "noop"` (`drafts.<id>` checks the draft only). Both shaped as `create`.

**`replace`** — overwrites an *existing* draft (`not_found` if none); honors `ifRevisionID`. Same shape (`doc_id` = `_id` alias).

All three create kinds write the **draft** row. On a **published `task`** id, `create`/`createOrReplace` fork a `drafts.<id>` twin: **refused** while the task holds a live claim (422 `validation_failed`), else a `create.forked_published` warning. `patch` edits a published task in place.

**`patch`** — `{ "patch": { "id": "drafts.my-post", "type": "post", "set": {…}, "ifRevisionID": "<rev>" } }` merges `set` into the doc. `ifRevisionID` = optimistic concurrency (mismatch → `412`; `ifMatch` alias; a 1-mutation batch inherits `If-Match`). Composes `setIfMissing`/`unset`/`inc`/`dec`/`append`/`prepend`/`insert`; server-owned `status`/`_id`/`_type`/`_rev` dropped; `title` promoted. Keys with `.`/`[` are paths: `seo.metaTitle`, `body[_key=="b1"].text`, `tags[-1]` (unmatched item → no-op + `patch.path_unmatched` warning; bad path → 422). `insert: {"after"|"before"|"replace": path, "items": […]}`. One doc's patches serialize.

The next four take one shape — `{ "<kind>": { "id": "my-post", "type": "post" } }`; missing `id`/`type` → 422 `validation_failed`:

- **`publish`** — copies `drafts.<id>` to `<id>`, deletes the draft.
- **`unpublish`** — deletes `<id>`; keeps `drafts.<id>`, else copies `<id>` there.
- **`discardDraft`** — deletes `drafts.<id>` only.
- **`delete`** — deletes `<id>` and `drafts.<id>` if they exist; honors `ifRevisionID`.

**Success:** `{ "transactionId": "<hex>", "results": [ { "id": "drafts.my-post", "operation": "create", "document": {…envelope} } ] }`. May add non-blocking `warnings:[{code,severity,message}]` (`label_norm`, `schema_validation`).

Failures: §9. Searchable text (title + every `content` string) over Postgres' **1 048 575-byte** tsvector cap → `422 searchable_text_too_large` (`details.limit_bytes`/`.field`/`.field_bytes`), nothing written. A document's JSON (title + content) over `BARKPARK_MAX_DOCUMENT_BYTES` (default 10 MB) → `413 document_too_large` (`details.limit_bytes`/`.size_bytes`); `/v1/data` bodies cap at 3x that. `content.dedup_bypass: true` skips the duplicate scan.

### 6a. `POST /w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id/ops` [token]

PortableDoc block ops on any document type. Body `{"op":{…},"ifRev":"<_rev>"}` or `"ops":[…]` (atomic, `result.results[]`); `ifRev` required; edits `drafts.<id>` if any. Stale rev → `412`; papers/sessions → `422 invalid_op`; unknown type → `404`. Success: `{result}`.

`…/fields/:field/ops`: `{"ops":[…],"ifRev"}` on one `editor: blocks` field, atomic; `result.rev` = new rev.

## 7. `GET /w/:workspace_slug/p/:project_slug/v1/data/listen/:dataset` [token]

SSE mutation stream: a `/w/:ws/p/:proj` URL carries one project, a flat URL its workspace.

**Narrowing:** `?types=a,b`; `?ids=a,b`; `?perspective=published` drops drafts; `filter[f]=v1,v2`: any-of equality on redacted doc; else 400.

**Resuming:** `Last-Event-ID: <int>` (browsers: `?lastEventId=<int>`) replays later events oldest-first, then live.

First frame: `event: welcome`.

**Mutation frame** — `id: <n>`, `event: mutation`, `data`: `eventId` (int, `Last-Event-ID`), `mutation` (kind), `type`, `documentId` (full id, `drafts.` if draft), `rev` (after write), `previousRev` (`null` on `create`), `result` (envelope), `syncTags`. Keepalive: `: keepalive` per 30 s idle.

**Shed frame:** a stalled consumer gets ONE `event: overloaded` (`reason: slow_consumer`), then closes; reconnect with `Last-Event-ID` (chat never sheds).

**Chat stream** (`GET /v1/chat/sessions/:id/events` [admin]) adds **`event: workflow`** — a live workflow summary (unreplayable, NO `id:`).

## 8. Schema endpoints [admin]

Flat `/v1/schemas/*` needs global `admin`. Scoped `P` reads: any workspace member; writes: role `owner`/`admin`. Below, `P` = `/w/:workspace_slug/p/:project_slug`; a schema object is `{name,title,icon,visibility,fields:[...]}`.

- `GET P/v1/schemas/:dataset` → `{"_schemaVersion": 1, "schemas": [ <schema>, ... ]}`
- `GET P/v1/schemas/:dataset/:name` → `{"_schemaVersion": 1, "schema": <schema>}`
- `POST P/v1/schemas/:dataset` — upsert; 201 with the schema object.
- `DELETE P/v1/schemas/:dataset/:name` → `{"deleted": "post"}`

## 8a. Plugin HTTP surfaces — Tickets `/v1/tickets`, Sheets `POST /v1/plugins/sheets/:slug/ops`, Bulldocs paper ops

Contract: [plugin HTTP](contracts/plugin-http-api.md) covers ticket keys/limits, Sheets individual ops and Paper create-only `/papers/:slug/create` (native blocks, 201; existing published/draft targets 409). Paper `/papers/:slug/ops` edits with `ratchet_hollow/2` + `reject_new_field_loss/2`, no AuthoringWall; its five publish floors reapply at publish. Ordinary `/papers` remains upsert.

## 8c. CycleFleet — `/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id` [token]

Immutable Epic/Legendary ledger; scoped routes canonical, flat = projectless legacy aliases. Contract: [`cycle-fleet.md`](contracts/cycle-fleet.md).

## 8d. Media — asset record (`absoluteUrl`) + `/v1/media/*` list envelope

Contract: [contracts/media-http-envelope.md](contracts/media-http-envelope.md). `GET /v1/i18n/paper_canvas`: [contract](contracts/paper-canvas-i18n.md).

## 9. Error Codes

All errors: `{"error":{"code","message","request_id"}}`; `request_id` mirrors `x-request-id`; `details` on `validation_failed`; optional `hint`. §6 schema `validation_failed` adds `findings:[{path,message,code,params}]`.

Core: `not_found` 404 · `unauthorized` 401 · `forbidden` 403 · `precondition_failed` 412 (`details.expected`/`.actual`) · `invalid_filter` 400 · `conflict` 409 · `malformed` 400 · `validation_failed` 422 · `bad_request` 400/422 · `internal_error` 500 · `rate_limited` 429 (`Retry-After`).

`halted` 409 · `forbidden_field` 422 · `cors_forbidden`/`csrf_required` 403 · `webhook_not_found`/`event_not_found` 404 · `rev_mismatch`/`paper_exists`/`duplicate_task`/`duplicate_of`/`schema_has_documents`/`idempotency_key_in_use` 409 · `unsupported_if_match_for_batch` 400 · `workspace_scope_required`/`private_field_bound`/`searchable_text_too_large` 422/`document_too_large` 413 (§6) · `storage_unavailable` 503/`unsupported_media_type` 422/`payload_too_large` 413. Publish: `workspace_suspended`/`playground_expired` 403 · `quota_exceeded` 402 · `unknown_tag`/`label_spine`/`invalid_paper_structure`/`invalid_epic_paper_quality` 422. BPML create-on-push: `create_wall` 422 (violations in `details`) · `slug_mismatch` 422 (slug attr ≠ URL slug) · `paper_rev_unreadable` 422 (`content["rev"]` not an integer; absent = 0) · `auth_method_not_allowed` 403 (org `allowed_auth_methods` allow-list; NULL = all open; `social` ≠ `sso`).

Per endpoint: [api/error-codes.md](api/error-codes.md); source `Errors.known_codes/0`.

## 10. Legacy `/api/*` Routes

Deprecated (404 after the 2026-12-31 sunset; migrate to `/v1`): `GET/POST/DELETE /api/documents/:type[/:id]` (token), `GET /api/schemas` (public). Responses carry `Deprecation`/`Sunset`/`Link`.

## 11. Rate Limiting

Per token (or IP), read/write buckets per dataset: **300r/60w**/min (config `:rate_limits` or `BARKPARK_RATE_LIMIT_READ`/`_WRITE`). Over → `429` + `Retry-After` (§9); ticket keys per-key (§8a).
