// One function per proof light. Each opens its own page, so a light never
// borrows state from another, and returns { pass, detail } (plus numbers).
import { pathToFileURL } from 'node:url'
import { PROVED_ON, SHEET_WAITS } from '../build/sheet-waits.mjs'
import { SURFACES } from '../build/page.mjs'
import { assertStyles, isolate, styleReader } from './guard.mjs'
import { limit } from './limit.mjs'
import { installHelpers, source } from './probes.mjs'

export const STEP_MS = 5000
const light = (pass, detail, extra = {}) => ({ pass: !!pass, detail, ...extra })
const fmt = (n) => n.toFixed(2)

export async function open(ctx, { width = 1440, height = 900, js = true, mobile = false } = {}) {
  const context = await ctx.browser.newContext({ viewport: { width, height }, javaScriptEnabled: js, colorScheme: 'light', reducedMotion: 'reduce', isMobile: mobile, hasTouch: mobile })
  const page = await context.newPage()
  const where = `${ctx.part}, ${width}px${js ? '' : ', no script'}`
  page.on('pageerror', (e) => ctx.errors.push(`${where}: ${String(e).slice(0, 200)}`))
  page.on('console', (m) => m.type() === 'error' && ctx.errors.push(`${where}: console: ${m.text().slice(0, 200)}`))
  page.on('request', (r) => !/^(file|data|blob):/.test(r.url()) && ctx.errors.push(`${where}: asked the network for ${r.url().slice(0, 120)}`))
  await limit(page.goto(ctx.url), 15000, 'opening the showroom')
  if (js) await page.waitForSelector('html[data-ready]', { timeout: 15000 })
  if (js && ctx.styles) {
    page.barkStyles = await styleReader(page)
    await assertStyles(page, ctx.styles, 'once the demo ran')
  }
  // Every reading the lights rest on runs in an isolated world: page script (a demo) cannot see or
  // patch what the check calls. press.mjs runs in a second one, so it cannot reach the check either.
  page.barkCheck = await isolate(page, 'barkui-check')
  await page.barkCheck(installHelpers)
  page.barkPress = await isolate(page, 'barkui-press')
  await page.barkPress(installHelpers)
  return page
}

/** The page's styling as the build alone leaves it: the same page, built with no demo. */
export async function styleBaseline(browser, url) {
  const context = await browser.newContext({ colorScheme: 'light', reducedMotion: 'reduce' })
  try {
    const page = await context.newPage()
    await limit(page.goto(url), 15000, 'opening the baseline page')
    await page.waitForSelector('html[data-ready]', { timeout: 15000 })
    return await (await styleReader(page))()
  } finally {
    await context.close()
  }
}

/** At the end of a page's run: nothing has styled the stage since it opened. */
const stillStyled = (ctx, page, light) => (page.barkStyles ? assertStyles(page, ctx.styles, `by the end of the ${light} run`) : null)

/** Runs a function with the part's root and the helpers in one of the page's isolated worlds, under a time limit. */
const inWorld = (run, fn, name, what, ms = STEP_MS) =>
  limit(run(([src, n]) => (0, eval)(`(${src})`)(document.querySelector(`[data-part="${n}"]`), window.__barkCheck), [source(fn), name]), ms, what)
/** press.mjs code: its own world. */
const inPage = (page, fn, name, what, ms) => inWorld(page.barkPress, fn, name, what, ms)
/** The check's own code: the check's world. */
const inCheck = (page, fn, name, what, ms) => inWorld(page.barkCheck, fn, name, what, ms)
const settle = (page) => limit(page.barkCheck(() => window.__barkCheck.settle()), STEP_MS, 'settling the page')
const view = (page, skin, scheme) =>
  page.barkCheck(([k, s]) => {
    document.documentElement.setAttribute('data-skin', k)
    document.documentElement.setAttribute('data-color-scheme', s)
  }, [skin, scheme])

/** What the browser hands a screen reader for one element (role, name, states). */
async function ax(page, selector) {
  const cdp = await page.context().newCDPSession(page)
  try {
    const { root } = await cdp.send('DOM.getDocument', { depth: 0 })
    const { nodeId } = await cdp.send('DOM.querySelector', { nodeId: root.nodeId, selector })
    if (!nodeId) return null
    const { nodes } = await cdp.send('Accessibility.getPartialAXTree', { nodeId, fetchRelatives: false })
    const n = nodes[0]
    return { role: n.role?.value, name: n.name?.value ?? '', ...Object.fromEntries((n.properties ?? []).map((p) => [p.name, p.value.value])) }
  } finally {
    await cdp.detach()
  }
}

