import { readdirSync, readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { PER_JOB } from '../check/capacity.mjs'
import { AGGREGATE, folderNames, JOBS, NAMES, partNames, partsDir, MOST_GROUPS, MOST_PARTS, split } from '../check/jobs.mjs'

const repo = (p) => new URL(`../../../../${p}`, import.meta.url)
const wf = readFileSync(repo('.github/workflows/barkui.yml'), 'utf8')
const job = (id) => {
  const at = wf.indexOf(`\n  ${id}:\n`)
  expect(at, id).toBeGreaterThan(0)
  const rest = wf.slice(at + 1)
  const next = rest.slice(1).search(/\n {2}[\w-]+:\n/)
  return next < 0 ? rest : rest.slice(0, next + 1)
}
const LEG_TEMPLATE = NAMES.group('${{ matrix.group }}')

describe('barkui.yml runs the split it is given and closes on one name', () => {
  it('has no paths filter on its triggers, so the closing name renders on every head', () => {
    const on = wf.slice(wf.indexOf('\non:\n'), wf.indexOf('\nconcurrency:'))
    expect(on).toContain('pull_request:')
    expect(on).toContain('push:')
    expect(on).not.toMatch(/paths/)
  })

  it(`names the closing check "${AGGREGATE}" once, always runs it, and has it read the plan, every group and the selftest`, () => {
    expect(wf.split('\n').filter((l) => l.includes(AGGREGATE))).toEqual([`    name: "${AGGREGATE}"`])
    const close = job('barkui')
    expect(close).toContain(`name: "${AGGREGATE}"`)
    expect(close).toContain(`needs: [${JOBS.plan}, ${JOBS.check}, ${JOBS.selftest}]`)
    expect(close).toMatch(/\n {4}if: always\(\)\n/)
    expect(close).toContain('NEEDS: ${{ toJSON(needs) }}')
    expect(close).toContain('node check/jobs.mjs --judge')
  })

  it('makes the list in a plan job that installs nothing, and runs each group from it, with no list written by hand', () => {
    const plan = job(JOBS.plan)
    expect(plan).toContain(`name: "${NAMES.plan}"`)
    expect(plan).not.toMatch(/\n {4}(if|needs):/)
    expect(plan).not.toMatch(/pnpm install|action-setup|npm ci|npm install|playwright install|cache:/)
    expect(plan).toContain('groups: ${{ steps.split.outputs.groups }}')
    expect(plan).toContain('groups=$(node packages/barkui/check/jobs.mjs --matrix)')
    expect(plan).toContain('\\.github/workflows/barkui\\.yml$')
    const check = job(JOBS.check)
    expect(check).toContain(`name: "${LEG_TEMPLATE}"`)
    expect(check).toContain(`include: \${{ fromJSON(needs.${JOBS.plan}.outputs.groups) }}`)
    expect(check).toContain('fail-fast: false')
    expect(check).toContain(`if: needs.${JOBS.plan}.outputs.run == 'true'`)
    expect(check).toContain('node check/run.mjs --group "$GROUP" --parts "$PARTS" --report')
    const self = job(JOBS.selftest)
    expect(self).toContain(`name: "${NAMES.selftest}"`)
    expect(self).toContain(`if: needs.${JOBS.plan}.outputs.run == 'true'`)
  })

  it('js-tests.yml no longer runs BarkUI', () => {
    const js = readFileSync(repo('.github/workflows/js-tests.yml'), 'utf8')
    expect(js).not.toMatch(/check\/run\.mjs|check:selftest|run check\b|BarkUI: did this change/)
  })

  it('the final head carries no proof copies and no planted break', () => {
    expect(wf).not.toContain('BARKUI_PROOF')
    const dir = new URL('../check/', import.meta.url)
    for (const f of readdirSync(dir)) expect(readFileSync(new URL(f, dir), 'utf8'), f).not.toContain('PROOF BREAK')
  })
})

describe('every name barkui.yml can render has a row in .github/required-checks.json, and none is required', () => {
  const spec = JSON.parse(readFileSync(repo('.github/required-checks.json'), 'utf8'))
  const required = new Set((spec.protection?.required_status_checks?.checks ?? []).map((c) => c.context))
  const rows = new Set([...required, ...spec.exclusions.map((e) => e.context)])
  // The most groups the split can make: every real part plus the most proof copies the knob takes.
  const most = split(partNames(partsDir, { BARKUI_PROOF_COPIES: String(MOST_PARTS - folderNames().length) })).length
  const groupRows = [...rows].filter((r) => /^BarkUI check, group \d+$/.test(r))
  const groupNames = (n) => Array.from({ length: n }, (_, i) => NAMES.group(i + 1))
  const missing = (names) => names.filter((n) => !rows.has(n))

  it('the group names the split can make, counted another way, each have a row', () => {
    expect(most).toBeGreaterThan(0)
    expect(most).toBe(MOST_GROUPS)
    expect(missing(groupNames(most))).toEqual([])
  })

  it('the group rows are exactly groups 1 to MOST_GROUPS: a row more or a row less than that number is red', () => {
    expect(groupRows.sort()).toEqual(groupNames(MOST_GROUPS).sort())
  })

  it("docs/PARTS.md's line on outgrowing the rows names MOST_GROUPS and MOST_PARTS as they are", () => {
    const readme = readFileSync(new URL('../docs/PARTS.md', import.meta.url), 'utf8').replace(/\s+/g, ' ')
    expect(readme).toContain(`The check runs at most ${MOST_GROUPS} groups (\`MOST_GROUPS\` in \`check/jobs.mjs\`), so at most ${MOST_PARTS} parts`)
    expect(readme).toContain(`one row for each of groups 1 to ${MOST_GROUPS};`)
    expect(readme).toContain(`Past ${MOST_PARTS} parts the plan job refuses`)
  })

  it('the plan, the selftest, the closing check and the skipped-matrix template each have a row', () => {
    expect(missing([NAMES.plan, NAMES.selftest, AGGREGATE, LEG_TEMPLATE])).toEqual([])
  })

  it('none of them is required: branch protection stays as it is', () => {
    for (const n of [NAMES.plan, NAMES.selftest, AGGREGATE, LEG_TEMPLATE, ...groupNames(most)]) expect(required.has(n), n).toBe(false)
  })

  it('one group more than the rows cover is found: the check is red the day the knob or the folder would make it', () => {
    const rowsFor = groupRows.length
    const more = split(Array.from({ length: rowsFor * PER_JOB + 1 }, (_, i) => `p${i}`)).length
    expect(more).toBe(rowsFor + 1)
    expect(missing(groupNames(more))).toEqual([NAMES.group(rowsFor + 1)])
  })
})
