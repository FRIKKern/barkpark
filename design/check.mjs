#!/usr/bin/env node
// design/check.mjs — the W1.2 drift gate. Re-emits every per-surface artifact
// into memory and byte-compares it against what is committed; any divergence is a
// non-zero exit with a per-artifact diff summary. PLUS §6: a cross-surface parity
// assertion that the emitted Go lifecycle literals, the emitted CSS glyph tones,
// and design/tokens.json agree on glyph, colour and the braille frame-set — so a
// GUI (CSS) vs TUI (Go) lifecycle divergence trips the gate.
// Dependency-free (Node built-ins only). Pairs with design/validate.mjs (shape)
// and design/emit.mjs (the single source of the emitted bytes).
import {
  evaluateAll, tokens, LIFE_ORDER, TYPE_STEPS, glyphOf, ARTIFACTS, repoRoot,
} from "./emit.mjs";
import { evaluateMirror } from "./paper-editor-mirror.mjs";

let failed = false;
const fail = (msg) => { console.error(msg); failed = true; };

// ── Part A: per-artifact byte-compare against committed ──────────────────────
function firstDiff(a, b) {
  const la = a.split("\n"), lb = b.split("\n");
  const n = Math.max(la.length, lb.length);
  for (let i = 0; i < n; i++) {
    if (la[i] !== lb[i]) {
      return `    line ${i + 1}:\n      - committed:  ${JSON.stringify(la[i])}\n      + regenerated: ${JSON.stringify(lb[i])}`;
    }
  }
  return "    (files differ in length only)";
}

console.log("design/check.mjs — Part A: per-surface byte parity");
for (const r of evaluateAll()) {
  if (r.error) { fail(`  FAIL ${r.name}: ${r.error}`); continue; }
  if (r.current == null) { fail(`  FAIL ${r.name}: committed file ${r.path} is missing`); continue; }
  if (r.current !== r.expected) {
    fail(`  DRIFT ${r.name} (${r.path}) — committed output is STALE vs design/tokens.json`);
    console.error(firstDiff(r.current, r.expected));
  } else {
    console.log(`  ok   ${r.name} (${r.path})`);
  }
}

// Paper-editor token mirror: a second generation hop (paper-surface.css → the
// styles.css bundle's marked region). Same shared transform emit.mjs drives, so
// a stale committed mirror trips HERE the same way a stale surface trips above.
{
  const mr = evaluateMirror(repoRoot);
  if (mr.error) fail(`  FAIL ${mr.name}: ${mr.error}`);
  else if (mr.current == null) fail(`  FAIL ${mr.name}: committed file ${mr.path} is missing`);
  else if (mr.current !== mr.expected) {
    fail(`  DRIFT ${mr.name} (${mr.path}) — the paper-editor mirror is STALE vs api/assets/paper-surface/paper-surface.css`);
    console.error(firstDiff(mr.current, mr.expected));
  } else {
    console.log(`  ok   ${mr.name} (${mr.path})`);
  }
}
if (failed) console.error("\n  Fix: node design/emit.mjs --write\n");

// ── Part B (§6): cross-surface lifecycle parity ──────────────────────────────
// Source of truth = tokens.lifecycle. Two independent EMITTED artifacts must
// agree with it and with each other:
//   • Go   : internal/taskboard/tokens_gen.go  (GenLifecycle literals + frames)
//   • CSS  : paper-surface.css  .bp-lg--<state> glyph-tone classes
console.log("\ndesign/check.mjs — Part B (§6): GUI/TUI lifecycle parity");

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
const cssText = ARTIFACTS.find((a) => a.path.endsWith("paper-surface.css")).build();
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

if (!failed)
  console.log(`  ok   ${LIFE_ORDER.length} lifecycle states agree across Go + CSS + Studio (CSS var + TokensGen) + tokens (glyph, colour, frames); done/closed teal ≠ status.ok green`);

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
if (typeOk)
  console.log(`  ok   ${TYPE_STEPS.length} chrome type steps emit --text-* vars matching tokens.type.chrome (size + line-height)`);

// ── verdict ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error("\ndesign/check.mjs: FAILED — a surface has drifted from design/tokens.json.");
  process.exit(1);
}
console.log(`\ndesign/check.mjs: PASS — ${ARTIFACTS.length} surfaces in lockstep + §6 lifecycle parity holds.`);
