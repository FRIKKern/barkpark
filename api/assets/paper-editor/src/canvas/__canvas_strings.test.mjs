// __canvas_strings.test.mjs — task-addade22d350314a, in a real mounted canvas: the
// canvas's own words (block handle, block menu, format toolbar, field label,
// slash menu) read the `data-strings` map the server stamps on the run host,
// keyed by the English text. A translation is text, never markup. A canvas with
// no stamped map reads the English unchanged, and the slash filter finds a block
// by its shown name as well as its English one.
// Run: node src/canvas/__canvas_strings.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const NB = {
  "Add a block below": "Legg til en blokk under",
  "Block options": "Blokkvalg",
  // A translation that carries markup must land as text.
  Duplicate: "<b>Dupliser</b>",
  Bold: "Fet",
  "Field label": "Feltnavn",
  "Insert block": "Sett inn blokk",
  Text: "Tekst",
  Paragraph: "Avsnitt",
  Heading: "Overskrift",
  Number: "Tall",
  "numeric value": "tallverdi",
  "Paper text": "Artikkeltekst",
};
const BLOCKS = [
  { id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] },
  { id: "f-str", type: "field-string", label: "Title", value: "" },
];

let ran = 0;
let failures = 0;
function check(name, fn) {
  ran += 1;
  try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); }
}

async function mount(strings) {
  const host = document.createElement("div");
  if (strings) host.setAttribute("data-strings", JSON.stringify(strings));
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  host.appendChild(canvas);
  document.body.appendChild(host);
  await tick(350);
  return canvas;
}

// The format toolbar builds its DOM on first show; build it to read its names.
const boldOf = (canvas) => {
  if (!canvas._bubble._el) canvas._bubble._build();
  return canvas._bubble._el.querySelector(".bp-paper-format__btn--bold");
};

function slashTexts(canvas, query = "") {
  canvas._openSlash(query);
  const menu = canvas._slash._el;
  const out = {
    eyebrow: menu.querySelector(".bp-slash-eyebrow").textContent,
    groups: [...menu.querySelectorAll(".bp-slash-group")].map((g) => g.textContent),
    labels: [...menu.querySelectorAll(".bp-slash-label")].map((l) => l.textContent),
  };
  canvas._closeSlash();
  return out;
}

try {
  // ── a Norwegian Studio: the run host carries the stamped map ───────────────
  const nb = await mount(NB);

  check("the block handle names its buttons in the stamped words", () => {
    const add = nb.querySelector(".bp-block-handle__add");
    const grip = nb.querySelector(".bp-block-handle__grip");
    assert.equal(add.getAttribute("aria-label"), "Legg til en blokk under");
    assert.equal(grip.getAttribute("aria-label"), "Blokkvalg");
  });

  check("the block menu reads the stamped words, and a translation stays text", () => {
    nb._handle._index = 0;
    nb._handle._openMenu();
    const menu = document.querySelector(".bp-block-menu");
    assert.equal(menu.getAttribute("aria-label"), "Blokkvalg");
    const dup = menu.querySelector('[data-action="duplicate"]');
    assert.match(dup.textContent, /<b>Dupliser<\/b>/);
    assert.equal(dup.querySelector("b"), null, "no markup was injected");
    nb._handle._closeMenu();
  });

  check("the format toolbar names Bold in the stamped word", () => {
    assert.equal(boldOf(nb).getAttribute("aria-label"), "Fet");
  });

  check("a field block's editable label is named in the stamped word", () => {
    const label = nb.querySelector(".bp-canvas-field-label");
    assert.equal(label.getAttribute("aria-label"), "Feltnavn");
  });

  check("the slash menu reads its eyebrow, groups and labels in the stamped words", () => {
    const s = slashTexts(nb);
    assert.equal(s.eyebrow, "Sett inn blokk");
    assert.ok(s.groups.includes("Tekst"), s.groups.join(","));
    assert.ok(s.labels.includes("Avsnitt"), s.labels.slice(0, 5).join(","));
  });

  // task-3dbe834e19630e74: ProseMirror's editable root is role=textbox; with no
  // name a screen reader lands in an unnamed "edit text" (axe
  // aria-input-field-name).
  check("the editable root is a named, multiline textbox in the stamped word", () => {
    const root = nb.querySelector(".ProseMirror");
    assert.equal(root.getAttribute("aria-label"), "Artikkeltekst");
    assert.equal(root.getAttribute("aria-multiline"), "true");
  });

  // task-347897df84f96882: the number field's row read English, the Visual
  // group split in two around the canvas-only Sheet row, and a no-match query
  // left a listbox with no option.
  check("the slash menu: Number reads in the stamped word, every group heads once", () => {
    const s = slashTexts(nb);
    assert.ok(s.labels.includes("Tall"), s.labels.join(","));
    assert.ok(!s.labels.includes("Number"));
    assert.deepEqual(s.groups, [...new Set(s.groups)], `a group heading repeats: ${s.groups.join(",")}`);
  });

  check("a slash query that matches nothing still offers one disabled option", () => {
    nb._openSlash("zzzz-no-such-block");
    const menu = nb._slash._el;
    const opts = [...menu.querySelectorAll("[role='option']")];
    assert.equal(opts.length, 1);
    assert.equal(opts[0].getAttribute("aria-disabled"), "true");
    nb._closeSlash();
  });

  check("the slash filter finds a block by its shown name", () => {
    const s = slashTexts(nb, "avsnitt");
    assert.equal(s.labels[0], "Avsnitt");
  });

  // ── no stamped map: English, unchanged ─────────────────────────────────────
  const en = await mount(null);

  check("with no stamped map the canvas reads English", () => {
    assert.equal(en.querySelector(".bp-block-handle__add").getAttribute("aria-label"), "Add a block below");
    assert.equal(en.querySelector(".bp-canvas-field-label").getAttribute("aria-label"), "Field label");
    assert.equal(boldOf(en).getAttribute("aria-label"), "Bold");
    assert.equal(en.querySelector(".ProseMirror").getAttribute("aria-label"), "Paper text");
    const s = slashTexts(en);
    assert.equal(s.eyebrow, "Insert block");
    assert.ok(s.labels.includes("Paragraph"));
  });
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.message}`);
} finally {
  if (ran !== 10) {
    failures += 1;
    console.log(`FAIL  ran ${ran} of 10 checks`);
  }
  if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
  console.log("\ncanvas strings: all checks passed");
  process.exit(0);
}
