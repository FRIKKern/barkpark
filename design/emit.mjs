#!/usr/bin/env node
// design/emit.mjs — the W1.2 emitter. design/tokens.json is the ONE source of the
// Barkpark Unified Aesthetic; this regenerates EVERY per-surface artifact from it.
// Dependency-free (Node built-ins only), deterministic output. Trusts
// design/validate.mjs to have proven the source well-formed.
//
//   node design/emit.mjs            # default: report drift, write nothing (== --check)
//   node design/emit.mjs --check    # same as default
//   node design/emit.mjs --write    # rewrite every artifact in place
//
// CSS surfaces are spliced into a BEGIN/END GENERATED: tokens marker block that
// must already exist (mirrors the status-tones precedent). Go surfaces are whole
// generated *_gen.go files. check.mjs imports the builders here for the drift gate
// and the §6 cross-surface parity assertion.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { evaluateMirror } from "./paper-editor-mirror.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, "..");
export const tokens = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));

// ── shared vocabulary ───────────────────────────────────────────────────────
export const BASE_ROLES = [
  "primary", "primary-hover", "primary-fg", "bg", "surface", "muted-surface",
  "text", "muted-text", "border", "ring", "accent",
];
export const STATUS_ROLES = ["ok", "warn", "danger", "info"];
export const LIFE_ORDER = [
  "in_progress", "blocked", "done", "closed", "cancelled", "ready", "open",
];
// Cloud INSTANCE lifecycle emission order (matches tokens.instanceLifecycle).
export const INST_ORDER = [
  "provisioning", "live", "degraded", "stopped", "archived", "decommissioned", "adopted",
];
export const PROVIDERS = ["hetzner", "azure"];
// An instance state's colour is READ THROUGH its status role (Decision 7): the
// role picks a CSS var (SPA) and the {light,dark} channels its Go hue resolves
// from. role "" (neutral: stopped/archived + _default) → the muted-text tone.
export const INST_ROLE_CSS = { ok: "--ok", warn: "--warn", danger: "--danger", info: "--info", "": "--muted-text" };
export const instRoleChannels = (role) =>
  role === "" ? tokens.color["muted-text"] : tokens.color.status[role];
// Chrome type-scale steps, largest → smallest (display order for the Studio type
// ladder). Mirrors tokens.type.chrome; the emitter and check.mjs both key off it.
export const TYPE_STEPS = ["2xl", "xl", "lg", "base", "sm", "xs"];

const softAlpha = tokens.color._convention.softAlpha;   // { light, dark }
const strongAlpha = tokens.color._convention.strongAlpha; // { light, dark, _note }

const MARKER_BEGIN =
  "/* BEGIN GENERATED: tokens (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) */";
const MARKER_END = "/* END GENERATED: tokens */";

// ── color helpers ───────────────────────────────────────────────────────────
const hsl = (ch) => `hsl(${ch})`;
const alpha = (a) => String(a); // 0.15 -> "0.15", 0.2 -> "0.2"

// HSL channels "H S% L%" -> "#rrggbb". Only the Go pdrender tones need hex
// (lipgloss wants hex); CSS surfaces keep hsl() so the soft-tint machinery lives.
export function hslToHex(channels) {
  const m = channels.trim().split(/\s+/);
  const h = parseFloat(m[0]);
  const s = parseFloat(m[1]) / 100;
  const l = parseFloat(m[2]) / 100;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hp = h / 60;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  let r = 0, g = 0, b = 0;
  if (hp >= 0 && hp < 1) [r, g, b] = [c, x, 0];
  else if (hp < 2) [r, g, b] = [x, c, 0];
  else if (hp < 3) [r, g, b] = [0, c, x];
  else if (hp < 4) [r, g, b] = [0, x, c];
  else if (hp < 5) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  const m2 = l - c / 2;
  const to = (v) => Math.round((v + m2) * 255).toString(16).padStart(2, "0");
  return `#${to(r)}${to(g)}${to(b)}`;
}

// "U+280B" -> "⠋"
export const glyphOf = (cp) => String.fromCodePoint(parseInt(cp.slice(2), 16));

// ── CSS var fragments (shared by every CSS surface) ─────────────────────────
const baseVar = (role, theme) => `--${role}: ${hsl(tokens.color[role][theme])};`;

function statusVars(theme, indent) {
  const st = tokens.color.status;
  const lines = [
    STATUS_ROLES.map((r) => `--${r}-hsl: ${st[r][theme]};`).join(" "),
    STATUS_ROLES.map((r) => `--${r}: hsl(var(--${r}-hsl));`).join(" "),
    STATUS_ROLES.map((r) => `--${r}-soft: hsl(var(--${r}-hsl) / ${alpha(softAlpha[theme])});`).join(" "),
    STATUS_ROLES
      .filter((r) => st[r].strong === true)
      .map((r) => `--${r}-strong: hsl(var(--${r}-hsl) / ${alpha(strongAlpha[theme])});`)
      .join(" "),
  ];
  return lines.map((l) => indent + l).join("\n");
}

function baseVars(theme, indent) {
  return BASE_ROLES.map((r) => indent + baseVar(r, theme)).join("\n");
}

// --primary carries the same -hsl/-soft machinery the status roles use, so blue
// accent TINTS being swept off literals have an evergreen --primary-soft to bind
// to. (--primary and --primary-hover themselves are emitted by baseVars via
// BASE_ROLES; this only adds the derived -hsl channel + the soft-tint fill.)
function primaryVars(theme, indent) {
  const ch = tokens.color.primary[theme];
  const lines = [
    `--primary-hsl: ${ch};`,
    `--primary-soft: hsl(var(--primary-hsl) / ${alpha(softAlpha[theme])});`,
  ];
  return lines.map((l) => indent + l).join("\n");
}

