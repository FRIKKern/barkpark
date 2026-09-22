import assert from 'node:assert/strict'
import { register } from 'node:module'
import { test } from 'node:test'

// `barkpark.ts` imports @barkpark/core as a VALUE. These hooks make it
// importable in the dependency-free CI job; everything else in it runs for real.
register(new URL('./__test-stub-hooks.mjs', import.meta.url))

const { BarkparkAPIError, BarkparkNotFoundError } = await import(
  './__test-stub-barkpark-core.mjs'
)
const { resolveEnv, fetchFlagshipDoc, flagshipMarkers, createBarkparkClient } =
  await import('./barkpark.ts')

/**
 * THE CONTENT LINK'S THREE STATES, and what each one must do to `astro build`.
 *
 * The astro-starter is a BUILD-time adapter: whatever `fetchFlagshipDoc` throws
 * kills `astro build` with exit 1 and produces no artifact at all. Until this
 * file, the astro-starter and the next-starter — the same adapter for two
 * frameworks — carried OPPOSITE 404 policies: next caught
 * `BarkparkNotFoundError` and rendered honest-empty (wave-7 D72), astro let it
 * propagate and crashed the build.
 *
 *   200-empty        (reachable type, zero docs)  -> { doc: null }, marker ''
 *   404              (type missing or private)    -> { doc: null }, marker ''
 *   anything else    (network / 401 / 5xx)        -> THROWS, build fails loud
 *
 * The third row is the load-bearing one. A bare `catch { return { doc: null } }`
 * would satisfy the first two and render an OUTAGE as "this dataset is empty",
 * which is the fail-open this suite exists to forbid.
 */

const ENV = {
  apiUrl: 'https://example.invalid/w/acme/p/default',
  token: 't',
  dataset: 'production',
  workspace: undefined,
  project: undefined,
  docType: 'post',
  docId: undefined,
  buildId: 'b1',
  contentRev: 'r1',
}

/** A client double whose list executor resolves `findOne` to `result`. */
function listClient(result: unknown) {
  return {
    doc: async () => {
      throw new Error('doc() must not be called on the unpinned path')
    },
    docs: () => ({
      order: () => ({
        limit: () => ({
          findOne: async () => {
            if (result instanceof Error) throw result
            return result
          },
        }),
      }),
    }),
  }
}

/** A client double whose single-doc getter resolves to `result`. */
function pinClient(result: unknown) {
  return {
    doc: async () => {
      if (result instanceof Error) throw result
      return result
    },
    docs: () => {
      throw new Error('docs() must not be called on the pinned path')
    },
  }
}

// ── QUIET ARM ──────────────────────────────────────────────────────────────
// Stays green before AND after the 404 fix. A reachable type with zero
// documents is a 200 carrying an empty page; core's `findOne()` resolves null
// and never rejects, so this arm never touched the catch block at all. It is
// here so the two RED arms below cannot be mistaken for the whole story: the
// ordinary empty site was always fine, and this file must not start claiming
// the fix repaired it.
test('200-empty: a reachable type with zero documents builds honestly empty', async () => {
  const result = await fetchFlagshipDoc(listClient(null) as never, ENV as never)
  assert.deepEqual(result, { doc: null })
  assert.deepEqual(flagshipMarkers(result), { docId: '', docTitle: '' })
})

// ── RED ARM 1 ──────────────────────────────────────────────────────────────
// Reverting the `catch (err) { if (err instanceof BarkparkNotFoundError) ... }`
// in fetchFlagshipDoc makes this test REJECT instead of resolving.
test('404 on the list path: missing/private type does NOT crash the build', async () => {
  const notFound = new BarkparkNotFoundError('no such type', {
    serverCode: 'not_found',
  })
  const result = await fetchFlagshipDoc(
    listClient(notFound) as never,
    ENV as never,
  )
  assert.deepEqual(result, { doc: null })
  // The EMPTY marker is the whole point: it is what the deploy engine's HEALTH
  // gate reads to refuse the switch, so the misconfiguration is still caught
  // fail-closed — one stage later, with an artifact to inspect.
  assert.equal(flagshipMarkers(result).docId, '')
})

