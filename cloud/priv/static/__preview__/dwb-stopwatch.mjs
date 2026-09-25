#!/usr/bin/env node
// dwb-stopwatch.mjs — the Deploy-with-Barkpark E2E stopwatch (task dwb-12).
//
// WHAT IT MEASURES. A visitor's journey from the README badge to a live site
// and into Studio, driven in a real headless Chrome over CDP, the way a person
// would do it: real pointer clicks dispatched with Input.dispatchMouseEvent,
// typed text, the real SPA (cloud/priv/static/app.js). It checks four budgets:
//
//   c0  badge -> live site in at most 5 clicks. Every pointer click the script
//       performs is counted and named, the badge click included. A text field
//       costs one click unless the page already focused it (autofocus is free).
//       Typing and Enter are never used to submit: forms are submitted by
//       clicking their button. The project name is labelled optional, so the
//       visitor leaves it blank; if the server refuses that (name_required),
//       the visitor names it and clicks Launch again, and both clicks count.
//       "Live site" is the one-click Vercel deployment
//       when the ready screen offers it (#new-vercel-claim, then the
//       deployment URL answers 200). When the ready screen does not offer it,
//       the milestone falls back to the instance-ready screen and the JSON says
//       so in `live_milestone` — the two are never silently mixed.
//   c1  instance live in at most 90 s at p95 over N runs. Measured from the
//       Launch click to the first sample showing the ready screen (.new-ready),
//       so the SPA's own step pacing counts: it is time the visitor waits.
//       p50 and p95 are nearest-rank over the N per-run values.
//   c2  no bare spinner visible for more than 2 s. The /new tab's DOM is
//       sampled every 100 ms. A spinner is a visible element running an
//       infinite rotate animation, or one whose class names a spinner. It is
//       BARE when no text sits beside it: walking up at most 3 ancestors, each
//       no taller than 240 px, finds no text other than a generic
//       "Loading/Please wait/One moment/Working". The longest continuous
//       stretch with at least one bare spinner on screen is the measurement.
//   c3  Studio entry in exactly 1 click with zero token paste. The script
//       clicks Open Studio once and follows the tab it opens. Studio is
//       entered when that tab lands on a /studio path with no token, API-key
//       or password field on screen. A field like that is a token paste and
//       fails the budget (the script never pastes anything). An interstitial
//       with a "Continue" button is clicked through, at most twice, and each
//       of those clicks is counted, so a 2-click entry fails the budget.
//   c4  "green before public launch" is NOT measured here. It is launch-blocked
//       (gh-1, dwb-2) and needs a live run, which is owner item 52.
//
// MODES.
//   --fixture <name> [--runs N]   offline: the real SPA served from this tree
//                                 by a local stub control plane. No network
//                                 beyond 127.0.0.1.
//   --selftest                    offline: runs every fixture and proves each
//                                 budget's verdict both ways (see ARMS below).
//   --live --host <url>           a real host. OWNER ITEM 52 ONLY — it
//                                 provisions real instances. Refuses to start
//                                 without BOTH flags.
// Common flags: --json <path> (write the verdict JSON), --template <slug>,
// --live-budget-s <n> (default 90; any other value is recorded as scaled),
// --persona signed-in|signed-out|new-visitor.
//
// EXIT CODES. 0 every budget met (selftest: every arm gave its expected
// verdict). 1 a budget failed (selftest: an arm gave the wrong verdict).
// 2 refused: nothing was measured (no Chrome, a squatted port, a flow that
// reached a screen this script cannot drive, a live run without its flags).
//
// BROWSER AXIS: Chrome only (Blink). The run banner says so; a green here is
// not a cross-browser green.

import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { bringUpChrome, captureStderr, BringUpRefusal } from "./bringup-retry.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, ".."); // cloud/priv/static

export const OWNER_ITEM = "owner item 52";
export const BUDGETS = Object.freeze({
  clicks_to_live: 5,
  instance_live_p95_s: 90,
  bare_spinner_s: 2,
  studio_clicks: 1,
  token_pastes: 0,
});

const SAMPLE_MS = 100;
const STEP_CAP_MS = 20000;
const STUDIO_CAP_MS = 10000;
const GENERIC_TEXT = /^(loading|please wait|one moment|working)[\s.…]*$/i;

// ── pure helpers (exported for the self-test and for readers) ────────────────

/** Nearest-rank percentile over numbers; null for an empty list. */
export function percentile(values, p) {
  const xs = values.filter((v) => typeof v === "number" && Number.isFinite(v)).sort((a, b) => a - b);
  if (!xs.length) return null;
  const rank = Math.max(1, Math.ceil((p / 100) * xs.length));
  return xs[rank - 1];
}

/**
 * Longest continuous stretch (ms) in which `present` held, from samples
 * [{t, present}] ordered by t. A stretch runs from its first present sample to
 * its last present sample: the lower bound, so sampling slop never fails a run.
 */
export function longestStretch(samples) {
  let best = 0, start = null, last = null;
  for (const s of samples) {
    if (s.present) {
      if (start === null) start = s.t;
      last = s.t;
      best = Math.max(best, last - start);
    } else {
      start = null;
    }
  }
  return best;
}

/** Grade N runs against the budgets. Returns the criteria block + verdict. */
export function grade(runs, { liveBudgetS = BUDGETS.instance_live_p95_s } = {}) {
  const clicks = runs.map((r) => (r.clicks_to_live == null ? null : r.clicks_to_live));
  const liveS = runs.map((r) => (r.instance_live_ms == null ? null : r.instance_live_ms / 1000));
  const bareS = runs.map((r) => (r.bare_spinner_max_ms || 0) / 1000);
  const studioClicks = runs.map((r) => r.studio && r.studio.clicks);
  const pastes = runs.map((r) => r.studio && r.studio.token_paste_required);

  const liveMeasured = liveS.filter((v) => v != null);
  const p50 = percentile(liveMeasured, 50);
  const p95 = percentile(liveMeasured, 95);
  const allLive = liveMeasured.length === runs.length;

  const criteria = {
    c0_clicks_to_live: {
      budget: BUDGETS.clicks_to_live,
      per_run: clicks,
      measured: clicks.some((c) => c == null) ? null : Math.max(...clicks),
      live_milestone: runs.map((r) => r.live_milestone),
    },
    c1_instance_live: {
      budget_s: liveBudgetS,
      budget_scaled: liveBudgetS !== BUDGETS.instance_live_p95_s,
      n: runs.length,
      per_run_s: liveS.map((v) => (v == null ? null : round(v))),
      p50_s: p50 == null ? null : round(p50),
      p95_s: p95 == null ? null : round(p95),
    },
    c2_bare_spinner: {
      budget_s: BUDGETS.bare_spinner_s,
      per_run_max_s: bareS.map(round),
      measured_s: round(Math.max(0, ...bareS)),
      sample_ms: SAMPLE_MS,
      // The detector's control: samples in which it saw a spinner and found
      // text beside it. Zero across a run that reached the progress screen
      // would mean the detector saw no spinner at all, and its 0 s is vacuous.
      narrated_spinner_samples: runs.reduce((n, r) => n + (r.narrated_spinner_samples || 0), 0),
    },
    c3_studio_entry: {
      budget_clicks: BUDGETS.studio_clicks,
      budget_token_pastes: BUDGETS.token_pastes,
      clicks_per_run: studioClicks,
      token_paste_per_run: pastes,
      entered_per_run: runs.map((r) => !!(r.studio && r.studio.entered)),
    },
  };
  criteria.c0_clicks_to_live.pass = criteria.c0_clicks_to_live.measured != null &&
    criteria.c0_clicks_to_live.measured <= BUDGETS.clicks_to_live;
  criteria.c1_instance_live.pass = allLive && p95 != null && p95 <= liveBudgetS;
  criteria.c2_bare_spinner.pass = criteria.c2_bare_spinner.measured_s <= BUDGETS.bare_spinner_s;
  criteria.c3_studio_entry.pass = runs.every((r) => r.studio && r.studio.entered &&
    r.studio.clicks === BUDGETS.studio_clicks && r.studio.token_paste_required === false);

  const failed = Object.keys(criteria).filter((k) => !criteria[k].pass);
  return { criteria, failed, verdict: failed.length ? "FAIL" : "PASS" };
}

