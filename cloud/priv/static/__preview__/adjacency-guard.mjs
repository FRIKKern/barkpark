// adjacency-guard.mjs — is a DESTROY-TIER control rendered directly beneath (or
// directly above) a PRIMARY action at the same edge?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (charter D815, row cch-w67-bl-a-destructive-control-under-a-
//  primary-action-is-untested)
// ─────────────────────────────────────────────────────────────────────────────
//  The cch-w67 crown put the site's Delete in the detail head's `.fleet-badges`
//  row. That row is `flex-wrap: wrap; justify-content: flex-end`, so above a
//  certain width it wraps and lands Delete a misclick's distance directly under
//  the primary Deploy at the SAME RIGHT EDGE. D815 accepted that as a known
//  cost and FILED the missing gate, because no instrument in this repo asks the
//  question: overflow-guard measures spill, breakpoint-sweep measures layout
//  drift, cssom-parity measures rule heads, modal-oracle measures one dialog.
//  None of them can tell a person that the button which destroys their site is
//  8px below the button which deploys it.
//
//  A geometry nothing measures is a geometry that drifts. This file measures it.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHAT A "DESTROY-TIER CONTROL" IS, AND WHY IT IS NOT A LIST
// ─────────────────────────────────────────────────────────────────────────────
//  app.js ships three confirm tiers (confirmModalInit): `mutate`, `danger` and
//  `destroy`. Only `destroy` renders the TYPED-NAME ECHO — the `.cm-typed-field`
//  with its `#cm-typed` input and the `.cm-name` the person must retype — and
//  `btn-danger` alone does NOT mean destroy: a rollback is `btn-danger` weight
//  with no echo at all (the DANGER-NO-ECHO tier, app.js's own GR41 note).
//
//  So the population is DERIVED, twice, and both derivations are printed:
//
//   (a) FROM THE SOURCE, at boot: the `btn-danger` class occurrences in
//       cloud/priv/static/app.js and the `tier: "destroy"` echo call sites in
//       the same file. These are the CANDIDATE ceiling and the reason this file
//       can refuse before a browser is spawned. A source that carries ZERO of
//       either is a source this guard has nothing to say about — exit 2, never
//       a green.
//
//   (b) IN THE BROWSER, by gesture: every `button.btn-danger` painted inside
//       the visible `section.view` is CLICKED on a fresh document, and it is
//       destroy-tier if and only if the dialog it opens carries the typed echo.
//       Nothing here reads a hand-maintained roster; a control that stops being
//       destroy-tier drops out of the measurement and the count printed on the
//       run changes, which is the point.
//
//  THE NON-VACUITY FLOOR. A run that classifies ZERO destroy-tier controls has
//  measured nothing, and a guard that greens on nothing is worse than no guard.
//  Both the source floor (a) and the rendered floor (b) REFUSE at exit 2, and
//  every route additionally declares the count it OWES (`destroyMin`) so a
//  screen that quietly stops painting its destroy control reds instead of
//  silently shrinking the population.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE PREDICATE
// ─────────────────────────────────────────────────────────────────────────────
//  A destroy-tier control D and a primary action P (`.btn-primary`, the
//  console's one primary weight) are ADJACENT when all three hold:
//
//    1. SAME EDGE      — |D.right - P.right| <= EDGE_TOL, or
//                        |D.left  - P.left|  <= EDGE_TOL.
//                        The shared edge is what makes the two buttons read as
//                        one column to a hand travelling down the screen.
//    2. STACKED        — their boxes do not overlap vertically, and they
//                        overlap HORIZONTALLY by more than zero: one is
//                        genuinely above the other, not beside it.
//    3. WITHIN REACH   — the vertical gap between the near edges is
//                        <= GAP_MAX. Measured on the D815 geometry the gap is
//                        single-digit pixels; a 24px ceiling is a deliberate
//                        misclick budget and not a measurement of one screen.
//
//  BOTH DIRECTIONS ARE MEASURED. A destroy control directly ABOVE a primary is
//  the same misclick with the thumb travelling the other way, and a predicate
//  that only looks down is a predicate a re-order defeats.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE ALLOWLIST — NAMED, REASONED, AND UNABLE TO GO STALE
// ─────────────────────────────────────────────────────────────────────────────
//  ALLOWED below carries the D815 pair and the charter's own measured reason.
//  It is not an exemption in the usual sense, because an entry that stops
//  matching is itself a FAILURE (the FLEET_KNOWN precedent in overflow-guard):
//  an allowlist that can never go stale is an allowlist that forgives the next
//  drift. Every allowed pair that fires PRINTS its reason on the run, so a
//  reader of a green run still learns the geometry is there.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node cloud/priv/static/__preview__/adjacency-guard.mjs
//    ROUTE=site-rollback node cloud/priv/static/__preview__/adjacency-guard.mjs
//    THEME=dark node cloud/priv/static/__preview__/adjacency-guard.mjs
//
//  Env: ROUTE (comma-list of the declared route names) · THEME (light|dark) ·
//       CHROME (binary override) · PORT (preview port; default = a free port).
//
//  Exit codes: 0 = every cell clean · 1 = a MEASURED adjacency defect ·
//              2 = REFUSED to measure (no Chrome, a stale server, a font pin
//              that would not take, an unknown ROUTE/THEME, or a population
//              floor that came back empty). 1 is a claim about the console; 2
//              is the ABSENCE of a claim, and the two must never be confused.
//
//  WIRED INTO CI: the `adjacency-guard` job in
//  .github/workflows/console-harness.yml, an upstream `needs:` of the REQUIRED
//  `Console gate` context, modelled on the `overflow-guard` job beside it.
//  Re-derive, do not trust:
//    git grep -nE '(node|bash|sh) .*adjacency-guard' -- .github/ scripts/ Makefile
// ─────────────────────────────────────────────────────────────────────────────

