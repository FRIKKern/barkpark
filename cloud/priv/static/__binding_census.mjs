// __binding_census.mjs — THE ELEVATED-WRITE BINDING CENSUS over the Cloud console SPA.
//
// Charter D383/D409/D421 (wave 37). The law this instrument enforces:
//
//     A BUTTON THE SERVER WILL REFUSE IS A LIE THE CONSOLE TOLD.
//
// The console draws write affordances. Some of those writes need more than
// plain team membership — owner, admin, primary-team admin, platform operator.
// When the console renders such an affordance with NO client predicate in front
// of it, a plain member sees a button, clicks it, and is handed a 403. The
// console told them they could do a thing it cannot support.
//
// ── WHAT THIS CENSUS IS NOT ─────────────────────────────────────────────────
//
// It is NOT an agreement census. Charter D409 already REFUTED that premise by
// measurement: every client predicate the console owns MATCHES the gate behind
// it, 6 for 6. An agreement census would go green on day one and stay green —
// exactly the clause-4 vacuity D383 exists to prevent. The live population is
// not disagreement, it is ABSENCE: elevated writes with no predicate at all.
//
// It is also NOT a drift gate. Charter D421 defers that arm, and names why: the
// only available oracle for a route's tier
// (cloud/test/barkpark_cloud/web/router_moduledoc_table_test.exs's tier map) is
// keyed by {METHOD, LITERAL path}, and it resolves the six inline-`cond`
// refusal sites to their OUTER `Auth.require_user`. Wired as a drift oracle it
// would report tier `user` for routes that refuse every non-admin — a gate that
// certifies the opposite of the truth. Filed, with its prerequisite, as
// cch-w37-bl-binding-census-drift-arm.
//
// ── WHAT IT IS: AN ADD/REMOVE SET DIFF, KEYED BY CALL SITE ──────────────────
//
//   ADD    — a write call site that no PIN row predicts reds. This is the arm
//            that loses on the disease: grow an elevated affordance, get a red.
//   REMOVE — a pinned call site whose function/route pair has vanished reds, so
//            the pin keeps describing the tree instead of decaying into fiction.
//
// THE GATE IS A PINNED SET DIFF, NEVER A COUNT (charter D383). A count gate is
// fail-green: one commit that predicates an affordance and ships a fresh
// unpredicated one keeps the population identical, and `count <= N` passes over
// a live regression. Both arms name the arrival AND the departure by call site.
//
// KEYING BY CALL SITE IS THE WHOLE POINT, and it is not a style preference.
// The 79 write call sites collapse to 67 route keys; 11 of those keys are
// multi-site. The decisive case is POST /v1/providers:
//
//   submitProviderCred()        — reached from the launch wizard's
//                                 `.launch-connect-provider` button, which
//                                 renderLaunchConnect draws UNCONDITIONALLY.
//                                 NO PREDICATE.
//   submitInlineProviderCred()  — reached only through renderConnectCard,
//                                 which renderProviderPage mounts only when
//                                 providerCanWrite().
//
//   (Re-derive both: grep -n 'function submitProviderCred' app.js, and the same
//   for submitInlineProviderCred. NO LINE NUMBER IS WRITTEN DOWN IN THIS FILE,
//   and every line number this census prints — app.js sites and the six router
//   overlay sites alike — is DERIVED at run time from the live file. That is a
//   description of the file as it stands, not an aspiration: it was FALSE until
//   charter D528, when the PIN's 79 documentary `line:` fields were deleted
//   (nothing read them; all 79 were stale) and the inline-cond overlay's six
//   typed-and-printed router lines were replaced by a resolver over the live
//   router source. Line numbers rot on any sibling shift — charter D41 /
//   bp-honest-gates D5 — so the PIN is keyed on the function name, and a
//   printed numeral is only ever this run's reading of the tree.)
//
// Route-keyed, those two collapse into one row, the row scores "predicated",
// and the ONE REAL DEFECT this instrument exists to see becomes structurally
// invisible. So the key is `<enclosing function>|<VERB> <route>` — stable under
// line drift, and it holds those two apart with opposite verdicts.
//
// ── THREE RULINGS ENCODED HERE (charter D421) ───────────────────────────────
//
// (a) `require_ability` IS NOT ELEVATED FOR THE CONSOLE. A browser session
//     carries the abilities `["root"]` — router.ex says so itself, in go_live's
//     own comment: "a SESSION carries [\"root\"], so `require_ability` is a
//     no-op for it". The check discriminates PATs, not people. Every console
//     call site whose only guard above membership is `require_ability` (or
//     `with_team_site(conn, {:ability, "write"}, …)`) is therefore PLAIN
//     MEMBER here: loadSite (PATCH /v1/sites/:*), runPromote, runSiteRollback,
//     createAndDeploy and runDeploy. A builder who counts `require_ability` as
//     elevated gets 46, not 40 — those five plus submitToken, whose whole
//     authority also lives below the router (see (c)).
//
// (b) THE VACUITY FLOOR ASSERTS "RESOLVED TO A ROUTE", NEVER "SEEN". A literal
//     path extractor silently drops 13 of the 79 — they build their path from a
//     variable or a helper — and a census that counted what it saw would call
//     that 66-of-66 and go green over a hole. Two of the dropped are the
//     console's HIGHEST-privilege writes (fleetRolloutAction and
//     operatorConfirmBrake, the operator autoupdate brake). Worse, a 14th does
//     not drop at all: submitActivateDecision builds
//     `"/v1/auth/device/" + decision` — a literal PREFIX with a variable last
//     segment, which a naive extractor ACCEPTS and mis-routes to
//     "/v1/auth/device/". Silent mis-routing beats silent dropping for damage,
//     so the extractor below REFUSES any path term that is neither a string
//     literal nor `encodeURIComponent(...)`, and every refusal must be answered
//     by a RESOLVERS row or the census exits 2.
//
// (c) canMintAnyAbility's AUTHORITY LIVES BELOW THE ROUTER. POST /v1/tokens is
//     `Auth.require_user` and nothing else — ANY member may mint a token — so
//     the row is NOT elevated. The owner/admin cap applies to the requested
//     ABILITY SET, in Accounts.pat_abilities_allowed?/2 (accounts.ex:865/873),
//     which no `auth_fn` can name. That is why `context_fn` is a first-class
//     slot in the schema and not a note: an auth_fn-only row here would either
//     red falsely (predicate present, gate says plain member) or assert the
//     flat untruth that any member may mint any ability.
//
// ── THE SCHEMA ──────────────────────────────────────────────────────────────
//
//   { fn, verb, route,                     // the key: fn|VERB route
//     elevated,                            // above plain team membership?
//     predicate,                           // the client fn gating it, or null
//     auth_fn,                             // the router's Auth.* guard, or null
//     context_fn,                          // authority BELOW the router, or null
//     note }
//
// ── HONEST LIMITS, stated, because an unstated limit is the same lie ─────────
//
//   LIMIT 1 — `elevated` AND `predicate` ARE PINNED JUDGEMENTS, NOT DERIVED.
//   The census DERIVES the call-site set and each site's route; it does not
//   re-derive the tier or re-trace the render path. So it cannot catch a
//   commit that keeps a call site in place while REMOVING the predicate around
//   it, nor one that raises a route's tier under an unchanged call site. Those
//   are the drift arm (deferred above). What it catches is GROWTH and LOSS of
//   the population — which is the shape the disease actually takes.
//
//   LIMIT 2 — THE EXTRACTOR MATCHES `api("VERB", …)` LITERALLY. A write issued
//   through a wrapper, or with the method in a variable, is invisible to it.
//   This raises the COST of the mistake; it does not make it impossible. A
//   ratchet, not a proof of absence.
//
//   LIMIT 3 — THE INLINE-COND OVERLAY IS CONTENT-MATCHED, NOT LINE-PINNED.
//   Six router routes refuse non-admins inside a `cond` rather than through an
//   `Auth.*` guard, so they are invisible to any guard grep. They are checked
//   by counting the exact `Accounts.team_admin?(conn.assigns.current_user,
//   conn.assigns.current_team)` form, so the check survives line drift — but it
//   cannot tell WHICH route grew a seventh. It tells you to go look.
//
//   The overlay also PRINTS a `router.ex:NNNN` per route, and those six numbers
//   are DERIVED by the same two regexes at run time — nothing compares them to
//   anything, so they cannot red and cannot go stale. What IS pinned is the six
//   ROUTE NAMES, and the print pairs name to line BY SOURCE ORDER. So the one
//   thing this print can still get wrong is a router that REORDERS these six
//   while keeping the count at six: the lines stay right and the names slide.
//   On any count change the pairing is dropped and the derived lines print
//   UNLABELED, because a mis-labelled failure message is a new false statement
//   of exactly the kind this census exists to remove.
//
// Exit codes:
//   0 — the derived call-site set EQUALS the pin, and every invariant holds
//   1 — ADD and/or REMOVE: the set differs from the pin, both named
//   2 — the instrument lost its footing: an unresolved path, a broken
//       discrimination control, a pin that no longer sums, a vanished
//       context_fn target, or a changed inline-cond overlay
//
// Run: node cloud/priv/static/__binding_census.mjs
//      node cloud/priv/static/__binding_census.mjs <app.js> <router.ex> <accounts.ex> <authz.ex>
//   (the argv overrides exist so a mutation driver can point the census at a
//    patched COPY without writing inside this slice's fence)

