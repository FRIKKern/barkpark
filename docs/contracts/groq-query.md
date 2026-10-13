<!-- doc-tier: agent | canonical-for: groq-query-api | budget: 1500tok -->
# GROQ query API

Barkpark answers GROQ queries on the URL scheme of Sanity's HTTP query API, so a site built on `@sanity/client` or `next-sanity` can point at Barkpark and keep its queries. Code: `api/lib/barkpark/groq/` (parser, evaluator, document source), `BarkparkWeb.GroqController`.

## Endpoint

`GET|POST /w/:workspace_slug/p/:project_slug/v{apiVersion}/data/query/:dataset` [token]

| Input | Form |
|---|---|
| `query` | GROQ text; GET query string or POST body `{"query", "params"}` |
| `$name` | GET only: one parameter, JSON-encoded (`$slug="intro"`) |
| `params` | POST only: object of decoded parameter values |
| `perspective` | `published` (default for every apiVersion), `drafts` (`previewDrafts` is an alias), `raw`; other values → 400 |
| `returnQuery` | `false` leaves `query` out of the response |

Any `apiVersion` is accepted. Auth, tenancy and share access are those of the scoped document reads ([api-v1.md](../api-v1.md) §2). A caller pinned to published reads (no token, a share, a `public-read` token) gets `published` whatever it asks for. POST is billed to the read rate-limit bucket.

Response: `{"query", "result", "ms", "syncTags"}`. Documents have `_id`, `_type`, `_rev`, `_createdAt`, `_updatedAt`, `title` and their content fields at the top level; field visibility redaction applies. `title` is the value a regular document read returns: Barkpark stores it in the `documents.title` column, and `title == "x"` is matched there. A document without a title has no `title` key. `drafts` overlays a draft on its published twin, sets `_id` to the published id and adds `_originalId`; `raw` returns `drafts.<id>` rows as stored.

Errors keep Barkpark's envelope and add Sanity's `description` and `type`: a syntax error is 400 `malformed` with `type: "queryParseError"`, `query`, `start`, `end`; a limit is 422 `bad_request` with `type: "queryLimitError"`; an unsupported function is 422 `bad_request` with `type: "queryEvaluationError"`. A parameter the query uses but the request lacks is a syntax error, as on Sanity.

## Client configuration

```ts
import {createClient} from '@sanity/client'

const client = createClient({
  projectId: 'barkpark', // any value; the client needs one to send perspective
  dataset: 'production',
  apiHost: 'https://<host>/w/<workspace>/p/<project>',
  useProjectHostname: false,
  apiVersion: '2025-02-19',
  useCdn: false,
  token: process.env.BARKPARK_READ_TOKEN,
})
```

`next-sanity`'s `createClient` takes the same options.

## Sync tags

`bp:ds:<dataset>:type:<type>` for every type a `*[...]` scanned, and `bp:ds:<dataset>:doc:<id>` for every document read by id (`_id ==`, `->`) whose type was not scanned. They are the tags the webhook dispatcher sends on each mutation ([webhook-realtime.md](webhook-realtime.md)), so `revalidateTag` with a webhook's tags refreshes every cached query that read the changed document. At most 128 tags; past that, document tags collapse into type tags.

## Evaluation and limits

These top-level conditions of each `*[...]` become SQL, including values read through `^`: `_type`, `_id`, field equality, `$x in field[].value`, `references()`, `count(field)` compared with an integer (not `!=`), and `defined()`. An `||` becomes SQL when each branch holds one of them; a branch that reads only `^` and is false for the parent is skipped. Field conditions use the GIN index over `content`, and `references()` a GIN index over its `_ref` values. Everything else runs in memory over the loaded documents, and the evaluator applies the whole filter again. `count(*[...])` is a SQL count when its filter has only `_type`, `_id`, field equality, `count()` and `defined()` and the caller sees every field of the type. Any other is counted in chunks, so only the wall time limits it. Dereferences and subqueries are read in rounds: one SQL read per level of `->` nesting and per subquery shape, however many documents they run for. A subquery that does not read `^` runs once per query.

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

Supported: the GROQ-1 grammar (filters, projections, `...`, `->`, `^`, `@`, slices, `| order()`, `| score()`, `select()`, ranges, `match`, `in`, arithmetic) and the functions `coalesce`, `count`, `dateTime`, `defined`, `identity`, `length`, `lower`, `upper`, `now`, `path`, `references`, `round`, `string`, `string::split`, `string::startsWith`, `array::join`, `array::compact`, `array::unique`, `array::intersects`, `math::min|max|sum|avg`, `dateTime::now`, `pt::text`, `sanity::projectId|dataset|versionOf|partOfRelease`, `releases::all`. Sanity's GROQ test suite runs in CI (`api/test/barkpark/groq/conformance_test.exs`): 7147 of 7731 cases pass; the rest use `diff::` selectors or custom `fn` declarations.

Not yet: `diff::changedAny|changedOnly`, `fn` custom functions, `geo::`, `text::query`, `documents::`, `delta::`, `user::`; release and version perspectives; `resultSourceMap`; the Live Content API (`/data/live/events`); and SQL for ordering and slicing, so a query that scans a large type without an indexed condition can hit the document limits. Barkpark defaults to `published` for every API version; Sanity defaults to `raw` before 2025-02-19, so a client on an older version that relies on drafts must ask for `perspective: 'raw'`.

Checking a site's queries: `tooling/groq/compare.mjs` runs a query corpus through groq-js and through this endpoint over the same documents and reports the differences (dev only).
