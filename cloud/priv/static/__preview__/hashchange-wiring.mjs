// hashchange-wiring.mjs — does the LIVE hashchange listener obey the pure
// decision, in a real browser, in the real order?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (gr-blk-hashchange-listener-wiring-proof)
// ─────────────────────────────────────────────────────────────────────────────
//  GR105 — "a hash change that ROUTES ELSEWHERE closes a modal the new route
//  did not itself open" — is implemented in TWO halves that no gate joined:
//
//    (a) THE DECISION, `hashChangeEffects(prev, next, ctx)` in app.js, pure and
//        pinned by four mutation-proven node tests in __app.test.mjs; and
//    (b) THE WIRING, the `window.addEventListener("hashchange", …)` registered
//        inside init(), which calls `closeModal()` when `eff.close` and calls
//        it BEFORE `applyRoute()`.
//
//  Only (a) was guarded. (b) was invisible to every gate in the repository, and
//  the reason is structural, not an oversight:
//
//    * __app.test.mjs runs app.js inside a node:vm with a synthetic DOM whose
//      `document.readyState === "loading"`, so init() is only ever REGISTERED,
//      never invoked. The listener never binds. Its 15 mentions of
//      hashChangeEffects all reach the pure function directly.
//    * __preview__/smoke.mjs is the same shape — node:vm, no browser — and it
//      drives every screen by a LOAD-TIME deep link. Nothing in it ever mutates
//      `location.hash` on a live page, so no hashchange is ever dispatched.
//    * The screenshot rig and the CSSOM oracle open modals, but by query seam
//      (`?modal=account`) at load; neither navigates afterwards.
//
//  So deleting `if (eff.close) closeModal();` from the listener left every gate
//  green — a decision certified, and no live event proven to obey it. That is
//  the exact shape this epic exists to stop trusting: a gate that cannot see
//  the artifact it certifies.
//
//  This file is the honest instrument: a real Chrome, the real app.js, a real
//  `location.hash` write, and an assertion about what the DOM did next.
//
// ─────────────────────────────────────────────────────────────────────────────
//  THE THREE LEGS, AND WHAT EACH ONE CATCHES
// ─────────────────────────────────────────────────────────────────────────────
//  1. route-change-closes — the account modal is open at hash "", the hash is
//     set to "#fleet" (a genuinely different canonical route), and #modal-root
//     must go hidden.
//        CATCHES: the `closeModal()` call removed from the listener; the
//        listener not bound at all; #modal-root selector drift inside
//        closeModal().
//        MUTATION-PROVEN — see MUTATION PROOF below.
//
//  2. legacy-launch-reopens — the LEGACY #launch bookmark (D66). At "#fleet",
//     the hash is set to "#launch". `legacyRoute("launch") === "overview"`, so
//     this IS a route change (fleet → overview): eff.close is TRUE, and then
//     applyRoute lands Overview and calls openLaunchModal(). A modal must be
//     OPEN at the end, and it must be the launch flow.
//        CATCHES THE ORDERING, which is the whole reason the listener closes
//        before it routes: move `if (eff.close) closeModal();` below
//        `if (eff.route) applyRoute();` and this leg goes red — the launcher is
//        opened by the route and then torn straight back down. Leg 1 stays
//        green under that reordering, and leg 2 stays green under leg 1's
//        deletion, so neither leg is the other's duplicate.
//
//  3. alias-same-route-keeps-open — the account modal is open at
//     "#settings/billing" and the hash is set to its legacy alias "#billing".
//     `legacyRoute("billing") === "settings/billing"`, so this is NOT a route
//     change: eff.close is FALSE and the modal must SURVIVE.
//
//     THE ALIAS SET IS READ, NOT GUESSED. legacyRoute's MAP is exactly
//     { launch, billing, providers, notifications, tokens } — this leg was
//     first written against "#account" → "#settings/account", which is NOT in
//     that map, and origin/main correctly CLOSED the modal. The instrument
//     caught its own author. Re-derive before editing this leg:
//       grep -n 'var MAP = {' -A 8 cloud/priv/static/app.js
//        CATCHES THE BLANKET CLOSE — the naive "close on any hashchange" fix
//        that leg 1 would otherwise accept. Nothing on this route reopens a
//        modal, so a blanket close is observable here and only here.
//
//  Legs 2 and 3 together are the #launch coverage the row asks for. Note what
//  is NOT true and was worth measuring before believing: a blanket close does
//  not, by itself, break the #launch bookmark. Because the committed listener
//  closes BEFORE it routes, `closeModal()` on the way into #launch runs before
//  openLaunchModal() and the launcher still ends up open. The hazard at #launch
//  is the ORDER, not the blanketness — so leg 2 pins the order and leg 3 pins
//  the blanketness, and saying which leg buys which is the difference between
//  three assertions and three claims.
//
// ─────────────────────────────────────────────────────────────────────────────
//  MUTATION PROOF (re-derive it; do not inherit this paragraph)
// ─────────────────────────────────────────────────────────────────────────────
//    cp cloud/priv/static/app.js /tmp/app.js.orig
//    perl -0pi -e 's/\n      if \(eff\.close\) closeModal\(\);//' cloud/priv/static/app.js
//    node cloud/priv/static/__preview__/hashchange-wiring.mjs ; echo "rc=$?"
//    cp /tmp/app.js.orig cloud/priv/static/app.js
//
//  THE MEASURED MATRIX (this host, Chrome 153, origin/main 4d9bbee5b). Three
//  mutations, three legs, and every cell was RUN — not reasoned about. Each
//  mutation reds EXACTLY ONE leg, which is what makes all three legs load-
//  bearing: drop any one of them and one of these mutations ships green.
//
//    mutation of the listener body            leg 1   leg 2   leg 3   rc
//    ---------------------------------------  -----   -----   -----   --
//    (committed code — no mutation)             ok      ok      ok      0
//    delete `if (eff.close) closeModal();`     FAIL     ok      ok      1
//    swap: applyRoute() before closeModal()      ok    FAIL     ok      1
//    blanket: `closeModal();` unconditional      ok      ok    FAIL     1
//
//  Reproduce the ordering row by swapping the two `if (eff…)` lines, and the
//  blanket row with `s/if \(eff\.close\) closeModal\(\);/closeModal();/`.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node cloud/priv/static/__preview__/hashchange-wiring.mjs
//    LEG=route-change-closes node cloud/priv/static/__preview__/hashchange-wiring.mjs
//
//  Env: LEG (comma-list, default all three) · CHROME (binary override) · PORT
//  (preview port; default = a free port) · WIDTH/HEIGHT (viewport, default
//  1440x900).
//
//  Exit codes — the console-harness vocabulary, deliberately identical to
//  modal-oracle.mjs beside it:
//    0 = every leg asserted clean.
//    1 = a leg FAILED: the wiring is measurably wrong, and the mechanism is
//        named on stderr.
//    2 = REFUSED TO MEASURE: an unknown LEG name, no usable Chrome, a stale
//        server squatting the port, or a leg whose PRECONDITION was never
//        reached (the modal never opened, the deep link never landed, the
//        hashchange never fired). A precondition that does not hold means
//        NOTHING about the listener was measured, and laundering that into
//        exit 1 — "a wiring defect was measured" — is the accusation this
//        whole wave exists to stop.
//
//  WIRED INTO CI: as a step of the `modal-oracle` job in
//  .github/workflows/console-harness.yml (it already provisions node 22 and an
//  explicit CHROME, and it is an upstream `needs:` of the REQUIRED `Console
//  gate` context, so a red here BLOCKS a merge). Re-derive, do not trust:
//    git grep -nE '(node|bash|sh) .*hashchange-wiring' -- .github/ scripts/ Makefile
//
//  ZERO DEPENDENCIES — node 22 native fetch + native WebSocket speak CDP
//  directly, matching __preview__'s doctrine. The CDP client and the teardown
//  below are the same shape as modal-oracle.mjs's; that file exports no
//  transport, and four instruments in this directory already carry their own
//  `class Cdp` for the same reason.
//
//  NO FONT PIN, on purpose. Every assertion here is a BOOLEAN about DOM
//  structure — is #modal-root hidden, is #launch-modal-slot present — and not
//  one of them is a layout of a resolved typeface. modal-oracle.mjs pins the
//  font because its verdicts are heights and clipping; borrowing that pin here
//  would buy a refusal path over an input nothing reads.
// ─────────────────────────────────────────────────────────────────────────────

