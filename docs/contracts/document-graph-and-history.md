<!-- doc-tier: agent | canonical-for: document-graph-and-history | budget: 650tok -->
# Document graph + history read surfaces

The `/v1/data` reads layered ON TOP of the document store — inbound references, weighted-tag relatedness, tag rollups, per-type counts, and the revision log. Split out of [api-v1.md](../api-v1.md) §5b/§5c (which kept §5a, forward reference expansion, because `GET .../doc/...` takes `?expand=` inline). Envelope, auth markers and error codes: that doc §3, §2, §9.

All routes here are **[token]**; anonymous callers get `404`, never an empty `200`.

## Backlinks — `GET /v1/data/backlinks/:dataset/:id` [token]

Inbound refs (reverse of [api-v1.md](../api-v1.md) §5a) — docs referencing `:id`: `{result:{backlinks:[<docs>], count:N}}`. Scope/visibility-filtered; out-of-tenant/hidden omitted.

Related — `GET /v1/data/related/:dataset/:id` (`?limit=`, ≤50): weighted-tag overlap (Σ `LEAST(src,cand)/100` + main_tag bonus) + backlinks → `{result:{related:[{doc_id,type,title,score,sources,shared_tags}],count:N}}`. Anon 404.

Tags — `GET /v1/data/tags/:dataset` (`?type=`, default `paper,task`): per-tag per-type published counts → `{result:{tags:[{tag,counts,total}],count}}`; `/tags/:dataset/:tag`: docs by tag strength (legacy flat last) → `result.documents:[{doc_id,type,title,strength,rationale,main_tag_match}]`. Anon 404.

Counts — `GET /v1/data/counts/:dataset` [token]: per-type **published** counts, one aggregate → `{ok,dataset,perspective:"published",counts:{<type>:N}}` (frozen, not `result`-wrapped). Anon 404. Published-only; other `?perspective` → 400 ([api-v1.md](../api-v1.md) §4).

## History [token]

Under `/v1/data`: `GET history/:dataset/:type/:doc_id` → `{revisions:[{id,action,rev,timestamp}], count}`; `GET revision/:dataset/:id` → `{revision:{rev,…content}}`, where `:id` is EITHER the revision UUID or the document `_rev` hash (disjoint shapes; a null `rev` resolves by UUID only); `POST revision/:dataset/:id/restore` restores as a draft.
