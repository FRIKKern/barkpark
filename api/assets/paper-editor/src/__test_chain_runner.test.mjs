// __test_chain_runner.test.mjs — what scripts/test-chain.mjs does with its chain: it
// runs every file, in chain order, and stops at the first that fails, with that file's
// exit code and its name. The census pins chain(); this pins the loop around it, and
// that the census itself goes red on a package.json that dodges the runner.
//
// Each scene copies the runner into a fresh package under the temp folder whose path has
// a space, a % and a non-ASCII letter, with logging stub tests at every depth, and runs it
// from another folder (the runner must set the cwd itself). src/Upper sorts before
// src/__a but is listed after it, so the order is the runner's sort, not the folder's.
// The temp folder is removed after every scene, red or green.
// Run: node src/__test_chain_runner.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { FIRST } from "../scripts/test-chain.mjs";

const RUNNER = fileURLToPath(new URL("../scripts/test-chain.mjs", import.meta.url));
const CENSUS = fileURLToPath(new URL("./__test_chain_census.mjs", import.meta.url));
const REST = ["src/Upper/__k.test.mjs", "src/__a.test.mjs", "src/__m.test.mjs", "src/canvas/__b.test.mjs", "src/canvas/__z.test.mjs", "src/deep/x/__q.test.mjs"];
const ORDER = [...FIRST, ...REST];

let failures = 0;
function scene(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures += 1;
    console.log(`FAIL  ${name}\n      ${e.message.split("\n").slice(0, 6).join(" | ")}`);
  }
}

function inPackage(plant, play) {
  const root = mkdtempSync(join(tmpdir(), "bp test chain %ø-"));
  try {
    const pkg = join(root, "pkg");
    const log = join(root, "ran.log");
    mkdirSync(join(pkg, "scripts"), { recursive: true });
    writeFileSync(join(pkg, "scripts/test-chain.mjs"), readFileSync(RUNNER));
    for (const file of [...ORDER, "src/__helper.mjs", "src/canvas/notes.test.mjs"]) {
      mkdirSync(join(pkg, dirname(file)), { recursive: true });
      writeFileSync(join(pkg, file), `import { appendFileSync } from "node:fs";\nappendFileSync(${JSON.stringify(log)}, ${JSON.stringify(`${file}\n`)});\n${plant[file] ?? ""}\n`);
    }
    return play({ root, pkg, ran: () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean) : []) });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const run = (script, cwd) => spawnSync(process.execPath, [script], { cwd, encoding: "utf8" });

scene("all pass: every test file runs once, FIRST then the rest by path, from the package root; exit 0 and a count", () => {
  inPackage({ "src/canvas/__b.test.mjs": `if (!process.cwd().endsWith("pkg")) process.exit(7);` }, ({ root, pkg, ran }) => {
    const r = run(join(pkg, "scripts/test-chain.mjs"), root);
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(ran(), ORDER, "ran exactly the chain, in order (no helper, no file not named __*.test.mjs)");
    assert.equal(r.stdout.trim().split("\n").at(-1), `npm test: ${ORDER.length} files passed`);
  });
});

for (const [file, plant, code, what] of [
  ["src/__path_filter.test.mjs", "process.exit(3)", 3, "exits 3"],
  ["src/__m.test.mjs", "process.exit(4)", 4, "exits 4"],
  ["src/canvas/__b.test.mjs", "throw new Error('boom')", 1, "throws"],
  ["src/deep/x/__q.test.mjs", "process.exit(5)", 5, "exits 5"],
]) {
  scene(`a test that ${what} (${file}) stops the chain there, with its code and its name`, () => {
    inPackage({ [file]: plant }, ({ root, pkg, ran }) => {
      const r = run(join(pkg, "scripts/test-chain.mjs"), root);
      assert.equal(r.status, code);
      assert.deepEqual(ran(), ORDER.slice(0, ORDER.indexOf(file) + 1), "nothing after it ran");
      assert.equal(r.stderr.trim().split("\n").at(-1), `npm test: ${file} exited ${code}`);
    });
  });
}

