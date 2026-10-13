// __reader_tabs.test.mjs — task-df40f0527b20e4fb: the reader's code-tabs and tabs strips
// said role=tab, but ArrowRight did nothing, every tab was a Tab stop, and no panel was a
// tabpanel. reader-tabs.js finishes the pattern on every strip the hook hydrated.
// Run: node src/__reader_tabs.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const { window } = new JSDOM("<!doctype html><body></body>", { url: "http://localhost/" });
globalThis.document = window.document;
const { wireAllTabs } = await import("./reader-tabs.js");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// compose.ex's markup for a three-language code-tabs block, then the hook's hydration
// in miniature: click selects (aria-selected + hidden), and data-hydrated is stamped.
document.body.innerHTML = `
  <div class="bp-code-tabs" data-sync-key="lang">
    <div class="bp-code-tabs__strip" role="tablist">
      <button type="button" class="bp-code-tabs__tab" role="tab" aria-selected="true" data-lang="elixir">Elixir</button>
      <button type="button" class="bp-code-tabs__tab" role="tab" aria-selected="false" data-lang="go">Go</button>
      <button type="button" class="bp-code-tabs__tab" role="tab" aria-selected="false" data-lang="js">JS</button>
    </div>
    <div class="bp-code-tabs__panels">
      <div class="bp-code-tabs__panel" data-lang="elixir"><pre>IO.puts(1)</pre></div>
      <div class="bp-code-tabs__panel" data-lang="go" hidden><pre>fmt.Println(1)</pre></div>
      <div class="bp-code-tabs__panel" data-lang="js" hidden><pre>console.log(1)</pre></div>
    </div>
  </div>
  <div class="bp-code-tabs" data-sync-key="lang">
    <div class="bp-code-tabs__strip" role="tablist">
      <button type="button" class="bp-code-tabs__tab" role="tab" aria-selected="true" data-lang="elixir">Elixir</button>
    </div>
    <div class="bp-code-tabs__panels"><div class="bp-code-tabs__panel" data-lang="elixir"><pre>x</pre></div></div>
  </div>`;
const [container, unhydrated] = document.querySelectorAll(".bp-code-tabs");
const tabs = [...container.querySelectorAll('[role="tab"]')];
const panels = [...container.querySelectorAll(".bp-code-tabs__panel")];
tabs.forEach((tab) =>
  tab.addEventListener("click", () => {
    tabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
    panels.forEach((p) => (p.dataset.lang === tab.dataset.lang ? p.removeAttribute("hidden") : p.setAttribute("hidden", "")));
  }),
);
container.dataset.hydrated = "true";

const key = (el, k) => el.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true }));
const shown = () => panels.findIndex((p) => !p.hasAttribute("hidden"));

check("wires only strips the hook hydrated", () => {
  assert.equal(wireAllTabs(document), 1);
  assert.equal(unhydrated.querySelector('[role="tab"]').getAttribute("aria-controls"), null);
  assert.equal(wireAllTabs(document), 0, "a wired strip is not wired twice");
});

check("each tab names its panel, each panel is a labelled tabpanel", () => {
  tabs.forEach((tab, i) => {
    assert.ok(tab.id);
    assert.equal(tab.getAttribute("aria-controls"), panels[i].id);
    assert.equal(panels[i].getAttribute("role"), "tabpanel");
    assert.equal(panels[i].getAttribute("aria-labelledby"), tab.id);
    assert.equal(panels[i].tabIndex, 0, "Tab from the strip lands in the panel");
  });
});

check("only the selected tab is in the Tab order", () => {
  assert.deepEqual(tabs.map((t) => t.tabIndex), [0, -1, -1]);
});

check("ArrowRight focuses and selects the next tab", () => {
  tabs[0].focus();
  key(tabs[0], "ArrowRight");
  assert.equal(document.activeElement, tabs[1]);
  assert.equal(tabs[1].getAttribute("aria-selected"), "true");
  assert.equal(shown(), 1);
  assert.deepEqual(tabs.map((t) => t.tabIndex), [-1, 0, -1]);
});

check("ArrowLeft wraps, End and Home jump", () => {
  key(tabs[1], "ArrowLeft");
  assert.equal(document.activeElement, tabs[0]);
  key(tabs[0], "ArrowLeft");
  assert.equal(document.activeElement, tabs[2]);
  assert.equal(shown(), 2);
  key(tabs[2], "Home");
  assert.equal(document.activeElement, tabs[0]);
  key(tabs[0], "End");
  assert.equal(document.activeElement, tabs[2]);
});

check("a mouse click keeps the roving tabindex in step", () => {
  tabs[1].click();
  assert.deepEqual(tabs.map((t) => t.tabIndex), [-1, 0, -1]);
});

window.close();
if (failures) {
  console.log(`${failures} failure(s)`);
  process.exit(1);
}
console.log("reader tabs passed");
