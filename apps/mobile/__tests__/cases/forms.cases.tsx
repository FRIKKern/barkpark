// Authored cases for the forms family (src/papers/portabledoc/blocks/
// forms.tsx) — the render-only question cards (mob-zb-s7-tail-media, D46a).
// The tripwire only asks that each registered type render without the
// unknown-block fallback; the CONTROL vocabulary and the two context lines are
// pinned in tailBlocks.test.tsx.
import type { BlockCase } from './types'

const questions = [
  {
    id: 'q1',
    prompt: 'Ship the degrade cards?',
    type: 'yesno',
    rationale: 'the corpus has none of these blocks yet',
    recommendation: 'ship them',
  },
  { id: 'q2', prompt: 'Rate the plan', type: 'scale', scale: { min: 1, max: 5 } },
]

export const formsCases: BlockCase[] = [
  { type: 'form', block: { type: 'form', questions } },
  { type: 'questionnaire', block: { type: 'questionnaire', questions } },
  // field-number (B085) — the labelled numeric definition row
  // (pbw-fix-field-number-react); value + unit exercises the full render path,
  // and the crown floor drives this exact case in both registers.
  { type: 'field-number', block: { type: 'field-number', label: 'Price', value: 19.99, unit: 'NOK' } },
  // The schema field blocks (task-7375ba22758155fa) — the same labelled row.
  { type: 'field-string', block: { type: 'field-string', label: 'Title', value: 'Notes' } },
  { type: 'field-slug', block: { type: 'field-slug', label: 'Slug', value: 'notes' } },
  { type: 'field-text', block: { type: 'field-text', label: 'Lead', value: 'Short.' } },
  { type: 'field-boolean', block: { type: 'field-boolean', label: 'Live', value: true } },
  {
    type: 'field-select',
    block: { type: 'field-select', label: 'Status', value: 'live', options: [{ value: 'live', label: 'Live' }] },
  },
  { type: 'field-datetime', block: { type: 'field-datetime', label: 'At', value: '2026-10-10T09:30' } },
  { type: 'field-color', block: { type: 'field-color', label: 'Accent', value: '#1e5347' } },
  { type: 'field-reference', block: { type: 'field-reference', label: 'Author', value: 'author-ada' } },
  { type: 'field-image', block: { type: 'field-image', label: 'Cover', value: 'https://example.com/c.jpg' } },
  {
    type: 'composite',
    block: { type: 'composite', label: 'SEO', fields: [{ name: 'title' }], value: { title: 'T' } },
  },
  { type: 'arrayOf', block: { type: 'arrayOf', label: 'Tags', value: ['a'] } },
  { type: 'codelist', block: { type: 'codelist', label: 'Lang', value: 'nob' } },
  {
    type: 'localizedText',
    block: { type: 'localizedText', label: 'Tagline', languages: ['nob'], value: { nob: 'Hei' } },
  },
]
