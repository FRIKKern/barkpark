import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const hookSource = readFileSync(
  new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url),
  "utf8",
);

function mountCanvas(attributes = "") {
  const dom = new JSDOM(`
    <main data-paper-doc-key="production:paper:nested" data-paper-rev="7">
      <div id="paper-canvas-nested-run" phx-hook="BarkparkPaperCanvas"
           data-canvas-blocks="[]" ${attributes}>
        <bp-paper-canvas></bp-paper-canvas>
      </div>
      <footer><span role="status" data-test-id="bp-paper-footer-save"></span></footer>
    </main>
  `);
  const { window } = dom;
  Object.defineProperty(window, "crypto", {
    configurable: true,
    value: { randomUUID: () => "10000000-0000-4000-8000-000000000001" },
  });
  const context = vm.createContext({
    window,
    document: window.document,
    CustomEvent: window.CustomEvent,
    FormData: window.FormData,
    Date,
    setTimeout,
    clearTimeout,
    customElements: { whenDefined: () => new Promise(() => {}) },
  });
  vm.runInContext(hookSource, context);

  const wrapper = window.document.querySelector('[phx-hook="BarkparkPaperCanvas"]');
  const canvas = wrapper.querySelector("bp-paper-canvas");
  const pending = [];
  const errors = [];
  wrapper.addEventListener("bp-error", (event) => errors.push(event.detail));
  const bridge = {
    ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
    el: wrapper,
    handleEvent() {},
    pushEvent(name, payload) {
      assert.equal(name, "paper-ops");
      return new Promise((resolve, reject) => pending.push({ payload, resolve, reject }));
    },
  };
  bridge.mounted();
  return { dom, window, wrapper, canvas, bridge, pending, errors };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

{
  const { dom, window, wrapper, canvas, bridge, pending } = mountCanvas(
    'data-paper-container-id="details-1" data-paper-container-run="2"',
  );
  canvas.blocks = [{ id: "nested-a" }, { id: "nested-b" }];
  const ops = [{ op: "insert-block", after_id: "nested-p", block: { id: "nested-new" } }];
  wrapper.dispatchEvent(
    new window.CustomEvent("bp-canvas-ops", { bubbles: true, detail: { ops, seq: 9 } }),
  );

  assert.equal(pending.length, 1);
  const original = structuredClone(pending[0].payload);
  assert.equal(original.container_id, "details-1");
  assert.deepEqual(original.container_run_ids, ["nested-a", "nested-b"]);
  assert.deepEqual(original.ops, ops);
  assert.equal(original.if_rev, 7);

  wrapper.dataset.paperContainerId = "details-moved";
  wrapper.dataset.paperContainerRun = "5";
  canvas.blocks = [{ id: "different-current-run" }];
  pending.shift().reject(new Error("reply lost"));
  await tick();

  const barriers = [];
  wrapper.dispatchEvent(
    new window.CustomEvent("bp-flush-pending", {
      bubbles: true,
      detail: { waitUntil: (promise) => barriers.push(promise) },
    }),
  );
  assert.equal(pending.length, 1);
  assert.deepEqual(
    structuredClone(pending[0].payload),
    original,
    "transport retry must preserve the original ops, nested context, revision and request ID",
  );

  pending[0].resolve({ saved: true, request_id: original.request_id, rev: 8 });
  await Promise.all(barriers);
  bridge.destroyed();
  dom.window.close();
}

{
  const { dom, window, wrapper, canvas, bridge, pending } = mountCanvas("");
  canvas.blocks = [{ id: "top-level" }];
  wrapper.dispatchEvent(
    new window.CustomEvent("bp-canvas-ops", {
      bubbles: true,
      detail: { ops: [{ op: "patch-block", id: "top-level" }], seq: 1 },
    }),
  );

  assert.equal(pending.length, 1);
  assert.equal("container_id" in pending[0].payload, false);
  assert.equal("container_run_ids" in pending[0].payload, false);
  pending[0].resolve({
    saved: true,
    request_id: pending[0].payload.request_id,
    rev: 8,
  });
  await tick();
  bridge.destroyed();
  dom.window.close();
}

for (const [attributes, confirmedBlocks] of [
  ['data-paper-container-run="0"', [{ id: "orphan-run" }]],
  ['data-paper-container-id=""', [{ id: "blank-container" }]],
  ['data-paper-container-id="details-1"', []],
  ['data-paper-container-id="details-1"', [{ id: "" }]],
  ['data-paper-container-id="details-1"', [{ id: "duplicate" }, { id: "duplicate" }]],
]) {
  const { dom, window, wrapper, canvas, bridge, pending, errors } = mountCanvas(attributes);
  canvas.blocks = confirmedBlocks;
  wrapper.dispatchEvent(
    new window.CustomEvent("bp-canvas-ops", {
      bubbles: true,
      detail: { ops: [{ op: "patch-block", id: "top-level" }], seq: 1 },
    }),
  );

  assert.equal(pending.length, 0, "invalid nested context must never become a top-level write");
  assert.deepEqual(errors.map((error) => error.code), ["paper_ops_container_context_invalid"]);
  assert.match(
    window.document.querySelector('[data-test-id="bp-paper-footer-save"]').textContent,
    /nested editor lost its document position/,
  );
  bridge.destroyed();
  dom.window.close();
}

console.log("nested canvas context: retry + top-level + 5 fail-closed cases passed");
