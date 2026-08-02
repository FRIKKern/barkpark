// smoke.mjs — a standalone node:vm smoke runner for the Cloud SPA preview harness.
//
// It BOOTS the shipped app.js (verbatim, no exports) inside a node:vm sandbox
// against each committed scenario's fixtures and asserts the expected view
// SKELETON rendered. Unlike __app.test.mjs (which keeps init() unbound to pin
// pure helpers), this harness sets document.readyState = "complete" so init()
// runs the real render → route → load path, with:
//   • window.fetch     routed to scenarios.route(scen, …)  (no backend)
//   • window.EventSource an inert stub                     (deterministic)
//   • a minimal but faithful DOM shim so innerHTML is observable afterwards.
//
// Assertions are STRUCTURAL (element / class presence, row counts) and live in
// the EXPECTATIONS table below — NOT in the harness. A4 will rewrite the SPA's
// onboarding / timeline / fleet markup; when it does, only EXPECTATIONS needs
// updating, never the boot machinery.
//
// Run: node smoke.mjs      (exits non-zero on any failed assertion)

import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { SCENARIOS, SCENARIO_NAMES, route } from "./scenarios.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_JS = fs.readFileSync(path.join(HERE, "..", "app.js"), "utf8");

// ── minimal DOM shim ─────────────────────────────────────────────────────────
// An element is a plain bag of the props app.js reads/writes. The critical
// invariant: getElementById(id) and querySelector("#id") return the SAME object
// across calls (a registry), so an innerHTML the app writes to #fleet-body is
// still there when the assertion reads it back.
//
// cch-w2-revoke-click-oracle — THE SHIM IS NOW CLICK-CAPABLE. It used to be
// incapable four independent ways, which is why no scenario had ever exercised
// a click path for ANY button:
//   (a) addEventListener DROPPED its handler,
//   (b) click() was a no-op,
//   (c) querySelectorAll always answered [] because innerHTML was an opaque
//       string, so a delegate loop over freshly-rendered rows wired nothing,
//   (d) there was no `isConnected` at all — and app.js guards three async
//       render paths with `if (!box.isConnected) return;` (:1072 loadSessions,
//       :2256, :10561). Every one of them bailed before painting, so the
//       account modal's session list had NEVER rendered through the real code
//       path here (account-modal-tall regex-splices rows in by hand to work
//       around exactly this).
//
// What is modelled and what is NOT — read this before writing a new check:
//   • innerHTML is a real accessor. Setting it re-parses; appendChild appends
//     the child's serialization, so a mounted node is observable in innerHTML.
//   • The parse is FLAT, not a tree: open tags become sibling stubs. Nesting,
//     text nodes and closing-tag structure are not modelled — a parsed stub's
//     own innerHTML is always "".
//   • The whitelist is DELIBERATELY only `button` and `a` — the leaf controls a
//     click oracle needs. It must NOT be widened to containers. app.js has
//     paths shaped like `var box = panel.querySelector(".fleet-body") || panel;`
//     (mountUsageTab), which fall back to the panel precisely
//     because a harness may not resolve the sub-query. Parsing `div` hands
//     those paths a DETACHED stub instead: the write lands on a node whose
//     content this flat parse cannot reflect back into its parent, so the panel
//     reads empty and six pre-existing scenarios go red. Modelling that
//     properly means a real tree; until someone builds one, containers stay
//     unparsed and those fallbacks keep working.
//   • Selectors: a single `.class`, a bare `#id`, and (cch-w10) a single
//     ATTRIBUTE selector — `[attr]` or `[attr="v"]`. Anything richer (a
//     COMPOUND like `.token-revoke[data-id]`, or a descendant path) answers
//     [] / null rather than throwing, so it silently matches NOTHING.
//     ⇒ EVERY click-driven check MUST assert a positive click count (the
//     `fired` idiom below); otherwise an empty node list reads as a clean pass
//     and you have written a false green inside the harness whose whole job is
//     to catch them.
//
// cch-w10-destroy-shrink-oracle-merged — WHY THE ATTRIBUTE GRAMMAR EXISTS.
// Before it, `.session-revoke` was the ONLY destructive list control the shim
// could resolve: every other one is authored as an attribute hook
// (`[data-prov-disconnect]`, `[data-member-remove]`, `[data-invite-revoke]`,
// `[data-env-delete]`, `[data-life-verb="decommission"]`), so app.js's
// `box.querySelectorAll("[data-…]").forEach(addEventListener)` looped over an
// EMPTY list and wired nothing — and a loop over nothing is a clean pass.
// Widening is safe by construction: every one of those call sites only ATTACHES
// handlers, so coming alive cannot change any pre-existing rendered markup
// (measured: all 98 scenarios stayed green across the widening alone).
// Two halves are needed and neither works without the other:
//   • the SELECTOR half (ATTR_SEL below), so `[data-x]` resolves against kids;
//   • the PARSE half (ATTR_RE), so a VALUELESS attribute is captured at all —
//     `data-prov-disconnect` and `data-wh-delete` are authored bare, and an
//     attribute the parse never recorded can never satisfy a selector.
// NOT widened, deliberately: PARSED_TAGS (the mountUsageTab detached-stub
// hazard above stands) and the DOCUMENT-level querySelectorAll (it hard-returns
// [] and six document-level attribute loops stay dead — a separate, unmeasured
// decision, filed as backlog rather than smuggled in here).
const PARSED_TAGS = "button|a";
const TAG_RE = new RegExp("<(" + PARSED_TAGS + ")\\b([^>]*?)/?>", "gi");
const ATTR_RE = /([\w:.-]+)(?:="([^"]*)")?/g;
const CLASS_SEL = /^\.[\w-]+$/;
const ID_SEL_SUB = /^#[\w-]+$/;
const ATTR_SEL = /^\[([\w:.-]+)(?:="([^"]*)")?\]$/;
// cch-w11-s3 — THE COMPOUND `.class[attr]`, the last selector shape standing
// between the shim and a destroy control. `.token-revoke[data-id]` — authored in
// renderTokenList(), `grep -n 'function renderTokenList' cloud/priv/static/app.js`
// — is the ONLY app.js destroy hook of this shape; every other one is a bare
// attribute already covered by ATTR_SEL above.
//
// THE BLAST RADIUS IS MEASURED, NOT ASSUMED — instrumented census over all 99
// scenarios, as calls/hits:
//   .token-revoke[data-id]    5 / 12   ← the destroy control this exists for
//   .seg-btn[data-kind]       1 /  2   ← THE SECOND SELECTOR THAT COMES ALIVE.
//        Named, not smuggled: it is a real behavioural change in the same diff.
//        Its call site only ATTACHES handlers (`.forEach(b => b.addEventListener)`),
//        so coming alive cannot alter any rendered markup — and all 99 scenarios
//        stayed green across the widening alone.
//   .fleet-row[data-id]      29 /  0
//   .site-row[data-id]        4 /  0
//   .new-step-dot[data-ring]  5 /  0   ← all three DIVs; PARSED_TAGS is button|a.
// `nav-link[data-view]` / `nav-sub[data-view]` never appear: they are
// DOCUMENT-level queries — applyRoute() and applyShellNav(), `grep -n 'function
// applyRoute\|function applyShellNav' cloud/priv/static/app.js` — a separate code
// path that hard-returns [], so the filed "a change here can alter boot paths"
// worry is structurally impossible for this element-level widening.
// `.choice[data-kind]:not([disabled])` in openProviderPicker() (`grep -n
// 'function openProviderPicker' cloud/priv/static/app.js`) carries a pseudo-class
// and stays outside this grammar.
const COMPOUND_SEL = /^\.([\w-]+)\[([\w:.-]+)(?:="([^"]*)")?\]$/;

// Flat scan: every whitelisted OPEN tag in `html` becomes a sibling stub
// carrying its double-quoted attributes (so getAttribute("data-id") answers a
// real value). Deliberately not a parser — see the contract above.
function parseChildren(html, makeEl) {
  const out = [];
  TAG_RE.lastIndex = 0;
  let m;
  while ((m = TAG_RE.exec(html)) !== null) {
    const el = makeEl("", m[1]);
    const raw = m[2] || "";
    ATTR_RE.lastIndex = 0;
    let a;
    // a[2] is undefined for a bare attribute (`data-prov-disconnect`), which the
    // DOM reflects as the empty string — the value nobody reads, but the
    // PRESENCE `[attr]` selectors and hasAttribute() ask about.
    while ((a = ATTR_RE.exec(raw)) !== null) el.setAttribute(a[1], a[2] === undefined ? "" : a[2]);
    el.disabled = /\bdisabled\b/.test(raw);
    out.push(el);
  }
  return out;
}

// Serialize a mounted node back into its parent's innerHTML, so appendChild is
// observable. Attribute order is stable (class first, then insertion order).
function serializeEl(el) {
  if (!el) return "";
  const tag = String(el.tagName || "div").toLowerCase();
  let attrs = "";
  if (el.className) attrs += ' class="' + el.className + '"';
  for (const k of Object.keys(el._attrs || {})) {
    if (k === "class") continue;
    attrs += " " + k + '="' + el._attrs[k] + '"';
  }
  return "<" + tag + attrs + ">" + (el.innerHTML || "") + "</" + tag + ">";
}

function makeDom() {
  const registry = new Map();

  function makeEl(id, tagName) {
    // Backing state for the innerHTML accessor: the serialized markup and the
    // flat child list parsed out of it (plus anything appendChild mounted).
    let html = "";
    let kids = [];
    const handlers = Object.create(null);
    const attrs = Object.create(null);

    const el = {
      id: id || "",
      tagName: (tagName || "div").toUpperCase(),
      textContent: "",
      value: "",
      hidden: false,
      className: "",
      disabled: false,
      // (d) The fourth incapacity. Present and true: every element this shim
      // hands out is mounted, so the isConnected guards let their render run.
      isConnected: true,
      style: {},
      dataset: {},
      scrollTop: 0,
      scrollHeight: 0,
      clientHeight: 0,
      parentNode: null,
      // Exposed for serializeEl only (a mounted node must round-trip into its
      // parent's innerHTML); app.js never reads it.
      _attrs: attrs,
      classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
      // (a) Handlers are KEPT, per type, in registration order.
      addEventListener(type, fn) {
        if (typeof fn !== "function") return;
        (handlers[type] || (handlers[type] = [])).push(fn);
      },
      removeEventListener(type, fn) {
        const list = handlers[type];
        if (!list) return;
        const i = list.indexOf(fn);
        if (i >= 0) list.splice(i, 1);
      },
      // Returns how many handlers actually ran — the number a check asserts on
      // so a never-wired (or wrongly-typed) listener cannot pass as success.
      dispatchEvent(ev) {
        const type = (ev && ev.type) || "click";
        const list = (handlers[type] || []).slice();
        const event = Object.assign({
          type,
          target: el,
          currentTarget: el,
          preventDefault() {},
          stopPropagation() {},
        }, ev || {});
        for (const fn of list) fn.call(el, event);
        return list.length;
      },
      // (b) A real click: dispatches every "click" handler and reports the
      // count. `el.click()` returning 0 means the button is DEAD.
      click() { return el.dispatchEvent({ type: "click" }); },
      setAttribute(k, v) {
        attrs[k] = String(v);
        if (k === "class") el.className = String(v);
        if (k === "id") el.id = String(v);
      },
      removeAttribute(k) { delete attrs[k]; },
      getAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k) ? attrs[k] : null; },
      hasAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k); },
      focus() {},
      blur() {},
      appendChild(child) {
        if (!child) return child;
        kids.push(child);
        child.parentNode = el;
        html += serializeEl(child);
        return child;
      },
      removeChild(child) {
        const i = kids.indexOf(child);
        if (i >= 0) kids.splice(i, 1);
        const s = serializeEl(child);
        const at = html.indexOf(s);
        if (at >= 0) html = html.slice(0, at) + html.slice(at + s.length);
        if (child) child.parentNode = null;
        return child;
      },
      insertAdjacentHTML(_pos, frag) { el.innerHTML = html + String(frag == null ? "" : frag); },
      // (c) Sub-tree lookup over the parsed children — the same objects across
      // calls, so a handler app.js attached to a row survives to the click.
      querySelectorAll(sel) {
        if (typeof sel !== "string") return [];
        if (CLASS_SEL.test(sel)) {
          const want = sel.slice(1);
          return kids.filter((k) => String(k.className || "").split(/\s+/).indexOf(want) >= 0);
        }
        if (ID_SEL_SUB.test(sel)) {
          const want = sel.slice(1);
          return kids.filter((k) => k.id === want);
        }
        const at = ATTR_SEL.exec(sel);
        if (at) {
          const name = at[1];
          const want = at[2];
          return kids.filter((k) =>
            k.hasAttribute(name) && (want === undefined || k.getAttribute(name) === want));
        }
        const cm = COMPOUND_SEL.exec(sel);
        if (cm) {
          const cls = cm[1];
          const name = cm[2];
          const want = cm[3];
          return kids.filter((k) =>
            String(k.className || "").split(/\s+/).indexOf(cls) >= 0 &&
            k.hasAttribute(name) && (want === undefined || k.getAttribute(name) === want));
        }
        return [];
      },
      querySelector(sel) { return el.querySelectorAll(sel)[0] || null; },
      closest() { return null; },
      getClientRects() { return []; },
      get children() { return kids.slice(); },
    };

    Object.defineProperty(el, "innerHTML", {
      get() { return html; },
      set(v) {
        html = String(v == null ? "" : v);
        kids = parseChildren(html, makeEl);
      },
      enumerable: true,
      configurable: true,
    });

    return el;
  }

  // Registry lookup for a bare #id selector; everything else is inert.
  const ID_SEL = /^#[\w-]+$/;
  function byId(id) {
    if (!registry.has(id)) registry.set(id, makeEl(id));
    return registry.get(id);
  }
  function query(sel) {
    if (typeof sel === "string" && ID_SEL.test(sel)) return byId(sel.slice(1));
    return null;
  }

  const documentEl = makeEl("documentElement");
  documentEl.getAttribute = () => null;

  const document = {
    readyState: "complete", // ⇒ app.js runs init() immediately at eval time
    documentElement: documentEl,
    body: makeEl("body"),
    addEventListener() {},
    removeEventListener() {},
    querySelector: query,
    querySelectorAll() { return []; },
    getElementById: byId,
    // Created (non-registry) elements are freshly-authored wiring surfaces. Now
    // that innerHTML really parses, their querySelector finds the real control
    // (toast()'s close button, the first smoke-exercised case) — but it still
    // NEVER answers null, because a primitive wiring markup this flat parse
    // does not model must not abort the boot by throwing on `.addEventListener`
    // of undefined. Registry (#id) elements keep the document-level null-
    // returning query above, so existence-driven logic is untouched.
    createElement(tag) {
      const el = makeEl("", tag);
      const real = el.querySelector.bind(el);
      el.querySelector = (sel) => real(sel) || makeEl("", "div");
      return el;
    },
  };

  return { registry, document, byId };
}

// ── per-scenario boot ────────────────────────────────────────────────────────
function bootScenario(name) {
  const { registry, document } = makeDom();

  // Backing stores we control so each scenario boots clean.
  const store = new Map();
  const sessionStore = new Map();
  const localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
  const sessionStorage = {
    getItem: (k) => (sessionStore.has(k) ? sessionStore.get(k) : null),
    setItem: (k, v) => sessionStore.set(k, String(v)),
    removeItem: (k) => sessionStore.delete(k),
  };

  const scen = SCENARIOS[name];
  // Seed the session exactly as mock.js does (logged-out scenario → none).
  if (scen.authed) {
    store.set("bpcloud.session", JSON.stringify({ token: "preview", team_id: "preview-team" }));
  }
  // seedLocal: pre-seed localStorage (e.g. bp_theme) so a scenario can exercise a
  // restored identity/mode before the first paint. Optional, smoke-only.
  if (scen.seedLocal) for (const k of Object.keys(scen.seedLocal)) store.set(k, String(scen.seedLocal[k]));

  // pathname/search are smoke-only optional scenario fields: a scenario that
  // needs a real path (e.g. /activate, to unlock isActivateFlow()) sets them.
  // Default "/"+"" keeps every pre-existing hash-routed scenario unchanged; the
  // browser harness (mock.js) ignores these and uses the actually-served path.
  const location = {
    hash: scen.deepLink || "#overview",
    pathname: scen.pathname || "/",
    search: scen.search || "",
    origin: "http://localhost",
    href: "http://localhost/",
  };

  // Per-boot mutable fixture state (cch-w2, D39). Handed to route() so a
  // scenario can model a route that actually CHANGES something — a stateless
  // fixture returns a byte-identical list after a destructive call, which is
  // indistinguishable from the call never having happened, i.e. exactly the
  // false green this slice exists to kill. Absent for mock.js (3-arg caller),
  // which keeps the browser harness stateless and unchanged.
  const fixtureState = {};

  // Every request is logged so a check can assert the WIRE (method + path),
  // which is the only coverage available for the destructive routes whose
  // toast text is a client-side constant and therefore identical whether the
  // server did the work or not.
  const calls = [];

  // fetch → scenario router → a Response-like the app's api() understands.
  function fetchStub(url, init) {
    const method = (init && init.method) || "GET";
    const p = String(url);
    calls.push({ method, path: p.split("?")[0] });
    const res = route(name, method, p, fixtureState) || { status: 404, body: { error: "not_found" } };
    return Promise.resolve({
      ok: res.status >= 200 && res.status < 300,
      status: res.status,
      headers: { get: (h) => (String(h).toLowerCase() === "content-type" ? "application/json" : null) },
      json: () => Promise.resolve(res.body),
      text: () => Promise.resolve(JSON.stringify(res.body)),
    });
  }

  function EventSourceStub() {
    return { addEventListener() {}, removeEventListener() {}, close() {}, onopen: null, onmessage: null, onerror: null };
  }

  const sandbox = {
    document,
    window: {
      addEventListener() {},
      removeEventListener() {},
      open() { return null; },
      matchMedia() { return { matches: false, addEventListener() {} }; },
    },
    location,
    history: { replaceState() {}, pushState() {} },
    localStorage,
    sessionStorage,
    navigator: {},
    fetch: fetchStub,
    EventSource: EventSourceStub,
    // Timers are inert: the load paths are pure promise chains; the elapsed
    // ticker + toast auto-dismiss would only add nondeterministic churn.
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: () => 1,
    clearInterval() {},
    console,
    URLSearchParams,
    URL,
  };
  sandbox.window.location = location;
  sandbox.globalThis = sandbox;

  // gr-p2-front-door: capture the app's __bpTestHook export (the same seam
  // __app.test.mjs uses) so an EXPECTATION can drive a pure mount — e.g. the
  // shared 2FA card, which only ever mounts behind a click this shim keeps
  // inert. The hook call runs at app.js eval tail, so it is populated by the
  // time bootScenario returns; absent in a real browser, a no-op here too if
  // app.js ever drops the export (expectations assert it explicitly).
  const captured = { hooks: null };
  sandbox.__bpTestHook = (h) => { captured.hooks = h; };

  vm.createContext(sandbox);
  vm.runInContext(APP_JS, sandbox, { filename: "app.js" });

  return { registry, hooks: captured.hooks, calls, fixtureState };
}

// Flush all pending microtasks (both realms share Node's one microtask queue).
async function flush() {
  for (let i = 0; i < 40; i++) {
    await Promise.resolve();
    await new Promise((r) => setImmediate(r));
  }
}

