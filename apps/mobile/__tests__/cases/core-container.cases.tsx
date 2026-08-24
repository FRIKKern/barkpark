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
  // With an href — the field the renderer used to drop on the floor (mob-zb-s3).
  { type: 'action', block: { type: 'action', label: 'Open', href: 'https://example.com/board' } },
  {
    type: 'paper-links',
    block: {
      type: 'paper-links',
      title: 'Continue reading',
      refs: [
        {
          slug: 'paper-authoring-excellence',
          title: 'Paper authoring excellence',
          description: 'A practical guide to publishing clear, useful Papers.',
        },
      ],
    },
  },
]