import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { SCENARIOS } from "./scenarios.mjs";
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr } from "./bringup-retry.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// Every leg boots this one scenario. It is signed in, carries a real /v1/me
// (the account chip must resolve before mock.js opens the modal), one instance
// so #fleet has something to paint, and `deepLink: ""` so leg 1 starts from the
// empty hash. Validated against SCENARIOS below, for the same reason
// modal-oracle.mjs validates SCEN: `?modal=account` opens the REAL account
// modal whether or not the scenario exists, so a rename here would otherwise
// measure the right listener on the wrong screen and exit 0.
const SCEN = "account-modal";

const VIEW_W = Number(process.env.WIDTH || 1440);
const VIEW_H = Number(process.env.HEIGHT || 900);

const SERVER_UP_CAP = 5000;
const DEVTOOLS_CAP = 15000;
const SETTLE_CAP = 12000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const list = (v) => String(v).split(",").map((s) => s.trim()).filter(Boolean);

// ── page-side probes ─────────────────────────────────────────────────────────
// Each is one expression returned by value. They are deliberately structural:
// "is the dialog root showing and does it hold the card this leg is about".
const MODAL_OPEN = `(function(){var r=document.getElementById('modal-root');` +
  `return !!(r && !r.hidden && r.querySelector('.modal-card'));})()`;