// ── EXPECTATIONS: the per-scenario view skeleton (edit HERE when markup moves) ─
const EXPECTATIONS = {
  // ── gr-p5-account-2fa (GR54/GR56/GR57): the account modal, recomposed ──────
  // The modal is CLICK-opened, so no deepLink reaches it. Drive the composition
  // through the REAL openModal primitive into the REAL #modal-body — the same
  // hook seam "loggedout-twofactor" uses for the login card — and pin the
  // rendered anatomy. The browser twin is mock.js's ?modal=account.
  "account-modal": {
    what: "the recomposed account modal — identity, sessions, password ON DEMAND, 2FA off-state; every lockout-bearing id intact",
    check(reg, hooks) {
      const model = hooks.accountModel({ team_id: "team_abc" }, SCENARIOS["account-modal"].data.me);
      assert.equal(model.twoFactorEnabled, false, "this fixture's /v1/me must say 2FA is off");
      hooks.openModal(hooks.accountModalHtml(model));
      const html = reg.get("modal-body").innerHTML || "";
      // The four bands of the recomposition.
      assert.ok(html.includes(">Your account<"), "the v4 heading must render");
      assert.ok(html.includes('class="am-identity"'), "the identity row must render");
      assert.ok(html.includes("owner of Guerrilla"), "the identity line must name the role and team");
      assert.ok(html.includes(">Sessions<"), "the sessions header must render");
      assert.ok(html.includes(">Two-factor authentication<"), "the 2FA header must render");
      // Password is DISCLOSED, not conditionally rendered: the form and all its
      // ids ship in the markup `hidden` so submitPasswordChange never unbinds.
      assert.ok(html.includes('id="am-pw-toggle"'), "the change-password disclosure link must render");
      assert.ok(/<form id="pw-form"[^>]*hidden/.test(html), "the password form must ship hidden, not absent");
      for (const id of ["modal-title", "pw-current", "pw-new", "pw-error", "sessions-box",
        "sessions-revoke-all", "pw-form", "modal-logout"]) {
        assert.ok(html.includes('id="' + id + '"'), "the modal must keep id=" + JSON.stringify(id));
      }
      // The footer is KEPT: both renders crop mid-scroll, so its absence is unproven.
      assert.ok(html.includes(">Close<") && html.includes(">Log out<"), "the Close / Log out footer must stay");
      // 2FA off-state, read free from /v1/me — no GET /v1/account/two-factor.
      assert.ok(html.includes('id="a2f-badge"') && html.includes(">Off<"), "the 2FA badge must read Off");
      assert.ok(html.includes('id="a2f-start"'), "the off state must offer the setup button");
      assert.ok(!html.includes('id="a2f-otp"'), "the off state must not draw the enroll form");
    },
  },
  "account-modal-tall": {
    what: "the NINE-session account modal — every row rendered, the escape hatches still present BELOW the list, no IP anywhere",
    check(reg, hooks) {
      const sessions = SCENARIOS["account-modal-tall"].data.accountSessions;
      assert.equal(sessions.length, 9, "the fixture must carry the tall shape, not the two-row short one");
      const rows = sessions.map((s) => hooks.sessionRowHtml(s)).join("");
      assert.equal((rows.match(/class="session-row"/g) || []).length, 9, "nine session rows render");
      assert.equal((rows.match(/session-revoke/g) || []).length, 8,
        "the current device is never self-revokable; the other eight are");
      // GR81: the fixture still SENDS an ip_address on every row; the panel
      // refuses to draw it, because on live every one of them is 172.18.0.1.
      assert.ok(!/84\.212\.31\./.test(rows), "no session IP is rendered");

      // Splice the rows in where loadSessions puts them, then pin that the
      // lockout-bearing controls survive at the bottom of a tall modal.
      hooks.openModal(hooks.accountModalHtml(
        hooks.accountModel({ team_id: "team_abc" }, SCENARIOS["account-modal-tall"].data.me)));
      const shell = reg.get("modal-body").innerHTML || "";
      const html = shell.replace(/(<div id="sessions-box"[^>]*>)[\s\S]*?(<\/div>)/, "$1" + rows + "$2");
      for (const id of ["sessions-revoke-all", "modal-logout"]) {
        assert.ok(html.includes('id="' + id + '"'), "the tall modal keeps id=" + JSON.stringify(id));
      }
      const lastRow = html.lastIndexOf("session-row");
      assert.ok(html.indexOf('id="modal-logout"') > lastRow,
        "Log out sits BELOW the whole session list — the anatomy that stranded it on live");
      // Honest about the limit: at the harness's 1000px height nine rows FIT, so
      // this documents the tall shape rather than proving overflow containment.
      assert.ok(html.includes(">Close<") && html.includes(">Log out<"), "the footer survives the tall list");
    },
  },
  // ── cch-w2-revoke-click-oracle: THE CLICK ORACLE ───────────────────────────
  // Every other expectation in this file reads markup. This one WATCHES THE APP
  // DO SOMETHING: it clicks #acct-btn and lets the real openAccountModal →
  // loadSessions → render → wire chain run, then clicks the buttons that chain
  // produced. Nothing is spliced, mounted or simulated on the app's behalf —
  // contrast account-modal-tall above, which hand-builds the rows with
  // sessionRowHtml because until now the list could not render here at all.
  //
  // WHAT IT ASSERTS, and why each assertion is the one that can fail:
  //   1. rows rendered through the REAL path      — proves the isConnected gate is open
  //   2. clicking a row's Revoke returns fired>0  — proves the button is WIRED for "click"
  //   3. DELETE /v1/account/sessions/<id> on wire — proves the right URL, right method
  //   4. the list SHRINKS 4→3                     — proves the server acted (stateful fixture, D39)
  //   5. sign-out-everywhere toasts the SERVER's count — the one text-observable false green
  //
  // cch-w2-revoke-ux-honesty AMENDED THIS SCENARIO IN PLACE (never forked it —
  // a parallel scenario would have left this one permanently red once the
  // confirm gate landed). Four assertions were added:
  //   6. the clicked row goes disabled + relabels — the pending state, read as STATE
  //   7. a per-row success TOAST mounts           — the leg used to succeed in silence
  //   8. sign-out-everywhere's DELETE is 0 after the trigger, 1 after #cm-confirm
  //   9. #modal-body carries the account screen again after the sheet closes
  //
  // COVERAGE BOUNDARY (D40 — an enforcement mechanism states its own limits).
  // Of the 8 unfixtured destructive DELETEs this slice is scoped to, exactly
  // ONE — /v1/account/sessions (the "Signed out other devices" revoke-all toast
  // in openAccountModal) — interpolates a server value into its toast, so it is
  // the only one where a missing fixture is visible AS TEXT
  // ("0 session(s) revoked."). This oracle covers it by TEXT. The per-row
  // sibling (:1112) is covered by WIRE + STATE + its own success toast.
  // The remaining six — /v1/auth/logout (:1050), /v1/github/installation
  // (:2295), /v1/barkparks/:id (:5430, :5474), the webhook DELETE (:7381) and
  // /v1/sites/:id/github (:9991) — toast client-side CONSTANTS ("Instance
  // removed", "Webhook deleted"), so a generic 200 produces a message that is
  // both indistinguishable from the real one and, in fact, honest. Their defect
  // is not "prod says 0", it is "nothing here would catch a regression". They
  // are NOT covered by this scenario; they are click-reachable now that the
  // shim works, and that is follow-on work, filed — not silently implied.
  //
  // WHAT THIS SHIM CANNOT PROVE — TWO LIMITS THAT MANUFACTURE WRONG VERDICTS
  // HERE, both learned the hard way (D55, D56). State them before writing a new
  // assertion in this scenario:
  //   • IT DOES NOT MODEL DETACHMENT. Every #id lives in ONE FLAT registry and
  //     reports isConnected: true forever. In the real DOM #sessions-box is a
  //     DESCENDANT of #modal-body, so openModal's `bodyEl.innerHTML = html`
  //     (app.js) DESTROYS it and closeModal() empties what remains — yet here
  //     the node survives, keeps its rows, and answers every question about
  //     them. Measured: a sign-out-everywhere onConfirm that never re-renders
  //     leaves ALL 87 GREEN while #modal-body is "" and the operator, in a
  //     browser, sees an empty dialog. ⇒ ANY assertion about what exists after
  //     a modal swap must anchor on #modal-body's innerHTML, the node the
  //     browser actually replaces — never on the descendant's own registry entry.
  //   • IT DELIVERS CLICKS TO DISABLED ELEMENTS. dispatchEvent has no `disabled`
  //     guard, so a correctly-disabled button still returns 1 from click() and
  //     runs its handler. ⇒ NEVER prove a pending/disabled state with a second
  //     click (it reports a working guard as broken, and doubles the DELETE
  //     count); read `disabled` and `textContent` directly, as §2b does.
  "account-modal-revoke": {
    what: "THE CLICK ORACLE — real clicks drive revoke: rows render, a row revoke pends + toasts + shrinks the list, and sign-out-everywhere waits for its danger-tier confirm before reporting the SERVER's count",
    async check(reg, hooks, ctx) {
      // ─ 1. the modal opens by CLICK, exactly as a user opens it ─────────────
      const acct = reg.get("acct-btn");
      assert.ok(acct, "#acct-btn was never touched — init() did not wire the shell");
      assert.equal(acct.click(), 1, "#acct-btn must have exactly one click handler (it opens the account modal)");
      await ctx.settle();

      // The session list rendered through the REAL loadSessions, which is only
      // possible because the shim now answers isConnected (loadSessions' box guard).
      const box = reg.get("sessions-box");
      const rendered = box.innerHTML || "";
      assert.ok(rendered.includes("session-row"),
        "#sessions-box is empty — loadSessions bailed at its `if (!box.isConnected) return;` guard, " +
        "which is the state this harness sat in for its whole existence");
      assert.equal(countMatches(rendered, 'class="session-row"'), 4, "the fixture's four sessions render");
      assert.equal(ctx.countCalls("GET", "/v1/account/sessions"), 1, "the list was fetched once on open");

      // ─ 2/3/4. the PER-ROW revoke: wired, right URL, and it ACTS ────────────
      const revokes = box.querySelectorAll(".session-revoke");
      assert.equal(revokes.length, 3, "three revokable rows — the current device is never self-revokable");
      const victim = revokes[0].getAttribute("data-id");
      assert.ok(victim && victim !== "sess_here",
        "the row must carry a real data-id and must not be the acting session, got " + JSON.stringify(victim));

      // THE CLICK-COUNT ASSERTION IS LOAD-BEARING. This shim's selector support
      // is narrow, so a selector it cannot parse answers an EMPTY list — and a
      // loop over nothing "succeeds". A dead button (wired to "mousedown", say)
      // dispatches zero handlers, and only this line notices.
      const fired = revokes[0].click();
      assert.equal(fired, 1,
        "the per-row Revoke dispatched " + fired + " click handlers — the button is DEAD. " +
        "Every source string can still be present and correct; nothing is bound to \"click\".");

      // ─ 2b. cch-w2-revoke-ux-honesty: the PENDING state, read DIRECTLY ──────
      // The handler disables the button and swaps its label BEFORE api() is
      // called, so both are observable synchronously — before the settle that
      // repaints the list out from under this node.
      //
      // ASSERTED BY STATE, NEVER BY A SECOND CLICK (D56). The shim's
      // dispatchEvent has no `disabled` guard, so `revokes[0].click()` on a
      // CORRECTLY disabled button still returns 1 and would red the DELETE-count
      // assertion below. A double-click test here reports a working guard as
      // broken; only reading `disabled`/`textContent` tells the truth.
      assert.equal(revokes[0].disabled, true,
        "the clicked Revoke must go disabled while its DELETE is in flight — an enabled button " +
        "during an unacknowledged destructive request invites the double-revoke");
      assert.equal(revokes[0].textContent, "Revoking…",
        "the label must confess the in-flight state, got " + JSON.stringify(revokes[0].textContent));

      await ctx.settle();

      assert.equal(ctx.countCalls("DELETE", "/v1/account/sessions/" + victim), 1,
        "the click must issue exactly one DELETE for that row's id");
      // The per-row leg used to succeed in SILENCE: the row simply vanished on
      // the re-render, which is indistinguishable from a render glitch.
      const rowToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(rowToast.includes("Device signed out"),
        "a successful per-row revoke must SAY SO — no success toast mounted; got: " + rowToast);
      // D39: this line is the reason the fixture is stateful. Against a static
      // fixture the re-render returns a byte-identical list, so this assertion
      // would hold whether or not the DELETE ever reached the server — a false
      // green planted inside the anti-false-green scenario.
      const after = reg.get("sessions-box").innerHTML || "";
      assert.equal(countMatches(after, 'class="session-row"'), 3,
        "the revoked row must be GONE on the re-render (4 → 3); an unchanged list means the DELETE did nothing");
      assert.ok(!after.includes('data-id="' + victim + '"'), "the revoked row's id must not come back");
      assert.equal(ctx.countCalls("GET", "/v1/account/sessions"), 2, "the success arm refetches the list");

      // ─ 5. SIGN OUT EVERYWHERE: gated, then the text-observable false green ─
      const all = reg.get("sessions-revoke-all");
      assert.equal(all.click(), 1, "the Sign-out-everywhere button must be wired for \"click\"");

      // ─ 5a. cch-w2-revoke-ux-honesty: THE TRIGGER ONLY OPENS THE SHEET ─────
      // The blast-radius button must NOT fire on the first click. This is the
      // assertion that catches a gate someone removes "to simplify" later: with
      // no confirmModal the DELETE is already on the wire right here.
      assert.equal(ctx.countCalls("DELETE", "/v1/account/sessions"), 0,
        "sign-out-everywhere fired its DELETE on the FIRST click — the confirm gate is gone, " +
        "and an irreversible-feeling action just happened with no way to say no");
      // Proven by what #modal-body actually CONTAINS — reg.get() alone would
      // answer a freshly-minted empty stub for any id and prove nothing.
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes('id="cm-confirm"'),
        "the confirm sheet did not mount into #modal-body; got: " + sheet.slice(0, 200));
      assert.ok(sheet.includes("Sign out everywhere else?"),
        "the sheet must name what it is about to do, in the title");
      assert.ok(sheet.includes("btn-danger"),
        "GR41: a grave-but-reversible action wears the danger tier's weight");

      // D54, AS AMENDED BY cch-w10. The confirm click goes BETWEEN the trigger
      // and the settle. The tier is `danger`, NOT `destroy` — a destroy sheet
      // would additionally need #cm-typed's value set plus an "input" event
      // before #cm-confirm arms, and (measured) an un-armed #cm-confirm STILL
      // returns 1 from click(), so the `fired == 1` idiom cannot detect the
      // disarm. D54 concluded from that that the disarm was UNOBSERVABLE here.
      // IT IS OBSERVABLE — on two objects D54 did not separate:
      //   • #modal-body's PARSED child carries the SHIPPED state (the `disabled`
      //     attribute confirmModalHtml emitted). This is the line below.
      //   • the WIRE carries the effect: openConfirmModal's handler bails at
      //     `if (!confirmModalArmed(state)) return;`, so an unarmed Confirm
      //     issues zero requests (asserted on all three destroy legs).
      // What is NOT observable is the disarm on `reg.get("cm-confirm")` — a
      // fresh registry stub answers disabled=false whether or not any sheet
      // mounted, which is why reading it would be a false green.
      // THIS LINE IS THE DISCRIMINATOR'S OTHER HALF: the same read that must
      // answer `true` on a destroy sheet must answer `false` here, or it is not
      // measuring the tier at all.
      const parsedDanger = parsedConfirmButton(reg);
      assert.ok(parsedDanger, "the danger sheet's Confirm must be parsed out of #modal-body");
      assert.equal(parsedDanger.disabled, false,
        "a DANGER-tier Confirm ships ARMED (no typed echo). If this reads true, the destroy-tier " +
        "disarm assertions elsewhere are measuring something other than the tier.");
      const cmConfirm = reg.get("cm-confirm");
      assert.ok(cmConfirm, "#cm-confirm was never touched — openConfirmModal did not wire the sheet");
      assert.equal(cmConfirm.click(), 1, "the sheet's Confirm must be wired for \"click\"");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/account/sessions"), 1, "one sign-out-everywhere DELETE on the wire");

      // ─ 5b. THE HARNESS'S OWN FALSE GREEN, CLOSED (D55) ────────────────────
      // In a real browser #sessions-box lives INSIDE #modal-body, so mounting
      // the confirm sheet destroyed it and closeModal() emptied what was left;
      // a post-success `loadSessions()` would bail at `if (!box) return` and
      // the operator would be left with no account modal at all. This shim
      // cannot see that: its #id registry is FLAT and every node reports
      // isConnected: true, so #sessions-box is immortal here and every
      // assertion below about it passes with #modal-body sitting at "".
      // Anchor on the node the browser actually replaces. MUTATION-KILLED BOTH
      // WAYS: green with onConfirm's openAccountModal() re-render, red
      // (modal-body === "") without it — while the #sessions-box assertions
      // below stay green in both and discriminate nothing.
      const reborn = reg.get("modal-body").innerHTML || "";
      assert.ok(reborn.includes('id="sessions-box"'),
        "#modal-body no longer contains the account modal — the confirm sheet replaced it and " +
        "nothing re-rendered, so in a real browser the operator is left staring at an empty dialog. " +
        "onConfirm must call openAccountModal() after ctl.succeed(). #modal-body is: " +
        JSON.stringify(reborn.slice(0, 120)));
      assert.ok(reborn.includes('id="modal-logout"') && reborn.includes(">Your account<"),
        "the re-render must be the WHOLE account screen, not a fragment");

      const toasts = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(toasts.includes("Signed out other devices"), "the success toast must actually mount");
      // Two sessions remained revokable after the per-row revoke, so the SERVER
      // says 2. The "Signed out other devices" revoke-all toast renders
      // `((r.data && r.data.revoked) || 0)` — with no DELETE
      // fixture the generic `/v1/` 200 {} answers `{}`, `revoked` is undefined,
      // and the console cheerfully announces a revoke of nothing.
      assert.ok(!toasts.includes("0 session(s) revoked"),
        "THE FALSE GREEN: the console reported '0 session(s) revoked.' after revoking real sessions — " +
        "DELETE /v1/account/sessions answered the generic 200 {} instead of {revoked: N}");
      assert.ok(toasts.includes("2 session(s) revoked"),
        "the toast must carry the SERVER's count (2 others remained), not a client-invented number; got: " + toasts);

      // And the list settles on the acting device alone.
      const settled = reg.get("sessions-box").innerHTML || "";
      assert.equal(countMatches(settled, 'class="session-row"'), 1, "only the acting session survives");
      assert.ok(settled.includes("This device"), "and it is the current one");
    },
  },
  "account-modal-2fa-badcode": {
    what: "enrollment rejected — 422 invalid_otp renders INLINE in the .form-error grammar, the form survives, and no toast fires",
    check(reg, hooks) {
      // The panel renders are pure, so drive the state the 422 arm produces and
      // pin the honest recovery: the code field stays, carrying the sentence.
      const copy = hooks.accountTwoFactorErrorCopy(422, { error: "invalid_otp" });
      assert.ok(copy && copy.includes("didn't match"), "invalid_otp must get its own sentence");
      const uri = "otpauth://totp/Barkpark%20Cloud:ada@acme.com?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Barkpark%20Cloud";
      hooks.openModal(hooks.accountModalHtml(hooks.accountModel({}, SCENARIOS["account-modal-2fa-badcode"].data.me)));
      const panel = hooks.accountTwoFactorPanelHtml({ phase: "enroll", uri, secret: "JBSWY3DPEHPK3PXP", error: copy });
      assert.ok(panel.includes('class="form-error a2f-error"'), "the error must ride the inline grammar");
      assert.ok(panel.includes('id="a2f-otp"'), "the code field must survive a rejection");
      assert.ok(panel.includes("a2f-qr-svg"), "the QR must still be there to re-scan");
      assert.ok(!/\brate[ -]?limit|\b429\b|try again in/i.test(panel),
        "GR52b: this route is genuinely unthrottled — no rate-limit theatre");
      // The toast stack is untouched: inline errors NEVER dive into a toast.
      // An untouched #toast-stack never enters the registry at all — either way,
      // nothing was appended to it.
      const toasts = reg.get("toast-stack");
      assert.ok(!toasts || !(toasts.innerHTML || "").length, "a field error must not fire a toast");
    },
  },
  "account-modal-2fa-on": {
    what: "2FA already ON — the on-row with regenerate + turn-off, derived from /v1/me alone (zero extra fetches)",
    check(reg, hooks) {
      const model = hooks.accountModel({ team_id: "team_abc" }, SCENARIOS["account-modal-2fa-on"].data.me);
      assert.equal(model.twoFactorEnabled, true, "the on-state must come from /v1/me's two_factor_enabled");
      hooks.openModal(hooks.accountModalHtml(model));
      const html = reg.get("modal-body").innerHTML || "";
      assert.ok(html.includes(">On<"), "the badge must read On");
      assert.ok(html.includes('id="a2f-regen"'), "the on-row must offer regenerate");
      assert.ok(html.includes('id="a2f-disable"'), "the on-row must offer turn-off");
      assert.ok(!html.includes('id="a2f-start"'), "an enrolled account is never offered setup again");
    },
  },
  loggedout: {
    what: "the sign-in screen (no shell)",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must be hidden");
      assert.equal(reg.get("login-card").hidden, false, "login card must be visible");
    },
  },
  empty: {
    what: "first-run onboarding on an empty dashboard (A4 welcome runway)",
    container: "overview-body",
    // A4 replaced the start-card checklist with the welcome runway; this
    // expectation lagged the markup (pre-existing red) — updated to the
    // shipped welcomeHeroHtml skeleton.
    includes: ["runway-hero", "Launch your first Barkpark", "runway-sub"],
    excludes: ['class="fleet-row"'],
  },
  "loggedout-invited": {
    what: "the sign-in banner announcing the parked invitation",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      const banner = reg.get("auth-invite").innerHTML;
      assert.ok(banner.includes("Northwind"), "banner must name the inviting team");
      assert.ok(banner.includes("ada@acme.com"), "banner must name the invited address");
    },
  },
  "mixed-fleet": {
    what: "one fleet row per instance, each with a status pill",
    container: "fleet-body",
    includes: ["status-pill"],
    // Structural, count-based: exactly one .fleet-row per fixture instance.
    fleetRowsEqualFixture: true,
  },
  provisioning: {
    what: "the watched provisioning timeline",
    container: "instance-body",
    // #1180 (9eff1fee) retired the bp-tl-step* classes: the timeline now renders
    // the shared newStepsHtml rows (new-steps / new-step active) — expectation lagged.
    includes: ["bp-timeline", "new-steps", "new-step active", "bp-console", "Provisioning"],
    excludes: ["bp-tl-fail"],
  },
  failed: {
    what: "the setup-failed state with the verbatim error",
    container: "instance-body",
    // #1180 (9eff1fee) retired the bp-tl-step* classes: the failed row is now
    // new-step failed (the bp-tl-fail block itself survived) — expectation lagged.
    includes: ["bp-tl-fail", "new-step failed", "Setup failed", "Retry setup", "Studio never came up"],
  },
  // Rollback/redeploy (charter D7): the current live row offers Redeploy + the
  // Current chip, the prior live row offers rollback, the failed row neither.
  rollback: {
    what: "deployment rows with Redeploy / Roll-back actions + the Current chip",
    container: "site-body",
    includes: ['data-kind="redeploy"', ">Redeploy<", ">Roll back to this<", "dep-current", "live since "],
  },
  // The 409-failure twin boots to the same skeleton; the inline-failure morph
  // itself is click-driven (covered by the vm unit tests + live browser).
  "promote-failure": {
    what: "the same deploy rows (failure path is exercised on click)",
    container: "site-body",
    includes: ['data-kind="redeploy"', ">Roll back to this<"],
  },
  // Rollback endgame — the promote's own three states (charter wave-4 owed).
  // IN-FLIGHT: a Building row streams on TOP while the still-live deploy keeps
  // the Current chip (a queued build serves no traffic yet). The exact skeleton
  // the optimistic promoteReconcile paints — frozen for the eye.
  "promote-in-flight": {
    what: "the new build streams on top; Current stays on the live deploy",
    container: "site-body",
    includes: ["dep-pill dep-building", "dep-current", ">Redeploy<", ">Roll back to this<"],
  },
  // RETRY: renders the rollback skeleton; the transient-500 → "Try again"
  // (retry recovery) morph is click-driven (covered by the vm unit tests).
  "promote-retry": {
    what: "the deploy rows; the transient failure → Try again is click-driven",
    container: "site-body",
    includes: ['data-kind="redeploy"', ">Roll back to this<"],
  },
  // MIGRATED: the promoted build went live — the Current chip MOVED to it; the
  // old current is now a prior live deploy offering "Roll back to this" (two
  // rollbackable live rows now, no Building row).
  "promote-migrated": {
    what: "the Current chip has migrated to the now-live deploy",
    container: "site-body",
    includes: ["dep-current", ">Redeploy<", ">Roll back to this<"],
    excludes: ["dep-pill dep-building"],
  },
  // Invitation accept: each committed terminal renders its designed card with
  // exactly one [data-invite-act] action (esc() turns ' into &#39; in copy).
  "invite-joined": {
    what: "the Join confirm for a live foreign-team invitation",
    container: "view-invite",
    includes: ['data-invite-act="join"', "Northwind Trading", "invite-skip", "Not now"],
  },
  "invite-expired": {
    what: "the calm expired dead-end with one next action, still WARN (recoverable)",
    container: "view-invite",
    // The other half of the ruling: expired is "ask for a fresh one", not a
    // dead link, so it must NOT drift into the danger mark.
    includes: ["has expired", 'data-invite-act="overview"', "invite-ico--warn"],
    excludes: ['data-invite-act="join"', "invite-ico--danger"],
  },
  "invite-already-member": {
    what: "the already-a-member card with one next action",
    container: "view-invite",
    includes: ["already a member", 'data-invite-act="overview"'],
    excludes: ['data-invite-act="join"'],
  },
  "invite-invalid": {
    what: "the revoked/used dead-end with one next action, wearing the DANGER mark",
    container: "view-invite",
    // gr-blk-invite-ico-danger-variant: a dead link and a retryable error used
    // to be the same "!" glyph. This is the mounted proof the danger variant
    // reaches the real render path, not just the pure helper.
    includes: ["isn&#39;t valid any more", 'data-invite-act="overview"', "invite-ico--danger"],
    excludes: ['data-invite-act="join"', "invite-ico--warn"],
  },
  // C8: the tab strip registers Timeline and marks it active on the deep link.
  // (The feed itself mounts through element-level querySelector, which this
  // shim keeps inert — the feed's rendering is pinned in __app.test.mjs.)
  timeline: {
    what: "the instance workspace routes the Timeline tab",
    container: "instance-body",
    includes: ["inst-tabs", '/timeline" aria-current="page"', 'id="instance-tabpanel"', ">Timeline<"],
  },
  "timeline-events-only": {
    what: "the Timeline tab routes for a non-admin too (403 degradation is harness-pinned)",
    container: "instance-body",
    includes: ["inst-tabs", '/timeline" aria-current="page"'],
  },
  // C10/OC7 + W4/OC19: the Usage sub-tab routes on its deep link AND fills its
  // meter wall — including the Wave-4 14-day sparklines. mountUsageTab re-acquires
  // the tabpanel by id (the same idiom refreshInstanceTimeline uses), so its
  // parallel /usage + /usage/history fetches render into the OBSERVABLE
  // #instance-tabpanel here. The tab strip lands in #instance-body; the sparkline
  // markup lands in #instance-tabpanel (both proved below).
  "usage-quota": {
    what: "the Usage tab routes and fills the meter wall with 14-day sparklines",
    check(reg) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      for (const needle of ["inst-tabs", '/usage" aria-current="page"', 'id="instance-tabpanel"', ">Usage<"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel meter wall rendered empty");
      // Progressive fill landed: a meter with numeric history carries a sparkline.
      assert.ok(panel.includes('class="usage-spark"'), "meter wall must carry a sparkline container");
      assert.ok(panel.includes("<polyline"), "a real history run draws a polyline");
      // The grid is still fully present (every meter label renders, sparks or not).
      assert.ok(panel.includes("Documents"), "the documents meter renders in the wall");
    },
  },
  // w6 (OC25): the instance Webhooks sub-tab. mountWebhooksTab re-acquires the
  // tabpanel by id (the mountUsageTab idiom), so the shell + the endpoint list
  // render into the OBSERVABLE #instance-tabpanel. The tab strip lands in
  // #instance-body; the list (each row carrying the new Edit action) lands in
  // #instance-tabpanel. The edit/create MODAL flows are click-driven (inert here)
  // and DOM-tested in __app.test.mjs.
  "webhooks-panel": {
    what: "the Webhooks tab routes and fills the endpoint list with the Edit action",
    check(reg) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      for (const needle of ["inst-tabs", '/webhooks" aria-current="page"', 'id="instance-tabpanel"', ">Webhooks<"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel webhook list rendered empty");
      assert.ok(panel.includes('class="wh-card"'), "the endpoint list must render webhook cards");
      assert.ok(panel.includes("data-wh-edit"), "each card must carry the w6 Edit action");
      assert.ok(panel.includes("Prod indexer"), "the fixture webhook name renders");
      assert.ok(panel.includes("data-wh-delete"), "the full action bar renders (delete present)");
    },
  },
  // gr-p2 HOME TRIAGE (C-01): the v4 Overview folds the wave-3 fleet-usage strip
  // into the instances grid + the page-header slots meter. The card stat pairs
  // (DOCS/DISK/CPU/RAM) read the SAME /v1/usage/summary as the strip did (no
  // per-instance fan-out); a box at its RAM ceiling tints that stat amber. The
  // header slots meter reads the REAL team instance quota (10) — never hardcoded.
  "fleet-usage": {
    what: "the v4 instances grid paints real per-instance stats + the header slots meter reads the real quota",
    check(reg) {
      // Each Overview mount is its own registry element in this fake DOM: the
      // grid paints #overview-instances, the slots meter #overview-slots.
      const grid = (reg.get("overview-instances") || {}).innerHTML || "";
      assert.ok(grid.includes('class="instances-grid"'), "the v4 instances grid renders");
      assert.ok(grid.includes("instance-card--"), "cards carry their status accent");
      assert.ok(grid.includes(">CPU</span>") && grid.includes(">RAM</span>"), "CPU/RAM stat pairs render");
      assert.ok(grid.includes("100%"), "the hot box's RAM value (100%) renders from the real sample");
      assert.ok(grid.includes("is-warn"), "an over-ceiling stat tints amber");
      assert.ok(grid.includes("Open Studio"), "live cards carry the Open Studio link");
      // The header slots meter reads count / REAL quota — the fixture's team
      // ceiling is 10 with 3 boxes in the fleet.
      const slots = (reg.get("overview-slots") || {}).innerHTML || "";
      assert.ok(slots.includes("3 / 10 slots"), "slots meter shows count / real quota, never hardcoded");
    },
  },
  // C8: the golden-path verify card renders from the events feed on Overview.
  "verify-pass": {
    what: "verify chips — three green probes + the quiet re-check",
    container: "instance-verify",
    includes: ["vf-card", "vf-chip vf-chip--pass", "All checks passed", "Check now"],
    excludes: ["vf-chip--fail", "Run first check"],
  },
  "verify-fail": {
    what: "verify chips — the failing Studio probe rendered honestly",
    container: "instance-verify",
    includes: ["vf-chip vf-chip--fail", "502", "1 of 3 checks failing"],
    excludes: ["All checks passed"],
  },
  "verify-never": {
    what: "verify chips — never run, the card invites the first check",
    container: "instance-verify",
    includes: ["Run first check", "vf-chip vf-chip--unknown", "Never checked"],
    excludes: ["vf-chip--pass", "vf-chip--fail"],
  },
  // bp-login-ux W3 (decision 40): the /activate device-login approve page's
  // PRE-CLICK skeletons. Each asserts DISTINCT per-state markup (a `device`
  // fixture that went missing would make inspect fall to the /v1/ catch-all's
  // 200 {}, folding gone/rate_limited into a degenerate "confirm" — the excludes
  // catch exactly that false-confirm). Click-driven approved/denied morphs are
  // DOM-tested in __app.test.mjs (smoke's click() is inert).
  "activate-entry": {
    what: "the manual code-entry form (authed, no prefill)",
    container: "activate-body",
    includes: ['id="activate-form"', 'id="activate-code"', "Approve a device sign-in", ">Continue<"],
    excludes: ["Approve this sign-in?", "Too many attempts", "expired or was already used"],
  },
  "activate-confirm": {
    what: "the confirm screen naming the requesting machine + Approve/Deny, with the (always-172.18.0.1) IP suppressed",
    container: "activate-body",
    includes: ["Approve this sign-in?", "bp on nimbus.local",
      'id="activate-approve"', 'id="activate-deny"'],
    // GR81: the fixture STILL sends an ip_address (the wire shape is unchanged);
    // the screen refuses to draw it, because in prod that field is the Docker
    // bridge gateway for every device and so cannot answer "is this machine
    // mine?". Revert with gr-bl-peer-ip-container.
    excludes: ["Too many attempts", "expired or was already used", "Unknown device",
      "203.0.113.7", "IP address"],
  },
  "activate-gone": {
    what: "the expired/used dead-end offering a fresh-code retry",
    container: "activate-body",
    includes: ["This code has expired or was already used", ">Enter a different code<"],
    excludes: ["Approve this sign-in?", "Too many attempts"],
  },
  "activate-rate-limited": {
    what: "the honest 429 with a PAUSED (disabled) retry countdown",
    container: "activate-body",
    // The countdown ticker is stubbed inert (smoke's setInterval never fires), so
    // this pins the INITIAL disabled skeleton only, never a tick.
    includes: ["Too many attempts", "Try again in 15s", "disabled"],
    excludes: ["Approve this sign-in?", "This code has expired"],
  },
  "activate-logged-out": {
    what: "logged out — the sign-in card banners the parked device code (park → resume)",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must be hidden");
      const banner = (reg.get("auth-activate") || {}).innerHTML || "";
      assert.ok(banner.includes("Approve a device sign-in."), "banner must announce the device approval");
      assert.ok(banner.includes("ABCD-2345"), "banner must show the parked code");
    },
  },

  // ── gr-w3 v4 shell: morph / operator / generated identity picker ────────────
  "shell-root": {
    what: "v4 shell — the ROOT nav layer shows, both morph layers hidden, operator hidden (no flag)",
    check(reg) {
      assert.equal(reg.get("app-shell").hidden, false, "app shell must be visible");
      assert.equal(reg.get("nav-layer-root").hidden, false, "root nav layer must show at a workspace route");
      assert.equal(reg.get("nav-layer-instance").hidden, true, "instance layer must be hidden at root");
      assert.equal(reg.get("nav-layer-site").hidden, true, "site layer must be hidden at root");
      assert.equal(reg.get("nav-operator").hidden, true, "operator entry is fail-closed without the flag");
    },
  },
  "shell-instance": {
    what: "v4 shell — the INSTANCE layer morphs in with its section links; root hidden",
    check(reg) {
      assert.equal(reg.get("nav-layer-instance").hidden, false, "instance layer must show under #instance/<id>");
      assert.equal(reg.get("nav-layer-root").hidden, true, "root layer must collapse when drilled in");
      const sections = reg.get("nav-instance-sections").innerHTML || "";
      assert.ok(sections.includes("/timeline"), "instance sections must link the Timeline sub-tab");
      assert.ok(sections.includes(">Timeline<"), "instance sections must label Timeline");
      assert.ok(sections.includes(">Webhooks<"), "instance sections must label Webhooks");
    },
  },
  "shell-site": {
    what: "v4 shell — the SITE layer morphs in; root hidden",
    check(reg) {
      assert.equal(reg.get("nav-layer-site").hidden, false, "site layer must show under #site/<id>");
      assert.equal(reg.get("nav-layer-root").hidden, true, "root layer must collapse for a site");
      assert.equal(reg.get("nav-layer-instance").hidden, true, "instance layer stays hidden for a site");
    },
  },
  "operator-visible": {
    what: "v4 shell — platform_operator:true reveals the Operator entry (GR9 fail-open only on true)",
    check(reg) {
      assert.equal(reg.get("nav-operator").hidden, false, "operator entry must show when platform_operator is true");
    },
  },
  "identity-iris": {
    what: "v4 shell — the identity picker offers all 5 skins incl charple + iris; iris is the restored value (GR12)",
    check(reg) {
      const opts = reg.get("bp-theme-picker").innerHTML || "";
      for (const id of ["evergreen", "charple", "ember", "fjord", "iris"]) {
        assert.ok(opts.includes('value="' + id + '"'), "picker must offer the " + id + " identity");
      }
      assert.equal(reg.get("bp-theme-picker").value, "iris", "the restored bp_theme=iris is the active option");
    },
  },

  // ── gr-p2-front-door: the logged-out front door (B-01..B-03) ────────────────
  "loggedout-signup": {
    what: "#signup deep-links the sign-in card straight onto the Create-account tab",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must be hidden");
      assert.equal(reg.get("login-card").hidden, false, "login card must be visible");
      assert.equal(reg.get("field-team").hidden, false, "signup shows the team-name field");
      assert.equal(reg.get("field-remember").hidden, true, "signup hides remember-me");
      assert.equal(reg.get("auth-submit").textContent, "Create account", "the CTA reads Create account");
      assert.ok(reg.get("auth-foot").innerHTML.includes("Already have an account?"),
        "the foot offers the switch back to log in");
    },
  },
  "loggedout-reset": {
    what: "the emailed reset link swaps the login form for the set-new-password card (absorbs gr-backlog-reset-route-smoke)",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must stay hidden");
      assert.equal(reg.get("reset-card").hidden, false, "reset card must be visible");
      assert.equal(reg.get("login-card").hidden, true, "login card must hand off to the reset card");
      assert.equal(reg.get("twofa-card").hidden, true, "no stale 2FA card on a reset landing");
    },
  },
  "loggedout-twofactor": {
    what: "the shared 2FA challenge card mounts into #twofa-card in the AUTH (never theater) vocabulary",
    check(reg, hooks) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.ok(hooks && typeof hooks.mountTwoFactorCard === "function",
        "the 2FA mount seam must be exported through __bpTestHook");
      // The card only ever mounts behind a login submit (inert in this shim) —
      // drive the mount seam directly into the REAL #twofa-card slot, exactly
      // as showTwoFactorLoginCard does, and pin the composed markup.
      const root = reg.get("twofa-card");
      hooks.mountTwoFactorCard(root, { challengeToken: "demo-challenge" });
      const html = root.innerHTML || "";
      for (const needle of ['class="auth-title"', 'class="auth-desc"', 'id="tfa-form"',
        'id="tfa-code"', "Two-factor authentication", 'autocomplete="one-time-code"']) {
        assert.ok(html.includes(needle), "#twofa-card missing " + JSON.stringify(needle));
      }
      for (const needle of ["new-title", "new-desc"]) {
        assert.ok(!html.includes(needle),
          "#twofa-card must not import theater vocabulary " + JSON.stringify(needle));
      }
    },
  },

  // ── gr-p2 plan & dunning (C-03/C-04): trial CTA, GR17 dunning, portal return ─
  "billing-trial": {
    what: "the trial billing state — countdown chip, the RATIFIED CTA verbatim, quota-honest open plan grid, trial topbar chip",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // The ratified CTA (task-2ed0ea068f37345d), VERBATIM — never the
      // prototype's superseded draft.
      assert.ok(box.includes("Pick a plan below to keep it. No card needed."),
        "the ratified trial CTA must render verbatim");
      assert.ok(box.includes('class="trial-chip"'), "the countdown chip must render");
      assert.ok(box.includes("14 days left"), "the chip must carry the server's days-remaining");
      // Trial expiry is a real teardown — the dunning suspend promise must NOT
      // leak into trial copy.
      assert.ok(!box.includes("suspended — not deleted"), "trial copy must never borrow the dunning suspend promise");
      // The plan grid opens right below the CTA ("below" must be true) and is
      // quota-honest: real ceilings, no unlimited fiction.
      assert.equal(reg.get("billing-tiers").hidden, false, "the plan grid must be open under the CTA");
      const grid = reg.get("billing-tiers").innerHTML || "";
      for (const q of ["1 managed instance", "3 managed instances", "10 managed instances"]) {
        assert.ok(grid.includes(q), "tier cards must state the real ceiling " + JSON.stringify(q));
      }
      assert.ok(!grid.includes("Unlimited managed instances"), "the unlimited fiction must be gone");
      // GR20: the topbar chip reads trial (XOR — never the past-due skin).
      const chip = reg.get("billing-chip");
      assert.equal(chip.textContent, "Trial · 14 days left", "topbar chip must count the trial down");
      assert.ok(chip.className.includes("billing-chip--trial"), "topbar chip must ride the trial skin");
      assert.ok(!chip.className.includes("past_due"), "trial XOR past-due — never both");
      assert.equal(chip.href, "#billing", "the chip must route to #billing");
      // G-01: a trial has no paid Stripe plan → no portal to manage, nothing to
      // cancel; both owner action sections stay retired (their action is to
      // subscribe, in the plan grid above).
      assert.equal(reg.get("billing-manage-section").hidden, true, "a trial mounts no Manage-billing section");
      assert.equal(reg.get("billing-cancel-section").hidden, true, "a trial mounts no Cancel section");
    },
  },
  "billing-past-due": {
    what: "past due — the GR17 banner verbatim with data-driven dates, portal CTA, no denial copy, red topbar chip",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // GR17 strings, data-driven: both date slots filled from current_period_end.
      assert.ok(box.includes("Your card was declined on "), "the banner must open with the failed date");
      assert.ok(box.includes("Your instances keep running until "), "the banner must carry the suspend date");
      assert.ok(box.includes("then they're suspended — not deleted — and come right back the moment payment succeeds."),
        "the suspended-not-deleted sentence must render verbatim");
      assert.ok(box.includes(">Past due<"), "the banner must carry the Past due title");
      assert.ok(box.includes(">Supporter<"), "the banner must chip the plan name");
      assert.ok(box.includes(">Update payment method<"), "the GR17 portal CTA must render verbatim");
      // G-01 anatomy: Manage billing moved OUT of the state card into its own
      // .set-section action row (the state card no longer buries a button).
      assert.ok(!box.includes(">Manage billing<"), "the state card must NOT bury the portal button");
      const manage = reg.get("billing-manage").innerHTML || "";
      assert.ok(manage.includes(">Manage billing<"), "the Manage-billing action rides its own .set-section");
      assert.ok(/download invoices/i.test(manage), "the invoice-less portal copy lives in the action section");
      assert.equal(reg.get("billing-manage-section").hidden, false, "the Manage-billing section is shown for a paid plan");
      // Owner + paid + not-yet-cancelling → the Cancel section offers the danger action.
      assert.equal(reg.get("billing-cancel-section").hidden, false, "an owner may cancel a paid plan");
      assert.ok((reg.get("billing-cancel").innerHTML || "").includes("Cancel plan"), "the Cancel-plan danger action renders");
      // The dead promises stay dead.
      assert.ok(!box.includes("retry twice more"), "the retry-count fiction must be gone");
      assert.ok(!/contact support/i.test(box), "the support-mail denial copy must be gone");
      // GR20: the topbar chip flips to the past-due alarm (XOR trial).
      const chip = reg.get("billing-chip");
      assert.equal(chip.textContent, "Payment failed · fix billing", "topbar chip must alarm on past-due");
      assert.ok(chip.className.includes("billing-chip--past_due"), "topbar chip must ride the past-due skin");
      assert.ok(!chip.className.includes("--trial"), "past-due XOR trial — never both");
      // The sidebar pill keeps the PAID plan (the activePlan past_due fix).
      assert.equal(reg.get("ws-plan").textContent, "Supporter", "a past_due team keeps its paid plan in the sidebar pill");
    },
  },
  "billing-portal-return": {
    what: "back from the portal — billing renders the current plan, portal-managed copy, no denial copy",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      assert.ok(box.includes(">Supporter<"), "the current plan card must render after the round-trip");
      assert.ok(box.includes("3 managed instances"), "the features must state the real Supporter ceiling");
      // G-01 anatomy: the portal CTA rides the Manage-billing .set-section now.
      assert.ok((reg.get("billing-manage").innerHTML || "").includes(">Manage billing<"), "the portal CTA must render in its section");
      assert.equal(reg.get("billing-manage-section").hidden, false, "the Manage-billing section shows for the active plan");
      assert.ok(!/contact support/i.test(box), "the support-mail denial copy must be gone");
      // A healthy active sub shows NO topbar billing chip (trial XOR past-due only).
      assert.equal(reg.get("billing-chip").hidden, true, "an active paid plan mounts no topbar billing chip");
    },
  },

  // ── gr-p2 launch theater (GR18): /new journey + provisioning theater ────────
  "new-launch": {
    what: "/new signed-in — the template card + the one-field Launch step",
    check(reg) {
      assert.equal(reg.get("new-screen").hidden, false, "the /new screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "the app shell stays hidden on /new");
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.length > 0, "#new-body rendered empty");
      for (const needle of ['class="new-title">Astro Blog', "new-gets", 'id="new-launch-btn"', ">Launch<", "no card required"]) {
        assert.ok(body.includes(needle), "#new-body missing " + JSON.stringify(needle));
      }
    },
  },
  "theater-midflight": {
    what: "the /new theater mid-flight — conditional 5-row rail, the price line, the open console",
    check(reg) {
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.includes("new-progress"), "the progress theater must be mounted");
      assert.ok(body.includes("Launching Hugin"), "the head names the instance (v4 copy)");
      // GR18(1): the conditional rail — the warm path reports no freshen/content,
      // so EXACTLY the 5 planned rows render (never the render's 7 static rows).
      assert.equal(countMatches(body, '<li class="new-step '), 5, "typical run renders 5 rail rows");
      assert.ok(!body.includes('data-step="freshen"'), "unreported freshen stays hidden");
      assert.ok(!body.includes('data-step="content"'), "unreported content stays hidden");
      assert.ok(body.includes('class="new-step active" data-step="configure"'), "configure is the live step");
      // GR18(3): the price-before-charge line — the REAL catalog row via
      // formatMonthlyPrice, never plan-grid digits.
      assert.ok(body.includes("data-price-line"), "the price line renders above the rail");
      assert.ok(body.includes("€4.9/mo"), "the price is the catalog row (formatMonthlyPrice)");
      assert.ok(body.includes("price confirmed before anything is charged."), "the ratified price copy renders");
      assert.ok(body.includes("Falkenstein"), "the human region name renders");
      // GR18(5): console open-by-default with the worker's redacted narration.
      assert.ok(body.includes("new-console"), "the console panel mounts");
      assert.ok(!body.includes("new-console is-collapsed"), "the console is open by default");
      assert.ok(body.includes("configure: docker compose up -d"), "the live console lines render");
    },
  },
  "theater-failed": {
    what: "the /new theater failed — the snap: red failed step, skipped rest, ONE recovery action",
    check(reg) {
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.includes("new-failed"), "the failed theater must be mounted");
      assert.ok(body.includes("Setup didn&#39;t finish"), "the honest headline renders");
      // GR18(4): the honest server-owned failCopy, verbatim.
      assert.ok(body.includes("the TLS certificate was never issued"), "provision_error renders verbatim");
      // The snap: the failing step is failed, everything behind it is skipped —
      // never a live pending row, never a plan hint.
      assert.ok(body.includes('class="new-step failed" data-step="secure"'), "secure renders failed");
      assert.equal(countMatches(body, '<li class="new-step skipped"'), 3, "configure/verify/ready render skipped");
      assert.ok(!body.includes('class="new-step pending"'), "no live pending rows behind a failure");
      // ONE recovery action (parent D25) + the console stays for the read-out.
      assert.equal(countMatches(body, 'id="new-retry"'), 1, "exactly one Retry recovery action");
      assert.ok(body.includes(">Retry setup<"), "the recovery action is Retry setup");
      assert.ok(body.includes("new-console"), "the console stays on the failed screen");
      assert.ok(body.includes("provision FAILED after 3 attempts"), "the console carries the failure tail");
    },
  },
  "theater-ready": {
    what: "the /new ready hero — the SHARED readyHeroHtml: Live eyebrow, Open Studio, deploy handoff",
    check(reg) {
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.includes("new-ready"), "the shared ready hero must render");
      assert.ok(body.includes("Hugin is ready"), "the hero names the live instance");
      assert.ok(body.includes('id="new-open-studio"'), "Open Studio is the primary action");
      assert.ok(body.includes("hugin-5b2c1e.barkpark.cloud"), "the live URL renders");
      assert.ok(body.includes(">View instance<"), "the secondary View-instance affordance renders");
      assert.ok(!body.includes("new-progress"), "the progress theater has handed over");
    },
  },

  // ── gr-p2 HOME TRIAGE (C-01/C-02): the v4 Overview states (tail-append, OC9) ─
  "overview-trial-runway": {
    what: "the self-healing runway binds to onboarding: 2 of 3, the real instance-name hint, the Open Studio nudge",
    check(reg) {
      const state = (reg.get("overview-state") || {}).innerHTML || "";
      assert.ok(state.includes("runway-card"), "the mint runway card renders");
      assert.ok(state.includes("You're nearly set up"), "the runway heading renders");
      assert.ok(state.includes("2 of 3 done"), "progress binds to onboarding server truth");
      assert.ok(state.includes("Production is running"), "the instance step carries the real fleet-cache name");
      assert.ok(state.includes("Publish your first document"), "the pending published_doc step renders");
      assert.ok(state.includes("Open Studio"), "the pending step offers Open Studio");
      assert.ok(!state.includes("dunning-banner"), "runway and past-due banner are mutually exclusive");
    },
  },
  "overview-attention": {
    what: "the attention queue leads with the degraded box + its real reason + a working Open Studio",
    check(reg) {
      const body = (reg.get("overview-body") || {}).innerHTML || "";
      assert.ok(body.includes("Needs attention"), "the attention section heading renders");
      assert.ok(body.includes("attention-row"), "an attention row renders");
      assert.ok(body.includes(">Reporting</a>"), "the degraded box is named + linked");
      assert.ok(/Health down|Agent offline/.test(body), "the row carries the real status reason");
      assert.ok(body.includes("View instance"), "the row offers View instance");
      assert.ok(body.includes("fleet-open-studio"), "the row offers a working Open Studio");
      const grid = (reg.get("overview-instances") || {}).innerHTML || "";
      assert.ok(grid.includes("instance-card--warn"), "the degraded card carries the amber accent");
    },
  },
  "overview-past-due": {
    what: "GR17 overview dunning banner + the suspended instance-card banner, verbatim, no runway",
    check(reg) {
      const state = (reg.get("overview-state") || {}).innerHTML || "";
      assert.ok(state.includes("Your payment failed on"), "the GR17 overview banner lead sentence renders verbatim");
      assert.ok(state.includes("they're suspended — not deleted"), "the GR17 keep-running sentence renders verbatim");
      assert.ok(state.includes("Update payment method"), "the portal CTA renders");
      assert.ok(!state.includes("runway-card"), "the runway is suppressed on the past-due path");
      const grid = (reg.get("overview-instances") || {}).innerHTML || "";
      assert.ok(grid.includes("suspended-card-banner"), "the suspended box carries the GR17 card banner");
      assert.ok(grid.includes("The server is stopped, not destroyed"), "the suspended-card body renders verbatim");
      assert.ok(!grid.includes("suspended — not deleted"), "trial-expiry copy never leaks onto the suspended card");
    },
  },
  // ── gr-p3 D-01: the v4 Fleet list + Archives (screens/01) ──────────────────
  "fleet-v4": {
    what: "v4 fleet rows (leading pill, mono meta, the update chip on the behind box) + archives storage-unconfigured",
    check(reg) {
      const body = (reg.get("fleet-body") || {}).innerHTML || "";
      assert.ok(body.includes('class="fleet-row"'), "the fleet rows render");
      assert.ok(body.includes('class="fleet-status"'), "the lifecycle pill leads its own column");
      assert.ok(body.includes('class="fleet-meta"'), "the mono metadata line renders");
      assert.ok(body.includes("fsn1 · cx32 · v0.1.0"), "the metadata is backend-true (region · size · version)");
      assert.ok(body.includes("fleet-update-chip--ready"), "the behind box carries the update chip");
      assert.ok(body.includes("v0.2.25 available"), "the chip names the real target release");
      assert.ok(!body.includes("Update available"), "the update signal is the chip, never a doubled pill");
      assert.ok(body.includes("provider-chip--hetzner") && body.includes("provider-chip--azure"), "provider marks render per row");
      const arch = (reg.get("archives-body") || {}).innerHTML || "";
      assert.ok(arch.includes("archives-note--unconfigured"), "archives shows the DISTINCT storage-unconfigured state");
      assert.ok(arch.includes("Archive storage isn"), "the server's not_configured copy renders verbatim");
      // gr-blk-archives-doc-link: the "How archives work" anchor pointed at the
      // bare repo root — nothing in the repo answers the question, so the
      // affordance became the answer itself rather than a relocated dead end.
      assert.ok(arch.includes("archives-note-sub"), "the in-place explanation renders");
      assert.ok(!arch.includes("github.com"), "and no invented docs URL took its place");
      assert.ok(arch.includes("data-archives-retry"), "a working Retry renders");
    },
  },
  // ── cch-w21-s3 (REVIEW ADDITION): the cruel fixture's expectation.
  // The slice committed `fleet-cruel-content` and taught breakpoint-sweep about
  // it, but not this file — and smoke's census guard is two-way, so the whole
  // harness step exited 1 with "1 committed scenario(s) have NO expectation and
  // were never run". That refusal is correct and it is the epic's own law: a
  // fixture nothing asserts on is a green that means nothing. So the fixture
  // gets a real expectation, and every string below is DERIVED FROM THE FIXTURE
  // rather than typed — a corpus edit that quietly shortens the cruel content
  // reds here instead of passing on a stale literal.
  "fleet-cruel-content": {
    what: "server-legal worst-case CONTENT on the fleet table — a 253-char custom domain, a 255-char name and a 512-char single-token provision error, all rendered beside a KIND neighbour in the same DOM",
    check(reg) {
      const rows = SCENARIOS["fleet-cruel-content"].data.barkparks;
      const cruel = rows.find((b) => b.custom_host && b.custom_host.length > 200);
      // cch-w23 REVIEW: the kind neighbour is picked by what makes it KIND — it
      // renders a short address of its own — not by "whatever is not the cruel
      // row". cch-w23-s1 added a THIRD row to this fixture (a failed box with a
      // 512-char single-token provision error and NO host), and a positional
      // `find(b => b !== cruel)` silently returned THAT one: `kind.host` went
      // undefined and `body.includes(undefined)` failed the whole harness step.
      // A selector that cannot say what it is selecting for is this epic's own
      // fifth clause pointed at an oracle.
      const kind = rows.find((b) => b !== cruel && b.host);
      // The single-token row is asserted on its own terms below rather than
      // being tolerated as "some other row".
      const tokenRow = rows.find((b) => b.provision_error && b.provision_error.length > 200);
      assert.ok(cruel, "the fixture still carries a cruel row (a >200-char custom_host)");
      assert.ok(kind, "the cruel row keeps a KIND neighbour — a bound that fixes one by shredding the other must be visible in the same DOM");
      assert.equal(cruel.custom_host.length, 253, "the host sits AT the server's validate_length cap (registry/barkpark.ex:727)");
      assert.equal(cruel.name.length, 255, "the name sits AT the server's cap (registry/barkpark.ex:466)");
      assert.ok(
        cruel.custom_host.split(".").some((l) => l.length === 63),
        "at least one MAXIMAL 63-char DNS label — a hyphen is a line-break opportunity, so a hyphen-rich host is not cruel at all",
      );
      const body = (reg.get("fleet-body") || {}).innerHTML || "";
      assert.ok(body.includes('class="fleet-row"'), "the fleet rows render");
      // publicUrl() PREFERS custom_host, so the CRUEL host is what the row paints.
      assert.ok(body.includes(cruel.custom_host), "the row renders the custom domain, not the barkpark.cloud fallback");
      // The fixture name carries no HTML-escapable character, so it renders verbatim;
      // this assertion also pins that (an escape would break the substring match).
      assert.ok(!/[&<>"]/.test(cruel.name), "the cruel name stays free of escapable characters, so it renders verbatim");
      assert.ok(body.includes(cruel.name), "the row renders the full 255-char name");
      assert.ok(body.includes(kind.host), "the kind neighbour still renders its own short address in the same table");
      assert.ok(countMatches(body, 'class="fleet-row"') >= 2, "both rows render — one of them alone proves nothing about the other");
      // cch-w23-s1's SHAPE axis: a machine-written error with no break
      // opportunity, painted verbatim into the status pill's detail. Derived
      // from the fixture, never typed, so a corpus edit that shortens or breaks
      // the token reds here instead of passing on a stale literal.
      if (tokenRow) {
        assert.ok(
          !/[\s\-./]/.test(tokenRow.provision_error),
          "the provision error stays a SINGLE UNBROKEN TOKEN — a space, hyphen, slash or dot is a line-break opportunity, and a breakable string wraps by itself",
        );
        assert.ok(body.includes(tokenRow.provision_error), "the failed row paints the provision error verbatim into its status-pill detail");
        assert.ok(countMatches(body, 'class="fleet-row"') >= 3, "all three rows render — the cruel host, the single-token error and the kind neighbour in ONE DOM");
      }
    },
  },
  "fleet-archives-stored": {
    what: "the Archives panel lists portable bundles, each with a per-provider resurrect",
    check(reg) {
      const arch = (reg.get("archives-body") || {}).innerHTML || "";
      assert.ok(arch.includes("archive-list"), "the populated archive list renders");
      assert.ok(countMatches(arch, 'class="archive-row"') >= 2, "one row per bundle");
      assert.ok(arch.includes("shop-9f2c1"), "a bundle is named by its fqdn");
      assert.ok(arch.includes("archive-resurrect-btn"), "each row offers Resurrect");
      assert.ok(!arch.includes("archives-note--unconfigured"), "a configured store never shows the unconfigured state");
    },
  },

  // ── gr-p3 instance workspace (GR24/GR30): D-02 header + D-03 Overview ──────
  // The scenario predates this wave with a fixture but ZERO assertions (the
  // GR30 vacuous-green finding) — these are its first EXPECTATIONS.
  "panel-overview": {
    what: "the v4 instance workspace: two-axis header, bp CLI card, composed Overview — AND a real typed Decommission that tears the instance out of the SERVER's fleet",
    async check(reg, hooks, ctx) {
      const body = reg.get("instance-body").innerHTML || "";
      // D-02 header: H1 + the two-axis compound pill + mono address + copy.
      assert.ok(body.includes("detail-head--inst"), "the v4 header renders");
      assert.ok(body.includes("status-pill-label"), "the compound pill renders its label axis");
      assert.ok(body.includes('data-copy="production-5b2c1e.barkpark.cloud"'), "the address carries the copy affordance");
      assert.ok(body.includes('id="inst-open-studio"'), "Open Studio is the primary action");
      assert.ok(body.includes('id="inst-cli-toggle"'), "the bp CLI disclosure renders");
      assert.ok(body.includes('aria-controls="inst-lifecycle-actions"'), "the disclosure points at the card slot");
      // D-03 Overview: one composed pass — updates card, Sites card, card rail.
      assert.ok(body.includes("update-panel"), "the updates card renders");
      assert.ok(body.includes("inst-sites-card"), "the Sites card renders");
      assert.ok(body.includes("detail-rail--cards"), "the rail renders as cards");
      for (const label of ["Identity", "Runtime", "Platform", "Activity"]) {
        assert.ok(body.includes('rail-group-label">' + label + "<"), "rail card " + label + " renders");
      }
      assert.ok(body.includes('id="instance-domains"'), "the domain-checklist slot renders (component consumed as-is)");
      assert.ok(body.includes('id="instance-tabpanel"'), "the tab panel pin holds");
      // The bp CLI card paints into its slot from the capabilities conduit:
      // 4 copyable commands, the SERVER-OWNED pause sentence, Decommission….
      const card = reg.get("inst-lifecycle-actions").innerHTML || "";
      assert.ok(card.includes("Manage this instance via the bp CLI"), "the CLI card head renders");
      for (const verb of ["archive", "resurrect", "adopt", "audit"]) {
        assert.ok(card.includes("bp cloud instance " + verb + " Production"), "the " + verb + " command chip renders");
      }
      assert.ok(card.includes("a stopped server still bills"), "the foot renders the conduit's own pause sentence");
      assert.ok(card.includes('data-life-verb="decommission"'), "the typed-confirm Decommission anchors the foot");
      // The golden-path verify card fills its slot off the events feed
      // (no verify event in the fixture → the honest never-run invite).
      const vf = reg.get("instance-verify").innerHTML || "";
      assert.ok(vf.includes("vf-card"), "the golden-path card renders");
      assert.ok(vf.includes("Golden path"), "the card heading renders");
      assert.ok(vf.includes("Run first check"), "the never-run state invites the first check");
      // Sites slot resolves to the honest empty state (fixture has no sites).
      const sites = reg.get("instance-sites").innerHTML || "";
      assert.ok(sites.includes("No sites yet"), "the Sites empty state renders");

      // ── cch-w10 LEG 5/5: DECOMMISSION, CLICKED FOR REAL ───────────────────
      // THIS LEG'S ORACLE HAS A DIFFERENT SHAPE FROM THE OTHER FOUR, and the
      // difference is not cosmetic. runDecommission drops fleetCache and sets
      // location.hash = "#fleet" — it NAVIGATES AWAY rather than refetching the
      // surface, so there is no repainted list to count. A UI row count here
      // would either assert a stale panel (green forever) or a panel the shim's
      // inert location never re-routes (red forever). The only honest oracle is
      // the SERVER's own list, read straight off the state bag.
      //
      // DELETE /v1/barkparks/:id was UNMODELLED until this wave: it fell through
      // the terminal `/v1/` 200 {} catch-all, so the console's most destructive
      // verb succeeded against a fixture that never lost anything.
      const bp = SCENARIOS["panel-overview"].data.barkparks[0];
      assert.equal(ctx.state.barkparks.length, 1, "the fleet starts at one instance");
      const cardEl = reg.get("inst-lifecycle-actions");
      const decomm = cardEl.querySelectorAll('[data-life-verb="decommission"]');
      assert.equal(decomm.length, 1,
        "the CLI card must carry exactly one wired Decommission; got " + decomm.length +
        " — 0 means the shim's attribute selector regressed and this leg proves nothing");
      assert.equal(decomm[0].click(), 1, "Decommission dispatched no click handler — it is DEAD");
      const bpPath = "/v1/barkparks/" + bp.id;
      assert.equal(ctx.countCalls("DELETE", bpPath), 0,
        "Decommission tore down the server on the row click — the typed-confirm gate is gone");
      assertDestroySheetDisarmed(reg, "Decommission");
      reg.get("cm-confirm").click();
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", bpPath), 0,
        "an UNARMED destroy Confirm tore down a live server");
      assert.equal(ctx.state.barkparks.length, 1, "and nothing left the fleet while it was unarmed");

      armConfirmSheet(reg, bp.name).click();
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", bpPath), 1, "the armed Confirm must issue exactly one teardown");
      assert.equal(ctx.state.barkparks.length, 0,
        "the SERVER's fleet must shrink by exactly one (1 → 0); got " + ctx.state.barkparks.length +
        " — an unchanged fleet means the teardown hit the catch-all and did nothing");
      const fleetAfter = route("panel-overview", "GET", "/v1/barkparks", ctx.state);
      assert.equal(fleetAfter.body.barkparks.length, 0,
        "and a fresh fleet READ agrees — the shrink is served, not just spliced into a bag nobody reads");
      const decomToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(decomToast.includes("Decommissioning " + bp.name) && decomToast.includes("is gone"),
        "the teardown must report itself, with the server's own 200-vs-202 distinction; got: " + decomToast.slice(0, 200));
    },
  },

  // ── gr-p3 D-04: the timeline coalescing grammar (tail-append, OC9) ──────────
  "timeline-coalesced": {
    what: "the coalescing grammar folds the health burst to ONE worst-verdict row with Show all/Collapse",
    check(reg, hooks) {
      // Routing: the deep link lands the Timeline tab exactly like the other
      // C8 states (the strip is the shim-observable half of the mount).
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.includes('/timeline" aria-current="page"'), "the Timeline tab must be current");
      assert.ok(body.includes('id="instance-tabpanel"'), "the tabpanel must render");
      // The feed itself paints through element-level querySelector (inert in
      // this shim), so drive the SAME pure pipeline loadTimeline runs —
      // mergeTimeline → coalesceEntries → timelineFeedHtml — over this
      // scenario's committed fixture, and pin the §07 grammar end-to-end.
      const d = SCENARIOS["timeline-coalesced"].data;
      const events = Object.values(d.instanceEvents)[0];
      const entries = hooks.mergeTimeline(events, d.audit);
      const closed = hooks.timelineFeedHtml(entries, {});
      assert.equal(countMatches(closed, 'class="tlv-row tlv-coalesce"'), 1, "the 10-beat burst folds to ONE row");
      assert.ok(closed.includes("Health report"), "the group names its kind");
      assert.ok(closed.includes("&times; 10"), "the × N count renders");
      assert.ok(closed.includes("all reporting health: down"), "the WORST verdict is stated");
      assert.ok(/every ~1m for \d+m/.test(closed), "the cadence segment renders from the members' stamps");
      assert.ok(closed.includes(">Show all 10<"), "the expand affordance renders");
      assert.ok(!closed.includes("tlv-coalesce-members"), "members stay out of the DOM while collapsed");
      assert.ok(closed.includes("Status → offline"), "the singleton status row still renders enriched");
      // Expanded state: Collapse + every member row on the inset rail.
      const gkey = (closed.match(/data-tlv-group="([^"]+)"/) || [])[1];
      assert.ok(gkey, "the group carries its stable key");
      const open = hooks.timelineFeedHtml(entries, { openGroups: [gkey] });
      assert.ok(open.includes('aria-expanded="true">Collapse<'), "the open group offers Collapse");
      assert.ok(open.includes("tlv-coalesce-members"), "the member rail renders");
      assert.equal(countMatches(open, 'data-tlv-key="'), 14, "10 members + status + tls + the 2 audit rows all render");
    },
  },

  // ── D-05 (tail-append, OC9): the v4 Webhooks auto-disabled state ────────────
  // The endpoint list renders the auto-disabled endpoint's COUNT-FREE banner with
  // a Re-enable action (the deliveries card + real-response replay are click-driven
  // → inert here, so unit-pinned in __app.test.mjs). The banner must carry the
  // server reason verbatim but NO client-authored failure count.
  "webhooks-autodisabled": {
    what: "the auto-disabled endpoint's count-free banner + Re-enable render in the list",
    check(reg) {
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel webhook list rendered empty");
      assert.ok(panel.includes('class="wh-card"'), "the endpoint list must render webhook cards");
      assert.ok(panel.includes("wh-autodisable"), "the auto-disabled banner renders");
      assert.ok(panel.includes("Auto-disabled"), "the banner leads with the Auto-disabled label");
      assert.ok(panel.includes("endpoint returned 500 Internal Server Error"), "the server disable_reason renders verbatim");
      assert.ok(panel.includes("data-wh-reenable"), "the banner offers Re-enable (the one recovery action)");
      assert.ok(!panel.includes("wh-autodisable-count"), "count-free: no client-authored failure count span");
      assert.ok(!panel.includes("20 consecutive failures"), "count-free: the live-config threshold never leaks into the banner copy");
    },
  },

  // ── D-06+D-07 Usage + Metrics in v4 (GR27/GR28): the metrics scenario existed
  // with ZERO smoke EXPECTATIONS (GR30) — these assert all three beat states plus
  // the dashed request-level stubs, and pin the GR28 warmup fiction OUT of every
  // state. mountMetricsTab re-acquires its swap box the mountUsageTab way
  // (`.metrics-body || panel`), so the grid lands in the OBSERVABLE
  // #instance-tabpanel here. (tail-append, OC9.) ──────────────────────────────
  metrics: {
    what: "the Metrics tab routes and fills all 4 live vitals + the dashed not-yet-metered stubs (no warmup fiction)",
    check(reg) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      for (const needle of ["inst-tabs", '/metrics" aria-current="page"', 'id="instance-tabpanel"', ">Metrics<"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel metrics panel rendered empty");
      // GR27: all four vitals plot as cards (design showed only CPU/RAM).
      assert.ok(panel.includes('class="metrics-grid"'), "the vitals grid renders");
      for (const label of [">CPU<", ">Memory<", ">Disk<", ">Load<"]) {
        assert.ok(panel.includes(label), "the vitals grid renders " + JSON.stringify(label));
      }
      assert.ok(panel.includes("<svg"), "a live vital draws its sparkline");
      // D-07: the dashed request-level stubs, honestly not-yet-metered.
      assert.ok(panel.includes('class="metrics-stubs"'), "the request-level stubs render beneath the vitals");
      for (const label of [">Req/s<", ">p95 latency<", ">API requests<"]) {
        assert.ok(panel.includes(label), "the stub renders " + JSON.stringify(label));
      }
      assert.ok(panel.includes("Not yet metered"), "a stub reads Not yet metered, never a fake number");
      // The live beat banner reads Live (not the stale skin).
      assert.ok(panel.includes('class="metrics-fresh'), "the live beat renders the fresh banner");
      // GR28 kill list: the 24h-warmup fiction never crosses into the build.
      assert.ok(!/warming up|24h|24 h|of 24|unlock|collected/i.test(panel), "no warmup fiction in the live panel");
    },
  },
  "metrics-stale": {
    what: "the Metrics tab stale beat — last-known vitals flagged Agent offline, stubs still present",
    check(reg) {
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.includes('class="metrics-stale"'), "the stale banner renders");
      assert.ok(panel.includes("Agent offline"), "the stale banner reads Agent offline");
      assert.ok(panel.includes("last seen "), "the stale banner carries the last-seen age");
      // A stale read STILL shows the last-known series (history, not blank).
      assert.ok(panel.includes('class="metrics-grid"'), "the last-known vitals still render on a stale beat");
      assert.ok(panel.includes('class="metrics-stubs"'), "the stubs still render on a stale beat");
      assert.ok(!/warming up|24h|24 h|of 24|unlock|collected/i.test(panel), "no warmup fiction in the stale panel");
    },
  },
  "metrics-absent": {
    what: "the Metrics tab absent beat — the honest waiting panel, never a zeroed chart or a fake stub",
    check(reg) {
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.includes("Waiting for the first beat"), "the absent state shows the honest waiting panel");
      assert.ok(!panel.includes('class="metrics-grid"'), "no zeroed vitals grid in the absent state");
      assert.ok(!panel.includes('class="metrics-stubs"'), "no request-level stubs in the absent state");
      assert.ok(panel.indexOf("<svg") === -1, "no fabricated chart in the absent state");
    },
  },
  // gr-p3-site-detail (E-02): the states-complete v4 ladder + previews + the
  // domains rungs painted by the SITE domain-status mount.
  "site-states": {
    what: "v4 site detail — every settled ladder state, trigger-only provenance, previews, domains rungs",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      // States-complete: live current / crash / blocked / cancelled pills.
      assert.ok(body.includes("dep-pill dep-live"), "live pill renders");
      assert.ok(body.includes("dep-pill dep-failed"), "failed pill renders");
      assert.ok(body.includes("dep-pill dep-cancelled"), "cancelled pill renders");
      assert.ok(body.includes("dep-current"), "the Now-live chip marks the current row");
      assert.ok(body.includes(">Roll back to this<"), "the prior live row offers rollback");
      // The v4 failure panels: crash red + blocked amber, dot included.
      assert.ok(body.includes("deploy-fail-dot"), "the failure panel carries its dot");
      assert.ok(body.includes("deploy-fail--blocked"), "the born-failed github push reads blocked amber");
      assert.ok(body.includes("npm run build exited 1"), "the crash reason renders verbatim");
      // GR27 provenance: trigger words only, never a named human.
      assert.ok(body.includes("Content update"), "content-auto renders as Content update");
      assert.ok(body.includes("Manual"), "manual renders as Manual");
      // Previews section: one live + one failed branch row.
      assert.ok(body.includes("Branch previews"), "the previews section renders");
      assert.ok(body.includes("preview-row"), "preview rows render");
      assert.ok(body.includes("draft/nav"), "the live preview names its branch");
      // The domains mount slot is in the detail markup…
      assert.ok(body.includes('id="site-domains"'), "the domains mount slot renders");
      // …and the SITE domain-status fetch painted the v4 rungs into it.
      const domains = (reg.get("site-domains") || {}).innerHTML || "";
      assert.ok(domains.includes("dom-card"), "the domain host card renders");
      assert.ok(domains.includes("acme.com"), "the apex host renders");
      assert.ok(domains.includes("dom-rung--proxied"), "the proxied rung renders informationally");
      assert.ok(domains.includes("dom-rung--active"), "the front in-flight rung shows honest motion");
      assert.ok(domains.includes("certificate usually issues"), "the server remediation renders verbatim");
    },
  },
  // ── ssw8 (charter D82): the content binding, PAINTED ────────────────────────
  // scenarios.mjs gained three binding fixtures; without an EXPECTATIONS entry
  // this harness never renders them (it iterates Object.keys(EXPECTATIONS), not
  // SCENARIOS), so they would be asserted only by the node string harness and
  // never by a boot. These three walk the real render into #site-body.
  "site-binding-bound": {
    what: "site detail — a bound site: the dataset triple on the rail and a read-token pill that promises only what content_bound means",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      assert.ok(body.includes("acme/site/production"), "the rail names the dataset triple the build reads");
      assert.ok(body.includes(">paper<"), "the bound content type renders");
      assert.ok(body.includes("status-pill--ok"), "a stored read token reads as an ok pill");
      assert.ok(body.includes(">Read token stored<"), "the pill says READ TOKEN…");
      assert.ok(!/has content|is bound</i.test(body),
        "…and never claims the site HAS content — content_bound is not_is_nil(read_token_encrypted)");
    },
  },
  "site-binding-unknown": {
    what: "site detail — an older control plane sends no triple and no content_bound; the rail says unknown, never a plausible default",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      assert.ok(body.includes(">Binding unknown<"), "an absent binding reads UNKNOWN");
      assert.ok(body.includes("status-pill--neutral"), "unknown is neutral — not a green, not a red");
      // THE lie this fixture exists to catch: nothing may invent the documented
      // defaults for a payload that carries none of them.
      assert.ok(!body.includes("default/default/production"),
        "an absent triple must never render the plausible default");
    },
  },
  "site-binding-mismatch": {
    what: "site detail — the payload's two spellings of the dataset disagree; both render and neither is resolved",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      assert.ok(body.includes("producton") && body.includes("production"),
        "a self-contradictory payload shows BOTH spellings");
      assert.ok(body.includes(">Binding mismatch<"), "and names the contradiction");
      assert.ok(body.includes("status-pill--danger"), "a contradiction is a danger state, not a shrug");
    },
  },
  // gr-p3-small-surfaces (E-01): the global sites list on v4 — one density row
  // per site with a leading deploy-status pill, states-complete, real fields
  // ONLY (the invented Marketing/Docs/Blank "kind" taxonomy never renders).
  sites: {
    what: "v4 sites list — deploy-status pills (live/rebuilding/failed/never), real fields, no invented kinds",
    check(reg) {
      const body = (reg.get("sites-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#sites-body rendered empty");
      // Exactly one v4 global row per fixture site. cch-w16-s4 grew the corpus
      // from 5 to 6 (the first preview-only site).
      assert.equal(countMatches(body, 'class="site-row site-row--global"'), 6,
        "one v4 density row per fixture site");
      // cch-w16-s4 — THE CONTRADICTION, ASSERTED PER ROW, NOT PER PAGE. A page
      // total can be satisfied by the wrong four rows; this splits the list on
      // its own row head and reads each row's own two claims.
      const rows = body.split('<div class="site-row').slice(1);
      assert.equal(rows.length, 6, "the split found every row");
      const undeployed = rows.filter((r) => r.includes(">Not deployed<"));
      assert.equal(undeployed.length, 2,
        "acme-labs (never deployed) and acme-previews (preview-only) both say so");
      for (const r of undeployed) {
        assert.ok(!r.includes("site-open"),
          "a row that says Not deployed offers NO door: " + (r.match(/site-name">([^<]*)/) || [])[1]);
      }
      const deployed = rows.filter((r) => !r.includes(">Not deployed<"));
      assert.equal(deployed.length, 4, "four rows have served a build");
      for (const r of deployed) {
        // …AND THE OTHER DIRECTION: rebuilding and deploy-failed rows are still
        // SERVING their previous build, so stripping their door would be the
        // same defect mirrored. This is the assertion `last_deployment.status
        // === "live"` would have failed.
        assert.ok(r.includes('class="site-open"'),
          "a site that has served a build KEEPS its door: " + (r.match(/site-name">([^<]*)/) || [])[1]);
      }
      assert.equal(countMatches(body, 'title="Open the live site"'), 4,
        "exactly four live-site doors on the page");
      // The leading status pill, states-complete across the four rows.
      assert.ok(body.includes("status-pill--ok"), "the live site reads an ok pill");
      assert.ok(body.includes("status-pill--warn"), "the rebuilding site reads a warn pill");
      assert.ok(body.includes("status-pill--danger"), "the deploy-failed site reads a danger pill");
      assert.ok(body.includes("status-pill--neutral"), "the never-deployed site reads a neutral pill");
      assert.ok(body.includes(">Not deployed<"), "a never-deployed site says so — no invented green");
      // cch-w14-s6: the cancelled freshness label #8608 shipped, rendered by a
      // harness for the first time — one spelling ("Cancelled", not "Canceled"),
      // on a neutral pill (a cancel is neither a success nor a failure).
      assert.ok(body.includes(">Cancelled<"), "a cancelled deploy says Cancelled — one spelling of the deploy noun");
      assert.ok(!body.includes(">Canceled<"), "never the American spelling for the DEPLOY noun");
      // Real fields: the site's OWN name, its host, framework, the instance link,
      // and a recency segment.
      assert.ok(body.includes(">acme-web<"), "the site's real name renders");
      assert.ok(body.includes('class="site-host"'), "the live host renders on its own line");
      assert.ok(body.includes("acme.com"), "the host value renders");
      assert.ok(body.includes(">nextjs "), "the framework renders in the meta line");
      assert.ok(body.includes('class="site-inst-link" href="#instance/'), "on <instance> is a real workspace link");
      assert.ok(body.includes("updated "), "the recency segment renders");
      assert.ok(body.includes("Auto-deploy") && body.includes("Manual"),
        "the auto-deploy capability chip renders both states");
      // GR28 kill list: the invented site-kind taxonomy never crosses in.
      assert.ok(!/\bMarketing\b|\bDocs\b|\bBlank\b|template picker|site-kind/i.test(body),
        "no invented Marketing/Docs/Blank kind taxonomy in the sites list");
    },
  },
  // cch-w16-s4: the OTHER row builder. `siteRow` paints the instance
  // workspace's Sites card, and it has NO status pill at all for a
  // never-deployed site (freshnessBadge returns "") — so the contradiction was
  // SILENT here rather than spelled out, and an absence-only guard on an empty
  // fixture would have passed for the wrong reason. This drives the SAME six
  // rows through it and asserts BOTH directions.
  "sites-on-instance": {
    what: "instance Sites card — siteRow keeps the door on four served sites and removes it from the two that never served",
    check(reg) {
      const body = (reg.get("instance-sites") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-sites rendered empty");
      const rows = body.split('<div class="site-row').slice(1);
      assert.equal(rows.length, 6, "one instance row per fixture site");
      assert.equal(countMatches(body, 'class="site-open"'), 4,
        "four doors: the two that never served a build get none");
      // Named, so a fixture reshuffle cannot silently move the gate.
      const rowOf = (name) => rows.filter((r) => r.includes(">" + name + "<"))[0];
      for (const name of ["acme-labs", "acme-previews"]) {
        const r = rowOf(name);
        assert.ok(r, name + " renders a row");
        assert.ok(!r.includes("site-open"), name + " has never served a build — no door");
      }
      for (const name of ["acme.com", "blog.acme.com", "shop.acme.com", "guides.acme.com"]) {
        const r = rowOf(name);
        assert.ok(r, name + " renders a row");
        assert.ok(r.includes('class="site-open"'), name + " has served a build — the door stays");
      }
    },
  },
  // gr-p3-small-surfaces (E-03): the write-only env editor. The site detail
  // carries the Edit-environment affordance; the modal body (opened behind a
  // click, inert here) is pinned through the pure envModalBodyHtml hook.
  "env-editor": {
    what: "site detail Edit-env affordance + the write-only, blank-start modal (no scope UI, no redeploy claim)",
    check(reg, hooks) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      // The rail affordance renders — an Edit action, NO stored values/count
      // (write-only: reveal_site_env has zero route callers).
      assert.ok(body.includes(">Environment<"), "the Environment rail row renders");
      assert.ok(body.includes('id="site-env-edit"'), "the Edit-environment affordance renders");
      // Drive the pure modal body — the same hook seam the 2FA card uses.
      assert.ok(hooks && typeof hooks.envModalBodyHtml === "function",
        "the env modal body must be exported through __bpTestHook");
      const modal = hooks.envModalBodyHtml({ name: "acme-web" });
      assert.ok(modal.includes("Edit environment"), "the modal titles itself");
      // The write-only law, verbatim.
      assert.ok(modal.includes("Saving replaces the whole set — values are write-only, so anything you leave out is removed."),
        "the replace-set / write-only law renders verbatim");
      assert.ok(modal.includes("Current values can’t be read back."), "the no-read-back law renders verbatim");
      // The textarea starts BLANK (GR28 — never pre-filled; no read-back).
      const ta = modal.match(/<textarea[^>]*id="site-env-text"[^>]*>([\s\S]*?)<\/textarea>/);
      assert.ok(ta, "the KEY=VALUE textarea renders");
      assert.equal(ta[1], "", "the textarea starts blank — there is no read-back to pre-fill");
      // Backend-true button copy: "Replace env", never "…and redeploy" (the
      // route queues no deployment).
      assert.ok(modal.includes(">Replace env</button>"), "the submit says Replace env");
      assert.ok(!/redeploy/i.test(modal), "no redeploy is claimed — the route queues none");
      // GR27: no production/preview scope UI (one blob).
      assert.ok(!/\bpreview\b|\bproduction scope\b|scope/i.test(modal), "no invented env scopes");
    },
  },
  // gr-p3-small-surfaces (I-01): the team Activity feed regrown on the shared
  // coalescing grammar with the by-target key + backend-true filter chips.
  activity: {
    what: "v4 activity — coalesced by target (×3 group, unrelated targets stay split), server-true target_type chips",
    check(reg) {
      const filters = (reg.get("activity-filters") || {}).innerHTML || "";
      // Backend-true filter chips: the two customer nouns + All. NO actor/verb
      // filter (the server has no such params).
      assert.ok(filters.includes('data-actfilter=""'), "the All chip renders");
      assert.ok(filters.includes('data-actfilter="barkpark"'), "the Instances chip maps to target_type=barkpark");
      assert.ok(filters.includes('data-actfilter="site"'), "the Sites chip maps to target_type=site");
      assert.ok(filters.includes("is-active"), "one chip is active (All by default)");
      const body = (reg.get("activity-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#activity-body rendered empty");
      // The feed renders through the SHARED grammar (tlv-* rows).
      assert.ok(body.includes("tlv-row"), "the feed renders through the shared timeline grammar");
      // The three same-site deploys fold into ONE ×3 coalesced group…
      assert.ok(body.includes("tlv-coalesce"), "the repeated same-target run coalesces");
      assert.ok(body.includes("&times; 3") || body.includes("× 3"), "the group states its count (×3)");
      assert.ok(body.includes("Show all 3"), "the group offers an expand affordance");
      // …but the DIFFERENT-target deploy (bob, acme-blog) is NOT folded in — a
      // team feed never merges unrelated targets. Exactly ONE coalesced group.
      assert.equal(countMatches(body, 'data-tlv-group="'), 1, "only the same-target run folds — unrelated targets stay split");
      // Actor display is backend-true (audit carries actor.email).
      assert.ok(body.includes("ada@acme.com"), "the actor email renders from the audit row");
      assert.ok(body.includes("bob@acme.com"), "the second actor's singleton renders separately");
      // The keyset Load-more control survives the regrow.
      assert.ok(reg.get("activity-more"), "the Load more control still mounts");
    },
  },

  // ── gr-p4-billing (G-01): plain-member gate + the post-cancel grace state ────
  "billing-member": {
    what: "a plain member of a paid team — read-only plan, the owner-gate copy, and NO billing write button anywhere",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // The plan STATE reads honestly (real name + real ceiling) …
      assert.ok(box.includes(">Supporter<"), "the member sees the real plan name");
      assert.ok(box.includes("3 managed instances"), "the member sees the real quota-honest ceiling");
      // … but with ZERO write affordances — never a disabled ghost (GR36).
      assert.ok(!/<button/i.test(box), "the read-only plan card renders NO button");
      assert.ok(!box.includes("plan-more") && !box.includes("plan-continue"), "no grid-toggle / subscribe CTA for a member");
      assert.equal(reg.get("billing-tiers").hidden, true, "the plan grid stays closed for a member");
      // The honest owner-gate copy is the member's single explanation.
      const manage = reg.get("billing-manage").innerHTML || "";
      assert.ok(manage.includes("Only the team owner can manage billing."), "the honest owner-gate copy renders");
      assert.ok(!/<button/i.test(manage), "the Manage section shows NO button for a member");
      // The pin that PROVES the member view has no billing write button: neither
      // section carries a Manage/Cancel action, and Cancel is retired entirely.
      assert.ok(!manage.includes(">Manage billing<"), "no Manage-billing button for a member");
      assert.equal(reg.get("billing-cancel-section").hidden, true, "no Cancel section for a member");
    },
  },
  "billing-cancelling": {
    what: "owner after an in-app cancel — the grace 'Access until' + Ending badge, Cancel section retired, Manage billing kept",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // The plan card reads the grace end honestly via billingPeriodLine.
      assert.ok(box.includes("Access until "), "a cancelling plan reads Access-until the period end");
      assert.ok(box.includes(">Ending<"), "the status badge reads Ending");
      // Manage billing stays available (resubscribe / portal) …
      assert.ok((reg.get("billing-manage").innerHTML || "").includes(">Manage billing<"), "Manage billing stays for the owner");
      assert.equal(reg.get("billing-manage-section").hidden, false, "the Manage section stays shown");
      // … but the Cancel section is GONE — a second cancel is a no-op.
      assert.equal(reg.get("billing-cancel-section").hidden, true, "the Cancel section retires once cancel_at_period_end is set");
    },
  },
  // ── gr-p4 G-02+G-03 Providers — the honesty flagship ───────────────────────
  // roster (kind + label + connected-at, no implied validity) + the hybrid
  // connect card + the 9-verb capability matrix (dev-tier filtered, server-owned
  // gap reasons, bare dash where the server owns no reason).
  "providers-connected": {
    what: "the roster (2 kinds, Disconnect…), the ROTATION state, the honest matrix — AND a real Disconnect click that arms the typed gate and shrinks the SERVER roster 2→1",
    async check(reg, hooks, ctx) {
      const roster = (reg.get("provider-roster") || {}).innerHTML || "";
      assert.ok(roster.includes("set-section"), "the roster rides the .set-* anatomy");
      assert.ok(roster.includes("prov-roster") && roster.includes("prov-row"), "roster rows render");
      assert.ok(roster.includes("Hetzner") && roster.includes("Azure"), "both connected kinds render");
      assert.ok(roster.includes("connected "), "each row shows a connected-at (never a validity badge)");
      assert.ok(!/\bConnected<\/span>/.test(roster), "the roster never implies live validity");
      assert.ok(roster.includes("data-prov-disconnect"), "an admin roster carries the typed-confirm Disconnect");

      // Both connectable providers are already connected → the connect card is in
      // the ROTATION state: a connected kind stays armable and its submit replaces
      // the stored credential in place (GR44 upsert on (team_id,kind), executed by
      // gr-bl-provider-reconnect-client-guard). It must NEVER tell the operator to
      // destroy a working credential first.
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(connect.includes("set-section") && connect.includes("Connect a provider"), "the connect card renders");
      assert.ok(connect.includes("data-connect-submit"), "a connected kind can still be re-submitted (rotation)");
      assert.ok(connect.includes("data-connect-rotating"), "the card says it is REPLACING the stored credential");
      assert.ok(connect.includes("Verify &amp; replace"), "the verb reads replace, not connect");
      assert.ok(!connect.includes("Disconnect one above"), "the destroy-first instruction is gone");
      assert.ok(!/data-connect-kind="[a-z]+"[^>]*disabled/.test(connect), "no connected kind is a disabled ghost");

      const matrix = (reg.get("provider-matrix") || {}).innerHTML || "";
      assert.ok(matrix.includes("cap-matrix"), "the capability matrix renders");
      for (const verb of ["core", "catalog", "archive", "resurrect", "decommission", "adopt", "audit", "pause", "labels"]) {
        assert.ok(matrix.includes(">" + verb + "<"), "the matrix rows verb " + JSON.stringify(verb));
      }
      assert.ok(matrix.includes("cap-mark"), "a supported cell shows an affirmative mark");
      assert.ok(matrix.includes("cap-dash"), "an unsupported cell shows a dash");
      assert.ok(matrix.includes("Hetzner has no pause primitive"), "a false cell carries the server-owned gap reason verbatim");
      assert.ok(matrix.includes("Adopt needs an existing resource-group import"), "the azure adopt gap renders verbatim");
      // dev-tier `fake` is FILTERED — it is never a matrix column.
      assert.ok(!matrix.includes(">Fake<"), "the dev-tier provider is filtered out of the matrix");

      // ── cch-w10 LEG 1/5: DISCONNECT, CLICKED FOR REAL ─────────────────────
      // AMENDED IN PLACE, never forked (the cch-w2-revoke-ux-honesty precedent):
      // a parallel "providers-disconnect" scenario would duplicate the fixture
      // and leave two places to keep true. Everything above reads the FIRST
      // paint; everything below happens after it, on the same one boot — which
      // is also what keeps the handler count honest (a re-opened surface
      // accumulates handlers on the immortal #id registry nodes, so `fired == 1`
      // is only safe on a surface opened ONCE).
      //
      // Until this wave `[data-prov-disconnect]` resolved to [] — the wiring
      // loop ran over nothing, and a loop over nothing passes.
      const rosterEl = reg.get("provider-roster");
      const disconnects = rosterEl.querySelectorAll("[data-prov-disconnect]");
      assert.equal(disconnects.length, 2,
        "both roster rows must carry a wired Disconnect; got " + disconnects.length +
        " — if this is 0 the shim's attribute selector regressed and nothing below proves anything");
      const kind = disconnects[0].getAttribute("data-prov-kind");
      assert.equal(kind, "hetzner", "the first row is the Hetzner credential");
      assert.equal(disconnects[0].click(), 1,
        "the Disconnect button dispatched no click handler — it is DEAD");

      // The trigger opens the sheet and issues NOTHING.
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/providers/" + kind), 0,
        "Disconnect fired its DELETE straight off the row click — the typed-confirm gate is gone");
      assertDestroySheetDisarmed(reg, "Disconnect");

      // THE DISARM, PROVEN BY THE WIRE. The shim delivers clicks to disabled
      // elements (D56), so `fired` cannot see the gate; the request count can.
      assert.equal(reg.get("cm-confirm").click(), 1, "the sheet's Confirm must be wired for \"click\"");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/providers/" + kind), 0,
        "an UNARMED destroy Confirm put the DELETE on the wire — the typed echo is decorative");

      // THE ARM: type the kind, then confirm.
      armConfirmSheet(reg, kind).click();
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/providers/" + kind), 1,
        "the armed Confirm must issue exactly one DELETE");

      // THE SHRINK, read off the SERVER's own list — the assertion a stateless
      // fixture cannot pass, because it answers a byte-identical roster whether
      // or not the DELETE ever arrived (D39).
      assert.equal(ctx.state.providers.length, 1,
        "the server roster must shrink by exactly one (2 → 1); got " + ctx.state.providers.length);
      assert.ok(!ctx.state.providers.some((x) => x.kind === kind), "and the disconnected kind is the one gone");
      // …and the UI refetched, so the operator sees the truth rather than a
      // stale row they could click again.
      const repainted = reg.get("provider-roster").innerHTML || "";
      assert.ok(repainted.includes("Azure") && !repainted.includes("Hetzner"),
        "the roster must repaint from the refetch (Azure alone survives); got: " + repainted.slice(0, 200));
      const provToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(provToast.includes("Hetzner Cloud disconnected"),
        "a successful disconnect must say so; toast stack: " + provToast.slice(0, 200));
    },
  },
  "providers-empty": {
    what: "the empty roster + the connect card armed on the first provider; the matrix still renders",
    check(reg) {
      const roster = (reg.get("provider-roster") || {}).innerHTML || "";
      assert.ok(roster.includes("set-section"), "the empty roster still rides the anatomy");
      assert.ok(roster.includes("No providers connected yet"), "the honest empty note renders");
      assert.ok(!roster.includes("prov-row"), "no roster rows when nothing is connected");
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(connect.includes("data-connect-submit"), "the connect card is armed even with an empty roster");
      const matrix = (reg.get("provider-matrix") || {}).innerHTML || "";
      assert.ok(matrix.includes("cap-matrix"), "the matrix renders regardless of connected providers");
    },
  },
  "providers-unverified": {
    what: "the connect card's remediation slot + the server-owned remediation copy verbatim (node-pinned)",
    check(reg, hooks) {
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(connect.includes("cred-remediation"), "the connect card carries the remediation slot (filled on submit)");
      // The remediation is click-driven (submit → 422). Prove the honest path
      // node-pinned: the scenario's POST returns the single provider_unverified
      // + a remediation string, and remediationCopy() extracts it verbatim (never
      // routed through friendly(), which drops .remediation).
      const res = route("providers-unverified", "POST", "/v1/providers");
      assert.equal(res.status, 422, "connect preflight fails");
      assert.equal(res.body.error, "provider_unverified", "all causes collapse to one provider_unverified");
      const copy = hooks.remediationCopy(res.body);
      assert.ok(copy && copy.includes("Hetzner Cloud console"), "the server remediation names the exact console fix, verbatim");
      assert.equal(hooks.friendly(res.body, "fallback").indexOf(copy), -1, "friendly() provably drops the remediation");
    },
  },
  "providers-member": {
    what: "a plain member sees a read-only roster + matrix with ZERO write affordances",
    check(reg) {
      const roster = (reg.get("provider-roster") || {}).innerHTML || "";
      assert.ok(roster.includes("prov-row"), "the member still sees the roster (GET is member-readable)");
      assert.ok(!roster.includes("data-prov-disconnect"), "a member roster has NO Disconnect affordance");
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(!connect.includes("data-connect-submit"), "a member sees NO connect card");
      assert.ok(!connect.includes("set-section"), "the connect region is empty for a member");
      const matrix = (reg.get("provider-matrix") || {}).innerHTML || "";
      assert.ok(matrix.includes("cap-matrix"), "the honest matrix still renders read-only for a member");
    },
  },
  // ── G-04 notifications (the crown): the settings-anatomy page ───────────────
  "notif-configured": {
    what: "the full notifications page — email + chat channels + routing matrix + delivery log, all backend-true",
    check(reg) {
      const html = reg.get("notif-body").innerHTML || "";
      // GR33 anatomy: .set-section cards, each buffered section its own save-row;
      // the loose #notif-status span is GONE, and the superseded .notif-card too.
      assert.ok(html.includes("set-section"), "sections use the GR33 .set-section card");
      assert.ok(!html.includes('id="notif-status"'), "the loose #notif-status span is retired");
      assert.ok(!html.includes("notif-card"), "the superseded .notif-card is gone from this view");
      // Email section: transport seg (single-select) + its own save-row.
      assert.ok(html.includes("Email delivery") && html.includes("notif-transport-seg"), "email section with the transport seg");
      assert.ok(html.includes('id="notif-email-save"'), "email section owns its save-row button");
      // Channels roster: 6 channels (email transport + 5 chat), configured honesty,
      // consequence sub-lines, its own save-row.
      assert.ok(html.includes("Chat channels") && html.includes("set-channel"), "chat-channel roster renders");
      for (const label of ["Discord", "Slack", "Telegram", "Pushover", "Webhook"]) {
        assert.ok(html.includes(">" + label + " "), "roster lists " + label);
      }
      assert.ok(html.includes("configured"), "channels render their configured:bool truth");
      assert.ok(html.includes('id="notif-channels-save"'), "channels section owns its save-row");
      // Routing matrix: the event×channel grid on .set-toggle-weight cells + the
      // always-send test row (stated, never a lying toggle).
      assert.ok(html.includes("Event routing") && html.includes("set-matrix-grid"), "the routing matrix renders");
      assert.ok(html.includes("set-matrix-cell"), "matrix cells render as toggles");
      assert.ok(html.includes("Always sent to every enabled channel"), "the test row is stated as always-send, not a toggle");
      // Delivery log: the async sub-mount populated the rows in the webhook
      // grammar (mono recipient + toned status pill). GR79: the filter panel is a
      // REAL server round-trip now, so the section must SAY the filters search the
      // whole log (the old copy promised the last 50 and disowned filtering), and
      // both filter axes must render in the shared .actfilter-chip grammar.
      assert.ok(html.includes("Delivery log"), "the delivery-log section renders");
      assert.ok(html.includes("Filters run on the server"), "the section states that filtering is server-side");
      assert.ok(!html.includes("Filtering isn't available yet"), "the disowning sentence is gone");
      assert.ok(html.includes('data-notif-del-axis="channel"') && html.includes('data-notif-del-axis="status"'),
        "both chip axes render");
      assert.ok(html.includes('id="notif-del-event"'), "the free-text event filter renders (event is not a closed vocabulary)");
      assert.ok(html.includes("actfilter-chip is-active"), "each axis lights its own active chip");
      const log = (reg.get("notif-deliveries-body") || {}).innerHTML || "";
      assert.ok(log.includes("wh-del-row"), "the log renders rows in the webhook-deliveries grammar");
      assert.ok(log.includes("wh-del-status--danger"), "a failed delivery reads danger-toned");
      assert.ok(log.includes("Failed"), "a failure with no http_status reads 'Failed'");
      assert.ok(log.includes("204 OK"), "a chat delivery with an http_status reads its code");
    },
  },
  "notif-empty": {
    what: "first-run notifications — no channels configured, empty delivery log, honest defaults",
    check(reg) {
      const html = reg.get("notif-body").innerHTML || "";
      assert.ok(html.includes("Email delivery") && html.includes("Event routing"), "the page still composes all sections");
      assert.ok(html.includes("not configured"), "an untouched channel reads not-configured");
      const log = (reg.get("notif-deliveries-body") || {}).innerHTML || "";
      assert.ok(log.includes("No notifications have been delivered yet"), "the empty log states the honest empty case");
    },
  },
  "notif-member": {
    what: "plain-member notifications — read-only email, ZERO save-rows, no admin sections, no test button",
    check(reg) {
      const html = reg.get("notif-body").innerHTML || "";
      assert.ok(html.includes("set-readonly"), "the member sees read-only email settings");
      assert.ok(html.includes("managed by team admins"), "the admin-only sections degrade to an honest line");
      // The plain-member proof: no write affordances anywhere.
      assert.ok(!html.includes("set-save-row"), "member view has NO save-rows");
      assert.ok(!html.includes("notif-email-save"), "member view has NO save buttons");
      assert.ok(!html.includes("set-matrix-grid"), "member view has NO routing matrix");
      assert.ok(!html.includes("set-channel-creds"), "member view has NO credential inputs");
      assert.equal(reg.get("notif-test").hidden, true, "the header Send-test button is hidden for a member");
    },
  },
  "notif-deliveries-error": {
    what: "the deliveries route errors — the delivery log degrades honestly, the rest of the page survives",
    check(reg) {
      const html = reg.get("notif-body").innerHTML || "";
      assert.ok(html.includes("Event routing"), "the admin page still renders when deliveries fail");
      const log = (reg.get("notif-deliveries-body") || {}).innerHTML || "";
      assert.ok(log.includes("Couldn't load the delivery log"), "the log shows the honest error-degrade, never an infinite spinner");
    },
  },
  // ── G-05 API tokens (GR34) ──────────────────────────────────────────────────
  "tokens-populated": {
    what: "the token list — one lean row per PAT, ability chips + created/expiry, per-row Revoke, revoked row flagged",
    check(reg, hooks) {
      const html = reg.get("token-list").innerHTML || "";
      // Exactly one .token-row per fixture token (4), the revoked one flagged.
      assert.equal(countMatches(html, 'class="token-row'), 4, "one lean row per token");
      assert.ok(html.includes("is-revoked"), "the revoked token row is dimmed via is-revoked");
      for (const name of ["CI deploy key", "Read-only dashboard", "Break-glass root", "Legacy writer"])
        assert.ok(html.includes(name), "the row names the token: " + name);
      // Real pat_json fields only — chips + created(inserted_at)/expiry/last-used.
      assert.ok(html.includes("token-chip"), "abilities render as chips");
      assert.ok(html.includes("created "), "created (inserted_at) renders");
      assert.ok(html.includes("never used"), "a never-used token says so");
      assert.ok(html.includes("no expiry"), "a no-expiry token says so");
      assert.ok(html.includes(">Revoke<"), "an active row offers Revoke");
      assert.ok(html.includes("Revoked"), "the revoked row shows the Revoked badge");
      // NO faked prefix/preview — pat_json carries none; the list never invents one.
      assert.ok(!html.includes("bpc_pat_"), "the list never shows a token prefix/plaintext");
      // Owner picker: all four abilities as .set-check rows with consequence sub-lines.
      const picker = hooks.tokenAbilitiesFieldHtml();
      assert.equal(countMatches(picker, 'class="token-ab"'), 4, "owner sees all four ability checkboxes");
      for (const v of ["read", "write", "deploy", "root"])
        assert.ok(picker.includes('value="' + v + '"'), "owner can pick " + v);
      assert.ok(picker.includes("set-check-sub"), "each ability carries its consequence sub-line");
      assert.ok(picker.includes("exclusive"), "the deploy/root exclusivity consequence is stated");
    },
  },
  // ── cch-w11-s3-token-revoke-shrink-oracle: THE LAST LYING DESTROY VERB ─────
  // Every other tokens expectation reads markup. This one WATCHES THE APP DO
  // SOMETHING: it clicks a row's Revoke, then the confirm sheet's Revoke, and
  // reads whether the list the console refetches actually MOVED.
  //
  // WHAT WAS MEASURED BEFORE THE FIX (selector widened, route untouched):
  //   DELETE-calls=1 GET-calls=2 rows-after=4 victim-still-listed=true
  // A real DELETE on the wire, a real refetch — and a token list byte-identical
  // to the one before it, while the console toasts "Token revoked". Both halves
  // are load-bearing and NEITHER works alone (mutation-proven):
  //   • revert COMPOUND_SEL ⇒ `.token-revoke[data-id]` resolves [], nothing is
  //     wired, and the row's click dispatches 0 handlers — the button is dead;
  //   • revert the route ⇒ every assertion up to and including the DELETE count
  //     still passes and the list still reads 4 rows with the victim present.
  //
  // THE UNDOCUMENTED TRAP — CLICKS AND ASSERTIONS ANCHOR ON DIFFERENT OBJECTS.
  // This file's header (D55) says to anchor ASSERTIONS on #modal-body's
  // innerHTML, because the descendant registry node is immortal here. The
  // INVERSE rule governs CLICKS and was written nowhere: the confirm button must
  // be clicked through the #id REGISTRY (`reg.get("token-revoke-go")`), because
  // confirmRevokeToken() wires it with `$("#token-revoke-go")` → getElementById →
  // the registry object, while the button parsed out of #modal-body's innerHTML
  // is a DIFFERENT object carrying ZERO handlers. Click the parsed child and it
  // returns 0 and reads as a dead button that is in fact perfectly wired.
  //
  // NO TYPED-CONFIRM DRIVER, deliberately: confirmRevokeToken() — `grep -n
  // 'function confirmRevokeToken' cloud/priv/static/app.js` for both claims —
  // opens a PLAIN openModal with a bare `<button id="token-revoke-go">`, not
  // openConfirmModal, so there is no #cm-confirm, no #cm-typed and nothing to
  // arm. armConfirmSheet/assertDestroySheetDisarmed do not apply to this leg.
  "tokens-revoke": {
    what: "THE TOKEN REVOKE ORACLE — a real click revokes: confirm sheet, exactly one DELETE on the wire, and the refetched list SHRINKS 4 → 3 with the victim gone",
    async check(reg, hooks, ctx) {
      // ─ 1. the list rendered through the REAL loadTokens ────────────────────
      const box = reg.get("token-list");
      const rendered = box.innerHTML || "";
      assert.equal(countMatches(rendered, 'class="token-row'), 4, "the fixture's four tokens render");
      assert.equal(ctx.countCalls("GET", "/v1/tokens"), 1, "the list was fetched once on view entry");

      // ─ 2. the per-row Revoke is REACHABLE and WIRED ────────────────────────
      // This is the compound-selector half: app.js wires the rows with
      // `box.querySelectorAll(".token-revoke[data-id]")`, which answered [] for
      // this shim's whole existence — so the loop wired nothing and a loop over
      // nothing is a clean pass.
      const revokes = box.querySelectorAll(".token-revoke[data-id]");
      assert.equal(revokes.length, 3, "three revokable rows — the already-revoked token offers no Revoke");
      const victim = revokes[0].getAttribute("data-id");
      assert.equal(victim, "tok_rv_ci", "the first revokable row must carry its real data-id");
      const fired = revokes[0].click();
      assert.equal(fired, 1,
        "the per-row Revoke dispatched " + fired + " click handlers — the button is DEAD. " +
        "The markup can be present and correct while nothing is bound to \"click\".");

      // ─ 3. the confirm sheet mounts and NOTHING has happened yet ────────────
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes('id="token-revoke-go"'),
        "the revoke confirm sheet did not mount into #modal-body; got: " + JSON.stringify(sheet.slice(0, 200)));
      assert.ok(sheet.includes("Revoke token?") && sheet.includes("CI deploy key"),
        "the sheet must name what it is about to revoke");
      assert.ok(sheet.includes("btn-danger"), "GR41: a destructive confirm wears the danger tier's weight");
      assert.equal(ctx.countCalls("DELETE", "/v1/tokens/" + victim), 0,
        "the row click fired the DELETE before the operator confirmed — the confirm gate is gone");

      // ─ 4. CONFIRM VIA THE REGISTRY (see the trap in the header above) ──────
      const go = reg.get("token-revoke-go");
      assert.equal(go.click(), 1, "the sheet's Revoke must be wired for \"click\"");
      assert.equal(go.disabled, true, "the confirm button must go disabled while its DELETE is in flight");
      assert.equal(go.textContent, "Revoking…",
        "the label must confess the in-flight state, got " + JSON.stringify(go.textContent));
      await ctx.settle();

      // ─ 5. THE WIRE ────────────────────────────────────────────────────────
      assert.equal(ctx.countCalls("DELETE", "/v1/tokens/" + victim), 1,
        "exactly one DELETE for that token's id must reach the wire");
      const toasts = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(toasts.includes("Token revoked"), "a successful revoke must SAY SO; toast stack: " + toasts);

      // ─ 6. THE LIE, CLOSED: the refetched list must actually MOVE ───────────
      // Against the old flat `{status:200, body:{ok:true}}` DELETE and the old
      // direct `d.tokens` GET, every assertion above passed and this one did
      // not — the console reported success over an unchanged list.
      assert.equal(ctx.countCalls("GET", "/v1/tokens"), 2, "the success arm refetches the list");
      const after = reg.get("token-list").innerHTML || "";
      assert.equal(countMatches(after, 'class="token-row'), 3,
        "the revoked token must be GONE on the re-render (4 → 3); an unchanged list means the DELETE did nothing");
      assert.ok(!after.includes('data-id="' + victim + '"'),
        "the revoked token's row came back — the console is reporting success over a list that never moved");
      assert.ok(after.includes("Read-only dashboard") && after.includes("Legacy writer"),
        "only the victim may disappear — the other rows must survive the refetch");
    },
  },
  "tokens-empty": {
    what: "the empty state — no tokens yet, Create-token CTA",
    container: "token-list",
    includes: ["No API tokens yet", "empty-state", "Create token"],
    excludes: ['class="token-row'],
  },
  "tokens-member": {
    what: "plain-member picker — read-only scope stated up-front, no write/deploy/root pickers (anti-ghost)",
    check(reg, hooks) {
      // The list still renders the member's own read token.
      const list = reg.get("token-list").innerHTML || "";
      assert.ok(list.includes("My read token"), "the member sees their own token");
      // The picker (gated on meCache.role) offers read-only scope — NO checkboxes
      // for write/deploy/root, plus the honest ask-an-admin copy.
      const picker = hooks.tokenAbilitiesFieldHtml();
      assert.ok(picker.includes("set-check--scope"), "read scope is stated, not a pickable ghost");
      assert.ok(picker.includes("Members can create read-only tokens"), "honest copy names the cap");
      assert.ok(!picker.includes('class="token-ab"'), "no ability checkboxes are rendered for a member");
      assert.ok(
        !picker.includes('value="write"') && !picker.includes('value="deploy"') && !picker.includes('value="root"'),
        "write/deploy/root are not offered to a member",
      );
    },
  },
  "tokens-reveal": {
    what: "the plaintext-once reveal — amber only-time banner + the mono token on its own wrapping line (copy + show/hide), with the input-affix demoted to an off-screen copy buffer",
    check(reg, hooks) {
      const html = hooks.tokenRevealHtml("bpc_pat_3xampLEon1yShoWnoNCE", { name: "CI deploy key", abilities: ["deploy"] });
      assert.ok(html.includes("notice notice-warn"), "the amber only-time banner frames the reveal");
      assert.ok(html.toLowerCase().includes("only time"), "the banner says this is the only time");
      assert.ok(html.includes("input-affix"), "the plaintext sits in an input-affix row");
      assert.ok(html.includes("token-reveal-input"), "the value renders mono");
      assert.ok(html.includes("bpc_pat_3xampLEon1yShoWnoNCE"), "the plaintext is shown once");
      assert.ok(html.includes(">Copy<"), "a copy button is offered");
      assert.ok(html.includes("token-eye"), "a show/hide toggle is offered");
    },
  },
  // ── G-06 Members + env-vars (Settings wave, phase 4) ──────────────────────
  // The roster on the GR33 .set-* anatomy: view-members visible, both cards, the
  // 3-role chips, per-manageable-row Change role + Remove, the "(you)" self-tag.
  "members-populated": {
    what: "Members (admin) — roster + invitations, 3 real roles — AND real clicks: Remove shrinks the SERVER roster 3→2, Revoke shrinks invitations 2→1",
    async check(reg, hooks, ctx) {
      assert.equal(reg.get("view-members").hidden, false, "the Members view must be visible");
      const body = reg.get("members-body").innerHTML || "";
      assert.ok(body.includes("set-section"), "the roster rides the .set-section anatomy");
      assert.ok(body.includes("Team members"), "the roster card heading renders");
      assert.ok(body.includes("Pending invitations"), "the admin-only invitations card renders");
      assert.ok(body.includes("ada@acme.com") && body.includes("lin@acme.com") && body.includes("rex@acme.com"), "every member row renders");
      assert.ok(body.includes("(you)"), "the acting owner is self-tagged and gets no self-remove");
      assert.ok(body.includes("sky@partner.io"), "a pending invitation renders");
      // THREE roles only — the chips read Owner/Admin/Member; NO invented tiers.
      assert.ok(body.includes(">Owner<") && body.includes(">Admin<") && body.includes(">Member<"), "the 3 real role chips render");
      assert.ok(!body.includes("Operator") && !body.includes("Supporter"), "no design-fiction 5-role vocabulary is rendered");
      // Manage affordances present for the admin; Remove is the destroy path.
      assert.ok(body.includes(">Change role<") && body.includes(">Remove<"), "manager rows carry Change role + Remove");

      // ── cch-w10 LEG 2/5: REMOVE MEMBER, CLICKED FOR REAL ──────────────────
      // The path carries the team id, which this check has no business
      // hard-coding — so the wire assertion matches the SHAPE and reads the id
      // the app actually used.
      const wire = (method, re) => ctx.calls.filter((c) => c.method === method && re.test(c.path)).length;
      const panel = reg.get("members-body");
      const removes = panel.querySelectorAll("[data-member-remove]");
      assert.equal(removes.length, 2,
        "the two manageable rows carry a wired Remove (the acting owner never self-removes); got " + removes.length);
      const victimId = removes[0].getAttribute("data-member-remove");
      const victimEmail = removes[0].getAttribute("data-email");
      assert.ok(victimId && victimEmail, "the Remove button must carry both the user id and the email it types against");
      assert.equal(removes[0].click(), 1, "the Remove button dispatched no click handler — it is DEAD");
      await ctx.settle();
      const memberRe = new RegExp("^/v1/teams/[^/]+/members/" + victimId + "$");
      assert.equal(wire("DELETE", memberRe), 0, "Remove must open the typed sheet, never fire on the row click");
      assertDestroySheetDisarmed(reg, "Remove member");
      reg.get("cm-confirm").click();
      await ctx.settle();
      assert.equal(wire("DELETE", memberRe), 0, "an UNARMED destroy Confirm removed a member");
      // The typed echo is the EMAIL for this verb (resourceName), not the id.
      armConfirmSheet(reg, victimEmail).click();
      await ctx.settle();
      assert.equal(wire("DELETE", memberRe), 1, "the armed Confirm must issue exactly one member DELETE");
      assert.equal(ctx.state.members.length, 2,
        "the server roster must shrink by exactly one (3 → 2); got " + ctx.state.members.length);
      assert.ok(!ctx.state.members.some((m) => m.user_id === victimId), "and the removed member is the one gone");
      const afterRemove = reg.get("members-body").innerHTML || "";
      assert.ok(!afterRemove.includes(victimEmail),
        "the roster must repaint without the removed member; got: " + afterRemove.slice(0, 200));

      // ── cch-w10 LEG 3/5: REVOKE INVITATION, CLICKED FOR REAL ──────────────
      // A DIFFERENT sheet shape on purpose: revoking a pending invite is a plain
      // openModal with its own #invite-revoke-go, not the typed destroy tier —
      // one template would not have driven both, and pretending otherwise is how
      // an oracle ends up asserting a sheet that isn't there.
      const invites = reg.get("members-body").querySelectorAll("[data-invite-revoke]");
      assert.equal(invites.length, 2, "both pending invitations carry a wired Revoke; got " + invites.length);
      const invId = invites[0].getAttribute("data-invite-revoke");
      const invEmail = invites[0].getAttribute("data-email");
      assert.equal(invites[0].click(), 1, "the invitation Revoke dispatched no click handler — it is DEAD");
      const invRe = new RegExp("^/v1/teams/[^/]+/invitations/" + invId + "$");
      assert.equal(wire("DELETE", invRe), 0, "the row click must only open the confirm sheet");
      const invSheet = reg.get("modal-body").innerHTML || "";
      assert.ok(invSheet.includes("Revoke invitation?") && invSheet.includes(invEmail),
        "the sheet must name the invitation it is about to kill; got: " + invSheet.slice(0, 200));
      const go = reg.get("invite-revoke-go");
      assert.equal(go.click(), 1, "the sheet's Revoke must be wired for \"click\"");
      assert.equal(go.disabled, true, "the in-flight Revoke must disable itself against a double-fire");
      await ctx.settle();
      assert.equal(wire("DELETE", invRe), 1, "exactly one invitation DELETE on the wire");
      assert.equal(ctx.state.invitations.length, 1,
        "the server invitation list must shrink by exactly one (2 → 1); got " + ctx.state.invitations.length);
      const afterRevoke = reg.get("members-body").innerHTML || "";
      assert.ok(!afterRevoke.includes(invEmail) && afterRevoke.includes("max@acme.com"),
        "the panel must repaint with only the surviving invitation; got: " + afterRevoke.slice(0, 200));
    },
  },
  // The plain-member seam (GR33 plain-member law): read-only roster, no
  // invitations card, no manage affordances — proven by their ABSENCE.
  "members-member": {
    what: "Members (member) — read-only roster, zero manage affordances",
    check(reg) {
      assert.equal(reg.get("view-members").hidden, false, "the Members view must be visible");
      const body = reg.get("members-body").innerHTML || "";
      assert.ok(body.includes("Team members") && body.includes("rex@acme.com"), "the roster still renders for a member");
      assert.ok(!body.includes("Pending invitations"), "a member sees no invitations card");
      assert.ok(!body.includes(">Change role<") && !body.includes(">Remove<"), "a member sees no manage affordances");
      // The header Invite button stays hidden for a plain member.
      assert.equal(reg.get("members-invite").hidden, true, "the Invite button is hidden for a member");
    },
  },
  // Env-vars (admin): view-env visible, the row grammar (mono keys, scope +
  // secret + write-once chips, the sealed write-once note) + the add FORM.
  "env-populated": {
    what: "Environment variables (admin) — rows (secret/write-once/scopes) + add form — AND a real Delete click that shrinks the SERVER list 4→3",
    async check(reg, hooks, ctx) {
      assert.equal(reg.get("view-env").hidden, false, "the Environment-variables view must be visible");
      const body = reg.get("env-body").innerHTML || "";
      assert.ok(body.includes("set-section"), "the rows ride the .set-section anatomy");
      assert.ok(body.includes("DATABASE_URL") && body.includes("STRIPE_SECRET_KEY") && body.includes("WORKER_TOKEN"), "every var key renders");
      assert.ok(body.includes(">Secret<"), "a secret chip renders");
      assert.ok(body.includes(">Write-once<"), "a write-once chip renders");
      assert.ok(body.includes(">Team<") && body.includes(">Instance<"), "both scope chips render");
      // The value is sealed forever — NEVER a reveal affordance anywhere.
      assert.ok(!body.includes("Reveal") && !body.includes("Show value") && !body.includes("value=\"env"), "no reveal affordance — the value is sealed");
      // The write-once row carries the honest sealed-and-unreplaceable note.
      assert.ok(body.includes("Delete and recreate to change"), "the write-once row states it can't be changed in place");
      // The admin add-var FORM section with its own save-row.
      assert.ok(body.includes("Add a variable") && body.includes("set-save-row"), "the add-var form section renders with a save-row");
      assert.ok(body.includes(">Delete<"), "admin rows carry Delete");

      // ── cch-w10 LEG 4/5: DELETE A VARIABLE, CLICKED FOR REAL ──────────────
      const rows = reg.get("env-body").querySelectorAll("[data-env-delete]");
      assert.equal(rows.length, 4, "every admin row carries a wired Delete; got " + rows.length);
      const varId = rows[0].getAttribute("data-env-delete");
      const varKey = rows[0].getAttribute("data-key");
      assert.equal(rows[0].click(), 1, "the row Delete dispatched no click handler — it is DEAD");
      assert.equal(ctx.countCalls("DELETE", "/v1/env-vars/" + varId), 0,
        "the row click must only open the confirm sheet — a sealed value must never go on a single click");
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes("Delete variable?") && sheet.includes(varKey),
        "the sheet must name the variable; got: " + sheet.slice(0, 200));
      assert.ok(sheet.includes("can&#39;t be recovered") || sheet.includes("can't be recovered"),
        "the sheet must state the value is unrecoverable — the whole reason this verb needs a sheet");
      const go = reg.get("env-delete-go");
      assert.equal(go.click(), 1, "the sheet's Delete must be wired for \"click\"");
      assert.equal(go.disabled, true, "the in-flight Delete must disable itself against a double-fire");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/env-vars/" + varId), 1, "exactly one env-var DELETE on the wire");
      assert.equal(ctx.state.envVars.length, 3,
        "the server list must shrink by exactly one (4 → 3); got " + ctx.state.envVars.length);
      assert.ok(!ctx.state.envVars.some((v) => v.id === varId), "and the deleted row is the one gone");
      const after = reg.get("env-body").innerHTML || "";
      // Anchored on the ROW markup, not a bare substring: the add-var form
      // carries "DATABASE_URL" as its placeholder, so a naive includes() would
      // have reported the deleted row as still present and sent the next reader
      // hunting a bug that isn't there.
      assert.ok(!after.includes('set-row-key">' + varKey + "<"),
        "the deleted row must be gone from the repaint; got: " + after.slice(0, 300));
      assert.equal(countMatches(after, 'class="set-row-key"'), 3, "three rows survive the refetch");
      assert.ok(after.includes('set-row-key">STRIPE_SECRET_KEY<'), "and the survivors are still listed");
    },
  },
  // The write-once 409 twin renders the same sealed note; the POST-collision copy
  // itself is unit-pinned (envVarWriteFailureCopy) since the submit is click-driven.
  "env-write-once-409": {
    what: "Environment variables — the write-once row's sealed state (409 copy unit-pinned)",
    check(reg) {
      assert.equal(reg.get("view-env").hidden, false, "the Environment-variables view must be visible");
      const body = reg.get("env-body").innerHTML || "";
      assert.ok(body.includes("STRIPE_SECRET_KEY") && body.includes("Write-once"), "the write-once var renders");
      assert.ok(body.includes("Delete and recreate to change"), "the sealed per-row note renders");
    },
  },
  // Env-vars (member): read-only rows, NO add form, NO Delete (member-read law).
  "env-member": {
    what: "Environment variables (member) — read-only rows, no add form",
    check(reg) {
      assert.equal(reg.get("view-env").hidden, false, "the Environment-variables view must be visible");
      const body = reg.get("env-body").innerHTML || "";
      assert.ok(body.includes("DATABASE_URL"), "the rows still render for a member");
      assert.ok(!body.includes("Add a variable") && !body.includes("set-save-row"), "a member sees no add form");
      assert.ok(!body.includes(">Delete<"), "a member sees no Delete affordance");
    },
  },

  // ── gr-p5 OPERATOR CONSOLE (GR39/GR40/GR48/GR49/GR50) ─────────────────────
  // The crown surface, states-complete: rolling / halted / bounced / unreadable.
  "operator-console": {
    what: "Operator console (rolling) — brake live, canary ordered, staging gate open, warm pool ready, digest empty",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, false, "the Operator view must be visible for an operator");
      const page = reg.get("operator-body").innerHTML || "";
      for (const heading of ["Rollout brake", "Canary rollout", "Warm pool", "Fleet digest"])
        assert.ok(page.includes(heading), "the page carries the " + heading + " card");

      // 1. BRAKE — the SHARED banner model, with the console's one action control.
      const brake = reg.get("op-brake-body").innerHTML || "";
      assert.ok(brake.includes("Fleet autoupdate is live"), "the shared banner copy renders (never restated)");
      assert.ok(brake.includes('data-fleet-au="halt"'), "the console owns the Halt control");
      assert.ok(brake.includes("nothing is rolled back"), "the halt consequence is stated honestly");

      // 2. CANARY — every row, the settle countdown, the top-level gate, 20m copy.
      const canary = reg.get("op-canary-body").innerHTML || "";
      for (const name of ["acme-canary", "acme-prod", "beta-prod", "fresh-box", "optout-prod"])
        assert.ok(canary.includes(name), "the roll-up renders " + name);
      assert.ok(canary.includes("SETTLE — 9m of 20m"), "the in-flight box shows its settle countdown");
      assert.ok(canary.includes("a staging instance is current on the newest release"), "the TOP-LEVEL gate flag drives the gate line");
      assert.ok(canary.includes("Unknown") && canary.includes("Autoupdate off") && canary.includes("Behind") && canary.includes("Current"),
        "all four update_state vocabularies render");
      assert.ok(canary.includes("SETTLE 20m") && !canary.includes("30m"), "20 minutes, never the mock's 30m");
      // In-flight leads, then staging, then behind — the rollout's own order.
      assert.ok(canary.indexOf("acme-prod") < canary.indexOf("acme-canary"), "the in-flight box leads");
      assert.ok(canary.indexOf("acme-canary") < canary.indexOf("beta-prod"), "the staging canary precedes the prod queue");

      // 3. WARM POOL — ONE number, no bar, no invented denominator.
      const warm = reg.get("op-warm-body").innerHTML || "";
      assert.ok(warm.includes(">2<"), "the ready count renders");
      assert.ok(warm.includes("there's no total to compare against"), "the honest no-denominator caption renders");
      assert.ok(!warm.includes("usage-bar") && !warm.includes("%"), "no bar and no percentage");

      // 4. DIGEST — empty is the true state, and there is NO send-now button.
      const digest = reg.get("op-digest-body").innerHTML || "";
      assert.ok(digest.includes("No fleet digest has been sent yet"), "the honest empty state renders");
      assert.ok(!/Send (one )?now/i.test(page + digest), "no send-now button anywhere (GR40)");
    },
  },
  "operator-halted": {
    what: "Operator console (halted) — Resume offered, gate closed, empty pool stated calmly, digest failure verbatim",
    check(reg) {
      const brake = reg.get("op-brake-body").innerHTML || "";
      assert.ok(brake.includes("Fleet autoupdate is halted"), "the halted banner renders");
      assert.ok(brake.includes("bad release 0.5.0"), "the server's halt reason is shown");
      assert.ok(brake.includes('data-fleet-au="resume"'), "Resume is the offered action");
      const canary = reg.get("op-canary-body").innerHTML || "";
      assert.ok(canary.includes("closed — staging is behind or paused"), "the closed gate is stated");
      const warm = reg.get("op-warm-body").innerHTML || "";
      assert.ok(warm.includes("The pool is empty right now"), "an empty pool reads as a designed state");
      assert.ok(!warm.includes("unavailable"), "an empty pool is never reported as an error");
      const digest = reg.get("op-digest-body").innerHTML || "";
      assert.ok(digest.includes("smtp: connection timed out"), "the failed send carries its verbatim error");
      assert.ok(digest.includes("Sent") && digest.includes("Failed"), "both outcomes render");
    },
  },
  "operator-zero-staging": {
    what: "Operator console (zero staging, empty pool) — the gate is open but vouches for NOTHING, and an empty pool is a designed state",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, false, "the Operator view renders for an operator");
      const canary = reg.get("op-canary-body").innerHTML || "";
      // GR50's THIRD gate sentence: open-because-empty is not open-because-vouched.
      assert.ok(canary.includes("no staging instance is registered"),
        "an empty staging list must NOT read as a green vouch");
      assert.ok(!canary.includes("a staging instance is current on the newest release"),
        "the vouching sentence must never fire without a staging box");
      assert.ok(!canary.includes("closed"), "the gate is genuinely open — it just guarantees nothing");
      for (const name of ["acme-prod", "beta-prod"]) assert.ok(canary.includes(name), "the prod queue still renders " + name);
      // Empty warm pool: the designed-state sentence, never an error, never a bar.
      const warm = reg.get("op-warm-body").innerHTML || "";
      assert.ok(warm.includes("The pool is empty right now"), "an empty pool reads as a designed state");
      assert.ok(!warm.includes("unavailable"), "an empty pool is never reported as unreadable");
      assert.ok(!warm.includes("usage-bar") && !warm.includes("%"), "no bar, no invented denominator");
      // And the digest is honestly empty rather than absent.
      const digest = reg.get("op-digest-body").innerHTML || "";
      assert.ok(digest.includes("No fleet digest has been sent yet"), "the honest empty digest renders");
    },
  },
  "operator-denied": {
    what: "Operator console — a non-operator deep link is BOUNCED to Overview (fail-closed route gate)",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, true, "the Operator view must NEVER render for a non-operator");
      assert.equal(reg.get("view-overview").hidden, false, "the bounce lands on Overview");
      assert.equal(reg.get("operator-body").innerHTML || "", "", "no operator markup is left behind");
      assert.equal(reg.get("nav-operator").hidden, true, "the sidebar entry stays hidden too");
    },
  },
  "operator-unreadable": {
    what: "Operator console — every route 403s; each card says IT couldn't read, and none fakes a value",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, false, "an operator still reaches the page");
      const brake = reg.get("op-brake-body").innerHTML || "";
      const canary = reg.get("op-canary-body").innerHTML || "";
      const warm = reg.get("op-warm-body").innerHTML || "";
      const digest = reg.get("op-digest-body").innerHTML || "";
      assert.ok(brake.includes("Rollout state unavailable"), "the brake degrades honestly");
      assert.ok(!brake.includes("data-fleet-au"), "an unreadable brake offers no button");
      assert.ok(canary.includes("Fleet unavailable"), "the canary degrades honestly");
      assert.ok(warm.includes("Warm pool unavailable"), "the warm pool degrades honestly");
      assert.ok(!warm.includes("op-metric-v"), "no fake zero is drawn when the count didn't answer");
      assert.ok(digest.includes("Digest log unavailable"), "the digest degrades honestly");
      for (const html of [brake, canary, warm, digest])
        assert.ok(!html.includes("Loading"), "no card is left spinning after its request settles");
    },
  },
  // ── MVP-0 Personal Dev Fleet (pdf-mvp0-fleet-card-spa): the fleet card ─────
  "fleet-support-provisioning": {
    what: "the fleet card with a support mid-provision — the 6-rung SUPPORT theater, secure included, never a freshen rung",
    container: "instance-body",
    includes: ["fleet-support-card", "fleet-support-theater", "new-steps",
      "Configuring the runtime", 'data-step="secure"', 'data-step="verify"'],
    excludes: ['data-step="freshen"'],
  },
  "fleet-support-online": {
    what: "the fleet card with an ONLINE support — the BYO-model-key step in the card; the roster read answers the documents envelope and the presence pipeline renders --online from THAT fixture",
    check(reg, hooks, ctx) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      // The static card half: key step + the presence slot (this fake DOM can't
      // observe the async attribute-selector paint — the chip pipeline is
      // asserted below from the same fixtures the paint consumes).
      for (const needle of ["fleet-support-card", "support-key-step", "Hand your box its model key",
        "data-support-presence=", "never stored by Barkpark",
        "/etc/barkpark/fleet-listener.env &amp;&amp; systemctl restart barkpark-fleet-listener"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      // The wire half: the app-token mint fired and the browser-direct roster
      // read landed on the /v1/fleet/roster arm (absolute-origin stripped).
      assert.ok(ctx.calls.some((c) => c.method === "POST" && /\/app-token$/.test(c.path)),
        "the member app token must be minted (in-memory only)");
      const roster = route("fleet-support-online", "GET", "/v1/fleet/roster");
      assert.ok(Array.isArray(roster.body.documents), "the roster rides the documents envelope (PDF-D21)");
      // The presence pipeline over the SAME fixture the paint consumes:
      // online DERIVED (idle ⇒ not offline) + the validated capacity object.
      const support = SCENARIOS["fleet-support-online"].data.barkparks.find((b) => b.fleet_role === "support");
      const slot = hooks.presenceSlotHtml(roster.body.documents, support);
      assert.ok(slot.includes("fleet-presence--online"), "idle must render the derived Online chip");
      assert.ok(slot.includes("Online · idle"), "the stored status renders as-is beside the derived Online");
      assert.ok(slot.includes("standard · 1/1 slots free"), "the capacity object renders");
      assert.ok(ctx.calls.some((c) => c.path === "/v1/fleet/roster" || /\/v1\/fleet\/roster$/.test(c.path)),
        "the roster was actually fetched browser-direct");
    },
  },
  "fleet-support-failed": {
    what: "the fleet card with a STUCK support — honest failed state, never lies online",
    container: "instance-body",
    includes: ["fleet-support-card", "Setup failed",
      "no heartbeat within the provisioning budget"],
    excludes: ["fleet-presence--online", "support-key-step"],
  },
  "fleet-support-empty": {
    what: "the fleet card empty state on a live main — the add-a-support CTA",
    container: "instance-body",
    includes: ["fleet-support-card", "No support servers yet", 'id="fleet-add-support-cta"'],
    excludes: ["fleet-support-row"],
  },
  // ── MVP-0 OFFLOAD (pdf-mvp0-offload-spa): the order watch ladder ───────────
  // The offload button renders on the ONLINE support row (static, observable in
  // #instance-body). The watch panel itself mounts AFTER a click+submit, which
  // this fake DOM can't drive, so the ladder is proven the fleet-support-online
  // way: fold the SAME task + roster fixtures the poll consumes through the pure
  // hooks and assert the rung + markup.
  "offload-filing": {
    what: "offload — the order is filed (open); the ladder folds to the FILED rung from the task + roster reads",
    check(reg, hooks, ctx) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.includes("data-offload-support="), "the Offload button must render on a live support");
      assert.ok(body.includes("Offload a task"), "the Offload action label renders");
      assert.ok(body.includes("data-offload-slot="), "the watch slot mounts on the row");
      assert.ok(ctx.calls.some((c) => c.method === "POST" && /\/app-token$/.test(c.path)),
        "the member app token must be minted (in-memory only)");
      const task = route("offload-filing", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-filing", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "filed");
      assert.equal(watch.terminal, false);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch);
      assert.ok(panel.includes("new-steps"), "the ladder renders through the SHARED step grammar");
      assert.ok(panel.includes("waiting for the support to claim"), "the filed rung label");
    },
  },
  "offload-working": {
    what: "offload — claimed AND working; the ladder folds filed→claimed→working from the task (in_progress) + roster (working) reads",
    check(reg, hooks) {
      const task = route("offload-working", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-working", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "working");
      assert.equal(watch.terminal, false);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch, 12000);
      assert.ok(panel.includes("Working the order"), "the working rung label");
      assert.ok(panel.includes('data-step="working"'), "the working rung renders in the ladder");
    },
  },
  "offload-done": {
    what: "offload — DONE terminal (the poll stops); the ladder paints every rung done + the success banner",
    check(reg, hooks) {
      const task = route("offload-done", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-done", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "done");
      assert.equal(watch.terminal, true);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch);
      assert.ok(panel.includes("notice-ok"), "the done terminal shows the success banner");
    },
  },
  "offload-blocked": {
    what: "offload — BLOCKED terminal; the ladder snaps and shows the honest blocked banner",
    check(reg, hooks) {
      const task = route("offload-blocked", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-blocked", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "blocked");
      assert.equal(watch.terminal, true);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch);
      assert.ok(panel.includes("notice-warn"), "the blocked terminal shows the honest banner");
      assert.ok(panel.includes('class="new-step failed'), "the ladder snaps on the failed rung");
    },
  },
};

