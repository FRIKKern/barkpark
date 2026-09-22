#!/usr/bin/env node
//
// accent-role-separation.mjs — does the DESTRUCTIVE control stay visibly
// distinct from the PRIMARY control at every accent identity?
//
// WHY THIS EXISTS (task-b96e83407f325986, accent-matrix DEFECT-B)
// ---------------------------------------------------------------
// The 2760-shot accent matrix (console-w10, 2026-09-20) found that at the EMBER
// identity `.btn-primary` and `.btn-danger` render in near-identical warm hues,
// so Delete / Roll back and the primary action were told apart only by
// position. Measured on origin/main 537bca5a0 in a real Chrome at 1440,
// ember/light: primary background rgb(179,78,30), danger background
// rgb(178,54,54) — CIE76 dE 21.0, where the same pair measures 82.9 (fjord),
// 91.7 (evergreen) and 100.1 (iris). A 4-5x outlier.
//
// Both ends of that pair are FIXED BY DOCTRINE — `--primary-hsl`/`--ok-hsl`
// track the brand per identity (GR6) and GR90 ruled in writing that `--ok-hsl`
// is not to be touched, while `--danger-hsl` is pinned at hue 0 — so no hue
// move is available. app.css separates the tiers on WEIGHT instead (solid
// accent fill vs outlined danger object); this instrument is what keeps that
// separation from silently regressing, at EVERY identity rather than at the one
// that happened to collide.
//
// WHAT IT MEASURES, and why nothing else could
// --------------------------------------------
// Per (scenario x accent x theme) cell it loads the real SPA in headless
// Chrome, finds the first visible `.btn-danger` and the first visible
// `.btn-primary`, and reads their COMPUTED `background-color` and
// `border-top-color` — after every var() has resolved through the identity
// cascade. `__css_check.mjs` reads TOKENS and can never see which rule a button
// finally wins; `cssom-parity.mjs` parses declarations, not resolved colours;
// the PNG matrix sees it but only by eye. The separation score of a cell is
//
//     max( dE76(bg_danger, bg_primary), dE76(border_danger, border_primary) )
//
// — a max, deliberately: two controls are distinguishable if EITHER channel
// separates them, and the fix trades background distance for border distance at
// identities where hue already did the work.
//
// Translucent colours are composited onto the element's own painted ancestry
// before the comparison, so a `--danger-soft` tint is scored as what the eye
// actually sees rather than as an alpha triple.
//
// THE FLOOR is 55. It is not a round number picked to pass: the four
// non-colliding identities measured 82.9-100.1 on the pre-fix bytes and the
// post-fix ember cells measure well above 55, while the two cells this task was
// filed for measured 21.0 (light) and 34.7 (dark). 55 sits in the empty gap
// between "the defect" and "every healthy cell", in both directions.
//
// MUTATION PROOF (this instrument reds on the pre-fix bytes): restore
// `git show origin/main:cloud/priv/static/app.css` and re-run — ember/light and
// ember/dark on all three scenarios report MISS.
//
// USAGE
//   node cloud/priv/static/__preview__/accent-role-separation.mjs
//   ACCENTS=ember THEMES=light node .../accent-role-separation.mjs
//   Env: CHROME (binary override) · ACCENTS · THEMES · SCENS · FLOOR
//
// EXIT: 0 every cell clear of the floor · 1 a measured collision ·
//       2 REFUSED to measure (no Chrome, no global WebSocket, dead preview
//         server, a foreign tree squatting the port, a cell whose PRECONDITION
//         never held — one of the two controls never rendered).
//
// NOTE ON RUNTIME: needs a Node with a global `WebSocket` (22+). On Node 20 it
// exits 2 as a REFUSAL, never as a pass — the same contract hashchange-wiring
// carries.

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import net from "node:net";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const VIEW_W = 1440;
const VIEW_H = 900;
const SERVER_UP_CAP = 15000;
const DEVTOOLS_CAP = 20000;
const SETTLE_CAP = 8000;
const FLOOR = Number(process.env.FLOOR || 55);

