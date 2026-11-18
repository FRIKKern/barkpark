// node check/shots.mjs <dir>: light and dark shots of the built showroom, 1440
// wide; close crops of a focused primary and a focused secondary button
// (focused by real Tab presses), side by side; and the button's first rows on
// every surface, stacked; and the part's lights after picking the primary
// surface on the Surface control (they show as not proved there).
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { SURFACES } from '../build/page.mjs'
import { outDir } from '../build/showroom.mjs'

const dir = process.argv[2]
if (!dir) throw new Error('usage: node check/shots.mjs <dir>')
mkdirSync(dir, { recursive: true })
const browser = await chromium.launch()
try {
  for (const scheme of ['light', 'dark']) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: scheme, deviceScaleFactor: 2 })
    await page.goto(`${pathToFileURL(join(outDir, 'index.html'))}#scheme=${scheme}`)
    await page.waitForSelector('html[data-ready]')
    await page.screenshot({ path: join(dir, `showroom-${scheme}.png`), fullPage: true, scale: 'css' })
    const crops = []
    await page.focus('#part-button-title')
    for (const [id, tabs] of [['#button-primary', 1], ['#button-secondary', 1]]) {
      for (let i = 0; i < tabs; i++) await page.keyboard.press('Tab')
      await page.waitForTimeout(250)
      const box = await page.locator(id).boundingBox()
      const clip = { x: box.x - 12, y: box.y - 12, width: box.width + 24, height: box.height + 24 }
      crops.push(`data:image/png;base64,${(await page.screenshot({ clip })).toString('base64')}`)
    }
    const sheet = await browser.newPage({ deviceScaleFactor: 1, colorScheme: scheme })
    await sheet.setContent(`<body style="margin:0;display:inline-flex;gap:0;background:${scheme === 'dark' ? '#000' : '#fff'}">${crops.map((c) => `<img src="${c}">`).join('')}</body>`)
    await sheet.locator('body').screenshot({ path: join(dir, `focus-${scheme}.png`) })
    const rows = []
    for (const surface of SURFACES) {
      await page.evaluate((v) => document.querySelector('[data-part="button"]').setAttribute('data-surface', v), surface)
      await page.keyboard.press('Escape')
      await page.evaluate(() => document.activeElement?.blur())
      await page.waitForTimeout(250)
      const clip = await page.evaluate(() => {
        const stage = document.querySelector('[data-part="button"]').getBoundingClientRect()
        const row = document.querySelectorAll('[data-part="button"] [data-demo-row]')[1].getBoundingClientRect()
        return { x: stage.x, y: stage.y + window.scrollY, width: 720, height: row.bottom - stage.y + 20 }
      })
      rows.push([surface, `data:image/png;base64,${(await page.screenshot({ clip, fullPage: true })).toString('base64')}`])
    }
    const ground = scheme === 'dark' ? '#000' : '#fff'
    const ink = scheme === 'dark' ? '#9a9a9a' : '#5f5f5f'
    await sheet.setContent(`<body style="margin:0;padding:16px;display:inline-flex;flex-direction:column;gap:8px;background:${ground};color:${ink};font:13px system-ui">${rows.map(([n, c]) => `<div>${n}</div><img src="${c}" style="width:720px">`).join('')}</body>`)
    await sheet.locator('body').screenshot({ path: join(dir, `surfaces-${scheme}.png`) })
    await page.evaluate(() => window.scrollTo(0, 0))
    await page.click('label.sr-radio:has(input[name="surface"][value="primary"])')
    const head = await page.locator('#part-button .sr-part-head').boundingBox()
    await page.screenshot({ path: join(dir, `unproved-${scheme}.png`), clip: { x: head.x - 12, y: head.y - 12, width: Math.min(head.width, 900) + 24, height: head.height + 24 } })
    await page.close()
    await sheet.close()
  }
} finally {
  await browser.close()
}
console.log(`shots in ${dir}`)
