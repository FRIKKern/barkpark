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

## Typed client

Pair the client with `@barkpark/codegen`'s generated `BarkparkTypeMap` for fully typed reads — `doc`/`docs`/`getDocuments` narrow by document type, and an unknown type name is a compile error.

```ts
import { typedClient } from '@barkpark/core'
import type { BarkparkTypeMap, Post } from './barkpark.types' // run `barkpark generate`

const bp = typedClient<BarkparkTypeMap>(client)

const post = await bp.doc('post', 'p1') // Post | null
const posts = await bp.getDocuments('post', ['p1', 'p2']) // Array<Post | null>
await bp.docs('post').eq('status', 'published').find() // Post[]
bp.doc('psot', 'p1') // ✗ compile error — 'psot' isn't a known type
```

`typedClient` is a **type-only wrapper** (runtime-identical to the client it wraps). The single-type-keyed reads narrow; the mixed-type reads (`getBacklinks`/`getGraph`/`getRelated`/`listTags`/`getTagDocs`) and the mutations stay open by design.

## Read

```ts
const post = await bp.doc('post', 'p1') // one document, or null
const withAuthor = await bp.doc('post', 'p1', { expand: 'author' }) // author inlined
const card = await bp.doc('post', 'p1', { fields: ['title', 'slug'] }) // project to named fields
// Batch-fetch by id — same order as `ids`, `null` for any missing (takes expand/fields/signal/perspective):
const many = await bp.getDocuments('post', ['p1', 'p2', 'p3'])
const drafts = await bp.getDocuments('post', ['p1', 'p2'], { perspective: 'drafts' }) // per-call override

// Inbound references — documents that reference a given doc (reverse of `expand`):
const { backlinks, count } = await bp.getBacklinks('p1')

// Content graph — traverse references from a root, find orphans / broken refs:
const graph = await bp.getGraph('p1', { depth: 3, direction: 'out' }) // { nodes, edges, dependents, truncated }
const orphans = await bp.getOrphans() // documents with zero edges
const broken = await bp.getDangling() // references whose target is missing

// Related documents — tag overlap fused with backlinks, each entry carries WHY:
const { related, count } = await bp.getRelated('p1', { limit: 5 })
related[0].score // fused relatedness; .sources = ['tags'] | ['references'] | both; .shared_tags explains the tag leg

// Weighted-tag registry — browse tags with per-type published counts, biggest first:
const { tags } = await bp.listTags({ types: ['paper', 'task'] }) // [{ tag, counts: { paper, task }, total }]
// …and the documents carrying one tag, ranked by that tag's strength (legacy flat carriers last):
const { documents } = await bp.getTagDocs('search') // [{ doc_id, type, title, strength, rationale, main_tag_match }]

// A document's `tags` field is dual-shape (weighted objects OR flat strings) —
// normalizeTags() collapses either into { names, entries }:
import { normalizeTags } from '@barkpark/core'
const { names, entries } = normalizeTags(post.tags) // names: string[]; entries: WeightedTag[] ({ tag, strength?, rationale? })

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

// `docs(type, opts)` takes a per-query `perspective` and an AbortSignal to cancel:
const ctrl = new AbortController()
const live = await bp.docs('post', { perspective: 'drafts', signal: ctrl.signal }).find()
// chain .order() for secondary sorts — appends keys (status, then title as tiebreak):
const sorted = await bp.docs('post').order('status:asc').order('title:desc').find()

// Paginate: the page + the total match count in ONE request.
const { documents, total } = await bp.docs('post').eq('status', 'published').limit(20).findPage()
// next page: `.offset()` skips rows — limit + offset drive pagination:
const page2 = await bp.docs('post').eq('status', 'published').limit(20).offset(20).findPage()
// …or just the total: await bp.docs('post').count()

// Project to fewer fields for smaller list payloads (system fields always kept):
const cards = await bp.docs('post').select(['title', 'slug']).limit(50).find()
```