// ── surface: Cloud SPA (cloud/priv/static/app.css) ──────────────────────────
// Full base + status contract. Values mirror the committed :root today; this is
// a check-against-committed surface (the generated block is additive and the
// hand-authored :root that follows keeps the live values).
//
// PLUS the cloud-console families (charter azure-hetzner Decision 7): the
// provider IDENTITY tints as --provider-<kind> custom properties (per-theme
// hex), and the instance-lifecycle glyph-tone classes .bp-inst--<state> whose
// colour is READ THROUGH the state's status role (var(--ok/--warn/--danger/
// --info/--muted-text)) — identity never a state voice. Additive: no consumer
// is rewired this slice (statusPill/bucketOf + CLI table renderers land later).
function providerVars(theme, indent) {
  const p = tokens.color.provider;
  return PROVIDERS.map((k) => indent + `--provider-${k}: ${p[k][theme]};`).join("\n");
}
function instClasses() {
  const il = tokens.instanceLifecycle;
  return INST_ORDER
    .map((s) => `.bp-inst--${s} { color: var(${INST_ROLE_CSS[il[s].role]}); }`)
    .join("\n");
}
function cloudBlock() {
  return [
    ":root {",
    baseVars("light", "  "),
    primaryVars("light", "  "),
    statusVars("light", "  "),
    providerVars("light", "  "),
    "}",
    '[data-theme="dark"] {',
    baseVars("dark", "  "),
    primaryVars("dark", "  "),
    statusVars("dark", "  "),
    providerVars("dark", "  "),
    "}",
    "/* instance-lifecycle glyph tones — colour READ THROUGH the state's status",
    "   role (Decision 7: identity is never a state voice); theme-invariant since",
    "   the referenced role var flips per theme. A later wave rewires statusPill/",
    "   bucketOf onto these. */",
    instClasses(),
  ].join("\n");
}

// ── surface: paper-surface (api/assets/paper-surface/paper-surface.css) ──────
// Reading font + reading type scale + status tones, plus the lifecycle
// glyph-tone classes (.bp-lg--<state>) that give the CSS/GUI half of the §6
// cross-surface parity assertion its hues. Additive (.bp-lg-- is a fresh, un-
// consumed class set; the hand-authored .bp-g-- ladder is untouched).
function paperBlock() {
  const r = tokens.type.reading;
  const readingVars = [
    `--tok-reading-font: ${tokens.font.reading.stack};`,
    `--tok-reading-heading-weight: ${r.headingWeight};`,
    `--tok-reading-body-size: ${r.body.size}px;`,
    `--tok-reading-body-lh: ${r.body.lineHeight};`,
    `--tok-reading-h1-size: ${r.h1.size}px;`,
    `--tok-reading-h1-lh: ${r.h1.lineHeight};`,
    `--tok-reading-h2-size: ${r.h2.size}px;`,
    `--tok-reading-h2-lh: ${r.h2.lineHeight};`,
    `--tok-reading-h3-size: ${r.h3.size}px;`,
    `--tok-reading-h3-lh: ${r.h3.lineHeight};`,
  ].map((l) => "  " + l).join("\n");

  const lifeClasses = (theme) =>
    LIFE_ORDER.map((s) => `.bp-lg--${s} { color: ${tokens.lifecycle[s].color[theme]}; }`).join("\n");

  return [
    ".bp-paper-surface, .bp-paper-body {",
    readingVars,
    statusVars("light", "  "),
    "}",
    "@media (prefers-color-scheme: dark) {",
    "  .bp-paper-surface, .bp-paper-body {",
    statusVars("dark", "    "),
    "  }",
    "}",
    'html[data-theme="light"] .bp-paper-surface, html[data-theme="light"] .bp-paper-body {',
    statusVars("light", "  "),
    "}",
    'html[data-theme="dark"] .bp-paper-surface, html[data-theme="dark"] .bp-paper-body {',
    statusVars("dark", "  "),
    "}",
    "/* lifecycle glyph tones — the CSS half of the §6 GUI/TUI parity assertion */",
    lifeClasses("light"),
    "@media (prefers-color-scheme: dark) {",
    lifeClasses("dark").split("\n").map((l) => "  " + l).join("\n"),
    "}",
  ].join("\n");
}

// ── surface: Studio (api/lib/barkpark_web/layouts/root.html.heex inline style) ─
// ADOPTION (W2.7): base roles now cascade to the hand-authored html[data-theme]
// blocks that follow — they no longer redefine --primary/--ring, so the emitted
// evergreen primary is live. Light base + status sit on :root; the DARK base is
// keyed on html[data-theme="dark"] (NOT @media) because Studio themes via a
// data-theme toggle, so the dark base must track the attribute (mirrors
// cloudBlock). Status dark stays under @media (unchanged). Emitted inside a
// <style>, hence CSS comment syntax and an extra 4-space indent to sit in block.
// On-fill status foregrounds (--ok-fg/--warn-fg/--danger-fg/--info-fg) + the
// zinc/chrome ladder (--bg-accent/--border-muted/--fg-dim/--fg-accent). Both are
// Studio-ONLY: no other surface consumes them, so they live here (studioBlock),
// NOT in the shared statusVars/baseVars that every CSS surface emits. Chrome
// values are HSL channels OR a bare var(--role) reference (border-muted light =
// --border; fg-accent dark = --text) — the emitter passes a var() through.
const STATUS_FG = ["ok-fg", "warn-fg", "danger-fg", "info-fg"];
const CHROME_ALIASES = ["bg-accent", "border-muted", "fg-dim", "fg-accent"];
const chromeVal = (v) => (v.startsWith("var(") ? v : hsl(v));

