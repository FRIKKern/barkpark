// pin-race.mjs — TWO REAL CHROME TABS, ONE localStorage, one stale team label.
//
// Task: cch-w42-bl-pin-race-needs-a-two-tab-browser-reproduction
//
// ── WHAT IT MEASURES ─────────────────────────────────────────────────────────
// Every claim below is anchored to a FUNCTION and a grep that re-derives it, per
// charter D41 — line numbers rot, and this row exists partly BECAUSE its own
// filing carried rotted ones.
//
//   grep -n 'function api(' cloud/priv/static/app.js
// `api()` re-reads `localStorage.getItem("bp.active-team")` on EVERY request and
// hangs it on the `x-barkpark-team` header. localStorage is shared by every tab
// on an origin.
//
//   grep -n 'localStorage.setItem("bp.active-team"' cloud/priv/static/app.js
// The team switcher (inside `renderTeamMenu`'s `[data-team]` click handler)
// writes that key and then calls `location.reload()` — which reloads ONLY ITS
// OWN TAB.
//
//   grep -n '"storage"' cloud/priv/static/app.js      # EMPTY on origin/main
// Nothing in app.js listens for the `storage` event, and `loadMe()` is not
// called on a route change. So a SECOND tab keeps the team name it cached at
// boot (`setAccountChip(r.data.team, …)` paints `#account-team` once, from the
// boot /v1/me) while every subsequent request it makes carries the OTHER team's
// pin.
//
//   grep -n 'function loadActivity' cloud/priv/static/app.js
// The Activity band is where that becomes a rendered lie: `loadActivity()`
// issues GET /v1/audit through that same `api()` and paints the answer into
// `#activity-body` with NO pin question asked.
//
//   grep -n 'meTeamPinMoved()' cloud/priv/static/app.js
// …and the console ALREADY HAS the question. `meTeamPinMoved()` exists and
// guards THREE other bands (`teamAuthorityState` and its two siblings, each
// returning "stale"). Activity is simply not one of them. The defect is not
// "no mechanism"; it is "one band skipped the mechanism".
//
// ── WHY NOT serve.mjs + mock.js ──────────────────────────────────────────────
// The reproduction needs a server whose GET /v1/audit ANSWERS DIFFERENTLY per
// `x-barkpark-team`. mock.js cannot do that: its fetch shim (mock.js, the
// `window.fetch = function (input, init)` block) forwards only `method` and
// `path` into `scenarios.route(scen, method, path, fixtureState)` — `init.headers`
// is dropped on the floor, so no scenario can see the pin at all. Teaching
// mock.js the header would change the shim every existing scenario runs through.
// This instrument therefore serves the SAME static tree itself (index.html and
// app.js VERBATIM, no injection — asserted byte-for-byte against disk below,
// the modal-oracle stale-server discipline) and answers /v1/* from a
// header-aware fixture. app.js's own `fetch` is untouched: these are real HTTP
// requests carrying the real header app.js built.
//
// ── D432 ─────────────────────────────────────────────────────────────────────
// The charter warns that a shared browser target gets hijacked mid-run, so a
// reading whose provenance is not stamped IN THE SAME EVALUATED OBJECT is not
// evidence. Every reading below is one `Runtime.evaluate` returning ONE object
// that carries `port` (location.port), `role` (the page's own meFlags().role),
// `tab`, `href`, plus the rendered label and rendered rows. Nothing is read in
// a second round trip and correlated afterwards.
//
// ── EXIT VOCABULARY (exit-vocabulary.mjs) ────────────────────────────────────
//   0  MEASURED, CLEAN     both tabs agree — the race did NOT render a mislabel
//   1  MEASURED, DEFECTIVE tab A rendered team Y's audit rows under team X's
//                          label. The bytes are printed and written to the
//                          capture file.
//   2  DID NOT MEASURE     Chrome/port/fixture fault, OR the CONTROL LEG failed
//                          (see below) — no claim in either direction.
//
// ── THE CONTROL LEG ──────────────────────────────────────────────────────────
// A zero-finding is only a measurement if the instrument can be shown capable
// of finding one. Leg CONTROL runs the identical two-tab dance with BOTH tabs
// pinned to the SAME team: tab A must render team X's label over team X's rows.
// If the control disagrees, the fixture/harness is broken and the RACE leg's
// verdict — in EITHER direction — is worthless, so the run refuses (exit 2)
// instead of reporting a clean bill or an accusation.
//
// ── RUN ──────────────────────────────────────────────────────────────────────
//   node cloud/priv/static/__preview__/pin-race.mjs [--json <path>] [--port N]
//   CHROME=/path/to/chrome  overrides the browser (same contract as modal-oracle).
//
// WIRED, as of the PR that closed the race (cch-w42-bl / task-8cc4f7c895c11dad):
// a step of the `modal-oracle` job in .github/workflows/console-harness.yml,
// which is an upstream `needs:` of the REQUIRED `Console gate`, with the same
// 0/1/2 wrapper hashchange-wiring.mjs rides. It was deliberately UNWIRED before
// that: on the pre-fix bytes it exits 1 BY DESIGN, and a job permanently red for
// a defect that is filed rather than regressed teaches a team to ignore it.
//
// THE FIX IT NOW GUARDS is one `storage` listener in app.js's init() delegating
// to the pure `pinStorageMovesTeam` (grep -n 'function pinStorageMovesTeam'
// cloud/priv/static/app.js): a tab whose pin moved under it reloads instead of
// painting. Deleting that mount reds THIS instrument (measured: exit 1, tab A
// back to "Northwind Ops" over Contoso's rows) while every pure test in
// __app.test.mjs stays green — which is exactly why the browser leg is the gate
// and the unit test is not.

