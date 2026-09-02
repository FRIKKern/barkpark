// __unknown_census.mjs — THE ABSENCE-AS-ANSWER CENSUS over the Cloud console SPA.
//
// Charter D382/D383 (wave 34), WIDENED IN PLACE by cch-w67-s4 (wave 68, charter
// D821). The law this instrument enforces:
//
//     A FAILED READ IS NOT AN EMPTY ONE.
//
// The original census matched ONE mechanical form of the lie — the fold
// `(r.ok && …) || []` — and its two documented limits (depth-1 callee inlining,
// regex-evadable fold spelling) are exactly what hid 8 of the 12 degrades wave
// 68 fixed. This widening subsumes both limits by changing the DENOMINATOR:
// the census is now a census of EVERY api("GET", …) call site in app.js
// (61 when this pin was written — the count is derived, never the gate), each
// pinned with a VERDICT and a one-line reason:
//
//   guarded    — a failed read produces a DISTINCT honest state (its own copy,
//                a retained fault threaded to the renderer, or a named degrade
//                line), so failure can never masquerade as absence.
//   sanctioned — silence or a soft degrade on failure is a DOCUMENTED ruling
//                (charter or at-site comment), not an accident. The note names
//                the ruling. loadSiteDomains lives here — it paints NO sentence
//                on failure (button-restore only), so pinning it `guarded`
//                would itself be the lie (wave-68 correction 5).
//   degrades   — the site still converts a failure into a determinate claim.
//                Every such row carries the bp task that owns it. Adding one is
//                a decision; it is never a way to quiet the gate.
//
// EVERY ROW ALSO CARRIES A PROOF — regexes that must match the enclosing
// function's body (or, for cross-function guards, the file). The proof pins the
// MECHANISM of the verdict: strip a guarded row's !ok arm and its proof stops
// matching, so the gate reds on the DECAY of a guard, not only on the arrival
// or departure of a call site. That is the REMOVE arm generalised: a row decays
// either by disappearing or by no longer being what its verdict claims.
//
// THE GATE IS A PINNED-ALLOWLIST SET DIFF, NEVER A COUNT (D383, measured via
// mutant M5: fix one + ship one keeps any count identical). It reds on any
// call site ADDED or REMOVED — keyed by (enclosing function, path expression,
// occurrence) — and names both the arrival and the departure. Moving a call
// site between functions is therefore an ADD + a REMOVE, which is the
// attribution mutation proof.
//
// ATTRIBUTION. Wave 68 fixed the brace-walk: the old walker treated regex
// literals as code, so a regex containing a quote (e.g. `/"/g` inside esc())
// flipped the string state and one function's extent swallowed its neighbours
// (esc's extent covered 30+ following functions; enclosing() only survived by
// the innermost-wins tiebreak). The walker is now regex-aware, and the census
// REFUSES to measure (exit 2) if any two top-level function extents overlap —
// a broken walker is a broken instrument, never a clean tree.
//
// REMAINING LIMIT, STATED: the denominator is matched by /\bapi\(\s*"GET"/, so
// a read issued through a new wrapper (or raw fetch) is invisible until it is
// pinned. This census raises the cost of the mistake; it does not make the
// mistake impossible. It is a ratchet, not a proof of absence.
//
//   exit 0 — the call-site set EQUALS the pin and every proof holds
//   exit 1 — arrivals, departures, or a verdict whose proof no longer matches
//   exit 2 — the instrument REFUSES to measure: broken walker (overlapping
//            extents), zero call sites (broken extractor), a missing positive
//            control, or a control that contains a GET site
//
// POSITIVE CONTROLS. Five state renderers that consume NO response envelope and
// contain NO api() call. They must be PRESENT and must hold ZERO call sites —
// the proof this instrument discriminates functions rather than counting text.
//
// The mutation driver is not committed under cloud/priv/static (fence): it
// patches app.js in a temp copy and runs `node __unknown_census.mjs <tmp>` —
// which is why the file under census is argv[2]-overridable below.
//
// Run: node cloud/priv/static/__unknown_census.mjs

