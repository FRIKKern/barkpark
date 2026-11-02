import { createServer } from "node:http";
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { exitRig, skip, tally } from "./__rig.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "../../../..");
const FIXTURE = join(REPO, "api/test/support/fixtures/paper-editor/duplicate_ids_keys.json");
const ASSET = "api/priv/static/assets";

const CONTRACTS = [
  ["1.14", "076e56cabd"],
  ["1.15", "e4b1f152b1"],
  ["1.16", "c4461c97ee"],
  ["1.17", "0a02feca5b"],
  ["1.18", "b2e84d5d50"],
  ["1.19", "648bfeeb44"],
  ["1.20", "d14236b0ee"],
  ["1.21", "d092a5b5ab"],
  ["tree", null],
  ["pr-25040", "d64d04625c"],
];

function asset(commit, name) {
  if (commit == null) return readFileSync(join(REPO, ASSET, name));
  return execFileSync("git", ["show", `${commit}:${ASSET}/${name}`], { cwd: REPO, maxBuffer: 1 << 26 });
}

function playwright() {
  const common = execFileSync("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: REPO, encoding: "utf8" }).trim();
  try {
    return createRequire(join(dirname(common), "js", "package.json"))("playwright");
  } catch {
    return null;
  }
}

const pw = playwright();
if (!pw) process.exit(skip("__duplicate_ids_keys.mjs — playwright not found in the main checkout js/."));
let browser;
try {
  browser = await pw.chromium.launch();
} catch (error) {
  process.exit(skip(`__duplicate_ids_keys.mjs — no Chromium for playwright: ${error.message.split("\n")[0]}`));
}

const PAGE = (contract) => `<!doctype html><html><head><meta charset="utf-8">
<script>window.BP_PAPER_EDITOR_NO_INJECT = true;</script>
<link rel="stylesheet" href="/${contract}/bp-paper-editor.css"></head>
<body><bp-paper-canvas id="canvas"></bp-paper-canvas>
<script src="/${contract}/bp-paper-editor.bundle.js"></script>
<script>
  const canvas = document.getElementById("canvas");
  window.__batches = [];
  window.__echoes = [];
  window.__order = "reply-first";
  canvas.acknowledgedSaves = true;
  const remint = (blocks) => {
    const seen = new Set();
    const rows = (list) => list.map((row) => {
      seen.add(row.id);
      return Array.isArray(row.blocks) ? { ...row, blocks: walk(row.blocks, row.id) } : row;
    });
    const walk = (list, parent) => list.map((block, index) => {
      const id = block.id != null && seen.has(block.id) ? parent + "-" + index : block.id;
      seen.add(id);
      const out = { ...block, id };
      if (Array.isArray(block.blocks)) out.blocks = walk(block.blocks, id);
      for (const key of ["steps", "tabs"]) if (Array.isArray(block[key])) out[key] = rows(block[key]);
      return out;
    });
    return walk(blocks, "block");
  };
  window.__ids = (blocks) => blocks.flatMap((block) => [
    block.id,
    ...window.__ids(block.blocks || []),
    ...[...(block.steps || []), ...(block.tabs || [])].flatMap((row) => [row.id, ...window.__ids(row.blocks || [])]),
  ]);
  canvas.addEventListener("bp-canvas-ops", (event) => {
    const { seq, ops } = event.detail;
    window.__batches.push(JSON.parse(JSON.stringify(ops)));
    const requestId = "r" + seq;
    canvas.identifyOpsRequest?.(seq, requestId);
    const echo = remint(JSON.parse(JSON.stringify(canvas._inflightOps.afterBlocks)));
    window.__echoes.push(echo);
    setTimeout(() => {
      if (window.__order === "echo-first") canvas.applyServerBlocks(echo, { mode: "own", requestId });
      canvas.acknowledgeOps(seq, true);
      if (window.__order === "reply-first") canvas.applyServerBlocks(echo, { mode: "own", requestId });
    }, 0);
  });
  window.__mount = (blocks) => { canvas.blocks = blocks; };
  window.__lines = () => {
    const out = [];
    canvas._editor.state.doc.descendants((node) => { if (node.isTextblock) out.push(node.textContent); });
    return out;
  };
</script></body></html>`;

const commits = new Map(CONTRACTS);
const cache = new Map();
const server = createServer((req, res) => {
  const [contract, name] = req.url.split("?")[0].slice(1).split("/");
  if (!commits.has(contract)) { res.statusCode = 404; return res.end(); }
  if (name === "") return res.end(PAGE(contract));
  if (!["bp-paper-editor.css", "bp-paper-editor.bundle.js"].includes(name)) { res.statusCode = 404; return res.end(); }
  const key = `${contract}/${name}`;
  if (!cache.has(key)) cache.set(key, asset(commits.get(contract), name));
  res.setHeader("content-type", name.endsWith(".css") ? "text/css" : "text/javascript");
  res.end(cache.get(key));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}/`;

const p = (id, value) => ({ id, type: "paragraph", content: [{ type: "text", value }] });
const section = (id, blocks) => ({ id, type: "section", title: id, blocks });

async function open(page, contract, blocks, order = "reply-first") {
  await page.goto(`${origin}${contract}/`);
  await page.evaluate((o) => { window.__order = o; }, order);
  await page.waitForFunction(() => customElements.get("bp-paper-canvas"));
  await page.evaluate((b) => window.__mount(b), blocks);
  await page.waitForFunction(() => document.getElementById("canvas")._editor);
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

async function clickEnd(page, text) {
  await clickAt(page, await edgeOf(page, text, true), `the caret after "${text}"`);
}

async function clickAt(page, box, what) {
  await page.mouse.click(box.x, box.y);
  await waitFor(page, what, () => {
    const view = document.getElementById("canvas")._editor.view;
    const dom = getSelection();
    return view.state.selection.from === view.posAtDOM(dom.anchorNode, dom.anchorOffset);
  });
}

async function settle(page) {
  await page.evaluate(() => document.getElementById("canvas").flushPendingChanges());
  await waitFor(page, "the save", () => {
    const canvas = document.getElementById("canvas");
    return !canvas.hasPendingChanges() && !canvas._inflightOps;
  });
}

async function waitFor(page, what, fn, arg = null) {
  try {
    await page.waitForFunction(fn, arg, { timeout: 10000 });
  } catch {
    const state = await page.evaluate(() => {
      const view = document.getElementById("canvas")._editor.view;
      const dom = getSelection();
      return { pm: view.state.selection.toJSON(), dom: dom.anchorNode && view.posAtDOM(dom.anchorNode, dom.anchorOffset), pending: document.getElementById("canvas").hasPendingChanges() };
    });
    throw new Error(`waited 10 s for ${what}: ${JSON.stringify(state)}`);
  }
}

async function dragSelection(page, from, to, before) {
  const start = await edgeOf(page, from, false);
  await clickAt(page, start, `the caret before "${from}"`);
  await page.evaluate(([from, to]) => {
    const walker = document.createTreeWalker(document.querySelector('[contenteditable="true"]'), NodeFilter.SHOW_TEXT);
    const at = {};
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.data.includes(from) && !at.from) at.from = [node, node.data.indexOf(from)];
      if (node.data.includes(to)) at.to = [node, node.data.indexOf(to) + to.length];
    }
    getSelection().setBaseAndExtent(...at.from, ...at.to);
  }, [from, to]);
  await waitFor(page, "the selection", () => !document.getElementById("canvas")._editor.state.selection.empty);
  const grab = { x: start.x + 6, y: start.y };
  const target = await edgeOf(page, before, false);
  const started = await page.evaluate(([grab, target]) => {
    const view = document.getElementById("canvas")._editor.view;
    const dataTransfer = new DataTransfer();
    const fire = (type, { x, y }) => document.elementFromPoint(x, y).dispatchEvent(
      new DragEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, dataTransfer }));
    fire("dragstart", grab);
    const dragging = !!view.dragging;
    fire("dragover", target);
    fire("drop", target);
    return dragging;
  }, [grab, target]);
  if (!started) throw new Error("the drag did not start");
}

const UP = [
  section("s-1", [p("p-a", "Alpha.")]),
  section("s-2", [p("p-b", "Beta."), p("p-x", "Original X."), p("p-y", "Original Y.")]),
];
const DOWN = [
  section("s-1", [p("p-a", "Alpha."), p("p-x", "Original X."), p("p-y", "Original Y.")]),
  section("s-2", [p("p-b", "Beta.")]),
];
const TRIP = [
  section("s-day", [p("p-day", "Left the car park at six."), p("p-ice", "Ice on the north face.")]),
  p("p-after", "Home by dark."),
];

const STEPS = [
  { id: "st", type: "steps", steps: [{ id: "r-1", title: "One", blocks: [p("p-s", "Pack the tent.")] }] },
  p("p-after", "Home by dark."),
];
const TABS = [
  { id: "tb", type: "tabs", tabs: [{ id: "r-1", label: "One", blocks: [p("p-s", "Pack the tent.")] }] },
  p("p-after", "Home by dark."),
];
const enterInRow = async (page) => {
  await clickEnd(page, "Pack the tent.");
  await page.keyboard.press("Enter");
  await page.keyboard.type("Boots.");
  await settle(page);
  await page.keyboard.type(" Laces.");
  await settle(page);
};

const SCENES = [
  ["move-up", UP, ["Original X. More.", "Original Y.Alpha.", "Beta."], async (page) => {
    await dragSelection(page, "Original X.", "Original Y.", "Alpha.");
    await settle(page);
    await clickEnd(page, "Original X.");
    await page.keyboard.type(" More.");
    await settle(page);
  }],
  ["move-down", DOWN, ["Alpha.", "Original X. More.", "Original Y.Beta."], async (page) => {
    await dragSelection(page, "Original X.", "Original Y.", "Beta.");
    await settle(page);
    await clickEnd(page, "Original X.");
    await page.keyboard.type(" More.");
    await settle(page);
  }],
  ["nested-enter-keep-typing", TRIP, ["Left the car park at six.", "Fog by eight. Then rain."], async (page) => {
    await clickEnd(page, "Left the car park at six.");
    await page.keyboard.press("Enter");
    await page.keyboard.type("Fog by eight.");
    await settle(page);
    await page.keyboard.type(" Then rain.");
    await settle(page);
  }],
  ["nested-enter-back-up", TRIP, ["Left the car park at six. Late.", "Fog by eight."], async (page) => {
    await clickEnd(page, "Left the car park at six.");
    await page.keyboard.press("Enter");
    await page.keyboard.type("Fog by eight.");
    await settle(page);
    await clickEnd(page, "Left the car park at six.");
    await page.keyboard.type(" Late.");
    await settle(page);
  }],
  ["nested-enter-retype-line", TRIP, ["Left the car park at six.", "Mist."], async (page) => {
    await clickEnd(page, "Left the car park at six.");
    await page.keyboard.press("Enter");
    await page.keyboard.type("Fog by eight.");
    await settle(page);
    for (const _ of "Fog by eight.") await page.keyboard.press("Shift+ArrowLeft");
    await page.keyboard.type("Mist.");
    await settle(page);
  }],
  ["nested-enter-pause-type-above", TRIP, ["Left the car park at six. Abc"], async (page) => {
    await clickEnd(page, "Left the car park at six.");
    await page.keyboard.press("Enter");
    await settle(page);
    await clickEnd(page, "Left the car park at six.");
    for (const typed of [" A", "b", "c"]) {
      await page.keyboard.type(typed);
      await settle(page);
    }
  }],
  ["nested-enter-line-start", TRIP, ["So then Left the car park at six."], async (page) => {
    await clickAt(page, await edgeOf(page, "Left the car park at six.", false), "the caret before the line");
    await page.keyboard.press("Enter");
    await settle(page);
    for (const typed of ["So ", "then "]) {
      await page.keyboard.type(typed);
      await settle(page);
    }
  }],
  ["steps-enter", STEPS, ["Pack the tent.", "Boots. Laces."], enterInRow],
  ["tabs-enter", TABS, ["Pack the tent.", "Boots. Laces."], enterInRow],
];
const ORDERS = {
  "move-up": ["reply-first"],
  "move-down": ["reply-first"],
  "nested-enter-keep-typing": ["reply-first", "echo-first"],
  "nested-enter-back-up": ["reply-first", "echo-first"],
  "nested-enter-retype-line": ["reply-first", "echo-first"],
  "nested-enter-pause-type-above": ["reply-first", "echo-first"],
  "nested-enter-line-start": ["reply-first", "echo-first"],
  "steps-enter": ["reply-first", "echo-first"],
  "tabs-enter": ["reply-first", "echo-first"],
};

const recorded = [];
const t = tally();
try {
  for (const [contract, commit] of CONTRACTS) {
    for (const [scene, before, typed, play] of SCENES) for (const order of ORDERS[scene]) {
      await t.checkAsync(`${contract} ${scene} ${order}: real keys and a real drop, every typed line on screen, a reload of what the client believes shows it`, async () => {
        const page = await browser.newPage();
        try {
          await open(page, contract, before, order);
          await play(page);
          const batches = await page.evaluate(() => window.__batches);
          const echoes = await page.evaluate(() => window.__echoes);
          const client = await page.evaluate(() => document.getElementById("canvas").blocks);
          const seen = await page.evaluate(() => window.__lines());
          for (const line of typed) {
            if (!seen.includes(line)) throw new Error(`"${line}" is not on screen: ${JSON.stringify(seen)}`);
          }
          const reload = await browser.newPage();
          try {
            await open(reload, contract, client);
            const after = await reload.evaluate(() => window.__lines());
            if (JSON.stringify(after) !== JSON.stringify(seen)) throw new Error(`a reload of the client's blocks shows ${JSON.stringify(after)}, the author saw ${JSON.stringify(seen)}`);
          } finally {
            await reload.close();
          }
          await page.evaluate(() => document.getElementById("canvas")._editor.view.dom.blur());
          const want = JSON.stringify(await page.evaluate((echo) => window.__ids(echo), echoes.at(-1)));
          await waitFor(page, "the client to take the last echo's ids after a blur",
            (want) => JSON.stringify(window.__ids(document.getElementById("canvas").blocks)) === want, want);
          recorded.push({ contract, commit, scene, order, before, batches, echoes, client_after: client, seen, typed });
        } finally {
          await page.close();
        }
      });
    }
  }

  await t.checkAsync("the recording matches api/test/support/fixtures/paper-editor/duplicate_ids_keys.json", async () => {
    const names = new Map();
    const scenes = JSON.parse(JSON.stringify(recorded).replace(/c-[0-9a-z]+-[0-9a-f]{8}/g, (id) => {
      if (!names.has(id)) names.set(id, `c-keys-${names.size + 1}`);
      return names.get(id);
    }));
    const fixture = { recorded_by: "api/assets/paper-editor/src/__duplicate_ids_keys.mjs", scenes };
    const text = oneScenePerLine(fixture);
    if (process.env.DUPLICATE_IDS_WRITE === "1") writeFileSync(FIXTURE, text);
    if (readFileSync(FIXTURE, "utf8") !== text) throw new Error("the recording's batches, echoes or screens differ from the fixture (DUPLICATE_IDS_WRITE=1 rewrites it)");
  });
} finally {
  await browser.close();
  server.close();
}
exitRig(t.passes, t.failures);

function oneScenePerLine({ recorded_by, scenes }) {
  return `{"recorded_by":${JSON.stringify(recorded_by)},"scenes":[\n${scenes.map((scene) => JSON.stringify(scene)).join(",\n")}\n]}\n`;
}
