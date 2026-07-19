// scenarios.mjs — committed fixture scenarios for the Cloud SPA preview harness.
//
// ONE source of truth for every "LOOK AT IT" screen state (charter D63). Both
// consumers import THIS file so a fixture never drifts:
//   • mock.js  — the browser dynamically import()s it and routes window.fetch.
//   • smoke.mjs — node statically imports it and boots app.js against it.
//
// The envelope shapes are derived from the real server serializers, NOT invented:
//   • barkparks[]   ⇐ router.ex `barkpark_json/3` (id,name,slug,url,host,mode,
//                     health_status,agent_status,version,git_commit,last_seen_at,
//                     team_id,suspended,suspended_reason,update_state,
//                     update_running_release,update_latest_release,
//                     update_checked_at,inserted_at,provision_status,
//                     provision_error,deprovision_status,deprovision_error,
//                     provision_steps,provision_console).
//   • provision_steps[] entries ⇐ Registry.append_provision_step: {step,status,
//                     at,detail?} with status ∈ started|done|failed|progress and
//                     step ∈ create|secure|configure|content|verify|ready
//                     (SERVER_STEP_ORDER in app.js).
//   • provision_console[] entries ⇐ append_provision_console: {line,at}.
//   • subscription  ⇐ subscription_json (plan,status,past_due,
//                     cancel_at_period_end,current_period_end,canceled_at,
//                     started_at,is_trial,trial_days_remaining).
//   • me            ⇐ GET /v1/me (user,team,role,onboarding).
//   • sites[]       ⇐ site_json.
//   • audit events  ⇐ audit_json (id,action,actor,target_type,target_id,
//                     metadata,inserted_at); actions drawn from the closed audit
//                     vocabulary (humanAction map in app.js).

// Stable ids so smoke.mjs can deep-link #instance/<id> deterministically.
export const IDS = {
  team: "5b2c1e00-0000-4000-8000-000000000001",
  liveInstance: "5b2c1e00-0000-4000-8000-0000000000a1",
  behindInstance: "5b2c1e00-0000-4000-8000-0000000000a2",
  provisioningInstance: "5b2c1e00-0000-4000-8000-0000000000a3",
  failedInstance: "5b2c1e00-0000-4000-8000-0000000000a4",
  suspendedInstance: "5b2c1e00-0000-4000-8000-0000000000a5",
  // The single-instance provisioning / failed scenarios reuse their own ids.
  soloProvisioning: "5b2c1e00-0000-4000-8000-0000000000b1",
  soloFailed: "5b2c1e00-0000-4000-8000-0000000000b2",
  siteMarketing: "5b2c1e00-0000-4000-8000-0000000000c1",
  siteDocs: "5b2c1e00-0000-4000-8000-0000000000c2",
  // Rollback/redeploy scenarios (deployment_json rows on the marketing site).
  depCurrent: "5b2c1e00-0000-4000-8000-0000000000d1",
  depFailed: "5b2c1e00-0000-4000-8000-0000000000d2",
  depPrior: "5b2c1e00-0000-4000-8000-0000000000d3",
};

// Clock anchor = NOW at module load. Offsets are fixed (so relative strings —
// "20s ago", step durations — read identically on every render), but the anchor
// must be live because app.js computes ELAPSED against Date.now(): a hardcoded
// date would show "configuring · 44640m" a month from now and make every shot
// read as broken. With a live anchor the mid-provision box is always ~3m in.
const T = new Date().toISOString();
const tMinus = (secs) => new Date(Date.parse(T) - secs * 1000).toISOString();

// ── shared row builders (keep every barkpark row envelope-complete) ──────────
function bpBase(over) {
  return Object.assign(
    {
      id: null,
      name: null,
      slug: null,
      url: null,
      host: null,
      mode: "managed",
      health_status: "unknown",
      agent_status: "offline",
      version: null,
      git_commit: null,
      last_seen_at: null,
      team_id: IDS.team,
      suspended: false,
      suspended_reason: null,
      update_state: null,
      update_running_release: null,
      update_latest_release: null,
      update_checked_at: null,
      inserted_at: tMinus(86400),
      provision_status: null,
      provision_error: null,
      deprovision_status: null,
      deprovision_error: null,
      provision_steps: [],
      provision_console: [],
    },
    over,
  );
}

const liveInstance = bpBase({
  id: IDS.liveInstance,
  name: "Production",
  slug: "production",
  url: "production-5b2c1e.barkpark.cloud",
  host: "production-5b2c1e.barkpark.cloud",
  health_status: "up",
  agent_status: "online",
  version: "0.9.2",
  git_commit: "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
  last_seen_at: tMinus(20),
  update_state: "current",
  update_running_release: "0.9.2",
  update_latest_release: "0.9.2",
  update_checked_at: tMinus(600),
  provision_status: "succeeded",
});

const behindInstance = bpBase({
  id: IDS.behindInstance,
  name: "Staging",
  slug: "staging",
  url: "staging-5b2c1e.barkpark.cloud",
  host: "staging-5b2c1e.barkpark.cloud",
  health_status: "up",
  agent_status: "online",
  version: "0.8.4",
  git_commit: "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432",
  last_seen_at: tMinus(45),
  update_state: "behind",
  update_running_release: "0.8.4",
  update_latest_release: "0.9.2",
  update_checked_at: tMinus(300),
  provision_status: "succeeded",
});

// A mid-provision box: create+secure done, configure in flight (active spinner),
// verify/ready still pending. Console tails the worker's live output.
const provisioningSteps = [
  { step: "create", status: "started", at: tMinus(190) },
  { step: "create", status: "done", at: tMinus(150) },
  { step: "secure", status: "started", at: tMinus(150), detail: "issuing TLS for acme-5b2c1e.barkpark.cloud" },
  { step: "secure", status: "done", at: tMinus(96) },
  { step: "configure", status: "started", at: tMinus(96), detail: "writing runtime env + starting Barkpark" },
  { step: "configure", status: "progress", at: tMinus(40), detail: "booting the release" },
];
const provisioningConsole = [
  { line: "provisioning acme-5b2c1e.barkpark.cloud…", at: tMinus(190) },
  { line: "create: server cax11 fsn1 — ok (188.245.0.42)", at: tMinus(150) },
  { line: "secure: DNS A/AAAA published, cert issued", at: tMinus(96) },
  { line: "configure: docker compose up -d", at: tMinus(70) },
  { line: "configure: waiting for the app to answer /up", at: tMinus(40) },
];

const provisioningInstanceRow = bpBase({
  id: IDS.provisioningInstance,
  name: "Analytics",
  slug: "analytics",
  provision_status: "claimed",
  provision_steps: provisioningSteps,
  provision_console: provisioningConsole,
});

// A failed box: verify gate probed the fresh instance and the login check 500'd.
const failedSteps = [
  { step: "create", status: "started", at: tMinus(320) },
  { step: "create", status: "done", at: tMinus(280) },
  { step: "secure", status: "started", at: tMinus(280) },
  { step: "secure", status: "done", at: tMinus(230) },
  { step: "configure", status: "started", at: tMinus(230) },
  { step: "configure", status: "done", at: tMinus(150) },
  { step: "content", status: "started", at: tMinus(150) },
  { step: "content", status: "done", at: tMinus(90) },
  { step: "verify", status: "started", at: tMinus(90) },
  { step: "verify", status: "progress", at: tMinus(80), detail: "verify.api: 200 in 44ms" },
  { step: "verify", status: "progress", at: tMinus(70), detail: "verify.login: 500 in 5031ms" },
  { step: "verify", status: "failed", at: tMinus(68), detail: "verify.login: 500 — Studio never came up" },
];
const failedConsole = [
  { line: "content: seeding starter workspace", at: tMinus(150) },
  { line: "verify: probing api/login/studio", at: tMinus(90) },
  { line: "verify.login: HTTP 500 (Studio boot timed out)", at: tMinus(70) },
  { line: "provision FAILED after 3 attempts", at: tMinus(68) },
];

const failedInstanceRow = bpBase({
  id: IDS.failedInstance,
  name: "Reporting",
  slug: "reporting",
  provision_status: "failed",
  provision_error: "verify.login: 500 — Studio never came up",
  provision_steps: failedSteps,
  provision_console: failedConsole,
});

const suspendedInstance = bpBase({
  id: IDS.suspendedInstance,
  name: "Marketing",
  slug: "marketing",
  url: "marketing-5b2c1e.barkpark.cloud",
  host: "marketing-5b2c1e.barkpark.cloud",
  health_status: "up",
  agent_status: "online",
  version: "0.9.2",
  last_seen_at: tMinus(3600),
  suspended: true,
  suspended_reason: "Payment failed — subscription past due",
  provision_status: "succeeded",
});

