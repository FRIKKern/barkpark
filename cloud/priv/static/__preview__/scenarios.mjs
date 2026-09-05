// scenarios.mjs — committed fixture scenarios for the Cloud SPA preview harness.
//
// ONE source of truth for every "LOOK AT IT" screen state (charter D63). The
// two consumers that RENDER from it import THIS file so a fixture never drifts:
//   • mock.js  — the browser dynamically import()s it and routes window.fetch.
//   • smoke.mjs — node statically imports it and boots app.js against it.
//
// ── TWO-WAY CENSUS RULE — READ THIS BEFORE YOU ADD A SCENARIO ────────────────
// Four committed instruments keep a TWO-WAY census over this file: every
// scenario here must be accounted for over there, AND every account over there
// must name a scenario that still exists here. Add one and teach only some of
// them and the rest REFUSE — in the Console gate, on arrival, not in your
// slice's own gate. That has now cost two waves (wave 20 red-lit the sweep;
// cch-w21-s3 added `fleet-cruel-content`, taught the sweep, and was refused by
// smoke.mjs).
//
// SO: if your change ADDS a scenario name, REMOVES one, or MOVES one to another
// family (its `pathname` / `deepLink` head — see `familyOf` in
// breakpoint-sweep.mjs), your slice's OWN gate must run all four:
//
//   node cloud/priv/static/__preview__/smoke.mjs
//        → exit 1: "CENSUS: N committed scenario(s) have NO expectation and were
//          never run". Teach EXPECTATIONS in smoke.mjs.
//   node cloud/priv/static/__preview__/breakpoint-sweep.mjs
//        → exit 2: UNLISTED / STALE / PROMOTED / DRIFTED. Give it a cell, or a
//          SCENARIO_RESIDUE entry naming why not.
//   node --test cloud/priv/static/__preview__/breakpoint-sweep.test.mjs
//        → the sweep's header-census arm recounts the prose from the derived
//          report, so a moved corpus reds the test file too.
//   node cloud/priv/static/__preview__/member-authority-sweep.mjs
//        → exit 1: "the committed corpus grew to N scenario(s), pinned at M".
//          Re-derive PIN_TOTAL_SCENARIOS by RUNNING it.
//
// Editing a scenario WITHOUT moving the census — a label, a fixture value —
// requires none of them (measured: all four stay at exit 0).
//
// THE CENSUS THAT ENFORCES THIS RULE OVER THIS HEADER:
//   node scripts/preview-census-gate-check.mjs --selftest
// It reads this comment block and reds if the rule or any of the four paths
// above is deleted from it; run with `--changed-from <base> --gate <your gate>`
// it reds when a gate omits an instrument the census delta requires. A comment
// cannot fail on the change it warns about — that check is what makes this one
// falsifiable.
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
//   • provision_console[] entries ⇐ append_provision_console: {line,at}, plus
//                     the OPTIONAL cch-w33-s3 disclosure keys the server writes
//                     when it discarded something: truncated_from (this line is
//                     a 2 KB prefix of an original of that many chars) and
//                     dropped_before (the oldest SURVIVING entry, cumulative
//                     count dropped by the 300-line ring). A deployment
//                     console[] entry carries the same keys, and additionally
//                     stage + status when the builder stamped them.
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
  // cch-w12-followup-login-fixture-gap: the OTHER team. The corpus has always
  // held exactly one, because every scenario is one account's screen — but the
  // one seam this file could not reach (a sign-out followed by a sign-in as
  // somebody else, with no reload in between) needs two, or "the previous
  // team's members" has no second team to be previous TO.
  teamBeta: "5b2c1e00-0000-4000-8000-000000000002",
  liveInstance: "5b2c1e00-0000-4000-8000-0000000000a1",
  behindInstance: "5b2c1e00-0000-4000-8000-0000000000a2",
  provisioningInstance: "5b2c1e00-0000-4000-8000-0000000000a3",
  failedInstance: "5b2c1e00-0000-4000-8000-0000000000a4",
  suspendedInstance: "5b2c1e00-0000-4000-8000-0000000000a5",
  // cch-w61-s2: the box that answered our stored admin credential with a 401.
  refusedInstance: "5b2c1e00-0000-4000-8000-0000000000a6",
  // cch-w45-bl: the box whose TEARDOWN failed. `deprovision_status:"failed"` is
  // the ONLY state instanceLifecycle() folds to removeFailed, and it was null on
  // every row in this file, so the header's whole removeFailed arm — the Retry
  // removal CTA and the deprovision_error banner beside it — rendered nowhere.
  removeFailedInstance: "5b2c1e00-0000-4000-8000-0000000000a7",
  // The single-instance provisioning / failed scenarios reuse their own ids.
  soloProvisioning: "5b2c1e00-0000-4000-8000-0000000000b1",
  soloFailed: "5b2c1e00-0000-4000-8000-0000000000b2",
  siteWeb: "5b2c1e00-0000-4000-8000-0000000000c1",
  siteBlog: "5b2c1e00-0000-4000-8000-0000000000c2",
  // Rollback/redeploy scenarios (deployment_json rows on the acme-web site).
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
// "Envelope-complete" is now a MEASURED claim, not a promise: __app.test.mjs's
// "bpBase declares every key barkpark_json serializes" test parses the key list
// straight out of `defp barkpark_json` in cloud/lib/barkpark_cloud/web/router.ex
// (base map + every `|> merge_*` the pipeline applies) and diffs it against
// Object.keys(bpBase({})). That is why this function is EXPORTED — the test
// reads the real object, not a copy of this list. A field the server starts
// serializing and this builder does not declare reds that test; a field no
// fixture declares is a field no instrument can ever drive
// (cch-backlog-bpbase-envelope-incomplete).
//
// TWO OF THE FOURTEEN KEYS THIS SLICE ADDED MOVE PIXELS, and that is the point,
// not a regression — measured, named, and stated here so nobody "restores" the
// old bytes later:
//   • provider — the schema carries `default: "hetzner"`, so EVERY row the
//     server has ever sent has it. The fleet row's provider chip therefore
//     rendered in only the five scenarios that set it by hand; it now renders
//     everywhere, as it does in production.
//   • last_verified_at / verify_reachable — `fleetVerifyText` (`grep -n
//     "function fleetVerifyText" cloud/priv/static/app.js`) branches on
//     hasOwnProperty, and its own comment says the silent branch "is
//     unreachable against any current server". The corpus was sitting in that
//     unreachable branch; the mono line now ends "· never verified", which is
//     what a real console paints for an unverified box.
// Net effect on overflow-guard: four INFORMATIONAL cells move (#fleet
// mixed-fleet heights at 900/1000, the panel-overview document height at
// 320/390). Every ✓/✗ verdict and every exit code is unchanged.
//
// VALUES ARE THE SERVER'S OWN DEFAULTS, not invented ones — the Ecto schema's
// (`cloud/lib/barkpark_cloud/registry/barkpark.ex`, `grep -n 'field :'`) for
// column-backed keys, and the serializer's documented nil-means-UNMEASURED
// contract for the rest. A wrong default is worse than a missing key: it
// paints a determinate state the control plane never sent.
export function bpBase(over) {
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
      // cch-backlog-bpbase-envelope-incomplete. SINCE WHEN this box has served
      // `git_commit` — the materialised column (dr-w22-bl). NULL is UNMEASURED,
      // never "now": a box that has not changed sha since the column shipped
      // reads null, so a renderer must paint it unmetered and must not sort it
      // as fresh.
      git_commit_first_seen_at: null,
      // The reachability counters behind the health axis. The COLUMN DEFAULTS
      // (registry/barkpark.ex: `default: 0` / `default: false`), never null —
      // null is a third state the control plane has never serialized. A healthy
      // box has missed zero windows and has no outage alert latched.
      unreachable_count: 0,
      unreachable_notification_sent: false,
      team_id: IDS.team,
      // Provider-neutral hosting (charter Decision 9) — identity, never a status
      // axis. `provider` carries the schema's `default: "hetzner"` and is
      // therefore NON-NULL on every row the server has ever sent, including
      // legacy ones; `region`/`server_type` are nullable LAUNCH PINS (the
      // serializer's own words: "wrong or empty on adopted boxes"), so the
      // envelope default is null and a fixture that wants a placement says so.
      provider: "hetzner",
      region: null,
      server_type: null,
      suspended: false,
      suspended_reason: null,
      // cch-w54-bl: SINCE WHEN the suspension holds. NULL means NOT SUSPENDED,
      // never "suspended at an unknown time" — unsuspend clears all three
      // columns together. Consumers must not substitute a billing date for it.
      suspended_at: null,
      // cch-w21-s3: `barkpark_json` (web/router.ex:8371) serializes `custom_host`
      // on EVERY row — null until a team attaches a domain. It belongs in the
      // envelope because `publicUrl()` (`grep -n "function publicUrl" app.js`)
      // PREFERS it over `url`, so a row that merely OMITS the key is a row no
      // fixture can make cruel.
      custom_host: null,
      // The custom domain's LAST VERIFICATION, serialized on every row beside
      // custom_host above. Both null until a team attaches a domain and the
      // verifier runs; `verify_reachable` is a three-valued boolean where null
      // is NOT-YET-CHECKED, distinct from a checked-and-false.
      last_verified_at: null,
      verify_reachable: null,
      update_state: null,
      update_running_release: null,
      update_latest_release: null,
      update_checked_at: null,
      // cch-w61-s2: `barkpark_json` serializes the update probe's typed refusal
      // reason on EVERY row (Registry.persist_update_unknown/2 writes it; the
      // whitelist is Barkpark.update_unavailable_reasons/0). It is null on a box
      // that answered. A fixture that OMITS the key is a fixture in which the
      // refused state cannot exist at all — the whole corpus rendered the Updates
      // panel in exactly ONE state before this row was added.
      update_unavailable_reason: null,
      // dr-w24-s2 COMMIT DISTANCE — the control plane's own measurement of the
      // commit each box serves, a DIFFERENT question from the release-tag grade
      // above (prod carries rows reading distance 2493 / "behind" while
      // update_state is "current"). NULL is UNMEASURED and never 0: an empty
      // git_commit, a 404 on an unknown sha and a rate-limit refusal all land
      // null, and a consumer must render unmetered and sort it to the TOP.
      commit_distance: null,
      commit_ancestry: null,
      commit_distance_checked_at: null,
      // cch-w47-s2 (D529/D515): `barkpark_json` serializes the autoupdate policy
      // block on EVERY row, so a fixture that OMITS these keys makes
      // `hasAutoupdatePolicy` false for the whole corpus — the policy chip and
      // the four policy buttons then render in NO scenario at all, and any
      // guard on them is one that structurally cannot fail. The values are the
      // MIGRATIONS' OWN COLUMN DEFAULTS (20260710160000_add_channel_and_fleet_settings):
      // enabled true, paused false, channel "prod" — never nulls, which are a
      // third state no control plane has ever serialized and which paint a bare
      // "Auto" chip that withholds the channel that IS the policy. Only
      // pinned_release and autoupdate_triggered_at are genuinely nullable.
      autoupdate_enabled: true,
      autoupdate_paused: false,
      channel: "prod",
      pinned_release: null,
      autoupdate_triggered_at: null,
      inserted_at: tMinus(86400),
      provision_status: null,
      provision_error: null,
      deprovision_status: null,
      deprovision_error: null,
      provision_steps: [],
      provision_console: [],
      // Personal Dev Fleet group record (PDF-D61/D92): serialized on EVERY row
      // by barkpark_json — null on an ungrouped main.
      fleet_role: null,
      fleet_parent_id: null,
      fleet_token_id: null,
      // The age in seconds of the OLDEST `queued` container-site deployment on
      // this box; null when none. A NUMBER, never a verdict — the SPA owns the
      // 5-minute deploy_stalled threshold — and always present, so a consumer
      // branches on the VALUE, not the key.
      queued_deploy_age_seconds: null,
      // The host's live resource pressure. Always present on the wire: when a
      // box has never beaten, merge_pressure/2's fallback clause puts
      // @unmetered_pressure — this ALL-NIL map, key for key. HONESTY LAW: an
      // absent probe and the agent's -1 sentinel both read nil (UNMETERED) and
      // never 0, so a box whose agent predates the vitals beat must read "we did
      // not measure", never "measured, and it is fine".
      pressure: {
        cpu_percent: null,
        cpu_cores: null,
        mem_used_percent: null,
        load1: null,
        load15: null,
        req_per_s: null,
        p95_ms: null,
        err_5xx_per_s: null,
        disk_used_percent: null,
        swap_used_percent: null,
        swap_total_bytes: null,
        beam_pss_bytes: null,
        beam_swap_bytes: null,
        beam_pid: null,
        beam_slot: null,
        runaway_procs: null,
        slot_units: null,
        slot_units_truncated: null,
        reported_at: null,
      },
    },
    over,
  );
}

const liveInstance = bpBase({
  id: IDS.liveInstance,
  name: "Production",
  slug: "production",
  // cch-w18-s4 — `url` CARRIES ITS SCHEME, because the column does. The server
  // writes this field as `"https://" <> provisioning_fqdn` at go-live
  // (registry/barkpark.ex `provisioning_url/1`, and `clean_url/1` the same way),
  // so a bare host here was never the envelope — it was a fixture that could not
  // be told apart from one until somebody read the RESOLVED href.
  // WHAT THE BARE HOST DID, DRIVEN (not a code reading): `siteLiveUrl` returns
  // `bp.url` verbatim and `siteOpenLink` drops it into `href`, so every one of
  // the four "Visit ↗" doors on `?scen=sites#sites` and on the instance Sites
  // card emitted `href="production-5b2c1e.barkpark.cloud/sites/acme-web/"` — a
  // RELATIVE reference, which the browser resolved against the page: measured
  // `.href` = `http://localhost:4271/production-5b2c1e.barkpark.cloud/sites/
  // acme-web/`, 4 of 4 doors on THE CONSOLE'S OWN ORIGIN. A person clicking
  // "Open the live site" did not reach the site; they reached a 404 on the
  // console. `host` below stays bare — it IS a hostname, and it is rendered as
  // text, never as an href.
  url: "https://production-5b2c1e.barkpark.cloud",
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
  // cch-w18-s4: schemed, same reason as liveInstance above.
  url: "https://staging-5b2c1e.barkpark.cloud",
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
  // cch-w18-s4: schemed, same reason as liveInstance above.
  url: "https://marketing-5b2c1e.barkpark.cloud",
  host: "marketing-5b2c1e.barkpark.cloud",
  health_status: "up",
  agent_status: "online",
  version: "0.9.2",
  last_seen_at: tMinus(3600),
  suspended: true,
  // cch-w55-s3 — a PLANE-LEGAL reason slug. This fixture used to carry the human
  // sentence "Payment failed — subscription past due", which no producer in
  // cloud/lib can ever write: the only three values written are `billing_lapsed`
  // (Billing.cancel_subscription/1), `billing_past_due` (maybe_enforce/1) and
  // `quota_exceeded` (Billing.reconcile_plan_limit/1), and router.ex:9383 ships
  // the raw column. A fixture vouching for copy the plane cannot emit certifies
  // nothing.
  suspended_reason: "billing_past_due",
  // cch-w54-bl — the stamp `Registry.suspend_barkpark/2` writes and
  // `barkpark_json/5` now serializes. FIXED, never relative to the corpus clock:
  // the card renders this as a calendar day, and this scenario's subscription
  // renews at T+3d, so a stamp that drifted with T could silently land on the
  // renewal day and make the smoke pin below vacuous. A fixed June day cannot.
  suspended_at: "2026-06-12T12:00:00.000Z",
  provision_status: "succeeded",
});

// cch-w61-s2 — THE BOX THAT REFUSED OUR CREDENTIAL. A HOSTED row (the Updates
// panel only renders when a box has a host, which is why the corpus's two
// hostless deep-links rendered no panel at all), carrying the state the hourly
// update probe writes when the box answers our stored admin credential with a
// 401: update_state "unknown" + update_unavailable_reason "identity_refused",
// stamped 45 minutes ago.
//
// KEYED ON id AND host, NEVER ON NAME OR SLUG. The live subject shares its name
// with two other rows on the fleet; a reader that picks by name picks an
// arbitrary one of the three, and the assertion silently becomes a statement
// about the wrong box. `167.233.194.23` is a bare-IP host on purpose — that is
// what the subject actually serves on, and it also proves publicUrl() renders a
// schemeless host without inventing a domain.
const credentialRefusedInstance = bpBase({
  id: IDS.refusedInstance,
  name: "Gyldendal",
  slug: "gyldendal",
  url: "https://167.233.194.23",
  host: "167.233.194.23",
  health_status: "unknown",
  agent_status: "offline",
  version: "0.9.1",
  last_seen_at: tMinus(45 * 60),
  update_state: "unknown",
  update_unavailable_reason: "identity_refused",
  update_checked_at: tMinus(45 * 60),
  provision_status: "succeeded",
});

