// What each selftest job tells the closing check, and how the closing check reads the two reports together. A job
// writes the cases it ran and the cases that held, by name, the count it printed, and its checkout's whole case
// list. The closing check (check/jobs.mjs, judge) is red, naming the cases, unless the jobs together ran every case
// of that list exactly once and each report agrees with itself. A case's name is its id; a fast test holds the names
// unique (tests/selftest-jobs.test.mjs).

/** The file a selftest job writes its report to, by its key. */
export const reportFile = (key) => `selftest-${key}.json`

/** A selftest job's report. `count` is what the run printed: "selftest: <held> of <of> cases held". */
export const selftestReport = ({ key, sha, all, ran, held, count }) => ({ selftest: key, sha, all, ran, held, count })

const names = (a) => Array.isArray(a) && a.every((n) => typeof n === 'string')

/** What is wrong with the selftest jobs' reports (`jobs` as SELFTEST_JOBS names them), in plain words, and how many
    cases they ran once each. Rows are empty when every case of the list ran in exactly one job and held there. */
export function readSelftestReports(reports, { sha, jobs }) {
  const rows = []
  const mine = reports.filter((r) => !r.error && r.file.startsWith('selftest-'))
  for (const r of mine) if (!jobs.some((j) => r.file === reportFile(j.key))) rows.push(`a selftest report ${r.file}, which names no selftest job`)
  const read = []
  for (const j of jobs) {
    const who = `the selftest job "${j.name}"`
    const d = mine.find((x) => x.file === reportFile(j.key))?.data
    if (!d) rows.push(`${who} left no report`)
    else if (d.selftest !== j.key) rows.push(`${who}'s report ${reportFile(j.key)} says it is the selftest job ${JSON.stringify(d.selftest)}`)
    else if (d.sha !== sha) rows.push(`${who}'s report is from commit ${d.sha}, not ${sha}`)
    else if (!names(d.all) || !names(d.ran) || !names(d.held)) rows.push(`${who}'s report does not list its cases by name`)
    else {
      if (d.count?.of !== d.ran.length || d.count?.held !== d.held.length)
        rows.push(`${who} said ${d.count?.held} of ${d.count?.of} cases held, but its report lists ${d.held.length} held of ${d.ran.length} run`)
      for (const n of d.ran) if (!d.held.includes(n)) rows.push(`selftest case "${n}" did not hold in ${who}`)
      for (const n of d.held) if (!d.ran.includes(n)) rows.push(`${who} says "${n}" held, but it did not run it`)
      read.push([j.key, d])
    }
  }
  if (read.length !== jobs.length) return { rows, cases: 0 }
  const all = read[0][1].all
  if (read.some(([, d]) => d.all.join('\n') !== all.join('\n'))) return { rows: [...rows, "the selftest jobs' reports name different case lists, so they are not from one checkout"], cases: 0 }
  for (const n of all) {
    const by = read.flatMap(([k, d]) => d.ran.filter((x) => x === n).map(() => k))
    if (!by.length) rows.push(`selftest case "${n}" ran in no selftest job`)
    else if (by.length > 1) rows.push(`selftest case "${n}" ran ${by.length} times, in the ${[...new Set(by)].join(' and ')} job${new Set(by).size > 1 ? 's' : ''}`)
  }
  for (const [k, d] of read) for (const n of d.ran) if (!all.includes(n)) rows.push(`the ${k} job ran "${n}", which is no selftest case`)
  return { rows, cases: all.length }
}
