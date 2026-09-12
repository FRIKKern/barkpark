// __route_fence.mjs — cch-w50-bl-shared-route-fence-module
//
// THE ONE route -> fence table. Nothing else in the console tree may keep a
// second one.
//
// WHY IT EXISTS. cch-w46-s7 shipped member-authority-sweep.mjs with its own
// TYPED `fence:` column on every HOOKS row, each row citing the
// __binding_census.mjs PIN row it had been read from BY HAND. That citation is
// prose: nothing re-read it, nothing could red when the census moved, and two
// tables that can disagree is this epic's founding defect class. The sweep's
// FILES fence excluded the census, so the extraction could not be done in that
// slice. This is that extraction.
//
// THE SHAPE, and why it is a THIRD file rather than one importing the other.
// The census already imports nothing from the sweep and the sweep already
// imports nothing from the census, but a (2n)-style arm in the census wants the
// fence answer and the sweep wants the same answer for its rows — so the answer
// lives here, below both, and both import DOWN into it. A cycle (the sweep
// importing the census, or the reverse) would run one instrument's whole gate
// during the other's module evaluation, and __binding_census.mjs ends in
// process.exit(): an import of it can never return.
//
// ── THE MEASURED TRAP THIS MODULE IS BUILT AROUND ───────────────────────────
// Deriving a route's fence from its `Auth.require_*` tier ALONE is FAIL-OPEN.
// POST /v1/fleet/supports is mounted under Auth.require_user_or_pat and would
// derive to plain member — its refusal of a non-admin SESSION lives in a `cond`
// clause, `Accounts.team_admin?(conn.assigns.current_user,
// conn.assigns.current_team)`, invisible to any `Auth.*` grep. Four more routes
// have the same shape. So the derivation is TWO-LAYER:
//
//     requireOnlyFence(entry)   the naive tier read — kept, EXPORTED, and run
//                               on every entry, precisely so the gap it leaves
//                               is a measured quantity rather than a warning
//                               in a comment
//     fenceFor(entry)           the shipped answer: the tier, then the
//                               INLINE_COND overlay, which can only ever RAISE
//
// Every entry that the overlay (and only the overlay) elevates carries
// `overlay_required: true`. `overlayGapReport()` asserts, per such entry, that
// requireOnly says member and shipped says elevated — so deleting an overlay
// row makes the TYPED expectation and the DERIVATION disagree, and both
// importers red. That is the lock, and it is losable from both sides: a typed
// flag with no gap reds, and a gap with no typed flag reds.
//
// ── WHAT IS *NOT* HERE ──────────────────────────────────────────────────────
// Per-CALL-SITE authority — predicates, fence bands, context_fn — stays in the
// census PIN, which is keyed by function. This module answers one question
// only: given a route, what tier must the caller hold. A route has one answer;
// a call site in front of it may have many fences.

// ── the fence vocabulary ─────────────────────────────────────────────────────
// ELEVATED = above plain team membership. Anything else is member-reachable.
// `unknown` exists ONLY so an author can be forced to answer: a routed row
// carrying it is an UNFENCED red, never a pass.
export const F_MEMBER = "member";        // any team member may call it
export const F_SELF = "self";            // self-scoped (your own account/token)
export const F_CLIENT = "client";        // no route at all — navigation, clipboard, disclosure
export const F_ADMIN = "elevated:team_admin";
export const F_UNKNOWN = "unknown";
export const ELEVATED = new Set([F_ADMIN]);

// ── the router's authority tiers, by their source-text names ────────────────
export const A_USER = "Auth.require_user";
export const A_TADMIN = "Auth.require_team_admin";
export const A_PTADMIN = "Auth.require_current_team_admin";
export const A_PTOWNER = "Auth.require_current_team_owner";
export const A_OPERATOR = "Auth.require_platform_operator";
export const A_USER_OR_PAT = "Auth.require_user_or_pat";
export const A_ABILITY = "Auth.require_ability";
export const H_TEAM_ROLE = 'with_team_role(conn, "admin")';

