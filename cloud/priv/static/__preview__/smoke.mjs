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
    // Created (non-registry) elements are throwaway wiring surfaces here. Their
    // querySelector answers an inert element (never null) so a primitive that
    // wires its own fresh markup — toast()'s close button is the first smoke-
    // exercised case (gr-p2 portal-return ack) — stays inert instead of
    // crashing the boot. Registry (#id) elements keep the null-returning
    // querySelector above, so existence-driven logic is untouched.
    createElement() {
      const el = makeEl("");
      el.querySelector = () => makeEl("");
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

  return { registry, hooks: captured.hooks };
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
      assert.ok(arch.includes("How archives work"), "the docs link renders");
      assert.ok(arch.includes("data-archives-retry"), "a working Retry renders");
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
    what: "the v4 instance workspace: two-axis header, bp CLI card, composed Overview",
    check(reg) {
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
  // gr-p3-small-surfaces (E-01): the global sites list on v4 — one density row
  // per site with a leading deploy-status pill, states-complete, real fields
  // ONLY (the invented Marketing/Docs/Blank "kind" taxonomy never renders).
  sites: {
    what: "v4 sites list — deploy-status pills (live/rebuilding/failed/never), real fields, no invented kinds",
    check(reg) {
      const body = (reg.get("sites-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#sites-body rendered empty");
      // Exactly one v4 global row per fixture site.
      assert.equal(countMatches(body, 'class="site-row site-row--global"'), 4,
        "one v4 density row per fixture site");
      // The leading status pill, states-complete across the four rows.
      assert.ok(body.includes("status-pill--ok"), "the live site reads an ok pill");
      assert.ok(body.includes("status-pill--warn"), "the rebuilding site reads a warn pill");
      assert.ok(body.includes("status-pill--danger"), "the deploy-failed site reads a danger pill");
      assert.ok(body.includes("status-pill--neutral"), "the never-deployed site reads a neutral pill");
      assert.ok(body.includes(">Not deployed<"), "a never-deployed site says so — no invented green");
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
    what: "the roster (2 kinds, Disconnect…), the all-connected replace state, and the honest capability matrix render",
    check(reg) {
      const roster = (reg.get("provider-roster") || {}).innerHTML || "";
      assert.ok(roster.includes("set-section"), "the roster rides the .set-* anatomy");
      assert.ok(roster.includes("prov-roster") && roster.includes("prov-row"), "roster rows render");
      assert.ok(roster.includes("Hetzner") && roster.includes("Azure"), "both connected kinds render");
      assert.ok(roster.includes("connected "), "each row shows a connected-at (never a validity badge)");
      assert.ok(!/\bConnected<\/span>/.test(roster), "the roster never implies live validity");
      assert.ok(roster.includes("data-prov-disconnect"), "an admin roster carries the typed-confirm Disconnect");

      // Both connectable providers are already connected → the connect card is in
      // the "disconnect to replace" state: it offers NO second connect (the
      // additive-duplicate guard, GR36 already-connected ruling).
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(connect.includes("set-section") && connect.includes("Connect a provider"), "the connect card renders");
      assert.ok(connect.includes("Every supported provider is connected"), "the all-connected replace note renders");
      assert.ok(!connect.includes("data-connect-submit"), "no second connect is offered for already-connected kinds");

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
      // Delivery log: the async sub-mount populated the last-50 rows in the webhook
      // grammar (mono recipient + toned status pill), with no fake filter UI.
      assert.ok(html.includes("Delivery log") && html.includes("last 50"), "the delivery-log section frames the last 50");
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
    what: "the plaintext-once reveal — amber only-time banner + mono input-affix (copy + show/hide)",
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
    what: "Members (admin) — roster + invitations on the .set-* anatomy, 3 real roles",
    check(reg) {
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
    what: "Environment variables (admin) — rows (secret/write-once/scopes) + add form",
    check(reg) {
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
};

function countMatches(hay, needle) {
  return hay.split(needle).length - 1;
}

async function runScenario(name) {
  const exp = EXPECTATIONS[name];
  if (!exp) throw new Error("no expectations for scenario " + name);
  const { registry, hooks } = bootScenario(name);
  await flush();

  if (exp.check) {
    exp.check(registry, hooks);
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
