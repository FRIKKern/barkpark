// task-c522237b9f37de21 — the LiveView paper host wires shared carets: a run's
// `bp-canvas-selection` goes to the server as `paper-selection` (trailing
// throttle), a blur's null is not sent while another run of the paper has
// focus, and `bp:remote-selections` reaches every run's setRemoteSelections.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:carets" data-paper-rev="3">
    <div class="bp-paper-editor">
      <div id="paper-canvas-carets-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas tabindex="0"></bp-paper-canvas></div>
      <div id="paper-canvas-carets-run-1" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas tabindex="0"></bp-paper-canvas></div>
    </div>
  </main>
`);
const { window } = dom;
let uuid = 0;
Object.defineProperty(window, "crypto", { configurable: true, value: {
  randomUUID: () => `00000000-0000-4000-8000-${String(++uuid).padStart(12, "0")}`,
} });
const context = vm.createContext({
  window,
  document: window.document,
  CustomEvent: window.CustomEvent,
  FormData: window.FormData,
  Date,
  setTimeout,
  clearTimeout,
  customElements: { whenDefined: () => Promise.resolve() },
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);
const Hooks = window.BarkparkPaperEditorHooks;

const pushes = [];
const handlers = [];
const mounts = [...window.document.querySelectorAll('[phx-hook="BarkparkPaperCanvas"]')].map((el) => {
  const canvas = el.querySelector("bp-paper-canvas");
  canvas.acknowledgedSaves = true;
  canvas.setRemoteSelections = (list) => { canvas.remote = list; };
  const hook = {
    ...Hooks.BarkparkPaperCanvas,
    el,
    handleEvent: (name, handler) => handlers.push({ el, name, handler }),
    pushEvent: (name, payload) => { pushes.push({ run: el.id, name, payload }); return Promise.resolve({}); },
  };
  hook.mounted();
  return { el, canvas, hook };
});
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// The hook runs in a vm realm: compare plain data by value, not by prototype.
const select = (i, detail) => mounts[i].canvas.dispatchEvent(
  new window.CustomEvent("bp-canvas-selection", { bubbles: true, composed: true, detail }),
);
const sel = (offset) => ({ anchor: { blockId: "p-1", offset }, head: { blockId: "p-1", offset } });
const selectionPushes = () => pushes.filter((p) => p.name === "paper-selection");

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${error.message}`);
  }
}

await check("the caret goes to the server once per burst, with the latest position", async () => {
  select(0, sel(1));
  select(0, sel(2));
  select(0, sel(3));
  assert.equal(selectionPushes().length, 0, "throttled");
  await wait(120);
  assert.equal(selectionPushes().length, 1);
  assert.equal(JSON.stringify(selectionPushes()[0].payload), JSON.stringify({ selection: sel(3) }));
});

await check("a blur's null is held back while another run of the paper has focus", async () => {
  mounts[1].canvas.focus();
  select(0, null);
  await wait(120);
  assert.equal(selectionPushes().length, 1, "no clearing push while run 1 holds focus");
  mounts[1].canvas.blur();
  select(0, null);
  await wait(120);
  assert.equal(selectionPushes().length, 2);
  assert.equal(JSON.stringify(selectionPushes()[1].payload), JSON.stringify({ selection: null }));
});

await check("every run draws the other sessions' carets", () => {
  const list = [{ id: "s2", name: "Bob", color: "#e11d48", anchor: sel(0).anchor, head: sel(4).head }];
  for (const h of handlers.filter((x) => x.name === "bp:remote-selections")) h.handler({ list });
  assert.deepEqual(mounts[0].canvas.remote, list);
  assert.deepEqual(mounts[1].canvas.remote, list);
  for (const h of handlers.filter((x) => x.name === "bp:remote-selections")) h.handler({ list: [] });
  assert.deepEqual(mounts[0].canvas.remote, [], "an empty list clears them");
});

if (failures) {
  console.log(`\n${failures} check(s) failed`);
  process.exit(1);
}
console.log("\nall remote caret hook checks passed");
process.exit(0);
