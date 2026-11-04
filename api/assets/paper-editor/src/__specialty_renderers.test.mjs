// Portable fallback behavior for specialty renderers. Canonical fixtures and
// projection/round-trip integration live in the sibling host test.

import assert from "node:assert/strict";
import { runToTiptap } from "./canvas/run-convert.js";
import { fleetChipLabel } from "./canvas/embed-node.js";

const TYPES = [
  "api-endpoint",
  "bar-chart",
  "code-tabs",
  "criteria-progress",
  "gauge-list",
  "route",
];

assert.equal(
  runToTiptap([{ id: "unknown", type: "not-a-specialty" }]).content[0].type,
  "bpOpaque",
  "unknown blocks remain honestly missing",
);

assert.deepEqual(
  // fleetChipLabel reads only `type`; these inputs are equivalent to the
  // canonical blocks while keeping this portable check fixture-independent.
  TYPES.map((type) => fleetChipLabel({ type })),
  ["API endpoint", "Bar chart", "Code tabs", "Criteria progress", "Gauge list", "Route"],
  "pre-paint fallbacks name every specialty block",
);

console.log("specialty renderers: portable fallbacks passed");
