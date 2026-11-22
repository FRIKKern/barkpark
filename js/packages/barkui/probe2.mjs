// TEMPORARY probe on a throwaway branch: which page change makes the hosted text reading pass.
const { runCheck } = await import('./check/check.mjs')
const variants = [
  ['as-is', ''],
  ['select hidden', '[data-part="select"] { display: none !important; }'],
  ['select +0.5px', '[data-part="select"] { margin-bottom: 0.5px !important; }'],
  ['select +0.25px', '[data-part="select"] { margin-bottom: 0.25px !important; }'],
  ['select +0.75px', '[data-part="select"] { margin-bottom: 0.75px !important; }'],
]
for (const [tag, plantCss] of variants) {
  const lines = []
  const r = await runCheck({ names: ['text-field', 'select'], only: ['pressed', 'phone'], surfaces: false, motion: false, states: false, plantCss, log: (s) => lines.push(String(s)) })
  console.log(`=== ${tag}: ${r.ok ? 'PASS' : 'FAIL'}`)
  for (const l of lines) if (/OFF|on  |part\(s\)/.test(l)) console.log(l.slice(0, 260))
}
const { chromium } = await import('playwright')
const b = await chromium.launch({ args: ['--disable-lcd-text'] })
const p = await b.newPage({ viewport: { width: 1440, height: 900 } })
await p.goto(new URL('dist/showroom/index.html', `file://${process.cwd()}/`).href)
await p.waitForSelector('html[data-ready]')
console.log(JSON.stringify(await p.evaluate(() => ['button', 'select', 'tabs', 'text-field'].map((n) => { const st = document.querySelector(`[data-part="${n}"]`); const r = st.getBoundingClientRect(); const l = st.querySelector('[data-demo-label]').getBoundingClientRect(); return [n, r.top + scrollY, r.height, l.top + scrollY] }))))
await b.close()
