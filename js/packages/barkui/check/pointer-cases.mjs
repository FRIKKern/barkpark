// The selftest's row for the pointer rule (check/acts.mjs pointTo): every pointer move the checker asks for is made,
// also to the point the pointer is already at. The page can change under a still pointer, and what is under it then
// gets its hover events only from a move: a move left out because the point is the same leaves them unread.
import * as acts from './acts.mjs'
import { onPage } from './rest-cases.mjs'

/** A box at a fixed point, the pointer moved onto it, the box swapped for another at the same point, and the pointer
    moved to that same point again: the hover events the second box got. */
async function stillPointer(page) {
  const swap = (id) =>
    page.barkCheck((id) => {
      window.__barkSeen ??= []
      document.getElementById('bark-under')?.remove()
      const box = Object.assign(document.createElement('div'), { id: 'bark-under' })
      box.dataset.box = id
      box.style.cssText = 'position: fixed; left: 0; top: 0; width: 200px; height: 200px; z-index: 2147483647; background: #fff;'
      for (const kind of ['mouseover', 'mouseenter', 'mousemove', 'pointermove']) box.addEventListener(kind, () => window.__barkSeen.push(`${id} ${kind}`))
      document.body.append(box)
    }, id)
  await swap('A')
  await acts.pointTo(page, 100, 100)
  await swap('B')
  await acts.pointTo(page, 100, 100)
  return page.barkCheck(() => window.__barkSeen.filter((e) => e.startsWith('B ')).map((e) => e.slice(2)))
}

/** The hover events a box must get when it comes under a still pointer and the pointer is moved to it. */
const WANTED = ['mouseover', 'mouseenter', 'mousemove', 'pointermove']

const pointerRule = () =>
  onPage('', 'reduce', async (page) => {
    const got = await stillPointer(page)
    const missing = WANTED.filter((k) => !got.includes(k))
    console.log(`    after a change under a still pointer and a move to the same point, the new box's hover events read: ${WANTED.length - missing.length} of ${WANTED.length}${missing.length ? `; not read: ${missing.join(', ')}` : ''}`)
    return missing.length === 0
  })

export const POINTER_CASES = [
  {
    name: 'at rest: after a change under a still pointer, a move to the same point is made and the hover events of what is now under it are read',
    direct: pointerRule,
  },
]
