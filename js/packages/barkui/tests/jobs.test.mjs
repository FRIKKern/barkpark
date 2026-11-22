import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { discoverParts } from '../build/parts.mjs'
import { ceilingFor, PER_JOB, STEP_MINUTES } from '../check/capacity.mjs'
import { reportFile, selftestReport } from '../check/selftest-report.mjs'
import { AGGREGATE, cover, folderNames, JOBS, judge, SELFTEST_ALL, legGroup, materialize, NO_PARTS, partNames, partsDir, planMatrix, MOST_GROUPS, MOST_PARTS, SELFTEST_JOBS, split } from '../check/jobs.mjs'

const scratch = mkdtempSync(join(tmpdir(), 'barkui-jobs-test-'))
afterAll(() => rmSync(scratch, { recursive: true, force: true }))
const folderOf = (n, tag = `n${n}`) => {
  const d = join(scratch, tag)
  mkdirSync(d)
  for (let i = 0; i < n; i++) mkdirSync(join(d, `p${String(i).padStart(2, '0')}`))
  return d
}
const flat = (groups) => groups.flatMap((g) => (typeof g.parts === 'string' ? g.parts.split(',') : g.parts))

// The selftest jobs' reports, as they are when the jobs ran every case once and each held (check/selftest-report.mjs):
// one case to a job, and one more in the first.
const CASE_IDS = ['c0', ...SELFTEST_JOBS.map((j, i) => `c${i + 1}`)]
const selftestOk = (sha) =>
  SELFTEST_JOBS.map((j, i) => {
    const ran = i === 0 ? CASE_IDS.slice(0, 2) : [CASE_IDS[i + 1]]
    return { file: reportFile(j.key), data: selftestReport({ key: j.key, sha, all: CASE_IDS, ran, held: ran, count: { held: ran.length, of: ran.length } }) }
  })

