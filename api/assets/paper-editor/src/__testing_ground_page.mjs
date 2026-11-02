import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { exitRig, skip, tally } from "./__rig.mjs";
import { drills } from "./testing-ground/drills/index.mjs";
import { barkparkFold } from "./testing-ground/barkpark-fold.mjs";
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

async function open(query = "", prepare = async () => {}) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.errors = [];
  page.on("pageerror", (error) => page.errors.push(error.message));
  await prepare(page);
  await page.goto(`${server.url}${query}`);
  await page.waitForFunction(() => window.testingGround?.state.canvases[0]?._editor && document.querySelector(".tg-light"));
  return page;
}

async function scene(name, query, fn, prepare) {
  if (ONLY && !name.includes(ONLY)) return;
  const page = await open(query, prepare);
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
  assert.equal(await page.isVisible(".tg-steps"), false, "a block sample has no checklist");
  assert.equal(await page.evaluate(() => window.testingGround.state.canvases[0].liveRemote), false, "one window keeps the canvas's own echo rules");
  assert.deepEqual(await page.$$eval(".tg-light", (ls) => ls.map((l) => l.className)), ["tg-light tg-light--green", "tg-light tg-light--green", "tg-light tg-light--green", "tg-light tg-light--green", "tg-light tg-light--wait"]);
  const first = await page.$(".tg-light");
  await page.evaluate(() => { window.testingGround.paintLights(); window.testingGround.paintLights(); });
  assert.equal(await first.evaluate((li) => li.isConnected), true, "unchanged lights are not repainted, so their words stay selectable");
});

await scene("D01 on main lights hidden blocks red", "?doc=drill:D01", async (page) => {
  await play(page, drill("D01"));
  const lights = await lightsOf(page);
  assert.deepEqual(red(lights), ["hidden-blocks"]);
  assert.match(lights["hidden-blocks"].words, /6 lines are in the doc but hidden on screen \(9 blocks, 2 shown\)/);
  assert.equal(await page.isVisible(".tg-tab-dot"), true, "the closed drawer's tab shows a red dot");
  assert.match(lights["hidden-blocks"].words, /^Hidden blocks — red 6 lines/);
  assert.equal(await page.getAttribute('[data-trap="hidden-blocks"]', "class"), "tg-light tg-light--red");
  await page.click(".tg-tab");
  assert.deepEqual(await page.$$eval(".tg-steps li", (li) => li.map((x) => x.textContent)), drill("D01").steps.map((s) => s.say));
  assert.equal(await page.isVisible(".tg-tally"), false);
});

await scene("a hand-only step says so, and a missing word stops the player", "?doc=drill:D03", async (page) => {
  await page.click(".tg-tab");
  assert.match(await page.textContent(".tg-steps li"), /\(by hand\)$/);
  await assert.rejects(play(page, { steps: [{ click: { text: "No such words", at: "end" } }] }), /"No such words" is not on screen/);
});

await scene("D04: a double-click and Enter split the line around the word", "?doc=drill:D04", async (page) => {
  await play(page, drill("D04"));
  assert.deepEqual(red(await lightsOf(page)), []);
  assert.deepEqual(await page.evaluate(() => window.testingGround.state.host.saved.map((b) => b.content.map((n) => n.value).join(""))), ["Pack the ", " and the tent."]);
});

await scene("a click at the start of a line puts the caret before its first letter", "?doc=drill:D01", async (page) => {
  await play(page, { steps: [{ click: { text: "Beta", at: "start" } }, { type: "x" }, { click: { text: "Alpha", at: "end" } }, { type: "y" }] });
  assert.deepEqual(await page.evaluate(() => window.testingGround.state.host.saved.map((b) => b.content.map((n) => n.value).join(""))), ["Alphay", "", "xBeta"]);
});

