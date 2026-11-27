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
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ARTIFACTS, themePalette, loadThemes, TEMPLATE_TOKENS_MARKER_BEGIN } from "./emit.mjs";
import { computeMirror } from "./paper-editor-mirror.mjs";
import { BRAND_SURFACES, softSides } from "./emit/barkui-surfaces.mjs";
import { stepsFor } from "./emit/barkui-states.mjs";
import { contrast, hexToRgb, hslToHex, maxChroma, oklchToSrgb, parseColor, rgbToHex, srgbToOklch, toHslTriplet } from "./derive.mjs";

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
  ["01-components-generated-theme.css", "paper-surface"],
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
  assert.equal(p.color.primary.light, "44.1 72.81% 55.29%");
  assert.equal(p.color.primary.dark, "45.21 75.53% 63.14%");
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

// ── starter templates: the registry is a PREDICATE, not a list ───────────────
// (stw-backlog-theme-matrix). The two search-starter editions used to carry a
// hand-kept COPY of webBlock()'s output. A copy cannot grow, and it did not: a
// fifth shipped skin (`iris`) was absent from both, and 77 of 151 (selector, var)
// pairs had drifted. The region is now an emit.mjs artifact built by webBlock()
// itself, and the three tests below hold that true by RULE — none of them names a
// theme, a count, or a template path, so a sixth theme or a third template edition
// is caught the same way the fifth and the second were not.
const TEMPLATES_DIR = join(here, "..", "templates");

// Every template file that declares a theme-identity block. Discovered by
// WALKING the tree, never enumerated: a new template edition that pastes a
// palette is a subject of this test the moment it lands.
function templateThemeFiles() {
  const out = [];
  const walk = (dir) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      if (e.name === "node_modules" || e.name === "dist" || e.name === ".next") continue;
      const p = join(dir, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (!/\.(css|scss)$/.test(e.name)) continue;
      const text = readFileSync(p, "utf8");
      if (text.includes('[data-bp-theme="')) out.push([p, text]);
    }
  };
  walk(TEMPLATES_DIR);
  return out;
}

test("templates: every theme-identity stylesheet under templates/ is a REGISTERED emit.mjs artifact", () => {
  const found = templateThemeFiles();
  // The control. An empty scan would make every assertion below vacuously true,
  // and a silent zero is exactly how the iris hole survived: nothing looked.
  assert.ok(found.length > 0,
    "scanned templates/ and found NO stylesheet declaring [data-bp-theme=…]. " +
    "Either the walk is broken or the templates lost their theme blocks; both are failures, not a pass.");

  const registered = new Set(ARTIFACTS.map((a) => join(here, "..", a.path)));
  const orphans = found.map(([p]) => p).filter((p) => !registered.has(p));
  assert.deepEqual(orphans, [],
    "these template stylesheets carry a [data-bp-theme=…] palette that NO design/emit.mjs " +
    "ARTIFACTS entry owns, so `node design/emit.mjs --write` cannot reach them and a new " +
    "theme will never arrive there:\n  " + orphans.join("\n  "));
});

test("templates: every SHIPPED theme has an on-disk identity block in every template stylesheet", () => {
  const themes = loadThemes();
  assert.ok(themes.length > 0, "loadThemes() returned nothing — the check below would be vacuous.");
  const found = templateThemeFiles();
  assert.ok(found.length > 0, "no template stylesheet found — see the control above.");

  for (const [p, text] of found) {
    for (const { name } of themes) {
      assert.ok(text.includes(`[data-bp-theme="${name}"] {`),
        `${p} has no [data-bp-theme="${name}"] block. design/themes/ ships it, so a visitor ` +
        `selecting it silently renders the fallback. Run: node design/emit.mjs --write`);
    }
  }
  // NEGATIVE control: a name design/themes/ does NOT ship must be absent, or the
  // assertion above would pass on a file that simply contains every string.
  const ghost = "__no_such_theme__";
  assert.ok(!themes.some((t) => t.name === ghost), "fixture name collided with a real theme");
  for (const [p, text] of found) {
    assert.ok(!text.includes(`[data-bp-theme="${ghost}"] {`), `${p} matched a theme that does not exist`);
  }
});

// ── the BarkUI sheet: today's skins under UI SDK's variable names ────────────
// api/priv/barkui/tokens.css is one more whole generated file. It must carry
// every shipped skin x {light, dark} under BarkUI's names, and each value must be
// the same string the Studio region writes for the slot it comes from, so the two
// can never drift. The names and their Studio sources are written out here, not
// read from the module, so a rename on either side reds this test.
const BARKUI_PATH = "api/priv/barkui/tokens.css";
const BARKUI_SOURCES = {
  "--ui-background": "--bg",
  "--ui-foreground": "--text",
  "--ui-border": "--border",
  "--ui-input": "--fg-dim",
  "--ui-ring-border": "--ring",
  "--ui-primary": "--primary",
  "--ui-primary-foreground": "--primary-fg",
  "--ui-destructive": "--danger",
  "--bark-accent": "--primary-text",
  "--bark-selected": "--bg-accent",
  ...Object.fromEntries(
    [["success", "ok"], ["warning", "warn"], ["danger", "danger"], ["info", "info"]].flatMap(([tone, role]) => [
      [`--bark-${tone}`, `--${role}`],
      [`--bark-${tone}-foreground`, `--${role}-fg`],
    ]),
  ),
};
// A tone's text starts from Studio's and gives way where a soft fill's hover and
// pressed need it (the states test); the tone text test holds it to its tone.
const TONE_TEXT_SOURCES = { success: "--ok-text", warning: "--warn-text", danger: "--danger-text", info: "--info-text" };

// Names whose light arm is Studio's and whose dark arm is not: in dark, muted
// sits above the page (a fill on a dark ground sits on its lighter side), and
// muted-foreground is walked on it.
const BARKUI_LIGHT_SOURCES = { "--ui-muted": "--muted-surface", "--ui-muted-foreground": "--muted-text" };

