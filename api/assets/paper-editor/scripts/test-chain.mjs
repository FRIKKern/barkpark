// npm test: every src/**/__*.test.mjs on disk, one after another, stopping at the first
// that fails (task-2f7cb25af65df103).
//
// The chain used to be one `node src/…` string in package.json, so every editor PR that
// added a test edited the same line, and each merge left the other open editor PRs
// conflicting. Now a test runs because its file exists; adding one touches nothing else.
//
// FIRST runs before the rest, in this order: the gates on the suite itself (the census
// of this list, the workflow path filter, the rig rule), then __smoke.mjs, the one file
// in the suite not named like a test. The rest run sorted by path. Each file runs in its
// own node process from the package root, as `node src/…` did.
//
// Run: node scripts/test-chain.mjs   (or: npm test)   --list prints the chain instead.

import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";

const PKG = join(dirname(fileURLToPath(import.meta.url)), "..");

export const FIRST = [
  "src/__test_chain_census.mjs",
  "src/__path_filter.test.mjs",
  "src/__path_filter_scan.test.mjs",
  "src/__rig.test.mjs",
  "src/__smoke.mjs",
];

export const isTest = (path) => /(^|\/)__[^/]*\.test\.mjs$/.test(path);

export function chain(pkg = PKG) {
  const found = readdirSync(join(pkg, "src"), { recursive: true })
    .map((rel) => `src/${rel.split(sep).join("/")}`)
    .filter((path) => isTest(path) && !FIRST.includes(path))
    .sort();
  return [...FIRST, ...found];
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (process.argv.includes("--list")) {
    console.log(chain().join("\n"));
    process.exit(0);
  }
  for (const file of chain()) {
    const { status, signal } = spawnSync(process.execPath, [file], { cwd: PKG, stdio: "inherit" });
    if (status !== 0) {
      console.error(`npm test: ${file} ${signal ? `was killed by ${signal}` : `exited ${status}`}`);
      process.exit(status || 1);
    }
  }
}
