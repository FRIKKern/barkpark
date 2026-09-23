<!-- doc-tier: agent | canonical-for: plugin-http-api | budget: 700tok -->
# Plugin HTTP surfaces — Tickets, Sheets, Bulldocs

`/v1` envelope/auth/errors: [api-v1.md](../api-v1.md) §2/3/9. Authoring: `docs/cards/plugins.md`; Sheets: [engine](sheets-engine.md).

## Tickets — `/v1/tickets`

Plugin-gated; each outsider's **`bptk_` key is their identity**. Server-derived status: `open` = operator's turn, `answered` = submitter's. Submitter reply reopens; operator close → `closed`.

| Persona (auth) | Routes (`/v1` prefix) |
|---|---|
| Submitter (`bptk_`) | `POST /tickets` · `GET /tickets[/:id]` (stamps `submitter_seen_at`) · `POST /tickets/:id/{messages,attachments}` · `GET /tickets/:id/attachments/:asset_id` |
| Operator (bearer) | `GET /tickets/inbox[/:id[/attachments/:asset_id]]` (open first) · `POST /tickets/:id/answer` `{body,close?}` · `POST /tickets/:id/close` |
| Admin (`/v1/plugins/tickets/keys`) | `POST` mint · `GET` ls · `POST /:id/{rotate,pause,unpause}` · `DELETE /:id` revoke |

Non-ticket routes refuse `bptk_` (capabilities tier `"none"`). Paused → reversible 403 `key paused`; revoked → 401; rotate changes secret, preserves identity.

Submitter attachments: magic-byte MIME, not client header; `png/jpeg/gif/webp/pdf/txt/log/zip`, ≤10 MB/file, ≤10/ticket; foreign → 404. Per-key limits: create 10/hr, message 60/hr, attachment 30/hr; reads exempt; excess → 429 + `Retry-After`. Mint returns the raw key once + `quickstart` curls.

## Sheets — `POST /v1/plugins/sheets/:slug/ops` [admin]

Body `{"ops":[…]}` (`?dataset=`, default `production`); ingest token also authorizes. Ops apply individually; refusals appear in 200's `errors` as `{index,code,message}`. Grammar: `Barkpark.Plugins.Sheets.Session`.

**`sort_range`** `{op:"sort_range", tab, range:"A2:D50", keys:[{col,dir}]}` — a pure row permutation of the rect (formulas move verbatim; undo = the inverse). Refuses: `sort_merge_overlap`/`sort_frozen_overlap` (rect below the frozen band)/`invalid_sort_keys`.

Filtering is per-viewer Studio/reader state; sorting edits data. No filter wire endpoint.

## Bulldocs — `POST /v1/plugins/bulldocs/papers/:slug/ops`

Editing runs `BlockOps.ratchet_hollow/2` + `reject_new_field_loss/2`, not `AuthoringWall.enforce/5`; its five gates are publish-time floors. Rationale: `bulldocs_ops_door_edit_contract_test.exs`.

**Create:** `POST /v1/plugins/bulldocs/papers/:slug/create` [ingest]: native `blocks` + metadata → 201 slug/rev. Same scope/wall; existing published/draft → 409 `paper_exists`. Insert-only; no HTML/BPML/revision-fence input. Lost replies require scoped content readback. Concurrent generic draft writers are not namespace-reserved. `/papers` remains upsert.