// Names whose source is a value the cloud region writes and Studio does not:
// the focus halo is the ring at the soft-tint alpha, `--ring-soft`.
const BARKUI_CLOUD_SOURCES = { "--ui-ring": "--ring-soft" };

// The surface and depth axes (the BarkUI base's names). A skin rule declares
// every surface's roles as --bark-<surface>-<role> and its depth grounds as
// --bark-<surface>-depth-<k>; the axis rules point the names parts read
// (--ui-<role>, --bark-accent, --bark-selected, --bark-depth-<k>) at one surface.
const SURFACES = ["base", "raised", "sunken", "primary", "inverse"];
const TONES = ["success", "warning", "danger", "info"];
const ROLES = ["background", "foreground", "muted", "muted-foreground", "border", "input",
  "primary", "primary-foreground", "ring", "ring-border", "accent", "selected",
  ...TONES.flatMap((t) => [t, `${t}-foreground`, `${t}-text`, `${t}-soft`]), "destructive",
  ...["primary", "muted", ...TONES.map((t) => `${t}-soft`)].flatMap((f) => [`${f}-hover`, `${f}-pressed`])];
const DEPTHS = [["-2", "m2"], ["-1", "m1"], ["1", "1"], ["2", "2"], ["3", "3"]];
const BARK_ROLES = new Set(["accent", "selected", ...TONES.flatMap((t) => [t, `${t}-foreground`, `${t}-text`, `${t}-soft`, `${t}-soft-hover`, `${t}-soft-pressed`])]);
const pointed = (role) => (BARK_ROLES.has(role) ? `--bark-${role}` : `--ui-${role}`);
// Where a table name lives in the skin rule: a pointed name as --bark-base-<role>.
const skinVar = (name) => { const r = ROLES.find((x) => pointed(x) === name); return r ? `--bark-base-${r}` : name; };
const SKIN_NAMES = [
  ...SURFACES.flatMap((s) => [...ROLES.map((r) => `--bark-${s}-${r}`), ...DEPTHS.map(([, k]) => `--bark-${s}-depth-${k}`)]),
  ...Object.keys({ ...BARKUI_SOURCES, ...BARKUI_LIGHT_SOURCES, ...BARKUI_CLOUD_SOURCES }).filter((n) => skinVar(n) === n),
  "--bark-sunken-rim",
];

// Every `selectors { body }` rule in a stylesheet, comments stripped, as
// { selectors: [...], vars: { property: value } }. Custom properties and
// `color-scheme` both land in `vars`.
function cssRules(text) {
  const bare = text.replace(/\/\*[\s\S]*?\*\//g, "");
  return [...bare.matchAll(/([^{}]+)\{([^}]*)\}/g)].map(([, sel, body]) => ({
    selectors: sel.split(",").map((s) => s.trim()).filter(Boolean),
    vars: Object.fromEntries([...body.matchAll(/(--[\w-]+|color-scheme):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()])),
  }));
}
const ruleFor = (rules, selector) => rules.find((r) => r.selectors.includes(selector));
const rulesFor = (rules, selector) => rules.filter((r) => r.selectors.includes(selector));

// Studio writes some roles as var() of another var in the same block
// (`--ok: hsl(var(--ok-hsl))`); resolve those to the plain string they stand for.
function resolveStudio(vars, name) {
  const v = vars[name];
  assert.ok(v !== undefined, `Studio block has no ${name}`);
  return v.replace(/var\((--[\w-]+)\)/g, (_, inner) => resolveStudio(vars, inner));
}

// One sheet value is `light-dark(<light>, <dark>)`. The arms are hsl() strings,
// which carry no comma, so the split is exact.
function arms(value) {
  const m = /^light-dark\(([^,]+), ([^,]+)\)$/.exec(value);
  assert.ok(m, `not a light-dark() pair: ${value}`);
  return { light: m[1], dark: m[2] };
}

test("BarkUI sheet: every skin carries exactly the table's names, each a light-dark() of Studio's light and dark strings", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  assert.ok(themes.length > 1, "loadThemes() returned too few skins for this check to mean anything");

  const rules = cssRules(sheet.build(themes));
  const studio = cssRules(build("layouts/root.html.heex", themes));
  const cloud = cssRules(build("static/app.css", themes));
  let compared = 0;
  for (const { name } of themes) {
    const found = rulesFor(rules, `[data-skin="${name}"]`);
    assert.equal(found.length, 1, `${name}: expected one skin rule, found ${found.length}`);
    const [rule] = found;
    assert.deepEqual(Object.keys(rule.vars).sort(), [...SKIN_NAMES].sort(),
      `${name}: the rule declares names outside the table and the surface axis, or lacks some`);
    const studioLight = ruleFor(studio, `html[data-bp-theme="${name}"]`);
    const studioDark = ruleFor(studio, `html[data-bp-theme="${name}"][data-theme="dark"]`);
    assert.ok(studioLight && studioDark, `${name}: Studio lacks a light or dark block to compare against`);
    for (const [barkui, source] of Object.entries(BARKUI_SOURCES)) {
      const { light, dark } = arms(rule.vars[skinVar(barkui)]);
      assert.equal(light, resolveStudio(studioLight.vars, source), `${name}/light: ${barkui} differs from Studio's ${source}`);
      assert.equal(dark, resolveStudio(studioDark.vars, source), `${name}/dark: ${barkui} differs from Studio's ${source}`);
      compared += 2;
    }
    for (const [barkui, source] of Object.entries(BARKUI_LIGHT_SOURCES)) {
      assert.equal(arms(rule.vars[skinVar(barkui)]).light, resolveStudio(studioLight.vars, source), `${name}/light: ${barkui} differs from Studio's ${source}`);
      compared += 1;
    }
    const cloudLight = ruleFor(cloud, `html[data-bp-theme="${name}"]`);
    const cloudDark = ruleFor(cloud, `html[data-bp-theme="${name}"][data-theme="dark"]`);
    assert.ok(cloudLight && cloudDark, `${name}: the cloud region lacks a light or dark block to compare against`);
    for (const [barkui, source] of Object.entries(BARKUI_CLOUD_SOURCES)) {
      const { light, dark } = arms(rule.vars[skinVar(barkui)]);
      assert.equal(light, resolveStudio(cloudLight.vars, source), `${name}/light: ${barkui} differs from the cloud's ${source}`);
      assert.equal(dark, resolveStudio(cloudDark.vars, source), `${name}/dark: ${barkui} differs from the cloud's ${source}`);
      compared += 2;
    }
  }
  assert.equal(compared, themes.length * (2 * Object.keys({ ...BARKUI_SOURCES, ...BARKUI_CLOUD_SOURCES }).length + Object.keys(BARKUI_LIGHT_SOURCES).length));
});