function onStatusVars(theme, indent) {
  const os = tokens.color.onStatus;
  return STATUS_FG.map((r) => indent + `--${r}: ${hsl(os[r][theme])};`).join("\n");
}
function chromeVars(theme, indent) {
  const ch = tokens.color.studioChrome;
  return CHROME_ALIASES.map((r) => indent + `--${r}: ${chromeVal(ch[r][theme])};`).join("\n");
}

// Chrome type scale → --text-<step> / --text-<step>-lh CSS vars (W2.7 gap close,
// Decision D2). Theme-invariant (size/line-height don't flip), so emitted ONLY in
// :root. The Studio styleguide type ladder renders straight off these vars.
function chromeTypeVars(indent) {
  const t = tokens.type.chrome;
  return TYPE_STEPS
    .map((s) => indent + `--text-${s}: ${t[s].size}px; --text-${s}-lh: ${t[s].lineHeight};`)
    .join("\n");
}

// Lifecycle glyph tones → --life-<state> CSS vars (Decision D1). The Studio MIRROR
// of the one lifecycle source (tokens.lifecycle.*.color) — the exact hues the Go
// board + paper-surface .bp-lg-- classes emit from. Theme-specific: light on
// :root, dark on html[data-theme="dark"]. Lets the styleguide colour a lifecycle
// glyph via var(--life-<state>) (an APPLIED-STYLE var, never a copied hex) and
// participates in the §6 cross-surface parity assertion (design/check.mjs Part B).
function lifeVars(theme, indent) {
  const life = tokens.lifecycle;
  return LIFE_ORDER.map((s) => indent + `--life-${s}: ${life[s].color[theme]};`).join("\n");
}

function studioBlock() {
  const ind = "    ";
  return [
    ind + ":root {",
    baseVars("light", ind + "  "),
    primaryVars("light", ind + "  "),
    statusVars("light", ind + "  "),
    onStatusVars("light", ind + "  "),
    chromeVars("light", ind + "  "),
    chromeTypeVars(ind + "  "),
    lifeVars("light", ind + "  "),
    ind + "}",
    ind + 'html[data-theme="dark"] {',
    baseVars("dark", ind + "  "),
    primaryVars("dark", ind + "  "),
    onStatusVars("dark", ind + "  "),
    chromeVars("dark", ind + "  "),
    lifeVars("dark", ind + "  "),
    ind + "}",
    ind + "@media (prefers-color-scheme: dark) {",
    ind + "  :root {",
    statusVars("dark", ind + "    "),
    ind + "  }",
    ind + "}",
  ].join("\n");
}

// ── surface: web demo (web/app/globals.css — Tailwind v4 @theme) ─────────────
// Light values register in a top-level @theme (Tailwind v4 requires @theme stay
// top-level — you cannot nest it under a selector or media query). Dark is an
// EXPLICIT [data-theme="dark"] override that redefines the same --color-* the
// theme registered; equal specificity to @theme's :root, but it comes LATER so
// it wins the cascade — mirroring cloudBlock()'s :root/[data-theme] pair. The
// OS-only @media block is intentionally dropped: default theme comes from the
// data-theme island (seeded from prefers-color-scheme), so the explicit toggle
// is the single source of truth and always wins.
function webBlock() {
  const st = tokens.color.status;
  return [
    "@theme {",
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(tokens.color[r].light)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].light)};`),
    "}",
    '[data-theme="dark"] {',
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(tokens.color[r].dark)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].dark)};`),
    "}",
  ].join("\n");
}

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
  ].join("\n");
}

// ── surface: Go board (internal/taskboard/tokens_gen.go) ─────────────────────
// Lifecycle glyph + adaptive hue + braille frames, mirroring theme.go/spinner.go
// values 1:1. Additive: no consumer is rewired — this is the generated twin the
// §6 gate compares against the CSS glyph tones.
// gofmt aligns contiguous map entries and var/const specs. Emit the same
// alignment up-front so gofmt is a no-op and the emitter output IS canonical.
function alignMap(rows) {
  const p = rows.map((r) => { const i = r.indexOf(": "); return { head: r.slice(0, i + 1), tail: r.slice(i + 2) }; });
  const w = Math.max(...p.map((x) => x.head.length));
  return p.map((x) => `${x.head.padEnd(w)} ${x.tail}`);
}
function alignEq(rows) {
  const p = rows.map((r) => { const i = r.indexOf(" = "); return { head: r.slice(0, i), tail: r.slice(i + 3) }; });
  const w = Math.max(...p.map((x) => x.head.length));
  return p.map((x) => `${x.head.padEnd(w)} = ${x.tail}`);
}

function goHeader(pkg) {
  return [
    "// Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "// Regenerate: node design/emit.mjs --write",
    "",
    `package ${pkg}`,
    "",
  ].join("\n");
}

function taskboardGo() {
  const life = tokens.lifecycle;
  const rows = LIFE_ORDER.map((s) => {
    const e = life[s];
    return `\t"${s}": {Glyph: "${glyphOf(e.codepoint)}", ASCIIGlyph: ${JSON.stringify(e.asciiGlyph)}, Role: ${JSON.stringify(e.role)}, ColorLight: "${e.color.light}", ColorDark: "${e.color.dark}"},`;
  });
  const frames = life.in_progress.frames.map((f) => `"${glyphOf(f)}"`).join(", ");
  return [
    goHeader("taskboard"),
    "// GenLifecycleToken mirrors one design/tokens.json lifecycle state.",
    "type GenLifecycleToken struct {",
    "\tGlyph      string",
    "\tASCIIGlyph string",
    "\tRole       string",
    "\tColorLight string",
    "\tColorDark  string",
    "}",
    "",
    "// GenLifecycle is the generated 1:1 mirror of tokens.lifecycle (glyph + hue).",
    "var GenLifecycle = map[string]GenLifecycleToken{",
    ...alignMap(rows),
    "}",
    "",
    "// GenLifecycleOrder is the canonical emission order (matches the source).",
    `var GenLifecycleOrder = []string{${LIFE_ORDER.map((s) => `"${s}"`).join(", ")}}`,
    "",
    "// GenBrailleFrames mirrors lifecycle.in_progress.frames (spinner.go).",
    `var GenBrailleFrames = [10]string{${frames}}`,
    "",
    "// GenBrailleStill is the reduced-motion steady frame.",
    `var GenBrailleStill = "${glyphOf(life.in_progress.framesStill)}"`,
    "",
  ].join("\n");
}

