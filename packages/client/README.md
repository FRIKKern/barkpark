# @barkpark/client

Framework-agnostic TypeScript client for the Barkpark v1 HTTP API.

- Strongly typed envelope + errors
- Zero runtime dependencies (uses global `fetch`)
- ESM + CJS + `.d.ts` output via tsup
- Immutable client: `withPerspective` / `withDataset` / `withToken` return fresh instances

Targets Barkpark `/v1` — see `docs/api-v1.md` for the wire contract. Pinned to `v0.0.83+`.

## Install

```bash
pnpm add @barkpark/client
```

Requires Node 18+ (or any runtime with global `fetch`).

## Usage

```ts
import { createClient } from '@barkpark/client'

const bp = createClient({
  projectUrl: 'http://89.167.28.206',
  dataset: 'production',
  token: process.env.BARKPARK_TOKEN,        // optional for public reads
  perspective: 'published',                 // default
})

// Reads
const posts = await bp.query('post', { limit: 10, order: '_updatedAt:desc' })
const post = await bp.getDocument('post', 'p1')

// Writes (each throws BarkparkError on failure)
await bp.create({ _id: 'x', _type: 'post', title: 'Hello', body: 'world' })
await bp.patch('post', 'drafts.x', { set: { title: 'New' }, ifRevisionID: post._rev })
await bp.publish('post', 'x')

// Atomic batch
await bp.mutate([
  { create: { _id: 'a', _type: 'post', title: 'A' } },
  { create: { _id: 'b', _type: 'post', title: 'B' } },
])
```

## Typed documents

Pass a type parameter to get full autocomplete on your domain model:

```ts
interface Post extends DocumentEnvelope {
  _type: 'post'
  title: string
  body?: string
}

const res = await bp.query<Post>('post')
res.documents[0].title // typed string
```

A `typegen` CLI is coming (will read `/v1/schemas/:dataset` and emit a
`DocumentMap`).

## Errors

```ts
import { BarkparkError } from '@barkpark/client'

try {
  await bp.patch('post', 'x', { set: { title: 'v2' }, ifRevisionID: staleRev })
} catch (err) {
  if (err instanceof BarkparkError && err.code === 'rev_mismatch') {
    // show a conflict UI, refetch, retry
  } else throw err
}
```

Error codes (from `docs/api-v1.md § Error codes`):
`not_found` `unauthorized` `forbidden` `schema_unknown` `rev_mismatch`
`conflict` `malformed` `validation_failed` `internal_error`.

## Testing

Vitest integration tests hit a local Phoenix instance. Start the API first,
then run tests:

```bash
cd api && MIX_ENV=dev mix phx.server &
cd packages/client && pnpm test
```

Tests isolate state in a disposable `sdktest` dataset and clean up after
themselves.