// `hsl(H S% L%)` or `hsl(H S% L% / a)` -> sRGB 0..255 and alpha.
function hslRgba(value) {
  const m = /^hsl\(([\d.]+ [\d.]+% [\d.]+%)(?: \/ ([\d.]+))?\)$/.exec(value);
  assert.ok(m, `not an hsl() value: ${value}`);
  return { rgb: hexToRgb(hslToHex(m[1])), a: m[2] === undefined ? 1 : Number(m[2]) };
}
// WCAG contrast of `fg` drawn over `ground` (an opaque colour), alpha composited.
function contrastOver(fg, ground) {
  const f = hslRgba(fg), g = hslRgba(ground);
  const mixed = f.rgb.map((c, i) => Math.round(c * f.a + g.rgb[i] * (1 - f.a)));
  return contrast(rgbToHex(mixed), rgbToHex(g.rgb));
}

// UI SDK draws --ui-ring as a 4px solid halo around a focused control and
// --ui-ring-border as the control's edge. Its own defaults give the halo 1.30:1
// (light) and 1.64:1 (dark) against --ui-background, the edge 2.68:1 and 3.88:1.
// The halo bounds keep it visible (> 1.1) and pale (< 1.7, which admits UI SDK's
// own dark halo). The edge must reach 3:1, the WCAG floor for a control's
// boundary; Barkpark's ring clears it in every skin.
test("BarkUI sheet: --ui-ring is a pale halo and --ui-ring-border the strong edge, in every skin and mode", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  const rules = cssRules(sheet.build(themes));
  for (const { name } of themes) {
    const v = ruleFor(rules, `[data-skin="${name}"]`).vars;
    for (const mode of ["light", "dark"]) {
      const bg = arms(v[skinVar("--ui-background")])[mode];
      const halo = contrastOver(arms(v[skinVar("--ui-ring")])[mode], bg);
      const edge = contrastOver(arms(v[skinVar("--ui-ring-border")])[mode], bg);
      assert.ok(halo > 1.1 && halo < 1.7, `${name}/${mode}: halo contrast ${halo.toFixed(2)} is outside 1.1..1.7`);
      assert.ok(edge >= 3, `${name}/${mode}: edge contrast ${edge.toFixed(2)} is under 3`);
      assert.ok(halo < edge, `${name}/${mode}: the halo is not paler than the edge`);
    }
  }
});

test("BarkUI sheet: the surface and depth rules point the names parts read at one surface", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const rules = cssRules(sheet.build(loadThemes()));
  const index = (selector) => rules.findIndex((r) => r.selectors.includes(selector));
  // Base is the default, and a skin element starts its subtree on base, as in the BarkUI base.
  const base = rules[index('[data-surface="base"]')];
  assert.ok(base, 'no [data-surface="base"] rule');
  for (const s of [":root", "[data-skin]", "[data-bp-theme]"]) assert.ok(base.selectors.includes(s), `the base rule lacks ${s}`);
  let last = -1;
  for (const surface of SURFACES) {
    const at = index(`[data-surface="${surface}"]`);
    assert.ok(at > last, `[data-surface="${surface}"] is missing or out of order`);
    last = at;
    const want = Object.fromEntries([
      ...ROLES.map((r) => [pointed(r), `var(--bark-${surface}-${r})`]),
      ...DEPTHS.map(([, k]) => [`--bark-depth-${k}`, `var(--bark-${surface}-depth-${k})`]),
    ]);
    assert.deepEqual(rules[at].vars, want, `[data-surface="${surface}"] does not point every name at ${surface}`);
  }
  for (const [n, k] of DEPTHS) {
    const at = index(`[data-depth="${n}"]`);
    assert.ok(at > last, `[data-depth="${n}"] is missing or comes before a surface rule`);
    assert.deepEqual(rules[at].vars, { "--ui-background": `var(--bark-depth-${k})` });
  }
});

test("BarkUI sheet: every surface reads in every skin and mode, raised and sunken differ from base, depth steps are ordered", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  const rules = cssRules(sheet.build(themes));
  const L = (v) => srgbToOklch(v).L;
  for (const { name } of themes) {
    const v = ruleFor(rules, `[data-skin="${name}"]`).vars;
    for (const mode of ["light", "dark"]) {
      const get = (n) => arms(v[n])[mode];
      for (const s of SURFACES) {
        const bg = get(`--bark-${s}-background`);
        const fg = contrast(get(`--bark-${s}-foreground`), bg);
        const quiet = contrast(get(`--bark-${s}-muted-foreground`), bg);
        assert.ok(fg >= 4.5, `${name}/${mode}/${s}: foreground ${fg.toFixed(2)} under 4.5`);
        assert.ok(quiet >= 3, `${name}/${mode}/${s}: muted foreground ${quiet.toFixed(2)} under 3`);
        const d = Object.fromEntries(DEPTHS.map(([, k]) => [k, L(get(`--bark-${s}-depth-${k}`))]));
        const g = L(bg), e = 1e-6;
        assert.ok(d.m2 < d.m1 && d.m1 < g, `${name}/${mode}/${s}: negative depths not below the ground in order`);
        assert.ok(g <= d["1"] + e && d["1"] <= d["2"] + e && d["2"] <= d["3"] + e, `${name}/${mode}/${s}: positive depths out of order`);
      }
      const base = get("--bark-base-background");
      assert.notEqual(get("--bark-raised-background"), base, `${name}/${mode}: raised equals base`);
      assert.notEqual(get("--bark-sunken-background"), base, `${name}/${mode}: sunken equals base`);
      assert.ok(L(get("--bark-sunken-background")) < L(base), `${name}/${mode}: sunken is not below base`);
      // Inverse is the other mode's base: a dark band on a light page and the reverse.
      const other = mode === "light" ? "dark" : "light";
      assert.equal(get("--bark-inverse-background"), arms(v["--bark-base-background"])[other], `${name}/${mode}: inverse is not the other mode's ground`);
    }
  }
});

