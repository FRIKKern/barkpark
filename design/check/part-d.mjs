// design/check/part-d.mjs — Part D of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { ARTIFACTS, glyphOf, hslToHex, INST_ORDER, INST_ROLE_CSS, instRoleChannels, PROVIDERS, tokens } from "../emit.mjs";
import { fail, failed, FAULT } from "./state.mjs";
import { wantGlyph } from "./part-b.mjs";

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

if (FAULT.has("D")) fail("  Part D FAIL: injected fault (--selftest)");

if (failed === failedBeforeD)
  console.log(`  ok   ${INST_ORDER.length} instance states + ${PROVIDERS.length} provider marks agree across CSS + Go + tokens (glyph, role→hue, tint hex)`);
