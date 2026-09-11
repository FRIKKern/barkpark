// FIXTURE — the same file with the anchor where it belongs.
//
// Byte-for-byte the sibling of zone-anchor-above.mjs except that the zone
// comment sits BELOW the last depth-0 `await`. It is the control: if the
// anchor assertion reds here too, it is not measuring position, it is just
// reacting to the marker's presence.
import test from "node:test";

const EARLY_FIXTURE = 1;

await import("node:os");

test("reads only an early binding, so there is no crossing to find", () => {
  if (EARLY_FIXTURE !== 1) throw new Error("unreachable");
});

await import("node:path");

const LATE_FIXTURE = 2;

// scaffy:zone console-tests (ensure-console-hook-zones) -- stable TAIL anchor
// Sweeps: move this comment only whole, on its own lines. MARK:zone-console-tests

export { LATE_FIXTURE };
