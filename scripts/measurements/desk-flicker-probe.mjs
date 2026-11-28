#!/usr/bin/env node
// desk-flicker-probe.mjs — what the desk's panes show, frame by frame, while
// panes open and close (task-32a5956065c81200: "the next pane flickers for a
// moment with content").
//
// It drives a running desk (/_desk) in headless Chrome, records every pane on
// each animation frame, and checks four things after each click:
//
//   leaving  a pane the click closes (`data-desk-leaving`) is never drawn.
//   rows     a row never shows a half state: no opacity under 1 and no
//            background on its way between two colours (a transition).
//   title    a document pane's header text, once drawn, does not change.
//   width    a pane that stays open keeps its x and width.
//
// It prints the frames and one line per broken check, and exits 1 when a
// check in --checks fails. NOT a CI gate: it needs a server, a signed-in
// user, and a list with at least two documents.
//
// Run against a local server, opened as localhost (the socket's origin check
// refuses 127.0.0.1): `PORT=4640 PHX_SERVER=true MIX_ENV=test mix phx.server`
// from api/, with a workspace admin and the lists the steps name seeded.
//   node scripts/measurements/desk-flicker-probe.mjs \
//     --base http://localhost:4640 \
//     --desk /w/default/p/default/d/production/studio/_desk \
//     --token-file tokens.txt \
//     --steps "0:Sheets,1:Budget,1:Rota,0:Papers,0:Sheets,1:Budget,close" \
//     --checks leaving,rows,title,width --out frames.txt
//
// --token-file holds magic-link tokens, one per line; each run uses the first
// and removes it (a token signs in once). --steps is "<pane index>:<row text>"
// or "close" (the last pane's close link). Playwright is resolved from
// barkpark-studio/e2e (BP_PLAYWRIGHT_FROM overrides the package.json path).
import { createRequire } from "node:module";
import { readFileSync, writeFileSync } from "node:fs";

const arg = (name, fallback) => {
  const at = process.argv.indexOf(`--${name}`);
  return at > 0 ? process.argv[at + 1] : fallback;
};

const HOVER = "246,246,248"; // --dk-card-hover: a row under the pointer.

// One action's frames → the checks it breaks. Pure, so it can be read alone.
export function judge(label, frames, checks) {
  const out = [];
  const bad = (check, text) => checks.includes(check) && out.push(`${check}: ${label}: ${text}`);

  for (const f of frames) {
    for (const p of f.panes) {
      if (p.leaving && p.w > 0) bad("leaving", `t=${f.t} pane ${p.index} is closing but drawn at ${p.x}+${p.w}`);
      for (const r of p.rows) {
        if (r.op < 1) bad("rows", `t=${f.t} row "${r.text}" at opacity ${r.op}`);
        const a = r.bg.split(",")[3];
        if (a !== undefined && Number(a) > 0 && Number(a) < 1) bad("rows", `t=${f.t} row "${r.text}" background half drawn (${r.bg})`);
      }
    }
  }

  // A row's background, frame after frame: anything between its first and
  // last colour (other than the pointer's hover) is a transition.
  const seq = new Map();
  for (const f of frames)
    for (const p of f.panes)
      if (!p.leaving)
        for (const r of p.rows) {
          const key = `${p.index}/${r.text}`;
          const s = seq.get(key) || [];
          if (s[s.length - 1] !== r.bg) s.push(r.bg);
          seq.set(key, s);
        }
  for (const [key, s] of seq) {
    const mid = s.slice(1, -1).filter((bg) => bg !== HOVER);
    if (mid.length) bad("rows", `row ${key} passes through ${mid.length} colour(s) between ${s[0]} and ${s[s.length - 1]}`);
  }

  // A pane, by index and kind, that is drawn in the first frame and the last.
  const first = frames[0], last = frames[frames.length - 1];
  if (first && last) {
    for (const p of first.panes.filter((p) => !p.leaving && p.w > 0)) {
      const end = last.panes.find((q) => q.index === p.index && q.kind === p.kind && q.title === p.title && !q.leaving);
      if (end && (end.x !== p.x || end.w !== p.w)) bad("width", `pane ${p.index} "${p.title}" moved ${p.x}+${p.w} -> ${end.x}+${end.w}`);
    }
  }

  // A document pane's header text, from its first frame after the click on
  // (the frame before it may show the document the click replaces).
  const titles = new Map();
  for (const f of frames.slice(1))
    for (const p of f.panes)
      if (p.kind === "doc" && !p.leaving && p.w > 0 && p.title) {
        const s = titles.get(p.index) || [];
        if (s[s.length - 1] !== p.title) s.push(p.title);
        titles.set(p.index, s);
      }
  for (const [index, s] of titles) if (s.length > 1) bad("title", `doc pane ${index} header reads ${s.map((t) => JSON.stringify(t)).join(" -> ")}`);

  return out;
}

