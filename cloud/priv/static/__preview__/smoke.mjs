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
import { SCENARIOS, route } from "./scenarios.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_JS = fs.readFileSync(path.join(HERE, "..", "app.js"), "utf8");

// ── minimal DOM shim ─────────────────────────────────────────────────────────
// An element is a plain bag of the props app.js reads/writes. The critical
// invariant: getElementById(id) and querySelector("#id") return the SAME object
// across calls (a registry), so an innerHTML the app writes to #fleet-body is
// still there when the assertion reads it back. Wiring calls (addEventListener,
// classList, focus, sub-tree querySelector) are inert — we observe markup, not
// behaviour.
function makeDom() {
  const registry = new Map();

  function makeEl(id) {
    const el = {
      id: id || "",
      innerHTML: "",
      textContent: "",
      value: "",
      hidden: false,
      className: "",
      disabled: false,
      style: {},
      dataset: {},
      scrollTop: 0,
      scrollHeight: 0,
      clientHeight: 0,
      parentNode: null,
      classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
      addEventListener() {},
      removeEventListener() {},
      setAttribute() {},
      removeAttribute() {},
      getAttribute() { return null; },
      hasAttribute() { return false; },
      focus() {},
      blur() {},
      click() {},
      appendChild(child) { return child; },
      removeChild(child) { return child; },
      insertAdjacentHTML(_pos, html) { this.innerHTML += html; },
      querySelector() { return null; },
      querySelectorAll() { return []; },
      closest() { return null; },
      getClientRects() { return []; },
    };
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
    createElement() { return makeEl(""); },
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

  const location = {
    hash: scen.deepLink || "#overview",
    pathname: "/",
    search: "",
    origin: "http://localhost",
    href: "http://localhost/",
  };

  // fetch → scenario router → a Response-like the app's api() understands.
  function fetchStub(url, init) {
    const method = (init && init.method) || "GET";
    const p = String(url);
    const res = route(name, method, p) || { status: 404, body: { error: "not_found" } };
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

  vm.createContext(sandbox);
  vm.runInContext(APP_JS, sandbox, { filename: "app.js" });

  return { registry };
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
    includes: ["bp-timeline", "bp-tl-steps", "bp-tl-step--active", "bp-console", "Provisioning"],
    excludes: ["bp-tl-fail"],
  },
  failed: {
    what: "the setup-failed state with the verbatim error",
    container: "instance-body",
    includes: ["bp-tl-fail", "bp-tl-step--failed", "Setup failed", "Retry setup", "Studio never came up"],
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
  // Invitation accept: each committed terminal renders its designed card with
  // exactly one [data-invite-act] action (esc() turns ' into &#39; in copy).
  "invite-joined": {
    what: "the Join confirm for a live foreign-team invitation",
    container: "view-invite",
    includes: ['data-invite-act="join"', "Northwind Trading", "invite-skip", "Not now"],
  },
  "invite-expired": {
    what: "the calm expired dead-end with one next action",
    container: "view-invite",
    includes: ["has expired", 'data-invite-act="overview"'],
    excludes: ['data-invite-act="join"'],
  },
  "invite-already-member": {
    what: "the already-a-member card with one next action",
    container: "view-invite",
    includes: ["already a member", 'data-invite-act="overview"'],
    excludes: ['data-invite-act="join"'],
  },
  "invite-invalid": {
    what: "the revoked/used dead-end with one next action",
    container: "view-invite",
    includes: ["isn&#39;t valid any more", 'data-invite-act="overview"'],
    excludes: ['data-invite-act="join"'],
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
};

function countMatches(hay, needle) {
  return hay.split(needle).length - 1;
}

async function runScenario(name) {
  const exp = EXPECTATIONS[name];
  if (!exp) throw new Error("no expectations for scenario " + name);
  const { registry } = bootScenario(name);
  await flush();

  if (exp.check) {
    exp.check(registry);
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

async function main() {
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
