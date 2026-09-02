// member-authority-sweep.mjs — cch-w46-s7 (shipped in wave 50)
//
// THE INSTRUMENT THIS EPIC HAD NEVER BUILT. Not a call-graph, not a source-text
// scan: it BOOTS the member-actor scenarios through smoke.mjs's own shim and
// reads the RENDERED BYTES, enumerating every control the console actually
// paints for a plain member and failing closed on anything unaccounted for.
//
// It exists because the console's fencing idiom is HIDE-OR-DON'T-WIRE the
// element. A source scan sees the string; a call-graph sees the handler; only
// the rendered bytes see whether the member was OFFERED the door. D505 refuted
// two SOURCE-TEXT shapes and its own argument ("a call-graph instrument is
// blind to it BY CATEGORY") points at exactly this seam.
//
// Run: node cloud/priv/static/__preview__/member-authority-sweep.mjs
// Exit 0 clean · 1 findings/guard red · 2 crash.
//
// ── WHAT IT ASSERTS ──────────────────────────────────────────────────────────
//   1. ACCOUNTING. Every control rendered to a member on every member-actor
//      screen matches exactly one HOOKS row. A control with no row is
//      UNACCOUNTED and reds — enabled or not, hidden or not.
//   2. AUTHORITY. An ENABLED, OFFERED control whose row resolves to an ELEVATED
//      route (above plain team membership) is a FINDING and reds, unless it is
//      in KNOWN with a written reason.
//   3. The table's own health: DEAD ROW (a row matching nothing), UNFENCED (a
//      routed row whose fence is not stated — `unknown` is never a pass),
//      FLOOR / VACUOUS (a corpus that enumerated too little to mean anything).
//   4. Anti-vacuity, per screen: every member screen is paired with a PRIVILEGED
//      TWIN on the same deep link, and the twin must render MORE than the
//      member. A screen that painted nothing at all reds instead of passing.
//
// ── THE FIVE MEASURED FAIL-OPEN HOLES, AND HOW EACH IS CLOSED ────────────────
// H1  smoke.mjs's PARSED_TAGS is "button|a", so a <div role="button"> parses to
//     NOTHING and a sweep built on the shim's own parse is blind to it. CLOSED:
//     this file runs its OWN nesting-aware tag-stack scanner over the mount's
//     innerHTML, with a broad fail-closed control predicate — control TAGS, or
//     an interactive ARIA role, or onclick, or a focusable tabindex.
// H2  the `hidden` ATTRIBUTE is never reflected onto `.hidden` in the shim (and
//     the reverse is also true). CLOSED: hidden is the UNION of the byte-level
//     attribute (own tag AND every ancestor in the same html) and the element
//     PROPERTY — plus the CROSS-REGISTRY HOP: #inst-lifecycle-actions is a
//     registry entry with its own detached innerHTML, while the bytes that SITE
//     it inside #instance-body read `<div id="inst-lifecycle-actions" … hidden>`.
//     Read either side alone and half the fences vanish. Both directions are
//     proven live by assertHiddenUnionIsNecessary() below, which reds if either
//     single-sided read starts catching both cases.
// H3  document.querySelectorAll used to hard-return []; it is now a registry
//     sweep (cch-bl-smoke-document-attr-selectors-still-dead). CLOSED under
//     BOTH behaviours, because the closure never leaned on the hard-return:
//     enumeration is over the shim REGISTRY, never a document query, with a
//     per-screen vacuity guard and a global FLOOR.
// H4  getElementById AUTO-CREATES, so a lookup — or a .click() — is vacuously
//     true. CLOSED: nothing here infers "offered" from a lookup or a click
//     count. Presence of a JS-emitted control is read ONLY through its mount:
//     registry.get(mount).querySelectorAll("#id"), which answers over the
//     mount's parsed kids and can therefore return [].
// H5  the STATIC SHELL is invisible to a registry-bytes sweep: index.html's
//     controls live in no registry container, and smoke.mjs never reads that
//     file. PARTIALLY CLOSED, and the remainder is DECLARED: the two
//     statically-authored launch buttons are read through
//     parseStaticControlIds() (breakpoint-sweep.mjs) and their fence — a
//     .hidden PROPERTY no byte reflects — is resolved through the union. See
//     BLIND SPOTS for what that leaves.
//
// ── THE LOAD-BEARING RULE: A HIDDEN ANCESTOR IS A FENCE ONLY IF NOTHING POINTS
//    AT IT. #inst-cli-toggle carries aria-controls="inst-lifecycle-actions" and
//    is ENABLED for a member, so that disclosure is member-OPENABLE and its
//    contents are OFFERED. Honouring `hidden` naively defeats the instrument.
//    TWO-TIER VERDICTS: hidden downgrades the AUTHORITY verdict, never the
//    ACCOUNTING — a hidden control still needs a row.
//    PAIRED WITH A GUARD, because the rule reads only aria-controls and would
//    otherwise fail OPEN on a JS-only toggle: a container hidden in the bytes
//    that holds controls and has NO aria-controls pointer must be named in
//    CONCEALED with a reason, or it reds.
//
// ── GRAMMAR BOUNDARY (why nothing here is enumerated by tag selector) ────────
// The shim's element-level selector grammar is exactly four shapes — `.class`,
// `#id`, `[attr]`/`[attr="v"]`, `.class[attr]` (smoke.mjs's querySelectorAll).
// A BARE TAG selector matches none of them and returns a SILENT EMPTY LIST:
// card.querySelectorAll("button") answers 0 on a card that demonstrably holds
// one. Enumerating controls by tag name would therefore be vacuity by a
// different door, which is why enumeration is a byte scan and the only
// selectors used are `#id` ones scoped to a mount.
//
// ── NO ANCESTRY IS CLAIMED AT RUNTIME ────────────────────────────────────────
// closest() is a hard `return null` in the shim and parentNode is null for 100%
// of innerHTML-parsed controls (parseChildren never sets it). Any assertion
// shaped "this control is inside that container" would be a guaranteed vacuous
// green. Ancestry here is only ever STATIC — read out of the byte stack inside
// one html string, or out of the cross-registry siting scan — and every failure
// message says which of the two it means.
//
// ── TWO HONEST LIMITS (stated, not hidden) ───────────────────────────────────
// L1 COVERAGE IS CORPUS-BOUND. The actor set is DERIVED (a scenario whose own
//    GET /v1/me answers role === "member"), not typed — but it can only be as
//    wide as the committed corpus, which is 10 of 111 scenarios today. The
//    count is PINNED so corpus growth is NAMED rather than silently absorbed.
// L2 ROUTE ATTRIBUTION IN THE HOOK TABLE IS TYPED, NOT DERIVED. UNACCOUNTED and
//    DEAD ROW guard completeness in BOTH directions, but a row naming the WRONG
//    route is caught by nothing here. Deriving hook -> handler -> api() is
//    exactly D505's refuted problem and this file does not promise it. Each
//    row's fence cites the __binding_census.mjs PIN row it was read from; the
//    census remains the owner of route -> fence truth, and shipping a SECOND
//    derived table that could disagree with it is deliberately not done.
//
// ── BLIND SPOTS, NAMED ───────────────────────────────────────────────────────
// B1 the static shell beyond the launch pair: index.html authors ~24 buttons.
//    Only the two LAUNCH controls are asserted; the rest have no rendered mount
//    and no fence this sweep can read, so they are NOT covered. Silence would
//    have been the dishonest option.
// B2 statically-authored controls WITHOUT an id are not returned by the reader
//    at all (no stable identity to account for).
// B3 #github-disconnect (cch-w48-s3) is WATCHED but NOT ASSERTED: D535 measured
//    zero /v1/github handlers in the corpus, so every actor paints the "Not
//    configured" arm and the control is absent for owner and member alike. An
//    assertion there would pass on a DOM that never rendered it — an unlosable
//    green, which is how wave 48's crown failed. It is reported, never counted.
// B4 text content is not modelled by the shim's flat parse, so a control is
//    identified by tag/id/class/data-attrs and never by its label.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { bootScenario, makeDom, flush } from "./smoke.mjs";
import { SCENARIOS, SCENARIO_NAMES, route } from "./scenarios.mjs";
import { parseStaticControlIds } from "./breakpoint-sweep.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const INDEX_HTML = path.join(HERE, "..", "index.html");

