// __nested_split_keys.mjs — the real-browser half of task-42d085f7431b8417.
//
// canvas/__nested_split_id_mounted.test.mjs proves the fix in jsdom; this rig types it
// in headless Chromium with real key events (Playwright's keyboard, the same input
// pipeline a person's keys take), on the committed bundle and stylesheet the Studio
// loads. For each container (section, expandable, step, tab): click into the nested
// paragraph, End, Enter, type, Enter twice, type, then split mid-text and type. Then
// two section paragraphs dragged onto a top-level line, with and without the copy
// key, and typed into. The
// page's host acknowledges every batch; afterwards every batch is folded through the
// patch.ex reference fold (smoke/harness.mjs applyOps), and the rig asserts:
//   - no block id repeats after any batch (patch.ex refuses that: duplicate_id)
//   - the fold equals what the canvas believes it saved
//   - a fresh canvas mounted on the folded blocks (the reload) shows exactly the
//     lines the author saw, every typed character included
//   - the live doc carries no id the server lacks; a copy-drop's originals keep
//     their ids, a move-drop's moved paragraphs keep theirs
// The batches are recorded into api/test/support/fixtures/paper-editor/
// nested_split_keys.json, which patch_nested_split_test.exs folds through Patch
// and the canvas batch write (NESTED_SPLIT_WRITE=1 rewrites it).
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
import { readFileSync, writeFileSync } from "node:fs";
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
const FIXTURE = join(REPO, "api/test/support/fixtures/paper-editor/nested_split_keys.json");

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

async function edgeOf(page, text, end) {
  const box = await page.evaluate(([text, end]) => {
    const walker = document.createTreeWalker(document.querySelector('[contenteditable="true"]'), NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const at = node.data.indexOf(text);
      if (at === -1) continue;
      const range = document.createRange();
      const i = end ? at + text.length - 1 : at;
      range.setStart(node, i);
      range.setEnd(node, i + 1);
      const r = range.getBoundingClientRect();
      return { x: end ? r.right - 1 : r.left + 1, y: r.top + r.height / 2 };
    }
    return null;
  }, [text, end]);
  if (!box) throw new Error(`"${text}" is not on screen`);
  return box;
}

// Select from the start of `from` to the end of `to` with the mouse (click, then
// Shift-click), then drag the selection onto the start of `before`; `copy` holds
// the copy key (Option on a Mac). Headless Chromium starts no native drag from a
// text selection, so the drag is the DragEvents a person's drag fires (dragstart
// in the selection, dragover, drop at the target), dispatched at those points:
// ProseMirror's own dragstart builds the slice, and its drop handler inserts it.
async function dragSelection(page, from, to, before, { copy }) {
  const start = await edgeOf(page, from, false);
  const end = await edgeOf(page, to, true);
  await page.mouse.click(start.x, start.y);
  await page.keyboard.down("Shift");
  await page.mouse.click(end.x, end.y);
  await page.keyboard.up("Shift");
  await page.waitForFunction(() => !document.getElementById("canvas")._editor.state.selection.empty);
  const grab = { x: start.x + 6, y: start.y };
  const target = await edgeOf(page, before, false);
  const started = await page.evaluate(([grab, target, copy]) => {
    const view = document.getElementById("canvas")._editor.view;
    const key = /Mac|iPhone|iPad|iPod/.test(navigator.platform) ? "altKey" : "ctrlKey";
    const dataTransfer = new DataTransfer();
    const fire = (type, { x, y }) => document.elementFromPoint(x, y).dispatchEvent(
      new DragEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, dataTransfer, [key]: copy }));
    fire("dragstart", grab);
    const dragging = !!view.dragging;
    fire("dragover", target);
    fire("drop", target);
    return dragging;
  }, [grab, target, copy]);
  if (!started) throw new Error("the drag did not start");
}

function words(blocks, out = []) {
  for (const block of blocks || []) {
    if (Array.isArray(block.content)) out.push(block.content.map((n) => n.value || "").join(""));
    else if (typeof block.text === "string") out.push(block.text);
    for (const key of ["blocks", "children", "steps", "tabs"]) words(block[key], out);
  }
  return out;
}

function idText(blocks, id) {
  for (const block of blocks || []) {
    if (block.id === id) return words([block])[0];
    for (const key of ["blocks", "children", "steps", "tabs"]) {
      const found = idText(block[key], id);
      if (found != null) return found;
    }
  }
  return null;
}

