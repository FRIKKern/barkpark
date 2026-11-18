// node check/run.mjs: builds the showroom, drives it in headless Chromium with
// real input events, and writes dist/proof.json; then rebuilds the page so its
// lights show this run. Exits non-zero when a part folder is incomplete, a
// press step fails, a proof fails, or the page logs an error or asks the network.
import { writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { buildShowroom, foundationHash, proofPath, skinNames, tokensPath, uiSdkVersion } from '../build/showroom.mjs'
import { installHelpers, source } from './probes.mjs'
import { readFileSync } from 'node:fs'

const wait = (ms) => new Promise((r) => setTimeout(r, ms))
let parts, file
try {
  ;({ parts, file } = await buildShowroom({ quiet: true }))
} catch (e) {
  console.error(`check: ${e.message}`)
  process.exit(1)
}
const url = pathToFileURL(file).href
const skins = skinNames(readFileSync(tokensPath, 'utf8'))
const errors = []

async function open(browser, { width = 1440, height = 900, js = true, scheme = 'light', mobile = false } = {}) {
  const context = await browser.newContext({ viewport: { width, height }, javaScriptEnabled: js, colorScheme: scheme, reducedMotion: 'reduce', isMobile: mobile, hasTouch: mobile })
  const page = await context.newPage()
  const where = `${width}px${js ? '' : ', no script'}`
  page.on('pageerror', (e) => errors.push(`${where}: ${String(e).slice(0, 200)}`))
  page.on('console', (m) => m.type() === 'error' && errors.push(`${where}: console: ${m.text().slice(0, 200)}`))
  page.on('request', (r) => !/^(file|data|blob):/.test(r.url()) && errors.push(`${where}: asked the network for ${r.url().slice(0, 120)}`))
  await page.goto(url)
  if (js) await page.waitForSelector('html[data-ready]', { timeout: 15000 })
  await page.evaluate(installHelpers)
  return page
}

const inPage = (page, fn, name, extra) =>
  page.evaluate(
    ([src, n, x]) => (0, eval)(`(${src})`)(document.querySelector(`[data-part="${n}"]`), window.__barkCheck, x),
    [source(fn), name, extra ?? null],
  )
const paintOf = (page, part) => page.evaluate(([n, spec]) => window.__barkCheck.paint(document.querySelector(`[data-part="${n}"]`), spec), [part.name, part.json.paint ?? []])
const view = (page, skin, scheme) =>
  page.evaluate(([k, s]) => {
    document.documentElement.setAttribute('data-skin', k)
    document.documentElement.setAttribute('data-color-scheme', s)
  }, [skin, scheme])
const settle = (page) => page.evaluate(() => window.__barkCheck.settle())
const light = (pass, detail) => ({ pass: !!pass, detail })
const fmt = (w) => (w.ratio === Infinity ? 'no text' : `weakest text ${w.ratio.toFixed(2)}:1`)

async function pressed(browser, part) {
  const { setup, steps } = await import(pathToFileURL(part.press).href)
  if (!Array.isArray(steps) || !steps.length) return { light: light(false, 'press.mjs exports no steps'), steps: [] }
  const page = await open(browser)
  const results = []
  try {
    if (setup) await inPage(page, setup, part.name)
    await page.focus(`#part-${part.name}-title`)
    for (const step of steps) {
      let result
      try {
        if (step.click) await page.click(`[data-part="${part.name}"] ${step.click}`, { force: true })
        for (const key of step.keys ?? []) await page.keyboard.press(key)
        await wait(step.wait ?? 0)
        await settle(page)
        result = await inPage(page, step.expect, part.name)
      } catch (e) {
        result = String(e.message).split('\n')[0]
      }
      results.push({ name: step.name, pass: result === true, detail: result === true ? '' : String(result) })
      console.log(`  ${result === true ? 'pass' : 'FAIL'} ${step.name}${result === true ? '' : `: ${result}`}`)
    }
  } finally {
    await page.context().close()
  }
  const failed = results.filter((r) => !r.pass)
  return { light: light(!failed.length, failed.length ? `${failed[0].name}: ${failed[0].detail}` : `${results.length} steps by real keys`), steps: results }
}

async function skinsAndSchemes(browser, part) {
  const page = await open(browser)
  const seen = { light: new Map(), dark: new Map() }
  const bad = { light: [], dark: [] }
  let weakest = { ratio: Infinity }
  try {
    await page.mouse.move(0, 0)
    for (const scheme of ['light', 'dark']) {
      for (const skin of skins) {
        await view(page, skin, scheme)
        await settle(page)
        const r = await paintOf(page, part)
        seen[scheme].set(skin, r.signature)
        if (r.weakest.ratio < weakest.ratio) weakest = { ...r.weakest, where: `${skin} ${scheme}` }
        if (r.wrong.length) bad[scheme].push(`${skin}: ${r.wrong[0]}`)
        if (r.weakest.ratio < 4.5) bad[scheme].push(`${skin}: text ${r.weakest.ratio.toFixed(2)}:1 at ${r.weakest.at}`)
      }
    }
  } finally {
    await page.context().close()
  }
  const distinct = new Set(seen.light.values()).size
  const sameAcross = skins.filter((k) => seen.light.get(k) === seen.dark.get(k))
  const skinsLight = bad.light.length
    ? light(false, bad.light[0])
    : distinct < skins.length
      ? light(false, `only ${distinct} of ${skins.length} skins paint differently`)
      : light(true, `${skins.length} skins paint their own values; ${fmt(weakest)}`)
  const schemesLight = bad.dark.length
    ? light(false, bad.dark[0])
    : sameAcross.length
      ? light(false, `light and dark paint the same in ${sameAcross.join(', ')}`)
      : light(true, `dark paints its own values in every skin; weakest text ${weakest.ratio.toFixed(2)}:1 (${weakest.where})`)
  return { skins: skinsLight, schemes: schemesLight }
}

async function phone(browser, part) {
  const page = await open(browser, { width: 390, height: 844, mobile: true })
  try {
    const r = await inPage(page, (root) => {
      const doc = document.documentElement
      if (doc.scrollWidth > doc.clientWidth) return `page is ${doc.scrollWidth}px wide in a ${doc.clientWidth}px window`
      if (root.scrollWidth > root.clientWidth) return `the example is ${root.scrollWidth}px wide in ${root.clientWidth}px`
      const out = [...root.querySelectorAll('[data-slot]')].find((el) => el.getBoundingClientRect().right > doc.clientWidth)
      return out ? `${out.textContent.trim()} ends past the window` : true
    }, part.name)
    return light(r === true, r === true ? 'nothing scrolls sideways at 390px' : r)
  } finally {
    await page.context().close()
  }
}

async function noscript(browser, part) {
  const page = await open(browser, { js: false })
  try {
    const shown = await inPage(page, (root) => {
      // Every part element that carries text or an icon must have a box (an idle spinner carries neither).
      const els = [...root.querySelectorAll('[data-slot]')].filter((el) => el.textContent.trim() || el.querySelector('svg'))
      if (!els.length) return 'no part is printed'
      const hidden = els.find((el) => !el.getClientRects().length || !el.getBoundingClientRect().width)
      return hidden ? `${hidden.outerHTML.slice(0, 60)} has no box` : els.length
    }, part.name)
    if (typeof shown === 'string') return light(false, shown)
    const r = await paintOf(page, part)
    if (r.wrong.length) return light(false, r.wrong[0])
    if (r.weakest.ratio < 4.5) return light(false, `text ${r.weakest.ratio.toFixed(2)}:1 at ${r.weakest.at}`)
    return light(true, `${shown} elements printed and painted with no script`)
  } finally {
    await page.context().close()
  }
}

const browser = await chromium.launch()
const proof = { ranAt: new Date().toISOString(), browser: `Chromium ${browser.version()}`, uiSdk: uiSdkVersion, foundation: foundationHash(), parts: {} }
try {
  for (const part of parts) {
    console.log(`${part.name}`)
    const press = await pressed(browser, part)
    const looks = await skinsAndSchemes(browser, part)
    const lights = { pressed: press.light, ...looks, phone: await phone(browser, part), noscript: await noscript(browser, part) }
    for (const [k, l] of Object.entries(lights)) console.log(`  ${l.pass ? 'on ' : 'OFF'} ${k}: ${l.detail}`)
    proof.parts[part.name] = { hash: part.hash, lights, steps: press.steps }
  }
} finally {
  await browser.close()
}
proof.errors = errors
writeFileSync(proofPath, JSON.stringify(proof, null, 2) + '\n')
await buildShowroom({ quiet: true })

const off = Object.entries(proof.parts).flatMap(([n, p]) => Object.entries(p.lights).filter(([, l]) => !l.pass).map(([k]) => `${n}.${k}`))
for (const e of errors) console.error(`error: ${e}`)
console.log(`${parts.length} part(s); ${off.length ? `lights off: ${off.join(', ')}` : 'every light on'}; ${errors.length} page error(s)`)
process.exit(off.length || errors.length ? 1 : 0)
