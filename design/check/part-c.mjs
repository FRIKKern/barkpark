// design/check/part-c.mjs — Part C of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { tokens, TYPE_STEPS } from "../emit.mjs";
import { fail, FAULT } from "./state.mjs";
import { studioText } from "./part-b.mjs";

// ── Part C: Studio chrome type-scale parity (Decision D2) ────────────────────
// The emitted --text-<step> / --text-<step>-lh vars in the root layout must mirror
// tokens.type.chrome exactly (size + line-height), so the styleguide type ladder —
// which renders straight off those vars — can never drift from the source scale.
console.log("\ndesign/check.mjs — Part C: Studio type-scale parity");
let typeOk = true;
for (const step of TYPE_STEPS) {
  const spec = tokens.type.chrome[step];
  const reSize = new RegExp(`--text-${step}: (\\d+(?:\\.\\d+)?)px;`);
  const reLh = new RegExp(`--text-${step}-lh: (\\d+(?:\\.\\d+)?);`);
  const mSize = studioText.match(reSize);
  const mLh = studioText.match(reLh);
  if (!mSize || Number(mSize[1]) !== spec.size) {
    fail(`  Part C FAIL: --text-${step} size ${mSize ? mSize[1] : "MISSING"} ≠ tokens.type.chrome.${step}.size ${spec.size}`);
    typeOk = false;
  }
  if (!mLh || Number(mLh[1]) !== spec.lineHeight) {
    fail(`  Part C FAIL: --text-${step}-lh ${mLh ? mLh[1] : "MISSING"} ≠ tokens.type.chrome.${step}.lineHeight ${spec.lineHeight}`);
    typeOk = false;
  }
}
if (FAULT.has("C")) { fail("  Part C FAIL: injected fault (--selftest)"); typeOk = false; }
if (typeOk)
  console.log(`  ok   ${TYPE_STEPS.length} chrome type steps emit --text-* vars matching tokens.type.chrome (size + line-height)`);
