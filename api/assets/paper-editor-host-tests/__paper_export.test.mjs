// __paper_export.test.mjs — task-a5ba0a62b64635ac: a paper left the Studio only
// as JSON. bp-paper-export.js draws the header's Export menu: Download
// Markdown, Copy as Markdown, Print / Save as PDF.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-paper-export.js under
// jsdom. The canvases are stand-ins that answer the contract's toMarkdown()
// (EMBED-CONTRACT.md, "Markdown export") with the editor's real converter and
// record each call, so the file's text is what a writer would get.
//
// Run: node ../paper-editor-host-tests/__paper_export.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";
import { blocksToExportMarkdown } from "../paper-editor/src/markdown.js";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/w/a/p/b/studio" });
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-paper-export.js");
const { document } = window;

const NB = {
  "Export": "Eksporter", "Download Markdown": "Last ned Markdown", "Copy as Markdown": "Kopier som Markdown", "Copied": "Kopiert",
  "Print / Save as PDF": "Skriv ut / lagre som PDF", "%{block}: not included in Markdown export": "%{block}: ikke med i Markdown-eksporten",
};

// What the page did with the file, the clipboard and the print page.
const files = [];
const copies = [];
const opened = [];
const blobs = new Map();
window.URL.createObjectURL = (blob) => { const url = `blob:paper-${blobs.size}`; blobs.set(url, blob); return url; };
window.URL.revokeObjectURL = () => {};
// A download link's click is a real click on the page, outside the menu.
window.HTMLAnchorElement.prototype.click = function () {
  if (this.download) files.push({ name: this.download, blob: blobs.get(this.getAttribute("href")) });
  this.dispatchEvent(new window.Event("click", { bubbles: true }));
};
Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: { writeText: (text) => { copies.push(text); return Promise.resolve(); } } });
window.open = (href, target) => { opened.push([href, target]); return null; };
const read = (blob) => new Promise((resolve) => { const reader = new window.FileReader(); reader.onload = () => resolve(reader.result); reader.readAsText(blob); });
const wait = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const p = (id, text) => ({ id, type: "paragraph", content: [{ type: "text", value: text }] });

// A run of prose: the wrapper the Studio renders, holding a canvas that
// converts its own blocks, or the blocks it is handed.
function run(blocks, { editable = true } = {}) {
  const wrap = document.createElement("div");
  wrap.className = "bp-paper-edit-canvas";
  wrap.setAttribute("data-canvas-blocks", JSON.stringify(blocks));
  const el = document.createElement("bp-paper-canvas");
  if (!editable) el.setAttribute("editable", "false");
  el.calls = [];
  el.toMarkdown = (options = {}) => {
    el.calls.push(["toMarkdown", options]);
    return blocksToExportMarkdown(options.blocks || blocks, options);
  };
  wrap.appendChild(el);
  return wrap;
}

// A block between runs: its own editor, which may hold a canvas of its own.
function between(block, inner) {
  const el = document.createElement("div");
  el.className = "bp-paper-edit-block";
  if (block.id) el.setAttribute("data-edit-block-id", block.id);
  el.setAttribute("data-block-type", block.type);
  if (inner) el.appendChild(inner);
  return el;
}

function mount(children, { kept = [], title = "Field notes", print = "/papers/field-notes", state = "published", strings } = {}) {
  window.BarkparkPaperExport.close();
  document.body.innerHTML =
    '<div id="paper-export-x" class="bp-paper-export" data-paper-export data-paper-export-editor="paper-editor-x" data-paper-export-file="field-notes">' +
    '<button type="button" aria-haspopup="menu" aria-expanded="false" data-paper-export-toggle>Export</button></div>' +
    '<div id="paper-editor-x" class="bp-paper-editor"></div>';
  const source = document.getElementById("paper-export-x");
  source.setAttribute("data-paper-export-title", title);
  source.setAttribute("data-paper-export-blocks", JSON.stringify(kept));
  source.setAttribute("data-paper-export-print-state", state);
  if (print) source.setAttribute("data-paper-export-print", print);
  const root = document.getElementById("paper-editor-x");
  if (strings) root.setAttribute("data-paper-strings", JSON.stringify(strings));
  children.forEach((child) => root.appendChild(child));
  files.length = copies.length = opened.length = 0;
  return { source, root, button: source.querySelector("button") };
}

const menu = () => document.querySelector('[data-test-id="paper-export-menu"]');
const item = (action) => menu().querySelector(`[data-export="${action}"]`);
const noteOf = (kind) => menu().querySelector(`[data-export-note="${kind}"]`);
const key = (target, init) => {
  const event = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(event);
  return event;
};

const table = { id: "t1", type: "table", head: [[{ type: "text", value: "Surface" }], [{ type: "text", value: "Renderer" }]], rows: [[[{ type: "text", value: "Phoenix" }], [{ type: "text", value: "Elixir" }]]] };
const steps = { id: "s1", type: "steps", steps: [{ title: "Claim", blocks: [p("s1a", "Inside a step.")] }] };

