// cssom-parity.mjs — does EVERY authored rule in app.css reach the browser?
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (charter GR73 / GR93 / GR100)
// ─────────────────────────────────────────────────────────────────────────────
//  Of the nine mechanisms that certify this console's CSS, eight ask a question
//  about the FILE — they regex-extract app.css, or scan its comment nesting, or
//  read `--x:` declarations out of three token blocks. ZERO of them build a
//  CSSOM. That is exactly how bug #4592 stayed green for five waves: a lost
//  `/*` opener turned a REVIEW ADDENDUM paragraph into raw CSS, CSS error
//  recovery discarded tokens until the next `{…}` block — and the block it
//  recovered on was `.modal-root`'s own — so the base rule of a shared modal
//  primitive with 15+ call sites never reached the browser. Every modal in the
//  console rendered unpositioned beneath a fixed scrim, in production. Three
//  green gates certified the dead CSS the whole time.
//
//  A gate that cannot parse the artifact it certifies is not a gate.
//
//  This is the first check in the surface that parses the artifact rather than
//  a text projection of it. It loads app.css in headless Chrome, enumerates
//  `document.styleSheets` recursively, and diffs the result against the
//  selectors the source file actually authors. Any authored selector with no
//  CSSOM counterpart is a MISS.
//
//  RELATIONSHIP TO ITS NEIGHBOURS — three tools, three scopes, no overlap:
//    · __css_check.mjs E10  — catches the SPECIFIC mechanism (an orphan `*/`
//      terminator) by walking the source text. Narrow, fast, in CI.
//    · modal-oracle.mjs     — catches the SPECIFIC victim (.modal-root) and its
//      rendered consequences. Narrow, browser-backed, unwired.
//    · this file            — catches the general CLASS: any authored top-level
//      selector the browser discards, for any reason, anywhere in the file.
//      Whole-stylesheet, browser-backed, unwired.
//
// ─────────────────────────────────────────────────────────────────────────────
//  TWO BINDING DESIGN RULINGS (GR100) — both are load-bearing, neither is style
// ─────────────────────────────────────────────────────────────────────────────
//  1. SYMMETRIC NORMALISATION, never an enumerated rewrite list.
//     Chrome re-serialises selectors, so a byte compare is useless. The obvious
//     fix — enumerate the known rewrites — is provably incomplete. GR73 recorded
//     TWO classes (comma-group flattening, `> *:pseudo` → `> :pseudo`) and a
//     THIRD was then found in a file containing exactly ONE affected selector:
//     Chrome strips whitespace inside the An+B microsyntax, serialising
//     `> *:nth-last-child(-n + 2)` as `> :nth-last-child(-n+2)`. A fourth class
//     is a coin-flip away. So BOTH sides go through ONE `normalise()` below.
//     Under symmetric normalisation an unknown serialisation class can only
//     cost sensitivity, never manufacture a false miss — which is the trade a
//     gate must make, because a gate that cries wolf is disabled within a wave.
//
//  2. BRACE-TRACKING PARSER, never a grep.
//     `app.css` holds 16 opaque at-rule blocks (@keyframes/@font-face/@property)
//     whose 21 percent-stop heads have NO `selectorText` and can never appear in
//     the CSSOM side, plus 40 multi-line comma continuations a line-oriented
//     grep splits into fragments. A grep manufactures ~37 spurious misses on a
//     perfectly clean file. The parser below skips opaque at-rules wholesale and
//     descends into grouping at-rules (@media/@supports/@container/@layer), so
//     both sides describe the same population by construction.
//
//  CALIBRATION. GR100 measured 1189 heads == 1189 CSSOM rules, 1158 flattened,
//  0 misses. This file measures 1200 == 1200, 1169 flattened, 0 misses — the
//  stylesheet grew 11 rules when #4733 gave six shipped class families their
//  CSS. Do NOT treat either absolute as the invariant; it goes stale every
//  wave. The invariant is `heads == CSSOM rules` and `MISSES == 0`, and both
//  censuses independently carry the same 31-rule head-to-flattened gap.
//
// ─────────────────────────────────────────────────────────────────────────────
//  MUTATION-PROVEN AT TWO LOCATIONS ~2000 LINES APART
// ─────────────────────────────────────────────────────────────────────────────
//  A green run means nothing unless the red is demonstrated.
//
//    cp cloud/priv/static/app.css /tmp/app.css.bak
//    perl -i -pe 's{/\\* REVIEW ADDENDUM}{REVIEW ADDENDUM} if $. == 1029' \
//      cloud/priv/static/app.css        # the #4592 defect, byte-for-byte
//    node cloud/priv/static/__preview__/cssom-parity.mjs   # exit 1, names .modal-root
//    cp /tmp/app.css.bak cloud/priv/static/app.css         # exit 0 again
//
//  Measured: MISSES 0 → 2 (one rule head, two comma fragments of one garbage
//  run) reporting `app.css:1034  .modal-root   ← SWALLOWED`, then 0 restored.
//  The same edit at `app.css:3076` (`/* Shown-once`) names `.wh-secret` at
//  `app.css:3077` — 2047 lines away, and THAT is the whole argument for this
//  instrument over more photographs: the check is FILE-WIDE, not modal-local.
//  (GR100 cites 986/3005; #4733's relocation shifted the file. The openers are
//  unchanged, and GR95 already records this one at :1029. Re-grep before
//  trusting any line number here — `grep -n 'REVIEW ADDENDUM' app.css`.)
//
//  A miss whose text contains `*/` is reported as an ORPHAN-COMMENT SWALLOW
//  cross-referencing E10 — without that, the miss reads as a nonsense selector
//  string and a cold reader files a bug against this gate instead of the CSS.
//
// ─────────────────────────────────────────────────────────────────────────────
//  RUN
// ─────────────────────────────────────────────────────────────────────────────
//    node cloud/priv/static/__preview__/cssom-parity.mjs
//    CSS=/path/to/other.css node cssom-parity.mjs      # certify a different file
//    CHROME=/path/to/chrome  node cssom-parity.mjs
//
//  Exit codes: 0 = every authored selector reached the CSSOM · 1 = at least one
//  MISS, or the run could not be completed · 2 = GUARD (no Chrome, no stylesheet)
//  refused before anything is spawned.
//
//  UNWIRED FROM CI ON PURPOSE (GR93(b)) — same shape as modal-oracle.mjs. It
//  never gates the epic seal. Wiring it is the successor epic's first task, and
//  it should be wired only once it has survived a wave of real use, because a
//  gate promoted before it is trusted is a gate that gets disabled.
//
//  ZERO DEPENDENCIES — Node 22 native fetch + native WebSocket speak CDP
//  directly, matching __preview__'s doctrine. It reads the file from disk rather
//  than through serve.mjs: serve.mjs serves cloud/priv/static VERBATIM, so these
//  are the served bytes, and a lone injected <style> keeps the CSSOM isolated to
//  exactly one stylesheet — which is what makes the 1189 == 1189 calibration
//  mean anything.
//
//  TEARDOWN — hand-bounded, and it does NOT inherit shoot.sh's blocking `wait`.
//  That `wait` on a Chrome which ignores SIGTERM is a measured multi-hour stall
//  (7h18m, then 10h30m+, on this host). Nothing here ever blocks on a child:
//  CDP Browser.close raced against a cap, then `kill -0` polling with a cap,
//  then SIGKILL with a further cap, then a SHOUT on stderr naming the pid.
//  Chrome takes --remote-debugging-port=0 and reports its own port through the
//  profile dir, so a concurrent shoot.sh can never collide with it.
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_CSS = path.resolve(HERE, "..", "app.css");

