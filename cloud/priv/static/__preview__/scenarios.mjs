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
  if (p === "/v1/audit") return { status: 200, body: { events: d.audit } };

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
