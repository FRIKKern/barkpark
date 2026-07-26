// Authored cases for the taskboard family (src/papers/portabledoc/blocks/
// taskboard.tsx). Round-2 grid natives (task-board — mob-zb-s6, D46c) add
// their cases here.
import type { BlockCase } from './types'

export const taskboardCases: BlockCase[] = [
  { type: 'tasks', block: { type: 'tasks', snapshot: [{ title: 'T', status: 'open' }] } },
  { type: 'task-list', block: { type: 'task-list', snapshot: [{ title: 'T', status: 'done' }] } },
]