// The one colour form the sheet writes: hsl(H S% L%), optionally with an alpha.
const COLOUR = String.raw`hsl\([\d.]+ [\d.]+% [\d.]+%(?: / [\d.]+)?\)`;
const VALUE = new RegExp(`^(?:light-dark\\(${COLOUR}, ${COLOUR}\\)|${COLOUR}|var\\(--[\\w-]+\\))$`);

test("BarkUI sheet: every declared value is a colour pair, a colour or a pointer, and every surface has every role", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  const rules = cssRules(sheet.build(themes));
  let seen = 0;
  for (const r of rules)
    for (const [prop, value] of Object.entries(r.vars)) {
      if (prop === "color-scheme") continue;
      assert.match(value, VALUE, `${r.selectors.join(", ")}: ${prop} is not a colour the sheet writes`);
      seen++;
    }
  assert.ok(seen > 0, "no declarations read; the check above would be vacuous");
  for (const { name } of themes) {
    const v = ruleFor(rules, `[data-skin="${name}"]`).vars;
    for (const s of SURFACES) for (const r of ROLES) assert.ok(`--bark-${s}-${r}` in v, `${name}: ${s} has no ${r}`);
  }
});

// Pairs whose two colours both come unchanged from the colour source: the
// status fill and its onStatus foreground. onStatus is warm white for every
// tone, so on light fills (warning, info in light) and every dark-mode fill it
// is under 4.5:1. That is the colour source's to fix; until then each pair is
// held at its own measured value (rounded down), so no single pair can fall
// unseen. Generated once from the colour source; task-3daddf3c246e3d19 will
// replace this table with 4.5.
const SOURCE_TONE_FLOORS = {
  "evergreen/light": { success: 4.5, warning: 3.88, danger: 4.5, info: 3.67 },
  "evergreen/dark": { success: 2.22, warning: 1.93, danger: 3.19, info: 3.67 },
  "charple/light": { success: 4.5, warning: 4.5, danger: 4.5, info: 4.5 },
  "charple/dark": { success: 2.37, warning: 2.52, danger: 2.62, info: 2.5 },
  "ember/light": { success: 4.5, warning: 4.5, danger: 4.5, info: 4.5 },
  "ember/dark": { success: 2.37, warning: 2.52, danger: 2.62, info: 2.5 },
  "fjord/light": { success: 4.5, warning: 4.5, danger: 4.5, info: 4.5 },
  "fjord/dark": { success: 2.39, warning: 2.51, danger: 2.58, info: 2.49 },
  "iris/light": { success: 4.5, warning: 4.5, danger: 4.5, info: 4.5 },
  "iris/dark": { success: 2.35, warning: 2.53, danger: 2.64, info: 2.5 },
};

test("BarkUI sheet: tones and fills read on every surface, in every skin and mode", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  const rules = cssRules(sheet.build(themes));
  const studio = cssRules(build("layouts/root.html.heex", themes));
  // Every (status fill, onStatus foreground) pair the colour source writes, as
  // Studio writes them, with that pair's own floor from the table above.
  const sourcePairs = new Map();
  for (const { name } of themes)
    for (const [mode, sel] of [["light", `html[data-bp-theme="${name}"]`], ["dark", `html[data-bp-theme="${name}"][data-theme="dark"]`]]) {
      const sv = ruleFor(studio, sel).vars;
      const floors = SOURCE_TONE_FLOORS[`${name}/${mode}`];
      assert.ok(floors, `${name}/${mode} has no row in SOURCE_TONE_FLOORS`);
      for (const [role, tone] of [["ok", "success"], ["warn", "warning"], ["danger", "danger"], ["info", "info"]])
        sourcePairs.set(`${resolveStudio(sv, `--${role}`)}|${resolveStudio(sv, `--${role}-fg`)}`, floors[tone]);
    }
  for (const { name } of themes) {
    const v = ruleFor(rules, `[data-skin="${name}"]`).vars;
    for (const mode of ["light", "dark"]) {
      const get = (s, r) => arms(v[`--bark-${s}-${r}`])[mode];
      for (const s of SURFACES) {
        const at = `${name}/${mode}/${s}`;
        const bg = get(s, "background");
        const pairs = [
          [get(s, "foreground"), get(s, "selected"), 4.5, "foreground on selected"],
          [get(s, "muted-foreground"), get(s, "muted"), 4.5, "muted foreground on muted"],
          [get(s, "destructive"), bg, 4.5, "destructive"],
          ...TONES.flatMap((t) => [
            [get(s, `${t}-text`), bg, 4.5, `${t}-text`],
            [get(s, t), bg, 3, `${t} fill`],
            [get(s, `${t}-foreground`), get(s, t), sourcePairs.get(`${get(s, t)}|${get(s, `${t}-foreground`)}`) ?? 4.5, `${t}-foreground on its fill`],
          ]),
        ];
        for (const [fg, ground, floor, what] of pairs) {
          const c = contrast(fg, ground);
          assert.ok(c >= floor, `${at}: ${what} is ${c.toFixed(2)}, under ${floor}`);
        }
      }
    }
  }
});

