// Authored cases for the core-container family (src/papers/portabledoc/
// blocks/core-container.tsx).
import type { BlockCase } from './types'

export const coreContainerCases: BlockCase[] = [
  { type: 'section', block: { type: 'section', title: 'Sec', blocks: [] } },
  {
    type: 'columns',
    block: { type: 'columns', columns: [[{ type: 'paragraph', text: 'col' }]] },
  },
  { type: 'terminal', block: { type: 'terminal', title: 'sh', children: [] } },
  { type: 'steps', block: { type: 'steps', steps: [{ title: 'First' }] } },
  { type: 'expandable', block: { type: 'expandable', summary: 'More', blocks: [] } },
  { type: 'toc', block: { type: 'toc', items: [{ text: 'Outline', level: 1 }] } },
  { type: 'action', block: { type: 'action', label: 'Open' } },
]
