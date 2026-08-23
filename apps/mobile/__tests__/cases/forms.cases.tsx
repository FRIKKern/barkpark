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
]
