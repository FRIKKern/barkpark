// Contract test for the corpus-graph bake — `node --test src/lib/graph-normalize.test.ts`.
// Guards the shape the renderer depends on: the baked graph.json must be the
// normalized {nodes, edges, rootId} (alias-tolerant, orphan-edge-free, root =
// highest degree with "barkpark" preferred) — the same behaviour as the Next
// edition's lib/graph.ts, so the two landings render the same graph — PLUS the
// truncation truth (truncated + truncationReason), which the normalizer used to
// drop on the floor: the flag never reached the baked bytes, so the static
// edition could only ever present a capped corpus as if it were complete.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  normalizeCorpusGraph,
  computeRootId,
  markNonNavigable,
  readTruncation,
} from './graph-normalize.ts'

test('normalizes aliased upstream fields into the renderer shape', () => {
  const g = normalizeCorpusGraph({
    nodes: [
      { node_id: 'a', document_id: 'doc-a', _type: 'paper', name: 'Alpha' },
      { id: 'b', title: 'Beta', type: 'post' },
      { id: 'ghost', title: 'Ghost', phantom: true },
      { title: 'no-id — dropped' },
    ],
    edges: [
      { from: 'a', to: 'b', type: 'reference', weight: 2 },
      { source: 'b', target: 'ghost' },
      { from_id: 'a', to_id: 'absent-node' }, // orphan endpoint — dropped
      { from_id: 'a' }, // no target — dropped
    ],
  })

  assert.equal(g.nodes.length, 3)
  const a = g.nodes.find((n) => n.id === 'a')
  assert.deepEqual(a, { id: 'a', doc_id: 'doc-a', type: 'paper', title: 'Alpha' })
  const ghost = g.nodes.find((n) => n.id === 'ghost')
  assert.equal(ghost?.phantom, true)

  assert.equal(g.edges.length, 2, 'orphan + malformed edges dropped')
  assert.deepEqual(g.edges[0], { from_id: 'a', to_id: 'b', kind: 'reference', weight: 2 })
})

test('rootId is the highest-degree node, with "barkpark" winning outright', () => {
  const nodes = [
    { id: 'hub', doc_id: 'hub', type: 'post', title: 'Hub' },
    { id: 'leaf1', doc_id: 'leaf1', type: 'post', title: 'L1' },
    { id: 'leaf2', doc_id: 'leaf2', type: 'post', title: 'L2' },
  ]
  const edges = [
    { from_id: 'hub', to_id: 'leaf1' },
    { from_id: 'hub', to_id: 'leaf2' },
  ]
  assert.equal(computeRootId(nodes, edges), 'hub')
  assert.equal(
    computeRootId([...nodes, { id: 'barkpark', doc_id: 'bp', type: 'post', title: 'BP' }], edges),
    'barkpark',
  )
  assert.equal(computeRootId([], []), null)
})

test('a garbage upstream degrades to an empty graph, never a throw', () => {
  const empty = { nodes: [], edges: [], rootId: null, truncated: false, truncationReason: null }
  assert.deepEqual(normalizeCorpusGraph(null), empty)
  assert.deepEqual(normalizeCorpusGraph('nope'), empty)
  assert.deepEqual(normalizeCorpusGraph({}), empty)
})

/* ── truncation, end to end into the baked bytes ────────────────────────── */

test('truncation reaches the normalized payload instead of stopping at the normalizer', () => {
  const g = normalizeCorpusGraph({
    nodes: [{ id: 'a', type: 'paper', title: 'A' }],
    edges: [],
    truncated: true,
    truncation_reason: 'per_type_cap',
  })
  assert.equal(g.truncated, true)
  assert.equal(g.truncationReason, 'per_type_cap')
  // And it survives JSON — this IS what graph.json.ts ships.
  const baked = JSON.parse(JSON.stringify(g))
  assert.equal(baked.truncated, true)
  assert.equal(baked.truncationReason, 'per_type_cap')
})

test('D67: a reason without truncated:true is DISCARDED, not honoured', () => {
  assert.deepEqual(readTruncation({ truncation_reason: 'per_type_cap' }), {
    truncated: false,
    truncationReason: null,
  })
  // A truthy-but-not-true flag is a shape drift, not a cut.
  assert.deepEqual(readTruncation({ truncated: 'true', truncation_reason: 'node_budget' }), {
    truncated: false,
    truncationReason: null,
  })
  const g = normalizeCorpusGraph({ nodes: [], edges: [], truncation_reason: 'node_budget' })
  assert.equal(g.truncated, false)
  assert.equal(g.truncationReason, null)
})

test('a cut with no named reason stays a cut', () => {
  assert.deepEqual(readTruncation({ truncated: true }), {
    truncated: true,
    truncationReason: null,
  })
})

test('markNonNavigable phantoms non-built types, keeps edges, re-roots on a navigable node', () => {
  const base = normalizeCorpusGraph({
    nodes: [
      { id: 'p1', type: 'paper', title: 'P1' },
      { id: 't1', type: 'task', title: 'T1' },
      { id: 't2', type: 'task', title: 'T2' },
      { id: 'ghost', type: 'paper', title: 'G', phantom: true },
    ],
    edges: [
      { from_id: 't1', to_id: 'p1' },
      { from_id: 't1', to_id: 't2' },
    ],
  })
  // Un-marked, the hub 't1' (degree 2) would be root.
  assert.equal(base.rootId, 't1')

  const g = markNonNavigable(base, ['paper'])
  assert.equal(g.nodes.find((n) => n.id === 'p1')?.phantom, undefined, 'built type stays navigable')
  assert.equal(g.nodes.find((n) => n.id === 't1')?.phantom, true, 'non-built type is phantom')
  assert.equal(g.nodes.find((n) => n.id === 'ghost')?.phantom, true, 'upstream phantom preserved')
  assert.equal(g.edges.length, 2, 'edges untouched — phantoms keep their context lines')
  assert.equal(g.rootId, 'p1', 'root re-chosen from navigable nodes only')
})

test('markNonNavigable does not launder a capped corpus into a complete one', () => {
  const base = normalizeCorpusGraph({
    nodes: [
      { id: 'p1', type: 'paper', title: 'P1' },
      { id: 't1', type: 'task', title: 'T1' },
    ],
    edges: [],
    truncated: true,
    truncation_reason: 'per_type_cap',
  })
  const g = markNonNavigable(base, ['paper'])
  assert.equal(g.truncated, true)
  assert.equal(g.truncationReason, 'per_type_cap')
})
