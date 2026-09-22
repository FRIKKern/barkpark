// journey.mjs — can a person ADD A THING PHYSICALLY in the Studio, in a real browser?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (studio space-priority desk, wave 18)
// ─────────────────────────────────────────────────────────────────────────────
//  The owner's report was "the buttons look inert and I cannot add things".
//  Wave 17 found three real defects on that seam and fixed all three. The
//  confirmation that the fix WORKS was then driven by hand, once, and written
//  down as English. This epic has SIX logged overturns of exactly that shape:
//  a prose walk that read as proof and was not one.
//
//  So the confirmation ships as an instrument. Every beat below is a binary the
//  DOM or the API answers. Nothing here is a matter of taste, and nothing here
//  is a sentence somebody typed about a screen they remember seeing.
//
//  A check that cannot open the artifact it certifies is not a check.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE THREE LEGS
// ─────────────────────────────────────────────────────────────────────────────
//  LEG A — CREATE → TYPE → PERSIST, and it creates its OWN document.
//    AUTH      a login ticket is minted and redeemed, and an IDENTITY
//              DISCRIMINATOR proves the session is the ADMIN one: the
//              `[phx-click="shares-open"]` bar button renders only under
//              `shares_admin?` (studio.html.heex:80). Without this assertion a
//              session that silently degraded to anonymous walks a login page
//              and reports green.
//    DESK      the Structure column has rows, and `#item-paper` is a real
//              `<button>` (panes.ex:380) — not a div wearing a click handler.
//    CREATE    click `#item-paper`, POLL for `.pane-doc-item` rows, then click
//              `button.pane-add-btn[phx-value-type="paper"]` and require the URL
//              to carry a NEW document id. D227: never `--doc`, never "the first
//              row" — the drill that clicked the first row is precisely how a
//              draft-only fossil made three verifiers time out on a selector
//              that could never appear.
//    HYDRATE   the canvas for THAT id becomes real. Gated on
//              `el.blocks.length` / `.ProseMirror` child count, NEVER on
//              `_editor` existing (see THE THREE TRAPS below).
//    TYPE      a heading and a paragraph are typed with real key events into
//              the seeded `tpl-title` / `tpl-body` blocks
//              (content/papers/template.ex:124).
//    PERSIST   the typed text is read back FROM THE API, not from the DOM.
//    RELOAD    the page is reloaded and the heading is still there.
//    PROVENANCE the served commit is stamped PRE and POST and must match.
//
//  LEG B — THE DRAFT-ONLY FOSSILS (report-only, and it FAILS today on purpose).
//    Opens the two named draft-only papers and reports, per fossil, the shell /
//    body / contenteditable / add-block / footer counts plus how much visible
//    text the editor region carries. Today every count is zero and the region is
//    WORDLESSLY BLANK — that is the live defect the never-blank contract fixes.
//    Leg B NEVER moves the exit code: it is a measurement of a known-open
//    defect, not a regression gate. When the named-state contract merges, these
//    beats go green on their own and the harness needs no edit.
//
//  LEG C — THE DESK-ROW CENSUS (report-only). Presses every row the desk offers,
//    of every KIND it offers, and records ROW KIND · ELEMENT ID · VISIBLE LABEL ·
//    OUTCOME in one line. A row goes green ONLY on an effect that NAMES it
//    (aria-current on that element, or the URL newly carrying that row's own
//    phx-value-id, or — for a plugin anchor — the page becoming its own href);
//    pane and row counts are recorded and decide nothing. Controls that cannot be
//    pressed without destroying the measurement (the three id-less
//    `.pane-add-btn` header controls) are INVENTORIED WITH THE REASON, and the
//    reason itself is asserted. Bounded by a HARD LEG_C_BUDGET; whatever it does
//    not reach is UNMEASURED, never FAIL. See the leg's own header for the three
//    ways the naive version of it published a false verdict table.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node tooling/studio-journey/journey.mjs --self-test        # offline, no network
//    node tooling/studio-journey/journey.mjs                    # deployed guerrilla
//    node tooling/studio-journey/journey.mjs --report           # never exit 1
//    node tooling/studio-journey/journey.mjs --json --out run.json
//    CHROME=/path/to/chrome node tooling/studio-journey/journey.mjs
//
//  Default mode is STRICT — a failed LEG A beat exits 1. This differs
//  deliberately from tooling/search-smoke/journey-smoke.mjs, whose default is
//  report: that instrument's job is a during-the-deploy-window narration, and
//  this one's job is to answer "is the owner's bug fixed" with a verdict.
//  `--report` opts back into exit-0, and it is what the CI lane uses.
//
//  EXIT CODES — the 1/2 split is load-bearing, inherited from
//  tooling/search-smoke/journey-smoke.mjs and cssom-parity.mjs D19:
//    0  LEG A green (or --report, which never fails on content)
//    1  a LEG A beat FAILED — a fact about the PRODUCT
//    2  GUARD — a fact about the ENVIRONMENT or the invocation: no Chrome, no
//       native WebSocket, an unknown flag, no barkpark config, a ticket mint
//       that did not answer, a browser that never started, an unreadable served
//       commit, or a DEPLOY THAT LANDED MID-RUN. A misconfigured runner must
//       never red with a message that reads like a product defect, and a
//       transport failure must NEVER be converted into a product fact.
//
//  ZERO DEPENDENCIES, and that is a decision (charter D240). Node 22's native
//  `fetch` + native `WebSocket` speak the Chrome DevTools Protocol straight at
//  `--headless=new`. Playwright would have to be resolved out of the JS
//  monorepo — a pnpm install plus a chromium download — which is why
//  scripts/studio-desk-measure.mjs cannot run anywhere the monorepo is not
//  installed. The Cdp class, findChrome, the one-char-at-a-time `type()`, the
//  click(), the teardown ladder and the exit-code doctrine are lifted from
//  tooling/search-smoke/journey-smoke.mjs, which is CI-proven on ubuntu-latest.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE THREE TRAPS — each one has already burned somebody on this exact seam
// ─────────────────────────────────────────────────────────────────────────────
//  1. HYDRATION IS NOT `_editor` EXISTING. Measured on deployed guerrilla:
//     `{ed:true, elBlocks:0, pmChildren:0}` at t≈2s and `{ed:true,
//     elBlocks:85}` at t≈4s. A driver that gates on `_editor` finds an EMPTY
//     editor and types into nothing, then reports that typing "worked". So
//     readiness is `el.blocks.length > 0 || .ProseMirror child count > 0`, with
//     a hard ceiling, and a canvas still empty at the ceiling is a FAILED BEAT
//     — never a "wait longer". (`window.__ready` is a false negative by
//     construction: `bp-ready` fires on connectedCallback, before the inline
//     script attaches its listener.)
//
//  2. POLL, NEVER SLEEP. Papers patched 100 rows in 936 ms on guerrilla, and
//     the observed range is >1.4s to <8s under load; D230 records 6–20s TTFB.
//     A fixed 1400 ms wait already nearly produced the finding "Papers is
//     dead". Every wait in this file is `poll()` over a DOM or API predicate
//     with a named ceiling. And note that Structure rows (`.pane-item`,
//     `#item-<x>`) and document rows (`.pane-doc-item`, `#doc-<x>`) BOTH carry
//     `phx-click="select"`, so a driver keying off `[phx-click="select"]` can
//     assert against a Structure row while believing it holds a document.
//     Discriminate by CLASS, never by phx-click.
//
//  3. THERE IS NO SAVE BUTTON. `[data-test-id="bp-paper-footer-save"]` is a
//     `<span role="status" aria-live="polite">` with `tabIndex -1` and no
//     accessible name (paper_editor.ex:395); clicking it does nothing.
//     Persistence is AUTOSAVE on a 300 ms debounce. And today a SUCCESSFUL save
//     leaves that span EMPTY — a separate open defect — so nothing here reads
//     its text. The persistence oracle is the API.
//
//  WHY THE API IS THE PERSISTENCE ORACLE. The canvas run wrapper is
//  `phx-update="ignore"`, so LiveView never diffs inside it and NO DOM state in
//  there proves anything about the server. Read back with
//  `GET /v1/data/query/<ds>/paper?perspective=drafts&filter[_id][eq]=<id>` —
//  proven non-vacuous against guerrilla (a bogus id returns `count: 0`) — and
//  assert the block count, the block types and the typed text. Do NOT use
//  `/v1/data/doc/...`: the published-doc endpoint cannot see a draft-only
//  document and answers 404, which reads as "it does not exist".
//
// ─────────────────────────────────────────────────────────────────────────────
//  --self-test IS THE MUTATION PROOF
// ─────────────────────────────────────────────────────────────────────────────
//  It boots a zero-dependency in-process fixture — a miniature Barkpark with a
//  login-ticket endpoint, a /status.json commit, a desk, a create action, a
//  canvas element and a drafts-perspective query API — and runs the SAME
//  journey code against two sites:
//    /good/  hydrates its canvas after a beat and persists what is typed.
//    /rot/   carries the exact defect that burned three verifiers: the custom
//            element upgrades and `_editor` is truthy, and `blocks` stays `[]`
//            FOREVER. A harness that gates on `_editor` passes this fixture
//            green while typing into a void.
//  The fixture also mints a USER-shaped ticket when the mint body is not `{}`,
//  so the "the body must stay empty" rule is load-bearing here rather than a
//  comment: get it wrong and the AUTH discriminator goes red offline.
//  A check whose red has never been demonstrated is not a check, so the red is
//  demonstrated on every run, offline, with no network and no deployment.
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import crypto from "node:crypto";
import { spawn } from "node:child_process";

// ── caps (ms) ────────────────────────────────────────────────────────────────
const DEVTOOLS_CAP = 15000; // Chrome writing DevToolsActivePort
const NAV_CAP = 30000; // a navigation settling (D230: 6–20s TTFB under load)
const SETTLE_CAP = 15000; // a DOM predicate becoming true
const HYDRATE_CAP = 25000; // the canvas going from 0 blocks to real blocks
const PERSIST_CAP = 20000; // autosave (300ms debounce) reaching the API
const FETCH_CAP = 20000; // one plain-HTTP call to the API
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

// LEG C's bounding, and it is a HARD budget rather than a per-row cap.
// `poll()` checks its cap AFTER the predicate has run (see poll below), so a
// nominal 3.0s row cap cost a MEASURED 6.4–6.9s per row on a loaded host, and a
// census of a real desk multiplies that by the row count. A soft cap therefore
// cannot bound the leg. The budget is checked before and after every press and
// what is left over is reported UNMEASURED — never FAIL, because converting an
// exhausted runner budget into a dead row FABRICATES A DEFECT, which is the one
// failure mode this whole epic exists to stop.
//
// THE DEFAULT IS 90s, AND THE 2.7x IT WAS RAISED FOR DOES NOT EXIST. The 150s
// default carried this justification: "an UNANSWERED row costs a measured 16.2s
// (16.2 / 16.2 / 16.3 / 16.4) against a nominal 2 × 3.0s row cap — the overshoot
// is in the click and probe round trips". That sentence was never attributed to a
// phase, and when it finally was, it did not survive.
//
// MEASURED, WITH A PER-PHASE TIMER (`LEG_C_TRACE=1`, which is still in the code
// below so this is re-runnable). Measuring host: the author's local macOS desk
// (Darwin 24.5.0, 10 cores), against the in-process `--self-test-site rot`
// fixture on loopback, node v22.22.0, 2026-09-10. Three runs at load average
// 4.55 / 2.98 / 3.24, five unanswered rows each — the breakdown was the same
// every time:
//
//   pane_item#item-sheet :: total 6094ms = locate 1ms + witness-before 0ms
//     + attempt1[click 2ms (box 0 moved 1 pressed 0 released 1)
//                + witness-loop 3043ms (21 evaluate(s) = 11ms, 3032ms of ticks)]
//     + attempt2[click 3ms (box 1 moved 1 pressed 1 released 0)
//                + witness-loop 3045ms (21 evaluate(s) = 9ms, 3034ms of ticks)]
//
// An unanswered row costs 6.09–6.10s, which IS the nominal 2 × 3.0s cap plus
// ~90ms — not 2.7x it. THE NAMED PHASE IS THE WITNESS LOOP, and 99.6% of the
// witness loop is its own `pause(POLL_TICK)` sleeps (3032ms of 3043ms): the leg
// is not waiting on Chrome, it is waiting out its own cap. The two suspects the
// raise was justified with are BOTH REFUTED by ratio, which is what survives
// load: `page.click`'s box evaluate plus its three Input.dispatchMouseEvent round
// trips total 1–3ms of 6094ms (0.03%), and all 42 witness evaluates together
// total 9–16ms (0.2%).
//
// AND THE ATTRIBUTION IS LOAD-PROOF. Re-run with 20 spinners pinned on the 10
// cores, ending at load average 43.67: every unanswered row still cost
// 6092–6103ms, click still 1–2ms, 21 evaluates still 10–16ms. A `setTimeout`
// sleep does not get slower when the host is busy, so the phase that dominates
// this leg is the one phase host load cannot inflate.
//
// WHERE 16.2s CAME FROM: 2 × 8.1s. `censusWitnessProbe` below records that
// asking the FULL enumeration for one row's aria-current on every poll tick
// "cost a MEASURED 8.1s for a 3.0s row cap on a loaded host". The 16.2s is that
// pre-cheap-probe cost, doubled by the two press attempts, carried forward into
// this comment after the cheap probe had already fixed it. Two comments in one
// file, one calling the cost fixed and one still budgeting for it.
//
// So 90s stands with a 2.8x margin: /rot/ (7 pressed rows, 5 of them dead) spends
// 32.5s, measured on all four runs above. LEG_C_BUDGET_MS moves it either way,
// and a host slow enough to need more will say so — the leg reports what it did
// not reach as UNMEASURED, never FAIL.
const LEG_C_BUDGET = Number(process.env.LEG_C_BUDGET_MS || 90000);
const LEG_C_ROW_CAP = Number(process.env.LEG_C_ROW_CAP_MS || 3000); // per-row, SOFT
// `LEG_C_MAX_ROWS` CAPS EACH KIND, NOT THE ROSTER — and that is the whole fix
// for spd-w19-census-maxrows-crowds-inventory. Measured on served c81b8e66d
// (production guerrilla, 2026-09-06): the desk opens with 7 `.pane-item` rows
// and NO doc rows, and the first press grows the roster by ~100
// `.pane-doc-item` rows. `CENSUS_FN` enumerates `.pane-doc-item` FIRST (the
// most specific shape has to claim its elements before a broader selector can),
// so under a ROSTER-WIDE cap of 40 those ~100 doc rows consumed every remaining
// slot and the `add_btn` / `section_header` rows the leg exists to INVENTORY
// never entered the roster at all: the census reported `0 inventoried` and `587
// further row(s) beyond LEG_C_MAX_ROWS=40`, which reads exactly like "this desk
// has no inventory rows".
//
// A roster-wide cap makes coverage a function of DOM ORDER: the most numerous
// kind decides which kinds are censused. Per-kind, every kind the desk offers
// is represented no matter how many members another kind has, and the run stays
// bounded — the ceiling is `LEG_C_MAX_ROWS × (number of kinds)`, and only the
// four PRESSABLE kinds cost time at all (inventory rows are asserted, never
// pressed). Raising the default instead would have bought coverage by removing
// the bound; that is not the same fix.
const LEG_C_MAX_ROWS = Number(process.env.LEG_C_MAX_ROWS || 40);
const LEG_C_PRESS_ATTEMPTS = 2;
// LEG_C_TRACE=1 prints the per-phase attribution of every census row to stderr.
const LEG_C_TRACE = process.env.LEG_C_TRACE === "1";

const POLL_TICK = 150; // the poll loop's interval
const KEY_GAP = 25; // pacing between synthetic keystrokes
const RETRY_BASE = 750; // fetch retry backoff base

const DESK_PATH = "/w/default/p/default/d/production/studio";
const DATASET = "production";

// The two named draft-only fossils (LEG B). `drafts.` is the DRAFT id; the
// Studio route and the pane row both carry the PUBLISHED id. A four-cell matrix
// already ruled the `drafts.` prefix out as the cause of the blank — the
// variable is the document, not its id spelling.
const FOSSILS = [
  { draftId: "drafts.paper-b28358ff271b260e", docId: "paper-b28358ff271b260e" },
  { draftId: "drafts.paper-3149ef706e777628", docId: "paper-3149ef706e777628" },
];

// ── the only wait primitive in the file ──────────────────────────────────────
// Named `pause` rather than `sleep` so that a grep for a wait lands on the four
// legitimate call sites and nowhere else: the poll loop's tick, the keystroke
// pacing, the fetch retry backoff, and the teardown kill ladder. There is no
// "wait for the page to be ready" anywhere — readiness is always a predicate.
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

/** Poll an async predicate until it returns something truthy, or the cap
 *  elapses. Returns `{ value, waited }` on success and `{ value: null, waited }`
 *  on timeout — the caller decides whether a timeout is a FAIL (it usually is)
 *  and reports how long it actually took, because "it passed in 4.1s" and "it
 *  passed at 14.9s of a 15s cap" are different facts about the same green. */
async function poll(fn, cap, label) {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return { value: v, waited: Date.now() - t0, label };
    if (Date.now() - t0 >= cap) return { value: null, waited: Date.now() - t0, label };
    await pause(POLL_TICK); // the poll tick — not a wait for anything in particular
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  argv — an UNKNOWN FLAG IS A GUARD, never a silent green
// ─────────────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const opts = {
    selfTest: false,
    selfTestSite: null,
    report: false,
    json: false,
    out: null,
    keep: false,
    dataset: process.env.JOURNEY_DATASET || DATASET,
    legs: process.env.JOURNEY_LEGS || "abc",
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v == null) throw new Error(`flag ${a} needs a value`);
      return v;
    };
    switch (a) {
      case "--self-test": opts.selfTest = true; break;
      case "--self-test-site": opts.selfTestSite = value(); break;
      case "--report": opts.report = true; break;
      case "--json": opts.json = true; break;
      case "--out": opts.out = value(); break;
      case "--keep": opts.keep = true; break;
      case "--dataset": opts.dataset = value(); break;
      case "--legs": opts.legs = value(); break;
      case "--help":
      case "-h": opts.help = true; break;
      default: throw new Error(`unknown flag ${a}`);
    }
  }
  // --legs is how a run reaches LEG C WITHOUT LEG A. LEG A creates a real
  // document; on a host other people are using, "just run the whole thing" is
  // not free, and the desk-row census needs none of it. An unknown letter is a
  // GUARD, never a silently narrower run.
  opts.legs = String(opts.legs).toLowerCase().replace(/[\s,]/g, "");
  if (!/^[abcd]+$/.test(opts.legs) || new Set(opts.legs).size !== opts.legs.length) {
    throw new Error(`--legs wants some subset of "abcd", each letter at most once (got "${opts.legs}")`);
  }
  if (opts.selfTestSite && !["good", "rot"].includes(opts.selfTestSite)) {
    throw new Error(`--self-test-site must be good or rot (got ${opts.selfTestSite})`);
  }
  return opts;
}

const USAGE = `journey — browser proof that a person can ADD A THING in the Studio

  node tooling/studio-journey/journey.mjs [--report] [--json] [--out <path>]
  node tooling/studio-journey/journey.mjs --self-test
  node tooling/studio-journey/journey.mjs --self-test-site good|rot

  (no flags)          drive DEPLOYED guerrilla; exit 1 if a LEG A beat failed
  --report            never exit 1 on content — the CI lane's mode
  --self-test         run both fixtures offline and assert the harness's own
                      behaviour: all-green on /good/, the exact red on /rot/
  --self-test-site s  run ONE fixture and exit with its real product verdict
                      (this is how the 0-on-healthy / non-0-on-rotten split is
                      demonstrated by invocation rather than asserted in prose)
  --json              emit the machine-readable run object after the report
  --out <path>        also write that object to a file
  --keep              do NOT delete the document LEG A created (default: it
                      self-cleans, so a re-run never litters the dataset)
  --dataset <ds>      dataset to drive (default ${DATASET})
  --legs <abcd>       run only these legs (default abc — LEG D is OPT-IN). \`--legs c\` is the
                      desk-row census ALONE: it never creates a document, so it
                      is the mode for a shared/production host. When a runs, it
                      establishes the session; when it does not, a minimal AUTH
                      beat mints the same ticket and asserts the same admin
                      discriminator first — a census of an anonymous desk is not
                      a census of the desk. \`--legs d\` is the COLD-LOAD PRESS
                      FLOOR: ten consecutive cold loads, one deliberately-early
                      press each, plus the ref-src second-press probe. It is NOT
                      in the default because it costs ten full navigations, and
                      because it REFUSES to publish a latency on a host whose
                      load average is at or above 0.20 per core — printing the
                      load it refused at. That refusal is a RESULT, not an error.

  exit 0 clean · 1 a LEG A product failure · 2 environment/usage guard
`;

// ─────────────────────────────────────────────────────────────────────────────
//  the CDP client — tooling/search-smoke/journey-smoke.mjs's, verbatim in shape
// ─────────────────────────────────────────────────────────────────────────────
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    this.listeners = new Map();
    ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id == null) {
        const subs = this.listeners.get(msg.method);
        if (subs) for (const fn of subs) { try { fn(msg.params || {}, msg); } catch { /* a listener must never kill the run */ } }
        return;
      }
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

  on(method, fn) {
    if (!this.listeners.has(method)) this.listeners.set(method, []);
    this.listeners.get(method).push(fn);
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

function findChrome() {
  // CHROME is VALIDATED, not trusted. Returning it unchecked means a typo'd or
  // stale path reaches `spawn`, whose ENOENT arrives as an unhandled 'error'
  // event and kills the process with exit 1 and a Node stack trace — i.e. an
  // ENVIRONMENT failure wearing a product failure's exit code, which is the one
  // thing the 1/2 split exists to prevent. Returning null here routes it to the
  // GUARD path instead. (Proven by invocation: CHROME=/nonexistent/chrome.)
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

// ─────────────────────────────────────────────────────────────────────────────
//  the page session — one tab, driven
// ─────────────────────────────────────────────────────────────────────────────
class Page {
  constructor(cdp, sessionId) {
    this.cdp = cdp;
    this.sid = sessionId;
    this.exceptions = [];
    this.lastDocument = null; // { status, url } of the most recent main document
    // ── THE WIRE TAP (spd-w18-desk-click-latency, criterion 0) ──────────────
    //
    // A press that was NEVER SENT and a press that was SENT AND IGNORED look
    // IDENTICAL from inside the DOM — nothing happens, either way — and they
    // need OPPOSITE fixes: the first is a client-side discard (make the
    // affordance refuse the press or survive the window), the second is a
    // server-side answer that did not come (make the handler answer, or say it
    // is working). Every "dead row" verdict this harness has ever printed was
    // silent about which one it saw. These three fields are what tells them
    // apart, and they are read OFF THE SOCKET, which no page JavaScript can do.
    //
    // `lvSocketIds` is not decoration: a CDP frame event carries only a
    // requestId, so without the created-event mapping there is no way to know a
    // frame belongs to `/live/websocket` rather than to some other socket the
    // page opened. An EMPTY set therefore means CANNOT READ — never "0 frames".
    this.lvSocketIds = new Set();
    this.lvSocketUrl = null;
    this.lvClickFrames = [];
  }

  static async open(cdp) {
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    const page = new Page(cdp, sessionId);
    page.targetId = targetId;
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Runtime.enable", {}, sessionId);
    // Network.enable is what makes the STATUS LINE visible. Guerrilla has served
    // a 500 and a 503 deploy page mid-run, and from inside the DOM those look
    // exactly like "the desk did not paint" — which a harness then reports as a
    // product defect. The status line is the only thing that separates the two,
    // and no page JavaScript can see it.
    await cdp.send("Network.enable", {}, sessionId);
    cdp.on("Network.responseReceived", (p) => {
      if (p.type !== "Document") return;
      page.lastDocument = { status: p.response?.status ?? null, url: p.response?.url ?? null };
    });
    // The wire tap's three subscriptions. `Network.enable` above already turned
    // the WebSocket events on — they ride the same domain as the status line, so
    // this costs one more listener and no extra protocol state.
    cdp.on("Network.webSocketCreated", (p) => {
      // The LiveView socket is the ONE this harness reasons about. Matching on
      // the path, not on "the first socket", because the Studio also opens
      // sockets for the tmux terminal and (in dev) live_reload, and a frame from
      // one of those must never be counted as a press.
      if (typeof p.url === "string" && p.url.includes("/live/websocket")) {
        page.lvSocketIds.add(p.requestId);
        page.lvSocketUrl = p.url;
      }
    });
    cdp.on("Network.webSocketFrameSent", (p) => {
      if (!page.lvSocketIds.has(p.requestId)) return;
      const data = p.response?.payloadData;
      if (typeof data !== "string") return;
      // A LiveView click rides as `[join_ref,ref,topic,"event",{"type":"click",…}]`.
      // `"type":"click"` is the discriminator — it is the field the server
      // switches on, and it is absent from every join, heartbeat, form, keydown
      // and hook push on the same socket.
      if (data.indexOf('"type":"click"') === -1) return;
      page.lvClickFrames.push({ at: Date.now(), payload: data.slice(0, 240) });
    });
    cdp.on("Runtime.exceptionThrown", (p) => {
      const d = p.exceptionDetails || {};
      page.exceptions.push(d.exception?.description || d.text || "(unknown exception)");
    });
    return page;
  }

  async goto(url) {
    const loaded = new Promise((resolve) => {
      const done = () => resolve(true);
      this.cdp.on("Page.loadEventFired", done);
      setTimeout(() => resolve(false), NAV_CAP); // a navigation ceiling, not a wait
    });
    await this.cdp.send("Page.navigate", { url }, this.sid);
    await loaded;
  }

  /** Evaluate in the page. A page-thrown exception comes back as
   *  `{ __throw: text }` rather than raised: a broken page must produce a
   *  FAILED BEAT, never a crashed harness that reports nothing about the rest. */
  async evaluate(expression) {
    const r = await this.cdp.send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      this.sid,
    );
    if (r.exceptionDetails) return { __throw: r.exceptionDetails.text || "evaluate threw" };
    return r.result?.value;
  }

  url() { return this.evaluate("location.href"); }

  async count(selector) {
    const n = await this.evaluate(`document.querySelectorAll(${JSON.stringify(selector)}).length`);
    return typeof n === "number" ? n : 0;
  }

  async tagOf(selector) {
    const t = await this.evaluate(
      `(function(){var el=document.querySelector(${JSON.stringify(selector)});return el?el.tagName:null;})()`,
    );
    return typeof t === "string" ? t : null;
  }

  /** Type through the INPUT domain, one char at a time, exactly as a keyboard
   *  does. Not `el.textContent = …`: ProseMirror maintains its own document
   *  state and a direct DOM write is either reverted or silently un-synced, so
   *  a text poke would prove nothing about the typing path — which is the only
   *  path the owner's bug lives on. Proven by run: this exact dispatch inserts
   *  into the real bp-paper-canvas TipTap contenteditable. */
  async type(text) {
    for (const ch of text) {
      await this.cdp.send("Input.dispatchKeyEvent", { type: "keyDown", text: ch, unmodifiedText: ch, key: ch }, this.sid);
      await this.cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: ch }, this.sid);
      await pause(KEY_GAP); // keystroke pacing, not a readiness wait
    }
  }

  /** A real mouse press/release at the element's centre — the click path the
   *  user takes, hover and focus handlers included. */
  async click(selector) {
    // LEG_C_TRACE: `clickTiming` is written on EVERY click so the caller can
    // attribute a slow press to the box evaluate or to one of the three
    // Input.dispatchMouseEvent round trips, rather than to "the click".
    const cs = Date.now();
    const box = await this.evaluate(
      `(function(){var el=document.querySelector(${JSON.stringify(selector)});if(!el)return null;` +
        `el.scrollIntoView({block:"center"});var r=el.getBoundingClientRect();` +
        `if(!r.width||!r.height)return null;` +
        `return {x:r.left+r.width/2,y:r.top+r.height/2};})()`,
    );
    const cBox = Date.now();
    if (!box || box.__throw) { this.clickTiming = { box: cBox - cs, moved: 0, pressed: 0, released: 0, total: cBox - cs, hit: false }; return false; }
    const common = { x: Math.round(box.x), y: Math.round(box.y), button: "left", clickCount: 1 };
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...common }, this.sid);
    const cMoved = Date.now();
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...common }, this.sid);
    const cPressed = Date.now();
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...common }, this.sid);
    const cDone = Date.now();
    this.clickTiming = {
      box: cBox - cs, moved: cMoved - cBox, pressed: cPressed - cMoved,
      released: cDone - cPressed, total: cDone - cs, hit: true,
    };
    return true;
  }

  /** Click, then WAIT FOR THE EFFECT — and if the effect does not come, click
   *  again, up to `attempts` times inside one overall cap.
   *
   *  This is not papering over a flaky product. A LiveView mount patch REPLACES
   *  the node the click was aimed at, and a click dispatched into that window is
   *  discarded with no error, no exception and no server-side trace. Measured on
   *  deployed guerrilla across otherwise identical runs: the same click on the
   *  same button patched the URL in 1.6s, in 2.4s, and never within 15s. Gating
   *  on `[data-phx-main].phx-connected` removed most of it and not all of it —
   *  the class flips when the socket joins, which is before the mount diff has
   *  landed. A single-shot click therefore measures the ARRIVAL TIME OF A DOM
   *  PATCH, not whether the control works.
   *
   *  The honesty rule: the attempt count is REPORTED. One attempt means the
   *  control answered the first press. Three attempts that then work is a
   *  latency finding. Exhausting the attempts is a FAILED BEAT — this helper
   *  can never turn a dead control green, only a raced one. */
  async clickUntil(selector, predicate, { cap, attempts = 3, label = selector } = {}) {
    const per = Math.max(1500, Math.floor(cap / attempts));
    const t0 = Date.now();
    // Taken before the FIRST press, so `wire` covers every press this helper
    // made — which is the honest scope: the question "was it sent" is about the
    // presses, plural, that produced (or failed to produce) this outcome.
    const mark = this.wireMark();
    let clicked = false;
    for (let i = 1; i <= attempts; i++) {
      const hit = await this.click(selector);
      clicked = clicked || hit;
      if (!hit) {
        // Nothing to click yet — poll for the element itself before re-trying,
        // so a control that simply has not rendered is not counted as a miss.
        await poll(async () => (await this.count(selector)) > 0 || null, per, `${label} present`);
        continue;
      }
      const r = await poll(predicate, per, label);
      if (r.value) return { value: r.value, attempts: i, waited: Date.now() - t0, clicked, wire: this.wireVerdict(mark) };
      if (Date.now() - t0 >= cap) break;
    }
    return { value: null, attempts, waited: Date.now() - t0, clicked, wire: this.wireVerdict(mark) };
  }

  /** Put the caret at the END of a contenteditable node and confirm the
   *  selection actually landed inside it. A click alone lands the caret
   *  wherever the pointer hit, which for an empty paragraph is ambiguous; and a
   *  focus that silently failed would make the subsequent typing go nowhere
   *  while every keystroke still "succeeded". */
  async caretAtEndOf(selector) {
    return this.evaluate(
      `(function(){var el=document.querySelector(${JSON.stringify(selector)});if(!el)return false;` +
        `var host=el.closest('[contenteditable="true"]')||el.querySelector('[contenteditable="true"]');` +
        `if(host&&host.focus)host.focus();` +
        `var r=document.createRange();r.selectNodeContents(el);r.collapse(false);` +
        `var s=window.getSelection();s.removeAllRanges();s.addRange(r);` +
        `var a=s.anchorNode;` +
        `return !!(a&&(el.contains(a)||a===el));})()`,
    );
  }

  /** A high-water mark on the click frames seen so far. Take it IMMEDIATELY
   *  before a press; `wireVerdict` reads what arrived after it. */
  wireMark() { return this.lvClickFrames.length; }

  /** THE THREE-VALUED ANSWER, and the third value is the point.
   *
   *    SENT        ≥1 `"type":"click"` frame left the browser on
   *                `/live/websocket` after the mark — the press reached the
   *                server, so a missing answer is the SERVER's.
   *    NOT SENT    the LiveView socket was observed and carried ZERO click
   *                frames — the press was discarded IN THE CLIENT and no
   *                server-side fix can help it.
   *    CANNOT READ no `/live/websocket` socket was ever observed at all, so
   *                this instrument has NO reading. It is deliberately NOT the
   *                same value as zero: reporting a failed read as "0 frames"
   *                would manufacture a confident client-side verdict out of a
   *                broken tap, which is the exact instrument fault this
   *                criterion exists to forbid. Callers must treat it as a
   *                FAILED check (exit non-zero), never as a NOT SENT.
   */
  wireVerdict(mark) {
    const frames = this.lvClickFrames.length - mark;
    if (this.lvSocketIds.size === 0) {
      return {
        verdict: "CANNOT READ",
        frames: null,
        detail:
          "CANNOT READ — no /live/websocket socket was ever observed on this tab, " +
          "so this run cannot say whether the press was sent. This is an INSTRUMENT " +
          "failure, not a zero: check that Network.enable is on and that the Studio " +
          "actually opens a LiveView socket at this base.",
      };
    }
    if (frames > 0) {
      return {
        verdict: "SENT",
        frames,
        detail: `SENT — ${frames} "type":"click" frame(s) left the browser on ${this.lvSocketUrl}`,
      };
    }
    return {
      verdict: "NOT SENT",
      frames: 0,
      detail:
        `NOT SENT — the LiveView socket (${this.lvSocketUrl}) was open and carried ZERO ` +
        `"type":"click" frames for this press: the client DISCARDED it (LiveView's ` +
        `bindClick returns early when the element carries data-phx-ref-src, and ` +
        `pushWithReply rejects with "no connection" before the channel has joined — ` +
        `both drop with no exception, no flash and no server trace)`,
    };
  }

  exceptionMark() { return this.exceptions.length; }
  exceptionsSince(mark) { return this.exceptions.slice(mark); }
}