import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, ".."); // cloud/priv/static

const argv = process.argv.slice(2);
const argOf = (flag) => { const i = argv.indexOf(flag); return i !== -1 ? argv[i + 1] : null; };
const JSON_OUT = argOf("--json");

const SERVER_UP_CAP = 8000;
const DEVTOOLS_CAP = 12000;
const POLL_CAP = 12000;

const TEAM_X = { id: "team-11111111-1111-1111-1111-111111111111", name: "Northwind Ops", slug: "northwind" };
const TEAM_Y = { id: "team-22222222-2222-2222-2222-222222222222", name: "Contoso Labs", slug: "contoso" };
const USER = { id: "user-9999", email: "ops@northwind.example", confirmed: true, two_factor_enabled: false, platform_operator: false };

// One audit row per team. The MARKER is the actor email, because that is what
// `tlvEntryTitle` actually renders for an audit entry (actor + humanAction) —
// asserting on a metadata.name that only reaches the collapsed <pre> detail
// would be an assertion the visible row cannot fail.
const MARK_X = "x-side@northwind.example";
const MARK_Y = "y-side@contoso.example";
const AUDIT = {
  [TEAM_X.id]: [{
    id: "aud-X-1", action: "site.created", inserted_at: "2026-09-10T09:00:00.000000Z",
    actor: { id: USER.id, email: MARK_X },
    target_type: "site", target_id: "site-X", metadata: { name: "NORTHWIND-ONLY-SITE" },
  }],
  [TEAM_Y.id]: [{
    id: "aud-Y-1", action: "token.minted", inserted_at: "2026-09-10T09:05:00.000000Z",
    actor: { id: USER.id, email: MARK_Y },
    target_type: "site", target_id: "site-Y", metadata: { name: "CONTOSO-ONLY-TOKEN" },
  }],
};

function teamFor(pin) { return pin === TEAM_Y.id ? TEAM_Y : TEAM_X; }

function meFor(pin) {
  const t = teamFor(pin);
  return {
    user: USER,
    team: t,
    teams: [
      { id: TEAM_X.id, name: TEAM_X.name, slug: TEAM_X.slug, role: "admin" },
      { id: TEAM_Y.id, name: TEAM_Y.name, slug: TEAM_Y.slug, role: "admin" },
    ],
    role: "admin",
    team_authority: { team_id: t.id, role: "admin", admin: true, owner: true },
    onboarding: null,
  };
}

const MIME = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8", ".svg": "image/svg+xml",
  ".png": "image/png", ".ico": "image/x-icon", ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8",
};

// The header-aware API. EVERY /v1 answer is derived from the request's OWN
// `x-barkpark-team`, which is precisely what a real server does (router.ex's
// team scope) and precisely what makes the race observable.
function apiAnswer(method, pathname, search, pin) {
  const team = teamFor(pin);
  if (pathname === "/v1/me") return [200, meFor(pin)];
  if (pathname === "/v1/audit") return [200, { events: AUDIT[team.id] }];
  if (/^\/v1\/teams\/[^/]+\/members$/.test(pathname)) {
    return [200, { members: [{ user_id: USER.id, id: USER.id, email: USER.email, role: "admin" }] }];
  }
  if (pathname === "/v1/barkparks") return [200, { barkparks: [] }];
  if (pathname === "/v1/sites") return [200, { sites: [] }];
  if (pathname === "/v1/subscription") return [200, { subscription: null }];
  // Everything else the boot touches: an honest empty object, never a 500 —
  // a boot error state would hide the band this instrument measures.
  return [200, {}];
}