// The tiers that are elevated above plain team membership.
//
// require_ability IS NOT ONE OF THEM, and that is the census's ruling (a), not
// an oversight: a browser SESSION carries ["root"], so require_ability is a
// PAT-shaped fence and a no-op for the console. Counting it as elevated would
// make the sweep withhold controls the server honours.
const ELEVATED_TIERS = new Set([A_TADMIN, A_PTADMIN, A_PTOWNER, A_OPERATOR, H_TEAM_ROLE]);

// ═══════════════════════════════════════════════════════════════════════════
// THE INLINE-COND OVERLAY (charter D421) — router routes whose refusal of a
// non-admin lives in a `cond` clause, invisible to any `Auth.*` grep. Recorded
// here because several of the console's elevated writes are elevated ONLY by
// these, and a census that read `Auth.*` alone would call them member.
//
// SIX, NOT SEVEN. cch-w36-s5's brief mandated "the SEVEN post-guard inline-cond
// routes"; the grep it prescribed returns SIX. The seventh site BY CONTENT is
// the one reading `admin? = Accounts.team_admin?(user, team)` — invisible to
// that grep because it binds a local; its line is DERIVED and printed as the
// overlay's EXCLUDED row, never written down here. It is EXCLUDED BY NAME, not
// counted: it is a self-scope NARROWING on a GET (the notification delivery log
// fences a member to their own rows), never a refusal. Inventing a seventh row
// would have made the overlay wrong in the other direction.
//
// EIGHT SINCE PDF-D94 (pdf-bl-console-key-custody): the agent-key POST and its
// status-poll GET both refuse non-admin sessions inside the same cond shape as
// POST /v1/fleet/supports (the read narrates a write only admins can make, so
// it carries the same disjunction). Recorded the day they landed, in the same
// commit as the routes.
//
// THE ROUTES ARE PINNED. THE LINE NUMBERS ARE NOT, AND NEVER AGAIN WILL BE.
// These six used to carry a typed `line:` that the census PRINTED, and all six
// were stale (drift 82, 87, 94, 98, 230, 235). Pin-and-check was built and
// REFUSED: router.ex took 102 commits in 30 days and all six of these lines
// moved within a SINGLE calendar day, so a numeral corrected at merge is wrong
// by the next one — and the census runs FIRST of three in the same CI job, so a
// drift red would convert an unrelated router insertion into a three-census
// outage. DERIVE AND PRINT; never pin and compare.
// ═══════════════════════════════════════════════════════════════════════════
export const INLINE_COND_ROUTES = [
  "POST /v1/fleet/supports",
  "DELETE /v1/fleet/supports/:id",
  "POST /v1/barkparks/:id/agent-key",
  "GET /v1/barkparks/:id/agent-key (status poll — same cond, admin-narrated read)",
  "POST /v1/launch + POST /v1/go-live (go_live/1)",
  "POST /v1/resurrect (resurrect/1)",
];
export const INLINE_COND_EXCLUDED = { why: "self-scope NARROWING on GET /v1/notifications/deliveries — binds `admin?` as a local, never refuses" };

// The overlay rows are written for a HUMAN — one row may name two routes
// ("POST /v1/launch + POST /v1/go-live"), and each carries the prose that says
// which cond it is. The MACHINE key set is DERIVED from those same strings, so
// there is still exactly one place a route is written down. Deriving rather
// than keeping a second literal list is the whole point of this file.
//
// `:id` is the router's own parameter spelling and `:*` is the census PIN's; a
// route key is normalised to `:*` so the two vocabularies meet.
export const normaliseRoute = (r) => r.trim().replace(/:[A-Za-z_][A-Za-z0-9_]*/g, ":*");
export const routeKey = (verb, route) => verb.trim().toUpperCase() + " " + normaliseRoute(route);