// ── sites (site_json) ────────────────────────────────────────────────────────
function site(over) {
  return Object.assign(
    {
      id: null,
      barkpark_id: IDS.liveInstance,
      team_id: IDS.team,
      name: null,
      slug: null,
      framework: "nextjs",
      domains: [],
      scale_mode: "always_on",
      port: 3000,
      current_deployment_id: null,
      github_repo: null,
      github_branch: null,
      github_webhook_configured: false,
      previews_enabled: true,
      inserted_at: tMinus(72000),
      updated_at: tMinus(1200),
    },
    over,
  );
}
const marketingSite = site({
  id: IDS.siteMarketing,
  name: "Marketing",
  slug: "marketing",
  domains: ["acme.com", "www.acme.com"],
  framework: "nextjs",
  github_repo: "acme/marketing",
  github_branch: "main",
  github_webhook_configured: true,
});
const docsSite = site({
  id: IDS.siteDocs,
  name: "Docs",
  slug: "docs",
  domains: ["docs.acme.com"],
  framework: "astro",
});

// ── deployments (deployment_json) ───────────────────────────────────────────
// Envelope from router.ex deployment_json/1: id, site_id, status, git_ref,
// artifact_url, image_tag, build_log_url, failure_reason, became_live_at,
// environment, branch, preview_host, preview_url, console, detail,
// inserted_at, updated_at. Production rows only here (previews have their own
// endpoint); the rollback scenarios key on `status:"live"` +
// site.current_deployment_id, exactly as the SPA's promoteActionFor does.
function deployment(over) {
  return Object.assign(
    {
      id: null,
      site_id: IDS.siteMarketing,
      status: "queued",
      git_ref: null,
      artifact_url: null,
      image_tag: null,
      build_log_url: null,
      failure_reason: null,
      became_live_at: null,
      environment: "production",
      branch: null,
      preview_host: null,
      preview_url: null,
      console: [],
      detail: null,
      inserted_at: tMinus(7200),
      updated_at: tMinus(7000),
    },
    over,
  );
}

// Newest first (the endpoint's order): the CURRENT live deploy, a failed
// attempt, and the PRIOR live deploy — so the site view shows Redeploy on the
// top row, nothing on the failed one, and "Roll back to this" on the oldest.
const depCurrent = deployment({
  id: IDS.depCurrent,
  status: "live",
  git_ref: "9c1f2ab84f00d4e2b16a99871c33d05a72e4f810",
  branch: "main",
  artifact_url: "file:///var/lib/barkpark/artifacts/marketing-9c1f2ab.tar.gz",
  became_live_at: tMinus(5400),
  inserted_at: tMinus(5800),
  updated_at: tMinus(5400),
});
const depFailed = deployment({
  id: IDS.depFailed,
  status: "failed",
  git_ref: "b23aa017c9d8e2f4a6b1305c8d9e0f1a2b3c4d5e",
  branch: "main",
  failure_reason: "npm run build exited 1",
  inserted_at: tMinus(20000),
  updated_at: tMinus(19800),
  console: [
    { line: "cloning acme/marketing @ b23aa01", at: tMinus(20000) },
    { line: "npm ci — ok (34s)", at: tMinus(19960) },
    { line: "npm run build — TypeError: window is not defined", at: tMinus(19820) },
  ],
});
const depPrior = deployment({
  id: IDS.depPrior,
  status: "live",
  git_ref: "4e7d0c9b3a5f18e2d6c4b0a9f8e7d6c5b4a39281",
  branch: "main",
  artifact_url: "file:///var/lib/barkpark/artifacts/marketing-4e7d0c9.tar.gz",
  became_live_at: tMinus(90000),
  inserted_at: tMinus(90400),
  updated_at: tMinus(90000),
});
const rollbackDeployments = [depCurrent, depFailed, depPrior];
// The marketing site with its production pointer on the newest live row.
const marketingSiteDeploys = Object.assign({}, marketingSite, {
  current_deployment_id: IDS.depCurrent,
});

// ── Rollback endgame: the three post-promote states (charter wave-4 owed) ────
// (a) IN-FLIGHT: the promote just succeeded — a freshly-queued build sits on
//     top with its console streaming, while the STILL-LIVE deploy keeps the
//     Current chip (a queued build serves no traffic yet). Exactly the
//     promoteReconcile result the SPA paints optimistically before the refetch.
const depInFlight = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000d4",
  status: "building",
  git_ref: depCurrent.git_ref, // same source as the current row → a redeploy
  branch: "main",
  became_live_at: null,
  inserted_at: tMinus(30),
  updated_at: tMinus(4),
  detail: "building",
  console: [
    { line: "promote → new production deployment (pinned to 9c1f2ab)", at: tMinus(30) },
    { line: "cloning acme/marketing @ 9c1f2ab", at: tMinus(26) },
    { line: "npm ci — installing 214 packages", at: tMinus(9) },
  ],
});
const inFlightDeployments = [depInFlight, depCurrent, depFailed, depPrior];
// The marketing site DURING the promote: pointer still on the old live row, so
// the Current chip has NOT jumped to the building deploy.
const marketingSiteInFlight = Object.assign({}, marketingSite, {
  current_deployment_id: IDS.depCurrent,
});

// (c) MIGRATED: the promoted build went live — the Current chip has MOVED to it
//     and the previously-current row is now a prior live deploy offering "Roll
//     back to this". Proves the chip migrates once the new deploy is live.
const depNowLive = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000d5",
  status: "live",
  git_ref: depCurrent.git_ref,
  branch: "main",
  became_live_at: tMinus(20),
  inserted_at: tMinus(240),
  updated_at: tMinus(20),
});
const migratedDeployments = [depNowLive, depCurrent, depFailed, depPrior];
const marketingSiteMigrated = Object.assign({}, marketingSite, {
  current_deployment_id: depNowLive.id,
});

// ── invitations (GET /v1/invitations/:token preview + POST accept) ──────────
// Preview envelope from router.ex: {team:{name,slug}, email, role, expires_at}.
// The accept POST answers 200 {team_id} | 404 invalid_or_expired | 403
// email_mismatch | 422 accept_failed. `me()` fixtures are on team slug "acme",
// so a preview on slug "acme" reads as already-a-member and any OTHER slug as
// a joinable foreign team.
const tPlus = (secs) => new Date(Date.parse(T) + secs * 1000).toISOString();
const foreignInvitePreview = {
  team: { name: "Northwind Trading", slug: "northwind" },
  email: "ada@acme.com",
  role: "admin",
  expires_at: tPlus(6 * 86400),
};

// ── audit events (audit_json; actions from the closed humanAction vocabulary) ─
function auditEvent(over) {
  return Object.assign(
    {
      id: null,
      action: null,
      actor: { id: "usr_ada", email: "ada@acme.com" },
      target_type: null,
      target_id: null,
      metadata: null,
      inserted_at: null,
    },
    over,
  );
}
// Actions are the closed audit vocabulary (app.js ACTION_LABELS), NOT invented.
const mixedAudit = [
  auditEvent({ id: "ev_5", action: "barkpark.go_live", target_type: "barkpark", target_id: IDS.provisioningInstance, metadata: { name: "Analytics" }, inserted_at: tMinus(190) }),
  auditEvent({ id: "ev_4", action: "site.created", target_type: "site", target_id: IDS.siteDocs, metadata: { name: "Docs" }, inserted_at: tMinus(4000) }),
  auditEvent({ id: "ev_3", action: "subscription.activated", target_type: "subscription", target_id: "sub_1", metadata: { plan: "pro" }, inserted_at: tMinus(80000) }),
  auditEvent({ id: "ev_2", action: "barkpark.deleted", target_type: "barkpark", target_id: "old_box", metadata: { name: "Sandbox" }, inserted_at: tMinus(90000) }),
  auditEvent({ id: "ev_1", action: "token.minted", target_type: "token", target_id: "tok_1", metadata: { name: "CI deploy" }, inserted_at: tMinus(172800) }),
];

// ── instance events + verify runs (event_json: {id,type,payload,inserted_at};
//    types from the closed AgentEvent vocabulary: health status backup tls
//    content verify; verify payload ⇐ Verify.run/1's result envelope) ─────────
function verifyEnvelope(over) {
  const base = {
    ok: true,
    reachable: true,
    verified_at: tMinus(120),
    probes: [
      { name: "verify.api", ok: true, reachable: true, status: 200, latency_ms: 44, evidence: "GET /v1/capabilities → 200 (API up)" },
      { name: "verify.login", ok: true, reachable: true, status: 401, latency_ms: 121, evidence: "POST /v1/auth/login → 401 (auth stack answered; bad creds rejected)" },
      { name: "verify.studio", ok: true, reachable: true, status: 200, latency_ms: 316, evidence: "GET /studio → 200 (renders)" },
    ],
  };
  return Object.assign(base, over);
}
const verifyPass = verifyEnvelope({});
const verifyOneFail = verifyEnvelope({
  ok: false,
  probes: [
    verifyPass.probes[0],
    verifyPass.probes[1],
    { name: "verify.studio", ok: false, reachable: true, status: 502, latency_ms: 5031, evidence: "502 — <html>upstream not ready</html>" },
  ],
});

