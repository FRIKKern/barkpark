<!-- doc-tier: agent | canonical-for: groq-query-api | budget: 1500tok -->
# GROQ query API

Barkpark answers GROQ on Sanity's HTTP query API URLs, so a `@sanity/client` or `next-sanity` site keeps its queries. Code: `api/lib/barkpark/groq/`, `BarkparkWeb.GroqController`.

## Endpoint

`GET|POST /w/:workspace_slug/p/:project_slug/v{apiVersion}/data/query/:dataset` [token]

| Input | Form |
|---|---|
| `query` | GROQ text; GET query string or POST body `{"query", "params"}` |
| `$name` | GET only: one parameter, JSON-encoded (`$slug="intro"`) |
| `params` | POST only: object of decoded parameter values |
| `perspective` | `published` (default), `drafts` (`previewDrafts` alias), `raw`; a stack (`rX,drafts`) reads as its base, release ids ignored; `raw` stacked or a lone other value → 400 |
| `returnQuery` | `false` leaves `query` out of the response |

Any `apiVersion`. Auth, tenancy and shares are those of the scoped document reads ([api-v1.md](../api-v1.md) §2). A caller pinned to published reads (a share, `public-read`) gets `published`. No token on an unshared dataset: 403 (Sanity: 200, empty), kept. POST bills the read bucket. A GET over 32,753 bytes is 414; use POST.

Response: `{"query", "result", "ms", "syncTags"}`. Documents carry `_id`, `_type`, `_rev`, `_createdAt`, `_updatedAt`, `title` and content fields at the top level, redacted per field visibility. No title, no `title` key. `drafts` overlays a draft on its published twin (`_id` published, plus `_originalId`); `raw` returns `drafts.<id>` rows.

`GET …/v{apiVersion}/data/doc/:dataset/:id[,id…]` (`getDocument(s)`) reads `*[_id in ids]` as `raw`: `{"documents", "omitted"}`; a missing id is omitted, reason `existence`.

Errors keep Barkpark's envelope plus Sanity's `description`, `statusCode` and `message` (`ClientError.message` names the cause), and `type`: a syntax error is 400 `malformed` with `type: "queryParseError"`, `query`, `start`, `end`; a limit is 422 `bad_request` with `type: "queryLimitError"`; an unsupported function is 422 `bad_request` with `type: "queryEvaluationError"`; no free slot is 503 with `type: "queryBusyError"` and `Retry-After`. A missing parameter is a syntax error, as on Sanity.

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

## Sync tags

`bp:ds:<dataset>:type:<type>` for every type a `*[...]` scanned, and `bp:ds:<dataset>:doc:<id>` for every document read by id (`_id ==`, `->`) whose type was not scanned. The webhook dispatcher sends the same tags on each mutation ([webhook-realtime.md](webhook-realtime.md)), so `revalidateTag` refreshes every cached query that read it. At most 128 tags; beyond that, type tags only.

## Evaluation and limits

Top-level conditions of each `*[...]` become SQL, `^` included: `_type`, `_id`, a field `==`, `!=`, `<`, `<=`, `>`, `>=` a scalar, `$x in field[].value`, `references()`, `count(field)` against an integer, `defined()`, `count(field[cond]) > 0` for element `==` and `in`, `!` of `defined()`, `==`, `in` and that count, and an `||` of them. The evaluator then applies the whole filter. `count(*[...])` is a SQL count when its filter has only these, except `references()` and `title`, and the caller sees every field it tests; any other is counted in chunks. A slice (`[n]`, `[a...b]`, no negative bound) of a `*[...]` without `^`, ordered or not, reads only what it returns: in SQL when `count()` would be, else in chunks. `->` and subqueries read in rounds: one SQL read per level and shape.

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

Supported: the GROQ-1 grammar (filters, projections, `...`, `->`, `^`, `@`, slices, `| order()`, `| score()`, `select()`, ranges, `match`, `in`, arithmetic) and the functions `coalesce`, `count`, `dateTime`, `defined`, `identity`, `length`, `lower`, `upper`, `now`, `path`, `references`, `round`, `string`, `string::split`, `string::startsWith`, `array::join`, `array::compact`, `array::unique`, `array::intersects`, `math::min|max|sum|avg`, `dateTime::now`, `pt::text`, `sanity::projectId|dataset|versionOf|partOfRelease`, `releases::all`, `documents::get` (own dataset). Sanity's GROQ test suite runs in CI (`groq/conformance_test.exs`): 7147 of 7731 pass; the rest use `diff::` or `fn`.

Not yet: `diff::changedAny|changedOnly`, `fn` custom functions, `geo::`, `text::query`, other `documents::`, `delta::`, `user::`; releases (a stack's release ids are ignored); `resultSourceMap`; the Live Content API (`/data/live/events`). Sanity defaults to `raw` before 2025-02-19, Barkpark to `published`: an older client asks for `perspective: 'raw'`.

`score()` weighs as groq-js; multi-term ranks can differ.

Read compat (declared fields): a bare-id reference answers `->`, `_ref`, `_type`, `_weak`, `references()`; a slug string `.current`; an object-array item `_type` (stored, else `kind`, else member name); a richText body `pt::text()` (its wikilinks do not count for `references()` yet). `order()` is exact where every type in scope declares the field, else a bare value sorts as missing, as in `order(a[0]._type)`.

`tooling/groq/compare.mjs` diffs a corpus against groq-js.
