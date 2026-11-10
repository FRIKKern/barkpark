// design/check/part-b.mjs — Part B of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { ARTIFACTS, glyphOf, LIFE_ORDER, tokens } from "../emit.mjs";
import { fail, failed, FAULT } from "./state.mjs";

// ── Part B (§6): cross-surface lifecycle parity ──────────────────────────────
// Source of truth = tokens.lifecycle. Two independent EMITTED artifacts must
// agree with it and with each other:
//   • Go   : internal/taskboard/tokens_gen.go  (GenLifecycle literals + frames)
//   • CSS  : paper-surface.css  .bp-lg--<state> glyph-tone classes
console.log("\ndesign/check.mjs — Part B (§6): GUI/TUI lifecycle parity");
// Part B's snapshot, the same declaration its nine sibling gates carry. It was
// the one part that read the run-wide `failed` directly, so ANY earlier failure
// suppressed a TRUE Part B ok and the part reported nothing at all about a check
// that passed — a diagnostic that reads identically for "passed, suppressed" and
// "did not run". Deleting the gate instead would make the line unconditional and
// so report nothing either; the snapshot is what makes it say something.
const failedBeforeB = failed;

// tokens.lifecycle → canonical facts
const wantGlyph = {}, wantLight = {}, wantDark = {};
for (const s of LIFE_ORDER) {
  const e = tokens.lifecycle[s];
  wantGlyph[s] = glyphOf(e.codepoint);
  wantLight[s] = e.color.light;
  wantDark[s] = e.color.dark;
}
const wantFrames = tokens.lifecycle.in_progress.frames.map(glyphOf);

// Parse the EMITTED Go board artifact (regenerated, so we test the emitter output
// that Part A already pinned to committed bytes).
const goText = ARTIFACTS.find((a) => a.path.endsWith("taskboard/tokens_gen.go")).build();
const goLife = {};
const goRe = /"(\w+)":\s+\{Glyph: "([^"]*)", ASCIIGlyph: "[^"]*", Role: "[^"]*", ColorLight: "([^"]*)", ColorDark: "([^"]*)"\}/g;
for (const m of goText.matchAll(goRe)) {
  goLife[m[1]] = { glyph: m[2], light: m[3], dark: m[4] };
}
const goFramesM = goText.match(/GenBrailleFrames = \[10\]string\{([^}]*)\}/);
const goFrames = goFramesM ? [...goFramesM[1].matchAll(/"([^"]*)"/g)].map((x) => x[1]) : [];

