// __paper_find_bar.test.mjs — task-c1bf7f10239f73bf: the Studio paper editor
// had the canvas's find engine and no bar, so a writer could not search a
// paper. bp-paper-find-bar.js draws the bar.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-paper-find-bar.js
// under jsdom against stand-in canvases that answer the contract's find
// methods (EMBED-CONTRACT.md, "Find and replace") and record each call.
//
// Run: node ../paper-editor-host-tests/__paper_find_bar.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
globalThis.window = window;
globalThis.document = window.document;
await import("../../priv/static/assets/bp-paper-find-bar.js");
const { document } = window;

const NB = {
  "Find and replace": "Søk og erstatt", "Find": "Søk", "%{index} of %{count}": "%{index} av %{count}",
  "No matches": "Ingen treff", "Previous match": "Forrige treff", "Next match": "Neste treff",
  "Match case": "Skill mellom store og små bokstaver", "Replace with": "Erstatt med", "Replace": "Erstatt",
  "Replace all": "Erstatt alle", "Replaced %{count}": "Erstattet %{count}", "Close": "Lukk", "Show replace": "Vis erstatt",
};

// A canvas that finds `query` in its own text, as the engine does: findSet
// makes the first match active, the steps wrap, replaceAll is one call.
function canvas(text, { editable = true } = {}) {
  const el = document.createElement("bp-paper-canvas");
  el.innerHTML = '<p contenteditable="true"></p>';
  if (!editable) el.setAttribute("editable", "false");
  const calls = [];
  let st = { query: "", caseSensitive: false, index: -1 };
  const count = () => {
    if (!st.query) return 0;
    const hay = st.caseSensitive ? text : text.toLowerCase();
    return hay.split(st.caseSensitive ? st.query : st.query.toLowerCase()).length - 1;
  };
  const state = () => ({ query: st.query, count: count(), index: count() ? Math.min(Math.max(st.index, 0), count() - 1) : -1, caseSensitive: st.caseSensitive });
  const move = (delta) => { const n = count(); if (n) st.index = (state().index + delta + n) % n; return state(); };
  Object.assign(el, {
    calls,
    findState: state,
    findSet(query, opts = {}) { calls.push(["findSet", query, opts]); st = { query, caseSensitive: !!opts.caseSensitive, index: 0 }; return state(); },
    findNext() { calls.push(["findNext"]); return move(1); },
    findPrev() { calls.push(["findPrev"]); return move(-1); },
    findClear() { calls.push(["findClear"]); st = { query: "", caseSensitive: false, index: -1 }; },
    replaceCurrent(to) { calls.push(["replaceCurrent", to]); if (editable && count()) text = text.replace(new RegExp(st.query, "i"), to); return state(); },
    replaceAll(to) {
      calls.push(["replaceAll", to]);
      const replaced = editable ? count() : 0;
      if (replaced) text = text.replace(new RegExp(st.query, st.caseSensitive ? "g" : "gi"), to);
      return { replaced, ...state() };
    },
    focusSelection() { calls.push(["focusSelection"]); el.firstChild.focus(); return true; },
    setText(next) { text = next; el.firstChild.textContent = next; },
  });
  return el;
}

function mount(canvases, strings) {
  document.body.innerHTML = '<button id="outside">Outside</button><div class="bp-paper-editor"></div>';
  const root = document.querySelector(".bp-paper-editor");
  if (strings) root.setAttribute("data-paper-strings", JSON.stringify(strings));
  canvases.forEach((c) => root.appendChild(c));
  return root;
}

const key = (target, init) => {
  const event = new window.KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
  target.dispatchEvent(event);
  return event;
};
const modF = (target) => key(target, { key: "f", ctrlKey: true });
const bar = () => document.querySelector('[data-test-id="paper-find-bar"]');
const part = (name) => bar().querySelector(`[data-find="${name}"]`);
const wait = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
const names = (c) => c.calls.map(([name]) => name);

async function type(text) {
  part("query").value = text;
  part("query").dispatchEvent(new window.Event("input", { bubbles: true }));
  await wait(160);
}

