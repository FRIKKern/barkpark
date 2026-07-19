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
  // Wave 3: the Overview fleet usage strip. Unlike the Usage meter wall, the
  // strip fills its OWN #overview-fleet-usage container (a real registry element
  // the app writes to), so the async /v1/usage/summary fetch → render is fully
  // observable here: the over-quota team headline + Manage-plan recovery, the
  // fresh/stale "as of" stamps, and the honest no-sample cell all in one boot.
  // Wave 5 (OC18/OC27): the per-instance CPU · RAM machine capacity cells, and a
  // hot armed box (RAM at its ceiling) lighting its whole row accent (over).
  "fleet-usage": {
    what: "the fleet usage strip paints team headline + per-instance sample + CPU/RAM capacity cells",
    container: "overview-fleet-usage",
    includes: [
      "Fleet usage", "usage-bar--over", ">Manage plan<", "fleet-usage-cell", "as of ", "No sample yet",
      ">CPU</span>", ">RAM</span>", "100%", "fleet-usage-cell--over",
    ],
    excludes: ["Loading fleet usage"],
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
    what: "the confirm screen naming the requesting machine + Approve/Deny",
    container: "activate-body",
    includes: ["Approve this sign-in?", "bp on nimbus.local", "203.0.113.7",
      'id="activate-approve"', 'id="activate-deny"'],
    excludes: ["Too many attempts", "expired or was already used", "Unknown device"],
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
