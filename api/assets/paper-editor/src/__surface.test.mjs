// __surface.test.mjs — host-profile/surface.json is what the committed build gives.
//
// scripts/surface.mjs reads the declared surface out of index.d.ts and the internal
// one out of the committed bundle and dist stylesheets. This fails when the
// committed file differs from a fresh read (run npm run build), when its versions
// are not this package's, or when a reader finds nothing it is known to find.
//
// Run: node src/__surface.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { render, surface, surfacePath } from "../scripts/surface.mjs";
import { declaredInTypes } from "./contract-surface.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pkg = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const fresh = await surface();

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

check("the committed surface.json is a fresh read of the committed build", () => {
  assert.equal(readFileSync(surfacePath, "utf8"), render(fresh), "run npm run build in api/assets/paper-editor and commit host-profile/surface.json");
});

check("surface.json names this package's versions and the bundle's BUILD_SHA", () => {
  assert.equal(fresh.contract, pkg.barkpark.contractVersion);
  assert.equal(fresh.editor, pkg.version);
  assert.match(fresh.build, /^[0-9a-f]{12}$/);
});

check("declared lists every name index.d.ts declares, under its element and kind", () => {
  const keys = Object.entries(fresh.declared).flatMap(([element, kinds]) => Object.entries(kinds).flatMap(([kind, names]) => names.map((n) => `${kind}|${element}|${n}`)));
  assert.deepEqual(keys.sort(), [...declaredInTypes(readFileSync(path.join(root, "index.d.ts"), "utf8"))].sort());
});

check("each internal reader finds a name only it can find", () => {
  const { members, classes, attributes, events } = fresh.internal;
  const lacks = (list, names) => names.filter((n) => !list.includes(n));
  assert.deepEqual(lacks(members.canvas, ["_editor", "_noteInlineObjectSave"]), [], "canvas members: a mounted element's own, the prototype's");
  assert.deepEqual(lacks(members.editor, ["_editor", "_requestTableStructure"]), [], "editor members");
  assert.deepEqual(lacks(classes, ["hljs-keyword", "ProseMirror-widget", "tiptap", "bp-slash-foot-sep", "bp-paper-format__btn--bold"]), [], "classes: stylesheet, classList, className, class=, BEM string");
  assert.deepEqual(lacks(attributes, ["data-pm-slice", "data-checked", "data-field"]), [], "attributes: setAttribute, key, attr=");
  assert.deepEqual(lacks(events, ["bp-flush-node", "bp-canvas-image-pick"]), [], "events");
});

check("no name is both declared and internal", () => {
  const declared = new Set(Object.values(fresh.declared).flatMap((kinds) => Object.values(kinds).flat()));
  const { members, classes, attributes, events } = fresh.internal;
  assert.deepEqual([...members.canvas, ...members.editor, ...classes, ...attributes, ...events].filter((n) => declared.has(n)), []);
});

if (failures) {
  console.log(`\n${failures} surface check(s) FAILED`);
  process.exit(1);
}
console.log("\nall surface checks PASS");
