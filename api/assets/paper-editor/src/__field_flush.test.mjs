import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(
  new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url),
  "utf8",
);

function loadHooks(window) {
  const context = vm.createContext({
    window,
    document: window.document,
    CustomEvent: window.CustomEvent,
    setTimeout,
    clearTimeout,
  });
  vm.runInContext(hooksSource, context);
  return window.BarkparkPaperEditorHooks;
}

function flush(wrapper) {
  const pending = [];
  wrapper.dispatchEvent(new wrapper.ownerDocument.defaultView.CustomEvent(
    "bp-flush-pending",
    { detail: { waitUntil: (promise) => pending.push(promise) } },
  ));
  return pending;
}

const dom = new JSDOM(`<!doctype html><body>
  <main><div id="text" data-block-id="field-1" data-field-type="field-text">
    <textarea>Before</textarea>
  </div></main>
  <main><div id="picker" data-block-id="field-2" data-field-type="field-image">
    <bp-media-picker></bp-media-picker>
  </div></main>
  <main><div id="image" data-block-id="image-1" data-field-type="image">
    <bp-media-picker></bp-media-picker>
  </div></main>
  <main><div id="destroyed" data-block-id="field-3" data-field-type="field-string">
    <input value="Before">
  </div></main>
</body>`, { url: "http://localhost/" });
const { window } = dom;
const hooks = loadHooks(window);

function mount(id) {
  const el = window.document.getElementById(id);
  const calls = [];
  const replies = [];
  const hook = {
    ...hooks.BarkparkFieldBlockBridge,
    el,
    pushEvent: (name, payload) => {
      calls.push({ name, payload });
      return new Promise((resolve, reject) => replies.push({
        resolve: (reply) => resolve({ ...reply, request_id: payload.request_id }), reject,
      }));
    },
  };
  hook.mounted();
  return { hook, el, calls, replies };
}

const text = mount("text");
const picker = mount("picker");
const image = mount("image");
const destroyed = mount("destroyed");

try {
  const textarea = text.el.querySelector("textarea");
  textarea.value = "Final native text";
  textarea.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(text.calls.length, 0, "native text remains local during the debounce");

  const firstWait = flush(text.el);
  assert.equal(text.calls.length, 1, "flush pushes the final native text immediately");
  assert.deepEqual(JSON.parse(JSON.stringify({
    name: text.calls[0].name,
    payload: {
      op: text.calls[0].payload.op,
      id: text.calls[0].payload.id,
      patch: text.calls[0].payload.patch,
    },
  })), {
    name: "paper-op",
    payload: {
      op: "patch-block",
      id: "field-1",
      patch: { value: "Final native text" },
    },
  });
  assert.equal(firstWait.length, 1, "flush contributes the save acknowledgement");

  const repeatWait = flush(text.el);
  assert.equal(text.calls.length, 1, "a repeated flush does not duplicate the patch");
  assert.equal(repeatWait.length, 1, "a repeated flush still waits for the in-flight save");
  text.replies.shift().resolve({ saved: false });
  assert.deepEqual(await Promise.all(firstWait), [false], "a refused save blocks the toggle");
  assert.deepEqual(await Promise.all(repeatWait), [false], "all waiters observe the refusal");
  const retryWait = flush(text.el);
  assert.equal(text.calls.length, 2, "the next View retries the failed field save");
  assert.deepEqual(JSON.parse(JSON.stringify({
    op: text.calls[1].payload.op,
    id: text.calls[1].payload.id,
    patch: text.calls[1].payload.patch,
  })), {
    op: "patch-block",
    id: "field-1",
    patch: { value: "Final native text" },
  });
  text.replies.shift().resolve({ saved: true });
  assert.deepEqual(await Promise.all(retryWait), [true]);

  text.el.querySelector("input, textarea").value = "Needs explicit acknowledgement";
  text.el.querySelector("input, textarea").dispatchEvent(new window.Event("input", { bubbles: true }));
  const missingAckWait = flush(text.el);
  text.replies.shift().resolve({});
  assert.deepEqual(await Promise.all(missingAckWait), [false], "an empty transport reply is not persistence success");
  const missingAckRetry = flush(text.el);
  text.replies.shift().resolve({ saved: true });
  assert.deepEqual(await Promise.all(missingAckRetry), [true]);

  const pickerNode = picker.el.querySelector("bp-media-picker");
  pickerNode.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: "asset-ref" },
  }));
  assert.equal(picker.calls.length, 1, "picker changes still push immediately");
  const pickerWait = flush(picker.el);
  assert.equal(picker.calls.length, 1, "flush does not duplicate an immediate picker save");
  assert.equal(pickerWait.length, 1, "flush waits for an in-flight picker save");
  picker.replies.shift().resolve({ saved: true });
  assert.deepEqual(await Promise.all(pickerWait), [true]);

  const imageNode = image.el.querySelector("bp-media-picker");
  imageNode.meta = { url: "https://example.test/final.jpg", alt: "Final image" };
  imageNode.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: "ignored-envelope" },
  }));
  assert.deepEqual(JSON.parse(JSON.stringify({
    op: image.calls[0].payload.op,
    id: image.calls[0].payload.id,
    patch: image.calls[0].payload.patch,
  })), {
    op: "patch-block",
    id: "image-1",
    patch: { src: "https://example.test/final.jpg", alt: "Final image" },
  });
  const imageWait = flush(image.el);
  assert.equal(imageWait.length, 1, "image content saves join the flush acknowledgement set");
  image.replies.shift().resolve({ saved: true });
  assert.deepEqual(await Promise.all(imageWait), [true]);

  const input = destroyed.el.querySelector("input");
  input.value = "Must not send after teardown";
  input.dispatchEvent(new window.Event("input", { bubbles: true }));
  destroyed.hook.destroyed();
  await new Promise((resolve) => setTimeout(resolve, 350));
  assert.equal(destroyed.calls.length, 0, "destroy clears the pending native debounce");
  assert.equal(flush(destroyed.el).length, 0, "destroy removes the flush listener");

  console.log("PASS field bridge: flush, acknowledgement, refusal, repeat, picker, teardown");
} finally {
  text.hook.destroyed();
  picker.hook.destroyed();
  image.hook.destroyed();
  dom.window.close();
}