const MODAL_SHUT = `(function(){var r=document.getElementById('modal-root');` +
  `return !!(r && r.hidden);})()`;
// The account modal specifically — #am-pw-toggle is minted by accountModalHtml
// and by nothing else, so "some modal is up" can never be read as "the account
// modal survived".
const ACCOUNT_MODAL_OPEN = `(function(){var r=document.getElementById('modal-root');` +
  `return !!(r && !r.hidden && r.querySelector('.modal-card') && ` +
  `document.getElementById('am-pw-toggle'));})()`;
// The launch flow specifically — openLaunchModal mounts #launch-modal-slot.
const LAUNCH_MODAL_OPEN = `(function(){var r=document.getElementById('modal-root');` +
  `return !!(r && !r.hidden && document.getElementById('launch-modal-slot'));})()`;
const FLEET_VIEW = `(function(){var v=document.querySelector('section.view:not([hidden])');` +
  `return !!(v && v.id==='view-fleet');})()`;

// Installed BEFORE the hash is written, and read after. It is OUR listener, not
// the app's, so it stays truthful under every mutation of the app's — which is
// the point: a leg that reds because the hash never moved is a REFUSAL (exit
// 2), not a wiring defect, and only an independent counter can tell them apart.
const ARM_COUNTER =
  `(function(){window.__hcSeen=0;` +
  `window.addEventListener('hashchange',function(){window.__hcSeen++;});return true;})()`;
const READ_COUNTER = `(function(){return window.__hcSeen|0;})()`;
const READ_HASH = `(function(){return String(location.hash||'');})()`;

