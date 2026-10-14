#!/usr/bin/env node
// Rebuilds api/test/fixtures/groq_test_suite/suite.ndjson.gz from Sanity's GROQ
// test suite (https://github.com/sanity-io/groq-test-suite, MIT).
//
//   curl -sfLO https://github.com/sanity-io/groq-test-suite/releases/download/v1.0.5/suite.ndjson
//   node tooling/groq/build-conformance-fixture.mjs suite.ndjson
//
// It keeps the cases groq-js runs: GROQ version 1.2.0, the features groq-js
// supports, no perf files, and only datasets embedded in the suite (the
// external movies dataset is left out). Update the floor in
// api/test/barkpark/groq/conformance_test.exs after rebuilding.

import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import {fileURLToPath} from 'node:url'

const GROQ_VERSION = [1, 2, 0]
const SUPPORTED_FEATURES = new Set(['portableText', 'customFunctions', 'internalDocuments', 'contentReleases'])
const here = path.dirname(fileURLToPath(import.meta.url))
const target = path.join(here, '../../api/test/fixtures/groq_test_suite/suite.ndjson.gz')

// The suite's version ranges are `>= X.Y` or an exact `X.Y`.
function versionSatisfies(range) {
  const match = /^(>=)?\s*(\d+)\.(\d+)(?:\.(\d+))?$/.exec(range.trim())
  if (!match) throw new Error(`unknown version range: ${range}`)
  const wanted = [Number(match[2]), Number(match[3]), Number(match[4] || 0)]
  const cmp = GROQ_VERSION.map((n, i) => n - wanted[i]).find((d) => d !== 0) || 0
  return match[1] ? cmp >= 0 : cmp === 0
}

const source = process.argv[2]
if (!source) {
  console.error('usage: build-conformance-fixture.mjs <suite.ndjson>')
  process.exit(2)
}

const entries = fs
  .readFileSync(source, 'utf8')
  .split('\n')
  .filter(Boolean)
  .map((line) => JSON.parse(line))

const datasets = new Map(entries.filter((e) => e._type === 'dataset').map((d) => [d._id, d]))
const tests = []
const skipped = {}
const skip = (reason) => (skipped[reason] = (skipped[reason] || 0) + 1)

for (const e of entries) {
  if (e._type !== 'test') continue
  if (!e.features.every((f) => SUPPORTED_FEATURES.has(f))) skip('feature')
  else if (e.version && !versionSatisfies(e.version)) skip('version')
  else if (/perf/.test(e.filename)) skip('perf')
  else if (!datasets.get(e.dataset._ref)?.documents) skip('external dataset')
  else {
    tests.push({
      _type: 'test',
      name: e.name,
      filename: e.filename,
      query: e.query,
      result: e.result,
      valid: e.valid,
      params: e.params,
      dataset: e.dataset._ref,
      features: e.features,
    })
  }
}

const used = [...new Set(tests.map((t) => t.dataset))].map((id) => ({
  _type: 'dataset',
  _id: id,
  documents: datasets.get(id).documents,
}))

const ndjson = [...used, ...tests].map((x) => JSON.stringify(x)).join('\n') + '\n'
fs.writeFileSync(target, zlib.gzipSync(ndjson, {level: 9}))
console.log(`${tests.length} tests, ${used.length} datasets, skipped ${JSON.stringify(skipped)} -> ${target}`)
