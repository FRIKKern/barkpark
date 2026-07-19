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
      assert.ok(box.includes(">Manage billing<"), "the current-plan card must offer the portal");
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
      assert.ok(box.includes(">Manage billing<"), "the portal CTA must render");
      assert.ok(box.includes("3 managed instances"), "the features must state the real Supporter ceiling");
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