// Every skin, mode and surface of the built sheet: calls f(at, mode, surface, get).
function eachSurface(f) {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  const rules = cssRules(sheet.build(themes));
  let n = 0;
  for (const { name } of themes) {
    const v = ruleFor(rules, `[data-skin="${name}"]`).vars;
    for (const mode of ["light", "dark"])
      for (const s of SURFACES) {
        f(`${name}/${mode}/${s}`, mode, s, (r, surface = s) => arms(v[`--bark-${surface}-${r}`])[mode]);
        n++;
      }
  }
  assert.equal(n, themes.length * 2 * SURFACES.length);
}

// A soft tone control (a destructive button, a soft badge) draws its tone's
// -soft as its fill and the tone's -text as its label. The sheet writes -soft
// per surface and tone. It must still be its tone: within SOFT_HUE degrees of
// the tone fill's OKLCH hue on that surface, at OKLCH chroma SOFT_CHROMA or
// more; it stands SOFT_STEP off the ground so the control is visibly tinted;
// and the label reads on it at 4.5:1. SOFT_CHROMA is the most every case can
// hold: a red tint 1.1:1 below a white ground ends at the sRGB gamut, 0.0167.
// Chroma near black cannot be seen, so every soft fill also keeps OKLCH
// lightness SOFT_LIGHTNESS or more.
const SOFT_STEP = 1.1, SOFT_HUE = 1, SOFT_CHROMA = 0.016, SOFT_LIGHTNESS = 0.15;
test("BarkUI sheet: every tone's soft fill keeps its tone, is visibly tinted, and its text reads on it", () => {
  // Every miss is listed, so one failure names every skin, mode and surface it hits.
  const misses = [];
  eachSurface((at, mode, s, get) => {
    const bg = get("background");
    for (const t of TONES) {
      const soft = get(`${t}-soft`), o = srgbToOklch(soft), tone = srgbToOklch(get(t));
      const dh = Math.min(Math.abs(o.h - tone.h), 360 - Math.abs(o.h - tone.h));
      const label = contrast(get(`${t}-text`), soft), step = contrast(soft, bg);
      if (o.C < SOFT_CHROMA) misses.push(`${at}: ${t}-soft has chroma ${o.C.toFixed(3)}, under ${SOFT_CHROMA}`);
      if (o.L < SOFT_LIGHTNESS) misses.push(`${at}: ${t}-soft has lightness ${o.L.toFixed(3)}, under ${SOFT_LIGHTNESS}`);
      if (dh > SOFT_HUE) misses.push(`${at}: ${t}-soft is ${dh.toFixed(1)} degrees off the ${t} hue, over ${SOFT_HUE}`);
      if (label < 4.5) misses.push(`${at}: ${t}-text on ${t}-soft is ${label.toFixed(2)}, under 4.5`);
      if (step < SOFT_STEP) misses.push(`${at}: ${t}-soft is ${step.toFixed(3)}:1 off the ground, under ${SOFT_STEP}`);
    }
  });
  assert.deepEqual(misses, []);
});

// Disabled controls draw on the muted fill with muted-foreground. They read as
// inactive when that fill sits close to the ground, its text is readable but
// clearly weaker than the foreground, and the fill can never be taken for the
// primary fill. On the primary surface the muted fill is computed, so it is
// held between 1.1 and 1.6:1 from the ground; the base muted fill is the colour
// source's own and is not held to that band.
test("BarkUI sheet: the muted fill reads as inactive on every surface", () => {
  eachSurface((at, mode, s, get) => {
    const bg = get("background"), muted = get("muted");
    if (s === "primary") {
      const step = contrast(muted, bg);
      assert.ok(step >= 1.1 && step <= 1.6, `${at}: muted fill is ${step.toFixed(2)}:1 from the ground, outside 1.1 to 1.6`);
    }
    const quiet = contrast(get("muted-foreground"), muted), loud = contrast(get("foreground"), muted);
    assert.ok(loud >= 1.2 * quiet, `${at}: muted-foreground ${quiet.toFixed(2)}:1 is not clearly weaker than the foreground ${loud.toFixed(2)}:1 on the muted fill`);
    const vsPrimary = contrast(get("primary"), muted);
    assert.ok(vsPrimary >= 3, `${at}: the muted fill is ${vsPrimary.toFixed(2)}:1 from --ui-primary, under 3`);
  });
});

// A sunken well stands SUNKEN_STEP off base in both modes and is marked by an
// inset 1px rim on every skin, the mirror of raised's shadow; the rim stands
// RIM_STEP off the base ground it is cut into. Raised stands DARK_RAISED_STEP
// off base in dark, where no shadow shows.
// Raised in light is left out: its shadow marks it (the light raised panel is its own task).
const DARK_RAISED_STEP = 1.1, SUNKEN_STEP = 1.05, RIM_STEP = 1.25;
test("BarkUI sheet: raised and sunken stand off base; a sunken well has a rim, with or without a depth", () => {
  const css = ARTIFACTS.find((a) => a.path === BARKUI_PATH).build(loadThemes());
  const rim = ':where([data-surface="sunken"]) {\n  box-shadow: inset 0 0 0 1px var(--bark-sunken-rim);\n}';
  const both = ':where([data-surface="sunken"][data-depth="1"], [data-surface="sunken"][data-depth="2"], [data-surface="sunken"][data-depth="3"]) {\n  box-shadow: inset 0 0 0 1px var(--bark-sunken-rim), var(--ui-shadow, 0 0 #0000);\n}';
  const shadow = css.indexOf(':where([data-depth="1"], [data-depth="2"], [data-depth="3"]) {');
  assert.ok(css.includes(rim), "no inset rim paint rule for the sunken surface");
  assert.ok(css.includes(both), "no rule giving a sunken surface with depth 1 to 3 both its rim and the depth shadow");
  assert.ok(shadow >= 0 && css.indexOf(rim) < shadow && shadow < css.indexOf(both),
    "the paint rules are out of order: rim, then depth shadow, then the combined rule");
  eachSurface((at, mode, s, get) => {
    const base = get("background", "base");
    if (s === "sunken") {
      const r = contrast(get("rim"), base);
      assert.ok(r >= RIM_STEP, `${at}: rim is ${r.toFixed(3)}:1 off the base ground, under ${RIM_STEP}`);
    }
    const floor = s === "sunken" ? SUNKEN_STEP : s === "raised" && mode === "dark" ? DARK_RAISED_STEP : 0;
    if (!floor) return;
    const step = contrast(get("background"), base);
    assert.ok(step >= floor, `${at}: ground is ${step.toFixed(3)}:1 from base, under ${floor}`);
  });
});

