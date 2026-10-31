// Mounted regression for contract 1.20.0: with `flushKeepsSource`, flushPendingChanges()
// in Markdown source mode saves the source text and keeps source mode open; without it
// the flush leaves source mode as before. The textarea keeps its value,
// caret, selection and focus (its value is never written, so the browser's native undo
// survives), the rich history gains no step, half-typed Markdown commits without
// throwing, and a block a half-typed construct swallowed gets its id back once the
// construct is closed. A block born in source mode keeps its id across flushes, every
// flush replays on a server to exactly the canvas's blocks (a kind change is a remove
// and an insert, never a typeless patch), and an external apply while the textarea
// holds no unsaved text shows up in the textarea instead of being reverted by the
// next flush. `sourceMode` reports the mode.

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
const { markdownToBlocks } = await import("../markdown.js");
await import("../index.js");
await import("./index.js");

const paragraph = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });
const clone = (value) => JSON.parse(JSON.stringify(value));
const sorted = (value) => Array.isArray(value)
  ? value.map(sorted)
  : value && typeof value === "object"
    ? Object.fromEntries(Object.keys(value).sort()
      .filter((key) => !(key === "lang" && value[key] === ""))
      .map((key) => [key, sorted(value[key])]))
    : value;

// A server that folds each batch the way portable_doc/patch.ex does: patch-block is a
// shallow merge that never changes `type`.
function replay(server, op) {
  const at = (id) => server.findIndex((block) => block.id === id);
  const need = (id) => {
    const index = at(id);
    assert.notEqual(index, -1, `${op.op} names ${id}, which the server does not hold`);
    return index;
  };
  if (op.op === "patch-block") {
    const index = need(op.id);
    server[index] = { ...server[index], ...clone(op.patch) };
  } else if (op.op === "replace-block") server[need(op.id)] = clone(op.block);
  else if (op.op === "remove-block") server.splice(need(op.id), 1);
  else if (op.op === "insert-after") {
    assert.equal(at(op.block.id), -1, `insert-after re-inserts ${op.block.id}`);
    server.splice(op.afterId == null ? 0 : need(op.afterId) + 1, 0, clone(op.block));
  } else if (op.op === "append-block") {
    assert.equal(at(op.block.id), -1, `append-block re-inserts ${op.block.id}`);
    server.push(clone(op.block));
  } else if (op.op === "move-block") {
    const [block] = server.splice(need(op.id), 1);
    server.splice(op.after == null ? 0 : need(op.after) + 1, 0, block);
  } else assert.fail(`unexpected op ${op.op}`);
}

async function mount(blocks, { flushKeepsSource = true } = {}) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.flushKeepsSource = flushKeepsSource;
  canvas.blocks = blocks;
  const batches = [];
  const server = clone(blocks);
  const refused = [];
  canvas.addEventListener("bp-canvas-ops", (event) => {
    batches.push(event.detail.ops);
    try {
      for (const op of event.detail.ops) replay(server, op);
    } catch (error) {
      refused.push(error.message);
    }
    canvas.acknowledgeOps(event.detail.seq, true);
  });
  document.body.appendChild(canvas);
  await new Promise((resolve) => setTimeout(resolve, 350));
  batches.length = 0;
  const inSync = (label) => {
    assert.deepEqual(refused, [], `the server takes every op ${label}`);
    assert.deepEqual(sorted(server), sorted(canvas.blocks),
      `the server's replay of every batch equals the canvas's blocks ${label}`);
  };
  return { canvas, batches, server, inSync };
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
  const type = (v) => { descriptor.set.call(textarea, v); textarea.dispatchEvent(new window.Event("input", { bubbles: true })); };
  // One key at the selection, as a browser does: it replaces what is selected.
  const press = (key) => {
    const [from, to, text] = [textarea.selectionStart, textarea.selectionEnd, textarea.value];
    type(text.slice(0, from) + key + text.slice(to));
    textarea.setSelectionRange(from + key.length, from + key.length);
  };
  return { writes, type, press };
}

