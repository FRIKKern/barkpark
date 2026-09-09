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
  el.dataset.imageOwner = "future-card-owner";
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
    "the exact Card owner is frozen at mount and exposes only its source envelope");
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

function mountedCardBridge({ owner = "card", id = "ordered-card", src = "A" } = {}) {
  const ownerAttribute = owner == null ? "" : ` data-image-owner="${owner}"`;
  const fixture = new JSDOM(`<!doctype html><body>
    <main data-paper-doc-key="production:paper:card-order" data-paper-rev="7">
      <div class="bp-paper-editor" data-paper-doc-key="production:paper:card-order" data-paper-rev="7">
        <div id="bridge" phx-hook="BarkparkFigureImageBridge"${ownerAttribute}
             data-block-id="${id}" data-image-src="${src}">
          <button type="button" data-paper-figure-image-trigger>Replace</button>
          <bp-media-picker data-paper-figure-image-picker></bp-media-picker>
        </div>
      </div>
    </main>
  </body>`, { url: "http://localhost/" });
  const fixtureWindow = fixture.window;
  let fixtureUuid = 0;
  Object.defineProperty(fixtureWindow, "crypto", { configurable: true, value: {
    randomUUID: () =>
      `10000000-0000-4000-8000-${String(++fixtureUuid).padStart(12, "0")}`,
  } });
  vm.runInContext(hooksSource, vm.createContext({
    window: fixtureWindow,
    document: fixtureWindow.document,
    CustomEvent: fixtureWindow.CustomEvent,
    FormData: fixtureWindow.FormData,
    Date,
    setTimeout,
    clearTimeout,
    customElements: { whenDefined: () => Promise.resolve() },
  }));

  const bridge = fixtureWindow.document.getElementById("bridge");
  const mediaPicker = bridge.querySelector("[data-paper-figure-image-picker]");
  const mediaTrigger = bridge.querySelector("[data-paper-figure-image-trigger]");
  const fixtureCalls = [];
  const fixtureReplies = [];
  const fixtureOpens = [];
  mediaPicker.openBrowser = () => { fixtureOpens.push("browser"); return true; };
  mediaPicker.openFileDialog = () => { fixtureOpens.push("upload"); };
  const fixtureHook = {
    ...fixtureWindow.BarkparkPaperEditorHooks.BarkparkFigureImageBridge,
    el: bridge,
    pushEvent(name, payload) {
      fixtureCalls.push({ name, payload: structuredClone(payload) });
      return new Promise((resolve, reject) => fixtureReplies.push({
        resolve: (reply) => resolve({ ...reply, request_id: payload.request_id }),
        reject,
      }));
    },
  };
  fixtureHook.mounted();

  return {
    fixture,
    window: fixtureWindow,
    bridge,
    picker: mediaPicker,
    trigger: mediaTrigger,
    hook: fixtureHook,
    calls: fixtureCalls,
    replies: fixtureReplies,
    opens: fixtureOpens,
    choose(nextSrc) {
      mediaPicker.meta = { url: nextSrc };
      mediaPicker.dispatchEvent(new fixtureWindow.CustomEvent("bp-change", {
        bubbles: true,
        detail: { value: JSON.stringify({ url: nextSrc }) },
      }));
    },
    acknowledge(nextSrc, rev, extra = {}) {
      bridge.dataset.imageSrc = nextSrc;
      bridge.closest("[data-paper-rev]").dataset.paperRev = String(rev);
      fixtureReplies.shift().resolve({ saved: true, rev, ...extra });
    },
    close() {
      fixtureHook.destroyed();
      fixtureWindow.close();
    },
  };
}

// The author's newest intent can be the original source. It is not a no-op
// while a different source is in flight: queue the restoration behind B, then
// retain that exact rebased request through a lost acknowledgement.
{
  const env = mountedCardBridge();
  try {
    env.choose("B");
    env.choose("A");
    assert.equal(env.calls.length, 1, "A waits behind the in-flight B selection");
    env.acknowledge("B", 8);
    await waitFor(() => env.calls.length === 2);
    assert.deepEqual(Object.keys(env.calls[1].payload).sort(),
      ["block_id", "card-media-src", "if_rev", "request_id"].sort());
    assert.equal(env.calls[1].payload["card-media-src"], "A");
    assert.equal(env.calls[1].payload.if_rev, 8,
      "the queued restoration rebases onto B's acknowledged revision");

    const restoreWire = structuredClone(env.calls[1]);
    env.replies.shift().reject(new Error("restoration acknowledgement lost"));
    await tick();
    await tick();
    const pending = [];
    env.bridge.dispatchEvent(new env.window.CustomEvent("bp-flush-pending", {
      detail: { waitUntil: (promise) => pending.push(promise) },
    }));
    await waitFor(() => env.calls.length === 3);
    assert.deepEqual(env.calls[2], restoreWire,
      "the A restoration retries with the exact request identity and source-only wire");
    env.acknowledge("A", 9, { replayed: true });
    assert.deepEqual(await Promise.all(pending), [true]);
  } finally {
    env.close();
  }
}

// Dedupe against the last intended source, not every source anywhere in the
// queue. Returning to B after C is a distinct final intent and must survive.
{
  const env = mountedCardBridge();
  try {
    env.choose("B");
    env.choose("C");
    env.choose("B");
    assert.equal(env.calls.length, 1, "C and final B serialize behind the first B");

    env.acknowledge("B", 8);
    await waitFor(() => env.calls.length === 2);
    assert.equal(env.calls[1].payload["card-media-src"], "C");
    assert.equal(env.calls[1].payload.if_rev, 8);

    env.acknowledge("C", 9);
    await waitFor(() => env.calls.length === 3);
    assert.equal(env.calls[2].payload["card-media-src"], "B");
    assert.equal(env.calls[2].payload.if_rev, 9,
      "the final B intent rebases after C instead of being globally deduplicated");
    env.acknowledge("B", 10);
    await tick();
    assert.equal(env.hook._exitCoordinator.hasUnsaved(), false);
  } finally {
    env.close();
  }
}

// An explicitly present unknown owner is neither Figure nor Card. It cannot
// activate a picker or infer a write shape from arbitrary data attributes.
for (const owner of ["", "video"]) {
  const env = mountedCardBridge({ owner });
  try {
    env.trigger.click();
    env.choose("B");
    await tick();
    assert.deepEqual(env.opens, [], `unknown owner ${JSON.stringify(owner)} stays inactive`);
    assert.deepEqual(env.calls, [], `unknown owner ${JSON.stringify(owner)} cannot write`);
  } finally {
    env.close();
  }
}

console.log("PASS Card media ordering: latest intent, exact retry, frozen owner, unknown fail-closed");
