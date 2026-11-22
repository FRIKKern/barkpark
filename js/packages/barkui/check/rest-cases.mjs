// The selftest's rows for a look read only at rest (the gate in check/probes.mjs, the door in check/capture.mjs):
// the checker's own changes start nothing, it adds no animation, every way it reads a look is gated, and a page that
// moves by its own rule is read as it truly is or is red by name as the check's own red, never read mid-way.
import { cpSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom } from '../build/showroom.mjs'
import { capture } from './capture.mjs'
import { named, withPopover } from './layer-cases.mjs'
import { each } from './plants.mjs'
import { open } from './proofs.mjs'
import { readView, verdict } from './reading.mjs'

/** The button part with the named "Details" popover, `css` planted, opened with motion `motion`; `go` gets the page
    and the part, and its answer is the case's. */
async function onPage(css, motion, go) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-selftest-'))
  const browser = await chromium.launch({ args: ['--disable-lcd-text'] })
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    withPopover(join(dir, 'button'))
    named(join(dir, 'button'))
    const built = await buildShowroom({ dir, out: join(scratch, 'out'), proof: join(scratch, 'proof.json'), quiet: true, plantCss: css })
    const part = built.parts.find((x) => x.name === 'button')
    const page = await open({ browser, url: pathToFileURL(built.file).href, part: part.name, errors: [] }, { motion })
    return await go(page, part)
  } finally {
    await browser.close()
    rmSync(scratch, { recursive: true, force: true })
  }
}
/** The popover opened by its click, hidden for the capture of what is behind it and drawn again, as a reading does:
    what the read straight after each sees, or the error that refused it. `made`: animations on the page that are no
    transition or animation of a stylesheet's, so ones the checker would have made. */
async function hiddenAndBack(page) {
  await page.click('#button-pop-open')
  // The click's own hover and focus changes run their course first, as they would before any reading.
  await page.waitForTimeout(100)
  const look = (on) =>
    page.barkCheck((on) => {
      const box = document.getElementById('button-pop')
      try {
        window.__barkCheck.hideLayers(on)
      } catch (e) {
        return { error: String(e.message) }
      }
      const made = document.getAnimations().filter((a) => !(a instanceof CSSTransition || a instanceof CSSAnimation)).length
      return { opacity: Number(getComputedStyle(box).opacity), running: box.getAnimations().length, made }
    }, on)
  const hidden = await look(true)
  // Frames pass while the capture is taken.
  await page.waitForTimeout(100)
  const back = await look(false)
  return { hidden, back }
}
/** The part's spinner turns for ever with motion allowed: held still, so what moves is only each row's own plant. */
const QUIET = '[data-slot="spinner"] { animation: none; }'
const NOT_AT_REST = /read on a page not at rest: .*div#button-pop /
/** Under reduced motion every property has a 0.01ms transition: hidden and drawn again, the box reads at its new
    opacity at once, in the same task; the change starts no transition and the checker adds no animation. */
const undone = () =>
  onPage('', 'reduce', async (page) => {
    const { hidden, back } = await hiddenAndBack(page)
    const held = hidden.opacity === 0 && hidden.running === 0 && hidden.made === 0 && back.opacity === 1 && back.running === 0 && back.made === 0
    if (!held) console.log(`    hidden: ${JSON.stringify(hidden)}; drawn again: ${JSON.stringify(back)}`)
    return held
  })
/** What the page does by its own rule is never undone by the checker. Held at opacity 0 by its own style, the box
    reads 0 and red. Still moving by its own rule when the checker would hide it or pin a state, the page is not at
    rest: the reading waits inside settle's bound, then is red by name; it never reads a number in between. */
const ownLook = () =>
  each({
    'a box its own style holds at opacity 0 reads at 0 when drawn again, and the reading is red at it': () =>
      onPage('#button-pop { opacity: 0; }', 'reduce', async (page, part) => {
        const { back } = await hiddenAndBack(page)
        const fails = verdict(await readView(page, part)).fails.filter((f) => f.includes('div#button-pop '))
        if (back.opacity !== 0 || !fails.length) console.log(`    drawn again: ${JSON.stringify(back)}; fails: ${JSON.stringify(fails)}`)
        return back.opacity === 0 && fails.length > 0
      }),
    'a box still fading in by its own 60 s transition is not at rest: its reading is red by name': () =>
      onPage(`${QUIET} #button-pop { transition: opacity 60s linear; } @starting-style { #button-pop:popover-open { opacity: 0; } }`, 'no-preference', async (page, part) => {
        await page.click('#button-pop-open')
        const read = await readView(page, part).then(() => 'read', (e) => String(e.message))
        const held = NOT_AT_REST.test(read)
        if (!held) console.log(`    reading: ${read.slice(0, 200)}`)
        return held
      }),
    "a control fading by its own 2 s rule when the checker pins a state reads the pinned state or is red by name, never between": () =>
      onPage(`${QUIET} #button-pop-open { transition: opacity 2s linear; } #button-pop-open[data-pin="active"] { opacity: 0.2; } #button-pop-open[data-pin="hover"] { opacity: 1; }`, 'no-preference', async (page) => {
        const got = await page.barkCheck(() => {
          const el = document.getElementById('button-pop-open')
          el.setAttribute('data-pin', 'active')
          document.getAnimations()
          try {
            window.__barkCheck.restyle('pins set or taken off', () => el.setAttribute('data-pin', 'hover'))
            return { opacity: Number(getComputedStyle(el).opacity) }
          } catch (e) {
            return { error: String(e.message) }
          }
        })
        const held = got.opacity === 1 || /read on a page not at rest: .*button#button-pop-open /.test(got.error ?? '')
        if (!held) console.log(`    pinned: ${JSON.stringify(got)}`)
        return held
      }),
  })()