// The three screens DEFECT-B named, and the identity axis in full — the point
// of the fix is that it holds at all five, not only at the one that collided.
const SCENS = (process.env.SCENS || "webhooks-panel,rollback,shell-site").split(",").filter(Boolean);
const ACCENTS = (process.env.ACCENTS || "evergreen,charple,ember,fjord,iris").split(",").filter(Boolean);
const THEMES = (process.env.THEMES || "light,dark").split(",").filter(Boolean);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── colour maths ────────────────────────────────────────────────────────────
// CIE76 in Lab. Not deltaE2000: this guard needs a stable, auditable number
// that a reader can recompute by hand from the two rgb() strings the log
// prints, and the decision it makes (a 4-5x outlier vs a healthy band) is far
// coarser than the cases where CIE76 and CIE2000 disagree.
export function parseRgb(s) {
  const m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,/\s]+([\d.]+))?\s*\)$/.exec(String(s).trim());
  if (!m) return null;
  return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] };
}

export function composite(fg, bg) {
  if (!fg) return null;
  if (fg.a >= 1) return { r: fg.r, g: fg.g, b: fg.b, a: 1 };
  if (!bg) return null;
  const a = fg.a;
  return {
    r: fg.r * a + bg.r * (1 - a),
    g: fg.g * a + bg.g * (1 - a),
    b: fg.b * a + bg.b * (1 - a),
    a: 1,
  };
}

function srgbToLinear(v) {
  const x = v / 255;
  return x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
}

export function toLab(c) {
  const r = srgbToLinear(c.r), g = srgbToLinear(c.g), b = srgbToLinear(c.b);
  let X = r * 0.4124 + g * 0.3576 + b * 0.1805;
  let Y = r * 0.2126 + g * 0.7152 + b * 0.0722;
  let Z = r * 0.0193 + g * 0.1192 + b * 0.9505;
  X /= 0.95047; Z /= 1.08883;
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  const fx = f(X), fy = f(Y), fz = f(Z);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}

export function deltaE76(a, b) {
  if (!a || !b) return null;
  const A = toLab(a), B = toLab(b);
  return Math.sqrt((A[0] - B[0]) ** 2 + (A[1] - B[1]) ** 2 + (A[2] - B[2]) ** 2);
}

// The cell verdict, kept pure so it is readable and testable without a browser.
// `sample` is the shape the page hands back: {danger:{bg,border}, primary:{bg,border}}
// with every colour already composited to an opaque triple.
export function separation(sample) {
  const bg = deltaE76(sample.danger.bg, sample.primary.bg);
  const border = deltaE76(sample.danger.border, sample.primary.border);
  const channels = [bg, border].filter((v) => v != null);
  if (!channels.length) return null;
  return { bg, border, score: Math.max(...channels) };
}

// ── plumbing (shape shared with hashchange-wiring.mjs / modal-oracle.mjs) ────
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
      if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
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
      this.pending.set(id, { resolve, reject });
      try { this.ws.send(JSON.stringify(frame)); }
      catch (e) { this.pending.delete(id); reject(e); }
    });
  }
  close() { try { this.ws.close(); } catch { /* already gone */ } }
}

// The page-side probe. Composites each control's own background over the
// painted ancestry it actually sits on, so a translucent tint scores as what
// the eye sees. Returned as plain strings; every number is computed in node.
const PROBE = `(() => {
  const vis = (e) => e && e.offsetParent !== null && e.getClientRects().length > 0;
  const pick = (sel) => [...document.querySelectorAll(sel)].find(vis) || null;
  const d = pick(".btn-danger");
  const p = pick(".btn-primary");
  if (!d || !p) return { missing: { danger: !d, primary: !p } };
  const groundOf = (el) => {
    let n = el.parentElement;
    while (n) {
      const c = getComputedStyle(n).backgroundColor;
      const m = /^rgba?\\(\\s*([\\d.]+)[,\\s]+([\\d.]+)[,\\s]+([\\d.]+)(?:[,/\\s]+([\\d.]+))?\\s*\\)$/.exec(c);
      if (m && (m[4] === undefined || Number(m[4]) > 0)) return c;
      n = n.parentElement;
    }
    return getComputedStyle(document.documentElement).backgroundColor;
  };
  const read = (el) => {
    const cs = getComputedStyle(el);
    return { bg: cs.backgroundColor, border: cs.borderTopColor, color: cs.color, ground: groundOf(el), text: (el.textContent || "").trim().slice(0, 32) };
  };
  return { danger: read(d), primary: read(p) };
})()`;

