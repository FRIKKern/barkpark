#!/usr/bin/env node
// overflow-guard.mjs — the browser-geometry guard the seal predicate's clause
// (b) shells out to (seal-predicate.mjs → `node overflow-guard.mjs --defect
// <id>`). A missing or failing run here is NO SEAL, never a pass.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS IS A BROWSER MEASUREMENT AND NOT A SOURCE REGEX (GR118)
// ─────────────────────────────────────────────────────────────────────────────
//  The predicate's first draft asserted GR108 as "does a .topbar rule exist
//  inside the 768 block" — the charter's THEORY of the cause. Dry-run both
//  directions it was EXACTLY INVERTED: it printed DEFECT against the correct
//  fix (0/44 overflow) and CLEAN against the broken one (14/16 still
//  overflowing). __app.test.mjs is text-based and passed 640/640 on BOTH
//  patches; cssom-parity.mjs asks whether a selector REACHED the CSSOM, and a
//  cascade-dead rule is present in the CSSOM — it just loses. So the dead-rule
//  class had NO coverage from any instrument in this epic. A source regex
//  tests a story about the pixels; only a browser tests the pixels. This file
//  loads the real SPA through serve.mjs, renders it in headless Chrome, and
//  asserts computed style and geometry.
//
//  THE SWEEP GOES ABOVE 768 OR IT CANNOT FAIL (GR116): the broken band reaches
//  ~782 — 769px measured 775.22 light / 776.92 dark pre-fix — so a sweep that
//  stops at the breakpoint goes green while a live scrollbar sits one pixel
//  above it (measured 13/44 failures once the sweep extended past 768).
//
//  THE THREE DEFECTS IT MEASURES
//    GR108-tablet-topbar-overflow   page-level horizontal overflow at
//        721-1440 x 2 themes x 2 past-due scenarios (44 checks), plus the
//        cosmetic half: the past-due billing chip must NOT be truncated at
//        768 — the unconditional min-width:0 pair alone clips the money
//        message, and shipping it without the 768-block trio trades a
//        scrollbar for a truncated "Payment failed · fix billing".
//    GR109-attention-row-dead-rule  at 768 the stacked .attention-row must
//        compute align-items:flex-start with .attention-acts left-aligned to
//        .attention-main (pre-fix: stacked but CENTRED, acts left 441.28).
//        At 900 the row must still be a row (the stack stays scoped <=768).
//    W12-narrow-viewport-truth      PHONE WIDTHS, which every other case here
//        is blind to (WIDTHS starts at 721 — see the honest limit below). Two
//        halves: (a) the page body must not scroll at 320-620 on #overview —
//        pre-fix 496/390 at a 390px viewport, a 106px overhang on every phone
//        in portrait, because a bare `1fr` mobile track floors at the CARD's
//        min-content (480.203px); (b) the notifications channel matrix must
//        TELL a person it continues past the edge — at 390 three of six
//        channels are fully off-screen at scrollLeft 0, and the OS scrollbar
//        is not the fallback (the reserved track measures 0px even in a
//        CLASSIC-scrollbar run). The cue is asserted to appear ONLY while
//        clipped: at 1440 the matrix fits and the fade must read 0px.
//    W13-detail-route-band          THE ROUTES, which every case above is
//        blind to: GR108 sweeps the 721-1440 band but drives only
//        billing-past-due / overview-past-due, and W12 only mixed-fleet
//        #overview and notif-configured#notifications — so no instrument in
//        this epic had ever driven a DETAIL route at any width. Driven on
//        origin/main bytes, five detail routes plus #fleet scrolled the page
//        sideways at 769-899 (panel-overview scrollWidth pinned 837 against a
//        769 viewport, rollback 838, site-states 861): 56 of 286 cells. This
//        leg drives instance-detail / inst-timeline / inst-metrics /
//        site-rollback / site-states / #fleet across 721-1024 in both themes
//        and asserts BOTH that the page does not scroll AND that the route
//        asked for is the route that rendered — the second half is not
//        ceremony, see the routing trap below.
//    GR115-bpconsole-dead-rule      at 700x800 .bp-console-body must compute
//        the authored 40vh cap (320px) and the 13px legibility floor, same
//        for .bp-console-toggle (pre-fix: 260px/12px/12px — the later base
//        rules discarded the media block's declarations at equal
//        specificity). Includes the .bp-console.is-collapsed twin control.
//
// ─────────────────────────────────────────────────────────────────────────────
//  EVIDENCE HYGIENE, EACH PROVEN LIVE THIS EPIC (GR125)
// ─────────────────────────────────────────────────────────────────────────────
//  (a) SERVED BYTES == DISK BYTES, asserted before anything is measured. A
//      preview server from a FOREIGN worktree once squatted the port and
//      served the primary checkout's origin/main bytes, making a patched run
//      print baseline output. 20 worktrees share this checkout. On mismatch
//      this guard exits non-zero naming the stale server — it never measures
//      the wrong tree silently.
//  (b) Network.setCacheDisabled — Chrome memory-caches app.css across
//      same-URL navigations; without this a mutation phase measures the
//      ORIGINAL stylesheet and reports a false "did not flip".
//  (d) A ROUTE IS NOT A QUERY STRING (W13). `?scen=rollback` alone renders
//      #overview: scenarios.mjs's deepLink is consumed by the CALLER
//      (smoke.mjs:372, shoot.sh:118), never applied by mock.js. A sweep that
//      omits the hash prints a full, plausible table in which every "detail
//      route" is the overview screen. W13 appends the hash itself and asserts
//      the visible section.view id (plus the active .inst-tab, because the
//      three instance routes share one section) in EVERY cell.
//  (c) The GR115 fixture is injected by SELECTOR-built DOM, and mutations to
//      app.css (in the proofs) are selector-anchored — .new-console-body and
//      .bp-console-body are byte-identical declaration blocks, so a plain
//      string replace patches the wrong twin.
//
//  RUN
//    node cloud/priv/static/__preview__/overflow-guard.mjs                 # all four
//    node cloud/priv/static/__preview__/overflow-guard.mjs --defect GR108-tablet-topbar-overflow
//    OVERFLOW_GUARD_PORT=4321 node …                                      # port override
//    CHROME=/path/to/chrome node …
//    OVERFLOW_GUARD_CLASSIC_SCROLLBARS=1 node …                           # drop --hide-scrollbars
//
//  THE CLASSIC-SCROLLBAR SWITCH is a DIAGNOSTIC, not a mode to run the whole
//  file in: with real scrollbars clientWidth no longer equals the emulated
//  width, which is the parity GR108's sweep is written against. It exists so
//  W12's "the OS scrollbar is not the affordance" claim can be measured in the
//  condition it is about — a browser that reserves a classic track — instead of
//  asserted from a run that hid scrollbars in the first place. W12's cue must
//  read identically under both, and the run prints the reserved track width it
//  measured either way.
//
//  HONEST LIMIT — THIS FILE IS RUN BY NO WORKFLOW (charter D109, re-confirmed
//  this wave: `grep -rn overflow-guard .github/` returns nothing, exit 1). It
//  is a developer tripwire and the seal predicate's shell-out, NOT a CI gate.
//  That is exactly how a tree whose body scrolled 106px at 390px passed every
//  required context: nothing measured below 700px, and nothing ran this file.
//
//  Exit codes: 0 = every requested defect measured fixed · 1 = a DEFECT WAS
//  MEASURED and is still present · 2 = REFUSED to measure (no/unusable Chrome,
//  unknown --defect, no server, a stale/squatted server, CDP bring-up failed,
//  the probe threw). 1 is a claim about the CSS; 2 is a claim about the
//  environment, and the two must never be confused under a required context.
//
//  ZERO DEPENDENCIES — Node 22 native fetch + native WebSocket speak CDP
//  directly (the Cdp class is cssom-parity.mjs's, unchanged). Teardown is
//  hand-bounded exactly like cssom-parity's: nothing here ever blocks on a
//  child process without a cap.
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, ".."); // cloud/priv/static
const PORT = Number(process.env.OVERFLOW_GUARD_PORT || 4199);
const BASE = `http://127.0.0.1:${PORT}`;

