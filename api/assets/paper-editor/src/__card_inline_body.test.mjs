import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
window.BP_PAPER_EDITOR_NO_INJECT = true;

const { BpPaperEditor } = await import("./index.js");
const richContent = [
  { type: "strong", children: [{ type: "text", value: "Rich" }] },
  { type: "text", value: " body" },
];

function mount(block) {
  const editor = document.createElement("bp-paper-editor");
  assert.ok(editor instanceof BpPaperEditor);
  editor.setAttribute("data-editor-mode", "card-body");
  editor.block = block;
  const ops = [];
  editor.addEventListener("bp-op", (event) => ops.push(event.detail));
  document.body.appendChild(editor);
  return { editor, ops };
}

function text(inline) {
  return (inline || []).map((node) => node.value || text(node.children)).join("");
}

try {
  const source = {
    id: "card-1", type: "card", tone: "warn", unknown_card: { keep: true },
    slots: {
      title: { level: 3, text: "Keep title", unknown_title: 1 },
      media: { src: "/keep.png", width: 320, height: 180 },
      action: { label: "Go", href: "/go", meta: { keep: true } },
      unknown_slot: { byte: "exact" },
      body: [{ id: "body-p", type: "paragraph", unknown_body: "keep", content: richContent }],
    },
  };
  const original = structuredClone(source);
  const { editor, ops } = mount(source);
  assert.deepEqual(editor._editor.getJSON().content[0].content, [
    { type: "text", text: "Rich", marks: [{ type: "bold" }] },
    { type: "text", text: " body" },
  ]);
  editor._editor.view.dispatch(editor._editor.state.tr.insertText(" edited", 6));
  assert.equal(editor.flushPendingChanges(), true);
  assert.equal(ops.length, 1);
  assert.deepEqual(source, original, "editing never mutates the supplied Card");
  assert.equal(ops[0].op, "patch-card-body");
  assert.deepEqual(Object.keys(ops[0]).sort(), ["content", "id", "op"], "Card body emits only authored inline content");
  assert.match(text(ops[0].content), /edited/);

  const chromeWhileQueued = structuredClone(source);
  chromeWhileQueued.slots.title.text = "Chrome saved while body queued";
  chromeWhileQueued.slots.media.width = 640;
  editor.block = chromeWhileQueued;
  assert.match(editor._editor.getText(), /edited/, "a chrome echo cannot repaint an emitted body draft");
  assert.equal("slots" in ops[0], false, "queued body mutation cannot carry stale chrome slots");

  const acknowledgedBody = structuredClone(chromeWhileQueued);
  acknowledgedBody.slots.body[0].content = structuredClone(ops[0].content);
  editor.block = acknowledgedBody;
  assert.match(editor._editor.getText(), /edited/, "matching body authority retires the retained draft");

  const echoed = structuredClone(acknowledgedBody);
  echoed.slots.title.text = "Server-updated title";
  echoed.slots.unknown_slot.byte = "new authority";
  editor.block = echoed;
  editor._editor.view.dispatch(editor._editor.state.tr.insertText(" again", 6));
  editor.flushPendingChanges();
  assert.equal("slots" in ops[1], false);
  editor.remove();

  const dirty = mount(source);
  dirty.editor._editor.view.dispatch(dirty.editor._editor.state.tr.insertText(" local", 6));
  const dirtyChrome = structuredClone(source);
  dirtyChrome.slots.action.meta.keep = "new chrome";
  dirty.editor.block = dirtyChrome;
  assert.match(dirty.editor._editor.getText(), /local/, "a chrome echo cannot repaint a debounced body draft");
  dirty.editor.flushPendingChanges();
  assert.equal("slots" in dirty.ops[0], false);
  assert.match(text(dirty.ops[0].content), /local/);
  dirty.editor.remove();

  const reverted = mount(source);
  reverted.editor._editor.view.dispatch(reverted.editor._editor.state.tr.insertText(" queued B", 6));
  reverted.editor.flushPendingChanges();
  reverted.editor._editor.commands.setContent(reverted.editor._editor.options.content, true);
  assert.equal(reverted.editor.flushPendingChanges(), true, "reverting to A emits compensation while B is queued");
  assert.equal(reverted.ops.length, 2);
  assert.deepEqual(reverted.ops[1].content, richContent);
  reverted.editor.remove();

  const sameDebounce = mount(source);
  const noopTokens = [];
  let dirtyToken = 0;
  sameDebounce.editor.addEventListener("bp-local-change", (event) => { event.detail.token = `dirty-${++dirtyToken}`; });
  sameDebounce.editor.addEventListener("bp-noop", (event) => noopTokens.push(event.detail.token));
  sameDebounce.editor.setAttribute("editable", "false");
  sameDebounce.editor.setAttribute("editable", "true");
  assert.equal(dirtyToken, 0, "server-owned Card read-only toggles do not synthesize local changes");
  assert.equal(sameDebounce.editor.hasPendingChanges(), false);
  sameDebounce.editor._editor.view.dispatch(sameDebounce.editor._editor.state.tr.insertText(" transient", 6));
  sameDebounce.editor._editor.commands.setContent(sameDebounce.editor._editor.options.content, true);
  assert.equal(sameDebounce.editor.flushPendingChanges(), false, "A→B→A in one debounce is a true no-op with no outstanding save");
  assert.equal(sameDebounce.ops.length, 0);
  assert.deepEqual(noopTokens, ["dirty-2"], "the WC returns the hook-owned token for the latest change");
  sameDebounce.editor._editor.view.dispatch(sameDebounce.editor._editor.state.tr.insertText(" transient again", 6));
  sameDebounce.editor._editor.commands.setContent(sameDebounce.editor._editor.options.content, true);
  assert.equal(sameDebounce.editor.flushPendingChanges(), false);
  assert.deepEqual(noopTokens, ["dirty-2", "dirty-4"], "each no-op settles the exact latest hook token");
  sameDebounce.editor.remove();

  const activeRevert = mount(source);
  activeRevert.editor._editor.view.dispatch(activeRevert.editor._editor.state.tr.insertText(" queued B", 6));
  activeRevert.editor.flushPendingChanges();
  activeRevert.editor._editor.commands.setContent(activeRevert.editor._editor.options.content, true);
  activeRevert.editor.flushPendingChanges();
  activeRevert.editor.block = source;
  assert.equal(activeRevert.editor._cardBodyAwaitingContents.length, 2, "a chrome echo carrying later A cannot skip queued B");
  assert.deepEqual(activeRevert.editor._editor.getJSON(), activeRevert.editor._editor.options.content);
  const echoedB = structuredClone(source);
  echoedB.slots.body[0].content = structuredClone(activeRevert.ops[0].content);
  activeRevert.editor.block = echoedB;
  assert.equal(activeRevert.ops.length, 2, "B echo cannot erase or duplicate compensating A");
  assert.deepEqual(activeRevert.ops[1].content, richContent);
  activeRevert.editor.remove();

  const malformedDuringDraft = mount(source);
  let sourceError = null;
  malformedDuringDraft.editor.addEventListener("bp-error", (event) => { sourceError = event.detail; });
  malformedDuringDraft.editor._editor.view.dispatch(malformedDuringDraft.editor._editor.state.tr.insertText(" retained", 6));
  const retainedJSON = malformedDuringDraft.editor._editor.getJSON();
  malformedDuringDraft.editor.block = { id: source.id, type: "card", slots: { body: "malformed" } };
  assert.deepEqual(malformedDuringDraft.editor._editor.getJSON(), retainedJSON, "malformed authority cannot erase a body draft");
  assert.equal(sourceError.code, "card_body_source_unsupported");
  assert.equal(malformedDuringDraft.editor._editor.isEditable, false, "unsafe authority pauses further editing");
  malformedDuringDraft.editor.resolveConflictWithServerBlock({ id: source.id, type: "card", slots: { body: "malformed" } });
  assert.deepEqual(
    malformedDuringDraft.editor._editor.getJSON(),
    { type: "doc", content: [{ type: "paragraph" }] },
    "explicit Use Latest discards the retained draft into an honest read-only projection",
  );
  malformedDuringDraft.editor.remove();

  const clearing = mount(source);
  clearing.editor._editor.commands.setContent({ type: "doc", content: [{ type: "paragraph" }] }, true);
  clearing.editor.flushPendingChanges();
  assert.deepEqual(clearing.ops[0].content, [], "clearing asks the server to retain its authoritative paragraph map");
  clearing.editor.remove();

  for (const [label, block] of [
    ["multiple body blocks", { id: "bad-many", type: "card", slots: { body: [{ type: "paragraph", content: [] }, { type: "paragraph", content: [] }] } }],
    ["non-paragraph body", { id: "bad-heading", type: "card", slots: { body: [{ type: "heading", text: "No" }] } }],
    ["scalar slots", { id: "bad-slots", type: "card", slots: "opaque" }],
    ["unsupported inline metadata", { id: "bad-inline", type: "card", slots: { body: [{ type: "paragraph", content: [{ type: "text", value: "No", unknown: true }] }] } }],
    ["malformed inline children", { id: "bad-children", type: "card", slots: { body: [{ type: "paragraph", content: [{ type: "strong", children: "opaque" }] }] } }],
  ]) {
    const mounted = mount(block);
    assert.equal(mounted.editor._editor.isEditable, false, `${label} is visibly read-only`);
    assert.equal(mounted.editor.flushPendingChanges(), false, `${label} emits no operation`);
    mounted.editor.remove();
  }

  for (const body of [undefined, null, []]) {
    const slots = body === undefined ? { other: { keep: 1 } } : { other: { keep: 1 }, body };
    const mounted = mount({ id: `empty-${String(body)}`, type: "card", slots });
    mounted.editor._scheduleEmit();
    assert.equal(mounted.editor.flushPendingChanges(), false, "unchanged empty body is a byte-preserving no-op");
    assert.equal(mounted.ops.length, 0);
    mounted.editor._editor.view.dispatch(mounted.editor._editor.state.tr.insertText("Created", 1));
    mounted.editor.flushPendingChanges();
    assert.deepEqual(mounted.ops[0].content, [{ type: "text", value: "Created" }]);
    mounted.editor.remove();
  }

  for (const [label, card] of [
    ["missing slots", { id: "empty-no-slots", type: "card", keep: true }],
    ["null slots", { id: "empty-null-slots", type: "card", slots: null, keep: true }],
  ]) {
    const mounted = mount(card);
    mounted.editor._scheduleEmit();
    assert.equal(mounted.editor.flushPendingChanges(), false, `${label} remains an exact empty no-op`);
    mounted.editor._editor.view.dispatch(mounted.editor._editor.state.tr.insertText("Created", 1));
    mounted.editor.flushPendingChanges();
    assert.deepEqual(mounted.ops[0].content, [{ type: "text", value: "Created" }]);
    mounted.editor.remove();
  }

  const guarded = mount({ id: "guarded", type: "card", slots: { body: [{ id: "only", type: "paragraph", content: [{ type: "text", value: "One" }] }] } });
  let slashEvents = 0;
  guarded.editor.addEventListener("bp-slash-insert", () => { slashEvents += 1; });
  const before = guarded.editor._editor.getJSON();
  guarded.editor._editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  assert.deepEqual(guarded.editor._editor.getJSON(), before, "Enter cannot split Card body");
  guarded.editor._editor.commands.setHeading({ level: 2 });
  assert.deepEqual(guarded.editor._editor.getJSON(), before, "block conversion is vetoed");
  guarded.editor._editor.commands.insertContent([{ type: "paragraph", content: [{ type: "text", text: "Two" }] }, { type: "paragraph", content: [{ type: "text", text: "Three" }] }]);
  assert.deepEqual(guarded.editor._editor.getJSON(), before, "multi-block insertion is vetoed");
  guarded.editor._editor.commands.setContent({ type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "/heading" }] }] });
  assert.equal(slashEvents, 0, "Card body mode never opens or emits the structural slash path");
  assert.equal(guarded.ops.length, 0);
  guarded.editor.remove();

  console.log("Card inline-body mounted contract passed");
} finally {
  window.close();
}
