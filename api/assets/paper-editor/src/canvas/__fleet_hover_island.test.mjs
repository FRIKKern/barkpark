// Hovering an editable fleet block must never change page layout. The structured
// island used to sit IN FLOW and was shown on mouseenter / hidden on mouseleave:
// leaving the block collapsed it, every block below slid up by its height, and a
// click aimed at the next paragraph's text landed (and was saved) in a block
// further down. Every editable kind now keeps its island in a closed, out-of-flow
// "Configure" disclosure: hover reveals only the absolutely placed toggle.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

// The public paper page loads ONLY the shell stylesheet (BP_PAPER_EDITOR_NO_INJECT),
// so the out-of-flow rules must live there; styles.css mirrors them for bare embedders.
for (const file of ["../styles.css", "../../../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-fleet-config\s*\{[^}]*bottom: 100%;/s,
    `${file}: a closed fleet disclosure sits in the gap above the block, out of flow`);
  assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-fleet-config\[open\]\s*\{[^}]*position: relative;/s,
    `${file}: an OPENED fleet disclosure takes flow space (an explicit click, never a hover)`);
}
const shell = readFileSync(new URL("../../../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
assert.match(shell, /\n\.bp-paper-contextual-controls\s*\{[^}]*position: absolute;[^}]*opacity: 0;/s,
  "the closed disclosure is absolutely placed and hidden by opacity, so revealing it moves nothing");

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
await import("./index.js");

const KINDS = [
  { id: "f-tasks", type: "tasks", snapshot: [{ status: "done", title: "Author the array" }] },
  { id: "f-board", type: "task-board", label: "proj:x" },
  { id: "f-pipe", type: "pipeline", nodes: [{ kind: "author", title: "write" }] },
  { id: "f-chart", type: "chart", series: [] },
];
const para = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });

const host = document.createElement("bp-paper-canvas");
host.blocks = [para("p-lead", "Lead"), ...KINDS.flatMap((b, i) => [b, para(`p-after-${i}`, `After ${b.type}`)])];
document.body.appendChild(host);
let failures = 0;
const check = (name, fn) => { try { fn(); console.log(`ok - ${name}`); } catch (e) { failures++; console.error(`not ok - ${name}\n  ${e.message}`); } };

// Snapshot everything that decides flow for an atom and its island: the island's
// inline display, its parent chain, and every <details> open state.
const flowState = (atom) => {
  const island = atom.querySelector(".bp-fleet-edit");
  const chain = [];
  for (let p = island; p && p !== atom; p = p.parentElement) chain.push(`${p.tagName}.${p.className}|${p.style.display}|${p.tagName === "DETAILS" ? p.open : "-"}`);
  return chain.join(" < ");
};

try {
  for (const kind of KINDS) {
    const atom = host.querySelector(`[data-bp-fleet-id="${kind.id}"]`);
    check(`${kind.type}: the island mounts inside a closed out-of-flow disclosure`, () => {
      assert.ok(atom, "fleet atom mounted");
      const island = atom.querySelector(`[data-test-id="paper-fleet-editor-${kind.type}"]`);
      assert.ok(island, "editable kind builds its island");
      const details = island.closest("details");
      assert.ok(details && atom.contains(details), "island rides a <details> disclosure, not the block's flow");
      assert.ok(details.classList.contains("bp-paper-contextual-controls") && details.classList.contains("bp-paper-fleet-config"),
        "disclosure carries the out-of-flow contextual-controls classes");
      assert.equal(details.open, false, "the disclosure starts closed");
      assert.match(details.querySelector(":scope > summary").textContent, /^Configure /, "a labelled Configure toggle opens it");
      assert.ok(atom.classList.contains("bp-paper-contextual-editor"), "the atom anchors the absolute toggle");
    });
    check(`${kind.type}: pointer enter / leave changes nothing that decides flow`, () => {
      const before = flowState(atom);
      atom.dispatchEvent(new MouseEvent("mouseenter", { bubbles: false }));
      atom.dispatchEvent(new MouseEvent("mouseover", { bubbles: true }));
      const hovered = flowState(atom);
      atom.dispatchEvent(new MouseEvent("mouseleave", { bubbles: false }));
      atom.dispatchEvent(new MouseEvent("mouseout", { bubbles: true }));
      const left = flowState(atom);
      assert.equal(hovered, before, "hover must not reveal an in-flow island");
      assert.equal(left, before, "leaving must not collapse anything");
    });
  }
} finally {
  host.remove();
}

if (failures) { console.error(`${failures} fleet hover island check(s) failed`); process.exit(1); }
console.log("fleet hover island: ok");
