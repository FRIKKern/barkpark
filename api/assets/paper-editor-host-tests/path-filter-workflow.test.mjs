import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chain } from "../paper-editor/scripts/test-chain.mjs";
import { filterArms, scanner, verdict } from "../paper-editor/scripts/path-filter.mjs";

const SELF = fileURLToPath(import.meta.url);
const REPO = resolve(dirname(SELF), "../../..");
const PKG = join(REPO, "api/assets/paper-editor");
const WORKFLOW = join(REPO, ".github/workflows/paper-editor.yml");
const NOT_READ = new Map([
  ["api/lib/barkpark/portable_doc/bpml/parser.ex", "src/__narrow_render.mjs"],
  ["internal/", "src/canvas/__filetree_inline_mounted.test.mjs"],
]);

const yml = readFileSync(WORKFLOW, "utf8");
const scripts = JSON.parse(readFileSync(join(PKG, "package.json"), "utf8")).scripts;
const arms = filterArms(yml);
assert.deepEqual(Object.keys(arms).sort(), ["pull_request", "push"], "the workflow has a push and a pull_request path filter");

const runs = new Map([[join(PKG, "scripts/test-chain.mjs"), chain(PKG).map((file) => join(PKG, file))]]);
const { entries, sinks, visited } = scanner({ repo: REPO, pkg: PKG, notRead: NOT_READ, self: SELF, runs }).reads(yml, scripts);
assert.ok(entries >= 200, `found ${entries} entry points; the workflow parse is broken`);
assert.ok(sinks.size >= 20, `found ${sinks.size} outside reads; the scan is broken`);

const ownedPrefixes = ["api/assets/paper-editor/", "api/assets/paper-editor-host-tests/"];
const { unequal, missing, unused } = verdict(arms, sinks, ownedPrefixes);
assert.equal(unequal, false, "push and pull_request list the same paths");
assert.deepEqual(missing, [], "files a paper-editor step reads that its path filter does not list: add each to BOTH arms of .github/workflows/paper-editor.yml");
assert.deepEqual(unused, [], "path filter entries no paper-editor step reads: remove them, or the derivation missed a read");

console.log(`ok path filter: ${sinks.size} outside reads from ${visited.size} files, all in both arms`);
