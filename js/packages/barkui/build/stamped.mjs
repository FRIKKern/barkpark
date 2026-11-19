// A block a script writes into a page: between a start and an end marker, its
// lines, then a stamp over those lines. A hand edit breaks the stamp. Used by
// build/status.mjs and build/board.mjs.
import { createHash } from 'node:crypto'

const STAMP = /^<!-- stamp: ([0-9a-f]{16}) -->$/
const hash = (lines) => createHash('sha256').update(lines.join('\n')).digest('hex').slice(0, 16)

/** The block's lines followed by the stamp over them. */
export const stamp = (lines) => [...lines, `<!-- stamp: ${hash(lines)} -->`].join('\n')

/** The block's lines inside a page, or a reason it cannot be trusted. */
export function readStamped(text, start, end) {
  if (text.split(start).length !== 2 || text.split(end).length !== 2 || text.indexOf(start) > text.indexOf(end)) return { why: `needs exactly one ${start} ... ${end} pair` }
  const lines = text.split(start)[1].split(end)[0].trim().split('\n')
  const m = STAMP.exec(lines.at(-1) ?? '')
  if (!m) return { why: 'the block has no stamp' }
  const body = lines.slice(0, -1)
  if (hash(body) !== m[1]) return { why: 'the block was edited by hand' }
  return { body }
}

/** The page with its block replaced; throws unless it holds exactly one marker pair. */
export function replaceBlock(text, start, end, block) {
  if (text.split(start).length !== 2 || text.split(end).length !== 2 || text.indexOf(start) > text.indexOf(end)) throw new Error(`needs exactly one ${start} ... ${end} pair`)
  const [head, rest] = text.split(start)
  return `${head}${start}\n${block}\n${end}${rest.split(end)[1]}`
}
