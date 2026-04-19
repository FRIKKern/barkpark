// Live regression for @barkpark/core SDK against prod API.
//
// Proves defect #16 (query) and defect #18 (doc) are fixed.
// Run: node scripts/live-regression.mjs  (from js/packages/core)
//
// Imports the freshly built package from ./dist — if you change src, run `pnpm build` first.

import { createClient } from '../dist/index.mjs'

const PROJECT_URL = process.env.BARKPARK_API_URL ?? 'http://89.167.28.206:4000'
const DATASET = 'production'
const TOKEN = process.env.BARKPARK_TOKEN ?? 'barkpark-dev-token'

const client = createClient({
  projectUrl: PROJECT_URL,
  dataset: DATASET,
  apiVersion: '2026-04-17',
  token: TOKEN,
})

const banner = (s) => console.log(`\n=== ${s} ===`)

async function main() {
  banner(`defect #16 regression: client.docs('post').find()`)
  const docs = await client.docs('post').find()
  if (!Array.isArray(docs) || docs.length === 0) {
    throw new Error(`expected non-empty array, got: ${JSON.stringify(docs).slice(0, 200)}`)
  }
  console.log(`  got ${docs.length} post documents`)
  console.log(`  first: _id=${docs[0]._id} _type=${docs[0]._type} title=${JSON.stringify(docs[0].title)}`)
  console.log(`  shape keys: ${Object.keys(docs[0]).sort().join(',')}`)

  banner(`defect #18 regression: client.doc('post','p1')`)
  const doc = await client.doc('post', 'p1')
  if (doc === null || doc === undefined) {
    throw new Error(`expected document, got ${doc}`)
  }
  if (typeof doc !== 'object' || !('_id' in doc)) {
    throw new Error(`expected object with _id, got: ${JSON.stringify(doc).slice(0, 200)}`)
  }
  console.log(`  got document _id=${doc._id} _type=${doc._type}`)
  console.log(`  title=${JSON.stringify(doc.title)} author=${JSON.stringify(doc.author)}`)
  console.log(`  _rev=${doc._rev}`)

  banner('OK — envelope contract honored')
}

main().catch((err) => {
  console.error('FAIL:', err.message)
  console.error(err.stack)
  process.exit(1)
})
