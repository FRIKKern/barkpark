// task-387501f9ce96c335 — in the LiveView paper canvas a wikilink's hover-card
// Open did nothing: the canvas asks the host (`bp-canvas-open-link`) and the
// BarkparkPaperCanvas hook did not answer. It now opens the linked paper through
// the backlink route (by its doc id, or by title for a hand-typed link) and leaves
// a plain link to the canvas's own new-window open.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { JSDOM } from "jsdom";

const dom = new JSDOM(`
  <main data-paper-doc-key="production:paper:wiki" data-paper-rev="1">
    <div class="bp-paper-editor">
      <div id="paper-canvas-wiki-run-0" phx-hook="BarkparkPaperCanvas" data-canvas-blocks="[]"><bp-paper-canvas></bp-paper-canvas></div>
    </div>
  </main>
`);
const { window } = dom;
Object.defineProperty(window, "crypto", { configurable: true, value: { randomUUID: () => "00000000-0000-4000-8000-000000000001" } });
const context = vm.createContext({
  window, document: window.document, CustomEvent: window.CustomEvent, FormData: window.FormData,
  Date, setTimeout, clearTimeout, customElements: { whenDefined: () => Promise.resolve() },
});
vm.runInContext(
  readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-hooks.js", import.meta.url), "utf8"),
  context,
);

const pushes = [];
const el = window.document.querySelector("#paper-canvas-wiki-run-0");
const canvas = el.querySelector("bp-paper-canvas");
canvas.acknowledgedSaves = true;
const hook = {
  ...window.BarkparkPaperEditorHooks.BarkparkPaperCanvas,
  el,
  handleEvent: () => {},
  pushEvent: (name, payload) => {
    pushes.push({ name, payload: JSON.parse(JSON.stringify(payload)) });
    if (name === "paper-wikilink-search") {
      return Promise.resolve({ results: [{ title: "Other paper", id: "paper-other", type: "paper" }, { title: "Fjord notes", id: "paper-fjord", type: "paper" }] });
    }
    return Promise.resolve({});
  },
};
hook.mounted();
const openLink = (detail) => {
  const ev = new window.CustomEvent("bp-canvas-open-link", { detail, bubbles: true, composed: true, cancelable: true });
  canvas.dispatchEvent(ev);
  return ev;
};
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

let failures = 0;
async function check(name, fn) {
  try { await fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}\n      ${e.message}`); }
}

await check("a wikilink with a doc id opens that paper in this Studio", () => {
  const ev = openLink({ kind: "wikilink", target: "Fjord notes", docId: "paper-fjord", href: null });
  assert.equal(ev.defaultPrevented, true, "the canvas does not try a new window");
  assert.equal(JSON.stringify(pushes.at(-1)), JSON.stringify({ name: "open-backlink", payload: { slug: "paper-fjord", type: "paper" } }));
});

await check("a hand-typed wikilink is opened by its title", async () => {
  pushes.length = 0;
  openLink({ kind: "wikilink", target: "fjord notes", docId: null });
  await tick();
  assert.deepEqual(pushes.map((p) => p.name), ["paper-wikilink-search", "open-backlink"]);
  assert.equal(pushes[1].payload.slug, "paper-fjord");
});

await check("a title nothing matches opens nothing", async () => {
  pushes.length = 0;
  openLink({ kind: "wikilink", target: "No such paper", docId: null });
  await tick();
  assert.deepEqual(pushes.map((p) => p.name), ["paper-wikilink-search"]);
});

await check("a plain link is left to the canvas", () => {
  pushes.length = 0;
  const ev = openLink({ kind: "link", href: "https://example.com", target: null, docId: null });
  assert.equal(ev.defaultPrevented, false);
  assert.equal(pushes.length, 0);
});

// Studio does not load the bundle's bp-paper-editor.css (BP_PAPER_EDITOR_NO_INJECT);
// it links the shell sheet, so the wikilink paint must live there too.
await check("the Studio shell sheet paints a wikilink as a link", () => {
  const css = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
  const rule = css.match(/\.bp-paper-editor span\[data-wikilink\]\s*\{([^}]*)\}/);
  assert.ok(rule, "no span[data-wikilink] rule in bp-paper-editor-shell.css");
  assert.match(rule[1], /color:\s*var\(--paper-accent\)/);
  assert.match(rule[1], /text-decoration:\s*underline/);
});

if (failures) { console.log(`\n${failures} check(s) failed`); process.exit(1); }
console.log("\nall wikilink open checks passed");
process.exit(0);