// cch-w45-bl — THE BOX WHOSE TEARDOWN FAILED. `Registry.mark_deprovision_failed`
// writes deprovision_status "failed" + the worker's verbatim deprovision_error,
// and `barkpark_json` serializes both. instanceLifecycle() folds exactly that
// pair to `removeFailed`, which is the ONE state that paints
// `id="inst-remove-retry"` (DELETE /v1/barkparks/:id, `admin`) — and it was
// unreachable from the committed corpus, so the guard on it was green by
// construction.
//
// `host` stays SET on purpose: a teardown that failed is a teardown that left
// the server standing, and removeFailed wins over every other fold in
// instanceLifecycle regardless — a hostless row would render the same header and
// hide that the box is still up. NOT `status:"remove_failed"`: measured, that
// renders nothing at all; the fold reads deprovision_status and only that.
const removeFailedInstance = bpBase({
  id: IDS.removeFailedInstance,
  name: "Retired",
  slug: "retired",
  url: "https://retired-5b2c1e.barkpark.cloud",
  host: "retired-5b2c1e.barkpark.cloud",
  health_status: "down",
  agent_status: "offline",
  version: "0.9.2",
  last_seen_at: tMinus(3 * 3600),
  update_state: "current",
  update_running_release: "0.9.2",
  update_latest_release: "0.9.2",
  update_checked_at: tMinus(3 * 3600),
  provision_status: "succeeded",
  deprovision_status: "failed",
  deprovision_error: "hcloud: server delete returned 409 (a volume is still attached)",
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
      // ssw8 (charter D82): the ELEVEN binding fields site_json/2 serializes.
      // The factory emitted 21 fields and NOT ONE of them was a binding field,
      // so no fixture could express binding truth at all. Shape derived from
      // router.ex site_json/2, not invented:
      //   kind · framework's runtime target      template · the starter it deploys
      //   doc_type · the featured type           port_base · node-slot base (static → null)
      //   bootstrap_{workspace,project,dataset} + the CLI spelling of the SAME
      //   three columns (workspace/project/dataset) — one row, both vocabularies
      //   content_bound · `not is_nil(read_token_encrypted)`, i.e. A READ TOKEN
      //     EXISTS. NOT "this site has content".
      // Defaults are the UNBOUND site (a plain GitHub-repo deploy): no triple,
      // no token. Bound rows override.
      kind: "node",
      template: null,
      doc_type: null,
      port_base: null,
      bootstrap_workspace: null,
      bootstrap_project: null,
      bootstrap_dataset: null,
      workspace: null,
      project: null,
      dataset: null,
      content_bound: false,
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
const webSite = site({
  id: IDS.siteWeb,
  name: "acme-web",
  slug: "acme-web",
  domains: ["acme.com", "www.acme.com"],
  framework: "nextjs",
  github_repo: "acme/web",
  github_branch: "main",
  github_webhook_configured: true,
});
const blogSite = site({
  id: IDS.siteBlog,
  name: "acme-blog",
  slug: "acme-blog",
  domains: ["blog.acme.com"],
  framework: "astro",
});

// ── ssw8 (charter D82): the three content-binding cases ──────────────────────
// A spawned static site's whole reason to exist is the dataset it reads. These
// three rows are the states that binding can actually be in, all expressible
// from site_json/2's own fields:
//
//   BOUND     — the triple agrees with itself and a read token exists.
//   UNKNOWN   — an OLDER control plane: no triple, and `content_bound` is
//               ABSENT (not false). The surface must say "unknown", never
//               "default/default/production" — the plausible-default lie.
//   MISMATCH  — site_json/2 sends the SAME three columns twice (bootstrap_* and
//               the CLI spelling). Here they DISAGREE, which is exactly what a
//               stranger's mistyped `--dataset` looks like after a partial
//               rebind. The surface must show BOTH and resolve neither.
const boundSite = site({
  id: "5b2c1e00-0000-4000-8000-0000000000cb",
  name: "acme-docs", slug: "acme-docs", domains: ["docs.acme.com"],
  framework: "astro", kind: "static", template: "astro-starter",
  doc_type: "paper",
  bootstrap_workspace: "acme", bootstrap_project: "site", bootstrap_dataset: "production",
  workspace: "acme", project: "site", dataset: "production",
  content_bound: true,
});
// `content_bound` is DELETED, not false: a control plane that predates the field
// says nothing, and "nothing" must not be read as "no".
const unknownBindingSite = (() => {
  const s = site({
    id: "5b2c1e00-0000-4000-8000-0000000000cc",
    name: "acme-legacy", slug: "acme-legacy", domains: [],
    framework: "astro", kind: "static",
  });
  delete s.content_bound;
  return s;
})();
const mismatchedBindingSite = site({
  id: "5b2c1e00-0000-4000-8000-0000000000cd",
  name: "acme-typo", slug: "acme-typo", domains: [],
  framework: "astro", kind: "static", doc_type: "post",
  // The rebind wrote the CLI spelling; the bootstrap columns still hold the old
  // dataset. A 201 was returned for this site and every surface has agreed with
  // it ever since.
  bootstrap_workspace: "acme", bootstrap_project: "site", bootstrap_dataset: "producton",
  workspace: "acme", project: "site", dataset: "production",
  content_bound: true,
});
const bindingSites = [boundSite, unknownBindingSite, mismatchedBindingSite];

// E-01 (#sites list): the LIST endpoint embeds a slim `last_deployment`
// (status · trigger · stamps — never content_rev, HONESTY LAW) via
// put_last_deployment, which the row's freshness pill reads. Detail fixtures
// above don't carry it (detail fetches /deployments), so the list scenario
// gets its own states-complete rows: live / rebuilding / deploy-failed /
// never-deployed — one per pill role. Real fields only; the invented
// Marketing/Docs "kind" taxonomy has no field to render.
const lastDeploy = (status, trigger, ago) => ({
  status,
  trigger,
  updated_at: tMinus(ago),
  inserted_at: tMinus(ago + 120),
});
// cch-w16-s4 (charter D199) — THE FIXTURE FIDELITY REPAIR. Until this slice
// `site()` defaulted `current_deployment_id: null` and NOT ONE list row
// overrode it, so the corpus asserted a state the SERVER CANNOT PRODUCE: pill
// "Live" beside a null production pointer. The server moves that pointer only
// after the box confirms a live flip, so ANY row whose deploy history reached
// live once — live, rebuilding-over-a-previous-build, failed-over-a-last-good,
// cancelled-over-a-last-good — carries a non-null pointer. Only a site that has
// never served a build has null.
// D182's census RESTATED with this diff: the corpus held 44 site rows, 40 of
// them null-pointered, and ZERO preview-only sites. This diff sets the pointer
// on the four deployed list rows and adds the first preview-only row, so the
// list corpus is now 6 site rows / 2 null (acme-labs never-deployed +
// acme-previews preview-only) / 1 preview-only.
const depOf = (n) => "5b2c1e00-0000-4000-8000-0000000000e" + n;

// cch-w24-s7 — the cruel site strings, built by concatenation so the lengths
// that make them cruel are auditable in the source rather than counted by eye.
// `atLength` is the guard that can lose: shorten any of these back to a
// comfortable string and every consumer of this module refuses on load, naming
// the constant and both numbers. A cruel fixture that quietly stops being cruel
// is the exact failure mode this slice exists to prevent.
function atLength(what, s, n) {
  if (s.length !== n) {
    throw new Error(
      "cruel fixture " + what + " is " + s.length + " chars, must be exactly " + n +
      " — that length IS the derivation (see the cruel site row's header); fix the string, not the number",
    );
  }
  return s;
}
// 255 = Site.changeset/2 validate_length(:name, max: 255). One token, no space.
const CRUEL_SITE_NAME = atLength("site name",
  "AcmeCorporateMarketingPlatformProductionContentDeliveryEdgeGateway" +
  "CustomerFacingExperienceClusterPrimaryIngressNode" +
  "NorthernEuropeanRegionalStaticAssetOriginForAcmeCommerce" +
  "InternalGroupHoldingsInfrastructureRenderedWithoutOneSingleSpaceCharacterAnywhere260", 255);
// 63 = the DNS label ceiling, and Barkpark.changeset/2's validate_length(:slug,
// max: 63) — the slug POST /v1/launch hands to clean_url/1 UNSUFFIXED.
const CRUEL_SITE_SLUG = atLength("site slug",
  "acmecorporateplatformproductioncontentdeliveryedgegatewaynode01", 63);
// 253 = validate_domains/1's cap, as 63 + 63 + 63 + 61 unbroken labels.
const CRUEL_SITE_DOMAIN = atLength("site domain", [
  CRUEL_SITE_SLUG,
  "northerneuropeanregionalstaticassetoriginforacmecommerceeu0231x",
  "customerfacingmarketingexperienceclusterprimaryingressnodea19x1",
  "internalacmegroupholdingsinfrastructureexampledomainnamecorpg",
].join("."), 253);
// cch-w50 (task-696a2fcf95e9c4da) — THE TWO SHAPES cch-w24-s7 DID NOT CARRY.
//
//   THE 511-CHAR `github_repo@github_branch` SPAN — the compact `siteRow`'s
//     `.site-meta .mono` (app.js: `'<span class="mono">' + esc(s.github_repo) +
//     (s.github_branch ? "@" + esc(s.github_branch) : "")`). It is the ONLY one
//     of the row's three text hosts that the global list does not also paint,
//     and nothing in this corpus had ever driven it past 18 characters.
//     THE FILING SAYS "two independent 255 caps"; ONLY ONE OF THEM IS A
//     CHANGESET RULE. Re-derived by symbol on this tree:
//       `validate_length(:github_branch, max: 255)`  — registry/site.ex:252
//       `validate_github_repo/1`                     — registry/site.ex:341-355,
//         a FORMAT check (`@github_repo_format`, owner/repo) with NO length
//         clause at all; github_repo's only cap is the column,
//         `add :github_repo, :string` (varchar(255)) in
//         20260627160000_add_github_to_sites.exs. So the span's ceiling is
//         255 + 1 + 255 = 511, but a length census over site.ex sees only half
//         of it — the same census blindness the 253-char domain has.
//       Re-derive: grep -n 'validate_github_repo\|validate_length(:github_branch' \
//         cloud/lib/barkpark_cloud/registry/site.ex
//     HONESTY: 255/255 is what the CONTROL PLANE accepts and stores. GitHub
//     itself would not mint a 255-char `owner/repo` (39-char owner, 100-char
//     repo are its own ceilings) — this span is FORMAT-legal and storable, not
//     registrable, exactly as the 253-char domain is. The branch half needs no
//     such caveat: git has no practical ref-name ceiling and a generated
//     release ref is the realistic producer.
//     NO HYPHEN, NO DOT, NO SECOND SLASH — and that is the whole point, MEASURED
//     rather than assumed. The first draft of this pair was the ordinary
//     kebab-case shape (`acme-corporate-…/…-static-asset-origin` @
//     `release/2026-09/…`) and it made the leg that guards this host VACUOUS:
//     deleting `.site-meta .mono`'s `overflow-wrap: anywhere` from app.css and
//     re-driving all 20 cells gave exit 0, because `-` and `/` are CSS break
//     opportunities and the default wrap already broke the span. `anywhere`
//     only earns its line against a run with NOTHING to break on, which is what
//     app.css's own comment beside that rule claims is reachable ("a 511-char
//     unbreakable token"). `@github_repo_format` is `[A-Za-z0-9._-]+/[A-Za-z0-9._-]+`
//     — separators are PERMITTED, never required — so CamelCase on both halves
//     is as legal as the kebab shape and is the one that bites.
const CRUEL_SITE_REPO = atLength("site github_repo", [
  "AcmeCorporateMarketingPlatformEngineeringGroupHoldings",
  "/",
  "CorporateMarketingPlatformProductionContentDeliveryEdgeGateway",
  "CustomerFacingExperienceClusterPrimaryIngressNorthernEuropean",
  "RegionalStaticAssetOriginForAcmeCommerceMonorepo01",
  "AndInternalInfrastructure01",
].join(""), 255);
const CRUEL_SITE_BRANCH = atLength("site github_branch", [
  "release202609AcmeCorporateMarketingPlatformProductionContent",
  "DeliveryEdgeGatewayCustomerFacingExperienceClusterPrimary",
  "IngressNorthernEuropeanRegionalStaticAssetOriginRebuildAfter",
  "TheQuarterlyRegistryMigrationStepTwoOfFourNoSeparatorsAt0139x",
  "PhaseThreeOfSeven",
].join(""), 255);
// THE CRUELTY IS SHAPE AS WELL AS LENGTH, so it is asserted as shape: the only
// break opportunity in the whole 511-character span is the single `/` the
// owner/repo format REQUIRES. A future retune that reaches 511 with hyphens in
// it is still 511 characters long and no longer bites — that is exactly the
// silent regression `atLength` cannot see, so it is checked here.
for (const [what, v] of [["github_repo", CRUEL_SITE_REPO], ["github_branch", CRUEL_SITE_BRANCH]]) {
  const seps = v.replace(/[A-Za-z0-9]/g, "");
  const want = what === "github_repo" ? "/" : "";
  if (seps !== want) {
    throw new Error(
      "cruel fixture: " + what + " carries the break opportunit" + (seps.length === 1 ? "y" : "ies") +
      " \"" + seps + "\", expected \"" + want + "\" — a separator makes the 511-char span breakable by the " +
      "DEFAULT wrap, which makes the .site-meta .mono guard vacuous (measured: exit 0 with the rule deleted)",
    );
  }
}
// The span the row actually paints, asserted here so a reader does not have to
// add two numbers and a separator by eye.
export const CRUEL_SITE_REPO_SPAN_LEN =
  CRUEL_SITE_REPO.length + 1 + CRUEL_SITE_BRANCH.length;
if (CRUEL_SITE_REPO_SPAN_LEN !== 511) {
  throw new Error("cruel fixture: the .site-meta .mono span is " + CRUEL_SITE_REPO_SPAN_LEN + " chars, must be 511");
}

//   THE 66-CHAR HOST WHOSE FIRST BREAK OPPORTUNITY IS AT CHARACTER 63 — the
//     SHAPE axis, not the length axis. The 253-char domain above is long enough
//     that any narrow column fails on it for the boring reason; this one is
//     SHORT and still unbreakable across a phone column, which is the case a
//     width-only remedy passes and a wrap-only remedy fails.
//     THE FILING ASKED FOR A "66-CHAR SINGLE-LABEL HOST" AND THAT STRING IS NOT
//     SERVER-LEGAL: `@domain_format` (registry/site.ex:28) is
//     `^label(\.label)+$` — the `+` makes at least one dot MANDATORY, so a
//     single-label domain is refused by `validate_domains/1` outright, and 66
//     is over the 63-octet DNS label ceiling besides. The nearest thing the
//     server does accept, and the one that carries the filing's intent, is a
//     66-character host that is ONE 63-character label plus a two-letter TLD:
//     `<63>.io`. Its leading run is the same 63-char unbroken token
//     `CRUEL_SITE_SLUG` already justifies (clean_url/1 emits it verbatim
//     through the non-admin POST /v1/launch), and the whole host is 66 chars
//     with exactly one break opportunity in it, at char 63.
//     Re-derive: grep -n '@domain_format' cloud/lib/barkpark_cloud/registry/site.ex
const CRUEL_SITE_HOST_ONE_LABEL = atLength("site one-label host",
  CRUEL_SITE_SLUG + ".io", 66);

// EXPORTED so overflow-guard.mjs's W50 leg DERIVES the strings it expects to
// find on the page instead of transcribing them. A transcribed expectation
// rots silently the first time a constant above is retuned; a derived one
// cannot. `CRUEL_SITE_ROW_ID` is the row the leg has to be able to point at —
// the harness reads it off `.site-row[data-id]`.
export const CRUEL_SITE_STRINGS = {
  name: CRUEL_SITE_NAME,
  slug: CRUEL_SITE_SLUG,
  domain: CRUEL_SITE_DOMAIN,
  oneLabelHost: CRUEL_SITE_HOST_ONE_LABEL,
  repo: CRUEL_SITE_REPO,
  branch: CRUEL_SITE_BRANCH,
  repoSpanLen: CRUEL_SITE_REPO_SPAN_LEN,
};
export const CRUEL_SITE_ROW_ID = "5b2c1e00-0000-4000-8000-0000000000c9";
export const ONE_LABEL_HOST_ROW_ID = "5b2c1e00-0000-4000-8000-0000000000ca";

const sitesListRows = [
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000c3",
    name: "acme-web", slug: "acme-web", domains: ["acme.com", "www.acme.com"],
    framework: "nextjs", github_repo: "acme/web", github_branch: "main",
    github_webhook_configured: true,
    current_deployment_id: depOf(3),
    last_deployment: lastDeploy("live", "content-auto", 900),
  }),
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000c4",
    name: "acme-blog", slug: "acme-blog", domains: ["blog.acme.com"],
    framework: "astro", github_webhook_configured: true,
    // A content publish is rebuilding this static site right now — the PREVIOUS
    // build is still being served, so the production pointer still names it.
    // This row is why the gate cannot be `last_deployment.status === "live"`.
    current_deployment_id: depOf(4),
    last_deployment: lastDeploy("building", "content-auto", 20),
  }),
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000c5",
    name: "acme-shop", slug: "acme-shop", domains: ["shop.acme.com"],
    framework: "nextjs", github_repo: "acme/shop", github_branch: "main",
    github_webhook_configured: true,
    // A failed deploy never moves the pointer: the last good build is still
    // serving. Its door is WORKING and must stay.
    current_deployment_id: depOf(5),
    last_deployment: lastDeploy("failed", "manual", 3600),
  }),
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000c6",
    name: "acme-labs", slug: "acme-labs", domains: [],
    framework: "nextjs", github_webhook_configured: false,
    // Never deployed — no last_deployment, so the pill reads a neutral
    // "Not deployed" (no invented green).
  }),
  // cch-w14-s6: the CANCELLED freshness label #8608 shipped had never been
  // rendered by any harness — lastDeploy() covered live/building/failed/never
  // only. A production deploy CAN end cancelled (the reaper, an operator
  // cancel), and freshnessModel spells it "Cancelled" with a neutral pill:
  // no invented green, no invented red. (After cch-w14-s6 the embed is
  // production-only, so this row is a cancelled PRODUCTION deploy — a torn-down
  // branch preview can no longer reach this slot.)
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000c7",
    name: "acme-guides", slug: "acme-guides", domains: ["guides.acme.com"],
    framework: "astro", github_webhook_configured: true,
    // A cancel does not tear down what is already serving, so the pointer holds.
    current_deployment_id: depOf(7),
    last_deployment: lastDeploy("cancelled", "manual", 1800),
  }),
  // cch-w64-s6: the SEVENTH server status, and the one the corpus could not
  // render at all — `lastDeploy()` had covered live/building/failed/cancelled/
  // never, so the state a live head-of-stream census found on 3 of 12 production
  // sites (oldest 93s old, all three carrying the box's 409 sentence) had never
  // reached a pixel here. `deferred` means the BOX refused this build and the
  // plane re-queued the rebuild; the previous build is still being served, so
  // the production pointer holds and this row keeps its door — the same rule
  // the failed and rebuilding rows above follow.
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000ca",
    // cch-w50: this row's host is the 66-char ONE-LABEL-PLUS-TLD shape (see
    // CRUEL_SITE_HOST_ONE_LABEL above). It is CARRIED BY AN EXISTING ROW ON
    // PURPOSE: `sitesListRows` is read positionally and by count by five
    // FIXTURE_SHAPE_PINS and by two smoke scenarios, so a new row costs a
    // five-pin edit while a swapped `domains` value costs none — and neither
    // smoke check names "media.acme.com" (the `sites` check keys acme-media by
    // its NAME, the `sites-on-instance` check names four other hosts).
    // Nothing else about this row moves: still deferred, still deployed, still
    // one domain, so `siteExtraDomains` stays 0.
    name: "acme-media", slug: "acme-media", domains: [CRUEL_SITE_HOST_ONE_LABEL],
    framework: "astro", github_webhook_configured: true,
    current_deployment_id: depOf(8),
    last_deployment: lastDeploy("deferred", "content-auto", 240),
  }),
  // cch-w15-bl-preview-only-site-fixture-missing, closed HERE: the corpus held
  // ZERO preview-only sites, so the population the Visit-link defect was widest
  // on — a site with branch previews and no production release — could not be
  // driven at all. It has previews on, a slug (so siteLiveUrl MANUFACTURES a
  // production URL for it out of the instance host), and NO production
  // deployment: null pointer, no last_deployment. It must read "Not deployed"
  // AND offer no production door, even though a URL is derivable for it. This
  // is the row that proves the gate is the DEPLOYMENT fact and not "has a URL".
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000c8",
    name: "acme-previews", slug: "acme-previews", domains: [],
    framework: "nextjs", github_repo: "acme/previews", github_branch: "main",
    github_webhook_configured: true, previews_enabled: true,
  }),
  // cch-w24-s7 — THE CRUEL SITE ROW. Every string below is DERIVED from a cap a
  // non-admin caller can actually reach; nothing here is invented cruelty.
  //
  //   NAME, 255 chars, ONE unbroken token — `Site.changeset/2`'s own
  //     `validate_length(:name, min: 1, max: 255)`. A pasted title with the
  //     spaces eaten is the realistic producer, so this is a FORMAT-legal
  //     generator (a readable phrase concatenated), not `"x".repeat(255)`.
  //     Re-derive: grep -n 'validate_length(:name' cloud/lib/barkpark_cloud/registry/site.ex
  //
  //   DOMAIN, 253 chars, FOUR unbroken labels of 63/63/63/61 — `validate_domains/1`
  //     accepts any string `String.length(d) <= 253` matching `@domain_format`,
  //     whose per-label shape is `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?` i.e. 63.
  //     It is a `validate_change`, so a `validate_length` census cannot see it.
  //     Re-derive: grep -n '@domain_format\|defp validate_domains' cloud/lib/barkpark_cloud/registry/site.ex
  //     Reached by a plain team member through `POST /v1/sites/:id/domains`
  //     (`with_team_site`, no admin gate). FORMAT-legal, not registrable — the
  //     harness renders hostnames, it does not resolve them.
  //
  //   WHY A 63-CHAR UNBROKEN LABEL IS NOT HYPOTHETICAL: the platform MINTS them.
  //     `POST /v1/launch` / `POST /v1/go-live` (non-admin — a team owner/admin
  //     session or a `deploy` PAT) runs `slugify/1`, which lowercases and joins
  //     on hyphens but NEVER truncates and NEVER inserts one into an already
  //     alphanumeric name; `Barkpark.changeset/2` caps the slug at 63; and
  //     `Barkpark.clean_url/1` then emits `https://<slug>.barkpark.cloud`
  //     verbatim, hyphen-free. So a 63-char unbroken first label is a string the
  //     product itself produces. Re-derive:
  //       grep -n 'def clean_url' cloud/lib/barkpark_cloud/registry/barkpark.ex
  //       grep -n 'validate_length(:slug' cloud/lib/barkpark_cloud/registry/barkpark.ex
  //       grep -n 'defp slugify' cloud/lib/barkpark_cloud/web/router.ex
  //     NOT `provisioning_subdomain/1`: it spends `@max_label_len - short - 1` on
  //     the slug and then appends `"-" <> short`, so it ALWAYS carries a hyphen
  //     at char 55 and can emit at most 54 unbroken characters. Citing it for a
  //     63-char token would assert a string that cannot be emitted.
  //
  // WHAT THIS ROW IS FOR: it is a REGRESSION PIN, and its expected finding yield
  // on today's CSS is ZERO — the `.site-name` / `.site-host` wrap already
  // shipped, and driven, this row reads scrollWidth == clientWidth exactly. The
  // value is that DELETING that wrap now reds an existing sweep cell naming
  // `div.site-name` and `div.site-host`, instead of being guarded by a comment.
  //
  // NO HEIGHT IS ASSERTED ANYWHERE FOR THIS ROW, deliberately: `Q3 BELOW THE
  // FOLD` reads `.content`'s own top offset and is structurally blind to a row
  // displacing its siblings; breakpoint-sweep's narrowest width is 619, so the
  // phone band where this row is tallest is measured by nothing; and a bare
  // pixel pin was already deleted from this epic once (cch-w15-s1). A height
  // claim here would have to be a reachability claim at a defended viewport
  // height, and this slice does not have one to defend.
  //
  // DEPLOYED ON PURPOSE: a 253-char host that is merely queued is a hostname
  // nobody has yet had to read. This row has served a build, so it keeps its
  // door and its host line is the one a person is actually looking at.
  site({
    id: "5b2c1e00-0000-4000-8000-0000000000c9",
    name: CRUEL_SITE_NAME,
    slug: CRUEL_SITE_SLUG,
    domains: [CRUEL_SITE_DOMAIN],
    // cch-w50: the 511-char `.site-meta .mono` span. Substituted on THIS row
    // rather than added as a new one, for the same shape-pin reason as
    // acme-media above; "acme/platform"@"main" was 18 characters and no
    // instrument had ever driven that host past a comfortable width.
    framework: "nextjs", github_repo: CRUEL_SITE_REPO, github_branch: CRUEL_SITE_BRANCH,
    github_webhook_configured: true,
    current_deployment_id: depOf(9),
    last_deployment: lastDeploy("live", "manual", 1200),
  }),
];

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
      site_id: IDS.siteWeb,
      status: "queued",
      git_ref: null,
      artifact_url: null,
      image_tag: null,
      build_log_url: null,
      failure_reason: null,
      // dr-w1-s2: `deployment_json/1` carries `failure_class:
      // DeployLedger.classify(d)` on EVERY row — null on a row that did not
      // fail. The key is on the base shape so a fixture that forgets it is a
      // missing key rather than a different wire.
      failure_class: null,
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
  artifact_url: "file:///var/lib/barkpark/artifacts/acme-web-9c1f2ab.tar.gz",
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
  // The class the LEDGER put this row in — `classify/2` reads the same reason
  // prose and answers BUILD_FAILED. The console renders this string and never
  // re-derives it from the sentence above.
  failure_class: "BUILD_FAILED",
  inserted_at: tMinus(20000),
  updated_at: tMinus(19800),
  console: [
    { line: "cloning acme/web @ b23aa01", at: tMinus(20000) },
    { line: "npm ci — ok (34s)", at: tMinus(19960) },
    { line: "npm run build — TypeError: window is not defined", at: tMinus(19820) },
  ],
});
const depPrior = deployment({
  id: IDS.depPrior,
  status: "live",
  git_ref: "4e7d0c9b3a5f18e2d6c4b0a9f8e7d6c5b4a39281",
  branch: "main",
  artifact_url: "file:///var/lib/barkpark/artifacts/acme-web-4e7d0c9.tar.gz",
  became_live_at: tMinus(90000),
  inserted_at: tMinus(90400),
  updated_at: tMinus(90000),
});
const rollbackDeployments = [depCurrent, depFailed, depPrior];
// The acme-web site with its production pointer on the newest live row.
const webSiteDeploys = Object.assign({}, webSite, {
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
    { line: "cloning acme/web @ 9c1f2ab", at: tMinus(26) },
    { line: "npm ci — installing 214 packages", at: tMinus(9) },
  ],
});
const inFlightDeployments = [depInFlight, depCurrent, depFailed, depPrior];
// The acme-web site DURING the promote: pointer still on the old live row, so
// the Current chip has NOT jumped to the building deploy.
const webSiteInFlight = Object.assign({}, webSite, {
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
const webSiteMigrated = Object.assign({}, webSite, {
  current_deployment_id: depNowLive.id,
});

// ── cch-w25-s3: THE DEPLOY RAIL'S FAILURE FOOTER, derived from its producers ─
//
// No scenario in this file has ever carried a rail STAGE entry, so
// `deployRailLedgerFromConsole` (app.js) dropped every console line and the
// whole `.deploy-rail` — head, step list, and the `.deploy-rail-fail` footer —
// has never rendered in this harness. These two lists are the fixture that
// makes it render, and the cruel string below is COMPOSED from the shell that
// actually emits it rather than transcribed from a screenshot.
//
// THE PRODUCERS, both read-only from here:
//   `build_failure_reason` — deploy/site-deploy-node.sh. On a failed
//     `npm ci && npm run build` it hands back the LAST line matching
//     `npm ERR!|[Ee]rror:` out of the build log, verbatim and unbounded. A Next
//     build's last error line is routinely a module-resolution path: one
//     unbreakable run carrying the person's own slug and the build id.
//   `emit()` — deploy/lib/site-deploy-common.sh. It collapses the detail's
//     tabs/newlines/quotes to spaces, squeezes runs, trims, and CUTS it —
//     `cut -c1-<N>`. That N is a SHELL CONVENTION IN ONE PRODUCER, not a
//     contract: nothing in the control plane re-asserts it (the provision-step
//     twin has no cap at all), so it is mirrored here as a NUMBER TO DERIVE,
//     never as an invariant to assert. `__app.test.mjs` reads the cut out of
//     the shell and reds when it moves — that test, not this comment, is what
//     keeps the fixture honest.
//
// RE-DERIVE THE WHOLE STRING:
//   grep -n 'build_failure_reason' deploy/site-deploy-node.sh
//   grep -n 'cut -c1-' deploy/lib/site-deploy-common.sh
//   node -e 'import("./cloud/priv/static/__preview__/scenarios.mjs").then(m=>console.log(m.RAIL_FAIL_EMIT_CUT, m.RAIL_FAIL_CRUEL_DETAIL.length))'
export const RAIL_FAIL_EMIT_CUT = 240;
// emit()'s own normalisation, in JS: tabs/newlines/quotes → space, squeeze,
// trim, cut. Applied to the stem so the fixture is the string a person would
// actually receive, not a hand-shortened idea of it.
export function railEmitDetail(stem, cut = RAIL_FAIL_EMIT_CUT) {
  return String(stem).replace(/[\n\r\t"]/g, " ").replace(/ +/g, " ").trim().slice(0, cut);
}
// The stem: a real `next build` module-resolution failure on THIS fixture's own
// site (slug `acme-web`, the pnpm store layout Next standalone builds produce).
// It is deliberately longer than the cut, so the fixture exercises the cut
// instead of merely fitting under it.
const railCruelStem =
  "npm ERR! Error: Cannot find module '/opt/barkpark/sites/acme-web/releases/" +
  "20260802T094118Z-9c1f2ab/.next/standalone/node_modules/.pnpm/@acme+design-system@4.2.1_react@18.3.1_" +
  "next@15.1.6/node_modules/@acme/design-system/dist/tokens/index.js' imported from /opt/barkpark/sites/acme-web";
export const RAIL_FAIL_CRUEL_DETAIL = railEmitDetail(railCruelStem);
// THE KIND CONTROL — the ordinary HEALTH failure a person sees most days.
// Derived from `HEALTH_DETAIL` in deploy/site-deploy-node.sh (the
// "slot … returned <code> (want 200)" branch): word-broken, ordinary
// punctuation, nothing unbreakable in it. It is short and probably fine, which
// is exactly why it is MEASURED — a remedy that buys the cruel string by
// shredding this one reds on it.
export const RAIL_FAIL_KIND_DETAIL = railEmitDetail(
  "slot blue on :8081 returned 502 (want 200) at /healthz after 12 attempts " +
  "(last: curl exit 0, 30.2s) — boot failed, live slot untouched",
);
// cch-w27-s2 — THE CLASSIFYING CONTROL, and the reason it had to be added.
//
// Neither string above CLASSIFIES: run both through `FailureCopy.humanize/1`
// (cloud/lib/barkpark_cloud/failure_copy.ex) and they come back byte-identical,
// because neither carries a token any `classify_atomic/1` clause matches. So a
// guard asserting "the rail caption and the row's failure_reason tell ONE story"
// is GREEN BY CONSTRUCTION on the wave-26 pair — the two strings agree for the
// same reason a broken clock agrees twice a day, and the guard could not have
// caught the live divergence it exists to catch. That is standing-test clause 4
// (a fixture that cannot produce the defect), and this constant is the fix.
//
// THE PRODUCER, read-only from here: `build_failure_reason()` —
// deploy/site-deploy.sh:1939 (and its byte-identical node twin,
// deploy/site-deploy-node.sh:1372). Its FIRST and highest-priority arm is
// `grep -a 'FATAL' <build-log> | tail -1`, and the FATAL line the header at
// site-deploy.sh:57 documents (emitted by the e2e's own npm at :935, asserted
// onto the stage line at :1062) is this one, verbatim. It reaches the rail as
// `BPSTAGE name=BUILD status=failed detail="…"`.
//
// It classifies on its OWN distinctive phrase — `the site read token is
// invalid`, not the generic `unauthorized` prefix — to "This site's Barkpark
// read token was rejected, so the build couldn't fetch its content. Mint a
// fresh read token for the site in Barkpark, save it on the site, then deploy
// the site again." That is what the settled row shows, and what the rail showed
// NOTHING of before this slice.
//
// TWO CORRECTIONS, IN ORDER. Wave 40 S6 removed a sentence that LIED ("The
// hosting provider rejected our credentials. We're on it — try again shortly.")
// — it named a party, an owner and a remedy `humanize/1`, arity 1, cannot see;
// the credential this very line reports is the USER'S OWN site read token and
// no hosting provider is in the story. task-fda5b6f19f1e06c9 then made the
// clause TELL: this is the one capture in which the producer already spells the
// owner and the remedy out, so it is keyed on the shell's bytes and says both.
// Every anonymous 401 still gets the deliberately party-less copy.
//
// RE-DERIVE THE WHOLE STRING:
//   grep -n 'FATAL: 401 Unauthorized' deploy/site-deploy.sh
//   grep -n '@credential_rejected' cloud/lib/barkpark_cloud/failure_copy.ex
// `sites_deploy_stage_caption_test.exs` reads BOTH ends and reds when either
// moves — that test, not this comment, is what keeps the fixture honest.
//
// NOT YET ROUTED INTO A SCENARIO: `smoke.mjs`'s cch-w10 census guard hard-fails
// on any scenario with no paired EXPECTATIONS row, and smoke.mjs is outside this
// slice's file fence. Wiring a third rail-fail scenario onto it is filed as
// task-877bfc465162e104.
export const RAIL_FAIL_CLASSIFYING_DETAIL = railEmitDetail(
  "FATAL: 401 Unauthorized from https://guerrilla.barkpark.cloud/w/acme/p/blog" +
  " — the site read token is invalid",
);

// The CRUEL rail: a deployment the control plane still calls `building` whose
// SSE narration already carries BUILD failed. That pairing is the honest
// TRANSIENT window this box lives in — `deployIsActive` (app.js) gates the rail
// to queued/building/pushing, so the footer is on screen from the stage-failed
// event until the control plane settles the row, and not one second longer.
const depRailFailedCruel = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000d6",
  site_id: IDS.siteWeb,
  status: "building",
  git_ref: "7f31c0d5ba9e4c218d63a07f5e1b8c94a2d60f3b",
  branch: "main",
  detail: "building",
  inserted_at: tMinus(74),
  updated_at: tMinus(3),
  console: [
    { stage: "PLAN", status: "done", detail: "release 20260802T094118Z-9c1f2ab, blue → green", at: tMinus(74) },
    { stage: "BUILD", status: "started", detail: "", at: tMinus(70) },
    { stage: "BUILD", status: "failed", detail: RAIL_FAIL_CRUEL_DETAIL, at: tMinus(6) },
  ],
});
// The KIND rail: same shape, same stage machine, an ordinary detail. Lives on
// the OTHER site of the same fixture (acme-blog) so one scenario carries both
// the cruel string and its control — see `deploymentsBySite` in route().
const depRailFailedKind = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000d7",
  site_id: IDS.siteBlog,
  status: "building",
  git_ref: "aa10ff2c4b7e8d6a1f0925c3b8e7d6c5b4a39281",
  branch: "main",
  detail: "building",
  inserted_at: tMinus(120),
  updated_at: tMinus(5),
  console: [
    { stage: "PLAN", status: "done", detail: "release 20260802T093902Z-aa10ff2, green → blue", at: tMinus(120) },
    { stage: "BUILD", status: "done", detail: "npm ci && npm run build (astro static)", at: tMinus(40) },
    { stage: "STAGE", status: "done", detail: "", at: tMinus(30) },
    { stage: "HEALTH", status: "failed", detail: RAIL_FAIL_KIND_DETAIL, at: tMinus(8) },
  ],
});

// ── cch-w29-bl-deploy-rail-live-site-open-still-nowrap: THE LIVE FOOTER ──────
//
// EVERY RAIL FIXTURE ABOVE IS A FAILURE FOOTER. `deployRailHtml` has two
// footers and only one of them had ever rendered in this harness:
// `.deploy-rail-fail` (cch-w25-s3, above) and `.deploy-rail-live` — the
// copyable site URL the OTHER branch emits once every stage is done. So the
// anchor inside the live footer was never measured at any width, and the base
// `white-space: nowrap` it inherits from `.site-open` (app.css) went unseen:
// #8743 dropped that nowrap for `.fleet-url .site-open` and the rail's twin
// emit kept it. THE SCENARIO-AXIS GAP IS THE DEFECT'S HIDING PLACE, which is
// why the fixture is the first half of the fix and not an extra.
//
// THE STATE IS THE SAME HONEST TRANSIENT WINDOW THE FAILED TWIN LIVES IN:
// `deployIsActive` (app.js) gates the rail to queued/building/pushing, so the
// rail is on screen while the control-plane row still reads `pushing` — and the
// SSE narration can already carry all six stages done, because the last
// stage-done frame arrives before the row settles to `live`. `deployRailStatus`
// folds an all-`ok` row set to tone "live", and `deployRailHtml` then emits
// `.deploy-rail-live` with `opts.url`.
//
// THE URL IS DERIVED, NEVER TYPED. `mountDeployRail` passes
// `siteLiveUrl(site, bp)`, and this site carries no `url` column, so the string
// is `liveInstance.url + "/sites/" + slug + "/"` — the product's own
// construction. Nothing here is lengthened to make it overflow: the ordinary
// 55-character live URL of the ordinary fixture site is what spills.
//
// THE HEAD'S `.fleet-url .site-open` IS THE IN-PAGE CONTROL, and that is why
// this fixture uses `webSiteDeploys` rather than a bare `webSite`: it carries
// `current_deployment_id`, so `siteHasEverDeployed` makes the detail head
// render THE SAME STRING through the twin selector #8743 already paid. One
// route, two anchors, one URL — the measured pair overflow-guard's
// W29-deploy-rail-live-url-wrap leg reads is a comparison inside a single page,
// not across two runs.
const depRailLive = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000d8",
  site_id: IDS.siteWeb,
  status: "pushing",
  git_ref: "9c1f2ab84f00d4e2b16a99871c33d05a72e4f810",
  branch: "main",
  detail: "pushing",
  inserted_at: tMinus(96),
  updated_at: tMinus(2),
  console: [
    { stage: "PLAN", status: "done", detail: "release 20260802T094118Z-9c1f2ab, blue → green", at: tMinus(96) },
    { stage: "BUILD", status: "done", detail: "npm ci && npm run build (next standalone)", at: tMinus(58) },
    { stage: "STAGE", status: "done", detail: "", at: tMinus(40) },
    { stage: "HEALTH", status: "done", detail: "slot green on :8081 answered 200 at /healthz", at: tMinus(24) },
    { stage: "SWITCH", status: "done", detail: "", at: tMinus(9) },
    { stage: "RETIRE", status: "done", detail: "", at: tMinus(2) },
  ],
});

// ── cch-deploy-detail-render-has-no-cap: THE LIVE SUB-CAPTION, AT ITS STORE CAP
//
// `.deploy-detail` is the only caption on the deploy rail with NO render bound,
// and no scenario in this file has ever carried one longer than "building". The
// three constants below are its three lengths, each DERIVED from the producer
// that can actually emit it — so the fixture reds when a producer moves instead
// of quietly stopping being cruel.
//
// (1) THE STORE CAP — what the column will accept. `set_deployment_detail/2`
//     (cloud/lib/barkpark_cloud/registry.ex) runs the detail through the SHARED
//     `validate_console_line/1`, whose only bound is `@max_console_line_chars`.
//     Since cch-w34-s5 widened `deployments.detail` from varchar(255) to :text,
//     that attribute is the LAST bound before the DOM. `__app.test.mjs` reads
//     the number out of registry.ex and reds when it moves — that test, not
//     this comment, is what keeps the fixture honest.
export const DEPLOY_DETAIL_STORE_CAP = 2000;
// (2) THE SHIPPED PRODUCER'S WORST CASE. `buildConsole.caption` is the ONLY
//     writer of this field in the fleet (internal/builder/console.go:175 ->
//     reportDetail -> POST /v1/builder/deployments/:id/detail), and its longest
//     format is `"Starting your build (%s)…"` over `git_ref`
//     (internal/builder/builder.go:141). `git_ref` is varchar(255), so a
//     builder's ceiling is the format's own 23 characters plus 255. It is
//     REPORTED, never pinned: it is what an ADVERSARIAL ref would cost, and the
//     bound chosen below is measured against it rather than fitted to it.
export const DEPLOY_DETAIL_BUILDER_MAX =
  "Starting your build (".length + 255 + ")…".length;
// (3) THE KIND CONTROL — the same caption with the ref a builder actually
//     carries: a 40-character SHA. This is the longest string a person sees on
//     an ordinary day, and a remedy that buys the cruel caption by shredding
//     THIS one reds on it.
export const DEPLOY_DETAIL_KIND =
  "Starting your build (7f31c0d5ba9e4c218d63a07f5e1b8c94a2d60f3b)…";
// (4) THE CRUEL CAPTION. Reaching the store cap needs a direct worker-token
//     POST — no shipped producer emits 2 KB — and the shape such a POST takes
//     is a build log the poster newline-squeezed into ONE line: a Next
//     module-resolution failure plus its import trace, which is exactly what
//     `emit()`'s tab/newline collapse does to a multi-line error one surface
//     over. Word-broken prose, not one unbreakable token: the token-shape
//     defect is `.status-pill-detail`'s (app.css:3498) and this caption already
//     carries `word-break`, so LENGTH is the only thing left to bound and the
//     fixture must not smuggle in the other defect to make its point.
const deployDetailCruelFrames = [
  "./src/app/(marketing)/pricing/page.tsx",
  "./src/components/design-system/PricingTable/index.tsx",
  "./src/components/design-system/PricingTable/PlanCard.tsx",
  "./src/lib/tokens/resolve.ts",
];
const deployDetailCruelStem =
  "Building your site… npm ERR! Error: Cannot find module " +
  "'/opt/barkpark/sites/acme-web/releases/20260802T094118Z-9c1f2ab/.next/standalone/" +
  "node_modules/@acme/design-system/dist/tokens/index.js' imported from " +
  "/opt/barkpark/sites/acme-web. Import trace for requested module: " +
  Array.from({ length: 40 }, (_, i) => deployDetailCruelFrames[i % 4] + " ").join("");
