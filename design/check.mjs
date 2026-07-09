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
  INST_ORDER, PROVIDERS, INST_ROLE_CSS, instRoleChannels, hslToHex,
} from "./emit.mjs";
import { evaluateMirror } from "./paper-editor-mirror.mjs";
import { derive, SLOTS, PASSTHROUGH_FAMILIES } from "./derive.mjs";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

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

// ── Part D: cloud-console family parity (charter azure-hetzner Decision 7) ────
// The instanceLifecycle + provider-identity families are DUAL-emitted: the SPA
// generated block (.bp-inst--<state> glyph tones + --provider-<kind> tints) and
// the Go CLI chrome sibling (GenInstanceLifecycle + GenProviderMark). This gate
// asserts both surfaces agree with tokens AND with each other — so a browser↔
// terminal instance-state divergence trips exactly like the §6 task-lifecycle
// gate. Colour is read THROUGH the status role on both surfaces (identity never
// a state voice), which this part also verifies (CSS var == role's var; Go hue
// == role tone resolved to hex).
console.log("\ndesign/check.mjs — Part D: cloud-console (instanceLifecycle + provider) parity");
const failedBeforeD = failed;

const cloudText = ARTIFACTS.find((a) => a.path.endsWith("static/app.css")).build();
const chromeText = ARTIFACTS.find((a) => a.path.endsWith("semrole/chrome_gen.go")).build();

