// journey-smoke.mjs — does the search-starter journey actually WORK in a browser?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (search-template charter D59)
// ─────────────────────────────────────────────────────────────────────────────
//  The Next edition of search-starter had ZERO browser-level coverage of any
//  kind. Every acceptance it ever passed was HTTP-status level (`curl -o
//  /dev/null -w '%{http_code}'`) or source-diff level (`grep` for a selector in
//  a .tsx file). That is exactly how three defects shipped and then sat live and
//  unnoticed for nine days:
//
//    · a red "Search failed." banner at FIRST PAINT (a 200 response, so every
//      status check was green while the page was a red box),
//    · a DEAD live-search websocket (the join-refused path is SILENT by design —
//      use-live-search.ts falls back to HTTP and the DOM looks identical), and
//    · 100% soft-404 detail routes (`/d/zzztype/foo` streamed HTTP 200 with
//      Next's not-found body, so a status assertion could not see it).
//
//  Every one of those is invisible to `curl` and visible in one second to an
//  eye. This file is the eye: it drives a real headless Chrome through the five
//  beats of the journey and asserts what a human would actually check.
//
//  A check that cannot open the artifact it certifies is not a check.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE FIVE BEATS
// ─────────────────────────────────────────────────────────────────────────────
//    LAND    the finder loads: no "Search failed." banner, at least one
//            [data-nav-result] row, and ZERO Runtime.exceptionThrown.
//    TYPE    a real keystroke transitions the result set — AND the live-search
//            websocket is asserted AT THE TRANSPORT, not through the DOM:
//            Network.webSocketCreated fired, a `query` frame was SENT after the
//            keystroke, and a reply frame came back carrying count > 0.
//            THE DOM CANNOT EXPRESS THIS. When the channel join is refused the
//            finder silently serves HTTP results that look pixel-identical
//            (use-live-search.ts:104-112) — so a DOM-only "the results changed"
//            assertion passes green over a completely dead socket. Only the CDP
//            Network domain can tell the two apart.
//    CLICK   clicking the first result reaches a detail page whose
//            `.bp-paper-surface` exists and carries non-empty text, with no new
//            exception. That is the canonical @barkpark/react PortableDoc
//            container — if it is empty, the paper did not render.
//    E404    an unknown route (`/d/zzztype/foo`) returns a REAL HTTP 404.
//            A soft-404 (Next streaming its not-found body with status 200)
//            fails here, which is the whole point.
//    ENGINE  the keystroke leg again with an explicit `?engine=postgres`, so a
//            regression that only breaks the non-default engine is still seen.
//
//  Every beat reports PASS, FAIL or PENDING. PENDING means "could not be
//  proven" — a prerequisite beat failed, so the assertion never ran. PENDING is
//  never a pass: report mode prints it, strict mode refuses it.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node tooling/search-smoke/journey-smoke.mjs --url https://host/sites/slug/
//    node tooling/search-smoke/journey-smoke.mjs --url … --strict   # seal mode
//    node tooling/search-smoke/journey-smoke.mjs --self-test        # no network
//    CHROME=/path/to/chrome node tooling/search-smoke/journey-smoke.mjs --url …
//
//  MODES — one script, two honesties (the tooling/mobile-smoke precedent):
//    report (default)  prints the per-beat verdict and exits 0 EVEN ON FAIL.
//                      This is the during-the-deploy-window instrument: it says
//                      out loud what is broken without reddening a pipeline that
//                      is knowingly mid-fix. The scheduled CI run uses it, and
//                      its output IS the rot alarm.
//    --strict          exits 1 unless every beat PASSED. This is the wave-seal
//                      instrument: the evidence that the journey is whole.
//
//  EXIT CODES — the 1/2 split is load-bearing, inherited verbatim from
//  cssom-parity.mjs D19:
//    0  every beat passed (or report mode, which never fails on content)
//    1  a beat FAILED (or is unproven) under --strict — a fact about the SITE
//    2  GUARD — a fact about the ENVIRONMENT or the invocation (no Chrome, no
//       Node-22 WebSocket, no --url, an unknown flag), refused BEFORE Chrome is
//       ever spawned. A misconfigured runner must never red a PR with a message
//       that reads like a site defect, and a mistyped flag must never pass green.
//
//  ZERO DEPENDENCIES. Node 22 native `fetch` + native `WebSocket` speak the
//  Chrome DevTools Protocol directly to `--headless=new`. No puppeteer, no
//  playwright, no browser download — CI uses ubuntu-latest's preinstalled
//  /usr/bin/google-chrome. The transport, the teardown and the guard doctrine
//  are lifted from cloud/priv/static/__preview__/cssom-parity.mjs, which has
//  been CI-proven on that runner.
//
//  TEARDOWN — nothing here EVER blocks on the Chrome child. A blocking `wait`
//  on a Chrome that ignores SIGTERM is a measured multi-hour stall on this host.
//  CDP Browser.close raced against a cap, then `kill -0` polling with a cap,
//  then SIGKILL with a further cap, then a SHOUT on stderr naming the pid.
//  Chrome takes --remote-debugging-port=0 and reports its own port through the
//  profile dir, so concurrent runs can never collide.
//
//  --self-test IS THE MUTATION PROOF. It boots a local zero-dependency fixture
//  server (node:http plus a hand-rolled RFC-6455 websocket — no `ws` package)
//  serving THREE sites from one process:
//    · /good/  — a healthy miniature of the finder: search input, result rows,
//                a live socket that answers a `query` frame with count > 0, a
//                detail page with a non-empty .bp-paper-surface, real 404s.
//    · /rot/   — the SAME page carrying the shipped defects: the red "Search
//                failed." banner, zero result rows, and a soft-404 that
//                streams 200.
//    · /mute/  — the NASTY one: it lands, types and re-renders its results
//                perfectly, with NO websocket at all. A DOM-only harness passes
//                it green. This fixture is what proves the transport assertion
//                is load-bearing rather than decorative.
//  The self-test asserts the harness reports ALL PASS on /good/ AND the exact
//  expected FAIL/PENDING pattern on /rot/ and /mute/. A check whose red has
//  never been demonstrated is not a check — so the red is demonstrated on every
//  single run, offline, with no network and no deployed site.
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import crypto from "node:crypto";
import { spawn } from "node:child_process";

