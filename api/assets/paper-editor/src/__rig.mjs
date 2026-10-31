// __rig.mjs — the exit rule every rig under src/ shares: green means it measured.
//
//   skip(what)          prints `SKIP  <what>` and returns 0, or, under
//                       BP_REQUIRE_CHROME=1 (CI, where a browser is installed
//                       on purpose), prints a FAIL line and returns 1. Use it as
//                       an exit code (`process.exit(skip(…))`) or add it to the
//                       failure count.
//   exitRig(p, f)       exits 1 on any failure, and on ZERO passes: a rig that
//                       ran no case is broken, not clean.
//
// Locally, with no browser, a SKIP still exits 0: `npm test` and the render
// scripts stay runnable on a machine that has none.

export const CHROME_REQUIRED = process.env.BP_REQUIRE_CHROME === "1";

export function skip(what) {
  console.log(`SKIP  ${what}`);
  if (!CHROME_REQUIRED) return 0;
  console.log("FAIL  BP_REQUIRE_CHROME=1, and a skipped rig is not a passing rig");
  return 1;
}

export function exitRig(passes, failures) {
  if (passes === 0) {
    console.log("FAIL  0 PASS: the rig ran no case, which is not a pass");
    process.exit(1);
  }
  process.exit(failures === 0 ? 0 : 1);
}
