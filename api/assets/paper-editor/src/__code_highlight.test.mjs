// __code_highlight.test.mjs — one tokenizer for the canvas and the reader (Barkdown plan #27).
// Pure-Node for the module; jsdom for the reader pass. A JavaScript and an Elixir snippet get hljs-*
// tokens; an unknown or empty lang gives escaped text; text content always round-trips byte-exact;
// the reader pass paints the same signature into a server-shaped <pre data-lang> and keeps an
// emphasis span; it marks a block once and leaves lang-less blocks alone.
// Run: node src/__code_highlight.test.mjs   (or: npm test)
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { highlightHtml, highlightPre, tokenSignature, resolveLang, languages, escapeHtml } from "./code-highlight.js";

let failures = 0;
function check(name, fn) { try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures++; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

const JS = 'const total = items.reduce((n, x) => n + x.price, 0); // sum\nif (total > 10) console.log("big");';
const EX = 'defmodule Demo do\n  @moduledoc "a demo"\n  def add(a, b), do: a + b\nend';
const dom = new JSDOM("<!doctype html><html><body></body></html>");
const { document } = dom.window;
const textOf = (html) => { const d = document.createElement("div"); d.innerHTML = html; return d.textContent; };

check("resolveLang: aliases land on registered grammars; unknown and empty give null", () => {
  assert.equal(resolveLang("js"), "javascript");
  assert.equal(resolveLang("ex"), "elixir");
  assert.equal(resolveLang("sh"), "bash");
  assert.equal(resolveLang("html"), "xml");
  assert.equal(resolveLang("Elixir "), "elixir");
  assert.equal(resolveLang("klingon"), null);
  assert.equal(resolveLang(""), null);
  assert.ok(languages().includes("elixir") && languages().includes("javascript"));
});

check("JavaScript and Elixir get hljs tokens; the text round-trips byte-exact", () => {
  const js = highlightHtml(JS, "js");
  assert.ok(js.includes('class="hljs-keyword"'), js);
  assert.ok(js.includes('class="hljs-comment"'), js);
  assert.ok(js.includes('class="hljs-string"'), js);
  assert.equal(textOf(js), JS);
  const ex = highlightHtml(EX, "elixir");
  assert.ok(ex.includes('class="hljs-keyword"'), ex);
  assert.ok(ex.includes("hljs-class") || ex.includes("hljs-title"), ex);
  assert.equal(textOf(ex), EX);
});

check("an unknown or empty lang gives escaped text and nothing else", () => {
  const src = 'a < b && c > "d"';
  assert.equal(highlightHtml(src, "klingon"), escapeHtml(src));
  assert.equal(highlightHtml(src, ""), escapeHtml(src));
  assert.equal(textOf(highlightHtml(src, "")), src);
});

check("the reader pass paints the same signature into a server-shaped <pre data-lang>", () => {
  const pre = document.createElement("pre");
  pre.setAttribute("data-lang", "js");
  pre.textContent = JS;
  assert.equal(highlightPre(pre), true);
  assert.equal(pre.getAttribute("data-hl"), "1");
  assert.equal(pre.textContent, JS, "text unchanged");
  const readerSig = tokenSignature(pre.innerHTML, document);
  const canvasSig = tokenSignature(`<span class="hljs">${highlightHtml(JS, "js")}</span>`, document);
  assert.deepEqual(readerSig, canvasSig);
  assert.ok(readerSig.some(([cls]) => /hljs-keyword/.test(cls)));
});

check("emphasis spans survive: tokens are painted inside each line span", () => {
  const pre = document.createElement("pre");
  pre.setAttribute("data-lang", "elixir");
  pre.innerHTML = `${escapeHtml("defmodule Demo do")}\n<span class="bp-code-em bp-code-em--warn">${escapeHtml('  def add(a, b), do: a + b')}</span>\n${escapeHtml("end")}`;
  const before = pre.textContent;
  highlightPre(pre);
  assert.equal(pre.textContent, before);
  const em = pre.querySelector(".bp-code-em--warn");
  assert.ok(em, "the emphasis span is still there");
  assert.ok(em.querySelector(".hljs-keyword"), "tokens inside the emphasised line");
});

check("a block is painted once; a lang-less block is left alone", () => {
  const pre = document.createElement("pre");
  pre.setAttribute("data-lang", "json");
  pre.textContent = '{"a": 1}';
  assert.equal(highlightPre(pre), true);
  assert.equal(highlightPre(pre), false, "second call is a no-op");
  const plain = document.createElement("pre");
  plain.textContent = "x = 1";
  assert.equal(highlightPre(plain), false);
  assert.equal(plain.innerHTML, "x = 1");
});

if (failures) { console.log(`\n${failures} failing`); process.exit(1); }
console.log("\nOK");
