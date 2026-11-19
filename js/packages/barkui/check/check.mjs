// runCheck: builds the showroom from a parts folder, drives it in headless
// Chromium with real input events, writes proof.json, and rebuilds the page so
// its lights show this run. A part whose run failed in any way (a step, a
// light, a page error, a time limit) gets no light on, and says why.
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { partsDir } from '../build/parts.mjs'
import { buildShowroom, foundationHash, outDir, proofPath, root, skinNames, tokensPath, uiSdkVersion } from '../build/showroom.mjs'
import { AT_ONCE, capacitySentence, PARTS_HELD } from './capacity.mjs'
import { unread } from './coverage.mjs'
import { readPartCss, sameAsShipped } from './cssom.mjs'
import { limit } from './limit.mjs'
import { noscript, phone, pressed, skinsAndSchemes, styleBaseline, surfacesOf } from './proofs.mjs'
import { waitLine } from '../build/sheet-waits.mjs'

// A part's limit: 120 s for each part that runs at the same time (they share the machine). A hang is caught
// sooner, by each step's own limit (STEP_MS in proofs.mjs).
export const PART_MS = 120000 * AT_ONCE
export const LIGHT_NAMES = ['pressed', 'skins', 'schemes', 'phone', 'noscript']

/** Every --ui-* / --bark-* name the sheet and the base styles define. */
function variableNames() {
  const text = readFileSync(tokensPath, 'utf8') + readFileSync(join(root, 'css', 'base.css'), 'utf8')
  return [...new Set([...text.matchAll(/(--(?:ui|bark)-[\w-]+)\s*:/g)].map((m) => m[1]))]
}