// ── surface: Go pdrender (internal/pdrender/tokens_gen.go) ────────────────────
// Reading tokens + the four semantic status tones as hex AdaptiveColors.
// Additive stub — pdrender's hand-tuned tone*/pd* vars are untouched.
function pdrenderGo() {
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
  return [
    goHeader("pdrender"),
    'import "github.com/charmbracelet/lipgloss"',
    "",
    "// Generated semantic status tones (design/tokens.json color.status → hex).",
    "var (",
    ...alignEq([tone("Info", "info"), tone("OK", "ok"), tone("Warn", "warn"), tone("Danger", "danger")]),
    ")",
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
  ].join("\n");
}

// ── surface: Go semrole (internal/semrole/tokens_gen.go) ─────────────────────
// The CLI truecolor source (Decision 3): the four status roles as hex
// AdaptiveColors, the seven lifecycle glyph hues (done/closed stay TEAL, not
// ok-green — Decision 4), and a pinned ANSI-16 SGR floor per role that the
// wave-2 colour ladder degrades to. info → blue (34) is the visible
// cross-surface coherence fix. Additive — no consumer is rewired here.
const SEMROLE_TONES = [["OK", "ok"], ["Info", "info"], ["Warn", "warn"], ["Danger", "danger"]];
const SEMROLE_ANSI16 = { ok: 32, info: 34, warn: 33, danger: 31 }; // green/blue/yellow/red
const pascal = (s) => s.split("_").map((w) => w[0].toUpperCase() + w.slice(1)).join("");

function semroleGo() {
  const st = tokens.color.status;
  const life = tokens.lifecycle;
  const tone = (name, role) =>
    `\tGen${name} = lipgloss.AdaptiveColor{Light: "${hslToHex(st[role].light)}", Dark: "${hslToHex(st[role].dark)}"}`;
  const hue = (s) =>
    `\tGen${pascal(s)}Hue = lipgloss.AdaptiveColor{Light: "${life[s].color.light}", Dark: "${life[s].color.dark}"}`;
  return [
    goHeader("semrole"),
    'import "github.com/charmbracelet/lipgloss"',
    "",
    "// Generated semantic status tones (design/tokens.json color.status → hex).",
    "var (",
    ...alignEq(SEMROLE_TONES.map(([name, role]) => tone(name, role))),
    ")",
    "",
    "// Generated lifecycle glyph hues (design/tokens.json lifecycle.*.color).",
    "// done/closed stay TEAL — deliberately distinct from status.ok green.",
    "var (",
    ...alignEq(LIFE_ORDER.map(hue)),
    ")",
    "",
    "// GenStatusTone maps a semantic role to its adaptive tone.",
    "var GenStatusTone = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(SEMROLE_TONES.map(([name, role]) => `\t"${role}": Gen${name},`)),
    "}",
    "",
    "// GenLifecycleHue maps a lifecycle state to its adaptive glyph hue.",
    "var GenLifecycleHue = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(LIFE_ORDER.map((s) => `\t"${s}": Gen${pascal(s)}Hue,`)),
    "}",
    "",
    "// GenANSI16 pins each status role to its basic-16 SGR foreground code — the",
    "// floor the CLI colour ladder degrades to. info → blue (34) is the visible",
    "// cross-surface coherence fix.",
    "var GenANSI16 = map[string]int{",
    ...alignMap(SEMROLE_TONES.map(([, role]) => `\t"${role}": ${SEMROLE_ANSI16[role]},`)),
    "}",
    "",
  ].join("\n");
}

