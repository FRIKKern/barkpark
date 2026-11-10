// design/check/part-c2.mjs — Part C2 of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { LADDER_REFUSE, READING_STEPS, repoRoot, tokens, TYPE_STEPS, typeLadderFrom } from "../emit.mjs";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fail, FAULT } from "./state.mjs";

// ── Part C2: the WEB type ladder has exactly one source ──────────────────────
// Studio reads the scale through emitted CSS vars (Part C). The web demo cannot:
// its styleguide renders inline `style` objects, which need NUMBERS. For months
// that meant web/components/styleguide.tsx hand-kept its own six-step
// {size,lh,weight} array beside a comment promising a later wave would wire the
// emitted scale in — a promise that outlived the wave (au-r4-web-type-ladder).
//
// The fix was to emit the numbers (web/lib/tokens.gen.ts `chromeType` /
// `readingType`, both {size,lineHeight,weight}). This part is the gate that keeps
// it fixed, and it has TWO arms because either alone is defeatable: arm 1 asserts
// the emitted ladders equal tokens.json, arm 2 asserts the consumer restates
// nothing. A page that re-typed the same numbers would pass arm 1 forever.
console.log("\ndesign/check.mjs — Part C2: web type-ladder single source");
let webTypeOk = true;
const webTokensPath = "web/lib/tokens.gen.ts";
const styleguidePath = "web/components/styleguide.tsx";
const webTokensText = readFileSync(join(repoRoot, webTokensPath), "utf8");
const styleguideText = readFileSync(join(repoRoot, styleguidePath), "utf8");
const webTypeFail = (m) => { fail(m); webTypeOk = false; };
// arm 0 — the STEP SET the rest of this part walks is tokens.json's own ladder
// (task-039d433a1bac63ab). Arms 1 and 2 below iterate TYPE_STEPS, and for as long
// as TYPE_STEPS was a hand-written literal that made them measure the copy
// against the source IN THE DIRECTION THAT CANNOT FAIL: every entry of the copy
// was checked present in tokens.json, and a rung present in tokens.json but
// absent from the copy was walked past in silence. This arm re-derives the
// ladder from `tokens` HERE — independently of whatever list emit.mjs chose to
// build the artifacts from — and compares the two as ARRAYS, so a rung tokens
// declares and the emitter does not walk reds NAMING THAT RUNG, and a
// display-order swap reds even though the two sets are character-identical.
let chromeFromSource = null;
try {
  chromeFromSource = typeLadderFrom(tokens, "chrome");
} catch (e) {
  webTypeFail(`  Part C2 FAIL: could not derive the chrome ladder from tokens.type.chrome: ${e.message}`);
}
if (chromeFromSource) {
  // POSITIVE CONTROL: a derivation that went blind would hand back [] and every
  // comparison below would agree with an empty emitted ladder. A guard that
  // cannot see must not report a pass.
  if (chromeFromSource.length < 4)
    webTypeFail(`  Part C2 FAIL: derived only ${chromeFromSource.length} chrome step(s) from tokens.type.chrome — the derivation has gone blind`);
  for (const step of chromeFromSource)
    if (!TYPE_STEPS.includes(step))
      webTypeFail(`  Part C2 FAIL: tokens.type.chrome declares the rung "${step}", which the emitted step list (emit.mjs TYPE_STEPS) does not walk — it would be emitted nowhere and checked by nothing`);
  for (const step of TYPE_STEPS)
    if (!chromeFromSource.includes(step))
      webTypeFail(`  Part C2 FAIL: the emitted step list walks "${step}", which tokens.type.chrome does not declare as a rung`);
  if (TYPE_STEPS.length === chromeFromSource.length && TYPE_STEPS.some((s2, i) => s2 !== chromeFromSource[i]))
    webTypeFail(`  Part C2 FAIL: the emitted chrome step ORDER [${TYPE_STEPS.join(", ")}] ≠ tokens.type.chrome by descending size [${chromeFromSource.join(", ")}]`);
}
// NEGATIVE CONTROLS, in-process: each way of seeing nothing must THROW rather
// than hand back an empty ladder. Without these the refusal itself can rot and
// arm 0 quietly becomes theatre.
//
// THE FAMILIES ARE NOT WRITTEN HERE ANY MORE. They used to be a four-element
// literal in this file while web/__tests__/type-ladder-emitted.test.ts carried
// its own THREE-element one (it had no non-object arm) and design/validate.mjs'
// chromeLadderAscending had none at all — three implementations of ONE refusal
// contract with three different, drifting ideas of what must be refused. The
// list now lives once, in design/ladder-refusal-fixture.json, and all three are
// driven against it (task-833f347eaa78a2a5). The conformance table, and the two
// measured grounds on which the three are deliberately NOT one function, are in
// design/ladder-refusal-conformance.test.mjs.
const ladderFixture = JSON.parse(readFileSync(join(repoRoot, "design/ladder-refusal-fixture.json"), "utf8"));
if (ladderFixture.sentinel !== LADDER_REFUSE)
  webTypeFail(`  Part C2 FAIL: design/ladder-refusal-fixture.json declares sentinel "${ladderFixture.sentinel}" but emit.mjs exports LADDER_REFUSE="${LADDER_REFUSE}"`);
