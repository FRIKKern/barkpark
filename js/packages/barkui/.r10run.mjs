import { mkdtempSync, cpSync, appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { runCheck } from './check/check.mjs'
const plant = process.argv[2] ?? ''
const only = (process.argv[3] ?? 'pressed,skins,schemes,phone,noscript').split(',')
const s = mkdtempSync(join(tmpdir(), 'r10run-'))
cpSync('parts/button', join(s, 'parts/button'), { recursive: true })
if (plant) appendFileSync(join(s, 'parts/button/part.css'), `\n${plant}\n`)
const t = Date.now()
const lines = []
const r = await runCheck({ dir: join(s, 'parts'), out: join(s, 'out'), proofFile: join(s, 'p.json'), only, log: (l) => lines.push(l) })
console.log(lines.filter((l) => !/^  (pass|measured)/.test(l)).map((l) => l.slice(0, 400)).join('\n'))
console.log('ok', r.ok, (Date.now() - t) / 1000)
for (const [k, l] of Object.entries(r.proof?.parts?.button?.lights ?? {})) for (const f of [...new Set((l.fails ?? []).filter((x) => /real|rule/.test(x)))].slice(0, 12)) console.log(' ', k, 'F', f.slice(0, 300))
for (const st of r.proof?.parts?.button?.steps ?? []) if (!st.pass) console.log('  step', st.name, st.detail.slice(0, 300))
