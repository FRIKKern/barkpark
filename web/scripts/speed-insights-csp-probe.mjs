#!/usr/bin/env node
// speed-insights-csp-probe.mjs — does @vercel/speed-insights inject its runtime
// script under the enforcing nonce + 'strict-dynamic' CSP WITHOUT a violation?
// (task arpss-consumer-speedinsights-strict-dynamic-browser-proof)
//
// WHY A BROWSER. SpeedInsights is a client component: its <script> is created
// by React at hydration, so it is ABSENT from the SSR HTML and invisible to
// curl. The static leg (every SSR <script> is nonced) is pinned elsewhere
// (__tests__/csp.test.ts, consumer-csp-parity.test.ts). This is the runtime
// leg: under `script-src 'self' 'nonce-…' 'strict-dynamic'` a CSP3 browser
// IGNORES 'self', so the injected script is allowed ONLY by strict-dynamic's
// trust propagation from the nonced Next chunks that create it. Nothing else
// in the tree asserts that propagation actually happens.
//
// WHAT IT DOES. Boots the BUILT app (`next start`, so run `pnpm build` first)
// on a free port, drives headless Chrome over raw CDP (no playwright), loads a
// route that renders the root layout (an unknown path -> not-found, which needs
// no Barkpark API), waits for hydration, then asserts:
//   1. the response carries an enforcing CSP with a nonce and 'strict-dynamic';
//   2. a <script src=…speed-insights…> element exists in the live DOM;
//   3. the browser ISSUED that request and did not block it (no
//      Network.loadingFailed with blockedReason "csp" for it);
//   4. ZERO `securitypolicyviolation` events and zero CSP console errors.
// A 404 for the script itself is expected off-Vercel (/_vercel/… is served by
// the platform) and is not a CSP fact; only a CSP block fails the probe.
//
// EXIT CODES: 0 all assertions pass · 1 an assertion failed (a product fact) ·
// 2 environment (no build, no Chrome, server never came up).
//
// Usage (from web/):  pnpm build && node scripts/speed-insights-csp-probe.mjs
//   CHROME=/path/to/chrome overrides the browser.

import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const children = [];

function guard(msg) {
  process.stderr.write(`!! GUARD (exit 2): ${msg}\n`);
  cleanup();
  process.exit(2);
}

function cleanup() {
  for (const c of children) {
    try { c.kill("SIGKILL"); } catch { /* gone */ }
  }
}

function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
    s.on("error", reject);
  });
}

function findChrome() {
  const candidates = [
    process.env.CHROME,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ].filter(Boolean);
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* next */ }
  }
  return null;
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    this.listeners = [];
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const p = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(JSON.stringify(msg.error)));
        else p.resolve(msg.result);
      } else if (msg.method) {
        for (const fn of this.listeners) fn(msg);
      }
    });
  }

  static async connect(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
      ws.addEventListener("open", resolve, { once: true });
      ws.addEventListener("error", () => reject(new Error(`CDP connect failed: ${url}`)), { once: true });
    });
    return new Cdp(ws);
  }

  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
}

