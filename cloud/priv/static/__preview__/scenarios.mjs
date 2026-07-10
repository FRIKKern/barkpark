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

// ── the scenario table ───────────────────────────────────────────────────────
// authed:   whether mock.js should seed a session token (false = logged out).
// deepLink: the hash a shot / smoke should open to exercise the scenario's view.
// data:     the fixtures route() answers /v1/* from.
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
  // ── Wave 3: Overview fleet usage strip (OC16/OC18/OC6) ────────────────────
  // Open Overview and the whole fleet's usage answers instantly from cached
  // samples: a team headline over its instance ceiling (with Manage-plan), a
  // fresh row, an hours-stale row, and a no-sample row — all four honest states
  // in one shot. The strip reads /v1/usage/summary, never a live fan-out.
  "fleet-usage": {
    label: "Overview fleet usage strip — over headline + fresh / stale / no-sample cells",
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

  // Invitation preview — unauthenticated on the real server too (the accept
  // landing and the sign-in banner both read it before any login).
  const invPreview = p.match(/^\/v1\/invitations\/([^/]+)$/);
  if (invPreview && invPreview[1] !== "accept" && method === "GET") {
    const inv = d.invitation;
    return inv && inv.preview
      ? { status: 200, body: inv.preview }
      : { status: 404, body: { error: "invalid_or_expired" } };
  }

  // Logged out: no authed reads are modelled.
  if (!scen.authed) return { status: 401, body: { error: "unauthorized" } };

  if (p === "/v1/invitations/accept" && method === "POST") {
    return (d.invitation && d.invitation.accept) || { status: 404, body: { error: "invalid_or_expired" } };
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

  // Anything else under /v1 answers a benign empty 200 so a stray read never
  // trips the 401→logout path or throws mid-render.
  if (p.indexOf("/v1/") === 0) return { status: 200, body: {} };
  return null;
}