// ── caps (ms) ────────────────────────────────────────────────────────────────
const DEVTOOLS_CAP = 15000; // Chrome writing DevToolsActivePort
const NAV_CAP = 30000; // a navigation settling
const SETTLE_CAP = 12000; // a DOM predicate becoming true
const WS_CAP = 8000; // a websocket reply frame arriving
const FETCH_CAP = 15000; // the plain-HTTP 404 probe
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const DEFAULT_QUERY = "search";
const DEFAULT_ENGINE = "postgres";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ─────────────────────────────────────────────────────────────────────────────
//  argv — an UNKNOWN FLAG IS A GUARD, never a silent green
// ─────────────────────────────────────────────────────────────────────────────
// A typo'd `--stict` that ran in report mode and exited 0 would certify a broken
// site as fine. Same doctrine as the roster guard in cssom-parity.mjs: refuse
// the invocation before anything is spawned.
function parseArgs(argv) {
  const opts = {
    url: process.env.SMOKE_URL || null,
    strict: false,
    selfTest: false,
    query: process.env.SMOKE_QUERY || DEFAULT_QUERY,
    engine: process.env.SMOKE_ENGINE || DEFAULT_ENGINE,
    json: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v == null) throw new Error(`flag ${a} needs a value`);
      return v;
    };
    switch (a) {
      case "--url": opts.url = value(); break;
      case "--strict": opts.strict = true; break;
      case "--self-test": opts.selfTest = true; break;
      case "--query": opts.query = value(); break;
      case "--engine": opts.engine = value(); break;
      case "--json": opts.json = true; break;
      case "--help":
      case "-h": opts.help = true; break;
      default: throw new Error(`unknown flag ${a}`);
    }
  }
  return opts;
}

const USAGE = `journey-smoke — browser proof of the search-starter journey

  node tooling/search-smoke/journey-smoke.mjs --url <base> [--strict] [--json]
  node tooling/search-smoke/journey-smoke.mjs --self-test

  --url <base>    the deployed site root, e.g. https://host/sites/search-ember/
  --strict        exit 1 unless every beat PASSED (report mode always exits 0)
  --self-test     run the five beats against a local fixture, twice: a healthy
                  site (expect all PASS) and a rotten one (expect the FAILs)
  --query <q>     the query typed in the TYPE/ENGINE beats (default "search")
  --engine <e>    the explicit engine for the ENGINE beat (default "postgres")
  --json          emit a machine-readable result object after the report

  exit 0 clean · 1 beat failure under --strict · 2 environment/usage guard
`;

