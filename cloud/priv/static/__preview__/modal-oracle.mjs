// modal-oracle.mjs — does the authored `.modal-root` rule survive into the CSSOM?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (charter GR74 / GR93)
// ─────────────────────────────────────────────────────────────────────────────
//  Bug #4592 shipped a REVIEW ADDENDUM paragraph in app.css whose `/*` opener
//  was lost. CSS error recovery then swallowed the base `.modal-root` rule
//  whole, and every modal in the console rendered unpositioned beneath a fixed
//  scrim — in PRODUCTION, for five waves. Three green gates certified that dead
//  CSS the entire time, because every one of them asks a question about the
//  FILE. E10 asks "is this file's comment nesting coherent?". This asks the only
//  question that actually matters: *did my authored rule survive into the
//  CSSOM the browser built?*
//
//  It is a runnable INSTRUMENT, not a gate. It is deliberately NOT wired into
//  any GitHub workflow (GR93(b)) — same shape as scripts/studio-desk-measure.mjs.
//  It never gates the epic seal (GR93(c)); the re-shoot's PNGs remain the
//  contractual visual evidence. If it proves flaky, that is the finding.
//
// ─────────────────────────────────────────────────────────────────────────────
//  HONEST COVERAGE — THREE detectors, not four. Do not credit the fourth.
// ─────────────────────────────────────────────────────────────────────────────
//  Four assertion classes run below. Under the real mutation (reintroducing the
//  #4592 defect byte-for-byte) only THREE of them go red. Measured, not assumed:
//
//   1. CSSOM BASE-RULE            ✅ DETECTS #4592
//      A rule whose selectorText is EXACTLY ".modal-root" must be reachable in
//      document.styleSheets and its cssText must still declare position:fixed.
//      ⚠️  A SUBSTRING CHECK HERE IS A FALSE GREEN, AND IT WAS MEASURED. Under
//      the defect the substring count goes 4 → 3, NEVER 0: error recovery eats
//      only the base rule, while `.modal-root:has(.cmdk)` ×2 and
//      `.modal-root:has(.am-modal)` parse fine. `cssText.includes(".modal-root")`
//      reports GREEN on the production defect. Key on selectorText EXACTLY.
//
//   2. COMPUTED position/overflow-y  ✅ DETECTS #4592
//      getComputedStyle(#modal-root) must read position:fixed, overflow-y:auto.
//
//   3. TALL-CARD SCROLL           ✅ DETECTS #4592
//      When the card is taller than the viewport the root must be scrollable
//      (scrollHeight > clientHeight). Under mutation this reads "card 961px in
//      a 900px viewport but #modal-root is NOT scrollable (961 vs 961)" — the
//      footer, i.e. Log out and 2FA, is permanently unreachable. This is the
//      exact shape that broke prod and the exact shape a screenshot cannot see.
//
//   4. HIT-TEST ABOVE BACKDROP + BUTTON REACHABILITY   ❌ DOES **NOT** DETECT #4592
//      Both still PASSED under the mutation. Reason, measured: `.modal-card`
//      carries `position: relative; z-index: 1`, so it keeps painting above the
//      `z-index: auto` backdrop even with the root unpositioned, and page-level
//      scroll substitutes for the root's own scroll path. Kept for OTHER defect
//      classes (a backdrop that eats clicks, a card pushed off-screen) — but no
//      future reader should count four independent safety nets here. There are
//      three.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node cloud/priv/static/__preview__/modal-oracle.mjs
//    SCEN=account-modal-tall THEME=dark node modal-oracle.mjs
//    ACCENT=iris node modal-oracle.mjs
//
//  Env: SCEN (comma-list, default the four account-modal scenarios) · THEME
//  (comma-list of light|dark, default both) · ACCENT (optional single identity)
//  · CHROME (binary override) · PORT (preview port; default = a free port).
//
//  Exit codes:  0 = every state asserted clean · 1 = an assertion FAILED (the
//  mechanism is named on stderr) · 2 = GUARD — refused BEFORE measuring: an
//  unknown SCEN or THEME, or no usable Chrome. 1 is a claim about the console;
//  2 is a claim about the environment, and the two must never be confused.
//
//  THE ROSTER GUARD IS NOT OPTIONAL — it is the second false green this
//  instrument's own mutation proof found *inside the instrument*.
//  `SCEN=account-modal-taII` (capital i's) once returned "ORACLE PASS — 1
//  state(s) asserted", exit 0: mock.js drives openAccountModal() on
//  ?modal=account whether or not the scenario exists, so it measured the right
//  CSS on the wrong screen. `THEME=drak` rendered light and passed the same way.
//  Both now abort with exit 2 before a browser is spawned.
//
//  ZERO DEPENDENCIES — Node 22 native fetch + native WebSocket speak CDP
//  directly, matching __preview__'s doctrine (serve.mjs, smoke.mjs, shoot.sh all
//  run dependency-free). smoke.mjs was read first and carries NO reusable CDP
//  transport: it is a node:vm + synthetic-DOM harness with no browser at all.
//
//  TEARDOWN — this does NOT inherit shoot.sh's hang. shoot.sh reaps with
//  `kill "$cpid"; wait "$cpid"; kill -9 "$cpid"`, and that blocking `wait` on a
//  Chrome that ignores TERM is the documented multi-hour stall (a foreign
//  shoot.sh was found wedged 7h18m on this host). Nothing here ever blocks on a
//  child: CDP Browser.close raced against a cap, then `kill -0` polling with a
//  cap, then SIGKILL with a further cap, and a SHOUT on stderr if a pid somehow
//  survives that.
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
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr } from "./bringup-retry.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const VALID_THEMES = ["light", "dark"];
const VALID_ACCENTS = ["evergreen", "ember", "fjord", "charple", "iris"];
const DEFAULT_SCEN = [
  "account-modal",
  "account-modal-tall",
  "account-modal-2fa-on",
  "account-modal-2fa-badcode",
];

