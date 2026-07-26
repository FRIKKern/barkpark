// Authored cases for the core-media family (src/papers/portabledoc/blocks/
// core-media.tsx). Round-2 media cards (video/asciicast — mob-zb-s7, D46d)
// add their cases here.
import type { BlockCase } from './types'

export const coreMediaCases: BlockCase[] = [
  { type: 'code', block: { type: 'code', value: 'const x = 1' } },
  { type: 'divider', block: { type: 'divider' } },
  { type: 'image', block: { type: 'image', src: 'https://example.com/a.png', alt: 'a' } },
  {
    type: 'figure',
    block: { type: 'figure', child: { type: 'paragraph', text: 'inner' }, caption: 'Figure 1. cap' },
  },
  { type: 'diagram', block: { type: 'diagram', source: 'flowchart TD\n A --> B' } },
]
