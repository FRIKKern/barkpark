// Authored cases for the six typed chat-* rows (src/papers/portabledoc/
// chat.tsx — spread into BLOCK_RENDERERS, charter D25/D35).
import type { BlockCase } from './types'

export const chatCases: BlockCase[] = [
  {
    type: 'chat-tool-diff',
    block: {
      type: 'chat-tool-diff',
      input: { file_path: 'a.ex' },
      lines: [{ op: '+', text: 'added' }],
      added: 1,
      removed: 0,
    },
  },
  {
    type: 'chat-todo',
    block: { type: 'chat-todo', todos: [{ content: 'do it', status: 'pending' }] },
  },
  { type: 'chat-thinking', block: { type: 'chat-thinking', tokens: 12 } },
  {
    type: 'chat-approval',
    block: { type: 'chat-approval', tool_name: 'Bash', summary: 's', approval_status: 'pending' },
  },
  {
    type: 'chat-question',
    block: { type: 'chat-question', questions: [{ question: 'Q?', options: ['A'] }] },
  },
  { type: 'chat-plan', block: { type: 'chat-plan', title: 'Plan', preview: 'p' } },
]
