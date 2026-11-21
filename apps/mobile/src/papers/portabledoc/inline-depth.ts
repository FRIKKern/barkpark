/* Inline nesting past the depth limit keeps its words (task-11bbe4b4ae8c85f4).
 * Twin of js/packages/react/src/inline-depth.ts; the shared rule is written out
 * there and in api/lib/barkpark/portable_doc/render/inline_depth.ex.
 *
 * A wrapper (a node holding `children`, or a bare list) at inline depth
 * MAX_DEPTH (100) or deeper is not drawn: its words are, read by a loop down to
 * MAX_WORD_DEPTH (1000), then one space and the notice. A text draws the marks
 * that fit (depth + marks <= 100), then the notice. */

import { isMap, str } from './model'

export const MAX_WORD_DEPTH = 1000

/** A bare list, or a node with a `children` key. */
export function isInlineWrapper(n: unknown): boolean {
  return Array.isArray(n) || (isMap(n) && 'children' in n)
}

function leafText(v: unknown): string {
  return typeof v === 'number' ? String(v) : str(v)
}

/** The words under an inline node, in order, read with a loop. `depth` is the
 * node's own inline depth; nothing at or past MAX_WORD_DEPTH is read. */
export function inlineWords(node: unknown, depth: number): string {
  const out: string[] = []
  const stack: Array<[unknown, number]> = [[node, depth]]
  while (stack.length) {
    const [n, d] = stack.pop() as [unknown, number]
    if (d >= MAX_WORD_DEPTH) continue
    let kids: unknown[] = []
    if (typeof n === 'string' || typeof n === 'number') out.push(String(n))
    else if (Array.isArray(n)) kids = n
    else if (isMap(n)) {
      if ('children' in n) kids = Array.isArray(n.children) ? n.children : []
      else out.push(leafText(n.value) || leafText(n.text))
    }
    for (let i = kids.length - 1; i >= 0; i--) stack.push([kids[i], d + 1])
  }
  return out.join('')
}

/** A wrapper past the depth limit: its words, then the notice. */
export function cutInline(node: unknown, depth: number, notice: string): string {
  const words = inlineWords(node, depth)
  return words ? `${words} ${notice}` : notice
}
