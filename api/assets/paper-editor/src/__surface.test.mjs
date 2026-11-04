// __surface.test.mjs — portable surface readers accept every supported source form.
//
// The committed-build, shell, and host-profile checks live in the sibling host
// surface.test.mjs. This package check keeps every pure parser and schema fixture.
//
// Run: node src/__surface.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import {
  bundleEvents,
  elementClassBody,
  extractPackageSurfaceEvidence,
  mountedMembers,
  notClasses,
  sourceMembers,
  stylesheetClasses,
} from "../scripts/surface-package.mjs";
import { classWords, lex, readerAttributes, readerClasses, schemaAttributes, writtenAttributes } from "../scripts/writes.mjs";
import { reachInsInContract } from "./contract-surface.mjs";

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
  assert.deepEqual(lex(`const r = /[/a/']/; x = 'bp-y'`).strings, ["bp-y"]);
  assert.deepEqual(lex(`x = "bp-open`).strings, ["bp-open"]);
  assert.deepEqual(reachInsInContract("## Known reach-ins\n| Kind | Names |\n|---|---|\n| member | `a` |\n| expando | `b`, `c` |\n| attribute | `d` |\n| class | `e` |\n| event | `f` |\n| Who | `g` |\n| event | `h` | x |\n## Next\n| event | `i` |\n"), new Set(["member|a", "expando|b", "expando|c", "attribute|d", "class|e", "event|f"]));
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

  const ex = [
    `@moduledoc """`, `Styled by .bp-in-moduledoc and [data-in-moduledoc="x"].`, `"""`,
    `~s(<div class=" bp-r1  plain-r2" data-r1="x">) <> ~s(<span class=\\"bp-r3\\">) %{"data-r2" => 1}`,
    `~s|<div class="bp-card#{tone} bp-tone--#{t} #{cls}">| # .bp-in-comment data-in-comment="x"`,
    `nav_class = if sticky, do: "bp-toc bp-toc--sticky", else: "bp-toc"`,
    `  # mirrors .bp-in-line-comment`,
  ].join("\n");
  assert.deepEqual(readerClasses(ex).sort(), ["bp-card", "bp-r1", "bp-r3", "bp-toc", "bp-toc--sticky", "plain-r2"]);
  assert.deepEqual(readerAttributes(ex).sort(), ["data-r1", "data-r2"]);
  assert.deepEqual(readerClasses(`~s(<p class="plain">)`), ["plain"]);

  assert.deepEqual(sourceMembers(`this._set = 1; this._called(); other._not;`), ["_set", "_called"]);
  assert.equal(elementClassBody("class Helper { m() { this._a = 1; } }\nclass El extends HTMLElement {\n  m() { if (x) { this._b = 1; } }\n}\nfunction after() { this._c = 1; }\n"), "class El extends HTMLElement {\n  m() { if (x) { this._b = 1; } }\n}");
  assert.throws(() => elementClassBody("class Helper {}"), /no custom element class/);
  const dom = new JSDOM("<!doctype html><body></body>", { runScripts: "outside-only" });
  dom.window.eval(`customElements.define("bp-fixture", class extends HTMLElement {
    constructor() { super(); this._own = 1; }
    connectedCallback() { this._editor = { schema: { nodes: {}, marks: {} } }; }
    _onThing() {}
    publicThing() {}
    has_underscore() {}
  });`);
  assert.deepEqual((await mountedMembers(dom.window, "bp-fixture")).sort(), ["_editor", "_onThing", "_own"]);
});

const syntheticTypes = `
export interface BpPaperCanvasElement {
  _declaredCanvas(): void;
}
export interface BpPaperEditorElement {
  _declaredEditor(): void;
}
export interface BpPaperBuildInfo {
  readonly CONTRACT_VERSION: string;
  readonly EDITOR_VERSION: string;
  readonly BUILD_SHA: string;
}
export interface BpPaperCanvasAttributes {
  "data-canvas": string;
}
export interface BpPaperEditorAttributes {
  "data-editor": string;
}
export interface BpPaperAncestorAttributes {
  "data-ancestor": string;
}
export interface BpPaperDomAttributes {
  "data-dom": string;
}
export interface BpPaperCanvasEventMap {
  "bp-canvas-event": CustomEvent;
}
export interface BpPaperEditorEventMap {
  "bp-editor-event": CustomEvent;
}
export interface BpPaperInboundEventMap {
  "bp-inbound-event": CustomEvent;
}
export type BpHostPickerTag = "bp-media-picker";
export interface BpHostPickerElement {
  open(): void;
}
export interface BpHostPickerAttributes {
  mode: string;
}
export interface BarkparkPaperMermaidRuntime {
  render(): void;
}
export type BpPaperPublicClass = "bp-public";
export type BpPaperHostClass = "bp-host";
export type BpPaperThemeToken = "--bp-test";
declare global {
  interface Window {
    syntheticGlobal: string;
  }
  interface HTMLElementTagNameMap {
    "bp-paper-canvas": BpPaperCanvasElement;
    "bp-paper-editor": BpPaperEditorElement;
  }
}
`;
const syntheticContract = `
## Known reach-ins
| Kind | Names | Why |
|---|---|---|
| member | \`_reach\` | test
## Next
`;
const syntheticBundle = `
customElements.define("bp-paper-canvas", class extends HTMLElement {
  constructor() { super(); this._canvasOwn = true; }
  connectedCallback() { this._canvasMounted = true; }
  _canvasMethod() {}
});
class SyntheticEditor extends HTMLElement {
  static CONTRACT_VERSION = "9.9.0";
  static EDITOR_VERSION = "0.0.0-test";
  static BUILD_SHA = "abcdef123456";
  constructor() { super(); this._editorOwn = true; }
  connectedCallback() { this._editorMounted = true; }
  _editorMethod() {}
}
customElements.define("bp-paper-editor", SyntheticEditor);
document.body.className = "bp-bundle-class bp-reader-future";
document.body.dataset.syntheticWritten = "yes";
document.body.dispatchEvent(new CustomEvent("bp-synthetic-event"));
`;
const syntheticInput = {
  bundleSource: syntheticBundle,
  editorCssSource: ".bp-css-class, .bp-reader-future { color: red; }",
  typesSource: syntheticTypes,
  contractSource: syntheticContract,
  elementSources: {
    canvas: ["this._canvasSource = 1; this._sharedMember = 1;"],
    editor: ["this._editorSource = 1;", "this._sharedMember = 1;"],
  },
};

