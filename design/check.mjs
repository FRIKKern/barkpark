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
  evaluateAll, tokens, LIFE_ORDER, TYPE_STEPS, AIR_STEPS, EVIDENCE_KEYS, EVIDENCE_UNITS, SECTION_KEYS, SECTION_UNITS, RULE_KEYS, RULE_UNITS, MOTION_STEPS, MOTION_SURFACES, glyphOf, ARTIFACTS, repoRoot,
  INST_ORDER, PROVIDERS, INST_ROLE_CSS, instRoleChannels, hslToHex,
  readManifest, attribute, lostLines, regionDigest, MANIFEST_PATH,
  auditActions, AUDIT_ACTIONS_PATH,
} from "./emit.mjs";
import { evaluateMirror } from "./paper-editor-mirror.mjs";
import { derive, contrast, SLOTS, PASSTHROUGH_FAMILIES } from "./derive.mjs";
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

let failed = false;
const fail = (msg) => { console.error(msg); failed = true; };

// ── Part 0: the audit verb table's own shape (charter cch-w65) ────────────────
// cloud/priv/audit-actions.json is the SOLE authority for TWO vocabularies — the
// server's closed @actions allowlist (read at compile time by AuditEvent) and the
// console's ACTION_LABELS region emitted below. Its shape gate runs FIRST and
// exits immediately, because the ACTION_LABELS build() reads the table: a
// malformed row would otherwise surface as a stack trace from inside Part A
// instead of the one sentence that says which row is wrong and why. The predicate
// is auditActions() itself, so this gate and the emitter cannot disagree about
// what "well-formed" means.
try {
  const rows = auditActions();
  const nulls = rows.filter((r) => r.label === null);
  console.log(
    `design/check.mjs — Part 0: ${AUDIT_ACTIONS_PATH} well-formed — ${rows.length} declared verbs, ` +
    `${rows.length - nulls.length} labelled, ${nulls.length} declared unlabelled WITH a reason.`,
  );
} catch (e) {
  console.error(`design/check.mjs — Part 0 FAIL: ${e.message}`);
  console.error(`
  ${AUDIT_ACTIONS_PATH} is the ONE table both audit vocabularies read. Until it is
  well-formed nothing downstream can be trusted: the console's ACTION_LABELS region is
  built from it and AuditEvent's @actions allowlist is derived from it at compile time.
`);
  process.exit(1);
}

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

// Part A also carries the emitter's MEMORY. Without it this gate is a tautology
// on the far side of a write: `expected` is build() and `current` is whatever
// build() last wrote, so once emit --write has run, current === expected BY
// CONSTRUCTION and the gate prints a clean PASS over content the write destroyed.
// design/emit-manifest.json breaks the tautology — it records what the emitter
// last emitted, so a region holding bytes the emitter never produced is named as
// UNATTRIBUTED whether or not it also drifts. Crucially the remedy printed for
// that case is NOT "run --write" (which is the very command that deletes it).
let manifestRegions = {};
let manifestErr = null;
try { manifestRegions = readManifest() ?? {}; }
catch (e) { manifestErr = e.message; }
if (manifestErr) fail(`  FAIL ${MANIFEST_PATH}: ${manifestErr}`);

let unattributedSeen = false;
function reportUnattributed(r) {
  unattributedSeen = true;
  const lost = lostLines(r.currentRegion, r.expectedRegion);
  fail(`  UNATTRIBUTED ${r.name} (${r.path}) — the generated region holds bytes design/emit.mjs never wrote`);
  if (lost.length) {
    console.error(`    ${lost.length} line(s) present on disk and absent from the regenerated output:`);
    for (const l of lost.slice(0, 8)) console.error(`      - ${l}`);
    if (lost.length > 8) console.error(`      … and ${lost.length - 8} more`);
  }
  console.error(`    Do NOT "fix" this with --write: that DELETES the lines above (see commit 1d928b3bf).`);
  console.error(`    Hand-written? move it outside the BEGIN/END GENERATED marker. Genuinely generated? node design/emit.mjs --adopt`);
}

console.log("design/check.mjs — Part A: per-surface byte parity + generated-region attribution");
for (const r of evaluateAll()) {
  if (r.error) { fail(`  FAIL ${r.name}: ${r.error}`); continue; }
  if (r.current == null) { fail(`  FAIL ${r.name}: committed file ${r.path} is missing`); continue; }
  const attributed = !manifestErr && attribute(r, manifestRegions) === "attributed";
  if (!attributed) {
    reportUnattributed(r);
  } else if (r.current !== r.expected) {
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
  const mu = mr.error ? mr : { ...mr, currentRegion: mr.currentBlock, expectedRegion: mr.generatedBlock };
  if (mr.error) fail(`  FAIL ${mr.name}: ${mr.error}`);
  else if (mr.current == null) fail(`  FAIL ${mr.name}: committed file ${mr.path} is missing`);
  else if (manifestErr || attribute(mu, manifestRegions) !== "attributed") reportUnattributed(mu);
  else if (mr.current !== mr.expected) {
    fail(`  DRIFT ${mr.name} (${mr.path}) — the paper-editor mirror is STALE vs api/assets/paper-surface/paper-surface.css`);
    console.error(firstDiff(mr.current, mr.expected));
  } else {
    console.log(`  ok   ${mr.name} (${mr.path})`);
  }
}
// The blanket "Fix: --write" is safe ONLY where nothing is unattributed; where a
// region holds hand-written bytes, --write is the destructive act, not the fix.
if (failed && !unattributedSeen) console.error("\n  Fix: node design/emit.mjs --write\n");
else if (unattributedSeen) console.error("\n  Fix: relocate hand-written content outside the marker (--write would DELETE it), or --adopt if it is genuinely generated.\n");

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
//     1. every BEGIN/END GENERATED: <name> marker region — a generator owns those
//        literals, so they are not hand-stamps. Three generators emit such blocks:
//        `tokens` (design/emit.mjs), `paper-surface` (the reader→editor mirror), and
//        `status-tones` (the status skin) — all blanked, and
//     2. comments — CSS `/* … */`, HTML `<!-- … -->`, and HEEx `<%!-- … --%>` /
//        `<%# … %>` — so e.g. the `#940` PR-ref inside app.css's
//        `/* Pre-claim queued state (#940) … */` note is not miscounted as a hex.
//   Shell (.sh) carries no scanned comment syntax here (the only literals are the
//   4 hex in the holding-page <style>, which live inside a heredoc, not a `#`
//   comment), so no comment pass runs for it.
console.log("\ndesign/check.mjs — Part E: hand-stamped color-literal exemption ledger");
const failedBeforeE = failed;

const here = dirname(fileURLToPath(import.meta.url));
// Any generator-owned block — `/* BEGIN GENERATED: <name> … END GENERATED: <name> */`
// — is emitter output, not a hand-stamp. Today three generators write such blocks:
// `tokens` (the theme compiler, design/emit.mjs), `paper-surface` (the reader→editor
// mirror, scripts/paper-editor-mirror-check.sh), and `status-tones` (the status skin,
// scripts/status-manifest-check.sh). The name is captured and back-referenced so the
// END must match its own BEGIN — abutting blocks (status-tones then tokens in
// paper-surface.css) each strip cleanly instead of one swallowing the other.
const LEDGER_MARKER =
  /[ \t]*\/\* BEGIN GENERATED: ([\w-]+)[\s\S]*?END GENERATED: \1 \*\//g;
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

// Frozen override counts, PER THEME (a map, keyed by theme name — every committed
// theme freezes its own pin count). GROWTH reds (a formula regressed and now needs a
// pin — fix the formula, don't grow the pin block); SHRINK requires lowering the
// entry in the SAME diff (a pin was retired to a native derivation — the ratchet
// must follow). ts-w5a raised evergreen 56 → 82: promoting the neutral ladder +
// CLI chrome ramp into skin-responsive formulas (D14ii/v) means evergreen's
// shadcn-zinc bytes no longer match the formula, so its 26 zinc rungs are
// CHARACTERIZATION-FROZEN as pins (a fresh theme re-hues natively). A theme with no
// entry here is not ratcheted (a fixture); every design/themes/*.json ships one.
const OVERRIDE_COUNT_FROZEN = { evergreen: 82, ember: 3, fjord: 3, charple: 2, iris: 0 };

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
  // _aaExceptions is a list of {slot, reason} — every AA-walk residual miss a NATIVE
  // formula reports (D15) must be explained here, or the byte the compiler ships
  // fails contrast with no owner. Shape-gate it now; the coverage check runs below.
  for (const e of theme._aaExceptions || []) {
    if (!e || typeof e.slot !== "string" || typeof e.reason !== "string")
      fail(`  Part F FAIL: ${f} _aaExceptions entry must be {slot, reason} strings — got ${JSON.stringify(e)}`);
  }
  console.log(`  ok   schema: ${name} — {bg,ink,accent}×2 modes, ${Object.keys(overrides).length} reasoned override(s), ${(theme.passthrough || []).length} declared passthrough(s)`);
}