for (const signal of ["SIGKILL", "SIGTERM"]) {
  scene(`a test killed by ${signal} fails the chain, exit 1`, () => {
    inPackage({ "src/canvas/__b.test.mjs": `process.kill(process.pid, "${signal}")` }, ({ root, pkg, ran }) => {
      const r = run(join(pkg, "scripts/test-chain.mjs"), root);
      assert.equal(r.status, 1);
      assert.deepEqual(ran(), ORDER.slice(0, ORDER.indexOf("src/canvas/__b.test.mjs") + 1));
      assert.equal(r.stderr.trim().split("\n").at(-1), `npm test: src/canvas/__b.test.mjs was killed by ${signal}`);
    });
  });
}

scene("run through an absolute symlink to the runner: the whole chain still runs", () => {
  inPackage({}, ({ root, pkg, ran }) => {
    const link = join(root, "link to runner.mjs");
    symlinkSync(join(pkg, "scripts/test-chain.mjs"), link);
    const r = run(link, root);
    assert.equal(r.status, 0, r.stderr);
    assert.deepEqual(ran(), ORDER);
  });
});

scene("--list prints the chain and runs nothing", () => {
  inPackage({}, ({ root, pkg, ran }) => {
    const r = run(join(pkg, "scripts/test-chain.mjs"), root);
    assert.equal(r.status, 0);
    const listed = spawnSync(process.execPath, [join(pkg, "scripts/test-chain.mjs"), "--list"], { cwd: root, encoding: "utf8" });
    assert.equal(listed.status, 0);
    assert.deepEqual(listed.stdout.trim().split("\n"), ORDER);
    assert.deepEqual(ran(), ORDER, "only the first run ran anything");
  });
});

for (const args of [["--list=1"], ["--lst"], ["--list", "--list"], ["src/__a.test.mjs"], [""], ["--list", ""]]) {
  scene(`arguments ${JSON.stringify(args)}: usage error, exit 2, nothing runs`, () => {
    inPackage({}, ({ root, pkg, ran }) => {
      const r = spawnSync(process.execPath, [join(pkg, "scripts/test-chain.mjs"), ...args], { cwd: root, encoding: "utf8" });
      assert.equal(r.status, 2, r.stderr);
      assert.match(r.stderr, /usage: node scripts\/test-chain\.mjs \[--list\]/);
      assert.deepEqual(ran(), []);
    });
  });
}

const TEST = { test: "node scripts/test-chain.mjs" };
for (const [what, scripts, gone, says] of [
  ["a clean package", TEST, null, null],
  ["a pretest hook", { pretest: "node src/__x.mjs", ...TEST }, null, "package.json has a pretest script"],
  ["a posttest hook", { ...TEST, posttest: "node src/__x.mjs" }, null, "package.json has a posttest script"],
  ["a test script that is not the runner", { test: "node src/__smoke.mjs" }, null, `package.json's test script is "node src/__smoke.mjs"`],
  ["a FIRST file gone from disk", TEST, "src/__rig.test.mjs", "src/__rig.test.mjs is in the chain but does not exist on disk"],
]) {
  scene(`the census on ${what}: ${says ? "red, and it says why" : "0 drift"}`, () => {
    inPackage({}, ({ root, pkg }) => {
      writeFileSync(join(pkg, "package.json"), JSON.stringify({ scripts }));
      writeFileSync(join(pkg, "src/__test_chain_census.mjs"), readFileSync(CENSUS));
      if (gone) rmSync(join(pkg, gone));
      const r = run(join(pkg, "src/__test_chain_census.mjs"), root);
      if (!says) {
        assert.equal(r.status, 0, r.stderr);
        assert.equal(r.stdout.trim(), `test-chain census: ${REST.length + 3} test files on disk, ${ORDER.length} files in the chain — reconciled, 0 drift`);
      } else {
        assert.equal(r.status, 1);
        assert.ok(r.stderr.includes(`  - ${says}`), r.stderr);
        assert.equal(r.stderr.trim().split("\n").at(-1), "test-chain census: FAIL (1 problem)");
      }
    });
  });
}

if (failures > 0) { console.log(`\n${failures} failing check(s)`); process.exit(1); }
console.log("\ntest-chain runner: all checks passed");
process.exit(0);
