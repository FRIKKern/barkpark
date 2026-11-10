// design/emit/web.mjs — the web demo, starter-template and web TS token surfaces.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { loadThemes, THEME_BANNER, themeBlocks, tokens } from "./source.mjs";
import { BASE_ROLES, CALLOUT_TONES, hsl, motionVarLines, READING_STEPS, STATUS_ROLES, TYPE_STEPS } from "./vocab.mjs";

// ── surface: web demo (web/app/globals.css — Tailwind v4 @theme) ─────────────
// Light values register in a top-level @theme (Tailwind v4 requires @theme stay
// top-level — you cannot nest it under a selector or media query). Dark is an
// EXPLICIT [data-theme="dark"] override that redefines the same --color-* the
// theme registered; equal specificity to @theme's :root, but it comes LATER so
// it wins the cascade — mirroring cloudBlock()'s :root/[data-theme] pair. The
// OS-only @media block is intentionally dropped: default theme comes from the
// data-theme island (seeded from prefers-color-scheme), so the explicit toggle
// is the single source of truth and always wins.
// Web theme block: the @theme registration must stay TOP-LEVEL (Tailwind v4
// forbids nesting it), so per-theme values are plain [data-bp-theme=X] selectors
// that redefine the same --color-* the theme registered. Light on the attribute,
// dark on the +[data-theme=dark] compound (one step more specific, so it wins
// over both the bare [data-theme=dark] and the theme-light block).
const webThemeBlock = (name, t) => {
  const st = t.color.status;
  return [
    `[data-bp-theme="${name}"] {`,
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(t.color[r].light)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].light)};`),
    "}",
    `[data-bp-theme="${name}"][data-theme="dark"] {`,
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(t.color[r].dark)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].dark)};`),
    "}",
  ].join("\n");
};