export async function pressed(ctx, part) {
  const { setup, steps } = await import(pathToFileURL(part.press).href)
  if (!Array.isArray(steps) || !steps.length) return { light: light(false, 'press.mjs exports no steps'), steps: [] }
  const page = await open(ctx)
  const results = []
  try {
    if (setup) await inPage(page, setup, part.name, 'press.mjs setup')
    await page.barkCheck((id) => document.getElementById(id).focus(), `part-${part.name}-title`)
    for (const step of steps) {
      let result
      try {
        await limit((async () => {
          if (step.click) await page.click(`[data-part="${part.name}"] ${step.click}`, { force: true, timeout: STEP_MS })
          for (const key of step.keys ?? []) await page.keyboard.press(key)
          if (step.wait) await new Promise((r) => setTimeout(r, step.wait))
          await settle(page)
        })(), STEP_MS + (step.wait ?? 0), `step "${step.name}"`)
        result = await inPage(page, step.expect, part.name, `step "${step.name}"`)
        for (const [selector, want] of Object.entries(result === true ? step.ax ?? {} : {})) {
          const got = await limit(ax(page, `[data-part="${part.name}"] ${selector}`), STEP_MS, `step "${step.name}" reading ${selector}`)
          const off = got ? Object.entries(want).find(([k, v]) => !(got[k] === v || (v === true && (got[k] === 1 || got[k] === 'true')))) : ['element', 'present']
          if (off) {
            result = `screen reader gets ${selector} ${off[0]}=${JSON.stringify(got?.[off[0]])}, want ${JSON.stringify(off[1])}`
            break
          }
        }
      } catch (e) {
        result = String(e.message).split('\n')[0]
      }
      results.push({ name: step.name, pass: result === true, detail: result === true ? '' : String(result) })
      ctx.log(`  ${result === true ? 'pass' : 'FAIL'} ${step.name}${result === true ? '' : `: ${result}`}`)
      await assertStyles(page, ctx.styles, `after step "${step.name}"`)
    }
  } finally {
    await page.context().close()
  }
  const failed = results.filter((r) => !r.pass)
  return { light: light(!failed.length, failed.length ? `${failed[0].name}: ${failed[0].detail}` : `${results.length} steps by real keys`), steps: results }
}

/** Every element must be explained by one colour variable that is the same name in every skin and scheme. */
function frozen(traces) {
  const views = Object.values(traces)
  const names = Object.keys(views[0].vars).filter((n) => new Set(views.map((v) => v.vars[n])).size > 1)
  const out = []
  views[0].els.forEach((el, i) => {
    for (const prop of Object.keys(el.props)) {
      let fits = null
      for (const v of views) {
        const seen = v.els[i]?.props[prop]
        if (!seen || seen.clear) continue
        const here = names.filter((n) => v.vars[n] === seen.v)
        fits = fits ? fits.filter((n) => here.includes(n)) : here
      }
      if (views.some((v) => v.els[i]?.props[prop]?.image)) out.push(`${el.at} shows an image that is not a data: SVG in currentColor`)
      else if (fits && !fits.length) out.push(`${el.at} ${prop} is not one skin variable in every skin and scheme`)
    }
  })
  return out
}