// The honest scope of this file's font pin, printed on EVERY run — a healthy
// one and a refusing one. Measured, not assumed:
//
//   $ grep -rn 'modal-oracle' .github/workflows/ scripts/
//   (no output)
//
// MODAL GEOMETRY IS OWNED BY overflow-guard.mjs (cchi-w22-bl-modal-oracle-
// never-visits-a-phone-width): its W22-2fa-enroll-phone-band leg drives the
// REAL enroll phase at 320-480 in both themes under the CI-blocking gate,
// because a phone-band assertion in a file nothing runs enforces nothing.
// This oracle stays the 1440 behavioural instrument.
// ZERO CI jobs and ZERO scripts invoke this oracle, so its exit 2 is read by
// nobody today. The pin below buys EVIDENCE — a human running this by hand
// learns which face resolved — and NOT enforcement. Saying so here is the
// difference between "three instruments are pinned" and "three instruments are
// gated"; only the first is true.
const ORACLE_CI_SCOPE =
  "font pin scope: this oracle is invoked by ZERO CI jobs and ZERO scripts " +
  "(grep -rn 'modal-oracle' .github/workflows/ scripts/ → no hits), so its exit 2 " +
  "buys evidence for whoever runs it by hand, not enforcement.";

// Viewport. 900px tall on purpose: it is shorter than the 9-session account
// card, which is what makes assertion 3 meaningful.
const VIEW_W = Number(process.env.WIDTH || 1440);
const VIEW_H = Number(process.env.HEIGHT || 900);

// Caps (ms).
const SERVER_UP_CAP = 5000;
const DEVTOOLS_CAP = 15000;
const MODAL_CAP = 12000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const list = (v) => String(v).split(",").map((s) => s.trim()).filter(Boolean);

