import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { drills } from "./drills/index.mjs";
import { chromium } from "./chromium.mjs";
import { doors } from "./play.mjs";
import { lights } from "./traps.mjs";
import { needsHands, verdict } from "./verdict.mjs";

const calm = { visibility: [true], believed: [], saved: [], batches: [], refusals: [], settled: true, reload: null };
const traps = lights(calm).map((l) => l.key);
const files = readdirSync(new URL("./drills/", import.meta.url)).filter((name) => /^D\d\d-/.test(name));
assert.deepEqual(drills.map((d) => d.id), files.map((name) => name.slice(0, 3)), "every drill file is in the menu, in order");
for (const drill of drills) {
  assert.match(drill.title, /\S/, `${drill.id} has a title`);
  assert.ok(drill.green.every((key) => traps.includes(key)), `${drill.id} names only real lights: ${drill.green}`);
  assert.equal(Boolean(drill.tally), Boolean(drill.repeat), `${drill.id}: a tally needs a repeat count`);
  for (const step of drill.steps) {
    assert.match(step.say, /\S/, `${drill.id}: every step says what a person does`);
    const acts = Object.keys(step).filter((key) => key in doors || key === "hands");
    assert.equal(acts.length, 1, `${drill.id}: "${step.say}" is one act, played or by hand`);
  }
}

const lit = (red = {}) => Object.fromEntries(traps.map((key) => [key, red[key] ? { ok: red[key][0], words: red[key][1] } : { ok: "true", words: `${key} fine` }]));
const d01 = drills.find((d) => d.id === "D01");
const d07 = drills.find((d) => d.id === "D07");
const quiet = { tries: 0, hits: 0, stayed: 0 };
assert.deepEqual(verdict(d01, lit(), quiet, []), { ok: true, words: "hidden-blocks, lost-keys green" });
assert.deepEqual(verdict(d01, lit({ "hidden-blocks": ["false", "Hidden blocks — red 6 lines"] }), quiet, []), { ok: false, words: "Hidden blocks — red 6 lines" });
assert.deepEqual(verdict(d01, lit({ "lost-keys": ["null", "Lost keys: reload to check"] }), quiet, []), { ok: false, words: "Lost keys: reload to check" }, "a light with no verdict is not green");
assert.deepEqual(verdict(d01, lit({ "duplicate-ids": ["false", "dup"] }), quiet, []), { ok: true, words: "hidden-blocks, lost-keys green" }, "only the drill's own lights decide");
assert.deepEqual(verdict(d01, lit(), quiet, ["boom"]), { ok: false, words: "page error: boom" });
assert.deepEqual(verdict(d07, lit(), { tries: 8, hits: 0, stayed: 0 }, []), { ok: true, words: "the tally green" }, "ArrowDown never lands in a hidden empty line, so a skip is green");
assert.deepEqual(verdict(d07, lit(), { tries: 8, hits: 1, stayed: 0 }, []), { ok: false, words: "↓ skipped the empty line in 7 of 8 tries." });
assert.deepEqual(verdict(d07, lit(), { tries: 7, hits: 0, stayed: 1 }, []), { ok: false, words: "↓ skipped the empty line in 7 of 7 tries. The caret stayed put 1 time." }, "a caret that stays put did not skip either");
assert.deepEqual(verdict({ ...d01, green: [] }, lit(), quiet, []), { ok: false, words: "nothing to check: no light was red when this was recorded, so add a check to the drill" }, "a drill that checks nothing cannot pass");
assert.equal(needsHands(drills.find((d) => d.id === "D06")).say, "In the top editor, type at the end of \"Window A types here.\"");
assert.equal(needsHands(d01), undefined);

const DRILL = fileURLToPath(new URL("./drill.mjs", import.meta.url));
for (const [args, why] of [
  [[], /name a drill, or all/],
  [["D99"], /no drill D99/],
  [["x--y"], /no drill x--y/],
  [["--repro=/no/--build=1.99"], /--repro=\/no\/--build=1\.99 is not a repro: ENOENT/],
  [["D01", "--fast"], /unknown or malformed flag --fast/],
  [["D01", "--build="], /unknown or malformed flag --build=/],
  [["D01", "--build=1.99"], /no recorded tree for contract 1\.99/],
  [["D01", "--build=x"], /a build is main, a PR number or a contract like 1\.19, got x/],
  [["D01", "--build=main", "--build=1.19"], /--build given twice/],
  [["--repro=a.json", "--repro=b.json"], /--repro given twice/],
  [["D01", "--repro=a.json"], /a repro or drill names, not both/],
  [["--repro="], /unknown or malformed flag --repro=/],
  [["--repro=/no/such/repro.json"], /--repro=\/no\/such\/repro\.json is not a repro: ENOENT/],
  [[`--repro=${fileURLToPath(import.meta.url)}`], /is not a repro: Unexpected token/],
]) {
  const run = spawnSync(process.execPath, [DRILL, ...args], { encoding: "utf8", timeout: 20000 });
  assert.equal(run.status, 2, `${args.join(" ")} is a usage error`);
  assert.match(run.stderr, why);
  assert.match(run.stderr, /usage: npm run drill <drill id …> \| all \[-- --build=<main \| PR number \| contract like 1\.19>\]\n       npm run drill -- --repro=<repro\.json> \[--build=…\]\n  drills: D01, D02, D03, D04, D05, D06, D07/);
}

process.env.BP_PLAYWRIGHT_FROM = "/no/such/package.json";
await assert.rejects(chromium(), /^Error: playwright not found from \/no\/such\/package\.json \(set BP_PLAYWRIGHT_FROM\)$/, "BP_PLAYWRIGHT_FROM picks where playwright comes from");

console.log("PASS  testing-ground drills: one file is a checklist and a script, and the runner's verdict reads its lights");
