// __caret_before_keys_keys.mjs — the real-browser half of task-ae6d3d056711b076.
//
// canvas/__caret_before_keys_mounted.test.mjs pins the rule in jsdom; this rig clicks and
// presses keys in headless Chromium (Playwright's mouse and keyboard) on the committed
// bundle and stylesheet. ProseMirror reads a click's caret on selectionchange, 2-60 ms
// after mouseup, so these scenes press the key 0, 20 and 40 ms after the click, without
// the wait the other rigs use: Enter must split the clicked line, and ArrowDown must skip
// a hidden empty line every time, whether or not the old caret had it open. The page's
// host acknowledges every batch; the rig folds them through the patch.ex reference fold
// (smoke/harness.mjs applyOps) and checks that the doc and the saved blocks agree.
//
//   Run:  node ../paper-editor-host-tests/__caret_before_keys_keys.mjs   (from api/assets/paper-editor)
//   Env:  BP_PLAYWRIGHT_FROM=<package.json that can require("playwright")>
//
// Playwright lives in the js/ monorepo's node_modules; a worktree finds it through the
// primary checkout. No Playwright or no browser: SKIP, exit 0 (exit 1 under
// BP_REQUIRE_CHROME=1), per __rig.mjs. Not in `npm test`, like the other rigs.

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { exitRig, skip, tally } from "../paper-editor/src/__rig.mjs";
import { applyOps } from "../paper-editor/src/smoke/harness.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../..");
const ASSETS = join(REPO, "api/priv/static/assets");
const TRIES = 5;

function playwright() {
  const candidates = [process.env.BP_PLAYWRIGHT_FROM].filter(Boolean);
  try {
    const common = execFileSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: REPO, encoding: "utf8" }).trim();
    candidates.push(join(dirname(common), "js", "package.json"));
  } catch {}
  for (const from of candidates) {
    try { return createRequire(from)("playwright"); } catch {}
  }
  return null;
}

const pw = playwright();
if (!pw) process.exit(skip("__caret_before_keys_keys.mjs — playwright not found (set BP_PLAYWRIGHT_FROM)."));
let browser;
try {
  browser = await pw.chromium.launch();
} catch (error) {
  process.exit(skip(`__caret_before_keys_keys.mjs — no Chromium for playwright: ${error.message.split("\n")[0]}`));
}

const PAGE = `<!doctype html><html><head><meta charset="utf-8">
<script>window.BP_PAPER_EDITOR_NO_INJECT = true;</script>
<link rel="stylesheet" href="/bp-paper-editor.css"></head>
<body><bp-paper-canvas id="canvas"></bp-paper-canvas>
<script src="/bp-paper-editor.bundle.js"></script>
<script>
  const canvas = document.getElementById("canvas");
  window.__batches = [];
  canvas.acknowledgedSaves = true;
  canvas.addEventListener("bp-canvas-ops", (event) => {
    window.__batches.push(JSON.parse(JSON.stringify(event.detail.ops)));
    canvas.acknowledgeOps(event.detail.seq, true);
  });
  window.__mount = (blocks) => { canvas.blocks = blocks; };
  window.__lines = () => {
    const out = [];
    canvas._editor.state.doc.forEach((node) => out.push(node.textContent));
    return out;
  };
  window.__shown = () => [...canvas._editor.view.dom.children]
    .filter((el) => el.matches("p") && el.getBoundingClientRect().height > 0)
    .map((el) => el.textContent);
  window.__caretRead = () => {
    const view = canvas._editor.view;
    const dom = getSelection();
    return view.state.selection.from === view.posAtDOM(dom.anchorNode, dom.anchorOffset);
  };
  window.__caretLine = () => canvas._editor.state.selection.$from.parent.textContent;
</script></body></html>`;