import fs from "node:fs";

const FILE = process.argv[2] || new URL("./app.js", import.meta.url).pathname;
const LABEL = process.argv[2] || "cloud/priv/static/app.js";
const src = fs.readFileSync(FILE, "utf8");

// ── the pin: every api("GET") call site, keyed fn + path expression ─────────
// p is the second argument's source text, whitespace-collapsed. proof entries
// match the ENCLOSING FUNCTION body; fileProof entries match the whole file
// (for guards that live in a pure helper the loader calls).
const OWNER_W34 = "owned by cch-w34-bl-five-remaining-absence-collapses";
const EXPECT = [
  { f: "loadSessions", p: '"/v1/account/sessions"', v: "guarded",
    proof: [/!r\.ok/],
    why: "failure paints its own line — distinct from 'No active sessions.'" },
  { f: "loadProviders", p: '"/v1/providers"', v: "guarded",
    proof: [/data-providers-retry/],
    why: "cch-w67-s4: !ok arm speaks + Retry; the roster/empty state renders only from a 200" },
  { f: "loadProviderIdentity", p: '"/v1/providers/" + encodeURIComponent(kind) + "/overview"', v: "guarded",
    proof: [/providerIdentityModel\(r\.ok && r\.data \? r\.data : null\)/],
    why: "a null model paints the honest couldn't-read state, never a blank" },
  { f: "loadCapabilityMatrix", p: '"/v1/providers/capabilities"', v: "guarded",
    proof: [/capabilityMatrixModel\(r\.ok && r\.data \? r\.data : null\)/],
    why: "a null model renders the matrix's own unknown state" },
  { f: "loadGithub", p: '"/v1/github/installation"', v: "guarded",
    proof: [/data-github-retry/],
    why: "cch-w67-s4: only a 200 may claim a configuration state; failure speaks + Retry" },
  { f: "loadNotifications", p: '"/v1/notifications/settings"', v: "guarded",
    proof: [/Couldn\\'t load settings/],
    why: "failure paints its own empty-state headline" },
  { f: "loadNotifDeliveries", p: "notifDeliveriesQuery(null)", v: "guarded",
    proof: [/notifDeliveriesErrorHtml\(r\.status, r\.data\)/],
    why: "cch-w40-s1: the error copy names status + body" },
  { f: "loadMoreNotifDeliveries", p: "notifDeliveriesQuery(before, beforeId)", v: "guarded",
    proof: [/Couldn't load more/],
    why: "failure toasts; the accumulated trail is untouched" },
  { f: "loadTokens", p: '"/v1/tokens"', v: "guarded",
    proof: [/!r\.ok/, /Nothing was changed/],
    why: "cch-w34-s1: hoisted arm + the unconditional 'Nothing was changed' reassurance" },
  // cloud-agent onramp: the console's first reader of the credentials route.
  // `guarded` and not `sanctioned`: the read has no empty state to collapse INTO
  // — a failure opens no modal at all and toasts through faultCopy, so the
  // status classification (5xx = ours, 0 = the named transport, 4xx = the
  // route's own curated slug) is what the person is told. The proof pins the
  // whole faultCopy call, `transport` included: dropping that argument is
  // exactly how a dead network starts reporting as a fact about the instance.
  { f: "connectAgent", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/credentials"', v: "guarded",
    proof: [/faultCopy\(r\.status, r\.data, "Please try again\.", r\.transport\)/],
    why: "no empty state exists to collapse into: failure opens no reveal and toasts the classified fault" },
  { f: "ensureFleet", p: '"/v1/barkparks"', v: "guarded",
    proof: [/fleetFault = \{ status: r\.status/],
    why: "resolves null + retains the fault for null-guarded readers; only success is cached" },
  { f: "loadFleet", p: '"/v1/barkparks"', v: "guarded",
    proof: [/!r\.ok/],
    why: "failure paints 'Couldn't load fleet'" },
  { f: "loadArchives", p: '"/v1/archives"', v: "guarded",
    proof: [/archivesModel\(r\.data, instanceAdminAuthority\(\)\)/],
    why: "archivesModel owns the honest error + Retry arm (route bodies both 200 and 502)" },
  { f: "loadOverview", p: '"/v1/barkparks"', v: "guarded",
    proof: [/markRefreshStale\(\)/],
    why: "full-load failure paints the error state; a background failure marks staleness, never blanks" },
  { f: "loadOverview", p: '"/v1/usage/summary"', v: "sanctioned",
    proof: [/res\[0\]\.ok && res\[0\]\.data && res\[0\]\.data\.usage\) \? res\[0\]\.data\.usage : null/],
    why: "null usage renders the slots meter's unknown state — never a fabricated quota" },
  { f: "loadOverview", p: '"/v1/onboarding"', v: "sanctioned",
    proof: [/ob = meCache\.onboarding/],
    why: "a failed read keeps the last-known fold rather than blanking it (comment at site)" },
  { f: "refreshOverviewOnboarding", p: '"/v1/onboarding"', v: "sanctioned",
    proof: [/if \(!ob\) return;/],
    why: "failed read → keep the last-known fold, never blank it (comment at site)" },
  { f: "loadOverviewDigest", p: '"/v1/audit?limit=5"', v: "sanctioned",
    proof: [/403 \(non-admin\) or any error/],
    why: "charter ruling: the digest hides on 403/any error — never a scare on the Overview" },
  { f: "wireLifecycleActions", p: '"/v1/providers/capabilities"', v: "guarded",
    proof: [/r && r\.ok && r\.data \? r\.data : null/],
    why: "a null payload paints 'capabilities unavailable' + Retry; decommission stays live" },
  // pdf-bl-console-key-custody (PDF-D94): the paste-a-key delivery status poll.
  { f: "pollAgentKeyStatus", p: '"/v1/barkparks/" + encodeURIComponent(supportId) + "/agent-key"', v: "guarded",
    proof: [/Couldn\'t read the delivery status/],
    why: "a failed status read speaks and retries — it never renders as 'no delivery in flight'" },
  { f: "loadFleetRollout", p: "OPERATOR_AUTOUPDATE", v: "sanctioned",
    proof: [/if \(!r\.ok \|\| !r\.data\) return;/],
    why: "operator-gated banner slot stays empty on non-ok (older CP 404 / non-operator 403) — by design" },
  { f: "operatorPaint", p: "path", v: "guarded",
    proof: [/operatorCardBody\(r, render\)/],
    why: "a non-ok read paints the card's own honest degrade, never a dead spinner" },
  { f: "loadInstanceSites", p: '"/v1/sites"', v: "guarded",
    proof: [/!r\.ok/],
    why: "cch-w34-s1: hoisted arm — 'No sites yet' may only describe a 200" },
  { f: "loadWebhooks", p: 'whPath(bp, "", ds)', v: "guarded",
    proof: [/webhookErrorHtml\(r\.data, cliInstance\(bp\)\)/],
    why: "failure paints webhookErrorHtml + Retry" },
  { f: "loadDeliveries", p: 'whPath(bp, "/" + encodeURIComponent(wh.id) + "/deliveries", ds)', v: "guarded",
    proof: [/webhookErrorHtml\(r\.data, cliInstance\(bp\)\)/],
    why: "failure paints webhookErrorHtml + Retry" },
  { f: "loadTimeline", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/events?limit=100"', v: "guarded",
    proof: [/Couldn\\'t load the timeline/],
    why: "the events read failing IS the error state, with Retry" },
  { f: "loadTimeline", p: '"/v1/audit?target_type=barkpark&target_id=" + encodeURIComponent(bp.id) + "&limit=100"', v: "guarded",
    proof: [/Audit entries couldn't be loaded/],
    why: "the audit read degrades to a NAMED quiet line (403 → the admins-only note) — never silence" },
  { f: "loadInstanceVerify", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/events?limit=200"', v: "guarded",
    proof: [/data-verify-retry/],
    why: "cch-w67-s4: failure paints its own card + Retry — no longer vanishes into 'no verify run exists'" },
  { f: "loadInstanceDomains", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/domain-status"', v: "sanctioned",
    proof: [/restoreDomainRecheck\(b\)/],
    why: "404/error keeps the static Domain rail row (never an error IN the rail) but restores the re-check control" },
  { f: "loadSiteDomains", p: '"/v1/sites/" + encodeURIComponent(site.id) + "/domain-status"', v: "sanctioned",
    proof: [/restoreDomainRecheck\(b\)/],
    why: "SANCTIONED-SILENT: paints no sentence on failure — button-restore only. Never pin this guarded (wave-68 correction 5)" },
  { f: "loadSites", p: '"/v1/sites"', v: "guarded",
    proof: [/!r\.ok/, /res\[1\] === null/, /data-sites-fleet-retry/],
    why: "cch-w67-s4: sites !ok arm speaks; the fleet leg reads fleetFault only under res[1]===null and banners what the rows can't say" },
  { f: "loadSite", p: '"/v1/sites/" + encodeURIComponent(id)', v: "guarded",
    proof: [/siteLoadFailureHtml\(sr\)/, /res\[2\] === null/],
    why: "cch-w66-s3 guard splits deletion from failure; cch-w67-s4: the fleet leg reads fleetFault only under res[2]===null" },
  { f: "loadSite", p: '"/v1/sites/" + encodeURIComponent(id) + "/deployments"', v: "guarded",
    proof: [/deployFault = res\[1\] && res\[1\]\.ok \? null : res\[1\]/],
    why: "cch-w66-s3: the failed read rides beside the [] into deployListHtml" },
  { f: "loadSite", p: '"/v1/sites/" + encodeURIComponent(id) + "/previews"', v: "guarded",
    proof: [/previewFault = res\[3\] && res\[3\]\.ok \? null : res\[3\]/],
    why: "w67 crown: the failed read rides beside the [] into the previews section" },
  { f: "recheckSiteDeleted", p: '"/v1/sites/" + encodeURIComponent(site.id)', v: "guarded",
    proof: [/verdict = siteRecheckVerdict\(r\)/, /bound\.settled/],
    fileProof: [/if \(r\.status === 404\) return planeSpoke \? "gone" : "unknown"/],
    why: "cch-w68-s5 (D834): the degrade-to-DONE is gone — siteRecheckVerdict splits the plane's own 404 from every non-plane answer on r.text, and only 'gone' may succeed" },
  { f: "openSiteGithub", p: '"/v1/github/repos"', v: "guarded",
    proof: [/Couldn't load your repositories\./],
    why: "503/409/no-installation/error arms each speak their own state" },
  { f: "loadInvite", p: '"/v1/invitations/" + encodeURIComponent(token)', v: "guarded",
    proof: [/inviteLandingState\(pr\.status, preview, me/],
    fileProof: [/previewStatus >= 200 && previewStatus < 300 \? "invalid" : "check_failed"/],
    why: "cch-w67-s4: only a 404/empty-200 reads 'invalid'; a failed preview read lands check_failed and keeps the parked token" },
  { f: "loadInvite", p: '"/v1/me"', v: "sanctioned",
    proof: [/var me = res\[1\]\.ok \? res\[1\]\.data : null/],
    why: "me only refines already_member/wrong-account context; the invite preview is the authority on this surface" },
  { f: "showAuthInviteBanner", p: '"/v1/invitations/" + encodeURIComponent(token)', v: "guarded",
    proof: [/r\.status === 404 \|\| r\.ok/, /We couldn't check your invitation just now/],
    why: "cch-w67-s4: only a determinate dead answer consumes the parked token; a transient failure keeps it and says so" },
  { f: "mountLaunchCatalog", p: '"/v1/providers/" + encodeURIComponent(kind) + "/catalog"', v: "guarded",
    proof: [/catalogViewState\(r\)/],
    why: "catalogViewState's error state renders the couldn't-load card + Retry" },
  { f: "loadMe", p: '"/v1/me"', v: "guarded",
    proof: [/absorbMe\(r\)/],
    why: "cch-w36-s3: the failed arm records the fault so meState() reads 'failed', and re-enters every dependent view fail-closed" },
  { f: "loadSubscription", p: '"/v1/subscription"', v: "guarded",
    proof: [/subErrorFault = \{ status: r\.status/],
    why: "failure retained (subError + fault) — the UI shows a retry, never the upsell over a 500" },
  { f: "ensureActivityActors", p: '"/v1/teams/" + encodeURIComponent(tid) + "/members"', v: "sanctioned",
    proof: [/retryable, still silent/],
    why: "the Who axis silently omits the roster on failure; the latch clears so the next paint retries (comment at site)" },
  { f: "loadActivity", p: "activityQuery(null)", v: "guarded",
    proof: [/!r\.ok/],
    why: "failure paints 'Couldn't load activity'" },
  { f: "loadMoreActivity", p: "activityQuery(before, beforeId)", v: "guarded",
    proof: [/Couldn't load more/],
    why: "failure toasts; the accumulated trail is untouched" },
  { f: "renderOAuthButtons", p: '"/v1/auth/oauth/providers"', v: "guarded",
    proof: [/data-oauth-retry/],
    why: "cch-w67-s4: only a 200 may hide the SSO block; failure paints the couldn't-check note + retry" },
  { f: "loadTheaterCatalog", p: '"/v1/providers/" + encodeURIComponent(kind) + "/catalog"', v: "sanctioned",
    proof: [/vs\.state === "ready" \? vs\.catalog : null/],
    why: "the price line is garnish: a null catalog inserts nothing — the absence of a price, never a wrong one" },
  { f: "loadNewTemplates", p: '"/v1/templates"', v: "guarded",
    proof: [/return \{ fault: r \};/],
    fileProof: [/renderNewTemplatesFailed\(templates\.fault\)/],
    why: "cch-w67-s4: a failure returns a {fault} marker and is NEVER cached; renderNewFlow paints the failure card + retry" },
  { f: "newRenderOAuth", p: '"/v1/auth/oauth/providers"', v: "guarded",
    proof: [/data-oauth-retry/],
    why: "cch-w67-s4: the /new twin of renderOAuthButtons' arm" },
  { f: "newAskLaunchAuthority", p: '"/v1/me"', v: "guarded",
    proof: [/absorbMe\(r\)/],
    why: "an unknown authority withholds the launch form and renders the one exit (newLaunchOffer, fail-closed)" },
  { f: "renderNewPricing", p: '"/v1/me"', v: "sanctioned",
    proof: [/if \(resolved !== "blocked"\) return;/],
    why: "a failed read leaves the CTAs standing — unknown is not refused (comment at site); the checkout POST is the enforcer" },
  { f: "newCheckStatus", p: '"/v1/barkparks"', v: "guarded",
    proof: [/newState\.lastPollOkAt = Date\.now\(\)/],
    why: "dwb-16: a failed poll leaves lastPollOkAt stale → the connection-lost banner; never a silent frozen spinner" },
  { f: "newRenderReady", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/bootstrap"', v: "guarded",
    proof: [/bootFault = r\.ok \? null : r \|\| \{\}/],
    why: "cch-w67-s4: the fault rides beside boot — the ready tail names the missing env values instead of asserting 'no env keys'" },
  { f: "newRenderReady", p: '"/v1/github/installation"', v: "guarded",
    proof: [/ghFault = gr\.ok \? null : gr \|\| \{\}/],
    why: "cch-w67-s4: the fault rides beside gh — the absent repo affordance is explained, not passed off as 'not connected'" },
  { f: "mountUsageTab", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/usage"', v: "guarded",
    proof: [/usageErrorHtml\(r\.status\)/],
    why: "failure paints usageErrorHtml + Retry" },
  { f: "mountUsageTab", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/usage/history?points=" + USAGE_HISTORY_POINTS', v: "sanctioned",
    proof: [/honest absence/],
    why: "history is best-effort garnish: a failure leaves the meters bar-less (comment at site), never its own error state" },
  { f: "tick", p: '"/v1/barkparks/" + encodeURIComponent(bp.id) + "/metrics?points=" + METRICS_POINTS', v: "guarded",
    proof: [/metricsErrorHtml\(r\.status\)/],
    why: "failure paints metricsErrorHtml + Retry and stops the poll" },
  { f: "loadMembers", p: '"/v1/me"', v: "guarded",
    proof: [/membersErrorHtml\(r\.status\)/],
    why: "cch-w36-s3: a failed role read is not a teamless account" },
  { f: "fetchMembers", p: '"/v1/teams/" + t + "/invitations"', v: "guarded",
    proof: [/invFault = ir && ir\.ok \? null : ir \|\| \{\}/],
    fileProof: [/data-invites-retry/],
    why: "cch-w67-s4: the fault rides beside [] — the invitations section names the failure + Retry instead of 'No pending invitations.'" },
  { f: "fetchMembers", p: '"/v1/teams/" + t + "/members"', v: "guarded",
    proof: [/membersErrorHtml\(mr\.status\)/],
    why: "the members read failing paints membersErrorHtml + Retry" },
  { f: "openCommandPalette", p: '"/v1/sites"', v: "degrades",
    proof: [/r\.ok && r\.data && r\.data\.sites\) \|\| \[\]/],
    why: "a failed sites read silently omits the palette's Sites group (self-documented at site; silent-on-screen only) — " + OWNER_W34 },
];

// ── positive controls: named renderers that consume no envelope and hold no
// ── api() call at all.
const CONTROLS = [
  "presenceChip",
  "lifecyclePill",
  "catalogViewState",
  "metricsAgeText",
  "freshnessModel",
];

// ── function index: name -> [start,end) by brace matching, REGEX-AWARE ──────
// The old walker treated `/` as division always; a regex literal containing a
// quote or brace corrupted the string/depth state (measured: esc()'s extent
// swallowed every function up to line ~252). A `/` opens a regex here whenever
// the previous significant character cannot END an expression.
function scanExtent(s, open) {
  let depth = 0, i = open, inS = null, esc = false, inRe = false, inClass = false;
  let prev = "";
  for (; i < s.length; i++) {
    const c = s[i];
    if (inS) {
      if (esc) { esc = false; continue; }
      if (c === "\\") { esc = true; continue; }
      if (c === inS) inS = null;
      continue;
    }
    if (inRe) {
      if (esc) { esc = false; continue; }
      if (c === "\\") { esc = true; continue; }
      if (c === "[") { inClass = true; continue; }
      if (c === "]") { inClass = false; continue; }
      if (c === "/" && !inClass) { inRe = false; prev = "/"; }
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inS = c; continue; }
    if (c === "/" && s[i + 1] === "/") { i = s.indexOf("\n", i); if (i < 0) { i = s.length; break; } continue; }
    if (c === "/" && s[i + 1] === "*") { const e = s.indexOf("*/", i); i = e < 0 ? s.length : e + 1; continue; }
    if (c === "/") {
      // Division only after something that can end an expression; else regex.
      if (/[A-Za-z0-9_$)\]}]/.test(prev)) { prev = c; continue; }
      inRe = true; inClass = false; continue;
    }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) { i++; break; } }
    if (!/\s/.test(c)) prev = c;
  }
  return i;
}

function indexFunctions(s) {
  const out = [];
  const re = /\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
  let m;
  while ((m = re.exec(s))) {
    const open = s.indexOf("{", re.lastIndex);
    if (open < 0) continue;
    out.push({ name: m[1], start: m.index, end: scanExtent(s, open) });
  }
  return out;
}

const fns = indexFunctions(src);
const lineOf = (off) => src.slice(0, off).split("\n").length;

// The INNERMOST named function containing this offset — the callbacks these
// reads live in are anonymous, so the enclosing NAMED loader is the site.
function enclosing(off) {
  let best = null;
  for (const f of fns) {
    if (f.start <= off && off < f.end) {
      if (!best || f.start > best.start) best = f;
    }
  }
  return best;
}

// ── walker self-check: two TOP-LEVEL extents may never overlap ──────────────
// (top-level in this file = the `function` keyword at the IIFE's 2-space
// indent). Overlap means the walk is corrupted → REFUSE to measure.
function indentOf(off) { const nl = src.lastIndexOf("\n", off); return off - nl - 1; }
const topLevel = fns.filter((f) => indentOf(f.start) === 2);
const overruns = [];
for (let i = 0; i < topLevel.length - 1; i++) {
  if (topLevel[i].end > topLevel[i + 1].start) {
    overruns.push(topLevel[i].name + " ⊃ " + topLevel[i + 1].name);
  }
}

// ── the denominator: every api("GET", …) call site ──────────────────────────
function pathArgAt(s, callOpen) {
  let i = callOpen + 1, depth = 0, inS = null, esc = false;
  const args = []; let cur = "";
  for (; i < s.length; i++) {
    const c = s[i];
    if (inS) {
      cur += c;
      if (esc) { esc = false; continue; }
      if (c === "\\") { esc = true; continue; }
      if (c === inS) inS = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inS = c; cur += c; continue; }
    if (c === "(" || c === "[" || c === "{") { depth++; cur += c; continue; }
    if (c === ")" || c === "]" || c === "}") {
      if (c === ")" && depth === 0) { args.push(cur); break; }
      depth--; cur += c; continue;
    }
    if (c === "," && depth === 0) { args.push(cur); cur = ""; continue; }
    cur += c;
  }
  return (args[1] || "").replace(/\s+/g, " ").trim();
}

const GET_RE = /\bapi\(\s*"GET"/g;
const found = [];
{
  let m;
  while ((m = GET_RE.exec(src))) {
    const fn = enclosing(m.index);
    found.push({
      fn: fn ? fn.name : "<anonymous>",
      fnRef: fn || null,
      path: pathArgAt(src, src.indexOf("(", m.index)),
      line: lineOf(m.index),
    });
  }
}

// Occurrence-indexed keys so a duplicated (fn, path) pair still diffs cleanly.
function keyed(rows, fnOf, pathOf) {
  const seen = Object.create(null);
  return rows.map((r) => {
    const base = fnOf(r) + " :: " + pathOf(r);
    const n = (seen[base] = (seen[base] || 0) + 1);
    return { row: r, key: base + " :: #" + n };
  });
}
const foundKeyed = keyed(found, (r) => r.fn, (r) => r.path);
const pinKeyed = keyed(EXPECT, (r) => r.f, (r) => r.p);

// ── report head ─────────────────────────────────────────────────────────────
const counts = { guarded: 0, sanctioned: 0, degrades: 0 };
for (const r of EXPECT) counts[r.v] = (counts[r.v] || 0) + 1;
const controlsPresent = CONTROLS.filter((c) => fns.some((f) => f.name === c));
const controlsMissing = CONTROLS.filter((c) => !controlsPresent.includes(c));
const controlBreaches = CONTROLS.filter((c) => found.some((s) => s.fn === c));

console.log("file             :", LABEL);
console.log("walk             :", fns.length, "named functions,", overruns.length, "top-level overruns");
console.log("controls present :", controlsPresent.join(" ") || "(none)");
console.log("controls missing :", controlsMissing.join(" ") || "(none)");
console.log("controls w/ GETs :", controlBreaches.join(" ") || "(none)");
console.log("GET call sites   :", found.length,
  "· pin", EXPECT.length,
  "=", counts.guarded, "guarded ·", counts.sanctioned, "sanctioned ·", counts.degrades, "degrades");
for (const { row } of foundKeyed) {
  const pin = EXPECT.find((e) => e.f === row.fn && e.p === row.path);
  console.log("  " + (pin ? pin.v.padEnd(10) : "UNPINNED".padEnd(10)) + " " + row.fn + "  " + row.path + "  (" + LABEL + ":" + row.line + ")");
}

// ── refusals: a broken instrument never reports a clean tree ────────────────
if (overruns.length) {
  console.error("FAIL(2): the function walk is corrupted — overlapping top-level extents: " + overruns.join(", "));
  process.exit(2);
}
if (!found.length) {
  console.error("FAIL(2): zero api(\"GET\") call sites found — the extractor is broken, not the tree clean.");
  process.exit(2);
}
if (controlsMissing.length) {
  console.error("FAIL(2): a positive control is missing from the source: " + controlsMissing.join(" "));
  process.exit(2);
}
if (controlBreaches.length) {
  console.error("FAIL(2): a positive control now holds a GET call site: " + controlBreaches.join(" ") +
    " — the census can no longer prove it discriminates.");
  process.exit(2);
}

// ── THE SET DIFF. Never a count. ────────────────────────────────────────────
const foundKeys = foundKeyed.map((k) => k.key);
const pinKeys = pinKeyed.map((k) => k.key);
const arrivals = foundKeyed.filter((k) => !pinKeys.includes(k.key));
const departures = pinKeyed.filter((k) => !foundKeys.includes(k.key));

let failed = false;
if (arrivals.length || departures.length) {
  failed = true;
  console.error("");
  console.error("FAIL(1): the GET call-site set does not match the pin.");
  for (const a of arrivals) {
    console.error("  ARRIVED  " + a.key + "  (" + LABEL + ":" + a.row.line + ") — a new read shipped unpinned. " +
      "Decide its verdict (guarded|sanctioned|degrades), prove it, and pin it with a one-line why.");
  }
  for (const d of departures) {
    console.error("  DEPARTED " + d.key + " — the pinned site is gone (deleted, moved between functions, or its path rewrote). " +
      "Update the pin so it keeps describing the tree.");
  }
}

// ── VERDICT PROOFS: a verdict whose mechanism decayed is a red, not a pass ──
for (const { row, key } of pinKeyed) {
  const hit = foundKeyed.find((k) => k.key === key);
  if (!hit) continue; // already reported as DEPARTED
  const body = hit.row.fnRef ? src.slice(hit.row.fnRef.start, hit.row.fnRef.end) : "";
  for (const re of row.proof || []) {
    if (!re.test(body)) {
      failed = true;
      console.error("  DECAYED  " + key + " — pinned '" + row.v + "' but its proof " + re +
        " no longer matches " + row.f + "'s body. The guard/sanction this verdict names has been removed or rewritten.");
    }
  }
  for (const re of row.fileProof || []) {
    if (!re.test(src)) {
      failed = true;
      console.error("  DECAYED  " + key + " — pinned '" + row.v + "' but its file-level proof " + re +
        " no longer matches " + LABEL + ".");
    }
  }
}

if (failed) {
  console.error("");
  console.error("  pinned (" + EXPECT.length + ") vs found (" + found.length + ") — " +
    "the population SIZE is not the gate; the SET and the PROOFS are.");
  process.exit(1);
}

console.log("");
console.log("OK: all " + found.length + " GET call sites equal the pin (" +
  counts.guarded + " guarded · " + counts.sanctioned + " sanctioned · " + counts.degrades + " degrades) and every verdict proof holds.");
process.exit(0);