// ── 1. ROSTER GUARD — before anything is spawned ─────────────────────────────
// Validate every requested name against the SINGLE source of truth. Exit 2, and
// exit 2 HERE, above every spawn: an unknown name must never reach a browser,
// because ?modal=account will happily paint a real modal on a fallback screen
// and the run will look green.
function rosterGuard() {
  const scens = process.env.SCEN ? list(process.env.SCEN) : DEFAULT_SCEN.slice();
  const themes = process.env.THEME ? list(process.env.THEME) : VALID_THEMES.slice();
  const accent = (process.env.ACCENT || "").trim();
  const problems = [];

  if (scens.length === 0) problems.push("SCEN is set but empty");
  for (const s of scens) {
    if (!Object.prototype.hasOwnProperty.call(SCENARIOS, s)) {
      problems.push(
        `unknown SCEN "${s}" — not a key of scenarios.mjs → SCENARIOS ` +
          `(did you mean one of: ${DEFAULT_SCEN.join(", ")}?)`,
      );
    }
  }
  if (themes.length === 0) problems.push("THEME is set but empty");
  for (const t of themes) {
    if (!VALID_THEMES.includes(t)) {
      problems.push(`unknown THEME "${t}" — expected one of: ${VALID_THEMES.join(", ")}`);
    }
  }
  if (accent && !VALID_ACCENTS.includes(accent)) {
    problems.push(`unknown ACCENT "${accent}" — expected one of: ${VALID_ACCENTS.join(", ")}`);
  }

  if (problems.length) {
    process.stderr.write("!! ROSTER GUARD (exit 2) — refusing to boot Chrome:\n");
    for (const p of problems) process.stderr.write("   • " + p + "\n");
    process.stderr.write(
      "   Why this guard exists: ?modal=account opens the REAL account modal\n" +
        "   regardless of whether the scenario exists, so a typo measures the\n" +
        "   right CSS on the WRONG screen and exits 0. That false green is the\n" +
        "   reason this check runs before any process is spawned.\n",
    );
    process.exit(2);
  }
  return { scens, themes, accent };
}

// ── 2. plumbing ──────────────────────────────────────────────────────────────

// A free TCP port, so parallel runs (and a concurrent shoot.sh on :4180) never
// collide. Chrome's own debug port is chosen by Chrome itself (see below).
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

// The accessSync check MUST cover the CHROME env branch, not only the candidate
// sweep. .github/workflows/console-harness.yml pins CHROME=/usr/bin/google-chrome
// for every console run, so on CI the env branch is the ONLY branch taken — an
// unchecked `return process.env.CHROME` makes the exit-2 "no Chrome" GUARD below
// dead code, and a runner image that drops the binary dies instead with a raw
// `spawn … ENOENT` node stack at exit 1. Exit 1 means "a measured modal defect";
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
    ? `!! GUARD (exit 2): CHROME=${process.env.CHROME} is not an executable file. Environment refusal, not a modal defect.\n`
    : "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n";
}

function httpOk(url) {
  return new Promise((resolve) => {
    const req = http.get(url, (res) => { res.resume(); resolve(res.statusCode === 200); });
    req.on("error", () => resolve(false));
    req.setTimeout(1000, () => { req.destroy(); resolve(false); });
  });
}

// A minimal CDP client over native WebSocket. Flat sessions (sessionId on the
// envelope) — no per-target socket, no event plumbing beyond what we consume.
class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id == null) return; // an event — nothing here subscribes
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