// (1b) PER-THEME completeness + non-vacuous + AA-exception + ratchet + native%.
// Runs derive() over EVERY committed theme (closes emit.mjs themePalette's
// `if (v === undefined) continue` silent-inherit — an unresolved slot would let a
// theme silently inherit evergreen's base byte). Two derives per theme:
//   • WITH overrides   → completeness: every slot resolves (no undefined leaf).
//   • MINUS overrides  → non-vacuous:  a BARE {bg,ink,accent} skin STILL resolves
//                        every slot from a real formula (replaces the old "native >
//                        pinned on evergreen" floor — a compiler with a formula for
//                        every slot is not vacuous even when the shipped flagship
//                        pins many bespoke bytes).
// AA-walk residual misses (status/callout on a bare skin) must all be declared in
// the theme's _aaExceptions. native% is REPORTED per theme, NOT gated (evergreen's
// legacy palette pins heavily and honestly; a fresh theme derives ~100% natively).
for (const f of themeFiles) {
  const theme = themeCache[f];
  if (!theme) continue;
  const name = theme.name || f.replace(/\.json$/, "");
  const frozen = OVERRIDE_COUNT_FROZEN[name];

  let full, bare;
  try { full = derive(theme); }
  catch (e) { fail(`  Part F FAIL: derive(${name}) threw — ${e.message}`); continue; }
  try { bare = derive({ ...theme, overrides: {} }); }
  catch (e) { fail(`  Part F FAIL: derive(${name} without overrides — the bare skin) threw — ${e.message}`); continue; }

  if (full.unresolved.length)
    fail(`  Part F FAIL: ${name} leaves ${full.unresolved.length} slot(s) UNRESOLVED (no formula, no pin) — a theme would silently inherit the base byte: ${full.unresolved.slice(0, 6).join(", ")}${full.unresolved.length > 6 ? " …" : ""}`);
  if (bare.unresolved.length)
    fail(`  Part F FAIL: ${name}'s BARE {bg,ink,accent} skin leaves ${bare.unresolved.length} slot(s) with NO formula (vacuous compiler — a slot only a pin covers): ${bare.unresolved.slice(0, 6).join(", ")}${bare.unresolved.length > 6 ? " …" : ""}`);

  // Every AA-walk residual miss a NATIVE formula ships must be an owned exception.
  const declared = new Set((theme._aaExceptions || []).map((e) => e.slot));
  const undeclared = full.misses.filter((m) => !declared.has(m.slot));
  if (undeclared.length)
    fail(
      `  Part F FAIL: ${name} ships ${undeclared.length} AA-walk MISS(es) with no _aaExceptions entry (D15 — a returned colour that fails contrast is a bug): ` +
      undeclared.map((m) => `${m.slot} (got ${m.got.toFixed(2)} < ${m.want})`).join(", "),
    );

  // Per-theme override ratchet (only for themes that declare a frozen count).
  if (frozen !== undefined && full.pinned.length !== frozen) {
    const dir = full.pinned.length > frozen ? "GREW" : "SHRANK";
    fail(
      `  Part F FAIL: ${name} override count ${dir} ${frozen} → ${full.pinned.length}. ` +
      (full.pinned.length > frozen
        ? "A formula regressed and now needs a pin — FIX THE FORMULA (or, if genuinely un-derivable, RAISE OVERRIDE_COUNT_FROZEN in check.mjs IN THIS SAME DIFF with a note)."
        : `A pin was retired to a native derivation (good!) — LOWER OVERRIDE_COUNT_FROZEN.${name} to ${full.pinned.length} IN THIS SAME DIFF so the ratchet holds.`),
    );
  }

  const nativePct = (100 * full.native.length / SLOTS.length).toFixed(1);
  const barePct = (100 * bare.native.length / SLOTS.length).toFixed(1);
  console.log(
    `  ok   ${name}: complete (0 unresolved), bare skin resolves all ${SLOTS.length} slots natively (${barePct}% formula), ` +
    `${full.native.length} native / ${full.pinned.length} pinned = ${nativePct}% native [reported, not gated]` +
    (full.misses.length ? `, ${full.misses.length} AA exception(s) declared` : ""),
  );
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

    // NOTE: the override-count ratchet + native% are asserted PER THEME in the
    // (1b) loop above (OVERRIDE_COUNT_FROZEN is a per-theme map now). The old
    // "native > pinned on evergreen" fit-first floor is RETIRED: it wrongly reds a
    // heavily-characterized flagship (evergreen pins its bespoke legacy bytes). The
    // non-vacuous guarantee is now the STRONGER bare-skin check — every slot has a
    // real formula, proven on the {bg,ink,accent}-only skin (1b) — not a pin-count
    // ratio on the one theme that most needs to freeze bytes.

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
const D25_BANNED = /--life-[\w-]+|--provider-[\w-]+|--cc-[\w-]+|\.bp-lg--|\.bp-inst--/;
let d25Clean = true;
for (const a of ARTIFACTS) {
  if (a.kind !== "css") continue;
  for (const m of a.build().matchAll(/\[data-bp-theme="[\w-]+"\][^{]*\{([^}]*)\}/g)) {
    if (D25_BANNED.test(m[1])) {
      fail(`  Part G FAIL: ${a.name} re-declares a positional-passthrough var/class (--life-*/--provider-*/--cc-*/.bp-lg--/.bp-inst--) inside a [data-bp-theme] block (D25)`);
      d25Clean = false;
    }
  }
}
if (d25Clean && failed === failedBeforeG)
  console.log("  ok   no --life-*/--provider-*/--cc-*/.bp-lg--/.bp-inst-- leaked into any [data-bp-theme] scope");

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

// ── Part H: WCAG-AA fg×surface contrast gate (studio-ui-premium D15/D8) ───────
// derive.mjs already ships the WCAG contrast() (Part I); this part makes AA a
// PERMANENT machine gate. It DERIVES every committed theme (ember/fjord author
// only {bg,ink,accent} — the chrome tokens are FORMULA-derived, so a per-theme
// derive is REQUIRED to know each theme's real --fg-dim/--bg-accent/… bytes; a
// theme whose derive() throws is skipped LOUDLY, never crashing the whole check)
// and asserts a CURATED table of pairings that ACTUALLY co-occur in the Studio
// DOM. Each entry names the CSS selector whose `color` is the foreground — READ
// LIVE out of the committed root.html.heex, so reverting a pairing fix reds this
// gate — and the surface token it renders on (CURATED: the co-occurrence a
// cartesian product would fabricate, e.g. --fg-dim on --bg-accent happens ONLY on
// a selected row). kind "text" needs AA 4.5; "nontext" (icons/carets) needs 3.0.
console.log("\ndesign/check.mjs — Part H: WCAG-AA fg×surface contrast (curated Studio pairings)");
const failedBeforeH = failed;

// DOM CSS var → derive SLOTS slot (mode appended per pairing). Aliases collapse
// per root.html.heex:359-366 (--bg-muted→muted-surface, --fg-muted→muted-text,
// --fg→text, --bg-card→surface).
const TOKEN_SLOT = {
  "--bg": "bg", "--surface": "surface", "--bg-card": "surface",
  "--muted-surface": "muted-surface", "--bg-muted": "muted-surface",
  "--muted-text": "muted-text", "--fg-muted": "muted-text",
  "--text": "text", "--fg": "text",
  "--fg-dim": "studioChrome.fg-dim",
  "--bg-accent": "studioChrome.bg-accent",
  "--surface-raised": "studioChrome.surface-raised",
  "--primary": "primary", "--primary-fg": "primary-fg",
};

// Derive every committed theme once (a THROW is skipped loudly, not fatal).
const contrastThemes = {};
for (const f of themeFiles) {
  const theme = themeCache[f];
  if (!theme) continue;
  const name = theme.name || f.replace(/\.json$/, "");
  try { contrastThemes[name] = derive(theme).values; }
  catch (e) { console.error(`  Part H SKIP: derive(${name}) threw — ${e.message} (theme skipped, non-fatal)`); }
}

// The SHIPPED root layout, straight from disk (build() emits only the generated
// block; these pane/scope rules are hand-authored, so we read the committed file).
const studioCss = readFileSync(join(repoRoot, "api/lib/barkpark_web/layouts/root.html.heex"), "utf8");

// Read the shipped foreground token out of a selector's rule body (revert→red).
// The selector is anchored to line start so a base rule (`.pane-doc-id {`) is never
// confused with a descendant rule (`.pane-doc-item.selected .pane-doc-id {`).
function ruleColor(sel) {
  const esc = sel.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = studioCss.match(new RegExp(`(?:^|\\n)[ \\t]*${esc}[ \\t]*\\{([\\s\\S]*?)\\}`));
  if (!m) return { err: `rule not found: ${sel}` };
  const c = m[1].match(/color:\s*var\((--[\w-]+)(?:\s*,[^)]*)?\)/);
  if (!c) return { err: `no "color: var(--…)" in rule ${sel}` };
  return { token: c[1] };
}

