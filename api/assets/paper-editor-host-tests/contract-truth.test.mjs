// contract-truth.test.mjs — Barkpark's editor integration matches the package contract.
//
// This suite owns canonical surface tokens, live reader writes, committed
// reach-ins and the generated bundle's version identity.
//
// Run: node api/assets/paper-editor-host-tests/contract-truth.test.mjs

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "./jsdom.mjs";
import { buildSha } from "../paper-editor/scripts/build-sha.mjs";
import { readerAttributes, writtenAttributes } from "../paper-editor/scripts/writes.mjs";
import {
  appears,
  declaredNames,
  globalAttribute,
  js,
  md,
  names,
  known,
  ownOrParentReads,
  packageCss,
  pkg,
  reachIns,
  root,
  selectorAttributes,
  sourceWrites,
  stripComments,
} from "../paper-editor/src/__contract_truth_support.mjs";

const hostCss = stripComments([
  packageCss,
  readFileSync(path.join(root, "../paper-surface/paper-surface.css"), "utf8"),
  readFileSync(path.join(root, "../paper-surface/code-tokens.css"), "utf8"),
].join("\n"));
const hostSource = `${js}\n${hostCss}`;
const bundle = readFileSync(path.join(root, "../../priv/static/assets/bp-paper-editor.bundle.js"), "utf8");
const readerDir = path.join(root, "../../lib/barkpark/portable_doc/render");
const reader = readdirSync(readerDir).map((name) => readFileSync(path.join(readerDir, name), "utf8")).join("\n");
const elsewhereWrites = new Set([...writtenAttributes(bundle), ...readerAttributes(reader)]);
const allowedRead = (name) => known(name) || globalAttribute(name) || sourceWrites.has(name) || elsewhereWrites.has(name);

let failures = 0;
let checks = 0;
const check = (name, fn) => {
  checks++;
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
  }
};

check("every declared CSS token appears in Barkpark's canonical source", () => {
  assert.deepEqual(names("token", "css").filter((name) => !appears(name, hostSource)).sort(), []);
});

check("every attribute the source reads off its own element is declared, written by the build or the reader, a global HTML attribute, editor-internal or a reach-in", () => {
  const { own } = ownOrParentReads(js);
  assert.ok(own.has("data-vocabulary") && own.has("editable"), "the own-attribute scan found nothing");
  assert.deepEqual([...own].filter((name) => !allowedRead(name)).sort(), []);
});

check("every attribute the source reads off a parent or the document root is declared, written by the build or the reader, a global HTML attribute, editor-internal or a reach-in", () => {
  assert.deepEqual([...ownOrParentReads(js).parents].filter((name) => !allowedRead(name)).sort(), []);
});

check("every attribute a canonical stylesheet selector names is declared, written by the build or the reader, a global HTML attribute, editor-internal or a reach-in", () => {
  const attributes = selectorAttributes(hostCss);
  assert.ok(attributes.has("data-paper-palette") && attributes.has("contenteditable"), "the selector scan found nothing");
  assert.deepEqual([...attributes].filter((name) => !allowedRead(name)).sort(), []);
});

check("every reach-in EMBED-CONTRACT.md lists by kind is in the committed build and is not declared", () => {
  const build = `${bundle}\n${readFileSync(path.join(root, "../../priv/static/assets/bp-paper-editor.css"), "utf8")}`;
  assert.ok(reachIns.has("domObserver") && reachIns.has("bp-flush-node"), "found no reach-in table");
  assert.deepEqual([...reachIns].filter((name) => !appears(name, build) || declaredNames.has(name)).sort(), []);
});

check("every upstream token in Styling is read by Barkpark's canonical stylesheets", () => {
  const styling = md.slice(md.indexOf("| Upstream token |"), md.indexOf("## `<bp-paper-canvas>`"));
  const upstream = [...styling.matchAll(/`(--[\w-]+?)(\*)?`/g)];
  assert.ok(upstream.length > 10, "found no upstream token table");
  const reads = [...hostSource.matchAll(/var\(\s*(--[\w-]+)/g)].map((match) => match[1]);
  assert.deepEqual(upstream.filter(([, name, star]) => !reads.some((read) => (star ? read.startsWith(name) : read === name))).map(([token]) => token), []);
});

const built = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/" });
built.window.BP_PAPER_EDITOR_NO_INJECT = true;
built.window.eval(bundle);
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
  console.log(`\n${failures} host contract truth check(s) FAILED`);
  process.exit(1);
}
if (checks !== 8) throw new Error(`expected 8 host checks, ran ${checks}`);
console.log("\nall 8 host contract truth checks (18 assertions) PASS");
