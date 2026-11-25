// One function per proof light. Each opens its own page, so a light never
// borrows state from another, and returns { pass, detail } (plus numbers).
import { click, pointTo, press } from './acts.mjs'
import { readFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { SHEET_WAITS, waitsFor } from '../build/sheet-waits.mjs'
import { SURFACES } from '../build/page.mjs'
import { assertStyles, isolate, styleReader } from './guard.mjs'
import { limit } from './limit.mjs'
import { installBoundary } from './boundary.mjs'
import { installDrawn } from './drawn.mjs'
import { eachLayer, installCensus, installLayers, unnamedNow } from './layers.mjs'
import { installMatch } from './match.mjs'
import { LISTS } from './motion.mjs'
import { installHelpers, source } from './probes.mjs'
import { readView, verdict } from './reading.mjs'
import { realStates } from './states.mjs'
import { VIEW_PAGES, viewList } from './view-pages.mjs'
import { readOnPages, STOP } from './view-run.mjs'
import { installCover } from './coverage.mjs'
import { LEFT_OUT_INITIAL } from '../build/vocabulary.mjs'

export const STEP_MS = 5000
const light = (pass, detail, extra = {}) => ({ pass: !!pass, detail, ...extra })
const fmt = (n) => n.toFixed(2)
/** How the least label and graphic draw against the same drawn alone (reading.mjs). */
const drawsAll = (w) => `${w.label.at ? `lowest label ${w.label.match.toFixed(3)} like itself at ${w.label.at}` : 'no label'}; every graphic draws ${Math.floor(Math.min(1, w.share) * 100)}% or more of itself`
/** The least of two weakest readings (verdict). */
const least = (a, b) => ({ share: Math.min(a.share, b.share), label: b.label.match < a.label.match ? b.label : a.label })
const NONE = { share: 1, label: { match: Infinity, at: '' } }
/** The surfaces a run proves its lights on: every one, unless the selftest asked for base alone (false) or for base
    and a list of others, in their page order. A name that is no surface is refused. */
export function surfacesOf(ctx) {
  if (ctx.surfaces === false) return ['base']
  if (!Array.isArray(ctx.surfaces)) return SURFACES
  const unknown = ctx.surfaces.filter((s) => !SURFACES.includes(s))
  if (unknown.length) throw new Error(`no such surface: ${unknown.join(', ')}; the surfaces are ${SURFACES.join(', ')}`)
  return SURFACES.filter((s) => s === 'base' || ctx.surfaces.includes(s))
}

// `scale` is the device pixel ratio: the pages whose text is read from pixels open at 2, for solid glyph cores.
// `motion`: the reduced-motion setting the page opens with; the lights are read under both (see motionFails).
// `clock`: the page's own timers (setTimeout, Date, its animation frames) run on a clock the check moves (see
// pressed); the check's worlds keep real time.
export async function open(ctx, { width = 1440, height = 900, js = true, mobile = false, scale = 1, motion = 'reduce', clock = false } = {}) {
  const context = await ctx.browser.newContext({ viewport: { width, height }, deviceScaleFactor: scale, javaScriptEnabled: js, colorScheme: 'light', reducedMotion: motion, isMobile: mobile, hasTouch: mobile })
  const page = await context.newPage()
  const where = `${ctx.part}, ${width}px${js ? '' : ', no script'}`
  page.on('pageerror', (e) => ctx.errors.push(`${where}: ${String(e).slice(0, 200)}`))
  page.on('console', (m) => m.type() === 'error' && ctx.errors.push(`${where}: console: ${m.text().slice(0, 200)}`))
  page.on('request', (r) => !/^(file|data|blob):/.test(r.url()) && ctx.errors.push(`${where}: asked the network for ${r.url().slice(0, 120)}`))
  if (clock) await page.clock.install()
  // A blank page in the same context, where things are drawn alone for reference (see drawn.mjs). It opens before the
  // census is set, which is given both pages (docs/PARTS.md "The top layer").
  const ref = await context.newPage()
  await ref.setContent('<!doctype html><html><head></head><body></body></html>')
  // What can enter the top layer is watched from the first frame (layers.mjs census).
  page.barkCensus = await installCensus(page, [page, ref], { script: js })
  // The placement fails for this part, from the census's world (placement.mjs; docs/PARTS.md "Placement" says what is read and when).
  page.barkPlacement = () => page.barkCensus.placement(ctx.part)
  await limit(page.goto(ctx.url), 15000, 'opening the showroom')
  if (js) await page.waitForSelector('html[data-ready]', { timeout: 15000 })
  if (js && ctx.styles) {
    page.barkStyles = await styleReader(page)
    await assertStyles(page, ctx.styles, 'once the demo ran')
  }
  // Every reading the lights rest on runs in an isolated world: page script (a demo) cannot see or
  // patch what the check calls. press.mjs runs in a second one, so it cannot reach the check either.
  page.barkCheck = await isolate(page, 'barkui-check')
  await page.barkCheck(installHelpers, LISTS)
  await page.barkCheck(installBoundary)
  await page.barkCheck(installMatch)
  await page.barkCheck(installDrawn)
  await page.barkCheck(installLayers)
  page.barkCdp = await page.context().newCDPSession(page)
  page.barkScale = scale
  page.barkRef = { page: ref, world: await isolate(ref, 'barkui-ref') }
  await page.barkRef.world(installHelpers, LISTS)
  for (const install of [installBoundary, installMatch, installDrawn]) await page.barkRef.world(install)
  installCover(page, ctx)
  page.barkPress = await isolate(page, 'barkui-press')
  await page.barkPress(installHelpers, LISTS)
  // Motion may be declared only where the check reads it (motion.mjs): a sheet that declares it anywhere else is red
  // by name before any light reads.
  const first = await page.barkCheck(() => window.__barkCheck.motionOffList())
  const texts = Object.fromEntries(first.files.map((href) => [href, readFileSync(fileURLToPath(href), 'utf8')]))
  const { off } = first.files.length ? await page.barkCheck((t) => window.__barkCheck.motionOffList(t), texts) : first
  if (off.length) throw new Error(`the check could not read (not a fault of the part): motion where the check cannot see it: ${off.slice(0, 3).join('; ')}`)
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
  page.barkCheck(([k, s]) =>
    window.__barkCheck.restyle('a skin and scheme set', () => {
      document.documentElement.setAttribute('data-skin', k)
      document.documentElement.setAttribute('data-color-scheme', s)
    }), [skin, scheme])

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

// With `ctx.states`, each step ends with the stage read as drawn (in the first skin, light, on base), so a state
// only the steps reach (pending, say) is read while it holds. A reading takes real time (a second or more on a
// slow runner), so the page's own timers run on a clock that stands still between steps: a step's `wait` moves
// it that far (otherwise 50ms), and a pending that lasts 2.5s lasts 2.5s of the page's time whatever the
// readings cost.
export async function pressed(ctx, part, skins) {
  const { setup, steps } = await import(pathToFileURL(part.press).href)
  if (!Array.isArray(steps) || !steps.length) return { light: light(false, 'press.mjs exports no steps'), steps: [] }
  const drawn = ctx.states !== false
  const page = await open(ctx, { clock: true, ...(drawn ? { scale: 2, height: 1600 } : {}) })
  const waits = waitsFor(skins[0], 'light', 'base')
  const results = []
  try {
    if (drawn) await view(page, skins[0], 'light')
    if (setup) await inPage(page, setup, part.name, 'press.mjs setup')
    await page.clock.pauseAt(Date.now() + 1000)
    await page.barkCheck((id) => {
      const el = document.getElementById(id)
      el.focus({ preventScroll: true })
      el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' })
    }, `part-${part.name}-title`)
    for (const step of steps) {
      let result
      try {
        await limit((async () => {
          if (step.click) {
            // A real pointer press at the control's centre, only once the control is what is on top there: a
            // cover or anything else in the way fails the step. (Playwright's own click would wait for a
            // disabled control to become enabled, and a forced one skips the hit test.)
            const at = await page.barkCheck(([n, s]) => {
              const el = document.querySelector(`[data-part="${n}"] ${s}`)
              if (!el) return { miss: 'is not in the stage' }
              el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
              const r = el.getBoundingClientRect()
              const [x, y] = [r.left + r.width / 2, r.top + r.height / 2]
              const top = document.elementFromPoint(x, y)
              return el === top || el.contains(top) ? { x, y } : { miss: `is not what a click at its centre reaches: ${window.__barkCheck.describe(top)} is on top` }
            }, [part.name, step.click])
            if (at.miss) throw new Error(`${step.click} ${at.miss}`)
            await click(page, at.x, at.y)
          }
          for (const key of step.keys ?? []) await press(page, key)
          await page.clock.runFor(step.wait ?? 50)
          await settle(page)
        })(), STEP_MS + (step.wait ?? 0), `step "${step.name}"`)
        result = await inPage(page, step.expect, part.name, `step "${step.name}"`)
        const unnamed = await unnamedNow(page, part)
        if (result === true && unnamed.length) result = unnamed[0]
        for (const [selector, want] of Object.entries(result === true ? step.ax ?? {} : {})) {
          const got = await limit(ax(page, `[data-part="${part.name}"] ${selector}`), STEP_MS, `step "${step.name}" reading ${selector}`)
          const off = got ? Object.entries(want).find(([k, v]) => !(got[k] === v || (v === true && (got[k] === 1 || got[k] === 'true')))) : ['element', 'present']
          if (off) {
            result = `screen reader gets ${selector} ${off[0]}=${JSON.stringify(got?.[off[0]])}, want ${JSON.stringify(off[1])}`
            break
          }
        }
        const fails = result === true && drawn ? verdict(await readView(page, part, waits), `drawn after this step, ${skins[0]} light on base: `, waits).fails : []
        if (fails.length) result = fails.join('; ')
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

/** The skins the state drive runs in: the first. */
export const driveSkins = (skins) => skins.slice(0, 1)
/** The skins whose wide views a run reads: every skin, or, when the state drive is given a list of selectors (a
    narrowed drive, states.mjs), the drive's own skins alone. No other setting reads fewer. */
export const viewSkins = (ctx, skins) => (Array.isArray(ctx.states) ? driveSkins(skins) : skins)
export async function skinsAndSchemes(ctx, part, skins, pages = VIEW_PAGES) {
  const traces = {}
  const sig = {}
  const bad = { light: [], dark: [] }
  const drawnWeakest = { light: Infinity, dark: Infinity }
  const fullest = { light: NONE, dark: NONE }
  const focus = { min: Infinity, max: 0 }
  const bounds = {}
  const bare = new Map()
  const waited = new Map()
  const keepBounds = (surface, b, at) => {
    const into = (bounds[surface] ??= { min: Infinity, max: 0, at: '' })
    for (const c of b.read) {
      if (c.ratio < into.min) Object.assign(into, { min: c.ratio, at: `${c.at} by its ${c.by} (${at})` })
      into.max = Math.max(into.max, c.ratio)
    }
  }
  let controls = 0
  const disabled = {}
  const keepDisabled = (surface, list) => {
    const d = (disabled[surface] ??= { ground: [], primary: [] })
    for (const x of list) d.ground.push(x.ground), d.primary.push(x.primary)
  }
  const free = new Map()
  // What reading the part's layers open costs: each opened by its input, read, and closed again (layers.mjs).
  const layered = { readings: 0, ms: 0 }
  // The views, on pages of the one browser at once (view-pages.mjs). What a view adds to the light is kept apart, in
  // `keep`, and made in the list's order once every page is done.
  const views = viewList(viewSkins(ctx, skins))
  /** One view read on `page`; `keep` takes what it adds to the light. */
  const readAView = async (page, names, { skin, scheme }, keep) => {
    const surfaceTo = async (x) => {
      await page.barkCheck(([n, v]) => window.__barkCheck.restyle('a surface set', () => document.querySelector(`[data-part="${n}"]`).setAttribute('data-surface', v)), [part.name, x])
      await settle(page)
    }
    const at = `${skin} ${scheme}`
    const V0 = performance.now()
    await view(page, skin, scheme)
    await settle(page)
    const freeNow = await page.barkCheck((n) => window.__barkCheck.paintFree(document.querySelector(`[data-part="${n}"]`)), part.name)
    keep(() => {
      for (const f of freeNow) {
        if (f.fail) bad[scheme].push(`${at}: ${f.fail}`)
        else free.set(f.selector, f.why)
      }
    })
    const r = await page.barkCheck(([n, spec]) => window.__barkCheck.paint(document.querySelector(`[data-part="${n}"]`), spec), [part.name, part.json.paint ?? []])
    const trace = await page.barkCheck(([n, list]) => window.__barkCheck.trace(document.querySelector(`[data-part="${n}"]`), list), [part.name, names])
    keep(() => {
      sig[at] = r.signature
      if (r.wrong.length) bad[scheme].push(`${at}: ${r.wrong[0]}`)
      traces[at] = trace
    })
    // The lights rest on what is drawn, on every surface: every text run and graphic draws, as itself, at
    // contrast (see reading.mjs), and every control's boundary holds 3:1. Only a wait on the sheet bound to
    // this view and pair lets a text under 4.5:1 through (build/sheet-waits.mjs).
    for (const surface of surfacesOf(ctx)) {
      await surfaceTo(surface)
      const waits = waitsFor(skin, scheme, surface)
      // One reading of the stage as it stands now: closed, then with each of the part's layers open (layers.mjs).
      const readOne = async (where) => {
        const v = await readView(page, part, waits)
        const d = verdict(v, `${where}: `, waits)
        keep(() => {
          bad[scheme].push(...d.fails)
          for (const x of d.waited) if (!waited.has(x.wait) || waited.get(x.wait) > x.ratio) waited.set(x.wait, x.ratio)
          drawnWeakest[scheme] = Math.min(drawnWeakest[scheme], d.weakest.text.ratio)
          fullest[scheme] = least(fullest[scheme], d.weakest)
          for (const c of v.bounds.read) if (c.ratio < 3) bad[scheme].push(`${where}: control boundary ${fmt(c.ratio)}:1 at ${c.at} by its ${c.by}, needs 3:1`)
          keepBounds(surface, v.bounds, at)
        })
        return v
      }
      const v = await readOne(`${at} on ${surface}`)
      const t0 = Date.now()
      const open = await eachLayer(page, part, async (layer) => (await readOne(`${at} on ${surface} with ${layer.box} open`), keep(() => layered.readings++), []))
      const ms = Date.now() - t0
      const fills = await page.barkCheck((n) => window.__barkCheck.disabledFill(document.querySelector(`[data-part="${n}"]`)), part.name)
      const out = await leftOut(page, part.name)
      keep(() => {
        layered.ms += ms
        bad[scheme].push(...open.map((f) => `${at} on ${surface}: ${f}`))
        for (const x of v.bounds.bare) bare.set(x.selector, [...new Set([...(bare.get(x.selector) ?? []), ...x.controls])])
        controls = Math.max(controls, v.bounds.count)
        keepDisabled(surface, fills)
        for (const f of out) bad[scheme].push(`${at} on ${surface}: ${f}`)
      })
    }
    const V1 = performance.now()
    await surfaceTo('base')
    // Focus: Tab through the part with real keys and measure the ring on each stop.
    await page.barkCheck((id) => {
      const el = document.getElementById(id)
      el.focus({ preventScroll: true })
      el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' })
    }, `part-${part.name}-title`)
    for (let i = 0; i < 60; i++) {
      await press(page, 'Tab')
      await limit(page.barkCheck(() => window.__barkCheck.frame()), STEP_MS, 'a frame')
      const r2 = await page.barkCheck((n) => {
        const h = window.__barkCheck
        const el = document.activeElement
        if (!el || !document.querySelector(`[data-part="${n}"]`).contains(el)) return { done: true }
        // The ring is read on the control a person sees: a slider thumb for the input UI SDK hides in it (shownAs).
        return el.matches(':focus-visible') ? { at: h.describe(h.shownAs(el)), ...h.ring(h.shownAs(el)) } : { at: h.describe(el), fail: 'focused but not :focus-visible' }
      }, part.name)
      // Real keys can open a box in the top layer (a tooltip on focus) and close it before any reading.
      const unnamed = await unnamedNow(page, part)
      keep(() => {
        for (const f of unnamed) bad[scheme].push(`${at}: Tab to ${r2.at ?? 'past the stage'}: ${f}`)
        if (r2.done) return
        if (r2.ratio) Object.assign(focus, { min: Math.min(focus.min, r2.ratio), max: Math.max(focus.max, r2.ratio) })
        if (r2.fail) bad[scheme].push(`${at}: focus on ${r2.at}: ${r2.fail}`)
      })
      if (r2.done) break
    }
    process.stderr.write(`T> ${part.name}     view ${at}: surfaces ${((V1 - V0) / 1000).toFixed(1)} tab ${((performance.now() - V1) / 1000).toFixed(1)}\n`)
  }
  let S0 = performance.now(); const ST = (w) => { process.stderr.write(`T> ${part.name}   ${w} ${((performance.now() - S0) / 1000).toFixed(1)}\n`); S0 = performance.now() }
  const { once, count } = await readOnPages({
    views,
    pages,
    what: 'the skins light',
    open: () => open(ctx, { scale: 2, height: 1600 }),
    start: async (page) => {
      await pointTo(page, 0, 0)
      return page.barkCheck((list) => window.__barkCheck.colourVars(list), ctx.colourNames)
    },
    read: (page, v, keep, names) => readAView(page, names, v, keep),
    end: (page) => stillStyled(ctx, page, 'skins'),
  })
  ST('views')
  // The light's views come first in light, then in dark: what the census told is kept where it is first read.
  for (const scheme of ['light', 'dark']) bad[scheme] = once(bad[scheme])
  // A run that reads the views of the drive's skins alone names the rest in both lights: it is never green, and a
  // row that needs a view of theirs finds nothing and is red by its name.
  const unreadSkins = skins.filter((k) => !viewSkins(ctx, skins).includes(k))
  if (unreadSkins.length) for (const scheme of ['light', 'dark']) bad[scheme].push(`this run reads the views of ${viewSkins(ctx, skins).join(', ')} alone: ${unreadSkins.join(', ')} go unread`)
  if (count.fail) for (const scheme of ['light', 'dark']) bad[scheme].push(count.fail)
  // Motion allowed: the same drawn readings, so a rule that applies only with motion on cannot hide from them.
  if (ctx.motion !== false) bad.light.push(...(await motionFails(ctx, part, skins[0])))
  ST('motion')
  // Real states against their pins (states.mjs).
  if (ctx.states !== false) bad.light.push(...(await stateFails(ctx, part, driveSkins(skins)[0])))
  ST('states')
  const still = frozen(traces)
  const measures = { focusEdge: focus.max ? { min: +fmt(focus.min), max: +fmt(focus.max) } : null }
  for (const [surface, b] of Object.entries(bounds)) if (b.max) measures[surface === 'base' ? 'boundary' : `boundary:${surface}`] = { min: +fmt(b.min), max: +fmt(b.max), at: b.at }
  // Each wait on the sheet that was read, with the least it measured; the page prints it while it is short.
  if (part.json.layers?.length) measures.layers = { readings: layered.readings, seconds: +(layered.ms / 1000).toFixed(1) }
  measures.waits = SHEET_WAITS.filter((w) => waited.has(w)).map((w) => ({ ...w, now: +fmt(waited.get(w)) }))
  // A part with controls prints a boundary line for them, or names every one text-only.
  const named = new Set([...bare.values()].flat()).size
  if (controls > named && !measures.boundary) bad.light.push(`${controls - named} control(s) and no boundary reading`)
  // Numbers only, no light: how far a disabled fill sits from its ground and from the primary fill.
  const span = (xs) => ({ min: +fmt(Math.min(...xs)), max: +fmt(Math.max(...xs)) })
  for (const [surface, d] of Object.entries(disabled)) if (d.ground.length) measures[`disabled:${surface}`] = { againstGround: span(d.ground), againstPrimary: span(d.primary) }
  const distinct = new Set(skins.map((k) => sig[`${k} light`])).size
  const sameAcross = skins.filter((k) => sig[`${k} light`] === sig[`${k} dark`])
  const low = Math.min(...Object.values(bounds).map((b) => b.min))
  const boundNote = measures.boundary ? `; control boundary ${fmt(low)}:1 or more` : ''
  const focusNote = measures.focusEdge ? `; focus edge ${measures.focusEdge.min} to ${measures.focusEdge.max}:1` : ''
  const on = surfacesOf(ctx)
  const where = on.length > 1 ? ` on all ${on.length} surfaces` : ` on ${on[0]}`
  // Every reason a light is off, in order, so a run can be read in full (the selftest asserts on them).
  const fails = { light: [...still, ...bad.light], dark: [...still, ...bad.dark] }
  const off = (scheme, extra) => light(false, fails[scheme][0] ?? extra, { fails: fails[scheme].length ? fails[scheme] : [extra] })
  const skinsLight = fails.light.length
    ? off('light')
    : distinct < skins.length
      ? off('light', `only ${distinct} of ${skins.length} skins paint differently`)
      : light(true, `every element takes each of ${skins.length} skins' values${where}; weakest drawn text ${fmt(drawnWeakest.light)}:1; ${drawsAll(fullest.light)}${boundNote}${focusNote}`)
  const schemesLight = fails.dark.length
    ? off('dark')
    : sameAcross.length
      ? off('dark', `light and dark paint the same in ${sameAcross.join(', ')}`)
      : light(true, `dark paints its own values in every skin${where}; weakest drawn text ${fmt(drawnWeakest.dark)}:1; ${drawsAll(fullest.dark)}${boundNote}${focusNote}`)
  return { skins: skinsLight, schemes: schemesLight, views: count.line, measures, paintFree: [...free].map(([selector, why]) => ({ selector, why })), textOnly: [...bare].map(([selector, list]) => ({ selector, controls: list })) }
}

/** Pinned equals real, in one skin, light, on base at 1440px, and each state read as drawn in light and dark (states.mjs). */
async function stateFails(ctx, part, skin) {
  const page = await open(ctx, { scale: 2, height: 1600 })
  try {
    const show = (scheme) => view(page, skin, scheme)
    const fails = await realStates(page, part, { skin, settle, title: `part-${part.name}-title`, entries: ctx.entries ?? [], pairs: ctx.pairs ?? [], show, cover: Array.isArray(ctx.states) ? ctx.states : null })
    await stillStyled(ctx, page, 'states')
    return fails
  } finally {
    await page.context().close()
  }
}

/** Longhands a shorthand in the vocabulary sets but the vocabulary leaves out, as computed on every element in the
    stage and its ::before and ::after: each must sit at its initial value (a var() is read here, once resolved). */
const leftOut = (page, name) =>
  page.barkCheck(([n, list]) => {
    const h = window.__barkCheck
    const out = []
    for (const el of [...document.querySelector(`[data-part="${n}"]`).querySelectorAll('*')])
      for (const pe of [null, '::before', '::after']) {
        const s = getComputedStyle(el, pe)
        for (const [p, ok] of Object.entries(list)) {
          const v = s.getPropertyValue(p)
          if (v && !v.split(/,\s*/).every((x) => ok.includes(x))) out.push(`${h.describe(el)}${pe ?? ''} computes ${p}: ${v}; part.css may leave ${p} only at ${ok[0]}`)
        }
      }
    return out
  }, [name, LEFT_OUT_INITIAL])

/** Holds every animation at one moment: 'finished' (an endless one halfway through its first round) or
    'halfway' through. A transition is always finished: both its ends are states the lights read anyway. */
const hold = (page, when) =>
  page.barkCheck((w) => {
    for (const a of document.getAnimations()) {
      const t = a.effect.getComputedTiming()
      const endless = t.activeDuration === Infinity
      a.pause()
      a.currentTime = a instanceof CSSTransition || (w === 'finished' && !endless) ? t.endTime : t.delay + (endless ? t.duration : t.activeDuration) / 2
    }
  }, when)

/** The drawn readings with motion allowed. part.css cannot tell skins or schemes apart, so one skin in light shows
    what any motion does: every surface at 1440px and base at 390px, with animations finished and halfway. */
async function motionFails(ctx, part, skin) {
  const fails = []
  for (const [width, surfaces] of [[1440, surfacesOf(ctx)], [390, ['base']]]) {
    const page = await open(ctx, { scale: 2, width, height: width < 600 ? 844 : 1600, mobile: width < 600, motion: 'no-preference' })
    try {
      await pointTo(page, 0, 0)
      await view(page, skin, 'light')
      for (const surface of surfaces) {
        await page.barkCheck(([n, v]) => window.__barkCheck.restyle('a surface set', () => document.querySelector(`[data-part="${n}"]`).setAttribute('data-surface', v)), [part.name, surface])
        await settle(page)
        for (const when of ['finished', 'halfway']) {
          await hold(page, when)
          await limit(page.barkCheck(() => window.__barkCheck.frame()), STEP_MS, 'a frame')
          const waits = waitsFor(skin, 'light', surface)
          fails.push(...verdict(await readView(page, part, waits), `motion allowed, ${skin} light on ${surface} at ${width}px, animations ${when}: `, waits).fails)
        }
      }
      await stillStyled(ctx, page, 'motion')
    } finally {
      await page.context().close()
    }
  }
  return fails
}

export async function phone(ctx, part, skins, pages = VIEW_PAGES) {
  const sideways = (page) =>
    inCheck(page, (root) => {
      const doc = document.documentElement
      if (doc.scrollWidth > doc.clientWidth) return `page is ${doc.scrollWidth}px wide in a ${doc.clientWidth}px window`
      if (root.scrollWidth > root.clientWidth) return `the example is ${root.scrollWidth}px wide in ${root.clientWidth}px`
      const out = [...root.querySelectorAll('*')].find((el) => el.getBoundingClientRect().right > doc.clientWidth)
      return out ? `${out.textContent.trim()} ends past the window` : true
    }, part.name, 'the phone check')
  // The phone view is read in full, as the wide one is: every skin and scheme, on every surface, on pages of the one
  // browser at once (view-run.mjs), each view's part made in the list's order.
  let text = Infinity
  let edge = Infinity
  let weakest = NONE
  let fails = []
  let side = null
  const readAView = async (page, { skin, scheme }, keep) => {
    const at = `${skin} ${scheme}`
    await view(page, skin, scheme)
    for (const surface of surfacesOf(ctx)) {
      await page.barkCheck(([n, v]) => window.__barkCheck.restyle('a surface set', () => document.querySelector(`[data-part="${n}"]`).setAttribute('data-surface', v)), [part.name, surface])
      await settle(page)
      const where = `${at} on ${surface}`
      const r = await sideways(page)
      if (r !== true) {
        keep(() => (side = `${where}: ${r}`))
        return STOP
      }
      const waits = waitsFor(skin, scheme, surface)
      const readOne = async (said) => {
        const v = await readView(page, part, waits)
        const d = verdict(v, `${said}: `, waits)
        keep(() => {
          fails.push(...d.fails)
          text = Math.min(text, d.weakest.text.ratio)
          weakest = least(weakest, d.weakest)
          for (const c of v.bounds.read) {
            if (c.ratio < 3) fails.push(`${said}: control boundary ${fmt(c.ratio)}:1 at ${c.at} by its ${c.by}, needs 3:1`)
            edge = Math.min(edge, c.ratio)
          }
        })
      }
      await readOne(where)
      const open = await eachLayer(page, part, async (layer) => (await readOne(`${where} with ${layer.box} open`), []))
      keep(() => fails.push(...open.map((f) => `${where}: ${f}`)))
    }
    await page.barkCheck((n) => window.__barkCheck.restyle('a surface set', () => document.querySelector(`[data-part="${n}"]`).setAttribute('data-surface', 'base')), part.name)
  }
  const { once, count } = await readOnPages({
    views: viewList(skins),
    pages,
    what: 'the phone light',
    open: () => open(ctx, { width: 390, height: 844, mobile: true, scale: 2 }),
    read: (page, v, keep) => readAView(page, v, keep),
    end: (page) => stillStyled(ctx, page, 'phone'),
  })
  if (side) return { ...light(false, side), views: count.line }
  fails = once(fails)
  if (count.fail) fails.push(count.fail)
  if (fails.length) return { ...light(false, fails[0], { fails }), views: count.line }
  return { ...light(true, `nothing scrolls sideways at 390px on ${surfacesOf(ctx).length < 2 ? 'base' : `all ${surfacesOf(ctx).length} surfaces`}; weakest drawn text ${fmt(text)}:1; ${drawsAll(weakest)}; control boundary ${fmt(edge)}:1 or more`), views: count.line }
}

export async function noscript(ctx, part) {
  const page = await open(ctx, { js: false, scale: 2, height: 1600 })
  try {
    // Nothing on a stage with no script can write a style attribute: any one there fails by name (placement.mjs).
    const placed = await page.barkPlacement()
    if (placed.length) return light(false, placed[0], { fails: placed })
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
    const d = verdict(await readView(page, part))
    if (d.fails.length) return light(false, d.fails[0])
    return light(true, `${shown} elements printed, seen and painted with no script; weakest drawn text ${fmt(d.weakest.text.ratio)}:1; ${drawsAll(d.weakest)}`)
  } finally {
    await page.context().close()
  }
}
