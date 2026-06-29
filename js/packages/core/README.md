<!-- doc-tier: human | canonical-for: core-package | budget: 320tok -->
# @barkpark/core

Runtime-agnostic HTTP client for the Barkpark Phoenix API. Zero runtime deps, fetch-only transport — runs in Node, browsers, edge, and workers.

```bash
npm install @barkpark/core
```

## Create a client

```ts
import { createClient } from '@barkpark/core'

const bp = createClient({
  projectUrl: 'https://api.example.com',
  dataset: 'production',
  apiVersion: '2026-04-01',
  token: process.env.BARKPARK_TOKEN, // required for writes / drafts
})

// Cheap to derive a variant with overridden config — e.g. read drafts:
const drafts = bp.withConfig({ perspective: 'drafts' })
```

## Read

```ts
const post = await bp.doc('post', 'p1') // one document, or null
const withAuthor = await bp.doc('post', 'p1', { expand: 'author' }) // author inlined

// Fluent query builder with semantic operators:
const featured = await bp
  .docs('post')
  .eq('status', 'published')
  .gt('rank', 5)
  .in('tag', ['news', 'release'])
  .order('_updatedAt:desc')
  .limit(20)
  .find()

const newest = await bp.docs('post').order('_createdAt:desc').findOne()
const byTitle = await bp.docs('post').order('title:asc').find() // any field, not just timestamps

// Paginate: the page + the total match count in ONE request.
const { documents, total } = await bp.docs('post').eq('status', 'published').limit(20).findPage()
// …or just the total: await bp.docs('post').count()
```

Operators: `.eq()` · `.neq()` · `.in()` · `.nin()` · `.has()` · `.contains()` · `.gt()` · `.gte()` · `.lt()` · `.lte()`, or the explicit `.where(field, op, value)`. `.neq()`/`.nin()` are strict (NULL/absent excluded); `.has()` is array membership (`tags has tag-x`).

Resolve references inline with `.expand()` (depth 1) — one request instead of a follow-up fetch:

```ts
const posts = await bp.docs('post').expand('author').find()
posts[0].author.name // the author document, inlined (a missing ref stays a raw id string)
```

`.expand()` resolves **reference fields** — single or `arrayOf`-of-reference — each value a plain id string or a `{_ref}` object (depth 1). Missing refs stay raw.

> Filters match **schema fields** (e.g. `status`, `slug.current`), not the system `_id`/`_type`. To fetch a specific document by id, use `bp.doc(type, id)` — `.eq('_id', …)` won't match.

Full-text search across the dataset:

```ts
const { documents, count } = await bp.search('headless cms', { limit: 10 })
```

Introspect the dataset's content model:

```ts
const schemas = await bp.schemas()        // every type's schema (BarkparkSchema[])
const post = await bp.getSchema('post')   // one schema, or null
```

## Write

```ts
// Single-doc shortcuts (each is one atomic commit):
await bp.create({ _type: 'post', title: 'New' })
await bp.createOrReplace({ _id: 'p1', _type: 'post', title: 'Upsert' })
await bp.createIfNotExists({ _id: 'p1', _type: 'post', title: 'Once' })
await bp.patch('p1').set({ title: 'Updated' }).commit()
await bp.delete('p2', 'post')

// …or batch many mutations atomically:
await bp
  .transaction()
  .create({ _type: 'post', title: 'New' })
  .patch('p2', (p) => p.set({ featured: true }))
  .commit()

await bp.publish('p1', 'post')

// Upload a media asset (multipart) — `file` is a web Blob/File:
const asset = await bp.uploadAsset(file, { filename: 'cover.png' })
```

## Listen (real-time)

`bp.listen()` returns an `AsyncIterable` of change events plus an `.unsubscribe()` method; it reconnects automatically. The optional second-argument filter is eq-only.

```ts
const handle = bp.listen('post')   // optional 2nd arg: an eq-only filter
for await (const ev of handle) {
  console.log(ev)                  // change event: created / updated / deleted
}
handle.unsubscribe()               // in your cleanup
```

## Errors

Every failure is a `BarkparkError` carrying `code`, `status`, `requestId`, and the server-supplied `hint` — the same fix-suggestion the `bp` CLI prints:

```ts
import { BarkparkError } from '@barkpark/core'

try {
  await bp.doc('post', 'missing')
} catch (e) {
  if (e instanceof BarkparkError) console.error(e.message, '→', e.hint)
}
```

See `docs/decisions/0001-sdk-envelope.md` for the envelope contract (Phoenix canonical, SDK adapts).
