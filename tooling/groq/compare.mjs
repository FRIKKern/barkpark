#!/usr/bin/env node
// Dev-only GROQ oracle: runs a corpus of queries through groq-js (Sanity's
// MIT-licensed reference engine) and through a Barkpark GROQ endpoint over the
// same documents, and reports where the two results differ.
//
// It is not shipped and not run in CI. groq-js is not a repository dependency;
// install it next to this script first:
//
//   npm install --no-save --no-package-lock groq-js@1.30.2
//
// Usage:
//
//   node tooling/groq/compare.mjs \
//     --endpoint http://127.0.0.1:4000/w/<ws>/p/<proj>/v2025-02-19/data/query/<dataset> \
//     --token <read token> \
//     --corpus corpus.json \
//     [--dataset documents.ndjson | --export <GET /w/<ws>/p/<proj>/v1/data/export/<dataset> url>] \
//     [--params params.json] [--perspective published] [--out report.json]
//     [--oracle-timeout 60] [--bench <id> --runs 50]
//
// corpus.json is an array of {id, query, params?}. params.json maps an id to a
// params object and wins over the corpus entry. Without --dataset the oracle's
// documents come from --export, shaped the way the GROQ endpoint shapes them.
// groq-js runs in a worker thread; a query it cannot finish within
// --oracle-timeout seconds is reported as `oracle-timeout`, not compared.
//
// The report holds only ids, pass/fail, error classes and GROQ node types.
// Keep corpora, datasets and reports built from private data out of the
// repository.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import {createRequire} from 'node:module'
import {fileURLToPath, pathToFileURL} from 'node:url'
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads'

const here = path.dirname(fileURLToPath(import.meta.url))

async function loadGroqJs() {
  const require = createRequire(path.join(here, 'package.json'))
  try {
    return await import(pathToFileURL(require.resolve('groq-js')).href)
  } catch {
    console.error('groq-js is missing: run `npm install --no-save --no-package-lock groq-js@1.30.2` at the repository root')
    process.exit(2)
  }
}

function parseArgs(argv) {
  const args = {}
  for (let i = 2; i < argv.length; i++) {
    const key = argv[i].replace(/^--/, '')
    const next = argv[i + 1]
    if (next === undefined || next.startsWith('--')) args[key] = true
    else {
      args[key] = next
      i++
    }
  }
  return args
}

// An export line is a Barkpark envelope; the GROQ endpoint drops `_draft`,
// `_publishedId`, and a `title` that is null. A set title stays.
function exportToSanity(doc) {
  const out = {...doc}
  delete out._draft
  delete out._publishedId
  if (out.title === null || out.title === undefined) delete out.title
  return out
}

// Documents in the oracle's order: by _id, as the endpoint returns `*`.
async function loadDataset(args) {
  let lines
  if (args.dataset) {
    lines = fs.readFileSync(args.dataset, 'utf8').split('\n')
  } else if (args.export) {
    const res = await fetch(args.export, {headers: {authorization: `Bearer ${args.token}`}})
    if (!res.ok) throw new Error(`export failed: ${res.status}`)
    lines = (await res.text()).split('\n')
  } else {
    throw new Error('pass --dataset or --export')
  }
  return lines
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l))
    .filter((d) => d && d._id && !d._barkpark_export)
    .map((d) => (args.dataset ? d : exportToSanity(d)))
    .sort((a, b) => (a._id < b._id ? -1 : a._id > b._id ? 1 : 0))
}

// Key order does not matter in JSON objects; array order does.
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((k) => [k, canonical(value[k])]),
    )
  }
  return value
}

function firstDifference(a, b, at = '$') {
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return `${at}: array length ${a.length} vs ${b.length}`
    for (let i = 0; i < a.length; i++) {
      const d = firstDifference(a[i], b[i], `${at}[${i}]`)
      if (d) return d
    }
    return null
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)])
    for (const k of keys) {
      if (!(k in a)) return `${at}.${k}: missing in groq-js`
      if (!(k in b)) return `${at}.${k}: missing in Barkpark`
      const d = firstDifference(a[k], b[k], `${at}.${k}`)
      if (d) return d
    }
    return null
  }
  if (typeof a === 'number' && typeof b === 'number' && a === b) return null
  return a === b ? null : `${at}: value differs (${typeof a} vs ${typeof b})`
}

// The GROQ node types and functions a query uses, for the failure summary.
function features(tree) {
  const found = new Set()
  const walk = (node) => {
    if (!node || typeof node !== 'object') return
    if (Array.isArray(node)) return node.forEach(walk)
    if (typeof node.type === 'string') {
      found.add(node.type)
      if (node.type === 'FuncCall') found.add(`fn:${node.namespace}::${node.name}`)
      if (node.type === 'PipeFuncCall') found.add(`pipe:${node.name}`)
      if (node.type === 'OpCall') found.add(`op:${node.op}`)
    }
    for (const [k, v] of Object.entries(node)) if (k !== 'value') walk(v)
  }
  walk(tree)
  return [...found].sort()
}

async function runEndpoint(args, query, params) {
  const url = new URL(args.endpoint)
  url.searchParams.set('perspective', args.perspective || 'published')
  url.searchParams.set('returnQuery', 'false')
  const started = performance.now()
  const res = await fetch(url, {
    method: 'POST',
    headers: {'content-type': 'application/json', authorization: `Bearer ${args.token}`},
    body: JSON.stringify({query, params}),
  })
  const elapsed = performance.now() - started
  const body = await res.json().catch(() => ({}))
  return {status: res.status, body, elapsed}
}

