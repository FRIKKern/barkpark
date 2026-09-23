#!/usr/bin/env node
// bidi-isolation.mjs — measured glyph geometry for the two console hosts where
// a USER-authored string and SYSTEM-authored words share one inline run
// (cch-rtl-script-neutral-borrowing).
//
//   activityRow   → .fleet-name     esc(actor email) + " " + verb [+ " · " + esc(name)]
//   memberRowHtml → .set-row-name   esc(email) + " (you)"
//
// cch-w22-s5 dropped the twelve bidi FORMATTING characters inside esc(), which
// killed the override forgery. It could not touch IMPLICIT bidi: an email in
// Arabic or Hebrew letters is strong-RTL by script, and the Unicode Bidi
// Algorithm resolves a NEUTRAL at its edge ("." "-" "!") from the strong text
// on either side. This file measures that in a real browser. A DOM check
// cannot: textContent is logical order by definition.
//
// WHAT THE FIRST RUN FOUND (2026-09-23, Chrome 153, before the <bdi>):
//   • SPAN ORDER HELD ON EVERY ROW. The system's words, and the space between
//     them and the email, never moved. Every system string at these hosts
//     begins and ends in strong-LTR letters ("deleted a site", "(you)"), and in
//     an LTR paragraph a neutral between R and L resolves to L — so no system
//     character can be pulled into the RTL run.
//   • THE BORROWING IS THE USER STRING'S OWN EDGE. A trailing "." on an Arabic
//     IDN email painted on the RIGHT of the RTL run instead of its left end.
//     The PROBE rows show what it borrows from: the same email ALONE in
//     invitationRowHtml's .set-row-name, with no system words at all, paints
//     identically. The neutral resolves against the paragraph's LTR base
//     direction, not against the neighbouring system text.
//   • <bdi> (dir=auto) gives the string its own base direction. That fixes the
//     edge, and it also re-bases a MIXED email: an Arabic local part on a Latin
//     domain paints "acme.com@<arabic>" instead of "<arabic>@acme.com".
//
// HOW IT MEASURES (never innerText):
//   1. app.js is evaluated verbatim in node:vm and the two hosts are called
//      through __bpTestHook, so the markup under test is the shipped markup.
//   2. The rows are mounted in headless Chrome under the real app.css.
//   3. Every code unit of the host gets its own Range; its rect gives its
//      painted x. Painted text = characters sorted by line, then x.
//   4. The same user string is also mounted ALONE in an isolated reference
//      (<bdi>, its own paragraph) — how it paints when nothing borrows from it.
//
// TWO VERDICTS PER ROW:
//   SPAN ORDER  the host splits into maximal user / system spans in DOM order.
//               Painted in the same order, non-overlapping, and every system
//               character left-to-right in DOM order?
//   ISOLATED    does the user string paint EXACTLY as it paints alone in a
//               <bdi> (same left-to-right character sequence)? A neutral at
//               the string's edge that resolved against the surrounding LTR
//               paragraph paints on the other side of the RTL run — this is
//               the borrowing.
//
// Exit 0 = every HOST row holds both verdicts (PROBE rows are printed only).
// Exit 1 = at least one host row does not (the per-row table says which).
// Exit 2 = environment refusal (no Chrome). Exit 3 = the harness itself broke.
//
// Run: node cloud/priv/static/__preview__/bidi-isolation.mjs [--json]
//      CHROME=/path/to/chrome overrides discovery.
//
// ZERO DEPENDENCIES and no WebSocket: CDP rides --remote-debugging-pipe (fd 3
// in, fd 4 out, NUL-framed JSON), so the file runs on the Node major the
// console declares without a runtime flag.

import vm from "node:vm";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATIC = path.join(HERE, "..");
const JSON_OUT = process.argv.includes("--json");

