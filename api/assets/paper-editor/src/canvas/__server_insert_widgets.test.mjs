// Mounted regression: a canvas pick of Terminal or Stage is inserted by the SERVER.
//
// Found dogfooding the Studio paper canvas (task-f3c8acd1e09a0eda, owner ruling
// #56, 2026-10-03). The canvas used to insert a bpTerminal / bpStage node itself.
// Its save batch (an insert-after carrying a terminal or stage block) is refused by
// the server's canvas fence (Blocks.canvas_run_context/2 → outdated_terminal_canvas
// / outdated_stage_canvas), so the block and anything typed in it were never stored
// and the author saw a false "changed elsewhere" banner. "+ Add block" worked
// because the server built the block.
//
// When the host builds blocks (Barkpark's LiveView marks its editor
// `data-server-insert`), the canvas hands these types to the server like "+ Add block":
//
//   * SLASH PICK — "/terminal" on a new line, choose Terminal: the "/query" line is
//     removed (and that removal flushed first), no terminal node is inserted locally,
//     and bp-server-insert {type, after_id} is dispatched, anchored on the confirmed
//     block above (the hook forwards it as `paper-slash-insert`).
//   * PALETTE — "Insert Stage" from the command palette takes the same route,
//     anchored on the confirmed block the caret sits in, without removing it.
//   * The other insertable types still insert locally (a heading pick is a node).
//
// Mutation-checked: removing the CANVAS_SERVER_INSERT_TYPES branch in _chooseSlash
// or the palette's onServerInsert option reds this file.

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
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

await import("./index.js");
const { CANVAS_SLASH_TYPES, CANVAS_SERVER_INSERT_TYPES } = await import("./slash-insert.js");

const tick = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));

const BLOCKS = [
  { id: "p-a", type: "paragraph", content: [{ type: "text", value: "Alpha" }] },
  { id: "p-b", type: "paragraph", content: [{ type: "text", value: "Beta" }] },
];

async function mount({ hostBuilds = false } = {}) {
  const editorRoot = document.createElement("div");
  editorRoot.className = "bp-paper-editor";
  // Barkpark's LiveView hook marks its editor; a plain embedder does not.
  if (hostBuilds) editorRoot.setAttribute("data-server-insert", "");
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(BLOCKS));
  editorRoot.appendChild(canvas);
  document.body.appendChild(editorRoot);
  await tick(350);
  assert.ok(canvas._editor?.view?.dom?.isConnected, "the real TipTap canvas editor is mounted");
  return canvas;
}

function typeSlashAfterFirst(editor, query) {
  const first = editor.state.doc.child(0);
  editor.chain().focus().setTextSelection(first.nodeSize - 1).splitBlock().insertContent(query).run();
}