// ─────────────────────────────────────────────────────────────────────────────
//  the barkpark client — the auth half of scripts/studio-desk-measure.mjs
// ─────────────────────────────────────────────────────────────────────────────
// Only `resolvePlaywright` is exported over there, and the rest is ~25 lines, so
// it is re-implemented here rather than refactoring a 3,800-line script that
// four other slices may be touching this wave.

class Guard extends Error {}
const guard = (msg) => { throw new Guard(msg); };

/** `allowInsecure` exists for ONE caller: the in-process self-test fixture,
 *  which is http://127.0.0.1 by construction. Every other path keeps the https
 *  requirement, because the Studio session cookie carries `Secure` and an
 *  http:// or bare-IP base silently drops it — you then spend the whole run
 *  measuring a login page and calling it a desk. */
function readServer({ allowInsecure = false } = {}) {
  // CI has no ~/.config/barkpark. The env pair is the ONLY other source, and it
  // is all-or-nothing on purpose: half a credential silently falling back to a
  // laptop's config file is how a scheduled lane ends up measuring the wrong
  // host and reporting it as the deployment.
  const envBase = process.env.JOURNEY_BASE, envToken = process.env.JOURNEY_TOKEN;
  if (envBase || envToken) {
    if (!envBase || !envToken) guard("JOURNEY_BASE and JOURNEY_TOKEN must be set together (got only one)");
    const base = envBase.replace(/\/+$/, "");
    if (!allowInsecure && !base.startsWith("https://")) {
      guard(`JOURNEY_BASE must be an https:// hostname (got ${base}) — the session cookie carries Secure`);
    }
    return { base, token: envToken };
  }
  const p = path.join(os.homedir(), ".config/barkpark/config.json");
  if (!fs.existsSync(p)) guard(`no barkpark config at ${p} — cannot read the guerrilla admin token`);
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(p, "utf8")); }
  catch (e) { guard(`barkpark config at ${p} is not JSON: ${e.message}`); }
  const srv = (cfg.known_servers || []).find((s) => s.name === "guerrilla");
  if (!srv?.token) guard(`no guerrilla entry with a token in ${p} (known_servers[] where name=="guerrilla") — run \`bp login\``);
  const base = String(srv.server || "").replace(/\/+$/, "");
  if (!allowInsecure && !base.startsWith("https://")) {
    guard(`guerrilla server must be an https:// hostname (got ${base || "<empty>"}) — the session cookie carries Secure and an http/IP form is dropped`);
  }
  return { base, token: srv.token };
}

/** One fetch, retried with backoff. Guerrilla has served a 503 deploy page
 *  mid-run and D230 records 6–20s TTFB, so a single transport hiccup must not
 *  become a product fact. Exhausting the retries is a GUARD (exit 2). */
async function api(ctx, url, init = {}, { attempts = 3, expectJson = true } = {}) {
  let last = null;
  for (let i = 0; i < attempts; i++) {
    if (i > 0) await pause(RETRY_BASE * 2 ** (i - 1)); // retry backoff
    try {
      const res = await fetch(url, {
        ...init,
        headers: { Authorization: `Bearer ${ctx.token}`, "Content-Type": "application/json", ...(init.headers || {}) },
        signal: AbortSignal.timeout(FETCH_CAP),
      });
      const text = await res.text();
      if (!res.ok) { last = `HTTP ${res.status} ${text.slice(0, 200)}`; continue; }
      if (!expectJson) return { ok: true, text };
      try { return { ok: true, body: JSON.parse(text), text }; }
      catch { last = `non-JSON body (${text.slice(0, 120)})`; }
    } catch (e) {
      last = e?.message || String(e);
    }
  }
  return { ok: false, error: last };
}

/** Single-use, 60s TTL, minted immediately before it is redeemed. The body MUST
 *  stay `'{}'`: an `email` in it mints a USER-shaped ticket, the session comes
 *  back non-admin, and every admin-gated control the desk is made of quietly
 *  disappears. The self-test fixture reproduces that behaviour so this rule is
 *  enforced offline rather than remembered. */
async function mintTicket(ctx) {
  const r = await api(ctx, `${ctx.base}/v1/auth/login-tickets`, { method: "POST", body: "{}" });
  if (!r.ok) guard(`login-ticket mint failed: ${r.error} — this is an ENVIRONMENT failure, no claim is made about the Studio`);
  if (!r.body?.ticket) guard(`login-ticket response carried no ticket: ${JSON.stringify(r.body).slice(0, 200)}`);
  return r.body.ticket;
}

/** The provenance stamp. `/status.json` carries the short sha of the code the
 *  serving process was built from — no ssh required, so this works from CI and
 *  from a laptop. Unreadable is a GUARD, not a product fact. */
async function servedCommit(ctx) {
  const r = await api(ctx, `${ctx.base}/status.json`, { method: "GET" });
  if (!r.ok) guard(`cannot read ${ctx.base}/status.json (${r.error}) — the run cannot be attributed to a build, so it certifies nothing`);
  const commit = r.body?.commit;
  if (!commit) guard(`${ctx.base}/status.json carried no commit field: ${JSON.stringify(r.body).slice(0, 200)}`);
  return { commit: String(commit), version: r.body?.version ?? null, read_at: new Date().toISOString() };
}

/** THE PERSISTENCE ORACLE. drafts perspective + an exact-id filter. Proven
 *  non-vacuous against guerrilla: `filter[_id][eq]=nope-does-not-exist` returns
 *  `count: 0`, so a green here is the document and not the endpoint shrugging.
 *  NOT `/v1/data/doc/...` — the published-doc endpoint cannot see a draft-only
 *  document and answers 404, which reads as "it does not exist". */
function draftQueryUrl(ctx, type, id) {
  const q = new URLSearchParams({ perspective: "drafts", limit: "1" });
  q.set("filter[_id][eq]", id);
  return `${ctx.base}/v1/data/query/${encodeURIComponent(ctx.dataset)}/${encodeURIComponent(type)}?${q}`;
}

/** ─────────────────────────────────────────────────────────────────────────
 *  THE SWEEP PREDICATE — provenance first, shape second.
 *  ─────────────────────────────────────────────────────────────────────────
 *
 *  WHAT THE OLD PREDICATE WAS AND WHY IT COULD NOT WORK (task-d582be9d064f35dc).
 *  It was: "a draft, created inside THIS run's window, whose title is empty or
 *  `Untitled`, with no more blocks than the seeded template". Every clause is
 *  defensible on its own and the conjunction is a trap, because the TYPE beat of
 *  this very harness writes text into the title-role block and the server then
 *  derives a title from it. Measured on guerrilla 2026-09-22, the six drafts a
 *  night of killed runs left behind carry titles like
 *  `journey paragraph MUCA9FZ6` and
 *  `journey paragraph MUCA8WHGJOURNEY HEADING MUCA8WHGjourney paragraph MUCA8WHG`.
 *  So a run that dies AFTER TYPE and before its own cleanup leaves a document
 *  the title clause rejects — on that run and on every future one.
 *
 *  AND THE TIME CLAUSE ALONE IS ALREADY FATAL, which the row's mechanism did not
 *  say. `since` is always "two seconds before THIS run pressed +", so a leftover
 *  is out of every later run's window no matter what its title is. The sixth
 *  catalogued draft, `drafts.paper-8be087501234ae2d`, proves it: title `null`,
 *  two blocks — it satisfies the title clause and the shape clause and it is
 *  still permanent debris. A longer title vocabulary would not have reclaimed it.
 *
 *  THE REPLACEMENT. The harness STAMPS every document it creates, over the API,
 *  the moment it learns the id and BEFORE it types anything:
 *
 *      journeyRun: { harness: "<this file's path>", run_id, host, stamped_at }
 *
 *  and the sweep selects on that stamp. Two arms, and they are deliberately not
 *  symmetric:
 *
 *    ARM 1 — STAMPED (a rule). Any draft carrying `journeyRun.harness ===
 *      HARNESS_MARK` is this harness's document, whatever its title, its content
 *      or its age. No time bound: that is the point, because reclaiming a DEAD
 *      run's debris is the whole defect. Bounded instead by OWNERSHIP — this
 *      run's own run_id, or a stamped draft older than STALE_DEBRIS_MS, which no
 *      live run can be (every cap in this file is tens of seconds; see the
 *      constant). A concurrent run's in-flight document is therefore never
 *      selected, which a bare "delete everything stamped" would get wrong.
 *
 *    ARM 2 — UNSTAMPED, WINDOW + SHAPE (unchanged, and still necessary). There
 *      is exactly one document class the stamp cannot cover: the "+" that
 *      CREATES WITHOUT NAVIGATING (guerrilla 4f046cce1), whose id the run never
 *      learns and therefore cannot patch. Those are untitled, two-block, and
 *      inside this run's own window, so the old predicate still catches them and
 *      it stays exactly as it was. It is a snapshot, and it is used only where
 *      the run's own seconds bound it.
 *
 *  WHY THE STAMP CANNOT BE DEFEATED THE WAY THE TITLE WAS. The title is written
 *  by a BEAT OF THE JOURNEY — the harness attacks its own predicate every run,
 *  and a human typing in the Studio writes the same field by the same route. The
 *  stamp is written by NO beat and by no Studio affordance: `journeyRun` is not a
 *  field the paper editor, the "+" handler or the template seeder ever sets, so a
 *  document carries it if and only if this file PUT it there over
 *  /v1/data/mutate. TYPE, autosave and reload rewrite `blocks`, `title`,
 *  `body_html` and `preview`; they do not touch it — asserted live, not assumed,
 *  and the killed-run evidence under tooling/studio-journey/evidence-sweep/ is a
 *  document that was typed into, autosaved, and still carries its stamp.
 *  The key is also a PREDICATE the server can evaluate:
 *  `filter[journeyRun.harness][eq]=…` returns the stamped set directly, so the
 *  sweep is no longer a 50-row recency scan that older debris falls out of.
 *
 *  Residual risk, stated rather than hidden: ARM 2 would still sweep an empty
 *  untitled draft somebody else created inside the same few seconds. `--keep`
 *  opts out on a busy host. ARM 1 carries no such risk — nothing but this file
 *  writes the field it reads. */
const SEEDED_TEMPLATE_BLOCKS = 2;

/** The stamp's field and value. The value is this file's repo path, so the mark
 *  NAMES its writer: a stamped document found by a human leads back here. */
const STAMP_FIELD = "journeyRun";
const HARNESS_MARK = "tooling/studio-journey/journey.mjs";

/** How old a stamped draft from ANOTHER run must be before this run will reclaim
 *  it. A journey run is bounded by its own caps (SETTLE_CAP, HYDRATE_CAP,
 *  PERSIST_CAP, LEG_C_BUDGET) and the slowest observed guerrilla run is under two
 *  minutes; 30 minutes is two orders of magnitude of headroom. Anything stamped
 *  and older than this belongs to a process that is not coming back. This is the
 *  ONLY guard between arm 1 and a concurrent run's live document, so it is a
 *  named constant and not an inline number. */
const STALE_DEBRIS_MS = 30 * 60 * 1000;

/** THE PROVENANCE READ. `d.journeyRun.harness` and nothing else — not the title,
 *  not the block count, not the id. */
function harnessStamped(d) {
  return typeof d?.[STAMP_FIELD]?.harness === "string" && d[STAMP_FIELD].harness === HARNESS_MARK;
}

/** ARM 1's ownership rule: MY run, or a run that is provably dead. */
function stampedAndReclaimable(d, { runId = null, now = Date.now() } = {}) {
  if (!harnessStamped(d)) return false;
  if (runId && d[STAMP_FIELD].run_id === runId) return true;
  const born = Date.parse(d._createdAt || 0);
  return Number.isFinite(born) && now - born >= STALE_DEBRIS_MS;
}

/** ARM 2: the old predicate, unchanged, for the documents the stamp cannot
 *  reach. Kept as its own named function so the self-test can red ONE arm. */
function untitledTemplateShape(d, since) {
  if (!d?._draft || Date.parse(d._createdAt || 0) < since) return false;
  const title = (d.title ?? "").trim();
  if (title !== "" && title.toLowerCase() !== "untitled") return false;
  const blocks = d.blocks ?? d.content?.blocks ?? [];
  return Array.isArray(blocks) && blocks.length <= SEEDED_TEMPLATE_BLOCKS;
}

function sweepCandidate(d, since, opts = {}) {
  if (!d?._draft) return false;
  if (harnessStamped(d)) return stampedAndReclaimable(d, opts);
  return untitledTemplateShape(d, since);
}

/** Write the stamp. Called the instant the run learns the document's id and
 *  BEFORE the TYPE beat — the ordering is the whole contract, because every
 *  document the old predicate could not reclaim was killed between those two
 *  points. A failed stamp is REPORTED and never fatal: the run's own cleanup
 *  still deletes by id, and arm 2 still covers the untouched case. What is lost
 *  on a failed stamp is only the ability of a LATER run to reclaim this one. */
async function stampRun(ctx, type, id, mark) {
  const r = await api(
    ctx,
    `${ctx.base}/v1/data/mutate/${encodeURIComponent(ctx.dataset)}`,
    { method: "POST", body: JSON.stringify({ mutations: [{ patch: { id, type, set: { [STAMP_FIELD]: mark } } }] }) },
    { attempts: 2 },
  );
  return r.ok ? { ok: true } : { ok: false, error: r.error };
}

/** ARM 1's query. A server-side filter on the stamp, NOT a recency page — the
 *  50-row `_createdAt:desc` window is exactly how debris from an old run becomes
 *  invisible once fifty documents are newer than it. Proven non-vacuous the same
 *  way the id oracle is: `filter[journeyRun.harness][eq]=<a value nothing
 *  carries>` returns count 0 against guerrilla, so a non-empty answer here is
 *  documents and not the endpoint ignoring the filter. */
async function stampedDrafts(ctx, type) {
  const q = new URLSearchParams({ perspective: "drafts", limit: "50", order: "_createdAt:desc" });
  q.set(`filter[${STAMP_FIELD}.harness][eq]`, HARNESS_MARK);
  const r = await api(ctx, `${ctx.base}/v1/data/query/${encodeURIComponent(ctx.dataset)}/${encodeURIComponent(type)}?${q}`, { method: "GET" });
  if (!r.ok) return { ok: false, error: r.error, docs: [] };
  return { ok: true, docs: r.body?.result?.documents || [] };
}

/** ARM 2's query. Every draft of `type` created at or after `sinceIso`, newest
 *  first. THIS EXISTS BECAUSE THE "+" CAN CREATE WITHOUT NAVIGATING. Measured on
 *  guerrilla 4f046cce1: pressing "+" inserted a real `Untitled` draft and the URL
 *  never moved to it, so the URL-derived id was null while documents piled up —
 *  three per run, once clickUntil started retrying. An instrument that leaks a
 *  draft on every failed run is worse than no instrument, so cleanup is keyed off
 *  what the DATASET gained during the leg, not off what the URL admitted to. */
async function draftsCreatedSince(ctx, type, sinceIso) {
  const q = new URLSearchParams({ perspective: "drafts", limit: "50", order: "_createdAt:desc" });
  const r = await api(ctx, `${ctx.base}/v1/data/query/${encodeURIComponent(ctx.dataset)}/${encodeURIComponent(type)}?${q}`, { method: "GET" });
  if (!r.ok) return { ok: false, error: r.error, ids: [] };
  const docs = r.body?.result?.documents || [];
  const since = Date.parse(sinceIso);
  const ids = docs.filter((d) => untitledTemplateShape(d, since)).map((d) => d._id);
  return { ok: true, ids };
}

/** THE UNION, and it is what the self-clean calls. Returns BOTH arms separately
 *  so the run report can say which rule claimed which document — "deleted 3" that
 *  cannot say why is the shape of report that hid this defect for a night. */
async function sweepTargets(ctx, type, sinceIso, { runId = null, now = Date.now() } = {}) {
  const stamped = await stampedDrafts(ctx, type);
  const recent = await draftsCreatedSince(ctx, type, sinceIso);
  // Through sweepCandidate, not through stampedAndReclaimable directly, so the
  // live path and the exported predicate are the SAME function — a sweep whose
  // production code takes a different route from its tests is untested. `since`
  // is Infinity here on purpose: this query already returned only stamped
  // documents, so arm 2 must be unreachable and the stamp must be the only
  // thing that can select one.
  const byStamp = stamped.docs.filter((d) => sweepCandidate(d, Infinity, { runId, now })).map((d) => d._id);
  const byShape = recent.ids.filter((id) => !byStamp.includes(id));
  return {
    ok: stamped.ok && recent.ok,
    errors: [stamped.ok ? null : `stamped query: ${stamped.error}`, recent.ok ? null : `recent query: ${recent.error}`].filter(Boolean),
    by_stamp: byStamp,
    by_shape: byShape,
    ids: [...byStamp, ...byShape],
    stamped_seen: stamped.docs.map((d) => ({ id: d._id, run_id: d[STAMP_FIELD]?.run_id ?? null, created_at: d._createdAt, title: d.title ?? null })),
  };
}

async function readDraft(ctx, type, id) {
  const url = draftQueryUrl(ctx, type, id);
  const r = await api(ctx, url, { method: "GET" });
  if (!r.ok) return { ok: false, error: r.error, url };
  const docs = r.body?.result?.documents || [];
  return { ok: true, url, count: r.body?.result?.count ?? docs.length, doc: docs[0] || null };
}

/** Self-clean. The confirmation run that preceded this harness left a real
 *  draft on guerrilla production carrying "VERIFY W18 HEADING"; an instrument
 *  meant to be re-run on demand must not accumulate one of those per run. */
async function deleteDoc(ctx, type, id) {
  const r = await api(
    ctx,
    `${ctx.base}/v1/data/mutate/${encodeURIComponent(ctx.dataset)}`,
    { method: "POST", body: JSON.stringify({ mutations: [{ delete: { id, type } }] }) },
    { attempts: 2 },
  );
  return r.ok ? { ok: true } : { ok: false, error: r.error };
}

// ─────────────────────────────────────────────────────────────────────────────
//  the beat ledger
// ─────────────────────────────────────────────────────────────────────────────
const PASS = "PASS", FAIL = "FAIL", PENDING = "PENDING";

class Ledger {
  constructor() { this.beats = []; }
  /** `gating: false` marks a beat whose verdict is a MEASUREMENT of a
   *  known-open defect rather than a regression gate — LEG B. It prints in full
   *  and it never moves the exit code. */
  add(name, status, detail, checks = [], { gating = true } = {}) {
    this.beats.push({ name, status, detail, checks, gating });
    return status;
  }
  statuses() { return Object.fromEntries(this.beats.map((b) => [b.name, b.status])); }
  get gatingBeats() { return this.beats.filter((b) => b.gating); }
  get failed() { return this.gatingBeats.filter((b) => b.status === FAIL); }
  get pending() { return this.gatingBeats.filter((b) => b.status === PENDING); }
  get clean() { return this.gatingBeats.length > 0 && this.gatingBeats.every((b) => b.status === PASS); }
}

/** A beat is the AND of its checks; PENDING beats FAIL beats PASS when a
 *  prerequisite never ran, because "unproven" and "broken" are different facts
 *  and collapsing them is how an instrument starts lying. */
function rollup(checks) {
  if (checks.some((c) => c.status === FAIL)) return FAIL;
  if (checks.some((c) => c.status === PENDING)) return PENDING;
  return PASS;
}

const check = (label, status, note = "") => ({ label, status, note });
const ms = (n) => `${(n / 1000).toFixed(1)}s`;

// ─────────────────────────────────────────────────────────────────────────────
//  in-page probes (kept as named constants so a typo is one grep away)
// ─────────────────────────────────────────────────────────────────────────────

// TRAP 1's oracle. `blocks` is a real getter on <bp-paper-canvas>
// (paper-editor/src/canvas/index.js:2113); `.ProseMirror` child count is the
// second witness for a canvas that renders without repopulating the property.
// `_editor` is reported ONLY so a failure can say "the element upgraded and
// stayed empty" instead of "no editor" — it is never the gate.
// `wrapper` is the run wrapper's id, `paper-canvas-<slug>-run-<n>`
// (paper_editor.ex:665, PaperCanvas.run_id/2). It is how the harness proves the
// canvas belongs to the document it just created — see CANVAS_FOR below.
const CANVAS_STATE = `(function(){
  var el = document.querySelector("bp-paper-canvas");
  if (!el) return { host: false, ed: false, blocks: 0, pm: 0, wrapper: null };
  var pm = el.querySelector(".ProseMirror");
  var blocks = 0;
  try { blocks = (el.blocks || []).length; } catch (e) { blocks = -1; }
  var wrap = el.closest("[id^='paper-canvas-']");
  return { host: true, ed: !!el._editor, blocks: blocks, pm: pm ? pm.children.length : 0,
           wrapper: wrap ? wrap.id : null };
})()`;

/** THE STALE-CANVAS TRAP, and it produced a false green before it was closed.
 *  The "+" navigates by push_patch, and the canvas run wrapper is
 *  phx-update="ignore" — so the PREVIOUS document's canvas can still be in the
 *  DOM when the new URL is already showing. Measured on guerrilla 25e69158a:
 *  HYDRATE reported `blocks=2 pm=2 in 0.0s`, instantly, for a document whose
 *  editor had not rendered yet; the caret then landed in the wrong canvas and the
 *  typing went nowhere. "The editor is real" is not enough — it has to be real
 *  FOR THAT ID, which the wrapper id is the only in-DOM witness of. */
// BOTH spellings, and the second one is not defensive padding: the wrapper slug
// for an unpublished paper carries the DRAFT id, so the real wrapper measured on
// guerrilla was `paper-canvas-drafts.paper-7d95421031ede4c0-run-0` while the URL
// said `paper-7d95421031ede4c0`. A prefix built only from the URL's id matches
// nothing and the beat reads as "the editor never rendered".
const canvasRunSelector = (docId) => {
  const bare = docId.replace(/^drafts\./, "");
  return `[id^="paper-canvas-${bare}-run-"], [id^="paper-canvas-drafts.${bare}-run-"]`;
};

const CANVAS_FOR = (docId) =>
  `(function(){var w=document.querySelector(${JSON.stringify(canvasRunSelector(docId))});if(!w)return null;` +
    `var el=w.querySelector("bp-paper-canvas");if(!el)return null;` +
    `var pm=el.querySelector(".ProseMirror");var b=0;` +
    `try{b=(el.blocks||[]).length}catch(e){b=-1}` +
    `return {host:true,ed:!!el._editor,blocks:b,pm:pm?pm.children.length:0,wrapper:w.id};})()`;

// THE NAMED STATE, BY NAME — and its absence is what made LEG B lie.
// #7897's notice renders as
//   main.bp-paper-shell[data-test-id=studio-paper-shell]
//     > article#paper-body-<slug>
//       > .bp-paper-unrenderable[role=alert][data-test-id=paper-unrenderable-notice]
// (components.ex:296 call site, components.ex:378 the component). There is NO
// `.bp-paper-editor` ANYWHERE on that branch: `.bp-paper-editor` is the CANVAS
// surface (paper_editor.ex:186) and a document that cannot render never reaches
// it. So the old region lookup (`.bp-paper-editor || [data-test-id=studio-editor]`)
// resolved to NULL, `visible_text_chars` was measured against nothing, and the
// beat printed "WORDLESSLY BLANK" for a page whose server HTML carries the
// shipped named state exactly once — measured on served 051112568, for BOTH id
// forms. A count taken against a null region is not a low number, it is NO
// MEASUREMENT, so the region that was actually measured is now REPORTED.
const NAMED_STATE_SEL = "[data-test-id='paper-unrenderable-notice'], .bp-paper-unrenderable";
const EDITOR_REGION_SEL = [
  ".bp-paper-editor", // the canvas surface (a renderable document)
  "[data-test-id='studio-editor']",
  "main.bp-paper-shell", // the shell the unrenderable notice lives in
  "[data-test-id='studio-paper-shell']",
  "[data-test-id='studio-doc-beta-shell']",
];

// The four structural counts LEG B reports per fossil, plus the named state and
// how much visible text the editor region carries. Zero text with zero controls
// AND NO NAMED STATE is the blank; a named state is the fix, by name.
const EDITOR_SHAPE = `(function(){
  var q = function (s) { return document.querySelectorAll(s).length; };
  var cands = ${JSON.stringify(EDITOR_REGION_SEL)};
  var region = null, regionSel = null;
  for (var i = 0; i < cands.length; i++) {
    region = document.querySelector(cands[i]);
    if (region) { regionSel = cands[i]; break; }
  }
  var vis = 0;
  if (region) vis = (region.innerText || region.textContent || "").trim().length;
  var named = document.querySelector(${JSON.stringify(NAMED_STATE_SEL)});
  return {
    shell: q(".bp-paper-editor"),
    body: q(".bp-paper-editor-body"),
    contenteditable: q("[contenteditable='true']"),
    addblock: q(".bp-paper-add-block"),
    footer: q("[data-test-id='bp-paper-footer-save']"),
    canvas: q("bp-paper-canvas"),
    named_state: q(${JSON.stringify(NAMED_STATE_SEL)}),
    named_state_role: named ? (named.getAttribute("role") || "(no role)") : null,
    named_state_text: named ? (named.innerText || named.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 140) : null,
    region: regionSel || "(NO REGION MATCHED — the char count below is measured against nothing)",
    visible_text_chars: vis
  };
})()`;

