<!-- doc-tier: agent | canonical-for: groq-query-api | budget: 1500tok -->
# GROQ query API

Barkpark answers GROQ on Sanity's query API URLs, so a `@sanity/client` or `next-sanity` site keeps its queries. Code: `api/lib/barkpark/groq/`, `BarkparkWeb.GroqController`.

## Endpoint

`GET|POST /w/:workspace_slug/p/:project_slug/v{apiVersion}/data/query/:dataset` [token]

| Input | Form |
|---|---|
| `query` | GROQ text; GET query string or POST body `{"query", "params"}` |
| `$name` | GET only: one parameter, JSON-encoded (`$slug="intro"`) |
| `params` | POST only: object of decoded parameter values |
| `perspective` | `published` (default), `drafts` (`previewDrafts` alias), `raw`; a stack (`rX,drafts`) reads as its base, release ids ignored; `raw` stacked or a lone other value → 400 |
| `returnQuery` | `false` leaves `query` out |
| `resultSourceMap` | `true`/`withKeyArraySelector`: Sanity's map, pass-through functions too |

Any `apiVersion`. Auth, tenancy and shares: the scoped document reads' ([api-v1.md](../api-v1.md) §2). A caller pinned to published reads (a share, `public-read`) gets `published`. No token, unshared dataset: 403 (Sanity: 200, empty). POST bills the read bucket. GET over 32,753 bytes: 414, use POST.

Response: `{"query", "result", "ms", "syncTags"}`. Documents carry `_id`, `_type`, `_rev`, `_createdAt`, `_updatedAt`, `title` and content at the top level, field-redacted. No title, no `title` key. `drafts` overlays a draft on its published twin (`_id` published, plus `_originalId`); `raw` returns `drafts.<id>` too.

Writes: [sanity-mutate.md](sanity-mutate.md). `GET …/v{apiVersion}/data/doc/:dataset/:id[,id…]` (`getDocument(s)`) is `*[_id in ids]` as `raw`: `{"documents", "omitted"}`, a missing id omitted (`existence`).

Errors keep Barkpark's envelope plus Sanity's `description`, `statusCode` and `message`, and `type`: `queryParseError` (400 `malformed`, plus `query`, `start`, `end`), `queryLimitError` or `queryEvaluationError` (422 `bad_request`), `queryBusyError` (503, `Retry-After`). A missing parameter is a syntax error, as on Sanity.

## Client configuration

```ts
import {createClient} from '@sanity/client'

const client = createClient({
  projectId: 'barkpark', // any value
  dataset: 'production',
  apiHost: 'https://<host>/w/<workspace>/p/<project>',
  useProjectHostname: false,
  apiVersion: '2025-02-19',
  useCdn: false,
  token: process.env.BARKPARK_READ_TOKEN,
})
```

## Sync tags

`bp:ds:<dataset>:type:<type>` for every type a `*[...]` scanned, `bp:ds:<dataset>:doc:<id>` for every document read by id (`_id ==`, `->`) whose type was not scanned, and `bp:ds:<dataset>:_all` for a scan with no `_type` or `_id` filter (add `_type` to narrow). Webhooks send them too ([webhook-realtime.md](webhook-realtime.md)). Each has an opaque `s1:` twin: `GET …/v{apiVersion}/data/live/events/:dataset` (`live.events()`; token or member, 20 streams each, then `goaway`) sends changed docs' twins in `{"tags"}` messages per second; `restart` if `Last-Event-ID` can't resume. Draft mode only for now: the client sends no token without `includeDrafts`, and anonymous streams await the owner. At most 128 tags: past 64 readable ones, type tags only.

## Evaluation and limits

Top-level conditions of each `*[...]` become SQL, `^` included: `_type`, `_id`, a field `==`, `!=`, `<`, `<=`, `>`, `>=` a scalar, `$x in field[].value`, `references()`, `count(field)` against an integer, `defined()`, `count(field[cond]) > 0` for element `==` and `in`, `!` of `defined()`, `==`, `in` and that count, and an `||` of them. The evaluator then applies the whole filter. `count(*[...])` is a SQL count when its filter has only these, except `references()` and `title`, and the caller sees every field it tests; any other is counted in chunks. A slice (`[n]`, `[a...b]`, no negative bound) of a `*[...]` without `^`, ordered or not, reads only what it returns: in SQL when `count()` would be, else in chunks. `->` and subqueries read in rounds.

| Limit | Default | Config key (`config :barkpark, Barkpark.Groq`) |
|---|---|---|
| Query text | 256 KiB | `:max_query_bytes` |
| Wall time | 10 s | `:timeout_ms` |
| Evaluator heap | 512 MiB | `:max_heap_bytes` |
| Documents one `*[...]` loads | 10 000 | `:max_documents_per_fetch` |
| Stored content one `*[...]` loads | 32 MiB | `:max_bytes_per_fetch` |
| Documents one query loads | 25 000 | `:max_documents_loaded` |
| Encoded result | 10 MiB | `:max_result_bytes` |
| Queries at once | ½ RAM ÷ heap, ≤ 2 per CPU | `:max_concurrent` |
| Slot wait, then 503 | 5 s | `:queue_ms` |

## Moving from Sanity

Supported: the GROQ-1 grammar (filters, projections, `...`, `->`, `^`, `@`, slices, `| order()`, `| score()`, `select()`, ranges, `match`, `in`, arithmetic) and functions `coalesce`, `count`, `dateTime`, `defined`, `identity`, `length`, `lower`, `upper`, `now`, `path`, `references`, `round`, `string`, `string::split`, `string::startsWith`, `array::join`, `array::compact`, `array::unique`, `array::intersects`, `math::min|max|sum|avg`, `dateTime::now`, `pt::text`, `sanity::projectId|dataset|versionOf|partOfRelease`, `releases::all`, `documents::get` (own dataset), `geo::latLng|distance`, `fn` (400 on a cycle or over 1000 calls expanded), `diff::changedAny|changedOnly` (≤ 100 selector steps). Sanity's GROQ suite (`groq/conformance_test.exs`, CI): all 7731 pass.

Not yet: `geo::contains|intersects`, `text::query`, other `documents::`, `delta::`, `user::`; releases. Before 2025-02-19 Sanity defaults to `raw`, Barkpark to `published`.

`score()` weighs as groq-js; multi-term ranks can differ.

Read compat (declared fields): a bare-id reference answers `->`, `_ref`, `_type`, `_weak`, `references()`; a slug string `.current`; an object-array item `_type` (stored, else `kind`, else member name); a richText body `pt::text()` (its wikilinks are not `references()` yet). `order()` is exact where every type in scope declares the field, else a bare value sorts as missing.