// ── 3. THE ASSERTIONS, as they run inside the page ───────────────────────────
// One expression, returned by value. Everything it measures is reported, pass
// or fail, so a run is readable without re-running it.
const ASSERT_JS = `(function () {
  var out = { failures: [], notes: [] };

  // ── 1. CSSOM BASE-RULE ─────────────────────────────────────────────────────
  // Walk every reachable stylesheet, recursing into grouping rules (@media,
  // @supports) so a rule is never "missing" merely because it is nested.
  var exact = [], substr = 0, unreadable = 0;
  function walk(rules) {
    for (var i = 0; i < rules.length; i++) {
      var r = rules[i];
      if (r.cssRules && r.cssRules.length) walk(r.cssRules);
      if (typeof r.selectorText !== "string") continue;
      if (r.selectorText.indexOf(".modal-root") !== -1) substr++;
      // EXACT — not a substring. The compound :has() variants survive the
      // #4592 defect intact, so a substring test counts 3 and reports green.
      if (r.selectorText.trim() === ".modal-root") exact.push(r);
    }
  }
  var sheets = document.styleSheets;
  for (var s = 0; s < sheets.length; s++) {
    try { walk(sheets[s].cssRules || []); } catch (e) { unreadable++; }
  }
  out.exactRuleCount = exact.length;
  out.substrRuleCount = substr;
  out.unreadableSheets = unreadable;
  out.baseCssText = exact.length ? exact[0].cssText : null;

  if (exact.length === 0) {
    out.failures.push(
      "CSSOM BASE-RULE: no rule with selectorText EXACTLY '.modal-root' survived into " +
      "the CSSOM (" + substr + " rule(s) merely CONTAIN '.modal-root' — the compound " +
      ":has() variants, which parse fine and would make a substring check report GREEN). " +
      "The authored base rule was eaten by CSS error recovery — this is the #4592 mechanism."
    );
  } else if (out.baseCssText.indexOf("position: fixed") === -1) {
    out.failures.push(
      "CSSOM BASE-RULE: '.modal-root' exists but no longer declares position:fixed — " +
      "cssText: " + out.baseCssText
    );
  }

  // ── the modal itself ───────────────────────────────────────────────────────
  var root = document.getElementById("modal-root");
  if (!root) { out.failures.push("STATE: #modal-root is not in the DOM at all"); out.modalOpen = false; return out; }
  var card = root.querySelector(".modal-card");
  out.modalOpen = !root.hidden && !!card;
  if (!out.modalOpen) {
    out.failures.push("STATE: the account modal never opened (#modal-root hidden=" + root.hidden + ", .modal-card=" + !!card + ") — nothing below was measured on a real dialog");
    return out;
  }

  // ── 2. COMPUTED position / overflow-y ──────────────────────────────────────
  var cs = getComputedStyle(root);
  out.computedPosition = cs.position;
  out.computedOverflowY = cs.overflowY;
  if (cs.position !== "fixed") {
    out.failures.push("COMPUTED: #modal-root position is '" + cs.position + "', expected 'fixed' — the dialog is not pinned to the viewport, it flows in the page beneath a fixed backdrop");
  }
  if (cs.overflowY !== "auto") {
    out.failures.push("COMPUTED: #modal-root overflow-y is '" + cs.overflowY + "', expected 'auto' — the root has no scroll path");
  }

  // ── 3. TALL-CARD SCROLL ────────────────────────────────────────────────────
  var cardH = Math.round(card.getBoundingClientRect().height);
  out.cardHeight = cardH;
  out.rootClientHeight = root.clientHeight;
  out.rootScrollHeight = root.scrollHeight;
  out.viewportHeight = window.innerHeight;
  out.tallCard = cardH > window.innerHeight;
  if (out.tallCard) {
    if (root.scrollHeight <= root.clientHeight) {
      out.failures.push(
        "TALL-CARD SCROLL: card is " + cardH + "px in a " + window.innerHeight + "px viewport but " +
        "#modal-root is NOT scrollable (scrollHeight " + root.scrollHeight + " vs clientHeight " +
        root.clientHeight + ") — everything past the fold, including Log out, is permanently unreachable."
      );
    }
  } else {
    out.notes.push("tall-card scroll: N/A (card " + cardH + "px fits the " + window.innerHeight + "px viewport)");
  }

  // ── 4. HIT-TEST + BUTTON REACHABILITY — DOES NOT DETECT #4592 ──────────────
  // Kept for other defect classes. Both of these PASSED under the mutation
  // (.modal-card is position:relative;z-index:1, so it paints above the
  // z-index:auto backdrop regardless of the root), so a red here means
  // something else broke. Never cite it as a #4592 net.
  var cr = card.getBoundingClientRect();
  var px = Math.round(cr.left + cr.width / 2);
  var py = Math.round(Math.max(2, Math.min(window.innerHeight - 2, cr.top + Math.min(cr.height, window.innerHeight) / 2)));
  var hit = document.elementFromPoint(px, py);
  out.hitTestTag = hit ? (hit.tagName.toLowerCase() + (hit.className && typeof hit.className === "string" ? "." + hit.className.trim().split(/\\s+/).join(".") : "")) : null;
  out.hitTestAboveBackdrop = !!(hit && card.contains(hit));
  if (!out.hitTestAboveBackdrop) {
    out.failures.push("HIT-TEST (non-#4592 class): the card's own centre point hit-tests to '" + out.hitTestTag + "', outside .modal-card — something is painting over the dialog");
  }

  var wanted = [];
  var btns = card.querySelectorAll("button, a[href], [role=button]");
  for (var b = 0; b < btns.length; b++) {
    var t = (btns[b].textContent || "").trim();
    if (/^(close|log out|logout)$/i.test(t) || (btns[b].classList && btns[b].classList.contains("modal-x"))) {
      var rb = btns[b].getBoundingClientRect();
      wanted.push({ label: t || "×", w: Math.round(rb.width), h: Math.round(rb.height) });
      if (rb.width <= 0 || rb.height <= 0) {
        out.failures.push("REACHABILITY (non-#4592 class): control '" + (t || "×") + "' has a zero-area box");
      }
    }
  }
  out.controls = wanted;

  return out;
})()`;

