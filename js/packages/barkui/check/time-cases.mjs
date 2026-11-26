// The selftest's rows for a job's page and its parts' time (check/check.mjs runCheck, given `names`): the job reads its
// own parts on a page that prints their stages, and the one that follows each of them, and loads every part folder's sheet, and prints each part's
// seconds against its limit and the parts that used more than two thirds of it (check/part-time.mjs); each part is read
// on a copy of that page whose other stages are hidden but the one that follows it (check/part-page.mjs).
import { appendFileSync, cpSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { partsDir } from '../build/parts.mjs'
import { PART_MS, runCheck } from './check.mjs'
import { copyAs } from './copy.mjs'

const ONLY = ['noscript']
const OTHER = 'other-button'

/** Runs a job of `names` (the button alone) over a folder of the button, a copy of it (OTHER, which follows it on the
    page of every part) and the copies `more`; `plant` changes the copy `at`. */
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
    name: "a job's page prints its parts' stages and the one that follows each of them on the page of every part, and no other stage",
    only: ONLY,
    direct: async () => {
      // On the page of every part: aa-button, button, other-button, zz-button. The job reads the button.
      const one = await job(() => {}, ONLY, ['aa-button', 'zz-button'])
      // On the page of every part: aa-button, ab-button, button, other-button, zz-button. The job reads aa-button and
      // the button, which are no run of neighbours there (check/jobs.mjs split): ab-button follows aa-button.
      const two = await job(() => {}, ONLY, ['aa-button', 'ab-button', 'zz-button'], OTHER, ['aa-button', 'button'])
      const printed = (r, n) => r.html.includes(`data-part="${n}"`)
      return (
        say(`the job did not pass: ${one.logs.join(' | ')}`, one.ok) &&
        say('the page read holds no button', printed(one, 'button')) &&
        say(`the page read holds no ${OTHER}, the stage that follows the button on the page of every part`, printed(one, OTHER)) &&
        say('the page read holds aa-button or zz-button, stages that neither are read nor follow a part read', !printed(one, 'aa-button') && !printed(one, 'zz-button')) &&
        say(`the job of aa-button and the button did not pass: ${two.logs.join(' | ')}`, two.ok) &&
        say('its page holds no ab-button, the stage that follows aa-button on the page of every part', printed(two, 'ab-button')) &&
        say(`its page holds no ${OTHER}, the stage that follows the button`, printed(two, OTHER)) &&
        say('its page holds zz-button, a stage that neither is read nor follows a part read', !printed(two, 'zz-button'))
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
    name: "a part is read with every other stage hidden but the one that follows it: another part's stage on the job's page draws nothing on its page",
    only: ['phone'],
    direct: async () => {
      // The job reads aa-button and the button; aa-button's stage runs past a 390px window. The page of aa-button
      // draws it; the button's page hides it.
      const wide = (d) => appendFileSync(join(d, 'example.html'), `\n<div data-demo-row><span data-demo-label>${'Wide'.repeat(60)}</span></div>\n`)
      const { ok, proof, logs } = await job(wide, ['phone'], ['aa-button'], 'aa-button', ['aa-button', 'button'])
      const phone = (n) => proof?.parts?.[n]?.lights?.phone
      return (
        say(`aa-button's phone light did not read its own stage: ${phone('aa-button')?.detail ?? logs.join(' | ')}`, !ok && phone('aa-button') && !phone('aa-button').pass && /page is \d+px wide in a 390px window/.test(phone('aa-button').detail)) &&
        say(`the button's phone light read another part's stage: ${phone('button')?.detail ?? logs.join(' | ')}`, phone('button')?.pass === true)
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
