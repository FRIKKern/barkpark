// __surface.test.mjs — host-profile/surface.json is what the committed build gives.
//
// scripts/surface.mjs reads declared and host out of index.d.ts, reachIns out of
// EMBED-CONTRACT.md and internal out of the committed bundle and dist stylesheet,
// through the readers in scripts/writes.mjs. This fails when:
//   - the committed file differs from a fresh read (naming each name that moved);
//   - its versions are not this package's;
//   - declared and host are not index.d.ts, or reachIns is not EMBED-CONTRACT.md;
//   - a reader misses a form on a small fixture, one name per form;
//   - a reader misses a name only it finds in the real build;
//   - a class Studio's shell stylesheet restyles, which the bundle writes (or
//     whose BEM block it writes), is not in surface.json or written by the reader;
//   - a name hosts outside this repo restyle today is missing;
//   - a name sits in two of the contract, reachIns and internal.
//
// Run: node src/__surface.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";
import { bundleEvents, mountedMembers, notClasses, render, sourceMembers, stylesheetClasses, surface, surfacePath } from "../scripts/surface.mjs";
import { classWords, lex, readerAttributes, readerClasses, schemaAttributes, writtenAttributes } from "../scripts/writes.mjs";
import { declaredInTypes, reachInsInContract } from "./contract-surface.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
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
  const [was, now] = [JSON.parse(committed), fresh].map((s) => new Set(leaves({ contract: [s.contract], editor: [s.editor], build: [s.build], declared: s.declared, host: s.host, reachIns: s.reachIns, internal: s.internal })));
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