function round(v) { return Math.round(v * 1000) / 1000; }

// ── the stub control plane (offline fixtures) ────────────────────────────────

const TEMPLATES = [{
  slug: "blog-starter",
  title: "Blog starter",
  description: "A blog with posts, authors and tags.",
  what_you_get: ["A managed Barkpark", "Studio", "A Next.js site"],
  deployable: true,
  repo: "https://github.com/example/blog-starter",
  env_keys: ["BARKPARK_URL", "BARKPARK_TOKEN"],
  docs: "https://example.test/docs",
}];

const USER = { id: "user-sw-1", email: "visitor@example.test", confirmed: true, two_factor_enabled: false, platform_operator: false };
const TEAM = { id: "team-sw-1", name: "Stopwatch team", slug: "stopwatch" };

/**
 * FIXTURES. Each is data the stub serves; nothing in the SPA is patched except
 * where a fixture says `inject` (the bare-spinner arm — see below).
 *   persona       signed-in: a session already sits in localStorage.
 *                 signed-out: an existing user logs in on /new.
 *                 new-visitor: a stranger with no account signs up on /new
 *                 (the "Sign up" tab costs a click) — the badge's audience.
 *   server        name-required: POST /v1/launch without a name answers
 *                 422 name_required — the control plane on main today.
 *                 name-defaulted: a nameless launch takes the template's
 *                 title — the behaviour open PR #20270 proposes.
 *   liveAtMs      per run: ms after POST /v1/launch at which the last step
 *                 reports done and the instance gets its host. The other steps
 *                 are already done on the first poll (a warm-pool assign).
 *   studio        ticket: studio-link lands on /studio signed in.
 *                 token: it lands on a page asking to paste an API token.
 *                 interstitial: it lands on a "Continue to Studio" page.
 *   bareSpinnerMs >0: the stub appends a fixture script to index.html that
 *                 shows a text-less spinner on the progress screen for that
 *                 long. The real SPA cannot produce one (every .new-step-spin
 *                 sits in a labelled step row), so the detector's NO arm needs
 *                 a planted one.
 */
const F = { persona: "signed-in", server: "name-defaulted", liveAtMs: [400], studio: "ticket", bareSpinnerMs: 0 };
export const FIXTURES = {
  clean: { ...F },
  "fifth-click": { ...F, server: "name-required" },
  "sixth-click": { ...F, persona: "new-visitor" },
  "slow-live": { ...F, liveAtMs: [400, 400, 10000] },
  "bare-spinner": { ...F, liveAtMs: [4000], bareSpinnerMs: 3000 },
  "token-paste": { ...F, studio: "token" },
  "studio-two-clicks": { ...F, studio: "interstitial" },
};

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8", ".svg": "image/svg+xml",
  ".png": "image/png", ".ico": "image/x-icon", ".woff2": "font/woff2",
};

const BARE_SPINNER_JS = (ms) => `(function () {
  var shown = false;
  var t = setInterval(function () {
    if (shown || !document.querySelector("#new-body .new-progress")) return;
    shown = true; clearInterval(t);
    var st = document.createElement("style");
    st.textContent = "@keyframes fxspin{to{transform:rotate(360deg)}}";
    document.head.appendChild(st);
    var box = document.createElement("div");
    box.id = "fx-bare-spinner";
    box.style.cssText = "position:fixed;top:12px;left:12px;width:24px;height:24px;z-index:99";
    box.innerHTML = '<span style="display:block;width:20px;height:20px;border:3px solid #888;border-top-color:transparent;border-radius:50%;animation:fxspin .7s linear infinite"></span>';
    document.body.appendChild(box);
    setTimeout(function () { box.remove(); }, ${Number(ms) || 0});
  }, 50);
})();`;

function studioPage(title, body) {
  return "<!doctype html><html><head><meta charset=utf-8><title>" + title + "</title></head><body>" + body + "</body></html>";
}