const ev = (id, type, payload, at) => ({ id, type, payload, inserted_at: at });
// Newest-first, exactly as GET /v1/barkparks/:id/events serves them.
const liveInstanceEvents = [
  ev(9, "verify", verifyPass, tMinus(120)),
  ev(8, "health", { health: "up", disk_used_pct: 41, pg_size_mb: 212, uptime_s: 86000 }, tMinus(300)),
  ev(7, "backup", { status: "ok", size_mb: 88, took_s: 12 }, tMinus(4100)),
  ev(6, "health", { health: "up", disk_used_pct: 41, pg_size_mb: 211 }, tMinus(7300)),
  ev(5, "status", { transition: "online", reason: "agent_report" }, tMinus(80000)),
  ev(4, "tls", { domain: "production-5b2c1e.barkpark.cloud", status: "issued" }, tMinus(86000)),
];
const liveInstanceEventsOneFail = [ev(10, "verify", verifyOneFail, tMinus(60))].concat(liveInstanceEvents.slice(1));
const liveInstanceEventsNoVerify = liveInstanceEvents.slice(1);

// Audit rows scoped to the live instance — what the Timeline's audit half
// contributes (actor attribution beside the machine events).
const liveInstanceAudit = [
  auditEvent({ id: "ev_b2", action: "site.created", target_type: "site", target_id: IDS.siteDocs, metadata: { name: "Docs" }, inserted_at: tMinus(4000) }),
  auditEvent({ id: "ev_b1", action: "barkpark.go_live", target_type: "barkpark", target_id: IDS.liveInstance, metadata: { name: "Production" }, inserted_at: tMinus(86400) }),
];

// ── me / subscription helpers ────────────────────────────────────────────────
// onboarding mirrors onboarding_json (accounts.ex onboarding_status): the step
// vocabulary is CLOSED — subscription | instance | published_doc — and the
// envelope always carries completed/completed_at/last_step/all_done/steps.
function me(teamName, onb) {
  onb = onb || {};
  const steps = [
    // Every scenario that is logged-in carries a subscription fixture, so the
    // subscription step is done unless a scenario opts out explicitly.
    { key: "subscription", done: onb.subscription !== false },
    { key: "instance", done: !!onb.instance },
    { key: "published_doc", done: !!onb.published_doc },
  ];
  return {
    user: { id: "usr_ada", email: "ada@acme.com", confirmed: true, two_factor_enabled: false },
    team: { id: IDS.team, name: teamName, slug: "acme" },
    role: "owner",
    onboarding: {
      completed: !!onb.completed,
      completed_at: onb.completed ? tMinus(80000) : null,
      last_step: onb.last_step || null,
      all_done: steps.every((s) => s.done),
      steps,
    },
  };
}
// A trial rides plan:"trial" with status:"active" — "trialing" is NOT in the
// server's status enum (subscription.ex @statuses: active|canceled|past_due),
// and app.js gates the current-plan panel + launch entitlement on "active".
const trialSub = {
  plan: "trial",
  status: "active",
  past_due: false,
  cancel_at_period_end: false,
  current_period_end: new Date(Date.parse(T) + 14 * 86400 * 1000).toISOString(),
  canceled_at: null,
  started_at: tMinus(3600),
  is_trial: true,
  trial_days_remaining: 14,
};
const activeSub = {
  plan: "pro",
  status: "active",
  past_due: false,
  cancel_at_period_end: false,
  current_period_end: new Date(Date.parse(T) + 20 * 86400 * 1000).toISOString(),
  canceled_at: null,
  started_at: tMinus(30 * 86400),
  is_trial: false,
  trial_days_remaining: null,
};

// ── usage envelope (GET /v1/barkparks/:id/usage — Usage.compose/1 shape) ──────
// Each meter is {value|"unmetered", quota, warn_at, source, measured_at}; a
// numeric quota lights the SPA's OC7 bar (ok/warn/over), a nil quota is honestly
// bar-less. This one envelope carries every quota tone across four meters so a
// single Usage shot proves the whole ladder: instances ok-under-warn, seats warn,
// documents over (+the Manage-plan recovery), datasets metered-but-unlimited.
const m = (value, over) => Object.assign({ value, quota: null, warn_at: null, source: "preview", measured_at: null }, over || {});
const quotaBarsUsage = {
  meters: {
    instances: m(3, { quota: 10, warn_at: 8 }),                     // ok — 30% under the warn line
    seats: m(8, { quota: 10, warn_at: 8, source: "control-plane.team_members", pending_invitations: 1 }), // warn — at warn_at
    documents: m(1240, { quota: 1000, warn_at: 900, source: "instance.documents" }),                       // over — recovery action
    datasets: m(4, { source: "instance.datasets" }),                // metered but unlimited (quota nil) → bar-less
    webhooks: m("unmetered", { source: "instance.webhooks" }),
    db_size: m("unmetered", { source: "telemetry.pg_size_bytes" }),
    disk: m(58, { quota: 100, warn_at: 70, over_at: 90, source: "telemetry.disk_used_percent", measured_at: T }), // healthy 0-100 bar
    // Machine meters (OC23/OC26): cpu OVER its red line (94 ≥ 90, bar not full),
    // ram in the warn band (76 ≥ 70), req_per_s near its rate warn line (bar-less
    // tint), p95_ms not yet reported by the instance runtime (honest unmetered).
    cpu: m(94, { quota: 100, warn_at: 70, over_at: 90, source: "telemetry.cpu_percent", measured_at: T }),
    ram: m(76, { quota: 100, warn_at: 70, over_at: 90, source: "telemetry.mem_used_percent", measured_at: T }),
    req_per_s: m(250, { warn_at: 210, over_at: 270, source: "telemetry.req_per_s", measured_at: T }),
    p95_ms: m("unmetered", { warn_at: 500, over_at: 1000, source: "telemetry.p95_ms" }),
    api_requests: m("unmetered", { source: "not-metered" }),
    bandwidth: m("unmetered", { source: "not-metered" }),
  },
};

// ── usage history (GET /v1/barkparks/:id/usage/history — OC19 Usage.history/2) ─
// The 14-day trend the Wave-4 Usage-tab sparklines paint. Mirrors the Metrics
// envelope: a top-level `series` of {at, value|nil} points, oldest→newest. This
// fixture carries all four honest spark states in one shot so a single Usage shot
// proves the ladder: a FRESH rising series (instances), a FLAT series (seats), a
// GAPPY series with mid-run nulls (documents — the D48 null-is-gap stroke break),
// and an ABSENT/all-null series (datasets → no spark drawn). Derived from the
// same meter names as quotaBarsUsage — NOT invented.
const WINDOW_S = 14 * 24 * 3600;
const histPts = (vals) => vals.map((v, i) => ({
  at: tMinus(Math.round(((vals.length - 1 - i) / Math.max(1, vals.length - 1)) * WINDOW_S)),
  value: v,
}));
const usageQuotaHistory = {
  ok: true,
  collected_at: T,
  window_days: 14,
  points: 6,
  instance: { id: IDS.liveInstance, name: "Acme Production", slug: "acme-prod", host: "acme.barkpark.cloud" },
  series: {
    instances: histPts([1, 1, 2, 2, 3, 3]),                    // fresh, rising toward the ok value
    seats: histPts([8, 8, 8, 8, 8, 8]),                        // flat — draws along the mid-line
    documents: histPts([1100, null, 1180, null, 1210, 1240]),  // gappy — nulls break the stroke
    datasets: histPts([null, null, null, null, null, null]),   // all-null → no spark (honest absence)
    cpu: histPts([61, 68, 74, 82, 88, 94]),                    // machine meter climbing into the red
    ram: histPts([76, 76, 76, 76, 76, 76]),                    // steady warm — flat mid-line
  },
};

// ── fleet usage summary (GET /v1/usage/summary — OC16 sampler read) ───────────
// The Overview fleet strip's contract: a team-level instances quota meter + one
// cached-sample row per instance. This one envelope carries all four honest
// states in a single Overview shot: an OVER-quota team headline (with the
// Manage-plan recovery), a FRESH row (~20s), an hours-STALE row, and a
// NO-SAMPLE row (measured_at null → the honest "no sample yet" cell). Derived
// from the sampler's Usage.compose/1 meter shape — NOT invented.
const fleetMeter = (value, over) => Object.assign({ value, quota: null, warn_at: null, source: "preview", measured_at: null }, over || {});
// The machine capacity beat (cpu/ram) rides the on-box agent, so it carries the
// PHYSICAL ceiling the sampler stamps (quota 100, warn 70). `machine` is
// {cpu, ram} for an armed box, or omitted → the honest un-armed dimmed cell
// (4 of 5 fleet boxes carry no agent — never a fake zero).
const fleetInstMeters = (docs, db, disk, seats, at, machine) => ({
  instances: fleetMeter("unmetered"),
  seats: fleetMeter(seats, { source: "control-plane.team_members", measured_at: at }),
  documents: fleetMeter(docs, { source: "instance.documents", measured_at: at }),
  datasets: fleetMeter("unmetered", { source: "instance.datasets" }),
  webhooks: fleetMeter("unmetered", { source: "instance.webhooks" }),
  db_size: fleetMeter(db, { source: "telemetry.pg_size_bytes", measured_at: at }),
  disk: fleetMeter(disk, { source: "telemetry.disk_used_percent", measured_at: at }),
  cpu: machine
    ? fleetMeter(machine.cpu, { quota: 100, warn_at: 70, source: "agent.cpu_percent", measured_at: at })
    : fleetMeter("unmetered", { source: "agent.cpu_percent" }),
  ram: machine
    ? fleetMeter(machine.ram, { quota: 100, warn_at: 70, source: "agent.ram_percent", measured_at: at })
    : fleetMeter("unmetered", { source: "agent.ram_percent" }),
  api_requests: fleetMeter("unmetered", { source: "not-metered" }),
  bandwidth: fleetMeter("unmetered", { source: "not-metered" }),
});
const fleetUsageSummary = {
  // Team headline OVER its instance ceiling — the one honest quota bar, with the
  // over tone + Manage-plan recovery (OC11/D25).
  team: { instances: fleetMeter(12, { quota: 10, warn_at: 8, source: "control-plane.barkparks" }) },
  instances: [
    // A HOT armed box: RAM pegged at its ceiling (over → the row reddens), CPU
    // past its warn line — the capacity glance the wave exists for.
    { id: IDS.liveInstance, name: "Acme Production", slug: "acme-prod", host: "acme.barkpark.cloud",
      measured_at: tMinus(20), meters: fleetInstMeters(412, 1048576, 37, 4, tMinus(20), { cpu: 88, ram: 100 }) },
    // A calm armed box: CPU/RAM comfortably under their ceilings (live green).
    { id: IDS.behindInstance, name: "Analytics", slug: "analytics", host: "an.barkpark.cloud",
      measured_at: tMinus(3 * 3600), meters: fleetInstMeters(88, 262144, 21, 2, tMinus(3 * 3600), { cpu: 12, ram: 34 }) },
    // An un-armed box: no agent → the honest dimmed "—" capacity cells.
    { id: IDS.suspendedInstance, name: "Staging", slug: "staging", host: "stg.barkpark.cloud",
      measured_at: null, meters: fleetInstMeters("unmetered", "unmetered", "unmetered", "unmetered", null) },
  ],
};