// Latency of one query: wall time seen by this client, and the `ms` the
// endpoint reports (server time, without connection and dev-only plug costs).
async function bench(args, entry, params) {
  const runs = Number(args.runs || 50)
  const wall = []
  const server = []
  for (let i = 0; i < runs; i++) {
    const r = await runEndpoint(args, entry.query, params)
    if (r.status !== 200) throw new Error(`bench query failed: ${r.status}`)
    wall.push(r.elapsed)
    server.push(r.body.ms)
  }
  const pct = (list, p) => {
    const sorted = [...list].sort((a, b) => a - b)
    return Math.round(sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)])
  }
  console.log(
    JSON.stringify({
      id: entry.id,
      runs,
      server_ms: {p50: pct(server, 50), p95: pct(server, 95), max: Math.max(...server)},
      wall_ms: {p50: pct(wall, 50), p95: pct(wall, 95), max: Math.round(Math.max(...wall))},
    }),
  )
}

// The oracle worker: holds the dataset and evaluates one query per message.
async function oracleWorker() {
  const groq = await loadGroqJs()
  const dataset = JSON.parse(fs.readFileSync(workerData.datasetFile, 'utf8'))
  parentPort.on('message', async ({query, params, now}) => {
    try {
      const tree = groq.parse(query, {params})
      const value = await groq.evaluate(tree, {dataset, params, timestamp: new Date(now)})
      parentPort.postMessage({ok: true, value: await value.get(), features: features(tree)})
    } catch (e) {
      parentPort.postMessage({ok: false, error: String(e.message).slice(0, 200)})
    }
  })
  parentPort.postMessage({ready: true})
}

class Oracle {
  constructor(datasetFile, timeoutMs) {
    this.datasetFile = datasetFile
    this.timeoutMs = timeoutMs
  }

  async start() {
    this.worker = new Worker(fileURLToPath(import.meta.url), {workerData: {datasetFile: this.datasetFile}})
    await new Promise((resolve, reject) => {
      this.worker.once('message', resolve)
      this.worker.once('error', reject)
    })
  }

  async evaluate(query, params, now) {
    if (!this.worker) await this.start()
    const reply = new Promise((resolve) => this.worker.once('message', resolve))
    let timer
    const timeout = new Promise((resolve) => {
      timer = setTimeout(() => resolve({timeout: true}), this.timeoutMs)
    })
    this.worker.postMessage({query, params, now})
    const result = await Promise.race([reply, timeout])
    clearTimeout(timer)
    if (result.timeout) {
      await this.worker.terminate()
      this.worker = null
    }
    return result
  }

  stop() {
    return this.worker?.terminate()
  }
}

async function main() {
  const args = parseArgs(process.argv)
  for (const required of ['endpoint', 'token', 'corpus']) {
    if (!args[required]) throw new Error(`--${required} is required`)
  }
  await loadGroqJs()
  const corpus = JSON.parse(fs.readFileSync(args.corpus, 'utf8'))
  const overrides = args.params ? JSON.parse(fs.readFileSync(args.params, 'utf8')) : {}
  const paramsFor = (entry) => overrides[entry.id] ?? (entry.params && !Array.isArray(entry.params) ? entry.params : {})

  if (args.bench) {
    const entry = corpus.find((e) => e.id === args.bench)
    if (!entry) throw new Error(`no corpus entry ${args.bench}`)
    return bench(args, entry, paramsFor(entry))
  }

  const datasetFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'groq-oracle-')), 'dataset.json')
  fs.writeFileSync(datasetFile, JSON.stringify(await loadDataset(args)))
  const oracle = new Oracle(datasetFile, Number(args['oracle-timeout'] || 60) * 1000)
  const now = args.now || new Date().toISOString()
  const results = []

  for (const entry of corpus) {
    const params = paramsFor(entry)
    const result = {id: entry.id, status: 'pass'}

    const answer = await oracle.evaluate(entry.query, params, now)
    if (answer.timeout) {
      result.status = 'oracle-timeout'
      results.push(result)
      continue
    }
    if (!answer.ok) {
      result.status = 'oracle-error'
      result.error = answer.error
      results.push(result)
      continue
    }
    result.features = answer.features
    const expected = canonical(answer.value)

    const actual = await runEndpoint(args, entry.query, params)
    result.ms = Math.round(actual.elapsed)
    if (actual.status !== 200) {
      result.status = 'endpoint-error'
      result.error = `${actual.status} ${actual.body?.error?.type || ''} ${actual.body?.error?.description || ''}`.slice(0, 300)
    } else {
      const diff = firstDifference(expected, canonical(actual.body.result))
      if (diff) {
        result.status = 'mismatch'
        result.diff = diff
      }
    }
    results.push(result)
    console.error(`${results.length}/${corpus.length} ${result.status} ${entry.id}`)
  }
  await oracle.stop()
  fs.rmSync(path.dirname(datasetFile), {recursive: true, force: true})

  const counts = results.reduce((acc, r) => ({...acc, [r.status]: (acc[r.status] || 0) + 1}), {})
  const summary = {total: results.length, ...counts}
  console.log(JSON.stringify(summary))
  for (const r of results.filter((r) => r.status !== 'pass')) {
    console.log(`${r.status}\t${r.id}\t${r.error || r.diff || ''}`)
  }
  if (args.out) fs.writeFileSync(args.out, JSON.stringify({summary, results}, null, 1))
}

if (isMainThread) {
  main().catch((e) => {
    console.error(e.message)
    process.exit(1)
  })
} else {
  oracleWorker()
}
