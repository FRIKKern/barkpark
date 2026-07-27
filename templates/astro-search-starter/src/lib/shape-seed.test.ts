// Contract test for the finder seed seam — `node --test src/lib/shape-seed.test.ts`.
//
// Regression guard for the "everything disappears on keystroke" bug: the build
// bakes `initialSeed` as a flat `SeedDoc[]`, but `lookupPrefix` (inside the
// vendored finder) requires a `PrefixSeed` `{index, docs}`. If `shapeSeed` ever
// stops calling `buildPrefixSeed` and passes the raw array through again,
// `lookupPrefix(seed, "d")` throws `Cannot read properties of undefined
// (reading 'd')` during render and unmounts the whole island. These assertions
// fail LOUDLY at that seam so the crash can never ship green again.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { shapeSeed } from './shape-seed.ts'
import { lookupPrefix } from '../finder/lib/prefix-seed.ts'

// Exactly the shape `src/lib/bp.ts` → `browseSeed` bakes into search-seed.json.
const bakedRaw = {
  initialData: null,
  initialSeed: [
    { id: 'a', title: 'Deploy with Barkpark', slug: 'deploy-with-barkpark', type: 'paper' },
    { id: 'b', title: 'Docs and design', slug: 'docs-design', type: 'paper' },
    { id: 'c', title: 'Rendering PortableDoc', slug: 'rendering-portabledoc', type: 'paper' },
  ],
}

test('shapeSeed turns the baked SeedDoc[] into a real PrefixSeed (has .index)', () => {
  const { initialSeed } = shapeSeed(bakedRaw)
  assert.ok(initialSeed, 'initialSeed must not be null for a non-empty corpus')
  assert.ok(
    initialSeed.index && typeof initialSeed.index === 'object' && !Array.isArray(initialSeed.index),
    'initialSeed.index must be the prefix map — NOT an array (the exact bug)',
  )
  assert.ok(Array.isArray(initialSeed.docs), 'initialSeed.docs must be the doc list')
})

test('lookupPrefix does not throw and returns docs for 1- and 2-char queries', () => {
  const { initialSeed } = shapeSeed(bakedRaw)
  // The first-char keystroke that used to crash the island.
  assert.doesNotThrow(() => lookupPrefix(initialSeed, 'd'))
  const one = lookupPrefix(initialSeed, 'd')
  assert.ok(one.length >= 1, '"d" must match Deploy/Docs/design')
  const two = lookupPrefix(initialSeed, 'de')
  assert.ok(two.length >= 1, '"de" must match Deploy/design')
})

test('shapeSeed bakes the browse as postgres, not the retired indx literal', () => {
  // The seed is baked with engine=postgres (bp.ts → browseSeed); the old
  // hard-coded engineUsed:'indx' literal claimed an engine no instance
  // provisions. Without a server-reported engineUsed the fallback is postgres…
  const { initialData } = shapeSeed({
    initialData: { documents: [], count: 0 },
    initialSeed: null,
  })
  assert.ok(initialData, 'initialData must shape when raw browse JSON exists')
  assert.equal(initialData.engine, 'postgres')
  assert.equal(initialData.engineUsed, 'postgres')
  assert.equal(initialData.indxUnavailable, false)
})

test('shapeSeed lets the server-reported engineUsed win over the fallback', () => {
  // …and when the baked payload carries the pipeline's own engineUsed, that
  // server truth wins over the shaping fallback (find-shape contract).
  const { initialData } = shapeSeed({
    initialData: { documents: [], count: 0, engineUsed: 'indx' },
    initialSeed: null,
  })
  assert.ok(initialData)
  assert.equal(initialData.engineUsed, 'indx')
})

test('shapeSeed degrades safely on an absent or empty seed', () => {
  assert.deepEqual(shapeSeed(null), { initialData: null, initialSeed: null })
  assert.equal(shapeSeed({ initialData: null, initialSeed: [] }).initialSeed, null)
  assert.equal(shapeSeed({ initialData: null, initialSeed: null }).initialSeed, null)
})