// Normalised by the SAME collapse `emit()` performs, then cut at the STORE cap
// rather than the shell's — this caption never passed through the shell.
export const DEPLOY_DETAIL_CRUEL = railEmitDetail(deployDetailCruelStem, DEPLOY_DETAIL_STORE_CAP);
// The stem must OVERFLOW the cap, or the "at its store cap" fixture is a
// shorter string wearing the cap's name and every number this scenario
// produces is about a caption nobody capped.
if (DEPLOY_DETAIL_CRUEL.length !== DEPLOY_DETAIL_STORE_CAP) {
  throw new Error(
    "cruel deploy detail is " + DEPLOY_DETAIL_CRUEL.length + " chars, must be exactly the store cap " +
    DEPLOY_DETAIL_STORE_CAP + " — lengthen deployDetailCruelStem; a stem that fits under the cap makes " +
    "this scenario a statement about a caption the store never had to cut",
  );
}
// The CRUEL row: mid-build, so `deployIsActive` keeps the live sub-caption on
// screen (a terminal row shows its failure panel instead — a different branch
// of deployDetailHtml). Nothing else about it is unusual; the caption is.
const depDetailCruel = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000e1",
  site_id: IDS.siteWeb,
  status: "building",
  git_ref: "7f31c0d5ba9e4c218d63a07f5e1b8c94a2d60f3b",
  branch: "main",
  trigger: "manual",
  detail: DEPLOY_DETAIL_CRUEL,
  inserted_at: tMinus(90),
  updated_at: tMinus(2),
  console: [
    { line: "cloning acme/web @ 7f31c0d", at: tMinus(90) },
    { line: "npm ci — installing 214 packages", at: tMinus(60) },
  ],
});
// The KIND row, in the SAME paint: an ordinary caption on an ordinary build.
// It is a SECOND building row rather than a queued one on purpose — the
// pre-claim branch renders a different caption through a different code path,
// so a control there would not be under the same rule as the cruel row.
const depDetailKind = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000e2",
  site_id: IDS.siteWeb,
  status: "building",
  git_ref: "aa10ff2c4b7e8d6a1f0925c3b8e7d6c5b4a39281",
  branch: "release/2026-08",
  trigger: "manual",
  detail: DEPLOY_DETAIL_KIND,
  inserted_at: tMinus(140),
  updated_at: tMinus(20),
  console: [{ line: "cloning acme/web @ aa10ff2", at: tMinus(140) }],
});
const deployDetailCruelDeployments = [depDetailCruel, depDetailKind, depCurrent, depPrior];
const deployDetailCruelSite = Object.assign({}, webSite, {
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
  auditEvent({ id: "ev_4", action: "site.created", target_type: "site", target_id: IDS.siteBlog, metadata: { name: "acme-blog" }, inserted_at: tMinus(4000) }),
  auditEvent({ id: "ev_3", action: "subscription.activated", target_type: "subscription", target_id: "sub_1", metadata: { plan: "pro" }, inserted_at: tMinus(80000) }),
  auditEvent({ id: "ev_2", action: "barkpark.deleted", target_type: "barkpark", target_id: "old_box", metadata: { name: "Sandbox" }, inserted_at: tMinus(90000) }),
  auditEvent({ id: "ev_1", action: "token.minted", target_type: "token", target_id: "tok_1", metadata: { name: "CI deploy" }, inserted_at: tMinus(172800) }),
];

// I-01 (#activity): a team feed that EXERCISES the by-target coalesce key —
// three consecutive deploys of the SAME site fold into ONE ×3 group, while a
// deploy of a DIFFERENT site (and a different actor) stays a singleton (the
// team feed must never fold unrelated targets, GR26). Newest-first, exactly as
// GET /v1/audit returns; actor.email is backend-true. Bob's row proves the key
// splits on BOTH actor and target.
const activityFeed = [
  auditEvent({ id: "af_7", action: "member.invited", actor: { id: "usr_ada", email: "ada@acme.com" }, target_type: "user", target_id: "usr_new", metadata: { email: "kit@acme.com" }, inserted_at: tMinus(60) }),
  auditEvent({ id: "af_6", action: "site.deploy_requested", actor: { id: "usr_ada", email: "ada@acme.com" }, target_type: "site", target_id: IDS.siteWeb, metadata: { git_ref: "b23aa01" }, inserted_at: tMinus(180) }),
  auditEvent({ id: "af_5", action: "site.deploy_requested", actor: { id: "usr_ada", email: "ada@acme.com" }, target_type: "site", target_id: IDS.siteWeb, metadata: { git_ref: "9c1f2ab" }, inserted_at: tMinus(320) }),
  auditEvent({ id: "af_4", action: "site.deploy_requested", actor: { id: "usr_ada", email: "ada@acme.com" }, target_type: "site", target_id: IDS.siteWeb, metadata: { git_ref: "4e7d0c9" }, inserted_at: tMinus(460) }),
  auditEvent({ id: "af_3", action: "site.deploy_requested", actor: { id: "usr_bob", email: "bob@acme.com" }, target_type: "site", target_id: IDS.siteBlog, metadata: { git_ref: "aa10ff2" }, inserted_at: tMinus(600) }),
  auditEvent({ id: "af_2", action: "site.env_changed", actor: { id: "usr_ada", email: "ada@acme.com" }, target_type: "site", target_id: IDS.siteWeb, metadata: { keys: ["DATABASE_URL", "API_TOKEN"] }, inserted_at: tMinus(900) }),
  auditEvent({ id: "af_1", action: "barkpark.go_live", actor: { id: "usr_ada", email: "ada@acme.com" }, target_type: "barkpark", target_id: IDS.liveInstance, metadata: { name: "Production" }, inserted_at: tMinus(4000) }),
];

// ── instance events + verify runs (event_json: {id,type,payload,inserted_at};
//    types from the closed AgentEvent vocabulary — read AgentEvent.types/0, not
//    this line: health status content verify space, since cch-w51-bl struck
//    backup and tls; verify payload ⇐ Verify.run/1's result envelope) ─────────
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
  ev(6, "health", { health: "up", disk_used_pct: 41, pg_size_mb: 211 }, tMinus(7300)),
  ev(5, "status", { transition: "online", reason: "agent_report" }, tMinus(80000)),
];
const liveInstanceEventsOneFail = [ev(10, "verify", verifyOneFail, tMinus(60))].concat(liveInstanceEvents.slice(1));
const liveInstanceEventsNoVerify = liveInstanceEvents.slice(1);

// Audit rows scoped to the live instance — what the Timeline's audit half
// contributes (actor attribution beside the machine events).
const liveInstanceAudit = [
  auditEvent({ id: "ev_b2", action: "site.created", target_type: "site", target_id: IDS.siteBlog, metadata: { name: "acme-blog" }, inserted_at: tMinus(4000) }),
  auditEvent({ id: "ev_b1", action: "barkpark.go_live", target_type: "barkpark", target_id: IDS.liveInstance, metadata: { name: "Production" }, inserted_at: tMinus(86400) }),
];

// The one-shot recovery sheet: 8 codes, 8-char lowercase base32 — the exact
// shape accounts/two_factor.ex mints. Shown plaintext ONCE and never re-served.
const RECOVERY_CODES = [
  "h4kq2mfp", "x8dw9rgt", "p2ml5qzn", "k9vt3bxs",
  "w6ny8jhc", "r1gd4tkm", "z7sb6plf", "m3cx1vwq",
];

// The active-session list the account modal renders (GR54). Two rows so both
// arms are exercised: the CURRENT device (badged, un-revokable) and a second
// device that CAN be revoked. Unmodelled before this slice — the modal is
// click-opened, so no scenario ever reached it.
const accountSessions = [
  { id: "sess_current", user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/126.0", ip_address: "84.212.31.7", last_used_at: tMinus(20), current: true },
  { id: "sess_cli", user_agent: "barkpark-cli/0.9", ip_address: "84.212.31.7", last_used_at: tMinus(2 * 86400), current: false },
];

// GR63/GR76 — the TALL shape. Two sessions (above) is the SHORT shape, which was
// never broken; NINE is the shape that broke on live, where the modal grew past
// the viewport and stranded Log out / Revoke all below the fold. Same shape as
// __app.test.mjs's TALL_SESSIONS fixture.
//
// Honest about what this scenario proves: at the harness's 1000px window height
// nine session rows FIT, so a shot of this scenario DOCUMENTS the tall anatomy —
// it does not by itself prove the overflow behaviour. The scroll containment
// that fixes the real break is pinned by the GR63 node test, not by this PNG.
// (ip_address is still on every row: the wire shape is unchanged, the SPA just
// refuses to draw it — GR81.)
const accountSessionsTall = Array.from({ length: 9 }, (_, i) => ({
  id: "sess_tall_" + i,
  user_agent: i === 0
    ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/126.0"
    : "barkpark-cli/0.9",
  ip_address: "84.212.31." + (7 + i),
  last_used_at: tMinus((i + 1) * 3600),
  current: i === 0,
}));

// cch-w2-revoke-click-oracle — the REVOKE shape: the acting device plus THREE
// revokable others. Three, not one, so the two legs stay distinguishable after
// the click oracle drives them in sequence: revoking one row leaves 4→3 rows
// (2 still revokable), and the subsequent "sign out everywhere" then reports
// revoked:2 — a count that is neither 0 (the generic-200 false green) nor any
// constant a client could have invented.
const accountSessionsRevoke = [
  { id: "sess_here", user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/126.0", ip_address: "84.212.31.7", last_used_at: tMinus(60), current: true },
  { id: "sess_phone", user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5) Safari/605.1", ip_address: "84.212.31.8", last_used_at: tMinus(3 * 3600), current: false },
  { id: "sess_cli", user_agent: "barkpark-cli/0.9", ip_address: "84.212.31.9", last_used_at: tMinus(2 * 86400), current: false },
  { id: "sess_old", user_agent: "Mozilla/5.0 (X11; Linux x86_64) Firefox/128.0", ip_address: "84.212.31.10", last_used_at: tMinus(9 * 86400), current: false },
];

// ── me / subscription helpers ────────────────────────────────────────────────
// onboarding mirrors onboarding_json (accounts.ex onboarding_status): the step
// vocabulary is CLOSED — subscription | instance | published_doc — and the
// envelope always carries completed/completed_at/last_step/all_done/steps.
//
// role (3rd param, default "owner"): the team role the /v1/me envelope carries.
// Phase-4 Settings page slices (G-01 billing … G-06 members) ship plain-member
// scenarios by passing "member" — the write affordances gate on owner/admin, so
// a member scenario proves the read-only / disabled-CTA states. Pairing pattern
// for the per-endpoint 403 those members hit: model it as a fixture DENIED FLAG
// on the endpoint, exactly like `auditDenied` (see below, ~line 1997): the flag
// makes GET /v1/audit answer 403 so the view degrades, never a client role-check.
// Add e.g. `membersDenied`/`envDenied` fixtures + the matching flag branch in the
// endpoint switch, then set the flag on the member scenario. Keep the DEFAULT
// path (owner, no flag) so no existing scenario changes behaviour.
// cch-w45-s1: `actorId` is the fourth parameter because rank is NOT identity.
// Until this wave `me()` threaded `role` into FOUR authority fields and ZERO
// identity fields, so a role-only "admin" scenario rendered BYTE-IDENTICALLY to
// the owner one (4220 vs 4220): every rank-relative predicate in the members
// panel compares the actor to the ROSTER ROW, and the roster row it was
// compared against was always the actor's own (teamMembers[0] IS usr_ada).
// Every guard over that comparison was green by construction. Passing an
// `actorId` moves `user.id` — and, inseparably, `user.email`, because an actor
// whose two halves name different people is a fixture that could never exist on
// the wire. Omit it and the corpus's default actor (usr_ada, the owner) is
// unmoved: moving that default globally is forbidden (it reds the members
// remove-click leg and the 2FA/invite copy, which read me().user.email).
function me(teamName, onb, role, actorId) {
  onb = onb || {};
  const steps = [
    // Every scenario that is logged-in carries a subscription fixture, so the
    // subscription step is done unless a scenario opts out explicitly.
    { key: "subscription", done: onb.subscription !== false },
    { key: "instance", done: !!onb.instance },
    { key: "published_doc", done: !!onb.published_doc },
  ];
  // cch-w43-s1: the envelope is the one the SERVER mints, key for key. The
  // shape is DERIVED from /v1/me's own response map (router.ex, the
  // `get "/v1/me"` clause): user{id,email,confirmed,two_factor_enabled,
  // platform_operator} · team{id,name,slug} · teams[]{id,name,slug,role} ·
  // role · team_authority{team_id,role,admin,owner} · onboarding.
  // __me_envelope_census.mjs re-derives that map at test time and diffs it
  // against what route(name,"GET","/v1/me") actually serves, so this comment
  // is not the guard — the census is, and it reds by key path when the two
  // drift. Until wave 43 the corpus emitted FOUR of those six keys, which is
  // why every rendered scenario ran on app.js's compatibility floors and the
  // `grant` band had never been painted by any instrument.
  //
  // `platform_operator` is deliberately NOT set here: it is the operator axis,
  // and operatorMe() (below) is the ONE producer that raises it, exactly as
  // GR39 requires. The census unions over the whole corpus, so those scenarios
  // are what prove the key is served at all.
  const actorRole = role || "owner";
  const actorUserId = actorId || "usr_ada";
  return {
    user: { id: actorUserId, email: corpusActorEmail(actorUserId), confirmed: true, two_factor_enabled: false },
    team: { id: IDS.team, name: teamName, slug: "acme" },
    // EVERY membership, the server's words. The corpus's actor belongs to the
    // one team it is scoped to — a SECOND team here would be a scenario-level
    // claim (a switcher with somewhere to switch to) that no fixture asks for.
    teams: [{ id: IDS.team, name: teamName, slug: "acme", role: actorRole }],
    role: actorRole,
    // The authority the GATE enforces, stated on the wire. Scoped to the SAME
    // team as `team:` and `role:` above — one resolved team, never a role from
    // one team beside an id from another. admin/owner mirror Authz: owner is
    // both, admin is admin-not-owner, everyone else is neither.
    team_authority: {
      team_id: IDS.team,
      role: actorRole,
      admin: actorRole === "owner" || actorRole === "admin",
      owner: actorRole === "owner",
    },
    onboarding: {
      completed: !!onb.completed,
      completed_at: onb.completed ? tMinus(80000) : null,
      last_step: onb.last_step || null,
      all_done: steps.every((s) => s.done),
      steps,
    },
  };
}
// dr-w1-s2 DEPLOY LEDGER CENSUS fixtures — the PAYLOAD SHAPE `DeployLedger`
// actually emits, not a convenience shape the console would like:
//   * every rate is a NODE — {sample, pct, numerator, min_sample, refused,
//     reason, basis} — so the denominator can never travel apart from the
//     percentage, and `refused: true` carries `pct: null` plus the server's own
//     sentence ("sample 74 below min_sample 200").
//   * each `classes[]` row carries the class NAME, its LABEL and its own share
//     NODE. The console renders all three verbatim; nothing here is a hint the
//     client is expected to expand.
// @min_sample is 200 (deploy_ledger.ex), which is why n=74 refuses.
function censusRate(numerator, sample, basis) {
  const enough = sample >= 200;
  return {
    sample,
    pct: enough ? Math.round((numerator * 10000) / sample) / 100 : null,
    numerator,
    min_sample: 200,
    refused: !enough,
    reason: enough ? null : `sample ${sample} below min_sample ${200}`,
    basis,
  };
}
const CENSUS_ATTEMPTED_BASIS =
  "attempted rows in the window: failed + deferred + live + in_flight + cancelled + residual " +
  "(never-attempted tombstones excluded, D19)";
const CENSUS_FAILED_BASIS = "settled failed rows in the window — the failure numerator";
function censusClass(name, label, count, failed) {
  return { class: name, label, agency: "box", count, share: censusRate(count, failed, CENSUS_FAILED_BASIS) };
}
function censusWindow(days) {
  return { from: tMinus(days * 86400), to: tMinus(0) };
}

// GR39: the platform-operator envelope. The flag is NESTED under `user` (the
// same read operatorVisible/operatorRouteAllowed make) — a flat one is not the
// contract and must never open the console.
function operatorMe(teamName) {
  const m = me(teamName, { instance: true, published_doc: true, completed: true }, "owner");
  m.user = Object.assign({}, m.user, { platform_operator: true });
  return m;
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

// ── G-06 members fixtures ────────────────────────────────────────────────────
// Envelope shapes are the real serializers: member_json {user_id, email, role,
// joined_at}; invitation_json {id, email, role, expires_at, inserted_at}.
// The env-var fixtures that lived beside these went with the team env-var
// feature (ruled 2026-09-02, Option A — zero prod rows ever).
// usr_ada is the me() user, so the roster tags it "(you)" and never offers a
// self-remove. THREE roles only (owner/admin/member).
const teamMembers = [
  { user_id: "usr_ada", email: "ada@acme.com", role: "owner", joined_at: tMinus(240 * 86400) },
  { user_id: "usr_lin", email: "lin@acme.com", role: "admin", joined_at: tMinus(120 * 86400) },
  { user_id: "usr_rex", email: "rex@acme.com", role: "member", joined_at: tMinus(20 * 86400) },
];
// cch-w45-s1: a SECOND owner, appended by CONCAT so `teamMembers` — and every
// count assertion, every residue line and every wire leg standing on its three
// rows — is byte-for-byte unmoved. This is the one roster cell where the two
// server verbs DISAGREE: `Accounts.remove_member_as/3` carries an owner escape
// hatch (`actor_role == "owner" or outranks?/2`, accounts.ex:1722) while
// `update_member_role_as/4` does not (strict `outranks?`, accounts.ex:1801) —
// so an owner MAY remove a peer owner and may NOT re-role one. No cell of the
// corpus could paint that disagreement before, because there was no peer owner.
const teamMembersPeerOwner = teamMembers.concat([
  { user_id: "usr_ozz", email: "ozz@acme.com", role: "owner", joined_at: tMinus(200 * 86400) },
]);
// The corpus's actors, id → email, read STRAIGHT off the roster fixtures so the
// two halves of an identity can never be edited apart. Unknown id is FATAL, not
// a silent fallback to ada: a typo'd actor that quietly renders as the owner is
// exactly the vacuous green this fixture exists to end.
function corpusActorEmail(userId) {
  const row = teamMembersPeerOwner.find((m) => m.user_id === userId);
  if (!row) throw new Error("preview corpus has no actor " + userId + " — id and email move together");
  return row.email;
}
const teamInvites = [
  { id: "inv_sky", email: "sky@partner.io", role: "member", expires_at: tPlus(6 * 86400), inserted_at: tMinus(86400) },
  { id: "inv_max", email: "max@acme.com", role: "admin", expires_at: tPlus(3 * 86400), inserted_at: tMinus(3 * 86400) },
];

// ── cch-w12-followup-login-fixture-gap · THE SECOND IDENTITY ─────────────────
// A roster of a DIFFERENT team, sharing not one user id with `teamMembers`.
// That disjointness is the whole assertion: after signing in as one of these
// people, a Who axis that still names lin or rex is naming the previous team's
// members, and there is no innocent reading of it.
// NOT routed through `corpusActorEmail` on purpose — that helper's contract is
// "the ACME corpus's actors, id → email, read straight off the roster fixtures",
// and it throws on an unknown id precisely so a typo cannot silently render as
// ada. These two belong to another team's roster, so they are stated whole
// here, in the same member_json shape (`{user_id, email, role, joined_at}`) the
// server serializes.
const teamMembersBeta = [
  { user_id: "usr_zed", email: "zed@beta.io", role: "owner", joined_at: tMinus(90 * 86400) },
  { user_id: "usr_qi", email: "qi@beta.io", role: "member", joined_at: tMinus(10 * 86400) },
];
// The /v1/me envelope the second sign-in lands. Built by MOVING the identity
// fields of a `me()` envelope rather than by typing a fresh object literal, so
// it is key-for-key what every other logged-in scenario answers — the
// __me_envelope_census diffs served keys against router.ex's own response map,
// and a hand-typed twin is exactly how a fixture drifts out from under it.
const betaMe = (() => {
  const env = me("Beta Works", { instance: true, published_doc: true, completed: true });
  env.user = { id: "usr_zed", email: "zed@beta.io", confirmed: true, two_factor_enabled: false };
  env.team = { id: IDS.teamBeta, name: "Beta Works", slug: "beta-works" };
  env.teams = [{ id: IDS.teamBeta, name: "Beta Works", slug: "beta-works", role: "owner" }];
  env.team_authority = { team_id: IDS.teamBeta, role: "owner", admin: true, owner: true };
  return env;
})();

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
    // w29 — the two UNMETERED states, side by side in one shot: webhooks was
    // MEASURED AND THE READ CRASHED (`unavailable_reason`, so it reads "Could
    // not measure · the read crashed" and tints warn), while db_size / p95_ms /
    // api_requests / bandwidth below are the DELIBERATE non-measurements that
    // still read "Not yet metered". Before the reason field existed these two
    // truths rendered byte-identically.
    webhooks: m("unmetered", { source: "instance.webhooks", unavailable_reason: "exception" }),
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
      gaps: { pause: "A Hetzner server bills for as long as it exists, powered on or off — we can't pause it. Deleting the instance is the only thing that stops the charge." },
    },
  },
  default_gap: "Not supported by this provider.",
};

// ── gr-p4 G-03: settings provider capabilities (GET /v1/providers/capabilities) ─
// The honest-matrix source in the SERVER facet shape
// {providers:{kind:{tier,capabilities,gaps}}} — mirrors __app.test.mjs CAP_PAYLOAD
// MINUS default_gap (the server NEVER emits one). All 9 verbs × 3 providers:
// hetzner + azure are prod (the two matrix columns), fake is dev-tier (FILTERED
// out of the matrix). The false cells prove the honesty grammar: some carry the
// server-owned gap reason (hetzner.pause, azure.adopt), some are a bare dash with
// NO reason (azure.audit) — the UI pads neither.
//
// cch-w45-bl — `catalog` IS TRUE FOR BOTH NEUTRAL KINDS, AND CANNOT BE ANYTHING
// ELSE. This fixture models the bytes GET /v1/providers/capabilities SERVES, and
// that response is POST-OVERLAY: own_catalog_capability/2 (cloud router,
// @neutral_kinds ~w(hetzner azure)) rewrites `catalog` to true for those two
// kinds whenever the key is present, because THIS control plane builds their
// catalogs itself (build_provider_catalog/2 behind GET /v1/providers/:kind/
// catalog). So no deployment can emit hetzner.catalog:false here — the value was
// copied from the GO SEAM fixture (priv/static/__fixtures__/
// providers_capabilities.json, where `false` is honest: no Go provider
// implements Cataloger) and landed on the wrong side of the overlay. azure was
// already carrying the post-overlay `true`, so the fixture was internally
// inconsistent about its own two neutral kinds.
//
// This is NOT a green bought by editing a fixture. It is the ONLY cell of this
// payload whose value the server fixes rather than passes through, and getting
// it wrong made the console — which now correctly consults the conduit before
// mounting a catalog — withhold the launch wizard's `.launch-connect-provider`
// door on `providers-connected`, an unreachable state in production. The
// no_catalog arm keeps its coverage in __app.test.mjs, where the payload is
// authored per-assertion rather than claimed of a real deployment. Do NOT
// "resync" this with the Go fixture: the two sit on opposite sides of the
// overlay, and the router's own comment forbids the reverse edit.
const settingsProviderCapabilities = {
  providers: {
    hetzner: {
      tier: "prod",
      capabilities: {
        core: true, catalog: true, labels: true, pause: false,
        archive: true, resurrect: true, decommission: true, adopt: true, audit: true,
      },
      gaps: { pause: "A Hetzner server bills for as long as it exists, powered on or off — we can't pause it. Deleting the instance is the only thing that stops the charge." },
    },
    azure: {
      tier: "prod",
      capabilities: {
        core: true, catalog: true, labels: true, pause: true,
        archive: true, resurrect: true, decommission: true, adopt: false, audit: false,
      },
      gaps: { adopt: "Adopt needs an existing resource-group import." },
    },
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

// ── gr-p4 G-02: connected providers (GET /v1/providers) ──────────────────────
// Rows carry ONLY {id,kind,label,team_id,inserted_at} (router.ex provider row) —
// there is NO health/verified field, so the roster shows kind + label + when it
// was connected and never a live-validity badge.
const connectedProviders = [
  { id: "prov_h1", kind: "hetzner", label: "main", team_id: IDS.team, inserted_at: tMinus(86400 * 9) },
  { id: "prov_a1", kind: "azure", label: "prod-sub", team_id: IDS.team, inserted_at: tMinus(3600 * 5) },
];

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

// ── gr-p3-site-detail (E-02): the states-complete v4 ladder fixtures ─────────
// One site whose history shows every settled deployment state at once — live
// (current), crash-failed (red panel + console), born-failed github-push
// (blocked amber panel), cancelled (hollow dashed pill: terminal and
// deliberately stopped, NOT the filled grey of a queued row) and a prior live
// row (rollback affordance) — plus branch previews (one live, one failed) and the
// domains rungs (a proxied custom apex + a www still waiting on TLS).
// Triggers are ONLY the backend vocabulary (manual | content-auto — GR27).
const stLive = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f1",
  status: "live",
  git_ref: "9c1f2ab84f00d4e2b16a99871c33d05a72e4f810",
  branch: "main",
  trigger: "content-auto",
  became_live_at: tMinus(7200),
  inserted_at: tMinus(7248),
  updated_at: tMinus(7200),
});
const stCrash = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f2",
  status: "failed",
  git_ref: "b23aa017c9d8e2f4a6b1305c8d9e0f1a2b3c4d5e",
  branch: "main",
  trigger: "manual",
  failure_reason: "npm run build exited 1",
  inserted_at: tMinus(21600),
  updated_at: tMinus(21581),
  console: [
    { line: "cloning acme/web @ b23aa01", at: tMinus(21600) },
    { line: "npm run build — TypeError: window is not defined", at: tMinus(21584) },
    { line: "build: exited with code 1", at: tMinus(21581) },
  ],
});
// ── cch-w26-s2: THE CRUEL DEPLOY ROW, derived from its producers ────────────
//
// WHY IT HAD TO BE COMMITTED. A census of every `failure_reason` in this file
// before this row returned NINE values reducing to TWO distinct strings —
// "npm run build exited 1" (22 chars, longest unbreakable run 9) and the
// humanized github-push copy (122 chars, word-broken throughout). Neither can
// clip: the widest `.deploy-fail` any committed fixture could paint fits inside
// the `.deploys` card at every width this epic drives. So the panel's missing
// wrap rule was UNREACHABLE by any instrument in this tree — a leg written
// against the old corpus would have printed a perfect table on the defective
// bytes. THE FIXTURE IS THE PRECONDITION OF THE LEG, not an extra.
//
// THE PRODUCER CHAIN, read-only from here, one hop LONGER than the rail's:
//   `build_failure_reason` (deploy/site-deploy-node.sh:1372) — the last
//     `npm ERR!|[Ee]rror:` line of the build log, verbatim and unbounded. On a
//     Next build that is routinely a module-resolution path: ONE unbreakable
//     run carrying the person's own slug and the release id.
//   `emit()` (deploy/lib/site-deploy-common.sh) — normalises and CUTS it. This
//     is the same string the deploy rail's footer holds, so it is reused here
//     as RAIL_FAIL_CRUEL_DETAIL rather than re-derived (one producer, one
//     fixture: if the shell's cut moves, __app.test.mjs reds and BOTH strings
//     move together).
//   `stage_failure_copy/1` (cloud/lib/barkpark_cloud/sites/deploy.ex:994) —
//     the control-plane hop the RAIL DOES NOT TAKE. When the box reports a
//     failed stage with a detail, the DEPLOYMENT ROW's `failure_reason` column
//     is stamped `"<STAGE> failed — <detail>"`, and `FailureCopy.humanize/1`
//     passes an unrecognised reason through verbatim. That prefix is why this
//     is a DIFFERENT string from the rail's footer even though the cruel part
//     is shared — and it is composed here, never pasted.
//
// RE-DERIVE:
//   grep -n 'defp stage_failure_copy' -A 6 cloud/lib/barkpark_cloud/sites/deploy.ex
//   node -e 'import("./cloud/priv/static/__preview__/scenarios.mjs").then(m=>console.log(m.DEPLOY_FAIL_CRUEL_REASON.length))'
export function deployStageFailureCopy(stage, detail) {
  return `${stage} failed — ${detail}`;
}
export const DEPLOY_FAIL_CRUEL_REASON = deployStageFailureCopy("BUILD", RAIL_FAIL_CRUEL_DETAIL);
// The row itself: a SECOND crash on the same site's history, one stage-report
// hop from the box. It is added rather than substituted because `stCrash`
// above is the KIND crash every other harness asserts verbatim — replacing it
// would have bought this leg its cruelty by deleting somebody else's control.
const stCrashCruel = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f8",
  status: "failed",
  git_ref: "e91b47c05d3a8f26b1c4d907e5a3f28b60c1d4e7",
  branch: "main",
  trigger: "manual",
  failure_reason: DEPLOY_FAIL_CRUEL_REASON,
  inserted_at: tMinus(30600),
  updated_at: tMinus(30541),
  console: [
    { line: "cloning acme/web @ e91b47c", at: tMinus(30600) },
    { line: "npm ci — ok (41s)", at: tMinus(30560) },
    { line: "next build — module resolution failed", at: tMinus(30541) },
  ],
});
const stBlocked = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f3",
  status: "failed",
  git_ref: "5f0a9dd41c2b3e4f5a6b7c8d9e0f1a2b3c4d5e6f",
  branch: "main",
  // The humanized born-failed github-push copy exactly as FailureCopy.humanize
  // emits it at the JSON boundary (the client re-map is idempotent on it).
  failure_reason: "This push predates GitHub source builds and can’t be built yet — push again to build this commit, or deploy it with bp deploy.",
  inserted_at: tMinus(90000),
  updated_at: tMinus(90000),
});
const stCancelled = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f4",
  status: "cancelled",
  git_ref: "4e7d0c9b3a5f18e2d6c4b0a9f8e7d6c5b4a39281",
  branch: "main",
  trigger: "manual",
  inserted_at: tMinus(172800),
  updated_at: tMinus(172740),
});
// cch-w28-bl: THE REFUSAL SENTENCE, byte-identical to
// `Sites.AutoDeployWorker`'s @refusal_detail (auto_deploy_worker.ex:162). It
// reaches the browser UNTRANSFORMED — FailureCopy.humanize/1 is the identity on
// it and no classifier token matches — so the fixture is allowed to carry the
// server's own bytes, and MUST carry exactly those bytes. This is the only copy
// of the string outside the Elixir module; __app.test.mjs pins the two together
// by reading the .ex file, so a reworded refusal reds the console gate instead
// of quietly leaving this fixture asserting a sentence nobody ships.
export const REFUSAL_DETAIL =
  "refused: this site's live release was uploaded (prebuilt), so a content publish must not trigger a box rebuild — it would replace bytes this fleet cannot reproduce. Ship new bytes with `bp cloud site deploy <site> --prebuilt <dir>`.";