try {
  // A paper of two runs with a table and steps between them: one file, in order.
  {
    const first = run([{ id: "h", type: "heading", level: 2, text: "Why" }, p("a", "The first run.")]);
    const last = run([p("z", "The second run.")]);
    const nested = run([p("s1a", "Inside a step.")]);
    const { button } = mount([first, between(table), between(steps, nested), last], { kept: [table, steps] });

    // The button is a menu button; the keyboard's click lands in the menu.
    assert.equal(button.getAttribute("aria-haspopup"), "menu");
    button.focus();
    button.click();
    assert.ok(menu(), "the menu opened");
    assert.equal(menu().getAttribute("role"), "menu");
    assert.equal(button.getAttribute("aria-expanded"), "true");
    assert.deepEqual([...menu().querySelectorAll("[role=menuitem]")].map((el) => el.textContent), ["Download Markdown", "Copy as Markdown", "Print / Save as PDF"]);
    assert.equal(document.activeElement, item("download"), "the first item has the focus");
    key(document.activeElement, { key: "ArrowDown" });
    assert.equal(document.activeElement, item("copy"));
    key(document.activeElement, { key: "ArrowUp" });
    key(document.activeElement, { key: "ArrowUp" });
    assert.equal(document.activeElement, item("print"), "the arrows wrap");
    assert.match(noteOf("markdown").textContent, /text first/, "the menu says the export is text first");

    item("download").click();
    assert.equal(files.length, 1, "one file");
    assert.equal(files[0].name, "field-notes.md");
    const text = await read(files[0].blob);
    assert.equal(
      text,
      "# Field notes\n\n## Why\n\nThe first run.\n\n" +
        "| Surface | Renderer |\n| --- | --- |\n| Phoenix | Elixir |\n\n" +
        "1. **Claim**\n\n   Inside a step.\n\n" +
        "The second run.\n",
    );
    assert.equal(menu(), null, "the menu closed");
    assert.equal(button.getAttribute("aria-expanded"), "false");
    assert.equal(document.activeElement, button, "the focus is back on the button");
    // The canvas inside the steps block was not asked: its block already holds that text.
    assert.equal(nested.firstChild.calls.length, 0);
    assert.equal(text.split("Inside a step.").length, 2, "the step's text is there once");
  }

  // Copy puts the same text on the clipboard, once, and says so.
  {
    const { button } = mount([run([p("a", "One.")]), between(table), run([p("b", "Two.")])], { kept: [table] });
    button.click();
    item("copy").click();
    await wait();
    assert.equal(copies.length, 1, "one clipboard write");
    assert.equal(copies[0], "# Field notes\n\nOne.\n\n| Surface | Renderer |\n| --- | --- |\n| Phoenix | Elixir |\n\nTwo.\n");
    assert.equal(item("copy").textContent, "Copied");
    assert.equal(noteOf("status").getAttribute("aria-live"), "polite");
    assert.equal(noteOf("status").textContent, "Copied");
    assert.ok(menu(), "the menu stays open to show it");

    // Esc closes it and gives the focus back.
    const esc = key(item("copy"), { key: "Escape" });
    assert.equal(esc.defaultPrevented, true);
    assert.equal(menu(), null);
    assert.equal(document.activeElement, button);
  }

  // A viewer who cannot edit exports the same way, and nothing but toMarkdown is called.
  {
    const only = run([p("a", "Read only.")], { editable: false });
    const { button } = mount([only], { title: "Locked" });
    button.click();
    item("download").click();
    assert.equal(await read(files[0].blob), "# Locked\n\nRead only.\n");
    assert.deepEqual([...new Set(only.firstChild.calls.map(([name]) => name))], ["toMarkdown"]);
  }

  // A paper that opens with its own H1 gets no second title; a block between
  // runs that the button does not carry leaves a line naming it.
  {
    const { source } = mount([run([{ id: "h", type: "heading", level: 1, text: "Own title" }]), between({ id: "q", type: "questionnaire" })]);
    assert.equal(window.BarkparkPaperExport.markdown(source), "# Own title\n\n> [Questionnaire: not included in Markdown export]\n");
  }

  // A draft with a published version: Print opens the reader page, and the menu says which version.
  {
    const { button } = mount([run([p("a", "Draft.")])], { state: "draft" });
    button.click();
    assert.match(noteOf("print").textContent, /published version/);
    item("print").click();
    assert.deepEqual(opened, [["/papers/field-notes", "_blank"]]);
    assert.equal(menu(), null);
  }

  // A paper that was never published has no page to print: the item is off and says why.
  {
    const { button } = mount([run([p("a", "New.")])], { state: "draft", print: null });
    button.click();
    assert.equal(item("print").getAttribute("aria-disabled"), "true");
    assert.match(noteOf("print").textContent, /Publish this paper/);
    item("print").click();
    assert.deepEqual(opened, []);
    assert.ok(menu(), "the menu stays open");
    // A click outside closes it.
    document.body.click();
    assert.equal(menu(), null);
  }

  // The words come from the Studio's string map, the placeholder line too.
  {
    const { button, source } = mount([run([p("a", "Tekst.")]), between({ id: "c", type: "chart" })], { strings: NB });
    button.click();
    assert.equal(menu().getAttribute("aria-label"), "Eksporter");
    assert.equal(item("download").textContent, "Last ned Markdown");
    assert.equal(window.BarkparkPaperExport.markdown(source), "# Field notes\n\nTekst.\n\n> [Chart: ikke med i Markdown-eksporten]\n");
    item("copy").click();
    await wait();
    assert.equal(item("copy").textContent, "Kopiert");
  }

  // Before the editor bundle has upgraded any canvas the menu says so, and writes no file.
  {
    const raw = document.createElement("div");
    raw.className = "bp-paper-edit-canvas";
    raw.appendChild(document.createElement("bp-paper-canvas"));
    const { button } = mount([raw]);
    button.click();
    item("download").click();
    assert.equal(files.length, 0);
    assert.match(noteOf("error").textContent, /still loading/);
  }

  window.BarkparkPaperExport.close();
  console.log("paper export: all passed");
} catch (error) {
  console.error(error);
  process.exitCode = 1;
}
