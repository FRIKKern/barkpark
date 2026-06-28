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
```

Operators: `.eq()` · `.in()` · `.contains()` · `.gt()` · `.gte()` · `.lt()` · `.lte()`, or the explicit `.where(field, op, value)`.

Resolve references inline with `.expand()` (depth 1) — one request instead of a follow-up fetch:

```ts
const posts = await bp.docs('post').expand('author').find()
posts[0].author.name // the author document, inlined (a missing ref stays a raw id string)
```

`.expand()` resolves **single reference fields** whose value is a plain id string (depth 1). Arrays of references and `{_ref}`-object values aren't inlined.

> Filters match **schema fields** (e.g. `status`, `slug.current`), not the system `_id`/`_type`. To fetch a specific document by id, use `bp.doc(type, id)` — `.eq('_id', …)` won't match.

## Write

```ts
await bp.patch('p1').set({ title: 'Updated' }).commit()

await bp
  .transaction()
  .create({ _type: 'post', title: 'New' })
  .patch('p2', (p) => p.set({ featured: true }))
  .commit()

await bp.publish('p1', 'post')
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