// cch-w28-bl: THE REFUSED AUTO-DEPLOY — the row the corpus could not express.
// A content editor publishes; the auto-deploy DECLINES because the live release
// is uploaded bytes the fleet cannot reproduce; refuse/1 mints this row. It is
// `cancelled`, NOT `failed` (so every `st === "failed"` render gate misses it),
// `trigger: "content-auto"` (nobody pressed anything), `source: "prebuilt"`
// (what was PROTECTED, not what was built), and it carries the same actionable
// sentence in BOTH channels — which is exactly why the row must say it once.
const stRefused = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f6",
  status: "cancelled",
  branch: "main",
  trigger: "content-auto",
  source: "prebuilt",
  failure_reason: REFUSAL_DETAIL,
  detail: REFUSAL_DETAIL,
  inserted_at: tMinus(3600),
  updated_at: tMinus(3599),
});
const stPrior = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f5",
  status: "live",
  git_ref: "8c00e1b9f8e7d6c5b4a392817061f5e4d3c2b1a0",
  branch: "main",
  trigger: "manual",
  artifact_url: "file:///var/lib/barkpark/artifacts/acme-web-8c00e1b.tar.gz",
  became_live_at: tMinus(259200),
  inserted_at: tMinus(259244),
  updated_at: tMinus(259200),
});
// cch-w26-s2: the cruel crash sits BETWEEN the two failures already here, so a
// single screen carries the 255-char stage-report crash under measurement, the
// 22-char crash, and the 122-char blocked copy that is this leg's KIND control
// — one route, the defect and its control in the same paint.
// cch-w28-bl adds stRefused directly ABOVE the bare stCancelled: the two
// cancelled rows now sit adjacent, one with something to say and one without,
// so a screenshot shows the rule (copy → panel, silence → pill only) rather
// than one specimen of it. Row count for this scenario: 6 → 7, and cch-w33-s3's
// cut-narration row (below) takes it to 8.
// ── cch-w33-s3: THE CUT NARRATION — the row the console count used to lie about
//
// The population: 2,881 failed production deployments across NINE distinct
// sites whose LAST console entry's own status is still "running" on a row the
// control plane calls failed. The panel printed a bare "3 lines" for those, as
// though the builder had finished talking. Every other committed deploy fixture
// in this file carries a status-less {line, at} console, so no instrument here
// could paint the disclosure — the fixture IS the precondition of the leg.
//
// It carries all three disclosures at once, so one screen shows the whole
// vocabulary:
//   • the ring drop     — `dropped_before` on the OLDEST surviving entry, as
//                         registry.ex's cap_console/1 writes it;
//   • the line chop     — `truncated_from` on a line stored as a 2 KB prefix,
//                         as console_line_meta/1 writes it (the `line` here is
//                         itself a stand-in, not 2,000 literal chars — the
//                         MARKER is what the renderer reads);
//   • the cut narration — a trailing BUILD/running entry under status "failed".
// Neither marker may inflate the count: this console has FOUR entries and the
// panel must read "4 lines · …".
const stCutNarration = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f9",
  status: "failed",
  git_ref: "7d41f0e39a2b5c6d8e0f1a2b3c4d5e6f70819a2b",
  branch: "main",
  trigger: "manual",
  failure_reason: "BUILD failed — the builder stopped reporting",
  inserted_at: tMinus(46800),
  updated_at: tMinus(46702),
  console: [
    { line: "…5 earlier lines dropped by the 300-line cap", at: tMinus(46800), dropped_before: 5, stage: "PLAN", status: "done" },
    { line: "PLAN: resolved acme/web @ 7d41f0e", at: tMinus(46790), stage: "PLAN", status: "done" },
    { line: "npm ERR! " + "…", at: tMinus(46740), stage: "BUILD", status: "running", truncated_from: 5000 },
    { line: "BUILD: nixpacks still working", at: tMinus(46702), stage: "BUILD", status: "running" },
  ],
});
const siteStatesDeployments = [stLive, stCrash, stCrashCruel, stBlocked, stRefused, stCutNarration, stCancelled, stPrior];
const siteStatesSite = Object.assign({}, webSite, {
  current_deployment_id: stLive.id,
});
// ── cch-w26-bl-deploy-row-siblings-unwrapped (charter D322): THE PREVIEW
//    HOSTNAME IS PRODUCED, NEVER TYPED ───────────────────────────────────────
//
// THE SHAPE THIS FILE CARRIED WAS ONE PRODUCTION CANNOT ISSUE. The committed
// fixture read `draft-nav--acme-web.preview.barkpark.cloud`: branch FIRST, site
// slug SECOND, and a `.preview.` label that no producer emits. The real host is
// `Registry.preview_host_for/2` = `preview_slug_for/2` <> "." <>
// `Barkpark.base_domain()`, i.e. `<site_slug>--<branch_slug>-<hash>` <>
// ".barkpark.cloud" — SLUG FIRST, no `.preview.` label. A fixture with the
// halves swapped is not a cosmetic error: it puts the BREAKABLE hyphen-rich
// slug where the producer puts the branch part, so any geometry measured on it
// is geometry of a string the control plane never sends.
//
// THE TWO CAPS ARE NOT THE SAME CAP, and this is the whole premise of the leg
// that measures these rows (overflow-guard.mjs, W27-deploy-ref-branch-bounded):
//   preview_host IS BOUNDED — `preview_slug_for/2`
//     (cloud/lib/barkpark_cloud/registry.ex) clamps the DNS label to 63 by
//     giving the branch part only `63 - len(base) - 9` characters, so the host
//     can never exceed 63 + len(".barkpark.cloud") = 78.
//   THE BRANCH BESIDE IT IS UNCAPPED — `cloud/lib/barkpark_cloud/registry/
//     deployment.ex` declares ZERO `validate_length` on `:branch`, and the
//     webhook path writes `branch_from_ref("refs/heads/" <> branch)` verbatim,
//     whatever GitHub sent. `previewRow()` (app.js) renders that raw branch in
//     `.deploy-ref` on the SAME LINE as the bounded host.
//
// THE ALGORITHM IS MIRRORED HERE, NOT ITS OUTPUT PASTED — the clamp arithmetic
// is the part that decides whether 78 is reachable, so it stays live. Only the
// 6-hex digest is pinned (SubtleCrypto is async and node:crypto is not
// available to the browser that also loads this file). Both digests below are
// the real `:crypto.hash(:sha256, branch) |> Base.encode16(:lower) |>
// binary_part(0, 6)`.
//
// RE-DERIVE (all four numbers this file states):
//   grep -n 'def preview_slug_for' -A 22 cloud/lib/barkpark_cloud/registry.ex
//   node -e 'const c=require("crypto");for(const b of ["draft/nav","renovate_lockfile_maintenance_all_ecosystems_2026_08_03_retry_after_registry_timeout"])console.log(b, c.createHash("sha256").update(b).digest("hex").slice(0,6))'
//   node -e 'import("./cloud/priv/static/__preview__/scenarios.mjs").then(m=>console.log(m.PREVIEW_CRUEL_BRANCH.length, m.PREVIEW_CRUEL_HOST.length))'
export function previewSlugFor(siteSlug, branch, sha6) {
  const base = siteSlug.slice(0, 40);
  const branchRoom = Math.max(63 - base.length - 9, 1);
  const branchSlug = branch
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, branchRoom)
    .replace(/^-+|-+$/g, "");
  const branchPart = branchSlug === "" ? sha6 : branchSlug + "-" + sha6;
  return base + "--" + branchPart;
}
export function previewHostFor(siteSlug, branch, sha6) {
  return previewSlugFor(siteSlug, branch, sha6) + ".barkpark.cloud";
}
// THE CRUEL BRANCH — 84 characters, ONE unbreakable run. Nothing invented: a
// branch name is whatever a person (or their bot) pushed, and this is the shape
// a Renovate-style lockfile branch takes on a repo that spells its branch
// segments with underscores. Underscores matter: `-` and `/` are line-break
// opportunities in CSS, `_` is not, so a hyphenated branch of the same length
// wraps on its own and would have made this fixture green by construction.
export const PREVIEW_CRUEL_BRANCH =
  "renovate_lockfile_maintenance_all_ecosystems_2026_08_03_retry_after_registry_timeout";
// 78 chars — the MAXIMUM host the control plane can issue, produced by the
// mirror above from THIS scenario's own site slug ("acme-web"). It is derived
// from the site under view on purpose: a foreign 40-char slug would reach the
// same 78 while modelling a host production could not issue for this site,
// which is the exact class of error the shape correction above fixes.
export const PREVIEW_CRUEL_HOST = previewHostFor("acme-web", PREVIEW_CRUEL_BRANCH, "453169");
const previewLiveRow = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f6",
  status: "live",
  environment: "preview",
  branch: "draft/nav",
  git_ref: "b7e21c94a5f18e2d6c4b0a9f8e7d6c5b4a392817",
  trigger: "manual",
  preview_host: previewHostFor("acme-web", "draft/nav", "cee407"),
  preview_url: "https://" + previewHostFor("acme-web", "draft/nav", "cee407"),
  became_live_at: tMinus(18000),
  inserted_at: tMinus(18052),
  updated_at: tMinus(18000),
});
const previewFailedRow = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f7",
  status: "failed",
  environment: "preview",
  branch: "fix/nav-overflow",
  git_ref: "c31de8a2b4f5061728394a5b6c7d8e9f0a1b2c3d",
  trigger: "manual",
  failure_reason: "npm run build exited 1",
  inserted_at: tMinus(9000),
  updated_at: tMinus(8981),
});
// THE CRUEL PREVIEW ROW. It is ADDED, never substituted: `previewLiveRow` and
// `previewFailedRow` above are the KIND controls — a 9-char branch and a
// 41-char host — and a remedy that bought the cruel row by shredding ordinary
// prose has to red somewhere. It is LIVE rather than failed on purpose: a
// failed preview row paints a `.deploy-fail` panel, and adding a third of those
// would have changed the population W26-deploy-fail-clip counts.
const previewCruelRow = deployment({
  id: "5b2c1e00-0000-4000-8000-0000000000f9",
  status: "live",
  environment: "preview",
  branch: PREVIEW_CRUEL_BRANCH,
  git_ref: "a4f0d81c72b6935e0d1c8a47f6b3e2905c7d1a8b",
  trigger: "manual",
  preview_host: PREVIEW_CRUEL_HOST,
  preview_url: "https://" + PREVIEW_CRUEL_HOST,
  became_live_at: tMinus(3600),
  inserted_at: tMinus(3661),
  updated_at: tMinus(3600),
});
const siteStatesPreviews = [previewCruelRow, previewLiveRow, previewFailedRow];
// The site domain-status envelope (DomainStatus.check(%Site{})): a CF-proxied
// apex (points_here classified `proxied` — informational, GR27) and a www
// whose TLS is still issuing, with the server-owned remediation verbatim.
const siteStatesDomains = {
  ok: false,
  checked_at: T,
  instance: { id: IDS.siteWeb, host: "production-5b2c1e.barkpark.cloud" },
  domains: [
    {
      host: "acme.com", kind: "custom", overall: "ok",
      stages: [
        { stage: "dns_found", label: "DNS resolves", status: "ok", evidence: "104.21.4.18", remediation: "" },
        { stage: "points_here", label: "Points to this instance", status: "proxied", evidence: "fronted by Cloudflare", remediation: "" },
        { stage: "tls", label: "TLS certificate", status: "ok", evidence: "valid, renews automatically", remediation: "" },
        { stage: "serving", label: "Serving traffic", status: "ok", evidence: "200 in 84ms", remediation: "" },
      ],
    },
    {
      host: "www.acme.com", kind: "custom", overall: "pending",
      stages: [
        { stage: "dns_found", label: "DNS resolves", status: "ok", evidence: "91.98.12.44", remediation: "" },
        { stage: "points_here", label: "Points to this instance", status: "ok", evidence: "matches this box", remediation: "" },
        { stage: "tls", label: "TLS certificate", status: "pending", evidence: "ACME order pending", remediation: "Nothing to do — the certificate usually issues within a few minutes of DNS settling." },
        { stage: "serving", label: "Serving traffic", status: "pending", evidence: "blocked on TLS", remediation: "" },
      ],
    },
  ],
};

// ── G-04 notifications (the crown) ───────────────────────────────────────────
// Backend-true settings_view: transport + masked SMTP secrets ("********" when
// set), the 6 per-event email booleans, the chat half (channels report only
// {type, enabled, configured} — credentials are NEVER echoed), event_routes, and
// the server-owned vocabulary (chat_events = 6 + "test", channel_types = the 5
// ChannelConfig types, chat_default_on = the 4 failure events).
//
// EIGHT AS OF cch-w30-bl. It was SEVEN as of cch-w29-bl, and SIX, NOT NINE
// before that (wave 30 S1).
// `deployment_refused` is the auto-deploy PREBUILT refusal: column, producer and
// console row all landed together, so the fixture seeds it too.
// `deployment_succeeded` came BACK the same way — `Registry`'s
// `dispatch_deployment_terminal/2` fires it from both writers that can land the
// `live` terminal, so the column, the render arms and the console row returned
// with it. `member_invited` and `token_expiring` are still dropped from
// `EmailSettings` end to end — no column, no producer, no toggle. A fixture that
// still seeded them was claiming to be backend-true while describing a backend
// that no longer exists, which is the exact shape wave 30 exists to remove;
// `__app.test.mjs`'s bidirectional census guards app.js but has no reach into
// this file, so it stayed green.
const NOTIF_EVENT_KEYS = [
  "provision_succeeded", "provision_failed", "deployment_failed",
  "deployment_succeeded", "deployment_refused",
  "agent_reachable", "agent_unreachable", "subscription_past_due",
];
const NOTIF_CHAT_EVENTS = NOTIF_EVENT_KEYS.concat(["test"]);
const NOTIF_CHANNEL_TYPES = ["discord", "slack", "telegram", "pushover", "webhook"];
const NOTIF_DEFAULT_ON = ["provision_failed", "deployment_failed", "deployment_refused", "agent_unreachable", "subscription_past_due"];
function notifSettings(over) {
  const base = {
    transport: "instance",
    alerts_enabled: true,
    smtp_host: null, smtp_username: null, smtp_password: null,
    smtp_port: null, smtp_encryption: "starttls",
    api_key: null,
    from_address: null, from_name: null,
    last_test_sent_at: null,
    channels: [],
    event_routes: {},
    chat_events: NOTIF_CHAT_EVENTS,
    channel_types: NOTIF_CHANNEL_TYPES,
    chat_default_on: NOTIF_DEFAULT_ON,
  };
  // Failures default ON, successes OFF (email hygiene, mirrors EmailSettings).
  for (const k of NOTIF_EVENT_KEYS) base[k] = NOTIF_DEFAULT_ON.indexOf(k) !== -1;
  return Object.assign(base, over);
}
const notifConfigured = notifSettings({
  transport: "smtp",
  smtp_host: "********", smtp_username: "********", smtp_password: "********",
  smtp_port: 587, from_address: "alerts@acme.com", from_name: "Acme Alerts",
  last_test_sent_at: tMinus(3600),
  channels: [
    { type: "discord", enabled: true, configured: true },
    { type: "slack", enabled: true, configured: true },
    { type: "telegram", enabled: false, configured: true },
    { type: "pushover", enabled: false, configured: false },
    { type: "webhook", enabled: true, configured: true },
  ],
  event_routes: {
    provision_failed: ["discord", "slack"],
    deployment_failed: ["discord"],
    provision_succeeded: ["slack"],
  },
  provision_succeeded: true, // a customized email boolean
});
const notifEmpty = notifSettings({});
// delivery_json rows: recipient/event/channel/kind/status/attempts/last_error/
// http_status/inserted_at. Chat rows record the channel TYPE as recipient (never
// a webhook URL); email rows carry the address. status ∈ pending|sent|failed.
const notifDeliveries = [
  // A WITHHELD alert (wave 32 S2 `suppressed`). The reaper's per-sweep cap
  // decided this one was not sent; `last_error` carries `Withhold.label/1`'s
  // constant sentence verbatim, and the row exists so a team admin can read the
  // decision instead of reading nothing. It renders `--muted` / "Withheld" — the
  // one status whose pill must NOT read "Pending"/info, which is what it did
  // before the tone branch existed.
  { id: "del_6", recipient: "alerts@acme.com", event: "deployment_failed", channel: "email", kind: "alert", status: "suppressed", attempts: 0, last_error: "Withheld: too many deployment alerts in one sweep, so this one was not sent. The deployment itself is failed in the console.", http_status: null, inserted_at: tMinus(60) },
  { id: "del_5", recipient: "alerts@acme.com", event: "provision_failed", channel: "email", kind: "alert", status: "failed", attempts: 3, last_error: "smtp 550 mailbox unavailable", http_status: null, inserted_at: tMinus(120) },
  { id: "del_4", recipient: "discord", event: "deployment_failed", channel: "discord", kind: "alert", status: "sent", attempts: 1, last_error: null, http_status: 204, inserted_at: tMinus(600) },
  { id: "del_3", recipient: "alerts@acme.com", event: "provision_succeeded", channel: "email", kind: "alert", status: "sent", attempts: 1, last_error: null, http_status: null, inserted_at: tMinus(4000) },
  { id: "del_2", recipient: "slack", event: "provision_failed", channel: "slack", kind: "alert", status: "pending", attempts: 0, last_error: null, http_status: null, inserted_at: tMinus(4200) },
  { id: "del_1", recipient: "alerts@acme.com", event: "subscription_past_due", channel: "email", kind: "transactional", status: "sent", attempts: 1, last_error: null, http_status: 200, inserted_at: tMinus(90000) },
];

// ── MVP-0 Personal Dev Fleet fixtures (PDF-D84/D88/D92) ──────────────────────
// Support rows ride the SAME barkpark envelope with the group record set:
// fleet_role:"support" + fleet_parent_id:<main>. Their provision_steps carry
// ONLY the support vocabulary (create/configure/content/verify/ready — never
// freshen/secure; the SPA folds them over SUPPORT_STEP_ORDER).
const FLEET_IDS = {
  supportProvisioning: "5b2c1e00-0000-4000-8000-0000000000fa",
  supportOnline: "5b2c1e00-0000-4000-8000-0000000000fb",
  supportFailed: "5b2c1e00-0000-4000-8000-0000000000fc",
};

// Mid-provision: create done, configure in flight — the SUPPORT theater
// (5 rows, support labels, no secure rung anywhere).
const supportProvisioningRow = bpBase({
  id: FLEET_IDS.supportProvisioning,
  name: "muscle-1",
  slug: "muscle-1",
  fleet_role: "support",
  fleet_parent_id: IDS.liveInstance,
  fleet_token_id: "ftk-preview-0001",
  inserted_at: tMinus(200),
  provision_steps: [
    { step: "create", status: "started", at: tMinus(180) },
    { step: "create", status: "done", at: tMinus(140) },
    { step: "configure", status: "started", at: tMinus(140), detail: "installing runtime + fleet listener" },
    { step: "configure", status: "progress", at: tMinus(50), detail: "systemd: barkpark-fleet-listener enabled" },
  ],
  provision_console: [
    { line: "provisioning support muscle-1…", at: tMinus(180) },
    { line: "create: server cx23 fsn1 — ok (188.245.0.99)", at: tMinus(140) },
    { line: "configure: installing runtime + agent CLI", at: tMinus(90) },
  ],
});

// Online: host set, provision succeeded — the presence chip reads the main's
// roster (fleetRoster fixture below) and the BYO-key step shows.
const supportOnlineRow = bpBase({
  id: FLEET_IDS.supportOnline,
  name: "muscle-2",
  slug: "muscle-2",
  host: "muscle-2-5b2c1e.fleet.internal",
  fleet_role: "support",
  fleet_parent_id: IDS.liveInstance,
  fleet_token_id: "ftk-preview-0002",
  inserted_at: tMinus(86400),
  provision_status: "succeeded",
});

// Stuck-provisioning FAILED honestly (PDF-D10: never lies online) — verify
// timed out waiting for the first heartbeat.
const supportFailedRow = bpBase({
  id: FLEET_IDS.supportFailed,
  name: "muscle-3",
  slug: "muscle-3",
  fleet_role: "support",
  fleet_parent_id: IDS.liveInstance,
  fleet_token_id: "ftk-preview-0003",
  inserted_at: tMinus(4000),
  provision_status: "failed",
  provision_error: "verify: no heartbeat within the provisioning budget (listener never came online)",
  provision_steps: [
    { step: "create", status: "started", at: tMinus(3900) },
    { step: "create", status: "done", at: tMinus(3860) },
    { step: "configure", status: "started", at: tMinus(3860) },
    { step: "configure", status: "done", at: tMinus(3760) },
    { step: "content", status: "started", at: tMinus(3760) },
    { step: "content", status: "done", at: tMinus(3700) },
    { step: "verify", status: "started", at: tMinus(3700), detail: "polling the main's roster for the first beat" },
    { step: "verify", status: "failed", at: tMinus(3400) },
  ],
  provision_console: [
    { line: "verify: polling https://production-5b2c1e.barkpark.cloud/v1/fleet/roster", at: tMinus(3700) },
    { line: "verify: no beat after 300s — failing the job", at: tMinus(3400) },
    { line: "provision FAILED", at: tMinus(3400) },
  ],
});

// The main's roster (documents envelope, PDF-D21) as the browser reads it
// app-token-direct: muscle-2 beats idle with a validated capacity object.
const fleetRosterFixture = [
  {
    worker: "muscle-2",
    agent: "claude",
    scope: "production",
    status: "idle",
    capacity: { size_class: "standard", slots_total: 1, slots_free: 1 },
    last_seen: tMinus(12),
    ttl_s: 30,
    task: null,
  },
];

// ── MVP-0 offload fixtures (pdf-mvp0-offload-spa, PDF-D87/D92) ───────────────
// An order is an ASSIGNEE-ROUTED type:task doc filed on the MAIN via the
// browser-direct mutate seam; the listener (muscle-2, the online support above)
// claims it, works it, closes it. These model GET /v1/tasks/:id (the .doc
// envelope) + the roster read in each ladder state the watch folds: filed ->
// claimed -> working -> done, plus the blocked terminal.
const OFFLOAD_ORDER_ID = "5b2c1e00-0000-4000-8000-0000000000d1";
const offloadOrderTask = (lifecycle, claim) => ({
  doc_id: OFFLOAD_ORDER_ID,
  type: "task",
  kind: "task",
  title: "Summarise the release notes",
  description: "Read the last three tagged releases and draft a changelog.",
  lifecycle_status: lifecycle,
  assignee: "muscle-2",
  priority: 2,
  claim: claim || null,
  status: "published",
});
const offloadRoster = (status, task) => [{
  worker: "muscle-2", agent: "claude", scope: "production", status,
  capacity: { size_class: "standard", slots_total: 1, slots_free: status === "working" ? 0 : 1 },
  last_seen: tMinus(8), ttl_s: 30, task: task || null,
}];

// ── cch-w21-s3 — THE CRUEL FIXTURE (server-legal worst-case CONTENT) ─────────
// Every other fixture in this file is KIND: the longest host it ships is 32
// characters (`production-5b2c1e.barkpark.cloud`) and the longest name is 10
// ("Production", "Reporting", "Guerrilla"). The SERVER admits far more, and it
// is the server's own caps — not an invented absurdity — that set the numbers
// below:
//   · `validate_length(:custom_host, max: 253)`   registry/barkpark.ex:727
//   · `validate_length(:name, min: 1, max: 255)`  registry/barkpark.ex:466
//   · `@external_host_format` (:109) admits an arbitrary customer-owned FQDN of
//     TWO OR MORE labels, each `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?` — i.e. up
//     to 63 characters with NO break opportunity a text renderer can use.
// `publicUrl()` (`grep -n "function publicUrl" app.js`) PREFERS `custom_host`, so
// an attached customer domain is the DOMINANT real input on `.fleet-url` and
// `.instance-card-url`, not an edge case — and until this fixture existed no
// instrument in this epic had ever driven one.
//
// THE LENGTHS ARE DERIVED AND ASSERTED, NEVER HAND-COUNTED. A fixture whose
// cruelty is a typed-in number stops being cruel the first time somebody edits
// a word in it and nothing complains. The three throws below are the fixture's
// own guard: they run at module load, so every consumer of this file (the
// sweep, the guard, mock.js, the browser) refuses rather than silently
// measuring a fixture that has gone kind.
const CUSTOM_HOST_MAX = 253; // registry/barkpark.ex:727
const BARKPARK_NAME_MAX = 255; // registry/barkpark.ex:466
const DNS_LABEL_MAX = 63; // @external_host_format's `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?`
// The server's external-host regex, copied verbatim from registry/barkpark.ex:109
// so the fixture can PROVE it is admissible rather than assert it in prose.
const EXTERNAL_HOST_FORMAT = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;

// Pad a stem to EXACTLY n characters while keeping the RFC-1035 label shape
// (first and last character alphanumeric). `joiner` decides how cruel the label
// is, and this is the whole difference between a fixture that bites and one
// that does not: a HYPHEN IS A LINE-BREAK OPPORTUNITY. Driven on the first cut
// of this fixture, a hyphen-rich 253-char host wrapped by itself and
// `.fleet-url` never once exceeded its own box — the fixture had quietly made
// itself kind. A 63-character label of unbroken alphanumerics is the real
// worst case the server's own `@external_host_format` admits.
function dnsLabel(stem, n, joiner = "") {
  let s = stem;
  while (s.length < n) s += joiner + stem;
  s = s.slice(0, n);
  return s.endsWith("-") ? s.slice(0, -1) + "0" : s;
}

// 63 + 63 + 63 + 58 + 2, four dots = 253, the cap exactly. THREE maximal DNS
// labels with NO internal hyphen, because 63 unbroken glyphs is the longest run
// a URL can carry with nothing — no space, no slash, no hyphen — for the line
// breaker to use. The fourth label keeps its hyphens: a corpus of pure worst
// case is its own kind of unrealistic, and the mixed host is what a real
// customer domain looks like.
const cruelCustomHost = [
  dnsLabel("redaksjoneltinnholdogdistribusjonforheleforlagsgruppen", DNS_LABEL_MAX),
  dnsLabel("gyldendalnorskforlagogdatterselskaperinorden", DNS_LABEL_MAX),
  dnsLabel("publiseringarkivrettigheterogmetadataplattform", DNS_LABEL_MAX),
  dnsLabel("kundeeid-domene-for-den-nordiske-plattformen", 58, "-"),
  "no",
].join(".");
// 255 characters, the cap exactly, carrying ONE 62-character unbroken token —
// a Norwegian compound is the realistic shape of a name with no break
// opportunity, and it is the token, not the total, that decides min-content.
const cruelName =
  "Produksjon redaksjonsinnholdsplattformenforflersprakligpubliseringinorden " +
  "arkiv og rettighetsstyring for alle avdelinger og datterselskaper i den " +
  "nordiske forlagsgruppen, inkludert distribusjon og metadata for samtlige " +
  "utgivelser fra 1892 og fram til 2026";

if (cruelCustomHost.length !== CUSTOM_HOST_MAX) {
  throw new Error(`cruel fixture: custom_host is ${cruelCustomHost.length} chars, the server's cap is ${CUSTOM_HOST_MAX} — the fixture has gone kind, fix the stems`);
}
if (!EXTERNAL_HOST_FORMAT.test(cruelCustomHost) || cruelCustomHost.split(".").filter((l) => l.length === DNS_LABEL_MAX).length < 1) {
  throw new Error("cruel fixture: custom_host is not admissible by registry/barkpark.ex's @external_host_format, or carries no maximal 63-char label — a fixture the server would REJECT proves nothing");
}
if (cruelName.length !== BARKPARK_NAME_MAX) {
  throw new Error(`cruel fixture: name is ${cruelName.length} chars, the server's cap is ${BARKPARK_NAME_MAX}`);
}

// The cruel row is a LIVE, healthy, up-to-date box: nothing about its state is
// unusual, and that is the point — the ONLY variable is the length of two
// strings a person is allowed to type.
const cruelInstance = bpBase({
  id: "5b2c1e00-0000-4000-8000-0000000000c1",
  name: cruelName,
  slug: "produksjon",
  url: "https://produksjon-c1a2b3.barkpark.cloud",
  host: "produksjon-c1a2b3.barkpark.cloud",
  custom_host: cruelCustomHost,
  health_status: "up",
  agent_status: "online",
  version: "0.9.2",
  git_commit: "c1a2b3d4e5f60718293a4b5c6d7e8f9012345678",
  last_seen_at: tMinus(30),
  update_state: "current",
  update_running_release: "0.9.2",
  update_latest_release: "0.9.2",
  update_checked_at: tMinus(420),
  region: "fsn1",
  server_type: "cx22",
  channel: "prod",
  autoupdate_enabled: true,
  provider: "hetzner",
  provision_status: "succeeded",
});

// ── cch-w23-s1 — THE CRUEL PROVISION ERROR (the SHAPE axis, not the length) ──
// The cruel corpus above bites on two strings a PERSON types. This one bites on
// a string a MACHINE writes, and it is the axis nothing in this file carried:
// the status pill's detail is `bp.provision_error` verbatim (`statusOf` in
// app.js — `kind === "failed"` returns `detail: bp.provision_error`).
//
// THE CAP IS DERIVED FROM THE CHAIN, AND THE CHAIN HAS NO CAP. Unlike
// custom_host (253) and name (255) above, there is NO `validate_length` to cite:
//   · `provision_jobs.error` is a POSTGRES :text column —
//     cloud/priv/repo/migrations/20260702130000_provision_job_error_to_text.exs
//     does `modify :error, :text`, and its own comment says the worker's
//     compound fallback-ladder error "exceeds varchar(255)", i.e. the widening
//     happened BECAUSE a real error was longer than the old bound.
//   · `ProvisionJob.changeset` (registry/provision_job.ex:152) casts `:error`
//     and validates status/kind/attempts/bundle_ref — and carries ZERO
//     `validate_length` on any field. Worker socket to pill, no bound.
// So the effective cap is the RENDER PATH, not a schema number, and the length
// below is derived as the smallest MEASURED biting value rather than the
// largest legal one (2000 — registry.ex's only known string cap — merely makes
// the same defect louder: page 13396 against 320 instead of 3555).
//
// AND THE CRUELTY IS SHAPE, NOT LENGTH — this is what makes a length cap the
// wrong remedy (charter D267). Probed on `mixed-fleet#overview` with all 8
// `.status-pill-detail` iterated per cell: a 1648-char WORD-BROKEN capture
// (longest token 8 chars) is COMPLETELY CLEAN (page 320/320, worst detail
// "none") — it just grows taller, while 512 chars in ONE UNBROKEN TOKEN take
// the page to 3555/320. Re-driven HERE, on this fixture, in the tree that ships
// it: unfixed, `#overview` measured documentElement.scrollWidth 3860 against a
// 320 viewport and the detail 3754/170; `#fleet` 3856/320. It is the TOKEN, not
// the total, that sets min-content, so the fixture below is a single unbroken
// run — and 2000 chars (registry.ex's only known string cap) would only make
// the same defect louder, never a different one.
const CRUEL_PROVISION_ERROR_LEN = 512;
// A base64 body echoed back from a provider API is the realistic shape of an
// error with no break opportunity in it: no space, no hyphen, no slash, no dot.
const cruelProvisionError = (function () {
  const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let s = "";
  while (s.length < CRUEL_PROVISION_ERROR_LEN) s += alphabet;
  return s.slice(0, CRUEL_PROVISION_ERROR_LEN);
})();

