<!-- doc-tier: agent | canonical-for: search-query-semantics | budget: 1500tok -->
# Search query semantics

What `GET …/v1/data/search/:dataset?q=` matches, how it ranks, and the parameters that narrow it. Routes and auth: [api-v1.md](../api-v1.md) and [INTELLIGENCE.md](../search/INTELLIGENCE.md).

## Words

- Every word must match (`match=all`, the default). `match=any` asks for one word. When `all` finds nothing, the pipeline widens typos under `all`, then runs `any`, and says so: `recovery: "match_any"`, `match: "any"`. The response field `match` names the rule that served the hits.
- A synonym is an alternative to its word, never one more required word.
- The last word is the word being typed. With 2 or more letters it also matches as a prefix. A last word of 1 letter after other words is left out of the match (no trigram to probe); it picks the ranking pool, so titles with a word starting with it rank first.
- An English stop word ("i", "the") is dropped when other words remain.
- Norwegian fold: each word also matches every spelling the fold maps to it (`knausgard`, `knausgaard` and `knausgård` find each other; `nesbo` finds `Nesbø`), in every field.

## Search slots

The index weights a title slot 'A' and an author slot 'B'. A schema names them with the field key `search`: `"search": "title"` or `"search": "author"`. Without it the title slot is the `title` column; for a type with no title, the `list_preview.title` field, else the first declared field among `name`, `displayName`, `label`, `heading`, `headline`. The author slot is `content.author` plus the declared `Author`/`Authors` fields. A trigger keeps `documents.search_title`/`search_author` current on every write; a bundle import refreshes them after it commits (`Barkpark.Search.SearchSlots.refresh/1`). Every row written since migration 20261016190000 also stores its folded names and names vector (a row without a slot, those of its `title`), so a search reads them instead of folding each title; older rows get them from the operator step `mix barkpark.search.fill_title_folds --apply`.

A schema change recomputes the slots and the public vector only when it changes what they read: the fields above and their `search` keys, `list_preview.title`, or a restriction. A type with at most 1,000 documents is recomputed in the schema write. A larger one is recomputed after it, in batches of 500, by `Barkpark.Search.Workers.SearchRefresh`. Until that is done after a change that made a field restricted, non-admin text searches leave the type's documents out; a browse still lists them.

## Two steps

1. Whole words through the full-text GIN index, the typed word as a word start of the title or author names (trigram index), and the document id.
2. Only when step 1 finds nothing: the typed word as a prefix anywhere, substrings of the title and slug, and near misses of the title (`%` at the surface's `similarity_threshold`, `<%` at 0.6 or that threshold if higher).

The search runs in one transaction that sets those trigram thresholds, `random_page_cost = 1.1` and `enable_seqscan = off` for itself only.

## Ranking

Exact id, then the title equal to the query, then a score: the full-text rank; the share of words that start a word of the title or an author (0.6 inside a title word); 0.5 x the share that are a whole word there; for two or more words, 0.5 when the title starts with the query, 0.25 when it holds it, 0.3 when the document holds the words next to each other; on step 2 only, the `searchable_fields` trigram similarity; the tag boost. Then recency. The 500-row ranking pool is chosen by the word-start share, then recency, and always holds the requested page.

## Parameters

| Param | Meaning |
|---|---|
| `match` | `all` (default) or `any`. Else 400. |
| `suggest=true` | Type-ahead: no facets, no recovery pass, a 100-row pool, no read of the stored vector. `count` stays exact. |
| `filter[...]` | The query API's field filters ([query-surface-limits.md](query-surface-limits.md)), applied before the limit, the count and the facets. Needs `type`. |
| `facet=a,b` | Up to 10 top-level content fields: value counts over the filtered match in `facets.fields.<name>`, at most 100 values, biggest first. Needs `type`; a field the caller may not read is `forbidden_field`. |
| `limit`, `offset` | `limit` 1 to 200. `offset` pages through the whole match set; `count` is exact. |
| `preview=1` | Each hit gains `_preview`: the `subtitle`, `description` and `media` its type's `list_preview` declares, as a Studio desk row shows them (`HitPreview`). Referenced documents are rendered for the caller first. No previews for an anonymous caller. |

## Code anchors

- api/lib/barkpark/search/documents_retriever.ex — def search
- api/lib/barkpark/search/query_pipeline.ex — defp recover_documents
- api/lib/barkpark/search/search_slots.ex — def refresh
- api/lib/barkpark/search/search_refresh.ex — def drain
- api/lib/barkpark/search/fold.ex — def variants
- api/priv/repo/migrations/20261014150000_add_documents_search_slots.exs
- api/priv/repo/migrations/20261016190000_store_title_search_folds.exs
