// design/emit/paper.mjs — the paper-surface fragment.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { loadThemes, THEME_BANNER, themeBlocks, tokens } from "./source.mjs";
import { AIR_STEPS, EVIDENCE_KEYS, EVIDENCE_UNITS, hslToHex, kebab, LIFE_ORDER, motionVarLines, PAPER_ROLES, RULE_KEYS, RULE_UNITS, SECTION_KEYS, SECTION_UNITS, statusVars, verdictVars } from "./vocab.mjs";

// ── surface: paper-surface (the generated fragment of the package's raw surface) ──
// Reading font + reading type scale + status tones, plus the lifecycle
// glyph-tone classes (.bp-lg--<state>) that give the CSS/GUI half of the §6
// cross-surface parity assertion its hues. Additive (.bp-lg-- is a fresh, un-
// consumed class set; the hand-authored .bp-g-- ladder is untouched).
// The `--paper-*` reading-surface theme colours for ONE theme (color.paper.surface,
// VERBATIM). Emitted on the html[data-theme=…] + bare-fallback token scopes — the
// same three-way structure the hand region used (attr blocks win over the light
// fallback so a pre-paint no-data-theme load still gets the light bp theme).
function paperColorVars(theme, indent, t = tokens) {
  const s = t.color.paper.surface;
  return [
    ...PAPER_ROLES.map((role) => indent + `--paper-${role}: ${s[role][theme]};`),
    // S7 STUB (charter Decision 6): the warm reading accent (color.reading-accent,
    // theme-derived) emitted onto the reading surface but UNCONSUMED — S8 (the
    // article terracotta pullquote/rule) reads it. Additive W1 posture; the
    // paper-editor mirror picks it up automatically.
    indent + `--paper-reading-accent: ${hslToHex(t.color["reading-accent"][theme])};`,
  ].join("\n");
}

// Paper theme block: the `--paper-*` reading-surface skin + status tones under
// the theme attribute. paper-surface is an ATTRIBUTE surface (edit surfaces stamp
// data-theme), so the dark scope keys on [data-theme=dark] (NOT @media) — that
// keeps the reader-dark-parity guard untouched (it scans `html[data-theme="dark"]`
// and prefers-color-scheme blocks; `html[data-bp-theme=X][data-theme=dark]`
// matches neither substring). Reading-type vars are theme-invariant and the
// .bp-lg-- glyph tones are positional passthrough (D25) — both excluded here.
const paperThemeBlock = (name, t) => [
  `html[data-bp-theme="${name}"] .bp-paper-surface, html[data-bp-theme="${name}"] .bp-paper-body {`,
  paperColorVars("light", "  ", t),
  statusVars("light", "  ", t),
  verdictVars("light", "  ", t),
  "}",
  `html[data-bp-theme="${name}"][data-theme="dark"] .bp-paper-surface, html[data-bp-theme="${name}"][data-theme="dark"] .bp-paper-body {`,
  paperColorVars("dark", "  ", t),
  statusVars("dark", "  ", t),
  verdictVars("dark", "  ", t),
  "}",
].join("\n");

