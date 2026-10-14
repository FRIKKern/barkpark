<!-- doc-tier: agent | canonical-for: document-view-counts | budget: 1800tok -->
# Document view counts and popularity

A site records views of its documents. Barkpark counts them per document per day and keeps 7-day and 30-day sums and a decayed score. GROQ, the query API and search read those numbers, so a site can list its most viewed documents without an analytics service. Code: `Barkpark.Search.Views` (`api/lib/barkpark/search/views.ex`).

## Record a view

`POST /w/:workspace_slug/p/:project_slug/v1/data/views/:dataset`

| Field | Notes |
|---|---|
| `id` | One document id. A `drafts.` prefix is stripped. |
| `ids` | Up to 50 ids, as a JSON list or a comma-separated string. |
| `visitor` | Token callers only. An opaque value naming one visitor for the day, such as a hash of the site's session id. |

The fields may ride the JSON body or the query string, so `navigator.sendBeacon(url + "?id=" + id)` works. The answer is `202 {"ok": true, "accepted": n, "duplicates": d}`. A missing id or more than 50 is `422 validation_failed`; an unknown dataset is `404`.

Access is the same as reading the scope's documents. A token of the workspace (a read token is enough) may record. An anonymous browser may record only when the scope has a `:docs` share because `RequireShareScope` admits POST on this one route. Rate limit: 60 views a minute per anonymous IP (`:rate_limits, view_per_minute`) and 6000 per token (`view_token_per_minute`), per dataset; over that, `429` with `Retry-After`.

An id that is not a published document of the dataset is accepted and then dropped when the buffer is written, so a caller cannot fill the tables with made-up ids.

## Dedupe and privacy

A visitor counts once per document per UTC day. The dedupe key is the first 16 bytes of SHA-256 over a random salt for the day and the visitor material. That material is the token caller's `visitor`, or else the client IP and user agent. Anonymous callers cannot set `visitor`, so a script cannot pick a new visitor per request.

The salt and the keys live only in ETS (`Barkpark.Search.Views.Buffer`). The salt is created for each day and deleted with that day's keys, so a key cannot be recomputed later. The database holds no IP address, user agent or key. `document_view_days` has `dataset_id, doc_id, day, type, views` and `document_popularity` has the sums. A restart forgets the day's keys, so a visitor may count twice on that day.

## Storage and jobs

- The request counts in ETS and returns. Every 5 s (`:flush_interval_ms`) the buffer adds its counts to `document_view_days` with one upsert per dataset. A view never writes the document.
- `Barkpark.Search.Workers.ViewsRollup` runs every 10 minutes (Oban cron). It rewrites `document_popularity` from the last 30 days: `views_7d` (today and the 6 days before, UTC), `views_30d`, and `score`, each day's views halved per 7 days of age. Documents with no view in 30 days leave the table. Day rows older than 90 days are deleted.
- Numbers lag views by up to the flush interval plus 10 minutes. Webhooks do not fire on new counts, so a cached page shows its old order until it revalidates.

Both tables cascade from `datasets`, so deleting a dataset, project or workspace deletes its counts.

## Read the counts

In GROQ, a query that names `_views7d`, `_views30d` or `_popularity` gets all three on every document it reads, 0 for a document with no views. A draft reads its published document's counts. `order()` on them and `_views30d > n` (also `<`, `<=`, `>=`, `==`, and the other two fields) run in SQL; other conditions run in memory as usual.

```groq
*[_type == "productSearch" && _views30d > 100] | order(_views30d desc)[0...20]{_id, Title, _views30d}
```

The sort left-joins `document_popularity` once. A comparison is a semi-join on it: `IN` when 0 fails the comparison, `NOT IN` of the failing rows when 0 passes.

The query API sorts with `order=popularity:desc`, which is the score, or with `_popularity`, `_views7d` or `_views30d` and `:asc|desc`. `popularity` was a content-field sort before; reach a content field of that name as `content.popularity:desc`.

Document search with `GET …/v1/data/search/:dataset?q=…&boost=popularity` adds `0.1 * score / (score + 10)` to relevance. `:boost_weight` sets the 0.1. That is the scale of the tag boost, so views reorder close matches and do not lift a weak match over a strong one. Other `boost` values are `400 malformed`. Indx ignores it.

## Measured

A copy of the local gyldendal.no twin database (18,020 `product`, 10,592 `productSearch`) on a branch server, port 4101, dev mode, on a Mac that other jobs kept at load 15 to 40. Request medians of 7 runs include about 150 to 300 ms that any request paid on that box; a plain `*[_type == "product"][0...20]{_id}` took 295 ms and `order(_updatedAt desc)` 188 ms.

| What | Result |
|---|---|
| 10,000 view POSTs, 8 in parallel, 3,000 ids | all 202; every view reached `document_view_days` at the next flush; p50 324 ms, the same as a trivial GROQ read on that box |
| Rollup, 831,571 day rows, 28,612 documents | 0.9 to 1.4 s |
| SQL: top 20 of 18,020 products by `views_30d` | 36 ms with the join (190 ms with a lookup per row) |
| SQL: `_views30d > 100` over 10,592 books | 18 ms |
| GROQ top 20 products by `_views30d` | 255 ms |
| GROQ `_views30d > 100`, top 20 | 164 ms |
| GROQ twin filters on the 300 most viewed books, top 16 | 456 ms |
| GROQ twin filters on every viewed book, top 16 | 4,645 ms |
| GROQ twin stand-in today (300 newest, by reviews) | 673 ms |
| `order=popularity:desc`, 20 products | 168 ms |
| search `q=krim`, with and without `boost=popularity` | 232 ms, 218 ms |

For a filtered top list, take a SQL slice of the most viewed books first and apply the filters that do not narrow in SQL to that slice.

```groq
(*[_type == "productSearch" && PublicationStatus == "04"] | order(_views30d desc)[0...300])
  [IsHidden != true && ...] | order(_views30d desc)[0...16]
```

Putting `!=` filters beside `_views30d > 0` over every viewed book runs them in memory over thousands of documents (4.6 s above).

## Code anchors

- `api/lib/barkpark/search/views.ex` — def record, def flush, def rollup, def join_popularity, def sql_condition
- `api/lib/barkpark/search/views/buffer.ex` — def visitor_key, def add
- `api/lib/barkpark_web/controllers/views_controller.ex` — def record
- `api/lib/barkpark/search/workers/views_rollup.ex` — def perform
- `api/priv/repo/migrations/20261014120000_create_document_views.exs`