// ── surface: Go CLI chrome (internal/semrole/chrome_gen.go) ──────────────────
// The ratified CLI/TUI chrome role set as hex AdaptiveColors, emitted into a
// SIBLING file (NOT tokens_gen.go) so the status/lifecycle artifact stays
// byte-stable and the #1394 board-parity risk is isolated. Nine NEW roles carry
// {light,dark} HEX directly (color.cliChrome[role] = {light,dark}); five REUSE
// roles are 'var(--role)' references RESOLVED here to the target role's hex —
// chrome-primary-cta → evergreen --primary (RECOLOR off the legacy #2563eb
// blue), chrome-on-primary → adaptive --primary-fg. Additive: the 27 call sites
// keep their lit-allows; a later wave threads GenChrome* through them.
const CLI_CHROME_NEW = [
  ["Accent", "chrome-accent"], ["Dim", "chrome-dim"], ["Ink", "chrome-ink"],
  ["TextSecondary", "chrome-text-secondary"], ["SelectionBg", "chrome-selection-bg"],
  ["SelectionFg", "chrome-selection-fg"], ["FieldBorder", "chrome-field-border"],
  ["ToolbarBg", "chrome-toolbar-bg"], ["CursorBg", "chrome-cursor-bg"],
];
const CLI_CHROME_REUSE = [
  ["Border", "chrome-border"], ["BorderActive", "chrome-border-active"],
  ["Label", "chrome-label"], ["PrimaryCta", "chrome-primary-cta"],
  ["OnPrimary", "chrome-on-primary"],
];
// Resolve a 'var(--role)' reference to its {light,dark} HSL channels. Status
// roles live under color.status (var(--info) → color.status.info); base roles
// sit directly on color.*.
function resolveChromeRef(ref) {
  const role = ref.replace(/^var\(--/, "").replace(/\)$/, "");
  return STATUS_ROLES.includes(role) ? tokens.color.status[role] : tokens.color[role];
}
// {light,dark} hex for a cliChrome role: NEW roles are hex already; REUSE roles
// resolve their reference to HSL channels then convert to hex.
function cliChromeHex(role) {
  const v = tokens.color.cliChrome[role];
  if (typeof v === "string") { const ch = resolveChromeRef(v); return { light: hslToHex(ch.light), dark: hslToHex(ch.dark) }; }
  return { light: v.light, dark: v.dark };
}
function cliChromeGo() {
  const line = (name, role) => {
    const h = cliChromeHex(role);
    return `\tGenChrome${name} = lipgloss.AdaptiveColor{Light: "${h.light}", Dark: "${h.dark}"}`;
  };
  const all = [...CLI_CHROME_NEW, ...CLI_CHROME_REUSE];
  // Cloud-console families (charter azure-hetzner Decision 7), emitted into the
  // SAME sibling (chrome_gen.go) so tokens_gen.go stays byte-stable. Provider
  // IDENTITY marks (hex) + the instance-lifecycle glyph/role/hue map. An
  // instance state's Hue is its status-role tone resolved to hex (role "" →
  // muted-text neutral) — colour is read THROUGH the role, never bespoke.
  const il = tokens.instanceLifecycle;
  const provRows = PROVIDERS.map(
    (k) => `\t"${k}": {Light: "${tokens.color.provider[k].light}", Dark: "${tokens.color.provider[k].dark}"},`,
  );
  const instRows = INST_ORDER.map((s) => {
    const e = il[s];
    const ch = instRoleChannels(e.role);
    return `\t"${s}": {Glyph: "${glyphOf(e.codepoint)}", ASCIIGlyph: ${JSON.stringify(e.asciiGlyph)}, Role: ${JSON.stringify(e.role)}, HueLight: "${hslToHex(ch.light)}", HueDark: "${hslToHex(ch.dark)}"},`;
  });
  return [
    goHeader("semrole"),
    'import "github.com/charmbracelet/lipgloss"',
    "",
    "// Generated CLI/TUI chrome roles (design/tokens.json color.cliChrome → hex).",
    "// Nine NEW hex roles + five REUSE references resolved to their target role's",
    "// hex (chrome-primary-cta = evergreen --primary; chrome-on-primary = --primary-fg).",
    "var (",
    ...alignEq(all.map(([name, role]) => line(name, role))),
    ")",
    "",
    "// GenChrome maps a cliChrome role name to its adaptive colour.",
    "var GenChrome = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(all.map(([name, role]) => `\t"${role}": GenChrome${name},`)),
    "}",
    "",
    "// GenProviderMark is the generated cloud-provider IDENTITY palette",
    "// (design/tokens.json color.provider → hex). Identity ONLY (Decision 7):",
    "// tint a chip mark or a chip/row border, NEVER a pill background — the",
    "// status roles stay the only state voice. Unconsumed until a later wave",
    "// threads it through the CLI provider-chip / table renderers.",
    "var GenProviderMark = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(provRows),
    "}",
    "",
    "// GenInstanceLifecycleToken mirrors one design/tokens.json instanceLifecycle",
    "// state. Hue is the state's status-role tone resolved to hex (role \"\" → the",
    "// muted-text neutral); the CLI reads colour THROUGH the role, never a bespoke",
    "// per-state hue (Decision 7).",
    "type GenInstanceLifecycleToken struct {",
    "\tGlyph      string",
    "\tASCIIGlyph string",
    "\tRole       string",
    "\tHueLight   string",
    "\tHueDark    string",
    "}",
    "",
    "// GenInstanceLifecycle is the generated 1:1 mirror of tokens.instanceLifecycle",
    "// (glyph + role + role-derived hue).",
    "var GenInstanceLifecycle = map[string]GenInstanceLifecycleToken{",
    ...alignMap(instRows),
    "}",
    "",
    "// GenInstanceLifecycleOrder is the canonical emission order (matches source).",
    `var GenInstanceLifecycleOrder = []string{${INST_ORDER.map((s) => `"${s}"`).join(", ")}}`,
    "",
  ].join("\n");
}