const DEFECTS = [
  "GR108-tablet-topbar-overflow",
  "GR109-attention-row-dead-rule",
  "GR115-bpconsole-dead-rule",
  "W12-narrow-viewport-truth",
  "W13-detail-route-band",
];

// W13-S4: the tablet band NOTHING in this file had ever driven a DETAIL ROUTE
// at. 769 and 899 are the two edges of the band; 900 and 1024 are the controls
// above it; 721/768 are below it and prove the fix did not disturb the phone
// and small-tablet shapes GR65/GR116 own.
const BAND_WIDTHS = [721, 768, 769, 790, 830, 860, 899, 900, 1024];

// The six routes. `view` is the section.view that MUST be visible: `?scen=` on
// its own does NOT route (deepLink is applied by the CALLER — smoke.mjs:372,
// shoot.sh:118 — never by mock.js), so a sweep without the hash renders
// #overview six times and prints a plausible, entirely phantom table. The hash
// is appended here AND the landed view is asserted per cell. `tab` additionally
// pins WHICH instance sub-tab landed, because all three instance routes share
// the single #view-instance section.
const INST = "5b2c1e00-0000-4000-8000-0000000000a1";
const SITE = "5b2c1e00-0000-4000-8000-0000000000c1";
const BAND_ROUTES = [
  { name: "instance-detail", scen: "panel-overview", hash: `#instance/${INST}`, view: "view-instance", tab: "Overview", ready: ".detail-grid--instance" },
  { name: "inst-timeline", scen: "timeline", hash: `#instance/${INST}/timeline`, view: "view-instance", tab: "Timeline", ready: "#instance-tabpanel" },
  { name: "inst-metrics", scen: "metrics", hash: `#instance/${INST}/metrics`, view: "view-instance", tab: "Metrics", ready: "#instance-tabpanel" },
  { name: "site-rollback", scen: "rollback", hash: `#site/${SITE}`, view: "view-site", tab: null, ready: ".detail-grid" },
  { name: "site-states", scen: "site-states", hash: `#site/${SITE}`, view: "view-site", tab: null, ready: ".detail-grid" },
  { name: "fleet", scen: "mixed-fleet", hash: "#fleet", view: "view-fleet", tab: null, ready: ".fleet-row" },
];

// W14-S3 RETIRED THE ONE PIN THIS LEG USED TO CARRY. #fleet's 21px overhang at
// 769 was the residual W13 named rather than skipped (FLEET_ROW_RESIDUAL, max
// 21px, cch-w13-fleet-row-band-769-785); its remedy — `.fleet-row`'s stack —
// moved from the 768 block into the 899 block, the band [769,789] measured 0
// offending cells on mixed-fleet AND fleet-v4 in both themes, and the pin,
// its skip branch and its summary sentence went with it. #fleet is now
// asserted like every other route: no exemption, 108/108.