Operators: `.eq()` · `.neq()` · `.in()` · `.nin()` · `.has()` · `.contains()` · `.startsWith()` · `.endsWith()` · `.gt()` · `.gte()` · `.lt()` · `.lte()`, or the explicit `.where(field, op, value)`. `.contains()`/`.startsWith()`/`.endsWith()` are case-insensitive substring/prefix/suffix matches. `.neq()`/`.nin()` are strict (NULL/absent excluded); `.has()` is array membership (`tags has tag-x`). `.eq(field, null)`/`.neq(field, null)` check **null/absence** (server `IS NULL`/`IS NOT NULL`, not an empty-string match) — `eq('category', null)` finds docs where the field is null or missing.

Every operator (and `.order()`) accepts **nested dot-paths** — `.gte('price.amount', 100)`, `.order('price.amount:desc')`. Range ops and ordering compare **numerically** on number fields, lexically on strings — so `rank: 10` correctly sorts after `rank: 9`.

Resolve references inline with `.expand()` (depth 1) — one request instead of a follow-up fetch:

```ts
const posts = await bp.docs('post').expand('author').find()
posts[0].author.name // the author document, inlined (a missing ref stays a raw id string)
```

`.expand()` resolves **reference fields** — single or `arrayOf`-of-reference — each value a plain id string or a `{_ref}` object (depth 1). Missing refs stay raw.

> Filters match **schema fields** (e.g. `status`, `slug.current`) plus the system timestamps `_createdAt`/`_updatedAt` (compare with `gt`/`gte`/`lt`/`lte`/`eq`/`neq`), but not `_id`/`_type`. To fetch a specific document by id, use `bp.doc(type, id)` — `.eq('_id', …)` won't match.

Full-text search across the dataset:

```ts
const { documents, count, facets } = await bp.search('headless cms', { limit: 10 })
// `facets` — counts per dimension (`type`/`status`/`author`), each `{ label, count }`, for faceted-search UIs
// paginate with `offset`, scope to a single type with `type`:
const page2 = await bp.search('cms', { limit: 10, offset: 10, type: 'post' })
// or scope to several types at once with `types` (a cross-type allowlist):
const crossType = await bp.search('cms', { types: ['post', 'author'] })
const suggestions = await bp.getSearchSuggestions('head') // document search typeahead (recent queries + popular terms)
```

Introspect the dataset's content model:

```ts
const schemas = await bp.schemas() // every type's schema (BarkparkSchema[])
const post = await bp.getSchema('post') // one schema, or null
// …or write schemas — idempotent upsert (register/replace), delete by name:
await bp.upsertSchema({ name: 'post', fields: [/* … */] }) // throws BarkparkValidationError if invalid
await bp.deleteSchema('post')
```

Get a dataset's content-stats overview (`GET /analytics/:dataset`) — total documents, a per-type published/draft breakdown, and recent activity:

```ts
const stats = await bp.getAnalytics() // { total_documents, types: [...], recent_activity: [...] }
```

Stream an entire dataset as NDJSON (`GET /v1/data/export/:dataset`) — an async generator, so memory stays flat at any size:

```ts
for await (const doc of bp.exportDataset({ type: 'post' })) { /* … */ } // omit `type` for all; `perspective` defaults to `raw` (every stored row)
```

## Write

