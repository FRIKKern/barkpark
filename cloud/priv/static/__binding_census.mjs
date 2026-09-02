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
//                                 `.launch-connect-provider` button, drawn by
//                                 catalogPanelHtml. NO PREDICATE OF ITS OWN —
//                                 and note the correction (cch-w48-s4): this
//                                 file used to say the button "renders
//                                 unconditionally", naming a `renderLaunchConnect`
//                                 that app.js does not declare at all. What is
//                                 true on main is narrower and does NOT make the
//                                 row predicated: the button only exists inside
//                                 the launch wizard, and launchFlow withholds
//                                 that whole form unless launchAuthority() ===
//                                 "grant" — a fence in a DIFFERENT band, three
//                                 hops away, guarding a different route. See the
//                                 row's own note.
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
//   printed numeral is only ever this run's reading of the tree. cch-w47-rv
//   made that sentence a CHECK rather than a promise: (2h) below reads this
//   file's own bytes and exits 2 on any typed `<file>:<digits>`. It had to —
//   D528 left seven of them behind in `note:` prose, all seven already stale.)
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
//     fence,                               // {band, read, decide} — or absent
//     auth_fn,                             // the router's Auth.* guard, or null
//     context_fn,                          // authority BELOW the router, or null
//     note }
//
// `fence` is the arm-(2i) triple, and it is what makes a row's PREDICATE claim
// losable instead of decorative (charter D540):
//
//   band   — the authority function whose answer decides the offer. Equal to
//            `predicate`; it is spelled again here because the accounting in
//            (2i-4) is keyed BY BAND, and a band with no fence row is simply
//            outside this arm rather than silently half-checked.
//   read   — the function (or functions) that CALL the band and thread its
//            answer to the render path. This console splits read from decision
//            on purpose (charter D530), so read is almost never the pinned `fn`.
//   decide — the function that turns the threaded answer into a rendered offer
//            or a withheld one. This is where the fence can be NEUTERED.
//
// A row with no `fence` is UNCHECKED BY (2i) and says so in the print. That is
// a hole, not a pass.
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
//   NARROWED, NOT LIFTED, by arm (2i) (charter D540): for a row that pins a
//   `fence`, removing the predicate around the call site IS now reachable —
//   deleting the band read, neutering the decision, or dropping the fence pin
//   itself each exit 2. The narrowing is exactly as wide as the fence pins go,
//   and today that is ONE BAND. Every other predicated row is still LIMIT 1.
//
//   LIMIT 1b — (2i-4)'s ACCOUNTING IS OVER READ SITES, NOT OVER ROWS. It walks
//   the band's live call sites and demands each enclosing function be claimed
//   by some row's `read`. Several rows legitimately share one read: on the
//   instance screen, loadInstance's single band read feeds the header, the
//   updates panel and the support card alike. So a row whose read is ALREADY
//   claimed by a sibling row is NOT auto-discovered by this arm — patchAutoupdate
//   and submitAddSupport were both found by hand, and dropping either row's
//   fence leaves the accounting green because rollbackInstance/attachDomain
//   still claim loadInstance. (2i) is ANTI-DECAY BOOKKEEPING WITH DERIVED
//   TEETH. It is not a discovery instrument, and reading it as one would put a
//   fresh false claim inside the arm that exists to remove them.
//
//   LIMIT 2 — THE EXTRACTOR MATCHES `api("VERB", …)` LITERALLY. A write issued
//   through a wrapper, or with the method in a variable, is invisible to it.
//   This raises the COST of the mistake; it does not make it impossible. A
//   ratchet, not a proof of absence.
//
//   LIMIT 3 — THE INLINE-COND OVERLAY IS CONTENT-MATCHED, NOT LINE-PINNED.
//   Eight router routes refuse non-admins inside a `cond` rather than through an
//   `Auth.*` guard, so they are invisible to any guard grep. They are checked
//   by counting the exact `Accounts.team_admin?(conn.assigns.current_user,
//   conn.assigns.current_team)` form, so the check survives line drift — but it
//   cannot tell WHICH route grew a ninth. It tells you to go look.
//
//   The overlay also PRINTS a `router.ex:NNNN` per route, and those numbers
//   are DERIVED by the same two regexes at run time — nothing compares them to
//   anything, so they cannot red and cannot go stale. What IS pinned is the six
//   ROUTE NAMES, and the print pairs name to line BY SOURCE ORDER. So the one
//   thing this print can still get wrong is a router that REORDERS these eight
//   while keeping the count at eight: the lines stay right and the names slide.
//   On any count change the pairing is dropped and the derived lines print
//   UNLABELED, because a mis-labelled failure message is a new false statement
//   of exactly the kind this census exists to remove.
//
// Exit codes:
//   0 — the derived call-site set EQUALS the pin, and every invariant holds
//   1 — ADD and/or REMOVE: the set differs from the pin, both named
//       (in a fixture mode: the declared arms fired, exactly as declared)
//   2 — the instrument lost its footing: an unresolved path, a broken
//       discrimination control, a pin that no longer sums, a vanished
//       context_fn target, a changed inline-cond overlay — or a fixture whose
//       observations do not match what it declares about itself
//   3 — THE RATCHET (2j): a pin row is ELEVATED and UNPREDICATED and its key is
//       not on LEGACY_UNPREDICATED. Its own code, not 1 and not 2, and the
//       distinction is the point: nothing ARRIVED unpinned (that is 1) and
//       nothing ROTTED (that is 2). Someone wrote down, in the pin, that the
//       console grew one more affordance a plain member can see, click, and be
//       refused for. See THE RATCHET below for what it can and cannot do.
//
// Run: node cloud/priv/static/__binding_census.mjs
//      node cloud/priv/static/__binding_census.mjs <app.js> <router.ex> <accounts.ex> <authz.ex>
//   (the argv overrides exist so a mutation driver can point the census at a
//    patched COPY without writing inside this slice's fence)
//
//      node cloud/priv/static/__binding_census.mjs --add-check     <fixture.js>
//      node cloud/priv/static/__binding_census.mjs --remove-check  <fixture.js>
//      node cloud/priv/static/__binding_census.mjs --ratchet-check <fixture.js>
//   THE FIXTURE CONTROL (charter D452) — the committed proof that the arm which
//   actually GATES can lose. All three exit 1 when the fixture's declared arms
//   fire. See THE FIXTURE CONTROL below for why it is a fixture and not a mutant
//   of the live tree, and why its expectations live in the fixture files.

import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
// ── THE FIXTURE MODE FLAG IS RESOLVED HERE, AT THE `APP` BINDING ────────────
// Not downstream, and this placement is load-bearing rather than tidy. `src` is
// read at module scope, a few lines below, from whatever `APP` says — so a mode
// block placed after that read never runs: `--add-check` IS argv[2], and the
// process dies first with `ENOENT: no such file or directory, open
// '--add-check'`. __css_check.mjs's targeted modes sit far down its file and do
// not hit this, because each of them reads its own subject INSIDE the mode
// block; this census reads its subject once, at the top, for everything.
const FIXTURE_FLAGS = ["--add-check", "--remove-check", "--ratchet-check"];
const fixtureFlagAt = process.argv.findIndex((a) => FIXTURE_FLAGS.includes(a));
const FIXTURE_MODE = fixtureFlagAt === -1 ? null : process.argv[fixtureFlagAt];
const FIXTURE_FILE = FIXTURE_MODE ? process.argv[fixtureFlagAt + 1] : null;
if (FIXTURE_MODE && !FIXTURE_FILE) {
  console.error(`FAIL(2): ${FIXTURE_MODE} needs a fixture file argument.`);
  console.error("  e.g. node cloud/priv/static/__binding_census.mjs --add-check cloud/priv/static/__binding_census.add.fixture.js");
  process.exit(2);
}

const APP = FIXTURE_FILE || process.argv[2] || path.join(here, "app.js");
// In a fixture mode argv[3..5] are the flag's own operands, never the Elixir
// sources — bind the defaults so a stray path cannot be silently read. The
// four-source contract (app.js, router.ex, accounts.ex, authz.ex) is main's;
// the fixture mode only overrides which JS subject is walked.
const ROUTER = (FIXTURE_MODE ? null : process.argv[3]) || path.join(here, "../../lib/barkpark_cloud/web/router.ex");
const ACCOUNTS = (FIXTURE_MODE ? null : process.argv[4]) || path.join(here, "../../lib/barkpark_cloud/accounts.ex");
const AUTHZ = (FIXTURE_MODE ? null : process.argv[5]) || path.join(here, "../../lib/barkpark_cloud/accounts/authz.ex");
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
const LABEL = APP === path.join(here, "app.js") ? "cloud/priv/static/app.js" : APP;

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