function startServer(port) {
  const server = http.createServer((req, res) => {
    const u = new URL(req.url || "/", "http://127.0.0.1");
    const pathname = u.pathname;

    if (pathname.startsWith("/v1/events")) { // the SSE stream: open and silent
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
      res.write(": preview\n\n");
      return;
    }
    if (pathname.startsWith("/v1/")) {
      const pin = req.headers["x-barkpark-team"] || null;
      const [status, body] = apiAnswer(req.method, pathname, u.search, pin);
      const payload = JSON.stringify(body);
      res.writeHead(status, { "Content-Type": MIME[".json"], "Cache-Control": "no-store" });
      return res.end(payload);
    }

    // Static, VERBATIM. No mock injection — app.js's own fetch does the talking.
    if (pathname === "/" || pathname === "/index.html" || !path.extname(pathname)) {
      let html;
      try { html = fs.readFileSync(path.join(ROOT, "index.html")); }
      catch { res.writeHead(500); return res.end("index.html missing"); }
      res.writeHead(200, { "Content-Type": MIME[".html"], "Cache-Control": "no-store" });
      return res.end(html);
    }
    const abs = path.normalize(path.join(ROOT, decodeURIComponent(pathname)));
    if (abs !== ROOT && !abs.startsWith(ROOT + path.sep)) { res.writeHead(403); return res.end("forbidden"); }
    fs.stat(abs, (err, st) => {
      if (err || !st.isFile()) { res.writeHead(404, { "Cache-Control": "no-store" }); return res.end("not found"); }
      res.writeHead(200, {
        "Content-Type": MIME[path.extname(abs).toLowerCase()] || "application/octet-stream",
        "Cache-Control": "no-store",
      });
      fs.createReadStream(abs).pipe(res);
    });
  });
  return new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(port, "127.0.0.1", () => resolve(server));
  });
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => { const p = srv.address().port; srv.close(() => resolve(p)); });
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

// Minimal CDP client — the modal-oracle shape, flat sessions, native WebSocket.
class Cdp {
  constructor(ws) {
    this.ws = ws; this.seq = 0; this.pending = new Map();
    ws.addEventListener("message", (ev) => {
      let msg; try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id == null) return;
      const p = this.pending.get(msg.id); if (!p) return;
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
      try { this.ws.send(JSON.stringify(frame)); } catch (e) { this.pending.delete(id); reject(e); }
    });
  }
  close() { try { this.ws.close(); } catch { /* gone */ } }
}

// Runs BEFORE app.js in every new document: seeds the session + the team pin,
// and installs the read-only hook app.js offers (`__bpTestHook`) so a reading
// can quote the page's OWN meFlags().role rather than the fixture's.
//
// THE PIN IS SEEDED ONLY WHEN ABSENT, and that is load-bearing. This script
// re-runs on EVERY new document in the target, reload included — an
// unconditional write would silently UNDO the switch the instrument just made
// and the reload leg would measure the pre-switch world while claiming to
// measure the post-switch one.
function bootScript(pin, tab) {
  return `(function () {
    try {
      localStorage.setItem("bpcloud.session", ${JSON.stringify(JSON.stringify({ token: "pin-race-token", user: { id: USER.id } }))});
      if (localStorage.getItem("bp.active-team") == null) localStorage.setItem("bp.active-team", ${JSON.stringify(pin)});
    } catch (e) {}
    globalThis.__bpTab = ${JSON.stringify(tab)};
    globalThis.__bpHooks = null;
    globalThis.__bpTestHook = function (h) { globalThis.__bpHooks = h; };
  })();`;
}