async function main() {
  if (typeof WebSocket === "undefined") {
    process.stderr.write(
      "!! ACCENT ROLE SEPARATION (exit 2): this Node has no global WebSocket " +
        `(${process.version}); CDP is unreachable. Run it on Node 22+. NOTHING was measured.\n`,
    );
    process.exit(2);
  }
  const chromeBin = findChrome();
  if (!chromeBin) {
    process.stderr.write(
      process.env.CHROME
        ? `!! ACCENT ROLE SEPARATION (exit 2): CHROME=${process.env.CHROME} is not an executable file.\n`
        : "!! ACCENT ROLE SEPARATION (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n",
    );
    process.exit(2);
  }

  const port = Number(process.env.PORT || (await freePort()));
  let server = null, chrome = null, cdp = null, profile = null;

  const teardown = async () => {
    if (cdp) { await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(2000)]); cdp.close(); }
    for (const proc of [chrome, server]) {
      if (proc && proc.pid != null) { try { proc.kill("SIGKILL"); } catch { /* gone */ } }
    }
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
  };
  const refuse = async (lines) => {
    await teardown();
    process.stderr.write("\n!! ACCENT ROLE SEPARATION (exit 2): REFUSED TO MEASURE\n");
    for (const l of lines) process.stderr.write("   " + l + "\n");
    process.exit(2);
  };

  try {
    server = spawn(process.execPath, [path.join(HERE, "serve.mjs"), "--port", String(port)], { stdio: "ignore" });
    let up = false;
    for (let w = 0; w < SERVER_UP_CAP; w += 100) {
      if (await httpOk(`http://127.0.0.1:${port}/`)) { up = true; break; }
      await sleep(100);
    }
    if (!up) await refuse([`preview server never answered on :${port}. Not one cell was measured.`]);

    // Stale-server guard, consumer side: "the port answers" is not "OUR server
    // answers". app.css IS the artifact under test here, so judging a foreign
    // worktree's bytes would certify the wrong tree.
    for (const rel of ["app.css", "app.js"]) {
      const served = Buffer.from(await (await fetch(`http://127.0.0.1:${port}/${rel}`, { cache: "no-store" })).arrayBuffer());
      const disk = fs.readFileSync(path.join(HERE, "..", rel));
      if (!served.equals(disk)) {
        await refuse([
          `STALE SERVER on :${port}.`,
          `/${rel} served ${served.length} B but this tree's disk has ${disk.length} B — a server rooted at a`,
          "DIFFERENT tree is squatting this port, and app.css IS the artifact under test.",
          `Find it: lsof -nP -iTCP:${port} -sTCP:LISTEN`,
        ]);
      }
    }

    const { SCENARIOS } = await import(path.join(HERE, "scenarios.mjs"));
    const unknown = SCENS.filter((s) => !SCENARIOS[s]);
    if (unknown.length) await refuse([`unknown scenario name(s): ${unknown.join(", ")}`]);

    profile = fs.mkdtempSync(path.join(os.tmpdir(), "accent-role-separation-"));
    chrome = spawn(chromeBin, [
      "--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
      "--no-first-run", "--no-default-browser-check", "--disable-extensions",
      "--disable-background-networking", `--user-data-dir=${profile}`,
      `--window-size=${VIEW_W},${VIEW_H}`, "--remote-debugging-port=0", "about:blank",
    ], { stdio: ["ignore", "ignore", "pipe"] });
    let devPort = null;
    for (let w = 0; w < DEVTOOLS_CAP; w += 100) {
      try {
        const raw = fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n");
        if (raw[0] && Number(raw[0])) { devPort = Number(raw[0]); break; }
      } catch { /* not written yet */ }
      await sleep(100);
    }
    if (!devPort) await refuse([`headless Chrome never published a DevTools port (${chromeBin}). Not one cell was measured.`]);

    const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    process.stdout.write(`>> preview  http://127.0.0.1:${port}\n>> chrome   ${chromeBin}\n>> ${version.Browser} · node ${process.version}\n`);
    process.stdout.write(`>> floor    dE76 ${FLOOR} · cells ${SCENS.length}x${ACCENTS.length}x${THEMES.length} = ${SCENS.length * ACCENTS.length * THEMES.length} at ${VIEW_W}px\n\n`);
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);

    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Runtime.enable", {}, sessionId);
    await cdp.send("Emulation.setDeviceMetricsOverride", { width: VIEW_W, height: VIEW_H, deviceScaleFactor: 1, mobile: false }, sessionId);

    const evaluate = async (expression) => {
      const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true }, sessionId);
      if (r.exceptionDetails) throw new Error("page threw: " + r.exceptionDetails.text);
      return r.result.value;
    };

    const misses = [];
    const blind = [];
    let measured = 0;

    for (const accent of ACCENTS) {
      for (const theme of THEMES) {
        for (const scen of SCENS) {
          const s = SCENARIOS[scen];
          const url =
            `http://127.0.0.1:${port}${s.pathname || "/"}?scen=${encodeURIComponent(scen)}` +
            `&theme=${theme}&accent=${accent}${s.search || ""}${s.deepLink || ""}`;
          await cdp.send("Page.navigate", { url }, sessionId);

          let probe = null;
          for (let w = 0; w < SETTLE_CAP; w += 150) {
            await sleep(150);
            probe = await evaluate(PROBE).catch(() => null);
            if (probe && !probe.missing) break;
          }
          const cell = `${scen} · ${accent} · ${theme}`;
          if (!probe || probe.missing) {
            // A cell whose PRECONDITION never held measured NOTHING. It is never
            // silently counted as a pass — a guard whose subject never arrived
            // is a green with no subject.
            blind.push(`${cell} — ${!probe ? "probe threw" : `no visible ${probe.missing.danger ? ".btn-danger" : ""}${probe.missing.danger && probe.missing.primary ? " and " : ""}${probe.missing.primary ? ".btn-primary" : ""}`}`);
            continue;
          }
          const opaque = (role) => ({
            bg: composite(parseRgb(probe[role].bg), parseRgb(probe[role].ground)),
            border: composite(parseRgb(probe[role].border), parseRgb(probe[role].ground)),
          });
          const sep = separation({ danger: opaque("danger"), primary: opaque("primary") });
          measured += 1;
          if (!sep || sep.score < FLOOR) {
            misses.push(
              `${cell}\n` +
                `      danger  "${probe.danger.text}"  bg ${probe.danger.bg}  border ${probe.danger.border}\n` +
                `      primary "${probe.primary.text}"  bg ${probe.primary.bg}  border ${probe.primary.border}\n` +
                `      dE76 background ${sep && sep.bg != null ? sep.bg.toFixed(1) : "n/a"} · border ${sep && sep.border != null ? sep.border.toFixed(1) : "n/a"} · SCORE ${sep ? sep.score.toFixed(1) : "n/a"} < floor ${FLOOR}`,
            );
            process.stdout.write(`!! ${cell}  score ${sep ? sep.score.toFixed(1) : "n/a"}\n`);
          } else {
            process.stdout.write(`ok ${cell}  score ${sep.score.toFixed(1)} (bg ${sep.bg.toFixed(1)} / border ${sep.border.toFixed(1)})\n`);
          }
        }
      }
    }

    if (blind.length) {
      await refuse([
        "a cell's PRECONDITION never held — one of the two controls never rendered, so that cell",
        "measured NOTHING and is not being reported as a pass:",
        ...blind.map((b) => "  " + b),
        `(${measured} other cell(s) DID measure; re-run once the scenario renders both controls.)`,
      ]);
    }

    await teardown();
    if (misses.length) {
      process.stderr.write(`\n!! ACCENT ROLE SEPARATION (exit 1): ${misses.length} of ${measured} cell(s) below the dE76 ${FLOOR} floor\n`);
      for (const m of misses) process.stderr.write("   " + m + "\n");
      process.stderr.write(
        "\n   The destructive control and the primary control are not visually separable in those\n" +
          "   cells. The remedy is NOT a hue move: --primary-hsl/--ok-hsl track the brand per identity\n" +
          "   (GR6) and --danger-hsl is pinned at hue 0, so the separation has to come off the weight\n" +
          "   axis — see the .btn-danger block in app.css for the ruling and the measurements.\n",
      );
      process.exit(1);
    }
    process.stdout.write(`\n>> CLEAN — ${measured}/${measured} cells at or above dE76 ${FLOOR}.\n`);
    process.exit(0);
  } catch (err) {
    await teardown();
    process.stderr.write(`\n!! ACCENT ROLE SEPARATION (exit 1): ${err && err.stack ? err.stack : err}\n`);
    process.exit(1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  main();
}