// ── 4. the run ───────────────────────────────────────────────────────────────

async function main() {
  const { scens, themes, accent } = rosterGuard();

  const chromeBin = findChrome();
  if (!chromeBin) {
    // Exit 2, not 1: cssom-parity.mjs and overflow-guard.mjs already code this
    // identical condition as a GUARD. A missing browser is a refusal to measure,
    // and must never be laundered into "a modal defect was measured".
    process.stderr.write(chromeGuardLine());
    process.exit(2);
  }

  const port = Number(process.env.PORT || (await freePort()));
  // Allocated PER BRING-UP ATTEMPT below, never once here: a retry into the
  // dead attempt's directory re-races the same DevToolsActivePort path.
  let profile = null;
  const t0 = Date.now();

  let server = null;
  let chrome = null;
  let cdp = null;
  const results = [];
  let teardownMs = 0;

  // ── teardown: hand-bounded, NEVER a blocking wait on a child ───────────────
  const teardown = async () => {
    const td0 = Date.now();
    // (a) ask Chrome politely over CDP, raced against a cap.
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    // (b) poll `kill -0` for the pid to actually vanish. process.kill(pid, 0)
    //     throws ESRCH once it is gone — that is the whole liveness test, and it
    //     never blocks the way `wait` does.
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

  try {
    // ── boot serve.mjs ───────────────────────────────────────────────────────
    server = spawn(process.execPath, [path.join(HERE, "serve.mjs"), "--port", String(port)], {
      stdio: "ignore",
    });
    let up = false;
    for (let w = 0; w < SERVER_UP_CAP; w += 100) {
      if (await httpOk(`http://127.0.0.1:${port}/`)) { up = true; break; }
      await sleep(100);
    }
    if (!up) throw new Error(`preview server never answered on :${port} (port in use? node error?)`);
    // The stale-server guard, CONSUMER SIDE (gr-blk-serve-stale-guard): "the
    // port answers" is not "OUR server answers". If serve.mjs died EADDRINUSE
    // (stdio is ignored here — nobody hears it), the 200 above came from a
    // FOREIGN worktree's squatter and every modal state below would be judged
    // against another tree's bytes. serve.mjs refuses and diagnoses on its own
    // now, but a port-polling consumer must assert tree identity itself.
    // EXIT 2 BY HAND, NOT BY THROW — the enclosing catch maps every throw to
    // exit 1, "a modal defect was measured". A squatted port measured NOTHING
    // about this tree's modals; laundering it into exit 1 is the exact
    // accusation this file's Chrome bring-up refusal already documents.
    for (const rel of ["app.css", "app.js"]) {
      const served = Buffer.from(await (await fetch(`http://127.0.0.1:${port}/${rel}`, { cache: "no-store" })).arrayBuffer());
      const disk = fs.readFileSync(path.join(HERE, "..", rel));
      if (!served.equals(disk)) {
        await teardown();
        process.stderr.write(`\n!! ORACLE (exit 2): REFUSED TO MEASURE — STALE SERVER on :${port}.\n`);
        process.stderr.write(`   /${rel} served ${served.length} B but this tree's disk has ${disk.length} B: a server rooted\n`);
        process.stderr.write(`   at a DIFFERENT tree (a foreign worktree?) is squatting this port. Judging its bytes\n`);
        process.stderr.write(`   would certify the wrong tree — not one modal state was asserted.\n`);
        process.stderr.write(`   Find it: lsof -nP -iTCP:${port} -sTCP:LISTEN\n`);
        process.exit(2);
      }
    }
    process.stdout.write(`>> preview  http://127.0.0.1:${port}\n>> chrome   ${chromeBin}\n`);

    // ── boot Chrome, letting IT pick the debug port (written to
    //    <profile>/DevToolsActivePort) so parallel runs can never collide ─────
    // D101 BRING-UP RETRY (deploy-reliability wave 8). Bounded, a FRESH profile
    // dir per attempt, every failed attempt's Chrome stderr printed.
    //
    // THE LINE THIS RETRY MUST NOT CROSS. cch-w19-bl-gr115's "do not paper over
    // the race" ruling governs exit-1 MEASURED intermittency — the browser came
    // up, the oracle asserted, and it disagreed with itself between runs. This
    // retries only the exit-2 case where Chrome never came up: not one modal
    // state was asserted, so there is no claim for a retry to hide. Everything
    // after `devPort` is a measurement and is never retried.
    let attemptSpawnError = null;
    const brought = await bringUpChrome({
      label: "modal-oracle",
      attempts: BRINGUP_ATTEMPTS,
      newProfile: () => fs.mkdtempSync(path.join(os.tmpdir(), "modal-oracle-")),
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

    // EXIT 2 BY HAND, NOT BY THROW — same reasoning as the font pin below. The
    // enclosing catch maps every throw to process.exit(1), i.e. "a modal defect
    // was measured". A browser that never started measured NOTHING, and
    // laundering that into exit 1 is the exact accusation this wave exists to
    // stop.
    if (brought.refusal) {
      await teardown();
      process.stderr.write(`\n!! ORACLE (exit 2): REFUSED TO MEASURE — ${brought.refusal.message}\n`);
      process.stderr.write(`   Headless Chrome never came up, so NOT ONE modal state was asserted.\n`);
      process.stderr.write(`   Fix the browser in this environment (CHROME=${chromeBin}), then re-run.\n`);
      process.stderr.write(`   teardown ${teardownMs}ms\n`);
      process.exit(2);
    }
    chrome = brought.child;
    profile = brought.profile;
    const devPort = brought.devPort;

    const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    process.stdout.write(`>> ${version.Browser} · node ${process.version}\n`);
    process.stdout.write(`>> ${ORACLE_CI_SCOPE}\n\n`);
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);

    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Runtime.enable", {}, sessionId);
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: VIEW_W, height: VIEW_H, deviceScaleFactor: 1, mobile: false,
    }, sessionId);

    // ── assert each state ────────────────────────────────────────────────────
    for (const scen of scens) {
      for (const theme of themes) {
        const label = `${scen} · ${theme}${accent ? " · " + accent : ""}`;
        const s0 = Date.now();
        const url =
          `http://127.0.0.1:${port}/?scen=${encodeURIComponent(scen)}&theme=${theme}` +
          (accent ? `&accent=${accent}` : "") +
          `&modal=account`;

        await cdp.send("Page.navigate", { url }, sessionId);

        // Wait for the REAL modal, by polling the page — the account modal opens
        // on a click that mock.js drives only after /v1/me paints, so there is no
        // single load event to key on.
        let opened = false;
        for (let w = 0; w < MODAL_CAP; w += 100) {
          const probe = await cdp.send("Runtime.evaluate", {
            expression:
              `(function(){var r=document.getElementById('modal-root');` +
              `return !!(r && !r.hidden && r.querySelector('.modal-card'));})()`,
            returnByValue: true,
          }, sessionId).catch(() => null);
          if (probe && probe.result && probe.result.value === true) { opened = true; break; }
          await sleep(100);
        }
        if (!opened) await sleep(300); // let the assertion report the honest not-open state

        // ── THE FONT PIN (D218) ───────────────────────────────────────────────
        // card= heights, root scroll heights and every clipping verdict below
        // are layouts of whatever face resolved. Pinned AFTER the modal-open
        // poll (the modal must exist before its type matters) and BEFORE the
        // assertion runs.
        //
        // EXIT 2 BY HAND, NOT BY THROW. The enclosing catch maps every throw to
        // process.exit(1) — "a modal defect was measured". A missing woff2 is
        // an ENVIRONMENT fault; laundering it into exit 1 is exactly the
        // confusion this pin exists to end, so the refusal tears down and exits
        // here rather than raising.
        const pin = await cdp.send("Runtime.evaluate", {
          expression: FONT_PIN_JS, returnByValue: true, awaitPromise: true,
        }, sessionId).catch((err) => ({ __cdpError: err }));
        const pinReport = pin && pin.__cdpError === undefined && !pin.exceptionDetails
          ? pin.result.value
          : null;
        if (!pinReport || !pinReport.ok) {
          await teardown();
          process.stderr.write(
            "\n!! ORACLE (exit 2): " + fontPinRefusal(label, pinReport) + "\n",
          );
          process.stderr.write(`   ${ORACLE_CI_SCOPE}\n`);
          process.stderr.write(`   teardown ${teardownMs}ms\n`);
          process.exit(2);
        }

        const evald = await cdp.send("Runtime.evaluate", {
          expression: ASSERT_JS, returnByValue: true, awaitPromise: false,
        }, sessionId);
        if (evald.exceptionDetails) {
          throw new Error(`assertion threw on ${label}: ${evald.exceptionDetails.text}`);
        }
        const r = evald.result.value;
        r.label = label;
        r.ms = Date.now() - s0;
        results.push(r);

        const bad = r.failures.length > 0;
        process.stdout.write(
          `${bad ? "FAIL" : " ok "}  ${label.padEnd(42)} ` +
            `rules exact=${r.exactRuleCount} substr=${r.substrRuleCount} · ` +
            `pos=${r.computedPosition ?? "-"} overflow-y=${r.computedOverflowY ?? "-"} · ` +
            `card=${r.cardHeight ?? "-"}px root=${r.rootScrollHeight ?? "-"}/${r.rootClientHeight ?? "-"} · ` +
            `hit=${r.hitTestAboveBackdrop === undefined ? "-" : r.hitTestAboveBackdrop} · ${r.ms}ms\n`,
        );
        for (const f of r.failures) process.stdout.write(`      ✗ ${f}\n`);
        for (const n of r.notes) process.stdout.write(`      · ${n}\n`);
      }
    }
  } catch (err) {
    await teardown();
    process.stderr.write(`\n!! ORACLE ERROR: ${err && err.message ? err.message : err}\n`);
    process.stderr.write(`   teardown ${teardownMs}ms\n`);
    process.exit(1);
  }

  await teardown();

  const failed = results.filter((r) => r.failures.length > 0);
  const wall = Date.now() - t0;
  process.stdout.write(
    `\n${failed.length ? "ORACLE FAIL" : "ORACLE PASS"} — ${results.length} state(s) asserted, ` +
      `${failed.length} failing · ${(wall / 1000).toFixed(1)}s wall · teardown ${teardownMs}ms\n`,
  );

  if (failed.length) {
    process.stderr.write(`\n!! ${failed.length} of ${results.length} state(s) FAILED:\n`);
    for (const r of failed) {
      process.stderr.write(`   ${r.label}\n`);
      for (const f of r.failures) process.stderr.write(`     ✗ ${f}\n`);
    }
    process.exit(1);
  }
  process.exit(0);
}

main();
