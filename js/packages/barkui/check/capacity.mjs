// How many parts one CI check job holds, from ceilings made from readings. A reading is one job's whole run on
// CI's hosted runner: how many parts it checked, how many were in the folder (every job builds and loads the
// whole page), how long, which run, at which commit. A ceiling is HEADROOM times the slowest reading for that
// number of parts; a number of parts no one has read there is scaled linearly from the largest number that has
// been (never from a guess or from a run on a loaded machine). The check (run.mjs) and the selftest stop, failing
// with their sentences, the moment a run passes its ceiling (ceiling.mjs). A job given more parts than PER_JOB
// refuses to run at all; check/jobs.mjs splits the folder into groups of at most PER_JOB. README.md's passage on this is made here (capacityPassage), between
// two markers, and a test holds it word for word; `node check/capacity.mjs` writes it. When another part lands,
// its hosted reading goes in READINGS and every number moves by measurement.
import { readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

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
  READINGS: {
    // One reading per job. The four with 14 in the folder are proof run (a): the real button and 13 copies of it.
    check: [
      { parts: 1, folder: 1, seconds: 135, run: 44623848758, commit: 'ddb4ba55b6' },
      { parts: 4, folder: 14, seconds: 430, run: 44642580444, commit: 'fa14e54128' },
      { parts: 4, folder: 14, seconds: 432, run: 44642580444, commit: 'fa14e54128' },
      { parts: 3, folder: 14, seconds: 252, run: 44642580444, commit: 'fa14e54128' },
      { parts: 3, folder: 14, seconds: 211, run: 44642580444, commit: 'fa14e54128' },
    ],
    selftest: { seconds: 308, run: 44623848758, commit: 'ddb4ba55b6' },
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
  const folder = Math.max(...i.READINGS.check.map((r) => r.folder))
  return { ...i, largest, ceilingFor, PER_JOB: held, FOLDER_READ: folder, SELFTEST_CEILING: Math.ceil(i.HEADROOM * i.READINGS.selftest.seconds) }
}

const share = (secs, minutes) => Math.round((secs / (minutes * 60)) * 100)
const parts = (n) => `${n} part${n === 1 ? '' : 's'}`
const pct = (x) => `${Math.round(x * 100)}%`

export const capacitySentence = (p = plan()) =>
  `On CI's hosted runner one job of the check took ${p.largest.seconds} s for ${parts(p.largest.parts)}, with ${parts(p.largest.folder)} in the folder; a job may take at most ${p.HEADROOM} times its reading, scaled linearly past the most parts read (${Math.round((p.HEADROOM * p.largest.seconds) / p.largest.parts)} s a part), and stops, failing, once it passes that, so one job's ${p.STEP_MINUTES}-minute check step in CI holds ${parts(p.PER_JOB)}, whose ceiling of ${p.ceilingFor(p.PER_JOB)} s is ${share(p.ceilingFor(p.PER_JOB), p.STEP_MINUTES)}% of it.`

export const selftestSentence = (p = plan()) =>
  `On CI's hosted runner the selftest took ${p.READINGS.selftest.seconds} s; it may take at most ${p.HEADROOM} times that, ${p.SELFTEST_CEILING} s, ${share(p.SELFTEST_CEILING, p.SELFTEST_STEP_MINUTES)}% of its ${p.SELFTEST_STEP_MINUTES}-minute step in CI, and stops, failing, once it passes that.`

export const MARKS = ['<!-- capacity: made by check/capacity.mjs; run `node check/capacity.mjs` to write it -->', '<!-- /capacity -->']

/** README.md's whole passage on capacity (and the PR's), every number from `p`. */
export function capacityPassage(p = plan()) {
  const read = (r) => `run ${r.run} at ${r.commit}`
  return [
    `${capacitySentence(p)} The ceilings are made from readings (\`check/capacity.mjs\`): each is one job's whole run on CI's hosted runner, and each ceiling is ${p.HEADROOM} times the slowest reading for its number of parts. The readings: the check, ${p.READINGS.check.map((r) => `${parts(r.parts)} of ${r.folder} in ${r.seconds} s (${read(r)})`).join('; ')}; the selftest, ${p.READINGS.selftest.seconds} s (${read(p.READINGS.selftest)}). A job checks ${p.AT_ONCE} parts at a time. A run stops, failing with its sentence, the moment it passes its ceiling, wherever it is then (\`check/ceiling.mjs\`, one timer for the check and the selftest; \`BARKUI_CEILING_SECONDS\` can lower a ceiling, down to 0 s, for a test, never raise it). Given more than ${parts(p.PER_JOB)}, a job refuses to run, naming that sentence, before any light is read. When a part lands, its hosted reading goes into \`check/capacity.mjs\` and the numbers move by measurement; a test holds the steps' minutes to \`barkui.yml\`, the ceiling of ${parts(p.PER_JOB)} under the check step and of one more over it, and this passage word for word.`,
    '',
    `In CI the check runs as jobs side by side. \`check/jobs.mjs\` splits the sorted part folders into the fewest groups of at most ${parts(p.PER_JOB)}, their sizes within one of each other, and the job matrix in \`barkui.yml\` reads that list; no list is written by hand. The plan, each job and the closing check compute the split again from the same checkout and must agree. Every job builds and loads the whole page, and the readings above were taken with at most ${parts(p.FOLDER_READ)} in the folder: with more, a job's ceiling stays where it is, so a page that makes it slower fails the job instead of stretching it. One closing check (its name is \`AGGREGATE\` in \`check/jobs.mjs\`) always runs and is red when the plan, any group or the selftest is red, cancelled, missing, or skipped while the plan said BarkUI was touched.`,
    '',
    `The selftest copies one part, so its time does not grow with the parts folder. ${selftestSentence(p)} Its ceiling stays at or under ${pct(p.SELFTEST_MOST)} of its step; a selftest that outgrows that is split across jobs, never given a longer step.`,
  ].join('\n')
}

const P = plan()
export const { AT_ONCE, STEP_MINUTES, SELFTEST_STEP_MINUTES, SELFTEST_MOST, HEADROOM, READINGS, ceilingFor, PER_JOB, FOLDER_READ, SELFTEST_CEILING } = P

// node check/capacity.mjs: writes the passage into README.md between its marks, and prints it.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = new URL('../README.md', import.meta.url)
  const s = readFileSync(file, 'utf8')
  const [a, b] = [s.indexOf(MARKS[0]), s.indexOf(MARKS[1])]
  if (a < 0 || b < a) throw new Error('README.md lacks the capacity marks')
  writeFileSync(file, `${s.slice(0, a + MARKS[0].length)}\n${capacityPassage()}\n${s.slice(b)}`)
  console.log(capacityPassage())
}
