// __contract_truth.test.mjs — the declared surface is the real one.
//
// index.d.ts and EMBED-CONTRACT.md's "Surface index" are read by
// src/contract-surface.mjs. It fails when:
//   - index.d.ts and EMBED-CONTRACT.md disagree, either way;
//   - either element has a public prototype member, own instance property or
//     static (no leading `_`) that is not declared, or lacks a declared member;
//   - a declared event is never dispatched (inbound: never listened for), or a
//     declared attribute, class, token or global never appears in the source,
//     comments stripped, matched on name boundaries;
//   - the source dispatches an event, or reads a data-* attribute or bp-* class off
//     an ancestor or the document (closest, document.querySelector, a CSS selector
//     that starts with an attribute), that is neither declared nor listed below as
//     editor-internal or a reach-in EMBED-CONTRACT.md names;
//   - an upstream token in Styling is no longer read by the stylesheet;
//   - the committed bundle's statics are not this source's versions and BUILD_SHA.
// It does not read the hosts.
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
const stripComments = (text) => text.replace(/(^|\s)\/\*[\s\S]*?\*\//g, "$1").replace(/(^|[\s;{}),])\/\/.*$/gm, "$1");
const sourceFiles = walk(path.join(root, "src")).filter((p) => /\.(js|css)$/.test(p) && !path.basename(p).startsWith("__"));
const cssFiles = [path.join(root, "src/styles.css"), path.join(root, "../paper-surface/paper-surface.css"), path.join(root, "../paper-surface/code-tokens.css")];
const js = stripComments(sourceFiles.filter((p) => p.endsWith(".js")).map((p) => readFileSync(p, "utf8")).join("\n"));
const css = stripComments(cssFiles.map((p) => readFileSync(p, "utf8")).join("\n"));
const source = `${js}\n${css}`;
const escape = (name) => name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const appears = (name, text = source) => new RegExp(`(?<![\\w-])${escape(name)}(?![\\w-])`).test(text);

const EDITOR_INTERNAL = new Set(["bp-canvas-image-pick", "data-action", "data-bp-opaque", "data-bp-text-boundary", "data-test-id", "data-bp-paste-notice", "bp-canvas-image-chrome"]);
const REACH_INS = ["bp-flush-node", "data-block-id", "data-bp-paper-conflict"];

const declaredNames = new Set([...types].map((k) => k.split("|")[2]));
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
const publicInstance = (tag) => Object.getOwnPropertyNames(window.document.createElement(tag)).filter((n) => !n.startsWith("_"));

for (const [tag, element] of [["bp-paper-canvas", "canvas"], ["bp-paper-editor", "editor"]]) {
  const cls = window.customElements.get(tag);
  const declared = new Set(names("member", element));
  check(`every public member of <${tag}> is declared`, () => {
    assert.deepEqual(publicMembers(cls).filter((n) => !declared.has(n)).sort(), []);
  });
  check(`every public own property of a new <${tag}> is declared`, () => {
    assert.deepEqual(publicInstance(tag).filter((n) => !declared.has(n)).sort(), []);
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

const dispatched = (event) => new RegExp(`CustomEvent\\(\\s*["'\`]${event}["'\`]`).test(js);
const listened = (event) => new RegExp(`(addEventListener\\(\\s*["'\`]${event}["'\`]|["'\`]${event}["'\`]\\s*:\\s*on)`).test(js);

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
  assert.deepEqual(all.filter((n) => !appears(n)).sort(), []);
});

const camel = (name) => name.replace(/^data-/, "").replace(/-(\w)/g, (_, c) => c.toUpperCase());
const written = (name) => new RegExp([
  `(?:set|toggle)Attribute\\(\\s*["'\`]${escape(name)}["'\`]`,
  `["'\`]${escape(name)}["'\`]\\s*:`,
  `(?<![\\w-])${escape(name)}=["'\`$]`,
  ...(name.startsWith("data-") ? [`\\.dataset\\.${camel(name)}\\s*=(?!=)`, `internalLinkMark\\(\\s*["'\`]${escape(name.slice(5))}["'\`]`] : []),
].join("|")).test(js) || new RegExp(`(?<![\\w-])${escape(name)}\\s*:\\s*\\{\\s*default`, "i").test(js);

check("every declared DOM attribute is written by the source", () => {
  assert.deepEqual(names("DOM attribute", "canvas").filter((n) => !written(n)).sort(), []);
});

check("every declared host class appears in the source", () => {
  assert.deepEqual(names("host class", "canvas").filter((n) => !appears(n)).sort(), []);
});

check("every declared global is read by the source", () => {
  assert.deepEqual(names("global", "window").filter((g) => !appears(`window.${g}`, js)).sort(), []);
});

const known = (name) => declaredNames.has(name) || EDITOR_INTERNAL.has(name) || REACH_INS.includes(name);

check("every event the source dispatches is declared, editor-internal or a reach-in", () => {
  const literal = [...js.matchAll(/new\s+CustomEvent\(\s*(["'`])([\w-]+)\1/g)].map((m) => m[2]);
  assert.ok(literal.length > 0, "found no dispatched events");
  assert.equal(literal.length, [...js.matchAll(/new\s+CustomEvent\(/g)].length, "a CustomEvent whose name is not a plain literal");
  assert.deepEqual([...new Set(literal)].filter((e) => !known(e)).sort(), []);
});

check("every attribute and class the source reads off an ancestor or the document is declared, editor-internal or a reach-in", () => {
  const selectors = [...js.matchAll(/(?:\.closest|document\.querySelector(?:All)?)\(\s*(?:"([^"]*)"|'([^']*)'|`([^`]*)`)/g)].map((m) => m[1] ?? m[2] ?? m[3]);
  const rules = [...css.matchAll(/([^{}]+)\{/g)].flatMap((m) => m[1].split(",").map((part) => part.trim()));
  const leading = rules.flatMap((rule) => /^(?::root|html|:host|body)?((?:\[[^\]]+\])+)(?=[\s>~+]|$)/.exec(rule)?.[1] ?? []);
  const read = new Set([...selectors, ...leading].flatMap((sel) => [...sel.matchAll(/\[(data-[\w-]+)|\.(bp-[\w-]+)/g)].map((m) => m[1] ?? m[2])));
  assert.ok(read.has("data-paper-palette") && read.has("data-theme"), "the selector scan found nothing");
  assert.deepEqual([...read].filter((n) => !known(n)).sort(), []);
});

check("every reach-in the test allows is named in EMBED-CONTRACT.md's Known reach-ins", () => {
  const reachIns = md.slice(md.indexOf("## Known reach-ins"), md.indexOf("## Invariants"));
  assert.deepEqual(REACH_INS.filter((n) => !reachIns.includes(n)), []);
});

check("every upstream token in Styling is read by the stylesheet", () => {
  const styling = md.slice(md.indexOf("| Upstream token |"), md.indexOf("## `<bp-paper-canvas>`"));
  const upstream = [...styling.matchAll(/`(--[\w-]+?)(\*)?`/g)];
  assert.ok(upstream.length > 10, "found no upstream token table");
  const reads = [...source.matchAll(/var\(\s*(--[\w-]+)/g)].map((m) => m[1]);
  assert.deepEqual(upstream.filter(([, name, star]) => !reads.some((r) => (star ? r.startsWith(name) : r === name))).map(([t]) => t), []);
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
