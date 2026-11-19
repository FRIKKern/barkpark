// node check/run.mjs: the showroom check over parts/. Exits non-zero when a part
// folder is incomplete, a press step fails, a light stays off, the page logs an
// error or asks the network, anything runs past its time limit, or the whole run
// passes its ceiling (check/capacity.mjs).
import { readdirSync } from 'node:fs'
import { partsDir } from '../build/parts.mjs'
import { capacitySentence, ceilingFor } from './capacity.mjs'
import { runCheck } from './check.mjs'

const parts = readdirSync(partsDir, { withFileTypes: true }).filter((e) => e.isDirectory() && !e.name.startsWith('.')).length
const ceiling = ceilingFor(parts)
setTimeout(() => {
  console.log(`check: FAIL the run passed its ceiling of ${ceiling} s for ${parts} part(s). ${capacitySentence()} Measure again, then change the ceilings in check/capacity.mjs and, if the step must grow, its limit in js-tests.yml together, or split the check.`)
  process.exit(1)
}, ceiling * 1000).unref()
const { ok } = await runCheck()
process.exit(ok ? 0 : 1)
