// Authored cases for the core-doc family (src/papers/portabledoc/blocks/
// core-doc.tsx). The six round-2 structure natives (mob-zb-s3) take their case
// inputs from the cross-surface parity fixtures in internal/pdrender/testdata/
// so the tripwire block and the semantic assertions in structureNatives.test.tsx
// exercise the SAME shapes the other surfaces are pinned against.
import type { BlockCase } from './types'

export const coreDocCases: BlockCase[] = [
  { type: 'note', block: { type: 'note', label: 'NB', text: 'noted' } },
  { type: 'notes', block: { type: 'notes', items: [{ text: 'noted' }] } },
  { type: 'cards', block: { type: 'cards', items: [{ title: 'Card', text: 'body', tone: 'danger' }] } },
  {
    type: 'card',
    block: {
      type: 'card',
      tone: 'info',
      slots: {
        media: [{ src: 'https://cdn.example.com/cover.png', alt: 'Cover art', width: 320, height: 180 }],
        title: [{ type: 'heading', text: 'Card title' }],
        body: [{ type: 'paragraph', content: [{ type: 'text', value: 'Card body text.' }] }],
        action: [{ type: 'action', label: 'Open the board', href: 'https://example.com/board' }],
      },
    },
  },
  {
    type: 'stage',
    block: { type: 'stage', kind: 'gate', title: 'Review', detail: 'checks the criteria', source: true },
  },
  {
    type: 'pipeline',
    block: {
      type: 'pipeline',
      nodes: [
        { kind: 'source', title: 'Ingest', detail: 'reads the queue', source: true },
        { kind: 'emit', title: 'Transform', detail: 'maps the rows', source: 'queue.ex:42' },
        { kind: 'gate', title: 'Publish', detail: 'writes the board' },
      ],
    },
  },
  // ZERO block props by design — the vocabulary IS the content.
  { type: 'status-legend', block: { type: 'status-legend' } },
  {
    type: 'task-detail',
    block: {
      type: 'task-detail',
      task: {
        title: 'Wire the harness',
        status: 'in_progress',
        priority: '1',
        labels: ['parity', 'w5'],
        timeline: [
          { label: 'Filed', status: 'open' },
          { label: 'Building', status: 'in_progress' },
          { label: 'Shipped', status: 'done' },
        ],
        criteria: [
          { met: true, text: 'Gen emits fixtures' },
          { met: false, text: 'Web realizes the projection' },
        ],
      },
    },
  },
  {
    type: 'roadmap',
    block: {
      type: 'roadmap',
      scale: ['Q1', 'Q2', 'Q3'],
      today: 55,
      snapshot: [
        { title: 'Foundation', status: 'done', phase_row: true, left: 0, width: 40 },
        { title: 'Ship the board', status: 'in_progress', left: 40, width: 35 },
      ],
    },
  },
]
