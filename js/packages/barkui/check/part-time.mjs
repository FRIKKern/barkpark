// A part's seconds against its time limit (PART_MS in check/check.mjs). Each part's lines carry its own, and the
// run's last lines name every part that used more than NEAR of its limit, so a part that nears its limit is named on
// a green run, before a slower runner or a later part takes it over.

/** The share of its limit past which a part is named. */
export const NEAR = 2 / 3

const secs = (ms) => (ms / 1000).toFixed(1)

/** One part's line: its seconds against its limit, and whether it used more than NEAR of it. Every number in it is
    written "<n> s", so the selftest's line-for-line compares (check/page-cases.mjs, lightLines) read past it. */
export const timeLine = (ms, limitMs) =>
  `time: ${secs(ms)} s of its ${limitMs / 1000} s limit${ms > NEAR * limitMs ? ', more than two thirds of it' : ''}`

/** The run's line: every part (`times`, { name: ms }) that used more than NEAR of its limit, by name and seconds,
    slowest first, or that none did. */
export function nearLine(times, limitMs) {
  const near = Object.entries(times).filter(([, ms]) => ms > NEAR * limitMs).sort((a, b) => b[1] - a[1])
  return near.length
    ? `time: ${near.length} part(s) used more than two thirds of the ${limitMs / 1000} s limit: ${near.map(([n, ms]) => `${n} ${secs(ms)} s`).join(', ')}`
    : `time: no part used more than two thirds of the ${limitMs / 1000} s limit`
}