export function createStub(fixture) {
  const state = { bps: new Map(), runIndex: 0, unknown: new Set(), sse: new Set(), launches: 0 };
  const now = () => Date.now();
  const iso = (t) => new Date(t).toISOString();

  function bpView(bp) {
    const t = now();
    const liveAt = bp.createdAt + bp.liveAtMs;
    const base = bp.createdAt;
    const steps = [];
    for (const [i, step] of ["create", "secure", "configure", "content", "verify"].entries()) {
      steps.push({ step, status: "started", at: iso(base - 5000 + i * 800) });
      steps.push({ step, status: "done", at: iso(base - 4600 + i * 800) });
    }
    steps.push({ step: "ready", status: "started", at: iso(base), detail: "Warming the cache" });
    const live = t >= liveAt;
    if (live) steps.push({ step: "ready", status: "done", at: iso(liveAt) });
    return {
      id: bp.id, name: bp.name, template: "blog-starter",
      provision_status: live ? "ready" : "provisioning",
      provision_steps: steps,
      provision_console: [{ at: iso(base), line: "Assigned a warm server" }],
      host: live ? bp.id + ".fixture.test" : null,
      url: live ? "https://" + bp.id + ".fixture.test" : null,
    };
  }

  function broadcastFleet() {
    for (const res of state.sse) { try { res.write('data: {"type":"fleet"}\n\n'); } catch { /* gone */ } }
  }

  function api(req, u, body, port) {
    const p = u.pathname;
    const origin = "http://127.0.0.1:" + port;
    if (p === "/v1/templates") return [200, { templates: TEMPLATES }];
    if (p === "/v1/auth/oauth/providers") return [200, { providers: [] }];
    if (p === "/v1/auth/login" || p === "/v1/auth/register") {
      return [200, { token: "sw-session-token", team_id: TEAM.id, user: USER }];
    }
    if (p === "/v1/auth/sse-ticket") return [200, { ticket: "sw-ticket" }];
    if (p === "/v1/me") {
      return [200, {
        user: USER, team: TEAM, role: "owner",
        teams: [{ id: TEAM.id, name: TEAM.name, slug: TEAM.slug, role: "owner" }],
        team_authority: { team_id: TEAM.id, role: "owner", admin: true, owner: true },
        onboarding: null,
      }];
    }
    if (p === "/v1/launch" && req.method === "POST") {
      const name = body && typeof body.name === "string" ? body.name.trim() : "";
      if (!name && fixture.server === "name-required") return [422, { error: "name_required", message: "Name your project." }];
      const idx = state.runIndex;
      const liveAtMs = fixture.liveAtMs[Math.min(idx, fixture.liveAtMs.length - 1)];
      const id = "bp-sw-" + (++state.launches);
      const bp = { id, name: name || TEMPLATES[0].title, createdAt: now(), liveAtMs };
      state.bps.set(id, bp);
      setTimeout(broadcastFleet, liveAtMs + 5);
      return [201, { barkpark: bpView(bp) }];
    }
    if (p === "/v1/barkparks" && req.method === "GET") {
      return [200, { barkparks: [...state.bps.values()].map(bpView) }];
    }
    let m = p.match(/^\/v1\/barkparks\/([^/]+)\/bootstrap$/);
    if (m) {
      return [200, {
        env: { BARKPARK_URL: "https://" + m[1] + ".fixture.test", BARKPARK_TOKEN: "sw-secret" },
        vercel: { configured: true, deployed: false, claimed: false },
      }];
    }
    if (p === "/v1/github/installation") return [200, { configured: false, connected: false }];
    m = p.match(/^\/v1\/barkparks\/([^/]+)\/vercel-deploy$/);
    if (m && req.method === "POST") {
      return [200, { vercel: {
        configured: true, deployed: true, claimed: false,
        claim_url: origin + "/__vercel/claim?project=" + m[1],
        deployment_url: origin + "/__site/" + m[1],
      } }];
    }
    m = p.match(/^\/v1\/barkparks\/([^/]+)\/studio-link$/);
    if (m && req.method === "POST") {
      if (fixture.studio === "token") return [200, { url: origin + "/__studio/login?from=ticket" }];
      if (fixture.studio === "interstitial") return [200, { url: origin + "/__studio/confirm/" + m[1] }];
      return [200, { url: origin + "/__studio/login/ticket/" + m[1] }];
    }
    state.unknown.add(req.method + " " + p);
    return [200, {}];
  }

  function handler(port) {
    return (req, res) => {
      const u = new URL(req.url || "/", "http://127.0.0.1");
      const p = u.pathname;
      const send = (status, type, payload, extra = {}) => {
        res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store", ...extra });
        res.end(payload);
      };
      if (p.startsWith("/v1/events")) {
        res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
        res.write(": stopwatch fixture\n\n");
        state.sse.add(res);
        req.on("close", () => state.sse.delete(res));
        return;
      }
      if (p.startsWith("/v1/")) {
        let raw = "";
        req.on("data", (c) => { raw += c; });
        req.on("end", () => {
          let body = null;
          try { body = raw ? JSON.parse(raw) : null; } catch { body = null; }
          const [status, out] = api(req, u, body, port);
          send(status, MIME[".json"], JSON.stringify(out));
        });
        return;
      }
      if (p.startsWith("/__site/")) return send(200, MIME[".html"], studioPage("Live site", "<h1>Blog starter</h1><p>Live.</p>"));
      if (p.startsWith("/__vercel/")) return send(200, MIME[".html"], studioPage("Vercel", "<p>Claim</p>"));
      if (p.startsWith("/__studio/login/ticket/")) return send(302, "text/plain", "", { Location: "/__studio/studio" });
      if (p === "/__studio/studio") {
        return send(200, MIME[".html"], studioPage("Studio", '<main data-studio><h1>Studio</h1><p>Signed in as ' + USER.email + "</p></main>"));
      }
      if (p === "/__studio/login") {
        return send(200, MIME[".html"], studioPage("Sign in",
          '<form><label for="api_token">Paste your API token</label><input id="api_token" name="api_token" type="text">' +
          '<button type="submit">Sign in</button></form>'));
      }
      if (p.startsWith("/__studio/confirm/")) {
        return send(200, MIME[".html"], studioPage("Continue",
          '<p>You are about to open Studio.</p><a class="btn" href="/__studio/studio">Continue to Studio</a>'));
      }
      if (p === "/__fixture/bare-spinner.js") return send(200, MIME[".js"], BARE_SPINNER_JS(fixture.bareSpinnerMs));
      if (p === "/" || p === "/index.html" || !path.extname(p)) {
        let html;
        try { html = fs.readFileSync(path.join(ROOT, "index.html"), "utf8"); }
        catch { return send(500, "text/plain", "index.html missing"); }
        if (fixture.bareSpinnerMs > 0) html = html.replace("</body>", '<script src="/__fixture/bare-spinner.js"></script></body>');
        return send(200, MIME[".html"], html);
      }
      const abs = path.normalize(path.join(ROOT, decodeURIComponent(p)));
      if (abs !== ROOT && !abs.startsWith(ROOT + path.sep)) return send(403, "text/plain", "forbidden");
      fs.stat(abs, (err, st) => {
        if (err || !st.isFile()) return send(404, "text/plain", "not found");
        res.writeHead(200, { "Content-Type": MIME[path.extname(abs).toLowerCase()] || "application/octet-stream", "Cache-Control": "no-store" });
        fs.createReadStream(abs).pipe(res);
      });
    };
  }

  return {
    state,
    nextRun() { state.runIndex += 1; },
    async listen(port) {
      const server = http.createServer(handler(port));
      await new Promise((resolve, reject) => { server.on("error", reject); server.listen(port, "127.0.0.1", resolve); });
      return {
        server,
        close: () => new Promise((r) => {
          for (const res of state.sse) { try { res.end(); } catch { /* gone */ } }
          state.sse.clear();
          server.closeAllConnections?.();
          server.close(() => r());
        }),
      };
    },
  };
}

// ── browser plumbing ─────────────────────────────────────────────────────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => { const p = srv.address().port; srv.close(() => resolve(p)); });
  });
}