const out = (s) => process.stdout.write(s);

// ── the byte scanner (H1) ────────────────────────────────────────────────────
const VOID_TAGS = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);
const TAG_RE = /<(\/?)([a-zA-Z][\w-]*)((?:"[^"]*"|'[^']*'|[^>"'])*?)(\/?)>/g;
const ATTR_RE = /([\w:.-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g;
const CONTROL_TAGS = new Set(["button", "a", "input", "select", "textarea", "form", "summary"]);
const CONTROL_ROLES = new Set(["button", "link", "menuitem", "switch", "tab", "checkbox", "radio", "option"]);
// Class tokens that describe STATE rather than identity. Folded out of the hook
// key so a row is not doubled by `is-active`; named here rather than silently
// stripped, because folding out the wrong token would merge two real controls.
const STATE_CLASSES = new Set(["is-active"]);

function parseAttrs(raw) {
  const a = Object.create(null);
  ATTR_RE.lastIndex = 0;
  let m;
  while ((m = ATTR_RE.exec(raw)) !== null) {
    const v = m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4] !== undefined ? m[4] : "";
    a[m[1].toLowerCase()] = v;
  }
  return a;
}

function isControl(tag, a) {
  if (CONTROL_TAGS.has(tag)) return true;
  if (a.role && CONTROL_ROLES.has(String(a.role).toLowerCase())) return true;
  if ("onclick" in a) return true;
  if (a.tabindex !== undefined && String(a.tabindex) !== "-1") return true;
  return false;
}

// A nesting-aware scan of one html STRING. Returns every control it holds, each
// carrying the STATIC ancestry facts read out of that same string: whether the
// control (or an open ancestor) declared `hidden`, and which ancestor id did.
export function scanControls(html) {
  const found = [];
  const containers = [];
  const stack = [];
  TAG_RE.lastIndex = 0;
  let m;
  while ((m = TAG_RE.exec(html)) !== null) {
    const closing = m[1] === "/";
    const tag = m[2].toLowerCase();
    if (closing) {
      for (let i = stack.length - 1; i >= 0; i--) {
        if (stack[i].tag === tag) { stack.length = i; break; }
      }
      continue;
    }
    const a = parseAttrs(m[3] || "");
    const selfClosing = m[4] === "/" || VOID_TAGS.has(tag);
    const hiddenHere = "hidden" in a;
    const hiddenAncestor = stack.find((s) => s.hidden) || null;
    const hidden = hiddenHere || !!hiddenAncestor;
    if (isControl(tag, a)) {
      found.push({
        tag,
        id: a.id || "",
        classes: String(a.class || "").split(/\s+/).filter(Boolean),
        data: Object.keys(a).filter((k) => k.startsWith("data-")).sort(),
        disabled: "disabled" in a,
        hiddenInBytes: hidden,
        hiddenOwnAttr: hiddenHere,
        // The nearest hidden ancestor's id, "" when it is anonymous, null when
        // there is none. STATIC, read inside this one string — never closest().
        hiddenBy: hiddenHere ? (a.id || "") : hiddenAncestor ? hiddenAncestor.id : null,
        role: a.role || "",
        ariaControls: a["aria-controls"] || "",
      });
    } else if (hiddenHere) {
      containers.push({ tag, id: a.id || "", hiddenOwnAttr: true });
    }
    if (!selfClosing) stack.push({ tag, hidden, id: a.id || "" });
  }
  return { controls: found, hiddenContainers: containers };
}

// The hook identity, DETERMINISTIC by construction (id first, then a SORTED
// data-attribute set, then SORTED class tokens minus state) — never
// first-attribute-wins, which produced the generic key `button.btn` for the
// disabled decommission and collides as the corpus widens.
export function hookKey(c) {
  if (c.id) return c.tag + "#" + c.id;
  const cls = c.classes.filter((x) => !STATE_CLASSES.has(x)).sort().map((x) => "." + x).join("");
  if (c.data.length) return c.tag + cls + c.data.map((d) => "[" + d + "]").join("");
  if (cls) return c.tag + cls;
  return c.tag;
}

// ── the fence vocabulary ─────────────────────────────────────────────────────
// ELEVATED = above plain team membership. Anything else is member-reachable.
// `unknown` exists ONLY so an author can be forced to answer: a routed row
// carrying it is an UNFENCED red, never a pass.
const F_MEMBER = "member";        // any team member may call it
const F_SELF = "self";            // self-scoped (your own account/token)
const F_CLIENT = "client";        // no route at all — navigation, clipboard, disclosure
const F_ADMIN = "elevated:team_admin";
const F_UNKNOWN = "unknown";
const ELEVATED = new Set([F_ADMIN]);

// ── THE HOOK TABLE ───────────────────────────────────────────────────────────
// One row per hook identity a member-actor screen can render. `route` is the
// route the hook calls (null for client-only), `fence` is that route's tier,
// `source` cites where the fence was read from — the __binding_census.mjs PIN
// row, or the markup itself for client-only controls. See LIMIT L2: these are
// TYPED, and a row naming the wrong route is caught by nothing here.
const HOOKS = [
  { key: "a", route: null, fence: F_CLIENT, what: "breadcrumb / bare in-app link", source: "markup: hash navigation" },
  { key: "a.inst-tab", route: null, fence: F_CLIENT, what: "instance detail tab", source: "markup: hash navigation" },
  { key: "a.nav-link.nav-sub", route: null, fence: F_CLIENT, what: "instance section nav", source: "markup: hash navigation" },
  { key: "a.site-open", route: null, fence: F_CLIENT, what: "open the live site URL", source: "markup: target=_blank anchor" },
  { key: "a.btn.btn-ghost.btn-sm.site-open", route: null, fence: F_CLIENT, what: "Visit button in the site detail head", source: "markup: target=_blank anchor" },
  { key: "button.copy-btn[data-copy]", route: null, fence: F_CLIENT, what: "copy a CLI command / id to the clipboard", source: "markup: data-copy delegate" },
  { key: "button#inst-open-studio", route: null, fence: F_CLIENT, what: "open Studio in a new tab", source: "markup: window.open" },
  { key: "button#inst-cli-toggle", route: null, fence: F_CLIENT, what: "disclose the bp CLI lifecycle rail", source: "markup: aria-controls disclosure" },
  { key: "button.deploy-console-toggle", route: null, fence: F_CLIENT, what: "expand a deploy's build console", source: "markup: local disclosure" },
  { key: "button.actfilter-chip[data-notif-del-axis][data-notif-del-value]", route: null, fence: F_CLIENT, what: "deliveries filter chip", source: "markup: client-side filter" },
  { key: "input#notif-del-event", route: null, fence: F_CLIENT, what: "deliveries event filter input", source: "markup: client-side filter" },
  { key: "button#notif-del-load-more", route: "GET /v1/notifications/deliveries", fence: F_MEMBER, what: "paginate deliveries", source: "census: read path; the inline-cond overlay records the deliveries route as a self-scope NARROWING, never a refusal" },
  { key: "button#site-new-btn", route: "POST /v1/sites", fence: F_MEMBER, what: "open the create-site modal", source: "census PIN: openCreateSiteModal — any member may create a site" },
  { key: "button#site-deploy", route: "POST /v1/sites/:*/deploy", fence: F_MEMBER, what: "deploy the site", source: "census PIN: runDeploy / createAndDeploy, ruling (a)" },
  { key: "button#site-rollback", route: "POST /v1/sites/:*/rollback", fence: F_MEMBER, what: "roll the site back", source: "census PIN: runSiteRollback, ruling (a)" },
  { key: "button.btn.btn-ghost.btn-sm.dep-promote[data-dep-id][data-kind]", route: "POST /v1/sites/:*/deployments/:*/promote", fence: F_MEMBER, what: "promote a deployment", source: "census PIN: runPromote, ruling (a)" },
  { key: "button#site-delete", route: "DELETE /v1/sites/:*", fence: F_MEMBER, what: "delete the site (destroy-tier confirm)", source: "census PIN: runSiteDelete — with_team_site {:ability,\"write\"} and a session carries [\"root\"], ruling (a); the INSTANCE Decommission is a different, higher band" },
  { key: "button#site-env-edit", route: "POST /v1/sites/:*/env", fence: F_MEMBER, what: "edit site env vars", source: "census PIN: openSiteEnvModal — team-scoped member action" },
  { key: "select#site-theme-select", route: "PATCH /v1/sites/:*", fence: F_MEMBER, what: "pin the deploy theme", source: "census PIN: loadSite, ruling (a)" },
  { key: "button.btn.btn-primary.btn-sm[data-vf-run]", route: "POST /v1/barkparks/:*/verify", fence: F_MEMBER, what: "run verification now", source: "census PIN: runVerifyNow — team-scoped member action" },
  { key: "button.btn.btn-ghost.btn-sm.token-revoke[data-id][data-name]", route: "DELETE /v1/tokens/:*", fence: F_SELF, what: "revoke your own token", source: "census PIN: confirmRevokeToken — self-scope" },
  { key: "button.btn.btn-ghost.btn-sm[data-life-retry]", route: null, fence: F_CLIENT, what: "retry the lifecycle read that failed", source: "markup: re-issues the same GET the view already made" },
  // The two DISABLED shapes. They still need rows — accounting is not
  // conditional on being enabled — and their fence is recorded as elevated so
  // that the day one of them renders ENABLED to a member, it is a FINDING and
  // not a silent new key.
  { key: "button.btn.btn-ghost.btn-sm", route: "POST /v1/instances/:*/lifecycle", fence: F_ADMIN, what: "instance lifecycle verb, drawn disabled-and-explained for a member (D428)", source: "census: the lifecycle band is team_admin; a member gets the disabled ghost with the grant sentence" },
  { key: "button.btn.btn-sm", route: "POST /v1/instances/:*/lifecycle", fence: F_ADMIN, what: "the CLI rail's lifecycle verb, drawn disabled for a member", source: "same band as the row above" },
];
const HOOK_BY_KEY = new Map(HOOKS.map((h) => [h.key, h]));

// ── watched JS-emitted controls, read ONLY through their mount (H4) ──────────
// `assert: true` means the corpus contains a PRIVILEGED arm that renders it, so
// absence for a member is a real, losable measurement. `assert: false` means it
// does not — and a pass there would be unlosable, so it is reported, never
// counted (BLIND SPOT B3).
const WATCHED = [
  {
    id: "site-github", mount: "site-body", scenario: "site-member", twin: "rollback",
    route: "POST /v1/sites/:*/github/connect", fence: F_ADMIN, assert: true,
    minted: "cch-w48-s2 (#10446) — siteDetailHtml emits #site-github only when the instance-band authority answers \"grant\"",
  },
  {
    id: "github-disconnect", mount: "github-card", scenario: "providers-member", twin: "providers-connected",
    route: "DELETE /v1/github/installation", fence: F_ADMIN, assert: false,
    minted: "cch-w48-s3 — githubCardHtml omits #github-disconnect unless providerCanWrite()",
    why_not: "D535: zero /v1/github handlers in the corpus, so EVERY actor paints the \"Not configured\" arm and the control is absent for owner and member alike. Asserting absence here would pass on a DOM that never rendered it",
  },
];

// ── the static shell's launch pair (H5) ──────────────────────────────────────
// Their fence is a `.hidden` PROPERTY app.js sets, which NO byte reflects — the
// exact case the union predicate exists for.
const STATIC_LAUNCH = ["overview-launch", "fleet-launch"];
const LAUNCH_ROUTE = "POST /v1/launch";
const LAUNCH_FENCE = F_ADMIN; // inline-cond overlay: go_live/1 refuses non-admins inside a cond

// ── CONCEALED: hidden containers with no pointer at them ─────────────────────
// The openability rule reads `aria-controls` and NOTHING else, so a JS-only
// toggle would otherwise absorb controls silently. Every hidden container that
// holds controls and has no pointer at it must be listed here with a reason AND
// a treatment:
//   treat: "offered" — hiding is STATE, not authority. Controls inside stay
//        OFFERED for the authority verdict, so moving an elevated control into
//        this container still reds. This is the fail-closed default and the
//        only honest answer for a container a script flips on data.
//   treat: "fence"   — the container genuinely withholds from this actor. The
//        controls inside are authority-downgraded. Use it only when the thing
//        that sets `hidden` is reading AUTHORITY, and say where.
// SYMMETRIC: an entry that stops being a hidden control-bearing container reds,
// so a stale exemption cannot outlive the markup it excused.
const CONCEALED = [
  {
    id: "notif-del-more", treat: "offered",
    why: "PAGINATION STATE, NOT A FENCE: toggleNotifDeliveryMore(show) sets `wrap.hidden = !show` from whether the " +
      "deliveries read returned another page — it never reads role or authority. So its one control " +
      "(#notif-del-load-more, a GET on the same log the screen already loaded) stays OFFERED for the authority " +
      "verdict, and an elevated control moved in here would still red.",
  },
];
const CONCEALED_BY_ID = new Map(CONCEALED.map((c) => [c.id, c]));
// A hidden container is only a fence if nothing points at it AND it is not
// declared state. Anything else is treated as OFFERED — fail closed.
function containerFences(id, openable) {
  if (openable.has(id)) return false;
  const listed = CONCEALED_BY_ID.get(id);
  if (listed) return listed.treat === "fence";
  return true;
}

// ── KNOWN: findings this sweep accepts, each with a written reason ───────────
// SYMMETRIC BY DESIGN: an entry that stops reproducing reds as loudly as a new
// finding, so a fixed defect cannot stay frozen here as "expected".
// It ships EMPTY because the wave-47/48/49 fixes landed first — this sweep was
// deliberately sequenced last so its baseline would not bless live defects.
const KNOWN = [
  // { scenario: "…", key: "…", why: "…" },
];

// ── PINS ─────────────────────────────────────────────────────────────────────
// Derived-but-pinned, so corpus growth is NAMED rather than silently absorbed
// (LIMIT L1). Update them in the same commit that grows the corpus.
const PIN_MEMBER_SCENARIOS = 10;
// 114 -> 115: cch-w37-bl-operator-retry-click-undriven added `operator-me-recovers`
// (the one-shot /v1/me fault whose retry smoke.mjs clicks). RE-DERIVED by running
// this sweep, not by adding one: its actor is an OPERATOR, so the member slice
// above is unmoved and PIN_MEMBER_SCENARIOS stays at 10 — bumping it to match
// would red this sweep on actor-set instead.
// 115 -> 116: cch-deploy-detail-render-has-no-cap added `deploy-detail-cruel`
// (the deploy sub-caption at its 2 KB store cap, beside the ordinary builder
// caption that is its control — the fixture overflow-guard.mjs's
// W34-deploy-detail-render-bound leg measures). RE-DERIVED by running this
// sweep and reading the number it PRINTED, not by adding one. Its actor is the
// same owner `me("Acme Inc", …)` every site-detail scenario carries, so the
// member slice is unmoved and PIN_MEMBER_SCENARIOS stays at 10.
// 116 -> 119: cch-w45-bl-four-rail-verbs added `instance-behind`,
// `instance-remove-failed` and `verify-no-credentials` — the three instance
// states that make #inst-update, #inst-remove-retry and [data-vf-reprovision]
// render at all. RE-DERIVED by running this sweep and reading the number it
// PRINTED, not by adding three. All three carry the same owner actor
// `me("Acme Inc", …)` the rest of the instance corpus does, so the member slice
// is unmoved and PIN_MEMBER_SCENARIOS stays at 10 — the member arm of these
// verbs is pinned in __app.test.mjs's cch-w38-s1 eleven-offer table, which
// asserts both directions on all seven.
// 119 -> 120 (cch-w29, PR #15265): `site-deploy-rail-live` — the first live-footer
// deploy-rail fixture — joins the corpus so the W29 overflow leg has a scenario to
// drive. RE-DERIVED by running this sweep and reading the number it PRINTED (the
// corpus-size guard said "120 committed (pinned 119)"). It carries the same owner
// actor `me("Acme Inc", …)` as every site-detail scenario, so the member slice is
// unmoved and PIN_MEMBER_SCENARIOS stays at 10 (69 controls accounted).
// 120 -> 121: cch-w23-bl-cruel-identity-own-scenario added
// `account-modal-cruel-identity` — the 158-character email local part that used
// to ride `account-modal-revoke`, where it silently drove smoke.mjs's click
// oracle. THIS PIN IS ONE OF THE FOUR CENSUSES that made the wave-23 slice park
// the identity on an existing key instead of minting one; all four are taught in
// the same commit. RE-DERIVED by running this sweep and reading the number it
// PRINTED, not by adding one. Its actor is the same owner `me("Guerrilla")`
// every account-modal scenario carries — only the email differs — so the member
// slice is unmoved and PIN_MEMBER_SCENARIOS stays at 10.
const PIN_TOTAL_SCENARIOS = 121;
// FLOOR, not an equality: an added control must not force a table churn, but a
// corpus that suddenly enumerates almost nothing is vacuous and reds. 66 today.
const FLOOR_CONTROLS = 60;
const FLOOR_MOUNTS = 20;

function meRole(name) {
  try {
    const r = route(name, "GET", "/v1/me", {});
    return r && r.body ? r.body.role || null : null;
  } catch (e) {
    return null;
  }
}

// ── the hidden UNION, and the proof that it needs both halves ────────────────
// Byte-attribute side ‖ element-property side ‖ the cross-registry siting hop.
function elementHiddenUnion(el) {
  if (!el) return { hidden: false, byProperty: false, byAttribute: false };
  const byProperty = el.hidden === true;
  const byAttribute = typeof el.hasAttribute === "function" && el.hasAttribute("hidden");
  return { hidden: byProperty || byAttribute, byProperty, byAttribute };
}

// Both directions are LIVE in this shim and each single-sided read misses one.
// If either single-sided form starts catching BOTH, the shim changed under this
// instrument and the union's justification is stale — so that reds too.
function assertHiddenUnionIsNecessary() {
  const bad = [];
  // The ONLY getElementById calls in this file, and they are CONSTRUCTION, not
  // measurement: this is a fresh empty DOM, and auto-create is exactly how one
  // mints a registry element to test the shim's semantics with. Nothing about
  // the console is read here. Every real read goes through a mount's scoped
  // querySelectorAll (H4).
  const { document } = makeDom();
  // Case A — a PARSED CHILD authored `hidden` in a markup string. setAttribute
  // reflects only class and id, so the property stays false.
  const mount = document.getElementById("union-probe-mount");
  mount.innerHTML = '<button id="union-a" hidden type="button">x</button>';
  const parsed = mount.querySelectorAll("#union-a")[0];
  // Case B — a REGISTRY element assigned `.hidden = true`. Nothing writes the
  // attribute, so the attribute stays absent. This is how app.js fences the
  // static launch buttons (77 `.hidden = ` sites).
  const registryEl = document.getElementById("union-b");
  registryEl.hidden = true;

  if (!parsed) bad.push("case A did not parse at all — the shim's sub-tree #id reader moved, and every scoped read in this file rides on it");
  const a = elementHiddenUnion(parsed);
  const b = elementHiddenUnion(registryEl);
  if (!a.hidden) bad.push("case A (markup `hidden`) is not resolved hidden by the union — a fence authored in bytes would be read as OFFERED");
  if (!b.hidden) bad.push("case B (`.hidden = true`) is not resolved hidden by the union — a fence set as a property would be read as OFFERED");
  if (a.byProperty) bad.push("case A now reports .hidden === true: the shim started reflecting the attribute onto the property. The union is no longer justified by THIS case — re-derive it before deleting either half");
  if (!a.byAttribute) bad.push("case A no longer reports hasAttribute(\"hidden\") — the attribute-side read is dead and property-only would miss it silently");
  if (b.byAttribute) bad.push("case B now reports hasAttribute(\"hidden\"): the shim started reflecting the property onto the attribute. Re-derive the union");
  if (!b.byProperty) bad.push("case B no longer reports .hidden === true — the property-side read is dead");
  out("  " + (bad.length ? "FAIL" : "ok  ") + " hidden-union    — property-only misses markup `hidden` (" +
    a.byAttribute + "/" + a.byProperty + "), attribute-only misses `.hidden = true` (" +
    b.byAttribute + "/" + b.byProperty + ") — the guard defends against the SHIM's non-reflection, not a browser behaviour\n");
  return bad;
}

// Where a mount is SITED: scan every OTHER registry entry's bytes for a tag
// carrying id="<mount>" and report whether that tag (or an open ancestor in the
// same string) declared `hidden`. This is the cross-registry hop — a registry
// entry's own innerHTML is detached and can never show its own siting.
function sitingHidden(registry, mountId) {
  const idRe = new RegExp('\\bid="' + mountId.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + '"');
  for (const [otherId, el] of registry) {
    if (otherId === mountId) continue;
    const html = el && typeof el.innerHTML === "string" ? el.innerHTML : "";
    if (!html || !idRe.test(html)) continue;
    const stack = [];
    TAG_RE.lastIndex = 0;
    let m;
    while ((m = TAG_RE.exec(html)) !== null) {
      const closing = m[1] === "/";
      const tag = m[2].toLowerCase();
      if (closing) {
        for (let i = stack.length - 1; i >= 0; i--) if (stack[i].tag === tag) { stack.length = i; break; }
        continue;
      }
      const a = parseAttrs(m[3] || "");
      const hiddenHere = "hidden" in a;
      const hidden = hiddenHere || stack.some((s) => s.hidden);
      if (a.id === mountId) return { sited: true, hidden, in: otherId };
      if (!(m[4] === "/" || VOID_TAGS.has(tag))) stack.push({ tag, hidden });
    }
  }
  // A container sited NOWHERE is treated as VISIBLE — fail closed. index.html's
  // static `hidden` is BOOT state, and a mount whose siting we cannot find must
  // not be credited with a fence nobody proved.
  return { sited: false, hidden: false, in: null };
}

// Every id an ENABLED control points at with aria-controls, anywhere in the
// boot. A hidden container in this set is member-OPENABLE, so it is not a fence.
function openableIds(scans) {
  const ids = new Set();
  for (const s of scans) {
    for (const c of s.controls) {
      if (c.ariaControls && !c.disabled) for (const id of c.ariaControls.split(/\s+/)) if (id) ids.add(id);
    }
  }
  return ids;
}

// Boots are expensive (each one evaluates the whole shipped app.js in a vm), and
// several guards read the same screen. Memoized per RUN, never across runs.
const SURVEYS = new Map();
async function surveyScenario(name) {
  if (SURVEYS.has(name)) return SURVEYS.get(name);
  const s = await surveyScenarioUncached(name);
  SURVEYS.set(name, s);
  return s;
}

async function surveyScenarioUncached(name) {
  const boot = bootScenario(name, {});
  await flush();
  const registry = boot.registry;
  const mounts = [];
  for (const [id, el] of registry) {
    const html = el && typeof el.innerHTML === "string" ? el.innerHTML : "";
    if (!html) continue;
    const scan = scanControls(html);
    mounts.push({ id, el, html, ...scan });
  }
  const openable = openableIds(mounts);
  const controls = [];
  const concealedContainers = [];
  for (const mount of mounts) {
    const own = elementHiddenUnion(mount.el);
    const siting = sitingHidden(registry, mount.id);
    const mountHidden = own.hidden || siting.hidden;
    // The mount's own fence only counts if nothing points at it and it is not
    // declared pagination/state in CONCEALED.
    const mountFenced = mountHidden && containerFences(mount.id, openable);
    for (const c of mount.controls) {
      const byteFenced = c.hiddenInBytes &&
        (c.hiddenOwnAttr ? containerFences(c.id, openable) : containerFences(c.hiddenBy || "", openable));
      controls.push({
        ...c,
        key: hookKey(c),
        mount: mount.id,
        fencedByHidden: byteFenced || mountFenced,
        hiddenWhy: byteFenced
          ? (c.hiddenOwnAttr ? "its own `hidden` attribute" : "a hidden ancestor" + (c.hiddenBy ? " #" + c.hiddenBy : "") + " in #" + mount.id + "'s bytes")
          : mountFenced
            ? (own.hidden ? "the mount #" + mount.id + " is hidden (" + (own.byProperty ? "property" : "attribute") + ")"
              : "the bytes that SITE #" + mount.id + " inside #" + siting.in + " carry `hidden`")
            : null,
      });
    }
    for (const cont of mount.hiddenContainers) {
      // A hidden container is only interesting if it actually holds controls,
      // which the byte stack already told us via hiddenBy.
      const holds = mount.controls.filter((c) => c.hiddenInBytes && !c.hiddenOwnAttr && c.hiddenBy === cont.id);
      if (holds.length && !openable.has(cont.id)) concealedContainers.push({ id: cont.id, mount: mount.id, holds: holds.length });
    }
    if (mountHidden && !openable.has(mount.id) && mount.controls.length) {
      concealedContainers.push({ id: mount.id, mount: mount.id, holds: mount.controls.length });
    }
  }
  return { name, registry, mounts, controls, concealedContainers, openable };
}

// ── the host boundary, guarded in a CHILD process ────────────────────────────
// This sweep can only exist because smoke.mjs became importable. That boundary
// has two halves and BOTH are load-bearing: `node smoke.mjs` must still run the
// whole corpus, and `import("./smoke.mjs")` must run NOTHING. The second half is
// not the main-guard alone — a top-level `await` executes at import time no
// matter what guards the tail call, which is why smoke.mjs's two harness guards
// had to move inside main().
//
// It runs in a CHILD because the measurement is destroyed by taking it: this
// process has already imported smoke.mjs by the time main() runs. The child
// stubs process.exit (so a corpus that DID run cannot kill it silently), counts
// bytes written to both streams, and counts vm.runInContext calls — the exact
// operation a scenario boot performs — then reports on fd 2 only.
const SILENCE_PROBE = `
import vm from "node:vm";
let boots = 0;
const realRun = vm.runInContext.bind(vm);
vm.runInContext = (...a) => { boots++; return realRun(...a); };
let bytes = 0, exits = 0;
const rw = process.stdout.write.bind(process.stdout);
const ew = process.stderr.write.bind(process.stderr);
process.stdout.write = (c) => { bytes += Buffer.byteLength(c); return true; };
process.stderr.write = (c) => { bytes += Buffer.byteLength(c); return true; };
const rex = process.exit.bind(process);
process.exit = () => { exits++; };
const mod = await import(process.env.BP_SILENCE_PROBE_TARGET);
process.stdout.write = rw; process.stderr.write = ew; process.exit = rex;
ew(JSON.stringify({ bytes, exits, boots, exports: Object.keys(mod).sort() }) + "\\n");
`;
// THE TARGET TRAVELS IN THE ENVIRONMENT, NOT IN argv — and that is not a style
// choice. smoke.mjs's own entry guard reads process.argv[1]; handing the child
// the smoke path as an argument makes that guard answer TRUE and the child runs
// the entire corpus, which is a probe measuring its own harness. Measured: with
// the path in argv the probe reported boots=1 on a module that boots nothing.

function assertSmokeImportIsSilent() {
  const bad = [];
  const smoke = path.join(HERE, "smoke.mjs");
  const r = spawnSync(process.execPath, ["--input-type=module", "-e", SILENCE_PROBE], {
    encoding: "utf8",
    env: { ...process.env, BP_SILENCE_PROBE_TARGET: smoke },
  });
  let m = null;
  try { m = JSON.parse(String(r.stderr).trim().split("\n").pop()); } catch (e) { m = null; }
  if (!m) {
    bad.push("the import-silence probe did not report: rc=" + r.status + " stderr=" + JSON.stringify(String(r.stderr).slice(-400)));
    out("  FAIL import-silence — the probe did not report\n");
    return bad;
  }
  if (m.bytes !== 0) bad.push("importing smoke.mjs wrote " + m.bytes + " byte(s). Something still runs at module scope — check for a top-level `await`, which fires on import no matter what guards main().");
  if (m.boots !== 0) bad.push("importing smoke.mjs booted " + m.boots + " scenario(s) (counted at vm.runInContext). The module boundary is gone and this sweep is paying for a corpus run it never asked for.");
  if (m.exits !== 0) bad.push("importing smoke.mjs called process.exit " + m.exits + " time(s) — an importer would be killed by its host.");
  for (const want of ["bootScenario", "flush"]) {
    if (m.exports.indexOf(want) === -1) bad.push("smoke.mjs no longer exports " + want + "; this sweep's whole corpus read hangs off it.");
  }
  out("  " + (bad.length ? "FAIL" : "ok  ") + " import-silence  — import(\"./smoke.mjs\") wrote " + m.bytes +
    " byte(s), booted " + m.boots + " scenario(s), called process.exit " + m.exits + " time(s); exports [" +
    m.exports.join(", ") + "]\n");
  return bad;
}

async function main() {
  out("member-authority-sweep — rendered-state member-actor authority (cch-w46-s7)\n\n");
  const broken = [];

  // 0 — the host boundary and the shim's own hidden semantics, before anything
  // reads either.
  broken.push(...assertSmokeImportIsSilent());
  broken.push(...assertHiddenUnionIsNecessary());

  // 1 — the actor set, DERIVED and PINNED.
  const members = SCENARIO_NAMES.filter((n) => meRole(n) === "member");
  out("  " + (members.length === PIN_MEMBER_SCENARIOS ? "ok  " : "FAIL") + " actor-set       — " +
    members.length + " scenario(s) whose own GET /v1/me answers role=\"member\", of " + SCENARIO_NAMES.length +
    " committed (pinned " + PIN_MEMBER_SCENARIOS + "/" + PIN_TOTAL_SCENARIOS + ")\n");
  if (members.length !== PIN_MEMBER_SCENARIOS) {
    broken.push("the member-actor corpus is " + members.length + ", pinned at " + PIN_MEMBER_SCENARIOS + ". " +
      "Coverage here is corpus-bound (LIMIT L1), so growth must be NAMED: if a new member scenario landed, add its " +
      "controls' rows to HOOKS and raise the pin in the SAME commit. If one disappeared, say which and why.");
  }
  // The total pin is a GUARD, not a note: a printed line the workflow cannot see
  // is not a guard at all (the sweep runs as a bare `run:` step, so the exit code
  // is the entire verdict). It reds in BOTH directions and NAMES which one.
  const corpusDrift = SCENARIO_NAMES.length - PIN_TOTAL_SCENARIOS;
  const corpusDirection = corpusDrift > 0 ? "grew" : "shrank";
  out("  " + (corpusDrift === 0 ? "ok  " : "FAIL") + " corpus-size     — " + SCENARIO_NAMES.length +
    " scenario(s) committed (pinned " + PIN_TOTAL_SCENARIOS + ")" +
    (corpusDrift === 0 ? "" : " — the corpus " + corpusDirection + " by " + Math.abs(corpusDrift)) + "\n");
  if (corpusDrift !== 0) {
    broken.push("the committed corpus " + corpusDirection + " to " + SCENARIO_NAMES.length + " scenario(s), pinned at " +
      PIN_TOTAL_SCENARIOS + ". Re-derive by RUNNING this sweep and set PIN_TOTAL_SCENARIOS to the number it PRINTS — " +
      "never pin ± 1, because one commit can move the corpus by more than one. PIN_MEMBER_SCENARIOS moves ONLY if " +
      "the member slice itself moved (the actor-set line above says how many scenarios answer role=\"member\"); do not " +
      "bump it to match the total, or this sweep reds on actor-set instead.");
  }

  // 2 — survey each member screen, and its privileged twin as the positive control.
  const seenKeys = new Set();
  const findings = [];
  const reproduced = new Set();
  let totalControls = 0;
  let totalMounts = 0;

  for (const name of members) {
    const deepLink = SCENARIOS[name].deepLink || "";
    const twins = SCENARIO_NAMES.filter((n) => n !== name && (SCENARIOS[n].deepLink || "") === deepLink &&
      meRole(n) && meRole(n) !== "member");
    const survey = await surveyScenario(name);
    totalControls += survey.controls.length;
    totalMounts += survey.mounts.length;

    // ANTI-VACUITY, per screen: the privileged twin must render MORE controls
    // than the member. A screen that painted nothing at all — or a sweep that
    // went blind on it — reds here instead of passing as "no elevated control".
    let twinLine = "no privileged twin on " + deepLink;
    let twinControls = -1;
    if (!twins.length) {
      broken.push(name + ": no privileged twin renders " + deepLink + ", so there is no positive control for this " +
        "screen and \"the member is offered nothing elevated\" is unfalsifiable here. Commit an owner/admin scenario " +
        "on the same deep link.");
    } else {
      const twin = twins[0];
      const tw = await surveyScenario(twin);
      twinControls = tw.controls.length;
      twinLine = twin + " renders " + twinControls;
      if (twinControls === 0) {
        broken.push(name + ": the positive control " + twin + " (role " + meRole(twin) + ") rendered ZERO controls " +
          "too — this sweep is BLIND on " + deepLink + ", so the member verdict is vacuous, not clean.");
      } else if (twinControls <= survey.controls.length && survey.controls.length === 0) {
        broken.push(name + ": positive control " + twin + " did not out-render the member on " + deepLink);
      }
    }

    for (const c of survey.controls) {
      seenKeys.add(c.key);
      const row = HOOK_BY_KEY.get(c.key);
      if (!row) {
        broken.push("UNACCOUNTED " + name + " #" + c.mount + " → " + c.key +
          (c.disabled ? " [disabled]" : " [ENABLED]") + (c.fencedByHidden ? " [hidden]" : "") +
          ": a control rendered to a MEMBER that no HOOKS row claims. Name its route and its fence, or it is an " +
          "unfenced offer nobody decided on.");
        continue;
      }
      if (row.fence === F_UNKNOWN) {
        broken.push("UNFENCED " + name + " → " + c.key + " (" + (row.route || "no route recorded") +
          "): the row's fence is `unknown`, and unknown is never a pass.");
        continue;
      }
      const elevated = ELEVATED.has(row.fence);
      const offered = !c.disabled && !c.fencedByHidden;
      if (elevated && offered) {
        const known = KNOWN.find((k) => k.scenario === name && k.key === c.key);
        if (known) { reproduced.add(name + "|" + c.key); continue; }
        findings.push({ scenario: name, mount: c.mount, key: c.key, route: row.route, what: row.what });
      }
    }

    const enabled = survey.controls.filter((c) => !c.disabled).length;
    const fenced = survey.controls.filter((c) => c.fencedByHidden).length;
    out("  ok   " + name.padEnd(28) + " " + String(survey.mounts.length).padStart(2) + " mount(s) · " +
      String(survey.controls.length).padStart(2) + " control(s) · " + enabled + " enabled · " + fenced +
      " hidden-fenced · positive control: " + twinLine + "\n");
  }

  // 3 — the table's own health.
  const dead = HOOKS.filter((h) => !seenKeys.has(h.key));
  out("  " + (dead.length ? "FAIL" : "ok  ") + " table-health    — " + HOOKS.length + " row(s), " + seenKeys.size +
    " key(s) rendered, " + dead.length + " dead row(s)\n");
  for (const d of dead) {
    broken.push("DEAD ROW " + d.key + " (" + (d.route || "client-only") + "): the table claims a control the member " +
      "corpus never renders. Either it moved — in which case the sweep is now blind to it — or the row is stale.");
  }
  for (const k of KNOWN) {
    if (!reproduced.has(k.scenario + "|" + k.key)) {
      broken.push("KNOWN NO LONGER REPRODUCES " + k.scenario + " → " + k.key + ": it was accepted because \"" + k.why +
        "\". A finding that stopped reproducing must be DELETED from KNOWN in the commit that fixed it, not left " +
        "blessing a defect that no longer exists.");
    }
  }

  // 4 — the floor. The only remaining defence against a corpus that renders
  // nothing and passes.
  const floorOk = totalControls >= FLOOR_CONTROLS && totalMounts >= FLOOR_MOUNTS;
  out("  " + (floorOk ? "ok  " : "FAIL") + " floor           — " + totalControls + " control(s) over " + totalMounts +
    " mount(s) examined (floor " + FLOOR_CONTROLS + "/" + FLOOR_MOUNTS + ")\n");
  if (!floorOk) {
    broken.push("FLOOR/VACUOUS: the sweep examined " + totalControls + " control(s) over " + totalMounts +
      " mount(s), below the floor of " + FLOOR_CONTROLS + "/" + FLOOR_MOUNTS + ". A green over an empty corpus " +
      "measures the harness, not the console.");
  }

  // 5 — the CONCEALED guard: a hidden container nothing points at.
  const concealed = [];
  for (const name of members) {
    const s = await surveyScenario(name);
    for (const c of s.concealedContainers) concealed.push({ scenario: name, ...c });
  }
  const unlisted = concealed.filter((c) => !CONCEALED.find((x) => x.id === c.id));
  out("  " + (unlisted.length ? "FAIL" : "ok  ") + " concealed       — " + concealed.length +
    " hidden container(s) holding controls, " + CONCEALED.length + " listed, " + unlisted.length + " unlisted\n");
  for (const c of unlisted) {
    broken.push("CONCEALED " + c.scenario + ": #" + c.id + " is hidden in the bytes, holds " + c.holds +
      " control(s), and NO enabled control points at it with aria-controls. Either it is a real fence — then list it " +
      "in CONCEALED with the reason — or it is a JS-only toggle, in which case those controls are OFFERED and this " +
      "sweep was about to absorb them silently.");
  }
  for (const c of CONCEALED) {
    if (!concealed.find((x) => x.id === c.id)) {
      broken.push("CONCEALED NO LONGER REPRODUCES #" + c.id + " (\"" + c.why + "\"): it is no longer a hidden " +
        "container holding controls. Delete the entry rather than leaving a stale exemption standing.");
    }
  }

  // 6 — the WATCHED JS-emitted controls, read ONLY through their mount.
  for (const w of WATCHED) {
    const memberSurvey = await surveyScenario(w.scenario);
    const mountEl = memberSurvey.registry.has(w.mount) ? memberSurvey.registry.get(w.mount) : null;
    // NEVER getElementById / $(): both AUTO-CREATE the element, which makes
    // absence and offered-ness indistinguishable. This reads the mount's own
    // parsed kids, which can answer [].
    const hereN = mountEl ? mountEl.querySelectorAll("#" + w.id).length : -1;
    if (!w.assert) {
      out("  note #" + w.id + " watched but NOT asserted (" + w.route + "): " + w.why_not +
        ". Member arm renders " + hereN + "; reported, never counted.\n");
      continue;
    }
    const twinSurvey = await surveyScenario(w.twin);
    const twinMount = twinSurvey.registry.has(w.mount) ? twinSurvey.registry.get(w.mount) : null;
    const twinN = twinMount ? twinMount.querySelectorAll("#" + w.id).length : -1;
    const ok = hereN === 0 && twinN >= 1;
    out("  " + (ok ? "ok  " : "FAIL") + " #" + w.id.padEnd(15) + " — " + w.route + " · scoped through registry.get(\"" +
      w.mount + "\").querySelectorAll(\"#" + w.id + "\"): member " + w.scenario + " → " + hereN + ", privileged " +
      w.twin + " → " + twinN + "\n");
    if (twinMount === null) {
      broken.push("#" + w.id + ": the mount #" + w.mount + " is not in the privileged twin's registry either — there " +
        "is no positive control, so \"absent for a member\" is unlosable here.");
    } else if (twinN < 1) {
      broken.push("#" + w.id + ": the PRIVILEGED actor " + w.twin + " does not render it either, so the member's " +
        "absence proves nothing. The fence (" + w.minted + ") may have been reverted into an omit-for-everyone.");
    } else if (hereN !== 0) {
      broken.push("#" + w.id + " IS OFFERED TO A MEMBER on " + w.scenario + " (" + w.route + ", " + w.fence + "). " +
        "The fence that withheld it — " + w.minted + " — is gone: the privileged arm renders " + twinN + " and the " +
        "member arm now renders " + hereN + ". The server refuses this write; the console must not offer it.");
    }
  }

  // 7 — the static shell's launch pair (H5). Their fence is a `.hidden`
  // PROPERTY, which is exactly why the union predicate above is not decorative.
  const staticIds = parseStaticControlIds(fs.readFileSync(INDEX_HTML, "utf8"));
  const missing = STATIC_LAUNCH.filter((id) => staticIds.indexOf(id) === -1);
  out("  " + (missing.length ? "FAIL" : "ok  ") + " static-shell    — index.html declares " + staticIds.length +
    " id-bearing control(s); the launch pair " + STATIC_LAUNCH.map((i) => "#" + i).join(", ") +
    (missing.length ? " is MISSING " + missing.join(", ") : " is present") + "\n");
  if (missing.length) {
    broken.push("the static reader no longer finds " + missing.map((i) => "#" + i).join(", ") + " in index.html. " +
      "Either the launch control moved into app.js (then it belongs to the scoped-mount half, not here) or it was " +
      "renamed — either way this half of the sweep just went blind and must be re-pointed, not deleted.");
  }
  for (const name of members) {
    const boot = bootScenario(name, {});
    await flush();
    for (const id of STATIC_LAUNCH) {
      if (missing.indexOf(id) !== -1) continue;
      // registry.has(), never byId(): byId AUTO-CREATES and would manufacture a
      // pristine (visible, enabled) element for a control the boot never touched.
      if (!boot.registry.has(id)) continue;
      const el = boot.registry.get(id);
      const u = elementHiddenUnion(el);
      if (!u.hidden && !el.disabled) {
        findings.push({ scenario: name, mount: "index.html", key: "button#" + id, route: LAUNCH_ROUTE,
          what: "the statically-authored launch button, left VISIBLE and enabled for a member (fence is a .hidden property)" });
      }
    }
  }
  // The positive control for the launch pair: a privileged actor on #overview
  // must leave at least one of them visible, or "hidden for a member" is a
  // property nobody set rather than a fence somebody wrote.
  {
    const twin = SCENARIO_NAMES.find((n) => (SCENARIOS[n].deepLink || "") === "#overview" && meRole(n) === "owner");
    const boot = bootScenario(twin, {});
    await flush();
    // GATED ON THE STATIC READER, and that gate is load-bearing: a registry
    // entry proves nothing on its own, because app.js's own $("#id") lookup
    // AUTO-CREATES a pristine (visible, enabled) element for an id index.html
    // no longer declares. Measured: with #fleet-launch deleted from index.html
    // this check still reported it "visible" until the reader gated it.
    const declared = STATIC_LAUNCH.filter((id) => staticIds.indexOf(id) !== -1);
    const visible = declared.filter((id) => boot.registry.has(id) && !elementHiddenUnion(boot.registry.get(id)).hidden);
    out("  " + (visible.length ? "ok  " : "FAIL") + " launch-fence    — privileged " + twin + " leaves " +
      visible.length + " of " + declared.length + " declared launch button(s) visible (" +
      (visible.map((i) => "#" + i).join(", ") || "none") + ")\n");
    if (!visible.length) {
      broken.push("no privileged actor on #overview renders EITHER launch button visible, so \"hidden for a member\" " +
        "is unlosable: the .hidden property could be set for everyone (or never read) and this check would still pass.");
    }
  }

  // ── verdict ────────────────────────────────────────────────────────────────
  out("\n");
  for (const f of findings) {
    out("  FINDING " + f.scenario + " #" + f.mount + " → " + f.key + "\n" +
      "          " + f.what + "\n" +
      "          route " + f.route + " is ELEVATED above plain team membership; the member is being offered a write " +
      "the server will refuse.\n");
  }
  if (broken.length) {
    out("\nguard(s) failed:\n");
    for (const b of broken) out("  · " + b + "\n");
  }
  const bad = findings.length + broken.length;
  out("\n>> member-authority " + members.length + " member actor(s) · " + totalControls + " control(s) accounted · " +
    HOOKS.length + " hook row(s) · " + findings.length + " finding(s) · " + broken.length + " guard failure(s) — exit " +
    (bad ? 1 : 0) + "\n");
  return bad ? 1 : 0;
}

// Importable (nothing imports it today; the guard keeps that door honest and
// matches breakpoint-sweep.mjs / smoke.mjs) — only run when executed.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main()
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write("\n!! MEMBER AUTHORITY SWEEP (exit 2): unhandled — " + (err && err.stack ? err.stack : err) + "\n");
      process.exit(2);
    });
}