```ts
// Single-doc shortcuts (each is one atomic commit):
await bp.create({ _type: 'post', title: 'New' })
await bp.createOrReplace({ _id: 'p1', _type: 'post', title: 'Upsert' })
await bp.createIfNotExists({ _id: 'p1', _type: 'post', title: 'Once' })
// patch takes (id, type) — the server dispatches a patch op on both:
await bp.patch('p1', 'post').set({ title: 'Updated' }).commit()
await bp.patch('p1', 'post').unset(['subtitle', 'draftNote']).commit() // remove content keys
await bp.patch('p1', 'post').inc({ views: 1 }).dec({ stock: 2 }).commit() // numeric deltas
await bp.patch('p1', 'post').setIfMissing({ slug: 'auto' }).commit() // set only if the key is absent
await bp.patch('p1', 'post').append('tags', ['featured']).prepend('log', ['first']).commit() // array append/prepend
await bp.delete('p2', 'post')

// …or batch many mutations atomically (the same patch ops work inside a transaction):
await bp
  .transaction()
  .create({ _type: 'post', title: 'New' })
  .patch('p2', 'post', (p) => p.set({ featured: true }))
  .commit()

await bp.publish('p1', 'post')
await bp.unpublish('p1', 'post') // published → draft
await bp.discardDraft('p1', 'post') // drop the draft, keep the published doc

// Document history — list revisions, fetch one (with content), restore a past version as a draft:
const revisions = await bp.getHistory('post', 'p1') // DocumentRevision[]: { id, action, timestamp }
const rev = await bp.getRevision(revisions[0].id) // includes the doc content at that revision
await bp.restoreRevision(rev.id, 'post') // writes that version back as a draft

// Upload a media asset (multipart) — `file` is a web Blob/File:
const asset = await bp.uploadAsset(file, { filename: 'cover.png' })

// Build an image URL from an asset/reference — pick a server rendition with `preset`:
const url = bp.imageUrl(asset, { preset: 'hero' }) // thumb | preview | hero | og; omit for the original

// Manage stored assets — list (paged), fetch one, delete:
const assets = await bp.listAssets({ limit: 20 })
const one = await bp.getAsset('asset-id') // MediaAsset | null
await bp.deleteAsset('asset-id')
await bp.updateAsset('asset-id', { title: 'Cover', altText: 'Hero image' }) // edit metadata (title/altText/caption/tags/…)

// Search the library, take/release an editorial lock, inspect what references an asset:
const hits = await bp.searchAssets('logo', { limit: 20 })
const suggestions = await bp.getAssetSearchSuggestions('log') // media search typeahead
await bp.checkoutAsset('asset-id')     // editorial lock — throws BarkparkConflictError if another editor holds it
await bp.undoCheckoutAsset('asset-id') // release the lock
const rels = await bp.getAssetRelations('asset-id') // what references this asset (impact analysis before delete)

// Media collections (folders / smart-folders) — list, fetch one, list a collection's assets:
const collections = await bp.listCollections({ limit: 20 })
const col = await bp.getCollection('col-id') // MediaCollection | null
const inCol = await bp.getCollectionAssets('col-id')
await bp.addCollectionMember('col-id', 'asset-id') // add an asset to a collection
await bp.removeCollectionMember('col-id', 'asset-id') // …or remove one
const share = await bp.shareCollection('col-id', { ttl: 3600 }) // public link → { token, shareUrl, expiresAt }
await bp.revokeCollectionShare('col-id') // revoke it
```

## Listen (real-time)

`bp.listen()` returns an `AsyncIterable` of change events plus an `.unsubscribe()` method; it reconnects automatically. The optional second-argument filter is eq-only.

```ts
const handle = bp.listen('post') // optional 2nd arg: an eq-only filter
for await (const ev of handle) {
  console.log(ev.mutation) // present-tense verb: create / update / delete / publish / unpublish / discardDraft
}
handle.unsubscribe() // in your cleanup
```

## Manage webhooks

Register and manage outbound webhooks — the `secret` signs each delivery (verify it with `verifyWebhookSignature`, below):

```ts
const hooks = await bp.listWebhooks() // Webhook[]
const hook = await bp.createWebhook({ name: 'ci', url: 'https://ci.example.com/hook', events: ['create', 'update'] })
const one = await bp.getWebhook(hook.id) // Webhook | null
await bp.updateWebhook(hook.id, { active: false }) // partial patch
await bp.deleteWebhook(hook.id)
```

## Verify webhooks

Verify an incoming Barkpark webhook in any runtime (Web Crypto HMAC + replay defense). Returns `false` on a bad or expired signature — it never throws:

```ts
import { verifyWebhookSignature, parseWebhookEvent } from '@barkpark/core'

const body = await req.text() // raw body, do NOT re-serialize
const ok = await verifyWebhookSignature({
  body,
  signature: req.headers.get('x-barkpark-signature'),
  secret: process.env.BARKPARK_WEBHOOK_SECRET!,
})
if (!ok) return new Response('bad signature', { status: 401 })

// Verified — parse into a typed event (verify FIRST; never parse an unverified body):
const event = parseWebhookEvent<Post>(body) // { event, type, doc_id, document, dataset, sync_tags, … }
if (event.event === 'publish') reindex(event.doc_id, event.document)
```

