// node build/pictures.mjs: retakes every picture the README, QUALITY.md and the
// decisions show, into docs/images/, from the built showroom, and writes their
// stamp (build/picture-stamp.mjs). Run it after `pnpm run build` and
// `pnpm run check`, so the lights in the pictures are the last run's. The
// pictures are the real page; nothing is drawn or hidden for them. Each shows
// one part's section (PICTURED), so a new part leaves them true.
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { chromium } from 'playwright'
import { PICTURED, pictureStamp, stampPath } from './picture-stamp.mjs'
import { outDir, root } from './showroom.mjs'

const images = join(root, 'docs', 'images')
const section = `#part-${PICTURED}`
// The section in a skin and scheme, as the page's address keeps them. `null` is the sheet's first skin.
const SECTIONS = [
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
  for (const [file, skin, scheme] of SECTIONS) {
    const page = await open(browser, skin, scheme)
    await page.locator(section).screenshot({ path: join(images, file), scale: 'css' })
    await page.close()
  }
  // The focus ring on the primary and the secondary button, each reached by real Tab presses, side by side.
  for (const scheme of ['light', 'dark']) {
    const page = await open(browser, null, scheme)
    await page.focus(`#part-${PICTURED}-title`)
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
  // The section's head: the part's name and its lights, as the last run left them.
  const page = await open(browser, null, 'light')
  await page.locator(`${section} .sr-part-head`).screenshot({ path: join(images, 'lights-light.png'), scale: 'css' })
  await page.close()
} finally {
  await browser.close()
}
writeFileSync(stampPath, `${pictureStamp()}\n`)
console.log(`pictures: ${SECTIONS.length + 3} written to ${images}, stamp ${pictureStamp()}`)
