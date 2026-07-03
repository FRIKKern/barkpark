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
};

// Fixed clock so elapsed math + timestamps read the same on every render.
const T = "2026-07-03T09:00:00Z";
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
function me(teamName) {
  return {
    user: { id: "usr_ada", email: "ada@acme.com", confirmed: true, two_factor_enabled: false },
    team: { id: IDS.team, name: teamName, slug: "acme" },
    role: "owner",
    onboarding: { completed: false, steps: [], all_done: false },
  };
}
const trialSub = {
  plan: "trial",
  status: "trialing",
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
      me: me("Acme Inc"),
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
      me: me("Acme Inc"),
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
  failed: {
    label: "A provision that failed at the verify gate",
    authed: true,
    deepLink: "#instance/" + IDS.soloFailed,
    data: {
      me: me("Acme Inc"),
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

  // Logged out: no authed reads are modelled.
  if (!scen.authed) return { status: 401, body: { error: "unauthorized" } };

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
  if (/^\/v1\/sites\/[^/]+\/deployments$/.test(p)) return { status: 200, body: { deployments: [] } };
  if (/^\/v1\/sites\/[^/]+\/previews$/.test(p)) return { status: 200, body: { previews: [] } };

  // Anything else under /v1 answers a benign empty 200 so a stray read never
  // trips the 401→logout path or throws mid-render.
  if (p.indexOf("/v1/") === 0) return { status: 200, body: {} };
  return null;
}
