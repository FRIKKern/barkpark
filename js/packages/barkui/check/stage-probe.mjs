// Throwaway: select's phone light alone, on pages that print different stages beside it.
import { runCheck } from './check.mjs'
for (const stages of process.argv.slice(2)) {
  process.env.BARKUI_PROBE_STAGES = stages
  const lines = []
  const t = performance.now()
  const { ok } = await runCheck({ names: ['select'], only: ['phone'], surfaces: false, motion: false, states: false, log: (l) => lines.push(l) })
  console.log(`stage-probe: stages ${stages}, ${((performance.now() - t) / 1000).toFixed(1)} s, ok ${ok}`)
  for (const l of lines) if (/phone:|  views|error/.test(l)) console.log(`  ${l}`)
}
process.exit(0)