const mounted = [];
try {
  // 0) Without the opt-in nothing changes for a host: the flush leaves source mode, and
  //    a server apply while source mode is open waits for the exit.
  {
    const { canvas, batches, server } = await mount([paragraph("d1", "One"), paragraph("d2", "Two")], { flushKeepsSource: false });
    mounted.push(canvas);
    assert.equal(canvas.flushKeepsSource, false, "flushKeepsSource defaults to false");
    canvas.toggleSourceMode();
    watchValueWrites(canvas.querySelector(".bp-canvas-source")).type("One\n\nTwo, typed");
    assert.equal(canvas.flushPendingChanges(), true);
    assert.equal(canvas.sourceMode, false, "the flush leaves source mode");
    assert.equal(batches.length, 1);
    canvas.applyServerBlocks(clone(server));
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    canvas.applyServerBlocks([paragraph("d1", "One, from elsewhere"), paragraph("d2", "Two, typed")]);
    assert.equal(textarea.value, "One\n\nTwo, typed", "the apply waits while source mode is open");
    document.dispatchEvent(new window.FocusEvent("focusout"));
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.equal(textarea.value, "One\n\nTwo, typed", "a focus release does not apply it either");
    canvas.blocks = [paragraph("d9", "Reseeded")];
    assert.equal(textarea.value, "One\n\nTwo, typed", "a reseed does not touch the textarea");
    canvas.resolveConflictWithServerBlocks([paragraph("d9", "Resolved")]);
    assert.equal(textarea.value, "One\n\nTwo, typed", "a conflict resolution does not touch the textarea");
  }

  // 1) A flush saves the source text and source mode stays open with its caret,
  //    selection, focus and value untouched; the rich history gains no step.
  {
    const { canvas, batches } = await mount([paragraph("p1", "One"), paragraph("p2", "Two")]);
    mounted.push(canvas);
    assert.equal(canvas.sourceMode, false, "a mounted canvas starts in rich mode");
    assert.equal(canvas.flushKeepsSource, true, "flushKeepsSource reads back the opt-in");
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
  //    open, every flush replays on the server to the canvas's blocks (the fence turns
  //    paragraphs into code: a remove and an insert, not a typeless patch the server
  //    would merge into a paragraph), and the final text keeps the ids of the blocks a
  //    half-typed construct swallowed on the way.
  {
    const { canvas, batches, inSync } = await mount([paragraph("a1", "One"), paragraph("a2", "Two"), paragraph("a3", "Three")]);
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
      ">[!e]O\n\nTwo\n\nThree",
      "",
    ];
    for (const md of midway) {
      value.type(md);
      assert.doesNotThrow(() => canvas.flushPendingChanges(), `a flush of ${JSON.stringify(md)} does not throw`);
      assert.equal(canvas.sourceMode, true, `source mode stays open after ${JSON.stringify(md)}`);
      assert.equal(textarea.value, md, "the textarea keeps exactly what was typed");
      assert.equal(new Set(liveIds(canvas).filter(Boolean)).size, liveIds(canvas).filter(Boolean).length,
        `no two live blocks share an id after ${JSON.stringify(md)}`);
      inSync(`after ${JSON.stringify(md)}`);
    }
    value.type("One\n\n```\nlet x\n```\n\nTwo\n\nThree");
    canvas.flushPendingChanges();
    const ids = liveIds(canvas);
    assert.deepEqual(liveTexts(canvas), ["One", "let x", "Two", "Three"]);
    assert.deepEqual([ids[0], ids[2], ids[3]], ["a1", "a2", "a3"],
      "the blocks the half-typed fence swallowed keep their ids");
    inSync("after the fence closes");
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

  // 5) A block born in source mode keeps the id it was first sent with: editing it
  //    across later flushes sends patch-blocks, never a remove and a fresh insert.
  {
    const { canvas, batches, inSync } = await mount([paragraph("n1", "One")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const value = watchValueWrites(canvas.querySelector(".bp-canvas-source"));
    value.type("One\n\nNew");
    canvas.flushPendingChanges();
    const [inserted] = batches[0];
    assert.equal(inserted.op, "insert-after", "the new block goes out as an insert");
    const born = inserted.block.id;
    value.type("One\n\nNew, edited");
    canvas.flushPendingChanges();
    value.type("One\n\nNew, edited twice");
    canvas.flushPendingChanges();
    assert.deepEqual(batches.slice(1), [
      [{ op: "patch-block", id: born, patch: { content: [{ type: "text", value: "New, edited" }] } }],
      [{ op: "patch-block", id: born, patch: { content: [{ type: "text", value: "New, edited twice" }] } }],
    ], "later edits of the new block are patches of the id it was sent with");
    inSync("after editing a block born in source mode");
    assert.deepEqual(canvas.recoverySnapshot().blocks.map((block) => block.id), ["n1", born],
      "the recovery snapshot carries the ids the flushes sent");

    value.type("# One\n\nNew, edited twice");
    canvas.flushPendingChanges();
    assert.deepEqual(batches.at(-1).map((op) => [op.op, op.id]), [["replace-block", "n1"]],
      "a paragraph turned into a heading keeps its id, as a replace-block");
    inSync("after a paragraph became a heading");
    canvas.toggleSourceMode();
    assert.equal(batches.length, 4, "leaving sends nothing more");
    assert.deepEqual(liveIds(canvas), ["n1", born]);
  }

  // 5b) One commit realigns exactly as leaving source mode does: a removed block's id
  //     goes to no new block elsewhere.
  {
    const { canvas, batches, inSync } = await mount([paragraph("k1", "Top"), paragraph("k2", "Middle")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    watchValueWrites(canvas.querySelector(".bp-canvas-source")).type("Middle\n\nBrand new");
    canvas.flushPendingChanges();
    const ops = batches[0];
    assert.ok(ops.some((op) => op.op === "remove-block" && op.id === "k1"), "the removed block is removed");
    assert.ok(ops.some((op) => op.op === "insert-after" && op.block.id !== "k1"), "the new block is inserted with an id of its own");
    inSync("after a remove and an insert in one commit");
  }

  // 6) An external apply while source mode is open and the textarea holds no unsaved
  //    text (a host undo after its flush, another writer) shows up in the textarea,
  //    with the caret kept where it was relative to the text, and the next flush sends
  //    only what is typed after it, not the external change reverted. With unsaved
  //    text in the textarea the apply waits, as it did before 1.20.0.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("u1", "Alpha"), paragraph("u2", "Beta")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("Alpha\n\nBeta edited");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    const undone = [paragraph("u1", "Alpha"), paragraph("u2", "Beta")];
    server.splice(0, server.length, ...clone(undone));
    textarea.setSelectionRange(2, 2);
    canvas.applyServerBlocks(clone(undone));
    assert.equal(canvas.sourceMode, true, "the apply keeps source mode open");
    assert.equal(textarea.value, "Alpha\n\nBeta", "the textarea shows the external change");
    assert.equal(document.activeElement, textarea, "the textarea keeps focus");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [2, 2], "a caret before the change stays put");
    assert.equal(canvas.hasPendingChanges(), false, "the external text is not an unsaved edit");
    assert.equal(canvas.flushPendingChanges(), false, "a flush right after it sends nothing");
    value.type("Alpha\n\nBeta!");
    canvas.flushPendingChanges();
    assert.deepEqual(batches.at(-1), [{
      op: "patch-block",
      id: "u2",
      patch: { content: [{ type: "text", value: "Beta!" }] },
    }], "the next flush sends the new typing on top of the external change");
    inSync("after an external apply in source mode");

    canvas.applyServerBlocks(clone(server));
    value.type("Alpha\n\nBeta! unsaved");
    const other = [paragraph("u1", "Alpha, from elsewhere"), paragraph("u2", "Beta!")];
    canvas.applyServerBlocks(clone(other));
    assert.equal(textarea.value, "Alpha\n\nBeta! unsaved", "unsaved text in the textarea is never overwritten");
    assert.equal(canvas.hasPendingChanges(), true);
  }

  // 6b) The sync never turns a caret into a selection the next key overwrites, and it
  //     rewrites only the blocks the server change touched.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("r1", "First"), paragraph("r2", "Second"), paragraph("r3", "Third")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("First\n\nSecond\n\nThird!");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(9, 9);
    const reordered = [server[2], server[0], server[1]].map(clone);
    server.splice(0, server.length, ...clone(reordered));
    canvas.applyServerBlocks(clone(reordered));
    assert.equal(textarea.value, "Third!\n\nFirst\n\nSecond", "the reorder shows up");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [17, 17],
      "a remote reorder leaves a caret, still inside the block being typed in");
    value.press("z");
    canvas.flushPendingChanges();
    assert.deepEqual(batches.at(-1), [{ op: "patch-block", id: "r2", patch: { content: [{ type: "text", value: "Sezcond" }] } }],
      "one key after a remote reorder patches the block it was typed in, and removes nothing");
    inSync("after one key on a remote reorder");
  }
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("w1", "Alpha beta")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("Alpha beta.");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(10, 10);
    const word = [paragraph("w1", "Alpha gamma.")];
    server.splice(0, server.length, ...clone(word));
    canvas.applyServerBlocks(clone(word));
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [11, 11], "a caret at the end of a remote word change moves past it");
    value.press("!");
    canvas.flushPendingChanges();
    assert.deepEqual(liveTexts(canvas), ["Alpha gamma!."], "the next key keeps the remote word");
    inSync("after one key on a remote word change");

    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(8, 8);
    const inside = [paragraph("w1", "Alpha delta!.")];
    server.splice(0, server.length, ...clone(inside));
    canvas.applyServerBlocks(clone(inside));
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [10, 10], "a caret inside the changed span goes to its end");

    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(0, 5, "backward");
    const after = [paragraph("w1", "Alpha delta!. More")];
    server.splice(0, server.length, ...clone(after));
    canvas.applyServerBlocks(clone(after));
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd, textarea.selectionDirection], [0, 5, "backward"],
      "a selection before the change keeps its ends and its direction");
  }
  {
    const { canvas, server } = await mount([paragraph("c1", "Top"), { id: "c2", type: "list", items: [[{ type: "text", value: "star" }]] }]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    value.type("Top\n\n* star __under__ item");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    const top = [paragraph("c1", "Top, from elsewhere"), clone(server[1])];
    server.splice(0, server.length, ...clone(top));
    canvas.applyServerBlocks(clone(top));
    assert.equal(textarea.value, "Top, from elsewhere\n\n* star __under__ item",
      "a remote edit to one block keeps the writer's own text in the others");
    assert.equal(canvas.hasPendingChanges(), false);
  }
  {
    const { canvas, server } = await mount([paragraph("f1", "One")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    watchValueWrites(textarea).type("One\n\n```\ncode");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    const added = [...clone(server), paragraph("f9", "Added elsewhere")];
    server.splice(0, server.length, ...clone(added));
    canvas.applyServerBlocks(clone(added));
    assert.equal(textarea.value, "One\n\n```\ncode\n```\n\nAdded elsewhere",
      "an unclosed fence is closed before a block the server put after it, so it cannot swallow that block");
    assert.deepEqual(markdownToBlocks(textarea.value).map((block) => block.type), ["paragraph", "code", "paragraph"]);
  }

  // 7) A host reseed (`blocks =`) while source mode is open shows the new run in the
  //    textarea, so the next flush diffs against it.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("r1", "Old")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    server.splice(0, server.length, paragraph("r9", "Reseeded"));
    canvas.blocks = [paragraph("r9", "Reseeded")];
    assert.equal(textarea.value, "Reseeded", "the textarea shows the reseeded run");
    assert.equal(canvas.flushPendingChanges(), false, "nothing is pending after a reseed");
    watchValueWrites(textarea).type("Reseeded!");
    canvas.flushPendingChanges();
    assert.deepEqual(batches, [[{
      op: "patch-block",
      id: "r9",
      patch: { content: [{ type: "text", value: "Reseeded!" }] },
    }]], "the next flush patches the reseeded block");
    inSync("after a reseed in source mode");
  }

  // 8) An external apply that reorders the blocks (setContent, not the in-place path)
  //    also reaches the textarea; an id it removed is never sent again for a
  //    new block; and a liveRemote host's apply reaches a clean textarea too.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("x1", "One"), paragraph("x2", "Two")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    value.type("One\n\nTwo\n\nBorn here");
    canvas.flushPendingChanges();
    const born = batches[0][0].block.id;
    canvas.applyServerBlocks(clone(server));
    const external = [paragraph("x2", "Two"), paragraph("x1", "One")];
    server.splice(0, server.length, ...clone(external));
    canvas.applyServerBlocks(clone(external));
    assert.equal(textarea.value, "Two\n\nOne", "a reordered block list shows up in the textarea");
    value.type("Two\n\nOne\n\nFresh");
    canvas.flushPendingChanges();
    const fresh = batches.at(-1).find((op) => op.op === "insert-after");
    assert.ok(fresh && fresh.block.id !== born, "the id the external change removed is not reused for a new block");
    inSync("after an external apply that reordered the blocks");
  }
  {
    const { canvas, server } = await mount([paragraph("l1", "Live")]);
    mounted.push(canvas);
    canvas.liveRemote = true;
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const remote = [paragraph("l1", "Live, from elsewhere")];
    server.splice(0, server.length, ...clone(remote));
    canvas.applyServerBlocks(clone(remote));
    assert.equal(textarea.value, "Live, from elsewhere", "a liveRemote apply reaches a clean textarea");
  }

  // 9) A `>[!x]y` line that is no callout header (no space after `]`) is plain text:
  //    as the first line it is a blockquote (it once stalled the parse loop forever),
  //    inside a callout it stays in the callout's body.
  {
    assert.deepEqual(markdownToBlocks(">[!e]O").map((block) => block.type), ["blockquote"]);
    assert.deepEqual(markdownToBlocks("> [!note]\n> a\n>[!e]O").map((block) => [block.type, block.content?.map((run) => run.value).join("")]),
      [["callout", "a\n[!e]O"]], "a non-header `>[!e]O` line stays in the callout body");
  }

  console.log("mounted source-mode flush regression passed");
} finally {
  for (const canvas of mounted) canvas.remove();
  window.close();
}
