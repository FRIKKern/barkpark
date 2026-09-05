<!-- doc-tier: agent | canonical-for: query-surface-limits | budget: 2400tok -->

# Query surface — measured limits and the recommended architecture

Owner of one fact: **what the read plane can and cannot express**, and what a
tool author should build instead when it cannot. Everything below was
re-measured against the live HTTP surface, not quoted from a report; the
measurements are pinned as tests in
`api/test/barkpark_web/controllers/query_documented_limits_test.exs`, which
fails if any statement here stops being true.

Endpoints in scope: `GET /v1/data/query/:dataset/:type` and its
workspace-scoped twin `GET /w/:ws/p/:proj/v1/data/query/:dataset/:type`.

## 1. Filters compose with AND

**There is no one-clause-per-query limit.** Three spellings all reach the same
query builder, which reduces every map key with `AND`:

| Spelling | Example |
|---|---|
| bracketed fields | `?filter[title]=Alpha&filter[status]=published` |
| bracketed ops | `?filter[price][gte]=10&filter[price][lt]=20` |
| repeated flat | `?filter[]=title=Alpha&filter[]=status=published` |

Conflict rule for the repeated form: clauses on the same field **merge** when
their operators differ, and are **refused with 400** when the same operator
appears twice — under `AND`, `title=a AND title=b` can never hold, so keeping
either one silently would answer a question nobody asked. Use `in a,b` for
membership.

An unparseable or unrecognised filter shape is a **400 naming the grammar**,
never a silent unfiltered 200.

## 2. No dereference through a reference — anywhere

A reference field stores an id string. Nothing in the read plane joins through
it, so:

- **filter:** `?filter[author.title]=Ada` matches **nothing**. It is read as a
  JSONB path inside the post document, where `author` is a string, so the path
  resolves to NULL on every row. No error — this is the one place the surface
  is quiet, and the reason for §5.
- **sort:** `?order=author.title:asc` is a no-op for the same reason. The rows
  come back unsorted-by-author rather than refused.

A dotted path **does** work when both segments live in the same document:
`?filter[meta.slug]=alpha` and `?order=meta.slug:asc` are real JSONB sub-path
operations. The rule is "same document, yes; across a reference, no".

## 3. Projection is top-level only

`?fields=meta.slug` keeps the **whole** `meta` object, not the `slug` key.
Deliberate: a sub-slice would need a projection language, and a partial object
that looks complete is worse than an explicit whole one. System keys (`_id`,
`_type`, `_rev`, `_draft`, `_publishedId`, `_createdAt`, `_updatedAt`) always
survive a projection.

## 4. Expansion is one hop — over single refs AND ref arrays

`?expand=author` inlines the referenced document. `?expand=tags` inlines every
element of an `arrayOf` whose element type is `reference` — **ref arrays are
not excluded**. `?expand=true` expands every reference field on the type.

Depth is one hop. A dotted spec (`?expand=author.employer`) names no top-level
reference field and expands nothing; there is no `expand=a.b` grammar.

**Identity of an expanded reference.** The inlined document carries the
identity of the row the reference resolves to, resolved **published-first**: a
reference that stores `drafts.<id>` still inlines the PUBLISHED twin when one
exists, so `_id` is the id a consumer can compare against. When no published
twin exists the draft is inlined and `_id` keeps its `drafts.` prefix — a
genuine draft is honestly a draft. Every inlined document also carries
`_publishedId` (the id with any `drafts.` prefix stripped), so a consumer never
has to strip the prefix itself. Compare on `_publishedId` when you want
identity independent of publication state.

## 5. jsonb normalises key order — compare canonically

Document content is stored as PostgreSQL `jsonb`, which does **not** preserve
key insertion order (and de-duplicates keys). A document written as
`{"b":1,"a":2}` reads back as `{"a":2,"b":1}`.

This is harmless for any consumer that treats JSON objects as unordered — which
the spec says they are — and invisible to `==` in Elixir, Go, Python or
JavaScript, because all of them compare maps/objects structurally.

It is **not** harmless for a tool that deep-compares **serialised text**. A
migration checker that does `JSON.stringify(before) !== JSON.stringify(after)`,
or diffs two `jq`-free dumps line by line, reports field drift on documents
where no field changed. This cost real debugging time on migrated portable-doc
fields.

Guidance: compare **canonically**, never textually.

- JavaScript / TypeScript: `JSON.stringify(v, Object.keys(v).sort())` is not
  enough (it is shallow) — use a recursive canonical serialiser, or a structural
  deep-equal (`node:assert`'s `deepStrictEqual`, lodash `isEqual`).
- `jq`: `jq -S .` sorts keys at every level; `jq -S . a.json > … ; diff` is a
  correct textual comparison.
- Go: `reflect.DeepEqual` over `map[string]any` is already order-independent.
- Elixir: map `==` is already order-independent.

Array order **is** preserved and IS significant — canonicalisation must sort
object keys only, never array elements.

## 6. Recommended architecture: denormalise at write time

Because of §2, a query that needs a value from a referenced document cannot ask
for it. The supported answer is not a richer query language — it is a
**catalogue row**: at write time, copy the fields you will filter, sort or
display into the referring document, alongside the reference.

```json
{
  "_id": "po1",
  "_type": "post",
  "author": "au1",
  "catalogueRow": { "authorName": "Ada", "authorSlug": "ada" }
}
```

Then `?filter[catalogueRow.authorSlug]=ada` and `?order=catalogueRow.authorName:asc`
are ordinary same-document JSONB paths, and `?fields=catalogueRow` is one
top-level projection — no expansion, no second round trip, one query.

Rules that keep this honest:

- Keep the reference. `catalogueRow` is a **derived cache**, never the source
  of truth; `author` stays the id you resolve when you need the full document.
- Rebuild it on write of either side. Subscribe to the referenced type's
  mutations (`GET /v1/data/listen/:dataset`) and re-stamp the referring
  documents, or re-stamp on the next write of the referrer if staleness is
  acceptable.
- Copy only what a query needs. A catalogue row that mirrors the whole target
  is a second copy of the document, with a second copy's drift.

Today every consumer rediscovers this boundary empirically. This section is the
answer, so the next one does not have to.

## 7. Graph routes are flat-only today

`/v1/graph`, `/v1/graph/orphans`, `/v1/graph/dangling`, `/v1/graph/:id` and
`/v1/graph/:id/tasks` are declared in a **flat** `scope "/v1"` — there is no
workspace-scoped `/w/:ws/p/:proj/v1/graph/...` twin. A token therefore reads the
graph of its **home dataset only**, and a caller with several workspaces cannot
point these at a non-default one.

This is not a defect unique to the graph family: it is the shared flat-route
scoping mechanism, and roughly fifteen sibling route families carry it. Mounting
the graph routes alone would leave the siblings broken and split the fix.
Repairing it is owned by the flat-route census, not by this document.

## Related

- Envelope keys and the draft/published model: `docs/api-v1.md` §3.
- Field types (including `reference` and `arrayOf`): `docs/contracts/schema-v2.md`.
- Tenancy and route scoping: `docs/contracts/tenancy.md`.
