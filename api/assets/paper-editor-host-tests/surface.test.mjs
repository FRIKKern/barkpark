// surface.test.mjs — committed build, shell, and host-profile surface integration.
//
// The pure reader fixtures remain package-owned in src/__surface.test.mjs.
//
// Run: node ../paper-editor-host-tests/surface.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "./jsdom.mjs";
import { render, stylesheetClasses, surface, surfacePath } from "../paper-editor/scripts/surface.mjs";
import { schemaAttributes } from "../paper-editor/scripts/writes.mjs";
import { declaredInTypes, reachInsInContract } from "../paper-editor/src/contract-surface.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../paper-editor");
const assets = path.join(root, "../../priv/static/assets");
const pkg = JSON.parse(readFileSync(path.join(root, "package.json"), "utf8"));
const fresh = await surface();

let failures = 0;
const check = async (name, fn) => {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${error.message.split("\n").join("\n      ")}`);
  }
};
const lacks = (list, names) => names.filter((n) => !list.includes(n));
const leaves = (value, at = []) => Array.isArray(value) ? value.map((n) => `${at.join(".")}: ${n}`) : Object.entries(value).flatMap(([k, v]) => leaves(v, [...at, k]));

await check("the committed surface.json is a fresh read of the committed build", () => {
  const committed = readFileSync(surfacePath, "utf8");
  if (committed === render(fresh)) return;
  const [was, now] = [JSON.parse(committed), fresh].map((s) => new Set(leaves({ contract: [s.contract], editor: [s.editor], build: [s.build], declared: s.declared, host: s.host, reachIns: s.reachIns, reader: s.reader, internal: s.internal })));
  const moved = [...[...now].filter((l) => !was.has(l)).map((l) => `+ ${l}`), ...[...was].filter((l) => !now.has(l)).map((l) => `- ${l}`)];
  assert.fail(`run npm run build in api/assets/paper-editor and commit host-profile/surface.json\n${moved.join("\n") || "(same names, different bytes)"}`);
});

await check("surface.json names this package's versions and the bundle's BUILD_SHA", () => {
  assert.equal(fresh.contract, pkg.barkpark.contractVersion);
  assert.equal(fresh.editor, pkg.version);
  assert.match(fresh.build, /^[0-9a-f]{12}$/);
});

await check("declared and host together are every name index.d.ts declares; host holds picker and mermaid only", () => {
  const keys = [fresh.declared, fresh.host].flatMap((group) => Object.entries(group).flatMap(([element, kinds]) => Object.entries(kinds).flatMap(([kind, names]) => names.map((n) => `${kind}|${element}|${n}`))));
  assert.deepEqual(keys.sort(), [...declaredInTypes(readFileSync(path.join(root, "index.d.ts"), "utf8"))].sort());
  assert.deepEqual(Object.keys(fresh.host).sort(), ["mermaid", "picker"]);
  assert.deepEqual(fresh.declared.canvas.tag, ["bp-paper-canvas"]);
});

await check("reachIns is EMBED-CONTRACT.md's Known reach-ins by kind", () => {
  const keys = Object.entries(fresh.reachIns).flatMap(([kind, names]) => names.map((n) => `${kind}|${n}`));
  assert.deepEqual(keys.sort(), [...reachInsInContract(readFileSync(path.join(root, "EMBED-CONTRACT.md"), "utf8"))].sort());
});

await check("each reader finds a name only it finds in the real build", () => {
  const { members, classes, attributes, events } = fresh.internal;
  assert.deepEqual(lacks(members.canvas, ["_editor", "_noteInlineObjectSave", "_onDrop", "_pendingFocus"]), [], "canvas members: own, prototype, prototype _on*, class body only");
  assert.deepEqual(lacks(members.editor, ["_editor", "_requestTableStructure", "_onKeyDown", "_discardTableDraft"]), [], "editor members: own, prototype, prototype _on*, class body only");
  assert.deepEqual(lacks(classes, ["hljs-keyword", "ProseMirror-widget", "prosemirror-dropcursor-block", "tiptap", "bp-slash-menu", "bp-link-preview__head"]), [], "classes: stylesheet, string, each prefix, ternary template, const + template");
  assert.deepEqual(lacks(attributes, ["data-pm-slice", "data-tiptap-style", "data-bp-figure-constraint", "data-bp-opaque-mark"]), [], "attributes: setAttribute, template name, dataset, addAttributes helper");
  assert.deepEqual(lacks(fresh.reader.classes, ["text-dim", "bp-table__td", "bp-callout"]), [], "reader classes: class=\"…\" token, a helper's string, both");
  assert.deepEqual(lacks(fresh.reader.attributes, ["data-p", "data-valueref"]), [], "reader attributes: attr=, a key");
  assert.deepEqual(lacks(events, ["bp-canvas-image-pick"]), [], "events");
  assert.deepEqual(attributes.filter((a) => !a.startsWith("data-")), [], "only data-* attributes; the schema also renders fallback, anchor, field");
});

await check("what is not internal stays out: tags, reader vocabulary, reach-ins, and names set only outside the element classes", () => {
  const { classes, attributes, events, members } = fresh.internal;
  const out = ["bp-paper-canvas", "bp-media-picker", "bp-callout", "bp-card", "bp-paper-article", "bp-sheet__td", "bp-mp-empty", "bp-ref-search-input"].filter((n) => classes.includes(n));
  const outAttributes = ["data-p", "data-valueref", "data-block-id"].filter((n) => attributes.includes(n));
  const outMembers = ["_key", "_onScroll", "_input", "_el"].filter((n) => members.canvas.includes(n) || members.editor.includes(n));
  assert.deepEqual([...out, ...outAttributes, ...outMembers, ...events.filter((e) => e === "bp-flush-node")], []);
});

await check("every data-* attribute the TipTap schema renders, on either element, is in a group", async () => {
  const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { runScripts: "outside-only", pretendToBeVisual: true, url: "http://localhost/" });
  dom.window.BP_PAPER_EDITOR_NO_INJECT = true;
  dom.window.eval(readFileSync(path.join(assets, "bp-paper-editor.bundle.js"), "utf8"));
  const rendered = [];
  for (const tag of ["bp-paper-canvas", "bp-paper-editor"]) {
    const el = dom.window.document.createElement(tag);
    dom.window.document.body.append(el);
    await new Promise((resolve) => setTimeout(resolve, 50));
    rendered.push(...schemaAttributes(el._editor.schema).filter((a) => a.startsWith("data-")));
    el.remove();
  }
  const grouped = new Set([fresh.declared, fresh.host, fresh.reachIns, fresh.reader, fresh.internal].flatMap((group) => leaves(group).map((l) => l.split(": ")[1])));
  assert.ok(rendered.includes("data-valueref"), "the schema scan found nothing");
  assert.deepEqual([...new Set(rendered)].filter((a) => !grouped.has(a)).sort(), []);
});

await check("every class Studio's shell stylesheet restyles that the bundle writes, or whose BEM block it writes, is in a group", () => {
  const bundle = readFileSync(path.join(assets, "bp-paper-editor.bundle.js"), "utf8");
  const shell = stylesheetClasses(readFileSync(path.join(assets, "bp-paper-editor-shell.css"), "utf8"));
  const known = new Set([fresh.declared, fresh.host, fresh.reachIns, fresh.reader, fresh.internal].flatMap((group) => leaves(group).map((l) => l.split(": ")[1])));
  const writes = (name) => new RegExp(`(?<![\\w-])${name}(?![\\w-])`).test(bundle);
  const editorStyled = [...new Set(shell)].filter((c) => /^(?:bp-|ProseMirror|tiptap|hljs)/.test(c) && (writes(c) || writes(c.split("__")[0])));
  assert.ok(editorStyled.length > 200, `only ${editorStyled.length} shell classes the bundle writes`);
  assert.deepEqual(editorStyled.filter((c) => !known.has(c)).sort(), []);
});

await check("names hosts outside this repo restyle today are in their group", () => {
  const internal = new Set([...fresh.internal.classes, ...fresh.internal.attributes]);
  const reader = new Set([...fresh.reader.classes, ...fresh.reader.attributes]);
  const hosts = [
    ["barkpark-studio app/src/styles.css:2063-2067", internal, ["bp-canvas-image-menu", "bp-canvas-object-menu", "bp-slash-menu"]],
    ["Barkdown app/renderer/paper-notion.css:167,183,200", internal, ["bp-slash-menu", "bp-link-preview"]],
    ["Barkdown app/renderer/paper-notion.css", reader, ["bp-callout", "bp-callout__body", "bp-callout__summary", "bp-section-divider", "bp-section-divider__mark", "bp-table", "bp-table__th"]],
    ["Barkdown app/renderer/vendor/bp-paper-popups.css", internal, ["data-bp-paste-notice", "data-bp-text-boundary"]],
  ];
  assert.deepEqual(hosts.flatMap(([where, group, names]) => names.filter((n) => !group.has(n)).map((n) => `${n} (${where})`)), []);
});

await check("no name is in two of the contract (declared, host), reachIns, reader and internal", () => {
  const groups = { contract: { declared: fresh.declared, host: fresh.host }, reachIns: fresh.reachIns, reader: fresh.reader, internal: fresh.internal };
  const owner = new Map();
  const twice = [];
  for (const [group, value] of Object.entries(groups)) {
    for (const name of new Set(leaves(value).map((l) => l.split(": ")[1]))) {
      if (owner.has(name) && owner.get(name) !== group) twice.push(`${name}: ${owner.get(name)} and ${group}`);
      owner.set(name, group);
    }
  }
  assert.deepEqual(twice, []);
});


if (failures) {
  console.log(`\n${failures} surface check(s) FAILED`);
  process.exit(1);
}
console.log("\nall surface checks PASS");