// ─────────────────────────────────────────────────────────────────────────────
//  the CDP client — cssom-parity.mjs's, plus EVENT routing (this file needs the
//  Network + Runtime event stream, which a request/response-only client drops)
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
  if (process.env.CHROME) return process.env.CHROME;
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
    this.wsCreated = [];
    this.framesSent = [];
    this.framesReceived = [];
  }

  static async open(cdp) {
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    const page = new Page(cdp, sessionId);
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Runtime.enable", {}, sessionId);
    // Network.enable is what makes the WS beat possible at all — the websocket
    // lifecycle and every frame in both directions arrive as events here, with
    // no cooperation from (and no visibility to) the page's own JavaScript.
    await cdp.send("Network.enable", {}, sessionId);
    cdp.on("Runtime.exceptionThrown", (p) => {
      const d = p.exceptionDetails || {};
      page.exceptions.push(d.exception?.description || d.text || "(unknown exception)");
    });
    cdp.on("Network.webSocketCreated", (p) => page.wsCreated.push(p.url || ""));
    cdp.on("Network.webSocketFrameSent", (p) => page.framesSent.push(p.response?.payloadData ?? ""));
    cdp.on("Network.webSocketFrameReceived", (p) => page.framesReceived.push(p.response?.payloadData ?? ""));
    return page;
  }

  async goto(url) {
    const loaded = new Promise((resolve) => {
      const done = () => resolve(true);
      this.cdp.on("Page.loadEventFired", done);
      setTimeout(() => resolve(false), NAV_CAP);
    });
    await this.cdp.send("Page.navigate", { url }, this.sid);
    await loaded;
  }

  /** Evaluate an expression in the page and return its by-value result.
   *  A page-thrown exception is returned as `{ __throw: text }` rather than
   *  raised: a broken page must produce a FAILED BEAT, never a crashed harness
   *  that reports nothing about the other four. */
  async evaluate(expression) {
    const r = await this.cdp.send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      this.sid,
    );
    if (r.exceptionDetails) return { __throw: r.exceptionDetails.text || "evaluate threw" };
    return r.result?.value;
  }

  /** Poll a page expression until it is truthy, or the cap elapses. */
  async waitFor(expression, cap = SETTLE_CAP) {
    const deadline = Date.now() + cap;
    for (;;) {
      const v = await this.evaluate(expression);
      if (v && !v.__throw) return v;
      if (Date.now() >= deadline) return null;
      await sleep(150);
    }
  }

  async focus(selector) {
    return this.evaluate(
      `(function(){var el=document.querySelector(${JSON.stringify(selector)});` +
        `if(!el)return false;el.focus();return document.activeElement===el;})()`,
    );
  }

  /** Type through the INPUT domain, one char at a time, exactly as a keyboard
   *  does. Not `el.value = …`: React's controlled input ignores a direct value
   *  write (no synthetic change event), so a value-poke would prove nothing
   *  about the real typing path — the very path the TYPE beat exists to test. */
  async type(text) {
    for (const ch of text) {
      await this.cdp.send("Input.dispatchKeyEvent", { type: "keyDown", text: ch, unmodifiedText: ch, key: ch }, this.sid);
      await this.cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: ch }, this.sid);
      await sleep(40);
    }
  }

  /** A real mouse press/release at the element's centre — the click path the
   *  user takes, including whatever hover/focus handlers ride along. */
  async click(selector) {
    const box = await this.evaluate(
      `(function(){var el=document.querySelector(${JSON.stringify(selector)});if(!el)return null;` +
        `var r=el.getBoundingClientRect();if(!r.width||!r.height)return null;` +
        `el.scrollIntoView({block:"center"});r=el.getBoundingClientRect();` +
        `return {x:r.left+r.width/2,y:r.top+r.height/2};})()`,
    );
    if (!box || box.__throw) return false;
    const common = { x: Math.round(box.x), y: Math.round(box.y), button: "left", clickCount: 1 };
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...common }, this.sid);
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ...common }, this.sid);
    await this.cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...common }, this.sid);
    return true;
  }

  /** Everything the WS listeners have seen so far — snapshotted so a beat can
   *  reason about "frames that arrived AFTER the keystroke", which is the only
   *  ordering that proves the keystroke caused the frame. */
  wsMark() {
    return { sent: this.framesSent.length, received: this.framesReceived.length, created: this.wsCreated.length };
  }

  wsSince(mark) {
    return {
      created: this.wsCreated.slice(mark.created),
      sent: this.framesSent.slice(mark.sent),
      received: this.framesReceived.slice(mark.received),
    };
  }

  exceptionMark() { return this.exceptions.length; }
  exceptionsSince(mark) { return this.exceptions.slice(mark); }
}

// ─────────────────────────────────────────────────────────────────────────────
//  websocket frame reading — Phoenix v2 arrays, v1 objects, and anything else
// ─────────────────────────────────────────────────────────────────────────────
// The Phoenix v2 serializer puts a channel message on the wire as
//   [join_ref, ref, topic, event, payload]
// and v1 as {topic, event, payload, ref}. Both are handled; an unrecognised
// shape falls back to a text scan so a serializer change degrades to a weaker
// assertion rather than a false red.
function frameEvent(text) {
  try {
    const v = JSON.parse(text);
    if (Array.isArray(v) && v.length >= 5) return String(v[3] ?? "");
    if (v && typeof v === "object" && typeof v.event === "string") return v.event;
  } catch { /* not JSON — fall through */ }
  return null;
}

function framePayload(text) {
  try {
    const v = JSON.parse(text);
    if (Array.isArray(v) && v.length >= 5) return v[4];
    if (v && typeof v === "object") return v.payload;
  } catch { /* not JSON */ }
  return null;
}

/** Dig a hit COUNT out of a reply frame. Phoenix wraps a channel reply as
 *  {status:"ok", response:{…}} and the search envelope carries `count`; a bare
 *  envelope is accepted too. The regex is the last resort, never the first. */
function frameCount(text) {
  const p = framePayload(text);
  const candidates = [p?.response, p, p?.response?.response];
  for (const c of candidates) {
    if (c && typeof c === "object") {
      if (typeof c.count === "number") return c.count;
      if (typeof c.total === "number") return c.total;
    }
  }
  const m = /"(?:count|total)"\s*:\s*(\d+)/.exec(text || "");
  return m ? Number(m[1]) : null;
}

