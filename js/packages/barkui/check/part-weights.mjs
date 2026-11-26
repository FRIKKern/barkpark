// Each part's weight in the job split (check/jobs.mjs, split, and startOrder): its seconds on CI's hosted runner, as
// one run's check jobs printed them ("time: <s> s of its … limit"), all from the one run named here. The split deals
// the heaviest parts out first, one to each group before any group takes a second (docs/PARTS.md says the rule). A
// part with no reading here (a new part, a proof copy) weighs the median reading, as a typical part does, so it never
// ties the heaviest and the heaviest readings still go one to a group. Nothing writes a reading: the plan job names
// each part folder with none (`node check/jobs.mjs --matrix`, on its log), and its reading is written here by hand
// from a hosted run's time: line. A test holds that every name here is a part folder.
export const PART_READINGS = {
  run: 45710017441,
  commit: '95d70b715d',
  jobs: [139541882340, 139541882323, 139541882344],
  seconds: {
    button: 154.2,
    checkbox: 132.9,
    dialog: 157.4,
    menu: 150.0,
    'password-input': 126.3,
    radio: 249.0,
    'segmented-control': 146.4,
    select: 232.7,
    slider: 117.4,
    switch: 181.7,
    tabs: 163.6,
    'text-field': 158.5,
    textarea: 113.0,
  },
}

/** The middle of a list of numbers (the mean of the two middle ones for an even count); 0 for none. */
const median = (xs) => {
  if (!xs.length) return 0
  const s = [...xs].sort((a, b) => a - b)
  const m = Math.floor(s.length / 2)
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2
}

/** A part's weight: its reading in `readings`, or the median reading there when it has none. */
export const weightOf = (name, readings = PART_READINGS.seconds) => readings[name] ?? median(Object.values(readings))

/** The names among `names` that have no reading. */
export const unreadOf = (names, readings = PART_READINGS.seconds) => names.filter((n) => !Object.hasOwn(readings, n))

/** The readings that name no folder among `folders`. */
export const staleOf = (folders, readings = PART_READINGS.seconds) => Object.keys(readings).filter((n) => !folders.includes(n))
