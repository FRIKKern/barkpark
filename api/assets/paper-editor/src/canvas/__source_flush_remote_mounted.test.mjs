// Mounted remote source-mode reconciliation cases for contract 1.20.0.

import assert from "node:assert/strict";
import {
  window, paragraph, clone, sorted, mount, liveTexts, watchValueWrites,
} from "./source-flush-mounted-harness.mjs";

const mounted = [];
try {
  // 10) A clamp that put back a locked title the writer deleted leaves the textarea
  //     one block short of what it was saved as; a remote change after it still
  //     finds the block the caret is in.
  {
    const title = { id: "t0", type: "heading", level: 1, role: "title", locked: true, text: "Doctrine" };
    const { canvas, server } = await mount([title, paragraph("t1", "Body"), paragraph("t2", "Tail")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("Body\n\nTail");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    assert.equal(textarea.value, "Body\n\nTail");
    assert.equal(canvas.blocks[0].id, "t0", "the clamp kept the locked title");
    textarea.setSelectionRange(2, 2);
    const remote = [clone(server[0]), clone(server[1]), paragraph("t2", "Tail, elsewhere")];
    server.splice(0, server.length, ...clone(remote));
    canvas.applyServerBlocks(clone(remote));
    assert.match(textarea.value, /\n\nBody\n\nTail, elsewhere$/);
    const body = textarea.value.indexOf("Body");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [body + 2, body + 2], "the caret stays in the block it was in");
  }

  // 11) The blank lines above the first block are the writer's and always stay, so a
  //     caret on them stays too, whatever the remote change does below.
  {
    const { canvas, server } = await mount([paragraph("e1", "One"), paragraph("e2", "Two")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("\nOne\n\nTwo");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(0, 0);
    const added = [paragraph("e0", "Zero"), ...clone(server)];
    server.splice(0, server.length, ...clone(added));
    canvas.applyServerBlocks(clone(added));
    assert.equal(textarea.value, "\nZero\n\nOne\n\nTwo");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [0, 0]);
  }
  {
    const { canvas, server } = await mount([paragraph("e1", "One"), paragraph("e2", "Two")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("\n\nOne\n\nTwo");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(1, 1);
    const edited = [clone(server[0]), paragraph("e2", "Two, elsewhere")];
    server.splice(0, server.length, ...clone(edited));
    canvas.applyServerBlocks(clone(edited));
    assert.equal(textarea.value, "\n\nOne\n\nTwo, elsewhere");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [1, 1], "a kept blank line above keeps its caret");
  }

  // 12) One remote change deletes the caret's block and adds another: the caret goes
  //     to the block that was before it, not into the newcomer.
  {
    const { canvas, server } = await mount([paragraph("g1", "One"), paragraph("g2", "Two")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    textarea.focus();
    textarea.setSelectionRange(6, 6);
    const swapped = [paragraph("g0", "New"), paragraph("g1", "One")];
    server.splice(0, server.length, ...clone(swapped));
    canvas.applyServerBlocks(clone(swapped));
    assert.equal(textarea.value, "New\n\nOne\n\n");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [8, 8], "the caret goes to the end of One");
  }

  // 13) A caret in blank lines the writer opened after a block (review-24791's
  //     probe3): the lines travel with the block before them, through a reorder
  //     and through the removal of the block after them, and the caret stays on
  //     them, so the next key starts a new block and never lands in a neighbour.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("g1", "One"), paragraph("g2", "Two"), paragraph("g3", "Three")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("One\n\n\n\nTwo\n\nThree");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(5, 5);
    const reordered = [clone(server[2]), clone(server[0]), clone(server[1])];
    server.splice(0, server.length, ...clone(reordered));
    canvas.applyServerBlocks(clone(reordered));
    assert.equal(textarea.value, "Three\n\nOne\n\n\n\nTwo\n\n");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [12, 12], "the kept blank lines keep the caret");
    const removed = server.filter((block) => block.id !== "g2");
    server.splice(0, server.length, ...clone(removed));
    canvas.applyServerBlocks(clone(removed));
    assert.equal(textarea.value, "Three\n\nOne\n\n\n\n");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [12, 12], "the blank lines travel with One and keep the caret");
    value.press("!");
    canvas.flushPendingChanges();
    assert.deepEqual(liveTexts(canvas), ["Three", "One", "!"]);
    assert.ok(batches.at(-1).every((op) => op.op !== "patch-block"), "no block takes the key");
    inSync("after a key in blank lines whose next block was removed");
  }

  // 14) A change that ends on a low surrogate both emoji share never leaves the caret
  //     between the two halves of a pair (the save would hold a lone surrogate).
  {
    const { canvas, server, inSync } = await mount([paragraph("u1", "ab\u{1F600}")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    textarea.setSelectionRange(2, 2);
    const swapped = [paragraph("u1", "aZ\u{1FA00}")];
    server.splice(0, server.length, ...clone(swapped));
    canvas.applyServerBlocks(clone(swapped));
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [4, 4], "the caret goes past the whole pair");
    value.press("z");
    canvas.flushPendingChanges();
    assert.deepEqual(liveTexts(canvas), ["aZ\u{1FA00}z"]);
    inSync("after a key next to a swapped emoji");
  }

  // 15) A block Markdown can only write as a <!--bp:block--> line (a soft line break,
  //     a table) keeps the lines the writer typed while another block changes, also
  //     when the server sends every key sorted, as Barkpark's JSON does.
  {
    const { canvas, server, inSync } = await mount([paragraph("w1", "Top."), paragraph("w2", "Base."), paragraph("w3", "x")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    const typed = "Top.\n\n**first** line\nsecond line\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nBase.";
    value.type(typed);
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(sorted(server));
    textarea.setSelectionRange(typed.length, typed.length);
    const edited = clone(server);
    edited[0] = paragraph(edited[0].id, "Top, edited.");
    server.splice(0, server.length, ...clone(edited));
    canvas.applyServerBlocks(sorted(edited));
    assert.equal(textarea.value, typed.replace("Top.", "Top, edited."));
    value.press("z");
    canvas.flushPendingChanges();
    assert.equal(liveTexts(canvas).at(-1), "Base.z");
    inSync("after a key below blocks that need a <!--bp:block--> line");
  }

  // 16) A textarea of blank lines only: they all stay above a block the server puts
  //     in, and the caret stays on its line.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("e1", "x")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("\n\n\n");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(2, 2);
    const filled = [paragraph("e2", "New")];
    server.splice(0, server.length, ...clone(filled));
    canvas.applyServerBlocks(clone(filled));
    assert.equal(textarea.value, "\n\n\nNew");
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [2, 2], "the caret stays on its blank line");
    inSync("after a block fills a blank textarea");
  }

  // 17) A block typed next to one Markdown writes as a <!--bp:block--> line is an
  //     insert: the other block keeps its id and is not patched.
  {
    const { canvas, batches, inSync } = await mount([paragraph("v1", "Top."), paragraph("v2", "first line\nsecond line"), paragraph("v3", "Base.")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("Top.\n\nfirst line\nsecond line\n\nBase.");
    canvas.flushPendingChanges();
    batches.length = 0;
    value.type("Top.\n\nNew.\n\nfirst line\nsecond line\n\nBase.");
    canvas.flushPendingChanges();
    assert.deepEqual(batches.flat().map((op) => op.op), ["insert-after"]);
    assert.deepEqual(canvas.blocks.map((block) => block.id).filter((id) => id.startsWith("v")), ["v1", "v2", "v3"]);
    inSync("after a block typed next to a soft-wrapped one");
  }

  // 18) A remote that applies at once drops an older one still queued: the writer
  //     typed (so the first was held), typed back to the saved text, then a newer
  //     remote applied; a blur must not bring the held one back.
  {
    const { canvas, server, inSync } = await mount([paragraph("k1", "One"), paragraph("k2", "Two")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    const saved = textarea.value;
    value.type(saved.replace("Two", "Two!"));
    const held = clone(server);
    held[0] = paragraph("k1", "Uno");
    server.splice(0, server.length, ...clone(held));
    canvas.applyServerBlocks(clone(held));
    assert.equal(textarea.value, "One\n\nTwo!", "the remote waits while the textarea holds unsaved text");
    value.type(saved);
    const newer = [...clone(held), paragraph("k3", "Three")];
    server.splice(0, server.length, ...clone(newer));
    canvas.applyServerBlocks(clone(newer));
    assert.equal(textarea.value, "Uno\n\nTwo\n\nThree");
    textarea.blur();
    document.dispatchEvent(new window.FocusEvent("focusout"));
    await new Promise((resolve) => setTimeout(resolve, 700));
    assert.equal(textarea.value, "Uno\n\nTwo\n\nThree", "the held remote does not come back");
    inSync("after a blur that found nothing held");
  }

  // 19) Blank lines after the last block travel with it when a block lands after it
  //     (review-24788 T1, T2): the caret stays on its blank line, and the key starts
  //     a new block between the two.
  for (const edited of [false, true]) {
    const { canvas, server, inSync } = await mount([paragraph("t1", "One"), paragraph("t2", "Two")]);
    mounted.push(canvas);
    canvas.toggleSourceMode();
    const textarea = canvas.querySelector(".bp-canvas-source");
    const value = watchValueWrites(textarea);
    textarea.focus();
    value.type("One\n\nTwo\n\n\n");
    canvas.flushPendingChanges();
    canvas.applyServerBlocks(clone(server));
    textarea.setSelectionRange(11, 11);
    const appended = [clone(server[0]), edited ? paragraph(server[1].id, "Two!") : clone(server[1]), paragraph("t3", "Three")];
    server.splice(0, server.length, ...clone(appended));
    canvas.applyServerBlocks(clone(appended));
    const two = edited ? "Two!" : "Two";
    assert.equal(textarea.value, `One\n\n${two}\n\n\n\n\nThree`);
    const caret = 5 + two.length + 3;
    assert.deepEqual([textarea.selectionStart, textarea.selectionEnd], [caret, caret], "the caret stays on its blank line");
    value.press("z");
    canvas.flushPendingChanges();
    assert.deepEqual(liveTexts(canvas), ["One", two, "z", "Three"]);
    inSync(`after a key on the trailing blank lines${edited ? " of an edited block" : ""}`);
  }
  console.log("mounted source-mode flush regression passed");
} finally {
  for (const canvas of mounted) canvas.remove();
  window.close();
}
