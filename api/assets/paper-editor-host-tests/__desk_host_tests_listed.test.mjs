// __desk_host_tests_listed.test.mjs — every desk host test is one CI runs
// (task-4ae0e039652cecef).
//
// The paper-editor workflow names its host tests one by one. Two desk tests
// (__desk_search_light, __desk_focus_mode) landed without a line there, so CI
// never ran them and a break in what they guard would have merged green. This
// test lists the __desk*.test.mjs files beside it and reds on any the
// workflow's host-test step does not run. It is itself a __desk test, so it
// is caught too if its own line goes.
//
// Run: node ../paper-editor-host-tests/__desk_host_tests_listed.test.mjs
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const WORKFLOW = join(resolve(HERE, "../../.."), ".github/workflows/paper-editor.yml");

// The names a `run:` line hands to node, one command per line, as the step
// writes them (`node ../paper-editor-host-tests/<file>`). A commented-out
// line runs nothing, so it does not count.
export function ran(yml) {
  const out = new Set();
  for (const m of yml.matchAll(/^[ \t]+node \.\.\/paper-editor-host-tests\/([^\s#]+)[ \t]*$/gm)) out.add(m[1]);
  return out;
}

export function unlisted(files, runs) {
  return files.filter((f) => /^__desk.*\.test\.mjs$/.test(f) && !runs.has(f)).sort();
}

const runs = ran(readFileSync(WORKFLOW, "utf8"));
const onDisk = readdirSync(HERE);
assert.ok(onDisk.some((f) => f.startsWith("__desk")), "no desk host test found: the folder read is wrong");
assert.ok(runs.size >= 50, `the workflow names only ${runs.size} host tests: the parse is broken`);

assert.deepEqual(
  unlisted(onDisk, runs),
  [],
  "desk host tests the paper-editor workflow never runs: add `node ../paper-editor-host-tests/<file>` to its host-test step"
);

// The guard's own cases: a new unlisted file reds, a commented-out line does
// not count as run, and a listed one passes.
assert.deepEqual(unlisted([...onDisk, "__desk_new.test.mjs"], runs), ["__desk_new.test.mjs"]);
assert.deepEqual([...ran("          # node ../paper-editor-host-tests/__desk_x.test.mjs\n")], []);
assert.deepEqual([...ran("          node ../paper-editor-host-tests/__desk_x.test.mjs\n")], ["__desk_x.test.mjs"]);
assert.deepEqual(unlisted(["__desk_x.test.mjs", "__other.test.mjs"], new Set(["__desk_x.test.mjs"])), []);

console.log(`desk host tests listed: ok (${onDisk.filter((f) => /^__desk.*\.test\.mjs$/.test(f)).length} on disk, all run)`);
