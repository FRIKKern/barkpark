<!-- doc-tier: agent | canonical-for: http-api-v1-contract | budget: 3500tok -->
# Barkpark HTTP API — v1 Reference

## 1. Overview

Frozen `/v1`: breaking changes need `/v2`; additive stay in v1.

## 1a. Workspace → Project → Dataset hierarchy

A **Workspace** is the token-bound tenant of **Projects**, **Datasets**, **Documents** (§3). Canonical paths start `/w/:workspace_slug/p/:project_slug/v1/data/...`.

**Flat alias.** Unprefixed `/v1/*` content routes resolve to `Default`/`Default`.

## 2. Base URL & Authentication

```
Base URL: http://<host>:4000
```

Private endpoints need `Authorization: Bearer <token>`. Dev token: `barkpark-dev-token` (all perms, `Default`). CORS: schema `cors_origins` + configured defaults + Barkpark Cloud origins.

**Tenancy.** Path workspace/project are authoritative and must match the token: unknown → `404`, non-member → `403`. Binding/write gates: `docs/auth.md`.

Markers: **[public]** = no token (schema-visibility gated) · **[token]** = any token · **[admin]** = admin.

**Discovery.** OpenAPI 3.1 of `/v1`: `GET /openapi.json` (public, manifest-generated).

## 3. Document Envelope

Payload under `result`, plus four outer keys: `schemaHash` (hex digest of the dataset schema; changes with any) · `etag` (`If-None-Match` → 304) · `ms` (server ms, int) · `syncTags` (string[] ISR cache-tag hints, e.g. `bp:ds:production:type:post`).

`result` for queries (§4): `{count, offset, limit, perspective, hasMore, documents:[...]}` (+`nextOffset` when more); for a single doc (§5), the envelope object.

**Document envelope keys** (in `result` for a single doc; each `result.documents[]` for queries): `_id` full id, `drafts.` prefix when draft · `_type` schema name · `_rev` 32-char hex, changes on every write · `_draft` bool · `_publishedId` `_id` minus `drafts.` · `_createdAt`/`_updatedAt` ISO 8601 UTC `Z` (all strings but `_draft`).

Other keys = stored content plus `title`; user fields can't shadow reserved keys—dropped on write.

## 4. `GET /w/:workspace_slug/p/:project_slug/v1/data/query/:dataset/:type` [public]

List documents. 404 if the schema is `"private"`; 404/403 per §2.

**Query parameters:**

| Param | Default | Notes |
|-------|---------|-------|
| `perspective` | `published` | `published\|drafts\|raw`; unsupported → 400; tokenless pinned `published` |
| `limit` | `100` | Int, min 1, max 1000 |
| `offset` | `0` | Int |
| `fields` | — | CSV content-field projection (`title,slug`); system fields kept |
| `order` | `_updatedAt:desc` | `<field>:asc\|desc`, comma-join secondaries |
| `count` | `false` | `true` adds `result.total` |
| `filter[<field>]` | — | Exact-match shorthand: `filter[title]=Alpha` |
| `filter[<field>][<op>]` | — | Ops: `eq`, `neq`, `in`, `nin` (`A,B`), `has`, `hasStrong` (`tag:min`, weighted `strength >= min`; flat never matches), `contains`, `startsWith`, `endsWith`, `gt`/`gte`/`lt`/`lte`, `is` (`null`/`notnull`). `neq`/`nin` exclude NULL. |
| `expand` | — | `true` (all refs) \| `field1,field2` (named refs). Depth 1. |

**Response:** `result` + outer keys per §3; `count` = page rows; `hasMore` = a row exists past this page (exact, always present) — so **never infer truncation from `count == limit`**; `nextOffset` = next offset when more.

## 5. `GET /w/:workspace_slug/p/:project_slug/v1/data/doc/:dataset/:type/:doc_id` [public]

Fetch one document by id. 404 if missing or the schema is `"private"`. Takes `?fields=`/`?expand=` (§5a) and `?perspective=` (§4): `drafts` prefers the `drafts.` twin, else published.

