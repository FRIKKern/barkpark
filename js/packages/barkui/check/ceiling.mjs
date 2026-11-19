// One way a run passes its ceiling, for the check (run.mjs) and the selftest: a timer that fails the run with
// its sentence the moment the ceiling is passed, wherever the run is then (mid-part, mid-case, in a browser).
// BARKUI_CEILING_SECONDS may set a lower ceiling, so a test can show the timer firing; never a higher one.

/** Starts the timer; `said(seconds)` is the line printed when it fires. Returns the ceiling in force. */
export function enforceCeiling(seconds, said) {
  const lower = Number(process.env.BARKUI_CEILING_SECONDS)
  const ceiling = lower > 0 ? Math.min(seconds, lower) : seconds
  setTimeout(() => {
    console.log(said(ceiling))
    process.exit(1)
  }, ceiling * 1000).unref()
  return ceiling
}
