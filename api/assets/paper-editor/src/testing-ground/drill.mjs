import { readFileSync } from "node:fs";
import { chromium } from "./chromium.mjs";
import { makeBuild, pickBuild } from "./builds.mjs";
import { drills } from "./drills/index.mjs";
import { lightsOf, play } from "./play.mjs";
import { mainBuild, REPO, start } from "./server.mjs";
import { drillFromRepro } from "./repro.mjs";
import { needsHands, verdict } from "./verdict.mjs";

function usage(why) {
  console.error(`npm run drill: ${why}\nusage: npm run drill <drill id …> | all [-- --build=<main | PR number | contract like 1.19>]\n       npm run drill -- --repro=<repro.json> [--build=…]\n  drills: ${drills.map((d) => d.id).join(", ")}`);
  process.exit(2);
}

for (const signal of ["SIGINT", "SIGTERM"]) process.once(signal, () => process.exit(130));
const args = process.argv.slice(2);
const bad = args.find((a) => a.startsWith("--") && !/^--(build|repro)=.+$/.test(a));
if (bad) usage(`unknown or malformed flag ${bad}`);
const flag = (name) => {
  const given = args.filter((a) => a.startsWith(`--${name}=`));
  if (given.length > 1) usage(`--${name} given twice`);
  return given[0]?.slice(name.length + 3);
};
const which = flag("build") || "main";
const repro = flag("repro");
const names = args.filter((a) => !a.startsWith("--"));
if (repro && names.length) usage("a repro or drill names, not both");
if (!repro && !names.length) usage("name a drill, or all");
function fromRepro(file) {
  try {
    return [drillFromRepro(JSON.parse(readFileSync(file, "utf8")))];
  } catch (error) {
    usage(`--repro=${file} is not a repro: ${error.message}`);
  }
}
const asked = repro ? fromRepro(repro) : names.includes("all") ? drills : names.map((id) => drills.find((d) => d.id === id) || usage(`no drill ${id}`));
let pick;
try {
  pick = which === "main" ? null : pickBuild(which, { repo: REPO });
} catch (error) {
  usage(error.message);
}

let build;
try {
  if (pick) console.log(`building ${pick.label} at ${pick.sha.slice(0, 10)}`);
  build = pick ? makeBuild(pick, { repo: REPO }) : mainBuild();
} catch (error) {
  console.error(`npm run drill: ${error.message}`);
  process.exit(1);
}

const server = await start({ builds: [build] });
const browser = await chromium();
const on = `on ${build.label} at ${build.sha}`;
let passed = 0;
let failed = 0;
for (const drill of asked) {
  const hands = needsHands(drill);
  if (hands) {
    console.log(`HANDS ${drill.id} ${drill.title} ${on}: needs hands at "${hands.say}"`);
    continue;
  }
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(`${server.url}?doc=${drill.open || `drill:${drill.id}`}`);
  await page.waitForFunction(() => window.testingGround?.state.canvases[0]?._editor && document.querySelector(".tg-light"));
  await play(page, drill);
  const { ok, words } = verdict(drill, await lightsOf(page), await page.evaluate(() => window.testingGround.state.tally), errors);
  console.log(`${ok ? "PASS " : "FAIL "} ${drill.id} ${drill.title} ${on}: ${words}`);
  if (ok) passed++;
  else failed++;
  await page.close();
}
await browser.close();
await server.close();
if (!passed && !failed) console.log("FAIL  nothing ran: every drill asked for needs hands");
process.exit(failed || !passed ? 1 : 0);