### 5a. Reference Expansion

`?expand=true` (or `?expand=author,category`) inlines reference fields with the full referenced document — single refs and `arrayOf`-of-reference lists, values plain id strings or `{_ref: id}`. **Depth 1** only — nested refs and missing targets stay raw (expanded = map, raw = string).

### 5b. Backlinks — `GET /v1/data/backlinks/:dataset/:id` [public]

Inbound refs (reverse of §5a) — docs referencing `:id`: `{result:{backlinks:[<docs>], count:N}}`. Scope/visibility-filtered; out-of-tenant/hidden omitted.

Related — `GET /v1/data/related/:dataset/:id` (`?limit=`, ≤50): weighted-tag overlap (Σ `LEAST(src,cand)/100` + main_tag bonus) + backlinks → `{result:{related:[{doc_id,type,title,score,sources,shared_tags}],count:N}}`. Anon 404.

Tags — `GET /v1/data/tags/:dataset` (`?type=`, default `paper,task`): per-tag per-type published counts → `{result:{tags:[{tag,counts,total}],count}}`; `/tags/:dataset/:tag`: docs ranked by that tag's strength (legacy flat last) → `result.documents:[{doc_id,type,title,strength,rationale,main_tag_match}]`. Anon 404.

Counts — `GET /v1/data/counts/:dataset` [token]: per-type **published** counts, one aggregate → `{ok,dataset,perspective:"published",counts:{<type>:N}}` (frozen, not `result`-wrapped). Anon 404. Published-only; other `?perspective` → 400 (§4).

### 5c. History [token]

Under `/v1/data`: `GET history/:dataset/:type/:doc_id` → `{revisions:[{id,action,timestamp}], count}`; `GET revision/:dataset/:id` → `{revision:{…content}}`; `POST revision/:dataset/:id/restore` restores as a draft.

## 6. `POST /w/:workspace_slug/p/:project_slug/v1/data/mutate/:dataset` [token]

A batch of mutations, applied atomically (any failure rolls back the batch). Body: `{ "mutations": [ … ] }`.

**Write gate.** Needs `write` permission (read-only token → `403`, even on its own workspace); tenancy first (§2).

### Mutation kinds

**`create`** — new draft; `conflict` if a draft already exists at that id: `{ "create": { "_type": "post", "_id": "my-post", "title": "New Post" } }`.

**`createOrReplace`** — upsert (creates or overwrites the draft); **`createIfNotExists`** — creates only if no draft exists, else returns it with `operation: "noop"`. Both shaped as `create`.

**`replace`** — overwrites an *existing* draft (`not_found` if none); honors `ifRevisionID`. Same shape (`doc_id` = `_id` alias).

**`patch`** — `{ "patch": { "id": "drafts.my-post", "type": "post", "set": {…}, "ifRevisionID": "<rev>" } }` merges `set` into the doc. `ifRevisionID` = optimistic concurrency (mismatch → `412`; `ifMatch` alias; a 1-mutation batch inherits `If-Match`). Composes `setIfMissing`/`unset`/`inc`/`dec`/`append`/`prepend`; server-owned `status`/`_id`/`_type`/`_rev` dropped; `title` promoted.

The next four take one shape — `{ "<kind>": { "id": "my-post", "type": "post" } }`:

- **`publish`** — copies `drafts.<id>` to `<id>`, deletes the draft.
- **`unpublish`** — moves `<id>` back to `drafts.<id>`.
- **`discardDraft`** — deletes `drafts.<id>` without touching the published document.
- **`delete`** — deletes both `<id>` and `drafts.<id>` if they exist. Requires `type` (else `400 malformed`); honors `ifRevisionID`.

**Success response:** `{ "transactionId": "<hex>", "results": [ { "id": "drafts.my-post", "operation": "create", "document": {…envelope} } ] }`. A publish may add non-blocking `warnings:[{code,severity,message}]` (e.g. `label_norm`); paper-ingest 200 carries it too.

Failures: §9.

## 7. `GET /w/:workspace_slug/p/:project_slug/v1/data/listen/:dataset` [token]