// `surfaces: false` skips measuring the four unproved surfaces, `motion: false` the reading with motion
// allowed, and `states: false` the real states held to their pins (the selftest skips each, except in the cases
// that plant there);
// `plantCss` is the selftest's planted sheet (see buildShowroom).
export async function runCheck({ dir = partsDir, out = outDir, proofFile = proofPath, only = LIGHT_NAMES, log = console.log, surfaces = true, motion = true, states = true, plantCss = '' } = {}) {
  let built
  let bare
  try {
    built = await buildShowroom({ dir, out, proof: proofFile, quiet: true, plantCss })
    bare = await buildShowroom({ dir, out: `${out}-bare`, proof: proofFile, quiet: true, plantCss, bare: true })
  } catch (e) {
    log(`check: ${e.message}`)
    return { ok: false, proof: null }
  }
  if (built.parts.length > PARTS_HELD) {
    log(`check: ${built.parts.length} parts, more than CI's check step holds. ${capacitySentence()} Raise the limit in check/capacity.mjs and js-tests.yml together, or split the check, then measure again.`)
    return { ok: false, proof: null }
  }
  const skins = skinNames(readFileSync(tokensPath, 'utf8'))
  // Grayscale text everywhere: with LCD text on, a layer the compositor makes non-opaque (a blend mode, say)
  // draws its glyphs another way than the reference does, and an honest label reads as cut.
  const browser = await chromium.launch({ args: ['--disable-lcd-text'] })
  // part.css as the browser parses it meets the same walls as its text, and the page's barkui.css holds each
  // part exactly as it was read alone (check/cssom.mjs).
  const judged = []
  for (const part of built.parts) {
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
  let styles
  try {
    styles = await styleBaseline(browser, pathToFileURL(bare.file).href)
  } catch (e) {
    await browser.close()
    log(`check: reading the build's own styles: ${e.message}`)
    return { ok: false, proof: null }
  }
  const proof = { ranAt: new Date().toISOString(), browser: `Chromium ${browser.version()}`, uiSdk: uiSdkVersion, foundation: foundationHash(), parts: {}, errors: [] }
  // Parts run AT_ONCE at a time, each in its own pages of the one browser; each part's lines print together
  // when it ends, and proof.json keeps the parts in folder order.
  const checkPart = async (part) => {
    const lines = []
    const ctx = { browser, url: pathToFileURL(built.file).href, part: part.name, errors: [], log, colourNames: variableNames(), styles, surfaces, motion, states, entries: judged.find((j) => j.name === part.name).entries, judged: new Set(), pairs: [] }
    lines.push(part.name)
    const lights = {}
    let measures = {}
    let paintFree = []
    let textOnly = []
    let steps = []
    try {
      await limit((async () => {
        if (only.includes('pressed')) ({ light: lights.pressed, steps } = await pressed(ctx, part, skins))
        if (only.includes('skins') || only.includes('schemes')) {
          const looks = await skinsAndSchemes(ctx, part, skins)
          Object.assign(lights, { skins: looks.skins, schemes: looks.schemes })
          measures = looks.measures
          paintFree = looks.paintFree
          textOnly = looks.textOnly
        }
        if (only.includes('phone')) lights.phone = await phone(ctx, part, skins)
        if (only.includes('noscript')) lights.noscript = await noscript(ctx, part)
      })(), PART_MS, `part ${part.name}`)
    } catch (e) {
      ctx.errors.push(String(e.message).split('\n')[0])
    }
    for (const k of LIGHT_NAMES) if (!lights[k]) lights[k] = { pass: false, detail: only.includes(k) ? 'did not finish' : 'not run in this run' }
    const offs = only.filter((k) => !lights[k].pass).map((k) => `${k}: ${lights[k].detail}`)
    // Coverage, once every light has read: a rule or a driven pair no judged reading saw fails the part.
    const missed = LIGHT_NAMES.every((k) => only.includes(k)) && states && !ctx.errors.length ? unread(ctx) : []
    for (const m of missed) lines.push(`  ${m}`)
    const failed = ctx.errors[0] ?? missed[0] ?? offs[0]
    for (const [k, l] of Object.entries(lights)) lines.push(`  ${l.pass && !failed ? 'on ' : 'OFF'} ${k}: ${l.detail}`)
    for (const w of measures.waits ?? []) lines.push(`  ${waitLine(w, w.now)}`)
    for (const [k, m] of Object.entries(measures))
      if (k === 'waits') continue
      else if (m?.againstGround) lines.push(`  measured ${k}: against the ground ${m.againstGround.min} to ${m.againstGround.max}:1, against the primary fill ${m.againstPrimary.min} to ${m.againstPrimary.max}:1`)
      else if (m) lines.push(`  measured ${k}: ${m.min} to ${m.max}:1`)
    if (failed) for (const l of Object.values(lights)) if (l.pass) Object.assign(l, { pass: false, detail: `the run failed (${failed.slice(0, 160)})` })
    for (const l of Object.values(lights)) l.surfaces = surfacesOf(ctx)
    for (const l of lines) log(l)
    return { entry: { hash: part.hash, lights, measures, paintFree, textOnly, steps, ...(missed.length ? { unread: missed } : {}), ...(failed ? { failed } : {}) }, errors: ctx.errors }
  }
  try {
    const done = new Array(built.parts.length)
    let next = 0
    const worker = async () => {
      while (next < built.parts.length) {
        const i = next++
        done[i] = await checkPart(built.parts[i])
      }
    }
    await Promise.all(Array.from({ length: Math.min(AT_ONCE, built.parts.length) }, worker))
    built.parts.forEach((part, i) => {
      proof.parts[part.name] = done[i].entry
      proof.errors.push(...done[i].errors)
    })
  } finally {
    await browser.close()
  }
  writeFileSync(proofFile, JSON.stringify(proof, null, 2) + '\n')
  await buildShowroom({ dir, out, proof: proofFile, quiet: true })
  for (const e of proof.errors) log(`error: ${e}`)
  const failedParts = Object.entries(proof.parts).filter(([, p]) => p.failed)
  log(`${built.parts.length} part(s); ${failedParts.length ? `failed: ${failedParts.map(([n]) => n).join(', ')}` : 'every light on'}; ${proof.errors.length} page error(s)`)
  return { ok: !failedParts.length && !proof.errors.length, proof }
}
