// The selftest's rows for a job's page and its parts' time (check/check.mjs runCheck, given `names`): the job builds
// the page of every folder, then reads its own parts on a page of their folders alone, and prints each part's seconds
// against its limit and the parts that used more than two thirds of it (check/part-time.mjs).
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { partsDir } from '../build/parts.mjs'
import { PART_MS, runCheck } from './check.mjs'
import { copyAs } from './copy.mjs'

const ONLY = ['noscript']
const OTHER = 'other-button'

/** Runs a job of the button alone over a folder of the button and a copy of it; `plant` changes the copy. */
async function job(plant = () => {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-time-case-'))
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    plant(copyAs(join(dir, 'button'), OTHER))
    const logs = []
    const out = join(scratch, 'out')
    const { ok, proof } = await runCheck({ dir, out, proofFile: join(scratch, 'proof.json'), names: ['button'], only: ONLY, surfaces: false, motion: false, states: false, log: (l) => logs.push(l) })
    let html = ''
    try {
      html = readFileSync(join(out, 'index.html'), 'utf8')
    } catch {}
    return { ok, proof, logs, html }
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

const say = (what, held) => (held ? true : (console.log(`    ${what}`), false))

export const TIME_CASES = [
  {
    name: 'a job reads its parts on a page of their folders alone',
    only: ONLY,
    direct: async () => {
      const { ok, logs, html } = await job()
      return (
        say(`the job did not pass: ${logs.join(' | ')}`, ok) &&
        say('the page read holds no button', html.includes('data-part="button"')) &&
        say(`the page read holds ${OTHER}, a part the job does not read`, !html.includes(`data-part="${OTHER}"`))
      )
    },
  },
  {
    name: "a job prints each part's seconds against its limit, and names the parts over two thirds of it or that none is",
    only: ONLY,
    direct: async () => {
      const { ok, logs } = await job()
      // The button's own lines: those after its name, each set in by two spaces.
      const own = []
      for (const l of logs.slice(logs.indexOf('button') + 1)) {
        if (!l.startsWith('  ')) break
        own.push(l)
      }
      const line = new RegExp(`^  time: \\d+\\.\\d s of its ${PART_MS / 1000} s limit$`)
      return (
        say(`the job did not pass: ${logs.join(' | ')}`, ok) &&
        say(`the button's lines carry no one line of its seconds against its limit: ${own.join(' | ')}`, logs.includes('button') && own.filter((l) => line.test(l)).length === 1) &&
        say('no line names the parts over two thirds of the limit, or says none is', logs.includes(`time: no part used more than two thirds of the ${PART_MS / 1000} s limit`))
      )
    },
  },
  {
    name: 'a job still builds the page of every folder: a folder it does not read that does not build refuses the job',
    only: ONLY,
    direct: async () => {
      const { ok, proof, logs } = await job((d) => appendFileSync(join(d, 'part.css'), '\n#other-button-after { color: #ff0000; }\n'))
      return say(`the job was not refused by the folder it does not read: ${logs.join(' | ')}`, !ok && proof === null && logs.some((l) => l.includes(`parts/${OTHER}/part.css`)))
    },
  },
]