const isQuerySend = (text) => frameEvent(text) === "query" || /"query"/.test(text || "");

// ─────────────────────────────────────────────────────────────────────────────
//  the beat ledger
// ─────────────────────────────────────────────────────────────────────────────
const PASS = "PASS", FAIL = "FAIL", PENDING = "PENDING";

class Ledger {
  constructor() { this.beats = []; }
  add(name, status, detail, checks = []) {
    this.beats.push({ name, status, detail, checks });
    return status;
  }
  get(name) { return this.beats.find((b) => b.name === name); }
  statuses() { return Object.fromEntries(this.beats.map((b) => [b.name, b.status])); }
  get failed() { return this.beats.filter((b) => b.status === FAIL); }
  get pending() { return this.beats.filter((b) => b.status === PENDING); }
  get clean() { return this.beats.every((b) => b.status === PASS); }
}

/** A beat is the AND of its checks; PENDING beats FAIL beats PASS when a
 *  prerequisite never ran, because "unproven" and "broken" are different facts
 *  and collapsing them is how a smoke test starts lying. */
function rollup(checks) {
  if (checks.some((c) => c.status === FAIL)) return FAIL;
  if (checks.some((c) => c.status === PENDING)) return PENDING;
  return PASS;
}

const check = (label, status, note = "") => ({ label, status, note });

// ─────────────────────────────────────────────────────────────────────────────
//  the journey
// ─────────────────────────────────────────────────────────────────────────────

const joinUrl = (base, tail) => base.replace(/\/+$/, "") + "/" + tail.replace(/^\/+/, "");

const COUNT_RESULTS = `document.querySelectorAll("[data-nav-result]").length`;
// The banner is a plain <section> with a <strong>Search failed.</strong> inside;
// there is no data-attribute to key on, so the assertion reads the text exactly
// as a human does. Keep this string in sync with finder.tsx's banner copy.
const BANNER_PRESENT = `!!Array.from(document.querySelectorAll("section")).find(function(s){return /Search failed\\./.test(s.textContent||"")})`;
// A stable signature of the current result set: change here == the list moved.
const RESULT_SIGNATURE =
  `Array.from(document.querySelectorAll("[data-nav-result]")).slice(0,8)` +
  `.map(function(e){return (e.textContent||"").slice(0,60)}).join("|")`;

async function runJourney(page, base, opts, ledger) {
  // ── BEAT 1 · LAND ──────────────────────────────────────────────────────────
  await page.goto(base);
  await page.waitFor(`${COUNT_RESULTS} > 0`, SETTLE_CAP);
  const landBanner = await page.evaluate(BANNER_PRESENT);
  const landCount = await page.evaluate(COUNT_RESULTS);
  const landExceptions = page.exceptionsSince(0);
  const landChecks = [
    check("no \"Search failed.\" banner", landBanner === false ? PASS : FAIL,
      landBanner === true ? "the red first-paint banner is on the page" : landBanner?.__throw || ""),
    check("[data-nav-result] rows > 0", typeof landCount === "number" && landCount > 0 ? PASS : FAIL,
      `rows=${typeof landCount === "number" ? landCount : "?"}`),
    check("zero Runtime.exceptionThrown", landExceptions.length === 0 ? PASS : FAIL,
      landExceptions.slice(0, 3).join(" · ")),
  ];
  ledger.add("LAND", rollup(landChecks), base, landChecks);
  const landed = typeof landCount === "number" && landCount > 0;

  // ── BEAT 2 · TYPE (DOM transition + the TRANSPORT-level WS proof) ──────────
  const typeChecks = await typeLeg(page, opts.query, landed, { engine: null });
  ledger.add("TYPE", rollup(typeChecks), `q="${opts.query}"`, typeChecks);

  // ── BEAT 3 · CLICK ─────────────────────────────────────────────────────────
  let clickChecks;
  if (!landed) {
    clickChecks = [check("first result opens a paper", PENDING, "no result rows to click — LAND failed")];
  } else {
    const exMark = page.exceptionMark();
    const clicked = await page.click("[data-nav-result]");
    if (!clicked) {
      clickChecks = [check("first result opens a paper", FAIL, "the first [data-nav-result] has no clickable box")];
    } else {
      const surface = await page.waitFor(
        `(function(){var el=document.querySelector(".bp-paper-surface");` +
          `return el ? (el.textContent||"").trim().length : 0;})()`,
        SETTLE_CAP,
      );
      const len = typeof surface === "number" ? surface : 0;
      const newEx = page.exceptionsSince(exMark);
      clickChecks = [
        check(".bp-paper-surface present and non-empty", len > 0 ? PASS : FAIL,
          len > 0 ? `${len} chars of rendered PortableDoc` : "no .bp-paper-surface with text after the click"),
        check("no new exception during navigation", newEx.length === 0 ? PASS : FAIL, newEx.slice(0, 2).join(" · ")),
      ];
    }
  }
  ledger.add("CLICK", rollup(clickChecks), "first result → detail", clickChecks);

  // ── BEAT 4 · E404 ──────────────────────────────────────────────────────────
  // Deliberately a PLAIN fetch, not a navigation: the assertion is about the
  // HTTP STATUS LINE, and a browser navigation renders a soft-404 body exactly
  // like a hard one. This is the beat that catches Next streaming a 200.
  const probe = joinUrl(base, "d/zzztype/foo");
  let status = null, netErr = null;
  try {
    const res = await fetch(probe, { redirect: "follow", signal: AbortSignal.timeout(FETCH_CAP) });
    status = res.status;
    await res.arrayBuffer().catch(() => {});
  } catch (e) { netErr = e?.message || String(e); }
  const e404Checks = [
    check("unknown route returns HTTP 404", status === 404 ? PASS : FAIL,
      netErr ? `fetch failed: ${netErr}` : `${probe} → ${status}${status === 200 ? " (SOFT-404: a 200 carrying a not-found body)" : ""}`),
  ];
  ledger.add("E404", rollup(e404Checks), probe, e404Checks);

  // ── BEAT 5 · ENGINE ────────────────────────────────────────────────────────
  // The default-engine leg already ran as TYPE; this is the EXPLICIT one. A
  // regression that only breaks `?engine=postgres` is otherwise invisible.
  const engineUrl = `${base.replace(/\/+$/, "")}/?engine=${encodeURIComponent(opts.engine)}`;
  await page.goto(engineUrl);
  const engineLanded = await page.waitFor(`${COUNT_RESULTS} > 0`, SETTLE_CAP);
  const engineChecks = engineLanded
    ? await typeLeg(page, opts.query, true, { engine: opts.engine })
    : [check(`engine=${opts.engine} lands with results`, FAIL, `no [data-nav-result] rows at ${engineUrl}`)];
  ledger.add("ENGINE", rollup(engineChecks), engineUrl, engineChecks);
}