// ── lifecycle capabilities (GET /v1/providers/capabilities) ──────────────────
// The S11b conduit that drives the lifecycle action row: a prod-tier Hetzner
// provider whose archive/resurrect/adopt/audit are CLI affordances, with pause
// gapped by the SERVER-OWNED reason (rendered verbatim). Decommission is always
// console-wired regardless of this payload.
const lifecycleCapabilities = {
  providers: {
    hetzner: {
      tier: "prod",
      capabilities: { archive: true, resurrect: true, adopt: true, audit: true, pause: false },
      gaps: { pause: "Hetzner has no pause primitive — a stopped server still bills, so archive it instead." },
    },
  },
  default_gap: "Not supported by this provider.",
};

// ── domain status (GET /v1/barkparks/:id/domain-status — a DNS-pending host) ──
// A platform host mid-propagation: DNS hasn't resolved (the failed front rung
// carries its own evidence + fix), and the three downstream rungs are all
// blocked on it — they share ONE remediation string. This exercises the render
// dedup: the repeated "Not checked yet…" evidence collapses to the front rung,
// and the three identical remediations collapse to a single amber note.
const dnsPendingDomain = {
  ok: false,
  checked_at: T,
  instance: { id: IDS.liveInstance, host: "production-5b2c1e.barkpark.cloud" },
  domains: [{
    host: "acme.barkpark.cloud", kind: "platform", overall: "failed",
    stages: [
      { stage: "dns", label: "DNS resolves", status: "failed",
        evidence: "No A/AAAA record for acme.barkpark.cloud has propagated yet.",
        remediation: "DNS records take up to a minute to propagate — give it a moment and re-check." },
      { stage: "points", label: "Points to this instance", status: "pending",
        evidence: "Not checked yet — an earlier step isn't passing.",
        remediation: "This domain isn't resolving publicly yet." },
      { stage: "tls", label: "TLS certificate", status: "pending",
        evidence: "Not checked yet — an earlier step isn't passing.",
        remediation: "This domain isn't resolving publicly yet." },
      { stage: "serving", label: "Serving traffic", status: "pending",
        evidence: "Not checked yet — an earlier step isn't passing.",
        remediation: "This domain isn't resolving publicly yet." },
    ],
  }],
};

// ── metrics (GET /v1/barkparks/:id/metrics — a live beat with four vitals) ────
// The S12 Metrics-tab envelope: a live beat + four series (cpu/mem/disk/load).
// Rendered as the aligned stat-card grid with area-filled sparklines.
const metricsLive = {
  ok: true,
  beat: { status: "live", age_seconds: 12 },
  instance: { id: IDS.liveInstance, host: "production-5b2c1e.barkpark.cloud" },
  service_health: { pass: 3, total: 3, failing: [] },
  series: {
    cpu: histPts([21, 28, 24, 39, 52, 47, 63, 58]),
    mem: histPts([46, 48, 49, 51, 53, 54, 55, 57]),
    disk: histPts([69, 70, 71, 71, 72, 73, 74, 74]),
    load: histPts([0.4, 0.7, 0.5, 0.9, 1.2, 0.8, 1.0, 1.1]),
  },
};

// ── the scenario table ───────────────────────────────────────────────────────
// authed:   whether mock.js should seed a session token (false = logged out).
// deepLink: the hash a shot / smoke should open to exercise the scenario's view.
// data:     the fixtures route() answers /v1/* from.
// ── gr-p2 launch theater fixtures (GR18) ─────────────────────────────────────
// Stable ids for the /new resume deep-links (mirrors IDS, kept local to the
// theater scenarios at the tail).
const THEATER_IDS = {
  mid: "5b2c1e00-0000-4000-8000-0000000000e1",
  failed: "5b2c1e00-0000-4000-8000-0000000000e2",
  ready: "5b2c1e00-0000-4000-8000-0000000000e3",
};
// Template envelope ⇐ GET /v1/templates (slug/title/description/what_you_get
// drive the /new card; deployable gates the GitHub affordance on ready).
const theaterTemplate = {
  slug: "astro-blog",
  title: "Astro Blog",
  description: "A fast content blog on Astro, wired to a fully-managed Barkpark.",
  what_you_get: [
    "A managed Barkpark instance with Studio",
    "The Astro blog starter, content included",
    "Instant content updates on your live site",
  ],
  deployable: true,
};
// Catalog envelope ⇐ GET /v1/providers/hetzner/catalog (router.ex: regions[] +
// server_types[].monthly_price + currency). cx22 is the priced row the theater
// resolves for the mid-flight box.
const theaterCatalog = {
  currency: "EUR",
  regions: [{ slug: "fsn1", name: "Falkenstein" }, { slug: "hel1", name: "Helsinki" }],
  server_types: [
    { slug: "cx22", cores: 2, ram_gb: 4, disk_gb: 40, monthly_price: 4.9 },
    { slug: "cx32", cores: 4, ram_gb: 8, disk_gb: 80, monthly_price: 8.9 },
  ],
};
// A theater-shaped failure MID-run: secure broke, so configure/verify/ready
// never ran — the rail must snap (failed red, the rest skipped/dashed).
const theaterFailedSteps = [
  { step: "create", status: "started", at: tMinus(220) },
  { step: "create", status: "done", at: tMinus(180) },
  { step: "secure", status: "started", at: tMinus(180), detail: "issuing TLS for hugin.barkpark.cloud" },
  { step: "secure", status: "failed", at: tMinus(60) },
];
const theaterFailedConsole = [
  { line: "provisioning hugin.barkpark.cloud…", at: tMinus(220) },
  { line: "create: server cx22 fsn1 — ok (188.245.0.87)", at: tMinus(180) },
  { line: "secure: publishing DNS A/AAAA", at: tMinus(170) },
  { line: "secure: ACME order pending — DNS never propagated", at: tMinus(80) },
  { line: "provision FAILED after 3 attempts", at: tMinus(60) },
];

