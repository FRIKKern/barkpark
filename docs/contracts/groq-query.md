<!-- doc-tier: agent | canonical-for: groq-query-api | budget: 1500tok -->
# GROQ query API

Barkpark answers GROQ on the URL scheme of Sanity's HTTP query API, so a `@sanity/client` or `next-sanity` site can point at Barkpark and keep its queries. Code: `api/lib/barkpark/groq/` (parser, evaluator, document source), `BarkparkWeb.GroqController`.

## Endpoint

`GET|POST /w/:workspace_slug/p/:project_slug/v{apiVersion}/data/query/:dataset` [token]

| Input | Form |
|---|---|
| `query` | GROQ text; GET query string or POST body `{"query", "params"}` |
| `$name` | GET only: one parameter, JSON-encoded (`$slug="intro"`) |
| `params` | POST only: object of decoded parameter values |
| `perspective` | `published` (default, any apiVersion), `drafts` (`previewDrafts` is an alias), `raw`; other values → 400 |
| `returnQuery` | `false` leaves `query` out of the response |

Any `apiVersion` is accepted. Auth, tenancy and share access are those of the scoped document reads ([api-v1.md](../api-v1.md) §2). A caller pinned to published reads (no token, a share, a `public-read` token) gets `published` regardless. POST bills the read bucket. A GET target over 32,753 bytes gets an empty 414; use POST.

Response: `{"query", "result", "ms", "syncTags"}`. Documents have `_id`, `_type`, `_rev`, `_createdAt`, `_updatedAt`, `title` and their content fields at the top level; field visibility redaction applies. `title` comes from the `documents.title` column (`title == "x"` matches it); no title, no `title` key. `drafts` overlays a draft on its published twin (`_id` published, plus `_originalId`); `raw` returns `drafts.<id>` rows as stored.

Errors keep Barkpark's envelope plus Sanity's `description` and `type`: a syntax error is 400 `malformed` with `type: "queryParseError"`, `query`, `start`, `end`; a limit is 422 `bad_request` with `type: "queryLimitError"`; an unsupported function is 422 `bad_request` with `type: "queryEvaluationError"`. A parameter the query uses but the request lacks is a syntax error, as on Sanity.

## Client configuration

```ts
import {createClient} from '@sanity/client'

const client = createClient({
  projectId: 'barkpark', // any value; needed to send perspective
  dataset: 'production',
  apiHost: 'https://<host>/w/<workspace>/p/<project>',
  useProjectHostname: false,
  apiVersion: '2025-02-19',
  useCdn: false,
  token: process.env.BARKPARK_READ_TOKEN,
})
```

`next-sanity` takes the same options.

## Sync tags

`bp:ds:<dataset>:type:<type>` for every type a `*[...]` scanned, and `bp:ds:<dataset>:doc:<id>` for every document read by id (`_id ==`, `->`) whose type was not scanned. The webhook dispatcher sends the same tags on each mutation ([webhook-realtime.md](webhook-realtime.md)), so `revalidateTag` refreshes every cached query that read the changed document. At most 128 tags; beyond that, type tags only.

## Evaluation and limits

Top-level conditions of each `*[...]` become SQL, `^` values included: `_type`, `_id`, a field `==`, `!=`, `<`, `<=`, `>`, `>=` a scalar, `$x in field[].value`, `references()`, `count(field)` against an integer, `defined()`, `count(field[cond]) > 0` for element `==` and `in`, `!` of `defined()`, `==`, `in` and that count, and an `||` of them; a branch reading only `^` that is false for the parent is skipped. GIN indexes over `content` and its `_ref` values serve them; the evaluator then applies the whole filter. `count(*[...])` is a SQL count when its filter has none but these, apart from `references()`, `title` and `$x in field[].value`, and the caller sees every field it tests; any other is counted in chunks, limited only by wall time. A slice (`[n]`, `[a...b]`, no negative bound) of a `*[...]` without `^`, ordered or not, reads only what it returns: in SQL when `count()` would be, else in chunks. Dereferences and subqueries read in rounds, one SQL read per `->` level and subquery shape. A subquery not reading `^` runs once per query.

| Limit | Default | Config key (`config :barkpark, Barkpark.Groq`) |
|---|---|---|
| Query text | 256 KiB | `:max_query_bytes` |
| Wall time | 10 s | `:timeout_ms` |
| Evaluator heap | 512 MiB | `:max_heap_bytes` |
| Documents one `*[...]` loads | 10 000 | `:max_documents_per_fetch` |
| Stored content one `*[...]` loads | 32 MiB | `:max_bytes_per_fetch` |
| Documents one query loads | 25 000 | `:max_documents_loaded` |
| Encoded result | 10 MiB | `:max_result_bytes` |

## Moving from Sanity

Supported: the GROQ-1 grammar (filters, projections, `...`, `->`, `^`, `@`, slices, `| order()`, `| score()`, `select()`, ranges, `match`, `in`, arithmetic) and the functions `coalesce`, `count`, `dateTime`, `defined`, `identity`, `length`, `lower`, `upper`, `now`, `path`, `references`, `round`, `string`, `string::split`, `string::startsWith`, `array::join`, `array::compact`, `array::unique`, `array::intersects`, `math::min|max|sum|avg`, `dateTime::now`, `pt::text`, `sanity::projectId|dataset|versionOf|partOfRelease`, `releases::all`, `documents::get` (own dataset). Sanity's GROQ test suite runs in CI (`api/test/barkpark/groq/conformance_test.exs`): 7147 of 7731 cases pass; the rest use `diff::` or custom `fn`.

Not yet: `diff::changedAny|changedOnly`, `fn` custom functions, `geo::`, `text::query`, other `documents::`, `delta::`, `user::`; release and version perspectives; `resultSourceMap`; the Live Content API (`/data/live/events`). Sanity defaults to `raw` before 2025-02-19, Barkpark always to `published`: an older client needing drafts asks for `perspective: 'raw'`.

`score()` weighs as groq-js; Sanity's hosted engine also favours rarer terms and shorter fields, so multi-clause ranks can differ.

Read compat: a declared reference stored as a bare id answers `->`, `_ref`, `_type`, `references()`; a declared slug string `.current`. `order()` is exact where every type in scope declares the field, else a bare value sorts as missing.

`tooling/groq/compare.mjs` (dev only) diffs a query corpus between groq-js and this endpoint.