try {
  // Mod+F inside the editor opens the bar; outside it the browser keeps the key.
  {
    const a = canvas("the cat and the dog");
    mount([a]);
    const outside = modF(document.getElementById("outside"));
    assert.equal(outside.defaultPrevented, false, "Mod+F outside the editor is the browser's");
    assert.equal(bar(), null);
    const inside = modF(a.firstChild);
    assert.equal(inside.defaultPrevented, true, "Mod+F inside the editor is taken");
    assert.ok(bar(), "the bar opened");
    assert.equal(document.activeElement, part("query"), "the find input has the focus");
    assert.equal(bar().getAttribute("role"), "search");
    assert.equal(part("count").getAttribute("aria-live"), "polite");
    for (const name of ["query", "replacement", "case", "prev", "next", "toggle", "replace", "replace-all", "close"]) {
      const el = part(name);
      assert.ok(el.getAttribute("aria-label") || el.textContent.trim(), `${name} has a name`);
    }

    // Typing searches, and the count is what findSet's canvas reports.
    await type("the");
    assert.deepEqual(a.calls.at(-1), ["findSet", "the", { caseSensitive: false }]);
    assert.equal(part("count").textContent, "1 of 2");

    // Enter is next, Shift+Enter previous.
    key(part("query"), { key: "Enter" });
    assert.equal(a.calls.at(-1)[0], "findNext");
    assert.equal(part("count").textContent, "2 of 2");
    key(part("query"), { key: "Enter", shiftKey: true });
    assert.equal(a.calls.at(-1)[0], "findPrev");
    assert.equal(part("count").textContent, "1 of 2");

    // Match case goes to the engine as its one option.
    part("case").click();
    assert.equal(part("case").getAttribute("aria-pressed"), "true");
    assert.deepEqual(a.calls.at(-1), ["findSet", "the", { caseSensitive: true }]);
    part("case").click();

    // The paper changed under the bar: the count is read again.
    a.setText("the cat, the dog and the bird");
    await wait(20);
    assert.equal(part("count").textContent, "1 of 3", "the count follows the document");

    // No match says so.
    await type("zebra");
    assert.equal(part("count").textContent, "No matches");
    assert.equal(part("next").disabled, true);

    // The replace row opens from its button. Replace all is one call, and
    // the bar says how many.
    await type("the");
    assert.equal(part("replace-row").hidden, true, "the bar opens as one row");
    part("toggle").click();
    assert.equal(part("replace-row").hidden, false);
    assert.equal(part("toggle").getAttribute("aria-expanded"), "true");
    part("replacement").value = "a";
    a.calls.length = 0;
    part("replace-all").click();
    assert.deepEqual(a.calls.filter(([name]) => name === "replaceAll"), [["replaceAll", "a"]], "one replaceAll");
    assert.equal(part("count").textContent, "Replaced 3");

    // Mod+F again keeps the one bar and takes the focus back to the query.
    part("replacement").focus();
    modF(part("replacement"));
    assert.equal(document.querySelectorAll('[data-test-id="paper-find-bar"]').length, 1);
    assert.equal(document.activeElement, part("query"));

    // Esc clears the highlights, closes, and hands the focus back to the paper.
    a.calls.length = 0;
    key(part("query"), { key: "Escape" });
    assert.equal(bar(), null, "Esc closed the bar");
    assert.deepEqual(names(a), ["findClear", "focusSelection"]);
    assert.equal(document.activeElement, a.firstChild, "the focus is back in the paper");
  }

  // A paper of two runs: one count, and Next walks from one run into the other.
  {
    const a = canvas("one fish");
    const b = canvas("two fish, red fish");
    mount([a, b]);
    modF(b.firstChild);
    await type("fish");
    assert.equal(part("count").textContent, "2 of 3", "the run the caret is in holds the current match");
    assert.equal(b.hasAttribute("data-find-current"), true);
    key(part("query"), { key: "Enter" });
    assert.equal(part("count").textContent, "3 of 3");
    key(part("query"), { key: "Enter" });
    assert.equal(part("count").textContent, "1 of 3", "past the last match is the first run's first");
    assert.equal(a.hasAttribute("data-find-current"), true);
    assert.equal(b.hasAttribute("data-find-current"), false);
    key(part("query"), { key: "g", ctrlKey: true, shiftKey: true });
    assert.equal(part("count").textContent, "3 of 3", "Shift+Mod+G steps back");
    part("replacement").value = "bird";
    part("replace-all").click();
    assert.equal(part("count").textContent, "Replaced 3");
    part("close").click();
    assert.equal(bar(), null);
  }

  // Read-only: no replace row. Norwegian: the words come from the server's map.
  {
    const a = canvas("lese og lese", { editable: false });
    mount([a], NB);
    modF(a.firstChild);
    assert.equal(part("replace-row").hidden, true, "a read-only paper offers no replace");
    assert.equal(part("toggle").hidden, true, "nor the button that opens it");
    assert.equal(bar().getAttribute("aria-label"), "Søk og erstatt");
    assert.equal(part("query").getAttribute("aria-label"), "Søk");
    assert.equal(part("next").getAttribute("aria-label"), "Neste treff");
    await type("lese");
    assert.equal(part("count").textContent, "1 av 2");
    await type("x");
    assert.equal(part("count").textContent, "Ingen treff");
    key(part("query"), { key: "Escape" });
  }

  // An editor with no canvas (the per-block list) has no engine: no bar.
  {
    const root = mount([]);
    root.innerHTML = '<div data-edit-block-id="a"><input id="field"></div>';
    const event = modF(document.getElementById("field"));
    assert.equal(event.defaultPrevented, false);
    assert.equal(bar(), null, "no bar without a canvas");
  }

  console.log("ok paper find bar: opens on Mod+F, counts, steps across runs, replaces, closes; read-only and no-canvas editors covered");
} finally {
  window.close();
}