/** Every way the check reads a look, called with no frame between on a page a 60 s transition of its own moves:
    each is red by name, and the count of ways is printed. `CALLS` is how each is called; a way with no call, or a
    call with no way, fails the row by name. The capture is the node-side way. */
const CALLS = {
  'window.getComputedStyle': (el) => getComputedStyle(el).opacity,
  'window.matchMedia': () => matchMedia('(min-width: 1px)').matches,
  'Element.getBoundingClientRect': (el) => el.getBoundingClientRect().width,
  'Element.getClientRects': (el) => el.getClientRects().length,
  'Element.checkVisibility': (el) => el.checkVisibility({ opacityProperty: true }),
  'Element.computedStyleMap': (el) => String(el.computedStyleMap().get('opacity')),
  'Range.getBoundingClientRect': (el) => {
    const r = document.createRange()
    r.selectNode(el)
    return r.getBoundingClientRect().width
  },
  'Range.getClientRects': (el) => {
    const r = document.createRange()
    r.selectNode(el)
    return r.getClientRects().length
  },
  'Document.elementFromPoint': () => document.elementFromPoint(1, 1),
  'Document.elementsFromPoint': () => document.elementsFromPoint(1, 1).length,
  'Document.caretPositionFromPoint': () => document.caretPositionFromPoint(1, 1),
  'Document.caretRangeFromPoint': () => document.caretRangeFromPoint(1, 1),
  // A getter's call is made from its name, so its source names the property (a call runs in the page from source).
  ...Object.fromEntries(['offsetWidth', 'offsetHeight', 'offsetTop', 'offsetLeft', 'offsetParent'].map((k) => [`HTMLElement.${k}`, new Function('el', `return el.${k}`)])),
  ...Object.fromEntries(['clientWidth', 'clientHeight', 'clientTop', 'clientLeft', 'scrollWidth', 'scrollHeight', 'scrollTop', 'scrollLeft'].map((k) => [`Element.${k}`, new Function('el', `return el.${k}`)])),
  // The probe makers read through the same ways: what they would read on a moving page is caught there too.
  'resolve (a probe on body)': () => window.__barkCheck.resolve('--ui-primary'),
  'colourVars (a probe on body)': () => window.__barkCheck.colourVars(['--ui-primary']),
}

/** A 60 s fade of the page's own on #button-primary, started by the check's world with no restyle and no frame. */
const SLOW = QUIET + ' #button-primary { transition: opacity 60s linear; } #button-primary[data-pin="hover"], #button-primary.bark-slow, #button-primary[aria-pressed="true"] { opacity: 0.5; }'
const walk = () =>
  onPage(SLOW, 'no-preference', async (page) => {
    const calls = Object.fromEntries(Object.entries(CALLS).map(([k, f]) => [k, f.toString()]))
    const got = await page.barkCheck((calls) => {
      const h = window.__barkCheck
      const el = document.getElementById('button-primary')
      el.style.opacity = '0.5'
      const out = { ways: h.looks?.ways ?? 0, gated: h.looks?.gated ?? [], reads: {} }
      for (const [k, src] of Object.entries(calls)) {
        try {
          out.reads[k] = `read ${JSON.stringify((0, eval)(`(${src})`)(el))}`.slice(0, 60)
        } catch (e) {
          out.reads[k] = String(e.message)
        }
      }
      return out
    }, calls)
    const shot = await capture(page, page.barkCheck, { x: 0, y: 0, w: 8, h: 8 }).then(() => 'read', (e) => String(e.message))
    const ways = [...got.gated.filter((k) => !(k in CALLS)).map((k) => `${k}: no call`), ...Object.keys(CALLS).filter((k) => !k.includes(' (') && !got.gated.includes(k)).map((k) => `${k}: not gated`)]
    const reds = Object.entries({ ...got.reads, 'the capture': shot }).filter(([, r]) => !RED.test(r))
    console.log(`    ways the checker reads a look: ${got.ways + 1}; gated: ${got.gated.length + (RED.test(shot) ? 1 : 0)}`)
    for (const w of ways) console.log(`    ${w}`)
    for (const [k, r] of reds) console.log(`    ${k} on a moving page: ${r}`)
    return got.ways === got.gated.length && !ways.length && !reds.length
  })