// Curated table — every (fg-site, surface) is a REAL co-occurrence. `where` cites
// the mirrored CSS rule. NOT a cartesian product.
const PAIRINGS = [
  // Pane document rows (sup-w2 desk anatomy: subtitle .pane-doc-sub, hover
  // fill --bg-muted, selected fill --bg-accent; the rightmost focus pane rides
  // --surface-raised via .pane-column--last).
  { sel: ".pane-doc-badge",                        surface: "--bg-muted",       kind: "text",    where: "root.html.heex .pane-doc-badge — pill paints its own --bg-muted fill" },
  { sel: ".pane-doc-sub",                          surface: "--surface",        kind: "text",    where: "root.html.heex .pane-doc-sub — subtitle on a non-last .pane-column --bg-card(=surface)" },
  { sel: ".pane-doc-sub",                          surface: "--surface-raised", kind: "text",    where: "root.html.heex .pane-doc-sub — subtitle on the .pane-column--last focus pane" },
  { sel: ".pane-doc-sub",                          surface: "--bg-muted",       kind: "text",    where: "root.html.heex .pane-doc-item:hover — hover row fill" },
  { sel: ".pane-doc-item.selected .pane-doc-sub",  surface: "--bg-accent",      kind: "text",    where: "root.html.heex .pane-doc-item.selected — selected row fill (escalates to --fg)" },
  // sup-w4 row-state ladder: the doc TITLE now paints the plain --fg-muted tier
  // (was body --fg, brighter than every nav label) on the same grounds as the
  // subtitle; the selected title escalates to --fg to clear the --bg-accent fence.
  { sel: ".pane-doc-title",                        surface: "--surface",        kind: "text",    where: "root.html.heex .pane-doc-title — title plain tier on a non-last .pane-column --bg-card(=surface)" },
  { sel: ".pane-doc-title",                        surface: "--surface-raised", kind: "text",    where: "root.html.heex .pane-doc-title — title plain tier on the .pane-column--last focus pane" },
  { sel: ".pane-doc-title",                        surface: "--bg-muted",       kind: "text",    where: "root.html.heex .pane-doc-item:hover — hover lifts the title to --fg over the --bg-muted fill (this row proves the plain tier before the lift)" },
  { sel: ".pane-doc-item.selected .pane-doc-title", surface: "--bg-accent",     kind: "text",    where: "root.html.heex .pane-doc-item.selected — selected title escalates to --fg on the --bg-accent fill" },
  // Pane chrome (headers/counts) — the focus pane ground is --surface-raised.
  { sel: ".pane-section-header",                   surface: "--surface",        kind: "text",    where: "root.html.heex .pane-section-header — section label on a non-last pane" },
  { sel: ".pane-column--last .pane-section-header", surface: "--surface-raised", kind: "text",   where: "root.html.heex .pane-column--last .pane-section-header — escalated on the raised focus pane" },
  { sel: ".pane-header-count",                     surface: "--bg-muted",       kind: "text",    where: "root.html.heex .pane-header-count — count pill paints its own --bg-muted fill" },
  // Pane navigation items.
  { sel: ".pane-item",                             surface: "--surface",        kind: "text",    where: "root.html.heex .pane-item — nav row on .pane-column surface" },
  { sel: ".pane-item",                             surface: "--surface-raised", kind: "text",    where: "root.html.heex .pane-item — nav row on the .pane-column--last focus pane" },
  { sel: ".pane-item.selected",                    surface: "--bg-accent",      kind: "text",    where: "root.html.heex .pane-item.selected — selected-row-on-bg-accent" },
  // sup-w4: the nav drill chevron is hover-revealed (opacity 0 at rest), so its
  // REAL visible grounds are the hover fill (--bg-muted) and the selected fill
  // (--bg-accent) — the old --surface row became a phantom co-occurrence.
  { sel: ".pane-item-chevron",                     surface: "--bg-muted",       kind: "nontext", where: "root.html.heex .pane-item:hover .pane-item-chevron — revealed glyph on the hover fill" },
  { sel: ".pane-item-chevron",                     surface: "--bg-accent",      kind: "nontext", where: "root.html.heex .pane-item.selected .pane-item-chevron — revealed glyph on the selected fill" },
  // sup-w4 row-state ladder: plugin-contributed nav rows (e.g. Projects) now paint
  // the SAME --fg-muted plain tier as sibling .pane-item rows (was color:inherit →
  // body --fg, the "Projects outshines its siblings" bug). Gate the fixed color so
  // a revert to inherit reds here — the pairing was ungated before this wave.
  { sel: "a.pane-item.nav-plugin-entry",           surface: "--surface",        kind: "text",    where: "root.html.heex a.pane-item.nav-plugin-entry — plugin nav row on .pane-column surface" },
  { sel: "a.pane-item.nav-plugin-entry",           surface: "--surface-raised", kind: "text",    where: "root.html.heex a.pane-item.nav-plugin-entry — plugin nav row on the .pane-column--last focus pane" },
  // Secondary (detail) pane read-only note — its own --bg-muted fill. Caught by
  // the sup-w3 QA sweep as fg-dim-on-bg-muted (4.05–4.40, sub-AA), the identical
  // D15 defect .pane-doc-badge had; escalated fg-dim→muted-text at the site.
  { sel: ".bp-secondary-pane-readonly",            surface: "--bg-muted",       kind: "text",    where: "root.html.heex .bp-secondary-pane-readonly — read-only note paints its own --bg-muted fill (editor detail pane)" },
  // Compact scope chip — surface-raised trigger fill.
  { sel: ".scope-title-caret",                     surface: "--surface-raised", kind: "nontext", where: "root.html.heex .scope-title-caret — glyph on .scope-title --surface-raised" },
  { sel: ".scope-title-trail",                     surface: "--surface-raised", kind: "text",    where: "root.html.heex .scope-title-trail — trail text on .scope-title --surface-raised" },
  // Scope chip v2: the workspace rides the avatar square (primary fill); the
  // dataset a .pane-doc-badge-pattern pill on its own --bg-muted fill.
  { sel: ".scope-avatar",                          surface: "--primary",         kind: "text",    where: "root.html.heex .scope-avatar — workspace initial on the --primary brand square" },
  { sel: ".scope-dataset-badge",                   surface: "--bg-muted",        kind: "text",    where: "root.html.heex .scope-dataset-badge — dataset pill paints its own --bg-muted fill" },
  // API-tester scenario results (sup-w3): rows ride the Response focus pane
  // (.pane-column--last → --surface-raised); the category header paints its own
  // --bg-muted fill. All three escalate fg-dim → --muted-text at the pairing site.
  { sel: ".scenario-cat-header",                   surface: "--bg-muted",       kind: "text",    where: "root.html.heex .scenario-cat-header — category label paints its own --bg-muted fill" },
  { sel: ".scenario-endpoint",                     surface: "--surface-raised", kind: "text",    where: "root.html.heex .scenario-endpoint — endpoint label on the .pane-column--last Response pane" },
  { sel: ".scenario-duration",                     surface: "--surface-raised", kind: "text",    where: "root.html.heex .scenario-duration — mono duration on the .pane-column--last Response pane" },
];