// Parse the EMITTED paper-surface glyph tones (.bp-lg--<state> { color: #hex; }).
const cssText = ARTIFACTS.find((a) => a.name === "paper-surface").build();
const cssLife = {}; // state -> [lightHex, darkHex] (first occurrence = light block, second = dark media)
for (const m of cssText.matchAll(/\.bp-lg--(\w+) \{ color: (#[0-9a-fA-F]{6}); \}/g)) {
  (cssLife[m[1]] ||= []).push(m[2]);
}

// Parse the EMITTED Studio surface — the THIRD lifecycle mirror (Decision D1).
// Two artifacts carry it: the root-layout CSS --life-<state> vars (colour, light
// then dark) and the Studio TokensGen lifecycle/0 rows (glyph + ascii + hue) +
// lifecycle_frames/0. Both must agree with tokens.lifecycle, so a Studio-vs-
// Go/CSS lifecycle divergence trips this gate exactly like the paper surface does.
const studioText = ARTIFACTS.find((a) => a.path.endsWith("layouts/root.html.heex")).build();
const studioLife = {}; // state -> [lightHex, darkHex] (:root light first, dark block second)
for (const m of studioText.matchAll(/--life-(\w+): (#[0-9a-fA-F]{6});/g)) {
  (studioLife[m[1]] ||= []).push(m[2]);
}

const tgText = ARTIFACTS.find((a) => a.path.endsWith("studio/tokens_gen.ex")).build();
const tgLife = {}; // state -> {glyph, light, dark} from lifecycle/0 rows
for (const m of tgText.matchAll(
  /%\{state: "(\w+)", glyph: "([^"]*)", ascii: "[^"]*", light: "(#[0-9a-fA-F]{6})", dark: "(#[0-9a-fA-F]{6})"\}/g,
)) {
  tgLife[m[1]] = { glyph: m[2], light: m[3], dark: m[4] };
}
const tgFramesM = tgText.match(/def lifecycle_frames, do: ~w\(([^)]*)\)/);
const tgFrames = tgFramesM ? tgFramesM[1].trim().split(/\s+/) : [];

// Assertions
const goStates = Object.keys(goLife).sort();
const cssStates = Object.keys(cssLife).sort();
const studioStates = Object.keys(studioLife).sort();
const tgStates = Object.keys(tgLife).sort();
const want = [...LIFE_ORDER].sort();
if (goStates.join(",") !== want.join(","))
  fail(`  §6 FAIL: Go lifecycle states ${JSON.stringify(goStates)} ≠ tokens ${JSON.stringify(want)}`);
if (cssStates.join(",") !== want.join(","))
  fail(`  §6 FAIL: CSS .bp-lg-- states ${JSON.stringify(cssStates)} ≠ tokens ${JSON.stringify(want)}`);
if (studioStates.join(",") !== want.join(","))
  fail(`  §6 FAIL: Studio --life-* states ${JSON.stringify(studioStates)} ≠ tokens ${JSON.stringify(want)}`);
if (tgStates.join(",") !== want.join(","))
  fail(`  §6 FAIL: Studio TokensGen lifecycle/0 states ${JSON.stringify(tgStates)} ≠ tokens ${JSON.stringify(want)}`);

for (const s of LIFE_ORDER) {
  const g = goLife[s] || {};
  const c = cssLife[s] || [];
  const sl = studioLife[s] || [];
  const t = tgLife[s] || {};
  if (g.glyph !== wantGlyph[s])
    fail(`  §6 FAIL: ${s} glyph — Go ${JSON.stringify(g.glyph)} ≠ tokens ${JSON.stringify(wantGlyph[s])}`);
  if (g.light !== wantLight[s] || g.dark !== wantDark[s])
    fail(`  §6 FAIL: ${s} Go colour {${g.light},${g.dark}} ≠ tokens {${wantLight[s]},${wantDark[s]}}`);
  if (c[0] !== wantLight[s] || c[1] !== wantDark[s])
    fail(`  §6 FAIL: ${s} CSS glyph-tone {${c[0]},${c[1]}} ≠ tokens {${wantLight[s]},${wantDark[s]}} (GUI/TUI divergence)`);
  if (sl[0] !== wantLight[s] || sl[1] !== wantDark[s])
    fail(`  §6 FAIL: ${s} Studio --life {${sl[0]},${sl[1]}} ≠ tokens {${wantLight[s]},${wantDark[s]}} (Studio divergence)`);
  if (t.glyph !== wantGlyph[s])
    fail(`  §6 FAIL: ${s} Studio TokensGen glyph ${JSON.stringify(t.glyph)} ≠ tokens ${JSON.stringify(wantGlyph[s])}`);
  if (t.light !== wantLight[s] || t.dark !== wantDark[s])
    fail(`  §6 FAIL: ${s} Studio TokensGen colour {${t.light},${t.dark}} ≠ tokens {${wantLight[s]},${wantDark[s]}}`);
}
if (goFrames.join("") !== wantFrames.join(""))
  fail(`  §6 FAIL: Go braille frame-set ≠ tokens.lifecycle.in_progress.frames`);
if (tgFrames.join("") !== wantFrames.join(""))
  fail(`  §6 FAIL: Studio TokensGen braille frame-set ≠ tokens.lifecycle.in_progress.frames`);

// done/closed must stay TEAL, distinct from status.ok green (regression tripwire).
if (wantLight.done === tokens.color.status.ok.light)
  fail("  §6 FAIL: done colour collided with status.ok — teal/green distinction lost");
for (const s of ["done", "closed"]) {
  if (goLife[s]?.light !== "#0d9488" || goLife[s]?.dark !== "#2dd4bf")
    fail(`  §6 FAIL: ${s} is not teal (#0d9488/#2dd4bf) in the Go artifact`);
}

if (FAULT.has("B")) fail("  Part B FAIL: injected fault (--selftest)");

if (failed === failedBeforeB)
  console.log(`  ok   ${LIFE_ORDER.length} lifecycle states agree across Go + CSS + Studio (CSS var + TokensGen) + tokens (glyph, colour, frames); done/closed teal ≠ status.ok green`);

export { studioText, want, wantGlyph };
