// __paper_bundle_gate.test.mjs — task-ca0936b4ca4a936d: the paper editor
// bundle loads `async`, so the LiveSocket no longer waits for it, and a paper
// hook can mount before <bp-paper-canvas> / <bp-paper-editor> are defined.
//
// This test takes the REAL gate from root.html.heex (between the
// `bp-paper-bundle-gate:start` / `:end` markers) and the REAL hook map from
// priv/static/assets/bp-paper-editor-hooks.js, and checks that no wrapped
// hook's own `mounted` runs before both elements are defined (or window
// `load`, when the bundle failed), that it runs at once when they already
// are, and that a hook destroyed while waiting never mounts.
//
// Run: node ../paper-editor-host-tests/__paper_bundle_gate.test.mjs
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "./jsdom.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "../../lib/barkpark_web/layouts/root.html.heex");
const HOOKS = path.join(__dirname, "../../priv/static/assets/bp-paper-editor-hooks.js");

const layout = fs.readFileSync(ROOT, "utf8");
// The markers close the gate's first and last lines (the layout may not grow).
const startAt = layout.indexOf("// bp-paper-bundle-gate:start");
const endAt = layout.indexOf("// bp-paper-bundle-gate:end");
assert.ok(startAt > 0 && endAt > startAt, "root.html.heex carries the bp-paper-bundle-gate markers around the paper hook merge");
const GATE = layout.slice(layout.lastIndexOf("\n", startAt) + 1, layout.indexOf("\n", endAt) + 1);