/** The keystroke leg: focus, type, assert the DOM moved, and assert the SOCKET
 *  carried it. Shared by TYPE and ENGINE so the two legs can never drift. */
async function typeLeg(page, query, landed, { engine }) {
  const tag = engine ? ` (engine=${engine})` : "";
  if (!landed) {
    return [
      check(`keystroke transitions the result set${tag}`, PENDING, "the finder never landed"),
      check(`websocket carries the query${tag}`, PENDING, "the finder never landed"),
    ];
  }
  const before = await page.evaluate(RESULT_SIGNATURE);
  const mark = page.wsMark();
  const focused = await page.focus("#finder-search, input[type=search]");
  if (focused !== true) {
    return [
      check(`keystroke transitions the result set${tag}`, FAIL, "no focusable search input on the page"),
      check(`websocket carries the query${tag}`, PENDING, "nothing was typed"),
    ];
  }
  await page.type(query);

  // The DOM half. The finder debounces, so this polls rather than samples.
  const moved = await page.waitFor(
    `(function(){var sig=${RESULT_SIGNATURE};return sig !== ${JSON.stringify(before)} ? (sig||"(empty)") : null;})()`,
    SETTLE_CAP,
  );

  // The TRANSPORT half — the assertion the DOM cannot make. Wait for a reply
  // frame rather than sampling once: a live socket answers in tens of ms, a
  // dead one never answers at all, and the difference is the whole beat.
  const deadline = Date.now() + WS_CAP;
  let sentQuery = null, reply = null, replyCount = null;
  for (;;) {
    const since = page.wsSince(mark);
    sentQuery = since.sent.find(isQuerySend) ?? null;
    for (const f of since.received) {
      const c = frameCount(f);
      if (c != null) { reply = f; replyCount = c; break; }
    }
    if (sentQuery && reply) break;
    if (Date.now() >= deadline) break;
    await sleep(150);
  }
  const created = page.wsCreated.length > 0;

  const wsNote = !created
    ? "NO websocket was ever created — the finder is on the silent HTTP fallback (use-live-search.ts:104-112)"
    : !sentQuery
      ? "a socket exists but NO `query` frame was sent after the keystroke"
      : replyCount == null
        ? "the query frame was sent but NO reply frame carried a count"
        : replyCount > 0
          ? `webSocketCreated ✓ · query frame sent ✓ · reply count=${replyCount}`
          : `reply arrived with count=${replyCount} — the socket is live but the topic is empty (wrong dataset?)`;

  return [
    check(`keystroke transitions the result set${tag}`, moved ? PASS : FAIL,
      moved ? String(moved).slice(0, 70) : "the result list never changed after typing"),
    check(`websocket carries the query${tag}`,
      created && sentQuery && replyCount != null && replyCount > 0 ? PASS : FAIL, wsNote),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
//  the fixture server (--self-test) — zero dependencies, including the socket
// ─────────────────────────────────────────────────────────────────────────────
// A hand-rolled RFC-6455 server is ~60 lines and buys the thing that matters:
// the self-test exercises the REAL transport assertions (webSocketCreated,
// frame sent, frame received with a count) rather than a mock of them. Only
// text frames, no fragmentation, no compression — everything this fixture
// needs, and nothing it does not.
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function wsAccept(key) {
  return crypto.createHash("sha1").update(key + WS_GUID).digest("base64");
}

function wsEncodeText(str) {
  const body = Buffer.from(str, "utf8");
  const len = body.length;
  let head;
  if (len < 126) head = Buffer.from([0x81, len]);
  else if (len < 65536) { head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(len, 2); }
  else { head = Buffer.alloc(10); head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(len), 2); }
  return Buffer.concat([head, body]);
}

/** Decode whole client text frames out of a buffer; returns [texts, rest]. */
function wsDecode(buf) {
  const out = [];
  let off = 0;
  for (;;) {
    if (buf.length - off < 2) break;
    const b0 = buf[off], b1 = buf[off + 1];
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let p = off + 2;
    if (len === 126) { if (buf.length - p < 2) break; len = buf.readUInt16BE(p); p += 2; }
    else if (len === 127) { if (buf.length - p < 8) break; len = Number(buf.readBigUInt64BE(p)); p += 8; }
    let mask = null;
    if (masked) { if (buf.length - p < 4) break; mask = buf.subarray(p, p + 4); p += 4; }
    if (buf.length - p < len) break;
    const payload = Buffer.from(buf.subarray(p, p + len));
    if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    if (opcode === 0x1) out.push(payload.toString("utf8"));
    off = p + len;
  }
  return [out, buf.subarray(off)];
}

const FIXTURE_ROWS = ["Mechanical spacing doctrine", "Search template charter", "PortableDoc block wishlist"];

function fixtureFinderPage({ mode, base }) {
  const rotten = mode === "rot";
  const rows = rotten
    ? ""
    : FIXTURE_ROWS.map((t, i) => `<a data-nav-result="" href="${base}d/paper/doc-${i}">${t}</a>`).join("\n");
  const banner = rotten ? `<section><strong>Search failed.</strong><pre>indx 404</pre></section>` : "";
  // THE BLIND SPOT UNDER TEST: `mute` renders rows and re-renders them on every
  // keystroke — a perfect DOM transition — with NO websocket at all. It is the
  // silent HTTP fallback, pixel-identical to a healthy finder. Any DOM-only
  // smoke test passes it green. Only the transport assertion sees it.
  const live = rotten
    ? ""
    : mode === "mute"
      ? `<script>
        document.getElementById("finder-search").addEventListener("input", function (e) {
          var q = e.target.value.toLowerCase();
          var hits = ${JSON.stringify(FIXTURE_ROWS)}.filter(function (t) { return t.toLowerCase().indexOf(q) !== -1; });
          document.getElementById("results").innerHTML = hits
            .map(function (h, i) { return '<a data-nav-result="" href="${base}d/paper/hit-' + i + '">' + h + '</a>'; })
            .join("");
        });
      </script>`
      : `<script>
        var ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/socket/websocket");
        var seq = 0;
        ws.onmessage = function (ev) {
          var msg = JSON.parse(ev.data);
          var hits = (msg[4] && msg[4].response && msg[4].response.documents) || [];
          document.getElementById("results").innerHTML = hits
            .map(function (h, i) { return '<a data-nav-result="" href="${base}d/paper/hit-' + i + '">' + h + '</a>'; })
            .join("");
        };
        document.getElementById("finder-search").addEventListener("input", function (e) {
          if (ws.readyState !== 1) return;
          ws.send(JSON.stringify(["1", String(++seq), "search:default:default:production", "query", { q: e.target.value, seq: seq }]));
        });
      </script>`;
  return `<!doctype html><meta charset="utf-8"><title>fixture finder</title>
<body>
  <input id="finder-search" type="search" aria-label="Search documents">
  ${banner}
  <div id="results">${rows}</div>
  ${live}
</body>`;
}

const FIXTURE_DETAIL = `<!doctype html><meta charset="utf-8"><title>fixture detail</title>
<body><article class="bp-paper-surface"><h1>Mechanical spacing doctrine</h1>
<p>Vertical rhythm in Papers is content, not style.</p></article></body>`;

function startFixture() {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const p = url.pathname;
    const send = (code, body, type = "text/html; charset=utf-8") =>
      res.writeHead(code, { "content-type": type, "cache-control": "no-store" }).end(body);

    for (const mode of ["good", "rot", "mute"]) {
      const prefix = `/${mode}/`;
      if (!p.startsWith(prefix)) continue;
      const rest = p.slice(prefix.length);
      if (rest === "") return send(200, fixtureFinderPage({ mode, base: prefix }));
      if (rest.startsWith("d/paper/")) return send(200, FIXTURE_DETAIL);
      // THE DEFECT UNDER TEST: the rotten site answers an unknown route with a
      // 200 carrying a not-found body — byte-for-byte the soft-404 that shipped.
      if (mode === "rot") return send(200, "<!doctype html><body><h1>Not found</h1></body>");
      return send(404, "<!doctype html><body><h1>404</h1></body>");
    }
    return send(404, "not a fixture route", "text/plain");
  });

  server.on("upgrade", (req, socket) => {
    const key = req.headers["sec-websocket-key"];
    if (!key) return socket.destroy();
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${wsAccept(key)}\r\n\r\n`,
    );
    let buf = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      let texts;
      [texts, buf] = wsDecode(buf);
      for (const text of texts) {
        let msg;
        try { msg = JSON.parse(text); } catch { continue; }
        if (!Array.isArray(msg) || msg[3] !== "query") continue;
        const q = String(msg[4]?.q ?? "");
        const documents = FIXTURE_ROWS.filter((t) => t.toLowerCase().includes(q.toLowerCase()));
        socket.write(wsEncodeText(JSON.stringify([
          msg[0], msg[1], msg[2], "phx_reply",
          { status: "ok", response: { documents, count: documents.length, query: q } },
        ])));
      }
    });
    socket.on("error", () => { /* the harness tore the tab down */ });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port }));
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  reporting
// ─────────────────────────────────────────────────────────────────────────────
const MARK = { [PASS]: "✓", [FAIL]: "✗", [PENDING]: "·" };

function report(ledger, { base, strict, wall }) {
  const lines = [`\n   ${strict ? "STRICT" : "REPORT"}  ${base}\n`];
  for (const beat of ledger.beats) {
    lines.push(`   ${MARK[beat.status]} ${beat.status.padEnd(7)} ${beat.name.padEnd(7)} ${beat.detail}`);
    for (const c of beat.checks) {
      lines.push(`               ${MARK[c.status]} ${c.label}${c.note ? ` — ${c.note}` : ""}`);
    }
  }
  lines.push(`\n   ${ledger.beats.filter((b) => b.status === PASS).length}/${ledger.beats.length} beats PASS · ${(wall / 1000).toFixed(1)}s wall`);
  return lines.join("\n") + "\n";
}

// ─────────────────────────────────────────────────────────────────────────────
//  the run
// ─────────────────────────────────────────────────────────────────────────────
async function withChrome(fn) {
  const chromeBin = findChrome();
  if (!chromeBin) {
    process.stderr.write("!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n");
    process.exit(2);
  }
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "journey-smoke-"));
  let chrome = null, cdp = null;

  const teardown = async () => {
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    const alive = (p) => { if (!p || p.pid == null) return false; try { process.kill(p.pid, 0); return true; } catch { return false; } };
    if (alive(chrome)) {
      try { chrome.kill("SIGTERM"); } catch { /* gone */ }
      let waited = 0;
      while (alive(chrome) && waited < TERM_POLL_CAP) { await sleep(50); waited += 50; }
      if (alive(chrome)) {
        try { chrome.kill("SIGKILL"); } catch { /* gone */ }
        waited = 0;
        while (alive(chrome) && waited < KILL_POLL_CAP) { await sleep(50); waited += 50; }
        if (alive(chrome)) {
          process.stderr.write(
            `!! TEARDOWN SHOUT: chrome pid ${chrome.pid} SURVIVED SIGKILL after ${KILL_POLL_CAP}ms. ` +
              `Reap it by hand: kill -9 ${chrome.pid}\n`,
          );
        }
      }
    }
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
  };

  try {
    chrome = spawn(
      chromeBin,
      [
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-background-networking",
        "--window-size=1400,1000",
        `--user-data-dir=${profile}`,
        "--remote-debugging-port=0",
        "about:blank",
      ],
      { stdio: "ignore" },
    );

    const portFile = path.join(profile, "DevToolsActivePort");
    let devPort = null;
    for (let w = 0; w < DEVTOOLS_CAP; w += 100) {
      try {
        const raw = fs.readFileSync(portFile, "utf8").split("\n");
        if (raw[0] && Number(raw[0])) { devPort = Number(raw[0]); break; }
      } catch { /* not written yet */ }
      await sleep(100);
    }
    if (!devPort) throw new Error("Chrome never wrote DevToolsActivePort — it did not start");

    const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    process.stdout.write(`>> chrome  ${chromeBin}\n>> build   ${version.Browser} · node ${process.version}\n`);
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);
    return await fn(cdp);
  } finally {
    await teardown();
  }
}

async function smokeOne(cdp, base, opts) {
  const page = await Page.open(cdp);
  const ledger = new Ledger();
  const t0 = Date.now();
  try {
    await runJourney(page, base, opts, ledger);
  } catch (err) {
    // A harness-side throw must still produce a ledger: the beats that already
    // ran keep their verdicts, and the rest are honestly unproven.
    ledger.add("HARNESS", FAIL, `journey aborted: ${err?.message || err}`, []);
  }
  const wall = Date.now() - t0;
  try { await cdp.send("Target.closeTarget", { targetId: (await cdp.send("Target.getTargetInfo", {}, page.sid)).targetInfo.targetId }); } catch { /* the browser teardown gets it */ }
  return { ledger, wall };
}

// ── --self-test: green on a healthy fixture, RED on the rotten one ───────────
// THREE fixtures, because a smoke test is only worth its RED. `good` proves the
// green is reachable; `rot` proves the three shipped defects are caught; `mute`
// proves the one defect a DOM-only harness is blind to — a finder that lands,
// types and re-renders perfectly over a DEAD socket.
const SELF_TEST_EXPECT = {
  good: { LAND: PASS, TYPE: PASS, CLICK: PASS, E404: PASS, ENGINE: PASS },
  rot: { LAND: FAIL, TYPE: PENDING, CLICK: PENDING, E404: FAIL, ENGINE: FAIL },
  mute: { LAND: PASS, TYPE: FAIL, CLICK: PASS, E404: PASS, ENGINE: FAIL },
};

async function selfTest(opts) {
  const { server, port } = await startFixture();
  const results = {};
  try {
    await withChrome(async (cdp) => {
      for (const site of Object.keys(SELF_TEST_EXPECT)) {
        const base = `http://127.0.0.1:${port}/${site}/`;
        // The fixture's live socket answers a substring match, so the typed
        // query must actually hit a row — otherwise "count > 0" would fail for
        // a reason that has nothing to do with the transport.
        const r = await smokeOne(cdp, base, { ...opts, query: "doctrine" });
        process.stdout.write(report(r.ledger, { base, strict: false, wall: r.wall }));
        results[site] = r.ledger.statuses();
      }
    });
  } finally {
    server.close();
  }

  const problems = [];
  for (const [site, expected] of Object.entries(SELF_TEST_EXPECT)) {
    for (const [beat, want] of Object.entries(expected)) {
      const got = results[site]?.[beat];
      if (got !== want) problems.push(`${site}/${beat}: expected ${want}, got ${got ?? "(missing)"}`);
    }
  }

  if (problems.length) {
    process.stderr.write(
      `\n!! SELF-TEST FAIL — the harness does not behave as specified:\n` +
        problems.map((p) => `   ✗ ${p}\n`).join("") +
        `\n   This is a fault in journey-smoke.mjs itself, NOT in any deployed site.\n`,
    );
    return 1;
  }
  process.stdout.write(
    `\nSELF-TEST PASS — five beats green on /good/, the shipped defects caught on /rot/ (banner +\n` +
      `  zero rows + soft-404), and the DOM-blind defect caught on /mute/ (lands, types, re-renders\n` +
      `  perfectly over a DEAD socket → TYPE and ENGINE red). Every beat's RED is demonstrated, not\n` +
      `  assumed. Transport: native fetch + native WebSocket, zero npm dependencies, no network.\n`,
  );
  return 0;
}

