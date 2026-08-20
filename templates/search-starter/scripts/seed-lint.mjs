#!/usr/bin/env node
// seed-lint.mjs — the search-starter seed gate.
//
// Validates templates/search-starter/seed.json against the invariants the
// force graph and the single-type bootstrap depend on, and FAILS (exit 1) on
// any violation. Run:
//   node templates/search-starter/scripts/seed-lint.mjs
//
// It refuses to ship a seed that would render a broken or empty graph:
//   1. shape        — a {mutations:[{createOrReplace:{…}}]} payload.
//   2. single type  — every doc is the ONE type the schema defines (bootstrap
//                     publishes exactly one type and rolls the batch back on a
//                     mismatch: internal/bootstrap/bootstrap.go).
//   3. title + body — every doc has a non-empty title and a non-empty
//                     PortableDocument body (an array of blocks).
//   4. no dangling  — every reference value (scalar `reference` fields AND
//                     `arrayOf`-of-`reference` fields, discovered from the
//                     schema — not hardcoded) points at an _id present in this
//                     same file. A dangling ref becomes a phantom graph node.
//   5. density      — average out-degree is > 1 so the graph is a constellation,
//                     not a scatter of islands.
//
// On success it prints the doc count and the average out-degree.
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, resolve, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '..')
const SEED_PATH = resolve(ROOT, 'seed.json')
const SCHEMA_DIR = resolve(ROOT, 'schemas')

const errors = []
const fail = (msg) => errors.push(msg)

// ── Load the schema and discover the reference-bearing fields ────────────────
// Reference edges come from GENUINE schema field types, mirroring the server's
// edge extractor: a scalar { type:"reference" } and an
// { type:"arrayOf", of:{ type:"reference" } }.
function loadSchema() {
  let files
  try {
    files = readdirSync(SCHEMA_DIR).filter((f) => f.endsWith('.json'))
  } catch {
    fail(`schemas/ directory not found at ${SCHEMA_DIR}`)
    return null
  }
  if (files.length !== 1) {
    fail(`expected exactly ONE schema file (single-type seed), found ${files.length}: ${files.join(', ')}`)
    return null
  }
  const schema = JSON.parse(readFileSync(join(SCHEMA_DIR, files[0]), 'utf8'))
  const fields = Array.isArray(schema.fields) ? schema.fields : []
  const scalarRefs = fields.filter((f) => f?.type === 'reference').map((f) => f.name)
  const arrayRefs = fields
    .filter((f) => f?.type === 'arrayOf' && f?.of?.type === 'reference')
    .map((f) => f.name)
  if (scalarRefs.length === 0) fail(`schema ${files[0]} declares no scalar { type:"reference" } field`)
  if (arrayRefs.length === 0)
    fail(`schema ${files[0]} declares no { type:"arrayOf", of:{ type:"reference" } } field`)
  return { name: schema.name, scalarRefs, arrayRefs }
}

const schema = loadSchema()

// ── Load the seed ────────────────────────────────────────────────────────────
let seed
try {
  seed = JSON.parse(readFileSync(SEED_PATH, 'utf8'))
} catch (e) {
  fail(`seed.json unreadable or invalid JSON: ${e.message}`)
}

let docCount = 0
let avgOutDegree = 0

if (seed && schema) {
  const muts = Array.isArray(seed.mutations) ? seed.mutations : null
  if (!muts) {
    fail('seed.json must be a { "mutations": [ … ] } payload')
  } else {
    const docs = []
    for (const [i, m] of muts.entries()) {
      const doc = m?.createOrReplace
      if (!doc) {
        fail(`mutation[${i}] is not a createOrReplace — the single-type bootstrap seeds createOrReplace only`)
        continue
      }
      docs.push(doc)
    }

    const ids = new Set(docs.map((d) => d._id).filter(Boolean))
    docCount = docs.length
    const expectedType = schema.name

    let totalOutDegree = 0
    for (const doc of docs) {
      const label = doc._id || '(no _id)'

      if (!doc._id) fail(`a document has no _id`)
      if (doc._type !== expectedType)
        fail(`${label}: _type "${doc._type}" ≠ the single seed type "${expectedType}" (mixed types are refused by bootstrap)`)

      if (typeof doc.title !== 'string' || doc.title.trim() === '')
        fail(`${label}: missing or empty title`)

      if (!Array.isArray(doc.body) || doc.body.length === 0)
        fail(`${label}: missing or empty PortableDocument body (expected a non-empty array of blocks)`)
      else if (!doc.body.every((b) => b && typeof b === 'object' && typeof b.type === 'string'))
        fail(`${label}: body has a block without a string "type"`)

      // Reference validation — scalar + arrayOf, discovered from the schema.
      let outDegree = 0
      for (const field of schema.scalarRefs) {
        const v = doc[field]
        if (v === undefined || v === null || v === '') continue
        if (typeof v !== 'string') {
          fail(`${label}.${field}: scalar reference must be a bare doc id string, got ${typeof v}`)
          continue
        }
        outDegree += 1
        if (!ids.has(v)) fail(`${label}.${field}: dangling reference → "${v}" is not a doc _id in this seed`)
      }
      for (const field of schema.arrayRefs) {
        const arr = doc[field]
        if (arr === undefined || arr === null) continue
        if (!Array.isArray(arr)) {
          fail(`${label}.${field}: arrayOf reference must be an array of bare doc ids`)
          continue
        }
        for (const v of arr) {
          if (typeof v !== 'string' || v === '') {
            fail(`${label}.${field}: array element must be a non-empty doc id string`)
            continue
          }
          outDegree += 1
          if (!ids.has(v)) fail(`${label}.${field}: dangling reference → "${v}" is not a doc _id in this seed`)
        }
      }
      totalOutDegree += outDegree
    }

    // Distinct _id guard — a duplicate _id would silently collapse a node.
    if (ids.size !== docs.filter((d) => d._id).length)
      fail(`duplicate _id detected — every document must have a distinct id`)

    avgOutDegree = docCount === 0 ? 0 : totalOutDegree / docCount
    if (docCount > 0 && avgOutDegree <= 1)
      fail(`average out-degree ${avgOutDegree.toFixed(2)} ≤ 1 — the graph would be islands, not a constellation`)

    // Body variety — several docs must show off different block types.
    const blockTypes = new Set()
    let richDocs = 0
    for (const doc of docs) {
      if (!Array.isArray(doc.body)) continue
      const types = new Set(doc.body.map((b) => b?.type).filter(Boolean))
      types.forEach((t) => blockTypes.add(t))
      if (types.size >= 3) richDocs += 1
    }
    if (blockTypes.size < 5)
      fail(`only ${blockTypes.size} distinct block types across all bodies — PortableDoc variety is too thin (want ≥5)`)
    if (richDocs < 5)
      fail(`only ${richDocs} docs carry ≥3 distinct block types — want ≥5 to showcase PortableDoc`)

    if (errors.length === 0) {
      console.log(`seed-lint: OK`)
      console.log(`  type            ${expectedType}`)
      console.log(`  documents       ${docCount}`)
      console.log(`  avg out-degree  ${avgOutDegree.toFixed(2)}`)
      console.log(`  distinct blocks ${blockTypes.size} (${[...blockTypes].sort().join(', ')})`)
      console.log(`  rich docs (≥3 block types) ${richDocs}`)
    }
  }
}

if (errors.length > 0) {
  console.error(`seed-lint: FAIL (${errors.length} problem${errors.length === 1 ? '' : 's'})`)
  for (const e of errors) console.error(`  ✗ ${e}`)
  process.exit(1)
}
