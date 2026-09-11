// FIXTURE — the CAUSE with no CONSEQUENCE yet.
//
// This synthetic harness carries the scaffy `console-tests` zone anchor ABOVE
// its LAST depth-0 `await`, which is exactly the drift the anchor assertion
// exists to catch. Nothing planted here reads a late binding, so the CROSSING
// arm is silent and `crossings: 0`. That silence is the point: a guard that
// only counted crossings would certify this file green while every future
// group planted at the anchor lands above a live suspension point.
import test from "node:test";

const EARLY_FIXTURE = 1;

await import("node:os");

// scaffy:zone console-tests (ensure-console-hook-zones) -- stable TAIL anchor
// Sweeps: move this comment only whole, on its own lines. MARK:zone-console-tests

test("reads only an early binding, so there is no crossing to find", () => {
  if (EARLY_FIXTURE !== 1) throw new Error("unreachable");
});

await import("node:path");

const LATE_FIXTURE = 2;

export { LATE_FIXTURE };
