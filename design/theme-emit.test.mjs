// design/theme-emit.test.mjs — the N-theme emission + mirror-scoping proofs for
// the Wave-4 [data-bp-theme] attribute axis (theme-system charter D23–D27).
// Zero-dep (node:test + node:assert). Run: node design/theme-emit.test.mjs
//
// design/themes/ ships evergreen ONLY (check.mjs Part F characterizes exactly it).
// The N-theme path is proven HERE with a FIXTURE theme that lives outside
// design/themes/ (design/fixtures/theme-fixture.json) and is never rendered into a
// real artifact — so a second theme can be exercised end-to-end without a shipped
// second skin (D24).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ARTIFACTS, themePalette } from "./emit.mjs";
import { computeMirror } from "./paper-editor-mirror.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const read = (p) => JSON.parse(readFileSync(join(here, p), "utf8"));

const evergreen = read("themes/evergreen.json");
const fixture = read("fixtures/theme-fixture.json");
const EVER = [{ name: "evergreen", spec: evergreen }];
const THEMES = [
  { name: "evergreen", spec: evergreen },
  { name: "fixture", spec: fixture },
];

const build = (suffix, themes) =>
  ARTIFACTS.find((a) => a.path.endsWith(suffix)).build(themes);

// The five DOM-attribute surfaces (cloud/Studio/web/login/paper) render explicit
// html[data-bp-theme=X] blocks; the value we probe per surface.
const ATTR = [
  ["static/app.css", "cloud"],
  ["layouts/root.html.heex", "Studio"],
  ["web/app/globals.css", "web"],
  ["controllers/session_html.ex", "login"],
  ["paper-surface.css", "paper-surface"],
];

test("N-theme: every attribute surface renders a DISTINCT block per injected theme", () => {
  for (const [suffix, name] of ATTR) {
    const out = build(suffix, THEMES);
    assert.match(out, /\[data-bp-theme="evergreen"\]/, `${name}: no evergreen block`);
    assert.match(out, /\[data-bp-theme="fixture"\]/, `${name}: no fixture block — N-theme emission did not generalize`);
  }
});

test("N-theme: the fixture's derived brand differs from evergreen's (values actually vary)", () => {
  // cloud declares --primary in both theme scopes; the fixture accent (265°
  // indigo) must not collapse onto evergreen's (163° evergreen).
  const cloud = build("static/app.css", THEMES);
  const ever = cloud.match(/html\[data-bp-theme="evergreen"\] \{[^}]*?--primary: (hsl\([^)]*\));/);
  const fix = cloud.match(/html\[data-bp-theme="fixture"\] \{[^}]*?--primary: (hsl\([^)]*\));/);
  assert.ok(ever && fix, "could not read --primary from both theme scopes");
  assert.notEqual(fix[1], ever[1], "fixture --primary equals evergreen — the theme did not change the palette");
  // and the fixture brand is its authored indigo accent.
  assert.equal(fix[1], "hsl(265 60% 45%)");
});

test("evergreen theme palette equals base tokens byte-for-byte (fallback === theme block)", () => {
  // themePalette(evergreen) must reproduce the shipped bytes — Part F's guarantee,
  // re-checked at the emit seam so the evergreen block can never silently retint.
  const p = themePalette(evergreen);
  assert.equal(p.color.primary.light, "151.96 71.81% 29.22%");
  assert.equal(p.color.primary.dark, "152.92 60% 52.94%");
  assert.equal(p.color.paper.surface.ink.light, "#15211d");
});

test("D25: no positional-passthrough var leaks into any per-theme block", () => {
  const banned = /--life-[\w-]+|--provider-[\w-]+|\.bp-lg--|\.bp-inst--/;
  for (const [suffix, name] of ATTR) {
    const out = build(suffix, THEMES);
    for (const m of out.matchAll(/\[data-bp-theme="[\w-]+"\][^{]*\{([^}]*)\}/g))
      assert.doesNotMatch(m[1], banned, `${name}: a passthrough var/class leaked into a theme block`);
  }
});

