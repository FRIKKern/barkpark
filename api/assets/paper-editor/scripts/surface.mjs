// Writes host-profile/surface.json: what the committed build offers a host, what it
// needs from one, what it keeps to itself, and the reach-ins between them.
//   declared  index.d.ts's names for the editor's elements (canvas, editor, both,
//             window, css); __contract_truth.test.mjs holds it equal to
//             EMBED-CONTRACT.md's Surface index.
//   host      index.d.ts's names the host supplies (picker, mermaid).
//   reachIns  EMBED-CONTRACT.md's Known reach-ins, by kind.
//   internal  read off the build a host loads, minus declared and reachIns:
//             - private members: the prototype's, a mounted element's own, and
//               every `this._x` in the source, which also finds the ones set later;
//             - classes in bp-paper-editor.css and in every string and template
//               chunk of the bundle (scripts/writes.mjs), less tags, ids and the
//               classes the reader writes (class="..." in
//               lib/barkpark/portable_doc/render: PortableDoc's page vocabulary,
//               styled by bp-paper-surface.css, the reader's sheet);
//             - data-* attributes the bundle writes or its TipTap schema renders;
//             - events the bundle dispatches.
// A host profile checks a host's sources against this file.
//
// Run: node scripts/surface.mjs   (npm run build runs it; src/__surface.test.mjs
// fails when the committed file is stale)
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { declaredInTypes, HOST_SUPPLIED, reachInsInContract } from "../src/contract-surface.mjs";
import { classWords, readerClasses, schemaAttributes, writtenAttributes } from "./writes.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const assets = path.join(root, "../../priv/static/assets");
const readerDir = path.join(root, "../../lib/barkpark/portable_doc/render");
export const surfacePath = path.join(root, "host-profile/surface.json");

const sorted = (list) => [...new Set(list)].sort();

const grouped = (keys) => {
  const out = {};
  for (const key of [...keys].sort()) {
    const [kind, element, name] = key.split("|");
    ((out[element] ??= {})[kind] ??= []).push(name);
  }
  return out;
};

const byKind = (keys) => {
  const out = {};
  for (const key of [...keys].sort()) {
    const [kind, name] = key.split("|");
    (out[kind] ??= []).push(name);
  }
  return out;
};

export const stylesheetClasses = (css) =>
  [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{/g)].flatMap((m) => [...m[1].matchAll(/\.(-?[_a-zA-Z][\w-]*)/g)].map((c) => c[1]));

export const bundleEvents = (js) => [...js.matchAll(/new\s+(?:Custom)?Event\(\s*["'`]([\w-]+)["'`]/g)].map((m) => m[1]);

export const notClasses = (js) => [
  ...[...js.matchAll(/(?:customElements\.define|createElement|getElementById)\(\s*["'`]([\w-]+)["'`]/g)].map((m) => m[1]),
  ...[...js.matchAll(/\.id\s*=\s*["'`]([\w-]+)["'`]/g)].map((m) => m[1]),
];

export const sourceMembers = (text) => [...text.matchAll(/\bthis\.(_[A-Za-z]\w*)/g)].map((m) => m[1]);

export async function mountedMembers(window, tag) {
  const el = window.document.createElement(tag);
  window.document.body.append(el);
  await new Promise((resolve) => setTimeout(resolve, 50));
  const members = [...Object.getOwnPropertyNames(window.customElements.get(tag).prototype), ...Object.getOwnPropertyNames(el)].filter((n) => n.startsWith("_"));
  const schema = schemaAttributes(el._editor.schema);
  el.remove();
  return { members, schema };
}

const sourceText = (dir) => readdirSync(dir).filter((n) => n.endsWith(".js")).map((n) => readFileSync(path.join(dir, n), "utf8")).join("\n");

export async function surface() {
  const types = declaredInTypes(readFileSync(path.join(root, "index.d.ts"), "utf8"));
  const reachIns = reachInsInContract(readFileSync(path.join(root, "EMBED-CONTRACT.md"), "utf8"));
  const names = new Set([...types, ...reachIns].map((k) => k.split("|").at(-1)));
  const internal = (list) => sorted(list).filter((n) => !names.has(n));

  const js = readFileSync(path.join(assets, "bp-paper-editor.bundle.js"), "utf8");
  const css = readFileSync(path.join(assets, "bp-paper-editor.css"), "utf8");
  const reader = readdirSync(readerDir).map((n) => readFileSync(path.join(readerDir, n), "utf8")).join("\n");
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/" });
  dom.window.BP_PAPER_EDITOR_NO_INJECT = true;
  dom.window.eval(js);
  const canvas = await mountedMembers(dom.window, "bp-paper-canvas");
  const editorEl = await mountedMembers(dom.window, "bp-paper-editor");
  const canvasSource = sourceText(path.join(root, "src/canvas"));
  const editorSource = sourceText(path.join(root, "src"));
  const editor = dom.window.customElements.get("bp-paper-editor");
  const notClass = new Set([...notClasses(js), ...readerClasses(reader)]);

  return {
    contract: editor.CONTRACT_VERSION,
    editor: editor.EDITOR_VERSION,
    build: editor.BUILD_SHA,
    declared: grouped([...types].filter((k) => !HOST_SUPPLIED.has(k.split("|")[1]))),
    host: grouped([...types].filter((k) => HOST_SUPPLIED.has(k.split("|")[1]))),
    reachIns: byKind(reachIns),
    internal: {
      members: {
        canvas: internal([...canvas.members, ...sourceMembers(canvasSource)]),
        editor: internal([...editorEl.members, ...sourceMembers(editorSource)]),
      },
      classes: internal([...stylesheetClasses(css), ...classWords(js)].filter((n) => !notClass.has(n))),
      attributes: internal([...writtenAttributes(js), ...canvas.schema, ...editorEl.schema].filter((n) => n.startsWith("data-"))),
      events: internal(bundleEvents(js)),
    },
  };
}

export const render = (value) => `${JSON.stringify(value, null, 2)}\n`;

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync(surfacePath, render(await surface()));
  console.log(`wrote ${path.relative(root, surfacePath)}`);
}