function countMatches(hay, needle) {
  return hay.split(needle).length - 1;
}

// ── cch-w10: the destroy-tier confirm sheet, driven as an operator drives it ──
// The typed echo is the gate: openConfirmModal's click handler bails at
// `if (!confirmModalArmed(state)) return;`, so an UNARMED Confirm is a real,
// wired, dispatching button that issues nothing. That makes the disarm
// observable BY THE WIRE (0 requests), which is the only observation that
// cannot be faked by a stub.
//
// WHICH OBJECT CARRIES WHICH FACT — this CORRECTS D54, which recorded the
// disarm as unobservable here and told every later check to skip it:
//   • the SHIPPED disarm lives on #modal-body's PARSED child, because it is an
//     attribute of the markup confirmModalHtml emitted (`<button … disabled>`);
//   • the ARM lives on the #id REGISTRY node, because that is the object
//     app.js's input handler writes (`confirmBtn.disabled = !armed`).
// They are DIFFERENT OBJECTS. reg.get("cm-confirm").disabled is `false` on a
// fresh stub whether or not a destroy sheet ever mounted — asserting it as the
// disarm is a false green planted inside the anti-false-green scenario.
function parsedConfirmButton(reg) {
  return reg.get("modal-body").querySelectorAll("#cm-confirm")[0] || null;
}

