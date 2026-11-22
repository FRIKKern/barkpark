// TEMPORARY probe on a throwaway branch: why text in two stages reads differently on the hosted runner.
import { chromium } from 'playwright'
import { mkdirSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { resolve, join } from 'node:path'

const out = process.argv[2]
mkdirSync(out, { recursive: true })
const url = pathToFileURL(resolve('dist/showroom/index.html')).href
const b = await chromium.launch()
const info = []
const shoot = async (tag, prep) => {
  const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: 'reduce', colorScheme: 'light' })
  const p = await ctx.newPage()
  await p.goto(url)
  await p.waitForSelector('html[data-ready]')
  if (prep) await p.evaluate(prep)
  await p.waitForTimeout(300)
  for (const n of ['tabs', 'select', 'text-field']) {
    const el = await p.$(`[data-part="${n}"]`)
    if (!el) continue
    await el.scrollIntoViewIfNeeded()
    await el.screenshot({ path: join(out, `${tag}-${n}.png`) })
    info.push({ tag, n, ...(await p.evaluate((n) => {
      const st = document.querySelector(`[data-part="${n}"]`)
      const lab = st.querySelector('[data-demo-label]')
      const s = getComputedStyle(lab)
      const all = [...document.querySelectorAll('*')].filter((e) => { const c = getComputedStyle(e); return c.position === 'fixed' || c.position === 'sticky' || c.willChange !== 'auto' || c.transform !== 'none' || c.filter !== 'none' || c.backdropFilter !== 'none' || c.mixBlendMode !== 'normal' || (c.opacity !== '1' && e.getClientRects().length) }).map((e) => `${e.tagName.toLowerCase()}#${e.id}.${e.className} pos=${getComputedStyle(e).position} op=${getComputedStyle(e).opacity} tf=${getComputedStyle(e).transform} wc=${getComputedStyle(e).willChange}`)
      return { y: lab.getBoundingClientRect().top + scrollY, scrollH: document.scrollingElement.scrollHeight, font: s.font, color: s.color, smooth: s.webkitFontSmoothing, ground: getComputedStyle(st).backgroundColor, special: all.slice(0, 40), fonts: [...document.fonts].map((f) => `${f.family} ${f.status}`) }
    }, n)) })
  }
  await ctx.close()
}
await shoot('as-is')
await shoot('no-select', () => document.querySelector('[data-part="select"]').closest('section, article, div.sr-part')?.remove() ?? document.querySelector('[data-part="select"]').remove())
await shoot('no-select-js', () => { for (const e of document.querySelectorAll('ui-select')) e.replaceWith(...e.childNodes) })
writeFileSync(join(out, 'info.json'), JSON.stringify(info, null, 1))
await b.close()
