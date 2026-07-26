// Authored cases for the table family (src/papers/portabledoc/blocks/
// table.tsx).
import type { BlockCase } from './types'

export const tableCases: BlockCase[] = [
  { type: 'table', block: { type: 'table', head: ['h'], rows: [['cell']] } },
]