// ── THE LEGS ─────────────────────────────────────────────────────────────────
//   url      — query + hash the leg boots at (scenario/theme are added).
//   setup    — the precondition probe. Not reached ⇒ exit 2, never exit 1.
//   setupWhy — what a reader must fix when the precondition never holds.
//   hash     — the hash this leg WRITES, live, on the settled page.
//   expect   — the probe that must become true after the write.
//   mechanism— the sentence printed when `expect` never becomes true. It names
//              the app.js seam, because "leg 1 failed" is not a finding.
const LEGS = {
  "route-change-closes": {
    url: "&modal=account",
    setup: ACCOUNT_MODAL_OPEN,
    setupWhy:
      "the account modal never opened at the boot hash — mock.js drives " +
      "appHooks.openAccountModal() only after /v1/me paints #acct-email, so " +
      "this is a preview-harness or /v1/me fault, not a listener fault.",
    hash: "#fleet",
    expect: MODAL_SHUT,
    what: "a route change must CLOSE the open modal",
    mechanism:
      "#modal-root is STILL VISIBLE after a live hashchange from \"\" to " +
      "\"#fleet\" — two different canonical routes, so hashChangeEffects " +
      "returned { close: true } and the modal should be gone. The " +
      "hashchange listener registered in init() (app.js, the " +
      "`window.addEventListener(\"hashchange\", …)` that reads `eff.close`) " +
      "is no longer calling closeModal() — the call was removed, the " +
      "listener never bound, or closeModal()'s #modal-root selector drifted. " +
      "GR105 is now certified at the DECISION and violated at the WIRING.",
  },
  "legacy-launch-reopens": {
    url: "#fleet",
    setup: FLEET_VIEW,
    setupWhy:
      "the #fleet deep link never landed on view-fleet, so the leg never had " +
      "a route to leave — nothing about the listener was measured.",
    hash: "#launch",
    expect: LAUNCH_MODAL_OPEN,
    what: "the legacy #launch bookmark must END with the launcher OPEN",
    mechanism:
      "no #launch-modal-slot is showing after a live hashchange from " +
      "\"#fleet\" to \"#launch\". legacyRoute(\"launch\") === \"overview\", so " +
      "this IS a route change (close: true) AND applyRoute must land Overview " +
      "and call openLaunchModal(). The committed listener closes BEFORE it " +
      "routes precisely so the launcher applyRoute opens is not the thing " +
      "torn back down — this failure is that ORDER inverted (closeModal() " +
      "moved below applyRoute()), or wantsLaunchFlow()/openLaunchModal() " +
      "broken on the Overview arm of applyRoute. D66's stale bookmark no " +
      "longer reaches the launcher.",
  },
  "alias-same-route-keeps-open": {
    url: "&modal=account#settings/billing",
    setup: ACCOUNT_MODAL_OPEN,
    setupWhy:
      "the account modal never opened at #settings/billing — see the " +
      "route-change-closes leg's note; the harness, not the listener.",
    hash: "#billing",
    expect: ACCOUNT_MODAL_OPEN,
    what: "a LEGACY-ALIAS hash change must NOT close the modal",
    mechanism:
      "the account modal is GONE after a live hashchange from " +
      "\"#settings/billing\" to its legacy alias \"#billing\". " +
      "legacyRoute(\"billing\") === \"settings/billing\": same canonical " +
      "route, so hashChangeEffects returned { close: false } and nothing may " +
      "be dismissed. A listener that closes on ANY hashchange — the naive " +
      "reading of GR105 — fails exactly here, and nowhere else in this file: " +
      "no other leg can distinguish it, because every other route change " +
      "either wants the close or reopens a modal of its own.",
  },
};