// Assert the sheet MOUNTED and SHIPPED DISARMED, then return the parsed child.
function assertDestroySheetDisarmed(reg, where) {
  const parsed = parsedConfirmButton(reg);
  assert.ok(parsed, "no #cm-confirm inside #modal-body — the " + where +
    " confirm sheet never mounted; #modal-body is: " +
    JSON.stringify((reg.get("modal-body").innerHTML || "").slice(0, 160)));
  assert.equal(parsed.disabled, true,
    "the " + where + " destroy sheet shipped its Confirm ARMED — the typed-echo gate is gone");
  assert.equal(reg.get("cm-confirm").disabled, false,
    "D54 CORRECTION GUARD: the #id registry stub answers disabled=false here. If this ever " +
    "flips, the two objects have merged and the disarm assertion above may be read off either — " +
    "until then, reading the registry node instead of the parsed child proves NOTHING.");
  return parsed;
}

// Type the exact resource name into #cm-typed and fire the "input" event the
// arming handler listens for; returns the (now armed) registry Confirm node.
function armConfirmSheet(reg, resourceName) {
  const typed = reg.get("cm-typed");
  typed.value = resourceName;
  assert.ok(typed.dispatchEvent({ type: "input" }) > 0,
    "#cm-typed has no \"input\" handler — the typed echo can never arm the sheet");
  const confirm = reg.get("cm-confirm");
  assert.equal(confirm.disabled, false,
    "typing the exact resource name did not ARM the Confirm button");
  return confirm;
}

