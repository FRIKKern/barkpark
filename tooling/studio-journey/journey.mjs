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
// THE DEFAULT IS 150s, NOT THE 90s THIS SLICE WAS BRIEFED WITH, and the number
// is measured rather than chosen. 90s was derived from a /rot/ pass of ~41s over
// a paper-only roster. This roster is four row KINDS plus a decoy and the row it
// spawns, and an UNANSWERED row costs a measured 16.2s (uniform across four of
// them: 16.2 / 16.2 / 16.3 / 16.4) against a nominal 2 × 3.0s row cap — the
// overshoot is in the click and probe round trips, not in the wait loop, which is
// clock-checked before every evaluate. /rot/ therefore needs ~125s and truncated
// at 90s with two rows still UNMEASURED, which is honest and useless. Tightening
// this back makes the expected verdicts load-dependent, which is the failure the
// brief's own reasoning warns about; LEG_C_BUDGET_MS moves it either way.
const LEG_C_BUDGET = Number(process.env.LEG_C_BUDGET_MS || 150000);
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
  if (!/^[abc]+$/.test(opts.legs) || new Set(opts.legs).size !== opts.legs.length) {
    throw new Error(`--legs wants some subset of "abc", each letter at most once (got "${opts.legs}")`);
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
  --legs <abc>        run only these legs (default abc). \`--legs c\` is the
                      desk-row census ALONE: it never creates a document, so it
                      is the mode for a shared/production host. When a runs, it
                      establishes the session; when it does not, a minimal AUTH
                      beat mints the same ticket and asserts the same admin
                      discriminator first — a census of an anonymous desk is not
                      a census of the desk.

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
    const box = await this.evaluate(
      `(function(){var el=document.querySelector(${JSON.stringify(selector)});if(!el)return null;` +
        `el.scrollIntoView({block:"center"});var r=el.getBoundingClientRect();` +
        `if(!r.width||!r.height)return null;` +
        `return {x:r.left+r.width/2,y:r.top+r.height/2};})()`,
    );
    if (!box || box.__throw) return false;
    const common = { x: Math.round(box.x), y: Math.round(box.y), button: "left", clickCount: 1 };
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...common }, this.sid);
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...common }, this.sid);
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...common }, this.sid);
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

/** Every draft of `type` created at or after `sinceIso`, newest first.
 *  THIS EXISTS BECAUSE THE "+" CAN CREATE WITHOUT NAVIGATING. Measured on
 *  guerrilla 4f046cce1: pressing "+" inserted a real `Untitled` draft and the URL
 *  never moved to it, so the URL-derived id was null while documents piled up —
 *  three per run, once clickUntil started retrying. An instrument that leaks a
 *  draft on every failed run is worse than no instrument, so cleanup is keyed off
 *  what the DATASET gained during the leg, not off what the URL admitted to.
 *
 *  BOUNDED BY SHAPE, NOT ONLY BY TIME (review, spd-w18). The window is a real
 *  dataset on a real host, so "everything created since I pressed +" can in
 *  principle name a document a HUMAN created in the same seconds — and this
 *  function's caller DELETES what it returns. So a candidate must also still
 *  look like the thing the "+" makes and nobody has touched: no title of its
 *  own, and no more blocks than the seeded template (`tpl-title` + `tpl-body`).
 *  A document with a title or with authored content is NEVER a sweep candidate,
 *  whatever its timestamp says. The typed document is added by the caller from
 *  `run.created_doc_id`, so narrowing here cannot orphan the run's own paper.
 *  Residual risk, stated rather than hidden: an empty untitled draft created by
 *  someone else inside the same few seconds would still be swept. Use `--keep`
 *  on a busy host. */
const SEEDED_TEMPLATE_BLOCKS = 2;

function sweepCandidate(d, since) {
  if (!d?._draft || Date.parse(d._createdAt || 0) < since) return false;
  const title = (d.title ?? "").trim();
  if (title !== "" && title.toLowerCase() !== "untitled") return false;
  const blocks = d.blocks ?? d.content?.blocks ?? [];
  return Array.isArray(blocks) && blocks.length <= SEEDED_TEMPLATE_BLOCKS;
}

async function draftsCreatedSince(ctx, type, sinceIso) {
  const q = new URLSearchParams({ perspective: "drafts", limit: "50", order: "_createdAt:desc" });
  const r = await api(ctx, `${ctx.base}/v1/data/query/${encodeURIComponent(ctx.dataset)}/${encodeURIComponent(type)}?${q}`, { method: "GET" });
  if (!r.ok) return { ok: false, error: r.error, ids: [] };
  const docs = r.body?.result?.documents || [];
  const since = Date.parse(sinceIso);
  const ids = docs.filter((d) => sweepCandidate(d, since)).map((d) => d._id);
  return { ok: true, ids };
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
      const rec = { ...r, enum_url: c.full_url || null, outcome: null, witness: null, detail: null, presses: 0, waited_ms: 0, recovered: false };
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
  const selfId = rec.kind === "collapsed_strip" ? rec.id : null;
  const locate = await page.evaluate(censusProbe(rec.key, selfId));
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
  const before = await page.evaluate(witnessExpr);
  if (!before || before.__throw) {
    return { status: PENDING, witness: "none", presses: 0, waited: Date.now() - t0,
      detail: `the page would not answer a witness probe for this row — ${UNMEASURED}` };
  }
  let after = before, won = null, presses = 0, landed = false, ranOut = false;
  for (let attempt = 1; attempt <= LEG_C_PRESS_ATTEMPTS && !won; attempt++) {
    if (Date.now() >= deadline) { ranOut = true; break; }
    presses = attempt;
    let sel = pressSelectorFor(rec);
    if (!sel) {
      const loc = attempt === 1 ? locate : await page.evaluate(censusProbe(rec.key, selfId));
      sel = loc && !loc.__throw ? loc.press_selector : null;
    }
    if (!sel) break;
    landed = (await page.click(sel)) || landed;
    // THE HARD BOUND, and it is why this does not call `poll()`: poll checks its
    // cap AFTER the predicate has run, so its overshoot is as long as one
    // predicate takes — measured 8.1s against a 3.0s cap on a loaded host, which
    // walked LEG C 5s PAST its 90s budget. Here the clock is checked BEFORE every
    // evaluate, so the budget holds to within one round trip.
    const until = Date.now() + Math.max(400, Math.min(LEG_C_ROW_CAP, deadline - Date.now()));
    for (;;) {
      const now = await page.evaluate(witnessExpr);
      if (now && !now.__throw) {
        after = now;
        const w = identityWitness(rec, before, now);
        if (w) { won = w; break; }
      }
      if (Date.now() >= deadline) { ranOut = true; break; }
      if (Date.now() >= until) break;
      await pause(POLL_TICK); // the poll tick — not a wait for anything in particular
    }
  }
  const waited = Date.now() - t0;
  // THE COUNTS ARE IN THE RECORD AND THEY DECIDE NOTHING. They are the drift a
  // snapshot diff used to call an answer, which is how the dead #item-sheet was
  // credited with its neighbour's URL 900 ms later.
  const drift =
    `counts(recorded, non-deciding): panes ${before.panes}→${after.panes} · ` +
    `.pane-item ${before.item_rows}→${after.item_rows} · .pane-doc-item ${before.doc_rows}→${after.doc_rows} · ` +
    `url ${before.url} → ${after.url}`;
  if (won) {
    return { status: PASS, witness: `IDENTITY: ${won}`, presses, waited,
      detail: `answered in ${ms(waited)} after ${presses} press(es) · ${drift}` };
  }
  // THE BUDGET IS NOT A VERDICT. A row whose measurement was cut off mid-flight
  // is UNMEASURED, never dead: converting an exhausted runner budget into a dead
  // row fabricates a defect, which is the failure mode this whole epic exists to
  // stop.
  if (ranOut) {
    return { status: PENDING, witness: "none", presses, waited,
      detail: `the ${ms(LEG_C_BUDGET)} LEG_C_BUDGET ran out WHILE this row was being measured (${presses} press(es), ${ms(waited)}) — ${UNMEASURED} · ${drift}` };
  }
  if (!landed) {
    return { status: FAIL, witness: "none", presses, waited,
      detail: `NO PRESS EVER LANDED on it in ${ms(waited)} (${presses} attempt(s)) — the element had no layout box to click, so it is on the page and cannot be pointed at · ${drift}` };
  }
  const unavailable =
    rec.kind === "plugin_link"
      ? `it has no phx-value-id and no aria-current — an anchor's ONLY witness is its own href (${rec.href || "(no href!)"})`
      : rec.kind === "collapsed_strip"
        ? `witness = #${rec.id || "(NO ID — nothing can name this strip; only the strip COUNT could move, and a count cannot name a row)"} losing .pane-column--collapsed`
        : `aria-current ${isCurrent(before.aria_current) ? `was ALREADY "${before.aria_current}" before the press, so that witness was unavailable and only the URL could name this row` : `stayed ${after.aria_current === null ? "absent" : `"${after.aria_current}"`}`}, and the URL never carried ${rec.phx_value_id ? `"${rec.phx_value_id}"` : "(this row has NO phx-value-id)"} as a path segment`;
  return { status: FAIL, witness: "none", presses, waited,
    detail: `NOTHING NAMED THIS ROW after ${presses} press(es) in ${ms(waited)}: ${unavailable} · ${drift} — whatever moved above, no effect claimed THIS row, so it is DEAD as far as any observer can tell` +
      ` · READ IT AS "no witness within ${ms(LEG_C_ROW_CAP)}": measured answer latency on this seam runs 1.6s to never-within-15s, so against a LIVE host this row is either dead or slower than the cap, and LEG_C_ROW_CAP_MS raises the cap` };
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
  // full 16s of dead-row cap (2 presses × the 3s LEG_C_ROW_CAP, plus probes) and
  // buys no red that the first row does not already buy. Three of them ran /rot/
  // to 128.5s of its 150s LEG_C_BUDGET — a fixture that truncates reds this
  // self-test, so the margin is the point.
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
${rows.map((r) => `<button type="button" class="pane-item" id="${r.id}" phx-click="select" phx-value-id="${r.value}" phx-value-pane="0"><span class="pane-item-label">${r.label}</span></button>`).join("\n")}
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
      const all = [...docs.values()].sort((a, b) => Date.parse(b._createdAt) - Date.parse(a._createdAt));
      return json(200, { result: { perspective: "drafts", limit: 50, offset: 0, count: all.length, documents: all } });
    }
    if (rest.startsWith("/v1/data/mutate/") && req.method === "POST") {
      let body = "";
      req.on("data", (c) => { body += c; });
      req.on("end", () => {
        let ids = [];
        try { ids = (JSON.parse(body).mutations || []).map((x) => x.delete?.id).filter(Boolean); } catch { /* report below */ }
        for (const id of ids) { docs.delete(id); docs.delete(`drafts.${id}`); }
        json(200, { results: ids.map((id) => ({ id, operation: "delete" })) });
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
    const swept = await draftsCreatedSince(ctx, "paper", run.create_pressed_at);
    const ids = new Set(swept.ids);
    if (run.created_doc_id) ids.add(`drafts.${run.created_doc_id}`);
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

const SELF_TEST_EXPECT = {
  good: withFossils({ AUTH: PASS, DESK: PASS, CREATE: PASS, HYDRATE: PASS, TYPE: PASS, PERSIST: PASS, RELOAD: PASS, CENSUS: PASS }, PASS),
  rot: withFossils({ AUTH: PASS, DESK: PASS, CREATE: PASS, HYDRATE: FAIL, TYPE: PENDING, PERSIST: PENDING, RELOAD: PENDING, CENSUS: FAIL }, FAIL),
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

async function selfTest(opts) {
  const { server, port, store } = await startFixture();
  const results = {}, exits = {}, residue = {}, censuses = {};
  const sites = opts.selfTestSite ? [opts.selfTestSite] : Object.keys(SELF_TEST_EXPECT);
  try {
    await withChrome(async (cdp) => {
      for (const site of sites) {
        const base = `http://127.0.0.1:${port}/${site}`;
        const ctx = { base, token: FIXTURE_TOKEN, dataset: opts.dataset };
        const r = await journeyOne(cdp, ctx, opts);
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
        residue[site] = [...store[site].keys()].filter((k) => !FOSSILS.some((f) => f.draftId === k));
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
  for (const [site, expected] of Object.entries(SELF_TEST_EXPECT)) {
    for (const [beat, want] of Object.entries(expected)) {
      const got = results[site]?.[beat];
      if (got !== want) problems.push(`${site}/${beat}: expected ${want}, got ${got ?? "(missing)"}`);
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
      if (Object.prototype.hasOwnProperty.call(SELF_TEST_EXPECT[site] || {}, beat)) continue;
      problems.push(
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
    if (!rows.length) { problems.push(`${site}: LEG C produced NO census rows at all — a census of nothing is not a census`); continue; }
    if (censuses[site]?.truncated) {
      problems.push(
        `${site}: LEG C hit its ${LEG_C_BUDGET}ms LEG_C_BUDGET on the FIXTURE, which is a few local rows — ` +
          `the row verdicts below are load-dependent and this self-test cannot assert them. Raise LEG_C_BUDGET_MS or run on a quieter host.`,
      );
    }
    for (const rec of rows) {
      if (!Object.prototype.hasOwnProperty.call(want, rec.key)) {
        problems.push(
          `${site}: LEG C CENSUSED A ROW NOBODY NAMED — "${rec.key}" came back ${rec.outcome}. ` +
            `Name it in SELF_TEST_CENSUS_EXPECT or an unasserted row can never red.`,
        );
        continue;
      }
      if (rec.outcome !== want[rec.key]) {
        problems.push(`${site}: census row "${rec.key}" expected ${want[rec.key]}, got ${rec.outcome} — ${rec.detail}`);
      }
    }
    const producedKeys = new Set(rows.map((r) => r.key));
    for (const key of Object.keys(want)) {
      if (!producedKeys.has(key)) {
        problems.push(`${site}: census row "${key}" is named in SELF_TEST_CENSUS_EXPECT and the run never produced it — the fixture row is gone, or the enumeration stopped seeing its kind`);
      }
    }
  }
  if (exits.good !== 0) problems.push(`good: expected product exit 0, got ${exits.good}`);
  if (exits.rot !== 1) problems.push(`rot: expected product exit 1, got ${exits.rot}`);
  for (const site of Object.keys(SELF_TEST_EXPECT)) {
    const left = residue[site] || [];
    if (left.length) problems.push(`${site}: the run LEFT LITTER on the dataset — ${left.join(", ")} (the self-clean sweep did not remove what the "+" created)`);
  }

  if (problems.length) {
    process.stderr.write(
      `\n!! SELF-TEST FAIL — the harness does not behave as specified:\n` +
        problems.map((p) => `   ✗ ${p}\n`).join("") +
        `\n   This is a fault in tooling/studio-journey/journey.mjs itself, NOT in any deployment.\n`,
    );
    return 1;
  }
  process.stdout.write(
    `\nSELF-TEST PASS — the whole journey is green on /good/ (mint → redeem → admin discriminator →\n` +
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

if (import.meta.url === `file://${process.argv[1]}`) main();