function findChrome() {
  if (process.env.CHROME) {
    try { fs.accessSync(process.env.CHROME, fs.constants.X_OK); return process.env.CHROME; }
    catch { return null; }
  }
  for (const c of [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium", "/usr/bin/chromium-browser",
  ]) { try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* next */ } }
  return null;
}

class Cdp {
  constructor(ws) {
    this.ws = ws; this.seq = 0; this.pending = new Map(); this.listeners = new Map();
    ws.addEventListener("message", (ev) => {
      let msg; try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id == null) {
        for (const fn of this.listeners.get(msg.method) || []) fn(msg.params || {}, msg.sessionId);
        return;
      }
      const p = this.pending.get(msg.id); if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(p.method + ": " + JSON.stringify(msg.error)));
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
    return () => { const l = this.listeners.get(method); l.splice(l.indexOf(fn), 1); };
  }
  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    const frame = { id, method, params };
    if (sessionId) frame.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      try { this.ws.send(JSON.stringify(frame)); } catch (e) { this.pending.delete(id); reject(e); }
    });
  }
  close() { try { this.ws.close(); } catch { /* gone */ } }
}

async function launchBrowser(chromeBin) {
  const profiles = [];
  const up = await bringUpChrome({
    label: "dwb-stopwatch",
    newProfile: () => { const d = fs.mkdtempSync(path.join(os.tmpdir(), "dwb-stopwatch-")); profiles.push(d); return d; },
    launch: (profile) => {
      const child = spawn(chromeBin, [
        "--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
        "--no-first-run", "--no-default-browser-check", "--disable-extensions",
        "--disable-background-networking", "--disable-popup-blocking",
        "--user-data-dir=" + profile, "--window-size=1280,900",
        "--remote-debugging-port=0", "about:blank",
      ], { stdio: ["ignore", "ignore", "pipe"] });
      return { child, readStderr: captureStderr(child) };
    },
    awaitDevToolsPort: async ({ profile, child }) => {
      for (let w = 0; w < 15000; w += 100) {
        if (child && child.exitCode != null) return null;
        try {
          const raw = fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n");
          if (raw[0] && Number(raw[0])) return Number(raw[0]);
        } catch { /* not yet */ }
        await sleep(100);
      }
      return null;
    },
    abandon: async ({ profile, child }) => {
      if (child && child.exitCode == null) { try { child.kill("SIGKILL"); } catch { /* gone */ } }
      try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
    },
  });
  const version = await (await fetch("http://127.0.0.1:" + up.devPort + "/json/version")).json();
  const cdp = await Cdp.connect(version.webSocketDebuggerUrl);
  return {
    cdp, version,
    async close() {
      cdp.close();
      if (up.child && up.child.exitCode == null) {
        const gone = new Promise((r) => up.child.once("exit", r));
        try { up.child.kill("SIGKILL"); } catch { /* gone */ }
        await Promise.race([gone, sleep(3000)]);
      }
      for (const d of profiles) { try { fs.rmSync(d, { recursive: true, force: true }); } catch { /* best effort */ } }
    },
  };
}

// The in-page sampler. Returns the current screen and every visible spinner,
// each marked bare or narrated. Pure DOM reads; it never changes the page
// except for a data-sw-id tag on spinner elements.
const SAMPLE_JS = `(function () {
  var GENERIC = ${GENERIC_TEXT.toString()};
  var screen = "other";
  if (location.protocol === "data:") screen = "badge";
  else {
    var ns = document.getElementById("new-screen");
    var nb = document.getElementById("new-body");
    if (ns && nb && !ns.hidden) {
      if (nb.querySelector(".new-ready")) screen = "ready";
      else if (nb.querySelector(".new-failed")) screen = "failed";
      else if (nb.querySelector(".new-progress")) screen = "progress";
      else if (nb.querySelector(".new-pricing")) screen = "pricing";
      else if (nb.querySelector("#new-launch-form")) screen = "launch";
      else if (nb.querySelector("[data-new-launch-step]")) screen = "launch-checking";
      else if (nb.querySelector("#new-auth-form")) screen = "auth";
      else if (nb.querySelector("#new-twofa")) screen = "two-factor";
      else if (nb.querySelector(".new-picks")) screen = "picker";
      else if (nb.querySelector(".loading")) screen = "loading";
      else screen = "new-other";
    }
  }
  var set = [];
  var add = function (e) { if (e && e.nodeType === 1 && set.indexOf(e) === -1) set.push(e); };
  try {
    document.getAnimations().forEach(function (a) {
      var eff = a.effect; if (!eff || !eff.target) return;
      var timing = eff.getTiming ? eff.getTiming() : {};
      if (a.playState !== "running" || timing.iterations !== Infinity) return;
      var kf = eff.getKeyframes ? eff.getKeyframes() : [];
      if (kf.some(function (k) { return /rotate/.test(String(k.transform || "")); })) add(eff.target);
    });
  } catch (e) {}
  Array.prototype.forEach.call(document.querySelectorAll('[class*="spin" i], [role="progressbar"]:not([aria-valuenow])'), add);
  var vw = innerWidth, vh = innerHeight;
  var visible = function (el) {
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < vh && r.left < vw;
  };
  var narration = function (el) {
    var node = el.parentElement, depth = 0;
    while (node && depth < 3 && node !== document.body && node !== document.documentElement) {
      if (node.getBoundingClientRect().height > 240) break;
      var txt = String(node.innerText || "").replace(/\\s+/g, " ").trim();
      if (txt && /[A-Za-z]{2,}/.test(txt) && !GENERIC.test(txt)) return txt.slice(0, 80);
      node = node.parentElement; depth++;
    }
    return null;
  };
  var seq = (window.__swSeq = window.__swSeq || 0);
  var spinners = [];
  set.forEach(function (el) {
    if (!visible(el)) return;
    if (!el.getAttribute("data-sw-id")) { seq += 1; el.setAttribute("data-sw-id", String(seq)); }
    var n = narration(el);
    spinners.push({ id: el.getAttribute("data-sw-id"), cls: String(el.className || el.tagName).slice(0, 60), bare: n == null, narration: n });
  });
  window.__swSeq = seq;
  var toastErr = document.querySelector(".toast-error .toast-title");
  return { screen: screen, href: location.href, spinners: spinners,
    toastError: toastErr ? String(toastErr.textContent || "").trim() : null };
})()`;

function badgePageUrl(target) {
  const html = "<!doctype html><html><head><meta charset=utf-8><title>README</title></head><body>" +
    "<h1>blog-starter</h1><p>A template repository README.</p>" +
    '<p><a id="deploy-badge" href="' + target + '" style="display:inline-block;padding:6px 10px;border:1px solid #333">' +
    "Deploy with Barkpark</a></p></body></html>";
  return "data:text/html;charset=utf-8," + encodeURIComponent(html);
}

// ── one journey ──────────────────────────────────────────────────────────────

class RunRefusal extends Error {}

