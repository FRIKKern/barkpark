// TEMPORARY probe on a throwaway branch: what the boundary reader sees on the open list.
const { runCheck } = await import('./check/check.mjs')
for (let i = 0; i < 2; i++) {
  const lines = []
  const r = await runCheck({ names: ['button', 'select', 'tabs', 'text-field'], only: ['pressed', 'phone', 'skins', 'schemes'], surfaces: true, motion: false, states: false, log: (s) => lines.push(String(s)) })
  console.log(`=== try ${i}: ${r.ok ? 'PASS' : 'FAIL'}`)
  for (const l of lines) if (/OFF|on  |DBG/.test(l)) console.log(l.slice(0, 1500))
}