// THE FIXTURE'S OWN GUARD, in the fixture and not in a charter — the two
// refusals a cruel CONTENT twin needs (cch-w22 ledger mechanism):
//   GONE KIND   — the string no longer matches the length it cites.
//   BREAKABLE   — the string is maximal but still self-wrapping, so the guard
//                 that consumes it would be green by construction. A single
//                 space or hyphen anywhere in here is enough to make the whole
//                 leg vacuous, which is exactly the accident cch-w21's own
//                 builder shipped on `.fleet-url`.
if (cruelProvisionError.length !== CRUEL_PROVISION_ERROR_LEN) {
  throw new Error(`cruel fixture: provision_error is ${cruelProvisionError.length} chars, the derived biting length is ${CRUEL_PROVISION_ERROR_LEN} — the fixture has GONE KIND`);
}
if (!/^[A-Za-z0-9]+$/.test(cruelProvisionError)) {
  throw new Error("cruel fixture: provision_error carries a line-break opportunity (space, hyphen, slash, dot) — a BREAKABLE string wraps by itself and proves nothing about a wrap remedy");
}

// A FAILED box whose ONLY unusual property is the error string: kind name,
// kind slug, no host (which is what `classifyBp` requires to read "failed").
const cruelProvisionErrorInstance = bpBase({
  id: "5b2c1e00-0000-4000-8000-0000000000c2",
  name: "Analytics",
  slug: "analytics",
  provision_status: "failed",
  provision_error: cruelProvisionError,
  region: "fsn1",
  server_type: "cx22",
  provider: "hetzner",
});

// ── cch-w23-s2 — THE CRUEL IDENTITY (the account modal's content axis) ──────
// The same mechanism as the fleet ledger above (cch-w21-s3): a cap READ OFF the
// schema file that governs it, a string built to sit exactly at that cap with no
// break opportunity, and throws at module load so the fixture cannot quietly go
// kind. This is the ACCOUNT axis, which no fixture in this file had ever driven:
// every `me()` in here is `ada@acme.com`, whose rendered name is three glyphs.
//
// THE CAP IS DERIVED, AND 255 IS INADMISSIBLE. `.am-name` is not a display name:
// `accountModel()` (re-derive with `grep -n 'function accountModel'
// cloud/priv/static/app.js`) sets `name: email.split("@")[0]`, the LOCAL PART
// of the address. `BarkparkCloud.Accounts.User` has no `:name` field and no
// `validate_length(:name, …)` at all — the ONLY cap on this string is
//   · `validate_length(:email, max: 160)`  cloud/lib/barkpark_cloud/accounts/user.ex:165
//   · `@email_format ~r/^[^\s@]+@[^\s@]+$/` (:31) — one "@", at least one
//     character on each side of it, no spaces.
// 160 total, minus the "@", minus at least one domain character, gives a
// DERIVED admissible cap of 158 characters for what `.am-name` paints. The
// backlog row cchi-w22-bl-am-name-unbounded-every-width asked for a 255-char
// fixture: the server would reject that address, so it is a string NO PERSON CAN
// PRODUCE — INADMISSIBLE in this ledger's own vocabulary, and a defect measured
// only at 255 is a defect nobody has. 158 is measured, and 158 still overflows.
const ACCOUNT_EMAIL_MAX = 160; // cloud/lib/barkpark_cloud/accounts/user.ex:165
// The server's own email shape, copied verbatim from user.ex:31 so the fixture
// can PROVE it is an address the server would accept rather than assert it.
const ACCOUNT_EMAIL_FORMAT = /^[^\s@]+@[^\s@]+$/;
// 160 − 1 ("@") − 1 (the shortest domain `@email_format` admits) = 158.
const AM_NAME_MAX = ACCOUNT_EMAIL_MAX - 2;
// A single-character domain is not decoration: it is what MAXIMISES the local
// part under the 160-character cap, and the local part is the whole of what
// `.am-name` renders — the domain never reaches this element. `dnsLabel` (above)
// is reused for the padding because its output is exactly what is wanted here
// too: one unbroken alphanumeric run, no hyphen, no dot, no separator a line
// breaker can use.
const cruelAccountLocal = dnsLabel("kristineandreassenbakkevoldhaugen", AM_NAME_MAX);
const cruelAccountEmail = `${cruelAccountLocal}@x`;

if (cruelAccountLocal.length !== AM_NAME_MAX) {
  throw new Error(`cruel identity: the local part is ${cruelAccountLocal.length} chars, the derived cap is ${AM_NAME_MAX} (email max ${ACCOUNT_EMAIL_MAX} at user.ex:165, minus "@" and one domain char) — GONE KIND, fix the stem`);
}
if (cruelAccountEmail.length !== ACCOUNT_EMAIL_MAX || !ACCOUNT_EMAIL_FORMAT.test(cruelAccountEmail)) {
  throw new Error(`cruel identity: ${cruelAccountEmail.length} chars against a ${ACCOUNT_EMAIL_MAX} cap, or not admissible by user.ex:31's @email_format — an address the server would REJECT proves nothing`);
}
// BREAKABLE (the refusal wave 22 added because wave 21's own builder shipped a
// maximal-but-self-wrapping string): a run at the cap that a text renderer can
// break by itself is not cruel — it wraps, nothing overflows, and the leg goes
// green against a defect that is still shipped. Any of `-`, `.`, `_`, `+`,
// whitespace is a break opportunity, so the local part must carry none.
if (/[^a-z0-9]/.test(cruelAccountLocal)) {
  throw new Error("cruel identity: the local part carries a character a line breaker can use (- . _ + or whitespace) — BREAKABLE, so it would wrap on its own and certify a rule that never bounded it");
}

// cch-w23-bl-cruel-identity-own-scenario — THE CRUEL IDENTITY NOW OWNS A KEY.
// cch-w23-s2 hung this `me` on the EXISTING `account-modal-revoke` because a new
// SCENARIOS key is refused by four instruments that slice was fenced out of —
// smoke.mjs's census guard (exit 1, "NO expectation"), breakpoint-sweep.mjs's
// committed residue literal (exit 2, "UNLISTED scenario"), that sweep's test
// census numbers, and member-authority-sweep.mjs's PIN_TOTAL_SCENARIOS (exit 1).
// It worked, and it lied twice: the cruelty hid inside a scenario whose NAME
// says revoke, and the revoke CLICK ORACLE — four sessions, two DELETEs, a
// danger-tier confirm — ran against a 158-character identity as a side effect,
// on the fixture shoot.sh publishes as the revoke evidence. All four censuses
// are taught in THIS commit, so the identity is now `account-modal-cruel-
// identity` and `account-modal-revoke` is back on the production-dominant
// `me("Guerrilla")` (`ada@acme.com`, three rendered glyphs). The scenario the
// cruel `me` rides is asserted, not assumed: smoke.mjs's FIXTURE_SHAPE_PINS pin
// `me.user.email.length` at 160 on the cruel key and 12 on the revoke key, so
// putting this object back on the click oracle reds BEFORE any scenario boots.
const cruelAccountMe = (function () {
  const m = me("Guerrilla");
  return Object.assign({}, m, { user: Object.assign({}, m.user, { email: cruelAccountEmail }) });
})();

// ── cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts — THE CRUEL MEMBER ──
// The roster's committed emails ship 12-14 characters against
// `validate_length(:email, max: 160)` (cloud/lib/barkpark_cloud/accounts/
// user.ex, validate_email/1) — so the members leg has only ever measured
// fixture kindness on `.set-row-name`, never the cap. Same derivation as the
// account identity above (160 − "@" − the 1-char domain @email_format admits =
// 158 unbroken local characters; lowercase because validate_email/1 downcases
// on the way in), with its OWN stem so two users never share an address.
const cruelMemberLocal = dnsLabel("solveigmargretheeriksdatterholmenkollveien", AM_NAME_MAX);
const cruelMemberEmail = `${cruelMemberLocal}@x`;
if (cruelMemberEmail.length !== ACCOUNT_EMAIL_MAX || !ACCOUNT_EMAIL_FORMAT.test(cruelMemberEmail)) {
  throw new Error(`cruel member: ${cruelMemberEmail.length} chars against the ${ACCOUNT_EMAIL_MAX} cap (user.ex validate_email/1), or not admissible by @email_format — an address the server would REJECT proves nothing`);
}
if (/[^a-z0-9]/.test(cruelMemberLocal)) {
  throw new Error("cruel member: the local part carries a break opportunity — BREAKABLE, it would wrap on its own and certify a bound that never held it");
}
// CONCAT, never an edit: `teamMembers` and every count assertion, residue line
// and wire leg standing on its three rows stays byte-for-byte unmoved (the
// cch-w45-s1 fence). usr_sol is never an ACTOR, so corpusActorEmail's fatal
// unknown-id arm is untouched.
const teamMembersCruel = teamMembers.concat([
  { user_id: "usr_sol", email: cruelMemberEmail, role: "member", joined_at: tMinus(3 * 86400) },
]);

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
  "overview-member-empty-fleet": {
    label: "A plain member on a ZERO-instance team — the welcome runway refuses UP-FRONT instead of selling a launch the server 403s",
    authed: true,
    deepLink: "#overview",
    data: {
      me: me("Ada's Lab", {}, "member", "usr_rex"),
      barkparks: [],
      subscription: trialSub,
      sites: [],
      audit: [],
    },
  },
  "mixed-fleet": {
    label: "A real estate — live, provisioning, failed, suspended + sites & activity",
    authed: true,
    deepLink: "#fleet",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, behindInstance, provisioningInstanceRow, failedInstanceRow, suspendedInstance],
      subscription: activeSub,
      sites: [webSite, blogSite],
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
  // ── Instance Overview as a plain MEMBER (cch-w38-s1) ──────────────────────
  // Byte-identical to `panel-overview` except the /v1/me envelope carries
  // role:"member" — the first plain-member scenario OUTSIDE GR33's settings
  // scope, and the fixture that makes the instance band's authority answer
  // observable at all. On origin/main this screen offered a member a live
  // Decommission (browser-measured: {"port":"4187","meRole":"member",
  // "decommission":{"disabled":false,"visible":true},"totalDisabled":0}); the
  // expectation in smoke.mjs pins the disable-and-explain remedy (D428).
  "panel-overview-member": {
    label: "Instance Overview as a plain member — the lifecycle rail refuses up-front, with the server's own sentence",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member"),
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
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteDeploys, blogSite],
      audit: [],
      deployments: rollbackDeployments,
      // cch-w2-revoke-oracle-round2 — the repo picker's list. openSiteGithub
      // reads GET /v1/github/repos FIRST and paints one of five arms off the
      // answer; with no fixture every scenario got the "Couldn't load your
      // repositories" arm, so #github-disconnect-site — the door to
      // DELETE /v1/sites/:id/github — had never been painted by any instrument.
      // acme/web is webSite's own github_repo, so the select renders it
      // `selected`, which is the state a connected site is actually in.
      githubRepos: [
        { full_name: "acme/web", private: false },
        { full_name: "acme/internal-docs", private: true },
      ],
      // cch-w48-bl — AND THE DEPLOYMENT FACT THE PICKER PRESUPPOSES. loadSite
      // now consults GET /v1/github/installation's `configured` before offering
      // #site-github at all, because on a deployment with NO GitHub App the
      // control can only open a modal that says the feature does not exist —
      // for an admin exactly as for a member.
      //
      // THIS IS NOT A FIXTURE ADDED TO KEEP A GREEN. Without it this scenario
      // falls to the terminal `/v1/` 200 {} at the bottom of route(), whose body
      // carries no `configured` key at all — the band reads "unknown", the door
      // is honestly withheld, and every #site-github assertion in smoke.mjs goes
      // red. That red is CORRECT for a deployment with no GitHub App; it is
      // wrong for THIS scenario, which serves a site already linked to acme/web
      // and a repo picker listing two repos. A site cannot be connected to a
      // GitHub repo on a deployment that has no GitHub App, so `configured:true`
      // is what this fixture was always implicitly claiming — it just had no
      // route arm to say it through.
      github: { connected: true, account_login: "acme-engineering", configured: true },
    },
  },
  // cch-w48-s6: THE SAME SITE SCREEN, entered by a plain MEMBER. Measured before
  // this key existed: all twelve `#site/` scenarios carried the default owner
  // actor, so no instrument had ever rendered the site layer for a member —
  // every member-fence claim about this screen was a claim about a screen the
  // corpus could not paint. Same fixtures as `rollback` (no new data), one
  // moved axis: role.
  "site-member": {
    label: "Site detail as a plain member — the deploy history and its member-legal controls, on the one screen no member fixture had ever entered",
    authed: true,
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member", "usr_rex"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteDeploys, blogSite],
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
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteDeploys, blogSite],
      audit: [],
      deployments: rollbackDeployments,
      promote: {
        status: 409,
        body: { error: "build_in_progress", detail: "a build for this git ref is already in progress — wait for it to finish" },
      },
    },
  },
  // E-01: the global #sites list on v4 — the states-complete deploy-freshness
  // pills (live / rebuilding / deploy-failed / never-deployed), each row's real
  // fields only, and the "on <instance>" link resolving through the fleet.
  sites: {
    label: "Sites list (v4) — deploy-status pills, host, framework, on <instance>, recency",
    authed: true,
    deepLink: "#sites",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: sitesListRows,
      audit: [],
    },
  },

  // cch-w16-s4: THE SAME six rows, rendered through the OTHER row builder.
  // `siteRow` (the instance-workspace Sites card) had NO scenario at all, and
  // every other instance fixture ships `sites: []` or a 100% never-deployed
  // set — so a guard asserting "no Visit anchor here" would have passed for the
  // wrong reason, on an empty list. This drives the SAME sitesListRows (no new
  // fixture data) at the instance route, where the FOUR rows that have served a
  // build must KEEP their door and the two that never have must not have one.
  "sites-on-instance": {
    label: "Instance workspace Sites card — the same six rows through siteRow, doors gated on deployment",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: sitesListRows,
      audit: [],
    },
  },

  // E-03: the site detail carrying the write-only env editor affordance. The
  // modal itself opens behind a click (inert in the smoke shim), so the
  // EXPECTATION drives envModalBodyHtml through the test hook — the same seam
  // the 2FA card uses — to pin the write-only states.
  "env-editor": {
    label: "Site detail — the Edit-environment affordance (write-only, blank-start)",
    authed: true,
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteDeploys, blogSite],
      audit: [],
      deployments: rollbackDeployments,
    },
  },

  // I-01: the team Activity feed regrown on the coalescing grammar — three
  // deploys of one site fold to a ×3 group; a deploy of another site (another
  // actor) stays a singleton; the server-true target_type filter chips render.
  activity: {
    label: "Activity (v4) — coalesced by target, backend-true filter chips",
    authed: true,
    deepLink: "#activity",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: activityFeed,
      // cch-w12-s1: the Who axis is the TEAM ROSTER, read from
      // GET /v1/teams/:id/members. Without a roster here this scenario answered
      // `{members: []}` and the axis degraded to "Everyone / Just me" no matter
      // what the code did — cold boot and warm navigation alike — so the epic's
      // own default Activity fixture was structurally blind to its own Who axis
      // (the cold-boot latch bug lived here undetected for eleven waves).
      // ada is the me() user, so the axis reads Everyone / Just me / lin / rex.
      members: teamMembers,
    },
  },

  // ── G-06 Members (Settings wave, phase 4) ─────────────────────────────────
  // The roster on the GR33 .set-* anatomy: mixed roles (owner "(you)" / admin /
  // member), the admin-only pending-invitations card, per-manageable-row Change
  // role + Remove (destroy-tier typed-confirm, click-driven).
  "members-populated": {
    label: "Members (admin) — roster with mixed roles + pending invitations",
    authed: true,
    deepLink: "#settings/members",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "owner"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      members: teamMembers,
      invitations: teamInvites,
    },
  },
  // cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts — the members roster
  // at the server's own email cap. Identical frame to members-populated (owner
  // actor, buttons rendered) with ONE appended 160-char member, so the members
  // leg finally measures `.set-row-name` under content the server would store.
  "members-cruel-content": {
    label: "Members — cruel content: one roster email at the 160-char server cap, unbroken",
    authed: true,
    deepLink: "#settings/members",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "owner"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      members: teamMembersCruel,
      invitations: teamInvites,
    },
  },
  // The plain-member seam (GR33 plain-member law): read-only roster, NO
  // invitations card, NO Change-role/Remove affordances. me() role "member"
  // makes assignableRoles([]) → canManage false throughout.
  "members-member": {
    label: "Members (member) — read-only roster, no manage affordances",
    authed: true,
    deepLink: "#settings/members",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      members: teamMembers,
      // A member never fetches invitations (the client skips the admin-gated
      // call), so no fixture — the panel renders the roster alone.
    },
  },
  // cch-w45-s1: THE FRAME NO EXISTING CELL PRODUCED — an actor who is not row 0.
  // lin is the acting ADMIN, by IDENTITY (usr_lin) and not merely by rank, over
  // the SAME 3-row roster the owner scenario uses. Three different answers in
  // one panel, each a different arm of the two server predicates:
  //   ada  (owner, outranks the actor) → NEITHER Change role NOR Remove,
  //   lin  (SELF)                      → Change role (the rank arm is bypassed
  //                                      on your own row — self-demotion is a
  //                                      409 STATE refusal the server owns, not
  //                                      an authority one) and NOT Remove,
  //   rex  (member, outranked)         → BOTH.
  // Before this scenario, every rank-relative predicate was only ever asked
  // about rows the actor outranked, so an over-offer on a superior's row could
  // not be seen by any instrument.
  "members-admin-actor": {
    label: "Members (admin actor, not the owner) — the owner's row offers NOTHING, the self row only Change role",
    authed: true,
    deepLink: "#settings/members",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "admin", "usr_lin"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      members: teamMembers,
      invitations: teamInvites,
    },
  },
  // cch-w45-s1: the acting OWNER against a roster that holds a SECOND owner —
  // the one cell where the server's two member verbs disagree. Remove is
  // offered on ozz's row (remove_member_as/3's owner escape hatch) and Change
  // role is NOT (update_member_role_as/4 has no such hatch), so a panel that
  // paints both is over-offering a control the server 403s `outranked`.
  "members-peer-owner": {
    label: "Members (owner) — a PEER OWNER row: Remove is offered, Change role is not (the two verbs disagree)",
    authed: true,
    deepLink: "#settings/members",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "owner"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      members: teamMembersPeerOwner,
      invitations: teamInvites,
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
      sites: [webSite, blogSite],
      audit: liveInstanceAudit,
      instanceEvents: { [IDS.liveInstance]: liveInstanceEvents },
    },
  },
  "timeline-events-only": {
    label: "Timeline as a non-admin — audit 403 degrades to events + one quiet line",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/timeline",
    data: {
      // cch-w35-s4: the label said "as a non-admin" while me() omitted the role
      // argument and me() DEFAULTS to "owner" — so this fixture was an owner
      // being answered 403 by an admin gate, a state the server cannot produce.
      // The role is now the one the scenario claims.
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSite, blogSite],
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
      sites: [webSite, blogSite],
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
      sites: [webSite, blogSite],
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
      sites: [webSite, blogSite],
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
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteInFlight, blogSite],
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
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteDeploys, blogSite],
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
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteMigrated, blogSite],
      audit: [],
      deployments: migratedDeployments,
    },
  },
  // cch-w25-s3: THE DEPLOY RAIL, FAILED — the first scenario in this harness to
  // carry a rail STAGE entry at all. Two sites, two rails, one fixture:
  //   #site/<acme-web>  BUILD failed with the CRUEL string — a real
  //                     module-resolution path off `build_failure_reason`, cut
  //                     by emit(). This is what `.deploy-rail-fail` holds when
  //                     a Node build dies, and nothing between the worker and
  //                     the box breaks it.
  //   #site/<acme-blog> HEALTH failed with the ORDINARY string — the control.
  // Both deployments are still `building`, which is the honest transient window
  // this footer lives in (deployIsActive gates the rail to queued/building/
  // pushing). Driven by overflow-guard's W25-deploy-rail-fail-wrap leg at
  // 320/390/900 in both themes, page AND box.
  "site-deploy-rail-failed": {
    label: "Deploy rail — a stage FAILED mid-flight; the footer carries the builder's raw error",
    authed: true,
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteInFlight, blogSite],
      audit: [],
      deployments: [depRailFailedCruel, depCurrent, depPrior],
      deploymentsBySite: {
        [IDS.siteWeb]: [depRailFailedCruel, depCurrent, depPrior],
        [IDS.siteBlog]: [depRailFailedKind],
      },
    },
  },
  // cch-w29-bl: THE DEPLOY RAIL, LIVE — the OTHER footer, and the first fixture
  // in this harness to render `.deploy-rail-live` at all (see the ledger beside
  // `depRailLive` in the fixtures above for why the state is honest and where
  // the URL comes from). ONE site on purpose: the live footer's anchor and the
  // detail head's `.fleet-url .site-open` carry the SAME derived URL on this
  // one route, so the paid twin is the in-page control for the unpaid one.
  // Driven by overflow-guard's W29-deploy-rail-live-url-wrap leg at 320/360/390
  // in both themes, page AND anchor.
  "site-deploy-rail-live": {
    label: "Deploy rail — every stage done; the footer carries the copyable live URL",
    authed: true,
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSiteDeploys],
      audit: [],
      deployments: [depRailLive, depCurrent, depPrior],
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
      barkparks: [liveInstance], subscription: activeSub, sites: [webSite], audit: [],
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
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true }),
      barkparks: [liveInstance], subscription: activeSub, sites: [webSite], audit: [],
    },
  },
  "operator-visible": {
    label: "v4 shell — /v1/me user.platform_operator:true reveals the sidebar Operator entry (GR9)",
    authed: true,
    deepLink: "#overview",
    data: {
      // Real /v1/me shape: platform_operator is NESTED under `user` (router.ex
      // me/2) — GR37 fixed the flat read; the fixture must mirror the server.
      me: (() => { const m = me("Ops Team", { instance: true }); return { ...m, user: { ...m.user, platform_operator: true } }; })(),
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

  // ── G-05 API tokens (GR34). The list renders real pat_json fields only
  // (id/name/abilities/last_used_at/expires_at/revoked_at/inserted_at) — there is
  // no prefix/preview field, so the row never fakes one. `tokens-member` carries
  // role:"member" so the picker proves the plain-member read-only truth up-front
  // (smoke drives openTokenModal directly — the modal is click-opened).
  "tokens-populated": {
    label: "API tokens — a populated list: mixed abilities (deploy/read/root/write) incl. a revoked row, per-row Revoke",
    authed: true,
    deepLink: "#settings/tokens",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      tokens: [
        { id: "tok_ci", name: "CI deploy key", abilities: ["deploy"], last_used_at: tMinus(3 * 3600), expires_at: tPlus(60 * 86400), revoked_at: null, inserted_at: tMinus(40 * 86400) },
        { id: "tok_read", name: "Read-only dashboard", abilities: ["read"], last_used_at: null, expires_at: null, revoked_at: null, inserted_at: tMinus(10 * 86400) },
        { id: "tok_root", name: "Break-glass root", abilities: ["root"], last_used_at: tMinus(2 * 86400), expires_at: tPlus(365 * 86400), revoked_at: null, inserted_at: tMinus(90 * 86400) },
        { id: "tok_old", name: "Legacy writer", abilities: ["read", "write"], last_used_at: tMinus(50 * 86400), expires_at: tPlus(20 * 86400), revoked_at: tMinus(6 * 86400), inserted_at: tMinus(120 * 86400) },
      ],
    },
  },
  "tokens-empty": {
    label: "API tokens — the empty state: no tokens minted yet, Create-token CTA",
    authed: true,
    deepLink: "#settings/tokens",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      tokens: [],
    },
  },
  "tokens-member": {
    label: "API tokens — plain member: the picker offers read-only scope up-front (no write/deploy/root pickers)",
    authed: true,
    deepLink: "#settings/tokens",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member"),
      barkparks: [liveInstance],
      tokens: [
        { id: "tok_m_read", name: "My read token", abilities: ["read"], last_used_at: tMinus(6 * 3600), expires_at: tPlus(30 * 86400), revoked_at: null, inserted_at: tMinus(4 * 86400) },
      ],
    },
  },
  // cch-w11-s3-token-revoke-shrink-oracle. THE LAST LYING DESTROY VERB, given
  // its own scenario rather than bolted onto `tokens-populated` — that one
  // asserts `countMatches(html, 'class="token-row') === 4`, so a destroy driven
  // inside it consumes a row BEFORE the assertion and reds it as a probe
  // artifact rather than a defect. Modelled on `account-modal-revoke`: real
  // clicks, a stateful route, and a list that must actually SHRINK.
  // Deliberately NOT named `account-modal*` (shoot.sh's `?modal=account` case),
  // and deliberately carrying its OWN token array — a shared fixture that a
  // destroy mutates would make scenario ORDER decide truth for the readers.
  "tokens-revoke": {
    label: "API tokens — the revoke path, driven by real clicks: confirm sheet, one DELETE on the wire, and the list actually shrinks 4 → 3",
    authed: true,
    deepLink: "#settings/tokens",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      tokens: [
        { id: "tok_rv_ci", name: "CI deploy key", abilities: ["deploy"], last_used_at: tMinus(3 * 3600), expires_at: tPlus(60 * 86400), revoked_at: null, inserted_at: tMinus(40 * 86400) },
        { id: "tok_rv_read", name: "Read-only dashboard", abilities: ["read"], last_used_at: null, expires_at: null, revoked_at: null, inserted_at: tMinus(10 * 86400) },
        { id: "tok_rv_root", name: "Break-glass root", abilities: ["root"], last_used_at: tMinus(2 * 86400), expires_at: tPlus(365 * 86400), revoked_at: null, inserted_at: tMinus(90 * 86400) },
        // Already revoked ⇒ renders a row but NO Revoke button, so the row
        // count (4) and the revokable count (3) differ and a check that
        // confuses them cannot pass.
        { id: "tok_rv_old", name: "Legacy writer", abilities: ["read", "write"], last_used_at: tMinus(50 * 86400), expires_at: tPlus(20 * 86400), revoked_at: tMinus(6 * 86400), inserted_at: tMinus(120 * 86400) },
      ],
    },
  },
  "tokens-reveal": {
    label: "API tokens — the plaintext-once reveal: amber only-time banner + mono input-affix + copy",
    authed: true,
    deepLink: "#settings/tokens",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      tokens: [],
      // The mint POST answers the plaintext ONCE + pat_json (no plaintext/hash on
      // the row); smoke drives revealToken() directly with this shape.
      // THE LENGTH IS THE SERVER'S, NOT A ROUND NUMBER (cch-w21-s4): the real
      // PAT is 51 characters — accounts.ex:857 `plaintext = "bpc_pat_" <>
      // generate_token()` over `defp generate_token, do:
      // :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)`
      // = 8 + 43. This fixture shipped 50 and so understated the reveal's
      // narrow-viewport clip by one character on every driven cell.
      tokenMint: {
        status: 201,
        body: {
          token: "bpc_pat_3xampLEon1yShoWnoNCEabcdef0123456789ABCDEFg",
          pat: { id: "tok_new", name: "CI deploy key", abilities: ["deploy"], last_used_at: null, expires_at: tPlus(30 * 86400), revoked_at: null, inserted_at: T },
        },
      },
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
        // W18 REVIEW: schemed with liveInstance — the last bare `url:` fixture.
        url: "https://hugin-5b2c1e.barkpark.cloud",
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
          // W18 REVIEW: schemed with liveInstance. This box sits BESIDE
          // `liveInstance` on the front screen (`?scen=overview-attention`),
          // and `.instance-card-url` renders `publicUrl(bp)` — i.e. `bp.url` —
          // as TEXT. Leaving this one bare printed two adjacent cards in two
          // different address formats on the most-seen screen in the product.
          url: "https://reporting-5b2c1e.barkpark.cloud",
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
  // ── cch-w34-s6 (REVIEW ADDITION): the NEVER-REPORTED box, on screen ────────
  // The slice made `unreported` reachable and proved it through the pure hooks
  // and 26 harness assertions — but shipped no fixture, so the one state a
  // person most wants to LOOK at was the only console state with no fixture at
  // all. It is also the state that first reaches the `neutral` role, whose
  // `.instance-card--neutral` rule did not exist until this review — a gap no
  // amount of hook-level assertion could have surfaced, and that this fixture
  // surfaced immediately. HONEST SCOPE: it is registered as breakpoint-sweep
  // RESIDUE, not as a cell — exactly where its sibling `overview-attention`
  // sits — so it is RENDERED and asserted by smoke.mjs but not width-walked.
  //
  // The row is production's own 3-of-8 shape, not an invented one: host set and
  // provisioning SUCCEEDED, `health_status: "up"` and `agent_status: "offline"`
  // still carrying the values written at adoption time (cch-w34-s2 fixed the
  // WRITERS and shipped no backfill, so legacy rows look exactly like this),
  // `last_seen_at: null`, `unreachable_count: 3`, created 38 days ago. The
  // point of the fixture is that the cached green "up" is on the row and the
  // console must NOT print it. `liveInstance` is the kind control beside it.
  "overview-never-reported": {
    label: "Overview never-reported — a box the control plane has never heard from names the absence, not a cached health",
    authed: true,
    deepLink: "#overview",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [
        bpBase({
          id: "bp-ov-unreported",
          name: "Archive",
          slug: "archive",
          url: "https://archive-5b2c1e.barkpark.cloud",
          host: "archive-5b2c1e.barkpark.cloud",
          // The stale cached columns — deliberately the OPTIMISTIC pair.
          health_status: "up",
          agent_status: "offline",
          version: null,
          last_seen_at: null,
          unreachable_count: 3,
          inserted_at: tMinus(38 * 86400),
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
          // W18 REVIEW: the three fleet-v4 rows are schemed for the same reason
          // as liveInstance — `.fleet-url` renders `publicUrl(bp)` as text, so a
          // half-schemed fleet list is a formatting inconsistency a person sees.
          // Driven: overflow-guard's W15 leg stays 90/90 with the 8 extra
          // characters at every width from 320 up.
          url: "https://gyldendal-506f0.barkpark.cloud", host: "gyldendal-506f0.barkpark.cloud",
          health_status: "down", agent_status: "online", version: "0.2.25",
          update_state: "current", update_latest_release: "0.2.25",
          region: "fsn1", server_type: "cx22", channel: "prod", autoupdate_enabled: true,
          provider: "hetzner", provision_status: "succeeded",
        }),
        bpBase({
          id: "5b2c1e00-0000-4000-8000-0000000000f2", name: "Guerrilla", slug: "guerrilla",
          url: "https://guerrilla-77a1c.barkpark.cloud", host: "guerrilla-77a1c.barkpark.cloud",
          health_status: "up", agent_status: "online", version: "0.1.0",
          update_state: "behind", update_running_release: "0.1.0", update_latest_release: "0.2.25",
          region: "fsn1", server_type: "cx32", channel: "prod", autoupdate_enabled: true,
          provider: "hetzner", provision_status: "succeeded",
        }),
        bpBase({
          id: "5b2c1e00-0000-4000-8000-0000000000f3", name: "Marketing", slug: "marketing",
          url: "https://marketing-2b9c4.barkpark.cloud", host: "marketing-2b9c4.barkpark.cloud",
          health_status: "up", agent_status: "online", version: "0.2.25",
          region: "hel1", server_type: "cx22", channel: "prod", autoupdate_enabled: false,
          // cch-w55-s3 — plane-legal slug (see the `suspended_reason` note above).
          provider: "azure", suspended: true, suspended_reason: "billing_past_due",
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
  // ── cch-w21-s3: THE CRUEL CONTENT TWIN of the fleet list ──────────────────
  // Same route, same components, same lifecycle states as `fleet-v4` above —
  // the ONLY variable is the LENGTH of two strings the server already accepts
  // (see the cruelCustomHost / cruelName note above the table). It carries a
  // KIND neighbour (`liveInstance`, 32-char host / 10-char name) in the same
  // DOM on purpose: a bound that fixes the cruel row by shredding the kind one
  // has to be visible in the SAME cell, not in a different fixture's run.
  // Reached on BOTH `#fleet` (the table) and `#overview` (the instance cards),
  // because the two unbounded hosts live one on each screen.
  //
  // cch-w23-s1 adds a THIRD row on the SHAPE axis: `cruelProvisionErrorInstance`
  // carries a 512-character single-token provision error (see its derivation
  // above) into `.status-pill-detail`, a host the two typed strings above never
  // reach. Its name and slug are deliberately KIND so the error is the only
  // variable, and `liveInstance` stays the kind control for both axes.
  "fleet-cruel-content": {
    label: "Cruel content — a 253-char custom domain, a 255-char name and a 512-char single-token provision error, all server-legal",
    authed: true,
    deepLink: "#fleet",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [cruelInstance, cruelProvisionErrorInstance, liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  // cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts (absorbing
  // cch-w15-bl-detail-url-fixture-never-overflows): the CRUEL instance's OWN
  // detail screen. fleet-cruel-content already carries cruelInstance and its
  // 253-char custom_host (registry/barkpark.ex custom_host cap under
  // @external_host_format), but no committed scenario ever deep-linked
  // #instance/<cruel id> — so `.detail-url-text`, which renders
  // publicUrl(bp) = "https://" + custom_host, had never rendered a string that
  // overflows anywhere in the corpus (the w15 measurement: sw == cw == 240 in
  // EVERY cell). Same data, the cruel box's route.
  "instance-cruel-detail": {
    label: "Instance detail — cruel content: the 253-char custom host reaches .detail-url-text, with the copy-btn carrying the full value",
    authed: true,
    deepLink: "#instance/5b2c1e00-0000-4000-8000-0000000000c1",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [cruelInstance, cruelProvisionErrorInstance, liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
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
  // ── gr-p3 D-04: the timeline coalescing grammar (tail-append, OC9) ─────────
  // A 10-beat health-down burst (one per minute) that MUST fold to one
  // "<thing> × N · cadence · shared verdict" row, with a `status` change beside
  // it proving a singleton passes through untouched. A `tls` event stood beside
  // it too until wave 51 removed it, and cch-w51-bl then struck `tls` from
  // AgentEvent's @types — this corpus manufactures nothing the control plane
  // cannot write, which is the arm-C rule the vocabulary census enforces.
  "timeline-coalesced": {
    label: "Timeline coalescing — a 10-beat health-down burst folds to ONE worst-verdict row (D-04, styleguide §07)",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/timeline",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [webSite, blogSite],
      audit: liveInstanceAudit,
      instanceEvents: {
        [IDS.liveInstance]: [
          // Newest-first, exactly as GET /v1/barkparks/:id/events serves them.
          ...Array.from({ length: 10 }, (_, i) =>
            ev(40 - i, "health", { health: "down", disk_used_pct: 91, pg_size_mb: 212 }, tMinus(60 + i * 60))),
          ev(20, "status", { transition: "offline", reason: "agent_silent" }, tMinus(700)),
        ],
      },
    },
  },

  // ── D-05 (tail-append, OC9): the v4 auto-disabled endpoint + a failed delivery
  // The Webhooks tab with an AUTO-DISABLED endpoint — its COUNT-FREE banner shows
  // in the list (Re-enable offered, no client-authored failure count), plus a
  // webhookDeliveries fixture carrying a failed (HTTP 500) row so a headless shot
  // can open the v4 "Recent deliveries" card. smoke's click is inert, so smoke
  // asserts the list-level count-free banner; the deliveries pill grammar + the
  // real-response replay toast are unit-pinned in __app.test.mjs.
  "webhooks-autodisabled": {
    label: "Webhooks sub-tab — an auto-disabled endpoint (count-free banner) + a failed delivery",
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
          id: "wh-dead", name: "Reindex hook", url: "https://hooks.acme.com/reindex",
          active: false, events: ["publish"], types: [],
          auto_disabled_at: tMinus(1800),
          disable_reason: "endpoint returned 500 Internal Server Error",
          consecutive_failures: 20, updated_at: tMinus(1800),
        },
      ],
      webhookDeliveries: {
        "wh-dead": [
          {
            event_id: 5012, status: "failed_giveup", last_status_code: 500,
            last_latency_ms: 182, attempts: 3,
            last_error_text: "connect ECONNREFUSED 10.0.0.9:443", updated_at: tMinus(1800),
          },
          {
            event_id: 5009, status: "delivered", last_status_code: 200,
            last_latency_ms: 84, attempts: 1, updated_at: tMinus(7200),
          },
        ],
      },
    },
  },
  // ── D-07 metrics — the stale + absent beats (tail-append, OC9) ─────────────
  // The live beat is the `metrics` scenario above; these complete the S12
  // live/stale/absent trichotomy. Stale keeps the last-known series (a stale
  // read shows history, never blank); absent has no series at all (the honest
  // waiting panel, never a zeroed chart). Both still carry the dashed
  // request-level stubs beneath a real read — but the absent panel does not.
  "metrics-stale": {
    label: "Metrics tab — a stale beat: last-known vitals flagged 'Agent offline' + the last-seen age",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/metrics",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      metrics: { ...metricsLive, beat: { status: "stale", age_seconds: 480, last_seen_at: tMinus(480) } },
    },
  },
  "metrics-absent": {
    label: "Metrics tab — no beat ever: the honest waiting panel, never a zeroed chart or a fake stub",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance + "/metrics",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      metrics: { ok: true, beat: { status: "absent" }, series: {} },
    },
  },
  // ── gr-p3-site-detail (E-02): the v4 site detail, states-complete ─────────
  // The whole ladder in one shot: live current (Redeploy + Now live), a crash
  // failure (red panel + console), a born-failed github push (blocked amber),
  // a cancelled row (hollow dashed pill — a terminal, deliberate stop, visibly
  // NOT the filled grey a queued row wears), a prior live row (Roll back to this) —
  // plus branch previews (live + failed) and the domains rungs (proxied apex,
  // www waiting on TLS with the server's remediation verbatim).
  "site-states": {
    label: "Site detail v4 — states-complete ladder + previews + domains rungs",
    authed: true,
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [siteStatesSite, blogSite],
      audit: [],
      deployments: siteStatesDeployments,
      previews: siteStatesPreviews,
      siteDomainStatus: siteStatesDomains,
    },
  },

  // ── cch-deploy-detail-render-has-no-cap: the live sub-caption at its store cap
  // Two builds in one paint, both mid-flight: the cruel 2 KB caption and the
  // ordinary one a builder actually emits. The point of the screen is the
  // VERTICAL room the first one takes and the second one must keep.
  "deploy-detail-cruel": {
    label: "Deploy sub-caption at the store cap — 2 KB of build narration under the status pill, beside an ordinary one",
    authed: true,
    deepLink: "#site/" + IDS.siteWeb,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [deployDetailCruelSite, blogSite],
      audit: [],
      deployments: deployDetailCruelDeployments,
    },
  },

  // ── ssw8 (charter D82): the content binding on the site surfaces ────────────
  // One fixture list, three deep links — the same three rows render as siteRow
  // chips on the instance workspace while each scenario opens ONE of them on the
  // detail rail. Nothing here is invented: every value is a field site_json/2
  // serializes, and the UNKNOWN row's honesty comes from a field being ABSENT.
  "site-binding-bound": {
    label: "Site binding — bound: the triple agrees with itself and a read token exists",
    authed: true,
    deepLink: "#site/" + boundSite.id,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: bindingSites,
      audit: [],
      deployments: [],
    },
  },
  "site-binding-unknown": {
    label: "Site binding — unknown: an older control plane sends no triple and no content_bound; the rail says so",
    authed: true,
    deepLink: "#site/" + unknownBindingSite.id,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: bindingSites,
      audit: [],
      deployments: [],
    },
  },
  "site-binding-mismatch": {
    label: "Site binding — mismatch: the payload's two spellings of the dataset disagree; both are shown, neither resolved",
    authed: true,
    deepLink: "#site/" + mismatchedBindingSite.id,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: bindingSites,
      audit: [],
      deployments: [],
    },
  },

  // ── gr-p4-billing (G-01): plain-member + cancel states (tail-append, OC9) ────
  // A plain MEMBER of a PAID team: the billing surface must render read-only —
  // the plan STATE with zero write CTAs (never a disabled ghost) and the honest
  // "Only the team owner can manage billing." line. Role rides me()'s 3rd param
  // (the hygiene seam); the subscription is a healthy Supporter so there IS a
  // paid plan an owner could manage — proving the gate hides it for the member,
  // not the absence of a plan.
  "billing-member": {
    label: "Billing — a plain member of a paid team: read-only plan, no manage/cancel CTA, owner-gate copy",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member"),
      barkparks: [liveInstance],
      subscription: {
        plan: "supporter",
        status: "active",
        past_due: false,
        cancel_at_period_end: false,
        current_period_end: new Date(Date.parse(T) + 18 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(40 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
    },
  },
  // cch-w39-s1 — THE HEADLINE DEFECT, DRIVEN. A genuine OWNER of a paid team
  // whose /v1/me 500s: on origin/main billingIsOwner() answered false (a
  // two-valued read of a three-valued fact) and #billing-manage told the OWNER
  // "Only the team owner can manage billing." with nothing on the page to
  // press. It consumes the meFault override cch-w37-s6 already merged (route()
  // in this file) rather than minting a second one, and deep-links to #billing
  // — a residue family that already exists, so no 14th family is created.
  "billing-me-unreadable": {
    label: "Billing — an OWNER whose /v1/me 500s: the page reports the failed check with a retry instead of accusing them of not being the owner",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      meFault: { status: 500, body: { error: "internal" } },
      barkparks: [liveInstance],
      subscription: {
        plan: "supporter",
        status: "active",
        past_due: false,
        cancel_at_period_end: false,
        current_period_end: new Date(Date.parse(T) + 18 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(40 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
    },
  },
  // cchi-w39-bl-mefault-must-be-exhaustible — the RECOVERY twin of
  // billing-me-unreadable: the same owner, the same 500, but a ONE-SHOT fault
  // (`times: 1` consumes through the per-boot state bag in route()). The first
  // /v1/me read fails and the unknown arm mounts the shared [data-me-retry];
  // the retry's re-read heals, and the owner affordances must RETURN. Without
  // this fixture the crown's "the unknown has an exit" claim stops at "the
  // button is present and pressable" — the recovery half would be asserted,
  // never measured.
  "billing-me-recovers": {
    label: "Billing — the owner's /v1/me 500s ONCE: the shared retry re-reads, the answer lands, and Manage billing returns",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      meFault: { status: 500, body: { error: "internal" }, times: 1 },
      barkparks: [liveInstance],
      subscription: {
        plan: "supporter",
        status: "active",
        past_due: false,
        cancel_at_period_end: false,
        current_period_end: new Date(Date.parse(T) + 18 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(40 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
    },
  },

  // The owner AFTER an in-app cancel: the subscription is now cancel_at_period_end
  // (grace) — the plan card reads "Access until {date}" + the Ending badge, the
  // Cancel section is GONE (a second cancel is a no-op), but Manage billing stays
  // (the owner can still open the portal / resubscribe). d.billingCancel drives
  // the mock's cancel POST for the interactive preview; smoke exercises the
  // SETTLED state (its clicks are inert).
  "billing-cancelling": {
    label: "Billing — owner after cancel: grace 'Access until' + Ending badge, Cancel section retired, Manage billing kept",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: {
        plan: "supporter",
        status: "active",
        past_due: false,
        cancel_at_period_end: true,
        current_period_end: new Date(Date.parse(T) + 12 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(45 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
      // The failure variant the danger modal designs for: a wrong password re-poll
      // answers 401 password_invalid (the mock's cancel POST for the preview).
      billingCancel: { status: 401, body: { error: "password_invalid" } },
    },
  },
  // ── gr-p4 G-02+G-03 provider settings — the honesty flagship (tail-append) ──
  // Four states on the .set-* anatomy: a populated roster + hybrid connect card
  // + the honest capability matrix; the empty roster; the connect-card verify-
  // before-save remediation state; and the plain-member read-only view (roster +
  // matrix, ZERO write affordances). GET /v1/providers is member-readable, so the
  // member scenario still paints the roster + matrix — just no connect/disconnect.
  "providers-connected": {
    label: "Providers — roster (Hetzner + Azure), the hybrid connect card, and the honest capability matrix",
    authed: true,
    deepLink: "#settings/providers",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance], subscription: activeSub, sites: [], audit: [],
      providers: connectedProviders,
      capabilities: settingsProviderCapabilities,
      // cch-w2-revoke-oracle-round2 — THE SAME console-side fixture
      // providers-member already carries (see its comment for why
      // connected:true cannot come from the live control plane), moved onto the
      // OWNER actor as well. It has to be here and not there: githubCardHtml
      // paints #github-disconnect only `if (canWrite)`, so on the member
      // scenario the DELETE has no door to come through, and
      // DELETE /v1/github/installation had no click-driven oracle anywhere.
      // install_url is carried so the POST-DISCONNECT repaint is the honest
      // reconnect door ("Connect GitHub") rather than githubCardHtml's
      // last-resort "aren't configured yet" arm, which would be a false claim
      // about the deployment on a Barkpark that just disconnected.
      github: {
        connected: true, account_login: "acme-engineering", configured: true,
        install_url: "https://github.com/apps/barkpark-cloud/installations/new",
      },
    },
  },
  "providers-empty": {
    label: "Providers — nothing connected yet: the empty roster, the connect card armed on the first provider, and the server's REAL 275-character Azure remediation when verify-before-save fails",
    authed: true,
    deepLink: "#settings/providers",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [], subscription: activeSub, sites: [], audit: [],
      providers: [],
      capabilities: settingsProviderCapabilities,
      // ── W23-S6: THE REMEDIATION COPY THE SERVER ACTUALLY SENDS ────────────
      // `providers-unverified` below carries a 168-character PARAPHRASE, and
      // that string measures CLEAN at every phone geometry: on it the defect
      // this fixture exists to expose cannot be produced, so a guard driving
      // only it is green by construction (wave-23 clause 4). This is
      // `connect_remediation("azure")` VERBATIM — the LONGEST clause the
      // server can send — living on the scenario the defect was reproduced on
      // (`providers-empty#settings/providers`, 390x390).
      //
      // The four clauses in cloud/lib/barkpark_cloud/failure_copy.ex:361-375
      // measure 169 (hetzner) / 275 (azure) / 206 (cloudflare) / 88 (generic).
      // Re-derive, do not quote:
      //   node -e 'const s=require("fs").readFileSync("cloud/lib/barkpark_cloud/failure_copy.ex","utf8").split("\n");
      //            const i=s.findIndex(l=>l.includes(`def connect_remediation("hetzner")`));
      //            for(let k=i;k<i+16;k++){const m=s[k].match(/^\s*"(.*)"\s*$/); if(m) console.log(m[1].length)}'
      // (The filed row cch-w21-bl-... cites `registry/failure_copy.ex`, which
      // does not exist, and 89 for the generic clause, which is 88.)
      //
      // IT RIDES AN EXISTING KEY ON PURPOSE. A NEW `SCENARIOS` key is refused
      // by breakpoint-sweep.mjs's census — "UNLISTED scenario … no cell renders
      // it and SCENARIO_RESIDUE does not carry it", exit 2 — and that file is
      // outside this slice's fence. Filed as
      // cch-w23-bl-real-hetzner-remediation-scenario.
      providerConnect: {
        status: 422,
        body: {
          error: "provider_unverified",
          // connect_remediation("azure") — 275 chars, VERBATIM.
          remediation: "We couldn't authenticate to Azure with those details. In the Azure Portal → App registrations → your app, re-check the Directory (tenant) ID, Application (client) ID and Subscription ID, and that the client secret under Certificates & secrets hasn't expired — then reconnect.",
        },
      },
    },
  },
  "providers-unverified": {
    label: "Providers — the connect card's verify-before-save remediation (server names the exact console fix)",
    authed: true,
    deepLink: "#settings/providers",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [], subscription: activeSub, sites: [], audit: [],
      providers: [],
      capabilities: settingsProviderCapabilities,
      // POST /v1/providers preflight fails → ALL causes collapse to the single
      // provider_unverified + the server-owned remediation string, rendered
      // verbatim in-card when the operator clicks Verify & connect.
      providerConnect: {
        status: 422,
        body: {
          error: "provider_unverified",
          remediation: "We couldn't verify this token. In the Hetzner Cloud console open Security → API tokens, revoke the old token, then generate a fresh Read & Write token for this project.",
        },
      },
    },
  },
  "providers-member": {
    label: "Providers — a plain member: read-only roster + matrix, NO connect card and NO Disconnect (GR33 plain-member law)",
    authed: true,
    deepLink: "#settings/providers",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member"),
      barkparks: [liveInstance], subscription: activeSub, sites: [], audit: [],
      providers: connectedProviders,
      capabilities: settingsProviderCapabilities,
      // cch-w48-s6 — A CONSOLE-SIDE FIXTURE, and it is NOT "the state the
      // server sends". This is the knowing EXCEPTION to cch-w43-s1's rule that
      // the corpus mints the envelope the server mints, and it is cited here
      // rather than left implicit: the live control plane CANNOT mint
      // connected:true. `record_installation/2` has one caller and that caller
      // 503s without GitHub App credentials, and the running control plane
      // carries ZERO ^GITHUB env — so on the deployed system this endpoint
      // answers the not-configured arm, always. The shape below is read off
      // app.js's own reader (`renderGithub`: connected / account_login /
      // configured / install_url — no secret), which is the contract this
      // fixture is FOR: arm 1 of renderGithub had never been painted by ANY
      // instrument, so every claim about what a member sees on the GitHub card
      // was a claim about markup nothing rendered. It rides the EXISTING
      // providers-member scenario, not a new key, so it moves zero typed
      // integers — nothing in the census counts fixture keys.
      github: { connected: true, account_login: "acme-engineering", configured: true },
    },
  },
  // ── G-04 notifications: the crown, states-complete ─────────────────────────
  "notif-configured": {
    label: "Notifications — SMTP transport, chat channels wired, matrix customized, delivery log populated",
    authed: true,
    deepLink: "#notifications",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      notifSettings: notifConfigured,
      notifDeliveries: notifDeliveries,
    },
  },
  "notif-empty": {
    label: "Notifications — first run: platform transport, no channels, empty delivery log",
    authed: true,
    deepLink: "#notifications",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      notifSettings: notifEmpty,
      notifDeliveries: [],
    },
  },
  "notif-member": {
    label: "Notifications as a plain member — read-only email, no save-rows, no admin sections",
    authed: true,
    deepLink: "#notifications",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }, "member"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      notifSettings: notifConfigured,
      notifDeliveries: notifDeliveries,
    },
  },
  "notif-deliveries-error": {
    label: "Notifications — the deliveries route errors: the log degrades honestly",
    authed: true,
    deepLink: "#notifications",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      notifSettings: notifConfigured,
      notifDeliveriesError: true, // GET /v1/notifications/deliveries → 500
    },
  },

  // ── gr-p5 OPERATOR CONSOLE (GR39/GR40/GR48/GR49/GR50) ─────────────────────
  // The fleet-wide, cross-team surface behind the role-gated sidebar entry.
  // Fixtures are the PROBE-VERIFIED wire shapes, not the design mock:
  //   /v1/operator/fleet      → {barkparks:[{id,name,update_state,channel,
  //                              autoupdate_triggered_at}], staging_gate_open}
  //                              — the gate flag is TOP-LEVEL, never per-row.
  //   /v1/operator/warm-pool  → {ready:n}, a bare integer under one key.
  //   /v1/operator/autoupdate → {halted:bool}.
  //   /v1/operator/deliveries → {deliveries:[delivery_json]}.
  // Timestamps carry six microsecond digits + a literal Z; a freshly-registered
  // box has autoupdate_triggered_at: null and update_state "unknown".
  "operator-console": {
    label: "Operator console — rolling: a settling canary, the staging gate open, warm pool ready, digest never sent",
    authed: true,
    deepLink: "#operator",
    data: {
      me: operatorMe("Acme Inc"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      operatorAutoupdate: { halted: false },
      operatorFleet: {
        barkparks: [
          { id: "5b2c1e00-0000-4000-8000-0000000000f1", name: "acme-canary", channel: "staging", update_state: "current", autoupdate_triggered_at: null },
          { id: "5b2c1e00-0000-4000-8000-0000000000f2", name: "acme-prod", channel: "prod", update_state: "behind", autoupdate_triggered_at: tMinus(9 * 60) },
          { id: "5b2c1e00-0000-4000-8000-0000000000f3", name: "beta-prod", channel: "prod", update_state: "behind", autoupdate_triggered_at: null },
          { id: "5b2c1e00-0000-4000-8000-0000000000f4", name: "fresh-box", channel: "prod", update_state: "unknown", autoupdate_triggered_at: null },
          { id: "5b2c1e00-0000-4000-8000-0000000000f5", name: "optout-prod", channel: "prod", update_state: "disabled", autoupdate_triggered_at: null },
        ],
        staging_gate_open: true,
      },
      operatorWarmPool: { ready: 2 },
      // Prod truth today: zero fleet_digest rows have ever been written.
      operatorDeliveries: [],
      // A census over a window big enough for `rate/2` to answer: 1,840
      // attempted rows, so the percentage renders WITH its denominator and the
      // class table carries each class's own share node.
      operatorCensus: {
        window: censusWindow(7),
        volume: 1840,
        failed: 312,
        live: 1402,
        in_flight: 21,
        cancelled: 6,
        residual: 0,
        deferred_total: 99,
        failure_rate: censusRate(312, 1840, CENSUS_ATTEMPTED_BASIS),
        live_rate: censusRate(1402, 1840, CENSUS_ATTEMPTED_BASIS),
        classes: [
          censusClass("BUILD_FAILED", "the site build exited non-zero", 181, 312),
          censusClass("BOX_UNREACHABLE", "the instance could not be reached at all", 74, 312),
          censusClass("UNCLASSIFIED", "not yet named by the ledger", 57, 312),
        ],
        min_sample: 200,
      },
    },
  },
  // The braked fleet: halted banner + Resume, the staging gate CLOSED, an empty
  // warm pool (a designed state, not an error), and a digest log with a failure.
  "operator-halted": {
    label: "Operator console — halted brake, staging gate closed, empty warm pool, digest log with a failure",
    authed: true,
    deepLink: "#operator",
    data: {
      me: operatorMe("Acme Inc"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      operatorAutoupdate: { halted: true, halted_reason: "bad release 0.5.0" },
      operatorFleet: {
        barkparks: [
          { id: "5b2c1e00-0000-4000-8000-0000000000f1", name: "acme-canary", channel: "staging", update_state: "behind", autoupdate_triggered_at: null },
          { id: "5b2c1e00-0000-4000-8000-0000000000f2", name: "acme-prod", channel: "prod", update_state: "behind", autoupdate_triggered_at: null },
        ],
        staging_gate_open: false,
      },
      operatorWarmPool: { ready: 0 },
      operatorDeliveries: [
        { id: "dl1", status: "sent", kind: "email", event: "fleet_digest", channel: "email", recipient: "ops@barkpark.cloud", attempts: 1, inserted_at: tMinus(3600), last_error: null, http_status: null },
        { id: "dl2", status: "failed", kind: "email", event: "fleet_digest", channel: "email", recipient: "ops@barkpark.cloud", attempts: 3, inserted_at: tMinus(90000), last_error: "smtp: connection timed out", http_status: null },
      ],
      // THE REFUSAL, and the whole reason this fixture exists: 74 attempted
      // rows is below `DeployLedger.min_sample/0` (200), so `rate/2` answers
      // `refused: true, pct: null` and the console must render the ledger's own
      // "not enough data (n=74)" — never a percentage it computed itself off
      // the counts sitting right beside it. The COUNTS stay (they are real
      // rows); only the RATIO goes.
      operatorCensus: {
        window: censusWindow(1),
        volume: 74,
        failed: 12,
        live: 58,
        in_flight: 3,
        cancelled: 1,
        residual: 0,
        deferred_total: 0,
        failure_rate: censusRate(12, 74, CENSUS_ATTEMPTED_BASIS),
        live_rate: censusRate(58, 74, CENSUS_ATTEMPTED_BASIS),
        classes: [
          censusClass("BUILD_FAILED", "the site build exited non-zero", 9, 12),
          censusClass("BOX_500", "the box errored on the deploy (HTTP 500)", 3, 12),
        ],
        min_sample: 200,
      },
    },
  },
  // The ZERO-STAGING console: nothing is registered on the staging channel and
  // the warm pool is empty. Both are DESIGNED states, not errors, and both are
  // states prod is genuinely in today — which is exactly why they deserve a shot
  // rather than an assumption. The gate sentence here is the THIRD one (GR50):
  // Registry.staging_gate_open?/0 fails OPEN on an empty staging list, so "open"
  // alone is not a vouch and the copy must say there is nothing ahead of prod.
  "operator-zero-staging": {
    label: "Operator console — zero staging boxes and an empty warm pool: the gate is open but vouches for nothing",
    authed: true,
    deepLink: "#operator",
    data: {
      me: operatorMe("Acme Inc"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      operatorAutoupdate: { halted: false },
      operatorFleet: {
        barkparks: [
          { id: "5b2c1e00-0000-4000-8000-0000000000e1", name: "acme-prod", channel: "prod", update_state: "current", autoupdate_triggered_at: null },
          { id: "5b2c1e00-0000-4000-8000-0000000000e2", name: "beta-prod", channel: "prod", update_state: "current", autoupdate_triggered_at: null },
        ],
        staging_gate_open: true,
      },
      operatorWarmPool: { ready: 0 },
      operatorDeliveries: [],
      // THE EMPTY WINDOW. Zero attempted rows is not zero failures — it is
      // NOTHING MEASURED, and a table of 0s beside a 0.0% rate would read as
      // health. The card must say "no deployments in this window" and draw no
      // table at all.
      operatorCensus: {
        window: censusWindow(1),
        volume: 0,
        failed: 0,
        live: 0,
        in_flight: 0,
        cancelled: 0,
        residual: 0,
        deferred_total: 0,
        failure_rate: censusRate(0, 0, CENSUS_ATTEMPTED_BASIS),
        live_rate: censusRate(0, 0, CENSUS_ATTEMPTED_BASIS),
        classes: [],
        min_sample: 200,
      },
    },
  },
  // FAIL-CLOSED (GR49): registering "operator" in VIEWS also made init()'s route
  // validator accept a deep-linked #operator for ANYBODY, so a non-operator who
  // types the hash must be BOUNCED to Overview — the sidebar gate alone is not
  // enough. /v1/me answers platform_operator:false here.
  "operator-denied": {
    label: "Operator console — a non-operator deep-links #operator and is bounced to Overview",
    authed: true,
    deepLink: "#operator",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  // Honest degrade: PLATFORM_ADMIN_EMAILS unset (or an allowlist change mid-
  // session) makes every /v1/operator/* route 403 while /v1/me still says
  // operator. Each card then reports that IT could not read — never a fake
  // reading, never a spinner that outlives the request.
  "operator-unreadable": {
    label: "Operator console — every operator route 403s; all four cards degrade honestly",
    authed: true,
    deepLink: "#operator",
    data: {
      me: operatorMe("Acme Inc"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      operatorDenied: true,
    },
  },
  // cch-w37-s6 — the OTHER unreadable: not the operator routes 403ing, but
  // /v1/me itself failing. `me` is PRESENT (this really is an operator) and only
  // the WIRE fails, so meState() lands on "failed" rather than the cold
  // "loading" the console used to be indistinguishable from. Before the fix the
  // page sat on "Checking operator access…" for the whole session, because
  // loadMe's failure arm deliberately does not re-enter loadOperator. This is a
  // WAIT, not a false grant: the sidebar entry stays hidden and zero
  // /v1/operator/* routes are read.
  "operator-me-unreadable": {
    label: "Operator console — /v1/me itself 500s: the page says it couldn't check, and offers a retry instead of a forever spinner",
    authed: true,
    deepLink: "#operator",
    data: {
      me: operatorMe("Acme Inc"),
      meFault: { status: 500, body: { error: "internal" } },
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  // cch-w37-bl-operator-retry-click-undriven — THE RECOVERY TWIN. The sibling
  // above proves the failed BODY renders and carries #operator-me-retry; nothing
  // in the repo ever CLICKED it. A regression that wires the listener to the
  // wrong node, drops the .then, or re-enters the loader on a SUCCESSFUL read
  // (painting twice and issuing the four operator reads twice) passed every gate.
  //
  // ONE-SHOT, NOT STICKY: `times: 1` fails the boot read and then heals, so the
  // retry's re-read LANDS and the operator shell must paint. The row filed this
  // exhaustible form as "does not exist yet and is the actual work" — it exists,
  // built by cchi-w39-bl-mefault-must-be-exhaustible (route()'s per-boot state
  // bag, two waves after this row was written), and `billing-me-recovers` has
  // consumed it since. This fixture mints no mechanism; it points the existing
  // one at the operator surface, whose recovery arm is the one with the double-
  // read hazard the billing twin does not have.
  "operator-me-recovers": {
    label: "Operator console — /v1/me 500s ONCE: the retry re-reads, the shell paints, and the four operator routes are read exactly once",
    authed: true,
    deepLink: "#operator",
    data: {
      me: operatorMe("Acme Inc"),
      meFault: { status: 500, body: { error: "internal" }, times: 1 },
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },

  // ── gr-p5-account-2fa: the account modal (GR54/GR58) ──────────────────────
  // The modal is opened by a CLICK, so it is unreachable by deepLink — smoke
  // drives the composition through the real openModal primitive instead (the
  // browser twin of this seam is mock.js's ?modal=account). Two scenarios
  // because the 2FA on/off state is read STRAIGHT off /v1/me's
  // two_factor_enabled: zero extra fetches, and the fixture is the proof.
  "account-modal": {
    label: "Account modal — identity, sessions, password on demand, 2FA OFF (the not-enrolled state)",
    authed: true,
    deepLink: "",
    data: {
      me: me("Guerrilla"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      accountSessions: accountSessions,
    },
  },
  // GR76 (folds gr-backlog-tall-modal-scenario). shoot.sh reaches the account
  // modal by the "account-modal" NAME PREFIX, so this scenario is auto-covered
  // with zero harness change — do NOT teach shoot.sh about it.
  "account-modal-tall": {
    label: "Account modal — the NINE-session shape (the one that broke on live); escape hatches sit below the list",
    authed: true,
    deepLink: "",
    data: {
      me: me("Guerrilla"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      accountSessions: accountSessionsTall,
    },
  },
  // cch-w2-revoke-click-oracle. The only scenario in this file driven by real
  // CLICKS rather than a deep link: smoke.mjs clicks #acct-btn, then a row's
  // Revoke, then Sign-out-everywhere, and reads what the REAL code path paints.
  // Named with the `account-modal` prefix, which (as GR76 notes) auto-enrols it
  // in shoot.sh's screenshot set — intended, so the revoke state gets an eye too.
  // cch-w23-bl-cruel-identity-own-scenario: this scenario is NO LONGER the cruel
  // identity twin. cch-w23-s2 parked `cruelAccountMe` here because a new
  // SCENARIOS key was fenced out of its slice; the consequence was that the one
  // scenario in this file driven by REAL CLICKS — and the one shoot.sh publishes
  // as the revoke evidence — ran its whole oracle against a 158-character
  // address nobody in this corpus otherwise owns. The cruelty moved next door to
  // `account-modal-cruel-identity`, and this fixture is back on the
  // PRODUCTION-DOMINANT identity `me("Guerrilla")` (`ada@acme.com`), which is
  // what the click oracle should measure a revoke against. That is PINNED, not
  // hoped: smoke.mjs's FIXTURE_SHAPE_PINS carries `account-modal-revoke` ·
  // `me.user.email.length` = 12, so a future edit that re-parks a cruel `me`
  // here reds before any scenario boots.
  "account-modal-revoke": {
    label: "Account modal — the revoke path, driven by real clicks: one row revoked, then sign-out-everywhere reporting the SERVER's count",
    authed: true,
    deepLink: "",
    data: {
      me: me("Guerrilla"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      accountSessions: accountSessionsRevoke,
    },
  },
  // cch-w23-bl-cruel-identity-own-scenario — THE CRUEL IDENTITY, ON ITS OWN KEY.
  // `.am-name` paints `email.split("@")[0]` (accountModel() — re-derive with
  // `grep -n 'function accountModel' cloud/priv/static/app.js`), so the string a
  // person can actually put on that element is capped by the SERVER's
  // `validate_length(:email, max: 160)` and nothing else: 160 − "@" − one domain
  // character = 158 unbroken characters (the full derivation, and why the filed
  // 255 is INADMISSIBLE, is in the cruelAccountEmail ledger above `SCENARIOS`).
  // Its KIND control is `account-modal` next door, still `ada@acme.com` (three
  // rendered glyphs) — the pair is what makes a remedy that buys the cruel name
  // by shredding an ordinary one red. Driven at 7 widths x 2 themes by
  // overflow-guard's W23-account-modal-identity-bounded leg (AM_SCENS), asserted
  // at rest by smoke.mjs's `account-modal-cruel-identity` expectation, and
  // auto-enrolled in shoot.sh's screenshot set by the `account-modal` name
  // prefix (GR76) with zero harness change. It carries the SHORT session list,
  // not the revoke one: this scenario's axis is the identity, and a stateful
  // revoke fixture here would give it a second axis nothing asserts.
  "account-modal-cruel-identity": {
    label: "Account modal — the CRUEL identity: a 158-character email local part, the longest name a person can actually own (validate_length(:email, max: 160))",
    authed: true,
    deepLink: "",
    data: {
      me: cruelAccountMe,
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      accountSessions: accountSessions,
    },
  },
  "account-modal-2fa-badcode": {
    label: "Account modal — enrollment rejected: 422 invalid_otp, inline in the #pw-error grammar (never a toast)",
    authed: true,
    deepLink: "",
    data: {
      me: me("Guerrilla"),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      accountSessions: accountSessions,
      twoFactorConfirm: { status: 422, body: { error: "invalid_otp" } },
    },
  },
  "account-modal-2fa-on": {
    label: "Account modal — 2FA already ON: the on-row, read free from /v1/me's two_factor_enabled",
    authed: true,
    deepLink: "",
    data: {
      me: (function () {
        const m = me("Guerrilla");
        return Object.assign({}, m, { user: Object.assign({}, m.user, { two_factor_enabled: true }) });
      })(),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      accountSessions: accountSessions,
    },
  },
  // ── MVP-0 Personal Dev Fleet (PDF-D84/D88/D92): the fleet card states ──────
  "fleet-support-provisioning": {
    label: "Fleet card — a support mid-provision: the SUPPORT theater (6 rungs, secure included) under the main",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, supportProvisioningRow],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  "fleet-support-online": {
    label: "Fleet card — a support ONLINE (roster presence chip + capacity) with the BYO-model-key step",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, supportOnlineRow],
      subscription: activeSub,
      sites: [],
      audit: [],
      fleetRoster: fleetRosterFixture,
    },
  },
  "fleet-support-failed": {
    label: "Fleet card — stuck provisioning renders honestly FAILED (never lies online)",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, supportFailedRow],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  "fleet-support-empty": {
    label: "Fleet card — no supports yet: the add-a-support CTA on a live main (+ nested #fleet list)",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  // ── MVP-0 OFFLOAD (pdf-mvp0-offload-spa, PDF-D87/D92): the order watch ladder ─
  // The offload action renders on the ONLINE support (muscle-2); the watch folds
  // the task read + the roster read into filed -> claimed -> working -> done with
  // honest blocked/failed terminals. Each scenario pins one rung.
  "offload-filing": {
    label: "Offload — the order is filed (open), waiting for the support to claim it",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, supportOnlineRow],
      subscription: activeSub, sites: [], audit: [],
      fleetRoster: offloadRoster("idle", null),
      orderTask: offloadOrderTask("open", null),
    },
  },
  "offload-working": {
    label: "Offload — the support has claimed AND is WORKING the order (roster beats working)",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, supportOnlineRow],
      subscription: activeSub, sites: [], audit: [],
      fleetRoster: offloadRoster("working", OFFLOAD_ORDER_ID),
      orderTask: offloadOrderTask("in_progress", { worker: "muscle-2", epoch: 1, ts_iso: "2026-07-24T12:00:00Z" }),
    },
  },
  "offload-done": {
    label: "Offload — the order is DONE (terminal success; the poll stops)",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, supportOnlineRow],
      subscription: activeSub, sites: [], audit: [],
      fleetRoster: offloadRoster("idle", null),
      orderTask: offloadOrderTask("done", { worker: "muscle-2", epoch: 1, ts_iso: "2026-07-24T12:00:00Z" }),
    },
  },
  "offload-blocked": {
    label: "Offload — the support hit a BLOCKER (honest terminal; the ladder snaps)",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, supportOnlineRow],
      subscription: activeSub, sites: [], audit: [],
      fleetRoster: offloadRoster("blocked", OFFLOAD_ORDER_ID),
      orderTask: offloadOrderTask("blocked", { worker: "muscle-2", epoch: 1, ts_iso: "2026-07-24T12:00:00Z" }),
    },
  },
  // ── cch-w61-s2: the credential-refused box, and a rollback that CAN refuse ──
  "instance-update-credential-refused": {
    label: "Updates panel — a box that answered our stored credential with a 401 (Unknown, 45m), and a Roll back that refuses terminally",
    authed: true,
    deepLink: "#instance/" + IDS.refusedInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [credentialRefusedInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      // The 409 the control plane emits for a box it will not relay to. Before
      // this route existed the POST fell through to a blanket 200 and the modal
      // reported success — the fixture could not refuse, so the split could not
      // be exercised at all.
      instanceRollback: { status: 409, body: { ok: false, error: { code: "identity_refused" } } },
    },
  },
  // ── cch-w45-bl: the three instance-lifecycle verbs no committed scenario
  // could paint. Each one is a STATE the corpus never produced, not a control
  // that was missing — so every guard over them was green by construction (the
  // epic's own fourth clause). Measured on origin/main dea37e8d19 by booting all
  // 116 scenarios through smoke.mjs's shim: `id="inst-update"` 0 hits,
  // `id="inst-remove-retry"` 0 hits, `data-vf-reprovision` 0 hits.
  //
  // Every one carries the corpus's OWNER actor, because the affordance these
  // scenarios exist to render is the LIVE one — the member arm of all seven
  // verbs is already pinned in both directions by __app.test.mjs's cch-w38-s1
  // eleven-offer table, and `panel-overview-member` pins the disable-and-explain
  // bytes in the real DOM.
  "instance-behind": {
    label: "Instance header — a live box one release BEHIND: the one-click self-update CTA (#inst-update) beside Open Studio",
    authed: true,
    deepLink: "#instance/" + IDS.behindInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, behindInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  "instance-remove-failed": {
    label: "Instance header — a teardown that FAILED: the Retry removal CTA (#inst-remove-retry) and the server's verbatim deprovision_error",
    authed: true,
    deepLink: "#instance/" + IDS.removeFailedInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance, removeFailedInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
    },
  },
  "verify-no-credentials": {
    label: "Verify card — the box predates verification: POST /verify answers 404 no_admin_token and the note offers its ONE recovery, Re-provision",
    authed: true,
    deepLink: "#instance/" + IDS.liveInstance,
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: [],
      instanceEvents: { [IDS.liveInstance]: liveInstanceEventsNoVerify },
      // The 404 the control plane answers for an instance with no stored admin
      // credential. Without it POST /verify is a blanket 200 in every scenario,
      // so verifyNoteHtml("no_admin_token", …) — and the [data-vf-reprovision]
      // mount inside it — was unreachable from this harness at all.
      instanceVerify: { status: 404, body: { error: "no_admin_token" } },
    },
  },

  // ── cch-w50-s4: THE TWO BILLING ACTORS THE CORPUS HAS NEVER HELD ────────────
  // The plan card's bullets rendered in five of the committed scenarios before
  // this pair, ALL of them paid-or-member. Two arms of renderPlanState had ZERO
  // fixtures, so every render-layer guard aimed at them was green BY
  // CONSTRUCTION — a guard over a state no fixture can produce cannot lose.
  //
  // 1. THE UNSUBSCRIBED OWNER — the actor renderPlanState routes to the UPSELL
  //    card. Its four unique markers (`plan-continue`, "Optimized for shipping
  //    to production", "See more plan options", "Recommended") had zero hits in
  //    a rendered-DOM dump of the whole corpus.
  // 2. THE SUPPORT++ OWNER — `grep support_plus scenarios.mjs` returned nothing.
  //    The third catalog tier had never rendered as a CURRENT plan anywhere.
  //
  // THE ENVELOPE IS THE SERVER'S, NOT A SYNTHESIS (charter D573, cch-w43-s1:
  // "the corpus mints the envelope the server mints"). `subscription: null` is
  // what GET /v1/subscription actually answers for a team with no live
  // subscription — web/router.ex:2088/2095 both `json(conn, 200, %{subscription:
  // nil, billing_capability: billing_capability_json()})`, under the comment "A
  // team with no active subscription gets {subscription: nil}". A synthesized
  // `{plan: "free"}` subscription reaches the SAME upsell arm (planFromSub's
  // `sub.plan !== "free"` guard rejects it, so renderPlanState falls through
  // identically) — but /v1/subscription never mints that shape for an
  // unsubscribed team, so the corpus would be asserting against an envelope the
  // plane cannot produce. loadSubscription sets `subLoaded = true` on r.ok with
  // `subCache = null`, so renderPlanState skips the trial arm, skips the
  // active|past_due arm, and reaches the upsell.
  "billing-free-owner": {
    label: "Billing — the UNSUBSCRIBED owner: subscription null, so the plan card is the upsell (Recommended badge, Continue, See more plan options)",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      // The server's own arm, verbatim: no live subscription → null, never a
      // synthesized {plan:"free"}.
      subscription: null,
      sites: [],
      audit: [],
    },
  },
  // The SUPPORT++ owner. `support_plus` is a first-class server plan, not a
  // console invention: Billing.Subscription's `@plans ~w(free trial supporter
  // support_plus forever)` validate_inclusion admits it, Billing.limits/0 carries
  // its ceiling (10), and config keys it to a Stripe price id
  // (STRIPE_PRICE_SUPPORT_PLUS). The one thing this fixture cannot prove from a
  // checkout is that the LIVE plane has that price id populated — see the PR's
  // written exception. What it renders is the tier's card as a CURRENT plan,
  // which no scenario had ever produced.
  "billing-support-plus": {
    label: "Billing — the Support++ owner: the third catalog tier renders as the CURRENT plan, with the manage/cancel owner sections",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: {
        plan: "support_plus",
        status: "active",
        past_due: false,
        cancel_at_period_end: false,
        current_period_end: new Date(Date.parse(T) + 24 * 86400 * 1000).toISOString(),
        canceled_at: null,
        started_at: tMinus(60 * 86400),
        is_trial: false,
        trial_days_remaining: null,
      },
      sites: [],
      audit: [],
    },
  },

  // ── cch-w49-s7 · THE DEPLOY THAT CANNOT TAKE MONEY ────────────────────────
  // THE HOLE THIS CLOSES. #10509 put `billing_capability` on GET
  // /v1/subscription and NO fixture in this corpus had ever carried one — so
  // every console consumer of it was green BY CONSTRUCTION, in the same way
  // `billing-free-owner` found the upsell card's four markers had zero hits.
  // `billing-trial` is the only actor whose #billing-tiers is VISIBLE at first
  // paint (renderTrial unhides the grid), so it is the only actor from which a
  // rendered-bytes assertion about the tier grid can be made at all; this is
  // that actor with the plane declaring `unconfigured` — no plan priced, so
  // Billing.checkout/2 can only ever answer {:error, :billing_not_configured}.
  // Everything else is billing-trial's data verbatim: the ONE variable is the
  // declaration.
  "billing-unconfigured": {
    label: "Billing — the plane declares checkout UNCONFIGURED: the tier grid offers no Subscribe at all and says why",
    authed: true,
    deepLink: "#billing",
    data: {
      me: me("Ada's Lab", { instance: true }),
      barkparks: [liveInstance],
      subscription: trialSub,
      // checkout_capability/0's :unconfigured arm, verbatim: priced_plans() is
      // empty, so `plans` is [] and not a missing key — an empty LIST is the
      // server's own answer, and it is not the same thing as no declaration.
      billingCapability: { checkout: "unconfigured", plans: [] },
      sites: [],
      audit: [],
    },
  },

  // ── cch-w12-followup-login-fixture-gap · THE SUCCESSFUL LOGIN ──────────────
  // THE HOLE THIS CLOSES. Until now this file answered POST /v1/auth/login from
  // exactly ONE fixture (`loggedout-twofactor`), and that fixture returns
  // `two_factor_required` — so the success branch of route()'s own login arm
  // (`if (state && d.login.status && d.login.status < 400) delete state.loggedOut`)
  // was unreachable from every committed scenario, and no drive in this harness
  // had ever COMPLETED a sign-in. The consequence is bigger than a missing
  // branch: render()'s logged-out arm is the one seam where a console lie about
  // IDENTITY can be built — it serves the sign-out click AND the 401
  // auto-bounce, neither of which reloads — so every per-account cache clear
  // standing in it (meCache via clearMe, subCache, capCache, overviewData.*,
  // and activityActors) was pinned by SOURCE SHAPE alone. Nothing could DRIVE
  // an account change, so nothing could observe one going wrong.
  //
  // WHAT THIS FIXTURE MODELS, AND WHAT IT HONESTLY CANNOT. route() is handed
  // (name, method, path, state) — there is NO REQUEST BODY on that signature,
  // in this harness or in mock.js — so the fixture cannot match credentials to
  // an account and must not pretend to. It models the only thing it can see:
  // this scenario boots ALREADY signed in as ada, so any successful
  // POST /v1/auth/login reaching it is by construction a SECOND sign-in, and it
  // lands the second identity (`secondIdentity` below). The claim under test is
  // the console's, not the server's: what the client keeps across an account
  // change it was told about. Credential matching is the server's, and
  // cloud/test owns it.
  "activity-identity-change": {
    label: "Sign out and back in as ANOTHER TEAM, no reload — the Activity Who axis must not name the previous team's members",
    authed: true,
    deepLink: "#overview",
    data: {
      me: me("Acme Inc", { instance: true, published_doc: true, completed: true }),
      barkparks: [liveInstance],
      subscription: activeSub,
      sites: [],
      audit: activityFeed,
      // Identity one's roster: ada (the actor) / lin / rex — the same three the
      // `activity` scenario's Who axis renders, and the three that must be GONE
      // after the switch.
      members: teamMembers,
      // The successful sign-in itself. 200 + a session body in the shape
      // loginResponseKind() folds to "session" (`grep -n 'function
      // loginResponseKind' cloud/priv/static/app.js`): a token, and the team it
      // is scoped to — which is the SECOND team, because that is who signs in.
      login: { status: 200, body: { token: "preview-second", team_id: IDS.teamBeta } },
      // Everything that changes with the account. Read through `state` by
      // route(), so the switch is a STATE CHANGE the fixture can be asked about
      // — not two static objects a check picks between, which would prove
      // nothing about what the console did.
      secondIdentity: { me: betaMe, members: teamMembersBeta },
    },
  },
};

