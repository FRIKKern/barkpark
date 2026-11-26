// __form_confirmed_ok.test.mjs — task-fe9d8741f0641f97: the page keeps, under
// `ok` in `_bp_seen`, the server's digest of the last value it confirmed the
// page shows (`TextConfirmed`). It rides a socket rejoin, which the numbers do
// not. A digest is taken only with its value: a confirm, a pushed value the
// field shows, or the born value the field shows.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-array-focus.js under
// jsdom and dispatches the window events LiveView dispatches for push_event.
//
// Run: node ../paper-editor-host-tests/__form_confirmed_ok.test.mjs
import assert from "node:assert/strict";
import { JSDOM } from "./jsdom.mjs";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const { window } = dom;
for (const name of ["document", "Element", "Event", "MouseEvent", "HTMLElement", "Node", "MutationObserver"]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
await import("../../priv/static/assets/bp-array-focus.js");

function mount(seen, title) {
  document.body.innerHTML =
    `<form id="editor-form"><input type="hidden" name="_bp_seen" value='${JSON.stringify(seen)}'>` +
    `<input type="text" name="doc[title]" value="${title}"></form>`;
}

const seen = () => JSON.parse(document.querySelector('input[name="_bp_seen"]').value);
const fire = (name, detail) => window.dispatchEvent(new window.CustomEvent("phx:" + name, { detail }));

// A confirm sets the digest; other keys stay.
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": 1, "doc[notes]": 9 } }, "a");
fire("bp:form-confirmed", { oks: { "doc[title]": 2 } });
assert.deepEqual(seen(), { v: 2, "doc[title]": 5, ok: { "doc[title]": 2, "doc[notes]": 9 } });

// A confirm on a page drawn with no digests starts the map.
mount({ v: 2 }, "a");
fire("bp:form-confirmed", { oks: { "doc[title]": 3 } });
assert.deepEqual(seen().ok, { "doc[title]": 3 });

// A pushed value the field shows: number and digest taken.
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": 1 } }, "new");
fire("bp:form-remote-values", { values: { "doc[title]": { value: "new", was: "old" } }, seqs: { "doc[title]": [5, 6] }, oks: { "doc[title]": 7 } });
assert.equal(seen()["doc[title]"], 6);
assert.equal(seen().ok["doc[title]"], 7);

// One it does not show (typing not yet sent): neither is taken.
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": 1 } }, "typing");
fire("bp:form-remote-values", { values: { "doc[title]": { value: "new", was: "old" } }, seqs: { "doc[title]": [5, 6] }, oks: { "doc[title]": 7 } });
assert.equal(seen()["doc[title]"], 5);
assert.equal(seen().ok["doc[title]"], 1);

// Born: a field showing the stored value takes number and digest; one typed
// while away keeps its old ones, so its post reads as typed on them.
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": 1 } }, "stored");
fire("bp:form-born", { values: { "doc[title]": "stored" }, seqs: { "doc[title]": 9 }, oks: { "doc[title]": 4 } });
assert.equal(seen()["doc[title]"], 9);
assert.equal(seen().ok["doc[title]"], 4);

mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": 1 } }, "typed away");
fire("bp:form-born", { values: { "doc[title]": "stored" }, seqs: { "doc[title]": 9 }, oks: { "doc[title]": 4 } });
assert.equal(seen()["doc[title]"], 5);
assert.equal(seen().ok["doc[title]"], 1);

// A digest that is not a number is never written.
mount({ v: 2, ok: { "doc[title]": 1 } }, "a");
fire("bp:form-confirmed", { oks: { "doc[title]": "x" } });
assert.equal(seen().ok["doc[title]"], 1);

console.log("form confirmed ok: all checks passed");
