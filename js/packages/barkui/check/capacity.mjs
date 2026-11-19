// How many parts one CI check step holds, from measured times. The check runs
// AT_ONCE parts at a time in one browser, so its time grows with each batch of
// AT_ONCE parts. When the parts folder holds more than PARTS_HELD, the check
// refuses to run and says this sentence, so the wall is seen before CI's time
// limit is hit. A test holds STEP_MINUTES to the check step's limit in
// js-tests.yml, and the README to the sentence.

// How many parts run at once: small and fixed, so this machine and the hosted runner both hold.
export const AT_ONCE = 3
// The check step's limit in .github/workflows/js-tests.yml.
export const STEP_MINUTES = 15
// Measured on Linux in a 4-CPU, 6 GB container with copies of the button (1, 3 and 6 parts: 78 s, 97 s and
// 240 s), rounded up: the whole run with one batch of AT_ONCE parts, and what each further batch adds.
export const MEASURED = { firstBatch: 100, eachBatch: 145 }
// The share of the step limit the parts may plan on; the rest is room for a slower runner.
export const PLANNED_SHARE = 0.6

export const PARTS_HELD = AT_ONCE * (1 + Math.floor((STEP_MINUTES * 60 * PLANNED_SHARE - MEASURED.firstBatch) / MEASURED.eachBatch))

export const capacitySentence = () =>
  `The check runs ${AT_ONCE} parts at a time; on Linux with 4 CPUs the first ${AT_ONCE} take about ${MEASURED.firstBatch} s and each further ${AT_ONCE} about ${MEASURED.eachBatch} s more, so the ${STEP_MINUTES}-minute check step in CI holds ${PARTS_HELD} parts with at least ${Math.round((1 - PLANNED_SHARE) * 100)}% of its time to spare.`
