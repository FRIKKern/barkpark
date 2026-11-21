/* Inline nesting past the depth limit keeps its words (task-11bbe4b4ae8c85f4).
 *
 * The rule every Barkpark reader shares (render/inline_depth.ex,
 * internal/pdrender/inline_depth.go, apps/mobile inlines.tsx and the editor's
 * canvas/inline-depth.js):
 *
 *  - A wrapper (a node holding `children`, or a bare list) is drawn while its
 *    inline depth is under MAX_DEPTH (100). A text at depth d with k marks draws
 *    all of them when d + k <= 100.
 *  - A wrapper at depth 100 or deeper is not drawn. The words under it are, flat
 *    and in order, then one space and the notice. A text with more marks than fit
 *    draws the marks that fit, then the notice.
 *  - The words are read by a loop, never by recursion, down to inline depth
 *    MAX_WORD_DEPTH (1000). Words deeper than that are not read; the notice still
 *    follows, so a document of any depth draws without a crash.
 */

export const MAX_WORD_DEPTH = 1000

function isRecord(n: unknown): n is Record<string, unknown> {
  return typeof n === 'object' && n !== null && !Array.isArray(n)
}

/** A bare list, or a node with a `children` key. */
export function isInlineWrapper(n: unknown): boolean {
  return Array.isArray(n) || (isRecord(n) && 'children' in n)
}

function leafText(v: unknown): string {
  if (typeof v === 'string') return v
  if (typeof v === 'number') return String(v)
  return ''
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
    else if (isRecord(n)) {
      if ('children' in n) kids = Array.isArray(n.children) ? n.children : []
      else out.push(leafText(n.value) || leafText(n.text))
    }
    for (let i = kids.length - 1; i >= 0; i--) stack.push([kids[i], d + 1])
  }
  return out.join('')
}

/** A wrapper past the depth limit, as plain text: its words, then the notice. */
export function cutInline(node: unknown, depth: number, notice: string): string {
  const words = inlineWords(node, depth)
  return words ? `${words} ${notice}` : notice
}
