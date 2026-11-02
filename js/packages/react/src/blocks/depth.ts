import { MAX_DEPTH, isMap, str } from '../inline'

type Path = (string | typeof EACH)[]

const EACH = Symbol('each')

const LIST_TYPES = [
  'list',
  'ordered-list',
  'numbered_list',
  'bulletList',
  'bullet_list',
  'bulleted-list',
  'bulleted_list',
]

const BLOCK_SLOTS = new Map<string, Path[]>([
  ['section', [['blocks', EACH]]],
  ['columns', [['columns', EACH, EACH]]],
  [
    'terminal',
    [
      ['blocks', EACH],
      ['children', EACH],
    ],
  ],
  [
    'expandable',
    [
      ['blocks', EACH],
      ['children', EACH],
    ],
  ],
  ['tabs', [['tabs', EACH, 'blocks', EACH]]],
  [
    'steps',
    [
      ['steps', EACH, 'blocks', EACH],
      ['steps', EACH, 'children', EACH],
    ],
  ],
  ['figure', [['child']]],
  [
    'card',
    [
      ['slots', 'action', EACH],
      ['slots', 'body', EACH],
      ['slots', 'media', EACH],
      ['slots', 'title', EACH],
    ],
  ],
  ['callout', [['slots', 'body', EACH]]],
  [
    'note',
    [
      ['slots', 'body', EACH],
      ['slots', 'label', EACH],
      ['slots', 'lead', EACH],
    ],
  ],
  [
    'stage',
    [
      ['slots', 'detail', EACH],
      ['slots', 'kind', EACH],
      ['slots', 'title', EACH],
    ],
  ],
  ...LIST_TYPES.map((t): [string, Path[]] => [t, [['items', EACH, 'children', EACH]]]),
])

export function capDepth(block: unknown, notice: string, depth = 0): unknown {
  if (!isMap(block)) return block
  if (depth >= MAX_DEPTH) return { type: 'paragraph', text: notice }
  return (BLOCK_SLOTS.get(str(block.type)) ?? []).reduce<unknown>(
    (acc, path) => updatePath(acc, path, (child) => capDepth(child, notice, depth + 1)),
    block,
  )
}

function updatePath(value: unknown, path: Path, fn: (v: unknown) => unknown): unknown {
  if (path.length === 0) return fn(value)
  const [head, ...rest] = path as [string | typeof EACH, ...Path]
  if (head === EACH) return Array.isArray(value) ? value.map((v) => updatePath(v, rest, fn)) : value
  if (isMap(value) && Object.hasOwn(value, head))
    return { ...value, [head]: updatePath(value[head], rest, fn) }
  return value
}
