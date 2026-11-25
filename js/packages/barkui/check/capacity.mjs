// How many parts one CI check job holds, from ceilings made from readings. A reading is one job's whole run on
// CI's hosted runner: how many parts it checked, how many were in the folder (the job then read its parts on the page of
// every part's stage), how long, which run, at which commit. A ceiling is HEADROOM times the slowest reading for that
// number of parts; a number of parts no one has read there is scaled linearly from the largest number that has
// been (never from a guess or from a run on a loaded machine). The check (run.mjs) and the selftest stop, failing
// with their sentences, the moment a run passes its ceiling (ceiling.mjs). A job given more parts than PER_JOB
// refuses to run at all; check/jobs.mjs splits the folder into groups of at most PER_JOB. docs/PARTS.md's passage on this is made here (capacityPassage), between
// two markers, and a test holds it word for word; `node check/capacity.mjs` writes it. When another part lands,
// its hosted reading goes in READINGS and every number moves by measurement.
import { readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { PART_READINGS } from './part-weights.mjs'

export const INPUT = {
  // How many parts run at once: small and fixed, so this machine and the hosted runner both hold.
  AT_ONCE: 3,
  // The steps' limits in .github/workflows/barkui.yml. A check that outgrows a job is split across more jobs,
  // and so is a selftest that outgrows its ceiling; no step grows.
  STEP_MINUTES: 15,
  SELFTEST_STEP_MINUTES: 10,
  // The share of its step the selftest's ceiling may take at most.
  SELFTEST_MOST: 0.8,
  // The one headroom rule: a ceiling is this many times its reading.
  HEADROOM: 1.5,
  // The one limit every selftest case runs under (check/selftest.mjs stops a case that passes it, failing), and
  // the share of it a case's hosted reading may take at most, so a slower runner does not push a case over.
  // A case that outgrows the share is unfolded into runs; neither number moves, and no case carries its own.
  CASE_SECONDS: 60,
  CASE_SHARE: 0.8,
  // The selftest's ceilings that stand, in seconds, by job. A reading may never make a job's ceiling higher than
  // the one that stands: a job whose reading would is split (check/jobs.mjs, selftestJob), and a job split off
  // another (`from` below) stands under the ceiling of the job it came from. A test holds every reading to this.
  SELFTEST_STANDS: { views: 315, rest: 252, layers: 218 },
  READINGS: {
    // One reading per job. Those with 14 in the folder are proof runs (a) and (b): the real button and 13 copies of
    // it; from (b), only the two groups without its planted break.
    check: [
      { parts: 1, folder: 1, seconds: 135, run: 44623848758, commit: 'ddb4ba55b6' },
      { parts: 4, folder: 14, seconds: 430, run: 44642580444, commit: 'fa14e54128' },
      { parts: 4, folder: 14, seconds: 432, run: 44642580444, commit: 'fa14e54128' },
      { parts: 3, folder: 14, seconds: 252, run: 44642580444, commit: 'fa14e54128' },
      { parts: 3, folder: 14, seconds: 211, run: 44642580444, commit: 'fa14e54128' },
      { parts: 5, folder: 14, seconds: 570, run: 44662694458, commit: 'd9d277ad73' },
      { parts: 5, folder: 14, seconds: 567, run: 44662694458, commit: 'd9d277ad73' },
    ],
    // One reading per selftest job (check/jobs.mjs, SELFTEST_JOBS): that job's whole run, as it printed it
    // ("selftest: N of N cases held, in S s"), with the job it came from.
    selftest: {
      views: { seconds: 201, job: 137754186448, run: 45192291440, commit: 'ff599196ef' },
      rest: { seconds: 63, job: 137754186506, run: 45192291440, commit: 'ff599196ef' },
      layers: { seconds: 133, job: 137754186372, run: 45192291440, commit: 'ff599196ef' },
      // Jobs split off another (`from`): each stands under the ceiling of the job it came from.
      surfaces: { seconds: 185, from: 'views', job: 137754186425, run: 45192291440, commit: 'ff599196ef' },
      states: { seconds: 137, from: 'rest', job: 137754186267, run: 45192291440, commit: 'ff599196ef' },
      open: { seconds: 108, from: 'layers', job: 137754186386, run: 45192291440, commit: 'ff599196ef' },
    },
  },
}

/** Every number that follows from the input. */
export function plan(i = INPUT) {
  const slower = (a, r) => (r.parts > a.parts || (r.parts === a.parts && r.seconds > a.seconds) ? r : a)
  const largest = i.READINGS.check.reduce(slower)
  const exact = (n) => i.READINGS.check.filter((r) => r.parts === n).reduce((a, r) => Math.max(a, r.seconds), 0)
  const projected = (n) => exact(n) || (largest.seconds * n) / largest.parts
  const ceilingFor = (n) => Math.ceil(i.HEADROOM * projected(n))
  let held = 0
  while (ceilingFor(held + 1) < i.STEP_MINUTES * 60) held++
  const SELFTEST_CEILINGS = Object.fromEntries(Object.entries(i.READINGS.selftest).map(([k, r]) => [k, Math.ceil(i.HEADROOM * r.seconds)]))
  return { ...i, largest, ceilingFor, PER_JOB: held, SELFTEST_CEILINGS }
}

/** What is wrong with the selftest's readings against the ceilings that stand, each by its job; empty when no
    reading makes a job's ceiling higher than the one that stands (SELFTEST_STANDS, or for a job split off another,
    the ceiling that stands for the job it came from). */
export function ceilingsRaised(p = plan()) {
  const top = (k, seen = []) => p.SELFTEST_STANDS[k] ?? (p.READINGS.selftest[k]?.from && !seen.includes(k) ? top(p.READINGS.selftest[k].from, [...seen, k]) : undefined)
  const wrong = []
  for (const [k, r] of Object.entries(p.READINGS.selftest)) {
    const t = top(k)
    if (t === undefined) wrong.push(`the selftest's ${k} job has no ceiling that stands and was split off no job that has one (check/capacity.mjs, SELFTEST_STANDS)`)
    else if (p.SELFTEST_CEILINGS[k] > t) wrong.push(`the selftest's ${k} job's reading of ${r.seconds} s (job ${r.job}) makes its ceiling ${p.SELFTEST_CEILINGS[k]} s, higher than the ${t} s that stands: split the job (check/jobs.mjs), never raise a ceiling`)
  }
  return wrong
}

const share = (secs, minutes) => Math.round((secs / (minutes * 60)) * 100)
const parts = (n) => `${n} part${n === 1 ? '' : 's'}`
const pct = (x) => `${Math.round(x * 100)}%`

export const capacitySentence = (p = plan()) =>
  `On CI's hosted runner one job of the check took ${p.largest.seconds} s for ${parts(p.largest.parts)}, with ${parts(p.largest.folder)} in the folder; a job may take at most ${p.HEADROOM} times its reading, scaled linearly past the most parts read (${Math.round((p.HEADROOM * p.largest.seconds) / p.largest.parts)} s a part), and stops, failing, once it passes that, so one job's ${p.STEP_MINUTES}-minute check step in CI holds ${parts(p.PER_JOB)}, whose ceiling of ${p.ceilingFor(p.PER_JOB)} s is ${share(p.ceilingFor(p.PER_JOB), p.STEP_MINUTES)}% of it.`

/** The sentence for one selftest job (`key`, as SELFTEST_JOBS in check/jobs.mjs names it). */
export const selftestSentence = (key, p = plan()) =>
  `On CI's hosted runner ${p.READINGS.selftest[key].within ? `the cases of the selftest's ${key} job ran inside the ${p.READINGS.selftest[key].within} job's run of ${p.READINGS.selftest[key].seconds} s, before they were split off` : `the selftest's ${key} job took ${p.READINGS.selftest[key].seconds} s`}; it may take at most ${p.HEADROOM} times that, ${p.SELFTEST_CEILINGS[key]} s, ${share(p.SELFTEST_CEILINGS[key], p.SELFTEST_STEP_MINUTES)}% of its ${p.SELFTEST_STEP_MINUTES}-minute step in CI, and stops, failing, once it passes that.`

export const MARKS = ['<!-- capacity: made by check/capacity.mjs; run `node check/capacity.mjs` to write it -->', '<!-- /capacity -->']

/** docs/PARTS.md's whole passage on capacity (and the PR's), every number from `p`. */
export function capacityPassage(p = plan()) {
  const read = (r) => `${r.job ? `job ${r.job} of ` : ''}run ${r.run} at ${r.commit}`
  return [
    `${capacitySentence(p)} The ceilings are made from readings (\`check/capacity.mjs\`): each is one job's whole run on CI's hosted runner, and each ceiling is ${p.HEADROOM} times the slowest reading for its number of parts. The readings: the check, ${p.READINGS.check.map((r) => `${parts(r.parts)} of ${r.folder} in ${r.seconds} s (${read(r)})`).join('; ')}; the selftest, ${Object.entries(p.READINGS.selftest).map(([k, r]) => `its ${k} job in ${r.seconds} s (${read(r)})`).join(' and ')}. A job checks ${p.AT_ONCE} parts at a time. A run stops, failing with its sentence, the moment it passes its ceiling, wherever it is then (\`check/ceiling.mjs\`, one timer for the check and the selftest; \`BARKUI_CEILING_SECONDS\` can lower a ceiling, down to 0 s, for a test, never raise it). Given more than ${parts(p.PER_JOB)}, a job refuses to run, naming that sentence, before any light is read. When a part lands, its hosted reading goes into \`check/capacity.mjs\` and the numbers move by measurement; a test holds the steps' minutes to \`barkui.yml\`, the ceiling of ${parts(p.PER_JOB)} under the check step and of one more over it, and this passage word for word.`,
    '',
    `In CI the check runs as jobs side by side. \`check/jobs.mjs\` splits the part folders into the fewest groups of at most ${parts(p.PER_JOB)}, their sizes within one of each other, and the job matrix in \`barkui.yml\` reads that list; no list is written by hand. The heaviest parts are spread apart: each part weighs its seconds on CI's hosted runner in one run (\`check/part-weights.mjs\`, run ${PART_READINGS.run}), a part with no reading weighs as much as the heaviest, and the parts are dealt out heaviest first (equal weights by name), each to the lightest group by summed weight among those that hold the fewest parts so far (equal loads: the lower group number), each group listing its parts in name order. So the heaviest parts go one to a group before any group takes a second, and a part with no reading is dealt out among the first. The plan, each job and the closing check compute the split again from the same checkout and must agree. Every job builds the page of every part folder, so each folder builds and every id is unique page-wide, and then presses and reads its own parts on a page that prints its group's stages, and the stage that follows each of them there, and loads that page's \`barkui.css\`, every part's sheet, so each part wears every rule it wears on the page of every part and has what follows it there, and a part's time does not grow with the folder. Each part is read on a copy of that page whose other stages carry \`hidden\` but the one that follows it (\`check/part-page.mjs\`): every stage's elements still connect and its demo runs, and only the part's own stage and the one after it are drawn, so a part's time does not grow with the stages beside it; each part's lines give its seconds against its limit, and the job's last lines name every part that used more than two thirds of it. A job's ceiling stays where it is whatever the folder holds. One closing check (its name is \`AGGREGATE\` in \`check/jobs.mjs\`) always runs and is red when the plan, any group or any selftest job is red, cancelled, missing, or skipped while the plan said BarkUI was touched.`,
    '',
    `The selftest copies one part, so its time does not grow with the parts folder. It runs as ${Object.keys(p.READINGS.selftest).length} jobs side by side, and one rule in \`check/jobs.mjs\` (\`selftestJob\`) puts each case in exactly one: the \`views\` job runs the cases that read the wide or phone views and drive no states, direct readings among them, but for those that read every surface, which the \`surfaces\` job runs; the \`layers\` job the other direct readings and the top layer's cases but for the named boxes read open, which the \`open\` job runs; the \`states\` job the states cases that bring a sheet or a part of their own; the \`rest\` job every other case. A test holds that the jobs together run every case, each once. ${Object.keys(p.READINGS.selftest).map((k) => selftestSentence(k, p)).join(' ')} Each ceiling stays at or under ${pct(p.SELFTEST_MOST)} of its step, and no reading makes a job's ceiling higher than the one that stands (${Object.entries(p.SELFTEST_STANDS).map(([k, t]) => `${k} ${t} s`).join(', ')}; a job split off another stands under the ceiling of the job it came from): a test holds each reading to it, and a job that would pass it is split again, never given a higher ceiling or a longer step. Every case runs under one limit of ${p.CASE_SECONDS} s (\`CASE_SECONDS\`), and none carries its own; each case's reading on CI's hosted runner (\`check/case-readings.mjs\`) sits under ${pct(p.CASE_SHARE)} of it, ${p.CASE_SHARE * p.CASE_SECONDS} s, and a test names any case that does not. A case that outgrows that share is unfolded into runs, each of its rows in exactly one, never given a longer limit.`,
  ].join('\n')
}

// What a selftest case may hold: these keys and no other (the runner reads each). A limit of its own is not one.
export const CASE_KEYS = ['name', 'only', 'plant', 'css', 'expect', 'direct', 'green', 'surfaces', 'motion', 'states', 'layers', 'part']

/** What is wrong with the selftest's `cases` against the one limit, each by the case's name; empty when no case
    holds a key the runner does not read (such as a limit of its own) and every case's hosted reading sits under
    CASE_SHARE of CASE_SECONDS. `readings` is check/case-readings.mjs's CASE_READINGS, one per selftest job. */
export function caseLimitsWrong(cases, readings, p = plan()) {
  const most = p.CASE_SHARE * p.CASE_SECONDS
  const read = new Map()
  for (const r of Object.values(readings)) for (const [name, seconds] of Object.entries(r.cases)) read.set(name, { seconds, job: r.job })
  const wrong = []
  for (const c of cases) {
    const other = Object.keys(c).filter((k) => !CASE_KEYS.includes(k))
    if (other.length) wrong.push(`the case "${c.name}" holds ${other.map((k) => `"${k}"`).join(', ')}, which the runner does not read; every case runs under the one limit of ${p.CASE_SECONDS} s (check/capacity.mjs), and none carries its own`)
    const r = read.get(c.name)
    if (!r) wrong.push(`the case "${c.name}" has no hosted reading in check/case-readings.mjs`)
    else if (r.seconds >= most) wrong.push(`the case "${c.name}" took ${r.seconds} s on CI's hosted runner (job ${r.job}), at or over ${pct(p.CASE_SHARE)} of the one limit of ${p.CASE_SECONDS} s (${most} s): unfold it into runs`)
  }
  const names = new Set(cases.map((c) => c.name))
  for (const name of read.keys()) if (!names.has(name)) wrong.push(`check/case-readings.mjs reads a case the selftest does not have: "${name}"`)
  return wrong
}

const P = plan()
export const { AT_ONCE, STEP_MINUTES, SELFTEST_STEP_MINUTES, SELFTEST_MOST, HEADROOM, CASE_SECONDS, CASE_SHARE, READINGS, ceilingFor, PER_JOB, SELFTEST_CEILINGS } = P

// node check/capacity.mjs: writes the passage into docs/PARTS.md between its marks, and prints it.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = new URL('../docs/PARTS.md', import.meta.url)
  const s = readFileSync(file, 'utf8')
  const [a, b] = [s.indexOf(MARKS[0]), s.indexOf(MARKS[1])]
  if (a < 0 || b < a) throw new Error('docs/PARTS.md lacks the capacity marks')
  writeFileSync(file, `${s.slice(0, a + MARKS[0].length)}\n${capacityPassage()}\n${s.slice(b)}`)
  console.log(capacityPassage())
}
