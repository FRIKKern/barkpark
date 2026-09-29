#!/usr/bin/env node
// parity-check.test.mjs — the proof that the parity comparator CAN LOSE.
//
// WHY THIS FILE EXISTS (task-4282890c59de377e). The CI step
// "Query-parity control (same tree, stub corpus)" used to run parity-check
// --write and then --compare against the SAME stub in the SAME run. Nothing
// changed between the two calls, so no input CI ever constructed could reach
// the divergence arm (exit 2) or the determinism arm (exit 3). Replacing
// sameSet() with `return true` left both commands exiting 0 and printing
// "OK — every (query, engine) hit set matches …. Parity holds." A comparator
// that cannot lose reports a verdict it never measured.
//
// The fix has two halves and this file is the second one:
//   · CI compares against scripts/parity-stub-baseline.json, a COMMITTED
//     expectation the run did not produce (and --compare refuses to write one);
//   · this selftest drives parity-check's OWN compare path against servers it
//     controls, and asserts each exit code by number:
//
//       identical corpus, committed-shape baseline  -> 0
//       baseline with one id trimmed                -> 2   (divergence arm)
//       server that flips on the 2nd fetch of a pair-> 3   (determinism arm)
//       baseline file absent                        -> 1   (no regeneration)
//
// Neuter sameSet() and the 2-arm and the 3-arm both go green -> two failing
// tests -> the CI step reds. That is the property the row asked for.
//
// Node stdlib only (node:test, node:http). Run through the floor runner so a
// glob that stops matching cannot pass on emptiness:
//   node ../../scripts/node-test-floor.mjs --floor 1 'scripts/parity-check.test.mjs'
// (--floor is the runner's FILE count, not a test count; its per-file zero-test
// floor is what refuses a file that registers nothing.)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { execFile } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const TOOL = join(HERE, 'parity-check.mjs')
const COMMITTED_BASELINE = join(HERE, 'parity-stub-baseline.json')

// parity-check refuses a fixture under 10 queries, so the selftest corpus is
// 10 wide. Every query hits at least one doc; `wobble` is the pair the flipping
// server mutates.
const QUERIES = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta', 'eta', 'theta', 'iota', 'wobble']
const HITS = Object.fromEntries(QUERIES.map((q, i) => [q, [`doc-${q}-1`, `doc-${q}-2`, `doc-${q}-${i}`]]))

/**
 * A minimal stand-in for the flat search route. `flip` makes the SECOND and
 * later fetch of a given (query, engine) answer a different hit set — the one
 * thing the real stub corpus, being canned, can never do, and therefore the
 * only way a test can reach the determinism arm.
 */
function startServer({ flip = null } = {}) {
  const seen = new Map()
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    const q = url.searchParams.get('q') ?? ''
    const engine = url.searchParams.get('engine') ?? ''
    const k = `${engine}::${q}`
    const n = (seen.get(k) ?? 0) + 1
    seen.set(k, n)
    let ids = HITS[q] ?? []
    if (flip && q === flip && n > 1) ids = ids.slice(0, 1)
    const body = JSON.stringify({
      count: ids.length,
      query: q,
      facets: null,
      documents: ids.map((id) => ({ _id: id, _type: 'entry' })),
    })
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
    res.end(body)
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      resolve({
        base: `http://127.0.0.1:${port}`,
        close: () => new Promise((r) => server.close(r)),
      })
    })
  })
}

/** Run the tool and hand back its exit code verbatim — never a truthiness. */
function run(args) {
  return new Promise((resolve) => {
    execFile(process.execPath, [TOOL, ...args], { cwd: HERE }, (err, stdout, stderr) => {
      resolve({ code: err ? (err.code ?? 1) : 0, stdout, stderr })
    })
  })
}