// The sweep envelope. 769/775/780/785 are ABOVE the breakpoint on purpose —
// see the header: a sweep capped at 768 cannot fail on this defect class.
const WIDTHS = [721, 750, 768, 769, 775, 780, 785, 800, 900, 1024, 1440];
// W12: the band NOTHING in this file used to look at. 495/496 straddle the
// measured threshold (overflowed at <=495, clean at >=496 pre-fix), so a run
// that goes green here has crossed the bisection point rather than missed it.
const PHONE_WIDTHS = [320, 360, 375, 390, 412, 430, 480, 495, 496, 620];
const HEIGHT = 800;
const CLASSIC_SCROLLBARS = process.env.OVERFLOW_GUARD_CLASSIC_SCROLLBARS === "1";

const SERVER_CAP = 8000;
const DEVTOOLS_CAP = 15000;
const RENDER_CAP = 12000;
const EVAL_CAP = 10000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── args ─────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
let only = null;
const di = argv.indexOf("--defect");
if (di !== -1) {
  only = argv[di + 1];
  if (!DEFECTS.includes(only)) {
    process.stderr.write(
      `!! GUARD (exit 2): unknown --defect "${only}". Known: ${DEFECTS.join(", ")}\n`,
    );
    process.exit(2);
  }
}
const requested = only ? [only] : DEFECTS;

