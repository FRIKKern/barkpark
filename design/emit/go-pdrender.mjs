// design/emit/go-pdrender.mjs — the Go pdrender surface.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { DEFAULT_THEME, loadThemes, themePalette, tokens } from "./source.mjs";
import { AIR_ROW_SPLIT, AIR_STEPS, goAdaptive, hslToHex, ruleGlyph } from "./vocab.mjs";
import { alignEq, alignFields, alignMap, goHeader } from "./go-board.mjs";

// ── surface: Go pdrender (internal/pdrender/tokens_gen.go) ────────────────────
// Reading tokens + the four semantic status tones as hex AdaptiveColors.
// Additive stub — pdrender's hand-tuned tone*/pd* vars are untouched.
function pdrenderGo(themes = loadThemes()) {
  const c = tokens.color;
  const st = c.status;
  const r = tokens.type.reading;
  const tone = (name, role) =>
    `\tGenTone${name} = lipgloss.AdaptiveColor{Light: "${hslToHex(st[role].light)}", Dark: "${hslToHex(st[role].dark)}"}`;
  // Chrome + reading-accent AdaptiveColors (color.* → hex). Unconsumed until
  // wave 2 (S7: pdAccent/L2/links → GenPrimary, pdTerra → GenReadingAccent).
  const chrome = (name, role) =>
    `\tGen${name} = lipgloss.AdaptiveColor{Light: "${hslToHex(c[role].light)}", Dark: "${hslToHex(c[role].dark)}"}`;
  // Code-block tones (color.code → hex; stored as hex directly, no HSL hop).
  // Additive: pdrender's ingress points at GenInk in a later wave.
  const code = (name, sub) =>
    `\tGenCode${name} = lipgloss.AdaptiveColor{Light: "${c.code[sub].light}", Dark: "${c.code[sub].dark}"}`;
  // CLI-chrome tones (color.cliChrome → hex; hex directly). pdrender's OWN copy
  // of the four chrome roles it threads (accent/ink/text-secondary/dim) — it may
  // import only lipgloss+x/ansi+stdlib, so it can NEVER read internal/semrole's
  // GenChrome* twins; these are byte-identical siblings. NOT the color.text/
  // muted-text reading family above (GenInk/GenDim are a DIFFERENT, warmer set).
  const cliChrome = (name, role) =>
    `\tGenChrome${name} = lipgloss.AdaptiveColor{Light: "${c.cliChrome[role].light}", Dark: "${c.cliChrome[role].dark}"}`;
  // Terminal space ladder inputs (see the emitted block below for the doctrine).
  const air = tokens.space.air;
  const sec = tokens.space.section;
  // Neutral callout tone (color.cliCalloutNeutral → hex) — the neutral peer of
  // the four status tones, consumed by Theme.Callout's "neutral" arm.
  const neut = c.cliCalloutNeutral;
  // The evergreen genPalette entry, byte-for-byte as before (Gen* references so
  // N=1 is byte-identical); a non-evergreen entry stamps literals from its skin.
  const EVERGREEN_FIELDS = [
    "\t\tChromeAccent: GenChromeAccent,",
    "\t\tChromeInk: GenChromeInk,",
    "\t\tChromeTextSecondary: GenChromeTextSecondary,",
    "\t\tChromeDim: GenChromeDim,",
    "\t\tRule: GenRule,",
    "\t\tCodeFg: GenCodeFg,",
    "\t\tCodeBg: GenCodeBg,",
    "\t\tReadingMuted: GenDim,",
    "\t\tReadingAccent: GenReadingAccent,",
    "\t\tToneInfo: GenToneInfo,",
    "\t\tToneOK: GenToneOK,",
    "\t\tToneWarn: GenToneWarn,",
    "\t\tToneDanger: GenToneDanger,",
    "\t\tToneNeutral: GenToneNeutral,",
  ];
  const litFields = (p) => {
    const col = p.color;
    const hx = (o) => goAdaptive(o.light, o.dark);            // stored hex (chrome/code/neutral)
    const hs = (o) => goAdaptive(hslToHex(o.light), hslToHex(o.dark)); // HSL channels → hex
    return [
      `\t\tChromeAccent: ${hx(col.cliChrome["chrome-accent"])},`,
      `\t\tChromeInk: ${hx(col.cliChrome["chrome-ink"])},`,
      `\t\tChromeTextSecondary: ${hx(col.cliChrome["chrome-text-secondary"])},`,
      `\t\tChromeDim: ${hx(col.cliChrome["chrome-dim"])},`,
      `\t\tRule: ${hs(col.border)},`,
      `\t\tCodeFg: ${hx(col.code.fg)},`,
      `\t\tCodeBg: ${hx(col.code.bg)},`,
      `\t\tReadingMuted: ${hs(col["muted-text"])},`,
      `\t\tReadingAccent: ${hs(col["reading-accent"])},`,
      `\t\tToneInfo: ${hs(col.status.info)},`,
      `\t\tToneOK: ${hs(col.status.ok)},`,
      `\t\tToneWarn: ${hs(col.status.warn)},`,
      `\t\tToneDanger: ${hs(col.status.danger)},`,
      `\t\tToneNeutral: ${hx(col.cliCalloutNeutral)},`,
    ];
  };
  const pdThemeEntry = ({ name, spec }) => [
    `\t${JSON.stringify(name)}: {`,
    ...alignMap(name === DEFAULT_THEME ? EVERGREEN_FIELDS : litFields(themePalette(spec))),
    "\t},",
  ];
  return [
    goHeader("pdrender"),
    'import "github.com/charmbracelet/lipgloss"',
    "",
    "// Generated semantic status tones (design/tokens.json color.status → hex).",
    "var (",
    ...alignEq([tone("Info", "info"), tone("OK", "ok"), tone("Warn", "warn"), tone("Danger", "danger")]),
    ")",
    "",
    "// Generated neutral callout tone (design/tokens.json color.cliCalloutNeutral).",
    `var GenToneNeutral = lipgloss.AdaptiveColor{Light: "${neut.light}", Dark: "${neut.dark}"}`,
    "",
    "// Generated chrome + reading-accent tokens (design/tokens.json color.* → hex).",
    "var (",
    ...alignEq([
      chrome("Primary", "primary"), chrome("PrimaryFg", "primary-fg"),
      chrome("Ink", "text"), chrome("Dim", "muted-text"), chrome("Rule", "border"),
      chrome("ReadingAccent", "reading-accent"),
    ]),
    ")",
    "",
    "// Generated CLI-chrome tokens (design/tokens.json color.cliChrome → hex).",
    "// pdrender's own copy (it can't import internal/semrole); referenced by the",
    "// evergreen genPalette entry below and threaded through theme.go's buildTheme",
    "// (pal.ChromeAccent/ChromeInk/ChromeTextSecondary/ChromeDim, via Resolve).",
    "var (",
    ...alignEq([
      cliChrome("Accent", "chrome-accent"), cliChrome("Ink", "chrome-ink"),
      cliChrome("TextSecondary", "chrome-text-secondary"), cliChrome("Dim", "chrome-dim"),
    ]),
    ")",
    "",
    "// Generated code-block tones (design/tokens.json color.code → hex).",
    "var (",
    ...alignEq([code("Fg", "fg"), code("Bg", "bg")]),
    ")",
    "",
    "// Generated reading tokens (design/tokens.json font.reading / type.reading).",
    "const (",
    `\tGenReadingFontStack     = ${JSON.stringify(tokens.font.reading.stack)}`,
    `\tGenReadingHeadingWeight = ${r.headingWeight}`,
    `\tGenReadingBodySize      = ${r.body.size}`,
    ")",
    "",
    // ── terminal space ladder (space.air / space.section / space.rule) ───────
    "// Generated terminal space ladder (design/tokens.json space.air /",
    "// space.section / space.rule). The web surface paints these as PIXELS; a",
    "// terminal has one vertical unit, the ROW, and space.air.beat (22px) is ≈ one",
    "// row — so the six-rung web air ladder collapses to TWO honest terminal",
    "// values. Nothing below spells a per-kind row count: GenAirRatios carries the",
    "// source ratios verbatim, GenAirRowSplit carries the documented collapse",
    "// threshold (design/emit.mjs AIR_ROW_SPLIT), and pdrender.AirRows (air.go)",
    "// applies one to the other. A hand-written six-step table is exactly the fake",
    "// precision this arm exists to refuse.",
    "var GenAirRatios = map[string]float64{",
    ...alignMap(AIR_STEPS.map((k) => `\t"${k}": ${air[k]},`)),
    "}",
    "",
    "// GenAirOrder is the emission order (lightest opening → heaviest), matching",
    "// AIR_STEPS in design/emit.mjs.",
    `var GenAirOrder = []string{${AIR_STEPS.map((k) => `"${k}"`).join(", ")}}`,
    "",
    "// GenRuleGlyph is the terminal's rendering of the TWO weights a paper draws",
    "// horizontal lines at (space.section.rule = 2px structural, space.rule.hairline",
    "// = 1px everything else). A terminal cannot vary a line's thickness, so the",
    "// weight becomes the GLYPH: heavy for a section boundary, light for a table",
    "// underline, a divider, a heading rule. Derived from the px values, not typed:",
    "// a weight of 2px or more is the structural one.",
    "var GenRuleGlyph = map[string]string{",
    ...alignMap([
      `\t"hairline": ${JSON.stringify(ruleGlyph(tokens.space.rule.hairline))},`,
      `\t"section": ${JSON.stringify(ruleGlyph(sec.rule))},`,
    ]),
    "}",
    "",
    "// GenAirRowSplit is the collapse threshold (a ratio at or above it earns a",
    "// SECOND blank row). GenAirRowsDefault is the air a block that is not on the",
    "// ladder opens with. GenSectionGapRows is space.section.beat (2.2 air beats ≈",
    "// 48px of section air) rounded to whole rows: the air",
    "// that says one section ENDED, the half of the boundary device the rule glyph",
    "// completes. GenSectionHeadGapRows is space.section.gap (the artifact's 16px",
    "// .sec-head padding-top) in rows: the air between the rule and the words.",
    "const (",
    ...alignEq([
      `\tGenAirRowSplit = ${AIR_ROW_SPLIT}`,
      "\tGenAirRowsDefault = 1",
      `\tGenSectionGapRows = ${Math.round(sec.beat)}`,
      `\tGenSectionHeadGapRows = ${Math.round(sec.gap / air.beat)}`,
    ]),
    ")",
    "",
    "// Generated categorical viz palettes (design/tokens.json color.pdrenderChart /",
    "// color.pdrenderHeatmap → hex). NOT status roles — theme-invariant categorical",
    "// data-viz values (the presence / matchQuality passthrough precedent, D21).",
    "// GenChartSeries is chart.go's per-series TrueColor cycle; GenHeatmapBase/Peak",
    "// are heatmap.go's dark→bright gradient endpoints. Byte-faithful to the former",
    "// hand literals, so the render is unchanged. GenHeatRamp is the 4 discrete shade",
    "// steps (light→full) heatmap.go's quantile dual-encode paints as each glyph bin's",
    "// Foreground — ramp[3] == GenHeatmapPeak so the discrete scale meets the gradient.",
    "var GenChartSeries = []lipgloss.Color{",
    ...tokens.color.pdrenderChart.series.map((h) => `\tlipgloss.Color(${JSON.stringify(h)}),`),
    "}",
    "",
    "var GenHeatRamp = []lipgloss.Color{",
    ...tokens.color.pdrenderHeatmap.ramp.map((h) => `\tlipgloss.Color(${JSON.stringify(h)}),`),
    "}",
    "",
    "const (",
    `\tGenHeatmapBase = ${JSON.stringify(tokens.color.pdrenderHeatmap.base)}`,
    `\tGenHeatmapPeak = ${JSON.stringify(tokens.color.pdrenderHeatmap.peak)}`,
    ")",
    "",
    // ── theme resolution seam (ts-w4c) ──────────────────────────────────────
    "// DefaultTheme is the built-in evergreen skin. Resolve defaults to it for any",
    "// unknown/empty theme id, so today (evergreen-only) every id yields these exact",
    "// bytes — the styleguide golden stays frozen. Adding theme N+1 grows genPalette",
    "// (one keyed entry); theme.go's buildTheme already reads Resolve(themeID).",
    `const DefaultTheme = ${JSON.stringify(DEFAULT_THEME)}`,
    "",
    "// Palette is one theme's resolved pdrender token set. The Chrome* roles are the",
    "// zinc cliChrome family (ChromeInk/ChromeDim are NOT the warmer reading Ink/Dim —",
    "// the decoy guard theme.go documents); ReadingMuted/ReadingAccent are the reading",
    "// family; Tone* are the semantic status tones the Callout builder paints.",
    "type Palette struct {",
    ...alignFields([
      "\tChromeAccent lipgloss.AdaptiveColor",
      "\tChromeInk lipgloss.AdaptiveColor",
      "\tChromeTextSecondary lipgloss.AdaptiveColor",
      "\tChromeDim lipgloss.AdaptiveColor",
      "\tRule lipgloss.AdaptiveColor",
      "\tCodeFg lipgloss.AdaptiveColor",
      "\tCodeBg lipgloss.AdaptiveColor",
      "\tReadingMuted lipgloss.AdaptiveColor",
      "\tReadingAccent lipgloss.AdaptiveColor",
      "\tToneInfo lipgloss.AdaptiveColor",
      "\tToneOK lipgloss.AdaptiveColor",
      "\tToneWarn lipgloss.AdaptiveColor",
      "\tToneDanger lipgloss.AdaptiveColor",
      "\tToneNeutral lipgloss.AdaptiveColor",
    ]),
    "}",
    "",
    "// genPalette keys each theme's Palette by id. Values REFERENCE the Gen* vars",
    "// above (no re-typed literals) so the evergreen skin is byte-identical to them.",
    "var genPalette = map[string]Palette{",
    ...themes.flatMap(pdThemeEntry),
    "}",
    "",
    "// Resolve returns the pdrender Palette for a theme id, defaulting to evergreen",
    "// for an unknown or empty id (never a partial/zero palette).",
    "func Resolve(theme string) Palette {",
    "\tif p, ok := genPalette[theme]; ok {",
    "\t\treturn p",
    "\t}",
    "\treturn genPalette[DefaultTheme]",
    "}",
    "",
  ].join("\n");
}

export { pdrenderGo };