async function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`!! GUARD (exit 2): ${e.message}\n\n${USAGE}`);
    process.exit(2);
  }
  if (opts.help) { process.stdout.write(USAGE); process.exit(0); }

  // ENVIRONMENT PREFLIGHT, on the GUARD path, before anything is spawned
  // (cssom-parity.mjs D19). Capability-tested, not version-parsed: what this
  // instrument needs is the global, and a process.version regex would both lie
  // about a backported build and go stale.
  if (typeof WebSocket === "undefined") {
    process.stderr.write(
      `!! GUARD (exit 2): no global WebSocket in this Node build (running ${process.version}).\n` +
        `   This harness speaks CDP over a native WebSocket, stable-by-default from Node 22.\n` +
        `   THIS IS AN ENVIRONMENT FAILURE, NOT A SITE DEFECT — no page was ever loaded and no\n` +
        `   claim is being made about the deployment. Fix the runtime: node-version: 22.\n`,
    );
    process.exit(2);
  }
  if (!opts.selfTest && !opts.url) {
    process.stderr.write(`!! GUARD (exit 2): --url <base> is required (or --self-test).\n\n${USAGE}`);
    process.exit(2);
  }
  if (opts.url) {
    try { new URL(opts.url); }
    catch { process.stderr.write(`!! GUARD (exit 2): --url ${opts.url} is not a URL.\n`); process.exit(2); }
  }

  if (opts.selfTest) process.exit(await selfTest(opts));

  const base = opts.url.endsWith("/") ? opts.url : opts.url + "/";
  const { ledger, wall } = await withChrome((cdp) => smokeOne(cdp, base, opts));
  process.stdout.write(report(ledger, { base, strict: opts.strict, wall }));
  if (opts.json) process.stdout.write(JSON.stringify({ base, strict: opts.strict, beats: ledger.beats }, null, 2) + "\n");

  if (ledger.clean) {
    process.stdout.write(`\nJOURNEY PASS — all five beats green.\n`);
    process.exit(0);
  }
  const summary =
    `\nJOURNEY ${ledger.failed.length ? "FAIL" : "UNPROVEN"} — ` +
    `${ledger.failed.length} failed, ${ledger.pending.length} unproven.\n`;
  if (opts.strict) {
    // PENDING is refused here too, deliberately. Strict mode is the seal
    // evidence, and "we could not prove it" is not "it works".
    process.stderr.write(summary + `Strict mode: a beat that is not PASS is not a pass.\n`);
    process.exit(1);
  }
  process.stdout.write(
    summary + `Report mode: exiting 0 on purpose — this run TELLS you what is broken, it does not\n` +
      `gate on it. Re-run with --strict once the fix is deployed; that run is the evidence.\n`,
  );
  process.exit(0);
}

main();