// EMITTED CSS: .bp-inst--<state> { color: var(--x); } + --provider-<kind>: #hex;
const cssInst = {};
for (const m of cloudText.matchAll(/\.bp-inst--(\w+) \{ color: var\((--[\w-]+)\); \}/g)) cssInst[m[1]] = m[2];
const cssProv = {}; // kind -> [lightHex, darkHex] (:root first, dark block second)
for (const m of cloudText.matchAll(/--provider-(\w+): (#[0-9a-fA-F]{6});/g)) (cssProv[m[1]] ||= []).push(m[2]);

// EMITTED Go: GenInstanceLifecycle rows + GenProviderMark rows.
const goInst = {};
for (const m of chromeText.matchAll(
  /"(\w+)":\s+\{Glyph: "([^"]*)", ASCIIGlyph: "[^"]*", Role: "([^"]*)", HueLight: "([^"]*)", HueDark: "([^"]*)"\}/g,
)) goInst[m[1]] = { glyph: m[2], role: m[3], hueLight: m[4], hueDark: m[5] };
const goProv = {}; // kind -> {light, dark}
for (const m of chromeText.matchAll(/"(\w+)":\s+\{Light: "(#[0-9a-fA-F]{6})", Dark: "(#[0-9a-fA-F]{6})"\}/g))
  goProv[m[1]] = { light: m[2], dark: m[3] };

// state-set agreement
const cssInstStates = Object.keys(cssInst).sort();
const goInstStates = Object.keys(goInst).sort();
const wantInst = [...INST_ORDER].sort();
if (cssInstStates.join(",") !== wantInst.join(","))
  fail(`  Part D FAIL: CSS .bp-inst-- states ${JSON.stringify(cssInstStates)} ≠ tokens ${JSON.stringify(wantInst)}`);
if (goInstStates.join(",") !== wantInst.join(","))
  fail(`  Part D FAIL: Go GenInstanceLifecycle states ${JSON.stringify(goInstStates)} ≠ tokens ${JSON.stringify(wantInst)}`);

for (const s of INST_ORDER) {
  const e = tokens.instanceLifecycle[s];
  const wantGlyph = glyphOf(e.codepoint);
  const wantVar = INST_ROLE_CSS[e.role];
  const ch = instRoleChannels(e.role);
  const wantHue = { light: hslToHex(ch.light), dark: hslToHex(ch.dark) };
  const g = goInst[s] || {};
  if (cssInst[s] !== wantVar)
    fail(`  Part D FAIL: ${s} CSS colour var ${JSON.stringify(cssInst[s])} ≠ role var ${JSON.stringify(wantVar)} (role ${JSON.stringify(e.role)})`);
  if (g.glyph !== wantGlyph)
    fail(`  Part D FAIL: ${s} Go glyph ${JSON.stringify(g.glyph)} ≠ tokens ${JSON.stringify(wantGlyph)}`);
  if (g.role !== e.role)
    fail(`  Part D FAIL: ${s} Go role ${JSON.stringify(g.role)} ≠ tokens ${JSON.stringify(e.role)} (GUI/TUI role divergence)`);
  if (g.hueLight !== wantHue.light || g.hueDark !== wantHue.dark)
    fail(`  Part D FAIL: ${s} Go hue {${g.hueLight},${g.hueDark}} ≠ role tone {${wantHue.light},${wantHue.dark}}`);
}

// provider identity: CSS tints + Go marks == tokens (both themes)
const cssProvKinds = Object.keys(cssProv).sort();
const goProvKinds = Object.keys(goProv).sort();
const wantProv = [...PROVIDERS].sort();
if (cssProvKinds.join(",") !== wantProv.join(","))
  fail(`  Part D FAIL: CSS --provider-* kinds ${JSON.stringify(cssProvKinds)} ≠ tokens ${JSON.stringify(wantProv)}`);
if (goProvKinds.join(",") !== wantProv.join(","))
  fail(`  Part D FAIL: Go GenProviderMark kinds ${JSON.stringify(goProvKinds)} ≠ tokens ${JSON.stringify(wantProv)}`);
for (const k of PROVIDERS) {
  const t = tokens.color.provider[k];
  const c = cssProv[k] || [];
  const g = goProv[k] || {};
  if (c[0] !== t.light || c[1] !== t.dark)
    fail(`  Part D FAIL: ${k} CSS tint {${c[0]},${c[1]}} ≠ tokens {${t.light},${t.dark}}`);
  if (g.light !== t.light || g.dark !== t.dark)
    fail(`  Part D FAIL: ${k} Go mark {${g.light},${g.dark}} ≠ tokens {${t.light},${t.dark}}`);
}

if (failed === failedBeforeD)
  console.log(`  ok   ${INST_ORDER.length} instance states + ${PROVIDERS.length} provider marks agree across CSS + Go + tokens (glyph, role→hue, tint hex)`);

// ── Part E: hand-stamped color-literal exemption ledger ──────────────────────
// The theme-system north star is "no surface holds a color literal the compiler
// did not put there." We are mid-migration — a handful of surfaces still carry
// hand-stamped literals the emitter has not yet reached. design/exemptions.json
// FREEZES the current count per surface; this part re-counts and FAILS on ANY
// drift. It is a one-way ratchet: the number may only go DOWN, and every change
// (up OR down) must be accompanied by a baseline edit in the SAME diff.
//
//   • growth  → a NEW hand-stamped literal slipped in — a regression.
//   • shrink  → a literal was tokenized — good, but the baseline MUST be lowered
//               in the same diff so the ratchet keeps holding (a stale-high
//               baseline would let a future regression hide under the slack).
//
// COUNTING RULE (documented here, next to the implementation):
//   A "color literal" is `#hex` (3-8 hex digits, word-bounded) OR an
//   rgb()/rgba()/hsl()/hsla() whose first argument is NOT `var(` — i.e. a literal
//   channel value, not compiler-driven token consumption. `hsl(var(--x) / .1)` is
//   EXCLUDED on purpose: it is exactly the tokenized form we want, and excluding
//   it is what lets a literal→var() conversion show up as a shrink (a hex or
//   literal-hsl disappears and its var() replacement is not re-counted).
//   Before counting, two noise sources are blanked (newline-preserving, so the
//   regex can't match across them):
//     1. the BEGIN/END GENERATED: tokens marker region (the emitter owns those
//        literals — they are not hand-stamped), and
//     2. comments — CSS `/* … */`, HTML `<!-- … -->`, and HEEx `<%!-- … --%>` /
//        `<%# … %>` — so e.g. the `#940` PR-ref inside app.css's
//        `/* Pre-claim queued state (#940) … */` note is not miscounted as a hex.
//   Shell (.sh) carries no scanned comment syntax here (the only literals are the
//   4 hex in the holding-page <style>, which live inside a heredoc, not a `#`
//   comment), so no comment pass runs for it.
console.log("\ndesign/check.mjs — Part E: hand-stamped color-literal exemption ledger");
const failedBeforeE = failed;

const here = dirname(fileURLToPath(import.meta.url));
const LEDGER_MARKER =
  /[ \t]*\/\* BEGIN GENERATED: tokens[\s\S]*?END GENERATED: tokens \*\//g;
const LEDGER_LITERAL = /#[0-9a-fA-F]{3,8}\b|(?:rgba?|hsla?)\(\s*(?!var\()/gi;
const ledgerBlank = (m) => m.replace(/[^\n]/g, " ");

function stripLedgerNoise(text, path) {
  let s = text.replace(LEDGER_MARKER, ledgerBlank);
  if (path.endsWith(".css") || path.endsWith(".heex")) {
    s = s.replace(/\/\*[\s\S]*?\*\//g, ledgerBlank); // CSS / <style> block comments
  }
  if (path.endsWith(".heex")) {
    s = s
      .replace(/<!--[\s\S]*?-->/g, ledgerBlank)   // HTML comments
      .replace(/<%!--[\s\S]*?--%>/g, ledgerBlank) // HEEx public comments
      .replace(/<%#[\s\S]*?%>/g, ledgerBlank);    // HEEx code comments
  }
  return s;
}

function countLedgerLiterals(path) {
  const text = readFileSync(join(repoRoot, path), "utf8");
  const cleaned = stripLedgerNoise(text, path);
  return (cleaned.match(LEDGER_LITERAL) || []).length;
}

let ledger;
try {
  ledger = JSON.parse(readFileSync(join(here, "exemptions.json"), "utf8"));
} catch (e) {
  fail(`  Part E FAIL: cannot read design/exemptions.json — ${e.message}`);
  ledger = { entries: [] };
}

const ledgerRows = [];
let ledgerBaselineTotal = 0, ledgerActualTotal = 0;
for (const entry of ledger.entries) {
  let actual;
  try { actual = countLedgerLiterals(entry.path); }
  catch (e) {
    fail(`  Part E FAIL: ${entry.path} — cannot count (${e.message})`);
    continue;
  }
  const baseline = entry.count;
  ledgerBaselineTotal += baseline;
  ledgerActualTotal += actual;
  const delta = actual - baseline;
  ledgerRows.push({ path: entry.path, baseline, actual, delta });
  if (delta > 0) {
    fail(
      `  Part E FAIL: ${entry.path} GREW ${baseline} → ${actual} (+${delta}). A new ` +
      `hand-stamped color literal was added outside the generated block. Tokenize it ` +
      `(consume var(--…) from the emitted BEGIN/END GENERATED block); if it is genuinely ` +
      `un-tokenizable, RAISE the baseline in design/exemptions.json IN THIS SAME DIFF with a note.`
    );
  } else if (delta < 0) {
    fail(
      `  Part E FAIL: ${entry.path} SHRANK ${baseline} → ${actual} (${delta}) — a literal was ` +
      `tokenized (good!). LOWER the baseline to ${actual} in design/exemptions.json IN THIS SAME ` +
      `DIFF so the ratchet holds (a stale-high baseline lets a future regression hide under the slack).`
    );
  }
}

// Ledger table (path, baseline, actual, delta) — always printed, pass or fail.
{
  const pad = (s, n) => String(s).padEnd(n);
  const wPath = Math.max(4, ...ledgerRows.map((r) => r.path.length));
  console.log(`  ${pad("path", wPath)}  baseline  actual  delta`);
  for (const r of ledgerRows) {
    const mark = r.delta === 0 ? "ok  " : r.delta > 0 ? "GREW" : "SHRUNK";
    const d = r.delta > 0 ? `+${r.delta}` : String(r.delta);
    console.log(`  ${pad(r.path, wPath)}  ${pad(r.baseline, 8)}  ${pad(r.actual, 6)}  ${pad(d, 5)} ${mark}`);
  }
  console.log(`  ${pad("TOTAL", wPath)}  ${pad(ledgerBaselineTotal, 8)}  ${pad(ledgerActualTotal, 6)}`);
}

if (failed === failedBeforeE)
  console.log(
    `  ok   ${ledgerRows.length} ledgered surface(s), ${ledgerActualTotal} hand-stamped ` +
    `literal(s) frozen — none grew, none silently shrank`
  );

// ── Part F: theme compiler characterization (charter D12/D13/D14/D21) ─────────
// The non-negotiable gate that guards the whole theme system: the compiler
// (design/derive.mjs) fed the authored evergreen skin (design/themes/evergreen.json)
// must reproduce design/tokens.json's theme-varying color slots BYTE-FOR-BYTE. A
// compiler that retints evergreen to fit its own math has FAILED — so the acceptance
// is exact identity, with every byte a formula can't hit PINNED in the theme's
// `overrides` (each carrying a one-line reason) and the override COUNT frozen exactly
// like Part E freezes literal counts: growth reds (a formula silently regressed),
// shrink requires updating the frozen count in the SAME diff (a pin was retired).
//
//   • schema gate  — every themes/*.json is well-formed {bg,ink,accent}×mode, its
//                     override keys are real slots with reasons, and its passthrough
//                     declaration stays within the theme-INVARIANT family list (D21).
//   • no-hole gate — derive's SLOTS contract === tokens' theme-varying leaf set, so a
//                     new color family can't slip in underived (w4 must not find a hole).
//   • byte gate    — derive(evergreen)[slot] === tokens[slot] for all ~146 leaves,
//                     across HSL-triplet / #hex / rgba() / var(--role) formats.
//   • ratchet      — the override count is frozen; evergreen derives MORE natively than
//                     it pins (fit-first, D14 — a mostly-overrides compiler is vacuous).
console.log("\ndesign/check.mjs — Part F: theme compiler characterization (derive(evergreen) === tokens)");
const failedBeforeF = failed;

// Frozen override counts, per theme. GROWTH reds (a formula regressed and now needs a
// pin — fix the formula, don't grow the pin block); SHRINK requires lowering this in
// the SAME diff (a pin was retired to a native derivation — the ratchet must follow).
const OVERRIDE_COUNT_FROZEN = { evergreen: 56 };

// Part F characterization GROUND TRUTH is design/tokens.json read STRAIGHT FROM
// DISK — never the `tokens` singleton re-exported by emit.mjs. Since the w4 seam
// (charter D22) emit.mjs now overlays derive(evergreen) onto its exported color
// tree, comparing derive against `emit.tokens` would compare derive against derive
// (vacuous green). The raw file is the frozen mirror; comparing derive against it
// keeps the byte gate honest.
const rawTokensDisk = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));

// tokens-side leaf reader: every theme-varying family lives under color.* in the
// RAW on-disk tokens (ts-w3c moved paperEmail/paperCallout there — #1707).
const tokenSlot = (path) =>
  path.split(".").reduce((o, k) => (o == null ? undefined : o[k]), rawTokensDisk.color);

// Collect every theme-varying color LEAF actually present in tokens.json (color.*
// families minus declared passthroughs, plus the two top-level paper families) — the
// ground truth the SLOTS contract is asserted against.
function collectTokenLeaves() {
  const PASS = new Set(PASSTHROUGH_FAMILIES);
  const out = [];
  const walk = (prefix, obj) => {
    for (const [k, v] of Object.entries(obj)) {
      if (k.startsWith("_")) continue;
      const p = prefix ? `${prefix}.${k}` : k;
      if (typeof v === "string") out.push(p);
      else if (v && typeof v === "object") walk(p, v);
    }
  };
  for (const [fam, v] of Object.entries(rawTokensDisk.color)) {
    if (fam.startsWith("_") || PASS.has(fam)) continue;
    if (v && typeof v === "object") walk(fam, v);
  }
  return out;
}

const themesDir = join(here, "themes");
const SLOT_SET = new Set(SLOTS);
const PASS_SET = new Set(PASSTHROUGH_FAMILIES);

// (1) schema-gate every committed theme file.
let themeFiles = [];
try { themeFiles = readdirSync(themesDir).filter((f) => f.endsWith(".json")); }
catch (e) { fail(`  Part F FAIL: cannot read design/themes/ — ${e.message}`); }
if (themeFiles.length === 0) fail("  Part F FAIL: no design/themes/*.json — the theme system has no authored theme");

const themeCache = {};
for (const f of themeFiles) {
  let theme;
  try { theme = JSON.parse(readFileSync(join(themesDir, f), "utf8")); }
  catch (e) { fail(`  Part F FAIL: ${f} is not valid JSON — ${e.message}`); continue; }
  themeCache[f] = theme;
  const name = theme.name || f.replace(/\.json$/, "");

  for (const m of ["light", "dark"]) {
    const md = theme.modes && theme.modes[m];
    if (!md || typeof md.bg !== "string" || typeof md.ink !== "string" || typeof md.accent !== "string")
      fail(`  Part F FAIL: ${f} mode "${m}" must author {bg,ink,accent} as HSL strings`);
  }
  const overrides = theme.overrides || {};
  const reasons = theme._overrideReasons || {};
  for (const k of Object.keys(overrides)) {
    if (!SLOT_SET.has(k))
      fail(`  Part F FAIL: ${f} overrides an UNKNOWN slot "${k}" — not a derive SLOTS contract member (typo, or a slot the compiler doesn't emit)`);
    if (!reasons[k])
      fail(`  Part F FAIL: ${f} override "${k}" has no _overrideReasons entry — every pin must carry a one-line reason (why the formula can't hit it)`);
  }
  for (const p of theme.passthrough || []) {
    if (!PASS_SET.has(p))
      fail(`  Part F FAIL: ${f} declares passthrough "${p}" which is NOT a theme-invariant family (D21) — a derivable family cannot opt out of characterization`);
  }
  console.log(`  ok   schema: ${name} — {bg,ink,accent}×2 modes, ${Object.keys(overrides).length} reasoned override(s), ${(theme.passthrough || []).length} declared passthrough(s)`);
}

// (2) no-hole gate: the SLOTS contract must EXACTLY equal tokens' theme-varying leaf
// set. A family present in tokens but absent from SLOTS = an underived hole (w4 would
// discover it); a SLOT with no tokens leaf = a phantom contract entry. Also assert
// every non-passthrough color family in tokens is covered by SLOTS (undeclared family).
{
  const leaves = collectTokenLeaves();
  const leafSet = new Set(leaves);
  const missing = leaves.filter((s) => !SLOT_SET.has(s));            // in tokens, not derived
  const phantom = SLOTS.filter((s) => !leafSet.has(s));              // derived, not in tokens
  if (missing.length)
    fail(`  Part F FAIL: ${missing.length} tokens color leaf(s) are NOT in derive's SLOTS contract (undeclared/underived): ${missing.slice(0, 8).join(", ")}${missing.length > 8 ? " …" : ""}`);
  if (phantom.length)
    fail(`  Part F FAIL: ${phantom.length} derive SLOTS entr(y/ies) have no tokens leaf (phantom contract): ${phantom.slice(0, 8).join(", ")}${phantom.length > 8 ? " …" : ""}`);
  if (!missing.length && !phantom.length)
    console.log(`  ok   contract: derive SLOTS (${SLOTS.length}) === tokens theme-varying leaves (${leaves.length}) — no underived hole, no phantom slot`);
}

// (3) byte gate + (4) override-count ratchet — evergreen is the shipped palette.
const evergreenFile = themeFiles.find((f) => (themeCache[f]?.name || f) === "evergreen" || f === "evergreen.json");
if (!evergreenFile) {
  fail("  Part F FAIL: design/themes/evergreen.json is missing — evergreen IS the characterized shipped palette");
} else {
  const evergreen = themeCache[evergreenFile];
  let result;
  try { result = derive(evergreen); }
  catch (e) { fail(`  Part F FAIL: derive(evergreen) threw — ${e.message}`); result = null; }
  if (result) {
    const { values, native, pinned } = result;
    let byteMiss = 0, firstMiss = null;
    for (const slot of SLOTS) {
      const want = tokenSlot(slot);
      const got = values[slot];
      if (want === undefined) { fail(`  Part F FAIL: ${slot} — no tokens value to characterize against`); continue; }
      if (got === undefined) { fail(`  Part F FAIL: ${slot} — derive produced no value (neither a formula nor an override covers it)`); continue; }
      if (want !== got) {
        byteMiss++;
        if (!firstMiss) firstMiss = slot;
        fail(`  Part F FAIL: ${slot} DRIFT — tokens ${JSON.stringify(want)} ≠ derive ${JSON.stringify(got)}. ` +
          `The compiler retinted a shipped byte. Fix the formula OR pin it in evergreen.json overrides (with a reason) and raise the frozen count.`);
      }
    }
    if (byteMiss === 0)
      console.log(`  ok   bytes: derive(evergreen) reproduces all ${SLOTS.length} tokens slots exactly (HSL/hex/rgba/var formats)`);

    // (4) override-count ratchet
    const frozen = OVERRIDE_COUNT_FROZEN.evergreen;
    if (pinned.length !== frozen) {
      const dir = pinned.length > frozen ? "GREW" : "SHRANK";
      fail(
        `  Part F FAIL: evergreen override count ${dir} ${frozen} → ${pinned.length}. ` +
        (pinned.length > frozen
          ? "A formula regressed and now needs a pin — FIX THE FORMULA (or, if genuinely un-derivable, RAISE OVERRIDE_COUNT_FROZEN.evergreen in check.mjs IN THIS SAME DIFF with a note)."
          : "A pin was retired to a native derivation (good!) — LOWER OVERRIDE_COUNT_FROZEN.evergreen to " + pinned.length + " IN THIS SAME DIFF so the ratchet holds.")
      );
    } else {
      console.log(`  ok   ratchet: evergreen override count frozen at ${frozen} (${native.length} native / ${pinned.length} pinned = ${(100 * native.length / SLOTS.length).toFixed(1)}% native)`);
    }

    // fit-first floor (D14): the compiler must derive MORE than it pins, or it is
    // vacuous. Applies to the shipped flagship only.
    if (native.length <= pinned.length)
      fail(`  Part F FAIL: evergreen is ${native.length} native / ${pinned.length} pinned — a majority-pinned compiler is vacuous (charter D13/D14). Derive more slots natively.`);

    // per-family native/pinned tally (the PR-body table).
    if (failed === failedBeforeF) {
      const fam = (s) => (s.startsWith("paper.surface") ? "paper.surface" : s.startsWith("paper.reader") ? "paper.reader" : s.split(".")[0]);
      const tally = {};
      for (const s of SLOTS) { const k = fam(s); (tally[k] ||= { n: 0, p: 0 }); }
      for (const s of native) tally[fam(s)].n++;
      for (const s of pinned) tally[fam(s)].p++;
      const pad = (x, n) => String(x).padEnd(n);
      const w = Math.max(6, ...Object.keys(tally).map((k) => k.length));
      console.log(`  ${pad("family", w)}  native  pinned`);
      for (const k of Object.keys(tally))
        console.log(`  ${pad(k, w)}  ${pad(tally[k].n, 6)}  ${tally[k].p}`);
    }
  }
}

if (failed === failedBeforeF)
  console.log("  ok   Part F PASS — the theme compiler reproduces evergreen byte-for-byte; adding theme N+1 is one more design/themes/*.json.");

// ── Part G: theme-identity attribute blocks + tone-pair nesting (D23–D26) ─────
// The Wave-4 CSS attribute axis: every attribute surface carries an explicit
// [data-bp-theme=<name>] block layered over its bare/evergreen fallback, theme
// identity is ORTHOGONAL to light/dark mode, and NO positional-passthrough var
// (the ones Parts B/D count) ever leaks into a theme scope (D25). The tone-pair
// nesting proof (D26): a theme re-declares its FULL var set at BOTH mode scopes,
// so a dark block nested in a light page re-resolves the opposite tone instead of
// inheriting the light page's active tone.
console.log("\ndesign/check.mjs — Part G: [data-bp-theme] identity blocks + tone-pair nesting");
const failedBeforeG = failed;

// Every attribute surface must carry an evergreen theme block (identity reached
// it). The media surfaces (status/sheets) + reader carry one too, but their idiom
// varies; this asserts the five DOM-attribute surfaces at minimum.
const ATTR_SURFACES = [
  ["cloud SPA", "static/app.css"],
  ["Studio", "layouts/root.html.heex"],
  ["web demo", "web/app/globals.css"],
  ["login", "controllers/session_html.ex"],
  ["paper-surface", "paper-surface.css"],
];
for (const [name, suffix] of ATTR_SURFACES) {
  const text = ARTIFACTS.find((a) => a.path.endsWith(suffix)).build();
  if (!/\[data-bp-theme="evergreen"\]/.test(text))
    fail(`  Part G FAIL: ${name} has no [data-bp-theme="evergreen"] block — theme identity did not reach this surface`);
}

// D25: no positional-passthrough var/class may appear inside a [data-bp-theme]
// scope on ANY CSS surface (Parts B/D accumulate [light,dark] pairs positionally
// — a third occurrence reds them). Scan each theme block body.
const D25_BANNED = /--life-[\w-]+|--provider-[\w-]+|\.bp-lg--|\.bp-inst--/;
let d25Clean = true;
for (const a of ARTIFACTS) {
  if (a.kind !== "css") continue;
  for (const m of a.build().matchAll(/\[data-bp-theme="[\w-]+"\][^{]*\{([^}]*)\}/g)) {
    if (D25_BANNED.test(m[1])) {
      fail(`  Part G FAIL: ${a.name} re-declares a positional-passthrough var/class (--life-*/--provider-*/.bp-lg--/.bp-inst--) inside a [data-bp-theme] block (D25)`);
      d25Clean = false;
    }
  }
}
if (d25Clean && failed === failedBeforeG)
  console.log("  ok   no --life-*/--provider-*/.bp-lg--/.bp-inst-- leaked into any [data-bp-theme] scope");

// Tone-pair nesting (D26), proven on cloud: the theme's light scope and its dark
// scope declare the SAME var set — the active/opposite pair is complete at every
// mode scope, so a nested dark island fully re-resolves.
{
  const t = ARTIFACTS.find((a) => a.path.endsWith("static/app.css")).build();
  const lm = t.match(/html\[data-bp-theme="evergreen"\] \{([^}]*)\}/);
  const dm = t.match(/html\[data-bp-theme="evergreen"\]\[data-theme="dark"\] \{([^}]*)\}/);
  if (!lm || !dm) {
    fail("  Part G FAIL: cloud evergreen light+dark theme scopes not both present — cannot prove tone-pair nesting");
  } else {
    const names = (body) => [...body.matchAll(/(--[\w-]+):/g)].map((x) => x[1]).sort();
    const ln = names(lm[1]), dn = names(dm[1]);
    if (ln.length === 0)
      fail("  Part G FAIL: cloud evergreen light theme scope declares zero vars");
    else if (ln.join(",") !== dn.join(","))
      fail(
        `  Part G FAIL: cloud tone-pair INCOMPLETE — light-scope vars ≠ dark-scope vars ` +
        `(a nested dark block would inherit the light page's active tone). ` +
        `light-only: ${ln.filter((x) => !dn.includes(x)).join(",") || "∅"}; ` +
        `dark-only: ${dn.filter((x) => !ln.includes(x)).join(",") || "∅"}`,
      );
    else
      console.log(`  ok   tone-pair: cloud re-declares all ${ln.length} theme vars at BOTH the light and dark mode scope (nested dark-in-light resolves the opposite pair)`);
  }
}

if (failed === failedBeforeG)
  console.log("  ok   Part G PASS — every attribute surface carries a [data-bp-theme] block; identity ⟂ mode; no passthrough leak.");

// ── verdict ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error("\ndesign/check.mjs: FAILED — a surface has drifted from design/tokens.json.");
  process.exit(1);
}
console.log(`\ndesign/check.mjs: PASS — ${ARTIFACTS.length} surfaces in lockstep + §6 lifecycle parity holds.`);
