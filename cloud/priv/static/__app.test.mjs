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

test("provisionSteps: empty (legacy row) → all seven known steps pending, elapsed null", () => {
  const rows = hooks.provisionSteps({ provision_steps: [] }, NOW);
  assert.equal(rows.length, 7);
  // dwb-17/D10 + D45 order: freshen sits between create and secure; the verify
  // gate probes BETWEEN content and ready, so it displays there.
  assert.deepEqual([...rows.map((r) => r.step)], ["create", "freshen", "secure", "configure", "content", "verify", "ready"]);
  assert.equal(rows[1].label, "Updating to the latest Barkpark"); // dwb-17 freshen label
  assert.equal(rows[5].label, "Testing login & Studio"); // D45 label
  for (const r of rows) {
    assert.equal(r.role, "pending");
    assert.equal(r.elapsedMs, null);
    assert.equal(r.caption, "");
    assert.deepEqual([...r.probes], []);
  }
  // Total over junk: null bp never throws.
  assert.equal(hooks.provisionSteps(null, NOW).length, 7);
  assert.equal(hooks.provisionSteps(undefined).length, 7);
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
  assert.equal(rows[1].step, "freshen"); // dwb-17: unstarted freshen renders pending
  assert.equal(rows[1].role, "pending");
  assert.deepEqual(norm(rows[2]), { step: "secure", label: "Securing your domain", role: "ok", elapsedMs: 2000, caption: "", probes: [] });
  assert.deepEqual(norm(rows[3]), { step: "configure", label: "Configuring Barkpark", role: "active", elapsedMs: 5000, caption: "Installing packages", probes: [] });
  assert.equal(rows[4].role, "pending"); // content
  assert.equal(rows[4].elapsedMs, null);
  assert.equal(rows[5].role, "pending"); // verify still upcoming
  assert.equal(rows[6].role, "pending"); // ready last
});

test("provisionSteps: verify with probe lines → checklist under the step", () => {
  const bp = { provision_steps: [
    { step: "verify", status: "started", at: T(5), detail: "Probing the golden path" },
    { step: "verify", status: "progress", at: T(6), detail: "verify.login: 200 in 120ms" },
    { step: "verify", status: "progress", at: T(7), detail: "verify.query: 200 in 42ms" },
  ] };
  const verify = hooks.provisionSteps(bp, NOW)[5]; // dwb-17: freshen shifted verify to index 5
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
  assert.equal(rows.length, 8); // seven known + the appended unknown
  const t = rows[7];
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
  assert.equal(rows[1].role, "pending"); // dwb-17: freshen, unstarted
  assert.equal(rows[2].role, "active");  // secure, shifted by the freshen rung
  assert.equal(rows[2].elapsedMs, null); // active but no start stamp
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

test("newStepsHtml: an active step with a caption is byte-identical to the pre-C3 markup", () => {
  const html = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "active", elapsedMs: 1000, caption: "Booting", probes: [] },
  ]);
  assert.equal(html,
    '<ul class="new-steps">' +
      '<li class="new-step active">' +
        '<span class="new-step-dot" aria-hidden="true"></span>' +
        '<span class="new-step-body">' +
          '<span class="new-step-label">Creating your server</span>' +
          '<span class="new-step-detail" data-cap="Booting">Booting</span>' +
        "</span>" +
        '<span class="new-step-spin" aria-hidden="true"></span>' +
      "</li>" +
    "</ul>");
});

test("newStepsHtml: a done step is a check with no spinner and no caption", () => {
  const html = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "ok", elapsedMs: 1000, caption: "", probes: [] },
  ]);
  assert.equal(html,
    '<ul class="new-steps">' +
      '<li class="new-step done">' +
        '<span class="new-step-dot" aria-hidden="true">&#10003;</span>' +
        '<span class="new-step-body">' +
          '<span class="new-step-label">Creating your server</span>' +
        "</span>" +
      "</li>" +
    "</ul>");
});

// ── timelineHtml (Mount 2 presentation) ─────────────────────────────────────

test("timelineHtml: renders roled steps, per-step elapsed, verify probes, and the failure block", () => {
  const rows = hooks.provisionSteps({ provision_steps: [
    { step: "create", status: "started", at: T(0) },
    { step: "create", status: "failed", at: T(3) },
    { step: "verify", status: "started", at: T(5), detail: "Probing" },
    { step: "verify", status: "progress", at: T(6), detail: "verify.login: 401 in 182ms" },
  ] }, NOW);
  const html = hooks.timelineHtml(rows, { failed: true, failureDetail: "SECRET_KEY_BASE was 32 bytes" });
  assert.match(html, /bp-tl-step--failed/);
  assert.match(html, /bp-tl-step--pending/);
  assert.match(html, /data-step="create"/);
  assert.match(html, /class="bp-tl-elapsed" data-step="create">3s</);
  assert.match(html, /bp-tl-probe">verify\.login: 401 in 182ms/);
  assert.match(html, /bp-tl-fail[\s\S]*SECRET_KEY_BASE was 32 bytes/);
  assert.doesNotMatch(hooks.timelineHtml(rows, { failed: false }), /bp-tl-fail/);
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
  assert.match(root.innerHTML, /bp-tl-steps/);
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
  assert.deepEqual([...hooks.instanceTabs], ["overview", "webhooks"]);
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

test("webhookBannerHtml prints disable_reason + consecutive_failures verbatim + a Re-enable button", () => {
  const html = hooks.webhookBannerHtml({
    auto_disabled_at: "2026-07-03T12:00:00Z",
    disable_reason: "20 consecutive failures (last: 500 Internal Server Error)",
    consecutive_failures: 20,
  });
  assert.match(html, /Auto-disabled/);
  assert.match(html, /20 consecutive failures \(last: 500 Internal Server Error\)/); // verbatim reason
  assert.match(html, /20 consecutive failures<\/span>/); // verbatim count
  assert.match(html, /data-wh-reenable/); // PUT {active:true} via the update capability
  assert.match(html, /notice-error/);
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

test("deliveryRowHtml renders the toned status + a Replay button keyed by event_id", () => {
  const html = hooks.deliveryRowHtml(
    { event_id: 42, last_status_code: 500, last_latency_ms: 182, attempts: 3, updated_at: "2026-07-03T12:00:00Z" },
    "abc", "production");
  assert.match(html, /wh-del-status--danger">500</);
  assert.match(html, /182ms/);
  assert.match(html, /event #42/);
  assert.match(html, /3 attempts/);
  assert.match(html, /data-wh-replay="42"/);
});

test("deliveryRowHtml: a code-less failed_giveup row reads 'failed' (danger), and missing attempts is just a dash", () => {
  const html = hooks.deliveryRowHtml({ event_id: 7, status: "failed_giveup" }, "abc", "production");
  assert.match(html, /wh-del-status--danger">failed</); // no raw failed_giveup jargon
  assert.doesNotMatch(html, /failed_giveup/);
  assert.doesNotMatch(html, /&mdash; attempts/); // absent attempts: no dangling " attempts"
  assert.match(html, /&mdash;<\/span>/);
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
