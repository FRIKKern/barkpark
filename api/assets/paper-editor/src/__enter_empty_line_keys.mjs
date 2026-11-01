// __enter_empty_line_keys.mjs — the real-browser half of task-be261d669280dc9e.
//
// canvas/__enter_empty_line_mounted.test.mjs pins the rule in jsdom; this rig presses
// the keys in headless Chromium (Playwright's mouse and keyboard) on the committed
// bundle and stylesheet, where an empty top-level paragraph the caret left is really
// display: none. The page's host acknowledges every batch; the rig folds them through
// the patch.ex reference fold (smoke/harness.mjs applyOps) and checks that the doc,
// the lines on screen and the saved blocks agree, and that a fresh canvas mounted on
// the saved blocks (the reload) shows the same lines.
//
//   Run:  node src/__enter_empty_line_keys.mjs        (or: npm run enter-empty-line:keys)
//   Env:  BP_PLAYWRIGHT_FROM=<package.json that can require("playwright")>
//
// Playwright lives in the js/ monorepo's node_modules; a worktree finds it through
// the primary checkout. A click is followed by a wait until ProseMirror has read the
// caret the click put in the DOM (it reads a mouse selection on its own schedule), so
// the keys that follow start where the click landed. No Playwright or no browser:
// SKIP, exit 0 (exit 1 under BP_REQUIRE_CHROME=1), per __rig.mjs. Not in `npm test`,
// like the other rigs.

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { exitRig, skip, tally } from "./__rig.mjs";
import { applyOps } from "./smoke/harness.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../../..");
const ASSETS = join(REPO, "api/priv/static/assets");

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
if (!pw) process.exit(skip("__enter_empty_line_keys.mjs — playwright not found (set BP_PLAYWRIGHT_FROM)."));
let browser;
try {
  browser = await pw.chromium.launch();
} catch (error) {
  process.exit(skip(`__enter_empty_line_keys.mjs — no Chromium for playwright: ${error.message.split("\n")[0]}`));
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
    .filter((el) => el.matches("p, h1, h2, h3, h4, h5, h6") && el.getBoundingClientRect().height > 0)
    .map((el) => el.textContent);
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

async function clickAt(page, text, offset) {
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
  await page.waitForFunction(() => {
    const view = document.getElementById("canvas")._editor.view;
    const dom = getSelection();
    return view.state.selection.from === view.posAtDOM(dom.anchorNode, dom.anchorOffset);
  });
}

async function settle(page) {
  await page.evaluate(() => document.getElementById("canvas").flushPendingChanges());
  await page.waitForFunction(() => !document.getElementById("canvas").hasPendingChanges());
}

function equal(actual, expected, what) {
  if (!isDeepStrictEqual(actual, expected)) throw new Error(`${what}: ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
}

async function state(page, before) {
  let saved = structuredClone(before);
  for (const ops of await page.evaluate(() => window.__batches)) saved = applyOps(saved, ops);
  const client = await page.evaluate(() => document.getElementById("canvas").blocks);
  equal(saved, client, "the fold against what the canvas believes it saved");
  const text = saved.map((block) => block.content.map((n) => n.value).join(""));
  return { doc: await page.evaluate(() => window.__lines()), shown: await page.evaluate(() => window.__shown()), saved: text, blocks: saved };
}

async function reloads(blocks, want) {
  const page = await browser.newPage();
  try {
    await open(page, blocks);
    equal(await page.evaluate(() => window.__lines()), want, "the reload");
  } finally {
    await page.close();
  }
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
  await run("six Enters at the end of a line: one empty line in the doc, on screen and saved; one Backspace leaves it", RUN, async (page) => {
    await clickAt(page, "Alpha", 5);
    for (let i = 0; i < 6; i++) await page.keyboard.press("Enter");
    await settle(page);
    const six = await state(page, RUN);
    equal(six.doc, ["Alpha", "", "Beta"], "the doc");
    equal(six.shown, ["Alpha", "", "Beta"], "the lines on screen");
    equal(six.saved, ["Alpha", "", "Beta"], "the saved blocks");
    await reloads(six.blocks, ["Alpha", "", "Beta"]);
    await page.keyboard.press("Backspace");
    await settle(page);
    const back = await state(page, RUN);
    equal(back.doc, ["Alpha", "Beta"], "the doc after one Backspace");
    equal(back.shown, ["Alpha", "Beta"], "the screen after one Backspace");
    equal(back.saved, ["Alpha", "Beta"], "the saved blocks after one Backspace");
  });

  await run("Enter at the start of a line under an empty line does nothing", GAP, async (page) => {
    await clickAt(page, "Beta", 0);
    await page.keyboard.press("Enter");
    await page.keyboard.type("Very ");
    await settle(page);
    const after = await state(page, GAP);
    equal(after.doc, ["Alpha", "", "Very Beta"], "the doc");
    equal(after.shown, ["Alpha", "Very Beta"], "the lines on screen (the empty line rests hidden)");
    equal(after.saved, ["Alpha", "", "Very Beta"], "the saved blocks");
    await reloads(after.blocks, ["Alpha", "", "Very Beta"]);
  });

  await run("Enter at the end of a line above an empty line moves the caret into it", GAP, async (page) => {
    await clickAt(page, "Alpha", 5);
    await page.keyboard.press("Enter");
    await page.keyboard.type("Gamma");
    await settle(page);
    const after = await state(page, GAP);
    equal(after.doc, ["Alpha", "Gamma", "Beta"], "the doc");
    equal(after.shown, ["Alpha", "Gamma", "Beta"], "the lines on screen");
    equal(after.saved, ["Alpha", "Gamma", "Beta"], "the saved blocks");
    await reloads(after.blocks, ["Alpha", "Gamma", "Beta"]);
  });
} finally {
  await browser.close();
  server.close();
}
exitRig(t.passes, t.failures);