async function runJourney({ cdp, host, template, persona, creds, liveBudgetS, log }) {
  const { browserContextId } = await cdp.send("Target.createBrowserContext", { disposeOnDetach: false });
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank", browserContextId });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await cdp.send("Page.enable", {}, sessionId);
  await cdp.send("Runtime.enable", {}, sessionId);
  const hostOrigin = new URL(host).origin;
  if (persona === "signed-in") {
    const sess = JSON.stringify({ token: creds.sessionToken, team_id: null });
    await cdp.send("Page.addScriptToEvaluateOnNewDocument", {
      source: "(function(){ if (location.origin !== " + JSON.stringify(hostOrigin) + ") return;" +
        " try { if (!localStorage.getItem('bpcloud.session')) localStorage.setItem('bpcloud.session', " + JSON.stringify(sess) + "); } catch (e) {} })();",
    }, sessionId);
  }

  const run = {
    persona, clicks: [], transitions: [], live_milestone: null,
    clicks_to_live: null, instance_live_ms: null, bare_spinner_max_ms: 0,
    worst_bare_spinner: null, narrated_spinner_samples: 0, studio: null, notes: [],
  };
  let t0 = null;
  const rel = () => (t0 == null ? 0 : Date.now() - t0);

  const evaluate = async (expression) => {
    const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (r.exceptionDetails) throw new Error("page threw: " + JSON.stringify(r.exceptionDetails).slice(0, 300));
    return r.result.value;
  };

  // The sampler runs for the whole journey, beside the driver.
  let sampling = true, lastScreen = null, current = { screen: null };
  const bareSamples = [];
  const sampler = (async () => {
    while (sampling) {
      const t = Date.now();
      const s = await evaluate(SAMPLE_JS).catch(() => null);
      if (s) {
        current = s;
        if (t0 != null) {
          if (s.screen !== lastScreen) { run.transitions.push({ screen: s.screen, at_ms: t - t0 }); lastScreen = s.screen; }
          const bare = s.spinners.filter((x) => x.bare);
          if (s.spinners.some((x) => !x.bare)) run.narrated_spinner_samples += 1;
          bareSamples.push({ t, present: bare.length > 0 });
          if (bare.length && !run.worst_bare_spinner) run.worst_bare_spinner = { at_ms: t - t0, screen: s.screen, spinner: bare[0] };
        }
      }
      const wait = SAMPLE_MS - (Date.now() - t);
      if (wait > 0) await sleep(wait);
    }
  })();

  const waitFor = async (what, pred, cap = STEP_CAP_MS) => {
    const end = Date.now() + cap;
    while (Date.now() < end) {
      const s = await evaluate(SAMPLE_JS).catch(() => null);
      if (s) { current = s; const v = pred(s); if (v) return s; }
      if (s && (s.screen === "failed" || s.screen === "pricing" || s.screen === "two-factor")) {
        throw new RunRefusal("the flow reached the '" + s.screen + "' screen while waiting for " + what + " — this script does not drive it");
      }
      await sleep(50);
    }
    throw new RunRefusal("timed out after " + cap + " ms waiting for " + what + " (last screen: " + current.screen + ", " + current.href + ")");
  };

  const waitForExpr = async (what, expr, cap = STEP_CAP_MS) => {
    const end = Date.now() + cap;
    while (Date.now() < end) {
      if (await evaluate(expr).catch(() => false)) return true;
      await sleep(50);
    }
    throw new RunRefusal("timed out after " + cap + " ms waiting for " + what);
  };

  const click = async (selector, label) => {
    const box = await evaluate("(function(){ var e = document.querySelector(" + JSON.stringify(selector) + "); if (!e) return null;" +
      " e.scrollIntoView({block:'center'}); var r = e.getBoundingClientRect(); return {x:r.left + r.width/2, y:r.top + r.height/2, w:r.width, h:r.height}; })()");
    if (!box || !box.w || !box.h) throw new RunRefusal("cannot click " + label + ": " + selector + " is not on screen");
    for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) {
      await cdp.send("Input.dispatchMouseEvent", { type, x: box.x, y: box.y, button: "left", clickCount: type === "mouseMoved" ? 0 : 1 }, sessionId);
    }
    if (t0 == null) t0 = Date.now();
    run.clicks.push({ n: run.clicks.length + 1, label, selector, at_ms: rel() });
    log("   click " + run.clicks.length + "  " + label + "  (+" + rel() + " ms)\n");
  };

  const typeInto = async (selector, label, text) => {
    const focused = await evaluate("document.activeElement === document.querySelector(" + JSON.stringify(selector) + ")");
    if (!focused) await click(selector, label + " field");
    else run.notes.push(label + " field was autofocused — no click");
    await cdp.send("Input.insertText", { text }, sessionId);
  };

  try {
    // Badge page: a README carrying the badge.
    const target = hostOrigin + "/new?template=" + encodeURIComponent(template);
    await cdp.send("Page.navigate", { url: badgePageUrl(target) }, sessionId);
    await waitFor("the README badge", (s) => s.screen === "badge");
    await click("#deploy-badge", "Deploy with Barkpark badge");

    const s1 = await waitFor("the template card", (s) => ["auth", "launch", "launch-checking"].includes(s.screen));
    if (s1.screen === "auth" && persona === "signed-in") {
      throw new RunRefusal("the signed-in persona was shown the sign-in step — the session was not accepted");
    }
    if (s1.screen === "auth") {
      if (persona === "new-visitor") {
        await click("#new-tab-signup", "Sign up tab");
        await waitForExpr("the sign-up form", "(function(){ var b = document.querySelector('#new-auth-submit'); return !!b && /sign up/i.test(b.textContent); })()");
      }
      await typeInto("#new-email", "email", creds.email);
      await typeInto("#new-password", "password", creds.password);
      await click("#new-auth-submit", persona === "new-visitor" ? "Sign up to launch" : "Log in to launch");
    }
    await waitFor("the Launch form", (s) => s.screen === "launch");
    // The name field is labelled "(optional)", so the visitor leaves it blank.
    // If the server refuses the nameless launch, the visitor names the project
    // and clicks Launch again, and both of those clicks count.
    await click("#new-launch-btn", "Launch");
    let launchAt = Date.now();
    const after = await waitFor("the progress screen or a launch refusal",
      (s) => s.screen === "progress" || s.screen === "ready" || (s.screen === "launch" && s.toastError));
    if (after.screen === "launch") {
      run.notes.push("nameless launch refused (" + after.toastError + "); visitor typed a name and retried");
      await waitForExpr("the Launch button to re-enable", "(function(){ var b = document.querySelector('#new-launch-btn'); return !!b && !b.disabled; })()");
      await typeInto("#new-name", "project name", "stopwatch-" + Date.now().toString(36));
      await click("#new-launch-btn", "Launch (again, named)");
      launchAt = Date.now();
    }

    const liveCap = Math.max(30000, liveBudgetS * 3000);
    const ready = await waitFor("the instance-ready screen", (s) => s.screen === "ready", liveCap).catch((e) => {
      if (e instanceof RunRefusal && /timed out/.test(e.message)) { run.notes.push("instance never went live within " + liveCap + " ms"); return null; }
      throw e;
    });
    if (!ready) return finish();
    run.instance_live_ms = Date.now() - launchAt;
    log("   instance live after " + run.instance_live_ms + " ms\n");

    // Live site: the one-click Vercel deployment if offered, else the instance.
    await sleep(300); // the ready screen paints its hand-off block after two reads
    const hasOneClick = await evaluate("!!document.querySelector('#new-vercel-claim:not([disabled])')");
    if (hasOneClick) {
      await click("#new-vercel-claim", "Deploy your site to Vercel");
      const url = await (async () => {
        const end = Date.now() + STEP_CAP_MS;
        while (Date.now() < end) {
          const u = await evaluate("(function(){ var a = document.querySelector('#new-vercel-area a.mono[href]'); return a ? a.href : null; })()").catch(() => null);
          if (u) return u;
          await sleep(50);
        }
        return null;
      })();
      if (!url) throw new RunRefusal("the one-click Vercel deploy never showed a deployment URL");
      const resp = await fetch(url, { redirect: "follow" }).catch((e) => ({ ok: false, status: 0, err: e }));
      if (!resp.ok) throw new RunRefusal("the deployment URL " + url + " answered " + resp.status + " — the site is not live");
      run.live_milestone = "site_deployed";
      run.site_url = url;
    } else {
      run.live_milestone = "instance_ready";
      run.notes.push("the ready screen offered no one-click site deploy; c0 counts clicks to the instance-ready screen");
    }
    run.clicks_to_live = run.clicks.length;
    run.site_live_at_ms = rel();

    run.studio = await enterStudio({ cdp, sessionId, targetId, browserContextId, click, evaluate, log });
    return finish();
  } finally {
    sampling = false;
    await sampler;
    run.bare_spinner_max_ms = longestStretch(bareSamples);
    run.samples = bareSamples.length;
    try { await cdp.send("Target.disposeBrowserContext", { browserContextId }); } catch { /* gone */ }
  }

  function finish() { return run; }
}