// THE INSTANCE-ADMIN BAND's fence constructor. `read` may be one function or
// several: the lifecycle rail is offered by wireLifecycleActions and re-offered
// by repaintLifecycleAuthority, and both genuinely re-read the band for the
// SAME affordance. Listing both is honest bookkeeping; listing only one would
// leave the other an orphan that (2i-4) then has to be told to ignore, and an
// exemption is a hole where a claim would have been true.
const INSTANCE_BAND = "instanceAdminAuthority";
const F_INST = (read, decide) => ({ band: INSTANCE_BAND, read: read, decide: decide });

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
  { fn: "openResurrectModal", verb: "POST", route: "/v1/resurrect", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadArchives", "archiveRowHtml"), auth_fn: A_USER, context_fn: C_TEAM_ADMIN, note: "cch-w48-s4 re-pin: loadArchives reads the band and threads it into archivesModel; archiveRowHtml emits .archive-resurrect-btn ONLY on a grant — refuse/unknown draw the CLI chip alone, with no button to mount. Was pinned UNPREDICATED, which stopped being true when the offer-time answer shipped. resurrect/1 still refuses non-admins inside a cond, so the context_fn and the overlay stay" },

  // ── providers — THE DECISIVE PAIR. Same route, opposite verdicts.
  { fn: "submitProviderCred", verb: "POST", route: "/v1/providers", elevated: true, predicate: null, auth_fn: A_TADMIN, context_fn: null, note: "UNPREDICATED — but NOT for the reason this row used to give. The old note said the .launch-connect-provider button 'renders unconditionally' and credited a renderLaunchConnect that app.js does not declare; both halves were false (cch-w48-s4). What is true: catalogPanelHtml draws the button, and it is only ever reached inside the launch wizard, which launchFlow withholds unless launchAuthority() === 'grant'. That fence is THREE HOPS away, belongs to the LAUNCH band, and guards POST /v1/launch — not this row's POST /v1/providers, whose own tier is require_team_admin. A predicate this row does not evaluate is not this row's predicate, so it stays null and stays owned" },
  { fn: "submitInlineProviderCred", verb: "POST", route: "/v1/providers", elevated: true, predicate: "providerCanWrite", auth_fn: A_TADMIN, context_fn: null, note: "renderConnectCard mounts only when providerCanWrite()" },
  { fn: "run", verb: "DELETE", route: "/v1/providers/:*", elevated: true, predicate: "providerCanWrite", auth_fn: A_TADMIN, context_fn: null, note: "wireProviderDisconnect runs only when providerCanWrite()" },

  // ── github (team-level installation)
  // cch-w48-s3, re-pinned here in review: the old note ("wired whenever an
  // installation exists") stopped being true the moment s3 landed —
  // githubCardHtml(g, canWrite) emits #github-disconnect only when
  // providerCanWrite() is true, and OMITS it otherwise. NOT fence-pinned:
  // providerCanWrite is a boolean, not a three-valued band, so (2i-3)'s
  // vocabulary derivation has nothing to read. LIMIT 1, and honest about it.
  { fn: "disconnectGithub", verb: "DELETE", route: "/v1/github/installation", elevated: true, predicate: "providerCanWrite", auth_fn: A_TADMIN, context_fn: null, note: "cch-w48-s3: githubCardHtml OMITs #github-disconnect unless providerCanWrite()" },

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
  { fn: "runDecommission", verb: "DELETE", route: "/v1/barkparks/:*", elevated: true, predicate: INSTANCE_BAND, fence: F_INST(["wireLifecycleActions", "repaintLifecycleAuthority"], "decommissionAction"), auth_fn: A_PTADMIN, context_fn: null, note: "cch-w48-s4 re-pin: decommissionAction answers mode:\"disabled\" for refuse and for unknown, and the rail emits data-life-verb only on the live arm — the same disabled-ghost shape rows rollbackInstance/attachDomain are already pinned on (D428). Read twice, on purpose: the rail is mounted by wireLifecycleActions and re-offered by repaintLifecycleAuthority when /v1/me answers late" },
  { fn: "retryInstance", verb: "POST", route: "/v1/barkparks/:*/retry", elevated: true, predicate: INSTANCE_BAND, fence: F_INST(["loadInstance", "mountInstanceTimeline", "runVerifyNow"], "adminWriteControlHtml"), auth_fn: A_TADMIN, context_fn: null, note: "cch-w38-s1 (criterion 3): TWO offer sites, both now drawn by adminWriteControlHtml — the timeline's docked [data-tl-retry] and the verify note's [data-vf-reprovision] — so the mount hook is withheld on refuse and on unknown. Read THREE times because the two sites have three entries: instanceOverviewHtml threads loadInstance's answer, the SSE repaint lands in mountInstanceTimeline, and the no_admin_token note is painted from runVerifyNow" },
  { fn: "removeInstance", verb: "DELETE", route: "/v1/barkparks/:*", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadInstance", "adminWriteControlHtml"), auth_fn: A_PTADMIN, context_fn: null, note: "cch-w38-s1 (criterion 3): instanceHeaderHtml's removal-failed arm offers #inst-remove-retry only on a grant; refuse/unknown render the disabled control with no mount hook. Second call site on the same route as runDecommission's, and now fenced on the same band" },
  { fn: "updateInstance", verb: "POST", route: "/v1/barkparks/:*/self-update", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadInstance", "adminWriteControlHtml"), auth_fn: A_PTADMIN, context_fn: null, note: "cch-w38-s1 (criterion 3): instanceHeaderHtml offers the behind-box CTA #inst-update only on a grant. The modal buttons behind it (#update-go, #update-force) are POST-offer and stay unfenced by design — the same shape as rollbackInstance's confirm" },
  { fn: "rollbackInstance", verb: "POST", route: "/v1/barkparks/:*/rollback", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadInstance", "adminWriteControlHtml"), auth_fn: A_PTADMIN, context_fn: null, note: "cch-w45-s5: updatePanelHtml offers [data-rollback] only on a grant; refuse/unknown render the disabled control with no mount hook. cch-w48-s4 names the DECIDING function rather than the panel that hosts it: updatePanelHtml threads the answer through unchanged, and adminWriteControlHtml is where the data-rollback hook is withheld" },
  { fn: "attachDomain", verb: "POST", route: "/v1/barkparks/:*/domain", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadInstance", "adminWriteControlHtml"), auth_fn: A_PTADMIN, context_fn: null, note: "cch-w45-s5: instanceHeaderHtml offers #inst-domain only on a grant; refuse/unknown render the disabled control with no mount hook — again by way of adminWriteControlHtml, which is the function that actually decides" },
  { fn: "submitAddSupport", verb: "POST", route: "/v1/fleet/supports", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadInstance", "fleetSupportCardHtml"), auth_fn: A_USER_OR_PAT, context_fn: C_TEAM_ADMIN, note: "cch-w48-s4 re-pin: fleetSupportCardHtml OMITS #fleet-add-support unless authority === \"grant\" (D514 rules this add OMITTED rather than disabled-and-explained). Found BY HAND, not by (2i-4): its read is loadInstance, which sibling rows already claim — see LIMIT 1b. POST /v1/fleet/supports still refuses non-admin sessions inside a cond, so the overlay stays" },
  { fn: "submitAgentKey", verb: "POST", route: "/v1/barkparks/:*/agent-key", elevated: true, predicate: null, auth_fn: A_USER_OR_PAT, context_fn: C_TEAM_ADMIN, note: "UNPREDICATED (PDF-D94, pdf-bl-console-key-custody): supportRowHtml renders the paste-a-key form + Deliver button on EVERY live support row — no authority threads into it, so a plain member sees the affordance and the route's inline cond refuses them with Auth.forbidden(required: admin, scope: team) (same disjunction as POST /v1/fleet/supports: PAT needs deploy, session needs team-admin). The instanceAdminAuthority band is already read one hop up (fleetSupportCardHtml takes `authority` for the ADD button) so the fence is one thread away — needs a row of its own; recording the truth here, not fixing it" },
  { fn: "mintAppToken", verb: "POST", route: "/v1/barkparks/:*/app-token", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "team-scoped member action" },
  { fn: "patchAutoupdate", verb: "PATCH", route: "/v1/barkparks/:*/autoupdate", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadInstance", "adminWriteControlHtml"), auth_fn: A_PTADMIN, context_fn: null, note: "cch-w48-s4 re-pin: all four autoupdate controls (pause/resume/pin/unpin) are drawn by adminWriteControlHtml, which emits the data-au hook only when the answer is neither refuse nor unknown. Found BY HAND, not by (2i-4) — same shared read as rollbackInstance, see LIMIT 1b" },

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
  { fn: "runSiteDelete", verb: "DELETE", route: "/v1/sites/:*", elevated: false, predicate: null, auth_fn: null, context_fn: H_TEAM_SITE, note: "cch-w67 crown: the console's FIRST caller of DELETE /v1/sites/:id. NOT elevated, and the judgement is re-derivable rather than inherited: the route is with_team_site(conn, {:ability,\"write\"}), a browser session is assigned [\"root\"], and Registry.get_team_site filters on TENANCY only — no role read exists anywhere on the path. The INSTANCE Decommission on the same screen family is require_primary_team_admin, a strictly higher tier; predicating this row on that band would withhold a control the server honours" },
  { fn: "createAndDeploy", verb: "POST", route: "/v1/sites/:*/deploy", elevated: false, predicate: null, auth_fn: null, context_fn: H_TEAM_SITE, note: "ruling (a)" },
  { fn: "runDeploy", verb: "POST", route: "/v1/sites/:*/deploy", elevated: false, predicate: null, auth_fn: null, context_fn: H_TEAM_SITE, note: "ruling (a); second call site on the same route as :12059" },
  // cch-w48-s2, pinned here in review: BOTH of these routes are reached ONLY
  // through #site-github, and siteDetailHtml now emits that control only on the
  // literal "grant". The fence is pinned rather than merely noted because arm
  // (2i-4) below FOUND it — loadSite's new instanceAdminAuthority() read was an
  // orphan the moment s2 landed, which is precisely the FIX direction (2g) was
  // blind to. MERGE ORDER: this pin requires cch-w48-s2 in the tree first.
  { fn: "submitSiteGithub", verb: "POST", route: "/v1/sites/:*/github/connect", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadSite", "siteDetailHtml"), auth_fn: A_TADMIN, context_fn: null, note: "cch-w48-s2: #site-github is emitted only on \"grant\"; a member gets a non-interactive chip (connected) or nothing (unconnected)" },
  { fn: "disconnectSiteGithub", verb: "DELETE", route: "/v1/sites/:*/github", elevated: true, predicate: INSTANCE_BAND, fence: F_INST("loadSite", "siteDetailHtml"), auth_fn: A_TADMIN, context_fn: null, note: "cch-w48-s2: same door, same fence — disconnect is reached only from the connected arm of #site-github" },

  { fn: "submitInviteAccept", verb: "POST", route: "/v1/invitations/accept", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "the invitation token is the authority" },
  { fn: "resumeStudioLogin", verb: "POST", route: "/v1/barkparks/:*/studio-link", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "second call site on the same route as :5544" },

  // ── launch + billing
  { fn: "submitLaunchFlow", verb: "POST", route: "/v1/launch", elevated: true, predicate: "launchAuthority", auth_fn: A_USER_OR_PAT, context_fn: C_TEAM_ADMIN, note: "cch-w47-s1, re-pinned cch-w48-s4: launchFlow withholds the WHOLE form unless launchAuthority() === \"grant\" — fail-closed on loading and on failed, so there is no submit to reach. NO `fence` PIN: arm (2i) is scoped to the instanceAdminAuthority band this wave, and pinning the launch band without doing its read accounting would be a claim this file cannot back. go_live/1 still refuses non-admin sessions inside a cond, so the overlay stays" },
  { fn: "renderLaunchPlan", verb: "POST", route: "/v1/billing/checkout", elevated: true, predicate: "launchCheckoutAuthority", auth_fn: A_PTOWNER, context_fn: null, note: "cch-w36-s1: the plan grid draws its CTA only for an owner authority" },
  { fn: "openCancelPlanModal", verb: "POST", route: "/v1/billing/cancel", elevated: true, predicate: "billingIsOwner", auth_fn: A_PTOWNER, context_fn: null, note: "renderBilling returns read-only when !billingIsOwner()" },
  { fn: "openBillingPortal", verb: "POST", route: "/v1/billing/portal", elevated: true, predicate: "billingIsOwner", auth_fn: A_PTOWNER, context_fn: null, note: "same fence" },
  { fn: "subscribe", verb: "POST", route: "/v1/billing/checkout", elevated: true, predicate: "billingIsOwner", auth_fn: A_PTOWNER, context_fn: null, note: "same fence" },

  { fn: "mintSseTicket", verb: "POST", route: "/v1/auth/sse-ticket", elevated: false, predicate: null, auth_fn: A_USER, context_fn: null, note: "self-scope" },
  { fn: "bootOAuth", verb: "POST", route: "/v1/auth/oauth/exchange", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session" },

  // ── the /new flow (a second, parallel console surface)
  { fn: "newSubmitAuth", verb: "POST", route: "/v1/auth/login|/v1/auth/register", elevated: false, predicate: null, auth_fn: null, context_fn: null, note: "pre-session; two-way branch on newAuthMode" },
  // cch-w48-s1, re-pinned here in review. This row was DELIBERATELY left
  // unflipped when s4 was written — /new had its own renderer and it never
  // called launchAuthority(). s1 changed exactly that: renderNewLaunch now
  // takes launchAuthority()'s band through newLaunchOffer, which emits
  // #new-launch-btn only on "grant". NOT fence-pinned: the launch band's read
  // accounting is not done (cch-w48-bl-fence-pins-for-the-other-eight-bands).
  { fn: "newLaunch", verb: "POST", route: "/v1/launch", elevated: true, predicate: "launchAuthority", auth_fn: A_USER_OR_PAT, context_fn: C_TEAM_ADMIN, note: "cch-w48-s1: newLaunchOffer emits #new-launch-btn only on \"grant\"; refuse omits it, unknown withholds it and renders the one exit" },
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
  { fn: "submitEnvVar", verb: "POST", route: "/v1/env-vars", elevated: true, predicate: "assignableRoles", auth_fn: A_USER, context_fn: C_TEAM_ADMIN, note: "POST /v1/env-vars refuses non-admins inside a cond; the form renders only when canWrite" },
  { fn: "confirmDeleteEnvVar", verb: "DELETE", route: "/v1/env-vars/:*", elevated: true, predicate: "assignableRoles", auth_fn: A_USER, context_fn: C_TEAM_ADMIN, note: "DELETE /v1/env-vars/:id, same inline cond; the Delete action renders only when canWrite" },

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
  { fn: "submitActivateDecision", verb: "POST", expr: '"/v1/auth/device/" + decision', route: "/v1/auth/device/approve|/v1/auth/device/deny", why: "decision is 'approve' | 'deny' — both routes exist: grep -n 'post \"/v1/auth/device/' router.ex" },
];

// ═══════════════════════════════════════════════════════════════════════════
// THE INLINE-COND OVERLAY (charter D421) — eight router routes whose refusal of a
// non-admin lives in a `cond` clause, invisible to any `Auth.*` grep. Recorded
// here because four of the console's unpredicated elevated writes are elevated
// ONLY by these, and a census that read `Auth.*` alone would call them member.
//
// SIX, NOT SEVEN. cch-w36-s5's brief mandated "the SEVEN post-guard inline-cond
// routes"; the grep it prescribed returns SIX. The seventh site BY CONTENT is
// the one reading `admin? = Accounts.team_admin?(user, team)` — invisible to
// that grep because it binds a local; its line is DERIVED and printed as the
// overlay's EXCLUDED row, never written down here. It is EXCLUDED BY NAME, not counted: it
// is a self-scope NARROWING on a GET (the notification delivery log fences a
// member to their own rows), never a refusal. Inventing a seventh row would
// have made the overlay wrong in the other direction.
//
// EIGHT SINCE PDF-D94 (pdf-bl-console-key-custody): the agent-key POST and its
// status-poll GET both refuse non-admin sessions inside the same cond shape as
// POST /v1/fleet/supports (the read narrates a write only admins can make, so
// it carries the same disjunction). Recorded the day they landed, in the same
// commit as the routes.
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
  "POST /v1/barkparks/:id/agent-key",
  "GET /v1/barkparks/:id/agent-key (status poll — same cond, admin-narrated read)",
  "POST /v1/env-vars",
  "DELETE /v1/env-vars/:id",
  "POST /v1/launch + POST /v1/go-live (go_live/1)",
  "POST /v1/resurrect (resurrect/1)",
];
const INLINE_COND_EXCLUDED = { why: "self-scope NARROWING on GET /v1/notifications/deliveries — binds `admin?` as a local, never refuses" };

// KEY ON THE TWO PRECISE FORMS, NEVER THE BARE STRING. `grep -n 'team_admin?'
// router.ex` returns MORE hits than the eight refusal-form sites and the one
// excluded local binding — the rest are DECOYS that are not call sites of this
// predicate at all. Re-derive them, do not trust a numeral: run that grep and
// you will find, among others,
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

// The rule check (2d-ii) enforces, named here because THE FIXTURE CONTROL below
// must exercise the very same function the live check runs. A control that
// re-implements the rule it is proving has proven its own copy and nothing else.
const verdictContrastLost = (pair) => pair.length > 1 && pair.every((r) => r.predicate === null);

// THE RATCHET'S RULE, named here for the same reason: the fixture control below
// and the live arm (2j) far down this file both call THIS function. A control
// that re-implements the rule it is proving has proven its own copy.
//
// `!r.predicate` rather than `r.predicate === null` on purpose — it is the
// identical test the classification summary uses for its UNPREDICATED count, and
// arm (2j) asserts the two agree. A row pinned `predicate: ""` must not be
// unpredicated to one and predicated to the other.
const isUnboundElevated = (r) => r.elevated === true && !r.predicate;

// Given a pin and a CEILING (a list of keys), split the pin three ways. `novel`
// is the only failing outcome; `healed` is the ceiling LOWERING, which is always
// green, and is what stops this arm becoming a guard that stays green only while
// the disease stays untreated (charter D452).
const ratchetVerdict = (pinRows, ceilingKeys) => {
  const ceiling = new Set(ceilingKeys);
  const byKey = new Map(pinRows.map((r) => [keyOf(r), r]));
  const novel = pinRows.filter((r) => isUnboundElevated(r) && !ceiling.has(keyOf(r))).map(keyOf);
  const healed = [];
  const held = [];
  for (const k of ceiling) {
    const r = byKey.get(k);
    if (!r) healed.push({ key: k, why: "the pin row is GONE — the call site was deleted" });
    else if (!r.elevated) healed.push({ key: k, why: "re-pinned BELOW plain-member elevation" });
    else if (r.predicate) healed.push({ key: k, why: `now PREDICATED on ${r.predicate}` });
    else held.push(k);
  }
  return { novel, healed, held };
};

// ═══════════════════════════════════════════════════════════════════════════
// THE FIXTURE CONTROL (charter D452) — `--add-check` / `--remove-check`.
//
// WHY IT EXISTS. (2d) below proves the census can SEE the decisive pair. It has
// never proven the arm that actually GATES can lose. The gate is the ADD/REMOVE
// set diff at the bottom of this file, and until this block landed there was no
// fixture, no self-test and no mutant showing either arm fire. A gate never
// observed losing is a gate being trusted, not one that has been measured.
//
// WHY IT SHORT-CIRCUITS HERE — after `seenByKey`, before every check below. A
// fixture is not app.js, and the checks are statements ABOUT app.js: (2b)'s
// EXPECT {79, 40, …} is nonsense against four hundred bytes of fixture, and
// (2e)/(2f) read Elixir the fixture has nothing to do with. Measured before this
// block existed: handing a fixture to the bare census resolves cleanly through
// (2a) and then dies at (2d) with `submitProviderCred → MISSING` — a red that
// says nothing about the fixture. Everything above this line — the extractor,
// `resolveLiteral`, RESOLVERS, `keyOf`, `seenByKey` — is the REAL machinery,
// unmodified, so the fixture is measured by the instrument, not beside it.
//
// THE FIXTURES DECLARE THEIR OWN EXPECTATIONS. `@must-flag <ARM> <key>` and
// `@must-clear <ARM> <key>` directives are read out of the fixture's own source
// text, so what a fixture is FOR lives in the bytes it is made of instead of in
// a table here that can drift away from them. The observed set must EQUAL the
// declared must-flag set: a control that fires for a reason other than the one
// it claims is not a control, so an unexplained observation exits 2 exactly
// like a missing one. And every must-clear key must be REAL — present in both
// the fixture's derived sites and FIXTURE_PIN — because a negative control
// naming a key that does not exist is the vacuous green this epic removes.
//
// ONE MODE RUNS ONE ARM, so the two fixtures CROSS-CHECK: the add fixture under
// `--remove-check` and the remove fixture under `--add-check` must both exit 0.
// That 2x2 is what separates "the control can shout" from "the control can tell
// things apart" — a mode that ran every arm would fire on either fixture and the
// pair would prove nothing about which arm saw what. console-harness.yml runs
// all four cells for exactly that reason.
//
// VERDICT-COLLAPSE RIDES `--add-check`, and the asymmetry is deliberate, not an
// oversight. That arm is PIN-side: it needs a `@pin-override` to drive it, so it
// needs exactly one driving fixture, and the fixture that drives it can no
// longer be silent under any mode that evaluates it. Parking it on one flag
// keeps the 2x2 above intact. Its silent side is not lost — the remove fixture
// declares `@must-clear VERDICT-COLLAPSE`, evaluated in the cross cell.
// ═══════════════════════════════════════════════════════════════════════════

if (FIXTURE_MODE) {
  // A pin small enough to read in one glance. It is NOT the real PIN and never
  // shares a row with it: this block is proving the ARMS, and a control keyed to
  // the live population would go stale on every honest console change — the
  // failure mode of cch-w38-bl, whose control needed a real defect to stay
  // unfixed forever. `fixtureBareProvider`/`fixtureGatedProvider` mirror the
  // POST /v1/providers pair's SHAPE (one route, two call sites, opposite
  // verdicts) so the verdict-contrast arm has something to lose on.
  //
  // `elevated` is carried here ONLY because the RATCHET arm reads it; no other
  // arm does, so these six flags cannot change what ADD, REMOVE or
  // VERDICT-COLLAPSE observe. Two rows are deliberately elevated-and-unbound —
  // `fixtureBareProvider` and `fixtureDepartedWrite` — because a ceiling with
  // nothing under it cannot be lowered, and the ratchet fixture's HEALED row
  // needs a legacy entry to heal.
  const FIXTURE_PIN = [
    { fn: "fixtureSelfWrite", verb: "POST", route: "/v1/fixture/self", elevated: false, predicate: null },
    { fn: "fixtureTeamWrite", verb: "DELETE", route: "/v1/fixture/team/:*", elevated: true, predicate: "fixtureCanManage" },
    { fn: "fixtureBareProvider", verb: "POST", route: "/v1/fixture/providers", elevated: true, predicate: null },
    { fn: "fixtureGatedProvider", verb: "POST", route: "/v1/fixture/providers", elevated: true, predicate: "fixtureCanWrite" },
    { fn: "fixtureDepartedWrite", verb: "POST", route: "/v1/fixture/departed", elevated: true, predicate: null },
    { fn: "fixtureDepartedTeam", verb: "DELETE", route: "/v1/fixture/departed/:*", elevated: true, predicate: "fixtureCanManage" },
  ];
  const ARMS = ["ADD", "REMOVE", "VERDICT-COLLAPSE", "RATCHET"];
  const IN_SCOPE = FIXTURE_MODE === "--add-check" ? ["ADD", "VERDICT-COLLAPSE"]
    : FIXTURE_MODE === "--remove-check" ? ["REMOVE"]
    : ["RATCHET"];
  const inScope = (row) => IN_SCOPE.includes(row.split(" ")[0]);

  const dieFixture = (lines) => {
    console.error("");
    console.error("FAIL(2): the fixture control lost its footing — " + LABEL);
    for (const l of lines) console.error(l);
    console.error("");
    console.error("  This is NOT the census failing on the console. It is the control that proves the");
    console.error("  census can fail failing to behave as its own fixture declares. Fix the fixture or");
    console.error("  the arm, never the declaration alone.");
    process.exit(2);
  };

  // ── the declarations, read from the fixture's own bytes ───────────────────
  const flags = [];
  const clears = [];
  const overrides = [];
  // The fixture's own CEILING, declared in its own bytes exactly like everything
  // else about it. A fixture that declares none is making no ratchet claim and
  // the arm stays out of its way — that is how the add and remove fixtures come
  // back silent (exit 0) under `--ratchet-check`, by measurement rather than by
  // an exemption keyed to their filenames. A fixture that declares a ceiling and
  // then cannot make the arm fire still dies, through the ordinary
  // DECLARED-BUT-SILENT path below, so this is not a way to buy quiet.
  const ceilingDecls = [];
  for (const m of src.matchAll(/^[ \t]*\/\/[ \t]*@(must-flag|must-clear|pin-override|legacy)[ \t]+(.+?)[ \t]*$/gm)) {
    const [, kind, rest] = m;
    if (kind === "legacy") {
      ceilingDecls.push(rest.trim());
      continue;
    }
    if (kind === "pin-override") {
      const om = rest.match(/^(.+?)[ \t]+predicate=(null|[A-Za-z_$][A-Za-z0-9_$]*)$/);
      if (!om) dieFixture(["  unparseable @pin-override: " + JSON.stringify(rest),
        "  shape: @pin-override <fn>|<VERB> <route> predicate=<name|null>"]);
      overrides.push({ key: om[1].trim(), predicate: om[2] === "null" ? null : om[2] });
      continue;
    }
    const am = rest.match(/^([A-Z-]+)[ \t]+(.+)$/);
    if (!am || !ARMS.includes(am[1])) {
      dieFixture(["  unparseable @" + kind + ": " + JSON.stringify(rest),
        "  shape: @" + kind + " <" + ARMS.join("|") + "> <key>"]);
    }
    (kind === "must-flag" ? flags : clears).push(am[1] + " " + am[2].trim());
  }

  // D442's shape, enforced rather than hoped for: a one-row fixture proves the
  // wiring and nothing about discrimination, so the floor is TWO of each.
  if (flags.length < 2 || clears.length < 2) {
    dieFixture([`  declares ${flags.length} @must-flag and ${clears.length} @must-clear row(s); the floor is 2 and 2.`,
      "  One must-flag row proves the mode is wired. It does not prove the arm discriminates —",
      "  for that the same run has to leave known-good rows alone (charter D442)."]);
  }

  // ── the observations, computed from the fixture, never from the declarations ─
  // Only the arms this mode runs. A cross cell (the add fixture under
  // `--remove-check`) therefore observes nothing and exits 0 — that silence IS
  // the discrimination proof, and it is only available because the arms are
  // separable here.
  const fixturePinByKey = new Map(FIXTURE_PIN.map((r) => [keyOf(r), r]));
  const observed = new Set();
  if (IN_SCOPE.includes("ADD")) {
    for (const k of seenByKey.keys()) if (!fixturePinByKey.has(k)) observed.add("ADD " + k);
  }
  if (IN_SCOPE.includes("REMOVE")) {
    for (const k of fixturePinByKey.keys()) if (!seenByKey.has(k)) observed.add("REMOVE " + k);
  }

  // The verdict arm, over a COPY of FIXTURE_PIN with the fixture's declared
  // `@pin-override`s applied — a pin-side property no source file can express,
  // so the fixture drives it as a mutant. Same rule the live (2d-ii) runs.
  const overridden = FIXTURE_PIN.map((r) => {
    const o = overrides.find((x) => x.key === keyOf(r));
    return o ? { ...r, predicate: o.predicate } : r;
  });
  for (const o of overrides) {
    if (!fixturePinByKey.has(o.key)) dieFixture(["  @pin-override names a key FIXTURE_PIN does not carry: " + o.key]);
  }
  const pairGroups = new Map();
  for (const r of overridden) {
    const rk = `${r.verb} ${r.route}`;
    if (!pairGroups.has(rk)) pairGroups.set(rk, []);
    pairGroups.get(rk).push(r);
  }
  if (IN_SCOPE.includes("VERDICT-COLLAPSE")) {
    for (const [rk, group] of pairGroups) if (verdictContrastLost(group)) observed.add("VERDICT-COLLAPSE " + rk);
  }

  // The RATCHET arm — PIN-side like VERDICT-COLLAPSE, and driven the same way:
  // `@pin-override` nulls a predicate, which is how a fixture manufactures "a
  // new elevated write shipped unbound" without a live defect to anchor to.
  let ratchetHealed = [];
  let ratchetHeld = [];
  if (IN_SCOPE.includes("RATCHET") && ceilingDecls.length) {
    for (const k of ceilingDecls) {
      if (!fixturePinByKey.has(k)) dieFixture(["  @legacy names a key FIXTURE_PIN does not carry: " + k]);
    }
    if (new Set(ceilingDecls).size !== ceilingDecls.length) {
      dieFixture(["  @legacy declares the same key twice — a ceiling with a duplicate row is a ceiling nobody read."]);
    }
    const v = ratchetVerdict(overridden, ceilingDecls);
    ratchetHealed = v.healed;
    ratchetHeld = v.held;
    for (const k of v.novel) observed.add("RATCHET " + k);
  }

  // ── every must-clear key must be REAL, or the negative control is theatre ──
  const unreal = [];
  for (const c of clears.filter(inScope)) {
    const [arm, ...restParts] = c.split(" ");
    const key = restParts.join(" ");
    if (arm === "VERDICT-COLLAPSE") {
      if (!pairGroups.has(key) || pairGroups.get(key).length < 2) unreal.push(`  ${c} — no multi-site FIXTURE_PIN group on that route`);
    } else if (arm === "RATCHET" && !ceilingDecls.length) {
      unreal.push(`  ${c} — the fixture declares no @legacy ceiling, so the RATCHET arm never ran`);
    } else if (!fixturePinByKey.has(key)) {
      unreal.push(`  ${c} — FIXTURE_PIN carries no such row, so nothing could have cleared`);
    } else if (!seenByKey.has(key)) {
      unreal.push(`  ${c} — the fixture has no such call site, so nothing was exercised`);
    }
  }
  if (unreal.length) {
    dieFixture(["  a @must-clear row names something that does not exist:", ...unreal,
      "  A negative control over an absent subject is green by construction."]);
  }

  // ── the verdict ───────────────────────────────────────────────────────────
  const scopedFlags = flags.filter(inScope);
  const scopedClears = clears.filter(inScope);
  const flagSet = new Set(scopedFlags);
  const missing = scopedFlags.filter((f) => !observed.has(f));
  const unexpected = [...observed].filter((o) => !flagSet.has(o));
  const firedClear = scopedClears.filter((c) => observed.has(c));

  console.log("fixture          :", LABEL);
  console.log("mode             :", FIXTURE_MODE, "· arms in scope:", IN_SCOPE.join(", "),
    "(pin: " + FIXTURE_PIN.length + " rows · fixture sites: " + sites.length + ")");
  if (IN_SCOPE.includes("RATCHET")) {
    if (ceilingDecls.length) {
      const novelHere = [...observed].filter((o) => o.startsWith("RATCHET ")).length;
      console.log("ratchet ceiling  : legacy " + ceilingDecls.length + " · still unbound " + ratchetHeld.length +
        " · healed " + ratchetHealed.length + " · NOVEL " + novelHere);
      for (const h of ratchetHealed) console.log("    HEALED  " + h.key + "  — " + h.why);
    } else {
      console.log("ratchet ceiling  : none declared (@legacy) — the RATCHET arm makes no claim on this fixture");
    }
  }
  console.log("");
  console.log("  declared must-flag :" + (scopedFlags.length ? "" : " (none in scope — this is a CROSS cell)"));
  for (const f of scopedFlags) console.log("    " + (observed.has(f) ? "FIRED   " : "SILENT  ") + f);
  console.log("  declared must-clear:" + (scopedClears.length ? "" : " (none in scope)"));
  for (const c of scopedClears) console.log("    " + (observed.has(c) ? "FIRED   " : "clear   ") + c);
  const outOfScope = [...flags, ...clears].filter((r) => !inScope(r));
  if (outOfScope.length) console.log("  out of scope here  : " + outOfScope.length + " row(s) — " + IN_SCOPE.join("/") + " only");

  if (missing.length || unexpected.length || firedClear.length) {
    dieFixture([
      ...missing.map((f) => "  DECLARED BUT SILENT   " + f + "  — the arm did not fire on a case built to make it fire"),
      ...firedClear.map((c) => "  FIRED BUT MUST CLEAR  " + c + "  — the arm fires on a known-good row; it does not discriminate"),
      ...unexpected.map((o) => "  FIRED UNDECLARED      " + o + "  — the control fired for a reason it does not claim"),
    ]);
  }

  console.log("");
  if (observed.size) {
    console.log(`OK(1): all ${scopedFlags.length} declared arm(s) fired and all ${scopedClears.length} known-good row(s) stayed clear.`);
    console.log("       Exiting 1 — the same code the live ADD/REMOVE arm uses when it loses. 2 is reserved");
    console.log("       for an instrument that lost its footing, and a control that borrowed it would be");
    console.log("       indistinguishable from a broken one.");
    process.exit(1);
  }
  console.log(`OK(0): no ${IN_SCOPE.join("/")} observation on this fixture, and none was declared.`);
  console.log("       This is a CROSS cell of the 2x2: the fixture built to fire the OTHER arm leaves");
  console.log("       this one silent. Without that silence, exit 1 on the matching cell would only show");
  console.log("       the control shouting, never that it can tell the two arms apart.");
  process.exit(0);
}

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
console.log("This census does NOT fix them. cch-w38-s1 (criterion 3) took the THREE this list was named for —");
console.log("retryInstance, removeInstance and updateInstance — so cch-w38-bl-three-elevated-verbs-still-unpredicated");
console.log("is FIXED and no longer the owner of what is left; the rows below are unowned and need a row of their own.");
console.log("The population SHRINKS by re-pinning as well as by fixing: cch-w48-s4 moved five rows out of this list");
console.log("because the console had already fenced them and only the pin still said otherwise. A row leaves this");
console.log("list on a FENCE, never on a tidier note.");
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
// cch-w48-s4 MOVED IT AGAIN: predicated 24 → 29, unpredicated 16 → 11. FIVE
// rows were still pinned UNPREDICATED against a tree where their offer had
// already been fenced — openResurrectModal, runDecommission, submitAddSupport
// and patchAutoupdate on the instance-admin band, submitLaunchFlow on the
// launch band. Each is judged by the convention this pin ALREADY uses for
// rollbackInstance and attachDomain: an offer withheld, or rendered as a
// disabled control with no mount hook, is PREDICATED. The population did not
// move (79 rows, 40 elevated); five rows changed column because the console
// changed, and the pin had gone on describing the older tree. That decay is
// what arm (2i) below exists to make expensive.
//
// AND THEN WAVE 48'S OWN REVIEW MOVED IT ONCE MORE: 29 → 33, 11 → 7. These four
// are NOT re-pins of an older tree; they are THIS WAVE's three fences, which
// were built in sibling worktrees and so could not be seen from here when the
// row above was written. newLaunch (cch-w48-s1), disconnectGithub
// (cch-w48-s3), and submitSiteGithub + disconnectSiteGithub (cch-w48-s2).
// Leaving them at "UNPREDICATED" would have shipped the exact defect this epic
// is about — a scoreboard telling a reader something the console no longer
// supports — inside the slice that exists to stop that. The two site rows are
// FENCE-pinned; arm (2i-4) found them itself, going red on loadSite's new
// orphaned read, which is the first time this instrument has lost in the FIX
// direction on a fence it did not already know about. MERGE ORDER, therefore:
// cch-w48-s2 must be in the tree before this file, or (2i-2) reds on a
// loadSite that does not yet call the band.
// cch-w67 crown: 79 -> 80. ONE row moved — runSiteDelete, the console's first
// DELETE /v1/sites/:id caller. `elevated` DELIBERATELY UNMOVED at 40: that route
// is plain team membership (see the row's own note), so bumping it would be a
// false statement about the router AND would red arm (2b) at rc=2.
// PDF-D94 (pdf-bl-console-key-custody): 80 -> 81. submitAgentKey's POST
// /v1/barkparks/:*/agent-key is elevated by an inline-cond refusal (the overlay
// grew 6 -> 8 in the same commit) and ships UNPREDICATED — the paste form
// renders on every live support row regardless of authority — so elevated and
// unpredicated both move by one, honestly. See the row's own note.
const EXPECT = { total: 81, elevated: 41, predicated: 36, unpredicated: 5 };
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

// ── (2j) THE RATCHET. LEGACY_UNPREDICATED is a CEILING, not a count. ────────
//
//      WHAT IT CLOSES. Everything above this arm is a SET DIFF over CALL SITES,
//      and that is the whole of its reach: (1) reds on a write affordance that
//      ARRIVED with no pin row. It has never had anything to say about a write
//      that arrives WITH one. `elevated` and `predicate` are pinned judgements
//      (LIMIT 1 at the top of this file) and EXPECT is this pin checked against
//      itself, so the sanctioned way to land a new affordance — add the call
//      site, add its row, move EXPECT in the same commit — is also the way to
//      land a new UNBOUND one. Measured, on a tree without this arm: a new
//      `DELETE /v1/github/installation` caller pinned `{elevated: true,
//      predicate: null}` with EXPECT moved by one exits 0, while the census's
//      own summary announces the unpredicated population growing. A brand-new
//      button a plain member can click and be refused for ships GREEN, and the
//      instrument narrates it happening.
//
//      WHAT IT DOES. The keys below are the elevated-and-unbound rows this pin
//      carried when the arm landed, named ONE BY ONE. An elevated row with no
//      predicate whose key is NOT among them exits 3. The population is free to
//      SHRINK without touching this list — a row that gains a predicate, gets
//      re-pinned below elevation, or loses its call site prints HEALED and stays
//      green. So the number can go down on its own and can only go UP through a
//      named edit to a list called LEGACY.
//
//      THE LIMIT, SAID OUT LOUD, BECAUSE AN UNSTATED LIMIT IS THE SAME LIE.
//      This list is SOURCE-EDITABLE, exactly like EXPECT. Anyone who can add a
//      pin row can add a key here in the same commit and be green again. This
//      arm therefore does NOT make it impossible for an unbound elevated write
//      to ship, and no evidence, PR body or comment may claim that it does. What
//      it changes is the SHAPE of the edit: an invisible `+1` inside an
//      eighty-row table becomes a new line in a list whose name is LEGACY and
//      whose failure text says, in this file's own words, that pinning the row
//      and moving EXPECT is not a fix. It is LOUD, not unbypassable.
//
//      THE SECOND LIMIT. The two HEALED directions are proven by editing PIN
//      JUDGEMENTS, not by putting a real client predicate in app.js, because
//      this census cannot see one (charter D430) — `predicate` is a hand-written
//      claim and (2g) only checks that the name it holds is declared somewhere.
//      So the mutation evidence for this arm shows that the ceiling is FREE TO
//      LOWER; it does not show that a fence landing in the console is detected.
//      That is a different instrument (the unfiled DRIFT arm) and this one must
//      not be read as if it were that one.
//
//      WHY 3 AND NOT 1 OR 2. 1 means the pin stopped describing the tree. 2
//      means the instrument lost its footing. Neither happened here: the pin
//      describes the tree perfectly and the instrument is fine. The tree got
//      worse, on purpose, in a commit that said so. That deserves its own code.
const LEGACY_UNPREDICATED = [
  // Each key is `${fn}|${verb} ${route}` — the census's own keyOf, so a row is
  // named by the HANDLER that writes, never by a line number and never by a
  // position in a table. Re-derive with:
  //   node -e 'const s=require("fs").readFileSync("cloud/priv/static/__binding_census.mjs","utf8");
  //     for (const m of s.matchAll(/\{ fn: "([^"]+)", verb: "([^"]+)", route: "([^"]+)", elevated: true, predicate: null,/g))
  //       console.log(`"${m[1]}|${m[2]} ${m[3]}",`)'
  // …or simply read the "UNPREDICATED ELEVATED WRITES" block this file prints.
  "submitProviderCred|POST /v1/providers",
  "submitAgentKey|POST /v1/barkparks/:*/agent-key",
  "newVercelDeploy|POST /v1/barkparks/:*/vercel-deploy",
  "newCreateRepo|POST /v1/github/repos",
  "newRenderFailed|POST /v1/barkparks/:*/retry",
];
{
  if (new Set(LEGACY_UNPREDICATED).size !== LEGACY_UNPREDICATED.length) {
    die2(["FAIL(2): LEGACY_UNPREDICATED names the same key twice.",
      "  A ceiling with a duplicate row is a ceiling nobody read.",
      ...new Set(LEGACY_UNPREDICATED.filter((k, i, a) => a.indexOf(k) !== i)).values()].map(String));
  }
  const ratchet = ratchetVerdict(PIN, LEGACY_UNPREDICATED);

  // NON-VACUITY, tied to a number this file already prints. `held + novel` is
  // the same population the classification line calls UNPREDICATED. If the two
  // ever disagree the arm is reading a different pin than the summary is, and a
  // green from it would mean nothing — so that is a footing failure, not a pass.
  if (ratchet.held.length + ratchet.novel.length !== pinnedUnpredicated.length) {
    die2([
      "FAIL(2): the ratchet arm and the classification summary disagree about the pin.",
      `  arm sees ${ratchet.held.length} held + ${ratchet.novel.length} novel = ${ratchet.held.length + ratchet.novel.length};` +
      ` the summary counts ${pinnedUnpredicated.length} unpredicated elevated rows.`,
      "  One of the two is reading a field the other is not. Do not silence this by moving a",
      "  number — find which reader is wrong.",
    ]);
  }

  console.log("");
  console.log(`ratchet (2j)     : legacy ${LEGACY_UNPREDICATED.length} · still unpredicated ${ratchet.held.length} · ` +
    `healed ${ratchet.healed.length} · NOVEL ${ratchet.novel.length}`);
  for (const h of ratchet.healed) {
    console.log(`    HEALED  ${h.key}`);
    console.log(`            ${h.why} — the ceiling LOWERED. Trim it from LEGACY_UNPREDICATED when convenient;`);
    console.log("            the arm does not require it, because a ceiling that has to be edited to stay");
    console.log("            green is a ceiling that gets edited for the wrong reason too.");
  }

  if (ratchet.novel.length) {
    console.error("");
    console.error("FAIL(3): a NEW unpredicated elevated write is pinned, and it is not on the legacy ceiling.");
    console.error("");
    for (const k of ratchet.novel) {
      const r = pinByKey.get(k);
      const live = liveByKey(r);
      console.error(`  NOVEL     ${k}`);
      console.error(`            ${LABEL}:${live ? live.line : "gone"}  tier ${r.auth_fn || r.context_fn || "?"}`);
    }
    console.error("");
    console.error("  LEGACY_UNPREDICATED is a CEILING, not a count. It names the elevated writes this");
    console.error("  console already ships with no client predicate in front of them. It is allowed to");
    console.error("  shrink on its own and it is not allowed to grow quietly.");
    console.error("");
    console.error("  PINNING THE ROW AND MOVING EXPECT IS NOT A FIX. It is the move this arm exists to");
    console.error("  make visible: the pin would go on summing, the set diff would go on matching, and a");
    console.error("  plain member would go on seeing a button that answers 403. Put a CLIENT PREDICATE in");
    console.error("  front of the affordance — withhold the offer, or render it disabled with no mount");
    console.error("  hook, the way this pin's predicated rows already do — and pin THAT.");
    console.error("");
    console.error("  If the write genuinely belongs on the ceiling — it shipped unbound before this arm");
    console.error("  existed and you are only recording it — add its key below with the reason. That edit");
    console.error("  is legal and it is meant to be readable in review: a line added to a list named");
    console.error("  LEGACY is what this arm buys instead of an invisible increment.");
    process.exit(3);
  }
}

// (2c) DUPLICATE KEYS. Two pinned rows sharing a key would let one hide behind
//      the other, and the whole instrument rests on keys being call sites.
const dupes = [...pinByKey.keys()].length !== PIN.length
  ? PIN.map(keyOf).filter((k, i, a) => a.indexOf(k) !== i)
  : [];
if (dupes.length) {
  die2(["FAIL(2): duplicate PIN keys — a call site is hiding behind another:", ...new Set(dupes.map((d) => "  " + d))]);
}

// (2d) THE DISCRIMINATION CONTROL, IN TWO PARTS — and they are two, because the
//      single fused predicate this check shipped with FROZE A LIVE DEFECT
//      (charter D452). It read:
//
//        if (!bare || !gated || keyOf(bare) === keyOf(gated) || !bp || !gp ||
//            bp.predicate !== null || gp.predicate === null)
//
//      Both terms are DIRECTIONAL, but ONLY ONE OF THEM FREEZES THE DEFECT, and
//      the first draft of this split retired both — which silently dropped a
//      guard main was really running (measured at rescue time, see (2d-iii)).
//
//      `bp.predicate !== null` demands submitProviderCred stay UNPREDICATED
//      forever, so the fix this census exists to motivate — putting a client
//      predicate in front of the launch wizard's provider button — reds its own
//      instrument. Measured on main: predicating that PIN row AND moving EXPECT
//      in the same commit still exits 2. A guard that can only stay green while
//      the disease stays untreated is not a guard; it is the same failure mode
//      as a positive control anchored to a real defect (cch-w38-bl). That term
//      is RETIRED.
//
//      `gp.predicate === null` demands submitInlineProviderCred stay predicated.
//      That direction blocks NOTHING anyone wants to do: the fix touches the
//      bare row, and a commit that nulls the gated row's pin is de-fencing a
//      fence the tree still has. It is KEPT, as (2d-iii).
//
//      (2d-i) KEYING — permanent, and the reason the key is a call site at all.
//      (2d-ii) VERDICT CONTRAST — NON-directional, and the honest residue of the
//              RETIRED term: the pair may not go BOTH unpredicated.
//              submitInlineProviderCred IS fenced by providerCanWrite in the
//              tree, so a pin recording no predicate on either row has forgotten
//              a fence that exists — the pin has been flattened, not the tree
//              fixed. Predicating the bare row leaves one predicate standing and
//              passes; blanket-nulling the pair reds. THE FIXTURE CONTROL above
//              is what proves this arm can lose: the add fixture declares a
//              VERDICT-COLLAPSE must-flag row (its `@pin-override` nulls the
//              gated verdict), and the remove fixture — run through
//              `--add-check`, the 2x2's cross cell — declares the same key
//              must-clear. Measured firing AND measured staying silent.
//      (2d-iii) GATED ROW STAYS FENCED — the surviving directional term, carried
//              over from main verbatim in effect. Measured both ways at rescue
//              time: with only (2d-i)+(2d-ii), predicating the bare row AND
//              nulling the gated row's pin predicate in the same commit exits 0,
//              where main exits 2. (2d-ii) cannot see that pair because one
//              predicate is still standing. It is strictly the weaker rule, so
//              (2d-iii) subsumes it; (2d-ii) is kept for its message, which
//              names the flattening case a reader is most likely to hit.
{
  const bare = sites.find((s) => s.fn === "submitProviderCred" && s.route === "/v1/providers");
  const gated = sites.find((s) => s.fn === "submitInlineProviderCred" && s.route === "/v1/providers");
  const bp = bare && pinByKey.get(keyOf(bare));
  const gp = gated && pinByKey.get(keyOf(gated));
  const keyingLost = !bare || !gated || keyOf(bare) === keyOf(gated) || !bp || !gp;
  // (2d-iii) is evaluated only once keying holds — with no `gp` there is no
  // verdict to read, and (2d-i) already owns that failure with a better message.
  const gatedUnfenced = !keyingLost && gp.predicate === null;
  const failed = keyingLost ? "2d-i" : gatedUnfenced ? "2d-iii" : verdictContrastLost([bp, gp]) ? "2d-ii" : null;
  if (failed) {
    die2([
      "FAIL(2): the POST /v1/providers discrimination control is broken.",
      failed === "2d-i"
        ? "  (2d-i) KEYING: both call sites must be present as TWO distinct keys."
        : failed === "2d-iii"
        ? "  (2d-iii) GATED ROW UNFENCED: submitInlineProviderCred is pinned with NO predicate."
        : "  (2d-ii) VERDICT CONTRAST: the pair is pinned BOTH unpredicated. renderConnectCard",
      failed === "2d-i"
        ? "  Route-keyed, they collapse into one 'predicated' row and the one real defect on"
        : failed === "2d-iii"
        ? "  renderConnectCard mounts only when providerCanWrite(), so this row's fence is REAL."
        : "  mounts only when providerCanWrite(), so a pin with no predicate on either row has",
      failed === "2d-i"
        ? "  this route becomes invisible. This control is the proof they have not collapsed."
        : failed === "2d-iii"
        ? "  Either the console de-fenced it (that is the bug) or the pin was flattened. Note that\n  predicating the BARE row is the fix this census motivates and does NOT trip this arm."
        : "  forgotten a fence that exists. Predicating the BARE row is the fix and passes here.",
      `    submitProviderCred       → ${bare ? LABEL + ":" + bare.line : "MISSING"}${bp ? " predicate=" + bp.predicate : ""}`,
      `    submitInlineProviderCred → ${gated ? LABEL + ":" + gated.line : "MISSING"}${gp ? " predicate=" + gp.predicate : ""}`,
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

// (2i) THE FENCE PINS, MADE LOSABLE IN THE FIX DIRECTION (charter D540).
//
//      WHAT (2g) LEFT OPEN. (2g) drops every row whose `predicate` is null
//      BEFORE it checks anything, so it can only ever lose in the DELETE
//      direction: rename a live predicate and it reds; ship a REAL fence for an
//      unpinned row and the census stays byte-identical at rc 0. This wave
//      measured exactly that — a genuine providerCanWrite() fence for
//      #github-disconnect moved nothing — and the same asymmetry let SIX rows
//      go on printing "NONE — a member can click it" over a console that had
//      already fenced them. A number that cannot move when the disease is CURED
//      is not an instrument, it is a slogan.
//
//      WHAT IS PINNED, AND WHY IT IS A TRIPLE. A row that claims a fence pins
//      {band, read, decide} — the authority function, the function that reads
//      it, and the function that turns the answer into an offer. It is three
//      names and not one because this console SPLITS them on purpose (charter
//      D530): the band is read at the DOM mount and threaded, as a value, into
//      a pure helper that decides. A row is checked HERE because it pinned a
//      fence — never because it happens to carry a predicate string.
//
//      TWO SHAPES ARE REFUTED. Do not "upgrade" this arm into either.
//        · A CALL GRAPH. Charter D517 refuted it BY BUILDING IT: fail-green on
//          the clean tree, and six of seven "fences" resolving through
//          operatorRouteAllowed graph noise. There is no separating hop
//          threshold, and this console fences by HIDING ELEMENTS, which a call
//          graph is blind to by category. No hops are walked below.
//        · A BODY SCOPE over the pinned `fn`. Refuted by measurement:
//          openResurrectModal's own body contains ZERO occurrences of its band
//          — the read lives thousands of lines away in loadArchives. Span
//          containment reds 19 of the 22 true rows.
//
//      WHAT IT DOES INSTEAD — three pinned sub-checks and ONE DERIVED one:
//        (2i-1) band, every read, and decide are DECLARED in app.js, and the
//               row's `predicate` names the same band.
//        (2i-2) each read's body still CALLS the band.
//        (2i-3) decide's body still BRANCHES on a value the band can return —
//               where the vocabulary is DERIVED from the band's own returns,
//               not typed here.
//        (2i-4) DERIVED ACCOUNTING over every live call site of every pinned
//               band: each enclosing function must be claimed by some row's
//               `read`. This is what reds when a row quietly reverts to no
//               fence, with no graph and no hop walk.
{
  // Comments blanked, LENGTH PRESERVED, so every offset still maps to the same
  // line in `src`. Blanking matters twice over: this file's own prose says
  // "instanceAdminAuthority()" in half a dozen comments, and counting those as
  // call sites would invent read sites that do not exist.
  const codeMask = (s) => {
    const out = s.split("");
    let inS = null, esc = false;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (inS) {
        if (esc) { esc = false; continue; }
        if (c === "\\") { esc = true; continue; }
        if (c === inS) inS = null;
        continue;
      }
      if (c === '"' || c === "'" || c === "`") { inS = c; continue; }
      if (c === "/" && s[i + 1] === "/") {
        const nl = s.indexOf("\n", i);
        const end = nl < 0 ? s.length : nl;
        for (let k = i; k < end; k++) out[k] = " ";
        i = end;
        continue;
      }
      if (c === "/" && s[i + 1] === "*") {
        const close = s.indexOf("*/", i + 2);
        const end = close < 0 ? s.length : close + 2;
        for (let k = i; k < end; k++) if (out[k] !== "\n") out[k] = " ";
        i = end - 1;
        continue;
      }
    }
    return out.join("");
  };
  const code = codeMask(src);

  const declsOf = (name) => fns.filter((f) => f.name === name);
  const bodyOf = (f) => code.slice(f.start, f.end);
  const esc0 = (n) => n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const readsOf = (r) => (Array.isArray(r.fence.read) ? r.fence.read : [r.fence.read]);

  const FENCED = PIN.filter((r) => r.fence);
  const BANDS = [...new Set(FENCED.map((r) => r.fence.band))];

  // A named hole, and every name on it must still be a live read site — a
  // stale exemption is a hole that has stopped even being honest about what it
  // covers, so it reds. Empty is the goal state, and for the instance-admin
  // band it is the ACTUAL state: all four of its read sites are claimed.
  const READ_EXEMPT = {
    // band: [{ fn: "<enclosing fn>", why: "<a stated reason, because a hole nobody named is a lie>" }]
  };

  if (!FENCED.length) {
    die2([
      "FAIL(2i): no PIN row pins a fence any more.",
      "  Arm (2i) is the only thing in this census that can red when a fence is SHIPPED or",
      "  NEUTERED. Emptying it silently would restore the exact one-directional blindness it",
      "  was built to remove, and every check below would pass over nothing.",
    ]);
  }

  // ── (2i-1) band, reads and decide DECLARED; predicate agrees with band ────
  {
    const bad = [];
    for (const r of FENCED) {
      const slots = [["band", r.fence.band], ["decide", r.fence.decide]]
        .concat(readsOf(r).map((n) => ["read", n]));
      for (const [slot, name] of slots) {
        if (!name) bad.push(`  ${keyOf(r)} -> ${slot} is empty`);
        else if (!declsOf(name).length) bad.push(`  ${keyOf(r)} -> ${slot} ${name} — no \`function ${name}(\` in app.js`);
      }
      if (r.predicate !== r.fence.band) {
        bad.push(`  ${keyOf(r)} -> predicate ${r.predicate === null ? "null" : r.predicate} but fence.band ${r.fence.band}`);
      }
    }
    if (bad.length) {
      die2([
        "FAIL(2i-1): a pinned fence names something app.js does not declare, or disagrees with its own row.",
        "  A fence is three names and they must all still be there: the band that answers, the",
        "  function that reads it, the function that decides the offer. This arm needs the BODIES,",
        "  so it wants a `function NAME(` declaration — converting one to a const arrow is a re-pin,",
        "  not a silent pass. And `predicate` must name the same band the fence does, or the printed",
        "  column and the checked fence are two different claims about one row.",
        "",
        ...bad,
      ]);
    }
  }

  // ── (2i-2) each READ still CALLS the band ────────────────────────────────
  //     This is the direction charter D430 proved live: delete the band read
  //     out of the render path and the shipped census did not move a byte.
  {
    const bad = [];
    for (const r of FENCED) {
      const call = new RegExp("\\b" + esc0(r.fence.band) + "\\s*\\(");
      for (const name of readsOf(r)) {
        const hit = declsOf(name).some((f) => call.test(bodyOf(f)));
        if (!hit) bad.push(`  ${keyOf(r)} -> read ${name} no longer calls ${r.fence.band}()`);
      }
    }
    if (bad.length) {
      die2([
        "FAIL(2i-2): a pinned read no longer reads its band.",
        "  The row still claims an offer-time fence, but the function that was supposed to ASK",
        "  the authority question does not ask it any more — so whatever the decide helper is",
        "  branching on, it is not this band's answer. Either restore the read, or drop the",
        "  fence and move the row back to UNPREDICATED (and move EXPECT with it).",
        "",
        ...bad,
      ]);
    }
  }

  // ── (2i-3) DECIDE still BRANCHES on the band's own vocabulary ────────────
  //     The vocabulary is DERIVED from the band's `return` statements, never
  //     typed here: a band that stops returning a vocabulary at all (the
  //     `return true` neutering) leaves nothing to branch on and reds below,
  //     and a band that gains a value does not need this file edited.
  const vocabOf = {};
  {
    const bad = [];
    for (const band of BANDS) {
      const body = declsOf(band).map(bodyOf).join("\n");
      const vocab = new Set();
      const ret = /\breturn\b([^;]*)/g;
      let m;
      while ((m = ret.exec(body))) {
        // A literal on the RIGHT of a comparison is an INPUT the band reads
        // (`meCache.role === "owner"`), not a value it can answer with. Blank
        // those first or the vocabulary quietly widens to include the role
        // names, and (2i-3) would accept a decide branching on the wrong thing.
        const answered = m[1].replace(/(===|!==|==|!=)\s*(?:"[^"\\]*"|'[^'\\]*')/g, "$1 0");
        const lits = answered.match(/"([^"\\]*)"|'([^'\\]*)'/g) || [];
        for (const l of lits) vocab.add(l.slice(1, -1));
      }
      vocabOf[band] = [...vocab];
      if (!vocabOf[band].length) {
        bad.push(`  band ${band} returns no string vocabulary at all — there is nothing left for a caller to branch on`);
      }
    }
    for (const r of FENCED) {
      const vocab = vocabOf[r.fence.band] || [];
      if (!vocab.length) continue;
      const body = declsOf(r.fence.decide).map(bodyOf).join("\n");
      const branches = vocab.some((v) => new RegExp("(===|!==)\\s*[\"']" + esc0(v) + "[\"']").test(body));
      if (!branches) {
        bad.push(`  ${keyOf(r)} -> decide ${r.fence.decide} branches on none of ${r.fence.band}'s values [${vocab.join(", ")}]`);
      }
    }
    if (bad.length) {
      die2([
        "FAIL(2i-3): a fence is still wired and no longer decides anything.",
        "  The read still asks the question and the answer still arrives — and then the decide",
        "  helper renders the same offer whatever it says. That is the NEUTERED fence: every",
        "  other arm of this census goes green over it, and a plain member gets the button back.",
        "  This check is a ratchet, not a proof: it asserts the comparison is still THERE, not",
        "  that its two arms are still right.",
        "",
        ...bad,
      ]);
    }
  }

  // ── (2i-4) DERIVED ACCOUNTING over every live band call site ─────────────
  //     No graph, no hops: find where the band is actually CALLED, take the
  //     enclosing function, and demand some row claim it as a read.
  const accounting = [];
  {
    const orphans = [];
    const stale = [];
    for (const band of BANDS) {
      const claimed = new Set(FENCED.filter((r) => r.fence.band === band).flatMap(readsOf));
      const exempt = READ_EXEMPT[band] || [];
      const re = new RegExp("\\b" + esc0(band) + "\\s*\\(", "g");
      const seen = new Map(); // enclosing fn -> [lines]
      let m;
      while ((m = re.exec(code))) {
        // The band's own declaration is not a read of it.
        if (/\bfunction\s+$/.test(code.slice(Math.max(0, m.index - 40), m.index))) continue;
        const f = innermost(m.index);
        const name = f ? f.name : "(top level)";
        if (!seen.has(name)) seen.set(name, []);
        seen.get(name).push(lineOf(m.index));
      }
      if (!seen.size) {
        die2([
          "FAIL(2i-4): a pinned band is never called in app.js.",
          `  ${band} is pinned as the fence for ${claimed.size} read site(s) and the live file calls it`,
          "  nowhere. A fence nothing reads is not a fence; the rows that claim it are unpredicated.",
        ]);
      }
      for (const [name, lines] of seen) {
        const ex = exempt.find((e) => e.fn === name);
        if (!claimed.has(name) && !ex) {
          for (const l of lines) orphans.push(`  ${LABEL}:${l}  ${band}() is read in ${name}, which NO row claims as a fence read`);
        }
      }
      for (const e of exempt) {
        if (!seen.has(e.fn)) stale.push(`  READ_EXEMPT[${band}] holds ${e.fn}, which no longer reads the band at all`);
      }
      accounting.push({
        band: band,
        sites: [...seen.values()].reduce((n, l) => n + l.length, 0),
        readers: [...seen.keys()],
        claimed: [...claimed],
        exempt: exempt.map((e) => e.fn),
      });
    }
    if (orphans.length || stale.length) {
      die2([
        "FAIL(2i-4): an authority band is read somewhere no PIN row accounts for.",
        "  Every function that CALLS a pinned band is offering something on that band's answer.",
        "  If no row claims it as a `read`, either an affordance was fenced and never pinned, or a",
        "  row that used to pin this fence has quietly gone back to claiming nothing. Both are the",
        "  pin decaying away from the tree, which is the whole disease.",
        "",
        "  THE HONEST LIMIT, stated here because a gate that overstates its reach is the same lie",
        "  it is checking for: THIS ACCOUNTING IS OVER READ SITES, NOT OVER ROWS. Rows share reads —",
        "  on the instance screen a single read in loadInstance feeds the header, the updates panel",
        "  and the support card. So patchAutoupdate and submitAddSupport were found BY HAND, and",
        "  dropping either row's fence would leave this check green, because sibling rows still",
        "  claim the same read. This arm is anti-decay bookkeeping with derived teeth. It is NOT a",
        "  discovery instrument, and it cannot tell you which unpinned affordance to fence next.",
        "",
        ...orphans,
        ...stale,
        "",
        "  Fix it by PINNING (add the fence to the row that owns the affordance) or by naming the",
        "  hole in READ_EXEMPT with a reason. An unexplained exemption is worse than a red.",
      ]);
    }
  }

  // THE PRINT SITS BEHIND THE CHECKS, never in front of them — the overlay's
  // rule, for the overlay's reason: a summary printed ahead of its own gate
  // gets read as the verdict.
  console.log("");
  console.log(`fence accounting (charter D540): ${FENCED.length} of ${pinnedPredicated.length} predicated rows pin a {band, read, decide} triple`);
  for (const a of accounting) {
    console.log(`  ${a.band}  —  ${a.sites} live read site(s) in ${a.readers.length} function(s), ${a.claimed.length} claimed by rows` +
      (a.exempt.length ? `, ${a.exempt.length} exempt` : ", READ_EXEMPT empty") + ", 0 orphaned");
    console.log(`    vocabulary DERIVED from its returns: ${vocabOf[a.band].map((v) => '"' + v + '"').join(" · ")}`);
    console.log(`    read sites: ${a.readers.join(", ")}`);
  }
  const unfenced = pinnedPredicated.filter((r) => !r.fence);
  const byBand = new Map();
  for (const r of unfenced) byBand.set(r.predicate, (byBand.get(r.predicate) || 0) + 1);
  console.log(`  NOT fence-pinned, so still LIMIT 1 and unchecked by (2i): ${unfenced.length} predicated row(s) across ` +
    `${byBand.size} band(s) — ` + [...byBand].map(([b, n]) => `${b} ×${n}`).join(", "));
  console.log("  The accounting is over READ SITES, not rows: rows share reads, so a row whose read a");
  console.log("  sibling already claims is NOT discovered here. Anti-decay bookkeeping, never discovery.");
}

// (2h) THE HEADER'S OWN CLAIM, MADE LOSABLE (cch-w47-rv).
//
//      The header at the top of this file asserts, flatly, that NO LINE NUMBER
//      IS WRITTEN DOWN HERE. Charter D528 made that true of the 79 PIN rows and
//      of the six printed router lines — and left SEVEN behind in prose that
//      nothing read and nothing could red: five `note:` strings naming
//      router.ex lines for the inline-cond sites, the excluded local-binding
//      site, and the two /v1/auth/device routes. Every one of them was already
//      stale (the notes said 2058/4302/4360/8082/8290 against a router that
//      derives 2140/4396/4458/8312/8525), which is precisely the defect class
//      the D528 half-A deletion existed to remove — a claim of derivation with
//      typed decoys underneath it.
//
//      So the claim is now a CHECK. This arm reads THIS file's own bytes and
//      refuses any `<source file>:<digits>` literal. The derived prints are
//      untouched by it: they are built at run time from template literals
//      (`router.ex:${...}`, `${LABEL}:${s.line}`), so the SOURCE carries no
//      digits for this regex to find. It fails LOUD rather than silently
//      tolerating the next one somebody types into a comment.
{
  const selfSrc = fs.readFileSync(new URL(import.meta.url), "utf8");
  const written = [];
  selfSrc.split("\n").forEach((text, i) => {
    const m = /\b(app\.js|router\.ex|index\.html|app\.css|[A-Za-z0-9_-]+\.mjs):\d+/.exec(text);
    if (m) written.push(`  __binding_census.mjs:${i + 1}  ${m[0]}   ${text.trim().slice(0, 96)}`);
  });
  if (written.length) {
    die2([
      "FAIL(2h): a line number is written down in this file.",
      "",
      "  The header of this file claims that every line number it prints is DERIVED and that",
      "  none is recorded here. A typed `file:NNNN` breaks that claim the moment a sibling",
      "  shifts — and nothing else in this census can red on it, which is how the previous",
      "  seven survived, all seven of them stale.",
      "",
      "  Name the CONTENT instead (a function name, a route, the grep that finds it), or let",
      "  the derived print own the numeral. Never restate a numeral this file cannot check.",
      "",
      ...written,
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