const DEVTOOLS_CAP = 15000;
const PARSE_CAP = 20000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// At-rules that CONTAIN style rules — descend into them; their inner rules are
// real CSSOM style rules and must appear on the authored side too.
const GROUPING_AT = new Set(["media", "supports", "container", "layer", "scope", "document"]);
// At-rules that contain something OTHER than style rules — @keyframes' percent
// stops are CSSKeyframeRule (no selectorText), @font-face/@property have no
// selector at all. Skipped wholesale, symmetric with the CSSOM walk below.

// ── 1. the authored side — a brace-tracking parser, not a grep ────────────────

function skipComment(css, i) {
  const end = css.indexOf("*/", i + 2);
  return end === -1 ? css.length : end + 2;
}

function skipString(css, i) {
  const quote = css[i];
  let j = i + 1;
  while (j < css.length) {
    if (css[j] === "\\") { j += 2; continue; }
    if (css[j] === quote) return j + 1;
    j++;
  }
  return css.length;
}

// Consume from the `{` at `i` through its matching `}`, respecting nesting,
// comments and strings. Used for both style-rule bodies and opaque at-rules.
function skipBlock(css, i) {
  let depth = 0;
  let j = i;
  while (j < css.length) {
    const c = css[j];
    if (c === "/" && css[j + 1] === "*") { j = skipComment(css, j); continue; }
    if (c === '"' || c === "'") { j = skipString(css, j); continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return j + 1; }
    j++;
  }
  return css.length;
}

