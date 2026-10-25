<!-- doc-tier: agent | canonical-for: document-graph-and-history | budget: 650tok -->
# Document graph + history read surfaces

`/v1/data` reads; envelopes/auth/errors: [api-v1.md](../api-v1.md) §3/2/9. Flat routes require tokens; anonymous callers get `404`.

Under `/w/:ws/p/:proj`, history, revision, schedules and doc-actions GETs also accept a seated personal bearer (not cookie-, grant- or share-only callers); token policies and write gates are unchanged. Personal schedule rows need a readable draft; a readable published twin is not enough.

## Backlinks — `GET /v1/data/backlinks/:dataset/:id` [token]

Live schema-declared refs (draft + published) + projected plugin edges → `{result:{backlinks:[<docs>],count:N}}`, one card per source; bare ids or `{_ref:id}`. Access rules apply to both; `via_field` is a readable matching field. Public graph: published-only. Many: `/backlinks/:dataset?ids=a,b` (≤100) → `result.byId.<id>`. Counts: `/backlink-counts/:dataset?ids=` (≤100, `?type=`) → `byId.<id>:N`, `source:"schema"`: declared refs, nested, no plugin edges.

Related — `GET /v1/data/related/:dataset/:id` (`?limit=`, ≤50): weighted-tag overlap + backlinks → `{result:{related:[{doc_id,type,title,score,sources,shared_tags}],count:N}}`.

Tags — `GET /v1/data/tags/:dataset` (`?type=`, default `paper,task`): published counts → `{result:{tags:[{tag,counts,total}],count}}`; `/tags/:dataset/:tag` → `result.documents:[{doc_id,type,title,strength,rationale,main_tag_match}]`.

Counts — `GET /v1/data/counts/:dataset` [token]: published-only aggregate → `{ok,dataset,perspective:"published",counts:{<type>:N}}` (not `result`-wrapped). Other `?perspective` → 400 ([api-v1.md](../api-v1.md) §4).

## History [token]

`GET /v1/data/history/:dataset/:type/:doc_id` (`?limit=` default 50, ≤200; `?offset=` floor 0, uncapped; noninteger → 400 `malformed`) → `{revisions:[{id,action,rev,timestamp}],count,limit,offset,has_more,next_offset}`. Order `{inserted_at,id}`; `has_more` from one extra row; `next_offset` or nil.

`GET revision/:dataset/:id` → `{revision:{rev,…content}}`; id is a revision UUID or a `_rev` hash (null rev: UUID only). `POST revision/:dataset/:id/restore` restores a draft.

Revisions are kept. Deleted payloads in `mutation_events.document` and `webhook_deliveries.payload_snapshot` redact after 90 days (rows kept) with `BARKPARK_DELETED_PAYLOAD_RETENTION=on`. Census: `mix barkpark.deleted_payload_retention`; policy: `Barkpark.Content.DeletedPayloadRetention`.

Schema changes: [migration-safety](migration-safety.md).