import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { SCENARIOS } from "./scenarios.mjs";
import { FONT_PIN_JS, fontPinRefusal } from "./font-pin.mjs";
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr, formatStderrTail } from "./bringup-retry.mjs";
import { createCrossDocumentNavigator } from "./same-document-nav-census.mjs";
// THE COMMITTED WIDTH AXIS, IMPORTED AND NEVER RETYPED. breakpoint-sweep.mjs
// DERIVES `WIDTHS` from app.css's own @media preludes (boundaryWalk over
// BREAKPOINTS: b-1, b, b+1 for each), and overflow-guard imports the same
// export. A copy here would be a second source of truth that rots the first
// time a breakpoint moves.
import { WIDTHS as SWEEP_WIDTHS } from "./breakpoint-sweep.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP_JS = path.join(HERE, "..", "app.js");

// ── THE WIDTHS ABOVE THE SWEEP'S CEILING ─────────────────────────────────────
// SWEEP_WIDTHS is a BOUNDARY walk, so it ends just past app.css's widest
// @media prelude (904) and cannot reach a defect that lives at a desktop width.
// The D815 geometry is measured at 1200 — above every breakpoint in the
// stylesheet, because the wrap is driven by the CONTENT of the badges row and
// not by a media query at all. A guard that stopped where the media queries
// stop would be blind to the very screen it was filed for, so these three are
// declared, reasoned, and printed beside the imported axis rather than folded
// into it.
const WIDE_WIDTHS = [960, 1000, 1024, 1040, 1100, 1200, 1440];
const WIDE_WHY =
  "D815's row names 1200 as the width where the site Delete wraps under Deploy. MEASURED HERE, " +
  "on `rollback` in both themes, it is NOT 1200: the pair is adjacent at 1000 (8px gap, same right " +
  "edge) and clean at 1200 and 1440. The band is bracketed rather than pinned to the row's number " +
  "precisely because that number did not reproduce — a single declared width would have measured " +
  "a clean cell and reported the geometry gone.";

const WIDTHS = [...SWEEP_WIDTHS, ...WIDE_WIDTHS];
const VIEW_H = Number(process.env.HEIGHT || 900);
const CENSUS_W = 1440; // the census runs unwrapped, so every control is painted

const VALID_THEMES = ["light", "dark"];

const INST = "5b2c1e00-0000-4000-8000-0000000000a1";
const SITE = "5b2c1e00-0000-4000-8000-0000000000c1";

// ── THE ROUTES ───────────────────────────────────────────────────────────────
// Each one declares the screen, how to know it LANDED, and the number of
// destroy-tier controls it OWES. `destroyMin` is the per-route anti-vacuity
// pin: a screen that stops painting its destroy control would otherwise shrink
// the population silently and take its adjacency assertions with it.
const ROUTES = [
  {
    name: "site-rollback",
    scen: "rollback",
    hash: `#site/${SITE}`,
    ready: ".detail-grid",
    destroyMin: 1,
    why: "the D815 screen: #site-delete and the primary #site-deploy share the .fleet-badges row.",
  },
  {
    name: "site-states",
    scen: "site-states",
    hash: `#site/${SITE}`,
    ready: ".detail-grid",
    destroyMin: 1,
    why: "the same head on a different corpus — a fixture-shaped green on site-rollback cannot buy this cell too.",
  },
  {
    name: "webhooks-panel",
    scen: "webhooks-panel",
    hash: `#instance/${INST}/webhooks`,
    ready: "[data-wh-new]",
    destroyMin: 1,
    why: "the SECOND destroy grammar: confirmDeleteWebhook hand-rolls its own typed echo instead of the confirm modal's, and it shares a toolbar with the primary [data-wh-new]. A guard that only knew the site head would have had one control and one shape.",
  },
  {
    name: "instance-detail",
    scen: "panel-overview",
    hash: `#instance/${INST}`,
    ready: ".detail-grid--instance",
    destroyMin: 0,
    why: "the instance's Decommission lives behind .inst-life-* and is authority-gated, so this route declares NO floor and reports what it finds; it is here for the PRIMARY population (#inst-open-studio) as much as for the destroy one.",
  },
];

// Geometry constants. Both are budgets, not measurements of one screen.
const EDGE_TOL = 2;
const GAP_MAX = 24;

// ── THE ALLOWLIST ────────────────────────────────────────────────────────────
// Keyed on the PAIR, never on the route: the site head renders on every site
// route, so a route-keyed entry would need re-stating per screen and would rot
// the first time a fourth route landed.
//
// `mustFire` is what stops this being a silent exemption: if the pair is never
// measured adjacent anywhere in the run, the entry has gone stale — either the
// geometry was fixed (delete the entry) or the control moved out of the
// measurement (which is the thing this guard exists to notice).
const ALLOWED = [
  {
    destroy: "#site-delete",
    primary: "#site-deploy",
    // The routes on which this entry's staleness can be judged. A narrowed run
    // (ROUTE=webhooks-panel) never visits the site head, and a mustFire that
    // fired on "the run did not look" would be an instrument that reds for the
    // operator's choice of scope rather than for a change in the console.
    mustFire: true,
    firesOn: ["site-rollback", "site-states"],
    reason:
      "charter D815, ACCEPTED as a known cost when the cch-w67 crown shipped, and NOT silently. " +
      "There is no zero-CSS placement that avoids it: `.deploys-head` is justify-content:space-between " +
      "and maroons the two buttons 186px apart (green on every gate, wrong on the screen), while " +
      "`.fleet-badges` groups them correctly and wraps. MEASURED BY THIS GUARD, the band is NOT the " +
      "1200 the row names: the pair is adjacent at 1000/1024/1040/1100 with an 8px gap at the same " +
      "right edge, and CLEAN at 960, 1200 and 1440 (both themes, both site routes). " +
      "The mitigation is the destroy tier's own TYPED-NAME ECHO: the confirm " +
      "cannot fire until the site's name is retyped exactly. This guard makes that trade VISIBLE on " +
      "every run instead of leaving it in a charter row nobody re-reads. Reversing it is a CHARTER " +
      "decision (and a new app.css rule invalidates the committed cssom-heads.baseline sidecar that " +
      "cssom-parity gates on), not a builder's unilateral edit.",
  },
];

