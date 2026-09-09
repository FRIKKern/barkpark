import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-hooks.js",
  import.meta.url,
), "utf8");
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const waitFor = async (predicate) => {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    if (predicate()) return;
    await tick();
  }
};

assert.match(hooksSource, /\[phx-hook="BarkparkFigureImageBridge"\]/,
  "Edit-to-View flushing discovers the shared contextual media bridge");

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:card-media" data-paper-rev="7">
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:card-media" data-paper-rev="7">
      <div id="card-media" class="bp-paper-card-media-editor"
           phx-hook="BarkparkFigureImageBridge" data-image-owner="card"
           data-block-id="card:media/[one]" data-image-src="https://example.test/before.jpg"
           data-image-event="forged-event" data-image-field="forged-field"
           data-payload='{"admin":true,"href":"/must-not-send"}'>
        <div class="bp-paper-card-media-paint">
          <img src="https://example.test/before.jpg" alt="Authored Card media alt">
        </div>
        <button type="button" class="bp-paper-figure-image-trigger"
                data-paper-figure-image-trigger aria-label="Replace Card media"></button>
        <details class="bp-paper-figure-image-controls">
          <summary>Media options</summary>
          <bp-media-picker data-paper-figure-image-picker></bp-media-picker>
        </details>
      </div>
    </div>
    <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
  </main>
</body>`, { url: "http://localhost/" });
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
vm.runInContext(hooksSource, vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
}));

const Hooks = window.BarkparkPaperEditorHooks;
const el = window.document.getElementById("card-media");
const trigger = el.querySelector("[data-paper-figure-image-trigger]");
const image = el.querySelector("img");
const picker = el.querySelector("[data-paper-figure-image-picker]");
const opens = [];
picker.openBrowser = () => { opens.push("browser"); return true; };
picker.openFileDialog = () => { opens.push("upload"); };

const calls = [];
const replies = [];
const hook = {
  ...Hooks.BarkparkFigureImageBridge,
  el,
  pushEvent(name, payload) {
    calls.push({ name, payload: structuredClone(payload) });
    return new Promise((resolve, reject) => replies.push({
      resolve: (reply) => resolve({ ...reply, request_id: payload.request_id }),
      reject,
    }));
  },
};
hook.mounted();

try {
  const pointer = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  trigger.dispatchEvent(pointer);
  assert.equal(pointer.defaultPrevented, true);
  assert.deepEqual(opens, ["browser"], "native pointer activation opens one trusted picker");
  assert.equal(window.document.activeElement, trigger,
    "pointer activation establishes the native Escape focus-return target");

  for (const key of ["Enter", " "]) {
    const keyboard = new window.KeyboardEvent("keydown", {
      key, bubbles: true, cancelable: true,
    });
    trigger.dispatchEvent(keyboard);
    assert.equal(keyboard.defaultPrevented, true, `${JSON.stringify(key)} is consumed once`);
  }
  assert.deepEqual(opens, ["browser", "browser", "browser"],
    "Enter and Space each open exactly one picker without an extra synthetic click");
  assert.equal(calls.length, 0, "opening or cancelling Card media never writes");

  picker.meta = { url: el.dataset.imageSrc, alt: "Must not overwrite authored alt" };
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: picker.meta.url, assetId: "asset-old" }) },
  }));
  assert.equal(calls.length, 0, "selecting the authoritative Card source is a no-op");

  picker.meta = {
    url: "https://example.test/after.jpg",
    assetId: "asset-new",
    alt: "Must remain server-authored",
  };
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: picker.meta.url, assetId: picker.meta.assetId }) },
  }));
  await waitFor(() => calls.length === 1);
  assert.equal(calls[0].name, "paper-edit-block");
  assert.deepEqual(Object.keys(calls[0].payload).sort(),
    ["block_id", "card-media-src", "if_rev", "request_id"].sort(),
    "Card mode exposes only the source field and immutable mutation envelope");
  assert.equal(calls[0].payload.block_id, "card:media/[one]");
  assert.equal(calls[0].payload["card-media-src"], "https://example.test/after.jpg");
  assert.equal(calls[0].payload.if_rev, 7);
  assert.equal(calls[0].payload.op, undefined);
  assert.equal(calls[0].payload.patch, undefined);
  assert.equal(calls[0].payload.admin, undefined);
  assert.equal(calls[0].payload.href, undefined);
  assert.equal(image.src, "https://example.test/before.jpg",
    "the reader paint remains server-authored until the authoritative refresh");

  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: picker.meta.url, assetId: picker.meta.assetId }) },
  }));
  assert.equal(calls.length, 1, "the same in-flight source cannot be queued twice");

  const originalWire = structuredClone(calls[0].payload);
  replies.shift().reject(new Error("acknowledgement lost after commit"));
  await tick();
  await tick();
  const retryWait = [];
  el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
    detail: { waitUntil: (promise) => retryWait.push(promise) },
  }));
  await waitFor(() => calls.length === 2);
  assert.equal(retryWait.length, 1, "View waits for the retained Card media retry");
  assert.deepEqual(calls[1], { name: "paper-edit-block", payload: originalWire },
    "a lost acknowledgement replays the exact request id, revision, and source-only payload");
  replies.shift().resolve({ saved: true, replayed: true, rev: 8 });
  assert.deepEqual(await Promise.all(retryWait), [true]);

  el.dataset.imageSrc = "https://example.test/after.jpg";
  el.closest("[data-paper-rev]").dataset.paperRev = "8";
  picker.value = "https://example.test/before.jpg";
  hook.updated();
  assert.equal(picker.value, el.dataset.imageSrc,
    "the authoritative Card refresh advances the ignored picker baseline");
  picker.meta = {};
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: el.dataset.imageSrc, assetId: "asset-new" }) },
  }));
  assert.equal(calls.length, 2, "the refreshed source remains a no-op baseline");

  for (const value of ["{malformed", JSON.stringify({ assetId: "missing-url" }), undefined]) {
    picker.dispatchEvent(new window.CustomEvent("bp-change", {
      bubbles: true,
      detail: value === undefined ? {} : { value },
    }));
  }
  assert.equal(calls.length, 2, "malformed envelopes never become destructive Card clears");

  el.setAttribute("inert", "");
  const callsBeforeInert = calls.length;
  const opensBeforeInert = opens.length;
  trigger.click();
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true, detail: { value: "https://example.test/inert.jpg" },
  }));
  assert.equal(opens.length, opensBeforeInert, "an inert Card editor cannot open the picker");
  assert.equal(calls.length, callsBeforeInert, "an inert Card editor cannot write");

  hook.destroyed();
  el.removeAttribute("inert");
  const callsBeforeDestroy = calls.length;
  const opensBeforeDestroy = opens.length;
  trigger.click();
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true, detail: { value: "https://example.test/destroyed.jpg" },
  }));
  assert.equal(opens.length, opensBeforeDestroy, "teardown removes Card activation listeners");
  assert.equal(calls.length, callsBeforeDestroy, "teardown removes Card persistence listeners");

  console.log("PASS Card media bridge: trusted activation, source-only replay, refresh, inert, teardown");
} finally {
  hook.destroyed();
  dom.window.close();
}
