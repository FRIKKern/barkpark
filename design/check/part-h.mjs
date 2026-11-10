// design/check/part-h.mjs — Part H of design/check.mjs, the W1.2 drift gate.
// design/check.mjs runs every design/check/part-*.mjs in order; this module runs
// its Part when imported. Moved out of check.mjs with no change in behaviour.

import { contrast, derive } from "../derive.mjs";
import { repoRoot } from "../emit.mjs";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fail, failed, FAULT } from "./state.mjs";
import { RAW_SURFACE_PATH, readDesignSource } from "./part-e.mjs";
import { themeCache, themeFiles } from "./part-f.mjs";

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
// per root.html.heex's alias block (--bg-muted→muted-surface, --fg-muted→muted-text,
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
if (FAULT.has("H")) fail("  Part H FAIL: injected fault (--selftest)");
if (failed === failedBeforeH)
  console.log(`  ok   ${PAIRINGS.length} curated pairings × ${Object.keys(contrastThemes).length} themes × 2 modes = ${pairChecks} checks, all ≥ AA (text 4.5 / nontext 3.0)`);

// ── Part H (verdict arm): the loss/peace inks on the READING page ────────────
// The pairings above are Studio-shell selectors read out of root.html.heex. The
// VERDICT pair (color.verdict — pe-bl-verdict-accent-tokens) never appears there:
// it lands inside `.bp-paper-surface`, so its curated pairings are read out of
// api/assets/paper-surface/paper-surface.css instead. Same gate, same AA floor,
// different sheet.
//
// TWO grounds per ink, and both are required:
//   • ink on its OWN soft ground — a verdict callout fills the soft wash and
//     paints the text/rail in the ink.
//   • ink on the bare reading page (paper.surface.bg) — a verdict stat VALUE
//     paints the digits straight onto the tile with no wash under them.
// derive.mjs walks the ink against soft only (soft is the worse ground in both
// modes). That is an ARGUMENT; this arm is the MEASUREMENT, and it measures the
// page pairing separately so the argument cannot quietly stop being true.
//
// The foreground token is read LIVE out of the committed rule body, exactly as
// ruleColor() does for the Studio sheet — so deleting or re-pointing
// `.bp-stat__v--loss` / `.bp-callout--peace` reds HERE. That is what makes these
// tokens consumed rather than merely declared: the named test that fails if the
// consumption goes away is `node design/check.mjs` Part H, this arm.
{
  const surfaceCssH = readDesignSource(RAW_SURFACE_PATH);
  // Same shape as ruleColor(), pointed at the paper-surface sheet.
  const surfaceRuleColor = (sel) => {
    const esc = sel.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const m = surfaceCssH.match(new RegExp(`(?:^|\\n)[ \\t]*${esc}[ \\t]*\\{([\\s\\S]*?)\\}`));
    if (!m) return { err: `rule not found in paper-surface.css: ${sel}` };
    const c = m[1].match(/color:\s*var\((--[\w-]+)(?:\s*,[^)]*)?\)/);
    if (!c) return { err: `no "color: var(--…)" in rule ${sel}` };
    return { token: c[1] };
  };
  // --bp-verdict-* / --paper-* CSS var → derive SLOTS slot (mode appended below).
  const VERDICT_SLOT = {
    "--bp-verdict-loss": "verdict.loss",
    "--bp-verdict-peace": "verdict.peace",
    "--bp-verdict-loss-soft": "verdict.loss-soft",
    "--bp-verdict-peace-soft": "verdict.peace-soft",
    "--paper-bg": "paper.surface.bg",
    "--paper-bg-deep": "paper.surface.bg-deep",
  };
  const VERDICT_PAIRINGS = [
    { sel: ".bp-paper-surface .bp-callout--loss",  surface: "--paper-bg",  kind: "text", where: "paper-surface.css .bp-callout--loss — the quiet card has no wash: the ink sits on the page (2026-10-05)" },
    { sel: ".bp-paper-surface .bp-callout--peace", surface: "--paper-bg", kind: "text", where: "paper-surface.css .bp-callout--peace — the quiet card has no wash: the ink sits on the page (2026-10-05)" },
    { sel: ".bp-paper-surface .bp-stat__v--loss",  surface: "--paper-bg-deep",         kind: "text", where: "paper-surface.css .bp-stat — the KPI tile's ground is --paper-bg-deep, no wash under the digits" },
    { sel: ".bp-paper-surface .bp-stat__v--peace", surface: "--paper-bg-deep",         kind: "text", where: "paper-surface.css .bp-stat — the KPI tile's ground is --paper-bg-deep, no wash under the digits" },
    { sel: ".bp-paper-surface .bp-stat__v--loss",  surface: "--paper-bg",              kind: "text", where: "paper-surface.css — a bare stat outside a tile falls back to the page ground" },
    { sel: ".bp-paper-surface .bp-stat__v--peace", surface: "--paper-bg",              kind: "text", where: "paper-surface.css — a bare stat outside a tile falls back to the page ground" },
  ];
  let verdictChecks = 0;
  for (const p of VERDICT_PAIRINGS) {
    const fg = surfaceRuleColor(p.sel);
    if (fg.err) { fail(`  Part H FAIL: ${p.sel} — ${fg.err}`); continue; }
    const fgSlot = VERDICT_SLOT[fg.token];
    const bgSlot = VERDICT_SLOT[p.surface];
    if (!fgSlot) { fail(`  Part H FAIL: ${p.sel} — fg token ${fg.token} has no VERDICT_SLOT mapping (the rule stopped reading a verdict ink)`); continue; }
    if (!bgSlot) { fail(`  Part H FAIL: ${p.sel} — surface token ${p.surface} has no VERDICT_SLOT mapping`); continue; }
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
        catch (e) { fail(`  Part H FAIL: ${p.sel} — ${name}/${mode} contrast() threw (${e.message})`); continue; }
        verdictChecks++;
        if (ratio < need - 1e-9)
          fail(`  Part H FAIL: ${p.sel} (${fg.token} on ${p.surface}, ${p.kind}) = ${ratio.toFixed(2)} < ${need} in ${name}/${mode} — ${p.where}`);
      }
    }
  }
  if (failed === failedBeforeH)
    console.log(`  ok   verdict arm: ${VERDICT_PAIRINGS.length} loss/peace pairings (ink on soft wash + ink on page) × ${Object.keys(contrastThemes).length} themes × 2 modes = ${verdictChecks} checks, all ≥ AA 4.5`);
}