async function enterStudio({ cdp, targetId, browserContextId, click, log }) {
  const out = { clicks: 0, token_paste_required: null, entered: false, landed: null, path: [] };
  await cdp.send("Target.setDiscoverTargets", { discover: true });
  let opened = null;
  const off = cdp.on("Target.targetCreated", (p) => {
    const ti = p.targetInfo || {};
    if (ti.type === "page" && ti.openerId === targetId && ti.browserContextId === browserContextId) opened = ti.targetId;
  });
  try {
    await click("#new-open-studio", "Open Studio");
    out.clicks = 1;
    const end = Date.now() + STUDIO_CAP_MS;
    while (!opened && Date.now() < end) await sleep(50);
    if (!opened) { out.note = "Open Studio opened no tab"; return out; }
    const { sessionId: s2 } = await cdp.send("Target.attachToTarget", { targetId: opened, flatten: true });
    await cdp.send("Runtime.enable", {}, s2).catch(() => {});
    const ev = async (expression) => {
      const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true }, s2);
      return r && r.result ? r.result.value : null;
    };
    const READ = `(function () {
      var vis = function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      var fields = Array.prototype.filter.call(document.querySelectorAll("input, textarea"), function (i) {
        if (!vis(i)) return false;
        var lab = i.id ? document.querySelector('label[for="' + i.id + '"]') : null;
        var words = [i.type, i.name, i.id, i.placeholder, i.getAttribute("aria-label"), lab && lab.textContent].join(" ");
        return i.type === "password" || /token|api[ _-]?key|password/i.test(words);
      }).map(function (i) { return i.name || i.id || i.type; });
      var cont = Array.prototype.filter.call(document.querySelectorAll("a, button"), function (b) {
        return vis(b) && /continue|open studio|enter studio/i.test(b.textContent || "");
      }).map(function (b) { return (b.textContent || "").trim(); });
      return { href: location.href, path: location.pathname, ready: document.readyState, fields: fields, cont: cont };
    })()`;
    let follows = 0, stableSince = null, lastHref = null;
    while (Date.now() < end) {
      const r = await ev(READ).catch(() => null);
      if (r && r.ready === "complete" && /^https?:/.test(r.href)) {
        if (r.href !== lastHref) { out.path.push(r.href); lastHref = r.href; stableSince = Date.now(); }
        if (r.fields.length) {
          out.token_paste_required = true; out.landed = r.href; out.fields = r.fields;
          log("   studio  asks for " + r.fields.join(", ") + " at " + r.href + "\n");
          return out;
        }
        if (/\/studio(\/|$)/.test(r.path)) {
          out.entered = true; out.token_paste_required = false; out.landed = r.href;
          log("   studio  entered at " + r.href + " after " + out.clicks + " click(s)\n");
          return out;
        }
        if (r.cont.length && follows < 2 && Date.now() - stableSince > 300) {
          follows += 1;
          const sel = "a, button";
          const clicked = await clickIn(cdp, s2, sel, /continue|open studio|enter studio/i);
          if (clicked) { out.clicks += 1; log("   click   studio interstitial: " + r.cont[0] + "\n"); stableSince = Date.now(); }
        }
      }
      await sleep(100);
    }
    out.note = "Studio was not reached within " + STUDIO_CAP_MS + " ms";
    return out;
  } finally {
    off();
    await cdp.send("Target.setDiscoverTargets", { discover: false }).catch(() => {});
  }
}

async function clickIn(cdp, sessionId, selector, textRe) {
  const r = await cdp.send("Runtime.evaluate", {
    expression: "(function(){ var re = " + textRe.toString() + "; var e = Array.prototype.filter.call(document.querySelectorAll(" +
      JSON.stringify(selector) + "), function (b) { return re.test(b.textContent || ''); })[0]; if (!e) return null;" +
      " var r = e.getBoundingClientRect(); return {x:r.left + r.width/2, y:r.top + r.height/2}; })()",
    returnByValue: true,
  }, sessionId);
  const box = r && r.result && r.result.value;
  if (!box) return false;
  for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) {
    await cdp.send("Input.dispatchMouseEvent", { type, x: box.x, y: box.y, button: "left", clickCount: type === "mouseMoved" ? 0 : 1 }, sessionId);
  }
  return true;
}

// ── orchestration ────────────────────────────────────────────────────────────

