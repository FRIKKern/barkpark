// The selftest's rows for a job's page and its parts' time (check/check.mjs runCheck, given `names`): the job reads its
// own parts on a page that prints their stages, and the one that follows each of them, and loads every part folder's sheet, and prints each part's
// seconds against its limit and the parts that used more than two thirds of it (check/part-time.mjs).
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { partsDir } from '../build/parts.mjs'
import { PART_MS, runCheck } from './check.mjs'
import { copyAs } from './copy.mjs'

const ONLY = ['noscript']
const OTHER = 'other-button'

/** Runs a job of the parts `names` (the button alone unless named) over a folder of the button, a copy of it
    (OTHER, which follows it on the page of every part) and the copies `more`; `plant` changes the copy `at`. */
async function job(plant = () => {}, only = ONLY, more = [], at = OTHER, names = ['button']) {
  const scratch = mkdtempSync(join(tmpdir(), 'barkui-time-case-'))
  try {
    const dir = join(scratch, 'parts')
    cpSync(join(partsDir, 'button'), join(dir, 'button'), { recursive: true })
    for (const name of [OTHER, ...more]) copyAs(join(dir, 'button'), name)
    plant(join(dir, at))
    const logs = []
    const out = join(scratch, 'out')
    const { ok, proof } = await runCheck({ dir, out, proofFile: join(scratch, 'proof.json'), names, only, surfaces: false, motion: false, states: false, log: (l) => logs.push(l) })
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
    name: "a job's page prints each of its parts' stages and the one that follows each of them on the page of every part, and no other stage",
    only: ONLY,
    direct: async () => {
      // On the page of every part: aa-button, button, mm-button, other-button, zz-button. The job reads aa-button
      // and mm-button, which are not side by side there.
      const { ok, logs, html } = await job(() => {}, ONLY, ['aa-button', 'mm-button', 'zz-button'], OTHER, ['aa-button', 'mm-button'])
      const printed = (n) => html.includes(`data-part="${n}"`)
      return (
        say(`the job did not pass: ${logs.join(' | ')}`, ok) &&
        say('the page read holds no aa-button or no mm-button, the parts it reads', printed('aa-button') && printed('mm-button')) &&
        say('the page read holds no button, the stage that follows aa-button on the page of every part', printed('button')) &&
        say(`the page read holds no ${OTHER}, the stage that follows mm-button on the page of every part`, printed(OTHER)) &&
        say('the page read holds zz-button, a stage that is neither read nor follows a part read', !printed('zz-button'))
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
    name: "a job reads its parts with every part's sheet: a rule of a part outside the job that styles its stage is read",
    only: ['phone'],
    direct: async () => {
      // The rule is aa-button's, a part whose stage the job's page does not print.
      const { ok, proof, logs } = await job((d) => appendFileSync(join(d, 'part.css'), '\n[data-slot="button"] { margin-inline-start: 600px; }\n'), ['phone'], ['aa-button'], 'aa-button')
      const phone = proof?.parts?.button?.lights?.phone
      return say(`the button's phone light did not read the other part's rule: ${phone?.detail ?? logs.join(' | ')}`, !ok && phone && !phone.pass && /wide in a 390px window/.test(phone.detail))
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
