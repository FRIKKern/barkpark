// __harness_generic_run.mjs — the browser runner for __harness_generic.html.
//
//   node api/assets/paper-editor/src/canvas/__harness_generic_run.mjs
//
// THE ONE COMMAND. That line, from a clean checkout at the repo root, is the
// whole reproduction: it starts a static file server over the repo, drives
// headless Chromium against the generic harness, and prints every assertion.
//
// WHAT IT PROVES. A static file server over the repo (NO Phoenix, no database,
// no /api) plus headless Chromium, driving the generic canvas harness:
//
//   1. the committed capture of a REAL PUBLISHED paper mounts clean and round
//      trips — __assertCleanMount().clean and __assertRoundTrip().ok;
//   2. malformed fixtures are REJECTED VISIBLY — a rendered #harness-error
//      panel carrying a sentence, window.__harnessError set, and BOTH
//      assertions reporting the error instead of a false green;
//   3. a MUTATED block (a real fixture with one block's id removed) reds the
//      same way — the harness does not shrug and mount a half-run;
//   4. Chromium contacted NOTHING but that static server.
//
// The byte-lock on __harness.html and the fixture's provenance need no browser,
// so they live in __harness_lock.test.mjs and run in `npm test` on every PR.
//
// CHROME. Same discovery as src/__narrow_render.mjs: BP_CHROME, then the
// puppeteer cache, then the system Chrome. With no browser it prints SKIP and
// exits 0: a gate that cannot run everywhere is a gate people learn to ignore,
// and the always-on half already lives in __harness_lock.test.mjs.
//
// NOT IN `npm test`, for the same reason __narrow_render.mjs is not: the suite
// must stay runnable on a machine with no Chromium. __test_chain_census.mjs
// blesses exactly this shape — "runner entrypoints such as __smoke.mjs /
// __narrow_render.mjs do not match" its __*.test.mjs predicate — which is why
// this file is named _run.mjs rather than .test.mjs.

import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileP = promisify(execFile);

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../../../..");
const HARNESS_DIR = "api/assets/paper-editor/src/canvas";
const REAL_FIXTURE = "./__fixtures/paper-mechanical-spacing-doctrine.json";

let failures = 0;
// Every arm is awaited. The static server below lives IN THIS PROCESS, so a
// synchronous child_process call would block the event loop and Chromium would
// hang forever on a request node can never answer — measured, not theorised.
const check = async (name, fn) => {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
};

// ── 1. chrome ────────────────────────────────────────────────────────────────

function findChrome() {
  if (process.env.BP_CHROME) return process.env.BP_CHROME;
  const appBin = "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";
  const cache = join(homedir(), ".cache/puppeteer");
  for (const kind of ["chrome-headless-shell", "chrome"]) {
    const root = join(cache, kind);
    if (!existsSync(root)) continue;
    for (const build of readdirSync(root)) {
      for (const [dir, bin] of [
        [`${kind}-mac-arm64`, kind === "chrome" ? appBin : kind],
        [`${kind}-mac-x64`, kind === "chrome" ? appBin : kind],
        [`${kind}-linux64`, kind],
      ]) {
        const p = join(root, build, dir, bin);
        if (existsSync(p)) return p;
      }
    }
  }
  for (const p of [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ]) {
    if (existsSync(p)) return p;
  }
  return null;
}

const CHROME = findChrome();

const fixturePath = join(REPO, HARNESS_DIR, "__fixtures/paper-mechanical-spacing-doctrine.json");

// ── 2. the static server ─────────────────────────────────────────────────────
//
// Plain files off disk, rooted at the repo. `overlay` serves a few in-memory
// fixtures (the malformed and mutated arms) so the repo is not littered with
// deliberately-broken JSON — the bytes live in this file, where the reason for
// each one is next to it.

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };
const overlay = new Map();

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  const path = decodeURIComponent(url.pathname);
  if (overlay.has(path)) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(overlay.get(path));
    return;
  }
  const abs = normalize(join(REPO, path));
  if (!abs.startsWith(normalize(REPO)) || !existsSync(abs)) {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found");
    return;
  }
  const ext = path.slice(path.lastIndexOf("."));
  res.writeHead(200, { "content-type": TYPES[ext] || "application/octet-stream" });
  res.end(readFileSync(abs));
});

