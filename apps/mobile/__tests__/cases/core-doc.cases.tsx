// Authored cases for the core-doc family (src/papers/portabledoc/blocks/
// core-doc.tsx). Round-2 structure natives (status-legend, card, pipeline,
// stage, task-detail, roadmap — mob-zb-s3) add their cases here.
import type { BlockCase } from './types'

export const coreDocCases: BlockCase[] = [
  { type: 'note', block: { type: 'note', label: 'NB', text: 'noted' } },
  { type: 'notes', block: { type: 'notes', items: [{ text: 'noted' }] } },
  { type: 'cards', block: { type: 'cards', items: [{ title: 'Card', text: 'body' }] } },
]