const RED = /the check could not read \(not a fault of the part\): read on a page not at rest: .*button#button-primary /

/** The reviewer's twelve ways to change a look outside restyle, each starting the page's own 60 s fade on
    #button-primary with no frame: the next read is red by name, the check's own red, never a number mid-way. */
const PLANTS = {
  'a style appended to head': () => document.head.append(Object.assign(document.createElement('style'), { textContent: '#button-primary { opacity: 0.5; }' })),
  'a style prepended to head': () => document.head.prepend(Object.assign(document.createElement('style'), { textContent: '#button-primary { opacity: 0.5 !important; }' })),
  'a style prepended to the root element': () => document.documentElement.prepend(Object.assign(document.createElement('style'), { textContent: '#button-primary { opacity: 0.5 !important; }' })),
  'style.setProperty on the element': (el) => el.style.setProperty('opacity', '0.5'),
  "setAttribute('style')": (el) => el.setAttribute('style', 'opacity: 0.5'),
  'an adopted sheet': () => {
    const s = new CSSStyleSheet()
    s.replaceSync('#button-primary { opacity: 0.5 !important; }')
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, s]
  },
  'insertRule into a page sheet': () => {
    const s = [...document.styleSheets].find((x) => { try { return x.cssRules } catch { return false } })
    s.insertRule('#button-primary { opacity: 0.5 !important; }', s.cssRules.length)
  },
  'classList.add': (el) => el.classList.add('bark-slow'),
  'setAttribute("data-pin")': (el) => el.setAttribute("data-pin", "hover"),
  'dataset.pin': (el) => (el.dataset.pin = 'hover'),
  "toggleAttribute('data-pin') with a value set after": (el) => {
    el.toggleAttribute('data-pin', true)
    el.setAttribute('data-pin', 'hover')
  },
  "an aria state a rule styles": (el) => el.setAttribute('aria-pressed', 'true'),
}
const plants = () =>
  each(Object.fromEntries(Object.entries(PLANTS).map(([what, plant]) => [what, () =>
    onPage(SLOW, 'no-preference', async (page) => {
      const r = await page.barkCheck(([src]) => {
        const el = document.getElementById('button-primary')
        ;(0, eval)(`(${src})`)(el)
        try {
          return `read ${getComputedStyle(el).opacity}`
        } catch (e) {
          return String(e.message)
        }
      }, [plant.toString()])
      if (!RED.test(r)) console.log(`    ${what}: ${r}`)
      return RED.test(r)
    })])))()

/** Motion declared anywhere but motion.mjs's PLACES is red by name before any light reads, and so is a shadow root
    on the page: the check reads neither. */
const OFF_LIST = {
  '::placeholder': '#button-primary::placeholder { transition: color 200ms ease-out; }',
  '::marker': '#button-primary::marker { transition: color 200ms ease-out; }',
  '::file-selector-button': '#button-primary::file-selector-button { animation: bark-spin 1s; }',
}
const UNSEEN = /the check could not read \(not a fault of the part\): motion where the check cannot see it: /
const unseen = () =>
  each({
    ...Object.fromEntries(Object.entries(OFF_LIST).map(([where, css]) => [`motion declared on ${where} is red by name`, async () => {
      const got = await onPage(css, 'reduce', async () => 'opened').catch((e) => String(e.message))
      const held = UNSEEN.test(got) && got.includes(where)
      if (!held) console.log(`    ${where}: ${got.slice(0, 200)}`)
      return held
    }])),
    'a shadow root on the page, of any mode, is red by name at the next reading': () =>
      onPage('', 'reduce', async (page, part) => {
        await page.barkCheck(() => {
          const host = Object.assign(document.createElement('div'), { id: 'bark-host' })
          document.body.append(host)
          host.attachShadow({ mode: 'closed' }).append('inside')
        })
        const read = await readView(page, part).then(() => 'read', (e) => String(e.message))
        const held = /the check could not read \(not a fault of the part\): unread: shadow root at div#bark-host/.test(read)
        if (!held) console.log(`    shadow root: ${read.slice(0, 200)}`)
        return held
      }),
  })()