let failures = 0;
async function check(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

const tick = () => new Promise((r) => setTimeout(r, 0));

// A page at the point the inline Hooks script runs: still parsing.
// `define` lists the elements the bundle has already defined.
function page({ define = [] } = {}) {
  const dom = new JSDOM(`<!doctype html><html><body><div id="w"></div></body></html>`, {
    runScripts: "outside-only",
    url: "http://localhost/",
  });
  const { window } = dom;
  Object.defineProperty(window.document, "readyState", { configurable: true, get: () => "loading" });
  for (const n of define) window.customElements.define(n, class extends window.HTMLElement {});
  const calls = [];
  const impl = (name) => ({
    mounted() { calls.push([name, "mounted", this.el?.id, this.helper?.()]); },
    updated() { calls.push([name, "updated"]); },
    beforeUpdate() { calls.push([name, "beforeUpdate"]); },
    disconnected() { calls.push([name, "disconnected"]); },
    reconnected() { calls.push([name, "reconnected"]); },
    destroyed() { calls.push([name, "destroyed"]); },
    helper() { return "helper"; },
  });
  window.BarkparkPaperEditorHooks = { BarkparkPaperCanvas: impl("canvas"), BarkparkPaperEditor: impl("editor") };
  window.Hooks = { BarkparkFieldCanvas: impl("field"), Desk: impl("desk") };
  window.eval("var Hooks = window.Hooks;\n" + GATE);
  // What LiveView does: copy the definition's own keys onto a hook instance.
  const instance = (name) => Object.assign({ el: window.document.getElementById("w") }, window.Hooks[name]);
  const defineBoth = () => {
    for (const n of ["bp-paper-canvas", "bp-paper-editor"]) {
      if (!window.customElements.get(n)) window.customElements.define(n, class extends window.HTMLElement {});
    }
  };
  return { window, calls, instance, defineBoth };
}

await check("mounted before the bundle ran: nothing runs until both elements are defined", async () => {
  const { calls, instance, defineBoth } = page();
  const hook = instance("BarkparkPaperCanvas");
  hook.mounted();
  hook.updated();
  hook.beforeUpdate();
  await tick();
  assert.deepEqual(calls, [], "no callback reached the implementation before the bundle");
  defineBoth();
  await tick();
  assert.deepEqual(calls, [["canvas", "mounted", "w", "helper"]], "mounted ran once, on the instance, with its helpers");
  hook.updated();
  hook.disconnected();
  hook.reconnected();
  assert.deepEqual(calls.slice(1), [["canvas", "updated"], ["canvas", "disconnected"], ["canvas", "reconnected"]]);
});

await check("one element defined is not enough", async () => {
  const { window, calls, instance } = page();
  instance("BarkparkPaperEditor").mounted();
  window.customElements.define("bp-paper-canvas", class extends window.HTMLElement {});
  await tick();
  assert.deepEqual(calls, []);
  window.customElements.define("bp-paper-editor", class extends window.HTMLElement {});
  await tick();
  assert.deepEqual(calls, [["editor", "mounted", "w", "helper"]]);
});

await check("the bundle already ran: mounted runs at once, synchronously, as before", async () => {
  const { calls, instance } = page({ define: ["bp-paper-canvas", "bp-paper-editor"] });
  instance("BarkparkPaperCanvas").mounted();
  assert.deepEqual(calls, [["canvas", "mounted", "w", "helper"]]);
});

await check("destroyed while waiting: the hook never mounts and is never destroyed", async () => {
  const { calls, instance, defineBoth } = page();
  const hook = instance("BarkparkPaperCanvas");
  hook.mounted();
  hook.destroyed();
  defineBoth();
  await tick();
  assert.deepEqual(calls, []);
});

await check("the bundle failed: window load releases the wait", async () => {
  const { window, calls, instance } = page();
  instance("BarkparkPaperCanvas").mounted();
  window.dispatchEvent(new window.Event("load"));
  assert.deepEqual(calls, [["canvas", "mounted", "w", "helper"]]);
});

await check("hooks mounted while waiting run in mount order, the field canvas too", async () => {
  const { calls, instance, defineBoth } = page();
  instance("BarkparkPaperEditor").mounted();
  instance("BarkparkFieldCanvas").mounted();
  instance("BarkparkPaperCanvas").mounted();
  defineBoth();
  await tick();
  assert.deepEqual(calls.map((c) => c[0]), ["editor", "field", "canvas"]);
});

await check("a hook outside the paper editor is left as it was", async () => {
  const { window, calls, instance } = page();
  instance("Desk").mounted();
  assert.deepEqual(calls, [["desk", "mounted", "w", "helper"]]);
  assert.equal(typeof window.Hooks.Desk.mounted, "function");
});

// Every hook in the real map is either gated (it lives next to the bundle's
// elements) or named here as left alone. A new hook fails this until someone
// decides which: gating a hook that classic fields use loses their edits.
const GATED = [
  "BarkparkPaperAutoSize", "BarkparkPaperEditToggle", "BarkparkTerminalBoundary",
  "BarkparkPaperEditor", "BarkparkPaperCanvas", "BarkparkFieldBlockBridge",
  "BarkparkFigureImageBridge", "BarkparkPaperSortable", "BarkparkPaperContextMenu",
  "BarkparkPaperPaintedCopy",
];
const NOT_GATED = ["BarkparkFieldBridge"];

function realPage(body = "") {
  const dom = new JSDOM(`<!doctype html><html><body>${body}</body></html>`, { runScripts: "outside-only", url: "http://localhost/" });
  const { window } = dom;
  Object.defineProperty(window.document, "readyState", { configurable: true, get: () => "loading" });
  window.eval(fs.readFileSync(HOOKS, "utf8"));
  const real = window.BarkparkPaperEditorHooks;
  window.Hooks = { BarkparkFieldCanvas: { mounted() {} } };
  window.eval("var Hooks = window.Hooks;\n" + GATE);
  return { window, real };
}

await check("the real hook map: each paper hook is gated, BarkparkFieldBridge is not", async () => {
  const { window, real } = realPage();
  const names = Object.keys(real);
  assert.deepEqual([...names].sort(), [...GATED, ...NOT_GATED].sort(), "every hook in bp-paper-editor-hooks.js is classified as gated or not");
  for (const name of GATED) {
    assert.notEqual(window.Hooks[name], real[name], `${name} is wrapped`);
    for (const key of Object.keys(real[name])) {
      assert.ok(key in window.Hooks[name], `${name}.${key} survives the wrap`);
    }
  }
  for (const name of NOT_GATED) assert.equal(window.Hooks[name], real[name], `${name} is the hook itself, not wrapped`);
  assert.notEqual(window.Hooks.BarkparkFieldCanvas.mounted.toString(), "mounted() {}", "BarkparkFieldCanvas is wrapped");
});

await check("a classic field's bp-change before the bundle reaches its hidden input", async () => {
  const { window } = realPage(`
    <form id="f" phx-change="autosave">
      <div id="wrap" phx-update="ignore" phx-hook="BarkparkFieldBridge">
        <input type="hidden" id="bp-mp-ref-hidden-cover" name="doc[cover]" value="" phx-debounce="500" />
        <bp-media-picker id="picker" data-bridge-target="bp-mp-ref-hidden-cover"></bp-media-picker>
      </div>
    </form>`);
  assert.equal(window.customElements.get("bp-paper-canvas"), undefined, "the paper bundle has not run");
  const el = window.document.getElementById("wrap");
  const hook = Object.assign({ el, handleEvent() {}, removeHandleEvent() {}, pushEvent() {}, pushEventTo() {} }, window.Hooks.BarkparkFieldBridge);
  hook.mounted();
  const input = window.document.getElementById("bp-mp-ref-hidden-cover");
  let inputs = 0;
  input.addEventListener("input", () => inputs++);
  window.document.getElementById("picker").dispatchEvent(
    new window.CustomEvent("bp-change", { bubbles: true, detail: { value: "media-42" } }));
  assert.equal(input.value, "media-42", "the hidden input carries the edit");
  assert.equal(inputs, 1, "an input event fires, so phx-change autosave runs");
  hook.destroyed?.();
});

if (failures) {
  console.log(`\n${failures} failing`);
  process.exit(1);
}
console.log("\nall passing");
