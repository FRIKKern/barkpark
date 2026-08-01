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
import os from "node:os";
import { spawnSync } from "node:child_process";
// fileURLToPath is imported once, further down with the path helpers — ESM
// imports hoist, so the CSS-fixture tests above that line resolve it fine.

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
  URL: URL, // studioLoginHost() parses instance origins with the WHATWG URL API
  URLSearchParams: URLSearchParams, // activateCodeFromSearch() reads ?code= prefill
  fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }),
  EventSource: function () { return { addEventListener: noop, close: noop }; },
  setTimeout: noop,
  clearTimeout: noop,
  setInterval: () => 1, // truthy handle so stopInstanceTicker() clears cleanly
  clearInterval: noop,
  console,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(
  fs.readFileSync(new URL("./app.js", import.meta.url), "utf8"),
  sandbox,
);

// scaffy:zone console-tests (ensure-console-hook-zones) -- stable head anchor
// for NEW test groups: add your `// ── name ──` header + test() blocks
// DIRECTLY BELOW this comment. Registration order is semantics-free:
// node:test runs callbacks after the whole module evaluates, so a group here
// (above the older groups) sees the same populated `hooks` as a tail append.
// Sweeps: move this comment only whole, on its own lines. MARK:zone-console-tests

// ── cch-w10-oauth-exchange-code · THE OAUTH LANDING GATE ───────────────────
// This path had ZERO coverage before this group: `handleOAuthReturn` was not in
// __bpTestHook, and "oauth" appeared in this file exactly twice, both inside one
// sessionRowHtml({origin:"oauth:github"}) assertion. "The harness still passes"
// was therefore a VACUOUS claim about it — nothing here could have gone red.
//
// Two defects are pinned:
//   (1) the fragment carried a live 30-day SESSION TOKEN, put there by a 302's
//       `location` RESPONSE HEADER. It now carries a one-time exchange code that
//       this module POSTs away. The client half of that is: bootOAuth actually
//       makes the exchange call and only then lands a session.
//   (2) `location.hash = "#fleet"` was a history PUSH, so /#oauth=<live token>
//       stayed one Back press away for the life of the tab. The scrub is now
//       history.replaceState, and it happens BEFORE the network hop.
//
// Every test below is RED on unmodified origin/main — the hooks do not exist
// there at all, so the typeof assertions fail first and by name.

// Distinct backing maps for localStorage and sessionStorage. The module-level
// `storage` stub shares ONE inert object between them; setSession(s, true) writes
// localStorage and then calls sessionStorage.removeItem(STORE), so a shared map
// would silently delete the session this group is asserting.
function memStore() {
  const m = new Map();
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
  };
}

// A DOM just wide enough for bootOAuth: the auth screen + login card (the pending
// state hides the card and appends a sibling), and a toast stack that RECORDS
// instead of rendering, so the failure copy is assertable.
function oauthDom() {
  const toasts = [];
  const mk = (tag) => ({
    tagName: tag, id: "", className: "", hidden: false, children: [], attrs: {},
    parentNode: null, innerHTML: "",
    setAttribute(k, v) { this.attrs[k] = v; if (k === "id") this.id = v; },
    getAttribute(k) { return this.attrs[k] != null ? this.attrs[k] : null; },
    appendChild(n) { n.parentNode = this; this.children.push(n); return n; },
    removeChild(n) { this.children = this.children.filter((c) => c !== n); n.parentNode = null; return n; },
    querySelector() { return { addEventListener() {} }; },
    addEventListener() {},
  });

  const authScreen = mk("main"); authScreen.id = "auth-screen"; authScreen.hidden = true;
  const center = mk("div");
  const card = mk("div"); card.id = "login-card";
  center.appendChild(card);
  authScreen.appendChild(center);

  const stack = mk("div"); stack.id = "toast-stack";
  stack.appendChild = (n) => { n.parentNode = stack; toasts.push(n); return n; };

  const byId = { "auth-screen": authScreen, "login-card": card, "toast-stack": stack };
  const doc = {
    querySelector(sel) {
      const id = String(sel).replace(/^#/, "");
      if (id === "oauth-pending") return center.children.find((c) => c.id === "oauth-pending") || null;
      return byId[id] || null;
    },
    getElementById(id) { return doc.querySelector("#" + id); },
    createElement: mk,
  };
  return { document: doc, authScreen, card, center, toasts };
}

// A location whose `hash` SETTER is recorded. That is the whole point: the old
// code assigned location.hash (a history PUSH); the new code must never touch it.
function recordingLocation(hash) {
  const assigned = [];
  const loc = {
    pathname: "/", search: "", origin: "http://localhost", _hash: hash,
    get hash() { return this._hash; },
    set hash(v) { assigned.push(v); this._hash = v; },
  };
  return { loc, assigned };
}

function recordingHistory() {
  const calls = [];
  return {
    calls,
    replaceState(_s, _t, url) { calls.push(["replace", url]); },
    pushState(_s, _t, url) { calls.push(["push", url]); },
  };
}

function fetchStub(status, payload) {
  const calls = [];
  const fn = (path, opts) => {
    calls.push({ path, opts });
    return Promise.resolve({
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => "application/json" },
      json: () => Promise.resolve(payload),
    });
  };
  fn.calls = calls;
  return fn;
}

// The vm realm has its own Object.prototype, so a hook's return value is never
// reference-equal to a locally-built literal under deepStrictEqual. Re-home the
// shape. (This file's other `plain` re-homer lives ~6000 lines down and is NOT
// reusable from here: the module has a top-level `await import`, so node:test
// starts running the groups above it before that declaration is initialised —
// reaching for it reds with a TDZ ReferenceError, measured.)
const oauthPlain = (o) => (o == null ? o : { ...o });

// Swap the sandbox globals bootOAuth reads, run it to completion, restore.
async function driveBootOAuth({ hash, status, payload }) {
  // `oauthJustLanded` is MODULE state in the IIFE and every drive below shares one
  // evaluated app.js — drain it so each test starts from a known false rather
  // than inheriting the previous test's success.
  hooks.handleOAuthReturn();

  const saved = {
    location: sandbox.location, history: sandbox.history, fetch: sandbox.fetch,
    document: sandbox.document, localStorage: sandbox.localStorage,
    sessionStorage: sandbox.sessionStorage,
  };
  const { loc, assigned } = recordingLocation(hash);
  const history = recordingHistory();
  const fetch = fetchStub(status, payload);
  const dom = oauthDom();
  const local = memStore();
  const session = memStore();

  sandbox.location = loc;
  sandbox.history = history;
  sandbox.fetch = fetch;
  sandbox.document = dom.document;
  sandbox.localStorage = local;
  sandbox.sessionStorage = session;

  // Snapshot the pending state at the moment of the hop — renderOAuthPending(false)
  // tears it down before bootOAuth resolves, so it is unobservable afterwards.
  let pendingDuringHop = null;
  let cardHiddenDuringHop = null;
  const wrapped = (...args) => {
    pendingDuringHop = dom.document.querySelector("#oauth-pending");
    cardHiddenDuringHop = dom.card.hidden;
    return fetch(...args);
  };
  wrapped.calls = fetch.calls;
  sandbox.fetch = wrapped;

  let renderCalls = 0;
  try {
    await new Promise((resolve) => {
      hooks.bootOAuth(() => { renderCalls++; resolve(); });
    });
  } finally {
    Object.assign(sandbox, saved);
  }
  return {
    assigned, history, fetch: wrapped, dom, local, session, renderCalls,
    pendingDuringHop, cardHiddenDuringHop,
  };
}

test("cch-w10: the landing gate is exported (RED on origin/main, where it does not exist)", () => {
  assert.equal(typeof hooks.oauthReturnFromHash, "function", "oauthReturnFromHash must be hookable");
  assert.equal(typeof hooks.bootOAuth, "function", "bootOAuth must be hookable");
  assert.equal(typeof hooks.handleOAuthReturn, "function", "handleOAuthReturn must be hookable");
});

test("cch-w10: oauthReturnFromHash classifies code / error / not-an-oauth-return", () => {
  const f = (h) => oauthPlain(hooks.oauthReturnFromHash(h));

  assert.deepEqual(f("#oauth_code=abc123&team=t-1"), { code: "abc123", team: "t-1" });
  assert.deepEqual(f("oauth_code=abc123"), { code: "abc123", team: null }, "leading # is optional");
  assert.deepEqual(f("#oauth_error=oauth_failed"), { error: true });

  // Not an OAuth return: every ordinary route, and the EMPTY hash.
  assert.equal(f(""), null);
  assert.equal(f(null), null);
  assert.equal(f("#fleet"), null);
  assert.equal(f("#billing"), null);

  // THE OLD FRAGMENT IS NO LONGER HONOURED. A stale /#oauth=<session token> —
  // e.g. a bookmarked or back-buttoned pre-cch-w10 URL — must classify as "not an
  // OAuth return", never as a session to install. This assertion is the one that
  // would red if someone re-added an `oauth=` branch "for compatibility".
  assert.equal(f("#oauth=live-session-token&team=t-1"), null);

  // Percent-encoding survives (the code is url-safe base64, but team ids and any
  // future value must not corrupt).
  assert.deepEqual(f("#oauth_code=a%2Bb&team=t%201"), { code: "a+b", team: "t 1" });
});

test("cch-w10: bootOAuth exchanges the code for a session and defers render until it lands", async () => {
  const r = await driveBootOAuth({
    hash: "#oauth_code=one-time-code&team=t-from-fragment",
    status: 200,
    payload: { token: "real-session-token", team_id: "t-from-server" },
  });

  // (1) THE EXCHANGE ACTUALLY HAPPENS — one POST, to the exchange route, carrying
  // the code in the BODY. On origin/main there is no network hop at all.
  assert.equal(r.fetch.calls.length, 1, "exactly one exchange call");
  assert.equal(r.fetch.calls[0].path, "/v1/auth/oauth/exchange");
  assert.equal(r.fetch.calls[0].opts.method, "POST");
  assert.deepEqual(JSON.parse(r.fetch.calls[0].opts.body), { code: "one-time-code" });
  // Unauthenticated by construction: there is no session yet to send.
  assert.equal(r.fetch.calls[0].opts.headers.Authorization, undefined);

  // (2) The session that lands is the SERVER's token, not anything off the URL.
  const stored = JSON.parse(r.local.getItem("bpcloud.session"));
  assert.equal(stored.token, "real-session-token");
  assert.equal(stored.team_id, "t-from-server", "the server's team wins over the fragment's");
  // setSession(s, true) persists — and must not ALSO leave a sessionStorage copy.
  assert.equal(r.session.getItem("bpcloud.session"), null);

  // (3) render() ran exactly once, AFTER the exchange resolved.
  assert.equal(r.renderCalls, 1);

  // (4) The one-shot flag: true on the first read, false forever after, so a later
  // render() cannot re-fire the /new and /activate bounces.
  assert.equal(hooks.handleOAuthReturn(), true);
  assert.equal(hooks.handleOAuthReturn(), false);
});

test("cch-w10: the credential-bearing URL is REPLACED, never PUSHED, and before the hop", async () => {
  const r = await driveBootOAuth({
    hash: "#oauth_code=one-time-code&team=t-1",
    status: 200,
    payload: { token: "real-session-token", team_id: "t-1" },
  });

  // THE HISTORY LEAK. `location.hash = "#fleet"` pushes a new entry, leaving the
  // credential-bearing URL recoverable with the Back button. Reverting the scrub
  // to that line reds this test on the FIRST assertion.
  assert.deepEqual(r.assigned, [], "location.hash must never be assigned (that is a history PUSH)");
  assert.deepEqual(r.history.calls, [["replace", "/#fleet"]], "exactly one replaceState, to /#fleet");
  assert.ok(!r.history.calls.some((c) => c[0] === "push"), "never pushState either");

  // ORDER: the scrub is recorded before the fetch call is made, so a slow or
  // failed exchange never leaves the code sitting in the address bar.
  assert.ok(r.pendingDuringHop, "the pending state was mounted before the hop");
});

test("cch-w10: a loading state covers the round trip, and is torn down after it", async () => {
  const r = await driveBootOAuth({
    hash: "#oauth_code=one-time-code",
    status: 200,
    payload: { token: "t", team_id: null },
  });

  // DURING: the auth screen shows a "Signing you in…" panel and the login form is
  // hidden — without this the user stares at a LOGGED-OUT login card while their
  // sign-in is still succeeding.
  assert.match(r.pendingDuringHop.innerHTML, /Signing you in/);
  assert.equal(r.pendingDuringHop.getAttribute("role"), "status");
  assert.equal(r.pendingDuringHop.getAttribute("aria-live"), "polite");
  assert.equal(r.cardHiddenDuringHop, true, "the login card is hidden while the exchange is in flight");
  assert.equal(r.dom.authScreen.hidden, false, "the auth screen is shown so the panel is visible");

  // AFTER: torn down, and the login card is restored (a failed exchange must land
  // the user on a usable form, not an empty screen).
  assert.equal(r.dom.document.querySelector("#oauth-pending"), null);
  assert.equal(r.dom.card.hidden, false);
});

test("cch-w10: a refused exchange lands NO session and reuses the existing generic copy", async () => {
  const r = await driveBootOAuth({
    hash: "#oauth_code=burned-or-expired",
    status: 401,
    payload: { error: "invalid_code" },
  });

  // Nothing is installed off a refusal — the whole point of a burnable code.
  assert.equal(r.local.getItem("bpcloud.session"), null);
  assert.equal(r.session.getItem("bpcloud.session"), null);
  assert.equal(hooks.handleOAuthReturn(), false, "the one-shot flag stays false");

  // render() still runs, so the user lands on the auth screen rather than a
  // permanent spinner.
  assert.equal(r.renderCalls, 1);
  assert.equal(r.dom.card.hidden, false, "the login form is back");
  assert.equal(r.dom.document.querySelector("#oauth-pending"), null);

  // NO NEW ERROR COPY: byte-identical to the pre-existing oauth_error toast, so a
  // burned / expired / rate-limited code cannot be told apart from a refused
  // consent by reading the screen.
  assert.equal(r.dom.toasts.length, 1);
  assert.match(r.dom.toasts[0].innerHTML, /Sign-in failed/);
  assert.match(r.dom.toasts[0].innerHTML, /We couldn&#39;t complete that sign-in\. Please try again\./);
});

test("cch-w10: an /#oauth_error landing scrubs by REPLACE and never calls the exchange", async () => {
  const r = await driveBootOAuth({
    hash: "#oauth_error=oauth_failed",
    status: 200,
    payload: { token: "must-not-be-used" },
  });

  assert.equal(r.fetch.calls.length, 0, "no code to exchange — no network hop");
  assert.deepEqual(r.assigned, [], "location.hash must never be assigned");
  assert.deepEqual(r.history.calls, [["replace", "/"]]);
  assert.equal(r.local.getItem("bpcloud.session"), null);
  assert.equal(r.renderCalls, 1);
  assert.equal(hooks.handleOAuthReturn(), false);
  assert.equal(r.dom.toasts.length, 1);
  assert.match(r.dom.toasts[0].innerHTML, /Sign-in failed/);
});

test("cch-w10: an ordinary boot pays nothing — no history write, no fetch, straight to render", async () => {
  const r = await driveBootOAuth({ hash: "#fleet", status: 200, payload: {} });

  assert.equal(r.fetch.calls.length, 0);
  assert.deepEqual(r.history.calls, []);
  assert.deepEqual(r.assigned, []);
  assert.equal(r.renderCalls, 1, "render still runs, synchronously enough to be the only paint");
  assert.equal(hooks.handleOAuthReturn(), false);
});

test("cch-w10: a network failure is a refusal, not a crash or a half-session", async () => {
  // api() catches a rejected fetch into { ok:false, status:0 } — pin that the gate
  // treats it exactly like a 401 rather than throwing inside the boot path (which
  // would leave the console on a permanent "Signing you in…").
  const saved = {
    location: sandbox.location, history: sandbox.history, fetch: sandbox.fetch,
    document: sandbox.document, localStorage: sandbox.localStorage,
    sessionStorage: sandbox.sessionStorage,
  };
  hooks.handleOAuthReturn(); // drain the shared one-shot flag (see driveBootOAuth)
  const { loc } = recordingLocation("#oauth_code=abc");
  const dom = oauthDom();
  const local = memStore();
  sandbox.location = loc;
  sandbox.history = recordingHistory();
  sandbox.fetch = () => Promise.reject(new Error("offline"));
  sandbox.document = dom.document;
  sandbox.localStorage = local;
  sandbox.sessionStorage = memStore();

  try {
    await new Promise((resolve) => hooks.bootOAuth(resolve));
  } finally {
    Object.assign(sandbox, saved);
  }

  assert.equal(local.getItem("bpcloud.session"), null);
  assert.equal(hooks.handleOAuthReturn(), false);
  assert.equal(dom.card.hidden, false, "the login form is back — not a stranded spinner");
  assert.equal(dom.toasts.length, 1);
  assert.match(dom.toasts[0].innerHTML, /Sign-in failed/);
});

test("cch-w10: init() hands the boot to bootOAuth — render() is no longer the tail call", () => {
  // WIRING TRIPWIRE. Everything above drives bootOAuth directly, so all of it
  // stays green if the gate is built and never called. init() is unreachable from
  // this harness (the sandbox reports readyState "loading"), so the call site is
  // asserted in the SOURCE — and by shape, not by one literal spelling.
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  assert.match(src, /\n\s*bootOAuth\(render\);\n/, "init()'s tail must be bootOAuth(render)");

  // And render() must still be SYNCHRONOUS — its 8 call sites were not changed,
  // so an `async function render` would silently make every one of them return a
  // pending promise instead of having painted.
  assert.match(src, /\n\s*function render\(\) \{/, "render() stays a plain synchronous function");
  assert.ok(!/async function render\(/.test(src), "render() must not become async");
});

// ── cch-bl-mockjs-revoke-stateless · THE BROWSER PREVIEW'S REVOKE ───────────
// scenarios.mjs models the two session DELETEs statefully, but ONLY when the
// caller hands route() its optional 4th arg — a per-boot mutable bag. smoke.mjs
// (the node oracle) passes one; mock.js (the BROWSER preview, and therefore the
// harness shoot.sh photographs) did not. Consequence: clicking Revoke toasted
// "Device signed out" and app.js's immediate loadSessions() refetch returned a
// byte-identical list. A success claim with no post-condition read — the epic
// predicate, in a browser, on a destructive verb.
//
// Nothing in this repo would have gone red on a revert: __app.test.mjs never
// read mock.js, modal-oracle.mjs has zero revoke coverage, and neither it nor
// smoke.mjs is run by any workflow. This group is therefore in TWO halves:
//   HALF 1 (CONTRACT) — route()'s own semantics, imported directly: stateless
//     DELETE leaves the list at N; with a bag it drops to N-1.
//   HALF 2 (WIRING, the tripwire) — mock.js actually PASSES a bag. It scans the
//     call's argument list with a balanced-paren walk rather than matching one
//     literal spelling, so a rename or a reformat cannot make it vacuously
//     green, and it throws by name if the call site disappears entirely.
// Half 2 is the half that goes red on clean origin/main (3 args).
const { route: previewRoute } = await import("./__preview__/scenarios.mjs");
const MOCK_JS_SRC = fs.readFileSync(new URL("./__preview__/mock.js", import.meta.url), "utf8");

// Split the argument list of the FIRST call to `<needle>` in `src`, walking
// balanced delimiters and skipping string/template/comment content, so nesting
// (`route(a, f(b, c), d)`) and reformatting do not miscount. Returns the trimmed
// top-level argument texts. THROWS if the call site is absent — the failure mode
// a silent regex would have turned into a vacuous pass.
function callArgs(src, needle) {
  const at = src.indexOf(needle);
  assert.ok(at !== -1, `call site "${needle}" not found in mock.js — the tripwire cannot certify a call it cannot locate`);
  let i = src.indexOf("(", at) + 1;
  const args = [];
  let depth = 0, cur = "", quote = null;
  for (; i < src.length; i++) {
    const c = src[i];
    if (quote) {
      if (c === "\\") { cur += c + src[++i]; continue; }
      if (c === quote) quote = null;
      cur += c;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { quote = c; cur += c; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2);
      // An unterminated block comment would send indexOf to -1, i to 0, and this
      // walk into an infinite loop — a hung test is worse than a red one.
      assert.ok(end !== -1, `unterminated block comment while scanning "${needle}" in mock.js`);
      i = end + 1;
      continue;
    }
    if (c === "(" || c === "[" || c === "{") depth++;
    if (c === ")" && depth === 0) { args.push(cur.trim()); break; }
    if (c === ")" || c === "]" || c === "}") depth--;
    if (c === "," && depth === 0) { args.push(cur.trim()); cur = ""; continue; }
    cur += c;
  }
  assert.ok(i < src.length, `unterminated argument list for "${needle}" in mock.js`);
  return args;
}

// HALF 1 — the CONTRACT, straight off scenarios.mjs. Both scenarios are pinned
// because account-modal-revoke is the one auto-enrolled in shoot.sh's screenshot
// set (the account-modal name prefix), i.e. the fixture the published evidence
// is taken through.
for (const [scen, n] of [["account-modal", 2], ["account-modal-revoke", 4]]) {
  test(`scenarios.route(${scen}): a DELETE without a state bag leaves the list at N; with one it drops to N-1`, () => {
    const list = (state) => previewRoute(scen, "GET", "/v1/account/sessions", state).body.sessions;

    // The fixture is the size this check assumes (a shrunken fixture would make
    // the -1 assertion below pass for the wrong reason).
    assert.equal(list(undefined).length, n, `${scen} must carry ${n} sessions`);

    // STATELESS (what mock.js used to be): 200, and the following GET is unchanged.
    const victim = list(undefined).find((s) => !s.current);
    const stateless = previewRoute(scen, "DELETE", `/v1/account/sessions/${victim.id}`, undefined);
    assert.equal(stateless.status, 200, "the revoke reports success");
    assert.equal(list(undefined).length, n, "…over a list that never changed — the false green");

    // STATEFUL: the same 200, and the post-condition read actually shrinks.
    const bag = {};
    assert.equal(previewRoute(scen, "DELETE", `/v1/account/sessions/${victim.id}`, bag).status, 200);
    assert.equal(previewRoute(scen, "GET", "/v1/account/sessions", bag).body.sessions.length, n - 1);

    // A second revoke of the SAME id is now an honest 404, not a second success.
    assert.equal(previewRoute(scen, "DELETE", `/v1/account/sessions/${victim.id}`, bag).status, 404);

    // Sign-out-everywhere keeps the acting session and reports the real count.
    const others = previewRoute(scen, "GET", "/v1/account/sessions", bag).body.sessions.filter((s) => !s.current);
    const all = previewRoute(scen, "DELETE", "/v1/account/sessions", bag);
    assert.equal(all.body.revoked, others.length, "the toast's count is the number actually revoked");
    assert.equal(previewRoute(scen, "GET", "/v1/account/sessions", bag).body.sessions.length, 1);
  });
}

test("mock.js WIRING TRIPWIRE: the browser preview hands route() a per-boot state bag (red on a 3-arg revert)", () => {
  const args = callArgs(MOCK_JS_SRC, ".route(");
  assert.equal(args.length, 4, `mock.js called route() with ${args.length} args — a 3-arg call gets no state bag, so every DELETE is a stateless no-op that still answers 200`);

  // The 4th arg is a bare identifier (not an inline `{}`, which would be a FRESH
  // bag per request and therefore still stateless across the refetch).
  const bag = args[3];
  assert.match(bag, /^[A-Za-z_$][A-Za-z0-9_$]*$/, `route()'s state argument must be a bare identifier, got ${JSON.stringify(bag)}`);

  // …and that identifier is declared ONCE, as an empty object literal, at a
  // scope outside the fetch handler — per page load, mirroring smoke.mjs.
  const decl = new RegExp(`\\b(?:var|let|const)\\s+${bag}\\s*=\\s*\\{\\s*\\}`);
  assert.match(MOCK_JS_SRC, decl, `${bag} must be declared as an empty object literal (the per-boot bag)`);

  // route() hands back the LIVE state array by reference, so the body must be
  // copied before the app sees it — otherwise a body rendered earlier silently
  // rewrites itself on the next revoke.
  const body = callArgs(MOCK_JS_SRC, "jsonResponse(res.status");
  assert.notEqual(body[1], "res.body", "the routed body must be snapshotted, not handed over by reference");
});

// ── cch-w1-refetch-storm · THE REQUEST COUNTER ──────────────────────────────
// Overview binds to five reads. Every SSE tick used to re-run the whole loader:
// 1 cold boot + 7 fleet ticks = 40 requests, 8 per endpoint — measured in
// production and reproduced from source. The carve-out at the top of this file
// says fetch flows and SSE are browser-coupled; that carve-out is exactly why
// the storm survived a 640-test harness, so this group crosses it deliberately
// and counts the requests ONE event costs.
//
// THE VACUOUS-GREEN TRAP (charter D4): loadOverview() short-circuits to the
// welcome runway on an EMPTY fleet, before the four other reads. A fixture with
// no instances would assert a small number and pass forever while the storm
// raged for every real user. OVERVIEW_FLEET carries two instances, and the
// first test in this group asserts that it does.

// One healthy box + one degraded box: non-empty (D4) and it populates BOTH the
// attention queue and the instances grid, so a scoped repaint has real markup
// to rebuild rather than an empty branch.
const OVERVIEW_FLEET = [
  { id: "bp-1", name: "alpha", host: "alpha.example", health_status: "up", agent_status: "online" },
  { id: "bp-2", name: "bravo", host: "bravo.example", health_status: "down", agent_status: "offline" },
];
const OVERVIEW_ENDPOINTS = [
  "/v1/barkparks", "/v1/audit?limit=5", "/v1/usage/summary", "/v1/subscription", "/v1/onboarding",
];

// A trial subscription with an INCOMPLETE onboarding fold, so overviewStatePick
// returns "runway" and the state band renders real markup — a scoped onboarding
// refresh that fetched but never repainted would look identical to a fix
// otherwise.
function overviewOnboarding(publishedDone) {
  return {
    completed: false,
    steps: [
      { key: "subscription", done: true },
      { key: "instance", done: true },
      { key: "published_doc", done: !!publishedDone },
    ],
  };
}

function overviewNet() {
  const paths = [];
  // `state` is the MUTABLE half of the fixture, so a test can flip what the
  // server would say between ticks:
  //   state.onboarding   — a step self-heals
  //   state.subscription — trialing → past_due (the band/chip transition)
  //   state.fail         — a Set of paths that answer 503 instead of 200, so a
  //                        BACKGROUND refetch failure is expressible at all
  //                        (every path was unconditionally ok before).
  const state = {
    onboarding: overviewOnboarding(false),
    subscription: { status: "trialing", plan: "trial" },
    fail: new Set(),
  };
  const bodyFor = (path) => {
    if (path === "/v1/barkparks") return { barkparks: OVERVIEW_FLEET };
    if (path.startsWith("/v1/audit")) return { events: [] };
    if (path === "/v1/usage/summary") return { usage: { team: { instances: { quota: 5 } }, instances: [] } };
    if (path === "/v1/subscription") return { subscription: state.subscription };
    if (path === "/v1/onboarding") return { onboarding: state.onboarding };
    return {};
  };
  return {
    paths, state,
    fetch(path) {
      const p = String(path);
      paths.push(p);
      const down = state.fail.has(p);
      return Promise.resolve({
        ok: !down, status: down ? 503 : 200,
        headers: { get: (n) => (String(n).toLowerCase() === "content-type" ? "application/json" : null) },
        json: () => Promise.resolve(down ? { error: "unavailable" } : bodyFor(p)),
      });
    },
    reset() { paths.length = 0; },
    count(endpoint) { return paths.filter((p) => p === endpoint).length; },
    tally() { return OVERVIEW_ENDPOINTS.map((e) => this.count(e)); },
  };
}

// A flat id-addressed DOM: enough for loadOverview's mounts. Setting innerHTML
// DESTROYS the nodes the previous markup mounted and registers the new ones —
// mirroring the real DOM, so carrying the activity digest across a scoped
// rebuild is genuinely exercised rather than trivially true.
function overviewDom() {
  const nodes = new Map();
  const noop2 = () => {};
  const make = (id) => {
    const el = {
      id, _html: "", _owned: [], hidden: false, textContent: "",
      get innerHTML() { return this._html; },
      set innerHTML(v) {
        this._owned.forEach((childId) => nodes.delete(childId));
        this._owned = [];
        this._html = String(v);
        const re = /id="([^"]+)"/g;
        let m;
        while ((m = re.exec(this._html))) {
          this._owned.push(m[1]);
          nodes.set(m[1], make(m[1]));
        }
      },
      addEventListener: noop2, removeEventListener: noop2,
      setAttribute: noop2, removeAttribute: noop2, getAttribute: () => null,
      querySelector: () => null, querySelectorAll: () => [],
      classList: { add: noop2, remove: noop2, toggle: noop2, contains: () => false },
      style: {},
    };
    return el;
  };
  ["overview-body", "overview-greeting", "overview-sub", "overview-chips", "overview-launch"]
    .forEach((id) => nodes.set(id, make(id)));
  // ONE document for the whole console, not two: the topbar chips
  // (#billing-chip, #liveness-chip) and the Overview mounts have to be reachable
  // from the SAME `document`, or the honesty this group asserts — "the chip says
  // X while the body says Y" — is unassertable by construction. fakeDom() (below,
  // hoisted) already owns the richer element model those chips need (children,
  // insertBefore, class-selector querySelector), so this composes with it rather
  // than forking a second one.
  const topbar = fakeDom();
  return {
    nodes,
    topbarRight: topbar.topbarRight,
    // The chip elements, by id, once the SPA has mounted them.
    chip: (id) => topbar.document.getElementById(id),
    document: {
      readyState: "complete",
      addEventListener: noop2, removeEventListener: noop2,
      querySelector: (sel) => (sel.startsWith("#")
        ? nodes.get(sel.slice(1)) || null
        : topbar.document.querySelector(sel)),
      querySelectorAll: () => [],
      getElementById: (id) => nodes.get(id) || topbar.document.getElementById(id),
      createElement: (t) => topbar.document.createElement(t),
      documentElement: make(""), body: make(""),
    },
  };
}

async function settleOverview() {
  for (let i = 0; i < 4; i += 1) await new Promise((r) => setImmediate(r));
}

async function overviewHarness(run) {
  const priorDoc = sandbox.document;
  const priorFetch = sandbox.fetch;
  const priorHash = sandbox.location.hash;
  const dom = overviewDom();
  const net = overviewNet();
  sandbox.document = dom.document;
  sandbox.fetch = net.fetch;
  sandbox.location.hash = "#overview";
  hooks.overviewData.list = null;
  hooks.overviewData.usage = null;
  hooks.overviewData.onboarding = null;
  try {
    // Cold paint first: it fills the snapshot a scoped refresh repaints from.
    hooks.loadOverview();
    await settleOverview();
    await run({ net, dom });
  } finally {
    sandbox.document = priorDoc;
    sandbox.fetch = priorFetch;
    sandbox.location.hash = priorHash;
    hooks.overviewData.list = null;
    hooks.overviewData.usage = null;
    hooks.overviewData.onboarding = null;
  }
}

test("cch-w1: the fixture carries instances — an empty fleet would make this whole group vacuous", () => {
  // charter D4. loadOverview() returns at the runway before four of the five
  // reads when the fleet is empty; an empty fixture asserts a number the storm
  // never produced. This test exists so emptying the fixture reds LOUDLY.
  assert.ok(OVERVIEW_FLEET.length >= 1,
    "the overview fixture must carry >=1 barkpark row (charter D4)");
});

test("cch-w1: a cold Overview paint issues each of the five endpoints EXACTLY once", async () => {
  await overviewHarness(async ({ net }) => {
    assert.deepEqual(net.tally(), [1, 1, 1, 1, 1],
      "cold paint per endpoint " + JSON.stringify(OVERVIEW_ENDPOINTS) + ", got " + JSON.stringify(net.paths));
    assert.equal(net.paths.length, 5, "and nothing else: " + JSON.stringify(net.paths));
  });
});

test("cch-w1: a fleet tick refetches ONLY /v1/barkparks (was all five)", async () => {
  await overviewHarness(async ({ net }) => {
    net.reset();
    hooks.handleLiveEvent("fleet");
    await settleOverview();
    // PRE-FIX: [1,1,1,1,1] — one tick re-ran the entire loader.
    assert.deepEqual(net.tally(), [1, 0, 0, 0, 0],
      "a fleet tick must read the fleet and nothing else, got " + JSON.stringify(net.paths));
  });
});

test("cch-w1: barkpark.suspended and barkpark.restored narrow the same way", async () => {
  for (const type of ["barkpark.suspended", "barkpark.restored"]) {
    await overviewHarness(async ({ net }) => {
      net.reset();
      hooks.handleLiveEvent(type);
      await settleOverview();
      assert.deepEqual(net.tally(), [1, 0, 0, 0, 0],
        type + " must read the fleet and nothing else, got " + JSON.stringify(net.paths));
    });
  }
});

test("cch-w1: an UNREGISTERED barkpark.* type no longer fires the 5-endpoint bundle", async () => {
  // charter D3: the version-skew fallback (handleLiveEvent's `barkpark.` prefix
  // arm) is a SEPARATE storm trigger from the four registered types. A
  // synthetic barkpark.unknown_skew was measured firing the full five.
  await overviewHarness(async ({ net }) => {
    assert.ok(!hooks.liveEventTypes.includes("barkpark.unknown_skew"),
      "this type must stay UNregistered or the test stops covering the fallback");
    net.reset();
    hooks.handleLiveEvent("barkpark.unknown_skew");
    await settleOverview();
    assert.deepEqual(net.tally(), [1, 0, 0, 0, 0],
      "the prefix fallback must narrow too, got " + JSON.stringify(net.paths));
  });
});

test("cch-w1: an onboarding tick refetches ONLY /v1/onboarding — and repaints the band", async () => {
  await overviewHarness(async ({ net, dom }) => {
    const band = () => dom.nodes.get("overview-state").innerHTML;
    assert.match(band(), /runway-step/, "the cold paint must mount the runway band");
    assert.match(band(), /2 of 3 done/, "…with the fold the server returned");
    net.reset();
    net.state.onboarding = overviewOnboarding(true); // the last step self-healed
    hooks.handleLiveEvent("onboarding");
    await settleOverview();
    // PRE-FIX: [1,1,1,1,1]. The fold is the ONLY thing an onboarding event names.
    assert.deepEqual(net.tally(), [0, 0, 0, 0, 1],
      "an onboarding tick must read the fold and nothing else, got " + JSON.stringify(net.paths));
    // Narrower must not mean staler: the band shows the NEW fold.
    assert.match(band(), /3 of 3 done/, "the state band must repaint from the refetched fold");
  });
});

test("cch-w1: seven fleet ticks after one boot cost 12 requests, not 40", async () => {
  // The production capture, reproduced end to end: 1 cold boot (5) + 7 ticks.
  await overviewHarness(async ({ net }) => {
    for (let i = 0; i < 7; i += 1) {
      hooks.handleLiveEvent("fleet");
      await settleOverview();
    }
    assert.equal(net.paths.length, 12,
      "1 boot (5) + 7 fleet ticks (1 each) = 12; pre-fix this was 40. Got " + JSON.stringify(net.paths));
    assert.deepEqual(net.tally(), [8, 1, 1, 1, 1],
      "only /v1/barkparks may repeat; the other four stay at their single cold read");
  });
});

test("cch-w1: a scoped refresh keeps the activity digest instead of re-reading /v1/audit", async () => {
  await overviewHarness(async ({ net, dom }) => {
    const digest = dom.nodes.get("overview-digest");
    assert.ok(digest, "the cold paint must mount #overview-digest");
    digest.innerHTML = '<div class="ov-digest-probe">recent activity</div>';
    net.reset();
    hooks.handleLiveEvent("fleet");
    await settleOverview();
    assert.equal(net.count("/v1/audit?limit=5"), 0, "no audit event fired — no audit read");
    // The rebuild DESTROYS the old node (see overviewDom), so this is the new one.
    assert.match(dom.nodes.get("overview-digest").innerHTML, /ov-digest-probe/,
      "the digest must be carried across the rebuild, not blanked");
  });
});

test("cch-w1: a tick that beats the first paint still does a FULL load", async () => {
  // A scoped refresh has no snapshot to repaint from before the cold paint, so
  // narrowing must degrade to the full loader rather than paint a half-empty
  // dashboard out of caches that were never filled.
  const priorDoc = sandbox.document;
  const priorFetch = sandbox.fetch;
  const priorHash = sandbox.location.hash;
  const dom = overviewDom();
  const net = overviewNet();
  sandbox.document = dom.document;
  sandbox.fetch = net.fetch;
  sandbox.location.hash = "#overview";
  hooks.overviewData.list = null;
  try {
    hooks.handleLiveEvent("fleet"); // no cold paint ran
    await settleOverview();
    assert.deepEqual(net.tally(), [1, 1, 1, 1, 1],
      "an unprimed scoped refresh must fall back to the full load, got " + JSON.stringify(net.paths));
  } finally {
    sandbox.document = priorDoc;
    sandbox.fetch = priorFetch;
    sandbox.location.hash = priorHash;
    hooks.overviewData.list = null;
    hooks.overviewData.usage = null;
    hooks.overviewData.onboarding = null;
  }
});

test("cch-w1: off-Overview, a fleet tick still costs the Overview nothing", async () => {
  // The mechanism already discriminated by VIEW correctly — this pins that the
  // narrowing did not accidentally make an off-view tick start fetching.
  const priorDoc = sandbox.document;
  const priorFetch = sandbox.fetch;
  const priorHash = sandbox.location.hash;
  const dom = overviewDom();
  const net = overviewNet();
  sandbox.document = dom.document;
  sandbox.fetch = net.fetch;
  sandbox.location.hash = "#activity";
  hooks.overviewData.list = null;
  try {
    assert.equal(hooks.currentView(), "activity", "the fixture route must not be overview");
    hooks.handleLiveEvent("fleet");
    await settleOverview();
    assert.equal(net.count("/v1/barkparks"), 0, "got " + JSON.stringify(net.paths));
  } finally {
    sandbox.document = priorDoc;
    sandbox.fetch = priorFetch;
    sandbox.location.hash = priorHash;
    hooks.overviewData.list = null;
  }
});

// ── cch-bl-overview-subscription-band-stale · OVERVIEW HONESTY ──────────────
// Two defects, one class: the Overview told the operator something it could not
// know. NEITHER was pinned by the 699 tests that preceded this group — both
// fixes passed the whole suite green before a single assertion below existed,
// which is exactly why "the suite is green" proves nothing here and every claim
// gets its own test, each mutation-proved able to fail.
//
// DEFECT A — the console CERTIFIED freshness it lacked. A background refetch
// that fails returns silently from loadOverview's background-failure arm. The
// SILENCE IS RIGHT (blanking a working dashboard on one blip is the louder
// lie); what was wrong was the claim that "the liveness chip already reports a
// broken stream". It does not: the chip is driven by EventSource state alone,
// and es.onmessage stamps lastEventMs and repaints the chip BEFORE dispatching
// the refetch — so at the instant of the failure it reads live / "Live" /
// "· just now" over data that never arrived.
//
// DEFECT B — TYPE_ACTIONS.subscription refreshed subCache and repainted the
// topbar chip, but had no `overview` arm, so the state band beneath a chip
// reading "Payment failed" still rendered the old trial runway from that same
// refreshed cache.

test("cch-bl: a failed BACKGROUND refresh stops the chip certifying freshness", async () => {
  await overviewHarness(async ({ net, dom }) => {
    const chip = hooks.ensureLivenessChip();
    hooks.renderLivenessChip();
    // PRE-CONDITION — the lie, stated: a healthy stream, and the chip says so.
    assert.equal(chip.getAttribute("data-state"), "live");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Live");

    const bodyBefore = dom.nodes.get("overview-body").innerHTML;
    assert.ok(bodyBefore.length > 0, "the cold paint must have left a dashboard to preserve");
    net.reset();
    net.state.fail.add("/v1/barkparks"); // the refetch the event triggers now 503s
    hooks.handleLiveEvent("fleet");
    await settleOverview();

    assert.equal(net.count("/v1/barkparks"), 1, "the tick did dispatch the refetch");
    // THE FIX: the chip no longer vouches for data that did not arrive.
    assert.equal(chip.getAttribute("data-state"), "refresh_failed");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Not current");
    assert.notEqual(chip.querySelector(".live-chip-label").textContent, "Live");
    assert.match(chip.getAttribute("aria-label"), /last refresh failed/);
  });
});

test("cch-bl: …and the body is still NOT blanked — the silence is the correct half", async () => {
  // The seam must not be "fixed" by repainting the body: replacing a working
  // dashboard with an error state on one blip is the louder lie. This assertion
  // was GREEN before the fix and must stay green after it.
  await overviewHarness(async ({ net, dom }) => {
    hooks.ensureLivenessChip();
    const bodyBefore = dom.nodes.get("overview-body").innerHTML;
    const bandBefore = dom.nodes.get("overview-state").innerHTML;
    net.state.fail.add("/v1/barkparks");
    hooks.handleLiveEvent("fleet");
    await settleOverview();
    assert.equal(dom.nodes.get("overview-body").innerHTML, bodyBefore,
      "a background failure must leave the last good dashboard byte-identical");
    assert.equal(dom.nodes.get("overview-state").innerHTML, bandBefore);
    assert.doesNotMatch(dom.nodes.get("overview-body").innerHTML, /Couldn't load your fleet/);
  });
});

test("cch-bl: a refresh that LANDS clears the not-current chip", async () => {
  // A staleness flag that never clears is its own permanent lie — one blip would
  // condemn the topbar for the rest of the session.
  await overviewHarness(async ({ net, dom }) => {
    const chip = hooks.ensureLivenessChip();
    net.state.fail.add("/v1/barkparks");
    hooks.handleLiveEvent("fleet");
    await settleOverview();
    assert.equal(chip.getAttribute("data-state"), "refresh_failed");
    net.state.fail.clear(); // the blip passes
    hooks.handleLiveEvent("fleet");
    await settleOverview();
    assert.equal(chip.getAttribute("data-state"), "live", "recovery is honest too");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Live");
    assert.ok(dom.nodes.get("overview-body").innerHTML.length > 0);
  });
});

test("liveDotState: a failed refresh reads refresh_failed — under dead/reconnecting, over stale/live", () => {
  const now = 1_000_000;
  // The stream is PERFECT and the screen is still not current — the case no
  // stream signal can express, which is why this is its own state.
  assert.equal(hooks.liveDotState(false, now, now, false, true), "refresh_failed");
  assert.equal(hooks.liveDotState(false, null, now, false, true), "refresh_failed");
  // A measured failure outranks the timing INFERENCE of staleness…
  assert.equal(hooks.liveDotState(false, now - 10 * hooks.liveStaleMs, now, false, true), "refresh_failed");
  // …but a down stream still outranks it: those say "not live" more loudly.
  assert.equal(hooks.liveDotState(true, now, now, false, true), "reconnecting");
  assert.equal(hooks.liveDotState(false, now, now, true, true), "dead");
  // The fifth arg is load-bearing: the same inputs without it keep the old
  // answers, so none of the above can pass vacuously.
  assert.equal(hooks.liveDotState(false, now, now, false, false), "live");
  assert.equal(hooks.liveDotState(false, now - 10 * hooks.liveStaleMs, now, false, false), "stale");
});

test("cch-bl: the not-current chip carries NO 'as of' — the event was just now, the data wasn't", () => {
  const orig = sandbox.document;
  const { document: doc } = fakeDom();
  sandbox.document = doc;
  try {
    const chip = hooks.ensureLivenessChip();
    const now = 1_000_000;
    // Exactly the production shape at the instant of failure: onmessage stamped
    // lastEventMs one second ago, so without the suppression the chip would read
    // "Not current · just now" — reassurance welded to a warning.
    hooks.renderLivenessChip({ lastEventMs: now - 1_000, nowMs: now, refreshStale: true });
    assert.equal(chip.getAttribute("data-state"), "refresh_failed");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Not current");
    assert.equal(chip.querySelector(".live-chip-ago").textContent, "");
    assert.equal(chip.querySelector(".live-chip-ago").hidden, true);
    assert.doesNotMatch(chip.getAttribute("title"), /last event/);
    // Control: the same recency WITHOUT the failed refresh does show it.
    hooks.renderLivenessChip({ lastEventMs: now - 1_000, nowMs: now, refreshStale: false });
    assert.equal(chip.getAttribute("data-state"), "live");
    assert.equal(chip.querySelector(".live-chip-ago").textContent, "· just now");
  } finally {
    sandbox.document = orig;
  }
});

// A past-due subscription: the transition the operator most needs to see, and
// the one overviewStatePick ranks above everything (the money path).
const OVERVIEW_PAST_DUE = { status: "past_due", plan: "pro", current_period_end: "2026-07-01T00:00:00Z" };

test("cch-bl: a subscription tick repaints the Overview band, not just the topbar chip", async () => {
  await overviewHarness(async ({ net, dom }) => {
    const band = () => dom.nodes.get("overview-state").innerHTML;
    assert.match(band(), /runway-step/, "the cold paint must mount the trial runway band");
    // The pure model already knows the answer — only the paint was missing.
    assert.equal(hooks.overviewStatePick(net.state.subscription, hooks.overviewData.onboarding), "runway");

    net.reset();
    net.state.subscription = OVERVIEW_PAST_DUE;
    hooks.handleLiveEvent("subscription");
    await settleOverview();

    // The topbar flipped — the half that always worked, and the reason the band
    // beneath it reading "trial" was a visible contradiction, not a subtlety.
    assert.equal(dom.chip("billing-chip").textContent, "Payment failed · fix billing");
    // PRE-FIX: byte-identical to `band()` above — the old runway card.
    assert.match(band(), /dunning-banner/, "the state band must follow the refreshed cache");
    assert.match(band(), /Payment failed/);
    assert.doesNotMatch(band(), /runway-step/);
    // …and the narrowing holds: ONE read, the one the event named.
    assert.deepEqual(net.tally(), [0, 0, 0, 1, 0],
      "a subscription tick must read the subscription and nothing else, got " + JSON.stringify(net.paths));
  });
});

test("cch-bl: the subscription tick repaints the whole sub-dependent Overview, not only the band", async () => {
  // paintOverviewData, NOT paintOverviewState: the slots meter and the instances
  // grid read subCache too (overviewInstancesHtml takes `sub`), so a band-only
  // repaint would leave two more stale regions behind the fixed one.
  await overviewHarness(async ({ net, dom }) => {
    const grid = dom.nodes.get("overview-instances");
    assert.ok(grid, "the cold paint must mount #overview-instances");
    grid.innerHTML = '<div class="ov-grid-probe">stale</div>'; // survives only if nothing repaints
    net.state.subscription = OVERVIEW_PAST_DUE;
    hooks.handleLiveEvent("subscription");
    await settleOverview();
    assert.doesNotMatch(dom.nodes.get("overview-instances").innerHTML, /ov-grid-probe/,
      "the instances grid must be repainted from the refreshed subscription too");
    assert.match(dom.nodes.get("overview-instances").innerHTML, /bravo/,
      "…and repainted with the fleet, not blanked");
  });
});

test("cch-bl: the not-current claim is OVERVIEW-scoped — Fleet's topbar does not inherit it", async () => {
  // The flag is set by loadOverview and cleared by an Overview read, so without
  // a scope the chip would keep disclaiming currency on Fleet — a view that
  // fetched its own data successfully. That is a NEW lie wearing the fix for an
  // old one, which is the exact trade this slice exists not to make.
  const priorHash = sandbox.location.hash;
  await overviewHarness(async ({ net }) => {
    const chip = hooks.ensureLivenessChip();
    net.state.fail.add("/v1/barkparks");
    hooks.handleLiveEvent("fleet");
    await settleOverview();
    assert.equal(chip.getAttribute("data-state"), "refresh_failed");

    sandbox.location.hash = "#fleet";
    hooks.renderLivenessChip(); // what the 1s chip ticker does on every view
    assert.equal(chip.getAttribute("data-state"), "live",
      "Fleet must not wear the Overview's staleness");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Live");

    // …and it is not forgotten either: back on Overview the claim stands until
    // a read lands.
    sandbox.location.hash = "#overview";
    hooks.renderLivenessChip();
    assert.equal(chip.getAttribute("data-state"), "refresh_failed");
  });
  sandbox.location.hash = priorHash;
});

test("cch-bl: off-Overview, a subscription tick paints no Overview and still costs one read", async () => {
  // The new arm is VIEW-scoped like every other: a tick arriving on Billing must
  // not paint into an Overview nobody is looking at.
  const priorHash = sandbox.location.hash;
  await overviewHarness(async ({ net, dom }) => {
    const band = () => dom.nodes.get("overview-state").innerHTML;
    const before = band();
    sandbox.location.hash = "#activity";
    net.reset();
    net.state.subscription = OVERVIEW_PAST_DUE;
    hooks.handleLiveEvent("subscription");
    await settleOverview();
    assert.equal(band(), before, "no repaint off-Overview");
    assert.deepEqual(net.tally(), [0, 0, 0, 1, 0]);
  });
  sandbox.location.hash = priorHash;
});

// ── gr-p5-account-2fa · GR54 THE SAFETY NET ─────────────────────────────────
// The account modal is the ONE surface whose three operations (password change,
// session revoke, log out) can lock a user out of their own console. Before the
// body is recomposed, its element-id contracts are pinned here. Every pin below
// was MUTATION-PROVED: deleting the thing it names reds exactly this test and
// nothing else. Source-regex guards are BANNED (a probe's first attempt passed
// while the guarded line sat commented out) — these read the rendered markup.

// The model the recomposed body renders — folded from the session + /v1/me by
// accountModel, exactly as openAccountModal does. NOTHING here costs a fetch.
const ACCT_ME = {
  user: { email: "fjord@jarl.no", two_factor_enabled: false },
  team: { id: "team_abc", name: "Guerrilla" },
  role: "owner",
};
const acctModel = (me = ACCT_ME) => hooks.accountModel({ team_id: "team_abc" }, me);

test("gr-p5-account: accountModalHtml carries all eight element ids the wiring binds to", () => {
  const html = hooks.accountModalHtml(acctModel());
  // Each id is bound by openAccountModal / submitPasswordChange / loadSessions.
  // Losing one silently deadens a control that can strand a signed-in user.
  for (const id of ["modal-title", "pw-current", "pw-new", "pw-error",
    "sessions-box", "sessions-revoke-all", "pw-form", "modal-logout"]) {
    assert.ok(html.includes('id="' + id + '"'),
      "account modal body must carry id=" + JSON.stringify(id));
  }
});

test("gr-p5-account: the <h2> ITSELF carries id=modal-title (index.html binds it statically)", () => {
  const html = hooks.accountModalHtml(acctModel());
  // index.html sets aria-labelledby="modal-title" on the SHARED .modal-card, so
  // the id must live on this body's heading — not on some other node, and never
  // absent: dropping it strips the accessible name from EVERY modal in the app.
  const h2 = html.match(/<h2[^>]*>/);
  assert.ok(h2, "the account modal must open with an <h2>");
  assert.ok(/id="modal-title"/.test(h2[0]),
    "id=modal-title must sit on the <h2> itself, got: " + h2[0]);
});

test("gr-p5-account: index.html still binds aria-labelledby=modal-title on the shared modal card", () => {
  const html = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const card = html.match(/<div class="modal-card card"[^>]*>/);
  assert.ok(card, "the shared .modal-card must exist in index.html");
  assert.ok(card[0].includes('aria-labelledby="modal-title"'),
    "the shared modal card must keep aria-labelledby=modal-title: " + card[0]);
});

test("gr-p5-account: loadSessions' two css_check-named hooks survive — .session-revoke and .badge-current", () => {
  // These two class names are not decoration: `.session-revoke` is the selector
  // loadSessions delegates its per-row revoke click through, and `.badge-current`
  // is what marks the row you must NOT revoke. GR63 extracted the row itself into
  // the pure sessionRowHtml, so the MARKUP arm reads rendered output; only the
  // delegation (a DOM mount, no pure seam) still reads source.
  const current = hooks.sessionRowHtml({ id: "a", user_agent: "barkpark-cli/0.9", current: true });
  const other = hooks.sessionRowHtml({ id: "b", user_agent: "barkpark-cli/0.9", current: false });
  assert.ok(current.includes("badge-current"), "the current row must be badged .badge-current");
  assert.ok(!current.includes("session-revoke"), "the current device is never self-revokable");
  assert.ok(other.includes('class="btn btn-sm session-revoke"'),
    "every other row offers .session-revoke");
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  const fn = src.slice(src.indexOf("function loadSessions("));
  const body = fn.slice(0, fn.indexOf("\n  function ", 10));
  assert.ok(body.includes('querySelectorAll(".session-revoke")'),
    "loadSessions must delegate row revokes through .session-revoke");
});

test("gr-p5-session-provenance: the session row shows origin only when the server sent one", () => {
  // A null/absent origin renders NOTHING — every row minted before the column
  // existed is genuinely unknown, and inventing "via password" for it would be
  // the same class of lie as the IP this row already suppresses. The label rides
  // the EXISTING .session-meta line: no new class, so this stays off css_check.
  const unknown = hooks.sessionRowHtml({ id: "a", user_agent: "barkpark-cli/0.9" });
  assert.ok(!unknown.includes("via "), "an origin-less row must claim nothing: " + unknown);

  const linked = hooks.sessionRowHtml({ id: "b", user_agent: "barkpark-cli/0.9", origin: "device_link" });
  assert.ok(/session-meta">Active [^<]*·[^<]*via device link</.test(linked),
    "device_link must render on the existing .session-meta line: " + linked);
  assert.ok(!linked.includes("session-origin"), "no new CSS class may appear: " + linked);

  // OAuth reports the provider itself, so the tail IS the label.
  assert.ok(hooks.sessionRowHtml({ id: "c", origin: "oauth:github" }).includes("via github"),
    "oauth:<provider> must surface the provider");

  // An origin this client has never heard of is SHOWN, not swallowed — a newer
  // server must not go silent against an older SPA.
  assert.ok(hooks.sessionRowHtml({ id: "d", origin: "smartcard" }).includes("via smartcard"),
    "an unknown origin falls through to the raw value");

  // ...and it is escaped like every other server-controlled string on this row.
  assert.ok(!hooks.sessionRowHtml({ id: "e", origin: "<img src=x>" }).includes("<img"),
    "the origin must be escaped");
});

test("gr-p5-account: the three OUTSIDE contracts still reach the modal — #acct-btn, #ws-switch, palette act-account", () => {
  // openAccountModal has exactly three entry points. A recomposition that
  // renames the function or drops a listener leaves the account unreachable.
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  assert.ok(src.includes('$("#acct-btn").addEventListener("click", openAccountModal)'),
    "the sidebar account button must open the account modal");
  assert.ok(/wsSwitch\.addEventListener\("click", openAccountModal\)/.test(src),
    "the workspace switcher must open the account modal");
  // The palette id is LAW (the label is free) — no conditional guard here: a
  // missing hook must red this test, never silently skip it.
  assert.equal(typeof hooks.paletteActionItems, "function",
    "paletteActionItems must stay exported");
  assert.ok(hooks.paletteActionItems().some((i) => i.id === "act-account"),
    "the command palette must keep the act-account action id");
});

test("gr-p5-account: hostile identity values are ESCAPED, never injected", () => {
  // Every string in the identity band is server-supplied. Drive the real fold,
  // not a hand-built model, so an unescaped NEW field would be caught too.
  const html = hooks.accountModalHtml(hooks.accountModel(
    { team_id: '<img src=x onerror="alert(1)">' },
    { user: { email: '<svg onload="alert(2)">@x.no' }, team: { name: '"><script>alert(3)</script>' }, role: "owner" },
  ));
  for (const raw of ["<img src=x", "<svg onload", "<script>alert(3)"]) {
    assert.ok(!html.includes(raw), "raw hostile markup must never reach the body: " + raw);
  }
  assert.ok(html.includes("&lt;svg onload"), "the hostile email must render escaped");
  assert.ok(html.includes("&lt;script&gt;alert(3)"), "the hostile team name must render escaped");
});

// ── gr-p5-account-2fa · GR55 THE QR SHIPS, GATED BY A BYTE-MATCH ────────────
// The encoder is verified against the COMMITTED fixture, never against a
// self-written decoder. That circle already green-lit a matrix with a
// TRANSPOSED format block AND a REVERSED generator polynomial — a decoder that
// shares its author's misconception agrees with it perfectly.

const QR_FIXTURE = JSON.parse(
  fs.readFileSync(new URL("./__qr_fixture.json", import.meta.url), "utf8"),
);

test("gr-p5-2fa: every fixture entry round-trips BYTE-IDENTICAL through the shipped encoder", () => {
  assert.equal(QR_FIXTURE.length, 3, "the fixture must keep all three entries");
  for (const entry of QR_FIXTURE) {
    const res = hooks.qrMatrix(entry.uri, { ec: entry.ec });
    assert.equal(res.version, entry.version, "version drift on " + entry.uri);
    assert.equal(res.mask, entry.mask, "mask drift on " + entry.uri);
    // THE gate: the full module matrix, module for module.
    assert.equal(hooks.qrText(res), entry.rows.join("\n"),
      "matrix bytes drifted on " + entry.uri);
  }
});

test("gr-p5-2fa: the fixture actually covers the three shapes it claims (v7/m4, v6/m4, v2/m6)", () => {
  // A fixture that silently lost an entry would make the byte-match above
  // vacuous. Pin the coverage itself.
  const shapes = QR_FIXTURE.map((e) => e.version + "/" + e.mask);
  assert.deepEqual(shapes, ["7/4", "6/4", "2/6"]);
});

test("gr-p5-2fa: qrMatrix THROWS past capacity, and the enroll panel falls back to manual entry ALONE", () => {
  // Fixed otpauth overhead is 96 bytes, so a 113+ char local part overruns
  // version 10 — and RFC-legal addresses reach 254.
  const long = "otpauth://totp/Barkpark%20Cloud:" + "a".repeat(120) +
    "@jarl.no?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Barkpark%20Cloud";
  assert.ok(long.length > 214, "the probe URI must actually overrun the encoder");
  assert.throws(() => hooks.qrMatrix(long, { ec: "M" }), /too long/);

  // The throw is CAUGHT at the render seam — no broken box, no blank plate.
  assert.equal(hooks.accountTwoFactorQrHtml(long), "", "an over-long URI must render NO qr node");
  const panel = hooks.accountTwoFactorPanelHtml({ phase: "enroll", uri: long, secret: "JBSWY3DPEHPK3PXP" });
  assert.ok(!panel.includes("a2f-qr-svg"), "no QR may be drawn when the encoder threw");
  assert.ok(panel.includes("a2f-enroll--noqr"), "the panel must take the no-QR layout");
  assert.ok(panel.includes("too long to fit a QR code"),
    "the panel must SAY why the QR is missing, not silently drop it");
  // Manual entry is still complete and first-class — the fallback that makes
  // the residual scanner risk non-fatal.
  assert.ok(panel.includes("JBSW Y3DP EHPK 3PXP"), "the secret must still be offered in 4-char groups");
  assert.ok(panel.includes('id="a2f-otp"'), "the code field must still be reachable");
});

test("gr-p5-2fa: a normal enrollment DOES draw the QR, and it carries a real module path", () => {
  const uri = QR_FIXTURE[0].uri;
  const html = hooks.accountTwoFactorQrHtml(uri);
  assert.ok(html.includes("a2f-qr-svg"), "the QR must render for a normal address");
  const path = html.match(/<path d="([^"]*)"/);
  assert.ok(path && path[1].length > 500, "the QR path must carry real modules, not an empty d=");
  // Literal black/white, never theme tokens: a themed QR that reads in light
  // mode and fails in dark is a silent lockout.
  assert.ok(html.includes('fill="#000000"') && html.includes('fill="#ffffff"'),
    "the QR must use literal contrast, never var(--…)");
  assert.ok(!html.includes("var(--"), "no theme token may reach the QR");
});

// ── gr-p5-account-2fa · GR52b THE SEVEN STATES, TWO HONEST ERRORS ───────────

test("gr-p5-2fa: all seven states render, each distinguishable from the others", () => {
  const off = hooks.accountTwoFactorPanelHtml({ phase: "off" });
  const notEnrolled = hooks.accountTwoFactorPanelHtml({ phase: "off", error: "That setup is no longer pending. Start again to get a fresh secret." });
  const enroll = hooks.accountTwoFactorPanelHtml({ phase: "enroll", uri: QR_FIXTURE[0].uri, secret: "JBSWY3DPEHPK3PXP" });
  const enrollErr = hooks.accountTwoFactorPanelHtml({ phase: "enroll", uri: QR_FIXTURE[0].uri, secret: "JBSWY3DPEHPK3PXP", error: "That code didn't match." });
  const codes = hooks.accountTwoFactorPanelHtml({ phase: "codes", codes: ["h4kq2mfp", "x8dw9rgt", "p2ml5qzn", "k9vt3bxs", "w6ny8jhc", "r1gd4tkm", "z7sb6plf", "m3cx1vwq"] });
  const on = hooks.accountTwoFactorPanelHtml({ phase: "on" });

  // 1 not-enrolled
  assert.ok(off.includes('id="a2f-start"') && !off.includes("form-error"), "1: the off state offers setup, clean");
  // 2 not-enrolled carrying the recovered 422 not_enrolled
  assert.ok(notEnrolled.includes('id="a2f-start"') && notEnrolled.includes("no longer pending"),
    "2: not_enrolled recovers to the off state WITH the sentence, never a dead form");
  // 3 enroll
  assert.ok(enroll.includes('id="a2f-otp"') && enroll.includes('id="a2f-confirm"') && !enroll.includes("form-error"),
    "3: enroll offers the QR + secret + code field");
  // 4 enroll + invalid_otp
  assert.ok(enrollErr.includes('id="a2f-otp"') && enrollErr.includes("form-error"),
    "4: a bad code keeps the form AND shows the inline sentence");
  // 5 one-shot recovery sheet
  assert.ok(codes.includes('id="a2f-codes"') && codes.includes('id="a2f-saved"'), "5: the recovery sheet");
  // 6 on-row
  assert.ok(on.includes('id="a2f-regen"') && on.includes('id="a2f-disable"'), "6: the on-row");
  // 7 the disable confirm rides the SHARED danger-no-echo tier (landed #4390):
  // btn-danger weight, NO typed echo, and a bodyHtml slot for the warning.
  const confirm = hooks.confirmModalHtml(hooks.confirmModalInit({
    tier: "danger", title: "Turn off two-factor authentication?",
    bodyHtml: "Sign-in drops back to <b>password only</b>.", confirmLabel: "Turn it off",
  }));
  assert.ok(confirm.includes("btn-danger"), "7: disable must carry danger weight");
  assert.ok(!confirm.includes("cm-typed"), "7: the danger tier must NOT demand a typed echo");
  assert.ok(confirm.includes("<b>password only</b>"), "7: the warning rides the bodyHtml slot");

  // The five undrawn states all speak the EXISTING inline-error grammar
  // (.form-error, the #pw-error pattern) — never a toast.
  for (const html of [notEnrolled, enrollErr]) {
    assert.ok(html.includes('class="form-error a2f-error"'), "errors must ride the .form-error grammar");
    assert.ok(html.includes('role="alert"'), "an inline error must announce itself");
  }
});

test("gr-p5-2fa: EXACTLY two honest server errors — 422 invalid_otp and 422 not_enrolled", () => {
  assert.ok(/didn't match/.test(hooks.accountTwoFactorErrorCopy(422, { error: "invalid_otp" })),
    "422 invalid_otp must get its own sentence");
  assert.ok(/no longer pending/.test(hooks.accountTwoFactorErrorCopy(422, { error: "not_enrolled" })),
    "422 not_enrolled must get its own sentence");
  // Everything else returns null so the caller falls back to friendly(). A third
  // named sentence would be inventing a server behaviour.
  for (const [status, data] of [
    [422, { error: "not_enabled" }], [422, { error: "whatever" }], [422, {}],
    [429, { error: "invalid_otp" }], [401, { error: "invalid_otp" }],
    [500, null], [200, { error: "invalid_otp" }],
  ]) {
    assert.equal(hooks.accountTwoFactorErrorCopy(status, data), null,
      "only the two documented 422s may be named: " + status + " " + JSON.stringify(data));
  }
});

test("gr-p5-2fa: GR52b — the account 2FA surface has NO rate-limited state anywhere", () => {
  // TwoFactorRateLimiter's ONLY call site is the LOGIN challenge (router.ex),
  // so the account confirm route is genuinely unthrottled. A "try again in Ns"
  // sentence here would be a lie. Scoped to the ACCOUNT surface: the login
  // challenge legitimately has a 429 branch and must not be caught by this.
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  const start = src.indexOf("function accountTwoFactorBadgeHtml(");
  const end = src.indexOf("function openAccountModal(");
  assert.ok(start > 0 && end > start, "the account 2FA region must be locatable");
  const region = src.slice(start, end);
  for (const banned of ["429", "rate_limited", "rateLimited", "Too many", "try again in"]) {
    assert.ok(!region.includes(banned),
      "the account 2FA surface must never speak " + JSON.stringify(banned));
  }
  // And the states themselves carry no such copy.
  for (const phase of ["off", "enroll", "codes", "on"]) {
    const html = hooks.accountTwoFactorPanelHtml({ phase, uri: QR_FIXTURE[0].uri, secret: "JBSWY3DPEHPK3PXP", codes: ["a", "b"] });
    // Word-bounded: "Regenerate recovery codes" legitimately contains "rate".
    assert.ok(!/\brate[ -]?limit|\b429\b|too many|try again in|\d+\s*seconds?/i.test(html),
      "no throttling copy in the " + phase + " state");
  }
});

test("gr-p5-2fa: the on-state is read FREE from /v1/me — no GET /v1/account/two-factor call site", () => {
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  assert.ok(!/api\(\s*"GET"\s*,\s*"\/v1\/account\/two-factor"/.test(src),
    "the status route must stay unused — two_factor_enabled is already on /v1/me");
  // And the model actually reads it.
  assert.equal(hooks.accountModel({}, { user: { two_factor_enabled: true } }).twoFactorEnabled, true);
  assert.equal(hooks.accountModel({}, { user: { two_factor_enabled: false } }).twoFactorEnabled, false);
  assert.equal(hooks.accountModel({}, {}).twoFactorEnabled, false, "an unloaded /v1/me must fail to OFF");
});

// ── gr-p5-account-2fa · GR56 THE ONE-SHOT SHEET, AND THE × TRAP ─────────────

test("gr-p5-2fa: the recovery sheet is 8 chips in a 4x2 grid with Copy all + Download .txt", () => {
  const codes = ["h4kq2mfp", "x8dw9rgt", "p2ml5qzn", "k9vt3bxs", "w6ny8jhc", "r1gd4tkm", "z7sb6plf", "m3cx1vwq"];
  const html = hooks.accountTwoFactorPanelHtml({ phase: "codes", codes });
  assert.equal(html.split('class="a2f-code"').length - 1, 8, "all eight codes must render as chips");
  for (const c of codes) assert.ok(html.includes(c), "code " + c + " must render");
  assert.ok(html.includes('id="a2f-copy"') && html.includes("Copy all"), "Copy all must be offered");
  assert.ok(html.includes('id="a2f-download"') && html.includes("Download .txt"), "Download .txt must be offered");
  assert.ok(html.includes('id="a2f-saved"') && html.includes("I saved them"), "the explicit exit must be offered");
  // The sentence that makes the stakes plain — losing the sheet is unrecoverable.
  assert.ok(html.includes("only time they're shown"), "the one-shot warning must be stated");
  // The .txt body carries every code.
  const txt = hooks.recoveryCodesText(codes);
  for (const c of codes) assert.ok(txt.includes(c), ".txt body must carry " + c);
  assert.ok(txt.includes("works once"), ".txt must restate the one-shot rule out of context");
});

test("gr-p5-2fa: the 4x2 grid is a real CSS grid of four columns, not a wrapped guess", () => {
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  assert.ok(/\.a2f-codes\s*\{[^}]*grid-template-columns:\s*repeat\(4,/.test(css),
    "the sheet must lay 8 chips out as 4 across (→ 4x2)");
});

test("gr-p5-2fa: modalDismissAllowed refuses the three REFLEX routes while pinned, and always allows explicit", () => {
  for (const via of ["escape", "backdrop", "close-x"]) {
    assert.equal(hooks.modalDismissAllowed(true, via), false, via + " must be refused while pinned");
    assert.equal(hooks.modalDismissAllowed(false, via), true, via + " must pass when unpinned");
  }
  // The body's own affordance is never a reflex — it ALWAYS passes.
  assert.equal(hooks.modalDismissAllowed(true, "explicit"), true);
  assert.equal(hooks.modalDismissAllowed(false, "explicit"), true);
  // Total over junk: an unknown route is treated as a reflex (fail-safe).
  assert.equal(hooks.modalDismissAllowed(true, "who-knows"), false);
  assert.equal(hooks.modalDismissAllowed(false, undefined), true);
});

test("gr-p5-2fa: openModal CLEARS the pin — a stale pin can never strand the NEXT modal", () => {
  // BEHAVIOURAL, not a source-regex: a probe's regex guard once passed while the
  // guarded line sat commented out. This drives the real openModal.
  hooks.setModalPin(true);
  assert.equal(hooks.modalPinState(), true, "the pin must actually set");
  hooks.openModal("<p>the next modal</p>");
  assert.equal(hooks.modalPinState(), false,
    "openModal must fail OPEN — otherwise launch / env-editor / confirm lock shut with no explanation");
  // And it clears even when the mount aborts (no #modal-root in this sandbox),
  // which is exactly the path that would otherwise strand the flag.
  hooks.setModalPin(true);
  hooks.openModal("");
  assert.equal(hooks.modalPinState(), false, "an aborted mount must still clear the pin");
});

test("gr-p5-2fa: closeModal stays UNGATED — a pin never imprisons the operator", () => {
  // Behavioural: mount a minimal real DOM into the sandbox, pin it, and prove
  // closeModal still tears the dialog down. (The pin is consulted ONLY in
  // wireModal's two reflex handlers.)
  const el = (id) => ({
    id, innerHTML: "", hidden: false, textContent: "",
    classList: { add() {}, remove() {}, toggle() {}, contains: () => id === "modal-x" },
    setAttribute() {}, removeAttribute() {}, addEventListener() {},
    querySelector: () => null, querySelectorAll: () => [], focus() {},
  });
  const nodes = { "#modal-root": el("modal-root"), "#modal-body": el("modal-body"), ".modal-x": el("modal-x") };
  const prevQS = sandbox.document.querySelector;
  const prevGE = sandbox.document.getElementById;
  sandbox.document.querySelector = (sel) => nodes[sel] || null;
  sandbox.document.getElementById = (id) => nodes["#" + id] || null;
  try {
    hooks.openModal("<p>recovery codes</p>");
    assert.equal(nodes["#modal-root"].hidden, false, "the dialog must be showing");
    assert.equal(nodes["#modal-body"].innerHTML, "<p>recovery codes</p>", "the body must have mounted");
    hooks.setModalPin(true);
    // GR56: `.modal-x` carries data-close, so a pin DEADENS it — a visible dead
    // × is strictly worse than no ×.
    assert.equal(nodes[".modal-x"].hidden, true, "the × must HIDE while pinned, never sit there dead");
    hooks.closeModal();
    assert.equal(nodes["#modal-root"].hidden, true, "closeModal must work THROUGH the pin");
    assert.equal(nodes["#modal-body"].innerHTML, "", "the body must be cleared");
    // Un-pinning restores the ×.
    hooks.setModalPin(false);
    assert.equal(nodes[".modal-x"].hidden, false, "the × must come back when unpinned");
  } finally {
    sandbox.document.querySelector = prevQS;
    sandbox.document.getElementById = prevGE;
    hooks.setModalPin(false);
  }
});

test("gr-p5-2fa: the pin hides EVERY [data-close] in the body, not just the × (review fix)", () => {
  // The account modal's footer renders `<button data-close>Close</button>`. It
  // rides the SAME delegated handler as the backdrop and the ×, so the pin
  // deadens it too — and hiding only the × left a full-width dead button
  // sitting under the one-shot recovery sheet. Behavioural, through the real
  // setModalPin.
  const footerClose = { hidden: false };
  const el = (id) => ({
    id, innerHTML: "", hidden: false, textContent: "",
    classList: { add() {}, remove() {}, toggle() {}, contains: () => id === "modal-x" },
    setAttribute() {}, removeAttribute() {}, addEventListener() {},
    querySelector: () => null,
    querySelectorAll: () => (id === "modal-body" ? [footerClose] : []),
    focus() {},
  });
  const nodes = { "#modal-root": el("modal-root"), "#modal-body": el("modal-body"), ".modal-x": el("modal-x") };
  const prevQS = sandbox.document.querySelector;
  try {
    sandbox.document.querySelector = (sel) => nodes[sel] || null;
    hooks.setModalPin(true);
    assert.equal(footerClose.hidden, true,
      "a dead footer Close is exactly the defect the × rule exists to prevent");
    hooks.setModalPin(false);
    assert.equal(footerClose.hidden, false, "un-pinning must bring the footer back");
  } finally {
    sandbox.document.querySelector = prevQS;
    hooks.setModalPin(false);
  }
});

test("gr-p5-2fa: a hidden footer [data-close] is actually invisible — .btn is display:inline-flex", () => {
  // Same author-rule-beats-[hidden] trap as .modal-x, one selector wider: the
  // footer Close is a `.btn`, so `hidden` alone would not hide it.
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  assert.ok(/#modal-body \[data-close\]\[hidden\]\s*\{[^}]*display:\s*none/.test(css),
    "app.css must restore [hidden] for body-rendered close affordances");
});

test("gr-p5-2fa: a hidden .modal-x is actually invisible — [hidden] must beat the display rule", () => {
  // `.modal-x { display: grid }` is an AUTHOR rule, and author rules beat the
  // UA sheet's [hidden]{display:none} regardless of specificity. Without an
  // explicit override the "hidden" × would stay on screen, dead.
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  assert.ok(/\.modal-x\[hidden\]\s*\{[^}]*display:\s*none/.test(css),
    "app.css must restore [hidden] for .modal-x");
});

// ── gr-p5-account-2fa · GR57 TOKENS ────────────────────────────────────────

test("gr-p5-2fa: fixed-blue links ride --info/--cc-blue — never --primary, which IS the user's accent", () => {
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  const rule = css.match(/\.am-link\s*\{([^}]*)\}/);
  assert.ok(rule, "the account modal's link variant must exist");
  assert.ok(/color:\s*var\(--info\)/.test(rule[1]),
    "the link colour must be the fixed blue: " + rule[1]);
  assert.ok(!/var\(--primary\)/.test(rule[1]),
    "--primary is the user-selectable accent — links would go orange under Ember");
  // --info is declared ONLY in :root / [data-theme="dark"] and has zero
  // [data-bp-theme] overrides. If that ever changes, this red is the warning.
  const themeBlocks = css.match(/\[data-bp-theme="[^"]+"\][^{]*\{[^}]*\}/g) || [];
  for (const b of themeBlocks) {
    assert.ok(!/--info\s*:/.test(b) && !/--cc-blue\s*:/.test(b),
      "an accent identity must never redefine the fixed blue: " + b.slice(0, 60));
  }
  // And the recomposed body reaches for the variant, not bare .btn-link.
  const html = hooks.accountModalHtml(hooks.accountModel({}, { user: { email: "a@b.no" } }));
  assert.ok(html.includes('class="btn-link am-link"'), "the body's links must carry the fixed-blue variant");
});

test("gr-p5-2fa: the width override is :has()-SCOPED — the shared 420px modal base is untouched", () => {
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  // The shared base, still 420px for the other 15+ modal bodies (env editor,
  // token creation, provider picker …).
  const base = css.match(/\.modal-card\s*\{([^}]*)\}/);
  assert.ok(base && /max-width:\s*420px/.test(base[1]),
    "the shared .modal-card base must stay 420px: " + (base && base[1]));
  // The widening rule follows the live cmdk :has() precedent.
  assert.ok(/\.modal-root:has\(\.am-modal\)\s*\.modal-card\s*\{[^}]*max-width:\s*5\d\dpx/.test(css),
    "the account modal must widen through a :has()-scoped rule");
  // And the body carries the hook the rule keys off.
  const html = hooks.accountModalHtml(hooks.accountModel({}, {}));
  assert.ok(html.includes('class="am-modal"'), "the body must carry the :has() hook class");
});

// ── cch-w16-s1 · the billing tier floor, pinned as a DECLARATION ────────────
// #8741 repaired the billing-tier grid in ONE line: `repeat(auto-fit,
// minmax(230px, 1fr))`. `minmax(230` occurs in exactly two places repo-wide —
// the charter's prose and app.css itself — and lowering it re-admits five
// tracks at 180.4px inside the 950px grid box, cutting the Free tier's CTA
// ("Yours when the trial ends", 147px wide in a 136px box). Every command CI
// invoked before this wave exited 0 on that mutant: the whole person-facing
// fix shipped with no guard at all.
//
// THE LIMIT OF THIS TEST, STATED HERE SO NOBODY OVERREADS ITS GREEN: it pins
// the DECLARATION, not the LAYOUT. node cannot lay out CSS. It refuses only a
// textual tidy-down of this one value, and is BLIND to a re-cut originating
// anywhere else — a `.content` max-width change that shrinks the grid box, a
// later competing `.tier-grid` rule or `@media` override, a token change that
// widens the button's text, or a markup change in tierCardHtml. The geometric
// half of the guard is the render leg
// (`breakpoint-sweep.mjs --render --widths 901 --cell billing-trial`, wired as
// its own node-22 job in console-harness.yml); the five-tier seam
// (`--tiers5`) covers the widths where a three-tier corpus is blind entirely.
// Neither half subsumes the other: measured, a 200px floor passes the FULL
// 13-width render leg exit 0, and this test refuses it.
test("cch-w16-s1: the .tier-grid floor is >= 230px — a tidy-down re-cuts the Free CTA", () => {
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  // The FIRST rule whose selector list is exactly `.tier-grid` — the base
  // declaration, never a `@media` override or a comment that names the token.
  const rule = css.match(/(^|\})\s*\.tier-grid\s*\{([^}]*)\}/m);
  assert.ok(rule, "app.css must carry a `.tier-grid` rule");
  const decls = rule[2].replace(/\/\*[\s\S]*?\*\//g, "");
  const m = decls.match(/grid-template-columns:\s*repeat\(\s*auto-fit\s*,\s*minmax\(\s*(\d+(?:\.\d+)?)px/);
  assert.ok(m,
    "the .tier-grid base must declare `repeat(auto-fit, minmax(<N>px, 1fr))` — " +
    "a different shape is not necessarily wrong, but it is no longer pinned by " +
    "this test, so re-derive the floor before changing it: " + decls.trim());
  const floor = Number(m[1]);
  assert.ok(floor >= 230,
    "the .tier-grid track floor measured " + floor + "px, below the 230px minimum #8741 shipped. " +
    "A minimum at or below ~180px re-admits five auto-fit tracks in the 950px grid box " +
    "(180.4px each) and cuts the Free tier's CTA label; 230px holds three tracks at 308.7px. " +
    "Do not tidy it downward.");
});

// ── GR63 · the modal root must be able to SCROLL ───────────────────────────
// The blocker this slice exists for: on live barkpark.cloud an account with 19
// sessions rendered a 1655.5px .modal-card inside a 900px viewport, and NOTHING
// in the modal chain could scroll (.modal-root was `position:fixed; place-items:
// center` with no overflow-y; .modal-card had no bounded height). 11 of 28
// controls were permanently unreachable — every Revoke, the footer Close, "Set
// up two-factor authentication", and Log out, which is the app's ONLY logout
// affordance. Measured threshold: 287.5px of modal chrome + 72px per session
// row ⇒ 8 sessions fit, 9 break it. Five waves of green fixtures missed it
// because every fixture carried two sessions.
//
// Two arms, and BOTH are needed: the markup arm proves the tall shape exists
// and puts the escape hatches BELOW the list (the structural reason they went
// out of reach), and the stylesheet arm proves the shipped CSS gives that shape
// a scroll path. The stylesheet arm reads the declaration block of the rule
// that actually ships — node cannot lay out CSS, and asserting on rendered
// markup here would prove nothing about geometry.

const declsOf = (css, selector) => {
  // The FIRST rule whose selector list is exactly `selector` (so a comment or a
  // `:has()` variant elsewhere in the file can never satisfy this).
  const re = new RegExp("(^|\\})\\s*" + selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*\\{([^}]*)\\}", "m");
  const m = css.match(re);
  assert.ok(m, "app.css must carry a `" + selector + "` rule");
  return Object.fromEntries(
    m[2].split(";").map((d) => d.split(":")).filter((p) => p.length >= 2)
      .map(([k, ...v]) => [k.trim(), v.join(":").trim()]),
  );
};

// Nine sessions: one current device + eight revokable ones — one past the
// measured break point, so this fixture renders the shape that broke.
const TALL_SESSIONS = Array.from({ length: 9 }, (_, i) => ({
  id: "sess_" + i,
  user_agent: i === 0
    ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/126.0"
    : "barkpark-cli/0.9",
  ip_address: "84.212.31." + (7 + i),
  last_used_at: new Date(Date.now() - (i + 1) * 3600 * 1000).toISOString(),
  current: i === 0,
}));

test("GR63: the 9-session account modal is TALL and buries its escape hatches below the list", () => {
  const rows = TALL_SESSIONS.map((s) => hooks.sessionRowHtml(s)).join("");
  assert.equal((rows.match(/class="session-row"/g) || []).length, 9,
    "the fixture must render nine session rows — 8 fit in a 900px viewport, 9 do not");
  assert.equal((rows.match(/session-revoke/g) || []).length, 8,
    "the current device is never self-revokable; the other eight are");

  // Splice the rows into the real body exactly where loadSessions puts them.
  const body = hooks.accountModalHtml(hooks.accountModel({ team_id: "team_abc" }, ACCT_ME));
  const html = body.replace(/(<div id="sessions-box"[^>]*>)[\s\S]*?(<\/div>)/, "$1" + rows + "$2");

  // The controls that were unreachable on live all sit AFTER the session list —
  // which is exactly why an unscrollable root strands them.
  const lastRow = html.lastIndexOf("session-row");
  for (const id of ["modal-logout", "am-2fa-start"]) {
    const at = html.indexOf('id="' + id + '"');
    if (at === -1) continue; // 2FA start only renders in the not-enrolled arm
    assert.ok(at > lastRow, id + " sits below the session list — it needs a scroll path");
  }
  assert.ok(html.includes('id="modal-logout"'), "Log out is the app's only logout affordance");
});

test("GR63: the SHARED modal root can scroll, and the card still centres when it fits", () => {
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  const root = declsOf(css, ".modal-root");

  // The scroll path itself. This is the assertion that reds against pre-fix CSS.
  assert.match(root["overflow-y"] || "", /^(auto|scroll)$/,
    "the modal root must be able to scroll a card taller than the viewport");

  // …and it must not be vertically centred, which is what pinned the overflow
  // out of reach in BOTH directions (a centred grid item overflows above the
  // scroll origin, so even a scrollable root cannot reach its top).
  assert.equal(root["place-items"], undefined,
    "`place-items` sets align-items too — set justify-items separately so align stays start");
  assert.equal(root["align-items"], "start",
    "a tall card must grow DOWNWARD from the top of the scroll box");

  // Short modals must still read as centred: `margin: auto 0` on the card makes
  // the free space split evenly whenever there IS free space.
  const card = declsOf(css, ".modal-card");
  assert.match(card["margin"] || "", /\bauto\b/,
    "the card keeps true vertical centring while it fits");
  assert.equal(card["max-width"], "420px", "the shared base width is untouched");

  // The scrim must not scroll away from under a tall card.
  assert.equal(declsOf(css, ".modal-backdrop")["position"], "fixed",
    "the backdrop covers the viewport, not just the first screenful");

  // The fix is on the SHARED primitive, not scoped to the account modal —
  // every tall modal (launch, env editor, confirm sheets) inherits the bug.
  const scoped = css.match(/\.modal-root:has\(\.am-modal\)\s*\{([^}]*)\}/);
  assert.ok(!scoped || !/overflow/.test(scoped[1]),
    "the overflow fix must not be :has(.am-modal)-scoped");
});

// ── gr-p5-account-2fa · the identity band degrades honestly ────────────────

test("gr-p5-2fa: the identity line never invents an identity it wasn't given", () => {
  const line = hooks.accountIdentityLine;
  assert.equal(line({ email: "fjord@jarl.no", role: "owner", teamName: "Guerrilla" }),
    "fjord@jarl.no · owner of Guerrilla");
  // No role → no fabricated one.
  assert.equal(line({ email: "fjord@jarl.no", teamName: "Guerrilla" }), "fjord@jarl.no · member of Guerrilla");
  assert.equal(line({ email: "fjord@jarl.no" }), "fjord@jarl.no");
  // No email at all (e.g. /v1/me hasn't landed) → the raw team id, the same
  // honesty the pre-recomposition body showed, never a made-up name.
  assert.equal(line({ teamId: "team_abc" }), "Team team_abc");
  assert.equal(line({}), "Signed in to Barkpark Cloud");
  assert.equal(line(), "Signed in to Barkpark Cloud");
});

test("gr-p5-2fa: secretGroups makes the manual fallback retypeable", () => {
  assert.equal(hooks.secretGroups("JBSWY3DPEHPK3PXP"), "JBSW Y3DP EHPK 3PXP");
  assert.equal(hooks.secretGroups("jbswy3dp"), "JBSW Y3DP");
  assert.equal(hooks.secretGroups(""), "");
  assert.equal(hooks.secretGroups(null), "");
  assert.equal(hooks.secretGroups("ABC"), "ABC", "a short tail must not be padded or dropped");
});

test("gr-p5: app.css is BRACE-BALANCED — no rule is silently swallowed by an unclosed block", () => {
  // A REAL defect this slice hit (present on main since #4271): a comment's
  // opening `/*` was lost, so `@media (max-width: 620px) {` never closed and
  // every rule after it — the whole tlv-coalesce + domain-checklist families,
  // and this wave's .op-* rules — was nested inside that media query and DEAD
  // above 620px. __css_check has no structural parse (E9 only guards the token
  // blocks), so nothing else would ever catch it. This is that tripwire.
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  let depth = 0, i = 0, inComment = false, firstNegative = -1;
  while (i < css.length) {
    if (inComment) {
      if (css.startsWith("*/", i)) { inComment = false; i += 2; continue; }
      i += 1; continue;
    }
    if (css.startsWith("/*", i)) { inComment = true; i += 2; continue; }
    const c = css[i];
    if (c === "{") depth += 1;
    else if (c === "}") { depth -= 1; if (depth < 0 && firstNegative < 0) firstNegative = i; }
    i += 1;
  }
  assert.equal(firstNegative, -1, "a stray closing brace ends a block early");
  assert.equal(depth, 0, "app.css has " + depth + " unclosed block(s) — every rule after it is nested and dead");
  assert.equal(inComment, false, "an unterminated /* comment eats the rest of the stylesheet");
});

// ── gr-backlog-css-brace-detector · the CSS fixtures are actually RUN ────────
// Both __css_check fixtures document a proof command in their own header, and
// until now neither command was executed by anything: console-harness runs bare
// __css_check.mjs (which scans app.css, never a fixture), so the two regression
// proofs were instruments that could not fail. These two tests execute them,
// and this harness IS run by console-harness — no workflow edit needed.
//
// The two checks are DISJOINT, not redundant, and each test proves that in both
// directions: the E9 fixture reds --swallow-check, and the E10 fixture reds
// --orphan-check while staying GREEN under --swallow-check (the semicolon parse
// genuinely cannot see an orphan terminator). The brace-depth tripwire directly
// above owns the third class — unclosed '{' and stray '}' — which BOTH
// __css_check modes miss; that is why it was not deleted.
const CSS_CHECK = fileURLToPath(new URL("./__css_check.mjs", import.meta.url));
const runCssCheck = (...args) => {
  const r = spawnSync(process.execPath, [CSS_CHECK, ...args], { encoding: "utf8" });
  return { status: r.status, out: (r.stdout || "") + (r.stderr || "") };
};

test("gr-backlog-css: the E9 fixture reds --swallow-check exactly as its header claims", () => {
  const fixture = fileURLToPath(new URL("./__css_check.fixture.css", import.meta.url));
  const r = runCssCheck("--swallow-check", fixture);
  assert.equal(r.status, 1, "the committed #4251 fixture must exit 1 — a green fixture is a dead proof:\n" + r.out);
  assert.match(r.out, /: 1 E9 error\(s\)/, "exactly one E9 error, per the fixture header:\n" + r.out);
  // AND the diagnostic must name the file it actually READ. The E9 message hard-
  // coded "app.css" until this wave, so the fixture run cited a file it never
  // opened — a report that misnames its own subject, which is precisely the class
  // this checker exists to catch. Same shape as --orphan-check, pinned below.
  assert.match(r.out, /E9 __css_check\.fixture\.css:\d+/, "E9 must cite the scanned file:\n" + r.out);
  assert.ok(!/E9 app\.css:/.test(r.out), "E9 cited app.css while scanning a fixture:\n" + r.out);
});

test("gr-backlog-css: the E10 fixture reds --orphan-check and ONLY --orphan-check", () => {
  const fixture = fileURLToPath(new URL("./__css_check.orphan.fixture.css", import.meta.url));
  const red = runCssCheck("--orphan-check", fixture);
  assert.equal(red.status, 1, "the committed #4592/GR74 fixture must exit 1:\n" + red.out);
  assert.match(red.out, /: 1 E10 error\(s\)/, "exactly one E10 error, per the fixture header:\n" + red.out);
  assert.match(red.out, /orphan '\*\/' outside any comment/, "and it must be the orphan-terminator diagnosis:\n" + red.out);
  assert.match(red.out, /E10 __css_check\.orphan\.fixture\.css:\d+/, "E10 must cite the scanned file:\n" + red.out);
  // The other direction: E9's semicolon-delimited parse is blind to this class,
  // so the two modes are pinned as complements rather than substitutes.
  const green = runCssCheck("--swallow-check", fixture);
  assert.equal(green.status, 0, "E9 does not see the orphan class — that is E10's whole reason to exist:\n" + green.out);
  // Inherited obligation from the E9 fixture header: a fixture .css that the
  // served bundle can reach is not a fixture, it is live CSS. Asserted, not
  // asserted-in-prose.
  const indexHtml = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const appJs = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  for (const name of ["__css_check.fixture.css", "__css_check.orphan.fixture.css", "__css_check.wrapparity.fixture.css"]) {
    assert.ok(!indexHtml.includes(name), name + " must never be linked from index.html");
    assert.ok(!appJs.includes(name), name + " must never be loaded by the SPA");
  }
});

// ── cch-w19-s4 · E14 wrap-recipe parity, driven in every direction ──────────
// Charter D220 REFUSED D210's fourth-host extraction trigger and replaced it
// with this instrument: the five-declaration recipe does not fix the fourth
// host (driven — every clipped op-gate cell stays clipped), so host COUNT was
// never the sin. DIVERGENCE between the three hand-built copies is, and nothing
// measured it. These tests execute the committed fixture two-directionally the
// way the E9/E10 pair above does, and additionally DRIVE the three design
// choices that make the predicate correct — each is load-bearing, and each
// would be silently "simplified" away without a leg that fails when it is.
const wrapTmp = (name, css) => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "bp-wrapparity-"));
  const f = path.join(d, name);
  fs.writeFileSync(f, css, "utf8");
  return f;
};
// The three PINNED survivors, byte-identical cores under three DIFFERENT
// jackets. Every synthetic case below is built on top of these so the two
// anti-vacuity guards (zero copies, missing pinned host) never mask the leg
// under test.
const WRAP_SURVIVORS = [
  ".detail-rail .status-pill { white-space: normal; height: auto; min-height: 24px; padding-top: 2px; padding-bottom: 2px; }",
  ".fleet-status .status-pill { white-space: normal; height: auto; min-height: 24px; padding-top: 2px; padding-bottom: 2px; align-items: flex-start; }",
  ".instance-card-head .status-pill { white-space: normal; height: auto; min-height: 24px; padding-top: 2px; padding-bottom: 2px; align-items: flex-start; }",
].join("\n");
const WRAP_CORE_TEXT = "white-space: normal; height: auto; min-height: 24px; padding-top: 2px; padding-bottom: 2px;";

test("cch-w19-s4: the E14 fixture reds --wrap-parity-check and ONLY --wrap-parity-check", () => {
  const fixture = fileURLToPath(new URL("./__css_check.wrapparity.fixture.css", import.meta.url));
  const red = runCssCheck("--wrap-parity-check", fixture);
  assert.equal(red.status, 1, "the committed D220 fixture must exit 1 — a green fixture is a dead proof:\n" + red.out);
  assert.match(red.out, /1 E14 error\(s\)/, "exactly one E14 error, per the fixture header:\n" + red.out);
  assert.match(red.out, /\.op-gate \.status-pill declares/, "and it must name the drifting copy:\n" + red.out);
  assert.match(red.out, /min-height: 24px \(not declared\)/, "and the MISSING declaration, not just 'diverges':\n" + red.out);
  // E9's lesson, inherited: the diagnostic cites the file it actually READ.
  assert.match(red.out, /E14 __css_check\.wrapparity\.fixture\.css:\d+/, "E14 must cite the scanned file:\n" + red.out);
  assert.ok(!/E14 app\.css:/.test(red.out), "E14 cited app.css while scanning a fixture:\n" + red.out);
  // The other direction: the sibling fixture modes are blind to this class, so
  // the three are pinned as complements rather than substitutes.
  for (const flag of ["--swallow-check", "--orphan-check"]) {
    const green = runCssCheck(flag, fixture);
    assert.equal(green.status, 0, flag + " does not see declaration divergence — that is E14's reason to exist:\n" + green.out);
  }
});

test("cch-w19-s4: E14 does NOT assert the jacket — a jacketless fourth host greens", () => {
  // DESIGN CHOICE 2, driven. align-items / the -dot and -detail rules / the
  // wrapper's own flex-wrap are per-HOST: .detail-rail ships none of them. A
  // fourth host carrying the bare five and nothing else is LEGAL, and this is
  // the leg that makes it so rather than arguing it in a comment.
  const f = wrapTmp("jacketless.css", WRAP_SURVIVORS + "\n.op-gate .status-pill { " + WRAP_CORE_TEXT + " }\n");
  const r = runCssCheck("--wrap-parity-check", f);
  assert.equal(r.status, 0, "a jacketless fourth host with the full core must GREEN:\n" + r.out);
  assert.match(r.out, /4 wrapper-scoped wrap copy\(ies\)/, "and it must be COUNTED as the fourth copy:\n" + r.out);
  assert.match(r.out, /0 E14 error\(s\)/, r.out);
});

test("cch-w19-s4: a fourth host dropping one core declaration reds under BOTH combinators", () => {
  // The predicate must not be evadable by swapping the descendant combinator
  // for a child combinator — a drifting copy written `.op-gate > .status-pill`
  // is the same defect on screen.
  for (const sel of [".op-gate .status-pill", ".op-gate > .status-pill"]) {
    const f = wrapTmp("drift.css", WRAP_SURVIVORS + "\n" + sel + " { white-space: normal; height: auto; padding-top: 2px; padding-bottom: 2px; }\n");
    const r = runCssCheck("--wrap-parity-check", f);
    assert.equal(r.status, 1, sel + " drops min-height and must RED:\n" + r.out);
    assert.match(r.out, /1 E14 error\(s\)/, "and exactly one — the three survivors stay ok:\n" + r.out);
    assert.match(r.out, /\.op-gate/, "and the error must name the drifting host:\n" + r.out);
    for (const ok of [".detail-rail", ".fleet-status", ".instance-card-head"]) {
      assert.ok(!new RegExp("E14 [^\\n]*\\" + ok + " \\.status-pill declares").test(r.out), ok + " must not be blamed:\n" + r.out);
    }
  }
});

test("cch-w19-s4: the trigger is the DECLARATION, not the selector", () => {
  // DESIGN CHOICE 1, driven. A wrapper-scoped rule touching none of the five is
  // not a wrap copy: it is not counted and it cannot red. Without this, every
  // future `.foo .status-pill { margin-left: 4px }` would be false-redded and
  // the check would be turned off within a wave.
  const f = wrapTmp("outofscope.css", WRAP_SURVIVORS + "\n.some-rail .status-pill { margin-left: 4px; }\n");
  const r = runCssCheck("--wrap-parity-check", f);
  assert.equal(r.status, 0, "a wrapper-scoped rule declaring no core property must not red:\n" + r.out);
  assert.match(r.out, /3 wrapper-scoped wrap copy\(ies\)/, "and must not even be COUNTED as a copy:\n" + r.out);
  assert.ok(!/some-rail/.test(r.out), "and must not be mentioned at all:\n" + r.out);
});

test("cch-w19-s4: a vacuous green is refused — zero copies is an ERROR", () => {
  // A scan that stops seeing the copies would otherwise report the stylesheet
  // clean, which is the exact failure mode this epic keeps finding in gates.
  const f = wrapTmp("empty.css", ".status-pill { height: 24px; white-space: nowrap; }\n");
  const r = runCssCheck("--wrap-parity-check", f);
  assert.equal(r.status, 1, "zero wrapper-scoped copies must exit 1, not report clean:\n" + r.out);
  assert.match(r.out, /ZERO wrapper-scoped \.status-pill wrap copies found/, r.out);
  // And the base rule is excluded by SELECTOR SHAPE, not by an allowlist: it
  // declares core properties at non-core values by design and is invisible here.
  assert.match(r.out, /0 wrapper-scoped wrap copy\(ies\)/, "the bare .status-pill must not count as a copy:\n" + r.out);
});

test("cch-w19-s4: the three survivor selectors are pinned — losing one reds", () => {
  // The zero-guard cannot see PARTIAL blindness: a scan degrading to 1 of 3
  // still reports clean. These pins close that, and they are same-file pins of
  // this repo's OWN selectors (pin-your-own, derive-foreign).
  for (const host of [".detail-rail", ".fleet-status", ".instance-card-head"]) {
    const kept = WRAP_SURVIVORS.split("\n").filter((l) => !l.startsWith(host + " ")).join("\n");
    const f = wrapTmp("missing.css", kept + "\n");
    const r = runCssCheck("--wrap-parity-check", f);
    assert.equal(r.status, 1, "removing " + host + " must red:\n" + r.out);
    assert.match(r.out, new RegExp("the pinned wrap copy .\\" + host + " \\.status-pill. is MISSING"), r.out);
  }
});

test("cch-w19-s4: E14 greens app.css's OWN bytes and sees all three copies there", () => {
  // The shipped tree is the subject the check was written for. If it cannot
  // green there it will be deleted, and if it cannot SEE there it is decorative.
  const appCss = fileURLToPath(new URL("./app.css", import.meta.url));
  const r = runCssCheck("--wrap-parity-check", appCss);
  assert.equal(r.status, 0, "app.css must be green under E14:\n" + r.out);
  assert.match(r.out, /3 wrapper-scoped wrap copy\(ies\)/, r.out);
  for (const host of [".detail-rail", ".fleet-status", ".instance-card-head"]) {
    assert.match(r.out, new RegExp("\\" + host + " \\.status-pill:\\d+"), host + " must be seen with a line number:\n" + r.out);
  }
});

// ── gr-p5 OPERATOR CONSOLE (GR39/GR40/GR48/GR49/GR50) ───────────────────────
// THE crown surface: the #operator view rendered honest over the real rollout
// machinery. Pinned here: the fail-closed ROUTE gate (applyRoute is not
// hook-exported, so the predicate it consults is), the four cards' pure
// derivations against the PROBE-VERIFIED wire bytes, and the four anti-drift
// source guards GR49 asks for (one route literal, one action emitter, zero
// /v1/admin/autoupdate, zero fleetStrip* consumption).

const APP_SRC = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");

test("gr-p5: the operator console's pure helpers ride the ONE test hook", () => {
  for (const name of [
    "operatorRouteAllowed", "operatorRowState", "operatorFleetSort",
    "operatorStagingGateCopy", "operatorBrakeCardHtml", "operatorCanaryCardHtml",
    "operatorWarmPoolCardHtml", "operatorDigestCardHtml", "operatorPageHtml",
  ]) assert.equal(typeof hooks[name], "function", name + " is exported");
  assert.equal(hooks.OPERATOR_SETTLE_MIN, 20, "the settle grace is 20 minutes, never 30 (GR40)");
});

test("gr-p5: operatorRouteAllowed is FAIL-CLOSED — only user.platform_operator === true opens #operator", () => {
  assert.equal(hooks.operatorRouteAllowed(undefined), false, "me not loaded → closed");
  assert.equal(hooks.operatorRouteAllowed(null), false);
  assert.equal(hooks.operatorRouteAllowed({}), false);
  assert.equal(hooks.operatorRouteAllowed({ user: {} }), false);
  assert.equal(hooks.operatorRouteAllowed({ user: { platform_operator: false } }), false);
  assert.equal(hooks.operatorRouteAllowed({ user: { platform_operator: "yes" } }), false, "truthy-but-not-true stays closed");
  // GR37: the flag is NESTED under `user`; a flat read must never open the gate.
  assert.equal(hooks.operatorRouteAllowed({ platform_operator: true }), false, "a flat flag is not the contract");
  assert.equal(hooks.operatorRouteAllowed({ user: { platform_operator: true } }), true);
  // The route gate and the sidebar gate are ONE truth — never two vocabularies.
  for (const me of [null, {}, { user: { platform_operator: true } }, { user: { platform_operator: 1 } }]) {
    assert.equal(hooks.operatorRouteAllowed(me), hooks.operatorVisible(me));
  }
});

test("gr-p5: #operator is a registered route (the sidebar link finally lands on a page)", () => {
  const orig = sandbox.location.hash;
  try {
    sandbox.location.hash = "#operator";
    assert.equal(hooks.parseHash().view, "operator");
    // It is NOT a settings page and NOT a drill-down — a bare tab route.
    sandbox.location.hash = "#settings/operator";
    assert.equal(hooks.parseHash().view, "overview", "there is no settings/operator page");
  } finally {
    sandbox.location.hash = orig;
  }
});

test("gr-p5: the Operator sidebar entry is data-view tagged, so #operator lights it", () => {
  // applyRoute's highlight loop is document.querySelectorAll(".nav-link[data-view]")
  // and activeNav for this route is the bare view name. A link without the
  // attribute is invisible to that loop: the page painted with NO nav entry
  // active and no aria-current="page" anywhere.
  const indexHtml = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const link = indexHtml.match(/<a[^>]*id="nav-operator"[^>]*>/);
  assert.ok(link, "the Operator sidebar entry exists");
  assert.match(link[0], /data-view="operator"/);
  assert.match(link[0], /href="#operator"/);
});

// ── card 1: the brake (GR49 — one derivation, never restated copy) ───────────

test("gr-p5: operatorBrakeCardHtml is a SECOND presentation of the SHARED banner model", () => {
  for (const state of [{ halted: false }, { halted: true, halted_reason: "bad release 0.5.0" }]) {
    const shared = hooks.fleetRolloutBanner(state);
    const card = hooks.operatorBrakeCardHtml(state);
    assert.ok(card.includes(shared.title), "the card carries the SHARED title: " + shared.title);
    assert.ok(card.includes(shared.actionLabel), "the card carries the SHARED action label");
    assert.ok(card.includes('data-fleet-au="' + shared.verb + '"'), "the console owns the action control");
  }
  // Honest degrade: the route didn't answer → say so about THIS card, never fake a state.
  const dead = hooks.operatorBrakeCardHtml(null);
  assert.match(dead, /Rollout state unavailable/);
  assert.doesNotMatch(dead, /data-fleet-au/, "an unreadable brake offers no button");
  // The halt consequence is stated honestly: advance stops, in-flight keeps settling.
  assert.match(hooks.operatorBrakeCardHtml({ halted: false }), /nothing is rolled back/);
});

// ── card 2: the canary (GR48 wire shape + GR50 copy) ─────────────────────────

test("gr-p5: operatorRowState renders ALL FOUR update_state values, unknown reads calm", () => {
  assert.deepEqual(
    ["current", "behind", "disabled", "unknown"].map((s) => hooks.operatorRowState({ update_state: s }).label),
    ["Current", "Behind", "Autoupdate off", "Unknown"],
  );
  assert.equal(hooks.operatorRowState({ update_state: "current" }).role, "ok");
  assert.equal(hooks.operatorRowState({ update_state: "behind" }).role, "warn");
  // `unknown` is the COMMON freshly-registered case (GR48) — neutral, not alarming.
  assert.equal(hooks.operatorRowState({ update_state: "unknown" }).role, "neutral");
  assert.equal(hooks.operatorRowState({ update_state: "disabled" }).role, "neutral");
  // A missing/absent state is `unknown`, and a hostile one never throws.
  assert.equal(hooks.operatorRowState({}).label, "Unknown");
  assert.equal(hooks.operatorRowState(null).label, "Unknown");
});

test("gr-p5: operatorRowState settle math — null-guarded, 20m grace, overdue is pause-not-retry", () => {
  const now = Date.parse("2026-07-19T18:00:00.000000Z");
  // GR48: autoupdate_triggered_at is NULL for a freshly-registered box.
  assert.equal(hooks.operatorRowState({ update_state: "behind", autoupdate_triggered_at: null }, now).label, "Behind");
  // Six microsecond digits + literal Z — the real serializer shape.
  const at12 = "2026-07-19T17:48:00.000000Z";
  const settling = hooks.operatorRowState({ update_state: "behind", autoupdate_triggered_at: at12 }, now);
  assert.equal(settling.label, "SETTLE — 12m of 20m");
  // Elapsed FLOORS (a wait of 11m59s reads 11m — never rounded up into a minute
  // that hasn't passed), and the six-microsecond serializer shape parses fine.
  assert.equal(
    hooks.operatorRowState({ update_state: "behind", autoupdate_triggered_at: "2026-07-19T17:48:00.932308Z" }, now).label,
    "SETTLE — 11m of 20m",
  );
  assert.equal(settling.role, "info");
  // In-flight WINS over update_state (that is what the worker's settle pass watches).
  assert.match(hooks.operatorRowState({ update_state: "current", autoupdate_triggered_at: at12 }, now).label, /^SETTLE/);
  const overdue = hooks.operatorRowState({ update_state: "behind", autoupdate_triggered_at: "2026-07-19T17:30:00.000000Z" }, now);
  assert.equal(overdue.label, "SETTLE — overdue past 20m");
  assert.match(overdue.note, /pauses this instance instead of retrying it/,
    "the overdue note states the worker's real behaviour: pause, not retry");
  // A garbage timestamp degrades to the update_state, never NaN.
  assert.equal(hooks.operatorRowState({ update_state: "behind", autoupdate_triggered_at: "nonsense" }, now).label, "Behind");
});

test("gr-p5: operatorStagingGateCopy renders THREE states — open is not automatically a vouch", () => {
  const staging = [{ channel: "staging" }, { channel: "prod" }];
  const prodOnly = [{ channel: "prod" }, { channel: "prod" }];
  assert.match(hooks.operatorStagingGateCopy(true, staging).text, /open — a staging instance is current on the newest release\./);
  // The fail-OPEN branch (zero staging boxes) — the state prod is in TODAY.
  assert.match(hooks.operatorStagingGateCopy(true, prodOnly).text, /open — no staging instance is registered, so prod advances with nothing ahead of it\./);
  assert.match(hooks.operatorStagingGateCopy(false, staging).text, /closed — staging is behind or paused, so no prod instance advances\./);
  assert.equal(hooks.operatorStagingGateCopy(true, prodOnly).role, "neutral", "fail-open is not a green vouch");
  assert.equal(hooks.operatorStagingGateCopy(true, staging).role, "ok");
  assert.equal(hooks.operatorStagingGateCopy(false, []).role, "warn");
});

test("gr-p5: operatorFleetSort walks the rollout's own order — in-flight, staging, behind, rest", () => {
  const rows = [
    { name: "zeta-prod", channel: "prod", update_state: "current" },
    { name: "beta-prod", channel: "prod", update_state: "behind" },
    { name: "canary", channel: "staging", update_state: "current" },
    { name: "alpha-prod", channel: "prod", update_state: "behind", autoupdate_triggered_at: "2026-07-19T17:50:00.000000Z" },
    { name: "aaa-prod", channel: "prod", update_state: "current" },
  ];
  assert.deepEqual(hooks.operatorFleetSort(rows).map((r) => r.name),
    ["alpha-prod", "canary", "beta-prod", "aaa-prod", "zeta-prod"]);
  assert.equal(hooks.operatorFleetSort([]).length, 0);
  assert.equal(hooks.operatorFleetSort(null).length, 0, "a missing list is empty, never a throw");
  // Pure: the input array is never mutated.
  const input = [{ name: "b" }, { name: "a" }];
  hooks.operatorFleetSort(input);
  assert.equal(input[0].name, "b");
});

test("gr-p5: operatorCanaryCardHtml reads the REAL envelope — staging_gate_open is TOP-LEVEL", () => {
  const now = Date.parse("2026-07-19T18:00:00.000000Z");
  const data = {
    barkparks: [
      { id: "5b2c1e00-0000-4000-8000-0000000000a1", name: "acme-prod", channel: "prod", update_state: "unknown", autoupdate_triggered_at: null },
      { id: "5b2c1e00-0000-4000-8000-0000000000a2", name: "acme-canary", channel: "staging", update_state: "current", autoupdate_triggered_at: null },
    ],
    staging_gate_open: true,
  };
  const html = hooks.operatorCanaryCardHtml(data, now);
  assert.ok(html.includes("acme-prod") && html.includes("acme-canary"), "every instance renders");
  assert.ok(html.includes("5b2c1e00"), "the row carries the id head an operator can grep on");
  assert.match(html, /a staging instance is current/, "the TOP-LEVEL gate flag drives the gate line");
  // A per-row staging_gate_open is NOT the contract and must not be read.
  const perRow = hooks.operatorCanaryCardHtml({ barkparks: [{ name: "x", channel: "prod", staging_gate_open: true }] });
  assert.match(perRow, /closed — staging is behind or paused/, "an absent top-level flag reads closed, never per-row");
  // GR40/GR50 vocabulary: 20 minutes, serial, pause-not-retry — and NEVER 30m.
  assert.match(html, /Gates: SETTLE 20m &rarr; health GATE &rarr; ADVANCE/);
  assert.match(html, /hasn't reported itself current within 20 minutes is paused, not retried/);
  assert.match(html, /serial — one instance at a time/);
  assert.ok(!html.includes("30m") && !html.includes("30 minutes"), "the design mock's 30m is never rendered");
  // Empty + unreadable states.
  assert.match(hooks.operatorCanaryCardHtml({ barkparks: [], staging_gate_open: true }), /No instances are registered yet/);
  assert.match(hooks.operatorCanaryCardHtml(null), /Fleet unavailable/);
  // Hostile server strings are escaped, never injected.
  const evil = hooks.operatorCanaryCardHtml({ barkparks: [{ name: "<img src=x onerror=alert(1)>", channel: "prod" }], staging_gate_open: false });
  assert.doesNotMatch(evil, /<img src=x/);
  assert.match(evil, /&lt;img/);
});

// ── card 3: warm pool (GR50 — one number, no denominator exists) ─────────────

test("gr-p5: operatorWarmPoolCardHtml renders ONE number — no bar, no percentage, no invented total", () => {
  const two = hooks.operatorWarmPoolCardHtml({ ready: 2 });
  assert.match(two, /op-metric-v">2</);
  assert.match(two, /boxes ready/);
  assert.match(two, /there's no total to compare against/);
  assert.match(two, /Boxes being claimed or retired are already on their way out/);
  assert.ok(!two.includes("usage-bar") && !two.includes("%"), "no bar and no percentage — there is no denominator");
  assert.ok(!/\bof\s+\d/.test(two), "never renders an 'n of m' fiction");
  assert.match(hooks.operatorWarmPoolCardHtml({ ready: 1 }), /box ready/, "singular reads right");
  // Zero is a DESIGNED state, not an error.
  const zero = hooks.operatorWarmPoolCardHtml({ ready: 0 });
  assert.match(zero, /The pool is empty right now\./);
  assert.match(zero, /Launches still work — they provision a cold box instead of claiming a warm one\./);
  assert.doesNotMatch(zero, /unavailable/, "an empty pool is never reported as an error");
  // Unreadable is about THIS CARD, never about the pool.
  const dead = hooks.operatorWarmPoolCardHtml(null);
  assert.match(dead, /Warm pool unavailable — the count didn't answer\./);
  assert.match(dead, /this card just couldn't read it/);
  assert.match(hooks.operatorWarmPoolCardHtml({}), /Warm pool unavailable/, "a shapeless answer is unreadable, not zero");
});

// ── card 4: fleet digest (GR40 — no send-now route, so no send-now button) ───

test("gr-p5: operatorDigestCardHtml — empty is the TRUE state, and there is NO Send-now button", () => {
  const empty = hooks.operatorDigestCardHtml([]);
  assert.match(empty, /No fleet digest has been sent yet\./);
  assert.match(empty, /daily at 06:00 UTC to the platform-operator addresses/);
  const rows = hooks.operatorDigestCardHtml([
    { id: "d1", status: "sent", event: "fleet_digest", channel: "email", recipient: "ops@barkpark.cloud", attempts: 1, inserted_at: "2026-07-19T06:00:01.932308Z", last_error: null, http_status: null },
    { id: "d2", status: "failed", event: "fleet_digest", channel: "email", recipient: "ops@barkpark.cloud", attempts: 3, inserted_at: "2026-07-18T06:00:02.100000Z", last_error: "smtp timeout", http_status: null },
  ]);
  assert.ok(rows.includes("ops@barkpark.cloud"), "the recipient renders");
  assert.ok(rows.includes("Sent") && rows.includes("Failed"), "both delivery outcomes render");
  assert.ok(rows.includes("smtp timeout"), "a failure carries its verbatim last_error");
  for (const html of [empty, rows, hooks.operatorDigestCardHtml(null)]) {
    assert.ok(!/Send (one )?now/i.test(html), "no send-now button — no route calls deliver_fleet_digest (GR40)");
  }
  assert.match(hooks.operatorDigestCardHtml(null), /Digest log unavailable/);
});

test("gr-p5: operatorPageHtml composes the four cards, each with its own body slot", () => {
  const html = hooks.operatorPageHtml();
  for (const heading of ["Rollout brake", "Canary rollout", "Warm pool", "Fleet digest"])
    assert.ok(html.includes(heading), "the page carries the " + heading + " card");
  for (const id of ["op-brake-body", "op-canary-body", "op-warm-body", "op-digest-body"])
    assert.ok(html.includes('id="' + id + '"'), "each card owns its body slot: " + id);
  assert.equal((html.match(/class="set-section"/g) || []).length, 4, "four cards on the shared .set-* anatomy");
  // No instance-lifecycle verbs live on this page (EXIT.md:13).
  assert.ok(!/Suspend|Decommission|Archive|Delete instance/i.test(html), "no lifecycle admin verbs");
});

// ── GR49 anti-drift source guards (the console is the SOLE brake control) ────

test("gr-p5 GR49: ONE route literal, ONE action emitter, ZERO worker-gated probes", () => {
  assert.equal((APP_SRC.match(/\/v1\/admin\/autoupdate/g) || []).length, 0,
    "the require_worker route (401-dead to a browser session) is gone from app.js");
  assert.equal((APP_SRC.match(/"\/v1\/operator\/autoupdate"/g) || []).length, 1,
    "the operator autoupdate route literal is defined exactly ONCE");
  assert.equal((APP_SRC.match(/data-fleet-au="/g) || []).length, 1,
    "exactly one emitter of the brake action attribute");
  // Fleet is demoted to a READ-ONLY, halted-only banner that points at #operator.
  const readonly = hooks.fleetRolloutBannerHtml({ halted: true }, { readonly: true });
  assert.doesNotMatch(readonly, /data-fleet-au/, "the team-scoped Fleet banner carries no fleet-wide button");
  assert.match(readonly, /href="#operator"/, "it points at the one place the brake is operated");
  // The DEFAULT (one-arg) call keeps the button, so the existing pins stay green.
  assert.match(hooks.fleetRolloutBannerHtml({ halted: true }), /data-fleet-au="resume"/);
});

test("gr-p5 GR42/GR51: the operator console consumes ZERO fleetStrip* helpers", () => {
  const start = APP_SRC.indexOf("OPERATOR CONSOLE");
  const end = APP_SRC.indexOf("function railRow(", start);
  assert.ok(start > 0 && end > start, "the operator console block is locatable");
  const block = APP_SRC.slice(start, end);
  assert.equal((block.match(/fleetStrip/g) || []).length, 0, "no fleetStrip* consumption in the operator console");
  assert.equal((block.match(/FLEET_STRIP/g) || []).length, 0);
});

// ── gr-p5 GR41: danger-no-echo confirm tier, rich-body slot, toast shape ─────
// The shared confirm modal's THIRD tier (btn-danger weight WITHOUT the typed
// echo — for grave-but-reversible actions like rollbacks) plus the trusted
// rich-body slot, ADDITIVE to the mutate/destroy grammar; and the toast-input
// normalizer that keeps a bare-string call from rendering an empty dead toast.

test("gr41: danger tier is armed from the start — btn-danger weight, no typed echo", () => {
  const s = hooks.confirmModalInit({
    tier: "danger", title: "Roll back x?", confirmLabel: "Roll back",
  });
  assert.equal(s.tier, "danger");
  assert.equal(s.resourceName, null);                    // echo is destroy-only
  assert.equal(hooks.confirmModalTypedMatch(s), true);   // no echo gate
  assert.equal(hooks.confirmModalArmed(s), true);        // live immediately
  const html = hooks.confirmModalHtml(s);
  assert.match(html, /btn-danger/);                      // danger weight
  assert.doesNotMatch(html, /cm-typed/);                 // no echo input
  assert.doesNotMatch(html, /id="cm-confirm" disabled/); // ships enabled
  assert.doesNotMatch(html, /btn-primary/);              // never reads as a safe primary
});

test("gr41: danger tier walks the same reducer — busy → inline error stays armed for recovery", () => {
  let s = hooks.confirmModalInit({ tier: "danger", title: "T" });
  s = hooks.confirmModalReduce(s, { type: "confirm" });
  assert.equal(s.phase, "busy");
  s = hooks.confirmModalReduce(s, { type: "fail", message: "nope" });
  assert.equal(s.phase, "error");
  assert.equal(s.error, "nope");
  assert.equal(hooks.confirmModalArmed(s), true); // recovery can re-enter busy
});

test("gr41: the rich-body slot renders TRUSTED caller markup raw, on any tier, and is absent by default", () => {
  const danger = hooks.confirmModalHtml(hooks.confirmModalInit({
    tier: "danger", title: "Roll back?", bodyHtml: "Schema stays <b>forward</b>.",
  }));
  assert.match(danger, /cm-body/);
  assert.match(danger, /Schema stays <b>forward<\/b>\./); // raw, not esc'd — the slot is trusted
  const mutate = hooks.confirmModalHtml(hooks.confirmModalInit({
    title: "Redeploy?", bodyHtml: "Same <b>source</b>.",
  }));
  assert.match(mutate, /Same <b>source<\/b>\./);          // additive: not danger-exclusive
  const plain = hooks.confirmModalHtml(hooks.confirmModalInit({ title: "T", consequence: "C" }));
  assert.doesNotMatch(plain, /cm-body/);                  // no slot → no empty element
});

test("gr41: toastShape coerces a bare string to {title} so a legacy call never renders an empty toast", () => {
  assert.deepEqual(plain(hooks.toastShape("Theme saved")), { title: "Theme saved" });
  const obj = { kind: "error", title: "Couldn't save", body: "why" };
  assert.equal(hooks.toastShape(obj), obj);   // object form passes through untouched
  assert.deepEqual(plain(hooks.toastShape(null)), {});      // total over junk
  assert.deepEqual(plain(hooks.toastShape(undefined)), {});
});

// ── gr-p2-front-door: the v4 front door (B-01..B-03) ────────────────────────
// The sign-in card's initial-tab classifier, the 2FA card's AUTH-scoped
// vocabulary (GR21: theater's .new-title/.new-desc never render on an auth
// surface), and the DELIBERATE 60s rate-limit countdown pin.

test("authModeFromHash: #signup / #/auth/signup land the Create-account tab; all else login", () => {
  assert.equal(typeof hooks.authModeFromHash, "function", "authModeFromHash must be exported");
  assert.equal(hooks.authModeFromHash("#signup"), "signup");
  assert.equal(hooks.authModeFromHash("#/auth/signup"), "signup");
  for (const h of ["", "#", "#overview", "#login", "#signup2", "#/auth/signup?x=1",
    "#/auth/reset?token=x", null, undefined]) {
    assert.equal(hooks.authModeFromHash(h), "login", JSON.stringify(h) + " → login");
  }
});

test("gr-p2: every 2FA card state composes in the AUTH vocabulary — zero theater classes", () => {
  for (const opts of [{ mode: "otp" }, { mode: "recovery" },
    { mode: "otp", rateLimited: true }, { mode: "otp", error: "invalid_code" }]) {
    const html = hooks.twoFactorCardHtml(opts);
    assert.match(html, /class="auth-title"/, JSON.stringify(opts) + " must carry .auth-title");
    assert.match(html, /class="auth-desc"/, JSON.stringify(opts) + " must carry .auth-desc");
    assert.doesNotMatch(html, /new-title|new-desc/,
      JSON.stringify(opts) + " must not import theater vocabulary");
  }
});

test("gr-p2: TFA_RATE_WAIT_S is DELIBERATELY 60 — the backend window is a fixed 60s", () => {
  // two_factor_rate_limiter.ex: @limit 5, @window_ms 60_000. The old 30s
  // countdown re-enabled the button INSIDE the same window and re-fired
  // straight into the same 429. A server retry_after seam is backlog
  // (gr-backlog-tfa-retry-after) — until then the constant mirrors the window.
  assert.equal(hooks.twoFactorRateWaitS, 60);
  const html = hooks.twoFactorCardHtml({ mode: "otp", rateLimited: true });
  assert.match(html, /Try again in 60s/); // the countdown copy matches the pin
});

// ── gr-w3 v4 shell: context-morph enum + fail-closed operator gate ──────────
// The sidebar morph is a PURE function of the parsed route (three panes, one
// visible); the operator entry is gated fail-closed on /v1/me.user.platform_operator
// (the flag is NESTED under `user` in the envelope — router.ex me/2 ~1005-1018;
// GR37 fixed a flat read that made the gate a silent prod false-negative).
// Both node-pinned here; their DOM appliers are smoke/browser-driven.

test("gr-w3: the v4 shell pure helpers are exported", () => {
  for (const name of ["shellNavLayer", "operatorVisible", "ctxDotColor",
    "bpThemeLabel", "bpThemeOptions", "resetTokenFromHash"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("shellNavLayer folds the route to exactly one sidebar layer (root|instance|site)", () => {
  assert.equal(hooks.shellNavLayer({ view: "overview" }), "root");
  assert.equal(hooks.shellNavLayer({ view: "fleet" }), "root");
  assert.equal(hooks.shellNavLayer({ view: "billing" }), "root");   // settings stay on root
  assert.equal(hooks.shellNavLayer({ view: "activity" }), "root");
  assert.equal(hooks.shellNavLayer({ view: "instance", id: "x", tab: "overview" }), "instance");
  assert.equal(hooks.shellNavLayer({ view: "site", id: "y" }), "site");
  // Total over junk — a bad/absent route degrades to the root layer, never throws.
  assert.equal(hooks.shellNavLayer({}), "root");
  assert.equal(hooks.shellNavLayer(null), "root");
  assert.equal(hooks.shellNavLayer(undefined), "root");
});

test("operatorVisible is fail-CLOSED — ONLY user.platform_operator===true shows the entry (GR9)", () => {
  // Real /v1/me shape: the flag is NESTED under `user` (router.ex me/2).
  assert.equal(hooks.operatorVisible({ user: { platform_operator: true } }), true);
  // Everything else is hidden: absent field, falsy, or truthy-but-not-true.
  assert.equal(hooks.operatorVisible({ user: { platform_operator: false } }), false);
  assert.equal(hooks.operatorVisible({ user: {} }), false);   // absent → hidden
  assert.equal(hooks.operatorVisible({}), false);             // no user → hidden
  assert.equal(hooks.operatorVisible({ user: { platform_operator: 1 } }), false);      // not === true
  assert.equal(hooks.operatorVisible({ user: { platform_operator: "true" } }), false); // not === true
  // The OLD flat shape must NOT satisfy the gate — this is the regression the
  // GR37 fix closes (a top-level flag was the prod false-negative).
  assert.equal(hooks.operatorVisible({ platform_operator: true }), false);
  assert.equal(hooks.operatorVisible(null), false);
  assert.equal(hooks.operatorVisible(undefined), false);
  // NEVER keyed on team role — an owner without the flag stays hidden.
  assert.equal(hooks.operatorVisible({ role: "owner", user: {} }), false);
});

test("ctxDotColor maps every fleet status kind onto a defined token", () => {
  assert.equal(hooks.ctxDotColor("ok"), "var(--ok)");
  assert.equal(hooks.ctxDotColor("behind"), "var(--ok)");
  for (const bad of ["failed", "removal_failed", "suspended", "degraded"]) {
    assert.equal(hooks.ctxDotColor(bad), "var(--danger)");
  }
  assert.equal(hooks.ctxDotColor("provisioning"), "var(--warn)");
  assert.equal(hooks.ctxDotColor("removing"), "var(--warn)");
  assert.equal(hooks.ctxDotColor(""), "var(--muted-text)");        // unknown → muted
  assert.equal(hooks.ctxDotColor(undefined), "var(--muted-text)");
});

test("bpThemeOptions is a pure projection of the GENERATED enum (all 5 identities, Title labels)", () => {
  const opts = hooks.bpThemeOptions();
  // Spread the vm-realm arrays into test-realm ones so deepEqual compares by value
  // (cross-realm Array prototypes differ — the [...hooks.bpThemes] house pattern).
  assert.deepEqual([...opts.map((o) => o.id)], ["evergreen", "charple", "ember", "fjord", "iris"]);
  assert.deepEqual([...opts.map((o) => o.label)], ["Evergreen", "Charple", "Ember", "Fjord", "Iris"]);
  // charple + iris — the drift GR12 fixes — are REACHABLE from the picker now.
  assert.ok(opts.some((o) => o.id === "charple"));
  assert.ok(opts.some((o) => o.id === "iris"));
  assert.equal(hooks.bpThemeLabel("evergreen"), "Evergreen");
  assert.equal(hooks.bpThemeLabel(""), "");
});

// ── gr-w3 reset-route (GR13): resetTokenFromHash is now exported + pinned ────
test("resetTokenFromHash extracts the emailed reset token, tolerant of encoding", () => {
  const orig = sandbox.location.hash;
  try {
    sandbox.location.hash = "#/auth/reset?token=abc123";
    assert.equal(hooks.resetTokenFromHash(), "abc123");
    // Percent-encoded token round-trips through safeDecode.
    sandbox.location.hash = "#/auth/reset?token=a%2Bb%3Dc";
    assert.equal(hooks.resetTokenFromHash(), "a+b=c");
  } finally {
    sandbox.location.hash = orig;
  }
});

test("resetTokenFromHash returns null for any non-reset hash (never throws)", () => {
  const orig = sandbox.location.hash;
  try {
    for (const h of ["", "#overview", "#instance/9f3c", "#/auth/reset", "#/auth/reset?nope=1", "#/auth/reset?token="]) {
      sandbox.location.hash = h;
      assert.equal(hooks.resetTokenFromHash(), null, JSON.stringify(h) + " → null");
    }
  } finally {
    sandbox.location.hash = orig;
  }
});

test("the test hook exported the helpers under test", () => {
  assert.equal(typeof hooks.esc, "function");
  assert.equal(typeof hooks.safeDecode, "function");
  assert.equal(typeof hooks.parseHash, "function");
  assert.equal(typeof hooks.relTime, "function");
  assert.ok(Array.isArray(hooks.liveEventTypes));
  // IA reshape + attention-rollup pure helpers (charter decisions 6 + 15).
  for (const name of ["legacyRoute", "parseFleetFilter", "classifyBp", "statusOf",
    "attentionRank", "attentionCompare", "bucketOf", "fleetSummary", "filterFleet"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
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

// ── provision-step vocabulary (dwb-14 + C2/D45) ─────────────────────────────
// The /new timeline renders exactly the steps the Go worker reports and the
// control plane's ProvisionJob @steps whitelist accepts. A step missing here is
// invisible in the GUI (newStepStatuses drops unlabeled steps); a step missing
// server-side is 422-swallowed. This pins the SPA side of that contract.

test("provision step order carries the freshen rung and the golden-path verify gate before ready", () => {
  // Spread into a host-realm array — the vm sandbox's Array prototype differs.
  // dwb-17/D10: "freshen" slots between create and secure (freshen precedes migrate).
  assert.deepEqual([...hooks.serverStepOrder], [
    "create", "freshen", "secure", "configure", "content", "verify", "ready",
  ]);
});

test("every provision step has a human label (and no orphan labels)", () => {
  assert.deepEqual(
    Object.keys(hooks.serverStepLabels).sort(),
    [...hooks.serverStepOrder].sort(),
  );
  for (const step of hooks.serverStepOrder) {
    const label = hooks.serverStepLabels[step];
    assert.equal(typeof label, "string");
    assert.ok(label.length > 0, step + " must have a non-empty label");
  }
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

test("parseHash decodes a well-formed instance id (defaulting to the Overview tab)", () => {
  sandbox.location.hash = "#instance/x%25y";
  assert.deepEqual({ ...hooks.parseHash() }, { view: "instance", id: "x%y", tab: "overview" });
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

test("parseHash routes a plain tab and falls back to Overview (the new home) on garbage/empty", () => {
  sandbox.location.hash = "#sites";
  assert.equal(hooks.parseHash().view, "sites");
  sandbox.location.hash = "#garbage";
  assert.equal(hooks.parseHash().view, "overview"); // IA reshape: home is Overview, not Fleet
  sandbox.location.hash = "";
  assert.equal(hooks.parseHash().view, "overview");
  sandbox.location.hash = "#overview";
  assert.equal(hooks.parseHash().view, "overview");
});

// ── legacyRoute: no bookmark or bp-cloud-open deep link ever breaks (D6 + D14) ─

test("legacyRoute keeps the legacy-stable set (D14) untouched, forever", () => {
  for (const h of ["fleet", "sites", "activity", "instance/9f3c", "site/ab12"]) {
    assert.equal(hooks.legacyRoute(h), h);
    assert.equal(hooks.legacyRoute("#" + h), h); // leading # is stripped
  }
});

test("legacyRoute remaps the four Settings pages under #settings/*, empty → overview", () => {
  assert.equal(hooks.legacyRoute("billing"), "settings/billing");
  assert.equal(hooks.legacyRoute("providers"), "settings/providers");
  assert.equal(hooks.legacyRoute("notifications"), "settings/notifications");
  assert.equal(hooks.legacyRoute("tokens"), "settings/tokens");
  assert.equal(hooks.legacyRoute(""), "overview");
  assert.equal(hooks.legacyRoute("#"), "overview");
  assert.equal(hooks.legacyRoute(null), "overview"); // total over junk
});

// ── A4/D66: #launch is no longer a place — bookmark → Overview + open the flow ─
test("legacyRoute('launch') remaps to Overview, and wantsLaunchFlow flags the reopen", () => {
  assert.equal(hooks.legacyRoute("launch"), "overview");
  assert.equal(hooks.legacyRoute("#launch"), "overview");
  assert.equal(hooks.wantsLaunchFlow("launch"), true);
  assert.equal(hooks.wantsLaunchFlow("#launch"), true);
  assert.equal(hooks.wantsLaunchFlow("overview"), false);
  assert.equal(hooks.wantsLaunchFlow("#fleet"), false);
  assert.equal(hooks.wantsLaunchFlow(""), false);
  assert.equal(hooks.wantsLaunchFlow(null), false); // total over junk
});

// ── hashChangeEffects: a modal may not survive a route change (gr-blk-modal-  ─
//    survives-route / GR105) — and the two hash paths that OPEN a modal must
//    keep working. The listener itself is registered inside init(), which never
//    binds in this sandbox, so the DECISION is what is pinned here. A blanket
//    "close on any hashchange" reds the two guard tests below rather than
//    silently blinding the accent x theme shot matrix.
const SIGNED_IN = { newFlow: false, activateFlow: false, signedIn: true };

test("hashChangeEffects closes an open modal when the hash routes ELSEWHERE", () => {
  for (const [from, to] of [
    ["#overview", "#fleet"],
    ["#fleet", "#sites"],
    ["#settings/billing", "#activity"],
    ["#instance/abc", "#instance/def"], // a different instance is a different place
    ["#instance/abc/overview", "#instance/abc/logs"], // …so is a different tab
    ["#fleet", "#fleet/attention"], // …and so is a filtered bucket
    ["#overview", "#/invitations/accept?token=t"],
  ]) {
    const eff = hooks.hashChangeEffects(from, to, SIGNED_IN);
    assert.equal(eff.close, true, `${from} → ${to} must close the modal`);
    assert.equal(eff.route, true, `${from} → ${to} must still route`);
  }
});

test("hashChangeEffects leaves the LEGACY #launch deep link able to open its modal", () => {
  // legacyRoute("launch") === "overview", so #overview → #launch is not a route
  // change: nothing closes, applyRoute runs and openLaunchModal() survives.
  const arrive = hooks.hashChangeEffects("#overview", "#launch", SIGNED_IN);
  assert.equal(arrive.close, false, "#launch must not close the modal it is about to open");
  assert.equal(arrive.route, true, "#launch must still route (that is what opens the flow)");
  // applyRoute normalises the address bar back to /#overview via replaceState.
  // That fires no hashchange at all, but even if it ever did it is route-
  // identical — so it can never tear down the launch modal either.
  assert.equal(hooks.hashChangeEffects("#launch", "#overview", SIGNED_IN).close, false);
  // The flat Settings bookmarks canonicalise the same way — an old #billing
  // link landing on #settings/billing is one place, not two.
  assert.equal(hooks.hashChangeEffects("#billing", "#settings/billing", SIGNED_IN).close, false);
});

test("hashChangeEffects never dismisses the ?modal=account preview seam", () => {
  // The account modal is QUERY-opened (mock.js drives openAccountModal on
  // window load at whatever hash the scenario deep-linked to), so the only
  // hashchange that could reach it is a same-route one — and a same-hash set
  // fires no event at all. Pinned across every hash the shot matrix uses: if
  // any of these self-closes, the harness photographs an empty screen and the
  // matrix goes quietly false-green.
  const shotHashes = [
    "", "#overview", "#fleet", "#sites", "#activity", "#billing",
    "#notifications", "#operator", "#settings/env", "#settings/members",
    "#settings/providers", "#settings/tokens", "#/auth/reset?token=demo",
    "#/invitations/accept?token=tok-preview-valid",
  ];
  for (const h of shotHashes) {
    assert.equal(
      hooks.hashChangeEffects(h, h, SIGNED_IN).close, false,
      `a same-route hashchange at ${JSON.stringify(h)} must not close the account modal`,
    );
  }
  assert.equal(typeof hooks.openAccountModal, "function", "the seam mock.js drives still exists");
});

test("hashChangeEffects does nothing on the non-hash-routed screens or signed out", () => {
  // (deepEqual is unusable across the vm realm — the sandbox's Object.prototype
  // is a different reference — so each effect is asserted by field.)
  const dead = (label, eff) => {
    assert.equal(eff.close, false, label + ": must not close");
    assert.equal(eff.route, false, label + ": must not route");
  };
  dead("/new", hooks.hashChangeEffects("#overview", "#fleet", { newFlow: true, signedIn: true }));
  dead("/activate", hooks.hashChangeEffects("#overview", "#fleet", { activateFlow: true, signedIn: true }));
  dead("signed out", hooks.hashChangeEffects("#overview", "#fleet", { signedIn: false }));
  dead("no ctx", hooks.hashChangeEffects("#overview", "#fleet", undefined)); // total over junk ctx
  // Total over junk hashes too: null/undefined both canonicalise to overview.
  const junk = hooks.hashChangeEffects(null, undefined, SIGNED_IN);
  assert.equal(junk.close, false);
  assert.equal(junk.route, true);
});

// ── gr-blk-invite-ico-danger-variant: the two failure-shaped landings are no ──
//    longer the same glyph. The split is recoverability, not severity.
test("invite landings: only the DEAD link wears the danger mark; retryable stays warn", () => {
  const dead = hooks.inviteStateHtml("invalid", {});
  assert.match(dead, /invite-ico--danger/, "a revoked/used link is terminal → danger");
  assert.doesNotMatch(dead, /invite-ico--warn/);
  for (const state of ["error", "expired"]) {
    const html = hooks.inviteStateHtml(state, {});
    assert.match(html, /invite-ico--warn/, `${state} is recoverable → warn, not danger`);
    assert.doesNotMatch(html, /invite-ico--danger/);
  }
  // The unknown-state fallback rides the same terminal card.
  assert.match(hooks.inviteStateHtml("who-knows", {}), /invite-ico--danger/);
});

// ── gr-blk-index-icon-link: link integrity, both directions. ─────────────────
//    favicon.ico shipped and was served for the whole epic while index.html
//    referenced it zero times. This is a STATIC document, so a text read is the
//    only way to check it — but the assertion that earns its keep is that the
//    referenced path RESOLVES ON DISK, which is the defect class in both
//    directions: an asset nobody links, or a link to an asset nobody ships.
test("index.html references a favicon that actually ships", () => {
  const html = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const m = html.match(/<link[^>]*\srel="icon"[^>]*\shref="([^"]+)"/);
  assert.ok(m, "index.html declares a rel=icon link");
  const href = m[1];
  assert.ok(href.startsWith("/"), `the icon is same-origin (E7: offline-renderable), got ${href}`);
  assert.ok(
    fs.existsSync(new URL("." + href, import.meta.url)),
    `the icon target ${href} exists in priv/static`,
  );
  // Golden Rule 4: <head> stays non-blocking. The one pre-paint script there is
  // the theme shim; nothing this slice added may grow that count.
  const head = html.slice(0, html.indexOf("</head>"));
  assert.equal((head.match(/<script/g) || []).length, 1, "no new <script> entered <head>");
});

// ── gr-blk-archives-doc-link: the affordance is honest, not relocated. ────────
test("the storage-unconfigured archives note explains itself instead of linking nowhere", () => {
  const html = hooks.archivesPanelHtml(
    hooks.archivesModel({ ok: false, error: "Archive storage isn't configured for this deployment." }),
  );
  assert.match(html, /archives-note--unconfigured/);
  assert.doesNotMatch(html, /archives-docs-link/, "the dead repo-root link is gone");
  assert.doesNotMatch(html, /github\.com/, "and was not replaced by another invented URL");
  assert.match(html, /archives-note-sub/, "the in-place explanation took its place");
  assert.match(html, /data-archives-retry/, "Retry survives");
});

test("parseHash resolves both the old flat and the new canonical Settings hashes to one view", () => {
  for (const h of ["#billing", "#settings/billing"]) {
    sandbox.location.hash = h;
    assert.equal(hooks.parseHash().view, "billing", h + " → billing view");
  }
  sandbox.location.hash = "#settings/tokens";
  assert.equal(hooks.parseHash().view, "tokens");
  sandbox.location.hash = "#settings/nope"; // unknown settings page → overview, never a blank screen
  assert.equal(hooks.parseHash().view, "overview");
});

// ── parseFleetFilter + parseHash fleet buckets (D15) ────────────────────────

test("parseFleetFilter extracts a known bucket, else null (whole fleet)", () => {
  assert.equal(hooks.parseFleetFilter("#fleet/attention"), "attention");
  assert.equal(hooks.parseFleetFilter("fleet/inflight"), "inflight");
  assert.equal(hooks.parseFleetFilter("#fleet/healthy"), "healthy");
  assert.equal(hooks.parseFleetFilter("#fleet"), null);
  assert.equal(hooks.parseFleetFilter("#fleet/bogus"), null);
  assert.equal(hooks.parseFleetFilter(null), null);
});

test("parseHash carries the fleet bucket filter; a bad suffix degrades to all", () => {
  sandbox.location.hash = "#fleet/attention";
  assert.deepEqual({ ...hooks.parseHash() }, { view: "fleet", filter: "attention" });
  sandbox.location.hash = "#fleet/bogus";
  assert.deepEqual({ ...hooks.parseHash() }, { view: "fleet", filter: null });
  sandbox.location.hash = "#fleet";
  assert.equal(hooks.parseHash().view, "fleet");
  assert.equal(hooks.parseHash().filter, undefined);
});

// ── statusOf: one semantic role per state, across the whole ladder (D15) ─────

test("statusOf collapses every fleet state into one {role,label} (D15 ordering)", () => {
  const cases = [
    [{ deprovision_status: "failed" }, "danger", "Removal failed"],
    [{ provision_status: "failed" }, "danger", "Failed"],                        // no host
    [{ host: "h", suspended: true }, "danger", "Suspended"],
    [{ host: "h", health_status: "down", agent_status: "online" }, "warn", "Degraded"],
    [{ host: "h", health_status: "up", agent_status: "offline" }, "warn", "Degraded"],
    [{ host: "h", health_status: "up", agent_status: "online", update_state: "behind" }, "info", "Update available"],
    [{ deprovision_status: "pending" }, "info", "Removing"],
    [{ deprovision_status: "claimed" }, "info", "Removing"],
    [{}, "info", "Provisioning"],                                                // no host, nothing failed
    [{ host: "h", health_status: "up", agent_status: "online" }, "ok", "Healthy"],
  ];
  for (const [bp, role, label] of cases) {
    const s = hooks.statusOf(bp);
    assert.equal(s.role, role, JSON.stringify(bp) + " role");
    assert.equal(s.label, label, JSON.stringify(bp) + " label");
    assert.equal(typeof s.detail, "string");
  }
  assert.equal(hooks.statusOf(null).role, "info"); // null → provisioning-ish, never throws
});

test("statusOf: 'not removing' qualifier — a suspended box mid-teardown reads as Removing (D15 §3)", () => {
  assert.equal(hooks.statusOf({ suspended: true, deprovision_status: "pending" }).label, "Removing");
});

// Cross-surface parity guard (matches cloud_status_cmd.go statusOf): a host-set
// box classifies on its HEALTH, never on a stale/failed latest provision job.
// A failed provision must not force a live-but-unhealthy box to a false-green
// "ok" — it must read Degraded, exactly as the CLI does.
test("classifyBp: a host-set box ignores a failed provision job, ranks on health (Go parity)", () => {
  // host up + healthy, failed latest provision → still ok (the box is serving)
  assert.equal(hooks.classifyBp({ host: "h", provision_status: "failed", health_status: "up", agent_status: "online" }), "ok");
  // host up + UNHEALTHY, failed latest provision → degraded, NOT a false-green ok
  assert.equal(hooks.classifyBp({ host: "h", provision_status: "failed", health_status: "down", agent_status: "online" }), "degraded");
  // no host + failed provision is still the terminal "failed" (rank 2)
  assert.equal(hooks.classifyBp({ provision_status: "failed" }), "failed");
});

// ── attentionRank ordering + tiebreak vs a mixed fixture (D15) ──────────────

const MIXED = [
  { name: "healthy-b", host: "h", health_status: "up", agent_status: "online" },       // ok (8)
  { name: "removing-x", deprovision_status: "claimed" },                               // removing (6)
  { name: "gone-fail", deprovision_status: "failed" },                                 // removal_failed (1)
  { name: "Alpha-degraded", host: "h", health_status: "down", agent_status: "online" },// degraded (4)
  { name: "prov", },                                                                    // provisioning (7)
  { name: "susp", host: "h", suspended: true },                                        // suspended (3)
  { name: "behind-1", host: "h", health_status: "up", agent_status: "online", update_state: "behind" }, // behind (5)
  { name: "prov-fail", provision_status: "failed" },                                   // failed (2)
  { name: "healthy-a", host: "h", health_status: "up", agent_status: "online" },       // ok (8), tiebreak before healthy-b
];

test("attentionRank matches the D15 ladder for each state", () => {
  const rankByName = Object.fromEntries(MIXED.map((b) => [b.name, hooks.attentionRank(b)]));
  assert.equal(rankByName["gone-fail"], 1);
  assert.equal(rankByName["prov-fail"], 2);
  assert.equal(rankByName["susp"], 3);
  assert.equal(rankByName["Alpha-degraded"], 4);
  assert.equal(rankByName["behind-1"], 5);
  assert.equal(rankByName["removing-x"], 6);
  assert.equal(rankByName["prov"], 7);
  assert.equal(rankByName["healthy-a"], 8);
});

test("attentionCompare sorts most-urgent-first, tiebreak name ascending case-insensitive", () => {
  const sorted = MIXED.slice().sort(hooks.attentionCompare).map((b) => b.name);
  assert.deepEqual(sorted, [
    "gone-fail",      // 1
    "prov-fail",      // 2
    "susp",           // 3
    "Alpha-degraded", // 4
    "behind-1",       // 5
    "removing-x",     // 6
    "prov",           // 7
    "healthy-a",      // 8, tiebreak: "healthy-a" < "healthy-b"
    "healthy-b",      // 8
  ]);
});

// ── bucketOf / fleetSummary / filterFleet ───────────────────────────────────

test("bucketOf maps ranks 1–5 → attention, 6–7 → inflight, 8 → healthy", () => {
  assert.equal(hooks.bucketOf({ deprovision_status: "failed" }), "attention"); // 1
  assert.equal(hooks.bucketOf({ host: "h", health_status: "down" }), "attention"); // 4
  assert.equal(hooks.bucketOf({ deprovision_status: "pending" }), "inflight"); // 6
  assert.equal(hooks.bucketOf({}), "inflight"); // 7 provisioning
  assert.equal(hooks.bucketOf({ host: "h", health_status: "up", agent_status: "online" }), "healthy"); // 8
});

test("fleetSummary counts buckets — mixed, empty, and all-healthy", () => {
  const s = hooks.fleetSummary(MIXED);
  assert.equal(s.total, 9);
  assert.equal(s.attention, 5); // removal_failed, failed, suspended, degraded, behind (ranks 1–5)
  assert.equal(s.inflight, 2);  // removing, provisioning (ranks 6–7)
  assert.equal(s.healthy, 2);   // healthy-a, healthy-b (rank 8)
  assert.equal(s.attention + s.inflight + s.healthy, s.total);

  // Spread sandbox-realm returns into the test realm before deepEqual (the
  // node:vm objects carry a different Object.prototype — same trick as parseHash).
  assert.deepEqual({ ...hooks.fleetSummary([]) }, { attention: 0, inflight: 0, healthy: 0, total: 0 });
  assert.deepEqual({ ...hooks.fleetSummary(null) }, { attention: 0, inflight: 0, healthy: 0, total: 0 });

  const allHealthy = [
    { name: "a", host: "h", health_status: "up", agent_status: "online" },
    { name: "b", host: "h", health_status: "up", agent_status: "online" },
  ];
  assert.deepEqual({ ...hooks.fleetSummary(allHealthy) }, { attention: 0, inflight: 0, healthy: 2, total: 2 });
});

test("filterFleet returns exactly one bucket; null bucket → the whole list (copied)", () => {
  const attention = hooks.filterFleet(MIXED, "attention").map((b) => b.name).sort();
  assert.deepEqual(attention, ["Alpha-degraded", "behind-1", "gone-fail", "prov-fail", "susp"].sort());
  assert.equal(hooks.filterFleet(MIXED, "inflight").length, 2);
  assert.equal(hooks.filterFleet(MIXED, "healthy").length, 2);
  const all = hooks.filterFleet(MIXED, null);
  assert.equal(all.length, MIXED.length);
  assert.notEqual(all, MIXED); // a copy, not the same reference
  assert.deepEqual([...hooks.filterFleet(null, "attention")], []);
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

// ── dwb-webhook-deploy-artifact-gap: the born-failed GitHub-push copy + tone ──
// The CP marks a GitHub push deployment born-failed (the builder can't run it
// until the gh-1 App integration lands). FailureCopy.humanize maps the raw
// machine reason to human copy at the JSON boundary, so the client usually
// already receives the human string — the mapping must be IDEMPOTENT.

const GH_HUMAN =
  "GitHub pushes are recorded but can't be built yet — deploy this commit with bp deploy. Automatic GitHub builds are coming.";

test("failureCopy: raw github-push reason → the exact server-humanized copy", () => {
  assert.equal(
    hooks.failureCopy(
      "github push builds require the GitHub App integration (not yet available) — deploy an artifact via bp deploy",
    ),
    GH_HUMAN,
  );
});

test("failureCopy: the humanized github-push copy maps to itself (idempotent)", () => {
  // The server humanizes at the JSON boundary, so the client typically receives
  // the already-human string; re-running failureCopy must not double-map it.
  assert.equal(hooks.failureCopy(GH_HUMAN), GH_HUMAN);
});

test("failureCopy/failureTone: byte-drifted server copy (case, U+2019, cannot) still classifies", () => {
  // The Elixir FailureCopy twin owns the wire string; if its copy drifts by a
  // curly apostrophe, casing, or can't→cannot, the client must still recognize
  // the family (re-mapping to canonical copy is the bonus; the tone is the contract).
  const curly = "GitHub pushes are recorded but can’t be built yet — automatic builds are coming.";
  assert.equal(hooks.failureCopy(curly), GH_HUMAN);
  assert.equal(hooks.failureTone(curly), "blocked");
  assert.equal(hooks.failureTone("GitHub Push Builds require the GitHub App integration"), "blocked");
  assert.equal(hooks.failureTone("This commit cannot be built yet."), "blocked");
});

test("failureTone: github-push family is 'blocked' (raw + humanized), everything else 'crashed'", () => {
  assert.equal(
    hooks.failureTone("github push builds require the GitHub App integration (not yet available)"),
    "blocked",
  );
  assert.equal(hooks.failureTone(GH_HUMAN), "blocked"); // matches the humanized twin too
  assert.equal(hooks.failureTone("artifact_url is empty (P6 bp deploy must populate it)"), "crashed");
  assert.equal(hooks.failureTone("some brand new builder error"), "crashed");
  assert.equal(hooks.failureTone(null), "crashed"); // total over junk
  assert.equal(hooks.failureTone(""), "crashed");
});

// ── launchEntitled: the client mirror of the server's Billing.entitled?/1 ────
// billing.ex entitled?/1 gates the launch form. The client must agree case-for-
// case so a paying customer (incl. a past_due one in grace) is never shown
// "subscription required" while the server would allow the launch.

const future = new Date(Date.now() + 86400000).toISOString();
const past = new Date(Date.now() - 86400000).toISOString();

test("launchEntitled: helpers are exported", () => {
  assert.equal(typeof hooks.launchEntitled, "function");
  assert.equal(typeof hooks.billingStatusLabel, "function");
  assert.equal(typeof hooks.billingStatusBadge, "function");
  assert.equal(typeof hooks.billingPeriodLine, "function");
});

test("launchEntitled: null / free / expired-trial / no-status are NOT entitled", () => {
  assert.equal(hooks.launchEntitled(null), false);
  assert.equal(hooks.launchEntitled({ status: "active", plan: "free" }), false);
  assert.equal(hooks.launchEntitled({ plan: "trial", current_period_end: past }), false);
  assert.equal(hooks.launchEntitled({ plan: "trial", current_period_end: null }), false);
  assert.equal(hooks.launchEntitled({ plan: "supporter" }), false); // no status
});

test("launchEntitled: active paid + forever + unexpired trial ARE entitled", () => {
  assert.equal(hooks.launchEntitled({ status: "active", plan: "supporter" }), true);
  assert.equal(hooks.launchEntitled({ status: "active", plan: "support_plus" }), true);
  assert.equal(hooks.launchEntitled({ plan: "forever" }), true); // status-independent comp
  assert.equal(hooks.launchEntitled({ plan: "trial", current_period_end: future }), true);
});

test("launchEntitled: past_due mirrors the server grace window (billing.ex:1064)", () => {
  // In grace (period end in the future, or unset) → still entitled.
  assert.equal(hooks.launchEntitled({ status: "past_due", plan: "supporter", current_period_end: future }), true);
  assert.equal(hooks.launchEntitled({ status: "past_due", plan: "supporter", current_period_end: null }), true);
  // Grace elapsed → NOT entitled.
  assert.equal(hooks.launchEntitled({ status: "past_due", plan: "supporter", current_period_end: past }), false);
});

// ── billing status/period surfacing (finding 3): no raw "Past_due" echo ──────

test("billingStatusLabel: past_due is a human dunning label, never 'Past_due'", () => {
  assert.equal(hooks.billingStatusLabel({ status: "past_due" }), "Payment past due");
  assert.equal(hooks.billingStatusLabel({ status: "canceled" }), "Canceled");
  assert.equal(hooks.billingStatusLabel({ status: "active", cancel_at_period_end: true }), "Cancels at period end");
  assert.equal(hooks.billingStatusLabel({ status: "active" }), "Active");
});

test("billingStatusBadge: compact status pill", () => {
  assert.equal(hooks.billingStatusBadge({ status: "past_due" }), "Past due");
  assert.equal(hooks.billingStatusBadge({ status: "active", cancel_at_period_end: true }), "Ending");
  assert.equal(hooks.billingStatusBadge({ status: "active" }), "Active");
});

test("billingPeriodLine: surfaces renewal / grace / cancel / end dates", () => {
  assert.match(hooks.billingPeriodLine({ status: "active", current_period_end: future }), /^Renews /);
  assert.match(hooks.billingPeriodLine({ status: "past_due", current_period_end: future }), /^Grace period ends /);
  assert.match(hooks.billingPeriodLine({ status: "active", cancel_at_period_end: true, current_period_end: future }), /^Access until /);
  assert.match(hooks.billingPeriodLine({ status: "canceled", canceled_at: past }), /^Ended /);
  assert.equal(hooks.billingPeriodLine({ status: "active" }), ""); // no dated milestone
});

// ── theme toggle label-in-name (WCAG 2.5.3): accessible name ⊇ visible word ──
// applyTheme() paints the visible label and the aria-label from these two pure
// helpers in lockstep. The invariant a screen-reader / voice-control user needs:
// whatever word is shown on the button is contained in its accessible name, in
// BOTH themes — so "click Dark" / "click Light" always resolves.

test("theme helpers are exported", () => {
  assert.equal(typeof hooks.themeLabelText, "function");
  assert.equal(typeof hooks.themeToggleAria, "function");
});

test("theme label shows the theme you'd switch TO, in each state", () => {
  assert.equal(hooks.themeLabelText("dark"), "Light");  // currently dark → offer Light
  assert.equal(hooks.themeLabelText("light"), "Dark");  // currently light → offer Dark
});

test("theme aria-label CONTAINS the visible word (label-in-name), both themes", () => {
  for (const t of ["dark", "light"]) {
    const visible = hooks.themeLabelText(t);       // "Light" | "Dark"
    const aria = hooks.themeToggleAria(t);         // "Switch to light theme" | "Switch to dark theme"
    assert.ok(
      aria.toLowerCase().includes(visible.toLowerCase()),
      `aria "${aria}" must contain visible word "${visible}"`,
    );
  }
  assert.equal(hooks.themeToggleAria("dark"), "Switch to light theme");
  assert.equal(hooks.themeToggleAria("light"), "Switch to dark theme");
});

// ── theme IDENTITY picker (D36) ─────────────────────────────────────────────
// data-bp-theme swaps the whole palette; it is a SECOND, orthogonal switch to
// the light/dark toggle above. normalizeBpTheme is the safety net: any id the
// build doesn't ship (stale localStorage, a retired theme) collapses to
// evergreen so a bad value never leaves the SPA on an undefined palette.

test("bp-theme picker helpers are exported", () => {
  assert.equal(typeof hooks.normalizeBpTheme, "function");
  assert.equal(typeof hooks.applyBpTheme, "function");
  assert.ok(Array.isArray(hooks.bpThemes));
});

test("bpThemes pins the GENERATED identity list — all 5 skins, in loadThemes order (GR12)", () => {
  // DELIBERATE update (gr-w3): BP_THEMES is now emitted from design/themes/*.json
  // (evergreen default first, then dir order), so charple + iris — the ids the old
  // hardcoded 3-list dropped, leaving charple emitted-but-unreachable — are present.
  // Regenerate via `node design/emit.mjs --write`; a drift reds design/check.mjs.
  assert.deepEqual([...hooks.bpThemes], ["evergreen", "charple", "ember", "fjord", "iris"]);
});

test("normalizeBpTheme passes known ids through and folds anything else to evergreen", () => {
  for (const id of ["evergreen", "charple", "ember", "fjord", "iris"]) {
    assert.equal(hooks.normalizeBpTheme(id), id);
  }
  // Unknown / hostile / empty inputs all fall back — never an undefined palette.
  for (const bad of ["", "EMBER", "midnight", null, undefined, "evergreen ", "0"]) {
    assert.equal(hooks.normalizeBpTheme(bad), "evergreen", `${JSON.stringify(bad)} → evergreen`);
  }
});

test("applyBpTheme returns the applied (normalized) id — the DOM stamp is no-op in the sandbox", () => {
  // document.documentElement.setAttribute + $("#bp-theme-picker") are inert here;
  // the return value is the contract the wiring persists to localStorage.
  assert.equal(hooks.applyBpTheme("ember"), "ember");
  assert.equal(hooks.applyBpTheme("fjord"), "fjord");
  assert.equal(hooks.applyBpTheme("evergreen"), "evergreen");
  assert.equal(hooks.applyBpTheme("bogus"), "evergreen");
});

// ════════════════════════════════════════════════════════════════════════════
// C3 — provisioning timeline: ONE fold (provisionSteps), THREE mounts.
// ════════════════════════════════════════════════════════════════════════════

test("C3: the timeline builders + mount seam are exported", () => {
  for (const name of ["provisionSteps", "stepElapsed", "fmtDur", "provisionTotalMs",
    "provisionChip", "newStepsHtml", "timelineHtml", "consoleTail",
    "instanceTimelineHtml", "mountInstanceTimeline"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

// A fixed clock so elapsed math is deterministic. Steps stamp seconds past T0.
const T = (s) => "2026-07-03T12:00:0" + s + "Z";
const NOW = Date.parse("2026-07-03T12:00:10Z"); // T0 + 10s
const norm = (r) => ({
  step: r.step, label: r.label, role: r.role,
  elapsedMs: r.elapsedMs, caption: r.caption, probes: [...r.probes],
});

// ── stepElapsed + fmtDur: total-over-partial, never NaN ─────────────────────

test("stepElapsed: clean spans, and null (never NaN) on any missing/garbled stamp", () => {
  assert.equal(hooks.stepElapsed(T(0), T(2)), 2000);
  assert.equal(hooks.stepElapsed(1000, 3000), 2000);      // epoch-ms args
  assert.equal(hooks.stepElapsed(5000, 3000), 0);          // clamped, never negative
  assert.equal(hooks.stepElapsed(null, NOW), null);        // missing start
  assert.equal(hooks.stepElapsed(T(0), null), null);       // missing end
  assert.equal(hooks.stepElapsed("not-a-date", NOW), null);// garbled
  assert.ok(!Number.isNaN(hooks.stepElapsed("x", "y")));   // the invariant
});

test("fmtDur: —/seconds/minutes (pre-A4 arms byte-identical)", () => {
  assert.equal(hooks.fmtDur(null), "—");
  assert.equal(hooks.fmtDur(NaN), "—");
  assert.equal(hooks.fmtDur(500), "0s");
  assert.equal(hooks.fmtDur(42000), "42s");
  assert.equal(hooks.fmtDur(102000), "1m 42s");
  assert.equal(hooks.fmtDur(60000), "1m 0s");
  assert.equal(hooks.fmtDur(59000), "59s");   // last second before the minute arm
  assert.equal(hooks.fmtDur(3599000), "59m 59s"); // last second before the hour arm
});

test("fmtDur: A4 hour arm (≥60m) reads '2h 1m'", () => {
  assert.equal(hooks.fmtDur(3600000), "1h 0m");          // exactly 60m
  assert.equal(hooks.fmtDur(2 * 3600000 + 60000), "2h 1m");
  assert.equal(hooks.fmtDur(3 * 3600000 + 59 * 60000), "3h 59m");
});

// ── provisionSteps: the table test over every fixture the slice must handle ──

test("provisionSteps: empty (legacy row) → the five PLANNED steps pending (freshen + content are conditional, hidden until reported)", () => {
  const rows = hooks.provisionSteps({ provision_steps: [] }, NOW);
  assert.equal(rows.length, 5);
  // freshen (fallback rebuild) AND content (template bootstrap, skipped when the
  // job carries no template) are OPTIONAL — an unreported conditional step never
  // renders as a planned phase (it would hang pending forever). The verify gate
  // slots wherever content lands (or directly after configure when there's none).
  assert.deepEqual([...rows.map((r) => r.step)], ["create", "secure", "configure", "verify", "ready"]);
  assert.equal(rows[3].label, "Testing login & Studio"); // D45 label
  for (const r of rows) {
    assert.equal(r.role, "pending");
    assert.equal(r.elapsedMs, null);
    assert.equal(r.caption, "");
    assert.deepEqual([...r.probes], []);
  }
  // Total over junk: null bp never throws.
  assert.equal(hooks.provisionSteps(null, NOW).length, 5);
  assert.equal(hooks.provisionSteps(undefined).length, 5);
});

test("provisionSteps: a REPORTED content renders in place between configure and verify (a templated launch)", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "configure", status: "done", at: T(2) },
    { step: "content", status: "started", at: T(3) },
  ] }, NOW);
  assert.ok([...rows.map((r) => r.step)].includes("content"));
  const content = rows.filter((r) => r.step === "content")[0];
  assert.equal(content.label, "Installing your content");
  assert.equal(content.role, "active");
});

test("provisionSteps: a REPORTED freshen renders in place between create and secure (the fallback fired)", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(2) },
    { step: "freshen", status: "started", at: T(2) },
  ] }, NOW);
  // content stays hidden (unreported); freshen slots in because it WAS reported.
  assert.deepEqual([...rows.map((r) => r.step)], ["create", "freshen", "secure", "configure", "verify", "ready"]);
  assert.equal(rows[1].label, "Updating to the latest Barkpark"); // dwb-17 freshen label
  assert.equal(rows[1].role, "active");
});

test("provisionSteps: partial (mid-configure) — done/done/active/pending…", () => {
  const bp = { provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(2) },
    { step: "secure", status: "started", at: T(2) },
    { step: "secure", status: "done", at: T(4) },
    { step: "configure", status: "started", at: T(5), detail: "Installing packages" },
  ] };
  const rows = hooks.provisionSteps(bp, NOW);
  assert.deepEqual(norm(rows[0]), { step: "create", label: "Creating your server", role: "ok", elapsedMs: 2000, caption: "", probes: [] });
  // Unstarted freshen is HIDDEN (fallback step) — secure follows create directly.
  assert.deepEqual(norm(rows[1]), { step: "secure", label: "Securing your domain", role: "ok", elapsedMs: 2000, caption: "", probes: [] });
  assert.deepEqual(norm(rows[2]), { step: "configure", label: "Configuring Barkpark", role: "active", elapsedMs: 5000, caption: "Installing packages", probes: [] });
  // content unreported → hidden; verify + ready follow configure directly.
  assert.equal(rows[3].step, "verify");
  assert.equal(rows[3].role, "pending"); // verify still upcoming
  assert.equal(rows[4].step, "ready");
  assert.equal(rows[4].role, "pending"); // ready last
  assert.equal(rows.length, 5);
});

test("provisionSteps: verify with probe lines → checklist under the step", () => {
  const bp = { provision_steps: [
    { step: "verify", status: "started", at: T(5), detail: "Probing the golden path" },
    { step: "verify", status: "progress", at: T(6), detail: "verify.login: 200 in 120ms" },
    { step: "verify", status: "progress", at: T(7), detail: "verify.query: 200 in 42ms" },
  ] };
  const verify = hooks.provisionSteps(bp, NOW)[3]; // freshen + content hidden (unreported) → verify at index 3
  assert.equal(verify.role, "active");
  assert.equal(verify.caption, "Probing the golden path");   // the started narration
  assert.deepEqual([...verify.probes], ["verify.login: 200 in 120ms", "verify.query: 200 in 42ms"]);
  assert.equal(verify.elapsedMs, 5000); // NOW - T5
});

test("provisionSteps: failed-with-detail → role failed, caption is the started narration", () => {
  const bp = { provision_steps: [
    { step: "create", status: "started", at: T(0), detail: "Booting the VM" },
    { step: "create", status: "failed", at: T(3) },
  ] };
  const create = hooks.provisionSteps(bp, NOW)[0];
  assert.equal(create.role, "failed");
  assert.equal(create.elapsedMs, 3000);
  assert.equal(create.caption, "Booting the VM");
});

test("provisionSteps: an UNKNOWN step name renders generically (label = raw name), no crash", () => {
  const bp = { provision_steps: [
    { step: "teardown", status: "started", at: T(0), detail: "cleaning up" },
  ] };
  const rows = hooks.provisionSteps(bp, NOW);
  assert.equal(rows.length, 6); // five planned (freshen + content unreported → hidden) + the appended unknown
  const t = rows[5];
  assert.equal(t.step, "teardown");
  assert.equal(t.label, "teardown"); // forward-compat: raw name, never undefined
  assert.equal(t.role, "active");
  assert.equal(t.caption, "cleaning up");
});

test("provisionSteps: absent / garbled timestamps → null elapsed, never NaN", () => {
  const bp = { provision_steps: [
    { step: "create", status: "started" },              // no `at`
    { step: "create", status: "done" },                 // no `at`
    { step: "secure", status: "started", at: "garbage" },
  ] };
  const rows = hooks.provisionSteps(bp, NOW);
  assert.equal(rows[0].role, "ok");
  assert.equal(rows[0].elapsedMs, null);
  assert.ok(!Number.isNaN(rows[0].elapsedMs));
  assert.equal(rows[1].role, "active");  // secure (freshen unreported → hidden)
  assert.equal(rows[1].elapsedMs, null); // active but no start stamp
});

// ── provisionChip (Mount 3): current step label + total elapsed ─────────────

test("provisionChip: active step gerund + total elapsed; failed; and the empty fallback", () => {
  const active = hooks.provisionChip({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(2) },
    { step: "configure", status: "started", at: T(5) },
  ] }, NOW);
  assert.equal(active.label, "configuring");
  assert.equal(active.elapsedMs, 10000); // NOW - first stamp (T0)
  assert.equal(active.failed, false);

  const failed = hooks.provisionChip({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "failed", at: T(3) },
  ] }, NOW);
  assert.equal(failed.label, "creating");
  assert.equal(failed.failed, true);

  const empty = hooks.provisionChip({ provision_steps: [] }, NOW);
  assert.deepEqual({ label: empty.label, elapsedMs: empty.elapsedMs, failed: empty.failed },
    { label: "provisioning", elapsedMs: null, failed: false });
});

// ── newStepsHtml (Mount 1): the /new checklist markup is byte-locked ────────
// Guards the "zero visual regression" contract — if the shared builder ever
// changes the /new step markup, this reds (there is no browser in this harness).
// Re-pinned for the progress-polish slice: the active dot carries the ring
// (data-ring + --p), every row a data-step, and the pace column (new-step-time).

// cch-w13-s1 re-pin: the pace column is now PROVENANCE-gated. A row whose
// budget was measured (paceSource: "measured" — a server median absorbed by
// absorbServerStepEstimates) still quotes it; a planned row narrates elapsed
// only. Both bytes are locked so neither arm can drift silently.
test("newStepsHtml: an active MEASURED step carries the ring dot, the live pace column, the caption and the spinner", () => {
  const html = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "active", elapsedMs: 1000, caption: "Booting", probes: [], paceSource: "measured" },
  ]);
  // stepRingProgress(1000, 15000) = 0.9 * 1/15 → 6%; pace = "1s · ~15s".
  assert.equal(html,
    '<ul class="new-steps">' +
      '<li class="new-step active" data-step="create">' +
        '<span class="new-step-dot" aria-hidden="true" data-ring="create" style="--p:6%"></span>' +
        '<span class="new-step-body">' +
          '<span class="new-step-label">Creating your server</span>' +
          '<span class="new-step-detail" data-cap="Booting">Booting</span>' +
        "</span>" +
        '<span class="new-step-time" data-time="create">1s · ~15s</span>' +
        '<span class="new-step-spin" aria-hidden="true"></span>' +
      "</li>" +
    "</ul>");
});

// cch-w14-s5 re-pin: the RING is provenance-gated too. A planned active row has
// no measured budget to sweep against, so it drops data-ring and --p and marks
// the DOT `data-ring-unpaced` — the stylesheet renders the indeterminate pulse.
// The row's own class vocabulary (`new-step active`) is untouched.
test("newStepsHtml: an active PLANNED step drops the determinate ring and quotes NO pace it cannot back", () => {
  const html = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "active", elapsedMs: 1000, caption: "Booting", probes: [] },
  ]);
  // Same row, no provenance → the "· ~15s" half of the pace column is gone and
  // the live elapsed stands alone, and the ring is indeterminate.
  assert.equal(html,
    '<ul class="new-steps">' +
      '<li class="new-step active" data-step="create">' +
        '<span class="new-step-dot" aria-hidden="true" data-ring-unpaced></span>' +
        '<span class="new-step-body">' +
          '<span class="new-step-label">Creating your server</span>' +
          '<span class="new-step-detail" data-cap="Booting">Booting</span>' +
        "</span>" +
        '<span class="new-step-time" data-time="create">1s</span>' +
        '<span class="new-step-spin" aria-hidden="true"></span>' +
      "</li>" +
    "</ul>");
  // And provenance is carried on the ROW, never emitted as markup.
  assert.doesNotMatch(html, /paceSource|data-pace/);
  // No determinate sweep survives anywhere in the row — neither the hook the
  // ticker patches nor the custom property it patches it with.
  assert.doesNotMatch(html, /data-ring="|--p:/);
});

test("newStepsHtml: a done step is a check with the real elapsed, no spinner and no caption — identical under either provenance", () => {
  const planned = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "ok", elapsedMs: 1000, caption: "", probes: [] },
  ]);
  const measured = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "ok", elapsedMs: 1000, caption: "", probes: [], paceSource: "measured" },
  ]);
  // A finished step reports what HAPPENED, so provenance cannot change a byte.
  const expected =
    '<ul class="new-steps">' +
      '<li class="new-step done" data-step="create">' +
        '<span class="new-step-dot" aria-hidden="true">&#10003;</span>' +
        '<span class="new-step-body">' +
          '<span class="new-step-label">Creating your server</span>' +
        "</span>" +
        '<span class="new-step-time">1s</span>' +
      "</li>" +
    "</ul>";
  assert.equal(planned, expected);
  assert.equal(measured, expected);
});

test("newStepsHtml: a pending MEASURED step shows the plan hint (~expected); an unknown step shows none", () => {
  const html = hooks.newStepsHtml([
    { step: "secure", label: "Securing your domain", role: "pending", elapsedMs: null, caption: "", probes: [], paceSource: "measured" },
    { step: "mystery", label: "mystery", role: "pending", elapsedMs: null, caption: "", probes: [], paceSource: "measured" },
  ]);
  assert.match(html, /<span class="new-step-time">~45s<\/span>/); // secure's estimate
  assert.doesNotMatch(html, /data-step="mystery"[\s\S]*new-step-time/); // no estimate → no hint
  assert.doesNotMatch(html, /new-step-spin[\s\S]*data-step="mystery"|data-step="mystery"[^]*new-step-spin/);
});

test("newStepsHtml: a pending PLANNED step shows NO plan hint — the whole time column is absent", () => {
  const html = hooks.newStepsHtml([
    { step: "secure", label: "Securing your domain", role: "pending", elapsedMs: null, caption: "", probes: [] },
  ]);
  // The full row, byte-locked: same dot, same label, and where the "~45s"
  // promise used to sit there is now nothing at all (the .skipped drop-the-hint
  // rule, applied to a step whose budget nobody measured).
  assert.equal(html,
    '<ul class="new-steps">' +
      '<li class="new-step pending" data-step="secure">' +
        '<span class="new-step-dot" aria-hidden="true"></span>' +
        '<span class="new-step-body">' +
          '<span class="new-step-label">Securing your domain</span>' +
        "</span>" +
      "</li>" +
    "</ul>");
  assert.doesNotMatch(html, /~45s/);
});

test("newStepsHtml: a `next` row pulses — pending class + next, Starting… caption, dimmable spinner", () => {
  const html = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "ok", elapsedMs: 2000, caption: "", probes: [] },
    { step: "secure", label: "Securing your domain", role: "pending", elapsedMs: null, caption: "", probes: [], next: true },
  ]);
  assert.match(html, /<li class="new-step pending next" data-step="secure">/);
  assert.match(html, /data-cap="Starting…">Starting…</); // the between-steps caption
  // The next row spins (motion), while the done row does not.
  const nextLi = html.slice(html.indexOf('data-step="secure"'));
  assert.match(nextLi, /new-step-spin/);
  const doneLi = html.slice(html.indexOf('data-step="create"'), html.indexOf('data-step="secure"'));
  assert.doesNotMatch(doneLi, /new-step-spin/);
});

// ── stepRingProgress: the per-phase ring fill is asymptotic + null-safe ─────

test("stepRingProgress: linear to 90% across the estimate, crawls after, never completes, never NaN", () => {
  assert.equal(hooks.stepRingProgress(0, 15000), 0);
  assert.ok(Math.abs(hooks.stepRingProgress(7500, 15000) - 0.45) < 1e-9); // halfway → 45%
  assert.ok(Math.abs(hooks.stepRingProgress(15000, 15000) - 0.9) < 1e-9); // on-estimate → 90%
  const overdue = hooks.stepRingProgress(10 * 15000, 15000);
  assert.ok(overdue > 0.9 && overdue < 0.98, `overdue must crawl in (0.9, 0.98), got ${overdue}`);
  // Monotone while overdue: still visibly moving.
  assert.ok(hooks.stepRingProgress(3 * 15000, 15000) < hooks.stepRingProgress(4 * 15000, 15000));
  // Null-safety: garbled elapsed or missing estimate → 0, never NaN.
  for (const v of [hooks.stepRingProgress(null, 15000), hooks.stepRingProgress(NaN, 15000),
    hooks.stepRingProgress(-5, 15000), hooks.stepRingProgress(1000, undefined)]) {
    assert.equal(v, 0);
  }
});

// ── markNextStep: the between-steps decoration ──────────────────────────────

test("markNextStep: flags the first pending after a done; never when a step is active/failed or nothing finished", () => {
  const row = (step, role) => ({ step, role, label: step, elapsedMs: null, caption: "", probes: [] });
  // Gap: done + all-pending → the first pending is `next`.
  const gap = hooks.markNextStep([row("create", "ok"), row("secure", "pending"), row("configure", "pending")]);
  assert.equal(gap[1].next, true);
  assert.equal(gap[2].next, undefined);
  assert.equal(gap[1].role, "pending"); // role untouched — the chip stays honest
  // A live step → no decoration.
  const busy = hooks.markNextStep([row("create", "ok"), row("secure", "active"), row("configure", "pending")]);
  assert.ok(busy.every((r) => !r.next));
  // A failed run → no decoration (the failure is the signal).
  const failed = hooks.markNextStep([row("create", "failed"), row("secure", "pending")]);
  assert.ok(failed.every((r) => !r.next));
  // Nothing finished yet (pre-first-step) → no decoration.
  const cold = hooks.markNextStep([row("create", "pending"), row("secure", "pending")]);
  assert.ok(cold.every((r) => !r.next));
});

// ── paceSteps: the min-dwell display shim (satisfying, still honest) ─────────

const paceRow = (step, role, extra = {}) =>
  ({ step, role, label: step, elapsedMs: null, caption: "", probes: [], ...extra });

test("paceSteps: an instantly-done step dwells as `completing` for the minimum, then reads done", () => {
  const ledger = {};
  const t0 = 100000;
  const truth = [paceRow("content", "ok", { elapsedMs: 600 }), paceRow("verify", "pending")];
  // First sight at t0: displayed active+completing, later rows held pending.
  const first = hooks.paceSteps(truth, ledger, t0);
  assert.equal(first[0].role, "active");
  assert.equal(first[0].completing, true);
  assert.equal(ledger.content, t0);
  // Still dwelling just before the minimum…
  const mid = hooks.paceSteps(truth, ledger, t0 + hooks.newStepMinDwellMs - 1);
  assert.equal(mid[0].completing, true);
  // …and done once the dwell has been served.
  const after = hooks.paceSteps(truth, ledger, t0 + hooks.newStepMinDwellMs);
  assert.equal(after[0].role, "ok");
  assert.equal(after[0].completing, false);
});

test("paceSteps: rapid multi-done plays ONE at a time — each later step gets its own dwell", () => {
  const ledger = {};
  const t0 = 200000;
  const truth = [paceRow("content", "ok"), paceRow("verify", "ok"), paceRow("ready", "ok")];
  const first = hooks.paceSteps(truth, ledger, t0);
  assert.deepEqual([...first.map((r) => r.role)], ["active", "pending", "pending"]);
  // After content's dwell: verify takes the stage with a FRESH stamp.
  const second = hooks.paceSteps(truth, ledger, t0 + hooks.newStepMinDwellMs + 100);
  assert.deepEqual([...second.map((r) => r.role)], ["ok", "active", "pending"]);
  assert.equal(second[1].completing, true);
  assert.equal(ledger.verify, t0 + hooks.newStepMinDwellMs + 100);
  // And the queue drains fully after every dwell has been served.
  const third = hooks.paceSteps(truth, ledger, t0 + 3 * (hooks.newStepMinDwellMs + 200));
  assert.deepEqual([...third.map((r) => r.role)], ["ok", "ok", "active"]); // ready dwelling now
});

test("paceSteps: a step active on screen ≥ the dwell flips to done with no extra wait", () => {
  const ledger = {};
  const t0 = 300000;
  hooks.paceSteps([paceRow("secure", "active")], ledger, t0); // shown active at t0
  const done = hooks.paceSteps([paceRow("secure", "ok")], ledger, t0 + hooks.newStepMinDwellMs + 500);
  assert.equal(done[0].role, "ok"); // dwell already served while genuinely active
});

test("paceSteps: FAILURE snaps to truth — no pacing may delay bad news", () => {
  const ledger = {};
  const truth = [paceRow("create", "ok"), paceRow("secure", "failed")];
  const rows = hooks.paceSteps(truth, ledger, 400000); // fresh ledger: create would dwell
  assert.deepEqual([...rows.map((r) => r.role)], ["ok", "failed"]);
  assert.ok(rows.every((r) => !r.completing));
});

test("paceSteps: the `next` pulse is suppressed while a paced row holds the stage", () => {
  const ledger = {};
  const truth = [paceRow("create", "ok"), paceRow("secure", "pending", { next: true })];
  const rows = hooks.paceSteps(truth, ledger, 500000);
  assert.equal(rows[0].role, "active"); // dwelling
  assert.equal(rows[1].next, false);
});

// ── Zero-paste Vercel handoff: the claim-area builders ───────────────────────

test("vercelClaimHtml: unconfigured → empty (the clone-URL fallback renders instead)", () => {
  assert.equal(hooks.vercelClaimHtml(null, { id: "b1" }), "");
  assert.equal(hooks.vercelClaimHtml({ configured: false, deployed: true }, { id: "b1" }), "");
});

test("vercelClaimHtml: configured + undeployed → the one-click deploy button", () => {
  const html = hooks.vercelClaimHtml({ configured: true, deployed: false, claim_url: null }, { id: "b1" });
  assert.match(html, /<div id="new-vercel-area">/);
  assert.match(html, /id="new-vercel-claim"[^>]*>Deploy your site to Vercel</);
  assert.match(html, /every environment variable already set/);
});

test("vercelClaimHtml: deployed but stale code → a re-mint button, never a dead link", () => {
  const html = hooks.vercelClaimHtml({ configured: true, deployed: true, claim_url: null }, { id: "b1" });
  assert.match(html, /Get your Vercel claim link/);
  assert.doesNotMatch(html, /claim-deployment/);
});

test("vercelClaimLinkHtml: fresh code → claim link with returnUrl back to the instance", () => {
  const vercel = {
    configured: true, deployed: true,
    claim_url: "https://vercel.com/claim-deployment?code=clm_x",
    deployment_url: "https://my-site-abc.vercel.app",
  };
  const html = hooks.vercelClaimHtml(vercel, { id: "bp-9" });
  assert.match(html, /id="new-vercel-claim-link"/);
  // esc() entity-encodes the & in the attribute — the browser decodes it back.
  assert.match(html, /href="https:\/\/vercel\.com\/claim-deployment\?code=clm_x&amp;returnUrl=http%3A%2F%2Flocalhost%2F%23instance%2Fbp-9"/);
  assert.match(html, /my-site-abc\.vercel\.app/); // the live-deployment line
  assert.match(html, /target="_blank" rel="noopener"/);
});

// ── Guided Vercel fallback (no platform token): per-field copy + Deploy ──────

test("vercelEnvRows: {key,value} pairs in template order, only resolved values", () => {
  const tpl = { env_keys: ["BARKPARK_API_URL", "BARKPARK_TOKEN", "MISSING"] };
  const boot = { env: { BARKPARK_TOKEN: "bp_secret", BARKPARK_API_URL: "https://x", MISSING: null } };
  const rows = hooks.vercelEnvRows(tpl, boot);
  assert.deepEqual([...rows.map((r) => r.key)], ["BARKPARK_API_URL", "BARKPARK_TOKEN"]);
  assert.equal(rows[1].value, "bp_secret");
});

test("vercelFallbackHtml: values FIRST (per-field copy), then the Deploy button", () => {
  const tpl = { env_keys: ["BARKPARK_API_URL", "BARKPARK_TOKEN"] };
  const boot = { env: { BARKPARK_API_URL: "https://acme.barkpark.cloud", BARKPARK_TOKEN: "bp_read_secret" } };
  const dotenv = hooks.vercelCloneUrl ? "BARKPARK_API_URL=https://acme.barkpark.cloud\nBARKPARK_TOKEN=bp_read_secret" : "";
  const clone = "https://vercel.com/new/clone?env=BARKPARK_API_URL,BARKPARK_TOKEN";
  const html = hooks.vercelFallbackHtml(tpl, boot, clone, dotenv);

  // A "Copy value" button per field, carrying the real (secret) value to copy…
  assert.match(html, /data-copy="https:\/\/acme\.barkpark\.cloud"[^>]*>Copy value/);
  assert.match(html, /data-copy="bp_read_secret"[^>]*>Copy value/);
  // …the key labels shown, the values NOT rendered inline as text (only in the
  // copy attribute) — reduces shoulder-surfing of the read token.
  assert.match(html, /new-env-key">BARKPARK_TOKEN</);
  assert.doesNotMatch(html, />bp_read_secret</);
  // Count in the instruction, "Copy all as .env", and the Deploy button LAST.
  assert.match(html, /Vercel will ask for 2 environment variables/);
  assert.match(html, /Copy all as \.env/);
  const rowsIdx = html.indexOf("new-env-rows");
  const deployIdx = html.indexOf("id=\"new-vercel\"");
  assert.ok(rowsIdx > -1 && deployIdx > rowsIdx, "the Deploy button must come AFTER the value rows");
  assert.match(html, /href="https:\/\/vercel\.com\/new\/clone[^"]*" target="_blank" rel="noopener"/);
});

test("vercelFallbackHtml: singular copy for one variable", () => {
  const tpl = { env_keys: ["BARKPARK_TOKEN"] };
  const html = hooks.vercelFallbackHtml(tpl, { env: { BARKPARK_TOKEN: "x" } }, "https://vercel.com/new/clone", "BARKPARK_TOKEN=x");
  assert.match(html, /ask for 1 environment variable\b/);
  assert.doesNotMatch(html, /1 environment variables/);
});

test("seedPaceLedger: resume renders finished history instantly (no theatre replay)", () => {
  const ledger = {};
  const truth = [paceRow("create", "ok"), paceRow("secure", "ok"), paceRow("configure", "active")];
  hooks.seedPaceLedger(truth, ledger);
  const rows = hooks.paceSteps(truth, ledger, 600000);
  assert.deepEqual([...rows.map((r) => r.role)], ["ok", "ok", "active"]);
  assert.ok(rows.every((r) => !r.completing));
});

// ── Overall master bar (provisioning-ui upgrade) ────────────────────────────

test("provisionOverall: empty rows → 0%, no eta", () => {
  const o = hooks.provisionOverall([]);
  assert.equal(o.pct, 0);
  assert.equal(o.count, 0);
  assert.equal(o.done, false);
});

test("provisionOverall: all steps done → 100%, done, index=count", () => {
  const rows = [paceRow("create", "ok"), paceRow("secure", "ok"), paceRow("ready", "ok")];
  const o = hooks.provisionOverall(rows);
  assert.equal(o.pct, 100);
  assert.equal(o.done, true);
  assert.equal(o.index, 3);
  assert.equal(o.etaMs, 0);
});

test("provisionOverall: never reads 100% until every step is done (a mid-active run caps at 99)", () => {
  const rows = [
    paceRow("create", "ok"),
    { step: "secure", role: "active", label: "s", elapsedMs: 44000, caption: "", probes: [] }, // ~on-estimate
    paceRow("ready", "pending"),
  ];
  const o = hooks.provisionOverall(rows);
  assert.ok(o.pct > 0 && o.pct <= 99, `pct ${o.pct} must be in (0,99]`);
  assert.equal(o.done, false);
  assert.equal(o.index, 2); // the active step
  assert.ok(o.etaMs > 0, "a running provision has time remaining");
});

test("provisionOverall: a failed step marks the model failed", () => {
  const rows = [paceRow("create", "ok"), paceRow("secure", "failed")];
  const o = hooks.provisionOverall(rows);
  assert.equal(o.failed, true);
  assert.equal(o.done, false);
});

test("provisionOverallHtml: carries the progressbar, fill width, and Step N of M summary", () => {
  const rows = [paceRow("create", "ok"), { step: "secure", role: "active", label: "s", elapsedMs: 10000, caption: "", probes: [] }, paceRow("ready", "pending")];
  const html = hooks.provisionOverallHtml(rows);
  assert.match(html, /data-overall/);
  assert.match(html, /role="progressbar"/);
  assert.match(html, /data-overall-fill style="width:\d+%"/);
  assert.match(html, /data-overall-summary>Step 2 of 3</);
  assert.match(html, /data-overall-eta>/);
});

// ── cch-w13-s1: the rail stops promising a precision it does not have ───────
// Provenance rides the ROW OBJECT (paceSource: "measured" | "planned"), never
// the markup. A planned row quotes no "~Ns" plan, and a run whose rows are
// planned renders an INDETERMINATE bar with no ETA — the person is told what
// step they are on (a count) and nothing that pretends to be a measurement.

test("cch-w13-s1 paceSource rides the row: provision rows are always planned, a deploy stage only measured when the server published its median", () => {
  // Every provision row, main OR support, is planned — both estimate tables are
  // hand-written constants and the server publishes no provision key.
  const prov = hooks.provisionSteps({ provision_steps: [{ step: "create", status: "started", at: T(0) }] }, NOW);
  assert.ok(prov.length > 0);
  assert.deepEqual([...new Set(prov.map((r) => r.paceSource))], ["planned"]);
  const support = hooks.provisionSteps({ fleet_role: "support", provision_steps: [] }, NOW);
  assert.deepEqual([...new Set(support.map((r) => r.paceSource))], ["planned"]);

  // The deploy rail: per STAGE, not per table. BUILD carries a server median →
  // "measured"; the five the server did not publish stay "planned".
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: { BUILD: 14835 } } });
  const rows = hooks.deployRailRows({ PLAN: { status: "done" }, BUILD: { status: "running" } });
  const by = Object.fromEntries(rows.map((r) => [r.step, r.paceSource]));
  assert.deepEqual(by, {
    PLAN: "planned", BUILD: "measured", STAGE: "planned",
    HEALTH: "planned", SWITCH: "planned", RETIRE: "planned",
  });
  // The pacer copies rows through a whitelist — provenance must survive it, or
  // the /new + rail screens would silently fall back to planned mid-run.
  const paced = hooks.paceSteps(rows, {}, Date.now());
  assert.equal(paced.find((r) => r.step === "BUILD").paceSource, "measured");

  // A table the server later withdraws demotes the stage back to planned.
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: {} } });
  assert.equal(hooks.deployRailRows({}).find((r) => r.step === "BUILD").paceSource, "planned");
});

test("cch-w13-s1 provenance is NEVER markup: the rendered rail carries no pace attribute, only different copy", () => {
  const planned = hooks.newStepsHtml([
    { step: "BUILD", label: "Build", role: "pending", elapsedMs: null, expectedMs: 120000, caption: "", probes: [] },
  ]);
  const measured = hooks.newStepsHtml([
    { step: "BUILD", label: "Build", role: "pending", elapsedMs: null, expectedMs: 14835, caption: "", probes: [], paceSource: "measured" },
  ]);
  for (const html of [planned, measured]) {
    assert.doesNotMatch(html, /paceSource|data-pace|data-source|measured|planned/);
  }
  // The ONLY difference between the two rows is the promise itself.
  assert.ok(!planned.includes("new-step-time"), "a planned pending row has no time column at all");
  assert.match(measured, /<span class="new-step-time">~14s<\/span>/); // the 14835ms median
});

test("cch-w13-s1 provisionOverallHtml: planned rows → an INDETERMINATE progressbar and an EMPTY eta", () => {
  const rows = [
    paceRow("create", "ok"),
    { step: "secure", role: "active", label: "Securing your domain", elapsedMs: 10000, caption: "", probes: [] },
    paceRow("ready", "pending"),
  ];
  const o = hooks.provisionOverall(rows);
  assert.equal(o.planned, true);
  assert.equal(hooks.overallEtaText(o), null, "no honest time-left exists → null, not 'almost there'");
  const html = hooks.provisionOverallHtml(rows);
  // The canonical indeterminate ARIA shape: role + min/max, NO aria-valuenow.
  assert.match(html, /<div class="prov-overall-track" role="progressbar" aria-valuemin="0" aria-valuemax="100">/);
  assert.doesNotMatch(html, /aria-valuenow/);
  // …and the ETA slot renders empty. The COUNT stays — it is not a prediction.
  assert.match(html, /<span class="prov-overall-eta" data-overall-eta><\/span>/);
  assert.match(html, /<span data-overall-summary>Step 2 of 3<\/span>/);
  assert.doesNotMatch(html, /about .* left|almost there/);
});

test("cch-w13-s1 provisionOverallHtml: measured rows KEEP the announced percentage and the ETA", () => {
  const measure = (step, role, extra) => Object.assign(
    { step, role, label: step, elapsedMs: null, caption: "", probes: [], expectedMs: 10000, paceSource: "measured" }, extra);
  const rows = [measure("PLAN", "ok", { elapsedMs: 2000 }), measure("BUILD", "active", { elapsedMs: 5000 }), measure("STAGE", "pending")];
  const o = hooks.provisionOverall(rows);
  assert.equal(o.planned, false);
  assert.match(hooks.overallEtaText(o), /^about .* left$/);
  const html = hooks.provisionOverallHtml(rows);
  assert.match(html, /role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="\d+"/);
  assert.match(html, /data-overall-eta>about /);
});

test("cch-w13-s1 a finished or failed run is still determinate — 100% and 'Setup failed' are facts, not predictions", () => {
  const done = hooks.provisionOverall([paceRow("create", "ok"), paceRow("ready", "ok")]);
  assert.equal(done.planned, false);
  assert.equal(hooks.overallEtaText(done), "Ready");
  assert.match(hooks.provisionOverallHtml([paceRow("create", "ok"), paceRow("ready", "ok")]), /aria-valuenow="100"/);
  const failed = hooks.provisionOverall([paceRow("create", "ok"), paceRow("secure", "failed")]);
  assert.equal(failed.planned, false);
  assert.equal(hooks.overallEtaText(failed), "");
});

test("cch-w13-s1 BOTH mount sites: the instance timeline renders the indeterminate bar, and /new mounts the same builder", () => {
  // Mount 2, driven end to end off a real fleet payload.
  const tl = hooks.instanceTimelineHtml({
    id: "bp-1", name: "Hugin", provision_status: "provisioning",
    provision_steps: [
      { step: "create", status: "started", at: "2026-07-03T12:00:00Z" },
      { step: "create", status: "done", at: "2026-07-03T12:00:05Z" },
      { step: "secure", status: "started", at: "2026-07-03T12:00:05Z" },
    ],
    provision_console: [],
  }, {});
  assert.match(tl, /<div class="prov-overall-track" role="progressbar" aria-valuemin="0" aria-valuemax="100">/);
  assert.doesNotMatch(tl, /aria-valuenow/);
  assert.match(tl, /<span class="prov-overall-eta" data-overall-eta><\/span>/);
  assert.doesNotMatch(tl, /~\d+[sm]/, "no planned step quotes a pace hint in the timeline");

  // Mount 1 (/new) feeds provisionOverallHtml the paced fold of the SAME rows,
  // so the identical bar renders there…
  const ledger = {};
  const newRows = hooks.paceSteps(
    hooks.provisionSteps({ provision_steps: [
      { step: "create", status: "started", at: "2026-07-03T12:00:00Z" },
      { step: "create", status: "done", at: "2026-07-03T12:00:05Z" },
      { step: "secure", status: "started", at: "2026-07-03T12:00:05Z" },
    ] }, NOW), ledger, NOW);
  const newBar = hooks.provisionOverallHtml(newRows);
  assert.doesNotMatch(newBar, /aria-valuenow/);
  assert.match(newBar, /<span class="prov-overall-eta" data-overall-eta><\/span>/);
  // …and the /new screen has exactly TWO provisionOverallHtml call sites (the
  // initial mount + the late insert once the first real steps land). A third
  // emitter of the bar would be a mount this lock never checked.
  const newScreen = APP_SRC.slice(APP_SRC.indexOf("function newRenderProgress"));
  const body = newScreen.slice(0, newScreen.indexOf("function newRenderFailed"));
  assert.equal((body.match(/provisionOverallHtml\(/g) || []).length, 2,
    "newRenderProgress mounts the bar and late-inserts it — both through the shared builder");
  // The provision bar has exactly ONE aria-valuenow emitter, and it sits behind
  // the determinate arm — so there is no second place a planned run could leak
  // an announced percentage from. (The SPA's only other emitter is the usage
  // quota bar, which counts real consumption and is rightly determinate.)
  const barSrc = APP_SRC.slice(APP_SRC.indexOf("function provisionOverallHtml"),
    APP_SRC.indexOf("function patchProvisionOverall"));
  assert.equal((barSrc.match(/aria-valuenow="/g) || []).length, 1);
  assert.match(barSrc, /o\.planned \? "" :/);
  assert.equal((APP_SRC.match(/aria-valuenow="/g) || []).length, 2,
    "only the provision bar and the usage quota bar announce a value at all");
});

test("newStepsHtml: a completing row carries the completing class and a visible sweep start", () => {
  const html = hooks.newStepsHtml([
    { step: "verify", label: "Testing login & Studio", role: "active", elapsedMs: 500, caption: "", probes: [], completing: true },
  ]);
  assert.match(html, /<li class="new-step active completing" data-step="verify">/);
  assert.match(html, /data-ring="verify" style="--p:(3[4-9]|[4-9][0-9]|100)%"/); // ≥34%: never sweeps from empty
});

test("provisionSteps: a between-steps gap (create done, nothing active) marks secure `next` end-to-end", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(2) },
  ] }, NOW);
  assert.equal(rows[0].role, "ok");
  assert.equal(rows[1].step, "secure");
  assert.equal(rows[1].next, true);
  // The chip is untouched by the decoration: still the generic fallback label.
  assert.equal(hooks.provisionChip({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(2) },
  ] }, NOW).label, "provisioning");
});

// ── timelineHtml (Mount 2 presentation) ─────────────────────────────────────

test("timelineHtml: ONE component — the instance timeline renders the SHARED .new-step rows + the failure block", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "failed", at: T(3) },
    { step: "verify", status: "started", at: T(5), detail: "Probing" },
    { step: "verify", status: "progress", at: T(6), detail: "verify.login: 401 in 182ms" },
  ] }, NOW);
  const html = hooks.timelineHtml(rows, { failed: true, failureDetail: "SECRET_KEY_BASE was 32 bytes" });
  // The unified rows: same markup family as /new — ring dots, pace column, probes.
  assert.match(html, /<li class="new-step failed" data-step="create">/);
  // gr-p2 (GR18(4)) pin update: unstarted steps BEHIND a failure render
  // `skipped` (dashed hollow, no plan hint), never a live `pending`.
  assert.match(html, /<li class="new-step skipped" data-step="secure">/);
  assert.match(html, /new-step-time">3s</); // the failed step's real elapsed
  assert.match(html, /new-step-probe">verify\.login: 401 in 182ms/);
  assert.doesNotMatch(html, /bp-tl-step|bp-tl-dot|bp-tl-elapsed/); // the old row family is GONE
  // The failure block is the timeline-specific extra.
  assert.match(html, /bp-tl-fail[\s\S]*SECRET_KEY_BASE was 32 bytes/);
  assert.doesNotMatch(hooks.timelineHtml(rows, { failed: false }), /bp-tl-fail/);
});

test("timelineHtml: a `next` row pulses exactly like /new — shared class, Starting… caption, spinner", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(2) },
  ] }, NOW);
  const html = hooks.timelineHtml(rows, {});
  assert.match(html, /<li class="new-step pending next" data-step="secure">/);
  assert.match(html, /data-cap="Starting…">Starting…</);
  const nextLi = html.slice(html.indexOf('data-step="secure"'), html.indexOf("configure"));
  assert.match(nextLi, /new-step-spin/);
});

test("newStepsHtml: verify probes render as a checklist under their step (both mounts)", () => {
  const html = hooks.newStepsHtml([
    { step: "verify", label: "Testing login & Studio", role: "active", elapsedMs: 5000,
      caption: "Probing the golden path", probes: ["verify.login: 200 in 120ms", "verify.query: 200 in 42ms"] },
  ]);
  assert.match(html, /new-step-probes/);
  assert.match(html, /new-step-probe">verify\.login: 200 in 120ms<\/li>/);
  assert.match(html, /new-step-probe">verify\.query: 200 in 42ms<\/li>/);
});

test("consoleTail: empty → a calm caption; lines → escaped rows with timestamps", () => {
  assert.match(hooks.consoleTail([]), /bp-console-empty/);
  const html = hooks.consoleTail([{ at: T(1), line: "cloning <repo>" }]);
  assert.match(html, /bp-console-line/);
  assert.match(html, /cloning &lt;repo&gt;/); // esc() shields injection
});

// ── Fake-DOM WIRING smoke (harvested idea): a re-render must not blank the view ─
// The pure-helper harness above structurally cannot see a handler that clears
// the mounted node. This drives the real mount+wire path against a minimal DOM
// stub and asserts the timeline survives a refresh (the SSE-driven re-render).

function fakeNode() {
  const n = {
    _html: "",
    get innerHTML() { return n._html; },
    set innerHTML(v) { n._html = String(v); },
    addEventListener() {}, removeEventListener() {},
    setAttribute() {}, getAttribute() { return null; },
    classList: { toggle() {}, add() {}, remove() {}, contains() { return false; } },
    textContent: "", hidden: false,
    querySelector() { return fakeNode(); },
    querySelectorAll() { return []; },
  };
  n.parentNode = n;
  return n;
}

test("mountInstanceTimeline: mounts the timeline and a re-render does NOT blank it", () => {
  const bp = {
    id: "abc", provision_status: "claimed",
    provision_steps: [
      { step: "create", status: "done", at: T(0) },
      { step: "configure", status: "started", at: T(2), detail: "Writing config" },
    ],
    provision_console: [{ at: T(3), line: "configuring…" }],
  };
  const root = fakeNode();
  hooks.mountInstanceTimeline(root, bp, NOW);
  assert.match(root.innerHTML, /class="bp-timeline"/);
  assert.match(root.innerHTML, /class="new-steps"/); // the SHARED rows component
  assert.match(root.innerHTML, /bp-console/);
  const first = root.innerHTML;
  assert.ok(first.length > 0);

  // Simulate the SSE-driven re-render onto the SAME container.
  hooks.mountInstanceTimeline(root, bp, NOW + 4000);
  assert.match(root.innerHTML, /class="bp-timeline"/, "re-render must not blank the timeline");
  assert.ok(root.innerHTML.length > 0);
});

test("mountInstanceTimeline: a failed instance keeps the timeline + shows the verbatim detail + Retry", () => {
  const bp = {
    id: "def", provision_status: "failed", provision_error: "SECRET_KEY_BASE too short (32 bytes)",
    provision_steps: [{ step: "configure", status: "failed", at: T(2), detail: "writing secrets" }],
    provision_console: [],
  };
  const root = fakeNode();
  hooks.mountInstanceTimeline(root, bp, NOW);
  assert.match(root.innerHTML, /Setup failed/);
  assert.match(root.innerHTML, /SECRET_KEY_BASE too short \(32 bytes\)/); // verbatim
  assert.match(root.innerHTML, /data-tl-retry/);                         // wired to POST /retry
  // Re-render (post-mortem stays visible — the timeline is the product).
  hooks.mountInstanceTimeline(root, bp, NOW + 1000);
  assert.match(root.innerHTML, /Setup failed/);
});

// ════════════════════════════════════════════════════════════════════════════
// C6 — instance-workspace sub-tabs + the Webhooks tab (charter D49/D46/D51/D18/D5)
// ════════════════════════════════════════════════════════════════════════════

test("C6: the tab codec + webhook builders + mount seam are exported", () => {
  for (const name of ["instanceTabOf", "instanceDetailHtml", "instanceTabStripHtml",
    "webhookCliChip", "cliChipHtml", "webhookEventsHtml", "webhookBannerHtml",
    "webhookCardHtml", "deliveryTone", "deliveryRowHtml", "hookToggleState",
    "webhookErrorHtml", "webhookMutationError", "whPath", "webhooksTabShellHtml",
    "mountWebhooksTab"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  // C8 registered the Timeline tab between Overview and Webhooks; C10 appended
  // Usage; S12 (azure-hetzner hosting) appended Metrics.
  assert.deepEqual([...hooks.instanceTabs], ["overview", "timeline", "webhooks", "usage", "metrics"]);
});

// ── parseHash tab codec (D49/D14): #instance/<id>/<tab>, legacy hash → overview ─

test("parseHash: #instance/<id> (the legacy-stable hash) maps to the Overview tab forever", () => {
  sandbox.location.hash = "#instance/9f3c";
  assert.deepEqual({ ...hooks.parseHash() }, { view: "instance", id: "9f3c", tab: "overview" });
});

test("parseHash: #instance/<id>/webhooks selects the registered Webhooks tab", () => {
  sandbox.location.hash = "#instance/9f3c/webhooks";
  assert.deepEqual({ ...hooks.parseHash() }, { view: "instance", id: "9f3c", tab: "webhooks" });
});

test("parseHash: an unregistered or empty tab suffix degrades to Overview (no broken bookmark)", () => {
  sandbox.location.hash = "#instance/9f3c/env"; // not registered this wave
  assert.equal(hooks.parseHash().tab, "overview");
  sandbox.location.hash = "#instance/9f3c/"; // trailing slash, empty tab
  assert.equal(hooks.parseHash().tab, "overview");
  assert.equal(hooks.parseHash().id, "9f3c");
});

test("parseHash: a malformed id escape WITH a tab still never throws", () => {
  sandbox.location.hash = "#instance/x%/webhooks";
  const r = hooks.parseHash();
  assert.equal(r.view, "instance");
  assert.equal(r.id, "x%");
  assert.equal(r.tab, "webhooks");
});

test("legacyRoute stays byte-identical for both #instance/<id> and #instance/<id>/<tab>", () => {
  assert.equal(hooks.legacyRoute("instance/9f3c"), "instance/9f3c");
  assert.equal(hooks.legacyRoute("instance/9f3c/webhooks"), "instance/9f3c/webhooks");
  assert.equal(hooks.legacyRoute("#instance/9f3c/webhooks"), "instance/9f3c/webhooks");
});

test("instanceTabOf clamps to the registered set", () => {
  assert.equal(hooks.instanceTabOf("webhooks"), "webhooks");
  assert.equal(hooks.instanceTabOf("overview"), "overview");
  assert.equal(hooks.instanceTabOf("nope"), "overview");
  assert.equal(hooks.instanceTabOf(undefined), "overview");
});

// ── the tab strip + panel switching (render-level) ──────────────────────────

test("instanceTabStripHtml marks exactly the active tab with aria-current + is-active", () => {
  const bp = { id: "abc", name: "Prod" };
  const wh = hooks.instanceTabStripHtml(bp, "webhooks");
  assert.match(wh, /href="#instance\/abc\/webhooks"[^>]*aria-current="page"/);
  assert.match(wh, /inst-tab is-active[^>]*href="#instance\/abc\/webhooks"/);
  // Overview is present but NOT current.
  assert.match(wh, /href="#instance\/abc\/overview"/);
  assert.doesNotMatch(wh.match(/overview"[^>]*>/)[0], /aria-current/);
});

test("instanceDetailHtml switches the panel by tab: Overview keeps the sites grid, Webhooks is a blank panel", () => {
  const bp = { id: "abc", name: "Prod", host: "1.2.3.4", url: "https://prod" };
  const ov = hooks.instanceDetailHtml(bp, "overview");
  assert.match(ov, /id="instance-sites"/); // the pre-C6 body lives under Overview
  assert.match(ov, /id="instance-tabpanel"/);
  const wh = hooks.instanceDetailHtml(bp, "webhooks");
  assert.doesNotMatch(wh, /id="instance-sites"/); // Webhooks panel is filled after mount
  assert.match(wh, /inst-tab is-active[^>]*webhooks/);
  // The header (name + a status pill) is present on BOTH tabs.
  assert.match(ov, /Prod/);
  assert.match(wh, /Prod/);
});

// ── webhookCliChip: the ratified verb grammar, byte-for-byte with C7 ────────

test("webhookCliChip emits `bp cloud webhook <verb> <instance>` and only appends --dataset off-default", () => {
  assert.equal(hooks.webhookCliChip("list", "abc", "production"), "bp cloud webhook list abc");
  assert.equal(hooks.webhookCliChip("rm", "abc", "production"), "bp cloud webhook rm abc");
  assert.equal(hooks.webhookCliChip("toggle", "abc", "staging"), "bp cloud webhook toggle abc --dataset staging");
  assert.equal(hooks.webhookCliChip("deliveries", "abc"), "bp cloud webhook deliveries abc");
});

test("cliChipHtml wraps the command with a copy affordance", () => {
  const html = hooks.cliChipHtml("bp cloud webhook list abc");
  assert.match(html, /class="cli-chip-code">bp cloud webhook list abc</);
  assert.match(html, /data-copy="bp cloud webhook list abc"/);
});

// ── webhookEventsHtml ───────────────────────────────────────────────────────

test("webhookEventsHtml: empty subscription reads 'all events'; events + types render as chips", () => {
  assert.match(hooks.webhookEventsHtml({}), /all events/);
  const html = hooks.webhookEventsHtml({ events: ["create", "publish"], types: ["post"] });
  assert.match(html, /wh-event-chip">create</);
  assert.match(html, /wh-event-chip">publish</);
  assert.match(html, /wh-event-chip">type:post</);
});

// ── webhookBannerHtml: autodisable substrate rendered VERBATIM (#1013) ───────

test("webhookBannerHtml renders NOTHING until auto_disabled_at is set", () => {
  assert.equal(hooks.webhookBannerHtml({ active: false, consecutive_failures: 3 }), "");
});

test("webhookBannerHtml prints the verbatim disable_reason + a Re-enable button, and authors NO count of its own (D-05 count-free)", () => {
  const html = hooks.webhookBannerHtml({
    auto_disabled_at: "2026-07-03T12:00:00Z",
    disable_reason: "endpoint returned 500 Internal Server Error",
    consecutive_failures: 20,
  });
  assert.match(html, /Auto-disabled/);
  assert.match(html, /endpoint returned 500 Internal Server Error/); // verbatim server reason
  // D-05: the client no longer echoes consecutive_failures — the disable
  // THRESHOLD is live instance config, never a client-authored number.
  assert.doesNotMatch(html, /wh-autodisable-count/);
  assert.doesNotMatch(html, /20 consecutive failures/);
  assert.match(html, /data-wh-reenable/); // PUT {active:true} via the update capability
  assert.match(html, /notice-error/);
});

test("webhookBannerHtml falls back to a count-free sentence when the instance sent no reason", () => {
  const html = hooks.webhookBannerHtml({ auto_disabled_at: "2026-07-03T12:00:00Z", consecutive_failures: 42 });
  assert.match(html, /repeated delivery failures/);
  assert.doesNotMatch(html, /42/); // no live-config threshold leaks into the copy
});

test("webhookBannerHtml escapes a hostile disable_reason (no injection)", () => {
  const html = hooks.webhookBannerHtml({
    auto_disabled_at: "2026-07-03T12:00:00Z",
    disable_reason: "<img src=x onerror=alert(1)>",
    consecutive_failures: 5,
  });
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /&lt;img/);
});

test("webhookBannerHtml suppresses the banner once the row is active again (Re-enable is not a dead loop)", () => {
  // The instance's PUT path cannot clear the server-managed auto_disabled_at
  // stamp, so a successfully re-enabled row STILL carries it — the banner must
  // gate on the row being inactive or Re-enable would appear to do nothing.
  const html = hooks.webhookBannerHtml({
    active: true,
    auto_disabled_at: "2026-07-03T12:00:00Z",
    disable_reason: "gave up after 20 tries",
    consecutive_failures: 20,
  });
  assert.equal(html, "");
});

// ── webhookCardHtml ─────────────────────────────────────────────────────────

test("webhookCardHtml reflects active state (Active pill + Disable) and carries per-action CLI chips", () => {
  const html = hooks.webhookCardHtml(
    { id: "wh1", name: "Prod hook", url: "https://x/h", active: true, events: [], updated_at: "2026-07-03T12:00:00Z" },
    "abc", "production");
  assert.match(html, /data-wh="wh1"/);
  assert.match(html, /status-pill--ok/);
  assert.match(html, /data-wh-toggle>Disable</);
  assert.match(html, /data-wh-rotate/);
  assert.match(html, /data-wh-deliveries/);
  assert.match(html, /data-wh-delete/);
  for (const verb of ["show", "toggle", "rotate", "deliveries", "rm"]) {
    assert.match(html, new RegExp("bp cloud webhook " + verb + " abc"));
  }
});

test("webhookCardHtml reflects disabled state (neutral pill + Enable)", () => {
  const html = hooks.webhookCardHtml({ id: "wh2", url: "https://x", active: false }, "abc", "production");
  assert.match(html, /status-pill--neutral/);
  assert.match(html, /data-wh-toggle>Enable</);
});

// ── deliveryTone: the status-token contract ─────────────────────────────────

test("deliveryTone: 2xx→ok, 4xx/5xx→danger, pending/other→info", () => {
  assert.equal(hooks.deliveryTone({ last_status_code: 200 }), "ok");
  assert.equal(hooks.deliveryTone({ status_code: 204 }), "ok");
  assert.equal(hooks.deliveryTone({ last_status_code: 404 }), "danger");
  assert.equal(hooks.deliveryTone({ last_status_code: 503 }), "danger");
  assert.equal(hooks.deliveryTone({ last_status_code: 302 }), "info");
  assert.equal(hooks.deliveryTone({ status: "pending" }), "info");
  assert.equal(hooks.deliveryTone({ status: "delivered" }), "ok");
  assert.equal(hooks.deliveryTone({ status: "failed" }), "danger");
  // The instance's ACTUAL terminal token (Delivery @statuses) — a connect-
  // failure give-up carries no status code, only this string.
  assert.equal(hooks.deliveryTone({ status: "failed_giveup" }), "danger");
  assert.equal(hooks.deliveryTone({}), "info");
});

// ── deliveryStatusLabel: the v4 pill grammar (HTTP 500 / 200 OK) ─────────────

test("deliveryStatusLabel: 2xx → '<code> OK', 4xx/5xx → 'HTTP <code>', code-less give-up → 'failed', else 'pending'", () => {
  assert.equal(hooks.deliveryStatusLabel({ last_status_code: 200 }), "200 OK");
  assert.equal(hooks.deliveryStatusLabel({ status_code: 204 }), "204 OK");
  assert.equal(hooks.deliveryStatusLabel({ last_status_code: 500 }), "HTTP 500");
  assert.equal(hooks.deliveryStatusLabel({ last_status_code: 404 }), "HTTP 404");
  assert.equal(hooks.deliveryStatusLabel({ status: "failed_giveup" }), "failed"); // no instance jargon
  assert.equal(hooks.deliveryStatusLabel({ status: "delivered" }), "OK");
  assert.equal(hooks.deliveryStatusLabel({ status: "pending" }), "pending");
  assert.equal(hooks.deliveryStatusLabel({}), "pending");
});

test("deliveryRowHtml renders the v4 pill (HTTP 500), the event id, attempts+latency meta, and a Replay keyed by event_id", () => {
  const html = hooks.deliveryRowHtml(
    { event_id: 42, last_status_code: 500, last_latency_ms: 182, attempts: 3, updated_at: "2026-07-03T12:00:00Z" },
    "abc", "production");
  assert.match(html, /wh-del-status--danger">HTTP 500</); // the designed failed treatment
  assert.match(html, /182ms/);
  assert.match(html, /event #42/);
  assert.match(html, /3 attempts/);
  assert.match(html, /wh-del-replay[^>]*data-wh-replay="42"/); // the blue replay affordance
});

test("deliveryRowHtml: a clean 2xx reads '200 OK' (ok tone)", () => {
  const html = hooks.deliveryRowHtml({ event_id: 5, last_status_code: 200, last_latency_ms: 84, attempts: 1 }, "abc", "production");
  assert.match(html, /wh-del-status--ok">200 OK</);
  assert.match(html, /1 attempt &middot; 84ms/); // singular attempt + latency in the meta
  assert.doesNotMatch(html, /1 attempts/); // no dangling plural
});

test("deliveryRowHtml: a code-less failed_giveup row reads 'failed' (danger) with no jargon and no dangling meta", () => {
  const html = hooks.deliveryRowHtml({ event_id: 7, status: "failed_giveup" }, "abc", "production");
  assert.match(html, /wh-del-status--danger">failed</); // no raw failed_giveup jargon
  assert.doesNotMatch(html, /failed_giveup/);
  assert.doesNotMatch(html, /wh-del-meta/); // no attempts + no latency → the meta span is omitted, not a dangling dash
});

test("deliveryRowHtml surfaces the verbatim last_error_text of a failed delivery, escaped", () => {
  const html = hooks.deliveryRowHtml(
    { event_id: 9, status: "failed_giveup", attempts: 5, last_error_text: "connect ECONNREFUSED <10.0.0.9:443>" },
    "abc", "production");
  assert.match(html, /wh-del-err/);
  assert.match(html, /connect ECONNREFUSED &lt;10\.0\.0\.9:443&gt;/);
  assert.doesNotMatch(html, /<10\.0\.0\.9/); // escaped, not injected
  // And a clean delivery renders no error line at all.
  assert.doesNotMatch(
    hooks.deliveryRowHtml({ event_id: 1, last_status_code: 200, attempts: 1 }, "abc", "production"),
    /wh-del-err/);
});

// ── replayToastBody: the REAL replay outcome, never the prototype's mock ─────

test("replayToastBody names the real status + latency ('Delivery replayed · 200 OK in 84 ms'), never a canned string", () => {
  assert.equal(
    hooks.replayToastBody({ last_status_code: 200, last_latency_ms: 84 }, 5),
    "Delivery replayed · 200 OK in 84 ms");
  // A failed re-attempt is reported honestly (the replay itself succeeded; the
  // target answered 500) rather than claiming success.
  assert.equal(
    hooks.replayToastBody({ last_status_code: 500, last_latency_ms: 12 }, 9),
    "Delivery replayed · HTTP 500 in 12 ms");
  // An older instance that echoes no delivery detail degrades to the plain ack,
  // never an invented status.
  assert.equal(hooks.replayToastBody(null, 7), "event #7");
  assert.equal(hooks.replayToastBody({}, ""), "Delivery replayed");
});

// ── hookToggleState: the D18 optimistic grammar (reconcile on RESPONSE) ──────

test("hookToggleState: idle shows the inverse action; pending shows the transition; failure is 'Unconfirmed — retry'", () => {
  // Active endpoint, idle → offer Disable. (Spread into a host-realm object so
  // deepEqual compares by value, not the vm sandbox's foreign prototype.)
  assert.deepEqual({ ...hooks.hookToggleState(true, "idle") },
    { disabled: false, checked: true, label: "Disable", tone: "neutral", note: "" });
  // Mid-flight → transitional label, disabled, no lie.
  assert.deepEqual({ ...hooks.hookToggleState(true, "pending") },
    { disabled: true, checked: true, label: "Disabling…", tone: "info", note: "" });
  assert.deepEqual({ ...hooks.hookToggleState(false, "pending") },
    { disabled: true, checked: false, label: "Enabling…", tone: "info", note: "" });
  // Timed-out / failed resolve → back to the KNOWN state with an honest note.
  assert.deepEqual({ ...hooks.hookToggleState(true, "unconfirmed") },
    { disabled: false, checked: true, label: "Disable", tone: "warn", note: "Unconfirmed — retry" });
});

// ── webhookErrorHtml: the D51 degradation grammar ───────────────────────────

test("webhookErrorHtml: a 502 {reachable:false} envelope is retry, never a spinner", () => {
  const html = hooks.webhookErrorHtml({ ok: false, error: { code: "instance_unreachable" }, reachable: false }, "abc");
  assert.match(html, /unreachable/i);
  assert.match(html, /data-wh-retry/);
});

test("webhookErrorHtml: capability_unavailable renders the update hint + the bp cloud update chip (no retry)", () => {
  const html = hooks.webhookErrorHtml({ ok: false, error: { code: "capability_unavailable", hint: "update this instance" } }, "abc");
  assert.match(html, /needs an update/i);
  assert.match(html, /bp cloud update abc/);
  assert.doesNotMatch(html, /data-wh-retry/);
});

test("webhookErrorHtml: coded webhook_not_found AND an older uncoded upstream 404 both read not-found", () => {
  const coded = hooks.webhookErrorHtml({ ok: false, error: { code: "webhook_not_found" } }, "abc");
  assert.match(coded, /not found/i);
  const older = hooks.webhookErrorHtml({ ok: false, error: { code: "upstream_error", status: 404 } }, "abc");
  assert.match(older, /not found/i);
});

test("webhookErrorHtml: not_live degrades honestly (D55) rather than 404ing", () => {
  const html = hooks.webhookErrorHtml({ ok: false, error: { code: "not_live" } }, "abc");
  assert.match(html, /live yet/); // apostrophe is HTML-escaped in the output
  assert.match(html, /data-wh-retry/);
});

test("webhookMutationError digs the first field error out of a relayed upstream validation envelope", () => {
  const msg = hooks.webhookMutationError({
    ok: false,
    error: { code: "upstream_error", status: 422, detail: { error: { details: { url: ["must be https"] } } } },
  });
  assert.equal(msg, "url must be https");
  assert.equal(hooks.webhookMutationError({ ok: false, error: { code: "instance_unreachable" }, reachable: false }),
    "Couldn't reach the instance — the change is unconfirmed.");
});

test("network failure (api()'s string-code shape) reads as a network error, not 'check the details'", () => {
  // fetch itself rejected → api() resolves { ok:false, status:0, data:{ error:"network_error" } }.
  const netData = { error: "network_error" };
  assert.match(hooks.webhookMutationError(netData), /[Nn]etwork error/);
  const html = hooks.webhookErrorHtml(netData, "abc");
  assert.match(html, /Network error/);
  assert.match(html, /data-wh-retry/); // still retryable, never a dead end
});

// ── Fake-DOM WIRING smoke: tab mount + toggle reconcile ─────────────────────

test("mountWebhooksTab: paints the toolbar + list shell synchronously without throwing", () => {
  const root = fakeNode();
  hooks.mountWebhooksTab(root, { id: "abc", url: "https://prod" });
  assert.match(root.innerHTML, /wh-toolbar/);
  assert.match(root.innerHTML, /wh-list/);
  assert.match(root.innerHTML, /data-wh-new/);
  assert.match(root.innerHTML, /wh-dataset-input/);
});

test("toggle reconcile: the pending label flips, then the card repaints from the RESPONSE body, not the guess", () => {
  // 1. Optimistic pending label while the PUT is in flight (active → disabling).
  assert.equal(hooks.hookToggleState(true, "pending").label, "Disabling…");
  // 2. Server RESPONSE says active:false → the reconciled card shows Disabled/Enable,
  //    even though an optimistic guess would have to trust the request.
  const reconciled = hooks.webhookCardHtml({ id: "wh1", url: "https://x", active: false }, "abc", "production");
  assert.match(reconciled, /status-pill--neutral/);
  assert.match(reconciled, /data-wh-toggle>Enable</);
  // 3. And a response that auto-disabled the row surfaces the verbatim banner.
  const disabled = hooks.webhookCardHtml({
    id: "wh1", url: "https://x", active: false,
    auto_disabled_at: "2026-07-03T12:00:00Z", disable_reason: "gave up after 20 tries", consecutive_failures: 20,
  }, "abc", "production");
  assert.match(disabled, /gave up after 20 tries/);
  assert.match(disabled, /data-wh-reenable/);
});

// ════════════════════════════════════════════════════════════════════════════
// A4 — onboarding narrative: welcome runway → launch flow → ready fold (D56/57/60/66)
// ════════════════════════════════════════════════════════════════════════════

test("A4: the launch/runway/ready-fold pure helpers are exported", () => {
  for (const name of ["wantsLaunchFlow", "runwaySubline", "welcomeHeroHtml",
    "launchedHash", "launchFlowReducer", "readyFoldTrigger", "readyHeroHtml",
    "railValue"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

// ── launchedHash: 201 body → the instance story, never #fleet (A5 envelope) ──
test("launchedHash routes a 201 body to #instance/<id> (and null on a missing id)", () => {
  assert.equal(hooks.launchedHash({ barkpark: { id: "9f3c-42" } }), "#instance/9f3c-42");
  assert.equal(hooks.launchedHash({ barkpark: {} }), null);
  assert.equal(hooks.launchedHash({}), null);
  assert.equal(hooks.launchedHash(null), null);
  // Ids are URL-encoded into the hash (defensive; parseHash safeDecodes back).
  assert.equal(hooks.launchedHash({ barkpark: { id: "a b" } }), "#instance/a%20b");
});

// ── launchFlowReducer: empty→name→402-plan→checkout-return-resume→submitted ──
test("launchFlowReducer walks the full happy+402 path", () => {
  let s = "name";
  s = hooks.launchFlowReducer(s, { type: "submit" });
  assert.equal(s, "submitting");
  s = hooks.launchFlowReducer(s, { type: "result", status: 402 });
  assert.equal(s, "plan"); // un-entitled → inline plan fold
  s = hooks.launchFlowReducer(s, { type: "choosePlan" });
  assert.equal(s, "checkout"); // hand off to Stripe
  s = hooks.launchFlowReducer(s, { type: "resume" }); // return from checkout
  assert.equal(s, "name");
  s = hooks.launchFlowReducer(s, { type: "submit" });
  assert.equal(s, "submitting");
  s = hooks.launchFlowReducer(s, { type: "result", status: 201 });
  assert.equal(s, "submitted"); // entitled now → launched
});

test("launchFlowReducer: a launch error drops back to the name step; junk is inert", () => {
  assert.equal(hooks.launchFlowReducer("submitting", { type: "result", status: 500 }), "name");
  assert.equal(hooks.launchFlowReducer("name", { type: "nonsense" }), "name");
  assert.equal(hooks.launchFlowReducer("plan", {}), "plan");
  assert.equal(hooks.launchFlowReducer("submitted", { type: "submit" }), "submitted");
  assert.equal(hooks.launchFlowReducer("plan", { type: "resume" }), "name"); // resume always re-enters
});

// ── readyFoldTrigger: the provision→live predicate ──────────────────────────
test("readyFoldTrigger flips only for a settled, hosted (live) instance", () => {
  assert.equal(hooks.readyFoldTrigger({ host: "1.2.3.4", provision_status: "succeeded" }), true);
  assert.equal(hooks.readyFoldTrigger({ host: null, provision_status: "claimed" }), false); // provisioning
  assert.equal(hooks.readyFoldTrigger({ host: null, provision_status: "failed" }), false);  // failed
  assert.equal(hooks.readyFoldTrigger({ host: "1.2.3.4", suspended: true }), false);        // suspended
  assert.equal(hooks.readyFoldTrigger({ host: "1.2.3.4", deprovision_status: "pending" }), false); // removing
  assert.equal(hooks.readyFoldTrigger(null), false); // total over junk
});

// ── railValue: honest '—' pre-host, never a scare value ─────────────────────
test("railValue reads '—' until the box has a host, then the real value", () => {
  assert.equal(hooks.railValue("Unknown", false), "—");
  assert.equal(hooks.railValue("Offline", false), "—");
  assert.equal(hooks.railValue("Healthy", true), "Healthy");
  assert.equal(hooks.railValue("Online", true), "Online");
});

// ── runwaySubline + welcomeHeroHtml: trial vs no-trial (DOM-string smoke) ────
test("runwaySubline is trial-first: un-entitled/trial/absent → free-trial invite; paid → managed", () => {
  const future = new Date(Date.now() + 5 * 86400000).toISOString();
  // Absent / trial / free all read as the free-trial invitation (server auto-starts it).
  assert.match(hooks.runwaySubline(null), /Free trial/);
  assert.match(hooks.runwaySubline({ plan: "trial", current_period_end: future }), /Free trial/);
  assert.match(hooks.runwaySubline({ plan: "free", status: "active" }), /Free trial/);
  // An already-entitled paid team gets the plain managed line — NOT the trial pitch.
  assert.match(hooks.runwaySubline({ plan: "supporter", status: "active" }), /Fully managed/);
  assert.doesNotMatch(hooks.runwaySubline({ plan: "supporter", status: "active" }), /Free trial/);
});

test("welcomeHeroHtml renders the what-is-a-Barkpark line + the right trial subline for each fixture", () => {
  const trial = hooks.welcomeHeroHtml({ plan: "trial", current_period_end: new Date(Date.now() + 86400000).toISOString() });
  const paid = hooks.welcomeHeroHtml({ plan: "supporter", status: "active" });
  for (const html of [trial, paid]) {
    assert.match(html, /runway-hero/);
    assert.match(html, /fully-managed headless CMS instance/); // what a Barkpark IS
    assert.match(html, /class="runway-sub"/); // the live-updatable subline slot (class-addressed — the component multi-mounts)
  }
  assert.match(trial, /Free trial/);
  assert.match(paid, /Fully managed/);
});

// ── readyHeroHtml: the ONE shared ready renderer (/new + in-shell fold) ──────
test("readyHeroHtml renders the shared core and parametrises the studio/view wiring", () => {
  // In-shell fold: a dismiss button, no /new extras, h2 (the instance header
  // owns that page's h1).
  const fold = hooks.readyHeroHtml(
    { name: "Prod", id: "abc", url: "prod.example.com" },
    { studioBtnId: "inst-ready-studio", viewBtnId: "inst-ready-dismiss", viewLabel: "View details", demoteHeading: true },
  );
  assert.match(fold, /<h2 class="new-title">Prod is ready<\/h2>/);
  assert.match(fold, /id="inst-ready-studio"[^>]*>Open Studio</);
  assert.match(fold, /id="inst-ready-dismiss"[^>]*>View details</);
  assert.match(fold, /prod\.example\.com/);
  assert.doesNotMatch(fold, /btn-vercel/); // no /new extras leak into the fold

  // /new usage: the extra actions + tail are threaded through the same core.
  const neu = hooks.readyHeroHtml(
    { name: "Site", id: "def" },
    { studioBtnId: "new-open-studio", viewHref: "/#instance/def", viewLabel: "View instance",
      extra: '<a class="btn btn-block btn-vercel" id="new-vercel" href="#">Deploy</a>', tail: '<div class="new-env"></div>' },
  );
  assert.match(neu, /id="new-open-studio"/);
  assert.match(neu, /<h1 class="new-title">Site is ready<\/h1>/); // /new is a standalone page: keeps the h1
  assert.match(neu, /btn-vercel/);
  assert.match(neu, /href="\/#instance\/def"/);
  assert.match(neu, /new-env/); // tail rendered after the actions
});

test("readyHeroHtml escapes the instance name (no markup injection)", () => {
  const html = hooks.readyHeroHtml({ name: "<script>x</script>", id: "z" }, { studioBtnId: "s" });
  assert.doesNotMatch(html, /<script>x/);
  assert.match(html, /&lt;script&gt;/);
});

// ═════════════════════════════════════════════════════════════════════════════
// Zero-broken-promises slice (charter D5/D7/D25/D26): the shared confirm modal,
// the promote (rollback/redeploy) grammar, and the invitation-accept landing.
// ═════════════════════════════════════════════════════════════════════════════

test("the zero-broken-promises helpers are exported", () => {
  for (const name of [
    "confirmModalInit", "confirmModalReduce", "confirmModalArmed", "confirmModalTypedMatch",
    "confirmModalHtml", "trapTarget",
    "promotePath", "promoteActionFor", "promoteConfirmCopy", "promoteFailure",
    "deployRefLabel", "deployRow",
    "parseInviteToken", "inviteLandingState", "inviteTerminalFrom", "inviteStateHtml",
  ]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

// ── confirmModal: the pure state machine (D5, both tiers) ────────────────────

test("confirmModalInit: mutate is the default tier and ships armed; junk is total", () => {
  const s = hooks.confirmModalInit({ title: "Deploy?", consequence: "One sentence." });
  assert.equal(s.tier, "mutate");
  assert.equal(s.phase, "open");
  assert.deepEqual([...s.consequences], ["One sentence."]);
  assert.equal(hooks.confirmModalTypedMatch(s), true);   // mutate: no echo needed
  assert.equal(hooks.confirmModalArmed(s), true);
  // Total over junk: no opts at all still yields a coherent open state.
  const bare = hooks.confirmModalInit();
  assert.equal(bare.tier, "mutate");
  assert.equal(hooks.confirmModalArmed(bare), true);
});

test("confirmModal destroy tier: disarmed until the typed echo matches EXACTLY", () => {
  let s = hooks.confirmModalInit({
    tier: "destroy", title: "Delete prod-db?", resourceName: "prod-db",
    consequences: ["All data is erased.", "This cannot be undone."],
  });
  assert.equal(s.tier, "destroy");
  assert.equal(hooks.confirmModalTypedMatch(s), false);
  assert.equal(hooks.confirmModalArmed(s), false);
  // Wrong case / partial / padded → still disarmed (no trim, no case-folding).
  for (const typed of ["Prod-DB", "prod-d", " prod-db", "prod-db "]) {
    const t = hooks.confirmModalReduce(s, { type: "type", value: typed });
    assert.equal(hooks.confirmModalArmed(t), false, JSON.stringify(typed) + " must not arm");
  }
  s = hooks.confirmModalReduce(s, { type: "type", value: "prod-db" });
  assert.equal(hooks.confirmModalTypedMatch(s), true);
  assert.equal(hooks.confirmModalArmed(s), true);
  // A destroy modal with NO resource name can never arm (fail closed).
  const noName = hooks.confirmModalInit({ tier: "destroy" });
  assert.equal(hooks.confirmModalTypedMatch(hooks.confirmModalReduce(noName, { type: "type", value: "" })), false);
});

test("confirmModalReduce walks open → busy → error → busy → done; illegal moves are no-ops", () => {
  let s = hooks.confirmModalInit({ title: "T", consequence: "C" });
  // fail/succeed outside busy: unchanged.
  assert.equal(hooks.confirmModalReduce(s, { type: "fail", message: "x" }).phase, "open");
  assert.equal(hooks.confirmModalReduce(s, { type: "succeed" }).phase, "open");
  s = hooks.confirmModalReduce(s, { type: "confirm" });
  assert.equal(s.phase, "busy");
  // typing while busy is ignored; confirming while busy is ignored.
  assert.equal(hooks.confirmModalReduce(s, { type: "type", value: "x" }).typed, "");
  assert.equal(hooks.confirmModalReduce(s, { type: "confirm" }).phase, "busy");
  s = hooks.confirmModalReduce(s, { type: "fail", message: "nope" });
  assert.equal(s.phase, "error");
  assert.equal(s.error, "nope");
  // error phase stays armed (mutate) → retry can re-enter busy without re-typing.
  assert.equal(hooks.confirmModalArmed(s), true);
  s = hooks.confirmModalReduce(s, { type: "confirm" });
  assert.equal(s.phase, "busy");
  assert.equal(s.error, null); // a retry clears the stale error
  s = hooks.confirmModalReduce(s, { type: "succeed" });
  assert.equal(s.phase, "done");
  // dismiss is legal from anywhere; unknown events + junk are total no-ops.
  assert.equal(hooks.confirmModalReduce(s, { type: "dismiss" }).phase, "closed");
  assert.equal(hooks.confirmModalReduce(s, { type: "wat" }), s);
  assert.equal(hooks.confirmModalReduce(null, { type: "confirm" }), null);
  assert.equal(hooks.confirmModalReduce(s, null), s);
});

test("confirmModalHtml: mutate renders one sentence + live Confirm; destroy renders list + disabled Confirm + echo input", () => {
  const m = hooks.confirmModalHtml(hooks.confirmModalInit({
    title: "Roll back?", consequence: "This creates a new deployment.", confirmLabel: "Roll back",
  }));
  assert.match(m, /cm-consequence/);
  assert.match(m, /This creates a new deployment\./);
  assert.doesNotMatch(m, /cm-typed/);          // no echo input on the mutate tier
  assert.doesNotMatch(m, /id="cm-confirm" disabled/); // armed from the start
  assert.match(m, /btn-primary/);
  assert.match(m, /data-close>Cancel</);       // dismissal is always available

  const d = hooks.confirmModalHtml(hooks.confirmModalInit({
    tier: "destroy", title: "Delete prod-db?", resourceName: "prod-db",
    consequences: ["All data is erased.", "Billing stops."], confirmLabel: "Delete",
  }));
  assert.match(d, /cm-consequences/);
  assert.match(d, /<li>All data is erased\.<\/li><li>Billing stops\.<\/li>/);
  assert.match(d, /id="cm-typed"/);
  assert.match(d, /id="cm-confirm" disabled/); // disarmed until the echo matches
  assert.match(d, /btn-danger/);
});

test("confirmModalHtml escapes hostile titles/consequences/resource names", () => {
  const html = hooks.confirmModalHtml(hooks.confirmModalInit({
    tier: "destroy", title: '<img src=x onerror=1>', resourceName: '"><script>',
    consequences: ["<b>bold</b>"],
  }));
  assert.doesNotMatch(html, /<img/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;img src=x onerror=1&gt;/);
  assert.match(html, /&lt;b&gt;bold&lt;\/b&gt;/);
});

// ── trapTarget: the pure focus-trap edge logic the modal Tab handler uses ────

test("trapTarget cycles Tab/Shift+Tab at the list edges and snaps escaped focus back", () => {
  const f = ["a", "b", "c"];
  assert.equal(hooks.trapTarget(f, "c", false), "a"); // Tab past the end wraps
  assert.equal(hooks.trapTarget(f, "a", true), "c");  // Shift+Tab past the start wraps
  assert.equal(hooks.trapTarget(f, "b", false), null); // mid-list: browser moves naturally
  assert.equal(hooks.trapTarget(f, "b", true), null);
  assert.equal(hooks.trapTarget(f, "zz", false), "a"); // focus escaped → snap to first
  assert.equal(hooks.trapTarget([], "a", false), null); // empty: caller pins
  assert.equal(hooks.trapTarget(null, "a", false), null);
  assert.equal(hooks.trapTarget(["only"], "only", false), "only"); // single element pins to itself
  assert.equal(hooks.trapTarget(["only"], "only", true), "only");
});

// ── promote grammar: URL builder, action ladder, confirm copy, failure map ──

test("promotePath percent-encodes both ids into their path segments", () => {
  assert.equal(hooks.promotePath("s1", "d1"), "/v1/sites/s1/deployments/d1/promote");
  assert.equal(
    hooks.promotePath("a/b", "c d"),
    "/v1/sites/a%2Fb/deployments/c%20d/promote",
  );
});

test("promoteActionFor: current live → Redeploy; prior live → Roll back; everything else → nothing", () => {
  const cur = { id: "d1", status: "live", environment: "production" };
  const prior = { id: "d0", status: "live", environment: "production" };
  assert.equal(hooks.promoteActionFor(cur, "d1").kind, "redeploy");
  assert.equal(hooks.promoteActionFor(cur, "d1").label, "Redeploy");
  assert.equal(hooks.promoteActionFor(prior, "d1").kind, "rollback");
  assert.equal(hooks.promoteActionFor(prior, "d1").label, "Roll back to this");
  // No current pointer at all → a live row still offers rollback (it IS prior).
  assert.equal(hooks.promoteActionFor(prior, null).kind, "rollback");
  // Non-live rows have no proven artifact to promote.
  for (const st of ["queued", "building", "pushing", "failed"]) {
    assert.equal(hooks.promoteActionFor({ id: "x", status: st }, "d1"), null, st);
  }
  // Branch previews are never promotable (server 422s them too).
  assert.equal(hooks.promoteActionFor({ id: "p", status: "live", environment: "preview" }, "d1"), null);
  assert.equal(hooks.promoteActionFor(null, "d1"), null);
});

test("promoteConfirmCopy: one honest consequence sentence per kind", () => {
  const rb = hooks.promoteConfirmCopy("rollback", "4e7d0c9");
  assert.match(rb.title, /Roll back to 4e7d0c9\?/);
  assert.match(rb.consequence, /new production deployment pinned to 4e7d0c9/);
  assert.match(rb.consequence, /stays in history/);
  assert.equal(rb.confirmLabel, "Roll back");
  const rd = hooks.promoteConfirmCopy("redeploy", "9c1f2ab");
  assert.match(rd.title, /Redeploy 9c1f2ab\?/);
  assert.match(rd.consequence, /same source \(9c1f2ab\)/);
  assert.match(rd.consequence, /keeps serving until the new one is live/);
  assert.equal(rd.confirmLabel, "Redeploy");
});

test("promoteFailure maps every server refusal to a human sentence + ONE recovery", () => {
  const conflict = hooks.promoteFailure(409, { error: "build_in_progress" });
  assert.match(conflict.message, /already in progress/);
  assert.equal(conflict.recovery, "refresh");
  assert.equal(hooks.promoteFailure(404, { error: "not_found" }).recovery, "refresh");
  assert.match(hooks.promoteFailure(422, { error: "not_promotable" }).message, /previews can't be promoted/);
  assert.match(hooks.promoteFailure(422, { error: "no_build_source" }).message, /nothing to rebuild from/);
  // Network/unknown failures are retryable — the modal's one action is Try again.
  assert.equal(hooks.promoteFailure(0, { error: "network_error" }).recovery, "retry");
  assert.equal(hooks.promoteFailure(500, {}).recovery, "retry");
  // Every branch yields a non-empty human sentence.
  for (const [st, data] of [[409, {}], [404, {}], [422, { error: "not_promotable" }],
    [422, { error: "no_build_source" }], [0, {}], [500, null]]) {
    const f = hooks.promoteFailure(st, data);
    assert.ok(typeof f.message === "string" && f.message.length > 10, st + " message");
    assert.ok(f.recovery === "retry" || f.recovery === "refresh");
  }
});

test("deployRefLabel prefers git sha, then image tag, then row id — always short", () => {
  assert.equal(hooks.deployRefLabel({ git_ref: "4e7d0c9aa112233445566", image_tag: "site:20" }), "4e7d0c9");
  assert.equal(hooks.deployRefLabel({ image_tag: "marketing:2026-07-03" }), "marketing:20"); // shortId caps at 12
  assert.equal(hooks.deployRefLabel({ id: "0123456789abcdef" }), "0123456789ab");
  assert.equal(hooks.deployRefLabel(null), "");
});

// ── deployRow: the rendered promise — actions, Current chip, git meta ────────

test("deployRow: the current live row gets Redeploy + the Current chip; a prior live row gets Roll back", () => {
  const cur = { id: "d2", status: "live", git_ref: "9c1f2ab", branch: "main", became_live_at: "2026-07-03T10:00:00Z" };
  const prior = { id: "d1", status: "live", git_ref: "4e7d0c9", branch: "main", became_live_at: "2026-07-01T10:00:00Z" };
  const curHtml = hooks.deployRow(cur, "d2");
  assert.match(curHtml, /dep-promote/);
  assert.match(curHtml, /data-kind="redeploy"/);
  assert.match(curHtml, /dep-current/);
  assert.match(curHtml, />Redeploy</);
  const priorHtml = hooks.deployRow(prior, "d2");
  assert.match(priorHtml, /data-kind="rollback"/);
  assert.match(priorHtml, />Roll back to this</);
  assert.doesNotMatch(priorHtml, /dep-current/);
  // Git meta rides along: branch + live-since phrasing.
  assert.match(priorHtml, /main/);
  assert.match(priorHtml, /live since /);
});

test("deployRow: failed/active rows offer no promote action (and no Current chip without a match)", () => {
  const failed = { id: "d3", status: "failed", git_ref: "b23aa01", failure_reason: "npm run build exited 1" };
  const html = hooks.deployRow(failed, "d2");
  assert.doesNotMatch(html, /dep-promote/);
  assert.doesNotMatch(html, /dep-current/);
  assert.match(html, /npm run build exited 1/);
  const building = { id: "d4", status: "building" };
  assert.doesNotMatch(hooks.deployRow(building, "d2"), /dep-promote/);
});

test("deployRow shortens a full-sha headline to 7 chars (full sha on hover); non-sha refs stay verbatim", () => {
  const full = "4e7d0c9b3a5f18e2d6c4b0a9f8e7d6c5b4a39281";
  const html = hooks.deployRow({ id: "d1", status: "live", git_ref: full }, null);
  assert.match(html, />4e7d0c9</);                       // 7-char short form
  assert.match(html, new RegExp('title="' + full + '"')); // full sha within reach
  assert.doesNotMatch(html, new RegExp(">" + full + "<")); // never the 40-char wall
  // A non-hex ref (tag / hand-set) is NOT a sha — renders verbatim, no title.
  const tag = hooks.deployRow({ id: "d2", status: "live", git_ref: "release-2026-07" }, null);
  assert.match(tag, />release-2026-07</);
  assert.doesNotMatch(tag, /title=/);
});

test("deployRow escapes hostile git meta (branch, ref, id)", () => {
  const evil = {
    id: 'd5" onclick="x', status: "live",
    git_ref: "<script>alert(1)</script>", branch: '<img src=x>',
    became_live_at: "2026-07-03T10:00:00Z",
  };
  const html = hooks.deployRow(evil, "other");
  assert.doesNotMatch(html, /<script>alert/);
  assert.doesNotMatch(html, /<img src=x>/);
  assert.match(html, /&lt;script&gt;/);
});

// ═════════════════════════════════════════════════════════════════════════════
// stw5 (charter D25/D28): the SITE-level synchronous rollback + capped deploy
// history. DISTINCT from the per-row async promote above — this flips the whole
// site to its previous release in place, synchronously, minting NO Deployment row.
// ═════════════════════════════════════════════════════════════════════════════

test("the stw5 site-rollback helpers are exported", () => {
  for (const name of [
    "siteRollbackPath", "siteRollbackConfirmOpts", "siteRollbackRefusalTerminal",
    "siteRollbackResult", "siteRollbackFailure", "siteRollbackFlashView",
    "deployRollbackBannerHtml", "deployTriggerLabel",
  ]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("siteRollbackPath targets the site rollback endpoint and encodes a hostile id", () => {
  assert.equal(hooks.siteRollbackPath("s1"), "/v1/sites/s1/rollback");
  assert.match(hooks.siteRollbackPath('a/b?x=1'), /\/v1\/sites\/a%2Fb%3Fx%3D1\/rollback/);
});

test("gr41: siteRollbackConfirmOpts rides the danger-no-echo shared modal: escaped domain, honest copy, inline-failure surface", () => {
  const opts = hooks.siteRollbackConfirmOpts({ id: "s1" }, "shop.example.com");
  assert.equal(opts.tier, "danger");                // no typed echo — reversible-grave, not destroy
  const html = hooks.confirmModalHtml(hooks.confirmModalInit(opts));
  assert.match(html, /Roll back shop\.example\.com\?/); // names the site
  assert.match(html, /id="cm-confirm"/);            // the SHARED confirm trigger
  assert.doesNotMatch(html, /id="cm-confirm" disabled/); // armed from the start
  assert.doesNotMatch(html, /cm-typed/);            // no echo input
  assert.match(html, /btn-danger/);
  assert.match(html, /data-close/);                 // Cancel
  assert.match(html, /id="cm-error"/);              // D25 inline-failure surface
  assert.match(html, /<b>previous release<\/b>/);   // honest consequence (rich-body slot)
  assert.match(html, /no rebuild/);                 // NOT the async build path
  // Hostile domain never injects markup (rides title → esc'd by confirmModalHtml).
  const evil = hooks.confirmModalHtml(hooks.confirmModalInit(
    hooks.siteRollbackConfirmOpts({ id: "s1" }, '<img src=x onerror="y">')));
  assert.doesNotMatch(evil, /<img src=x/);
  assert.match(evil, /&lt;img/);
});

test("gr41: siteRollbackRefusalTerminal — the two typed 422s are terminal, everything else retries", () => {
  assert.equal(hooks.siteRollbackRefusalTerminal(422, { error: "not_rollbackable" }), true);
  assert.equal(hooks.siteRollbackRefusalTerminal(422, { error: { code: "no_previous" } }), true);
  assert.equal(hooks.siteRollbackRefusalTerminal(409, { error: "rollback_failed" }), false); // deploy in flight → retry later
  assert.equal(hooks.siteRollbackRefusalTerminal(500, {}), false);
  assert.equal(hooks.siteRollbackRefusalTerminal(0, null), false);
  assert.equal(hooks.siteRollbackRefusalTerminal(422, { error: "wat" }), false); // unknown 422 stays retryable
});

test("siteRollbackResult: deployment_id PRESENT → 'restored' branch (row to mark)", () => {
  const r = hooks.siteRollbackResult({
    ok: true, status: "rolled_back",
    deployment_id: "d7", previous_deployment_id: "d9", url: "https://x/sites/shop/",
  });
  assert.equal(r.kind, "restored");
  assert.equal(r.deploymentId, "d7");
  assert.equal(r.previousDeploymentId, "d9");
  assert.equal(r.url, "https://x/sites/shop/");
  assert.equal(typeof r.at, "number");
});

test("siteRollbackResult: deployment_id NULL → 'previous' branch (no row, previous+url only)", () => {
  const r = hooks.siteRollbackResult({
    ok: true, status: "rolled_back",
    deployment_id: null, previous_deployment_id: "d9", url: "https://x/sites/shop/",
  });
  assert.equal(r.kind, "previous");
  assert.equal(r.deploymentId, null);
  assert.equal(r.previousDeploymentId, "d9");
  assert.equal(r.url, "https://x/sites/shop/");
  // A missing url is honest-null, never the string "undefined".
  assert.equal(hooks.siteRollbackResult({ ok: true, deployment_id: null }).url, null);
});

test("siteRollbackFailure maps every typed refusal to one honest sentence", () => {
  const notRb = hooks.siteRollbackFailure(422, { error: "not_rollbackable" });
  assert.match(notRb.title, /can't be rolled back/);
  assert.match(notRb.body, /rebuilds a fresh image/);
  assert.match(notRb.body, /Roll back to this/);        // points to the promote path
  const noPrev = hooks.siteRollbackFailure(422, { error: "no_previous" });
  assert.match(noPrev.title, /Nothing to roll back to/);
  assert.match(noPrev.body, /only ever had one release/);
  const running = hooks.siteRollbackFailure(409, { error: "rollback_failed" });
  assert.match(running.title, /deploy is already running/);
  assert.match(running.body, /finish, then roll back/);
  // Envelope shape parity: {error:{code}} reads the same as {error:"code"}.
  assert.match(hooks.siteRollbackFailure(422, { error: { code: "no_previous" } }).title, /Nothing to roll back to/);
  // Unknown → a generic, non-throwing sentence.
  assert.match(hooks.siteRollbackFailure(500, {}).title, /Couldn't roll back/);
});

test("siteRollbackFlashView: restored cue applies ONLY while its row is current + inside the TTL", () => {
  const site = { current_deployment_id: "d7" };
  const flash = { kind: "restored", deploymentId: "d7", at: 1000 };
  // Fresh + row still current → shows.
  const v = hooks.siteRollbackFlashView(flash, site, 1000);
  assert.equal(v.kind, "restored");
  assert.equal(v.deploymentId, "d7");
  // A later deploy moved current_deployment_id → the cue is stale → null.
  assert.equal(hooks.siteRollbackFlashView(flash, { current_deployment_id: "d9" }, 1000), null);
  // Past the TTL → null (no perpetual banner).
  assert.equal(hooks.siteRollbackFlashView(flash, site, 1000 + 45001), null);
  // No flash → null.
  assert.equal(hooks.siteRollbackFlashView(null, site, 1000), null);
});

test("siteRollbackFlashView: the 'previous' branch passes through (no row to gate on)", () => {
  const flash = { kind: "previous", previousDeploymentId: "d9", url: "https://x/", at: 1000 };
  const v = hooks.siteRollbackFlashView(flash, { current_deployment_id: "d7" }, 1500);
  assert.equal(v.kind, "previous");
  assert.equal(v.previousDeploymentId, "d9");
  assert.equal(v.url, "https://x/");
  // Still TTL-bounded.
  assert.equal(hooks.siteRollbackFlashView(flash, {}, 1000 + 45001), null);
});

test("deployRollbackBannerHtml: 'previous' → 'Rolled back' pill + previous-release note + escaped url; 'restored' → nothing", () => {
  const html = hooks.deployRollbackBannerHtml({ kind: "previous", url: "https://x/sites/shop/" });
  assert.match(html, /deploys-rollback-pill/);
  assert.match(html, />Rolled back</);
  assert.match(html, /previous release/);
  assert.match(html, /https:\/\/x\/sites\/shop\//);
  // The restored branch has its cue on the row, not a banner.
  assert.equal(hooks.deployRollbackBannerHtml({ kind: "restored", deploymentId: "d7" }), "");
  assert.equal(hooks.deployRollbackBannerHtml(null), "");
  // Hostile url can't inject.
  const evil = hooks.deployRollbackBannerHtml({ kind: "previous", url: '"><img src=x>' });
  assert.doesNotMatch(evil, /<img src=x>/);
});

test("deployRow: 'Now live' marks the current_deployment_id row by ID equality, never by status", () => {
  // Two rows both status:'live' (history rows all read live) — only the id match wins.
  const cur = { id: "d2", status: "live", git_ref: "9c1f2ab", became_live_at: "2026-07-03T10:00:00Z" };
  const other = { id: "d1", status: "live", git_ref: "4e7d0c9", became_live_at: "2026-07-01T10:00:00Z" };
  const curHtml = hooks.deployRow(cur, "d2");
  assert.match(curHtml, /dep-current/);
  assert.match(curHtml, /Now live/);
  assert.doesNotMatch(curHtml, /rolled back/);          // no flash → plain "Now live"
  assert.doesNotMatch(hooks.deployRow(other, "d2"), /dep-current/);
});

test("deployRow: a 'restored' flash on the current row → 'Now live — rolled back' + a 'restored build from' qualifier", () => {
  const cur = { id: "d2", status: "live", git_ref: "9c1f2ab", became_live_at: "2026-07-01T10:00:00Z" };
  const flash = { kind: "restored", deploymentId: "d2" };
  const html = hooks.deployRow(cur, "d2", flash);
  assert.match(html, /dep-current--restored/);
  assert.match(html, /Now live &mdash; rolled back/);
  assert.match(html, /restored build from/);            // the original became_live_at, named as a restore
  // The flash is inert on a NON-current row (only the current row is the restore).
  const priorHtml = hooks.deployRow({ id: "d1", status: "live" }, "d2", flash);
  assert.doesNotMatch(priorHtml, /rolled back/);
});

test("deployRow renders trigger provenance (GR27: Manual / Content update, never a named human); unknowns humanize", () => {
  // Pin UPDATED deliberately (gr-p3-site-detail): the backend trigger vocabulary
  // is exactly manual | content-auto (Registry.Deployment @triggers); the old
  // "GitHub push" mapping re-labelled a value the server can never store.
  assert.match(hooks.deployRow({ id: "d1", status: "live", trigger: "content-auto" }, null), /Content update/);
  assert.match(hooks.deployRow({ id: "d1b", status: "live", trigger: "manual" }, null), /Manual/);
  // An unknown future value passes through humanized, never re-mapped.
  assert.match(hooks.deployRow({ id: "d2", status: "live", trigger: "github_webhook" }, null), /github webhook/);
  // A hostile trigger is escaped.
  const evil = hooks.deployRow({ id: "d3", status: "live", trigger: "<b>x</b>" }, null);
  assert.doesNotMatch(evil, /<b>x<\/b>/);
});

test("deployListHtml: caps to the recent-N with an HONEST footer (no 'full history' claim); flash threads to the current row", () => {
  const many = [];
  for (let i = 0; i < 20; i++) many.push({ id: "d" + i, status: "live" });
  const html = hooks.deployListHtml(many, "d0", { kind: "restored", deploymentId: "d0" });
  // Exactly 12 rows rendered (recent-N), rest omitted.
  assert.equal((html.match(/class="deploy-row"/g) || []).length, 12);
  assert.match(html, /Showing the 12 most recent deployments\./);
  assert.doesNotMatch(html, /full history/i);
  // The flash marker reached the current row.
  assert.match(html, /Now live &mdash; rolled back/);
  // A short list shows no footer.
  assert.doesNotMatch(hooks.deployListHtml([{ id: "d0", status: "live" }], "d0"), /most recent deployments/);
  // Empty stays the honest empty-state.
  assert.match(hooks.deployListHtml([], null), /No deployments yet/);
});

// ── invitation accept: the minted URL shape parses EXACTLY (router accept_url) ─

test("parseInviteToken accepts the minted shape (#/invitations/accept?token=…) and the canonical one", () => {
  assert.equal(hooks.parseInviteToken("#/invitations/accept?token=abc123"), "abc123"); // as minted by accept_url/2
  assert.equal(hooks.parseInviteToken("/invitations/accept?token=abc123"), "abc123");
  assert.equal(hooks.parseInviteToken("#invitations/accept?token=abc123"), "abc123");
  assert.equal(hooks.parseInviteToken("invitations/accept?token=abc123"), "abc123");
});

test("parseInviteToken decodes percent-escapes safely and survives junk", () => {
  assert.equal(hooks.parseInviteToken("#/invitations/accept?token=a%2Bb%20c"), "a+b c");
  assert.equal(hooks.parseInviteToken("#/invitations/accept?token=abc%"), "abc%"); // malformed escape: verbatim, no throw
  assert.equal(hooks.parseInviteToken("#/invitations/accept?foo=1&token=xyz"), "xyz"); // extra params tolerated
  assert.equal(hooks.parseInviteToken("#/invitations/accept?token="), null);
  assert.equal(hooks.parseInviteToken("#/invitations/accept"), null);
  assert.equal(hooks.parseInviteToken("#overview"), null);
  assert.equal(hooks.parseInviteToken(null), null);
});

test("legacyRoute normalizes the minted leading-slash invite hash; parseHash routes it with the token", () => {
  assert.equal(hooks.legacyRoute("/invitations/accept?token=x"), "invitations/accept?token=x");
  assert.equal(hooks.legacyRoute("#/invitations/accept?token=x"), "invitations/accept?token=x");
  sandbox.location.hash = "#/invitations/accept?token=tok-1";
  let r = hooks.parseHash();
  assert.equal(r.view, "invite");
  assert.equal(r.token, "tok-1");
  sandbox.location.hash = "#invitations/accept"; // parked-token resume shape: no token in the URL
  r = hooks.parseHash();
  assert.equal(r.view, "invite");
  assert.equal(r.token, null);
  sandbox.location.hash = ""; // leave the shared sandbox clean for later tests
});

// ── invite state classifiers ─────────────────────────────────────────────────

const INV_NOW = Date.parse("2026-07-04T12:00:00Z");
const INV_FUTURE = "2026-07-10T12:00:00Z";
const INV_PAST = "2026-07-01T12:00:00Z";
const livePreview = { team: { name: "Northwind", slug: "northwind" }, email: "ada@acme.com", role: "admin", expires_at: INV_FUTURE };
const INV_ME = { user: { email: "ada@acme.com" }, team: { name: "Acme Inc", slug: "acme" } };

test("inviteLandingState: 404 → invalid; past expiry → expired; own team → already_member; else confirm", () => {
  assert.equal(hooks.inviteLandingState(404, null, INV_ME, INV_NOW), "invalid");
  assert.equal(hooks.inviteLandingState(200, { ...livePreview, expires_at: INV_PAST }, INV_ME, INV_NOW), "expired");
  assert.equal(hooks.inviteLandingState(200, { ...livePreview, team: { name: "Acme Inc", slug: "acme" } }, INV_ME, INV_NOW), "already_member");
  assert.equal(hooks.inviteLandingState(200, livePreview, INV_ME, INV_NOW), "confirm");
  assert.equal(hooks.inviteLandingState(200, livePreview, null, INV_NOW), "confirm"); // me unavailable → still offer the join
});

test("inviteTerminalFrom: 200→joined, 403→wrong_account, 404 splits expired/invalid by OUR preview, else error", () => {
  assert.equal(hooks.inviteTerminalFrom(200, { team_id: "t" }, livePreview, INV_NOW), "joined");
  assert.equal(hooks.inviteTerminalFrom(403, { error: "email_mismatch" }, livePreview, INV_NOW), "wrong_account");
  // 404 with a preview that expired since landing → honest "expired".
  assert.equal(hooks.inviteTerminalFrom(404, { error: "invalid_or_expired" }, { ...livePreview, expires_at: INV_PAST }, INV_NOW), "expired");
  // 404 with a still-live (or absent) preview → the server folded it: "invalid".
  assert.equal(hooks.inviteTerminalFrom(404, { error: "invalid_or_expired" }, livePreview, INV_NOW), "invalid");
  assert.equal(hooks.inviteTerminalFrom(404, { error: "invalid_or_expired" }, null, INV_NOW), "invalid");
  assert.equal(hooks.inviteTerminalFrom(422, { error: "accept_failed" }, livePreview, INV_NOW), "error");
  assert.equal(hooks.inviteTerminalFrom(0, { error: "network_error" }, livePreview, INV_NOW), "error");
});

// ── invite terminal renders: calm copy, exactly ONE action each ──────────────

test("every invite terminal state renders exactly one next action", () => {
  const ctx = { team: "Northwind", role: "admin", email: "ada@acme.com", meEmail: "someone@else.com" };
  const expectations = {
    joined: [/You&#39;re in/, /data-invite-act="overview"/, /Go to Overview/],
    already_member: [/already a member/, /data-invite-act="overview"/],
    expired: [/has expired/, /data-invite-act="overview"/],
    invalid: [/isn&#39;t valid any more/, /data-invite-act="overview"/],
    wrong_account: [/different email/, /data-invite-act="switch"/, /Switch account/],
    error: [/Something went wrong/, /data-invite-act="retry"/, /Try again/],
  };
  for (const [state, patterns] of Object.entries(expectations)) {
    const html = hooks.inviteStateHtml(state, ctx);
    const actions = (html.match(/data-invite-act=/g) || []).length;
    assert.equal(actions, 1, state + " must render exactly one action, got " + actions);
    for (const p of patterns) assert.match(html, p, state);
  }
});

test("the invite confirm screen offers Join (one action) plus a quiet Not-now escape", () => {
  const html = hooks.inviteStateHtml("confirm", { team: "Northwind", role: "admin", email: "ada@acme.com" });
  assert.equal((html.match(/data-invite-act=/g) || []).length, 1);
  assert.match(html, /data-invite-act="join"/);
  assert.match(html, /Join Northwind/);
  assert.match(html, /as admin/);
  assert.match(html, /ada@acme\.com/);
  assert.match(html, /invite-skip/);
  assert.match(html, /Not now/);
});

test("inviteStateHtml is total over unknown states and escapes hostile team names", () => {
  // Unknown state → the invalid fallback (never a blank screen).
  assert.match(hooks.inviteStateHtml("wat", {}), /isn&#39;t valid any more/);
  assert.match(hooks.inviteStateHtml(null, {}), /isn&#39;t valid any more/);
  const html = hooks.inviteStateHtml("joined", { team: '<script>alert(1)</script>' });
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /&lt;script&gt;/);
  // Missing ctx degrades to calm generic copy, never "undefined".
  assert.doesNotMatch(hooks.inviteStateHtml("joined", {}), /undefined/);
  assert.doesNotMatch(hooks.inviteStateHtml("confirm", {}), /undefined/);
});

// ════════════════════════════════════════════════════════════════════════════
// C8 — instance Timeline tab + golden-path verify chips (D10/D18/D25/D33/D53)
// ════════════════════════════════════════════════════════════════════════════

test("C8: the timeline + verify pure helpers are exported", () => {
  for (const name of ["mergeTimeline", "auditMirrorsEvent", "tlvEntryTitle",
    "tlvRowHtml", "tlvDetailHtml", "timelineFeedHtml", "timelineTabShellHtml",
    "mountTimelineTab", "latestVerifyOf", "probeChipsModel", "verifySummaryText",
    "verifyChipHtml", "verifyCardHtml", "verifyNoteHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  assert.ok(Array.isArray(hooks.verifyProbes));
});

// ── the probe vocabulary is byte-pinned against the shared fixture ──────────
// __fixtures__/verify_probes.json is asserted by the Elixir Verify suite AND
// the Go provision gate; the SPA's chip labels must be the same three probes.

test("C8: verifyProbes (name+label) equals the shared verify_probes.json fixture", () => {
  const fixture = JSON.parse(
    fs.readFileSync(new URL("./__fixtures__/verify_probes.json", import.meta.url), "utf8"),
  );
  // Spread the vm-realm array into the host realm before deepEqual (foreign
  // Array prototype — same trick as the fleetSummary tests above).
  assert.deepEqual(
    [...hooks.verifyProbes].map((p) => ({ name: p.name, label: p.label })),
    fixture.probes.map((p) => ({ name: p.name, label: p.label })),
  );
});

// ── tab codec: #instance/<id>/timeline routes; strip renders the tab ────────

test("C8: parseHash selects the registered Timeline tab", () => {
  sandbox.location.hash = "#instance/9f3c/timeline";
  assert.deepEqual({ ...hooks.parseHash() }, { view: "instance", id: "9f3c", tab: "timeline" });
});

test("C8: the tab strip renders Timeline and marks it active on that tab", () => {
  const html = hooks.instanceTabStripHtml({ id: "abc", name: "Prod" }, "timeline");
  assert.match(html, /href="#instance\/abc\/timeline"[^>]*aria-current="page"/);
  assert.match(html, />Timeline</);
  // Overview + Webhooks still present, not current.
  assert.match(html, /href="#instance\/abc\/overview"/);
  assert.match(html, /href="#instance\/abc\/webhooks"/);
});

test("C8: instanceDetailHtml leaves the Timeline panel blank (filled after mount)", () => {
  const html = hooks.instanceDetailHtml({ id: "abc", name: "Prod", host: "h", url: "u" }, "timeline");
  assert.doesNotMatch(html, /id="instance-sites"/);
  assert.match(html, /id="instance-tabpanel"/);
});

// ── mergeTimeline: ordering / interleaving / dedup / empty (the table test) ──

const EV = (id, type, secs, payload) => ({
  id, type, payload: payload || {}, inserted_at: new Date(Date.UTC(2026, 6, 3, 12, 0, secs)).toISOString(),
});
const AU = (id, action, secs, over) => Object.assign({
  id, action, actor: { id: "u1", email: "ada@acme.com" }, target_type: "barkpark",
  target_id: "bp1", metadata: null, inserted_at: new Date(Date.UTC(2026, 6, 3, 12, 0, secs)).toISOString(),
}, over || {});

test("C8: mergeTimeline interleaves both feeds newest-first", () => {
  const merged = hooks.mergeTimeline(
    [EV(3, "health", 30), EV(1, "status", 10)],       // newest-first, as the API sends
    [AU("a2", "site.created", 20), AU("a1", "token.minted", 5)],
  );
  assert.deepEqual([...merged.map((e) => e.key)], ["e:3", "a:a2", "e:1", "a:a1"]);
  assert.deepEqual([...merged.map((e) => e.source)], ["event", "audit", "event", "audit"]);
});

test("C8: equal timestamps order stably — event before audit, then key (repaint-stable)", () => {
  const events = [EV(2, "health", 10), EV(1, "backup", 10)];
  const audits = [AU("a1", "site.created", 10)];
  const once = hooks.mergeTimeline(events, audits).map((e) => e.key);
  const twice = hooks.mergeTimeline(events, audits).map((e) => e.key);
  assert.deepEqual([...once], ["e:1", "e:2", "a:a1"]); // events first, key-tiebreak deterministic
  assert.deepEqual([...once], [...twice]);
});

test("C8: a verify event rides as source 'verify', other events as 'event'", () => {
  const merged = hooks.mergeTimeline([EV(2, "verify", 20, { ok: true }), EV(1, "health", 10)], []);
  assert.equal(merged[0].source, "verify");
  assert.equal(merged[1].source, "event");
});

test("C8: dedup — an audit row naming the event via metadata.event_id is dropped", () => {
  const merged = hooks.mergeTimeline(
    [EV(7, "status", 10, { transition: "online" })],
    [AU("a1", "barkpark.go_live", 40, { metadata: { event_id: 7 } }),
     AU("a2", "site.created", 20)],
  );
  assert.deepEqual([...merged.map((e) => e.key)], ["a:a2", "e:7"]);
});

test("C8: dedup — same-second + action dot-suffix == event type drops the audit mirror", () => {
  const merged = hooks.mergeTimeline(
    [EV(9, "verify", 10, { ok: true })],
    [AU("a1", "barkpark.verify", 10)],
  );
  assert.deepEqual([...merged.map((e) => e.key)], ["e:9"]);
  // A DIFFERENT second (or a non-matching suffix) keeps both rows.
  assert.equal(hooks.mergeTimeline([EV(9, "verify", 10)], [AU("a1", "barkpark.verify", 11)]).length, 2);
  assert.equal(hooks.mergeTimeline([EV(9, "status", 10)], [AU("a1", "site.created", 10)]).length, 2);
});

test("C8: mergeTimeline is total over junk — empty, null, garbled stamps", () => {
  assert.deepEqual([...hooks.mergeTimeline([], [])], []);
  assert.deepEqual([...hooks.mergeTimeline(null, undefined)], []);
  const merged = hooks.mergeTimeline([EV(1, "health", 10), { id: 2, type: "backup", inserted_at: "garbage" }], []);
  assert.equal(merged.length, 2);
  assert.equal(merged[1].key, "e:2"); // garbled stamp sinks to the bottom, never NaN-throws
});

// ── entry titles + detail rendering ─────────────────────────────────────────

test("C8: tlvEntryTitle — audit reads actor+action, status reads the transition, verify the verdict", () => {
  const m = hooks.mergeTimeline(
    [EV(1, "status", 10, { transition: "offline", reason: "agent_silent" }),
     EV(2, "verify", 20, { ok: false, reachable: true, probes: [
       { name: "verify.api", ok: true, reachable: true, status: 200 },
       { name: "verify.login", ok: true, reachable: true, status: 401 },
       { name: "verify.studio", ok: false, reachable: true, status: 502 },
     ] })],
    [AU("a1", "token.minted", 5)],
  );
  const byKey = Object.fromEntries(m.map((e) => [e.key, hooks.tlvEntryTitle(e)]));
  assert.equal(byKey["a:a1"], "ada@acme.com minted an API token");
  assert.equal(byKey["e:1"], "Status → offline");
  assert.equal(byKey["e:2"], "Verification failed — 1 of 3 checks");
});

test("C8: a verify pass and an unreachable run title honestly", () => {
  const pass = hooks.mergeTimeline([EV(1, "verify", 10, { ok: true, reachable: true, probes: [] })], [])[0];
  assert.equal(hooks.tlvEntryTitle(pass), "Verification passed");
  const unreach = hooks.mergeTimeline([EV(2, "verify", 10, { ok: false, reachable: false, probes: [] })], [])[0];
  assert.equal(hooks.tlvEntryTitle(unreach), "Verification failed — unreachable");
});

test("C8: a degenerate verify payload titles without inventing a cause", () => {
  // No probes array (never produced by Verify.run — version-skew/junk safety):
  // state the failure plainly, never fabricate "unreachable".
  const junk = hooks.mergeTimeline([EV(1, "verify", 10, {})], [])[0];
  assert.equal(hooks.tlvEntryTitle(junk), "Verification failed");
  // ok:true is trusted even without probe detail.
  const okOnly = hooks.mergeTimeline([EV(2, "verify", 10, { ok: true })], [])[0];
  assert.equal(hooks.tlvEntryTitle(okOnly), "Verification passed");
});

test("C8: tlvDetailHtml — verify probes render as readable lines, payloads as escaped JSON", () => {
  const v = hooks.mergeTimeline([EV(1, "verify", 10, { ok: false, probes: [
    { name: "verify.api", ok: true, status: 200, latency_ms: 44, evidence: "GET /v1/capabilities → 200 (API up)" },
    { name: "verify.studio", ok: false, reachable: false, evidence: "connect refused" },
  ] })], [])[0];
  const detail = hooks.tlvDetailHtml(v);
  assert.match(detail, /verify\.api: 200 in 44ms — GET \/v1\/capabilities/);
  assert.match(detail, /verify\.studio: unreachable — connect refused/);
  const h = hooks.mergeTimeline([EV(2, "health", 10, { note: "<img src=x>" })], [])[0];
  assert.match(hooks.tlvDetailHtml(h), /&lt;img src=x&gt;/);
  assert.doesNotMatch(hooks.tlvDetailHtml(h), /<img/);
});

test("C8: tlvRowHtml — badge + expandable detail honouring the expanded flag", () => {
  const e = hooks.mergeTimeline([EV(1, "health", 10, { health: "up" })], [])[0];
  const closed = hooks.tlvRowHtml(e, false);
  assert.match(closed, /tlv-badge tlv-badge--event/);
  assert.match(closed, /data-tlv-toggle aria-expanded="false"/);
  assert.match(closed, /<pre class="tlv-detail" hidden>/);
  const open = hooks.tlvRowHtml(e, true);
  assert.match(open, /aria-expanded="true"/);
  assert.match(open, /<pre class="tlv-detail">/);
  // A payload-less entry gets no dead Details button.
  const bare = hooks.mergeTimeline([EV(2, "tls", 10, {})], [])[0];
  assert.doesNotMatch(hooks.tlvRowHtml(bare, false), /data-tlv-toggle/);
});

test("C8: the verify badge colours by OUTCOME — green pass, red fail (text stays 'verify')", () => {
  const pass = hooks.mergeTimeline([EV(1, "verify", 10, { ok: true, reachable: true, probes: [] })], [])[0];
  assert.match(hooks.tlvRowHtml(pass, false), /tlv-badge tlv-badge--verify"/);
  const fail = hooks.mergeTimeline([EV(2, "verify", 10, { ok: false, reachable: true, probes: [
    { name: "verify.studio", ok: false, reachable: true, status: 502 },
  ] })], [])[0];
  const html = hooks.tlvRowHtml(fail, false);
  assert.match(html, /tlv-badge tlv-badge--verify-fail/);
  assert.match(html, />verify</); // the badge still names the SOURCE
  assert.doesNotMatch(html, /tlv-badge--verify"/); // never the green variant on a failed run
});

// ── timelineFeedHtml: the D18 degradation + teaching empty state ────────────

test("C8: the empty feed teaches, never apologises", () => {
  const html = hooks.timelineFeedHtml([], {});
  assert.match(html, /Events will appear here as this Barkpark works/);
  assert.match(html, /empty-state/);
});

test("C8: an audit 403 degrades to ONE quiet line, not an error state", () => {
  const entries = hooks.mergeTimeline([EV(1, "health", 10)], []);
  const html = hooks.timelineFeedHtml(entries, { quietLine: "Audit entries are visible to team admins." });
  assert.match(html, /tlv-quiet/);
  assert.match(html, /Audit entries are visible to team admins\./);
  assert.doesNotMatch(html, /notice-error/);
  assert.doesNotMatch(html, /Couldn/); // no error copy anywhere
  assert.match(html, /tlv-row/); // the events still render
});

test("C8: expandedKeys re-open exactly the remembered rows across a repaint", () => {
  const entries = hooks.mergeTimeline([EV(1, "health", 10, { a: 1 }), EV(2, "backup", 20, { b: 2 })], []);
  const html = hooks.timelineFeedHtml(entries, { expandedKeys: ["e:2"] });
  const rows = html.split('data-tlv-key="');
  assert.match(rows[1], /^e:2/); // newest first
  assert.match(rows[1], /aria-expanded="true"/);
  assert.match(rows[2], /^e:1/);
  assert.match(rows[2], /aria-expanded="false"/);
});

// ── fake-DOM mount smoke ────────────────────────────────────────────────────

test("C8: mountTimelineTab paints the loading shell synchronously without throwing", () => {
  const root = fakeNode();
  hooks.mountTimelineTab(root, { id: "abc", name: "Prod" });
  assert.match(root.innerHTML, /class="tlv"/);
  assert.match(root.innerHTML, /Loading timeline/);
});

// ── latestVerifyOf + probeChipsModel ────────────────────────────────────────

test("C8: latestVerifyOf finds the newest verify in a newest-first payload", () => {
  const events = [EV(3, "health", 30), EV(2, "verify", 20, { ok: true }), EV(1, "verify", 10, { ok: false })];
  assert.equal(hooks.latestVerifyOf(events).id, 2);
  assert.equal(hooks.latestVerifyOf([EV(1, "health", 10)]), null);
  assert.equal(hooks.latestVerifyOf(null), null);
});

const PASS_ENVELOPE = {
  ok: true, reachable: true, verified_at: new Date(Date.now() - 120000).toISOString(),
  probes: [
    { name: "verify.api", ok: true, reachable: true, status: 200, latency_ms: 44, evidence: "" },
    { name: "verify.login", ok: true, reachable: true, status: 401, latency_ms: 120, evidence: "" },
    { name: "verify.studio", ok: true, reachable: true, status: 200, latency_ms: 310, evidence: "" },
  ],
};

test("C8: probeChipsModel — all-pass maps every fixture probe to a pass chip", () => {
  const m = hooks.probeChipsModel(PASS_ENVELOPE);
  assert.equal(m.ran, true);
  assert.equal(m.ok, true);
  assert.equal(m.reachable, true);
  assert.deepEqual([...m.chips.map((c) => c.role)], ["pass", "pass", "pass"]);
  assert.deepEqual([...m.chips.map((c) => c.label)], ["API answers", "Login responds", "Studio renders"]);
  assert.equal(m.chips[0].status, 200);
  assert.equal(m.chips[0].latencyMs, 44);
});

test("C8: probeChipsModel — one-fail and unreachable are normal results, chips stay three", () => {
  const oneFail = JSON.parse(JSON.stringify(PASS_ENVELOPE));
  oneFail.ok = false;
  oneFail.probes[2] = { name: "verify.studio", ok: false, reachable: true, status: 502, latency_ms: 90, evidence: "502" };
  const m = hooks.probeChipsModel(oneFail);
  assert.deepEqual([...m.chips.map((c) => c.role)], ["pass", "pass", "fail"]);

  const unreach = {
    ok: false, reachable: false, verified_at: PASS_ENVELOPE.verified_at,
    probes: ["verify.api", "verify.login", "verify.studio"].map((n) => (
      { name: n, ok: false, reachable: false, status: null, latency_ms: 5000, evidence: "connect timeout" }
    )),
  };
  const mu = hooks.probeChipsModel(unreach);
  assert.equal(mu.reachable, false);
  assert.equal(mu.chips.length, 3);
  for (const c of mu.chips) {
    assert.equal(c.role, "fail");
    assert.equal(c.unreachable, true);
  }
});

test("C8: probeChipsModel(null) is the never-run state — three unknown chips", () => {
  const m = hooks.probeChipsModel(null);
  assert.equal(m.ran, false);
  assert.equal(m.ok, null);
  assert.equal(m.verifiedAt, null);
  assert.deepEqual([...m.chips.map((c) => c.role)], ["unknown", "unknown", "unknown"]);
});

test("C8: verifySummaryText — pass / fail-count / unreachable / never-run", () => {
  assert.match(hooks.verifySummaryText(hooks.probeChipsModel(PASS_ENVELOPE)), /^All checks passed · checked /);
  const oneFail = JSON.parse(JSON.stringify(PASS_ENVELOPE));
  oneFail.ok = false;
  oneFail.probes[1].ok = false;
  assert.match(hooks.verifySummaryText(hooks.probeChipsModel(oneFail)), /^1 of 3 checks failing/);
  const unreach = { ok: false, reachable: false, probes: [] };
  assert.match(hooks.verifySummaryText(hooks.probeChipsModel(unreach)), /^Unreachable — the box didn't answer/);
  assert.match(hooks.verifySummaryText(hooks.probeChipsModel(null)), /Never checked/);
});

// ── verifyCardHtml: never-run invite, honest verdicts, one Check button ─────

test("C8: the never-run card invites the FIRST check (primary button)", () => {
  const html = hooks.verifyCardHtml(hooks.probeChipsModel(null));
  assert.match(html, /Run first check/);
  assert.match(html, /btn-primary/);
  assert.match(html, /data-vf-run/);
  assert.match(html, /vf-chip vf-chip--unknown/);
  assert.match(html, /Never checked/);
});

test("C8: an all-pass card shows three pass chips + a quiet Check now", () => {
  const html = hooks.verifyCardHtml(hooks.probeChipsModel(PASS_ENVELOPE));
  assert.equal((html.match(/vf-chip vf-chip--pass/g) || []).length, 3);
  assert.match(html, />Check now</);
  assert.doesNotMatch(html, /btn-primary/); // routine re-check is not the loudest thing on the page
  assert.match(html, /All checks passed/);
  assert.match(html, /200 · 44ms/);
});

test("C8: an unreachable result renders honestly — fail chips + 'unreachable', no error scaffolding", () => {
  const unreach = {
    ok: false, reachable: false, verified_at: PASS_ENVELOPE.verified_at,
    probes: ["verify.api", "verify.login", "verify.studio"].map((n) => (
      { name: n, ok: false, reachable: false, status: null, latency_ms: 5000, evidence: "t/o" }
    )),
  };
  const html = hooks.verifyCardHtml(hooks.probeChipsModel(unreach));
  assert.equal((html.match(/vf-chip vf-chip--fail/g) || []).length, 3);
  assert.match(html, /unreachable/);
  assert.doesNotMatch(html, /notice-error/);
  assert.match(html, /data-vf-run/); // re-check stays one click away
});

test("C8: chips carry a label-in-name aria-label (pass/fail/not-checked in words)", () => {
  const pass = hooks.verifyChipHtml({ name: "verify.api", label: "API answers", role: "pass", status: 200, latencyMs: 44 });
  assert.match(pass, /aria-label="API answers — passed"/);
  const fail = hooks.verifyChipHtml({ name: "verify.studio", label: "Studio renders", role: "fail", status: 502, latencyMs: 9 });
  assert.match(fail, /aria-label="Studio renders — failed"/);
  const never = hooks.verifyChipHtml({ name: "verify.login", label: "Login responds", role: "unknown", status: null, latencyMs: null });
  assert.match(never, /aria-label="Login responds — not checked"/);
});

// ── verifyNoteHtml: human copy + EXACTLY ONE recovery action (D25) ──────────

test("C8: 409 not_live — copy + exactly one recovery action (View timeline)", () => {
  const html = hooks.verifyNoteHtml("not_live", { id: "abc" });
  assert.match(html, /Not live yet/);
  assert.match(html, /href="#instance\/abc\/timeline"/);
  const actions = (html.match(/<a |<button /g) || []).length;
  assert.equal(actions, 1, "exactly one recovery action");
});

test("C8: 404 no_admin_token — copy + exactly one recovery action (Re-provision)", () => {
  const html = hooks.verifyNoteHtml("no_admin_token", { id: "abc" });
  assert.match(html, /No stored credentials/);
  assert.match(html, /data-vf-reprovision/);
  const actions = (html.match(/<a |<button /g) || []).length;
  assert.equal(actions, 1, "exactly one recovery action");
  // Unknown codes render nothing (total over junk).
  assert.equal(hooks.verifyNoteHtml("decrypt_failed", { id: "abc" }), "");
});

// ── async WIRING smoke: the real mount → fetch → merge → paint path ─────────
// Drives mountTimelineTab against a stubbed fetch (events 200, audit 403) and
// asserts the painted feed: rows from the events feed, the ONE quiet
// degradation line, and no error scaffolding. This is the path a non-admin
// operator actually hits.

test("C8: mountTimelineTab paints events + the quiet 403 line through the real load path", async () => {
  const tlv = fakeNode();
  const root = fakeNode();
  root.querySelector = (sel) => (sel === ".tlv" ? tlv : null);

  const realFetch = sandbox.fetch;
  sandbox.fetch = (url) => {
    const p = String(url);
    const isEvents = p.indexOf("/events") !== -1;
    const body = isEvents
      ? { events: [
          { id: 2, type: "verify", payload: { ok: true, reachable: true, probes: [] }, inserted_at: "2026-07-03T12:00:20Z" },
          { id: 1, type: "health", payload: { health: "up" }, inserted_at: "2026-07-03T12:00:10Z" },
        ] }
      : { error: "forbidden" };
    return Promise.resolve({
      ok: isEvents,
      status: isEvents ? 200 : 403,
      headers: { get: () => "application/json" },
      json: () => Promise.resolve(body),
    });
  };
  try {
    hooks.mountTimelineTab(root, { id: "bp-smoke", name: "Prod" });
    assert.match(root.innerHTML, /Loading timeline/); // honest synchronous state
    for (let i = 0; i < 10; i++) await Promise.resolve(); // flush the promise chain
    assert.match(tlv.innerHTML, /tlv-quiet/);
    assert.match(tlv.innerHTML, /Audit entries are visible to team admins\./);
    assert.match(tlv.innerHTML, /tlv-badge--verify/);
    assert.match(tlv.innerHTML, /Verification passed/);
    assert.match(tlv.innerHTML, /tlv-badge--event/);
    assert.doesNotMatch(tlv.innerHTML, /Couldn/); // degraded, never an error state
  } finally {
    sandbox.fetch = realFetch;
  }
});

test("C8: a failed EVENTS fetch is the error state with one Retry", async () => {
  const tlv = fakeNode();
  const root = fakeNode();
  root.querySelector = (sel) => (sel === ".tlv" ? tlv : null);

  const realFetch = sandbox.fetch;
  sandbox.fetch = () => Promise.reject(new Error("net down")); // api() → network_error
  try {
    hooks.mountTimelineTab(root, { id: "bp-smoke-2", name: "Prod" });
    for (let i = 0; i < 10; i++) await Promise.resolve();
    assert.match(tlv.innerHTML, /Couldn't load the timeline/);
    assert.match(tlv.innerHTML, /data-tlv-retry/);
    assert.equal((tlv.innerHTML.match(/<button/g) || []).length, 1); // exactly one recovery action
  } finally {
    sandbox.fetch = realFetch;
  }
});

// ── "Log in with Barkpark Cloud" (instance-login deep link) ─────────────────
// The parse/match layer is pure and lives here; the mint round-trip rides the
// server-tested studio-link route and is exercised live.

test("instance-login: hash parses with and without the leading slash", () => {
  assert.equal(
    hooks.studioLoginFromHash("#/instance-login?url=https%3A%2F%2Fguerrilla.barkpark.cloud"),
    "https://guerrilla.barkpark.cloud",
  );
  assert.equal(
    hooks.studioLoginFromHash("#instance-login?url=https%3A%2F%2Fg.example"),
    "https://g.example",
  );
  assert.equal(hooks.studioLoginFromHash("#fleet"), null);
  assert.equal(hooks.studioLoginFromHash(""), null);
  // Trailing params beyond url= are ignored, not swallowed into the origin.
  assert.equal(
    hooks.studioLoginFromHash("#/instance-login?url=https%3A%2F%2Fa.example&x=1"),
    "https://a.example",
  );
});

test("instance-login: a malformed deep link degrades to null, never throws", () => {
  // The URIError white-screen class this harness exists for (see header):
  // safeDecode returns the RAW string on a bad escape; the host parse is the
  // layer that turns that garbage into "no target".
  const garbage = hooks.studioLoginFromHash("#/instance-login?url=%E0%A4%A");
  assert.equal(hooks.studioLoginHost(garbage), null);
  assert.equal(hooks.studioLoginHost("not-a-url"), null);
  assert.equal(hooks.studioLoginHost("javascript:alert(1)"), null);
  assert.equal(hooks.studioLoginHost(null), null);
  assert.equal(hooks.studioLoginHost("https://"), null);
});

test("instance-login: fleet match is host equality, never substring", () => {
  const fleet = [
    { id: "a", url: "https://alpha.barkpark.cloud" },
    { id: "b", url: "https://guerrilla.barkpark.cloud/" },
    { id: "c", url: null },
  ];
  assert.equal(hooks.studioLoginMatch(fleet, "https://guerrilla.barkpark.cloud").id, "b");
  // A lookalike host must NOT match the real one.
  assert.equal(hooks.studioLoginMatch(fleet, "https://evil-guerrilla.barkpark.cloud"), null);
  assert.equal(hooks.studioLoginMatch(fleet, "https://guerrilla.barkpark.cloud.evil.example"), null);
  assert.equal(hooks.studioLoginMatch([], "https://guerrilla.barkpark.cloud"), null);
  assert.equal(hooks.studioLoginMatch(fleet, "garbage"), null);
});

// ══ Rollback endgame — criteria-proof the shipped promote UI ═════════════════
// The promote grammar (promoteActionFor / promoteFailure / confirm copy) shipped
// in 58100d00; these tests PIN its acceptance criteria so a future edit can't
// silently regress "rollback only for prior successes" or "every failure has one
// recovery, never a dead spinner", plus the post-promote reconcile invariant and
// the loadInstanceSites stale-paint guard.

// ── Criterion 1: rollback is offered ONLY for prior successful deploys ───────
test("promoteActionFor: rollback ⇔ a PRIOR live row — never the current one, never a failed one", () => {
  // The current live row is Redeploy, not rollback (you don't roll back to now).
  const cur = { id: "d9", status: "live", environment: "production" };
  assert.equal(hooks.promoteActionFor(cur, "d9").kind, "redeploy");
  // A prior live row (id ≠ current) is the only source of a rollback.
  const prior = { id: "d1", status: "live", environment: "production" };
  const a = hooks.promoteActionFor(prior, "d9");
  assert.equal(a.kind, "rollback");
  assert.equal(a.label, "Roll back to this");
  // A FAILED prior deploy is never rollbackable — there is no proven artifact,
  // even when it is NOT the current pointer. This is the "never a failed one".
  assert.equal(hooks.promoteActionFor({ id: "d2", status: "failed", environment: "production" }, "d9"), null);
  // Every non-terminal-live status yields no action (queued/building/pushing).
  for (const st of ["queued", "building", "pushing", "canceled", "errored", ""]) {
    assert.equal(hooks.promoteActionFor({ id: "dx", status: st, environment: "production" }, "d9"), null, "status=" + st);
  }
  // Id comparison is string-coerced, so a numeric current id still redeploys
  // (never mis-classifies the current row as a rollback source).
  assert.equal(hooks.promoteActionFor({ id: 9, status: "live", environment: "production" }, 9).kind, "redeploy");
  assert.equal(hooks.promoteActionFor({ id: "9", status: "live", environment: "production" }, 9).kind, "redeploy");
});

// ── Criterion 3: every failure family → a human sentence + EXACTLY ONE recovery
test("promoteFailure: every status family maps to a human sentence + exactly one recovery — never a dead spinner", () => {
  // Every family the map DESIGNS for, incl. the generic 5xx and null-body cases.
  const cases = [
    [409, { error: "build_in_progress" }],
    [404, { error: "not_found" }],
    [422, { error: "not_promotable" }],
    [422, { error: "no_build_source" }],
    [0, { error: "network_error" }],
    [500, {}],
    [503, null],
  ];
  for (const [st, data] of cases) {
    const f = hooks.promoteFailure(st, data);
    // A non-empty sentence — never a blank/dead spinner — with whitespace, so
    // it reads as English, not a bare machine token (these branches all carry
    // hand-written copy).
    assert.ok(typeof f.message === "string" && f.message.trim().length > 12, "message@" + st);
    assert.match(f.message, /\s/, "message@" + st + " reads as a sentence");
    // EXACTLY ONE recovery action, drawn from the closed {retry, refresh} set —
    // the modal always offers a live way forward.
    assert.ok(f.recovery === "retry" || f.recovery === "refresh", "recovery@" + st);
    assert.equal(Object.prototype.hasOwnProperty.call(f, "recovery"), true, "has recovery@" + st);
  }
  // Even a garbage/unmapped server error still yields a non-empty message + one
  // recovery: friendly() echoes the server's words, but the guarantee holds —
  // never a dead end, always exactly one way forward.
  for (const [st, data] of [[422, { error: "something_else" }], [418, { error: "teapot" }]]) {
    const f = hooks.promoteFailure(st, data);
    assert.ok(f.message.length > 0, "generic message@" + st);
    assert.ok(f.recovery === "retry" || f.recovery === "refresh", "generic recovery@" + st);
  }
  // The recovery SPLIT is meaningful: transient/unknown failures retry the POST;
  // "the state moved under us" (409/404/422) refreshes the list instead.
  assert.equal(hooks.promoteFailure(0, {}).recovery, "retry");     // network → retry
  assert.equal(hooks.promoteFailure(500, {}).recovery, "retry");   // server 5xx → retry
  assert.equal(hooks.promoteFailure(409, {}).recovery, "refresh"); // conflict → refresh
  assert.equal(hooks.promoteFailure(404, {}).recovery, "refresh"); // gone → refresh
});

// ── Criterion 2: a successful promote reconciles — the Current chip STAYS put ─
test("promoteReconcile: the fresh queued row is prepended but the Current chip stays on the still-live deploy", () => {
  const current = { id: "d-cur", status: "live", environment: "production" };
  const prior = { id: "d-old", status: "live", environment: "production" };
  const list = [current, prior]; // newest-first, as the endpoint returns
  const optimistic = { id: "d-new", status: "queued", environment: "production" };
  const rec = hooks.promoteReconcile(list, optimistic);
  // The queued row is now on top of the list…
  assert.equal(rec.list[0].id, "d-new");
  assert.equal(rec.list.length, 3);
  // …but it is NOT current — the Current chip stays on the still-live deploy
  // (a queued build never serves traffic). This is the criterion: the chip does
  // not jump to the new deployment until it actually goes live.
  assert.equal(rec.currentId, "d-cur");
  assert.notEqual(rec.currentId, optimistic.id);
  // And deployRow paints that truth: the new row gets NO Current chip and NO
  // promote action (queued rows aren't promotable); the live row keeps Current.
  const newRowHtml = hooks.deployRow(optimistic, rec.currentId);
  assert.doesNotMatch(newRowHtml, /dep-current/);
  assert.doesNotMatch(newRowHtml, /dep-promote/);
  const curRowHtml = hooks.deployRow(current, rec.currentId);
  assert.match(curRowHtml, /dep-current/);
});

test("promoteReconcile: dedups a racing SSE tick and migrates Current only once the new row is live", () => {
  const prior = { id: "d-old", status: "live", environment: "production" };
  // The optimistic row arrives while an SSE tick already delivered the same id —
  // reconcile must not double it.
  const already = { id: "d-new", status: "queued", environment: "production" };
  const optimistic = { id: "d-new", status: "queued", environment: "production" };
  const rec = hooks.promoteReconcile([already, prior], optimistic);
  assert.equal(rec.list.filter((d) => d.id === "d-new").length, 1);
  assert.equal(rec.list[0], optimistic); // the fresh copy wins, on top
  assert.equal(rec.currentId, "d-old");  // still on the prior live deploy
  // Once that deployment goes live (a later refetch), Current MIGRATES to it —
  // the chip's whole point. A preview row is never eligible to be current.
  const live = { id: "d-new", status: "live", environment: "production" };
  const migrated = hooks.promoteReconcile([live, prior], null);
  assert.equal(migrated.currentId, "d-new");
  const preview = { id: "d-pre", status: "live", environment: "preview" };
  assert.equal(hooks.promoteReconcile([preview, prior], null).currentId, "d-old");
  // Degenerate inputs never throw (assert fields, not deepEqual — the sandbox
  // returns cross-realm objects whose prototype trips deepStrictEqual).
  const empty = hooks.promoteReconcile(null, null);
  assert.equal(empty.list.length, 0);
  assert.equal(empty.currentId, null);
  assert.equal(hooks.promoteReconcile([], { id: "x", status: "queued" }).list.length, 1);
});

// ── The stale-paint guard: A's late /v1/sites must not paint into B's slot ────
test("staleGuard: drops a superseded response, accepts the current one", () => {
  // reqId lags the current ticket → a newer instance switch won → DROP.
  assert.equal(hooks.staleGuard(1, 2), true);
  assert.equal(hooks.staleGuard(1, 5), true);
  // reqId is the current ticket → this is the freshest load → ACCEPT (not stale).
  assert.equal(hooks.staleGuard(2, 2), false);
  assert.equal(hooks.staleGuard(0, 0), false);
  // A stale reqId that somehow reads higher than current still isn't "current" —
  // strict inequality means only an exact match paints (defensive).
  assert.equal(hooks.staleGuard(3, 2), true);
});

// ── Liveness chip (OC6): topbar SSE health dot, honest reconnect ─────────────
// The chip's dot colour is a PURE function of the existing EventSource signals
// (evtErrored + the last-confirmed-event epoch). We pin the three states at
// their boundaries; the DOM paint + ticker are browser-coupled (exercised live).

test("liveDotState: freshly connected (no event yet) reads live, not stale", () => {
  // A connected stream with no DATA frame yet is healthy — events are sparse
  // invalidations, not a feed, and the 25s heartbeat is an invisible comment.
  assert.equal(hooks.liveDotState(false, null, 1_000_000), "live");
});

test("liveDotState: a recent event reads live", () => {
  const now = 1_000_000;
  assert.equal(hooks.liveDotState(false, now - 1_000, now), "live");
  assert.equal(hooks.liveDotState(false, now - hooks.liveStaleMs + 1, now), "live");
});

test("liveDotState: evtErrored always wins → reconnecting (even with a fresh event)", () => {
  const now = 1_000_000;
  assert.equal(hooks.liveDotState(true, now, now), "reconnecting");
  assert.equal(hooks.liveDotState(true, null, now), "reconnecting");
  assert.equal(hooks.liveDotState(true, now - 10 * hooks.liveStaleMs, now), "reconnecting");
});

test("liveDotState: no event past the threshold reads stale (up, but can't prove currency)", () => {
  const now = 1_000_000;
  assert.equal(hooks.liveDotState(false, now - hooks.liveStaleMs - 1, now), "stale");
  // Exactly AT the threshold is still live — strictly greater flips it.
  assert.equal(hooks.liveDotState(false, now - hooks.liveStaleMs, now), "live");
});

test("liveFreshness: compact relative label, empty until the first event", () => {
  const now = 1_000_000;
  assert.equal(hooks.liveFreshness(null, now), "");
  assert.equal(hooks.liveFreshness(now - 1_000, now), "just now"); // < 5s
  assert.equal(hooks.liveFreshness(now - 12_000, now), "12s ago");
  assert.equal(hooks.liveFreshness(now - 3 * 60_000, now), "3m ago");
  assert.equal(hooks.liveFreshness(now - 2 * 3_600_000, now), "2h ago");
  // A clock skew (event "in the future") never renders a negative age.
  assert.equal(hooks.liveFreshness(now + 5_000, now), "just now");
});

// ── Liveness chip: the FOURTH (terminal) state, cch-w3 ──────────────────────
// The SSE ticket is single-use, so a mint refused with 401/403 means the SESSION
// is gone and the stream is never coming back. Before this state existed the
// chip could only say "reconnecting", which after a terminal 401 was a
// permanent lie in the topbar.

test("liveDotState: a dead stream reads 'dead', outranking every other signal", () => {
  const now = 1_000_000;
  assert.equal(hooks.liveDotState(false, null, now, true), "dead");
  // Dead beats a fresh event, beats errored, beats stale — retrying is a lie in
  // all three, so nothing may downgrade it.
  assert.equal(hooks.liveDotState(false, now, now, true), "dead");
  assert.equal(hooks.liveDotState(true, now, now, true), "dead");
  assert.equal(hooks.liveDotState(false, now - 10 * hooks.liveStaleMs, now, true), "dead");
  // And the fourth arg is genuinely load-bearing: the same inputs without it
  // return the OLD answers, so these assertions cannot pass vacuously.
  assert.equal(hooks.liveDotState(true, now, now, false), "reconnecting");
  assert.equal(hooks.liveDotState(false, now - 10 * hooks.liveStaleMs, now, false), "stale");
});

test("liveDotState: the return set is a CLOSED enum of exactly five states", () => {
  // Without this, JS's permissive arity keeps every 3-arg equality test above
  // green after a new state lands — the suite would report green while asserting
  // nothing about the new behaviour. Pin the SET, not just the members.
  // .join() rather than deepEqual: hooks come from a vm sandbox, so their arrays
  // carry a foreign Array.prototype and strict deepEqual fails on the realm, not
  // the contents.
  // cch-bl added the FIFTH state (refresh_failed: the stream is fine, the last
  // refetch was not) — and this pin is what forced that addition to be declared,
  // copied, aria'd and reachable rather than slipping in behind green arity.
  assert.equal([...hooks.liveDotStates].sort().join("|"),
    "dead|live|reconnecting|refresh_failed|stale");
  const now = 1_000_000;
  const inputs = [];
  for (const dead of [false, true]) {
    for (const errored of [false, true]) {
      for (const last of [null, now, now - 10 * hooks.liveStaleMs]) {
        for (const stale of [false, true]) {
          inputs.push([errored, last, now, dead, stale]);
        }
      }
    }
  }
  const seen = new Set(inputs.map((a) => hooks.liveDotState(...a)));
  for (const s of seen) {
    assert.ok(hooks.liveDotStates.includes(s), `unknown state escaped the enum: ${s}`);
  }
  // Every declared state is REACHABLE — a closed enum that lists a state nothing
  // can produce is its own kind of lie.
  assert.equal([...seen].sort().join("|"), [...hooks.liveDotStates].sort().join("|"));
});

test("liveness chip copy: every state has copy + aria, and unknown never says 'Live'", () => {
  for (const s of hooks.liveDotStates) {
    assert.ok(hooks.LIVE_CHIP_COPY[s], `no copy for ${s}`);
    assert.ok(hooks.LIVE_CHIP_ARIA[s], `no aria for ${s}`);
  }
  assert.equal(hooks.liveChipCopy("dead"), "Not live");
  assert.match(hooks.liveChipAria("dead"), /stopped/);
  // The old `LIVE_CHIP_COPY[state] || "Live"` fallback would have announced a
  // permanently dead stream as "Live". An unmapped state now reads not-live.
  assert.equal(hooks.liveChipCopy("something-new"), "Not live");
  assert.notEqual(hooks.liveChipCopy("something-new"), "Live");
  assert.notEqual(hooks.liveChipAria("something-new"), "Live updates");
  assert.match(hooks.liveChipAria("something-new"), /unavailable/);
});

test("events reopen backoff: starts at the floor, doubles, and is CAPPED", () => {
  // Uncapped, a hard-down control plane (or a revoked session that somehow
  // stayed transient) would spin the mint route forever.
  let d = hooks.nextEventsBackoffMs(0);
  assert.equal(d, hooks.eventsBackoffMinMs);
  const seen = [d];
  for (let i = 0; i < 12; i++) { d = hooks.nextEventsBackoffMs(d); seen.push(d); }
  assert.equal(seen[1], hooks.eventsBackoffMinMs * 2);
  assert.equal(d, hooks.eventsBackoffMaxMs, "saturates at the cap");
  assert.ok(seen.every((x) => x <= hooks.eventsBackoffMaxMs));
  // onopen resets to the floor by zeroing the accumulator.
  assert.equal(hooks.nextEventsBackoffMs(0), hooks.eventsBackoffMinMs);
});

// ── SSE reconnect loop: the client survives a drop INDEFINITELY (cch-w3) ────
// MEASURED (headless Chrome 150 over CDP) and NOT re-litigated here: EventSource
// freezes its URL at construction and replays it byte-identically, and ANY 401
// is TERMINAL — one onerror at readyState 2, zero further requests, forever. So
// under single-use tickets the browser's own retry is a guaranteed 401 and the
// recovery has to be OURS. This drives that loop end-to-end against a stubbed
// fetch + EventSource: what the browser does is a measurement, what OUR code
// does on top of it is a test.
function sseHarness(opts) {
  opts = opts || {};
  const mints = [];
  const opened = [];
  const timers = [];
  let mintN = 0;
  const orig = {
    fetch: sandbox.fetch, EventSource: sandbox.EventSource,
    localStorage: sandbox.localStorage, sessionStorage: sandbox.sessionStorage,
    setTimeout: sandbox.setTimeout, clearTimeout: sandbox.clearTimeout,
  };
  const sess = JSON.stringify({ token: "SESSION-TOKEN-30-DAY", team_id: "t1" });
  sandbox.localStorage = { getItem: (k) => (k === "bpcloud.session" ? sess : null), setItem() {}, removeItem() {} };
  sandbox.sessionStorage = { getItem: () => null, setItem() {}, removeItem() {} };
  sandbox.fetch = (path, init) => {
    mints.push({ path, init });
    const status = opts.mintStatus ? opts.mintStatus(mints.length) : 200;
    const body = status === 200 ? { ticket: "TICKET-" + ++mintN, expires_in: 60 } : { error: "unauthorized" };
    return Promise.resolve({
      ok: status >= 200 && status < 300, status,
      headers: { get: () => "application/json" },
      json: () => Promise.resolve(body),
    });
  };
  sandbox.EventSource = function (url) {
    const es = { url, closed: false, close() { this.closed = true; } };
    opened.push(es);
    return es;
  };
  sandbox.setTimeout = (fn, ms) => { timers.push({ fn, ms }); return timers.length; };
  sandbox.clearTimeout = () => {};
  // Drain the promise queue the mint rides on (fetch → .then → .then).
  const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
  const fireTimer = () => { const t = timers.pop(); assert.ok(t, "a retry was scheduled"); t.fn(); return t.ms; };
  const restore = () => Object.assign(sandbox, orig);
  return { mints, opened, timers, settle, fireTimer, restore, sess };
}

test("SSE: the stream URL carries a single-use ticket — NEVER the session token", async () => {
  const h = sseHarness();
  try {
    hooks.connectEvents();
    await h.settle();

    // The mint went out as a POST with the bearer in an Authorization HEADER.
    assert.equal(h.mints.length, 1);
    assert.equal(h.mints[0].path, "/v1/auth/sse-ticket");
    assert.equal(h.mints[0].init.method, "POST");
    assert.equal(h.mints[0].init.headers.Authorization, "Bearer SESSION-TOKEN-30-DAY");

    // And the URL that gets logged carries the ticket, not the credential.
    assert.equal(h.opened.length, 1);
    assert.equal(h.opened[0].url, "/v1/events?ticket=TICKET-1");
    assert.doesNotMatch(h.opened[0].url, /SESSION-TOKEN-30-DAY/);
    assert.doesNotMatch(h.opened[0].url, /[?&]token=/);
  } finally {
    h.restore();
    hooks.closeEvents();
  }
});

test("SSE: three consecutive recoveries — each drop remints a FRESH ticket and reopens", async () => {
  const h = sseHarness();
  try {
    hooks.connectEvents();
    await h.settle();
    assert.equal(h.opened.length, 1);

    const delays = [];
    for (let i = 1; i <= 3; i++) {
      const es = h.opened[h.opened.length - 1];
      es.onerror();                       // the drop (or the 401'd replay)
      assert.equal(es.closed, true, "the dead stream is explicitly closed");
      delays.push(h.fireTimer());         // backoff elapses
      await h.settle();
      assert.equal(h.opened.length, i + 1, `recovery ${i} reopened the stream`);
      // A FRESH ticket every time — replaying the burnt one is a guaranteed 401.
      assert.equal(h.opened[i].url, "/v1/events?ticket=TICKET-" + (i + 1));
      assert.notEqual(h.opened[i].url, h.opened[i - 1].url);
      assert.doesNotMatch(h.opened[i].url, /SESSION-TOKEN-30-DAY/);
    }
    // Capped exponential: 500 → 1000 → 2000, never unbounded.
    assert.deepEqual(delays, [500, 1000, 2000]);
    assert.equal(h.mints.length, 4);

    // onopen resets the ladder to the floor, so a flaky link doesn't ratchet
    // into an 8s wait forever.
    h.opened[3].onopen();
    h.opened[3].onerror();
    assert.equal(h.fireTimer(), 500);
  } finally {
    h.restore();
    hooks.closeEvents();
  }
});

test("SSE: a 401 on the MINT is terminal — dead chip, no retry, no spin", async () => {
  // The session credential itself is gone. Retrying cannot fix it, so the loop
  // must STOP and the chip must say so rather than promise a reconnect forever.
  const h = sseHarness({ mintStatus: () => 401 });
  try {
    hooks.connectEvents();
    await h.settle();
    assert.equal(h.opened.length, 0, "no stream opened");
    assert.equal(h.timers.length, 0, "and no retry was scheduled — this is terminal");
    assert.equal(h.mints.length, 1, "exactly one mint attempt, not a spin");

    // connectEvents runs on EVERY re-render, so terminal has to survive one:
    // otherwise each navigation fires another known-401 mint, which is a fresh
    // line of exactly the access-log noise this slice exists to remove.
    hooks.connectEvents();
    hooks.connectEvents();
    await h.settle();
    assert.equal(h.mints.length, 1, "a re-render must not re-mint a dead session");

    // A real sign-in still recovers: closeEvents clears the terminal flag.
    hooks.closeEvents();
    hooks.connectEvents();
    await h.settle();
    assert.equal(h.mints.length, 2, "logout → login re-arms the loop");
  } finally {
    h.restore();
    hooks.closeEvents();
  }
});

test("SSE: a transient mint failure is NOT terminal — it backs off and recovers", async () => {
  // 500 / network-down must keep retrying; only 401/403 is terminal. Getting
  // this backwards silently kills live updates on a blip.
  const h = sseHarness({ mintStatus: (n) => (n <= 2 ? 500 : 200) });
  try {
    hooks.connectEvents();
    await h.settle();
    assert.equal(h.opened.length, 0);
    assert.equal(h.fireTimer(), 500);
    await h.settle();
    assert.equal(h.opened.length, 0);
    assert.equal(h.fireTimer(), 1000);
    await h.settle();
    assert.equal(h.opened.length, 1, "recovered once the control plane came back");
    assert.equal(h.opened[0].url, "/v1/events?ticket=TICKET-1");
  } finally {
    h.restore();
    hooks.closeEvents();
  }
});

test("SSE: closeEvents orphans an in-flight mint (no stream after logout)", async () => {
  const h = sseHarness();
  try {
    hooks.connectEvents();
    hooks.closeEvents();     // logout lands while the mint is still in flight
    await h.settle();
    assert.equal(h.opened.length, 0, "a resolved mint must not resurrect the stream");
  } finally {
    h.restore();
    hooks.closeEvents();
  }
});

// ── Liveness chip DOM wiring (fake-DOM smoke) ───────────────────────────────
// The mount/paint is browser-coupled (real topbar exercised live), but a tiny
// fake DOM pins the structural contract: ensureLivenessChip injects one chip
// into .topbar-right, is idempotent, and renderLivenessChip paints a data-state
// + label without throwing. The eval'd functions resolve `document` dynamically
// off the vm global, so swapping sandbox.document drives the REAL code.
function fakeDom() {
  const all = [];
  const cls = () => {
    const s = new Set();
    return { add: (c) => s.add(c), remove: (c) => s.delete(c),
      contains: (c) => s.has(c), toggle: (c) => (s.has(c) ? s.delete(c) : s.add(c)) };
  };
  const findDesc = (el, want) => {
    for (const c of el.children) {
      if ((c._class || "").split(/\s+/).includes(want)) return c;
      const deep = findDesc(c, want);
      if (deep) return deep;
    }
    return null;
  };
  const make = (tag) => {
    const el = {
      tagName: tag, children: [], attrs: {}, _class: "", id: "",
      textContent: "", hidden: false, offsetWidth: 10, classList: cls(),
      setAttribute(k, v) { this.attrs[k] = v; if (k === "id") this.id = v; },
      getAttribute(k) { return this.attrs[k] != null ? this.attrs[k] : null; },
      get className() { return this._class; },
      set className(v) { this._class = v; },
      set innerHTML(html) {
        this.children = [];
        const re = /class="([^"]+)"/g; let m;
        while ((m = re.exec(html))) { const c = make("span"); c._class = m[1]; this.children.push(c); all.push(c); }
      },
      insertBefore(node) { this.children.unshift(node); if (!all.includes(node)) all.push(node); return node; },
      appendChild(node) { this.children.push(node); if (!all.includes(node)) all.push(node); return node; },
      querySelector(sel) { return findDesc(this, sel.replace(/^\./, "")); },
      get firstChild() { return this.children[0] || null; },
    };
    all.push(el);
    return el;
  };
  const topbarRight = make("div"); topbarRight._class = "topbar-right";
  return {
    document: {
      getElementById: (id) => all.find((e) => e.id === id) || null,
      querySelector: (sel) => (sel === ".topbar .topbar-right" ? topbarRight : null),
      createElement: (t) => make(t),
    },
    topbarRight,
  };
}

test("liveness chip: ensureLivenessChip injects one chip into the topbar, idempotently", () => {
  const orig = sandbox.document;
  const { document: doc, topbarRight } = fakeDom();
  sandbox.document = doc;
  try {
    const chip = hooks.ensureLivenessChip();
    assert.ok(chip, "chip is created");
    assert.equal(chip.id, "liveness-chip");
    assert.equal(topbarRight.children.length, 1, "exactly one chip in the topbar");
    assert.equal(topbarRight.children[0], chip);
    // Structural contract: dot + label + ago spans exist.
    assert.ok(chip.querySelector(".live-dot"));
    assert.ok(chip.querySelector(".live-chip-label"));
    assert.ok(chip.querySelector(".live-chip-ago"));
    // Idempotent: a re-login / re-render reuses the SAME node, never a second.
    const again = hooks.ensureLivenessChip();
    assert.equal(again, chip);
    assert.equal(topbarRight.children.length, 1);
  } finally {
    sandbox.document = orig;
  }
});

test("liveness chip: renderLivenessChip paints a data-state + label without throwing", () => {
  const orig = sandbox.document;
  const { document: doc } = fakeDom();
  sandbox.document = doc;
  try {
    const chip = hooks.ensureLivenessChip();
    hooks.renderLivenessChip();
    // Default module state (no error, no event yet) is honest "live".
    assert.equal(chip.getAttribute("data-state"), "live");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Live");
    assert.match(chip.getAttribute("aria-label"), /Live updates/);
    // A missing chip must be a silent no-op (logout tears the shell down).
    sandbox.document = fakeDom().document; // fresh DOM with no chip
    assert.doesNotThrow(() => hooks.renderLivenessChip());
  } finally {
    sandbox.document = orig;
  }
});

test("liveness chip: the terminal state paints 'dead' — never 'Live', never an 'as of'", () => {
  // The stream signals are private closure state, so renderLivenessChip takes an
  // override purely so this contract is assertable at all.
  const orig = sandbox.document;
  const { document: doc } = fakeDom();
  sandbox.document = doc;
  try {
    const chip = hooks.ensureLivenessChip();
    const now = 1_000_000;
    hooks.renderLivenessChip({ evtDead: true, evtErrored: false, lastEventMs: now - 2_000, nowMs: now });
    // data-state is the selector the CSS paints off — app.css must carry a
    // .live-chip[data-state="dead"] rule or this renders a calm neutral grey.
    assert.equal(chip.getAttribute("data-state"), "dead");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Not live");
    assert.notEqual(chip.querySelector(".live-chip-label").textContent, "Live");
    assert.match(chip.getAttribute("aria-label"), /stopped/);
    assert.doesNotMatch(chip.getAttribute("aria-label"), /^Live updates connected/);
    // No "2s ago" reassurance beside a dead dot — the data STOPPED arriving.
    assert.equal(chip.querySelector(".live-chip-ago").textContent, "");
    assert.equal(chip.querySelector(".live-chip-ago").hidden, true);
    assert.doesNotMatch(chip.getAttribute("title"), /last event/);

    // And the override really is driving it: the same recency, not dead, is live.
    hooks.renderLivenessChip({ evtDead: false, evtErrored: false, lastEventMs: now - 2_000, nowMs: now });
    assert.equal(chip.getAttribute("data-state"), "live");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Live");
    // Reconnecting is the RECOVERABLE state and stays distinct from dead.
    hooks.renderLivenessChip({ evtDead: false, evtErrored: true, lastEventMs: now, nowMs: now });
    assert.equal(chip.getAttribute("data-state"), "reconnecting");
    assert.equal(chip.querySelector(".live-chip-label").textContent, "Reconnecting…");
  } finally {
    sandbox.document = orig;
  }
});

test("liveness chip: app.css carries a paint rule for EVERY chip state", () => {
  // D31/D32: a data-state with no author rule is not "unstyled" — it inherits
  // .live-dot { background: var(--dim) } = a calm neutral grey, i.e. the MOST
  // severe state painting quieter than the amber it replaces. And no existing
  // gate can catch it: __css_check E2 extracts CLASS emissions only
  // (/\.className\s*=/, /classList\.(add|remove|toggle)\(/) and is structurally
  // blind to setAttribute("data-state", …); cssom-parity.mjs has zero
  // data-state references. This test IS the fence.
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  for (const s of hooks.liveDotStates) {
    if (s === "live" || s === "stale") {
      // These two already have rules; assert them anyway so the loop is total.
      assert.ok(css.includes(`.live-chip[data-state="${s}"]`), `no paint rule for ${s}`);
      continue;
    }
    assert.ok(css.includes(`.live-chip[data-state="${s}"] .live-dot`),
      `no DOT paint rule for the "${s}" state — it would fall back to var(--dim)`);
  }
  // The terminal state must read as danger, not as another amber "retrying".
  const dead = css.slice(css.indexOf('.live-chip[data-state="dead"]'));
  assert.match(dead.slice(0, 400), /--danger/);
});

test("liveness chip: every state's .live-dot rule DECLARES a background (per-declaration fence)", () => {
  // D41/D66 — closes the KNOWN GRANULARITY LIMIT the sibling fence above declared.
  // That fence proves SELECTOR-PREFIX presence: deleting ONLY app.css:3470
  // (`.live-chip[data-state="stale"] .live-dot { background: … }`) leaves the
  // same-prefix `.live-chip-label` rule on :3471, so the prefix survives and every
  // gate stays green while the state silently loses its dot colour — the one
  // property that carries the severity signal. This probe reads PER DECLARATION:
  // it isolates each state's own `.live-dot {…}` block and asserts the background
  // survives INSIDE it, so a background-only deletion reds too, not just a
  // whole-rule deletion. Not a prefix substring one level down.
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  for (const s of hooks.liveDotStates) {
    // Trailing ` .live-dot {` excludes the `.live-dot.is-ping::after` ping decoy;
    // first indexOf picks the authored rule over the @media duplicate that follows.
    const start = css.indexOf(`.live-chip[data-state="${s}"] .live-dot {`);
    assert.notEqual(start, -1,
      `no .live-dot paint rule for the "${s}" state — its dot colour falls back to var(--dim)`);
    const block = css.slice(start, css.indexOf("}", start));
    assert.match(block, /background\s*:/,
      `the .live-dot rule for the "${s}" state declares no background — the dot colour is gone`);
  }
});

// ── /activate device-login render states (fake-DOM swap) ────────────────────
// bp-login-ux W3 (decision 40). The pre-click skeletons (entry/confirm/gone/
// rate_limited) are smoke-pinned in __preview__/smoke.mjs, but the click-driven
// approved/denied terminals morph #activate-body IN PLACE — smoke's click() is
// inert, so they're DOM-tested here by calling renderActivateResult directly
// against a swapped document (the same swap idiom the liveness-chip tests use).
// A minimal CAPTURING DOM: querySelector caches one element per #id and records
// the raw innerHTML string, so assertions read the literal markup (unlike the
// class-span-parsing fakeDom() above). setInterval is inert in the sandbox, so
// renderActivateRateLimited pins its INITIAL disabled skeleton, never a tick.
function activateDom() {
  const els = new Map();
  const make = (id) => ({
    id: id || "", innerHTML: "", textContent: "", value: "", disabled: false,
    hidden: false, addEventListener() {}, focus() {}, querySelector() { return null; },
  });
  const byId = (id) => {
    if (!els.has(id)) els.set(id, make(id));
    return els.get(id);
  };
  return {
    document: {
      querySelector: (sel) => byId(String(sel).replace(/^#/, "")),
      getElementById: (id) => byId(id),
      createElement: () => make(""),
    },
    body: () => byId("activate-body").innerHTML,
  };
}

function withActivateDom(fn) {
  const orig = sandbox.document;
  const dom = activateDom();
  sandbox.document = dom.document;
  try { return fn(dom); } finally { sandbox.document = orig; }
}

test("the /activate render functions are exported on the test hook", () => {
  for (const name of ["renderActivateEntry", "renderActivateConfirm",
    "renderActivateResult", "renderActivateError", "renderActivateRateLimited"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("renderActivateResult('approved'): the signed-in terminal, distinct from denied", () => {
  withActivateDom((dom) => {
    hooks.renderActivateResult("approved");
    const html = dom.body();
    assert.ok(html.includes("You're signed in"), "announces success");
    assert.ok(html.includes("Approved"), "carries the approved eyebrow");
    assert.ok(html.includes("finishing sign-in"), "tells the user to return to the terminal");
    assert.ok(!html.includes("Request denied"), "must NOT read as the denied terminal");
  });
});

test("renderActivateResult('denied'): the denied terminal, nothing shared", () => {
  withActivateDom((dom) => {
    hooks.renderActivateResult("denied");
    const html = dom.body();
    assert.ok(html.includes("Request denied"), "names the denial");
    assert.ok(html.includes("Nothing was shared"), "reassures nothing leaked");
    assert.ok(!html.includes("You're signed in"), "must NOT read as the approved terminal");
  });
});

test("renderActivateResult('gone'): the expired/used dead-end offers a fresh code", () => {
  withActivateDom((dom) => {
    hooks.renderActivateResult("gone");
    const html = dom.body();
    assert.ok(html.includes("This code has expired or was already used"));
    assert.ok(html.includes("Enter a different code"), "offers a retry with a fresh code");
    assert.ok(html.includes('id="activate-retry"'));
  });
});

test("renderActivateEntry: the manual code-entry form", () => {
  withActivateDom((dom) => {
    hooks.renderActivateEntry("");
    const html = dom.body();
    assert.ok(html.includes('id="activate-form"'));
    assert.ok(html.includes('id="activate-code"'));
    assert.ok(html.includes("Approve a device sign-in"));
    assert.ok(html.includes(">Continue<"));
  });
});

test("renderActivateEntry: a partial prefill is normalized into the field value", () => {
  withActivateDom((dom) => {
    hooks.renderActivateEntry("abcd23");
    const html = dom.body();
    // normalizeUserCode: uppercase, dash after 4, ambiguous chars dropped.
    assert.ok(html.includes('value="ABCD-23"'), "prefill normalized into the input");
  });
});

test("renderActivateConfirm: names the requesting machine + explicit Approve/Deny", () => {
  withActivateDom((dom) => {
    hooks.renderActivateConfirm("ABCD-2345", {
      client_name: "bp on nimbus.local",
      ip_address: "203.0.113.7",
      user_agent: "bp/1.0 (darwin arm64)",
      expires_at: new Date(Date.now() + 9 * 60000).toISOString(),
    });
    const html = dom.body();
    assert.ok(html.includes("Approve this sign-in?"));
    assert.ok(html.includes("bp on nimbus.local"), "names the device");
    // GR81: the IP is SUPPRESSED even when the server sends one. Every inspect
    // body carries the Docker bridge gateway (the control plane is containerized
    // and trust_forwarded_ip only honours X-Forwarded-For from a loopback peer),
    // so the value is identical for every device and cannot answer the only
    // question this screen asks. This assertion is the tripwire on the revert:
    // when gr-bl-peer-ip-container lands a real per-client peer IP, flip it back.
    assert.ok(!html.includes("203.0.113.7"), "the fixture IP is not rendered");
    assert.ok(!html.includes("IP address"), "no IP row even when the server sent one");
    assert.ok(html.includes('id="activate-approve"'));
    assert.ok(html.includes('id="activate-deny"'));
  });
});

test("renderActivateConfirm: a bare inspect body still renders (Unknown device, no empty rows)", () => {
  withActivateDom((dom) => {
    hooks.renderActivateConfirm("ABCD-2345", {});
    const html = dom.body();
    assert.ok(html.includes("Unknown device"), "falls back to a generic device name");
    assert.ok(!html.includes("IP address"), "no IP row when the server sent none");
    assert.ok(!html.includes("Client</span>"), "no user-agent row when the server sent none");
  });
});

test("renderActivateError: the transient failure is retryable, code preserved", () => {
  withActivateDom((dom) => {
    hooks.renderActivateError("ABCD-2345", { error: "internal" });
    const html = dom.body();
    assert.ok(html.includes("Something went wrong"));
    assert.ok(html.includes('id="activate-again"'), "offers a live Try-again");
    assert.ok(html.includes(">Try again<"));
    assert.ok(!html.includes("Too many attempts"), "distinct from the 429 rate-limited state");
  });
});

test("renderActivateRateLimited: the honest 429 pauses retry (disabled countdown)", () => {
  withActivateDom((dom) => {
    hooks.renderActivateRateLimited("ABCD-2345");
    const html = dom.body();
    assert.ok(html.includes("Too many attempts"));
    assert.match(html, /Try again in \d+s/, "the initial paused countdown label");
    assert.ok(html.includes("disabled"), "retry starts disabled through the countdown");
  });
});

// ── S5 four-surface coherence harness (__preview__/coherence.html) ──────────
// The standing sign-off instrument composes Studio + web + paper + TUI on one
// page under ONE light/dark toggle. Its pure logic lives in app.js (theme
// propagation, token-manifest rows, fixture→styled-HTML) so this vm harness can
// pin it; the page mirrors the same block byte-for-byte and a drift test below
// keeps the two copies honest.

import { fileURLToPath } from "node:url";
import path from "node:path";

const COHERENCE_HTML = new URL("./__preview__/coherence.html", import.meta.url);
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const LIFECYCLE_FIXTURE = path.join(REPO_ROOT, "internal/taskboard/testdata/styleguide_lifecycle.txt");
const TOKENS_FIXTURE = path.join(REPO_ROOT, "internal/pdrender/testdata/styleguide_tokens.txt");

test("coherence: the pure helpers are exported on the test hook", () => {
  for (const name of ["coherenceNextTheme", "coherenceStampTheme",
    "coherenceTokenRows", "coherenceFixtureToHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  assert.ok(Array.isArray(hooks.coherenceTokens) && hooks.coherenceTokens.length > 0);
  // The four semantic roles + the evergreen primary are the coherence spine.
  assert.ok(hooks.coherenceTokens.includes("--primary"));
  for (const t of ["--ok", "--warn", "--danger", "--info"]) {
    assert.ok(hooks.coherenceTokens.includes(t), t + " must be in the manifest");
  }
  assert.deepEqual([...hooks.coherenceRoles], ["info", "warn", "ok", "danger"]);
});

test("coherence: nextTheme flips the single light/dark bit both ways", () => {
  assert.equal(hooks.coherenceNextTheme("light"), "dark");
  assert.equal(hooks.coherenceNextTheme("dark"), "light");
  // Anything not "dark" is treated as light → toggling lands on dark.
  assert.equal(hooks.coherenceNextTheme(""), "dark");
  assert.equal(hooks.coherenceNextTheme(undefined), "dark");
});

test("coherence: stampTheme cascades to every root, skips nulls, returns the count", () => {
  const mk = () => {
    const attrs = {};
    return { attrs, setAttribute: (k, v) => { attrs[k] = v; } };
  };
  const a = mk(), b = mk();
  // Null roots (an iframe still loading) are skipped, never thrown on.
  const stamped = hooks.coherenceStampTheme("dark", [a, null, b, undefined]);
  assert.equal(stamped, 2);
  assert.equal(a.attrs["data-theme"], "dark");
  assert.equal(b.attrs["data-theme"], "dark");
  // A dataset-only root (no setAttribute) still gets stamped.
  const ds = { dataset: {} };
  assert.equal(hooks.coherenceStampTheme("light", [ds]), 1);
  assert.equal(ds.dataset.theme, "light");
  // Honest empty state: nothing mounted yet → 0.
  assert.equal(hooks.coherenceStampTheme("dark", []), 0);
  assert.equal(hooks.coherenceStampTheme("dark", null), 0);
});

test("coherence: tokenRows reads live and flags unresolved tokens as gaps", () => {
  // A fake live reader: resolves everything except --border (a missing token).
  const reader = (name) => (name === "--border" ? "  " : "hsl(163 46% 22%)");
  const rows = hooks.coherenceTokenRows(reader);
  assert.equal(rows.length, hooks.coherenceTokens.length);
  const primary = rows.find((r) => r.name === "--primary");
  assert.equal(primary.value, "hsl(163 46% 22%)");
  assert.equal(primary.empty, false);
  // A blank/whitespace resolution reads as a gap, never a fabricated color.
  const border = rows.find((r) => r.name === "--border");
  assert.equal(border.value, "");
  assert.equal(border.empty, true);
  // No reader at all → every row is an honest gap, not a crash.
  const blind = hooks.coherenceTokenRows(null);
  assert.ok(blind.every((r) => r.empty === true));
  // A custom name list is honored. (Field-wise, not deepEqual — the vm sandbox's
  // object prototype is a different realm's, so structural deepEqual won't match.)
  const custom = hooks.coherenceTokenRows(() => "x", ["--ok"]);
  assert.equal(custom.length, 1);
  assert.equal(custom[0].name, "--ok");
  assert.equal(custom[0].value, "x");
  assert.equal(custom[0].empty, false);
});

test("coherence: fixtureToHtml paints role words + hex chips and stays escape-safe", () => {
  const golden = fs.readFileSync(LIFECYCLE_FIXTURE, "utf8");
  const html = hooks.coherenceFixtureToHtml(golden);
  // Emitted lifecycle roles are wrapped in the shared token classes.
  assert.match(html, /<span class="bp-lc-info">info<\/span>/);
  assert.match(html, /<span class="bp-lc-warn">warn<\/span>/);
  assert.match(html, /<span class="bp-lc-ok">ok<\/span>/);
  // Hex swatch cells become color chips carrying the literal value.
  assert.match(html, /<span class="bp-lc-hex" style="--hex:#2563eb">#2563eb<\/span>/);
  // Escaping first: markup in the fixture can never break out of the <pre>.
  const evil = hooks.coherenceFixtureToHtml('<img src=x onerror=alert(1)> & "ok"');
  assert.ok(!evil.includes("<img"));
  assert.match(evil, /&lt;img/);
  assert.match(evil, /&amp;/);
  // "ok" inside the escaped text is still colorized as a role.
  assert.match(evil, /<span class="bp-lc-ok">ok<\/span>/);
  // No false positive: a substring like "workshop" is NOT a role word.
  assert.ok(!hooks.coherenceFixtureToHtml("workshop broker").includes("bp-lc-"));
});

test("coherence: the helper block is byte-identical in app.js and coherence.html", () => {
  const appSrc = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  const pageSrc = fs.readFileSync(COHERENCE_HTML, "utf8");
  const RE = /\/\/ >>> BEGIN coherence-helpers[\s\S]*?\/\/ <<< END coherence-helpers <<</;
  const appBlock = appSrc.match(RE);
  const pageBlock = pageSrc.match(RE);
  assert.ok(appBlock, "app.js must carry the coherence-helpers block");
  assert.ok(pageBlock, "coherence.html must mirror the coherence-helpers block");
  assert.equal(
    pageBlock[0],
    appBlock[0],
    "coherence.html drifted from app.js — re-mirror the block verbatim",
  );
});

test("coherence: the embedded TUI fixtures are byte-identical to the committed goldens", () => {
  const pageSrc = fs.readFileSync(COHERENCE_HTML, "utf8");
  const embed = (id) => {
    const m = pageSrc.match(
      new RegExp('<script type="text/plain" id="' + id + '">([\\s\\S]*?)</script>'),
    );
    assert.ok(m, "coherence.html must embed the " + id + " fixture");
    return m[1];
  };
  assert.equal(
    embed("co-fixture-lifecycle"),
    fs.readFileSync(LIFECYCLE_FIXTURE, "utf8"),
    "lifecycle fixture drifted — re-embed styleguide_lifecycle.txt verbatim",
  );
  assert.equal(
    embed("co-fixture-tokens"),
    fs.readFileSync(TOKENS_FIXTURE, "utf8"),
    "tokens fixture drifted — re-embed styleguide_tokens.txt verbatim",
  );
});

// ── C10: Usage sub-tab + Members settings panel ─────────────────────────────
// Pure helpers only (the DOM mount/fetch wiring is browser-verified). These pin
// the meter vocabulary, the honest freshness/unmetered states, the failure copy,
// and the role-gated manage controls.

const usageSpec = (key) => hooks.usageMeters.find((s) => s.key === key);

test("C10: the Usage + Members helpers are exported", () => {
  for (const name of ["c10FmtBytes", "usageMeterDisplay", "usageMeterHtml",
    "usageMetersHtml", "usageTabShellHtml", "usageFailureCopy",
    "assignableRoles", "membersFailureCopy", "memberRowHtml",
    "invitationRowHtml", "membersPanelHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  // The fixed 13-meter vocabulary, in SPA render order — `instances` leads as the
  // headline quota meter, the machine meters (cpu/ram/req_per_s/p95_ms) group
  // after disk in the host-capacity block, flow meters last (order is
  // surface-local; the fixture tripwire below binds only the name SET, not order).
  assert.deepEqual([...hooks.usageMeters.map((m) => m.key)],
    ["instances", "seats", "documents", "datasets", "webhooks", "db_size", "disk",
      "cpu", "ram", "req_per_s", "p95_ms", "api_requests", "bandwidth"]);
});

// ── the meter vocabulary is name-SET-pinned against the shared fixture ───────
// __fixtures__/usage_meters.json is the three-runtime tripwire: the Go CLI holds
// it name+order+label, the Elixir Usage module names the same meters, and this is
// the SPA leg. The SPA's render order is surface-local (instances leads), so it
// binds only the name SET — a meter added/renamed/removed in one runtime reds the
// others.
test("C10: usageMeters key set equals the shared usage_meters.json fixture", () => {
  const fixture = JSON.parse(
    fs.readFileSync(new URL("./__fixtures__/usage_meters.json", import.meta.url), "utf8"),
  );
  const fixtureNames = fixture.meters.map((m) => m.name).sort();
  const spaKeys = [...hooks.usageMeters.map((m) => m.key)].sort();
  assert.deepEqual(spaKeys, fixtureNames);
});

test("C10: c10FmtBytes humanizes base-1024, echoes non-numbers", () => {
  assert.equal(hooks.c10FmtBytes(0), "0 B");
  assert.equal(hooks.c10FmtBytes(512), "512 B");
  assert.equal(hooks.c10FmtBytes(1024), "1.0 KB");
  assert.equal(hooks.c10FmtBytes(1048576), "1.0 MB");
  // A surprise shape (e.g. the "unmetered" sentinel) is echoed, never crashes.
  assert.equal(hooks.c10FmtBytes("unmetered"), "unmetered");
  assert.equal(hooks.c10FmtBytes(-5), "-5");
});

test("C10: usageMeterDisplay — a real number formats by the meter's fmt", () => {
  const seats = hooks.usageMeterDisplay(usageSpec("seats"), { value: 5, measured_at: null });
  assert.equal(seats.unmetered, false);
  assert.equal(seats.value, "5");
  const db = hooks.usageMeterDisplay(usageSpec("db_size"), { value: 1048576, measured_at: null });
  assert.equal(db.value, "1.0 MB"); // bytes fmt
  const disk = hooks.usageMeterDisplay(usageSpec("disk"), { value: 42.6, measured_at: null });
  assert.equal(disk.value, "43%"); // percent fmt, rounded
});

test("C10: usageMeterDisplay — 'unmetered' renders the designed empty state, never a fake zero", () => {
  const d = hooks.usageMeterDisplay(usageSpec("documents"), { value: "unmetered" });
  assert.equal(d.unmetered, true);
  assert.equal(d.value, "Not yet metered");
  assert.equal(d.freshness, "");
  // A missing meter degrades to the same unmetered state (no throw).
  const missing = hooks.usageMeterDisplay(usageSpec("documents"), undefined);
  assert.equal(missing.unmetered, true);
  assert.equal(missing.value, "Not yet metered");
});

test("C10: usageMeterDisplay — measured_at nil is a LIVE read, present is 'as of'", () => {
  const live = hooks.usageMeterDisplay(usageSpec("documents"), { value: 12, measured_at: null });
  assert.equal(live.freshness, "live"); // nil ≠ error (acceptance criterion 2)
  const ts = "2026-07-08T06:00:00Z";
  const asOf = hooks.usageMeterDisplay(usageSpec("documents"), { value: 12, measured_at: ts });
  assert.equal(asOf.freshness, "as of " + hooks.relTime(ts));
  assert.match(asOf.freshness, /^as of /);
});

test("C10: usageMeterDisplay — seats meter carries pending_invitations, pluralized", () => {
  const two = hooks.usageMeterDisplay(usageSpec("seats"), { value: 3, pending_invitations: 2 });
  assert.equal(two.pending, "2 pending invitations");
  const one = hooks.usageMeterDisplay(usageSpec("seats"), { value: 3, pending_invitations: 1 });
  assert.equal(one.pending, "1 pending invitation"); // singular
  const none = hooks.usageMeterDisplay(usageSpec("seats"), { value: 3, pending_invitations: 0 });
  assert.equal(none.pending, "");
  // pending only rides the seats meter, never another.
  const docs = hooks.usageMeterDisplay(usageSpec("documents"), { value: 3, pending_invitations: 9 });
  assert.equal(docs.pending, "");
});

test("C10: usageMetersHtml renders the full grid; metered vs unmetered chrome differs", () => {
  const empty = hooks.usageMetersHtml({});
  // Every meter label present even with an empty payload — the grid is always full.
  for (const spec of hooks.usageMeters) assert.ok(empty.includes(hooks.esc(spec.label)), spec.label + " missing");
  assert.equal((empty.match(/Not yet metered/g) || []).length, 13);
  const metered = hooks.usageMetersHtml({ documents: { value: 7, measured_at: null } });
  assert.match(metered, /<strong>7<\/strong>/);          // real value is bold
  assert.match(metered, /<span class="dim">Not yet metered<\/span>/); // still-empty meters stay dim
});

// ── OC7 quota bars: the display model draws a bar ONLY for a real ceiling ────
const instSpec = () => usageSpec("instances");

test("C10/OC7: usageMeterDisplay — no bar for an unlimited (quota nil/zero) or unmetered meter", () => {
  // The v1 shape (quota null) is honest: no ceiling, no bar, no fake number.
  assert.equal(hooks.usageMeterDisplay(instSpec(), { value: 3, quota: null }).bar, null);
  assert.equal(hooks.usageMeterDisplay(instSpec(), { value: 3, quota: 0 }).bar, null); // 0 is not a real ceiling
  assert.equal(hooks.usageMeterDisplay(instSpec(), { value: 3 }).bar, null);           // absent quota
  // An unmetered meter never draws a bar even if a quota rides along.
  assert.equal(hooks.usageMeterDisplay(instSpec(), { value: "unmetered", quota: 10 }).bar, null);
});

test("C10/OC7: usageMeterDisplay — ok tone under warn_at, pct rounds", () => {
  const d = hooks.usageMeterDisplay(instSpec(), { value: 3, quota: 10, warn_at: 8 });
  assert.equal(d.bar.tone, "ok");
  assert.equal(d.bar.pct, 30);
  assert.equal(d.bar.quotaText, "3 / 10");
});

test("C10/OC7: usageMeterDisplay — warn tone once value reaches warn_at", () => {
  const d = hooks.usageMeterDisplay(instSpec(), { value: 8, quota: 10, warn_at: 8 });
  assert.equal(d.bar.tone, "warn"); // inclusive at warn_at
  assert.equal(d.bar.pct, 80);
  // No warn_at → never warns; it stays ok right up to the ceiling.
  const noWarn = hooks.usageMeterDisplay(instSpec(), { value: 9, quota: 10 });
  assert.equal(noWarn.bar.tone, "ok");
});

test("C10/OC7: usageMeterDisplay — over tone is inclusive at the ceiling, pct clamps at 100", () => {
  const at = hooks.usageMeterDisplay(instSpec(), { value: 10, quota: 10, warn_at: 8 });
  assert.equal(at.bar.tone, "over"); // value >= quota, inclusive
  assert.equal(at.bar.pct, 100);
  const over = hooks.usageMeterDisplay(instSpec(), { value: 25, quota: 10, warn_at: 8 });
  assert.equal(over.bar.tone, "over");
  assert.equal(over.bar.pct, 100); // clamped, never overflows the track
  assert.equal(over.bar.quotaText, "25 / 10");
});

test("C10/OC7: usageMeterHtml — bar track + toned fill; only OVER carries the one recovery action", () => {
  const ok = hooks.usageMeterHtml(instSpec(), { value: 3, quota: 10, warn_at: 8 });
  assert.match(ok, /class="usage-bar usage-bar--ok"/);
  assert.match(ok, /class="usage-bar-fill" style="width:30%"/);
  assert.ok(!ok.includes("#settings/billing"), "an ok meter needs no recovery action");

  const warn = hooks.usageMeterHtml(instSpec(), { value: 8, quota: 10, warn_at: 8 });
  assert.match(warn, /usage-bar--warn/);
  assert.ok(!warn.includes("#settings/billing"), "warn is not a dead end — no forced action yet");

  const over = hooks.usageMeterHtml(instSpec(), { value: 12, quota: 10, warn_at: 8 });
  assert.match(over, /usage-bar--over/);
  // D25: exactly ONE recovery action, routing to a real Settings billing view.
  assert.match(over, /<a class="usage-bar-action" href="#settings\/billing">Manage plan<\/a>/);
  assert.equal((over.match(/usage-bar-action/g) || []).length, 1);
  // The Settings billing view the link targets must actually be a registered view.
  assert.ok(hooks.settingsViews.includes("billing"), "billing must be a real Settings view (no dead end)");
});

test("C10/OC7: usageMeterHtml — an unlimited meter renders byte-identically to today (bar-less)", () => {
  const unlimited = hooks.usageMeterHtml(instSpec(), { value: 3, quota: null, measured_at: null });
  assert.ok(!unlimited.includes("usage-bar"), "no bar chrome when there is no ceiling");
  assert.match(unlimited, /<strong>3<\/strong>/); // the value renders exactly as a plain metered meter
});

// ── OC23/OC26 machine meters: units + over_at state, bar iff a quota ──────────
const cpuSpec = () => usageSpec("cpu");
const reqSpec = () => usageSpec("req_per_s");
const p95Spec = () => usageSpec("p95_ms");

test("OC26: c10FmtValue — ms + rate units", () => {
  const req = hooks.usageMeterDisplay(reqSpec(), { value: 12.45, measured_at: null });
  assert.equal(req.value, "12.5/s"); // one decimal, trimmed
  const reqWhole = hooks.usageMeterDisplay(reqSpec(), { value: 200, measured_at: null });
  assert.equal(reqWhole.value, "200/s"); // no trailing .0
  const p95 = hooks.usageMeterDisplay(p95Spec(), { value: 143.6, measured_at: null });
  assert.equal(p95.value, "144 ms"); // rounded ms
  const cpu = hooks.usageMeterDisplay(cpuSpec(), { value: 63.4, measured_at: null });
  assert.equal(cpu.value, "63%"); // percent, rounded
});

test("OC25: usageMeterDisplay — cpu reddens at over_at (90) BELOW its 100 bar ceiling", () => {
  // 94% cpu: state over (>= over_at 90) even though the bar isn't full (94 < 100).
  const hot = hooks.usageMeterDisplay(cpuSpec(), { value: 94, quota: 100, warn_at: 70, over_at: 90 });
  assert.equal(hot.state, "over");
  assert.equal(hot.bar.tone, "over");
  assert.equal(hot.bar.pct, 94); // true 0-100 bar, not full
  // 76% cpu: warn band (>= 70, < 90).
  const warm = hooks.usageMeterDisplay(cpuSpec(), { value: 76, quota: 100, warn_at: 70, over_at: 90 });
  assert.equal(warm.state, "warn");
  assert.equal(warm.bar.tone, "warn");
  // 40% cpu: ok — a threshold-bearing meter that has tripped none.
  const cool = hooks.usageMeterDisplay(cpuSpec(), { value: 40, quota: 100, warn_at: 70, over_at: 90 });
  assert.equal(cool.state, "ok");
});

test("OC25: usageMeterDisplay — a rate meter has state + tint but NO bar (quota nil)", () => {
  // req_per_s over its red line (270): state over, but no bar to nowhere.
  const over = hooks.usageMeterDisplay(reqSpec(), { value: 300, warn_at: 210, over_at: 270 });
  assert.equal(over.state, "over");
  assert.equal(over.bar, null); // no quota → no bar
  // Between warn and over → warn.
  const near = hooks.usageMeterDisplay(reqSpec(), { value: 250, warn_at: 210, over_at: 270 });
  assert.equal(near.state, "warn");
  assert.equal(near.bar, null);
  // Under warn → ok.
  assert.equal(hooks.usageMeterDisplay(reqSpec(), { value: 40, warn_at: 210, over_at: 270 }).state, "ok");
});

test("OC25: usageMeterHtml — a bar-less rate meter over its threshold tints the ROW, no Manage-plan", () => {
  const over = hooks.usageMeterHtml(reqSpec(), { value: 300, warn_at: 210, over_at: 270 });
  assert.match(over, /class="usage-card usage-card--over"/); // the card tints
  assert.ok(!over.includes("usage-bar"), "a rate meter draws no bar (no quota ceiling)");
  assert.ok(!over.includes("#settings/billing"), "a capacity meter is not a billing dead-end");
});

test("OC25: usageMeterHtml — an over cpu meter tints red but carries NO Manage-plan link", () => {
  // Only the billing quota meter (instances) routes to Manage plan; a physical
  // meter over its wall is a capacity signal, tinted, with no billing action.
  const cpu = hooks.usageMeterHtml(cpuSpec(), { value: 95, quota: 100, warn_at: 70, over_at: 90 });
  assert.match(cpu, /usage-bar--over/); // the bar reddens
  assert.ok(!cpu.includes("#settings/billing"), "cpu over 90% is not a billing dead-end");
  // The instances billing meter over its ceiling DOES keep the one recovery action.
  const inst = hooks.usageMeterHtml(instSpec(), { value: 12, quota: 10, warn_at: 8 });
  assert.match(inst, /<a class="usage-bar-action" href="#settings\/billing">Manage plan<\/a>/);
});

test("OC25: usageMeterDisplay — an unmetered machine meter never reads a state (no fake alarm)", () => {
  // req_per_s not yet reported: honest unmetered, no state, no bar — never a fake 0.
  const dark = hooks.usageMeterDisplay(reqSpec(), { value: "unmetered", warn_at: 210, over_at: 270 });
  assert.equal(dark.unmetered, true);
  assert.equal(dark.state, null);
  assert.equal(dark.bar, null);
});

// ── Wave 4 (OC19): Usage-tab sparklines — the 14-day history read path ────────
// The pure surface: normalise the /usage/history envelope, extract one meter's
// value|null array (null-is-gap preserved), thread it through the display model
// and markup. The DOM mount (mountUsageTab's parallel fetch + progressive fill)
// is browser-verified; sparklineSvg itself is pinned in the S12 metrics block.

test("W4/OC19: the sparkline history helpers are exported", () => {
  for (const name of ["usageHistorySeries", "usageHistoryValues"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

// Sandbox-realm returns (objects/nested arrays) fail deepStrictEqual on prototype
// identity — JSON round-trip re-creates them in the test realm (see the comment at
// fleetSummary); flat primitive arrays only need a spread.
const rerealm = (x) => JSON.parse(JSON.stringify(x));

test("W4/OC19: usageHistorySeries — top-level `series`, defensive wrapper, garbage → {}", () => {
  const flat = hooks.usageHistorySeries({ ok: true, window_days: 14, series: { documents: [{ at: "t", value: 3 }] } });
  assert.deepEqual(rerealm(flat), { documents: [{ at: "t", value: 3 }] });
  // A defensive `usage_history` wrapper is tolerated (backend key drift never blanks the line).
  const wrapped = hooks.usageHistorySeries({ usage_history: { series: { seats: [{ at: "t", value: 5 }] } } });
  assert.deepEqual(rerealm(wrapped), { seats: [{ at: "t", value: 5 }] });
  // Garbage / missing series → an empty map (the grid then draws bar-less, unchanged).
  assert.deepEqual(rerealm(hooks.usageHistorySeries(null)), {});
  assert.deepEqual(rerealm(hooks.usageHistorySeries({})), {});
  assert.deepEqual(rerealm(hooks.usageHistorySeries({ series: 7 })), {});
});

test("W4/OC19: usageHistoryValues — value|null array, gaps preserved, non-finite → null", () => {
  const series = {
    documents: [{ at: "a", value: 10 }, { at: "b", value: null }, { at: "c", value: 12 }],
    seats: [{ at: "a", value: 4 }, { at: "b" }, { at: "c", value: "unmetered" }],
  };
  assert.deepEqual([...hooks.usageHistoryValues(series, "documents")], [10, null, 12]); // a null is a GAP, never a fake 0
  assert.deepEqual([...hooks.usageHistoryValues(series, "seats")], [4, null, null]);    // missing/non-number → null
  // A meter absent from the series (or a garbage series) → [] (no spark drawn).
  assert.deepEqual([...hooks.usageHistoryValues(series, "disk")], []);
  assert.deepEqual([...hooks.usageHistoryValues(null, "documents")], []);
});

test("W4/OC19: usageMeterDisplay — spark is the value|null array only when numeric history is present", () => {
  const rising = hooks.usageMeterDisplay(usageSpec("documents"), { value: 12, measured_at: null }, [8, null, 10, 12]);
  assert.deepEqual([...rising.spark], [8, null, 10, 12]); // gap survives to sparklineSvg
  // Absent / all-null / empty history → no spark (honest absence, progressive fill).
  assert.equal(hooks.usageMeterDisplay(usageSpec("documents"), { value: 12 }, null).spark, null);
  assert.equal(hooks.usageMeterDisplay(usageSpec("documents"), { value: 12 }, [null, null]).spark, null);
  assert.equal(hooks.usageMeterDisplay(usageSpec("documents"), { value: 12 }, []).spark, null);
  // Two-arg callers (the fleet strip) never get a spark — no regression.
  assert.equal(hooks.usageMeterDisplay(usageSpec("documents"), { value: 12 }).spark, null);
});

test("W4/OC19: usageMeterHtml — spark markup present iff numeric history, absent otherwise", () => {
  const withHist = hooks.usageMeterHtml(usageSpec("documents"), { value: 12, measured_at: null }, [8, 10, 12]);
  assert.match(withHist, /class="usage-spark"/);
  assert.match(withHist, /<svg class="spark"/);
  assert.match(withHist, /<polyline/); // a real run draws a polyline (>1 point)
  // No history → byte-identical to today (no spark chrome at all).
  const bare = hooks.usageMeterHtml(usageSpec("documents"), { value: 12, measured_at: null });
  assert.ok(!bare.includes("usage-spark"), "no spark container without history");
  assert.ok(!bare.includes("<svg"), "no svg without history");
  // All-null history is honest absence, not an empty frame in a container.
  const allNull = hooks.usageMeterHtml(usageSpec("documents"), { value: 12 }, [null, null, null]);
  assert.ok(!allNull.includes("usage-spark"), "all-null series draws no spark");
});

test("W4/OC19: usageMetersHtml — series threads per-meter; a gappy series still renders every meter", () => {
  const meters = { documents: { value: 12, measured_at: null }, seats: { value: 5, measured_at: null } };
  const series = { documents: [{ at: "a", value: 8 }, { at: "b", value: null }, { at: "c", value: 12 }] };
  const grid = hooks.usageMetersHtml(meters, series);
  // documents has history → a spark; seats has none → no spark, but still rendered.
  assert.equal((grid.match(/class="usage-spark"/g) || []).length, 1);
  assert.match(grid, /<strong>5<\/strong>/); // seats still fully present, bar/spark-less
  // No series arg → today's bar-less grid, unchanged (progressive fill before history lands).
  assert.ok(!hooks.usageMetersHtml(meters).includes("usage-spark"), "no sparks until history lands");
});

test("W4/OC19: usageMeterHtml — an over-limit meter carries the danger tint via its card class", () => {
  // The .usage-card--over class (on the stat card) tints the value, the spark
  // (currentColor) and the bar danger — one tone vocabulary, no new colour.
  const over = hooks.usageMeterHtml(instSpec(), { value: 12, quota: 10, warn_at: 8 }, [9, 11, 12]);
  assert.match(over, /class="usage-card usage-card--over"/);
  assert.match(over, /class="usage-spark"/);
});

test("C10: usageFailureCopy — 404 is a distinct honest line, else a retryable one", () => {
  assert.match(hooks.usageFailureCopy(404), /isn't in your team|has been removed/);
  assert.match(hooks.usageFailureCopy(500), /couldn't load usage|Retry/i);
  // The shell is a loading skeleton, not a blank panel.
  assert.match(hooks.usageTabShellHtml(), /Loading usage/);
});

test("C10: assignableRoles — owner assigns all, admin can't grant owner, member none", () => {
  assert.deepEqual([...hooks.assignableRoles("owner")], ["owner", "admin", "member"]);
  assert.deepEqual([...hooks.assignableRoles("admin")], ["admin", "member"]);
  assert.deepEqual([...hooks.assignableRoles("member")], []);
  assert.deepEqual([...hooks.assignableRoles("nonsense")], []);
});

test("C10: membersFailureCopy — network / forbidden / generic each get honest copy", () => {
  assert.match(hooks.membersFailureCopy(0), /Network error/i);
  assert.match(hooks.membersFailureCopy(403), /permission/i);
  assert.match(hooks.membersFailureCopy(500), /couldn't load|Retry/i);
});

test("C10: memberRowHtml — manage controls are role-gated and self-hidden", () => {
  const m = { user_id: "u2", email: "teammate@x.io", role: "member", joined_at: "2026-06-01T00:00:00Z" };
  const admin = hooks.memberRowHtml(m, { role: "admin", userId: "u1" });
  assert.match(admin, /data-member-role="u2"/);   // change role
  assert.match(admin, /data-member-remove="u2"/); // remove
  // A plain member sees no manage controls at all.
  const member = hooks.memberRowHtml(m, { role: "member", userId: "u1" });
  assert.ok(!member.includes("data-member-role"));
  assert.ok(!member.includes("data-member-remove"));
  // You can't demote/remove yourself: self row is tagged "(you)", controls hidden.
  const self = hooks.memberRowHtml(m, { role: "admin", userId: "u2" });
  assert.match(self, /\(you\)/);
  assert.ok(!self.includes("data-member-remove"));
});

test("C10: invitationRowHtml — revoke is manager-gated", () => {
  const inv = { id: "inv9", email: "invitee@x.io", role: "member", expires_at: "2026-07-15T00:00:00Z" };
  const admin = hooks.invitationRowHtml(inv, { role: "admin" });
  assert.match(admin, /data-invite-revoke="inv9"/);
  assert.match(admin, /Pending/);
  const member = hooks.invitationRowHtml(inv, { role: "member" });
  assert.ok(!member.includes("data-invite-revoke"));
});

test("C10: membersPanelHtml — invitations section is manager-only and collapses when empty", () => {
  const members = [{ user_id: "u2", email: "a@x.io", role: "member", joined_at: "2026-06-01T00:00:00Z" }];
  const invitations = [{ id: "inv1", email: "b@x.io", role: "member", expires_at: "2026-07-15T00:00:00Z" }];
  // Manager, empty invitations → heading present, quiet collapse line.
  const emptyInv = hooks.membersPanelHtml(members, [], { role: "admin", userId: "u1" });
  assert.match(emptyInv, /Pending invitations/);
  assert.match(emptyInv, /No pending invitations\./);
  // Manager, with invitations → the invitation row is rendered.
  const withInv = hooks.membersPanelHtml(members, invitations, { role: "admin", userId: "u1" });
  assert.match(withInv, /data-invite-revoke="inv1"/);
  assert.ok(!withInv.includes("No pending invitations"));
  // A plain member never sees the invitations section at all.
  const plain = hooks.membersPanelHtml(members, invitations, { role: "member", userId: "u1" });
  assert.ok(!plain.includes("Pending invitations"));
});

// ── G-06 Members restyle + greenfield env-vars page (Settings wave, phase 4) ──

test("G-06: the members + env-vars helpers are exported", () => {
  for (const name of ["memberInitials", "removeMemberFailureCopy", "inviteFailureCopy",
    "envScopeLabel", "envVarsFailureCopy", "envVarWriteFailureCopy",
    "envVarRowHtml", "envVarsPanelHtml", "envAddFormHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("G-06: memberInitials — first letter of the local part, upper-cased, total", () => {
  assert.equal(hooks.memberInitials("ada@acme.com"), "A");
  assert.equal(hooks.memberInitials("Zed"), "Z");
  assert.equal(hooks.memberInitials(""), "?");
  assert.equal(hooks.memberInitials(null), "?");
});

test("G-06: memberRowHtml — GR33 anatomy with the 3 real role chips, no fiction", () => {
  const owner = { user_id: "u1", email: "ada@acme.com", role: "owner", joined_at: "2026-01-01T00:00:00Z" };
  const html = hooks.memberRowHtml(owner, { role: "admin", userId: "u2" });
  assert.match(html, /set-row/);          // rides the roster anatomy
  assert.match(html, /set-ava/);          // avatar
  assert.match(html, /set-chip">Owner</);  // the role chip is the real label
  // The 5-role design fiction must never render as a team role (GR36/GR14).
  for (const role of ["owner", "admin", "member"]) {
    const chip = hooks.memberRowHtml({ user_id: "x", email: "x@y.io", role }, { role: "owner", userId: "z" });
    assert.ok(!/Operator|Supporter/.test(chip), role + " row must not render an invented tier");
  }
});

test("G-06: removeMemberFailureCopy — last_owner 409 is surfaced honestly", () => {
  assert.match(hooks.removeMemberFailureCopy(409, { error: "last_owner" }), /last owner/i);
  assert.match(hooks.removeMemberFailureCopy(404, {}), /no longer on the team/i);
  assert.equal(typeof hooks.removeMemberFailureCopy(500, {}), "string");
});

test("G-06: inviteFailureCopy — already_member vs already_invited each get true copy", () => {
  assert.match(hooks.inviteFailureCopy({ error: "already_member" }), /already on your team/i);
  assert.match(hooks.inviteFailureCopy({ error: "already_invited" }), /pending invitation/i);
  assert.equal(typeof hooks.inviteFailureCopy({ error: "other" }), "string");
});

test("G-06: envScopeLabel — barkpark scope OR a barkpark_id reads Instance, else Team", () => {
  assert.equal(hooks.envScopeLabel({ scope: "team", barkpark_id: null }), "Team");
  assert.equal(hooks.envScopeLabel({ scope: "barkpark", barkpark_id: "bp1" }), "Instance");
  assert.equal(hooks.envScopeLabel({ scope: "team", barkpark_id: "bp1" }), "Instance"); // id wins
  assert.equal(hooks.envScopeLabel({}), "Team");
});

test("G-06: envVarsFailureCopy + envVarWriteFailureCopy — honest per-status copy", () => {
  assert.match(hooks.envVarsFailureCopy(0), /Network error/i);
  assert.match(hooks.envVarsFailureCopy(422), /isn't part of a team/i);
  assert.match(hooks.envVarsFailureCopy(403), /permission/i);
  // The write-once 409 is the honest per-row truth — delete + recreate.
  assert.match(hooks.envVarWriteFailureCopy(409, { error: "write_once" }), /write-once.*[Dd]elete/i);
  assert.match(hooks.envVarWriteFailureCopy(403, {}), /owners and admins/i);
  assert.match(hooks.envVarWriteFailureCopy(422, { error: "key_required" }), /Enter a key/i);
});

test("G-06: envVarRowHtml — value sealed forever (no reveal), write-once note, canWrite gates Delete", () => {
  const secret = { id: "e1", key: "DATABASE_URL", scope: "team", barkpark_id: null, is_secret: true, is_shown_once: false, comment: "pg" };
  const admin = hooks.envVarRowHtml(secret, true);
  assert.match(admin, /set-row-key">DATABASE_URL/); // mono key visible
  assert.match(admin, /set-chip">Secret</);
  assert.match(admin, /set-chip">Team</);
  assert.match(admin, /data-env-delete="e1"/);       // admin gets Delete
  // The value is NEVER rendered or revealable — no reveal/show affordance at all.
  assert.ok(!/Reveal|Show value|reveal/i.test(admin), "no reveal affordance may exist");
  // A member gets the SAME metadata, zero Delete.
  const member = hooks.envVarRowHtml(secret, false);
  assert.ok(!member.includes("data-env-delete"), "a member row carries no Delete");
  // A write-once row states it can't be changed in place (a POST would 409).
  const once = hooks.envVarRowHtml({ id: "e2", key: "STRIPE", scope: "team", is_secret: true, is_shown_once: true }, true);
  assert.match(once, /set-chip">Write-once</);
  assert.match(once, /Delete and recreate to change/i);
});

test("G-06: envVarsPanelHtml — admin gets the add FORM + save-row; a member is read-only", () => {
  const vars = [{ id: "e1", key: "K", scope: "team", is_secret: true, is_shown_once: false }];
  const admin = hooks.envVarsPanelHtml(vars, { role: "admin" });
  assert.match(admin, /Add a variable/);
  assert.match(admin, /set-save-row/);
  assert.match(admin, /data-env-delete="e1"/);
  // Member-read / admin-write: E-03's any-member-write does NOT transfer here.
  const member = hooks.envVarsPanelHtml(vars, { role: "member" });
  assert.ok(!member.includes("Add a variable"), "a member sees no add form");
  assert.ok(!member.includes("set-save-row"), "a member sees no save-row");
  assert.ok(!member.includes("data-env-delete"), "a member sees no Delete");
  // The empty-state copy invites an admin, stays quiet for a member.
  assert.match(hooks.envVarsPanelHtml([], { role: "admin" }), /Add one below/);
  assert.ok(!hooks.envVarsPanelHtml([], { role: "member" }).includes("Add one below"));
});

test("G-06: envAddFormHtml — write-only (never a value read-back affordance)", () => {
  const html = hooks.envAddFormHtml();
  assert.match(html, /id="env-key"/);
  assert.match(html, /id="env-value"/);
  assert.match(html, /id="env-once"/);   // the write-once toggle
  assert.match(html, /set-save-row/);
  assert.ok(!/Reveal|Show value/i.test(html), "the add form never offers a value read-back");
});

// ════════════════════════════════════════════════════════════════════════════
// S7 — Azure card + verified connect + priced provider-neutral launch catalog
// (epic azure-hetzner hosting parity). The pure seam; the DOM mount is live.
// ════════════════════════════════════════════════════════════════════════════

const catalogFixture = JSON.parse(
  fs.readFileSync(new URL("./__fixtures__/provider_catalog.json", import.meta.url), "utf8"),
);

// Helpers cross the node:vm boundary, so their objects/arrays carry the
// sandbox's Object/Array prototype — strict deepEqual rejects that even when the
// structure matches. Round-trip through JSON to compare by structure only.
const plain = (v) => JSON.parse(JSON.stringify(v));

test("S7: every new pure helper is exported through the hook", () => {
  for (const name of ["providerChipHtml", "instanceLifecycleClass", "azureFieldsValid",
    "providerCredBody", "remediationCopy", "friendly", "formatMonthlyPrice", "catalogViewState",
    "serverTypeLabel", "defaultCatalogSelection", "launchBody", "launchProviderTabsHtml",
    "catalogRegionsHtml", "catalogSizeRowsHtml", "catalogPanelHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  // Azure is a first-class launchable provider now.
  assert.deepEqual(plain(hooks.availableProviderKinds), ["hetzner", "azure"]);
  assert.deepEqual(plain(hooks.azureFieldKeys), ["tenant_id", "client_id", "client_secret", "subscription_id"]);
});

// ── providerChipHtml: identity only, never fabricated ───────────────────────
test("S7: providerChipHtml renders a tinted chip for known kinds, '' otherwise", () => {
  assert.match(hooks.providerChipHtml("hetzner"), /provider-chip--hetzner/);
  assert.match(hooks.providerChipHtml("hetzner"), /Hetzner/);
  assert.match(hooks.providerChipHtml("azure"), /provider-chip--azure/);
  // Absent / unknown provider → NO chip: a fleet row never fakes an identity.
  assert.equal(hooks.providerChipHtml(undefined), "");
  assert.equal(hooks.providerChipHtml(null), "");
  assert.equal(hooks.providerChipHtml("gcp"), "");
  assert.equal(hooks.providerChipHtml(""), "");
});

// ── instanceLifecycleClass: the seven canonical states, '' for the rest ─────
test("S7: instanceLifecycleClass maps the 7 states and degrades unknown to ''", () => {
  for (const s of ["provisioning", "live", "degraded", "stopped", "archived", "decommissioned", "adopted"]) {
    assert.equal(hooks.instanceLifecycleClass(s), "bp-inst--" + s);
  }
  assert.equal(hooks.instanceLifecycleClass("exploded"), "");
  assert.equal(hooks.instanceLifecycleClass(null), "");
});

// ── azureFieldsValid: all four service-principal fields required ────────────
test("S7: azureFieldsValid requires all four non-empty fields", () => {
  const full = { tenant_id: "t", client_id: "c", client_secret: "s", subscription_id: "sub" };
  assert.equal(hooks.azureFieldsValid(full), true);
  // Whitespace-only is empty.
  assert.equal(hooks.azureFieldsValid({ ...full, client_secret: "   " }), false);
  // Any missing field fails.
  assert.equal(hooks.azureFieldsValid({ tenant_id: "t", client_id: "c", client_secret: "s" }), false);
  assert.equal(hooks.azureFieldsValid({}), false);
  assert.equal(hooks.azureFieldsValid(null), false);
});

// ── providerCredBody: the exact per-kind POST shape (router.ex:5572-5583) ────
test("S7: providerCredBody builds {kind,token} for hetzner and {kind,credentials} for azure", () => {
  assert.deepEqual(
    plain(hooks.providerCredBody("hetzner", { token: "  abc  " }, "  main  ")),
    { kind: "hetzner", token: "abc", label: "main" },
  );
  // No label → no label key.
  assert.deepEqual(plain(hooks.providerCredBody("hetzner", { token: "abc" }, "")), { kind: "hetzner", token: "abc" });
  const az = plain(hooks.providerCredBody("azure", {
    tenant_id: " t ", client_id: "c", client_secret: "s", subscription_id: "sub", stray: "DROP ME",
  }, "prod"));
  assert.deepEqual(az, {
    kind: "azure",
    credentials: { tenant_id: "t", client_id: "c", client_secret: "s", subscription_id: "sub" },
    label: "prod",
  });
  // Stray keys never reach the credentials blob.
  assert.ok(!("stray" in az.credentials));
});

// ── remediationCopy is the ONLY path for server remediation; friendly drops it ─
test("S7: remediationCopy extracts server copy that friendly() provably drops", () => {
  const data = { error: "provider_unverified", remediation: "Fix it in the Azure Portal." };
  assert.equal(hooks.remediationCopy(data), "Fix it in the Azure Portal.");
  // friendly() reads only .error/.details — it MUST NOT surface the remediation.
  const f = hooks.friendly(data, "fallback");
  assert.ok(!f.includes("Azure Portal"), "friendly must not leak the server remediation");
  // No remediation → null (caller falls back to friendly()).
  assert.equal(hooks.remediationCopy({ error: "invalid" }), null);
  assert.equal(hooks.remediationCopy({ remediation: "   " }), null);
  assert.equal(hooks.remediationCopy(null), null);
});

// ── formatMonthlyPrice: real price both clouds, honest nil, azure framing ───
test("S7: formatMonthlyPrice renders the catalog's currency, azure 'from ~' framing, honest nil", () => {
  // The payload's currency wins (Decision 15: EUR hetzner / USD azure) — a EUR
  // price is never dressed as dollars.
  assert.equal(hooks.formatMonthlyPrice(3.79, "hetzner", "EUR"), "€3.79/mo");
  assert.equal(hooks.formatMonthlyPrice(70.08, "azure", "USD"), "from ~$70/mo compute");
  assert.equal(hooks.formatMonthlyPrice(4, "hetzner", "EUR"), "€4/mo");
  // Absent currency (a pre-currency server) defaults to "$".
  assert.equal(hooks.formatMonthlyPrice(3.79, "hetzner"), "$3.79/mo");
  // A nil/absent/negative price is NEVER a fabricated $0.
  assert.equal(hooks.formatMonthlyPrice(null, "azure", "USD"), "Price unavailable");
  assert.equal(hooks.formatMonthlyPrice(undefined, "hetzner", "EUR"), "Price unavailable");
  assert.equal(hooks.formatMonthlyPrice(-1, "hetzner", "EUR"), "Price unavailable");
});

// ── catalogViewState: honest states from the api() response ─────────────────
test("S7: catalogViewState maps 200/404-no_provider/502/other to render states", () => {
  assert.deepEqual(
    hooks.catalogViewState({ status: 200, data: catalogFixture.hetzner }).state,
    "ready",
  );
  assert.equal(hooks.catalogViewState({ status: 404, data: { error: "no_provider" } }).state, "no_provider");
  assert.equal(hooks.catalogViewState({ status: 404, data: { error: "unknown_kind" } }).state, "unknown");
  assert.equal(hooks.catalogViewState({ status: 502, data: { error: "catalog_unavailable" } }).state, "unavailable");
  assert.equal(hooks.catalogViewState({ status: 500, data: {} }).state, "error");
  assert.equal(hooks.catalogViewState(null).state, "error");
});

// ── serverTypeLabel: honest partial spec line ───────────────────────────────
test("S7: serverTypeLabel joins present dimensions and drops missing ones", () => {
  assert.equal(hooks.serverTypeLabel({ cores: 2, ram_gb: 8, disk_gb: 16 }), "2 vCPU · 8 GB RAM · 16 GB SSD");
  assert.equal(hooks.serverTypeLabel({ cores: 1, ram_gb: null, disk_gb: 20 }), "1 vCPU · 20 GB SSD");
  assert.equal(hooks.serverTypeLabel({}), "");
});

// ── defaultCatalogSelection: first region + cheapest priced size ────────────
test("S7: defaultCatalogSelection picks first region + cheapest priced size", () => {
  // Hetzner: cheapest is cx11 at 3.79.
  assert.deepEqual(plain(hooks.defaultCatalogSelection(catalogFixture.hetzner)), { region: "fsn1", server_type: "cx11" });
  // Azure: the only priced size wins over the nil-priced one.
  assert.deepEqual(plain(hooks.defaultCatalogSelection(catalogFixture.azure)), { region: "eastus", server_type: "Standard_D2ps_v5" });
  // No priced sizes → first type; empty catalog → null slugs (empty state).
  assert.deepEqual(
    plain(hooks.defaultCatalogSelection({ regions: [{ slug: "x", name: "X" }], server_types: [{ slug: "s1" }, { slug: "s2" }] })),
    { region: "x", server_type: "s1" },
  );
  assert.deepEqual(plain(hooks.defaultCatalogSelection({ regions: [], server_types: [] })), { region: null, server_type: null });
});

// ── launchBody: name always; provider/region/size only when selected ────────
test("S7: launchBody sends name-only when nothing selected, full body when it is", () => {
  assert.deepEqual(plain(hooks.launchBody("Prod")), { name: "Prod" });
  assert.deepEqual(plain(hooks.launchBody("Prod", null, null, null)), { name: "Prod" });
  assert.deepEqual(
    plain(hooks.launchBody("Prod", "azure", "eastus", "Standard_D2ps_v5")),
    { name: "Prod", provider: "azure", region: "eastus", server_type: "Standard_D2ps_v5" },
  );
});

// ── catalog markup builders: prices + honest states surface in the HTML ─────
test("S7: catalogPanelHtml renders the priced ready state for both clouds", () => {
  const hz = hooks.catalogPanelHtml(
    { state: "ready", catalog: catalogFixture.hetzner }, "hetzner",
    { region: "fsn1", server_type: "cx11" }, "grp-h",
  );
  assert.match(hz, /Falkenstein/);
  // Hetzner prices are EUR (the fixture's currency) — never dressed as dollars.
  assert.match(hz, /€3\.79\/mo/);
  assert.ok(!hz.includes("$3.79"), "a EUR price must not render with a $ symbol");
  assert.match(hz, /value="cx11" checked/);
  const az = hooks.catalogPanelHtml(
    { state: "ready", catalog: catalogFixture.azure }, "azure",
    { region: "eastus", server_type: "Standard_D2ps_v5" }, "grp-a",
  );
  assert.match(az, /from ~\$70\/mo compute/);
  // The nil-priced azure size shows the honest unavailable state, never $0.
  assert.match(az, /Price unavailable/);
  assert.ok(!az.includes("$0"));
});

test("S7: catalogPanelHtml renders honest non-ready states with an action", () => {
  const noProv = hooks.catalogPanelHtml({ state: "no_provider" }, "azure", null, "g");
  assert.match(noProv, /Connect Microsoft Azure/);
  assert.match(noProv, /launch-connect-provider/);
  // Azure is BYO-only (Decision 17): a launch without a connected row 422s at
  // the button, so the azure panel must NOT promise a managed fallback…
  assert.ok(!noProv.includes("fully-managed"), "azure no_provider copy must not promise a managed launch");
  // …while managed Hetzner (platform account) honestly may.
  const noProvHz = hooks.catalogPanelHtml({ state: "no_provider" }, "hetzner", null, "g");
  assert.match(noProvHz, /fully-managed/);
  const unavail = hooks.catalogPanelHtml({ state: "unavailable" }, "hetzner", null, "g");
  assert.match(unavail, /unavailable/);
  const err = hooks.catalogPanelHtml({ state: "error" }, "hetzner", null, "g");
  assert.match(err, /launch-catalog-retry/);
});

test("S7: launchProviderTabsHtml marks exactly the active provider pressed", () => {
  const tabs = hooks.launchProviderTabsHtml("azure");
  assert.match(tabs, /data-kind="azure" aria-pressed="true"/);
  assert.match(tabs, /data-kind="hetzner" aria-pressed="false"/);
});

// ════════════════════════════════════════════════════════════════════════════
// S11b — console lifecycle action row (conduit-driven; azure-hetzner hosting)
// ════════════════════════════════════════════════════════════════════════════
//
// The POST-S9 capability-facet payload the /v1/providers/capabilities conduit
// serves:  { providers: { <kind>: { tier?, capabilities:{…}, gaps:{…} } } }
// — note NO default_gap: gr-p4 removed the dead client-side fallback, so a false
// verb shows the SERVER-OWNED per-verb gap when one exists and NO reason at all
// otherwise. Never invented, never a generic filler.
//
// GR71: this is DERIVED from the committed cross-surface fixture, not
// hand-copied. That fixture is byte-gated against internal/cli/cloud/
// providers_capabilities.json (cloud/test/barkpark_cloud/
// providers_capabilities_contract_test.exs), so it is the one place the truth
// about which verbs a provider supports lives. The hand-copy it replaces had
// ALREADY drifted from it in two places (azure catalog and azure audit both
// claimed the opposite of the shipped fixture) — exactly the class of quiet lie
// a fixture exists to prevent.
//
// The fixture is FLAT (kind → tier? + verb booleans); the conduit serves the
// FACET shape, so we lift it here. `gaps` is SERVER-authored copy the fixture
// does not carry, so it stays an explicit, visible overlay.
const CAP_FIXTURE = JSON.parse(
  fs.readFileSync(new URL("./__fixtures__/providers_capabilities.json", import.meta.url), "utf8"),
);
const CAP_GAPS = {
  hetzner: { pause: "Hetzner has no pause primitive." },
  azure: { adopt: "Adopt needs an existing resource-group import." },
};
const CAP_PAYLOAD = {
  providers: Object.fromEntries(
    Object.entries(CAP_FIXTURE).map(([kind, row]) => {
      const { tier, ...capabilities } = row;
      const entry = { capabilities, gaps: CAP_GAPS[kind] || {} };
      if (tier) entry.tier = tier; // `fake` is dev-tier → the console filters it
      return [kind, entry];
    }),
  ),
};

test("GR71: the capability payload carries NO default_gap — the console never pads a reason", () => {
  assert.equal(Object.prototype.hasOwnProperty.call(CAP_PAYLOAD, "default_gap"), false,
    "the conduit emits no top-level default_gap");
  assert.ok(!JSON.stringify(CAP_PAYLOAD).includes("default_gap"),
    "…and none nested inside a provider entry either");
  assert.ok(!JSON.stringify(CAP_FIXTURE).includes("default_gap"),
    "the committed cross-surface fixture invents no default either");
  // So a false verb with no per-verb gap renders an EMPTY reason, not filler.
  const m = hooks.lifecycleActionsModel(
    { providers: { hetzner: { capabilities: { pause: false }, gaps: {} } } },
    { provider: "hetzner", host: "h", name: "web" },
  );
  assert.equal(plain(m.actions).find((a) => a.verb === "pause").reason, "");
});

test("GR71: CAP_PAYLOAD is derived, not copied — every provider row matches the fixture verbatim", () => {
  for (const [kind, row] of Object.entries(CAP_FIXTURE)) {
    const { tier, ...caps } = row;
    assert.deepEqual(plain(CAP_PAYLOAD.providers[kind].capabilities), caps,
      kind + " capabilities must come straight off the fixture");
    assert.equal(CAP_PAYLOAD.providers[kind].tier, tier, kind + " tier must come off the fixture");
  }
});

test("S11b: every new lifecycle-console pure helper is exported", () => {
  for (const name of ["lifecyclePillState", "lifecyclePill", "fleetInfraLine",
    "showLifecycleRow", "lifecycleActionsModel", "lifecycleActionRowHtml", "lifecycleOptimistic"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  // The verb set the row surfaces (destructive last).
  assert.deepEqual([...hooks.lifecycleVerbs].sort(),
    ["adopt", "archive", "audit", "decommission", "pause", "resurrect"]);
});

// ── lifecyclePillState: client-derived states → the seven S4 token states ────
test("S11b: lifecyclePillState folds each client state onto a canonical S4 state", () => {
  assert.equal(hooks.lifecyclePillState({ host: "h" }), "live");
  assert.equal(hooks.lifecyclePillState({}), "provisioning"); // no host, not failed
  assert.equal(hooks.lifecyclePillState({ provision_status: "failed" }), "degraded");
  assert.equal(hooks.lifecyclePillState({ deprovision_status: "failed", host: "h" }), "degraded");
  assert.equal(hooks.lifecyclePillState({ host: "h", suspended: true }), "stopped");
  assert.equal(hooks.lifecyclePillState({ deprovision_status: "pending", host: "h" }), "decommissioned");
  // The pill descriptor threads the label + the S4 class.
  const p = hooks.lifecyclePill({ host: "h" });
  assert.equal(p.state, "live");
  assert.equal(p.label, "Live");
  assert.equal(p.cls, "bp-inst--live");
});

// ── fleetInfraLine: region · size, blank-tolerant (pre-S6 rows) ─────────────
test("S11b: fleetInfraLine renders present dimensions and stays empty when absent", () => {
  assert.equal(hooks.fleetInfraLine({}), ""); // old row: no region/server_type → nothing
  assert.equal(hooks.fleetInfraLine({ region: null, server_type: null }), "");
  assert.match(hooks.fleetInfraLine({ region: "nbg1" }), /nbg1/);
  assert.ok(hooks.fleetInfraLine({ region: "nbg1" }).indexOf("·") === -1); // no dangling separator
  const both = hooks.fleetInfraLine({ region: "nbg1", server_type: "cax11" });
  assert.match(both, /nbg1 · cax11/);
});

// ── showLifecycleRow: the row appears where teardown makes sense ────────────
test("S11b: showLifecycleRow gates on host|failed, hides the transient states", () => {
  assert.equal(hooks.showLifecycleRow({ host: "h" }), true); // live
  assert.equal(hooks.showLifecycleRow({ host: "h", suspended: true }), true); // stopped
  assert.equal(hooks.showLifecycleRow({ provision_status: "failed" }), true); // failed → teardown the wreckage
  assert.equal(hooks.showLifecycleRow({}), false); // clean provisioning → timeline owns it
  assert.equal(hooks.showLifecycleRow({ deprovision_status: "pending", host: "h" }), false); // removing
  assert.equal(hooks.showLifecycleRow({ deprovision_status: "failed", host: "h" }), false); // header's Retry removal
});

// ── lifecycleActionsModel: loading shell — decommission live from frame 1 ────
test("S11b: undefined payload → loading shell with decommission still live", () => {
  const m = hooks.lifecycleActionsModel(undefined, { provider: "hetzner", host: "h", name: "web" });
  assert.equal(m.loading, true);
  assert.equal(m.available, false);
  assert.equal(m.retry, false); // nothing to retry — the fetch is still in flight
  assert.equal(m.actions.length, 1);
  assert.equal(m.actions[0].verb, "decommission");
  assert.equal(m.actions[0].mode, "live");
  assert.equal(m.actions[0].resourceName, "web");
});

// ── lifecycleActionsModel: payload unavailable → one honest state + Retry ───
test("S11b: null/404 payload → 'capabilities unavailable' + Retry, decommission live", () => {
  const m = hooks.lifecycleActionsModel(null, { provider: "hetzner", host: "h", name: "web" });
  assert.equal(m.available, false);
  assert.equal(m.loading, false);
  assert.equal(m.retry, true);
  assert.equal(m.devTier, false);
  assert.equal(m.actions.length, 1);
  assert.equal(m.actions[0].mode, "live"); // decommission predates the conduit
  // A kind absent from the payload degrades the same way.
  const gone = hooks.lifecycleActionsModel(CAP_PAYLOAD, { provider: "gcp", host: "h", name: "web" });
  assert.equal(gone.retry, true);
  assert.equal(gone.actions.length, 1);
});

// ── lifecycleActionsModel: dev-tier provider is filtered (not operated) ─────
test("S11b: a dev-tier provider is filtered — no Retry, decommission still live", () => {
  const m = hooks.lifecycleActionsModel(CAP_PAYLOAD, { provider: "fake", host: "h", name: "web" });
  assert.equal(m.available, false);
  assert.equal(m.devTier, true);
  assert.equal(m.retry, false); // a dev box has nothing to re-fetch
  assert.equal(m.actions.length, 1);
  assert.equal(m.actions[0].verb, "decommission");
});

// ── lifecycleActionsModel: a wired provider → per-verb honest degrade ───────
test("S11b: hetzner model — CLI affordances, a disabled verb with the SERVER reason, live decommission", () => {
  const bp = { provider: "hetzner", host: "h", name: "web" };
  const m = hooks.lifecycleActionsModel(CAP_PAYLOAD, bp);
  assert.equal(m.available, true);
  const byVerb = Object.fromEntries(plain(m.actions).map((a) => [a.verb, a]));
  // capability true but console-unwired → CLI affordance with the exact command.
  assert.equal(byVerb.archive.mode, "cli");
  assert.equal(byVerb.archive.cli, "bp cloud instance archive web");
  assert.equal(byVerb.audit.mode, "cli");
  // capability false → disabled, carrying Hetzner's OWN gap reason verbatim.
  assert.equal(byVerb.pause.mode, "disabled");
  assert.equal(byVerb.pause.reason, "Hetzner has no pause primitive.");
  // decommission is always the live console action.
  assert.equal(byVerb.decommission.mode, "live");
  assert.equal(byVerb.decommission.resourceName, "web");
});

test("S11b: azure model — the one false verb is disabled with its SERVER reason, the rest are CLI affordances", () => {
  const bp = { provider: "azure", host: "h", name: "az1" };
  const m = hooks.lifecycleActionsModel(CAP_PAYLOAD, bp);
  const byVerb = Object.fromEntries(plain(m.actions).map((a) => [a.verb, a]));
  assert.equal(byVerb.adopt.mode, "disabled");
  assert.equal(byVerb.adopt.reason, "Adopt needs an existing resource-group import.");
  // GR71 note: this arm used to also assert azure `audit` was a false verb with
  // no gap. The committed fixture says azure audit is TRUE — the hand-copied
  // payload had drifted. Deriving from the fixture corrected it, so the
  // never-invent-a-reason invariant is proved where it belongs, against a
  // synthetic payload: see "JS never invents a reason" below and the GR71
  // default_gap test above. Here the honest truth is a CLI affordance.
  assert.equal(byVerb.audit.mode, "cli");
  assert.equal(byVerb.audit.cli, "bp cloud instance audit az1");
  // pause is a capability here → a CLI affordance, not disabled.
  assert.equal(byVerb.pause.mode, "cli");
});

test("S11b: a box with no provider defaults to the hetzner capability lane", () => {
  const m = hooks.lifecycleActionsModel(CAP_PAYLOAD, { host: "h", name: "legacy" });
  assert.equal(m.kind, "hetzner");
  assert.equal(m.available, true);
  assert.equal(m.provider, null); // the IDENTITY chip stays empty — no fabricated provider
});

test("S11b: JS never invents a reason — a false verb with no gap and no default renders no copy", () => {
  const payload = { providers: { hetzner: { capabilities: { decommission: true, archive: false }, gaps: {} } } };
  const m = hooks.lifecycleActionsModel(payload, { provider: "hetzner", host: "h", name: "web" });
  const archive = plain(m.actions).find((a) => a.verb === "archive");
  assert.equal(archive.mode, "disabled");
  assert.equal(archive.reason, ""); // no server reason, no default → empty, NEVER fabricated
  const html = hooks.lifecycleActionRowHtml(m);
  assert.ok(html.indexOf("inst-life-reason") === -1); // and the render shows no reason span
});

// ── lifecycleActionRowHtml: the three modes render honestly ────────────────
test("S11b: lifecycleActionRowHtml renders the pill class, CLI chip, disabled reason, and danger decommission", () => {
  const m = hooks.lifecycleActionsModel(CAP_PAYLOAD, { provider: "hetzner", host: "h", name: "web" });
  const html = hooks.lifecycleActionRowHtml(m);
  assert.match(html, /inst-life-pill bp-inst--live/); // S4 token consumed on the pill
  assert.match(html, /Live/);
  assert.match(html, /bp cloud instance archive web/); // CLI affordance verbatim
  assert.match(html, /via the bp CLI/);
  assert.match(html, /Hetzner has no pause primitive\./); // server-owned reason
  assert.match(html, /data-life-verb="decommission"/); // the live, wired verb
  assert.match(html, /btn-danger/);
});

test("S11b: the loading + unavailable renders show their honest states", () => {
  const loading = hooks.lifecycleActionRowHtml(hooks.lifecycleActionsModel(undefined, { provider: "hetzner", host: "h", name: "web" }));
  assert.match(loading, /Checking capabilities/);
  assert.match(loading, /data-life-verb="decommission"/); // teardown never absent
  const unavail = hooks.lifecycleActionRowHtml(hooks.lifecycleActionsModel(null, { provider: "hetzner", host: "h", name: "web" }));
  assert.match(unavail, /Capabilities unavailable/);
  assert.match(unavail, /data-life-retry/); // retry offered
  const dev = hooks.lifecycleActionRowHtml(hooks.lifecycleActionsModel(CAP_PAYLOAD, { provider: "fake", host: "h", name: "web" }));
  assert.match(dev, /Developer-tier provider/);
  assert.ok(dev.indexOf("data-life-retry") === -1); // a dev box has nothing to retry
});

// ── lifecycleOptimistic: decommission flips the pill, failure rolls it back ─
test("S11b: lifecycleOptimistic applies the decommissioned pill then rolls back verbatim", () => {
  const base = hooks.lifecycleActionsModel(CAP_PAYLOAD, { provider: "hetzner", host: "h", name: "web" });
  assert.equal(base.pill.state, "live");
  const optimistic = hooks.lifecycleOptimistic(base, "decommission");
  assert.equal(optimistic.pill.state, "decommissioned");
  assert.equal(optimistic.pill.cls, "bp-inst--decommissioned");
  assert.equal(optimistic.pill.label, "Decommissioning");
  // rollback restores the exact prior pill and clears the bookkeeping.
  const rolled = hooks.lifecycleOptimistic(optimistic, "rollback");
  assert.deepEqual(plain(rolled.pill), plain(base.pill));
  assert.equal(rolled._rollback, undefined);
  // rollback with nothing remembered is a no-op (total, never throws).
  assert.equal(hooks.lifecycleOptimistic(base, "rollback"), base);
});

// ── gr-p4 G-02/G-03: the providers page (roster + hybrid connect + honest matrix)
// The capability facet in SERVER shape (minus default_gap) — mirrors the settings
// scenario fixture. hetzner/azure are prod (matrix columns); fake is dev-tier.
const PROV_CAP = {
  providers: {
    hetzner: { tier: "prod", gaps: { pause: "Hetzner has no pause primitive." },
      capabilities: { core: true, catalog: false, labels: true, pause: false, archive: true, resurrect: true, decommission: true, adopt: true, audit: true } },
    azure: { tier: "prod", gaps: { adopt: "Adopt needs an existing resource-group import." },
      capabilities: { core: true, catalog: true, labels: true, pause: true, archive: true, resurrect: true, decommission: true, adopt: false, audit: false } },
    fake: { tier: "dev", gaps: {},
      capabilities: { core: true, catalog: true, labels: true, pause: true, archive: true, resurrect: true, decommission: true, adopt: true, audit: true } },
  },
};

test("gr-p4: providers-page pure helpers are exported with the 9-verb order", () => {
  for (const n of ["providerDisplayName", "providerRosterHtml", "providerConnectModel",
    "providerConnectCardHtml", "capabilityMatrixModel", "capabilityMatrixHtml"]) {
    assert.equal(typeof hooks[n], "function", n + " must be exported");
  }
  assert.deepEqual([...hooks.capabilityVerbs],
    ["core", "catalog", "archive", "resurrect", "decommission", "adopt", "audit", "pause", "labels"]);
});

test("gr-p4: roster shows kind+label+connected-at, NEVER a live-validity badge; disconnect gates on admin", () => {
  const list = [{ id: "p1", kind: "hetzner", label: "main", inserted_at: new Date(Date.now() - 9 * 86400000).toISOString() }];
  const admin = hooks.providerRosterHtml(list, true);
  assert.match(admin, /Hetzner/);
  assert.match(admin, /main/);
  assert.match(admin, /connected /); // a connected-at line
  assert.ok(admin.indexOf("Connected</span>") === -1); // never an implied live-validity badge
  assert.match(admin, /data-prov-disconnect/);
  assert.match(admin, /data-prov-kind="hetzner"/);
  // a member (canDisconnect false) sees NO disconnect affordance
  assert.ok(hooks.providerRosterHtml(list, false).indexOf("data-prov-disconnect") === -1);
  // empty → an honest note, no rows
  assert.match(hooks.providerRosterHtml([], true), /No providers connected/);
  assert.ok(hooks.providerRosterHtml([], true).indexOf("prov-row") === -1);
});

// GR44 (.claude/workflows/bp-cloud-gui-remake-charter.md) — the server has been
// an UPSERT on (team_id, kind) since the unique index landed, so re-connecting a
// connected kind ROTATES its credential in place. These two tests used to pin the
// opposite (the "additive-duplicate guard" / "already-connected is disabled"
// stopgap that predated the index); they are inverted here, not relaxed.
test("gr-p4/GR44: a connected kind stays SELECTABLE — a second connect is a rotation, never a duplicate", () => {
  const empty = hooks.providerConnectModel([]);
  assert.equal(empty.allConnected, false);
  assert.equal(empty.selectable, "hetzner"); // first available kind armed
  assert.deepEqual(plain(empty.options.map((o) => o.kind)), ["hetzner", "azure"]);
  assert.ok(empty.options.every((o) => !o.connected));
  const partial = hooks.providerConnectModel([{ kind: "hetzner" }]);
  assert.equal(partial.selectable, "azure"); // an OPEN kind is still preferred by default
  assert.equal(partial.options.find((o) => o.kind === "hetzner").connected, true);
  // …but a connected kind is never dropped from the picker.
  assert.deepEqual(plain(partial.options.map((o) => o.kind)), ["hetzner", "azure"]);
  // All connected is a ROTATION state, not a dead end: a kind is still armed.
  const full = hooks.providerConnectModel([{ kind: "hetzner" }, { kind: "azure" }]);
  assert.equal(full.allConnected, true);
  assert.equal(full.selectable, "hetzner");
  assert.ok(full.options.every((o) => o.connected));
  // providerIsConnected is the single copy switch the card, the wiring and the
  // submit toast all read, so they can never disagree about connect vs replace.
  assert.equal(hooks.providerIsConnected([{ kind: "hetzner" }], "hetzner"), true);
  assert.equal(hooks.providerIsConnected([{ kind: "hetzner" }], "azure"), false);
  assert.equal(hooks.providerIsConnected(null, "hetzner"), false);
});

test("gr-p4/GR44: connect card is the GR33 hybrid, and an armed connected kind reads REPLACE — no disabled seg-btn, no dead end", () => {
  const card = hooks.providerConnectCardHtml([{ kind: "hetzner" }], null);
  assert.match(card, /data-connect-kind="hetzner"/);
  assert.ok(!/data-connect-kind="hetzner"[^>]*disabled/.test(card), "a connected kind is never a disabled ghost");
  assert.match(card, /data-connect-kind="azure"/);
  assert.match(card, /aria-pressed="true"/); // azure armed (the open kind is the default)
  assert.match(card, /set-save-row/); // verify+save in a save-row
  assert.match(card, /data-connect-submit/);
  assert.match(card, /cred-remediation/); // the in-card remediation slot
  // Arming the OPEN kind is a first connect: connect copy, no rotation note.
  assert.match(card, /Verify &amp; connect/);
  assert.ok(card.indexOf("data-connect-rotating") === -1);

  // Explicitly arming the CONNECTED kind is honoured and becomes a replace.
  const armedConnected = hooks.providerConnectCardHtml([{ kind: "hetzner" }], "hetzner");
  assert.match(armedConnected, /data-connect-kind="hetzner"[^>]*aria-pressed="true"/);
  assert.match(armedConnected, /data-connect-rotating/);
  assert.match(armedConnected, /Replaces the stored Hetzner Cloud credential/);
  assert.match(armedConnected, /keeps working until it does/); // the honest no-downtime claim
  assert.match(armedConnected, /Verify &amp; replace/);

  // All connected → still a working form, and NEVER the destroy-first copy.
  const replace = hooks.providerConnectCardHtml([{ kind: "hetzner" }, { kind: "azure" }], null);
  assert.match(replace, /data-connect-submit/);
  assert.match(replace, /Verify &amp; replace/);
  assert.match(replace, /data-connect-rotating/);
  assert.ok(replace.indexOf("Every supported provider is connected") === -1);
  assert.ok(replace.indexOf("Disconnect one above") === -1);
  assert.ok(!/data-connect-kind="[a-z]+"[^>]*disabled/.test(replace));
});

test("gr-p4/GR44: the roster shows a rotation — 'credential updated' ONLY when updated_at moved past inserted_at", () => {
  const at = new Date(Date.now() - 9 * 86400000).toISOString();
  const later = new Date(Date.now() - 3600000).toISOString();
  // A first connect: both stamps come from ONE autogenerate entry → no rotation line.
  const fresh = hooks.providerRosterHtml(
    [{ id: "p1", kind: "hetzner", label: "main", inserted_at: at, updated_at: at }], true);
  assert.match(fresh, /connected /);
  assert.ok(fresh.indexOf("credential updated") === -1, "an untouched row never claims an update");
  // A rotated row: the upsert kept inserted_at and moved updated_at.
  const rotated = hooks.providerRosterHtml(
    [{ id: "p1", kind: "hetzner", label: "main", inserted_at: at, updated_at: later }], true);
  assert.match(rotated, /connected /);
  assert.match(rotated, /credential updated /);
  assert.match(rotated, /data-prov-rotated/);
  // An older control plane that omits updated_at degrades to silence, not to a lie.
  const legacy = hooks.providerRosterHtml([{ id: "p1", kind: "hetzner", inserted_at: at }], true);
  assert.ok(legacy.indexOf("credential updated") === -1);
});

// cch wave 13 — the rotation card names WHICH cloud account the stored
// credential points at, BEFORE the person commits a replacement.
const OVERVIEW_AZURE = {
  regions: [], server_types: [], currency: "USD",
  provider: { kind: "azure", label: "az",
    identity: { label: "Subscription", value: "33333333-3333-3333-3333-333333333333",
      source: "stored", reason: null } },
};
const OVERVIEW_HETZNER = {
  regions: [], server_types: [], currency: "EUR",
  provider: { kind: "hetzner", label: "main",
    identity: { label: "Project", value: null, source: "unavailable",
      reason: "Hetzner doesn't report which project this token belongs to." } },
};

test("cch-w13: provider identity — the stored value is echoed as STORED, never as 'verified'", () => {
  for (const n of ["providerIdentityModel", "providerIdentityHtml"]) {
    assert.equal(typeof hooks[n], "function", n + " must be exported");
  }
  const m = hooks.providerIdentityModel(OVERVIEW_AZURE);
  assert.equal(m.state, "known");
  assert.equal(m.label, "Subscription");
  assert.equal(m.value, "33333333-3333-3333-3333-333333333333");
  assert.equal(m.stored, true);
  const html = hooks.providerIdentityHtml(m);
  assert.match(html, /data-prov-identity="known"/);
  assert.match(html, /33333333-3333-3333-3333-333333333333/);
  assert.match(html, /the subscription you connected/); // provenance, in the person's words
  assert.ok(!/verified/i.test(html), "the echo must never read as a verification");
});

test("cch-w13: provider identity — an unknown identity renders EXPLICITLY absent, never a blank that looks known", () => {
  // Hetzner: the server states the gap, and the console renders that reason.
  const hz = hooks.providerIdentityModel(OVERVIEW_HETZNER);
  assert.equal(hz.state, "absent");
  assert.equal(hz.label, "Project");
  const hzHtml = hooks.providerIdentityHtml(hz);
  assert.match(hzHtml, /data-prov-identity="absent"/);
  assert.match(hzHtml, /not known/);
  // the server's reason, verbatim (its apostrophe HTML-escaped by esc — the
  // console never re-words a server-owned reason)
  assert.match(hzHtml, /Hetzner doesn&#39;t report which project this token belongs to\./);
  assert.ok(hzHtml.replace(/<[^>]*>/g, "").trim().length > 0, "an absent identity is never empty markup");

  // A null value with NO server reason still says something honest.
  const bare = hooks.providerIdentityModel({ provider: { identity: { label: "Subscription", value: null } } });
  assert.equal(bare.state, "absent");
  assert.match(hooks.providerIdentityHtml(bare), /doesn’t say which account/);

  // An older control plane that omits the identity key entirely → absent with a
  // reason of the console's own, NOT a silent blank.
  const legacy = hooks.providerIdentityModel({ provider: { kind: "azure", label: "az" } });
  assert.equal(legacy.state, "absent");
  assert.match(hooks.providerIdentityHtml(legacy), /doesn’t report which account/);

  // Loading and fetch-failure are their own stated states.
  assert.equal(hooks.providerIdentityModel(undefined).state, "loading");
  assert.match(hooks.providerIdentityHtml(hooks.providerIdentityModel(undefined)), /Checking which account/);
  assert.equal(hooks.providerIdentityModel(null).state, "unavailable");
  assert.match(hooks.providerIdentityHtml(hooks.providerIdentityModel(null)), /couldn’t read which account/);
});

test("cch-w13: the identity slot rides the ROTATION card only, and names the armed kind", () => {
  const rotating = hooks.providerConnectCardHtml([{ kind: "hetzner" }], "hetzner");
  assert.match(rotating, /data-prov-identity-kind="hetzner"/);
  assert.match(rotating, /id="prov-identity"/);
  assert.match(rotating, /data-prov-identity="loading"/); // honest loading, not a blank slot
  // …and the slot sits ABOVE the credential fields, so it is read before the
  // "Verify & replace" button is pressed.
  assert.ok(rotating.indexOf("prov-identity") < rotating.indexOf("data-connect-submit"));
  // A first connect has no stored credential to name — no slot, no empty box.
  const fresh = hooks.providerConnectCardHtml([], "hetzner");
  assert.ok(fresh.indexOf("data-prov-identity-kind") === -1);
});

test("gr-p4: capability matrix — 9 verbs, prod columns only, server-owned gaps, NO invented reason, NO padded cell", () => {
  const m = hooks.capabilityMatrixModel(PROV_CAP);
  assert.equal(m.ok, true);
  assert.deepEqual(plain(m.providers.map((p) => p.kind)), ["hetzner", "azure"]); // fake (dev) filtered
  assert.equal(m.verbs.length, 9);
  // false WITH a server gap → the reason is the server's own, verbatim
  assert.equal(m.cells.pause.hetzner.ok, false);
  assert.equal(m.cells.pause.hetzner.reason, "Hetzner has no pause primitive.");
  assert.equal(m.cells.adopt.azure.reason, "Adopt needs an existing resource-group import.");
  // false with NO gap → a bare cell, NO reason (never padded, no default_gap)
  assert.equal(m.cells.catalog.hetzner.ok, false);
  assert.equal(m.cells.catalog.hetzner.reason, "");
  assert.equal(m.cells.audit.azure.reason, "");
  // a true cell carries no reason
  assert.equal(m.cells.core.hetzner.ok, true);
  assert.equal(m.cells.core.hetzner.reason, "");
});

test("gr-p4: capability matrix render — mark on yes, dash + verbatim reason on no, honest degrade states", () => {
  const html = hooks.capabilityMatrixHtml(hooks.capabilityMatrixModel(PROV_CAP));
  assert.match(html, /cap-matrix/);
  assert.match(html, />core</);
  assert.match(html, />pause</);
  assert.match(html, />labels</);
  assert.match(html, /Hetzner/);
  assert.match(html, /Azure/);
  assert.ok(html.indexOf(">Fake<") === -1); // dev-tier filtered from the render
  assert.match(html, /cap-mark/); // a supported mark
  assert.match(html, /cap-dash/); // an unsupported dash
  assert.match(html, /Hetzner has no pause primitive\./); // reason verbatim
  // honest degrade states
  assert.match(hooks.capabilityMatrixHtml(hooks.capabilityMatrixModel(undefined)), /Checking provider capabilities/);
  assert.match(hooks.capabilityMatrixHtml(hooks.capabilityMatrixModel(null)), /unavailable/);
  assert.match(hooks.capabilityMatrixHtml(hooks.capabilityMatrixModel({})), /unavailable/);
  // a payload with ONLY a dev-tier provider → unavailable (nothing to operate)
  assert.equal(hooks.capabilityMatrixModel({ providers: { fake: { tier: "dev", capabilities: {}, gaps: {} } } }).ok, false);
});

test("gr-p4: providerDisplayName — known brand or honest Title-case fallback, never a fabricated brand", () => {
  assert.equal(hooks.providerDisplayName("hetzner"), "Hetzner Cloud");
  assert.equal(hooks.providerDisplayName("azure"), "Microsoft Azure");
  assert.equal(hooks.providerDisplayName("gcp"), "Gcp"); // unknown prod kind → Title-case, never invented
  assert.equal(hooks.providerDisplayName(""), "");
});

// ── S13 domainStages: the per-host DNS/TLS checklist fold ────────────────────
// The pure reducer behind `bp cloud domain status` (Go) and the console Domain
// rail. NEITHER surface probes — both fold the SAME control-plane envelope. The
// four rung roles (ok/active/pending/failed), the active-front promotion, the
// terminal (poll-stop) flag, and the server-owned remediation gate are pinned
// here; the DOM mount + 4s poll are browser-verified.

// The all-serving / mid-issuance / serving-failed envelopes are NOT authored
// here — they are the REAL DomainStatus.check/2 output, read from the ONE
// cross-surface fixture that the Elixir suite regenerates + drift-gates and the
// Go CLI test also reads (a label/evidence/shape change reds all three
// runtimes). Their rung labels are the real server strings ("DNS resolves" /
// "Points to this instance" / "TLS certificate" / "Serving traffic"), and ok
// rungs carry remediation:null (domainStageRows coerces non-strings → "").
const DOMAIN_FIXTURE = JSON.parse(
  fs.readFileSync(new URL("./__fixtures__/domain-status.json", import.meta.url), "utf8"),
);
const DOMAIN_SERVING = DOMAIN_FIXTURE.all_serving;
const DOMAIN_PENDING = DOMAIN_FIXTURE.mid_issuance;
// [ok, ok, ok, failed] — the domain + cert are wired but the app is down. A
// failed serving rung is RECOVERABLE (an app restart heals it), so the fold
// keeps it NON-terminal and the DOM mount keeps polling.
const DOMAIN_SERVING_FAILED = DOMAIN_FIXTURE.serving_failed;

// DOMAIN_FAILED stays hand-authored: a lone failed-first rung with a
// skipped-pending tail is a fold-logic edge the real check/2 never emits (a DNS
// miss is pending, never failed), so it isn't part of the generated fixture — it
// exercises the terminal/active fold, not the server contract.
const DOMAIN_FAILED = {
  ok: false, checked_at: "2026-07-09T10:00:00Z",
  instance: { id: "i1", host: "blog.barkpark.cloud" },
  domains: [{
    host: "shop.example.com", kind: "custom", overall: "failed",
    stages: [
      { stage: "dns_found", label: "DNS found", status: "failed", evidence: "NXDOMAIN", remediation: "Add an A record for shop.example.com → 91.99.1.2." },
      { stage: "points_here", label: "Points here", status: "pending", evidence: "blocked on DNS", remediation: "" },
    ],
  }],
};

test("S13: domainStages exposes the pure helpers", () => {
  for (const name of ["domainStages", "domainStageRows", "domainChecklistHtml", "domainRungChip", "domainKindChip"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("S13: a fully-serving domain is all-ok and terminal (poll stops)", () => {
  const m = hooks.domainStages(DOMAIN_SERVING, 0);
  assert.equal(m.ok, true);
  assert.equal(m.empty, false);
  assert.equal(m.terminal, true); // every rung ok → nothing to poll
  assert.equal(m.checkedAt, "2026-07-09T10:00:00Z");
  assert.equal(m.domains.length, 1);
  const d = m.domains[0];
  assert.equal(d.overallRole, "ok");
  assert.deepEqual([...d.rows.map((r) => r.role)], ["ok", "ok", "ok", "ok"]);
  // No ok rung ever shows remediation.
  assert.ok(d.rows.every((r) => r.showRemediation === false));
});

test("S13: a mid-issuance domain promotes the first pending rung to the active front, and is NOT terminal", () => {
  const m = hooks.domainStages(DOMAIN_PENDING, 0);
  assert.equal(m.ok, false);
  assert.equal(m.terminal, false); // still resolving → keep polling
  const roles = [...m.domains[0].rows.map((r) => r.role)];
  // dns/points ok; the FIRST pending (tls) becomes "active"; serving stays pending.
  assert.deepEqual(roles, ["ok", "ok", "active", "pending"]);
  assert.equal(m.domains[0].overallRole, "pending");
});

test("S13: remediation shows ONLY under a non-ok rung that carries server copy, verbatim", () => {
  const rows = hooks.domainStageRows(DOMAIN_PENDING.domains[0].stages);
  const tls = rows.find((r) => r.stage === "tls");
  const dns = rows.find((r) => r.stage === "dns_found");
  // tls: active (non-ok) + server copy → shown, verbatim (the REAL server string).
  assert.equal(tls.showRemediation, true);
  assert.match(tls.remediation, /issued and renewed automatically by the platform/);
  // An ok rung never shows remediation (the fixture nulls it → coerced "").
  assert.equal(dns.role, "ok");
  assert.equal(dns.showRemediation, false);
  assert.equal(dns.remediation, "");
  // The "empty remediation → no dangling row" logic (a non-ok rung the server
  // left reason-less — rare: FailureCopy's default clause means the real server
  // never does, so this is synthetic) must still suppress the row.
  const bare = hooks.domainStageRows([{ stage: "serving", status: "pending", remediation: "" }]);
  assert.equal(bare[0].role, "pending");
  assert.equal(bare[0].showRemediation, false);
  assert.equal(bare[0].remediation, "");
});

test("S13: a failed rung settles, but a skipped-pending rung downstream keeps polling (the operator can fix + watch)", () => {
  const m = hooks.domainStages(DOMAIN_FAILED, 0);
  const roles = [...m.domains[0].rows.map((r) => r.role)];
  // dns failed; points_here never had a prior ok, so it stays pending (no active).
  assert.deepEqual(roles, ["failed", "pending"]);
  // A pending rung remains → NOT terminal (the box may still be actioned).
  assert.equal(m.terminal, false);
  assert.equal(m.domains[0].overallRole, "failed");
  const dns = m.domains[0].rows[0];
  assert.equal(dns.showRemediation, true);
  assert.equal(dns.remediation, "Add an A record for shop.example.com → 91.99.1.2.");
});

test("S13: a failed SERVING rung stays NON-terminal — an app restart heals it, so keep polling", () => {
  const m = hooks.domainStages(DOMAIN_SERVING_FAILED, 0);
  const roles = [...m.domains[0].rows.map((r) => r.role)];
  // domain + cert wired, the app behind them is down.
  assert.deepEqual(roles, ["ok", "ok", "ok", "failed"]);
  assert.equal(m.domains[0].overallRole, "failed");
  // NARROW: a failed serving rung is recoverable (tls:ok + serving:failed is a
  // modeled state), so the fold keeps it NON-terminal and the mount keeps
  // polling to catch the heal.
  assert.equal(m.terminal, false);
  const serving = m.domains[0].rows[3];
  assert.equal(serving.stage, "serving");
  assert.equal(serving.showRemediation, true); // server copy under the failed rung
  // Narrowness guard: a failed NON-serving rung with no pending tail IS terminal
  // (a genuine dead-end — broadening the rule would infinite-poll it). Synthetic:
  // the real server always trails a points/dns failure with skipped-pending rungs.
  const deadEnd = hooks.domainStages({
    ok: false,
    domains: [{ host: "h", overall: "failed", stages: [
      { stage: "dns_found", status: "ok" },
      { stage: "points_here", status: "failed" },
    ] }],
  }, 0);
  assert.equal(deadEnd.terminal, true);
});

test("S13: an empty domain set folds to empty+terminal (keeps the static Domain rail row)", () => {
  const m = hooks.domainStages({ ok: true, domains: [] }, 0);
  assert.equal(m.empty, true);
  assert.equal(m.terminal, true); // nothing to poll
  const html = hooks.domainChecklistHtml(m, { custom_host: "acme.barkpark.cloud" });
  // Degrades to the original single Domain rail row, not a checklist card.
  assert.match(html, /rail-row/);
  assert.match(html, /acme\.barkpark\.cloud/);
  assert.ok(html.indexOf("vf-card") === -1);
});

test("S13: domainStages is TOTAL — a null/garbage payload never throws", () => {
  for (const bad of [null, undefined, {}, { domains: null }, { domains: [null, {}] }]) {
    const m = hooks.domainStages(bad, 0);
    assert.equal(Array.isArray(m.domains), true);
    assert.equal(typeof m.terminal, "boolean");
  }
  // A domain with no stages array is an empty (terminal) host.
  const m = hooks.domainStages({ domains: [{ host: "h" }] }, 0);
  assert.deepEqual([...m.domains[0].rows], []);
});

test("S13: domainChecklistHtml renders one v4 dom-card per host with escaped, role-mapped rung pills", () => {
  // Pin UPDATED deliberately (gr-p3-site-detail): the shared checklist restyled
  // off the borrowed .vf-chip vocabulary onto its own v4 .dom-* family.
  const m = hooks.domainStages(DOMAIN_PENDING, 0);
  const html = hooks.domainChecklistHtml(m, {});
  assert.match(html, /dom-card/);
  assert.match(html, /blog-22222222\.barkpark\.cloud/);
  assert.match(html, /dom-rung--ok/);      // the two ok rungs
  assert.match(html, /dom-rung--active/);  // the front in-flight rung
  assert.match(html, /dom-rung--pending/); // the waiting rung
  assert.match(html, /issued and renewed automatically by the platform/); // remediation surfaced verbatim
  assert.match(html, /dom-note/);          // …in the amber note component
  // The kind chip is present.
  assert.match(html, /platform/);
});

test("S13: domainRungChip escapes a hostile label + evidence (no raw markup leaks)", () => {
  const chip = hooks.domainRungChip({
    role: "failed", label: "<b>x</b>", evidence: "<script>1</script>", remediation: "", showRemediation: false,
  });
  assert.ok(chip.indexOf("<b>x</b>") === -1, "label must be escaped");
  assert.ok(chip.indexOf("<script>") === -1, "evidence must be escaped");
  assert.match(chip, /dom-rung--failed/);
});

test("S13: domainKindChip maps the two known kinds and passes an unknown through", () => {
  assert.equal(hooks.domainKindChip("platform"), "platform");
  assert.equal(hooks.domainKindChip("custom"), "custom");
  assert.equal(hooks.domainKindChip(""), "");
  assert.equal(hooks.domainKindChip("byo"), "byo");
});

// ─────────────────────────────────────────────────────────────────────────────
// S12 (azure-hetzner hosting): the Metrics tab — metricsSeries fold + the
// string-returning SVG sparkline. Consumers NEVER compute; they render the
// pinned S12a envelope verbatim.
// ─────────────────────────────────────────────────────────────────────────────

const METRICS_LIVE = {
  ok: true,
  collected_at: "2026-07-09T12:00:00Z",
  instance: { id: "bp_1", host: "prod.barkpark.cloud", provider: "hetzner" },
  beat: { last_seen_at: "2026-07-09T11:59:30Z", age_seconds: 30, status: "live" },
  points: 4,
  series: {
    cpu: [{ at: "t0", value: 12 }, { at: "t1", value: 44 }, { at: "t2", value: 30 }, { at: "t3", value: 55 }],
    mem: [{ at: "t0", value: 60 }, { at: "t1", value: 62 }, { at: "t2", value: 61 }, { at: "t3", value: 63 }],
    disk: [{ at: "t0", value: 40 }, { at: "t1", value: 40 }, { at: "t2", value: 41 }, { at: "t3", value: 41 }],
    load: [{ at: "t0", value: 0.5 }, { at: "t1", value: 1.2 }, { at: "t2", value: 0.8 }, { at: "t3", value: 1.1 }],
  },
  service_health: { pass: 3, total: 3, failing: [] },
};

test("S12: metricsSeries folds a live envelope — status, current, host/provider, health", () => {
  const m = hooks.metricsSeries(METRICS_LIVE);
  assert.equal(m.status, "live");
  assert.equal(m.live, true);
  assert.equal(m.absent, false);
  assert.equal(m.stale, false);
  assert.equal(m.host, "prod.barkpark.cloud");
  assert.equal(m.provider, "hetzner");
  assert.deepEqual([...m.metrics.map((x) => x.key)], [...hooks.metricsKeys]);
  const cpu = m.metrics.find((x) => x.key === "cpu");
  assert.equal(cpu.current, 55); // latest non-null value
  assert.equal(cpu.hasData, true);
  assert.deepEqual([...cpu.values], [12, 44, 30, 55]);
  assert.equal(m.health.pass, 3);
  assert.equal(m.health.total, 3);
  assert.deepEqual([...m.health.failing], []);
  assert.equal(hooks.metricsValueText(cpu), "55%");
  const load = m.metrics.find((x) => x.key === "load");
  assert.equal(hooks.metricsValueText(load), "1.1"); // no unit, two-decimal max
});

test("S12: metricsSeries — absent beat yields the honest waiting state (never a zeroed chart)", () => {
  const m = hooks.metricsSeries({ ok: true, beat: { status: "absent" }, series: {} });
  assert.equal(m.absent, true);
  const html = hooks.metricsPanelHtml(m);
  assert.match(html, /Waiting for the first beat/);
  // No chart is drawn in the absent state.
  assert.ok(html.indexOf("metrics-grid") === -1);
  assert.ok(html.indexOf("<svg") === -1);
});

test("S12: metricsSeries — stale beat flags the last-known series with 'last seen Xm ago'", () => {
  const stale = { ...METRICS_LIVE, beat: { last_seen_at: "t", age_seconds: 180, status: "stale" } };
  const m = hooks.metricsSeries(stale);
  assert.equal(m.stale, true);
  assert.equal(m.lastSeenText, "3m ago"); // 180s → 3m
  const html = hooks.metricsPanelHtml(m);
  assert.match(html, /Agent offline/);
  assert.match(html, /last seen 3m ago/);
  // The last-known series is STILL rendered (a stale read shows history, not blank).
  assert.match(html, /metrics-grid/);
  assert.match(html, /<svg/);
});

test("S12: metricsAgeText — honest human ages, garbage → ''", () => {
  assert.equal(hooks.metricsAgeText(0), "0s ago");
  assert.equal(hooks.metricsAgeText(45), "45s ago");
  assert.equal(hooks.metricsAgeText(90), "1m ago");
  assert.equal(hooks.metricsAgeText(3600), "1h ago");
  assert.equal(hooks.metricsAgeText(90000), "1d ago");
  for (const bad of [null, undefined, NaN, -5, "x"]) assert.equal(hooks.metricsAgeText(bad), "");
});

test("S12: metricsSeries preserves null points as gaps (a null never becomes 0) + current skips trailing nulls", () => {
  const holey = {
    ok: true, beat: { status: "live", age_seconds: 10 },
    series: { cpu: [{ at: "t0", value: 10 }, { at: "t1", value: null }, { at: "t2", value: 20 }, { at: "t3", value: null }] },
  };
  const m = hooks.metricsSeries(holey);
  const cpu = m.metrics.find((x) => x.key === "cpu");
  // The null is preserved as null in the values array — NOT coerced to 0.
  assert.deepEqual([...cpu.values], [10, null, 20, null]);
  // current is the latest REAL value, skipping the trailing null.
  assert.equal(cpu.current, 20);
});

test("S12: metricsSeries is TOTAL — a null/garbage payload never throws", () => {
  for (const bad of [null, undefined, {}, { series: null }, { beat: 7, series: { cpu: [null, {}, { value: "x" }] } }]) {
    const m = hooks.metricsSeries(bad);
    assert.equal(typeof m.status, "string");
    assert.equal(Array.isArray(m.metrics), true);
    assert.equal(m.metrics.length, hooks.metricsKeys.length);
    // A garbage / absent beat degrades to the absent state, never a crash.
    assert.equal(["live", "stale", "absent"].includes(m.status), true);
  }
  // A bogus cpu series (non-numeric samples) → all-null values, hasData false.
  const m = hooks.metricsSeries({ beat: { status: "live" }, series: { cpu: [{ value: "x" }, null] } });
  const cpu = m.metrics.find((x) => x.key === "cpu");
  assert.deepEqual([...cpu.values], [null, null]);
  assert.equal(cpu.hasData, false);
  assert.equal(cpu.current, null);
  assert.equal(hooks.metricsValueText(cpu), "—"); // holes-only → em-dash, never a fake 0
});

test("S12: sparklineSvg draws a NULL as a gap, not a point at the baseline", () => {
  // [10, null, 20]: two isolated islands → two dots, ZERO connecting polyline, and
  // exactly two plotted points (the non-null count) — the null draws nothing.
  const svg = hooks.sparklineSvg([10, null, 20], { width: 100, height: 40 });
  assert.match(svg, /^<svg[\s\S]*<\/svg>$/);
  assert.equal((svg.match(/<circle/g) || []).length, 2);
  assert.equal((svg.match(/<polyline/g) || []).length, 0);
  assert.ok(svg.indexOf("NaN") === -1, "no NaN coordinates leak");

  // [10,20,null,30,40]: two runs → two polylines, four total plotted points.
  const svg2 = hooks.sparklineSvg([10, 20, null, 30, 40], { width: 100, height: 40 });
  const polys = svg2.match(/points="([^"]*)"/g) || [];
  assert.equal(polys.length, 2); // one polyline per contiguous run (the null is the gap)
  const pairs = polys.reduce((acc, p) => acc + p.replace(/points="|"/g, "").trim().split(/\s+/).length, 0);
  assert.equal(pairs, 4); // exactly the four real samples — the null contributes none
});

test("S12: sparklineSvg — empty / all-null → an empty frame (never a fabricated line)", () => {
  for (const vals of [[], [null, null], null, undefined, ["x", NaN]]) {
    const svg = hooks.sparklineSvg(vals, {});
    assert.match(svg, /^<svg[\s\S]*<\/svg>$/);
    assert.ok(svg.indexOf("<polyline") === -1);
    assert.ok(svg.indexOf("<circle") === -1);
  }
});

test("S12: sparklineSvg — a flat series draws along the mid-line, never at y=0 (no divide-by-zero)", () => {
  const h = 40, pad = 3;
  const svg = hooks.sparklineSvg([50, 50, 50, 50], { width: 100, height: h });
  const poly = (svg.match(/points="([^"]*)"/) || [])[1];
  assert.ok(poly, "a flat series still draws a stroke");
  const ys = poly.trim().split(/\s+/).map((p) => Number(p.split(",")[1]));
  const mid = pad + (h - pad * 2) / 2;
  for (const y of ys) assert.equal(y, mid); // mid-line baseline, not the y=0 top edge
});

test("S12: metricsHealthHtml — failing checks surface; absent counts hide (never 0/0)", () => {
  assert.equal(hooks.metricsHealthHtml({}), "");
  assert.equal(hooks.metricsHealthHtml({ pass: 0, total: 0, failing: [] }), "");
  const ok = hooks.metricsHealthHtml({ pass: 3, total: 3, failing: [] });
  assert.match(ok, /Health 3\/3/);
  const bad = hooks.metricsHealthHtml({ pass: 2, total: 3, failing: ["disk", "http"] });
  assert.match(bad, /Health 2\/3/);
  assert.match(bad, /failing: disk, http/);
});

// D-07 (GR27): the request-level stubs are honest dashed rows — WHAT, never a
// fabricated number and never the 24h-warmup ETA fiction (GR28).
test("D-07: metricsStubsHtml renders exactly the three not-yet-metered signals, dimmed, no number", () => {
  const html = hooks.metricsStubsHtml();
  assert.deepEqual([...hooks.metricsStubKeys], ["req_per_s", "p95_ms", "api_requests"]);
  assert.equal((html.match(/class="metrics-stub"/g) || []).length, 3);
  for (const label of ["Req/s", "p95 latency", "API requests"]) {
    assert.ok(html.includes(">" + label + "<"), "the " + label + " stub renders");
  }
  assert.equal((html.match(/Not yet metered/g) || []).length, 3);
  // Honest absence: no fabricated digit, no ETA — the GR28 kill list stays dead.
  assert.ok(!/\d/.test(html.replace(/p95/g, "")), "a stub never shows a number");
  assert.doesNotMatch(html, /warm|24\s?h|unlock|collected/i);
});

test("D-07: metricsPanelHtml shows the stubs alongside a live read + carries NONE of the killed warmup copy", () => {
  const live = hooks.metricsPanelHtml(hooks.metricsSeries(METRICS_LIVE));
  assert.match(live, /metrics-grid/); // the 4 live vitals
  assert.match(live, /metrics-stubs/); // the dashed request-level stubs
  assert.match(live, />Req\/s</);
  // GR28 kill list: the "metrics are warming up / 24h / N of 24h collected"
  // fiction must NOT be reachable in the built panel, in any state.
  for (const html of [live, hooks.metricsPanelHtml(hooks.metricsSeries({ beat: { status: "stale", age_seconds: 200 }, series: METRICS_LIVE.series }))]) {
    assert.doesNotMatch(html, /warming up|24h|24 h|of 24|unlock|collected/i);
  }
});

test("D-07: the absent panel owns its empty state — no vitals grid, no stubs, never a zeroed chart", () => {
  const absent = hooks.metricsPanelHtml(hooks.metricsSeries({ ok: true, beat: { status: "absent" }, series: {} }));
  assert.match(absent, /Waiting for the first beat/);
  assert.ok(absent.indexOf("metrics-grid") === -1, "no vitals grid in the absent state");
  assert.ok(absent.indexOf("metrics-stubs") === -1, "no request-level stubs in the absent state");
});

// ── S14 portable archives: the console archives panel (pure projection) ──────
test("S14: the archives helpers are exported", () => {
  for (const name of ["archivesModel", "archiveRowHtml", "archivesPanelHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("S14: archivesModel — undefined payload is the loading shell", () => {
  const m = hooks.archivesModel(undefined);
  assert.equal(m.loading, true);
  assert.equal(m.error, false);
  assert.deepEqual([...m.rows], []);
  // The panel renders a spinner, not an empty/error state.
  assert.match(hooks.archivesPanelHtml(m), /Loading archives/);
});

test("S14: archivesModel — {ok:true, archives:[]} is a TRUE empty, not an error", () => {
  const m = hooks.archivesModel({ ok: true, archives: [] });
  assert.equal(m.loading, false);
  assert.equal(m.error, false);
  assert.equal(m.rows.length, 0);
  const html = hooks.archivesPanelHtml(m);
  assert.match(html, /No archives yet/);
  // The empty state teaches the archive command as a copy affordance.
  assert.match(html, /bp cloud instance archive/);
});

test("S14: archivesModel — a bundle row carries the exact resurrect command per provider", () => {
  const m = hooks.archivesModel({
    ok: true,
    archives: [
      { fqdn: "api.barkpark.cloud", slug: "api-2", source_provider: "azure",
        created_at: "2026-07-08T00:00:00Z", bundle_ref: "archives/t/api-2/",
        spec: { region: "eastus", server_type: "Standard_B1s" } },
      { fqdn: "web.barkpark.cloud", slug: "web-1", source_provider: "hetzner",
        created_at: "2026-07-01T00:00:00Z", bundle_ref: "archives/t/web-1/",
        spec: { region: "nbg1", server_type: "cax11" } },
    ],
  });
  assert.equal(m.rows.length, 2);
  // Order is the server's (newest-first) — the model is a faithful projection.
  assert.equal(m.rows[0].slug, "api-2");
  assert.equal(m.rows[0].providerKind, "azure");
  assert.equal(m.rows[0].resurrectCommand, "bp cloud instance resurrect api-2 --provider azure");
  assert.equal(m.rows[1].resurrectCommand, "bp cloud instance resurrect web-1 --provider hetzner");
  assert.equal(m.rows[1].region, "nbg1");
  assert.equal(m.rows[1].serverType, "cax11");
});

test("S14: archiveRowHtml — identity + provider chip + a copy-paste resurrect chip", () => {
  const m = hooks.archivesModel({
    ok: true,
    archives: [{ fqdn: "web.barkpark.cloud", slug: "web-1", source_provider: "hetzner",
      created_at: "2026-07-01T00:00:00Z", spec: { region: "nbg1", server_type: "cax11" } }],
  });
  const html = hooks.archiveRowHtml(m.rows[0]);
  assert.match(html, /web\.barkpark\.cloud/);
  assert.match(html, /provider-chip--hetzner/); // IDENTITY chip (Decision 7)
  assert.match(html, /nbg1 · cax11/);
  // The resurrect command rides the shared copy affordance (data-copy).
  assert.match(html, /data-copy="bp cloud instance resurrect web-1 --provider hetzner"/);
});

test("S14: an unknown provider fakes no identity chip; a slugless bundle has no resurrect command", () => {
  const m = hooks.archivesModel({
    ok: true,
    archives: [{ fqdn: "mystery.example", slug: "", source_provider: "gcp", spec: {} }],
  });
  const row = m.rows[0];
  assert.equal(row.resurrectCommand, ""); // no slug → no paste-fail command
  const html = hooks.archiveRowHtml(row);
  assert.ok(html.indexOf("provider-chip--") === -1); // unknown kind → no chip, not a fake one
  assert.ok(html.indexOf("archive-resurrect") === -1); // no resurrect affordance rendered
});

test("S14: archivesModel — a 502 {ok:false,error} surfaces the SERVER message + Retry", () => {
  const m = hooks.archivesModel({ ok: false, error: "Archive storage isn't configured for this deployment." });
  assert.equal(m.error, true);
  assert.equal(m.message, "Archive storage isn't configured for this deployment.");
  const html = hooks.archivesPanelHtml(m);
  // esc() HTML-escapes the apostrophe — assert on escaping-stable fragments.
  assert.match(html, /Archive storage isn/);
  assert.match(html, /configured for this deployment/);
  assert.match(html, /data-archives-retry/);
});

test("S14: a client transport failure never surfaces a raw internal token as a server reason", () => {
  // api() returns {error:"network_error"} (NO ok:false) on a fetch reject.
  const m = hooks.archivesModel({ error: "network_error" });
  assert.equal(m.error, true);
  assert.ok(m.message.indexOf("network_error") === -1); // the sentinel never reaches the operator
  assert.match(m.message, /try again/i);
});

// ── azh-w7: the console Resurrect flow (pure request/outcome/sheet builders) ──
test("azh-w7: the resurrect helpers are exported", () => {
  for (const name of ["resurrectRequestBody", "resurrectOutcome", "resurrectModalHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("azh-w7: resurrectRequestBody — name=slug, THIS row's bundle_ref, chosen provider", () => {
  const row = { slug: "shop", bundleRef: "s3://bundles/shop.tar.zst", providerKind: "hetzner" };
  // Picking azure (portable) overrides the source provider.
  const b = hooks.resurrectRequestBody(row, "azure");
  assert.equal(b.name, "shop");
  assert.equal(b.bundle_ref, "s3://bundles/shop.tar.zst");
  assert.equal(b.provider, "azure");
  // No explicit pick → falls back to the source provider.
  assert.equal(hooks.resurrectRequestBody(row).provider, "hetzner");
});

test("azh-w7: resurrectRequestBody — a source-less bundle omits provider (server default)", () => {
  const body = hooks.resurrectRequestBody({ slug: "x", bundleRef: "ref" }, "");
  assert.equal(body.name, "x");
  assert.equal(body.bundle_ref, "ref");
  assert.ok(!("provider" in body)); // never a blank provider on the wire
});

test("azh-w7: resurrectOutcome — a 202 hands off to the /new step feed", () => {
  const out = hooks.resurrectOutcome({ status: 202, data: { ok: true, id: "bp-1", bundle_ref: "ref" } });
  assert.equal(out.action, "progress");
  assert.equal(out.id, "bp-1");
});

test("azh-w7: resurrectOutcome — provider_not_connected surfaces the SERVER remediation (D19)", () => {
  const remediation = "Connect your Azure account in Settings → Providers, then try again.";
  const out = hooks.resurrectOutcome({
    status: 422,
    data: { error: "provider_not_connected", provider: "azure", remediation: remediation },
  });
  assert.equal(out.action, "remediate");
  // Verbatim server copy — NOT re-derived through friendly() (which drops it).
  assert.equal(out.message, remediation);
});

test("azh-w7: resurrectOutcome — provider_not_connected w/o remediation still yields a message", () => {
  const out = hooks.resurrectOutcome({ status: 422, data: { error: "provider_not_connected" } });
  assert.equal(out.action, "remediate");
  assert.ok(typeof out.message === "string" && out.message.length > 0);
});

test("azh-w7: resurrectOutcome — any other failure is a plain error sentence", () => {
  const out = hooks.resurrectOutcome({ status: 500, data: { error: "enqueue_failed" } });
  assert.equal(out.action, "error");
  assert.ok(typeof out.message === "string" && out.message.length > 0);
  // A bare 404/no-body never white-screens.
  assert.equal(hooks.resurrectOutcome({ status: 404 }).action, "error");
  assert.equal(hooks.resurrectOutcome(undefined).action, "error");
});

test("azh-w7: resurrectModalHtml — title, typed echo, provider picker, disarmed button", () => {
  const html = hooks.resurrectModalHtml(
    { slug: "shop", bundleRef: "ref", providerKind: "hetzner" }, "hetzner");
  assert.match(html, /Resurrect shop\?/);
  // The portable provider picker carries BOTH available clouds.
  assert.match(html, /data-resurrect-tabs/);
  assert.match(html, /data-kind="hetzner"/);
  assert.match(html, /data-kind="azure"/);
  // Typed-echo proof-of-attention + a server-owned inline error slot.
  assert.match(html, /Type <span class="cm-name">shop<\/span> to confirm/);
  assert.match(html, /id="resurrect-typed"/);
  assert.match(html, /id="resurrect-error"/);
  // The Resurrect action ships DISABLED — the typed echo arms it.
  assert.match(html, /id="resurrect-go"[^>]*disabled/);
});

test("azh-w7: resurrectModalHtml — the slug is HTML-escaped (no markup injection)", () => {
  const html = hooks.resurrectModalHtml({ slug: '<img src=x>', bundleRef: "ref" }, "hetzner");
  assert.ok(html.indexOf("<img src=x>") === -1);
  assert.match(html, /&lt;img/);
});

// ── bp-login-ux W1: /activate device-login approve-page pure helpers ────────
// The browser half of `bp login`'s copy-link flow. These are the parse/decode
// helpers that turn a pasted/deep-linked code into the wire user_code and fold
// the frozen (charter D10) inspect/approve responses into view states — the
// layer where a malformed ?code= or a stray character would otherwise reach the
// POST body or throw inside render(). Rendering + fetch flows are browser-live.

test("the /activate helpers are exported", () => {
  for (const name of ["normalizeUserCode", "userCodeComplete", "activateCodeFromSearch",
    "activateInspectState", "activateExpiryText",
    "pathClean", "isActivateFlow", "isNewFlow"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  assert.equal(hooks.activateAlphabet, "23456789ABCDEFGHJKMNPQRSTVWXYZ");
});

test("normalizeUserCode uppercases, drops separators, and renders XXXX-XXXX", () => {
  assert.equal(hooks.normalizeUserCode("abcd-2345"), "ABCD-2345");
  assert.equal(hooks.normalizeUserCode("abcd2345"), "ABCD-2345"); // inserts the dash
  assert.equal(hooks.normalizeUserCode("ab cd 23 45"), "ABCD-2345"); // strips spaces
  assert.equal(hooks.normalizeUserCode("AB-CD-23-45"), "ABCD-2345"); // strips extra dashes
});

test("normalizeUserCode drops ambiguous chars (no 0/1/I/L/O/U) and caps at 8", () => {
  // 0,1,O,I,L,U are outside the alphabet → stripped, not mapped.
  assert.equal(hooks.normalizeUserCode("O0I1LU"), ""); // every char rejected
  assert.equal(hooks.normalizeUserCode("ABCD2345EXTRA"), "ABCD-2345"); // caps at 8 valid chars
  assert.equal(hooks.normalizeUserCode(null), ""); // nullish → empty, never throws
});

test("normalizeUserCode keeps a live dash only past 4 chars (natural typing)", () => {
  assert.equal(hooks.normalizeUserCode("ab"), "AB"); // no premature dash
  assert.equal(hooks.normalizeUserCode("abcd"), "ABCD");
  assert.equal(hooks.normalizeUserCode("abcd2"), "ABCD-2");
});

test("userCodeComplete is true only for exactly 8 alphabet chars", () => {
  assert.equal(hooks.userCodeComplete("ABCD-2345"), true);
  assert.equal(hooks.userCodeComplete("abcd2345"), true); // normalized first
  assert.equal(hooks.userCodeComplete("ABCD-234"), false); // 7 chars
  assert.equal(hooks.userCodeComplete(""), false);
  assert.equal(hooks.userCodeComplete("OOOO-1111"), false); // all rejected chars
});

test("activateCodeFromSearch pulls + normalizes the ?code= prefill", () => {
  assert.equal(hooks.activateCodeFromSearch("?code=abcd2345"), "ABCD-2345");
  assert.equal(hooks.activateCodeFromSearch("?code=ABCD-2345&x=1"), "ABCD-2345");
  assert.equal(hooks.activateCodeFromSearch("?other=1"), ""); // no code param
  assert.equal(hooks.activateCodeFromSearch(""), ""); // empty search
  assert.equal(hooks.activateCodeFromSearch(null), ""); // nullish never throws
});

test("activateInspectState folds the frozen D10 responses into view states", () => {
  assert.equal(hooks.activateInspectState(200, { client_name: "bp on host" }), "confirm");
  assert.equal(hooks.activateInspectState(404, { error: "expired_or_invalid" }), "gone");
  assert.equal(hooks.activateInspectState(500, {}), "error"); // retryable
  assert.equal(hooks.activateInspectState(200, null), "error"); // 200 without a body
  // W2: 429 is a FIRST-CLASS rate-limited state, no longer folded into "error"
  // (the old generic error screen let Try-again re-fire inspect instantly and
  // re-trip the limiter). rate_limited renders a paused/countdown retry.
  assert.equal(hooks.activateInspectState(429, {}), "rate_limited");
  assert.equal(hooks.activateInspectState(429, { error: "rate_limited" }), "rate_limited");
});

// ── bp-login-ux W2: /activate trailing-slash tolerance ──────────────────────
// The control plane serves /activate/ (and //) as the same 200 as /activate
// (Plug.Router drops the trailing slash), so an EXACT pathname check missed the
// slashed spellings — the approve page never rendered and the hash-router escape
// guards bounced the user to the dashboard. pathClean strips trailing slashes
// (keeping "/" itself), and isActivateFlow/isNewFlow route through it.

test("pathClean strips trailing slashes but keeps root intact", () => {
  assert.equal(hooks.pathClean("/activate"), "/activate");
  assert.equal(hooks.pathClean("/activate/"), "/activate");
  assert.equal(hooks.pathClean("/activate//"), "/activate");
  assert.equal(hooks.pathClean("/new/"), "/new");
  assert.equal(hooks.pathClean("/"), "/"); // root must NOT collapse to ""
  assert.equal(hooks.pathClean("//"), "/"); // repeated root → "/"
  assert.equal(hooks.pathClean(""), "/"); // empty → "/"
  assert.equal(hooks.pathClean(null), "/"); // nullish never throws
});

test("isActivateFlow matches every trailing-slash spelling, and only /activate", () => {
  const orig = sandbox.location.pathname;
  const at = (p) => { sandbox.location.pathname = p; return hooks.isActivateFlow(); };
  try {
    assert.equal(at("/activate"), true);
    assert.equal(at("/activate/"), true); // the bug: server 200s this
    assert.equal(at("/activate//"), true);
    assert.equal(at("/activated"), false); // prefix, NOT a slash variant → no match
    assert.equal(at("/new/"), false);
    assert.equal(at("/"), false);
  } finally { sandbox.location.pathname = orig; }
});

test("isNewFlow matches /new and /new/ (same defect class), and only those", () => {
  const orig = sandbox.location.pathname;
  const at = (p) => { sandbox.location.pathname = p; return hooks.isNewFlow(); };
  try {
    assert.equal(at("/new"), true);
    assert.equal(at("/new/"), true);
    assert.equal(at("/new//"), true);
    assert.equal(at("/newsletter"), false); // prefix, not a slash variant
    assert.equal(at("/activate/"), false);
    assert.equal(at("/"), false);
  } finally { sandbox.location.pathname = orig; }
});

test("activateExpiryText renders a humane countdown and fails closed", () => {
  const now = Date.parse("2026-07-09T12:00:00Z");
  assert.equal(hooks.activateExpiryText("2026-07-09T12:09:30Z", now), "expires in 9m 30s");
  assert.equal(hooks.activateExpiryText("2026-07-09T12:00:45Z", now), "expires in 45s");
  assert.equal(hooks.activateExpiryText("2026-07-09T11:59:00Z", now), "expired"); // past
  assert.equal(hooks.activateExpiryText(null, now), ""); // absent
  assert.equal(hooks.activateExpiryText("not-a-date", now), ""); // unparseable → ""
});

// ── Cmd+K command palette (wave 3) ──────────────────────────────────────────
// The palette DOM mount + Cmd/Ctrl+K keydown are browser-verified; these pin the
// pure helpers: fuzzy subsequence match, filter/rank, the selection reducer, and
// the registry builder (static nav + actions + instances + sites).

test("the command-palette pure helpers are exported", () => {
  for (const name of ["paletteFuzzy", "paletteFilter", "paletteMoveIndex",
    "paletteNavItems", "paletteActionItems", "paletteInstanceItems",
    "paletteSiteItems", "paletteRegistry"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("paletteFuzzy is a case-insensitive, order-preserving subsequence match", () => {
  assert.equal(hooks.paletteFuzzy("ov", "Overview Go to"), true);
  assert.equal(hooks.paletteFuzzy("OVW", "Overview Go to"), true); // gaps allowed, any case
  assert.equal(hooks.paletteFuzzy("wover", "Overview"), false); // out of order
  assert.equal(hooks.paletteFuzzy("", "anything"), true); // empty passes everything
  assert.equal(hooks.paletteFuzzy("x", ""), false);
  assert.equal(hooks.paletteFuzzy(null, "Fleet"), true); // nullish query → pass, never throws
  assert.equal(hooks.paletteFuzzy("fleet", null), false); // nullish hay → no match, never throws
});

test("paletteFilter: empty query returns the registry order-preserving", () => {
  const items = [
    { label: "Overview", group: "Go to" },
    { label: "Fleet", group: "Go to" },
    { label: "Sites", group: "Go to" },
  ];
  const out = hooks.paletteFilter(items, "");
  assert.deepEqual(out.map((i) => i.label), ["Overview", "Fleet", "Sites"]);
  assert.notEqual(out, items); // a copy, not the original array
});

test("paletteFilter ranks a substring hit above a mere subsequence", () => {
  const items = [
    { label: "Track of keys", group: "Actions" }, // "tok": t..o..k subsequence, NO "tok" substring
    { label: "Manage tokens", group: "Settings" }, // "tok" is a contiguous substring (tokens)
  ];
  const out = hooks.paletteFilter(items, "tok");
  assert.equal(out.length, 2);
  assert.equal(out[0].label, "Manage tokens"); // substring wins over subsequence
});

test("paletteFilter keeps registry order for equal-quality matches", () => {
  const items = [
    { label: "Fleet", group: "Go to" },
    { label: "Fleet · healthy", group: "Go to" },
  ];
  // "fleet" is a prefix substring (idx 0) in both → tie broken by registry order.
  const out = hooks.paletteFilter(items, "fleet");
  assert.deepEqual([...out.map((i) => i.label)], ["Fleet", "Fleet · healthy"]);
});

test("paletteFilter drops non-matches and never throws on missing fields", () => {
  const items = [{ label: "Overview" }, {}, { group: "Sites" }];
  assert.deepEqual([...hooks.paletteFilter(items, "ovv").map((i) => i.label)], ["Overview"]);
  assert.deepEqual([...hooks.paletteFilter(null, "x")], []);
});

test("paletteMoveIndex wraps on up/down and snaps on home/end", () => {
  assert.equal(hooks.paletteMoveIndex(0, 3, "down"), 1);
  assert.equal(hooks.paletteMoveIndex(2, 3, "down"), 0); // wrap forward
  assert.equal(hooks.paletteMoveIndex(0, 3, "up"), 2); // wrap backward
  assert.equal(hooks.paletteMoveIndex(1, 3, "home"), 0);
  assert.equal(hooks.paletteMoveIndex(1, 3, "end"), 2);
});

test("paletteMoveIndex clamps out-of-range and handles an empty list", () => {
  assert.equal(hooks.paletteMoveIndex(9, 3, null), 0); // out-of-range → first
  assert.equal(hooks.paletteMoveIndex(-4, 3, null), 0);
  assert.equal(hooks.paletteMoveIndex(0, 0, "down"), -1); // nothing selectable
  assert.equal(hooks.paletteMoveIndex(2, 5, "nudge"), 2); // unknown dir → clamp
});

test("paletteNavItems carries the frozen IA, the three Fleet lenses, and every Settings view", () => {
  const nav = hooks.paletteNavItems();
  const byId = Object.fromEntries(nav.map((n) => [n.id, n]));
  for (const id of ["nav-overview", "nav-fleet", "nav-fleet-attention",
    "nav-fleet-inflight", "nav-fleet-healthy", "nav-sites", "nav-activity"]) {
    assert.ok(byId[id], id + " must be a nav row");
  }
  // One Settings row per registered Settings view (no dead shells, no extras).
  const settings = nav.filter((n) => n.group === "Settings").map((n) => n.id).sort();
  assert.deepEqual(settings, hooks.settingsViews.map((v) => "nav-settings-" + v).sort());
  // Every nav row is kind:'nav' with a runnable run().
  for (const n of nav) {
    assert.equal(n.kind, "nav");
    assert.equal(typeof n.run, "function");
  }
});

test("paletteActionItems are safe actions only, each with a run()", () => {
  const acts = hooks.paletteActionItems();
  assert.deepEqual([...acts.map((a) => a.id).sort()], ["act-account", "act-launch", "act-theme"]);
  for (const a of acts) {
    assert.equal(a.group, "Actions");
    assert.equal(a.kind, "action");
    assert.equal(typeof a.run, "function");
  }
});

test("paletteInstanceItems map name + status hint + drill-in run", () => {
  const rows = hooks.paletteInstanceItems([
    { id: "bp-1", name: "guerrilla", host: "guerrilla.example.com", version: "1.2.0" },
    { id: "bp-2", host: null, provision_status: "failed" }, // no name → falls back to id
  ]);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].label, "guerrilla");
  assert.equal(rows[0].group, "Instances");
  assert.equal(rows[0].kind, "nav");
  assert.equal(typeof rows[0].hint, "string"); // statusOf(...).label, never blank/throwing
  assert.ok(rows[0].hint.length > 0);
  assert.equal(rows[1].label, "bp-2"); // id fallback
  assert.equal(hooks.paletteInstanceItems(null).length, 0); // nullish → empty
});

test("paletteSiteItems map primary domain + framework hint + drill-in run", () => {
  const rows = hooks.paletteSiteItems([
    { id: "s1", domains: ["shop.example.com"], framework: "nextjs" },
    { id: "s2", slug: "blog" }, // no domains → slug fallback, "site" hint
  ]);
  assert.equal(rows[0].label, "shop.example.com");
  assert.equal(rows[0].hint, "nextjs");
  assert.equal(rows[0].group, "Sites");
  assert.equal(rows[0].kind, "nav");
  assert.equal(rows[1].label, "blog");
  assert.equal(rows[1].hint, "site");
  assert.equal(hooks.paletteSiteItems(null).length, 0);
});

test("paletteRegistry orders static nav + actions first, then instances, then sites", () => {
  const reg = hooks.paletteRegistry({
    instances: [{ id: "bp-1", name: "guerrilla", host: "h" }],
    sites: [{ id: "s1", domains: ["a.example.com"] }],
  });
  const staticCount = hooks.paletteNavItems().length + hooks.paletteActionItems().length;
  assert.equal(reg[staticCount].group, "Instances"); // instances immediately after the static block
  assert.equal(reg[reg.length - 1].group, "Sites"); // sites last
  // Every registry row has the full shape.
  for (const it of reg) {
    assert.equal(typeof it.id, "string");
    assert.equal(typeof it.label, "string");
    assert.equal(typeof it.run, "function");
    assert.ok(it.kind === "nav" || it.kind === "action");
  }
});

test("paletteRegistry with no data is the static slate — the instant-open guarantee", () => {
  const reg = hooks.paletteRegistry();
  const staticCount = hooks.paletteNavItems().length + hooks.paletteActionItems().length;
  assert.equal(reg.length, staticCount); // nav + actions only, no instance/site rows
  assert.ok(!reg.some((i) => i.group === "Instances" || i.group === "Sites"));
});

// ════════════════════════════════════════════════════════════════════════════
// bp-login-ux W3 — shared two-factor challenge card (charter decision 39)
// ════════════════════════════════════════════════════════════════════════════
// The control plane's login is two-phase for TOTP accounts: POST /v1/auth/login
// → 200 {two_factor_required:true, challenge_token}; POST /v1/auth/two-factor-
// challenge {challenge_token, code|recovery_code} → 200 {token, team_id} | 401
// invalid_code | 429 rate_limited. ONE shared card renders at every submit site.
// The server is HTTP-tested (router_two_factor_test.exs); here we pin the SPA's
// pure classifiers, the card markup, honest 401/429 copy, the closure-only
// secret handling, and the mount → challenge → onDone path via a stubbed fetch.

// A richer fake root than fakeNode(): stable per-selector child stubs (so a
// re-paint re-wires the SAME node), a value map, handler capture + _fire, and a
// settable innerHTML. Mirrors the mountTimelineTab wiring-smoke style.
function fake2faRoot(values) {
  const nodes = {};
  function nodeFor(sel) {
    if (!nodes[sel]) {
      const handlers = {};
      nodes[sel] = {
        value: (values && values[sel]) || "",
        disabled: false, textContent: "", hidden: false,
        _handlers: handlers,
        addEventListener(ev, fn) { handlers[ev] = fn; },
        removeEventListener() {}, setAttribute() {}, getAttribute() { return null; },
        focus() {}, classList: { toggle() {}, add() {}, remove() {}, contains() { return false; } },
        querySelector() { return null; }, querySelectorAll() { return []; },
      };
    }
    return nodes[sel];
  }
  const root = {
    _html: "",
    get innerHTML() { return root._html; },
    set innerHTML(v) { root._html = String(v); },
    querySelector(sel) { return nodeFor(sel); },
    querySelectorAll() { return []; },
    _fire(sel, ev) { const n = nodes[sel]; if (n && n._handlers[ev]) return n._handlers[ev]({ preventDefault() {} }); },
    _node(sel) { return nodeFor(sel); },
  };
  return root;
}

test("W3 2FA: the shared-card helpers are exported through the ONE hook", () => {
  for (const name of ["loginResponseKind", "twoFactorChallengeOutcome",
    "twoFactorCardHtml", "twoFactorErrorCopy", "mountTwoFactorCard"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  assert.equal(typeof hooks.twoFactorRateWaitS, "number");
});

test("W3 2FA: loginResponseKind routes session / two_factor / error", () => {
  assert.equal(hooks.loginResponseKind({ ok: true, data: { token: "t", team_id: "x" } }), "session");
  assert.equal(hooks.loginResponseKind({ ok: true, data: { two_factor_required: true, challenge_token: "CT" } }), "two_factor");
  // two_factor_required WITHOUT a challenge_token is not a valid challenge → error.
  assert.equal(hooks.loginResponseKind({ ok: true, data: { two_factor_required: true } }), "error");
  assert.equal(hooks.loginResponseKind({ ok: false, status: 401, data: { error: "invalid_credentials" } }), "error");
  assert.equal(hooks.loginResponseKind(null), "error");
});

test("W3 2FA: twoFactorChallengeOutcome maps 200/401/429/other honestly", () => {
  // Field-by-field: the outcome object is built inside the vm realm, so its
  // prototype ≠ node's Object.prototype and deepStrictEqual would reject it.
  const ok = hooks.twoFactorChallengeOutcome({ ok: true, status: 200, data: { token: "sess", team_id: "team-9" } });
  assert.equal(ok.state, "success");
  assert.equal(ok.token, "sess");
  assert.equal(ok.team_id, "team-9");
  // 200 with a null team_id still succeeds (team_id normalises to null).
  const ok2 = hooks.twoFactorChallengeOutcome({ ok: true, status: 200, data: { token: "sess" } });
  assert.equal(ok2.state, "success");
  assert.equal(ok2.team_id, null);
  assert.equal(hooks.twoFactorChallengeOutcome({ ok: false, status: 401, data: { error: "invalid_code" } }).state, "invalid_code");
  assert.equal(hooks.twoFactorChallengeOutcome({ ok: false, status: 429, data: { error: "rate_limited" } }).state, "rate_limited");
  assert.equal(hooks.twoFactorChallengeOutcome({ ok: false, status: 500, data: {} }).state, "error");
  assert.equal(hooks.twoFactorChallengeOutcome(null).state, "error");
});

test("W3 2FA: invalid_code and rate_limited get DISTINCT honest copy", () => {
  const invalid = hooks.friendly({ error: "invalid_code" });
  const rate = hooks.friendly({ error: "rate_limited" });
  assert.match(invalid, /didn't match/);
  assert.match(rate, /Too many attempts/);
  assert.notEqual(invalid, rate); // a 401 must never read like a 429
  // The card's own copy helper agrees with the ERRORS entry for invalid_code.
  assert.equal(hooks.twoFactorErrorCopy("invalid_code"), invalid);
  assert.match(hooks.twoFactorErrorCopy("empty", false), /6-digit code/);
  assert.match(hooks.twoFactorErrorCopy("empty", true), /recovery code/);
});

test("W3 2FA: the card markup is tokens-only OTP by default, recovery on toggle", () => {
  const otp = hooks.twoFactorCardHtml({ mode: "otp" });
  assert.match(otp, /id="tfa-form"/);
  assert.match(otp, /id="tfa-code"/);
  assert.match(otp, /inputmode="numeric"/);      // valid inputmode (not the old "latin")
  assert.match(otp, /autocomplete="one-time-code"/);
  assert.match(otp, /id="tfa-alt"/);             // "use a recovery code"
  assert.match(otp, /Use a recovery code/);
  assert.doesNotMatch(otp, /<select|type="checkbox"|type="radio"/); // no native controls

  const rec = hooks.twoFactorCardHtml({ mode: "recovery" });
  assert.match(rec, /Recovery code/);
  assert.match(rec, /Use a 6-digit code/);
  assert.doesNotMatch(rec, /inputmode="numeric"/); // recovery codes are alphanumeric
});

test("W3 2FA: the 429 card is a PAUSED disabled-countdown, no instant re-fire", () => {
  const html = hooks.twoFactorCardHtml({ mode: "otp", rateLimited: true });
  assert.match(html, /id="tfa-submit"/);
  assert.match(html, /disabled/);
  assert.match(html, /Try again in \d+s/);
  assert.doesNotMatch(html, /id="tfa-form"/);   // no live form to submit while paused
  assert.match(html, /Too many attempts/);
});

test("W3 2FA: mount → valid code → challenge endpoint → onDone(session)", async () => {
  const root = fake2faRoot({ "#tfa-code": "123456" });
  let done = null;
  const realFetch = sandbox.fetch;
  const calls = [];
  sandbox.fetch = (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    return Promise.resolve({
      ok: true, status: 200,
      headers: { get: () => "application/json" },
      json: () => Promise.resolve({ token: "sess-1", team_id: "team-9" }),
    });
  };
  try {
    hooks.mountTwoFactorCard(root, { challengeToken: "CT-xyz", onDone: (s) => { done = s; } });
    assert.match(root.innerHTML, /id="tfa-form"/);        // painted synchronously
    root._fire("#tfa-form", "submit");
    assert.equal(root._node("#tfa-submit").disabled, true); // immediate feedback
    for (let i = 0; i < 10; i++) await Promise.resolve();   // flush the promise chain
    assert.equal(calls.length, 1);
    assert.match(calls[0].url, /two-factor-challenge/);
    assert.equal(calls[0].body.challenge_token, "CT-xyz");  // token from the closure
    assert.equal(calls[0].body.code, "123456");
    assert.ok(done);
    assert.equal(done.token, "sess-1");
    assert.equal(done.team_id, "team-9");
  } finally { sandbox.fetch = realFetch; }
});

test("W3 2FA: a 401 repaints invalid-code copy, re-enables the form, no onDone", async () => {
  const root = fake2faRoot({ "#tfa-code": "000000" });
  let done = false;
  const realFetch = sandbox.fetch;
  sandbox.fetch = () => Promise.resolve({
    ok: false, status: 401,
    headers: { get: () => "application/json" },
    json: () => Promise.resolve({ error: "invalid_code" }),
  });
  try {
    hooks.mountTwoFactorCard(root, { challengeToken: "CT", onDone: () => { done = true; } });
    root._fire("#tfa-form", "submit");
    for (let i = 0; i < 10; i++) await Promise.resolve();
    assert.equal(done, false);                            // wrong code is NOT success
    assert.match(root.innerHTML, /rotate every 30 seconds/); // honest inline copy (apostrophe HTML-escaped)
    assert.match(root.innerHTML, /id="tfa-form"/);        // form is back — retry in place
  } finally { sandbox.fetch = realFetch; }
});

test("W3 2FA: a 429 paints the paused-countdown state, no onDone", async () => {
  const root = fake2faRoot({ "#tfa-code": "123456" });
  let done = false;
  const realFetch = sandbox.fetch;
  sandbox.fetch = () => Promise.resolve({
    ok: false, status: 429,
    headers: { get: () => "application/json" },
    json: () => Promise.resolve({ error: "rate_limited" }),
  });
  try {
    hooks.mountTwoFactorCard(root, { challengeToken: "CT", onDone: () => { done = true; } });
    root._fire("#tfa-form", "submit");
    for (let i = 0; i < 10; i++) await Promise.resolve();
    assert.equal(done, false);
    assert.match(root.innerHTML, /Too many attempts/);
    assert.match(root.innerHTML, /Try again in \d+s/);
    assert.equal(root._node("#tfa-submit").disabled, true);
  } finally { sandbox.fetch = realFetch; }
});

test("W3 2FA: the recovery toggle switches the submit to recovery_code", async () => {
  const root = fake2faRoot({ "#tfa-code": "abcd-efgh" });
  const realFetch = sandbox.fetch;
  let body = null;
  sandbox.fetch = (url, init) => { body = JSON.parse(init.body); return Promise.resolve({
    ok: true, status: 200, headers: { get: () => "application/json" },
    json: () => Promise.resolve({ token: "s", team_id: "t" }),
  }); };
  try {
    hooks.mountTwoFactorCard(root, { challengeToken: "CT", onDone: () => {} });
    root._fire("#tfa-alt", "click"); // OTP → recovery
    assert.match(root.innerHTML, /Recovery code/);
    root._fire("#tfa-form", "submit");
    for (let i = 0; i < 10; i++) await Promise.resolve();
    assert.equal(body.recovery_code, "abcd-efgh");
    assert.equal(body.code, undefined); // recovery mode sends recovery_code, not code
  } finally { sandbox.fetch = realFetch; }
});

test("W3 2FA: the challenge_token is NEVER written to storage (closure-only)", async () => {
  const root = fake2faRoot({ "#tfa-code": "123456" });
  const realFetch = sandbox.fetch;
  const realLocal = sandbox.localStorage;
  const realSession = sandbox.sessionStorage;
  const writes = [];
  const spy = { getItem: () => null, removeItem: () => {}, setItem: (k, v) => writes.push([k, v]) };
  sandbox.localStorage = spy;
  sandbox.sessionStorage = spy;
  sandbox.fetch = (url, init) => Promise.resolve({
    ok: true, status: 200, headers: { get: () => "application/json" },
    json: () => Promise.resolve({ token: "s", team_id: "t" }),
  });
  try {
    hooks.mountTwoFactorCard(root, { challengeToken: "CT-secret-xyz", onDone: () => {} });
    root._fire("#tfa-form", "submit");
    for (let i = 0; i < 10; i++) await Promise.resolve();
    for (const [k, v] of writes) {
      assert.doesNotMatch(String(v), /CT-secret-xyz/, "challenge_token must never hit storage (" + k + ")");
    }
  } finally {
    sandbox.fetch = realFetch; sandbox.localStorage = realLocal; sandbox.sessionStorage = realSession;
  }
});

// ── isu-w5 console operator update panel ────────────────────────────────────
// The per-instance update-truth derivations + the 409 pin-force flow + the fleet
// rollout banner. Every helper CODES AGAINST the Decision-10 field names
// (autoupdate_enabled/paused, pinned_release, channel, update_checked_at, built
// by the sibling slice) and DEGRADES GRACEFULLY against an older CP that omits
// them. Fixture rows below pin both the present-fields and absent-fields shapes.

// NOTE: sandbox objects carry the vm realm's Object prototype, so
// deepStrictEqual fails on equal structure — round-trip through the module-scoped
// `plain()` helper (defined earlier) to re-home a plain object into this realm.

test("isu-w5: the update-panel helpers are exported through the ONE hook", () => {
  for (const name of ["hasAutoupdatePolicy", "updateBadge", "lastCheckedText",
    "autoupdatePolicyLabel", "autoupdateActions", "updateConflict", "updateConflictCopy",
    "forceUpdateBody", "updatePanelHtml", "fleetRolloutBanner", "fleetRolloutBannerHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("isu-w5: hasAutoupdatePolicy is false for an older-CP row, true once any policy field lands", () => {
  assert.equal(hooks.hasAutoupdatePolicy({}), false);
  assert.equal(hooks.hasAutoupdatePolicy({ update_state: "behind" }), false); // legacy update fields ≠ policy
  assert.equal(hooks.hasAutoupdatePolicy({ autoupdate_enabled: true }), true);
  assert.equal(hooks.hasAutoupdatePolicy({ autoupdate_paused: false }), true);
  assert.equal(hooks.hasAutoupdatePolicy({ pinned_release: null }), true); // present-and-null still counts
  assert.equal(hooks.hasAutoupdatePolicy({ channel: "stable" }), true);
  assert.equal(hooks.hasAutoupdatePolicy(null), false);
});

test("isu-w5: updateBadge derives current | behind | in-flight | unknown, in-flight outranks", () => {
  assert.deepEqual(plain(hooks.updateBadge({ update_state: "current" })), { state: "current", role: "ok", label: "Up to date" });
  assert.deepEqual(plain(hooks.updateBadge({ update_state: "behind" })), { state: "behind", role: "info", label: "Update available" });
  assert.deepEqual(plain(hooks.updateBadge({})), { state: "unknown", role: "neutral", label: "Unknown" });
  assert.deepEqual(plain(hooks.updateBadge({ update_state: "garbage" })), { state: "unknown", role: "neutral", label: "Unknown" });
  // the trigger marker wins over a stale "behind"
  assert.deepEqual(
    plain(hooks.updateBadge({ update_state: "behind", autoupdate_triggered_at: "2026-07-10T00:00:00Z" })),
    { state: "in-flight", role: "info", label: "Updating" },
  );
  assert.equal(hooks.updateBadge(null).state, "unknown");
});

test("isu-w5: lastCheckedText reads Never checked for absent/unparsable, Checked <rel> otherwise", () => {
  assert.equal(hooks.lastCheckedText(null), "Never checked");
  assert.equal(hooks.lastCheckedText(""), "Never checked");
  assert.equal(hooks.lastCheckedText("not-a-date"), "Never checked");
  assert.equal(hooks.lastCheckedText(new Date(Date.now() - 5 * 60 * 1000).toISOString()), "Checked 5m ago");
  assert.equal(hooks.lastCheckedText(new Date().toISOString()), "Checked just now");
});

test("isu-w5: autoupdatePolicyLabel is null on older CP; pin > pause > manual > auto precedence", () => {
  assert.equal(hooks.autoupdatePolicyLabel({}), null); // no policy block → hidden chip
  // auto-riding a channel
  assert.deepEqual(plain(hooks.autoupdatePolicyLabel({ autoupdate_enabled: true, channel: "canary" })),
    { tone: "ok", dot: "online", text: "Auto · canary" });
  assert.deepEqual(plain(hooks.autoupdatePolicyLabel({ autoupdate_enabled: true })),
    { tone: "ok", dot: "online", text: "Auto" });
  // manual (opt-out)
  assert.deepEqual(plain(hooks.autoupdatePolicyLabel({ autoupdate_enabled: false })),
    { tone: "neutral", dot: "unknown", text: "Manual" });
  // paused beats manual/auto
  assert.equal(hooks.autoupdatePolicyLabel({ autoupdate_enabled: true, autoupdate_paused: true }).text, "Paused");
  // a pin beats a pause and names the version (normalised via vRel)
  assert.deepEqual(plain(hooks.autoupdatePolicyLabel({ autoupdate_paused: true, pinned_release: "0.4.1" })),
    { tone: "warn", dot: "warn", text: "Pinned to v0.4.1" });
});

test("isu-w5: autoupdateActions hides every button on older CP and toggles pin/pause independently", () => {
  assert.deepEqual(plain(hooks.autoupdateActions({})),
    { policy: false, showPin: false, showUnpin: false, showPause: false, showResume: false });
  // enabled, unpinned, unpaused → offer Pin + Pause
  assert.deepEqual(plain(hooks.autoupdateActions({ autoupdate_enabled: true, autoupdate_paused: false })),
    { policy: true, showPin: true, showUnpin: false, showPause: true, showResume: false });
  // pinned + paused → offer Unpin + Resume
  assert.deepEqual(plain(hooks.autoupdateActions({ pinned_release: "v0.4.1", autoupdate_paused: true })),
    { policy: true, showPin: false, showUnpin: true, showPause: false, showResume: true });
});

test("isu-w5: updateConflict classifies pinned / already_running / not_enabled / not_live / other", () => {
  assert.deepEqual(plain(hooks.updateConflict({ error: { code: "pinned", pinned_release: "v0.4.1" } })),
    { kind: "pinned", pin: "v0.4.1" });
  // a pin named without a code still reads as pinned (defensive)
  assert.deepEqual(plain(hooks.updateConflict({ pinned_release: "v0.4.0" })), { kind: "pinned", pin: "v0.4.0" });
  assert.deepEqual(plain(hooks.updateConflict({ error: { code: "already_running" } })), { kind: "already_running", pin: null });
  assert.deepEqual(plain(hooks.updateConflict({ error: { code: "not_enabled" } })), { kind: "not_enabled", pin: null });
  assert.deepEqual(plain(hooks.updateConflict({ error: { code: "not_live" } })), { kind: "not_live", pin: null });
  assert.deepEqual(plain(hooks.updateConflict({ error: { code: "instance_error" } })), { kind: "other", pin: null, code: "instance_error" });
  // a flat string error (some routes emit {error: "not_found"})
  assert.equal(hooks.updateConflict({ error: "not_found" }).kind, "other");
  assert.equal(hooks.updateConflict(null).kind, "other");
});

test("isu-w5: updateConflictCopy offers force ONLY for a pin, names it, carries the honest no-rollback caveat", () => {
  const pinned = hooks.updateConflictCopy({ kind: "pinned", pin: "v0.4.1" });
  assert.equal(pinned.forceLabel, "Update anyway");
  assert.match(pinned.body, /v0\.4\.1/);
  assert.match(pinned.body, /does not roll back/); // charter honest-pin copy
  // terminal kinds NEVER offer a force affordance
  for (const kind of ["already_running", "not_enabled", "not_live", "other"]) {
    assert.equal(hooks.updateConflictCopy({ kind }).forceLabel, null, kind + " must not offer force");
  }
  assert.match(hooks.updateConflictCopy({ kind: "not_enabled" }).body, /BARKPARK_SELF_UPDATE_APPLY=1/);
});

test("isu-w5: forceUpdateBody is the explicit {force:true} override payload", () => {
  assert.deepEqual(plain(hooks.forceUpdateBody()), { force: true });
});

test("isu-w5: updatePanelHtml renders truth cells and degrades (no policy chip/buttons) on older CP", () => {
  const legacy = hooks.updatePanelHtml({
    update_state: "behind", update_running_release: "0.4.0", update_latest_release: "v0.4.1", version: "0.4.0",
  });
  assert.match(legacy, /Update available/);       // badge
  assert.match(legacy, /v0\.4\.0/);               // running
  assert.match(legacy, /v0\.4\.1/);               // latest
  assert.match(legacy, /Never checked/);          // no update_checked_at
  assert.match(legacy, /update-panel/);
  assert.doesNotMatch(legacy, /data-au=/);        // no policy block → no policy buttons
  assert.doesNotMatch(legacy, /Autoupdate<\/span>/); // no policy chip row

  const modern = hooks.updatePanelHtml({
    update_state: "current", update_running_release: "v0.4.1", update_latest_release: "v0.4.1",
    channel: "stable", update_checked_at: new Date(Date.now() - 3600 * 1000).toISOString(),
    autoupdate_enabled: true, autoupdate_paused: false, pinned_release: null,
  });
  assert.match(modern, /Up to date/);
  assert.match(modern, /Stable/);                 // channel, capitalised
  assert.match(modern, /Checked 1h ago/);
  assert.match(modern, /Auto · stable/);          // policy chip
  assert.match(modern, /data-au="pin"/);          // Pin offered (unpinned)
  assert.match(modern, /data-au="pause"/);        // Pause offered (unpaused)
  assert.doesNotMatch(modern, /data-au="unpin"/);
});

test("isu-w5: updatePanelHtml escapes a hostile channel value (no markup injection)", () => {
  const html = hooks.updatePanelHtml({ autoupdate_enabled: true, channel: '<img src=x onerror=alert(1)>' });
  assert.doesNotMatch(html, /<img src=x/);
  assert.match(html, /&lt;img/);
});

test("isu-w5: fleetRolloutBanner — halted → warn+Resume, live → base+Halt, absent → null", () => {
  assert.equal(hooks.fleetRolloutBanner(null), null);
  assert.equal(hooks.fleetRolloutBanner("nope"), null);
  const halted = hooks.fleetRolloutBanner({ halted: true, halted_reason: "bad release 0.5.0" });
  assert.equal(halted.halted, true);
  assert.equal(halted.tone, "warn");
  assert.equal(halted.verb, "resume");
  assert.match(halted.body, /bad release 0\.5\.0/);
  const live = hooks.fleetRolloutBanner({ halted: false });
  assert.equal(live.halted, false);
  assert.equal(live.verb, "halt");
  assert.equal(live.tone, "");
});

test("isu-w5: fleetRolloutBannerHtml emits a wired Halt/Resume button, empty on absent state", () => {
  assert.equal(hooks.fleetRolloutBannerHtml(null), "");
  const halted = hooks.fleetRolloutBannerHtml({ halted: true });
  assert.match(halted, /notice-warn/);
  assert.match(halted, /data-fleet-au="resume"/);
  assert.match(halted, /Resume rollout/);
  const live = hooks.fleetRolloutBannerHtml({ halted: false });
  assert.match(live, /data-fleet-au="halt"/);
  assert.match(live, /Halt rollout/);
  // halted_reason is escaped, never injected as markup
  const evil = hooks.fleetRolloutBannerHtml({ halted: true, halted_reason: "<b>x</b>" });
  assert.doesNotMatch(evil, /<b>x<\/b>/);
  assert.match(evil, /&lt;b&gt;x/);
});

// ── isu-w6 → GR41: console instance rollback rides the SHARED confirm modal ──
// (charter W6 D16/D19/D23 + GR41 danger-no-echo grammar)

test("gr41: the rollback pure helpers are exported through the ONE test hook", () => {
  assert.equal(typeof hooks.rollbackConfirmOpts, "function");
  assert.equal(typeof hooks.rollbackConflictCopy, "function");
  assert.equal(typeof hooks.rollbackRefusalTerminal, "function");
});

test("gr41: rollbackConfirmOpts rides the danger-no-echo tier with the honest D19 copy (app-level, schema forward, pins)", () => {
  const opts = hooks.rollbackConfirmOpts({ name: "acme-prod" });
  assert.equal(opts.tier, "danger");                   // no typed echo for a reversible-grave action
  assert.equal(opts.confirmLabel, "Roll back");
  assert.equal(opts.busyLabel, "Rolling back…");
  const html = hooks.confirmModalHtml(hooks.confirmModalInit(opts));
  assert.match(html, /Roll back acme-prod\?/);         // names the instance
  assert.match(html, /previous slot/);                 // app-level slot flip
  assert.match(html, /does <b>not<\/b> undo migrations/); // schema stays FORWARD (rich-body slot)
  assert.match(html, /<b>pinned<\/b>/);                // pins at rolled-back version
  assert.match(html, /id="cm-confirm"/);               // the SHARED confirm trigger
  assert.doesNotMatch(html, /id="cm-confirm" disabled/); // armed from the start — no echo gate
  assert.doesNotMatch(html, /cm-typed/);               // danger-no-echo: no typed field
  assert.match(html, /id="cm-error"/);                 // the D25 inline-failure surface exists
  assert.match(html, /data-close/);                    // Cancel exists
  assert.match(html, /btn-danger/);                    // rollback is a caution action
});

test("gr41: a hostile instance name never injects markup through the shared modal (title is esc'd)", () => {
  const html = hooks.confirmModalHtml(hooks.confirmModalInit(
    hooks.rollbackConfirmOpts({ name: '<img src=x onerror=alert(1)>' })));
  assert.doesNotMatch(html, /<img src=x/); // never emitted as live markup
  assert.match(html, /&lt;img/);           // rendered as escaped text
});

test("gr41: rollbackRefusalTerminal splits Close from Try again over the D23 vocabulary", () => {
  for (const code of ["no_previous_slot", "not_supported", "not_enabled",
    "feature_not_configured", "not_live"]) {
    assert.equal(hooks.rollbackRefusalTerminal(code), true, code + " is terminal");
  }
  for (const code of ["already_running", "instance_unreachable", "instance_error", "wat", undefined]) {
    assert.equal(hooks.rollbackRefusalTerminal(code), false, String(code) + " is transient (retryable)");
  }
});

test("isu-w6: rollbackConflictCopy maps the full W6 refusal vocabulary (D23), no force affordance", () => {
  const noPrev = hooks.rollbackConflictCopy("no_previous_slot", { error: { code: "no_previous_slot" } });
  assert.match(noPrev.title, /Nothing to roll back to/);
  assert.match(noPrev.body, /No previous slot/);

  assert.match(hooks.rollbackConflictCopy("already_running").title, /already running/);
  assert.match(hooks.rollbackConflictCopy("not_supported").body, /blue\/green slot box/);

  // not_enabled and its 503 alias feature_not_configured collapse to one honest copy
  const notEnabled = hooks.rollbackConflictCopy("not_enabled");
  const notConfigured = hooks.rollbackConflictCopy("feature_not_configured");
  assert.match(notEnabled.body, /BARKPARK_SELF_UPDATE_APPLY=1/);
  assert.deepEqual(plain(notConfigured), plain(notEnabled));

  // not_live (409 while provisioning) gets the same honest copy as the w5 update trio
  assert.match(hooks.rollbackConflictCopy("not_live").title, /isn't live yet/);

  assert.match(hooks.rollbackConflictCopy("instance_unreachable").title, /Couldn't reach the instance/);
  assert.match(hooks.rollbackConflictCopy("instance_error").title, /rejected the rollback/);

  // unknown / absent code → a safe generic terminal copy, never a crash
  assert.match(hooks.rollbackConflictCopy(undefined).title, /Couldn't start the rollback/);
  assert.match(hooks.rollbackConflictCopy("wat", null).title, /Couldn't start the rollback/);

  // NO force affordance on any branch — a rollback refusal is always terminal
  for (const code of ["no_previous_slot", "already_running", "not_supported", "not_live",
    "not_enabled", "feature_not_configured", "instance_unreachable", "instance_error", "wat"]) {
    assert.equal(hooks.rollbackConflictCopy(code).forceLabel, undefined, code + " must not offer force");
  }
});

test("isu-w6: rollbackConflictCopy embeds NO server free-text — copy is static (no injection surface)", () => {
  // The raw envelope may carry hostile strings; the classifier must NEVER splice
  // them into its title/body (they'd reach a toast). Every branch stays static.
  const hostile = { error: { code: "instance_error", message: "<script>alert(1)</script>" } };
  const copy = hooks.rollbackConflictCopy("instance_error", hostile);
  assert.doesNotMatch(copy.title + copy.body, /<script/);
  assert.doesNotMatch(copy.title + copy.body, /alert\(1\)/);
});

// ── w6 (OC25): webhook full-edit — Edit action + pre-fill + PUT-body builder ──

test("webhookCardHtml carries an Edit action alongside toggle/rotate/deliveries/delete", () => {
  const html = hooks.webhookCardHtml(
    { id: "wh1", name: "Prod hook", url: "https://x/h", active: true, events: [] }, "abc", "production");
  assert.match(html, /data-wh-edit>Edit</);
  // Edit sits FIRST in the action bar (the primary configuration action).
  assert.ok(html.indexOf("data-wh-edit") < html.indexOf("data-wh-toggle"),
    "Edit should precede the toggle in the action bar");
});

test("webhookEventPickHtml: renders every event; only the selected ones are checked", () => {
  const none = hooks.webhookEventPickHtml([]);
  for (const e of ["create", "update", "publish", "unpublish", "delete", "discardDraft", "patch"]) {
    assert.match(none, new RegExp('value="' + e + '"'));
  }
  assert.doesNotMatch(none, /checked/); // nothing selected → no checked boxes
  const some = hooks.webhookEventPickHtml(["create", "publish"]);
  assert.match(some, /value="create"\s+checked/);
  assert.match(some, /value="publish"\s+checked/);
  assert.doesNotMatch(some, /value="update"\s+checked/); // an unselected event stays unchecked
});

test("webhookEditFormHtml pre-fills name/url/types and checks the subscribed events (escaped)", () => {
  const html = hooks.webhookEditFormHtml({
    name: "Prod <hook>", url: "https://x/h?a=1&b=2", events: ["publish"], types: ["post", "page"],
  });
  assert.match(html, /id="wh-edit-form"/);
  assert.match(html, /id="wh-e-name"[^>]*value="Prod &lt;hook&gt;"/); // hostile name escaped, not injected
  assert.doesNotMatch(html, /<hook>/);
  assert.match(html, /id="wh-e-url"[^>]*value="https:\/\/x\/h\?a=1&amp;b=2"/);
  assert.match(html, /id="wh-e-types"[^>]*value="post, page"/); // comma-joined types
  assert.match(html, /value="publish"\s+checked/);
  assert.doesNotMatch(html, /value="create"\s+checked/);
  assert.match(html, />Save changes</); // the edit CTA, distinct from create
});

test("webhookEditFormHtml on a bare row: empty fields, no checked events, no crash", () => {
  const html = hooks.webhookEditFormHtml({ id: "wh9" });
  assert.match(html, /id="wh-e-name"[^>]*value=""/);
  assert.match(html, /id="wh-e-url"[^>]*value=""/);
  assert.match(html, /id="wh-e-types"[^>]*value=""/);
  assert.doesNotMatch(html, /checked/);
  // Fully null-safe (no argument at all).
  assert.match(hooks.webhookEditFormHtml(), /id="wh-edit-form"/);
});

test("webhookEditBody builds the FULL edited body — name/url trimmed, events/types arrays", () => {
  const body = hooks.webhookEditBody({
    name: "  Renamed  ", url: "  https://new/h  ",
    events: ["create", "publish"], types: [" post ", "page", ""],
  });
  assert.equal(body.name, "Renamed");
  assert.equal(body.url, "https://new/h"); // trimmed
  assert.deepEqual([...body.events], ["create", "publish"]);
  assert.deepEqual([...body.types], ["post", "page"]); // trimmed, blanks dropped
});

test("webhookEditBody: an emptied subscription sends [] (an edit can CLEAR a filter, not only add)", () => {
  const body = hooks.webhookEditBody({ name: "n", url: "https://u", events: [], types: [] });
  assert.deepEqual([...body.events], []);
  assert.deepEqual([...body.types], []);
  // Fully null-safe: a missing state yields empty arrays + empty strings, never a throw.
  const bare = hooks.webhookEditBody();
  assert.equal(bare.name, "");
  assert.equal(bare.url, "");
  assert.deepEqual([...bare.events], []);
  assert.deepEqual([...bare.types], []);
});

// ── cloud console interaction harness: programmed fetch + selector/listeners ─

function programmedFetch() {
  const queue = [];
  const requests = [];
  return {
    queue,
    requests,
    fetch(path, init = {}) {
      const raw = init.body;
      requests.push({
        path: String(path),
        method: init.method || "GET",
        body: raw == null ? null : JSON.parse(raw),
        headers: { ...(init.headers || {}) },
      });
      if (!queue.length) return Promise.reject(new Error("unprogrammed fetch: " + path));
      const next = queue.shift();
      if (next.reject) return Promise.reject(next.reject);
      const status = next.status == null ? (next.ok === false ? 500 : 200) : next.status;
      return Promise.resolve({
        ok: next.ok == null ? status >= 200 && status < 300 : next.ok,
        status,
        headers: { get(name) { return String(name).toLowerCase() === "content-type" ? "application/json" : null; } },
        json() { return Promise.resolve(next.json == null ? {} : next.json); },
      });
    },
  };
}

function selectorMatches(el, rawSelector) {
  const full = rawSelector.trim();
  if (full.includes(",")) return full.split(",").some((part) => selectorMatches(el, part));
  const selector = full.split(/\s+/).at(-1);
  if (selector.startsWith("#")) return el.id === selector.slice(1);
  if (selector.startsWith(".")) return String(el.className || "").split(/\s+/).includes(selector.slice(1));
  const attr = selector.match(/^([a-z]+)?\[([^=\]]+)(?:="([^"]*)")?\]$/i);
  if (attr) {
    if (attr[1] && el.tagName !== attr[1].toUpperCase()) return false;
    const got = el.getAttribute(attr[2]);
    return attr[3] == null ? got != null : got === attr[3];
  }
  return el.tagName === selector.toUpperCase();
}

function interactionElement(tag = "div", initial = {}) {
  const listeners = new Map();
  const attrs = new Map();
  const el = {
    tagName: tag.toUpperCase(), id: "", className: "", value: "", textContent: "",
    hidden: false, disabled: false, checked: false, children: [], parentNode: null,
    style: {}, classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    addEventListener(type, fn) { listeners.set(type, fn); },
    removeEventListener(type) { listeners.delete(type); },
    dispatch(type, extra = {}) {
      const event = { type, target: el, key: extra.key, shiftKey: !!extra.shiftKey,
        defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...extra };
      const fn = listeners.get(type);
      if (fn) fn(event);
      return event;
    },
    click() { if (!el.disabled) el.dispatch("click"); },
    focus() {},
    setAttribute(name, value) {
      attrs.set(name, String(value));
      if (name === "id") el.id = String(value);
      if (name === "class") el.className = String(value);
    },
    getAttribute(name) {
      if (name === "id") return el.id || null;
      if (name === "class") return el.className || null;
      return attrs.has(name) ? attrs.get(name) : null;
    },
    hasAttribute(name) { return attrs.has(name); },
    removeAttribute(name) { attrs.delete(name); },
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) { el.children = el.children.filter((x) => x !== child); el._nodes = (el._nodes || []).filter((x) => x !== child); child.parentNode = null; },
    replaceChild(fresh, old) {
      fresh.parentNode = el;
      el.children = el.children.map((x) => x === old ? fresh : x);
      el._nodes = (el._nodes || []).map((x) => x === old ? fresh : x);
      old.parentNode = null;
    },
    querySelector(selector) { return (el._nodes || []).find((node) => selectorMatches(node, selector)) || null; },
    querySelectorAll(selector) { return (el._nodes || []).filter((node) => selectorMatches(node, selector)); },
    _nodes: [], _source: "", firstChild: null,
  };
  Object.assign(el, initial);
  let inner = "";
  Object.defineProperty(el, "innerHTML", {
    get() { return inner; },
    set(html) {
      inner = String(html || "");
      el._source = inner;
      el._nodes = [];
      el.children = [];
      el.firstChild = null;
      const tags = inner.matchAll(/<(div|span|button|input|form|code)\b([^>]*)>([^<]*)/gi);
      for (const match of tags) {
        const node = interactionElement(match[1]);
        const rawAttrs = match[2];
        for (const a of rawAttrs.matchAll(/([:\w-]+)(?:="([^"]*)")?/g)) {
          node.setAttribute(a[1], a[2] == null ? "" : a[2]);
          if (a[1] === "value") node.value = a[2] || "";
          if (a[1] === "checked") node.checked = true;
          if (a[1] === "disabled") node.disabled = true;
          if (a[1] === "hidden") node.hidden = true;
        }
        node.textContent = match[3].replace(/&hellip;/g, "…").replace(/&times;/g, "×");
        el._nodes.push(node);
      }
      const card = el._nodes.find((node) => selectorMatches(node, ".wh-card"));
      if (card) {
        card._source = inner;
        card._nodes = el._nodes.filter((node) => node !== card);
        card.parentNode = el;
        el.children.push(card);
        el.firstChild = card;
      } else if (el._nodes.length) {
        el.firstChild = el._nodes[0];
        el._nodes.forEach((node) => { node.parentNode = el; });
      }
    },
  });
  return el;
}

function installInteractionHarness() {
  const prior = {
    fetch: sandbox.fetch,
    createElement: sandbox.document.createElement,
    querySelector: sandbox.document.querySelector,
    querySelectorAll: sandbox.document.querySelectorAll,
    getElementById: sandbox.document.getElementById,
    activeElement: sandbox.document.activeElement,
  };
  const net = programmedFetch();
  const modalRoot = interactionElement("div", { id: "modal-root", hidden: true });
  const modalBody = interactionElement("div", { id: "modal-body" });
  const appShell = interactionElement("div", { id: "app-shell" });
  const toastStack = interactionElement("div", { id: "toast-stack" });
  const fixed = [modalRoot, modalBody, appShell, toastStack];
  sandbox.fetch = net.fetch;
  sandbox.document.createElement = (tag) => interactionElement(tag);
  sandbox.document.querySelector = (selector) => fixed.find((el) => selectorMatches(el, selector)) || modalBody.querySelector(selector);
  sandbox.document.querySelectorAll = (selector) => modalBody.querySelectorAll(selector);
  sandbox.document.getElementById = (id) => fixed.find((el) => el.id === id) || modalBody.querySelector("#" + id);
  sandbox.document.activeElement = null;
  return {
    ...net, modalRoot, modalBody, toastStack,
    cleanup() { Object.assign(sandbox.document, prior); sandbox.fetch = prior.fetch; },
  };
}

function webhookList(wh) {
  const root = interactionElement("section");
  const list = interactionElement("div", { className: "wh-list", parentNode: root });
  root._nodes = [list];
  list.innerHTML = hooks.webhookCardHtml(wh, "demo", "production");
  return { root, list, card: () => list.querySelectorAll(".wh-card")[0] || null };
}

async function settleInteraction() {
  for (let i = 0; i < 8; i += 1) await Promise.resolve();
}

function plainRequest(request) {
  return JSON.parse(JSON.stringify(request));
}

const interactionBp = { id: "bp 7", name: "demo" };
const interactionWh = { id: "wh/1", name: "Prod hook", url: "https://example.test/hook", active: true, events: ["publish"], types: ["post"] };

test("interaction toggle records PUT body and reconciles success or restores failure controls", async () => {
  for (const succeeds of [true, false]) {
    const h = installInteractionHarness();
    try {
      const ui = webhookList(interactionWh);
      h.queue.push(succeeds
        ? { json: { data: { webhook: { ...interactionWh, active: false } } } }
        : { ok: false, status: 422, json: { error: { code: "validation_failed" } } });
      hooks.wireWebhookCard(ui.list, interactionBp, "production", interactionWh);
      const button = ui.card().querySelector("[data-wh-toggle]");
      button.dispatch("click");
      await settleInteraction();
      const req = plainRequest(h.requests[0]);
      assert.deepEqual({ path: req.path, method: req.method, body: req.body }, {
        path: "/v1/barkparks/bp%207/api/webhooks/wh%2F1?dataset=production", method: "PUT", body: { active: false },
      });
      if (succeeds) {
        assert.match(ui.card()._source, /Disabled/);
        assert.match(h.toastStack.children.at(-1).innerHTML, /Webhook disabled/);
      } else {
        assert.equal(button.disabled, false);
        assert.equal(button.textContent, "Disable");
        assert.equal(ui.card().querySelector(".wh-toggle-note").hidden, false);
        assert.match(h.toastStack.children.at(-1).innerHTML, /Couldn&#39;t disable/);
      }
    } finally { h.cleanup(); }
  }
});

test("interaction rotate records POST {} and shows secret or restores failure controls", async () => {
  for (const succeeds of [true, false]) {
    const h = installInteractionHarness();
    try {
      const ui = webhookList(interactionWh);
      h.queue.push(succeeds
        ? { json: { data: { secret: "sec_once", webhook: interactionWh } } }
        : { ok: false, status: 503, json: { error: { code: "instance_unreachable" } } });
      hooks.wireWebhookCard(ui.list, interactionBp, "production", interactionWh);
      const button = ui.card().querySelector("[data-wh-rotate]");
      button.dispatch("click");
      await settleInteraction();
      const req = plainRequest(h.requests[0]);
      assert.deepEqual({ path: req.path, method: req.method, body: req.body }, {
        path: "/v1/barkparks/bp%207/api/webhooks/wh%2F1/rotate?dataset=production", method: "POST", body: {},
      });
      if (succeeds) {
        assert.equal(h.modalRoot.hidden, false);
        assert.match(h.modalBody.innerHTML, /sec_once/);
      } else {
        assert.equal(button.disabled, false);
        assert.equal(button.textContent, "Rotate secret");
        assert.match(h.toastStack.children.at(-1).innerHTML, /Couldn&#39;t rotate/);
      }
    } finally { h.cleanup(); }
  }
});

test("interaction delete unlocks by exact name, records DELETE null, then removes or reports inline", async () => {
  for (const succeeds of [true, false]) {
    const h = installInteractionHarness();
    try {
      const ui = webhookList(interactionWh);
      h.queue.push(succeeds ? { status: 204 } : { ok: false, status: 409, json: { error: { code: "upstream_error" } } });
      hooks.wireWebhookCard(ui.list, interactionBp, "production", interactionWh);
      ui.card().querySelector("[data-wh-delete]").dispatch("click");
      const input = h.modalBody.querySelector("#wh-del-confirm");
      const go = h.modalBody.querySelector("#wh-del-go");
      assert.equal(go.disabled, true);
      input.value = interactionWh.name;
      input.dispatch("input");
      assert.equal(go.disabled, false);
      go.dispatch("click");
      await settleInteraction();
      const req = plainRequest(h.requests[0]);
      assert.deepEqual({ path: req.path, method: req.method, body: req.body }, {
        path: "/v1/barkparks/bp%207/api/webhooks/wh%2F1?dataset=production", method: "DELETE", body: null,
      });
      if (succeeds) {
        assert.equal(h.modalRoot.hidden, true);
        assert.equal(ui.card(), null);
        assert.match(h.toastStack.children.at(-1).innerHTML, /Webhook deleted/);
      } else {
        assert.equal(h.modalRoot.hidden, false);
        assert.equal(go.disabled, false);
        assert.equal(go.textContent, "Delete webhook");
        assert.equal(h.modalBody.querySelector("#wh-del-error").hidden, false);
      }
    } finally { h.cleanup(); }
  }
});

test("interaction edit opens prefilled form and submit records full PUT with success/failure modal behavior", async () => {
  for (const succeeds of [true, false]) {
    const h = installInteractionHarness();
    try {
      const ui = webhookList(interactionWh);
      h.queue.push(succeeds ? { json: { data: { webhook: interactionWh } } } : { ok: false, status: 422, json: { error: { code: "validation_failed" } } });
      if (succeeds) h.queue.push({ json: { data: { webhooks: [] } } });
      hooks.wireWebhookCard(ui.list, interactionBp, "production", interactionWh);
      ui.card().querySelector("[data-wh-edit]").dispatch("click");
      assert.match(h.modalBody.innerHTML, /value="Prod hook"/);
      h.modalBody.querySelector("#wh-e-name").value = "Renamed";
      h.modalBody.querySelector("#wh-e-url").value = "https://new.test/h";
      h.modalBody.querySelector("#wh-e-types").value = "post, page";
      for (const cb of h.modalBody.querySelectorAll(".wh-event-cb")) cb.checked = cb.value === "publish" || cb.value === "update";
      h.modalBody.querySelector("#wh-edit-form").dispatch("submit");
      await settleInteraction();
      const req = plainRequest(h.requests[0]);
      assert.deepEqual({ path: req.path, method: req.method, body: req.body }, {
        path: "/v1/barkparks/bp%207/api/webhooks/wh%2F1?dataset=production", method: "PUT",
        body: { name: "Renamed", url: "https://new.test/h", events: ["update", "publish"], types: ["post", "page"] },
      });
      if (succeeds) {
        assert.equal(h.modalRoot.hidden, true);
        assert.match(h.toastStack.children.at(-1).innerHTML, /Webhook updated/);
        assert.equal(h.requests[1].method, "GET");
      } else {
        assert.equal(h.modalRoot.hidden, false);
        assert.equal(h.modalBody.querySelector('#wh-edit-form button[type="submit"]').disabled, false);
        assert.equal(h.modalBody.querySelector("#wh-e-error").hidden, false);
      }
    } finally { h.cleanup(); }
  }
});

test("interaction replay is wired from rendered delivery markup and records POST {} with reload/restore", async () => {
  for (const succeeds of [true, false]) {
    const h = installInteractionHarness();
    try {
      const ui = webhookList(interactionWh);
      const deliveries = { deliveries: [{ event_id: "ev/9", status: "ok", attempts: 1 }] };
      h.queue.push({ json: { data: deliveries } });
      h.queue.push(succeeds ? { json: { ok: true } } : { ok: false, status: 503, json: { error: { code: "instance_unreachable" } } });
      if (succeeds) h.queue.push({ json: { data: deliveries } });
      hooks.loadDeliveries(ui.list, interactionBp, "production", interactionWh);
      await settleInteraction();
      const replay = ui.card().querySelector("[data-wh-deliveries-box]").querySelector("[data-wh-replay]");
      assert.ok(replay, "rendered delivery row must expose its replay selector");
      replay.dispatch("click");
      await settleInteraction();
      const req = plainRequest(h.requests[1]);
      assert.deepEqual({ path: req.path, method: req.method, body: req.body }, {
        path: "/v1/barkparks/bp%207/api/webhooks/wh%2F1/deliveries/ev%2F9/replay?dataset=production", method: "POST", body: {},
      });
      if (succeeds) {
        assert.equal(h.requests.length, 3);
        assert.equal(h.requests[2].method, "GET");
        assert.match(h.toastStack.children.at(-1).innerHTML, /Replayed/);
      } else {
        assert.equal(replay.disabled, false);
        assert.equal(replay.textContent, "Replay");
        assert.match(h.toastStack.children.at(-1).innerHTML, /Couldn&#39;t replay/);
      }
    } finally { h.cleanup(); }
  }
});

test("interaction harness requires the guarded webhook action surface", () => {
  for (const name of [
    "wireWebhookCard", "toggleWebhook", "rotateWebhook",
    "openEditWebhookModal", "submitEditWebhook", "confirmDeleteWebhook",
    "deleteWebhook", "loadDeliveries", "replayDelivery",
  ]) {
    assert.equal(typeof hooks[name], "function", name + " must be test-hook exported");
  }
});

// ── search-template W2 (D8): create-site modal pure helpers ─────────────────

test("siteKindFor mirrors the engine defaults (astro static, everything else node)", () => {
  assert.equal(hooks.siteKindFor("astro"), "static");
  assert.equal(hooks.siteKindFor("nextjs"), "node");
});

test("siteTemplateOptions offers framework-matching starters, flagship on nextjs", () => {
  assert.deepEqual(plain(hooks.siteTemplateOptions("astro")), ["", "astro-starter"]);
  assert.deepEqual(plain(hooks.siteTemplateOptions("nextjs")), ["", "search-starter", "next-starter"]);
  assert.deepEqual(plain(hooks.siteTemplateOptions("hugo")), [""]);
});

test("siteCreateBody omits empty optionals and carries the template when picked", () => {
  const full = hooks.siteCreateBody({
    name: "my-search", framework: "nextjs", template: "search-starter",
    workspace: "default", project: "default", dataset: "production",
    doc_type: "entry", barkpark_id: "bp-1",
  });
  assert.deepEqual(plain(full), {
    name: "my-search", framework: "nextjs", kind: "node",
    workspace: "default", project: "default", dataset: "production",
    barkpark_id: "bp-1", template: "search-starter", doc_type: "entry",
  });
  const auto = hooks.siteCreateBody({
    name: "n", framework: "astro", template: "",
    workspace: "w", project: "p", dataset: "d", doc_type: "", barkpark_id: "b",
  });
  assert.equal(auto.kind, "static");
  assert.ok(!("template" in auto), "empty template must be omitted (framework-derived default)");
  assert.ok(!("doc_type" in auto), "empty doc_type must be omitted (server default)");
});

// ── W4: the SSE-driven deploy stage rail (charter D15-D17) ──────────────────
// The console's live twin of the /new timeline. These pin the PURE fold /
// signature / status / markup helpers; the EventSource wiring + DOM mount are
// browser-verified (the harness rule — only string-in/derivation helpers pin).

test("W4 rail: the six stages are PLAN→BUILD→STAGE→HEALTH→SWITCH→RETIRE (PROVISION silent)", () => {
  assert.deepEqual([...hooks.deployRailStages], ["PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"]);
});

test("W4 deployStageRole: engine status word → display role, unknown → pending", () => {
  assert.equal(hooks.deployStageRole("done"), "ok");
  assert.equal(hooks.deployStageRole("failed"), "failed");
  assert.equal(hooks.deployStageRole("running"), "active");
  assert.equal(hooks.deployStageRole("started"), "active");
  assert.equal(hooks.deployStageRole("skipped"), "skipped");
  assert.equal(hooks.deployStageRole("pending"), "pending");
  assert.equal(hooks.deployStageRole("wat"), "pending");
  assert.equal(hooks.deployStageRole(undefined), "pending");
});

test("W4 deployRailLedgerFromConsole: folds rail entries latest-wins, ignores non-rail lines", () => {
  const ledger = hooks.deployRailLedgerFromConsole([
    { stage: "PLAN", status: "done", detail: "planned" },
    { stage: "BUILD", status: "running", detail: "npm ci" },
    { stage: "BUILD", status: "done", detail: "built" }, // latest wins
    { stage: "NOISE", status: "done" },                  // not a rail stage → ignored
    { line: "raw log with no stage" },                   // ignored
    null,                                                 // tolerated
  ]);
  assert.equal(hooks.deployStageRole(ledger.PLAN.status), "ok");
  assert.equal(ledger.BUILD.status, "done");
  assert.equal(ledger.BUILD.detail, "built");
  assert.ok(!("NOISE" in ledger));
});

test("stw5 deployRailLedgerFromConsole: first entry stamps startedAt, terminal stamps finishedAt", () => {
  // The console carries a per-entry `at`; the fold keeps the FIRST `at` as the
  // stage start and the done/failed `at` as its finish — the two stamps the
  // completed-stage duration reads from (D23).
  const ledger = hooks.deployRailLedgerFromConsole([
    { stage: "BUILD", status: "running", detail: "npm ci", at: "2026-07-16T10:00:00Z" },
    { stage: "BUILD", status: "done", detail: "built", at: "2026-07-16T10:00:42Z" },
    { stage: "HEALTH", status: "running", detail: "probing", at: "2026-07-16T10:00:50Z" },
    { stage: "HEALTH", status: "failed", detail: "probe 500", at: "2026-07-16T10:01:05Z" },
    { stage: "SWITCH", status: "running", detail: "flipping", at: "2026-07-16T10:01:10Z" }, // no terminal
  ]);
  assert.equal(ledger.BUILD.startedAt, "2026-07-16T10:00:00Z");
  assert.equal(ledger.BUILD.finishedAt, "2026-07-16T10:00:42Z");
  assert.equal(ledger.HEALTH.startedAt, "2026-07-16T10:00:50Z");
  assert.equal(ledger.HEALTH.finishedAt, "2026-07-16T10:01:05Z"); // failed also stamps finish
  assert.equal(ledger.SWITCH.startedAt, "2026-07-16T10:01:10Z");
  assert.equal(ledger.SWITCH.finishedAt, null); // in-flight → no finish stamp
  // A stampless console (older event) folds to null stamps, never NaN.
  const bare = hooks.deployRailLedgerFromConsole([{ stage: "PLAN", status: "done", detail: "" }]);
  assert.equal(bare.PLAN.startedAt, null);
  assert.equal(bare.PLAN.finishedAt, null);
});

test("W4 deployRailRows: empty ledger → all six pending", () => {
  const rows = hooks.deployRailRows({});
  assert.equal(rows.length, 6);
  assert.ok(rows.every((r) => r.role === "pending"));
  assert.deepEqual([...rows.map((r) => r.step)], ["PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"]);
});

test("W4 deployRailRows: a mid-flight ledger folds to done/active/pending in order", () => {
  const rows = hooks.deployRailRows({
    PLAN: { status: "done", detail: "" },
    BUILD: { status: "done", detail: "" },
    STAGE: { status: "running", detail: "staging release" },
  });
  assert.deepEqual([...rows.map((r) => r.role)], ["ok", "ok", "active", "pending", "pending", "pending"]);
  assert.equal(rows[2].caption, "staging release");
});

test("stw5 deployRailRows: a completed stage carries its real duration; active/pending stay null", () => {
  // Seed via the console fold so the stamps flow end-to-end, then assert the
  // pinned elapsed math newStepsHtml renders through fmtDur (D23).
  const ledger = hooks.deployRailLedgerFromConsole([
    { stage: "PLAN", status: "running", detail: "", at: "2026-07-16T10:00:00Z" },
    { stage: "PLAN", status: "done", detail: "", at: "2026-07-16T10:00:03Z" },   // 3s
    { stage: "BUILD", status: "running", detail: "npm ci", at: "2026-07-16T10:00:03Z" },
    { stage: "BUILD", status: "done", detail: "", at: "2026-07-16T10:00:45Z" },   // 42s
    { stage: "STAGE", status: "failed", detail: "cp failed", at: "2026-07-16T10:00:50Z" }, // start=end → 0
    { stage: "HEALTH", status: "running", detail: "probing", at: "2026-07-16T10:00:55Z" }, // active
  ]);
  const rows = hooks.deployRailRows(ledger);
  assert.equal(rows[0].elapsedMs, 3000);  // PLAN done: 3s
  assert.equal(rows[1].elapsedMs, 42000); // BUILD done: 42s
  assert.equal(rows[2].elapsedMs, 0);     // STAGE failed, only a terminal stamp → 0, never NaN
  assert.ok(!Number.isNaN(rows[2].elapsedMs));
  assert.equal(rows[3].elapsedMs, null);  // HEALTH active → no duration (ETA/ring is backlog)
  assert.equal(rows[4].elapsedMs, null);  // SWITCH pending → null
  assert.equal(rows[5].elapsedMs, null);  // RETIRE pending → null
  // A completed stage with a missing stamp is an honest null (total-over-partial),
  // not a guessed or NaN duration.
  const bare = hooks.deployRailRows(hooks.deployRailLedgerFromConsole([{ stage: "PLAN", status: "done" }]));
  assert.equal(bare[0].elapsedMs, null);
});

test("W4 deployRailRows: a FAILED stage marks the stages after it skipped, not pending-forever", () => {
  const rows = hooks.deployRailRows({
    PLAN: { status: "done" }, BUILD: { status: "done" },
    STAGE: { status: "done" }, HEALTH: { status: "failed", detail: "probe 500" },
  });
  assert.deepEqual([...rows.map((r) => r.role)], ["ok", "ok", "ok", "failed", "skipped", "skipped"]);
});

// ── cch-w12-s4: the deploy rail paces off MEASURED medians, or refuses ──────
// The constants lied by an order of magnitude (BUILD advertised 120000ms
// against a live p50 of 14835ms). The server now publishes a measured table on
// GET /v1/barkparks; these cases pin the three things that make that safe: the
// rail prefers the table, falls back PER STAGE, and behaves byte-identically to
// today when the server sends nothing.
//
// NOTE: absorbServerStepEstimates mutates one module-level variable, so every
// case here resets it (absorbing an empty table clears it) before asserting.

test("cch-w12-s4 deployExpectedMs: with NO server table every stage reads its constant", () => {
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: {} } }); // reset
  assert.equal(hooks.deployExpectedMs("BUILD"), 120000);
  assert.equal(hooks.deployExpectedMs("HEALTH"), 18000);
  assert.equal(hooks.deployExpectedMs("PLAN"), 3000);
  assert.equal(hooks.deployExpectedMs("STAGE"), 8000);
  assert.equal(hooks.deployExpectedMs("SWITCH"), 3000);
  assert.equal(hooks.deployExpectedMs("RETIRE"), 4000);
});

test("cch-w12-s4 deployRailRows: no server table → rows still carry the constants (today's pacing, unchanged)", () => {
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: {} } });
  const rows = hooks.deployRailRows({});
  assert.deepEqual([...rows.map((r) => r.expectedMs)], [3000, 120000, 8000, 18000, 3000, 4000]);
  // A payload with no step_estimates at all (cold cache, older server) is a
  // no-op, not a wipe of whatever was already in hand.
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: { BUILD: 14835 } } });
  hooks.absorbServerStepEstimates({ barkparks: [] });
  assert.equal(hooks.deployExpectedMs("BUILD"), 14835);
});

test("cch-w12-s4 absorbServerStepEstimates: the measured table wins, and REFUSED stages fall back per step", () => {
  // Exactly the shape the Elixir fold publishes for the live cohort: the three
  // stages that cleared the policy, and nothing for the three it refused as
  // poll-cadence artifacts (RETIRE/STAGE/SWITCH, all pinned at ~2s).
  hooks.absorbServerStepEstimates({
    barkparks: [],
    step_estimates: {
      deploy: { BUILD: 14835, HEALTH: 2098, PLAN: 2046 },
      meta: { window_days: 30, refused: { STAGE: "cadence_quantized" } },
    },
  });
  const rows = hooks.deployRailRows({});
  const by = Object.fromEntries(rows.map((r) => [r.step, r.expectedMs]));
  assert.equal(by.BUILD, 14835);   // was 120000 — the headline lie
  assert.equal(by.HEALTH, 2098);   // was 18000
  assert.equal(by.PLAN, 2046);     // was 3000
  assert.equal(by.STAGE, 8000);    // refused → constant
  assert.equal(by.SWITCH, 3000);   // refused → constant
  assert.equal(by.RETIRE, 4000);   // refused → constant
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: {} } });
});

test("cch-w12-s4 absorbServerStepEstimates: a garbled table can never pace a row off NaN", () => {
  hooks.absorbServerStepEstimates({
    step_estimates: { deploy: { BUILD: "soon", HEALTH: -5, PLAN: 0, STAGE: null, SWITCH: NaN, RETIRE: Infinity } },
  });
  const rows = hooks.deployRailRows({});
  assert.deepEqual([...rows.map((r) => r.expectedMs)], [3000, 120000, 8000, 18000, 3000, 4000]);
  assert.ok(rows.every((r) => Number.isFinite(r.expectedMs)));
  // A non-object / absent table is inert too.
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: 7 } });
  assert.equal(hooks.deployExpectedMs("BUILD"), 120000);
  hooks.absorbServerStepEstimates(null);
  assert.equal(hooks.deployExpectedMs("BUILD"), 120000);
});

test("cch-w12-s4 the measured median reaches the rendered rail (the pending hint + the ETA)", () => {
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: { BUILD: 14835 } } });
  const rows = hooks.deployRailRows({ PLAN: { status: "done" }, BUILD: { status: "running" } });
  // provisionOverall's ETA is weighted by each row's OWN budget — with BUILD at
  // 14835ms instead of 120000ms the whole rail's remaining time collapses.
  const measured = hooks.provisionOverall(rows).etaMs;
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: {} } });
  const invented = hooks.provisionOverall(hooks.deployRailRows({
    PLAN: { status: "done" }, BUILD: { status: "running" },
  })).etaMs;
  assert.ok(measured < invented, `measured ETA ${measured} should undercut the invented ${invented}`);
  assert.ok(invented - measured > 100000, "the 120000→14835 correction should dominate the ETA");
});

test("cch-w12-s4 pickTables: the PROVISION fork is untouched by the server table (its cohort is four jobs)", () => {
  hooks.absorbServerStepEstimates({
    step_estimates: { deploy: { BUILD: 14835, PLAN: 2046 } },
  });
  const main = hooks.pickTables({});
  const support = hooks.pickTables({ fleet_role: "support" });
  assert.equal(main.expectedMs.create, 15000);
  assert.equal(main.expectedMs.secure, 45000);
  assert.equal(support.expectedMs.create, 20000);
  assert.equal(support.expectedMs.configure, 60000);
  // The deploy stages must not have leaked into a provision table.
  assert.equal(main.expectedMs.BUILD, 120000); // the shared constants map, NOT the measured 14835
  assert.equal(support.expectedMs.BUILD, undefined);
  // And a provision row still folds off the constant end to end.
  const rows = hooks.provisionSteps({ provision_steps: [] }, NOW);
  assert.equal(rows[0].expectedMs, 15000);
  hooks.absorbServerStepEstimates({ step_estimates: { deploy: {} } });
});

test("W4 deployRailSignature: stable across a no-op, moves when a role or caption changes", () => {
  const a = hooks.deployRailRows({ PLAN: { status: "done" } });
  const b = hooks.deployRailRows({ PLAN: { status: "done" } });
  assert.equal(hooks.deployRailSignature(a), hooks.deployRailSignature(b));
  const c = hooks.deployRailRows({ PLAN: { status: "done" }, BUILD: { status: "running" } });
  assert.notEqual(hooks.deployRailSignature(a), hooks.deployRailSignature(c));
});

test("W4 deployRailStatus: starting / active / live / failed(named)", () => {
  assert.equal(hooks.deployRailStatus(hooks.deployRailRows({})).text, "Starting…");
  const active = hooks.deployRailStatus(hooks.deployRailRows({ PLAN: { status: "done" }, BUILD: { status: "running" } }));
  assert.equal(active.tone, "active");
  assert.equal(active.text, "Build…");
  const live = hooks.deployRailStatus(hooks.deployRailRows({
    PLAN: { status: "done" }, BUILD: { status: "done" }, STAGE: { status: "done" },
    HEALTH: { status: "done" }, SWITCH: { status: "done" }, RETIRE: { status: "done" },
  }));
  assert.deepEqual({ tone: live.tone, text: live.text }, { tone: "live", text: "Live" });
  const failed = hooks.deployRailStatus(hooks.deployRailRows({ HEALTH: { status: "failed" } }));
  assert.equal(failed.tone, "failed");
  assert.equal(failed.text, "Deploy failed at Health check");
});

test("W4 deployRailHtml: renders the shared step component + a copyable live URL when done", () => {
  const doneRows = hooks.deployRailRows({
    PLAN: { status: "done" }, BUILD: { status: "done" }, STAGE: { status: "done" },
    HEALTH: { status: "done" }, SWITCH: { status: "done" }, RETIRE: { status: "done" },
  });
  const html = hooks.deployRailHtml(doneRows, { deploymentId: "d1", url: "https://acme.barkpark.cloud/sites/blog/" });
  assert.ok(html.includes("new-steps"), "reuses the /new step component");
  assert.ok(html.includes("data-rail-sig="), "carries the region-diff signature hook");
  assert.ok(html.includes('data-copy="https://acme.barkpark.cloud/sites/blog/"'), "live URL is copyable");
  // A failed rail shows the failure detail, never a dead end.
  const failHtml = hooks.deployRailHtml(hooks.deployRailRows({ HEALTH: { status: "failed", detail: "probe 500" } }),
    { deploymentId: "d1", failureDetail: "probe 500" });
  assert.ok(failHtml.includes("deploy-rail-fail"));
  assert.ok(failHtml.includes("probe 500"));
});

test("W4 railDeployment: picks the in-flight deployment, null when all terminal", () => {
  assert.equal(hooks.railDeployment([{ id: "a", status: "live" }, { id: "b", status: "failed" }]), null);
  const active = hooks.railDeployment([{ id: "a", status: "building" }, { id: "b", status: "live" }]);
  assert.equal(active.id, "a");
  assert.equal(hooks.railDeployment([]), null);
  assert.equal(hooks.railDeployment(null), null);
});

test("W4 instanceCanDeploy: true only when the instance has a URL (deploy 422s mid-provision)", () => {
  assert.equal(hooks.instanceCanDeploy({ url: "https://acme.barkpark.cloud" }), true);
  assert.equal(hooks.instanceCanDeploy({ url: "" }), false);
  assert.equal(hooks.instanceCanDeploy({}), false);
  assert.equal(hooks.instanceCanDeploy(null), false);
});

test("W4 rail reuses the min-dwell pacer: a fresh live transition dwells, then reads done", () => {
  // The rail runs deployRailRows through paceSteps (the same /new machinery), so
  // a step that just finished dwells as `completing` before the check lands.
  const ledger = {};
  const t0 = 900000;
  const truth = hooks.deployRailRows({ PLAN: { status: "done" } });
  const first = hooks.paceSteps(truth, ledger, t0);
  assert.equal(first[0].role, "active");
  assert.equal(first[0].completing, true);
  const after = hooks.paceSteps(truth, ledger, t0 + hooks.newStepMinDwellMs);
  assert.equal(after[0].role, "ok");
});

// ─────────────────────── stw4-freshness: site-row freshness badge (D24) ──────
// The server embeds a SLIM last_deployment (status/trigger/timestamps only). The
// badge pulses amber ONLY while a content-auto rebuild is in flight; every
// settled row states status · trigger · when; a never-deployed site gets nothing.

test("stw4 freshnessModel: nil-honest — no embed, no status → null (no badge)", () => {
  assert.equal(hooks.freshnessModel({}), null);
  assert.equal(hooks.freshnessModel({ last_deployment: null }), null);
  assert.equal(hooks.freshnessModel({ last_deployment: {} }), null);
  assert.equal(hooks.freshnessBadge({}), "");
});

test("stw4 freshnessModel: amber-pulse ONLY for an in-flight content-auto rebuild", () => {
  for (const status of ["queued", "building", "pushing"]) {
    const m = hooks.freshnessModel({ last_deployment: { status, trigger: "content-auto" } });
    assert.equal(m.rebuilding, true, status + " content-auto rebuilds");
    assert.equal(m.label, "Rebuilding");
    assert.equal(m.dot, "rebuild");
  }
  // A MANUAL in-flight deploy is NOT the amber rebuild pulse — it's a plain
  // "Deploying" (amber is reserved for the content-triggered rebuild).
  const manual = hooks.freshnessModel({ last_deployment: { status: "building", trigger: "manual" } });
  assert.equal(manual.rebuilding, false);
  assert.equal(manual.label, "Deploying");
  assert.equal(manual.dot, "deploy");
});

test("stw4 freshnessModel: settled rows state status · trigger · when", () => {
  const live = hooks.freshnessModel({ last_deployment: { status: "live", trigger: "content-auto", updated_at: new Date().toISOString() } });
  assert.equal(live.rebuilding, false);
  assert.equal(live.label, "Live");
  assert.equal(live.dot, "up");
  assert.match(live.meta, /^auto · /);
  const failed = hooks.freshnessModel({ last_deployment: { status: "failed", trigger: "manual", updated_at: new Date().toISOString() } });
  assert.equal(failed.label, "Deploy failed");
  assert.equal(failed.dot, "down");
  assert.match(failed.meta, /^manual · /);
});

test("stw4 freshnessBadge: is-rebuilding class + escaped, no content_rev leak", () => {
  const html = hooks.freshnessBadge({ last_deployment: { status: "building", trigger: "content-auto" } });
  assert.ok(html.includes("fresh-badge--rebuild"));
  assert.ok(html.includes("is-rebuilding"), "carries the pulse hook");
  assert.ok(html.includes("Rebuilding"));
  const settled = hooks.freshnessBadge({ last_deployment: { status: "live", trigger: "manual", updated_at: new Date().toISOString() } });
  assert.ok(settled.includes("fresh-badge--up"));
  assert.ok(!settled.includes("is-rebuilding"), "a settled row never pulses");
  // HONESTY LAW: the badge renders only status/trigger/time — a content_rev on the
  // embed (should never be there) is ignored, never surfaced.
  const sneaky = hooks.freshnessBadge({ last_deployment: { status: "live", trigger: "manual", updated_at: new Date().toISOString(), content_rev: "deadbeef" } });
  assert.ok(!sneaky.includes("deadbeef"), "content_rev never reaches the badge");
});

// ── E-01 (gr-p3): the v4 sites-list row + its leading deploy-status pill ─────

test("E-01 siteStatusPill: freshness → status-pill role, states-complete", () => {
  const roleOf = (last_deployment) => {
    const html = hooks.siteStatusPill(last_deployment ? { last_deployment } : {});
    const m = html.match(/status-pill--(\w+)/);
    return m && m[1];
  };
  assert.equal(roleOf({ status: "live", trigger: "content-auto", updated_at: new Date().toISOString() }), "ok");
  assert.equal(roleOf({ status: "building", trigger: "content-auto" }), "warn", "an in-flight rebuild is amber");
  assert.equal(roleOf({ status: "building", trigger: "manual" }), "info", "a plain deploy is info");
  assert.equal(roleOf({ status: "failed", trigger: "manual", updated_at: new Date().toISOString() }), "danger");
  // Nil-honest: a never-deployed site reads a neutral "Not deployed" — no
  // invented green.
  assert.equal(roleOf(null), "neutral");
  assert.ok(hooks.siteStatusPill({}).includes(">Not deployed<"), "never-deployed says so");
});

test("E-01 globalSiteRow: real fields only, v4 anatomy, no invented kind taxonomy", () => {
  const s = {
    id: "site-1", name: "acme-web", slug: "acme-web", framework: "nextjs",
    domains: ["acme.com"], github_webhook_configured: true,
    last_deployment: { status: "live", trigger: "content-auto", updated_at: new Date().toISOString() },
  };
  const bp = { id: "bp-1", name: "Production", slug: "production", host: "h" };
  const html = hooks.globalSiteRow(s, bp);
  assert.ok(html.includes('class="site-row site-row--global"'), "the v4 density row");
  assert.ok(html.includes("status-pill--ok"), "the leading deploy-status pill");
  assert.ok(html.includes(">acme-web<"), "the site's own name, not a domain");
  assert.ok(html.includes('class="site-host"') && html.includes("acme.com"), "the live host");
  assert.ok(html.includes("nextjs"), "the framework");
  assert.ok(html.includes('class="site-inst-link" href="#instance/bp-1"'), "on <instance> is a real link");
  assert.ok(html.includes(">Production</a>"), "the instance name renders in the link");
  assert.ok(html.includes("updated "), "the recency segment");
  assert.ok(html.includes("Auto-deploy"), "the auto-deploy capability chip");
  // GR28: the invented Marketing/Docs/Blank kind taxonomy has no field, so a
  // row NEVER carries a kind label or template picker.
  assert.ok(!/\bMarketing\b|\bDocs\b|\bBlank\b|template picker|site-kind|data-site-kind/i.test(html),
    "no invented site-kind taxonomy");
});

test("E-01 globalSiteRow: no instance → honest 'on —', never a fabricated instance", () => {
  const html = hooks.globalSiteRow({ id: "s", name: "orphan", framework: "astro", domains: [] }, null);
  assert.ok(html.includes("on —"), "an unresolved instance reads a dash, not an invented name");
  assert.ok(!html.includes("site-inst-link"), "no dead link when the instance is unknown");
});

// ── E-03 (gr-p3): the write-only env editor — KEY=VALUE parser + modal body ──

test("E-03 parseEnvBlob: valid KEY=VALUE lines → env map; blanks + #comments skipped", () => {
  const r = hooks.parseEnvBlob("# a comment\nFOO=bar\n\n  BAZ = qux \nEMPTY=");
  assert.equal(r.ok, true);
  // (Assert keys individually — the vm realm's object has a cross-realm
  // prototype that deepStrictEqual would reject.)
  assert.deepEqual(Object.keys(r.env).sort(), ["BAZ", "EMPTY", "FOO"]);
  assert.equal(r.env.FOO, "bar");
  assert.equal(r.env.BAZ, " qux ", "value is verbatim after the first '=' (only the key is trimmed)");
  assert.equal(r.env.EMPTY, "");
});

test("E-03 parseEnvBlob: a value may contain '='; only the first splits", () => {
  const r = hooks.parseEnvBlob("DATABASE_URL=postgres://u:p@h/db?sslmode=require");
  assert.equal(r.ok, true);
  assert.equal(r.env.DATABASE_URL, "postgres://u:p@h/db?sslmode=require");
});

test("E-03 parseEnvBlob: a bad line fails the WHOLE parse (no partial replace)", () => {
  const noEq = hooks.parseEnvBlob("FOO=bar\njust-a-word");
  assert.equal(noEq.ok, false);
  assert.match(noEq.error, /Line 2/, "the error names the offending line");
  const badKey = hooks.parseEnvBlob("1BAD=x");
  assert.equal(badKey.ok, false);
  assert.match(badKey.error, /not a valid variable name/);
  const spacedKey = hooks.parseEnvBlob("HAS SPACE=x");
  assert.equal(spacedKey.ok, false, "a key with whitespace is rejected");
});

test("E-03 envModalBodyHtml: write-only law verbatim, BLANK textarea, backend-true button copy", () => {
  const html = hooks.envModalBodyHtml({ name: "acme-web" });
  // The replace-set / write-only / no-read-back law, verbatim.
  assert.ok(html.includes("Saving replaces the whole set — values are write-only, so anything you leave out is removed."));
  assert.ok(html.includes("Current values can’t be read back."));
  // GR28: the textarea starts BLANK (there is no read-back to pre-fill).
  const ta = html.match(/<textarea[^>]*id="site-env-text"[^>]*>([\s\S]*?)<\/textarea>/);
  assert.ok(ta && ta[1] === "", "the textarea has no pre-filled content");
  // Backend-true: "Replace env" — the route queues NO deploy, so no redeploy claim.
  assert.ok(html.includes(">Replace env</button>"));
  assert.ok(!/redeploy/i.test(html), "the button never claims a redeploy the route doesn't do");
  // GR27: one blob — no production/preview scope UI.
  assert.ok(!/\bpreview\b|scope/i.test(html), "no invented env scopes");
});

// ── I-01 (gr-p3): the Activity feed — audit normalization + by-target fold ───

test("I-01 auditEntry: an audit row → the mergeTimeline audit-entry shape", () => {
  const e = hooks.auditEntry({
    id: "a1", action: "site.deploy_requested", inserted_at: "2026-07-19T00:00:00Z",
    actor: { id: "u", email: "ada@acme.com" }, target_type: "site", target_id: "s7", metadata: { git_ref: "abc" },
  });
  assert.equal(e.source, "audit");
  assert.equal(e.key, "a:a1");
  assert.equal(e.type, "site.deploy_requested");
  assert.equal(e.actor, "ada@acme.com", "actor is backend-true (audit_json's actor.email)");
  assert.equal(e.target, "site:s7", "target is <type>:<id> for the by-target coalesce key");
  // A target-less row (no target_id) degrades to null — the by-target key then
  // falls back to the type key (never a fabricated target).
  const noTarget = hooks.auditEntry({ id: "a2", action: "subscription.activated", target_type: "subscription", target_id: null });
  assert.equal(noTarget.target, null);
});

test("I-01 coalesceEntries by target: same target folds, unrelated targets never merge", () => {
  const mk = (id, target) => hooks.auditEntry({ id, action: "site.deploy_requested", actor: { email: "ada@acme.com" }, target_type: "site", target_id: target });
  // Three deploys of site A (consecutive) then one of site B.
  const entries = [mk("1", "A"), mk("2", "A"), mk("3", "A"), mk("4", "B")];
  const out = hooks.coalesceEntries(entries, hooks.tlvCoalesceKeyByTarget);
  // One ×3 group (site A) + one singleton (site B) = 2 render items.
  assert.equal(out.length, 2, "the A-run folds, B stays separate");
  assert.equal(out[0].group, true, "the same-target run is a group");
  assert.equal(out[0].count, 3, "the group folds all three A deploys");
  assert.ok(!out[1].group, "the different-target deploy is a singleton, never folded in");
  // Same actions on different targets must NOT fold even when adjacent.
  const split = hooks.coalesceEntries([mk("5", "A"), mk("6", "B")], hooks.tlvCoalesceKeyByTarget);
  assert.equal(split.length, 2, "adjacent but different targets never merge");
});

test("I-01 activityFiltersHtml: three server-true axes, each with exactly one active chip", () => {
  const html = hooks.activityFiltersHtml();
  assert.ok(html.includes('data-actfilter-axis="target_type"'), "the target_type axis");
  assert.ok(html.includes('data-actfilter="barkpark"'), "Instances → target_type=barkpark");
  assert.ok(html.includes('data-actfilter="site"'), "Sites → target_type=site");
  // GR80 leg 2: the two axes the server gained. Both are real query params on
  // GET /v1/audit, applied inside the Ecto query — never a client-side sieve.
  assert.ok(html.includes('data-actfilter-axis="action_prefix"'), "the action_prefix axis");
  assert.ok(html.includes('data-actfilter="site.deploy"'), "Deploys → action_prefix=site.deploy");
  assert.ok(html.includes('data-actfilter-axis="actor_user_id"'), "the actor_user_id axis");
  // Exactly one chip active PER AXIS — three axes, three "all" chips lit.
  assert.equal((html.match(/actfilter-chip is-active/g) || []).length, 3, "one chip active per axis");
  // Every chip is a STATIC per-branch class literal (never "actfilter-chip" +
  // modifier) — the __css_check E3 discipline this row has carried since I-01.
  assert.ok(!/actfilter-chip"\s*\+/.test(html), "no concat modifier leaked into a class");
});

test("GR80 leg 2: every action_prefix chip value is a real prefix of the closed audit vocabulary", () => {
  // The server LIKE-matches '<prefix>%' with metacharacters escaped, so a prefix
  // that no action starts with renders a permanently-empty feed that reads as a
  // bug. These are the AuditEvent @actions nouns the chips claim.
  const ACTIONS = ["site.deploy_requested", "webhook.created", "webhook.test_sent",
    "member.invited", "token.minted", "subscription.activated"];
  for (const f of hooks.activityActionFilters) {
    if (f.prefix === null) continue;
    assert.ok(ACTIONS.some((a) => a.startsWith(f.prefix)),
      "action_prefix " + JSON.stringify(f.prefix) + " must prefix a real action");
  }
});

test("GR80 leg 2: activityQuery sends every set axis and omits every unset one", () => {
  const st = hooks.activityFilterState;
  const reset = () => { st.target_type = null; st.actor_user_id = null; st.action_prefix = null; };
  reset();
  const bare = hooks.activityQuery(null);
  assert.ok(!/target_type|actor_user_id|action_prefix|before/.test(bare), "unfiltered page one is bare: " + bare);

  st.target_type = "site";
  st.action_prefix = "site.deploy";
  st.actor_user_id = "9f1c2d3e-0000-4000-8000-000000000001";
  const filtered = hooks.activityQuery(null);
  assert.ok(filtered.includes("&target_type=site"), filtered);
  assert.ok(filtered.includes("&actor_user_id=9f1c2d3e-0000-4000-8000-000000000001"), filtered);
  assert.ok(filtered.includes("&action_prefix=site.deploy"), filtered);

  // Load more keeps every axis AND adds the keyset cursor — the filtered TRAIL
  // pages, not one page of it.
  const more = hooks.activityQuery("2026-07-19T10:00:00.000000Z");
  assert.ok(more.includes("&action_prefix=site.deploy") && more.includes("&before=2026-07-19T10%3A00%3A00.000000Z"), more);
  reset();
});

test("keyset tiebreak: the activity cursor sends before_id, and auditEntry carries the id", () => {
  const st = hooks.activityFilterState;
  const reset = () => { st.target_type = null; st.actor_user_id = null; st.action_prefix = null; };
  reset();

  const pair = hooks.activityQuery("2026-07-19T10:00:00.000000Z", "a7");
  assert.ok(pair.includes("&before=2026-07-19T10%3A00%3A00.000000Z") && pair.includes("&before_id=a7"), pair);

  // BACKWARD COMPATIBLE: the stamp alone is still a legal cursor.
  const stampOnly = hooks.activityQuery("2026-07-19T10:00:00.000000Z", null);
  assert.ok(stampOnly.includes("&before=") && !stampOnly.includes("before_id"), stampOnly);

  // before_id without a stamp is meaningless and is never sent.
  assert.ok(!hooks.activityQuery(null, "a7").includes("before"), "no stamp → no cursor at all");

  // The entry keeps the raw row id, which is where loadMoreActivity reads the
  // second half of the cursor from.
  const e = hooks.auditEntry({ id: "a7", action: "site.created", inserted_at: "2026-07-19T10:00:00Z" });
  assert.equal(e.id, "a7");
  assert.equal(hooks.auditEntry({ action: "site.created" }).id, null, "no id → no fabricated cursor half");
  reset();
});

test("GR80 leg 2: the actor axis degrades to Everyone/Just me with no member list", () => {
  const meEnv = { user: { id: "usr_ada", email: "ada@acme.com" } };
  const bare = hooks.activityActorFilters(null, meEnv);
  assert.equal(bare.map((f) => f.label).join("|"), "Everyone|Just me", "no members → the one actor we can name");
  assert.equal(bare[1].id, "usr_ada");

  // With members, the caller is still "Just me" (never listed twice) and the
  // others read as their email local-part.
  const full = hooks.activityActorFilters(
    [{ user_id: "usr_ada", email: "ada@acme.com" }, { user_id: "usr_bob", email: "bob@acme.com" }], meEnv);
  assert.equal(full.map((f) => f.label).join("|"), "Everyone|Just me|bob");
  // A member with no email and no id degrades honestly rather than rendering blank.
  const odd = hooks.activityActorFilters([{ user_id: "usr_zed" }, {}], meEnv);
  assert.equal(odd.map((f) => f.label).join("|"), "Everyone|usr_zed");
});

// ── cch-w12-s1: the cold-boot Who axis ──────────────────────────────────────
// The wiring these pin is BROWSER-DRIVEN in the slice's evidence (Chrome on
// __preview__/serve.mjs, cold #activity vs a warm control, plus a one-shot 500
// on /members). ensureActivityActors / loadMe are fetch-and-DOM bound, so what
// a node harness can hold still is the SHAPE that made the lie possible:
// where the latch is set relative to the guard, and which views loadMe repaints.
// Region-scoped source assertions, the same instrument as the GR52b 2FA pins.

function appRegion(src, from, to) {
  const start = src.indexOf(from);
  const end = src.indexOf(to, start + 1);
  assert.ok(start > 0 && end > start, "region " + JSON.stringify(from) + " must be locatable");
  return src.slice(start, end);
}

test("cch-w12-s1: the members latch means 'a fetch was ISSUED' — set BELOW the team-id guard, cleared on failure", () => {
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  const region = appRegion(src, "function ensureActivityActors(", "function activityFiltered(");
  const guard = region.indexOf("if (!tid) return");
  const latch = region.indexOf("activityActorsTried = true");
  const early = region.indexOf("if (activityActorsTried) return");
  assert.ok(early >= 0 && guard > 0 && latch > 0, "the guard, the early-out and the latch must all be present");
  // THE BUG, pinned: the latch used to be set before the guard, so a cold deep
  // link into #activity (meCache still null — loadMe() is un-awaited and
  // applyRoute() runs in the same synchronous turn) burned it without ever
  // issuing the read, and the Who axis was dead for the whole page life.
  assert.ok(guard < latch, "activityActorsTried must be set BELOW the team-id guard, never above it");
  // And a failed read must not latch either: a transient 5xx retries.
  assert.match(region, /if \(!r \|\| !r\.ok\) \{ activityActorsTried = false;/,
    "a non-ok members read must clear the latch so the next Activity paint retries");
  assert.match(region, /\.catch\(function \(\) \{ activityActorsTried = false; \}\)/,
    "a rejected read must clear the latch too — there was no .catch at all");
  // Silent degrade is unchanged: no error surface in this region.
  for (const banned of ["toast(", "showError", "renderError"]) {
    assert.ok(!region.includes(banned), "a failed members read must never paint over a feed that loaded fine");
  }
});

test("cch-w12-s1: loadMe repaints Activity when /v1/me lands — the third twin of billing and operator", () => {
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  const region = appRegion(src, "function loadMe(", "// =========================================================== SUBSCRIPTION");
  for (const view of ["billing", "operator", "activity"]) {
    assert.ok(region.includes('currentView() === "' + view + '"'),
      "loadMe must re-render " + view + " once the real /v1/me is in");
  }
  assert.ok(region.includes("ensureActivityActors()") && region.includes("paintActivityFilters()"),
    "the Activity seam must both repaint the axis (the 'Just me' chip needs me) and issue the roster read");
});

test("cch-w12-s1: an identity change WITHOUT a reload drops the cached actor axis", () => {
  const src = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  // The logged-out branch of render() — it serves BOTH the sign-out click and
  // the 401 auto-bounce, neither of which reloads. It already cleared meCache,
  // the subscription trio and the overview snapshot; the actor axis was the
  // one per-account cache left standing.
  const loggedOut = appRegion(src, "    var s = session();\n    if (!s || !s.token) {", "hide($(\"#app-shell\"));");
  assert.ok(loggedOut.includes("meCache = null"), "sanity: this is the logged-out branch");
  assert.ok(loggedOut.includes("activityActors = null") && loggedOut.includes("activityActorsTried = false"),
    "signing out (or being bounced by a 401) must drop the previous team's roster");
  // Accepting an invite changes the roster under the same page life.
  const invite = appRegion(src, "function submitInviteAccept(", "function showAuthInviteBanner(");
  assert.ok(invite.includes("activityActors = null") && invite.includes("activityActorsTried = false"),
    "an accepted invite changes the roster the Who axis is derived from");
  // NOT at the team switcher: it does location.reload(), which kills every
  // module variable — a reset there would be a fix for a non-bug.
  const switcher = appRegion(src, 'sel.id = "team-switcher"', "host.textContent = \"\";");
  assert.ok(switcher.includes("location.reload()"), "the switcher still reloads");
  assert.ok(!switcher.includes("activityActors"), "no reset belongs at a seam that reloads the document");
});

// ── search-template W8: site theme-edit pure helpers ────────────────────────

test("siteThemeOptionsHtml lists the four palettes + a template-default, current selected", () => {
  const html = hooks.siteThemeOptionsHtml("ember");
  assert.match(html, /Template default/);
  for (const t of ["evergreen", "ember", "fjord", "charple"]) {
    assert.match(html, new RegExp(`value="${t}"`));
  }
  // the current value carries the selected attribute
  assert.match(html, /value="ember" selected/);
});

test("siteThemePatchBody sends the chosen theme; empty clears the pin", () => {
  assert.deepEqual(plain(hooks.siteThemePatchBody("charple")), { theme: "charple" });
  assert.deepEqual(plain(hooks.siteThemePatchBody("")), { theme: "" });
  assert.deepEqual(plain(hooks.siteThemePatchBody(undefined)), { theme: "" });
});

// ── stw5 backlog: the deploy rail's active stage gets an ETA/ring too ────────

test("SERVER_STEP_EXPECTED_MS covers every deploy stage so the ring fills on deploys", () => {
  const map = hooks.SERVER_STEP_EXPECTED_MS;
  for (const stage of ["PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"]) {
    assert.equal(typeof map[stage], "number", stage + " must have an ETA estimate");
    assert.ok(map[stage] > 0, stage + " estimate must be positive");
  }
  // BUILD is the long pole — its estimate dwarfs the second-scale stages so the
  // ring paces sensibly (a full build never reads "done but stuck").
  assert.ok(map.BUILD > map.SWITCH * 10);
});

test("stepRingProgress fills a mid-BUILD deploy stage (was flat 0 without the estimate)", () => {
  const build = hooks.SERVER_STEP_EXPECTED_MS.BUILD;
  // 30s into a ~120s BUILD → partway up the linear ramp, not 0.
  const p = hooks.stepRingProgress(30000, build);
  assert.ok(p > 0.1 && p < 0.9, "mid-build ring should be partway filled, got " + p);
  // Without an estimate (the pre-fix state) it was flat 0.
  assert.equal(hooks.stepRingProgress(30000, undefined), 0);
});

// ── gr-p2 plan & dunning (GR17/GR19/GR20): catalog, dunning, trial, chip ─────

test("PLAN_CATALOG is the one quota-honest source: USD placeholders + real 1/3/10 ceilings", () => {
  const cat = hooks.planCatalog;
  assert.equal(cat.length, 3, "exactly the three real plans");
  const by = {};
  for (const t of cat) by[t.plan] = t;
  // The REAL enforced ceilings (server Billing @default_limits) — never unlimited.
  assert.equal(by.free.instances, 1);
  assert.equal(by.supporter.instances, 3);
  assert.equal(by.support_plus.instances, 10);
  // USD placeholders held until the cloud-console-billing-live-gate human gate.
  assert.equal(by.free.price, "$0");
  assert.equal(by.supporter.price, "$69");
  assert.equal(by.support_plus.price, "$499");
});

test("planFeatures leads with the real ceiling — the unlimited fiction is gone", () => {
  const names = { free: "1 managed instance", supporter: "3 managed instances", support_plus: "10 managed instances" };
  for (const t of hooks.planCatalog) {
    const feats = hooks.planFeatures(t);
    assert.equal(feats[0], names[t.plan], t.plan + " must state its real ceiling first");
    assert.ok(!feats.join("|").includes("Unlimited"), t.plan + " must never claim unlimited");
  }
  assert.equal(hooks.planInstanceLimit({ instances: 1 }), "1 managed instance", "singular at 1");
});

test("planFromSub: a past_due team KEEPS its paid plan (the sidebar-pill fix)", () => {
  assert.equal(hooks.planFromSub({ status: "past_due", plan: "supporter" }), "supporter");
  assert.equal(hooks.planFromSub({ status: "active", plan: "supporter" }), "supporter");
  assert.equal(hooks.planFromSub({ status: "active", plan: "trial" }), "trial");
  // canceled / absent / plan-less all read free — never a stale paid name.
  assert.equal(hooks.planFromSub({ status: "canceled", plan: "supporter" }), "free");
  assert.equal(hooks.planFromSub(null), "free");
  assert.equal(hooks.planFromSub({ status: "active" }), "free");
});

test("dunningDates: failed_date is EXACTLY suspend_date minus the 3-day grace", () => {
  const end = "2026-08-01T12:00:00.000Z";
  const d = hooks.dunningDates({ current_period_end: end });
  assert.ok(d, "a dated sub yields both milestones");
  assert.equal(d.suspendMs, Date.parse(end));
  assert.equal(d.suspendMs - d.failedMs, 3 * 86400 * 1000, "the −3d offset is the grace window");
  // No dated milestone → null (the banner drops dates, never invents them).
  assert.equal(hooks.dunningDates({ current_period_end: null }), null);
  assert.equal(hooks.dunningDates(null), null);
});

test("dunningBannerHtml: GR17 strings verbatim, portal CTA, dead promises stay dead", () => {
  const html = hooks.dunningBannerHtml({ plan: "supporter", status: "past_due", current_period_end: "2026-08-01T12:00:00.000Z" });
  assert.match(html, /Your card was declined on .+\. Your instances keep running until .+, then they're suspended — not deleted — and come right back the moment payment succeeds\./);
  assert.ok(html.includes(">Past due<"), "the banner title");
  assert.ok(html.includes(">Supporter<"), "the plan-name chip");
  assert.ok(html.includes(">Update payment method<"), "the GR17 CTA verbatim");
  assert.ok(html.includes('id="dunning-portal"'), "the CTA is the portal wire point");
  assert.ok(!html.includes("retry twice more"), "the retry-count fiction is gone");
  assert.ok(!/contact support/i.test(html), "the support-mail denial copy is gone");
  // Date-less sub still renders the honest sentence, without invented dates.
  const bare = hooks.dunningBannerHtml({ plan: "supporter", status: "past_due", current_period_end: null });
  assert.ok(bare.includes("suspended — not deleted"), "the promise survives date-less");
  assert.ok(!bare.includes("declined on"), "no invented failed date");
});

test("trialCardHtml carries the RATIFIED CTA verbatim and never the teardown-dishonest promise", () => {
  const html = hooks.trialCardHtml({ plan: "trial", status: "active", trial_days_remaining: 14 });
  assert.ok(html.includes("Pick a plan below to keep it. No card needed."),
    "the ratified CTA (task-2ed0ea068f37345d), verbatim");
  assert.ok(html.includes("14 days left"), "the countdown chip");
  assert.ok(!html.includes("suspended — not deleted"), "trial expiry is a real teardown");
  // The final days flip the chip to the low state; singular reads correctly.
  const low = hooks.trialCardHtml({ plan: "trial", status: "active", trial_days_remaining: 1 });
  assert.ok(low.includes("trial-chip--low"), "≤3 days lights the low chip");
  assert.ok(low.includes("1 day left"), "singular day");
});

test("tierCardHtml: quota line always; portal button for subscribed, checkout otherwise", () => {
  const supporter = hooks.planCatalog.filter((t) => t.plan === "supporter")[0];
  const fresh = hooks.tierCardHtml(supporter, "free", false);
  assert.ok(fresh.includes("3 managed instances"), "the quota line renders");
  assert.ok(fresh.includes('data-plan="supporter"'), "unsubscribed → checkout");
  const paid = hooks.tierCardHtml(supporter, "support_plus", true);
  assert.ok(paid.includes('data-portal-plan="supporter"'), "subscribed → portal, self-serve");
  assert.ok(!/contact support/i.test(paid), "no support-mail denial copy");
  const current = hooks.tierCardHtml(supporter, "supporter", true);
  assert.ok(current.includes(">Current plan<"), "the current tier is marked");
});

test("billingChipModel: trial countdown XOR past-due alarm; silent otherwise (GR20)", () => {
  assert.equal(hooks.billingChipModel(null), null);
  const trial = hooks.billingChipModel({ plan: "trial", status: "active", trial_days_remaining: 5 });
  assert.equal(trial.kind, "trial");
  assert.equal(trial.label, "Trial · 5 days left");
  assert.equal(hooks.billingChipModel({ plan: "trial", status: "active", trial_days_remaining: 1 }).label, "Trial · 1 day left");
  assert.equal(hooks.billingChipModel({ plan: "trial", status: "active", trial_days_remaining: 0 }).label, "Trial ended");
  const due = hooks.billingChipModel({ plan: "supporter", status: "past_due" });
  assert.equal(due.kind, "past_due");
  assert.equal(due.label, "Payment failed · fix billing");
  // XOR: a past_due trial reads past-due (payment beats countdown).
  assert.equal(hooks.billingChipModel({ plan: "trial", status: "past_due", trial_days_remaining: 5 }).kind, "past_due");
  // An active paid plan / free team shows NO chip.
  assert.equal(hooks.billingChipModel({ plan: "supporter", status: "active" }), null);
  assert.equal(hooks.billingChipModel({ plan: "free", status: "active" }), null);
});

test("currentPlanCardHtml: STATE only — dunning banner only when past_due; the portal CTA moved to its own action section (G-01 anatomy)", () => {
  const due = hooks.currentPlanCardHtml({ plan: "supporter", status: "past_due", current_period_end: "2026-08-01T12:00:00.000Z", started_at: "2026-05-01T00:00:00.000Z" });
  assert.ok(due.includes("dunning-banner"), "past_due carries the banner");
  const ok = hooks.currentPlanCardHtml({ plan: "supporter", status: "active", current_period_end: "2026-08-01T12:00:00.000Z", started_at: "2026-05-01T00:00:00.000Z" });
  assert.ok(!ok.includes("dunning-banner"), "active carries no banner");
  // GR33: billing is an ACTION page — the state card no longer buries the
  // Manage-billing button (it rides the #billing-manage .set-section now), and
  // the invoice-less portal copy moved with it. The card stays STATE only.
  assert.ok(!ok.includes(">Manage billing<") && !due.includes(">Manage billing<"), "the portal CTA is NOT in the state card");
  assert.ok(!/download invoices/i.test(ok + due), "the invoice-less portal copy moved to the action section");
  assert.ok(!/contact support/i.test(ok + due), "no support-mail denial copy anywhere");
  // "See all plans" (a read affordance the card owns) stays.
  assert.ok(ok.includes("See all plans"), "the state card keeps its grid toggle");
});

test("billingPortalFlag matches the gateway's pinned return_url flag exactly", () => {
  // stripe_gateway.ex default_portal_return_url: "https://barkpark.cloud/?billing=portal"
  assert.equal(hooks.billingPortalFlag("?billing=portal"), true);
  assert.equal(hooks.billingPortalFlag("?billing=portal&x=1"), true);
  assert.equal(hooks.billingPortalFlag("?x=1&billing=portal"), true);
  assert.equal(hooks.billingPortalFlag("?checkout=success"), false);
  assert.equal(hooks.billingPortalFlag("?billing=portalx"), false, "no prefix-match false positive");
  assert.equal(hooks.billingPortalFlag(""), false);
  assert.equal(hooks.billingPortalFlag(undefined), false);
});

test("ERRORS gains the two billing truths; friendly() precedence is ERRORS → details → fallback → slug", () => {
  assert.equal(hooks.friendly({ error: "limit_reached" }, "fallback"), "You're at your plan's instance limit.");
  assert.equal(hooks.friendly({ error: "billing_not_configured" }), "Billing isn't set up on this deployment yet.");
  // The GR19 fix: a designed per-call fallback now BEATS the humanized slug…
  assert.equal(hooks.friendly({ error: "totally_unknown_slug" }, "Please try again."), "Please try again.");
  // …while a call WITHOUT a fallback still surfaces the humanized slug.
  assert.equal(hooks.friendly({ error: "totally_unknown_slug" }), "totally unknown slug");
  // details still outrank the fallback (field-level truth is more specific).
  assert.equal(hooks.friendly({ error: "x", details: { name: ["is required"] } }, "fb"), "name is required");
});

test("tierCardHtml: a trial team's Free card never offers a doomed checkout (review fix)", () => {
  // There is no free checkout — POST /v1/billing/checkout with plan=free 422s
  // plan_invalid. Only a TRIAL team ever sees Free as non-current, and doing
  // nothing IS how a trial lands on Free, so the card is honest and inert.
  const free = hooks.planCatalog.filter((t) => t.plan === "free")[0];
  const onTrial = hooks.tierCardHtml(free, "trial", false);
  assert.ok(!onTrial.includes('data-plan="free"'), "no checkout wire on the free card");
  assert.ok(onTrial.includes("Yours when the trial ends"), "the honest inert label");
  // A genuinely free team still reads Free as its current plan.
  assert.ok(hooks.tierCardHtml(free, "free", false).includes(">Current plan<"));
});

// ════════════════════════════════════════════════════════════════════════════
// gr-p2 launch theater (GR18): conditional rail proof, price-before-charge,
// failure snap (skipped rows). Appended at the tail (OC9 append-only law).
// ════════════════════════════════════════════════════════════════════════════

test("GR18(1): conditional rail — 5 rows without freshen/content, 7 when the server reports both", () => {
  // The typical warm-path run: neither optional step reported → exactly the 5
  // planned rows (the design render's 7 static rows over-promise; code wins).
  const bare = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
  ] }, NOW);
  assert.equal(bare.length, 5);
  assert.deepEqual([...bare.map((r) => r.step)], ["create", "secure", "configure", "verify", "ready"]);
  // A stale-box templated run: the server reported freshen AND content → both
  // slot into their places and the rail grows to 7.
  const full = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(1) },
    { step: "freshen", status: "started", at: T(1) },
    { step: "freshen", status: "done", at: T(3) },
    { step: "secure", status: "started", at: T(3) },
    { step: "secure", status: "done", at: T(4) },
    { step: "configure", status: "started", at: T(4) },
    { step: "configure", status: "done", at: T(5) },
    { step: "content", status: "started", at: T(5) },
  ] }, NOW);
  assert.equal(full.length, 7);
  assert.deepEqual([...full.map((r) => r.step)],
    ["create", "freshen", "secure", "configure", "content", "verify", "ready"]);
});

// A priced catalog fixture shaped like the real /v1/providers/:kind/catalog
// payload (server_types[].monthly_price, regions[].{slug,name}, currency).
const THEATER_CATALOG = {
  currency: "EUR",
  regions: [{ slug: "fsn1", name: "Falkenstein" }, { slug: "hel1", name: "Helsinki" }],
  server_types: [
    { slug: "cx22", cores: 2, ram_gb: 4, disk_gb: 40, monthly_price: 4.9 },
    { slug: "cx32", cores: 4, ram_gb: 8, disk_gb: 80, monthly_price: null }, // honest unpriced row
  ],
};
const THEATER_BP = { provider: "hetzner", region: "fsn1", server_type: "cx22" };

test("GR18(3): price-before-charge — the REAL catalog price via formatMonthlyPrice, provider + human region", () => {
  const m = hooks.theaterPriceModel(THEATER_BP, THEATER_CATALOG);
  // The price IS formatMonthlyPrice's output for the catalog row — never
  // plan-grid digits, never an invented number.
  assert.equal(m.price, hooks.formatMonthlyPrice(4.9, "hetzner", "EUR"));
  assert.equal(m.price, "€4.9/mo");
  assert.equal(m.provider, "Hetzner Cloud"); // providerMeta's honest display name
  assert.equal(m.location, "Falkenstein"); // the region NAME, slug as fallback
  const html = hooks.theaterPriceLineHtml(THEATER_BP, THEATER_CATALOG);
  assert.match(html, /data-price-line/);
  assert.match(html, /€4\.9\/mo/);
  assert.match(html, /on Hetzner Cloud · Falkenstein/);
  assert.match(html, /price confirmed before anything is charged\./);
});

test("GR18(3): the price line is OMITTED when no real price exists (nil-safe, never fabricated)", () => {
  // The catalog row exists but carries no price (nil monthly_price).
  const unpriced = Object.assign({}, THEATER_BP, { server_type: "cx32" });
  assert.equal(hooks.theaterPriceModel(unpriced, THEATER_CATALOG), null);
  assert.equal(hooks.theaterPriceLineHtml(unpriced, THEATER_CATALOG), "");
  // No catalog at all (managed launch → 404 no_provider), no server_type, an
  // unknown type, and garbage — all omit, never throw, never "Price unavailable".
  assert.equal(hooks.theaterPriceLineHtml(THEATER_BP, null), "");
  assert.equal(hooks.theaterPriceLineHtml({ provider: "hetzner" }, THEATER_CATALOG), "");
  assert.equal(hooks.theaterPriceLineHtml(Object.assign({}, THEATER_BP, { server_type: "nope" }), THEATER_CATALOG), "");
  assert.equal(hooks.theaterPriceLineHtml(null, null), "");
  assert.equal(hooks.theaterPriceLineHtml(THEATER_BP, { server_types: "garbled" }), "");
});

test("GR18(3): a region the catalog does not know falls back to the slug; azure frames its floor price", () => {
  const m = hooks.theaterPriceModel(Object.assign({}, THEATER_BP, { region: "xyz9" }), THEATER_CATALOG);
  assert.equal(m.location, "xyz9");
  const az = hooks.theaterPriceModel(
    { provider: "azure", region: "westeurope", server_type: "b2s" },
    { currency: "USD", regions: [], server_types: [{ slug: "b2s", monthly_price: 30.4 }] },
  );
  assert.equal(az.price, "from ~$30/mo compute"); // Decision 6 azure floor framing (≥10 rounds whole)
  assert.equal(az.provider, "Microsoft Azure");
});

test("GR18(4): failure snap — rows behind the failed step render `skipped` with no plan hint, no caption", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "done", at: T(1) },
    { step: "secure", status: "started", at: T(1), detail: "Requesting certificate" },
    { step: "secure", status: "failed", at: T(4) },
  ] }, NOW);
  const html = hooks.newStepsHtml(rows);
  assert.match(html, /<li class="new-step done" data-step="create">/);
  assert.match(html, /<li class="new-step failed" data-step="secure">/);
  // Everything behind the break is skipped — dashed hollow, and NEVER the
  // pending "~30s" plan hint (promising a plan for a step that won't run).
  assert.match(html, /<li class="new-step skipped" data-step="configure">/);
  assert.match(html, /<li class="new-step skipped" data-step="verify">/);
  assert.match(html, /<li class="new-step skipped" data-step="ready">/);
  assert.doesNotMatch(html, /new-step pending/);
  const skippedChunk = html.slice(html.indexOf('data-step="configure"'));
  assert.doesNotMatch(skippedChunk, /new-step-time/); // no pace column on skipped rows
  assert.doesNotMatch(skippedChunk, /new-step-detail/); // no caption either
  // The failed row keeps its truth: real elapsed + its last caption.
  assert.match(html, /new-step failed[\s\S]*?new-step-detail[^>]*>Requesting certificate/);
  assert.match(html, /new-step failed[\s\S]*?new-step-time">3s</);
});

test("GR18(4): a step the server DID report after a break stays truthful (never blanket-skipped)", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "failed", at: T(2) },
    { step: "verify", status: "started", at: T(3) },
  ] }, NOW);
  const html = hooks.newStepsHtml(rows);
  assert.match(html, /<li class="new-step failed" data-step="create">/);
  assert.match(html, /<li class="new-step active" data-step="verify">/); // reported → truthful
  assert.match(html, /<li class="new-step skipped" data-step="secure">/);
});

// ── gr-p2 HOME TRIAGE (C-01/C-02): the v4 Overview pure helpers ──────────────
// The triage headline, real slots meter, attention row, instance cards, the
// self-healing runway model, and the GR17 past-due surfaces. Pure functions
// only — the DOM mounts (loadOverview/paintOverview*) are smoke-verified.

test("overviewGreeting: time-of-day prefix across the four bands (trailing ', ')", () => {
  assert.equal(hooks.overviewGreeting(2), "Up late, ");
  assert.equal(hooks.overviewGreeting(9), "Good morning, ");
  assert.equal(hooks.overviewGreeting(14), "Good afternoon, ");
  assert.equal(hooks.overviewGreeting(21), "Good evening, ");
  // boundaries: <5 / <12 / <18
  assert.equal(hooks.overviewGreeting(5), "Good morning, ");
  assert.equal(hooks.overviewGreeting(12), "Good afternoon, ");
  assert.equal(hooks.overviewGreeting(18), "Good evening, ");
});

test("overviewSubline: the triage sentence reads the truth (0 / 1 / N attention)", () => {
  assert.equal(hooks.overviewSubline({ attention: 0, total: 3 }), "All 3 instances are running fine.");
  assert.equal(hooks.overviewSubline({ attention: 0, total: 1 }), "All 1 instance is running fine.");
  assert.equal(hooks.overviewSubline({ attention: 1, total: 4 }), "One thing needs a look — everything else is running fine.");
  assert.equal(hooks.overviewSubline({ attention: 3, total: 5 }), "3 things need a look.");
});

test("overviewHeadChipsHtml: attention always, in-flight only when >0 (pulsing), healthy, + slots slot", () => {
  const withFlight = hooks.overviewHeadChipsHtml({ attention: 2, inflight: 1, healthy: 4 });
  assert.match(withFlight, /ov-chip--attention/);
  assert.match(withFlight, /2 needs attention/);
  assert.match(withFlight, /ov-chip--inflight/);
  assert.match(withFlight, /1 in flight/);
  assert.match(withFlight, /ov-chip-pulse/);
  assert.match(withFlight, /ov-chip--healthy/);
  assert.match(withFlight, /4 healthy/);
  assert.match(withFlight, /id="overview-slots"/);
  const noFlight = hooks.overviewHeadChipsHtml({ attention: 0, inflight: 0, healthy: 2 });
  assert.doesNotMatch(noFlight, /ov-chip--inflight/); // conditional
  assert.match(noFlight, /0 needs attention/); // amber chip always present
});

test("overviewSlotsModel: denominator is the REAL team quota, never hardcoded", () => {
  const m = hooks.overviewSlotsModel({ team: { instances: { value: 5, quota: 10 } } }, 5);
  assert.deepEqual({ count: m.count, limit: m.limit, hasLimit: m.hasLimit, pct: m.pct }, { count: 5, limit: 10, hasLimit: true, pct: 50 });
  assert.match(hooks.overviewSlotsHtml(m), /5 \/ 10 slots/);
  // No positive quota (older CP / unlimited) → no meter, no invented ceiling.
  const none = hooks.overviewSlotsModel({ team: {} }, 3);
  assert.equal(none.hasLimit, false);
  assert.equal(hooks.overviewSlotsHtml(none), "");
  assert.equal(hooks.overviewSlotsModel(null, 2).hasLimit, false);
  // pct clamps at 100 for an over-limit fleet.
  assert.equal(hooks.overviewSlotsModel({ team: { instances: { value: 12, quota: 10 } } }, 12).pct, 100);
});

test("attentionReason: the real status detail, with the v4 'Needs a look.' fallback", () => {
  const degraded = { host: "h", health_status: "down", agent_status: "offline", provision_status: "succeeded" };
  assert.match(hooks.attentionReason(degraded), /Health down|Agent offline/);
  // An 'ok' box carries a detail too (never the fallback), but a stateless one falls back.
  assert.equal(hooks.attentionReason({ host: "h", health_status: "up", agent_status: "online", update_state: "current" }).length > 0, true);
});

test("attentionCanStudio: live boxes only (host set, not suspended, not tearing down)", () => {
  assert.equal(hooks.attentionCanStudio({ host: "h" }), true);
  assert.equal(hooks.attentionCanStudio({ host: "h", suspended: true }), false);
  assert.equal(hooks.attentionCanStudio({ host: "h", deprovision_status: "pending" }), false);
  assert.equal(hooks.attentionCanStudio({ provision_status: "failed" }), false); // no host
});

test("attentionRowHtml: pill + linked name + reason + View instance + (live) Open Studio", () => {
  const html = hooks.attentionRowHtml({ id: "b1", name: "Reporting", host: "h", health_status: "down", agent_status: "offline", provision_status: "succeeded" });
  assert.match(html, /status-pill/);
  assert.match(html, /href="#instance\/b1"[^>]*>Reporting<\/a>/);
  assert.match(html, /attention-reason/);
  assert.match(html, />View instance</);
  assert.match(html, /fleet-open-studio[^>]*data-id="b1"/);
  // A failed (host-less) box gets no Open Studio.
  const failed = hooks.attentionRowHtml({ id: "b2", name: "X", provision_status: "failed" });
  assert.doesNotMatch(failed, /Open Studio/);
});

test("instanceCardStats: four stats, over/warn meter tints its value amber", () => {
  const meters = {
    documents: { value: 412, measured_at: "2020" },
    disk: { value: 37, quota: 100, warn_at: 70, measured_at: "2020" },
    cpu: { value: 88, quota: 100, warn_at: 70, measured_at: "2020" },
    ram: { value: 100, quota: 100, warn_at: 70, measured_at: "2020" },
  };
  const stats = [...hooks.instanceCardStats(meters)]; // spread across the vm realm
  assert.deepEqual(stats.map((s) => s.k), ["DOCS", "DISK", "CPU", "RAM"]);
  assert.equal(stats[1].warn, false); // disk 37% < warn 70
  assert.equal(stats[2].warn, true); // cpu 88% ≥ warn 70
  assert.equal(stats[3].warn, true); // ram 100% ≥ quota → over
  // No meters → honest em-dash, never a fabricated 0.
  assert.equal(hooks.instanceCardStats(null)[0].v, "—");
});

test("instanceCardHtml: v4 anatomy — status accent, mono url, sparkline frame, Open Studio; suspended → GR17 card banner", () => {
  const live = { id: "b1", name: "Production", host: "prod.barkpark.cloud", url: "prod.barkpark.cloud", health_status: "up", agent_status: "online", update_state: "current", version: "0.9.2", provision_status: "succeeded" };
  const html = hooks.instanceCardHtml(live, { stats: hooks.instanceCardStats(null) });
  assert.match(html, /instance-card instance-card--ok/);
  assert.match(html, /instance-card-name[^>]*>Production</);
  assert.match(html, /instance-card-spark spark--ok/);
  assert.match(html, /class="spark"/); // the honest (empty) sparkline frame
  assert.match(html, /fleet-open-studio/);
  assert.doesNotMatch(html, /suspended-card-banner/);
  // A suspended box (with a subscription in hand) carries the GR17 recovery banner.
  const susp = { id: "b2", name: "Marketing", host: "m", suspended: true, provision_status: "succeeded" };
  const sub = { plan: "supporter", status: "past_due", current_period_end: "2026-08-01T00:00:00Z" };
  const shtml = hooks.instanceCardHtml(susp, { sub, stats: hooks.instanceCardStats(null) });
  assert.match(shtml, /suspended-card-banner/);
  assert.match(shtml, /The server is stopped, not destroyed/);
  assert.doesNotMatch(shtml, /Open Studio/); // suspended boxes get no Studio link
});

test("runwayStepModel: check marks vs digits, real instance-name hint, Open Studio gated on pending+studioId", () => {
  const ob = { steps: [{ key: "subscription", done: true }, { key: "instance", done: true }, { key: "published_doc", done: false }] };
  const model = [...hooks.runwayStepModel(ob, { instanceName: "Production", studioId: "b1" })]; // spread across the vm realm
  assert.deepEqual(model.map((s) => s.mark), ["✓", "✓", "3"]); // done → check, pending → digit
  assert.equal(model[1].hint, "Production is running"); // real fleet-cache name
  assert.equal(model[2].action, "Open Studio →"); // pending published_doc + a live box
  // No live box → no Studio nudge even while pending.
  assert.equal(hooks.runwayStepModel(ob, { studioId: "" })[2].action, "");
});

test("runwayProgressText / runwayCardHtml: 'N of 3 done' + role-gated dismiss", () => {
  const ob = { completed: false, steps: [{ key: "subscription", done: true }, { key: "instance", done: true }, { key: "published_doc", done: false }] };
  assert.equal(hooks.runwayProgressText(ob), "2 of 3 done");
  const owner = hooks.runwayCardHtml(ob, { canManage: true, instanceName: "Production", studioId: "b1" });
  assert.match(owner, /You're nearly set up/);
  assert.match(owner, /2 of 3 done/);
  assert.match(owner, /runway-dismiss/); // owner/admin sees Dismiss
  const member = hooks.runwayCardHtml(ob, { canManage: false });
  assert.doesNotMatch(member, /runway-dismiss/); // plain member: no silent-403 button
});

test("overviewDunningBannerHtml (GR17): 'Your payment failed on {date}' + suspended-not-deleted, data-driven", () => {
  // Midday UTC so fmtDay's local-date render never straddles a TZ boundary.
  const sub = { plan: "supporter", status: "past_due", current_period_end: "2026-08-04T12:00:00.000Z" };
  const html = hooks.overviewDunningBannerHtml(sub);
  assert.match(html, /Your payment failed on .+\. Your instances keep running until .+, then they're suspended — not deleted\./);
  assert.match(html, /Update payment method/);
  assert.doesNotMatch(html, /come right back/); // that tail is the billing-page variant only
  assert.doesNotMatch(html, /card was declined/); // the ratified overview lead is 'Your payment failed on'
  // No dated milestone → the banner drops the dates, never invents them.
  assert.match(hooks.overviewDunningBannerHtml({ plan: "supporter", status: "past_due" }), /Your payment failed\. /);
});

test("suspendedCardBannerHtml (GR17): 'Suspended {date} — payment failed' + stopped-not-destroyed, verbatim", () => {
  const html = hooks.suspendedCardBannerHtml({ plan: "supporter", status: "past_due", current_period_end: "2026-08-04T12:00:00.000Z" });
  assert.match(html, /Suspended .+ — payment failed/);
  assert.match(html, /The server is stopped, not destroyed\. Everything comes back exactly as it was the moment payment succeeds\./);
  assert.doesNotMatch(html, /suspended — not deleted/); // the card uses its OWN copy, never the banner's
});

test("overviewStatePick: past_due wins; trial+incomplete → runway; else none (mutual exclusivity)", () => {
  const ob = { completed: false, steps: [] };
  assert.equal(hooks.overviewStatePick({ status: "past_due", plan: "supporter" }, ob), "past_due");
  // even a trial with open onboarding yields to a past_due state (impossible in practice, but the pick is total).
  assert.equal(hooks.overviewStatePick({ status: "past_due", plan: "trial" }, ob), "past_due");
  assert.equal(hooks.overviewStatePick({ status: "active", plan: "trial" }, ob), "runway");
  assert.equal(hooks.overviewStatePick({ status: "active", plan: "trial" }, { completed: true, steps: [] }), "none"); // dismissed/finished
  assert.equal(hooks.overviewStatePick({ status: "active", plan: "pro" }, ob), "none"); // paid, not trial
  assert.equal(hooks.overviewStatePick(null, null), "none");
});

test("overviewStateHtml: dispatches to the mutually-exclusive band", () => {
  const ob = { completed: false, steps: [{ key: "subscription", done: true }, { key: "instance", done: false }, { key: "published_doc", done: false }] };
  assert.match(hooks.overviewStateHtml({ status: "past_due", plan: "supporter", current_period_end: "2026-08-04T00:00:00Z" }, ob, {}), /dunning-banner/);
  assert.match(hooks.overviewStateHtml({ status: "active", plan: "trial" }, ob, { canManage: true }), /runway-card/);
  assert.equal(hooks.overviewStateHtml({ status: "active", plan: "pro" }, ob, {}), "");
});

// ── gr-p3 D-01: the v4 fleet-row anatomy + the orthogonal update chip ────────
// (screens/01). Pure row markup — states-complete (live/degraded/suspended/
// failed) × update-chip present/absent, the mono metadata line, and the pill's
// update-state decoupling. The shared classifyBp/statusOf spine is untouched.
const fleetBp = (over) => Object.assign({
  id: "i1", name: "Production", slug: "production",
  url: "production.barkpark.cloud", host: "production.barkpark.cloud",
  health_status: "up", agent_status: "online", version: "0.9.2",
  update_state: "current", update_running_release: "0.9.2", update_latest_release: "0.9.2",
  region: "fsn1", server_type: "cx22", channel: "prod",
  autoupdate_enabled: true, autoupdate_paused: false, pinned_release: null,
  provider: "hetzner", provision_status: "succeeded", suspended: false,
}, over || {});

test("gr-p3: the v4 fleet-row + update helpers are exported", () => {
  for (const name of ["fleetRow", "fleetMetaHtml", "fleetAutoupdateText",
    "fleetUpdateChip", "fleetUpdateChipHtml", "withoutUpdateState"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

test("gr-p3: fleetMetaHtml is the backend-true mono line, blank-tolerant", () => {
  assert.equal(hooks.fleetMetaHtml({}), ""); // an empty row renders nothing (no dangling ·)
  const full = hooks.fleetMetaHtml(fleetBp());
  assert.match(full, /class="fleet-meta"/);
  assert.match(full, /fsn1 · cx22 · v0\.9\.2 · prod · autoupdate on/);
  // version already prefixed with v is not double-prefixed
  assert.match(hooks.fleetMetaHtml({ version: "v1.2.3" }), /v1\.2\.3/);
  assert.ok(hooks.fleetMetaHtml({ version: "v1.2.3" }).indexOf("vv1.2.3") === -1);
  // no channel/autoupdate → those segments simply vanish
  assert.equal(hooks.fleetMetaHtml({ region: "nbg1" }).indexOf("·"), -1);
});

test("gr-p3: fleetAutoupdateText — pinned > paused > off > on, hidden without a policy block", () => {
  assert.equal(hooks.fleetAutoupdateText({}), ""); // older CP: no policy fields → nothing
  assert.equal(hooks.fleetAutoupdateText({ autoupdate_enabled: true }), "autoupdate on");
  assert.equal(hooks.fleetAutoupdateText({ autoupdate_enabled: false }), "autoupdate off");
  assert.equal(hooks.fleetAutoupdateText({ autoupdate_enabled: true, autoupdate_paused: true }), "autoupdate paused");
  assert.equal(hooks.fleetAutoupdateText({ pinned_release: "v0.9.0" }), "pinned v0.9.0");
});

test("gr-p3: fleetUpdateChip — backend-true only (behind names the release; in-flight outranks; else null)", () => {
  assert.equal(hooks.fleetUpdateChip({ update_state: "current" }), null);
  assert.equal(hooks.fleetUpdateChip({}), null); // never an invented state
  const behind = hooks.fleetUpdateChip({ update_state: "behind", update_latest_release: "0.9.2" });
  assert.equal(behind.state, "behind");
  assert.equal(behind.label, "v0.9.2 available");
  // a settled behind with no named latest still reads honestly
  assert.equal(hooks.fleetUpdateChip({ update_state: "behind" }).label, "A newer release available");
  // an in-flight rollout outranks a stale cached "behind"
  assert.equal(hooks.fleetUpdateChip({ update_state: "behind", autoupdate_triggered_at: "2026-07-19T00:00:00Z" }).state, "in-flight");
});

test("gr-p3: fleetUpdateChipHtml — static per-state classes, escaped label; empty when no update", () => {
  assert.equal(hooks.fleetUpdateChipHtml({ update_state: "current" }), "");
  const ready = hooks.fleetUpdateChipHtml({ update_state: "behind", update_latest_release: "0.9.2" });
  assert.match(ready, /class="fleet-update-chip fleet-update-chip--ready"/);
  assert.match(ready, /v0\.9\.2 available/);
  const busy = hooks.fleetUpdateChipHtml({ autoupdate_triggered_at: "2026-07-19T00:00:00Z" });
  assert.match(busy, /fleet-update-chip--busy/);
  assert.match(busy, /Updating/);
});

test("gr-p3: withoutUpdateState clears only update_state, never mutating the source", () => {
  const src = fleetBp({ update_state: "behind" });
  const copy = hooks.withoutUpdateState(src);
  assert.equal(copy.update_state, null);
  assert.equal(src.update_state, "behind"); // the shared spine's input is never mutated
  assert.equal(copy.name, "Production");
});

test("gr-p3: fleetRow — v4 anatomy: leading pill column, mono meta, badges, chevron", () => {
  const html = hooks.fleetRow(fleetBp());
  assert.match(html, /class="fleet-row" data-id="i1"/);
  assert.match(html, /<div class="fleet-status"><span class="status-pill status-pill--ok/);
  assert.match(html, /class="fleet-name">Production/);
  assert.match(html, /class="fleet-meta"/);
  assert.match(html, /provider-chip--hetzner/);
  assert.match(html, /fleet-open-studio/); // live → Open Studio
  assert.match(html, /class="fleet-chev"/);
  assert.equal(html.indexOf("fleet-update-chip"), -1); // current → no chip
});

test("gr-p3: fleetRow — states-complete pill roles (live/degraded/suspended/failed)", () => {
  assert.match(hooks.fleetRow(fleetBp()), /status-pill--ok/);                 // live → Healthy
  assert.match(hooks.fleetRow(fleetBp({ health_status: "down" })), /status-pill--warn/); // degraded
  assert.match(hooks.fleetRow(fleetBp({ suspended: true })), /status-pill--danger/);     // suspended
  const failed = hooks.fleetRow(fleetBp({ host: null, provision_status: "failed" }));
  assert.match(failed, /status-pill--danger/);        // failed
  assert.match(failed, /fleet-url failed/);           // and the failed url line
  assert.equal(failed.indexOf("fleet-open-studio"), -1); // not live → no Open Studio
});

test("gr-p3: fleetRow — a live+behind box reads its lifecycle + a chip, NEVER a double 'Update available'", () => {
  const html = hooks.fleetRow(fleetBp({ version: "0.8.4", update_state: "behind", update_latest_release: "0.9.2" }));
  assert.match(html, /status-pill--ok/);                       // the pill stays lifecycle (Healthy)
  assert.doesNotMatch(html, /Update available/);               // decoupled — no pill duplication
  assert.match(html, /fleet-update-chip--ready/);              // the update signal is the chip
  assert.match(html, /v0\.9\.2 available/);
});

// ── gr-p3 D-01: archives — the DISTINCT storage-unconfigured state ───────────
test("gr-p3: archivesModel — the not_configured server copy is a DISTINCT state (explanation + Retry)", () => {
  const m = hooks.archivesModel({ ok: false, error: "Archive storage isn't configured for this deployment." });
  assert.equal(m.notConfigured, true);
  assert.equal(m.error, true);
  const html = hooks.archivesPanelHtml(m);
  assert.match(html, /archives-note--unconfigured/);
  assert.match(html, /archives-note-dot/);
  assert.match(html, /Archive storage isn/);            // server copy, verbatim (esc-stable fragment)
  // gr-blk-archives-doc-link: this used to assert the "How archives work" link.
  // Nothing in the repo answers that question, so the anchor pointed at the
  // bare repo root — the affordance is now the explanation itself, in place.
  assert.match(html, /archives-note-sub/);
  assert.match(html, /data-archives-retry/);            // and a working Retry
});

test("gr-p3: archivesModel — a GENERIC store outage stays the transient error branch, not unconfigured", () => {
  const m = hooks.archivesModel({ ok: false, error: "Couldn't reach the archive store. It may be temporarily unavailable — try again shortly." });
  assert.ok(!m.notConfigured);
  assert.equal(m.error, true);
  const html = hooks.archivesPanelHtml(m);
  assert.match(html, /archives-note--warn/);
  assert.equal(html.indexOf("archives-note--unconfigured"), -1);
  assert.equal(html.indexOf("archives-note-sub"), -1); // no "what an archive is" aside on a transient outage
  assert.match(html, /data-archives-retry/);
});

// ════════════════════════════════════════════════════════════════════════════
// gr-p3 instance workspace (GR24, screens/02) — the v4 header, the bp CLI card,
// and the composed Overview pass. Tail-append (OC9).
// ════════════════════════════════════════════════════════════════════════════

test("GR24: the header helpers are exported", () => {
  for (const name of ["instanceHeaderHtml", "instanceOverviewHtml", "instanceLifecycle"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

const GR24_LIVE = {
  id: "b-1", name: "Gyldendal", slug: "gyldendal", host: "5.75.169.183",
  url: "https://gyldendal-506f035e.barkpark.cloud",
  health_status: "up", agent_status: "online", version: "0.2.25",
  git_commit: "c801681aa00", provider: "hetzner", region: "fsn1", server_type: "cx22",
  update_state: "current", provision_status: "succeeded",
};

test("GR24: a live header carries the two-axis pill, the mono address + copy, and the action trio", () => {
  const html = hooks.instanceHeaderHtml(GR24_LIVE);
  // two-axis compound pill: statusPill's label + detail axes both render.
  assert.match(html, /status-pill status-pill--ok/);
  assert.match(html, /status-pill-label">Healthy</);
  assert.match(html, /status-pill-detail">v0\.2\.25</);
  // the address line: mono URL + the shared [data-copy] affordance.
  assert.match(html, /detail-url-text">https:\/\/gyldendal-506f035e\.barkpark\.cloud</);
  assert.match(html, /data-copy="https:\/\/gyldendal-506f035e\.barkpark\.cloud"/);
  // actions: Open Studio primary, Attach domain, the bp CLI disclosure (closed).
  assert.match(html, /id="inst-open-studio"/);
  assert.match(html, /id="inst-domain"/);
  assert.match(html, /id="inst-cli-toggle"[^>]*aria-expanded="false"/);
  assert.match(html, /aria-controls="inst-lifecycle-actions"/);
});

test("GR24: a degraded header reads the honest two-axis breakdown off statusPill", () => {
  const html = hooks.instanceHeaderHtml({ ...GR24_LIVE, health_status: "down" });
  assert.match(html, /status-pill status-pill--warn/);
  assert.match(html, /status-pill-label">Degraded</);
  assert.match(html, /status-pill-detail">Health down</);
});

test("GR24: suspended keeps the banner + the CLI disclosure (teardown stays reachable)", () => {
  const html = hooks.instanceHeaderHtml({ ...GR24_LIVE, suspended: true, suspended_reason: "payment failed" });
  assert.match(html, /notice notice-error/);
  assert.match(html, /payment failed/);
  assert.match(html, /id="inst-cli-toggle"/);
  assert.doesNotMatch(html, /id="inst-open-studio"/); // no Studio on a stopped box
});

test("GR24: a provisioning header keeps the live chip and offers no CLI disclosure", () => {
  const html = hooks.instanceHeaderHtml({ id: "b-2", name: "Analytics", provision_status: "claimed", provision_steps: [] });
  assert.match(html, /fleet-url provisioning/); // the SSE fast path patches this class in place
  assert.doesNotMatch(html, /inst-cli-toggle/); // showLifecycleRow is false pre-host
  assert.doesNotMatch(html, /detail-url-text/);
});

test("GR24: a failed provision keeps the CLI disclosure — its teardown home", () => {
  const html = hooks.instanceHeaderHtml({ id: "b-3", name: "Broken", provision_status: "failed" });
  assert.match(html, /fleet-url failed/);
  assert.match(html, /id="inst-cli-toggle"/);
});

test("GR24: the bp CLI card — title, 4 copyable commands, the SERVER pause sentence in the foot, Decommission…", () => {
  const html = hooks.lifecycleActionRowHtml(hooks.lifecycleActionsModel(CAP_PAYLOAD, { provider: "hetzner", host: "h", name: "web" }));
  assert.match(html, /cli-card/);
  assert.match(html, /Manage this instance via the bp CLI/);
  for (const verb of ["archive", "resurrect", "adopt", "audit"]) {
    assert.match(html, new RegExp("bp cloud instance " + verb + " web"));
  }
  // the pause verb leaves the grid: its SERVER-OWNED gap reason IS the foot sentence.
  assert.match(html, /inst-life-footnote">Hetzner has no pause primitive\.</);
  assert.doesNotMatch(html, /<button[^>]*disabled[^>]*>Pause</); // no dead Pause control in the grid
  // the destroy-tier verb anchors the foot with the typed-confirm ellipsis.
  assert.match(html, /cli-card-foot/);
  assert.match(html, /data-life-verb="decommission"[^>]*>Decommission&hellip;</);
});

test("GR24: a provider WITH a pause capability gets pause as a command row and no foot sentence", () => {
  const html = hooks.lifecycleActionRowHtml(hooks.lifecycleActionsModel(CAP_PAYLOAD, { provider: "azure", host: "h", name: "az1" }));
  assert.match(html, /bp cloud instance pause az1/); // pause joins the grid
  assert.match(html, /inst-life-footnote"></); // empty foot spacer, no invented sentence
});

test("GR24: the composed Overview — verify slot, updates card, Sites card, and the card rail", () => {
  const html = hooks.instanceOverviewHtml(GR24_LIVE, {});
  assert.match(html, /id="instance-verify"/);
  assert.match(html, /update-panel/);
  assert.match(html, /inst-sites-card/);
  assert.match(html, /id="site-new-btn"/);
  assert.match(html, /detail-rail detail-rail--cards/);
  for (const label of ["Identity", "Runtime", "Platform", "Activity"]) {
    assert.match(html, new RegExp('rail-group-label">' + label + "<"));
  }
  // GR27 identity truth: provider/region/size are the real S6 fields.
  assert.match(html, /Provider<\/span><span class="v">Hetzner</);
  assert.match(html, /Region<\/span><span class="v">fsn1</);
  assert.match(html, /Size<\/span><span class="v">cx22</);
  assert.match(html, /id="instance-domains"/); // the checklist component's slot, consumed as-is
});

test("GR24: pre-host the Overview stays quiet — no Sites card, no verify slot, blank-tolerant rail", () => {
  const html = hooks.instanceOverviewHtml({ id: "b-2", name: "Analytics", provision_status: "claimed", provision_steps: [] }, {});
  assert.doesNotMatch(html, /inst-sites-card/);
  assert.doesNotMatch(html, /id="instance-verify"/);
  assert.match(html, /id="instance-sites"/); // the slot itself stays for loadInstanceSites
  assert.match(html, /Provider<\/span><span class="v">—</);
});

// ════════════════════════════════════════════════════════════════════════════
// gr-p3 D-04 — THE event-coalescing grammar (GR26, styleguide §07)
// coalesceEntries + tlv-coalesce render: consecutive same-key folds, the
// PARAMETERIZED group key (type vs type+target for I-01), worst-verdict
// summary, cadence copy, singleton passthrough, Show-all/Collapse markup.
// (Tail-append per OC9; reuses the C8 EV/AU fixture builders above.)
// ════════════════════════════════════════════════════════════════════════════

test("D-04: the coalescing pure helpers are exported", () => {
  for (const name of ["coalesceEntries", "tlvCoalesceKey", "tlvCoalesceKeyByTarget",
    "tlvVerdictOf", "tlvGroupVerdictText", "tlvGroupCadenceText", "tlvApproxDur",
    "tlvGroupTitle", "tlvBadgeMod", "tlvGroupBadgeMod", "tlvGroupRowHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
});

// Ten health beats, one per minute, newest-first — the styleguide §07 burst.
const BURST = Array.from({ length: 10 }, (_, i) =>
  EV(30 - i, "health", 600 - i * 60, { health: "down", disk_used_pct: 91 }));

test("D-04: coalesceEntries folds consecutive same-key runs; singletons pass through UNCHANGED", () => {
  const entries = hooks.mergeTimeline(
    [...BURST, EV(5, "status", 30, { transition: "offline" }), EV(4, "backup", 20, { status: "ok" })],
    [],
  );
  const items = hooks.coalesceEntries(entries);
  assert.equal(items.length, 3, "10 beats fold to one group; the two singles stay");
  assert.equal(items[0].group, true);
  assert.equal(items[0].count, 10);
  assert.equal(items[0].type, "health");
  assert.equal(items[0].at, entries[0].at, "the newest member fronts the group");
  // Singletons are the SAME objects mergeTimeline made (===, not copies).
  assert.equal(items[1], entries[10]);
  assert.equal(items[2], entries[11]);
  assert.equal(items[1].group, undefined);
});

test("D-04: a run of two folds; interleaving breaks the run (consecutive-only, never feed-wide)", () => {
  const entries = hooks.mergeTimeline(
    [EV(4, "health", 40, { health: "up" }), EV(3, "health", 30, { health: "up" }),
     EV(2, "backup", 20, { status: "ok" }), EV(1, "health", 10, { health: "up" })],
    [],
  );
  const items = hooks.coalesceEntries(entries);
  assert.equal(items.length, 3);
  assert.equal(items[0].count, 2, "the adjacent pair folds");
  assert.equal(items[1].key, "e:2");
  assert.equal(items[2].key, "e:1", "the beat behind the backup stays single — no cross-feed fold");
});

test("D-04: the group key anchors on the OLDEST member — a live prepend grows, never re-keys", () => {
  const entries = hooks.mergeTimeline(BURST, []);
  const before = hooks.coalesceEntries(entries)[0];
  const grown = hooks.mergeTimeline([EV(31, "health", 660, { health: "down" }), ...BURST], []);
  const after = hooks.coalesceEntries(grown)[0];
  assert.equal(after.count, 11);
  assert.equal(after.key, before.key, "an open group must survive the SSE repaint");
});

test("D-04: PARAMETERIZED key — the default folds audit repeats; tlvCoalesceKeyByTarget keeps unrelated targets apart (I-01)", () => {
  const audits = [
    AU("a3", "site.created", 30, { target_type: "site", target_id: "s1" }),
    AU("a2", "site.created", 20, { target_type: "site", target_id: "s2" }),
    AU("a1", "site.created", 10, { target_type: "site", target_id: "s1" }),
  ];
  const entries = hooks.mergeTimeline([], audits);
  // Instance default: same action, same actor → one group of 3.
  const byType = hooks.coalesceEntries(entries, hooks.tlvCoalesceKey);
  assert.equal(byType.length, 1);
  assert.equal(byType[0].count, 3);
  // Team-feed key: target s1/s2/s1 are non-consecutive → nothing folds.
  const byTarget = hooks.coalesceEntries(entries, hooks.tlvCoalesceKeyByTarget);
  assert.equal(byTarget.length, 3, "unrelated targets must never fold together");
  assert.ok(byTarget.every((i) => !i.group));
  // mergeTimeline carries the target attribution the key needs.
  assert.equal(entries[0].target, "site:s1");
});

test("D-04: two actors' identical actions never fold under the default key (attribution law)", () => {
  const audits = [
    AU("a2", "token.minted", 20),
    AU("a1", "token.minted", 10, { actor: { id: "u2", email: "bob@acme.com" } }),
  ];
  const items = hooks.coalesceEntries(hooks.mergeTimeline([], audits));
  assert.equal(items.length, 2, "different actors stay separate rows");
});

test("D-04: worst-verdict summary — unanimous says 'all …', mixed states the WORST, never averaged", () => {
  const down = hooks.mergeTimeline(BURST, []);
  assert.equal(hooks.tlvGroupVerdictText(down), "all reporting health: down");
  // 8 up beats around 2 down beats — the summary leads with the bad ones.
  const mixed = hooks.mergeTimeline(
    Array.from({ length: 10 }, (_, i) =>
      EV(30 - i, "health", 600 - i * 60, { health: i === 2 || i === 5 ? "down" : "up" })),
    [],
  );
  assert.equal(hooks.tlvGroupVerdictText(mixed), "2 of 10 reporting health: down");
  // A verify burst with one failure states the failure.
  const verifies = hooks.mergeTimeline(
    [EV(3, "verify", 30, { ok: true, probes: [] }), EV(2, "verify", 20, { ok: false, probes: [] }),
     EV(1, "verify", 10, { ok: true, probes: [] })],
    [],
  );
  assert.equal(hooks.tlvGroupVerdictText(verifies), "1 of 3 failed");
  // Verdict-less types (tls) omit the segment rather than inventing one.
  const tls = hooks.mergeTimeline(
    [EV(2, "tls", 20, { domain: "a" }), EV(1, "tls", 10, { domain: "b" })], []);
  assert.equal(hooks.tlvGroupVerdictText(tls), "");
});

test("D-04: cadence copy — 'every ~1m for 9m' from the members' own stamps; same-second bursts stay silent", () => {
  const entries = hooks.mergeTimeline(BURST, []);
  assert.equal(hooks.tlvGroupCadenceText(entries), "every ~1m for 9m");
  const burst = hooks.mergeTimeline(
    [EV(2, "health", 10, { health: "up" }), EV(1, "health", 10, { health: "up" })], []);
  assert.equal(hooks.tlvGroupCadenceText(burst), "", "no fabricated rhythm for a same-second burst");
  // Approx durations are ONE rounded unit.
  assert.equal(hooks.tlvApproxDur(45 * 1000), "45s");
  assert.equal(hooks.tlvApproxDur(40 * 60 * 1000), "40m");
  assert.equal(hooks.tlvApproxDur(90 * 60 * 1000), "2h", "one rounded unit — never '1h 30m' precision");
  assert.equal(hooks.tlvApproxDur(5 * 3600 * 1000), "5h");
  assert.equal(hooks.tlvApproxDur(3 * 86400 * 1000), "3d");
});

test("D-04: tlvGroupRowHtml closed — badge + '× N' + meta + Show all N; NO member rows in the markup", () => {
  const entries = hooks.mergeTimeline(BURST, []);
  const group = hooks.coalesceEntries(entries)[0];
  const html = hooks.tlvGroupRowHtml(group, { open: false });
  assert.match(html, /tlv-row tlv-coalesce/);
  assert.match(html, /data-tlv-group="g:event\|health:e:21"/); // oldest member anchors
  assert.match(html, /tlv-badge tlv-badge--event/);
  assert.match(html, /Health report <span class="tlv-coalesce-count">&times; 10<\/span>/);
  assert.match(html, /every ~1m for 9m · all reporting health: down/);
  assert.match(html, /data-tlv-group-toggle aria-expanded="false">Show all 10</);
  assert.doesNotMatch(html, /tlv-coalesce-members/, "collapsed groups keep the DOM cheap");
  assert.doesNotMatch(html, /data-tlv-key=/, "no member rows while collapsed");
});

test("D-04: tlvGroupRowHtml open — Collapse + all member rows, each keeping its own Details toggle", () => {
  const entries = hooks.mergeTimeline(BURST, []);
  const group = hooks.coalesceEntries(entries)[0];
  const html = hooks.tlvGroupRowHtml(group, { open: true, expandedKeys: ["e:28"] });
  assert.match(html, /aria-expanded="true">Collapse</);
  assert.match(html, /tlv-coalesce-members/);
  assert.equal(html.split('data-tlv-key="').length - 1, 10, "every member renders");
  // The remembered member detail re-opens; the others stay shut.
  const row28 = html.split('data-tlv-key="e:28"')[1].split('data-tlv-key="')[0];
  assert.match(row28, /aria-expanded="true"/);
});

test("D-04: a verify group with any failure badges verify-fail — the summary badge never lies green", () => {
  const entries = hooks.mergeTimeline(
    [EV(3, "verify", 30, { ok: true, probes: [] }), EV(2, "verify", 20, { ok: false, probes: [] }),
     EV(1, "verify", 10, { ok: true, probes: [] })],
    [],
  );
  const group = hooks.coalesceEntries(entries)[0];
  assert.equal(hooks.tlvGroupBadgeMod(group), "verify-fail");
  assert.match(hooks.tlvGroupRowHtml(group, {}), /tlv-badge tlv-badge--verify-fail/);
  const allPass = hooks.coalesceEntries(hooks.mergeTimeline(
    [EV(2, "verify", 20, { ok: true, probes: [] }), EV(1, "verify", 10, { ok: true, probes: [] })], []))[0];
  assert.equal(hooks.tlvGroupBadgeMod(allPass), "verify");
});

test("D-04: audit group titles keep the actor only while the whole run shares one", () => {
  const same = hooks.coalesceEntries(hooks.mergeTimeline(
    [], [AU("a2", "token.minted", 20), AU("a1", "token.minted", 10)]))[0];
  assert.equal(hooks.tlvGroupTitle(same), "ada@acme.com minted an API token");
  // A custom key that folds mixed actors drops the attribution, never miscredits.
  const mixedEntries = hooks.mergeTimeline(
    [], [AU("a2", "token.minted", 20), AU("a1", "token.minted", 10, { actor: { id: "u2", email: "bob@acme.com" } })]);
  const mixed = hooks.coalesceEntries(mixedEntries, (e) => e.source + "|" + e.type)[0];
  assert.equal(hooks.tlvGroupTitle(mixed), "minted an API token");
});

test("D-04: timelineFeedHtml coalesces the feed and honors openGroups + expandedKeys across repaints", () => {
  const entries = hooks.mergeTimeline([...BURST, EV(5, "status", 30, { transition: "offline" })], []);
  const closed = hooks.timelineFeedHtml(entries, {});
  assert.equal(closed.split("tlv-coalesce\"").length - 1, 1, "ONE summary row for the burst");
  assert.match(closed, /Show all 10/);
  assert.match(closed, /Status → offline/, "the singleton still renders enriched");
  const gkey = closed.match(/data-tlv-group="([^"]+)"/)[1];
  const open = hooks.timelineFeedHtml(entries, { openGroups: [gkey], expandedKeys: ["e:28"] });
  assert.match(open, /aria-expanded="true">Collapse</);
  assert.equal(open.split('data-tlv-key="').length - 1, 11, "10 members + the singleton");
  // The custom groupKey seam I-01 will use is honored end-to-end.
  const flat = hooks.timelineFeedHtml(entries, { groupKey: () => null });
  assert.doesNotMatch(flat, /tlv-coalesce/, "a null key disables folding entirely");
});

test("D-04: the quiet line and teaching empty state survive the coalescing rewrite", () => {
  const entries = hooks.mergeTimeline(BURST, []);
  const html = hooks.timelineFeedHtml(entries, { quietLine: "Audit entries are visible to team admins." });
  assert.match(html, /tlv-quiet/);
  assert.match(html, /tlv-coalesce/);
  assert.match(hooks.timelineFeedHtml([], {}), /Events will appear here as this Barkpark works/);
});

test("D-04: total over junk — nulls, garbled stamps, junk payloads never throw or NaN", () => {
  assert.deepEqual([...hooks.coalesceEntries(null)], []);
  assert.deepEqual([...hooks.coalesceEntries([null, undefined])], []);
  const junk = hooks.mergeTimeline(
    [{ id: 2, type: "health", payload: { health: "down" }, inserted_at: "garbage" },
     { id: 1, type: "health", payload: { health: "down" }, inserted_at: "garbage" }],
    [],
  );
  const items = hooks.coalesceEntries(junk);
  assert.equal(items[0].count, 2);
  assert.equal(hooks.tlvGroupCadenceText(items[0].entries), "", "garbled stamps yield no cadence");
  const html = hooks.tlvGroupRowHtml(items[0], {});
  assert.doesNotMatch(html, /NaN/);
  assert.equal(hooks.tlvVerdictOf(null), null);
  assert.equal(hooks.tlvVerdictOf({ type: "health", payload: {} }), null);
  assert.equal(hooks.tlvCoalesceKey(null), null);
  assert.equal(hooks.tlvCoalesceKeyByTarget(null), null);
});

// ═════════════════════════════════════════════════════════════════════════════
// gr-p3-site-detail (E-02): the v4 site detail — deploy ladder provenance,
// honest duration, the shared failure panel, the proxied domain rung, and the
// siteDetailHtml pins (domains mount, read-only Scale, mono repo button).
// Appended at the tail (OC9).

test("gr-p3: deployTriggerLabel is trigger-only provenance (GR27) — Manual / Content update, never a named human", () => {
  assert.equal(hooks.deployTriggerLabel("manual"), "Manual");
  assert.equal(hooks.deployTriggerLabel("content-auto"), "Content update");
  // Unknown future values humanize (never re-mapped to copy the server didn't say).
  assert.equal(hooks.deployTriggerLabel("some_new-thing"), "some new thing");
  assert.equal(hooks.deployTriggerLabel(null), "");
});

test("gr-p3: deployDuration — two server stamps only; in-flight/missing → null, never a guess", () => {
  const live = { status: "live", inserted_at: "2026-07-19T10:00:00Z", became_live_at: "2026-07-19T10:00:48Z" };
  assert.equal(hooks.deployDuration(live), 48000);
  const failed = { status: "failed", inserted_at: "2026-07-19T10:00:00Z", updated_at: "2026-07-19T10:00:19Z" };
  assert.equal(hooks.deployDuration(failed), 19000);
  const cancelled = { status: "cancelled", inserted_at: "2026-07-19T10:00:00Z", updated_at: "2026-07-19T10:01:00Z" };
  assert.equal(hooks.deployDuration(cancelled), 60000);
  // In-flight: no settled stamp → null (no ticking guess).
  assert.equal(hooks.deployDuration({ status: "building", inserted_at: "2026-07-19T10:00:00Z", updated_at: "2026-07-19T10:00:30Z" }), null);
  // Missing stamps / negative math → null.
  assert.equal(hooks.deployDuration({ status: "live", inserted_at: "2026-07-19T10:00:00Z" }), null);
  assert.equal(hooks.deployDuration({ status: "live", inserted_at: "2026-07-19T11:00:00Z", became_live_at: "2026-07-19T10:00:00Z" }), null);
  assert.equal(hooks.deployDuration(null), null);
});

test("gr-p3: deployRow meta reads env · trigger · duration · when — and NEVER a named human", () => {
  const d = {
    id: "d1", status: "live", git_ref: "9c1f2ab84f00d4e2b16a99871c33d05a72e4f810",
    environment: "production", trigger: "manual",
    inserted_at: "2026-07-19T10:00:00Z", became_live_at: "2026-07-19T10:00:48Z",
  };
  const html = hooks.deployRow(d, "d1");
  assert.match(html, /production/);
  assert.match(html, /Manual/);
  assert.match(html, /48s/);
  assert.match(html, /live since /);
  // GR27/GR28: no actor identity anywhere in the row — provenance is the
  // trigger word alone (an actor field doesn't even exist in deployment_json,
  // and the renderer must never grow one).
  assert.doesNotMatch(html, /actor|@/i);
});

test("gr-p3: deployFailHtml — the v4 red-bordered panel with dot; blocked keeps amber; empty → none", () => {
  const crash = hooks.deployFailHtml("npm run build exited 1");
  assert.match(crash, /class="deploy-fail"/);
  assert.match(crash, /deploy-fail-dot/);
  assert.match(crash, /npm run build exited 1/);
  const blocked = hooks.deployFailHtml("github push builds require the GitHub App integration (not yet available)");
  assert.match(blocked, /deploy-fail--blocked/);
  assert.match(blocked, /can&#39;t be built yet/); // failureCopy still threads through (esc'd)
  assert.equal(hooks.deployFailHtml(""), "");
  assert.equal(hooks.deployFailHtml(null), "");
  // Escaped server copy.
  assert.doesNotMatch(hooks.deployFailHtml("<img src=x>"), /<img src=x>/);
});

test("gr-p3: a cancelled row states its state through the pill, no invented copy", () => {
  const html = hooks.deployRow({ id: "dc", status: "cancelled", inserted_at: "2026-07-19T10:00:00Z", updated_at: "2026-07-19T10:01:00Z" }, null);
  assert.match(html, /dep-pill dep-cancelled/);
  assert.match(html, /Cancelled/);
  assert.doesNotMatch(html, /deploy-fail/); // cancelled is not a failure panel
});

test("cch-w13-s3: the DEPLOY noun has ONE spelling — freshness label and ladder pill agree", () => {
  // Both surfaces render on the SAME site screen ~200px apart: the sites-list /
  // site-header freshness label from freshnessModel, and the ladder pill from
  // cap(status). They disagreed ("Canceled" vs "Cancelled") until cch-w13-s3.
  const d = { status: "cancelled", trigger: "manual", inserted_at: "2026-07-19T10:00:00Z", updated_at: "2026-07-19T10:01:00Z" };
  const fresh = hooks.freshnessModel({ last_deployment: d });
  assert.equal(fresh.label, "Cancelled");
  const pill = hooks.deployRow({ id: "dc", ...d }, null);
  assert.match(pill, new RegExp(">" + fresh.label + "<"));
  // The Stripe SUBSCRIPTION noun is a DIFFERENT word and keeps its own American
  // spelling — this test must not drag billing along with the deploy vocabulary.
  assert.equal(hooks.billingStatusLabel({ status: "canceled" }), "Canceled");
});

test("gr-p3: domainStageRows — proxied is its own settled informational role", () => {
  const rows = hooks.domainStageRows([
    { stage: "dns_found", status: "ok", label: "DNS found" },
    { stage: "points_here", status: "proxied", label: "Points here", evidence: "via Cloudflare" },
    { stage: "tls", status: "pending", label: "TLS" },
    { stage: "serving", status: "pending", label: "Serving" },
  ]);
  assert.equal(rows[1].role, "proxied");
  assert.equal(rows[1].showRemediation, false); // informational, never a fix prompt
  // The rung AFTER a proxied front still gets the honest active motion.
  assert.equal(rows[2].role, "active");
  assert.equal(rows[3].role, "pending");
});

test("gr-p3: domainStages — an all-settled host with a proxied rung is terminal (poll stops)", () => {
  const m = hooks.domainStages({
    ok: true, checked_at: "2026-07-19T10:00:00Z",
    domains: [{ host: "acme.com", kind: "custom", overall: "ok", stages: [
      { stage: "dns_found", status: "ok", label: "DNS found" },
      { stage: "points_here", status: "proxied", label: "Points here" },
      { stage: "tls", status: "ok", label: "TLS" },
      { stage: "serving", status: "ok", label: "Serving" },
    ] }],
  }, 0);
  assert.equal(m.terminal, true);
  const html = hooks.domainChecklistHtml(m, {});
  assert.match(html, /dom-rung--proxied/);
  assert.match(html, /aria-label="Points here — proxied"/);
});

test("gr-p3: siteDetailHtml — domains mount present, Scale stays read-only, repo button is the mono repo name", () => {
  const site = {
    id: "s1", framework: "astro", domains: ["acme.com"], scale_mode: "always_on",
    port: 4321, current_deployment_id: "d1", github_repo: "acme/site",
    github_branch: "main", github_webhook_configured: true, inserted_at: "2026-07-01T10:00:00Z",
  };
  const deployments = [{ id: "d1", status: "live", environment: "production", inserted_at: "2026-07-19T10:00:00Z", became_live_at: "2026-07-19T10:00:40Z" }];
  const html = hooks.siteDetailHtml(site, null, deployments, "acme.com", []);
  assert.match(html, /id="site-domains"/);            // the domains rungs mount
  assert.match(html, /id="deploy-rail-slot"/);        // the live rail slot survives
  // Scale: a read-only rail value — no input/select/toggle control for it (GR28).
  assert.match(html, /Scale<\/span><span class="v">always_on/);
  assert.doesNotMatch(html, /id="site-scale|name="scale/);
  // The connected GitHub button carries the mono repo name (v4 header), not a bare verb.
  assert.match(html, /id="site-github"[^>]*><span class="mono">acme\/site<\/span>/);
  // The headline chip is honest: current live row → Live.
  assert.match(html, /dep-pill dep-live/);
});

test("stw9: siteDetailHtml — the rail reads doc_type back, and a site without one shows an em dash, never an invented default", () => {
  const base = {
    id: "s1", framework: "astro", theme: "ember", scale_mode: "always_on",
    inserted_at: "2026-07-01T10:00:00Z",
  };
  const withType = hooks.siteDetailHtml({ ...base, doc_type: "paper" }, null, [], "", []);
  assert.match(withType, /Content type<\/span><span class="v">paper/);
  // A pre-W10 control plane sends no doc_type: the row is honest, not "post".
  const without = hooks.siteDetailHtml(base, null, [], "", []);
  assert.match(without, /Content type<\/span><span class="v">—/);
  assert.doesNotMatch(without, /Content type<\/span><span class="v">post/);
});

// ── ssw8 (charter D82): THE CONTENT BINDING + THE UNBACKED-CLAIM INVARIANT ───
//
// site_json/2 serializes eleven binding fields; the console rendered one. These
// pin the model AND the law that made the slice worth cutting: A SITE SURFACE
// MUST RENDER NO CLAIM NO PAYLOAD FIELD BACKS. The invariant test below is
// MUTATION-PROVEN — each arm was verified to go red against a renderer that
// invents a value (see the commit message for the pasted reds).

// Scoped readers: pull ONE rail row's value / the binding pill's label+title out
// of the detail markup. Scoped on purpose — a whole-document scan for
// "default" would trip on the theme select's real "Template default" option
// label, which is a control's name, not a claim about this site.
const railValueOf = (html, key) => {
  const m = html.match(new RegExp(">" + key + "</span><span class=\"v\">([^<]*)<"));
  return m && m[1];
};
const bindingPillOf = (html) => {
  const m = html.match(/<span class="status-pill status-pill--(\w+)" title="([^"]*)"><span class="status-pill-dot"[^>]*><\/span><span class="status-pill-label">([^<]*)</);
  return m && { role: m[1], title: m[2], label: m[3] };
};

test("ssw8 siteBindingModel: every state is derived from a payload field, and content_bound is read as a TOKEN promise", () => {
  const M = (over) => hooks.siteBindingModel(over);
  // Bound: the triple agrees with itself and a read token exists. The label
  // says READ TOKEN — content_bound is `not is_nil(read_token_encrypted)`, so
  // "this site has content" is a claim no field backs.
  const bound = M({
    workspace: "acme", bootstrap_workspace: "acme",
    project: "site", bootstrap_project: "site",
    dataset: "production", bootstrap_dataset: "production",
    content_bound: true,
  });
  assert.equal(bound.path, "acme/site/production");
  assert.equal(bound.pathState, "ok");
  assert.equal(bound.role, "ok");
  assert.equal(bound.label, "Read token stored");
  assert.ok(!/has content|is bound\b/i.test(bound.label + " " + bound.title), "never promises content");
  // A triple with NO read token is a real defect the payload states outright.
  const noToken = M({ workspace: "a", project: "b", dataset: "c", content_bound: false });
  assert.equal(noToken.role, "danger");
  assert.equal(noToken.label, "No read token");
  // content_bound ABSENT (an older control plane) is UNKNOWN, never false.
  const oldCp = M({ workspace: "a", project: "b", dataset: "c" });
  assert.equal(oldCp.token, "unknown");
  assert.equal(oldCp.label, "Read token unknown");
  assert.equal(oldCp.role, "neutral", "unknown is neutral — not a green, not a red");
  // The two vocabularies of the SAME column disagreeing: both render, neither wins.
  const clash = M({
    workspace: "acme", bootstrap_workspace: "acme",
    project: "site", bootstrap_project: "site",
    dataset: "production", bootstrap_dataset: "producton",
    content_bound: true,
  });
  assert.equal(clash.pathState, "mismatch");
  assert.equal(clash.role, "danger");
  assert.equal(clash.label, "Binding mismatch");
  assert.ok(clash.path.includes("production") && clash.path.includes("producton"),
    "a self-contradictory payload shows BOTH spellings — the renderer breaks no ties");
  // A HALF-written triple is incomplete, not "ok with an em dash".
  const partial = M({ workspace: "acme", dataset: "production", content_bound: true });
  assert.equal(partial.pathState, "partial");
  assert.equal(partial.role, "danger");
  assert.equal(partial.label, "Binding incomplete");
  // Nothing at all: unknown, and the LIST chip stays silent (a repo-deploy site
  // has no binding to report — the detail rail still spells it out).
  const nothing = M({});
  assert.equal(nothing.path, "—");
  assert.equal(nothing.label, "Binding unknown");
  assert.equal(nothing.silent, true);
  assert.equal(hooks.siteBindingChip({}), "");
});

test("ssw8 INVARIANT: no site surface renders a binding claim no payload field backs", () => {
  // The vocabulary a renderer could plausibly INVENT. Every one of these is a
  // REAL default somewhere in this product (`production` is the documented
  // default dataset, `post` the default doc type, `default` the default
  // workspace/project) — which is exactly what makes them the tempting lie on a
  // surface whose payload does not carry them.
  const INVENTABLE = /\b(production|default|post|entry|paper|bound)\b/i;
  const SENT = { ws: "zzws", pr: "zzpr", ds: "zzds", ty: "zzty" };
  const full = () => ({
    id: "s1", slug: "s1", framework: "astro", inserted_at: "2026-07-01T10:00:00Z",
    workspace: SENT.ws, bootstrap_workspace: SENT.ws,
    project: SENT.pr, bootstrap_project: SENT.pr,
    dataset: SENT.ds, bootstrap_dataset: SENT.ds,
    doc_type: SENT.ty, content_bound: true,
  });
  const surfaces = (s) => [hooks.siteDetailHtml(s, null, [], "", []), hooks.siteRow(s, null)];

  // ARM 1 — ABLATION. Delete one binding CONCEPT at a time (both spellings of
  // it). Its sentinel must vanish from every site surface: a value that
  // survives its own field's deletion is, by definition, unbacked.
  const CONCEPTS = {
    workspace: ["workspace", "bootstrap_workspace"],
    project: ["project", "bootstrap_project"],
    dataset: ["dataset", "bootstrap_dataset"],
    "content type": ["doc_type"],
  };
  for (const [concept, fields] of Object.entries(CONCEPTS)) {
    const s = full();
    const values = fields.map((f) => String(s[f]));
    fields.forEach((f) => { delete s[f]; });
    for (const html of surfaces(s)) {
      for (const v of values) {
        assert.ok(!html.includes(v),
          concept + " was removed from the payload but " + v + " still renders");
      }
    }
  }

  // ARM 2 — THE EMPTY PAYLOAD. A site carrying NO binding field at all: the rail
  // reads honest placeholders and the binding rows contain nothing from the
  // plausible-default vocabulary.
  const bare = { id: "s1", framework: "astro", inserted_at: "2026-07-01T10:00:00Z" };
  const bareRail = hooks.siteDetailHtml(bare, null, [], "", []);
  assert.equal(railValueOf(bareRail, "Content dataset"), "—");
  assert.equal(railValueOf(bareRail, "Content type"), "—");
  const barePill = bindingPillOf(bareRail);
  assert.equal(barePill.label, "Binding unknown");
  assert.equal(barePill.role, "neutral");
  for (const claim of [
    railValueOf(bareRail, "Content dataset"),
    railValueOf(bareRail, "Content type"),
    barePill.label, barePill.title,
  ]) {
    assert.ok(!INVENTABLE.test(claim),
      "an unbacked binding surface invented a value: " + JSON.stringify(claim));
  }
  // …and the list chip says nothing rather than inventing a state to show.
  assert.equal(hooks.siteBindingChip(bare), "");
  assert.ok(!hooks.siteRow(bare, null).includes("status-pill"), "no chip on an unbound row");

  // ARM 3 — SELF-CONTRADICTION IS REPORTED, NOT RESOLVED. Both spellings of the
  // dataset reach the surface; picking one would be a claim the payload denies.
  const clash = Object.assign(full(), { bootstrap_dataset: "zzOTHER" });
  const clashRail = hooks.siteDetailHtml(clash, null, [], "", []);
  const clashValue = railValueOf(clashRail, "Content dataset");
  assert.ok(clashValue.includes(SENT.ds) && clashValue.includes("zzOTHER"),
    "both spellings render: " + clashValue);
  assert.equal(bindingPillOf(clashRail).label, "Binding mismatch");
  assert.ok(hooks.siteRow(clash, null).includes("status-pill--danger"),
    "the row chip carries the contradiction too — the list is where a stranger looks first");

  // ARM 4 — EVERY RENDERED BINDING VALUE TRACES TO A PAYLOAD VALUE. On the fully
  // populated site the rail's binding rows are EXACTLY the sentinels, so nothing
  // in them came from anywhere but the response.
  const rail = hooks.siteDetailHtml(full(), null, [], "", []);
  assert.equal(railValueOf(rail, "Content dataset"), SENT.ws + "/" + SENT.pr + "/" + SENT.ds);
  assert.equal(railValueOf(rail, "Content type"), SENT.ty);
  const pill = bindingPillOf(rail);
  assert.equal(pill.label, "Read token stored");
  assert.equal(pill.role, "ok");
  // The token promise is stated as a token, never upgraded into a content claim.
  assert.ok(!/has content|site is bound|content bound/i.test(pill.label + " " + pill.title),
    "content_bound renders as 'a read token exists', never as 'this site has content'");
});

test("ssw8 siteRow: the FIRST row a stranger sees — real fields, a binding chip only when the payload has one", () => {
  const s = {
    id: "site-1", name: "acme-docs", slug: "acme-docs", framework: "astro",
    domains: ["docs.acme.com"], github_repo: "acme/docs", github_branch: "main",
    github_webhook_configured: true,
    workspace: "acme", bootstrap_workspace: "acme",
    project: "site", bootstrap_project: "site",
    dataset: "production", bootstrap_dataset: "production",
    content_bound: true,
  };
  const html = hooks.siteRow(s, { id: "bp-1", name: "Production", url: "https://acme.barkpark.cloud" });
  assert.ok(html.includes('class="site-row" data-id="site-1"'), "the row is the drill-in target");
  assert.ok(html.includes(">docs.acme.com<"), "the primary domain names the row");
  assert.ok(html.includes("astro"), "the framework renders");
  assert.ok(html.includes("acme/docs") && html.includes("@main"), "the linked repo renders");
  assert.ok(html.includes("Auto-deploy"), "the auto-deploy chip renders");
  assert.ok(html.includes("status-pill--ok") && html.includes(">Read token stored<"),
    "a content-bound row carries the binding chip");
  assert.ok(html.includes("acme/site/production"), "the chip's tooltip names the dataset it reads");
  // A repo-deploy site with no binding at all: no chip, no invented state.
  const plain = hooks.siteRow(
    { id: "site-2", slug: "acme-app", framework: "nextjs", github_webhook_configured: false }, null);
  assert.ok(!plain.includes("status-pill"), "an unbound row shows no binding chip");
  assert.ok(plain.includes("not linked") && plain.includes("Manual"), "and still reads honestly otherwise");
});

// ── cch-w16-s4 (charter D199): NO DOOR TO A SITE THAT HAS NEVER BEEN DEPLOYED ─
//
// Until this slice the console painted `Not deployed` and, in the SAME 8px flex
// run, `<a class="site-open" title="Open the live site">Visit ↗</a>` — because
// the affordance was gated on `siteLiveUrl`, which MANUFACTURES a URL out of the
// instance host whenever the row carries a slug. There was ZERO coverage: this
// file had never mentioned site-open, siteOpenLink or Visit, and the geometric
// breakpoint sweep is structurally blind to a semantic contradiction.
//
// The states below are the shipped corpus, and the guard reads BOTH directions
// on purpose. Removing the door from the rebuilding and deploy-failed rows would
// be the same defect mirrored — a static site mid-rebuild is still serving its
// previous build — which is exactly why the predicate is the production POINTER
// and not `last_deployment.status === "live"`.
const S4_STATES = [
  { name: "live", current_deployment_id: "d-live", last_deployment: { status: "live", trigger: "content-auto" }, door: true },
  { name: "rebuilding", current_deployment_id: "d-prev", last_deployment: { status: "building", trigger: "content-auto" }, door: true },
  { name: "deploy-failed", current_deployment_id: "d-prev", last_deployment: { status: "failed", trigger: "manual" }, door: true },
  { name: "cancelled", current_deployment_id: "d-prev", last_deployment: { status: "cancelled", trigger: "manual" }, door: true },
  { name: "never-deployed", current_deployment_id: null, last_deployment: null, door: false },
  { name: "preview-only", current_deployment_id: null, last_deployment: null, previews_enabled: true, door: false },
];
const s4Site = (st) => ({
  id: "site-" + st.name, name: "acme-" + st.name, slug: "acme-" + st.name,
  domains: [st.name + ".acme.com"], framework: "nextjs",
  github_webhook_configured: true,
  current_deployment_id: st.current_deployment_id,
  ...(st.last_deployment ? { last_deployment: st.last_deployment } : {}),
  ...(st.previews_enabled ? { previews_enabled: true } : {}),
});
const S4_BP = { id: "bp-1", name: "Production", url: "https://acme.barkpark.cloud" };

test("cch-w16-s4: siteHasEverDeployed is the ONE predicate — the production pointer, not the URL and not the last row", () => {
  // A URL is derivable for EVERY state (siteLiveUrl manufactures one from the
  // instance host), so the URL can never be the gate.
  for (const st of S4_STATES) {
    assert.ok(hooks.siteLiveUrl(s4Site(st), S4_BP), st.name + " has a derivable URL either way");
    assert.equal(hooks.siteHasEverDeployed(s4Site(st)), st.door, st.name + " → door " + st.door);
  }
  // The REFUSED predicate, spelled out so its refusal cannot quietly regress:
  // it would strip a WORKING door from two states that are still serving.
  const refused = (s) => !!(s.last_deployment && s.last_deployment.status === "live");
  const stripped = S4_STATES.filter((st) => st.door && !refused(s4Site(st))).map((st) => st.name);
  assert.deepEqual(stripped, ["rebuilding", "deploy-failed", "cancelled"],
    "last_deployment.status==='live' would close three doors that still open");
  // Absent/garbage payloads fail CLOSED — no door invented out of nothing.
  for (const bad of [null, undefined, {}, { current_deployment_id: null }, { current_deployment_id: "" }]) {
    assert.equal(hooks.siteHasEverDeployed(bad), false, "a payload with no pointer offers no door");
  }
});

test("cch-w16-s4: all FOUR Visit anchors are gated — siteRow, globalSiteRow and BOTH detail-head doors", () => {
  for (const st of S4_STATES) {
    const s = s4Site(st);
    const row = hooks.siteRow(s, S4_BP);
    const global = hooks.globalSiteRow(s, S4_BP);
    // Anchors 3 and 4 live in the SAME function: the .fleet-url full-URL run and
    // the .fleet-badges Visit button. Gating siteOpenLink alone fixes neither.
    const detail = hooks.siteDetailHtml(s, S4_BP, [], s.domains[0], []);
    const badges = detail.slice(detail.indexOf('class="fleet-badges"'));
    const url = detail.slice(detail.indexOf('class="fleet-url"'), detail.indexOf('class="fleet-badges"'));
    if (st.door) {
      assert.ok(row.includes('class="site-open"'), st.name + ": siteRow keeps its door");
      assert.ok(global.includes('class="site-open"'), st.name + ": globalSiteRow keeps its door");
      assert.ok(url.includes('class="site-open"'), st.name + ": the .fleet-url full-URL link stays");
      assert.ok(badges.includes("site-open"), st.name + ": the .fleet-badges Visit button stays");
      assert.equal(countAll(detail, "site-open"), 2, st.name + ": exactly the two detail-head doors");
    } else {
      assert.ok(!row.includes("site-open"), st.name + ": siteRow offers NO door");
      assert.ok(!global.includes("site-open"), st.name + ": globalSiteRow offers NO door");
      assert.ok(!url.includes("site-open"), st.name + ": no full-URL link on the detail head");
      assert.ok(!badges.includes("site-open"), st.name + ": no Visit button on the detail head");
      assert.equal(countAll(detail, "site-open"), 0, st.name + ": zero live-open affordances anywhere on the detail");
      // …and the contradiction itself: never "Not deployed" beside a live door.
      assert.ok(global.includes(">Not deployed<"), st.name + ": the list still says what is true");
      assert.ok(!global.includes("Open the live site"),
        st.name + ": nothing offers to open a site the same row calls Not deployed");
    }
  }
});

test("cch-w16-s4: the never-deployed DETAIL grows the neutral chip — it used to say nothing at all", () => {
  const never = s4Site(S4_STATES[4]);
  const detail = hooks.siteDetailHtml(never, S4_BP, [], "acme-never.acme.com", []);
  assert.equal(countAll(detail, "dep-pill"), 1, "exactly one status chip in the head");
  assert.ok(detail.includes(">Not deployed</span>"), "the visible copy matches the LIST word for word");
  assert.ok(detail.includes('title="Not deployed to production"'), "the tooltip names the environment");
  assert.ok(detail.includes('aria-label="Not deployed to production"'), "and so does the accessible name");
  // The deployed detail is unchanged: a live pointer + a live row still reads Live.
  const liveDetail = hooks.siteDetailHtml(
    s4Site(S4_STATES[0]), S4_BP, [{ id: "d-live", status: "live" }], "acme-live.acme.com", []);
  assert.ok(liveDetail.includes("dep-live") && !liveDetail.includes(">Not deployed<"),
    "a live site is untouched by the neutral case");
});

test("cch-w16-s4: siteOpenLink itself stays honest — a null URL renders nothing to click", () => {
  assert.equal(hooks.siteOpenLink(null), "");
  assert.equal(hooks.siteOpenLink(""), "");
  const a = hooks.siteOpenLink("https://acme.barkpark.cloud/sites/blog/");
  assert.ok(a.includes('rel="noopener"') && a.includes('target="_blank"'), "the door still opens in a new tab");
});

// Count every occurrence of a literal — the gate assertions need a COUNT, not a
// presence: "two doors became one" is the regression this file exists to catch.
function countAll(hay, needle) {
  return hay.split(needle).length - 1;
}

test("ssw8: siteLiveUrl — the manufactured 'Visit ↗' strips to URL-safe BEFORE escaping, never after", () => {
  const bp = { url: "https://acme.barkpark.cloud/" };
  // The payload's own url always wins — nothing is manufactured when the server sent one.
  assert.equal(hooks.siteLiveUrl({ url: "https://x.test/s/" }, bp), "https://x.test/s/");
  // The normal case: trailing slash on the box url is collapsed, one is appended.
  assert.equal(hooks.siteLiveUrl({ slug: "blog" }, bp), "https://acme.barkpark.cloud/sites/blog/");
  // THE ORDERING. esc()-then-strip turned `a&b` into `a&amp;b` and the strip kept
  // the escape's LETTERS, yielding /sites/aampb/ — a confident link to a site that
  // does not exist. Strip-then-nothing drops the metacharacter instead.
  assert.equal(hooks.siteLiveUrl({ slug: "a&b" }, bp), "https://acme.barkpark.cloud/sites/ab/");
  assert.ok(!hooks.siteLiveUrl({ slug: "a&b" }, bp).includes("amp"),
    "an HTML entity's letters must never survive into a URL path");
  for (const s of ["a<b", 'a"b', "a'b", "a>b"]) {
    assert.equal(hooks.siteLiveUrl({ slug: s }, bp), "https://acme.barkpark.cloud/sites/ab/");
  }
  // No box url and no site url: null, so callers render no link rather than a broken one.
  assert.equal(hooks.siteLiveUrl({ slug: "blog" }, null), null);
  assert.equal(hooks.siteLiveUrl({}, bp), null);
});

test("gr-p3: siteStatusChip — Deploying while in flight, Live only when the pointer names a live row, else nothing", () => {
  const site = { current_deployment_id: "d1" };
  const live = [{ id: "d1", status: "live" }];
  assert.match(hooks.siteStatusChip(site, live), /dep-live/);
  const building = [{ id: "d2", status: "building" }, { id: "d1", status: "live" }];
  assert.match(hooks.siteStatusChip(site, building), /dep-building">Deploying/);
  // Pointer names a row that is not in the list (stale) → no chip, never invented.
  // This site HAS served a build, so "Not deployed" here would be the same lie
  // in the other direction: silence is the only honest answer.
  assert.equal(hooks.siteStatusChip({ current_deployment_id: "dx" }, live), "");
  // cch-w16-s4: a NEVER-deployed site used to take this same bare "" — so the
  // detail head said NOTHING about deployment while offering two doors to the
  // site. It now takes D182's ruled pair.
  const never = hooks.siteStatusChip({}, []);
  assert.match(never, /class="dep-pill"/, "the neutral chip rides the BARE base class — this slice ships no CSS");
  assert.ok(!/dep-live|dep-building|dep-queued|dep-failed/.test(never), "no borrowed status colour");
  assert.match(never, />Not deployed</, "the VISIBLE copy is the list's word for word");
  assert.match(never, /title="Not deployed to production"/, "the tooltip names the environment");
  assert.match(never, /aria-label="Not deployed to production"/, "…and so does the accessible name");
});

test("gr-p3: previewRow meta carries preview env + provenance + duration; failed preview gets the shared panel", () => {
  const d = {
    id: "p1", status: "failed", branch: "draft/nav", trigger: "manual",
    failure_reason: "npm run build exited 1",
    inserted_at: "2026-07-19T10:00:00Z", updated_at: "2026-07-19T10:00:19Z",
  };
  const html = hooks.previewRow ? hooks.previewRow(d) : null;
  if (html !== null) {
    assert.match(html, /preview/);
    assert.match(html, /Manual/);
    assert.match(html, /19s/);
    assert.match(html, /deploy-fail-dot/);
  }
});

// ── gr-p4-billing (G-01): owner-honest gate + the button-free read-only card ──
test("billingCanManage / billingHasPaidPlan: owner-honest gate + paid-plan test (GR36)", () => {
  // Owner-only writes: only the literal "owner" role manages billing (stricter
  // than admin — require_primary_team_owner).
  assert.equal(hooks.billingCanManage("owner"), true);
  assert.equal(hooks.billingCanManage("admin"), false, "admin is NOT an owner — billing is stricter");
  assert.equal(hooks.billingCanManage("member"), false);
  assert.equal(hooks.billingCanManage(undefined), false);
  // A real paid plan (a non-free catalog plan in an active/past_due state) has a
  // portal to open and a plan to cancel; a trial / free / canceled does not.
  assert.equal(hooks.billingHasPaidPlan({ plan: "supporter", status: "active" }), true);
  assert.equal(hooks.billingHasPaidPlan({ plan: "support_plus", status: "past_due" }), true);
  assert.equal(hooks.billingHasPaidPlan({ plan: "trial", status: "active" }), false, "a trial is not a paid Stripe plan");
  assert.equal(hooks.billingHasPaidPlan({ plan: "free", status: "active" }), false);
  assert.equal(hooks.billingHasPaidPlan({ plan: "supporter", status: "canceled" }), false, "canceled has no live portal");
  assert.equal(hooks.billingHasPaidPlan(null), false);
});

test("readOnlyPlanCardHtml: the non-owner view is a button-free summary reusing the pure models (GR36 plain-member law)", () => {
  const paid = hooks.readOnlyPlanCardHtml({ plan: "supporter", status: "active", current_period_end: "2026-08-01T12:00:00.000Z" });
  assert.ok(paid.includes(">Supporter<"), "reads the real plan name");
  assert.ok(paid.includes("3 managed instances"), "reuses the quota-honest features verbatim");
  assert.ok(paid.includes("Renews "), "reuses billingPeriodLine");
  // Never a write affordance — no buttons, no grid toggle, no portal copy.
  assert.ok(!/<button/i.test(paid), "no buttons in the read-only card");
  assert.ok(!paid.includes("plan-more") && !/Manage billing/i.test(paid), "no CTAs at all");
  // A cancelling paid plan surfaces "Access until" honestly, still button-free.
  const ending = hooks.readOnlyPlanCardHtml({ plan: "supporter", status: "active", cancel_at_period_end: true, current_period_end: "2026-08-01T12:00:00.000Z" });
  assert.ok(ending.includes("Access until ") && ending.includes(">Ending<"), "a cancelling plan reads Access-until + the Ending badge");
  const trial = hooks.readOnlyPlanCardHtml({ plan: "trial", status: "active", trial_days_remaining: 9 });
  assert.ok(trial.includes("Free trial") && trial.includes("9 days left"), "trial summary carries the countdown");
  assert.ok(!/<button/i.test(trial) && !/Pick a plan below/i.test(trial), "no CTA and no misleading 'pick a plan below' (the grid is hidden for members)");
});

// ════════════════════════════════════════════════════════════════════════════
// G-04 — Notifications (the crown): the settings-anatomy pure builders
// (GR33 form-page anatomy, GR34 check grammars, GR36 per-page rulings)
// ════════════════════════════════════════════════════════════════════════════

test("G-04: the notification builders + routing helpers are exported", () => {
  for (const name of ["notifMatrixColumns", "notifChannelState", "notifCellState",
    "notifEventChannels", "notifTransportLabel", "notifDeliveryTone", "notifDeliveryStatusLabel",
    "notifDeliveryRowHtml", "notifDeliveriesHtml", "notifDeliveriesErrorHtml",
    "notifEmailSectionHtml", "notifChannelsSectionHtml", "notifChannelRowHtml",
    "notifMatrixSectionHtml", "notifMatrixCellHtml", "notifDeliveriesShellHtml",
    "notifMemberAdminNoticeHtml", "notifPageHtml"]) {
    assert.equal(typeof hooks[name], "function", name + " must be exported");
  }
  // The 6 matrix columns are email + the 5 ChannelConfig chat types, in order.
  assert.deepEqual([...hooks.notifMatrixColumns()].map((c) => c.type),
    ["email", "discord", "slack", "telegram", "pushover", "webhook"]);
  assert.deepEqual([...hooks.notifChannels], ["discord", "slack", "telegram", "pushover", "webhook"]);
});

// ── notifCellState: the honest per-cell truth ───────────────────────────────

test("G-04 notifCellState: email column reads the per-event boolean", () => {
  const s = { deployment_failed: true, provision_succeeded: false };
  assert.equal(hooks.notifCellState(s, "deployment_failed", "email").on, true);
  assert.equal(hooks.notifCellState(s, "provision_succeeded", "email").on, false);
  // never flagged default — email is an explicit boolean either way.
  assert.equal(hooks.notifCellState(s, "deployment_failed", "email").isDefault, false);
});

test("G-04 notifCellState: an explicit chat route wins over the default", () => {
  const s = {
    channels: [{ type: "discord", enabled: true, configured: true }],
    event_routes: { provision_failed: ["discord"] },
    chat_default_on: ["provision_failed"],
  };
  const st = hooks.notifCellState(s, "provision_failed", "discord");
  assert.equal(st.on, true);
  assert.equal(st.isDefault, false, "an explicit route is NOT a default");
});

test("G-04 notifCellState: a chat_default_on failure event fans to enabled channels as an honest DEFAULT", () => {
  const s = {
    channels: [{ type: "discord", enabled: true, configured: true }, { type: "slack", enabled: false, configured: false }],
    event_routes: {}, // never customized
    chat_default_on: ["provision_failed"],
  };
  const on = hooks.notifCellState(s, "provision_failed", "discord");
  assert.equal(on.on, true);
  assert.equal(on.isDefault, true, "an un-customized failure event renders as a default, not a choice");
  // A disabled channel can't receive — off, even for a default-on event.
  assert.equal(hooks.notifCellState(s, "provision_failed", "slack").on, false);
  // A non-default event with no route is simply off.
  assert.equal(hooks.notifCellState(s, "deployment_succeeded", "discord").on, false);
});

// ── notifEventChannels: the PUT /events body over the materialized set ───────

test("G-04 notifEventChannels: the first edit of a default event materializes the whole fan-out", () => {
  const s = {
    channels: [{ type: "discord", enabled: true }, { type: "slack", enabled: true }, { type: "webhook", enabled: false }],
    event_routes: {},
    chat_default_on: ["provision_failed"],
  };
  // Turning discord OFF must keep slack (the other default) — not silently drop it.
  assert.deepEqual([...hooks.notifEventChannels(s, "provision_failed", "discord", false)].sort(), ["slack"]);
  // Turning a third channel ON extends the materialized set.
  assert.deepEqual([...hooks.notifEventChannels(s, "provision_failed", "webhook", true)].sort(), ["discord", "slack", "webhook"]);
});

test("G-04 notifEventChannels: an explicitly-routed event edits its stored list", () => {
  const s = { event_routes: { deployment_failed: ["discord"] }, channels: [], chat_default_on: [] };
  assert.deepEqual([...hooks.notifEventChannels(s, "deployment_failed", "slack", true)].sort(), ["discord", "slack"]);
  assert.deepEqual([...hooks.notifEventChannels(s, "deployment_failed", "discord", false)], []);
  // A non-default event with no route starts empty.
  assert.deepEqual([...hooks.notifEventChannels(s, "member_invited", "discord", true)], ["discord"]);
});

// ── delivery-log grammar ─────────────────────────────────────────────────────

test("G-04 notifDeliveryTone: sent→ok, failed→danger, pending→info, http_status overrides", () => {
  assert.equal(hooks.notifDeliveryTone({ status: "sent" }), "ok");
  assert.equal(hooks.notifDeliveryTone({ status: "failed" }), "danger");
  assert.equal(hooks.notifDeliveryTone({ status: "pending" }), "info");
  assert.equal(hooks.notifDeliveryTone({ status: "sent", http_status: 500 }), "danger");
  assert.equal(hooks.notifDeliveryTone({ http_status: 204 }), "ok");
});

test("G-04 notifDeliveryStatusLabel: http code → '204 OK'/'HTTP 500', else the status word", () => {
  assert.equal(hooks.notifDeliveryStatusLabel({ http_status: 200 }), "200 OK");
  assert.equal(hooks.notifDeliveryStatusLabel({ http_status: 500 }), "HTTP 500");
  assert.equal(hooks.notifDeliveryStatusLabel({ status: "failed" }), "Failed");
  assert.equal(hooks.notifDeliveryStatusLabel({ status: "pending" }), "Pending");
});

test("G-04 notifDeliveryRowHtml: recipient + toned pill + meta + verbatim error", () => {
  const row = hooks.notifDeliveryRowHtml({
    recipient: "alerts@acme.com", event: "provision_failed", channel: "email",
    status: "failed", attempts: 3, last_error: "smtp 550 mailbox unavailable", http_status: null,
    inserted_at: "2026-07-19T10:00:00Z",
  });
  assert.match(row, /wh-del-row/);
  assert.match(row, /alerts@acme\.com/);
  assert.match(row, /wh-del-status--danger/);
  assert.match(row, /Failed/);
  assert.match(row, /3 attempts/);
  assert.match(row, /wh-del-err/);
  assert.match(row, /smtp 550 mailbox unavailable/);
  // A chat row records the channel type as recipient — never a leaked URL.
  const chat = hooks.notifDeliveryRowHtml({ recipient: "discord", channel: "discord", event: "deployment_failed", status: "sent", attempts: 1, http_status: 204 });
  assert.match(chat, /204 OK/);
  assert.match(chat, /wh-del-status--ok/);
  assert.doesNotMatch(chat, /wh-del-err/);
});

test("G-04 notifDeliveriesHtml: populated card vs honest empty; error degrade is distinct", () => {
  assert.match(hooks.notifDeliveriesHtml([{ recipient: "x", status: "sent" }]), /wh-del-card/);
  assert.match(hooks.notifDeliveriesHtml([]), /No notifications have been delivered yet/);
  assert.match(hooks.notifDeliveriesErrorHtml(), /Couldn't load the delivery log/);
});

// ── channel roster (GR34 .set-check) ─────────────────────────────────────────

test("G-04 notifChannelRowHtml: configured honesty, write-only creds, consequence sub-line, gated test", () => {
  const s = { channels: [{ type: "discord", enabled: true, configured: true }] };
  const discord = { type: "discord", label: "Discord", off: "Off = Discord stops receiving routed events.",
    fields: [{ k: "url", label: "Webhook URL", ph: "https://discord.com/api/webhooks/…" }] };
  const row = hooks.notifChannelRowHtml(s, discord);
  assert.match(row, /set-check/);
  assert.match(row, /set-cred-tag">configured/);
  assert.match(row, /Off = Discord stops receiving routed events\./, "the mandatory consequence sub-line renders");
  // Write-only: a configured channel shows the sealed placeholder, never the value.
  assert.match(row, /stored/);
  assert.match(row, /data-notif-chan-test="discord"/, "an enabled+configured channel offers a test");

  // Not configured: the empty tag + the real placeholder + NO test affordance.
  const empty = hooks.notifChannelRowHtml({ channels: [] }, discord);
  assert.match(empty, /set-cred-tag--empty">not configured/);
  assert.match(empty, /discord\.com\/api\/webhooks/);
  assert.doesNotMatch(empty, /data-notif-chan-test/);
});

// ── the routing matrix (GR36) ────────────────────────────────────────────────

test("G-04 notifMatrixSectionHtml: 6 columns, dashed defaults, honest always-send test row", () => {
  const s = {
    channels: [{ type: "discord", enabled: true, configured: true }],
    event_routes: {}, chat_default_on: ["provision_failed"],
  };
  const html = hooks.notifMatrixSectionHtml(s);
  assert.match(html, /set-matrix-grid/);
  // One label column header (corner) + 6 channel columns.
  assert.equal((html.match(/set-matrix-col/g) || []).length, 6, "6 channel columns render");
  assert.match(html, /set-matrix-cell--default/, "a default-on failure cell is dashed");
  assert.match(html, /Always sent to every enabled channel/, "the test row states always-send");
  assert.doesNotMatch(html, /data-event="test"/, "the test row is NOT a lying toggle");
  // A disabled/absent chat channel column is flagged off in its header.
  assert.match(html, /set-matrix-off/);
});

// ── email section + page composition (GR33 plain-member law) ─────────────────

test("G-04 notifEmailSectionHtml: admin gets a save-row + seg; member is read-only", () => {
  const s = { transport: "smtp", alerts_enabled: true, from_address: "a@acme.com", smtp_host: "********" };
  const admin = hooks.notifEmailSectionHtml(s, true);
  assert.match(admin, /notif-transport-seg/);
  assert.match(admin, /set-save-row/);
  assert.match(admin, /notif-email-save/);
  assert.match(admin, /stored/, "a stored SMTP secret shows the sealed placeholder, never a value");

  const member = hooks.notifEmailSectionHtml(s, false);
  assert.match(member, /set-readonly/);
  assert.doesNotMatch(member, /set-save-row/, "member email section has NO save-row");
  assert.doesNotMatch(member, /notif-email-save/, "member email section has NO save button");
  assert.doesNotMatch(member, /form-input/, "member email section has NO inputs");
  assert.match(member, /a@acme\.com/, "the read-only view still shows the value");
});

test("G-04 notifPageHtml: admin composes every section; member gets read-only + honest notice", () => {
  const s = { transport: "instance", channels: [], event_routes: {}, chat_default_on: [] };
  const admin = hooks.notifPageHtml(s, { canManage: true });
  for (const needle of ["Email delivery", "Chat channels", "Event routing", "Delivery log"]) {
    assert.ok(admin.includes(needle), "admin page includes " + needle);
  }
  const member = hooks.notifPageHtml(s, { canManage: false });
  assert.match(member, /managed by team admins/);
  assert.doesNotMatch(member, /set-save-row/, "member page has ZERO save-rows");
  assert.doesNotMatch(member, /set-matrix-grid/, "member page has no routing matrix");
});

test("G-04 notifTransportLabel: the platform transport reads friendly", () => {
  assert.equal(hooks.notifTransportLabel("instance"), "Barkpark platform");
  assert.equal(hooks.notifTransportLabel("smtp"), "SMTP");
});

// ── GR80 leg 1: the two-factor challenge countdown rides the server ──────────

test("GR80 leg 1: tfaRetryAfterSecs takes the server's number and rejects unusable ones", () => {
  assert.equal(hooks.tfaRetryAfterSecs({ status: 429, data: { error: "rate_limited", retry_after: 37 } }), 37);
  // A fractional 4.2s left still means the caller must wait 5.
  assert.equal(hooks.tfaRetryAfterSecs({ data: { retry_after: 4.2 } }), 5);
  assert.equal(hooks.tfaRetryAfterSecs({ data: { retry_after: "12" } }), 12, "a stringified number is still a number");
  // Everything unusable falls back (null) rather than painting a button that
  // re-enables instantly straight into the same 429.
  for (const bad of [undefined, null, "", 0, -5, "soon", NaN, Infinity]) {
    assert.equal(hooks.tfaRetryAfterSecs({ data: { retry_after: bad } }), null,
      "retry_after " + JSON.stringify(String(bad)) + " must fall back");
  }
  assert.equal(hooks.tfaRetryAfterSecs({ data: {} }), null);
  assert.equal(hooks.tfaRetryAfterSecs(null), null);
});

test("GR80 leg 1: the challenge 429 carries retryAfter; the constant is only the fallback", () => {
  const withHint = hooks.twoFactorChallengeOutcome({ ok: false, status: 429, data: { error: "rate_limited", retry_after: 18 } });
  assert.equal(withHint.state, "rate_limited");
  assert.equal(withHint.retryAfter, 18, "the server's window drives the countdown");
  const bare = hooks.twoFactorChallengeOutcome({ ok: false, status: 429, data: {} });
  assert.equal(bare.state, "rate_limited");
  assert.equal(bare.retryAfter, null, "no server hint → null, so the mount falls back to the constant");
  // The fixed-window constant survives ONLY as that fallback.
  assert.equal(hooks.twoFactorRateWaitS, 60);
  // The card renders whatever seconds it is handed — the mount resolves the
  // fallback once and feeds both the label and the ticker from the same number.
  assert.match(hooks.twoFactorCardHtml({ rateLimited: true, waitSecs: 18 }), /Try again in 18s/);
  assert.match(hooks.twoFactorCardHtml({ rateLimited: true }), /Try again in 60s/);
});

// ── GR80 leg 3: the webhook test-send verdict ────────────────────────────────

test("GR80 leg 3: the test-send toast names the endpoint's real answer, and a non-2xx is an error", () => {
  const ok = { last_status_code: 200, last_latency_ms: 84, status: "ok" };
  assert.equal(hooks.testSendAccepted(ok), true);
  assert.match(hooks.testSendToastBody(ok), /Test delivered/);
  assert.match(hooks.testSendToastBody(ok), /in 84 ms/);
  // A 500 is a delivered-but-rejected test: the request succeeded, the delivery
  // did not, and the toast must not conflate them.
  const bad = { last_status_code: 500, last_latency_ms: 12, status: "failed_giveup" };
  assert.equal(hooks.testSendAccepted(bad), false);
  assert.match(hooks.testSendToastBody(bad), /500/);
  // An older instance that returns no verdict at all degrades honestly.
  assert.equal(hooks.testSendToastBody({}), "Test payload delivered to the endpoint URL.");
  assert.equal(hooks.testSendToastBody(null), "Test payload delivered to the endpoint URL.");
});

test("REVIEW FIX (GR80 leg 3): the verdict is three-way and the toast never contradicts itself", () => {
  // deliveryTone answers ok | danger | info. Folding `info` into "not accepted"
  // paired a red "Endpoint rejected the test" headline with the body "Test
  // payload delivered to the endpoint URL." — both halves false at once.
  assert.equal(hooks.testSendVerdict({ last_status_code: 204 }), "accepted");
  assert.equal(hooks.testSendVerdict({ last_status_code: 500 }), "rejected");
  assert.equal(hooks.testSendVerdict({ status: "failed_giveup" }), "rejected");
  for (const unknown of [null, {}, { status: "pending" }, { last_status_code: 302 }]) {
    assert.equal(hooks.testSendVerdict(unknown), "unconfirmed",
      "no 2xx and no failure is UNKNOWN: " + JSON.stringify(unknown));
    assert.equal(hooks.testSendAccepted(unknown), false, "unknown is never a green tick");
  }

  // The toast resolves title, kind and body TOGETHER, so no headline can
  // contradict the sentence beneath it.
  const ok = hooks.testSendToast({ last_status_code: 200, last_latency_ms: 84 });
  assert.equal(ok.kind, "success");
  assert.match(ok.body, /200 OK/);

  const bad = hooks.testSendToast({ last_status_code: 500 });
  assert.equal(bad.kind, "error");
  assert.match(bad.title, /rejected/);
  assert.match(bad.body, /500/);

  // The case the fix exists for: an instance that echoed no delivery at all.
  const quiet = hooks.testSendToast(undefined);
  assert.equal(quiet.kind, "info", "never an error toast for an answer we never got");
  assert.ok(!/rejected/i.test(quiet.title), "an unknown answer is not an accusation");
  assert.match(quiet.body, /didn't report/);

  // A still-pending row says so rather than claiming a delivered verdict.
  const pending = hooks.testSendToast({ status: "pending" });
  assert.equal(pending.kind, "info");
  assert.match(pending.body, /hasn't answered yet/);
});

test("GR80 leg 3: the webhook action bar offers Send test, and no CLI chip for a verb bp lacks", () => {
  const card = hooks.webhookCardHtml(
    { id: "wh_1", url: "https://example.com/hook", active: true }, "acme", "production");
  assert.match(card, /data-wh-test/, "the action bar carries the test-send affordance");
  assert.match(card, />Send test</);
  assert.ok(!/webhook test-send acme/.test(card), "no copy-as-CLI chip: bp cloud webhook has no test-send verb");
  // The existing bar is intact — this is an addition, not a re-composition.
  for (const hook of ["data-wh-edit", "data-wh-toggle", "data-wh-rotate", "data-wh-deliveries", "data-wh-delete"]) {
    assert.ok(card.includes(hook), "the bar keeps " + hook);
  }
});

// ── GR79 leg 4: the delivery log is a server round-trip with a keyset cursor ──

test("GR79: notifDeliveriesQuery sends every set filter and pages with before", () => {
  const st = hooks.notifDeliveryFilterState;
  const reset = () => { st.channel = null; st.status = null; st.event = null; };
  reset();
  assert.equal(hooks.notifDeliveriesQuery(null), "/v1/notifications/deliveries?limit=50",
    "an unfiltered first page sends nothing but the limit");

  st.channel = "discord";
  st.status = "failed";
  assert.equal(hooks.notifDeliveriesQuery(null),
    "/v1/notifications/deliveries?limit=50&channel=discord&status=failed");

  // Load more carries EVERY axis plus the cursor: it walks the filtered trail,
  // not a filtered slice of the newest page.
  assert.equal(hooks.notifDeliveriesQuery("2026-07-18T09:00:00.000000Z"),
    "/v1/notifications/deliveries?limit=50&channel=discord&status=failed&before=2026-07-18T09%3A00%3A00.000000Z");

  // A free-text event is encoded, never interpolated raw.
  reset();
  st.event = "instance down & out";
  assert.match(hooks.notifDeliveriesQuery(null), /&event=instance%20down%20%26%20out/);
  reset();
});

test("GR79: the keyset cursor is the OLDEST rendered row, and a stamp-less row stops paging", () => {
  const rows = [
    { id: "d1", inserted_at: "2026-07-19T10:00:00.000000Z" },
    { id: "d2", inserted_at: "2026-07-18T09:00:00.000000Z" },
  ];
  assert.equal(hooks.notifDeliveriesCursor(rows), "2026-07-18T09:00:00.000000Z",
    "server orders inserted_at DESC, so the oldest rendered row is last");
  assert.equal(hooks.notifDeliveriesCursor([]), null);
  assert.equal(hooks.notifDeliveriesCursor(null), null);
  assert.equal(hooks.notifDeliveriesCursor([{ id: "d3" }]), null,
    "no stamp → no cursor → paging STOPS rather than silently restarting at page one");
});

// ── gr-bl-delivery-keyset-tiebreak: the cursor carries BOTH halves of the key ──

test("keyset tiebreak: the delivery cursor sends before_id alongside before", () => {
  const st = hooks.notifDeliveryFilterState;
  const reset = () => { st.channel = null; st.status = null; st.event = null; };
  reset();

  // Both halves ride together — the server's tiebreak arm engages only on the
  // pair, so a stamp without its id is exactly the silent-drop bug.
  assert.equal(hooks.notifDeliveriesQuery("2026-07-18T09:00:00.000000Z", "d2"),
    "/v1/notifications/deliveries?limit=50&before=2026-07-18T09%3A00%3A00.000000Z&before_id=d2");

  // BACKWARD COMPATIBLE: a stamp with no id is still a legal stamp-only cursor
  // (a bookmarked URL, or a row the server did not give an id).
  assert.equal(hooks.notifDeliveriesQuery("2026-07-18T09:00:00.000000Z", null),
    "/v1/notifications/deliveries?limit=50&before=2026-07-18T09%3A00%3A00.000000Z");

  // No stamp → no id either; before_id alone is meaningless and never sent.
  assert.equal(hooks.notifDeliveriesQuery(null, "d2"), "/v1/notifications/deliveries?limit=50");

  // The id is URL-encoded like every other param.
  assert.match(hooks.notifDeliveriesQuery("2026-07-18T09:00:00.000000Z", "d 2&x"), /&before_id=d%202%26x$/);
  reset();
});

test("keyset tiebreak: notifDeliveriesCursorId is the SAME oldest row the stamp came from", () => {
  const rows = [
    { id: "d1", inserted_at: "2026-07-19T10:00:00.000000Z" },
    { id: "d2", inserted_at: "2026-07-18T09:00:00.000000Z" },
  ];
  assert.equal(hooks.notifDeliveriesCursorId(rows), "d2",
    "both halves of the cursor must come from ONE row or the predicate is nonsense");
  assert.equal(hooks.notifDeliveriesCursor(rows), "2026-07-18T09:00:00.000000Z");
  assert.equal(hooks.notifDeliveriesCursorId([]), null);
  assert.equal(hooks.notifDeliveriesCursorId(null), null);
  assert.equal(hooks.notifDeliveriesCursorId([{ inserted_at: "2026-07-18T09:00:00.000000Z" }]), null,
    "an id-less row degrades to a stamp-only cursor, never to a fabricated id");
});

test("GR79: an empty FILTERED log never claims nothing was ever delivered", () => {
  assert.match(hooks.notifDeliveriesBodyHtml([], false), /No notifications have been delivered yet/);
  const filtered = hooks.notifDeliveriesBodyHtml([], true);
  assert.match(filtered, /No sends match these filters/);
  assert.ok(!/No notifications have been delivered yet/.test(filtered),
    "the unfiltered sentence would be FALSE here — it is the exact lie a filter panel invites");
  assert.match(hooks.notifDeliveriesBodyHtml([{ recipient: "a@b.c", status: "sent" }], true), /wh-del-card/);
});

test("GR79: the filter chips are static per-branch class literals in the shared grammar", () => {
  const html = hooks.notifDeliveryFiltersHtml();
  assert.match(html, /data-notif-del-axis="channel"/);
  assert.match(html, /data-notif-del-axis="status"/);
  // Both vocabularies are the Delivery schema's own — nothing invented.
  for (const v of ["email", "discord", "slack", "telegram", "pushover", "webhook"]) {
    assert.ok(html.includes('data-notif-del-value="' + v + '"'), "channel " + v + " is a real @channels member");
  }
  for (const v of ["sent", "failed", "pending"]) {
    assert.ok(html.includes('data-notif-del-value="' + v + '"'), "status " + v + " is a real @statuses member");
  }
  // event is FREE TEXT server-side, so it must not be faked as a closed chip row.
  assert.match(html, /id="notif-del-event"/);
  // E3 discipline: full literal heads only, exactly two lit chips (one per axis).
  assert.equal((html.match(/actfilter-chip is-active/g) || []).length, 2);
  assert.ok(!/actfilter-chip"\s*\+/.test(html), "no concat modifier leaked into a class");
});

// ═══ MVP-0 Personal Dev Fleet (pdf-mvp0-fleet-card-spa) ═════════════════════
// PDF-D84/D87/D88/D92: the SUPPORT step vocabulary (additive beside the
// byte-locked SERVER tables), the kind-aware provision fold, the fleet card +
// nested support rows, the add-support reducer with its honest error states,
// the roster presence chip (online DERIVED, both capacity shapes), the BYO
// model-key step, and #fleet nesting.

const FLEET_MAIN = {
  id: "main-1", name: "Production", slug: "production", host: "production.barkpark.cloud",
  url: "https://production.barkpark.cloud", provision_status: "succeeded",
};
const FLEET_SUPPORT_LIVE = {
  id: "sup-1", name: "muscle-1", slug: "muscle-1", host: "muscle-1.fleet.internal",
  fleet_role: "support", fleet_parent_id: "main-1", provision_status: "succeeded",
};
const FLEET_SUPPORT_PROV = {
  id: "sup-2", name: "muscle-2", slug: "muscle-2", host: null,
  fleet_role: "support", fleet_parent_id: "main-1",
  provision_steps: [
    { step: "create", status: "started", at: "2026-07-24T10:00:00Z" },
    { step: "create", status: "done", at: "2026-07-24T10:00:20Z" },
    { step: "configure", status: "started", at: "2026-07-24T10:00:20Z" },
  ],
};

test("PDF-D84: SUPPORT_STEP_ORDER is the 6-step support vocabulary (secure joined with full public identity), ADDITIVE beside the untouched SERVER order", () => {
  assert.deepEqual([...hooks.supportStepOrder], ["create", "secure", "configure", "content", "verify", "ready"]);
  // The server table still carries freshen — the lock above holds, and the
  // two arrays are distinct objects (no aliasing that could drift both).
  assert.deepEqual([...hooks.serverStepOrder], [
    "create", "freshen", "secure", "configure", "content", "verify", "ready",
  ]);
  assert.notEqual(hooks.supportStepOrder, hooks.serverStepOrder);
  // secure paces by the SAME expectation as the main chain's secure — one DNS
  // + ACME wait, one estimate.
  assert.equal(hooks.supportStepExpectedMs.secure, hooks.SERVER_STEP_EXPECTED_MS.secure);
});

test("every support step has a label AND a pacing estimate (no orphans either way)", () => {
  assert.deepEqual(Object.keys(hooks.supportStepLabels).sort(), [...hooks.supportStepOrder].sort());
  assert.deepEqual(Object.keys(hooks.supportStepExpectedMs).sort(), [...hooks.supportStepOrder].sort());
  for (const s of hooks.supportStepOrder) {
    assert.ok(hooks.supportStepLabels[s].length > 0, s + " must have a non-empty label");
    assert.ok(hooks.supportStepExpectedMs[s] > 0, s + " must have a positive estimate");
  }
});

test("provisionSteps folds a support over the SUPPORT tables: 6 planned rows, support labels, own estimates", () => {
  const rows = hooks.provisionSteps({ fleet_role: "support", provision_steps: [] }, Date.now());
  assert.deepEqual([...rows.map((r) => r.step)], ["create", "secure", "configure", "content", "verify", "ready"]);
  assert.equal(rows[0].label, hooks.supportStepLabels.create);
  // secure is a PLANNED rung — full public identity: DNS + Caddy/TLS ship on
  // every provisioned support now, so the row renders pending from the start.
  assert.equal(rows[1].step, "secure");
  assert.equal(rows[1].role, "pending");
  // content is a PLANNED rung for a support (the dataset leg always ships) —
  // never the server-side optional that hides until reported.
  assert.equal(rows[3].step, "content");
  assert.equal(rows[3].role, "pending");
  // rows carry the SUPPORT estimate so ring/pace/overall pace by it.
  assert.equal(rows[0].expectedMs, hooks.supportStepExpectedMs.create);
});

test("a support renders a REPORTED secure step but NEVER freshen — even from a rogue payload", () => {
  const rows = hooks.provisionSteps({
    fleet_role: "support",
    provision_steps: [
      { step: "create", status: "done", at: "2026-07-24T10:00:00Z" },
      { step: "secure", status: "started", at: "2026-07-24T10:00:10Z" },
      { step: "freshen", status: "started", at: "2026-07-24T10:00:11Z" },
    ],
  }, Date.now());
  const secure = rows.filter((r) => r.step === "secure")[0];
  assert.ok(secure, "secure is a real support rung now (full public identity)");
  assert.equal(secure.role, "active");
  assert.ok(!rows.some((r) => r.step === "freshen"),
    "freshen stays main-only and must be dropped from a support fold, whatever the server says");
});

test("a MAIN's fold is byte-compatible with before: server labels, optional rungs hidden until reported", () => {
  const rows = hooks.provisionSteps({ provision_steps: [] }, Date.now());
  assert.deepEqual([...rows.map((r) => r.step)], ["create", "secure", "configure", "verify", "ready"]);
  assert.equal(rows[0].label, "Creating your server");
  assert.equal(rows[0].expectedMs, hooks.SERVER_STEP_EXPECTED_MS.create);
});

test("supportsOf picks exactly this main's supports — 0, 1 and 2; id types coerced; foreign rows excluded", () => {
  const other = { id: "sup-9", fleet_role: "support", fleet_parent_id: "main-2" };
  assert.deepEqual([...hooks.supportsOf([FLEET_MAIN, other], "main-1")], []);
  assert.deepEqual(
    [...hooks.supportsOf([FLEET_MAIN, FLEET_SUPPORT_LIVE, other], "main-1").map((s) => s.id)],
    ["sup-1"],
  );
  assert.deepEqual(
    [...hooks.supportsOf([FLEET_MAIN, FLEET_SUPPORT_LIVE, FLEET_SUPPORT_PROV, other], "main-1").map((s) => s.id)],
    ["sup-1", "sup-2"],
  );
  // A main is never its own support; null mainId never matches null parents.
  assert.deepEqual([...hooks.supportsOf([FLEET_MAIN], "main-1")], []);
  assert.deepEqual([...hooks.supportsOf([FLEET_MAIN, FLEET_SUPPORT_LIVE], null)], []);
});

test("fleetSupportCardHtml renders ONLY on a main — a support row never gets its own card", () => {
  assert.equal(hooks.fleetSupportCardHtml(FLEET_SUPPORT_LIVE, [], Date.now()), "");
  const html = hooks.fleetSupportCardHtml(FLEET_MAIN, [], Date.now());
  assert.match(html, /fleet-support-card/);
});

test("fleet card empty state: the CTA on a live main; the honest hint (no CTA) pre-live", () => {
  const live = hooks.fleetSupportCardHtml(FLEET_MAIN, [], Date.now());
  assert.match(live, /id="fleet-add-support-cta"/);
  assert.match(live, /id="fleet-add-support"/);
  const proving = hooks.fleetSupportCardHtml(
    { id: "m2", name: "Fresh", host: null, provision_status: null }, [], Date.now());
  assert.match(proving, /Available once this server is live/);
  assert.ok(!/fleet-add-support/.test(proving), "no add affordance before the main is live");
});

test("fleet card with supports: one nested row each, deep-linked, never a second card", () => {
  const html = hooks.fleetSupportCardHtml(FLEET_MAIN, [FLEET_SUPPORT_LIVE, FLEET_SUPPORT_PROV], Date.now());
  assert.equal((html.match(/fleet-support-row-head/g) || []).length, 2);
  assert.match(html, /href="#instance\/sup-1"/);
  assert.match(html, /href="#instance\/sup-2"/);
  assert.equal((html.match(/fleet-support-card/g) || []).length, 1);
});

test("supportRowHtml per state: provisioning → the SUPPORT theater through newStepsHtml (secure planned, freshen never)", () => {
  const html = hooks.supportRowHtml(FLEET_SUPPORT_PROV, Date.parse("2026-07-24T10:01:00Z"));
  assert.match(html, /fleet-support-theater/);
  assert.match(html, /new-steps/); // the SHARED step component, not a bespoke list
  assert.match(html, /data-step="configure"/);
  // Full public identity: secure is a planned support rung now (DNS + TLS).
  assert.match(html, /data-step="secure"/);
  assert.ok(!/data-step="freshen"/.test(html), "freshen stays main-only in the support theater");
  assert.match(html, /Configuring the runtime/); // support label, not "Configuring Barkpark"
});

test("cch-w13-s1 supportRowHtml: the support theater quotes NO constant-paced hint — the four ~Ns promises are gone", () => {
  // The support theater renders through the same newStepsHtml, so it carried
  // four unpinned "~Ns" hints off SUPPORT_STEP_EXPECTED_MS (secure 45s,
  // content 25s, verify 45s, ready 5s — every one a hand-written constant).
  // This is the coverage that gap never had: they are planned, so they render
  // nothing, and the live step still narrates its real elapsed.
  const html = hooks.supportRowHtml(FLEET_SUPPORT_PROV, Date.parse("2026-07-24T10:01:00Z"));
  assert.doesNotMatch(html, /~\d+[sm]/, "no support step may quote a pace nobody measured");
  for (const hint of ["~45s", "~25s", "~5s", "~20s", "~1m 0s"]) {
    assert.ok(!html.includes(hint), "the support theater still quotes " + hint);
  }
  // The rows are all planned, and the elapsed narration survives untouched.
  const rows = hooks.provisionSteps(FLEET_SUPPORT_PROV, Date.parse("2026-07-24T10:01:00Z"));
  assert.ok(rows.every((r) => r.paceSource === "planned"));
  assert.match(html, /<span class="new-step-time">20s<\/span>/);          // create, done
  assert.match(html, /data-time="configure">40s<\/span>/);                 // configure, live
});

test("supportRowHtml per state: failed is HONEST (alert + verbatim error), live carries the key step", () => {
  const failed = hooks.supportRowHtml({
    id: "sup-3", name: "muscle-3", fleet_role: "support", fleet_parent_id: "main-1",
    host: null, provision_status: "failed", provision_error: "verify: no heartbeat within budget",
  }, Date.now());
  assert.match(failed, /role="alert"/);
  assert.match(failed, /verify: no heartbeat within budget/);
  assert.ok(!/fleet-presence--online/.test(failed), "stuck-provisioning never lies online");
  const live = hooks.supportRowHtml(FLEET_SUPPORT_LIVE, Date.now());
  assert.match(live, /support-key-step/);
  assert.match(live, /data-support-presence="sup-1"/);
});

test("addSupportFlowReducer: name → submitting → submitted on 202 (201 tolerated); errors return to name", () => {
  const r = hooks.addSupportFlowReducer;
  assert.equal(r("name", { type: "submit" }), "submitting");
  assert.equal(r("submitting", { type: "result", status: 202 }), "submitted");
  assert.equal(r("submitting", { type: "result", status: 201 }), "submitted");
  assert.equal(r("submitting", { type: "result", status: 409 }), "name");
  assert.equal(r("submitting", { type: "result", status: 403 }), "name");
  assert.equal(r("submitting", { type: "result", status: 422 }), "name");
  // Total over junk: unknown events/states never move or throw.
  assert.equal(r("name", { type: "result", status: 202 }), "name");
  assert.equal(r("submitting", { type: "submit" }), "submitting");
  assert.equal(r("weird", { type: "submit" }), "weird");
  assert.equal(r("name", null), "name");
});

test("addSupportErrorCopy: honest 409 no_admin_token and 403 limit_reached states", () => {
  const noTok = hooks.addSupportErrorCopy(409, { error: "no_admin_token" });
  assert.match(noTok, /no stored admin credentials/i);
  const limit = hooks.addSupportErrorCopy(403, { error: "limit_reached" });
  assert.match(limit, /support-server limit/);
  // Anything else flows through friendly() to the designed fallback.
  assert.match(hooks.addSupportErrorCopy(0, { error: "network_error" }), /Network error/);
  assert.match(hooks.addSupportErrorCopy(500, {}), /Couldn't add the support server/);
});

test("supportNameValid mirrors the provisioner's DNS-label fence — the trap never leaves the modal", () => {
  for (const good of ["muscle-1", "a", "worker9", "a-b-c", "x".repeat(63)]) {
    assert.equal(hooks.supportNameValid(good), true, good + " must be accepted");
  }
  for (const bad of ["My Support", "Muscle_1", "-lead", "trail-", "UPPER", "", "x".repeat(64), "a.b"]) {
    assert.equal(hooks.supportNameValid(bad), false, JSON.stringify(bad) + " must be refused (the Go chain would fail it after queueing)");
  }
});

test("presenceChip: online is DERIVED (status !== \"offline\") — never a stored literal", () => {
  assert.deepEqual({ ...hooks.presenceChip({ status: "idle" }) },
    { state: "idle", online: true, label: "Online · idle" });
  assert.equal(hooks.presenceChip({ status: "working" }).online, true);
  assert.equal(hooks.presenceChip({ status: "blocked" }).online, true);
  assert.equal(hooks.presenceChip({ status: "provisioning" }).online, true);
  assert.deepEqual({ ...hooks.presenceChip({ status: "offline" }) },
    { state: "offline", online: false, label: "Offline" });
  // A missing row / garbled status is the honest unknown, never a fake Offline.
  assert.equal(hooks.presenceChip(null).state, "unknown");
  assert.equal(hooks.presenceChip({ status: 7 }).state, "unknown");
});

test("presenceChipHtml: one STATIC class literal per state (E3), unknown future statuses land on --online", () => {
  assert.match(hooks.presenceChipHtml({ status: "idle" }), /fleet-presence--online/);
  assert.match(hooks.presenceChipHtml({ status: "working" }), /fleet-presence--working/);
  assert.match(hooks.presenceChipHtml({ status: "blocked" }), /fleet-presence--blocked/);
  assert.match(hooks.presenceChipHtml({ status: "provisioning" }), /fleet-presence--provisioning/);
  assert.match(hooks.presenceChipHtml({ status: "offline" }), /fleet-presence--offline/);
  assert.match(hooks.presenceChipHtml(null), /fleet-presence--unknown/);
  assert.ok(!/fleet-presence--"\s*\+/.test(hooks.presenceChipHtml({ status: "idle" })),
    "no concat modifier leaked into a class");
});

test("rosterCapacityText handles BOTH shapes: the validated object AND the legacy string (junk → \"\")", () => {
  assert.equal(hooks.rosterCapacityText({ size_class: "standard", slots_total: 2, slots_free: 1 }),
    "standard · 1/2 slots free");
  assert.equal(hooks.rosterCapacityText({ size_class: "heavy", slots_total: 1, slots_free: 0, budget: 5 }),
    "heavy · 0/1 slots free · $5 budget");
  assert.equal(hooks.rosterCapacityText("1 task"), "1 task"); // legacy stored as-is
  assert.equal(hooks.rosterCapacityText(null), "");
  assert.equal(hooks.rosterCapacityText(42), "");
  // slots_free 0 must render 0, never "?" (falsy-vs-missing trap).
  assert.equal(hooks.rosterCapacityText({ slots_total: 1, slots_free: 0 }), "0/1 slots free");
});

test("rosterRowFor matches the listener by slug OR name; presenceSlotHtml separates read-failed from no-beat", () => {
  const docs = [{ worker: "muscle-1", status: "idle" }, { worker: "other", status: "working" }];
  assert.equal(hooks.rosterRowFor(docs, FLEET_SUPPORT_LIVE).worker, "muscle-1");
  assert.equal(hooks.rosterRowFor(docs, { name: "muscle-1" }).worker, "muscle-1");
  assert.equal(hooks.rosterRowFor(docs, { slug: "ghost" }), null);
  // null documents = the READ failed — say so; a missing row = no beat yet.
  assert.match(hooks.presenceSlotHtml(null, FLEET_SUPPORT_LIVE), /Roster unreachable/);
  assert.match(hooks.presenceSlotHtml([], FLEET_SUPPORT_LIVE), /No heartbeat yet/);
  assert.match(hooks.presenceSlotHtml(docs, FLEET_SUPPORT_LIVE), /fleet-presence--online/);
});

test("rosterUrl: scheme-less rows get https://, schemed rows pass through, trailing slashes trimmed", () => {
  assert.equal(hooks.rosterUrl("https://main.example"), "https://main.example/v1/fleet/roster");
  assert.equal(hooks.rosterUrl("main.example/"), "https://main.example/v1/fleet/roster");
  assert.equal(hooks.rosterUrl("http://localhost:4000"), "http://localhost:4000/v1/fleet/roster");
});

test("PDF-D88: the BYO model key is a VISIBLE NAMED step with the exact SSH one-liner + copy affordance", () => {
  const cmd = hooks.supportKeyCommand(FLEET_SUPPORT_LIVE);
  assert.ok(cmd.startsWith("ssh root@muscle-1.fleet.internal "), cmd);
  assert.ok(cmd.includes(">> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener"),
    "the exact hand-off one-liner (PDF-D62/D88) must be verbatim");
  assert.ok(cmd.includes("ANTHROPIC_API_KEY="));
  const html = hooks.supportKeyStepHtml(FLEET_SUPPORT_LIVE);
  assert.match(html, /Hand your box its model key/);
  assert.match(html, /never stored by Barkpark/);
  assert.match(html, /data-copy="/); // the shared clipboard affordance
  // A hostless row still renders an honest placeholder, never "root@null".
  assert.match(hooks.supportKeyCommand({ host: null }), /ssh root@<support-host> /);
});

test("PDF-D92: fleetNest rides supports under their main; orphans fall back to flat rows, never dropped", () => {
  const orphan = { id: "sup-8", fleet_role: "support", fleet_parent_id: "gone" };
  const nested = hooks.fleetNest([FLEET_MAIN, orphan, FLEET_SUPPORT_LIVE, FLEET_SUPPORT_PROV]);
  assert.deepEqual([...nested.map((r) => r.bp.id)], ["main-1", "sup-1", "sup-2", "sup-8"]);
  assert.deepEqual([...nested.map((r) => r.support)], [false, true, true, false]);
  // No fleets at all → byte-order passthrough, all flat.
  const flat = hooks.fleetNest([FLEET_MAIN, { id: "m2" }]);
  assert.deepEqual([...flat.map((r) => r.support)], [false, false]);
});

test("nested support rows carry fleet-row--support + the role chip; a bare fleetRow(bp) is unchanged", () => {
  const html = hooks.fleetNestedRowsHtml([FLEET_MAIN, FLEET_SUPPORT_LIVE]);
  assert.equal((html.match(/fleet-row--support/g) || []).length, 1);
  assert.match(html, /fleet-role-chip/);
  // Arity safety: existing single-arg callers (Overview attention queue,
  // filtered lists) render byte-identically to an explicit no-opts call.
  assert.equal(hooks.fleetRow(FLEET_MAIN), hooks.fleetRow(FLEET_MAIN, undefined));
  assert.ok(!/fleet-row--support/.test(hooks.fleetRow(FLEET_MAIN)));
});

// ════════════════════════════════════════════════════════════════════════════
// MVP-0 OFFLOAD (pdf-mvp0-offload-spa, PDF-D87/D92): file an assignee-routed
// order to a support and watch it claim -> working -> done, app-token-direct.
// Appended at the tail (OC9 append-only law). Pure helpers only; the DOM mounts
// (startOffload / submitOffload / pollOffloadWatch) are browser-verified.
// ════════════════════════════════════════════════════════════════════════════

// Cross-realm normalise: hooks return objects built inside the node:vm
// sandbox (a different Object/Array prototype), so deepEqual's strict
// prototype check fails on them — JSON round-trip them into this realm first
// (the same reason the fleet tests spread `[...x.map(...)]`).
const J = (x) => JSON.parse(JSON.stringify(x));

test("mainDirectUrl: scheme-less rows get https://, schemed pass through, trailing slashes trimmed, path joined", () => {
  assert.equal(hooks.mainDirectUrl("https://main.example", "/v1/tasks/x"), "https://main.example/v1/tasks/x");
  assert.equal(hooks.mainDirectUrl("main.example/", "/v1/fleet/roster"), "https://main.example/v1/fleet/roster");
  assert.equal(hooks.mainDirectUrl("http://localhost:4000", "/v1/data/mutate/production"), "http://localhost:4000/v1/data/mutate/production");
  assert.equal(hooks.mainDirectUrl("", "/x"), "https:///x"); // total: never throws on junk
});

test("offloadWorkerName: the listener identity — slug preferred (box identity), name the fallback", () => {
  assert.equal(hooks.offloadWorkerName({ slug: "muscle-1", name: "Muscle One" }), "muscle-1");
  assert.equal(hooks.offloadWorkerName({ name: "muscle-2" }), "muscle-2");
  assert.equal(hooks.offloadWorkerName({}), "");
  assert.equal(hooks.offloadWorkerName(null), "");
});

test("offloadDataset: the listener's scope — dataset > scope > the fleet default production", () => {
  assert.equal(hooks.offloadDataset({ dataset: "staging" }), "staging");
  assert.equal(hooks.offloadDataset({ scope: "production" }), "production");
  assert.equal(hooks.offloadDataset({}), "production");
});

test("offloadOrderDoc: assignee = the support worker name, filed OPEN, and the PUBLISH mutation is included", () => {
  const support = { slug: "muscle-1", name: "muscle-1" };
  const o = hooks.offloadOrderDoc("ord-1", support, { title: "Summarise notes", description: "the brief" });
  const cor = o.create.mutations[0].createOrReplace;
  assert.equal(cor._id, "ord-1");
  assert.equal(cor._type, "task");
  assert.equal(cor.kind, "task");
  assert.equal(cor.lifecycle_status, "open");
  assert.equal(cor.assignee, "muscle-1"); // routed by assignee → the listener claims it
  assert.equal(cor.priority, 2);
  assert.equal(cor.title, "Summarise notes");
  assert.equal(cor.description, "the brief");
  assert.ok(!("tags" in cor), "the first-pass order carries NO tags (the tag arm is the contingency)");
  // The publish mutation MUST accompany the create — an unpublished order is
  // invisible to the claim queue.
  assert.deepEqual(J(o.publish.mutations[0]), { publish: { id: "ord-1", type: "task" } });
});

test("offloadOrderDoc {tagged}: the contingency retry seeds tags:=[{tag:order,...}]", () => {
  const o = hooks.offloadOrderDoc("ord-2", { slug: "m" }, { title: "t" }, { tagged: true });
  assert.deepEqual(J(o.create.mutations[0].createOrReplace.tags), [{ tag: "order", strength: 80, rationale: "fleet order" }]);
});

test("offloadOrderTagSeed: createOrReplace a minimal type:tag order doc, then publish it", () => {
  const s = hooks.offloadOrderTagSeed();
  assert.deepEqual(J(s.create.mutations[0].createOrReplace), { _id: "order", _type: "tag", title: "order" });
  assert.deepEqual(J(s.publish.mutations[0]), { publish: { id: "order", type: "tag" } });
});

test("offloadPublishNeedsTag: ONLY a 422 label_spine/unknown_tag arms the tag seed (env code AND bare-string shapes)", () => {
  assert.equal(hooks.offloadPublishNeedsTag(422, { error: { code: "label_spine" } }), true);
  assert.equal(hooks.offloadPublishNeedsTag(422, { error: { code: "unknown_tag" } }), true);
  assert.equal(hooks.offloadPublishNeedsTag(422, { error: "unknown_tag" }), true);
  assert.equal(hooks.offloadPublishNeedsTag(422, { error: { code: "duplicate_of" } }), false); // a real refusal, not retried
  assert.equal(hooks.offloadPublishNeedsTag(409, { error: { code: "label_spine" } }), false); // wrong status
  assert.equal(hooks.offloadPublishNeedsTag(422, null), false);
});

test("offloadEligibility: ONLY an ONLINE support may take an order; every refusal points at the key step", () => {
  const live = FLEET_SUPPORT_LIVE;
  const online = hooks.offloadEligibility(live, { worker: "muscle-1", status: "idle" });
  assert.equal(online.allowed, true);
  // Offline / no-heartbeat / provisioning / failed all REFUSE, and the copy
  // steers the operator at the BYO key step (PDF-D88).
  const offline = hooks.offloadEligibility(live, { worker: "muscle-1", status: "offline" });
  assert.equal(offline.allowed, false);
  assert.equal(offline.reason, "offline");
  assert.match(offline.copy, /model key|the step above/i);
  const noBeat = hooks.offloadEligibility(live, null);
  assert.equal(noBeat.allowed, false);
  assert.equal(noBeat.reason, "no_heartbeat");
  assert.match(noBeat.copy, /model key|the step above/i);
  const prov = hooks.offloadEligibility({ id: "s", host: null, provision_status: null }, { status: "idle" });
  assert.equal(prov.allowed, false);
  assert.equal(prov.reason, "provisioning");
  const failed = hooks.offloadEligibility({ id: "s", host: null, provision_status: "failed" }, { status: "idle" });
  assert.equal(failed.allowed, false);
  assert.equal(failed.reason, "failed");
});

test("offloadTaskFields: reads lifecycle/claim/assignee off BOTH the doc top-level AND doc.content", () => {
  assert.deepEqual(J(hooks.offloadTaskFields({ lifecycle_status: "open", assignee: "m" })),
    { lifecycle: "open", claim: null, assignee: "m" });
  assert.deepEqual(J(hooks.offloadTaskFields({ content: { lifecycle_status: "in_progress", claim: { worker: "m" }, assignee: "m" } })),
    { lifecycle: "in_progress", claim: { worker: "m" }, assignee: "m" });
  assert.deepEqual(J(hooks.offloadTaskFields(null)), { lifecycle: null, claim: null, assignee: null });
});

test("offloadWatchStage: fold task + roster into the filed→claimed→working→done ladder with honest terminals", () => {
  const w = "muscle-1";
  // filed: published + open, no worker beating.
  assert.deepEqual(J(hooks.offloadWatchStage({ lifecycle_status: "open" }, [], w)),
    { stage: "filed", terminal: false, failed: false });
  // claimed: in_progress but the worker is idle (claimed, not yet beating working).
  assert.deepEqual(J(hooks.offloadWatchStage({ lifecycle_status: "in_progress" }, [{ worker: "muscle-1", status: "idle" }], w)),
    { stage: "claimed", terminal: false, failed: false });
  // working: in_progress AND the roster shows the worker WORKING.
  assert.deepEqual(J(hooks.offloadWatchStage({ lifecycle_status: "in_progress" }, [{ worker: "muscle-1", status: "working" }], w)),
    { stage: "working", terminal: false, failed: false });
  // done: terminal success — the poll stops.
  assert.deepEqual(J(hooks.offloadWatchStage({ lifecycle_status: "done" }, [], w)),
    { stage: "done", terminal: true, failed: false });
  // blocked: honest terminal (from the task doc OR a blocked roster beat).
  assert.deepEqual(J(hooks.offloadWatchStage({ lifecycle_status: "blocked" }, [], w)),
    { stage: "blocked", terminal: true, failed: true });
  assert.deepEqual(J(hooks.offloadWatchStage({ lifecycle_status: "in_progress" }, [{ worker: "muscle-1", status: "blocked" }], w)),
    { stage: "blocked", terminal: true, failed: true });
  // cancelled → failed terminal.
  assert.deepEqual(J(hooks.offloadWatchStage({ lifecycle_status: "cancelled" }, [], w)),
    { stage: "failed", terminal: true, failed: true });
  // total over junk: a null doc reads filed, never throws.
  assert.equal(hooks.offloadWatchStage(null, null, w).stage, "filed");
});

test("offloadWatchRows: the ladder roles per stage; a blocked/failed terminal SNAPS the rungs behind it", () => {
  const step = (rows, s) => rows.find((r) => r.step === s).role;
  const filed = hooks.offloadWatchRows({ stage: "filed" });
  assert.deepEqual([...filed.map((r) => r.role)], ["active", "pending", "pending", "pending"]);
  const claimed = hooks.offloadWatchRows({ stage: "claimed" });
  assert.deepEqual([...claimed.map((r) => r.role)], ["ok", "active", "pending", "pending"]);
  const working = hooks.offloadWatchRows({ stage: "working" }, 12000);
  assert.deepEqual([...working.map((r) => r.role)], ["ok", "ok", "active", "pending"]);
  assert.equal(working.find((r) => r.step === "working").elapsedMs, 12000); // paces the active rung
  const done = hooks.offloadWatchRows({ stage: "done", terminal: true });
  assert.deepEqual([...done.map((r) => r.role)], ["ok", "ok", "ok", "ok"]);
  const blocked = hooks.offloadWatchRows({ stage: "blocked", terminal: true, failed: true });
  assert.deepEqual([...blocked.map((r) => r.role)], ["ok", "ok", "failed", "pending"]);
  assert.equal(step(blocked, "working"), "failed");
});

test("offloadWatchPanelHtml: renders the shared step ladder + honest terminal banners; the title is esc'd", () => {
  const filed = hooks.offloadWatchPanelHtml({ id: "ord-1", title: "Ship it" }, { stage: "filed" });
  assert.match(filed, /new-steps/); // the SHARED step-row grammar
  assert.match(filed, /data-offload-watch="ord-1"/);
  assert.match(filed, /Ship it/);
  assert.match(hooks.offloadWatchPanelHtml({ id: "d", title: "x" }, { stage: "done" }), /notice-ok/);
  assert.match(hooks.offloadWatchPanelHtml({ id: "b", title: "x" }, { stage: "blocked" }), /notice-warn/);
  assert.match(hooks.offloadWatchPanelHtml({ id: "f", title: "x" }, { stage: "failed" }), /notice-error/);
  // XSS: a hostile order title renders as TEXT, never markup.
  const evil = hooks.offloadWatchPanelHtml({ id: "e", title: "<img src=x onerror=alert(1)>" }, { stage: "filed" });
  assert.ok(!evil.includes("<img src=x"), "the order title must be escaped");
});

test("offloadSupportActionHtml: the Offload button + the watch slot, both keyed on the support id", () => {
  const html = hooks.offloadSupportActionHtml({ id: "sup-1" });
  assert.match(html, /data-offload-support="sup-1"/);
  assert.match(html, /data-offload-slot="sup-1"/);
  assert.match(html, /Offload a task/);
});

test("offloadFileErrorCopy: honest transport steers (0 / 401 / 403) else the friendly envelope", () => {
  assert.match(hooks.offloadFileErrorCopy(0, null), /reach the Barkpark/);
  assert.match(hooks.offloadFileErrorCopy(401, null), /token/);
  assert.match(hooks.offloadFileErrorCopy(403, null), /token/);
  assert.equal(typeof hooks.offloadFileErrorCopy(500, { error: "boom" }), "string");
});

// ─────────────────────────────────────────────────────────────────────────────
// cch-w14-s2 — THE FOLDED SHELL STOPS OPENING EVERY SCREEN ON 746px OF NAV.
// The defect and the fix are both GEOMETRY, so the proof that matters is driven
// in a real browser (72 cells, both themes, three route families: `.content` top
// went 745.88 -> 328 at h=800 and -> 282.77 at h=667, while 721 and 768 stayed at
// exactly 56). What these tests own is the smaller thing a node run CAN own —
// the source-level invariants that, if any one silently reverted, would put the
// wall back while every browser proof still read green in a paper.
// ─────────────────────────────────────────────────────────────────────────────

test("cch-w14-s2: the folded shell CAPS the nav strip and CUES the clip (never a bare cap)", () => {
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  // app.css carries several 720 blocks; the SHELL FOLD is the one that turns
  // .app-shell into a column. Anchored on that declaration, never on ordinal.
  const anchor = css.indexOf(".app-shell { flex-direction: column; }");
  assert.ok(anchor > 0, "the shell-fold block must exist");
  const at = css.lastIndexOf("@media (max-width: 720px)", anchor);
  assert.ok(at > 0 && anchor - at < 200, "the fold must still be the 720px block");
  const block = css.slice(at, css.indexOf("\n}\n", at) + 3);
  // cch-w15-s1: the cap subtracts the invariant 56px topbar so contentTop is
  // 0.4H - 4 at EVERY height. A bare `Nvh` cap is `N + 56/H` and is worst at the
  // smallest height, which is how 34vh sat over the sweep's own 0.4 bar at all of
  // 800/667/390 while a 745.88px pin reported it green.
  assert.match(block, /max-height:\s*calc\(40vh - 60px\)/, "the folded strip must be capped by a topbar-cancelling calc (it stood 690px tall; a bare vh cap drifts with height)");
  assert.match(block, /overflow-y:\s*auto/, "a cap with no scroller strands the rest of the nav");
  // A cap with no continuation cue is the W12 clipped-without-cue defect wearing
  // a new hat, which is why these travel together and neither may ship alone.
  assert.match(block, /mask-image:\s*linear-gradient\(to bottom/, "the clip must be CUED");
  assert.match(block, /\.sidebar\.is-nav-clipped\s*\{\s*--nav-fade:\s*40px/, "the cue is live iff clipped");
  assert.match(css, /@property --nav-fade/, "--nav-fade must be REGISTERED or the fade jumps");
  // D153: the fold itself is NOT raised — raising it relocates the same cliff
  // onto every tablet in portrait. The `anchor - at < 200` check above is that
  // assertion: the column-stack lives inside the 720 block and nowhere else, and
  // exactly one rule in the file stacks the shell.
  assert.equal(css.split(".app-shell { flex-direction: column; }").length - 1, 1,
    "exactly one rule may stack the shell, and it is the 720px fold");
});

test("cch-w14-s2: Settings is a real <details> disclosure, and the dead .nav-menu idiom is gone", () => {
  const html = fs.readFileSync(new URL("./index.html", import.meta.url), "utf8");
  const css = fs.readFileSync(new URL("./app.css", import.meta.url), "utf8");
  const js = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  assert.match(html, /<details class="nav-group" id="nav-settings" open>/,
    "a native disclosure — aria-expanded, Enter/Space and the open state come free");
  assert.match(html, /<summary class="nav-eyebrow nav-group-summary">/);
  assert.match(js, /function syncNavDisclosure\(onRoute\)/);
  assert.match(js, /group\.querySelector\("\.nav-link\.is-active"\)/,
    "the active Settings screen must never be sealed behind a closed summary");
  // The pre-v4 topbar dropdown retires in the SAME commit, CSS and JS both —
  // half a retirement is how it survived the whole v4 shell in the first place.
  assert.ok(!/\bnav-menu\b/.test(html), "index.html must not carry the retired idiom");
  assert.ok(!/^\s*\.nav-menu[\s{,[:]/m.test(css), "no live .nav-menu rule may remain");
  assert.ok(!/querySelector\([^)]*nav-menu/.test(js), "no JS may still sweep for .nav-menu");
});

test("cch-w14-s2: the clip cue is driven from a MEASURED state, on every trigger that changes it", () => {
  const js = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  assert.match(js, /sb\.scrollHeight - sb\.clientHeight - sb\.scrollTop/,
    "the cue reads live geometry — inferring it from a scroll timeline measured dead on 48 of 72 cells");
  assert.match(js, /classList\.toggle\("is-nav-clipped", below > 1\)/);
  // Five triggers. Lose any one and the cue goes silent on some route.
  for (const trigger of [
    /sb\.addEventListener\("scroll", navStripCue/,
    /window\.addEventListener\("resize", function \(\) \{ syncNavDisclosure\(false\); \}\)/,
    /group\.addEventListener\("toggle", navStripCue\)/,
    /new window\.ResizeObserver\(function \(\) \{ syncNavDisclosure\(false\); \}\)/,
    /syncNavDisclosure\(true\);/,
  ]) assert.match(js, trigger, "missing a navStripCue trigger: " + trigger);
  // A geometry event must NOT re-apply the collapse rule unless the fold itself
  // was crossed — otherwise a person's own tap on Settings snaps it shut again.
  assert.match(js, /if \(!onRoute && !crossed\) \{ navStripCue\(\); return; \}/,
    "a resize that did not cross the fold must leave the person's disclosure choice alone");
});

// ── cch-w20-s3: the address as TEXT vs the address as a PAYLOAD ──────────────
// Appended at the END on purpose: node --test numbers tests positionally, and
// this wave's evidence cites existing numbers (658 is the copy-payload guard).
// Inserting anywhere above would renumber somebody else's proof.
test("cch-w20-s3: displayUrl shaves the scheme, publicUrl keeps it — and a custom host rides the same rule", () => {
  const bp = { url: "https://production-5b2c1e.barkpark.cloud" };
  assert.equal(hooks.publicUrl(bp), "https://production-5b2c1e.barkpark.cloud");
  assert.equal(hooks.displayUrl(bp), "production-5b2c1e.barkpark.cloud");
  // an attached custom host is THE address, and it is shaved the same way
  const custom = { url: "https://production-5b2c1e.barkpark.cloud", custom_host: "app.acme.no" };
  assert.equal(hooks.publicUrl(custom), "https://app.acme.no");
  assert.equal(hooks.displayUrl(custom), "app.acme.no");
  // http is shaved too (a self-hosted control plane), and only at the FRONT
  assert.equal(hooks.displayUrl({ url: "http://box.internal/https://x" }), "box.internal/https://x");
  // no address yet (provisioning) → the empty string, never "undefined"
  assert.equal(hooks.displayUrl({}), "");
  // a path is kept whole — the shave is the scheme, not a truncation
  assert.equal(hooks.displayUrl({ url: "https://acme.barkpark.cloud/sites/blog/" }), "acme.barkpark.cloud/sites/blog/");
  // REVIEW (wave 20): an uppercased scheme is shaved too. Nothing normalises
  // bp.url before render, and a case-SENSITIVE match would have painted the
  // scheme back on for that one record while every driven cell stayed green.
  assert.equal(hooks.displayUrl({ url: "HTTPS://production-5b2c1e.barkpark.cloud" }), "production-5b2c1e.barkpark.cloud");
  assert.equal(hooks.displayUrl({ custom_host: "app.acme.no", url: "HtTp://box.internal" }), "app.acme.no");
});

test("cch-w20-s3: BOTH text sites shave the scheme together — the card and the fleet row never disagree", () => {
  const bp = {
    id: "bp-1", name: "Production", slug: "production", url: "https://production-5b2c1e.barkpark.cloud",
    host: "production-5b2c1e.barkpark.cloud", health_status: "ok", agent_status: "online",
    version: "0.9.2", provision_status: "succeeded",
  };
  const row = hooks.fleetRow(bp);
  assert.match(row, /class="fleet-url">production-5b2c1e\.barkpark\.cloud</);
  assert.ok(row.indexOf('class="fleet-url">https://') === -1,
    "the fleet row must not keep the scheme while the card drops it — that split is the sin scenarios.mjs:2331 exists to prevent");
  // …while the PAYLOAD keeps the whole address: a person copying it needs the
  // scheme. This is the same guarantee test 658 (GR24) pins on the header.
  const header = hooks.instanceHeaderHtml(bp);
  assert.match(header, /data-copy="https:\/\/production-5b2c1e\.barkpark\.cloud"/);
  assert.match(header, /detail-url-text">https:\/\/production-5b2c1e\.barkpark\.cloud</);
  // the card's own site is source-pinned: instanceCardHtml is not exported, so
  // the browser guard (overflow-guard.mjs W18 leg) is what measures it live.
  const js = fs.readFileSync(new URL("./app.js", import.meta.url), "utf8");
  assert.match(js, /class="instance-card-url">' \+ esc\(displayUrl\(bp\)\)/);
  assert.match(js, /class="fleet-url">' \+ esc\(displayUrl\(bp\)\)/);
});
