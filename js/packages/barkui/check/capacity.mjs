// How many parts one CI check step holds, from ceilings made from readings. A reading is a whole run on CI's
// hosted runner at this code: how many parts, how long, where, at which commit. A ceiling is HEADROOM times the
// reading for that number of parts; a number of parts no one has read there is scaled linearly from the largest
// number that has been (never from a guess or from a run on a loaded machine). The check (run.mjs) and the
// selftest stop, failing with their sentences, the moment a run passes its ceiling (ceiling.mjs). When the parts
// folder holds more than PARTS_HELD, the check refuses to run at all. A test holds each step's minutes to its
// limit in js-tests.yml, each ceiling under its step, and the README to both sentences. When another part lands,
// its hosted reading goes in READINGS and the numbers move by measurement.

// How many parts run at once: small and fixed, so this machine and the hosted runner both hold.
export const AT_ONCE = 3
// The steps' limits in .github/workflows/js-tests.yml. If the selftest outgrows its ceiling, it is split across
// jobs; its step does not grow.
export const STEP_MINUTES = 15
export const SELFTEST_STEP_MINUTES = 10
// The share of its step the selftest's ceiling may take at most.
export const SELFTEST_MOST = 0.8

export const READINGS = {
  check: [{ parts: 1, seconds: 131, where: "CI's hosted runner (js-tests)", commit: 'ddc911943f' }],
  selftest: { seconds: 301, where: "CI's hosted runner (js-tests)", commit: 'ddc911943f' },
}
// The one headroom rule: a ceiling is this many times its reading.
export const HEADROOM = 1.5

const largest = READINGS.check.reduce((a, r) => (r.parts > a.parts ? r : a))
/** Seconds a run over `n` parts takes: its reading, or the largest reading scaled linearly. */
export const projected = (n) => READINGS.check.find((r) => r.parts === n)?.seconds ?? (largest.seconds * n) / largest.parts
/** The most a run over `n` parts may take, in seconds. */
export const ceilingFor = (n) => Math.ceil(HEADROOM * projected(n))
/** The most parts whose ceiling stays under the step. */
export const PARTS_HELD = (() => {
  let n = 0
  while (ceilingFor(n + 1) < STEP_MINUTES * 60) n++
  return n
})()
export const SELFTEST_CEILING = Math.ceil(HEADROOM * READINGS.selftest.seconds)

const share = (secs, minutes) => Math.round((secs / (minutes * 60)) * 100)
const parts = (n) => `${n} part${n === 1 ? '' : 's'}`

export const capacitySentence = () =>
  `On CI's hosted runner the check took ${largest.seconds} s for ${parts(largest.parts)}; a run may take at most ${HEADROOM} times its reading, scaled linearly past the most parts read (${Math.round((HEADROOM * largest.seconds) / largest.parts)} s a part), and stops, failing, once it passes that, so the ${STEP_MINUTES}-minute check step in CI holds ${parts(PARTS_HELD)}, whose ceiling of ${ceilingFor(PARTS_HELD)} s is ${share(ceilingFor(PARTS_HELD), STEP_MINUTES)}% of it.`

export const selftestSentence = () =>
  `On CI's hosted runner the selftest took ${READINGS.selftest.seconds} s; it may take at most ${HEADROOM} times that, ${SELFTEST_CEILING} s, ${share(SELFTEST_CEILING, SELFTEST_STEP_MINUTES)}% of its ${SELFTEST_STEP_MINUTES}-minute step in CI, and stops, failing, once it passes that.`
