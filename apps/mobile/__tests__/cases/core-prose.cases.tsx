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
  { type: 'callout', block: { type: 'callout', tone: 'info', title: 'Note', text: 'careful' } },
  { type: 'blockquote', block: { type: 'blockquote', text: 'quoted', cite: 'someone' } },
  { type: 'quote', block: { type: 'quote', text: 'quoted' } },
  { type: 'footnote', block: { type: 'footnote', notes: [{ text: 'a note' }] } },
]
