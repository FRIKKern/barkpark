// Authored cases for the core-media family (src/papers/portabledoc/blocks/
// core-media.tsx), including the two degrade cards (video/asciicast —
// mob-zb-s7, D46d). The video case carries a src ON PURPOSE: a src-less one
// renders null (the parity law), which would satisfy the tripwire vacuously.
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
  {
    type: 'video',
    block: {
      type: 'video',
      src: 'https://example.com/clip.mp4',
      poster: 'https://example.com/poster.png',
      captions: [{ lang: 'en', src: 'https://example.com/en.vtt' }],
      caption: 'Figure 2. a clip',
    },
  },
  {
    type: 'asciicast',
    block: {
      type: 'asciicast',
      src: 'https://example.com/session.cast',
      header: { width: 120, height: 40, duration: 95 },
    },
  },
]