describe('the job split covers every part folder exactly once', () => {
  it('every real part folder is in exactly one group, and the set is the folder counted another way', () => {
    const counted = readdirSync(partsDir).filter((n) => !n.startsWith('.') && statSync(join(partsDir, n)).isDirectory())
    expect(counted.length).toBeGreaterThan(0)
    const names = partNames(partsDir, {})
    expect(names.length).toBe(counted.length)
    const run = flat(planMatrix(partsDir, {}))
    expect(run.length).toBe(counted.length)
    expect(new Set(run).size).toBe(run.length)
    expect([...run].sort()).toEqual([...counted].sort())
  })

  it('the cover check refuses a split that leaves a part out, runs one twice, overfills a job or runs a stranger', () => {
    const names = Array.from({ length: 9 }, (_, i) => `x${i}`)
    const good = split(names, 4)
    expect(cover(good, names, 4)).toEqual([])
    const dropLast = good.map((g, i) => (i === good.length - 1 ? { ...g, parts: g.parts.slice(0, -1) } : g))
    expect(cover(dropLast, names, 4)).toEqual(['parts/x8: no job runs it'])
    const twice = good.map((g, i) => (i === good.length - 1 ? { ...g, parts: [...g.parts, 'x0'] } : g))
    expect(cover(twice, names, 4)).toEqual([`parts/x0: groups 1 and ${good.length} both run it`])
    expect(cover([{ group: 1, parts: names }], names, 4)).toEqual(['group 1 holds 9 parts, more than one job holds (4)'])
    expect(cover([...good, { group: 9, parts: ['ghost'] }], names, 4)).toEqual(['group 9 runs ghost, which is no part folder'])
    expect(cover([...good, { group: 9, parts: [] }], names, 4)).toEqual(['group 9 runs nothing'])
  })

  it('the plan, a job and the closing check split alike for 0 to 40 folders, and none is a refusal with its own sentence', () => {
    for (let n = 0; n <= 40; n++) {
      const dir = folderOf(n)
      if (n === 0) {
        expect(() => planMatrix(dir, {})).toThrow(NO_PARTS)
        expect(() => legGroup(1, '', dir, {})).toThrow(NO_PARTS)
        const v = judge({ needs: needsWith('[]'), reports: [], names: partNames(dir, {}), sha: 's' })
        expect(v.ok).toBe(false)
        expect(v.rows.join('\n')).toContain(NO_PARTS)
        continue
      }
      const m = planMatrix(dir, {})
      expect(m.length, `n=${n}`).toBe(Math.ceil(n / PER_JOB))
      const sizes = m.map((g) => g.parts.split(',').length)
      expect(Math.max(...sizes) - Math.min(...sizes), `n=${n}`).toBeLessThanOrEqual(1)
      expect(Math.max(...sizes)).toBeLessThanOrEqual(PER_JOB)
      for (const g of m) expect(legGroup(g.group, g.parts, dir, {}).parts.join(','), `n=${n} group ${g.group}`).toBe(g.parts)
      expect(() => legGroup(1, `${m[0].parts},extra`, dir, {})).toThrow(/the plan gave group 1/)
      expect(() => legGroup(m.length + 1, '', dir, {})).toThrow(/is not in this checkout's split/)
      const reports = [...m.map((g) => ({ file: `${g.group}.json`, data: { group: g.group, of: g.of, parts: g.parts.split(','), sha: 's', ok: true } })), ...selftestOk('s')]
      expect(judge({ needs: needsWith(JSON.stringify(m)), reports, names: partNames(dir, {}), sha: 's' }).ok, `n=${n}`).toBe(true)
    }
  })
})

describe('more parts than the folder holds, made as copies under a test-only root', () => {
  // Every count of proof copies here comes from the one limit, MOST_PARTS in check/jobs.mjs, less the real parts,
  // so the tests hold for every number of real parts the limit allows (tests/counts.mjs walks them).
  const top = MOST_PARTS - folderNames(partsDir).length

  it(`the most copies of the button the knob takes beside the real parts (${top}) are real parts, each its own bytes, split into jobs that each hold under the step`, () => {
    const env = { BARKUI_PROOF_COPIES: String(top) }
    const root = materialize(partsDir, env, scratch)
    expect(root.startsWith(scratch)).toBe(top > 0)
    const real = folderNames(partsDir)
    const names = partNames(partsDir, env)
    expect(names.length).toBe(real.length + top)
    expect(folderNames(root)).toEqual(names)
    const parts = discoverParts(root)
    expect(parts.map((p) => p.name)).toEqual(names)
    expect(new Set(parts.map((p) => p.hash)).size).toBe(parts.length)
    const groups = split(names)
    expect(groups.length).toBe(Math.ceil(names.length / PER_JOB))
    expect(cover(groups, names)).toEqual([])
    for (const g of groups) {
      expect(g.parts.length).toBeLessThanOrEqual(PER_JOB)
      expect(ceilingFor(g.parts.length)).toBeLessThan(STEP_MINUTES * 60)
    }
  })

  it('the proof knob can only add parts: every real part stays in a group for every value it takes, and other values refuse', () => {
    const real = folderNames(partsDir)
    const alone = split(real).length
    for (const v of [undefined, '', '0', String(Math.floor(top / 2)), String(top)]) {
      const env = v === undefined ? {} : { BARKUI_PROOF_COPIES: v }
      const names = partNames(partsDir, env)
      for (const r of real) expect(names, `value ${v}`).toContain(r)
      const groups = split(names)
      expect(groups.length).toBeGreaterThanOrEqual(alone)
      for (const r of real) expect(groups.filter((g) => g.parts.includes(r)).length, `${r} with ${v}`).toBe(1)
      expect(materialize(partsDir, env, scratch) === partsDir, `value ${v}`).toBe(!Number(v))
    }
    for (const v of ['-1', 'abc', '1.5', String(top + 1), ' 3', '1e2']) expect(() => partNames(partsDir, { BARKUI_PROOF_COPIES: v }), v).toThrow(/BARKUI_PROOF_COPIES must be/)
  })

  it(`the knob at its top makes exactly MOST_GROUPS (${MOST_GROUPS}) groups, and a folder past MOST_PARTS refuses with the way out the file it names holds`, () => {
    expect(split(partNames(partsDir, { BARKUI_PROOF_COPIES: String(top) })).length).toBe(MOST_GROUPS)
    expect(split(partNames(folderOf(MOST_PARTS, 'at-most'), {})).length).toBe(MOST_GROUPS)
    expect(() => partNames(folderOf(MOST_PARTS + 1, 'past-most'), {})).toThrow(/raise MOST_GROUPS in check\/jobs.mjs .*docs\/PARTS\.md/)
    // The file the refusal names exists and holds the way out, so the pointer cannot go stale.
    let said = ''
    try { partNames(folderOf(MOST_PARTS + 1, 'past-most-2'), {}) } catch (e) { said = e.message }
    const named = said.match(/as js\/packages\/barkui\/(\S+) says/)?.[1]
    expect(named).toBeTruthy()
    const text = readFileSync(new URL(`../${named}`, import.meta.url), 'utf8').replace(/\s+/g, ' ')
    expect(text).toContain(`Past ${MOST_PARTS} parts the plan job refuses, red, and names the fix: raise \`MOST_GROUPS\``)
  })
})

// The closing check's rows. Nine parts, four to a job: three groups, the last one (x6, x7, x8) planted red below.
const NAMES = Array.from({ length: 9 }, (_, i) => `x${i}`)
const GROUPS = split(NAMES, 4)
const MATRIX = JSON.stringify(GROUPS.map((g) => ({ group: g.group, of: g.of, parts: g.parts.join(',') })))
function needsWith(groups, over = {}) {
  return {
    [JOBS.plan]: { result: 'success', outputs: { run: 'true', groups } },
    [JOBS.check]: { result: 'success', outputs: {} },
    ...Object.fromEntries(SELFTEST_JOBS.map((j) => [j.id, { result: 'success', outputs: {} }])),
    ...over,
  }
}
const groupReports = () => GROUPS.map((g) => ({ file: `group-${g.group}.json`, data: { group: g.group, of: g.of, parts: g.parts, sha: 'abc', ok: true } }))
const goodReports = () => [...groupReports(), ...selftestOk('abc')]
const verdict = (needs, reports = goodReports()) => judge({ needs, reports, names: NAMES, sha: 'abc', perJob: 4 })
const redWith = (v, re) => v.ok === false && v.rows.some((r) => r.startsWith('RED ') && re.test(r))
const withLast = (fn) => [...groupReports().map((r, i, all) => (i === all.length - 1 ? fn(r) : r)), ...selftestOk('abc')]

describe(`the closing check, "${AGGREGATE}"`, () => {
  it('refuses an empty or missing commit id, even when every job and report would be green against it', () => {
    const blank = (r) => ({ ...r, data: { ...r.data, sha: '' } })
    for (const sha of ['', ' ', undefined, null]) {
      const v = judge({ needs: needsWith(MATRIX), reports: goodReports().map(blank), names: NAMES, sha, perJob: 4 })
      expect(redWith(v, /no commit id/), JSON.stringify(sha)).toBe(true)
    }
  })

  it('is green when the plan, every group and every selftest job passed, and names them', () => {
    const v = verdict(needsWith(MATRIX))
    expect(SELFTEST_ALL).toBe(`the ${SELFTEST_JOBS.length} selftest jobs`)
    expect(v).toEqual({ ok: true, rows: [`green: 3 group(s) of 9 part(s), each checked once at abc, and the ${SELFTEST_JOBS.length} selftest jobs passed, running each of ${CASE_IDS.length} cases once`] })
  })

  it('is red for a red, cancelled, skipped-by-mistake or missing group job, even when every report says ok', () => {
    expect(redWith(verdict(needsWith(MATRIX, { [JOBS.check]: { result: 'failure' } })), /the check jobs is red/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX, { [JOBS.check]: { result: 'cancelled' } })), /the check jobs was cancelled/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX, { [JOBS.check]: { result: 'skipped' } })), /the check jobs were skipped by mistake/)).toBe(true)
    const gone = needsWith(MATRIX)
    delete gone[JOBS.check]
    expect(redWith(verdict(gone), /the check jobs is missing from this run/)).toBe(true)
  })

  it('is red for any selftest job red, cancelled, skipped by mistake or missing, by its name', () => {
    expect(SELFTEST_JOBS.length).toBe(3)
    for (const j of SELFTEST_JOBS) {
      const who = `the selftest job "${j.name}"`
      for (const [result, said] of [['failure', 'is red'], ['cancelled', 'was cancelled'], ['skipped', 'was skipped by mistake']])
        expect(verdict(needsWith(MATRIX, { [j.id]: { result } })).rows, `${j.id} ${result}`).toContain(`RED ${who} ${said}${result === 'skipped' ? ': the plan said BarkUI was touched' : ''}`)
      const gone = needsWith(MATRIX)
      delete gone[j.id]
      expect(verdict(gone).rows, `${j.id} missing`).toContain(`RED ${who} is missing from this run`)
    }
  })

  // The layers job, one test per way it can end (SELFTEST_JOBS's third job, "BarkUI selftest, top layer").
  const LAYERS = SELFTEST_JOBS.find((j) => j.key === 'layers')
  const layersSay = (needs) => verdict(needs).rows.filter((r) => r.includes(`"${LAYERS.name}"`))
  it('is red when the layers job is red', () => {
    expect(layersSay(needsWith(MATRIX, { [LAYERS.id]: { result: 'failure' } }))).toEqual([`RED the selftest job "${LAYERS.name}" is red`])
  })
  it('is red when the layers job was cancelled', () => {
    expect(layersSay(needsWith(MATRIX, { [LAYERS.id]: { result: 'cancelled' } }))).toEqual([`RED the selftest job "${LAYERS.name}" was cancelled`])
  })
  it('is red when the layers job is missing from the run', () => {
    const gone = needsWith(MATRIX)
    delete gone[LAYERS.id]
    expect(layersSay(gone)).toEqual([`RED the selftest job "${LAYERS.name}" is missing from this run`])
  })
  it('is red when the layers job was skipped while the plan said BarkUI was touched', () => {
    expect(layersSay(needsWith(MATRIX, { [LAYERS.id]: { result: 'skipped' } }))).toEqual([`RED the selftest job "${LAYERS.name}" was skipped by mistake: the plan said BarkUI was touched`])
  })
  it('is green with the layers job skipped when the plan said BarkUI was not touched, and red when it ran then', () => {
    const skipped = { [JOBS.check]: { result: 'skipped' }, ...Object.fromEntries(SELFTEST_JOBS.map((j) => [j.id, { result: 'skipped' }])) }
    const plan = { [JOBS.plan]: { result: 'success', outputs: { run: 'false', groups: MATRIX } } }
    expect(verdict(needsWith(MATRIX, { ...skipped, ...plan }), []).ok).toBe(true)
    expect(verdict(needsWith(MATRIX, { ...skipped, ...plan, [LAYERS.id]: { result: 'success' } }), []).rows.some((r) => r.includes(`"${LAYERS.name}"`) && r.includes('though the plan said BarkUI was not touched'))).toBe(true)
  })

  it('a plan job that failed, was cancelled, was skipped or is missing is red, never read as "not touched"', () => {
    for (const result of ['failure', 'cancelled', 'skipped'])
      expect(redWith(verdict(needsWith(MATRIX, { [JOBS.plan]: { result, outputs: { run: 'false' } } }), []), /the plan job .*never read as "not touched"/), result).toBe(true)
    const gone = needsWith(MATRIX)
    delete gone[JOBS.plan]
    expect(redWith(verdict(gone, []), /the plan job is missing.*never read as "not touched"/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX, { [JOBS.plan]: { result: 'success', outputs: { run: '', groups: MATRIX } } })), /neither "true" nor "false"/)).toBe(true)
  })

  it('"not touched" is green only with the groups and every selftest job skipped', () => {
    const skipped = { [JOBS.check]: { result: 'skipped' }, ...Object.fromEntries(SELFTEST_JOBS.map((j) => [j.id, { result: 'skipped' }])) }
    const plan = { result: 'success', outputs: { run: 'false', groups: MATRIX } }
    expect(verdict(needsWith(MATRIX, { ...skipped, [JOBS.plan]: plan }), [])).toEqual({ ok: true, rows: [`green: the plan said BarkUI was not touched, and the check jobs and the ${SELFTEST_JOBS.length} selftest jobs were skipped`] })
    for (const j of SELFTEST_JOBS) expect(redWith(verdict(needsWith(MATRIX, { ...skipped, [JOBS.plan]: plan, [j.id]: { result: 'success' } }), []), /though the plan said BarkUI was not touched/), j.id).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX, { ...skipped, [JOBS.plan]: plan, [JOBS.check]: { result: 'failure' } }), []), /the check jobs is red, though the plan said BarkUI was not touched/)).toBe(true)
  })

  it('a planted failing part in the last group turns it red, named, while the others pass', () => {
    const v = verdict(needsWith(MATRIX, { [JOBS.check]: { result: 'failure' } }), withLast((r) => ({ ...r, data: { ...r.data, ok: false } })))
    expect(v.ok).toBe(false)
    expect(v.rows).toContain('RED group 3 of 3 (x6, x7, x8) is red')
    expect(v.rows.filter((r) => /group [12] /.test(r))).toEqual([])
  })

  it('a group with no report, a report from another commit or naming other parts, or two reports, is missing or red', () => {
    expect(redWith(verdict(needsWith(MATRIX), [...groupReports().slice(0, -1), ...selftestOk('abc')]), /group 3 of 3 \(x6, x7, x8\) is missing: no report/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX), withLast((r) => ({ ...r, data: { ...r.data, sha: 'old' } }))), /group 3 of 3 .* is missing: its report is from commit old, not abc/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX), withLast((r) => ({ ...r, data: { ...r.data, parts: ['x7'] } }))), /group 3 of 3 .* is missing: its report names \["x7"\]/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX), [...goodReports(), goodReports()[2]]), /group 3 of 3 .* reported 2 times/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX), [...goodReports(), { file: 'x.json', data: { group: 4, parts: [], sha: 'abc', ok: true } }]), /a report for group 4, which this checkout's split does not have/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX), [...goodReports(), { file: 'bad.json', error: 'Unexpected token' }]), /report bad.json cannot be read/)).toBe(true)
    expect(redWith(verdict(needsWith(MATRIX), []), /group 1 of 3 .* is missing: no report/)).toBe(true)
  })

  it("a plan whose groups differ from this checkout's split is red", () => {
    expect(redWith(verdict(needsWith(JSON.stringify([{ group: 1, of: 1, parts: NAMES.join(',') }]))), /the plan's groups .* differ from this checkout's split/)).toBe(true)
  })

  it('decides by one rule over every combination of results: nothing else is green', () => {
    const results = ['success', 'failure', 'cancelled', 'skipped', 'missing']
    const legs = [JOBS.check, ...SELFTEST_JOBS.map((j) => j.id)]
    // Every way the legs can end: results to the power of the legs.
    const ways = legs.reduce((all) => all.flatMap((w) => results.map((r) => [...w, r])), [[]])
    let greens = 0
    let rows = 0
    for (const plan of results)
      for (const run of ['true', 'false'])
        for (const way of ways) {
          const needs = {}
          if (plan !== 'missing') needs[JOBS.plan] = { result: plan, outputs: plan === 'success' ? { run, groups: MATRIX } : {} }
          legs.forEach((id, i) => way[i] !== 'missing' && (needs[id] = { result: way[i] }))
          const touched = plan === 'success' && run === 'true' && way.every((r) => r === 'success')
          const untouched = plan === 'success' && run === 'false' && way.every((r) => r === 'skipped')
          const v = verdict(needs)
          const at = JSON.stringify({ plan, run, way })
          expect(v.ok, at).toBe(touched || untouched)
          if (!v.ok) expect(v.rows.length && v.rows.every((r) => r.startsWith('RED ')), at).toBe(true)
          greens += v.ok ? 1 : 0
          rows++
        }
    expect([rows, greens]).toEqual([results.length * 2 * results.length ** legs.length, 2])
  })
})