export async function skinsAndSchemes(ctx, part, skins) {
  const page = await open(ctx)
  const traces = {}
  const sig = {}
  const bad = { light: [], dark: [] }
  const text = { light: Infinity, dark: Infinity }
  const focus = { min: Infinity, max: 0 }
  const edges = []
  const other = {}
  const disabled = {}
  const keepDisabled = (surface, list) => {
    const d = (disabled[surface] ??= { ground: [], primary: [] })
    for (const x of list) d.ground.push(x.ground), d.primary.push(x.primary)
  }
  const free = new Map()
  try {
    await page.mouse.move(0, 0)
    const names = await page.barkCheck((list) => window.__barkCheck.colourVars(list), ctx.colourNames)
    for (const scheme of ['light', 'dark']) {
      for (const skin of skins) {
        const at = `${skin} ${scheme}`
        await view(page, skin, scheme)
        await settle(page)
        for (const f of await page.barkCheck((n) => window.__barkCheck.paintFree(document.querySelector(`[data-part="${n}"]`)), part.name)) {
          if (f.fail) bad[scheme].push(`${at}: ${f.fail}`)
          else free.set(f.selector, f.why)
        }
        const r = await page.barkCheck(([n, spec]) => window.__barkCheck.paint(document.querySelector(`[data-part="${n}"]`), spec), [part.name, part.json.paint ?? []])
        sig[at] = r.signature
        text[scheme] = Math.min(text[scheme], r.weakest.ratio)
        if (r.wrong.length) bad[scheme].push(`${at}: ${r.wrong[0]}`)
        if (r.weakest.ratio < 4.5) bad[scheme].push(`${at}: text ${fmt(r.weakest.ratio)}:1 at ${r.weakest.at}`)
        traces[at] = await page.barkCheck(([n, list]) => window.__barkCheck.trace(document.querySelector(`[data-part="${n}"]`), list), [part.name, names])
        edges.push(...(await page.barkCheck((n) => window.__barkCheck.controlEdges(document.querySelector(`[data-part="${n}"]`)), part.name)))
        keepDisabled(PROVED_ON, await page.barkCheck((n) => window.__barkCheck.disabledFill(document.querySelector(`[data-part="${n}"]`)), part.name))
        // The unproved surfaces: measured, recorded, never a light (see SHEET_WAITS).
        for (const surface of ctx.surfaces === false ? [] : SURFACES.filter((x) => x !== PROVED_ON)) {
          await page.barkCheck(([n, x]) => document.querySelector(`[data-part="${n}"]`).setAttribute('data-surface', x), [part.name, surface])
          await settle(page)
          const m = await page.barkCheck(([n, spec]) => {
            const root = document.querySelector(`[data-part="${n}"]`)
            return { text: window.__barkCheck.paint(root, spec).weakest, edges: window.__barkCheck.controlEdges(root), disabled: window.__barkCheck.disabledFill(root) }
          }, [part.name, part.json.paint ?? []])
          const o = (other[surface] ??= { text: { min: Infinity, max: 0, at: '' }, edges: [] })
          if (m.text.ratio < o.text.min) Object.assign(o.text, { min: m.text.ratio, at: `${m.text.at} (${at})` })
          o.text.max = Math.max(o.text.max, m.text.ratio)
          o.edges.push(...m.edges)
          keepDisabled(surface, m.disabled)
        }
        await page.barkCheck(([n, x]) => document.querySelector(`[data-part="${n}"]`).setAttribute('data-surface', x), [part.name, PROVED_ON])
        await settle(page)
        // Focus: Tab through the part with real keys and measure the ring on each stop.
        await page.barkCheck((id) => document.getElementById(id).focus(), `part-${part.name}-title`)
        for (let i = 0; i < 60; i++) {
          await page.keyboard.press('Tab')
          await limit(page.barkCheck(() => window.__barkCheck.frame()), STEP_MS, 'a frame')
          const r2 = await page.barkCheck((n) => {
            const h = window.__barkCheck
            const el = document.activeElement
            if (!el || !document.querySelector(`[data-part="${n}"]`).contains(el)) return { done: true }
            return el.matches(':focus-visible') ? { at: h.describe(el), ...h.ring(el) } : { at: h.describe(el), fail: 'focused but not :focus-visible' }
          }, part.name)
          if (r2.done) break
          if (r2.ratio) Object.assign(focus, { min: Math.min(focus.min, r2.ratio), max: Math.max(focus.max, r2.ratio) })
          if (r2.fail) bad[scheme].push(`${at}: focus on ${r2.at}: ${r2.fail}`)
        }
      }
    }
    await stillStyled(ctx, page, 'skins')
  } finally {
    await page.context().close()
  }
  const still = frozen(traces)
  const measures = {
    focusEdge: focus.max ? { min: +fmt(focus.min), max: +fmt(focus.max) } : null,
    controlEdge: edges.length ? { min: +fmt(Math.min(...edges)), max: +fmt(Math.max(...edges)) } : null,
  }
  for (const [surface, o] of Object.entries(other)) {
    if (o.text.max) measures[`text:${surface}`] = { min: +fmt(o.text.min), max: +fmt(o.text.max), at: o.text.at }
    if (o.edges.length) measures[`controlEdge:${surface}`] = { min: +fmt(Math.min(...o.edges)), max: +fmt(Math.max(...o.edges)) }
  }
  // Numbers only, no light and no wait line yet: how far a disabled fill sits from its ground and from the primary fill.
  const span = (xs) => ({ min: +fmt(Math.min(...xs)), max: +fmt(Math.max(...xs)) })
  for (const [surface, d] of Object.entries(disabled)) if (d.ground.length) measures[`disabled:${surface}`] = { againstGround: span(d.ground), againstPrimary: span(d.primary) }
  for (const [key, wait] of Object.entries(SHEET_WAITS)) {
    const m = measures[key]
    if (wait.hard && m && m.min < wait.needs) bad.light.push(`${wait.label} ${m.min}:1${m.at ? ` at ${m.at}` : ''}, needs ${wait.needs}:1`)
  }
  const distinct = new Set(skins.map((k) => sig[`${k} light`])).size
  const sameAcross = skins.filter((k) => sig[`${k} light`] === sig[`${k} dark`])
  const focusNote = measures.focusEdge ? `; focus edge ${measures.focusEdge.min} to ${measures.focusEdge.max}:1` : ''
  const skinsLight = still.length
    ? light(false, still[0])
    : bad.light.length
      ? light(false, bad.light[0])
      : distinct < skins.length
        ? light(false, `only ${distinct} of ${skins.length} skins paint differently`)
        : light(true, `every element takes each of ${skins.length} skins' values; weakest text ${fmt(text.light)}:1${focusNote}`)
  const schemesLight = still.length
    ? light(false, still[0])
    : bad.dark.length
      ? light(false, bad.dark[0])
      : sameAcross.length
        ? light(false, `light and dark paint the same in ${sameAcross.join(', ')}`)
        : light(true, `dark paints its own values in every skin; weakest text ${fmt(text.dark)}:1${focusNote}`)
  return { skins: skinsLight, schemes: schemesLight, measures, paintFree: [...free].map(([selector, why]) => ({ selector, why })) }
}