import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const APP = process.argv[2] || path.join(here, "app.js");
const ROUTER = process.argv[3] || path.join(here, "../../lib/barkpark_cloud/web/router.ex");
const ACCOUNTS = process.argv[4] || path.join(here, "../../lib/barkpark_cloud/accounts.ex");
const AUTHZ = process.argv[5] || path.join(here, "../../lib/barkpark_cloud/accounts/authz.ex");
// A context_fn names authority BELOW the router, and that authority does not
// all live in one module: the rank-relative member writes decide in
// `Accounts.*` but the router re-derives the refusal ARM through `Authz.*`.
// So check (2e) resolves a context_fn through this module → source map rather
// than assuming accounts.ex. A module-qualified context_fn whose module is
// absent here is a FAILURE, not a skip — otherwise naming an unmapped module
// would be the way to buy silence from the check.
const CONTEXT_SOURCES = { Accounts: ACCOUNTS, Authz: AUTHZ };
const MODULE_QUALIFIED = /^([A-Z][A-Za-z0-9_]*)\.(.+)$/;
// Report against a stable repo-relative label so the output reads the same from
// any cwd; a mutant copy passed as argv[2] keeps its own path.
const LABEL = process.argv[2] || "cloud/priv/static/app.js";

const src = fs.readFileSync(APP, "utf8");

// ═══════════════════════════════════════════════════════════════════════════
// THE PIN — 79 write call sites, keyed by `fn|VERB route`.
//
// A PIN ROW CARRIES NO LINE NUMBER, and adding one back is a regression. Every
// `app.js:NNNN` this census prints is DERIVED from the live file at run time
// (`lineOf`, below) and looked up by KEY, so it is correct by construction. The
// rows used to carry a documentary `line:` beside it; measured, all 79 were
// stale (median drift 524, max 928, zero correct) and nothing read them —
// setting one to 999999 left the report BYTE-IDENTICAL at rc 0. A number no
// check can red and no reader can trust is not orientation, it is a second
// answer that disagrees with the first. Deleted (charter D528).
//
// Adding a row is a DECISION — it means "this affordance is honest, or its
// dishonesty is owned by a filed task". It is never a way to quiet the gate.
// ═══════════════════════════════════════════════════════════════════════════

const A_USER = "Auth.require_user";
const A_TADMIN = "Auth.require_team_admin";
const A_PTADMIN = "Auth.require_primary_team_admin";
const A_PTOWNER = "Auth.require_primary_team_owner";
const A_OPERATOR = "Auth.require_platform_operator";
const A_USER_OR_PAT = "Auth.require_user_or_pat";
const A_ABILITY = "Auth.require_ability";
const H_TEAM_ROLE = 'with_team_role(conn, "admin")';
const H_TEAM_SITE = 'with_team_site(conn, {:ability, "write"})';
const H_TEAM_SITE_M = "with_team_site(conn, fn)";
const H_PROXY = "proxy_instance_webhook/2";
const C_TEAM_ADMIN = "Accounts.team_admin?/2";
const C_PAT_ABILITIES = "Accounts.pat_abilities_allowed?/2";
// The two rank-relative member writes. `with_team_role(conn, "admin")` is the
// whole of their ROUTER authority and none of their real one: whether THIS
// admin may touch THIS member is decided below the router, against a strict
// rank ladder (team_membership.ex:48). PATCH decides in
// `Accounts.update_member_role_as/4` (no owner escape hatch) and the router
// re-runs `Authz.can_grant?/3` only to split the refusal into `outranked` vs
// `cannot_grant_higher_role`; DELETE decides in `Accounts.remove_member_as/3`
// (owner escape hatch present) and its cause is always `outranked`.
const C_MEMBER_ROLE = "Accounts.update_member_role_as/4 + Authz.can_grant?/3";
const C_MEMBER_REMOVE = "Accounts.remove_member_as/3";

