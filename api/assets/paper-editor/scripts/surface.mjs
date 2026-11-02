// Writes host-profile/surface.json: what the committed build offers a host and what
// it keeps to itself. "declared" is index.d.ts (which __contract_truth.test.mjs holds
// equal to EMBED-CONTRACT.md's Surface index). "internal" is read off the build a
// host actually loads: the bundle's private members (on the prototype and on a
// mounted element), the classes in the dist stylesheets and in the bundle's class strings, the data-* attributes the
// bundle writes and the events it dispatches, each minus what is declared. A host profile (R2.3) is checked against this file, so a
// host can tell a contract name from an internal one from a name of its own.
//
// Run: node scripts/surface.mjs   (npm run build runs it; src/__surface.test.mjs
// fails when the committed file is stale)
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { declaredInTypes } from "../src/contract-surface.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const assets = path.join(root, "../../priv/static/assets");
export const surfacePath = path.join(root, "host-profile/surface.json");

const sorted = (list) => [...new Set(list)].sort();
const words = (text) => text.split(/\s+/);

const grouped = (keys) => {
  const out = {};
  for (const key of [...keys].sort()) {
    const [kind, element, name] = key.split("|");
    ((out[element] ??= {})[kind] ??= []).push(name);
  }
  return out;
};

const stylesheetClasses = (css) =>
  [...css.matchAll(/([^{}]+)\{/g)].flatMap((m) => [...m[1].matchAll(/\.(-?[_a-zA-Z][\w-]*)/g)].map((c) => c[1]));

const bundleClasses = (js) => [
  ...[...js.matchAll(/classList\.(?:add|remove|toggle|contains|replace)\(([^)]*)\)/g)].flatMap((m) => [...m[1].matchAll(/["'`]([\w\s-]+)["'`]/g)].flatMap((s) => words(s[1]))),
  ...[...js.matchAll(/(?:className\s*=|class\s*:|["']class["']\s*:|setAttribute\(\s*["']class["']\s*,)\s*["'`]([\w\s-]+)["'`]/g)].flatMap((m) => words(m[1])),
  ...[...js.matchAll(/\sclass=\\?["']([\w\s-]+)\\?["']/g)].flatMap((m) => words(m[1])),
  ...[...js.matchAll(/["'`\s.](bp-[a-z0-9][\w-]*__[\w-]*[a-z0-9])/g)].map((m) => m[1]),
];

const bundleAttributes = (js) => [
  ...js.matchAll(/(?:set|toggle)Attribute\(\s*["'`](data-[\w-]+)["'`]/g),
  ...js.matchAll(/["'`](data-[\w-]+)["'`]\s*:/g),
  ...js.matchAll(/(?<![\w-])(data-[\w-]+)=\\?["'`$]/g),
].map((m) => m[1]);

const bundleEvents = (js) => [...js.matchAll(/new\s+CustomEvent\(\s*["'`]([\w-]+)["'`]/g)].map((m) => m[1]);

export async function surface() {
  const declared = declaredInTypes(readFileSync(path.join(root, "index.d.ts"), "utf8"));
  const names = new Set([...declared].map((k) => k.split("|")[2]));
  const undeclared = (list) => sorted(list).filter((n) => !names.has(n));

  const js = readFileSync(path.join(assets, "bp-paper-editor.bundle.js"), "utf8");
  const css = ["bp-paper-editor.css", "bp-paper-surface.css"].map((f) => readFileSync(path.join(assets, f), "utf8")).join("\n");
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/" });
  dom.window.BP_PAPER_EDITOR_NO_INJECT = true;
  dom.window.eval(js);
  const element = (tag) => dom.window.customElements.get(tag);
  const privateMembers = async (tag) => {
    const el = dom.window.document.createElement(tag);
    dom.window.document.body.append(el);
    await new Promise((resolve) => setTimeout(resolve, 50));
    const own = Object.getOwnPropertyNames(el);
    el.remove();
    return sorted([...Object.getOwnPropertyNames(element(tag).prototype), ...own].filter((n) => n.startsWith("_")));
  };
  const editor = element("bp-paper-editor");

  return {
    contract: editor.CONTRACT_VERSION,
    editor: editor.EDITOR_VERSION,
    build: editor.BUILD_SHA,
    declared: grouped(declared),
    internal: {
      members: { canvas: await privateMembers("bp-paper-canvas"), editor: await privateMembers("bp-paper-editor") },
      classes: undeclared([...stylesheetClasses(css), ...bundleClasses(js)]),
      attributes: undeclared(bundleAttributes(js)),
      events: undeclared(bundleEvents(js)),
    },
  };
}

export const render = (value) => `${JSON.stringify(value, null, 2)}\n`;

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync(surfacePath, render(await surface()));
  console.log(`wrote ${path.relative(root, surfacePath)}`);
}