// Caps (ms).
const SERVER_UP_CAP = 5000;
const DEVTOOLS_CAP = 15000;
const LAND_CAP = 12000;
const MODAL_CAP = 4000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const list = (v) => String(v).split(",").map((s) => s.trim()).filter(Boolean);

// ── 1. THE SOURCE-SIDE POPULATION, before anything is spawned ────────────────
// Grepped out of app.js's own bytes at run time. This is the CANDIDATE ceiling
// and the first floor: a source carrying no btn-danger controls, or no typed
// echo at all, is a source about which this guard has nothing to say.
function sourcePopulation() {
  let src;
  try {
    src = fs.readFileSync(APP_JS, "utf8");
  } catch (e) {
    return { error: `cannot read ${APP_JS}: ${e.message}` };
  }
  const dangerSites = (src.match(/btn-danger/g) || []).length;
  const echoSites = (src.match(/tier:\s*"destroy"/g) || []).length;
  // The echo's own markup, so a run can say WHICH string the browser half keys
  // on rather than asserting a class name that has drifted.
  const echoField = src.indexOf("cm-typed-field") !== -1;
  const echoInput = src.indexOf('id="cm-typed"') !== -1;
  return { dangerSites, echoSites, echoField, echoInput };
}

// ── 2. plumbing (shape shared with modal-oracle.mjs / overflow-guard.mjs) ────

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const p = srv.address().port;
      srv.close(() => resolve(p));
    });
  });
}

// The accessSync check covers the CHROME env branch too: console-harness.yml
// pins CHROME=/usr/bin/google-chrome, so on CI that is the ONLY branch taken,
// and an unchecked `return process.env.CHROME` makes the exit-2 guard below
// dead code — a runner image that drops the binary would then die with a raw
// ENOENT at exit 1, i.e. "a measured adjacency defect".
function findChrome() {
  if (process.env.CHROME) {
    try { fs.accessSync(process.env.CHROME, fs.constants.X_OK); return process.env.CHROME; }
    catch { return null; }
  }
  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* next */ }
  }
  return null;
}

function chromeGuardLine() {
  return process.env.CHROME
    ? `!! GUARD (exit 2): CHROME=${process.env.CHROME} is not an executable file. Environment refusal, not an adjacency defect.\n`
    : "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n";
}

function httpOk(url) {
  return new Promise((resolve) => {
    const req = http.get(url, (res) => { res.resume(); resolve(res.statusCode === 200); });
    req.on("error", () => resolve(false));
    req.setTimeout(1000, () => { req.destroy(); resolve(false); });
  });
}

// A minimal CDP client over native WebSocket, flat sessions.
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id == null) return;
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.method + ": " + JSON.stringify(msg.error)));
      else p.resolve(msg.result);
    });
    ws.addEventListener("close", () => {
      for (const [, p] of this.pending) p.reject(new Error("CDP socket closed"));
      this.pending.clear();
    });
  }
  static async connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener("open", resolve, { once: true });
      ws.addEventListener("error", () => reject(new Error("CDP connect failed: " + wsUrl)), { once: true });
    });
    return new Cdp(ws);
  }
  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    const frame = { id, method, params };
    if (sessionId) frame.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject: (e) => reject(Object.assign(e, { method })) });
      try { this.ws.send(JSON.stringify(frame)); }
      catch (e) { this.pending.delete(id); reject(e); }
    });
  }
  close() { try { this.ws.close(); } catch { /* already gone */ } }
}

// ── 3. the page-side halves ──────────────────────────────────────────────────

// A stable selector for one element, preferring what a person would grep for.
const SEL_OF_JS = `
  function selOf(el) {
    if (!el) return null;
    if (el.id) return "#" + el.id;
    var attrs = el.attributes || [];
    for (var i = 0; i < attrs.length; i++) {
      var a = attrs[i];
      if (a.name.indexOf("data-") === 0) {
        return a.value ? "[" + a.name + "=\\"" + a.value + "\\"]" : "[" + a.name + "]";
      }
    }
    var cls = (el.className && typeof el.className === "string")
      ? "." + el.className.trim().split(/\\s+/).join(".") : el.tagName.toLowerCase();
    var sibs = el.parentElement ? Array.prototype.slice.call(el.parentElement.children) : [];
    return cls + ":nth-child(" + (sibs.indexOf(el) + 1) + ")";
  }
`;

