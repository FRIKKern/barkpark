// Authored cases for the core-prose family (src/papers/portabledoc/blocks/
// core-prose.tsx): one per registered type, aliases included.
import type { BlockCase } from './types'

export const coreProseCases: BlockCase[] = [
  { type: 'heading', block: { type: 'heading', level: 2, text: 'Heading' } },
  { type: 'paragraph', block: { type: 'paragraph', text: 'body copy' } },
  // The content[] shape, not the bare `text` one: this is the shape the 3 live
  // eyebrows persist and the shape that rendered BLANK until the paragraphInline
  // law reached this renderer (mob-zb-s3).
  { type: 'eyebrow', block: { type: 'eyebrow', content: [{ type: 'text', value: 'EYEBROW' }] } },
  { type: 'byline', block: { type: 'byline', items: ['Ada', 'Grace'] } },
  { type: 'ingress', block: { type: 'ingress', text: 'the lede' } },
  { type: 'pullquote', block: { type: 'pullquote', text: 'pulled' } },
  { type: 'list', block: { type: 'list', items: ['one', 'two'] } },
  { type: 'bulletList', block: { type: 'bulletList', items: ['one'] } },
  { type: 'bullet_list', block: { type: 'bullet_list', items: ['one'] } },
  { type: 'bulleted-list', block: { type: 'bulleted-list', items: ['one'] } },
  { type: 'bulleted_list', block: { type: 'bulleted_list', items: ['one'] } },
  { type: 'numbered_list', block: { type: 'numbered_list', items: ['one'] } },
  // charter D57: the h-tag + ordered-list live drift. The level-less shapes are
  // the real corpus ones — __tests__/headingAliasDrift.test.tsx pins the levels.
  { type: 'h1', block: { type: 'h1', level: 1, text: 'H1' } },
  { type: 'h2', block: { type: 'h2', text: 'H2 with no level' } },
  { type: 'h3', block: { type: 'h3', text: 'H3 with no level' } },
  { type: 'ordered-list', block: { type: 'ordered-list', items: ['one'] } },
  { type: 'callout', block: { type: 'callout', tone: 'info', title: 'Note', text: 'careful' } },
  { type: 'blockquote', block: { type: 'blockquote', text: 'quoted', cite: 'someone' } },
  { type: 'quote', block: { type: 'quote', text: 'quoted' } },
  { type: 'footnote', block: { type: 'footnote', notes: [{ text: 'a note' }] } },
]