const DOC_URL_RE = /\/studio\/paper\/([^/?#]+)/;

// ─────────────────────────────────────────────────────────────────────────────
//  LEG A — create → type → persist
// ─────────────────────────────────────────────────────────────────────────────
async function legA(page, ctx, ledger, run) {
  const stamp = Date.now().toString(36).toUpperCase();
  const headingText = `JOURNEY HEADING ${stamp}`;
  const paraText = `journey paragraph ${stamp}`;
  run.markers = { heading: headingText, paragraph: paraText };
  // The run's identity, written INTO the documents it creates. `run_id` is what
  // arm 1 of the sweep uses to tell THIS run's in-flight document from a
  // concurrent run's — see stampedAndReclaimable.
  run.run_id = stamp;
  run.run_mark = { harness: HARNESS_MARK, run_id: stamp, host: ctx.base, stamped_at: new Date().toISOString() };

  // ── AUTH ───────────────────────────────────────────────────────────────────
  // A degraded (anonymous) session renders a login page or an unprivileged
  // desk, and EVERY downstream beat then fails for a reason that has nothing to
  // do with the product. So identity is asserted first, with a discriminator
  // that is 1 for admin and 0 for anonymous.
  const ticket = await mintTicket(ctx);
  await page.goto(`${ctx.base}/login/ticket/${encodeURIComponent(ticket)}`);
  await page.goto(ctx.base + DESK_PATH);
  // A 5xx on the desk is an ENVIRONMENT fact and must never be reported as "the
  // Studio is broken". Measured: guerrilla served `500 · Internal Server Error`
  // for this exact path mid-wave, and from inside the DOM that is
  // indistinguishable from a desk that failed to render.
  const docStatus = page.lastDocument?.status ?? null;
  if (docStatus != null && docStatus >= 500) {
    guard(
      `the host served HTTP ${docStatus} for ${DESK_PATH} (${page.lastDocument.url}). ` +
        `That is the deployment failing, not the Studio failing — no product claim can be made from it. Re-run.`,
    );
  }
  const landed = await poll(async () => {
    const n = await page.count(".pane-item, [phx-click='shares-open'], form[action*='login']");
    return n > 0 ? n : null;
  }, SETTLE_CAP, "desk or login painted");
  const shares = await page.count("[phx-click='shares-open']");
  const authUrl = await page.url();
  // WHAT the page actually was, when it was not the desk. Without this a failed
  // AUTH says "nothing painted" and the next hour goes to guessing between an
  // error page, a login wall, a 503 deploy page and a redirect — the exact
  // ambiguity that made the previous instrument's three runs unactionable.
  const authProbe = await page.evaluate(
    `(function(){var b=document.body;return {title:document.title,` +
      `chars:b?(b.innerText||"").trim().length:0,` +
      `head:b?(b.innerText||"").trim().replace(/\\s+/g," ").slice(0,180):"(no body)"};})()`,
  );
  run.auth_probe = { url: authUrl, http_status: docStatus, ...(authProbe && !authProbe.__throw ? authProbe : {}) };
  const authChecks = [
    check("the desk painted something", landed.value ? PASS : FAIL,
      landed.value ? `${landed.value} anchor node(s) in ${ms(landed.waited)}` : `nothing in ${ms(landed.waited)} at ${authUrl} — title="${authProbe?.title}" body=${authProbe?.chars} chars: ${authProbe?.head}`),
    check("identity discriminator [phx-click=shares-open] == 1 (admin)", shares === 1 ? PASS : FAIL,
      shares === 1
        ? "the shares_admin?-gated bar button is present — this session is the admin one"
        : `count=${shares} — 0 means the session degraded to anonymous (a USER-shaped ticket, an expired one, or a dropped Secure cookie). NOT a product defect.`),
  ];
  const authed = rollup(authChecks) === PASS;
  ledger.add("AUTH", rollup(authChecks), String(authUrl).replace(ctx.base, ""), authChecks);

  // ── DESK ───────────────────────────────────────────────────────────────────
  // Structure rows must exist AND `#item-paper` must be a real <button>
  // (panes.ex:380). A div wearing phx-click is not in the tab order, which is
  // the whole reason the owner's controls read as inert.
  let deskChecks;
  if (!authed) {
    deskChecks = [check("Structure rows present and #item-paper is a <button>", PENDING, "AUTH failed — nothing downstream is measurable")];
  } else {
    const rows = await poll(async () => {
      const n = await page.count(".pane-item");
      return n > 0 ? n : null;
    }, SETTLE_CAP, ".pane-item rows");
    const tag = await page.tagOf("#item-paper");
    const ids = await page.evaluate(
      `Array.from(document.querySelectorAll(".pane-item")).map(function(e){return e.id||"(no id)"})`,
    );
    run.structure_rows = Array.isArray(ids) ? ids : null;
    // THE SWALLOWED CLICK. The Structure rows render in the DEAD mount, so the
    // desk "paints" before the LiveView socket has joined — and a phx-click
    // dispatched in that window is DROPPED ON THE FLOOR with no error anywhere.
    // Measured directly: identical runs where the URL patched in 2.4s and where
    // it never patched in 15s, the only difference being how early the click
    // went out. A page with a LiveView-less desk is also the real click-dead
    // failure (Past Mistake #11: check_origin drift → 403 on /live/websocket →
    // Studio silently inert), so this is BOTH a readiness gate and a real
    // assertion — never a sleep, and never optional.
    const live = await poll(async () => {
      const s = await page.evaluate(
        `(function(){var m=document.querySelector("[data-phx-main]");` +
          `return m ? (m.classList.contains("phx-connected") ? "connected" : (m.className||"(no class)")) : "no-main";})()`,
      );
      return s === "connected" ? s : null;
    }, SETTLE_CAP, "[data-phx-main].phx-connected");
    const liveState = live.value || (await page.evaluate(
      `(function(){var m=document.querySelector("[data-phx-main]");return m?(m.className||"(no class)"):"no-main";})()`,
    ));
    deskChecks = [
      check(".pane-item Structure rows > 0", rows.value ? PASS : FAIL,
        rows.value ? `${rows.value} rows in ${ms(rows.waited)}: ${(ids || []).join(", ")}` : `zero rows in ${ms(rows.waited)}`),
      check("#item-paper is a <button>", tag === "BUTTON" ? PASS : FAIL,
        tag === "BUTTON" ? "focusable, Enter/Space-activatable" : `tagName=${tag ?? "(absent)"} — a non-button row is not in the tab order`),
      check("the LiveView socket has JOINED ([data-phx-main].phx-connected)", live.value ? PASS : FAIL,
        live.value
          ? `connected in ${ms(live.waited)} — clicks dispatched from here reach the server`
          : `NOT connected in ${ms(live.waited)} (state="${liveState}") — every phx-click on this page is swallowed silently, which is exactly what "the buttons are inert" looks like`),
    ];
  }
  const deskOk = rollup(deskChecks) === PASS;
  ledger.add("DESK", rollup(deskChecks), DESK_PATH, deskChecks);

  // ── CREATE ─────────────────────────────────────────────────────────────────
  // Click the Structure row, POLL for the pane to open, then click the "+".
  // Three separate checks, because "the create journey is broken" is useless and
  // "the click patched the URL and the pane column never arrived" is a bug
  // report. The click's own effect (Scope.select push_patches to
  // studio_path(nav_path ++ [id]) — handlers/scope.ex:12) is asserted on the
  // URL, which is observable even when the pane never renders.
  //
  // Document rows are polled for by CLASS, never by phx-click: Structure rows
  // (`.pane-item`) and doc rows (`.pane-doc-item`) BOTH carry
  // `phx-click="select"`, so a phx-click selector asserts against a Structure
  // row while believing it holds a document.
  let createChecks, docId = null;
  if (!deskOk) {
    createChecks = [check("clicking + creates a new document and navigates to it", PENDING, "DESK failed")];
  } else {
    // clickUntil, not click: the mount patch replaces this node and swallows a
    // click that lands in the gap (see Page.clickUntil). Attempts are reported.
    const patched = await page.clickUntil(
      "#item-paper",
      async () => {
        const p = await page.evaluate("location.pathname");
        return typeof p === "string" && /\/studio\/paper(\/|$)/.test(p) ? p : null;
      },
      { cap: SETTLE_CAP, label: "URL patches to the paper pane" },
    );
    const clickedPaper = patched.clicked;
    const docRows = await poll(async () => {
      const n = await page.count(".pane-doc-item");
      return n > 0 ? n : null;
    }, SETTLE_CAP, ".pane-doc-item rows");
    // THE ADD-BUTTON SELECTOR TRAP. `.pane-add-btn[phx-value-type="paper"]` is
    // NOT unique: the airdrop share-access button carries the same class AND the
    // same phx-value-type (components.ex:973), and it renders FIRST — so that
    // selector clicks "Share access to paper" and opens a sheet while the driver
    // believes it pressed "+". Pin the EVENT, which is the only unique thing:
    // phx-click="new-document".
    const addSel = 'button.pane-add-btn[phx-click="new-document"][phx-value-type="paper"]';
    // Polled, not sampled: the header actions arrive with the pane's own patch,
    // and reading the name one tick too early reports "no accessible name" for a
    // button that has one.
    const addProbe = await poll(async () => {
      const v = await page.evaluate(
        `(function(){var el=document.querySelector(${JSON.stringify(addSel)});if(!el)return null;` +
          `return {name:(el.getAttribute("aria-label")||el.textContent||"").trim(),` +
          `siblings:document.querySelectorAll('.pane-add-btn[phx-value-type="paper"]').length};})()`,
      );
      return v && !v.__throw ? v : null;
    }, SETTLE_CAP, "the new-document + button");
    const addName = addProbe.value?.name ?? null;
    // What the desk actually shows instead, so a failure names the state a human
    // would be looking at rather than only the selector that was missing.
    const paneShape = await page.evaluate(
      `(function(){var p=document.getElementById("studio-panes");return {` +
        `columns:Array.from(document.querySelectorAll(".pane-column")).map(function(c){return c.id||"(no id)"}),` +
        `add_buttons:document.querySelectorAll(".pane-add-btn").length,` +
        `text:p?(p.innerText||"").replace(/\\s+/g," ").trim().slice(0,160):"(no #studio-panes)"};})()`,
    );
    run.pane_shape_after_select = paneShape;
    // The high-water mark for the litter sweep, taken one tick before the FIRST
    // press. Anything this type gains from here on was created by this leg.
    run.create_pressed_at = new Date(Date.now() - 2000).toISOString();
    const nav = await page.clickUntil(
      addSel,
      async () => {
        const u = await page.url();
        const m = DOC_URL_RE.exec(String(u || ""));
        return m ? m[1] : null;
      },
      { cap: SETTLE_CAP, label: "URL carries a document id" },
    );
    const clickedAdd = nav.clicked;
    docId = nav.value;
    run.created_doc_id = docId;
    // ── THE PROVENANCE STAMP, AND ITS PLACEMENT IS THE FIX ────────────────
    // Written HERE: after the id is known, before HYDRATE and before TYPE. Every
    // document the old title-keyed sweep could never reclaim was killed between
    // those two points, so a stamp written any later would miss exactly the
    // class it exists for. Non-fatal by design — see stampRun's header. The
    // failure is recorded on the run object and printed with the self-clean
    // line, because a stamp that silently did not land is a run that has just
    // manufactured the debris this predicate was built to prevent.
    if (docId) {
      const stamped = await stampRun(ctx, "paper", `drafts.${docId}`, run.run_mark);
      run.stamp = { id: `drafts.${docId}`, mark: run.run_mark, ...stamped };
    } else {
      run.stamp = { id: null, mark: run.run_mark, ok: false, error: 'the "+" never produced an id — nothing to stamp (arm 2 covers this case)' };
    }
    // What the screen says when the "+" did NOT produce a document. A flash is
    // the difference between "the server refused and told the user" and the
    // owner's actual complaint, which was silence.
    let postAdd = null;
    if (!docId) {
      postAdd = await page.evaluate(
        `(function(){var p=document.getElementById("studio-panes");` +
          `var f=document.querySelector("[id^='flash'], .alert, [role='alert']");` +
          `return {path:location.pathname,flash:f?(f.innerText||"").replace(/\\s+/g," ").trim().slice(0,120):"(none)",` +
          `text:p?(p.innerText||"").replace(/\\s+/g," ").trim().slice(0,160):"(no #studio-panes)"};})()`,
      );
      // DID THE PRESS CREATE ANYTHING? "created but did not navigate" and
      // "did nothing at all" are completely different defects, and the URL alone
      // cannot tell them apart — the API can.
      const orphans = await draftsCreatedSince(ctx, "paper", run.create_pressed_at);
      postAdd = { ...(postAdd && !postAdd.__throw ? postAdd : {}), orphans: orphans.ids };
      run.post_add_state = postAdd;
    }
    // ── THE WIRE READING (spd-w18-desk-click-latency, criterion 0) ───────
    //
    // The old detail on the row below ENDED "the row's phx-click never reached
    // the server" — a claim this harness had no instrument for. It was a guess,
    // and it is exactly the guess that costs a wave: "never reached the server"
    // and "reached the server and the server said nothing" are opposite defects
    // with opposite fixes, and from inside the DOM they are the same silence.
    // `patched.wire` is the reading, and it is taken off /live/websocket.
    run.press_wire = { item_paper: patched.wire || null, new_document: nav.wire || null };
    const wire = patched.wire || { verdict: "CANNOT READ", frames: null, detail: "no reading was taken" };
    createChecks = [
      check("#item-paper click patches the URL to the paper pane", clickedPaper && patched.value ? PASS : FAIL,
        patched.value
          ? `${patched.value} in ${ms(patched.waited)} after ${patched.attempts} press(es) · ${wire.detail}`
          : `the URL never reached /studio/paper after ${patched.attempts} press(es) in ${ms(patched.waited)} (a press landed=${clickedPaper}) · ${wire.detail}`),
      // A THREE-VALUED CHECK, and CANNOT READ is a FAIL on purpose (which drives
      // the run's non-zero exit): an instrument with no reading must never print
      // the same line as an instrument that read a zero.
      check(
        "the run says whether the press put a phx-click frame on /live/websocket",
        wire.verdict === "CANNOT READ" ? FAIL : PASS,
        patched.value
          ? `the press ANSWERED (URL patched), and the wire says ${wire.verdict}. ${wire.detail}`
          : `THE PRESS DID NOT PATCH THE URL, and the wire says ${wire.verdict}. ${wire.detail}` +
            (wire.verdict === "NOT SENT"
              ? " — so this is a CLIENT-SIDE DISCARD: the fix belongs on the affordance (refuse the press visibly, or make it survive the pre-join window), NOT on the server handler."
              : wire.verdict === "SENT"
                ? " — so this is a SERVER-SIDE non-answer: the press arrived and nothing came back in time. The fix belongs on the handler's latency, NOT on the client."
                : "")),
      check("the paper pane lands .pane-doc-item document rows", docRows.value ? PASS : FAIL,
        docRows.value
          ? `${docRows.value} rows in ${ms(docRows.waited)}`
          : `NO document rows in ${ms(docRows.waited)}. columns=[${(paneShape?.columns || []).join(", ")}] add_buttons=${paneShape?.add_buttons} · the desk says: "${paneShape?.text}"`),
      check('the "+" button has an accessible name', addName && String(addName).length > 0 ? PASS : FAIL,
        addName
          ? `aria-label="${addName}" (${addProbe.value.siblings} .pane-add-btn share phx-value-type="paper" — the event pins the right one)`
          : `${addSel} did not appear within ${ms(addProbe.waited)}, or its accessible name is empty`),
      check("the + navigates to a NEW document id", docId ? PASS : FAIL,
        docId
          ? `${docId} in ${ms(nav.waited)} after ${nav.attempts} press(es)`
          : `URL never matched /studio/paper/<id> after ${nav.attempts} press(es) in ${ms(nav.waited)} (a press landed=${clickedAdd})` +
            `${postAdd?.orphans?.length ? ` · BUT THE PRESS DID CREATE ${postAdd.orphans.length} DRAFT(S): ${postAdd.orphans.join(", ")} — the document exists and the navigation to it does not` : " · and no draft was created either"}` +
            ` · the desk then says: "${postAdd?.text}" url=${postAdd?.path} flash="${postAdd?.flash}"`),
    ];
  }
  const created = rollup(createChecks) === PASS;
  ledger.add("CREATE", rollup(createChecks), docId ? `→ ${docId}` : "no document", createChecks);

  // ── HYDRATE ────────────────────────────────────────────────────────────────
  // TRAP 1. Readiness is blocks/ProseMirror children, never `_editor`. A canvas
  // still empty at the ceiling is a FAILED BEAT — the wave-17 bug (a paper
  // created with `blocks` nil) presented as exactly this, and a harness that
  // "waits longer" reports nothing.
  //
  // AND it must be the canvas FOR THIS DOCUMENT. Scoping the poll to the run
  // wrapper `paper-canvas-<docId>-run-*` is what stops the previous document's
  // canvas — which survives the push_patch because the wrapper is
  // phx-update="ignore" — from answering for the new one.
  let hydrateChecks, canvas = null;
  if (!created) {
    hydrateChecks = [check("the canvas hydrates with real blocks for THIS document", PENDING, "CREATE failed — there is no document to open")];
  } else {
    const probe = CANVAS_FOR(docId);
    const h = await poll(async () => {
      const s = await page.evaluate(probe);
      if (!s || s.__throw) return null;
      return (s.blocks > 0 || s.pm > 0) ? s : null;
    }, HYDRATE_CAP, `canvas blocks for ${docId}`);
    canvas = h.value || (await page.evaluate(probe)) || (await page.evaluate(CANVAS_STATE));
    run.canvas_state = canvas;
    hydrateChecks = [
      check(`bp-paper-canvas for ${docId} has el.blocks.length > 0 (or .ProseMirror children > 0)`, h.value ? PASS : FAIL,
        h.value
          ? `blocks=${canvas.blocks} pm=${canvas.pm} in ${ms(h.waited)} · wrapper=${canvas.wrapper}`
          : canvas?.host
            ? `STILL EMPTY at the ${ms(HYDRATE_CAP)} ceiling: _editor=${canvas.ed} blocks=${canvas.blocks} pm=${canvas.pm} wrapper=${canvas.wrapper}` +
              (canvas.ed ? " — the element UPGRADED and never populated: this is the blank editor, not a slow one" : "")
            : `no canvas run wrapper matching ${canvasRunSelector(docId)} within ${ms(HYDRATE_CAP)} — the editor never rendered FOR THIS DOCUMENT` +
              `${canvas?.wrapper ? ` · the wrapper actually on the page is ${canvas.wrapper} (blocks=${canvas.blocks}), i.e. ANOTHER document's canvas` : " · and no canvas run wrapper of any kind is present"}`,
      ),
    ];
  }
  const hydrated = rollup(hydrateChecks) === PASS;
  ledger.add("HYDRATE", rollup(hydrateChecks), docId || "—", hydrateChecks);

  // ── TYPE ───────────────────────────────────────────────────────────────────
  // The seeded template is [heading tpl-title (locked, role=title), empty
  // paragraph tpl-body] — content/papers/template.ex:124. So the caret goes to
  // the end of the first ProseMirror child for the heading and the second for
  // the paragraph, and real key events do the rest.
  let typeChecks;
  if (!hydrated) {
    typeChecks = [check("a heading and a paragraph can be typed", PENDING, "HYDRATE failed — there is nothing to type into")];
  } else {
    const exMark = page.exceptionMark();
    // Scoped to THIS document's run wrapper, for the same reason HYDRATE is: an
    // unscoped `.ProseMirror` can be the previous document's surviving canvas, and
    // typing into that is how a run reports "the keystrokes went nowhere".
    const run0 = canvasRunSelector(docId);
    // BLOCKS RENDERED IS NOT THE SAME AS TYPEABLE. `blocks` can be 2 and the
    // ProseMirror markup present while TipTap has not attached — the canvas is
    // server-rendered before the editor mounts — and keystrokes into that go
    // nowhere while every dispatch still "succeeds". Measured on guerrilla
    // 25e69158a: HYDRATE green at 0.0s for the right wrapper, and the typed text
    // never appeared. So typing waits for a REAL editable surface inside this
    // document's wrapper, which is a predicate, not a sleep.
    const editable = await poll(async () => {
      const v = await page.evaluate(
        `(function(){var w=document.querySelector(${JSON.stringify(run0)});if(!w)return null;` +
          `var el=w.querySelector("bp-paper-canvas");` +
          `var ce=w.querySelector('[contenteditable="true"]');` +
          `var ed=el&&el._editor;` +
          `return {ce:!!ce, editable: ed ? (typeof ed.isEditable==="boolean"?ed.isEditable:true) : false};})()`,
      );
      return v && !v.__throw && v.ce && v.editable ? v : null;
    }, SETTLE_CAP, "an editable ProseMirror for this document");

    // Typed ONCE, then re-tried ONCE if the text did not land — bounded, and the
    // attempt count is reported. Same doctrine as clickUntil: this can rescue a
    // race, never a broken editor.
    let h1 = null, p1 = null, reached = { value: null, waited: 0 }, passes = 0;
    for (let attempt = 1; attempt <= 2 && !reached.value; attempt++) {
      passes = attempt;
      h1 = await page.caretAtEndOf(`${run0} .ProseMirror > *:nth-child(1)`);
      if (h1 === true) await page.type(headingText);
      p1 = await page.caretAtEndOf(`${run0} .ProseMirror > *:nth-child(2)`);
      if (p1 === true) await page.type(paraText);
      // The DOM half is a proof that the KEYSTROKES REACHED THE EDITOR, and
      // nothing more. It is explicitly NOT the persistence proof: this text lives
      // inside a phx-update="ignore" wrapper the server never sees.
      reached = await poll(async () => {
        const t = await page.evaluate(
          `(function(){var w=document.querySelector(${JSON.stringify(run0)});` +
            `return w?(w.innerText||w.textContent||""):""})()`,
        );
        return typeof t === "string" && t.includes(headingText) && t.includes(paraText) ? t.length : null;
      }, SETTLE_CAP, "typed text in this document's canvas");
    }
    const newEx = page.exceptionsSince(exMark);
    typeChecks = [
      check("the editor for this document is editable before a key is sent", editable.value ? PASS : FAIL,
        editable.value
          ? `contenteditable + a live TipTap editor in ${ms(editable.waited)}`
          : `no editable ProseMirror inside ${run0} within ${ms(editable.waited)} — the canvas rendered but the editor never attached, so nothing typed here could land`),
      check("the caret lands in the seeded title and body blocks", h1 === true && p1 === true ? PASS : FAIL,
        `title-block caret=${h1} body-block caret=${p1}`),
      check("keystrokes reach the editor (DOM only — NOT the persistence proof)", reached.value ? PASS : FAIL,
        reached.value
          ? `both markers visible in the canvas in ${ms(reached.waited)} after ${passes} typing pass(es)`
          : `the canvas never showed the typed text after ${passes} typing pass(es)`),
      check("no exception while typing", newEx.length === 0 ? PASS : FAIL, newEx.slice(0, 2).join(" · ")),
    ];
  }
  const typed = rollup(typeChecks) === PASS;
  ledger.add("TYPE", rollup(typeChecks), `"${headingText}" + "${paraText}"`, typeChecks);

  // ── PERSIST ────────────────────────────────────────────────────────────────
  // The oracle. Autosave is a 300ms debounce with no Save button to press
  // (TRAP 3), so this polls the API until the blocks carry both markers.
  let persistChecks;
  if (!typed) {
    persistChecks = [check("the typed text is readable back from the API", PENDING, "TYPE failed — nothing was entered to persist")];
  } else {
    const q = draftQueryUrl(ctx, "paper", `drafts.${docId}`);
    const qPub = draftQueryUrl(ctx, "paper", docId);
    let seen = null;
    const p = await poll(async () => {
      for (const id of [`drafts.${docId}`, docId]) {
        const r = await readDraft(ctx, "paper", id);
        if (!r.ok) continue;
        if (!r.doc) continue;
        seen = { id, blocks: r.doc.blocks || [], url: r.url };
        const flat = JSON.stringify(seen.blocks);
        if (flat.includes(headingText) && flat.includes(paraText)) return seen;
      }
      return null;
    }, PERSIST_CAP, "API carries both markers");
    const blocks = (p.value || seen)?.blocks || [];
    const types = blocks.map((b) => b?.type ?? "(untyped)");
    run.persisted = { queried: [q, qPub], id: (p.value || seen)?.id ?? null, block_count: blocks.length, block_types: types };
    persistChecks = [
      check("drafts-perspective query carries the typed heading AND paragraph", p.value ? PASS : FAIL,
        p.value
          ? `${blocks.length} blocks [${types.join(", ")}] in ${ms(p.waited)} via ${p.value.url.replace(ctx.base, "")}`
          : `NOT in the API after ${ms(p.waited)} — last seen ${blocks.length} blocks [${types.join(", ")}]. Autosave did not reach the server.`),
      check("the persisted set carries a heading and a paragraph block", types.includes("heading") && types.includes("paragraph") ? PASS : FAIL,
        `types=[${types.join(", ")}]`),
    ];
  }
  const persisted = rollup(persistChecks) === PASS;
  ledger.add("PERSIST", rollup(persistChecks), run.persisted?.id || "—", persistChecks);

  // ── RELOAD ─────────────────────────────────────────────────────────────────
  // The last thing a human does: come back and find their work. This re-opens
  // the document URL cold and re-asserts hydration and the heading.
  let reloadChecks;
  if (!persisted) {
    reloadChecks = [check("the heading survives a reload", PENDING, "PERSIST failed — there is nothing to come back to")];
  } else {
    // A FULL navigation, so nothing survives from before — and still scoped to
    // this document's run wrapper, so the assertion cannot be satisfied by
    // anything else the page happens to hold.
    const run0 = canvasRunSelector(docId);
    await page.goto(`${ctx.base}${DESK_PATH}/paper/${encodeURIComponent(docId)}`);
    const back = await poll(async () => {
      const s = await page.evaluate(CANVAS_FOR(docId));
      if (!s || s.__throw || !(s.blocks > 0 || s.pm > 0)) return null;
      const t = await page.evaluate(
        `(function(){var w=document.querySelector(${JSON.stringify(run0)});` +
          `return w?(w.innerText||w.textContent||""):""})()`,
      );
      return typeof t === "string" && t.includes(headingText) ? s : null;
    }, HYDRATE_CAP, "reloaded canvas carries the heading");
    reloadChecks = [
      check("re-opening the document shows the typed heading", back.value ? PASS : FAIL,
        back.value ? `blocks=${back.value.blocks} and the heading is present in ${ms(back.waited)}` : `the heading was not on the reloaded page within ${ms(HYDRATE_CAP)}`),
    ];
  }
  ledger.add("RELOAD", rollup(reloadChecks), docId || "—", reloadChecks);

  return { docId };
}

// ─────────────────────────────────────────────────────────────────────────────
//  LEG B — the draft-only fossils (report-only; FAILS today, on purpose)
// ─────────────────────────────────────────────────────────────────────────────
async function legB(page, ctx, ledger, run) {
  run.fossils = [];
  for (const f of FOSSILS) {
    // The API side first, so a genuinely-absent document can never be reported
    // as a blank editor. The drafts-perspective query is the instrument here:
    // /v1/data/doc answers 404 for a draft-only document.
    const api1 = await readDraft(ctx, "paper", f.draftId);
    const exists = api1.ok && !!api1.doc;
    const apiBlocks = (api1.doc?.blocks || []).length;

    await page.goto(`${ctx.base}${DESK_PATH}/paper/${encodeURIComponent(f.docId)}`);
    // Give the editor the same hydration budget LEG A gets, then measure. This
    // poll's TIMEOUT is the expected outcome today, which is why it is a
    // measurement and not a wait: whatever it settles on gets reported.
    await poll(async () => {
      const s = await page.evaluate(EDITOR_SHAPE);
      return s && !s.__throw && (s.body > 0 || s.contenteditable > 0 || s.named_state > 0 || s.visible_text_chars > 0) ? s : null;
    }, SETTLE_CAP, "fossil editor shows anything");
    const shape = await page.evaluate(EDITOR_SHAPE);
    // A NAMED STATE COUNTS ON ITS OWN NAME, not only on a char count: the notice
    // is the shipped answer to "this document cannot render", so finding it by
    // `data-test-id` is the primary witness and the char count is corroboration.
    // Both are reported, so a notice that renders EMPTY (a named state with no
    // words in it) is still visible as `named_state=1 visible_text=0`.
    const named = !!shape && !shape.__throw && (shape.named_state > 0 || shape.visible_text_chars > 0);
    run.fossils.push({ ...f, exists_in_drafts: exists, api_block_count: apiBlocks, shape });

    const checks = [
      check("the document exists in the drafts perspective", exists ? PASS : FAIL,
        exists ? `${f.draftId} · blocks=${apiBlocks} · _updatedAt=${api1.doc?._updatedAt}` : `not found via ${api1.url?.replace(ctx.base, "")}`),
      check("the editor answers with a NAMED VISIBLE STATE, never absence", named ? PASS : FAIL,
        `shell=${shape?.shell} body=${shape?.body} contenteditable=${shape?.contenteditable} addblock=${shape?.addblock} footer=${shape?.footer} canvas=${shape?.canvas} ` +
        `named_state=${shape?.named_state}${shape?.named_state ? `[role=${shape.named_state_role}]` : ""} ` +
        `region=${shape?.region} visible_text=${shape?.visible_text_chars} chars` +
        (named
          ? `${shape?.named_state ? ` · the page SAYS SO BY NAME: "${shape.named_state_text}"` : ""}`
          : " — WORDLESSLY BLANK: this is the open never-blank defect, not a regression"),
      ),
    ];
    ledger.add(`FOSSIL/${f.docId.slice(-8)}`, rollup(checks), f.docId, checks, { gating: false });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  LEG C — the desk-row census (report-only)
// ─────────────────────────────────────────────────────────────────────────────
//  THE QUESTION: "whatever the Desk Structure buttons do when clicked is
//  verified to do it, or the dead ones are named." Wave 18 proved the rows are
//  real <button>s with aria-current and aria-label and focus rings. Nobody had
//  CLICKED each row and recorded what came back. This leg does that, per row,
//  and records ROW KIND · ELEMENT ID · VISIBLE LABEL · OUTCOME in ONE line —
//  wave 18's census recorded labels while the desk serves opaque ids, so nobody
//  could prove the two censuses were describing the same rows.
//
//  IT IS REPORT-ONLY ({gating:false}) AND CANNOT BE MADE A GATE. Ledger.add
//  honours `gating:false` and clean/failed/pending all filter to gatingBeats, so
//  a red row here cannot move the exit code; and per charter D241 tooling/**
//  dodges the required gate anyway, so this is EVIDENCE, never a merge gate.
//
//  THE NAIVE CENSUS IS WRONG THREE WAYS, and all three were caught by RUNNING it
//  rather than by reading it:
//
//  1. SNAPSHOT-DIFF ATTRIBUTION IS UNSOUND. Diffing {url, aria-current, pane
//     count, row count} before/after credited the DEAD #item-sheet with the
//     PREVIOUS row's answer arriving 900 ms later, and on /good/ every row
//     reported its predecessor's URL. A quiesce fixed the off-by-one and did NOT
//     fix the false green, and CANNOT: measured answer latency is 1.6s to
//     never-within-15s, so no bounded quiet window is sound. So the effect must
//     NAME THE ROW — aria-current newly on THIS element, or the URL newly
//     carrying THIS row's OWN phx-value-id as a path segment. Pane and row counts
//     are still recorded, and they can NEVER make a row green on their own.
//
//  2. IDENTITY THEN FABRICATES A DEAD ROW FOR EVERY plugin_link. A plugin entry
//     is `<a id="plugin-link-…" class="pane-item nav-plugin-entry" href=…>`
//     (components.ex:1192): it matches `.pane-item` so the census enumerates it,
//     and it has NEITHER phx-value-id NOR aria-current, so both witnesses are
//     structurally unavailable. Proven with a fixture anchor that really
//     navigated and was reported DEAD. An anchor is attributed to its OWN href.
//     And an anchor is a real page load, so the census RETURNS TO THE DESK
//     afterwards and re-arms it: the row after one needed 2 presses, not 1,
//     because it landed in a fresh dead mount.
//
//  3. AN UNNAMED BEAT IS SILENTLY UNASSERTED — see SELF_TEST_EXPECT's coverage
//     guard. This leg's first version failed on /rot/ with five FAIL rows and the
//     self-test still printed SELF-TEST PASS and exited 0.
//
//  WHAT IS NOT PRESSED, AND WHY IT IS STILL A ROW IN THE TABLE. The three
//  `.pane-add-btn` header controls are INVENTORIED with the reason instead of
//  pressed: "+" CREATES A DOCUMENT and the other two open a modal OVER the desk,
//  so pressing any of them would litter the dataset or destroy the state the
//  remaining rows are measured against. None of the three carries an `id` (two
//  carry a data-test-id, the "+" carries neither — components.ex:1106/1116/1124),
//  which is recorded, because a builder reaching for `#…` cannot address them at
//  all. Each of those inventory rows carries a REAL assertion about its reason,
//  so the day one of them stops being true the row goes red and says "re-decide"
//  instead of quietly staying green.
//
//  `.pane-section-header` IS NOT AN INVENTORY ROW — IT IS A TRIPWIRE. Measured
//  on served c81b8e66d (guerrilla, 2026-09-06) it renders ZERO times on the
//  deployed desk, on the bare desk and again with the Papers pane open.
//  RULING (lead-studio-9, 2026-09-06): the deployed desk should NOT render
//  `.pane-section-header` today. Its only desk call site is the `:header ->` arm
//  at api/lib/barkpark_web/live/studio/studio_live/components.ex:1434 and   (lineref-ok:
//  the ruling is quoted VERBATIM, so its own citation cannot be paraphrased into
//  symbol form; re-find the spot by the `:header ->` arm if the line moves)
//  `git grep 'type: :header' origin/main -- api/lib` returns ZERO producers — no
//  pane builder emits a `:header` item, so the arm is unreachable and the zero
//  count on guerrilla is correct. The harness used to assert a PASS-by-
//  construction verdict for the shape, against a fixture that rendered it
//  itself; that assertion could never have fired against production. Now /good
//  renders none, /rot renders ONE so the tripwire's red is demonstrated offline,
//  and any `.pane-section-header` on a REAL desk is a FAIL saying "a shape that
//  had no producer on 2026-09-06 has appeared".

const CENSUS_STAMP = "data-legc-row";

/** The enumeration, as a JS FUNCTION EXPRESSION so it can be called both to
 *  enumerate and to re-locate one row after a LiveView patch. It STAMPS each
 *  matched element with `data-legc-row=<index>`, which is how a row without an
 *  id is addressable at all — and it re-stamps on every call, because a patch
 *  replaces the node and takes the stamp with it. Rows are identified across
 *  patches by KEY (kind + owning id + visible label + occurrence), never by
 *  index. */
const CENSUS_FN = `(function(){
  var out = [], seen = [], keys = {};
  var text = function (el) {
    return (el.getAttribute("aria-label") || el.innerText || el.textContent || "")
      .replace(/\\s+/g, " ").trim().slice(0, 80);
  };
  // The VISIBLE LABEL, and \`title\` is reported as \`title:"…"\` rather than folded
  // in silently: two of the three .pane-add-btn controls have NOTHING BUT a
  // title, and a census that printed that as an ordinary label would hide the
  // fact that their only accessible name is a tooltip.
  var labelOf = function (el) {
    var t = text(el);
    if (t) return t;
    var title = el.getAttribute("title");
    return title ? 'title:"' + title.replace(/\\s+/g, " ").trim().slice(0, 60) + '"' : "";
  };
  var push = function (el, kind, extra) {
    if (!el || seen.indexOf(el) !== -1) return;
    seen.push(el);
    var idx = out.length;
    el.setAttribute(${JSON.stringify(CENSUS_STAMP)}, String(idx));
    var label = labelOf(el) || "(no visible label)";
    var owner = (extra && extra.wrapper_id) || el.id || "(no id)";
    var key = kind + "#" + owner + "|" + label;
    keys[key] = (keys[key] || 0) + 1;
    if (keys[key] > 1) key = key + "@" + keys[key];
    var row = {
      index: idx, key: key, kind: kind, tag: el.tagName,
      id: el.id || null, label: label,
      test_id: el.getAttribute("data-test-id") || null,
      phx_click: el.getAttribute("phx-click") || null,
      phx_value_id: el.getAttribute("phx-value-id") || null,
      phx_value_idx: el.getAttribute("phx-value-idx") || null,
      href: el.getAttribute("href") || null,
      aria_label: el.getAttribute("aria-label") || null,
      aria_current: el.getAttribute("aria-current") || null,
      disabled: !!el.disabled
    };
    if (extra) for (var k in extra) row[k] = extra[k];
    out.push(row);
  };
  var each = function (sel, fn) { Array.prototype.forEach.call(document.querySelectorAll(sel), fn); };
  // ORDER IS THE KIND DISCRIMINATOR: the most specific shape claims an element
  // first and \`seen\` stops a broader selector re-claiming it under a wrong kind.
  // .pane-item and .pane-doc-item BOTH carry phx-click="select", so nothing here
  // keys off phx-click.
  each(".pane-doc-item", function (w) {
    var b = w.querySelector("button.bp-doc-row-body");
    if (b) push(b, "pane_doc_item", { wrapper_id: w.id || null,
      note: "the .pane-doc-item DIV is only a wrapper (it hosts the bulk-publish checkbox); the control is the inner button.bp-doc-row-body, which owns phx-value-id, aria-label AND aria-current" });
    else push(w, "pane_doc_item_bodyless", { wrapper_id: w.id || null,
      note: "a .pane-doc-item with NO inner button.bp-doc-row-body — there is no control in this row to press" });
  });
  each("a.pane-item", function (el) { push(el, "plugin_link", {}); });
  each("button.pane-item", function (el) { push(el, "pane_item", {}); });
  each(".pane-item", function (el) { push(el, "pane_item_inert", {
    note: "matches .pane-item but is neither <a> nor <button> — no keyboard can reach it" }); });
  each("button.pane-column--collapsed", function (el) { push(el, "collapsed_strip", {}); });
  each(".pane-add-btn", function (el) { push(el, "add_btn", {}); });
  each(".pane-section-header", function (el) { push(el, "section_header", {}); });
  return {
    rows: out,
    url: location.pathname + location.search,
    // The ABSOLUTE url, because it is what a row's recovery navigates back to.
    // \`ctx.base + url\` would be wrong on the fixture, whose base carries a
    // \`/good\` or \`/rot\` path prefix that \`location.pathname\` already includes.
    full_url: location.href,
    panes: document.querySelectorAll(".pane-column").length,
    doc_rows: document.querySelectorAll(".pane-doc-item").length,
    item_rows: document.querySelectorAll(".pane-item").length
  };
})`;

/** Re-locate ONE row by key and read the state its witnesses live in. `selfId`
 *  is read separately because a collapsed strip STOPS being enumerable the
 *  moment it works (it is no longer `button.pane-column--collapsed`), so its
 *  witness has to be read off the element's own id. */
const censusProbe = (key, selfId) => `(function(){
  var c = ${CENSUS_FN}();
  var r = null;
  for (var i = 0; i < c.rows.length; i++) if (c.rows[i].key === ${JSON.stringify(key)}) { r = c.rows[i]; break; }
  var byId = ${selfId ? `document.getElementById(${JSON.stringify(selfId)})` : "null"};
  return {
    found: !!r,
    press_selector: r ? "[${CENSUS_STAMP}='" + r.index + "']" : null,
    aria_current: r ? r.aria_current : null,
    url: c.url, panes: c.panes, doc_rows: c.doc_rows, item_rows: c.item_rows,
    self_exists: !!byId,
    self_collapsed: byId ? (String(byId.className || "").indexOf("pane-column--collapsed") !== -1) : null
  };
})()`;

/** The WITNESS probe, and it is deliberately CHEAP. The enumeration above walks
 *  every candidate in the document and writes an attribute onto each one; asking
 *  it for one row's aria-current on every poll tick cost a MEASURED 8.1s for a
 *  3.0s row cap on a loaded host, which blew the hard budget by 5s. This reads
 *  the row by id (free), the counts with three selector counts, and nothing else. */
function censusWitnessProbe(rec, stampSel) {
  const byId = rec.id ? `document.getElementById(${JSON.stringify(rec.id)})` : "null";
  const byWrapper = rec.wrapper_id
    ? `(function(){var w=document.getElementById(${JSON.stringify(rec.wrapper_id)});return w?w.querySelector("button.bp-doc-row-body"):null;})()`
    : "null";
  const byStamp = stampSel ? `document.querySelector(${JSON.stringify(stampSel)})` : "null";
  return `(function(){
    var own = ${byId};
    var el = own || ${byWrapper} || ${byStamp};
    return {
      found: !!el,
      aria_current: el ? (el.getAttribute("aria-current") || null) : null,
      self_exists: !!own,
      self_collapsed: own ? (String(own.className || "").indexOf("pane-column--collapsed") !== -1) : null,
      url: location.pathname + location.search,
      panes: document.querySelectorAll(".pane-column").length,
      doc_rows: document.querySelectorAll(".pane-doc-item").length,
      item_rows: document.querySelectorAll(".pane-item").length
    };
  })()`;
}

/** Address the row WITHOUT the stamp wherever it has an id of its own — the
 *  `[id="…"]` attribute form needs no CSS escaping, which `#drafts.paper-…`
 *  would. Only a genuinely id-less row (all three `.pane-add-btn` controls, a
 *  section header) needs the stamp, and those are never pressed. */
function pressSelectorFor(rec) {
  if (rec.kind === "pane_doc_item" && rec.wrapper_id) {
    return `[id=${JSON.stringify(rec.wrapper_id)}] button.bp-doc-row-body`;
  }
  return rec.id ? `[id=${JSON.stringify(rec.id)}]` : null;
}

const UNMEASURED = "UNMEASURED, which is not the same as working";
const PRESSABLE = new Set(["pane_item", "pane_doc_item", "plugin_link", "collapsed_strip"]);

// `aria-current` is `"true"` on both row components (panes.ex pane_item and
// pane_doc_item), never `aria-selected` — but an absent attribute reads back as
// null and a removed one as "", and LiveView can render the literal "false".
const isCurrent = (v) => v != null && v !== "" && v !== "false";

/** Path-SEGMENT containment, never substring. `url.includes("post")` is true for
 *  `/studio/posts` and for `/w/postmortem/...`, so a substring test hands one
 *  row's green to a neighbour whose id happens to be a prefix. */
const urlNames = (url, id) =>
  !!id && String(url || "").split(/[/?#&=]/).filter(Boolean).includes(String(id));

const hrefPath = (href) => {
  if (!href) return null;
  try { return new URL(href, "http://x").pathname; } catch { return String(href).split("?")[0]; }
};

/** THE ONLY WAY A ROW GOES GREEN: an effect that NAMES THIS ROW. Returns the
 *  witness sentence, or null. Pane/row/doc-row counts are deliberately NOT
 *  consulted here — they are recorded in the row's detail and they cannot reach
 *  this function, which is what makes "counts cannot make a beat green" a
 *  property of the code rather than a promise in a comment. */
function identityWitness(rec, before, after) {
  const urlNewlyNames = (id) => !!id && !urlNames(before.url, id) && urlNames(after.url, id);
  if (rec.kind === "plugin_link") {
    const p = hrefPath(rec.href);
    const now = String(after.url || "").split("?")[0];
    if (p && after.url !== before.url && (now === p || now.endsWith(p))) {
      return `the page is now this anchor's OWN href (${p})`;
    }
    return null;
  }
  if (rec.kind === "collapsed_strip") {
    if (before.self_collapsed === true && after.self_exists && after.self_collapsed === false) {
      return `#${rec.id} is no longer .pane-column--collapsed — THIS strip expanded`;
    }
    if (urlNewlyNames(rec.phx_value_idx)) {
      return `the URL newly carries this strip's own phx-value-idx (${rec.phx_value_idx})`;
    }
    return null;
  }
  if (!isCurrent(before.aria_current) && isCurrent(after.aria_current)) {
    return `aria-current="${after.aria_current}" landed on THIS element`;
  }
  if (urlNewlyNames(rec.phx_value_id)) {
    return `the URL newly carries this row's own phx-value-id (${rec.phx_value_id})`;
  }
  return null;
}

/** The rows that are NOT pressed still get a verdict, and the verdict asserts
 *  the REASON they are not pressed. A row whose reason has gone stale reds and
 *  says so, so the inventory cannot rot into a list of excuses. */
function inventoryVerdict(rec) {
  if (rec.kind === "add_btn") {
    const why = {
      "new-document": 'pressing it CREATES A DOCUMENT (the "+")',
      "airdrop-open": "it opens the share-access modal OVER the desk",
      "access-open": "it opens the scoped-access modal OVER the desk",
    }[rec.phx_click] || `its phx-click="${rec.phx_click}" is not one this census knows`;
    const addressing = `id=${rec.id || "(NONE — #id addressing cannot reach it)"} · data-test-id=${rec.test_id || "(none)"} · aria-label=${rec.aria_label || "(none)"} · title-only=${!rec.aria_label}`;
    return rec.id
      ? { status: FAIL, detail: `THE RECORDED REASON IS STALE: this .pane-add-btn now carries id="${rec.id}", so it IS addressable — re-decide whether the census should press it. (${addressing})` }
      : { status: PASS, detail: `NOT PRESSED BY DESIGN — ${why}, and either would litter the dataset or destroy the desk state the remaining rows are measured against. ${addressing}` };
  }
  // THE SECTION-HEADER TRIPWIRE — spd-w19-section-header-absent-on-desk.
  //
  // RULING (lead-studio-9, 2026-09-06): the deployed desk should NOT render
  // `.pane-section-header` today. Its only desk call site is the `:header ->`
  // arm at api/lib/barkpark_web/live/studio/studio_live/components.ex:1434 and   (lineref-ok:
  // quoted VERBATIM from the ruling; re-find it by the `:header ->` arm)
  // `git grep 'type: :header' origin/main -- api/lib` returns ZERO producers —
  // no pane builder emits a `:header` item, so the arm is unreachable and the
  // zero count on guerrilla is correct.
  //
  // So this is no longer an inventory row with a "dead by construction" excuse
  // to keep asserting. It is a PRESENCE tripwire: the census reaching this
  // function at all means a `.pane-section-header` was on the page, and on a
  // real desk that is a shape with no producer having appeared. It records FAIL
  // and asks for a re-decision rather than quietly inventorying it, because the
  // old PASS-by-construction verdict was true on a fixture that rendered the
  // shape itself and could never have fired against production.
  if (rec.kind === "section_header") {
    return {
      status: FAIL,
      detail:
        `a shape that had no producer on 2026-09-06 has appeared: re-decide (components.ex:1434). ` +
        `tag=${rec.tag} · phx-click=${rec.phx_click || "(none)"} · label="${rec.label}". ` +
        `RULING (lead-studio-9, 2026-09-06): the deployed desk should NOT render .pane-section-header today — the ` +
        `\`:header ->\` arm at components.ex:1434 is its only desk call site and no pane builder emits a \`:header\` item, ` +
        `so the arm is unreachable. Something now produces one: either a builder started emitting :header, or a new ` +
        `component grew the class. Decide which, and re-decide this row.`,
    };
  }
  if (rec.kind === "pane_doc_item_bodyless") {
    return { status: FAIL, detail: `a .pane-doc-item (wrapper ${rec.wrapper_id || "(no id)"}) with NO inner button.bp-doc-row-body — the row has no control at all, so no keyboard and no pointer can open this document.` };
  }
  return { status: FAIL, detail: `${rec.tag} matches .pane-item but is neither <a> nor <button> — it is not in the tab order, which is exactly what "the buttons look inert" felt like.` };
}

/** The session, WITHOUT LEG A. Same ticket mint, same desk navigation, same
 *  5xx guard and the same admin discriminator LEG A's AUTH beat asserts — and
 *  nothing else, so `--legs c` creates no document. It is a full gating beat
 *  on purpose: a census recorded against a login wall or an anonymous desk
 *  would call every row dead for a reason that is not about the rows. */
async function authOnly(page, ctx, ledger, run) {
  const ticket = await mintTicket(ctx);
  await page.goto(`${ctx.base}/login/ticket/${encodeURIComponent(ticket)}`);
  await page.goto(ctx.base + DESK_PATH);
  const docStatus = page.lastDocument?.status ?? null;
  if (docStatus != null && docStatus >= 500) {
    guard(
      `the host served HTTP ${docStatus} for ${DESK_PATH} (${page.lastDocument.url}). ` +
        `That is the deployment failing, not the Studio failing — no product claim can be made from it. Re-run.`,
    );
  }
  const landed = await poll(async () => {
    const n = await page.count(".pane-item, [phx-click='shares-open'], form[action*='login']");
    return n > 0 ? n : null;
  }, SETTLE_CAP, "desk or login painted");
  const shares = await page.count("[phx-click='shares-open']");
  const authUrl = await page.url();
  run.auth_probe = { url: authUrl, http_status: docStatus, leg_a_skipped: true };
  const checks = [
    check("the desk painted something", landed.value ? PASS : FAIL,
      landed.value ? `${landed.value} anchor node(s) in ${ms(landed.waited)}` : `nothing in ${ms(landed.waited)} at ${authUrl}`),
    check("identity discriminator [phx-click=shares-open] == 1 (admin)", shares === 1 ? PASS : FAIL,
      shares === 1
        ? "the shares_admin?-gated bar button is present — this session is the admin one"
        : `count=${shares} — 0 means the session degraded to anonymous. NOT a product defect.`),
  ];
  ledger.add("AUTH", rollup(checks), String(authUrl).replace(ctx.base, ""), checks);
}

async function legC(page, ctx, ledger, run) {
  const t0 = Date.now();
  const deadline = t0 + LEG_C_BUDGET;

  /** Re-arm the desk. A REAL navigation lands a fresh DEAD MOUNT: the rows paint
   *  before the socket joins and the first press after that is dropped on the
   *  floor with no error anywhere — which is why the row after an anchor needed
   *  two presses. Re-arming is a predicate, never a sleep. */
  const backToDesk = async (absoluteUrl) => {
    await page.goto(absoluteUrl || ctx.base + DESK_PATH);
    const rows = await poll(async () => (await page.count(".pane-item")) > 0 || null, SETTLE_CAP, "desk rows painted");
    const live = await poll(async () => {
      const s = await page.evaluate(
        `(function(){var m=document.querySelector("[data-phx-main]");` +
          `return m?(m.classList.contains("phx-connected")?"connected":null):null;})()`,
      );
      return s === "connected" ? s : null;
    }, SETTLE_CAP, "the socket rejoined");
    return { rows: !!rows.value, live: !!live.value };
  };

  const armed = await backToDesk();

  const roster = [];
  const byKey = new Map();
  // PER KIND, not per roster — see LEG_C_MAX_ROWS. `overflowByKind` is what makes
  // a dropped row legible: "0 inventoried" could previously mean either "this
  // desk has no inventory rows" or "the inventory kinds were crowded out", and
  // the printed output could not tell the two apart. Now every drop names its
  // kind, so the second reading is impossible to mistake for the first.
  const takenByKind = new Map();
  const overflowByKind = new Map();
  const bump = (m, k) => m.set(k, (m.get(k) || 0) + 1);
  const absorb = async () => {
    const c = await page.evaluate(`${CENSUS_FN}()`);
    if (!c || c.__throw || !Array.isArray(c.rows)) return null;
    for (const r of c.rows) {
      if (byKey.has(r.key)) continue;
      if ((takenByKind.get(r.kind) || 0) >= LEG_C_MAX_ROWS) { bump(overflowByKind, r.kind); continue; }
      bump(takenByKind, r.kind);
      // WHERE THIS ROW WAS SEEN. A press replaces the pane its siblings live in,
      // so by the time a sibling's turn comes its node is gone; navigating back
      // to the URL the row was ENUMERATED at re-renders the pane that held it.
      const rec = { ...r, enum_url: c.full_url || null, outcome: null, witness: null, detail: null, presses: 0, waited_ms: 0, recovered: false, wire: null };
      byKey.set(r.key, rec);
      roster.push(rec);
    }
    return c;
  };
  const first = await absorb();

  /** THE COVERAGE FIX for spd-w19-census-doc-row-coverage. Measured on served
   *  c81b8e66d: the desk grew 236 `.pane-doc-item` rows, ONE was measured, and
   *  the other 235 all reported "the row was gone from the desk when its turn
   *  came" — 5.4s of a 480s budget, `truncated:false`. It was never budget: a
   *  doc-row press replaces the pane its siblings live in, so the roster held
   *  235 stale node references. A census that can only ever see one row of the
   *  most numerous kind cannot be diffed against a later census for that kind.
   *
   *  The recovery is a RE-NAVIGATION, not a re-ordering: pressing doc rows in
   *  some pane-aware order still loses every sibling after the first press, and
   *  re-querying the roster only renames the problem (the node is gone, not
   *  stale-named). Going back to the row's own enumeration URL rebuilds the pane
   *  the row lived in, which is exactly what a person does. It is attempted ONCE
   *  per row and only when the row is actually missing, so a present row costs
   *  nothing, and a row that is STILL missing afterwards says so — recovery
   *  turning a genuinely-vanished row green is the one thing it must not do. */
  const recoverRow = async (rec) => {
    if (!rec.enum_url || Date.now() >= deadline) return null;
    const back = await backToDesk(rec.enum_url);
    rec.recovered = true;
    return `re-navigated to the URL this row was enumerated at (rows=${back.rows} socket=${back.live})`;
  };

  // The roster GROWS while it is walked, and that is the point: on the real desk
  // the document rows do not exist until a Structure row has been pressed, so a
  // roster fixed at enumeration time can only ever census Structure rows. Every
  // press re-enumerates and appends what the desk grew.
  let truncated = false;
  for (let i = 0; i < roster.length; i++) {
    const rec = roster[i];
    if (!PRESSABLE.has(rec.kind)) {
      const v = inventoryVerdict(rec);
      rec.outcome = v.status;
      rec.witness = "inventory (asserted, not pressed)";
      rec.detail = v.detail;
      continue;
    }
    if (Date.now() >= deadline) {
      truncated = true;
      rec.outcome = PENDING;
      rec.witness = "none";
      rec.detail = `the ${ms(LEG_C_BUDGET)} LEG_C_BUDGET ran out before this row's turn — ${UNMEASURED}`;
      continue;
    }
    let r = await pressCensusRow(page, rec, deadline);
    // THE RECOVERY, WIRED. `pressCensusRow` reports `missing` when the row is
    // not on the page at all when its turn comes — the 235-of-236 shape. Only
    // then, and only ONCE per row (`rec.recovered` is set by `recoverRow`), the
    // desk is re-navigated to the URL this row was enumerated at and the press
    // is retried. A row that was present costs nothing, and a row that is STILL
    // missing after the re-navigation says so in its own detail and stays
    // UNMEASURED — the recovery must never be able to turn a genuinely-vanished
    // row green, and it cannot: the retry goes through the same press and the
    // same identity witness as every other row.
    if (r.missing && !rec.recovered) {
      const how = await recoverRow(rec);
      if (how) {
        await absorb();
        const again = await pressCensusRow(page, rec, deadline);
        again.detail = again.missing
          ? `${again.detail} · RECOVERY WAS ATTEMPTED AND THE ROW IS STILL MISSING — ${how} — and the row was not there afterwards either`
          : `${again.detail} · recovered before the press: ${how}`;
        r = again;
      } else {
        r.detail += rec.enum_url
          ? ` · recovery NOT attempted: the ${ms(LEG_C_BUDGET)} LEG_C_BUDGET was already spent`
          : ` · recovery NOT attempted: this row carries no enumeration URL to navigate back to`;
      }
    }
    rec.outcome = r.status;
    rec.witness = r.witness;
    rec.detail = r.detail;
    rec.presses = r.presses;
    rec.waited_ms = r.waited;
    // The reading, in the RECORD and not only in the sentence: the self-test
    // asserts on it, and a fact only a human can read out of prose is a fact no
    // gate can hold.
    rec.wire = r.wire ? r.wire.verdict : null;

    // An anchor is a real page load: come back, and RE-ARM, before the next row
    // is judged. Same for any press that left a page with no desk rows on it.
    if (rec.kind === "plugin_link" || (await page.count(".pane-item")) === 0) {
      const back = await backToDesk();
      rec.detail += ` · returned to the desk afterwards (rows=${back.rows} socket=${back.live})`;
    }
    await absorb();
  }

  const wall = Date.now() - t0;
  const counted = (s) => roster.filter((r) => r.outcome === s).length;
  const pressed = roster.filter((r) => PRESSABLE.has(r.kind));
  run.census = {
    budget_ms: LEG_C_BUDGET,
    row_cap_ms: LEG_C_ROW_CAP,
    max_rows: LEG_C_MAX_ROWS,
    wall_ms: wall,
    truncated,
    // BOTH, and the by-kind map is the load-bearing one: a total alone is what
    // let "0 inventoried" read as "this desk has no inventory rows".
    overflowed_rows: [...overflowByKind.values()].reduce((a, b) => a + b, 0),
    overflowed_by_kind: Object.fromEntries(overflowByKind),
    censused_by_kind: Object.fromEntries(takenByKind),
    armed,
    desk_at_start: first ? { url: first.url, panes: first.panes, item_rows: first.item_rows, doc_rows: first.doc_rows } : null,
    rows: roster,
  };

  const checks = roster.map((rec) =>
    // ROW KIND · ELEMENT ID · VISIBLE LABEL, in ONE line with the outcome, so a
    // later census can be diffed against this one row by row.
    check(
      `${rec.kind.padEnd(12)} ${(rec.id || rec.wrapper_id || "(no id)").padEnd(24)} "${rec.label}"`,
      rec.outcome,
      `${rec.witness} — ${rec.detail}`,
    ),
  );
  if (!armed.rows || !armed.live) {
    checks.unshift(check("the desk was armed before any row was pressed", FAIL,
      `rows=${armed.rows} socket-joined=${armed.live} — with no joined socket every phx-click on this page is swallowed, so no row's verdict below means anything about the control`));
  }
  // A DROP NAMES ITS KIND — spd-w19-census-maxrows-crowds-inventory c1. The old
  // line said only how MANY rows were beyond the cap, so a reader of a
  // default-configured run saw "0 inventoried · 587 further row(s) beyond
  // LEG_C_MAX_ROWS=40" and could not tell "this desk has no inventory rows" from
  // "the inventory kinds were crowded out of the roster by 100 document rows".
  // Naming the dropped kinds makes the first reading impossible: `add_btn ×3`
  // in the drop line IS the statement that add_btn rows exist and were not
  // measured. The kinds that were censused whole are printed too, because
  // "add_btn is not in the drop list" only means something if the reader can
  // see the list of kinds that made it in.
  if (overflowByKind.size) {
    const dropped = [...overflowByKind.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    const total = dropped.reduce((n, [, c]) => n + c, 0);
    const whole = [...takenByKind.keys()].filter((k) => !overflowByKind.has(k)).sort();
    checks.push(check(
      `${total} further row(s) dropped for LEG_C_MAX_ROWS=${LEG_C_MAX_ROWS} PER KIND — ` +
        `KINDS DROPPED: ${dropped.map(([k, c]) => `${k} ×${c}`).join(" · ")}`,
      PENDING,
      `${UNMEASURED}. The cap is per KIND, so each kind above is represented in the census by its first ` +
        `${LEG_C_MAX_ROWS} member(s) and these are the ones beyond that — a dropped kind is never an ABSENT kind. ` +
        `KINDS CENSUSED WHOLE (nothing dropped): ${whole.length ? whole.join(", ") : "(none)"}. ` +
        `LEG_C_MAX_ROWS raises the per-kind ceiling.`,
    ));
  }
  if (roster.length === 0) {
    checks.push(check("the desk offered any row to census at all", FAIL, "zero rows enumerated — a census of nothing is not a census"));
  }

  ledger.add(
    "CENSUS",
    rollup(checks),
    `${pressed.length} pressed · ${roster.length - pressed.length} inventoried · ` +
      `${counted(PASS)} PASS ${counted(FAIL)} FAIL ${counted(PENDING)} UNMEASURED · ` +
      `${ms(wall)} of the ${ms(LEG_C_BUDGET)} budget${truncated ? " (TRUNCATED)" : ""}` +
      // THE SUMMARY LINE CARRIES THE DROP TOO. The per-row check above is the
      // full statement, but the summary is what a reader skims, and "0
      // inventoried" with nothing beside it is exactly the sentence that misled.
      (overflowByKind.size
        ? ` · DROPPED FOR THE PER-KIND CAP: ${[...overflowByKind.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([k, c]) => `${k} ×${c}`).join(" · ")}`
        : ""),
    checks,
    { gating: false },
  );
}

/** Press ONE row and decide by IDENTITY. The press is retried once, for the same
 *  reason `clickUntil` retries: a mount patch replaces the node and a click that
 *  lands in that window is discarded silently. The press count is reported, so
 *  "it answered the first press" and "it answered the second" stay different
 *  facts. This can rescue a raced control; it can never turn a dead one green. */
async function pressCensusRow(page, rec, deadline) {
  const t0 = Date.now();
  // THE PHASE TIMER. `LEG_C_TRACE=1` prints one line per row attributing the
  // row's wall clock to a NAMED phase — locate / witness-before / each click
  // (split into its box evaluate and its three Input.dispatchMouseEvent round
  // trips) / each witness-evaluate loop. It exists because the per-row cost was
  // 2.7x the nominal cap and the overshoot was ASSUMED to be in the click.
  const trace = { locate: 0, witnessBefore: 0, attempts: [] };
  const selfId = rec.kind === "collapsed_strip" ? rec.id : null;
  const locate = await page.evaluate(censusProbe(rec.key, selfId));
  trace.locate = Date.now() - t0;
  if (!locate || locate.__throw || !locate.found) {
    return {
      // `missing` is what the walk loop keys the ONE recovery attempt off. It is
      // a separate field from the status on purpose: a caller must not have to
      // parse this sentence to know the row was absent rather than silent.
      status: PENDING, witness: "none", presses: 0, waited: Date.now() - t0, missing: true,
      detail: `the row was gone from the desk when its turn came (an earlier press replaced the pane it lived in) — ${UNMEASURED}`,
    };
  }
  const witnessExpr = censusWitnessProbe(rec, locate.press_selector);
  const wbT0 = Date.now();
  const before = await page.evaluate(witnessExpr);
  trace.witnessBefore = Date.now() - wbT0;
  if (!before || before.__throw) {
    return { status: PENDING, witness: "none", presses: 0, waited: Date.now() - t0,
      detail: `the page would not answer a witness probe for this row — ${UNMEASURED}` };
  }
  let after = before, won = null, presses = 0, landed = false, ranOut = false;
  // THE WIRE MARK, taken before the first press on this row. Every FAIL below
  // used to end "it is DEAD as far as any observer can tell" — true of an
  // observer confined to the DOM, and this one is not: the tap reads
  // /live/websocket, so a dead row now says WHICH KIND of dead it is.
  const wireMark = page.wireMark();
  for (let attempt = 1; attempt <= LEG_C_PRESS_ATTEMPTS && !won; attempt++) {
    if (Date.now() >= deadline) { ranOut = true; break; }
    presses = attempt;
    let sel = pressSelectorFor(rec);
    if (!sel) {
      const loc = attempt === 1 ? locate : await page.evaluate(censusProbe(rec.key, selfId));
      sel = loc && !loc.__throw ? loc.press_selector : null;
    }
    if (!sel) break;
    const at = { n: attempt, click: null, evals: 0, evalMs: 0, pauseMs: 0, loopMs: 0 };
    trace.attempts.push(at);
    landed = (await page.click(sel)) || landed;
    at.click = page.clickTiming;
    // THE HARD BOUND, and it is why this does not call `poll()`: poll checks its
    // cap AFTER the predicate has run, so its overshoot is as long as one
    // predicate takes — measured 8.1s against a 3.0s cap on a loaded host, which
    // walked LEG C 5s PAST its 90s budget. Here the clock is checked BEFORE every
    // evaluate, so the budget holds to within one round trip.
    const loopT0 = Date.now();
    const until = Date.now() + Math.max(400, Math.min(LEG_C_ROW_CAP, deadline - Date.now()));
    for (;;) {
      const evT0 = Date.now();
      const now = await page.evaluate(witnessExpr);
      at.evals += 1; at.evalMs += Date.now() - evT0;
      if (now && !now.__throw) {
        after = now;
        const w = identityWitness(rec, before, now);
        if (w) { won = w; break; }
      }
      if (Date.now() >= deadline) { ranOut = true; break; }
      if (Date.now() >= until) break;
      const pT0 = Date.now();
      await pause(POLL_TICK); // the poll tick — not a wait for anything in particular
      at.pauseMs += Date.now() - pT0;
    }
    at.loopMs = Date.now() - loopT0;
  }
  if (LEG_C_TRACE) {
    const parts = trace.attempts.map((a) => {
      const c = a.click || {};
      return `attempt${a.n}[click ${c.total ?? "?"}ms (box ${c.box ?? "?"} moved ${c.moved ?? "?"} pressed ${c.pressed ?? "?"} released ${c.released ?? "?"}) ` +
        `+ witness-loop ${a.loopMs}ms (${a.evals} evaluate(s) = ${a.evalMs}ms, ${a.pauseMs}ms of ${POLL_TICK}ms ticks)]`;
    });
    process.stderr.write(
      `LEG_C_TRACE ${rec.key} :: total ${Date.now() - t0}ms = locate ${trace.locate}ms + witness-before ${trace.witnessBefore}ms + ` +
      (parts.length ? parts.join(" + ") : "(no press)") + `\n`,
    );
  }
  const waited = Date.now() - t0;
  // A PLAIN ANCHOR IS NOT A SOCKET PRESS. `plugin_link` rows navigate by href
  // and carry no phx-click at all (components.ex: "A real anchor ON PURPOSE"),
  // so ZERO click frames is the CORRECT behaviour there, not a discard. Reading
  // the tap for them would print "NOT SENT" over a row that is working exactly
  // as designed — an instrument answering a question the row never asked.
  const wire =
    rec.kind === "plugin_link"
      ? { verdict: "N/A", frames: null, detail: "N/A — a plain anchor navigates by href and never puts a click frame on the socket" }
      : page.wireVerdict(wireMark);
  // THE COUNTS ARE IN THE RECORD AND THEY DECIDE NOTHING. They are the drift a
  // snapshot diff used to call an answer, which is how the dead #item-sheet was
  // credited with its neighbour's URL 900 ms later.
  const drift =
    `counts(recorded, non-deciding): panes ${before.panes}→${after.panes} · ` +
    `.pane-item ${before.item_rows}→${after.item_rows} · .pane-doc-item ${before.doc_rows}→${after.doc_rows} · ` +
    `url ${before.url} → ${after.url}`;
  if (won) {
    return { status: PASS, witness: `IDENTITY: ${won}`, presses, waited, wire,
      detail: `answered in ${ms(waited)} after ${presses} press(es) · wire: ${wire.verdict} · ${drift}` };
  }
  // THE BUDGET IS NOT A VERDICT. A row whose measurement was cut off mid-flight
  // is UNMEASURED, never dead: converting an exhausted runner budget into a dead
  // row fabricates a defect, which is the failure mode this whole epic exists to
  // stop.
  if (ranOut) {
    return { status: PENDING, witness: "none", presses, waited, wire,
      detail: `the ${ms(LEG_C_BUDGET)} LEG_C_BUDGET ran out WHILE this row was being measured (${presses} press(es), ${ms(waited)}) — ${UNMEASURED} · ${drift}` };
  }
  if (!landed) {
    return { status: FAIL, witness: "none", presses, waited, wire,
      detail: `NO PRESS EVER LANDED on it in ${ms(waited)} (${presses} attempt(s)) — the element had no layout box to click, so it is on the page and cannot be pointed at · ${drift}` };
  }
  const unavailable =
    rec.kind === "plugin_link"
      ? `it has no phx-value-id and no aria-current — an anchor's ONLY witness is its own href (${rec.href || "(no href!)"})`
      : rec.kind === "collapsed_strip"
        ? `witness = #${rec.id || "(NO ID — nothing can name this strip; only the strip COUNT could move, and a count cannot name a row)"} losing .pane-column--collapsed`
        : `aria-current ${isCurrent(before.aria_current) ? `was ALREADY "${before.aria_current}" before the press, so that witness was unavailable and only the URL could name this row` : `stayed ${after.aria_current === null ? "absent" : `"${after.aria_current}"`}`}, and the URL never carried ${rec.phx_value_id ? `"${rec.phx_value_id}"` : "(this row has NO phx-value-id)"} as a path segment`;
  return { status: FAIL, witness: "none", presses, waited, wire,
    detail: `NOTHING NAMED THIS ROW after ${presses} press(es) in ${ms(waited)}: ${unavailable} · ${drift}` +
    // WHICH KIND OF DEAD. Without this clause the sentence below says only that
    // nothing happened, which is the one thing a reader already knew — and it
    // used to end "DEAD as far as any observer can tell", a claim that was only
    // ever true of a DOM-bound observer.
    ` · WIRE: ${wire.detail}` +
    (wire.verdict === "NOT SENT"
      ? ` — so this row is not "dead": its press was DISCARDED IN THE BROWSER and the server never heard it. Fix the affordance, not the handler.`
      : wire.verdict === "SENT"
        ? ` — so the press DID reach the server and nothing observable came back: this is a server-side non-answer, not a client discard.`
        : ` — and the wire could not be read, so this run cannot say which.`) +
      ` · READ IT AS "no witness within ${ms(LEG_C_ROW_CAP)}": measured answer latency on this seam runs 1.6s to never-within-15s, so against a LIVE host this row is either dead or slower than the cap, and LEG_C_ROW_CAP_MS raises the cap` };
}

// ─────────────────────────────────────────────────────────────────────────────
//  LEG D — THE COLD-LOAD PRESS FLOOR (report-only, and it REFUSES under load)
// ─────────────────────────────────────────────────────────────────────────────
//  spd-b19-lane4-quiet-host-floor. Three waves filed this leg and none of them
//  ran it, for one reason: THE HOST WAS NEVER QUIET. Wave 19's verify round
//  never saw load fall below 8.05 on 10 cores and watched it peak at 40.81, and
//  it REFUSED to publish any number it took there. This leg makes that refusal
//  MECHANICAL instead of editorial — the instrument itself declines to name a
//  latency it cannot stand behind, and prints the load it declined at.
//
//  WHAT THE LEG MEASURES
//    1. THE FLOOR. Ten CONSECUTIVE COLD LOADS, one press each on a Structure
//       row, every latency quoted. The press is EARLY BY CONSTRUCTION: the
//       moment the row is dispatchable the leg presses, with no socket gate and
//       no settle. Prior runs measured 9/10, 9/10, 9/10 and 5/6 and failed
//       DETERMINISTICALLY ON THE EARLIEST PRESS EVERY TIME (11–48ms after
//       load) — so a harness that lets iteration 1 be the only fast one is
//       measuring its own warm-up, not the seam. Here every iteration is fast.
//    2. THE UNATTRIBUTED GAP. `readyState === "complete"` → the row being
//       dispatchable was measured at 5056–5067ms, 28 times, with an 11ms spread
//       that load jitter does not explain, while in-page truth said the row was
//       present the whole time. If it survives on a quiet host it is a THIRD
//       failure mode — a main-thread freeze in which clicks are QUEUED rather
//       than dropped — and it is absent from wave 18's ledger of five. The leg
//       re-takes it and quotes the spread either way.
//    3. THE REF-SRC NO-OP (c3). See `refSrcProbe`.
//
//  THE FRAME-COUNT TRAP, STATED IN THE CODE BECAUSE THE ROW REQUIRES IT
//  (spd-b19-lane4-quiet-host-floor c4). THE ORACLE FOR "WAS THIS PRESS SENT"
//  MATCHES `"type":"click"` AND NEVER COUNTS FRAMES. `phx_join`, the heartbeat
//  and WidthBucket's own hook push all ride the same `/live/websocket`, so a
//  DISCARDED press reads as TWO FRAMES while sending no click — a frame count
//  is confounded by construction and would report a dropped press as sent. The
//  match lives in `Page.open`'s `Network.webSocketFrameSent` subscription
//  (`data.indexOf('"type":"click"') === -1` → not a press) and the verdict lives
//  in `wireVerdict`, whose `frames` field counts ONLY frames that already
//  matched. Nothing in this leg reads a raw frame total, and nothing may.
//
//  WHAT IS ALREADY PURCHASED AND IS NOT RE-DERIVED HERE. A discarded press puts
//  ZERO `"type":"click"` frames on the socket — 4/4, against a same-run positive
//  control of 32/32 answered presses that DID emit one; the source-level reason
//  is `pushWithReply`'s reject before any channel push; and the drop is SILENT.
//  `phx-connected` is REFUTED as the discriminator IN BOTH DIRECTIONS (31/31
//  presses landed while `connected === false` and 29 of them were honoured; the
//  one probe that carried `phx-loading` is the one that was dropped) because the
//  class is applied post-mount-diff at view.js:618. So this leg does not gate on
//  the class and does not re-litigate the frame question — it presses early,
//  reads the typed oracle, and reports.
//
//  REPORT-ONLY. Like LEG B and LEG C this leg never moves the exit code: it is a
//  measurement of an open defect on a shared host, and converting a slow host
//  into a product FAIL is the exact fabrication this epic exists to stop.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHAT THIS LEG MEASURED ON ITS FIRST TWO RUNS — guerrilla, served ca4534461,
//  2026-09-22T13:26Z, host load 4.62→4.84 (cold arm) and 4.87→4.65 (warm arm)
//  on 10 cores. THE LATENCIES BELOW ARE NOT PUBLISHED AS THE FLOOR — the host
//  was loaded and the leg refused, exactly as designed. They are quoted here
//  ONLY to carry the two verdicts that survive a loaded host BY DIRECTION.
// ─────────────────────────────────────────────────────────────────────────────
//  THE ~5.06s GAP IS REFUTED, AND NOT AS A LOAD ARTEFACT. Measured
//  readyState=complete → a dispatchable press: 0–1ms, 20 iterations out of 20,
//  across both arms, at load 4.6–4.9. The prior observation was 5056–5067ms,
//  28 times, with an ELEVEN MILLISECOND SPREAD.
//
//  The refutation is load-proof because load is MONOTONE UPWARD on a wait: a
//  gap that reads 1ms at load 4.9 cannot read 5056ms at load 2.0. A quiet host
//  could only make it smaller, and it is already 1ms. So this verdict does not
//  need the quiet window the FLOOR number needs.
//
//  AND THE THIRD READING IS THE RIGHT ONE. The row framed this as a binary — a
//  real third failure mode, or a load artefact — and it is NEITHER. An 11ms
//  spread on a 5056ms value is the signature of a CONSTANT, not of a
//  measurement: host load produces spreads in the hundreds of milliseconds (see
//  the answer latencies below, 455–761ms on the same runs), and 5056–5067ms is
//  ~5000ms of something fixed plus ~60ms of work. The gap was an artefact of
//  the PRIOR INSTRUMENT — a ~5s constant in the harness that observed it — and
//  in-page truth already said so at the time: the row was present the whole
//  time (row:true at 851ms) and `[data-phx-main].className` was empty. There is
//  no third failure mode here, and nothing queues.
//
//  THE EARLY-PRESS DROP DID NOT REPRODUCE ON ca4534461 AT ALL. 20/20 presses
//  ANSWERED, every one of them wire=SENT — so on the currently served commit
//  the socket has joined before the row is hit-testable, and `pushWithReply`
//  never gets the chance to reject. Answer latency 455–761ms; press placed
//  229–537ms into a cold load and 139–188ms into a warm one. This is 20/20 at a
//  load of 4.6–4.9, and the same monotone argument applies to the RELIABILITY
//  claim (a quiet host cannot answer fewer presses than a loaded one) — but NOT
//  to the latency numbers, which stay unpublished.
//
//  THE 11–48ms FAILING PRESS IS UNREACHABLE FROM HERE. The earliest press this
//  leg can physically place is ~139ms (warm) / ~229ms (cold), because before
//  that the row has no hit box. A press recorded at 11ms was therefore pressing
//  something not yet laid out — which is a fact about THAT harness, not about
//  the seam. See FLOOR_COLD.
//
//  THE REF-SRC NO-OP REPRODUCES, NATURALLY, ON THE DEPLOYED STUDIO. The probe
//  caught `data-phx-ref-src` still on the element from the control press (arm
//  source NATURAL, both runs), and the second press read NOT SENT against a
//  same-run control that read SENT. Signature: wire NOT SENT · 0 exceptions ·
//  the DOM deltas are the CONTROL press's answer landing late and are printed
//  as context, never as the verdict.
// ─────────────────────────────────────────────────────────────────────────────

// THE QUIET FLOOR. "under ~2.0 on 10 cores" is the row's own wording, so the
// threshold is expressed as a FRACTION OF CORES and rendered back into the 10-core
// number: 2.0/10 cores = 0.20 runnable per core. A 10-core desk therefore refuses
// above 2.0 exactly as written, and the same constant means the same thing on a
// 4-core CI runner instead of silently becoming 5x stricter there.
const QUIET_LOAD_PER_CORE = Number(process.env.QUIET_LOAD_PER_CORE || 0.20);
const FLOOR_ITERATIONS = Number(process.env.FLOOR_ITERATIONS || 10);
const FLOOR_PRESS_CAP = Number(process.env.FLOOR_PRESS_CAP_MS || 15000); // a press's effect
const FLOOR_READY_CAP = Number(process.env.FLOOR_READY_CAP_MS || 30000); // readyState + row

// COLD AND EARLY PULL IN OPPOSITE DIRECTIONS, and that is a finding rather than
// a knob. MEASURED against guerrilla (served ca4534461, 2026-09-22): with the
// cache DISABLED the row is not hit-testable until 229–537ms, so the earliest
// press this leg can physically place is ~230ms into the load. The presses that
// failed deterministically in the prior runs landed at 11–48ms — which is only
// REACHABLE ON A WARM LOAD, where the desk's JS and CSS come out of the memory
// cache and the row paints before the socket has any chance to join. So "press
// early" and "load cold" are not the same axis: FLOOR_COLD=1 measures the
// cold-load floor and FLOOR_COLD=0 measures the 11–48ms window the drops were
// observed in. Both arms are needed and neither subsumes the other.
const FLOOR_COLD = process.env.FLOOR_COLD !== "0";

/** The host reading, taken from the clock rather than remembered. `quiet` is the
 *  ONE field callers may branch on; `load1` and `cores` are printed so a refusal
 *  names the number it refused at, which is what makes the refusal a result. */
function hostLoad() {
  const cores = os.cpus().length || 1;
  const [load1, load5, load15] = os.loadavg();
  const ceiling = QUIET_LOAD_PER_CORE * cores;
  return {
    at: new Date().toISOString(),
    cores, load1, load5, load15,
    ceiling: Number(ceiling.toFixed(2)),
    per_core: Number((load1 / cores).toFixed(3)),
    quiet: load1 < ceiling,
  };
}

const loadLine = (l) =>
  `load ${l.load1.toFixed(2)} / ${l.load5.toFixed(2)} / ${l.load15.toFixed(2)} on ${l.cores} cores ` +
  `(${l.per_core.toFixed(3)}/core; the quiet ceiling is ${l.ceiling.toFixed(2)}) — ${l.quiet ? "QUIET" : "LOADED"}`;

const FLOOR_ROW = "#item-paper";

/** Was the press ANSWERED, by this row's own identity? `aria-current` on THIS
 *  element, or the URL newly carrying THIS row's id. Never a count — LEG C's
 *  `#item-counts-decoy` exists because a pane count credited a dead row with its
 *  neighbour's answer 900ms later. */
const FLOOR_ANSWERED = `(function(){
  var el = document.querySelector(${JSON.stringify(FLOOR_ROW)});
  var owned = !!(el && el.hasAttribute("aria-current"));
  var urled = location.pathname.indexOf("/studio/paper") !== -1;
  return owned || urled;
})()`;

/** Is the row DISPATCHABLE — present, laid out, and hit-testable at its centre?
 *  Presence alone is not dispatchability: a row with a zero box cannot receive a
 *  synthetic mouse event, and the 5.06s gap is precisely a claim about the
 *  distance between "present" (in-page truth said `row:true` at 851ms) and
 *  "pressable". So this predicate is the one the gap is measured against, and it
 *  reports WHICH of the two conditions is missing rather than a bare false. */
const FLOOR_DISPATCHABLE = `(function(){
  var el = document.querySelector(${JSON.stringify(FLOOR_ROW)});
  if (!el) return { present:false, boxed:false, hit:false };
  var r = el.getBoundingClientRect();
  var boxed = r.width > 0 && r.height > 0;
  if (!boxed) return { present:true, boxed:false, hit:false };
  var t = document.elementFromPoint(r.left + r.width/2, r.top + r.height/2);
  return { present:true, boxed:true, hit: !!(t && (t === el || el.contains(t))) };
})()`;

/** ONE COLD LOAD, pressed early on purpose. Returns a record that is decidable
 *  either way — a press that was never possible says so rather than reading as a
 *  zero. */
async function floorIteration(page, ctx, i, pressCap) {
  const rec = { i, load_before: hostLoad(), load_after: null, discarded: null };
  // COLD MEANS COLD. Without this the second iteration serves the desk's JS and
  // CSS out of the memory cache and measures a warm parse, which is exactly the
  // "iteration 1 was the fast one" artefact this leg was written to remove.
  rec.cold = FLOOR_COLD;
  try { await page.cdp.send("Network.setCacheDisabled", { cacheDisabled: FLOOR_COLD }, page.sid); } catch { /* the leg still runs warm-ish */ }

  const t0 = Date.now();
  await page.goto(ctx.base + DESK_PATH);
  rec.nav_ms = Date.now() - t0;
  rec.doc_status = page.lastDocument?.status ?? null;

  const ready = await poll(async () => (await page.evaluate('document.readyState')) === "complete" || null, FLOOR_READY_CAP, "readyState complete");
  rec.ready_ms = ready.value ? Date.now() - t0 : null;
  const tReady = Date.now();

  const disp = await poll(async () => {
    const d = await page.evaluate(FLOOR_DISPATCHABLE);
    rec.last_dispatch_probe = d && !d.__throw ? d : null;
    return d && !d.__throw && d.present && d.boxed && d.hit ? d : null;
  }, FLOOR_READY_CAP, "the Structure row became dispatchable");
  rec.dispatchable_ms = disp.value ? Date.now() - t0 : null;
  // THE NUMBER THE ROW ASKED FOR: readyState=complete → a dispatchable press.
  rec.gap_ms = ready.value && disp.value ? Date.now() - tReady : null;

  if (!disp.value) {
    rec.outcome = "NO ROW";
    rec.detail = `the Structure row never became dispatchable within ${ms(FLOOR_READY_CAP)} (last probe ${JSON.stringify(rec.last_dispatch_probe)})`;
    rec.load_after = hostLoad();
    return rec;
  }

  // PRESS NOW. No socket gate, no settle, no "let the mount land" — the early
  // press IS the measurement.
  const mark = page.wireMark();
  const exMark = page.exceptionMark();
  rec.press_at_ms = Date.now() - t0;
  const hit = await page.click(FLOOR_ROW);
  rec.click_timing = page.clickTiming || null;
  const tPress = Date.now();
  if (!hit) {
    rec.outcome = "NOT PRESSED";
    rec.detail = "the row had no hit box at press time";
    rec.load_after = hostLoad();
    return rec;
  }

  const answered = await poll(async () => (await page.evaluate(FLOOR_ANSWERED)) === true || null, pressCap, "the press was answered");
  rec.latency_ms = answered.value ? Date.now() - tPress : null;
  rec.wire = page.wireVerdict(mark);
  rec.exceptions = page.exceptionsSince(exMark);
  rec.outcome = answered.value ? "ANSWERED" : "UNANSWERED";
  rec.detail = answered.value
    ? `answered ${rec.latency_ms}ms after a press placed ${rec.press_at_ms}ms into the load · ${rec.wire.verdict}`
    : `NO answer within ${ms(pressCap)} of a press placed ${rec.press_at_ms}ms into the load · ${rec.wire.detail}`;
  rec.load_after = hostLoad();
  return rec;
}

/** The spread, over the iterations that are ALLOWED to contribute. An iteration
 *  whose load crossed the ceiling while it ran is DISCARDED BY NAME rather than
 *  averaged through — averaging a loaded sample into a quiet set is how a
 *  refusal becomes a number. */
function spread(values) {
  const xs = values.filter((v) => typeof v === "number").sort((a, b) => a - b);
  if (!xs.length) return null;
  const mid = Math.floor(xs.length / 2);
  return {
    n: xs.length,
    min: xs[0],
    max: xs[xs.length - 1],
    median: xs.length % 2 ? xs[mid] : Math.round((xs[mid - 1] + xs[mid]) / 2),
    range: xs[xs.length - 1] - xs[0],
    all: xs,
  };
}

/** THE PHX_REF_SRC SECOND-PRESS NO-OP (c3), as its own probe, with a CONTROL.
 *
 *  LiveView stamps `data-phx-ref-src` on an element while its event is in
 *  flight, `syncPendingAttrs` CARRIES IT ACROSS a re-render, and `bindClick`
 *  ends `!r.hasAttribute(N) && this.debounce(…)` with N = "data-phx-ref-src".
 *  So a second press on a row whose first press is still outstanding is
 *  discarded IN THE CLIENT: no frame, no exception, no flash, no server trace.
 *  The digest says this shape ALONE reproduces the owner's report, and it had
 *  never been exercised as its own probe.
 *
 *  TWO ARMS, AND THE CONTROL IS THE POINT. An instrument that only ever sees the
 *  stamped press cannot tell "the press was suppressed" from "the tap is dead":
 *    ARM CONTROL  press the row with NO ref-src → the oracle must say SENT.
 *    ARM STAMPED  press the SAME row with ref-src present → NOT SENT.
 *  A run in which both arms agree has measured nothing and says so.
 *
 *  NATURAL vs SYNTHETIC, LABELLED. The probe first tries to catch the attribute
 *  in its natural in-flight window. That window can close faster than a CDP
 *  round trip, so when it does the probe stamps the attribute itself — which is
 *  what LiveView writes, byte for byte — and RECORDS WHICH ARM IT GOT. A
 *  synthetic stamp proves the client's early return; it does not prove the
 *  window is reachable by hand, and the record never claims it does. */
async function refSrcProbe(page, ctx) {
  const out = { row: FLOOR_ROW, control: null, stamped: null, natural_window: null, source: null };

  await page.goto(ctx.base + DESK_PATH);
  await poll(async () => {
    const d = await page.evaluate(FLOOR_DISPATCHABLE);
    return d && !d.__throw && d.hit ? d : null;
  }, FLOOR_READY_CAP, "the row became dispatchable");
  // Let the socket join before the CONTROL arm: the control's job is to prove
  // the tap CAN say SENT, and a control that races the join would refute itself
  // for the OTHER reason (`pushWithReply`'s no-connection reject) and read as a
  // ref-src suppression. This is the one press in this file that is deliberately
  // NOT early.
  await poll(async () => {
    const s = await page.evaluate(`(function(){var m=document.querySelector("[data-phx-main]");return m&&m.classList.contains("phx-connected")?"y":null;})()`);
    return s || null;
  }, SETTLE_CAP, "the socket joined");

  // ── ARM CONTROL ────────────────────────────────────────────────────────────
  const cMark = page.wireMark();
  await page.click(FLOOR_ROW);
  // The natural window, read IMMEDIATELY after the press and before any poll:
  // whether LiveView's own stamp is observable from here at all is itself a
  // finding, and a probe that looked for it later would answer "no" for the
  // wrong reason.
  out.natural_window = await page.evaluate(
    `(function(){var el=document.querySelector(${JSON.stringify(FLOOR_ROW)});` +
      `return el?{present:true,ref_src:el.getAttribute("data-phx-ref-src"),ref:el.getAttribute("data-phx-ref"),cls:el.className}:{present:false};})()`,
  );
  await pause(POLL_TICK);
  out.control = page.wireVerdict(cMark);

  // ── ARM STAMPED ────────────────────────────────────────────────────────────
  const natural = !!(out.natural_window && out.natural_window.ref_src);
  if (!natural) {
    const wrote = await page.evaluate(
      `(function(){var el=document.querySelector(${JSON.stringify(FLOOR_ROW)});if(!el)return false;` +
        `el.setAttribute("data-phx-ref-src", el.closest("[data-phx-main]")?el.closest("[data-phx-main]").id:"phx-synthetic");return true;})()`,
    );
    out.source = wrote === true ? "SYNTHETIC — the natural in-flight window had already closed when the probe looked, so the probe wrote the attribute LiveView writes and pressed again" : "UNAVAILABLE";
  } else {
    out.source = "NATURAL — the attribute was still on the element from the control press";
  }
  const sMark = page.wireMark();
  const sExMark = page.exceptionMark();
  const before = await page.evaluate(
    `(function(){var el=document.querySelector(${JSON.stringify(FLOOR_ROW)});` +
      `return {aria:el?el.getAttribute("aria-current"):null,href:location.href,cls:el?el.className:null};})()`,
  );
  await page.click(FLOOR_ROW);
  await pause(POLL_TICK * 3);
  out.stamped = page.wireVerdict(sMark);
  const after = await page.evaluate(
    `(function(){var el=document.querySelector(${JSON.stringify(FLOOR_ROW)});` +
      `return {aria:el?el.getAttribute("aria-current"):null,href:location.href,cls:el?el.className:null};})()`,
  );
  out.exceptions = page.exceptionsSince(sExMark);
  out.dom_before = before;
  out.dom_after = after;
  // THE OBSERVABLE SIGNATURE, spelled out rather than left to a reader to infer
  // from two verdict strings.
  //
  // AND THE DOM FIELDS ARE THE WEAK ONES, WHICH THIS RUN DEMONSTRATED. On the
  // /good/ fixture the second-press window reads "aria-current changed · URL
  // changed" — and neither change is the second press's. They are the CONTROL
  // press's answer landing late (the fixture patches the URL at 400ms and grows
  // the pane at 900ms, modelling the 2.4s measured on guerrilla). A probe that
  // read the DOM delta as the suppressed press's effect would report the exact
  // opposite of the truth. THE LOAD-BEARING FIELD IS THE WIRE — did a
  // `"type":"click"` frame leave the socket — and the DOM fields are printed as
  // CONTEXT, never as the verdict. That is the same rule LEG C's
  // `#item-counts-decoy` enforces one level up: an effect that does not NAME the
  // press cannot be credited to it.
  out.signature =
    `second press on a row carrying data-phx-ref-src: wire=${out.stamped?.verdict} · ` +
    `exceptions=${(out.exceptions || []).length} · ` +
    `className ${before?.cls === after?.cls ? "UNCHANGED" : "changed"} · ` +
    `aria-current ${before?.aria === after?.aria ? "UNCHANGED" : "changed"} · ` +
    `URL ${before?.href === after?.href ? "UNCHANGED" : "changed"} · ` +
    `control arm (same row, no ref-src) = ${out.control?.verdict} ` +
    `[the three DOM fields are CONTEXT, not the verdict: the control press's answer lands inside ` +
    `this window, so a "changed" there is usually the FIRST press arriving late]`;
  return out;
}

async function legD(page, ctx, ledger, run, opts) {
  // The fixture narrows both of these. Ten iterations at a 15s answer cap is
  // 150s of self-test when every early press is (correctly) dropped, and a
  // self-test nobody will sit through is a self-test that stops being run.
  const iters = Number(opts?.floorIterations ?? FLOOR_ITERATIONS);
  const pressCap = Number(opts?.floorPressCap ?? FLOOR_PRESS_CAP);
  const before = hostLoad();
  process.stdout.write(`>> LEG D  uptime BEFORE: ${loadLine(before)}\n`);

  const iterations = [];
  for (let i = 1; i <= iters; i++) {
    const rec = await floorIteration(page, ctx, i, pressCap);
    // THE DISCARD RULE, applied per iteration and NAMED. An iteration that began
    // or ended above the ceiling contributes to NOTHING — not the spread, not the
    // median, not a sentence. It is kept in the record so the discard is visible.
    if (!rec.load_before.quiet || !(rec.load_after && rec.load_after.quiet)) {
      rec.discarded = `DISCARDED — host load crossed the quiet ceiling during this iteration ` +
        `(before ${rec.load_before.load1.toFixed(2)}, after ${rec.load_after ? rec.load_after.load1.toFixed(2) : "n/a"}, ceiling ${before.ceiling.toFixed(2)})`;
    }
    iterations.push(rec);
    process.stdout.write(
      `   D${String(i).padStart(2, "0")} ${(rec.outcome || "?").padEnd(10)} ` +
      `nav ${String(rec.nav_ms ?? "-").padStart(6)}ms · ready ${String(rec.ready_ms ?? "-").padStart(6)}ms · ` +
      `gap ${String(rec.gap_ms ?? "-").padStart(6)}ms · press@${String(rec.press_at_ms ?? "-").padStart(6)}ms · ` +
      `answer ${String(rec.latency_ms ?? "-").padStart(6)}ms · wire ${(rec.wire?.verdict || "-")}` +
      `${rec.discarded ? "  [DISCARDED: load]" : ""}\n`,
    );
  }

  const refsrc = await refSrcProbe(page, ctx);
  const after = hostLoad();
  process.stdout.write(`>> LEG D  uptime AFTER:  ${loadLine(after)}\n`);

  // EVERY ITERATION MUST BE DECIDABLE. This — not the answer rate — is what the
  // FLOOR beat's status is about, and the distinction is load-bearing: the
  // answer rate is a PRODUCT number this leg refuses to publish on a loaded
  // host, so hanging the beat's verdict on it would make the beat mean one
  // thing when the host is quiet and another when it is not. "NO ROW" and "NOT
  // PRESSED" are the instrument failing to measure; UNANSWERED is a measurement.
  const undecidable = iterations.filter((r) => r.outcome !== "ANSWERED" && r.outcome !== "UNANSWERED");
  const kept = iterations.filter((r) => !r.discarded);
  const answered = kept.filter((r) => r.outcome === "ANSWERED");
  const floor = {
    cold: FLOOR_COLD,
    quiet_ceiling: before.ceiling,
    load_before: before, load_after: after,
    quiet_throughout: before.quiet && after.quiet && iterations.every((r) => !r.discarded),
    iterations,
    kept: kept.length, discarded: iterations.length - kept.length,
    answered: answered.length,
    latency_spread: spread(answered.map((r) => r.latency_ms)),
    gap_spread: spread(kept.map((r) => r.gap_ms)),
    press_offset_spread: spread(kept.map((r) => r.press_at_ms)),
    refsrc,
    frame_oracle:
      "MATCHES \"type\":\"click\" AND NEVER COUNTS FRAMES — phx_join, the heartbeat and the " +
      "WidthBucket hook push share /live/websocket, so a frame TOTAL reads two frames for a " +
      "press that sent no click. See Page.open's webSocketFrameSent subscription.",
  };
  run.floor = floor;

  // ── THE VERDICT, AND THE REFUSAL IS ONE ────────────────────────────────────
  // A number taken above the ceiling is the load, not the code. Three waves have
  // now declined to publish one; this is the first time the instrument declines
  // on its own, with the observed load attached. A refusal is a COMPLETE result
  // for this leg — it is not a PENDING and it is not a FAIL, because nothing
  // about the product was learned or impugned.
  if (!floor.quiet_throughout) {
    floor.verdict = "REFUSED";
    ledger.add(
      "FLOOR", undecidable.length === 0 ? PASS : FAIL,
      `REFUSED, and the refusal is the result. The quiet floor is ${before.ceiling.toFixed(2)} on ` +
        `${before.cores} cores (${QUIET_LOAD_PER_CORE}/core); this host read ${before.load1.toFixed(2)} before and ` +
        `${after.load1.toFixed(2)} after, with ${iterations.length - kept.length} of ${iterations.length} iterations ` +
        `crossing the ceiling WHILE THEY RAN. Every latency below was still recorded and is printed, and NONE of it ` +
        `is published as a number: per measure-on-a-quiet-host a press latency taken here is the host's, not the ` +
        `code's. Re-run with the host idle. (The MECHANISM beats — the wire oracle and the ref-src probe — are ` +
        `load-independent and DO stand: a frame either left the socket or it did not.)`,
      [
        check("uptime BEFORE", PASS, loadLine(before)),
        check("uptime AFTER", PASS, loadLine(after)),
        check("iterations run", PASS, `${iterations.length} · ${kept.length} kept · ${iterations.length - kept.length} DISCARDED by the load rule`),
        check("every iteration decidable", undecidable.length === 0 ? PASS : FAIL, `${iterations.length - undecidable.length}/${iterations.length} produced ANSWERED or UNANSWERED`),
        check("latency PUBLISHED", PENDING, "withheld — the host was loaded"),
      ],
      { gating: false },
    );
  } else {
    floor.verdict = "MEASURED";
    const ls = floor.latency_spread, gs = floor.gap_spread;
    ledger.add(
      "FLOOR", undecidable.length === 0 && kept.length > 0 ? PASS : FAIL,
      `MEASURED on a quiet host: ${answered.length}/${kept.length} early presses answered · ` +
        `answer latency ${ls ? `${ls.min}–${ls.max}ms (median ${ls.median})` : "n/a"} · ` +
        `readyState→dispatchable gap ${gs ? `${gs.min}–${gs.max}ms (median ${gs.median}, range ${gs.range})` : "n/a"} · ` +
        `presses placed ${floor.press_offset_spread ? `${floor.press_offset_spread.min}–${floor.press_offset_spread.max}ms` : "n/a"} into the load`,
      [
        check("uptime BEFORE", PASS, loadLine(before)),
        check("uptime AFTER", PASS, loadLine(after)),
        check("every iteration decidable", undecidable.length === 0 ? PASS : FAIL, `${iterations.length - undecidable.length}/${iterations.length} produced ANSWERED or UNANSWERED`),
        check("early presses answered", PASS, `${answered.length}/${kept.length} — REPORTED, NOT GATED: an early press being dropped is the DEFECT under measurement, so reddening on it would make this leg red on exactly the finding it exists to record`),
        check("the ~5.06s gap", PASS, gs ? `re-taken: ${gs.min}–${gs.max}ms over ${gs.n} quiet iterations (range ${gs.range}ms)` : "no quiet iteration produced one"),
      ],
      { gating: false },
    );
  }

  // The ref-src probe stands on its own and is NOT load-gated: "did a frame
  // leave the socket" is a binary the host's load cannot move.
  const armsDiffer = refsrc.control?.verdict === "SENT" && refsrc.stamped?.verdict === "NOT SENT";
  const readable = refsrc.control?.verdict !== "CANNOT READ" && refsrc.stamped?.verdict !== "CANNOT READ";
  ledger.add(
    "REFSRC",
    !readable ? FAIL : armsDiffer ? PASS : FAIL,
    !readable
      ? `the wire tap had NO READING for at least one arm, so this probe measured nothing: ${refsrc.control?.detail || ""} / ${refsrc.stamped?.detail || ""}`
      : armsDiffer
        ? `${refsrc.signature} · arm source: ${refsrc.source}`
        : `THE TWO ARMS AGREE (${refsrc.control?.verdict} / ${refsrc.stamped?.verdict}), so this run cannot tell a suppressed press from a dead tap — that is an INSTRUMENT verdict, not a product one. ${refsrc.signature}`,
    [
      check("control arm (no ref-src) SENT", refsrc.control?.verdict === "SENT" ? PASS : FAIL, refsrc.control?.detail || "(none)"),
      check("stamped arm NOT SENT", refsrc.stamped?.verdict === "NOT SENT" ? PASS : FAIL, refsrc.stamped?.detail || "(none)"),
      check("silent (no exception)", (refsrc.exceptions || []).length === 0 ? PASS : FAIL, `${(refsrc.exceptions || []).length} exception(s)`),
      check("arm source", PASS, refsrc.source || "(unknown)"),
    ],
    { gating: false },
  );
  return floor;
}

// ─────────────────────────────────────────────────────────────────────────────
//  the fixture (--self-test) — a miniature Barkpark, zero dependencies
// ─────────────────────────────────────────────────────────────────────────────
// It serves BOTH honest sites from one process. `/good/` hydrates its canvas
// after a beat and persists what is typed. `/rot/` upgrades the element, sets
// `_editor` truthy, and leaves `blocks` EMPTY forever — the precise defect that
// made three verifiers report on an editor they never actually saw.
//
// The fixture is deliberately a mini-Barkpark and not a mock of this harness's
// helpers: the self-test therefore exercises the real mint → redeem → cookie →
// desk → create → canvas → drafts-query path, including the '{}' mint-body rule
// (a non-empty body mints a USER ticket and the admin discriminator goes red).

const FIXTURE_TOKEN = "fixture-admin-token";

// THE DESK ROSTER IS A ROW-KIND ROSTER, not a list of Structure rows. LEG C's
// first version censused six identical `button.pane-item` rows, which is why
// three of its four bugs were invisible: the plugin ANCHOR (no phx-value-id, no
// aria-current — both identity witnesses structurally unavailable), the
// COLLAPSED STRIP (a `button.pane-column--collapsed` whose answer is its own
// expansion, not a URL), and the real `.pane-doc-item` (a DIV wrapper whose
// control is the INNER `button.bp-doc-row-body`) were all absent. So the fixture
// serves one of each, in the real markup, plus the three id-less `.pane-add-btn`
// header controls.
//
// `/good/` RENDERS NO `.pane-section-header`, and `/rot/` RENDERS EXACTLY ONE.
// That asymmetry is the whole of spd-w19-section-header-absent-on-desk: the
// deployed desk renders zero (see the RULING in LEG C's header), so a /good
// fixture that rendered two was modelling a shape production never produces and
// buying a PASS that could not fire against it. /rot keeps one so the PRESENCE
// TRIPWIRE that replaced that PASS has its red demonstrated offline, on every
// run, like every other red in this file.
//
// `/good/` ALSO CARRIES THREE `.pane-doc-item` ROWS, and pressing one REPLACES
// the pane the other two live in — the exact structural shape measured on
// guerrilla, where 235 of 236 doc rows reported "the row was gone from the desk
// when its turn came". Without more than one doc row the recovery is untestable
// offline; with three, the self-test proves it twice.
//
// AND /good/ IS HONEST: every row on it either answers or names its refusal. The
// old fixture wired ONE row (#item-paper) and left five dead IDENTICALLY on both
// sites, so LEG C's red on /rot/ arrived for free and proved nothing about
// /rot/. /rot/ now differs on purpose: only #item-paper answers, the strip and
// the doc row are dead, and #item-counts-decoy MOVES THE PANE AND ROW COUNTS
// WITHOUT NAMING ITSELF — the exact shape a snapshot diff called an answer.
//
// `paneAtLoad` is the PAPER-PANE DEEP LINK: `…/studio/paper` renders the desk
// WITH the document pane already on it, which is what the real desk does for
// that URL and what makes a doc row's enumeration URL a recovery target at all.
function fixtureDeskHtml(site, { paneAtLoad = false } = {}) {
  const base = `/${site}/w/default/p/default/d/production`;
  const rows = [
    { id: "item-paper", value: "paper", label: "Papers" },
    // Two selecting rows is the coverage: one that /good/ answers and /rot/ does
    // not. A third identical one only costs another 16s of dead-row cap on /rot/.
    { id: "item-sheet", value: "sheet", label: "Sheets" },
  ];
  // THE DOCUMENT ROWS. /good/ carries THREE — spd-w19-census-doc-row-coverage
  // c2 needs more than one, because with a single row the "the row was gone from
  // the desk when its turn came" shape cannot occur offline at all and the
  // recovery could never be asserted. Three means the census has to recover
  // TWICE to measure them all.
  //
  // /rot/ carries ONE, and that is the same arithmetic the two-Structure-row
  // comment above makes: on /rot/ every row is dead, so each extra one costs a
  // full dead-row cap (2 presses × the 3s LEG_C_ROW_CAP, plus probes) and buys no
  // red that the first row does not already buy. The "128.5s of its 150s
  // LEG_C_BUDGET" this comment used to quote for three of them was priced at the
  // unattributed 16.2s/row; the measured cost is 6.09–6.10s/row (see
  // LEG_C_BUDGET), so three would cost ~44.5s of the 90s budget. The margin is
  // still the point — a fixture that truncates reds this self-test — but it is a
  // 2x margin at one doc row, not a fixture pressed against its ceiling.
  const docRows = [
    { id: "doc-fossil-old",   value: "paper-fossil-old",   title: "An older paper", label: "An older paper, published" },
    { id: "doc-fossil-two",   value: "paper-fossil-two",   title: "A second paper", label: "A second paper, published" },
    { id: "doc-fossil-three", value: "paper-fossil-three", title: "A third paper",  label: "A third paper, published" },
  ].slice(0, site === "rot" ? 1 : 3);
  const decoy =
    site === "rot"
      ? `<button type="button" class="pane-item" id="item-counts-decoy" phx-click="select" phx-value-id="counts-decoy" phx-value-pane="0"><span class="pane-item-label">Counts only</span></button>`
      : "";
  return `<!doctype html><meta charset="utf-8"><title>fixture desk</title><body>
<div data-phx-main id="phx-fixture" class="phx-connecting">
<button type="button" phx-click="shares-open" aria-label="Network shares">S</button>
<div id="studio-panes">
<!-- The collapsed strip IS the pane, collapsed (panes.ex:178): a real <button>
     carrying phx-value-idx and an aria-label, and NO phx-value-id and NO
     aria-current — so its only witness is that IT stops being collapsed. -->
<button type="button" class="pane-column pane-column--collapsed" id="pane-navigate"
        data-role="navigate" phx-click="expand-pane" phx-value-idx="0"
        title="Back to Navigate" aria-label="Back to Navigate" aria-controls="studio-panes">
  <div class="pane-header"></div>
  <div class="pane-column-collapsed-label">Navigate</div>
</button>
<div class="pane-column" id="pane-structure">
${
  // THE TRIPWIRE'S RED, and it is here rather than on /good on purpose. The
  // deployed desk renders ZERO .pane-section-header (RULING, LEG C header), so
  // /good models the desk truthfully by rendering none — and /rot renders one
  // so the presence tripwire is proven to FIRE offline on every run.
  site === "rot" ? `<div class="pane-section-header">Content</div>` : ""
}
${rows.map((r) => `<button type="button" class="pane-item" id="${r.id}" phx-click="select" phx-value-id="${r.value}" phx-value-pane="0"${
  // THE REF-STUCK ROW, /rot only. `data-phx-ref-src` is what LiveView stamps on
  // an element while its event is in flight, and `syncPendingAttrs` CARRIES IT
  // ACROSS a re-render — so a row whose earlier press is still outstanding is
  // rendered exactly like this. bindClick then returns EARLY on it
  // (live_socket.js: `!r.hasAttribute(N) && this.debounce(...)`), and the press
  // is discarded with no frame, no exception and no server trace.
  //
  // It is here so the tap's NOT SENT verdict is DEMONSTRATED offline on every
  // run rather than promised in a comment. /rot's other dead rows are dead the
  // OTHER way — their press goes out on the wire and nothing answers it — so
  // the two verdicts red for different reasons on the same site, which is the
  // whole distinction this instrument exists to draw.
  site === "rot" && r.id === "item-sheet" ? ` data-phx-ref-src="phx-fixture"` : ""
}><span class="pane-item-label">${r.label}</span></button>`).join("\n")}
${decoy}
<!-- components.ex:1192 — an <a>, not a button. It matches .pane-item, so a
     census enumerates it, and neither identity witness exists on it. -->
<a id="plugin-link-tickets" href="${base}/plugin/tickets" class="pane-item nav-plugin-entry" data-test-id="nav-plugin-entry"><span class="pane-item-label">Tickets</span></a>
</div>
<div id="docs"></div>
</div>
</div>
<script>
  var site = ${JSON.stringify(site)};
  var BASE = ${JSON.stringify(base)};
  var LIVE_ROWS = ${site === "rot" ? "false" : "true"};   // /rot/: only #item-paper answers
  // The swallowed-click trap, reproduced: the rows are in the DEAD markup and
  // the socket "joins" a beat later. A click before that is dropped silently, so
  // a harness that does not gate on .phx-connected fails against this fixture
  // for the same reason it failed against guerrilla.
  var main = document.getElementById("phx-fixture");
  setTimeout(function () { main.className = "phx-connected"; }, 700);

  // ── THE LIVEVIEW SOCKET, AND THE TWO CLIENT-SIDE DROP GATES ───────────────
  // (spd-w18-desk-click-latency, criterion 0)
  //
  // The whole point of the wire tap is that "never sent" and "sent and ignored"
  // are the SAME silence in the DOM and need OPPOSITE fixes. That distinction
  // can only be asserted offline if this fixture actually puts frames on a
  // socket, and drops them where the real client drops them. Both gates below
  // are transcribed from the shipped client, not invented:
  //
  //   1. NOT JOINED YET — 'View.pushWithReply' opens with
  //      'if(!this.isConnected()) return Promise.reject(new Error("no connection"))',
  //      and 'View.isConnected(){ return this.channel.canPush() }'. A press
  //      before the channel joins produces NO frame.
  //   2. A REF IS ALREADY STAMPED — 'bindClick' ends
  //      '!r.hasAttribute(N) && this.debounce(...)' with N = "data-phx-ref-src".
  //      A press on an element whose previous event is still in flight produces
  //      NO frame.
  //
  // Neither raises, neither flashes, and neither leaves a server-side trace.
  // Everything else pushes — INCLUDING a press on a row this fixture answers
  // with nothing, which is the other arm: the server heard it and said nothing.
  var LV = null;
  setTimeout(function () {
    try {
      LV = new WebSocket(location.origin.replace(/^http/, "ws") + "/" + site + "/live/websocket?vsn=2.0.0");
      LV.addEventListener("error", function () { /* the tap reads the SENT side */ });
    } catch (e) { LV = null; }
  }, 700);
  // Capture phase on document, so this models the client's window-level binding
  // running for EVERY press regardless of which per-row listener also fires.
  document.addEventListener("click", function (ev) {
    var el = ev.target && ev.target.closest ? ev.target.closest("[phx-click]") : null;
    if (!el) return;
    if (!LV || LV.readyState !== 1) return;              // gate 1: no connection
    if (el.hasAttribute("data-phx-ref-src")) return;     // gate 2: bindClick's early return
    try {
      LV.send('["4","5","lv:phx-fixture","event",{"type":"click","event":' +
        JSON.stringify(el.getAttribute("phx-click") || "") + ',"value":{}}]');
    } catch (e) { /* a closing socket is not a press */ }
  }, true);
  // The ONE honest answer a selecting row gives: aria-current moves onto THIS
  // element and the URL gains THIS row's own phx-value-id. Both are per-row
  // identity, which is what LEG C attributes on.
  function answer(el) {
    var all = document.querySelectorAll("[aria-current]");
    for (var i = 0; i < all.length; i++) all[i].removeAttribute("aria-current");
    el.setAttribute("aria-current", "true");
  }
  // THE DOCUMENT PANE, built ONCE and used in two places: the #item-paper press
  // grows it, and a load of the \`…/studio/paper\` deep link renders it straight
  // away. Both matter — the second is what a doc row's RECOVERY navigates back
  // to, and if the two disagreed the recovery would be testing a pane the press
  // never produces.
  var DOC_ROWS = ${JSON.stringify(docRows)};   // three on /good/, one on /rot/ — see docRows
  var DOC_PANE_HTML =
    '<div class="pane-column" id="pane-papers">' +
    // The DECOY first, exactly as the airdrop-open .pane-add-btn in
    // components.ex renders it: same class,
    // same phx-value-type, NO aria-label, a different event. A driver keying
    // off .pane-add-btn[phx-value-type=paper] clicks THIS one and opens the
    // share sheet while believing it pressed "+".
    // ICON-ONLY, like the real ones (an .icon component renders an svg):
    // innerText is EMPTY, so the ONLY name these two carry is a title
    // tooltip. The census prints that as title:"…" rather than folding it
    // in, because a tooltip-only name is a finding, not a label.
    '<button type="button" class="pane-add-btn" phx-click="airdrop-open" phx-value-type="paper" title="Share access to paper" data-test-id="airdrop-open-type"><svg width="14" height="14" aria-hidden="true"></svg></button>' +
    // The access-panel entry: a THIRD .pane-add-btn, with no phx-value-type
    // and no aria-label either (the access-open .pane-add-btn in
    // components.ex). All three are id-less,
    // which is the fact the census inventories.
    '<button type="button" class="pane-add-btn" phx-click="access-open" title="Review scoped access grants" data-test-id="access-open-type"><svg width="14" height="14" aria-hidden="true"></svg></button>' +
    '<button type="button" class="pane-add-btn" phx-click="new-document" phx-value-type="paper" title="New paper" aria-label="New paper">+</button>' +
    // THE REAL DOC-ROW SHAPE (pane_doc_item in panes.ex): the .pane-doc-item is a DIV
    // wrapper and the control is the INNER button.bp-doc-row-body, which owns
    // phx-value-id, title, aria-label and aria-current. A census that clicks
    // the wrapper clicks nothing.
    DOC_ROWS.map(function (d) {
      return '<div class="pane-doc-item" id="' + d.id + '">' +
        '<span class="bp-doc-checkbox" phx-click="toggle-doc-checkbox" phx-value-id="' + d.value + '" data-test-id="doc-checkbox-' + d.value + '"><span class="bp-doc-checkbox-box"></span></span>' +
        '<button type="button" class="bp-doc-row-body" title="' + d.value + '" aria-label="' + d.label + '" phx-click="select" phx-value-pane="1" phx-value-id="' + d.value + '">' +
        '<span class="pane-doc-main"><span class="pane-doc-title"><span class="pane-doc-dot published"></span>' + d.title + '</span></span>' +
        '</button></div>';
    }).join("") +
    '</div>';
  // THE DEEP LINK. Server-rendered on the real desk; here it is the same pane
  // the press builds, present at load, so \`…/studio/paper\` is a real recovery
  // target rather than a URL that answers with an empty desk.
  if (${paneAtLoad ? "true" : "false"}) document.getElementById("docs").innerHTML = DOC_PANE_HTML;
  document.getElementById("item-paper").addEventListener("click", function () {
    if (!main.classList.contains("phx-connected")) return;   // dropped on the floor
    var self = this;
    // Two-stage, exactly like the real desk: Scope.select push_patches the URL
    // first (measured at 2.4s on guerrilla) and the pane column arrives with the
    // patch. Nothing here is instant — a harness that samples once instead of
    // polling must fail against this fixture.
    setTimeout(function () {
      if (LIVE_ROWS) answer(self);
      history.pushState({}, "", BASE + "/studio/paper");
    }, 400);
    setTimeout(function () {
      document.getElementById("docs").innerHTML = DOC_PANE_HTML;
    }, 900);
  });
  // Every OTHER selecting row, on /good/ only. /rot/ leaves them dead, which is
  // what makes /rot/'s census red for a REASON instead of by accident.
  var others = document.querySelectorAll("button.pane-item:not(#item-paper)");
  for (var i = 0; i < others.length; i++) {
    (function (el) {
      el.addEventListener("click", function () {
        if (!main.classList.contains("phx-connected")) return;
        if (el.id === "item-counts-decoy") {
          // THE COUNTS-ONLY DECOY, and it exists so "counts cannot make a row
          // green" is DEMONSTRATED rather than promised. It moves the pane count
          // AND the .pane-item count and it never touches aria-current or the
          // URL — the precise shape that credited the dead #item-sheet with its
          // neighbour's answer 900 ms later.
          setTimeout(function () {
            // IDEMPOTENT: the census presses a silent row twice (a mount patch
            // can swallow the first press), and a decoy that spawned a second
            // pane on the retry would mint a DUPLICATE #item-decoy-spawn — two
            // rows with one id, which is a fixture bug wearing a census finding.
            if (document.getElementById("pane-decoy")) return;
            var d = document.createElement("div");
            d.className = "pane-column";
            d.id = "pane-decoy";
            d.innerHTML = '<button type="button" class="pane-item" id="item-decoy-spawn" phx-click="select" phx-value-id="decoy-spawn"><span class="pane-item-label">Spawned by the counts decoy</span></button>';
            document.getElementById("studio-panes").appendChild(d);
          }, 300);
          return;
        }
        if (!LIVE_ROWS) return;                    // /rot/: the row is dead
        setTimeout(function () {
          answer(el);
          history.pushState({}, "", BASE + "/studio/" + el.getAttribute("phx-value-id"));
        }, 250);
      });
    })(others[i]);
  }
  // The collapsed strip's answer is ITS OWN EXPANSION — no URL, no aria-current.
  document.getElementById("pane-navigate").addEventListener("click", function () {
    if (!LIVE_ROWS || !main.classList.contains("phx-connected")) return;
    var el = this;
    setTimeout(function () {
      var d = document.createElement("div");
      d.className = "pane-column";
      d.id = el.id;                                 // same id: the witness is by id
      d.setAttribute("data-role", "navigate");
      d.innerHTML = '<div class="pane-header"><span class="pane-title">Navigate</span></div>';
      el.replaceWith(d);
    }, 250);
  });
  // Document rows are created with the pane, so they are wired by delegation.
  document.addEventListener("click", function (ev) {
    var b = ev.target.closest ? ev.target.closest("button.bp-doc-row-body") : null;
    if (!b || !LIVE_ROWS) return;
    setTimeout(function () {
      var id = b.getAttribute("phx-value-id");
      var name = b.getAttribute("aria-label");
      answer(b);
      history.pushState({}, "", BASE + "/studio/paper/" + id);
      // THE 235-OF-236 SHAPE, REPRODUCED. Opening a document REPLACES the pane
      // its siblings live in, so every doc row after this one holds a node that
      // is no longer in the document by the time its turn comes. This happens in
      // the SAME tick as the URL patch, not on a later timer, so it is
      // DETERMINISTIC: a fixture that raced the census would prove the recovery
      // only on a slow host. The pressed row still answers — its witness is the
      // URL newly carrying its OWN phx-value-id, which is exactly how the one
      // measured row on guerrilla passed while its 235 siblings vanished.
      document.getElementById("docs").innerHTML =
        '<div class="pane-column" id="pane-document"><div class="pane-header"><span class="pane-title">' + name + '</span></div></div>';
    }, 250);
  });
  document.addEventListener("click", function (ev) {
    var b = ev.target.closest ? ev.target.closest("button.pane-add-btn") : null;
    if (!b) return;
    // Only the new-document button creates. Pressing the decoy does what the
    // real one does — something else entirely — so the self-test would fail if
    // the harness ever went back to the ambiguous selector.
    if (b.getAttribute("phx-click") !== "new-document") { b.setAttribute("data-decoy-pressed", "1"); return; }
    fetch("/" + site + "/fixture/new", { method: "POST" })
      .then(function (r) { return r.json(); })
      .then(function (j) { location.href = "/" + site + "/w/default/p/default/d/production/studio/paper/" + j.id; });
  });
</script></body>`;
}

/** The fossil branch (LEG B's self-test). A stored document with ZERO blocks is
 *  the fixture's stand-in for a draft-only fossil, and the two sites answer it
 *  differently on purpose:
 *    /good/ obeys the never-blank contract — a NAMED VISIBLE STATE carrying the
 *           document's id and a way out.
 *    /rot/  is today's guerrilla — the editor region renders and says NOTHING.
 *  So LEG B's red is demonstrated offline instead of being a comment claiming
 *  the beat would catch something.
 *
 *  /good/ RENDERS THE SHIPPED SHAPE, NOT A CONVENIENT ONE. It used to wrap the
 *  notice in a `.bp-paper-editor`, which is the ONE thing the real page does not
 *  do — so the fixture agreed with a broken oracle and LEG B's false negative
 *  survived a green self-test. The real branch is
 *  `main.bp-paper-shell > article#paper-body-<slug> > .bp-paper-unrenderable`
 *  with NO `.bp-paper-editor` anywhere (components.ex:223/296/378), which is
 *  what is reproduced here: revert EDITOR_REGION_SEL to the two old selectors
 *  and /good/'s FOSSIL beats go red offline, by construction. */
function fixtureBlankHtml(site, id) {
  if (site === "rot") {
    return `<!doctype html><meta charset="utf-8"><title>fixture blank</title><body>
<div class="bp-paper-editor"></div></body>`;
  }
  return `<!doctype html><meta charset="utf-8"><title>fixture named state</title><body>
<main class="bp-paper-shell bp-paper-surface" data-test-id="studio-paper-shell">
  <div id="paper-sentinel" data-slug="${id}" hidden></div>
  <article id="paper-body-${id}" data-rev="1">
    <div class="bp-paper-unrenderable" role="alert" aria-live="assertive"
         data-test-id="paper-unrenderable-notice" data-doc-id="${id}" data-doc-type="paper">
      <p class="bp-paper-unrenderable-title">Studio cannot render the body of this paper.</p>
      <p class="bp-paper-unrenderable-reason"><code>${id}</code> (paper) was stored without a body
        block list and without saved HTML, so there is nothing here to show or edit yet.</p>
      <div class="bp-paper-unrenderable-actions">
        <button type="button" data-test-id="paper-unrenderable-start-body">Start the body</button>
        <a href="/studio/paper">All papers</a>
      </div>
    </div>
  </article>
</main></body>`;
}

function fixtureEditorHtml(site, id, doc) {
  const rot = site === "rot";
  const seeded = (doc?.blocks || []);
  if (seeded.length === 0) return fixtureBlankHtml(site, id);
  return `<!doctype html><meta charset="utf-8"><title>fixture editor</title><body>
<div class="bp-paper-editor">
  <!-- THE STALE CANVAS, reproduced. The run wrapper is phx-update="ignore", so
       the PREVIOUS document's canvas survives a push_patch and is still in the
       DOM — already hydrated — when the new document's URL is showing. It is
       rendered FIRST here, so an unscoped querySelector("bp-paper-canvas") finds
       THIS one: a harness that does not scope to paper-canvas-<id>-run-* passes
       HYDRATE instantly on the wrong document and then types into it. -->
  <div id="paper-canvas-paper-stalefx-run-0" phx-update="ignore" class="bp-paper-edit-canvas">
    <bp-paper-canvas data-doc-id="paper-stalefx"></bp-paper-canvas>
  </div>
  <div id="paper-canvas-drafts.${id}-run-0" phx-update="ignore" class="bp-paper-edit-canvas">
    <bp-paper-canvas data-doc-id="${id}"></bp-paper-canvas>
  </div>
  <div class="bp-paper-add-block"><label>Add block</label></div>
  <span class="bp-paper-footer-save" role="status" aria-live="polite" tabindex="-1" data-test-id="bp-paper-footer-save"></span>
</div>
<script>
  var ROT = ${rot ? "true" : "false"};
  var DOC = ${JSON.stringify(id)};
  var SITE = ${JSON.stringify(site)};
  // Served from the store, so a RELOAD really does come back from the server —
  // a fixture that re-seeded a blank template on every load would make the
  // RELOAD beat unfalsifiable.
  var SEED = ${JSON.stringify(seeded)};
  class Canvas extends HTMLElement {
    constructor() { super(); this._blocks = []; this._editor = null; }
    get stale() { return this.getAttribute("data-doc-id") !== DOC; }
    connectedCallback() {
      // THE TRAP, reproduced: _editor becomes truthy immediately in BOTH
      // sites. Only /good/ ever populates blocks. A driver gating on _editor
      // cannot tell these two apart.
      this._editor = { real: true };
      var self = this;
      // The stale canvas is ALREADY hydrated — it is the leftover from the
      // previous document — and it never saves anywhere. It hydrates in both
      // sites, including /rot/, so /rot/'s HYDRATE red also proves the scoping:
      // an unscoped harness would find this one and call the beat green.
      if (this.stale) return this.hydrate();
      if (ROT) return;                       // rotten: blocks stay [] forever
      setTimeout(function () { self.hydrate(); }, 700);
    }
    hydrate() {
      if (this.stale) {
        this._blocks = [{ id: "tpl-title", type: "heading", level: 1, text: "STALE CANVAS FROM THE PREVIOUS DOCUMENT" },
                        { id: "tpl-body", type: "paragraph", content: [{ type: "text", text: "not this document" }] }];
        this.innerHTML =
          '<div class="bp-paper-editor-body"><div class="ProseMirror" contenteditable="true">' +
          '<h1>STALE CANVAS FROM THE PREVIOUS DOCUMENT</h1><p>not this document</p></div></div>';
        return;
      }
      this._blocks = JSON.parse(JSON.stringify(SEED));
      var esc = function (s) { return String(s == null ? "" : s).replace(/[<&]/g, function (c) { return c === "<" ? "&lt;" : "&amp;"; }); };
      var h = esc(this._blocks[0] && this._blocks[0].text);
      var pTxt = "";
      var pc = (this._blocks[1] && this._blocks[1].content) || [];
      for (var i = 0; i < pc.length; i++) pTxt += esc(pc[i].text);
      this.innerHTML =
        '<div class="bp-paper-editor-body"><div class="ProseMirror" contenteditable="true">' +
        '<h1 data-bp-id="tpl-title">' + (h || "<br>") + '</h1>' +
        '<p data-bp-id="tpl-body">' + (pTxt || "<br>") + '</p></div></div>';
      var pm = this.querySelector(".ProseMirror");
      var self = this;
      var timer = null;
      pm.addEventListener("input", function () {
        // Autosave on a debounce, exactly like contract.js DEBOUNCE_MS — and
        // no Save button anywhere, exactly like the real editor.
        clearTimeout(timer);
        timer = setTimeout(function () { self.save(); }, 300);
      });
    }
    save() {
      var pm = this.querySelector(".ProseMirror");
      var h = pm.querySelector("h1"), p = pm.querySelector("p");
      this._blocks[0].text = (h.innerText || h.textContent || "").trim();
      this._blocks[1].content = [{ type: "text", text: (p.innerText || p.textContent || "").trim() }];
      fetch("/" + SITE + "/fixture/save/" + DOC, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ blocks: this._blocks })
      });
    }
    get blocks() { return this._blocks; }
    set blocks(v) { this._blocks = v || []; }
  }
  customElements.define("bp-paper-canvas", Canvas);
</script></body>`;
}

/** The first text a block set carries, which is what the fixture's save uses as
 *  the document's title. Shallow on purpose: the real derivation lives on the
 *  server and this only has to produce the PROPERTY "non-empty, not Untitled". */
function blockText(blocks) {
  for (const b of blocks || []) {
    const t = (b?.text ?? (b?.content || []).map((c) => c?.text || "").join("")).trim();
    if (t) return t;
  }
  return "";
}

/** The four pre-seeded sweep specimens, named ONCE so the fixture and the
 *  assertions cannot drift apart. Their expected fates are in SWEEP_EXPECT. */
const SWEEP_SPECIMENS = {
  dead_run: "drafts.paper-fx-deadrun",
  live_sibling: "drafts.paper-fx-sibling",
  human: "drafts.paper-fx-human",
  pre_stamp: "drafts.paper-fx-prestamp",
};
/** true = the run must DELETE it; false = the run must LEAVE it. Both directions
 *  on purpose: a sweep asserted only on what it removes is one edit away from
 *  removing everything and still passing. */
const SWEEP_EXPECT = { dead_run: true, live_sibling: false, human: false, pre_stamp: false };

function startFixture() {
  // One store per site so /good/ and /rot/ can never read each other's writes.
  const store = { good: new Map(), rot: new Map() };
  const sessions = new Map(); // ticket -> "admin" | "user"
  let seq = 0;

  // The two named fossils, seeded into BOTH sites as blocks-less drafts with
  // _updatedAt == _createdAt — the shape measured on guerrilla. LEG B then runs
  // for real offline: /good/ answers them with a named state, /rot/ blanks.
  for (const site of ["good", "rot"]) {
    for (const f of FOSSILS) {
      const at = "2026-07-09T14:16:39.143678Z";
      store[site].set(f.draftId, {
        _id: f.draftId, _publishedId: f.docId, _type: "paper", _draft: true,
        _createdAt: at, _updatedAt: at, title: "Untitled", blocks: [],
      });
    }
    // ── THE FOUR SWEEP SPECIMENS (task-d582be9d064f35dc) ──────────────────
    // The run's OWN document can never test the sweep: the self-clean adds
    // `run.created_doc_id` by hand, so a fixture run that completes deletes its
    // paper whatever the predicate says. The class this row is about is a
    // document left by a run that DIED, and only a pre-seeded one can stand in
    // for it. All four are asserted, in both directions, in selfTest().
    const long_ago = new Date(Date.now() - 45 * 60 * 1000).toISOString();
    const moments_ago = new Date(Date.now() - 5 * 1000).toISOString();
    const typed = [
      { id: "tpl-title", type: "heading", level: 1, role: "title", locked: true, text: "JOURNEY HEADING DEADRUN" },
      { id: "tpl-body", type: "paragraph", content: [{ text: "journey paragraph DEADRUN" }] },
    ];
    // 1. MUST BE SWEPT. A dead run's leftover: stamped, TITLED by its own TYPE
    //    beat, far older than STALE_DEBRIS_MS. The old title-keyed predicate
    //    cannot select it — delete the stamp arm and the residue assertion reds.
    store[site].set(SWEEP_SPECIMENS.dead_run, {
      _id: SWEEP_SPECIMENS.dead_run, _publishedId: SWEEP_SPECIMENS.dead_run.slice(7), _type: "paper", _draft: true,
      _createdAt: long_ago, _updatedAt: long_ago, title: "journey paragraph DEADRUN", blocks: typed,
      [STAMP_FIELD]: { harness: HARNESS_MARK, run_id: "DEADRUN", host: "fixture", stamped_at: long_ago },
    });
    // 2. MUST SURVIVE. A CONCURRENT run's live document — stamped, titled, five
    //    seconds old. This is the only thing standing between arm 1 and a
    //    sibling run's in-flight paper, so it is asserted, not trusted.
    store[site].set(SWEEP_SPECIMENS.live_sibling, {
      _id: SWEEP_SPECIMENS.live_sibling, _publishedId: SWEEP_SPECIMENS.live_sibling.slice(7), _type: "paper", _draft: true,
      _createdAt: moments_ago, _updatedAt: moments_ago, title: "journey paragraph SIBLING", blocks: typed,
      [STAMP_FIELD]: { harness: HARNESS_MARK, run_id: "SIBLING", host: "fixture", stamped_at: moments_ago },
    });
    // 3. MUST SURVIVE. A HUMAN's paper: no stamp, a real title, old. Nothing may
    //    ever select this, and it is what makes the sweep safe to run on a host
    //    other people use.
    store[site].set(SWEEP_SPECIMENS.human, {
      _id: SWEEP_SPECIMENS.human, _publishedId: SWEEP_SPECIMENS.human.slice(7), _type: "paper", _draft: true,
      _createdAt: long_ago, _updatedAt: long_ago, title: "Q3 board notes", blocks: typed,
    });
    // 4. MUST SURVIVE, AND IT IS A DELIBERATE LIMIT, not an oversight. This is
    //    the live shape of drafts.paper-8be087501234ae2d: untitled, two blocks,
    //    UNSTAMPED, and old. It is almost certainly harness debris from before
    //    the stamp existed — and "almost certainly" is not a licence to delete a
    //    document on a live host off a predicate that cannot tell it from an
    //    empty draft a human opened and walked away from. Arm 2 stays bounded by
    //    the run's own window; pre-stamp debris is DISPOSED OF BY HAND, WITH
    //    AUTHORISATION, never by a sweep.
    store[site].set(SWEEP_SPECIMENS.pre_stamp, {
      _id: SWEEP_SPECIMENS.pre_stamp, _publishedId: SWEEP_SPECIMENS.pre_stamp.slice(7), _type: "paper", _draft: true,
      _createdAt: long_ago, _updatedAt: long_ago, title: null,
      blocks: [{ id: "tpl-title", type: "heading", level: 1, role: "title", locked: true, text: "" }, { id: "tpl-body", type: "paragraph", content: [] }],
    });
  }

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const send = (code, body, type = "text/html; charset=utf-8", extra = {}) =>
      res.writeHead(code, { "content-type": type, "cache-control": "no-store", ...extra }).end(body);
    const json = (code, obj, extra = {}) => send(code, JSON.stringify(obj), "application/json", extra);

    const m = /^\/(good|rot)(\/.*)?$/.exec(url.pathname);
    if (!m) return send(404, "not a fixture route", "text/plain");
    const site = m[1];
    const rest = m[2] || "/";
    const docs = store[site];

    // /status.json — the provenance stamp, per site so a "deploy" can be faked.
    if (rest === "/status.json") return json(200, { status: "operational", commit: `fixture-${site}`, version: "0.0.0-fixture" });

    // The mint. A NON-EMPTY body mints a USER-shaped ticket, mirroring the real
    // trap — so the '{}' rule is enforced by this fixture, not remembered.
    if (rest === "/v1/auth/login-tickets" && req.method === "POST") {
      let body = "";
      req.on("data", (c) => { body += c; });
      req.on("end", () => {
        const t = `t${++seq}`;
        sessions.set(t, body.trim() === "{}" || body.trim() === "" ? "admin" : "user");
        json(200, { ticket: t });
      });
      return;
    }

    const tm = /^\/login\/ticket\/(.+)$/.exec(rest);
    if (tm) {
      const role = sessions.get(tm[1]);
      if (!role) return send(401, "no such ticket", "text/plain");
      sessions.delete(tm[1]); // single use, like the real one
      return send(200, "<!doctype html><body>ok</body>", "text/html; charset=utf-8", {
        "set-cookie": `fixture_role=${role}; Path=/`,
      });
    }
    const role = /fixture_role=(\w+)/.exec(req.headers.cookie || "")?.[1] || null;

    // The drafts-perspective query, filter[_id][eq] included — the same oracle
    // the real run uses, including its non-vacuity (an unknown id → count 0).
    if (rest.startsWith("/v1/data/query/")) {
      const want = url.searchParams.get("filter[_id][eq]");
      if (want) {
        const hit = docs.get(want);
        return json(200, {
          result: { perspective: "drafts", limit: 1, offset: 0, count: hit ? 1 : 0, documents: hit ? [hit] : [] },
        });
      }
      // The unfiltered, _createdAt:desc list — what the litter sweep reads. The
      // fixture must serve it or the sweep is untested, and an untested sweep is
      // how the leak got here.
      let all = [...docs.values()].sort((a, b) => Date.parse(b._createdAt) - Date.parse(a._createdAt));
      // ARM 1's server-side filter, served here so the stamped query is
      // EXERCISED offline rather than assumed. Guerrilla answers
      // `filter[journeyRun.harness][eq]=<value nothing carries>` with count 0;
      // this branch reproduces that, so a fixture run cannot go green off an
      // endpoint that ignored the filter and handed back everything.
      const wantMark = url.searchParams.get(`filter[${STAMP_FIELD}.harness][eq]`);
      if (wantMark !== null) all = all.filter((d) => d?.[STAMP_FIELD]?.harness === wantMark);
      return json(200, { result: { perspective: "drafts", limit: 50, offset: 0, count: all.length, documents: all } });
    }
    if (rest.startsWith("/v1/data/mutate/") && req.method === "POST") {
      let body = "";
      req.on("data", (c) => { body += c; });
      req.on("end", () => {
        let muts = [];
        try { muts = JSON.parse(body).mutations || []; } catch { /* report below */ }
        const ids = muts.map((x) => x.delete?.id).filter(Boolean);
        for (const id of ids) { docs.delete(id); docs.delete(`drafts.${id}`); }
        // THE PROVENANCE STAMP'S WRITE PATH. `patch.set` only, which is all the
        // harness sends; guerrilla refuses a patch with no `type` (422
        // validation_failed, measured 2026-09-22) and so does this, or the
        // fixture would green a request the deployment rejects.
        const patched = [];
        for (const m of muts) {
          const pt = m.patch;
          if (!pt) continue;
          if (!pt.id || !pt.type) continue; // refuse, exactly as guerrilla does
          const doc = docs.get(pt.id);
          if (!doc) continue;
          Object.assign(doc, pt.set || {});
          doc._updatedAt = new Date().toISOString();
          patched.push(pt.id);
        }
        json(200, { results: [...ids.map((id) => ({ id, operation: "delete" })), ...patched.map((id) => ({ id, operation: "update" }))] });
      });
      return;
    }

    if (rest === "/fixture/new" && req.method === "POST") {
      const id = `paper-fx${++seq}`;
      // Born with the seeded template, exactly like Papers.Template.maybe_seed.
      docs.set(`drafts.${id}`, {
        _id: `drafts.${id}`, _publishedId: id, _type: "paper", _draft: true,
        _createdAt: new Date().toISOString(), _updatedAt: new Date().toISOString(),
        blocks: [
          { id: "tpl-title", type: "heading", level: 1, role: "title", locked: true, text: "" },
          { id: "tpl-body", type: "paragraph", content: [] },
        ],
      });
      return json(200, { id });
    }
    const sm = /^\/fixture\/save\/(.+)$/.exec(rest);
    if (sm && req.method === "POST") {
      let body = "";
      req.on("data", (c) => { body += c; });
      req.on("end", () => {
        const key = `drafts.${sm[1]}`;
        const doc = docs.get(key);
        if (doc) {
          try { doc.blocks = JSON.parse(body).blocks; } catch { /* leave it */ }
          // ── THE FIXTURE GIVES THE DOCUMENT A TITLE, AND THAT IS THE POINT ──
          // Without this the fixture could NEVER reproduce
          // task-d582be9d064f35dc: the harness's own drafts stayed title-less
          // offline, so the title-keyed sweep swept them, so the residue
          // assertion below was green on a predicate that leaves permanent
          // debris on the deployment. The fixture reproduces the PROPERTY
          // measured on guerrilla — after TYPE, the draft has a non-empty title
          // that is not "Untitled" (live: `journey paragraph MUCA9FZ6`,
          // `journey paragraph MUCA8WHGJOURNEY HEADING MUCA8WHG…`) — not the
          // server's exact derivation, which concatenates block text in an order
          // this fixture makes no claim about.
          doc.title = blockText(doc.blocks) || doc.title || null;
          doc._updatedAt = new Date().toISOString();
        }
        json(200, { ok: true });
      });
      return;
    }

    // A plugin entry's destination. It only has to be a real page load at the
    // anchor's OWN href: that is the entire witness LEG C has for a plugin_link,
    // and the row LEG C reported DEAD while this page was on the screen.
    const pl = /^\/plugin\/([\w-]+)$/.exec(rest);
    if (pl) {
      if (role !== "admin") return send(200, "<!doctype html><body><form action='/login'><h1>Sign in</h1></form></body>");
      return send(200, `<!doctype html><meta charset="utf-8"><title>fixture plugin</title><body><h1>Plugin: ${pl[1]}</h1></body>`);
    }

    // The Studio itself — admin-gated, so an anonymous or USER session gets a
    // desk with no shares button and the discriminator goes red.
    // THREE desk URLs, not two: the bare desk (`…/studio`), a PANE DEEP LINK
    // (`…/studio/<pane>`), and one document (`…/studio/<pane>/<id>`). The middle
    // one is load-bearing for spd-w19-census-doc-row-coverage, not a
    // convenience: it is what a `.pane-doc-item`'s ENUMERATION URL is, and a
    // row's recovery navigates straight back to it. Without the route the
    // recovery would land in a 404.
    //
    // ANY pane segment renders the document pane, deliberately. Which segment a
    // doc row was enumerated under depends on how far the census had walked when
    // the pane painted (`…/studio/paper` if the item-paper press's own absorb
    // caught it, `…/studio/sheet` if the next row's did), and a recovery that
    // worked for one and 404'd for the other would make this self-test a
    // coin-flip. The fixture's one document pane stands for "the pane this deep
    // link selects", which is what the real desk renders server-side for any of
    // them.
    const dm = /^\/w\/default\/p\/default\/d\/production\/studio(?:\/([^/]+)(?:\/(.+))?)?$/.exec(rest);
    if (dm) {
      if (role !== "admin") return send(200, "<!doctype html><body><form action='/login'><h1>Sign in</h1></form></body>");
      if (dm[2]) return send(200, fixtureEditorHtml(site, dm[2], docs.get(`drafts.${dm[2]}`)));
      return send(200, fixtureDeskHtml(site, { paneAtLoad: !!dm[1] }));
    }
    return send(404, "fixture: no route " + rest, "text/plain");
  });

  // ── /live/websocket, FOR REAL (spd-w18-desk-click-latency, criterion 0) ────
  //
  // The wire tap reads Chrome's own `Network.webSocketFrameSent`, so a fixture
  // with no socket would make the tap report CANNOT READ on every offline run
  // and its two real verdicts would be asserted NOWHERE. This handshake is the
  // whole server side: 101, then ignore everything. Nothing here needs to
  // DECODE a frame — the tap reads what the BROWSER sent, on the browser's
  // side, and the server is only required to keep the socket open so the page
  // can send at all.
  server.on("upgrade", (req, socket) => {
    const key = req.headers["sec-websocket-key"];
    if (!/^\/(good|rot)\/live\/websocket/.test(req.url || "") || !key) {
      socket.destroy();
      return;
    }
    const accept = crypto
      .createHash("sha1")
      .update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      .digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
    socket.on("data", () => { /* the fixture never replies; the tap reads the SENT side */ });
    socket.on("error", () => { /* a closed tab is not a fixture failure */ });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port, store }));
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  reporting
// ─────────────────────────────────────────────────────────────────────────────
const MARK = { [PASS]: "✓", [FAIL]: "✗", [PENDING]: "·" };

function report(ledger, { base, mode, wall, pre, post, legs = "abc" }) {
  const lines = [`\n   ${mode}  ${base}`, `   served ${pre.commit} → ${post.commit}${pre.commit === post.commit ? "" : "  ** MOVED **"}\n`];
  for (const beat of ledger.beats) {
    const tag = beat.gating ? "" : "  (report-only)";
    lines.push(`   ${MARK[beat.status]} ${beat.status.padEnd(7)} ${beat.name.padEnd(16)} ${beat.detail}${tag}`);
    for (const c of beat.checks) {
      lines.push(`                       ${MARK[c.status]} ${c.label}${c.note ? ` — ${c.note}` : ""}`);
    }
  }
  const g = ledger.gatingBeats;
  // NAME WHAT WAS TALLIED. With `--legs c` the gating beats are AUTH alone, and
  // printing them under "LEG A" would report a census run as a create-journey
  // run — the exact species of lie this harness exists to stop.
  const gatedLabel = String(legs).includes("a") ? "LEG A" : `legs=${legs} gating`;
  lines.push(`\n   ${gatedLabel} ${g.filter((b) => b.status === PASS).length}/${g.length} beats PASS · ${(wall / 1000).toFixed(1)}s wall`);
  return lines.join("\n") + "\n";
}

// ─────────────────────────────────────────────────────────────────────────────
//  the run
// ─────────────────────────────────────────────────────────────────────────────
async function withChrome(fn) {
  const chromeBin = findChrome();
  if (!chromeBin) {
    guard(
      process.env.CHROME
        ? `CHROME=${process.env.CHROME} is not an executable file. Point it at a real Chrome/Chromium binary.`
        : "no Chrome/Chromium found on any known path. Set CHROME=/path/to/chrome.",
    );
  }
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "studio-journey-"));
  let chrome = null, cdp = null;

  const teardown = async () => {
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), pause(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    // Nothing here EVER blocks on the Chrome child: a blocking wait on a Chrome
    // that ignores SIGTERM is a measured multi-hour stall on this host.
    const alive = (p) => { if (!p || p.pid == null) return false; try { process.kill(p.pid, 0); return true; } catch { return false; } };
    if (alive(chrome)) {
      try { chrome.kill("SIGTERM"); } catch { /* gone */ }
      let waited = 0;
      while (alive(chrome) && waited < TERM_POLL_CAP) { await pause(50); waited += 50; } // kill ladder
      if (alive(chrome)) {
        try { chrome.kill("SIGKILL"); } catch { /* gone */ }
        waited = 0;
        while (alive(chrome) && waited < KILL_POLL_CAP) { await pause(50); waited += 50; } // kill ladder
        if (alive(chrome)) {
          process.stderr.write(`!! TEARDOWN SHOUT: chrome pid ${chrome.pid} SURVIVED SIGKILL. Reap it by hand: kill -9 ${chrome.pid}\n`);
        }
      }
    }
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
  };

  try {
    chrome = spawn(chromeBin, [
      "--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
      "--no-first-run", "--no-default-browser-check", "--disable-extensions",
      "--disable-background-networking", "--window-size=1500,1000",
      `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank",
    ], { stdio: "ignore" });
    // A spawn failure arrives as an 'error' EVENT, not a throw. Unhandled, it
    // takes the whole process down with exit 1. Swallowed here so the missing
    // DevToolsActivePort below becomes the GUARD, which is the correct class.
    chrome.on("error", () => { /* surfaced as the DevToolsActivePort guard */ });

    const portFile = path.join(profile, "DevToolsActivePort");
    let devPort = null;
    for (let w = 0; w < DEVTOOLS_CAP; w += 100) {
      try {
        const raw = fs.readFileSync(portFile, "utf8").split("\n");
        if (raw[0] && Number(raw[0])) { devPort = Number(raw[0]); break; }
      } catch { /* not written yet */ }
      await pause(100); // polling for the port file, capped
    }
    if (!devPort) guard("Chrome never wrote DevToolsActivePort — the browser did not start");

    const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    process.stdout.write(`>> chrome  ${chromeBin}\n>> build   ${version.Browser} · node ${process.version}\n`);
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);
    return await fn(cdp);
  } finally {
    await teardown();
  }
}

/** One full journey against one base. Returns the ledger, the run object and
 *  the PRE/POST provenance stamps. Throws only `Guard` (→ exit 2). */
async function journeyOne(cdp, ctx, opts) {
  const page = await Page.open(cdp);
  const ledger = new Ledger();
  const run = {
    instrument: "tooling/studio-journey/journey.mjs",
    base: ctx.base, dataset: ctx.dataset, started_at: new Date().toISOString(),
  };
  const pre = await servedCommit(ctx);
  const t0 = Date.now();
  const legs = new Set(String(opts?.legs ?? "abc"));
  run.legs = [...legs].join("");
  try {
    if (legs.has("a")) await legA(page, ctx, ledger, run);
    else await authOnly(page, ctx, ledger, run);
    if (legs.has("b")) await legB(page, ctx, ledger, run);
    // LAST, and report-only: it presses every desk row, so it must not be able
    // to disturb the document LEG A typed into before PERSIST/RELOAD have read
    // it back. It presses nothing that creates a document, so the litter sweep
    // below still holds after it.
    if (legs.has("c")) await legC(page, ctx, ledger, run);
    // LEG D LAST, for the same reason LEG C is late and one more: it NAVIGATES
    // TEN TIMES, so anything it ran before would have its page torn out from
    // under it. It creates nothing, so the litter sweep below still holds.
    if (legs.has("d")) await legD(page, ctx, ledger, run, opts);
  } catch (err) {
    if (err instanceof Guard) throw err;
    // A harness-side throw must still produce a ledger: the beats that already
    // ran keep their verdicts, and the rest are honestly unproven.
    ledger.add("HARNESS", FAIL, `journey aborted: ${err?.message || err}`, []);
  }
  const wall = Date.now() - t0;
  const post = await servedCommit(ctx);
  run.provenance = { pre, post, matched: pre.commit === post.commit };
  run.wall_ms = wall;
  run.beats = ledger.beats;

  // ── SELF-CLEAN ─────────────────────────────────────────────────────────────
  // Keyed off WHAT THE DATASET GAINED, not off what the URL admitted to. Three
  // ways this leaks otherwise, all of them observed: a harness-side throw after
  // the "+" landed; a "+" that creates without navigating (guerrilla 4f046cce1);
  // and clickUntil retrying a "+" that creates every time. `--keep` opts out for
  // a human who wants to open the document afterwards.
  if (run.create_pressed_at) {
    // BOTH ARMS. The stamped arm reclaims what a DEAD run left — the class the
    // title-keyed predicate could never select, on this run or any other. The
    // shape arm still covers the "+"-without-navigating orphans this run itself
    // could not stamp because it never learned their ids.
    const swept = await sweepTargets(ctx, "paper", run.create_pressed_at, { runId: run.run_id ?? null });
    const ids = new Set(swept.ids);
    if (run.created_doc_id) ids.add(`drafts.${run.created_doc_id}`);
    run.sweep = { by_stamp: swept.by_stamp, by_shape: swept.by_shape, stamped_seen: swept.stamped_seen, errors: swept.errors };
    run.cleanup = { docs: [...ids], deleted: [], failed: [], skipped: opts.keep ? "--keep" : null };
    if (!opts.keep) {
      for (const id of ids) {
        const del = await deleteDoc(ctx, "paper", id);
        (del.ok ? run.cleanup.deleted : run.cleanup.failed).push(del.ok ? id : `${id} (${del.error})`);
      }
    }
  }

  try { await cdp.send("Target.closeTarget", { targetId: page.targetId }); } catch { /* the browser teardown gets it */ }
  return { ledger, run, wall, pre, post };
}

// ── --self-test: green on the healthy fixture, RED on the rotten one ─────────
// The rotten expectation is the ENTIRE point. /rot/'s canvas upgrades and never
// populates, so HYDRATE fails and everything downstream is honestly PENDING —
// which is exactly what a driver gating on `_editor` would have called green.
//
// The FOSSIL beats are in here too, and they are the proof that LEG B is a real
// measurement rather than a decorative one: the same code that reports "blank"
// on guerrilla today reports PASS the moment the document answers with words.
const FOSSIL_BEATS = FOSSILS.map((f) => `FOSSIL/${f.docId.slice(-8)}`);
const withFossils = (base, verdict) =>
  Object.assign({}, base, Object.fromEntries(FOSSIL_BEATS.map((b) => [b, verdict])));

// LEG D's TWO BEATS ARE THE SAME ON BOTH SITES, and that is deliberate rather
// than lazy. FLOOR's status asks ONLY "was every iteration decidable" — the
// answer rate is reported and never gated (see legD) — so it is PASS wherever
// the row exists, and on the fixture that is both sites. REFSRC is a pure
// CLIENT-side fact: the control press (no ref-src, socket joined) must put a
// `"type":"click"` frame on the wire and the stamped press must not, and the
// fixture transcribes both of the shipped client's drop gates, so both arms
// fire offline on every run regardless of which site is serving. A site-shaped
// expectation here would be a coincidence dressed as coverage.
const SELF_TEST_EXPECT = {
  good: withFossils({ AUTH: PASS, DESK: PASS, CREATE: PASS, HYDRATE: PASS, TYPE: PASS, PERSIST: PASS, RELOAD: PASS, CENSUS: PASS, FLOOR: PASS, REFSRC: PASS }, PASS),
  rot: withFossils({ AUTH: PASS, DESK: PASS, CREATE: PASS, HYDRATE: FAIL, TYPE: PENDING, PERSIST: PENDING, RELOAD: PENDING, CENSUS: FAIL, FLOOR: PASS, REFSRC: PASS }, FAIL),
};

// ── THE CENSUS, ROW BY ROW ───────────────────────────────────────────────────
// A beat-level expectation is too coarse for LEG C: "CENSUS: FAIL on /rot/" is
// satisfied by ANY red row, including a row that is red because the harness is
// broken. So every fixture row is named with the outcome it must produce, and
// the map is COVERAGE-GUARDED in both directions — a produced row nobody named
// reds, and a named row that stopped being produced reds. That is what makes
// these three claims mechanical rather than editorial:
//   · the plugin ANCHOR passes on BOTH sites, by its own href (a real anchor
//     navigates with or without a socket) — the row identity-attribution
//     fabricated as DEAD.
//   · #item-counts-decoy FAILS on /rot/ even though it moves the pane count and
//     the .pane-item count, because counts cannot name a row.
//   · the pane_doc_item passes only when the INNER button.bp-doc-row-body is the
//     thing that was pressed.
//   · THREE pane_doc_item rows pass on /good/, and two of them ONLY because the
//     census re-navigated to the URL they were enumerated at: pressing the first
//     replaces the pane the other two live in, so without the recovery they read
//     "the row was gone from the desk when its turn came". That is the offline
//     assertion for spd-w19-census-doc-row-coverage — unwire `recoverRow` and
//     these two rows go PENDING and this map reds.
//   · NO section_header row is named on /good/, and that is not an omission: the
//     /good fixture renders none, because the deployed desk renders none (see
//     the RULING in LEG C's header). /rot/ renders one and it is expected FAIL —
//     the presence tripwire firing, demonstrated on every run.
const CENSUS_ROWS_GOOD = {
  'plugin_link#plugin-link-tickets|Tickets': PASS,
  'pane_item#item-paper|Papers': PASS,
  'pane_item#item-sheet|Sheets': PASS,
  'collapsed_strip#pane-navigate|Back to Navigate': PASS,
  'pane_doc_item#doc-fossil-old|An older paper, published': PASS,
  'pane_doc_item#doc-fossil-two|A second paper, published': PASS,
  'pane_doc_item#doc-fossil-three|A third paper, published': PASS,
  'add_btn#(no id)|title:"Share access to paper"': PASS,
  'add_btn#(no id)|title:"Review scoped access grants"': PASS,
  'add_btn#(no id)|New paper': PASS,
};
const SELF_TEST_CENSUS_EXPECT = {
  good: CENSUS_ROWS_GOOD,
  // /rot/ SERVES ONE DOC ROW, not three (see `docRows`), so the other two are
  // NOT named here: the coverage guard reds BOTH ways, and a key named for a row
  // the fixture never renders is as much a fault as a row nobody named. Hence a
  // literal rather than a spread of CENSUS_ROWS_GOOD.
  rot: {
    'plugin_link#plugin-link-tickets|Tickets': PASS,
    'pane_item#item-paper|Papers': PASS,
    'add_btn#(no id)|title:"Share access to paper"': PASS,
    'add_btn#(no id)|title:"Review scoped access grants"': PASS,
    'add_btn#(no id)|New paper': PASS,
    // /rot/'s dead rows — the reds LEG C exists to produce, each for a stated
    // reason rather than because the fixture wired nothing.
    'pane_item#item-sheet|Sheets': FAIL,
    'collapsed_strip#pane-navigate|Back to Navigate': FAIL,
    'pane_doc_item#doc-fossil-old|An older paper, published': FAIL,
    'pane_item#item-counts-decoy|Counts only': FAIL,
    'pane_item#item-decoy-spawn|Spawned by the counts decoy': FAIL,
    // THE PRESENCE TRIPWIRE, fired. /rot/ renders one `.pane-section-header`;
    // the deployed desk renders zero and should. A FAIL here is the harness
    // saying "a shape that had no producer on 2026-09-06 has appeared" — the
    // verdict that replaced a PASS-by-construction which could only ever have
    // been asserted against a fixture that produced the shape itself.
    'section_header#(no id)|Content': FAIL,
  },
};

// The one /rot row the fixture renders with `data-phx-ref-src` already stamped.
// Named ONCE, here, because two of the wire assertions below are defined against
// it and its complement — a key spelled twice is a key that drifts apart.
const SELF_TEST_REFSTUCK_KEY = "pane_item#item-sheet|Sheets";

// ── THE ASSERTION FLOOR ──────────────────────────────────────────────────────
// A GREEN WITH NO SUBJECT IS NOT EVIDENCE, and this harness has a documented way
// of producing one: the scheduled CI lane that was supposed to run it carried
// `if: github.event_name != 'schedule'` while the live arm died at the credential
// GUARD, so for forty-seven consecutive scheduled runs ZERO assertions executed
// and the only visible artefact was a red nobody read (task-2c762aa7dfca5bd8).
//
// So the self-test now COUNTS the comparisons it actually performs and refuses
// to print PASS below a floor. The count is printed on the PASS line and on the
// FAIL line, so a reader — or a CI log grep — can see the subject, not just the
// verdict. `SELF-TEST PASS` with no number is an OLD binary.
//
// The floor is deliberately well under the count a healthy run produces (measured
// 2026-09-15 on this tree: see the number the run prints). It is a FLOOR, not a
// pin: it fires when a whole leg stops being asserted, and it does not have to be
// edited every time one beat is added. Raise it when a leg is added; if it ever
// has to be LOWERED, that is the finding, not the fix.
//
// THE OVERRIDE CAN ONLY RAISE THE FLOOR (task-c1148783a9ee36e7, 2026-09-15).
// `Number(process.env.X || 40)` let one env var set the floor to 0, and a floor
// of 0 passes off ZERO assertions — the exact vacuity this guard exists to
// prevent, reachable without touching a file anybody reviews. Nothing in CI sets
// it, so nothing legitimate is lost by making the hard floor the minimum: the
// env var is honoured only where it makes the check STRICTER. A caller who wants
// a weaker floor has to edit HARD_ASSERTION_FLOOR here, in the diff, in review.
const HARD_ASSERTION_FLOOR = 48;
const SELF_TEST_ASSERTION_FLOOR = (() => {
  const raw = process.env.SELF_TEST_ASSERTION_FLOOR;
  if (raw === undefined || raw === '') return HARD_ASSERTION_FLOOR;
  const n = Number(raw);
  if (!Number.isFinite(n)) {
    throw new Error(
      `SELF_TEST_ASSERTION_FLOOR=${JSON.stringify(raw)} is not a number. ` +
      `A floor that fails to parse would silently become NaN and every comparison ` +
      `against it would be false — a guard that cannot fire. Refusing.`);
  }
  if (n < HARD_ASSERTION_FLOOR) {
    throw new Error(
      `SELF_TEST_ASSERTION_FLOOR=${n} is BELOW the hard floor of ${HARD_ASSERTION_FLOOR}. ` +
      `This override exists to make the self-test stricter, never to manufacture a ` +
      `green off fewer assertions. Refusing.`);
  }
  return n;
})();

async function selfTest(opts) {
  const { server, port, store } = await startFixture();
  const results = {}, exits = {}, residue = {}, censuses = {}, survivors = {};
  const sites = opts.selfTestSite ? [opts.selfTestSite] : Object.keys(SELF_TEST_EXPECT);
  try {
    await withChrome(async (cdp) => {
      for (const site of sites) {
        const base = `http://127.0.0.1:${port}/${site}`;
        const ctx = { base, token: FIXTURE_TOKEN, dataset: opts.dataset };
        // LEG D IS FORCED ON OFFLINE, and that is the only way it is asserted at
        // all: it is opt-in against a deployment (ten navigations), so a fixture
        // run that inherited the default `abc` would leave FLOOR and REFSRC
        // unproduced — and the coverage guard below only reds on a beat that IS
        // produced and unnamed, never on a leg that quietly stopped running.
        // Narrowed to 3 iterations at a 3s answer cap: the fixture drops every
        // early press ON PURPOSE (its socket joins at 700ms), so a 15s cap would
        // spend 150s proving what 9s proves.
        const r = await journeyOne(cdp, ctx, { ...opts, legs: opts.legs + (opts.legs.includes("d") ? "" : "d"), floorIterations: 3, floorPressCap: 3000 });
        process.stdout.write(report(r.ledger, { base, mode: `FIXTURE/${site}`, wall: r.wall, pre: r.pre, post: r.post }));
        results[site] = r.ledger.statuses();
        censuses[site] = r.run.census || null;
        exits[site] = r.ledger.clean ? 0 : 1;
        // THE LITTER SWEEP, asserted rather than trusted. After a run the store
        // must hold exactly the two pre-seeded fossils: anything else is a draft
        // the run created and failed to remove. This is checked on BOTH sites,
        // and /rot/ is the interesting one — its "+" creates and its canvas never
        // hydrates, which is precisely the shape that was leaking a draft per
        // press against the deployment.
        // The four sweep specimens have their OWN expectations (SWEEP_EXPECT),
        // so they are excluded here and asserted by name below — folding them
        // into "residue" would make one of them indistinguishable from a leak.
        const named = new Set([...FOSSILS.map((f) => f.draftId), ...Object.values(SWEEP_SPECIMENS)]);
        residue[site] = [...store[site].keys()].filter((k) => !named.has(k));
        survivors[site] = Object.fromEntries(
          Object.entries(SWEEP_SPECIMENS).map(([name, id]) => [name, store[site].has(id)]),
        );
      }
    });
  } finally {
    server.close();
  }

  // `--self-test-site` runs ONE fixture and exits with its real product verdict,
  // so the "0 on healthy, non-0 on rotten" split is demonstrated by invocation
  // rather than asserted in a comment.
  if (opts.selfTestSite) {
    const site = opts.selfTestSite;
    process.stdout.write(`\nFIXTURE ${site}: product verdict exit ${exits[site]}\n`);
    return exits[site];
  }

  const problems = [];
  // Every comparison below goes through `check`, so the count cannot drift away
  // from the assertions: adding a `problems.push` without a `check` is the one
  // way to under-report, and the coverage guards above/below are what stop a beat
  // from being added with no comparison at all.
  let asserted = 0;
  const check = (ok, msg) => { asserted += 1; if (!ok) problems.push(msg); };
  for (const [site, expected] of Object.entries(SELF_TEST_EXPECT)) {
    for (const [beat, want] of Object.entries(expected)) {
      const got = results[site]?.[beat];
      check(got === want, `${site}/${beat}: expected ${want}, got ${got ?? "(missing)"}`);
    }
  }

  // ── THE COVERAGE GUARD ─────────────────────────────────────────────────────
  // AN UNNAMED BEAT IS SILENTLY UNASSERTED, and that is not a hypothetical: the
  // loop above walks the EXPECTED keys, so the first LEG C ran on /rot/ with five
  // FAIL rows and this self-test printed SELF-TEST PASS and exited 0. Every leg
  // added after that would have been a decoration by default, and a HARNESS abort
  // beat — the one the catch in journeyOne adds when the harness itself throws —
  // read as a pass for exactly the same reason.
  //
  // So the guard walks the PRODUCED keys and reds on anything SELF_TEST_EXPECT
  // does not name. It is the mechanism that makes "the harness asserts what it
  // measures" true rather than intended, and it is proven by MUTATION: delete a
  // key from SELF_TEST_EXPECT and this reds while the run itself is unchanged.
  for (const site of sites) {
    for (const [beat, got] of Object.entries(results[site] || {})) {
      check(
        Object.prototype.hasOwnProperty.call(SELF_TEST_EXPECT[site] || {}, beat),
        `${site}/${beat}: THE RUN PRODUCED THIS BEAT (${got}) AND SELF_TEST_EXPECT DOES NOT NAME IT — ` +
          `an unnamed beat is silently unasserted, so it can never red and it is a decoration. Name it.`,
      );
    }
  }

  // The same guard, one level down, over LEG C's rows — plus the per-row verdicts
  // themselves, because "CENSUS: FAIL on /rot/" is satisfied by ANY red row,
  // including one that is red because the harness broke.
  for (const site of sites) {
    const want = SELF_TEST_CENSUS_EXPECT[site] || {};
    const rows = censuses[site]?.rows || [];
    check(rows.length > 0, `${site}: LEG C produced NO census rows at all — a census of nothing is not a census`);
    if (!rows.length) continue;
    check(!censuses[site]?.truncated,
      `${site}: LEG C hit its ${LEG_C_BUDGET}ms LEG_C_BUDGET on the FIXTURE, which is a few local rows — ` +
        `the row verdicts below are load-dependent and this self-test cannot assert them. Raise LEG_C_BUDGET_MS or run on a quieter host.`,
    );
    for (const rec of rows) {
      const named = Object.prototype.hasOwnProperty.call(want, rec.key);
      check(
        named,
        `${site}: LEG C CENSUSED A ROW NOBODY NAMED — "${rec.key}" came back ${rec.outcome}. ` +
          `Name it in SELF_TEST_CENSUS_EXPECT or an unasserted row can never red.`,
      );
      if (!named) continue;
      check(rec.outcome === want[rec.key],
        `${site}: census row "${rec.key}" expected ${want[rec.key]}, got ${rec.outcome} — ${rec.detail}`);
      // ── THE WIRE READING, ASSERTED (spd-w18-desk-click-latency, crit. 0) ──
      // A reading nobody asserts is a decoration, and this one has a specific
      // way of going quietly blind: if the tap ever stops seeing the socket it
      // returns CANNOT READ for EVERY row, and every sentence it writes stays
      // grammatical. So CANNOT READ is a self-test failure on both sites.
      // Only rows this census actually PRESSED, and only rows whose press is a
      // socket push: `add_btn` / `section_header` are inventoried and never
      // pressed, and `plugin_link` navigates by href. Asserting a wire reading
      // on those would be asserting an instrument against a question they do
      // not pose.
      const wireApplies = rec.presses > 0 && rec.kind !== "plugin_link";
      if (wireApplies) {
        check(
          !(rec.wire === "CANNOT READ" || rec.wire === null),
          `${site}: census row "${rec.key}" came back with NO WIRE READING (${rec.wire}) — ` +
            `the tap saw no /live/websocket socket, so the SENT / NOT SENT distinction was asserted nowhere on this run`,
        );
      }
      // The two verdicts, pinned to the two shapes the fixture builds. Without
      // BOTH of these the instrument could be stuck on one answer and stay green.
      if (wireApplies && site === "rot" && rec.key === SELF_TEST_REFSTUCK_KEY) {
        check(
          rec.wire === "NOT SENT",
          `rot: "${rec.key}" carries data-phx-ref-src, so its press is discarded IN THE BROWSER and the wire ` +
            `must read NOT SENT — it read ${rec.wire}. Either the drop gate stopped firing or the tap counts frames it should not.`,
        );
      }
      if (wireApplies && site === "rot" && rec.outcome === FAIL && rec.key !== SELF_TEST_REFSTUCK_KEY) {
        check(
          rec.wire !== "NOT SENT",
          `rot: "${rec.key}" is dead SERVER-side (the fixture answers it with nothing) and its press does go out, ` +
            `so the wire must read SENT — it read NOT SENT. The tap is not seeing frames the browser sent.`,
        );
      }
      if (wireApplies && site === "good" && rec.outcome === PASS) {
        check(
          rec.wire === "SENT",
          `good: "${rec.key}" ANSWERED, so its press was necessarily on the wire — the wire read ${rec.wire}`,
        );
      }
    }
    const producedKeys = new Set(rows.map((r) => r.key));
    for (const key of Object.keys(want)) {
      check(producedKeys.has(key), `${site}: census row "${key}" is named in SELF_TEST_CENSUS_EXPECT and the run never produced it — the fixture row is gone, or the enumeration stopped seeing its kind`);
    }
  }
  check(exits.good === 0, `good: expected product exit 0, got ${exits.good}`);
  check(exits.rot === 1, `rot: expected product exit 1, got ${exits.rot}`);
  for (const site of Object.keys(SELF_TEST_EXPECT)) {
    const left = residue[site] || [];
    check(left.length === 0, `${site}: the run LEFT LITTER on the dataset — ${left.join(", ")} (the self-clean sweep did not remove what the "+" created)`);
  }

  // ── THE SWEEP PREDICATE, BOTH DIRECTIONS (task-d582be9d064f35dc) ───────────
  // The run's own document proves nothing about the sweep: the self-clean adds
  // it by id whatever the predicate says. These four specimens are the ones that
  // only the predicate can decide, and they are asserted as a PAIR of directions
  // per site — one that must be gone, three that must still be there.
  //
  // MUTATION-PROVEN, both ways, on this tree: delete the `harnessStamped` arm
  // from sweepCandidate and `dead_run` survives and this reds; drop the
  // STALE_DEBRIS_MS guard from stampedAndReclaimable and `live_sibling`
  // disappears and this reds. Neither mutation moves any other assertion, so a
  // green here is about the predicate and not about the fixture.
  for (const site of Object.keys(SELF_TEST_EXPECT)) {
    const seen = survivors[site] || {};
    for (const [name, mustBeSwept] of Object.entries(SWEEP_EXPECT)) {
      const stillThere = seen[name];
      check(
        stillThere === !mustBeSwept,
        mustBeSwept
          ? `${site}: the sweep LEFT ${name} (${SWEEP_SPECIMENS[name]}) — a stamped draft from a run that died ${
              Math.round(STALE_DEBRIS_MS / 60000)}+ minutes ago is the permanent debris this predicate exists to reclaim. ` +
            `A title-keyed sweep cannot select it, which is exactly the defect.`
          : `${site}: the sweep DELETED ${name} (${SWEEP_SPECIMENS[name]}) — it must NOT have. ` +
            `This is a document on a dataset other people use, and a sweep that takes it is worse than no sweep.`,
      );
    }
  }

  // THE FLOOR ITSELF. A run that compared almost nothing must not be allowed to
  // print PASS — that is the whole shape this workflow's scheduled lane had for
  // six weeks. This is the LAST check, so the number it guards is final.
  if (asserted < SELF_TEST_ASSERTION_FLOOR) {
    problems.push(
      `THE SELF-TEST EXECUTED ONLY ${asserted} ASSERTIONS, BELOW THE FLOOR OF ${SELF_TEST_ASSERTION_FLOOR} — ` +
        `a green produced by a run that compared almost nothing is not evidence. Either a whole leg stopped ` +
        `being asserted, or the fixture stopped producing rows. Do not lower the floor to clear this.`,
    );
  }

  if (problems.length) {
    process.stderr.write(
      `\n!! SELF-TEST FAIL — ${asserted} assertions executed; the harness does not behave as specified:\n` +
        problems.map((p) => `   ✗ ${p}\n`).join("") +
        `\n   This is a fault in tooling/studio-journey/journey.mjs itself, NOT in any deployment.\n`,
    );
    return 1;
  }
  process.stdout.write(
    `\nSELF-TEST PASS — ${asserted} assertions executed (floor ${SELF_TEST_ASSERTION_FLOOR}).\n` +
      `  The whole journey is green on /good/ (mint → redeem → admin discriminator →\n` +
      `  desk → create → canvas hydrates → real keystrokes → the API carries the text → it survives a\n` +
      `  reload → self-clean), and RED on /rot/, whose canvas upgrades with a truthy _editor and NEVER\n` +
      `  populates blocks — the exact trap a readiness check on _editor cannot see. Product exits:\n` +
      `  good=0, rot=1. Zero dependencies, no network, no deployment.\n`,
  );
  return 0;
}

async function main() {
  let opts;
  try { opts = parseArgs(process.argv.slice(2)); }
  catch (e) { process.stderr.write(`!! GUARD (exit 2): ${e.message}\n\n${USAGE}`); process.exit(2); }
  if (opts.help) { process.stdout.write(USAGE); process.exit(0); }

  // ENVIRONMENT PREFLIGHT on the GUARD path, before anything is spawned.
  // Capability-tested, not version-parsed: what this needs is the global, and a
  // process.version regex would both lie about a backported build and go stale.
  if (typeof WebSocket === "undefined") {
    process.stderr.write(
      `!! GUARD (exit 2): no global WebSocket in this Node build (running ${process.version}).\n` +
        `   This harness speaks CDP over a native WebSocket, stable-by-default from Node 22.\n` +
        `   THIS IS AN ENVIRONMENT FAILURE, NOT A PRODUCT DEFECT — no page was ever loaded.\n`,
    );
    process.exit(2);
  }

  try {
    if (opts.selfTest || opts.selfTestSite) process.exit(await selfTest(opts));

    const srv = readServer();
    const ctx = { ...srv, dataset: opts.dataset };
    const { ledger, run, wall, pre, post } = await withChrome((cdp) => journeyOne(cdp, ctx, opts));
    process.stdout.write(report(ledger, { base: ctx.base, mode: opts.report ? "REPORT" : "STRICT", wall, pre, post, legs: opts.legs }));
    // THE STAMP, SAID OUT LOUD. A run whose stamp did not land has just created
    // the exact document class task-d582be9d064f35dc exists for, and that must
    // never be a silent fact buried in --json.
    if (run.stamp) {
      process.stdout.write(
        run.stamp.ok
          ? `   provenance stamp: ${STAMP_FIELD}.run_id=${run.stamp.mark.run_id} written to ${run.stamp.id}\n`
          : `   provenance stamp: NOT WRITTEN to ${run.stamp.id ?? "(no id)"} — ${run.stamp.error}. A later run cannot reclaim this document by stamp.\n`,
      );
    }
    if (run.sweep) {
      const sw = run.sweep;
      process.stdout.write(
        `   sweep: ${sw.by_stamp.length} by STAMP${sw.by_stamp.length ? ` [${sw.by_stamp.join(", ")}]` : ""}` +
          ` · ${sw.by_shape.length} by SHAPE+WINDOW${sw.by_shape.length ? ` [${sw.by_shape.join(", ")}]` : ""}` +
          ` · ${sw.stamped_seen.length} stamped draft(s) seen on the host` +
          `${sw.errors.length ? ` · QUERY ERRORS: ${sw.errors.join("; ")}` : ""}\n`,
      );
    }
    if (run.cleanup) {
      const c = run.cleanup;
      process.stdout.write(
        c.skipped
          ? `   self-clean: KEPT ${c.docs.length} draft(s) (--keep): ${c.docs.join(", ") || "none"}\n`
          : `   self-clean: deleted ${c.deleted.length}/${c.docs.length} draft(s)` +
            `${c.deleted.length ? ` [${c.deleted.join(", ")}]` : ""}` +
            `${c.failed.length ? ` · FAILED TO DELETE: ${c.failed.join(", ")} — sweep these by hand` : ""}\n`,
      );
    }
    if (opts.json) process.stdout.write(JSON.stringify(run, null, 2) + "\n");
    if (opts.out) { fs.writeFileSync(opts.out, JSON.stringify(run, null, 2)); process.stdout.write(`   run written to ${opts.out}\n`); }

    // PROVENANCE FIRST, and it is a GUARD. If the served commit moved, beats
    // before the deploy describe one build and beats after it another, and
    // nothing in the ledger says which is which. That is an environment fact.
    if (pre.commit !== post.commit) {
      process.stderr.write(
        `\n!! GUARD (exit 2): SERVED COMMIT MOVED MID-RUN: ${pre.commit} (${pre.read_at}) → ${post.commit} (${post.read_at}).\n` +
          `   A deploy landed inside the measurement window, so this run cannot be attributed to a build.\n` +
          `   No claim is made about the Studio either way. Re-run it.\n`,
      );
      process.exit(2);
    }

    if (ledger.clean) {
      process.stdout.write(
        opts.legs.includes("a")
          ? `\nJOURNEY PASS — a person can create a document, type a heading and a paragraph, and it persists.\n`
          : `\nLEGS ${opts.legs.toUpperCase()} PASS — every gating beat that RAN is green. LEG A did not run, so nothing here claims a person can create a document.\n`,
      );
      process.exit(0);
    }
    const summary = `\nJOURNEY ${ledger.failed.length ? "FAIL" : "UNPROVEN"} — ${ledger.failed.length} gating beats failed, ${ledger.pending.length} unproven.\n`;
    if (opts.report) {
      process.stdout.write(
        summary + `Report mode: exiting 0 on purpose — this run TELLS you what is broken, it does not gate on it.\n` +
          `Re-run without --report once the fix is deployed; that run is the evidence.\n`,
      );
      process.exit(0);
    }
    process.stderr.write(summary + `A beat that is not PASS is not a pass.\n`);
    process.exit(1);
  } catch (e) {
    if (e instanceof Guard) {
      process.stderr.write(
        `\n!! GUARD (exit 2): ${e.message}\n` +
          `   This is an ENVIRONMENT or INVOCATION failure. A transport failure is never a product fact.\n`,
      );
      process.exit(2);
    }
    throw e;
  }
}

// Exported so the transport can be reused by an ad-hoc probe (and so its syntax
// is checkable) WITHOUT running the journey. `main()` fires only when this file
// is the entry point — an unconditional call would make any import spawn Chrome.
export { Cdp, Page, findChrome, withChrome, readServer, mintTicket, servedCommit, readDraft, poll, DESK_PATH, CANVAS_STATE, EDITOR_SHAPE };
// The sweep predicate and its parts, exported so
// tooling/studio-journey/sweep-predicate.test.mjs can drive BOTH arms in BOTH
// directions offline, against the real shapes measured on guerrilla. A
// predicate that deletes documents on a live host and is asserted only by the
// browser self-test is asserted only where a browser is available.
export { sweepCandidate, harnessStamped, stampedAndReclaimable, untitledTemplateShape, STAMP_FIELD, HARNESS_MARK, STALE_DEBRIS_MS, SEEDED_TEMPLATE_BLOCKS };

if (import.meta.url === `file://${process.argv[1]}`) main();
