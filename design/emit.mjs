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
function cloudBlock() {
  return [
    ":root {",
    baseVars("light", "  "),
    primaryVars("light", "  "),
    statusVars("light", "  "),
    "}",
    '[data-theme="dark"] {',
    baseVars("dark", "  "),
    primaryVars("dark", "  "),
    statusVars("dark", "  "),
    "}",
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
function studioBlock() {
  const ind = "    ";
  return [
    ind + ":root {",
    baseVars("light", ind + "  "),
    primaryVars("light", ind + "  "),
    statusVars("light", ind + "  "),
    ind + "}",
    ind + 'html[data-theme="dark"] {',
    baseVars("dark", ind + "  "),
    primaryVars("dark", ind + "  "),
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
  return [
    "// Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "// Regenerate: node design/emit.mjs --write",
    "",
    "/** Light-theme canvas colours for listings-map.tsx, mapped from design/tokens.json. */",
    "export const canvas = {",
    ...rows.map(([k, role]) => `  ${k}: "${c(role)}",`),
    "} as const;",
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
  { name: "Elixir render tokens", path: "api/lib/barkpark/portable_doc/render/tokens_gen.ex", kind: "elixir", build: elixirTokensGen },
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