export async function phone(ctx, part) {
  const page = await open(ctx, { width: 390, height: 844, mobile: true })
  try {
    const r = await inCheck(page, (root) => {
      const doc = document.documentElement
      if (doc.scrollWidth > doc.clientWidth) return `page is ${doc.scrollWidth}px wide in a ${doc.clientWidth}px window`
      if (root.scrollWidth > root.clientWidth) return `the example is ${root.scrollWidth}px wide in ${root.clientWidth}px`
      const out = [...root.querySelectorAll('*')].find((el) => el.getBoundingClientRect().right > doc.clientWidth)
      return out ? `${out.textContent.trim()} ends past the window` : true
    }, part.name, 'the phone check')
    await stillStyled(ctx, page, 'phone')
    return light(r === true, r === true ? 'nothing scrolls sideways at 390px' : r)
  } finally {
    await page.context().close()
  }
}

export async function noscript(ctx, part) {
  const page = await open(ctx, { js: false })
  try {
    const shown = await inCheck(page, (root, h) => {
      // Every element in the stage that carries text or an icon must be seen (an idle spinner carries neither).
      const carrying = [...root.querySelectorAll('*')].filter((el) => h.carries(el) || (el.matches('[data-slot]') && (el.textContent.trim() || el.querySelector('svg'))))
      if (!carrying.length) return 'no part is printed'
      for (const el of carrying) {
        const ok = h.seen(el)
        if (ok !== true) return `${h.describe(el)} ${ok}`
      }
      return carrying.length
    }, part.name, 'the no-script check')
    if (typeof shown === 'string') return light(false, shown)
    const r = await page.barkCheck(([n, spec]) => window.__barkCheck.paint(document.querySelector(`[data-part="${n}"]`), spec), [part.name, part.json.paint ?? []])
    if (r.wrong.length) return light(false, r.wrong[0])
    if (r.weakest.ratio < 4.5) return light(false, `text ${fmt(r.weakest.ratio)}:1 at ${r.weakest.at}`)
    return light(true, `${shown} elements printed, seen and painted with no script`)
  } finally {
    await page.context().close()
  }
}