function nodeTypes(editor) {
  const types = [];
  editor.state.doc.forEach((node) => types.push(node.type.name));
  return types;
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
  check("Terminal, Stage, Image and Equation stay in the menu and are the server-insert types", () => {
    assert.ok(CANVAS_SERVER_INSERT_TYPES instanceof Set, "CANVAS_SERVER_INSERT_TYPES is exported");
    assert.deepEqual([...CANVAS_SERVER_INSERT_TYPES].sort(), ["equation", "image", "stage", "terminal"]);
    for (const type of CANVAS_SERVER_INSERT_TYPES) {
      assert.ok(CANVAS_SLASH_TYPES.has(type), `${type} is still offered`);
    }
  });

  // image + equation: task-f92354b415b486f5 (they re-rendered as boundary
  // editors and dropped what was typed into the transient canvas node).
  for (const type of ["terminal", "stage", "image", "equation"]) {
    // Only a host that builds blocks (data-server-insert) is asked.
    const canvas = await mount({ hostBuilds: true });
    const editor = canvas._editor;
    const events = [];
    canvas.addEventListener("bp-canvas-ops", (e) => events.push(["ops", e.detail.ops]));
    canvas.addEventListener("bp-server-insert", (e) => events.push(["server", e.detail]));

    typeSlashAfterFirst(editor, `/${type}`);
    const menu = canvas._slash;
    const row = menu && menu.isOpen() ? menu._items.find((item) => item.type === type) : null;
    check(`typing /${type} offers ${type} in the slash menu`, () => {
      assert.ok(row, `a ${type} row`);
    });
    if (row) canvas._chooseSlash(row);

    const serverEvents = events.filter(([kind]) => kind === "server");
    check(`choosing ${type} asks the server to insert it after the block above`, () => {
      assert.equal(serverEvents.length, 1, "exactly one server insert request");
      assert.deepEqual(serverEvents[0][1], { type, after_id: "p-a" });
    });

    check(`no ${type} node is inserted locally and the /query line is gone`, () => {
      assert.deepEqual(nodeTypes(editor), ["paragraph", "paragraph"]);
      assert.ok(!editor.state.doc.textContent.includes(`/${type}`), "the slash query text is gone");
      const opsBlocks = events
        .filter(([kind]) => kind === "ops")
        .flatMap(([, ops]) => ops)
        .filter((op) => op.block);
      assert.ok(
        !opsBlocks.some((op) => op.block.type === type),
        `no canvas batch carries a ${type} block (the server fence refuses it)`,
      );
      const serverAt = events.findIndex(([kind]) => kind === "server");
      const opsAt = events.findIndex(([kind]) => kind === "ops");
      if (opsAt !== -1) assert.ok(opsAt < serverAt, "the removal batch precedes the insert");
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  // ── PALETTE ───────────────────────────────────────────────────────────────
  {
    const canvas = await mount({ hostBuilds: true });
    const editor = canvas._editor;
    const inserts = [];
    canvas.addEventListener("bp-server-insert", (e) => inserts.push(e.detail));
    // The caret in the second (confirmed) block, as when the author opens the palette there.
    const first = editor.state.doc.child(0);
    editor.commands.setTextSelection(first.nodeSize + 2);
    canvas._openPalette();
    const cmd = (canvas._palette?._baseItems || []).find((c) => c.id === "insert-stage");
    check("the palette offers Insert Stage", () => assert.ok(cmd, "an insert-stage command"));
    if (cmd) canvas._choosePaletteCommand(cmd);
    check("Insert Stage from the palette asks the server, anchored on the caret's block", () => {
      assert.deepEqual(inserts, [{ type: "stage", after_id: "p-b" }]);
      assert.deepEqual(nodeTypes(editor), ["paragraph", "paragraph"], "no local stage node, no block removed");
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  // ── an embedder that does not build on the server: all four land in the canvas
  // (the pick removed "/" and inserted nothing — image + equation:
  // task-9c04bcc87b3da42f; terminal + stage in barkpark-studio: task-d170de40027ea448).
  for (const type of ["terminal", "stage", "image", "equation"]) {
    const canvas = await mount();
    const editor = canvas._editor;
    const inserts = [];
    canvas.addEventListener("bp-server-insert", (e) => inserts.push(e.detail));
    typeSlashAfterFirst(editor, `/${type}`);
    const row = canvas._slash?.isOpen() ? canvas._slash._items.find((item) => item.type === type) : null;
    if (row) canvas._chooseSlash(row);
    check(`without data-server-insert, /${type} inserts the ${type} node in the canvas`, () => {
      assert.ok(row, `a ${type} row`);
      assert.equal(inserts.length, 0, "no server insert request");
      assert.equal(nodeTypes(editor).length, 3, "the run gained a block in place of the slash line");
      assert.ok(!editor.state.doc.textContent.includes(`/${type}`), "the slash query text is gone");
    });
    canvas._openPalette();
    const cmd = (canvas._palette?._baseItems || []).find((c) => c.id === `insert-${type}`);
    if (cmd) canvas._choosePaletteCommand(cmd);
    check(`without data-server-insert, Insert ${type} from the palette inserts locally too`, () => {
      assert.ok(cmd, `an insert-${type} command`);
      assert.equal(inserts.length, 0, "still no server insert request");
      assert.equal(nodeTypes(editor).length, 4, "the palette added another block");
    });
    canvas.closest(".bp-paper-editor").remove();
  }

  // ── a local type still inserts locally ────────────────────────────────────
  {
    const canvas = await mount();
    const editor = canvas._editor;
    const inserts = [];
    canvas.addEventListener("bp-server-insert", (e) => inserts.push(e.detail));
    typeSlashAfterFirst(editor, "/heading");
    const row = canvas._slash?.isOpen() ? canvas._slash._items.find((item) => item.type === "heading") : null;
    if (row) canvas._chooseSlash(row);
    check("a heading pick still inserts the node in the canvas", () => {
      assert.equal(inserts.length, 0, "no server insert for a heading");
      assert.ok(nodeTypes(editor).includes("heading"), "a heading node is in the run");
    });
    canvas.closest(".bp-paper-editor").remove();
  }
} finally {
  dom.window.close();
}

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nserver_insert_widgets: Terminal, Stage, Image and Equation picks go through the server insert");
process.exit(0);