// ── 1. the shipped hosts ─────────────────────────────────────────────────────
function loadHooks() {
  const noop = () => {};
  const el = () => ({
    addEventListener: noop, removeEventListener: noop, setAttribute: noop,
    removeAttribute: noop, getAttribute: () => null,
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    style: {}, hidden: false, value: "", innerHTML: "", textContent: "",
    querySelector: () => null, querySelectorAll: () => [], appendChild: noop,
  });
  const storage = { getItem: () => null, setItem: noop, removeItem: noop };
  const hooks = {};
  const sb = {
    __bpTestHook(h) { Object.assign(hooks, h); },
    document: {
      readyState: "loading", addEventListener: noop, removeEventListener: noop,
      querySelector: () => null, querySelectorAll: () => [], getElementById: () => null,
      createElement: el, documentElement: el(), body: el(),
    },
    window: { addEventListener: noop, removeEventListener: noop, open: () => null,
      matchMedia: () => ({ matches: false, addEventListener: noop }) },
    location: { hash: "", pathname: "/", search: "", origin: "http://localhost" },
    localStorage: storage, sessionStorage: storage, navigator: {},
    URL, URLSearchParams,
    fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }),
    EventSource: function () { return { addEventListener: noop, close: noop }; },
    setTimeout: noop, clearTimeout: noop, setInterval: () => 1, clearInterval: noop,
    console,
  };
  sb.globalThis = sb;
  vm.createContext(sb);
  vm.runInContext(fs.readFileSync(path.join(STATIC, "app.js"), "utf8"), sb);
  for (const k of ["activityRow", "memberRowHtml", "invitationRowHtml"]) {
    if (typeof hooks[k] !== "function") throw new Error(`__bpTestHook does not export ${k}`);
  }
  return hooks;
}

// ── 2. the rows ──────────────────────────────────────────────────────────────
// Every email here is SERVER-LEGAL under @email_format (^[^\s@]+@[^\s@]+$):
// letters of any script, no whitespace, one @. `user` lists the user-authored
// strings in the order they appear in the host's text.
const AR = "مدير";            // Arabic "manager"
const AR_DOM = "شركة.مصر";    // Arabic IDN domain
const HE = "שלום";            // Hebrew
const HE_DOM = "דוגמה.קום";

const ACT = (email, name) => ({
  host: "activity", sel: ".fleet-name",
  row: { actor: { email }, action: "site.deleted", inserted_at: "2026-08-02T00:00:00Z",
    ...(name != null ? { metadata: { name } } : {}) },
  user: name != null ? [email, name] : [email],
});
const MEM = (email) => ({
  host: "member", sel: ".set-row-name",
  row: { user_id: "u1", email, role: "member", joined_at: "2026-01-01T00:00:00Z" },
  ctx: { role: "admin", userId: "u1" },
  user: [email],
});

// PROBE rows are printed, never gated. invitationRowHtml paints an email in
// the SAME .set-row-name class with NO system words beside it — the control
// that separates "borrows from the system's words" from "borrows from the
// paragraph's own LTR base direction". It is not one of the two hosts this
// file guards, so it cannot red the run.
const INV = (email) => ({
  host: "invite", sel: ".set-row-name", probe: true,
  row: { id: "i1", email, role: "member", expires_at: "2026-12-01T00:00:00Z" },
  ctx: { role: "admin" },
  user: [email],
});