// ── chrome discovery (cssom-parity.mjs's, unchanged) ─────────────────────────
// The accessSync check MUST cover the CHROME env branch, not only the candidate
// sweep. .github/workflows/console-harness.yml pins CHROME=/usr/bin/google-chrome
// for every console run, so on CI the env branch is the ONLY branch taken — an
// unchecked `return process.env.CHROME` makes the exit-2 "no Chrome" GUARD below
// dead code, and a runner image that drops the binary dies instead with a raw
// `spawn … ENOENT` node stack at exit 1. Exit 1 means "a measured overflow";
// a missing browser is an ENVIRONMENTAL REFUSAL and must speak as exit 2.
function findChrome() {
  if (process.env.CHROME) {
    try {
      fs.accessSync(process.env.CHROME, fs.constants.X_OK);
      return process.env.CHROME;
    } catch {
      return null; // fall through to the exit-2 GUARD naming the missing path
    }
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

// The refusal line for a findChrome() miss — names the path that was pinned and
// not found, so a runner-image regression reads as "this binary is gone", never
// as an anonymous red.
function chromeGuardLine() {
  return process.env.CHROME
    ? `!! GUARD (exit 2): CHROME=${process.env.CHROME} is not an executable file. Environment refusal, not an overflow defect.\n`
    : "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n";
}

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

// ── the run ──────────────────────────────────────────────────────────────────
async function main() {
  const chromeBin = findChrome();
  if (!chromeBin) {
    process.stderr.write(chromeGuardLine());
    process.exit(2);
  }

  // 1. Serve the tree. If the port is already held, our child dies with
  //    EADDRINUSE — that is fine IF AND ONLY IF whoever holds it serves this
  //    tree's exact bytes; the assertion below decides, never the spawn.
  const serveChild = spawn("node", [path.join(HERE, "serve.mjs"), "--port", String(PORT)], {
    stdio: "ignore",
  });

  let chrome = null;
  let cdp = null;
  const alive = (p) => { if (!p || p.pid == null) return false; try { process.kill(p.pid, 0); return true; } catch { return false; } };

  const reap = async (p) => {
    if (!alive(p)) return;
    try { p.kill("SIGTERM"); } catch { /* gone */ }
    let waited = 0;
    while (alive(p) && waited < TERM_POLL_CAP) { await sleep(50); waited += 50; }
    if (alive(p)) {
      try { p.kill("SIGKILL"); } catch { /* gone */ }
      waited = 0;
      while (alive(p) && waited < KILL_POLL_CAP) { await sleep(50); waited += 50; }
      if (alive(p)) process.stderr.write(`!! TEARDOWN SHOUT: pid ${p.pid} SURVIVED SIGKILL. Reap it by hand: kill -9 ${p.pid}\n`);
    }
  };

  let profile = null;
  const teardown = async () => {
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    await reap(chrome);
    await reap(serveChild);
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
  };

  // Default 2 = REFUSED TO MEASURE (environment fault), not 1 = a measured
  // overflow defect. Every current call site is environmental — server never
  // came up, a foreign tree squats the port, Chrome never started, CDP failed,
  // the evaluate threw — so all six take this default deliberately. A future
  // site that IS a measured defect must pass 1 explicitly and say why.
  const die = async (msg, code = 2) => {
    await teardown();
    process.stderr.write(`\n!! OVERFLOW GUARD: ${msg}\n`);
    process.exit(code);
  };

  // Wait for SOMETHING to answer on the port (ours or a squatter's).
  let up = false;
  for (let w = 0; w < SERVER_CAP; w += 100) {
    try { const r = await fetch(`${BASE}/app.css`, { cache: "no-store" }); if (r.ok) { up = true; break; } } catch { /* not yet */ }
    await sleep(100);
  }
  // AUDITED (exit 2): the local static server never came up. Environment, not CSS.
  if (!up) return die(`no server answered on :${PORT} within ${SERVER_CAP}ms`);

  // 2. SERVED BYTES == DISK BYTES (GR125a). Compared for every file the
  //    measurement depends on, plus the injected shell "/" against the same
  //    injection serve.mjs performs — so a squatter serving a different
  //    index.html is caught too, not only a different stylesheet.
  const fetchBytes = async (p) => Buffer.from(await (await fetch(`${BASE}${p}`, { cache: "no-store" })).arrayBuffer());
  for (const rel of ["/app.css", "/app.js", "/__preview__/mock.js", "/__preview__/scenarios.mjs"]) {
    const served = await fetchBytes(rel);
    const disk = fs.readFileSync(path.join(ROOT, rel.slice(1)));
    if (!served.equals(disk)) {
      // AUDITED (exit 2): a foreign tree squats the port — we refuse to measure
      // bytes we did not author. Nothing about this tree's CSS has been judged.
      return die(
        `STALE SERVER on :${PORT} — ${rel} served ${served.length} B, disk holds ${disk.length} B.\n` +
        `   A server rooted at a DIFFERENT tree (a foreign worktree?) is squatting this port.\n` +
        `   Measuring against it would certify the wrong bytes — refusing.`,
      );
    }
  }
  {
    const shell = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
    const APP_TAG = '<script src="/app.js"></script>';
    const expected = shell.includes(APP_TAG)
      ? shell.replace(APP_TAG, '<script src="/__preview__/mock.js"></script>\n    ' + APP_TAG)
      : shell;
    const served = (await fetchBytes("/")).toString("utf8");
    if (served !== expected) {
      // AUDITED (exit 2): same squatter refusal, on the injected shell.
      return die(`STALE SERVER on :${PORT} — the injected shell "/" does not match this tree's index.html.`);
    }
  }
  process.stdout.write(`>> serve      :${PORT} — served bytes == disk bytes (app.css, app.js, mock.js, scenarios.mjs, shell)\n`);

  // 3. Chrome.
  profile = fs.mkdtempSync(path.join(os.tmpdir(), "overflow-guard-"));
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
      // classic-macOS overlay parity: clientWidth == emulated width. Dropped
      // only under OVERFLOW_GUARD_CLASSIC_SCROLLBARS=1 (see the header).
      ...(CLASSIC_SCROLLBARS ? [] : ["--hide-scrollbars"]),
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
  // AUDITED (exit 2): the browser never started. Environment, not CSS.
  if (!devPort) return die("Chrome never wrote DevToolsActivePort — it did not start");

  let sessionId;
  try {
    const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    process.stdout.write(`>> chrome     ${version.Browser} · node ${process.version}\n`);
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    ({ sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true }));
    await cdp.send("Runtime.enable", {}, sessionId);
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Network.enable", {}, sessionId);
    // GR125(b): Chrome memory-caches app.css across same-URL navigations —
    // without this, a mutated stylesheet measures as the original.
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true }, sessionId);
  } catch (err) {
    // AUDITED (exit 2): the debugger transport failed before any measurement ran.
    return die(`CDP bring-up failed: ${err.message}`);
  }

  const evalJs = async (expression) => {
    const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true }, sessionId);
    if (r.exceptionDetails) throw new Error("page eval threw: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
    return r.result.value;
  };

  const setViewport = (width, height = HEIGHT) =>
    cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false }, sessionId);

  // Navigate and poll until `readyExpr` is truthy (the SPA mounts async).
  const nav = async (url, readyExpr) => {
    await cdp.send("Page.navigate", { url }, sessionId);
    for (let w = 0; w < RENDER_CAP; w += 100) {
      try { if (await evalJs(`!!(${readyExpr})`)) return; } catch { /* navigating */ }
      await sleep(100);
    }
    throw new Error(`page never became ready: ${url} (waited on: ${readyExpr})`);
  };

  const failures = [];
  const fail = (defect, msg) => { failures.push({ defect, msg }); process.stdout.write(`   ✗ ${msg}\n`); };
  const okLine = (msg) => process.stdout.write(`   ✓ ${msg}\n`);

  try {
    // ── GR108: page-level overflow sweep + the chip's money message ─────────
    if (requested.includes("GR108-tablet-topbar-overflow")) {
      process.stdout.write(`\nGR108-tablet-topbar-overflow — ${WIDTHS.length} widths x 2 themes x 2 scenarios\n`);
      let checks = 0, offenders = 0;
      for (const scen of ["billing-past-due", "overview-past-due"]) {
        for (const theme of ["light", "dark"]) {
          await setViewport(768);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}`,
            `document.querySelector('.topbar') && (function(){var c=document.getElementById('billing-chip');return c && !c.hidden;})()`,
          );
          const row = [];
          for (const width of WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;` +
              `return {sw:d.scrollWidth, cw:d.clientWidth, theme:d.getAttribute('data-theme')};})()`,
            );
            checks++;
            const over = m.sw > m.cw;
            if (over) { offenders++; fail("GR108-tablet-topbar-overflow", `${scen}/${theme}@${width}: scrollWidth ${m.sw} > viewport ${m.cw} — horizontal scrollbar`); }
            row.push(`${width}:${m.sw}${over ? "!" : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join(" ")}\n`);

          // Cosmetic half at the breakpoint: the past-due money message must be
          // whole at 768 — correctness-only clips it to ~154.61 of ~169.78px.
          await setViewport(768);
          const chip = await evalJs(
            `(function(){var c=document.getElementById('billing-chip');if(!c)return null;` +
            `var r=c.getBoundingClientRect();` +
            `return {sw:c.scrollWidth, cw:c.clientWidth, w:Math.round(r.width*100)/100, text:c.textContent};})()`,
          );
          if (!chip) fail("GR108-tablet-topbar-overflow", `${scen}/${theme}@768: #billing-chip missing`);
          else if (chip.sw > chip.cw + 1) fail("GR108-tablet-topbar-overflow", `${scen}/${theme}@768: billing chip TRUNCATED — scrollWidth ${chip.sw} > clientWidth ${chip.cw} (rect ${chip.w}px, "${chip.text}")`);
          else okLine(`${scen}/${theme}@768: chip whole — ${chip.w}px, scrollWidth ${chip.sw} <= clientWidth ${chip.cw} ("${chip.text}")`);
        }
      }
      if (!failures.some((f) => f.defect === "GR108-tablet-topbar-overflow")) {
        okLine(`0/${checks} overflowing across ${WIDTHS[0]}-${WIDTHS[WIDTHS.length - 1]} (sweep includes 769/775/780/785 — ABOVE the breakpoint)`);
      }
    }

    // ── GR109: the stacked attention row is left-aligned, not centred ───────
    if (requested.includes("GR109-attention-row-dead-rule")) {
      process.stdout.write(`\nGR109-attention-row-dead-rule — overview-past-due attention queue\n`);
      await setViewport(768);
      await nav(`${BASE}/?scen=overview-past-due&theme=light`, `document.querySelector('.attention-row .attention-acts')`);
      const m = await evalJs(
        `(function(){var row=document.querySelector('.attention-row');var cs=getComputedStyle(row);` +
        `var main=row.querySelector('.attention-main').getBoundingClientRect();` +
        `var acts=row.querySelector('.attention-acts').getBoundingClientRect();` +
        `return {dir:cs.flexDirection, align:cs.alignItems,` +
        ` mainLeft:Math.round(main.left*100)/100, actsLeft:Math.round(acts.left*100)/100};})()`,
      );
      if (m.dir !== "column") fail("GR109-attention-row-dead-rule", `@768 flex-direction is "${m.dir}", expected "column" — the stack itself died`);
      if (m.align !== "flex-start") fail("GR109-attention-row-dead-rule", `@768 align-items is "${m.align}", expected "flex-start" — the authored rule is cascade-dead (row stacks but stays centred)`);
      if (Math.abs(m.actsLeft - m.mainLeft) > 1) fail("GR109-attention-row-dead-rule", `@768 .attention-acts left ${m.actsLeft} != .attention-main left ${m.mainLeft} — buttons are centred, not left-aligned`);
      if (!failures.some((f) => f.defect === "GR109-attention-row-dead-rule")) {
        okLine(`@768 computed column/flex-start; acts left ${m.actsLeft} == main left ${m.mainLeft}`);
      }
      // The stack must stay scoped to the tablet block — at 900 it is a row.
      await setViewport(900);
      const wide = await evalJs(`getComputedStyle(document.querySelector('.attention-row')).flexDirection`);
      if (wide !== "row") fail("GR109-attention-row-dead-rule", `@900 flex-direction is "${wide}", expected "row" — the tablet stack leaked above its breakpoint`);
      else okLine(`@900 still a row — the stack is scoped to <=768`);
    }

    // ── GR115: the 720-block console declarations actually take effect ──────
    if (requested.includes("GR115-bpconsole-dead-rule")) {
      process.stdout.write(`\nGR115-bpconsole-dead-rule — computed console styles at 700x800\n`);
      await setViewport(700, 800);
      await nav(`${BASE}/?scen=empty&theme=light`, `document.querySelector('.topbar')`);
      // The .bp-console mounts on instance-detail timelines; the cascade is a
      // stylesheet property, so a minimal fixture rendered against the REAL
      // served stylesheet measures the same computed values the timeline gets.
      // Both console families are byte-identical declaration blocks (GR125c) —
      // the fixture carries BOTH so the twin proves the reorder fixed the dead
      // one without touching the live one.
      const m = await evalJs(
        `(function(){var host=document.createElement('div');host.id='gr115-fixture';` +
        `host.innerHTML='<div class="bp-console"><button class="bp-console-toggle">` +
        `<span class="bp-console-caret"></span>Console</button>` +
        `<div class="bp-console-body"><div class="bp-console-line">` +
        `<span class="bp-console-text">line</span></div></div></div>` +
        `<div class="new-console"><button class="new-console-toggle">Console</button>` +
        `<div class="new-console-body">line</div></div>';` +
        `document.body.appendChild(host);` +
        `var bp=host.querySelector('.bp-console'),tog=host.querySelector('.bp-console-toggle'),` +
        `body=host.querySelector('.bp-console-body'),caret=host.querySelector('.bp-console-caret'),` +
        `nb=host.querySelector('.new-console-body');` +
        `var out={bpMax:getComputedStyle(body).maxHeight,bpFs:getComputedStyle(body).fontSize,` +
        `togFs:getComputedStyle(tog).fontSize,newMax:getComputedStyle(nb).maxHeight,` +
        `newFs:getComputedStyle(nb).fontSize};` +
        // Twin control (.bp-console.is-collapsed, GR115): transition:none on the
        // caret first, or the synchronous read returns the transition's START
        // value and manufactures a false red.
        `caret.style.transition='none';tog.style.transition='none';` +
        `bp.classList.add('is-collapsed');` +
        `out.togBorderStyle=getComputedStyle(tog).borderBottomStyle;` +
        `out.togBorderWidth=getComputedStyle(tog).borderBottomWidth;` +
        `out.caretTransform=getComputedStyle(caret).transform;` +
        `host.remove();return out;})()`,
      );
      // 40vh of the 800px emulated viewport = 320px; pre-fix computes 260px.
      if (m.bpMax !== "320px") fail("GR115-bpconsole-dead-rule", `.bp-console-body max-height computes ${m.bpMax}, expected 320px (40vh @ 800) — the 720-block cap is cascade-dead`);
      if (m.bpFs !== "13px") fail("GR115-bpconsole-dead-rule", `.bp-console-body font-size computes ${m.bpFs}, expected 13px — the legibility floor ("no theater text falls below 13px") is false`);
      if (m.togFs !== "13px") fail("GR115-bpconsole-dead-rule", `.bp-console-toggle font-size computes ${m.togFs}, expected 13px`);
      if (m.newMax !== "320px" || m.newFs !== "13px") fail("GR115-bpconsole-dead-rule", `.new-console twin regressed: max-height ${m.newMax} font-size ${m.newFs}, expected 320px/13px`);
      // The twin control re-run after the reorder: is-collapsed still wins.
      // REVIEW FIX: this was `&&`, which only fires when BOTH readings are
      // wrong — a toggle computing `solid` at a 0px width would have passed a
      // control whose whole job is to fail. `||` is strictly stronger and still
      // green on the fix (style `none` forces the computed width to `0px`, so
      // both operands are false together).
      if (m.togBorderStyle !== "none" || m.togBorderWidth !== "0px") fail("GR115-bpconsole-dead-rule", `.bp-console.is-collapsed .bp-console-toggle border-bottom is ${m.togBorderStyle}/${m.togBorderWidth}, expected none/0px`);
      const mat = /matrix\(([-\d.e]+),\s*([-\d.e]+),/.exec(m.caretTransform || "");
      if (!mat || Math.abs(Number(mat[1])) > 1e-3 || Math.abs(Number(mat[2]) + 1) > 1e-3) {
        fail("GR115-bpconsole-dead-rule", `.bp-console.is-collapsed caret transform is "${m.caretTransform}", expected rotate(-90deg)`);
      }
      if (!failures.some((f) => f.defect === "GR115-bpconsole-dead-rule")) {
        okLine(`bp-console body ${m.bpMax}/${m.bpFs}, toggle ${m.togFs}; twin ${m.newMax}/${m.newFs}; is-collapsed border ${m.togBorderStyle}, caret ${m.caretTransform}`);
      }
    }
    // ── W12: phone widths — the body must not scroll, and the matrix must
    //    say it continues ───────────────────────────────────────────────────
    if (requested.includes("W12-narrow-viewport-truth")) {
      const D = "W12-narrow-viewport-truth";
      process.stdout.write(
        `\n${D} — ${PHONE_WIDTHS.length} phone widths x 2 themes` +
        ` (scrollbars: ${CLASSIC_SCROLLBARS ? "CLASSIC — reserved track measured" : "hidden"})\n`,
      );

      // (a) the page body itself. The fleet grid is the offender: a bare `1fr`
      //     track cannot go below the CARD's min-content, so the track — not
      //     the card's children — is what overhangs a 358px container.
      for (const theme of ["light", "dark"]) {
        await setViewport(390);
        await nav(
          `${BASE}/?scen=mixed-fleet&theme=${theme}#overview`,
          `document.querySelector('.instances-grid .instance-card')`,
        );
        const row = [];
        for (const width of PHONE_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){var d=document.documentElement;` +
            `var g=document.querySelector('.instances-grid');var c=g&&g.querySelector('.instance-card');` +
            `var r=Math.round((c?c.getBoundingClientRect().width:0)*1000)/1000;` +
            `var gw=Math.round((g?g.getBoundingClientRect().width:0)*1000)/1000;` +
            `return {sw:d.scrollWidth,cw:d.clientWidth,card:r,grid:gw,` +
            ` tracks:g?getComputedStyle(g).gridTemplateColumns:''};})()`,
          );
          const over = m.sw > m.cw;
          if (over) fail(D, `mixed-fleet/${theme}@${width}#overview: body scrollWidth ${m.sw} > clientWidth ${m.cw} (${m.sw - m.cw}px overhang) — track ${m.tracks} on a ${m.grid}px container`);
          else if (m.card > m.grid + 1) fail(D, `mixed-fleet/${theme}@${width}#overview: .instance-card ${m.card}px overhangs its ${m.grid}px grid — the track is still floored at the card's min-content`);
          row.push(`${width}:${m.sw}${over ? "!" : ""}`);
        }
        process.stdout.write(`   mixed-fleet/${theme}  ${row.join(" ")}\n`);
      }

      // (b) the notifications matrix must ADMIT it is clipped. Two independent
      //     cues, both measured: a label column that stays put while the
      //     channels scroll under it, and an edge fade that exists ONLY while
      //     content is hidden. The fade is scroll-driven, so every read is
      //     taken a frame after the scroll that provoked it — a same-tick read
      //     returns the previous frame's value and manufactures a false red.
      // A scroll-driven animation's computed value is produced by the ANIMATION
      // FRAME that follows the scroll, not by the assignment — a same-tick (or
      // even a fixed-sleep) read is a coin flip, and this measurement caught
      // itself flipping: light@768 read 48px and dark@768 read 0px off the same
      // stylesheet. Every read below is taken after two real rAFs have run.
      // TWO FORCED FRAMES. requestAnimationFrame is NOT a frame source here: a
      // headless target that has gone idle simply never calls back (measured —
      // the light pass settled on rAF every time, the dark pass sat through
      // 8000ms and eight re-arms without a single callback, off the same
      // stylesheet). Page.captureScreenshot blocks on a real BeginFrame, so it
      // produces one on demand; the value is read on the frame AFTER the scroll,
      // hence two.
      const settle = async () => {
        for (let i = 0; i < 2; i++) {
          await Promise.race([
            cdp.send("Page.captureScreenshot", { format: "jpeg", quality: 1 }, sessionId).catch(() => {}),
            sleep(EVAL_CAP),
          ]);
        }
      };

      const readMatrix = async () => {
        // Bring the matrix into the viewport FIRST. elementFromPoint answers
        // null for anything below the fold, and the matrix sits well down an
        // 800px-tall #notifications page — measured: the header hit-test read
        // "nothing" identically with the corner 1px tall and with it 55px
        // tall, i.e. a red that fired on both sides of the fix and proved
        // nothing. A hit-test that cannot tell the states apart is not a
        // measurement.
        await evalJs(`(function(){var s=document.querySelector('.set-matrix');if(s){s.scrollIntoView({block:'center'});s.scrollLeft=0;}})()`);
        await settle();
        const rest = await evalJs(
          `(function(){var s=document.querySelector('.set-matrix');if(!s)return null;` +
          `var ev=s.querySelector('.set-matrix-event');var sr=s.getBoundingClientRect();` +
          `var cols=[].slice.call(s.querySelectorAll('.set-matrix-col'));` +
          `return {sw:s.scrollWidth,cw:s.clientWidth,track:s.offsetHeight-s.clientHeight,` +
          ` fade:getComputedStyle(s).getPropertyValue('--set-matrix-fade').trim(),` +
          ` pos:getComputedStyle(ev).position,` +
          ` evLeft:Math.round(ev.getBoundingClientRect().left*100)/100,` +
          ` scLeft:Math.round(sr.left*100)/100,` +
          ` hidden:cols.filter(function(c){return c.getBoundingClientRect().left>=sr.right-0.5;}).length,` +
          ` cols:cols.length};})()`,
        );
        await evalJs(`(function(){var s=document.querySelector('.set-matrix');s.scrollLeft=120;})()`);
        await settle();
        // The hit-test at the HEADER row is not decoration. The grid is
        // `align-items: center`, and the corner cell is EMPTY — left to its
        // content it lays out 1px tall and centred, so the channel headings
        // scroll straight THROUGH the pinned label column while every row
        // below is covered correctly. A screenshot catches that; a position
        // read does not. So: sample the middle of the label column at the
        // middle of the header row and name whatever is actually on top.
        const mid = await evalJs(
          `(function(){var s=document.querySelector('.set-matrix');var ev=s.querySelector('.set-matrix-event');` +
          `var co=s.querySelector('.set-matrix-corner');var cr=co.getBoundingClientRect();` +
          `var hd=s.querySelector('.set-matrix-col').getBoundingClientRect();` +
          `var hit=document.elementFromPoint(cr.left+cr.width/2,hd.top+hd.height/2);` +
          `return {sl:s.scrollLeft,evLeft:Math.round(ev.getBoundingClientRect().left*100)/100,` +
          ` cornerH:Math.round(cr.height*100)/100,headH:Math.round(hd.height*100)/100,` +
          ` onTop:hit?(hit.className||hit.tagName):'nothing'};})()`,
        );
        await evalJs(`(function(){var s=document.querySelector('.set-matrix');s.scrollLeft=s.scrollWidth;})()`);
        await settle();
        const end = await evalJs(
          `(function(){var s=document.querySelector('.set-matrix');` +
          `return {sl:s.scrollLeft,fade:getComputedStyle(s).getPropertyValue('--set-matrix-fade').trim()};})()`,
        );
        return { rest, mid, end };
      };
      const px = (v) => Number(String(v || "0px").replace("px", ""));

      for (const theme of ["light", "dark"]) {
        await setViewport(768);
        await nav(
          `${BASE}/?scen=notif-configured&theme=${theme}#notifications`,
          `document.querySelector('.set-matrix .set-matrix-grid .set-matrix-event')`,
        );
        for (const width of [768, 430, 390]) {
          await setViewport(width);
          const { rest, mid, end } = await readMatrix();
          if (!rest) { fail(D, `notif-configured/${theme}@${width}: .set-matrix missing`); continue; }
          const clipped = rest.sw > rest.cw;
          if (!clipped) { fail(D, `notif-configured/${theme}@${width}: matrix NOT clipped (${rest.sw}/${rest.cw}) — the fixture no longer reproduces the condition`); continue; }
          // Cue 1 — the label column holds its ground while the channels move.
          if (rest.pos !== "sticky") fail(D, `notif-configured/${theme}@${width}: .set-matrix-event position is "${rest.pos}", expected "sticky" — the label column scrolls away with the channels`);
          else if (Math.abs(mid.evLeft - rest.scLeft) > 1.5) fail(D, `notif-configured/${theme}@${width}: sticky label left ${mid.evLeft} != scroller left ${rest.scLeft} after scrolling to ${mid.sl} — sticky is declared but DEAD (an overflow:hidden ancestor is the scrollport)`);
          else if (mid.cornerH < mid.headH - 0.5) fail(D, `notif-configured/${theme}@${width}: the sticky corner is ${mid.cornerH}px tall in a ${mid.headH}px header row — the channel headings scroll THROUGH the pinned label column at the top (align-items:center collapses an empty cell)`);
          else if (!String(mid.onTop).includes("set-matrix-corner")) fail(D, `notif-configured/${theme}@${width}: at the header row the label column is covered by "${mid.onTop}", not .set-matrix-corner`);
          else okLine(`notif-configured/${theme}@${width}: ${rest.hidden}/${rest.cols} channel columns off-screen at rest; label column sticks at ${mid.evLeft} through scrollLeft ${mid.sl}, corner covers the header row (${mid.cornerH}/${mid.headH}px); reserved scrollbar track ${rest.track}px`);
          // Cue 2 — the fade exists while clipped and retracts at the end.
          if (px(rest.fade) <= 0) fail(D, `notif-configured/${theme}@${width}: edge fade is ${rest.fade} while ${rest.sw - rest.cw}px of the matrix is hidden — nothing tells a person there is more`);
          else if (px(end.fade) > 0.5) fail(D, `notif-configured/${theme}@${width}: edge fade still ${end.fade} at scrollLeft ${end.sl} (the end) — the cue lies in the other direction`);
          else okLine(`notif-configured/${theme}@${width}: edge fade ${rest.fade} at rest -> ${end.fade} at the end`);
        }
        // The cue must be ABSENT when nothing is hidden — the control that
        // makes "only while clipped" a measurement rather than a hope.
        await setViewport(1440);
        const wide = await readMatrix();
        if (wide.rest.sw > wide.rest.cw) fail(D, `notif-configured/${theme}@1440: matrix still clipped (${wide.rest.sw}/${wide.rest.cw}) — control invalid`);
        else if (px(wide.rest.fade) > 0.5) fail(D, `notif-configured/${theme}@1440: edge fade ${wide.rest.fade} with nothing hidden — the cue fires when it should not`);
        else okLine(`notif-configured/${theme}@1440: nothing hidden, fade ${wide.rest.fade} — the cue is scoped to the clipped state`);
      }
    }
    // ── W13: the detail routes stop scrolling sideways in the tablet band ──
    //    Five detail routes plus #fleet, 9 widths x 2 themes = 108 cells. Every
    //    cell asserts TWO things: the page does not scroll horizontally, and the
    //    route that was asked for is the route that rendered.
    if (requested.includes("W13-detail-route-band")) {
      const D = "W13-detail-route-band";
      process.stdout.write(
        `\n${D} — ${BAND_ROUTES.length} routes x ${BAND_WIDTHS.length} widths x 2 themes` +
        ` (${BAND_ROUTES.length * BAND_WIDTHS.length * 2} cells)\n`,
      );
      let cells = 0, offenders = 0, misrouted = 0;
      for (const r of BAND_ROUTES) {
        for (const theme of ["light", "dark"]) {
          // Enter at 900 — ABOVE the band — so a route that only renders at one
          // width cannot be mistaken for a route that renders everywhere.
          await setViewport(900);
          await nav(
            `${BASE}/?scen=${r.scen}&theme=${theme}${r.hash}`,
            `document.querySelector('${r.ready}') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='${r.view}';})()`,
          );
          const row = [];
          for (const width of BAND_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var t=document.querySelector('.inst-tab[aria-current="page"]');` +
              `return {sw:d.scrollWidth, cw:d.clientWidth, view:v?v.id:'none',` +
              ` tab:t?t.textContent:null, theme:d.getAttribute('data-theme')};})()`,
            );
            cells++;
            // (1) THE ROUTE. Without this the whole table is phantom.
            if (m.view !== r.view) {
              misrouted++;
              fail(D, `${r.name}/${theme}@${width}: rendered section.view "${m.view}", asked for "${r.view}" — the hash did not route, so nothing below this line measures ${r.name}`);
            } else if (r.tab && m.tab !== r.tab) {
              misrouted++;
              fail(D, `${r.name}/${theme}@${width}: #view-instance is up but the active sub-tab is "${m.tab}", expected "${r.tab}" — a sibling instance route was measured`);
            }
            if (m.theme !== theme) fail(D, `${r.name}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // (2) THE PIXELS.
            const over = m.sw - m.cw;
            if (over > 0) {
              offenders++;
              fail(D, `${r.name}/${theme}@${width}: scrollWidth ${m.sw} > viewport ${m.cw} — ${over}px of the page is off-screen at rest, with no cue`);
            }
            row.push(`${width}:${m.sw}${over > 0 ? "!" : ""}`);
          }
          process.stdout.write(`   ${r.name}/${theme}  ${row.join(" ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean across ${BAND_WIDTHS[0]}-${BAND_WIDTHS[BAND_WIDTHS.length - 1]}` +
          ` (769/899 are the band edges, 900/1024 the controls above it); ${misrouted} misrouted;` +
          ` no exemptions — #fleet's W13 residual was paid by W14-S3 and its pin is gone`,
        );
      }
    }
  } catch (err) {
    // AUDITED (exit 2): the probe itself threw, so NOTHING was measured — an
    // incomplete run must never be reported as a measured overflow.
    return die(`measurement broke: ${err.message}`);
  }

  await teardown();

  process.stdout.write("\n");
  if (failures.length) {
    const byDefect = [...new Set(failures.map((f) => f.defect))];
    process.stderr.write(`OVERFLOW GUARD FAIL — ${failures.length} finding(s) in: ${byDefect.join(", ")}\n`);
    process.exit(1);
  }
  process.stdout.write(`OVERFLOW GUARD PASS — ${requested.join(", ")} measured fixed in a real browser\n`);
  process.exit(0);
}

main().catch((err) => {
  process.stderr.write(`!! OVERFLOW GUARD crashed: ${err && err.stack ? err.stack : err}\n`);
  process.exit(1);
});
