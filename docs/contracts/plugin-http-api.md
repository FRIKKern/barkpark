<!-- doc-tier: agent | canonical-for: plugin-http-api | budget: 700tok -->
# Plugin HTTP surfaces — Tickets and Sheets ops

The two plugin-owned `/v1` endpoints that were §8a/§8b of [api-v1.md](../api-v1.md) (envelope, auth markers and error codes: that doc §2, §3, §9). Plugin authoring: `docs/cards/plugins.md`; Sheets semantics: [sheets-engine.md](sheets-engine.md).

## Tickets plugin — `/v1/tickets`

A **`bptk_` key IS an identity**: minted per outsider, who files/reads tickets with only that key. Plugin-gated. `status` is **server-derived**: `open` = operator's move, `answered` = submitter's; a submitter reply auto-reopens, an operator close → `closed`.

| Persona (auth) | Routes (`/v1` prefix) |
|---|---|
| Submitter (`bptk_`) | `POST /tickets` · `GET /tickets[/:id]` (stamps `submitter_seen_at`) · `POST /tickets/:id/{messages,attachments}` · `GET /tickets/:id/attachments/:asset_id` |
| Operator (bearer) | `GET /tickets/inbox[/:id[/attachments/:asset_id]]` (open first) · `POST /tickets/:id/answer` `{body,close?}` · `POST /tickets/:id/close` |
| Admin (`/v1/plugins/tickets/keys`) | `POST` mint · `GET` ls · `POST /:id/{rotate,pause,unpause}` · `DELETE /:id` revoke |

**Auth.** A `bptk_` key is refused by every non-ticket route (tier `"none"` in `/v1/capabilities`). **Paused** → `403` `key paused` (reversible); **revoked** → `401` (as no token); **rotate** = new secret, same identity row.

**Attachments** (submitter-only): MIME from magic bytes (client header ignored); allowlist `png/jpeg/gif/webp/pdf/txt/log/zip`, ≤10 MB/file, ≤10/ticket; foreign → `404`. **Write limits**/key (reads exempt): create 10/hr, message 60/hr, attachment 30/hr; over → `429` + `Retry-After` (§9). **Mint** returns the raw key **once** + `quickstart` curls.

## Sheets plugin — `POST /v1/plugins/sheets/:slug/ops` [admin]

Body `{"ops":[…]}` (`?dataset=`, default `production`); the `BARKPARK_INGEST_TOKEN` shared secret also authorizes. Ops apply INDIVIDUALLY, not atomically — a refused op lands in the 200's `errors` as `{index,code,message}`. Full grammar: the `Barkpark.Plugins.Sheets.Session` moduledoc.

**`sort_range`** `{op:"sort_range", tab, range:"A2:D50", keys:[{col,dir}]}` — a pure row permutation of the rect (formulas move verbatim; undo = the inverse). Refusals: `sort_merge_overlap`/`sort_frozen_overlap` (rect below the frozen band)/`invalid_sort_keys`.

**Filtering** is per-viewer view-state in Studio + the `/sheets` reader (sorting is an edit mutation). Deliberately NO filter wire endpoint; adding one is a regression.