async function main() {
  if (!fs.existsSync(path.join(WEB, ".next", "BUILD_ID"))) guard("no production build — run `pnpm build` in web/ first");
  const chromeBin = findChrome();
  if (!chromeBin) guard("no Chrome found (set CHROME=/path/to/chrome)");

  // ── the app ──────────────────────────────────────────────────────────────
  const port = await freePort();
  const nextBin = path.join(WEB, "node_modules", ".bin", "next");
  if (!fs.existsSync(nextBin)) guard("web/node_modules missing — run `pnpm install` in web/");
  const server = spawn(nextBin, ["start", "-p", String(port), "-H", "127.0.0.1"], {
    cwd: WEB,
    env: { ...process.env, NEXT_TELEMETRY_DISABLED: "1" },
    stdio: ["ignore", "ignore", "pipe"],
  });
  children.push(server);
  const base = `http://127.0.0.1:${port}`;
  const probePath = "/__csp-runtime-probe"; // must NOT itself match /speed-insights/
  let up = false;
  for (let i = 0; i < 120 && !up; i++) {
    try { await fetch(base + "/robots.txt"); up = true; } catch { await sleep(250); }
  }
  if (!up) guard(`next start never answered on ${base}`);

  const head = await fetch(base + probePath);
  const policy = head.headers.get("content-security-policy") || "";
  const scriptSrc = (policy.split(";").find((d) => d.trim().startsWith("script-src")) || "").trim();

  // ── the browser ──────────────────────────────────────────────────────────
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "si-csp-probe-"));
  const chrome = spawn(chromeBin, [
    "--headless=new", "--disable-gpu", "--no-sandbox", "--no-first-run",
    "--no-default-browser-check", "--disable-extensions", "--disable-background-networking",
    `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank",
  ], { stdio: ["ignore", "ignore", "ignore"] });
  children.push(chrome);
  let devPort = null;
  for (let i = 0; i < 150 && !devPort; i++) {
    try {
      const n = Number(fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n")[0]);
      if (n) devPort = n;
    } catch { await sleep(100); }
  }
  if (!devPort) guard("Chrome never wrote DevToolsActivePort");
  const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
  const cdp = await Cdp.connect(version.webSocketDebuggerUrl);
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });

  const blocked = [];
  const requested = new Map();
  const consoleCsp = [];
  cdp.listeners.push((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === "Network.requestWillBeSent") requested.set(msg.params.requestId, msg.params.request.url);
    if (msg.method === "Network.loadingFailed" && msg.params.blockedReason) {
      blocked.push({ url: requested.get(msg.params.requestId), reason: msg.params.blockedReason });
    }
    if (msg.method === "Log.entryAdded" && /Content Security Policy/i.test(msg.params.entry.text)) {
      consoleCsp.push(msg.params.entry.text);
    }
  });
  for (const m of ["Network.enable", "Log.enable", "Page.enable", "Runtime.enable"]) await cdp.send(m, {}, sessionId);
  await cdp.send("Page.addScriptToEvaluateOnNewDocument", {
    source: "window.__cspv=[];document.addEventListener('securitypolicyviolation',e=>window.__cspv.push({d:e.violatedDirective,u:e.blockedURI}));",
  }, sessionId);
  await cdp.send("Page.navigate", { url: base + probePath }, sessionId);
  await sleep(6000); // hydration + the component's injection effect

  const evalJson = async (expr) => {
    const r = await cdp.send("Runtime.evaluate", { expression: `JSON.stringify(${expr})`, returnByValue: true }, sessionId);
    return JSON.parse(r.result.value);
  };
  const siScripts = await evalJson("[...document.querySelectorAll('script[src]')].map(s=>s.src).filter(s=>/speed-insights/.test(s))");
  const violations = await evalJson("window.__cspv||[]");
  const siRequested = [...requested.values()].filter((u) => /speed-insights/.test(u || ""));
  const siBlocked = blocked.filter((b) => /speed-insights/.test(b.url || "") && /csp/i.test(b.reason));

  // ── verdict ──────────────────────────────────────────────────────────────
  const checks = [
    ["response CSP is enforcing with a nonce and 'strict-dynamic'",
      /'nonce-[^']+'/.test(scriptSrc) && scriptSrc.includes("'strict-dynamic'"), scriptSrc || "(no CSP header)"],
    ["SpeedInsights injected its <script> at runtime", siScripts.length > 0, JSON.stringify(siScripts)],
    ["the browser issued the SpeedInsights request", siRequested.length > 0, JSON.stringify(siRequested)],
    ["no CSP block on the SpeedInsights request", siBlocked.length === 0, JSON.stringify(siBlocked)],
    ["zero securitypolicyviolation events on the page", violations.length === 0, JSON.stringify(violations)],
    ["zero CSP console errors", consoleCsp.length === 0, JSON.stringify(consoleCsp.slice(0, 3))],
  ];
  let failed = 0;
  for (const [name, ok, detail] of checks) {
    if (!ok) failed++;
    process.stdout.write(`${ok ? "PASS" : "FAIL"}  ${name}\n      ${detail}\n`);
  }
  await cdp.send("Browser.close").catch(() => {});
  cleanup();
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
  process.stdout.write(failed ? `\n${failed} check(s) FAILED\n` : "\nALL PASS\n");
  process.exit(failed ? 1 : 0);
}

process.on("SIGINT", () => { cleanup(); process.exit(130); });
main().catch((e) => guard(e.stack || String(e)));
