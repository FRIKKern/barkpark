// runCheck: builds the showroom from a parts folder, drives it in headless
// Chromium with real input events, writes proof.json, and rebuilds the page so
// its lights show this run. A part whose run failed in any way (a step, a
// light, a page error, a time limit) gets no light on, and says why.
import { copyFileSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom, foundationHash, outDir, proofPath, root, skinNames, tokensPath, uiSdkVersion } from '../build/showroom.mjs'
import { AT_ONCE, capacitySentence, PER_JOB } from './capacity.mjs'
import { unread } from './coverage.mjs'
import { readPartCss, sameAsShipped } from './cssom.mjs'
import { limit } from './limit.mjs'
import { noscript, phone, pressed, skinsAndSchemes, styleBaseline, surfacesOf } from './proofs.mjs'
import { waitLine } from '../build/sheet-waits.mjs'
import { VIEW_PAGES } from './view-pages.mjs'
import { launch, refusals } from './acts.mjs'
import { pageOf, startOrder } from './jobs.mjs'
import { writePartPage } from './part-page.mjs'
import { nearLine, timeLine } from './part-time.mjs'

// A part's limit: 120 s for each part that runs at the same time (they share the machine). A hang is caught
// sooner, by each step's own limit (STEP_MS in proofs.mjs).
export const PART_MS = 120000 * AT_ONCE
export const LIGHT_NAMES = ['pressed', 'skins', 'schemes', 'phone', 'noscript']

/** Every --ui-* / --bark-* name the sheet and the base styles define. */
function variableNames() {
  const text = readFileSync(tokensPath, 'utf8') + readFileSync(join(root, 'css', 'base.css'), 'utf8')
  return [...new Set([...text.matchAll(/(--(?:ui|bark)-[\w-]+)\s*:/g)].map((m) => m[1]))]
}

// `surfaces: false` skips measuring the four unproved surfaces (a list of them measures base and those),
// `motion: false` the reading with motion allowed, and `states: false` the real states held to their pins (the selftest skips each, except in the cases
// that plant there; a list of selectors drives only the live controls they match, states.mjs, and the wide views are
// then read in the drive's own skins alone, proofs.mjs's driveSkins);
// `plantCss` is the selftest's planted sheet (see buildShowroom). `names` is the group one CI job checks
// (check/jobs.mjs): the page of every part folder is built first, so each folder builds and ids stay unique
// page-wide; then those parts are pressed and read on a page that prints their stages, and the stage that follows
// each of them on the page of every part (a stage reads otherwise at the end of a page; a group need not be a run of
// neighbours there, check/jobs.mjs split), built from those folders alone (pageOf), and that loads the whole page's
// barkui.css, every part's sheet. So each stage wears
// every rule it wears on the page of every part and has what follows it there, and a part's time does not grow with
// the folder. Without it, every part is read, on the page of every folder. Either way, each part is read on a copy of
// that page whose other stages are hidden but the one that follows it (check/part-page.mjs), so its time does not grow
// with the stages beside it.
export async function runCheck(o = {}) {
  const { dir = partsDir, out = outDir, proofFile = proofPath, log = console.log, plantCss = '', names = null } = o
  if (!names) return readParts(o)
  let whole
  try {
    whole = await buildShowroom({ dir, out: `${out}-whole`, proof: proofFile, quiet: true, plantCss })
  } catch (e) {
    log(`check: ${e.message}`)
    return { ok: false, proof: null }
  }
  const unknown = names.filter((n) => !whole.parts.some((p) => p.name === n))
  if (unknown.length) {
    log(`check: no part folder named ${unknown.join(', ')}`)
    return { ok: false, proof: null }
  }
  // The stage that follows each part read, on the page of every part: printed, never pressed or read. In name order,
  // each part's follower is then the next stage on this page too.
  const order = whole.parts.map((p) => p.name)
  // PLANT 3: the old page, the follower of the last part alone.
  const last = order[Math.max(...names.map((n) => order.indexOf(n))) + 1]
  const page = pageOf(dir, last ? [...names, last] : names)
  try {
    return await readParts({ ...o, dir: page, sheet: join(`${out}-whole`, 'barkui.css'), every: whole.parts })
  } finally {
    rmSync(page, { recursive: true, force: true })
  }
}