test("mirror: a [data-bp-theme] paper-surface scope is de-scoped, NOT skipped or collapsed (D27)", () => {
  // A synthetic paper-surface.css: base light/dark + a fixture theme's light/dark.
  const surface = [
    ".bp-paper-surface, .bp-paper-body {",
    "  --paper-bg: #ffffff;",
    "  --paper-ink: #111111;",
    "}",
    'html[data-theme="dark"] .bp-paper-surface, html[data-theme="dark"] .bp-paper-body {',
    "  --paper-bg: #000000;",
    "  --paper-ink: #eeeeee;",
    "}",
    'html[data-bp-theme="fixture"] .bp-paper-surface, html[data-bp-theme="fixture"] .bp-paper-body {',
    "  --paper-bg: #123456;",
    "}",
    'html[data-bp-theme="fixture"][data-theme="dark"] .bp-paper-surface, html[data-bp-theme="fixture"][data-theme="dark"] .bp-paper-body {',
    "  --paper-bg: #654321;",
    "}",
  ].join("\n");
  const bundle =
    "/* BEGIN GENERATED: paper-surface (x) */\nOLD\n/* END GENERATED: paper-surface */\n";
  const { generated } = computeMirror(surface, bundle);

  // The fixture scope is EMITTED as its own theme-identity scope (not skipped).
  assert.match(generated, /:root\[data-bp-theme="fixture"\], :host\(\[data-bp-theme="fixture"\]\) \{/);
  assert.match(generated, /:root\[data-bp-theme="fixture"\]\[data-theme="dark"\], :host\(\[data-bp-theme="fixture"\]\[data-theme="dark"\]\) \{/);

  // The fixture LIGHT value lives in the fixture scope …
  const fixLight = generated.match(/:root\[data-bp-theme="fixture"\], :host\(\[data-bp-theme="fixture"\]\) \{([\s\S]*?)\}/);
  assert.match(fixLight[1], /--paper-bg: #123456;/);
  // … and its DARK value in the fixture dark scope.
  const fixDark = generated.match(/:root\[data-bp-theme="fixture"\]\[data-theme="dark"\][^{]*\{([\s\S]*?)\}/);
  assert.match(fixDark[1], /--paper-bg: #654321;/);

  // NOT collapsed: the BASE :root scope keeps the base white, unpolluted by the
  // fixture theme's value (the last-write-wins bug D27 guards against).
  const base = generated.match(/^:root, :host \{([\s\S]*?)\}/m);
  assert.match(base[1], /--paper-bg: #ffffff;/);
  assert.doesNotMatch(base[1], /#123456/);
});

// ── the GENERATED (non-CSS) surfaces: Go x4 + Elixir TokensGen (ts-w5b) ──────
// The four Go builders + elixirTokensGen carry one keyed entry per committed
// theme. The evergreen entry REFERENCES the Gen* vars (Go) / equals the base
// hex (Elixir) so N=1 stays byte-identical; theme N+1 stamps a derived literal
// entry. Each map's evergreen segment must survive byte-for-byte when a second
// (fixture) theme is injected — the loop is additive, never a rewrite.
const GEN = [
  // [suffix, evergreen-entry anchor (present at N=1 AND unchanged at N=2)]
  ["taskboard/tokens_gen.go", '"evergreen": {Lifecycle: GenLifecycle, BrailleFrames: GenBrailleFrames, BrailleStill: GenBrailleStill},'],
  ["pdrender/tokens_gen.go", "ToneNeutral:         GenToneNeutral,"],
  ["semrole/tokens_gen.go", '"evergreen": {StatusTone: GenStatusTone, LifecycleHue: GenLifecycleHue, ANSI16: GenANSI16},'],
  ["semrole/chrome_gen.go", '"evergreen": {Chrome: GenChrome},'],
];

test("Go builders: N=1 references Gen* vars and emits no second theme", () => {
  for (const [suffix, anchor] of GEN) {
    const n1 = build(suffix, EVER);
    assert.ok(n1.includes(anchor), `${suffix}: evergreen Gen* reference missing at N=1`);
    assert.ok(!n1.includes('"fixture"'), `${suffix}: N=1 leaked a fixture entry`);
  }
});

test("Go builders: N=2 keeps the evergreen Gen* entry byte-identical AND adds a fixture literal entry", () => {
  for (const [suffix, anchor] of GEN) {
    const n2 = build(suffix, THEMES);
    assert.ok(n2.includes(anchor), `${suffix}: evergreen entry drifted when a second theme was injected`);
    assert.ok(n2.includes('"fixture": {'), `${suffix}: fixture entry missing — the loop did not generalize`);
  }
});

test("pdrender: the whole evergreen genPalette entry is byte-identical N=1 vs N=2", () => {
  // Non-anchor proof: extract the evergreen map block (up to its closing `\t},`)
  // and demand it is unchanged — no reorder, no retint, no Gen*→literal swap.
  const block = (s) => s.match(/\t"evergreen": \{[\s\S]*?\n\t\},/)[0];
  assert.equal(block(build("pdrender/tokens_gen.go", THEMES)), block(build("pdrender/tokens_gen.go", EVER)));
});

test("Go builders: the fixture entry carries DERIVED literals, not Gen* references", () => {
  // pdrender's fixture ChromeAccent must be the indigo-derived hex, proving the
  // non-evergreen entry stamps themePalette values (not a copy of the Gen* var).
  const n2 = build("pdrender/tokens_gen.go", THEMES);
  const fx = n2.match(/\t"fixture": \{[\s\S]*?\n\t\},/)[0];
  assert.match(fx, /ChromeAccent:\s+lipgloss\.AdaptiveColor\{Light: "#[0-9a-f]{6}", Dark: "#[0-9a-f]{6}"\}/);
  assert.doesNotMatch(fx, /GenChromeAccent/);
});

test("semrole: Themes() enumerates the committed theme dir and grows by one per theme", () => {
  assert.ok(build("semrole/tokens_gen.go", EVER).includes('func Themes() []string { return []string{"evergreen"} }'));
  assert.ok(build("semrole/tokens_gen.go", THEMES).includes('func Themes() []string { return []string{"evergreen", "fixture"} }'));
});

test("Elixir TokensGen: @themes + every colour map gains the fixture; N=1 is evergreen-only", () => {
  const n1 = build("render/tokens_gen.ex", EVER);
  assert.ok(n1.includes("@themes [:evergreen]"), "N=1 @themes is not evergreen-only");
  assert.ok(!n1.includes(":fixture") && !n1.includes("fixture:"), "N=1 leaked a fixture entry");

  const n2 = build("render/tokens_gen.ex", THEMES);
  assert.ok(n2.includes("@themes [:evergreen, :fixture]"), "@themes did not gain :fixture");
  // status, reading_accent, email and callout are ALL block maps now, one theme
  // per line. status/reading_accent used to be one-liners; they were reshaped
  // once five themes pushed them past `mix format`'s 98 columns, which is what
  // made the emitter stop being a format fixed point and reddened the drift gate.
  assert.match(n2, /@status %\{\n {4}evergreen: %\{[^}]*\},\n {4}fixture: %\{/);
  assert.match(n2, /@reading_accent %\{\n {4}evergreen: "[^"]*",\n {4}fixture: "[^"]*"\n {2}\}/);
  assert.ok(n2.includes("    fixture: %{"), "email/callout block maps missing the fixture entry");
});

test("Elixir TokensGen: the evergreen @status entry is byte-identical N=1 vs N=2", () => {
  // The ENTRY, deliberately not its separator: at N=1 evergreen is last and
  // carries no comma, at N=2 it does. The property under test is that adding a
  // theme does not RETINT evergreen, not how the list is punctuated. `%{ok:` is
  // unique to the status map — email/callout open with a newline after `%{`.
  const status = (s) => s.match(/^ {4}evergreen: %\{ok:[^\n]*?\}/m)[0];
  assert.equal(status(build("render/tokens_gen.ex", THEMES)), status(build("render/tokens_gen.ex", EVER)));
});

test("mirror: a token scope mixing theme identity across comma-parts is a hard error", () => {
  const surface = [
    'html[data-bp-theme="a"] .bp-paper-surface, html[data-bp-theme="b"] .bp-paper-body {',
    "  --paper-bg: #123456;",
    "}",
  ].join("\n");
  const bundle = "/* BEGIN GENERATED: paper-surface (x) */\nOLD\n/* END GENERATED: paper-surface */\n";
  assert.throws(() => computeMirror(surface, bundle), /mixes theme\/mode/);
});