// ── 1. ROSTER GUARD — before anything is spawned ─────────────────────────────
function rosterGuard() {
  const legs = process.env.LEG ? list(process.env.LEG) : Object.keys(LEGS);
  const problems = [];
  if (legs.length === 0) problems.push("LEG is set but empty");
  for (const l of legs) {
    if (!Object.prototype.hasOwnProperty.call(LEGS, l)) {
      problems.push(
        `unknown LEG "${l}" — expected one of: ${Object.keys(LEGS).join(", ")}`,
      );
    }
  }
  if (!Object.prototype.hasOwnProperty.call(SCENARIOS, SCEN)) {
    problems.push(
      `SCEN "${SCEN}" is not a key of scenarios.mjs → SCENARIOS. Every leg ` +
        `boots it; a renamed scenario would leave ?modal=account opening the ` +
        `real modal on a FALLBACK screen and every leg would pass on it.`,
    );
  }
  if (problems.length) {
    process.stderr.write("!! ROSTER GUARD (exit 2) — refusing to boot Chrome:\n");
    for (const p of problems) process.stderr.write("   • " + p + "\n");
    process.exit(2);
  }
  return legs;
}

// ── 2. plumbing (shape shared with modal-oracle.mjs) ─────────────────────────
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

function findChrome() {
  if (process.env.CHROME) {
    try {
      fs.accessSync(process.env.CHROME, fs.constants.X_OK);
      return process.env.CHROME;
    } catch {
      return null;
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

function chromeGuardLine() {
  return process.env.CHROME
    ? `!! GUARD (exit 2): CHROME=${process.env.CHROME} is not an executable file. Environment refusal, not a wiring defect.\n`
    : "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n";
}

function httpOk(url) {
  return new Promise((resolve) => {
    const req = http.get(url, (res) => { res.resume(); resolve(res.statusCode === 200); });
    req.on("error", () => resolve(false));
    req.setTimeout(1000, () => { req.destroy(); resolve(false); });
  });
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

// ── 3. the run ───────────────────────────────────────────────────────────────
async function main() {
  const legs = rosterGuard();

  const chromeBin = findChrome();
  if (!chromeBin) {
    process.stderr.write(chromeGuardLine());
    process.exit(2);
  }

  const port = Number(process.env.PORT || (await freePort()));
  let profile = null;
  const t0 = Date.now();

  let server = null;
  let chrome = null;
  let cdp = null;
  const results = [];
  let teardownMs = 0;

  const teardown = async () => {
    const td0 = Date.now();
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    const alive = (p) => { if (!p || p.pid == null) return false; try { process.kill(p.pid, 0); return true; } catch { return false; } };
    const reap = async (proc, label) => {
      if (!alive(proc)) return;
      try { proc.kill("SIGTERM"); } catch { /* already gone */ }
      let waited = 0;
      while (alive(proc) && waited < TERM_POLL_CAP) { await sleep(50); waited += 50; }
      if (!alive(proc)) return;
      try { proc.kill("SIGKILL"); } catch { /* already gone */ }
      waited = 0;
      while (alive(proc) && waited < KILL_POLL_CAP) { await sleep(50); waited += 50; }
      if (alive(proc)) {
        process.stderr.write(
          `!! TEARDOWN SHOUT: ${label} pid ${proc.pid} SURVIVED SIGKILL after ` +
            `${KILL_POLL_CAP}ms. Reap it by hand: kill -9 ${proc.pid}\n`,
        );
      }
    };
    await reap(chrome, "chrome");
    await reap(server, "serve.mjs");
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
    teardownMs = Date.now() - td0;
  };

  // Every refusal path funnels through here, so exit 2 can never be reached by
  // a `throw` (the catch below maps every throw to exit 1 = "a wiring defect
  // was measured", and a refusal measured nothing).
  const refuse = async (lines) => {
    await teardown();
    process.stderr.write("\n!! HASHCHANGE WIRING (exit 2): REFUSED TO MEASURE\n");
    for (const l of lines) process.stderr.write("   " + l + "\n");
    process.stderr.write(`   teardown ${teardownMs}ms\n`);
    process.exit(2);
  };

  try {
    server = spawn(process.execPath, [path.join(HERE, "serve.mjs"), "--port", String(port)], {
      stdio: "ignore",
    });
    let up = false;
    for (let w = 0; w < SERVER_UP_CAP; w += 100) {
      if (await httpOk(`http://127.0.0.1:${port}/`)) { up = true; break; }
      await sleep(100);
    }
    if (!up) {
      await refuse([
        `preview server never answered on :${port} (port in use? node error?)`,
        "Not one leg was asserted.",
      ]);
    }
    // Stale-server guard, consumer side (gr-blk-serve-stale-guard): "the port
    // answers" is not "OUR server answers". app.js is the artifact under test
    // here, so judging a foreign worktree's bytes would certify the wrong tree.
    for (const rel of ["app.js"]) {
      const served = Buffer.from(await (await fetch(`http://127.0.0.1:${port}/${rel}`, { cache: "no-store" })).arrayBuffer());
      const disk = fs.readFileSync(path.join(HERE, "..", rel));
      if (!served.equals(disk)) {
        await refuse([
          `STALE SERVER on :${port}.`,
          `/${rel} served ${served.length} B but this tree's disk has ${disk.length} B: a server rooted`,
          "at a DIFFERENT tree (a foreign worktree?) is squatting this port. app.js IS the artifact",
          "under test, so judging its bytes would certify the wrong tree.",
          `Find it: lsof -nP -iTCP:${port} -sTCP:LISTEN`,
        ]);
      }
    }
    process.stdout.write(`>> preview  http://127.0.0.1:${port}\n>> chrome   ${chromeBin}\n`);

    let attemptSpawnError = null;
    const brought = await bringUpChrome({
      label: "hashchange-wiring",
      attempts: BRINGUP_ATTEMPTS,
      newProfile: () => fs.mkdtempSync(path.join(os.tmpdir(), "hashchange-wiring-")),
      launch: (dir) => {
        attemptSpawnError = null;
        const child = spawn(
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
            `--user-data-dir=${dir}`,
            `--window-size=${VIEW_W},${VIEW_H}`,
            "--remote-debugging-port=0",
            "about:blank",
          ],
          { stdio: ["ignore", "ignore", "pipe"] },
        );
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
        if (child && child.pid != null) { try { child.kill("SIGKILL"); } catch { /* already gone */ } }
        try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
      },
      log: (s) => process.stderr.write(s),
    }).catch((err) => (err && err.refused ? { refusal: err } : Promise.reject(err)));

    if (brought.refusal) {
      await refuse([
        brought.refusal.message,
        "Headless Chrome never came up, so NOT ONE leg was asserted.",
        `Fix the browser in this environment (CHROME=${chromeBin}), then re-run.`,
      ]);
    }
    chrome = brought.child;
    profile = brought.profile;

    const version = await (await fetch(`http://127.0.0.1:${brought.devPort}/json/version`)).json();
    process.stdout.write(`>> ${version.Browser} · node ${process.version}\n`);
    process.stdout.write(
      ">> scope: this instrument is invoked by the `modal-oracle` job in " +
        ".github/workflows/console-harness.yml, an upstream `needs:` of the " +
        "REQUIRED `Console gate` context — exit 1 and exit 2 both BLOCK a merge.\n\n",
    );
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);

    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Runtime.enable", {}, sessionId);
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: VIEW_W, height: VIEW_H, deviceScaleFactor: 1, mobile: false,
    }, sessionId);

    const evaluate = async (expression) => {
      const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true }, sessionId);
      if (r.exceptionDetails) throw new Error(`page threw: ${r.exceptionDetails.text}`);
      return r.result.value;
    };
    const poll = async (expression) => {
      for (let w = 0; w < SETTLE_CAP; w += 100) {
        const probe = await cdp
          .send("Runtime.evaluate", { expression, returnByValue: true }, sessionId)
          .catch(() => null);
        if (probe && probe.result && probe.result.value === true) return true;
        await sleep(100);
      }
      return false;
    };

    for (const name of legs) {
      const leg = LEGS[name];
      const s0 = Date.now();

      // Each leg gets a FULL navigation, not a hash rewrite on the previous
      // leg's page: `lastRoutedHash` is seeded once at init() wiring time, and a
      // leg inheriting another's routing history would compare against a `prev`
      // nobody declared.
      const url =
        `http://127.0.0.1:${port}/?scen=${encodeURIComponent(SCEN)}&theme=light` +
        (leg.url.startsWith("#") ? "" : leg.url.split("#")[0]) +
        (leg.url.includes("#") ? "#" + leg.url.split("#")[1] : "");
      await cdp.send("Page.navigate", { url }, sessionId);

      if (!(await poll(leg.setup))) {
        await refuse([
          `leg "${name}": its PRECONDITION never held (probe: ${leg.setup}).`,
          leg.setupWhy,
          "The hash was never written, so this leg made NO claim about the listener",
          "in either direction — that is a refusal, not a clean bill and not an accusation.",
          `url: ${url}`,
        ]);
      }
      const hashBefore = await evaluate(READ_HASH);
      await evaluate(ARM_COUNTER);

      // THE LIVE EVENT. `location.hash = …` is the only gesture in this file,
      // and it is the one no other gate in the repository performs.
      await evaluate(`location.hash = ${JSON.stringify(leg.hash)}; true;`);

      const ok = await poll(leg.expect);
      const seen = await evaluate(READ_COUNTER);
      const hashAfter = await evaluate(READ_HASH);

      // ANTI-VACUITY, read AFTER the expectation and BEFORE the verdict. A leg
      // whose expectation is "the modal is still open" (leg 3) is trivially
      // satisfied by a page where nothing happened at all, so "did a hashchange
      // actually fire" is a PRECONDITION of every leg, not a control on the
      // failing ones. It is measured by our own listener, which no mutation of
      // app.js can silence.
      if (seen < 1) {
        await refuse([
          `leg "${name}": no hashchange event was dispatched at all.`,
          `hash went "${hashBefore}" → "${hashAfter}" and window.__hcSeen is ${seen}.`,
          "A same-hash write fires no event; the browser, not the console, decides that.",
          "Nothing about the listener was measured — the leg is void, not failing.",
        ]);
      }

      results.push({ name, ok, seen, hashBefore, hashAfter, ms: Date.now() - s0, leg });
      process.stdout.write(
        `${ok ? " ok " : "FAIL"}  ${name.padEnd(30)} ` +
          `"${hashBefore}" → "${hashAfter}" · events=${seen} · ${leg.what} · ${Date.now() - s0}ms\n`,
      );
      if (!ok) process.stdout.write(`      ✗ ${leg.mechanism}\n`);
    }
  } catch (err) {
    await teardown();
    process.stderr.write(`\n!! HASHCHANGE WIRING ERROR: ${err && err.message ? err.message : err}\n`);
    process.stderr.write(`   teardown ${teardownMs}ms\n`);
    process.exit(1);
  }

  await teardown();

  const failed = results.filter((r) => !r.ok);
  const wall = Date.now() - t0;
  process.stdout.write(
    `\n${failed.length ? "WIRING FAIL" : "WIRING PASS"} — ${results.length} leg(s) asserted, ` +
      `${failed.length} failing · ${(wall / 1000).toFixed(1)}s wall · teardown ${teardownMs}ms\n`,
  );

  if (failed.length) {
    process.stderr.write(
      `\n!! ${failed.length} of ${results.length} leg(s) FAILED — the LIVE hashchange ` +
        `listener does not obey the pure decision:\n`,
    );
    for (const r of failed) {
      process.stderr.write(`   ${r.name}  ("${r.hashBefore}" → "${r.hashAfter}")\n`);
      process.stderr.write(`     ✗ ${r.leg.mechanism}\n`);
    }
    process.exit(1);
  }
  process.exit(0);
}

main();
