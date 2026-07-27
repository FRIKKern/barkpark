// Authored cases for the taskboard family (src/papers/portabledoc/blocks/
// taskboard.tsx). The `task-board` case carries a lane row AND a laneless one
// (`cancelled`, which homes in `open` keeping its own glyph — D46c) so the
// tripwire renders the real bucketing path.
import type { BlockCase } from './types'

export const taskboardCases: BlockCase[] = [
  { type: 'tasks', block: { type: 'tasks', snapshot: [{ title: 'T', status: 'open' }] } },
  { type: 'task-list', block: { type: 'task-list', snapshot: [{ title: 'T', status: 'done' }] } },
  {
    type: 'task-board',
    block: {
      type: 'task-board',
      snapshot: [
        { title: 'B', status: 'in_progress', priority: 1, criteria: { met: 1, total: 3 }, worker: 'w1' },
        { title: 'C', status: 'cancelled' },
      ],
    },
  },
]
