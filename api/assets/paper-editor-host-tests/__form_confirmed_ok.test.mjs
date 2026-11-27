// __form_confirmed_ok.test.mjs — task-fe9d8741f0641f97: the page keeps, under
// `ok` in `_bp_seen`, the server's digest of the last value it confirmed the
// page shows (`TextConfirmed`). It rides a socket rejoin, which the numbers do
// not. A digest is taken only with its value: a confirm, a pushed value the
// field shows, or the born value the field shows.
//
// Runs the TRACKED static asset api/priv/static/assets/bp-array-focus.js under
// jsdom and dispatches the window events LiveView dispatches for push_event.
//
// A digest is 64 bits of sha256, as 16 hex characters (task-8a35dcc94956b8aa:
// it was a 27-bit :erlang.phash2 number, where a collision reads a stale page
// as typed on the store).
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
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": "0000000000000001", "doc[notes]": "0000000000000009" } }, "a");
fire("bp:form-confirmed", { oks: { "doc[title]": "0000000000000002" } });
assert.deepEqual(seen(), { v: 2, "doc[title]": 5, ok: { "doc[title]": "0000000000000002", "doc[notes]": "0000000000000009" } });

// A confirm on a page drawn with no digests starts the map.
mount({ v: 2 }, "a");
fire("bp:form-confirmed", { oks: { "doc[title]": "0000000000000003" } });
assert.deepEqual(seen().ok, { "doc[title]": "0000000000000003" });

// A pushed value the field shows: number and digest taken.
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": "0000000000000001" } }, "new");
fire("bp:form-remote-values", { values: { "doc[title]": { value: "new", was: "old" } }, seqs: { "doc[title]": [5, 6] }, oks: { "doc[title]": "0000000000000007" } });
assert.equal(seen()["doc[title]"], 6);
assert.equal(seen().ok["doc[title]"], "0000000000000007");

// One it does not show (typing not yet sent): neither is taken.
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": "0000000000000001" } }, "typing");
fire("bp:form-remote-values", { values: { "doc[title]": { value: "new", was: "old" } }, seqs: { "doc[title]": [5, 6] }, oks: { "doc[title]": "0000000000000007" } });
assert.equal(seen()["doc[title]"], 5);
assert.equal(seen().ok["doc[title]"], "0000000000000001");

// Born: a field showing the stored value takes number and digest; one typed
// while away keeps its old ones, so its post reads as typed on them.
mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": "0000000000000001" } }, "stored");
fire("bp:form-born", { values: { "doc[title]": "stored" }, seqs: { "doc[title]": 9 }, oks: { "doc[title]": "0000000000000004" } });
assert.equal(seen()["doc[title]"], 9);
assert.equal(seen().ok["doc[title]"], "0000000000000004");

mount({ v: 2, "doc[title]": 5, ok: { "doc[title]": "0000000000000001" } }, "typed away");
fire("bp:form-born", { values: { "doc[title]": "stored" }, seqs: { "doc[title]": 9 }, oks: { "doc[title]": "0000000000000004" } });
assert.equal(seen()["doc[title]"], 5);
assert.equal(seen().ok["doc[title]"], "0000000000000001");

// A digest that is not 16 hex characters is never written: a number (the
// old 27-bit digest, from a server before the change), a short or long
// string, an object.
for (const bad of [7, "x", "000000000000001", "00000000000000011", "000000000000000G", { a: 1 }, null]) {
  mount({ v: 2, ok: { "doc[title]": "0000000000000001" } }, "a");
  fire("bp:form-confirmed", { oks: { "doc[title]": bad } });
  assert.equal(seen().ok["doc[title]"], "0000000000000001", `took ${JSON.stringify(bad)}`);
}

console.log("form confirmed ok: all checks passed");
