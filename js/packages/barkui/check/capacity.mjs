// How many parts one CI check step holds, from ceilings: the most a run may take, which the check enforces.
// The check runs AT_ONCE parts at a time in one browser, so its time grows with each batch of AT_ONCE parts.
// A run of the check stops, failing with capacitySentence, once it passes the ceiling for its parts
// (check/run.mjs); the selftest stops, failing with selftestSentence, once it passes its own. Each ceiling sits
// under its step's limit in js-tests.yml, so the check's own words come before CI cuts it off. When the parts
// folder holds more than PARTS_HELD, the check refuses to run at all. A test holds each step's minutes to its
// limit in js-tests.yml, and the README to both sentences. The times the ceilings were set over are stated
// with the change that sets them, not here: a ceiling is what is enforced.

// How many parts run at once: small and fixed, so this machine and the hosted runner both hold.
export const AT_ONCE = 3
// The check step's limit in .github/workflows/js-tests.yml.
export const STEP_MINUTES = 15
// Seconds: the most the first batch of AT_ONCE parts may take (with the build and the browser's start), and
// the most each further batch may add.
export const CEILING = { firstBatch: 240, eachBatch: 300 }

/** The most a run over `n` parts may take, in seconds. */
export const ceilingFor = (n) => CEILING.firstBatch + CEILING.eachBatch * Math.max(0, Math.ceil(n / AT_ONCE) - 1)
/** The most parts whose ceiling fits in the step. */
export const PARTS_HELD = AT_ONCE * (1 + Math.floor((STEP_MINUTES * 60 - CEILING.firstBatch) / CEILING.eachBatch))
const share = (secs, minutes) => Math.round((secs / (minutes * 60)) * 100)

export const capacitySentence = () =>
  `The check runs ${AT_ONCE} parts at a time; a run may take at most ${CEILING.firstBatch} s for the first ${AT_ONCE} and ${CEILING.eachBatch} s more for each further ${AT_ONCE}, and stops, failing, once it passes that, so the ${STEP_MINUTES}-minute check step in CI holds ${PARTS_HELD} parts, whose ceiling of ${ceilingFor(PARTS_HELD)} s is ${share(ceilingFor(PARTS_HELD), STEP_MINUTES)}% of it.`

// The selftest's step. It copies one part, so its time does not grow with the parts folder, only with its own
// cases.
export const SELFTEST_STEP_MINUTES = 12
export const SELFTEST_CEILING = 540

export const selftestSentence = () =>
  `The selftest may take at most ${SELFTEST_CEILING} s, ${share(SELFTEST_CEILING, SELFTEST_STEP_MINUTES)}% of its ${SELFTEST_STEP_MINUTES}-minute step in CI, and stops, failing, once it passes that.`