async function runScenario(name) {
  const exp = EXPECTATIONS[name];
  if (!exp) throw new Error("no expectations for scenario " + name);
  const { registry, hooks, calls, fixtureState } = bootScenario(name);
  await flush();

  if (exp.check) {
    // check may be async: a click-driven scenario has to settle the fetch
    // chain the click started before it can read the re-render. `ctx.settle()`
    // is that await; sync checks simply ignore the third argument.
    await exp.check(registry, hooks, {
      calls,
      state: fixtureState,
      settle: flush,
      // How many times METHOD PATH was requested — the wire assertion.
      countCalls(method, path) {
        return calls.filter((c) => c.method === method && c.path === path).length;
      },
    });
    return exp.what;
  }

  const el = registry.get(exp.container);
  assert.ok(el, "container #" + exp.container + " was never touched");
  const html = el.innerHTML || "";
  assert.ok(html.length > 0, "#" + exp.container + " rendered empty");

  for (const needle of exp.includes || []) {
    assert.ok(html.includes(needle), "#" + exp.container + " missing " + JSON.stringify(needle));
  }
  for (const needle of exp.excludes || []) {
    assert.ok(!html.includes(needle), "#" + exp.container + " unexpectedly has " + JSON.stringify(needle));
  }
  if (exp.fleetRowsEqualFixture) {
    const want = SCENARIOS[name].data.barkparks.length;
    const got = countMatches(html, 'class="fleet-row"');
    assert.equal(got, want, "expected " + want + " fleet rows, rendered " + got);
  }
  return exp.what;
}