// Every batch folds without a refusal or a repeated id, the fold is what the canvas
// believes it saved, the live doc carries no id the server lacks, every `typed`
// string is saved, `holds` (container id → its children's [id, text]) and `owns`
// (id → its text) hold, and a fresh canvas on the fold shows what the author saw.
async function landed(page, name, blocks, typed, holds = {}, owns = {}) {
  const batches = await page.evaluate(() => window.__batches);
  const client = await page.evaluate(() => document.getElementById("canvas").blocks);
  const seen = await page.evaluate(() => window.__lines());
  const live = await page.evaluate(() => {
    const out = [];
    document.getElementById("canvas")._editor.state.doc.descendants((node) => { if (!node.isText && node.attrs.bpId != null) out.push(node.attrs.bpId); });
    return out;
  });
  let folded = structuredClone(blocks);
  for (const ops of batches) {
    folded = applyOps(folded, ops);
    const dup = repeated(ids(folded));
    if (dup.length) throw new Error(`a batch repeats ${dup.join(", ")}: ${JSON.stringify(ops)}`);
  }
  if (!isDeepStrictEqual(folded, client)) throw new Error(`the fold ${JSON.stringify(folded)} differs from what the canvas believes it saved ${JSON.stringify(client)}`);
  const unknown = live.filter((id) => !ids(folded).includes(id));
  if (unknown.length) throw new Error(`the live doc carries ${unknown.join(", ")}, which the server does not hold`);
  if (repeated(live).length) throw new Error(`the live doc repeats ${repeated(live).join(", ")}`);
  for (const [id, children] of Object.entries(holds)) {
    const have = (folded.find((block) => block.id === id)?.blocks || []).map((child) => [child.id, words([child])[0]]);
    if (!isDeepStrictEqual(have, children)) throw new Error(`${id} holds ${JSON.stringify(have)}, want ${JSON.stringify(children)}`);
  }
  for (const [id, text] of Object.entries(owns)) {
    const have = idText(folded, id);
    if (have !== text) throw new Error(`${id} reads ${JSON.stringify(have)}, want ${JSON.stringify(text)}`);
  }
  const saved = words(folded);
  for (const t of typed) {
    if (!saved.includes(t)) throw new Error(`"${t}" is not saved: ${JSON.stringify(saved)}`);
  }
  const reload = await browser.newPage();
  try {
    await open(reload, folded);
    const after = await reload.evaluate(() => window.__lines());
    if (JSON.stringify(after) !== JSON.stringify(seen)) throw new Error(`the reload shows ${JSON.stringify(after)}, the author saw ${JSON.stringify(seen)}`);
  } finally {
    await reload.close();
  }
  recorded.push({ scene: name, before: structuredClone(blocks), batches, client_after: client, typed });
}

const recorded = [];
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
        await landed(page, `keys-${name}`, blocks, ["Left", "Late at six.", "Fog lifted.", "", "Rain."]);
      } finally {
        await page.close();
      }
    });
  }

  const DROP = [p("p-a", "Alpha."), { id: "s-day", type: "section", title: "Day one", blocks: [p("p-day", "Left at six."), p("p-two", "Fog.")] }];
  for (const copy of [true, false]) {
    const name = copy ? "copy-drop" : "move-drop";
    const why = copy ? "the originals keep their ids" : "the moved paragraphs keep theirs, and a paste right after carrying p-two gets fresh ids";
    await t.checkAsync(`${name}: two section paragraphs dragged${copy ? " with the copy key" : ""} onto a top-level line, then typed into: every character folds and reloads, ${why}`, async () => {
      const page = await browser.newPage();
      try {
        await open(page, DROP);
        await dragSelection(page, "Left at six.", "Fog.", "Alpha.", { copy });
        await settle(page);
        await clickAfter(page, "Fog.Alpha.", "Fog.Alpha.".length);
        await page.keyboard.type(" Typed.");
        await settle(page);
        if (copy) {
          await landed(page, `keys-${name}`, DROP, ["Fog.Alpha. Typed.", "Left at six.", "Fog."], { "s-day": [["p-day", "Left at six."], ["p-two", "Fog."]] });
        } else {
          await clickAfter(page, "Left at six.", "Left at six.".length);
          await page.evaluate(() => {
            const clipboardData = new DataTransfer();
            const copy = (text) => `<p data-bp-id="p-two" data-bp-type="paragraph">${text}</p>`;
            clipboardData.setData("text/html", copy("Copied one.") + copy("Copied two."));
            clipboardData.setData("text/plain", "Copied one.\n\nCopied two.");
            document.querySelector('[contenteditable="true"]').dispatchEvent(new ClipboardEvent("paste", { clipboardData, bubbles: true, cancelable: true }));
          });
          await settle(page);
          await landed(page, `keys-${name}`, DROP, ["Fog.Alpha. Typed.", "Copied two."], {}, { "p-day": "Left at six.Copied one.", "p-two": "Fog.Alpha. Typed." });
        }
      } finally {
        await page.close();
      }
    });
  }

  // The recording, for patch_nested_split_test.exs to fold through Patch and the
  // canvas batch write. NESTED_SPLIT_WRITE=1 rewrites it; otherwise every scene's
  // after-state must match it, minted ids aside (batch boundaries follow timing).
  await t.checkAsync("the recording matches api/test/support/fixtures/paper-editor/nested_split_keys.json", async () => {
    const names = new Map();
    const scenes = JSON.parse(JSON.stringify(recorded).replace(/c-[0-9a-z]+-[0-9a-f]{8}/g, (id) => {
      if (!names.has(id)) names.set(id, `c-keys-${names.size + 1}`);
      return names.get(id);
    }));
    const fixture = { recorded_by: "api/assets/paper-editor/src/__nested_split_keys.mjs", scenes };
    if (process.env.NESTED_SPLIT_WRITE === "1") writeFileSync(FIXTURE, JSON.stringify(fixture, null, 2) + "\n");
    const shape = (f) => JSON.stringify(f.scenes.map(({ scene, before, client_after, typed }) => ({ scene, before, client_after, typed }))).replace(/c-keys-\d+/g, "c-keys");
    if (shape(JSON.parse(readFileSync(FIXTURE, "utf8"))) !== shape(fixture)) throw new Error("the recording's after-states differ from the fixture (NESTED_SPLIT_WRITE=1 rewrites it)");
  });
} finally {
  await browser.close();
  server.close();
}
exitRig(t.passes, t.failures);
