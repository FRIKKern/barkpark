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
  assert.ok(Array.isArray(hooks.liveEventTypes));
});

// ── SSE event contract: TYPE_ACTIONS mirrors the shared fixture ─────────────
// __fixtures__/event_types.json is the single cross-language truth for the
// closed SSE vocabulary; events_contract_test.exs asserts the Elixir registry
// against the SAME file. If either side adds a type without the other, one of
// the two gates reds.

test("liveEventTypes (TYPE_ACTIONS keys) sorted equals the shared fixture", () => {
  const fixture = JSON.parse(
    fs.readFileSync(new URL("./__fixtures__/event_types.json", import.meta.url), "utf8"),
  );
  assert.ok(Array.isArray(fixture) && fixture.length > 0);
  assert.deepEqual([...fixture].sort(), fixture, "fixture must be sorted");
  assert.deepEqual([...hooks.liveEventTypes].sort(), fixture);
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

// ── dwb-18: queued (unclaimed) deploy gets an honest pre-claim state ─────────
// A deploy that's enqueued but no builder has claimed it (status "queued", no
// console lines) must NOT render the dark "Waiting for the first log line…"
// build console — that implies an active stream. It gets a calm muted caption
// and no console panel until the first real log line flips it to building.

test("dwb-18: the deploy pre-claim helpers are exported", () => {
  assert.equal(typeof hooks.deployIsPreClaim, "function");
  assert.equal(typeof hooks.deployDetailHtml, "function");
  assert.equal(typeof hooks.deployConsoleHtml, "function");
});

test("dwb-18: a queued row with no console yields the queued caption, not a build console", () => {
  const d = { id: "dep1", status: "queued" };
  const detail = hooks.deployDetailHtml(d, "queued");
  assert.match(detail, /Queued — waiting for a builder to pick this up/);
  assert.match(detail, /deploy-queued/);
  // No dark console panel at all while pre-claim.
  const console = hooks.deployConsoleHtml(d, hooks.deployIsActive("queued"));
  assert.equal(console, "");
  assert.doesNotMatch(console, /Waiting for the first log line/);
});

test("dwb-18: an optional since-hint appears only when inserted_at is present", () => {
  assert.doesNotMatch(hooks.deployDetailHtml({ id: "d", status: "queued" }, "queued"), /since/);
  assert.match(
    hooks.deployDetailHtml({ id: "d", status: "queued", inserted_at: "2026-07-03T10:00:00Z" }, "queued"),
    /\(since /,
  );
});

test("dwb-18: a building row still opens the dark build console", () => {
  const d = { id: "dep2", status: "building" };
  const console = hooks.deployConsoleHtml(d, hooks.deployIsActive("building"));
  assert.match(console, /deploy-console/);
  assert.match(console, /Waiting for the first log line/); // placeholder until first line
  // building is NOT pre-claim → no queued caption
  assert.equal(hooks.deployIsPreClaim(d, "building"), false);
});

test("dwb-18: once the first log line arrives, a still-queued row renders the console normally", () => {
  const d = { id: "dep3", status: "queued", console: [{ at: null, line: "cloning repo" }] };
  assert.equal(hooks.deployIsPreClaim(d, "queued"), false);
  const console = hooks.deployConsoleHtml(d, hooks.deployIsActive("queued"));
  assert.match(console, /cloning repo/);
  assert.doesNotMatch(console, /Waiting for the first log line/);
});

// ── failureCopy: raw builder failure_reason → human copy for the deploy-fail row

test("failureCopy maps a known builder reason to friendly copy", () => {
  assert.equal(
    hooks.failureCopy("artifact_url is empty (P6 bp deploy must populate it)"),
    "The build source couldn't be fetched.",
  );
  assert.equal(
    hooks.failureCopy("unsupported artifact scheme file://"),
    "The build source couldn't be fetched.",
  );
  assert.equal(
    hooks.failureCopy("this site has no build source configured"),
    "This site has no build source yet. Connect a repo or run bp deploy.",
  );
});

test("failureCopy passes an unrecognized reason through unchanged", () => {
  assert.equal(hooks.failureCopy("some brand new builder error"), "some brand new builder error");
  assert.equal(hooks.failureCopy(""), "");
});