// ── cch-w10: THE CENSUS GUARD ────────────────────────────────────────────────
// The runner iterates EXPECTATIONS, never SCENARIO_NAMES. Nothing bound the two
// together, so a committed scenario with no expectation was simply NEVER RUN —
// it rendered nowhere, asserted nothing, and the suite still printed a total and
// exited 0. That is the cross-slice census hole in miniature: each half looks
// complete on its own, and only the pair exposes the gap. (The file's own
// comment has documented the trap for waves; the guard was never written.)
// Both directions matter: an EXPECTATION whose scenario was renamed or deleted
// would otherwise boot the DEFAULT fixture and quietly assert against the wrong
// data. This runs BEFORE any scenario, and it exits non-zero on its own.
function assertCensus() {
  const unrun = SCENARIO_NAMES.filter((n) => !EXPECTATIONS[n]);
  const orphans = Object.keys(EXPECTATIONS).filter((n) => !SCENARIOS[n]);
  if (!unrun.length && !orphans.length) return true;
  if (unrun.length) {
    process.stdout.write(
      "\nCENSUS: " + unrun.length + " committed scenario(s) have NO expectation and were never run — " +
      "a fixture nothing asserts on is a green that means nothing:\n  " + unrun.join("\n  ") + "\n");
  }
  if (orphans.length) {
    process.stdout.write(
      "\nCENSUS: " + orphans.length + " expectation(s) name a scenario that does not exist, so they " +
      "assert against the DEFAULT fixture:\n  " + orphans.join("\n  ") + "\n");
  }
  return false;
}

async function main() {
  if (!assertCensus()) {
    process.stdout.write("\ncensus guard failed — every scenario needs an expectation, both ways\n");
    process.exit(1);
  }
  const names = Object.keys(EXPECTATIONS);
  let failed = 0;
  for (const name of names) {
    try {
      const what = await runScenario(name);
      process.stdout.write("  ok   " + name.padEnd(14) + " — " + what + "\n");
    } catch (e) {
      failed++;
      process.stdout.write("  FAIL " + name.padEnd(14) + " — " + (e && e.message) + "\n");
    }
  }
  process.stdout.write(
    (failed ? "\n" + failed + " scenario(s) failed\n" : "\nall " + names.length + " scenarios rendered\n"),
  );
  process.exit(failed ? 1 : 0);
}

main();