async function run(fixtureUrl, netLogPath = null) {
  const { port } = server.address();
  const page =
    `http://127.0.0.1:${port}/${HARNESS_DIR}/__harness_generic.html` +
    `?autorun=1&fixture=${encodeURIComponent(fixtureUrl)}`;
  const { stdout: dom } = await execFileP(
    CHROME,
    [
      "--headless",
      "--disable-gpu",
      "--no-sandbox",
      "--hide-scrollbars",
      "--window-size=900,1200",
      "--virtual-time-budget=12000",
      ...(netLogPath ? [`--log-net-log=${netLogPath}`, "--net-log-capture-mode=Default"] : []),
      "--dump-dom",
      page,
    ],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  const m = dom.match(/RESULT(\{.*?\})<\/pre>/s);
  if (!m) {
    throw new Error(
      `the page produced no RESULT marker — it never finished.\n      ${page}`,
    );
  }
  const unescape = (s) =>
    s.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  return { result: JSON.parse(unescape(m[1])), dom, page, origin: `http://127.0.0.1:${port}` };
}

// PHOENIX IS NEVER CONTACTED, and this measures it rather than asserting it.
// "run it with Phoenix stopped" is unverifiable on a shared machine where
// somebody else's `mix phx.server` may be listening on :4000 — and stopping a
// server proves nothing about the NEXT run anyway. The net log names every URL
// Chromium requested; if any of them leaves the static server's origin, the
// page is not the self-contained static artifact it claims to be.
function loggedRequests(netLogPath, origin) {
  if (!existsSync(netLogPath)) return { all: [], foreign: ["<no net log was written>"] };
  const raw = readFileSync(netLogPath, "utf8");
  const urls = new Set();
  for (const m of raw.matchAll(/"url":"(https?:[^"]+)"/g)) urls.add(m[1].replace(/\\u002F/g, "/"));
  const all = [...urls];
  return { all, foreign: all.filter((u) => !u.startsWith(origin)) };
}

// The red panel is only a real rejection if it is VISIBLE. Chromium's
// --dump-dom emits the `hidden` attribute verbatim, so its presence or absence
// on #harness-error is the rendered-visibility assertion.
function errorPanel(dom) {
  const m = dom.match(/<div id="harness-error"([^>]*)>([\s\S]*?)<\/div>/);
  if (!m) return null;
  return { hidden: /\bhidden\b/.test(m[1]), html: m[2] };
}

const realFixture = JSON.parse(readFileSync(fixturePath, "utf8"));

// The MUTATED arm: the real capture with one block's id removed. It is a
// one-field mutation of a payload that is otherwise proven green two checks
// above, so a red here is attributable to the mutation and nothing else.
const mutated = JSON.parse(JSON.stringify(realFixture));
delete mutated.blocks[3].id;
overlay.set("/__overlay__/mutated-block.json", JSON.stringify(mutated));

// The MALFORMED arms. Each names the shape a fixture author actually gets wrong.
const MALFORMED = [
  ["not JSON at all", "/__overlay__/not-json.json", "{ this is not json"],
  ["no version field", "/__overlay__/no-version.json", JSON.stringify({ blocks: realFixture.blocks })],
  ["blocks is a string", "/__overlay__/blocks-string.json", JSON.stringify({ version: 1, blocks: "nope" })],
  ["blocks is empty", "/__overlay__/blocks-empty.json", JSON.stringify({ version: 1, blocks: [] })],
  ["top level is an array", "/__overlay__/array.json", JSON.stringify(realFixture.blocks)],
];
for (const [, path, body] of MALFORMED) overlay.set(path, body);

if (!CHROME) {
  console.log("SKIP  browser arms — no Chromium found.");
  console.log("      Set BP_CHROME=/path/to/chrome, or `npx @puppeteer/browsers install chrome-headless-shell`.");
} else {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    // ── the green: a real published paper, clean mount + round trip ──────────
    let green;
    let net;
    await check("the real published-paper capture mounts clean and round trips", async () => {
      const NETLOG = mkdtempSync(join(tmpdir(), "bp-canvas-harness-"));
      const netLogPath = join(NETLOG, "net.json");
      const run1 = await run(REAL_FIXTURE, netLogPath);
      green = run1.result;
      net = loggedRequests(netLogPath, run1.origin);
      rmSync(NETLOG, { recursive: true, force: true });
      if (green.error) throw new Error(`the harness rejected the real fixture: ${green.error}`);
      if (!green.ready) throw new Error("the harness never reached ready");
      if (!green.cleanMount.clean) {
        throw new Error(
          `an UNEDITED mount emitted ops: ${JSON.stringify(green.cleanMount.ops)}`,
        );
      }
      if (!green.roundTrip.ok) {
        throw new Error(
          `bpIds did not survive the setContent->getJSON round trip\n` +
            `      expected ${JSON.stringify(green.roundTrip.expected)}\n` +
            `      got      ${JSON.stringify(green.roundTrip.ids)}`,
        );
      }
      console.log(
        `      __assertCleanMount() -> ${JSON.stringify(green.cleanMount)}\n` +
          `      __assertRoundTrip()  -> ok=${green.roundTrip.ok}, ` +
          `${green.roundTrip.ids.length} ids, first=${green.roundTrip.ids[0]}, ` +
          `last=${green.roundTrip.ids[green.roundTrip.ids.length - 1]}`,
      );
    });

    await check("the proof touches NOTHING but the static server (Phoenix uncontacted)", () => {
      if (!net) throw new Error("the green arm did not run, so no net log exists");
      // NON-VACUITY. An empty net log would pass the filter below for free, so
      // the count is asserted before the verdict: the page loads a document, a
      // stylesheet, a 550KB bundle and a fixture, so anything under 4 means the
      // log was not captured and this arm measured nothing.
      if (net.all.length < 4) {
        throw new Error(
          `the net log named only ${net.all.length} URL(s) (${JSON.stringify(net.all)}) — ` +
            "it was not captured, so this arm proves nothing",
        );
      }
      if (net.foreign.length) {
        throw new Error(
          `Chromium requested ${net.foreign.length} URL(s) outside the static server:\n      ` +
            net.foreign.join("\n      ") +
            "\n      The harness must be static files only — no /api, no :4000, no CDN.",
        );
      }
      console.log(`      all ${net.all.length} logged requests stayed on the static server's origin`);
    });

    // ── the reds: malformed input is refused, visibly ────────────────────────
    for (const [label, path] of MALFORMED) {
      await check(`malformed fixture (${label}) is rejected visibly`, async () => {
        const { result, dom } = await run(path);
        if (!result.error) throw new Error("the harness accepted it — no window.__harnessError");
        const panel = errorPanel(dom);
        if (!panel) throw new Error("#harness-error is not in the rendered DOM");
        if (panel.hidden) throw new Error("#harness-error is still [hidden] — the rejection is invisible");
        if (!panel.html.includes("Harness input rejected")) {
          throw new Error(`#harness-error carries no rejection headline: ${panel.html.slice(0, 160)}`);
        }
        if (result.cleanMount.clean) throw new Error("__assertCleanMount() returned a false green");
        if (result.roundTrip.ok) throw new Error("__assertRoundTrip() returned a false green");
        console.log(`      window.__harnessError -> ${JSON.stringify(result.error)}`);
      });
    }

    await check("a mutated block (id removed from the real capture) is rejected visibly", async () => {
      const { result, dom } = await run("/__overlay__/mutated-block.json");
      if (!result.error) throw new Error("the harness mounted a run with an id-less block");
      const panel = errorPanel(dom);
      if (!panel || panel.hidden) throw new Error("#harness-error did not render visibly");
      if (result.cleanMount.clean || result.roundTrip.ok) {
        throw new Error("an assertion returned a false green over a mutated run");
      }
      console.log(`      window.__harnessError -> ${JSON.stringify(result.error)}`);
    });
  } finally {
    server.close();
  }
}

console.log(failures === 0 ? "\nOK  __harness_generic_run.mjs" : `\n${failures} FAILING  __harness_generic_run.mjs`);
process.exit(failures === 0 ? 0 : 1);