// Hover and pressed come from the sheet: every fill a control can have (the
// primary fill, the muted fill a secondary control takes, each tone's soft fill;
// a destructive control is the danger tone's soft fill) has -hover and -pressed
// on every surface. Every reading is taken on the 8-bit colour a screen paints.
//   - Hover and pressed move the fill away from its ground, by contrast, pressed
//     furthest. Only a fill at the end of the lightness range (no room for two
//     steps away from its ground) moves toward its ground, and then it still
//     stands 3:1 off the ground when pressed. No state is closer to its ground
//     than 1.1:1.
//   - Each step (rest to hover, hover to pressed) is at least 1.12:1 and at
//     least 0.03 in OKLCH lightness.
//   - One label for all three states, reading 4.5:1 on each.
//   - Soft states keep the soft fill's hue within 1 degree and at least 0.016
//     chroma; primary states keep its hue within 1 degree; muted states gain at
//     most 0.002 chroma.
//   - A fill that stands 3:1 off its ground at rest still does in both states.
const STATE = { step: 1.12, stepL: 0.03, ground: 1.1, hue: 1, softC: 0.016, greyGain: 0.002 };
const STATE_FILLS = [["primary", "primary-foreground", "primary"], ["muted", "foreground", "muted"], ...TONES.map((t) => [`${t}-soft`, `${t}-text`, "soft"])];
const paint = (c) => parseColor(c).map((v) => Math.round(Math.min(1, Math.max(0, v)) * 255) / 255);
const hueOff = (a, b) => { const d = Math.abs(a - b) % 360; return Math.min(d, 360 - d); };
test("BarkUI sheet: every control fill has a visible hover and pressed state that keeps its label, colour and ground", () => {
  const misses = [];
  eachSurface((at, mode, s, get) => {
    const bg = paint(get("background"));
    for (const [f, lab, kind] of STATE_FILLS) {
      const fills = ["", "-hover", "-pressed"].map((x) => paint(get(`${f}${x}`)));
      const [rest] = fills, label = paint(get(lab));
      const o = fills.map((c) => srgbToOklch(c)), g = fills.map((c) => contrast(c, bg));
      const miss = (m) => misses.push(`${at}: ${f} ${m}`);
      for (const k of [1, 2]) {
        const n = k === 1 ? "hover" : "pressed";
        if (contrast(fills[k], fills[k - 1]) < STATE.step) miss(`${n} is ${contrast(fills[k], fills[k - 1]).toFixed(3)}:1 off the state before, under ${STATE.step}`);
        if (Math.abs(o[k].L - o[k - 1].L) < STATE.stepL) miss(`${n} is ${Math.abs(o[k].L - o[k - 1].L).toFixed(3)} lightness off the state before, under ${STATE.stepL}`);
        if (g[k] < STATE.ground) miss(`${n} is ${g[k].toFixed(3)}:1 off the ground, under ${STATE.ground}`);
        if (g[0] >= 3 && g[k] < 3) miss(`${n} is ${g[k].toFixed(2)}:1 off the ground, under 3`);
        if (contrast(label, fills[k]) < 4.5) miss(`${lab} on ${n} is ${contrast(label, fills[k]).toFixed(2)}, under 4.5`);
        if (kind !== "muted" && hueOff(o[k].h, o[0].h) > STATE.hue) miss(`${n} is ${hueOff(o[k].h, o[0].h).toFixed(1)} degrees off the fill's hue`);
        if (kind === "soft" && o[k].C < STATE.softC) miss(`${n} has chroma ${o[k].C.toFixed(4)}, under ${STATE.softC}`);
        if (kind === "muted" && o[k].C > o[0].C + STATE.greyGain) miss(`${n} gains chroma ${(o[k].C - o[0].C).toFixed(4)}`);
      }
      if (contrast(label, rest) < 4.5) miss(`${lab} on rest is ${contrast(label, rest).toFixed(2)}, under 4.5`);
      if (Math.sign(o[1].L - o[0].L) !== Math.sign(o[2].L - o[1].L)) miss("hover and pressed move in different directions");
      if (g[1] < g[0]) {
        const end = contrast(rest, contrast(rest, [0, 0, 0]) >= contrast(bg, [0, 0, 0]) ? [1, 1, 1] : [0, 0, 0]);
        if (end >= STATE.step ** 2) miss(`moves toward its ground with ${end.toFixed(3)}:1 of room away from it`);
        if (g[2] < 3) miss(`moves toward its ground and ends ${g[2].toFixed(2)}:1 off it, under 3`);
      }
    }
  });
  assert.deepEqual(misses, []);
});

