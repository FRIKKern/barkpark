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
  assert.equal(p.color.primary.light, "163 46% 22%");
  assert.equal(p.color.primary.dark, "160 42% 62%");
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

test("mirror: a token scope mixing theme identity across comma-parts is a hard error", () => {
  const surface = [
    'html[data-bp-theme="a"] .bp-paper-surface, html[data-bp-theme="b"] .bp-paper-body {',
    "  --paper-bg: #123456;",
    "}",
  ].join("\n");
  const bundle = "/* BEGIN GENERATED: paper-surface (x) */\nOLD\n/* END GENERATED: paper-surface */\n";
  assert.throws(() => computeMirror(surface, bundle), /mixes theme\/mode/);
});