const AA_THRESH = { text: 4.5, nontext: 3.0 };
let pairChecks = 0;
for (const p of PAIRINGS) {
  const fg = ruleColor(p.sel);
  if (fg.err) { fail(`  Part H FAIL: ${p.sel} — ${fg.err}`); continue; }
  const fgSlot = TOKEN_SLOT[fg.token];
  const bgSlot = TOKEN_SLOT[p.surface];
  if (!fgSlot) { fail(`  Part H FAIL: ${p.sel} — fg token ${fg.token} has no TOKEN_SLOT mapping`); continue; }
  if (!bgSlot) { fail(`  Part H FAIL: ${p.sel} — surface token ${p.surface} has no TOKEN_SLOT mapping`); continue; }
  const need = AA_THRESH[p.kind];
  for (const [name, values] of Object.entries(contrastThemes)) {
    for (const mode of ["light", "dark"]) {
      const fgv = values[`${fgSlot}.${mode}`];
      const bgv = values[`${bgSlot}.${mode}`];
      if (fgv === undefined || bgv === undefined) {
        fail(`  Part H FAIL: ${p.sel} — ${name}/${mode} missing slot (${fgSlot}=${fgv}, ${bgSlot}=${bgv})`);
        continue;
      }
      let ratio;
      try { ratio = contrast(fgv, bgv); }
      catch (e) { fail(`  Part H FAIL: ${p.sel} — ${name}/${mode} contrast() threw (${e.message}); a var() passthrough cannot be a contrast operand`); continue; }
      pairChecks++;
      if (ratio < need - 1e-9)
        fail(`  Part H FAIL: ${p.sel} (${fg.token} on ${p.surface}, ${p.kind}) = ${ratio.toFixed(2)} < ${need} in ${name}/${mode} — ${p.where}`);
    }
  }
}
if (failed === failedBeforeH)
  console.log(`  ok   ${PAIRINGS.length} curated pairings × ${Object.keys(contrastThemes).length} themes × 2 modes = ${pairChecks} checks, all ≥ AA (text 4.5 / nontext 3.0)`);

