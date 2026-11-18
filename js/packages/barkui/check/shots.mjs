// node check/shots.mjs <dir>: light and dark shots of the built showroom, 1440 wide.
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
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: scheme })
    await page.goto(`${pathToFileURL(join(outDir, 'index.html'))}#scheme=${scheme}`)
    await page.waitForSelector('html[data-ready]')
    await page.screenshot({ path: join(dir, `showroom-${scheme}.png`), fullPage: true })
    await page.close()
  }
} finally {
  await browser.close()
}
console.log(`shots in ${dir}`)