// `sheet` and `every` (runCheck, given `names`): the barkui.css of the page of every part, which the page read loads
// in place of its own, and every part in it, each read alone and held to its section there (sameAsShipped).
async function readParts({ dir = partsDir, out = outDir, proofFile = proofPath, only = LIGHT_NAMES, log = console.log, surfaces = true, motion = true, states = true, plantCss = '', names = null, viewPages = VIEW_PAGES, sheet = null, every = null } = {}) {
  // A refusal by the wall anywhere in this run (check/acts.mjs), a timer's or a listener's too, is an error of the run.
  const before = refusals().length
  let built
  let bare
  try {
    built = await buildShowroom({ dir, out, proof: proofFile, quiet: true, plantCss })
    bare = await buildShowroom({ dir, out: `${out}-bare`, proof: proofFile, quiet: true, plantCss, bare: true })
    if (sheet) for (const o of [out, `${out}-bare`]) copyFileSync(sheet, join(o, 'barkui.css'))
  } catch (e) {
    log(`check: ${e.message}`)
    return { ok: false, proof: null }
  }
  const unknown = (names ?? []).filter((n) => !built.parts.some((p) => p.name === n))
  if (unknown.length) {
    log(`check: no part folder named ${unknown.join(', ')}`)
    return { ok: false, proof: null }
  }
  const mine = names ? built.parts.filter((p) => names.includes(p.name)) : built.parts
  if (mine.length > PER_JOB) {
    log(`check: ${mine.length} parts in one job, more than one CI job holds. ${capacitySentence()} Split them across more jobs (check/jobs.mjs does), or read a job on CI's runner and put the reading in check/capacity.mjs.`)
    return { ok: false, proof: null }
  }
  const skins = skinNames(readFileSync(tokensPath, 'utf8'))
  // Grayscale text everywhere: with LCD text on, a layer the compositor makes non-opaque (a blend mode, say)
  // draws its glyphs another way than the reference does, and an honest label reads as cut.
  const browser = await launch({ args: ['--disable-lcd-text'] })
  // part.css as the browser parses it meets the same walls as its text, and the page's barkui.css holds each
  // part exactly as it was read alone (check/cssom.mjs).
  const judged = []
  for (const part of every ?? built.parts) {
    const { found, rules, entries } = await readPartCss(browser, part.css)
    judged.push({ name: part.name, rules, entries })
    if (!found.length) continue
    await browser.close()
    for (const f of found) log(`check: parts/${part.name}/part.css, as the browser reads it: ${f}`)
    return { ok: false, proof: null }
  }
  const shipped = await sameAsShipped(browser, join(out, 'barkui.css'), judged)
  if (shipped.length) {
    await browser.close()
    for (const f of shipped) log(`check: ${f}`)
    return { ok: false, proof: null }
  }
  // Each part is read on its own copy of the page, the stages of the other parts hidden but the one that follows it
  // (check/part-page.mjs), and its baseline is the same copy of the page built without any demo.
  const order = built.parts.map((p) => p.name)
  const written = []
  const pages = {}
  const styles = {}
  const drop = () => written.forEach((f) => rmSync(f, { force: true }))
  try {
    for (const part of mine) {
      pages[part.name] = writePartPage(built.file, order, part.name)
      written.push(pages[part.name])
      const base = writePartPage(bare.file, order, part.name)
      written.push(base)
      styles[part.name] = await styleBaseline(browser, pathToFileURL(base).href)
    }
  } catch (e) {
    await browser.close()
    drop()
    log(`check: reading the build's own styles: ${e.message}`)
    return { ok: false, proof: null }
  }
  const proof = { ranAt: new Date().toISOString(), browser: `Chromium ${browser.version()}`, uiSdk: uiSdkVersion, foundation: foundationHash(), parts: {}, errors: [] }
  // Parts run AT_ONCE at a time, each in its own pages of the one browser, lightest first (check/jobs.mjs startOrder),
  // so a job's heaviest part starts last, as the others end; each part's lines print together when it ends, and
  // proof.json keeps the parts in folder order.
  const checkPart = async (part) => {
    const lines = []
    const ctx = { browser, url: pathToFileURL(pages[part.name]).href, part: part.name, errors: [], log, colourNames: variableNames(), styles: styles[part.name], surfaces, motion, states, entries: judged.find((j) => j.name === part.name).entries, judged: new Set(), pairs: [] }
    lines.push(part.name)
    const lights = {}
    let measures = {}
    let paintFree = []
    let textOnly = []
    let steps = []
    let viewsLine = null
    const began = performance.now()
    try {
      await limit((async () => {
        if (only.includes('pressed')) ({ light: lights.pressed, steps } = await pressed(ctx, part, skins))
        if (only.includes('skins') || only.includes('schemes')) {
          const looks = await skinsAndSchemes(ctx, part, skins, viewPages)
          viewsLine = looks.views
          Object.assign(lights, { skins: looks.skins, schemes: looks.schemes })
          measures = looks.measures
          paintFree = looks.paintFree
          textOnly = looks.textOnly
        }
        if (only.includes('phone')) lights.phone = await phone(ctx, part, skins, viewPages)
        if (only.includes('noscript')) lights.noscript = await noscript(ctx, part)
      })(), PART_MS, `part ${part.name}`)
    } catch (e) {
      ctx.errors.push(String(e.message).split('\n')[0])
    }
    const ms = performance.now() - began
    for (const k of LIGHT_NAMES) if (!lights[k]) lights[k] = { pass: false, detail: only.includes(k) ? 'did not finish' : 'not run in this run' }
    const offs = only.filter((k) => !lights[k].pass).map((k) => `${k}: ${lights[k].detail}`)
    // Coverage, once every light has read: a rule or a driven pair no judged reading saw fails the part.
    const missed = LIGHT_NAMES.every((k) => only.includes(k)) && states && !Array.isArray(states) && !ctx.errors.length ? unread(ctx) : []
    for (const m of missed) lines.push(`  ${m}`)
    // A light's own reason first: it names the cause; coverage names only what no reading saw.
    const failed = ctx.errors[0] ?? offs[0] ?? missed[0]
    for (const [k, l] of Object.entries(lights)) lines.push(`  ${l.pass && !failed ? 'on ' : 'OFF'} ${k}: ${l.detail}`)
    if (viewsLine) lines.push(`  ${viewsLine}`)
    if (lights.phone?.views) lines.push(`  ${lights.phone.views}`)
    lines.push(`  ${timeLine(ms, PART_MS)}`)
    for (const w of measures.waits ?? []) lines.push(`  ${waitLine(w, w.now)}`)
    for (const [k, m] of Object.entries(measures))
      if (k === 'waits') continue
      else if (k === 'layers') lines.push(`  measured the top layer: ${m.readings} readings with a layer open, ${m.seconds} s with opening and closing, ${m.readings ? (m.seconds / m.readings).toFixed(2) : 0} s each`)
      else if (m?.againstGround) lines.push(`  measured ${k}: against the ground ${m.againstGround.min} to ${m.againstGround.max}:1, against the primary fill ${m.againstPrimary.min} to ${m.againstPrimary.max}:1`)
      else if (m) lines.push(`  measured ${k}: ${m.min} to ${m.max}:1`)
    if (failed) for (const l of Object.values(lights)) if (l.pass) Object.assign(l, { pass: false, detail: `the run failed (${failed.slice(0, 160)})` })
    for (const l of Object.values(lights)) l.surfaces = surfacesOf(ctx)
    for (const l of lines) log(l)
    return { ms, entry: { hash: part.hash, lights, measures, paintFree, textOnly, steps, ...(missed.length ? { unread: missed } : {}), ...(failed ? { failed } : {}) }, errors: ctx.errors }
  }
  const done = new Array(mine.length)
  try {
    const queue = startOrder(mine.map((p) => p.name)).map((n) => mine.findIndex((p) => p.name === n))
    let next = 0
    const worker = async () => {
      while (next < queue.length) {
        const i = queue[next++]
        done[i] = await checkPart(mine[i])
      }
    }
    await Promise.all(Array.from({ length: Math.min(AT_ONCE, mine.length) }, worker))
    mine.forEach((part, i) => {
      proof.parts[part.name] = done[i].entry
      proof.errors.push(...done[i].errors)
    })
  } finally {
    await browser.close()
    drop()
  }
  for (const r of refusals().slice(before)) proof.errors.push(`the wall refused ${r.what}, from ${r.at}`)
  writeFileSync(proofFile, JSON.stringify(proof, null, 2) + '\n')
  await buildShowroom({ dir, out, proof: proofFile, quiet: true })
  if (sheet) copyFileSync(sheet, join(out, 'barkui.css'))
  for (const e of proof.errors) log(`error: ${e}`)
  log(nearLine(Object.fromEntries(mine.map((part, i) => [part.name, done[i].ms])), PART_MS))
  const failedParts = Object.entries(proof.parts).filter(([, p]) => p.failed)
  log(`${mine.length} part(s); ${failedParts.length ? `failed: ${failedParts.map(([n]) => n).join(', ')}` : 'every light on'}; ${proof.errors.length} page error(s)`)
  return { ok: !failedParts.length && !proof.errors.length, proof }
}