// ── Part I: the write fence's own predicates, proven able to fail ────────────
// Part A above is the fence's REPORTING half; `run()` in emit.mjs is its
// BLOCKING half. Both rest on exactly two predicates — attribute() and
// lostLines() — and every proof of them so far has been a manual mutation an
// author ran once and reverted. That is the failure mode this whole epic is
// about: an instrument nobody can regress noisily. Neutering attribute() to
// return "attributed" (or lostLines() to return []) would leave every other
// gate in this repo green while the fence quietly stopped fencing.
//
// These are synthetic fixtures, NOT a read of the tree, so they cost nothing
// and cannot flake on real content. They do not cover run()'s all-or-nothing
// pre-flight — that needs a process-level test and a doc-gates.yml entry, and
// is filed as cch-w1-emit-fence-regression-test.
{
  const failedBeforeI = failed;
  console.log("design/check.mjs — Part I: write-fence predicates");
  const region = "a\nb\n";
  const unit = (cur) => ({ path: "fixture/x", currentRegion: cur, expectedRegion: region });
  const digest = regionDigest(region);

  // The three attribution outcomes. If any collapses into "attributed", the
  // fence stops refusing and hand-written content becomes deletable again.
  const cases = [
    ["byte-identical region is attributed", unit(region), { "fixture/x": digest }, "attributed"],
    ["a hand-edited region is UNattributed", unit("a\nb\nhand-written\n"), { "fixture/x": digest }, "unattributed"],
    ["a region with no ledger entry is unknown", unit(region), {}, "unknown"],
    ["an errored/unreadable region is unknown", { path: "fixture/x", error: "boom" }, { "fixture/x": digest }, "unknown"],
  ];
  for (const [what, u, regions, want] of cases) {
    const got = attribute(u, regions);
    if (got !== want) fail(`  Part I FAIL: ${what} — attribute() returned ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
  }

  // lostLines() is what turns a refusal into a USEFUL one: it names the bytes
  // that would die. Returning [] would keep the fence blocking but make it mute,
  // and a mute refusal is the one a developer clears with --force.
  const lost = lostLines("a\nkeep-me\nb\n", region);
  if (lost.length !== 1 || lost[0] !== "keep-me")
    fail(`  Part I FAIL: lostLines() must name the one dropped line, got ${JSON.stringify(lost)}`);
  // A pure token edit drops only the line it truly replaces — not the block.
  const swap = lostLines("--x: #aaa;\n--y: 1;\n", "--x: #bbb;\n--y: 1;\n");
  if (swap.length !== 1 || swap[0] !== "--x: #aaa;")
    fail(`  Part I FAIL: lostLines() over-reported a token edit, got ${JSON.stringify(swap)}`);
  // Blank lines are noise, never "lost work" — reporting them would train
  // readers to skim the list the fence needs them to read.
  if (lostLines("a\n\n\nb\n", region).length !== 0)
    fail(`  Part I FAIL: lostLines() must ignore blank lines, got ${JSON.stringify(lostLines("a\n\n\nb\n", region))}`);

  if (failed === failedBeforeI)
    console.log(`  ok   ${cases.length} attribution outcomes + 3 lostLines properties`);
}

// ── Part J: the AIR scale reaches a real consumer ────────────────────────────
// space.air emits `--tok-air-<step>` onto the paper surface, paper-surface.css
// bridges each onto `--bp-air-<step>`, and the six consumers live in THREE files —
// two of them Elixir renderers that emit the beat as an inline `var(--bp-air-*)`
// on markup this CSS gate would otherwise never see.
//
// That spread is exactly the shape pe-w1-reader-editorial-typography found and
// fixed: `--bp-*-tracking` was declared in tokens.json and consumed NOWHERE, and
// nothing failed, because "single-source" and "single-source and unread" look
// identical until you measure the page. So this part refuses the silence in both
// directions — emitted-but-unbridged, and bridged-but-unconsumed. A step whose
// consumer is deleted (or renamed) reds here instead of quietly flattening the
// reader's evidence spacing back to zero.
console.log("\ndesign/check.mjs — Part J: air-scale consumer census");
{
  const failedBeforeJ = failed;
  const surfaceCss = readFileSync(join(repoRoot, "api/assets/paper-surface/paper-surface.css"), "utf8");
  // Consumers may live in the stylesheet OR inline on renderer output. Both are
  // legitimate: a figure's beat has to survive a stylesheet-less sink, so it
  // rides `var(--bp-air-figure, <fallback>)` in the emitting Elixir source.
  const consumerSources = [
    "api/assets/paper-surface/paper-surface.css",
    "api/lib/barkpark/portable_doc/render/figures.ex",
    "api/lib/barkpark/portable_doc/render/compose.ex",
  ].map((p) => ({ path: p, text: readFileSync(join(repoRoot, p), "utf8") }));

  for (const step of AIR_STEPS) {
    const ratio = tokens.space.air[step];
    // 1. emitted, as a ratio of the beat — never a resolved literal.
    const emitted = new RegExp(`--tok-air-${step}: calc\\(var\\(--tok-air-beat\\) \\* ${String(ratio).replace(".", "\\.")}\\);`);
    if (!emitted.test(surfaceCss))
      fail(`  Part J FAIL: --tok-air-${step} is not emitted as calc(var(--tok-air-beat) * ${ratio}) in paper-surface.css`);

    // 2. bridged onto the --bp-* name every rule reads.
    if (!surfaceCss.includes(`--bp-air-${step}: var(--tok-air-${step});`))
      fail(`  Part J FAIL: --bp-air-${step} has no bridge onto --tok-air-${step} in paper-surface.css`);

    // 3. actually READ by something. The bridge declaration itself is excluded,
    //    so a bridge that only feeds itself does not count as a consumer.
    const hits = consumerSources.flatMap(({ path, text }) =>
      text
        .split("\n")
        .filter((l) => l.includes(`var(--bp-air-${step}`) && !l.includes(`--bp-air-${step}: var(`))
        .map((l) => `${path}: ${l.trim().slice(0, 80)}`),
    );
    if (hits.length === 0)
      fail(
        `  Part J FAIL: --bp-air-${step} is emitted and bridged but NOTHING consumes it.\n` +
          `    A token with no reader is not a single source — it is a dead one. Either give it\n` +
          `    a rule (paper-surface.css) or an inline var() on the emitting renderer, or drop\n` +
          `    the step from space.air + AIR_STEPS.`,
      );
  }
  if (failed === failedBeforeJ)
    console.log(`  ok   ${AIR_STEPS.length} air steps emitted as beat ratios, bridged onto --bp-air-*, and each read by a live consumer`);
}

// ── Part K: the EVIDENCE BAND reaches a real consumer ────────────────────────
// space.evidence emits five `--tok-evidence-*` inputs; paper-surface.css bridges
// each onto `--bp-evidence-*` and composes four of them into ONE derived width,
// which the breakout rules and the article <figure> emitters then read.
//
// That chain has three distinct ways to go quietly dead, and Part J's shape only
// catches the first:
//
//   1. a token emitted and bridged but read by nothing — the pe-w1 defect.
//   2. a token bridged and read ONLY by its own bridge, i.e. dropped out of the
//      `--bp-evidence-width` composition. The band would still resolve, still
//      look plausible, and silently stop honouring (say) the gutter — which is
//      the one term standing between the band and a sideways-scrolling page.
//   3. a breakout rule that takes the WIDTH but not the PULL. The component
//      grows to the right instead of growing about its centre: still wide, still
//      green on any width assertion, and visibly off-axis on the page. So the
//      two are censused as a PAIR, per rule, and a half-breakout reds.
console.log("\ndesign/check.mjs — Part K: evidence-band consumer census");
{
  // Part K counts its OWN failures rather than reading the shared `failed`
  // boolean the parts above it use. That flag is sticky: once ANY earlier part
  // has tripped, `failed === failedBefore<X>` is true again and the part prints
  // its green line beside its own red ones. Proven while mutation-testing this
  // part — dropping the gutter term reds the mirror check first, and Part K then
  // printed both two FAILs and its `ok`. The run still exits 1, so nothing ships
  // on it, but a green line under a red one is the kind of output that teaches a
  // reader to skim. Parts D-J share the pattern and are left alone here: they
  // belong to other changes in flight.
  let kFailed = false;
  const kFail = (msg) => { kFailed = true; fail(msg); };
  const kebab = (s) => s.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
  const surfacePath = "api/assets/paper-surface/paper-surface.css";
  const surfaceCss = readFileSync(join(repoRoot, surfacePath), "utf8");
  // Consumers may live in the stylesheet OR inline on renderer output — a figure
  // has to survive a stylesheet-less sink, so its width and pull ride inline
  // `var(--bp-evidence-*, <fallback>)` in the emitting Elixir source, exactly as
  // its air beat does.
  const consumerSources = [
    surfacePath,
    "api/lib/barkpark/portable_doc/render/figures.ex",
    "api/lib/barkpark/portable_doc/render/compose.ex",
    "api/lib/barkpark/portable_doc/render/components.ex",
  ].map((p) => ({ path: p, text: readFileSync(join(repoRoot, p), "utf8") }));

  const readsOf = (name) =>
    consumerSources.flatMap(({ path, text }) =>
      text
        .split("\n")
        .filter((l) => l.includes(`var(--bp-evidence-${name}`) && !l.includes(`--bp-evidence-${name}: var(`))
        .map((l) => `${path}: ${l.trim().slice(0, 80)}`),
    );

  for (const key of EVIDENCE_KEYS) {
    const name = kebab(key);
    const value = `${tokens.space.evidence[key]}${EVIDENCE_UNITS[key]}`;
    // 1. emitted, with its authored unit — `fill` is a bare ratio and `caption`
    //    is a character count; emitting either as px is the drift this catches.
    if (!surfaceCss.includes(`--tok-evidence-${name}: ${value};`))
      kFail(`  Part K FAIL: --tok-evidence-${name} is not emitted as ${value} in ${surfacePath}`);

    // 2. bridged onto the --bp-* name every rule reads.
    if (!surfaceCss.includes(`--bp-evidence-${name}: var(--tok-evidence-${name});`))
      kFail(`  Part K FAIL: --bp-evidence-${name} has no bridge onto --tok-evidence-${name} in ${surfacePath}`);

    // 3. actually READ. The bridge line itself is excluded, so a bridge that only
    //    feeds itself does not count as a consumer.
    if (readsOf(name).length === 0)
      kFail(
        `  Part K FAIL: --bp-evidence-${name} is emitted and bridged but NOTHING consumes it.\n` +
          `    A token with no reader is not a single source — it is a dead one. Either fold it\n` +
          `    into the --bp-evidence-width composition, give it a rule, or drop it from\n` +
          `    space.evidence + EVIDENCE_KEYS in design/emit.mjs.`,
      );
  }

  // The derived pair. `width` composes the four geometry inputs; `pull` re-centres
  // the wider box on the column's axis. Neither is a token — both are the law —
  // so they are censused for consumers the same way.
  const widthDecl = surfaceCss.split("\n").find((l) => l.includes("--bp-evidence-width: "));
  if (!widthDecl) {
    kFail(`  Part K FAIL: ${surfacePath} declares no --bp-evidence-width — the band has no composed law`);
  } else {
    for (const key of ["band", "bandMax", "fill", "gutter"]) {
      const name = kebab(key);
      if (!widthDecl.includes(`var(--bp-evidence-${name})`))
        kFail(
          `  Part K FAIL: --bp-evidence-width does not read --bp-evidence-${name}.\n` +
            `    The band would still resolve and still look plausible while silently ignoring\n` +
            `    that term — and 'gutter' is the only thing keeping the band off the viewport edge.`,
        );
    }
  }
  for (const derived of ["width", "pull"]) {
    if (readsOf(derived).length === 0)
      kFail(`  Part K FAIL: --bp-evidence-${derived} is composed but NOTHING consumes it — the band is computed and never applied`);
  }

  // The shipped breakout SET, each rule censused for the width/pull PAIR. These
  // are the components the wave decided improve with width; a class listed here
  // that stops breaking out reds, and so does one that breaks out by half.
  const BREAKOUT_RULES = [".bp-table", ".bp-stats", ".bp-chart", ".bp-diff", ".bp-filetree"];
  for (const cls of BREAKOUT_RULES) {
    const rule = surfaceCss
      .split("}")
      .find((block) => block.includes(`.bp-paper-surface ${cls} {`) || block.includes(`.bp-paper-surface ${cls},`));
    if (!rule) {
      kFail(`  Part K FAIL: no .bp-paper-surface ${cls} rule in ${surfacePath} — the breakout set names a component that is not styled here`);
      continue;
    }
    for (const half of ["width", "pull"]) {
      if (!rule.includes(`var(--bp-evidence-${half}`))
        kFail(
          `  Part K FAIL: .bp-paper-surface ${cls} does not read --bp-evidence-${half}.\n` +
            `    A component takes the band's width and its centring pull TOGETHER; with only\n` +
            `    one it grows off-axis instead of about the column's centre.`,
        );
    }
  }

  // The four article <figure> emitters carry the same pair inline. Counted, not
  // just found: three of the four live in figures.ex and one in compose.ex, and a
  // figure family that silently loses the breakout is exactly the regression the
  // count catches.
  const figureBreakouts = consumerSources
    .filter(({ path }) => path.endsWith(".ex"))
    .flatMap(({ text }) => text.split("\n").filter((l) => l.includes("<figure style=") && l.includes("--bp-evidence-width")));
  if (figureBreakouts.length !== 4)
    kFail(
      `  Part K FAIL: ${figureBreakouts.length} article <figure> emitter(s) carry the evidence breakout, expected 4\n` +
        `    (diagram + asciicast + video in render/figures.ex, generic figure in render/compose.ex).`,
    );

  // diff + filetree are INLINE-produced breakouts. Their emitters write the whole
  // box as an inline `style=`, which beats any class rule, so the pair has to be
  // on the EMITTER — and the CSS rule that mirrors it must agree. Censusing only
  // the stylesheet would have called the half-breakout green: measured, the diff
  // took the band's width from CSS, left the pull to an inline `margin: 4px 0`,
  // and overflowed the page by 110px.
  const componentsEx = consumerSources.find(({ path }) => path.endsWith("components.ex")).text;
  for (const cls of ["bp-diff", "bp-filetree"]) {
    const line = componentsEx.split("\n").find((l) => l.includes(`<div class="${cls} `));
    if (!line) {
      kFail(`  Part K FAIL: no <div class="${cls} …"> emitter found in render/components.ex`);
      continue;
    }
    for (const half of ["width", "pull"]) {
      if (!line.includes(`var(--bp-evidence-${half}`))
        kFail(
          `  Part K FAIL: the ${cls} emitter's inline style does not read --bp-evidence-${half}.\n` +
            `    An inline style beats the class rule, so declaring one half in CSS and leaving the\n` +
            `    other to the emitter grows the component off-axis instead of about the column.`,
        );
    }
  }

  if (!kFailed)
    console.log(
      `  ok   ${EVIDENCE_KEYS.length} evidence tokens emitted with their authored units, bridged onto --bp-evidence-*, ` +
        `all four geometry terms folded into one composed width, and ${BREAKOUT_RULES.length} breakout rules + 4 article figures reading the width/pull pair`,
    );
}

// ── Part L: the SECTION BOUNDARY reaches a real consumer, on BOTH surfaces ───
// space.section emits `--tok-section-{beat,rule,gap}`, each surface bridges them
// onto `--bp-section-*`, and ONE declaration per surface spends all three on the
// section head. Part J's shape (emitted → bridged → read) is necessary here and
// not sufficient, because this device is a TWIN: the reader's
// `.bp-paper-surface > #paper-body > h2` and the editor's
// `.bp-paper-editor-body > h2` are two hand-maintained declarations of one law,
// and the way this fails is not a deleted token — it is one surface keeping the
// air while the other keeps the rule, which every per-surface census passes.
//
// So Part L checks the three tokens on BOTH surfaces AND that each surface's
// section-head declaration spends all three properties, AND that the reader
// carries the keyed-stream leg — the one that actually ships (bulldocs_live.ex
// wraps every top-level block in a class-less div; a reader rule written only
// against the flat shape is dead on the live page and green in every gate that
// does not look at the selector).
console.log("\ndesign/check.mjs — Part L: section-boundary consumer census");
{
  let lFailed = 0;
  const lFail = (m) => { console.error(m); lFailed++; failed++; };

  const SECTION_SURFACES = [
    { path: "api/assets/paper-surface/paper-surface.css", head: ".bp-paper-surface > #paper-body > h2" },
    { path: "api/assets/paper-editor/src/styles.css", head: ".bp-paper-editor-body > h2" },
  ];
  // The three properties that make the device. Air without a rule is a long
  // pause; a rule without the gap is underlined text. A surface that declares
  // two of three has a HALF device, which is the exact drift a twin invites.
  const HEAD_PROPS = [
    ["margin-top", "beat"],
    ["border-top", "rule"],
    ["padding-top", "gap"],
  ];

  for (const { path, head } of SECTION_SURFACES) {
    const css = readFileSync(join(repoRoot, path), "utf8");

    for (const key of SECTION_KEYS) {
      const value =
        key === "beat"
          ? `calc(var(--tok-air-beat) * ${String(tokens.space.section.beat).replace(".", "\\.")})`
          : `${tokens.space.section[key]}${SECTION_UNITS[key]}`;
      // 1. emitted — `beat` as a ratio of the air beat, never a resolved pixel,
      //    so section rhythm cannot drift away from evidence rhythm.
      if (!new RegExp(`--tok-section-${key}: ${value.replace(/[()*]/g, "\\$&")};`).test(css))
        lFail(`  Part L FAIL: --tok-section-${key} is not emitted as ${value} in ${path}`);
      // 2. bridged onto the --bp-* name the rules read.
      if (!css.includes(`--bp-section-${key}: var(--tok-section-${key});`))
        lFail(`  Part L FAIL: --bp-section-${key} has no bridge onto --tok-section-${key} in ${path}`);
      // 3. actually READ (the bridge declaration itself excluded, so a bridge
      //    feeding only itself does not count as a consumer).
      const read = css
        .split("\n")
        .some((l) => l.includes(`var(--bp-section-${key}`) && !l.includes(`--bp-section-${key}: var(`));
      if (!read)
        lFail(
          `  Part L FAIL: --bp-section-${key} is emitted and bridged in ${path} but NOTHING consumes it.\n` +
            `    A token with no reader is not a single source — it is a dead one. Either spend it on\n` +
            `    the ${head} rule, or drop it from space.section + SECTION_KEYS in design/emit.mjs.`,
        );
    }

    // 4. the section-head declaration exists on this surface and is WHOLE.
    const at = css.indexOf(head);
    if (at === -1) {
      lFail(`  Part L FAIL: ${path} has no ${head} rule — this surface has no section head at all`);
      continue;
    }
    const block = css.slice(at, css.indexOf("}", at) + 1);
    for (const [prop, key] of HEAD_PROPS) {
      if (!new RegExp(`${prop}:[^;]*var\\(--bp-section-${key}\\)`).test(block))
        lFail(
          `  Part L FAIL: the ${head} rule in ${path} does not set ${prop} from --bp-section-${key}.\n` +
            `    The section boundary is air + rule + gap TOGETHER; two of the three is a half device,\n` +
            `    and a half device on ONE surface is View<->Edit drift that every other gate passes.`,
        );
    }
  }

  // 5. the reader's keyed-stream leg. bulldocs_live.ex streams each top-level
  //    block as a class-less `<div id data-block-id>`, so `#paper-body > h2`
  //    alone matches only the legacy whole-body path and the render rig — the
  //    live reader would show no section heads and nothing here would notice.
  const surfaceCss = readFileSync(join(repoRoot, "api/assets/paper-surface/paper-surface.css"), "utf8");
  if (!surfaceCss.includes(".bp-paper-surface > #paper-body > div:not([class]) > h2"))
    lFail(
      `  Part L FAIL: paper-surface.css has no keyed-stream leg for the section head.\n` +
        `    The block-backed reader wraps every top-level block in <div id data-block-id> — without\n` +
        `    \`> #paper-body > div:not([class]) > h2\` the device is dead on the page that ships.`,
    );

  if (!lFailed)
    console.log(
      `  ok   ${SECTION_KEYS.length} section tokens emitted, bridged and consumed on both the reader and the editor surface, ` +
        `each head spending all three on one declaration, and the reader carrying its keyed-stream leg`,
    );
}

// ── Part M: the RULE LADDER — one weight for structure, one for everything ───
// space.rule emits `--tok-rule-hairline`, each surface bridges it onto
// `--bp-rule-hairline`, and the rules that draw chrome spend it. That is Part J's
// shape and Part J's shape alone would be satisfied by a stylesheet where the
// token is consumed in one place and every OTHER line still draws 2px from a
// literal — which is precisely the state this part was written to end.
//
// So Part M has a second arm the other consumer censuses do not: it reads every
// HORIZONTAL border declaration in both stylesheets and refuses any literal at or
// above the structural weight, wherever it appears. That is the arm that can see
// what a photograph cannot. The rig's census (tooling/paper-excellence/rig/shoot.mjs)
// counts the rules that PAINT on the seven committed fixtures — authoritative
// about what ships, and blind to a heavy rule on a class no fixture happens to
// render. `.bp-board__col` was exactly that: a 3px accent across a task board, in
// none of the seven papers. Neither arm subsumes the other; a declaration census
// alone would miss an inline style, a rendered census alone would miss this.
//
// VERTICAL edges are deliberately not censused. A left edge is a margin accent —
// the verdict colour `.bp-callout`, `.bp-card` and `.bp-board__col` all carry, and
// the benchmark artifact's own `border-left: 3px` device — and it cannot compete
// with a horizontal boundary because it does not draw a horizontal line.
console.log("\ndesign/check.mjs — Part M: rule-ladder consumer census + heavy-declaration scan");
{
  let mFailed = 0;
  const mFail = (m) => { console.error(m); mFailed++; failed++; };

  const RULE_SURFACES = [
    "api/assets/paper-surface/paper-surface.css",
    "api/assets/paper-editor/src/styles.css",
  ];

  // ── arm 1: the token reaches a real consumer on both surfaces ──────────────
  for (const path of RULE_SURFACES) {
    const css = readFileSync(join(repoRoot, path), "utf8");
    for (const key of RULE_KEYS) {
      const value = `${tokens.space.rule[key]}${RULE_UNITS[key]}`;
      if (!css.includes(`--tok-rule-${key}: ${value};`))
        mFail(`  Part M FAIL: --tok-rule-${key} is not emitted as ${value} in ${path}`);
      if (!css.includes(`--bp-rule-${key}: var(--tok-rule-${key});`))
        mFail(`  Part M FAIL: --bp-rule-${key} has no bridge onto --tok-rule-${key} in ${path}`);
      const read = css
        .split("\n")
        .some((l) => l.includes(`var(--bp-rule-${key}`) && !l.includes(`--bp-rule-${key}: var(`));
      if (!read)
        mFail(
          `  Part M FAIL: --bp-rule-${key} is emitted and bridged in ${path} but NOTHING consumes it.\n` +
            `    Every chrome rule on this surface is then drawing a hardcoded weight, which is the\n` +
            `    drift the token exists to prevent. Spend it, or drop it from space.rule + RULE_KEYS.`,
        );
    }
  }

  // ── arm 2: no horizontal border literal at or above the structural weight ──
  // Only the section head may declare one, and it declares it through
  // `--bp-section-rule` rather than a literal, so the allowlist is empty by
  // construction: there is no legitimate literal.
  const HEAVY_PX = tokens.space.section.rule;
  // `border`, `border-top`, `border-bottom` and their `-width` forms. NOT
  // `border-left/right` (a margin accent is not a rule), and not `border-radius`
  // — the `(?![a-z-])` is what keeps `radius`, `color` and `style` out.
  const HORIZONTAL_BORDER = /border(?:-top|-bottom)?(?:-width)?(?![a-z-])\s*:\s*([^;}]*)/g;
  for (const path of RULE_SURFACES) {
    const css = readFileSync(join(repoRoot, path), "utf8").replace(/\/\*[\s\S]*?\*\//g, " ");
    for (const [, selector, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      for (const [decl, value] of body.matchAll(HORIZONTAL_BORDER)) {
        const px = /(\d*\.?\d+)px/.exec(value);
        if (!px || parseFloat(px[1]) < HEAVY_PX) continue;
        mFail(
          `  Part M FAIL: ${path} declares a ${px[1]}px HORIZONTAL rule outside the section head:\n` +
            `      ${selector.trim().replace(/\s+/g, " ").slice(0, 110)}\n` +
            `        ${decl.trim().slice(0, 90)}\n` +
            `    ${HEAVY_PX}px is the STRUCTURAL weight (space.section.rule) and a section boundary is the\n` +
            `    only thing allowed to spend it — a component drawing at that weight makes the boundary\n` +
            `    stop meaning anything. Use var(--bp-rule-hairline) for chrome; if the line carries a\n` +
            `    VERDICT rather than structure, put it on the left edge where .bp-callout and .bp-card\n` +
            `    already carry theirs, and it leaves this census by being vertical.`,
        );
      }
    }
  }

  if (!mFailed)
    console.log(
      `  ok   --tok-rule-hairline emitted, bridged and consumed on both surfaces, and neither stylesheet ` +
        `declares a horizontal border at or above the ${HEAVY_PX}px structural weight`,
    );
}

// Newline-preserving noise blanker for Part N. Deliberately SEPARATE from Part
// E's stripLedgerNoise: this ledger also reads `.ex` (the login page's CSS lives
// in a heredoc) and `.html` (the styleguide), and teaching the shared helper
// those extensions would silently move every frozen COLOUR baseline.
const motionBlank = (m) => m.replace(/[^\n]/g, " ");
// Comments only. Arm 1 uses this one and NOT the generated-region blanker, for the
// obvious reason that the declarations it is looking for live inside those regions.
function motionBlankComments(text, path) {
  let s = text.replace(/\/\*[\s\S]*?\*\//g, motionBlank); // CSS / <style> block comments
  if (/\.(heex|html)$/.test(path)) {
    s = s
      .replace(/<!--[\s\S]*?-->/g, motionBlank)
      .replace(/<%!--[\s\S]*?--%>/g, motionBlank)
      .replace(/<%#[\s\S]*?%>/g, motionBlank);
  }
  return s;
}
// Arm 2 additionally blanks every BEGIN/END GENERATED region: a duration the
// emitter wrote is not a hand-stamp.
const motionBlankAll = (text, path) =>
  motionBlankComments(text.replace(LEDGER_MARKER, motionBlank), path);

// ── Part N: motion-ladder parity + hand-typed duration ratchet ───────────────
// The motion twin of Part C (type-scale parity) and Part E (the colour-literal
// ratchet). tokens.json has carried motion.dur-1/-2/-3 since the first token
// file and design/emit.mjs emitted NONE of it: `grep -rn -- "--dur-" api/`
// returned exactly one hit, a COMMENT in root.html.heex explaining that a
// var(--dur-1) there would resolve to nothing. Every Studio transition was a
// hand-typed literal and nothing could see them, because the only literal census
// in this file counts COLOURS. spd-b21 emits the ladder; this part is what keeps
// it from decaying back.
//
// ── arm 1: parity + no shadow ────────────────────────────────────────────────
// For every surface on MOTION_SURFACES, each `--dur-N` must be declared with the
// tokens.json byte and declared EXACTLY ONCE. The uniqueness half is not
// pedantry: a second declaration LATER in the same file wins the cascade, so a
// hand-authored copy would keep painting while the generated one — the thing this
// gate reads — sits inert. A value-only assertion would report green while the
// surface ignored the token entirely.
//
// The ONE legitimate re-declaration is the reduced-motion collapse
// (`@media (prefers-reduced-motion: reduce) { :root { --dur-N: 0s } }`), which
// zeroes the ladder rather than shadowing it. It is recognised by its VALUE
// (`0s`) — not by an allowlist of paths — so it stays available to every surface
// and cannot be stretched to cover a literal that actually paints.
//
// ── arm 2: the hand-typed duration ratchet ───────────────────────────────────
// Exactly Part E's shape, over time instead of colour. design/exemptions.json
// `motion.entries` freezes the count of hand-typed duration literals per surface;
// any drift fails, up OR down, and the baseline must move in the same diff.
//
// COUNTING RULE (documented next to the implementation, as Part E's is):
//   A "duration literal" is a `<number>s` or `<number>ms` appearing inside the
//   VALUE of a `transition` / `transition-duration` / `transition-delay` /
//   `animation` / `animation-duration` / `animation-delay` declaration. A
//   `var(--dur-N)` is not a number and so is not counted — which is precisely
//   what lets a literal→token sweep register as a SHRINK. Times outside a motion
//   declaration are invisible here on purpose: `PUSH_TIMEOUT is 30000ms` in a
//   comment, a `phx-remove` JS `time: 320`, and a `<meta http-equiv="refresh">`
//   are not motion design. Before counting, the same two noise sources Part E
//   blanks are blanked (newline-preserving): every BEGIN/END GENERATED region —
//   an emitted duration is not a hand-stamp — and comments. Part E's
//   stripLedgerNoise is NOT reused: this ledger also scans `.ex` (the login
//   heredoc) and `.html` (the styleguide), which Part E's rule does not strip,
//   and widening the shared helper would silently move every colour baseline.
console.log("\ndesign/check.mjs — Part N: motion-ladder parity + hand-typed duration ratchet");
{
  let nFailed = 0;
  const nFail = (m) => { console.error(m); nFailed++; failed++; };

  // ── arm 1: the ladder reaches every emitting surface, exactly once ─────────
  const unit = tokens.motion._unit;
  for (const path of MOTION_SURFACES) {
    let text;
    try { text = readFileSync(join(repoRoot, path), "utf8"); }
    catch (e) { nFail(`  Part N FAIL: ${path} — cannot read (${e.message})`); continue; }
    const src = motionBlankComments(text, path);
    for (const step of MOTION_STEPS) {
      const want = `${tokens.motion[step]}${unit}`;
      const decls = [...src.matchAll(new RegExp(`--${step}\\s*:\\s*([^;}]+)`, "g"))]
        .map((m) => m[1].trim());
      // The reduced-motion collapse zeroes the ladder; it is not a shadow.
      const painting = decls.filter((v) => v !== "0s");
      if (painting.length === 0) {
        nFail(
          `  Part N FAIL: ${path} declares no --${step}.\n` +
            `    It is on MOTION_SURFACES in design/emit.mjs — it draws transitions, so the ladder\n` +
            `    has to reach it. Most entries get it from the GENERATED block (\`node design/emit.mjs\n` +
            `    --write\`); cloud/priv/static/app.css declares it by hand in its decision-29 token\n` +
            `    area. Restore whichever applies, or drop the surface from the list if it genuinely\n` +
            `    no longer consumes durations.`,
        );
        continue;
      }
      if (painting.length > 1) {
        nFail(
          `  Part N FAIL: ${path} declares --${step} ${painting.length} times ` +
            `(${painting.map((v) => JSON.stringify(v)).join(", ")}).\n` +
            `    The LAST one wins the cascade, so a hand-authored copy keeps painting while the\n` +
            `    emitted declaration this gate reads sits inert — a token that is decorative again.\n` +
            `    Delete the hand copy and let the GENERATED block own the value. (A\n` +
            `    \`@media (prefers-reduced-motion: reduce)\` collapse to \`0s\` is exempt: it zeroes\n` +
            `    the ladder rather than replacing it.)`,
        );
        continue;
      }
      if (painting[0] !== want)
        nFail(
          `  Part N FAIL: ${path} declares --${step}: ${painting[0]} ≠ ` +
            `tokens.motion["${step}"] ${want}`,
        );
    }
  }

  // ── arm 2: the hand-typed duration ratchet ────────────────────────────────
  const MOTION_DECL = /\b(?:transition|animation)(?:-duration|-delay)?\s*:\s*([^;{}]*)/gi;
  const MOTION_LITERAL = /(?<![\w.-])\d*\.?\d+m?s(?![\w-])/gi;

  function countMotionLiterals(path) {
    const src = motionBlankAll(readFileSync(join(repoRoot, path), "utf8"), path);
    let n = 0;
    for (const m of src.matchAll(MOTION_DECL)) n += (m[1].match(MOTION_LITERAL) || []).length;
    return n;
  }

  const motionLedger = (ledger.motion && ledger.motion.entries) || [];
  if (motionLedger.length === 0)
    nFail("  Part N FAIL: design/exemptions.json carries no `motion.entries` — the ratchet has nothing to hold");

  const rows = [];
  let baseTotal = 0, actualTotal = 0;
  for (const entry of motionLedger) {
    let actual;
    try { actual = countMotionLiterals(entry.path); }
    catch (e) { nFail(`  Part N FAIL: ${entry.path} — cannot count (${e.message})`); continue; }
    const baseline = entry.count;
    baseTotal += baseline;
    actualTotal += actual;
    const delta = actual - baseline;
    rows.push({ path: entry.path, baseline, actual, delta });
    if (delta > 0)
      nFail(
        `  Part N FAIL: ${entry.path} GREW ${baseline} → ${actual} (+${delta}). A new hand-typed ` +
          `duration literal landed in a transition/animation declaration. Spend a ladder rung — ` +
          `var(--dur-1|--dur-2|--dur-3) — from the emitted GENERATED block; if the timing is ` +
          `genuinely off-ladder (a spinner loop, a long attention pulse), RAISE the baseline in ` +
          `design/exemptions.json IN THIS SAME DIFF with a note saying which literal and why.`,
      );
    else if (delta < 0)
      nFail(
        `  Part N FAIL: ${entry.path} SHRANK ${baseline} → ${actual} (${delta}) — a duration was ` +
          `tokenized (good!). LOWER the baseline to ${actual} in design/exemptions.json IN THIS ` +
          `SAME DIFF so the ratchet holds.`,
      );
  }

  {
    const pad = (s, n) => String(s).padEnd(n);
    const wPath = Math.max(4, ...rows.map((r) => r.path.length));
    console.log(`  ${pad("path", wPath)}  baseline  actual  delta`);
    for (const r of rows) {
      const mark = r.delta === 0 ? "ok  " : r.delta > 0 ? "GREW" : "SHRUNK";
      const d = r.delta > 0 ? `+${r.delta}` : String(r.delta);
      console.log(`  ${pad(r.path, wPath)}  ${pad(r.baseline, 8)}  ${pad(r.actual, 6)}  ${pad(d, 5)} ${mark}`);
    }
    console.log(`  ${pad("TOTAL", wPath)}  ${pad(baseTotal, 8)}  ${pad(actualTotal, 6)}`);
  }

  if (!nFailed)
    console.log(
      `  ok   the ${MOTION_STEPS.length}-rung motion ladder reaches ${MOTION_SURFACES.length} surface(s) ` +
        `with tokens.json's bytes and no shadow declaration; ${rows.length} ledgered surface(s), ` +
        `${actualTotal} hand-typed duration literal(s) frozen — none grew, none silently shrank`,
    );
}

// ── verdict ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error(unattributedSeen
    ? "\ndesign/check.mjs: FAILED — a generated region holds content design/emit.mjs never wrote (or a surface has drifted from design/tokens.json)."
    // Parts B–I are not drift checks (parity, contrast, fence predicates), so
    // naming drift here would send the reader to the wrong file. Say what the
    // gate actually knows: something above failed, and it is labelled.
    : "\ndesign/check.mjs: FAILED — see the labelled failure(s) above.");
  process.exit(1);
}
console.log(`\ndesign/check.mjs: PASS — ${ARTIFACTS.length} surfaces in lockstep + §6 lifecycle parity holds, every generated region attributed to design/emit.mjs.`);