SSE stream of document mutations, scoped to the resolved workspace + project.

**Resuming:** `Last-Event-ID: <int>` header (`?lastEventId=<int>` for browsers); replays scope events with greater `id`, oldest first, then live.

**First frame** on connect: `event: welcome` / `data: {"type":"welcome"}`.

**Mutation frame** — SSE lines `id: <n>` / `event: mutation` / `data: <json>`; `data`: `eventId` (int, `Last-Event-ID`), `mutation` (kind), `type`, `documentId` (full id, `drafts.` if draft), `rev` (after write), `previousRev` (`null` on `create`), `result` (envelope), `syncTags` (outer format). **Keepalive:** `: keepalive` every 30 s idle.

**Shed frame:** a stalled consumer gets ONE `event: overloaded` / `data: {"type":"overloaded","reason":"slow_consumer"}`, then the stream closes — reconnect with `Last-Event-ID`. (Chat never sheds.)

**Chat stream** (`GET /v1/chat/sessions/:id/events` [admin]) adds **`event: workflow`** — a live workflow summary (unreplayable, NO `id:`).

## 8. Schema endpoints [admin]

Flat `/v1/schemas/*` forms remain the `Default`/`Default` alias, gated on the global `admin` permission; scoped `P` forms gate on workspace role (`owner`/`admin`). Below, `P` = `/w/:workspace_slug/p/:project_slug`; a schema object is `{name,title,icon,visibility,fields:[...]}`.

- `GET P/v1/schemas/:dataset` → `{"_schemaVersion": 1, "schemas": [ <schema>, ... ]}`
- `GET P/v1/schemas/:dataset/:name` → `{"_schemaVersion": 1, "schema": <schema>}`
- `POST P/v1/schemas/:dataset` — upsert; 201 with the schema object.
- `DELETE P/v1/schemas/:dataset/:name` → `{"deleted": "post"}`

## 8a. Tickets plugin — `/v1/tickets`

A **`bptk_` key IS an identity**: minted per outsider, who files/reads tickets with only that key. Plugin-gated. `status` is **server-derived**: `open` = operator's move, `answered` = submitter's; a submitter reply auto-reopens, an operator close → `closed`.

| Persona (auth) | Routes (`/v1` prefix) |
|---|---|
| Submitter (`bptk_`) | `POST /tickets` · `GET /tickets[/:id]` (stamps `submitter_seen_at`) · `POST /tickets/:id/{messages,attachments}` · `GET /tickets/:id/attachments/:asset_id` |
| Operator (bearer) | `GET /tickets/inbox[/:id[/attachments/:asset_id]]` (open first) · `POST /tickets/:id/answer` `{body,close?}` · `POST /tickets/:id/close` |
| Admin (`/v1/plugins/tickets/keys`) | `POST` mint · `GET` ls · `POST /:id/{rotate,pause,unpause}` · `DELETE /:id` revoke |

**Auth.** A `bptk_` key is refused by every non-ticket route (tier `"none"` in `/v1/capabilities`). **Paused** → `403` `key paused` (reversible); **revoked** → `401` (as no token); **rotate** = new secret, same identity row.

**Attachments** (submitter-only): MIME from magic bytes (client header ignored); allowlist `png/jpeg/gif/webp/pdf/txt/log/zip`, ≤10 MB/file, ≤10/ticket; foreign → `404`. **Write limits**/key (reads exempt): create 10/hr, message 60/hr, attachment 30/hr; over → `429` + `Retry-After` (§9). **Mint** returns the raw key **once** + `quickstart` curls.

## 8b. Sheets plugin — `POST /v1/plugins/sheets/:slug/ops` [admin]

Body `{"ops":[…]}` (`?dataset=`, default `production`); the `BARKPARK_INGEST_TOKEN` shared secret also authorizes. Ops apply INDIVIDUALLY, not atomically — a refused op lands in the 200's `errors` as `{index,code,message}`. Full grammar: the `Barkpark.Plugins.Sheets.Session` moduledoc.

