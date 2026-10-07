<!-- doc-tier: agent | canonical-for: document-graph-and-history | budget: 650tok -->
# Document graph + history read surfaces

The `/v1/data` reads layered on the document store: backlinks, related, tags, counts and revision history. Split out of [api-v1.md](../api-v1.md) §5b/§5c. Envelope, auth markers and error codes: that doc §3, §2, §9.

All routes here are **[token]**; anonymous callers get `404`, never an empty `200`.

## Backlinks — `GET /v1/data/backlinks/:dataset/:id` [token]

Inbound refs (reverse of [api-v1.md](../api-v1.md) §5a) — docs referencing `:id` (a bare id or `{_ref: id}`): `{result:{backlinks:[<docs>], count:N}}`. Reads live draft and published schema-declared references plus projected plugin edges, one card per logical source document. Scope/visibility-filtered; out-of-tenant/hidden omitted. Public graph readers retain their published lens.

Related — `GET /v1/data/related/:dataset/:id` (`?limit=`, ≤50): weighted-tag overlap + backlinks → `{result:{related:[{doc_id,type,title,score,sources,shared_tags}],count:N}}`.

Tags — `GET /v1/data/tags/:dataset` (`?type=`, default `paper,task`): per-tag per-type published counts → `{result:{tags:[{tag,counts,total}],count}}`; `/tags/:dataset/:tag`: docs by tag strength → `result.documents:[{doc_id,type,title,strength,rationale,main_tag_match}]`.

Counts — `GET /v1/data/counts/:dataset` [token]: per-type **published** counts, one aggregate → `{ok,dataset,perspective:"published",counts:{<type>:N}}` (frozen, not `result`-wrapped). Other `?perspective` → 400 ([api-v1.md](../api-v1.md) §4).

## History [token]

`GET /v1/data/history/:dataset/:type/:doc_id` (`?limit=` default 50, ≤200; `?offset=` floor 0, uncapped; non-integer → 400 `malformed`) → `{revisions:[{id,action,rev,timestamp}], count, limit, offset, has_more, next_offset}` (`next_offset`: the next `?offset=`, or `nil`). The order key is TOTAL (`{inserted_at, id}`), so a page boundary cannot skip or duplicate a row; `has_more` is one row fetched past the page, never a second COUNT.

`GET revision/:dataset/:id` → `{revision:{rev,…content}}`, where `:id` is EITHER the revision UUID or the document `_rev` hash (disjoint shapes; a null `rev` resolves by UUID only); `POST revision/:dataset/:id/restore` restores as a draft.

Retention: revisions are kept indefinitely (`Barkpark.Content.Revisions`). Deleted content copied into `mutation_events.document` and media `webhook_deliveries.payload_snapshot` is redacted after 90 days, rows kept; off until `BARKPARK_DELETED_PAYLOAD_RETENTION=on`. Census: `mix barkpark.deleted_payload_retention`. Policy: `Barkpark.Content.DeletedPayloadRetention`.

Migrations that touch `revisions`/`documents`: [migration-safety](migration-safety.md).
