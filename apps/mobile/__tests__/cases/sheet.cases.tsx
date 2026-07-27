// Authored cases for the sheet family (src/papers/portabledoc/blocks/
// sheet.tsx). The case carries the whole D46b vocabulary in one block — a head
// row, a partial `col_widths`, a per-cell style, an engine error, a numeric and
// a URL cell — so the registry tripwire exercises the real grid path rather
// than the empty-snapshot shortcut.
import type { BlockCase } from './types'

export const sheetCases: BlockCase[] = [
  {
    type: 'sheet',
    block: {
      type: 'sheet',
      snapshot: {
        head: ['Item', 'Qty'],
        rows: [
          ['Widget', '1,200'],
          ['#REF!', 'https://example.com/x'],
        ],
        col_widths: [140],
        styles: { '0,0': { b: true, bg: '#fff3c4' } },
      },
    },
  },
]
