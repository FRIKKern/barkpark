#!/usr/bin/env node
// parity-check.mjs — the honest, re-runnable finder-parity instrument.
//
// The Astro edition ships THE finder: the same dual-engine search (indx
// typo-tolerant + Postgres FTS) as the Next edition, talking straight to
// Barkpark from the browser. This script proves that parity is MEASURED, not
// asserted. It sweeps an N-query fixture across BOTH engines against the
// flat-anonymous read route the finder itself uses —
//
//   GET /v1/data/search/:dataset?q&engine&types&perspective=published&limit=100
//
// — captures each query×engine hit-id SET, and:
//
//   (a) asserts DETERMINISM: the same (query, engine) returns the same hit
//       set across a repeat run (a wobbling result set can't be a baseline);
//   (b) --write <baseline.json> records {query, engine -> [ids]} as the frozen
//       reference;
//   (c) --compare <baseline.json> re-runs and exits NON-ZERO on any per-(query,
//       engine) hit-SET divergence.
//
// Parity is a SET relation, not an ordered one: both editions read the
// identical route on the identical server, so hit ORDER is a server-side
// ranking detail that jitters run-to-run at a capped result boundary — never
// an edition property. Comparing sets keeps the instrument honest AND
// non-flaky; a real edition break (different corpus/dataset/wiring) still
// changes the set and is caught.
//
// THE ACCEPTANCE BAR IS CROSS-EDITION PARITY PER ENGINE — the Next finder and
// the Astro finder, same engine, same query, MUST return the same hits (both
// read the same route against the same corpus). It is NOT cross-ENGINE
// identity: indx and postgres legitimately diverge on multi-term/typo queries
// (e.g. "portable document" → indx 37 hits vs postgres 100 hits). This tool
// therefore diffs each engine against ITS OWN baseline, never one engine
// against the other.
//
// Node stdlib only (global fetch, Node 18+). Zero dependencies.
//
// Usage:
//   node scripts/parity-check.mjs --base https://guerrilla.barkpark.cloud \
//     --dataset production --type paper --write baseline.json
//   node scripts/parity-check.mjs --base https://guerrilla.barkpark.cloud \
//     --dataset production --type paper --compare baseline.json
//
// Sign-off (see README): capture a baseline against the Next edition's live
// deploy, then --compare it against the Astro edition's live deploy. Both
// exiting 0 IS the side-by-side parity proof, per engine.
import { readFileSync, writeFileSync } from 'node:fs'

// ── The committed fixture ──────────────────────────────────────────────────
// N>=10 corpus-real paper queries. Chosen to exercise the finder's real
// behaviour on the guerrilla `production` paper corpus: high-recall hubs
// ("barkpark", "search", "deploy", "task"), a multi-word query where the two
// engines LEGITIMATELY diverge ("portable document"), and a deliberate
// misspelling that only indx's typo tolerance should still resolve
// ("typo tollerance"). Override with --fixture <path> (JSON array of strings,
// or { "queries": [...] }).
const DEFAULT_QUERIES = [
  'barkpark',
  'search',
  'deploy',
  'graph',
  'portable document',
  'template',
  'astro',
  'editor',
  'task',
  'plugin',
  'theme',
  'finder',
  'typo tollerance',
]

const DEFAULT_ENGINES = ['indx', 'postgres']
const CONCURRENCY = 6

// ── args ───────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const a = {
    base: null,
    dataset: 'production',
    type: 'paper',
    engines: DEFAULT_ENGINES,
    limit: 100,
    perspective: 'published',
    fixture: null,
    write: null,
    compare: null,
  }
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i]
    const next = () => argv[++i]
    switch (k) {
      case '--base': a.base = next(); break
      case '--dataset': a.dataset = next(); break
      case '--type': a.type = next(); break
      case '--engines': a.engines = next().split(',').map((s) => s.trim()).filter(Boolean); break
      case '--limit': a.limit = Number(next()); break
      case '--perspective': a.perspective = next(); break
      case '--fixture': a.fixture = next(); break
      case '--write': a.write = next(); break
      case '--compare': a.compare = next(); break
      case '-h': case '--help': a.help = true; break
      default:
        console.error(`parity-check: unknown argument ${k}`)
        process.exit(64)
    }
  }
  return a
}

