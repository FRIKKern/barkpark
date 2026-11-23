// Input forms a file outside check/acts.mjs could try on a wall page: each one must be refused by the wall
// (check/acts.mjs, check/wall.mjs) by name, at this file. The selftest's wall row (check/wall-cases.mjs) makes each on
// a page of its own browser and reads N of M, M the length of each list.

/** The review's plants, one line each as the review made them. */
export const SEEN = [
  async (page) => { await page.click('#x') },
  async (page) => { await page.hover('#x') },
  async (page) => { await page.locator('#x').click() },
  async (page) => { await page.touchscreen.tap(1, 1) },
  async (page) => { const kb = page.keyboard; await kb.press('Tab') },
  async (page) => { await page['keyboard'].press('Tab') },
  async (page) => { await page.press('#x', 'Tab') },
  async (page) => { await page.type('#x', 'a') },
  async (page) => { await page.dispatchEvent('#x', 'click') },
  async (page) => { await page.mouse.wheel(0, 100) },
  async (page) => { await page.keyboard.down('Shift') },
  async (page) => { await page.focus('#x') },
  async (page) => { await page.getByRole('button').press('Enter') },
  async (page) => { await page.dragAndDrop('#a', '#b') },
]

const later = (make) => new Promise((done) => setTimeout(() => { done(); make() }, 0))

/** The selftest's own forms: ways round a wall that decides by the caller, each closed by what a wall object holds. */
export const OWN = {
  'a key from a timer': (page) => later(() => page.keyboard.press('Tab')),
  'a click from an event listener': async (page) => {
    page.on('console', () => page.click('#x'))
    await page.evaluate(() => console.log('x'))
  },
  'a second page from the context': async (page) => { await (await page.context().newPage()).keyboard.press('Tab') },
  "a page from the context's list": async (page) => { await page.context().pages()[0].mouse.click(1, 1) },
  'a protocol session sending a key': async (page) => {
    const s = await page.context().newCDPSession(page)
    await s.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'a' })
  },
  "the library's underscored channel": (page) => page._channel,
  'a symbol': (page) => page[Symbol.for('keyboard')],
  "the page's prototype": async (page) => { await Object.getPrototypeOf(page).click.call(page, '#x') },
  "the page's own keys": (page) => Object.keys(page),
  "a descriptor of the page's keyboard": async (page) => { await Object.getOwnPropertyDescriptor(page, 'keyboard').value.press('Tab') },
  'a library method on no list': async (page) => { await page.bringToFront() },
  "the context's browser": async (page) => { await (await page.context().browser().newPage()).mouse.click(1, 1) },
}

/** Names read with no file of the check on the stack: the library's own function, called by the runtime's timer or
    task queue. The wall refuses them all the same, by name; the file it prints is unknown. */
export const NO_FRAME = {
  "the page's keyboard, read by a queued task": { what: 'Page.keyboard', make: (page) => queueMicrotask(Reflect.get.bind(null, page, 'keyboard')) },
  "the page's mouse, read by a timer": { what: 'Page.mouse', make: (page) => setTimeout(Reflect.get, 0, page, 'mouse') },
}