const CASES = [
  // control — no RTL script at all; must hold before and after
  { label: "ltr control", ...ACT("ops@acme.com") },
  { label: "ltr control", ...MEM("ops@acme.com") },
  // RTL-script emails
  { label: "arabic local, latin domain", ...ACT(AR + "@acme.com") },
  { label: "arabic local, latin domain", ...MEM(AR + "@acme.com") },
  { label: "arabic idn", ...ACT(AR + "@" + AR_DOM) },
  { label: "arabic idn", ...MEM(AR + "@" + AR_DOM) },
  { label: "hebrew idn", ...ACT(HE + "@" + HE_DOM) },
  { label: "hebrew idn", ...MEM(HE + "@" + HE_DOM) },
  // a trailing neutral inside an all-RTL email — the edge the borrowing is about
  { label: "arabic idn + trailing '.'", ...ACT(AR + "@" + AR_DOM + ".") },
  { label: "arabic idn + trailing '.'", ...MEM(AR + "@" + AR_DOM + ".") },
  { label: "hebrew idn + trailing '-'", ...ACT(HE + "@" + HE_DOM + "-") },
  { label: "hebrew idn + trailing '-'", ...MEM(HE + "@" + HE_DOM + "-") },
  // trailing digits inside an all-RTL email
  { label: "hebrew idn + trailing digits", ...ACT(HE + "@" + HE_DOM + "2") },
  { label: "hebrew idn + trailing digits", ...MEM(HE + "@" + HE_DOM + "2") },
  // the second user span in .fleet-name: the metadata name after " · "
  { label: "rtl email + rtl name", ...ACT(AR + "@" + AR_DOM, "موقع") },
  { label: "rtl email + rtl name ending '!'", ...ACT(HE + "@" + HE_DOM, "אתר!") },
  { label: "latin email + name opening '!'", ...ACT("ops@acme.com", "!אתר") },
  // probes — no system words in the run at all
  { label: "PROBE email alone, arabic idn + trailing '.'", ...INV(AR + "@" + AR_DOM + ".") },
  { label: "PROBE email alone, arabic local, latin domain", ...INV(AR + "@acme.com") },
];

// ── 3. chrome over a pipe ────────────────────────────────────────────────────
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

function launch(bin, profile) {
  const child = spawn(bin, [
    "--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
    "--no-first-run", "--no-default-browser-check", "--disable-extensions",
    "--disable-background-networking", "--hide-scrollbars",
    `--user-data-dir=${profile}`, "--remote-debugging-pipe", "about:blank",
  ], { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
  const toChrome = child.stdio[3], fromChrome = child.stdio[4];
  let seq = 0, buf = "";
  const pending = new Map();
  fromChrome.setEncoding("utf8");
  fromChrome.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\0")) >= 0) {
      const frame = buf.slice(0, i); buf = buf.slice(i + 1);
      let msg; try { msg = JSON.parse(frame); } catch { continue; }
      if (msg.id == null || !pending.has(msg.id)) continue;
      const p = pending.get(msg.id); pending.delete(msg.id);
      msg.error ? p.reject(new Error(p.method + ": " + JSON.stringify(msg.error))) : p.resolve(msg.result);
    }
  });
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++seq;
    const t = setTimeout(() => { pending.delete(id); reject(new Error(method + ": no reply in 20s")); }, 20000);
    pending.set(id, { method, resolve: (r) => { clearTimeout(t); resolve(r); }, reject: (e) => { clearTimeout(t); reject(e); } });
    toChrome.write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
  });
  return { child, send };
}

// ── 4. the in-page measurement ───────────────────────────────────────────────
// Returns, per [data-case] section, the host's characters in DOM order with
// their painted rect, plus the same for the isolated reference of each user
// string.
const MEASURE = `(() => {
  function chars(root) {
    var out = [], w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null), n;
    while ((n = w.nextNode())) {
      for (var i = 0; i < n.data.length; i++) {
        var r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + 1);
        var b = r.getBoundingClientRect();
        out.push({ c: n.data[i], l: b.left, r: b.right, t: Math.round(b.top) });
      }
    }
    return out;
  }
  return Array.prototype.map.call(document.querySelectorAll("[data-case]"), function (s) {
    var host = s.querySelector(s.getAttribute("data-sel"));
    return {
      host: host ? chars(host) : null,
      refs: Array.prototype.map.call(s.querySelectorAll(".bidi-ref"), chars),
    };
  });
})()`;

function painted(cs) {
  return cs.map((x, i) => ({ ...x, i }))
    .filter((x) => x.r > x.l || x.c.trim() !== "")
    .sort((a, b) => a.t - b.t || a.l - b.l || a.i - b.i);
}
const paintedText = (cs) => painted(cs).map((x) => x.c).join("");

