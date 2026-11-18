// design/barkui-scheme-runtime.test.mjs — the BarkUI sheet's scheme axis, resolved
// by a real browser.
//
// design/theme-emit.test.mjs checks the sheet's TEXT: every skin writes each
// colour as light-dark(<light>, <dark>) and the scheme attributes set
// color-scheme. Text cannot prove the part that matters: that a scheme set on
// any ancestor reaches a skin set below it, that a light island inside a dark
// page draws light, and that a page with no scheme attribute follows the
// system setting. This file loads the committed api/priv/barkui/tokens.css into
// headless Chrome, builds each case in the DOM, and reads the colour a real
// property resolves to (`background-color: var(--ui-background)`), once with the
// system set to light and once set to dark.
//
// Expected values are the Studio region's --bg strings for the skin and mode, so
// this also holds the sheet to the source. Each run first checks that the system
// setting took (matchMedia), so a browser that ignores the flag reds instead of
// passing on the wrong mode.
//
// Chrome: $BARKUI_CHROME, else /usr/bin/google-chrome (GitHub's ubuntu runners
// ship it), else a puppeteer chrome-headless-shell, else the macOS app. With
// none found the test fails under CI and skips locally, saying so.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { ARTIFACTS, loadThemes } from "./emit.mjs";
import { srgbToOklch } from "./derive.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const SHEET = readFileSync(join(REPO, "api/priv/barkui/tokens.css"), "utf8");

function findChrome() {
  const fixed = [process.env.BARKUI_CHROME, "/usr/bin/google-chrome", "/usr/bin/chromium"];
  const shells = join(homedir(), ".cache", "puppeteer", "chrome-headless-shell");
  const cached = existsSync(shells)
    ? readdirSync(shells, { withFileTypes: true }).filter((v) => v.isDirectory()).map((v) => v.name).sort().reverse()
        .flatMap((v) => readdirSync(join(shells, v)).map((d) => join(shells, v, d, "chrome-headless-shell")))
    : [];
  const mac = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"];
  return [...fixed, ...cached, ...mac].find((p) => p && existsSync(p)) ?? null;
}

// The Studio region's --bg for a skin and mode: the string the sheet must resolve to.
function studioBg(themes) {
  const studio = ARTIFACTS.find((a) => a.path.endsWith("layouts/root.html.heex")).build(themes);
  const bg = (selector) => {
    const at = studio.indexOf(`${selector} {`);
    assert.ok(at >= 0, `Studio has no ${selector} block`);
    return /--bg: ([^;]+);/.exec(studio.slice(at))[1];
  };
  return (skin, mode) => bg(mode === "dark" ? `html[data-bp-theme="${skin}"][data-theme="dark"]` : `html[data-bp-theme="${skin}"]`);
}

// [id, attributes on <html>, markup holding the probe, skin, scheme]. scheme
// "system" means the case must follow the system setting of the run.
function cases(def, x) {
  const P = '<i class="probe"></i>';
  return [
    ["skin on a child of a dark root", { "data-color-scheme": "dark" }, `<div data-skin="${x}">${P}</div>`, x, "dark"],
    ["same, old names", { "data-theme": "dark" }, `<div data-bp-theme="${x}">${P}</div>`, x, "dark"],
    ["same, old scheme + new skin", { "data-theme": "dark" }, `<div data-skin="${x}">${P}</div>`, x, "dark"],
    ["same, new scheme + old skin", { "data-color-scheme": "dark" }, `<div data-bp-theme="${x}">${P}</div>`, x, "dark"],
    ["light island in a dark page", { "data-color-scheme": "dark" }, `<section data-color-scheme="light"><div data-skin="${x}">${P}</div></section>`, x, "light"],
    ["light island, old names", { "data-theme": "dark" }, `<section data-theme="light" data-bp-theme="${x}">${P}</section>`, x, "light"],
    ["light island under a skinned dark root", { "data-skin": x, "data-color-scheme": "dark" }, `<section data-color-scheme="light">${P}</section>`, x, "light"],
    ["dark island in a light page", { "data-theme": "light" }, `<section data-theme="dark"><div data-skin="${x}">${P}</div></section>`, x, "dark"],
    ["skin and scheme on the same element", { "data-skin": x, "data-color-scheme": "dark" }, P, x, "dark"],
    ["same element, old names", { "data-bp-theme": x, "data-theme": "dark" }, P, x, "dark"],
    ["no attributes", {}, P, def, "system"],
    ["skin on the root, no scheme", { "data-skin": x }, P, x, "system"],
    ["old skin on the root, no scheme", { "data-bp-theme": x }, P, x, "system"],
    ["system island in a dark page", { "data-color-scheme": "dark" }, `<section data-color-scheme="system" data-skin="${x}">${P}</section>`, x, "system"],
    ["explicit light root", { "data-color-scheme": "light" }, P, def, "light"],
    ["explicit light root, old name", { "data-theme": "light" }, P, def, "light"],
    ["explicit dark root, no skin", { "data-color-scheme": "dark" }, P, def, "dark"],
    ["explicit dark root, no skin, old name", { "data-theme": "dark" }, P, def, "dark"],
    // One element with both scheme attributes that disagree: dark wins.
    ["both scheme attributes disagree on one element", { "data-color-scheme": "light", "data-theme": "dark" }, `<div data-skin="${x}">${P}</div>`, x, "dark"],
  ];
}

