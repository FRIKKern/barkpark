// __studio_leave.test.mjs — task-c4b59891f88686e0: Studio asks before it
// leaves a field held under the conflict banner. Runs the TRACKED static
// asset api/priv/static/assets/bp-studio-leave.js under jsdom, over the
// editor form as Studio draws it (`data-studio-held`, LeaveGuard.message/1).
//
// Run: node ../paper-editor-host-tests/__studio_leave.test.mjs
import assert from "node:assert/strict";
import { JSDOM, VirtualConsole } from "./jsdom.mjs";

// A link that is not held back navigates, which jsdom does not do: quiet.
const virtualConsole = new VirtualConsole();
virtualConsole.on("jsdomError", (err) => {
  if (!/navigation/.test(err.message)) throw err;
});

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/w/a/p/b/d/production/studio/post/p1",
  virtualConsole,
});
const { window } = dom;
for (const name of ["document", "Element", "Event", "MouseEvent", "HTMLElement", "Node"]) globalThis[name] = window[name];
globalThis.window = window;
await import("../../priv/static/assets/bp-studio-leave.js");
assert.equal(typeof window.BarkparkStudioLeave, "object", "bp-studio-leave.js loaded");

const QUESTION = "Not saved: Notes. What you typed there will be lost.";
let asked = [];
let answer = false;
window.confirm = (message) => {
  asked.push(message);
  return answer;
};

const page = (held) => {
  document.body.innerHTML =
    `<nav><a id="away" href="/w/a/p/b/d/production/studio/post">Posts</a>` +
    `<a id="same" href="/w/a/p/b/d/production/studio/post/p1?tab=seo">SEO</a>` +
    `<a id="hash" href="#notes">Notes</a><a id="blank" href="/x" target="_blank">x</a></nav>` +
    `<form id="editor-form"${held ? ` data-studio-held="${held}"` : ""}><a id="inside" href="/y">ref</a></form>`;
  asked = [];
};

// A LiveView-style listener after ours: it runs only if the click goes on.
let navigated = 0;
document.addEventListener("click", (e) => {
  if (e.target.closest("a[href]")) navigated++;
});

const click = (id, init = {}) => {
  navigated = 0;
  const e = new window.MouseEvent("click", { bubbles: true, cancelable: true, button: 0, ...init });
  document.getElementById(id).dispatchEvent(e);
  return e;
};

try {
  {
    // Held: a link away asks, naming the field; Cancel keeps the page.
    page(QUESTION);
    answer = false;
    const e = click("away");
    assert.deepEqual(asked, [QUESTION], "the link asks with the form's question");
    assert.equal(e.defaultPrevented, true, "Cancel holds the link back");
    assert.equal(navigated, 0, "Cancel stops the page's own navigation");
  }

  {
    // Held: OK on the question goes on.
    page(QUESTION);
    answer = true;
    const e = click("away");
    assert.deepEqual(asked, [QUESTION]);
    assert.equal(e.defaultPrevented, false);
    assert.equal(navigated, 1, "Leave goes on");
  }

  {
    // Held: links that keep the document, or open elsewhere, do not ask.
    page(QUESTION);
    for (const id of ["same", "hash", "blank", "inside"]) click(id);
    click("away", { metaKey: true });
    assert.deepEqual(asked, [], "own path, hash, new tab, inside the form, a modified click: no question");
  }

  {
    // Nothing held, nothing asked.
    page(null);
    const e = click("away");
    assert.deepEqual(asked, []);
    assert.equal(e.defaultPrevented, false);
    assert.equal(navigated, 1);
  }

  {
    // A full-page link answered Leave: its own unload does not ask again
    // (#28836 r1 review: confirm, then the browser's "Leave site?").
    page(QUESTION);
    answer = true;
    click("away");
    const e = new window.Event("beforeunload", { cancelable: true });
    window.dispatchEvent(e);
    assert.equal(e.defaultPrevented, false, "Leave answered: the unload does not ask twice");
  }

  // Past the Leave answer's moment, the tab's close asks again.
  await new Promise((resolve) => setTimeout(resolve, 2100));

  {
    // The tab's close or reload asks while held, and not otherwise.
    page(QUESTION);
    let e = new window.Event("beforeunload", { cancelable: true });
    window.dispatchEvent(e);
    assert.equal(e.defaultPrevented, true, "held: beforeunload asks");
    page(null);
    e = new window.Event("beforeunload", { cancelable: true });
    window.dispatchEvent(e);
    assert.equal(e.defaultPrevented, false, "nothing held: beforeunload does not ask");
  }

  console.log("studio leave: all checks passed");
} finally {
  window.close();
}