function judge(cse, m) {
  const text = m.host.map((x) => x.c).join("");
  // origin mask: user strings located in DOM order
  const user = new Array(text.length).fill(false);
  let from = 0;
  for (const u of cse.user) {
    const at = text.indexOf(u, from);
    if (at < 0) return { text, error: `user string ${JSON.stringify(u)} not found in host text` };
    for (let k = at; k < at + u.length; k++) user[k] = true;
    from = at + u.length;
  }
  // SPAN ORDER
  const spans = [];
  for (let k = 0; k < text.length; k++) {
    if (!spans.length || spans[spans.length - 1].user !== user[k]) spans.push({ user: user[k], idx: [] });
    spans[spans.length - 1].idx.push(k);
  }
  const problems = [];
  const lines = new Set(m.host.map((x) => x.t));
  if (lines.size !== 1) problems.push(`host wrapped onto ${lines.size} lines — widen the stage`);
  let prevRight = -Infinity;
  for (const s of spans) {
    const L = Math.min(...s.idx.map((k) => m.host[k].l));
    const R = Math.max(...s.idx.map((k) => m.host[k].r));
    if (L < prevRight - 0.5) {
      problems.push(`${s.user ? "user" : "system"} span ${JSON.stringify(s.idx.map((k) => text[k]).join(""))} paints at x=${L.toFixed(1)}, left of the previous span's right edge ${prevRight.toFixed(1)}`);
    }
    prevRight = Math.max(prevRight, R);
    if (!s.user) {
      for (let j = 1; j < s.idx.length; j++) {
        const a = m.host[s.idx[j - 1]], b = m.host[s.idx[j]];
        if (b.l < a.l - 0.5) problems.push(`system char ${JSON.stringify(b.c)} (DOM ${s.idx[j]}) paints left of ${JSON.stringify(a.c)} (DOM ${s.idx[j - 1]})`);
      }
    }
  }
  // ISOLATED — the user string's painted sequence in the host vs alone
  const isolation = cse.user.map((u, n) => {
    const idx = [];
    for (let k = 0; k < text.length; k++) if (user[k]) idx.push(k);
    // slice this user string's indices out of the mask, in order
    const mine = idx.slice(cse.user.slice(0, n).reduce((a, s) => a + s.length, 0)).slice(0, u.length);
    const inHost = paintedText(mine.map((k) => m.host[k]));
    const alone = paintedText(m.refs[n]);
    return { user: u, inHost, alone, same: inHost === alone };
  });
  return {
    text, painted: paintedText(m.host),
    spanOrder: problems.length === 0, problems,
    isolation, isolated: isolation.every((x) => x.same),
  };
}