// ── surface: Elixir render tokens (api/.../render/tokens_gen.ex) ──────────────
// Whole generated Elixir module for the paper render surface (emails + article
// palettes): evergreen brand + foreground, rule, the four status tones, the
// tokenized terracotta reading accent, and the reading type. kind "elixir"
// (whole-file, like go/ts): check.mjs Part A byte-compares it. Additive — do
// NOT edit palettes.ex; that consumer lands in wave 2 (Decision 8).
function elixirTokensGen() {
  const c = tokens.color;
  const st = c.status;
  const r = tokens.type.reading;
  const hx = (role) => hslToHex(c[role].light);
  const stx = (role) => hslToHex(st[role].light);
  return [
    "# Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "# Regenerate: node design/emit.mjs --write",
    "",
    "defmodule Barkpark.PortableDoc.Render.TokensGen do",
    '  @moduledoc """',
    "  Unified Aesthetic tokens for the paper render surface (emails + article",
    "  palettes), generated from design/tokens.json. Regenerate with",
    "  `node design/emit.mjs --write`; never hand-edit. Additive until wave 2,",
    "  when palettes.ex adopts it (email indigo → evergreen brand; article accent",
    "  → tokenized terracotta).",
    '  """',
    "",
    "  # Evergreen brand — the paper/email accent, its foreground, and the hairline.",
    `  def brand, do: "${hx("primary")}"`,
    `  def brand_text, do: "${hx("primary-fg")}"`,
    `  def rule, do: "${hx("border")}"`,
    "",
    "  # Semantic status tones (design/tokens.json color.status, light theme → hex).",
    `  def tone_ok, do: "${stx("ok")}"`,
    `  def tone_info, do: "${stx("info")}"`,
    `  def tone_warn, do: "${stx("warn")}"`,
    `  def tone_danger, do: "${stx("danger")}"`,
    "",
    "  # Warm reading accent — the paper terracotta, tokenized.",
    `  def reading_accent, do: "${hx("reading-accent")}"`,
    "",
    "  # Reading type (design/tokens.json font.reading / type.reading).",
    // Via a module attribute so the long font-stack literal is a `mix format`
    // fixed point — a bare `def _, do: "<long>"` gets reflowed, which would flap
    // the byte-exact drift gate the moment anyone runs the formatter.
    `  @reading_font ${JSON.stringify(tokens.font.reading.stack)}`,
    "  def reading_font, do: @reading_font",
    `  def reading_heading_weight, do: ${r.headingWeight}`,
    `  def reading_body_size, do: ${r.body.size}`,
    "end",
    "",
  ].join("\n");
}

// ── surface: Studio categorical tokens (api/.../studio/tokens_gen.ex) ─────────
// Whole generated Elixir module for the STUDIO surface's CATEGORICAL palettes:
// the 8 presence-avatar hues + the two Sheets-CF swatch lists (pastel cell/rule
// backgrounds + saturated per-tab dots). These are HEX VALUE lists, not status
// roles and not CSS vars — the swatch hex is PERSISTED DATA (stored on the
// cell/rule/tab, compared for selection, echoed in data-test-id), so the
// concrete literal must survive. kind "elixir" (whole-file, like the render
// TokensGen); check.mjs Part A byte-compares it. Distinct module from the
// paper-render TokensGen — different layer, different consumer.
function studioTokensGen() {
  const p = tokens.color.presence.palette;
  const cf = tokens.color.sheetCf;
  const sh = tokens.color.statusHealth;
  const list = (arr) => arr.map((h) => `"${h}"`).join(", ");
  const life = tokens.lifecycle;
  const lifeRows = LIFE_ORDER.map((s) => {
    const e = life[s];
    return `      %{state: "${s}", glyph: "${glyphOf(e.codepoint)}", ascii: ${JSON.stringify(e.asciiGlyph)}, light: "${e.color.light}", dark: "${e.color.dark}"}`;
  }).join(",\n");
  const frames = life.in_progress.frames.map(glyphOf).join(" ");
  return [
    "# Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "# Regenerate: node design/emit.mjs --write",
    "",
    "defmodule BarkparkWeb.Studio.TokensGen do",
    '  @moduledoc """',
    "  Unified Aesthetic Studio-surface tokens, generated from design/tokens.json.",
    "  Regenerate with `node design/emit.mjs --write`; never hand-edit.",
    "",
    "  Two families live here, both as returned VALUES (not CSS vars):",
    "",
    "    * CATEGORICAL identity swatches (presence + Sheets-CF hex lists): presence",
    "      hues index by a phash2 of the user id, and the Sheets-CF swatches are",
    "      PERSISTED DATA (stored on the cell/rule/tab, compared for selection,",
    "      echoed in data-test-id) — the concrete hex must survive.",
    "    * The LIFECYCLE mirror (glyph / ascii / adaptive hue per state) — the",
    "      Studio twin of the ONE lifecycle source (tokens.lifecycle) the Go board",
    "      + paper-surface CSS also emit from. It feeds the living styleguide's",
    "      lifecycle row (glyph + braille + colour label); the applied glyph COLOUR",
    "      comes from the emitted --life-<state> CSS var, so no hex is ever painted",
    "      inline. design/check.mjs §6 gates this mirror against Go + CSS + tokens.",
    '  """',
    "",
    "  # Presence-avatar palette (presence_state.ex @colors) — 8 fixed categorical",
    "  # hues; a phash2 of the user id picks one.",
    `  def presence_palette, do: ~w(${p.join(" ")})`,
    "",
    "  # Sheets conditional-format cell/rule backgrounds — the pastel fills",
    "  # (sheet_grid.ex bg-swatch loop). PERSISTED as phx-value-bg.",
    `  def sheet_cf_backgrounds, do: ~w(${cf.background.join(" ")})`,
    "",
    "  # Sheets per-tab colors — the saturated dot strip (sheet_grid.ex tab-color",
    "  # picker). Read best more vivid than the pastel cell backgrounds.",
    `  def sheet_tab_colors, do: ~w(${cf.tab.join(" ")})`,
    "",
    "  # Public status-page health-severity DATA tones (status_controller.ex",
    "  # @labels + component dots) — inline-style hex conveying OUTAGE SEVERITY,",
    "  # NOT a CSS role. partial_outage is an out-of-model tone between warn-amber",
    "  # (degraded) and danger-red (major_outage): the severity distinction must",
    "  # survive, so it is NOT recolored onto --warn/--danger.",
    `  def status_health, do: %{operational: "${sh.operational}", degraded: "${sh.degraded}", partial_outage: "${sh.partial_outage}", major_outage: "${sh.major_outage}"}`,
    "",
    "  # Neutral gray fallback for an unrecognised / missing status.",
    `  def status_health_unknown, do: "${sh.unknown}"`,
    "",
    "  # Lifecycle mirror — one row per state, canonical emission order. glyph +",
    "  # ascii are text CONTENT; light/dark are the adaptive hue LABELS (the applied",
    "  # colour is var(--life-<state>) from the GENERATED CSS block). Mirrors",
    "  # tokens.lifecycle 1:1; done/closed stay TEAL, distinct from status.ok green.",
    "  def lifecycle do",
    "    [",
    lifeRows,
    "    ]",
    "  end",
    "",
    "  # in_progress braille spinner frames (spinner.go / tokens.lifecycle frames).",
    `  def lifecycle_frames, do: ~w(${frames})`,
    "end",
    "",
  ].join("\n");
}

