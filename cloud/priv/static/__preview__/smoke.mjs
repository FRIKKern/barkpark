// smoke.mjs — a standalone node:vm smoke runner for the Cloud SPA preview harness.
//
// It BOOTS the shipped app.js (verbatim, no exports) inside a node:vm sandbox
// against each committed scenario's fixtures and asserts the expected view
// SKELETON rendered. Unlike __app.test.mjs (which keeps init() unbound to pin
// pure helpers), this harness sets document.readyState = "complete" so init()
// runs the real render → route → load path, with:
//   • window.fetch     routed to scenarios.route(scen, …)  (no backend)
//   • window.EventSource an inert stub                     (deterministic)
//   • a minimal but faithful DOM shim so innerHTML is observable afterwards.
//
// Assertions are STRUCTURAL (element / class presence, row counts) and live in
// the EXPECTATIONS table below — NOT in the harness. A4 will rewrite the SPA's
// onboarding / timeline / fleet markup; when it does, only EXPECTATIONS needs
// updating, never the boot machinery.
//
// Run: node smoke.mjs      (exits non-zero on any failed assertion)

import assert from "node:assert/strict";
import vm from "node:vm";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import {
  SCENARIOS, SCENARIO_NAMES, route,
  IDS as SCEN_IDS,
  RAIL_FAIL_CRUEL_DETAIL as SCEN_RAIL_CRUEL_DETAIL,
  DEPLOY_DETAIL_CRUEL as SCEN_DEPLOY_DETAIL_CRUEL,
  DEPLOY_DETAIL_KIND as SCEN_DEPLOY_DETAIL_KIND,
  DEPLOY_DETAIL_STORE_CAP as SCEN_DEPLOY_DETAIL_STORE_CAP,
} from "./scenarios.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_JS = fs.readFileSync(path.join(HERE, "..", "app.js"), "utf8");

// ── index.html's shipped `hidden` (cch-w43-s6) ───────────────────────────────
// The shim used to default EVERY element to hidden:false, and never read
// index.html at all. That default is not neutral — it is a CLAIM, and the
// shipped page contradicts it on 38 elements. #team-menu is one of them
// (`<div class="team-menu" id="team-menu" role="menu" hidden>`), so the first
// #ws-switch click CLOSED an already-closed menu and only the second opened
// it. A check written against that boot state pins the SHIM's invention as the
// app's contract and would go red against a correct app — the harness judging
// the app by state the harness made up.
//
// Scanned with the same flat open-tag grammar parseChildren uses, keyed by id:
// all 38 hidden-bearing tags in index.html carry an id, and only registry (#id)
// elements are ever asked for their boot state. App-RENDERED markup is
// deliberately NOT seeded — a node the app painted owns its own hidden state,
// and reflecting it here would make this shim answer for markup index.html
// never shipped.
const INDEX_HTML = fs.readFileSync(path.join(HERE, "..", "index.html"), "utf8");
const HIDDEN_IDS = (() => {
  const ids = new Set();
  const OPEN_TAG_RE = /<([a-zA-Z][\w-]*)\b([^>]*)>/g;
  let m;
  while ((m = OPEN_TAG_RE.exec(INDEX_HTML)) !== null) {
    if (!/(^|\s)hidden(\s|=|\/|$)/.test(m[2])) continue;
    const id = /\bid="([^"]+)"/.exec(m[2]);
    if (id) ids.add(id[1]);
  }
  return ids;
})();

// ── minimal DOM shim ─────────────────────────────────────────────────────────
// An element is a plain bag of the props app.js reads/writes. The critical
// invariant: getElementById(id) and querySelector("#id") return the SAME object
// across calls (a registry), so an innerHTML the app writes to #fleet-body is
// still there when the assertion reads it back.
//
// cch-w2-revoke-click-oracle — THE SHIM IS NOW CLICK-CAPABLE. It used to be
// incapable four independent ways, which is why no scenario had ever exercised
// a click path for ANY button:
//   (a) addEventListener DROPPED its handler,
//   (b) click() was a no-op,
//   (c) querySelectorAll always answered [] because innerHTML was an opaque
//       string, so a delegate loop over freshly-rendered rows wired nothing,
//   (d) there was no `isConnected` at all — and app.js guards ~15 async render
//       paths with `if (!box.isConnected) return;` (`grep -n 'isConnected'
//       cloud/priv/static/app.js`, loadSessions the first). Every one of them
//       bailed before painting, so the account modal's session list had NEVER
//       rendered through the real code path here (account-modal-tall
//       regex-splices rows in by hand to work around exactly this).
//
// cch-bl-smoke-shim-fidelity — TWO MORE INCAPACITIES CLOSED, both of which had
// been measured MANUFACTURING WRONG VERDICTS (charter D55, D56):
//   (e) `isConnected` was true FOREVER, so a node the browser had destroyed
//       kept answering questions about content that no longer existed — a
//       false GREEN. It is now driven by declaration: see `declaredBy` in
//       makeDom, and the full statement of what that does and does not buy in
//       the account-modal-revoke header.
//   (f) dispatchEvent delivered clicks to `disabled` elements, so a correct
//       pending-state guard read as broken — a false RED. See
//       `SUPPRESSED_WHEN_DISABLED`.
//
// cch-w2-revoke-oracle-round2 — THE THIRD HALF OF (e), and the one that was
// still manufacturing wrong numbers after it:
//   (g) A DESTROYED NODE KEPT ITS LISTENERS. `declaredBy` already knew when a
//       parent's markup stopped naming an id (destroyed) and when it named it
//       again (a fresh node) — but the registry object survived both with its
//       handler lists intact, so every re-render ADDED a listener. Measured
//       before the fix: #modal-logout dispatched 2 handlers after openModal ran
//       twice, and one click therefore issued TWO DELETE /v1/auth/logout — a
//       number no browser can produce, and one that makes "exactly one request
//       per click" unassertable for every control the app re-wires. Handlers
//       are now cleared on BOTH transitions (`_resetHandlers` in makeEl, called
//       from the innerHTML reconcile loops), which is what the browser does:
//       the node is gone, and its listeners went with it. All 119 scenarios
//       stayed green across this alone.
//
// What is modelled and what is NOT — read this before writing a new check:
//   • innerHTML is a real accessor. Setting it re-parses; appendChild appends
//     the child's serialization, so a mounted node is observable in innerHTML.
//   • The parse is FLAT, not a tree: open tags become sibling stubs. Nesting,
//     text nodes and closing-tag structure are not modelled — a parsed stub's
//     own innerHTML is always "".
//   • CONTAINERS ARE REACHABLE ONLY THROUGH THE CLASS ALLOWLIST. A card whose
//     class is in `GROUPED_CLASSES` is materialised as a scoped VIEW over the
//     leaves inside its span (see parseGroups) — that is how `.wh-card`
//     resolves for findWhCard. PARSED_TAGS is NOT how it resolves, and the two
//     must not be confused: the allowlist is per-class and reviewable, the tag
//     list is blanket. Everything the next bullet forbids is still forbidden.
//   • The whitelist is DELIBERATELY only `button` and `a` — the leaf controls a
//     click oracle needs. It must NOT be widened to containers. app.js has
//     paths shaped like `var box = panel.querySelector(".fleet-body") || panel;`
//     (mountUsageTab), which fall back to the panel precisely
//     because a harness may not resolve the sub-query. Parsing `div` hands
//     those paths a DETACHED stub instead: the write lands on a node whose
//     content this flat parse cannot reflect back into its parent, so the panel
//     reads empty and six pre-existing scenarios go red. Modelling that
//     properly means a real tree; until someone builds one, containers stay
//     unparsed and those fallbacks keep working.
//   • Selectors: a single `.class`, a bare `#id`, and (cch-w10) a single
//     ATTRIBUTE selector — `[attr]` or `[attr="v"]`. Anything richer (a
//     COMPOUND like `.token-revoke[data-id]`, or a descendant path) answers
//     [] / null rather than throwing, so it silently matches NOTHING.
//     ⇒ EVERY click-driven check MUST assert a positive click count (the
//     `fired` idiom below); otherwise an empty node list reads as a clean pass
//     and you have written a false green inside the harness whose whole job is
//     to catch them.
//
// cch-w10-destroy-shrink-oracle-merged — WHY THE ATTRIBUTE GRAMMAR EXISTS.
// Before it, `.session-revoke` was the ONLY destructive list control the shim
// could resolve: every other one is authored as an attribute hook
// (`[data-prov-disconnect]`, `[data-member-remove]`, `[data-invite-revoke]`,
// `[data-env-delete]`, `[data-life-verb="decommission"]`), so app.js's
// `box.querySelectorAll("[data-…]").forEach(addEventListener)` looped over an
// EMPTY list and wired nothing — and a loop over nothing is a clean pass.
// Widening is safe by construction: every one of those call sites only ATTACHES
// handlers, so coming alive cannot change any pre-existing rendered markup
// (measured: all 98 scenarios stayed green across the widening alone).
// Two halves are needed and neither works without the other:
//   • the SELECTOR half (ATTR_SEL below), so `[data-x]` resolves against kids;
//   • the PARSE half (ATTR_RE), so a VALUELESS attribute is captured at all —
//     `data-prov-disconnect` and `data-wh-delete` are authored bare, and an
//     attribute the parse never recorded can never satisfy a selector.
// NOT widened, deliberately: PARSED_TAGS (the mountUsageTab detached-stub
// hazard above stands).
//
// cch-bl-smoke-document-attr-selectors-still-dead — the DOCUMENT-level
// querySelectorAll is now a registry sweep, and the decision was MEASURED, not
// assumed: with an instrumented sweep in place the full suite ran GREEN (111
// scenarios, exit 0, status lines byte-identical to the hard-return-[] run),
// so widening reds nothing. The census over that run, per selector as
// calls/hits:
//   [data-notif-chan-test]   6/12  ← COMES ALIVE — per-channel Send test wired
//   [data-offload-support]   5/5   ← COMES ALIVE — the Offload row button wired
//   [data-notif-cell]        6/0      routing checkboxes are <input>: PARSED_TAGS
//   [data-support-presence]  5/0      presence slots are <span>: PARSED_TAGS
//   .nav-link[data-view]   105/0      shell chrome lives in index.html, which
//   .nav-sub[data-view]    105/0      this shim never parses — structurally 0
//   #modal [data-close]      2/0      DESCENDANT selector — see below
// Both live loops only ATTACH handlers (wireNotifSettings :4281 and
// wireOffloadActions :24229 in app.js — grep, don't trust the line), so coming
// alive cannot change pre-existing rendered markup; that is the same
// safe-by-construction argument as the two element-level widenings above, and
// the measured green confirms it. The sweep is ONE code path — dedupe over
// [body, ...registry] delegating to the element-level grammar — so no arm of
// it is decoration: every grammar arm is the same arm the element-level
// oracles already exercise, and the document level itself is pinned by the
// notif-configured chan-test click (revert the sweep to `return []` and that
// check reds — mutation-verified, this row's evidence).
// STILL DEAD, by name, so nobody re-discovers them: `#modal [data-close]`
// (applyModalClose — a DESCENDANT selector no shim grammar parses; it answers
// [] exactly as every richer selector does), `.nav-link[data-view]` /
// `.nav-sub[data-view]` (applyRoute/applyShellNav — the static shell is not
// modelled, so a sweep finds no such nodes to return), and credQ (:2816) —
// never called in this corpus (census shows no credQ selector), but NOTE: if a
// future scenario reaches it with #modal-root visible, its `root.contains(b)`
// will THROW here (shim elements model no `contains`) — a loud red, never a
// false green, which is the correct failure mode for an unmodelled path.
// The event types a real browser refuses to deliver to a `disabled` form
// control (HTML spec: "a form control that is disabled must prevent any
// click events that are queued ... from being dispatched"; UAs extend the
// same suppression to the other pointer/keyboard interaction events). Every
// other type — "input", "change", "submit" — is still delivered, because the
// browser does deliver those and app.js replays some of them programmatically.
const SUPPRESSED_WHEN_DISABLED = new Set([
  "click", "mousedown", "mouseup", "dblclick", "keydown", "keypress", "keyup",
]);
const PARSED_TAGS = "button|a";
const TAG_RE = new RegExp("<(" + PARSED_TAGS + ")\\b([^>]*?)/?>", "gi");
const ATTR_RE = /([\w:.-]+)(?:="([^"]*)")?/g;
const CLASS_SEL = /^\.[\w-]+$/;
const ID_SEL_SUB = /^#[\w-]+$/;
const ATTR_SEL = /^\[([\w:.-]+)(?:="([^"]*)")?\]$/;
// cch-w11-s3 — THE COMPOUND `.class[attr]`, the last selector shape standing
// between the shim and a destroy control. `.token-revoke[data-id]` — authored in
// renderTokenList(), `grep -n 'function renderTokenList' cloud/priv/static/app.js`
// — is the ONLY app.js destroy hook of this shape; every other one is a bare
// attribute already covered by ATTR_SEL above.
//
// THE BLAST RADIUS IS MEASURED, NOT ASSUMED — instrumented census over all 99
// scenarios, as calls/hits:
//   .token-revoke[data-id]    5 / 12   ← the destroy control this exists for
//   .seg-btn[data-kind]       1 /  2   ← THE SECOND SELECTOR THAT COMES ALIVE.
//        Named, not smuggled: it is a real behavioural change in the same diff.
//        Its call site only ATTACHES handlers (`.forEach(b => b.addEventListener)`),
//        so coming alive cannot alter any rendered markup — and all 99 scenarios
//        stayed green across the widening alone.
//   .fleet-row[data-id]      29 /  0
//   .site-row[data-id]        4 /  0
//   .new-step-dot[data-ring]  5 /  0   ← all three DIVs; PARSED_TAGS is button|a.
// `nav-link[data-view]` / `nav-sub[data-view]` never appear: they are
// DOCUMENT-level queries — applyRoute() and applyShellNav(), `grep -n 'function
// applyRoute\|function applyShellNav' cloud/priv/static/app.js` — a separate code
// path that hard-returns [], so the filed "a change here can alter boot paths"
// worry is structurally impossible for this element-level widening.
// `.choice[data-kind]:not([disabled])` in openProviderPicker() (`grep -n
// 'function openProviderPicker' cloud/priv/static/app.js`) carries a pseudo-class
// and stays outside this grammar.
const COMPOUND_SEL = /^\.([\w-]+)\[([\w:.-]+)(?:="([^"]*)")?\]$/;

// Flat scan: every whitelisted OPEN tag in `html` becomes a sibling stub
// carrying its double-quoted attributes (so getAttribute("data-id") answers a
// real value). Deliberately not a parser — see the contract above.
function parseChildren(html, makeEl) {
  const out = [];
  TAG_RE.lastIndex = 0;
  let m;
  while ((m = TAG_RE.exec(html)) !== null) {
    const el = makeEl("", m[1]);
    const raw = m[2] || "";
    ATTR_RE.lastIndex = 0;
    let a;
    // a[2] is undefined for a bare attribute (`data-prov-disconnect`), which the
    // DOM reflects as the empty string — the value nobody reads, but the
    // PRESENCE `[attr]` selectors and hasAttribute() ask about.
    while ((a = ATTR_RE.exec(raw)) !== null) el.setAttribute(a[1], a[2] === undefined ? "" : a[2]);
    el.disabled = /\bdisabled\b/.test(raw);
    // Where this leaf sat in the markup. Used ONLY by parseGroups below, to
    // decide which card a button belongs to; nothing app.js can see reads it.
    el._at = m.index;
    out.push(el);
  }
  return out;
}

// The ONE selector arm every level of this shim goes through — element,
// document sweep, and card group alike. Factored out of makeEl by
// cch-bl-webhook-delete-oracle so a group cannot grow a second, drifting copy
// of the grammar: a group differs from an element only in WHICH list it
// searches, never in HOW it matches.
function selectIn(list, sel) {
  if (typeof sel !== "string") return [];
  const hasClass = (k, want) => String(k.className || "").split(/\s+/).indexOf(want) >= 0;
  if (CLASS_SEL.test(sel)) return list.filter((k) => hasClass(k, sel.slice(1)));
  if (ID_SEL_SUB.test(sel)) return list.filter((k) => k.id === sel.slice(1));
  const at = ATTR_SEL.exec(sel);
  if (at) {
    return list.filter((k) =>
      k.hasAttribute(at[1]) && (at[2] === undefined || k.getAttribute(at[1]) === at[2]));
  }
  const cm = COMPOUND_SEL.exec(sel);
  if (cm) {
    return list.filter((k) =>
      hasClass(k, cm[1]) &&
      k.hasAttribute(cm[2]) && (cm[3] === undefined || k.getAttribute(cm[2]) === cm[3]));
  }
  return [];
}

// ── CARD GROUPS — THE WEBHOOK CARD, REACHED WITHOUT WIDENING PARSED_TAGS ─────
// cch-bl-webhook-delete-oracle. `wireWebhookCard` (grep it in app.js) bails at
// `findWhCard`, which needs `listBox.querySelectorAll(".wh-card")` to answer a
// DIV — and PARSED_TAGS is `button|a` under a committed prohibition against
// widening it to containers (the mountUsageTab detached-stub hazard, stated at
// the top of this file). Both things stay true here. Nothing is added to
// PARSED_TAGS; the flat leaf parse is untouched, byte for byte.
//
// THE MECHANISM, and why it cannot revive that hazard: groups are keyed on a
// CLASS ALLOWLIST, not on a tag. `.wh-list` and `.fleet-body` — the two
// container queries whose `|| root` fallbacks the prohibition protects — are
// not on the list, so they still answer null and still fall back to the panel.
// Only a container whose class is named below is materialised, and adding one
// is a deliberate, reviewable act rather than a blanket widening.
//
// A group is a VIEW over the SAME leaf objects its parent already parsed, not a
// second copy:
//   • it is returned by the parent's `.wh-card` query (and by any other
//     selector it matches — one grammar, `selectIn`, for every level);
//   • its `querySelector` searches ONLY the leaves that sat inside ITS span, so
//     card 2's Delete is card 2's. THAT is the wrong-target trap this row exists
//     to disprove: an `|| listBox` fallback in app.js would wire BOTH cards'
//     handlers to the FIRST button and look green;
//   • the leaves are shared, so a handler attached through the card is the same
//     handler a `panel.querySelectorAll("[data-wh-delete]")` sweep would find —
//     one node, two ways to reach it, exactly like the DOM;
//   • `parentNode` is the parent, and `parentNode.removeChild(card)` splices the
//     card's own bytes out of the parent's innerHTML and drops its leaves. That
//     is what makes "the row left the DOM" observable, which is the ONLY thing
//     deleteWebhook's success arm does to the list (its toast is a constant).
const GROUPED_CLASSES = ["wh-card"];
const DIV_TOKEN_RE = /<div\b([^>]*)>|<\/div\s*>/gi;
const GROUP_CLOSE = "</div>";

function parseGroups(html, kids, makeEl, owner) {
  const groups = [];
  // Cheap bail: every scenario that renders no grouped class pays one indexOf.
  if (!GROUPED_CLASSES.some((c) => html.indexOf(c) >= 0)) return groups;
  DIV_TOKEN_RE.lastIndex = 0;
  const stack = [];
  let m;
  while ((m = DIV_TOKEN_RE.exec(html)) !== null) {
    if (m[1] === undefined) {
      const open = stack.pop();
      if (open && open.grouped) groups.push(makeGroup(html, open, m.index + m[0].length, kids, makeEl, owner));
      continue;
    }
    const raw = m[1];
    if (/\/\s*$/.test(raw)) continue; // a self-closed <div/> owns no span
    const cls = /\bclass="([^"]*)"/.exec(raw);
    const names = cls ? cls[1].split(/\s+/) : [];
    stack.push({
      raw,
      grouped: names.some((n) => GROUPED_CLASSES.indexOf(n) >= 0),
      outerStart: m.index,
      innerStart: m.index + m[0].length,
    });
  }
  return groups;
}

function makeGroup(html, open, outerEnd, kids, makeEl, owner) {
  const el = makeEl("", "div");
  ATTR_RE.lastIndex = 0;
  let a;
  while ((a = ATTR_RE.exec(open.raw)) !== null) el.setAttribute(a[1], a[2] === undefined ? "" : a[2]);
  const leaves = kids.filter((k) => k._at >= open.innerStart && k._at < outerEnd);
  el._groupOuter = html.slice(open.outerStart, outerEnd);
  el._groupLeaves = leaves;
  el.parentNode = owner;
  el.querySelectorAll = (sel) => selectIn(leaves, sel);
  el.querySelector = (sel) => selectIn(leaves, sel)[0] || null;
  // The group's own bytes, read-only: a group is a VIEW, and a write through it
  // would have to reconcile back into the parent's string. Nothing in app.js
  // writes a card's innerHTML (it removes the whole card instead), so the honest
  // move is to answer the bytes and refuse the write rather than to model half
  // of it. A future writer gets a loud TypeError, never a silent no-op.
  Object.defineProperty(el, "innerHTML", {
    get() { return html.slice(open.innerStart, Math.max(open.innerStart, outerEnd - GROUP_CLOSE.length)); },
    enumerable: true,
    configurable: true,
  });
  return el;
}

// Serialize a mounted node back into its parent's innerHTML, so appendChild is
// observable. Attribute order is stable (class first, then insertion order).
function serializeEl(el) {
  if (!el) return "";
  const tag = String(el.tagName || "div").toLowerCase();
  let attrs = "";
  if (el.className) attrs += ' class="' + el.className + '"';
  for (const k of Object.keys(el._attrs || {})) {
    if (k === "class") continue;
    attrs += " " + k + '="' + el._attrs[k] + '"';
  }
  return "<" + tag + attrs + ">" + (el.innerHTML || "") + "</" + tag + ">";
}

function makeDom() {
  const registry = new Map();

  // ── DETACHMENT, MODELLED BY DECLARATION (cch-bl-smoke-shim-fidelity) ───────
  // The registry is flat: #sessions-box and #modal-body are siblings here even
  // though the browser nests the first inside the second. What the shim CAN
  // see is the markup, and markup names its own ids. So an element is treated
  // as mounted while some other element's CURRENT innerHTML declares its id —
  // and the instant that markup is replaced by markup that no longer names it,
  // the browser has destroyed the node, so `isConnected` flips to false. That
  // is the exact read app.js's async render guards make
  // (`grep -n 'isConnected' cloud/priv/static/app.js` — loadSessions and ~15
  // siblings bail on it), and it is what turns "the confirm sheet replaced the
  // account screen and nothing re-rendered" from a silent green into a red.
  //
  // BOUNDED ON PURPOSE. Only ids a parent's markup DECLARED can ever detach:
  // an id that lives in the shipped index.html shell and is never re-emitted
  // by a render (#modal-body, #view-root, #toast-stack, …) was never declared
  // here, so it keeps the old unconditional `isConnected: true` and no
  // pre-existing scenario moves. Nesting resolves last-writer-wins: if two
  // elements declare the same id, only the one that currently owns it can
  // detach it.
  const declaredBy = new Map();
  // ids whose declaring markup has been torn out at least once, so a LATER
  // getElementById cannot launder the detachment into a fresh connected stub.
  const detached = new Set();
  const ID_IN_MARKUP = /\sid="([\w:.-]+)"/g;
  function declaredIds(markup) {
    const out = new Set();
    ID_IN_MARKUP.lastIndex = 0;
    let m;
    while ((m = ID_IN_MARKUP.exec(markup)) !== null) out.add(m[1]);
    return out;
  }

  function makeEl(id, tagName) {
    // Backing state for the innerHTML accessor: the serialized markup and the
    // flat child list parsed out of it (plus anything appendChild mounted).
    let html = "";
    let kids = [];
    // Card groups over the SAME kids (see parseGroups). Re-derived on every
    // innerHTML write, exactly like kids.
    let groups = [];
    // The registry ids this element's CURRENT markup declares (see declaredBy).
    let ownIds = new Set();
    const handlers = Object.create(null);
    const attrs = Object.create(null);

    const el = {
      id: id || "",
      tagName: (tagName || "div").toUpperCase(),
      textContent: "",
      value: "",
      // Seeded from index.html, not invented: an element the page ships
      // `hidden` BOOTS hidden here too (see HIDDEN_IDS above).
      hidden: HIDDEN_IDS.has(id || ""),
      className: "",
      disabled: false,
      // (d) The fourth incapacity. Present and true: every element this shim
      // hands out is mounted, so the isConnected guards let their render run.
      isConnected: true,
      style: {},
      dataset: {},
      scrollTop: 0,
      scrollHeight: 0,
      clientHeight: 0,
      parentNode: null,
      // Exposed for serializeEl only (a mounted node must round-trip into its
      // parent's innerHTML); app.js never reads it.
      _attrs: attrs,
      classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
      // (a) Handlers are KEPT, per type, in registration order.
      addEventListener(type, fn) {
        if (typeof fn !== "function") return;
        (handlers[type] || (handlers[type] = [])).push(fn);
      },
      _resetHandlers() { for (const k of Object.keys(handlers)) delete handlers[k]; },
      removeEventListener(type, fn) {
        const list = handlers[type];
        if (!list) return;
        const i = list.indexOf(fn);
        if (i >= 0) list.splice(i, 1);
      },
      // Returns how many handlers actually ran — the number a check asserts on
      // so a never-wired (or wrongly-typed) listener cannot pass as success.
      dispatchEvent(ev) {
        const type = (ev && ev.type) || "click";
        // (e) THE DISABLED GATE (cch-bl-smoke-shim-fidelity). A real browser
        // never delivers a click to a `disabled` control, so a CORRECTLY
        // disabled button must report 0 handlers here too. Without this line a
        // pending-state guard that works looks BROKEN under the obvious
        // double-click test: the second click ran the handler and doubled the
        // request count. Scoped to the interaction events the browser actually
        // suppresses — a programmatic dispatch of a non-interaction event
        // (e.g. the "input" a re-render replays) still reaches the node.
        if (el.disabled && SUPPRESSED_WHEN_DISABLED.has(type)) return 0;
        const list = (handlers[type] || []).slice();
        const event = Object.assign({
          type,
          target: el,
          currentTarget: el,
          preventDefault() {},
          stopPropagation() {},
        }, ev || {});
        for (const fn of list) fn.call(el, event);
        return list.length;
      },
      // (b) A real click: dispatches every "click" handler and reports the
      // count. `el.click()` returning 0 means the button is DEAD.
      click() { return el.dispatchEvent({ type: "click" }); },
      setAttribute(k, v) {
        attrs[k] = String(v);
        if (k === "class") el.className = String(v);
        if (k === "id") el.id = String(v);
      },
      removeAttribute(k) { delete attrs[k]; },
      getAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k) ? attrs[k] : null; },
      hasAttribute(k) { return Object.prototype.hasOwnProperty.call(attrs, k); },
      focus() {},
      blur() {},
      // The search box's re-render restores the caret with
      // setSelectionRange(len, len) (app.js renderTeamMenu). Absent here, the
      // team picker's filter path threw TypeError on the FIRST keystroke, so
      // no check could ever type into it. Inert (the shim models no caret) but
      // PRESENT, which is the whole difference between a path that runs and a
      // path that cannot be reached at all.
      setSelectionRange() {},
      appendChild(child) {
        if (!child) return child;
        kids.push(child);
        child.parentNode = el;
        html += serializeEl(child);
        return child;
      },
      removeChild(child) {
        // A CARD GROUP: splice its own bytes out of this element's markup and
        // drop the leaves that lived inside it. This is `deleteWebhook`'s
        // success arm — `card.parentNode.removeChild(card)` — and it is the one
        // observable that separates a delete that worked from one that did not.
        if (child && child._groupOuter !== undefined) {
          const at = html.indexOf(child._groupOuter);
          if (at >= 0) html = html.slice(0, at) + html.slice(at + child._groupOuter.length);
          for (const leaf of child._groupLeaves) {
            const j = kids.indexOf(leaf);
            if (j >= 0) kids.splice(j, 1);
          }
          const g = groups.indexOf(child);
          if (g >= 0) groups.splice(g, 1);
          child.parentNode = null;
          child.isConnected = false;
          return child;
        }
        const i = kids.indexOf(child);
        if (i >= 0) kids.splice(i, 1);
        const s = serializeEl(child);
        const at = html.indexOf(s);
        if (at >= 0) html = html.slice(0, at) + html.slice(at + s.length);
        if (child) child.parentNode = null;
        return child;
      },
      insertAdjacentHTML(_pos, frag) { el.innerHTML = html + String(frag == null ? "" : frag); },
      // (c) Sub-tree lookup over the parsed children — the same objects across
      // calls, so a handler app.js attached to a row survives to the click.
      // Card groups (see parseGroups) are searched alongside the flat leaves,
      // so `findWhCard`'s `.wh-card` resolves without any leaf moving.
      querySelectorAll(sel) { return selectIn(kids.concat(groups), sel); },
      querySelector(sel) { return el.querySelectorAll(sel)[0] || null; },
      closest() { return null; },
      getClientRects() { return []; },
      get children() { return kids.slice(); },
    };

    Object.defineProperty(el, "innerHTML", {
      get() { return html; },
      set(v) {
        html = String(v == null ? "" : v);
        kids = parseChildren(html, makeEl);
        groups = parseGroups(html, kids, makeEl, el);
        // Reconcile the declaration ledger: ids this markup drops are detached,
        // ids it names are (re-)attached. See declaredBy above.
        const next = declaredIds(html);
        for (const gone of ownIds) {
          if (next.has(gone) || declaredBy.get(gone) !== el) continue;
          declaredBy.delete(gone);
          detached.add(gone);
          const node = registry.get(gone);
          if (node) {
            node.isConnected = false;
            if (node._resetHandlers) node._resetHandlers();
          }
        }
        for (const here of next) {
          const reDeclared = ownIds.has(here) && declaredBy.get(here) === el;
          declaredBy.set(here, el);
          detached.delete(here);
          const node = registry.get(here);
          if (node) {
            node.isConnected = true;
            if (reDeclared && node._resetHandlers) node._resetHandlers();
          }
        }
        ownIds = next;
      },
      enumerable: true,
      configurable: true,
    });

    return el;
  }

  // Registry lookup for a bare #id selector; everything else is inert.
  const ID_SEL = /^#[\w-]+$/;
  function byId(id) {
    if (!registry.has(id)) {
      const fresh = makeEl(id);
      // A node first asked for AFTER its declaring markup was already torn out
      // must not boot connected — otherwise a re-lookup laundered the
      // detachment away. `declaredBy` remembers the tear-out.
      if (!declaredBy.has(id) && detached.has(id)) fresh.isConnected = false;
      registry.set(id, fresh);
    }
    return registry.get(id);
  }
  function query(sel) {
    if (typeof sel === "string" && ID_SEL.test(sel)) return byId(sel.slice(1));
    return null;
  }

  const documentEl = makeEl("documentElement");
  documentEl.getAttribute = () => null;

  const document = {
    readyState: "complete", // ⇒ app.js runs init() immediately at eval time
    documentElement: documentEl,
    body: makeEl("body"),
    addEventListener() {},
    removeEventListener() {},
    querySelector: query,
    // The document-level sweep (cch-bl-smoke-document-attr-selectors-still-dead):
    // every registry mount + body, deduped, through the SAME per-element grammar
    // above — one code path, no document-only selector arm to rot unexercised.
    querySelectorAll(sel) {
      if (typeof sel !== "string") return [];
      const seen = new Set();
      const out = [];
      for (const root of [document.body, ...registry.values()]) {
        for (const hit of root.querySelectorAll(sel)) {
          if (!seen.has(hit)) { seen.add(hit); out.push(hit); }
        }
      }
      return out;
    },
    getElementById: byId,
    // Created (non-registry) elements are freshly-authored wiring surfaces. Now
    // that innerHTML really parses, their querySelector finds the real control
    // (toast()'s close button, the first smoke-exercised case) — but it still
    // NEVER answers null, because a primitive wiring markup this flat parse
    // does not model must not abort the boot by throwing on `.addEventListener`
    // of undefined. Registry (#id) elements keep the document-level null-
    // returning query above, so existence-driven logic is untouched.
    createElement(tag) {
      const el = makeEl("", tag);
      const real = el.querySelector.bind(el);
      el.querySelector = (sel) => real(sel) || makeEl("", "div");
      return el;
    },
  };

  return { registry, document, byId };
}

// ── per-scenario boot ────────────────────────────────────────────────────────
// OPTIONS (cch-w46-s3), all smoke-only and all defaulting to the shipped boot:
//   • deferMe — HOLD every GET /v1/me response until the returned resolveMe()
//     is called. The scenario boots, routes and paints with the authority read
//     STILL IN FLIGHT, which is the state a deep link into a slow control plane
//     actually produces; resolveMe() then lands the answer LATE, so a surface
//     that read /v1/me at paint time and never again is observable as such
//     (before/after bytes). Without it the whole corpus resolves /v1/me on the
//     first microtask and no late-answer defect can be represented at all.
function bootScenario(name, opts) {
  const { registry, document, byId } = makeDom();

  // Backing stores we control so each scenario boots clean.
  const store = new Map();
  const sessionStore = new Map();
  const localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
  const sessionStorage = {
    getItem: (k) => (sessionStore.has(k) ? sessionStore.get(k) : null),
    setItem: (k, v) => sessionStore.set(k, String(v)),
    removeItem: (k) => sessionStore.delete(k),
  };

  const scen = SCENARIOS[name];
  // Seed the session exactly as mock.js does (logged-out scenario → none).
  if (scen.authed) {
    store.set("bpcloud.session", JSON.stringify({ token: "preview", team_id: "preview-team" }));
  }
  // seedLocal: pre-seed localStorage (e.g. bp_theme) so a scenario can exercise a
  // restored identity/mode before the first paint. Optional, smoke-only.
  if (scen.seedLocal) for (const k of Object.keys(scen.seedLocal)) store.set(k, String(scen.seedLocal[k]));

  // pathname/search are smoke-only optional scenario fields: a scenario that
  // needs a real path (e.g. /activate, to unlock isActivateFlow()) sets them.
  // Default "/"+"" keeps every pre-existing hash-routed scenario unchanged; the
  // browser harness (mock.js) ignores these and uses the actually-served path.
  // Every full-reload the app performs, in order. NOT a no-op: a swallowed
  // reload is indistinguishable from a code path that never ran, and the team
  // picker's pin write (localStorage.setItem("bp.active-team", id) immediately
  // followed by location.reload()) is the one place where the reload IS the
  // second half of the contract — every team-scoped cache must repopulate. The
  // shim shipped no `reload` at all, so that handler threw TypeError after the
  // write, i.e. the only writer of the pin could not be driven to completion.
  const reloads = [];
  const location = {
    hash: scen.deepLink || "#overview",
    pathname: scen.pathname || "/",
    search: scen.search || "",
    origin: "http://localhost",
    href: "http://localhost/",
    reload() { reloads.push({ href: location.href, hash: location.hash }); },
  };

  // Per-boot mutable fixture state (cch-w2, D39). Handed to route() so a
  // scenario can model a route that actually CHANGES something — a stateless
  // fixture returns a byte-identical list after a destructive call, which is
  // indistinguishable from the call never having happened, i.e. exactly the
  // false green this slice exists to kill. Absent for mock.js (3-arg caller),
  // which keeps the browser harness stateless and unchanged.
  const fixtureState = {};

  // Every request is logged so a check can assert the WIRE (method + path),
  // which is the only coverage available for the destructive routes whose
  // toast text is a client-side constant and therefore identical whether the
  // server did the work or not.
  const calls = [];

  // fetch → scenario router → a Response-like the app's api() understands.
  // cch-w46-s3: the held /v1/me responses, drained (in request order) by the
  // resolveMe() bootScenario hands back. Empty unless opts.deferMe.
  const heldMe = [];
  const resolveMe = () => { heldMe.splice(0).forEach((land) => land()); };

  function fetchStub(url, init) {
    const method = (init && init.method) || "GET";
    const p = String(url);
    calls.push({ method, path: p.split("?")[0] });
    // Routed at LANDING time, not at call time, so a deferred response still
    // reflects whatever the fixture state is when it actually answers.
    const answer = () => {
      const res = route(name, method, p, fixtureState) || { status: 404, body: { error: "not_found" } };
      // extraMembership (cch-w43-s6), smoke-only and defaulting OFF: APPEND one
      // further membership to the teams[] a 200 /v1/me already answers with.
      //
      // Why it has to exist. The corpus mints exactly ONE membership per actor,
      // deliberately (scenarios.mjs, me(): "a SECOND team here would be a
      // scenario-level claim ... that no fixture asks for"), and the switcher's
      // active row is that same team. So renderTeamMenu's non-active arm — the
      // SOLE writer of localStorage["bp.active-team"], the pin api() sends as
      // x-barkpark-team on every request — is unreachable from every committed
      // fixture, and an assertion that cannot reach a branch does not guard it.
      // This is ADDITIVE by construction: the corpus's own membership is never
      // replaced or reordered, so the rendered-list half of the guard below
      // still reads what the CORPUS serves, and the appended row is structurally
      // guaranteed non-active (meCache.team.id is the corpus's team, always).
      // No scenario, no census literal, and route() is untouched — the envelope
      // census still measures exactly what scenarios.mjs answers.
      let body = res.body;
      if (opts && opts.extraMembership && res.status === 200 &&
          p.split("?")[0].endsWith("/v1/me")) {
        body = Object.assign({}, body, {
          teams: ((body && body.teams) || []).concat([opts.extraMembership]),
        });
      }
      return {
        ok: res.status >= 200 && res.status < 300,
        status: res.status,
        headers: { get: (h) => (String(h).toLowerCase() === "content-type" ? "application/json" : null) },
        json: () => Promise.resolve(body),
        text: () => Promise.resolve(JSON.stringify(body)),
      };
    };
    if (opts && opts.deferMe && p.split("?")[0].endsWith("/v1/me")) {
      return new Promise((resolve) => heldMe.push(() => resolve(answer())));
    }
    return Promise.resolve(answer());
  }

  function EventSourceStub() {
    return { addEventListener() {}, removeEventListener() {}, close() {}, onopen: null, onmessage: null, onerror: null };
  }

  const sandbox = {
    document,
    window: {
      addEventListener() {},
      removeEventListener() {},
      open() { return null; },
      matchMedia() { return { matches: false, addEventListener() {} }; },
    },
    location,
    history: { replaceState() {}, pushState() {} },
    localStorage,
    sessionStorage,
    navigator: {},
    fetch: fetchStub,
    EventSource: EventSourceStub,
    // Timers are inert: the load paths are pure promise chains; the elapsed
    // ticker + toast auto-dismiss would only add nondeterministic churn.
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: () => 1,
    clearInterval() {},
    console,
    URLSearchParams,
    URL,
  };
  sandbox.window.location = location;
  sandbox.globalThis = sandbox;

  // gr-p2-front-door: capture the app's __bpTestHook export (the same seam
  // __app.test.mjs uses) so an EXPECTATION can drive a pure mount — e.g. the
  // shared 2FA card, which only ever mounts behind a click this shim keeps
  // inert. The hook call runs at app.js eval tail, so it is populated by the
  // time bootScenario returns; absent in a real browser, a no-op here too if
  // app.js ever drops the export (expectations assert it explicitly).
  const captured = { hooks: null };
  sandbox.__bpTestHook = (h) => { captured.hooks = h; };

  vm.createContext(sandbox);
  vm.runInContext(APP_JS, sandbox, { filename: "app.js" });

  // localStorage/reloads are handed back so a check can observe what the app
  // WROTE, not merely what it painted: the team pin is written to storage and
  // then the page reloads, and neither half is visible in any innerHTML.
  // byId is the SAME lookup app.js's $() makes. A check that wants an element's
  // BOOT state ("does #team-menu ship hidden?") has to be able to ask for it
  // without a click having created the registry entry first — reading it off
  // `registry` alone answers undefined for every id the boot never touched,
  // which is indistinguishable from an element that booted visible.
  return { registry, byId, hooks: captured.hooks, calls, fixtureState, resolveMe, localStorage, reloads };
}

// Flush all pending microtasks (both realms share Node's one microtask queue).
async function flush() {
  for (let i = 0; i < 40; i++) {
    await Promise.resolve();
    await new Promise((r) => setImmediate(r));
  }
}

// ── cch-w46-s3 · THE LATE-/v1/me GUARD, and it runs BEFORE the corpus ────────
// Not an EXPECTATION (those own their scenarios; this owns a HARNESS
// CAPABILITY): it boots ONE existing scenario twice-over in a single run — with
// the authority read held open past the paint, then landed — and asserts the
// instance rail actually repainted. It is deliberately pinned on `usage-quota`,
// the tab reloadInstanceView() HARD-RETURNS on: the obvious
// `if (currentView() === "instance") reloadInstanceView()` seam was built and
// measured, and it left this exact rail byte-identical while Overview looked
// fixed. So a fix that only covers Overview reds here.
//
// It runs at module top level, ahead of main(), so a broken seam is named at
// the START of the run rather than inferred from a scenario failing downstream.
async function assertLateMeRepaintsTheRail() {
  const boot = bootScenario("usage-quota", { deferMe: true });
  await flush();
  const railEl = boot.registry.get("inst-lifecycle-actions");
  const before = (railEl && railEl.innerHTML) || "";
  boot.resolveMe();
  await flush();
  const after = (railEl && railEl.innerHTML) || "";

  const broken = [];
  if (!before) broken.push("the rail never painted with /v1/me in flight — the scenario or the mount moved");
  if (before.indexOf("data-me-retry") === -1) {
    broken.push("an UNKNOWN authority rendered no exit: no [data-me-retry] in the in-flight rail, so the only " +
      "way out of \"Checking capabilities…\" is a full page reload");
  }
  if (after === before) {
    broken.push("a /v1/me that answered LATE left the rail BYTE-IDENTICAL (" + before.length + " bytes) — the " +
      "authority is still read at paint time only. Note the tab: reloadInstanceView() refuses #usage, so a seam " +
      "routed through it passes on Overview and fails here.");
  }
  if (after.indexOf('data-life-verb="decommission"') === -1) {
    broken.push("the landed answer (an owner) did not restore the live destroy verb — the repaint fired but " +
      "painted the wrong model");
  }
  process.stdout.write(
    "  " + (broken.length ? "FAIL" : "ok  ") + " late-/v1/me   — usage tab rail: " + before.length +
    " bytes in flight (exit: " + (before.indexOf("data-me-retry") !== -1) + ") → " + after.length +
    " bytes once it landed (repainted: " + (after !== before) + ")\n");
  if (broken.length) {
    process.stdout.write("\nlate-/v1/me guard failed:\n  " + broken.join("\n  ") + "\n");
    process.exit(1);
  }
}
// cch-w46-s7 — THIS CALL MOVED INTO main(). It used to fire at module top level,
// which made `import("./smoke.mjs")` boot a scenario and leak its verdict line to
// stdout (measured: 117 bytes). A module that runs a corpus on import cannot be a
// host for another instrument, so the two top-level awaits (this one and the
// billing guard below main()) now run as main()'s FIRST two steps — same order,
// same output, same exit codes, but only when smoke.mjs is the entry point.


// ── cch-w43-s6 · THE TEAM SWITCHER'S FIRST RENDERED PROOF ────────────────────
// Not an EXPECTATION (it owns a HARNESS CAPABILITY and drives one existing
// scenario twice, the same shape as the late-/v1/me guard above): it adds no
// SCENARIOS key, no EXPECTATIONS key, and moves no census literal.
//
// What had no guard at all. `grep 'ws-switch\|team-menu\|renderTeamMenu'` over
// this file returned ZERO lines. The switcher's only pin anywhere in the repo
// is five regexes over readFileSync(app.js) in __app.test.mjs — a source-text
// scan, and a vacuous one: truncating renderTeamMenu's list to
// `.slice(0, 0)` — structurally incapable of ever listing a team — satisfies
// every one of those regexes and ships the whole console suite green. Only a
// RENDERED click can tell the two apart, and this is that click.
//
// The two halves are inseparable, which is why they land together:
//   • the DOM shim seeding (HIDDEN_IDS) without this guard changes no
//     behaviour — measured: the full suite is byte-identical before and after;
//   • this guard without the seeding cannot be written honestly, because
//     #team-menu booted VISIBLE in the shim and index.html ships it `hidden`,
//     so the first click closed it and only the second opened one. A
//     "click once, assert open" check written over that boot state pins the
//     harness's invention and would go RED against a correct app.
//
// Two things it deliberately does NOT do (charter D488/D489):
//   • it asserts NO input-listener count. The 1/2/4/8/16 doubling on
//     #team-menu-q is an artifact of this shim's identity model (PARSED_TAGS is
//     "button|a", so an <input> is never a parsed child and $() falls through
//     to a persistent registry stub). A real browser destroys the node on the
//     innerHTML replacement. `fired === 1` would pin the harness, not the app.
//   • nothing seeds localStorage["bp.active-team"]. teamAuthorityState's
//     `stale` arm compares the pin against the one the answer was fetched
//     under, and stays quiet only while both are null; a seeded pin flips every
//     scenario to `stale`, membersContext returns null and the corpus reds en
//     masse. The pin is observed as a WRITE — and the boot value is asserted
//     null first, so a future seed reds HERE rather than everywhere.
const SWITCHER_SCENARIO = "members-populated";

// The painted .team-list, sliced out of #team-menu's markup. It is read as a
// STRING on purpose: parseChildren is FLAT, so a parsed <button> stub carries
// its attributes and NO inner markup — the row's name and its ✓ exist only in
// the HTML, and a selector-shaped assertion over the stubs would match nothing
// and pass vacuously.
function teamListHtml(menuHtml) {
  const start = String(menuHtml || "").indexOf('<div class="team-list">');
  if (start === -1) return "";
  const foot = menuHtml.indexOf('<button type="button" class="team-item team-foot"', start);
  return menuHtml.slice(start, foot === -1 ? menuHtml.length : foot);
}
function teamRowsHtml(listHtml) {
  return listHtml.split('<button type="button" class="team-item"').slice(1);
}

// ONE real click through the registry — el.click() returns how many handlers
// actually ran, so a never-wired control reports 0 instead of passing as a
// success.
async function openTeamMenu(boot) {
  const fired = boot.byId("ws-switch").click();
  await flush();
  return fired;
}

async function assertTeamSwitcherListsTheTeamsTheEnvelopeNames() {
  const broken = [];
  const envelope = SCENARIOS[SWITCHER_SCENARIO].data.me || {};
  const scenTeams = envelope.teams || [];
  const activeId = (envelope.team || {}).id || "";
  let listHtml = "";

  // ── half 1 · the CORPUS's own envelope, rendered ──────────────────────────
  {
    const boot = bootScenario(SWITCHER_SCENARIO);
    await flush();
    const menu = boot.byId("team-menu");
    if (menu.hidden !== true) {
      broken.push("#team-menu did not BOOT hidden — index.html ships it `hidden`, so a harness that starts " +
        "it open makes the first #ws-switch click CLOSE it, and every claim below would be measuring the " +
        "shim's invention rather than the app");
    }
    const fired = await openTeamMenu(boot);
    if (fired < 1) {
      broken.push("#ws-switch ran " + fired + " click handler(s) — the switcher is DEAD, not merely wrong");
    }
    if (menu.hidden !== false) {
      broken.push("ONE click on #ws-switch left #team-menu hidden — it never opened");
    }
    listHtml = teamListHtml(menu.innerHTML || "");
    if (scenTeams.length === 0) {
      broken.push("the " + SWITCHER_SCENARIO + " /v1/me envelope names NO membership, so \"the menu lists " +
        "the user's teams\" is unfalsifiable here — the corpus stopped minting teams[] and this guard has " +
        "nothing left to compare against");
    } else if (!listHtml) {
      broken.push("no .team-list painted inside #team-menu (" + (menu.innerHTML || "").length + " bytes) — " +
        "the picker rendered nothing, so every row assertion below is vacuous");
    } else {
      if (listHtml.indexOf("No teams yet") !== -1) {
        broken.push("the switcher told the OWNER of " + JSON.stringify(scenTeams[0].name) + " they belong to " +
          "NO team, while /v1/me names " + scenTeams.length + " membership(s): .team-list is " +
          JSON.stringify(listHtml) + " — absence reported as a determinate answer");
      }
      const rows = teamRowsHtml(listHtml);
      for (const t of scenTeams) {
        const row = rows.find((r) => r.indexOf('data-team="' + t.id + '"') !== -1);
        if (!row) {
          broken.push("the envelope names membership " + JSON.stringify(t.id) + " and NO rendered row carries " +
            "data-team=" + JSON.stringify(t.id));
          continue;
        }
        if (row.indexOf(">" + t.name + "<") === -1) {
          broken.push("the row for " + JSON.stringify(t.id) + " renders no name — " + JSON.stringify(t.name) +
            " is what the envelope says it is called");
        }
        const marked = row.indexOf('class="team-check"') !== -1;
        if (marked !== (t.id === activeId)) {
          broken.push("the row for " + JSON.stringify(t.name) + " is " + (marked ? "MARKED" : "NOT marked") +
            " current and it is " + (t.id === activeId ? "" : "NOT ") + "the active team (meCache.team.id = " +
            JSON.stringify(activeId) + ")");
        }
      }

      // The SEARCH FILTER, driven. Not garnish: its handler ends in
      // setSelectionRange(), which this shim did not implement, so a real
      // keystroke threw TypeError out of dispatchEvent and the whole filter arm
      // was unreachable by any check. Both directions are asserted (a query
      // that matches NOTHING, then one that matches), because a filter that
      // never narrows and a filter that never restores are different bugs and a
      // one-way probe cannot tell them apart. The handler COUNT is deliberately
      // not asserted — only that at least one ran (D488).
      const q = boot.byId("team-menu-q");
      const miss = "zzz-no-such-team";
      q.value = miss;
      const firedMiss = q.dispatchEvent({ type: "input" });
      await flush();
      const missList = teamListHtml(menu.innerHTML || "");
      if (firedMiss < 1) {
        broken.push("typing into #team-menu-q ran " + firedMiss + " input handler(s) — the filter is not wired");
      }
      if (missList.indexOf("No team matches") === -1) {
        broken.push("a query no team can match left the list at " + JSON.stringify(missList) + " — the filter " +
          "either did not run or reported the wrong absence (a filtered-to-empty list must say so in the " +
          "query's own words, not fall back to \"No teams yet\")");
      }
      const hit = String(scenTeams[0].name).slice(0, 3);
      q.value = hit;
      q.dispatchEvent({ type: "input" });
      await flush();
      const hitList = teamListHtml(menu.innerHTML || "");
      if (hitList.indexOf('data-team="' + scenTeams[0].id + '"') === -1) {
        broken.push("clearing the query back to " + JSON.stringify(hit) + " did not restore the row for " +
          JSON.stringify(scenTeams[0].name) + " — the filter narrows and never widens: " +
          JSON.stringify(hitList));
      }
    }
  }

  // ── half 2 · the PIN WRITE, the only thing that writes bp.active-team ─────
  // The appended membership is the harness's (see extraMembership in
  // bootScenario, and why the corpus cannot supply one); the ACTIVE row it is
  // measured beside is the corpus's.
  {
    const extra = {
      id: "5b2c1e00-0000-4000-8000-0000000000f1",
      name: "Northwind Trading",
      slug: "northwind",
      role: "member",
    };
    const boot = bootScenario(SWITCHER_SCENARIO, { extraMembership: extra });
    await flush();
    const menu = boot.byId("team-menu");
    const pinAtBoot = boot.localStorage.getItem("bp.active-team");
    if (pinAtBoot !== null) {
      broken.push("bp.active-team was ALREADY " + JSON.stringify(pinAtBoot) + " at boot — nothing may seed the " +
        "pin (D489): a seeded pin flips teamAuthorityState to `stale` corpus-wide, and this guard would then " +
        "be reading the seed back rather than a write");
    }
    await openTeamMenu(boot);
    const rowFor = (id) => menu.querySelectorAll("[data-team]").find((el) => el.getAttribute("data-team") === id);

    if (!rowFor(extra.id)) {
      broken.push("the appended membership " + JSON.stringify(extra.id) + " painted no row, so the non-active " +
        "arm — the only path that writes bp.active-team — is unreachable and everything below is vacuous");
    } else {
      // Re-pinning the team you are ALREADY on must write nothing and reload
      // nothing: the guard app.js spends its early-return on.
      const activeRow = rowFor(activeId);
      if (!activeRow) {
        broken.push("no row carries the ACTIVE team " + JSON.stringify(activeId) + " — the no-op arm cannot be " +
          "measured");
      } else {
        const firedActive = activeRow.click();
        await flush();
        if (firedActive < 1) broken.push("the active team row ran " + firedActive + " click handler(s)");
        const afterActive = boot.localStorage.getItem("bp.active-team");
        if (afterActive !== null) {
          broken.push("clicking the ALREADY-ACTIVE team wrote bp.active-team = " + JSON.stringify(afterActive) +
            " — a re-pin plus a full page reload for a switch that did not happen");
        }
        if (boot.reloads.length !== 0) {
          broken.push("clicking the already-active team RELOADED the page " + boot.reloads.length + " time(s)");
        }
        if (menu.hidden !== true) broken.push("clicking the active team left the menu OPEN — it must close");
        await openTeamMenu(boot); // reopen: the rows are freshly-rendered stubs
      }
      const target = rowFor(extra.id);
      const firedOther = target ? target.click() : 0;
      await flush();
      if (firedOther < 1) {
        broken.push("the non-active team row ran " + firedOther + " click handler(s) — the switcher cannot switch");
      }
      const pin = boot.localStorage.getItem("bp.active-team");
      if (pin !== extra.id) {
        broken.push("clicking " + JSON.stringify(extra.name) + " left bp.active-team = " + JSON.stringify(pin) +
          " (expected " + JSON.stringify(extra.id) + ") — the pin api() sends as x-barkpark-team, and that " +
          "teamAuthorityState compares against, was never written");
      }
      if (boot.reloads.length !== 1) {
        broken.push("the pin write fired " + boot.reloads.length + " reload(s), not 1 — every team-scoped cache " +
          "(fleet, subscription, members) is stale the instant the pin moves, and only the reload repopulates them");
      }
    }
  }

  process.stdout.write(
    "  " + (broken.length ? "FAIL" : "ok  ") + " team-switcher — " + SWITCHER_SCENARIO + ": #team-menu boots " +
    "hidden, ONE #ws-switch click lists " + scenTeams.length + " membership(s) the envelope names with the " +
    "active one ✓-marked; the already-active row writes nothing, a non-active row pins bp.active-team + reloads\n");
  process.stdout.write("       .team-list → " + (listHtml || "(nothing painted)") + "\n");
  if (broken.length) {
    process.stdout.write("\nteam-switcher guard failed:\n  " + broken.join("\n  ") + "\n");
    process.exit(1);
  }
}

// ── EXPECTATIONS: the per-scenario view skeleton (edit HERE when markup moves) ─
const EXPECTATIONS = {
  // ── gr-p5-account-2fa (GR54/GR56/GR57): the account modal, recomposed ──────
  // The modal is CLICK-opened, so no deepLink reaches it. Drive the composition
  // through the REAL openModal primitive into the REAL #modal-body — the same
  // hook seam "loggedout-twofactor" uses for the login card — and pin the
  // rendered anatomy. The browser twin is mock.js's ?modal=account.
  "account-modal": {
    what: "the recomposed account modal — identity, sessions, password ON DEMAND, 2FA off-state; every lockout-bearing id intact",
    check(reg, hooks) {
      const model = hooks.accountModel({ team_id: "team_abc" }, SCENARIOS["account-modal"].data.me);
      assert.equal(model.twoFactorEnabled, false, "this fixture's /v1/me must say 2FA is off");
      hooks.openModal(hooks.accountModalHtml(model));
      const html = reg.get("modal-body").innerHTML || "";
      // The four bands of the recomposition.
      assert.ok(html.includes(">Your account<"), "the v4 heading must render");
      assert.ok(html.includes('class="am-identity"'), "the identity row must render");
      assert.ok(html.includes("owner of Guerrilla"), "the identity line must name the role and team");
      assert.ok(html.includes(">Sessions<"), "the sessions header must render");
      assert.ok(html.includes(">Two-factor authentication<"), "the 2FA header must render");
      // Password is DISCLOSED, not conditionally rendered: the form and all its
      // ids ship in the markup `hidden` so submitPasswordChange never unbinds.
      assert.ok(html.includes('id="am-pw-toggle"'), "the change-password disclosure link must render");
      assert.ok(/<form id="pw-form"[^>]*hidden/.test(html), "the password form must ship hidden, not absent");
      for (const id of ["modal-title", "pw-current", "pw-new", "pw-error", "sessions-box",
        "sessions-revoke-all", "pw-form", "modal-logout"]) {
        assert.ok(html.includes('id="' + id + '"'), "the modal must keep id=" + JSON.stringify(id));
      }
      // The footer is KEPT: both renders crop mid-scroll, so its absence is unproven.
      assert.ok(html.includes(">Close<") && html.includes(">Log out<"), "the Close / Log out footer must stay");
      // 2FA off-state, read free from /v1/me — no GET /v1/account/two-factor.
      assert.ok(html.includes('id="a2f-badge"') && html.includes(">Off<"), "the 2FA badge must read Off");
      assert.ok(html.includes('id="a2f-start"'), "the off state must offer the setup button");
      assert.ok(!html.includes('id="a2f-otp"'), "the off state must not draw the enroll form");
    },
  },
  "account-modal-tall": {
    what: "the NINE-session account modal — every row rendered, the escape hatches still present BELOW the list, no IP anywhere",
    check(reg, hooks) {
      const sessions = SCENARIOS["account-modal-tall"].data.accountSessions;
      assert.equal(sessions.length, 9, "the fixture must carry the tall shape, not the two-row short one");
      const rows = sessions.map((s) => hooks.sessionRowHtml(s)).join("");
      assert.equal((rows.match(/class="session-row"/g) || []).length, 9, "nine session rows render");
      assert.equal((rows.match(/session-revoke/g) || []).length, 8,
        "the current device is never self-revokable; the other eight are");
      // GR81: the fixture still SENDS an ip_address on every row; the panel
      // refuses to draw it, because on live every one of them is 172.18.0.1.
      assert.ok(!/84\.212\.31\./.test(rows), "no session IP is rendered");

      // Splice the rows in where loadSessions puts them, then pin that the
      // lockout-bearing controls survive at the bottom of a tall modal.
      hooks.openModal(hooks.accountModalHtml(
        hooks.accountModel({ team_id: "team_abc" }, SCENARIOS["account-modal-tall"].data.me)));
      const shell = reg.get("modal-body").innerHTML || "";
      const html = shell.replace(/(<div id="sessions-box"[^>]*>)[\s\S]*?(<\/div>)/, "$1" + rows + "$2");
      for (const id of ["sessions-revoke-all", "modal-logout"]) {
        assert.ok(html.includes('id="' + id + '"'), "the tall modal keeps id=" + JSON.stringify(id));
      }
      const lastRow = html.lastIndexOf("session-row");
      assert.ok(html.indexOf('id="modal-logout"') > lastRow,
        "Log out sits BELOW the whole session list — the anatomy that stranded it on live");
      // Honest about the limit: at the harness's 1000px height nine rows FIT, so
      // this documents the tall shape rather than proving overflow containment.
      assert.ok(html.includes(">Close<") && html.includes(">Log out<"), "the footer survives the tall list");
    },
  },
  // ── cch-w2-revoke-click-oracle: THE CLICK ORACLE ───────────────────────────
  // Every other expectation in this file reads markup. This one WATCHES THE APP
  // DO SOMETHING: it clicks #acct-btn and lets the real openAccountModal →
  // loadSessions → render → wire chain run, then clicks the buttons that chain
  // produced. Nothing is spliced, mounted or simulated on the app's behalf —
  // contrast account-modal-tall above, which hand-builds the rows with
  // sessionRowHtml because until now the list could not render here at all.
  //
  // WHAT IT ASSERTS, and why each assertion is the one that can fail:
  //   1. rows rendered through the REAL path      — proves the isConnected gate is open
  //   2. clicking a row's Revoke returns fired>0  — proves the button is WIRED for "click"
  //   3. DELETE /v1/account/sessions/<id> on wire — proves the right URL, right method
  //   4. the list SHRINKS 4→3                     — proves the server acted (stateful fixture, D39)
  //   5. sign-out-everywhere toasts the SERVER's count — the one text-observable false green
  //
  // cch-w2-revoke-ux-honesty AMENDED THIS SCENARIO IN PLACE (never forked it —
  // a parallel scenario would have left this one permanently red once the
  // confirm gate landed). Four assertions were added:
  //   6. the clicked row goes disabled + relabels — the pending state, read as STATE
  //   7. a per-row success TOAST mounts           — the leg used to succeed in silence
  //   8. sign-out-everywhere's DELETE is 0 after the trigger, 1 after #cm-confirm
  //   9. #modal-body carries the account screen again after the sheet closes
  //
  // COVERAGE BOUNDARY (D40 — an enforcement mechanism states its own limits).
  // Of the 8 unfixtured destructive DELETEs this slice is scoped to, exactly
  // ONE — /v1/account/sessions (the "Signed out other devices" revoke-all toast
  // in openAccountModal) — interpolates a server value into its toast, so it is
  // the only one where a missing fixture is visible AS TEXT
  // ("0 session(s) revoked."). This oracle covers it by TEXT. The per-row
  // sibling is covered by WIRE + STATE + its own success toast.
  //
  // THE REMAINING SIX ARE NOW COVERED TOO — cch-w2-revoke-oracle-round2 and
  // cch-bl-webhook-delete-oracle. Each toasts a client-side CONSTANT
  // ("Instance removed", "Webhook deleted"), so a generic 200 produces a
  // message that is both indistinguishable from the real one and, in fact,
  // honest: their defect was never "prod says 0", it was "nothing here would
  // catch a regression". So every one of them is a WIRE + STATE oracle and NOT
  // a text one — no text observable was invented to make them resemble the
  // sessions case. Where each one lives (by SCENARIO, because line numbers
  // drift and this list has already rotted once):
  //
  //   /v1/auth/logout            → account-modal-revoke, this scenario's tail
  //   /v1/github/installation    → providers-connected
  //   /v1/barkparks/:id          → panel-overview (runDecommission) AND
  //                                instance-remove-failed (removeInstance).
  //                                TWO handlers, not one:
  //                                grep -n 'api("DELETE", "/v1/barkparks/'
  //                                cloud/priv/static/app.js  → two hits.
  //   the webhook DELETE         → webhooks-panel
  //   /v1/sites/:id/github       → rollback
  //
  // WHAT THIS LIST GOT WRONG WHEN IT WAS WRITTEN, recorded rather than quietly
  // fixed: it counted the two /v1/barkparks/:id hits as "six remaining" while
  // cch-w10's leg 5/5 had already covered ONE of them (panel-overview's typed
  // Decommission). Five were open, not six. A boundary note is a measurement
  // with a timestamp, and this is what its decay looked like.
  //
  // WHAT THIS SHIM CAN AND CANNOT PROVE — REWRITTEN BY cch-bl-smoke-shim-fidelity,
  // which BUILT the two capabilities D55 and D56 had to route around. A stale
  // limits list is worse than none, so this states what the shim does TODAY:
  //   • DETACHMENT IS MODELLED, BY DECLARATION. A registry id whose declaring
  //     markup is overwritten out of its parent now reports isConnected: false
  //     (makeDom's `declaredBy` ledger — `grep -n 'const declaredBy' ` in this
  //     file). #sessions-box is authored into #modal-body by openAccountModal
  //     (`grep -n 'id="sessions-box"' cloud/priv/static/app.js` — ONE hit, and
  //     index.html ships no such id), so the confirm sheet's
  //     `bodyEl.innerHTML = html` detaches it and the re-render re-attaches it,
  //     both readable on the node itself (§5a′ and §5b assert BOTH directions).
  //     The D55 discipline — anchor post-swap assertions on #modal-body — is no
  //     longer the ONLY defence, and §5b keeps it as the second, independent
  //     one. WHAT IS STILL NOT MODELLED: the tree. Detachment is inferred from
  //     the id a parent's markup NAMES, so (i) an id that only ever lives in the
  //     shipped index.html shell is never declared and therefore never detaches
  //     (#modal-body, #view-root, #toast-stack — correct: the browser does not
  //     destroy them either), (ii) detaching a node does NOT cascade to ids its
  //     own markup declared, and (iii) two elements declaring the same id is
  //     last-writer-wins. A real tree would fix (ii) and (iii); the PARSED_TAGS
  //     note at the top of this file is the same missing tree.
  //   • CLICKS ARE REFUSED BY DISABLED ELEMENTS. dispatchEvent returns 0 and
  //     runs no handler when `el.disabled` and the type is one the browser
  //     suppresses (`SUPPRESSED_WHEN_DISABLED` — click/mousedown/mouseup/
  //     dblclick/key*). ⇒ A pending/disabled state may now be proven by the
  //     SECOND CLICK, which is the read that measures the consequence (§2c);
  //     reading `disabled`/`textContent` directly (§2b) still measures the
  //     attribute, and both are worth keeping. NOT suppressed: "input",
  //     "change", "submit" and every other non-interaction type, because the
  //     browser delivers those to disabled nodes too and app.js replays some
  //     programmatically.
  //   • A RE-RENDER KILLS ITS LISTENERS (cch-w2-revoke-oracle-round2,
  //     `_resetHandlers`). An id whose declaring markup is replaced — dropped
  //     OR re-emitted — hands back a node with no handlers, because the browser
  //     destroyed the old one. ⇒ A click count is now an EXACT number, not a
  //     floor: `el.click() === 1` is assertable, and a 2 means either the app
  //     double-wired or this model broke. Before it, listeners accumulated and
  //     one click on a twice-rendered control issued two requests.
  //   • STILL TRUE, AND STILL THE FIRST THING TO CHECK: the parse is FLAT
  //     (PARSED_TAGS is `button|a`; containers arrive only through
  //     `GROUPED_CLASSES`), a parsed stub's own innerHTML is always "", and
  //     `contains()` does not exist. See the shim contract at the top.
  //   • A REGISTRY NODE DOES NOT INHERIT ITS MARKUP'S BOOT ATTRIBUTES. Only
  //     index.html's `hidden` is seeded (HIDDEN_IDS); app-RENDERED `disabled`
  //     is not. So a sheet that ships `<button id="x" disabled>` answers
  //     `reg.get("x").disabled === false` — read the disarmed state off the
  //     PARSED node (`reg.get("modal-body").querySelector("#x")`) and the armed
  //     state off the registry node the app writes. The webhook-delete leg does
  //     exactly that, and says so.
  "account-modal-revoke": {
    what: "THE CLICK ORACLE — real clicks drive revoke: rows render, a row revoke pends + toasts + shrinks the list, sign-out-everywhere waits for its danger-tier confirm before reporting the SERVER's count, and Sign out issues exactly one DELETE /v1/auth/logout and clears the local session",
    async check(reg, hooks, ctx) {
      // ─ 1. the modal opens by CLICK, exactly as a user opens it ─────────────
      const acct = reg.get("acct-btn");
      assert.ok(acct, "#acct-btn was never touched — init() did not wire the shell");
      assert.equal(acct.click(), 1, "#acct-btn must have exactly one click handler (it opens the account modal)");
      await ctx.settle();

      // The session list rendered through the REAL loadSessions, which is only
      // possible because the shim now answers isConnected (loadSessions' box guard).
      const box = reg.get("sessions-box");
      const rendered = box.innerHTML || "";
      assert.ok(rendered.includes("session-row"),
        "#sessions-box is empty — loadSessions bailed at its `if (!box.isConnected) return;` guard, " +
        "which is the state this harness sat in for its whole existence");
      assert.equal(countMatches(rendered, 'class="session-row"'), 4, "the fixture's four sessions render");
      assert.equal(ctx.countCalls("GET", "/v1/account/sessions"), 1, "the list was fetched once on open");

      // ─ 2/3/4. the PER-ROW revoke: wired, right URL, and it ACTS ────────────
      const revokes = box.querySelectorAll(".session-revoke");
      assert.equal(revokes.length, 3, "three revokable rows — the current device is never self-revokable");
      const victim = revokes[0].getAttribute("data-id");
      assert.ok(victim && victim !== "sess_here",
        "the row must carry a real data-id and must not be the acting session, got " + JSON.stringify(victim));

      // THE CLICK-COUNT ASSERTION IS LOAD-BEARING. This shim's selector support
      // is narrow, so a selector it cannot parse answers an EMPTY list — and a
      // loop over nothing "succeeds". A dead button (wired to "mousedown", say)
      // dispatches zero handlers, and only this line notices.
      const fired = revokes[0].click();
      assert.equal(fired, 1,
        "the per-row Revoke dispatched " + fired + " click handlers — the button is DEAD. " +
        "Every source string can still be present and correct; nothing is bound to \"click\".");

      // ─ 2b. cch-w2-revoke-ux-honesty: the PENDING state, read DIRECTLY ──────
      // The handler disables the button and swaps its label BEFORE api() is
      // called, so both are observable synchronously — before the settle that
      // repaints the list out from under this node.
      //
      // ASSERTED BY STATE. D56 wrote "NEVER BY A SECOND CLICK" here because the
      // shim's dispatchEvent had no `disabled` guard, so `revokes[0].click()` on
      // a CORRECTLY disabled button returned 1 and redded the DELETE-count
      // assertion below. cch-bl-smoke-shim-fidelity built the guard, so the
      // second click is now legal and §2c makes it — these two lines stay
      // because the attribute and the consequence are different measurements.
      assert.equal(revokes[0].disabled, true,
        "the clicked Revoke must go disabled while its DELETE is in flight — an enabled button " +
        "during an unacknowledged destructive request invites the double-revoke");
      assert.equal(revokes[0].textContent, "Revoking…",
        "the label must confess the in-flight state, got " + JSON.stringify(revokes[0].textContent));

      // ─ 2c. THE SECOND CLICK (cch-bl-smoke-shim-fidelity) ──────────────────
      // D56 BANNED this line, and was right to: the shim delivered clicks to
      // disabled elements, so the working guard returned 1 here and doubled
      // the DELETE count asserted below — a correct fix read as broken. The
      // shim now refuses interaction events on a disabled node (makeEl's
      // dispatchEvent, `SUPPRESSED_WHEN_DISABLED`), so this is the assertion
      // that actually measures what the pending state is FOR: an operator who
      // double-clicks Revoke must not issue two DELETEs. The `disabled` read
      // above proves the ATTRIBUTE; only this proves the CONSEQUENCE.
      assert.equal(revokes[0].click(), 0,
        "the disabled Revoke still ran its click handler — the pending state is decoration, " +
        "and a double-click issues a second DELETE for a session that is already gone");

      await ctx.settle();

      assert.equal(ctx.countCalls("DELETE", "/v1/account/sessions/" + victim), 1,
        "the click must issue exactly one DELETE for that row's id");
      // The per-row leg used to succeed in SILENCE: the row simply vanished on
      // the re-render, which is indistinguishable from a render glitch.
      const rowToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(rowToast.includes("Device signed out"),
        "a successful per-row revoke must SAY SO — no success toast mounted; got: " + rowToast);
      // D39: this line is the reason the fixture is stateful. Against a static
      // fixture the re-render returns a byte-identical list, so this assertion
      // would hold whether or not the DELETE ever reached the server — a false
      // green planted inside the anti-false-green scenario.
      const after = reg.get("sessions-box").innerHTML || "";
      assert.equal(countMatches(after, 'class="session-row"'), 3,
        "the revoked row must be GONE on the re-render (4 → 3); an unchanged list means the DELETE did nothing");
      assert.ok(!after.includes('data-id="' + victim + '"'), "the revoked row's id must not come back");
      assert.equal(ctx.countCalls("GET", "/v1/account/sessions"), 2, "the success arm refetches the list");

      // ─ 5. SIGN OUT EVERYWHERE: gated, then the text-observable false green ─
      const all = reg.get("sessions-revoke-all");
      assert.equal(all.click(), 1, "the Sign-out-everywhere button must be wired for \"click\"");

      // ─ 5a. cch-w2-revoke-ux-honesty: THE TRIGGER ONLY OPENS THE SHEET ─────
      // The blast-radius button must NOT fire on the first click. This is the
      // assertion that catches a gate someone removes "to simplify" later: with
      // no confirmModal the DELETE is already on the wire right here.
      assert.equal(ctx.countCalls("DELETE", "/v1/account/sessions"), 0,
        "sign-out-everywhere fired its DELETE on the FIRST click — the confirm gate is gone, " +
        "and an irreversible-feeling action just happened with no way to say no");
      // Proven by what #modal-body actually CONTAINS — reg.get() alone would
      // answer a freshly-minted empty stub for any id and prove nothing.
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes('id="cm-confirm"'),
        "the confirm sheet did not mount into #modal-body; got: " + sheet.slice(0, 200));
      assert.ok(sheet.includes("Sign out everywhere else?"),
        "the sheet must name what it is about to do, in the title");
      assert.ok(sheet.includes("btn-danger"),
        "GR41: a grave-but-reversible action wears the danger tier's weight");

      // ─ 5a′. THE DETACHMENT, READ ON THE NODE ITSELF (cch-bl-smoke-shim-fidelity)
      // #sessions-box was authored INTO #modal-body (app.js openAccountModal,
      // `grep -n 'id="sessions-box"' cloud/priv/static/app.js` — one hit, and
      // index.html ships no such id), so the confirm sheet's
      // `bodyEl.innerHTML = …` destroyed it. Until this slice the shim's flat
      // registry answered isConnected: true here forever and #sessions-box kept
      // serving its stale rows to every assertion — the immortal node D55 had
      // to route around. THIS PAIR IS THE DISCRIMINATOR: false while the sheet
      // owns the body, true again below only if something re-rendered. Asserted
      // in BOTH directions so a model that simply never detaches, and a model
      // that never re-attaches, are each a red.
      assert.equal(reg.get("sessions-box").isConnected, false,
        "#sessions-box still reports isConnected: true while the confirm sheet owns #modal-body — " +
        "the shim is not modelling detachment, so every assertion about the account screen " +
        "below this point is reading a node the browser already destroyed");

      // D54, AS AMENDED BY cch-w10. The confirm click goes BETWEEN the trigger
      // and the settle. The tier is `danger`, NOT `destroy` — a destroy sheet
      // would additionally need #cm-typed's value set plus an "input" event
      // before #cm-confirm arms, and (measured) an un-armed #cm-confirm STILL
      // returns 1 from click(), so the `fired == 1` idiom cannot detect the
      // disarm. D54 concluded from that that the disarm was UNOBSERVABLE here.
      // IT IS OBSERVABLE — on two objects D54 did not separate:
      //   • #modal-body's PARSED child carries the SHIPPED state (the `disabled`
      //     attribute confirmModalHtml emitted). This is the line below.
      //   • the WIRE carries the effect: openConfirmModal's handler bails at
      //     `if (!confirmModalArmed(state)) return;`, so an unarmed Confirm
      //     issues zero requests (asserted on all three destroy legs).
      // What is NOT observable is the disarm on `reg.get("cm-confirm")` — a
      // fresh registry stub answers disabled=false whether or not any sheet
      // mounted, which is why reading it would be a false green.
      // THIS LINE IS THE DISCRIMINATOR'S OTHER HALF: the same read that must
      // answer `true` on a destroy sheet must answer `false` here, or it is not
      // measuring the tier at all.
      const parsedDanger = parsedConfirmButton(reg);
      assert.ok(parsedDanger, "the danger sheet's Confirm must be parsed out of #modal-body");
      assert.equal(parsedDanger.disabled, false,
        "a DANGER-tier Confirm ships ARMED (no typed echo). If this reads true, the destroy-tier " +
        "disarm assertions elsewhere are measuring something other than the tier.");
      const cmConfirm = reg.get("cm-confirm");
      assert.ok(cmConfirm, "#cm-confirm was never touched — openConfirmModal did not wire the sheet");
      assert.equal(cmConfirm.click(), 1, "the sheet's Confirm must be wired for \"click\"");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/account/sessions"), 1, "one sign-out-everywhere DELETE on the wire");

      // ─ 5b. THE HARNESS'S OWN FALSE GREEN, CLOSED (D55) ────────────────────
      // In a real browser #sessions-box lives INSIDE #modal-body, so mounting
      // the confirm sheet destroyed it and closeModal() emptied what was left;
      // a post-success `loadSessions()` would bail at `if (!box) return` and
      // the operator would be left with no account modal at all. When D55 wrote
      // this, the shim could not see it: the #id registry was FLAT and every
      // node reported isConnected: true, so #sessions-box was immortal and this
      // #modal-body anchor was the ONLY thing that could discriminate.
      // cch-bl-smoke-shim-fidelity made the node itself honest (§5a′ above), so
      // the anchor is now the SECOND, independent witness rather than the only
      // one — kept deliberately: it reads the CONTENT the browser replaced,
      // where §5a′ reads the connection. MUTATION-KILLED BOTH WAYS: green with
      // onConfirm's openAccountModal() re-render, red without it.
      // The same read, now the other way round: the re-render must put the node
      // BACK. This is the assertion the #modal-body anchor below used to have
      // to stand in for — it goes red on the very mutation D55 measured (drop
      // onConfirm's openAccountModal() re-render) without reading #modal-body
      // at all.
      assert.equal(reg.get("sessions-box").isConnected, true,
        "#sessions-box is still detached after the sign-out-everywhere success — the confirm sheet " +
        "replaced the account screen and nothing re-rendered it, so the operator is left staring at " +
        "an empty dialog. onConfirm must call openAccountModal() after ctl.succeed().");

      const reborn = reg.get("modal-body").innerHTML || "";
      assert.ok(reborn.includes('id="sessions-box"'),
        "#modal-body no longer contains the account modal — the confirm sheet replaced it and " +
        "nothing re-rendered, so in a real browser the operator is left staring at an empty dialog. " +
        "onConfirm must call openAccountModal() after ctl.succeed(). #modal-body is: " +
        JSON.stringify(reborn.slice(0, 120)));
      assert.ok(reborn.includes('id="modal-logout"') && reborn.includes(">Your account<"),
        "the re-render must be the WHOLE account screen, not a fragment");

      const toasts = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(toasts.includes("Signed out other devices"), "the success toast must actually mount");
      // Two sessions remained revokable after the per-row revoke, so the SERVER
      // says 2. The "Signed out other devices" revoke-all toast renders
      // `((r.data && r.data.revoked) || 0)` — with no DELETE
      // fixture the generic `/v1/` 200 {} answers `{}`, `revoked` is undefined,
      // and the console cheerfully announces a revoke of nothing.
      assert.ok(!toasts.includes("0 session(s) revoked"),
        "THE FALSE GREEN: the console reported '0 session(s) revoked.' after revoking real sessions — " +
        "DELETE /v1/account/sessions answered the generic 200 {} instead of {revoked: N}");
      assert.ok(toasts.includes("2 session(s) revoked"),
        "the toast must carry the SERVER's count (2 others remained), not a client-invented number; got: " + toasts);

      // And the list settles on the acting device alone.
      const settled = reg.get("sessions-box").innerHTML || "";
      assert.equal(countMatches(settled, 'class="session-row"'), 1, "only the acting session survives");
      assert.ok(settled.includes("This device"), "and it is the current one");

      // ── cch-w2-revoke-oracle-round2 · SIGN OUT — DELETE /v1/auth/logout ────
      // The last leg of the modal, and it is last for a reason: its success arm
      // calls clearSession() + render(), which tears the whole authed shell
      // down. Everything above had to have happened already.
      //
      // WHY THIS ONE IS NOT A TEXT ASSERTION. The handler is
      //   grep -n 'api("DELETE", "/v1/auth/logout")' cloud/priv/static/app.js
      // — one hit, inside openAccountModal's #modal-logout listener — and it
      // .catch()es the request outright: "even a network failure must still
      // drop the local session". So there is NO toast, no server value, and no
      // rendered difference between a logout that reached the server and one
      // that never left the browser. The only two honest observables are the
      // WIRE (exactly one DELETE, right method, right path) and the LOCAL
      // consequence (the session key is gone from storage), and this leg reads
      // both — because either one alone passes on a broken half.
      assert.ok(reborn.includes('id="modal-logout"'),
        "this leg clicks the registry node, and byId auto-creates one for any id — so the RENDER half " +
        "is what proves the control is on the page at all. #modal-body declares no #modal-logout.");
      assert.ok(ctx.localStorage.getItem("bpcloud.session"),
        "the scenario must still hold a session before the sign-out click, or 'the session was cleared' " +
        "is vacuously true");
      assert.equal(ctx.countCalls("DELETE", "/v1/auth/logout"), 0, "nothing signed out before the click");
      const logout = reg.get("modal-logout");
      // Exactly one: openAccountModal ran TWICE in this check (the open at §1
      // and the post-success re-render at §5b), and each run re-declares
      // #modal-logout in #modal-body's markup — which in a browser destroys the
      // old node and its listener with it. `_resetHandlers` in makeDom models
      // that; without it this reads 2 and the DELETE count below reads 2, which
      // is the accumulated-listener artifact, not the app.
      assert.equal(logout.click(), 1,
        "Sign out dispatched no click handler — it is DEAD (a modal whose only exit is the browser's back button)");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/auth/logout"), 1,
        "the sign-out click must revoke the calling token with exactly one DELETE /v1/auth/logout; got " +
        ctx.countCalls("DELETE", "/v1/auth/logout"));
      assert.equal(ctx.localStorage.getItem("bpcloud.session"), null,
        "the local session survived the sign-out — clearSession() is the half that must happen even when the " +
        "revoke fails, and it did not happen at all");
    },
  },
  "account-modal-2fa-badcode": {
    what: "enrollment rejected — 422 invalid_otp renders INLINE in the .form-error grammar, the form survives, and no toast fires",
    check(reg, hooks) {
      // The panel renders are pure, so drive the state the 422 arm produces and
      // pin the honest recovery: the code field stays, carrying the sentence.
      const copy = hooks.accountTwoFactorErrorCopy(422, { error: "invalid_otp" });
      assert.ok(copy && copy.includes("didn't match"), "invalid_otp must get its own sentence");
      const uri = "otpauth://totp/Barkpark%20Cloud:ada@acme.com?secret=JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP&issuer=Barkpark%20Cloud";
      hooks.openModal(hooks.accountModalHtml(hooks.accountModel({}, SCENARIOS["account-modal-2fa-badcode"].data.me)));
      const panel = hooks.accountTwoFactorPanelHtml({ phase: "enroll", uri, secret: "JBSWY3DPEHPK3PXP", error: copy });
      assert.ok(panel.includes('class="form-error a2f-error"'), "the error must ride the inline grammar");
      assert.ok(panel.includes('id="a2f-otp"'), "the code field must survive a rejection");
      assert.ok(panel.includes("a2f-qr-svg"), "the QR must still be there to re-scan");
      assert.ok(!/\brate[ -]?limit|\b429\b|try again in/i.test(panel),
        "GR52b: this route is genuinely unthrottled — no rate-limit theatre");
      // The toast stack is untouched: inline errors NEVER dive into a toast.
      // An untouched #toast-stack never enters the registry at all — either way,
      // nothing was appended to it.
      const toasts = reg.get("toast-stack");
      assert.ok(!toasts || !(toasts.innerHTML || "").length, "a field error must not fire a toast");
    },
  },
  "account-modal-2fa-on": {
    what: "2FA already ON — the on-row with regenerate + turn-off, derived from /v1/me alone (zero extra fetches)",
    check(reg, hooks) {
      const model = hooks.accountModel({ team_id: "team_abc" }, SCENARIOS["account-modal-2fa-on"].data.me);
      assert.equal(model.twoFactorEnabled, true, "the on-state must come from /v1/me's two_factor_enabled");
      hooks.openModal(hooks.accountModalHtml(model));
      const html = reg.get("modal-body").innerHTML || "";
      assert.ok(html.includes(">On<"), "the badge must read On");
      assert.ok(html.includes('id="a2f-regen"'), "the on-row must offer regenerate");
      assert.ok(html.includes('id="a2f-disable"'), "the on-row must offer turn-off");
      assert.ok(!html.includes('id="a2f-start"'), "an enrolled account is never offered setup again");
    },
  },
  loggedout: {
    what: "the sign-in screen (no shell)",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must be hidden");
      assert.equal(reg.get("login-card").hidden, false, "login card must be visible");
    },
  },
  empty: {
    what: "first-run onboarding on an empty dashboard (A4 welcome runway)",
    container: "overview-body",
    // A4 replaced the start-card checklist with the welcome runway; this
    // expectation lagged the markup (pre-existing red) — updated to the
    // shipped welcomeHeroHtml skeleton.
    includes: ["runway-hero", "Launch your first Barkpark", "runway-sub"],
    excludes: ['class="fleet-row"'],
  },
  // cch-w48-s6: the frame this epic's crown is named for, rendered for the first
  // time. A member on a ZERO-instance team gets the welcome runway, and until
  // cch-w47-s1 that runway was a full launch form — a name field, two provider
  // tabs and a submit — against `go_live`, which answers a plain member 403
  // {required:"admin"} BEFORE it ever reaches the entitlement check. This is the
  // corpus proof of that fix: the refusal card is what renders, and the form is
  // GONE rather than merely disabled (a disabled submit leaves three live
  // controls still selling the refusal).
  "overview-member-empty-fleet": {
    what: "a member with no instances is REFUSED up front, in the server's own words — the launch form is withheld, not disabled",
    container: "overview-body",
    includes: [
      "empty-state",
      "You can&#39;t launch for this team",
      "Launching needs the admin role on this team. Ask a team admin to launch it, or to give you that role.",
    ],
    // The whole form, named control by control — the name field, the provider
    // seg-buttons and the submit. `launch-form` alone would go green on a form
    // that lost only its wrapper class.
    excludes: [
      "launch-form",
      "launch-flow-name-",
      "seg-btn",
      'type="submit"',
      "Create your first Barkpark",
    ],
  },
  // cch-w48-s6: the site layer, entered by a MEMBER for the first time. This is
  // the PAIRED POSITIVE CONTROL — it asserts what a member legitimately keeps,
  // so the fences cch-w48-s2/s3 draw around this screen cannot be satisfied by
  // an empty page. It deliberately says NOTHING about `#site-github`: s2 omits
  // that control for a member, and an expectation pinning today's unfenced
  // render would freeze the defect into the baseline.
  "site-member": {
    what: "a member on the site screen keeps every member-legal control — deploy, rollback, promote rows, env",
    container: "site-body",
    includes: [
      'id="site-deploy"',
      'id="site-rollback"',
      'data-kind="redeploy"',
      'data-kind="rollback"',
      ">Roll back to this<",
      'id="site-env-edit"',
      "dep-current",
    ],
  },
  "loggedout-invited": {
    what: "the sign-in banner announcing the parked invitation",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      const banner = reg.get("auth-invite").innerHTML;
      assert.ok(banner.includes("Northwind"), "banner must name the inviting team");
      assert.ok(banner.includes("ada@acme.com"), "banner must name the invited address");
    },
  },
  "mixed-fleet": {
    what: "one fleet row per instance, each with a status pill",
    container: "fleet-body",
    includes: ["status-pill"],
    // Structural, count-based: exactly one .fleet-row per fixture instance.
    fleetRowsEqualFixture: true,
  },
  provisioning: {
    what: "the watched provisioning timeline",
    container: "instance-body",
    // #1180 (9eff1fee) retired the bp-tl-step* classes: the timeline now renders
    // the shared newStepsHtml rows (new-steps / new-step active) — expectation lagged.
    includes: ["bp-timeline", "new-steps", "new-step active", "bp-console", "Provisioning"],
    excludes: ["bp-tl-fail"],
  },
  failed: {
    what: "the setup-failed state with the verbatim error",
    container: "instance-body",
    // #1180 (9eff1fee) retired the bp-tl-step* classes: the failed row is now
    // new-step failed (the bp-tl-fail block itself survived) — expectation lagged.
    // cch-w45-bl: `"Retry setup"` alone is the LABEL, and the label is what the
    // REFUSED arm renders too (`<button … disabled title="You need the admin
    // role…">Retry setup</button>`), so this line passed on a member's dead
    // control just as happily as on an admin's live one. retryInstance has TWO
    // live mounts — this timeline one and the verify card's
    // [data-vf-reprovision] (paid by `verify-no-credentials` below) — and one
    // census row covers both, so a green over one is not a green over the verb.
    // `data-tl-retry` is the attribute wireInstanceTimeline binds on and
    // `bp-tl-retry` is the viewport dock the refused arm deliberately drops.
    includes: ["bp-tl-fail", "new-step failed", "Setup failed", "Retry setup", "data-tl-retry", "bp-tl-retry",
      "Studio never came up"],
  },
  // Rollback/redeploy (charter D7): the current live row offers Redeploy + the
  // Current chip, the prior live row offers rollback, the failed row neither.
  //
  // cch-w67-followup (wave 68): CONVERTED from an `includes` list to a `check`,
  // because the one line that joins every control on this screen to its code —
  // `var sdel = $("#site-delete"); if (sdel) sdel.addEventListener("click", …)`
  // in loadSite — was driven by NOTHING. The W67 destroy tier shipped behind
  // five green gates and not one of them could fail on a dead button: the
  // binding census greps the fetch path out of runSiteDelete's SOURCE, the
  // member-authority sweep proves #site-delete RENDERS, the review pass enters
  // AT runSiteDelete with a hand-built ctl. A typo in the attach line ships a
  // Delete that does nothing, and every gate stays green — the epic's own
  // vacuous-green shape. The hole belongs to the ROW, not to Delete: the same
  // one line wires Deploy, Roll back, the retries, GitHub, Edit env and the
  // theme select.
  //
  // WHY HERE AND NOT IN A NEW SCENARIO. This scenario already boots loadSite's
  // SUCCESS branch, so every attach has already run by the time the check
  // reads. Dispatching a real event and counting the handlers that ran is the
  // whole proof, and it costs no fixture and no scenario (PIN_TOTAL_SCENARIOS
  // is untouched — D817 refused that bump for the crown itself).
  //
  // THE RUNNER RETURNS EARLY ON `check` (runScenario, below) — an `includes`
  // list beside one is SILENTLY DROPPED, not merged. The five needles this
  // expectation has always shipped are therefore re-asserted VERBATIM first,
  // before any dispatch, so the conversion adds a proof and subtracts none.
  //
  // `> 0`, NEVER `=== 1`: the #id registry is IMMORTAL and handlers ACCUMULATE
  // across re-renders (this scenario measures 2 per control today, because
  // loadSite paints twice). The count that means DEAD is 0 — which is exactly
  // what deleting an addEventListener line produces here, measured.
  rollback: {
    what: "deployment rows with Redeploy / Roll-back actions + the Current chip, every control loadSite wires DISPATCHES — and the repo UNLINK is clicked for real: one DELETE /v1/sites/:id/github, the server row loses its repo, the header repaints to the reconnect verb",
    async check(reg, hooks, ctx) {
      const body = reg.get("site-body").innerHTML || "";
      for (const needle of ['data-kind="redeploy"', ">Redeploy<", ">Roll back to this<", "dep-current", "live since "]) {
        assert.ok(body.includes(needle), "#site-body missing " + JSON.stringify(needle));
      }

      // dr-w1-s2 (criterion 1): the LEDGER'S CLASS, on the row, in a browser.
      // `deployment_json/1` has carried `failure_class` since W1 S2 and nothing
      // rendered it — the operator saw the humanized prose and had no way to
      // name the class the census counts. Read OFF the payload: the fixture says
      // BUILD_FAILED and the pill says BUILD_FAILED, with no map in between.
      assert.ok(body.includes(">BUILD_FAILED<"),
        "the failed row must carry its ledger class as a pill; got: " + body);
      // And only the row that HAS one grows one — two live rows sit beside it
      // with failure_class null, and neither may invent a class.
      assert.equal((body.match(/>BUILD_FAILED</g) || []).length, 1,
        "exactly one row carries a class — a null failure_class must render NO pill");

      // Every listener loadSite attaches on the success branch, with the event
      // type it was registered for — the shim dispatches PER TYPE, so a control
      // wired for "change" and clicked reports 0 (site-theme-select, measured).
      const WIRED = [
        ["site-delete", "click"],       // confirmSiteDelete — the W67 destroy tier
        ["site-deploy", "click"],       // confirmDeploy
        ["site-rollback", "click"],     // confirmSiteRollback
        ["site-deploys-retry", "click"], // loadSite(id, { quiet: true })
        ["site-github", "click"],       // openSiteGithub
        ["site-env-edit", "click"],     // openSiteEnvModal
        ["site-theme-select", "change"], // the PATCH …/sites/:id theme write
      ];
      for (const [id, type] of WIRED) {
        const el = reg.get(id);
        assert.ok(el, "#" + id + " was never even looked up — loadSite's attach line for it is gone");
        assert.ok(el.dispatchEvent({ type }) > 0,
          "#" + id + " renders but no \"" + type + "\" handler ran — the control is DEAD " +
          "(loadSite's addEventListener for it never attached)");
      }

      // NEGATIVE CONTROL, so the seven greens above mean something: #site-load-retry
      // belongs to the DEGRADE path (siteLoadFailureHtml), which this successful
      // read never paints — loadSite never looks it up, so it is absent from the
      // registry entirely. If this ever resolves, the success and failure branches
      // have merged and the assertions above are reading the wrong screen.
      assert.equal(reg.get("site-load-retry"), undefined,
        "#site-load-retry must NOT exist on a successful site read — it is the failure branch's control");

      // ── cch-w2-revoke-oracle-round2 · DELETE /v1/sites/:id/github ──────────
      // The repository UNLINK — the last of the six destructive DELETEs the
      // COVERAGE BOUNDARY note named as uncovered. Re-derive both halves by
      // symbol, never by line:
      //   grep -n "function disconnectSiteGithub" cloud/priv/static/app.js
      //   grep -n "function openSiteGithub"       cloud/priv/static/app.js
      // The door is TWO clicks deep and that is why it had no oracle: the
      // control lives inside a modal openSiteGithub paints only AFTER
      // GET /v1/github/repos answers with a repo list, and no scenario carried
      // one — every boot got the "Couldn't load your repositories" arm, so
      // #github-disconnect-site had never existed on any rendered surface.
      // `githubRepos` on this scenario is that fixture.
      //
      // The WIRED sweep above already clicked #site-github once, and its
      // in-flight repo read lands on this settle along with five other modal
      // opens — last writer owns #modal-body, and it is not this one. So the
      // sheet is opened AGAIN here, deliberately, rather than assuming the
      // sweep left it standing.
      await ctx.settle();
      assert.equal(reg.get("site-github").click(), 1, "#site-github must still be wired after the sweep");
      await ctx.settle();

      const site = SCENARIOS.rollback.data.sites[0];
      const ghPath = "/v1/sites/" + site.id + "/github";
      const picker = (reg.get("github-connect-body") || {}).innerHTML || "";
      assert.ok(picker.includes('id="github-repo"'),
        "the repo picker never painted — openSiteGithub's GET /v1/github/repos took a failure arm, so the " +
        "control this leg clicks does not exist and everything after it would be vacuous. Got: " + picker.slice(0, 200));
      assert.ok(picker.includes('id="github-disconnect-site"'),
        "the CONNECTED arm must paint the Disconnect control (site.github_webhook_configured is the discriminator); " +
        "got: " + picker.slice(0, 400));
      assert.equal(ctx.countCalls("DELETE", ghPath), 0, "opening the picker must not unlink anything");
      assert.equal(reg.get("github-disconnect-site").click(), 1,
        "the site Disconnect dispatched no click handler — it is DEAD");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", ghPath), 1,
        "exactly one DELETE " + ghPath + " must reach the wire; got " + ctx.countCalls("DELETE", ghPath));

      // THE STATE HALF, off the SERVER's own row. Until this wave the path fell
      // through the terminal `/v1/` 200 {}, so the unlink "succeeded" and the
      // refetch below re-served a site still carrying github_repo.
      const served = route("rollback", "GET", "/v1/sites/" + site.id, ctx.state);
      assert.equal(served.status, 200, "the site must still be readable after the unlink");
      assert.equal(served.body.site.github_repo, null,
        "the SERVER still links " + JSON.stringify(served.body.site.github_repo) +
        " — the unlink hit a fixture that cannot lose");
      assert.equal(served.body.site.github_webhook_configured, false,
        "…and the push webhook must be gone with it, or the header still paints the connected arm");

      // AND THE HEADER REPAINTS, because the success arm calls loadSite(). The
      // chip and the verb are the SAME control (#site-github): connected paints
      // the repo name in mono, unconnected paints the verb — so this pair is
      // the whole before/after of the unlink on the screen the operator is on.
      const headAfter = reg.get("site-body").innerHTML || "";
      assert.ok(!headAfter.includes('id="site-github" type="button"><span class="mono">acme/web</span>'),
        "the header still shows the repo chip for a repository that is no longer linked");
      assert.ok(headAfter.includes('id="site-github" type="button">Connect GitHub repo<'),
        "the unlinked header must offer the way back in; got the strip: " + headAfter.slice(0, 200));
      const ghToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(ghToast.includes("Repository disconnected") && ghToast.includes("acme.com"),
        "the unlink must report itself, naming the domain that stops deploying; got: " + ghToast.slice(0, 300));
    },
  },
  // The 409-failure twin boots to the same skeleton; the inline-failure morph
  // itself is click-driven (covered by the vm unit tests + live browser).
  "promote-failure": {
    what: "the same deploy rows (failure path is exercised on click)",
    container: "site-body",
    includes: ['data-kind="redeploy"', ">Roll back to this<"],
  },
  // Rollback endgame — the promote's own three states (charter wave-4 owed).
  // IN-FLIGHT: a Building row streams on TOP while the still-live deploy keeps
  // the Current chip (a queued build serves no traffic yet). The exact skeleton
  // the optimistic promoteReconcile paints — frozen for the eye.
  "promote-in-flight": {
    what: "the new build streams on top; Current stays on the live deploy",
    container: "site-body",
    includes: ["dep-pill dep-building", "dep-current", ">Redeploy<", ">Roll back to this<"],
  },
  // cch-deploy-detail-render-has-no-cap: the live sub-caption at its STORE cap.
  // The first scenario in this harness to carry a `.deploy-detail` longer than
  // the word "building" — before it, no instrument here had ever rendered the
  // one caption on the deploy rail with no render bound. Two building rows in
  // one paint: the 2 KB caption under measurement and the ordinary builder
  // caption that is its control. The GEOMETRY is overflow-guard.mjs's
  // W34-deploy-detail-render-bound leg; this entry asserts only that both rows
  // reach the DOM, because a leg measuring a screen that rendered one of them
  // would be half green by construction.
  "deploy-detail-cruel": {
    what: "the 2 KB live sub-caption under the status pill, beside an ordinary builder caption",
    container: "site-body",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      const captions = countMatches(body, 'class="deploy-detail"');
      assert.equal(captions, 2, `both building rows render a .deploy-detail (got ${captions})`);
      // The caption's own bytes, not a transcription: read off the fixture's
      // constants. The CRUEL slice stops at 55 characters on purpose — the
      // module path after it carries apostrophes that app.js html-escapes, and
      // an assertion that has to re-implement esc() is asserting its own copy
      // of the renderer rather than the renderer.
      assert.ok(body.includes(SCEN_DEPLOY_DETAIL_KIND), "the ordinary builder caption renders verbatim");
      assert.ok(
        body.includes(SCEN_DEPLOY_DETAIL_CRUEL.slice(0, 55)),
        "the cruel caption renders — its opening 55 characters are in the DOM",
      );
      // The STORE is what the DOM carries: all of it. A renderer that starts
      // cutting the caption in JS would pass every geometry assertion in the
      // guard and silently take the capture away from ops.
      const m = body.match(/class="deploy-detail" data-cap="(\d+)"/);
      assert.ok(m, "the cruel caption's data-cap carries a NUMBER (the caption's length), not a second copy of the caption");
      assert.equal(
        Number(m[1]), SCEN_DEPLOY_DETAIL_STORE_CAP,
        "data-cap reports the caption's full stored length — the render bound is on DISPLAY only",
      );
    },
  },

  // RETRY: renders the rollback skeleton; the transient-500 → "Try again"
  // (retry recovery) morph is click-driven (covered by the vm unit tests).
  "promote-retry": {
    what: "the deploy rows; the transient failure → Try again is click-driven",
    container: "site-body",
    includes: ['data-kind="redeploy"', ">Roll back to this<"],
  },
  // MIGRATED: the promoted build went live — the Current chip MOVED to it; the
  // old current is now a prior live deploy offering "Roll back to this" (two
  // rollbackable live rows now, no Building row).
  "promote-migrated": {
    what: "the Current chip has migrated to the now-live deploy",
    container: "site-body",
    includes: ["dep-current", ">Redeploy<", ">Roll back to this<"],
    excludes: ["dep-pill dep-building"],
  },
  // cch-w25-s3: the deploy rail, FAILED. The first scenario in this harness
  // whose console carries a rail STAGE entry — before it,
  // `deployRailLedgerFromConsole` dropped every console line (no `stage` key)
  // and the rail never mounted anywhere. The footer must carry the builder's
  // raw string VERBATIM, so the expectation quotes the fixture's own derived
  // detail rather than a transcription of it.
  //
  // WHY A `check` AND NOT AN `includes` LIST. The rail is mounted INTO
  // `#deploy-rail-slot` by `mountDeployRail`, which reaches through
  // `scope.querySelector` — a real-DOM seam this vm registry does not model, so
  // the slot renders as an empty div here however correct the fixture is. The
  // browser half of this proof is overflow-guard's W25 leg, which asserts the
  // box in a real Chrome. What THIS half owns is the fold: the ledger keeps a
  // stage entry, the rows carry the failure, and the markup puts the raw string
  // in `.deploy-rail-fail` — every one of them off the committed fixture.
  "site-deploy-rail-failed": {
    what: "the deploy rail's FAILED fold — the ledger keeps the stage entry and the footer carries the builder's raw error",
    check(reg, hooks) {
      const scen = SCENARIOS["site-deploy-rail-failed"];
      const deployments = scen.data.deploymentsBySite[scen.deepLink.split("/")[1]];
      // The rail tracks the deployment still IN FLIGHT — the transient window
      // this footer lives in. A fixture whose row went terminal would render no
      // rail at all, so this is asserted rather than assumed.
      const dep = hooks.railDeployment(deployments);
      assert.ok(dep, "the fixture must carry an ACTIVE deployment or the rail never mounts");
      // The precondition this whole slice rests on: before this scenario, no
      // console entry in this harness carried a `stage`, so the ledger was
      // always empty and the rail never rendered anywhere.
      const ledger = hooks.deployRailLedgerFromConsole(dep.console);
      assert.equal(Object.keys(ledger).length, 2, "PLAN + BUILD must survive the fold");
      assert.equal(ledger.BUILD.status, "failed");
      assert.equal(ledger.BUILD.detail, SCEN_RAIL_CRUEL_DETAIL,
        "the footer must carry the builder's string VERBATIM — nothing humanises it");
      const rows = hooks.deployRailRows(ledger);
      const failed = rows.filter((r) => r.role === "failed")[0];
      assert.ok(failed, "BUILD must fold to a failed row");
      const html = hooks.deployRailHtml(rows, { deploymentId: dep.id, failureDetail: failed.caption });
      assert.ok(html.includes("deploy-rail-status--failed"), "the pill must read the failed tone");
      assert.ok(html.includes(">Deploy failed at Build<"), "the pill must name the stage that broke");
      assert.ok(html.includes('<div class="deploy-rail-fail" role="alert">'), "the failure footer must render");
      // The raw string, escaped, inside that footer — this is the text the
      // CSS rule under measurement has to wrap.
      const foot = html.split('<div class="deploy-rail-fail" role="alert">')[1].split("</div>")[0];
      assert.ok(foot.includes("Cannot find module"), "the footer holds the builder's own error line");
      assert.ok(foot.length >= 200, "the cruel detail must reach the footer at full length, not truncated by the SPA");
      // The KIND control's own fold, from the same fixture's other site.
      const kind = hooks.railDeployment(scen.data.deploymentsBySite[SCENARIOS["site-deploy-rail-failed"].data.sites[1].id]);
      assert.ok(kind, "the control site must carry an active deployment too");
      const kindRows = hooks.deployRailRows(hooks.deployRailLedgerFromConsole(kind.console));
      const kindFail = kindRows.filter((r) => r.role === "failed")[0];
      assert.ok(kindFail && kindFail.step === "HEALTH", "the control must fail at HEALTH, not BUILD");
      assert.ok(/\s/.test(kindFail.caption) && kindFail.caption.length < SCEN_RAIL_CRUEL_DETAIL.length,
        "the control must be the ORDINARY word-broken string — shorter, and breakable at spaces");
    },
  },
  // cch-w29-bl: the deploy rail, LIVE — the fold behind `.deploy-rail-live`,
  // the footer `deployRailHtml`'s OTHER branch emits and which no scenario in
  // this harness had ever produced. Same seam limit as the FAILED twin above:
  // the rail mounts through `scope.querySelector` into `#deploy-rail-slot`, a
  // real-DOM seam this vm registry does not model, so the browser half of this
  // proof is overflow-guard's W29-deploy-rail-live-url-wrap leg. What THIS half
  // owns is that the fixture can reach the live branch AT ALL — an active row,
  // six done stages, tone "live" — and that the URL in the footer is the SAME
  // string the detail head's already-paid `.fleet-url .site-open` carries, from
  // `siteLiveUrl`, so the browser leg's in-page control is a fact about the
  // fixture rather than a hope.
  "site-deploy-rail-live": {
    what: "the deploy rail's LIVE fold — every stage done, and the footer carries the copyable site URL",
    check(reg, hooks) {
      const scen = SCENARIOS["site-deploy-rail-live"];
      const site = scen.data.sites[0];
      const bp = scen.data.barkparks[0];
      // The rail tracks the deployment still IN FLIGHT. A fixture whose row went
      // terminal renders no rail at all, so this is asserted, never assumed.
      const dep = hooks.railDeployment(scen.data.deployments);
      assert.ok(dep, "the fixture must carry an ACTIVE deployment or the rail never mounts");
      const ledger = hooks.deployRailLedgerFromConsole(dep.console);
      assert.equal(Object.keys(ledger).length, hooks.deployRailStages.length,
        "every rail stage must survive the fold — a short ledger cannot reach the live branch");
      const rows = hooks.deployRailRows(ledger);
      assert.ok(rows.length > 0 && rows.every((r) => r.role === "ok"),
        "all six rows must fold to ok — that is the ONLY input that makes deployRailStatus say live");
      assert.equal(hooks.deployRailStatus(rows).tone, "live");
      // THE URL IS DERIVED FROM THE FIXTURE, exactly as mountDeployRail derives
      // it — a transcribed string here would keep passing after the fixture
      // stopped producing one.
      const url = hooks.siteLiveUrl(site, bp);
      assert.ok(url && url.startsWith("https://"), "siteLiveUrl must yield an absolute live URL for this fixture");
      const html = hooks.deployRailHtml(rows, { deploymentId: dep.id, url });
      assert.ok(html.includes("deploy-rail-status--live"), "the pill must read the live tone");
      assert.ok(html.includes('<div class="deploy-rail-live">'), "the LIVE footer must render — this is the branch no fixture reached before");
      const foot = html.split('<div class="deploy-rail-live">')[1].split("</div>")[0];
      assert.ok(foot.includes('class="site-open"'), "the footer's URL is a `.site-open` anchor — the class the base nowrap rule dresses");
      assert.ok(foot.includes(">" + url + "&nbsp;"), "the WHOLE url is the anchor's text, not a label");
      assert.ok(foot.includes('data-copy="' + url + '"'), "the copy button carries the same url");
      // THE IN-PAGE CONTROL IS A PROPERTY OF THE FIXTURE, not of the browser
      // run: the detail head renders `.fleet-url .site-open` only when
      // siteHasEverDeployed, and the browser leg compares the two anchors.
      assert.ok(site.current_deployment_id,
        "the fixture's site must carry current_deployment_id or the head renders no `.fleet-url .site-open`, and the browser leg loses its paid-twin control");
      // The unbreakable run the nowrap pinned: no space anywhere in the URL.
      assert.ok(!/\s/.test(url) && url.length > 40,
        "the live URL must be one long unbreakable run — a URL with a space in it could wrap without any remedy at all");
    },
  },
  // Invitation accept: each committed terminal renders its designed card with
  // exactly one [data-invite-act] action (esc() turns ' into &#39; in copy).
  "invite-joined": {
    what: "the Join confirm for a live foreign-team invitation",
    container: "view-invite",
    includes: ['data-invite-act="join"', "Northwind Trading", "invite-skip", "Not now"],
  },
  "invite-expired": {
    what: "the calm expired dead-end with one next action, still WARN (recoverable)",
    container: "view-invite",
    // The other half of the ruling: expired is "ask for a fresh one", not a
    // dead link, so it must NOT drift into the danger mark.
    includes: ["has expired", 'data-invite-act="overview"', "invite-ico--warn"],
    excludes: ['data-invite-act="join"', "invite-ico--danger"],
  },
  "invite-already-member": {
    what: "the already-a-member card with one next action",
    container: "view-invite",
    includes: ["already a member", 'data-invite-act="overview"'],
    excludes: ['data-invite-act="join"'],
  },
  "invite-invalid": {
    what: "the revoked/used dead-end with one next action, wearing the DANGER mark",
    container: "view-invite",
    // gr-blk-invite-ico-danger-variant: a dead link and a retryable error used
    // to be the same "!" glyph. This is the mounted proof the danger variant
    // reaches the real render path, not just the pure helper.
    includes: ["isn&#39;t valid any more", 'data-invite-act="overview"', "invite-ico--danger"],
    excludes: ['data-invite-act="join"', "invite-ico--warn"],
  },
  // C8: the tab strip registers Timeline and marks it active on the deep link.
  // (The feed itself mounts through element-level querySelector, which this
  // shim keeps inert — the feed's rendering is pinned in __app.test.mjs.)
  timeline: {
    what: "the instance workspace routes the Timeline tab",
    container: "instance-body",
    includes: ["inst-tabs", '/timeline" aria-current="page"', 'id="instance-tabpanel"', ">Timeline<"],
  },
  "timeline-events-only": {
    what: "the Timeline tab routes for a non-admin too (403 degradation is harness-pinned)",
    container: "instance-body",
    includes: ["inst-tabs", '/timeline" aria-current="page"'],
  },
  // C10/OC7 + W4/OC19: the Usage sub-tab routes on its deep link AND fills its
  // meter wall — including the Wave-4 14-day sparklines. mountUsageTab re-acquires
  // the tabpanel by id (the same idiom refreshInstanceTimeline uses), so its
  // parallel /usage + /usage/history fetches render into the OBSERVABLE
  // #instance-tabpanel here. The tab strip lands in #instance-body; the sparkline
  // markup lands in #instance-tabpanel (both proved below).
  "usage-quota": {
    what: "the Usage tab routes and fills the meter wall with 14-day sparklines",
    check(reg) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      for (const needle of ["inst-tabs", '/usage" aria-current="page"', 'id="instance-tabpanel"', ">Usage<"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel meter wall rendered empty");
      // Progressive fill landed: a meter with numeric history carries a sparkline.
      assert.ok(panel.includes('class="usage-spark"'), "meter wall must carry a sparkline container");
      assert.ok(panel.includes("<polyline"), "a real history run draws a polyline");
      // The grid is still fully present (every meter label renders, sparks or not).
      assert.ok(panel.includes("Documents"), "the documents meter renders in the wall");
    },
  },
  // w6 (OC25): the instance Webhooks sub-tab. mountWebhooksTab re-acquires the
  // tabpanel by id (the mountUsageTab idiom), so the shell + the endpoint list
  // render into the OBSERVABLE #instance-tabpanel. The tab strip lands in
  // #instance-body; the list (each row carrying the new Edit action) lands in
  // #instance-tabpanel. The edit/create MODAL flows are click-driven (inert here)
  // and DOM-tested in __app.test.mjs.
  "webhooks-panel": {
    what: "the Webhooks tab fills the endpoint list — and the SECOND card's Delete is clicked for real: the typed gate, exactly one DELETE for wh-stale, the server list 2 → 1, and THAT card gone from the DOM",
    async check(reg, hooks, ctx) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      for (const needle of ["inst-tabs", '/webhooks" aria-current="page"', 'id="instance-tabpanel"', ">Webhooks<"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel webhook list rendered empty");
      assert.ok(panel.includes('class="wh-card"'), "the endpoint list must render webhook cards");
      assert.ok(panel.includes("data-wh-edit"), "each card must carry the w6 Edit action");
      assert.ok(panel.includes("Prod indexer"), "the fixture webhook name renders");
      assert.ok(panel.includes("data-wh-delete"), "the full action bar renders (delete present)");

      // ── cch-bl-webhook-delete-oracle · THE WEBHOOK DELETE, CLICKED ─────────
      // The twelfth destroy verb, and the one cch-w10 measured and DEFERRED.
      // Two blockers were named; both are closed here, and neither by waving.
      //
      // BLOCKER 1 — the card is a DIV and PARSED_TAGS is `button|a`, under a
      // committed prohibition against widening it. NOT widened: `findWhCard`
      // (grep it in app.js) now resolves through CARD GROUPS — a class
      // allowlist over container spans, documented at `GROUPED_CLASSES` in this
      // file. `.wh-list` and `.fleet-body` are NOT on that list, so
      // loadWebhooks' and mountUsageTab's `|| root` fallbacks still take the
      // fallback and the detached-stub hazard is structurally unreachable.
      //
      // BLOCKER 2 — THE WRONG-TARGET TRAP, and it is disproven by EXECUTION,
      // not avoided. The fixture carries TWO endpoints on purpose. The remedy
      // cch-w10 sketched (an `|| listBox` fallback inside findWhCard) would
      // hand BOTH cards the SAME listBox, so `card.querySelector(
      // "[data-wh-delete]")` would answer the FIRST button for both and a
      // green oracle would be asserting the wrong webhook was deleted. This leg
      // clicks the SECOND card and pins the second endpoint's id at every step:
      // the sheet's copy, the wire path, the survivor, and the row that leaves.
      const panelEl = reg.get("instance-tabpanel");
      const cards = panelEl.querySelectorAll(".wh-card");
      assert.equal(cards.length, 2,
        "this leg's whole point is TWO cards (the wrong-target trap needs a second one); got " + cards.length +
        " — 0 means the card-group parse regressed and everything below would be vacuous");
      assert.deepEqual(cards.map((c) => c.getAttribute("data-wh")), ["wh-prod", "wh-stale"],
        "the cards must render in fixture order, so 'the SECOND card' names a known endpoint");
      const victim = cards[1];
      const survivor = cards[0];
      const del = victim.querySelector("[data-wh-delete]");
      assert.ok(del, "the second card carries no Delete — wireWebhookCard's `on()` had nothing to bind");
      assert.notEqual(del, survivor.querySelector("[data-wh-delete]"),
        "BOTH cards answered the SAME Delete button — this is the wrong-target trap itself, and an oracle " +
        "built on it would happily assert that deleting card 2 deleted card 1");

      const whPath = "/v1/barkparks/" + SCENARIOS["webhooks-panel"].data.barkparks[0].id + "/api/webhooks";
      assert.equal(ctx.countCalls("DELETE", whPath + "/wh-stale"), 0, "nothing was deleted before the click");
      assert.equal(del.click(), 1,
        "the second card's Delete dispatched no click handler. Read this as the WRONG-TARGET trap first: " +
        "if findWhCard resolves BOTH cards to the same node (the `|| listBox` fallback cch-w10 sketched, or a " +
        "card-group span that swallowed its sibling), every handler lands on card ONE and card TWO's button is " +
        "left dead. Mutation-verified: `return cards[i]` -> `return cards[0]` in findWhCard reds exactly here.");
      await ctx.settle();

      // THE SHEET IS THE SECOND ENDPOINT'S. Both fixture rows carry distinct
      // names and urls, so this copy cannot be satisfied by the wrong card.
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes("legacy.acme.com/sync") && sheet.includes("Legacy sync"),
        "the confirm sheet named the WRONG endpoint — it must describe wh-stale, the card that was clicked; got: " +
        sheet.slice(0, 300));
      assert.ok(!sheet.includes("hooks.acme.com/reindex"),
        "…and it must not describe wh-prod, which nobody touched");
      assert.equal(ctx.countCalls("DELETE", whPath + "/wh-stale"), 0,
        "the card click fired the DELETE before the operator confirmed — the typed gate is gone");

      // THE TYPED GATE, read where the shim can read it honestly. The button
      // ships `disabled` in the sheet's MARKUP, and this shim does not seed a
      // registry node's boot state from app-RENDERED markup (the same rule
      // HIDDEN_IDS states for `hidden`) — so the disarmed state is read off the
      // parsed markup node, and the ARM is read off the node app.js actually
      // writes. Both are real; neither is the other's stand-in.
      assert.equal(reg.get("modal-body").querySelector("#wh-del-go").disabled, true,
        "the sheet must ship its Delete disabled — an armed-on-open destroy sheet has no gate at all");
      const go = reg.get("wh-del-go");
      const input = reg.get("wh-del-confirm");
      input.value = "Prod indexer";
      input.dispatchEvent({ type: "input" });
      assert.equal(go.disabled, true, "the OTHER endpoint's name armed this sheet — the echo is matching the wrong row");
      input.value = "Legacy sync";
      input.dispatchEvent({ type: "input" });
      assert.equal(go.disabled, false, "typing the endpoint's own name did not arm the sheet");

      assert.equal(go.click(), 1, "the armed Delete dispatched no click handler");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", whPath + "/wh-stale"), 1,
        "exactly one DELETE for the SECOND endpoint must reach the wire; got " +
        ctx.countCalls("DELETE", whPath + "/wh-stale"));
      assert.equal(ctx.countCalls("DELETE", whPath + "/wh-prod"), 0,
        "THE WRONG-TARGET TRAP FIRED: deleting the second card put the FIRST endpoint on the wire");

      // THE SHRINK, off the SERVER's own list — the assertion the old stateless
      // `{data:{webhooks: d.webhooks}}` could not pass.
      assert.equal(ctx.state.webhooks.length, 1,
        "the server list must shrink by exactly one (2 → 1); got " + ctx.state.webhooks.length);
      assert.deepEqual(ctx.state.webhooks.map((w) => w.id), ["wh-prod"], "and the SURVIVOR is the untouched endpoint");
      const served = route("webhooks-panel", "GET", whPath + "?dataset=production", ctx.state);
      assert.deepEqual(served.body.data.webhooks.map((w) => w.id), ["wh-prod"],
        "a fresh list READ must agree — the shrink is served, not just spliced into a bag nobody reads");

      // AND THE ROW LEAVES THE DOM. deleteWebhook does not refetch: its success
      // arm removes the card node itself, so this is the ONLY on-screen
      // consequence there is (its toast is a client-side constant, which is
      // exactly why this row was a WIRE + STATE job and never a text one).
      const after = panelEl.innerHTML || "";
      assert.ok(!after.includes('data-wh="wh-stale"'),
        "the deleted card is still in the list — findWhCard/removeChild never reached it");
      assert.ok(after.includes('data-wh="wh-prod"'),
        "the SURVIVING card left the list too — the removal took the wrong row, or the whole list");
      assert.deepEqual(panelEl.querySelectorAll(".wh-card").map((c) => c.getAttribute("data-wh")), ["wh-prod"],
        "the live card list must be the survivor alone");
      const whToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(whToast.includes("Webhook deleted") && whToast.includes("legacy.acme.com/sync"),
        "the delete must report itself, naming the endpoint it removed; got: " + whToast.slice(0, 300));
    },
  },
  // gr-p2 HOME TRIAGE (C-01): the v4 Overview folds the wave-3 fleet-usage strip
  // into the instances grid + the page-header slots meter. The card stat pairs
  // (DOCS/DISK/CPU/RAM) read the SAME /v1/usage/summary as the strip did (no
  // per-instance fan-out); a box at its RAM ceiling tints that stat amber. The
  // header slots meter reads the REAL team instance quota (10) — never hardcoded.
  "fleet-usage": {
    what: "the v4 instances grid paints real per-instance stats + the header slots meter reads the real quota",
    check(reg) {
      // Each Overview mount is its own registry element in this fake DOM: the
      // grid paints #overview-instances, the slots meter #overview-slots.
      const grid = (reg.get("overview-instances") || {}).innerHTML || "";
      assert.ok(grid.includes('class="instances-grid"'), "the v4 instances grid renders");
      assert.ok(grid.includes("instance-card--"), "cards carry their status accent");
      assert.ok(grid.includes(">CPU</span>") && grid.includes(">RAM</span>"), "CPU/RAM stat pairs render");
      assert.ok(grid.includes("100%"), "the hot box's RAM value (100%) renders from the real sample");
      assert.ok(grid.includes("is-warn"), "an over-ceiling stat tints amber");
      assert.ok(grid.includes("Open Studio"), "live cards carry the Open Studio link");
      // The header slots meter reads count / REAL quota — the fixture's team
      // ceiling is 10 with 3 boxes in the fleet.
      const slots = (reg.get("overview-slots") || {}).innerHTML || "";
      assert.ok(slots.includes("3 / 10 slots"), "slots meter shows count / real quota, never hardcoded");
    },
  },
  // C8: the golden-path verify card renders from the events feed on Overview.
  "verify-pass": {
    what: "verify chips — three green probes + the quiet re-check",
    container: "instance-verify",
    includes: ["vf-card", "vf-chip vf-chip--pass", "All checks passed", "Check now"],
    excludes: ["vf-chip--fail", "Run first check"],
  },
  "verify-fail": {
    what: "verify chips — the failing Studio probe rendered honestly",
    container: "instance-verify",
    includes: ["vf-chip vf-chip--fail", "502", "1 of 3 checks failing"],
    excludes: ["All checks passed"],
  },
  "verify-never": {
    what: "verify chips — never run, the card invites the first check",
    container: "instance-verify",
    includes: ["Run first check", "vf-chip vf-chip--unknown", "Never checked"],
    excludes: ["vf-chip--pass", "vf-chip--fail"],
  },
  // bp-login-ux W3 (decision 40): the /activate device-login approve page's
  // PRE-CLICK skeletons. Each asserts DISTINCT per-state markup (a `device`
  // fixture that went missing would make inspect fall to the /v1/ catch-all's
  // 200 {}, folding gone/rate_limited into a degenerate "confirm" — the excludes
  // catch exactly that false-confirm). Click-driven approved/denied morphs are
  // DOM-tested in __app.test.mjs (smoke's click() is inert).
  "activate-entry": {
    what: "the manual code-entry form (authed, no prefill)",
    container: "activate-body",
    includes: ['id="activate-form"', 'id="activate-code"', "Approve a device sign-in", ">Continue<"],
    excludes: ["Approve this sign-in?", "Too many attempts", "expired or was already used"],
  },
  "activate-confirm": {
    what: "the confirm screen naming the requesting machine + Approve/Deny, with the (always-172.18.0.1) IP suppressed",
    container: "activate-body",
    includes: ["Approve this sign-in?", "bp on nimbus.local",
      'id="activate-approve"', 'id="activate-deny"'],
    // GR81: the fixture STILL sends an ip_address (the wire shape is unchanged);
    // the screen refuses to draw it, because in prod that field is the Docker
    // bridge gateway for every device and so cannot answer "is this machine
    // mine?". Revert with gr-bl-peer-ip-container.
    excludes: ["Too many attempts", "expired or was already used", "Unknown device",
      "203.0.113.7", "IP address"],
  },
  "activate-gone": {
    what: "the expired/used dead-end offering a fresh-code retry",
    container: "activate-body",
    includes: ["This code has expired or was already used", ">Enter a different code<"],
    excludes: ["Approve this sign-in?", "Too many attempts"],
  },
  "activate-rate-limited": {
    what: "the honest 429 with a PAUSED (disabled) retry countdown",
    container: "activate-body",
    // The countdown ticker is stubbed inert (smoke's setInterval never fires), so
    // this pins the INITIAL disabled skeleton only, never a tick.
    includes: ["Too many attempts", "Try again in 15s", "disabled"],
    excludes: ["Approve this sign-in?", "This code has expired"],
  },
  "activate-logged-out": {
    what: "logged out — the sign-in card banners the parked device code (park → resume)",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must be hidden");
      const banner = (reg.get("auth-activate") || {}).innerHTML || "";
      assert.ok(banner.includes("Approve a device sign-in."), "banner must announce the device approval");
      assert.ok(banner.includes("ABCD-2345"), "banner must show the parked code");
    },
  },

  // ── gr-w3 v4 shell: morph / operator / generated identity picker ────────────
  "shell-root": {
    what: "v4 shell — the ROOT nav layer shows, both morph layers hidden, operator hidden (no flag)",
    check(reg) {
      assert.equal(reg.get("app-shell").hidden, false, "app shell must be visible");
      assert.equal(reg.get("nav-layer-root").hidden, false, "root nav layer must show at a workspace route");
      assert.equal(reg.get("nav-layer-instance").hidden, true, "instance layer must be hidden at root");
      assert.equal(reg.get("nav-layer-site").hidden, true, "site layer must be hidden at root");
      assert.equal(reg.get("nav-operator").hidden, true, "operator entry is fail-closed without the flag");
    },
  },
  "shell-instance": {
    what: "v4 shell — the INSTANCE layer morphs in with its section links; root hidden",
    check(reg) {
      assert.equal(reg.get("nav-layer-instance").hidden, false, "instance layer must show under #instance/<id>");
      assert.equal(reg.get("nav-layer-root").hidden, true, "root layer must collapse when drilled in");
      const sections = reg.get("nav-instance-sections").innerHTML || "";
      assert.ok(sections.includes("/timeline"), "instance sections must link the Timeline sub-tab");
      assert.ok(sections.includes(">Timeline<"), "instance sections must label Timeline");
      assert.ok(sections.includes(">Webhooks<"), "instance sections must label Webhooks");
    },
  },
  "shell-site": {
    what: "v4 shell — the SITE layer morphs in; root hidden",
    check(reg) {
      assert.equal(reg.get("nav-layer-site").hidden, false, "site layer must show under #site/<id>");
      assert.equal(reg.get("nav-layer-root").hidden, true, "root layer must collapse for a site");
      assert.equal(reg.get("nav-layer-instance").hidden, true, "instance layer stays hidden for a site");
    },
  },
  "operator-visible": {
    what: "v4 shell — platform_operator:true reveals the Operator entry (GR9 fail-open only on true)",
    check(reg) {
      assert.equal(reg.get("nav-operator").hidden, false, "operator entry must show when platform_operator is true");
    },
  },
  "identity-iris": {
    what: "v4 shell — the identity picker offers all 5 skins incl charple + iris; iris is the restored value (GR12)",
    check(reg) {
      const opts = reg.get("bp-theme-picker").innerHTML || "";
      for (const id of ["evergreen", "charple", "ember", "fjord", "iris"]) {
        assert.ok(opts.includes('value="' + id + '"'), "picker must offer the " + id + " identity");
      }
      assert.equal(reg.get("bp-theme-picker").value, "iris", "the restored bp_theme=iris is the active option");
    },
  },

  // ── gr-p2-front-door: the logged-out front door (B-01..B-03) ────────────────
  "loggedout-signup": {
    what: "#signup deep-links the sign-in card straight onto the Create-account tab",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must be hidden");
      assert.equal(reg.get("login-card").hidden, false, "login card must be visible");
      assert.equal(reg.get("field-team").hidden, false, "signup shows the team-name field");
      assert.equal(reg.get("field-remember").hidden, true, "signup hides remember-me");
      assert.equal(reg.get("auth-submit").textContent, "Create account", "the CTA reads Create account");
      assert.ok(reg.get("auth-foot").innerHTML.includes("Already have an account?"),
        "the foot offers the switch back to log in");
    },
  },
  "loggedout-reset": {
    what: "the emailed reset link swaps the login form for the set-new-password card (absorbs gr-backlog-reset-route-smoke)",
    check(reg) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "app shell must stay hidden");
      assert.equal(reg.get("reset-card").hidden, false, "reset card must be visible");
      assert.equal(reg.get("login-card").hidden, true, "login card must hand off to the reset card");
      assert.equal(reg.get("twofa-card").hidden, true, "no stale 2FA card on a reset landing");
    },
  },
  "loggedout-twofactor": {
    what: "the shared 2FA challenge card mounts into #twofa-card in the AUTH (never theater) vocabulary",
    check(reg, hooks) {
      assert.equal(reg.get("auth-screen").hidden, false, "auth screen must be visible");
      assert.ok(hooks && typeof hooks.mountTwoFactorCard === "function",
        "the 2FA mount seam must be exported through __bpTestHook");
      // The card only ever mounts behind a login submit (inert in this shim) —
      // drive the mount seam directly into the REAL #twofa-card slot, exactly
      // as showTwoFactorLoginCard does, and pin the composed markup.
      const root = reg.get("twofa-card");
      hooks.mountTwoFactorCard(root, { challengeToken: "demo-challenge" });
      const html = root.innerHTML || "";
      for (const needle of ['class="auth-title"', 'class="auth-desc"', 'id="tfa-form"',
        'id="tfa-code"', "Two-factor authentication", 'autocomplete="one-time-code"']) {
        assert.ok(html.includes(needle), "#twofa-card missing " + JSON.stringify(needle));
      }
      for (const needle of ["new-title", "new-desc"]) {
        assert.ok(!html.includes(needle),
          "#twofa-card must not import theater vocabulary " + JSON.stringify(needle));
      }
    },
  },

  // ── gr-p2 plan & dunning (C-03/C-04): trial CTA, GR17 dunning, portal return ─
  "billing-trial": {
    what: "the trial billing state — countdown chip, the warranted CTA verbatim, open plan grid, trial topbar chip",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // The ratified CTA (task-2ed0ea068f37345d), VERBATIM — never the
      // prototype's superseded draft. cch-w49-s1 retired the second sentence
      // ("No card needed."): the ratification warranted teardown + the T-3/T-1
      // reminders, never card collection, and checkout does collect a card.
      assert.ok(box.includes("Pick a plan below to keep it."),
        "the warranted trial CTA must render verbatim");
      assert.ok(!box.includes("No card needed"),
        "the trial card must not promise a card-free path into a mode=subscription checkout");
      assert.ok(box.includes('class="trial-chip"'), "the countdown chip must render");
      assert.ok(box.includes("14 days left"), "the chip must carry the server's days-remaining");
      // Trial expiry is a real teardown — the dunning copy must NOT leak into
      // trial copy. cch-w54-s5 retired "suspended — not deleted" from both
      // dunning banners (the suspension it promised has no executor), so this
      // inverse pin is RE-POINTED at the sentence that replaced it. Left on the
      // dead phrase it would have gone vacuously green.
      assert.ok(!box.includes("Isolation, not shutdown"), "trial copy must never borrow the dunning isolation sentence");
      assert.ok(!box.includes("suspended — not deleted"), "nor the retired dunning suspend promise, if it ever returns");
      // The plan grid opens right below the CTA ("below" must be true) and
      // still names all three tiers with their actions. It states no ceiling
      // and no price — this actor is on plan "trial", which the catalog has no
      // card for, and nothing on this screen ever asks the server for a quota.
      // The numeral absence itself is guarded corpus-wide by
      // assertBillingStatesNoNumeralItCannotSupport().
      assert.equal(reg.get("billing-tiers").hidden, false, "the plan grid must be open under the CTA");
      const grid = reg.get("billing-tiers").innerHTML || "";
      for (const q of ["Free", "Supporter", "Support++"]) {
        assert.ok(grid.includes(">" + q + "<"), "tier cards must name the tier " + JSON.stringify(q));
      }
      assert.ok(!grid.includes("Unlimited managed instances"), "the unlimited fiction must be gone");
      // GR20: the topbar chip reads trial (XOR — never the past-due skin).
      const chip = reg.get("billing-chip");
      assert.equal(chip.textContent, "Trial · 14 days left", "topbar chip must count the trial down");
      assert.ok(chip.className.includes("billing-chip--trial"), "topbar chip must ride the trial skin");
      assert.ok(!chip.className.includes("past_due"), "trial XOR past-due — never both");
      assert.equal(chip.href, "#billing", "the chip must route to #billing");
      // G-01: a trial has no paid Stripe plan → no portal to manage, nothing to
      // cancel; both owner action sections stay retired (their action is to
      // subscribe, in the plan grid above).
      assert.equal(reg.get("billing-manage-section").hidden, true, "a trial mounts no Manage-billing section");
      assert.equal(reg.get("billing-cancel-section").hidden, true, "a trial mounts no Cancel section");
    },
  },
  "billing-past-due": {
    what: "past due — the GR17 banner verbatim with data-driven dates, portal CTA, no denial copy, red topbar chip",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // cch-w54-s5: DATELESS. Both date slots came off current_period_end, which
      // mark_past_due/2 re-anchors to now+3d on every webhook delivery, and the
      // suspension they pointed at has no executor on any production path. The
      // banner now states the consequence entitled?/1 actually gates.
      assert.ok(box.includes("Your card was declined. Nothing stops and nothing is deleted"),
        "the banner must open with the honest isolation lead");
      assert.ok(box.includes("this team can't launch a new instance until payment succeeds"),
        "the banner must name the go-live gate, the one real consequence of a lapsed grace");
      assert.ok(box.includes("Isolation, not shutdown — and it lifts the moment payment succeeds."),
        "the isolation sentence must render verbatim, with the backed restore tail");
      // The two negatives are scoped to the BANNER BODY by name — the card below
      // it legitimately dates "since {started_at}", and suspendedCardBannerHtml
      // (elsewhere on the console) legitimately says "Suspended".
      const dunningBody = (box.match(/<p class="dunning-body">([\s\S]*?)<\/p>/) || [])[1] || "";
      assert.ok(dunningBody.length > 0, "the dunning body must render");
      assert.ok(!/suspend/i.test(dunningBody), "the past-due banner must promise no suspension");
      assert.ok(!/\b(January|February|March|April|May|June|July|August|September|October|November|December)\b|\d{1,2}\/\d{1,2}/.test(dunningBody),
        "and must name no calendar day");
      // The member-visible line beside it is dateless too (one edit inside
      // billingPeriodLine moves the owner and non-owner twins together).
      assert.ok(box.includes("Grace period running — new instance launches stop when it ends"),
        "the plan-meta period line states the lapse without a sliding deadline");
      assert.ok(!box.includes("Grace period ends "), "the retracted deadline must not survive anywhere on the screen");
      assert.ok(box.includes(">Past due<"), "the banner must carry the Past due title");
      assert.ok(box.includes(">Supporter<"), "the banner must chip the plan name");
      assert.ok(box.includes(">Update payment method<"), "the GR17 portal CTA must render verbatim");
      // G-01 anatomy: Manage billing moved OUT of the state card into its own
      // .set-section action row (the state card no longer buries a button).
      assert.ok(!box.includes(">Manage billing<"), "the state card must NOT bury the portal button");
      const manage = reg.get("billing-manage").innerHTML || "";
      assert.ok(manage.includes(">Manage billing<"), "the Manage-billing action rides its own .set-section");
      assert.ok(/download invoices/i.test(manage), "the invoice-less portal copy lives in the action section");
      assert.equal(reg.get("billing-manage-section").hidden, false, "the Manage-billing section is shown for a paid plan");
      // Owner + paid + not-yet-cancelling → the Cancel section offers the danger action.
      assert.equal(reg.get("billing-cancel-section").hidden, false, "an owner may cancel a paid plan");
      assert.ok((reg.get("billing-cancel").innerHTML || "").includes("Cancel plan"), "the Cancel-plan danger action renders");
      // The dead promises stay dead.
      assert.ok(!box.includes("retry twice more"), "the retry-count fiction must be gone");
      assert.ok(!/contact support/i.test(box), "the support-mail denial copy must be gone");
      // GR20: the topbar chip flips to the past-due alarm (XOR trial).
      const chip = reg.get("billing-chip");
      assert.equal(chip.textContent, "Payment failed · fix billing", "topbar chip must alarm on past-due");
      assert.ok(chip.className.includes("billing-chip--past_due"), "topbar chip must ride the past-due skin");
      assert.ok(!chip.className.includes("--trial"), "past-due XOR trial — never both");
      // The sidebar pill keeps the PAID plan (the activePlan past_due fix).
      assert.equal(reg.get("ws-plan").textContent, "Supporter", "a past_due team keeps its paid plan in the sidebar pill");
    },
  },
  "billing-portal-return": {
    what: "back from the portal — billing renders the current plan, portal-managed copy, no denial copy",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      assert.ok(box.includes(">Supporter<"), "the current plan card must render after the round-trip");
      // cch-w49-s1: the card states the plan and its features, never a ceiling
      // this screen never fetched (Usage.instance_quota is not read here at all).
      assert.ok(box.includes("Automated provisioning &amp; updates"), "the features must render");
      // G-01 anatomy: the portal CTA rides the Manage-billing .set-section now.
      assert.ok((reg.get("billing-manage").innerHTML || "").includes(">Manage billing<"), "the portal CTA must render in its section");
      assert.equal(reg.get("billing-manage-section").hidden, false, "the Manage-billing section shows for the active plan");
      assert.ok(!/contact support/i.test(box), "the support-mail denial copy must be gone");
      // A healthy active sub shows NO topbar billing chip (trial XOR past-due only).
      assert.equal(reg.get("billing-chip").hidden, true, "an active paid plan mounts no topbar billing chip");
    },
  },

  // ── gr-p2 launch theater (GR18): /new journey + provisioning theater ────────
  "new-launch": {
    what: "/new signed-in — the template card + the one-field Launch step",
    check(reg) {
      assert.equal(reg.get("new-screen").hidden, false, "the /new screen must be visible");
      assert.equal(reg.get("app-shell").hidden, true, "the app shell stays hidden on /new");
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.length > 0, "#new-body rendered empty");
      for (const needle of ['class="new-title">Astro Blog', "new-gets", 'id="new-launch-btn"', ">Launch<", "no card required"]) {
        assert.ok(body.includes(needle), "#new-body missing " + JSON.stringify(needle));
      }
    },
  },
  "theater-midflight": {
    what: "the /new theater mid-flight — conditional 5-row rail, the price line, the open console",
    check(reg) {
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.includes("new-progress"), "the progress theater must be mounted");
      assert.ok(body.includes("Launching Hugin"), "the head names the instance (v4 copy)");
      // GR18(1): the conditional rail — the warm path reports no freshen/content,
      // so EXACTLY the 5 planned rows render (never the render's 7 static rows).
      assert.equal(countMatches(body, '<li class="new-step '), 5, "typical run renders 5 rail rows");
      assert.ok(!body.includes('data-step="freshen"'), "unreported freshen stays hidden");
      assert.ok(!body.includes('data-step="content"'), "unreported content stays hidden");
      assert.ok(body.includes('class="new-step active" data-step="configure"'), "configure is the live step");
      // GR18(3): the price-before-charge line — the REAL catalog row via
      // formatMonthlyPrice, never plan-grid digits.
      assert.ok(body.includes("data-price-line"), "the price line renders above the rail");
      assert.ok(body.includes("€4.9/mo"), "the price is the catalog row (formatMonthlyPrice)");
      assert.ok(body.includes("price confirmed before anything is charged."), "the ratified price copy renders");
      assert.ok(body.includes("Falkenstein"), "the human region name renders");
      // GR18(5): console open-by-default with the worker's redacted narration.
      assert.ok(body.includes("new-console"), "the console panel mounts");
      assert.ok(!body.includes("new-console is-collapsed"), "the console is open by default");
      assert.ok(body.includes("configure: docker compose up -d"), "the live console lines render");
    },
  },
  "theater-failed": {
    what: "the /new theater failed — the snap: red failed step, skipped rest, ONE recovery action",
    check(reg) {
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.includes("new-failed"), "the failed theater must be mounted");
      assert.ok(body.includes("Setup didn&#39;t finish"), "the honest headline renders");
      // GR18(4): the honest server-owned failCopy, verbatim.
      assert.ok(body.includes("the TLS certificate was never issued"), "provision_error renders verbatim");
      // The snap: the failing step is failed, everything behind it is skipped —
      // never a live pending row, never a plan hint.
      assert.ok(body.includes('class="new-step failed" data-step="secure"'), "secure renders failed");
      assert.equal(countMatches(body, '<li class="new-step skipped"'), 3, "configure/verify/ready render skipped");
      assert.ok(!body.includes('class="new-step pending"'), "no live pending rows behind a failure");
      // ONE recovery action (parent D25) + the console stays for the read-out.
      assert.equal(countMatches(body, 'id="new-retry"'), 1, "exactly one Retry recovery action");
      assert.ok(body.includes(">Retry setup<"), "the recovery action is Retry setup");
      assert.ok(body.includes("new-console"), "the console stays on the failed screen");
      assert.ok(body.includes("provision FAILED after 3 attempts"), "the console carries the failure tail");
    },
  },
  "theater-ready": {
    what: "the /new ready hero — the SHARED readyHeroHtml: Live eyebrow, Open Studio, deploy handoff",
    check(reg) {
      const body = reg.get("new-body").innerHTML || "";
      assert.ok(body.includes("new-ready"), "the shared ready hero must render");
      assert.ok(body.includes("Hugin is ready"), "the hero names the live instance");
      assert.ok(body.includes('id="new-open-studio"'), "Open Studio is the primary action");
      assert.ok(body.includes("hugin-5b2c1e.barkpark.cloud"), "the live URL renders");
      assert.ok(body.includes(">View instance<"), "the secondary View-instance affordance renders");
      assert.ok(!body.includes("new-progress"), "the progress theater has handed over");
    },
  },

  // ── gr-p2 HOME TRIAGE (C-01/C-02): the v4 Overview states (tail-append, OC9) ─
  "overview-trial-runway": {
    what: "the self-healing runway binds to onboarding: 2 of 3, the real instance-name hint, the Open Studio nudge",
    check(reg) {
      const state = (reg.get("overview-state") || {}).innerHTML || "";
      assert.ok(state.includes("runway-card"), "the mint runway card renders");
      assert.ok(state.includes("You're nearly set up"), "the runway heading renders");
      assert.ok(state.includes("2 of 3 done"), "progress binds to onboarding server truth");
      assert.ok(state.includes("Production is running"), "the instance step carries the real fleet-cache name");
      assert.ok(state.includes("Publish your first document"), "the pending published_doc step renders");
      assert.ok(state.includes("Open Studio"), "the pending step offers Open Studio");
      assert.ok(!state.includes("dunning-banner"), "runway and past-due banner are mutually exclusive");
    },
  },
  "overview-attention": {
    what: "the attention queue leads with the degraded box + its real reason + a working Open Studio",
    check(reg) {
      const body = (reg.get("overview-body") || {}).innerHTML || "";
      assert.ok(body.includes("Needs attention"), "the attention section heading renders");
      assert.ok(body.includes("attention-row"), "an attention row renders");
      assert.ok(body.includes(">Reporting</a>"), "the degraded box is named + linked");
      assert.ok(/Health down|Agent offline/.test(body), "the row carries the real status reason");
      assert.ok(body.includes("View instance"), "the row offers View instance");
      assert.ok(body.includes("fleet-open-studio"), "the row offers a working Open Studio");
      const grid = (reg.get("overview-instances") || {}).innerHTML || "";
      assert.ok(grid.includes("instance-card--warn"), "the degraded card carries the amber accent");
    },
  },
  // cch-w34-s6 (REVIEW ADDITION). Every string below is DERIVED FROM THE
  // FIXTURE, and the EXCLUSIONS are the load-bearing half: the row carries
  // `health_status: "up"`, so a console that reprints its cached column would
  // pass an includes-only check and still be telling the lie the slice removed.
  "overview-never-reported": {
    what: "a box the control plane has never heard from reads Never reported — never the cached green Up",
    check(reg) {
      const grid = (reg.get("overview-instances") || {}).innerHTML || "";
      assert.ok(grid.includes("Never reported"), "the never-reported box names the absence as a STATE");
      assert.ok(grid.includes("38d ago"), "…with the age since creation as evidence");
      assert.ok(grid.includes("3 missed checks"), "…and the sweep's own unreachable_count, finally read");
      assert.ok(grid.includes("instance-card--neutral"), "the card reaches the neutral accent (rule added at review)");
      assert.ok(!grid.includes("Unclassified"), "the loud fallthrough is NOT how this state renders");
      // The kind control is in the same DOM: a fix that neutered the pill for
      // everyone would take Healthy down with it.
      assert.ok(grid.includes("Healthy"), "the reporting box beside it still reads Healthy");
      assert.ok(!/Never reported[^<]*<[^>]*>[^<]*v0\.9\.2/.test(grid), "no version is invented for a box that never reported");
    },
  },
  "overview-past-due": {
    what: "GR17 overview dunning banner + the suspended instance-card banner, verbatim, no runway",
    check(reg) {
      const state = (reg.get("overview-state") || {}).innerHTML || "";
      // cch-w54-s5: dateless, and ISOLATION rather than a suspension no code
      // performs (maybe_enforce/1's suspend arm is unreachable in production).
      assert.ok(state.includes("Your payment failed. Nothing stops and nothing is deleted"),
        "the overview banner lead sentence renders verbatim");
      assert.ok(state.includes("this team can't launch a new instance until payment succeeds"),
        "the overview banner names the go-live gate, the one real consequence");
      assert.ok(state.includes("Isolation, not shutdown."), "the isolation sentence renders verbatim");
      assert.ok(!/suspend/i.test(state), "the overview banner must promise no suspension");
      assert.ok(!/\b(January|February|March|April|May|June|July|August|September|October|November|December)\b|\d{1,2}\/\d{1,2}/.test(state),
        "and must name no calendar day — the failed-on day was back-computed from a sliding anchor");
      assert.ok(state.includes("Update payment method"), "the portal CTA renders");
      assert.ok(!state.includes("runway-card"), "the runway is suppressed on the past-due path");
      const grid = (reg.get("overview-instances") || {}).innerHTML || "";
      assert.ok(grid.includes("suspended-card-banner"), "the suspended box carries the GR17 card banner");
      // cch-w54-s1 — the card names what suspension actually withdrew (Cloud's
      // management), not a stop nothing in this plane performs. The rendered
      // DOM is the pin, so a helper that stopped being called would red here.
      assert.ok(grid.includes("Barkpark Cloud has stopped managing it"), "the suspended-card body renders verbatim");
      // cch-w54-bl — THE DAY, IN THE RENDERED DOM. The card used to date itself
      // from `sub.current_period_end` (this scenario's sub renews at T+3d)
      // because `suspended_at` reached no wire. It now reads the suspension's
      // own stamp, which the corpus box carries as a fixed 2026-06-12.
      //
      // The pin is the WHOLE TITLE, by equality, not a substring: a substring
      // check passes on "Suspended <right day>" even if a second, wrong date is
      // sitting beside it, and the failure this guards against is precisely a
      // date arriving from the wrong source. Equality means any other day —
      // renewal, birthday, today — reds, without this test having to enumerate
      // which wrong day it fears.
      const expectedDay = new Date(Date.parse("2026-06-12T12:00:00.000Z"))
        .toLocaleDateString(undefined, { month: "long", day: "numeric" });
      const cardTitle = (grid.match(/<div class="suspended-card-title">([\s\S]*?)<\/div>/) || [])[1];
      assert.ok(cardTitle, "the suspended card must render a title element to pin");
      assert.equal(cardTitle, `Suspended ${expectedDay} — payment failed`,
        "the suspended card names the day the plane stamped, and nothing else");
      assert.ok(!grid.includes("The server is stopped"), "the console never paints a stop it does not perform");
      assert.ok(!grid.includes("suspended — not deleted"), "trial-expiry copy never leaks onto the suspended card");
      // The pill beside it moved with the copy: the WORD is Suspended, and the
      // `bp-inst--stopped` S4 token (the hue) is deliberately unchanged.
      assert.ok(!/inst-life-label">Stopped</.test(grid), "no pill paints the literal word Stopped");
    },
  },
  // ── gr-p3 D-01: the v4 Fleet list + Archives (screens/01) ──────────────────
  "fleet-v4": {
    what: "v4 fleet rows (leading pill, mono meta, the update chip on the behind box) + archives storage-unconfigured",
    check(reg) {
      const body = (reg.get("fleet-body") || {}).innerHTML || "";
      assert.ok(body.includes('class="fleet-row"'), "the fleet rows render");
      assert.ok(body.includes('class="fleet-status"'), "the lifecycle pill leads its own column");
      assert.ok(body.includes('class="fleet-meta"'), "the mono metadata line renders");
      assert.ok(body.includes("fsn1 · cx32 · v0.1.0"), "the metadata is backend-true (region · size · version)");
      assert.ok(body.includes("fleet-update-chip--ready"), "the behind box carries the update chip");
      assert.ok(body.includes("v0.2.25 available"), "the chip names the real target release");
      assert.ok(!body.includes("Update available"), "the update signal is the chip, never a doubled pill");
      assert.ok(body.includes("provider-chip--hetzner") && body.includes("provider-chip--azure"), "provider marks render per row");
      const arch = (reg.get("archives-body") || {}).innerHTML || "";
      assert.ok(arch.includes("archives-note--unconfigured"), "archives shows the DISTINCT storage-unconfigured state");
      assert.ok(arch.includes("Archive storage isn"), "the server's not_configured copy renders verbatim");
      // gr-blk-archives-doc-link: the "How archives work" anchor pointed at the
      // bare repo root — nothing in the repo answers the question, so the
      // affordance became the answer itself rather than a relocated dead end.
      assert.ok(arch.includes("archives-note-sub"), "the in-place explanation renders");
      assert.ok(!arch.includes("github.com"), "and no invented docs URL took its place");
      assert.ok(arch.includes("data-archives-retry"), "a working Retry renders");
    },
  },
  // ── cch-w21-s3 (REVIEW ADDITION): the cruel fixture's expectation.
  // The slice committed `fleet-cruel-content` and taught breakpoint-sweep about
  // it, but not this file — and smoke's census guard is two-way, so the whole
  // harness step exited 1 with "1 committed scenario(s) have NO expectation and
  // were never run". That refusal is correct and it is the epic's own law: a
  // fixture nothing asserts on is a green that means nothing. So the fixture
  // gets a real expectation, and every string below is DERIVED FROM THE FIXTURE
  // rather than typed — a corpus edit that quietly shortens the cruel content
  // reds here instead of passing on a stale literal.
  // cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts (absorbing
  // cch-w15-bl-detail-url-fixture-never-overflows): the cruel instance's own
  // detail. BOTH halves of the w15 fix shape that a fake DOM can see are
  // pinned here: the full 253-char host renders as the span's TEXT, and the
  // adjacent copy-btn's data-copy carries the identical full value — so the
  // truncation the browser paints (CSS ellipsis) is always recoverable. The
  // GEOMETRY half (scrollWidth > clientWidth at 1440) needs a real browser and
  // is driven, not asserted here.
  "instance-cruel-detail": {
    what: "Instance detail — the 253-char custom host reaches .detail-url-text whole, and data-copy carries the identical full value",
    check(reg) {
      const bp = SCENARIOS["instance-cruel-detail"].data.barkparks[0];
      assert.ok(bp.custom_host && bp.custom_host.length === 253,
        "the fixture's custom_host must sit AT the 253 cap — it reads " + String(bp.custom_host || "").length + " — GONE KIND otherwise");
      const url = "https://" + bp.custom_host;
      const body = reg.get("instance-body").innerHTML || "";
      assert.ok(body.includes("detail-url-text"), "the address line renders through .detail-url-text");
      assert.ok(body.includes(">" + url + "<"), "the FULL public URL is the span's text — the DOM carries the whole value, CSS does the clipping");
      assert.ok(body.includes('data-copy="' + url + '"'),
        "the adjacent copy-btn's data-copy equals the full untruncated value — the w15 recoverability half");
    },
  },
  "fleet-cruel-content": {
    what: "server-legal worst-case CONTENT on the fleet table — a 253-char custom domain, a 255-char name and a 512-char single-token provision error, all rendered beside a KIND neighbour in the same DOM",
    check(reg) {
      const rows = SCENARIOS["fleet-cruel-content"].data.barkparks;
      const cruel = rows.find((b) => b.custom_host && b.custom_host.length > 200);
      // cch-w23 REVIEW: the kind neighbour is picked by what makes it KIND — it
      // renders a short address of its own — not by "whatever is not the cruel
      // row". cch-w23-s1 added a THIRD row to this fixture (a failed box with a
      // 512-char single-token provision error and NO host), and a positional
      // `find(b => b !== cruel)` silently returned THAT one: `kind.host` went
      // undefined and `body.includes(undefined)` failed the whole harness step.
      // A selector that cannot say what it is selecting for is this epic's own
      // fifth clause pointed at an oracle.
      const kind = rows.find((b) => b !== cruel && b.host);
      // The single-token row is asserted on its own terms below rather than
      // being tolerated as "some other row".
      const tokenRow = rows.find((b) => b.provision_error && b.provision_error.length > 200);
      assert.ok(cruel, "the fixture still carries a cruel row (a >200-char custom_host)");
      assert.ok(kind, "the cruel row keeps a KIND neighbour — a bound that fixes one by shredding the other must be visible in the same DOM");
      assert.equal(cruel.custom_host.length, 253, "the host sits AT the server's validate_length cap (registry/barkpark.ex:727)");
      assert.equal(cruel.name.length, 255, "the name sits AT the server's cap (registry/barkpark.ex:466)");
      assert.ok(
        cruel.custom_host.split(".").some((l) => l.length === 63),
        "at least one MAXIMAL 63-char DNS label — a hyphen is a line-break opportunity, so a hyphen-rich host is not cruel at all",
      );
      const body = (reg.get("fleet-body") || {}).innerHTML || "";
      assert.ok(body.includes('class="fleet-row"'), "the fleet rows render");
      // publicUrl() PREFERS custom_host, so the CRUEL host is what the row paints.
      assert.ok(body.includes(cruel.custom_host), "the row renders the custom domain, not the barkpark.cloud fallback");
      // The fixture name carries no HTML-escapable character, so it renders verbatim;
      // this assertion also pins that (an escape would break the substring match).
      assert.ok(!/[&<>"]/.test(cruel.name), "the cruel name stays free of escapable characters, so it renders verbatim");
      assert.ok(body.includes(cruel.name), "the row renders the full 255-char name");
      assert.ok(body.includes(kind.host), "the kind neighbour still renders its own short address in the same table");
      assert.ok(countMatches(body, 'class="fleet-row"') >= 2, "both rows render — one of them alone proves nothing about the other");
      // cch-w23-s1's SHAPE axis: a machine-written error with no break
      // opportunity, painted verbatim into the status pill's detail. Derived
      // from the fixture, never typed, so a corpus edit that shortens or breaks
      // the token reds here instead of passing on a stale literal.
      if (tokenRow) {
        assert.ok(
          !/[\s\-./]/.test(tokenRow.provision_error),
          "the provision error stays a SINGLE UNBROKEN TOKEN — a space, hyphen, slash or dot is a line-break opportunity, and a breakable string wraps by itself",
        );
        assert.ok(body.includes(tokenRow.provision_error), "the failed row paints the provision error verbatim into its status-pill detail");
        assert.ok(countMatches(body, 'class="fleet-row"') >= 3, "all three rows render — the cruel host, the single-token error and the kind neighbour in ONE DOM");
      }
    },
  },
  "fleet-archives-stored": {
    what: "the Archives panel lists portable bundles, each with its CLI command — and a live Resurrect only for an actor the route will accept",
    check(reg, hooks) {
      const arch = (reg.get("archives-body") || {}).innerHTML || "";
      assert.ok(arch.includes("archive-list"), "the populated archive list renders");
      assert.ok(countMatches(arch, 'class="archive-row"') >= 2, "one row per bundle");
      assert.ok(arch.includes("shop-9f2c1"), "a bundle is named by its fqdn");
      // cch-w47-s3 — THIS ASSERTION USED TO BE A CONSTANT ("each row offers
      // Resurrect") and it passed for a reason it never named: this scenario's
      // actor is the DEFAULT OWNER (me() defaults role to "owner"), and the
      // button was drawn on slug presence alone, so it would have passed just
      // the same for the plain member the route refuses with a 403. The offer
      // is now decided by instanceAdminAuthority, so the expectation is DERIVED
      // from the actor this scenario actually boots with: an owner still MUST
      // see it (the grant arm is not weakened), and if a future corpus edit
      // demotes this actor, the button must vanish with it.
      const granted = hooks.meState() === "loaded" &&
        (hooks.meFlags().role === "owner" || hooks.meFlags().role === "admin");
      assert.equal(granted, true,
        "fleet-archives-stored boots the DEFAULT OWNER — got " + hooks.meState() + "/" + JSON.stringify(hooks.meFlags().role));
      assert.equal(arch.includes("archive-resurrect-btn"), granted,
        "the live Resurrect is offered exactly to an actor holding team-admin authority");
      // The CLI command is NOT authority-gated — it teaches, it does not write.
      assert.ok(arch.includes("bp cloud instance resurrect"), "every reader keeps the copy-paste CLI affordance");
      assert.ok(!arch.includes("archives-note--unconfigured"), "a configured store never shows the unconfigured state");
    },
  },

  // ── gr-p3 instance workspace (GR24/GR30): D-02 header + D-03 Overview ──────
  // The scenario predates this wave with a fixture but ZERO assertions (the
  // GR30 vacuous-green finding) — these are its first EXPECTATIONS.
  "panel-overview": {
    what: "the v4 instance workspace: two-axis header, bp CLI card, composed Overview — AND a real typed Decommission that tears the instance out of the SERVER's fleet",
    async check(reg, hooks, ctx) {
      const body = reg.get("instance-body").innerHTML || "";
      // D-02 header: H1 + the two-axis compound pill + mono address + copy.
      assert.ok(body.includes("detail-head--inst"), "the v4 header renders");
      assert.ok(body.includes("status-pill-label"), "the compound pill renders its label axis");
      // cch-w18-bl-smoke-address-copy-assertion-matches-the-rail-row: this line
      // used to read `body.includes('data-copy="production-5b2c1e.barkpark.cloud"')`
      // — a BARE host, which the ADDRESS LINE has not emitted since cch-w18-s4
      // gave the instance fixtures their real scheme: publicUrl(bp) is now
      // "https://production-5b2c1e.barkpark.cloud" (publicUrl() in app.js —
      // grep -n 'function publicUrl'). The host emits THREE [data-copy] values,
      // and the one that satisfied the bare literal was the rail's Platform/Host
      // row (railRowCopy() in app.js — grep -n 'function railRowCopy'; value =
      // bp.host, still bare) — a different element in a different card. So the
      // assertion's MESSAGE named the address line while its SUBJECT was the
      // rail: deleting the address line's copy button entirely left it green.
      // Scoped to the .detail-url host and pinned to the SCHEMED value, the two
      // elements can no longer stand in for each other.
      const addr = (body.match(/<div class="detail-url">[\s\S]*?<\/div>/) || [])[0] || "";
      assert.ok(addr, "the address line renders as .detail-url; got: " + body.slice(0, 400));
      const addrCopy = (addr.match(/<button[^>]*class="copy-btn"[^>]*>/) || [])[0] || "";
      assert.ok(addrCopy, "the ADDRESS LINE itself carries the copy affordance; got: " + addr);
      assert.ok(addrCopy.includes('data-copy="https://production-5b2c1e.barkpark.cloud"'),
        "the address's copy affordance carries the SCHEMED public URL the address line paints, not the rail's bare host; got: " + addrCopy);
      assert.ok(body.includes('id="inst-open-studio"'), "Open Studio is the primary action");
      assert.ok(body.includes('id="inst-cli-toggle"'), "the bp CLI disclosure renders");
      assert.ok(body.includes('aria-controls="inst-lifecycle-actions"'), "the disclosure points at the card slot");
      // D-03 Overview: one composed pass — updates card, Sites card, card rail.
      assert.ok(body.includes("update-panel"), "the updates card renders");
      // cch-w45-bl — patchAutoupdate, ON THE GRANT ARM. cch-w47-s2 put the CP's
      // real policy block on every bpBase row, which is what makes
      // hasAutoupdatePolicy true and paints these four toggles at all; until
      // then they rendered in ZERO committed scenarios. The only corpus-level
      // assertion that block had was `panel-overview-member`'s count of five
      // disable-and-explain wrappers — a NEGATIVE, so reverting the fixture
      // moved a number rather than naming a verb. These name it, positively, on
      // the actor who is actually offered it.
      assert.ok(body.includes('<button class="btn btn-ghost btn-sm" type="button" data-au="pause">Pause autoupdate</button>'),
        "patchAutoupdate: the admin arm paints the live Pause toggle (PATCH /v1/barkparks/:id/autoupdate)");
      assert.ok(body.includes('<button class="btn btn-ghost btn-sm" type="button" data-au="pin">Pin version</button>'),
        "patchAutoupdate: …and the live Pin toggle, its independent freeze");
      assert.ok(body.includes('rail-row"><span class="k">Autoupdate</span>'),
        "patchAutoupdate: the policy chip the toggles act on renders beside them");
      assert.ok(body.includes("inst-sites-card"), "the Sites card renders");
      assert.ok(body.includes("detail-rail--cards"), "the rail renders as cards");
      for (const label of ["Identity", "Runtime", "Platform", "Activity"]) {
        assert.ok(body.includes('rail-group-label">' + label + "<"), "rail card " + label + " renders");
      }
      assert.ok(body.includes('id="instance-domains"'), "the domain-checklist slot renders (component consumed as-is)");
      assert.ok(body.includes('id="instance-tabpanel"'), "the tab panel pin holds");
      // The bp CLI card paints into its slot from the capabilities conduit:
      // 4 copyable commands, the SERVER-OWNED pause sentence, Decommission….
      const card = reg.get("inst-lifecycle-actions").innerHTML || "";
      assert.ok(card.includes("Manage this instance via the bp CLI"), "the CLI card head renders");
      for (const verb of ["archive", "resurrect", "adopt", "audit"]) {
        assert.ok(card.includes("bp cloud instance " + verb + " Production"), "the " + verb + " command chip renders");
      }
      assert.ok(card.includes("bills for as long as it exists"), "the foot renders the conduit's own pause sentence");
      assert.ok(!card.includes("archive it instead"), "the foot never prescribes archiving as a way to stop paying (cch-w55-s2)");
      assert.ok(card.includes('data-life-verb="decommission"'), "the typed-confirm Decommission anchors the foot");
      // The golden-path verify card fills its slot off the events feed
      // (no verify event in the fixture → the honest never-run invite).
      const vf = reg.get("instance-verify").innerHTML || "";
      assert.ok(vf.includes("vf-card"), "the golden-path card renders");
      assert.ok(vf.includes("Golden path"), "the card heading renders");
      assert.ok(vf.includes("Run first check"), "the never-run state invites the first check");
      // Sites slot resolves to the honest empty state (fixture has no sites).
      const sites = reg.get("instance-sites").innerHTML || "";
      assert.ok(sites.includes("No sites yet"), "the Sites empty state renders");

      // ── cch-w10 LEG 5/5: DECOMMISSION, CLICKED FOR REAL ───────────────────
      // THIS LEG'S ORACLE HAS A DIFFERENT SHAPE FROM THE OTHER FOUR, and the
      // difference is not cosmetic. runDecommission drops fleetCache and sets
      // location.hash = "#fleet" — it NAVIGATES AWAY rather than refetching the
      // surface, so there is no repainted list to count. A UI row count here
      // would either assert a stale panel (green forever) or a panel the shim's
      // inert location never re-routes (red forever). The only honest oracle is
      // the SERVER's own list, read straight off the state bag.
      //
      // DELETE /v1/barkparks/:id was UNMODELLED until this wave: it fell through
      // the terminal `/v1/` 200 {} catch-all, so the console's most destructive
      // verb succeeded against a fixture that never lost anything.
      const bp = SCENARIOS["panel-overview"].data.barkparks[0];
      assert.equal(ctx.state.barkparks.length, 1, "the fleet starts at one instance");
      const cardEl = reg.get("inst-lifecycle-actions");
      const decomm = cardEl.querySelectorAll('[data-life-verb="decommission"]');
      assert.equal(decomm.length, 1,
        "the CLI card must carry exactly one wired Decommission; got " + decomm.length +
        " — 0 means the shim's attribute selector regressed and this leg proves nothing");
      assert.equal(decomm[0].click(), 1, "Decommission dispatched no click handler — it is DEAD");
      const bpPath = "/v1/barkparks/" + bp.id;
      assert.equal(ctx.countCalls("DELETE", bpPath), 0,
        "Decommission tore down the server on the row click — the typed-confirm gate is gone");

      // ── cch-w57-s3: THE FIRST ASSERTIONS THIS COPY HAS EVER HAD ───────────
      // The consequence bullets were unpinned in the whole tree (grep returned
      // exactly one hit per string, app.js itself), so the sheet was free to
      // promise an erasure the plane does not perform. This leg already renders
      // the REAL sheet into #modal-body; it just never read the words.
      // The three residues asserted here are all MEASURED, not stylistic: the
      // archive bundle has no delete path at all, DELETE /v1/barkparks/:id
      // reaches no Billing function, and a customer-owned DNS record is never
      // retracted. The FORBIDDEN half matters as much: no window and
      // no number of days may appear, because there is no reaper to back one.
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes('class="cm-consequences"'),
        "the destroy sheet must render its consequence list; got: " + sheet.slice(0, 200));
      assert.ok(sheet.includes("Tears down the server for good"),
        "the live arm must still say plainly what it destroys; got: " + sheet.slice(0, 400));
      assert.ok(sheet.includes("archive bundle") && sheet.includes("no way to delete it"),
        "the sheet must disclose the archive bundle the control plane cannot delete");
      assert.ok(sheet.includes("Billing does not stop here"),
        "the sheet must stop implying the teardown cancels the subscription");
      assert.ok(!/\b\d+\s*(day|days|week|weeks|month|months)\b/i.test(sheet),
        "the sheet named a window in days — there is no reaper, and inventing one is the very defect this fixes: " +
        sheet.slice(0, 400));
      assert.ok(sheet.includes("stays behind"),
        "the finality line must be about the row, with the residue named beside it");
      // THE CONDITIONAL, BOTH WAYS. The fixture instance carries NO custom host
      // (derived, never typed), so the DNS sentence must be absent here…
      const inst = ctx.state.barkparks[0];
      assert.equal(inst.custom_host, null,
        "this branch assertion is only meaningful while the fixture carries no custom host; got: " + inst.custom_host);
      assert.ok(!sheet.includes("your own DNS record"),
        "the customer-DNS sentence fired on an instance with no custom host at all");

      assertDestroySheetDisarmed(reg, "Decommission");
      reg.get("cm-confirm").click();
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", bpPath), 0,
        "an UNARMED destroy Confirm tore down a live server");
      assert.equal(ctx.state.barkparks.length, 1, "and nothing left the fleet while it was unarmed");

      armConfirmSheet(reg, bp.name).click();
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", bpPath), 1, "the armed Confirm must issue exactly one teardown");
      assert.equal(ctx.state.barkparks.length, 0,
        "the SERVER's fleet must shrink by exactly one (1 → 0); got " + ctx.state.barkparks.length +
        " — an unchanged fleet means the teardown hit the catch-all and did nothing");
      const fleetAfter = route("panel-overview", "GET", "/v1/barkparks", ctx.state);
      assert.equal(fleetAfter.body.barkparks.length, 0,
        "and a fresh fleet READ agrees — the shrink is served, not just spliced into a bag nobody reads");
      const decomToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(decomToast.includes("Decommissioning " + bp.name) && decomToast.includes("is gone"),
        "the teardown must report itself, with the server's own 200-vs-202 distinction; got: " + decomToast.slice(0, 200));

      // ── cch-w57-s3: THE CUSTOM-DOMAIN BRANCH, RENDERED FOR REAL ───────────
      // Attach writes `dns_zone: nil` for a non-platform FQDN and there is no
      // detach route anywhere, so a customer's own A record outlives the box and
      // keeps pointing at an address Hetzner will hand to someone else. The
      // discriminator is the PLATFORM SUFFIX (externalCustomHost in app.js), and
      // a sentence that fires on the wrong side is worse than none — so BOTH
      // sides are driven here, through the same real click that opened the sheet
      // above. `inst` is the per-boot fixture row the rail closed over (the
      // route serves the state bag's objects by reference), so writing the field
      // is what the console would see on a box that carries one. Nothing is
      // armed after this point: these clicks re-render the sheet and issue no
      // request (the DELETE count assertions above are already sealed).
      const hostBefore = inst.custom_host;
      inst.custom_host = "console.acme.example";
      assert.equal(decomm[0].click(), 1, "the Decommission handler died before the custom-host branch could render");
      const extSheet = reg.get("modal-body").innerHTML || "";
      assert.ok(extSheet.includes("console.acme.example is your own DNS record"),
        "an EXTERNAL custom host must be named as the customer's own record; got: " + extSheet.slice(0, 500));
      assert.ok(extSheet.includes("Hetzner") && extSheet.includes("someone else"),
        "and the released IP that Hetzner recycles must be stated, not implied");
      // Read around the apostrophe: consequences ride through esc(), which
      // renders "can't" as "can&#39;t" — an assertion typed with the raw
      // character would be red for a reason that has nothing to do with the copy.
      assert.ok(extSheet.includes("repoint the record for you"),
        "and the console must admit it cannot fix that record for them; got: " + extSheet.slice(0, 500));
      assert.ok(!/\b\d+\s*(day|days|week|weeks|month|months)\b/i.test(extSheet),
        "the custom-host branch named a window in days; got: " + extSheet.slice(0, 500));
      // …and the PLATFORM side, whose zone the control plane does own end to end
      // (the attach modal accepts <name>.barkpark.cloud and nothing else), must
      // stay silent — the sentence is about a record we never held.
      inst.custom_host = "production-5b2c1e.barkpark.cloud";
      assert.equal(decomm[0].click(), 1, "the Decommission handler died before the platform-host branch could render");
      const platSheet = reg.get("modal-body").innerHTML || "";
      assert.ok(!platSheet.includes("your own DNS record"),
        "the customer-DNS sentence fired on a PLATFORM host, whose zone Barkpark Cloud owns; got: " + platSheet.slice(0, 500));
      assert.ok(platSheet.includes("archive bundle"),
        "…while the residues that are NOT conditional must still render on that same sheet");
      inst.custom_host = hostBefore;
    },
  },

  // ── cch-w38-s1: the instance rail as a plain MEMBER ────────────────────────
  // cch-w38-s1: the SAME screen, as a plain MEMBER.
  // The BEFORE frame (browser-measured on origin/main, chrome-devtools against
  // serve.mjs): {"port":"4187","meRole":"member","decommission":{"disabled":
  // false,"visible":true},"totalDisabled":0} — a member was offered the
  // destroy-tier verb the server answers 403. The AFTER contract (D428): the
  // control is DISABLED and carries the server's OWN sentence, never hidden.
  // The reason asserted below is FORBIDDEN_ROLE_COPY.admin verbatim — if a
  // future edit mints fresh copy for this arm, this expectation says so.
  "panel-overview-member": {
    what: "a plain member's instance rail refuses the destroy verb UP-FRONT, in the server's own words — no live control, no post-click 403",
    check(reg) {
      const card = (reg.get("inst-lifecycle-actions") || {}).innerHTML || "";
      assert.ok(card.length > 0, "#inst-lifecycle-actions rendered empty");
      assert.ok(card.includes("Manage this instance via the bp CLI"), "the CLI card still renders in full — the rail is never hidden from a member");
      // The remedy: a disabled control + the server's own role sentence.
      assert.ok(card.includes("inst-life-disabled"), "the refused verb renders through the disable-and-explain arm");
      assert.ok(card.includes("You need the admin role on this team — an admin on this team can grant it."),
        "the visible reason is the SERVER's sentence (FORBIDDEN_ROLE_COPY.admin), verbatim");
      assert.ok(card.includes("inst-life-reason"), "the sentence rides the shipped reason span, not new markup");
      // And the live affordance is GONE: no click hook, no danger button. This
      // assertion names the attribute the mount binds on, so an added
      // `disabled` cannot slip past it the way a [^>]* window would.
      assert.ok(!card.includes('data-life-verb="decommission"'), "no click hook is wired for a verb the server will refuse");
      assert.ok(!card.includes("btn-danger"), "the destroy-tier styling goes with the destroy-tier affordance");
      // NOT a checking state: /v1/me answered, and it said member.
      assert.ok(!card.includes("Checking capabilities"), "an ANSWERED /v1/me is not a checking state");

      // ── cch-w45-s5: and the rail is not the only place the screen was
      // selling this member a 403. Measured on the PRE-FIX tree by booting THIS
      // scenario: #instance-body carried a LIVE `id="inst-domain"` button and a
      // LIVE `data-rollback="1"` button, both against require_primary_team_admin
      // routes, while every read the screen makes is `user`. Same remedy, same
      // sentence, same grammar — asserted on the BODY, not the CLI card.
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.includes("Attach domain"), "the Attach domain affordance is never hidden from a member — it explains itself");
      assert.ok(body.includes("Roll back"), "nor is Rollback");
      assert.ok(!body.includes('id="inst-domain"'),
        "no click hook is wired for the domain attach the server will refuse");
      assert.ok(!body.includes("data-rollback"),
        "no click hook is wired for the rollback the server will refuse");
      assert.ok(body.includes("You need the admin role on this team — an admin on this team can grant it."),
        "both refusals speak the SERVER's sentence (FORBIDDEN_ROLE_COPY.admin), verbatim");
      // cch-w47-s2: FOUR, not two — the same screen was also offering this
      // member the autoupdate policy toggles (patch /v1/barkparks/:id/autoupdate,
      // require_primary_team_admin). With bpBase carrying the CP's real policy
      // block, `autoupdateActions` offers Pause + Pin on this row, and
      // adminWriteControlHtml emits ONE wrapper PER control: domain + rollback +
      // pause + pin = 4. Add Support takes the OMIT arm (D514) and adds none.
      //
      // cloud-agent onramp: FIVE. "Connect agent" (GET
      // /v1/barkparks/:id/credentials) joins them, and it is the first entry
      // here that is not a WRITE — it is a READ that reveals the plaintext
      // instance admin token, so it carries the same team-admin gate and takes
      // the same arm. The wording below is widened to say so rather than left
      // counting "writes" and quietly meaning something else.
      assert.equal(countMatches(body, '<div class="inst-life-disabled">'), 5,
        "exactly the five member-reachable admin-gated affordances render through the disable-and-explain arm");
      assert.ok(body.includes("Connect agent"),
        "the credential reveal is never hidden from a member — it explains itself like its neighbours");
      assert.ok(!body.includes('id="inst-connect-agent"'),
        "no click hook is wired for the credential reveal the server will refuse");
      assert.ok(!body.includes('data-au='),
        "no click hook is wired for the autoupdate policy writes the server will refuse");
      assert.ok(!body.includes("fleet-add-support"),
        "and the add-support affordance is omitted outright for a member (D514)");
      assert.ok(!body.includes("Checking capabilities"),
        "an ANSWERED /v1/me is not a checking state on the body either");
      assert.ok(!body.includes("data-me-retry"),
        "and an answered read offers no /v1/me retry — the exit belongs to the unknown arm alone");
    },
  },

  // ── gr-p3 D-04: the timeline coalescing grammar (tail-append, OC9) ──────────
  "timeline-coalesced": {
    what: "the coalescing grammar folds the health burst to ONE worst-verdict row with Show all/Collapse",
    check(reg, hooks) {
      // Routing: the deep link lands the Timeline tab exactly like the other
      // C8 states (the strip is the shim-observable half of the mount).
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.includes('/timeline" aria-current="page"'), "the Timeline tab must be current");
      assert.ok(body.includes('id="instance-tabpanel"'), "the tabpanel must render");
      // The feed itself paints through element-level querySelector (inert in
      // this shim), so drive the SAME pure pipeline loadTimeline runs —
      // mergeTimeline → coalesceEntries → timelineFeedHtml — over this
      // scenario's committed fixture, and pin the §07 grammar end-to-end.
      const d = SCENARIOS["timeline-coalesced"].data;
      const events = Object.values(d.instanceEvents)[0];
      const entries = hooks.mergeTimeline(events, d.audit);
      const closed = hooks.timelineFeedHtml(entries, {});
      assert.equal(countMatches(closed, 'class="tlv-row tlv-coalesce"'), 1, "the 10-beat burst folds to ONE row");
      assert.ok(closed.includes("Health report"), "the group names its kind");
      assert.ok(closed.includes("&times; 10"), "the × N count renders");
      assert.ok(closed.includes("all reporting health: down"), "the WORST verdict is stated");
      assert.ok(/every ~1m for \d+m/.test(closed), "the cadence segment renders from the members' stamps");
      assert.ok(closed.includes(">Show all 10<"), "the expand affordance renders");
      assert.ok(!closed.includes("tlv-coalesce-members"), "members stay out of the DOM while collapsed");
      assert.ok(closed.includes("Status → offline"), "the singleton status row still renders enriched");
      // Expanded state: Collapse + every member row on the inset rail.
      const gkey = (closed.match(/data-tlv-group="([^"]+)"/) || [])[1];
      assert.ok(gkey, "the group carries its stable key");
      const open = hooks.timelineFeedHtml(entries, { openGroups: [gkey] });
      assert.ok(open.includes('aria-expanded="true">Collapse<'), "the open group offers Collapse");
      assert.ok(open.includes("tlv-coalesce-members"), "the member rail renders");
      assert.equal(countMatches(open, 'data-tlv-key="'), 13, "10 members + status + the 2 audit rows all render");
    },
  },

  // ── D-05 (tail-append, OC9): the v4 Webhooks auto-disabled state ────────────
  // The endpoint list renders the auto-disabled endpoint's COUNT-FREE banner with
  // a Re-enable action (the deliveries card + real-response replay are click-driven
  // → inert here, so unit-pinned in __app.test.mjs). The banner must carry the
  // server reason verbatim but NO client-authored failure count.
  "webhooks-autodisabled": {
    what: "the auto-disabled endpoint's count-free banner + Re-enable render in the list",
    check(reg) {
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel webhook list rendered empty");
      assert.ok(panel.includes('class="wh-card"'), "the endpoint list must render webhook cards");
      assert.ok(panel.includes("wh-autodisable"), "the auto-disabled banner renders");
      assert.ok(panel.includes("Auto-disabled"), "the banner leads with the Auto-disabled label");
      assert.ok(panel.includes("endpoint returned 500 Internal Server Error"), "the server disable_reason renders verbatim");
      assert.ok(panel.includes("data-wh-reenable"), "the banner offers Re-enable (the one recovery action)");
      assert.ok(!panel.includes("wh-autodisable-count"), "count-free: no client-authored failure count span");
      assert.ok(!panel.includes("20 consecutive failures"), "count-free: the live-config threshold never leaks into the banner copy");
    },
  },

  // ── D-06+D-07 Usage + Metrics in v4 (GR27/GR28): the metrics scenario existed
  // with ZERO smoke EXPECTATIONS (GR30) — these assert all three beat states plus
  // the dashed request-level stubs, and pin the GR28 warmup fiction OUT of every
  // state. mountMetricsTab re-acquires its swap box the mountUsageTab way
  // (`.metrics-body || panel`), so the grid lands in the OBSERVABLE
  // #instance-tabpanel here. (tail-append, OC9.) ──────────────────────────────
  metrics: {
    what: "the Metrics tab routes and fills all 4 live vitals + the dashed not-yet-metered stubs (no warmup fiction)",
    check(reg) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      for (const needle of ["inst-tabs", '/metrics" aria-current="page"', 'id="instance-tabpanel"', ">Metrics<"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.length > 0, "#instance-tabpanel metrics panel rendered empty");
      // GR27: all four vitals plot as cards (design showed only CPU/RAM).
      assert.ok(panel.includes('class="metrics-grid"'), "the vitals grid renders");
      for (const label of [">CPU<", ">Memory<", ">Disk<", ">Load<"]) {
        assert.ok(panel.includes(label), "the vitals grid renders " + JSON.stringify(label));
      }
      assert.ok(panel.includes("<svg"), "a live vital draws its sparkline");
      // D-07: the dashed request-level stubs, honestly not-yet-metered.
      assert.ok(panel.includes('class="metrics-stubs"'), "the request-level stubs render beneath the vitals");
      for (const label of [">Req/s<", ">p95 latency<", ">API requests<"]) {
        assert.ok(panel.includes(label), "the stub renders " + JSON.stringify(label));
      }
      assert.ok(panel.includes("Not yet metered"), "a stub reads Not yet metered, never a fake number");
      // The live beat banner reads Live (not the stale skin).
      assert.ok(panel.includes('class="metrics-fresh'), "the live beat renders the fresh banner");
      // GR28 kill list: the 24h-warmup fiction never crosses into the build.
      assert.ok(!/warming up|24h|24 h|of 24|unlock|collected/i.test(panel), "no warmup fiction in the live panel");
    },
  },
  "metrics-stale": {
    what: "the Metrics tab stale beat — last-known vitals flagged Agent offline, stubs still present",
    check(reg) {
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.includes('class="metrics-stale"'), "the stale banner renders");
      assert.ok(panel.includes("Agent offline"), "the stale banner reads Agent offline");
      assert.ok(panel.includes("last seen "), "the stale banner carries the last-seen age");
      // A stale read STILL shows the last-known series (history, not blank).
      assert.ok(panel.includes('class="metrics-grid"'), "the last-known vitals still render on a stale beat");
      assert.ok(panel.includes('class="metrics-stubs"'), "the stubs still render on a stale beat");
      assert.ok(!/warming up|24h|24 h|of 24|unlock|collected/i.test(panel), "no warmup fiction in the stale panel");
    },
  },
  "metrics-absent": {
    what: "the Metrics tab absent beat — the honest waiting panel, never a zeroed chart or a fake stub",
    check(reg) {
      const panel = (reg.get("instance-tabpanel") || {}).innerHTML || "";
      assert.ok(panel.includes("Waiting for the first beat"), "the absent state shows the honest waiting panel");
      assert.ok(!panel.includes('class="metrics-grid"'), "no zeroed vitals grid in the absent state");
      assert.ok(!panel.includes('class="metrics-stubs"'), "no request-level stubs in the absent state");
      assert.ok(panel.indexOf("<svg") === -1, "no fabricated chart in the absent state");
    },
  },
  // gr-p3-site-detail (E-02): the states-complete v4 ladder + previews + the
  // domains rungs painted by the SITE domain-status mount.
  "site-states": {
    what: "v4 site detail — every settled ladder state, trigger-only provenance, previews, domains rungs",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      // States-complete: live current / crash / blocked / cancelled pills.
      assert.ok(body.includes("dep-pill dep-live"), "live pill renders");
      assert.ok(body.includes("dep-pill dep-failed"), "failed pill renders");
      assert.ok(body.includes("dep-pill dep-cancelled"), "cancelled pill renders");
      assert.ok(body.includes("dep-current"), "the Now-live chip marks the current row");
      assert.ok(body.includes(">Roll back to this<"), "the prior live row offers rollback");
      // The v4 failure panels: crash red + blocked amber, dot included.
      assert.ok(body.includes("deploy-fail-dot"), "the failure panel carries its dot");
      assert.ok(body.includes("deploy-fail--blocked"), "the born-failed github push reads blocked amber");
      assert.ok(body.includes("npm run build exited 1"), "the crash reason renders verbatim");
      // GR27 provenance: trigger words only, never a named human.
      assert.ok(body.includes("Content update"), "content-auto renders as Content update");
      assert.ok(body.includes("Manual"), "manual renders as Manual");
      // Previews section: one live + one failed branch row.
      assert.ok(body.includes("Branch previews"), "the previews section renders");
      assert.ok(body.includes("preview-row"), "preview rows render");
      assert.ok(body.includes("draft/nav"), "the live preview names its branch");
      // The domains mount slot is in the detail markup…
      assert.ok(body.includes('id="site-domains"'), "the domains mount slot renders");
      // …and the SITE domain-status fetch painted the v4 rungs into it.
      const domains = (reg.get("site-domains") || {}).innerHTML || "";
      assert.ok(domains.includes("dom-card"), "the domain host card renders");
      assert.ok(domains.includes("acme.com"), "the apex host renders");
      assert.ok(domains.includes("dom-rung--proxied"), "the proxied rung renders informationally");
      assert.ok(domains.includes("dom-rung--active"), "the front in-flight rung shows honest motion");
      assert.ok(domains.includes("certificate usually issues"), "the server remediation renders verbatim");
    },
  },
  // ── ssw8 (charter D82): the content binding, PAINTED ────────────────────────
  // scenarios.mjs gained three binding fixtures; without an EXPECTATIONS entry
  // this harness never renders them (it iterates Object.keys(EXPECTATIONS), not
  // SCENARIOS), so they would be asserted only by the node string harness and
  // never by a boot. These three walk the real render into #site-body.
  "site-binding-bound": {
    what: "site detail — a bound site: the dataset triple on the rail and a read-token pill that promises only what content_bound means",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      assert.ok(body.includes("acme/site/production"), "the rail names the dataset triple the build reads");
      assert.ok(body.includes(">paper<"), "the bound content type renders");
      assert.ok(body.includes("status-pill--ok"), "a stored read token reads as an ok pill");
      assert.ok(body.includes(">Read token stored<"), "the pill says READ TOKEN…");
      assert.ok(!/has content|is bound</i.test(body),
        "…and never claims the site HAS content — content_bound is not_is_nil(read_token_encrypted)");
    },
  },
  "site-binding-unknown": {
    what: "site detail — an older control plane sends no triple and no content_bound; the rail says unknown, never a plausible default",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      assert.ok(body.includes(">Binding unknown<"), "an absent binding reads UNKNOWN");
      assert.ok(body.includes("status-pill--neutral"), "unknown is neutral — not a green, not a red");
      // THE lie this fixture exists to catch: nothing may invent the documented
      // defaults for a payload that carries none of them.
      assert.ok(!body.includes("default/default/production"),
        "an absent triple must never render the plausible default");
    },
  },
  "site-binding-mismatch": {
    what: "site detail — the payload's two spellings of the dataset disagree; both render and neither is resolved",
    check(reg) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      assert.ok(body.includes("producton") && body.includes("production"),
        "a self-contradictory payload shows BOTH spellings");
      assert.ok(body.includes(">Binding mismatch<"), "and names the contradiction");
      assert.ok(body.includes("status-pill--danger"), "a contradiction is a danger state, not a shrug");
    },
  },
  // gr-p3-small-surfaces (E-01): the global sites list on v4 — one density row
  // per site with a leading deploy-status pill, states-complete, real fields
  // ONLY (the invented Marketing/Docs/Blank "kind" taxonomy never renders).
  sites: {
    what: "v4 sites list — deploy-status pills (live/rebuilding/failed/never), real fields, no invented kinds",
    check(reg) {
      const body = (reg.get("sites-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#sites-body rendered empty");
      // Exactly one v4 global row per fixture site. cch-w16-s4 grew the corpus
      // from 5 to 6 (the first preview-only site); cch-w24-s7 grew it to 7 (the
      // cruel row — a 255-char single-token name on a 253-char host). Every
      // integer in this check is now ALSO pinned in FIXTURE_SHAPE_PINS, so the
      // next edit to sitesListRows is named before this check ever runs.
      assert.equal(countMatches(body, 'class="site-row site-row--global"'), 8,
        "one v4 density row per fixture site");
      // cch-w16-s4 — THE CONTRADICTION, ASSERTED PER ROW, NOT PER PAGE. A page
      // total can be satisfied by the wrong four rows; this splits the list on
      // its own row head and reads each row's own two claims.
      const rows = body.split('<div class="site-row').slice(1);
      assert.equal(rows.length, 8, "the split found every row");
      const undeployed = rows.filter((r) => r.includes(">Not deployed<"));
      assert.equal(undeployed.length, 2,
        "acme-labs (never deployed) and acme-previews (preview-only) both say so");
      for (const r of undeployed) {
        assert.ok(!r.includes("site-open"),
          "a row that says Not deployed offers NO door: " + (r.match(/site-name">([^<]*)/) || [])[1]);
      }
      const deployed = rows.filter((r) => !r.includes(">Not deployed<"));
      assert.equal(deployed.length, 6, "six rows have served a build");
      for (const r of deployed) {
        // …AND THE OTHER DIRECTION: rebuilding and deploy-failed rows are still
        // SERVING their previous build, so stripping their door would be the
        // same defect mirrored. This is the assertion `last_deployment.status
        // === "live"` would have failed.
        assert.ok(r.includes('class="site-open"'),
          "a site that has served a build KEEPS its door: " + (r.match(/site-name">([^<]*)/) || [])[1]);
      }
      assert.equal(countMatches(body, 'title="Open the live site"'), 6,
        "exactly six live-site doors on the page");
      // The leading status pill, states-complete across the four rows.
      assert.ok(body.includes("status-pill--ok"), "the live site reads an ok pill");
      assert.ok(body.includes("status-pill--warn"), "the rebuilding site reads a warn pill");
      assert.ok(body.includes("status-pill--danger"), "the deploy-failed site reads a danger pill");
      assert.ok(body.includes("status-pill--neutral"), "the never-deployed site reads a neutral pill");
      assert.ok(body.includes(">Not deployed<"), "a never-deployed site says so — no invented green");
      // cch-w14-s6: the cancelled freshness label #8608 shipped, rendered by a
      // harness for the first time — one spelling ("Cancelled", not "Canceled"),
      // on a neutral pill (a cancel is neither a success nor a failure).
      assert.ok(body.includes(">Cancelled<"), "a cancelled deploy says Cancelled — one spelling of the deploy noun");
      // cch-w64-s6: the deferred head row, rendered by a harness for the first
      // time. It reads AMBER and names who refused — not the neutral shrug the
      // generic else painted, which made a refused build look as calm as a
      // healthy one. Asserted on the ROW, because a page-level pill count is
      // already satisfied by the rebuilding site.
      const deferredRow = rows.filter((r) => r.includes(">acme-media<"))[0];
      assert.ok(deferredRow, "the deferred site renders a row");
      assert.ok(deferredRow.includes("status-pill--warn"),
        "a build the box REFUSED is amber, never the neutral pill it used to wear");
      assert.ok(deferredRow.includes(">Deferred by the box<"),
        "and it names WHO refused, echoing the shipped CLI phrase");
      assert.ok(!/will never build|minutes|shortly|soon/i.test(deferredRow),
        "no loss claim and no time promise rides in with it");
      assert.ok(!body.includes(">Canceled<"), "never the American spelling for the DEPLOY noun");
      // Real fields: the site's OWN name, its host, framework, the instance link,
      // and a recency segment.
      assert.ok(body.includes(">acme-web<"), "the site's real name renders");
      assert.ok(body.includes('class="site-host"'), "the live host renders on its own line");
      assert.ok(body.includes("acme.com"), "the host value renders");
      assert.ok(body.includes(">nextjs "), "the framework renders in the meta line");
      assert.ok(body.includes('class="site-inst-link" href="#instance/'), "on <instance> is a real workspace link");
      assert.ok(body.includes("updated "), "the recency segment renders");
      assert.ok(body.includes("Auto-deploy") && body.includes("Manual"),
        "the auto-deploy capability chip renders both states");
      // GR28 kill list: the invented site-kind taxonomy never crosses in.
      assert.ok(!/\bMarketing\b|\bDocs\b|\bBlank\b|template picker|site-kind/i.test(body),
        "no invented Marketing/Docs/Blank kind taxonomy in the sites list");
    },
  },
  // cch-w16-s4: the OTHER row builder. `siteRow` paints the instance
  // workspace's Sites card, and it has NO status pill at all for a
  // never-deployed site (freshnessBadge returns "") — so the contradiction was
  // SILENT here rather than spelled out, and an absence-only guard on an empty
  // fixture would have passed for the wrong reason. This drives the SAME six
  // rows through it and asserts BOTH directions.
  "sites-on-instance": {
    what: "instance Sites card — siteRow keeps the door on four served sites and removes it from the two that never served",
    check(reg) {
      const body = (reg.get("instance-sites") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-sites rendered empty");
      const rows = body.split('<div class="site-row').slice(1);
      assert.equal(rows.length, 8, "one instance row per fixture site");
      assert.equal(countMatches(body, 'class="site-open"'), 6,
        "six doors: the two that never served a build get none");
      // Named, so a fixture reshuffle cannot silently move the gate.
      const rowOf = (name) => rows.filter((r) => r.includes(">" + name + "<"))[0];
      for (const name of ["acme-labs", "acme-previews"]) {
        const r = rowOf(name);
        assert.ok(r, name + " renders a row");
        assert.ok(!r.includes("site-open"), name + " has never served a build — no door");
      }
      for (const name of ["acme.com", "blog.acme.com", "shop.acme.com", "guides.acme.com"]) {
        const r = rowOf(name);
        assert.ok(r, name + " renders a row");
        assert.ok(r.includes('class="site-open"'), name + " has served a build — the door stays");
      }
    },
  },
  // gr-p3-small-surfaces (E-03): the write-only env editor. The site detail
  // carries the Edit-environment affordance; the modal body (opened behind a
  // click, inert here) is pinned through the pure envModalBodyHtml hook.
  "env-editor": {
    what: "site detail Edit-env affordance + the write-only, blank-start modal (no scope UI, no redeploy claim)",
    check(reg, hooks) {
      const body = (reg.get("site-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#site-body rendered empty");
      // The rail affordance renders — an Edit action, NO stored values/count
      // (write-only: reveal_site_env has zero route callers).
      assert.ok(body.includes(">Environment<"), "the Environment rail row renders");
      assert.ok(body.includes('id="site-env-edit"'), "the Edit-environment affordance renders");
      // Drive the pure modal body — the same hook seam the 2FA card uses.
      assert.ok(hooks && typeof hooks.envModalBodyHtml === "function",
        "the env modal body must be exported through __bpTestHook");
      const modal = hooks.envModalBodyHtml({ name: "acme-web" });
      assert.ok(modal.includes("Edit environment"), "the modal titles itself");
      // The write-only law, verbatim.
      assert.ok(modal.includes("Saving replaces the whole set — values are write-only, so anything you leave out is removed."),
        "the replace-set / write-only law renders verbatim");
      assert.ok(modal.includes("Current values can’t be read back."), "the no-read-back law renders verbatim");
      // The textarea starts BLANK (GR28 — never pre-filled; no read-back).
      const ta = modal.match(/<textarea[^>]*id="site-env-text"[^>]*>([\s\S]*?)<\/textarea>/);
      assert.ok(ta, "the KEY=VALUE textarea renders");
      assert.equal(ta[1], "", "the textarea starts blank — there is no read-back to pre-fill");
      // Backend-true button copy: "Replace env", never "…and redeploy" (the
      // route queues no deployment).
      assert.ok(modal.includes(">Replace env</button>"), "the submit says Replace env");
      assert.ok(!/redeploy/i.test(modal), "no redeploy is claimed — the route queues none");
      // GR27: no production/preview scope UI (one blob).
      assert.ok(!/\bpreview\b|\bproduction scope\b|scope/i.test(modal), "no invented env scopes");
    },
  },
  // gr-p3-small-surfaces (I-01): the team Activity feed regrown on the shared
  // coalescing grammar with the by-target key + backend-true filter chips.
  activity: {
    what: "v4 activity — coalesced by target (×3 group, unrelated targets stay split), server-true target_type chips",
    check(reg) {
      const filters = (reg.get("activity-filters") || {}).innerHTML || "";
      // Backend-true filter chips: the two customer nouns + All. NO actor/verb
      // filter (the server has no such params).
      assert.ok(filters.includes('data-actfilter=""'), "the All chip renders");
      assert.ok(filters.includes('data-actfilter="barkpark"'), "the Instances chip maps to target_type=barkpark");
      assert.ok(filters.includes('data-actfilter="site"'), "the Sites chip maps to target_type=site");
      assert.ok(filters.includes("is-active"), "one chip is active (All by default)");
      const body = (reg.get("activity-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#activity-body rendered empty");
      // The feed renders through the SHARED grammar (tlv-* rows).
      assert.ok(body.includes("tlv-row"), "the feed renders through the shared timeline grammar");
      // The three same-site deploys fold into ONE ×3 coalesced group…
      assert.ok(body.includes("tlv-coalesce"), "the repeated same-target run coalesces");
      assert.ok(body.includes("&times; 3") || body.includes("× 3"), "the group states its count (×3)");
      assert.ok(body.includes("Show all 3"), "the group offers an expand affordance");
      // …but the DIFFERENT-target deploy (bob, acme-blog) is NOT folded in — a
      // team feed never merges unrelated targets. Exactly ONE coalesced group.
      assert.equal(countMatches(body, 'data-tlv-group="'), 1, "only the same-target run folds — unrelated targets stay split");
      // Actor display is backend-true (audit carries actor.email).
      assert.ok(body.includes("ada@acme.com"), "the actor email renders from the audit row");
      assert.ok(body.includes("bob@acme.com"), "the second actor's singleton renders separately");
      // The keyset Load-more control survives the regrow.
      assert.ok(reg.get("activity-more"), "the Load more control still mounts");

      // ── cch-w12-followup-smoke-who-axis-expectation: the Who axis, SEEN ──
      // cch-w12-s1 gave this fixture a members roster (ada/lin/rex) so the
      // actor axis could stop being structurally invisible here — but the
      // assertion was outside that slice's file fence, so until now nothing
      // read it. This boot IS the cold ordering the latch bug lived in:
      // applyRoute() deep-links #activity in the same synchronous turn as the
      // un-awaited loadMe() (meCache === null), and the roster lands only via
      // loadMe() calling back in — MEASURED, not assumed: re-introducing the
      // pre-fix bug (activityActorsTried = true hoisted above the team-id
      // guard) makes lin/rex vanish from this very innerHTML while all three
      // source-shape pins in __app.test.mjs are what they are. So this is a
      // live cold-boot-latch guard, not a decoration over the unit pins.
      const who = filters.split("Who</span>")[1] || "";
      assert.ok(who.length > 0, "the Who axis segment renders at all");
      assert.ok(who.includes('data-actfilter="usr_ada"') && who.includes(">Just me<"),
        "the caller renders as Just me (ada is the me() user)");
      assert.ok(who.includes('data-actfilter="usr_lin"') && who.includes(">lin<"),
        "the roster read landed: lin renders on the actor axis — if this reds, the cold-boot latch burned before the members fetch was issued");
      assert.ok(who.includes('data-actfilter="usr_rex"') && who.includes(">rex<"),
        "the roster read landed: rex renders on the actor axis");
    },
  },

  // ── gr-p4-billing (G-01): plain-member gate + the post-cancel grace state ────
  "billing-member": {
    what: "a plain member of a paid team — read-only plan, the owner-gate copy, and NO billing write button anywhere",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // The plan STATE reads honestly (the real plan name, and the features) …
      // cch-w49-s1 retired the ceiling pin that used to sit here: it called a
      // hand-typed client constant "the real quota-honest ceiling" inside the
      // required Console gate, which made this gate certify the fiction. The
      // member's screen issues no usage/summary call, so it states no ceiling.
      assert.ok(box.includes(">Supporter<"), "the member sees the real plan name");
      assert.ok(box.includes("Automated provisioning &amp; updates"), "the member sees the plan features");
      // … but with ZERO write affordances — never a disabled ghost (GR36).
      assert.ok(!/<button/i.test(box), "the read-only plan card renders NO button");
      assert.ok(!box.includes("plan-more") && !box.includes("plan-continue"), "no grid-toggle / subscribe CTA for a member");
      assert.equal(reg.get("billing-tiers").hidden, true, "the plan grid stays closed for a member");
      // The honest owner-gate copy is the member's single explanation.
      const manage = reg.get("billing-manage").innerHTML || "";
      assert.ok(manage.includes("Only the team owner can manage billing."), "the honest owner-gate copy renders");
      assert.ok(!/<button/i.test(manage), "the Manage section shows NO button for a member");
      // The pin that PROVES the member view has no billing write button: neither
      // section carries a Manage/Cancel action, and Cancel is retired entirely.
      assert.ok(!manage.includes(">Manage billing<"), "no Manage-billing button for a member");
      assert.equal(reg.get("billing-cancel-section").hidden, true, "no Cancel section for a member");
    },
  },
  // cch-w39-s1 — THE FAIL-BEFORE PIN. Every assertion below is FAULT-DEPENDENT:
  // it reds on origin/main's bytes, where billingIsOwner() answered false for an
  // unread /v1/me and the owner was handed the member surface verbatim.
  "billing-me-unreadable": {
    what: "an OWNER whose /v1/me 500s — billing REPORTS the failed check with a retry, and never accuses them of not being the owner",
    check(reg) {
      const manage = reg.get("billing-manage").innerHTML || "";
      // THE DEFECT, DRIVEN. On main this exact sentence is what an owner reads.
      assert.ok(!manage.includes("Only the team owner can manage billing."),
        "an unread /v1/me is not evidence that this person is not the owner; got: " + manage);
      assert.ok(manage.includes("We couldn't check your account"),
        "it says what actually happened; got: " + manage);
      // HONEST ABOUT THE FAULT CLASS: a 500 is ours, not the person's input —
      // and this string can only come from meFailureCopy() classifying the
      // RETAINED fault, so it cannot pass without the fault actually landing.
      assert.ok(manage.includes("broke on our side"), "a 5xx is reported as a 5xx; got: " + manage);
      assert.ok(manage.includes("data-me-retry"), "…and the unknown arm carries the shared retry the member surface never had");
      // NO CAUSE THE READ DID NOT RETURN (charter D438): /v1/me has no rate
      // limiter, and nothing here may invent a next step.
      assert.ok(!/rate limit|slow down|too many/i.test(manage), "no cause is named that the read did not return");
      assert.ok(!/check your (internet|connection)|ask (your|the) team owner/i.test(manage),
        "no newly authored next step");
      // FAIL-CLOSED: an unknown role gets ZERO billing write affordances. The
      // plan card is /v1/subscription's truth (role-free) and still renders, so
      // the person is not blinded to what they are paying for.
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.includes(">Supporter<"), "the real plan still renders — it was never a role claim");
      assert.ok(!/<button/i.test(box), "the plan region offers no write affordance while the role is unknown");
      assert.ok(!manage.includes(">Manage billing<"), "no portal button on an unproven role");
      assert.equal(reg.get("billing-cancel-section").hidden, true, "no Cancel section on an unproven role");
      assert.equal(reg.get("billing-tiers").hidden, true, "the plan grid stays closed while the role is unknown");
    },
  },
  // cchi-w39-bl-mefault-must-be-exhaustible — THE RECOVERY, DRIVEN. The
  // unreadable twin proves the shared retry RENDERS; this one proves it
  // RECOVERS: the one-shot fault (times: 1) fails the boot read, the shared
  // [data-me-retry] is clicked (fired count asserted — an unwired button would
  // otherwise be a dead pass), the re-read lands 200 owner, and the owner
  // affordances RETURN. Wire-asserted at both ends via ctx.countCalls.
  "billing-me-recovers": {
    what: "the owner's /v1/me 500s ONCE — clicking the shared retry re-reads, and Manage billing RETURNS",
    async check(reg, hooks, ctx) {
      const manageEl = reg.get("billing-manage");
      const before = manageEl.innerHTML || "";
      assert.ok(before.includes("We couldn't check your account"),
        "the boot read must fail first — without the unknown arm there is no recovery to measure; got: " + before);
      assert.ok(!before.includes(">Manage billing<"), "no portal button while the role is unknown");
      assert.equal(ctx.countCalls("GET", "/v1/me"), 1, "exactly one /v1/me read at boot");
      const btns = manageEl.querySelectorAll("[data-me-retry]");
      assert.equal(btns.length, 1, "the unknown arm mounts exactly one shared retry");
      const fired = btns[0].click();
      assert.ok(fired > 0, "[data-me-retry] dispatched " + fired + " handler(s) — the button is DEAD (wireMeRetry never ran)");
      await ctx.settle();
      assert.ok(ctx.countCalls("GET", "/v1/me") >= 2, "the retry never re-issued the /v1/me read");
      const after = manageEl.innerHTML || "";
      assert.ok(after.includes(">Manage billing<"),
        "the landed 200 owner did not restore Manage billing — the retry re-read but the surface never healed; got: " + after);
      assert.ok(!after.includes("We couldn't check your account"), "the failure copy retires once the read lands");
      assert.equal(reg.get("billing-cancel-section").hidden, false, "the Cancel section returns with the proven owner");
      assert.equal(reg.get("billing-manage-section").hidden, false, "the Manage section is shown for the proven owner");
    },
  },
  "billing-cancelling": {
    what: "owner after an in-app cancel — the grace 'Access until' + Ending badge, Cancel section retired, Manage billing kept",
    check(reg) {
      const box = reg.get("billing-recommended").innerHTML || "";
      assert.ok(box.length > 0, "#billing-recommended rendered empty");
      // The plan card reads the grace end honestly via billingPeriodLine.
      assert.ok(box.includes("Access until "), "a cancelling plan reads Access-until the period end");
      assert.ok(box.includes(">Ending<"), "the status badge reads Ending");
      // Manage billing stays available (resubscribe / portal) …
      assert.ok((reg.get("billing-manage").innerHTML || "").includes(">Manage billing<"), "Manage billing stays for the owner");
      assert.equal(reg.get("billing-manage-section").hidden, false, "the Manage section stays shown");
      // … but the Cancel section is GONE — a second cancel is a no-op.
      assert.equal(reg.get("billing-cancel-section").hidden, true, "the Cancel section retires once cancel_at_period_end is set");
    },
  },
  // ── gr-p4 G-02+G-03 Providers — the honesty flagship ───────────────────────
  // roster (kind + label + connected-at, no implied validity) + the hybrid
  // connect card + the 9-verb capability matrix (dev-tier filtered, server-owned
  // gap reasons, bare dash where the server owns no reason).
  "providers-connected": {
    what: "the roster (2 kinds, Disconnect…), the ROTATION state, the honest matrix — AND a real Disconnect click that arms the typed gate and shrinks the SERVER roster 2→1",
    async check(reg, hooks, ctx) {
      const roster = (reg.get("provider-roster") || {}).innerHTML || "";
      assert.ok(roster.includes("set-section"), "the roster rides the .set-* anatomy");
      assert.ok(roster.includes("prov-roster") && roster.includes("prov-row"), "roster rows render");
      assert.ok(roster.includes("Hetzner") && roster.includes("Azure"), "both connected kinds render");
      assert.ok(roster.includes("connected "), "each row shows a connected-at (never a validity badge)");
      assert.ok(!/\bConnected<\/span>/.test(roster), "the roster never implies live validity");
      assert.ok(roster.includes("data-prov-disconnect"), "an admin roster carries the typed-confirm Disconnect");

      // Both connectable providers are already connected → the connect card is in
      // the ROTATION state: a connected kind stays armable and its submit replaces
      // the stored credential in place (GR44 upsert on (team_id,kind), executed by
      // gr-bl-provider-reconnect-client-guard). It must NEVER tell the operator to
      // destroy a working credential first.
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(connect.includes("set-section") && connect.includes("Connect a provider"), "the connect card renders");
      assert.ok(connect.includes("data-connect-submit"), "a connected kind can still be re-submitted (rotation)");
      assert.ok(connect.includes("data-connect-rotating"), "the card says it is REPLACING the stored credential");
      assert.ok(connect.includes("Verify &amp; replace"), "the verb reads replace, not connect");
      assert.ok(!connect.includes("Disconnect one above"), "the destroy-first instruction is gone");
      assert.ok(!/data-connect-kind="[a-z]+"[^>]*disabled/.test(connect), "no connected kind is a disabled ghost");

      const matrix = (reg.get("provider-matrix") || {}).innerHTML || "";
      assert.ok(matrix.includes("cap-matrix"), "the capability matrix renders");
      for (const verb of ["core", "catalog", "archive", "resurrect", "decommission", "adopt", "audit", "pause", "labels"]) {
        assert.ok(matrix.includes(">" + verb + "<"), "the matrix rows verb " + JSON.stringify(verb));
      }
      assert.ok(matrix.includes("cap-mark"), "a supported cell shows an affirmative mark");
      assert.ok(matrix.includes("cap-dash"), "an unsupported cell shows a dash");
      assert.ok(matrix.includes("bills for as long as it exists"), "a false cell carries the server-owned gap reason verbatim");
      assert.ok(matrix.includes("Adopt needs an existing resource-group import"), "the azure adopt gap renders verbatim");
      // dev-tier `fake` is FILTERED — it is never a matrix column.
      assert.ok(!matrix.includes(">Fake<"), "the dev-tier provider is filtered out of the matrix");

      // ── cch-w10 LEG 1/5: DISCONNECT, CLICKED FOR REAL ─────────────────────
      // AMENDED IN PLACE, never forked (the cch-w2-revoke-ux-honesty precedent):
      // a parallel "providers-disconnect" scenario would duplicate the fixture
      // and leave two places to keep true. Everything above reads the FIRST
      // paint; everything below happens after it, on the same one boot — which
      // is also what keeps the handler count honest (a re-opened surface
      // accumulates handlers on the immortal #id registry nodes, so `fired == 1`
      // is only safe on a surface opened ONCE).
      //
      // Until this wave `[data-prov-disconnect]` resolved to [] — the wiring
      // loop ran over nothing, and a loop over nothing passes.
      const rosterEl = reg.get("provider-roster");
      const disconnects = rosterEl.querySelectorAll("[data-prov-disconnect]");
      assert.equal(disconnects.length, 2,
        "both roster rows must carry a wired Disconnect; got " + disconnects.length +
        " — if this is 0 the shim's attribute selector regressed and nothing below proves anything");
      const kind = disconnects[0].getAttribute("data-prov-kind");
      assert.equal(kind, "hetzner", "the first row is the Hetzner credential");
      assert.equal(disconnects[0].click(), 1,
        "the Disconnect button dispatched no click handler — it is DEAD");

      // The trigger opens the sheet and issues NOTHING.
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/providers/" + kind), 0,
        "Disconnect fired its DELETE straight off the row click — the typed-confirm gate is gone");
      assertDestroySheetDisarmed(reg, "Disconnect");

      // THE DISARM, PROVEN BY THE WIRE. The shim delivers clicks to disabled
      // elements (D56), so `fired` cannot see the gate; the request count can.
      assert.equal(reg.get("cm-confirm").click(), 1, "the sheet's Confirm must be wired for \"click\"");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/providers/" + kind), 0,
        "an UNARMED destroy Confirm put the DELETE on the wire — the typed echo is decorative");

      // THE ARM: type the kind, then confirm.
      armConfirmSheet(reg, kind).click();
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/providers/" + kind), 1,
        "the armed Confirm must issue exactly one DELETE");

      // THE SHRINK, read off the SERVER's own list — the assertion a stateless
      // fixture cannot pass, because it answers a byte-identical roster whether
      // or not the DELETE ever arrived (D39).
      assert.equal(ctx.state.providers.length, 1,
        "the server roster must shrink by exactly one (2 → 1); got " + ctx.state.providers.length);
      assert.ok(!ctx.state.providers.some((x) => x.kind === kind), "and the disconnected kind is the one gone");
      // …and the UI refetched, so the operator sees the truth rather than a
      // stale row they could click again.
      const repainted = reg.get("provider-roster").innerHTML || "";
      assert.ok(repainted.includes("Azure") && !repainted.includes("Hetzner"),
        "the roster must repaint from the refetch (Azure alone survives); got: " + repainted.slice(0, 200));
      const provToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(provToast.includes("Hetzner Cloud disconnected"),
        "a successful disconnect must say so; toast stack: " + provToast.slice(0, 200));

      // ── cch-w2-revoke-oracle-round2 · DELETE /v1/github/installation ───────
      // The GitHub App installation, the OTHER destroy verb on this screen and
      // the one no instrument had ever driven. Re-derive the handler, do not
      // trust a line number:
      //   grep -n "function disconnectGithub" cloud/priv/static/app.js
      // — one hit; it is wired in renderGithub by `$("#github-disconnect")`,
      // and githubCardHtml paints that button only `if (canWrite)`, which is
      // why this leg lives on the OWNER scenario and not on providers-member
      // (whose check deliberately asserts the card WITHOUT the control).
      //
      // NO CONFIRM GATE, deliberately not asserted as one: unlike the provider
      // disconnect above, disconnectGithub fires straight off the click. That
      // is the app's shape today; this oracle pins the WIRE, not a gate it does
      // not have, and inventing an assertion for a sheet that never opens would
      // be a claim about markup nothing renders.
      const ghCard = reg.get("github-card");
      // THE RENDER HALF, and it is load-bearing: this leg clicks the REGISTRY
      // node (renderGithub wires it through `$()`), and byId auto-creates an
      // entry for any id the app asks for — so without this line the click
      // would keep passing against a phantom on a screen that paints no
      // Disconnect at all. That is exactly what providers-connected did before
      // this fixture: `$("#github-disconnect")` was wired on every render while
      // the card showed "GitHub deploys aren't configured".
      const ghBefore = ghCard.innerHTML || "";
      assert.ok(ghBefore.includes('id="github-disconnect"'),
        "the connected+admin arm must paint the live #github-disconnect control; got: " + ghBefore.slice(0, 300));
      assert.ok(ghBefore.includes("acme-engineering") && ghBefore.includes("Connected"),
        "…and it must be the CONNECTED arm that painted it");
      assert.equal(ctx.countCalls("DELETE", "/v1/github/installation"), 0, "nothing was disconnected before the click");
      const ghReadsBefore = ctx.countCalls("GET", "/v1/github/installation");
      assert.ok(ghReadsBefore > 0, "the card was never fetched — this leg is asserting over a screen that never loaded");
      assert.equal(reg.get("github-disconnect").click(), 1,
        "the GitHub Disconnect dispatched no click handler — it is DEAD");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/github/installation"), 1,
        "exactly one DELETE /v1/github/installation must reach the wire; got " +
        ctx.countCalls("DELETE", "/v1/github/installation"));
      // THE STATE HALF. The success arm only calls loadGithub() — it refetches
      // and repaints, and against the old stateless fixture (which answered the
      // DELETE with {connected:false} and then served d.github, connected:true,
      // to the very next GET) the card came back CONNECTED and every assertion
      // below would have held whether or not the teardown did anything.
      assert.equal(ctx.state.github.connected, false,
        "the SERVER still reports the installation connected — the DELETE hit a fixture that cannot lose");
      assert.ok(ctx.countCalls("GET", "/v1/github/installation") > ghReadsBefore,
        "the success arm never refetched, so the operator is left looking at a card that outlived its installation");
      const ghAfter = ghCard.innerHTML || "";
      assert.ok(!ghAfter.includes("acme-engineering"),
        "the card still names the disconnected account; got: " + ghAfter.slice(0, 300));
      assert.ok(!ghAfter.includes('id="github-disconnect"'),
        "the card still offers Disconnect on an installation that is already gone");
      assert.ok(ghAfter.includes("Connect GitHub"),
        "a disconnected+configured deployment must offer the way back in, not a dead end; got: " + ghAfter.slice(0, 300));
      assert.ok(!ghAfter.includes("aren&#39;t configured"),
        "…and it must never answer a successful disconnect with a claim about the DEPLOYMENT's configuration");
      assert.ok((reg.get("toast-stack") || {}).innerHTML.includes("GitHub disconnected"),
        "the disconnect must report itself");
    },
  },
  "providers-empty": {
    what: "the empty roster + the connect card armed on the first provider; the matrix still renders",
    check(reg) {
      const roster = (reg.get("provider-roster") || {}).innerHTML || "";
      assert.ok(roster.includes("set-section"), "the empty roster still rides the anatomy");
      assert.ok(roster.includes("No providers connected yet"), "the honest empty note renders");
      assert.ok(!roster.includes("prov-row"), "no roster rows when nothing is connected");
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(connect.includes("data-connect-submit"), "the connect card is armed even with an empty roster");
      const matrix = (reg.get("provider-matrix") || {}).innerHTML || "";
      assert.ok(matrix.includes("cap-matrix"), "the matrix renders regardless of connected providers");
    },
  },
  "providers-unverified": {
    what: "the connect card's remediation slot + the server-owned remediation copy verbatim (node-pinned)",
    check(reg, hooks) {
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(connect.includes("cred-remediation"), "the connect card carries the remediation slot (filled on submit)");
      // The remediation is click-driven (submit → 422). Prove the honest path
      // node-pinned: the scenario's POST returns the single provider_unverified
      // + a remediation string, and remediationCopy() extracts it verbatim (never
      // routed through friendly(), which drops .remediation).
      const res = route("providers-unverified", "POST", "/v1/providers");
      assert.equal(res.status, 422, "connect preflight fails");
      assert.equal(res.body.error, "provider_unverified", "all causes collapse to one provider_unverified");
      const copy = hooks.remediationCopy(res.body);
      assert.ok(copy && copy.includes("Hetzner Cloud console"), "the server remediation names the exact console fix, verbatim");
      assert.equal(hooks.friendly(res.body, "fallback").indexOf(copy), -1, "friendly() provably drops the remediation");
    },
  },
  "providers-member": {
    what: "a plain member sees a read-only roster + matrix with ZERO write affordances",
    check(reg) {
      const roster = (reg.get("provider-roster") || {}).innerHTML || "";
      assert.ok(roster.includes("prov-row"), "the member still sees the roster (GET is member-readable)");
      assert.ok(!roster.includes("data-prov-disconnect"), "a member roster has NO Disconnect affordance");
      const connect = (reg.get("provider-connect") || {}).innerHTML || "";
      assert.ok(!connect.includes("data-connect-submit"), "a member sees NO connect card");
      assert.ok(!connect.includes("set-section"), "the connect region is empty for a member");
      const matrix = (reg.get("provider-matrix") || {}).innerHTML || "";
      assert.ok(matrix.includes("cap-matrix"), "the honest matrix still renders read-only for a member");
      // cch-w48-s6: the GitHub card, arm 1. Before this fixture every scenario
      // fell through to the /v1/ catch-all's `{}`, which renderGithub reads as
      // the NOT-CONFIGURED arm — so the connected arm had never been painted by
      // any instrument and nothing could be asserted about it, true or false.
      // WHAT IS DELIBERATELY NOT ASSERTED: `#github-disconnect`. That control is
      // cch-w48-s3's fence, and pinning its presence here would freeze today's
      // unfenced render into the baseline and force a second edit to delete it.
      const gh = (reg.get("github-card") || {}).innerHTML || "";
      assert.ok(gh.includes("acme-engineering"), "the connected account is named — the card reports WHICH GitHub account, never a bare 'connected'");
      assert.ok(gh.includes("Connected"), "the connected arm renders at all (arm 1 of renderGithub)");
      assert.ok(!gh.includes("Loading GitHub"), "an ANSWERED /v1/github/installation is not a loading state");
      assert.ok(!gh.includes("aren&#39;t configured"), "the fixture answers connected — the not-configured arm must NOT be what renders");
    },
  },
  // ── G-04 notifications (the crown): the settings-anatomy page ───────────────
  "notif-configured": {
    what: "the full notifications page — email + chat channels + routing matrix + delivery log, all backend-true; the per-channel Send test is WIRED through the document-level sweep",
    async check(reg, hooks, ctx) {
      const html = reg.get("notif-body").innerHTML || "";
      // GR33 anatomy: .set-section cards, each buffered section its own save-row;
      // the loose #notif-status span is GONE, and the superseded .notif-card too.
      assert.ok(html.includes("set-section"), "sections use the GR33 .set-section card");
      assert.ok(!html.includes('id="notif-status"'), "the loose #notif-status span is retired");
      assert.ok(!html.includes("notif-card"), "the superseded .notif-card is gone from this view");
      // Email section: transport seg (single-select) + its own save-row.
      assert.ok(html.includes("Email delivery") && html.includes("notif-transport-seg"), "email section with the transport seg");
      assert.ok(html.includes('id="notif-email-save"'), "email section owns its save-row button");
      // Channels roster: 6 channels (email transport + 5 chat), configured honesty,
      // consequence sub-lines, its own save-row.
      assert.ok(html.includes("Chat channels") && html.includes("set-channel"), "chat-channel roster renders");
      for (const label of ["Discord", "Slack", "Telegram", "Pushover", "Webhook"]) {
        assert.ok(html.includes(">" + label + " "), "roster lists " + label);
      }
      assert.ok(html.includes("configured"), "channels render their configured:bool truth");
      assert.ok(html.includes('id="notif-channels-save"'), "channels section owns its save-row");
      // Routing matrix: the event×channel grid on .set-toggle-weight cells + the
      // always-send test row (stated, never a lying toggle).
      assert.ok(html.includes("Event routing") && html.includes("set-matrix-grid"), "the routing matrix renders");
      assert.ok(html.includes("set-matrix-cell"), "matrix cells render as toggles");
      assert.ok(html.includes("Always sent to every enabled channel"), "the test row is stated as always-send, not a toggle");
      // Delivery log: the async sub-mount populated the rows in the webhook
      // grammar (mono recipient + toned status pill). GR79: the filter panel is a
      // REAL server round-trip now, so the section must SAY the filters search the
      // whole log (the old copy promised the last 50 and disowned filtering), and
      // both filter axes must render in the shared .actfilter-chip grammar.
      assert.ok(html.includes("Delivery log"), "the delivery-log section renders");
      assert.ok(html.includes("Filters run on the server"), "the section states that filtering is server-side");
      assert.ok(!html.includes("Filtering isn't available yet"), "the disowning sentence is gone");
      assert.ok(html.includes('data-notif-del-axis="channel"') && html.includes('data-notif-del-axis="status"'),
        "both chip axes render");
      assert.ok(html.includes('id="notif-del-event"'), "the free-text event filter renders (event is not a closed vocabulary)");
      assert.ok(html.includes("actfilter-chip is-active"), "each axis lights its own active chip");
      const log = (reg.get("notif-deliveries-body") || {}).innerHTML || "";
      assert.ok(log.includes("wh-del-row"), "the log renders rows in the webhook-deliveries grammar");
      assert.ok(log.includes("wh-del-status--danger"), "a failed delivery reads danger-toned");
      assert.ok(log.includes("Failed"), "a failure with no http_status reads 'Failed'");
      assert.ok(log.includes("204 OK"), "a chat delivery with an http_status reads its code");
      // THE WITHHOLD, REACHED. A `suppressed` fixture row alone reds nothing —
      // proved by adding it with these three lines absent (smoke exit 0, 111
      // scenarios, __app.test.mjs 1135/0). So the assertion, not the fixture, is
      // the guard: it pins the two things the old code got exactly backwards.
      assert.ok(log.includes("wh-del-status--muted"), "a withheld delivery reads muted-toned — never info, which paints a thrown-away alert as in flight");
      assert.ok(log.includes("Withheld"), "the withheld pill reads 'Withheld' — never 'Pending', the inverse of what happened");
      assert.ok(!/wh-del-status--info[^"]*">\s*Pending\s*<\/span>[\s\S]{0,400}?too many deployment alerts/.test(log),
        "no suppressed row renders through the pending pill");
      assert.ok(log.includes("too many deployment alerts in one sweep"), "the withhold REASON is on the row, so the admin reads the decision and not just its name");

      // ── cch-bl-smoke-document-attr-selectors-still-dead: THE DOCUMENT LOOP,
      // CLICKED. wireNotifSettings attaches the per-channel Send-test handler
      // through document.querySelectorAll("[data-notif-chan-test]") — a loop
      // that ran over [] for the whole life of this harness, so every one of
      // these buttons was rendered DEAD. This is the assertion that makes the
      // document-level sweep falsifiable: the button is FOUND element-level
      // (notif-body's kids — a path that works either way), but it was WIRED
      // document-level, so reverting the sweep to `return []` reds exactly
      // here (mutation-verified). Amended in place, never forked (the
      // cch-w2-revoke-ux-honesty precedent).
      const chanTests = reg.get("notif-body").querySelectorAll("[data-notif-chan-test]");
      assert.equal(chanTests.length, 3,
        "one Send test per ENABLED+CONFIGURED channel (discord, slack, webhook; telegram is disabled, pushover " +
        "unconfigured); got " + chanTests.length +
        " — if 0, the element-level attribute selector regressed and nothing below proves anything");
      const chanType = chanTests[0].getAttribute("data-notif-chan-test");
      assert.equal(chanType, "discord", "the first configured channel is discord");
      assert.equal(chanTests[0].click(), 1,
        "the Send-test button dispatched no click handler — the document-level wiring loop is DEAD again");
      await ctx.settle();
      assert.equal(ctx.countCalls("POST", "/v1/notifications/test"), 1,
        "the wired handler must put exactly one test POST on the wire");
      const chanToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(chanToast.includes("Test queued") && chanToast.includes("Sent to " + chanType),
        "the 202 renders the honest per-channel toast; toast stack: " + chanToast.slice(0, 200));
    },
  },
  "notif-empty": {
    what: "first-run notifications — no channels configured, empty delivery log, honest defaults",
    check(reg) {
      const html = reg.get("notif-body").innerHTML || "";
      assert.ok(html.includes("Email delivery") && html.includes("Event routing"), "the page still composes all sections");
      assert.ok(html.includes("not configured"), "an untouched channel reads not-configured");
      const log = (reg.get("notif-deliveries-body") || {}).innerHTML || "";
      assert.ok(log.includes("No notifications have been delivered yet"), "the empty log states the honest empty case");
    },
  },
  "notif-member": {
    what: "plain-member notifications — read-only email, ZERO save-rows, no admin sections, no test button",
    check(reg) {
      const html = reg.get("notif-body").innerHTML || "";
      assert.ok(html.includes("set-readonly"), "the member sees read-only email settings");
      assert.ok(html.includes("managed by team admins"), "the admin-only sections degrade to an honest line");
      // The plain-member proof: no write affordances anywhere.
      assert.ok(!html.includes("set-save-row"), "member view has NO save-rows");
      assert.ok(!html.includes("notif-email-save"), "member view has NO save buttons");
      assert.ok(!html.includes("set-matrix-grid"), "member view has NO routing matrix");
      assert.ok(!html.includes("set-channel-creds"), "member view has NO credential inputs");
      assert.equal(reg.get("notif-test").hidden, true, "the header Send-test button is hidden for a member");
    },
  },
  "notif-deliveries-error": {
    what: "the deliveries route errors — the delivery log degrades honestly, the rest of the page survives",
    check(reg) {
      const html = reg.get("notif-body").innerHTML || "";
      assert.ok(html.includes("Event routing"), "the admin page still renders when deliveries fail");
      const log = (reg.get("notif-deliveries-body") || {}).innerHTML || "";
      assert.ok(log.includes("Couldn't load the delivery log"), "the log shows the honest error-degrade, never an infinite spinner");
    },
  },
  // ── G-05 API tokens (GR34) ──────────────────────────────────────────────────
  "tokens-populated": {
    what: "the token list — one lean row per PAT, ability chips + created/expiry, per-row Revoke, revoked row flagged",
    check(reg, hooks) {
      const html = reg.get("token-list").innerHTML || "";
      // Exactly one .token-row per fixture token (4), the revoked one flagged.
      assert.equal(countMatches(html, 'class="token-row'), 4, "one lean row per token");
      assert.ok(html.includes("is-revoked"), "the revoked token row is dimmed via is-revoked");
      for (const name of ["CI deploy key", "Read-only dashboard", "Break-glass root", "Legacy writer"])
        assert.ok(html.includes(name), "the row names the token: " + name);
      // Real pat_json fields only — chips + created(inserted_at)/expiry/last-used.
      assert.ok(html.includes("token-chip"), "abilities render as chips");
      assert.ok(html.includes("created "), "created (inserted_at) renders");
      assert.ok(html.includes("never used"), "a never-used token says so");
      assert.ok(html.includes("no expiry"), "a no-expiry token says so");
      assert.ok(html.includes(">Revoke<"), "an active row offers Revoke");
      assert.ok(html.includes("Revoked"), "the revoked row shows the Revoked badge");
      // NO faked prefix/preview — pat_json carries none; the list never invents one.
      assert.ok(!html.includes("bpc_pat_"), "the list never shows a token prefix/plaintext");
      // Owner picker: all four abilities as .set-check rows with consequence sub-lines.
      const picker = hooks.tokenAbilitiesFieldHtml();
      assert.equal(countMatches(picker, 'class="token-ab"'), 4, "owner sees all four ability checkboxes");
      for (const v of ["read", "write", "deploy", "root"])
        assert.ok(picker.includes('value="' + v + '"'), "owner can pick " + v);
      assert.ok(picker.includes("set-check-sub"), "each ability carries its consequence sub-line");
      assert.ok(picker.includes("exclusive"), "the deploy/root exclusivity consequence is stated");
    },
  },
  // ── cch-w11-s3-token-revoke-shrink-oracle: THE LAST LYING DESTROY VERB ─────
  // Every other tokens expectation reads markup. This one WATCHES THE APP DO
  // SOMETHING: it clicks a row's Revoke, then the confirm sheet's Revoke, and
  // reads whether the list the console refetches actually MOVED.
  //
  // WHAT WAS MEASURED BEFORE THE FIX (selector widened, route untouched):
  //   DELETE-calls=1 GET-calls=2 rows-after=4 victim-still-listed=true
  // A real DELETE on the wire, a real refetch — and a token list byte-identical
  // to the one before it, while the console toasts "Token revoked". Both halves
  // are load-bearing and NEITHER works alone (mutation-proven):
  //   • revert COMPOUND_SEL ⇒ `.token-revoke[data-id]` resolves [], nothing is
  //     wired, and the row's click dispatches 0 handlers — the button is dead;
  //   • revert the route ⇒ every assertion up to and including the DELETE count
  //     still passes and the list still reads 4 rows with the victim present.
  //
  // THE UNDOCUMENTED TRAP — CLICKS AND ASSERTIONS ANCHOR ON DIFFERENT OBJECTS.
  // This file's header (D55) says to anchor ASSERTIONS on #modal-body's
  // innerHTML, because the descendant registry node is immortal here. The
  // INVERSE rule governs CLICKS and was written nowhere: the confirm button must
  // be clicked through the #id REGISTRY (`reg.get("token-revoke-go")`), because
  // confirmRevokeToken() wires it with `$("#token-revoke-go")` → getElementById →
  // the registry object, while the button parsed out of #modal-body's innerHTML
  // is a DIFFERENT object carrying ZERO handlers. Click the parsed child and it
  // returns 0 and reads as a dead button that is in fact perfectly wired.
  //
  // NO TYPED-CONFIRM DRIVER, deliberately: confirmRevokeToken() — `grep -n
  // 'function confirmRevokeToken' cloud/priv/static/app.js` for both claims —
  // opens a PLAIN openModal with a bare `<button id="token-revoke-go">`, not
  // openConfirmModal, so there is no #cm-confirm, no #cm-typed and nothing to
  // arm. armConfirmSheet/assertDestroySheetDisarmed do not apply to this leg.
  "tokens-revoke": {
    what: "THE TOKEN REVOKE ORACLE — a real click revokes: confirm sheet, exactly one DELETE on the wire, and the refetched list SHRINKS 4 → 3 with the victim gone",
    async check(reg, hooks, ctx) {
      // ─ 1. the list rendered through the REAL loadTokens ────────────────────
      const box = reg.get("token-list");
      const rendered = box.innerHTML || "";
      assert.equal(countMatches(rendered, 'class="token-row'), 4, "the fixture's four tokens render");
      assert.equal(ctx.countCalls("GET", "/v1/tokens"), 1, "the list was fetched once on view entry");

      // ─ 2. the per-row Revoke is REACHABLE and WIRED ────────────────────────
      // This is the compound-selector half: app.js wires the rows with
      // `box.querySelectorAll(".token-revoke[data-id]")`, which answered [] for
      // this shim's whole existence — so the loop wired nothing and a loop over
      // nothing is a clean pass.
      const revokes = box.querySelectorAll(".token-revoke[data-id]");
      assert.equal(revokes.length, 3, "three revokable rows — the already-revoked token offers no Revoke");
      const victim = revokes[0].getAttribute("data-id");
      assert.equal(victim, "tok_rv_ci", "the first revokable row must carry its real data-id");
      const fired = revokes[0].click();
      assert.equal(fired, 1,
        "the per-row Revoke dispatched " + fired + " click handlers — the button is DEAD. " +
        "The markup can be present and correct while nothing is bound to \"click\".");

      // ─ 3. the confirm sheet mounts and NOTHING has happened yet ────────────
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes('id="token-revoke-go"'),
        "the revoke confirm sheet did not mount into #modal-body; got: " + JSON.stringify(sheet.slice(0, 200)));
      assert.ok(sheet.includes("Revoke token?") && sheet.includes("CI deploy key"),
        "the sheet must name what it is about to revoke");
      assert.ok(sheet.includes("btn-danger"), "GR41: a destructive confirm wears the danger tier's weight");
      assert.equal(ctx.countCalls("DELETE", "/v1/tokens/" + victim), 0,
        "the row click fired the DELETE before the operator confirmed — the confirm gate is gone");

      // ─ 4. CONFIRM VIA THE REGISTRY (see the trap in the header above) ──────
      const go = reg.get("token-revoke-go");
      assert.equal(go.click(), 1, "the sheet's Revoke must be wired for \"click\"");
      assert.equal(go.disabled, true, "the confirm button must go disabled while its DELETE is in flight");
      assert.equal(go.textContent, "Revoking…",
        "the label must confess the in-flight state, got " + JSON.stringify(go.textContent));
      await ctx.settle();

      // ─ 5. THE WIRE ────────────────────────────────────────────────────────
      assert.equal(ctx.countCalls("DELETE", "/v1/tokens/" + victim), 1,
        "exactly one DELETE for that token's id must reach the wire");
      const toasts = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(toasts.includes("Token revoked"), "a successful revoke must SAY SO; toast stack: " + toasts);

      // ─ 6. THE LIE, CLOSED: the refetched list must actually MOVE ───────────
      // Against the old flat `{status:200, body:{ok:true}}` DELETE and the old
      // direct `d.tokens` GET, every assertion above passed and this one did
      // not — the console reported success over an unchanged list.
      assert.equal(ctx.countCalls("GET", "/v1/tokens"), 2, "the success arm refetches the list");
      const after = reg.get("token-list").innerHTML || "";
      assert.equal(countMatches(after, 'class="token-row'), 3,
        "the revoked token must be GONE on the re-render (4 → 3); an unchanged list means the DELETE did nothing");
      assert.ok(!after.includes('data-id="' + victim + '"'),
        "the revoked token's row came back — the console is reporting success over a list that never moved");
      assert.ok(after.includes("Read-only dashboard") && after.includes("Legacy writer"),
        "only the victim may disappear — the other rows must survive the refetch");
    },
  },
  "tokens-empty": {
    what: "the empty state — no tokens yet, Create-token CTA",
    container: "token-list",
    includes: ["No API tokens yet", "empty-state", "Create token"],
    excludes: ['class="token-row'],
  },
  "tokens-member": {
    what: "plain-member picker — read-only scope stated up-front, no write/deploy/root pickers (anti-ghost)",
    check(reg, hooks) {
      // The list still renders the member's own read token.
      const list = reg.get("token-list").innerHTML || "";
      assert.ok(list.includes("My read token"), "the member sees their own token");
      // cch-w36-s3 — THIS EXPECTATION USED TO PASS FOR THE WRONG REASON, and
      // stayed green through the entire defect. The picker is gated on
      // canMintAnyAbility(), a TWO-valued read of a THREE-valued fact: with
      // /v1/me unanswered or FAILED it returns false, so an OWNER whose /v1/me
      // answered 500 received this very picker — byte-identical, 434 bytes —
      // and the four assertions below passed against it VERBATIM, 4/4. The
      // member sentence may only be asserted against a CONFIRMED member, so
      // the state is pinned FIRST: a role we do not know is not a role of
      // member, and this scenario's /v1/me answers 200 with role:"member".
      assert.equal(hooks.meState(), "loaded",
        "the member picker may only be asserted against a CONFIRMED /v1/me answer — an owner-after-500 renders the unknown arm, and this assertion is what tells them apart");
      assert.equal(hooks.meFlags().role, "member",
        "and the confirmed answer must actually say member; got " + JSON.stringify(hooks.meFlags()));
      // The picker (gated on meCache.role) offers read-only scope — NO checkboxes
      // for write/deploy/root, plus the honest ask-an-admin copy.
      const picker = hooks.tokenAbilitiesFieldHtml();
      assert.ok(picker.indexOf("token-scope-unknown") === -1,
        "a CONFIRMED member must get the member picker, never the unknown-role arm");
      assert.ok(picker.includes("set-check--scope"), "read scope is stated, not a pickable ghost");
      assert.ok(picker.includes("Members can create read-only tokens"), "honest copy names the cap");
      assert.ok(!picker.includes('class="token-ab"'), "no ability checkboxes are rendered for a member");
      assert.ok(
        !picker.includes('value="write"') && !picker.includes('value="deploy"') && !picker.includes('value="root"'),
        "write/deploy/root are not offered to a member",
      );
    },
  },
  "tokens-reveal": {
    what: "the plaintext-once reveal — amber only-time banner + the mono token on its own wrapping line (copy + show/hide), with the input-affix demoted to an off-screen copy buffer",
    check(reg, hooks) {
      const html = hooks.tokenRevealHtml("bpc_pat_3xampLEon1yShoWnoNCE", { name: "CI deploy key", abilities: ["deploy"] });
      assert.ok(html.includes("notice notice-warn"), "the amber only-time banner frames the reveal");
      assert.ok(html.toLowerCase().includes("only time"), "the banner says this is the only time");
      assert.ok(html.includes("input-affix"), "the plaintext sits in an input-affix row");
      assert.ok(html.includes("token-reveal-input"), "the value renders mono");
      assert.ok(html.includes("bpc_pat_3xampLEon1yShoWnoNCE"), "the plaintext is shown once");
      assert.ok(html.includes(">Copy<"), "a copy button is offered");
      assert.ok(html.includes("token-eye"), "a show/hide toggle is offered");
    },
  },
  // ── G-06 Members + env-vars (Settings wave, phase 4) ──────────────────────
  // The roster on the GR33 .set-* anatomy: view-members visible, both cards, the
  // 3-role chips, per-manageable-row Change role + Remove, the "(you)" self-tag.
  // cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts — the roster at the
  // 160-char email cap. Every needle DERIVES from the fixture, so a fixture
  // that goes kind cannot leave this check asserting a shorter string.
  "members-cruel-content": {
    what: "Members — the 160-char cruel email renders WHOLE in its row (identity recoverable at the DOM), roster grown by concat to 4 rows",
    check(reg) {
      const cruel = SCENARIOS["members-cruel-content"].data.members.find((m) => m.email.length >= 100);
      assert.ok(cruel, "the cruel roster fixture lost its at-cap member — GONE KIND, nothing cruel is being asserted");
      assert.equal(cruel.email.length, 160, "the cruel email must sit AT the user.ex validate_email cap (160), not near it");
      const body = reg.get("members-body").innerHTML || "";
      // THE NAME DIV, not any attribute: the full address also rides the
      // Change-role/Remove buttons' data-email attributes, so a bare
      // body.includes(email) is satisfiable by markup a person cannot read —
      // measured: truncating the name render to 40 chars left that weaker
      // needle GREEN. The needle below pins the text node a person sees.
      assert.ok(body.includes('set-row-name">' + cruel.email + "<"),
        "the 160-char email must render WHOLE as the row's visible name — CSS may clip it, the DOM must carry it");
      const rows = SCENARIOS["members-cruel-content"].data.members.length;
      assert.equal(rows, 4, "the roster is teamMembers.concat(one cruel member) — the three committed rows stay byte-for-byte unmoved");
      for (const m of SCENARIOS["members-cruel-content"].data.members) {
        assert.ok(body.includes(m.email), "every roster row renders, including " + m.email.slice(0, 24) + "…");
      }
      assert.ok(body.includes(">Change role<") && body.includes(">Remove<"), "the owner actor still gets manage affordances beside the cruel row");
    },
  },
  "members-populated": {
    what: "Members (admin) — roster + invitations, 3 real roles — AND real clicks: Remove shrinks the SERVER roster 3→2, Revoke shrinks invitations 2→1",
    async check(reg, hooks, ctx) {
      assert.equal(reg.get("view-members").hidden, false, "the Members view must be visible");
      const body = reg.get("members-body").innerHTML || "";
      assert.ok(body.includes("set-section"), "the roster rides the .set-section anatomy");
      assert.ok(body.includes("Team members"), "the roster card heading renders");
      assert.ok(body.includes("Pending invitations"), "the admin-only invitations card renders");
      assert.ok(body.includes("ada@acme.com") && body.includes("lin@acme.com") && body.includes("rex@acme.com"), "every member row renders");
      assert.ok(body.includes("(you)"), "the acting owner is self-tagged and gets no self-remove");
      assert.ok(body.includes("sky@partner.io"), "a pending invitation renders");
      // THREE roles only — the chips read Owner/Admin/Member; NO invented tiers.
      assert.ok(body.includes(">Owner<") && body.includes(">Admin<") && body.includes(">Member<"), "the 3 real role chips render");
      assert.ok(!body.includes("Operator") && !body.includes("Supporter"), "no design-fiction 5-role vocabulary is rendered");
      // Manage affordances present for the admin; Remove is the destroy path.
      assert.ok(body.includes(">Change role<") && body.includes(">Remove<"), "manager rows carry Change role + Remove");

      // ── cch-w45-s2, PROVED IN THE LIVE DOM AND NOT ONLY IN THE UNIT ────────
      // This scenario IS the sole-owner case: ada is the only owner AND the
      // acting principal, so every in-range self role change is a demotion
      // do_update_role rolls back with :last_owner (409). The unit tests pin the
      // predicate; this pins that the RENDERED panel a person actually sees
      // withheld the control — and that the omission is EXPLAINED rather than
      // silently missing. `>Change role<` above stays true from the two peers,
      // which is exactly why a substring check could never have seen this.
      {
        const roleBtns = reg.get("members-body").querySelectorAll("[data-member-role]");
        const roleEmails = roleBtns.map((b) => b.getAttribute("data-email")).sort();
        assert.deepEqual(roleEmails, ["lin@acme.com", "rex@acme.com"],
          "the SOLE owner's own row must not offer a role change the server 409s — offered on " +
          JSON.stringify(roleEmails));
        assert.ok(body.includes("only owner") && body.includes("promote another member to owner first"),
          "a withheld control with no sentence is a silently missing control; got: " + body.slice(0, 400));
      }

      // ── cch-w10 LEG 2/5: REMOVE MEMBER, CLICKED FOR REAL ──────────────────
      // The path carries the team id, which this check has no business
      // hard-coding — so the wire assertion matches the SHAPE and reads the id
      // the app actually used.
      const wire = (method, re) => ctx.calls.filter((c) => c.method === method && re.test(c.path)).length;
      const panel = reg.get("members-body");
      const removes = panel.querySelectorAll("[data-member-remove]");
      assert.equal(removes.length, 2,
        "the two manageable rows carry a wired Remove (the acting owner never self-removes); got " + removes.length);
      const victimId = removes[0].getAttribute("data-member-remove");
      const victimEmail = removes[0].getAttribute("data-email");
      assert.ok(victimId && victimEmail, "the Remove button must carry both the user id and the email it types against");
      assert.equal(removes[0].click(), 1, "the Remove button dispatched no click handler — it is DEAD");
      await ctx.settle();
      const memberRe = new RegExp("^/v1/teams/[^/]+/members/" + victimId + "$");
      assert.equal(wire("DELETE", memberRe), 0, "Remove must open the typed sheet, never fire on the row click");
      assertDestroySheetDisarmed(reg, "Remove member");
      reg.get("cm-confirm").click();
      await ctx.settle();
      assert.equal(wire("DELETE", memberRe), 0, "an UNARMED destroy Confirm removed a member");
      // The typed echo is the EMAIL for this verb (resourceName), not the id.
      armConfirmSheet(reg, victimEmail).click();
      await ctx.settle();
      assert.equal(wire("DELETE", memberRe), 1, "the armed Confirm must issue exactly one member DELETE");
      assert.equal(ctx.state.members.length, 2,
        "the server roster must shrink by exactly one (3 → 2); got " + ctx.state.members.length);
      assert.ok(!ctx.state.members.some((m) => m.user_id === victimId), "and the removed member is the one gone");
      const afterRemove = reg.get("members-body").innerHTML || "";
      assert.ok(!afterRemove.includes(victimEmail),
        "the roster must repaint without the removed member; got: " + afterRemove.slice(0, 200));

      // ── cch-w10 LEG 3/5: REVOKE INVITATION, CLICKED FOR REAL ──────────────
      // A DIFFERENT sheet shape on purpose: revoking a pending invite is a plain
      // openModal with its own #invite-revoke-go, not the typed destroy tier —
      // one template would not have driven both, and pretending otherwise is how
      // an oracle ends up asserting a sheet that isn't there.
      const invites = reg.get("members-body").querySelectorAll("[data-invite-revoke]");
      assert.equal(invites.length, 2, "both pending invitations carry a wired Revoke; got " + invites.length);
      const invId = invites[0].getAttribute("data-invite-revoke");
      const invEmail = invites[0].getAttribute("data-email");
      assert.equal(invites[0].click(), 1, "the invitation Revoke dispatched no click handler — it is DEAD");
      const invRe = new RegExp("^/v1/teams/[^/]+/invitations/" + invId + "$");
      assert.equal(wire("DELETE", invRe), 0, "the row click must only open the confirm sheet");
      const invSheet = reg.get("modal-body").innerHTML || "";
      assert.ok(invSheet.includes("Revoke invitation?") && invSheet.includes(invEmail),
        "the sheet must name the invitation it is about to kill; got: " + invSheet.slice(0, 200));
      const go = reg.get("invite-revoke-go");
      assert.equal(go.click(), 1, "the sheet's Revoke must be wired for \"click\"");
      assert.equal(go.disabled, true, "the in-flight Revoke must disable itself against a double-fire");
      await ctx.settle();
      assert.equal(wire("DELETE", invRe), 1, "exactly one invitation DELETE on the wire");
      assert.equal(ctx.state.invitations.length, 1,
        "the server invitation list must shrink by exactly one (2 → 1); got " + ctx.state.invitations.length);
      const afterRevoke = reg.get("members-body").innerHTML || "";
      assert.ok(!afterRevoke.includes(invEmail) && afterRevoke.includes("max@acme.com"),
        "the panel must repaint with only the surviving invitation; got: " + afterRevoke.slice(0, 200));
    },
  },
  // The plain-member seam (GR33 plain-member law): read-only roster, no
  // invitations card, no manage affordances — proven by their ABSENCE.
  "members-member": {
    what: "Members (member) — read-only roster, zero manage affordances",
    check(reg) {
      assert.equal(reg.get("view-members").hidden, false, "the Members view must be visible");
      const body = reg.get("members-body").innerHTML || "";
      assert.ok(body.includes("Team members") && body.includes("rex@acme.com"), "the roster still renders for a member");
      assert.ok(!body.includes("Pending invitations"), "a member sees no invitations card");
      assert.ok(!body.includes(">Change role<") && !body.includes(">Remove<"), "a member sees no manage affordances");
      // The header Invite button stays hidden for a plain member.
      assert.equal(reg.get("members-invite").hidden, true, "the Invite button is hidden for a member");
    },
  },
  // cch-w45-s1: the acting ADMIN who is NOT row 0 of the roster. Asserted BY ROW
  // — the set of emails each control is offered on — never by a substring of the
  // panel, because "the panel contains >Change role<" is true of any roster with
  // one manageable row and would go green with the owner's row over-offered.
  // Both member buttons carry data-email, so the offered set is readable exactly.
  "members-admin-actor": {
    what: "Members (admin actor lin, not the owner) — ada's row offers NOTHING, lin's own row only Change role, rex's row both",
    check(reg) {
      assert.equal(reg.get("view-members").hidden, false, "the Members view must be visible");
      const panel = reg.get("members-body");
      const body = panel.innerHTML || "";
      // IDENTITY, not rank: the acting principal is lin, and the whole envelope
      // moved with the id — a corpus that shipped ada's email under lin's id
      // would tag the wrong row "(you)" and every predicate below would be a
      // coincidence.
      assert.ok(body.includes("lin@acme.com <span class=\"dim\">(you)</span>"),
        "lin's row must be the self row — the actor identity, not just the actor rank; got: " + body.slice(0, 400));
      assert.ok(!body.includes("ada@acme.com <span class=\"dim\">(you)</span>"),
        "ada must NOT be self-tagged when the acting principal is lin");
      const emailsFor = (attr) =>
        panel.querySelectorAll("[" + attr + "]").map((b) => b.getAttribute("data-email")).sort();
      const roleOffers = emailsFor("data-member-role");
      const removeOffers = emailsFor("data-member-remove");
      // ada OUTRANKS the acting admin: the server 403s `outranked` on both verbs,
      // so neither control may be painted on her row.
      assert.ok(!roleOffers.includes("ada@acme.com"),
        "an acting ADMIN was offered Change role on the team OWNER's row — the server 403s outranked; offered on " + JSON.stringify(roleOffers));
      assert.ok(!removeOffers.includes("ada@acme.com"),
        "an acting ADMIN was offered Remove on the team OWNER's row — the server 403s outranked; offered on " + JSON.stringify(removeOffers));
      // The exact sets, so an over-offer ANYWHERE reds and names the row.
      assert.deepEqual(roleOffers, ["lin@acme.com", "rex@acme.com"],
        "Change role belongs on the self row (self-demotion is legal) and the outranked member — got " + JSON.stringify(roleOffers));
      assert.deepEqual(removeOffers, ["rex@acme.com"],
        "Remove belongs ONLY on the outranked member's row — got " + JSON.stringify(removeOffers));
      // An admin still manages: the invitations card is there, so the absences
      // above are RANK refusals and not a plain-member panel by accident.
      assert.ok(body.includes("Pending invitations"), "an acting admin still sees the invitations card");
    },
  },
  // cch-w45-s1: the acting OWNER on a roster with a PEER OWNER — the one cell
  // where the server's two member verbs disagree (remove_member_as/3 has an
  // owner escape hatch, update_member_role_as/4 does not).
  "members-peer-owner": {
    what: "Members (owner) — the PEER OWNER row carries Remove and NOT Change role; the two server verbs disagree",
    check(reg) {
      assert.equal(reg.get("view-members").hidden, false, "the Members view must be visible");
      const panel = reg.get("members-body");
      const body = panel.innerHTML || "";
      assert.ok(body.includes("ozz@acme.com"), "the peer owner renders on the roster");
      assert.ok(body.includes("ada@acme.com <span class=\"dim\">(you)</span>"),
        "the acting owner is still ada — this scenario moves the ROSTER, never the default actor");
      const emailsFor = (attr) =>
        panel.querySelectorAll("[" + attr + "]").map((b) => b.getAttribute("data-email")).sort();
      const roleOffers = emailsFor("data-member-role");
      const removeOffers = emailsFor("data-member-remove");
      assert.ok(!roleOffers.includes("ozz@acme.com"),
        "an owner was offered Change role on a PEER OWNER's row — update_member_role_as/4 has no owner escape hatch and 403s; offered on " + JSON.stringify(roleOffers));
      assert.ok(removeOffers.includes("ozz@acme.com"),
        "an owner must be offered Remove on a PEER OWNER's row — remove_member_as/3's owner escape hatch permits it; offered on " + JSON.stringify(removeOffers));
      assert.deepEqual(roleOffers, ["ada@acme.com", "lin@acme.com", "rex@acme.com"],
        "Change role reaches the two outranked rows and the actor's OWN (self-demotion is a 409 state refusal, not an authority one) — got " + JSON.stringify(roleOffers));
      assert.deepEqual(removeOffers, ["lin@acme.com", "ozz@acme.com", "rex@acme.com"],
        "Remove reaches every row but the actor's own — got " + JSON.stringify(removeOffers));
    },
  },
  // Env-vars (admin): view-env visible, the row grammar (mono keys, scope +
  // secret + write-once chips, the sealed write-once note) + the add FORM.
  "env-populated": {
    what: "Environment variables (admin) — rows (secret/write-once/scopes) + add form — AND a real Delete click that shrinks the SERVER list 4→3",
    async check(reg, hooks, ctx) {
      assert.equal(reg.get("view-env").hidden, false, "the Environment-variables view must be visible");
      const body = reg.get("env-body").innerHTML || "";
      assert.ok(body.includes("set-section"), "the rows ride the .set-section anatomy");
      assert.ok(body.includes("DATABASE_URL") && body.includes("STRIPE_SECRET_KEY") && body.includes("WORKER_TOKEN"), "every var key renders");
      assert.ok(body.includes(">Secret<"), "a secret chip renders");
      assert.ok(body.includes(">Write-once<"), "a write-once chip renders");
      assert.ok(body.includes(">Team<") && body.includes(">Instance<"), "both scope chips render");
      // The value is sealed forever — NEVER a reveal affordance anywhere.
      assert.ok(!body.includes("Reveal") && !body.includes("Show value") && !body.includes("value=\"env"), "no reveal affordance — the value is sealed");
      // The write-once row carries the honest sealed-and-unreplaceable note.
      assert.ok(body.includes("Delete and recreate to change"), "the write-once row states it can't be changed in place");
      // The admin add-var FORM section with its own save-row.
      assert.ok(body.includes("Add a variable") && body.includes("set-save-row"), "the add-var form section renders with a save-row");
      assert.ok(body.includes(">Delete<"), "admin rows carry Delete");

      // ── cch-w10 LEG 4/5: DELETE A VARIABLE, CLICKED FOR REAL ──────────────
      const rows = reg.get("env-body").querySelectorAll("[data-env-delete]");
      assert.equal(rows.length, 4, "every admin row carries a wired Delete; got " + rows.length);
      const varId = rows[0].getAttribute("data-env-delete");
      const varKey = rows[0].getAttribute("data-key");
      assert.equal(rows[0].click(), 1, "the row Delete dispatched no click handler — it is DEAD");
      assert.equal(ctx.countCalls("DELETE", "/v1/env-vars/" + varId), 0,
        "the row click must only open the confirm sheet — a sealed value must never go on a single click");
      const sheet = reg.get("modal-body").innerHTML || "";
      assert.ok(sheet.includes("Delete variable?") && sheet.includes(varKey),
        "the sheet must name the variable; got: " + sheet.slice(0, 200));
      assert.ok(sheet.includes("can&#39;t be recovered") || sheet.includes("can't be recovered"),
        "the sheet must state the value is unrecoverable — the whole reason this verb needs a sheet");
      const go = reg.get("env-delete-go");
      assert.equal(go.click(), 1, "the sheet's Delete must be wired for \"click\"");
      assert.equal(go.disabled, true, "the in-flight Delete must disable itself against a double-fire");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", "/v1/env-vars/" + varId), 1, "exactly one env-var DELETE on the wire");
      assert.equal(ctx.state.envVars.length, 3,
        "the server list must shrink by exactly one (4 → 3); got " + ctx.state.envVars.length);
      assert.ok(!ctx.state.envVars.some((v) => v.id === varId), "and the deleted row is the one gone");
      const after = reg.get("env-body").innerHTML || "";
      // Anchored on the ROW markup, not a bare substring: the add-var form
      // carries "DATABASE_URL" as its placeholder, so a naive includes() would
      // have reported the deleted row as still present and sent the next reader
      // hunting a bug that isn't there.
      assert.ok(!after.includes('set-row-key">' + varKey + "<"),
        "the deleted row must be gone from the repaint; got: " + after.slice(0, 300));
      assert.equal(countMatches(after, 'class="set-row-key"'), 3, "three rows survive the refetch");
      assert.ok(after.includes('set-row-key">STRIPE_SECRET_KEY<'), "and the survivors are still listed");
    },
  },
  // The write-once 409 twin renders the same sealed note; the POST-collision copy
  // itself is unit-pinned (envVarWriteFailureCopy) since the submit is click-driven.
  "env-write-once-409": {
    what: "Environment variables — the write-once row's sealed state (409 copy unit-pinned)",
    check(reg) {
      assert.equal(reg.get("view-env").hidden, false, "the Environment-variables view must be visible");
      const body = reg.get("env-body").innerHTML || "";
      assert.ok(body.includes("STRIPE_SECRET_KEY") && body.includes("Write-once"), "the write-once var renders");
      assert.ok(body.includes("Delete and recreate to change"), "the sealed per-row note renders");
    },
  },
  // Env-vars (member): read-only rows, NO add form, NO Delete (member-read law).
  "env-member": {
    what: "Environment variables (member) — read-only rows, no add form",
    check(reg) {
      assert.equal(reg.get("view-env").hidden, false, "the Environment-variables view must be visible");
      const body = reg.get("env-body").innerHTML || "";
      assert.ok(body.includes("DATABASE_URL"), "the rows still render for a member");
      assert.ok(!body.includes("Add a variable") && !body.includes("set-save-row"), "a member sees no add form");
      assert.ok(!body.includes(">Delete<"), "a member sees no Delete affordance");
    },
  },

  // ── gr-p5 OPERATOR CONSOLE (GR39/GR40/GR48/GR49/GR50) ─────────────────────
  // The crown surface, states-complete: rolling / halted / bounced / unreadable.
  "operator-console": {
    what: "Operator console (rolling) — brake live, canary ordered, staging gate open, warm pool ready, digest empty",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, false, "the Operator view must be visible for an operator");
      const page = reg.get("operator-body").innerHTML || "";
      for (const heading of ["Rollout brake", "Canary rollout", "Warm pool", "Fleet digest", "Deploy ledger"])
        assert.ok(page.includes(heading), "the page carries the " + heading + " card");

      // 1. BRAKE — the SHARED banner model, with the console's one action control.
      const brake = reg.get("op-brake-body").innerHTML || "";
      assert.ok(brake.includes("Fleet autoupdate is live"), "the shared banner copy renders (never restated)");
      assert.ok(brake.includes('data-fleet-au="halt"'), "the console owns the Halt control");
      assert.ok(brake.includes("nothing is rolled back"), "the halt consequence is stated honestly");

      // 2. CANARY — every row, the settle countdown, the top-level gate, 20m copy.
      const canary = reg.get("op-canary-body").innerHTML || "";
      for (const name of ["acme-canary", "acme-prod", "beta-prod", "fresh-box", "optout-prod"])
        assert.ok(canary.includes(name), "the roll-up renders " + name);
      assert.ok(canary.includes("SETTLE — 9m of 20m"), "the in-flight box shows its settle countdown");
      assert.ok(canary.includes("a staging instance is current on the newest release"), "the TOP-LEVEL gate flag drives the gate line");
      assert.ok(canary.includes("Unknown") && canary.includes("Autoupdate off") && canary.includes("Behind") && canary.includes("Current"),
        "all four update_state vocabularies render");
      assert.ok(canary.includes("SETTLE 20m") && !canary.includes("30m"), "20 minutes, never the mock's 30m");
      // In-flight leads, then staging, then behind — the rollout's own order.
      assert.ok(canary.indexOf("acme-prod") < canary.indexOf("acme-canary"), "the in-flight box leads");
      assert.ok(canary.indexOf("acme-canary") < canary.indexOf("beta-prod"), "the staging canary precedes the prod queue");

      // 3. WARM POOL — ONE number, no bar, no invented denominator.
      const warm = reg.get("op-warm-body").innerHTML || "";
      assert.ok(warm.includes(">2<"), "the ready count renders");
      assert.ok(warm.includes("there's no total to compare against"), "the honest no-denominator caption renders");
      assert.ok(!warm.includes("usage-bar") && !warm.includes("%"), "no bar and no percentage");

      // 4. DIGEST — an EMPTY OPERATOR LIST and NO send-now button. cch-w55-s3
      // called this empty a query artifact, because the writer stamped a real
      // team_id while the reader filtered is_nil(team_id). cch-w56-s3 FIXED the
      // reader (event-only, notifications.ex:930), so the list can see the
      // receipts and empty is an honest empty: nothing recorded.
      const digest = reg.get("op-digest-body").innerHTML || "";
      assert.ok(!digest.includes("never land in this list"), "the receipts DO land here now — the reader filters on the event alone");
      assert.ok(digest.includes("an empty list means nothing was recorded"), "the honest empty state renders");
      assert.ok(digest.includes("06:00 UTC"), "the one backed clock claim survives (config.exs:334)");
      assert.ok(!/Send (one )?now/i.test(page + digest), "no send-now button anywhere (GR40)");

      // 5. DEPLOY LEDGER CENSUS (dr-w1-s2) — the READABLE arm: n=1840 clears
      // @min_sample, so the rate answers and must arrive WITH its denominator.
      // Sixteen waves computed this number and nothing rendered it; this is the
      // first assertion in the repo that a human can SEE a failure class.
      const census = reg.get("op-census-body").innerHTML || "";
      assert.ok(census.includes("16.96%"), "the rate the server computed renders verbatim; got: " + census);
      assert.ok(census.includes("312 of 1840"),
        "a percentage NEVER travels without its numerator and denominator; got: " + census);
      for (const cls of ["BUILD_FAILED", "BOX_UNREACHABLE", "UNCLASSIFIED"])
        assert.ok(census.includes(cls), "the class table names " + cls);
      assert.ok(census.includes("the site build exited non-zero"),
        "the LABEL is DeployLedger.label/1's own string, rendered verbatim — the console owns no label map");
      assert.ok(!census.includes("not enough data"), "a rate the ledger answered is not a refusal");
      assert.ok(!census.includes("No deployments in this window"), "1840 rows is not an empty window");
      assert.ok(census.includes("volume 1840") && census.includes("deferred 99"),
        "every named state is a COUNT beside the rate, never folded into it");
    },
  },
  "operator-halted": {
    what: "Operator console (halted) — Resume offered, gate closed, empty pool stated calmly, digest failure verbatim",
    check(reg) {
      const brake = reg.get("op-brake-body").innerHTML || "";
      assert.ok(brake.includes("Fleet autoupdate is halted"), "the halted banner renders");
      assert.ok(brake.includes("bad release 0.5.0"), "the server's halt reason is shown");
      assert.ok(brake.includes('data-fleet-au="resume"'), "Resume is the offered action");
      const canary = reg.get("op-canary-body").innerHTML || "";
      assert.ok(canary.includes("closed — staging is behind or paused"), "the closed gate is stated");
      const warm = reg.get("op-warm-body").innerHTML || "";
      assert.ok(warm.includes("The pool is empty right now"), "an empty pool reads as a designed state");
      assert.ok(!warm.includes("unavailable"), "an empty pool is never reported as an error");
      const digest = reg.get("op-digest-body").innerHTML || "";
      assert.ok(digest.includes("smtp: connection timed out"), "the failed send carries its verbatim error");
      assert.ok(digest.includes("Sent") && digest.includes("Failed"), "both outcomes render");

      // THE REFUSAL, RENDERED (dr-w1-s2). n=74 is below @min_sample 200, so
      // `rate/2` answers `refused: true, pct: null`. The console must print the
      // ledger's own refusal and NOT a percentage — and it must not compute one
      // from the counts (12/74 = 16.22%) sitting right beside it either.
      const census = reg.get("op-census-body").innerHTML || "";
      assert.ok(census.includes("not enough data (n=74)"),
        "the ledger's refusal renders with the SERVER's own n; got: " + census);
      assert.ok(census.includes("sample 74 below min_sample 200"),
        "and the server's reason rides along, so the threshold is legible");
      assert.ok(!/\d+(\.\d+)?%\s*—/.test(census),
        "NO percentage may be rendered for a refused rate; got: " + census);
      assert.ok(!census.includes("16.22"), "and certainly not one computed client-side from 12/74");
      // The COUNTS stay — D9's ruling is that counts stay while ratios go.
      assert.ok(census.includes("volume 74") && census.includes("failed 12"),
        "a refused RATIO does not delete the real rows behind it");
      assert.ok(census.includes("BUILD_FAILED"), "the class table still renders under a refused rate");
    },
  },
  "operator-zero-staging": {
    what: "Operator console (zero staging, empty pool) — the gate is open but vouches for NOTHING, and an empty pool is a designed state",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, false, "the Operator view renders for an operator");
      const canary = reg.get("op-canary-body").innerHTML || "";
      // GR50's THIRD gate sentence: open-because-empty is not open-because-vouched.
      assert.ok(canary.includes("no staging instance is registered"),
        "an empty staging list must NOT read as a green vouch");
      assert.ok(!canary.includes("a staging instance is current on the newest release"),
        "the vouching sentence must never fire without a staging box");
      assert.ok(!canary.includes("closed"), "the gate is genuinely open — it just guarantees nothing");
      for (const name of ["acme-prod", "beta-prod"]) assert.ok(canary.includes(name), "the prod queue still renders " + name);
      // Empty warm pool: the designed-state sentence, never an error, never a bar.
      const warm = reg.get("op-warm-body").innerHTML || "";
      assert.ok(warm.includes("The pool is empty right now"), "an empty pool reads as a designed state");
      assert.ok(!warm.includes("unavailable"), "an empty pool is never reported as unreadable");
      assert.ok(!warm.includes("usage-bar") && !warm.includes("%"), "no bar, no invented denominator");
      // And the digest is honestly empty rather than absent — since cch-w56-s3
      // fixed the reader (event-only), this list carries every team's receipts,
      // so empty means nothing was recorded.
      const digest = reg.get("op-digest-body").innerHTML || "";
      assert.ok(digest.includes("an empty list means nothing was recorded"), "the honest empty digest renders");
      assert.ok(!digest.includes("platform-operator addresses"), "the audience is team members, not platform admins (dr-w19-s5)");

      // THE EMPTY CENSUS WINDOW (dr-w1-s2). volume 0 is NOTHING MEASURED, not
      // zero failures — a zeroed class table beside a 0.0% rate reads as health,
      // which is the exact inversion this epic exists to refuse.
      const census = reg.get("op-census-body").innerHTML || "";
      assert.ok(census.includes("No deployments in this window"),
        "an empty window says so in words; got: " + census);
      assert.ok(!census.includes("set-row"), "and draws NO class table — a table of zeroes reads like health");
      assert.ok(!/%/.test(census), "no rate, not even 0%, off a window with nothing in it");
      assert.ok(!census.includes("unavailable"), "an empty window is a reading, never an error");
    },
  },
  "operator-denied": {
    what: "Operator console — a non-operator deep link is BOUNCED to Overview (fail-closed route gate)",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, true, "the Operator view must NEVER render for a non-operator");
      assert.equal(reg.get("view-overview").hidden, false, "the bounce lands on Overview");
      assert.equal(reg.get("operator-body").innerHTML || "", "", "no operator markup is left behind");
      assert.equal(reg.get("nav-operator").hidden, true, "the sidebar entry stays hidden too");
      // cch-w36-s4 / charter D411 — ADDITIVE to the four above, which are the
      // fail-closed guarantee and are asserted here UNCHANGED. The bounce used
      // to happen in total silence: body blanked, hash flipped, and not one
      // sentence — right or wrong — ever shown. With PLATFORM_ADMIN_EMAILS unset
      // this is EVERY user's experience of #operator, so the silence was the
      // only behaviour prod has ever had.
      const toasts = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(toasts.includes("platform-gated"), "the refusal is finally SAID; got: " + toasts);
      assert.ok(toasts.includes("platform_operator"),
        "and it names the platform principal the server itself emits");
      assert.ok(toasts.includes("No team role grants it"), "…and that no team action can grant it");
      assert.ok(!/ask (your|the) team owner/i.test(toasts),
        "a platform allowlist is never a team-owner errand (charter D386's wrong remedy)");
    },
  },
  "operator-unreadable": {
    what: "Operator console — every route 403s; all four cards name the REFUSAL (not a transport failure), and none fakes a value",
    check(reg) {
      assert.equal(reg.get("view-operator").hidden, false, "an operator still reaches the page");
      const brake = reg.get("op-brake-body").innerHTML || "";
      const canary = reg.get("op-canary-body").innerHTML || "";
      const warm = reg.get("op-warm-body").innerHTML || "";
      const digest = reg.get("op-digest-body").innerHTML || "";
      const census = reg.get("op-census-body").innerHTML || "";
      // cch-w36-s4 — THIS SCENARIO IS A 403 ON ALL FOUR ROUTES, and a 403 is an
      // ANSWER: the control plane made a determination. The cards used to call
      // it "didn't answer / this card just couldn't read it" — a transport story
      // over an authority verdict — because operatorPaint's single ternary
      // destroyed the status before any renderer saw it. Four cards, ONE funnel.
      for (const [name, html] of [["brake", brake], ["canary", canary], ["warm pool", warm], ["digest", digest], ["census", census]]) {
        assert.ok(html.includes("refused this read (403)"), "the " + name + " names the refusal");
        assert.ok(html.includes("platform_operator"), "the " + name + " names the authority that refused");
        assert.ok(!html.includes("didn't answer"), "the " + name + " no longer calls a determination a silence");
        assert.ok(!/ask (your|the) team owner/i.test(html), "the " + name + " sends nobody to a team owner");
      }
      assert.ok(!brake.includes("data-fleet-au"), "a refused brake offers no button");
      assert.ok(!warm.includes("op-metric-v"), "no fake zero is drawn when the count was refused");
      // A REFUSED CENSUS IS NOT AN EMPTY WINDOW, and it is not a rate of zero.
      // Both would be a determinate claim about the fleet's deploys off a read
      // the control plane never performed.
      assert.ok(!census.includes("No deployments in this window"),
        "a refused read must NEVER be reported as a measured empty window");
      assert.ok(!/%/.test(census), "and no percentage is drawn off a reading that was refused");
      assert.ok(!census.includes("not enough data"),
        "a 403 is an AUTHORITY verdict, never the ledger's sample-size refusal");
      for (const html of [brake, canary, warm, digest, census])
        assert.ok(!html.includes("Loading"), "no card is left spinning after its request settles");
    },
  },
  "operator-me-unreadable": {
    what: "Operator console — /v1/me 500s STICKILY: the body REPORTS the failed check, and pressing the retry on a read that fails AGAIN repaints the report rather than stranding the spinner",
    async check(reg, hooks, ctx) {
      const body = reg.get("operator-body").innerHTML || "";
      // THE DEFECT, DRIVEN. On origin/main this string is the whole body, for
      // the rest of the session: loadOperator branched on `!meCache` alone, and
      // loadMe's failure arm never re-enters it, so navigating away and back
      // repaints the same spinner. A spinner that outlives its request claims we
      // are still checking; we are not.
      assert.ok(!body.includes("Checking operator access"),
        "the console must not claim to be checking access it will never check; got: " + body);
      assert.ok(body.includes("We couldn't check your account"), "it says what actually happened; got: " + body);
      assert.ok(body.includes("operator-me-retry"), "…and offers the retry the spinner never did");
      // HONEST ABOUT THE FAULT CLASS: a 500 is ours, not the person's input.
      assert.ok(body.includes("broke on our side"), "a 5xx is reported as a 5xx; got: " + body);
      // NOT AN ACCUSATION (the D411 intent, carried into this arm): an unread
      // answer is not a refusal, so no role is named and nothing is denied.
      assert.ok(!body.includes("platform_operator") && !/platform-gated/i.test(body),
        "an unread /v1/me is not a platform refusal");
      assert.ok(!/ask (your|the) team owner/i.test(body), "and it is certainly not a team-owner errand");
      // FAIL-CLOSED IS UNWEAKENED (GR9): the sidebar entry stays hidden while
      // the role is unknown, and this is a WAIT — not a false grant.
      assert.equal(reg.get("nav-operator").hidden, true, "an unknown role never reveals the sidebar entry");
      // …and no operator route was read: the four cards were never painted.
      assert.equal(reg.get("op-brake-body"), undefined, "no operator card is mounted while the role is unknown");

      // cch-w37-bl-operator-retry-click-undriven — THE ARM THE RECOVERY TWIN
      // CANNOT REACH: a retry whose re-read FAILS TOO. The handler paints the
      // spinner before it re-reads, so if nothing repaints afterwards the
      // console is left claiming to check an answer that already came back —
      // the exact forever-spinner the failed arm was built to end, reachable
      // again through the exit that was supposed to end it.
      //
      // THE ROW'S THIRD REGRESSION IS REFUTED, AND THIS IS WHERE IT DIES. The
      // row lists "drops the .then" among the regressions that pass every gate.
      // It passes because it is a NO-OP, not because coverage was missing:
      // loadMe re-enters this loader from BOTH arms already (app.js — the
      // success seam and the cch-w37-s6 failure seam, each guarded on
      // `currentView() === "operator"`), and the retry only exists inside the
      // operator view. Measured, not read: replacing the handler's
      // `loadMe().then(…)` with a bare `loadMe()` leaves this whole suite's
      // output BYTE-IDENTICAL across every scenario (diff rc 0, both rc 0).
      // The `.then` is belt-and-braces over a seam that already fires — and on
      // this failing path it makes the failed arm paint twice. No test in this
      // file claims to catch its deletion, because no observable behaviour
      // changes when it goes.
      const ids = [...body.matchAll(/<button[^>]*\bid="([^"]+)"/g)].map((m) => m[1]);
      assert.equal(ids.length, 1, "the failed arm must offer exactly one button — found " + JSON.stringify(ids));
      const btn = reg.get(ids[0]);
      assert.ok(btn,
        "#" + ids[0] + " is the id the failed arm renders, and nothing in app.js ever looked it up — " +
        "the retry's listener is bound to some other node");
      assert.equal(ctx.countCalls("GET", "/v1/me"), 1, "exactly one /v1/me read at boot");
      const fired = btn.click();
      assert.ok(fired > 0, "#" + ids[0] + " dispatched " + fired + " click handler(s) — the retry is DEAD");
      await ctx.settle();
      assert.equal(ctx.countCalls("GET", "/v1/me"), 2, "the retry must re-issue the read exactly once");
      const after = reg.get("operator-body").innerHTML || "";
      assert.ok(!after.includes("Checking operator access"),
        "the retry left the console on the spinner it painted while it waited — the second read failed and nothing " +
        "repainted the report, which is the forever-spinner this whole arm exists to end; got: " + after);
      assert.ok(after.includes("We couldn't check your account"),
        "a retry whose re-read fails too must say so again, not go blank; got: " + after);
      assert.ok(after.includes(ids[0]), "…and must still offer the retry — one failure does not retire the exit");
      // STILL FAIL-CLOSED after the press: no route read, no sidebar entry.
      assert.equal(reg.get("nav-operator").hidden, true, "a failed re-read never reveals the sidebar entry");
      for (const path of ["/v1/operator/autoupdate", "/v1/operator/fleet", "/v1/operator/warm-pool", "/v1/operator/deliveries"]) {
        assert.equal(ctx.countCalls("GET", path), 0, "no operator route may be read after a failed retry (" + path + ")");
      }
    },
  },
  // cch-w37-bl-operator-retry-click-undriven — THE CLICK, WHICH NOTHING DROVE.
  //
  // The sibling above asserts the failed BODY renders and carries the retry.
  // That is the whole of what was proven: no harness in this repo had ever
  // pressed it. Three regressions passed every gate — a listener wired to the
  // wrong node, a dropped `.then`, and a loader re-entered on a SUCCESSFUL read
  // (painting twice and issuing the four operator reads twice). The third is the
  // one with no analogue on the billing surface, because only this loader fans
  // out to four routes.
  //
  // THE ID IS READ OFF THE RENDERED BODY, NEVER TYPED HERE. This shim's `$("#x")`
  // AUTO-VIVIFIES, so a listener bound to a node the markup does not contain
  // still attaches to something — and a hardcoded id in this file would click
  // that same phantom and report success. Extracting the id from the HTML the
  // person is actually shown makes "wired to the wrong node" observable: the
  // click lands on the rendered button, finds no handler, and `fired` is 0.
  "operator-me-recovers": {
    what: "Operator console — /v1/me 500s ONCE: the retry is CLICKED, the shell paints, /v1/me is read exactly twice and each of the four operator routes exactly once",
    async check(reg, hooks, ctx) {
      const OPS = ["/v1/operator/autoupdate", "/v1/operator/fleet", "/v1/operator/warm-pool", "/v1/operator/deliveries"];
      const before = reg.get("operator-body").innerHTML || "";
      assert.ok(before.includes("We couldn't check your account"),
        "the boot read must FAIL first — without the failed arm there is no recovery to measure; got: " + before);
      assert.ok(!before.includes("Checking operator access"), "the failed arm is not the spinner");
      assert.equal(ctx.countCalls("GET", "/v1/me"), 1, "exactly one /v1/me read at boot");
      for (const path of OPS) {
        assert.equal(ctx.countCalls("GET", path), 0, "no operator route may be read while the role is unknown (" + path + ")");
      }
      assert.equal(reg.get("nav-operator").hidden, true, "the sidebar entry stays hidden while the role is unknown");

      // THE BUTTON THE PERSON SEES, by the id the markup declares.
      const ids = [...before.matchAll(/<button[^>]*\bid="([^"]+)"/g)].map((m) => m[1]);
      assert.equal(ids.length, 1, "the failed arm must offer exactly one button — found " + JSON.stringify(ids));
      // THE REGISTRY IS THE FIRST WITNESS. It holds exactly the ids app.js has
      // looked up; an id the failed arm RENDERS but nobody ever queried is the
      // wrong-node bug in its purest form, and it must say so rather than dying
      // on `undefined.click`.
      const btn = reg.get(ids[0]);
      assert.ok(btn,
        "#" + ids[0] + " is the id the failed arm renders, and nothing in app.js ever looked it up — " +
        "the retry's listener is bound to some other node");
      const fired = btn.click();
      assert.ok(fired > 0,
        "#" + ids[0] + " dispatched " + fired + " click handler(s) — the retry the failed arm renders is DEAD, " +
        "or its listener is bound to a node this markup does not contain");
      await ctx.settle();

      // THE READ RE-ISSUED, AND EXACTLY ONCE. `>= 2` would pass a loader that
      // re-enters itself forever; the shipped `.then` re-enters ONLY when the
      // read did not land, so a healed read costs exactly one extra /v1/me.
      assert.equal(ctx.countCalls("GET", "/v1/me"), 2,
        "the retry must re-issue /v1/me exactly once — " + ctx.countCalls("GET", "/v1/me") + " total reads");

      const after = reg.get("operator-body").innerHTML || "";
      assert.ok(!after.includes("We couldn't check your account"), "the failure copy retires once the read lands");
      assert.ok(!after.includes("Checking operator access"),
        "the console must not be left on the spinner the retry painted while it waited; got: " + after);
      // THE SHELL ACTUALLY PAINTED — the four card slots the operator page owns.
      for (const slot of ["op-brake-body", "op-canary-body", "op-warm-body", "op-digest-body", "op-census-body"]) {
        assert.ok(after.includes(slot), "the operator shell did not mount #" + slot + "; got: " + after);
      }
      assert.equal(reg.get("nav-operator").hidden, false, "a proven operator gets the sidebar entry back");

      // THE DOUBLE-READ REGRESSION, NAMED. loadMe's SUCCESS arm re-enters this
      // loader itself; re-entering again from the retry's `.then` paints the
      // page twice and reads all four routes twice. Nothing before this
      // scenario could see it, because nothing pressed the button.
      for (const path of OPS) {
        assert.equal(ctx.countCalls("GET", path), 1,
          path + " was read " + ctx.countCalls("GET", path) + " time(s) — the recovered loader must fan out exactly once");
      }
    },
  },
  // ── MVP-0 Personal Dev Fleet (pdf-mvp0-fleet-card-spa): the fleet card ─────
  "fleet-support-provisioning": {
    what: "the fleet card with a support mid-provision — the 6-rung SUPPORT theater, secure included, never a freshen rung",
    container: "instance-body",
    includes: ["fleet-support-card", "fleet-support-theater", "new-steps",
      "Configuring the runtime", 'data-step="secure"', 'data-step="verify"'],
    excludes: ['data-step="freshen"'],
  },
  "fleet-support-online": {
    what: "the fleet card with an ONLINE support — the BYO-model-key step in the card; the roster read answers the documents envelope and the presence pipeline renders --online from THAT fixture",
    check(reg, hooks, ctx) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      // The static card half: key step + the presence slot (this fake DOM can't
      // observe the async attribute-selector paint — the chip pipeline is
      // asserted below from the same fixtures the paint consumes).
      for (const needle of ["fleet-support-card", "support-key-step", "Hand your box its model key",
        "data-support-presence=", "never stored by Barkpark",
        "/etc/barkpark/fleet-listener.env &amp;&amp; systemctl restart barkpark-fleet-listener"]) {
        assert.ok(body.includes(needle), "#instance-body missing " + JSON.stringify(needle));
      }
      // The wire half: the app-token mint fired and the browser-direct roster
      // read landed on the /v1/fleet/roster arm (absolute-origin stripped).
      assert.ok(ctx.calls.some((c) => c.method === "POST" && /\/app-token$/.test(c.path)),
        "the member app token must be minted (in-memory only)");
      const roster = route("fleet-support-online", "GET", "/v1/fleet/roster");
      assert.ok(Array.isArray(roster.body.documents), "the roster rides the documents envelope (PDF-D21)");
      // The presence pipeline over the SAME fixture the paint consumes:
      // online DERIVED (idle ⇒ not offline) + the validated capacity object.
      const support = SCENARIOS["fleet-support-online"].data.barkparks.find((b) => b.fleet_role === "support");
      const slot = hooks.presenceSlotHtml(roster.body.documents, support);
      assert.ok(slot.includes("fleet-presence--online"), "idle must render the derived Online chip");
      assert.ok(slot.includes("Online · idle"), "the stored status renders as-is beside the derived Online");
      assert.ok(slot.includes("standard · 1/1 slots free"), "the capacity object renders");
      assert.ok(ctx.calls.some((c) => c.path === "/v1/fleet/roster" || /\/v1\/fleet\/roster$/.test(c.path)),
        "the roster was actually fetched browser-direct");
    },
  },
  "fleet-support-failed": {
    what: "the fleet card with a STUCK support — honest failed state, never lies online",
    container: "instance-body",
    includes: ["fleet-support-card", "Setup failed",
      "no heartbeat within the provisioning budget"],
    excludes: ["fleet-presence--online", "support-key-step"],
  },
  "fleet-support-empty": {
    what: "the fleet card empty state on a live main — the add-a-support CTA",
    container: "instance-body",
    includes: ["fleet-support-card", "No support servers yet", 'id="fleet-add-support-cta"'],
    excludes: ["fleet-support-row"],
  },
  // ── MVP-0 OFFLOAD (pdf-mvp0-offload-spa): the order watch ladder ───────────
  // The offload button renders on the ONLINE support row (static, observable in
  // #instance-body). The watch panel itself mounts AFTER a click+submit, which
  // this fake DOM can't drive, so the ladder is proven the fleet-support-online
  // way: fold the SAME task + roster fixtures the poll consumes through the pure
  // hooks and assert the rung + markup.
  "offload-filing": {
    what: "offload — the order is filed (open); the ladder folds to the FILED rung from the task + roster reads",
    check(reg, hooks, ctx) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.includes("data-offload-support="), "the Offload button must render on a live support");
      assert.ok(body.includes("Offload a task"), "the Offload action label renders");
      assert.ok(body.includes("data-offload-slot="), "the watch slot mounts on the row");
      assert.ok(ctx.calls.some((c) => c.method === "POST" && /\/app-token$/.test(c.path)),
        "the member app token must be minted (in-memory only)");
      const task = route("offload-filing", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-filing", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "filed");
      assert.equal(watch.terminal, false);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch);
      assert.ok(panel.includes("new-steps"), "the ladder renders through the SHARED step grammar");
      assert.ok(panel.includes("waiting for the support to claim"), "the filed rung label");
    },
  },
  "offload-working": {
    what: "offload — claimed AND working; the ladder folds filed→claimed→working from the task (in_progress) + roster (working) reads",
    check(reg, hooks) {
      const task = route("offload-working", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-working", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "working");
      assert.equal(watch.terminal, false);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch, 12000);
      assert.ok(panel.includes("Working the order"), "the working rung label");
      assert.ok(panel.includes('data-step="working"'), "the working rung renders in the ladder");
    },
  },
  "offload-done": {
    what: "offload — DONE terminal (the poll stops); the ladder paints every rung done + the success banner",
    check(reg, hooks) {
      const task = route("offload-done", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-done", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "done");
      assert.equal(watch.terminal, true);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch);
      assert.ok(panel.includes("notice-ok"), "the done terminal shows the success banner");
    },
  },
  "offload-blocked": {
    what: "offload — BLOCKED terminal; the ladder snaps and shows the honest blocked banner",
    check(reg, hooks) {
      const task = route("offload-blocked", "GET", "/v1/tasks/" + "x");
      const roster = route("offload-blocked", "GET", "/v1/fleet/roster");
      const watch = hooks.offloadWatchStage(task.body.doc, roster.body.documents, "muscle-2");
      assert.equal(watch.stage, "blocked");
      assert.equal(watch.terminal, true);
      const panel = hooks.offloadWatchPanelHtml({ id: "x", title: "Summarise the release notes" }, watch);
      assert.ok(panel.includes("notice-warn"), "the blocked terminal shows the honest banner");
      assert.ok(panel.includes('class="new-step failed'), "the ladder snaps on the failed rung");
    },
  },
  // ── cch-w61-s2: the Updates panel finally renders in a SECOND state, and the
  // Roll back button is wired in this harness AT ALL ─────────────────────────
  // TWO defects meet here, and neither was visible from the other side:
  //   (a) the corpus had ONE update state across every committed scenario
  //       (`current`) and NO mock route for POST …/rollback, so a preview click
  //       "succeeded" against a fixture that could never refuse;
  //   (b) `wireUpdatePanel` opened with a compound descendant selector this
  //       shim's query() cannot parse — measured `Roll back click dispatched
  //       handlers = 0`, in every scenario, since the button shipped. The
  //       shipped fallback to the `#instance-body` mount fixes it (handlers = 1,
  //       asserted below). Widening PARSED_TAGS instead was measured WORSE: 6
  //       scenarios red and still 0 handlers.
  // The positive click count is MANDATORY here: an empty node list dispatches
  // nothing and reads as a clean pass — the exact false green this harness exists
  // to refuse.
  "instance-update-credential-refused": {
    what: "credential-refused box — Roll back is WIRED (handlers=1), its 409 renders terminally, and the recovery issues no second POST",
    async check(reg, hooks, ctx) {
      const body = reg.get("instance-body");
      const html = (body || {}).innerHTML || "";
      assert.ok(html.includes("update-panel"), "the Updates panel must render — this box HAS a host");
      // cch-w63-s5 — THESE TWO ASSERTIONS WERE THE LIE, AND THEY ARE MOVED, NOT
      // WORKED AROUND. They read `Checked 45m ago` + `Unknown` and justified it as
      // "what update_state actually is for a refused box". update_state IS
      // "unknown" — the wire's own word, and the data attribute below still pins
      // it (charter D778) — but this fixture carries
      // update_unavailable_reason:"identity_refused", i.e. the control plane
      // NAMED the cause. The probe ran and the box refused it; nothing was
      // "checked", so the panel must not say so.
      assert.ok(html.includes("Tried 45m ago — the instance rejected our access credential"),
        "the panel states what was TRIED and why it failed, echoing usageUnavailableText('unauthorized') verbatim");
      assert.equal(html.includes("Checked"), false,
        "…and never asserts a completed check about a probe the box refused");
      assert.ok(html.includes("Could not check"), "the badge names the failure instead of shrugging");
      assert.ok(html.includes('data-update-state="unknown"'),
        "…while the STATE literal stays `unknown` — the label moved, the wire's word did not");

      const rb = body.querySelectorAll("[data-rollback]");
      assert.equal(rb.length, 1, "exactly one Roll back control renders");
      const handlers = rb[0].dispatchEvent({ type: "click" });
      assert.ok(handlers > 0,
        "Roll back dispatched " + handlers + " handlers — wireUpdatePanel had never wired anything in " +
        "this harness before the #instance-body fallback (measured: 0)");

      // The sheet's LABEL lives on #modal-body's parsed child; the STATE app.js
      // writes lives on the #id registry node. They are different objects (the
      // D54 correction above) — read each fact off the one that carries it.
      const sheet = (reg.get("modal-body") || {}).innerHTML || "";
      assert.ok(sheet.includes(">Roll back<"), "the danger confirm sheet must mount, labelled");
      assert.ok(sheet.includes("btn-danger"), "…on the danger tier");
      assert.equal(sheet.indexOf("cm-typed"), -1, "…danger-no-echo: no typed field");
      const confirm = reg.get("cm-confirm");
      assert.ok(confirm, "the shared confirm trigger must exist");

      const posts = () => ctx.calls.filter((c) => c.method === "POST" && /\/rollback$/.test(c.path)).length;
      assert.equal(posts(), 0, "opening a confirm sheet POSTs nothing");

      confirm.dispatchEvent({ type: "click" });
      await ctx.settle();
      assert.equal(posts(), 1, "confirming issues exactly one POST");

      // THE FIX, END TO END, against a fixture that CAN refuse.
      assert.equal(confirm.textContent, "Close",
        "a 409 identity_refused is permanent — the recovery is Close, never a Try again that re-POSTs");
      const msg = (reg.get("cm-error-msg") || {}).textContent || "";
      assert.ok(msg.includes("the instance rejected our access credential"),
        "the inline failure names what actually happened: " + JSON.stringify(msg));
      assert.equal(msg.indexOf("Please try again in a moment."), -1,
        "…and never sells a permanent refusal as a transient one");

      confirm.dispatchEvent({ type: "click" });
      await ctx.settle();
      assert.equal(posts(), 1, "clicking the terminal recovery issues NO second POST");
    },
  },

  // ── cch-w45-bl: the three rail verbs that rendered in NO committed scenario ─
  // Measured on origin/main dea37e8d19 by booting all 116 committed scenarios
  // through this shim (0 boot errors) and scanning every registry entry's bytes:
  //   id="inst-update"        0 hits
  //   id="inst-remove-retry"  0 hits
  //   data-vf-reprovision     0 hits
  // Each absence is a STATE the corpus never produced, not a control that was
  // missing, so every guard over them was green by construction.
  //
  // WHY THE FIRST TWO WERE SCORED AT RENDER LEVEL AND NOT CLICKED. Both mounts
  // are read with `$("#inst-update")` / `$("#inst-remove-retry")`, and this
  // shim's byId AUTO-CREATES a registry entry for any id asked for — so a click
  // oracle there would dispatch against a phantom node that exists because the
  // app asked for it, and would keep passing with the control deleted. The
  // verify-card mount below is read with `box.querySelector("[data-vf-…]")`
  // over the mount's own parsed kids, which CAN answer null — so that one is
  // clicked, and its handler count is asserted positive.
  //
  // AMENDED BY cch-w2-revoke-oracle-round2, which now CLICKS #inst-remove-retry.
  // The phantom hazard above is real and is NOT waved away — it is PAIRED OUT.
  // A click alone IS a false green on a deleted control; a click PLUS the
  // byte-exact render assertion already in that check is not, because the render
  // half reds the instant the control stops being painted. Neither half is
  // redundant: delete the markup and the render half reds; unwire the handler
  // and the click half reds (0 handlers dispatched). #inst-update keeps its
  // render-only score — no destructive verb sits behind it, so there is no wire
  // worth this pairing.
  "instance-behind": {
    what: "a live box one release BEHIND paints the self-update CTA — the first committed scenario in which #inst-update exists at all",
    check(reg) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      // The LIVE mount hook, not the label: the refused arm renders the same
      // words on a disabled button, so a label-only assertion cannot tell an
      // offered verb from a withheld one.
      assert.ok(body.includes('<button class="btn btn-primary btn-sm" type="button" id="inst-update">Update to v0.9.2</button>'),
        "the admin arm must paint the live #inst-update control, labelled with the release it would install");
      // …and it is the BEHIND state that produces it. A box on `current` renders
      // no CTA at all, which is what every other instance scenario proves.
      assert.ok(body.includes("Update available"), "the pill states the same fact the CTA acts on");
      assert.ok(!body.includes("inst-life-disabled"),
        "this scenario's actor is an owner — a disable-and-explain wrapper here would mean the fixture lost its authority");
    },
  },
  "instance-remove-failed": {
    what: "a teardown that FAILED paints Retry removal — and the retry is CLICKED: exactly one DELETE /v1/barkparks/:id on the wire and the SERVER fleet shrinks 2 → 1",
    async check(reg, hooks, ctx) {
      const body = (reg.get("instance-body") || {}).innerHTML || "";
      assert.ok(body.length > 0, "#instance-body rendered empty");
      assert.ok(body.includes('<button class="btn btn-primary btn-sm" type="button" id="inst-remove-retry">Retry removal</button>'),
        "the admin arm must paint the live #inst-remove-retry control");
      // The removeFailed fold owns the WHOLE actions strip: nothing else may be
      // offered on a box whose teardown is half-done.
      assert.ok(!body.includes('id="inst-open-studio"'), "a box mid-failed-teardown offers no Studio link");
      assert.ok(!body.includes('id="inst-update"'), "…nor an update");
      // The server's verbatim reason, on the banner beside it.
      assert.ok(body.includes("<b>Removal failed.</b> hcloud: server delete returned 409 (a volume is still attached)"),
        "the deprovision_error is rendered verbatim, never summarised");

      // ── cch-w2-revoke-oracle-round2 · THE SECOND /v1/barkparks/:id DELETE ──
      // The COVERAGE BOUNDARY note in this file listed `/v1/barkparks/:id`
      // TWICE for a reason: app.js issues it from two different handlers, and
      // cch-w10 leg 5/5 covered only ONE of them. Re-derive, do not trust a
      // line number:
      //   grep -n 'api("DELETE", "/v1/barkparks/' cloud/priv/static/app.js
      // returns exactly two hits — runDecommission (COVERED: panel-overview's
      // typed Decommission) and removeInstance (THIS one, the Retry-removal
      // handler for a box whose teardown FAILED). They are not the same leg:
      // removeInstance has NO confirm sheet — the click IS the teardown — and
      // its success arm sets location.hash = "#fleet" rather than refetching,
      // so the only honest observable is the SERVER's own list.
      const victim = SCENARIOS["instance-remove-failed"].data.barkparks[1];
      assert.equal(ctx.state.barkparks.length, 2,
        "this leg's arithmetic is 2 → 1; the fleet started at " + ctx.state.barkparks.length);
      const bpPath = "/v1/barkparks/" + victim.id;
      assert.equal(ctx.countCalls("DELETE", bpPath), 0, "nothing was torn down before the click");
      const retry = reg.get("inst-remove-retry");
      // EXACTLY one, not >0 (the positive-dispatch rule at the top of this file
      // is the floor, not the ceiling): a re-render destroys the nodes its
      // markup declares, so their handlers die with them — makeDom's
      // `_resetHandlers`. A count above one would mean that model broke and
      // this click is issuing more teardowns than a browser would.
      assert.equal(retry.click(), 1, "Retry removal dispatched no click handler — it is DEAD");
      await ctx.settle();
      assert.equal(ctx.countCalls("DELETE", bpPath), 1,
        "the retry must issue exactly one DELETE for THIS box's id; got " + ctx.countCalls("DELETE", bpPath));
      assert.equal(ctx.state.barkparks.length, 1,
        "the SERVER's fleet must shrink by exactly one (2 → 1); got " + ctx.state.barkparks.length +
        " — an unchanged fleet means the teardown hit the catch-all and did nothing");
      const fleetAfter = route("instance-remove-failed", "GET", "/v1/barkparks", ctx.state);
      assert.equal(fleetAfter.body.barkparks.filter((b) => b.id === victim.id).length, 0,
        "and a fresh fleet READ agrees — the box is gone from what the server serves, not just spliced " +
        "into a bag nobody reads");
      const removeToast = (reg.get("toast-stack") || {}).innerHTML || "";
      assert.ok(removeToast.includes("Instance removed"),
        "the retry must report itself; got: " + removeToast.slice(0, 200));
    },
  },
  "verify-no-credentials": {
    what: "the golden-path card's 404 no_admin_token note offers its ONE recovery — [data-vf-reprovision] renders, is wired, and POSTs /retry once",
    async check(reg, hooks, ctx) {
      const box = reg.get("instance-verify");
      assert.ok(box, "#instance-verify was never touched");
      const before = box.innerHTML || "";
      assert.ok(!before.includes("data-vf-reprovision"),
        "the note is a RESULT: nothing offers a re-provision before the check has been run");

      // The run control is read the way app.js reads it — a single attribute
      // selector over the mount's own kids, which can answer [] — so the
      // positive handler count below is a real measurement, not a formality.
      const run = box.querySelectorAll("[data-vf-run]");
      assert.equal(run.length, 1, "exactly one Run-first-check control renders");
      const ranHandlers = run[0].dispatchEvent({ type: "click" });
      assert.ok(ranHandlers > 0, "the run control dispatched " + ranHandlers + " handlers — an unwired button is a false green");
      await ctx.settle();
      assert.equal(ctx.countCalls("POST", "/v1/barkparks/" + SCEN_IDS.liveInstance + "/verify"), 1,
        "the click issued exactly one POST /verify");

      const after = (reg.get("instance-verify") || {}).innerHTML || "";
      assert.ok(after.includes("<b>No stored credentials.</b>"), "the 404 renders the coded note, not a toast");
      assert.ok(after.includes('<button class="btn btn-sm" type="button" data-vf-reprovision>Re-provision</button>'),
        "the ONE recovery action is the live re-provision control (D25) — this is retryInstance's SECOND live mount, " +
        "and it had never rendered in any committed scenario");
      // Wired, and it calls the primitive the note's own sentence promises.
      const rp = reg.get("instance-verify").querySelectorAll("[data-vf-reprovision]");
      assert.equal(rp.length, 1, "exactly one re-provision control");
      const rpHandlers = rp[0].dispatchEvent({ type: "click" });
      assert.ok(rpHandlers > 0, "the re-provision control dispatched " + rpHandlers + " handlers");
      await ctx.settle();
      assert.equal(ctx.countCalls("POST", "/v1/barkparks/" + SCEN_IDS.liveInstance + "/retry"), 1,
        "…and it POSTs /retry exactly once — the primitive the note names in words");
    },
  },
};

function countMatches(hay, needle) {
  return hay.split(needle).length - 1;
}

// ── cch-w10: the destroy-tier confirm sheet, driven as an operator drives it ──
// The typed echo is the gate: openConfirmModal's click handler bails at
// `if (!confirmModalArmed(state)) return;`, so an UNARMED Confirm is a real,
// wired, dispatching button that issues nothing. That makes the disarm
// observable BY THE WIRE (0 requests), which is the only observation that
// cannot be faked by a stub.
//
// WHICH OBJECT CARRIES WHICH FACT — this CORRECTS D54, which recorded the
// disarm as unobservable here and told every later check to skip it:
//   • the SHIPPED disarm lives on #modal-body's PARSED child, because it is an
//     attribute of the markup confirmModalHtml emitted (`<button … disabled>`);
//   • the ARM lives on the #id REGISTRY node, because that is the object
//     app.js's input handler writes (`confirmBtn.disabled = !armed`).
// They are DIFFERENT OBJECTS. reg.get("cm-confirm").disabled is `false` on a
// fresh stub whether or not a destroy sheet ever mounted — asserting it as the
// disarm is a false green planted inside the anti-false-green scenario.
function parsedConfirmButton(reg) {
  return reg.get("modal-body").querySelectorAll("#cm-confirm")[0] || null;
}

// Assert the sheet MOUNTED and SHIPPED DISARMED, then return the parsed child.
function assertDestroySheetDisarmed(reg, where) {
  const parsed = parsedConfirmButton(reg);
  assert.ok(parsed, "no #cm-confirm inside #modal-body — the " + where +
    " confirm sheet never mounted; #modal-body is: " +
    JSON.stringify((reg.get("modal-body").innerHTML || "").slice(0, 160)));
  assert.equal(parsed.disabled, true,
    "the " + where + " destroy sheet shipped its Confirm ARMED — the typed-echo gate is gone");
  assert.equal(reg.get("cm-confirm").disabled, false,
    "D54 CORRECTION GUARD: the #id registry stub answers disabled=false here. If this ever " +
    "flips, the two objects have merged and the disarm assertion above may be read off either — " +
    "until then, reading the registry node instead of the parsed child proves NOTHING.");
  return parsed;
}

// Type the exact resource name into #cm-typed and fire the "input" event the
// arming handler listens for; returns the (now armed) registry Confirm node.
function armConfirmSheet(reg, resourceName) {
  const typed = reg.get("cm-typed");
  typed.value = resourceName;
  assert.ok(typed.dispatchEvent({ type: "input" }) > 0,
    "#cm-typed has no \"input\" handler — the typed echo can never arm the sheet");
  const confirm = reg.get("cm-confirm");
  assert.equal(confirm.disabled, false,
    "typing the exact resource name did not ARM the Confirm button");
  return confirm;
}

async function runScenario(name) {
  const exp = EXPECTATIONS[name];
  if (!exp) throw new Error("no expectations for scenario " + name);
  const { registry, hooks, calls, fixtureState, localStorage } = bootScenario(name);
  await flush();

  if (exp.check) {
    // check may be async: a click-driven scenario has to settle the fetch
    // chain the click started before it can read the re-render. `ctx.settle()`
    // is that await; sync checks simply ignore the third argument.
    await exp.check(registry, hooks, {
      calls,
      state: fixtureState,
      settle: flush,
      // cch-w2-revoke-oracle-round2: the SESSION STORE, handed through so a
      // check can read what the app WROTE and not merely what it painted.
      // /v1/auth/logout is the one destructive DELETE whose whole point is a
      // local consequence — clearSession() — and that consequence is invisible
      // in every innerHTML in the registry.
      localStorage,
      // How many times METHOD PATH was requested — the wire assertion.
      countCalls(method, path) {
        return calls.filter((c) => c.method === method && c.path === path).length;
      },
    });
    return exp.what;
  }

  const el = registry.get(exp.container);
  assert.ok(el, "container #" + exp.container + " was never touched");
  const html = el.innerHTML || "";
  assert.ok(html.length > 0, "#" + exp.container + " rendered empty");

  for (const needle of exp.includes || []) {
    assert.ok(html.includes(needle), "#" + exp.container + " missing " + JSON.stringify(needle));
  }
  for (const needle of exp.excludes || []) {
    assert.ok(!html.includes(needle), "#" + exp.container + " unexpectedly has " + JSON.stringify(needle));
  }
  if (exp.fleetRowsEqualFixture) {
    const want = SCENARIOS[name].data.barkparks.length;
    const got = countMatches(html, 'class="fleet-row"');
    assert.equal(got, want, "expected " + want + " fleet rows, rendered " + got);
  }
  return exp.what;
}

// ── cch-w10: THE CENSUS GUARD ────────────────────────────────────────────────
// The runner iterates EXPECTATIONS, never SCENARIO_NAMES. Nothing bound the two
// together, so a committed scenario with no expectation was simply NEVER RUN —
// it rendered nowhere, asserted nothing, and the suite still printed a total and
// exited 0. That is the cross-slice census hole in miniature: each half looks
// complete on its own, and only the pair exposes the gap. (The file's own
// comment has documented the trap for waves; the guard was never written.)
// Both directions matter: an EXPECTATION whose scenario was renamed or deleted
// would otherwise boot the DEFAULT fixture and quietly assert against the wrong
// data. This runs BEFORE any scenario, and it exits non-zero on its own.
function assertCensus() {
  const unrun = SCENARIO_NAMES.filter((n) => !EXPECTATIONS[n]);
  const orphans = Object.keys(EXPECTATIONS).filter((n) => !SCENARIOS[n]);
  if (!unrun.length && !orphans.length) return true;
  if (unrun.length) {
    process.stdout.write(
      "\nCENSUS: " + unrun.length + " committed scenario(s) have NO expectation and were never run — " +
      "a fixture nothing asserts on is a green that means nothing:\n  " + unrun.join("\n  ") + "\n");
  }
  if (orphans.length) {
    process.stdout.write(
      "\nCENSUS: " + orphans.length + " expectation(s) name a scenario that does not exist, so they " +
      "assert against the DEFAULT fixture:\n  " + orphans.join("\n  ") + "\n");
  }
  return false;
}

// ── cch-w24-s5: THE FENCE AROUND A READER ────────────────────────────────────
// Every fence this epic has drawn goes around a FILE. None goes around a
// READER, and a reader is what a fixture edit actually breaks. Wave 23's
// cross-slice defect was exactly that: a new row in a fixture invalidated an
// oracle that picked its neighbour POSITIONALLY, and the oracle blew up on its
// own bytes a thousand lines away from the edit that caused it.
//
// WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT. It is NOT a port of
// `SCENARIO_RESIDUE` (overflow-guard.mjs) and NOT a file-level census over
// readers — see the written refusal below. It is the shape that is ALREADY
// SHIPPED and already working in this file: the three `assert.equal` calls that
// pin a fixture's CONTENT and name the reader's assumption in the message
// ("the fixture must carry the tall shape, not the two-row short one"; "this
// fixture's /v1/me must say 2FA is off"). Those refuse by name — they just sit
// a thousand lines downstream of the edit, inside the scenario they defend.
// Hoisting them into a committed literal asserted BEFORE any scenario runs is
// the whole delta: the refusal arrives first, and it names the reader, the
// fixture path and the assumption in one sentence.
//
// THE WRITTEN REFUSAL — NO FILE-LEVEL READER CENSUS IS BUILT HERE, and the
// reason is measured, not argued. Three mutations were driven against the
// unfenced tree:
//   (A) a row PREPENDED to a fixture a reader indexes at [0] — smoke exit 1,
//       but on a STATE pin on the line AFTER the positional read, naming
//       neither the reader, nor the index, nor the fixture file: an accidental
//       bystander catch.
//   (B) the FAITHFUL replay — one row inserted MID-ARRAY in `fleet-cruel-content`,
//       changing which row the kind-neighbour `.find()` returns — smoke exit 0
//       (all 101 scenarios rendered), breakpoint-sweep exit 0, the cruel leg
//       exit 0 while VISIBLY printing its counts moving.
//   (C) the kind control made cruel — exit 0.
// 0-for-3 on the defect class, and (A)'s single catch was a bystander. A census
// keyed on NAMES cannot see a CONTENT edit that moves no name, so building one
// would ship a guard that is green by construction — the epic's own fourth
// clause. The pins below key on the VALUE a reader depends on instead.
//
// EXPLICITLY EXCLUDED, and not a gap: `exp.fleetRowsEqualFixture`'s
// `const want = SCENARIOS[name].data.barkparks.length` — it DERIVES BOTH SIDES
// from the same fixture (the render it counts is produced from that array), so
// no fixture edit can ever red it, and that is CORRECT for its actual job of
// proving the RENDER drops a row. Pinning it would pin a tautology.
const FIXTURE_SHAPE_PINS = [
  {
    scenario: "account-modal",
    path: "me.user.two_factor_enabled",
    expected: false,
    why: 'EXPECTATIONS["account-modal"].check feeds this fixture straight into hooks.accountModel and then asserts the OFF anatomy (a2f-badge reads Off, a2f-start offered, a2f-otp absent). An enrolled fixture makes every one of those assertions a statement about the wrong state',
  },
  {
    scenario: "account-modal-2fa-on",
    path: "me.user.two_factor_enabled",
    expected: true,
    why: 'EXPECTATIONS["account-modal-2fa-on"].check asserts the ON-row (a2f-regen, a2f-disable, never a2f-start) is DERIVED from /v1/me alone with zero extra fetches — the fixture is the only thing that can carry the on-state',
  },
  {
    scenario: "account-modal-2fa-badcode",
    path: "me.user.two_factor_enabled",
    expected: false,
    why: 'EXPECTATIONS["account-modal-2fa-badcode"].check opens the modal shell around an ENROLL panel; an already-enrolled fixture renders the on-row instead, and the rejection copy would be asserted against a shell that never offers enrollment',
  },
  {
    scenario: "account-modal-tall",
    path: "accountSessions.length",
    expected: 9,
    why: 'EXPECTATIONS["account-modal-tall"].check maps this array to session rows and pins 9 rows / 8 revokes / Log out BELOW the last row — the tall shape is the whole scenario, and a short fixture makes the strand-the-footer proof vacuous',
  },
  {
    scenario: "fleet-cruel-content",
    path: "barkparks.length",
    expected: 3,
    why: 'EXPECTATIONS["fleet-cruel-content"].check reads three DISTINCT rows out of this array by intent (the cruel host, the single-token provision error, the kind neighbour) and asserts all three render in ONE DOM — this is the array wave 23 broke by inserting a row',
  },
  {
    scenario: "fleet-cruel-content",
    path: "barkparks.#longerThan(custom_host,200)",
    expected: 1,
    why: 'the `cruel` reader is rows.find((b) => b.custom_host && b.custom_host.length > 200) — a SECOND over-long custom_host makes that find silently arbitrary, and every length assertion after it (253 at the validate_length cap) would be about whichever row happened to come first',
  },
  {
    scenario: "fleet-cruel-content",
    path: "barkparks.#longerThan(provision_error,200)",
    expected: 1,
    why: 'the `tokenRow` reader is rows.find((b) => b.provision_error && b.provision_error.length > 200); a second one makes the unbroken-token and verbatim-paint assertions pick a row nobody chose',
  },
  {
    scenario: "fleet-cruel-content",
    path: "barkparks.#with(host)",
    expected: 2,
    why: 'the `kind` reader is rows.find((b) => b !== cruel && b.host) — the cruel row carries a host of its own, so exactly ONE OTHER host-bearing row makes that find unambiguous. THIS IS THE WAVE-23 DEFECT PINNED: inserting a third host-bearing row changes the kind neighbour\'s identity, and the whole harness stayed green while it did',
  },
  {
    scenario: "panel-overview",
    path: "barkparks.length",
    expected: 1,
    why: 'the ONE surviving positional index in this file — const bp = SCENARIOS["panel-overview"].data.barkparks[0] — and every teardown count after it (fleet 1 -> 0, exactly one DELETE, the toast naming bp.name) is arithmetic on a single-instance fleet',
  },
  {
    scenario: "timeline-coalesced",
    path: "instanceEvents.#keys",
    expected: 1,
    why: 'EXPECTATIONS["timeline-coalesced"].check takes Object.values(d.instanceEvents)[0] — with a second instance keyed in, that [0] picks by insertion order and the coalescing grammar is asserted over whichever feed happened to be first',
  },
  {
    scenario: "timeline-coalesced",
    path: "instanceEvents.#values0.#eq(type,health)",
    expected: 10,
    why: 'the same check pins "&times; 10", ">Show all 10<" and 14 open rows (10 members + status + tls + 2 audit) — the 10 is the health burst\'s size, read from this fixture and typed into the assertions',
  },
  {
    scenario: "timeline-coalesced",
    path: "audit.length",
    expected: 2,
    why: 'the 14-row expanded count in that same check is 10 + 1 + 1 + THESE two audit rows; an audit edit moves the total and reds a row-count assertion that names none of this',
  },
  // cch-w24-s7 — THE SITES ARRAY HAD NO PIN AT ALL, and it is the one fixture
  // TWO scenarios read through TWO different row builders. Driven before these
  // five existed, adding a single row to `sitesListRows` produced exactly two
  // prose lines — "FAIL sites — one v4 density row per fixture site" and "FAIL
  // sites-on-instance — one instance row per fixture site" — naming no count, no
  // path, no fixture file and no reader; and because `assert.equal` throws on
  // the FIRST of five integers, the next four were met one run apiece, five runs
  // deep. These pins move that refusal to before any scenario boots and name all
  // of it at once.
  {
    scenario: "sites",
    path: "sites.length",
    // cch-w64-s6: 7 → 8, the deferred head row (acme-media).
    expected: 8,
    why: 'EXPECTATIONS["sites"].check pins the row count TWICE (countMatches over site-row--global, then the length of the split) and every per-row filter after it is arithmetic on this array — and `sites-on-instance` reads the SAME array through the other builder, so one appended row reds two scenarios that name neither the array nor each other',
  },
  {
    scenario: "sites",
    path: "sites.#eq(current_deployment_id,null)",
    expected: 2,
    why: 'the never-served population: the same check asserts exactly two rows read "Not deployed" AND that each of them offers no site-open door, and it names acme-labs and acme-previews in its message — a third null-pointered row makes that message a lie about which rows it measured',
  },
  {
    scenario: "sites",
    path: "sites.#with(current_deployment_id)",
    // cch-w64-s6: 5 → 6. A deferral does not tear down what is already serving,
    // so the deferred row keeps its pointer and its door.
    expected: 6,
    why: 'the served population: siteHasEverDeployed reads current_deployment_id and NOTHING else, so this count IS the number of site-open doors and the number of title="Open the live site" anchors the check pins — including cch-w24-s7\'s cruel row, whose 253-char host is only worth rendering because it kept its door',
  },
  {
    scenario: "sites-on-instance",
    path: "sites.length",
    // cch-w64-s6: 7 → 8, the same shared array through the other row builder.
    expected: 8,
    why: 'the instance Sites card renders the SAME sitesListRows through siteRow, and its check reds FIRST on rows.length — pinning it here means an edit to the shared array is named as a shape change once, rather than discovered separately by each builder',
  },
  {
    scenario: "sites-on-instance",
    path: "sites.#with(current_deployment_id)",
    // cch-w64-s6: 5 → 6, the deferred row's door through the compact builder.
    expected: 6,
    why: 'the same served population through the compact builder: the check pins countMatches(body, class="site-open") to it, and siteRow has no status pill for a never-served site, so this count is the ONLY thing standing between a door-gating regression and a silent pass',
  },
  {
    scenario: "fleet-support-online",
    path: "barkparks.#eq(fleet_role,support)",
    expected: 1,
    why: 'EXPECTATIONS["fleet-support-online"].check reads .find((b) => b.fleet_role === "support") and renders the presence slot for it; a second support row makes the Online chip and the 1/1-slots capacity a statement about an arbitrary member',
  },
];

// The path grammar, deliberately tiny — a dotted property walk plus four
// counting segments, because what a reader depends on is usually a COUNT of
// rows with a property, not a scalar buried at a fixed index:
//   #keys                   Object.keys(x).length
//   #values0                Object.values(x)[0]   (mirrors a reader that does the same)
//   #with(prop)             array elements whose prop is truthy
//   #eq(prop,value)         array elements whose String(prop) === value
//   #longerThan(prop,n)     array elements whose prop is a string longer than n
function readPinPath(root, pathStr) {
  let cur = root;
  for (const seg of pathStr.split(".")) {
    if (cur === undefined || cur === null) return { missing: true, at: seg };
    if (seg === "#keys") { cur = Object.keys(cur).length; continue; }
    if (seg === "#values0") { cur = Object.values(cur)[0]; continue; }
    const withM = /^#with\(([\w$]+)\)$/.exec(seg);
    if (withM) { cur = (cur || []).filter((e) => e && e[withM[1]]).length; continue; }
    const eqM = /^#eq\(([\w$]+),(.*)\)$/.exec(seg);
    if (eqM) { cur = (cur || []).filter((e) => e && String(e[eqM[1]]) === eqM[2]).length; continue; }
    const lenM = /^#longerThan\(([\w$]+),(\d+)\)$/.exec(seg);
    if (lenM) {
      cur = (cur || []).filter((e) => e && typeof e[lenM[1]] === "string" && e[lenM[1]].length > Number(lenM[2])).length;
      continue;
    }
    cur = cur[seg];
  }
  return { value: cur };
}

// Runs BEFORE any scenario, like the census, and exits non-zero on its own —
// the point is that the edit is named at the top of the run, not that some
// downstream assertion eventually notices.
function assertFixtureShapePins() {
  const broken = [];
  for (const pin of FIXTURE_SHAPE_PINS) {
    const scen = SCENARIOS[pin.scenario];
    if (!scen) {
      broken.push("SHAPE PIN: scenario " + JSON.stringify(pin.scenario) + " no longer exists — the reader it fences " +
        "is either gone or now asserting against the DEFAULT fixture");
      continue;
    }
    const got = readPinPath(scen.data, pin.path);
    if (got.missing) {
      broken.push("SHAPE PIN: " + pin.scenario + ".data." + pin.path + " — the path went undefined at " +
        JSON.stringify(got.at) + ", pinned " + JSON.stringify(pin.expected) + "\n    reader: " + pin.why);
      continue;
    }
    if (got.value !== pin.expected) {
      broken.push("SHAPE PIN: " + pin.scenario + ".data." + pin.path + " is " + JSON.stringify(got.value) +
        ", pinned " + JSON.stringify(pin.expected) + "\n    reader: " + pin.why);
    }
  }
  if (!broken.length) return true;
  process.stdout.write(
    "\nFIXTURE SHAPE: " + broken.length + " committed reader assumption(s) no longer hold. The fixtures live in " +
    "cloud/priv/static/__preview__/scenarios.mjs; each line below names the READER that depends on the shape you " +
    "changed. Fix the reader or restore the shape — do not delete the pin:\n  " + broken.join("\n  ") + "\n");
  return false;
}

// ── cch-w49-s1 · THE MONEY SCREEN'S ABSENT-ARM GUARD ─────────────────────────
// An ABSENT-arm assertion, not a presence one: it asserts the billing surface
// states NO currency numeral and NO instance-count numeral, on every actor who
// can reach it. It exists because the console used to state $0/$69/$499 and
// 1/3/10 managed instances as FACT under a button that opens a real Stripe
// session, with nothing server-side those numbers could ever be checked against
// — no amount exists in the tree at all (STRIPE_PRICE_* are price IDs, not
// amounts), and the ceiling is not fetched on this screen by ANY billing actor.
// The remedy was to OMIT, so the guard that can lose is one that reds the
// moment a numeral comes back.
//
// WHY IT IS A GUARD AND NOT A NEW SCENARIO: it needs no fixture — it re-reads
// the corpus that already exists. The scenario set is DERIVED from the corpus
// (`deepLink === "#billing"`), so a seventh billing actor is covered on the day
// it is minted rather than on the day someone remembers this file.
//
// THE TWO WAYS THIS COULD HAVE BEEN A FALSE GREEN, both refused below:
//   • an EMPTY corpus slice — if a deepLink is renamed the filter would answer
//     [] and an assertion over nothing passes, so the count is floored (6, the
//     set derived by running: billing-trial, billing-past-due,
//     billing-portal-return, billing-member, billing-me-unreadable,
//     billing-cancelling);
//   • an EMPTY container — a mount that moved would leave both ids blank and
//     "no numeral" would be trivially true, so the union must be non-empty for
//     every actor.
// The container union {#billing-recommended, #billing-tiers} was derived by
// scanning the ENTIRE registry of all six booted actors for either numeral, not
// from a named list: billing-trial carries it in #billing-tiers, the other five
// in #billing-recommended, and NO third id carries one. A guard scoped to
// #billing-tiers alone would have covered 1 actor of 6.
//
// It reads innerHTML STRINGS deliberately: this shim's parse is FLAT and its
// document-level querySelectorAll hard-returns [], so a selector-shaped
// assertion here matches nothing and passes vacuously. And it does NOT open the
// grid with a #plan-more click: renderBilling repaints #billing-recommended
// 4-5x per boot while the registry hands back the same node, so listeners
// accumulate and an even count makes the toggle dead — a click-opened grid
// measures the harness, not the app.
const MONEY_CURRENCY_RE = /\$\s?\d[\d,]*/;
const MONEY_CEILING_RE = /\b\d+\s+managed instances?\b/;
const MONEY_CONTAINERS = ["billing-recommended", "billing-tiers"];

async function assertBillingStatesNoNumeralItCannotSupport() {
  const names = SCENARIO_NAMES.filter((n) => (SCENARIOS[n].deepLink || "") === "#billing");
  const broken = [];
  if (names.length < 6) {
    broken.push("only " + names.length + " scenario(s) deep-link #billing (6 are committed) — the corpus slice this " +
      "guard reads has shrunk, and an assertion over a shrunken slice is a false green, not a pass");
  }
  for (const name of names) {
    const boot = bootScenario(name, {});
    await flush();
    // The parts are filtered BEFORE joining, deliberately: joining two empty
    // strings yields "\n", which is truthy, and an emptiness test against that
    // can never fire — measured, by moving both ids and watching this guard
    // pass. The vacuity arm below only works over the filtered union.
    const parts = MONEY_CONTAINERS.map((id) => {
      const el = boot.registry.get(id);
      return (el && typeof el.innerHTML === "string" ? el.innerHTML : "") || "";
    }).filter(Boolean);
    const union = parts.join("\n");
    if (!union) {
      broken.push(name + ": both " + MONEY_CONTAINERS.map((i) => "#" + i).join(" and ") + " rendered EMPTY — the " +
        "billing surface moved, so \"states no numeral\" is vacuously true here rather than proven");
      continue;
    }
    const cur = union.match(MONEY_CURRENCY_RE);
    const ceil = union.match(MONEY_CEILING_RE);
    if (cur || ceil) {
      broken.push(name + ": the billing surface STATES " +
        [cur ? "a price " + JSON.stringify(cur[0]) : null,
         ceil ? "a ceiling " + JSON.stringify(ceil[0]) : null].filter(Boolean).join(" and ") +
        " — no server value backs either one (no amount exists in the tree; the ceiling is never fetched on this " +
        "screen), so the console must state the tier, the features and the CTA, and state no number");
    }
  }
  process.stdout.write(
    "  " + (broken.length ? "FAIL" : "ok  ") + " billing-numerals — " + names.length +
    " #billing actor(s) × " + MONEY_CONTAINERS.length + " container(s): " +
    (broken.length ? broken.length + " stating a numeral no server value supports" : "no unsupported numeral stated") + "\n");
  if (broken.length) {
    process.stdout.write("\nbilling absent-arm guard failed:\n  " + broken.join("\n  ") + "\n");
    process.exit(1);
  }
}
// cch-w46-s7 — this call moved into main() too (see the note at the late-/v1/me
// guard). Both harness-capability guards keep their original ORDER relative to
// each other and to the corpus: late-/v1/me, then billing-numerals, then the
// census guard and the scenarios.

async function main() {
  await assertLateMeRepaintsTheRail();
  await assertBillingStatesNoNumeralItCannotSupport();
  await assertTeamSwitcherListsTheTeamsTheEnvelopeNames();
  if (!assertCensus()) {
    process.stdout.write("\ncensus guard failed — every scenario needs an expectation, both ways\n");
    process.exit(1);
  }
  if (!assertFixtureShapePins()) {
    process.stdout.write("\nfixture-shape guard failed — a fixture edit invalidated a reader, named above\n");
    process.exit(1);
  }
  const names = Object.keys(EXPECTATIONS);
  let failed = 0;
  for (const name of names) {
    try {
      const what = await runScenario(name);
      process.stdout.write("  ok   " + name.padEnd(14) + " — " + what + "\n");
    } catch (e) {
      failed++;
      process.stdout.write("  FAIL " + name.padEnd(14) + " — " + (e && e.message) + "\n");
    }
  }
  process.stdout.write(
    (failed ? "\n" + failed + " scenario(s) failed\n" : "\nall " + names.length + " scenarios rendered\n"),
  );
  process.exit(failed ? 1 : 0);
}

// ── the module boundary (cch-w46-s7) ─────────────────────────────────────────
// smoke.mjs is now BOTH an entry point and a HOST: member-authority-sweep.mjs
// imports bootScenario/flush to read the rendered bytes of the same corpus
// instead of re-implementing a second DOM shim that could drift from this one.
// Two properties are load-bearing and both are asserted by the sweep's own
// import-silence probe:
//   1. `node smoke.mjs` behaves EXACTLY as before — same lines, same order,
//      same exit code.
//   2. `import("./smoke.mjs")` runs NOTHING and writes ZERO bytes. That is not
//      the guard below alone: the two harness guards above had to move inside
//      main(), because a top-level `await` executes at import time no matter
//      what guards the tail call.
export { bootScenario, makeDom, flush };

// Importable (the sweep imports the boot half) — only run when executed.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