export const SCENARIO_NAMES = Object.keys(SCENARIOS);
export const DEFAULT_SCENARIO = "empty";

// The account modal's live session list, as a MUTABLE per-boot store when the
// caller supplies a state bag (smoke.mjs) and as the read-only fixture when it
// does not (mock.js). Copies each row so a revoke can never leak across boots
// by mutating the module-level fixture.
function sessionsOf(d, state) {
  if (!state) return (d.accountSessions || []).slice();
  if (!state.sessions) state.sessions = (d.accountSessions || []).map((s) => Object.assign({}, s));
  return state.sessions;
}

// cch-w10-destroy-shrink-oracle-merged — sessionsOf's SHAPE, generalised to the
// other lists a destroy verb shrinks (providers, members, invitations,
// barkparks). The three properties that make a shrink OBSERVABLE, all inherited
// verbatim from sessionsOf and all load-bearing:
//   1. OPT-IN. No `state` → the old read-only `.slice()`, byte-for-byte. mock.js
//      is the 3-arg caller and must stay stateless and unchanged.
//   2. PER-BOOT COPY. Rows are copied, so a destroy can never leak across boots
//      by mutating the module-level fixture (scenario order would decide truth).
//   3. THE GET READS THROUGH THE SAME FUNCTION. This is the whole point: a
//      DELETE that splices a list nobody re-reads proves nothing, because the
//      refetch would answer the pristine fixture either way.
// `key` is the SCENARIO field name and doubles as the state-bag slot, so the two
// can never drift apart.
function listOf(d, state, key) {
  if (!state) return (d[key] || []).slice();
  if (!state[key]) state[key] = (d[key] || []).map((x) => Object.assign({}, x));
  return state[key];
}

// The destroy half: 404 on a miss (never a silent success — a wrong id must be
// distinguishable from a right one), 200 {ok} on a hit, and the splice ONLY when
// a state bag was supplied, so the stateless caller keeps its old 200.
function destroyFrom(list, state, pred) {
  const i = list.findIndex(pred);
  if (i < 0) return { status: 404, body: { error: "not_found" } };
  if (state) list.splice(i, 1);
  return { status: 200, body: { ok: true } };
}

// The GitHub installation, as a MUTABLE per-boot singleton. Same contract as
// listOf above (opt-in, per-boot copy, the GET reads through it) for a resource
// that is one object rather than a list, so a disconnect is observable as a
// state change instead of a 200 nobody can check.
function githubOf(d, state) {
  if (!state) return Object.assign({}, d.github || {});
  if (!state.github) state.github = Object.assign({}, d.github || {});
  return state.github;
}

