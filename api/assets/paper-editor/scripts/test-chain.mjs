// npm test: FIRST in order, then every other src/**/__*.test.mjs sorted, each in its own
// node process from the package root, stopping at the first failure. A test runs because
// its file exists (task-2f7cb25af65df103). Pinned by src/__test_chain_runner.test.mjs.

import { spawnSync } from "node:child_process";
import { readdirSync, realpathSync } from "node:fs";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";

const SELF = fileURLToPath(import.meta.url);
const PKG = join(dirname(SELF), "..");

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

if (process.argv[1] && realpathSync(process.argv[1]) === SELF) {
  const args = process.argv.slice(2);
  const list = args.length === 1 && args[0] === "--list";
  if (args.length > 0 && !list) {
    console.error(`npm test: unknown arguments ${JSON.stringify(args)}; usage: node scripts/test-chain.mjs [--list]`);
    process.exit(2);
  }
  if (list) {
    console.log(chain().join("\n"));
    process.exit(0);
  }
  const files = chain();
  for (const file of files) {
    const { status, signal, error } = spawnSync(process.execPath, [file], { cwd: PKG, stdio: "inherit" });
    if (status !== 0) {
      const why = error ? `could not start: ${error.message}` : signal ? `was killed by ${signal}` : `exited ${status}`;
      console.error(`npm test: ${file} ${why}`);
      process.exit(status === null ? 1 : status);
    }
  }
  console.log(`npm test: ${files.length} files passed`);
}