// ── 5. run ───────────────────────────────────────────────────────────────────
async function main() {
  const bin = findChrome();
  if (!bin) {
    process.stderr.write(process.env.CHROME
      ? `!! GUARD (exit 2): CHROME=${process.env.CHROME} is not an executable file.\n`
      : "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n");
    process.exit(2);
  }
  const hooks = loadHooks();
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const sections = CASES.map((c, i) => {
    const markup = c.host === "activity" ? hooks.activityRow(c.row)
      : c.host === "member" ? hooks.memberRowHtml(c.row, c.ctx)
      : hooks.invitationRowHtml(c.row, c.ctx);
    const list = c.host === "activity" ? "fleet-list" : "set-list";
    // The reference: each user string alone, isolated, in its own paragraph.
    const refs = c.user.map((u) => `<div class="bidi-ref-line"><bdi class="bidi-ref">${esc(u)}</bdi></div>`).join("");
    return `<section data-case="${i}" data-sel="${c.sel}"><div class="${list}">${markup}</div>${refs}</section>`;
  }).join("");
  const css = fs.readFileSync(path.join(STATIC, "app.css"), "utf8");
  const html = `<!doctype html><html lang="en" data-theme="light" data-bp-theme="evergreen"><head><meta charset="utf-8">` +
    `<style>${css}</style><style>body{width:1800px} section{margin:8px 0}</style></head><body>${sections}</body></html>`;

  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "bidi-iso-"));
  const page = path.join(profile, "page.html");
  fs.writeFileSync(page, html);
  const { child, send } = launch(bin, profile);
  const cleanup = () => {
    try { child.kill("SIGKILL"); } catch { /* gone */ }
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
  };
  let results;
  try {
    const { targetId } = await send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
    await send("Page.enable", {}, sessionId);
    await send("Emulation.setDeviceMetricsOverride", { width: 1900, height: 1200, deviceScaleFactor: 1, mobile: false }, sessionId);
    await send("Page.navigate", { url: "file://" + page }, sessionId);
    let ready = false;
    for (let k = 0; k < 100 && !ready; k++) {
      const r = await send("Runtime.evaluate", { expression: "document.readyState === 'complete' && document.fonts.status === 'loaded'", returnByValue: true }, sessionId);
      ready = r.result.value === true;
      if (!ready) await new Promise((res) => setTimeout(res, 100));
    }
    if (!ready) throw new Error("page never reached readyState complete");
    const r = await send("Runtime.evaluate", { expression: MEASURE, returnByValue: true }, sessionId);
    if (r.exceptionDetails) throw new Error("measure threw: " + JSON.stringify(r.exceptionDetails));
    const ua = await send("Browser.getVersion");
    results = { browser: ua.product, rows: CASES.map((c, i) => ({ host: c.host, label: c.label, probe: !!c.probe, ...judge(c, r.result.value[i]) })) };
  } finally {
    cleanup();
  }

  if (JSON_OUT) {
    process.stdout.write(JSON.stringify(results, null, 2) + "\n");
  } else {
    process.stdout.write(`bidi-isolation: ${results.browser}, ${results.rows.length} rows, glyph rects per code unit\n`);
    // The scope line browser-axis-census.mjs requires of every console launcher:
    // a Blink green here says nothing about Gecko or WebKit bidi.
    process.stdout.write(">> browser axis  Blink — 1 of 3 engine families (Blink · Gecko · WebKit). A green here is NOT a cross-browser green.\n");
    for (const row of results.rows) {
      const ok = !row.error && row.spanOrder && row.isolated;
      process.stdout.write(`\n${row.probe ? "info" : ok ? "ok  " : "FAIL"} ${row.host.padEnd(8)} ${row.label}\n`);
      if (row.error) { process.stdout.write(`     error   : ${row.error}\n`); continue; }
      process.stdout.write(`     DOM     : ${row.text}\n     painted : ${row.painted}\n`);
      process.stdout.write(`     span order ${row.spanOrder ? "HOLDS" : "BROKEN"}; user text ${row.isolated ? "ISOLATED" : "BORROWED"}\n`);
      for (const p of row.problems) process.stdout.write(`       - ${p}\n`);
      for (const x of row.isolation) if (!x.same) process.stdout.write(`       - ${JSON.stringify(x.user)} paints ${JSON.stringify(x.inHost)} in the row but ${JSON.stringify(x.alone)} alone\n`);
    }
  }
  const gated = results.rows.filter((r) => !r.probe);
  const bad = gated.filter((r) => r.error || !r.spanOrder || !r.isolated).length;
  const brokenOrder = gated.filter((r) => !r.error && !r.spanOrder).length;
  process.stdout.write(`\nbidi-isolation: ${gated.length - bad}/${gated.length} host rows hold both verdicts ` +
    `(span order broken on ${brokenOrder}; ${results.rows.length - gated.length} probe rows not gated)\n`);
  process.exit(bad ? 1 : 0);
}

main().catch((e) => { process.stderr.write("bidi-isolation: " + (e && e.stack || e) + "\n"); process.exit(3); });