if (!Array.isArray(ladderFixture.cases) || ladderFixture.cases.length < 4)
  webTypeFail(`  Part C2 FAIL: design/ladder-refusal-fixture.json carries ${(ladderFixture.cases || []).length} malformed case(s), not the four families — this negative half would prove almost nothing`);
for (const c of ladderFixture.cases || []) {
  const arg = c.kind === "omit" ? { type: {} } : { type: { chrome: c.family } };
  let refused = false;
  try { typeLadderFrom(arg, "chrome"); } catch (e) { refused = String(e.message).includes(LADDER_REFUSE); }
  if (!refused)
    webTypeFail(`  Part C2 FAIL: IMPLEMENTATION "emit" (typeLadderFrom) did not refuse ladder-refusal-fixture.json case "${c.id}" with "${LADDER_REFUSE}" — the ladder derivation can go blind and still report a pass. ${c.why}`);
}
// arm 1 — every emitted step carries tokens.json's three numbers, verbatim.
const emittedStep = (family, step) => {
  const re = new RegExp(`^  (?:"${step}"|${step}): \\{ size: (\\d+(?:\\.\\d+)?), lineHeight: (\\d+(?:\\.\\d+)?), weight: (\\d+) \\},$`, "m");
  const block = webTokensText.split(`export const ${family} = {`)[1];
  const m = block === undefined ? null : block.split("} as const")[0].match(re);
  return m && { size: Number(m[1]), lineHeight: Number(m[2]), weight: Number(m[3]) };
};
for (const step of TYPE_STEPS) {
  const spec = tokens.type.chrome[step];
  const got = emittedStep("chromeType", step);
  if (!got) { webTypeFail(`  Part C2 FAIL: ${webTokensPath} chromeType.${step} is MISSING`); continue; }
  if (got.size !== spec.size || got.lineHeight !== spec.lineHeight || got.weight !== spec.weight)
    webTypeFail(`  Part C2 FAIL: chromeType.${step} ${JSON.stringify(got)} ≠ tokens.type.chrome.${step} {size:${spec.size},lineHeight:${spec.lineHeight},weight:${spec.weight}}`);
}
for (const step of READING_STEPS) {
  const spec = tokens.type.reading[step];
  const wantWeight = spec.weight ?? (step === "body" ? 400 : tokens.type.reading.headingWeight);
  const got = emittedStep("readingType", step);
  if (!got) { webTypeFail(`  Part C2 FAIL: ${webTokensPath} readingType.${step} is MISSING`); continue; }
  if (got.size !== spec.size || got.lineHeight !== spec.lineHeight || got.weight !== wantWeight)
    webTypeFail(`  Part C2 FAIL: readingType.${step} ${JSON.stringify(got)} ≠ tokens.type.reading.${step} {size:${spec.size},lineHeight:${spec.lineHeight},weight:${wantWeight}}`);
}
// arm 2 — the consumer READS the ladder and restates no step of its own. A
// literal `size: 20` or `lh: 1.3` in this file is the defect returning.
for (const sym of ["chromeType", "chromeTypeOrder", "readingType", "readingTypeOrder"])
  if (!styleguideText.includes(sym))
    webTypeFail(`  Part C2 FAIL: ${styleguidePath} does not consume the emitted ${sym}`);
if (!/from "@\/lib\/tokens\.gen"/.test(styleguideText))
  webTypeFail(`  Part C2 FAIL: ${styleguidePath} does not import the emitted token module`);
for (const [re, what] of [[/\bsize:\s*\d/, "a literal type size"], [/\blh:\s*\d/, "a literal line height"], [/\bfontWeight:\s*\d{3}\b/, "a literal font weight"]])
  if (re.test(styleguideText))
    webTypeFail(`  Part C2 FAIL: ${styleguidePath} declares ${what} — the hand-kept ladder is back beside the emitted one`);
if (FAULT.has("C2")) webTypeFail("  Part C2 FAIL: injected fault (--selftest)");
if (webTypeOk)
  console.log(`  ok   ${TYPE_STEPS.length} chrome (derived from tokens.type.chrome, descending size) + ${READING_STEPS.length} reading steps emit typed {size,lineHeight,weight} into ${webTokensPath}, and ${styleguidePath} consumes them without restating a step`);