export const INLINE_COND_KEYS = new Set(
  INLINE_COND_ROUTES.flatMap((row) =>
    row
      .replace(/\s*\([^)]*\)\s*$/, "")      // drop the trailing prose gloss
      .split("+")
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => {
        const m = /^([A-Z]+)\s+(\/\S*)$/.exec(part);
        if (!m) throw new Error("__route_fence: overlay row is not `VERB /route`: " + JSON.stringify(part));
        return routeKey(m[1], m[2]);
      })),
);

// ═══════════════════════════════════════════════════════════════════════════
// THE ROUTE TABLE. One row per route either instrument must fence.
//
// `auth_fn` is the route's ROUTER tier, verbatim, or null when the route is
// mounted behind a pipeline helper instead (with_team_site/2 and friends — see
// the census's ruling (a): those resolve to tenancy, not to role).
// `pin` is the census PIN key this row is PROVEN against — the census's (2n)
// arm re-reads the PIN and reds if the tier or the elevated verdict disagrees.
// A row may set `pin: null`, but then it MUST say `why_no_pin`, and (2n) prints
// it: the PIN covers WRITE call sites made by app.js, so a READ route has
// nothing there to bind to.
//
// AND THAT IS NOW THE WHOLE OF THE HATCH. It used to hold a second kind of
// occupant — a BAND LABEL (`POST /v1/instances/:*/lifecycle`), a string no
// router ever served, typed onto the sweep's two lifecycle hook rows and citing
// a PIN row that did not exist. Its rows now name `DELETE /v1/barkparks/:*`,
// the band's one console-executed write, and the label row is gone. The rule
// that keeps it gone is `pinHatchReport()` below: a PIN-less row must be a
// READ, and a write that declines to name a PIN key reds on BOTH importers.
// A predicate, not a two-item skip list — a third unbound write cannot appear
// by being added to an allowlist nobody re-reads.
// ═══════════════════════════════════════════════════════════════════════════
export const ROUTE_TIERS = [
  // ── reads ──
  { key: "GET /v1/notifications/deliveries", auth_fn: A_USER, pin: null,
    why_no_pin: "a READ. The census PIN is 80 WRITE call sites; no read has a row there. The overlay records this route as the EXCLUDED self-scope narrowing — a member sees their own rows, never a refusal",
    why: "any member may page their own delivery log" },

  // ── site writes — ruling (a): require_ability is a no-op for a session ──
  { key: "POST /v1/sites", auth_fn: A_USER, pin: "POST /v1/sites", why: "any member may create a site" },
  { key: "POST /v1/sites/:*/deploy", auth_fn: null, pin: "POST /v1/sites/:*/deploy", why: "with_team_site {:ability,\"write\"} — tenancy, not role" },
  { key: "POST /v1/sites/:*/rollback", auth_fn: null, pin: "POST /v1/sites/:*/rollback", why: "with_team_site {:ability,\"write\"}" },
  { key: "POST /v1/sites/:*/deployments/:*/promote", auth_fn: A_USER_OR_PAT + " + " + A_ABILITY, pin: "POST /v1/sites/:*/deployments/:*/promote", why: "require_ability is PAT-shaped; a session carries [\"root\"]" },
  { key: "DELETE /v1/sites/:*", auth_fn: null, pin: "DELETE /v1/sites/:*", why: "with_team_site {:ability,\"write\"}; the INSTANCE Decommission is a strictly higher band" },
  { key: "POST /v1/sites/:*/env", auth_fn: null, pin: "POST /v1/sites/:*/env", why: "with_team_site(conn, fn)" },
  { key: "PATCH /v1/sites/:*", auth_fn: A_ABILITY, pin: "PATCH /v1/sites/:*", why: "require_ability + with_team_site" },
  { key: "POST /v1/sites/:*/github/connect", auth_fn: A_TADMIN, pin: "POST /v1/sites/:*/github/connect", why: "team-admin tier at the router" },
  { key: "DELETE /v1/github/installation", auth_fn: A_TADMIN, pin: "DELETE /v1/github/installation", why: "team-admin tier at the router" },

  // ── instance / barkpark writes ──
  { key: "POST /v1/barkparks/:*/verify", auth_fn: A_USER, pin: "POST /v1/barkparks/:*/verify", why: "team-scoped member action" },
  // THE INSTANCE-ADMIN BAND'S PIN-BOUND ROUTE. Two call sites ride it —
  // runDecommission (the CLI rail's live Decommission) and removeInstance (the
  // header's Retry removal) — and the census PIN carries a row for each, both
  // auth_fn require_current_team_admin. The sweep's two lifecycle hook rows now
  // name THIS route rather than the band label that used to sit below: the band
  // label was not a router route, nothing could re-read it, and its fence answer
  // was this route's tier copied by hand.
  { key: "DELETE /v1/barkparks/:*", auth_fn: A_PTADMIN, pin: "DELETE /v1/barkparks/:*", why: "the lifecycle band's ONE console-executed write (decommission); the header's Retry removal is the second call site on it" },
  { key: "POST /v1/barkparks/:*/agent-key", auth_fn: A_USER_OR_PAT, pin: "POST /v1/barkparks/:*/agent-key", overlay_required: true,
    why: "require_user_or_pat at the router; the non-admin SESSION is refused inside a cond (PDF-D94)" },

  // ── the launch / fleet band: elevated ONLY by the inline-cond overlay ──
  { key: "POST /v1/launch", auth_fn: A_USER_OR_PAT, pin: "POST /v1/launch", overlay_required: true,
    why: "require_user_or_pat at the router; go_live/1 refuses non-admins inside a cond" },
  { key: "POST /v1/fleet/supports", auth_fn: A_USER_OR_PAT, pin: "POST /v1/fleet/supports", overlay_required: true,
    why: "THE MEASURED TRAP. require_user_or_pat at the router, admin gate is Accounts.team_admin? inside a cond" },
  { key: "POST /v1/resurrect", auth_fn: A_USER, pin: "POST /v1/resurrect", overlay_required: true,
    why: "require_user at the router; resurrect/1 refuses non-admins inside a cond" },

  // ── self-scope ──
  { key: "DELETE /v1/tokens/:*", auth_fn: A_USER, scope: "self", pin: "DELETE /v1/tokens/:*", why: "revoke your OWN token" },
];