**`sort_range`** `{op:"sort_range", tab, range:"A2:D50", keys:[{col,dir}]}` — a pure row permutation of the rect (formulas move verbatim, undo = the inverse permutation). Refusals: `sort_merge_overlap`/`sort_frozen_overlap` (rect below the frozen band)/`invalid_sort_keys`.

**Filtering** is per-viewer view-state in Studio + the `/sheets` reader (sorting is an edit mutation). Deliberately NO filter wire endpoint; adding one is a regression.

## 8c. CycleFleet — `/w/:workspace_slug/p/:project_slug/v1/cycles/:epic_id/:wave_id` [token]

Immutable Epic/Legendary ledger; scoped routes canonical, flat = projectless legacy aliases. Contract: [`cycle-fleet.md`](contracts/cycle-fleet.md).

## 9. Error Codes

All errors: `{"error":{"code","message","request_id"}}`; `request_id` mirrors `x-request-id`; `details` on `validation_failed`; optional `hint`.

Core: `not_found` 404 (doc/schema/wksp) · `unauthorized` 401 · `forbidden` 403 (perm/membership/read-only) · `schema_unknown` 404 · `precondition_failed` 412 (`details.expected`/`.actual`) · `invalid_filter` 400 · `conflict` 409 · `malformed` 400 · `validation_failed` 422 · `internal_error` 500 · `rate_limited` 429 (`Retry-After`).

`halted` 409 · `forbidden_field` 422 · `cors_forbidden`/`csrf_required` 403 · `rev_mismatch` 409 · `webhook_not_found`/`event_not_found` 404 · `duplicate_task`/`duplicate_of` 409 · `schema_has_documents`/`idempotency_key_in_use` 409 · `unsupported_if_match_for_batch` 400 · media `storage_unavailable` 503/`unsupported_media_type` 422/`payload_too_large` 413. Publish: `workspace_suspended` 403 · `quota_exceeded` 402 · `unknown_tag`/`label_spine`/`invalid_paper_structure`/`invalid_epic_paper_quality` 422; `playground_expired` 403. BPML sync create-on-push: `create_wall` 422 (publish wall refused; violations in `details`) · `slug_mismatch` 422 (BPML slug attr ≠ URL slug).

Endpoint-specific: ingest `invalid_paper`/`invalid_text`/`malformed_op`/`invalid_op`/`malformed_proposal`/`invalid_proposal`/`missing_source`/`source_not_found`/`constraint`/`bpml`/`bpml_unavailable`/`bpml_unprintable`/`unknown_format`/`hollow_paper`/`structure` · sessions `missing_slug`/`invalid_kind`/`invalid_conversation`/`conflict_retry` · sheets `malformed_ops`/`batch_too_large`/`session_unavailable`/`invalid_request_id` · media `share_expired` · deploy `build_id_mismatch`/`deploy_runner_unavailable` · grants `invalid_grant`/`unprocessable` · Chat hosts `invalid_enrollment`/`invalid_state_report` · step-up `mfa_required`/`mfa_enrolment_required` · import/export `bundle_import_disabled`/`invalid_mode`/`workspace_slug_conflict`/`blob_path_conflict`/`import_constraint_violation`/`import_failed`/`export_failed`/`import_body_read_failed`/`import_body_too_large`/`import_spill_write_failed`/`insufficient_disk_space` · chat `runtime_capacity`/`runtime_unavailable`/`chat_unsupported`/`chat_create_failed`. Source `known_codes/0`.

## 10. Legacy `/api/*` Routes

Deprecated (404 after the 2026-12-31 sunset; migrate to `/v1`): `GET/POST/DELETE /api/documents/:type[/:id]` (token), `GET /api/schemas` (public). Responses carry `Deprecation`/`Sunset`/`Link` successor headers.

## 11. Rate Limiting

Per token (or IP), read/write buckets per dataset: **300r/60w**/min (config `:rate_limits` or `BARKPARK_RATE_LIMIT_READ`/`_WRITE`). Over → `429` + `Retry-After` (§9); ticket keys per-key (§8a).
