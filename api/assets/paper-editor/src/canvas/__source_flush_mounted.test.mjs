// Mounted regression for contract 1.20.0: flushPendingChanges() in Markdown source mode
// saves the source text and keeps source mode open. The textarea keeps its value,
// caret, selection and focus (its value is never written, so the browser's native undo
// survives), the rich history gains no step, half-typed Markdown commits without
// throwing, and a block a half-typed construct swallowed gets its id back once the
// construct is closed. `sourceMode` reports the mode.

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
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects ||= () => [];
window.Range.prototype.getBoundingClientRect ||= () => ({ top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0 });

const { undoDepth } = await import("@tiptap/pm/history");
await import("../index.js");
await import("./index.js");

const paragraph = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });

async function mount(blocks) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.blocks = blocks;
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (event) => {
    batches.push(event.detail.ops);
    canvas.acknowledgeOps(event.detail.seq, true);
  });
  document.body.appendChild(canvas);
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;
  return { canvas, batches };
}

const liveIds = (canvas) => canvas._editor.getJSON().content.map((node) => node.attrs.bpId);
const liveTexts = (canvas) => canvas._editor.getJSON().content.map((node) =>
  node.attrs.value ?? (node.content || []).map((child) => child.text || "").join(""));

function watchValueWrites(textarea) {
  const proto = Object.getPrototypeOf(textarea);
  const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
  const writes = [];
  Object.defineProperty(textarea, "value", {
    configurable: true,
    get() { return descriptor.get.call(this); },
    set(v) { writes.push(v); descriptor.set.call(this, v); },
  });
  return { writes, type(v) { descriptor.set.call(textarea, v); textarea.dispatchEvent(new window.Event("input", { bubbles: true })); } };
}

