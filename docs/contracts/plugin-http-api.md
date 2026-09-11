<!-- doc-tier: agent | canonical-for: plugin-http-api | budget: 700tok -->
# Plugin HTTP surfaces — Tickets, Sheets, Bulldocs

Plugin `/v1` endpoints (envelope, auth, error codes: [api-v1.md](../api-v1.md) §2, §3, §9). Authoring: `docs/cards/plugins.md`; Sheets: [sheets-engine.md](sheets-engine.md).

## Tickets — `/v1/tickets`

A **`bptk_` key IS an identity**: minted per outsider, who files/reads tickets with only it. Plugin-gated. `status` is **server-derived**: `open` = operator's move, `answered` = submitter's; a submitter reply auto-reopens, an operator close → `closed`.

| Persona (auth) | Routes (`/v1` prefix) |
|---|---|
| Submitter (`bptk_`) | `POST /tickets` · `GET /tickets[/:id]` (stamps `submitter_seen_at`) · `POST /tickets/:id/{messages,attachments}` · `GET /tickets/:id/attachments/:asset_id` |
| Operator (bearer) | `GET /tickets/inbox[/:id[/attachments/:asset_id]]` (open first) · `POST /tickets/:id/answer` `{body,close?}` · `POST /tickets/:id/close` |
| Admin (`/v1/plugins/tickets/keys`) | `POST` mint · `GET` ls · `POST /:id/{rotate,pause,unpause}` · `DELETE /:id` revoke |

**Auth.** A `bptk_` key is refused by every non-ticket route (tier `"none"` in `/v1/capabilities`). **Paused** → `403` `key paused` (reversible); **revoked** → `401`; **rotate** = new secret, same identity row.

**Attachments** (submitter-only): MIME from magic bytes (client header ignored); allowlist `png/jpeg/gif/webp/pdf/txt/log/zip`, ≤10 MB/file, ≤10/ticket; foreign → `404`. **Write limits**/key (reads exempt): create 10/hr, message 60/hr, attachment 30/hr; over → `429` + `Retry-After` (§9). **Mint** returns the raw key **once** + `quickstart` curls.

## Sheets — `POST /v1/plugins/sheets/:slug/ops` [admin]

Body `{"ops":[…]}` (`?dataset=`, default `production`); `BARKPARK_INGEST_TOKEN` also authorizes. Ops apply INDIVIDUALLY, not atomically — a refused op lands in the 200's `errors` as `{index,code,message}`. Grammar: the `Barkpark.Plugins.Sheets.Session` moduledoc.

**`sort_range`** `{op:"sort_range", tab, range:"A2:D50", keys:[{col,dir}]}` — a pure row permutation of the rect (formulas move verbatim; undo = the inverse). Refuses: `sort_merge_overlap`/`sort_frozen_overlap` (rect below the frozen band)/`invalid_sort_keys`.

**Filtering** is per-viewer view-state in Studio + the `/sheets` reader (sorting is an edit mutation). Deliberately NO filter wire endpoint; adding one is a regression.

## Bulldocs — `POST /v1/plugins/bulldocs/papers/:slug/ops`

An **edit** door: `AuthoringWall.enforce/5` does NOT run here (ruled). Its whole contract is two ratchets in `BlockOps` — `ratchet_hollow/2` and `reject_new_field_loss/2`. The five gates are publish-time FLOORS. Reasons + caveat: `bulldocs_ops_door_edit_contract_test.exs`.
