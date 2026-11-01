// __contract_truth.test.mjs — the declared surface is the real one.
//
// index.d.ts, EMBED-CONTRACT.md's "Surface index" and the two element classes
// must name the same members, statics, attributes, events, globals, classes and
// CSS tokens (src/contract-surface.mjs reads both files). It fails when:
//   - index.d.ts and EMBED-CONTRACT.md disagree, either way;
//   - either element class has a public member (no leading `_`) or static that is
//     not declared, or a declared member it does not have;
//   - a declared event is never dispatched (or, inbound, never listened for), or
//     a declared attribute, class or token never appears in the source;
//   - the committed bundle's statics are not this source's versions and BUILD_SHA.
//
// Run: node src/__contract_truth.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { declaredInContract, declaredInTypes } from "./contract-surface.mjs";
import { buildSha } from "../scripts/build-sha.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (rel) => readFileSync(path.join(root, rel), "utf8");
const pkg = JSON.parse(read("package.json"));
const md = read("EMBED-CONTRACT.md");
const types = declaredInTypes(read("index.d.ts"));
const contract = declaredInContract(md);

const walk = (dir) => readdirSync(dir).flatMap((name) => {
  const p = path.join(dir, name);
  return statSync(p).isDirectory() ? walk(p) : [p];
});
const sourceFiles = walk(path.join(root, "src")).filter((p) => /\.(js|css)$/.test(p) && !path.basename(p).startsWith("__"));
const source = [...sourceFiles, path.join(root, "../paper-surface/paper-surface.css")].map((p) => readFileSync(p, "utf8")).join("\n");

const names = (kind, element) => [...types].filter((k) => k.startsWith(`${kind}|${element}|`)).map((k) => k.split("|")[2]);
const missing = (from, to) => [...from].filter((k) => !to.has(k)).sort();

let failures = 0;
const check = (name, fn) => {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
  }
};

check("index.d.ts declares every name EMBED-CONTRACT.md indexes", () => {
  assert.deepEqual(missing(contract, types), []);
});

check("EMBED-CONTRACT.md indexes every name index.d.ts declares", () => {
  assert.deepEqual(missing(types, contract), []);
});

check("EMBED-CONTRACT.md describes every indexed name outside the index", () => {
  const body = md.slice(0, md.indexOf("## Surface index")) + md.slice(md.indexOf("## Known reach-ins"));
  const undescribed = [...contract].map((k) => k.split("|")[2]).filter((n) => !new RegExp("`(window\\.|\\[|\\.)?" + n.replace(/[$]/g, "\\$") + "[`( =\\]]").test(body));
  assert.deepEqual([...new Set(undescribed)].sort(), []);
});

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
window.BP_PAPER_EDITOR_NO_INJECT = true;
await import("./index.js");

const LIFECYCLE = new Set(["constructor", "connectedCallback", "disconnectedCallback", "attributeChangedCallback", "adoptedCallback"]);
const STATIC_BUILTINS = new Set(["length", "name", "prototype", "observedAttributes"]);
const publicMembers = (cls) => Object.getOwnPropertyNames(cls.prototype).filter((n) => !n.startsWith("_") && !LIFECYCLE.has(n));
const publicStatics = (cls) => Object.getOwnPropertyNames(cls).filter((n) => !n.startsWith("_") && !STATIC_BUILTINS.has(n));

for (const [tag, element] of [["bp-paper-canvas", "canvas"], ["bp-paper-editor", "editor"]]) {
  const cls = window.customElements.get(tag);
  const declared = new Set(names("member", element));
  check(`every public member of <${tag}> is declared`, () => {
    assert.deepEqual(publicMembers(cls).filter((n) => !declared.has(n)).sort(), []);
  });
  check(`<${tag}> has every member declared for it`, () => {
    assert.deepEqual([...declared].filter((n) => !(n in cls.prototype)).sort(), []);
  });
  check(`<${tag}>'s public statics are the declared ones, with this source's versions`, () => {
    assert.deepEqual(publicStatics(cls).sort(), names("static", "both").sort());
    assert.equal(cls.CONTRACT_VERSION, pkg.barkpark.contractVersion);
    assert.equal(cls.EDITOR_VERSION, pkg.version);
    assert.equal(cls.BUILD_SHA, null, "unbuilt source has no BUILD_SHA");
  });
}

check("EMBED-CONTRACT.md's title and opening name this CONTRACT_VERSION", () => {
  const version = pkg.barkpark.contractVersion;
  assert.ok(md.startsWith(`# \`<bp-paper-editor>\` and \`<bp-paper-canvas>\` — Embed Contract (v${version})`), "title");
  assert.ok(md.includes(`\`BpPaperEditor.CONTRACT_VERSION === "${version}"\``), "opening line");
  assert.ok(read("index.d.ts").includes(`EMBED-CONTRACT.md\n// (v${version})`), "index.d.ts header");
});

const dispatched = (event) => new RegExp(`CustomEvent\\(\\s*["'\`]${event}["'\`]`).test(source);
const listened = (event) => new RegExp(`(addEventListener\\(\\s*["'\`]${event}["'\`]|["'\`]${event}["'\`]\\s*:\\s*on)`).test(source);

check("every declared outbound event is dispatched by the source", () => {
  const silent = [...names("event", "canvas"), ...names("event", "editor")].filter((e) => !dispatched(e));
  assert.deepEqual([...new Set(silent)].sort(), []);
});

check("every declared inbound event is listened for by the source", () => {
  assert.deepEqual(names("inbound event", "canvas").filter((e) => !listened(e)).sort(), []);
});

check("every declared attribute, class and token appears in the source", () => {
  const all = ["attribute|canvas", "attribute|editor", "ancestor attribute|canvas", "DOM attribute|canvas", "class|canvas", "token|css"]
    .flatMap((g) => names(...g.split("|")));
  assert.deepEqual(all.filter((n) => !source.includes(n)).sort(), []);
});

check("every declared global is read by the source", () => {
  assert.deepEqual(names("global", "window").filter((g) => !source.includes(`window.${g}`)).sort(), []);
});

const built = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/" });
built.window.BP_PAPER_EDITOR_NO_INJECT = true;
built.window.eval(readFileSync(path.join(root, "../../priv/static/assets/bp-paper-editor.bundle.js"), "utf8"));
const sha = await buildSha();

for (const tag of ["bp-paper-canvas", "bp-paper-editor"]) {
  check(`the committed bundle's <${tag}> reads this source's versions and BUILD_SHA at runtime`, () => {
    const cls = built.window.customElements.get(tag);
    assert.equal(cls.CONTRACT_VERSION, pkg.barkpark.contractVersion);
    assert.equal(cls.EDITOR_VERSION, pkg.version);
    assert.match(cls.BUILD_SHA, /^[0-9a-f]{12}$/);
    assert.equal(cls.BUILD_SHA, sha, "run npm run build");
  });
}

if (failures) {
  console.log(`\n${failures} contract truth check(s) FAILED`);
  process.exit(1);
}
console.log("\nall contract truth checks PASS");
