// The fast tests hold for every number of real parts the showroom allows, from one up to MOST_PARTS
// (check/jobs.mjs). Each count gets a scratch copy of this package, at its place in a mirror of the repo, whose
// parts/ holds that many real parts: the button and copies of it. One child vitest then runs
// every other test file in every copy. The tests run as they are written, so one that counts parts by hand turns
// red at the count it breaks.
import { spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, describe, expect, it } from 'vitest'
import { copyAs } from '../check/copy.mjs'
import { MOST_PARTS } from '../check/jobs.mjs'

const pkg = fileURLToPath(new URL('..', import.meta.url))
const repoRoot = join(pkg, '..', '..', '..')
const below = relative(repoRoot, pkg)
const self = fileURLToPath(import.meta.url)

const scratch = mkdtempSync(join(tmpdir(), 'barkui-part-counts-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))

/** A folder whose entries are links to `from`'s entries, but for `except`, which the caller fills. */
function mirror(from, to, except) {
  mkdirSync(to, { recursive: true })
  for (const e of readdirSync(from)) if (e !== except) symlinkSync(realpathSync(join(from, e)), join(to, e))
}

/** The repo as the tests see it, with this package a copy whose parts/ holds `n` real parts. Everything else is a
    link to the real file, so whatever the code reads from the repo it reads as it is. */
function copyWith(n) {
  const root = join(scratch, `n${String(n).padStart(2, '0')}`)
  const steps = below.split(sep)
  steps.forEach((step, i) => mirror(join(repoRoot, ...steps.slice(0, i)), join(root, ...steps.slice(0, i)), step))
  const at = join(root, below)
  cpSync(pkg, at, { recursive: true, filter: (src) => ![join(pkg, 'node_modules'), join(pkg, 'parts'), self].includes(src) })
  mirror(join(pkg, 'node_modules'), join(at, 'node_modules'))
  cpSync(join(pkg, 'parts', 'button'), join(at, 'parts', 'button'), { recursive: true })
  for (let i = 2; i <= n; i++) copyAs(join(at, 'parts', 'button'), `grown${String(i).padStart(2, '0')}-button`)
  return root
}

describe('the fast tests, for every number of real parts from one up to MOST_PARTS', () => {
  it(`hold at each count from 1 to ${MOST_PARTS}`, () => {
    const roots = Array.from({ length: MOST_PARTS }, (_, i) => copyWith(i + 1))
    const config = join(scratch, 'vitest.config.mjs')
    writeFileSync(config, `export default { test: { environment: 'node', include: [${JSON.stringify(`n*/${below.split(sep).join('/')}/tests/*.test.mjs`)}] } }\n`)
    const out = join(scratch, 'results.json')
    const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('VITEST')))
    const run = spawnSync(process.execPath, [join(pkg, 'node_modules', 'vitest', 'vitest.mjs'), 'run', '--root', scratch, '--config', config, '--reporter=json', `--outputFile=${out}`], { env, encoding: 'utf8' })
    expect(existsSync(out), run.stderr.slice(-2000)).toBe(true)
    const { testResults } = JSON.parse(readFileSync(out, 'utf8'))
    const ran = new Set(testResults.map((r) => relative(scratch, r.name).split(sep)[0]))
    expect(ran.size, 'every copy ran').toBe(roots.length)
    const red = testResults.flatMap((r) =>
      r.assertionResults.filter((a) => a.status !== 'passed').map((a) => `${relative(scratch, r.name).split(sep)[0]} ${r.name.split(sep).at(-1)}: ${a.fullName}: ${(a.failureMessages?.[0] ?? '').split('\n')[0].slice(0, 300)}`),
    )
    expect(red, 'red at these counts').toEqual([])
    expect(run.status).toBe(0)
  }, 600_000)
})