const BY_KEY = new Map(ROUTE_TIERS.map((r) => [normaliseRoute(r.key.replace(/^(\S+)/, (v) => v.toUpperCase())), r]));

// ── THE NAIVE DERIVATION, kept on purpose ───────────────────────────────────
// This is what a `require_*`-only reader answers. It is EXPORTED and RUN, not
// described: the gap between it and fenceFor() is the quantity this module
// exists to hold, and a quantity nothing computes is a claim nobody can lose.
export function requireOnlyFence(entry) {
  if (!entry) return F_UNKNOWN;
  if (entry.scope === "self") return F_SELF;
  return ELEVATED_TIERS.has(entry.auth_fn) ? F_ADMIN : F_MEMBER;
}

// ── THE SHIPPED DERIVATION ──────────────────────────────────────────────────
// tier, then overlay. The overlay can only ever RAISE: a route whose router
// tier is already team-admin does not become member because no cond mentions
// it.
export function fenceFor(entry) {
  if (!entry) return F_UNKNOWN;
  const naive = requireOnlyFence(entry);
  if (naive === F_ADMIN) return F_ADMIN;
  if (INLINE_COND_KEYS.has(normaliseRoute(entry.key))) return F_ADMIN;
  return naive;
}

// The answer both instruments ask for. `null` route = a client-only control.
// An UNRECORDED route answers `unknown`, which is never a pass on either side:
// the sweep reds it as UNFENCED and the census reds it in (2n).
export function fenceForRoute(route) {
  if (!route) return F_CLIENT;
  const entry = BY_KEY.get(normaliseRoute(route.replace(/^(\S+)/, (v) => v.toUpperCase())));
  return entry ? fenceFor(entry) : F_UNKNOWN;
}