// A soft fill's hover and pressed are steps toward the tone itself, judged by
// where the tone's solid fill (--bark-<tone> on that surface) sits:
//   - a state moving toward the solid's lightness takes the rest chroma moved
//     the same fraction of the way toward the solid's chroma (less only where
//     sRGB ends at that hue), so it is stronger than the state before;
//   - a state moving away from it keeps its hue within 1 degree and the rest
//     chroma.
// Chroma is read on the 8-bit colour; one 8-bit rounding moves it by at most
// SOFT_ROUND. A single reading against the rule's value may be off by that
// much (SOFT_TARGET_TOL adds a little); comparing two states reads two rounded
// colours, so "stronger than the state before" allows two roundings.
const SOFT_ROUND = 0.0021, SOFT_TARGET_TOL = 0.0025, SOFT_BEFORE_TOL = 0.004;
test("BarkUI sheet: a soft state moving away from its solid keeps its hue within 1 degree and the rest chroma; one moving toward it follows the fraction rule", () => {
  const misses = [];
  eachSurface((at, mode, s, get) => {
    for (const t of TONES) {
      const o = ["", "-hover", "-pressed"].map((x) => srgbToOklch(paint(get(`${t}-soft${x}`))));
      const solid = srgbToOklch(paint(get(t)));
      const miss = (m) => misses.push(`${at}: ${t}-soft ${m}`);
      const ruled = (l) => {
        const frac = Math.min(1, (l - o[0].L) / (solid.L - o[0].L));
        return [frac, Math.min(Math.max(o[0].C, o[0].C + frac * (solid.C - o[0].C)), maxChroma(l, o[0].h))];
      };
      for (const k of [1, 2]) {
        const n = k === 1 ? "hover" : "pressed";
        if (Math.sign(o[k].L - o[0].L) !== Math.sign(solid.L - o[0].L)) {
          if (hueOff(o[k].h, o[0].h) > STATE.hue) miss(`${n} moves away from the solid and is ${hueOff(o[k].h, o[0].h).toFixed(2)} degrees off the rest hue`);
          if (Math.abs(o[k].C - o[0].C) > SOFT_ROUND) miss(`${n} moves away from the solid with chroma ${o[k].C.toFixed(4)}, not the rest fill's ${o[0].C.toFixed(4)}`);
          continue;
        }
        const [frac, target] = ruled(o[k].L);
        if (Math.abs(o[k].C - target) > SOFT_TARGET_TOL) miss(`${n} has chroma ${o[k].C.toFixed(4)}, not ${target.toFixed(4)} (${frac.toFixed(2)} of the way to the solid's ${solid.C.toFixed(3)})`);
        const before = k === 1 ? o[0].C : ruled(o[1].L)[1];
        if (target - before > SOFT_BEFORE_TOL && o[k].C <= o[k - 1].C) miss(`${n} is no stronger than the state before (chroma ${o[k].C.toFixed(4)} after ${o[k - 1].C.toFixed(4)})`);
      }
    }
  });
  assert.deepEqual(misses, []);
});

// On one ground the muted fill and every soft fill sit on one side, so every
// such button there presses the same way: the side away from the label (the
// foreground) if every one of them fits there with both its steps, else the
// label's side. Sides are by the painted luminance; a colour that paints the
// same as the ground is on neither side. The muted fill's candidate on the
// other side is itself mirrored across the ground in OKLCH lightness; a soft
// fill's is the generator's soft fill on that side (softSides); "fits" is the
// step rule (stepsFor), which the states test holds.
test("BarkUI sheet: on each ground the muted and soft fills sit on one side, away from the label only where all of them fit", () => {
  const misses = [];
  const side = (c, g) => Math.sign(contrast(paint(c), [0, 0, 0]) - contrast(paint(g), [0, 0, 0]));
  eachSurface((at, mode, s, get) => {
    const ground = get("background"), labelSide = side(get("foreground"), ground);
    const mirror = (c) => { const o = srgbToOklch(c); return `hsl(${toHslTriplet(oklchToSrgb(2 * srgbToOklch(ground).L - o.L, o.C, o.h))})`; };
    const fills = [["muted", "muted", get("muted"), (c) => mirror(c)], ...TONES.map((t) => [`${t}-soft`, "soft", get(`${t}-soft`), (c) => softSides(get(t), ground).find((x) => x && side(x, ground) === -side(c, ground)), get(t)])];
    const sides = fills.map(([, , c]) => side(c, ground));
    if (new Set(sides).size !== 1 || sides[0] === 0) { misses.push(`${at}: the fills sit on sides ${sides.join(" ")}`); return; }
    if (sides[0] === labelSide) {
      const far = fills.map(([, kind, c, other, solid]) => [kind, other(c), solid]);
      if (far.every(([kind, c, solid]) => c && side(c, ground) === -labelSide && stepsFor(kind, c, ground, solid))) misses.push(`${at}: every fill fits away from the label, but they sit on its side`);
    } else for (const [role, kind, c, , solid] of fills) if (!stepsFor(kind, c, ground, solid)) misses.push(`${at}: ${role} sits away from the label without room for its steps`);
  });
  assert.deepEqual(misses, []);
});

// A tone's text walks only to read on its soft fill's states (and, on a brand
// ground, on the ground). On a neutral ground it keeps its tone: OKLCH hue
// within 1 degree of Studio's tone text, at least TONE_TEXT_CHROMA of its
// chroma (the least any walk keeps is charple's light sunken warning text,
// 0.91), and at least Studio's contrast on the ground. On a brand ground
// (BRAND_SURFACES, from the generator) status is carried by the fill: every
// tone's soft fill keeps its tone (hue within 1 degree, chroma at least 0.016)
// and the text reads 4.5:1 on it and on the ground; its own chroma is not held.
const TONE_TEXT_CHROMA = 0.9;
test("BarkUI sheet: a tone's text keeps its tone on a neutral ground; on a brand ground the soft fill carries it", () => {
  const themes = loadThemes();
  const studio = cssRules(build("layouts/root.html.heex", themes));
  const misses = [];
  eachSurface((at, mode, s, get) => {
    const [name] = at.split("/");
    const from = s === "inverse" ? (mode === "light" ? "dark" : "light") : mode;
    const block = ruleFor(studio, from === "light" ? `html[data-bp-theme="${name}"]` : `html[data-bp-theme="${name}"][data-theme="dark"]`);
    const bg = paint(get("background"));
    for (const t of TONES) {
      const text = paint(get(`${t}-text`));
      if (BRAND_SURFACES.includes(s)) {
        // the soft fill's tone is read as the soft fill test reads it, on the written value
        const soft = paint(get(`${t}-soft`)), tone = srgbToOklch(get(t)), o = srgbToOklch(get(`${t}-soft`));
        if (hueOff(o.h, tone.h) > 1) misses.push(`${at}: ${t}-soft is ${hueOff(o.h, tone.h).toFixed(2)} degrees off its tone`);
        if (o.C < STATE.softC) misses.push(`${at}: ${t}-soft has chroma ${o.C.toFixed(4)}`);
        for (const [n, c] of [["soft fill", soft], ["ground", bg]])
          if (contrast(text, c) < 4.5) misses.push(`${at}: ${t}-text reads ${contrast(text, c).toFixed(2)} on the ${n}`);
        continue;
      }
      const src = paint(resolveStudio(block.vars, TONE_TEXT_SOURCES[t]));
      const a = srgbToOklch(src), b = srgbToOklch(text);
      if (hueOff(a.h, b.h) > 1) misses.push(`${at}: ${t}-text is ${hueOff(a.h, b.h).toFixed(2)} degrees off Studio's`);
      if (b.C < a.C * TONE_TEXT_CHROMA) misses.push(`${at}: ${t}-text keeps ${(b.C / a.C).toFixed(2)} of Studio's chroma`);
      if (contrast(text, bg) < contrast(src, bg) - 0.005) misses.push(`${at}: ${t}-text reads ${contrast(text, bg).toFixed(2)} on the ground, under Studio's ${contrast(src, bg).toFixed(2)}`);
    }
  });
  assert.deepEqual(misses, []);
});

