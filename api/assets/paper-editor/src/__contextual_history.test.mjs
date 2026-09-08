import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:history" data-paper-rev="7">
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:history" data-paper-rev="7">
      <div id="figure-image" phx-hook="BarkparkFigureImageBridge"
           data-block-id="figure-image-1" data-image-src="https://example.test/original.jpg">
        <button type="button" data-paper-figure-image-trigger>Replace image</button>
        <bp-media-picker data-paper-figure-image-picker></bp-media-picker>
      </div>
      <form id="caption-form" class="bp-paper-edit-form" phx-change="paper-edit-block"
            phx-debounce="300">
        <input type="hidden" name="block_id" value="figure-1">
        <textarea id="caption" name="caption">Caption</textarea>
      </form>
      <footer>
        <div class="bp-paper-history-controls" role="group" aria-label="Image and caption history">
          <button type="button" data-paper-history-action="undo" disabled>Undo</button>
          <button type="button" data-paper-history-action="redo" disabled>Redo</button>
          <span data-paper-history-status role="status" aria-live="polite"></span>
        </div>
        <span data-test-id="bp-paper-footer-save" role="status"></span>
      </footer>
    </div>
  </main>
</body>`, { url: "http://localhost/" });
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
vm.runInContext(
  readFileSync(new URL(
    "../../../priv/static/assets/bp-paper-editor-hooks.js",
    import.meta.url,
  ), "utf8"),
  vm.createContext({
    window,
    document: window.document,
    CustomEvent: window.CustomEvent,
    FormData: window.FormData,
    Date,
    setTimeout,
    clearTimeout,
    customElements: { whenDefined: () => Promise.resolve() },
  }),
);

const Hooks = window.BarkparkPaperEditorHooks;
const el = window.document.getElementById("figure-image");
const picker = el.querySelector("bp-media-picker");
const undo = window.document.querySelector('[data-paper-history-action="undo"]');
const redo = window.document.querySelector('[data-paper-history-action="redo"]');
const status = window.document.querySelector("[data-paper-history-status]");
const saveStatus = window.document.querySelector('[data-test-id="bp-paper-footer-save"]');
const calls = [];
const replies = [];
const deferReply = (toTarget, name, payload) => {
  calls.push({ name, payload, toTarget });
  return new Promise((resolve) => replies.push({ resolve, toTarget }));
};
const hook = {
  ...Hooks.BarkparkFigureImageBridge,
  el,
  pushEvent(name, payload) {
    return deferReply(false, name, payload);
  },
  pushEventTo(_target, name, payload) {
    return deferReply(true, name, payload);
  },
};
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const replaceImage = (src) => {
  picker.meta = { url: src };
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: src }) },
  }));
};
const settleReply = (reply) => {
  const pending = replies.shift();
  pending.resolve(pending.toTarget
    ? [{ status: "fulfilled", value: { reply } }]
    : reply);
};
const settleSaved = (call, rev, extra = {}) => settleReply({
  saved: true, request_id: call.payload.request_id, rev, ...extra,
});

hook.mounted();

try {
  assert.equal(undo.disabled, true);
  assert.equal(redo.disabled, true);

  replaceImage("https://example.test/first.jpg");
  const first = calls.at(-1);
  assert.equal(first.name, "paper-op");
  settleSaved(first, 8, {
    changed: true,
    history_step: { version: 1, ref: first.payload.request_id, action: "undo" },
  });
  await tick();
  assert.equal(undo.disabled, false, "a correlated non-noop receipt enables Undo");
  assert.equal(redo.disabled, true);

  const caption = window.document.getElementById("caption");
  caption.focus();
  caption.value = "Caption B";
  caption.dispatchEvent(new window.Event("input", { bubbles: true }));
  undo.click();
  const captionSave = calls.at(-1);
  assert.equal(captionSave.name, "paper-edit-block",
    "Undo flushes the production fallback caption form before selecting history");
  assert.equal(captionSave.toTarget, true, "the fallback caption uses the LiveView target reply path");
  assert.equal(captionSave.payload.caption, "Caption B");
  settleSaved(captionSave, 9, {
    changed: true,
    history_step: { version: 1, ref: captionSave.payload.request_id, action: "undo" },
  });
  await tick();
  await tick();
  const firstUndo = calls.at(-1);
  assert.equal(firstUndo.name, "paper-history-step");
  assert.equal(status.textContent, "Undoing…");
  assert.doesNotMatch(saveStatus.textContent, /auto-saved/i,
    "pending history cannot leave the document claiming it is saved");
  assert.deepEqual(JSON.parse(JSON.stringify(firstUndo.payload)), {
    history_ref: captionSave.payload.request_id,
    action: "undo",
    request_id: firstUndo.payload.request_id,
    if_rev: 9,
  }, "history selects the newest token after the save drain and sends no inverse value");

  settleReply({
    saved: true,
    request_id: firstUndo.payload.request_id,
    rev: 10,
    history_step: null,
  });
  await tick();
  assert.equal(undo.dataset.paperHistoryState, "retry",
    "an ambiguous applied response keeps the same history action retryable");
  assert.match(status.textContent, /not confirmed.*try again/i,
    "an ambiguous history response announces its retry state");
  const guardedUnload = new window.Event("beforeunload", { cancelable: true });
  window.dispatchEvent(guardedUnload);
  assert.equal(guardedUnload.defaultPrevented, true,
    "an ambiguous history request remains protected by the exit guard");

  undo.click();
  const retriedUndo = calls.at(-1);
  assert.equal(retriedUndo.payload.request_id, firstUndo.payload.request_id,
    "an ambiguous history acknowledgement retries the exact request identity");
  assert.equal(retriedUndo.payload.if_rev, 9,
    "an ambiguous history acknowledgement retries the immutable revision base");
  settleReply({
    saved: true,
    request_id: retriedUndo.payload.request_id,
    replayed: true,
    rev: 10,
    history_step: { version: 1, ref: retriedUndo.payload.request_id, action: "redo" },
  });
  await tick();
  assert.equal(redo.disabled, false, "Undo acknowledgement creates only an opaque Redo token");
  assert.equal(undo.disabled, false, "the older Undo entry remains below the consumed top");

  caption.value = "Caption";
  caption.dispatchEvent(new window.Event("input", { bubbles: true }));
  await new Promise((resolve) => setTimeout(resolve, 325));
  const postHistoryCaption = calls.at(-1);
  assert.equal(postHistoryCaption.name, "paper-edit-block");
  assert.equal(postHistoryCaption.payload.if_rev, 10,
    "a clean focused caption rebases to the acknowledged history revision");
  settleSaved(postHistoryCaption, 10, { changed: false, history_step: null });
  await tick();
  assert.equal(redo.disabled, false, "an acknowledged no-op preserves Redo");

  replaceImage("https://example.test/unsupported.jpg");
  const unsupported = calls.at(-1);
  settleSaved(unsupported, 11, {
    history_step: {
      version: 1,
      ref: unsupported.payload.request_id,
      action: "undo",
      leaked_private_value: "must-not-be-accepted",
    },
  });
  await tick();
  assert.equal(redo.disabled, true,
    "a legacy response without changed clears Redo and rejects a non-opaque history shape");

  undo.click();
  await tick();
  const consumed = calls.at(-1);
  assert.equal(consumed.name, "paper-history-step");
  assert.equal(consumed.payload.history_ref, first.payload.request_id,
    "after undoing the caption, the next Undo reaches the older image change");
  settleReply({
    saved: false,
    request_id: consumed.payload.request_id,
    rejected: "history_ref_consumed",
  });
  await tick();
  assert.equal(undo.disabled, true, "a terminal failure disables the failed top entry");
  assert.equal(undo.dataset.paperHistoryState, "blocked");
  assert.match(status.textContent, /already used/i,
    "the history status explains the terminal failure without exposing receipt contents");

  const callCountBeforeKeys = calls.length;
  caption.focus();
  const nativeUndo = new window.KeyboardEvent("keydown", {
    key: "z", metaKey: true, bubbles: true, cancelable: true,
  });
  caption.dispatchEvent(nativeUndo);
  assert.equal(nativeUndo.defaultPrevented, false,
    "Cmd/Ctrl-Z remains native inside editable text");
  assert.equal(calls.length, callCountBeforeKeys, "native text history does not call Paper history");

  const next = window.document.createElement("div");
  next.id = "next-figure";
  next.setAttribute("phx-hook", "BarkparkFigureImageBridge");
  next.dataset.paperDocKey = "production:paper:next";
  next.dataset.paperRev = "40";
  next.dataset.blockId = "next-image";
  next.dataset.imageSrc = "";
  next.innerHTML = '<button type="button" data-paper-figure-image-trigger></button>' +
    '<bp-media-picker data-paper-figure-image-picker></bp-media-picker>';
  window.document.querySelector(".bp-paper-editor").append(next);
  const nextHook = { ...Hooks.BarkparkFigureImageBridge, el: next, pushEvent: hook.pushEvent };
  nextHook.mounted();
  assert.equal(undo.dataset.paperHistoryState, "empty",
    "a clean document identity change clears session-only history");
  assert.equal(status.textContent, "");

  const nextPicker = next.querySelector("bp-media-picker");
  nextPicker.meta = { url: "https://example.test/next.jpg" };
  nextPicker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: nextPicker.meta.url }) },
  }));
  const nextForward = calls.at(-1);
  settleSaved(nextForward, 41, {
    changed: true,
    history_step: { version: 1, ref: nextForward.payload.request_id, action: "undo" },
  });
  await tick();
  const realNow = Date.now;
  const receivedAt = realNow();
  Date.now = () => receivedAt + 60 * 60 * 1000 + 1;
  try {
    const callsBeforeExpiry = calls.length;
    undo.click();
    await tick();
    assert.equal(calls.length, callsBeforeExpiry,
      "an expired client token is disabled without sending a doomed mutation");
    assert.equal(undo.dataset.paperHistoryState, "blocked");
    assert.match(status.textContent, /more than one hour old/i);
  } finally {
    Date.now = realNow;
  }
  nextHook.destroyed();

  console.log("PASS contextual history: FIFO, opaque retry, redo policy, terminal state, identity reset, native keys");
} finally {
  hook.destroyed();
  dom.window.close();
}
