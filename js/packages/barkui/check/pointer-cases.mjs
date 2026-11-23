// The selftest's rows for the checker's input on pages open at once (check/acts.mjs, check/view-pages.mjs).
// The pointer rule: every pointer move the checker asks for is made, also to the point the pointer is already at. The
// page can change under a still pointer, and what is under it then gets its hover events only from a move: a move
// left out because the point is the same leaves them unread. No cross-talk: a key or a pointer move goes to the page
// it was sent to and no other, and each page reads focus and hover as if it were in front.
import * as acts from './acts.mjs'
import { onPages } from './rest-cases.mjs'

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

/** The pointer rule on each of two pages at once. */
const pointerRule = () =>
  onPages(2, '', 'reduce', async (pages) => {
    const got = await Promise.all(pages.map(stillPointer))
    const missing = got.map((g) => WANTED.filter((k) => !g.includes(k)))
    const say = missing.map((m, j) => `page ${j + 1}: ${WANTED.length - m.length} of ${WANTED.length}${m.length ? ` (not read: ${m.join(', ')})` : ''}`)
    console.log(`    after a change under a still pointer and a move to the same point, the new box's hover events read: ${say.join('; ')}`)
    return missing.every((m) => m.length === 0)
  })

/** Where focus is on a page, and whether it shows as keyboard focus; and whether `selector` is under the pointer. */
const state = (page, selector) =>
  page.barkCheck((s) => {
    const el = document.activeElement
    return { focus: el === document.body ? 'body' : `${el.tagName.toLowerCase()}#${el.id}`, visible: el.matches(':focus-visible'), hover: document.querySelector(s).matches(':hover') }
  }, selector)

/** Keys on the first page and the pointer on the second, then the other way round: each act moves only its own
    page, and each page reads its own focus and hover. */
const noCrossTalk = () =>
  onPages(2, '', 'reduce', async ([a, b]) => {
    const target = '#button-primary'
    const centre = (page) =>
      page.barkCheck((s) => {
        const el = document.querySelector(s)
        el.scrollIntoView({ block: 'center', behavior: 'instant' })
        const r = el.getBoundingClientRect()
        return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
      }, target)
    const wrong = []
    const at = async (what, want) => {
      const got = [await state(a, target), await state(b, target)]
      for (const [j, w] of want.entries())
        for (const [k, v] of Object.entries(w)) if (got[j][k] !== v) wrong.push(`${what}: page ${j + 1} reads ${k} ${JSON.stringify(got[j][k])}, not ${JSON.stringify(v)}`)
      return got
    }
    const [ca, cb] = [await centre(a), await centre(b)]
    await acts.pointTo(a, 0, 0)
    await acts.pointTo(b, 0, 0)
    await at('at the start', [{ focus: 'body', hover: false }, { focus: 'body', hover: false }])
    for (let i = 0; i < 3; i++) await acts.press(a, 'Tab')
    const [fa] = await at('three Tabs on page 1', [{ visible: true }, { focus: 'body' }])
    if (fa.focus === 'body') wrong.push('three Tabs on page 1: page 1 has no focus')
    await acts.pointTo(b, cb.x, cb.y)
    await at('the pointer on page 2', [{ focus: fa.focus, visible: true, hover: false }, { focus: 'body', hover: true }])
    await acts.press(b, 'Tab')
    const [, fb] = await at('a Tab on page 2', [{ focus: fa.focus, visible: true }, { visible: true }])
    if (fb.focus === 'body') wrong.push('a Tab on page 2: page 2 has no focus')
    await acts.pointTo(a, ca.x, ca.y)
    await at('the pointer on page 1', [{ hover: true }, { focus: fb.focus, hover: true }])
    console.log(`    keys and the pointer on two pages at once: ${wrong.length ? wrong.join('; ') : 'each act moved its own page alone, and each page read its own focus and hover'}`)
    return wrong.length === 0
  })

export const POINTER_CASES = [
  {
    name: 'at rest: after a change under a still pointer, a move to the same point is made and the hover events of what is now under it are read, on each of two pages at once',
    direct: pointerRule,
  },
  {
    name: 'two pages at once: a key or a pointer move goes to its own page alone, and each page reads focus and hover as if in front',
    direct: noCrossTalk,
  },
]
