// Mounted canvas test for PAPER MASTERS, editor half (task-3b6e562e916c8ce4).
//
// Mounts the real <bp-paper-canvas> inside a `.bp-paper-editor` that carries the
// `[data-paper-masters]` carrier (what the Studio paper pane renders when it may
// write) and drives both author actions through the real editor:
//
//   * SLASH PICK — typing "/pri" on a new line opens the slash menu with a
//     "Masters" group row for the carrier's master; choosing it removes the
//     "/query" paragraph, flushes that removal as a bp-canvas-ops batch FIRST,
//     then dispatches bp-master-insert {master_id, after_id} anchored on the
//     confirmed block above the slash line (the hook forwards it as
//     `paper-insert-master`, which the server turns into a detached copy);
//   * SAVE — the block menu offers "Save as master" on a confirmed block and
//     dispatches bp-save-master {block_id}; a just-typed block the server has
//     never seen is not offered;
//   * NO CARRIER — outside a masters-enabled editor there is no Masters group
//     and no Save item (the public reader, a field canvas).
//
// Mutation-checked: dropping the `item.master` branch in _chooseSlash, the
// masters readExtraItems, or the block-menu item reds this file.

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.HTMLElement.prototype.scrollIntoView ||= function scrollIntoView() {};
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");
const { masterInsertAnchor } = await import("./slash-insert.js");
const { readMasterItems } = await import("../slash-menu.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const MASTERS = [{ id: "m-1", title: "Pricing block", tier: "section", block_type: "section" }];
const BLOCKS = [
  { id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] },
  { id: "p-b", type: "paragraph", content: [{ type: "text", value: "Beta" }] },
];

async function mount({ carrier }) {
  const editorRoot = document.createElement("div");
  editorRoot.className = "bp-paper-editor";
  if (carrier) {
    const el = document.createElement("div");
    el.setAttribute("data-paper-masters", JSON.stringify(MASTERS));
    el.hidden = true;
    editorRoot.appendChild(el);
  }
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  editorRoot.appendChild(canvas);
  document.body.appendChild(editorRoot);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  return { canvas, editorRoot };
}