// ── page-scoped surfaces (self-contained Studio pages) ───────────────────────
// The login / error / status / sheets pages each carry their OWN scoped <style>
// (:root or a scoped selector) — the root-layout emitted tokens do NOT cascade
// in — so each de-literalizes onto its OWN page-scoped marker-splice block.
// These are CSS artifacts like the surfaces above, but their marker sits inside
// an .ex/.heex <style> (heredoc or ~H), so each builder bakes the page's own
// indentation. An "hsl OR var() OR #hex passthrough" value formatter lets a
// value be a token channel (→ hsl()), a var(--role) reference, or a raw hex.
const pageVal = (v) => (v.startsWith("var(") || v.startsWith("#") ? v : hsl(v));

// ── surface: login (api/lib/barkpark_web/controllers/session_html.ex) ────────
// The auth pages' brand override — evergreen --primary/--ring (the exact emitted
// primary/ring tokens) + the decoupled auth button fills (color.authButton),
// scoped under .bp-auth. Light on the scoped selector; dark keyed on
// html[data-theme="dark"] .bp-auth (Studio themes via the data-theme attribute).
// Indented 6 spaces to sit inside the ~H <style>. The ring-soft alpha reuses the
// shared softAlpha convention (0.15 light / 0.2 dark).
function sessionAuthBlock() {
  const c = tokens.color;
  const ab = c.authButton;
  const rows = (theme) => [
    `--primary: ${hsl(c.primary[theme])};`,
    `--primary-fg: ${hsl(c["primary-fg"][theme])};`,
    `--ring: ${hsl(c.ring[theme])};`,
    `--ring-soft: hsl(${c.ring[theme]} / ${alpha(softAlpha[theme])});`,
    `--btn-bg: ${pageVal(ab.bg[theme])};`,
    `--btn-fg: ${pageVal(ab.fg[theme])};`,
    `--btn-bg-hover: ${pageVal(ab.bgHover[theme])};`,
  ];
  const ind = "      ";
  return [
    ind + ".bp-auth {",
    ...rows("light").map((l) => ind + "  " + l),
    ind + "}",
    ind + 'html[data-theme="dark"] .bp-auth {',
    ...rows("dark").map((l) => ind + "  " + l),
    ind + "}",
  ].join("\n");
}

// ── surface: error page (api/lib/barkpark_web/controllers/error_html.ex) ─────
// The 404/500 page is INTENTIONALLY ALWAYS-DARK (a stark error card, no theme
// switch). De-literalized WITHOUT becoming theme-aware: a single fixed-dark
// :root carrying color.errorPage (bg/fg/muted, single values). Indented 10
// spaces to sit inside the heredoc <style>.
function errorPageBlock() {
  const e = tokens.color.errorPage;
  const ind = "          ";
  return [
    ind + ":root {",
    ind + `  --err-bg: ${e.bg};`,
    ind + `  --err-fg: ${e.fg};`,
    ind + `  --err-muted: ${e.muted};`,
    ind + "}",
  ].join("\n");
}

// ── surface: status page (api/lib/barkpark_web/controllers/status_controller.ex)
// The public /status page's self-contained chrome palette (color.statusChrome,
// theme-aware via prefers-color-scheme). color-scheme + the health-severity DATA
// tones stay OUTSIDE this block — the tones are inline-style DATA emitted via
// BarkparkWeb.Studio.TokensGen.status_health/0. Indented 6 spaces (heredoc
// <style>). Hex passthrough (bespoke zinc, byte-preserving the chrome).
function statusChromeBlock() {
  const sc = tokens.color.statusChrome;
  const vars = (theme) =>
    ["bg", "fg", "muted", "card", "line"].map((r) => `--${r}:${sc[r][theme]};`).join(" ");
  const ind = "      ";
  return [
    ind + `:root { ${vars("light")} }`,
    ind + `@media (prefers-color-scheme: dark){ :root{ ${vars("dark")} } }`,
  ].join("\n");
}

// ── surface: /sheets reader (api/lib/barkpark_web/layouts/sheets.html.heex) ──
// The parchment reader's info-blue link + focus ring (color.readerInfo): a
// WCAG-safe darker blue-600 on the light parchment, lifting to info-role
// blue-500 on the dark parchment. --ring binds to --info so the reader's focus
// rings stay blue (their prior hardcoded fallback intent). Indented 4 spaces
// (heex <style>). Sits AFTER the hand-authored parchment :root; global :root
// vars, so they cascade to .sheet-link / .btn / .sheet-* focus rules.
function sheetsBlock() {
  const ri = tokens.color.readerInfo;
  const ind = "    ";
  return [
    ind + `:root { --info: ${ri.light}; --ring: var(--info); }`,
    ind + `@media (prefers-color-scheme: dark) { :root { --info: ${ri.dark}; } }`,
  ].join("\n");
}

