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
  URL: URL, // studioLoginHost() parses instance origins with the WHATWG URL API
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

test("newStepsHtml: an active step carries the ring dot, the live pace column, the caption and the spinner", () => {
  const html = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "active", elapsedMs: 1000, caption: "Booting", probes: [] },
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

test("newStepsHtml: a done step is a check with the real elapsed, no spinner and no caption", () => {
  const html = hooks.newStepsHtml([
    { step: "create", label: "Creating your server", role: "ok", elapsedMs: 1000, caption: "", probes: [] },
  ]);
  assert.equal(html,
    '<ul class="new-steps">' +
      '<li class="new-step done" data-step="create">' +
        '<span class="new-step-dot" aria-hidden="true">&#10003;</span>' +
        '<span class="new-step-body">' +
          '<span class="new-step-label">Creating your server</span>' +
        "</span>" +
        '<span class="new-step-time">1s</span>' +
      "</li>" +
    "</ul>");
});

test("newStepsHtml: a pending step shows the plan hint (~expected); an unknown step shows none", () => {
  const html = hooks.newStepsHtml([
    { step: "secure", label: "Securing your domain", role: "pending", elapsedMs: null, caption: "", probes: [] },
    { step: "mystery", label: "mystery", role: "pending", elapsedMs: null, caption: "", probes: [] },
  ]);
  assert.match(html, /<span class="new-step-time">~45s<\/span>/); // secure's estimate
  assert.doesNotMatch(html, /data-step="mystery"[\s\S]*new-step-time/); // no estimate → no hint
  assert.doesNotMatch(html, /new-step-spin[\s\S]*data-step="mystery"|data-step="mystery"[^]*new-step-spin/);
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
  assert.match(html, /<li class="new-step pending" data-step="secure">/);
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
  // C8 registered the Timeline tab between Overview and Webhooks; C10 appended Usage.
  assert.deepEqual([...hooks.instanceTabs], ["overview", "timeline", "webhooks", "usage"]);
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
  // The fixed 8-meter vocabulary, in render order (mirrors Usage.compose/1).
  assert.deepEqual([...hooks.usageMeters.map((m) => m.key)],
    ["seats", "documents", "datasets", "webhooks", "db_size", "disk", "api_requests", "bandwidth"]);
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
  assert.equal((empty.match(/Not yet metered/g) || []).length, 8);
  const metered = hooks.usageMetersHtml({ documents: { value: 7, measured_at: null } });
  assert.match(metered, /<strong>7<\/strong>/);          // real value is bold
  assert.match(metered, /<span class="dim">Not yet metered<\/span>/); // still-empty meters stay dim
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
// The ratified POST-S9 capability-facet payload the /v1/providers/capabilities
// conduit serves (built in parallel by azh-w3-s11-capability-conduit). Shape:
//   { default_gap, providers: { <kind>: { tier?, capabilities:{…}, gaps:{…} } } }
// capabilities keys: core/catalog/labels/pause/archive/resurrect/decommission/
// adopt/audit. This inline sample mirrors the committed cross-surface fixture at
// internal/cli/cloud/providers_capabilities.json (S1) evolved to the facet shape;
// the conduit slice owns cloud/priv/static/__fixtures__/providers_capabilities.json.
const CAP_PAYLOAD = {
  default_gap: "Not available on this provider yet.",
  providers: {
    // hetzner: every lifecycle verb is a seam capability EXCEPT pause (no
    // primitive) — so the wired-later verbs are CLI affordances and pause is a
    // disabled control carrying Hetzner's own gap reason.
    hetzner: {
      capabilities: {
        core: true, catalog: false, labels: true, pause: false,
        archive: true, resurrect: true, decommission: true, adopt: true, audit: true,
      },
      gaps: { pause: "Hetzner has no pause primitive." },
    },
    // azure: adopt carries an explicit gap reason; audit is false WITHOUT a
    // per-verb gap → the model falls back to the payload's own default_gap.
    azure: {
      capabilities: {
        core: true, catalog: true, labels: true, pause: true,
        archive: true, resurrect: true, decommission: true, adopt: false, audit: false,
      },
      gaps: { adopt: "Adopt needs an existing resource-group import." },
    },
    // fake: dev-tier — the console does not operate it (filtered).
    fake: {
      tier: "dev",
      capabilities: {
        core: true, catalog: true, labels: true, pause: true,
        archive: true, resurrect: true, decommission: true, adopt: true, audit: true,
      },
      gaps: {},
    },
  },
};

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

test("S11b: azure model — a false verb with no per-verb gap falls back to the payload default_gap, never invented", () => {
  const bp = { provider: "azure", host: "h", name: "az1" };
  const m = hooks.lifecycleActionsModel(CAP_PAYLOAD, bp);
  const byVerb = Object.fromEntries(plain(m.actions).map((a) => [a.verb, a]));
  assert.equal(byVerb.adopt.mode, "disabled");
  assert.equal(byVerb.adopt.reason, "Adopt needs an existing resource-group import.");
  // audit: capability false, NO per-verb gap → the payload's own default_gap.
  assert.equal(byVerb.audit.mode, "disabled");
  assert.equal(byVerb.audit.reason, "Not available on this provider yet.");
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

// ── S13 domainStages: the per-host DNS/TLS checklist fold ────────────────────
// The pure reducer behind `bp cloud domain status` (Go) and the console Domain
// rail. NEITHER surface probes — both fold the SAME control-plane envelope. The
// four rung roles (ok/active/pending/failed), the active-front promotion, the
// terminal (poll-stop) flag, and the server-owned remediation gate are pinned
// here; the DOM mount + 4s poll are browser-verified.

const DOMAIN_SERVING = {
  ok: true, checked_at: "2026-07-09T10:00:00Z",
  instance: { id: "i1", host: "blog.barkpark.cloud" },
  domains: [{
    host: "blog.barkpark.cloud", kind: "platform", overall: "ok",
    stages: [
      { stage: "dns_found", label: "DNS found", status: "ok", evidence: "A → 91.99.1.2", remediation: "" },
      { stage: "points_here", label: "Points here", status: "ok", evidence: "this instance", remediation: "" },
      { stage: "tls", label: "TLS issued", status: "ok", evidence: "valid", remediation: "" },
      { stage: "serving", label: "Serving", status: "ok", evidence: "HTTPS 200", remediation: "" },
    ],
  }],
};

const DOMAIN_PENDING = {
  ok: false, checked_at: "2026-07-09T10:00:00Z",
  instance: { id: "i1", host: "blog.barkpark.cloud" },
  domains: [{
    host: "shop.example.com", kind: "custom", overall: "pending",
    stages: [
      { stage: "dns_found", label: "DNS found", status: "ok", evidence: "A → 91.99.1.2", remediation: "" },
      { stage: "points_here", label: "Points here", status: "ok", evidence: "this instance", remediation: "" },
      { stage: "tls", label: "TLS issued", status: "pending", evidence: "issuing", remediation: "TLS takes a few minutes — keep this open." },
      { stage: "serving", label: "Serving", status: "pending", evidence: "waiting on TLS", remediation: "" },
    ],
  }],
};

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
  const serving = rows.find((r) => r.stage === "serving");
  // tls: active (non-ok) + has copy → shown, verbatim.
  assert.equal(tls.showRemediation, true);
  assert.equal(tls.remediation, "TLS takes a few minutes — keep this open.");
  // serving: pending (non-ok) but EMPTY remediation → not shown (no dangling row).
  assert.equal(serving.showRemediation, false);
  assert.equal(serving.remediation, "");
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

test("S13: domainChecklistHtml renders one vf-card per host with escaped, role-mapped chips", () => {
  const m = hooks.domainStages(DOMAIN_PENDING, 0);
  const html = hooks.domainChecklistHtml(m, {});
  assert.match(html, /vf-card/);
  assert.match(html, /shop\.example\.com/);
  assert.match(html, /vf-chip--pass/);    // the two ok rungs
  assert.match(html, /vf-chip--unknown/); // active + pending render as neutral chips
  assert.match(html, /TLS takes a few minutes/); // remediation surfaced verbatim
  // The kind chip is present.
  assert.match(html, /custom/);
});

test("S13: domainRungChip escapes a hostile label + evidence (no raw markup leaks)", () => {
  const chip = hooks.domainRungChip({
    role: "failed", label: "<b>x</b>", evidence: "<script>1</script>", remediation: "", showRemediation: false,
  });
  assert.ok(chip.indexOf("<b>x</b>") === -1, "label must be escaped");
  assert.ok(chip.indexOf("<script>") === -1, "evidence must be escaped");
  assert.match(chip, /vf-chip--fail/);
});

test("S13: domainKindChip maps the two known kinds and passes an unknown through", () => {
  assert.equal(hooks.domainKindChip("platform"), "platform");
  assert.equal(hooks.domainKindChip("custom"), "custom");
  assert.equal(hooks.domainKindChip(""), "");
  assert.equal(hooks.domainKindChip("byo"), "byo");
});
