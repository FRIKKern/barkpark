// The selftest's cases for closed shadow roots (check/layers.mjs): the check cannot read inside one, so a closed root
// anywhere in the part's page fails by name, by whatever way it came. The judge is the read at every look, which
// names each closed root present; the hook on attachShadow names one made by that call at once, even one gone
// again before the next look. Each way below is a row, not the rule: a way no row lists is caught by the read.
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { CLOSED, installCensus } from './layers.mjs'
import { each, esc, inDemo, skinsSay } from './plants.mjs'

/** A host span whose declared closed root holds one bold word, as markup the unsafe-HTML setters parse. */
const DECLARED = (id, word) => `<span id="${id}"><template shadowrootmode="closed" shadowrootclonable><b>${word}</b></template></span>`
const J = JSON.stringify
// What the demo plants, each a closed root made its own way.
const PLANTS = [
  // A host in the stage; in its closed root, a span restyled through el.style: wider letters and an underline.
  "{ const h = document.createElement('span'); h.id = 'button-closed'; root.append(h); const s = document.createElement('span'); s.textContent = 'Inside'; s.style.letterSpacing = '6px'; s.style.textDecoration = 'underline'; h.attachShadow({ mode: 'closed' }).append(s) }",
  // By the call, on focus, on a host gone again within the task: never in the page at a look.
  "root.querySelector('#button-primary').addEventListener('focus', () => { const h = document.createElement('span'); h.id = 'button-gone'; root.append(h); h.attachShadow({ mode: 'closed' }); h.remove() })",
  // Parsed by setHTMLUnsafe into a span in the stage.
  `{ const b = document.createElement('span'); root.append(b); b.setHTMLUnsafe(${J(DECLARED('button-set', 'Set'))}) }`,
  // Parsed by Document.parseHTMLUnsafe into a document of its own, then moved into the stage.
  `root.append(Document.parseHTMLUnsafe(${J(DECLARED('button-parsed', 'Parsed'))}).body.firstChild)`,
  // A clone of the clonable one above: the clone comes with a closed root of its own.
  "{ const c = root.querySelector('#button-set').cloneNode(true); c.id = 'button-clone'; root.append(c) }",
  // On the stage's own section, an ancestor of the stage, its children shown through a slot.
  "{ const a = root.parentElement; a.id = 'button-section'; a.attachShadow({ mode: 'closed' }).append(document.createElement('slot')) }",
  // Inside an open root on a host in the stage.
  `{ const h = document.createElement('span'); root.append(h); h.attachShadow({ mode: 'open' }).setHTMLUnsafe(${J(DECLARED('button-nested', 'Nested'))}) }`,
].join('\n')
/** The fail for the host `tag#id`, whatever its text. */
const named = (host) => skinsSay(new RegExp(`${esc(host)} "[^"]*" ${esc(CLOSED('').trim())}`))

/** A closed root written into the page while it is parsed (document.write while loading), which no part can do (its
    script runs once the page is parsed, and example.html holds no script), read by the census's own look on a page
    of the selftest's. True when the look names its host. */
async function writtenWhileLoading() {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  const browser = await chromium.launch()
  try {
    const file = join(scratch, 'page.html')
    writeFileSync(file, `<!doctype html><div data-part="button"><script>document.write(${J(DECLARED('button-written', 'Written'))})</script></div>`)
    const page = await browser.newPage()
    const look = await installCensus(page)
    await page.goto(pathToFileURL(file).href)
    const said = await look({ name: 'button', json: {} })
    const held = said.includes(CLOSED('span#button-written ""'))
    if (!held) console.log(`    the look said: ${J(said)}`)
    return held
  } finally {
    await browser.close()
    rmSync(scratch, { recursive: true, force: true })
  }
}

// `layers`: each holds a top-layer refusal, so it runs in the selftest's rest job by its one rule (check/jobs.mjs).
export const CLOSED_ROOT_CASES = [
  {
    name: 'closed shadow roots: each in the page fails by name, by whatever way it came: the attachShadow call (even gone before the next look), setHTMLUnsafe, parseHTMLUnsafe, a clone, on an ancestor of the stage, inside an open root',
    only: ['skins'],
    layers: true,
    plant: (d) => inDemo(d, PLANTS),
    expect: each({
      'a closed root in the stage holding a span restyled through el.style': named('span#button-closed'),
      'a closed root made by the call on a host gone before the next look': named('span#button-gone'),
      'a closed root parsed by setHTMLUnsafe': named('span#button-set'),
      'a closed root parsed by parseHTMLUnsafe': named('span#button-parsed'),
      'a clone of a clonable closed root': named('span#button-clone'),
      'a closed root on an ancestor of the stage': named('section#button-section'),
      'a closed root inside an open root': named('span#button-nested'),
    }),
  },
  {
    name: 'closed shadow roots: one written into the page while it is parsed is named by the census look',
    direct: writtenWhileLoading,
  },
]
