// A callout that holds a body is shown whole and read-only in the rich editor
// (task-c6355c4cb9cb7707). Its words are its content, then every block of its body.
// Until the editor can edit a body in place, such a callout shows content then every
// body block, takes no typing, says so, and sends nothing for itself. A callout with
// no body, or an empty one, stays editable.
// Run: node src/canvas/__callout_body_readonly_mounted.test.mjs

import assert from "node:assert/strict";
import { mount, paragraph } from "./source-flush-mounted-harness.mjs";

const callout = () => ({
  id: "c1",
  type: "callout",
  tone: "note",
  title: "Heads up",
  content: [{ type: "text", value: "head words" }],
  slots: {
    body: [
      paragraph("b1", "body one"),
      { id: "b2", type: "list", items: [[{ type: "text", value: "body item" }]] },
      paragraph("b3", "body two"),
    ],
  },
});

// Where the editor would take a key at the end of `words`, or -1 when no editable
// text holds them.
function typingSpot(editor, words) {
  let at = -1;
  editor.state.doc.descendants((node, pos) => {
    if (at !== -1 || !node.isText) return;
    const i = node.text.indexOf(words);
    if (i !== -1) at = pos + i + words.length;
  });
  return at;
}

const mounted = [];
try {
  // 1) A callout with content and a body: shown whole, in order, read-only.
  {
    const { canvas, batches, server, inSync } = await mount([paragraph("p1", "Before"), callout()]);
    mounted.push(canvas);
    const editor = canvas._editor;
    const view = canvas.querySelector('[data-bp-callout-readonly="c1"]');
    assert.ok(view, "the callout with a body is shown as a read-only callout");
    assert.equal(view.getAttribute("contenteditable"), "false", "it takes no typing");
    const shown = view.querySelector("[data-bp-callout-words]").textContent;
    const order = ["Heads up", "head words", "body one", "body item", "body two"].map((w) => shown.indexOf(w));
    assert.ok(order.every((i) => i !== -1), `every word of the callout is shown: ${JSON.stringify(shown)}`);
    assert.deepEqual([...order].sort((a, b) => a - b), order, "content first, then every body block in order");
    assert.match(view.querySelector("[data-bp-callout-readonly-note]").textContent, /^Read only: this callout has a body/, "it says it is read-only");
    for (const words of ["head words", "body one", "body two"]) {
      assert.equal(typingSpot(editor, words), -1, `"${words}" are not text the editor can type into`);
    }

    // A key in the paragraph before it saves that paragraph and nothing of the callout.
    editor.view.dispatch(editor.state.tr.insertText("!", typingSpot(editor, "Before")));
    canvas.flushPendingChanges();
    assert.equal(batches.length, 1, "the key is saved");
    assert.deepEqual(batches[0].map((op) => op.id), ["p1"], "only the paragraph typed in is sent");
    assert.deepEqual(server[1], callout(), "the callout is stored as it was");
    inSync("after a key beside a callout with a body");

    // Source mode and back sends nothing and keeps the callout.
    batches.length = 0;
    canvas.toggleSourceMode();
    canvas.toggleSourceMode();
    assert.deepEqual(batches, [], "source mode and back sends nothing");
    assert.deepEqual(server[1], callout(), "and keeps the callout");
  }

  // 2) A callout with a body and no content is read-only too.
  {
    const block = { id: "c1", type: "callout", tone: "info", slots: { body: [paragraph("b1", "only body")] } };
    const { canvas } = await mount([paragraph("p1", "Before"), block]);
    mounted.push(canvas);
    const view = canvas.querySelector('[data-bp-callout-readonly="c1"]');
    assert.ok(view, "a callout holding only a body is read-only");
    assert.match(view.querySelector("[data-bp-callout-words]").textContent, /only body/);
    assert.equal(typingSpot(canvas._editor, "only body"), -1);
  }

  // 3) A callout without a body, or with an empty one, stays editable: a key lands in
  //    its content.
  for (const [label, extra] of [["no body", {}], ["an empty body", { slots: { body: [] } }]]) {
    const block = { id: "c1", type: "callout", tone: "note", content: [{ type: "text", value: "own words" }], ...extra };
    const { canvas, batches, server, inSync } = await mount([paragraph("p1", "Before"), block]);
    mounted.push(canvas);
    assert.equal(canvas.querySelector("[data-bp-callout-readonly]"), null, `no read-only callout (${label})`);
    const editor = canvas._editor;
    const at = typingSpot(editor, "own words");
    assert.notEqual(at, -1, `the callout's words take typing (${label})`);
    editor.view.dispatch(editor.state.tr.insertText("!", at));
    canvas.flushPendingChanges();
    assert.equal(batches.length, 1, `the key is saved (${label})`);
    assert.deepEqual(server[1], { ...block, content: [{ type: "text", value: "own words!" }] }, `the key lands in content (${label})`);
    if (!extra.slots) inSync(`after a key in a callout with ${label}`);
  }

  console.log("callout body read-only mounted: 3 cases passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