// The visible view, and every btn-danger painted inside it. `#modal-root` is
// deliberately NOT walked: the confirm dialog's own Confirm button is
// btn-danger by construction and sits beside a Cancel, which is neither a
// primary action nor a page geometry.
const CENSUS_JS = `(function () {
  ${SEL_OF_JS}
  var view = document.querySelector("section.view:not([hidden])");
  if (!view) return { view: null, controls: [] };
  var out = [];
  var bs = view.querySelectorAll("button.btn-danger, a.btn-danger");
  for (var i = 0; i < bs.length; i++) {
    var r = bs[i].getBoundingClientRect();
    out.push({ i: i, sel: selOf(bs[i]), label: (bs[i].textContent || "").trim().slice(0, 40),
               painted: r.width > 0 && r.height > 0 });
  }
  return { view: view.id, controls: out };
})()`;

// Click the i-th btn-danger of the visible view. Returns false when the index
// no longer resolves, so a census that has gone stale refuses rather than
// silently classifying the wrong control.
function clickJs(i) {
  return `(function () {
    var view = document.querySelector("section.view:not([hidden])");
    if (!view) return false;
    var bs = view.querySelectorAll("button.btn-danger, a.btn-danger");
    if (!bs[${i}]) return false;
    bs[${i}].click();
    return true;
  })()`;
}

// THE TYPED-NAME ECHO, as the browser can see it — KEYED ON SHAPE, NOT ON A
// NAME. The first draft of this probe asked for `#cm-typed`, the confirm-modal
// grammar's own input id, and it was WRONG in the safe-looking direction:
// `confirmDeleteWebhook` in app.js hand-rolls the same contract with its own
// `#wh-del-confirm` input and its own disabled `#wh-del-go`, so a name-keyed
// probe classified a genuine destroy-tier control as `danger` and dropped it
// out of the population silently. A population that shrinks without saying so
// is the exact failure this file's floors exist to catch, and an id is a name.
//
// The SHAPE both grammars share, and which `danger` (a rollback) has none of:
//   a text input inside the open dialog, AND a btn-danger confirm that ships
//   DISABLED — i.e. the destroy cannot fire until something is typed.
// `grammar` reports WHICH of the two produced it, so a run still says where a
// control's echo comes from without the predicate depending on that answer.
const ECHO_PROBE = `(function () {
  var r = document.getElementById("modal-root");
  if (!r || r.hidden) return null;
  var card = r.querySelector(".modal-card");
  if (!card) return null;
  var inputs = card.querySelectorAll("input[type=text], input:not([type])");
  var dangers = card.querySelectorAll("button.btn-danger");
  var lockedDanger = false;
  for (var i = 0; i < dangers.length; i++) { if (dangers[i].disabled) lockedDanger = true; }
  var cmName = card.querySelector(".cm-name");
  return {
    typedInput: inputs.length > 0,
    lockedDanger: lockedDanger,
    grammar: card.querySelector("#cm-typed") ? "confirmModal" : (inputs.length && lockedDanger ? "bespoke" : null),
    name: cmName ? (cmName.textContent || "").trim() : null,
    dangerCount: dangers.length
  };
})()`;

// The measurement. Takes the destroy-tier selector set derived by the census
// pass and reports EVERY pair it judged — adjacent or not — so a green run is
// readable without re-running it.
function measureJs(destroySels, cfg) {
  return `(function () {
    ${SEL_OF_JS}
    var DESTROY = ${JSON.stringify(destroySels)};
    var EDGE_TOL = ${cfg.edgeTol}, GAP_MAX = ${cfg.gapMax};
    var out = { view: null, destroys: [], primaries: 0, pairs: [], notes: [] };
    var view = document.querySelector("section.view:not([hidden])");
    if (!view) { out.notes.push("no visible section.view"); return out; }
    out.view = view.id;

    function box(el) {
      var r = el.getBoundingClientRect();
      return { l: r.left, r: r.right, t: r.top, b: r.bottom, w: r.width, h: r.height };
    }
    function painted(b) { return b.w > 0 && b.h > 0; }

    var ds = [];
    for (var s = 0; s < DESTROY.length; s++) {
      var els = view.querySelectorAll(DESTROY[s]);
      for (var e = 0; e < els.length; e++) {
        var b = box(els[e]);
        if (!painted(b)) continue;
        ds.push({ sel: DESTROY[s], box: b });
      }
    }
    out.destroys = ds.map(function (d) {
      return { sel: d.sel, x: Math.round(d.box.l) + ".." + Math.round(d.box.r),
               y: Math.round(d.box.t) + ".." + Math.round(d.box.b) };
    });

    var ps = [];
    var pels = view.querySelectorAll(".btn-primary");
    for (var p = 0; p < pels.length; p++) {
      var pb = box(pels[p]);
      if (!painted(pb)) continue;
      ps.push({ sel: selOf(pels[p]), box: pb });
    }
    out.primaries = ps.length;

    for (var i = 0; i < ds.length; i++) {
      for (var j = 0; j < ps.length; j++) {
        var D = ds[i].box, P = ps[j].box;
        var sameRight = Math.abs(D.r - P.r) <= EDGE_TOL;
        var sameLeft = Math.abs(D.l - P.l) <= EDGE_TOL;
        if (!sameRight && !sameLeft) continue;
        var hOverlap = Math.min(D.r, P.r) - Math.max(D.l, P.l);
        if (hOverlap <= 0) continue;
        var vOverlap = Math.min(D.b, P.b) - Math.max(D.t, P.t);
        if (vOverlap > 0) continue; // side by side, or overlapping — not a stack
        var below = D.t >= P.b;
        var gap = below ? (D.t - P.b) : (P.t - D.b);
        if (gap > GAP_MAX) continue;
        out.pairs.push({
          destroy: ds[i].sel, primary: ps[j].sel,
          edge: sameRight ? "right" : "left",
          edgeDelta: Math.round((sameRight ? D.r - P.r : D.l - P.l) * 100) / 100,
          direction: below ? "below" : "above",
          gap: Math.round(gap * 100) / 100,
          hOverlap: Math.round(hOverlap),
          destroyBox: Math.round(D.t) + ".." + Math.round(D.b) + " @ x" + Math.round(D.l) + ".." + Math.round(D.r),
          primaryBox: Math.round(P.t) + ".." + Math.round(P.b) + " @ x" + Math.round(P.l) + ".." + Math.round(P.r)
        });
      }
    }
    return out;
  })()`;
}