async function measure({ browser, host, template, persona, creds, runs, liveBudgetS, stub, log }) {
  const results = [];
  for (let i = 0; i < runs; i++) {
    log(">> run " + (i + 1) + "/" + runs + "  persona=" + persona + "\n");
    const r = await runJourney({ cdp: browser.cdp, host, template, persona, creds, liveBudgetS, log });
    results.push(r);
    if (stub) stub.nextRun();
  }
  return results;
}

function summarize(report) {
  const c = report.criteria;
  const mark = (ok) => (ok ? "PASS" : "FAIL");
  const lines = [];
  lines.push("dwb-stopwatch  " + report.mode + (report.fixture ? " fixture=" + report.fixture : "") + "  host=" + report.host + "  N=" + report.n);
  lines.push("  c0 clicks to live site  " + mark(c.c0_clicks_to_live.pass) + "  measured " + c.c0_clicks_to_live.measured +
    " (budget <= " + c.c0_clicks_to_live.budget + ")  milestone " + [...new Set(c.c0_clicks_to_live.live_milestone)].join("/"));
  lines.push("  c1 instance live        " + mark(c.c1_instance_live.pass) + "  p50 " + c.c1_instance_live.p50_s + " s, p95 " +
    c.c1_instance_live.p95_s + " s over N=" + c.c1_instance_live.n + " (budget p95 <= " + c.c1_instance_live.budget_s + " s" +
    (c.c1_instance_live.budget_scaled ? ", SCALED from 90 s" : "") + ")");
  lines.push("  c2 bare spinner         " + mark(c.c2_bare_spinner.pass) + "  longest " + c.c2_bare_spinner.measured_s +
    " s (budget <= " + c.c2_bare_spinner.budget_s + " s, sampled every " + c.c2_bare_spinner.sample_ms + " ms)");
  lines.push("  c3 Studio entry         " + mark(c.c3_studio_entry.pass) + "  clicks " + JSON.stringify(c.c3_studio_entry.clicks_per_run) +
    ", token paste " + JSON.stringify(c.c3_studio_entry.token_paste_per_run) + " (budget exactly 1 click, 0 pastes)");
  lines.push("  c4 green before launch  NOT MEASURED — launch-blocked; a live run is " + OWNER_ITEM);
  lines.push("  verdict " + report.verdict + (report.failed.length ? "  failed: " + report.failed.join(", ") : ""));
  return lines.join("\n") + "\n";
}

function buildReport({ mode, fixture, host, template, runs, liveBudgetS, browserVersion, unknown }) {
  const g = grade(runs, { liveBudgetS });
  return {
    instrument: "dwb-stopwatch",
    task: "dwb-12",
    mode, fixture: fixture || null, host, template,
    browser: browserVersion, browser_axis: "Blink only (1 of 3 engine families)",
    n: runs.length,
    budgets: { ...BUDGETS, instance_live_p95_s: liveBudgetS },
    budget_scaled: liveBudgetS !== BUDGETS.instance_live_p95_s,
    criteria: g.criteria,
    c4_launch_gate: "not measured: launch-blocked (gh-1, dwb-2); live runs are " + OWNER_ITEM,
    verdict: g.verdict,
    failed: g.failed,
    runs,
    stub_unanswered_paths: unknown ? [...unknown].sort() : undefined,
  };
}

// expectClicks pins c0's measured value on the arms that exist to test it, so
// the boundary is proven at 5 (pass) and 6 (fail), not merely "small" and "big".
export const ARMS = [
  { fixture: "clean", runs: 3, expectFailed: [], expectClicks: 3 },
  { fixture: "fifth-click", runs: 1, expectFailed: [], expectClicks: 5 },
  { fixture: "sixth-click", runs: 1, expectFailed: ["c0_clicks_to_live"], expectClicks: 6 },
  { fixture: "slow-live", runs: 3, expectFailed: ["c1_instance_live"] },
  { fixture: "bare-spinner", runs: 1, expectFailed: ["c2_bare_spinner"] },
  { fixture: "token-paste", runs: 1, expectFailed: ["c3_studio_entry"] },
  { fixture: "studio-two-clicks", runs: 1, expectFailed: ["c3_studio_entry"] },
];

const SELFTEST_LIVE_BUDGET_S = 8;
const FIXTURE_CREDS = { email: "visitor@example.test", password: "correct horse battery", sessionToken: "sw-session-token" };

async function runFixture(browser, name, runs, liveBudgetS, log) {
  const fixture = FIXTURES[name];
  const stub = createStub(fixture);
  const port = await freePort();
  const srv = await stub.listen(port);
  const host = "http://127.0.0.1:" + port;
  try {
    const served = Buffer.from(await (await fetch(host + "/app.js", { cache: "no-store" })).arrayBuffer());
    if (!served.equals(fs.readFileSync(path.join(ROOT, "app.js")))) {
      throw new RunRefusal("/app.js on :" + port + " is not this tree's app.js — a foreign server owns the port");
    }
    const results = await measure({ browser, host, template: "blog-starter", persona: fixture.persona, creds: FIXTURE_CREDS, runs, liveBudgetS, stub, log });
    return buildReport({ mode: "fixture", fixture: name, host, template: "blog-starter", runs: results, liveBudgetS, browserVersion: browser.version.Browser, unknown: stub.state.unknown });
  } finally {
    await srv.close();
  }
}

function parseArgs(argv) {
  const has = (f) => argv.includes(f);
  const val = (f) => { const i = argv.indexOf(f); return i !== -1 ? argv[i + 1] : null; };
  return {
    live: has("--live"), host: val("--host"), selftest: has("--selftest"), fixture: val("--fixture"),
    runs: val("--runs") ? Number(val("--runs")) : null, json: val("--json"),
    template: val("--template") || "blog-starter", persona: val("--persona"),
    liveBudgetS: val("--live-budget-s") ? Number(val("--live-budget-s")) : null,
    help: has("--help") || has("-h"),
  };
}