async function main() {
  const base = arg("base", "http://localhost:4640");
  const desk = arg("desk");
  const tokenFile = arg("token-file");
  const steps = arg("steps", "0:Sheets,1:Budget,1:Rota,0:Papers,0:Sheets,1:Budget,close").split(",");
  const checks = arg("checks", "leaving,rows,title,width").split(",");
  const outFile = arg("out");
  if (!desk || !tokenFile) {
    console.error("usage: --desk <desk path> --token-file <file> [--base] [--steps] [--checks] [--out]");
    process.exit(2);
  }

  const pool = readFileSync(tokenFile, "utf8").split("\n").filter(Boolean);
  if (!pool.length) throw new Error(`no token left in ${tokenFile}`);
  writeFileSync(tokenFile, pool.slice(1).join("\n") + "\n");

  const from = process.env.BP_PLAYWRIGHT_FROM || "/Volumes/SATECHI/github/barkpark-studio/e2e/package.json";
  const { chromium } = createRequire(from)("@playwright/test");
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await (await browser.newContext({ viewport: { width: 1400, height: 860 } })).newPage();
  await page.goto(`${base}/auth/magic/${pool[0]}`);
  await page.goto(base + desk);
  await page.waitForSelector("#desk-panes a[data-desk-row]", { timeout: 15000 });
  await page.waitForTimeout(1500);

  await page.evaluate((hover) => {
    window.__frames = [];
    window.__hover = hover;
    const t0 = performance.now();
    let last = "";
    const opacity = (el) => {
      let o = 1;
      for (let e = el; e && e.nodeType === 1; e = e.parentElement) o *= Number(getComputedStyle(e).opacity);
      return Math.round(o * 100) / 100;
    };
    const snap = () => {
      const root = document.getElementById("desk-panes");
      const panes = root ? [...root.children].filter((el) => el.hasAttribute("data-pane-index")) : [];
      const shot = panes.map((el) => {
        const r = el.getBoundingClientRect();
        return {
          index: Number(el.getAttribute("data-pane-index")),
          kind: el.getAttribute("data-pane-kind"),
          id: el.id || (el.hasAttribute("data-desk-skeleton") ? "(skeleton)" : "?"),
          leaving: el.hasAttribute("data-desk-leaving"),
          x: Math.round(r.x),
          w: Math.round(r.width),
          title: (el.querySelector(".pane-header-title")?.textContent || "").replace(/\s+/g, " ").trim(),
          bones: !!el.querySelector(".dk-skeleton"),
          editor: el.hasAttribute("data-pane-editing"),
          rows: [...el.querySelectorAll("a[data-desk-row]")].map((a) => ({
            text: (a.querySelector(".dk-row-title, .pane-item-label")?.textContent || a.textContent).replace(/\s+/g, " ").trim().slice(0, 24),
            op: opacity(a),
            bg: getComputedStyle(a).backgroundColor.replace(/rgba?\(|\)| /g, ""),
          })),
        };
      });
      const key = JSON.stringify(shot);
      if (key !== last) {
        window.__frames.push({ t: Math.round(performance.now() - t0), panes: shot });
        last = key;
      }
      requestAnimationFrame(snap);
    };
    requestAnimationFrame(snap);
  }, HOVER);

  const actions = [];
  for (const step of steps) {
    let from = await page.evaluate(() => window.__frames.length);
    let label = step;
    if (step === "close") {
      label = "close the last pane";
      await page.evaluate(() => {
        const links = [...document.querySelectorAll('#desk-panes > [data-pane-index]:not([data-desk-leaving]) a[aria-label^="Close"]')].filter((a) => a.getClientRects().length);
        links[links.length - 1]?.click();
      });
    } else {
      const [index, text] = step.split(":");
      label = `click "${text}" in pane ${index}`;
      const row = page.locator(`#desk-panes > [data-pane-index="${index}"]:not([data-desk-leaving]) a[data-desk-row]`, { hasText: text }).first();
      if (!(await row.count())) throw new Error(`no row "${text}" in pane ${index}: the steps do not fit this desk`);
      // The pointer rests on the row first, as a person's does: the hover's
      // read ahead (`warm`) is part of what a click shows.
      await row.hover();
      await page.waitForTimeout(300);
      from = await page.evaluate(() => window.__frames.length);
      await row.click();
    }
    await page.waitForTimeout(1500);
    const frames = await page.evaluate((n) => window.__frames.slice(n), from);
    // The frame before the click is the action's first.
    const before = await page.evaluate((n) => window.__frames[n - 1], from);
    actions.push({ label, frames: before ? [before, ...frames] : frames });
  }
  await browser.close();

  const lines = [];
  const broken = [];
  for (const a of actions) {
    lines.push(`=== ${a.label}`);
    for (const f of a.frames) {
      lines.push(`t=${f.t}ms`);
      for (const p of f.panes) {
        const rows = p.rows.map((r) => `${r.text}{${r.op === 1 ? "" : "op" + r.op + " "}${r.bg}}`).join(" ");
        const marks = [p.leaving && "LEAVING", p.bones && "bones", p.editor && "editor"].filter(Boolean).join(" ");
        lines.push(`  ${p.index} ${p.kind} ${p.id} ${p.x}+${p.w} ${marks} [${p.title}] ${rows}`);
      }
    }
    broken.push(...judge(a.label, a.frames, checks));
  }
  if (outFile) writeFileSync(outFile, lines.join("\n") + "\n");
  else console.log(lines.join("\n"));

  for (const check of checks) {
    const mine = broken.filter((b) => b.startsWith(check + ":"));
    console.log(`${mine.length ? "FAIL" : "PASS"} ${check} (${mine.length})`);
    mine.slice(0, 8).forEach((b) => console.log("  " + b));
  }
  process.exit(broken.length ? 1 : 0);
}

if (import.meta.url === `file://${process.argv[1]}`) await main();