// ── 4. the run ───────────────────────────────────────────────────────────────

function rosterGuard() {
  const names = process.env.ROUTE ? list(process.env.ROUTE) : ROUTES.map((r) => r.name);
  const themes = process.env.THEME ? list(process.env.THEME) : ["dark"];
  const problems = [];
  if (!names.length) problems.push("ROUTE is set but empty");
  for (const n of names) {
    if (!ROUTES.some((r) => r.name === n)) {
      problems.push(`unknown ROUTE "${n}" — expected one of: ${ROUTES.map((r) => r.name).join(", ")}`);
    }
  }
  if (!themes.length) problems.push("THEME is set but empty");
  for (const t of themes) {
    if (!VALID_THEMES.includes(t)) problems.push(`unknown THEME "${t}" — expected one of: ${VALID_THEMES.join(", ")}`);
  }
  for (const r of ROUTES) {
    if (!names.includes(r.name)) continue;
    if (!Object.prototype.hasOwnProperty.call(SCENARIOS, r.scen)) {
      problems.push(`route "${r.name}" names scenario "${r.scen}", which is not a key of scenarios.mjs → SCENARIOS`);
    }
  }
  if (problems.length) {
    process.stderr.write("!! ROSTER GUARD (exit 2) — refusing to boot Chrome:\n");
    for (const p of problems) process.stderr.write("   • " + p + "\n");
    process.stderr.write(
      "   Why before the spawn: an unknown ?scen= still paints a real console on a fallback\n" +
      "   corpus, so a typo measures the right geometry on the WRONG screen and exits 0.\n");
    process.exit(2);
  }
  return { routes: ROUTES.filter((r) => names.includes(r.name)), themes };
}

