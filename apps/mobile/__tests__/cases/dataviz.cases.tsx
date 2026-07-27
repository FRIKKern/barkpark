// Authored cases for the dataviz family (src/papers/portabledoc/blocks/
// dataviz.tsx). Every case must render WITHOUT the unknown-block fallback in
// BOTH registers (chatRenderers.test.tsx's tripwire, charter D31/D49) — so each
// carries the MINIMUM payload its renderer needs to get past its honest empty
// state. Round-2 natives (chart, heatmap, gauge-list, bar-chart,
// criteria-progress — mob-zb-s5, D56) each pick the variant their dispatch arm
// selects.
import type { BlockCase } from './types'

export const datavizCases: BlockCase[] = [
  { type: 'stat', block: { type: 'stat', value: '42', label: 'answers', spark: [1, 4, 2, 8] } },
  { type: 'stats', block: { type: 'stats', items: [{ value: '7', label: 'seven' }] } },
  { type: 'stat-grid', block: { type: 'stat-grid', items: [{ value: '7' }] } },
  {
    type: 'chart',
    block: {
      type: 'chart',
      caption: 'throughput',
      series: [{ label: 'merged', points: [1, 3, 2, 5] }],
      axes: { xLabels: ['Mon', 'Fri'] },
    },
  },
  {
    type: 'heatmap',
    block: {
      type: 'heatmap',
      cells: [
        [0, 2],
        [4, 1],
      ],
      rowLabels: ['a', 'b'],
      colLabels: ['x', 'y'],
    },
  },
  { type: 'gauge-list', block: { type: 'gauge-list', title: 'share', rows: [{ label: 'done', value: 3 }] } },
  { type: 'bar-chart', block: { type: 'bar-chart', bars: [{ label: 'open', value: 4 }], values: true } },
  {
    type: 'criteria-progress',
    block: { type: 'criteria-progress', rows: [{ label: 'slice', met: 2, total: 5 }] },
  },
]

/** The other two variants the ONE `heatmap` type dispatches to. Kept OUT of
 * `datavizCases` because the registry tripwire is keyed by TYPE — a second
 * `heatmap` row would break its set-equality with Object.keys(BLOCK_RENDERERS).
 * datavizNatives.test.tsx renders these directly. */
export const heatmapVariantCases: BlockCase[] = [
  {
    type: 'heatmap',
    block: { type: 'heatmap', mode: 'calendar', cells: [[0, 1, 5, 9]], colLabels: ['Jan'] },
  },
  {
    type: 'heatmap',
    block: {
      type: 'heatmap',
      cells: [
        [1, 2],
        [3, 4],
      ],
      values: true,
      marginals: true,
      rowLabels: ['r0', 'r1'],
    },
  },
]