await check("each reader finds every form on a fixture", async () => {
  const css = `/* .gone */ .Upper-Case, .two:hover > .three { x: 1 } @media (min-width: 1.5rem) { .in-media { x: 1 } }`;
  assert.deepEqual(stylesheetClasses(css).sort(), ["Upper-Case", "in-media", "three", "two"]);

  const js = [
    `const Qe="bp-block";`,
    `a.className="bp-plain"; b.className='bp-single tiptap';`,
    "c.innerHTML=`<div class=\"bp-in-template\">${x}</div>`;",
    "d.className=x?`bp-ternary ${y}`:\"bp-ternary\";",
    "e(`${Qe}__head`, `${Qe}--mod`, `bp-partial-${z}`);",
    `f("ProseMirror-thing","hljs-scope","#bp-an-id");`,
    `const re=/"bp-in-regex"/g; // "bp-in-comment"`,
    `/* a/b "bp-in-block-comment" */ g.classList.toggle("bp-toggled");`,
    "const dep = `${ {a: 1}.a /* \"bp-hidden-in-expression\" */ }`;",
    `const v = (o.void) / 2; const w = "bp-after-paren"; const z = 1 / 2;`,
    `function h(){return /"bp-after-return"/.test(x)}`,
    `const q = a / b; const s = "bp-after-division"; const t = c / d;`,
    `const k = /[/]"bp-slash-in-class"/;`,
    `const esc = "a\\" bp-escaped \\"";`,
    "const te = `a\\` bp-template-escaped`;",
    "const nest = `${ {a: `bp-inner`}.a } ${Qe}__second bp-outer`;",
  ].join("\n");
  assert.deepEqual(classWords(js).sort(), ["ProseMirror-thing", "bp-after-division", "bp-after-paren", "bp-block", "bp-block--mod", "bp-block__head", "bp-block__second", "bp-escaped", "bp-in-template", "bp-inner", "bp-outer", "bp-plain", "bp-single", "bp-template-escaped", "bp-ternary", "bp-toggled", "hljs-scope", "tiptap"]);
  assert.throws(() => lex("x = `${a"), /lexer ended inside 1 template expression/);
  assert.deepEqual(reachInsInContract("## Known reach-ins\n| Kind | Names |\n|---|---|\n| member | `a` |\n| Who | `b` |\n| event | `c` | x |\n## Next\n| event | `d` |\n"), new Set(["member|a"]));
  assert.deepEqual(notClasses(`customElements.define("bp-tag",X);document.createElement("bp-made");document.getElementById("bp-id1");n.id="bp-id2";`).sort(), ["bp-id1", "bp-id2", "bp-made", "bp-tag"]);
  assert.deepEqual(bundleEvents(`new CustomEvent("bp-a");new Event('bp-b');`), ["bp-a", "bp-b"]);

  const writes = [
    `a.setAttribute("data-set",1);a.toggleAttribute('data-toggle');a.setAttributeNS(null,"data-ns","");`,
    `const sc="data-const";a.setAttribute(sc,"");`,
    "a.setAttribute(`data-template${n}`,\"\");a.setAttribute(`data-${n}`,\"\");",
    `const o={"data-key":1};`,
    "a.innerHTML=`<i data-chunk=\"1\"></i>`;",
    `a.dataset.camelCase="x";a.dataset["bracketKey"]="y";Object.assign(a.dataset,{assigned:1});`,
    `X.create({addAttributes(){return{level:{default:null},m:_k("m","data-helper"),docId:{default:null}}}});`,
    `const o2={"aria-label":1,"not-data-key":2};`,
    `a.getAttribute("data-read");if(a.dataset.compared==="x");`,
  ].join("\n");
  assert.deepEqual(writtenAttributes(writes).sort(), ["data-assigned", "data-bracket-key", "data-camel-case", "data-chunk", "data-const", "data-helper", "data-key", "data-ns", "data-set", "data-template", "data-toggle", "docid", "level"]);

  const { window } = new JSDOM("");
  const node = window.document.createElement("span");
  node.setAttribute("data-from-node", "");
  const wrapped = window.document.createElement("span");
  wrapped.setAttribute("data-from-dom-wrapper", "");
  const schema = {
    nodes: {
      doc: { spec: {} },
      box: { spec: { toDOM: () => ["div", { "data-box": "", "xlink href": "" }, ["span", { "data-nested": "" }, 0]] }, createAndFill: () => ({}) },
      bare: { spec: { toDOM: () => ["p", ["b", { "data-child-of-bare": "" }]] }, createAndFill: () => ({}) },
      text: { spec: { toDOM: () => "just text" }, createAndFill: () => ({}) },
      live: { spec: { toDOM: () => node }, createAndFill: () => ({}) },
      view: { spec: { toDOM: () => ({ dom: wrapped }) }, createAndFill: () => ({}) },
    },
    marks: { link: { spec: { toDOM: () => ["a", { "data-docId": "" }, 0] }, create: () => ({}) } },
  };
  assert.deepEqual(schemaAttributes(schema).sort(), ["data-box", "data-child-of-bare", "data-docid", "data-from-dom-wrapper", "data-from-node", "data-nested", "href"]);

  const ex = `~s(<div class="bp-r1 bp-r2" data-r1="x">) <> ~s(<span class=\\"bp-r3\\">) %{"data-r2" => 1}`;
  assert.deepEqual(readerClasses(ex).sort(), ["bp-r1", "bp-r2", "bp-r3"]);
  assert.deepEqual(readerAttributes(ex).sort(), ["data-r1", "data-r2"]);

  assert.deepEqual(sourceMembers(`this._set = 1; this._called(); other._not;`), ["_set", "_called"]);
  const dom = new JSDOM("<!doctype html><body></body>", { runScripts: "outside-only" });
  dom.window.eval(`customElements.define("bp-fixture", class extends HTMLElement {
    constructor() { super(); this._own = 1; }
    connectedCallback() { this._editor = { schema: { nodes: {}, marks: {} } }; }
    _onThing() {}
    publicThing() {}
    has_underscore() {}
  });`);
  assert.deepEqual((await mountedMembers(dom.window, "bp-fixture")).members.sort(), ["_editor", "_onThing", "_own"]);
});