// THE READING. One expression, one object. D432: port + role travel WITH the
// bytes they describe, in the same evaluate, or they are not evidence.
const READ_JS = `(function () {
  var h = globalThis.__bpHooks || {};
  var label = document.getElementById("account-team");
  var body = document.getElementById("activity-body");
  var rows = body ? Array.prototype.map.call(body.querySelectorAll(".tlv-title, .fleet-name, .tl-title"), function (n) {
    return (n.textContent || "").replace(/\\s+/g, " ").trim();
  }) : [];
  return {
    tab: globalThis.__bpTab || null,
    port: location.port,
    href: location.href,
    role: (h.meFlags ? h.meFlags().role : null),
    meState: (h.meState ? h.meState() : null),
    teamAuthorityState: (h.teamAuthorityState ? h.teamAuthorityState() : null),
    meTeamPinMoved: (h.meTeamPinMoved ? h.meTeamPinMoved() : null),
    livePin: (function () { try { return localStorage.getItem("bp.active-team"); } catch (e) { return null; } })(),
    renderedTeamLabel: label ? (label.textContent || "").trim() : null,
    renderedTeamLabelHtml: label ? label.outerHTML : null,
    renderedRows: rows,
    renderedActivityHtml: body ? body.innerHTML : null
  };
})()`;