const mounted = [];
try {
  // 1) A flush saves the source text and source mode stays open with its caret,
  //    selection, focus and value untouched; the rich history gains no step.
  {
    const { canvas, batches } = await mount([paragraph("p1", "One"), paragraph("p2", "Two")]);
    mounted.push(canvas);
    assert.equal(canvas.sourceMode, false, "a mounted canvas starts in rich mode");
    const depth = undoDepth(canvas._editor.state);
    canvas.toggleSourceMode();
    assert.equal(canvas.sourceMode, true, "sourceMode reports the open textarea");
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    value.type("One\n\nTwo, typed in source");
    textarea.focus();
    textarea.setSelectionRange(5, 8, "backward");

    assert.equal(canvas.hasPendingChanges(), true, "unsaved source text is pending");
    assert.equal(canvas.flushPendingChanges(), true, "the flush emits the source edit");
    assert.deepEqual(batches, [[{
      op: "patch-block",
      id: "p2",
      patch: { content: [{ type: "text", value: "Two, typed in source" }] },
    }]], "the edit goes out as a patch of the block it edits");
    assert.equal(canvas.sourceMode, true, "source mode stays open after the flush");
    assert.equal(canvas.querySelector(".bp-canvas-source"), textarea, "the same textarea stays mounted");
    assert.equal(document.activeElement, textarea, "the textarea keeps focus");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd, textarea.selectionDirection], [5, 8, "backward"],
      "the caret and selection stay where they were");
    assert.deepEqual(value.writes, [], "the flush never writes the textarea value, so its native undo survives");
    assert.equal(undoDepth(canvas._editor.state), depth, "the commit adds no rich undo step");
    assert.deepEqual(liveTexts(canvas), ["One", "Two, typed in source"], "the hidden rich editor holds the source text");
    assert.equal(canvas.hasPendingChanges(), false, "nothing is pending once the source text is saved");
    let noops = 0;
    canvas.addEventListener("bp-noop", () => noops++);
    assert.equal(canvas.flushPendingChanges(), false, "a repeated flush is a no-op");
    assert.equal(noops, 0, "a repeated flush re-parses nothing, so it says nothing either");

    value.type("One\n\nTwo, typed in source again");
    assert.equal(canvas.flushPendingChanges(), true, "a later source edit flushes too");
    assert.deepEqual(batches[1], [{
      op: "patch-block",
      id: "p2",
      patch: { content: [{ type: "text", value: "Two, typed in source again" }] },
    }], "the later flush sends only what changed since the first");

    canvas.toggleSourceMode();
    assert.equal(canvas.sourceMode, false, "the toggle leaves source mode");
    assert.equal(batches.length, 2, "leaving with nothing new sends nothing");
    assert.deepEqual(liveTexts(canvas), ["One", "Two, typed in source again"]);
    assert.equal(undoDepth(canvas._editor.state), depth, "source commits never become rich undo steps");
  }

  // 2) Typing back to the last saved text after a flush, then leaving: no batch, and
  //    the rich editor keeps the saved text (the NO-EDIT exit compares against the
  //    last commit, not the text shown on enter).
  {
    const { canvas, batches } = await mount([paragraph("q1", "Start")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    value.type("Changed");
    assert.equal(canvas.flushPendingChanges(), true);
    value.type("Changed!");
    value.type("Changed");
    assert.equal(canvas.hasPendingChanges(), false, "text typed back to the saved text is not pending");
    canvas.toggleSourceMode();
    assert.equal(batches.length, 1, "leaving sends nothing more");
    assert.deepEqual(liveTexts(canvas), ["Changed"], "the rich editor keeps the saved source text");

    canvas.toggleSourceMode();
    const again = canvas.querySelector(".bp-canvas-source");
    watchValueWrites(again).type("Start");
    canvas.toggleSourceMode();
    assert.deepEqual(batches[1], [{
      op: "patch-block",
      id: "q1",
      patch: { content: [{ type: "text", value: "Start" }] },
    }], "reverting to the text shown on the first enter is an edit, not a no-op");
  }

  // 3) Half-typed Markdown commits on every flush without throwing, source mode stays
  //    open, and the final text keeps the ids of the blocks a half-typed construct
  //    swallowed on the way.
  {
    const { canvas, batches } = await mount([paragraph("a1", "One"), paragraph("a2", "Two"), paragraph("a3", "Three")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    const midway = [
      "One\n\n```\n\nTwo\n\nThree",
      "One\n\n```js\nlet x\n\nTwo\n\nThree",
      "One\n\n| a | b |\n| -\n\nTwo\n\nThree",
      "One [[Tit\n\nTwo\n\nThree",
      "One **bold\n\nTwo\n\nThree",
      "One\n\n<!--bp:block {\"id\":\"a\n\nTwo\n\nThree",
      "One\n\n<!--bp:block {\"id\":\"a1\",\"type\":\"paragraph\",\"content\":[]}-->\n\nTwo\n\nThree",
      "- \n\nTwo\n\nThree",
      "#\n\nTwo\n\nThree",
      "",
    ];
    for (const md of midway) {
      value.type(md);
      assert.doesNotThrow(() => canvas.flushPendingChanges(), `a flush of ${JSON.stringify(md)} does not throw`);
      assert.equal(canvas.sourceMode, true, `source mode stays open after ${JSON.stringify(md)}`);
      assert.equal(textarea.value, md, "the textarea keeps exactly what was typed");
      assert.equal(new Set(liveIds(canvas).filter(Boolean)).size, liveIds(canvas).filter(Boolean).length,
        `no two live blocks share an id after ${JSON.stringify(md)}`);
    }
    value.type("One\n\n```\nlet x\n```\n\nTwo\n\nThree");
    canvas.flushPendingChanges();
    const ids = liveIds(canvas);
    assert.deepEqual(liveTexts(canvas), ["One", "let x", "Two", "Three"]);
    assert.deepEqual([ids[0], ids[2], ids[3]], ["a1", "a2", "a3"],
      "the blocks the half-typed fence swallowed keep their ids");
    canvas.toggleSourceMode();
    assert.deepEqual(liveTexts(canvas), ["One", "let x", "Two", "Three"], "leaving keeps the final text");
    assert.ok(batches.length >= midway.length, "every half-typed state was sent");
  }

  // 4) A flush clamps a locked template title like leaving source mode does: deleting
  //    its line sends no remove-block for it, the live doc keeps it at the head, and the
  //    body edit typed beside the deletion still lands.
  {
    const locked = { id: "tpl-title", type: "heading", level: 1, role: "title", locked: true, text: "Doctrine" };
    const { canvas, batches } = await mount([locked, paragraph("tpl-body", "Body.")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    watchValueWrites(canvas.querySelector(".bp-canvas-source")).type("Body, edited in source.");
    canvas.flushPendingChanges();
    assert.ok(!batches.flat().some((op) => op.op === "remove-block" && op.id === "tpl-title"),
      "the flush never removes the locked title");
    assert.equal(liveIds(canvas)[0], "tpl-title", "the locked title stays at the head of the live doc");
    assert.deepEqual(liveTexts(canvas).slice(1), ["Body, edited in source."], "the body edit still lands");
    assert.equal(canvas.sourceMode, true);
  }

  console.log("mounted source-mode flush regression passed");
} finally {
  for (const canvas of mounted) canvas.remove();
  window.close();
}
