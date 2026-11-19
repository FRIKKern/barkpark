// node check/run.mjs: the showroom check over parts/. Exits non-zero when a part
// folder is incomplete, a press step fails, a light stays off, the page logs an
// error or asks the network, anything runs past its time limit, or the whole run
// passes its ceiling (check/capacity.mjs, check/ceiling.mjs).
import { readdirSync } from 'node:fs'
import { partsDir } from '../build/parts.mjs'
import { capacitySentence, ceilingFor } from './capacity.mjs'
import { enforceCeiling } from './ceiling.mjs'
import { runCheck } from './check.mjs'

const parts = readdirSync(partsDir, { withFileTypes: true }).filter((e) => e.isDirectory() && !e.name.startsWith('.')).length
enforceCeiling(
  ceilingFor(parts),
  (s) => `check: FAIL the run passed its ceiling of ${s} s for ${parts} part(s). ${capacitySentence()} Read the run again on CI's runner and put the reading in check/capacity.mjs, or split the check.`,
)
const { ok } = await runCheck()
process.exit(ok ? 0 : 1)