await scene("D07 counts how often ArrowDown skips the hidden empty line", "?doc=drill:D07", async (page) => {
  await play(page, drill("D07"));
  await page.click(".tg-tab");
  const words = await page.textContent(".tg-tally");
  assert.match(words, /^↓ skipped the empty line in [0-8] of 8 tries\.$/);
  const { tries, hits } = await page.evaluate(() => window.testingGround.state.tally);
  assert.equal(tries, 8);
  assert.equal(await page.getAttribute(".tg-tally", "class"), hits < tries ? "tg-tally tg-tally--red" : "tg-tally");
  console.log(`      D07 on this build: ${words}`);
  await page.evaluate(() => window.testingGround.openDoc("drill:D01"));
  assert.equal(await page.isVisible(".tg-tally"), false);
  await page.evaluate(() => window.testingGround.openDoc("drill:D07"));
  assert.equal(await page.textContent(".tg-tally"), "↓ skipped the empty line in 0 of 0 tries.", "another doc starts the count over");
  assert.match(await page.textContent(".tg-steps"), /Pick D07 again and repeat, 8 tries in all/);
});

await scene("under the hood: batches with the server's answer, the diff and the saved doc", "?doc=drill:D02", async (page) => {
  await page.click(".tg-tab");
  await page.click('[data-section="hood"] summary');
  await page.waitForFunction(() => document.querySelector(".tg-diff").textContent === "nothing yet");
  assert.equal(await page.textContent(".tg-fold"), "Fold: Reference fold (the JS mirror of patch.ex)");
  await play(page, { steps: [{ click: { text: "Home by dark.", at: "end" } }, { type: "!" }] });
  await page.waitForFunction(() => document.querySelector(".tg-batches li"));
  assert.deepEqual(await page.$$eval(".tg-batches li", (li) => li.map((x) => x.textContent)), ["#1 patch-block p-after → saved"]);
  assert.equal(await page.textContent(".tg-diff"), "~ p-after (paragraph)");
  assert.match(await page.textContent(".tg-json"), /"value": "Home by dark\.!"/);
  await play(page, drill("D02"));
  const batches = await page.$$eval(".tg-batches li", (li) => li.map((x) => x.textContent));
  assert.match(batches.join("\n"), /#\d+ replace-block s-day → refused: replace-block: duplicate id p-day/);
  await play(page, { steps: [{ click: { text: "Trip", at: "end" } }, { key: "Enter" }, { type: "z" }] });
  assert.match((await page.$$eval(".tg-batches li", (li) => li.map((x) => x.textContent))).join("\n"), /insert-after c-\d/);
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
  const words = await page.evaluate(() => window.testingGround.state.host.saved.map((b) => b.content.map((n) => n.value || n.children?.[0]?.value).join("")));
  assert.deepEqual(words, ["A body paragraph with bold emphasis inside it, ok ", "nexta marked link and a link node."]);
});

await scene("the reader shows the golden HTML, then the labeled stand-in after an edit", "?doc=sample:callout&reader=1", async (page) => {
  assert.match(await page.textContent(".tg-read-label"), /^Golden reader HTML/);
  assert.match(await page.innerHTML(".tg-read-body"), /This is a warning callout body\./);
  await play(page, { steps: [{ click: { text: "callout body.", at: "end" } }, { type: " Edited" }] });
  await page.waitForFunction(() => document.querySelector(".tg-read-body").textContent.includes("Edited"));
  assert.match(await page.textContent(".tg-read-label"), /^Stand-in: the @barkpark\/react render of this doc, not the golden reader\./);
  assert.match(await page.textContent(".tg-read-body"), /callout body\. Edited/);
  await page.click(".tg-tab");
  await page.uncheck(".tg-reader");
  await play(page, { steps: [{ click: { text: "Edited", at: "end" } }, { type: "Z" }] });
  assert.doesNotMatch(await page.textContent(".tg-read-body"), /EditedZ/, "a hidden reader is not repainted");
});

await scene("a stand-in that throws shows its error in the reader", "?doc=drill:D01&reader=1", async (page) => {
  assert.match(await page.textContent(".tg-read-label"), /^Stand-in:/, "a drill has no golden");
  await page.waitForFunction(() => document.querySelector(".tg-read-body").textContent === "stand-in broke");
}, (page) => page.route("**/reader-standin.js", (route) => route.fulfill({ contentType: "text/javascript", body: "export const render = () => { throw new Error('stand-in broke'); };" })));

await scene("fleet blocks are painted from the pack's fragments", "?doc=sample:heatmap", async (page) => {
  await page.waitForFunction(() => document.querySelector("[data-bp-fleet-body][data-tg-painted]"));
  const [painted, fragment] = await page.evaluate(async () => [document.querySelector("[data-bp-fleet-body]").innerHTML, (await (await fetch("/pack/fragments.json")).json()).heatmap]);
  assert.equal(painted, fragment);
});

await scene("a fleet block the canvas does not paint gets the fragment from the host", "?doc=sample:roadmap", async (page) => {
  await page.waitForFunction(() => document.querySelector("[data-bp-fleet-body][data-tg-painted]"));
  const [painted, fragment] = await page.evaluate(async () => [document.querySelector("[data-bp-fleet-body]").innerHTML, (await (await fetch("/pack/fragments.json")).json()).roadmap]);
  assert.equal(painted, fragment);
});

await scene("a fleet block the canvas paints itself is left to the canvas", "?doc=sample:roadmap", async (page) => {
  await page.waitForFunction(() => document.querySelector("[data-bp-fleet-body][data-tg-painted]"));
  assert.equal(await page.innerHTML("[data-bp-fleet-body]"), "<p>the canvas painted this</p>");
}, (page) => page.addInitScript(() => document.addEventListener("bp-fleet-paint", (event) => { event.preventDefault(); event.target.innerHTML = "<p>the canvas painted this</p>"; }, true)));

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

await scene("every test doc opens: 7 drills and 80 block samples, none with a duplicate id", "", async (page) => {
  await page.click(".tg-tab");
  const keys = await page.$$eval(".tg-doc option", (options) => options.map((o) => o.value));
  assert.equal(keys.filter((k) => k.startsWith("drill:")).length, 7);
  assert.equal(keys.filter((k) => k.startsWith("sample:")).length, 80);
  const bad = [];
  for (const key of keys) {
    await page.selectOption(".tg-doc", key);
    await page.waitForFunction(() => window.testingGround.state.canvases[0]._editor);
    const lights = await lightsOf(page);
    if (lights["duplicate-ids"].ok !== "true" || lights["refused-batches"].ok !== "true") bad.push(key);
  }
  assert.deepEqual(bad, []);
  const windows = await page.evaluate(() => { window.testingGround.openDoc("drill:D06"); return [...document.querySelectorAll(".tg-edit bp-paper-canvas")].map((c) => c.liveRemote); });
  assert.deepEqual(windows, [true, true], "D06 opens two windows on one host, each taking the other's saves live");
});

if (process.env.TG_BARKPARK) {
  const local = await start({ fold: barkparkFold(process.env.TG_BARKPARK, process.env.BARKPARK_TG_TOKEN) });
  const page = await browser.newPage();
  await t.checkAsync("D02 through a local Barkpark: patch.ex itself refuses the batch", async () => {
    await page.goto(`${local.url}?doc=drill:D02`);
    await page.waitForFunction(() => window.testingGround?.state.canvases[0]?._editor && document.querySelector(".tg-light"));
    await play(page, drill("D02"));
    const lights = await lightsOf(page);
    assert.deepEqual(red(lights), ["duplicate-ids", "refused-batches", "lost-keys"]);
    assert.match(lights["refused-batches"].words, /Barkpark answered 422 to POST \/v1\/data\/doc\/production\/post\/tg-\d+\/ops: .*invalid_op/);
  });
  await page.close();
  await local.close();
}

await browser.close();
await server.close();
exitRig(t.passes, t.failures);