async function main() {
  const port = Number(argOf("--port")) || (await freePort());
  const chromeBin = findChrome();
  const out = { instrument: "pin-race", startedAt: new Date().toISOString(), port, legs: {} };

  let server = null, chrome = null, profile = null, cdp = null;
  const teardown = async () => {
    if (cdp) cdp.close();
    if (chrome && chrome.pid != null) { try { chrome.kill("SIGKILL"); } catch { /* gone */ } }
    if (server) await new Promise((r) => server.close(r));
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
  };
  const refuse = async (why) => {
    await teardown();
    process.stderr.write("\n!! PIN RACE (exit 2): REFUSED TO MEASURE — " + why + "\n");
    process.stderr.write("   Subject: cloud/priv/static/app.js's cross-tab team pin. NOTHING was judged,\n");
    process.stderr.write("   in either direction. This is not a clean bill and not an accusation.\n");
    process.exitCode = 2;
    return null;
  };

  if (!chromeBin) {
    return refuse(process.env.CHROME
      ? "CHROME=" + process.env.CHROME + " is not an executable file."
      : "no Chrome/Chromium found. Set CHROME=/path/to/chrome.");
  }

  try {
    server = await startServer(port);

    // Stale-server discipline: what the URL answers must be THIS tree's bytes.
    for (const rel of ["app.js", "app.css"]) {
      const served = Buffer.from(await (await fetch("http://127.0.0.1:" + port + "/" + rel, { cache: "no-store" })).arrayBuffer());
      const disk = fs.readFileSync(path.join(ROOT, rel));
      if (!served.equals(disk)) {
        return refuse("/" + rel + " served " + served.length + " B but disk has " + disk.length + " B — a foreign tree owns :" + port + ".");
      }
    }
    out.appJsBytes = fs.statSync(path.join(ROOT, "app.js")).size;
    process.stdout.write(">> server   http://127.0.0.1:" + port + " (app.js " + out.appJsBytes + " B, verbatim)\n");
    process.stdout.write(">> chrome   " + chromeBin + "\n");

    profile = fs.mkdtempSync(path.join(os.tmpdir(), "pin-race-"));
    chrome = spawn(chromeBin, [
      "--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
      "--no-first-run", "--no-default-browser-check", "--disable-extensions",
      "--disable-background-networking", "--user-data-dir=" + profile,
      "--window-size=1440,900", "--remote-debugging-port=0", "about:blank",
    ], { stdio: ["ignore", "ignore", "pipe"] });
    let spawnErr = null;
    chrome.on("error", (e) => { spawnErr = e; });

    let devPort = null;
    for (let w = 0; w < DEVTOOLS_CAP && !spawnErr; w += 100) {
      try {
        const raw = fs.readFileSync(path.join(profile, "DevToolsActivePort"), "utf8").split("\n");
        if (raw[0] && Number(raw[0])) { devPort = Number(raw[0]); break; }
      } catch { /* not written yet */ }
      await sleep(100);
    }
    if (!devPort) return refuse("headless Chrome never published a DevTools port" + (spawnErr ? " (" + (spawnErr.code || spawnErr.message) + ")" : "") + ".");

    const version = await (await fetch("http://127.0.0.1:" + devPort + "/json/version")).json();
    out.browser = version.Browser;
    out.node = process.version;
    process.stdout.write(">> " + version.Browser + " · node " + process.version + "\n\n");
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);

    // ONE browser, ONE default context → ONE localStorage per origin, which is
    // the whole premise. Separate contexts would partition storage and the
    // instrument would measure nothing.
    const openTab = async (tabName, pin) => {
      const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
      const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
      await cdp.send("Page.enable", {}, sessionId);
      await cdp.send("Runtime.enable", {}, sessionId);
      await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: bootScript(pin, tabName) }, sessionId);
      return { targetId, sessionId, tab: tabName };
    };

    const evaluate = async (t, expression) => {
      const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: false }, t.sessionId);
      if (r && r.exceptionDetails) throw new Error("evaluate threw in " + t.tab + ": " + JSON.stringify(r.exceptionDetails));
      return r.result.value;
    };

    const poll = async (t, expression, what) => {
      for (let w = 0; w < POLL_CAP; w += 100) {
        const v = await evaluate(t, expression).catch(() => null);
        if (v === true) return true;
        await sleep(100);
      }
      throw new Error("timed out waiting for " + what + " in " + t.tab);
    };

    // A FRESH DOCUMENT, always. `Page.navigate` to a URL that differs from the
    // current one ONLY in its fragment is a SAME-DOCUMENT navigation: app.js
    // never re-boots, addScriptToEvaluateOnNewDocument never re-runs, and a leg
    // that believes it reloaded measures the page it already had. (Measured, not
    // assumed: the first run of this instrument reported tab B — the tab that
    // DID switch — still rendering the pre-switch team, because its "reload" was
    // a fragment hop.) `Page.reload` is therefore its own verb here, and both
    // wait on a load event rather than on readyState, which for a same-document
    // hop is "complete" before the call even lands.
    const awaitLoad = async (t, fn) => {
      const before = await evaluate(t, 'String(document.documentElement.getAttribute("data-bp-doc") || "")').catch(() => "");
      await fn();
      for (let w = 0; w < POLL_CAP; w += 100) {
        const v = await evaluate(t,
          '(function(){ if (document.readyState !== "complete") return null;' +
          ' if (!document.documentElement.getAttribute("data-bp-doc")) {' +
          '   document.documentElement.setAttribute("data-bp-doc", String(Date.now()) + ":" + Math.random());' +
          ' } return String(document.documentElement.getAttribute("data-bp-doc")); })()',
        ).catch(() => null);
        if (v && v !== before) return;
        await sleep(100);
      }
      throw new Error("timed out waiting for a FRESH document in " + t.tab);
    };
    const navigate = (t, url) => awaitLoad(t, () => cdp.send("Page.navigate", { url }, t.sessionId));
    const reload = (t) => awaitLoad(t, () => cdp.send("Page.reload", { ignoreCache: true }, t.sessionId));

    const ACTIVITY_READY =
      '(function(){var b=document.getElementById("activity-body");' +
      'var l=document.getElementById("account-team");' +
      'return !!b && b.innerHTML.indexOf("Loading activity") === -1 && b.innerHTML.length > 0 ' +
      '&& !!l && l.textContent.trim() !== "My team";})()';

    // ── ONE LEG ──────────────────────────────────────────────────────────────
    // tabAPin: what tab A boots on. tabBPin: what tab B SWITCHES the shared key
    // to (the switcher's own two statements, in order: setItem then reload).
    const runLeg = async (name, tabAPin, tabBPin) => {
      const url = "http://127.0.0.1:" + port + "/#activity";
      const A = await openTab(name + ":tabA", tabAPin);
      await navigate(A, url);
      await poll(A, ACTIVITY_READY, "tab A's first Activity paint");
      const beforeA = await evaluate(A, READ_JS);

      const B = await openTab(name + ":tabB", tabAPin);
      await navigate(B, url);
      await poll(B, ACTIVITY_READY, "tab B's first Activity paint");

      // THE SWITCH, in tab B, exactly as the switcher's own two statements do it
      // (grep -n 'localStorage.setItem("bp.active-team"' ../app.js): setItem, then
      // location.reload().
      await evaluate(B, 'localStorage.setItem("bp.active-team", ' + JSON.stringify(tabBPin) + '); "ok"');
      await reload(B);                 // location.reload()'s effect: TAB B ONLY
      await poll(B, ACTIVITY_READY, "tab B's post-switch Activity paint");
      const afterB = await evaluate(B, READ_JS);

      // TAB A, SAME PAGE LIFE, NO RELOAD. A real user action: the Refresh button.
      await evaluate(A, 'document.getElementById("activity-refresh").click(); "clicked"');
      await sleep(400);
      await poll(A, ACTIVITY_READY, "tab A's refreshed Activity paint");
      const afterA = await evaluate(A, READ_JS);

      await cdp.send("Target.closeTarget", { targetId: A.targetId });
      await cdp.send("Target.closeTarget", { targetId: B.targetId });
      return { name, tabAPin, tabBPin, beforeA, afterB, afterA };
    };

    // ── CONTROL: both tabs on team X. Tab A must stay coherent. ──────────────
    const control = await runLeg("control", TEAM_X.id, TEAM_X.id);
    out.legs.control = control;
    const ctlRows = (control.afterA.renderedRows || []).join(" | ");
    const controlCoherent =
      control.afterA.renderedTeamLabel === TEAM_X.name &&
      ctlRows.indexOf(MARK_X) !== -1 &&
      ctlRows.indexOf(MARK_Y) === -1;
    out.controlCoherent = controlCoherent;
    process.stdout.write("CONTROL (both tabs pinned to " + TEAM_X.name + "), tab A after refresh:\n");
    process.stdout.write(JSON.stringify(control.afterA, null, 2) + "\n\n");
    if (!controlCoherent) {
      out.verdict = "REFUSED";
      if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify(out, null, 2) + "\n");
      return refuse("the CONTROL leg is incoherent — with BOTH tabs on one team, tab A rendered label " +
        JSON.stringify(control.afterA.renderedTeamLabel) + " over rows " + JSON.stringify(ctlRows) +
        ". The fixture cannot tell the teams apart, so the race leg's verdict would be meaningless in EITHER direction.");
    }

    // ── RACE: tab B switches to team Y under tab A's feet. ───────────────────
    const race = await runLeg("race", TEAM_X.id, TEAM_Y.id);
    out.legs.race = race;
    const raceRows = (race.afterA.renderedRows || []).join(" | ");
    const mislabelled =
      race.afterA.renderedTeamLabel === TEAM_X.name &&
      raceRows.indexOf(MARK_Y) !== -1;
    out.verdict = mislabelled ? "REPRODUCED" : "NOT REPRODUCED";

    process.stdout.write("RACE — tab A boot reading (pinned to " + TEAM_X.name + "):\n");
    process.stdout.write(JSON.stringify(race.beforeA, null, 2) + "\n\n");
    process.stdout.write("RACE — tab B after switching the SHARED pin to " + TEAM_Y.name + " and reloading ITSELF:\n");
    process.stdout.write(JSON.stringify(race.afterB, null, 2) + "\n\n");
    process.stdout.write("RACE — tab A after clicking Refresh, SAME page life, NO reload:\n");
    process.stdout.write(JSON.stringify(race.afterA, null, 2) + "\n\n");

    if (JSON_OUT) {
      fs.writeFileSync(JSON_OUT, JSON.stringify(out, null, 2) + "\n");
      process.stdout.write(">> capture written: " + JSON_OUT + "\n");
    }

    await teardown();
    if (mislabelled) {
      process.stdout.write(
        "!! PIN RACE (exit 1): MEASURED, DEFECTIVE.\n" +
        "   Tab A renders the label " + JSON.stringify(race.afterA.renderedTeamLabel) +
        " over " + JSON.stringify(TEAM_Y.name) + "'s audit rows: " + JSON.stringify(raceRows) + "\n" +
        "   port=" + race.afterA.port + " role=" + JSON.stringify(race.afterA.role) +
        " livePin=" + JSON.stringify(race.afterA.livePin) +
        " meTeamPinMoved=" + JSON.stringify(race.afterA.meTeamPinMoved) + "\n" +
        "   The CONTROL leg (both tabs on one team) rendered coherently, so this is the race,\n" +
        "   not a fixture that cannot tell two teams apart.\n",
      );
      process.exitCode = 1;
      return;
    }
    process.stdout.write(
      "-- PIN RACE (exit 0): MEASURED, CLEAN. Tab A's label and rows agree after the switch.\n" +
      "   label=" + JSON.stringify(race.afterA.renderedTeamLabel) + " rows=" + JSON.stringify(raceRows) + "\n",
    );
    process.exitCode = 0;
  } catch (e) {
    if (JSON_OUT) { try { out.error = String(e && e.stack || e); fs.writeFileSync(JSON_OUT, JSON.stringify(out, null, 2) + "\n"); } catch { /* best effort */ } }
    return refuse(String((e && e.message) || e));
  }
}

main();