const refuse = (why) => {
  process.stderr.write("\n!! DWB STOPWATCH (exit 2): REFUSED — " + why + "\n   Nothing was measured, in either direction.\n");
  process.exitCode = 2;
};

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const log = (s) => process.stdout.write(s);
  if (a.help) {
    log("usage: dwb-stopwatch.mjs --selftest | --fixture <" + Object.keys(FIXTURES).join("|") + "> [--runs N] | --live --host <url>\n" +
      "       [--json out.json] [--template slug] [--live-budget-s n] [--persona signed-in|signed-out|new-visitor]\n" +
      "Live runs provision real instances: " + OWNER_ITEM + ".\n");
    return;
  }

  // THE LIVE GUARD. Live mode needs BOTH flags; a host without --live is refused
  // too, so no spelling of the command reaches a real host by accident.
  if (a.live || a.host) {
    log(">> LIVE MODE is " + OWNER_ITEM + ": it provisions real Barkpark instances on the named host.\n");
    if (!a.live || !a.host) return refuse("live mode needs BOTH --live and --host <url> (" + OWNER_ITEM + ").");
    if (a.selftest || a.fixture) return refuse("--live cannot be combined with --selftest or --fixture.");
    let hostUrl;
    try { hostUrl = new URL(a.host); } catch { return refuse("--host " + JSON.stringify(a.host) + " is not a URL."); }
    const persona = a.persona || (process.env.BP_STOPWATCH_SESSION_TOKEN ? "signed-in" : "signed-out");
    const creds = {
      email: process.env.BP_STOPWATCH_EMAIL, password: process.env.BP_STOPWATCH_PASSWORD,
      sessionToken: process.env.BP_STOPWATCH_SESSION_TOKEN,
    };
    if (!["signed-in", "signed-out", "new-visitor"].includes(persona)) return refuse("--persona must be signed-in, signed-out or new-visitor.");
    if (persona !== "signed-in" && !(creds.email && creds.password)) return refuse("a " + persona + " live run needs BP_STOPWATCH_EMAIL and BP_STOPWATCH_PASSWORD.");
    if (persona === "signed-in" && !creds.sessionToken) return refuse("a signed-in live run needs BP_STOPWATCH_SESSION_TOKEN.");
    const chromeBin = findChrome();
    if (!chromeBin) return refuse("no Chrome/Chromium found. Set CHROME=/path/to/chrome.");
    let browser;
    try { browser = await launchBrowser(chromeBin); } catch (e) { return refuse(e instanceof BringUpRefusal ? e.message : String(e)); }
    try {
      const liveBudgetS = a.liveBudgetS || BUDGETS.instance_live_p95_s;
      const results = await measure({ browser, host: hostUrl.origin, template: a.template, persona, creds, runs: a.runs || 5, liveBudgetS, stub: null, log });
      const report = buildReport({ mode: "live", host: hostUrl.origin, template: a.template, runs: results, liveBudgetS, browserVersion: browser.version.Browser });
      return emit(report, a.json, log);
    } catch (e) {
      return refuse(e instanceof RunRefusal ? e.message : (e && e.stack) || String(e));
    } finally { await browser.close(); }
  }

  if (!a.selftest && !a.fixture) return refuse("pick a mode: --selftest, --fixture <name>, or --live --host <url> (" + OWNER_ITEM + ").");
  if (a.fixture && !FIXTURES[a.fixture]) return refuse("unknown fixture " + JSON.stringify(a.fixture) + "; known: " + Object.keys(FIXTURES).join(", "));

  const chromeBin = findChrome();
  if (!chromeBin) return refuse(process.env.CHROME ? "CHROME=" + process.env.CHROME + " is not executable." : "no Chrome/Chromium found. Set CHROME=/path/to/chrome.");
  if (typeof WebSocket !== "function") return refuse("this Node (" + process.version + ") has no global WebSocket; run on Node 22+.");
  let browser;
  try { browser = await launchBrowser(chromeBin); } catch (e) { return refuse(e instanceof BringUpRefusal ? e.message : String(e)); }
  log(">> " + browser.version.Browser + " · node " + process.version + "\n");
  process.stdout.write(">> browser axis  Blink — 1 of 3 engine families (Blink · Gecko · WebKit). A green here is NOT a cross-browser green.\n");
  log(">> offline: the real SPA from " + path.relative(process.cwd(), ROOT) + " behind a stub control plane on 127.0.0.1. No live host is contacted.\n\n");

  try {
    if (a.fixture) {
      const report = await runFixture(browser, a.fixture, a.runs || FIXTURES[a.fixture].liveAtMs.length, a.liveBudgetS || BUDGETS.instance_live_p95_s, log);
      return emit(report, a.json, log);
    }
    // SELFTEST: every arm, each with the verdict it must produce. An arm that
    // passes when it should fail, or fails a budget it should not touch, reds.
    const liveBudgetS = a.liveBudgetS || SELFTEST_LIVE_BUDGET_S;
    const arms = [];
    let bad = 0;
    for (const arm of ARMS) {
      log("== arm " + arm.fixture + " (expect " + (arm.expectFailed.length ? "FAIL " + arm.expectFailed.join(",") : "PASS") + ")\n");
      const report = await runFixture(browser, arm.fixture, arm.runs, liveBudgetS, log);
      log(summarize(report));
      const got = [...report.failed].sort().join(",");
      const want = [...arm.expectFailed].sort().join(",");
      let ok = got === want;
      if (arm.expectClicks != null && report.criteria.c0_clicks_to_live.measured !== arm.expectClicks) {
        ok = false;
        log("   arm WRONG: c0 measured " + report.criteria.c0_clicks_to_live.measured + " click(s), this arm pins " + arm.expectClicks + "\n");
      }
      // The spinner detector must have SEEN the SPA's real (narrated) step
      // spinner on every arm that reached the progress screen, or a 0 s bare
      // reading is a detector that sees nothing.
      if (!(report.criteria.c2_bare_spinner.narrated_spinner_samples > 0)) {
        ok = false;
        log("   arm WRONG: the spinner detector saw no narrated spinner at all — its c2 reading is vacuous\n");
      }
      if (!ok) bad += 1;
      log("   arm " + (ok ? "OK" : "WRONG") + ": expected failed=[" + want + "], got failed=[" + got + "]\n\n");
      arms.push({ fixture: arm.fixture, runs: arm.runs, expect_failed: arm.expectFailed, got_failed: report.failed, ok, report });
    }
    const out = {
      instrument: "dwb-stopwatch", task: "dwb-12", mode: "selftest",
      live_budget_s_scaled_to: liveBudgetS,
      verdict: bad ? "SELFTEST_FAIL" : "SELFTEST_PASS",
      arms: arms.map((x) => ({ fixture: x.fixture, runs: x.runs, expect_failed: x.expect_failed, got_failed: x.got_failed, ok: x.ok, criteria: x.report.criteria })),
      reports: arms.map((x) => x.report),
    };
    if (a.json) fs.writeFileSync(a.json, JSON.stringify(out, null, 2) + "\n");
    log("SELFTEST " + (bad ? "FAIL: " + bad + " arm(s) gave the wrong verdict" : "PASS: " + arms.length + " arms, each budget proven able to pass AND fail") + "\n");
    process.exitCode = bad ? 1 : 0;
  } catch (e) {
    return refuse(e instanceof RunRefusal ? e.message : (e && e.stack) || String(e));
  } finally {
    await browser.close();
  }
}

function emit(report, jsonPath, log) {
  log("\n" + summarize(report));
  const json = JSON.stringify(report, null, 2);
  if (jsonPath) { fs.writeFileSync(jsonPath, json + "\n"); log(">> verdict JSON written: " + jsonPath + "\n"); }
  else log(json + "\n");
  process.exitCode = report.verdict === "PASS" ? 0 : 1;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => { refuse((e && e.stack) || String(e)); });
}
