// node build/pictures.mjs: retakes every picture the README, QUALITY.md and the
// decisions show, into docs/images/, from the built showroom. Run it after
// `pnpm run build` and `pnpm run check`, so the lights in the pictures are the
// last run's. The pictures are the real page; nothing is drawn for them.
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { outDir, root } from './showroom.mjs'

const images = join(root, 'docs', 'images')
// The page in a skin and scheme, as its address keeps them. `null` is the sheet's first skin.
const PAGES = [
  ['showroom-light.png', null, 'light'],
  ['showroom-dark.png', null, 'dark'],
  ['showroom-ember-dark.png', 'ember', 'dark'],
  ['showroom-fjord-light.png', 'fjord', 'light'],
]
const SETTLE_MS = 600 // past the button's 120 ms colour transition after a skin or focus change
const RING = 9 // the focus ring reaches 8px past a control; the next button starts 10px away

const url = (skin, scheme) => `${pathToFileURL(join(outDir, 'index.html'))}#${new URLSearchParams({ ...(skin ? { skin } : {}), scheme })}`

async function open(browser, skin, scheme) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: scheme, deviceScaleFactor: 2 })
  await page.goto(url(skin, scheme))
  await page.waitForSelector('html[data-ready]')
  await page.waitForTimeout(SETTLE_MS)
  return page
}

mkdirSync(images, { recursive: true })
const browser = await chromium.launch()
try {
  for (const [file, skin, scheme] of PAGES) {
    const page = await open(browser, skin, scheme)
    await page.screenshot({ path: join(images, file), fullPage: true, scale: 'css' })
    await page.close()
  }
  // The focus ring on the primary and the secondary button, each reached by real Tab presses, side by side.
  for (const scheme of ['light', 'dark']) {
    const page = await open(browser, null, scheme)
    await page.focus('#part-button-title')
    const crops = []
    for (const id of ['#button-primary', '#button-secondary']) {
      await page.keyboard.press('Tab')
      await page.waitForTimeout(SETTLE_MS)
      const box = await page.locator(id).boundingBox()
      const clip = { x: box.x - RING, y: box.y - RING, width: box.width + 2 * RING, height: box.height + 2 * RING }
      crops.push((await page.screenshot({ clip })).toString('base64'))
    }
    const sheet = await browser.newPage({ deviceScaleFactor: 1 })
    await sheet.setContent(`<body style="margin:0;display:inline-flex;gap:8px;background:${scheme === 'dark' ? '#000' : '#fff'}">${crops.map((c) => `<img src="data:image/png;base64,${c}">`).join('')}</body>`)
    writeFileSync(join(images, `focus-${scheme}.png`), await sheet.locator('body').screenshot())
    await sheet.close()
    await page.close()
  }
  // The button's lights after the Surface control is set to primary: grey, "not proved on primary".
  const page = await open(browser, null, 'light')
  await page.click('label.sr-radio:has(input[name="surface"][value="primary"])')
  const head = await page.locator('#part-button .sr-part-head').boundingBox()
  await page.screenshot({ path: join(images, 'unproved-light.png'), clip: { x: head.x - 12, y: head.y - 12, width: Math.min(head.width, 900) + 24, height: head.height + 24 } })
  await page.close()
} finally {
  await browser.close()
}
console.log(`pictures: ${PAGES.length + 3} written to ${images}`)
