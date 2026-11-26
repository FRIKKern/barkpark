// __studio_leave.test.mjs — task-c4b59891f88686e0: Studio asks before it
// leaves a field held under the conflict banner; a link asks on the server,
// with the desk's dialog (task-5b4914f1b5f21594). Runs the TRACKED static
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
// What reached the server: the bridge button's values at each click
// (`LeaveAsk.bridge/1`; LiveView reads `phx-value-*` when it is clicked).
let sent = [];

const page = (held) => {
  document.body.innerHTML =
    `<nav><a id="away" href="/w/a/p/b/d/production/studio/post?q=1#top">Posts</a>` +
    `<a id="patch" data-phx-link="patch" href="/w/a/p/b/d/production/studio/post/p2">P2</a>` +
    `<a id="same" href="/w/a/p/b/d/production/studio/post/p1?tab=seo">SEO</a>` +
    `<a id="other" href="https://example.org/x">site</a>` +
    `<a id="hash" href="#notes">Notes</a><a id="blank" href="/x" target="_blank">x</a></nav>` +
    `<form id="editor-form"${held ? ` data-studio-held="${held}"` : ""}><a id="inside" href="/y">ref</a></form>` +
    `<button id="studio-leave-ask" type="button" phx-click="studio-leave" hidden></button>` +
    `<a id="go" data-desk-leave-go href="/papers">Leave</a>`;
  sent = [];
  document.getElementById("studio-leave-ask").addEventListener("click", (e) => {
    sent.push({ href: e.target.getAttribute("phx-value-href"), kind: e.target.getAttribute("phx-value-kind") });
  });
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
    // Held: a link away is held back and handed to the server, which asks
    // with the desk's dialog. The browser asks nothing itself.
    page(QUESTION);
    window.confirm = () => assert.fail("window.confirm is no longer the question");
    const e = click("away");
    assert.equal(e.defaultPrevented, true, "the link is held back");
    assert.equal(navigated, 0, "the page's own navigation does not run");
    assert.deepEqual(sent, [{ href: "/w/a/p/b/d/production/studio/post?q=1#top", kind: "" }], "path, query and hash; a page load");
  }

  {
    // Held: a LiveView patch link carries its kind.
    page(QUESTION);
    click("patch");
    assert.deepEqual(sent, [{ href: "/w/a/p/b/d/production/studio/post/p2", kind: "patch" }]);
  }

  {
    // Held: links that keep the document, open elsewhere, or leave the site
    // are not held back.
    page(QUESTION);
    for (const id of ["same", "hash", "blank", "inside", "other"]) click(id);
    click("away", { metaKey: true });
    assert.deepEqual(sent, [], "own path, hash, new tab, inside the form, another site, a modified click: not held back");
  }

  {
    // Nothing held, nothing asked.
    page(null);
    const e = click("away");
    assert.deepEqual(sent, []);
    assert.equal(e.defaultPrevented, false);
    assert.equal(navigated, 1);
  }

  {
    // The dialog's Leave link goes on, and its own unload does not ask
    // again (#28836 r1 review: a full-page link asked twice).
    page(QUESTION);
    const go = click("go");
    assert.equal(go.defaultPrevented, false, "Leave is not held back");
    assert.deepEqual(sent, []);
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