export const SCENARIOS = {
  loggedout: {
    label: "Logged out — the sign-in screen",
    authed: false,
    deepLink: "#overview",
    data: { me: null, barkparks: [], subscription: null, sites: [], audit: [] },
  },
  // NOTE: mock.js clears the seeded session for any scenario named loggedout*
  // (it must decide synchronously, before this module loads) — keep the prefix.
  "loggedout-invited": {
    label: "Logged out with an invite link — the sign-in banner announces the parked invitation",
    authed: false,
    deepLink: "#/invitations/accept?token=tok-preview-signin",
    data: {
      me: null, barkparks: [], subscription: null, sites: [], audit: [],
      invitation: { preview: foreignInvitePreview },
    },
  },
  empty: {
    label: "Fresh team — empty dashboard, first-run onboarding",
    authed: true,
    deepLink: "#overview",
    data: { me: me("Ada's Lab"), barkparks: [], subscription: trialSub, sites: [], audit: [] },
  },
  "mixed-fleet": {
    label: "A real estate — live, provisioning, failed, suspended + sites & activity",
    authed: true,
    deepLink: "#fleet",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, behindInstance, provisioningInstanceRow, failedInstanceRow, suspendedInstance],
      subscription: activeSub,
      sites: [marketingSite, docsSite],
      audit: mixedAudit,
    },
  },
  provisioning: {
    label: "One instance mid-provision — the watched timeline",
    authed: true,
    deepLink: "#instance/" + IDS.soloProvisioning,
    data: {
      me: me("Acme Inc", { instance: true }),
      barkparks: [bpBase({
        id: IDS.soloProvisioning,
        name: "Analytics",
        slug: "analytics",
        provision_status: "claimed",
        provision_steps: provisioningSteps,
        provision_console: provisioningConsole,
      })],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  // ── Usage quota bars (OC7 / D25) ──────────────────────────────────────────
  // The Usage sub-tab with real plan ceilings: an ok bar, a warn bar, an over
  // bar that carries the one Manage-plan recovery action, and a metered-but-
  // unlimited meter that stays honestly bar-less. Deep-links straight to the tab.
  "usage-quota": {
    label: "Usage sub-tab — quota bars across ok / warn / over + an unlimited meter",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/usage",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      usage: quotaBarsUsage,
      usageHistory: usageQuotaHistory,
    },
  },
  // ── Instance Overview — the full restructured panel ───────────────────────
  // A live box whose Overview shows the styled S11b lifecycle action cluster
  // (archive/resurrect/adopt/audit CLI chips + a single "via the bp CLI" caption,
  // pause disabled with its server reason, danger Decommission), the grouped
  // Details rail (Identity / Runtime / Platform / Activity), and the per-host
  // domain checklist with the deduped evidence + collapsed amber remediation.
  "panel-overview": {
    label: "Instance Overview — lifecycle cluster + grouped rail + DNS checklist",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      capabilities: lifecycleCapabilities,
      domainStatus: dnsPendingDomain,
    },
  },
  // ── Metrics tab — the aligned stat-card grid ──────────────────────────────
  "metrics": {
    label: "Metrics tab — CPU / Memory / Disk / Load cards with area-filled sparklines",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/metrics",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      metrics: metricsLive,
    },
  },
  // ── Wave 3: Overview fleet usage strip (OC16/OC18/OC6) ────────────────────
  // Open Overview and the whole fleet's usage answers instantly from cached
  // samples: a team headline over its instance ceiling (with Manage-plan), a
  // fresh row, an hours-stale row, and a no-sample row — all four honest states
  // in one shot. The strip reads /v1/usage/summary, never a live fan-out.
  "fleet-usage": {
    label: "Overview instances grid — real per-instance stats (RAM at ceiling) + the real slots meter",
    authed: true,
    deepLink: "#overview",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, behindInstance, suspendedInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      usageSummary: fleetUsageSummary,
    },
  },
  // ── Webhooks panel (w6 / OC25 / D5) — the FIRST webhook-panel scenario ─────
  // The instance Webhooks sub-tab: the toolbar shell (dataset + New webhook) plus
  // a real endpoint list, each row carrying the full action bar — Edit (w6),
  // toggle, rotate, deliveries, delete. Deep-links straight to the tab so the
  // panel shell + list mount are observable. Click-driven edit/create modals are
  // DOM-tested in __app.test.mjs (smoke's click() is inert).
  "webhooks-panel": {
    label: "Webhooks sub-tab — endpoint list with the Edit action (w6)",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/webhooks",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      webhooks: [
        {
          id: "wh-prod", name: "Prod indexer", url: "https://hooks.acme.com/reindex",
          active: true, events: ["create", "publish"], types: ["post"],
          updated_at: tMinus(3600), consecutive_failures: 0,
        },
        {
          id: "wh-stale", name: "Legacy sync", url: "https://legacy.acme.com/sync",
          active: false, events: [], types: [], updated_at: tMinus(86400),
          consecutive_failures: 0,
        },
      ],
    },
  },
  // ── rollback/redeploy (charter D7 + D25) ──────────────────────────────────
  // The deployment history with promote actions: Redeploy on the current live
  // row, "Roll back to this" on the prior live row, nothing on the failed one.
  // Click an action for the mutate-tier confirm (one consequence sentence).
  rollback: {
    label: "Site detail — rollback/redeploy actions (click one for the mutate confirm)",
    authed: true,
    deepLink: "#site/" + IDS.siteMarketing,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSiteDeploys, docsSite],
      audit: [],
      deployments: rollbackDeployments,
    },
  },
  // Same screen, but the promote POST answers 409 build_in_progress — the
  // confirm renders the human sentence inline + ONE recovery action (never a
  // dead toast). Click an action, then Confirm, to see the failure state.
  "promote-failure": {
    label: "Promote fails honestly — 409 inside the confirm (click an action, then Confirm)",
    authed: true,
    deepLink: "#site/" + IDS.siteMarketing,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSiteDeploys, docsSite],
      audit: [],
      deployments: rollbackDeployments,
      promote: {
        status: 409,
        body: { error: "build_in_progress", detail: "a build for this git ref is already in progress — wait for it to finish" },
      },
    },
  },
  // ── invitation accept terminal states (charter D26 / roadmap 12) ──────────
  // The deepLink carries the token exactly as router.ex accept_url mints it
  // (hash + query). invite-joined lands on the Join confirm; clicking Join
  // reaches the "joined" terminal (accept answers 200).
  "invite-joined": {
    label: "Invitation — valid: the Join confirm, then You're-in after clicking Join",
    authed: true,
    deepLink: "#/invitations/accept?token=tok-preview-valid",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      invitation: {
        preview: foreignInvitePreview,
        accept: { status: 200, body: { team_id: "5b2c1e00-0000-4000-8000-00000000e001" } },
      },
    },
  },
  "invite-expired": {
    label: "Invitation — expired: calm dead-end with one next action",
    authed: true,
    deepLink: "#/invitations/accept?token=tok-preview-expired",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      invitation: {
        preview: Object.assign({}, foreignInvitePreview, { expires_at: tMinus(3600) }),
        accept: { status: 404, body: { error: "invalid_or_expired" } },
      },
    },
  },
  "invite-already-member": {
    label: "Invitation — already a member: nothing to accept, one next action",
    authed: true,
    deepLink: "#/invitations/accept?token=tok-preview-member",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      invitation: {
        // Same slug as the me() fixture's team → the landing classifies
        // already_member without ever POSTing.
        preview: { team: { name: "Acme Inc", slug: "acme" }, email: "ada@acme.com", role: "member", expires_at: tPlus(6 * 86400) },
        accept: { status: 200, body: { team_id: IDS.team } },
      },
    },
  },
  "invite-invalid": {
    label: "Invitation — revoked/used: the preview 404s, honest dead-end",
    authed: true,
    deepLink: "#/invitations/accept?token=tok-preview-revoked",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      invitation: { preview: null },
    },
  },
  failed: {
    label: "A provision that failed at the verify gate",
    authed: true,
    deepLink: "#instance/" + IDS.soloFailed,
    data: {
      me: me("Acme Inc", { instance: true }),
      barkparks: [bpBase({
        id: IDS.soloFailed,
        name: "Reporting",
        slug: "reporting",
        provision_status: "failed",
        provision_error: "verify.login: 500 — Studio never came up",
        provision_steps: failedSteps,
        provision_console: failedConsole,
      })],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  // ── C8: the instance Timeline tab + golden-path verify chips ──────────────
  timeline: {
    label: "Instance Timeline — events + audit merged, verify runs inline",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/timeline",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSite, docsSite],
      audit: liveInstanceAudit,
      instanceEvents: { [IDS.liveInstance]: liveInstanceEvents },
    },
  },
  "timeline-events-only": {
    label: "Timeline as a non-admin — audit 403 degrades to events + one quiet line",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/timeline",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSite, docsSite],
      audit: [],
      auditDenied: true, // /v1/audit → 403 (team-admin-only)
      instanceEvents: { [IDS.liveInstance]: liveInstanceEvents },
    },
  },
  "verify-pass": {
    label: "Verify chips — all three golden-path checks green",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSite, docsSite],
      audit: liveInstanceAudit,
      instanceEvents: { [IDS.liveInstance]: liveInstanceEvents },
    },
  },
  "verify-fail": {
    label: "Verify chips — Studio probe failing (502), rendered honestly",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSite, docsSite],
      audit: liveInstanceAudit,
      instanceEvents: { [IDS.liveInstance]: liveInstanceEventsOneFail },
    },
  },
  "verify-never": {
    label: "Verify chips — never run, the card invites the first check",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSite, docsSite],
      audit: liveInstanceAudit,
      instanceEvents: { [IDS.liveInstance]: liveInstanceEventsNoVerify },
    },
  },
  // ── Rollback endgame: the promote's own three states (charter wave-4 owed) ──
  // IN-FLIGHT: the redeploy just succeeded — the fresh build streams on top while
  // the still-live deploy keeps the Current chip (a queued build serves nothing
  // yet). This is the optimistic promoteReconcile paint, frozen for the eye.
  "promote-in-flight": {
    label: "Promote in flight — the new build streams on top; Current stays on the live deploy",
    authed: true,
    deepLink: "#site/" + IDS.siteMarketing,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSiteInFlight, docsSite],
      audit: [],
      deployments: inFlightDeployments,
    },
  },
  // RETRY: unlike promote-failure (409 → Refresh), a transient 500 offers a live
  // "Try again" — the retry recovery, never a dead spinner. Click an action,
  // then Confirm, to see the inline failure + Try again.
  "promote-retry": {
    label: "Promote fails transiently — the confirm shows Try again (retry recovery)",
    authed: true,
    deepLink: "#site/" + IDS.siteMarketing,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSiteDeploys, docsSite],
      audit: [],
      deployments: rollbackDeployments,
      promote: { status: 500, body: { error: "internal", detail: "the control plane hit an unexpected error" } },
    },
  },
  // MIGRATED: the promoted build went live — the Current chip has MOVED to the
  // new row; the old current is now a prior live deploy offering "Roll back to
  // this". The end of the promote story: the chip only migrates once live.
  "promote-migrated": {
    label: "Post-promote — the Current chip has migrated to the now-live deploy",
    authed: true,
    deepLink: "#site/" + IDS.siteMarketing,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [marketingSiteMigrated, docsSite],
      audit: [],
      deployments: migratedDeployments,
    },
  },
  // ── bp-login-ux W3 (decision 40): the /activate device-login approve page ──
  // Until now every /activate state existed only live behind auth — the 8 PNGs
  // #2111 committed under docs/evidence/login-ux-w2/ were the ONLY witness. These
  // scenarios make each PRE-CLICK skeleton locally renderable. pathname
  // "/activate" unlocks isActivateFlow() (smoke reads scen.pathname); the ?code=
  // search feeds renderActivateApprove's inspect; the `device` fixture answers
  // /v1/auth/device/inspect so the state is real, never the catch-all's 200 {}.
  // The click-driven approved/denied morphs are NOT smokeable (smoke's click() is
  // inert) — they're DOM-tested in __app.test.mjs.
  "activate-entry": {
    label: "Device sign-in — manual code entry (authed, no prefill)",
    authed: true,
    pathname: "/activate",
    data: {},
  },
  "activate-confirm": {
    label: "Device sign-in — confirm which machine is asking (Approve / Deny)",
    authed: true,
    pathname: "/activate",
    search: "?code=ABCD-2345",
    data: {
      device: {
        inspect: {
          status: 200,
          body: {
            client_name: "bp on nimbus.local",
            ip_address: "203.0.113.7",
            user_agent: "bp/1.0 (darwin arm64)",
            expires_at: new Date(Date.now() + 9 * 60000).toISOString(),
          },
        },
      },
    },
  },
  "activate-gone": {
    label: "Device sign-in — the code expired or was already used (404 → gone)",
    authed: true,
    pathname: "/activate",
    search: "?code=ABCD-2345",
    data: { device: { inspect: { status: 404, body: { error: "expired_or_invalid" } } } },
  },
  "activate-rate-limited": {
    label: "Device sign-in — too many attempts (429 → paused retry countdown)",
    authed: true,
    pathname: "/activate",
    search: "?code=ABCD-2345",
    data: { device: { inspect: { status: 429, body: { error: "slow_down" } } } },
  },
  "activate-logged-out": {
    label: "Device sign-in while logged out — the sign-in card banners the parked code",
    authed: false,
    pathname: "/activate",
    search: "?code=ABCD-2345",
    data: {},
  },

  // ── gr-w3 v4 shell: context-morph, fail-closed operator gate, generated picker.
  "shell-root": {
    label: "v4 shell — a workspace route shows the ROOT nav layer (Overview/Fleet/Sites/Activity + Settings)",
    authed: true,
    deepLink: "#overview",
    data: {
      me: me("Acme Inc", { instance: true }),
      barkparks: [liveInstance], subscription: activeSub, sites: [marketingSite], audit: [],
    },
  },
  "shell-instance": {
    label: "v4 shell — entering an instance MORPHS the sidebar to the instance layer + its sections",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true }),
      barkparks: [liveInstance], subscription: activeSub, sites: [], audit: [],
    },
  },
  "shell-site": {
    label: "v4 shell — entering a site MORPHS the sidebar to the site layer",
    authed: true,
    deepLink: "#site/" + IDS.siteMarketing,
    data: {
      me: me("Acme Inc", { instance: true }),
      barkparks: [liveInstance], subscription: activeSub, sites: [marketingSite], audit: [],
    },
  },
  "operator-visible": {
    label: "v4 shell — /v1/me platform_operator:true reveals the sidebar Operator entry (GR9)",
    authed: true,
    deepLink: "#overview",
    data: {
      me: { ...me("Ops Team", { instance: true }), platform_operator: true },
      barkparks: [liveInstance], subscription: activeSub, sites: [], audit: [],
    },
  },
  "identity-iris": {
    label: "v4 shell — the identity picker offers all 5 skins; iris is the active state (GR12)",
    authed: true,
    deepLink: "#overview",
    seedLocal: { bp_theme: "iris" },
    data: {
      me: me("Acme Inc", { instance: true }),
      barkparks: [liveInstance], subscription: activeSub, sites: [], audit: [],
    },
  },

  // ── gr-p2-front-door: the logged-out front door (B-01..B-03). mock.js clears
  // the seeded session for any scenario named loggedout* — keep the prefix.
  "loggedout-signup": {
    label: "Logged out — #signup deep-links straight to the Create-account tab",
    authed: false,
    deepLink: "#signup",
    data: { me: null, barkparks: [], subscription: null, sites: [], audit: [] },
  },
  "loggedout-reset": {
    label: "Password reset — the emailed #/auth/reset?token= link opens the set-new-password card",
    authed: false,
    deepLink: "#/auth/reset?token=demo",
    data: {
      me: null, barkparks: [], subscription: null, sites: [], audit: [],
      reset: { status: 200, body: {} },
    },
  },
  "loggedout-twofactor": {
    label: "Two-factor challenge — submit ANY credentials to swap in the shared 2FA card; a wrong code shows the honest 401",
    authed: false,
    deepLink: "#overview",
    data: {
      me: null, barkparks: [], subscription: null, sites: [], audit: [],
      login: { status: 200, body: { two_factor_required: true, challenge_token: "demo-challenge" } },
      twoFactorChallenge: { status: 401, body: { error: "invalid_code" } },
    },
  },

  // ── gr-p2 plan & dunning (C-03/C-04): trial, past-due dunning, portal return.
  // The past-due subscription fixture is written FRESH here (tail-append law):
  // status past_due with current_period_end 3 days out — mid-grace, so the GR17
  // banner carries both data-driven dates ({failed_date} = −3d ≈ today).
  "billing-trial": {
    label: "Billing — free trial with a running fleet: countdown chip + the ratified keep-it CTA + open plan grid",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Ada's Lab", { instance: true }),
      barkparks: [liveInstance],
      subscription: trialSub,
      sites: [],
      audit: [],
    },
  },
  "billing-past-due": {
    label: "Billing — past due: GR17 dunning banner with data-driven dates + the portal CTA",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: {
        plan: "supporter",
        status: "past_due",
        past_due: true,
        cancel_at_period_end: false,
        current_period_end: new Date(Date.parse(T) + 3 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(60 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
    },
  },
  "billing-portal-return": {
    label: "Billing — back from the Stripe portal (?billing=portal): URL scrub + re-poll + neutral ack",
    authed: true,
    deepLink: "#billing",
    search: "?billing=portal",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      // A REAL catalog plan (activeSub's legacy "pro" predates the catalog and
      // would render feature-less) — a healthy Supporter sub, fresh at the tail.
      subscription: {
        plan: "supporter",
        status: "active",
        past_due: false,
        cancel_at_period_end: false,
        current_period_end: new Date(Date.parse(T) + 20 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(30 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
    },
  },

  // ── gr-p2 launch theater (GR18): the /new journey + the provisioning theater.
  // pathname "/new" unlocks isNewFlow(); ?template selects the starter and &bp=
  // resumes straight into the theater (the refresh-durable URL the flow writes).
  // The mid-flight fixture reports NO freshen/content → the conditional rail's
  // typical 5 rows; the catalog fixture carries the REAL priced row the
  // price-before-charge line resolves (hetzner cx22, €4.9/mo, Falkenstein).
  "new-launch": {
    label: "/new — the signed-in launch step: template card + name + Launch",
    authed: true,
    pathname: "/new",
    search: "?template=astro-blog",
    data: {
      me: me("Ada's Lab"),
      barkparks: [], subscription: trialSub, sites: [], audit: [],
      templates: [theaterTemplate],
    },
  },
  "theater-midflight": {
    label: "/new theater mid-flight — conditional rail (5 rows), price line, live console",
    authed: true,
    pathname: "/new",
    search: "?template=astro-blog&bp=" + THEATER_IDS.mid,
    data: {
      me: me("Ada's Lab", { instance: true }),
      barkparks: [bpBase({
        id: THEATER_IDS.mid,
        name: "Hugin",
        slug: "hugin",
        provider: "hetzner",
        region: "fsn1",
        server_type: "cx22",
        provision_status: "claimed",
        provision_steps: provisioningSteps,
        provision_console: provisioningConsole,
      })],
      subscription: trialSub, sites: [], audit: [],
      templates: [theaterTemplate],
      catalog: theaterCatalog,
    },
  },
  "theater-failed": {
    label: "/new theater failed — the snap: failed step red, rest skipped, one Retry",
    authed: true,
    pathname: "/new",
    search: "?template=astro-blog&bp=" + THEATER_IDS.failed,
    data: {
      me: me("Ada's Lab", { instance: true }),
      barkparks: [bpBase({
        id: THEATER_IDS.failed,
        name: "Munin",
        slug: "munin",
        provision_status: "failed",
        provision_error: "Couldn't secure hugin.barkpark.cloud — the TLS certificate was never issued (DNS didn't propagate). The server exists but isn't serving; nothing else was set up.",
        provision_steps: theaterFailedSteps,
        provision_console: theaterFailedConsole,
      })],
      subscription: trialSub, sites: [], audit: [],
      templates: [theaterTemplate],
    },
  },
  "theater-ready": {
    label: "/new theater ready — the shared ready hero: Open Studio + deploy handoff",
    authed: true,
    pathname: "/new",
    search: "?template=astro-blog&bp=" + THEATER_IDS.ready,
    data: {
      me: me("Ada's Lab", { instance: true }),
      barkparks: [bpBase({
        id: THEATER_IDS.ready,
        name: "Hugin",
        slug: "hugin",
        url: "hugin-5b2c1e.barkpark.cloud",
        host: "hugin-5b2c1e.barkpark.cloud",
        health_status: "up",
        agent_status: "online",
        version: "0.9.2",
        last_seen_at: tMinus(20),
        provider: "hetzner",
        region: "fsn1",
        server_type: "cx22",
        provision_status: "succeeded",
      })],
      subscription: trialSub, sites: [], audit: [],
      templates: [theaterTemplate],
      catalog: theaterCatalog,
    },
  },

  // ── gr-p2 HOME TRIAGE (C-01/C-02): the v4 Overview states (tail-append, OC9) ─
  // Three states of the ONE Overview region: the self-healing trial runway, the
  // attention queue with a real reason, and the past-due money path (GR17 banner
  // + suspended instance-card banner). Fresh fixtures written inline at the tail.
  "overview-trial-runway": {
    label: "Overview trial — the self-healing runway at 2 of 3, real instance-name step hint",
    authed: true,
    deepLink: "#overview",
    data: {
      // subscription + instance steps done, published_doc pending, not completed.
      me: me("Ada's Lab", { instance: true }),
      barkparks: [liveInstance],
      subscription: trialSub,
      sites: [],
      audit: [],
      // A real team ceiling so the header slots meter is honest (never hardcoded).
      usageSummary: {
        team: { instances: { value: 1, quota: 3, warn_at: 2, source: "control-plane.barkparks", measured_at: T } },
        instances: [],
      },
    },
  },
  "overview-attention": {
    label: "Overview attention — a degraded box heads the queue with its real reason + working Open Studio",
    authed: true,
    deepLink: "#overview",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [
        bpBase({
          id: "bp-ov-degraded",
          name: "Reporting",
          slug: "reporting",
          url: "reporting-5b2c1e.barkpark.cloud",
          host: "reporting-5b2c1e.barkpark.cloud",
          health_status: "down",
          agent_status: "offline",
          version: "0.9.2",
          last_seen_at: tMinus(1200),
          provision_status: "succeeded",
        }),
        liveInstance,
      ],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  "overview-past-due": {
    label: "Overview past-due — GR17 overview dunning banner + the suspended instance-card banner (no runway)",
    authed: true,
    deepLink: "#overview",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, suspendedInstance],
      subscription: {
        plan: "supporter",
        status: "past_due",
        past_due: true,
        cancel_at_period_end: false,
        current_period_end: new Date(Date.parse(T) + 3 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(60 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
    },
  },
  // ── gr-p3 D-01: the v4 Fleet list + Archives (screens/01) ──────────────────
  // Density rows across every lifecycle state (degraded / behind+chip / suspended
  // / failed), the NEW backend-true update chip on the behind box, the mono
  // metadata line (region · size · version · channel · autoupdate), and the
  // DISTINCT archives storage-unconfigured state (the server's exact
  // :not_configured copy at 502).
  "fleet-v4": {
    label: "Fleet v4 — density rows across states, the update chip, archives storage-unconfigured",
    authed: true,
    deepLink: "#fleet",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [
        bpBase({
          id: "5b2c1e00-0000-4000-8000-0000000000f1", name: "Gyldendal", slug: "gyldendal",
          url: "gyldendal-506f0.barkpark.cloud", host: "gyldendal-506f0.barkpark.cloud",
          health_status: "down", agent_status: "online", version: "0.2.25",
          update_state: "current", update_latest_release: "0.2.25",
          region: "fsn1", server_type: "cx22", channel: "prod", autoupdate_enabled: true,
          provider: "hetzner", provision_status: "succeeded",
        }),
        bpBase({
          id: "5b2c1e00-0000-4000-8000-0000000000f2", name: "Guerrilla", slug: "guerrilla",
          url: "guerrilla-77a1c.barkpark.cloud", host: "guerrilla-77a1c.barkpark.cloud",
          health_status: "up", agent_status: "online", version: "0.1.0",
          update_state: "behind", update_running_release: "0.1.0", update_latest_release: "0.2.25",
          region: "fsn1", server_type: "cx32", channel: "prod", autoupdate_enabled: true,
          provider: "hetzner", provision_status: "succeeded",
        }),
        bpBase({
          id: "5b2c1e00-0000-4000-8000-0000000000f3", name: "Marketing", slug: "marketing",
          url: "marketing-2b9c4.barkpark.cloud", host: "marketing-2b9c4.barkpark.cloud",
          health_status: "up", agent_status: "online", version: "0.2.25",
          region: "hel1", server_type: "cx22", channel: "prod", autoupdate_enabled: false,
          provider: "azure", suspended: true, suspended_reason: "Payment failed — subscription past due",
          provision_status: "succeeded",
        }),
        bpBase({
          id: "5b2c1e00-0000-4000-8000-0000000000f4", name: "Reporting", slug: "reporting",
          provision_status: "failed", provision_error: "verify.login: 500 — Studio never came up",
          region: "fsn1", server_type: "cx22", provider: "hetzner",
        }),
      ],
      subscription: activeSub,
      sites: [],
      audit: [],
      archives: { status: 502, body: { ok: false, error: "Archive storage isn't configured for this deployment." } },
    },
  },
  "fleet-archives-stored": {
    label: "Fleet Archives — portable bundles listed with a per-provider resurrect",
    authed: true,
    deepLink: "#fleet",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      archives: {
        status: 200,
        body: {
          ok: true,
          archives: [
            {
              fqdn: "shop-9f2c1.barkpark.cloud", slug: "shop", source_provider: "hetzner",
              created_at: tMinus(3 * 86400), bundle_ref: "s3://bundles/shop.tar.zst",
              spec: { region: "fsn1", server_type: "cx22" },
            },
            {
              fqdn: "blog-1a4d7.barkpark.cloud", slug: "blog", source_provider: "azure",
              created_at: tMinus(9 * 86400), bundle_ref: "s3://bundles/blog.tar.zst",
              spec: { region: "hel1", server_type: "cx32" },
            },
          ],
        },
      },
    },
  },
};

export const SCENARIO_NAMES = Object.keys(SCENARIOS);
export const DEFAULT_SCENARIO = "empty";

// route(name, method, path) → { status, body } | null.
//   Returns null for a path this harness does not model, so a caller can decide
//   whether to 404 or pass through. Query strings are ignored (the SPA never
//   depends on server-side filtering for these fixtures).
export function route(name, method, path) {
  const scen = SCENARIOS[name] || SCENARIOS[DEFAULT_SCENARIO];
  const d = scen.data;
  const p = String(path || "").split("?")[0];

  // OAuth provider list is fetched unauthenticated on the sign-in screen.
  if (p === "/v1/auth/oauth/providers") return { status: 200, body: { providers: [] } };

  // gr-p2 launch theater: the /new flow's template read — unauthenticated on
  // the real server too (the badge lands logged-out visitors here).
  if (p === "/v1/templates") return { status: 200, body: { templates: d.templates || [] } };

  // Invitation preview — unauthenticated on the real server too (the accept
  // landing and the sign-in banner both read it before any login).
  const invPreview = p.match(/^\/v1\/invitations\/([^/]+)$/);
  if (invPreview && invPreview[1] !== "accept" && method === "GET") {
    const inv = d.invitation;
    return inv && inv.preview
      ? { status: 200, body: inv.preview }
      : { status: 404, body: { error: "invalid_or_expired" } };
  }

  // gr-p2-front-door: the front door's own unauthenticated POSTs.
  //   • request-reset is ALWAYS the neutral 200 — the real endpoint is
  //     enumeration-safe by design, so the harness must never model a
  //     "no such account" branch either.
  //   • d.login lets a logged-out scenario answer the sign-in submit (the 2FA
  //     preview returns two_factor_required, so submitting ANY credentials
  //     swaps in the shared challenge card).
  //   • d.twoFactorChallenge answers the code submit (the committed fixture is
  //     401 invalid_code — the honest inline error, one click away).
  //   • d.reset answers the set-new-password submit off the emailed link.
  if (method === "POST" && p === "/v1/auth/request-reset") return { status: 200, body: {} };
  if (method === "POST" && p === "/v1/auth/login" && d.login) return d.login;
  if (method === "POST" && p === "/v1/auth/two-factor-challenge" && d.twoFactorChallenge) return d.twoFactorChallenge;
  if (method === "POST" && p === "/v1/auth/reset" && d.reset) return d.reset;

  // Logged out: no authed reads are modelled.
  if (!scen.authed) return { status: 401, body: { error: "unauthorized" } };

  if (p === "/v1/invitations/accept" && method === "POST") {
    return (d.invitation && d.invitation.accept) || { status: 404, body: { error: "invalid_or_expired" } };
  }

  // bp-login-ux W3 (decision 40): the /activate device-login endpoints. A
  // scenario carries a `device` fixture; route() answers inspect/approve/deny
  // from it (mirroring the invitation-stub pattern above). This MUST precede the
  // benign /v1/ catch-all (which returns 200 {}) — otherwise inspect would fold
  // to a DEGENERATE "confirm" ("Unknown device") and no scenario could pin the
  // gone (404) or rate_limited (429) states. inspect 200 body shape =
  // {client_name, ip_address, user_agent, expires_at} (the confirm-screen fields).
  if (method === "POST" && p === "/v1/auth/device/inspect") {
    return (d.device && d.device.inspect) || { status: 404, body: { error: "expired_or_invalid" } };
  }
  if (method === "POST" && p === "/v1/auth/device/approve") {
    return (d.device && d.device.approve) || { status: 200, body: { ok: true } };
  }
  if (method === "POST" && p === "/v1/auth/device/deny") {
    return (d.device && d.device.deny) || { status: 200, body: { ok: true } };
  }

  // Promote (rollback/redeploy). Default: 201 with a fresh queued row minted
  // from the newest fixture deployment; a scenario overrides via d.promote to
  // exercise the failure path.
  if (method === "POST" && /^\/v1\/sites\/[^/]+\/deployments\/[^/]+\/promote$/.test(p)) {
    if (d.promote) return d.promote;
    const src = (d.deployments || [])[0] || {};
    return {
      status: 201,
      body: {
        deployment: Object.assign({}, src, {
          id: "dep-promoted-preview",
          status: "queued",
          became_live_at: null,
          console: [],
          detail: null,
        }),
      },
    };
  }

  if (p === "/v1/me") return d.me ? { status: 200, body: d.me } : { status: 401, body: { error: "unauthorized" } };
  // gr-p2 HOME TRIAGE (C-02): the onboarding fold is member-readable on GET
  // (mirrors /v1/me's fold, so the runway self-heals on refetch); the mutating
  // POST (advance/ack/skip/complete) is owner/admin-only server-side — here it
  // just acks with 200 (the dismiss click is inert in smoke).
  if (p === "/v1/onboarding") {
    if (method === "GET") return { status: 200, body: { onboarding: d.me ? d.me.onboarding : null } };
    return { status: 200, body: { onboarding: d.me ? d.me.onboarding : null } };
  }
  if (p === "/v1/barkparks") return { status: 200, body: { barkparks: d.barkparks } };
  if (p === "/v1/subscription") return { status: 200, body: { subscription: d.subscription } };
  if (p === "/v1/sites") return { status: 200, body: { sites: d.sites } };
  // /v1/audit is team-admin-only server-side; auditDenied models the member's
  // 403 (the Timeline must degrade to events-only, never error).
  if (p === "/v1/audit") {
    return d.auditDenied
      ? { status: 403, body: { error: "forbidden" } }
      : { status: 200, body: { events: d.audit } };
  }

  // Wave 3 (OC16): the fleet usage SUMMARY — the cached-sample read the Overview
  // strip paints. A scenario without a `usageSummary` fixture answers the honest
  // empty shape (no team meter, no rows → the strip hides itself).
  if (p === "/v1/usage/summary") {
    return { status: 200, body: { usage: d.usageSummary || { team: {}, instances: [] } } };
  }

  // C10/OC7: the instance usage envelope (the meter wall the Usage sub-tab paints).
  // A scenario without a `usage` fixture answers the honest all-unmetered v1 shape
  // (never a 404 that would read as "instance gone").
  if (/^\/v1\/barkparks\/[^/]+\/usage$/.test(p)) {
    return { status: 200, body: { usage: d.usage || { meters: {} } } };
  }

  // Wave 4 (OC19): the per-instance usage HISTORY read — the sparkline series. A
  // scenario without a `usageHistory` fixture answers an empty series, so the
  // Usage tab renders bar-less (honest absence, exactly like an older control
  // plane that never shipped the endpoint).
  if (/^\/v1\/barkparks\/[^/]+\/usage\/history$/.test(p)) {
    return { status: 200, body: d.usageHistory || { ok: true, window_days: 14, series: {} } };
  }

  // w6 (OC25): the instance webhooks proxy. The collection GET paints the panel
  // list; a specific-endpoint PUT (the edit modal) echoes the merged row back so
  // a live click reconciles (smoke's click is inert, so only the GET is exercised
  // here — the edit body/pre-fill are unit-tested). The proxy envelope nests the
  // instance body under `data`, exactly like the real control-plane relay.
  const whColl = p.match(/^\/v1\/barkparks\/[^/]+\/api\/webhooks$/);
  if (whColl && method === "GET") {
    return { status: 200, body: { data: { webhooks: d.webhooks || [] } } };
  }
  const whOne = p.match(/^\/v1\/barkparks\/[^/]+\/api\/webhooks\/([^/]+)$/);
  if (whOne && method === "PUT") {
    const cur = (d.webhooks || []).filter((w) => String(w.id) === whOne[1])[0] || { id: whOne[1] };
    return { status: 200, body: { data: { webhook: Object.assign({}, cur) } } };
  }

  // C8: the instance event history (agent events + verify runs, newest first).
  const evMatch = p.match(/^\/v1\/barkparks\/([^/]+)\/events$/);
  if (evMatch) {
    const list = (d.instanceEvents && d.instanceEvents[evMatch[1]]) || [];
    return { status: 200, body: { events: list } };
  }
  // C8: "Check now" — the synchronous verify suite answers a fresh all-pass
  // envelope so the preview's button exercises the full render path.
  if (method === "POST" && /^\/v1\/barkparks\/[^/]+\/verify$/.test(p)) {
    return {
      status: 200,
      body: {
        ok: true,
        reachable: true,
        verified_at: new Date().toISOString(),
        probes: [
          { name: "verify.api", ok: true, reachable: true, status: 200, latency_ms: 38, evidence: "GET /v1/capabilities → 200 (API up)" },
          { name: "verify.login", ok: true, reachable: true, status: 401, latency_ms: 102, evidence: "POST /v1/auth/login → 401 (auth stack answered; bad creds rejected)" },
          { name: "verify.studio", ok: true, reachable: true, status: 200, latency_ms: 288, evidence: "GET /studio → 200 (renders)" },
        ],
      },
    };
  }

  // Single-site drill-down (best-effort, for shots that click a site row).
  const siteMatch = p.match(/^\/v1\/sites\/([^/]+)$/);
  if (siteMatch) {
    const s = d.sites.filter((x) => String(x.id) === siteMatch[1])[0];
    return s ? { status: 200, body: { site: s } } : { status: 404, body: { error: "not_found" } };
  }
  if (/^\/v1\/sites\/[^/]+\/deployments$/.test(p)) return { status: 200, body: { deployments: d.deployments || [] } };
  if (/^\/v1\/sites\/[^/]+\/previews$/.test(p)) return { status: 200, body: { previews: [] } };

  // S11b: the lifecycle-capabilities conduit. A scenario without a `capabilities`
  // fixture answers the empty shape → the row degrades to "capabilities
  // unavailable" (exactly as an older control plane would).
  if (p === "/v1/providers/capabilities") {
    return { status: 200, body: d.capabilities || {} };
  }

  // S13: the per-host DNS/TLS checklist. A scenario without a `domainStatus`
  // fixture answers the honest no-attached-domains shape → the rail keeps its
  // static Domain row (no checklist card).
  if (/^\/v1\/barkparks\/[^/]+\/domain-status$/.test(p)) {
    return { status: 200, body: d.domainStatus || { ok: true, domains: [] } };
  }

  // S12: the Metrics-tab beat + series. A scenario without a `metrics` fixture
  // answers empty → the tab shows the honest "waiting for the first beat" panel.
  if (/^\/v1\/barkparks\/[^/]+\/metrics$/.test(p)) {
    return { status: 200, body: d.metrics || {} };
  }

  // gr-p2 launch theater (GR18(3)): the provider catalog the price-before-charge
  // line resolves against. A scenario without a `catalog` fixture answers the
  // honest 404 no_provider (a managed launch) → the line is OMITTED, exactly as
  // live. MUST precede the /v1/ catch-all (its 200 {} would also omit, but then
  // no scenario could pin the priced state).
  if (method === "GET" && /^\/v1\/providers\/[^/]+\/catalog$/.test(p)) {
    return d.catalog
      ? { status: 200, body: d.catalog }
      : { status: 404, body: { error: "no_provider" } };
  }

  // gr-p3 D-01: the S14 archives read. A scenario carries the FULL {ok,archives|
  // error} envelope GET /v1/archives serves on BOTH 200 and 502 (as `d.archives`);
  // absent → the benign catch-all below (which archivesModel reads as a transient
  // error, exactly like today), so no non-archives scenario changes.
  if (p === "/v1/archives" && d.archives) return d.archives;

  // Anything else under /v1 answers a benign empty 200 so a stray read never
  // trips the 401→logout path or throws mid-render.
  if (p.indexOf("/v1/") === 0) return { status: 200, body: {} };
  return null;
}