function webBlock(themes = loadThemes()) {
  const st = tokens.color.status;
  const lines = [
    "@theme {",
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(tokens.color[r].light)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].light)};`),
    // Theme-INVARIANT always-dark graph canvas (color.graphCanvas, a D21
    // passthrough — single hex, errorPage precedent). Registered in @theme so
    // Tailwind v4 auto-generates bg-graph-canvas; deliberately NO dark/theme
    // override — the Obsidian graph panel never flips.
    `  --color-graph-canvas: ${tokens.color.graphCanvas.canvas};`,
    // Motion ladder — theme-invariant, so it registers once in @theme and is
    // deliberately absent from the [data-theme]/[data-bp-theme] overrides below.
    ...motionVarLines().map((l) => "  " + l),
    "}",
    '[data-theme="dark"] {',
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(tokens.color[r].dark)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].dark)};`),
    "}",
  ];
  const themed = themeBlocks(themes, webThemeBlock);
  if (themed) lines.push(THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: the starter templates' theme token region (stw-backlog-theme-matrix)
// templates/search-starter/app/globals.css and its Astro twin carried a BYTE-COPY
// of webBlock()'s output, and a copy cannot grow. Two defects followed, and both
// are of the same shape — an ENUMERATION standing in for a RULE:
//
//   • design/themes/ ships FIVE skins; the copy enumerated FOUR. `iris` was
//     silently absent from both starter templates, so a visitor selecting it got
//     the evergreen fallback and no error anywhere.
//   • 77 of 151 (selector, var) pairs had drifted from web/app/globals.css.
//
// Registering the region as an ARTIFACT built by webBlock() — the SAME builder the
// web demo uses, not a template-specific near-copy — removes the class rather than
// the instances: a SIXTH theme file reaches both templates on the next `--write`,
// and no reviewer has to notice that it did not.
//
// It owns its OWN marker pair rather than the shared `BEGIN GENERATED: tokens`
// one, because those files' outer BEGIN/END SNAPSHOT markers are read by
// scripts/templates-literal-check.sh to exempt the block from the raw-palette
// literal ban; a distinct inner pair leaves that script untouched and keeps the
// generated region strictly narrower than the exemption it sits inside.
export const TEMPLATE_TOKENS_MARKER_BEGIN =
  "/* BEGIN GENERATED: template theme tokens (design/tokens.json + design/themes/*.json via design/emit.mjs — node design/emit.mjs --write; do not hand-edit) */";
export const TEMPLATE_TOKENS_MARKER_END = "/* END GENERATED: template theme tokens */";

// ── surface: web TS token artifact (web/lib/tokens.gen.ts) ────────────────────
// A whole generated TS module (kind "ts", like the Go files). Exports the LIGHT
// canvas colours listings-map.tsx paints with, so no hex literal lives in the
// component. HSL strings — valid Canvas2D fillStyle/strokeStyle; the component
// composes alpha variants itself. Only the roles the canvas actually consumes
// are exported (no dead tokens).
function webTokensTs() {
  const c = (role) => hsl(tokens.color[role].light);
  const rows = [
    ["primary", "primary"],       // evergreen brand — the map marker
    ["mutedText", "muted-text"],  // a pin filtered out by the active search
    ["surface", "surface"],       // pin outline / basemap paper
    ["primaryFg", "primary-fg"],  // label text on the dark label chip
    ["text", "text"],             // label chip fill + pin shadow (via alpha)
    ["mutedSurface", "muted-surface"], // sea/landless basemap tint
  ];
  // Categorical match-quality SPECTRUM (7 ordered fuzzy→exact stops) → hsl()
  // strings, consumed by finder.tsx's HighlightLegend gradient. Theme-invariant
  // VALUE list, the web analog of the Studio presence/sheet-CF categorical sets.
  const spectrum = tokens.color.matchQuality.spectrum.map((ch) => hsl(ch));
  // Paper CALLOUT tone tints for the /papers reader (portable-doc.tsx) — the
  // web twin of Render.TokensGen.callout/1 + the paper-surface --bp-tone-*
  // pairs. Sourced from color.paperCallout ONLY, never color.status (a
  // DIFFERENT value set — tokens.json forbids the substitution). Tone order
  // mirrors util.ex tone_palette/1 (CALLOUT_TONES); hex verbatim, no HSL hop.
  const pc = tokens.color.paperCallout;
  const calloutRows = CALLOUT_TONES.map(
    (t) =>
      `  ${t}: { light: { bg: "${pc.light[t].bg}", fg: "${pc.light[t].fg}" }, dark: { bg: "${pc.dark[t].bg}", fg: "${pc.dark[t].fg}" } },`,
  );
  // The TYPED type ladders. Both families ship as {size,lineHeight,weight} so a
  // consumer never has to invent the missing third number — the hole that let
  // styleguide.tsx hand-keep its own weight column beside tokens.json for months
  // (au-r4-web-type-ladder). CHROME weights are authored per step; READING
  // resolves the optional per-step `weight` against the shared headingWeight
  // scalar (charter D29), and body falls back to the CSS normal 400.
  const tc = tokens.type.chrome;
  const tr = tokens.type.reading;
  const key = (k) => (/^[A-Za-z_$][\w$]*$/.test(k) ? k : `"${k}"`);
  const chromeRows = TYPE_STEPS.map(
    (k) => `  ${key(k)}: { size: ${tc[k].size}, lineHeight: ${tc[k].lineHeight}, weight: ${tc[k].weight} },`,
  );
  const readingWeight = (k) => tr[k].weight ?? (k === "body" ? 400 : tr.headingWeight);
  const readingRows = READING_STEPS.map(
    (k) => `  ${key(k)}: { size: ${tr[k].size}, lineHeight: ${tr[k].lineHeight}, weight: ${readingWeight(k)} },`,
  );
  return [
    "// Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "// Regenerate: node design/emit.mjs --write",
    "",
    "/** Light-theme canvas colours for listings-map.tsx, mapped from design/tokens.json. */",
    "export const canvas = {",
    ...rows.map(([k, role]) => `  ${k}: "${c(role)}",`),
    "} as const;",
    "",
    "/** Categorical match-quality spectrum (7 ordered stops, fuzzy→exact) for",
    " *  finder.tsx's HighlightLegend gradient. Theme-invariant data-viz palette,",
    " *  NOT a status role — mirrors the presence / Sheets-CF categorical sets. */",
    "export const matchQuality = [",
    ...spectrum.map((s) => `  "${s}",`),
    "] as const;",
    "",
    "/** Paper callout tone tints for portable-doc.tsx (design/tokens.json",
    " *  color.paperCallout — the web twin of the paper-surface --bp-tone-* pairs).",
    " *  {bg,fg} hex per tone, light + dark. NOT the status roles — never",
    " *  substitute color.status for these. */",
    "export const paperCallout = {",
    ...calloutRows,
    "} as const;",
    "",
    "/** A typed typography step: px size, unitless line height, CSS font weight. */",
    "export type TypeStep = { readonly size: number; readonly lineHeight: number; readonly weight: number };",
    "",
    "/** UI CHROME type ladder (Inter), largest → smallest, from design/tokens.json",
    " *  `type.chrome`. This is the ONE web source for chrome type: styleguide.tsx",
    " *  renders its specimens straight off these numbers. Never hand-keep a second",
    " *  copy — retune tokens.json, re-emit, and the ladder moves here. */",
    "export const chromeType = {",
    ...chromeRows,
    "} as const satisfies Record<string, TypeStep>;",
    "",
    "/** The step order the chrome ladder is displayed in (largest → smallest). */",
    `export const chromeTypeOrder = [${TYPE_STEPS.map((s2) => `"${s2}"`).join(", ")}] as const;`,
    "",
    "/** READING type ladder (serif prose) from design/tokens.json `type.reading` —",
    " *  the SAME leaves paper-surface.css emits as --tok-reading-*-size/-lh and the",
    " *  `.bp-paper-surface` heading rules consume, so what the styleguide shows is",
    " *  what @barkpark/react PortableDoc actually paints. `weight` resolves the",
    " *  per-step override against the shared type.reading.headingWeight scalar. */",
    "export const readingType = {",
    ...readingRows,
    "} as const satisfies Record<string, TypeStep>;",
    "",
    "/** The step order the reading ladder is displayed in (display → body). */",
    `export const readingTypeOrder = [${READING_STEPS.map((s2) => `"${s2}"`).join(", ")}] as const;`,
    "",
  ].join("\n");
}

export { webBlock, webTokensTs };