// The page: the sheet, one stage, one reference element. For each case it sets
// the <html> attributes, builds the markup, and records the probe's resolved
// background next to the reference's resolution of the expected string.
function page(list) {
  const json = JSON.stringify(list).replace(/</g, "\\u003c");
  return `<!doctype html><html><head><meta charset="utf-8"><style>${SHEET}
.probe { display: block; background-color: var(--ui-background); color: var(--ui-foreground); }</style></head><body>
<div id="stage"></div><b id="ref"></b><pre id="out"></pre>
<script type="application/json" id="cases">${json}</script>
<script>
const root = document.documentElement, stage = document.getElementById("stage"), ref = document.getElementById("ref");
const rows = [];
for (const c of JSON.parse(document.getElementById("cases").textContent)) {
  for (const a of [...root.attributes]) if (a.name.startsWith("data-")) root.removeAttribute(a.name);
  for (const [k, v] of Object.entries(c.root)) root.setAttribute(k, v);
  stage.innerHTML = c.html;
  ref.style.backgroundColor = c.want;
  ref.style.color = c.wantFg || "";
  const probe = getComputedStyle(stage.querySelector(".probe")), r = getComputedStyle(ref);
  const row = { id: c.id, got: probe.backgroundColor, want: r.backgroundColor, ...(c.wantFg ? { gotFg: probe.color, wantFg: r.color } : {}) };
  if (c.wantPaint) {
    // The element's own painted ground: the root, or the stage's first child.
    ref.style.backgroundColor = c.wantPaint;
    const el = c.paintOf === "root" ? root : stage.firstElementChild;
    Object.assign(row, { gotPaint: getComputedStyle(el).backgroundColor, wantPaint: getComputedStyle(ref).backgroundColor });
  }
  if (c.wantRim) {
    // The element's own inset rim, against the reference colour.
    ref.style.color = c.wantRim;
    Object.assign(row, { gotRim: getComputedStyle(stage.firstElementChild).boxShadow, wantRim: getComputedStyle(ref).color + " 0px 0px 0px 1px inset" });
  }
  rows.push(row);
}
document.getElementById("out").textContent = JSON.stringify({ systemDark: matchMedia("(prefers-color-scheme: dark)").matches, rows });
</script></body></html>`;
}

