import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hooksSource = readFileSync(new URL(
  "../../../priv/static/assets/bp-paper-editor-hooks.js",
  import.meta.url,
), "utf8");
assert.match(hooksSource, /\[phx-hook="BarkparkFigureImageBridge"\]/,
  "the Edit-to-View flush discovers the Figure image bridge");

const dom = new JSDOM(`<!doctype html><body>
  <main data-paper-doc-key="production:paper:figure" data-paper-rev="7">
    <div class="bp-paper-editor" data-paper-doc-key="production:paper:figure" data-paper-rev="7">
      <div id="figure-image" class="bp-paper-figure-image-editor"
           phx-hook="BarkparkFigureImageBridge" data-block-id="image-child-1"
           data-image-src="https://example.test/before.jpg">
        <div class="bp-paper-figure-image-paint">
          <img src="https://example.test/before.jpg" alt="Kept description">
        </div>
        <button type="button" class="bp-paper-figure-image-trigger"
                data-paper-figure-image-trigger aria-label="Replace figure image"></button>
        <details class="bp-paper-figure-image-controls">
          <summary>Image options</summary>
          <bp-media-picker data-paper-figure-image-picker></bp-media-picker>
        </details>
      </div>
    </div>
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
assert.equal(typeof Hooks.BarkparkFigureImageBridge?.mounted, "function",
  "the contextual Figure image bridge is shipped");

const el = window.document.getElementById("figure-image");
const trigger = el.querySelector("[data-paper-figure-image-trigger]");
const image = el.querySelector(".bp-paper-figure-image-paint img");
const picker = el.querySelector("[data-paper-figure-image-picker]");
const opens = [];
picker.openBrowser = () => { opens.push("browser"); return true; };
picker.openFileDialog = () => { opens.push("upload"); };
const calls = [];
const replies = [];
const hook = {
  ...Hooks.BarkparkFigureImageBridge,
  el,
  pushEvent: (name, payload) => {
    calls.push({ name, payload });
    return new Promise((resolve) => replies.push((reply) => resolve({
      ...reply,
      request_id: payload.request_id,
    })));
  },
};
hook.mounted();

try {
  el.dataset.imageOwner = "card";
  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  trigger.dispatchEvent(click);
  assert.equal(click.defaultPrevented, true, "the rendered image overlay owns its edit action");
  assert.deepEqual(opens, ["browser"], "clicking the rendered image opens the library");
  assert.equal(window.document.activeElement, trigger,
    "pointer activation gives the picker an Escape focus-return target");
  assert.equal(calls.length, 0, "opening or cancelling the picker does not mutate the Figure");

  for (const key of ["Enter", " "]) {
    const event = new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
    trigger.dispatchEvent(event);
    assert.equal(event.defaultPrevented, true, `${JSON.stringify(key)} consumes image activation`);
  }
  assert.deepEqual(opens, ["browser", "browser", "browser"]);

  picker.meta = { url: el.dataset.imageSrc, alt: "Must not overwrite authored alt" };
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: picker.meta.url, assetId: "asset-old" }) },
  }));
  assert.equal(calls.length, 0, "selecting the current source is a no-op");

  picker.meta = { url: "https://example.test/after.jpg", assetId: "asset-new", alt: "Do not copy" };
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: picker.meta.url, assetId: picker.meta.assetId }) },
  }));
  assert.deepEqual(JSON.parse(JSON.stringify({
    name: calls[0].name,
    op: calls[0].payload.op,
    id: calls[0].payload.id,
    patch: calls[0].payload.patch,
    if_rev: calls[0].payload.if_rev,
  })), {
    name: "paper-op",
    op: "patch-block",
    id: "image-child-1",
    patch: { src: "https://example.test/after.jpg" },
    if_rev: 7,
  }, "an absent Figure owner is frozen at mount and changes only the canonical child source");
  assert.equal(image.src, "https://example.test/before.jpg",
    "the bridge leaves the painted reader image to the server echo");
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: picker.meta.url, assetId: picker.meta.assetId }) },
  }));
  assert.equal(calls.length, 1, "a repeated selection cannot enqueue the same in-flight source twice");

  const pending = [];
  el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
    detail: { waitUntil: (promise) => pending.push(promise) },
  }));
  assert.equal(pending.length, 1, "View waits for the Figure image save acknowledgement");
  replies.shift()({ saved: true, rev: 8 });
  assert.deepEqual(await Promise.all(pending), [true]);

  el.dataset.imageSrc = "https://example.test/after.jpg";
  picker.value = "https://example.test/before.jpg";
  hook.updated();
  assert.equal(picker.value, el.dataset.imageSrc,
    "an authoritative echo refreshes the ignored native picker's source");
  picker.meta = {};
  picker.dispatchEvent(new window.CustomEvent("bp-change", {
    bubbles: true,
    detail: { value: JSON.stringify({ url: el.dataset.imageSrc, assetId: "asset-new" }) },
  }));
  assert.equal(calls.length, 1, "the authoritative echoed source remains a no-op baseline");

  for (const value of ["{malformed", JSON.stringify({ assetId: "missing-url" }), undefined]) {
    picker.dispatchEvent(new window.CustomEvent("bp-change", {
      bubbles: true,
      detail: value === undefined ? {} : { value },
    }));
  }
  assert.equal(calls.length, 1, "malformed or incomplete picker values never become destructive clears");

  picker.dispatchEvent(new window.CustomEvent("bp-change", { bubbles: true, detail: { value: "" } }));
  assert.deepEqual(JSON.parse(JSON.stringify(calls[1].payload.patch)), { src: "" },
    "the fallback's explicit Remove clears only the source");
  const removeId = calls[1].payload.request_id;
  const refusedWait = [];
  el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
    detail: { waitUntil: (promise) => refusedWait.push(promise) },
  }));
  replies.shift()({ saved: false });
  assert.deepEqual(await Promise.all(refusedWait), [false], "a refused replacement blocks View");
  const retryWait = [];
  el.dispatchEvent(new window.CustomEvent("bp-flush-pending", {
    detail: { waitUntil: (promise) => retryWait.push(promise) },
  }));
  assert.equal(calls.length, 3, "the next View retries the refused source change");
  assert.equal(calls[2].payload.request_id, removeId, "retry preserves the mutation identity");
  replies.shift()({ saved: true, rev: 9 });
  assert.deepEqual(await Promise.all(retryWait), [true]);

  picker.openBrowser = () => false;
  trigger.click();
  assert.equal(opens.at(-1), "upload", "upload remains the trusted fallback without browsing");

  el.setAttribute("inert", "");
  const beforeInert = calls.length;
  const opensBeforeInert = opens.length;
  trigger.click();
  picker.dispatchEvent(new window.CustomEvent("bp-change", { bubbles: true, detail: { value: "x" } }));
  assert.equal(calls.length, beforeInert, "an inert editor neither opens nor writes");
  assert.equal(opens.length, opensBeforeInert, "an inert editor does not activate the picker");

  hook.destroyed();
  el.removeAttribute("inert");
  const beforeDestroy = calls.length;
  trigger.click();
  picker.dispatchEvent(new window.CustomEvent("bp-change", { bubbles: true, detail: { value: "x" } }));
  assert.equal(calls.length, beforeDestroy, "destroy removes activation and persistence listeners");

  console.log("PASS contextual Figure image: rendered activation, source-only save, no-op, flush, inert, teardown");
} finally {
  hook.destroyed();
  dom.window.close();
}
