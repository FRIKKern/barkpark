// A callout that holds a body opens read-only in the rich editor and sends nothing
// for itself (task-c6355c4cb9cb7707; markdown/callout-words.js holds what a callout's
// words are). Until the editor can edit a body in place, such a callout shows its
// content, then each body block with every word it holds or as one line naming its
// kind, never a part of itself; it takes no typing and says so. A callout with no
// body, or an empty one, stays editable.
// Run: node src/canvas/__callout_body_readonly_mounted.test.mjs

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { NodeSelection } from "@tiptap/pm/state";
import { mount, paragraph } from "./source-flush-mounted-harness.mjs";
import { UNCHECKED, diffWords, goldenWords, loadPack } from "../../../../priv/portable_doc/conformance/conformance.mjs";

const readJson = (path) => JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8"));

// The reader's words for the shared nested-list fixture, in reader order: the same
// words render/nested_list_carriers_test.exs and src/__nested_list_carriers.test.mjs
// assert. No golden in the conformance pack holds nested list items.
const NESTED_LIST_CARRIER_WORDS = ["Plan", "Build", "Verify", "Ship", "Flat", "sibling", "Fallback", "parent", "Alias", "child"];

// The words an element shows, one text node apart from the next.
function shownText(node) {
  const parts = [];
  const walker = node.ownerDocument.createTreeWalker(node, 4);
  while (walker.nextNode()) parts.push(walker.currentNode.nodeValue);
  return parts.join(" ");
}

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
  // 1) A callout with content and a body: shown in order, read-only.
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

    // A key with the card selected goes where the editor's text input sends it, as
    // for every carried block: the stored callout stays as it was.
    let at = -1;
    editor.state.doc.forEach((node, offset) => { if (node.attrs.bpId === "c1") at = offset; });
    editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(editor.state.doc, at)));
    const typed = editor.view.someProp("handleTextInput", (f) => f(editor.view, at, at + 1, "x"));
    if (!typed) editor.view.dispatch(editor.state.tr.insertText("x", at, at + 1));
    canvas.flushPendingChanges();
    assert.ok(!batches.flat().some((op) => op.id === "c1"), "no op names the callout");
    assert.deepEqual(server.find((block) => block.id === "c1"), callout(), "the callout is stored as it was");
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

  // 4) A list's nested items are shown with their words.
  {
    const list = readJson("../../test-inputs/nested-list-carriers.json").blocks[0];
    const block = { id: "c1", type: "callout", tone: "note", slots: { body: [list] } };
    const { canvas } = await mount([paragraph("p1", "Before"), block]);
    mounted.push(canvas);
    const shown = shownText(canvas.querySelector('[data-bp-callout-readonly="c1"] [data-bp-callout-words]'));
    for (const word of ["Build", "Verify", "Alias"]) assert.ok(shown.includes(word), `the nested item word "${word}" is shown: ${JSON.stringify(shown)}`);
  }

  // 5) Each body block shows every word it holds or its marker, never a part. The
  //    body holds every block kind the schema allows, with the reader's own words for
  //    each from the conformance pack, plus the shared nested-list fixture and a
  //    callout whose body holds a table.
  {
    const kinds = Object.keys(readJson("../../../../priv/portable_doc/spec/blocks.schema.json").definitions.blocks);
    const golden = new Map(loadPack().cases.map((c) => [c.type, c]));
    const expected = new Map();
    const body = [];
    const add = (block, words) => { const id = `k${body.length}`; body.push({ ...block, id }); expected.set(id, words); };
    for (const kind of kinds) {
      const c = golden.get(kind);
      add(c ? c.input : { type: kind }, c ? goldenWords(c.shape) : []);
    }
    add(readJson("../../test-inputs/nested-list-carriers.json").blocks[0], NESTED_LIST_CARRIER_WORDS.map((w) => w.toLowerCase()));
    const table = golden.get("table");
    const inner = { ...golden.get("callout").input, slots: { body: [{ ...table.input, id: "inner-table" }] } };
    add(inner, goldenWords(golden.get("callout").shape));
    expected.set("inner-table", goldenWords(table.shape));
    const block = { id: "c1", type: "callout", tone: "note", content: [{ type: "text", value: "head words" }], slots: { body } };
    const { canvas } = await mount([paragraph("p1", "Before"), block]);
    mounted.push(canvas);
    const words = canvas.querySelector('[data-bp-callout-readonly="c1"] [data-bp-callout-words]');
    const check = (holder, blocks, where) => {
      const shown = [...holder.children].filter((child) => child.hasAttribute("data-bp-callout-body-block"));
      assert.equal(shown.length, blocks.length, `${where}: one shown block per body block`);
      blocks.forEach((stored, i) => {
        const view = shown[i];
        const label = `${where} block ${i + 1} (${stored.type})`;
        const text = view.textContent;
        if (text === `↪ ${stored.type}`) return;
        const want = expected.get(stored.id);
        const missing = diffWords(shownText(view), want);
        assert.notEqual(missing, UNCHECKED, `${label}: a block with no reader words shows its marker, got ${JSON.stringify(text)}`);
        assert.deepEqual(missing, [], `${label}: drawn with every word it holds, or its marker; got ${JSON.stringify(text)}`);
        if (stored.type === "callout") check(view, (stored.slots && stored.slots.body) || [], label);
      });
    };
    check(words, body, "body");
  }

  console.log("callout body read-only mounted: 5 cases passed");
} finally {
  for (const canvas of mounted) canvas.remove();
}
process.exit(0);
