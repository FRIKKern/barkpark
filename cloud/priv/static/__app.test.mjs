// __app.test.mjs — pure-Node unit harness for the Cloud dashboard SPA (app.js).
//
// app.js is a browser IIFE with no exports, so (like the sheet-grid precedent,
// api/assets/sheet-grid/__hook.test.mjs) we evaluate the SHIPPED file verbatim
// inside a node:vm sandbox and grab its pure helpers through the guarded
// __bpTestHook at the tail of the IIFE. The sandbox reports
// document.readyState === "loading", so init() is only ever REGISTERED (on a
// no-op addEventListener) and no boot path runs — the eval is side-effect-free.
// Zero dependencies; a regression in the committed artifact reds the gate.
//
// Run: node --test __app.test.mjs
//
// CARVE-OUT: rendering, fetch flows, and SSE are browser-coupled and exercised
// live. This harness pins the route/decode/escape helpers — the layer where a
// malformed deep link used to throw URIError inside render() and white-screen
// the dashboard permanently (every hashchange re-threw).

import assert from "node:assert/strict";
import { test } from "node:test";
import vm from "node:vm";
import fs from "node:fs";

// ── vm sandbox: the minimal browser surface the IIFE touches at eval time ───
// Only the tail `document.readyState` check actually executes; the rest are
// inert stubs so any future eager statement fails loudly here, not in prod.

const noop = () => {};
const inertEl = {
  addEventListener: noop,
  removeEventListener: noop,
  setAttribute: noop,
  removeAttribute: noop,
  classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
  style: {},
  hidden: false,
  value: "",
  innerHTML: "",
  textContent: "",
  querySelector: () => null,
  querySelectorAll: () => [],
};
const storage = { getItem: () => null, setItem: noop, removeItem: noop };

const hooks = {};
const sandbox = {
  __bpTestHook(h) { Object.assign(hooks, h); },
  document: {
    readyState: "loading", // keeps init() unbound — DOMContentLoaded never fires
    addEventListener: noop,
    removeEventListener: noop,
    querySelector: () => null,
    querySelectorAll: () => [],
    getElementById: () => null,
    createElement: () => ({ ...inertEl }),
    documentElement: { ...inertEl, getAttribute: () => null },
    body: { ...inertEl, appendChild: noop },
  },
  window: { addEventListener: noop, removeEventListener: noop, open: () => null, matchMedia: () => ({ matches: false, addEventListener: noop }) },
  location: { hash: "", pathname: "/", search: "", origin: "http://localhost" },
  localStorage: storage,
  sessionStorage: storage,
  navigator: {},
  fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }),
  EventSource: function () { return { addEventListener: noop, close: noop }; },
  setTimeout: noop,
  clearTimeout: noop,
  console,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(new URL("./app.js", import.meta.url), "utf8"),
  sandbox,
);

test("the test hook exported the helpers under test", () => {
  assert.equal(typeof hooks.esc, "function");
  assert.equal(typeof hooks.safeDecode, "function");
  assert.equal(typeof hooks.parseHash, "function");
  assert.equal(typeof hooks.relTime, "function");
});

// ── safeDecode: the URIError shield ─────────────────────────────────────────

test("safeDecode decodes a valid escape", () => {
  assert.equal(hooks.safeDecode("a%20b"), "a b");
});

test("safeDecode returns a malformed escape verbatim instead of throwing", () => {
  assert.equal(hooks.safeDecode("abc%"), "abc%"); // truncated deep link
  assert.equal(hooks.safeDecode("%E0%A4%A"), "%E0%A4%A"); // clipped multibyte
});

// ── parseHash: router never throws, malformed ids flow to "not found" ───────

test("parseHash decodes a well-formed instance id", () => {
  sandbox.location.hash = "#instance/x%25y";
  assert.deepEqual({ ...hooks.parseHash() }, { view: "instance", id: "x%y" });
});

test("parseHash on a malformed instance escape does NOT throw (pre-fix: URIError white-screen)", () => {
  sandbox.location.hash = "#instance/x%";
  const r = hooks.parseHash(); // pre-fix this threw before applyRoute() ran
  assert.equal(r.view, "instance");
  assert.equal(r.id, "x%"); // raw id → the existing "not found" empty state
});

test("parseHash on a malformed site escape does NOT throw", () => {
  sandbox.location.hash = "#site/9f3c%";
  const r = hooks.parseHash();
  assert.equal(r.view, "site");
  assert.equal(r.id, "9f3c%");
});

test("parseHash routes a plain tab and falls back to fleet on garbage", () => {
  sandbox.location.hash = "#sites";
  assert.equal(hooks.parseHash().view, "sites");
  sandbox.location.hash = "#garbage";
  assert.equal(hooks.parseHash().view, "fleet");
  sandbox.location.hash = "";
  assert.equal(hooks.parseHash().view, "fleet");
});

// ── esc: the HTML-injection shield used by every renderer ───────────────────

test("esc escapes all five HTML metacharacters", () => {
  assert.equal(hooks.esc("<&\"'>"), "&lt;&amp;&quot;&#39;&gt;");
  assert.equal(hooks.esc(null), "");
});
