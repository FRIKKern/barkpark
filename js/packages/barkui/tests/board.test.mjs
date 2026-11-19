import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { collect, END, readBlock, renderBoard, roadmapPath, START } from '../build/board.mjs'

// A board as `bp task get <id> -o json` returns it: the goal, then each milestone.
const board = {
  goal: { children: [
    { doc_id: 'g6', title: 'BarkUI M6: later', lifecycle_status: 'open' },
    { doc_id: 'g1', title: 'BarkUI M1: the map', lifecycle_status: 'done' },
    { doc_id: 'g2', title: 'BarkUI M2: one skin everywhere', lifecycle_status: 'open' },
    { doc_id: 'g3a', title: 'BarkUI M3: editor menus', lifecycle_status: 'open' },
    { doc_id: 'g3b', title: "BarkUI M3: Barkdown's tree", lifecycle_status: 'in_progress' },
    { doc_id: 'gx', title: 'BarkUI has a front door', lifecycle_status: 'in_progress' },
  ] },
  g1: { children: [] },
  g2: { children: [{ lifecycle_status: 'done' }, { lifecycle_status: 'in_progress' }, { lifecycle_status: 'open' }, { lifecycle_status: 'cancelled' }] },
  g3a: { children: [] },
  g3b: { children: [] },
  g6: { children: [] },
}
const read = (id) => board[id]

describe('board block', () => {
  it('counts each milestone in roadmap order; a milestone with no tasks under it counts itself', () => {
    expect(collect('goal', read)).toEqual([
      { id: 'M1', name: 'The map', done: 1, in_progress: 0, open: 0 },
      { id: 'M2', name: 'One skin everywhere', done: 1, in_progress: 1, open: 1 },
      { id: 'M3', name: "Editor menus and Barkdown's tree", done: 0, in_progress: 1, open: 1 },
      { id: 'M6', name: 'Re-imagining', done: 0, in_progress: 0, open: 1 },
    ])
  })

  it('keeps its shape (a change here must change the block on the roadmap too)', () => {
    expect(renderBoard([{ id: 'M2', name: 'One skin everywhere', done: 1, in_progress: 2, open: 3 }], '2026-01-02')).toBe(
      [
        '| Id | Milestone | Done | In progress | Open |',
        '|---|---|---|---|---|',
        '| M2 | One skin everywhere | 1 | 2 | 3 |',
        '',
        'Read from the board on 2026-01-02.',
        '<!-- board-stamp: c7dc67dcdc3b8bf4 -->',
      ].join('\n'),
    )
  })

  it('the roadmap carries a block the script wrote, untouched by hand (rerun node build/board.mjs <goal-task-id> when this fails)', () => {
    expect(readBlock(readFileSync(roadmapPath, 'utf8'))).not.toHaveProperty('why')
  })

  it('catches a number typed by hand and a block in another shape', () => {
    const page = (block) => `x\n${START}\n${block}\n${END}\n`
    const good = renderBoard([{ id: 'M1', name: 'The map', done: 1, in_progress: 0, open: 0 }], '2026-01-02')
    expect(readBlock(page(good))).toEqual({ rows: ['| M1 | The map | 1 | 0 | 0 |'] })
    expect(readBlock(page(good.replace('| 1 | 0 | 0 |', '| 2 | 0 | 0 |'))).why).toMatch(/by hand/)
    expect(readBlock(page(good.split('\n').slice(0, -1).join('\n'))).why).toMatch(/no stamp/)
    expect(readBlock('no block').why).toMatch(/exactly one/)
  })
})