// ── artifact registry ────────────────────────────────────────────────────────
// kind "css"             : splice content between the shared marker block.
// kind "go"/"ts"/"elixir": the build() is the WHOLE file.
export const ARTIFACTS = [
  { name: "cloud SPA", path: "cloud/priv/static/app.css", kind: "css", build: cloudBlock },
  { name: "paper-surface", path: "api/assets/paper-surface/paper-surface.css", kind: "css", build: paperBlock },
  { name: "Studio", path: "api/lib/barkpark_web/layouts/root.html.heex", kind: "css", build: studioBlock },
  { name: "web demo", path: "web/app/globals.css", kind: "css", build: webBlock },
  { name: "web TS tokens", path: "web/lib/tokens.gen.ts", kind: "ts", build: webTokensTs },
  { name: "Go board", path: "internal/taskboard/tokens_gen.go", kind: "go", build: taskboardGo },
  { name: "Go pdrender", path: "internal/pdrender/tokens_gen.go", kind: "go", build: pdrenderGo },
  { name: "Go semrole", path: "internal/semrole/tokens_gen.go", kind: "go", build: semroleGo },
  { name: "Go CLI chrome", path: "internal/semrole/chrome_gen.go", kind: "go", build: cliChromeGo },
  { name: "Elixir render tokens", path: "api/lib/barkpark/portable_doc/render/tokens_gen.ex", kind: "elixir", build: elixirTokensGen },
  { name: "Elixir Studio categorical tokens", path: "api/lib/barkpark_web/studio/tokens_gen.ex", kind: "elixir", build: studioTokensGen },
  { name: "login (session_html)", path: "api/lib/barkpark_web/controllers/session_html.ex", kind: "css", build: sessionAuthBlock },
  { name: "error page (error_html)", path: "api/lib/barkpark_web/controllers/error_html.ex", kind: "css", build: errorPageBlock },
  { name: "status page chrome", path: "api/lib/barkpark_web/controllers/status_controller.ex", kind: "css", build: statusChromeBlock },
  { name: "/sheets reader", path: "api/lib/barkpark_web/layouts/sheets.html.heex", kind: "css", build: sheetsBlock },
];

// Tolerant of leading indentation on the marker lines (Studio's markers sit
// indented inside a <style> block); the captured groups preserve that whitespace.
const markerRe = new RegExp(
  `([ \\t]*${escapeRe(MARKER_BEGIN)}\\n)([\\s\\S]*?)(\\n[ \\t]*${escapeRe(MARKER_END)})`
);
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

// Compute {expected, current, path, kind, name} for one artifact. `expected` is
// the desired full file text; `current` is what's on disk. A missing marker for a
// css artifact is a hard error (surface not prepared with the marker block).
export function evaluate(a) {
  const abs = join(repoRoot, a.path);
  let current;
  try { current = readFileSync(abs, "utf8"); }
  catch { current = null; }
  const content = a.build();

  if (a.kind !== "css") {
    // whole-file artifacts (Go, TS): the build() output IS the entire file.
    return { ...a, abs, current, expected: content };
  }
  // css: splice into the marker block of the CURRENT file
  const base = current == null ? "" : current;
  const m = base.match(markerRe);
  if (!m) {
    return { ...a, abs, current, expected: null, error: `no BEGIN/END GENERATED: tokens marker in ${a.path}` };
  }
  const expected = base.slice(0, m.index) + m[1] + content + m[3] + base.slice(m.index + m[0].length);
  return { ...a, abs, current, expected };
}

export function evaluateAll() { return ARTIFACTS.map(evaluate); }

function run(mode) {
  const results = evaluateAll();
  let changed = 0, errored = 0;
  for (const r of results) {
    if (r.error) { console.error(`  ERROR ${r.name}: ${r.error}`); errored++; continue; }
    const drift = r.current !== r.expected;
    if (mode === "write") {
      if (drift) { writeFileSync(r.abs, r.expected); console.log(`  WROTE ${r.name} (${r.path})`); changed++; }
      else { console.log(`  ok    ${r.name} (already current)`); }
    } else {
      if (drift) { console.error(`  DRIFT ${r.name} (${r.path})`); changed++; }
      else { console.log(`  ok    ${r.name}`); }
    }
  }
  // Post-step: the paper-editor token mirror. It is DERIVED from the just-emitted
  // paper-surface.css (a second generation hop), so it runs AFTER the artifact
  // loop has written paper-surface.css to disk. One shared transform with
  // design/check.mjs + scripts/paper-editor-mirror-check.sh — they can't disagree.
  const mr = evaluateMirror(repoRoot);
  if (mr.error) {
    console.error(`  ERROR ${mr.name}: ${mr.error}`);
    errored++;
  } else {
    const drift = mr.current !== mr.expected;
    if (mode === "write") {
      if (drift) { writeFileSync(mr.abs, mr.expected); console.log(`  WROTE ${mr.name} (${mr.path})`); changed++; }
      else { console.log(`  ok    ${mr.name} (already current)`); }
    } else {
      if (drift) { console.error(`  DRIFT ${mr.name} (${mr.path})`); changed++; }
      else { console.log(`  ok    ${mr.name}`); }
    }
  }

  if (errored) { console.error(`emit: ${errored} artifact(s) missing their marker block.`); process.exit(1); }
  if (mode !== "write" && changed) {
    console.error(`\nemit --check: ${changed} artifact(s) DRIFTED from design/tokens.json. Fix: node design/emit.mjs --write`);
    process.exit(1);
  }
  const total = results.length + 1; // + paper-editor mirror
  console.log(mode === "write"
    ? `emit --write: ${changed} artifact(s) regenerated, ${total - changed} already current.`
    : `emit --check: all ${total} artifacts in sync (${results.length} surfaces + paper-editor mirror).`);
}

// CLI
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const mode = process.argv.includes("--write") ? "write" : "check";
  run(mode);
}