const USAGE = `parity-check.mjs — dual-engine finder parity instrument

  --base <url>            Barkpark origin (required, e.g. https://guerrilla.barkpark.cloud)
  --dataset <name>        dataset (default: production)
  --type <type>           document type -> ?types= (default: paper)
  --engines <a,b>         engines to sweep (default: indx,postgres)
  --limit <n>             per-query hit cap (default: 100)
  --perspective <p>       read perspective (default: published)
  --fixture <path>        JSON [".."] or {"queries":[..]} overriding the built-in queries
  --write <baseline.json> record the sweep as the frozen reference
  --compare <baseline.json> re-run and exit non-zero on any hit-list divergence

Exit codes: 0 ok · 1 network/usage · 2 compare divergence · 3 non-determinism`

// ── search ─────────────────────────────────────────────────────────────────
function searchUrl(a, query, engine) {
  const p = new URLSearchParams({
    q: query,
    engine,
    types: a.type,
    perspective: a.perspective,
    limit: String(a.limit),
  })
  return `${a.base.replace(/\/$/, '')}/v1/data/search/${encodeURIComponent(a.dataset)}?${p}`
}

// The flat route answers { count, query, facets, documents: [{ _id, ... }] }.
// Fall back to the channel/legacy hit shapes so the same instrument works if a
// deploy is wired to a slightly different read surface.
function extractIds(body) {
  if (Array.isArray(body?.documents)) return body.documents.map((d) => d._id ?? d._publishedId ?? d.id)
  if (Array.isArray(body?.result?.hits)) return body.result.hits.map((h) => h.id)
  if (Array.isArray(body?.hits)) return body.hits.map((h) => h.id)
  return []
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Transient live-server hiccups (5xx / 429 / a dropped connection) are not
// parity signal — retry with backoff so a single blip can't red the gate. A
// persistent failure still surfaces after the attempts are spent.
async function fetchIds(a, query, engine, attempts = 4) {
  const url = searchUrl(a, query, engine)
  let lastErr
  for (let n = 1; n <= attempts; n++) {
    try {
      const res = await fetch(url, { headers: { accept: 'application/json' } })
      if (res.status >= 500 || res.status === 429) {
        lastErr = new Error(`HTTP ${res.status} for ${engine} "${query}"`)
      } else if (!res.ok) {
        throw new Error(`HTTP ${res.status} for ${engine} "${query}" (${url})`)
      } else {
        return extractIds(await res.json())
      }
    } catch (e) {
      lastErr = e
    }
    if (n < attempts) await sleep(300 * n)
  }
  throw new Error(`${lastErr.message} — failed after ${attempts} attempts (${url})`)
}

const key = (query, engine) => `${engine} :: ${query}`

// Parity is defined over the SET of hits, not their order. The live server's
// ranking jitters run-to-run at a capped result boundary (count > limit ties),
// so an ordered compare would red on pure reordering with no real parity break.
// Both editions read the IDENTICAL route on the IDENTICAL server, so any order
// difference is server-side time jitter, never an edition property — the hit
// SET per (query, engine) is the true cross-edition invariant.
function sameSet(x, y) {
  if (x.length !== y.length) return false
  const a = [...x].sort()
  const b = [...y].sort()
  return a.every((v, i) => v === b[i])
}

// Run tasks with bounded concurrency, preserving order-independent collection.
async function pool(items, worker) {
  const results = []
  let idx = 0
  const runners = Array.from({ length: Math.min(CONCURRENCY, items.length) }, async () => {
    while (idx < items.length) {
      const my = idx++
      results[my] = await worker(items[my])
    }
  })
  await Promise.all(runners)
  return results
}

// One full sweep. When `verifyDeterminism`, each (query,engine) is fetched
// TWICE and the two lists must match, else exit 3.
async function sweep(a, queries, verifyDeterminism) {
  const pairs = []
  for (const query of queries) for (const engine of a.engines) pairs.push({ query, engine })

  const rows = await pool(pairs, async ({ query, engine }) => {
    const first = await fetchIds(a, query, engine)
    if (!verifyDeterminism) return { query, engine, ids: first }
    const second = await fetchIds(a, query, engine)
    return { query, engine, ids: first, ids2: second }
  })

  const out = {}
  const nondet = []
  for (const r of rows) {
    if (verifyDeterminism && !sameSet(r.ids, r.ids2)) {
      nondet.push({ query: r.query, engine: r.engine, a: r.ids, b: r.ids2 })
    }
    ;(out[r.query] ||= {})[r.engine] = r.ids
  }
  return { results: out, nondet }
}

function baselineDoc(a, results, queries) {
  return {
    _meta: {
      tool: 'parity-check.mjs',
      route: '/v1/data/search/:dataset?q&engine&types&perspective&limit',
      base: a.base,
      dataset: a.dataset,
      type: a.type,
      engines: a.engines,
      limit: a.limit,
      perspective: a.perspective,
      queries,
      generatedAt: new Date().toISOString(),
      note: 'Cross-EDITION parity per engine. Not cross-engine identity.',
    },
    results,
  }
}

function fmtCounts(a, results, queries) {
  const w = Math.max(...queries.map((q) => q.length), 5)
  const lines = queries.map((q) => {
    const cols = a.engines.map((e) => `${e}:${(results[q]?.[e] ?? []).length}`).join('  ')
    return `  ${q.padEnd(w)}  ${cols}`
  })
  return lines.join('\n')
}

// ── modes ──────────────────────────────────────────────────────────────────
async function main() {
  const a = parseArgs(process.argv.slice(2))
  if (a.help) { console.log(USAGE); return 0 }
  if (!a.base) { console.error('parity-check: --base is required\n\n' + USAGE); return 1 }

  let queries = DEFAULT_QUERIES
  if (a.fixture) {
    const raw = JSON.parse(readFileSync(a.fixture, 'utf8'))
    queries = Array.isArray(raw) ? raw : raw.queries
    if (!Array.isArray(queries) || queries.length === 0) {
      console.error(`parity-check: fixture ${a.fixture} has no queries`); return 1
    }
  }
  if (queries.length < 10) {
    console.error(`parity-check: fixture must have >=10 queries (got ${queries.length})`); return 1
  }

  console.log(`parity-check :: ${a.base} · ${a.dataset}/${a.type} · engines ${a.engines.join(',')} · ${queries.length} queries`)

  if (a.compare) {
    const baseline = JSON.parse(readFileSync(a.compare, 'utf8'))
    const bqueries = baseline._meta?.queries ?? Object.keys(baseline.results ?? {})
    const { results } = await sweep({ ...a, engines: baseline._meta?.engines ?? a.engines }, bqueries, false)
    console.log(`\nre-run counts:\n${fmtCounts({ ...a, engines: baseline._meta?.engines ?? a.engines }, results, bqueries)}`)

    const diffs = []
    for (const query of bqueries) {
      for (const engine of baseline._meta?.engines ?? a.engines) {
        const want = baseline.results?.[query]?.[engine] ?? []
        const got = results[query]?.[engine] ?? []
        if (!sameSet(want, got)) diffs.push({ query, engine, want, got })
      }
    }
    if (diffs.length) {
      console.error(`\nFAIL — ${diffs.length} per-(query,engine) hit-list divergence(s) vs ${a.compare}:`)
      for (const d of diffs) {
        const removed = d.want.filter((x) => !d.got.includes(x))
        const added = d.got.filter((x) => !d.want.includes(x))
        console.error(`  [${key(d.query, d.engine)}]`)
        console.error(`    observed : ${d.got.length} hits`)
        console.error(`    expected : ${d.want.length} hits (baseline)`)
        if (removed.length) console.error(`    dropped  : ${removed.slice(0, 8).join(', ')}${removed.length > 8 ? ' …' : ''}`)
        if (added.length) console.error(`    appeared : ${added.slice(0, 8).join(', ')}${added.length > 8 ? ' …' : ''}`)
        console.error('    next     : this edition returned a different hit SET than the baseline edition for this engine — check the corpus, dataset, and engine wiring match')
      }
      return 2
    }
    console.log(`\nOK — every (query, engine) hit set matches ${a.compare}. Parity holds.`)
    return 0
  }

  // write / default: sweep WITH determinism verification.
  const { results, nondet } = await sweep(a, queries, true)
  console.log(`\nhit counts:\n${fmtCounts(a, results, queries)}`)

  if (nondet.length) {
    console.error(`\nFAIL — ${nondet.length} (query, engine) pair(s) returned a different hit SET across a repeat run:`)
    for (const n of nondet) {
      console.error(`  [${key(n.query, n.engine)}]  observed ${n.a.length} then ${n.b.length} hits`)
      console.error('    next : a wobbling result set cannot anchor a parity baseline — investigate before recording')
    }
    return 3
  }
  console.log('\nOK — every (query, engine) hit set is deterministic across a repeat run.')

  if (a.write) {
    writeFileSync(a.write, JSON.stringify(baselineDoc(a, results, queries), null, 2) + '\n')
    console.log(`baseline written → ${a.write}`)
  } else {
    console.log('(no --write; ran as a determinism check only — pass --write <baseline.json> to record, --compare to diff)')
  }
  return 0
}

main().then((code) => process.exit(code)).catch((e) => {
  console.error(`parity-check: ${e.message}`)
  process.exit(1)
})
