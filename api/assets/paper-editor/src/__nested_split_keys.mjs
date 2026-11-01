// __nested_split_keys.mjs — the real-browser half of task-42d085f7431b8417.
//
// canvas/__nested_split_id_mounted.test.mjs proves the fix in jsdom; this rig types it
// in headless Chromium with real key events (Playwright's keyboard, the same input
// pipeline a person's keys take), on the committed bundle and stylesheet the Studio
// loads. For each container (section, expandable, step, tab): click into the nested
// paragraph, End, Enter, type, Enter twice, type, then split mid-text and type. The
// page's host acknowledges every batch; afterwards every batch is folded through the
// patch.ex reference fold (smoke/harness.mjs applyOps), and the rig asserts:
//   - no block id repeats after any batch (patch.ex refuses that: duplicate_id)
//   - the fold equals what the canvas believes it saved
//   - a fresh canvas mounted on the folded blocks (the reload) shows exactly the
//     lines the author saw, every typed character included
//
//   Run:  node src/__nested_split_keys.mjs        (or: npm run nested-split:keys)
//   Env:  BP_PLAYWRIGHT_FROM=<package.json that can require("playwright")>
//
// Playwright lives in the js/ monorepo's node_modules; a worktree finds it through
// the primary checkout. A click is followed by a wait until ProseMirror has read the
// caret the click put in the DOM (it reads a mouse selection on its own schedule), so
// the keys that follow start where the click landed. No Playwright or no browser: SKIP, exit 0 (exit 1 under
// BP_REQUIRE_CHROME=1), per __rig.mjs. Not in `npm test`, like the other rigs.

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
if (!pw) process.exit(skip("__nested_split_keys.mjs — playwright not found (set BP_PLAYWRIGHT_FROM)."));
let browser;
try {
  browser = await pw.chromium.launch();
} catch (error) {
  process.exit(skip(`__nested_split_keys.mjs — no Chromium for playwright: ${error.message.split("\n")[0]}`));
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
    canvas._editor.state.doc.descendants((node) => { if (node.isTextblock) out.push(node.textContent); });
    return out;
  };
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

const p = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });
const SCENES = [
  ["section", [
    { id: "h-trip", type: "heading", level: 2, text: "Trip" },
    { id: "s-day", type: "section", title: "Day one", blocks: [p("p-day", "Left at six."), p("p-two", "Fog.")] },
    p("p-after", "Home."),
  ]],
  ["expandable", [{ id: "x-more", type: "expandable", summary: "Details", open: true, blocks: [p("p-day", "Left at six."), p("p-two", "Fog.")] }]],
  ["steps", [{ id: "st-walk", type: "steps", steps: [
    { id: "r-one", title: "First", blocks: [p("p-day", "Left at six.")] },
    { id: "r-two", title: "Second", blocks: [p("p-two", "Fog.")] },
  ] }]],
  ["tabs", [{ id: "t-days", type: "tabs", tabs: [
    { id: "u-one", label: "Monday", blocks: [p("p-day", "Left at six.")] },
    { id: "u-two", label: "Tuesday", blocks: [p("p-two", "Fog.")] },
  ] }]],
];

function ids(blocks, out = []) {
  for (const block of blocks || []) {
    if (block.id != null) out.push(block.id);
    for (const key of ["blocks", "children", "steps", "tabs"]) ids(block[key], out);
  }
  return out;
}
const repeated = (list) => [...new Set(list.filter((id, i) => list.indexOf(id) !== i))];

async function open(page, blocks) {
  await page.goto(origin);
  await page.waitForFunction(() => customElements.get("bp-paper-canvas"));
  await page.evaluate((b) => window.__mount(b), blocks);
  await page.waitForFunction(() => document.getElementById("canvas")._editor);
}

async function clickAfter(page, text, chars) {
  const box = await page.evaluate(([text, chars]) => {
    const walker = document.createTreeWalker(document.querySelector('[contenteditable="true"]'), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const at = node.data.indexOf(text);
      if (at === -1) continue;
      const range = document.createRange();
      range.setStart(node, at + chars - 1);
      range.setEnd(node, at + chars);
      const r = range.getBoundingClientRect();
      return { x: r.right - 1, y: r.top + r.height / 2 };
    }
    return null;
  }, [text, chars]);
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

const t = tally();
try {
  for (const [name, blocks] of SCENES) {
    await t.checkAsync(`${name}: real keys split a nested paragraph, every character folds and reloads`, async () => {
      const page = await browser.newPage();
      try {
        await open(page, blocks);
        await clickAfter(page, "Left at six.", "Left at six.".length);
        await page.keyboard.press("Enter");
        await page.keyboard.type("Fog lifted.");
        await settle(page);
        await page.keyboard.press("Enter");
        await page.keyboard.press("Enter");
        await page.keyboard.type("Rain.");
        await settle(page);
        await clickAfter(page, "Left at six.", "Left".length);
        await page.keyboard.press("Enter");
        await page.keyboard.type("Late");
        await settle(page);

        const batches = await page.evaluate(() => window.__batches);
        const client = await page.evaluate(() => document.getElementById("canvas").blocks);
        const seen = await page.evaluate(() => window.__lines());
        let folded = structuredClone(blocks);
        for (const ops of batches) {
          folded = applyOps(folded, ops);
          const dup = repeated(ids(folded));
          if (dup.length) throw new Error(`a batch repeats ${dup.join(", ")}: ${JSON.stringify(ops)}`);
        }
        if (!isDeepStrictEqual(folded, client)) throw new Error(`the fold ${JSON.stringify(folded)} differs from what the canvas believes it saved ${JSON.stringify(client)}`);
        for (const typed of ["Left", "Late at six.", "Fog lifted.", "", "Rain."]) {
          if (!seen.includes(typed)) throw new Error(`"${typed}" is not on screen: ${JSON.stringify(seen)}`);
        }
        const reload = await browser.newPage();
        try {
          await open(reload, folded);
          const after = await reload.evaluate(() => window.__lines());
          if (JSON.stringify(after) !== JSON.stringify(seen)) throw new Error(`the reload shows ${JSON.stringify(after)}, the author saw ${JSON.stringify(seen)}`);
        } finally {
          await reload.close();
        }
      } finally {
        await page.close();
      }
    });
  }
} finally {
  await browser.close();
  server.close();
}
exitRig(t.passes, t.failures);
