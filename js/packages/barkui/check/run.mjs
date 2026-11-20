// node check/run.mjs: the showroom check over parts/. Exits non-zero when a part
// folder is incomplete, a press step fails, a light stays off, the page logs an
// error or asks the network, anything runs past its time limit, or the whole run
// passes its ceiling (check/capacity.mjs, check/ceiling.mjs).
//
// node check/run.mjs --group k --parts a,b --report file: one CI job of the check
// (check/jobs.mjs). It splits the folder again, refuses unless its group k is the
// list the plan handed it, checks only those parts on the whole page, and writes
// its report for the closing check: group, parts, commit, and whether it passed.
import { writeFileSync } from 'node:fs'
import { parseArgs } from 'node:util'
import { capacitySentence, ceilingFor } from './capacity.mjs'
import { enforceCeiling } from './ceiling.mjs'
import { runCheck } from './check.mjs'
import { folderNames, legGroup, materialize, partsDir } from './jobs.mjs'

const { values: args } = parseArgs({ options: { group: { type: 'string' }, parts: { type: 'string' }, report: { type: 'string' } } })
let group = null
let dir
try {
  if (args.group !== undefined) {
    if (!/^[1-9]\d*$/.test(args.group)) throw new Error(`jobs: --group takes a group number, not ${JSON.stringify(args.group)}`)
    group = legGroup(Number(args.group), args.parts ?? '')
  }
  dir = materialize()
} catch (e) {
  console.log(`check: ${e.message}`)
  process.exit(1)
}
const names = group ? group.parts : null
const parts = names ? names.length : folderNames(dir).length
enforceCeiling(
  ceilingFor(parts),
  (s) => `check: FAIL the run passed its ceiling of ${s} s for ${parts} part(s). ${capacitySentence()} Read the run again on CI's runner and put the reading in check/capacity.mjs, or split the check.`,
)
if (group) console.log(`check: group ${group.group} of ${group.of}: ${names.join(', ')}${dir === partsDir ? '' : ` (from ${dir})`}`)
const { ok } = await runCheck({ dir, names })
if (args.report) writeFileSync(args.report, JSON.stringify({ group: group?.group ?? null, of: group?.of ?? null, parts: names, sha: process.env.GITHUB_SHA ?? '', ok }) + '\n')
process.exit(ok ? 0 : 1)
