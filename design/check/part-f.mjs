// design/check/part-f.mjs — Part F of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { derive, PASSTHROUGH_FAMILIES, SLOTS } from "../derive.mjs";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fail, failed, FAULT } from "./state.mjs";
import { want } from "./part-b.mjs";
import { here } from "./part-e.mjs";

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
// CHARACTERIZATION-FROZEN as pins (a fresh theme re-hues natively). MEMBERSHIP is
// NOT this map's to decide: every design/themes/*.json MUST have an entry, and a
// theme without one is a hard FAIL below, so a sixth committed theme cannot land
// un-ratcheted in silence. The map supplies the NUMBER; the directory listing
// supplies the ROSTER. (Fixture themes are handed to derive() directly by tests
// and never reach this loop, which reads design/themes/ off disk.)
const OVERRIDE_COUNT_FROZEN = { evergreen: 79, ember: 3, fjord: 3, charple: 2, iris: 0 };

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

// Part F's two PER-THEME ok lines need a PER-THEME delta, not the part-level
// `failed === failedBeforeF` the part summary uses. `themeFaults[f]` counts the
// failures THIS theme file recorded, across BOTH loops below: the schema loop adds
// its own delta, the resolve loop reads that total back and adds its own. A theme
// that fails its shape gate therefore withholds BOTH of its ok lines — its
// `complete (0 unresolved)` line asserts a verdict about a file whose own FAIL two
// lines above says it is broken — while every OTHER theme keeps both of its true
// ok lines. The part-level snapshot is the WRONG gate here for exactly that
// reason: it would silence four healthy themes over one broken one.
const themeFaults = {};
const themeCache = {};
for (const f of themeFiles) {
  const snap = failed;
  let theme;
  try { theme = JSON.parse(readFileSync(join(themesDir, f), "utf8")); }
  catch (e) { fail(`  Part F FAIL: ${f} is not valid JSON — ${e.message}`); themeFaults[f] = failed - snap; continue; }
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
  themeFaults[f] = failed - snap;
  if (failed === snap)
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
  // Per-theme delta again, AND the schema loop's verdict for this same file: a
  // theme whose shape gate failed has no business printing "complete".
  const snap = failed;
  const schemaFaults = themeFaults[f] || 0;
  const name = theme.name || f.replace(/\.json$/, "");
  const frozen = OVERRIDE_COUNT_FROZEN[name];
  // COVERAGE, not membership. `frozen === undefined` used to mean "not ratcheted"
  // silently, so a SIXTH committed theme was un-ratcheted the day it landed and no
  // output said so (proven 2026-09-16: design/themes/w8probe.json derived 3 pins,
  // Part F printed its ok line and its PASS verdict; adding `w8probe: 0` to the map
  // immediately red the same run). Every design/themes/*.json must carry an entry;
  // the map supplies the NUMBER, the directory supplies the MEMBERSHIP.
  if (frozen === undefined)
    fail(
      `  Part F FAIL: ${name} (design/themes/${f}) has no OVERRIDE_COUNT_FROZEN entry — its override count is NOT ratcheted. ` +
      "Add an entry for it to OVERRIDE_COUNT_FROZEN in design/check.mjs IN THIS SAME DIFF (its live pin count is on this theme's ok line below).",
    );

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
  if (failed === snap && schemaFaults === 0)
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

if (FAULT.has("F")) fail("  Part F FAIL: injected fault (--selftest)");
if (failed === failedBeforeF)
  console.log("  ok   Part F PASS — the theme compiler reproduces evergreen byte-for-byte; adding theme N+1 is one more design/themes/*.json.");

export { themeCache, themeFiles };
