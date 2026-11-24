// node check/shots.mjs <dir>: light and dark shots of the built showroom, 1440
// wide: the button's stage on every surface, stacked, one picture per scheme
// (surfaces-light.png, surfaces-dark.png). The pictures these pages show (the
// whole page, the focus ring, a light not proved) are taken by build/pictures.mjs.
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { SURFACES } from '../build/page.mjs'
import { outDir } from '../build/showroom.mjs'
import { launch } from './acts.mjs'

const dir = process.argv[2]
if (!dir) throw new Error('usage: node check/shots.mjs <dir>')
mkdirSync(dir, { recursive: true })
const browser = await launch()
try {
  for (const scheme of ['light', 'dark']) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: scheme, deviceScaleFactor: 2 })
    await page.goto(`${pathToFileURL(join(outDir, 'index.html'))}#scheme=${scheme}`)
    await page.waitForSelector('html[data-ready]')
    const sheet = await browser.newPage({ deviceScaleFactor: 1, colorScheme: scheme })
    const rows = []
    for (const surface of SURFACES) {
      await page.evaluate((v) => document.querySelector('[data-part="button"]').setAttribute('data-surface', v), surface)
      await page.waitForTimeout(250)
      // The whole stage and a margin round it, so the surface's own edge (the sunken rim) shows on every side.
      const clip = await page.evaluate(() => {
        const stage = document.querySelector('[data-part="button"]').getBoundingClientRect()
        return { x: stage.x + window.scrollX - 8, y: stage.y + window.scrollY - 8, width: stage.width + 16, height: stage.height + 16 }
      })
      rows.push([surface, `data:image/png;base64,${(await page.screenshot({ clip, fullPage: true })).toString('base64')}`])
    }
    const ground = scheme === 'dark' ? '#000' : '#fff'
    const ink = scheme === 'dark' ? '#9a9a9a' : '#5f5f5f'
    await sheet.setContent(`<body style="margin:0;padding:32px;display:inline-flex;flex-direction:column;gap:16px;background:${ground};color:${ink};font:26px system-ui">${rows.map(([n, c]) => `<div>${n}</div><img src="${c}">`).join('')}</body>`)
    await sheet.locator('body').screenshot({ path: join(dir, `surfaces-${scheme}.png`) })
    await page.close()
    await sheet.close()
  }
} finally {
  await browser.close()
}
console.log(`shots in ${dir}`)