const PIN = [
  // ── account & session self-service — every one of these acts on the caller's
  // ── OWN account, so plain membership is the honest tier.
  { fn: "a2fWire", verb: "POST", route: "/v1/account/two-factor/enroll", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope: enrol your own 2FA" },
  { fn: "a2fWire", verb: "POST", route: "/v1/account/two-factor/confirm", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope" },
  { fn: "a2fWire", verb: "POST", route: "/v1/account/two-factor/recovery-codes", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope" },
  { fn: "run", verb: "DELETE", route: "/v1/account/two-factor", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope; `run` is the confirm-modal callback" },
  { fn: "run", verb: "DELETE", route: "/v1/account/sessions", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope: sign out your other sessions" },
  { fn: "openAccountModal", verb: "DELETE", route: "/v1/auth/logout", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope" },
  { fn: "paint", verb: "DELETE", route: "/v1/account/sessions/:*", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope; `paint` is loadSessions' repaint closure (sessions fold)" },
  { fn: "submitPasswordChange", verb: "PUT", route: "/v1/account/password", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope" },

  // ── instance lifecycle — resurrect stands up (and bills) a real box.
  { fn: "openResurrectModal", verb: "POST", route: "/v1/resurrect", elevated: true, predicate: null, auth_fn: A_USER, context_fn: C_TEAM_ADMIN, note: "UNPREDICATED. router.ex:8290 refuses non-admins inside a cond; no Auth.* names it" },

  // ── providers — THE DECISIVE PAIR. Same route, opposite verdicts.
  { fn: "submitProviderCred", verb: "POST", route: "/v1/providers", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED. The launch wizard's .launch-connect-provider button renders unconditionally" },
  { fn: "submitInlineProviderCred", verb: "POST", route: "/v1/providers", elevated: true, predicate: "providerCanWrite", auth_fn: A_TADMIN, context_fn: null, note: "renderConnectCard mounts only when providerCanWrite()" },
  { fn: "run", verb: "DELETE", route: "/v1/providers/:*", elevated: true, predicate: "providerCanWrite", auth_fn: A_TADMIN, context_fn: null, note: "wireProviderDisconnect runs only when providerCanWrite()" },

  // ── github (team-level installation)
  { fn: "disconnectGithub", verb: "DELETE", route: "/v1/github/installation", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED. #github-disconnect is wired whenever an installation exists" },

  // ── notifications — every write is wired behind notifCanManage()
  { fn: "saveNotifEmail", verb: "PUT", route: "/v1/notifications/settings", elevated: true, predicate: "notifCanManage", auth_fn: A_TADMIN, context_fn: null, note: "loadNotifications returns before wiring when !canManage" },
  { fn: "next", verb: "PUT", route: "/v1/notifications/channels", elevated: true, predicate: "notifCanManage", auth_fn: A_TADMIN, context_fn: null, note: "chat-channel save; same wiring fence" },
  { fn: "onNotifCellToggle", verb: "PUT", route: "/v1/notifications/settings", elevated: true, predicate: "notifCanManage", auth_fn: A_TADMIN, context_fn: null, note: "matrix cell → settings axis" },
  { fn: "onNotifCellToggle", verb: "PUT", route: "/v1/notifications/events", elevated: true, predicate: "notifCanManage", auth_fn: A_TADMIN, context_fn: null, note: "matrix cell → per-event axis" },
  { fn: "sendChatTest", verb: "POST", route: "/v1/notifications/test", elevated: true, predicate: "notifCanManage", auth_fn: A_TADMIN, context_fn: null, note: "per-channel test send" },
  { fn: "sendTestNotification", verb: "POST", route: "/v1/notifications/test", elevated: true, predicate: "notifCanManage", auth_fn: A_TADMIN, context_fn: null, note: "#notif-test is hidden when !canManage" },

  // ── tokens — see ruling (c). NOT elevated; the cap is on the ability set.
  { fn: "submitToken", verb: "POST", route: "/v1/tokens", elevated: false, predicate: "canMintAnyAbility", auth_fn: A_USER, context_fn: C_PAT_ABILITIES, note: "any member may mint; the owner/admin cap is on the requested abilities, below the router" },
  { fn: "confirmRevokeToken", verb: "DELETE", route: "/v1/tokens/:*", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope: revoke your own token" },

  // ── unauthenticated auth flows — no principal exists yet to elevate
  { fn: "onSubmit", verb: "POST", route: "/v1/auth/two-factor-challenge", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session; the challenge token is the credential" },
  { fn: "requestPasswordReset", verb: "POST", route: "/v1/auth/request-reset", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session" },
  { fn: "submitReset", verb: "POST", route: "/v1/auth/reset", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session" },
  { fn: "submitAuth", verb: "POST", route: "/v1/auth/login|/v1/auth/register", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session; the path is a two-way branch on authMode" },

  // ── studio / onboarding
  { fn: "openStudio", verb: "POST", route: "/v1/barkparks/:*/studio-link", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "team-scoped member action" },
  { fn: "dismissRunway", verb: "POST", route: "/v1/onboarding", elevated: true, predicate: "canManageOnboarding", auth_fn: A_PTADMIN, context_fn: null, note: "the runway renders with canManage: canManageOnboarding()" },

  // ── instance detail — the console's densest unpredicated cluster
  { fn: "runDecommission", verb: "DELETE", route: "/v1/barkparks/:*", elevated: true, predicate: null, auth_fn: A_PTADMIN, context_fn: null, note: "UNPREDICATED" },
  { fn: "retryInstance", verb: "POST", route: "/v1/barkparks/:*/retry", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED" },
  { fn: "removeInstance", verb: "DELETE", route: "/v1/barkparks/:*", elevated: true, predicate: null, auth_fn: A_PTADMIN, context_fn: null, note: "UNPREDICATED; second call site on the same route as :6750" },
  { fn: "updateInstance", verb: "POST", route: "/v1/barkparks/:*/self-update", elevated: true, predicate: null, auth_fn: A_PTADMIN, context_fn: null, note: "UNPREDICATED" },
  { fn: "rollbackInstance", verb: "POST", route: "/v1/barkparks/:*/rollback", elevated: true, predicate: "instanceAdminAuthority", auth_fn: A_PTADMIN, context_fn: null, note: "cch-w45-s5: updatePanelHtml offers [data-rollback] only on a grant; refuse/unknown render the disabled control with no mount hook" },
  { fn: "attachDomain", verb: "POST", route: "/v1/barkparks/:*/domain", elevated: true, predicate: "instanceAdminAuthority", auth_fn: A_PTADMIN, context_fn: null, note: "cch-w45-s5: instanceHeaderHtml offers #inst-domain only on a grant; refuse/unknown render the disabled control with no mount hook" },
  { fn: "submitAddSupport", verb: "POST", route: "/v1/fleet/supports", elevated: true, predicate: null, auth_fn: A_USER_OR_PAT, context_fn: C_TEAM_ADMIN, note: "UNPREDICATED. router.ex:2058 refuses non-admin sessions inside a cond" },
  { fn: "mintAppToken", verb: "POST", route: "/v1/barkparks/:*/app-token", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "team-scoped member action" },
  { fn: "patchAutoupdate", verb: "PATCH", route: "/v1/barkparks/:*/autoupdate", elevated: true, predicate: null, auth_fn: A_PTADMIN, context_fn: null, note: "UNPREDICATED" },

  // ── operator console — the console's highest-privilege writes, and both of
  // ── them build their path from a constant (ruling (b)).
  { fn: "fleetRolloutAction", verb: "POST", route: "/v1/operator/autoupdate/halt|/v1/operator/autoupdate/resume", elevated: true, predicate: "operatorRouteAllowed", auth_fn: A_OPERATOR, context_fn: null, note: "the operator route refuses to render at all unless operatorRouteAllowed(meCache)" },
  { fn: "operatorConfirmBrake", verb: "POST", route: "/v1/operator/autoupdate/halt", elevated: true, predicate: "operatorRouteAllowed", auth_fn: A_OPERATOR, context_fn: null, note: "same route fence" },

  // ── sites
  { fn: "openCreateSiteModal", verb: "POST", route: "/v1/sites", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "any member may create a site" },

  // ── webhook catalog proxy — user-authed + team-scoped, member tier
  { fn: "sendWebhookTest", verb: "POST", route: "/v1/barkparks/:*/api/webhooks/:*/test-send", elevated: false, predicate: null, auth_fn: null, context_fn: H_PROXY, note: "proxy: user-authed + team-scoped fail-closed" },
  { fn: "toggleWebhook", verb: "PUT", route: "/v1/barkparks/:*/api/webhooks/:*", elevated: false, predicate: null, auth_fn: null, context_fn: H_PROXY, note: "proxy" },
  { fn: "rotateWebhook", verb: "POST", route: "/v1/barkparks/:*/api/webhooks/:*/rotate", elevated: false, predicate: null, auth_fn: null, context_fn: H_PROXY, note: "proxy" },
  { fn: "submitEditWebhook", verb: "PUT", route: "/v1/barkparks/:*/api/webhooks/:*", elevated: false, predicate: null, auth_fn: null, context_fn: H_PROXY, note: "proxy" },
  { fn: "submitCreateWebhook", verb: "POST", route: "/v1/barkparks/:*/api/webhooks", elevated: false, predicate: null, auth_fn: null, context_fn: H_PROXY, note: "proxy" },
  { fn: "deleteWebhook", verb: "DELETE", route: "/v1/barkparks/:*/api/webhooks/:*", elevated: false, predicate: null, auth_fn: null, context_fn: H_PROXY, note: "proxy" },
  { fn: "replayDelivery", verb: "POST", route: "/v1/barkparks/:*/api/webhooks/:*/deliveries/:*/replay", elevated: false, predicate: null, auth_fn: null, context_fn: H_PROXY, note: "proxy" },

  { fn: "runVerifyNow", verb: "POST", route: "/v1/barkparks/:*/verify", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "team-scoped member action" },

  // ── site writes — ruling (a): require_ability is a no-op for a session
  { fn: "loadSite", verb: "PATCH", route: "/v1/sites/:*", elevated: false, predicate: null, auth_fn: A_ABILITY, context_fn: H_TEAM_SITE, note: "ruling (a): a session carries [\"root\"]" },
  { fn: "openSiteEnvModal", verb: "POST", route: "/v1/sites/:*/env", elevated: false, predicate: null, auth_fn: null, context_fn: H_TEAM_SITE_M, note: "team-scoped member action" },
  { fn: "runPromote", verb: "POST", route: "/v1/sites/:*/deployments/:*/promote", elevated: false, predicate: null, auth_fn: A_USER_OR_PAT + " + " + A_ABILITY, context_fn: null, note: "ruling (a): the promote/rollback pair are plain-member for a session" },
  { fn: "runSiteRollback", verb: "POST", route: "/v1/sites/:*/rollback", elevated: false, predicate: null, auth_fn: null, context_fn: H_TEAM_SITE, note: "ruling (a)" },
  { fn: "createAndDeploy", verb: "POST", route: "/v1/sites/:*/deploy", elevated: false, predicate: null, auth_fn: null, context_fn: H_TEAM_SITE, note: "ruling (a)" },
  { fn: "runDeploy", verb: "POST", route: "/v1/sites/:*/deploy", elevated: false, predicate: null, auth_fn: null, context_fn: H_TEAM_SITE, note: "ruling (a); second call site on the same route as :12059" },
  { fn: "submitSiteGithub", verb: "POST", route: "/v1/sites/:*/github/connect", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED" },
  { fn: "disconnectSiteGithub", verb: "DELETE", route: "/v1/sites/:*/github", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED" },

  { fn: "submitInviteAccept", verb: "POST", route: "/v1/invitations/accept", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "the invitation token is the authority" },
  { fn: "resumeStudioLogin", verb: "POST", route: "/v1/barkparks/:*/studio-link", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "second call site on the same route as :5544" },

  // ── launch + billing
  { fn: "submitLaunchFlow", verb: "POST", route: "/v1/launch", elevated: true, predicate: null, auth_fn: A_USER_OR_PAT, context_fn: C_TEAM_ADMIN, note: "UNPREDICATED. router.ex:8082 refuses non-admin sessions inside a cond" },
  { fn: "renderLaunchPlan", verb: "POST", route: "/v1/billing/checkout", elevated: true, predicate: "launchCheckoutAuthority", auth_fn: A_PTOWNER, context_fn: null, note: "cch-w36-s1: the plan grid draws its CTA only for an owner authority" },
  { fn: "openCancelPlanModal", verb: "POST", route: "/v1/billing/cancel", elevated: true, predicate: "billingIsOwner", auth_fn: A_PTOWNER, context_fn: null, note: "renderBilling returns read-only when !billingIsOwner()" },
  { fn: "openBillingPortal", verb: "POST", route: "/v1/billing/portal", elevated: true, predicate: "billingIsOwner", auth_fn: A_PTOWNER, context_fn: null, note: "same fence" },
  { fn: "subscribe", verb: "POST", route: "/v1/billing/checkout", elevated: true, predicate: "billingIsOwner", auth_fn: A_PTOWNER, context_fn: null, note: "same fence" },

  { fn: "mintSseTicket", verb: "POST", route: "/v1/auth/sse-ticket", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope" },
  { fn: "bootOAuth", verb: "POST", route: "/v1/auth/oauth/exchange", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session" },

  // ── the /new flow (a second, parallel console surface)
  { fn: "newSubmitAuth", verb: "POST", route: "/v1/auth/login|/v1/auth/register", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session; two-way branch on newAuthMode" },
  { fn: "newLaunch", verb: "POST", route: "/v1/launch", elevated: true, predicate: null, auth_fn: A_USER_OR_PAT, context_fn: C_TEAM_ADMIN, note: "UNPREDICATED; second call site on the same route as :13129" },
  { fn: "renderNewPricing", verb: "POST", route: "/v1/billing/checkout", elevated: true, predicate: "launchCheckoutAuthority", auth_fn: A_PTOWNER, context_fn: null, note: "cch-w36-s1: the /new plan grid draws its CTA only for an owner authority" },
  { fn: "newVercelDeploy", verb: "POST", route: "/v1/barkparks/:*/vercel-deploy", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED" },
  { fn: "newCreateRepo", verb: "POST", route: "/v1/github/repos", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED" },
  { fn: "newSubmitSiteUrl", verb: "POST", route: "/v1/barkparks/:*/site-url", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "team-scoped member action" },
  { fn: "newRenderFailed", verb: "POST", route: "/v1/barkparks/:*/retry", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED; second call site on the same route as :6776" },

  // ── team membership — every write behind assignableRoles(ctx.role)
  { fn: "submitInvite", verb: "POST", route: "/v1/teams/:*/invitations", elevated: true, predicate: "assignableRoles", auth_fn: H_TEAM_ROLE, context_fn: null, note: "canManage = assignableRoles(ctx.role).length > 0" },
  { fn: "openRoleModal", verb: "PATCH", route: "/v1/teams/:*/members/:*", elevated: true, predicate: "assignableRoles", auth_fn: H_TEAM_ROLE, context_fn: C_MEMBER_ROLE, note: "same fence; RANK-RELATIVE below it — the same admin is refused on a peer and allowed on a member" },
  { fn: "runRemoveMember", verb: "DELETE", route: "/v1/teams/:*/members/:*", elevated: true, predicate: "assignableRoles", auth_fn: H_TEAM_ROLE, context_fn: C_MEMBER_REMOVE, note: "same fence; RANK-RELATIVE below it, with an owner escape hatch the PATCH path lacks" },
  { fn: "confirmRevokeInvite", verb: "DELETE", route: "/v1/teams/:*/invitations/:*", elevated: true, predicate: "assignableRoles", auth_fn: H_TEAM_ROLE, context_fn: null, note: "same fence" },

  // ── env vars — elevated, and ONLY the inline cond says so
  { fn: "submitEnvVar", verb: "POST", route: "/v1/env-vars", elevated: true, predicate: "assignableRoles", auth_fn: A_USER, context_fn: C_TEAM_ADMIN, note: "router.ex:4302 refuses non-admins inside a cond; the form renders only when canWrite" },
  { fn: "confirmDeleteEnvVar", verb: "DELETE", route: "/v1/env-vars/:*", elevated: true, predicate: "assignableRoles", auth_fn: A_USER, context_fn: C_TEAM_ADMIN, note: "router.ex:4360; the Delete action renders only when canWrite" },

  // ── device-link activation
  { fn: "activateInspect", verb: "POST", route: "/v1/auth/device/inspect", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope: inspect your own device code" },
  { fn: "submitActivateDecision", verb: "POST", route: "/v1/auth/device/approve|/v1/auth/device/deny", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope; THE LITERAL-PREFIX TRAP — see ruling (b)" },
];

// ═══════════════════════════════════════════════════════════════════════════
// THE RESOLVERS — ruling (b). Every write whose path is not a pure
// literal/encodeURIComponent expression must be answered HERE, by its exact
// source expression, or the census exits 2 rather than guessing.
//
// Keying on the expression TEXT (not just the function) is deliberate: change
// what a helper is called with and the resolution is no longer proven, so the
// census makes you re-state it instead of inheriting a stale answer.
// ═══════════════════════════════════════════════════════════════════════════

const RESOLVERS = [
  { fn: "submitAuth", verb: "POST", expr: "path", route: "/v1/auth/login|/v1/auth/register", why: "authMode === 'login' ? '/v1/auth/login' : '/v1/auth/register'" },
  { fn: "newSubmitAuth", verb: "POST", expr: "path", route: "/v1/auth/login|/v1/auth/register", why: "newAuthMode branch, same two routes" },
  { fn: "fleetRolloutAction", verb: "POST", expr: "path", route: "/v1/operator/autoupdate/halt|/v1/operator/autoupdate/resume", why: "OPERATOR_AUTOUPDATE + (verb === 'halt' ? '/halt' : '/resume')" },
  { fn: "operatorConfirmBrake", verb: "POST", expr: 'OPERATOR_AUTOUPDATE + "/halt"', route: "/v1/operator/autoupdate/halt", why: "OPERATOR_AUTOUPDATE = '/v1/operator/autoupdate'" },
  { fn: "sendWebhookTest", verb: "POST", expr: 'whPath(bp, "/" + encodeURIComponent(wh.id) + "/test-send", ds)', route: "/v1/barkparks/:*/api/webhooks/:*/test-send", why: "whPath/3 → /v1/barkparks/<id>/api/webhooks<suffix>?dataset=" },
  { fn: "toggleWebhook", verb: "PUT", expr: 'whPath(bp, "/" + encodeURIComponent(wh.id), ds)', route: "/v1/barkparks/:*/api/webhooks/:*", why: "whPath/3" },
  { fn: "rotateWebhook", verb: "POST", expr: 'whPath(bp, "/" + encodeURIComponent(wh.id) + "/rotate", ds)', route: "/v1/barkparks/:*/api/webhooks/:*/rotate", why: "whPath/3" },
  { fn: "submitEditWebhook", verb: "PUT", expr: 'whPath(bp, "/" + encodeURIComponent(wh.id), ds)', route: "/v1/barkparks/:*/api/webhooks/:*", why: "whPath/3" },
  { fn: "submitCreateWebhook", verb: "POST", expr: 'whPath(bp, "", ds)', route: "/v1/barkparks/:*/api/webhooks", why: "whPath/3 with an empty suffix" },
  { fn: "deleteWebhook", verb: "DELETE", expr: 'whPath(bp, "/" + encodeURIComponent(wh.id), ds)', route: "/v1/barkparks/:*/api/webhooks/:*", why: "whPath/3" },
  { fn: "replayDelivery", verb: "POST", expr: 'whPath(bp, "/" + encodeURIComponent(wh.id) + "/deliveries/" + encodeURIComponent(eventId) + "/replay", ds)', route: "/v1/barkparks/:*/api/webhooks/:*/deliveries/:*/replay", why: "whPath/3" },
  { fn: "runPromote", verb: "POST", expr: "promotePath(site.id, d.id)", route: "/v1/sites/:*/deployments/:*/promote", why: "promotePath/2, both ids encodeURIComponent'd" },
  { fn: "runSiteRollback", verb: "POST", expr: "siteRollbackPath(site.id)", route: "/v1/sites/:*/rollback", why: "siteRollbackPath/1" },
  // THE TRAP. A literal PREFIX with a variable last segment. A naive extractor
  // accepts it and mis-routes to "/v1/auth/device/" — a route that does not
  // exist. It is resolved here, by name, rather than silently believed.
  { fn: "submitActivateDecision", verb: "POST", expr: '"/v1/auth/device/" + decision', route: "/v1/auth/device/approve|/v1/auth/device/deny", why: "decision is 'approve' | 'deny' (router.ex:952 / :974)" },
];

// ═══════════════════════════════════════════════════════════════════════════
// THE INLINE-COND OVERLAY (charter D421) — six router routes whose refusal of a
// non-admin lives in a `cond` clause, invisible to any `Auth.*` grep. Recorded
// here because four of the console's unpredicated elevated writes are elevated
// ONLY by these, and a census that read `Auth.*` alone would call them member.
//
// SIX, NOT SEVEN. cch-w36-s5's brief mandated "the SEVEN post-guard inline-cond
// routes"; the grep it prescribed returns SIX. The seventh site BY CONTENT is
// router.ex:4653 — `admin? = Accounts.team_admin?(user, team)` — invisible to
// that grep because it binds a local. It is EXCLUDED BY NAME, not counted: it
// is a self-scope NARROWING on a GET (the notification delivery log fences a
// member to their own rows), never a refusal. Inventing a seventh row would
// have made the overlay wrong in the other direction.
// ═══════════════════════════════════════════════════════════════════════════

// THE ROUTES ARE PINNED. THE LINE NUMBERS ARE NOT, AND NEVER AGAIN WILL BE.
// These six used to carry a typed `line:` that the census PRINTED, and all six
// were stale (drift 82, 87, 94, 98, 230, 235; router.ex at the recorded 8082 is
// now a bare `conn`). Pin-and-check was built and REFUSED: router.ex took 102
// commits in 30 days and all six of these lines moved within a SINGLE calendar
// day, so a numeral corrected at merge is wrong by the next one — and this
// census runs FIRST of three in the same CI job (console-harness.yml), so a
// drift red would convert an unrelated router insertion into a three-census
// outage. DERIVE AND PRINT; never pin and compare.
const INLINE_COND_ROUTES = [
  "POST /v1/fleet/supports",
  "DELETE /v1/fleet/supports/:id",
  "POST /v1/env-vars",
  "DELETE /v1/env-vars/:id",
  "POST /v1/launch + POST /v1/go-live (go_live/1)",
  "POST /v1/resurrect (resurrect/1)",
];
const INLINE_COND_EXCLUDED = { why: "self-scope NARROWING on GET /v1/notifications/deliveries — binds `admin?` as a local, never refuses" };

// KEY ON THE TWO PRECISE FORMS, NEVER THE BARE STRING. `grep -n 'team_admin?'
// router.ex` returns NINE hits, not eight — six refusal-form, one excluded
// local binding, and TWO DECOYS that are not call sites of this predicate at
// all. Re-derive them, do not trust a numeral: run that grep and you will find
//
//   · a DOC-COMMENT in the env-var route's `@doc`-style header, reading
//     "… Write-gated to owner/admin (Accounts.team_admin?/2)." — prose, not code
//   · `admin: Authz.team_admin?(user, team)` — a DIFFERENT MODULE's function,
//     inside a payload map, not a refusal
//
// (Their line numbers are deliberately not recorded here. This file writes down
// no line numbers at all — see the header — and two decoy numerals would be the
// first to rot, in a comment nothing can red.) A resolver keying on the bare
// string mis-splits by TWO: it reports eight refusals against six recorded
// routes and reds on prose. The two regexes below are exactly the forms check
// (2f) already counted, so deriving the lines changes nothing it tests.
const REFUSAL_FORM = /Accounts\.team_admin\?\(conn\.assigns\.current_user, conn\.assigns\.current_team\)/;
const LOCAL_FORM = /admin\?\s*=\s*Accounts\.team_admin\?\(user, team\)/;

// One entry PER OCCURRENCE (a line carrying the form twice yields it twice), so
// the derived array's LENGTH is exactly the occurrence count check (2f) tests —
// deriving the lines must not quietly change what the check counts.
function siteLines(source, re) {
  const g = new RegExp(re.source, "g");
  const out = [];
  source.split("\n").forEach((text, i) => {
    const n = (text.match(g) || []).length;
    for (let k = 0; k < n; k++) out.push(i + 1);
  });
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════
// THE EXTRACTOR
// ═══════════════════════════════════════════════════════════════════════════

// function index: name -> [start,end) by brace matching, string/comment aware.
function indexFunctions(s) {
  const out = [];
  const re = /\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
  let m;
  while ((m = re.exec(s))) {
    const open = s.indexOf("{", re.lastIndex);
    if (open < 0) continue;
    let depth = 0, i = open, inS = null, esc = false;
    for (; i < s.length; i++) {
      const c = s[i];
      if (inS) {
        if (esc) { esc = false; continue; }
        if (c === "\\") { esc = true; continue; }
        if (c === inS) inS = null;
        continue;
      }
      if (c === '"' || c === "'" || c === "`") { inS = c; continue; }
      if (c === "/" && s[i + 1] === "/") { i = s.indexOf("\n", i); if (i < 0) break; continue; }
      if (c === "/" && s[i + 1] === "*") { i = s.indexOf("*/", i) + 1; continue; }
      if (c === "{") depth++;
      else if (c === "}") { depth--; if (depth === 0) { i++; break; } }
    }
    out.push({ name: m[1], start: m.index, end: i });
  }
  return out;
}

const fns = indexFunctions(src);
const innermost = (pos) => {
  let best = null;
  for (const f of fns) if (f.start <= pos && pos < f.end) if (!best || f.start > best.start) best = f;
  return best;
};
const lineOf = (i) => src.slice(0, i).split("\n").length;

// Read the FIRST argument expression after `api("VERB",` — up to the top-level
// comma (or the closing paren for a one-argument call), tracking nesting and
// string state so a comma inside `f(a, b)` or inside a literal cannot end it.
function readPathArg(s, from) {
  let depth = 0, inS = null, esc = false;
  for (let i = from; i < s.length; i++) {
    const c = s[i];
    if (inS) {
      if (esc) { esc = false; continue; }
      if (c === "\\") { esc = true; continue; }
      if (c === inS) inS = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inS = c; continue; }
    if (c === "(" || c === "[" || c === "{") { depth++; continue; }
    if (c === ")" || c === "]" || c === "}") {
      if (depth === 0) return s.slice(from, i);
      depth--;
      continue;
    }
    if (c === "," && depth === 0) return s.slice(from, i);
  }
  return null;
}

// Split a `+`-joined expression at top level, then normalise whitespace.
function splitTerms(expr) {
  const terms = [];
  let depth = 0, inS = null, esc = false, start = 0;
  for (let i = 0; i < expr.length; i++) {
    const c = expr[i];
    if (inS) {
      if (esc) { esc = false; continue; }
      if (c === "\\") { esc = true; continue; }
      if (c === inS) inS = null;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") { inS = c; continue; }
    if (c === "(" || c === "[" || c === "{") { depth++; continue; }
    if (c === ")" || c === "]" || c === "}") { depth--; continue; }
    if (c === "+" && depth === 0) { terms.push(expr.slice(start, i)); start = i + 1; }
  }
  terms.push(expr.slice(start));
  return terms.map((t) => t.trim()).filter((t) => t.length);
}

const squash = (s) => s.replace(/\s+/g, " ").trim();

// Resolve a path expression to a route, or return null to force a RESOLVERS
// answer. ACCEPTS ONLY string literals and encodeURIComponent(...) — see (b).
function resolveLiteral(expr) {
  const terms = splitTerms(expr);
  let route = "";
  for (const t of terms) {
    const lit = t.match(/^"([^"]*)"$/) || t.match(/^'([^']*)'$/);
    if (lit) { route += lit[1]; continue; }
    if (/^encodeURIComponent\s*\(/.test(t)) { route += ":*"; continue; }
    return null;
  }
  const q = route.indexOf("?");
  return q === -1 ? route : route.slice(0, q);
}

const sites = [];
const unresolved = [];
{
  const re = /\bapi\(\s*"(POST|PUT|PATCH|DELETE)"\s*,\s*/g;
  let m;
  while ((m = re.exec(src))) {
    const verb = m[1];
    const f = innermost(m.index);
    const fn = f ? f.name : "<top>";
    const line = lineOf(m.index);
    const raw = readPathArg(src, m.index + m[0].length);
    if (raw === null) { unresolved.push({ line, fn, verb, expr: "<unparseable>" }); continue; }
    const expr = squash(raw);
    let route = resolveLiteral(expr);
    let via = "literal";
    if (route === null) {
      const r = RESOLVERS.find((x) => x.fn === fn && x.verb === verb && squash(x.expr) === expr);
      if (!r) { unresolved.push({ line, fn, verb, expr }); continue; }
      route = r.route;
      via = "resolver";
    }
    sites.push({ line, fn, verb, route, expr, via });
  }
}

const keyOf = (r) => `${r.fn}|${r.verb} ${r.route}`;

// ═══════════════════════════════════════════════════════════════════════════
// THE REPORT
// ═══════════════════════════════════════════════════════════════════════════

const pinByKey = new Map(PIN.map((r) => [keyOf(r), r]));
const seenByKey = new Map();
for (const s of sites) if (!seenByKey.has(keyOf(s))) seenByKey.set(keyOf(s), s);

const rows = sites
  .map((s) => ({ ...s, pin: pinByKey.get(keyOf(s)) || null }))
  .sort((a, b) => a.line - b.line);

// Column pad that NEVER lets a long cell fuse into its neighbour — the
// operator-autoupdate route is 60 chars and used to run straight into its tier.
const pad = (s, n) => (s.length >= n ? s + " " : s + " ".repeat(n - s.length));

console.log("file             :", LABEL);
console.log("write call sites :", sites.length, "seen,", sites.length, "RESOLVED TO A ROUTE (" +
  sites.filter((s) => s.via === "resolver").length + " via RESOLVERS, " + unresolved.length + " unresolved)");
console.log("");
console.log("  " + pad("call site", 34) + pad("verb", 7) + pad("route", 58) + pad("tier", 12) + "predicate");
console.log("  " + "-".repeat(34 + 7 + 58 + 12 + 20));
for (const r of rows) {
  const p = r.pin;
  const tier = !p ? "UNPINNED" : p.elevated ? (p.predicate ? "ELEVATED" : "ELEVATED!") : "member";
  const pred = !p ? "—" : p.predicate || (p.elevated ? "NONE — a member can click it" : "—");
  console.log("  " + pad(`${LABEL}:${r.line}`, 34) + pad(r.verb, 7) + pad(r.route, 58) + pad(tier, 12) + pred);
}

const pinnedElevated = PIN.filter((r) => r.elevated);
const pinnedPredicated = pinnedElevated.filter((r) => r.predicate);
const pinnedUnpredicated = pinnedElevated.filter((r) => !r.predicate);
const liveByKey = (r) => seenByKey.get(keyOf(r));

console.log("");
console.log(`classification   : ${PIN.length} call sites · ${pinnedElevated.length} ELEVATED above plain member · ` +
  `${pinnedPredicated.length} PREDICATED · ${pinnedUnpredicated.length} UNPREDICATED`);
console.log("                   (require_ability is NOT elevated for the console — a session carries [\"root\"];");
console.log("                    counting it would give 46, not " + pinnedElevated.length + ". See ruling (a) at the top of this file.)");
console.log("");
console.log(`THE ${pinnedUnpredicated.length} UNPREDICATED ELEVATED WRITES — an affordance a plain member can see, click, and be refused for.`);
console.log("This census does NOT fix them. Fixing them is cch-w38-bl-three-elevated-verbs-still-unpredicated,");
console.log("which is still open and still the owner — an earlier owner's text said seventeen because it was written");
console.log(`before submitProviderCred was separated from submitInlineProviderCred by call-site keying. The population it owns is these ${pinnedUnpredicated.length}.`);
for (const r of pinnedUnpredicated) {
  const live = liveByKey(r);
  console.log(`  ${pad(`${LABEL}:${live ? live.line : "gone"}`, 34)}${pad(r.verb, 7)}${pad(r.route, 58)}${r.auth_fn || r.context_fn}`);
}

// A context_fn may name more than one function (the router's refusal ARM and
// the function that actually decides it are not always the same), joined with
// " + " — the same form `auth_fn` already uses. Only the module-qualified parts
// are checkable targets; the unqualified ones (`with_team_role(conn, …)`,
// `proxy_instance_webhook/2`) are router-local labels, as they were before.
const contextParts = (name) => name.split(" + ").map((s) => s.trim());
const withContext = PIN.filter((r) => r.context_fn && contextParts(r.context_fn).some((p) => MODULE_QUALIFIED.test(p)));
console.log("");
console.log("context_fn bindings — authority that lives BELOW the router, which no auth_fn can name:");
for (const r of withContext) {
  const live = liveByKey(r);
  console.log(`  ${pad(`${LABEL}:${live ? live.line : "gone"}`, 34)}${pad(r.verb + " " + r.route, 52)}${pad(r.auth_fn || "—", 26)}→ ${r.context_fn}`);
}

// The inline-cond overlay PRINTS BELOW, behind check (2f) — see the note there.
// ═══════════════════════════════════════════════════════════════════════════
// THE CHECKS. Ordered so the most fundamental failure is reported first: an
// instrument that lost its footing (2) must never be read as a clean diff (1).
// ═══════════════════════════════════════════════════════════════════════════

const die2 = (lines) => {
  console.error("");
  for (const l of lines) console.error(l);
  process.exit(2);
};

// (2a) THE VACUITY FLOOR. Not "79 seen" — 79 RESOLVED TO A ROUTE.
if (unresolved.length) {
  die2([
    "FAIL(2): " + unresolved.length + " write call site(s) could not be RESOLVED TO A ROUTE.",
    "  A census that counted these as absent would report a clean population over a hole —",
    "  and two of the original thirteen were the operator autoupdate brake, the console's",
    "  highest-privilege writes. Add a RESOLVERS row naming the route, or refuse the site.",
    "",
    ...unresolved.map((u) => `  ${LABEL}:${u.line}  ${u.fn}  ${u.verb}  path expr: ${u.expr}`),
  ]);
}

// (2b) PIN SELF-CONSISTENCY. A pin that no longer sums to its own doctrine is a
//      pin someone edited without reading it.
// cch-w45-s5 MOVED THIS: predicated 22 → 24, unpredicated 18 → 16. The two
// member-REACHABLE elevated writes on the instance screen (attachDomain,
// rollbackInstance) are now decided at OFFER time by instanceAdminAuthority()
// — a refused caller is served a disabled control with no mount hook, so the
// call site is unreachable rather than a 403 waiting to happen. The population
// itself did not move (79 rows, 40 elevated); only where two of them sit.
const EXPECT = { total: 79, elevated: 40, predicated: 24, unpredicated: 16 };
if (PIN.length !== EXPECT.total ||
    pinnedElevated.length !== EXPECT.elevated ||
    pinnedPredicated.length !== EXPECT.predicated ||
    pinnedUnpredicated.length !== EXPECT.unpredicated) {
  die2([
    "FAIL(2): the PIN no longer sums to the population this census documents.",
    `  expected  ${EXPECT.total} rows · ${EXPECT.elevated} elevated · ${EXPECT.predicated} predicated · ${EXPECT.unpredicated} unpredicated`,
    `  found     ${PIN.length} rows · ${pinnedElevated.length} elevated · ${pinnedPredicated.length} predicated · ${pinnedUnpredicated.length} unpredicated`,
    "  If the population genuinely moved, move EXPECT in the same commit and say why in the",
    "  message — the numbers are the doctrine's receipt, not a convenience.",
  ]);
}

// (2c) DUPLICATE KEYS. Two pinned rows sharing a key would let one hide behind
//      the other, and the whole instrument rests on keys being call sites.
const dupes = [...pinByKey.keys()].length !== PIN.length
  ? PIN.map(keyOf).filter((k, i, a) => a.indexOf(k) !== i)
  : [];
if (dupes.length) {
  die2(["FAIL(2): duplicate PIN keys — a call site is hiding behind another:", ...new Set(dupes.map((d) => "  " + d))]);
}

// (2d) THE DISCRIMINATION CONTROL. The two POST /v1/providers call sites must
//      stay TWO rows with OPPOSITE verdicts. If they ever collapse to one key,
//      the census has stopped being able to see the defect it exists to see and
//      must say so rather than going green.
{
  const bare = sites.find((s) => s.fn === "submitProviderCred" && s.route === "/v1/providers");
  const gated = sites.find((s) => s.fn === "submitInlineProviderCred" && s.route === "/v1/providers");
  const bp = bare && pinByKey.get(keyOf(bare));
  const gp = gated && pinByKey.get(keyOf(gated));
  if (!bare || !gated || keyOf(bare) === keyOf(gated) || !bp || !gp || bp.predicate !== null || gp.predicate === null) {
    die2([
      "FAIL(2): the POST /v1/providers discrimination control is broken.",
      "  Both call sites must be present as TWO keys with OPPOSITE predicate verdicts:",
      `    submitProviderCred       (expect predicate null)  → ${bare ? LABEL + ":" + bare.line : "MISSING"}${bp ? " predicate=" + bp.predicate : ""}`,
      `    submitInlineProviderCred (expect a predicate)     → ${gated ? LABEL + ":" + gated.line : "MISSING"}${gp ? " predicate=" + gp.predicate : ""}`,
      "  Route-keyed, these collapse into one 'predicated' row and the one real defect on",
      "  this route becomes invisible. This control is the proof they have not collapsed.",
    ]);
  }
}

// (2e) THE context_fn TARGETS MUST EXIST. A context_fn naming a function that
//      has been renamed or deleted is exactly the class of lie this epic is for.
{
  const missing = [];
  const sourceCache = new Map();
  const readSource = (file) => {
    if (!sourceCache.has(file)) {
      sourceCache.set(file, fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null);
    }
    return sourceCache.get(file);
  };
  for (const target of new Set(withContext.flatMap((r) => contextParts(r.context_fn)))) {
    const m = MODULE_QUALIFIED.exec(target);
    if (!m) continue; // router-local label, not a module-qualified target
    const [, mod] = m;
    const file = CONTEXT_SOURCES[mod];
    if (!file) {
      missing.push("  " + target + " — module " + mod + " has no source file in CONTEXT_SOURCES");
      continue;
    }
    const source = readSource(file);
    if (source === null) {
      missing.push("  " + target + " — " + mod + " source not readable at " + file);
      continue;
    }
    const bare = m[2].replace(/\/\d+$/, "");
    if (!new RegExp("\\bdefp?\\s+" + bare.replace(/[?!]/g, "\\$&") + "\\(").test(source)) {
      missing.push("  " + target + " — no matching def/defp in " + file);
    }
  }
  if (missing.length) {
    die2([
      "FAIL(2): a context_fn binding names authority that no longer exists.",
      "  The whole reason context_fn is a first-class slot is that this authority is",
      "  invisible to the router. A dangling one is worse than none.",
      ...missing,
    ]);
  }
}

// (2f) THE INLINE-COND OVERLAY. Content-matched, not line-pinned (LIMIT 3).
{
  const router = fs.existsSync(ROUTER) ? fs.readFileSync(ROUTER, "utf8") : null;
  if (router === null) {
    die2(["FAIL(2): router.ex not readable at " + ROUTER + " — the inline-cond overlay cannot be checked."]);
  }
  const refusalLines = siteLines(router, REFUSAL_FORM);
  const localLines = siteLines(router, LOCAL_FORM);
  const refusals = refusalLines.length;
  const locals = localLines.length;
  const paired = refusals === INLINE_COND_ROUTES.length;
  if (!paired || locals !== 1) {
    die2([
      "FAIL(2): the inline-cond overlay moved.",
      `  expected ${INLINE_COND_ROUTES.length} refusal-form sites and 1 excluded local-binding site`,
      `  found    ${refusals} refusal-form and ${locals} local-binding`,
      "",
      refusals > INLINE_COND_ROUTES.length
        ? "  A router route grew an inline non-admin refusal. That is an ELEVATION no `Auth.*` grep\n" +
          "  can see — so no console predicate is likely to have followed it. Find it, decide whether\n" +
          "  the console call site in front of it is predicated, and record the row."
        : refusals < INLINE_COND_ROUTES.length
          ? "  An inline refusal disappeared. Either a route was lowered to plain member (update the\n" +
            "  affected PIN rows' elevated/context_fn) or a refusal was LOST (that is the bug)."
          : "  The excluded local-binding site changed count. It is a self-scope narrowing, not a\n" +
            "  refusal — if a second one appeared, decide which it is before touching this overlay.",
      "",
      "  Recorded overlay ROUTES (the pinned half — line numbers are never recorded here):",
      ...INLINE_COND_ROUTES.map((r) => `    ${r}`),
      "",
      // TRAP (iii): pairing derived lines to route names POSITIONALLY is only
      // meaningful when there are as many lines as names. On an ADD there are
      // more, and pairing would print 8 lines against 6 names — the gate's own
      // failure text would become a NEW false statement, which is the exact
      // defect class this instrument exists to close. Unlabeled instead.
      paired
        ? "  Derived refusal-form lines in router.ex, paired to those routes by source order:"
        : "  Derived refusal-form lines in router.ex, UNLABELED — there are " + refusals + " of them and " +
          INLINE_COND_ROUTES.length + " recorded routes,\n  so naming them positionally would mis-label every site after the change:",
      ...(paired
        ? refusalLines.map((l, i) => `    router.ex:${pad(String(l), 8)}${INLINE_COND_ROUTES[i]}`)
        : refusalLines.map((l) => `    router.ex:${l}`)),
      locals === 1
        ? `    EXCLUDED router.ex:${localLines[0]} — ${INLINE_COND_EXCLUDED.why}`
        : `    EXCLUDED local-binding form: ${locals} site(s)${locals ? " at router.ex:" + localLines.join(", router.ex:") : ""} — expected exactly 1, ${INLINE_COND_EXCLUDED.why}`,
    ]);
  }

  // THE DERIVED PRINT SITS HERE, BEHIND THE CHECK — never in front of it.
  // Reaching this line means the content-matched check already agreed that the
  // overlay is the six routes it records, so pairing line to route by source
  // order is sound. Put a drift check FIRST and a real elevation — a seventh
  // inline-cond refusal — gets reported as "line numbers are stale", which is
  // the misdiagnosis this ordering exists to prevent.
  console.log("");
  console.log("inline-cond overlay (charter D421): " + INLINE_COND_ROUTES.length + " router routes refuse non-admins inside a `cond`");
  console.log("  (every line below DERIVED from the live router.ex just now, paired by source order):");
  for (let i = 0; i < INLINE_COND_ROUTES.length; i++) {
    console.log(`  router.ex:${pad(String(refusalLines[i]), 8)}${INLINE_COND_ROUTES[i]}`);
  }
  console.log(`  EXCLUDED  router.ex:${localLines[0]} — ${INLINE_COND_EXCLUDED.why}`);
}

// (2g) EVERY PINNED PREDICATE MUST NAME A REAL DECLARATION IN app.js.
//
//      WHAT THIS IS: DECAY PROTECTION. Nothing else. `predicate` is a PINNED
//      JUDGEMENT (LIMIT 1 at the top of this file), so before this arm existed
//      a predicate could be renamed or deleted out from under its pin and the
//      census would keep printing the dead name as if it still guarded the
//      call site — mutation-proven: `zzzNotARealPredicate`, zero occurrences in
//      app.js, exited 0. This arm closes exactly that: a pin whose predicate no
//      longer resolves to a declaration is a pin that has rotted, and typos die
//      here too.
//
//      WHAT THIS IS NOT: it does NOT verify that the predicate FENCES the call
//      site, and it cannot be read as if it did. It never looks at what the
//      predicate asks. `function instanceAdminAuthority() { return true }` is
//      GREEN under this check. Both stronger variants were measured and both
//      are REFUTED, so do not "upgrade" this arm into them:
//        · span containment ("the predicate appears inside the enclosing
//          function") REDS 19 of the 22 true rows — the client predicate almost
//          always fences the RENDER/WIRE path, not the SUBMIT path; only
//          renderLaunchPlan, renderNewPricing and openRoleModal evaluate it in
//          the same function as the write.
//        · a call-graph hop walk has NO separating threshold: true rows reach at
//          0..6 hops (one UNREACHABLE at 8) while deliberately-wrong pairings
//          reach at 2..8, so threshold 4 certifies nonsense (disconnectGithub
//          "fenced" by operatorRouteAllowed). It can never work here, because
//          sendTestNotification's real fence is `testBtn.hidden = !canManage` —
//          a DOM VISIBILITY relation. This console fences by hiding elements,
//          and a call graph is blind to that by category.
{
  const declaresFn = (name) => {
    const n = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return new RegExp("\\bfunction\\s+" + n + "\\s*\\(").test(src) ||
      new RegExp("\\b(?:const|let|var)\\s+" + n +
        "\\s*=\\s*(?:async\\s+)?(?:function\\b|\\(|[A-Za-z_$][\\w$]*\\s*=>)").test(src);
  };
  const undeclared = PIN
    .filter((r) => r.predicate && !declaresFn(r.predicate))
    .map((r) => `  ${keyOf(r)} -> predicate ${r.predicate}`);
  if (undeclared.length) {
    die2([
      "FAIL(2): a pinned predicate names a function that app.js does not declare.",
      "  `predicate` is a pinned judgement, so a rename or deletion cannot reach it on its",
      "  own — the pin just keeps printing a dead name as if the affordance were still",
      "  fenced. Either restore the declaration or re-pin the row (and if the fence really",
      "  is gone, the row is now UNPREDICATED and EXPECT moves with it).",
      "",
      ...undeclared,
    ]);
  }
}

// ── (1) THE SET DIFF. ADD and REMOVE. Never a count. ────────────────────────
const liveKeys = [...seenByKey.keys()];
const pinKeys = [...pinByKey.keys()];
const arrivals = liveKeys.filter((k) => !pinByKey.has(k));
const departures = pinKeys.filter((k) => !seenByKey.has(k));

if (arrivals.length || departures.length) {
  console.error("");
  console.error("FAIL(1): the console's write call-site set does not match the pin.");
  console.error("");
  for (const k of arrivals) {
    const s = seenByKey.get(k);
    console.error(`  ADDED     ${LABEL}:${s.line}  ${s.verb} ${s.route}  (in ${s.fn})`);
    console.error("            A write affordance nothing predicts. If the route is above plain team");
    console.error("            membership, a member will see this button and be refused — put a client");
    console.error("            predicate in front of it. Then pin the row, with its tier and predicate.");
  }
  for (const k of departures) {
    const r = pinByKey.get(k);
    // No line number here, and that is not an omission: the site is GONE from
    // the live file, so there is nothing to derive it from. `${r.fn}` is the
    // key's own half and stays true. Printing a remembered line would be the
    // one number in this report that no live file backs.
    console.error(`  REMOVED   ${r.verb} ${r.route}  (in ${r.fn}, no longer present in ${LABEL})`);
    console.error("            Its PIN row now describes a tree that no longer exists. Delete the row in");
    console.error("            the same commit that removed the call site, so the pin stays a description.");
  }
  console.error("");
  console.error(`  pinned (${pinKeys.length}) · live (${liveKeys.length})`);
  console.error("  NOTE: the population SIZE is not the gate. A commit that predicates one affordance and");
  console.error("  ships another unpredicated keeps it identical — which is why this is a SET DIFF (D383).");
  process.exit(1);
}

console.log("");
console.log(`OK: all ${sites.length} console write call sites resolve to a route and match the ${PIN.length}-row pin.`);
console.log(`    ${pinnedElevated.length} are elevated above plain member; ${pinnedUnpredicated.length} of those are still unpredicated (owned, not fixed here).`);
process.exit(0);