await check("the package extractor is complete, sorted, and does not classify future reader vocabulary", async () => {
  const evidence = await extractPackageSurfaceEvidence(syntheticInput);
  assert.deepEqual(evidence, {
    contract: "9.9.0",
    editor: "0.0.0-test",
    build: "abcdef123456",
    declared: {
      both: { static: ["BUILD_SHA", "CONTRACT_VERSION", "EDITOR_VERSION"] },
      canvas: {
        "DOM attribute": ["data-dom"],
        "ancestor attribute": ["data-ancestor"],
        attribute: ["data-canvas"],
        class: ["bp-public"],
        event: ["bp-canvas-event"],
        "host class": ["bp-host"],
        "inbound event": ["bp-inbound-event"],
        member: ["_declaredCanvas"],
        tag: ["bp-paper-canvas"],
      },
      css: { token: ["--bp-test"] },
      editor: { attribute: ["data-editor"], event: ["bp-editor-event"], member: ["_declaredEditor"], tag: ["bp-paper-editor"] },
      window: { global: ["syntheticGlobal"] },
    },
    host: {
      mermaid: { member: ["render"] },
      picker: { attribute: ["mode"], member: ["open"], tag: ["bp-media-picker"] },
    },
    reachIns: { member: ["_reach"] },
    candidates: {
      members: {
        canvas: ["_canvasMethod", "_canvasMounted", "_canvasOwn", "_canvasSource", "_sharedMember"],
        editor: ["_editorMethod", "_editorMounted", "_editorOwn", "_editorSource", "_sharedMember"],
      },
      classes: ["bp-bundle-class", "bp-css-class", "bp-reader-future", "bp-synthetic-event"],
      attributes: ["data-synthetic-written"],
      events: ["bp-synthetic-event"],
    },
  });
  assert.ok(evidence.candidates.classes.includes("bp-reader-future"));
  assert.equal("reader" in evidence, false);
  assert.equal("internal" in evidence, false);
});

await check("the package extractor fails closed on incomplete text inputs and incomplete bundles", async () => {
  for (const key of ["bundleSource", "editorCssSource", "typesSource", "contractSource"]) {
    for (const value of [undefined, "", 7]) {
      await assert.rejects(() => extractPackageSurfaceEvidence({ ...syntheticInput, [key]: value }), new RegExp(key));
    }
  }
  for (const elementSources of [undefined, {}, { canvas: [], editor: syntheticInput.elementSources.editor }, { canvas: [""], editor: syntheticInput.elementSources.editor }, { canvas: syntheticInput.elementSources.canvas, editor: [] }, { canvas: syntheticInput.elementSources.canvas, editor: [7] }]) {
    await assert.rejects(() => extractPackageSurfaceEvidence({ ...syntheticInput, elementSources }), /elementSources/);
  }
  await assert.rejects(() => extractPackageSurfaceEvidence({ ...syntheticInput, bundleSource: syntheticBundle.replace('"bp-paper-canvas"', '"bp-missing-canvas"') }), /bp-paper-canvas/);
  await assert.rejects(() => extractPackageSurfaceEvidence({ ...syntheticInput, bundleSource: syntheticBundle.replace('static BUILD_SHA = "abcdef123456";', "") }), /BUILD_SHA/);
});

const staticImportSpecifiers = (source) => {
  const specifiers = [];
  for (const [index, line] of source.split("\n").entries()) {
    if (!/\bimport\b/.test(line)) continue;
    const match = line.match(/^\s*import\s+(?:(?:[^"']+?)\s+from\s+)?(["'])([^"']+)\1;\s*$/);
    assert.ok(match, `unsupported or multiline static import at line ${index + 1}`);
    specifiers.push(match[2]);
  }
  return specifiers.sort();
};

await check("the package extractor has only its three approved static dependencies", () => {
  const source = readFileSync(new URL("../scripts/surface-package.mjs", import.meta.url), "utf8");
  const imports = staticImportSpecifiers(source);
  assert.deepEqual(imports, ["../src/contract-surface.mjs", "./writes.mjs", "jsdom"]);
  assert.throws(() => staticImportSpecifiers('import {\n  readFileSync,\n} from "node:fs";'), /unsupported or multiline static import/);
  assert.throws(() => staticImportSpecifiers('import "./unapproved.mjs"'), /unsupported or multiline static import/);
  assert.throws(() => staticImportSpecifiers('const unused = 0; import "./unapproved.mjs";'), /unsupported or multiline static import/);
  assert.throws(() => staticImportSpecifiers('const dependency = import("./unapproved.mjs");'), /unsupported or multiline static import/);
  assert.doesNotMatch(source, /\bimport\s*\(|node:|Barkpark|host-profile|readerClasses|readerAttributes/);
});


if (failures) {
  console.log(`\n${failures} surface check(s) FAILED`);
  process.exit(1);
}
console.log("\nall surface checks PASS");