async function main() {
  const { routes, themes } = rosterGuard();

  // ── THE SOURCE FLOOR, before a browser exists ──────────────────────────────
  const pop = sourcePopulation();
  if (pop.error) {
    process.stderr.write(`!! GUARD (exit 2): ${pop.error}\n`);
    process.exit(2);
  }
  process.stdout.write(
    `>> source population (grepped from cloud/priv/static/app.js at run time, NOT a committed list)\n` +
    `   btn-danger occurrences: ${pop.dangerSites} · tier:"destroy" echo call sites: ${pop.echoSites}\n` +
    `   typed-echo markup present: .cm-typed-field=${pop.echoField} #cm-typed=${pop.echoInput}\n`);
  if (pop.dangerSites === 0 || pop.echoSites === 0 || !pop.echoInput) {
    process.stderr.write(
      `\n!! GUARD (exit 2): REFUSED TO MEASURE — the source population is EMPTY.\n` +
      `   btn-danger=${pop.dangerSites} tier:"destroy"=${pop.echoSites} #cm-typed=${pop.echoInput}.\n` +
      `   A run over zero candidate controls would print a clean sweep having asserted\n` +
      `   nothing about a single button. That is the false green this floor exists to stop.\n`);
    process.exit(2);
  }

  const chromeBin = findChrome();
  if (!chromeBin) { process.stderr.write(chromeGuardLine()); process.exit(2); }

  const port = Number(process.env.PORT || (await freePort()));
  let profile = null;
  const t0 = Date.now();
  const crossDoc = createCrossDocumentNavigator("adjacency-guard");

  let server = null;
  let chrome = null;
  let cdp = null;
  let teardownMs = 0;
  const findings = [];     // measured defects
  const allowedHits = [];  // allowed pairs that fired, printed on every run
  let cellsMeasured = 0;
  let destroyTotal = 0;

  const teardown = async () => {
    const td0 = Date.now();
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    const alive = (p) => { if (!p || p.pid == null) return false; try { process.kill(p.pid, 0); return true; } catch { return false; } };
    const reap = async (proc, label) => {
      if (!alive(proc)) return;
      try { proc.kill("SIGTERM"); } catch { /* gone */ }
      let waited = 0;
      while (alive(proc) && waited < TERM_POLL_CAP) { await sleep(50); waited += 50; }
      if (!alive(proc)) return;
      try { proc.kill("SIGKILL"); } catch { /* gone */ }
      waited = 0;
      while (alive(proc) && waited < KILL_POLL_CAP) { await sleep(50); waited += 50; }
      if (alive(proc)) {
        process.stderr.write(`!! TEARDOWN SHOUT: ${label} pid ${proc.pid} SURVIVED SIGKILL. Reap it: kill -9 ${proc.pid}\n`);
      }
    };
    await reap(chrome, "chrome");
    await reap(server, "serve.mjs");
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
    teardownMs = Date.now() - td0;
  };

  try {
    server = spawn(process.execPath, [path.join(HERE, "serve.mjs"), "--port", String(port)], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    const readServeStderr = captureStderr(server);
    let up = false;
    for (let w = 0; w < SERVER_UP_CAP; w += 100) {
      if (await httpOk(`http://127.0.0.1:${port}/`)) { up = true; break; }
      await sleep(100);
    }
    if (!up) {
      throw new Error(
        `preview server never answered on :${port} (port in use? node error?)\n` +
        formatStderrTail(readServeStderr(), { who: "serve.mjs" }).replace(/\n$/, ""));
    }
    // SERVED BYTES == DISK BYTES. "The port answers" is not "OUR server
    // answers": a foreign worktree's squatter makes the poll SUCCEED and every
    // cell below would judge another tree's geometry. Exit 2 BY HAND — the
    // enclosing catch maps a throw to exit 1, "a defect was measured", and a
    // squatted port measured nothing about this tree.
    for (const rel of ["app.css", "app.js"]) {
      const served = Buffer.from(await (await fetch(`http://127.0.0.1:${port}/${rel}`, { cache: "no-store" })).arrayBuffer());
      const disk = fs.readFileSync(path.join(HERE, "..", rel));
      if (!served.equals(disk)) {
        await teardown();
        process.stderr.write(`\n!! GUARD (exit 2): REFUSED TO MEASURE — STALE SERVER on :${port}.\n`);
        process.stderr.write(`   /${rel} served ${served.length} B but this tree's disk has ${disk.length} B.\n`);
        process.stderr.write(`   Find it: lsof -nP -iTCP:${port} -sTCP:LISTEN\n`);
        process.exit(2);
      }
    }
    process.stdout.write(`>> preview  http://127.0.0.1:${port}\n>> chrome   ${chromeBin}\n`);

    let attemptSpawnError = null;
    const brought = await bringUpChrome({
      label: "adjacency-guard",
      attempts: BRINGUP_ATTEMPTS,
      newProfile: () => fs.mkdtempSync(path.join(os.tmpdir(), "adjacency-guard-")),
      launch: (dir) => {
        attemptSpawnError = null;
        const child = spawn(chromeBin, [
          "--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
          "--no-first-run", "--no-default-browser-check", "--disable-extensions",
          "--disable-background-networking",
          `--user-data-dir=${dir}`, `--window-size=${CENSUS_W},${VIEW_H}`,
          "--remote-debugging-port=0", "about:blank",
        ], { stdio: ["ignore", "ignore", "pipe"] });
        child.on("error", (e) => { attemptSpawnError = e; });
        return { child, readStderr: captureStderr(child) };
      },
      awaitDevToolsPort: async ({ profile: dir }) => {
        const portFile = path.join(dir, "DevToolsActivePort");
        for (let w = 0; w < DEVTOOLS_CAP; w += 100) {
          if (attemptSpawnError) break;
          try {
            const raw = fs.readFileSync(portFile, "utf8").split("\n");
            if (raw[0] && Number(raw[0])) return Number(raw[0]);
          } catch { /* not written yet */ }
          await sleep(100);
        }
        if (attemptSpawnError) {
          throw new Error(`Chrome could not be executed (${attemptSpawnError.code || attemptSpawnError.message}): ${chromeBin}`);
        }
        return null;
      },
      abandon: async ({ profile: dir, child }) => {
        if (child && child.pid != null) { try { child.kill("SIGKILL"); } catch { /* gone */ } }
        try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
      },
      log: (s) => process.stderr.write(s),
    }).catch((err) => (err && err.refused ? { refusal: err } : Promise.reject(err)));

    if (brought.refusal) {
      await teardown();
      process.stderr.write(`\n!! GUARD (exit 2): REFUSED TO MEASURE — ${brought.refusal.message}\n`);
      process.stderr.write(`   Headless Chrome never came up, so NOT ONE cell was asserted.\n`);
      process.stderr.write(`   teardown ${teardownMs}ms\n`);
      process.exit(2);
    }
    chrome = brought.child;
    profile = brought.profile;
    const devPort = brought.devPort;

    const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    process.stdout.write(`>> ${version.Browser} · node ${process.version}\n`);
    // THE SCOPE OF THIS RUN, PRINTED WITH ITS RESULT (D906). Everything below
    // is measured in ONE engine. D168 asserted a cross-browser property off a
    // green like this one and stood for four waves until a hand-driven Firefox
    // refuted it (D904). browser-axis-census.mjs derives the engine from this
    // file's own discovery candidates and reds if this line disagrees with them.
    process.stdout.write(">> browser axis  Blink — 1 of 3 engine families (Blink · Gecko · WebKit). A green here is NOT a cross-browser green.\n");
    process.stdout.write(
      `>> widths ${WIDTHS.length}: ${SWEEP_WIDTHS.length} IMPORTED from breakpoint-sweep.mjs ` +
      `(${SWEEP_WIDTHS[0]}..${SWEEP_WIDTHS[SWEEP_WIDTHS.length - 1]}, derived from app.css's own @media preludes)\n` +
      `   + ${WIDE_WIDTHS.length} declared above its ceiling: ${WIDE_WIDTHS.join(", ")} — ${WIDE_WHY}\n` +
      `>> predicate: same edge within ${EDGE_TOL}px, boxes stacked (no vertical overlap, horizontal overlap > 0), gap <= ${GAP_MAX}px, BOTH directions\n\n`);

    cdp = await Cdp.connect(version.webSocketDebuggerUrl);
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Runtime.enable", {}, sessionId);

    const evalJs = async (expression, awaitPromise = false) => {
      const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise }, sessionId);
      if (r.exceptionDetails) throw new Error(`page expression threw: ${r.exceptionDetails.text}`);
      return r.result.value;
    };

    const goto = async (scen, theme, hash, w, h) => {
      await cdp.send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: false }, sessionId);
      const url = `http://127.0.0.1:${port}/?scen=${encodeURIComponent(scen)}&theme=${theme}${hash}`;
      await cdp.send("Page.navigate", { url: crossDoc.next(url) }, sessionId);
    };
    const poll = async (expression, cap) => {
      for (let w = 0; w < cap; w += 100) {
        const probe = await cdp.send("Runtime.evaluate", { expression, returnByValue: true }, sessionId).catch(() => null);
        if (probe && probe.result && probe.result.value === true) return true;
        await sleep(100);
      }
      return false;
    };
    const landed = (route) =>
      `(function(){var v=document.querySelector('section.view:not([hidden])');` +
      `return !!(v && v.querySelector(${JSON.stringify(route.ready)}));})()`;

    const pinFonts = async (label) => {
      const pin = await cdp.send("Runtime.evaluate", { expression: FONT_PIN_JS, returnByValue: true, awaitPromise: true }, sessionId)
        .catch((err) => ({ __cdpError: err }));
      const report = pin && pin.__cdpError === undefined && !pin.exceptionDetails ? pin.result.value : null;
      if (!report || !report.ok) {
        await teardown();
        process.stderr.write("\n!! GUARD (exit 2): " + fontPinRefusal(label, report) + "\n");
        process.stderr.write("   Every rect below is a layout of whatever face resolved, so the run REFUSES\n" +
                             "   rather than reporting a geometry it cannot attribute.\n");
        process.stderr.write(`   teardown ${teardownMs}ms\n`);
        process.exit(2);
      }
    };

    for (const route of routes) {
      for (const theme of themes) {
        // ── PHASE A: the rendered population, derived BY GESTURE ─────────────
        const censusLabel = `${route.name} · ${theme} · census@${CENSUS_W}`;
        await goto(route.scen, theme, route.hash, CENSUS_W, VIEW_H);
        if (!(await poll(landed(route), LAND_CAP))) {
          throw new Error(
            `${censusLabel}: the deep link never landed (${route.hash} → no "${route.ready}" in the visible view). ` +
            `Nothing about this route was measured — an unreached screen is not a clean screen.`);
        }
        await pinFonts(censusLabel);
        const census = await evalJs(CENSUS_JS);
        const candidates = census.controls.filter((c) => c.painted);

        const destroySels = [];
        const classified = [];
        for (const cand of candidates) {
          // A FRESH DOCUMENT PER GESTURE. A click that opens a dialog leaves
          // the page in a state the next click would be judged against, and a
          // control that navigates would take the rest of the census with it.
          await goto(route.scen, theme, route.hash, CENSUS_W, VIEW_H);
          if (!(await poll(landed(route), LAND_CAP))) {
            throw new Error(`${censusLabel}: the route stopped landing partway through the census gesture chain`);
          }
          const clicked = await evalJs(clickJs(cand.i));
          if (!clicked) {
            throw new Error(
              `${censusLabel}: btn-danger index ${cand.i} (${cand.sel}) no longer resolves on a fresh document — ` +
              `the census is unstable, so no classification can be trusted.`);
          }
          let echo = null;
          for (let w = 0; w < MODAL_CAP; w += 100) {
            echo = await evalJs(ECHO_PROBE);
            if (echo) break;
            await sleep(100);
          }
          const isDestroy = !!(echo && echo.typedInput && echo.lockedDanger);
          classified.push({ ...cand, isDestroy, echoName: echo ? echo.name : null,
                            grammar: echo ? echo.grammar : null, openedModal: !!echo });
          // DEDUPED: `[data-wh-delete]` is the selector of EVERY webhook row's
          // delete, so two rows classify to one selector. Pushing it twice
          // would double every box the measurement walks and inflate the
          // printed population into a number nothing in the DOM matches.
          if (isDestroy && !destroySels.includes(cand.sel)) destroySels.push(cand.sel);
        }
        destroyTotal += destroySels.length;

        process.stdout.write(
          `── ${route.name} · ${theme} — ${route.why}\n` +
          `   btn-danger painted in ${census.view}: ${candidates.length} · destroy-tier (typed echo present): ${destroySels.length}\n`);
        for (const c of classified) {
          process.stdout.write(
            `     ${c.isDestroy ? "DESTROY" : c.openedModal ? "danger " : "no-modal"} ${c.sel} "${c.label}"` +
            `${c.grammar ? ` · echo grammar ${c.grammar}` : ""}` +
            `${c.echoName ? ` · echo name "${c.echoName}"` : ""}\n`);
        }

        // PER-ROUTE ANTI-VACUITY. A screen that owes a destroy control and
        // paints none has taken its adjacency assertions with it, and the
        // widths below would sweep clean having judged nothing.
        if (destroySels.length < route.destroyMin) {
          findings.push(
            `${route.name}/${theme}: this route declares destroyMin=${route.destroyMin} and the census classified ` +
            `${destroySels.length} destroy-tier control(s) out of ${candidates.length} btn-danger painted. Every width ` +
            `below would have swept CLEAN having measured nothing. Either the screen stopped painting its destroy ` +
            `control, or the typed echo it opens stopped being a typed echo.`);
          continue;
        }
        if (destroySels.length === 0) {
          process.stdout.write(`     · no destroy-tier control on this route — no width is swept for it (declared: destroyMin=0)\n`);
          continue;
        }

        // ── PHASE B: the geometry, across the width axis ─────────────────────
        for (const w of WIDTHS) {
          const label = `${route.name} · ${theme} · ${w}x${VIEW_H}`;
          await goto(route.scen, theme, route.hash, w, VIEW_H);
          if (!(await poll(landed(route), LAND_CAP))) {
            throw new Error(`${label}: the route stopped landing at this width`);
          }
          await pinFonts(label);
          const m = await evalJs(measureJs(destroySels, { edgeTol: EDGE_TOL, gapMax: GAP_MAX }));
          cellsMeasured++;

          if (m.destroys.length === 0) {
            findings.push(
              `${label}: the destroy-tier control(s) the census classified (${destroySels.join(", ")}) painted NO box at ` +
              `this width. A control that vanishes cannot be adjacent to anything, and this cell would otherwise read clean.`);
            continue;
          }

          const hits = [];
          for (const pair of m.pairs) {
            const allow = ALLOWED.find((a) => a.destroy === pair.destroy && a.primary === pair.primary);
            if (allow) {
              allow.__fired = true;
              allowedHits.push({ ...pair, label, reason: allow.reason });
              hits.push(`ALLOWED ${pair.destroy} ${pair.direction} ${pair.primary}`);
              continue;
            }
            findings.push(
              `${label}: DESTROY-TIER ${pair.destroy} is rendered ${pair.direction} the primary ${pair.primary} at the ` +
              `same ${pair.edge} edge (edge delta ${pair.edgeDelta}px, vertical gap ${pair.gap}px, horizontal overlap ` +
              `${pair.hOverlap}px). destroy box y${pair.destroyBox}; primary box y${pair.primaryBox}. A hand travelling ` +
              `down that column reaches the destroy control ${pair.gap}px after the primary one — that is a misclick ` +
              `geometry, and it is NOT on this guard's allowlist.`);
            hits.push(`DEFECT ${pair.destroy} ${pair.direction} ${pair.primary}`);
          }
          process.stdout.write(
            `   ${hits.some((h) => h.startsWith("DEFECT")) ? "FAIL" : " ok "} ${label.padEnd(40)} ` +
            `destroy=${m.destroys.length} primary=${m.primaries} pairs=${m.pairs.length}` +
            `${hits.length ? " · " + hits.join("; ") : ""}\n`);
        }
      }
    }
  } catch (err) {
    await teardown();
    process.stderr.write(`\n!! ADJACENCY GUARD ERROR: ${err && err.message ? err.message : err}\n`);
    process.stderr.write(`   teardown ${teardownMs}ms\n`);
    process.exit(1);
  }

  await teardown();

  process.stdout.write(crossDoc.line());

  // ── THE RENDERED FLOOR ─────────────────────────────────────────────────────
  // A run that classified no destroy-tier control anywhere has swept every
  // width and judged nothing. Exit 2: the ABSENCE of a measurement, never a
  // clean bill.
  if (destroyTotal === 0) {
    process.stderr.write(
      `\n!! GUARD (exit 2): REFUSED TO MEASURE — the RENDERED population is EMPTY.\n` +
      `   ${cellsMeasured} cell(s) were visited and ZERO destroy-tier controls were classified across\n` +
      `   every route. The source carries btn-danger controls and a typed echo, so this is a\n` +
      `   REACHABILITY fault in the routes above (or in the gesture that opens the confirm),\n` +
      `   not a clean console. A sweep over an empty population is the false green this floor stops.\n`);
    process.exit(2);
  }

  // ── THE ALLOWLIST STALENESS CHECK ──────────────────────────────────────────
  // An entry that never fires has outlived the geometry it was written for.
  // That is a FAILURE, not a convenience: an allowlist that cannot go stale is
  // an allowlist that forgives the next drift.
  const ranRoutes = routes.map((r) => r.name);
  for (const a of ALLOWED) {
    const judgeable = !a.firesOn || a.firesOn.some((n) => ranRoutes.includes(n));
    if (!judgeable) {
      process.stdout.write(
        `   · allowlist entry ${a.destroy} ${a.primary}: staleness NOT judged — this run visited ` +
        `${ranRoutes.join(", ")} and the entry declares it can only fire on ${a.firesOn.join(", ")}.\n`);
      continue;
    }
    if (a.mustFire && !a.__fired) {
      findings.push(
        `ALLOWLIST STALE: the entry for ${a.destroy} ${a.primary} declares mustFire and was never measured adjacent ` +
        `anywhere in this run. Either the geometry was FIXED (delete this entry, and say so in the commit), or the ` +
        `control left the measurement entirely — which is the drift this guard exists to notice.`);
    }
  }

  if (allowedHits.length) {
    process.stdout.write(`\n>> ALLOWED adjacency, PRINTED rather than exempted (${allowedHits.length} cell(s)):\n`);
    const byPair = new Map();
    for (const h of allowedHits) {
      const k = `${h.destroy} ${h.direction} ${h.primary}`;
      if (!byPair.has(k)) byPair.set(k, { reason: h.reason, cells: [], gaps: [] });
      byPair.get(k).cells.push(h.label);
      byPair.get(k).gaps.push(h.gap);
    }
    for (const [k, v] of byPair) {
      process.stdout.write(
        `   ${k} — ${v.cells.length} cell(s), gap ${Math.min(...v.gaps)}..${Math.max(...v.gaps)}px\n` +
        `     first: ${v.cells[0]}\n     REASON: ${v.reason}\n`);
    }
  }

  const wall = Date.now() - t0;
  process.stdout.write(
    `\n${findings.length ? "ADJACENCY FAIL" : "ADJACENCY PASS"} — ${cellsMeasured} cell(s) measured, ` +
    `${destroyTotal} destroy-tier control(s) classified, ${allowedHits.length} allowed hit(s), ` +
    `${findings.length} finding(s) · ${(wall / 1000).toFixed(1)}s wall · teardown ${teardownMs}ms\n`);

  if (findings.length) {
    process.stderr.write(`\n!! ${findings.length} FINDING(S):\n`);
    for (const f of findings) process.stderr.write(`   ✗ ${f}\n`);
    process.exit(1);
  }
  process.exit(0);
}

main();
