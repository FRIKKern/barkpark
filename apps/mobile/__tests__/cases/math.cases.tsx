// Authored cases for the math family (src/papers/portabledoc/blocks/math.tsx)
// — the native equation render (mob-zb-s7-tail-media, D45). The case exercises
// all three grammar productions at once (a fraction, a superscript and a macro)
// so the tripwire's render-without-fallback pass is not vacuous; the parser and
// the macro table are pinned in tailBlocks.test.tsx.
import type { BlockCase } from './types'

export const mathCases: BlockCase[] = [
  { type: 'equation', block: { type: 'equation', tex: 'E = \\frac{mc^2}{\\alpha}', display: true } },
]
