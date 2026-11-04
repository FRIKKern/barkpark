// __surface.test.mjs — portable surface readers accept every supported source form.
//
// The committed-build, shell, and host-profile checks live in the sibling host
// surface.test.mjs. This package check keeps every pure parser and schema fixture.
//
// Run: node src/__surface.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { bundleEvents, elementClassBody, mountedMembers, notClasses, sourceMembers, stylesheetClasses } from "../scripts/surface.mjs";
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


if (failures) {
  console.log(`\n${failures} surface check(s) FAILED`);
  process.exit(1);
}
console.log("\nall surface checks PASS");