const server = createServer((req, res) => {
  const name = req.url.split("?")[0].slice(1);
  if (name === "") return res.end(PAGE);
  if (!["bp-paper-editor.css", "bp-paper-editor.bundle.js"].includes(name)) { res.statusCode = 404; return res.end(); }
  res.setHeader("content-type", name.endsWith(".css") ? "text/css" : "text/javascript");
  res.end(readFileSync(join(ASSETS, name)));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}/`;

const p = (id, value) => ({ id, type: "paragraph", content: value ? [{ type: "text", value }] : [] });
const RUN = [p("p-a", "Alpha"), p("p-b", "Beta")];
const GAP = [p("p-a", "Alpha"), p("p-e", ""), p("p-b", "Beta")];

async function open(page, blocks) {
  await page.goto(origin);
  await page.waitForFunction(() => customElements.get("bp-paper-canvas"));
  await page.evaluate((b) => window.__mount(b), blocks);
  await page.waitForFunction(() => document.getElementById("canvas")._editor);
}

async function click(page, text, offset) {
  const box = await page.evaluate(([text, offset]) => {
    const walker = document.createTreeWalker(document.querySelector('[contenteditable="true"]'), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.data !== text) continue;
      const range = document.createRange();
      const end = offset === text.length;
      range.setStart(node, end ? offset - 1 : offset);
      range.setEnd(node, end ? offset : offset + 1);
      const r = range.getBoundingClientRect();
      return { x: end ? r.right - 1 : r.left + 1, y: r.top + r.height / 2 };
    }
    return null;
  }, [text, offset]);
  if (!box) throw new Error(`"${text}" is not on screen`);
  await page.mouse.click(box.x, box.y);
}

async function clickAndWait(page, text, offset) {
  await click(page, text, offset);
  await page.waitForFunction(() => window.__caretRead());
}

async function settle(page) {
  await page.evaluate(() => document.getElementById("canvas").flushPendingChanges());
  await page.waitForFunction(() => !document.getElementById("canvas").hasPendingChanges());
}

async function arrowFrom(page, line, key) {
  await page.keyboard.press(key);
  await page.waitForFunction((line) => window.__caretRead() && window.__caretLine() !== line, line);
  return page.evaluate(() => ({ line: window.__caretLine(), shown: window.__shown() }));
}

function equal(actual, expected, what) {
  if (!isDeepStrictEqual(actual, expected)) throw new Error(`${what}: ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
}

async function saved(page, before) {
  let blocks = structuredClone(before);
  for (const ops of await page.evaluate(() => window.__batches)) blocks = applyOps(blocks, ops);
  equal(blocks, await page.evaluate(() => document.getElementById("canvas").blocks), "the fold against what the canvas believes it saved");
  return blocks.map((block) => block.content.map((n) => n.value).join(""));
}

async function run(name, blocks, play) {
  await t.checkAsync(name, async () => {
    const page = await browser.newPage();
    try {
      await open(page, blocks);
      await play(page);
    } finally {
      await page.close();
    }
  });
}

const t = tally();
try {
  for (const gap of [0, 20, 40]) {
    await run(`Enter ${gap} ms after a click at the end of Beta splits Beta, not the line the caret was on`, RUN, async (page) => {
      await clickAndWait(page, "Alpha", 0);
      await click(page, "Beta", 4);
      if (gap) await page.waitForTimeout(gap);
      await page.keyboard.press("Enter");
      await page.keyboard.type("x");
      await settle(page);
      equal(await page.evaluate(() => window.__lines()), ["Alpha", "Beta", "x"], "the doc");
      equal(await saved(page, RUN), ["Alpha", "Beta", "x"], "the saved blocks");
    });

    await run(`Enter ${gap} ms after the click that focuses the canvas splits the clicked line`, RUN, async (page) => {
      await click(page, "Beta", 4);
      if (gap) await page.waitForTimeout(gap);
      await page.keyboard.press("Enter");
      await page.keyboard.type("x");
      await settle(page);
      equal(await page.evaluate(() => window.__lines()), ["Alpha", "Beta", "x"], "the doc");
      equal(await saved(page, RUN), ["Alpha", "Beta", "x"], "the saved blocks");
    });
  }

  for (let i = 1; i <= TRIES; i++) {
    await run(`ArrowDown from the end of Alpha skips the hidden empty line below (${i}/${TRIES})`, GAP, async (page) => {
      await clickAndWait(page, "Alpha", 5);
      equal(await arrowFrom(page, "Alpha", "ArrowDown"), { line: "Beta", shown: ["Alpha", "Beta"] }, "where the caret landed");
    });

    await run(`ArrowDown right after a click at the end of Alpha skips the empty line the old caret had open (${i}/${TRIES})`, GAP, async (page) => {
      await page.click(".bp-scaffold-control");
      await page.waitForFunction(() => window.__caretLine() === "" && window.__shown().length === 3);
      await click(page, "Alpha", 5);
      equal(await arrowFrom(page, "Alpha", "ArrowDown"), { line: "Beta", shown: ["Alpha", "Beta"] }, "where the caret landed");
    });

    await run(`ArrowUp from the start of Beta skips the hidden empty line above (${i}/${TRIES})`, GAP, async (page) => {
      await clickAndWait(page, "Beta", 0);
      equal(await arrowFrom(page, "Beta", "ArrowUp"), { line: "Alpha", shown: ["Alpha", "Beta"] }, "where the caret landed");
    });
  }
} finally {
  await browser.close();
  server.close();
}
exitRig(t.passes, t.failures);
