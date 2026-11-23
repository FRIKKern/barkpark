// The wall round the checker's input (check/wall.mjs), proved: on a page the check opened, each input form below,
// made from this file and not from check/acts.mjs, is refused by name and file, and so is a method the library
// gains later, which is on neither list. The selftest reads N of M: M is the length of the list.
import { onPage } from './rest-cases.mjs'

const POP = '#button-pop-open'
/** The input forms a checker file could use, each made on a page the check opened. */
export const WALL_PLANTS = {
  'Keyboard.type': (page) => page.keyboard.type('x'),
  'Keyboard.down': (page) => page.keyboard.down('Shift'),
  'Keyboard.insertText': (page) => page.keyboard.insertText('x'),
  'Mouse.wheel': (page) => page.mouse.wheel(0, 40),
  'Mouse.dblclick': (page) => page.mouse.dblclick(5, 5),
  'Touchscreen.tap': (page) => page.touchscreen.tap(5, 5),
  'Page.click': (page) => page.click(POP),
  'Page.hover': (page) => page.hover(POP),
  'Page.focus': (page) => page.focus(POP),
  'Page.press': (page) => page.press(POP, 'Enter'),
  'Page.dispatchEvent': (page) => page.dispatchEvent(POP, 'click'),
  'Locator.click': (page) => page.locator(POP).click(),
  'Locator.scrollIntoViewIfNeeded': (page) => page.locator(POP).scrollIntoViewIfNeeded(),
  'Frame.click': (page) => page.mainFrame().click(POP),
  'ElementHandle.press': async (page) => (await page.$(POP)).press('Enter'),
}
const FUTURE = 'barkFutureInput'

/** Each plant made on its own page: refused by the wall, by its name, at this file. */
async function wallHolds() {
  const plants = Object.entries(WALL_PLANTS)
  let held = 0
  for (const [name, make] of plants) {
    const got = await onPage('', 'reduce', async (page) => make(page).then(() => 'made', (e) => String(e.message)))
    const ok = got.includes(`the checker's input goes only through check/acts.mjs: ${name} called at check/wall-cases.mjs:`)
    if (ok) held++
    else console.log(`    ${name}: ${got.slice(0, 200)}`)
  }
  // A method the library gains later: on its page class when the check opens a page, on neither list.
  let proto = null
  const future = await onPage('', 'reduce', async (page) => {
    proto = Object.getPrototypeOf(page)
    proto[FUTURE] = function () {
      return Promise.resolve('made')
    }
    return 'added'
  })
    .then(() => onPage('', 'reduce', (page) => page[FUTURE]().then(() => 'made', (e) => String(e.message))))
    .finally(() => proto && delete proto[FUTURE])
  const later = future.includes(`the checker's input goes only through check/acts.mjs: Page.${FUTURE} called at check/wall-cases.mjs:`)
  if (later) held++
  else console.log(`    a method the library adds later: ${future.slice(0, 200)}`)
  const of = plants.length + 1
  console.log(`    the wall refused ${held} of ${of} input forms made outside check/acts.mjs`)
  return held === of
}

export const WALL_CASES = [
  {
    name: "the checker's input: every method of the library's page-side objects but those that make no input is refused by name and file unless check/acts.mjs made it, one the library adds later too",
    direct: wallHolds,
  },
]