export const routeEntry = (route) => BY_KEY.get(normaliseRoute(route.replace(/^(\S+)/, (v) => v.toUpperCase()))) || null;

// ── THE LOCK, run by BOTH importers ─────────────────────────────────────────
// Losable in both directions:
//   · an entry typed `overlay_required` whose naive fence is NOT member, or
//     whose shipped fence is NOT elevated  → the overlay row that raised it is
//     gone (or the router tier changed and the flag is now a lie)
//   · an entry the overlay raises that is NOT typed `overlay_required` → a
//     silent new fail-open specimen nobody decided on
// Both arms name POST /v1/fleet/supports by name when it is the one that moved,
// because that is the specimen the trap was measured on.
export function overlayGapReport() {
  const lines = [];
  const bad = [];
  for (const entry of ROUTE_TIERS) {
    const naive = requireOnlyFence(entry);
    const shipped = fenceFor(entry);
    const raised = naive !== shipped;
    if (entry.overlay_required) {
      if (naive !== F_MEMBER || shipped !== F_ADMIN) {
        bad.push(entry.key + " is typed `overlay_required`, but the derivation now answers require-only=" + naive +
          " shipped=" + shipped + " (expected member -> " + F_ADMIN + "). The inline-cond overlay row that elevated it " +
          "is gone, so a require_*-only reader and the shipped reader now AGREE — on the fail-open answer. That is the " +
          "exact under-fencing this module exists to catch: the router mounts it under " + entry.auth_fn +
          " and refuses the non-admin session inside a `cond` no `Auth.*` grep can see.");
      } else {
        lines.push(entry.key + "  require-only=" + naive + "  ->  shipped=" + shipped + "   [" + entry.why + "]");
      }
    } else if (raised) {
      bad.push(entry.key + " is RAISED by the inline-cond overlay (" + naive + " -> " + shipped + ") but carries no " +
        "`overlay_required` flag. A new fail-open specimen appeared and nobody decided on it: type the flag, or take " +
        "the overlay row out.");
    }
  }
  if (!lines.length && !bad.length) {
    bad.push("NO entry is elevated by the inline-cond overlay any more. A require_*-only derivation would now be " +
      "EQUIVALENT to the shipped one, which means this module's whole reason to exist has been deleted rather than " +
      "outgrown. If the router really did lower every cond-fenced route, delete the overlay AND this guard together.");
  }
  return { ok: bad.length === 0, lines, bad };
}

// ── THE PIN HATCH, AS A PREDICATE ───────────────────────────────────────────
// `pin: null` is legal for exactly one reason: the census PIN is a WRITE call
// site census (zero GET rows), so a read route has nothing there to bind to.
// Any other PIN-less row is a route whose fence nothing re-reads — the shape
// the band label `POST /v1/instances/:*/lifecycle` had, where the cited PIN row
// never existed and the citation could not have been checked by anyone.
//
// Run by BOTH importers, and losable: set a write row's `pin` to null and this
// reds by route name, with or without a `why_no_pin` beside it.
export function pinHatchReport() {
  const reads = [];
  const bad = [];
  for (const entry of ROUTE_TIERS) {
    if (entry.pin) continue;
    if (/^GET\b/i.test(entry.key.trim())) {
      reads.push(entry);
      continue;
    }
    bad.push(entry.key + " names no PIN key and is NOT a read. The hatch exists for reads alone — the census PIN " +
      "is a WRITE call-site census, so a read has nothing to bind to and a WRITE always does. A write route with no " +
      "PIN key is a fence nothing re-reads: the band label `POST /v1/instances/:*/lifecycle` was exactly that shape, " +
      "cited a PIN row that never existed, and its verdict could not be lost by anyone. Bind it to a PIN row, or " +
      "take the route out of this table.");
  }
  return { ok: bad.length === 0, reads, bad };
}
