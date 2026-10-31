// __rig.test.mjs — the rig exit rule (__rig.mjs) holds, and every rig uses it.
//
// 1. skip() exits 0 locally and 1 under BP_REQUIRE_CHROME=1; exitRig() exits 1
//    on zero PASS and on any failure; tally() counts every PASS and every FAIL.
// 2. A predicate, not a list: every file under src/ that looks for a browser
//    (names BP_CHROME) imports __rig.mjs, exits through exitRig(), never prints
//    SKIP by hand, never calls process.exit(0) or sets process.exitCode, and
//    keeps no PASS counter of its own. A new rig that skips green, ends on its
//    own exit code, or counts its own passes, reds.
//
// Run: node src/__rig.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { tally } from "./__rig.mjs";

const SRC = fileURLToPath(new URL(".", import.meta.url));
const RIG = new URL("./__rig.mjs", import.meta.url).href;

function run(body, env = {}) {
  const r = spawnSync(process.execPath, ["--input-type=module", "-e", `import { skip, exitRig } from ${JSON.stringify(RIG)};\n${body}`], {
    env: { ...process.env, BP_REQUIRE_CHROME: "", ...env },
    encoding: "utf8",
  });
  return { code: r.status, out: r.stdout };
}

const cases = [
  ["skip exits 0 locally", 'process.exit(skip("x — no Chromium found."))', {}, 0],
  ["skip exits 1 under BP_REQUIRE_CHROME=1", 'process.exit(skip("x — no Chromium found."))', { BP_REQUIRE_CHROME: "1" }, 1],
  ["exitRig with zero PASS exits 1", "exitRig(0, 0)", {}, 1],
  ["exitRig with passes and no failure exits 0", "exitRig(3, 0)", {}, 0],
  ["exitRig with a failure exits 1", "exitRig(3, 1)", {}, 1],
];
for (const [name, body, env, want] of cases) {
  const { code, out } = run(body, env);
  assert.equal(code, want, `${name}: exited ${code}\n${out}`);
}
assert.match(run('skip("x")').out, /^SKIP  x$/m);
assert.match(run('skip("x")', { BP_REQUIRE_CHROME: "1" }).out, /^FAIL  BP_REQUIRE_CHROME=1/m);
assert.match(run("exitRig(0, 0)").out, /^FAIL  0 PASS/m);

const printed = [];
const log = console.log;
console.log = (line) => printed.push(line);
let t, quiet, returned;
try {
  t = tally();
  t.check("a", () => {});
  t.check("b", () => { throw new Error("boom"); });
  t.record("c", true);
  t.record("d", false, "why");
  await t.checkAsync("e", async () => {});
  await t.checkAsync("f", async () => { throw new Error("late"); });
  quiet = tally({ verbose: false });
  quiet.check("g", () => {});
  quiet.check("h", () => { throw new Error("loud"); });
  returned = [quiet.record("x", false), quiet.record("y", true)];
} finally {
  console.log = log;
}
assert.deepEqual([t.passes, t.failures], [3, 3], "tally counts every PASS and every FAIL");
assert.deepEqual([quiet.passes, quiet.failures], [2, 2], "a quiet tally still counts its passes");
assert.deepEqual(printed, ["PASS  a", "FAIL  b\n      boom", "PASS  c", "FAIL  d\n      why", "PASS  e", "FAIL  f\n      late", "FAIL  h\n      loud", "FAIL  x"]);
assert.deepEqual(returned, [false, true], "record returns its verdict");

function walk(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(dir, e.name)) : /\.m?js$/.test(e.name) ? [join(dir, e.name)] : [],
  );
}

const rigs = walk(SRC)
  .filter((f) => !/__rig(\.test)?\.mjs$/.test(f))
  .map((f) => ({ f: relative(SRC, f), src: readFileSync(f, "utf8") }))
  .filter(({ src }) => src.includes("BP_CHROME"));
assert.ok(rigs.length >= 6, `found ${rigs.length} rigs that look for a browser; the scan is broken`);

const broken = rigs.flatMap(({ f, src }) => [
  ...(/from "\.{1,2}\/(?:\.\.\/)*__rig\.mjs"/.test(src) ? [] : [`${f}: does not import __rig.mjs`]),
  ...(/\bexitRig\(/.test(src) ? [] : [`${f}: does not exit through exitRig()`]),
  ...(/process\.exit\((?!skip\()/.test(src) ? [`${f}: calls process.exit outside skip()`] : []),
  ...(/process\.exitCode/.test(src) ? [`${f}: sets process.exitCode`] : []),
  ...(/\blet passes\b|\bpasses\s*(\+\+|\+=)/.test(src) ? [`${f}: counts its own passes instead of tally()`] : []),
  ...(/console\.log\([`"']SKIP/.test(src) ? [`${f}: prints SKIP by hand instead of skip()`] : []),
]);
assert.deepEqual(broken, [], "every rig exits through __rig.mjs");

console.log(`ok rig exit rule: ${cases.length} exit cases, ${rigs.length} rigs use it`);