function dumpDom(chrome, file, systemDark) {
  const dir = mkdtempSync(join(tmpdir(), "barkui-scheme-"));
  const args = [
    "--headless=new", "--disable-gpu", "--no-sandbox", "--no-first-run", "--no-default-browser-check",
    `--user-data-dir=${dir}`, `--blink-settings=preferredColorScheme=${systemDark ? 0 : 1}`,
    "--dump-dom", pathToFileURL(file).href,
  ];
  return new Promise((resolve, reject) => {
    const child = spawn(chrome, args, { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    child.stdout.on("data", (d) => { out += d; });
    const timer = setTimeout(() => { child.kill("SIGKILL"); reject(new Error(`Chrome did not finish in 60 s (${chrome})`)); }, 60_000);
    child.on("error", (e) => { clearTimeout(timer); reject(e); });
    child.on("close", () => {
      clearTimeout(timer);
      rmSync(dir, { recursive: true, force: true });
      const m = /<pre id="out">([^<]*)<\/pre>/.exec(out);
      if (!m) return reject(new Error(`no result in Chrome's DOM dump (${out.length} bytes)`));
      resolve(JSON.parse(m[1].replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&")));
    });
  });
}

const chrome = findChrome();
const skip = !chrome && !process.env.CI ? "no Chrome found; set BARKUI_CHROME to run this locally" : false;

test("BarkUI sheet: the scheme reaches skins on any element, under both namings, and the system setting is the default", { skip }, async () => {
  assert.ok(chrome, "no Chrome found under CI: install google-chrome or set BARKUI_CHROME");
  const themes = loadThemes();
  const [def, x] = themes.map((t) => t.name);
  assert.ok(x, "needs a second skin besides the default");
  const want = studioBg(themes);
  // Control: the light and dark grounds must differ, or every case below passes on the wrong mode.
  for (const skin of [def, x]) assert.notEqual(want(skin, "light"), want(skin, "dark"), `${skin}: light and dark --bg are equal`);
  assert.notEqual(want(x, "light"), want(def, "light"), `${x} and ${def} share a light --bg; the skin cases could not tell them apart`);

  const dir = mkdtempSync(join(tmpdir(), "barkui-scheme-page-"));
  try {
    for (const systemDark of [false, true]) {
      const sys = systemDark ? "dark" : "light";
      const list = cases(def, x).map(([id, root, html, skin, scheme]) => {
        const mode = scheme === "system" ? sys : scheme;
        return { id: `${id} [system ${sys}] -> ${skin} ${mode}`, root, html, want: want(skin, mode) };
      });
      const file = join(dir, `page-${sys}.html`);
      writeFileSync(file, page(list));
      const result = await dumpDom(chrome, file, systemDark);
      assert.equal(result.systemDark, systemDark, `the system setting did not take in Chrome (wanted ${sys})`);
      assert.equal(result.rows.length, list.length);
      for (const r of result.rows) assert.equal(r.got, r.want, r.id);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// The sheet's own value for a skin, a name and a mode: one arm of its light-dark().
function sheetValue(skin, name, mode) {
  const at = SHEET.indexOf(`[data-skin="${skin}"]`);
  assert.ok(at >= 0, `the sheet has no [data-skin="${skin}"] rule`);
  const body = SHEET.slice(at, SHEET.indexOf("}", at));
  const m = new RegExp(`${name}: light-dark\\(([^,]+), ([^;]+)\\);`).exec(body);
  assert.ok(m, `[data-skin="${skin}"] has no ${name}`);
  return mode === "light" ? m[1] : m[2];
}

test("BarkUI sheet: surfaces and depth nest inside skin, scheme and each other", { skip }, async () => {
  assert.ok(chrome, "no Chrome found under CI: install google-chrome or set BARKUI_CHROME");
  const def = loadThemes()[0].name, x = "ember";
  assert.ok(loadThemes().some((t) => t.name === x), `${x} is not a shipped skin`);
  const P = '<i class="probe"></i>';
  const bg = (skin, s, mode) => sheetValue(skin, `--bark-${s}-background`, mode);
  const fg = (skin, s, mode) => sheetValue(skin, `--bark-${s}-foreground`, mode);
  // The inverse band on a light page must be a dark ground with light text.
  assert.ok(srgbToOklch(bg(def, "inverse", "light")).L < 0.4 && srgbToOklch(fg(def, "inverse", "light")).L > 0.7,
    "the default skin's inverse band on a light page is not dark with light text");
  const list = [
    ["raised under ember in a dark page", { "data-color-scheme": "dark" },
      `<div data-skin="${x}"><div data-surface="raised">${P}</div></div>`, bg(x, "raised", "dark")],
    ["same, old names", { "data-theme": "dark" },
      `<div data-bp-theme="${x}"><div data-surface="raised">${P}</div></div>`, bg(x, "raised", "dark")],
    ["sunken well inside a raised panel", { "data-color-scheme": "light", "data-skin": x },
      `<div data-surface="raised"><div data-surface="sunken">${P}</div></div>`, bg(x, "sunken", "light")],
    ["inverse band in a light page", { "data-color-scheme": "light" },
      `<section data-surface="inverse">${P}</section>`, bg(def, "inverse", "light"), fg(def, "inverse", "light")],
    ["primary fill in a dark page", { "data-color-scheme": "dark", "data-skin": x },
      `<div data-surface="primary">${P}</div>`, bg(x, "primary", "dark"), fg(x, "primary", "dark")],
    ["a skin inside a surface starts on its own base", { "data-color-scheme": "light" },
      `<div data-surface="raised"><div data-skin="${x}">${P}</div></div>`, bg(x, "base", "light")],
    ["depth on a raised panel", { "data-color-scheme": "dark", "data-skin": x },
      `<div data-surface="raised"><div data-depth="2">${P}</div></div>`, sheetValue(x, "--bark-raised-depth-2", "dark")],
    ["depth and surface on one element", { "data-color-scheme": "dark", "data-skin": x },
      `<div data-surface="sunken" data-depth="-1">${P}</div>`, sheetValue(x, "--bark-sunken-depth-m1", "dark")],
    ["scheme island inside a surface", { "data-color-scheme": "dark", "data-skin": x },
      `<div data-surface="raised"><section data-color-scheme="light">${P}</section></div>`, bg(x, "raised", "light")],
  ].map(([id, root, html, want, wantFg]) => ({ id, root, html, want, ...(wantFg ? { wantFg } : {}) }));
  // data-bp-theme (today's Studio pages) gets the variables but no paint;
  // data-skin gets both. The second pair shows the paint check can see paint.
  list.push(
    { id: "data-bp-theme alone on the root: variables, no paint", root: { "data-bp-theme": x },
      html: P, want: bg(x, "base", "light"), paintOf: "root", wantPaint: "transparent" },
    { id: "data-bp-theme alone on an element: variables, no paint", root: {},
      html: `<div data-bp-theme="${x}">${P}</div>`, want: bg(x, "base", "light"), wantPaint: "transparent" },
    { id: "data-skin on the root is painted", root: { "data-skin": x },
      html: P, want: bg(x, "base", "light"), paintOf: "root", wantPaint: bg(x, "base", "light") },
    // A sunken well carries an inset 1px rim in both modes, also with a depth.
    { id: "sunken well has its rim (dark)", root: { "data-color-scheme": "dark", "data-skin": x },
      html: `<div data-surface="sunken">${P}</div>`, want: bg(x, "sunken", "dark"), wantRim: sheetValue(x, "--bark-sunken-rim", "dark") },
    { id: "sunken well with a depth keeps its rim (light)", root: { "data-color-scheme": "light", "data-skin": x },
      html: `<div data-surface="sunken" data-depth="-1">${P}</div>`, want: sheetValue(x, "--bark-sunken-depth-m1", "light"), wantRim: sheetValue(x, "--bark-sunken-rim", "light") },
  );
  const dir = mkdtempSync(join(tmpdir(), "barkui-surface-page-"));
  try {
    const file = join(dir, "page.html");
    writeFileSync(file, page(list));
    const result = await dumpDom(chrome, file, false);
    assert.equal(result.rows.length, list.length);
    for (const r of result.rows) {
      assert.equal(r.got, r.want, r.id);
      if (r.wantFg) assert.equal(r.gotFg, r.wantFg, `${r.id} (text)`);
      if (r.wantPaint) assert.equal(r.gotPaint, r.wantPaint, `${r.id} (own paint)`);
      if (r.wantRim) assert.equal(r.gotRim, r.wantRim, `${r.id} (rim)`);
    }
    assert.equal(result.rows.filter((r) => r.wantPaint).length, 3, "the paint cases did not run");
    assert.equal(result.rows.filter((r) => r.wantRim).length, 2, "the rim cases did not run");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
