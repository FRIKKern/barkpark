// __rig_rule.test.mjs — the rigs that need the host keep the rig exit rule.
//
// Every file in this folder that looks for a browser (names BP_CHROME) is held to
// rigRuleBreaks() from paper-editor/src/__rig.mjs, the same rule
// paper-editor/src/__rig.test.mjs applies to the rigs left in the package.
//
// Run from api/assets/paper-editor: node ../paper-editor-host-tests/__rig_rule.test.mjs

import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { rigRuleBreaks } from "../paper-editor/src/__rig.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const rigs = readdirSync(HERE)
  .filter((f) => /\.m?js$/.test(f) && f !== "__rig_rule.test.mjs")
  .map((f) => ({ f, src: readFileSync(HERE + f, "utf8") }))
  .filter(({ src }) => src.includes("BP_CHROME"));
assert.ok(rigs.length >= 4, `found ${rigs.length} rigs that look for a browser; the scan is broken`);
assert.deepEqual(rigs.flatMap(({ f, src }) => rigRuleBreaks(f, src)), [], "every host rig exits through __rig.mjs");

console.log(`ok host rig exit rule: ${rigs.length} rigs use it`);