// ── RED ARM 2 ──────────────────────────────────────────────────────────────
// Widening the catch to a bare `catch { return { doc: null } }` makes this test
// resolve instead of rejecting. It is the fail-open guard: an outage must never
// be rendered as an empty dataset and shipped.
test('a non-404 failure still THROWS — an outage is not an empty dataset', async () => {
  const boom = new BarkparkAPIError('upstream is down', { status: 503 })
  await assert.rejects(
    () => fetchFlagshipDoc(listClient(boom) as never, ENV as never),
    (err: unknown) => err === boom,
  )
  await assert.rejects(
    () =>
      fetchFlagshipDoc(
        listClient(new TypeError('fetch failed')) as never,
        ENV as never,
      ),
    TypeError,
  )
})

// ── PINNED-DOC AXIS (BARKPARK_DOC_ID) ──────────────────────────────────────
test('BARKPARK_DOC_ID pins one document instead of racing newest-of-type', async () => {
  const env = { ...ENV, docId: 'doc-42' }
  const result = await fetchFlagshipDoc(
    pinClient({ _id: 'doc-42', title: 'Pinned' }) as never,
    env as never,
  )
  assert.deepEqual(result, { doc: { _id: 'doc-42', title: 'Pinned' } })
  assert.deepEqual(flagshipMarkers(result), {
    docId: 'doc-42',
    docTitle: 'Pinned',
  })
})

test('a pinned doc that is absent bakes an empty marker, not a crash', async () => {
  const env = { ...ENV, docId: 'doc-gone' }
  // core's single-doc getter maps its own 404 to null (doc.ts:85-87), so this
  // arm proves the pinned path reaches `toFlagship(null)` rather than throwing.
  const result = await fetchFlagshipDoc(pinClient(null) as never, env as never)
  assert.deepEqual(result, { doc: null })
  assert.equal(flagshipMarkers(result).docId, '')
})

// ── ENV CONTRACT ───────────────────────────────────────────────────────────
test('resolveEnv: docType defaults to post, blank docId collapses to undefined', () => {
  const env = resolveEnv({
    BARKPARK_API_URL: 'https://example.invalid/w/acme/p/default',
    BARKPARK_DATASET: 'production',
    BARKPARK_DOC_ID: '   ',
  } as never)
  assert.equal(env.docType, 'post')
  assert.equal(env.docId, undefined)

  const pinned = resolveEnv({
    BARKPARK_API_URL: 'https://example.invalid/w/acme/p/default',
    BARKPARK_DATASET: 'production',
    BARKPARK_DOC_TYPE: ' book ',
    BARKPARK_DOC_ID: ' doc-7 ',
  } as never)
  assert.equal(pinned.docType, 'book')
  assert.equal(pinned.docId, 'doc-7')
})

test('resolveEnv: a missing required var fails LOUD, never a silent empty site', () => {
  assert.throws(
    () => resolveEnv({ BARKPARK_DATASET: 'production' } as never),
    /BARKPARK_API_URL/,
  )
})

test('an already-scoped apiUrl is not double-prefixed with workspace/project', () => {
  const scoped = createBarkparkClient({
    ...ENV,
    workspace: 'acme',
    project: 'default',
  } as never) as { __config: Record<string, unknown> }
  assert.equal(scoped.__config.projectUrl, ENV.apiUrl)
  assert.equal('workspace' in scoped.__config, false)
  assert.equal('project' in scoped.__config, false)

  const bare = createBarkparkClient({
    ...ENV,
    apiUrl: 'https://example.invalid',
    workspace: 'acme',
    project: 'default',
  } as never) as { __config: Record<string, unknown> }
  assert.equal(bare.__config.workspace, 'acme')
  assert.equal(bare.__config.project, 'default')
})