//  and , not : a sync finally around a
// returned promise deletes the directory before the body has used it, and the
// tool then fails on a missing fixture — a green-looking harness fault wearing
// the costume of a real refusal.
async function withTmp(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'parity-selftest-'))
  try {
    return await fn(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const FIXTURE = (dir) => {
  const p = join(dir, 'queries.json')
  writeFileSync(p, JSON.stringify(QUERIES))
  return p
}

const BASE_ARGS = (base, fixture) => [
  '--base', base, '--dataset', 'selftest', '--type', 'entry',
  '--engines', 'indx,postgres', '--fixture', fixture,
]

test('an identical corpus compares clean — exit 0', async () => {
  const s = await startServer()
  try {
    await withTmp(async (dir) => {
      const fx = FIXTURE(dir)
      const bl = join(dir, 'baseline.json')
      const w = await run([...BASE_ARGS(s.base, fx), '--write', bl])
      assert.equal(w.code, 0, w.stderr)
      const c = await run([...BASE_ARGS(s.base, fx), '--compare', bl])
      assert.equal(c.code, 0, c.stderr)
      assert.match(c.stdout, /Parity holds/)
    })
  } finally {
    await s.close()
  }
})

test('a trimmed baseline reds the DIVERGENCE arm — exit 2', async () => {
  const s = await startServer()
  try {
    await withTmp(async (dir) => {
      const fx = FIXTURE(dir)
      const bl = join(dir, 'baseline.json')
      assert.equal((await run([...BASE_ARGS(s.base, fx), '--write', bl])).code, 0)
      // Hand-trim ONE id from ONE (query, engine). Everything else is identical,
      // so exit 2 can only come from the hit-set comparison itself.
      const doc = JSON.parse(readFileSync(bl, 'utf8'))
      doc.results.alpha.indx = doc.results.alpha.indx.slice(0, 1)
      writeFileSync(bl, JSON.stringify(doc, null, 2))
      const c = await run([...BASE_ARGS(s.base, fx), '--compare', bl])
      assert.equal(c.code, 2, `expected the divergence arm; got ${c.code}\n${c.stdout}${c.stderr}`)
      assert.match(c.stderr, /hit-list divergence/)
      assert.match(c.stderr, /indx :: alpha/)
    })
  } finally {
    await s.close()
  }
})

test('a server that answers differently on the 2nd fetch reds the DETERMINISM arm — exit 3', async () => {
  const stable = await startServer()
  let flipping
  try {
    await withTmp(async (dir) => {
      const fx = FIXTURE(dir)
      const bl = join(dir, 'baseline.json')
      // The baseline is taken from the STABLE server, so the flipping run's
      // failure is about the repeat fetch, not about a mismatched expectation.
      assert.equal((await run([...BASE_ARGS(stable.base, fx), '--write', bl])).code, 0)
      flipping = await startServer({ flip: 'wobble' })
      const c = await run([...BASE_ARGS(flipping.base, fx), '--compare', bl])
      assert.equal(c.code, 3, `expected the determinism arm; got ${c.code}\n${c.stdout}${c.stderr}`)
      assert.match(c.stderr, /different hit SET across a repeat run/)
      assert.match(c.stderr, /wobble/)
    })
  } finally {
    await stable.close()
    if (flipping) await flipping.close()
  }
})

test('an absent baseline is a REFUSAL, not a regeneration — exit 1 and no file written', async () => {
  const s = await startServer()
  try {
    await withTmp(async (dir) => {
      const fx = FIXTURE(dir)
      const missing = join(dir, 'not-here.json')
      const c = await run([...BASE_ARGS(s.base, fx), '--compare', missing])
      assert.equal(c.code, 1, `expected the refusal; got ${c.code}\n${c.stdout}${c.stderr}`)
      assert.match(c.stderr, /NEVER regenerates a baseline/)
      assert.equal(existsSync(missing), false, 'the tool wrote the baseline it was asked to compare against')
    })
  } finally {
    await s.close()
  }
})

test('the committed baseline CI compares against exists and is shaped', () => {
  assert.ok(existsSync(COMMITTED_BASELINE), `${COMMITTED_BASELINE} is missing — CI has nothing to compare against`)
  const doc = JSON.parse(readFileSync(COMMITTED_BASELINE, 'utf8'))
  assert.ok(Array.isArray(doc._meta?.queries) && doc._meta.queries.length >= 10, 'baseline must carry >=10 queries')
  assert.deepEqual(doc._meta.engines, ['indx', 'postgres'])
  assert.equal(doc._meta.dataset, 'smoke')
  assert.equal(doc._meta.type, 'entry')
  // A baseline of all-empty hit sets would compare clean against a dead server.
  const total = Object.values(doc.results).flatMap((byEngine) => Object.values(byEngine)).reduce((n, ids) => n + ids.length, 0)
  assert.ok(total > 0, 'every recorded hit set is empty — this baseline asserts nothing')
})
