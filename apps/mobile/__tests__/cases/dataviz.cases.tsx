// Authored cases for the dataviz family (src/papers/portabledoc/blocks/
// dataviz.tsx). Round-2 dataviz natives (chart, heatmap, gauge-list,
// bar-chart, criteria-progress — mob-zb-s5, D56) add their cases here.
import type { BlockCase } from './types'

export const datavizCases: BlockCase[] = [
  { type: 'stat', block: { type: 'stat', value: '42', label: 'answers' } },
  { type: 'stats', block: { type: 'stats', items: [{ value: '7', label: 'seven' }] } },
  { type: 'stat-grid', block: { type: 'stat-grid', items: [{ value: '7' }] } },
]