// Put the caret at the end of the first block, split a new line and type "/pri".
function typeSlashAfterFirst(editor) {
  const first = editor.state.doc.child(0);
  editor.chain().focus().setTextSelection(first.nodeSize - 1).splitBlock().insertContent("/pri").run();
}

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${error.message}`);
  }
}

try {
  // ── pure helpers ──────────────────────────────────────────────────────────
  check("masterInsertAnchor prefers the nearest confirmed block above the slash line", () => {
    const confirmed = new Set(["a", "b", "c"]);
    assert.equal(masterInsertAnchor(["a", "b", null, "c"], 2, confirmed), "b");
    assert.equal(masterInsertAnchor(["a", "new", null], 2, confirmed), "a", "skips unconfirmed ids");
    assert.equal(masterInsertAnchor([null, "c"], 0, confirmed), "c", "falls back to below");
    assert.equal(masterInsertAnchor([null], 0, confirmed), null);
    assert.equal(masterInsertAnchor(["b", "c"], 1, confirmed), "b", "never the slash line itself");
  });

  check("readMasterItems maps the carrier to Masters rows, [] without one", () => {
    const root = document.createElement("div");
    assert.deepEqual(readMasterItems(root), []);
    const el = document.createElement("div");
    el.setAttribute("data-paper-masters", JSON.stringify(MASTERS));
    root.appendChild(el);
    const [row] = readMasterItems(root);
    assert.equal(row.group, "Masters");
    assert.equal(row.master, "m-1");
    assert.equal(row.label, "Pricing block");
  });

  // ── SLASH PICK ────────────────────────────────────────────────────────────
  {
    const { canvas } = await mount({ carrier: true });
    const editor = canvas._editor;
    const events = [];
    canvas.addEventListener("bp-canvas-ops", (e) => events.push(["ops", e.detail.ops]));
    canvas.addEventListener("bp-master-insert", (e) => events.push(["master", e.detail]));

    typeSlashAfterFirst(editor);
    const menu = canvas._slash;
    const row = menu && menu.isOpen() ? menu._items.find((it) => it.master === "m-1") : null;

    check("typing /pri opens the slash menu with the master in a Masters group", () => {
      assert.ok(menu && menu.isOpen(), "the slash menu is open");
      assert.ok(row, "the carrier's master is a row");
      assert.equal(row.group, "Masters");
    });

    if (row) canvas._chooseSlash(row);

    const masterEvents = events.filter(([kind]) => kind === "master");
    check("choosing it dispatches bp-master-insert anchored after the block above", () => {
      assert.equal(masterEvents.length, 1, "exactly one insert request");
      assert.deepEqual(masterEvents[0][1], { master_id: "m-1", after_id: "p-a" });
    });

    check("the /query line is gone and its removal is flushed BEFORE the insert", () => {
      const ids = [];
      editor.state.doc.forEach((node) => ids.push(node.attrs.bpId));
      assert.deepEqual(ids, ["p-a", "p-b"], "no stray /pri paragraph remains");
      const text = editor.state.doc.textContent;
      assert.ok(!text.includes("/pri"), "the slash query text is gone");
      const masterAt = events.findIndex(([kind]) => kind === "master");
      const opsAt = events.findIndex(([kind]) => kind === "ops");
      // The new line was never confirmed; if any batch was emitted it must precede
      // the insert so the hook queues it first.
      if (opsAt !== -1) assert.ok(opsAt < masterAt, "ops batch precedes the insert");
    });

    check("the editor is blurred so the server echo renders at once", () => {
      assert.equal(editor.isFocused, false);
    });
  }

  // ── SAVE from the block menu ──────────────────────────────────────────────
  {
    const { canvas } = await mount({ carrier: true });
    const saves = [];
    canvas.addEventListener("bp-save-master", (e) => saves.push(e.detail));
    const handle = canvas._handle;
    handle._index = 1;
    handle._openMenu();
    const item = handle._menu && handle._menu.querySelector('[data-action="save-master"]');

    check("the block menu offers Save as master on a confirmed block", () => {
      assert.ok(item, "Save as master item present");
      assert.match(item.textContent, /Save as master/);
    });

    if (item) item.click();
    check("Save as master dispatches bp-save-master with the block id", () => {
      assert.deepEqual(saves, [{ block_id: "p-b" }]);
    });

    // A just-inserted (never confirmed) block is not offered. Built with a null
    // id — the new-block signal the canvas mints an id for on emit.
    const editor = canvas._editor;
    editor.commands.insertContentAt(editor.state.doc.content.size, {
      type: "paragraph",
      content: [{ type: "text", text: "fresh" }],
    });
    handle._index = editor.state.doc.childCount - 1;
    const freshId = editor.state.doc.child(handle._index).attrs.bpId;
    handle._openMenu();
    check("an unconfirmed block gets no Save as master", () => {
      assert.ok(!["p-a", "p-b"].includes(freshId), `the new block is not a confirmed one (${freshId})`);
      assert.equal(handle._menu.querySelector('[data-action="save-master"]'), null);
    });
    handle._closeMenu();
  }

  // ── NO CARRIER ────────────────────────────────────────────────────────────
  {
    const { canvas } = await mount({ carrier: false });
    typeSlashAfterFirst(canvas._editor);
    check("without the carrier there is no Masters group", () => {
      assert.ok(canvas._slash && canvas._slash.isOpen(), "slash menu open");
      assert.equal(canvas._slash._allItems.filter((it) => it.master).length, 0);
    });
    canvas._closeSlash();
    const handle = canvas._handle;
    handle._index = 0;
    handle._openMenu();
    check("without the carrier the block menu has no Save as master", () => {
      assert.equal(handle._menu.querySelector('[data-action="save-master"]'), null);
    });
    handle._closeMenu();
  }
} catch (error) {
  failures += 1;
  console.log(`FAIL  unexpected error: ${error.stack || error.message}`);
}

if (failures) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
console.log("\nall masters mounted checks passed");
process.exit(0);
