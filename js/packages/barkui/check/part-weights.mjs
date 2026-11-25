// Each part's weight in the job split (check/jobs.mjs, split): its seconds on CI's hosted runner, as one run's check
// jobs printed them ("time: <s> s of its … limit"), all from the one run named here. The split deals the heaviest
// parts out first, one to each group before any group takes a second (docs/PARTS.md says the rule). A part
// with no reading here (a new part, a proof copy) weighs as much as the heaviest reading, so it is dealt out among the
// first and never piles onto a loaded job; its PR's hosted run gives it its reading, and the readings are taken again
// together, from one run. A test holds that every name here is a part folder.
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

/** A part's weight: its reading in `readings`, or the heaviest reading there when it has none (0 when there is none). */
export const weightOf = (name, readings = PART_READINGS.seconds) => readings[name] ?? Math.max(0, ...Object.values(readings))