// route(name, method, path, state) → { status, body } | null.
//   Returns null for a path this harness does not model, so a caller can decide
//   whether to 404 or pass through. Query strings are ignored (the SPA never
//   depends on server-side filtering for these fixtures).
//   `state` is an OPTIONAL per-boot mutable bag for routes that must actually
//   change something (see sessionsOf). Omitting it keeps every route stateless.
//   CORRECTED (wave 11 review): this used to say stateless "is what the browser
//   harness (mock.js) does". It has not been true since
//   cch-bl-mockjs-revoke-stateless — mock.js:124 passes a `fixtureState` on
//   every call, exactly as smoke.mjs does. NO CALLER OMITS IT TODAY, so the
//   stateless arm of every `if (state)` is dead code that only a new caller can
//   revive, and a route added on the assumption that the browser is stateless
//   will be wrong in the browser first.
export function route(name, method, path, state) {
  const scen = SCENARIOS[name] || SCENARIOS[DEFAULT_SCENARIO];
  const d = scen.data;
  // Strip any absolute origin first (mock.js extracts pathname; smoke passes
  // the raw URL): the MVP-0 roster read is browser-direct against the MAIN's
  // absolute URL, and both harnesses must land it on the same /v1 arm.
  const p = String(path || "").replace(/^https?:\/\/[^/]+/, "").split("?")[0];

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
  if (method === "POST" && p === "/v1/auth/login" && d.login) {
    // A successful sign-in mints a new token, so it lifts the revocation the
    // logout arm below records — otherwise a sign-out is a one-way trap the
    // fixture can never leave, which no real server does.
    if (state && d.login.status && d.login.status < 400) {
      delete state.loggedOut;
      // cch-w12-followup-login-fixture-gap: …and, for a scenario that carries a
      // SECOND identity, this is the moment the account changes. Recorded on
      // the per-boot state bag (never on this module's shared scenario object,
      // which smoke.mjs drives across many scenarios in one process), and the
      // per-account READS below go through it — a switch nothing re-reads would
      // prove nothing, which is this file's founding sin in a smaller costume.
      // Until wave 12's follow-up NO fixture had a `login` under 400 at all, so
      // this success branch had never once executed.
      if (d.secondIdentity) state.secondIdentity = true;
    }
    return d.login;
  }
  if (method === "POST" && p === "/v1/auth/two-factor-challenge" && d.twoFactorChallenge) return d.twoFactorChallenge;
  if (method === "POST" && p === "/v1/auth/reset" && d.reset) return d.reset;

  // Logged out: no authed reads are modelled.
  if (!scen.authed) return { status: 401, body: { error: "unauthorized" } };

  // cch-w11-bl-unmodelled-delete-route-arms — DELETE /v1/auth/logout, THE LAST
  // destroy verb that still fell through to the terminal `/v1/` 200 {} at the
  // bottom of this function. A verb that succeeds against a route the fixture
  // never modelled would report success against literally any server, which is
  // this harness's founding sin in a smaller costume.
  //
  // RE-DERIVED, not copied from the filing: the row named four routes. Three
  // are modelled today — /v1/github/installation (gated on the `github`
  // fixture), /v1/sites/:id/github (the `siteGithub` matcher) and the webhook
  // DELETE (the `whDelete` matcher, a full destroyFrom/listOf shrink oracle)
  // all answer real shapes. Only logout was left, and this is it. Derived by
  // sentinel: the terminal catch-all was replaced with a marker body and every
  // DELETE the console issues was probed across all 118 scenarios — logout was
  // the only one that reached it (112/118; the other 6 are the logged-out
  // scenarios, whose 401 is the authed gate above, not a logout arm).
  //
  // THE OBSERVABLE STATE THE VERB CHANGES: the calling token is REVOKED, so
  // every authed read after it must answer 401 — the same 401 the logged-out
  // scenarios answer above. `state.loggedOut` is that fact, on the sessionsOf /
  // listOf / githubOf contract: opt-in on `state` (a stateless caller keeps its
  // old 200 byte-for-byte) and the READS GO THROUGH IT, which is the whole
  // point — a DELETE nothing re-reads proves nothing.
  //
  // Signing back in clears it: the unauthenticated POSTs above sit ABOVE this
  // gate on purpose, so a scenario that signs out and signs in again is not
  // trapped in a 401 the fixture can never leave.
  if (method === "DELETE" && p === "/v1/auth/logout") {
    if (state) state.loggedOut = true;
    return { status: 200, body: { ok: true } };
  }
  if (state && state.loggedOut) return { status: 401, body: { error: "unauthorized" } };

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

  // MVP-0 Personal Dev Fleet: the app-token mint + the main's roster. The
  // browser reads the roster app-token-direct off the MAIN's absolute URL;
  // mock.js path-matches by pathname, so the cross-origin read still lands
  // here and the ONLINE presence chip is previewable.
  if (method === "POST" && /^\/v1\/barkparks\/[^/]+\/app-token$/.test(p)) {
    return {
      status: 200,
      body: { token: "tok-preview-app", workspace_id: "ws-preview", permissions: ["read", "write", "chat"], expires_at: tPlus(3600) },
    };
  }
  if (method === "GET" && p === "/v1/fleet/roster") {
    return { status: 200, body: { documents: d.fleetRoster || [] } };
  }
  if (method === "POST" && p === "/v1/fleet/supports") {
    return d.addSupport || { status: 202, body: { ok: true } };
  }
  // MVP-0 offload (pdf-mvp0-offload-spa): the order is FILED via the browser-
  // direct mutate seam and WATCHED via GET /v1/tasks/:id — both land here (the
  // absolute origin is already stripped above). The mutate answers success
  // unless a scenario pins the publish-wall 422 via d.orderMutate; the task read
  // returns the scenario's order doc in its {ok, doc} envelope, else 404.
  if (method === "POST" && /^\/v1\/data\/mutate\/[^/]+$/.test(p)) {
    return d.orderMutate || { status: 200, body: { transactionId: "tx-preview", results: [] } };
  }
  const offloadTaskMatch = p.match(/^\/v1\/tasks\/([^/]+)$/);
  if (method === "GET" && offloadTaskMatch) {
    return d.orderTask
      ? { status: 200, body: { ok: true, doc: d.orderTask } }
      : { status: 404, body: { ok: false, error: "task not found" } };
  }

  // cch-w37-s6 — THE WIRE FAILURE, which no committed fixture could express.
  // Below, /v1/me answers 200-or-401 only, and a 401 SIGNS THE PERSON OUT
  // (app.js clearSession + render), so meState()=="failed" — the state
  // absorbMe writes on a 500/502/offline — was unreachable from every scenario
  // in this file. `meFault` is a per-scenario override that fails the READ while
  // leaving `me` present: the account exists, the wire did not answer.
  if (p === "/v1/me" && d.meFault) {
    // cchi-w39-bl-mefault-must-be-exhaustible — the EXHAUSTIBLE form. A sticky
    // fault can prove a retry RENDERS and re-issues the read, but never that it
    // RECOVERS: the second read fails identically forever. `times: N` fails the
    // first N reads and then heals, with the count kept in the PER-BOOT state
    // bag (the 4th arg both harnesses already pass) — NEVER on this module's
    // shared scenario object, which smoke.mjs drives across many scenarios in
    // one process and which a browser reload must not inherit. No `times` — or
    // a stateless caller that passed no bag — is the STICKY default, unchanged:
    // operator-me-unreadable and billing-me-unreadable depend on a read that
    // NEVER heals, and their surfaces pin exactly that.
    if (typeof d.meFault.times === "number" && state) {
      if ((state.meFaultServed || 0) < d.meFault.times) {
        state.meFaultServed = (state.meFaultServed || 0) + 1;
        return { status: d.meFault.status, body: d.meFault.body };
      }
      // exhausted — fall through to the healthy /v1/me arm below.
    } else {
      return d.meFault;
    }
  }
  // cch-w12-followup-login-fixture-gap: after a successful second sign-in, the
  // authority read answers the SECOND account. Above the ordinary arm because
  // the ordinary arm is unconditional; the flag is only ever set by the login
  // arm, so no scenario without a `secondIdentity` fixture can reach this.
  if (p === "/v1/me" && state && state.secondIdentity && d.secondIdentity) {
    return { status: 200, body: d.secondIdentity.me };
  }
  if (p === "/v1/me") return d.me ? { status: 200, body: d.me } : { status: 401, body: { error: "unauthorized" } };
  // gr-p5-account-2fa: the account modal's session list. Defaults to [] rather
  // than 404 so every scenario answers HONESTLY ("No active sessions") instead
  // of the modal's couldn't-load state.
  //
  // cch-w2-revoke-click-oracle — the list is now served from a per-boot STORE
  // when the caller supplies one, so the two DELETEs below actually change it.
  // With a stateless fixture the list is byte-identical before and after a
  // revoke, so a per-row revoke that never fired is indistinguishable from one
  // that did: the check passes either way (D39). smoke.mjs passes a store, and
  // since cch-bl-mockjs-revoke-stateless so does mock.js (a per-boot bag), so
  // both harnesses now answer the destructive routes the same way. A caller
  // that omits the 4th arg still gets the old read-only behaviour.
  if (p === "/v1/account/sessions" && method === "GET") {
    return { status: 200, body: { sessions: sessionsOf(d, state) } };
  }
  // DELETE /v1/account/sessions/:id → revoke ONE session. Mirrors router.ex
  // (`revoke_user_session/2`): 200 {ok} on a hit, 404 not_found on a miss.
  // Before this handler existed the request fell through to the generic
  // `/v1/` 200 {} at the bottom of route(), so the row vanished from the
  // re-render for no reason other than the fixture being static.
  const sessOne = p.match(/^\/v1\/account\/sessions\/([^/]+)$/);
  if (sessOne && method === "DELETE") {
    const list = sessionsOf(d, state);
    const i = list.findIndex((s) => s.id === sessOne[1]);
    if (i < 0) return { status: 404, body: { error: "not_found" } };
    if (state) list.splice(i, 1);
    return { status: 200, body: { ok: true } };
  }
  // DELETE /v1/account/sessions → "sign out everywhere", 200 {revoked: N}.
  // N counts the OTHER sessions, never the acting one — router.ex keeps the
  // caller alive via `except: Auth.bearer_token(conn)`. This is the ONE
  // destructive route in the console whose toast interpolates a SERVER value
  // ((r.data.revoked || 0) in the "Signed out other devices" revoke-all toast),
  // so without this handler the
  // generic 200 {} made the console announce "0 session(s) revoked." after
  // revoking real ones. The live route is honest; the harness was not.
  if (p === "/v1/account/sessions" && method === "DELETE") {
    const list = sessionsOf(d, state);
    const others = list.filter((s) => !s.current);
    if (state) {
      const keep = list.filter((s) => s.current);
      list.length = 0;
      for (const s of keep) list.push(s);
    }
    return { status: 200, body: { revoked: others.length } };
  }
  // cch-w3 × cch-w2 (CROSS-SLICE). The live stream now opens in two steps: the
  // SPA POSTs here for a single-use 60s ticket, THEN constructs an EventSource
  // on it. Without this handler the mint falls through to the benign `/v1/` 200
  // {} at the bottom of route() — which is `ok` but carries no `ticket`, so
  // app.js reads the mint as FAILED, calls markEventsErrored() and raises a
  // "Live updates interrupted" toast on EVERY scenario boot.
  //
  // That was invisible until this wave: the toast only became observable once
  // the click oracle gave the shim a real innerHTML + isConnected, and it then
  // broke `account-modal-2fa-badcode`, whose whole assertion is that a field
  // error fires NO toast. Two individually-correct slices jointly producing a
  // defect — the same shape the HEAD fence documents about Plug.Head.
  //
  // The ticket value is inert: the sandbox's EventSource is a stub that never
  // opens, errors or delivers, so the stream stays silent and deterministic and
  // the chip sits on its initial state. Modelled, not suppressed — an absent
  // fixture would still be a lie about what the console does at boot.
  if (p === "/v1/auth/sse-ticket" && method === "POST") {
    return { status: 200, body: { ticket: "preview-sse-ticket", expires_in: 60 } };
  }
  // gr-p5-account-2fa: the five password-free two-factor routes. Overridable per
  // scenario (d.twoFactorConfirm) so the 422 invalid_otp / not_enrolled arms are
  // reachable without a backend. The secret is a well-known RFC 4648 test vector.
  if (p === "/v1/account/two-factor/enroll" && method === "POST") {
    return d.twoFactorEnroll || { status: 200, body: {
      secret: "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP",
      otpauth_uri: "otpauth://totp/Barkpark%20Cloud:" +
        encodeURIComponent((d.me && d.me.user && d.me.user.email) || "you@example.com") +
        "?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Barkpark%20Cloud",
    } };
  }
  if (p === "/v1/account/two-factor/confirm" && method === "POST") {
    return d.twoFactorConfirm || { status: 200, body: { recovery_codes: RECOVERY_CODES } };
  }
  if (p === "/v1/account/two-factor/recovery-codes" && method === "POST") {
    return d.twoFactorRegen || { status: 200, body: { recovery_codes: RECOVERY_CODES } };
  }
  if (p === "/v1/account/two-factor" && method === "DELETE") return { status: 200, body: { ok: true } };
  if (p === "/v1/account/two-factor" && method === "GET") {
    // Modelled for completeness; the SPA never calls it (two_factor_enabled
    // rides /v1/me, so the on-state costs zero extra fetches).
    return { status: 200, body: { enabled: !!(d.me && d.me.user && d.me.user.two_factor_enabled) } };
  }
  // gr-p2 HOME TRIAGE (C-02): the onboarding fold is member-readable on GET
  // (mirrors /v1/me's fold, so the runway self-heals on refetch); the mutating
  // POST (advance/ack/skip/complete) is owner/admin-only server-side — here it
  // just acks with 200 (the dismiss click is inert in smoke).
  if (p === "/v1/onboarding") {
    if (method === "GET") return { status: 200, body: { onboarding: d.me ? d.me.onboarding : null } };
    return { status: 200, body: { onboarding: d.me ? d.me.onboarding : null } };
  }
  if (p === "/v1/barkparks") return { status: 200, body: { barkparks: listOf(d, state, "barkparks") } };
  // DELETE /v1/barkparks/:id → the teardown BOTH console destroy verbs issue
  // (the CLI card's typed Decommission and the header's Retry removal). It was
  // UNMODELLED: it fell through to the terminal `/v1/` 200 {} at the bottom of
  // route(), so the fleet answered the same list before and after and no oracle
  // could tell a teardown from a no-op.
  // METHOD-GUARDED, deliberately: the exact-path arm above carries no method
  // guard at all, and an unguarded two-segment matcher here would swallow the
  // instance GET. There is no other two-segment /v1/barkparks matcher (the
  // domain-status / metrics / app-token arms are all three-segment), so this is
  // the whole of the surface.
  const bpOne = p.match(/^\/v1\/barkparks\/([^/]+)$/);
  if (bpOne && method === "DELETE") {
    return destroyFrom(listOf(d, state, "barkparks"), state, (b) => b.id === bpOne[1]);
  }
  // cch-w61-s2: POST /v1/barkparks/:id/rollback — the instance slot flip. It was
  // UNMODELLED: it fell through to the terminal `/v1/` 200 {} at the bottom of
  // route(), so every preview click on "Roll back…" "succeeded" against a
  // fixture that could never refuse, and the console's whole terminal-vs-retry
  // split was unreachable from this harness. A scenario overrides via
  // d.instanceRollback to drive one named refusal; the default stays the 202 the
  // control plane answers on the happy path.
  const bpRollback = p.match(/^\/v1\/barkparks\/([^/]+)\/rollback$/);
  if (bpRollback && method === "POST") {
    return d.instanceRollback ||
      { status: 202, body: { status: "rolling_back", target_sha: "9f2c1a7", pinned_release: "v0.9.0" } };
  }
  // cch-w49-s7 — the plane puts D554's `billing_capability` on this 200 as a
  // TOP-LEVEL SIBLING (router.ex: `%{subscription: …, billing_capability:
  // billing_capability_json()}`). It is OPT-IN here rather than defaulted:
  // an absent key is exactly the "unknown" the console fail-opens on, which is
  // what every scenario written before this slice was already modelling, so no
  // committed fixture's rendered bytes move. A scenario that wants to drive a
  // declared capability sets `billingCapability` in its data.
  if (p === "/v1/subscription") {
    const sub = { subscription: d.subscription };
    if (d.billingCapability) sub.billing_capability = d.billingCapability;
    return { status: 200, body: sub };
  }
  // gr-p4-billing (G-01): the owner-gated billing WRITES, unmodeled before this
  // slice. Default 200; a scenario overrides via d.billingPortal / d.billingCancel
  // to drive the failure variants (401 password_invalid, 403 forbidden, …). The
  // cancel 200 mirrors the router EXACTLY — {status, cancel_at_period_end} only,
  // NO current_period_end — so the SPA's re-poll of /v1/subscription (not this
  // body) is what renders the "Access until {date}" line.
  if (method === "POST" && p === "/v1/billing/portal") {
    return d.billingPortal || { status: 200, body: { portal_url: "https://billing.stripe.example/session/preview" } };
  }
  if (method === "POST" && p === "/v1/billing/cancel") {
    return d.billingCancel || { status: 200, body: { status: "active", cancel_at_period_end: true } };
  }
  // cch-w2-revoke-oracle-round2: through the state bag, so a site-level mutation
  // (today: DELETE /v1/sites/:id/github) is visible to the very next read. The
  // no-state arm is the old `d.sites` verbatim, and listOf's per-boot copy makes
  // the collection and the drill-down below answer the SAME objects.
  if (p === "/v1/sites") return { status: 200, body: { sites: listOf(d, state, "sites") } };

  // G-05 API tokens (GR34). GET → the caller's PATs (newest-first as fixtured);
  // POST → mint (201 {token: <plaintext ONCE>, pat: pat_json}, overridable via
  // d.tokenMint); DELETE /v1/tokens/:id → revoke (200 {ok}). A member never mints
  // beyond read (the UI offers only read-scope), so no 403 branch is reachable here.
  // cch-w11-s3: BOTH LEGS GO THROUGH THE STATE BAG, and neither is optional.
  // The GET was a DIRECT `d.tokens || []` fixture read — nobody had recorded
  // that half, so even a spliced DELETE would have refetched the pristine list.
  if (p === "/v1/tokens") {
    if (method === "GET") return { status: 200, body: { tokens: listOf(d, state, "tokens") } };
    if (method === "POST") {
      return d.tokenMint || {
        status: 201,
        body: {
          // 51 characters, the server's own length (accounts.ex:857 +
          // `defp generate_token` = "bpc_pat_" + 43 base64url chars).
          token: "bpc_pat_previewONLYshownONCEabcdef0123456789ABCDEFg",
          pat: { id: "tok_new", name: "New token", abilities: ["read"], last_used_at: null, expires_at: tPlus(30 * 86400), revoked_at: null, inserted_at: T },
        },
      };
    }
  }
  // DELETE /v1/tokens/:id — THE LAST LYING DESTROY VERB. It answered a flat
  // {ok:true} while the list above answered the pristine fixture, so the console
  // toasted "Token revoked" over a token list that never moved and no oracle
  // could tell the revoke from a no-op. destroyFrom 404s on a miss (a wrong id
  // must stay distinguishable from a right one) and splices only when a state
  // bag was supplied.
  //
  // THIS DOES CHANGE THE BROWSER TWIN, and saying otherwise would be the same
  // class of lie. mock.js:124 passes a per-boot `fixtureState` on EVERY call
  // (cch-bl-mockjs-revoke-stateless), so the 4-arg stateful path is the only
  // one either harness takes and the `if (state)` splice always fires. Two
  // consequences, both in the honest direction: the browser preview's token
  // list now SHRINKS on revoke instead of reporting success over a list that
  // never moved, and a DELETE for an id absent from the bag now 404s where it
  // used to 200 unconditionally. The only such id is the plaintext-once mint's
  // `pat_…`, which the POST arm never appends to the bag and which therefore
  // never reaches a rendered row (the list refetches), so no UI path can reach
  // the new 404 — but it is a real behavioural change, not a no-op.
  const tokOne = p.match(/^\/v1\/tokens\/([^/]+)$/);
  if (tokOne && method === "DELETE") {
    return destroyFrom(listOf(d, state, "tokens"), state, (t) => t.id === tokOne[1]);
  }

  // /v1/audit is team-admin-only server-side; auditDenied models the member's
  // 403 (the Timeline must degrade to events-only, never error).
  // REVIEW FIX (GR80 leg 2): the three filter axes are applied SERVER-side, so
  // the harness models them here too. Without this the harness answered the
  // unfiltered trail to a filtered request — a filtered feed would render rows
  // that contradict its own lit chips, which is exactly the class of harness lie
  // #4593 was opened for. Mirrors accounts.ex: maybe_audit_target needs BOTH
  // target_type and target_id, maybe_audit_actor is equality on actor_user_id,
  // maybe_audit_action_prefix is LIKE '<prefix>%' with the metacharacters escaped
  // (so a plain startsWith is the faithful model). target_type narrows on its own
  // — the widened maybe_audit_target clause this review added, because that is
  // the exact request the Activity chip row has always sent.
  if (p === "/v1/audit") {
    // cch-w35-s4: the refusal carries the server's EVIDENCE, because the real one
    // does. Auth.require_current_team_admin answers this route with
    // `forbidden(conn, required: "admin", scope: "team")` — "team", NOT
    // "primary_team": cch-w37-s3 renamed the label because the gate reads
    // conn.assigns[:current_team] (resolve_team/2 honours the x-barkpark-team
    // header), so it never consulted the primary team. A fixture that modelled a
    // refusal shape the server never sends would be its own kind of lie. The
    // console renders the `required` label and deliberately ignores `scope`.
    if (d.auditDenied) {
      return { status: 403, body: { error: "forbidden", required: "admin", scope: "team" } };
    }
    const q = new URLSearchParams(String(path || "").split("?")[1] || "");
    const ttype = q.get("target_type");
    const tid = q.get("target_id");
    const actor = q.get("actor_user_id");
    const prefix = q.get("action_prefix");
    const before = q.get("before");
    const events = (d.audit || []).filter((e) => {
      if (ttype && String(e.target_type || "") !== ttype) return false;
      if (ttype && tid && String(e.target_id || "") !== tid) return false;
      if (actor && String((e.actor && e.actor.id) || e.actor_user_id || "") !== actor) return false;
      if (prefix && !String(e.action || "").startsWith(prefix)) return false;
      if (before && !(String(e.inserted_at || "") < before)) return false;
      return true;
    });
    return { status: 200, body: { events } };
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
    // cch-bl-webhook-delete-oracle: through listOf, so the endpoint DELETE below
    // is visible to the next list read. The stateless arm is `d.webhooks`
    // verbatim. NOTE the path arrives QUERY-STRIPPED (route() splits on "?"),
    // so `?dataset=production` is already gone by the time these matchers run.
    return { status: 200, body: { data: { webhooks: listOf(d, state, "webhooks") } } };
  }
  // cch-bl-webhook-delete-oracle — DELETE one endpoint, the TWELFTH destroy verb
  // and the only list-shaped one cch-w10 could not reach. It was UNMODELLED: it
  // fell through the terminal `/v1/` 200 {}, so `deleteWebhook` toasted its
  // client-side constant ("Webhook deleted") against a fixture that still served
  // both endpoints. Placed ABOVE the PUT matcher's siblings but sharing whOne's
  // shape, so a wrong id 404s exactly as destroyFrom does everywhere else.
  const whDelete = p.match(/^\/v1\/barkparks\/[^/]+\/api\/webhooks\/([^/]+)$/);
  if (whDelete && method === "DELETE") {
    return destroyFrom(listOf(d, state, "webhooks"), state, (w) => String(w.id) === whDelete[1]);
  }
  const whOne = p.match(/^\/v1\/barkparks\/[^/]+\/api\/webhooks\/([^/]+)$/);
  if (whOne && method === "PUT") {
    const cur = (d.webhooks || []).filter((w) => String(w.id) === whOne[1])[0] || { id: whOne[1] };
    return { status: 200, body: { data: { webhook: Object.assign({}, cur) } } };
  }
  // D-05: an endpoint's delivery log + a replay. Deliveries read the scenario's
  // webhookDeliveries[id] fixture (empty when absent → the honest "No deliveries
  // yet."); a replay echoes back a fresh 200 delivery so the real-response toast
  // (replayToastBody) has TRUE status + latency fields to name, never a mock.
  const whDeliveries = p.match(/^\/v1\/barkparks\/[^/]+\/api\/webhooks\/([^/]+)\/deliveries$/);
  if (whDeliveries && method === "GET") {
    const list = (d.webhookDeliveries && d.webhookDeliveries[whDeliveries[1]]) || [];
    return { status: 200, body: { data: { deliveries: list } } };
  }
  const whReplay = p.match(/^\/v1\/barkparks\/[^/]+\/api\/webhooks\/[^/]+\/deliveries\/([^/]+)\/replay$/);
  if (whReplay && method === "POST") {
    return {
      status: 200,
      body: { data: { delivery: {
        event_id: whReplay[1], status: "delivered", last_status_code: 200,
        last_latency_ms: 88, attempts: 1, updated_at: new Date().toISOString(),
      } } },
    };
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
    // cch-w45-bl: a scenario overrides via d.instanceVerify to drive one of the
    // two CODED refusals (409 not_live, 404 no_admin_token) — the instanceRollback
    // seam, same shape. The default stays the all-pass 200 below, so every
    // scenario written before this line is byte-identical through it.
    if (d.instanceVerify) return d.instanceVerify;
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
    const s = listOf(d, state, "sites").filter((x) => String(x.id) === siteMatch[1])[0];
    return s ? { status: 200, body: { site: s } } : { status: 404, body: { error: "not_found" } };
  }
  // cch-w2-revoke-oracle-round2 — DELETE /v1/sites/:id/github, the repository
  // UNLINK. It was UNMODELLED: it fell through the terminal `/v1/` 200 {}, so
  // disconnectSiteGithub "succeeded" against a fixture that then re-served a
  // site still carrying github_repo — the refetched header repainted the repo
  // chip and the console looked like it had ignored the operator.
  //   grep -n "function disconnectSiteGithub" cloud/priv/static/app.js
  // is the handler; it reads `#github-disconnect-site`, which openSiteGithub
  // paints only when the site's `github_webhook_configured` is true.
  const siteGithub = p.match(/^\/v1\/sites\/([^/]+)\/github$/);
  if (siteGithub && method === "DELETE") {
    const s = listOf(d, state, "sites").filter((x) => String(x.id) === siteGithub[1])[0];
    // 404 on a miss AND on an already-unlinked site — destroyFrom's rule: a
    // no-op must never be indistinguishable from real work.
    if (!s || !s.github_repo) return { status: 404, body: { error: "not_found" } };
    if (state) { s.github_repo = null; s.github_branch = null; s.github_webhook_configured = false; }
    return { status: 200, body: { ok: true } };
  }
  // The repo picker openSiteGithub reads before it can paint anything at all.
  // Gated on the fixture so every scenario without one keeps falling through to
  // the catch-all exactly as before (which renders the honest "Couldn't load
  // your repositories" arm).
  if (p === "/v1/github/repos" && method === "GET" && d.githubRepos) {
    return { status: 200, body: { repos: d.githubRepos } };
  }
  // cch-w25-s3: PER-SITE deployment lists. The default stays the scenario-wide
  // `d.deployments` (every scenario written before this line is byte-identical
  // through it); a scenario that needs two DIFFERENT deploy stories on one
  // fixture — a cruel rail on one site and its kind control on the other —
  // keys them by site id under `deploymentsBySite`. Without this seam the
  // cruel string and its control would have to be two scenarios, which pays
  // the census/residue blast radius twice for one measurement.
  const depMatch = p.match(/^\/v1\/sites\/([^/]+)\/deployments$/);
  if (depMatch) {
    const bySite = d.deploymentsBySite || null;
    const own = bySite && Object.prototype.hasOwnProperty.call(bySite, depMatch[1]) ? bySite[depMatch[1]] : null;
    return { status: 200, body: { deployments: own || d.deployments || [] } };
  }
  // gr-p3: branch previews now come from the scenario (d.previews) so the
  // preview-rows section is observable; absent → the honest empty list.
  if (/^\/v1\/sites\/[^/]+\/previews$/.test(p)) return { status: 200, body: { previews: d.previews || [] } };
  // gr-p3: the site domain-status checklist (same envelope as the instance
  // sibling, CF-mode-aware). MUST precede the /v1/ catch-all (its 200 {} would
  // read as "no domains" and no scenario could pin the rungs). Absent fixture →
  // the honest no-attached-domains shape (the section stays unpainted).
  if (/^\/v1\/sites\/[^/]+\/domain-status$/.test(p)) {
    return { status: 200, body: d.siteDomainStatus || { ok: true, domains: [] } };
  }

  // S11b: the lifecycle-capabilities conduit. A scenario without a `capabilities`
  // fixture answers the empty shape → the row degrades to "capabilities
  // unavailable" (exactly as an older control plane would).
  if (p === "/v1/providers/capabilities") {
    return { status: 200, body: d.capabilities || {} };
  }

  // gr-p4 G-02: the connected-providers collection. GET is member-readable (the
  // roster + matrix render for every role); POST (connect) + DELETE /:kind
  // (disconnect) are admin-only server-side. A scenario carries `providers` (the
  // roster) and optionally `providerConnect` (a 422 preflight remediation);
  // absent → an empty roster + a benign 201/200. MUST precede the catch-all AND
  // the /:kind/catalog GET (those are two-segment; these are exact or one-segment
  // DELETE, so they never collide with the capabilities/catalog reads above).
  if (p === "/v1/providers" && method === "GET") {
    return { status: 200, body: { providers: listOf(d, state, "providers") } };
  }
  if (p === "/v1/providers" && method === "POST") {
    return d.providerConnect || { status: 201, body: { provider: { kind: "hetzner", label: "main" } } };
  }
  // Disconnect is a per-KIND destroy (the server deletes every credential of that
  // kind), so the roster shrinks by the row whose kind matches — not by id.
  const provOne = p.match(/^\/v1\/providers\/([^/]+)$/);
  if (method === "DELETE" && provOne) {
    return destroyFrom(listOf(d, state, "providers"), state, (x) => (x.kind || "") === provOne[1]);
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

  // G-04 notifications. GET settings is member-readable; the mutations (PUT
  // settings/channels/events, POST test, GET deliveries) are admin-gated server-
  // side — the harness echoes the fixture back on a write so a live click
  // reconciles, and models the deliveries 500 so the log's honest-degrade path is
  // observable. `notifSettings` absent → the benign empty 200 (older-CP shape).
  if (p === "/v1/notifications/settings") {
    if (method === "PUT") return { status: 200, body: { settings: d.notifSettings || {} } };
    return d.notifSettings ? { status: 200, body: { settings: d.notifSettings } } : { status: 200, body: {} };
  }
  if (p === "/v1/notifications/channels" && method === "PUT") return { status: 200, body: { settings: d.notifSettings || {} } };
  if (p === "/v1/notifications/events" && method === "PUT") return { status: 200, body: { settings: d.notifSettings || {} } };
  if (p === "/v1/notifications/test" && method === "POST") return { status: 202, body: { ok: true } };
  // GR79: the delivery log filters and pages SERVER-side, so the harness models
  // the query params too — otherwise a "filtered" scenario would render the
  // unfiltered fixture and the round-trip claim would be untested. Mirrors
  // notifications.ex exactly: maybe_delivery_eq is an equality match that
  // IGNORES an empty string, and maybe_delivery_before is strictly-older on
  // inserted_at over a newest-first list.
  if (p === "/v1/notifications/deliveries" && method === "GET") {
    if (d.notifDeliveriesError) return { status: 500, body: { error: "internal" } };
    const qs = new URLSearchParams(String(path || "").split("?")[1] || "");
    const eq = (row, field) => {
      const want = qs.get(field);
      return !want ? true : String(row[field] || "") === want;
    };
    const before = qs.get("before");
    const rows = (d.notifDeliveries || []).filter((row) =>
      eq(row, "channel") && eq(row, "status") && eq(row, "event") &&
      (!before || String(row.inserted_at || "") < before));
    const limit = Math.min(Number(qs.get("limit")) || 50, 200);
    return { status: 200, body: { deliveries: rows.slice(0, limit) } };
  }
  // G-06 MEMBERS: the roster + invitations reads. Team-scoped under /v1/teams/:id.
  // A scenario carries `members`/`invitations` fixtures; absent → honest empty
  // lists (the panel never errors on an empty team). Invitations are admin-gated
  // server-side, but the client already skips the call for a plain member, so a
  // member scenario simply omits the fixture. The DELETEs are click-driven and,
  // since cch-w10, actually DRIVEN: members-populated clicks Remove and Revoke
  // for real, so both lists are served from the per-boot store and shrink.
  if (/^\/v1\/teams\/[^/]+\/members$/.test(p) && method === "GET") {
    // cch-w12-followup-login-fixture-gap: the roster is TEAM-scoped, so after
    // the account change it is the second team's. The two rosters share no user
    // id, which is what makes "the Who axis still names lin" an unambiguous
    // reading rather than a coincidence of two similar fixtures.
    if (state && state.secondIdentity && d.secondIdentity && d.secondIdentity.members) {
      return { status: 200, body: { members: d.secondIdentity.members } };
    }
    return { status: 200, body: { members: listOf(d, state, "members") } };
  }
  const memberOne = p.match(/^\/v1\/teams\/[^/]+\/members\/([^/]+)$/);
  if (memberOne && (method === "DELETE" || method === "PATCH")) {
    // A scenario that pins a failure (memberWrite) keeps its exact envelope AND
    // its roster: a 403 that still shrank the list would be a fixture lying in
    // the opposite direction. PATCH is a role change, never a removal.
    if (d.memberWrite) return d.memberWrite;
    if (method === "PATCH") return { status: 200, body: { ok: true } };
    return destroyFrom(listOf(d, state, "members"), state, (x) => x.user_id === memberOne[1]);
  }
  if (/^\/v1\/teams\/[^/]+\/invitations$/.test(p)) {
    if (method === "POST") {
      return d.invitePost || {
        status: 201,
        body: { invitation: { id: "inv_new", email: "new@acme.com", role: "member", expires_at: tPlus(7 * 86400), inserted_at: T }, accept_url: "http://localhost/#/invitations/accept?token=preview-new" },
      };
    }
    return { status: 200, body: { invitations: listOf(d, state, "invitations") } };
  }
  const inviteOne = p.match(/^\/v1\/teams\/[^/]+\/invitations\/([^/]+)$/);
  if (inviteOne && method === "DELETE") {
    return destroyFrom(listOf(d, state, "invitations"), state, (x) => x.id === inviteOne[1]);
  }

  // gr-p5 OPERATOR: the session-gated /v1/operator/* seam. `operatorDenied`
  // models the live control plane with PLATFORM_ADMIN_EMAILS unset — every route
  // 403s — so the console's honest per-card degrade is observable. A scenario
  // without an operator fixture gets the same 403 (a non-operator never reads
  // these), which is exactly what the bounce scenario needs.
  if (p.indexOf("/v1/operator/") === 0) {
    const forbidden = { status: 403, body: { error: "forbidden" } };
    if (d.operatorDenied) return forbidden;
    if (p === "/v1/operator/autoupdate" && method === "GET") {
      return d.operatorAutoupdate ? { status: 200, body: d.operatorAutoupdate } : forbidden;
    }
    if (p === "/v1/operator/autoupdate/halt" && method === "POST") return { status: 200, body: { halted: true } };
    if (p === "/v1/operator/autoupdate/resume" && method === "POST") return { status: 200, body: { halted: false } };
    if (p === "/v1/operator/fleet") return d.operatorFleet ? { status: 200, body: d.operatorFleet } : forbidden;
    if (p === "/v1/operator/warm-pool") return d.operatorWarmPool ? { status: 200, body: d.operatorWarmPool } : forbidden;
    if (p === "/v1/operator/deliveries") {
      return d.operatorDeliveries ? { status: 200, body: { deliveries: d.operatorDeliveries } } : forbidden;
    }
    // dr-w1-s2: GET /v1/operator/deploy-ledger/census?from=&to=. The console
    // pins its own window, so the fixture is matched on the PATH alone and the
    // query is ignored here — the window bytes the browser sends are asserted
    // in __app.test.mjs (operatorCensusPath), where they can be pinned against
    // an injected clock instead of a wall clock.
    if (p === "/v1/operator/deploy-ledger/census") {
      return d.operatorCensus ? { status: 200, body: d.operatorCensus } : forbidden;
    }
    return forbidden;
  }

  // cch-w48-s6 GITHUB — placed ABOVE the catch-all below on purpose: the
  // catch-all answers `{}`, which renderGithub reads as the not-configured arm,
  // and that is why arm 1 (connected) had never been painted. GATED ON THE
  // FIXTURE so no scenario without a `github` fixture changes behaviour by one
  // byte — the catch-all keeps serving them exactly what it served before.
  // CONSOLE-SIDE, NOT SERVER TRUTH: see the fixture's own comment on
  // `providers-member` — the deployed control plane has no GitHub App
  // credentials and cannot answer connected:true. The DELETE arm exists so the
  // Disconnect affordance has a wire to reach, not because a member may use it
  // (cch-w48-s3 owns that fence).
  if (p === "/v1/github/installation" && d.github) {
    // cch-w2-revoke-oracle-round2 — STATEFUL, on the sessionsOf/listOf pattern.
    // It used to answer `{connected:false}` to the DELETE and then serve
    // `d.github` — connected:true — to the refetch the success arm issues, so
    // the card repainted CONNECTED after a successful disconnect and no oracle
    // could tell the teardown from a no-op. A single object rather than a list
    // (this endpoint is a singleton), but the three properties are the same:
    // opt-in on `state`, copied per boot, and the GET reads through it.
    const inst = githubOf(d, state);
    if (method === "DELETE") {
      // 404 on a miss, exactly as destroyFrom does: disconnecting nothing must
      // be distinguishable from disconnecting something.
      if (!inst.connected) return { status: 404, body: { error: "not_found" } };
      if (state) { inst.connected = false; delete inst.account_login; }
      return { status: 200, body: { connected: false } };
    }
    if (method === "GET") return { status: 200, body: inst };
  }

  // Anything else under /v1 answers a benign empty 200 so a stray read never
  // trips the 401→logout path or throws mid-render.
  if (p.indexOf("/v1/") === 0) return { status: 200, body: {} };
  return null;
}
