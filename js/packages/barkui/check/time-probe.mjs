// Throwaway timing probe: one part, or a few at once, at different folder sizes, in one job on one runner.
// node check/time-probe.mjs <copies>:<part,part> ...
import { runCheck } from './check.mjs'
import { materialize, partsDir, folderNames } from './jobs.mjs'
import { clockLine, clockReset } from './probe-clock.mjs'

for (const arg of process.argv.slice(2)) {
  const [copies, list] = arg.split(':')
  const names = list.split(',')
  const dir = materialize(partsDir, { BARKUI_PROOF_COPIES: copies, RUNNER_TEMP: process.env.RUNNER_TEMP })
  const folder = folderNames(dir).length
  clockReset()
  const t = performance.now()
  const lines = []
  const { ok } = await runCheck({ dir, names, log: (l) => lines.push(l) })
  const s = ((performance.now() - t) / 1000).toFixed(1)
  for (const l of lines) if (/^\S|probe/.test(l)) console.log(`  ${l}`)
  console.log(`probe: folder ${folder}, parts ${names.join('+')}, ${s} s, ok ${ok}`)
  console.log(`probe-clock: folder ${folder}, ${clockLine()}`)
}
process.exit(0)