const atName = (head) => (head.match(/^@([a-zA-Z-]+)/) || [, ""])[1].toLowerCase();

// Every style-rule head the source authors, in file order, with its line number.
// A "head" is the raw prelude text before a `{` — it may be a comma group, and
// it may span many lines (40 of them do).
function authoredHeads(css) {
  const heads = [];
  let i = 0;
  let buf = "";
  let bufStart = 0;
  // Leading whitespace is never part of a head, and swallowing it here is what
  // makes the reported line the line the DEFECT is on rather than the line the
  // previous rule closed on.
  const push = (ch, at) => {
    if (buf === "" && /^\s*$/.test(ch)) return;
    if (buf === "") bufStart = at;
    buf += ch;
  };

  while (i < css.length) {
    const c = css[i];
    if (c === "/" && css[i + 1] === "*") { i = skipComment(css, i); continue; }
    if (c === '"' || c === "'") {
      const j = skipString(css, i);
      push(css.slice(i, j), i);
      i = j;
      continue;
    }
    if (c === "{") {
      const head = buf.trim();
      const start = bufStart;
      buf = "";
      if (head.startsWith("@")) {
        if (GROUPING_AT.has(atName(head))) { i++; continue; } // descend
        i = skipBlock(css, i);                                 // opaque — skip
        continue;
      }
      if (head !== "") heads.push({ head, index: start, braceIndex: i });
      i = skipBlock(css, i);
      continue;
    }
    if (c === "}") { buf = ""; i++; continue; }        // leaving a grouping block
    // A `;` ends a STATEMENT at-rule (@import, @charset, @layer a, b;). It does
    // NOT end a qualified rule's prelude — CSS error recovery runs to the next
    // `{`, which is precisely how #4592 swallowed the rule that followed it, and
    // reproducing that faithfully is what makes the mutation proof honest.
    if (c === ";" && buf.trim().startsWith("@")) { buf = ""; i++; continue; }
    push(c, i);
    i++;
  }
  return heads;
}

