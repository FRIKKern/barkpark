// note.test.mjs — Barkpark host ownership for the Note shell CSS and LiveView hook.
// Run: node ../paper-editor-host-tests/note.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { JSDOM } from "./jsdom.mjs";
import { check, report } from "../paper-editor/src/smoke/harness.mjs";
import { docToBlocks, runToOps } from "../paper-editor/src/canvas/run-convert.js";

const { window } = new JSDOM("<!doctype html><html><body></body></html>", { pretendToBeVisual: true, url: "http://localhost/" });
globalThis.window = window;
globalThis.document = window.document;
for (const name of ["customElements", "CustomEvent", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
const tick = () => new Promise(resolve => setTimeout(resolve, 20));
async function mountedCheck(name, fn) {
  try { await fn(); check(name, () => {}); }
  catch (error) { check(name, () => { throw error; }); }
}
const original = {
  id: "mounted-note", type: "note", label: "divergent", custom: { keep: [null, 7] },
  slots: {
    label: [{ id: "label-p", type: "paragraph", meta: true, content: [
      { type: "strong", extra: "wrapper", children: [{ type: "text", value: "Shown", extra: "leaf" }] },
    ] }],
    body: [{ type: "paragraph", content: [{ type: "text", value: "Body", custom: true }] }],
    unknown: [{ extra: "keep" }],
  },
};
await import("../paper-editor/src/canvas/index.js");

try {
  check("note server paint uses the live shell stylesheet linked by the root layout", () => {
    const css = path => readFileSync(new URL(path, import.meta.url), "utf8");
    const styles = css("../paper-editor/src/styles.css");
    const shell = css("../../priv/static/assets/bp-paper-editor-shell.css");
    const root = css("../../lib/barkpark_web/layouts/root.html.heex");
    assert.match(root, /<link rel="stylesheet" href=\{BarkparkWeb\.StaticAssets\.path\("bp-paper-editor-shell\.css"\)\} \/>/);
    const noteRules = text => text.split("\n").map(line => line.trim()).filter(line => line.startsWith(".bp-canvas-note") || line.startsWith("@media (max-width: 520px) { .bp-canvas-note"));
    assert.deepEqual(noteRules(styles), noteRules(shell));
  });
  check("note preview nested surface neutralizes only page geometry in live shell CSS", () => {
    const selector = ".bp-paper-surface .bp-canvas-note-preview > .bp-paper-surface";
    const expected = {
      "max-width": "none", "max-inline-size": "none", "min-inline-size": "0",
      "min-height": "0", margin: "0", padding: "0",
    };
    // This rule starts with .bp-paper-surface, outside the noteRules filter above.
    for (const path of ["../../priv/static/assets/bp-paper-editor-shell.css"]) {
      const css = readFileSync(new URL(path, import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
      const rule = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].find(([, head]) => head.trim() === selector);
      assert.ok(rule, `${path}: missing Note-only nested-surface neutralizer`);
      const declarations = Object.fromEntries(rule[2].split(";").filter(part => part.trim()).map(part => part.split(":").map(value => value.trim())));
      assert.deepEqual(declarations, expected, `${path}: geometry only; preserve tokens, font, color and background`);
    }
  });

  await mountedCheck("note readonly paint: installed LiveView hook routes and replays source-bound HTML without saving", async () => {
    const vm = await import("node:vm");
    const hooksSource = readFileSync(new URL("../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8");
    vm.runInContext(hooksSource, vm.createContext({
      window, document, customElements, CustomEvent, CSS: globalThis.CSS,
      FormData: window.FormData, setTimeout, clearTimeout,
    }));
    const unsafe = { ...original, content: [{ type: "text", value: "Dormant fallback" }] };
    const main = document.createElement("main");
    main.className = "bp-paper-editor";
    const wrapper = document.createElement("div");
    wrapper.id = "note-preview-run-0";
    wrapper.dataset.canvasBlocks = JSON.stringify([unsafe]);
    wrapper.dataset.canvasDataset = "production";
    const canvas = document.createElement("bp-paper-canvas");
    wrapper.appendChild(canvas);
    main.appendChild(wrapper);
    document.body.appendChild(main);
    const handlers = new Map();
    const requests = [];
    const hook = {
      ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas, el: wrapper,
      handleEvent: (name, handler) => handlers.set(name, handler),
      pushEvent: (name, payload) => { requests.push({ name, payload }); return Promise.resolve({}); },
    };
    try {
      hook.mounted();
      const html = '<div class="bp-note"><span class="bp-note__k">Shown</span><div class="bp-note__d">Body</div></div>';
      handlers.get("bp:block-html")({ renders: [{ block_id: unsafe.id, source_block: unsafe, html }] });
      const hole = canvas.querySelector("[data-bp-fleet-body]");
      assert.equal(hole.innerHTML, html);
      handlers.get("bp:block-html")({ renders: [{ block_id: "another-note", source_block: unsafe, html: "wrong note" }] });
      assert.equal(hole.innerHTML, html);
      hole.replaceChildren();
      hook.updated();
      assert.equal(hole.innerHTML, html, "existing hook replays cached canonical paint");
      handlers.get("bp:block-html")({ renders: [{ block_id: unsafe.id, source_block: { ...unsafe, custom: "stale" }, html: "stale" }] });
      assert.equal(hole.innerHTML, html, "generic hook cannot bypass node-view source guard");
      assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [unsafe]);
      assert.equal(canvas.flushPendingChanges(), false);
      assert.equal(requests.some(request => request.name === "paper-ops"), false);
    } finally { hook.destroyed(); main.remove(); await tick(); }
  });

  for (const initiallySafe of [false, true]) {
    await mountedCheck(`note conflict recovery: cached latest paint survives ${initiallySafe ? "safe-to-opaque mount" : "opaque source update"}`, async () => {
      const vm = await import("node:vm");
      vm.runInContext(readFileSync(new URL("../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
        vm.createContext({ window, document, customElements, CustomEvent, CSS: globalThis.CSS,
          FormData: window.FormData, setTimeout, clearTimeout }));
      const latest = structuredClone(original);
      latest.custom = { latest: [null, { id: "preserved-metadata" }] };
      latest.slots.body[0].content = [
        { type: "text", value: "Latest ", metadata: true },
        { type: "code", value: "unsafe body", id: "latest-leaf" },
      ];
      const old = initiallySafe
        ? { id: latest.id, type: "note", label: "Old", text: "Old safe body" }
        : { ...structuredClone(latest), custom: { old: true }, label: "old shadow" };
      const main = document.createElement("main");
      main.className = "bp-paper-editor";
      const wrapper = document.createElement("div");
      wrapper.id = "note-conflict-run-0";
      wrapper.dataset.canvasBlocks = JSON.stringify([old]);
      wrapper.dataset.canvasDataset = "production";
      const canvas = document.createElement("bp-paper-canvas");
      wrapper.appendChild(canvas);
      main.appendChild(wrapper);
      document.body.appendChild(main);
      const handlers = new Map();
      const requests = [];
      const hook = {
        ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas, el: wrapper,
        handleEvent: (name, handler) => handlers.set(name, handler),
        pushEvent: (name, payload) => { requests.push({ name, payload }); return Promise.resolve({}); },
      };
      try {
        hook.mounted();
        await tick();
        assert.equal(canvas._editor.state.doc.firstChild.type.name, initiallySafe ? "note" : "bpOpaque");
        const html = '<div class="bp-note"><span class="bp-note__k">Shown</span><div class="bp-note__d">Latest unsafe body</div></div>';
        handlers.get("bp:block-html")({ renders: [{ block_id: latest.id, source_block: latest, html }] });
        assert.equal(canvas.querySelector("[data-bp-fleet-body]")?.innerHTML === html, false,
          "future-source paint stays cached while the old source is installed");
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [old]);

        canvas.resolveConflictWithServerBlocks([latest]);
        await tick();
        const atom = canvas.querySelector('[data-test-id="paper-opaque-note"]');
        assert.equal(atom.getAttribute("data-bp-fleet-id"), latest.id);
        assert.equal(atom.querySelector("[data-bp-fleet-body]").innerHTML, html,
          "mounted/updated node signals readiness only after latest source and identity are installed");
        assert.deepEqual(canvas._editor.state.doc.firstChild.attrs.bpBlock, latest);
        assert.deepEqual(docToBlocks(canvas._editor.getJSON()), [latest]);
        assert.deepEqual(runToOps([latest], canvas._editor.getJSON()), []);
        assert.equal(canvas.flushPendingChanges(), false);
        assert.equal(requests.some(request => request.name === "paper-ops"), false);

        handlers.get("bp:block-html")({ renders: [{ block_id: latest.id, source_block: old, html: "stale" }] });
        hook.updated();
        assert.equal(atom.querySelector("[data-bp-fleet-body]").innerHTML, html);
      } finally { hook.destroyed(); main.remove(); await tick(); }
    });
  }
} finally { window.close(); }
report();