function paperBlock(themes = loadThemes()) {
  const r = tokens.type.reading;
  // Each reading step emits size + line-height, and a tracking var ONLY where
  // tokens.json declares a letterSpacing. The tracking leaves were declared in
  // the source and emitted NOWHERE until pe-w1-reader-editorial-typography — the
  // `--bp-*-tracking` vars were hand-authored beside a token that claimed to own
  // them, so the single source was single in name only.
  //
  // `weight` is the same idiom (device 3, charter D29): a step that declares its
  // own weight emits `--tok-reading-<step>-weight`, and a step that does not
  // emits nothing — it keeps reading the SHARED `--tok-reading-heading-weight`
  // through the surface's `--bp-heading-weight` bridge. The shared scalar is
  // pinned at 600 by validate.mjs; this per-step channel is the only legal way
  // for one level to take a different voice.
  const step = (name, s) => [
    `--tok-reading-${name}-size: ${s.size}px;`,
    `--tok-reading-${name}-lh: ${s.lineHeight};`,
    ...(s.letterSpacing == null ? [] : [`--tok-reading-${name}-tracking: ${s.letterSpacing}em;`]),
    ...(s.weight == null ? [] : [`--tok-reading-${name}-weight: ${s.weight};`]),
  ];
  // The AIR scale (space.air): the beat an EVIDENCE block opens with. Emitted as
  // a ratio of `--tok-air-beat` rather than a resolved pixel, so the LAW ("evidence
  // opens at 1.1-1.85x the ARTIFACT's air unit") is what ships — retune the unit and
  // the whole scale moves together instead of eight literals drifting apart.
  // `--tok-air-beat` is that ARTIFACT unit and not the reader's paragraph rhythm,
  // which stays `--bp-para-margin-top: 12pt` (ruled 2026-09-02,
  // task-741e0de1ddb3a482; the rig asserts the prose beat stays a clear step below
  // the ladder's bottom rung). The token name is kept: renaming an emitted token
  // ripples through every generated artifact for zero pixels.
  const a = tokens.space.air;
  const airVars = [
    `--tok-air-beat: ${a.beat}px;`,
    ...AIR_STEPS.map((k) => `--tok-air-${k}: calc(var(--tok-air-beat) * ${a[k]});`),
  ];
  // The EVIDENCE BAND (space.evidence): how wide a block that improves with width
  // may grow when it steps out of the prose column. Emitted as the four inputs to
  // one law, never as a resolved width — paper-surface.css composes them into a
  // single `--bp-evidence-width` expression, so the band is CONTINUOUS in the
  // available inline space and there is no breakpoint literal to drift.
  // `caption` carries `ch`, not `px`: it is a reading measure, and a caption
  // inside a wide figure must wrap at a character count, not at a pixel.
  const e = tokens.space.evidence;
  const evidenceVars = EVIDENCE_KEYS.map(
    (k) => `--tok-evidence-${kebab(k)}: ${e[k]}${EVIDENCE_UNITS[k]};`,
  );
  // The SECTION BOUNDARY (space.section): the air that ends a section and the rule
  // that opens the next. `beat` emits as a ratio of `--tok-air-beat` — the same
  // anchor the evidence ladder hangs off, so retuning the beat moves section
  // rhythm and evidence rhythm together instead of letting them drift apart.
  // `rule`/`gap` emit as pixels: a hairline is a hairline at any beat.
  const sc = tokens.space.section;
  const sectionVars = SECTION_KEYS.map((k) =>
    k === "beat"
      ? `--tok-section-beat: calc(var(--tok-air-beat) * ${sc.beat});`
      : `--tok-section-${k}: ${sc[k]}${SECTION_UNITS[k]};`,
  );
  // The RULE LADDER (space.rule): the weight of every horizontal line that is
  // NOT a section boundary. Emitted beside the section rule on purpose — the two
  // are one ladder, and a reader who sees them apart is reading a paper where a
  // table header shouts as loud as a chapter break.
  const rl = tokens.space.rule;
  const ruleVars = RULE_KEYS.map((k) => `--tok-rule-${kebab(k)}: ${rl[k]}${RULE_UNITS[k]};`);

  const readingVars = [
    `--tok-reading-font: ${tokens.font.reading.stack};`,
    `--tok-reading-heading-weight: ${r.headingWeight};`,
    ...step("body", r.body),
    ...step("h1", r.h1),
    ...step("h2", r.h2),
    ...step("h3", r.h3),
    ...airVars,
    ...sectionVars,
    ...ruleVars,
    ...evidenceVars,
    // The motion ladder rides the reading surface's own root scope so the
    // paper-editor bundle inherits it through the de-scoping mirror.
    ...motionVarLines(),
  ].map((l) => "  " + l).join("\n");

  const lifeClasses = (theme) =>
    LIFE_ORDER.map((s) => `.bp-lg--${s} { color: ${tokens.lifecycle[s].color[theme]}; }`).join("\n");

  const themed = themeBlocks(themes, paperThemeBlock);
  return [
    "/* ── `--paper-*` reading-surface theme tokens (color.paper.surface — relocated",
    "   from the hand region into this GENERATED block; Barkpark aesthetic-unification:",
    "   cool near-white ground, evergreen accent, replacing the legacy warm parchment).",
    "   Scoped to .bp-paper-surface; the html[data-theme] blocks win over the light",
    "   fallback so a pre-paint no-data-theme load still gets the light bp theme. */",
    'html[data-theme="light"] .bp-paper-surface,',
    'html[data-theme="light"] .bp-paper-body {',
    paperColorVars("light", "  "),
    "}",
    'html[data-theme="dark"] .bp-paper-surface,',
    'html[data-theme="dark"] .bp-paper-body {',
    paperColorVars("dark", "  "),
    "}",
    ".bp-paper-surface, .bp-paper-body {",
    paperColorVars("light", "  "),
    "}",
    ".bp-paper-surface, .bp-paper-body {",
    readingVars,
    statusVars("light", "  "),
    verdictVars("light", "  "),
    "}",
    "@media (prefers-color-scheme: dark) {",
    "  .bp-paper-surface, .bp-paper-body {",
    statusVars("dark", "    "),
    verdictVars("dark", "    "),
    "  }",
    "}",
    'html[data-theme="light"] .bp-paper-surface, html[data-theme="light"] .bp-paper-body {',
    statusVars("light", "  "),
    verdictVars("light", "  "),
    "}",
    'html[data-theme="dark"] .bp-paper-surface, html[data-theme="dark"] .bp-paper-body {',
    statusVars("dark", "  "),
    verdictVars("dark", "  "),
    "}",
    "/* lifecycle glyph tones — the CSS half of the §6 GUI/TUI parity assertion */",
    lifeClasses("light"),
    "@media (prefers-color-scheme: dark) {",
    lifeClasses("dark").split("\n").map((l) => "  " + l).join("\n"),
    "}",
    ...(themed ? [THEME_BANNER, themed] : []),
  ].join("\n");
}

export { paperBlock };