// ── 2. ONE normaliser, applied to BOTH sides (GR100 ruling 1) ────────────────
// Every transform here is deliberately blind to which side it is looking at.
// It is NOT a list of Chrome's known rewrites — it is a canonical form both a
// hand-written selector and a Chrome-serialised one collapse into. An unknown
// fourth serialisation class costs sensitivity here, never correctness.
function normalise(sel) {
  return sel
    .replace(/\s+/g, " ")               // multi-line comma continuations
    .replace(/\s*([>+~])\s*/g, "$1")    // combinators — AND the An+B `-n + 2`
    .replace(/\(\s+/g, "(")             // `:is( a )`
    .replace(/\s+\)/g, ")")
    .replace(/\s*,\s*/g, ",")
    .replace(/\*(?=[:.#[])/g, "")       // `> *:pseudo` serialises as `> :pseudo`
    .trim();
}

// Split a comma group at TOP level only — `:is(a, b)` and `[x=","]` stay whole.
function splitGroup(head) {
  const out = [];
  let depth = 0;
  let cur = "";
  for (let i = 0; i < head.length; i++) {
    const c = head[i];
    if (c === '"' || c === "'") { const j = skipString(head, i); cur += head.slice(i, j); i = j - 1; continue; }
    if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") depth--;
    if (c === "," && depth === 0) { out.push(cur); cur = ""; continue; }
    cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

const lineOf = (css, index) => css.slice(0, index).split("\n").length;

// Middle-ellipsis, never a tail chop: under an orphan-comment swallow the thing
// a reader needs is at the END of a 400-character garbage run, and a tail chop
// hides exactly the selector the gate exists to name.
const ellipsis = (s, max = 150) =>
  s.length <= max ? s : s.slice(0, max - 60) + " … " + s.slice(-57);

// ── 3. the CSSOM side, as it runs inside the page ─────────────────────────────
// Recurse into grouping rules so a rule is never "missing" merely because it is
// nested, and key on `selectorText` being a string — that is exactly what
// excludes @keyframes percent stops, @font-face and @property, symmetric with
// the parser's opaque-at-rule skip.
const COLLECT_JS = `(function () {
  var out = { rules: [], unreadable: 0, sheetCount: document.styleSheets.length };
  function walk(rules) {
    for (var i = 0; i < rules.length; i++) {
      var r = rules[i];
      if (typeof r.selectorText === "string") out.rules.push(r.selectorText);
      if (r.cssRules && r.cssRules.length) walk(r.cssRules);
    }
  }
  for (var s = 0; s < document.styleSheets.length; s++) {
    try { walk(document.styleSheets[s].cssRules || []); } catch (e) { out.unreadable++; }
  }
  return out;
})()`;

// ── 4. plumbing (the CDP client and reap are modal-oracle.mjs's, unchanged) ───

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

// ── 5. the run ───────────────────────────────────────────────────────────────

async function main() {
  const cssPath = path.resolve(process.env.CSS || DEFAULT_CSS);
  if (!fs.existsSync(cssPath)) {
    process.stderr.write(`!! GUARD (exit 2): no stylesheet at ${cssPath}\n`);
    process.exit(2);
  }
  const chromeBin = findChrome();
  if (!chromeBin) {
    process.stderr.write("!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n");
    process.exit(2);
  }

  const css = fs.readFileSync(cssPath, "utf8");
  const bytes = Buffer.byteLength(css);
  const sha = crypto.createHash("sha256").update(css).digest("hex");

  const heads = authoredHeads(css);
  const authored = new Map(); // normalised selector -> first {head, line, braceLine}
  for (const h of heads) {
    const where = { head: h.head, line: lineOf(css, h.index), braceLine: lineOf(css, h.braceIndex) };
    for (const sel of splitGroup(h.head)) {
      const key = normalise(sel);
      if (key && !authored.has(key)) authored.set(key, where);
    }
  }

  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "cssom-parity-"));
  const t0 = Date.now();
  let chrome = null;
  let cdp = null;
  let teardownMs = 0;

  const teardown = async () => {
    const td0 = Date.now();
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
            `!! TEARDOWN SHOUT: chrome pid ${chrome.pid} SURVIVED SIGKILL after ` +
              `${KILL_POLL_CAP}ms. Reap it by hand: kill -9 ${chrome.pid}\n`,
          );
        }
      }
    }
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ }
    teardownMs = Date.now() - td0;
  };

  let cssom;
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
    process.stdout.write(
      `>> chrome     ${chromeBin}\n` +
        `>> build      ${version.Browser} · node ${process.version}\n` +
        `>> stylesheet ${path.relative(process.cwd(), cssPath)} · ${bytes} B · sha256 ${sha.slice(0, 12)}…\n\n`,
    );
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);

    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Runtime.enable", {}, sessionId);

    // Inject as ONE inline <style> and wait for the sheet to be reachable. An
    // inline sheet is always same-origin, so `cssRules` can never throw the
    // SecurityError that would silently zero this instrument out.
    const inject = await cdp.send("Runtime.evaluate", {
      expression:
        `(function(){var s=document.createElement("style");` +
        `s.textContent=${JSON.stringify(css)};document.head.appendChild(s);` +
        `return document.styleSheets.length;})()`,
      returnByValue: true,
    }, sessionId);
    if (inject.exceptionDetails) throw new Error("injection threw: " + inject.exceptionDetails.text);

    let collected = null;
    for (let w = 0; w < PARSE_CAP; w += 100) {
      const ev = await cdp.send("Runtime.evaluate", { expression: COLLECT_JS, returnByValue: true }, sessionId);
      if (ev.exceptionDetails) throw new Error("collection threw: " + ev.exceptionDetails.text);
      if (ev.result.value && ev.result.value.rules.length) { collected = ev.result.value; break; }
      await sleep(100);
    }
    if (!collected) throw new Error("Chrome parsed ZERO style rules — the stylesheet never reached the CSSOM");
    if (collected.unreadable) throw new Error(`${collected.unreadable} stylesheet(s) were unreadable — the diff would be a false green`);
    cssom = collected;
  } catch (err) {
    await teardown();
    process.stderr.write(`\n!! PARITY ERROR: ${err && err.message ? err.message : err}\n   teardown ${teardownMs}ms\n`);
    process.exit(1);
  }

  await teardown();

  const cssomSet = new Set();
  for (const sel of cssom.rules) for (const one of splitGroup(sel)) cssomSet.add(normalise(one));

  const misses = [];
  for (const [key, where] of authored) if (!cssomSet.has(key)) misses.push({ key, ...where });

  const wall = Date.now() - t0;
  process.stdout.write(
    `   authored rule heads   ${heads.length}\n` +
      `   CSSOM style rules     ${cssom.rules.length}\n` +
      `   flattened selectors   ${authored.size} authored / ${cssomSet.size} CSSOM\n` +
      `   MISSES                ${misses.length}\n`,
  );

  // Count skew means the parser no longer models the file (CSS nesting, a new
  // at-rule) — the miss list may then be INCOMPLETE, which is the failure mode
  // this whole instrument exists to refuse. Advisory, not fatal: it is a fact
  // about the parser, not about the CSS, and a gate that reds on the wrong
  // thing gets disabled. Under a real swallow it moves too, and the MISS below
  // is the signal that decides the exit code.
  if (heads.length !== cssom.rules.length) {
    process.stdout.write(
      `\n!! COUNT SKEW: ${heads.length} authored heads vs ${cssom.rules.length} CSSOM rules. Either a rule was\n` +
        `   discarded by the browser (see MISSES), or this parser no longer models app.css\n` +
        `   (CSS nesting? a new at-rule? add it to GROUPING_AT). If MISSES is 0 while this\n` +
        `   is non-zero, treat the 0 as UNPROVEN and fix the parser first.\n`,
    );
  }

  if (misses.length === 0) {
    process.stdout.write(
      `\nPARITY PASS — every authored selector reached the CSSOM · ` +
        `${(wall / 1000).toFixed(1)}s wall · teardown ${teardownMs}ms\n`,
    );
    process.exit(0);
  }

  // Report GROUPED BY AUTHORED HEAD. One orphan-comment swallow fragments into
  // several misses (the prose contains commas), and listing them flat reads as
  // several unrelated defects instead of the single one it is.
  const byHead = new Map();
  for (const m of misses) {
    if (!byHead.has(m.head)) byHead.set(m.head, { where: m, keys: [] });
    byHead.get(m.head).keys.push(m.key);
  }

  process.stderr.write(
    `\n!! ${misses.length} authored selector(s) in ${byHead.size} rule head(s) NEVER REACHED THE CSSOM:\n\n`,
  );
  for (const [head, g] of byHead) {
    const orphan = head.includes("*/");
    // The swallowed rule is ALWAYS the tail of the garbage run — error recovery
    // stops at the first `{`, and that `{` belongs to the real rule. Naming it
    // is the difference between "some nonsense selector" and ".modal-root is
    // dead in production".
    const swallowed = orphan ? head.slice(head.lastIndexOf("*/") + 2).trim() : null;

    if (orphan) {
      process.stderr.write(
        `   ✗ app.css:${g.where.braceLine}  ${swallowed || "(unnamed)"}   ← SWALLOWED\n` +
          `     ORPHAN-COMMENT SWALLOW — not a malformed selector, and not a bug in this gate.\n` +
          `     The comment beginning at app.css:${g.where.line} is missing its \`/*\` opener, so its\n` +
          `     prose is parsed as CSS. Error recovery then discards tokens until the next\n` +
          `     \`{…}\` block — and that block belongs to \`${swallowed || "the next rule"}\`, which is\n` +
          `     therefore consumed with it and never reaches the browser. This is bug #4592\n` +
          `     exactly: it is how \`.modal-root\` stayed dead in production for five waves.\n` +
          `     __css_check.mjs E10 guards this same mechanism at the source-text level —\n` +
          `     cross-check it. Fix: restore the \`/*\` opener at app.css:${g.where.line}.\n` +
          `     Garbage run absorbed into the prelude (${g.keys.length} fragment(s)):\n`,
      );
      for (const k of g.keys) process.stderr.write(`       · ${ellipsis(k)}\n`);
    } else {
      process.stderr.write(`   ✗ app.css:${g.where.braceLine}  ${g.keys.map(ellipsis).join(", ")}\n`);
    }
  }
  process.stderr.write(
    `\nPARITY FAIL — ${misses.length} miss(es) · ${(wall / 1000).toFixed(1)}s wall · teardown ${teardownMs}ms\n` +
      `Findings are FILED as tasks, never patched by this instrument.\n`,
  );
  process.exit(1);
}

main();
