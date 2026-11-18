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
import { limit } from './limit.mjs'
import { noscript, phone, pressed, skinsAndSchemes } from './proofs.mjs'

export const PART_MS = 120000
export const LIGHT_NAMES = ['pressed', 'skins', 'schemes', 'phone', 'noscript']

/** Every --ui-* / --bark-* name the sheet and the base styles define. */
function variableNames() {
  const text = readFileSync(tokensPath, 'utf8') + readFileSync(join(root, 'css', 'base.css'), 'utf8')
  return [...new Set([...text.matchAll(/(--(?:ui|bark)-[\w-]+)\s*:/g)].map((m) => m[1]))]
}

export async function runCheck({ dir = partsDir, out = outDir, proofFile = proofPath, only = LIGHT_NAMES, log = console.log } = {}) {
  let built
  try {
    built = await buildShowroom({ dir, out, proof: proofFile, quiet: true })
  } catch (e) {
    log(`check: ${e.message}`)
    return { ok: false, proof: null }
  }
  const skins = skinNames(readFileSync(tokensPath, 'utf8'))
  const browser = await chromium.launch()
  const proof = { ranAt: new Date().toISOString(), browser: `Chromium ${browser.version()}`, uiSdk: uiSdkVersion, foundation: foundationHash(), parts: {}, errors: [] }
  try {
    for (const part of built.parts) {
      const ctx = { browser, url: pathToFileURL(built.file).href, part: part.name, errors: [], log, colourNames: variableNames() }
      log(part.name)
      const lights = {}
      let measures = {}
      let paintFree = []
      let steps = []
      try {
        await limit((async () => {
          if (only.includes('pressed')) ({ light: lights.pressed, steps } = await pressed(ctx, part))
          if (only.includes('skins') || only.includes('schemes')) {
            const looks = await skinsAndSchemes(ctx, part, skins)
            Object.assign(lights, { skins: looks.skins, schemes: looks.schemes })
            measures = looks.measures
            paintFree = looks.paintFree
          }
          if (only.includes('phone')) lights.phone = await phone(ctx, part)
          if (only.includes('noscript')) lights.noscript = await noscript(ctx, part)
        })(), PART_MS, `part ${part.name}`)
      } catch (e) {
        ctx.errors.push(String(e.message).split('\n')[0])
      }
      for (const k of LIGHT_NAMES) if (!lights[k]) lights[k] = { pass: false, detail: only.includes(k) ? 'did not finish' : 'not run in this run' }
      const offs = only.filter((k) => !lights[k].pass).map((k) => `${k}: ${lights[k].detail}`)
      const failed = ctx.errors[0] ?? offs[0]
      for (const [k, l] of Object.entries(lights)) log(`  ${l.pass && !failed ? 'on ' : 'OFF'} ${k}: ${l.detail}`)
      for (const [k, m] of Object.entries(measures)) if (m) log(`  measured ${k}: ${m.min} to ${m.max}:1`)
      if (failed) for (const l of Object.values(lights)) if (l.pass) Object.assign(l, { pass: false, detail: `the run failed (${failed.slice(0, 160)})` })
      proof.parts[part.name] = { hash: part.hash, lights, measures, paintFree, steps, ...(failed ? { failed } : {}) }
      proof.errors.push(...ctx.errors)
    }
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