await check("each reader finds a name only it finds in the real build", () => {
  const { members, classes, attributes, events } = fresh.internal;
  assert.deepEqual(lacks(members.canvas, ["_editor", "_noteInlineObjectSave", "_onDrop", "_pendingFocus"]), [], "canvas members: own, prototype, prototype _on*, source-only");
  assert.deepEqual(lacks(members.editor, ["_editor", "_requestTableStructure"]), [], "editor members");
  assert.deepEqual(lacks(classes, ["hljs-keyword", "ProseMirror-widget", "bp-slash-menu", "bp-link-preview__head"]), [], "classes: stylesheet, string, ternary template, const + template");
  assert.deepEqual(lacks(attributes, ["data-pm-slice", "data-tiptap-style", "data-bp-figure-constraint", "data-bp-opaque-mark", "data-valueref"]), [], "attributes: setAttribute, template name, dataset, addAttributes helper, schema output");
  assert.deepEqual(lacks(events, ["bp-canvas-image-pick"]), [], "events");
  assert.deepEqual(attributes.filter((a) => !a.startsWith("data-")), [], "only data-* attributes; the schema also renders fallback, anchor, field");
});

await check("what is not internal stays out: tags, the reader's classes, classes only bp-paper-surface.css styles, reach-ins", () => {
  const { classes, events } = fresh.internal;
  const out = ["bp-paper-canvas", "bp-media-picker", "bp-callout", "bp-card", "bp-paper-article", "bp-sheet__td", "bp-mp-empty", "bp-ref-search-input"].filter((n) => classes.includes(n));
  assert.deepEqual([...out, ...events.filter((e) => e === "bp-flush-node")], []);
});

await check("every class Studio's shell stylesheet restyles that the bundle writes, or whose BEM block it writes, is in surface.json or written by the reader", () => {
  const bundle = readFileSync(path.join(assets, "bp-paper-editor.bundle.js"), "utf8");
  const shell = stylesheetClasses(readFileSync(path.join(assets, "bp-paper-editor-shell.css"), "utf8"));
  const readerDir = path.join(root, "../../lib/barkpark/portable_doc/render");
  const reader = new Set(readerClasses(readdirSync(readerDir).map((n) => readFileSync(path.join(readerDir, n), "utf8")).join("\n")));
  const known = new Set([fresh.declared, fresh.host, fresh.reachIns, fresh.internal].flatMap((group) => leaves(group).map((l) => l.split(": ")[1])));
  const writes = (name) => new RegExp(`(?<![\\w-])${name}(?![\\w-])`).test(bundle);
  const editorStyled = [...new Set(shell)].filter((c) => /^(?:bp-|ProseMirror|tiptap|hljs)/.test(c) && (writes(c) || writes(c.split("__")[0])));
  assert.ok(editorStyled.length > 200, `only ${editorStyled.length} shell classes the bundle writes`);
  assert.deepEqual(editorStyled.filter((c) => !known.has(c) && !reader.has(c)).sort(), []);
});

await check("names hosts outside this repo restyle today are internal", () => {
  const hosts = {
    "barkpark-studio app/src/styles.css:2063-2067": ["bp-canvas-image-menu", "bp-canvas-object-menu", "bp-slash-menu"],
    "Barkdown app/renderer/paper-notion.css:167,183,200": ["bp-slash-menu", "bp-link-preview"],
    "Barkdown app/renderer/vendor/bp-paper-popups.css": ["data-bp-paste-notice", "data-bp-text-boundary"],
  };
  const internal = new Set([...fresh.internal.classes, ...fresh.internal.attributes]);
  assert.deepEqual(Object.entries(hosts).flatMap(([where, names]) => names.filter((n) => !internal.has(n)).map((n) => `${n} (${where})`)), []);
});

await check("no name is in two of the contract (declared, host), reachIns and internal", () => {
  const groups = { contract: { declared: fresh.declared, host: fresh.host }, reachIns: fresh.reachIns, internal: fresh.internal };
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
