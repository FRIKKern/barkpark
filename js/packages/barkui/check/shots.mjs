// node check/shots.mjs <dir>: light and dark shots of the built showroom, 1440
// wide, and close crops of a focused primary and a focused secondary button
// (focused by real Tab presses), side by side.
import { chromium } from 'playwright'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
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
    await page.close()
    await sheet.close()
  }
} finally {
  await browser.close()
}
console.log(`shots in ${dir}`)