Pass `previousSecret` to accept a rotated-out secret during a rotation window; tune replay tolerance with `toleranceSeconds` (default 300 = ±5 min). `parseWebhookEvent<T>` types `event.document` as `T | null` — pass a generated type (e.g. `Post`) for full type safety on the payload.

## Tenancy & escape hatch

`listWorkspaces()` / `listProjects(workspaceSlug)` / `listDatasets(workspaceSlug, projectSlug)` enumerate the tenancy hierarchy (workspace → project → dataset); `createWorkspace(attrs)` / `createProject(workspaceSlug, attrs)` create them (top-level, token-authed). `fetchRaw(path, init?)` hits an arbitrary API path, bypassing envelope decoding — the escape hatch for endpoints the client doesn't wrap. It resolves to the raw `Response` (not parsed JSON), so call `.json()`/`.text()` yourself; a type argument only asserts the shape of the body you'll read.

## Auth

`bp.auth` is the user-authentication surface (`/v1/auth/*`) — register, log in, sessions, MFA, and password recovery. `login` returns a bearer session **token in the body**; set it on a new client to make authenticated requests.

```ts
await bp.auth.register('a@b.co', 'pw') // confirmation email sent
const { token, user } = await bp.auth.login('a@b.co', 'pw')
const authed = createClient({ ...config, token }) // use the session
await authed.auth.me() // AuthUser | null (null when not signed in)
await authed.auth.logout()
```

When an account has MFA enrolled, `login` throws `BarkparkAuthError` with `serverCode === 'mfa_required'` — catch it, collect a code, and retry with `login(email, password, { totpCode })`.

MFA (TOTP) enrolment and password recovery; the MFA steps re-auth with the account password:

```ts
const { secret, otpauth_uri, qr_svg } = await authed.auth.enrollMfa('pw') // render the QR
const { recovery_codes } = await authed.auth.verifyMfa(secret, '123456', 'pw') // show ONCE
await authed.auth.disableMfa('pw')

await bp.auth.requestPasswordReset('a@b.co') // always resolves (no email-existence leak)
await bp.auth.resetPassword(tokenFromEmail, 'newpw') // throws on a bad token (serverCode 'invalid_token')
await bp.auth.verifyEmail(tokenFromEmail)
```

## Errors

Every failure is a `BarkparkError` carrying `code` (the error class), `serverCode` (the server's machine-readable code, e.g. `mfa_required`/`rev_mismatch` — switch on it for specific conditions), `status`, `requestId`, and the server-supplied `hint` — the same fix-suggestion the `bp` CLI prints:

```ts
import { BarkparkError } from '@barkpark/core'

try {
  await bp.doc('post', 'missing')
} catch (e) {
  if (e instanceof BarkparkError) console.error(e.message, '→', e.hint)
}
```

Across bundle boundaries (pnpm can hoist duplicate class copies), `instanceof` can fail — use `isBarkparkError(e, code?)`, which matches the string `code` field instead; pass a `code` (e.g. `'BarkparkAuthError'`) to narrow to that subclass — its extra fields become reachable with no cast (`isBarkparkError(e, 'BarkparkRateLimitError')` then `e.retryAfterMs`). The known class names are the exported `BarkparkErrorCode` union, so you get autocomplete on the `code` argument (an arbitrary string is still accepted for cross-bundle codes, but only a union member narrows the subclass).

Typed subclasses (all extend `BarkparkError`) let you branch on the failure kind: `BarkparkAuthError` (401/403), `BarkparkValidationError` (422 — carries `.issues`, the per-field errors), `BarkparkNotFoundError` (404), `BarkparkConflictError` (409 id collision / 412 `ifMatch` mismatch), and `BarkparkRateLimitError` (429).

See `docs/decisions/0001-sdk-envelope.md` for the envelope contract (Phoenix canonical, SDK adapts).
