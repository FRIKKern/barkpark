import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { exitRig, skip, tally } from "./__rig.mjs";
import { drills } from "./testing-ground/drills/index.mjs";
import { lightsOf, play } from "./testing-ground/play.mjs";
import { start } from "./testing-ground/server.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "../../../..");
const ONLY = process.env.TG_ONLY;

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
if (!pw) process.exit(skip("__testing_ground_page.mjs — playwright not found (set BP_PLAYWRIGHT_FROM)."));
let browser;
try {
  browser = await pw.chromium.launch();
} catch (error) {
  process.exit(skip(`__testing_ground_page.mjs — no Chromium for playwright: ${error.message.split("\n")[0]}`));
}
const server = await start();
const t = tally();

async function open(query = "") {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.errors = [];
  page.on("pageerror", (error) => page.errors.push(error.message));
  await page.goto(`${server.url}${query}`);
  await page.waitForFunction(() => window.testingGround?.state.canvases[0]?._editor && document.querySelector(".tg-light"));
  return page;
}

async function scene(name, query, fn) {
  if (ONLY && !name.includes(ONLY)) return;
  const page = await open(query);
  try {
    await t.checkAsync(name, async () => {
      await fn(page);
      assert.deepEqual(page.errors, [], "page errors");
    });
  } finally {
    await page.close();
  }
}

const drill = (id) => drills.find((d) => d.id === id);
const red = (lights) => Object.entries(lights).filter(([, l]) => l.ok === "false").map(([key]) => key);

await scene("opens as a plain editor: drawer closed, no light red", "", async (page) => {
  assert.equal(await page.isVisible("#tg-drawer"), false);
  assert.equal(await page.getAttribute(".tg-tab", "aria-expanded"), "false");
  assert.equal(await page.isVisible(".tg-tab-dot"), false);
  await page.click(".tg-tab");
  assert.equal(await page.isVisible("#tg-drawer"), true);
  assert.deepEqual(await page.$$eval("#tg-drawer summary", (s) => s.map((x) => x.textContent)), ["Live checks", "Preview and test docs", "Versions", "Under the hood"]);
  assert.match(await page.textContent(".tg-build"), /^Editor build: main at [0-9a-f]{7,}$/);
  assert.deepEqual(red(await lightsOf(page)), []);
});

await scene("D01 on main lights hidden blocks red", "?doc=drill:D01", async (page) => {
  await play(page, drill("D01"));
  const lights = await lightsOf(page);
  assert.deepEqual(red(lights), ["hidden-blocks"]);
  assert.match(lights["hidden-blocks"].words, /6 lines are in the doc but hidden on screen \(9 blocks, 2 shown\)/);
  assert.equal(await page.isVisible(".tg-tab-dot"), true, "the closed drawer's tab shows a red dot");
});

await scene("D02 on main lights duplicate ids, refused batches and lost keys red", "?doc=drill:D02", async (page) => {
  await play(page, drill("D02"));
  const lights = await lightsOf(page);
  assert.deepEqual(red(lights), ["duplicate-ids", "refused-batches", "lost-keys"]);
  assert.match(lights["duplicate-ids"].words, /Used twice: p-day/);
  assert.match(lights["refused-batches"].words, /replace-block: duplicate id p-day/);
  assert.match(lights["lost-keys"].words, /13 characters you typed did not come back after the reload: "Fog by eight\."/);
});

await scene("a fold that drops ops lights fold drift, then lost keys after a reload", "?doc=sample:paragraph", async (page) => {
  await page.evaluate(() => { window.testingGround.state.host.fold = { name: "drops every op", apply: async (blocks) => blocks }; });
  await play(page, { steps: [{ click: { text: "inside it, ", at: "end" } }, { type: "zz" }] });
  assert.deepEqual(red(await lightsOf(page)), ["fold-drift"]);
  await play(page, { steps: [{ reload: true }] });
  const lights = await lightsOf(page);
  assert.deepEqual(red(lights), ["lost-keys"], "the reload took the server's copy, so the editor and server agree again");
  assert.match(lights["lost-keys"].words, /2 characters you typed did not come back after the reload: "zz"/);
});

await scene("typing and a reload on a sound build keep every light green", "?doc=sample:paragraph", async (page) => {
  await play(page, { steps: [{ click: { text: "inside it, ", at: "end" } }, { type: "ok " }, { key: "Enter" }, { type: "next" }, { reload: true }] });
  const lights = await lightsOf(page);
  assert.deepEqual(Object.values(lights).map((l) => l.ok), ["true", "true", "true", "true", "true"]);
  assert.match(await page.evaluate(() => JSON.stringify(window.testingGround.state.host.saved)), /ok .*next/);
});

await scene("the reader shows the golden HTML, then the labeled stand-in after an edit", "?doc=sample:callout&reader=1", async (page) => {
  assert.match(await page.textContent(".tg-read-label"), /^Golden reader HTML/);
  assert.match(await page.innerHTML(".tg-read-body"), /This is a warning callout body\./);
  await play(page, { steps: [{ click: { text: "callout body.", at: "end" } }, { type: " Edited" }] });
  await page.waitForFunction(() => document.querySelector(".tg-read-label").textContent.startsWith("Stand-in"));
  assert.match(await page.textContent(".tg-read-label"), /^Stand-in: the @barkpark\/react render of this doc, not the golden reader\./);
  assert.match(await page.textContent(".tg-read-body"), /callout body\. Edited/);
});

await scene("phone width and dark mode", "?doc=sample:paragraph&phone=1&dark=1", async (page) => {
  assert.equal(await page.evaluate(() => document.querySelector(".tg-stage").getBoundingClientRect().width), 390);
  assert.equal(await page.getAttribute("html", "data-theme"), "dark");
  assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor), "rgb(14, 22, 20)");
  await page.click(".tg-tab");
  await page.uncheck(".tg-dark");
  assert.equal(await page.getAttribute("html", "data-theme"), "light");
  assert.match(page.url(), /phone=1/);
  assert.doesNotMatch(page.url(), /dark=1/);
});

await scene("every test doc opens: 6 drills and 80 block samples, none with a duplicate id", "", async (page) => {
  await page.click(".tg-tab");
  const keys = await page.$$eval(".tg-doc option", (options) => options.map((o) => o.value));
  assert.equal(keys.filter((k) => k.startsWith("drill:")).length, 6);
  assert.equal(keys.filter((k) => k.startsWith("sample:")).length, 80);
  const bad = [];
  for (const key of keys) {
    await page.selectOption(".tg-doc", key);
    await page.waitForFunction(() => window.testingGround.state.canvases[0]._editor);
    const lights = await lightsOf(page);
    if (lights["duplicate-ids"].ok !== "true" || lights["refused-batches"].ok !== "true") bad.push(key);
  }
  assert.deepEqual(bad, []);
  const windows = await page.evaluate(() => { window.testingGround.openDoc("drill:D06"); return document.querySelectorAll(".tg-edit bp-paper-canvas").length; });
  assert.equal(windows, 2, "D06 opens two windows on one host");
});

await browser.close();
await server.close();
exitRig(t.passes, t.failures);
