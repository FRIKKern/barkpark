import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

// task-bbfdcf4c80b8300d long tail: a file tree's lines and legend edit where the
// reader paints them. Before this, the tree was a read-only server paint whose
// text was editable only in the "Edit file tree" disclosure, and at top level the
// canvas atom clipped the reader's evidence pull (the census read OCCLUDED).
for (const file of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.match(css, /\n\.bp-canvas-technical \{ overflow-x: visible; \}/,
    `${file}: the technical atom never clips the reader's evidence pull`);
}

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("../index.js");

const TEXT = "internal/\n├── diff.go ● created — renderer\n└── pdrender.go ○ injected\n";
// The reader's bytes (components.ex filetree_html/1), lines verbatim, annotation in a span.
const row = (path, note = "") => `<div style="white-space: pre;">${path}${note ? `<span class="bp-filetree-note" style="color: var(--ok);">${note}</span>` : ""}</div>`;
const tree = (rows, legend = "● created") =>
  `<div class="bp-filetree text-xs">${rows.join("")}${legend ? `<div class="bp-filetree-legend text-dim">${legend}</div>` : ""}</div>`;
const html = tree([row("internal/"), row("├── diff.go", " ● created — renderer"), row("└── pdrender.go", " ○ injected")]);

function paint(host, markup = html) {
  const hole = host.querySelector("[data-bp-fleet-body]");
  const event = new CustomEvent("bp-fleet-paint", { detail: { html: markup, sourceBlock: host.blocks[0] }, cancelable: true });
  if (hole.dispatchEvent(event)) hole.innerHTML = markup;
}
function mount(attrs = {}) {
  const block = { id: "ft", type: "filetree", text: TEXT, legend: "● created", ...attrs };
  const host = document.createElement("bp-paper-canvas");
  host.blocks = [block];
  const batches = [];
  host.addEventListener("bp-canvas-ops", e => batches.push(e.detail));
  document.body.appendChild(host);
  paint(host);
  return { host, block, batches };
}
function input(el, text) { el.textContent = text; el.dispatchEvent(new Event("input", { bubbles: true })); }
const lines = host => [...host.querySelectorAll('[aria-label^="File tree line"]')];

try {
  const { host, block, batches } = mount();
  try {
    const rows = lines(host);
    assert.equal(rows.length, 3, "every stored line edits where it reads");
    assert.equal(rows[1].textContent, "├── diff.go ● created — renderer", "a line host carries its annotation verbatim");
    assert.equal(rows[1].contentEditable, "plaintext-only");
    assert.ok(rows[1].querySelector("span"), "decoration keeps the reader's annotation span");
    const legend = host.querySelector('[aria-label="File tree legend"]');
    assert.ok(legend, "the legend edits where it reads");

    rows[0].focus(); rows[0].blur(); host.flushPendingChanges();
    assert.deepEqual(batches, [], "focus/blur is not an authored change");

    rows[2].focus(); input(rows[2], "└── pdrender.go ○ injected twice");
    host.flushPendingChanges();
    rows[2].blur();
    assert.equal(host._editor.state.doc.firstChild.attrs.text,
      "internal/\n├── diff.go ● created — renderer\n└── pdrender.go ○ injected twice\n",
      "only that line of the stored text changes; indentation, glyphs and the trailing newline stay");
    assert.deepEqual(batches.at(-1).ops.at(-1).patch,
      { text: "internal/\n├── diff.go ● created — renderer\n└── pdrender.go ○ injected twice\n" },
      "the patch carries the edited text only; the unchanged legend does not ride");

    legend.focus(); input(legend, "● created · ○ injected");
    host.flushPendingChanges();
    legend.blur();
    assert.equal(host._editor.state.doc.firstChild.attrs.legend, "● created · ○ injected");
    assert.equal(block.text, TEXT, "the source block is never mutated in place");
  } finally { host.remove(); }

  const mismatch = mount();
  try {
    paint(mismatch.host, tree([row("internal/"), row("├── other.go")]));
    assert.equal(lines(mismatch.host).length, 0, "a paint that does not match the stored lines 1:1 never maps onto them");
    assert.ok(mismatch.host.querySelector('[aria-label="File tree legend"]'), "the legend is still its own field");
  } finally { mismatch.host.remove(); }
  console.log("filetree inline: lines and legend edit in place, verbatim, one line patched; mismatched paints refused");
} finally { window.close(); }