/** The checker's skin switch goes through restyle: a read straight after it reads the new skin on a sound page; on a
    page still moving by its own rule, the switch waits inside the bound, then is red by name, never a silent read. */
const skinSwitch = () =>
  each({
    'on a sound page, a read straight after the switch reads at rest': () =>
      onPage(QUIET, 'no-preference', async (page) => {
        const skins = ['ember', 'fjord']
        const seen = []
        for (const k of skins) {
          await page.barkCheck((k) => window.__barkCheck.restyle('a skin and scheme set', () => document.documentElement.setAttribute('data-skin', k)), k)
          seen.push(await page.barkCheck(() => {
            const el = document.getElementById('button-primary')
            try {
              return { colour: getComputedStyle(el).backgroundColor, moving: window.__barkCheck.moving().length }
            } catch (e) {
              return { error: String(e.message) }
            }
          }))
        }
        const held = seen.every((s) => s.colour && s.moving === 0) && seen[0].colour !== seen[1].colour
        if (!held) console.log(`    sound: ${JSON.stringify(seen)}`)
        return held
      }),
    'on a page moving by its own 60 s rule, the switch is red by name': () =>
      onPage(`${QUIET} #button-primary { transition: opacity 60s linear; }`, 'no-preference', async (page) => {
        await page.barkCheck(() => (document.getElementById('button-primary').style.opacity = '0.5'))
        const got = await page.barkCheck(() => window.__barkCheck.restyle('a skin and scheme set', () => document.documentElement.setAttribute('data-skin', 'fjord'))).then(() => 'switched', (e) => String(e.message))
        const held = /the check could not read \(not a fault of the part\): read on a page not at rest: the checker's change "a skin and scheme set": button#button-primary /.test(got)
        if (!held) console.log(`    moving: ${got.slice(0, 200)}`)
        return held
      }),
  })()

/** A capture is bracketed: with the page's own 150 ms fade started every 400 ms by a timer, each of 40 captures is
    the page at rest, the same as one of the two captures taken with the timer stopped. */
const bracket = () =>
  onPage(`${QUIET} #button-primary { transition: opacity 150ms linear; } #button-primary[data-pin="hover"] { opacity: 0.4; }`, 'no-preference', async (page) => {
    const clip = await page.barkCheck(() => {
      const r = document.getElementById('button-primary').getBoundingClientRect()
      return { x: Math.floor(r.left + scrollX), y: Math.floor(r.top + scrollY), w: Math.ceil(r.width) + 2, h: Math.ceil(r.height) + 2 }
    })
    const pin = (on) =>
      page.barkCheck((on) => window.__barkCheck.restyle('pins set or taken off', () => {
        const el = document.getElementById('button-primary')
        if (on) el.setAttribute('data-pin', 'hover')
        else el.removeAttribute('data-pin')
      }), on)
    await pin(false)
    const off = await capture(page, page.barkCheck, clip)
    await pin(true)
    const on = await capture(page, page.barkCheck, clip)
    await pin(false)
    await page.barkCheck(() => {
      const el = document.getElementById('button-primary')
      window.__barkTimer = setInterval(() => (el.hasAttribute('data-pin') ? el.removeAttribute('data-pin') : el.setAttribute('data-pin', 'hover')), 400)
    })
    let mid = 0
    let red = 0
    for (let i = 0; i < 40; i++) {
      const png = await capture(page, page.barkCheck, clip).catch(() => null)
      if (png === null) red++
      else if (png !== off && png !== on) mid++
    }
    await page.barkCheck(() => clearInterval(window.__barkTimer))
    if (mid || red || off === on) console.log(`    captures mid-motion: ${mid}; red: ${red}; rest images differ: ${off !== on}`)
    return !mid && !red && off !== on
  })

export const REST_CASES = [
  {
    name: 'at rest: a box hidden for the capture behind it and drawn again reads at its new opacity at once; the change starts no transition and the checker adds no animation',
    direct: undone,
  },
  {
    name: 'at rest: a box held at opacity 0 by its own style reads so and is red; a page still moving by its own rule is red by name as the check\'s own red',
    direct: ownLook,
  },
  { name: 'at rest: every way the checker reads a look is gated, and on a moving page each is red by name', direct: walk },
  { name: 'at rest: twelve ways to change a look outside restyle each leave the next read red by name, never mid-way', direct: plants },
  { name: 'at rest: motion declared on ::placeholder, ::marker or ::file-selector-button, and a shadow root on the page, are red by name', direct: unseen },
  { name: "at rest: the checker's skin switch reads at rest straight after on a sound page, and is red by name on a page moving by its own rule", direct: skinSwitch },
  { name: 'at rest: a capture under a timer-driven fade is the page at rest every time, or taken again', direct: bracket },
]