// The control edge (--ui-input): the edge of anything a person operates, an
// outlined button, a text field, a select, a checkbox. It must stand at 3:1
// against the ground it sits on (WCAG 1.4.11), on every surface, and stay
// clearly quieter than text: the foreground's contrast is at least 1.5 times
// the edge's, so a field is not drawn in ink. --ui-border stays the hairline.
test("BarkUI sheet: the control edge stands at 3:1 on every surface and stays quieter than text", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  const rules = cssRules(sheet.build(themes));
  let checked = 0;
  for (const { name } of themes) {
    const v = ruleFor(rules, `[data-skin="${name}"]`).vars;
    for (const mode of ["light", "dark"])
      for (const s of SURFACES) {
        const get = (r) => arms(v[`--bark-${s}-${r}`])[mode];
        const at = `${name}/${mode}/${s}`;
        const edge = contrast(get("input"), get("background"));
        const text = contrast(get("foreground"), get("background"));
        assert.ok(edge >= 3, `${at}: --ui-input is ${edge.toFixed(2)}:1 on its ground, under 3`);
        assert.ok(text >= 1.5 * edge, `${at}: --ui-input ${edge.toFixed(2)}:1 is too close to the foreground's ${text.toFixed(2)}:1`);
        checked++;
      }
  }
  assert.equal(checked, themes.length * 2 * SURFACES.length);
});

test("BarkUI sheet: one rule per skin under both namings, and the scheme attributes set color-scheme", () => {
  const sheet = ARTIFACTS.find((a) => a.path === BARKUI_PATH);
  assert.ok(sheet, `${BARKUI_PATH} is not a registered design/emit.mjs artifact`);
  const themes = loadThemes();
  const rules = cssRules(sheet.build(themes));
  for (const { name } of themes) {
    const rule = ruleFor(rules, `[data-skin="${name}"]`);
    assert.ok(rule && rule.selectors.includes(`[data-bp-theme="${name}"]`), `${name}: skin rule lacks [data-bp-theme]`);
  }
  // One form: no selector ties a skin to a scheme.
  for (const r of rules)
    for (const s of r.selectors)
      assert.ok(!(/data-(skin|bp-theme)=/.test(s) && /data-(color-scheme|theme)=/.test(s)), `paired skin+scheme selector: ${s}`);
  // No skin attribute: :root carries the default skin.
  const [first] = themes;
  assert.ok(ruleFor(rules, `[data-skin="${first.name}"]`).selectors.includes(":root"), ":root does not carry the default skin");
  // The scheme axis: both namings, plus system and the bare root following the OS.
  const scheme = (selector) => rulesFor(rules, selector).map((r) => r.vars["color-scheme"]).find(Boolean);
  for (const [selector, want] of [
    ['[data-color-scheme="dark"]', "dark"], ['[data-theme="dark"]', "dark"],
    ['[data-color-scheme="light"]', "light"], ['[data-theme="light"]', "light"],
    ['[data-color-scheme="system"]', "light dark"], [":root", "light dark"],
  ]) assert.equal(scheme(selector), want, `${selector} should set color-scheme: ${want}`);
  // An explicit scheme on the root must beat the root's system default: later in the sheet, same weight.
  const at = (selector, prop) => rules.findIndex((r) => r.selectors.includes(selector) && prop in r.vars);
  assert.ok(at('[data-theme="dark"]', "color-scheme") > at(":root", "color-scheme"), "dark scheme rule must follow the :root default");
  assert.ok(at('[data-theme="light"]', "color-scheme") > at(":root", "color-scheme"), "light scheme rule must follow the :root default");
  // A skin design/themes/ does not ship must be absent.
  assert.equal(ruleFor(rules, '[data-skin="__no_such_theme__"]'), undefined);
});

test("templates: the artifact DERIVES its theme blocks — an injected theme appears, unnamed by any literal", () => {
  // The mutation arm. webBlock() is the shared builder, so this proves the
  // template region grows from the THEME LIST rather than from a pasted snapshot:
  // build with N=1 and with N=2 and the fixture block must be the difference.
  const subjects = ARTIFACTS.filter((x) => x.markerBegin === TEMPLATE_TOKENS_MARKER_BEGIN);
  assert.ok(subjects.length > 0, "no template theme-token artifact is registered — the loop below would be vacuous.");
  for (const a of subjects) {
    const one = a.build(EVER);
    const two = a.build(THEMES);
    assert.ok(!one.includes('[data-bp-theme="fixture"]'), `${a.path}: N=1 leaked the fixture theme`);
    assert.ok(two.includes('[data-bp-theme="fixture"] {'), `${a.path}: N=2 did not render the injected theme`);
    assert.ok(two.includes('[data-bp-theme="fixture"][data-theme="dark"] {'),
      `${a.path}: the injected theme got a light block but no dark one — the two axes are orthogonal`);
    assert.ok(two.length > one.length, `${a.path}: adding a theme did not grow the region`);
  }
});
