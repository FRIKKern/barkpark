// __inward_read.test.mjs — the package reads nothing of its host, by any path.
//
// A read the text guard in __build_ownership cannot see, because the path is built at
// run time, shows up here. The build and the notices check run under
// __inward_read_tracer.mjs, and a probe keeps the tracer itself honest.
//
// The contract truth scan is held here too, from outside the support file that narrows
// it: one leaf left out of that scan, with a read planted in it, must go red.
//
// Everything runs in a temporary directory. Nothing here needs the host to exist.
//
// Run: node src/__inward_read.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scratch = mkdtempSync(path.join(tmpdir(), "bp-inward-read-"));
process.once("exit", () => rmSync(scratch, { recursive: true, force: true }));

let failures = 0;
const check = async (name, fn) => {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (error) {
    failures++;
    console.log(`FAIL  ${name}\n      ${String(error.message).split("\n").join("\n      ")}`);
  }
};

const inScratch = (name, text) => {
  const at = path.join(scratch, name);
  if (text !== undefined) writeFileSync(at, text);
  return at;
};

// NODE_OPTIONS, so a node this one spawns is traced too.
function traced(label, args) {
  const log = inScratch(`${label}.log`, "");
  const tracer = fileURLToPath(new URL("./__inward_read_tracer.mjs", import.meta.url));
  const { status, stdout, stderr } = spawnSync(process.execPath, args, {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ""} --import="${pathToFileURL(tracer)}"`.trim(),
      INWARD_READ_LOG: log,
      INWARD_READ_ROOT: root,
      INWARD_READ_ALLOW: scratch,
    },
  });
  const hits = readFileSync(log, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
  return { status, output: `${stdout}\n${stderr}`, hits };
}
const shown = (hits) => [...new Set(hits.map(({ op, target }) => `${op}: ${target}`))];

await check("the tracer sees every way a path can leave the package", () => {
  const probe = inScratch("probe.mjs", `
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
const at = path.join(process.env.INWARD_READ_ROOT, "..", "..", "lib", "probe.txt");
const quiet = async (fn) => { try { await fn(); } catch {} };
await quiet(() => fs.readFileSync(at));
await quiet(() => fs.statSync(at));
await quiet(() => fs.readdirSync(path.dirname(at)));
fs.existsSync(at);
fs.createReadStream(at).on("error", () => {});
await quiet(() => readFile(at));
await quiet(() => import(pathToFileURL(at).href));
await quiet(() => createRequire(import.meta.url)(at));
spawnSync("cat", [at], { stdio: "ignore" });
fs.readFileSync(path.join(process.env.INWARD_READ_ROOT, "package.json"));
`);
  const { status, output, hits } = traced("probe", [probe]);
  assert.equal(status, 0, output);
  const ops = new Set(hits.map(({ op }) => op));
  for (const op of ["readFileSync", "statSync", "readdirSync", "existsSync", "createReadStream", "promises.readFile", "import", "require", "spawn"])
    assert.ok(ops.has(op), `the tracer missed ${op}; it saw ${[...ops].join(", ")}`);
  assert.ok(!hits.some(({ target }) => target.endsWith(`${path.sep}package.json`)), "a read inside the package is not a hit");
});

let inputs = {};
await check("a real build reaches nothing outside the package, by any path", () => {
  const out = inScratch("build-inputs.json");
  const driver = inScratch("build.mjs", `
import { writeFileSync } from "node:fs";
const { buildLocal } = await import(process.argv[2]);
const { metafiles } = await buildLocal({ outDir: process.argv[3], logLevel: "warning" });
writeFileSync(process.argv[4], JSON.stringify(Object.fromEntries(Object.entries(metafiles).map(([name, meta]) => [name, Object.keys(meta.inputs)]))));
`);
  const script = pathToFileURL(path.join(root, "scripts/build-local.mjs")).href;
  const { status, output, hits } = traced("build", [driver, script, path.join(scratch, "dist"), out]);
  assert.equal(status, 0, output);
  inputs = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(Object.keys(inputs).length, 4, "four esbuild outputs report their inputs");
  assert.deepEqual(shown(hits), []);
});

await check("the notices check reaches nothing outside the package, by any path", () => {
  const { status, output, hits } = traced("notices", ["scripts/third-party-notices.mjs", "--check"]);
  assert.equal(status, 0, output);
  assert.deepEqual(shown(hits), []);
});

// Lists of its own, so a narrower scan in __contract_truth_support.mjs cannot narrow these.
const walk = (dir) => readdirSync(dir).flatMap((name) => {
  const at = path.join(dir, name);
  return statSync(at).isDirectory() ? walk(at) : [at];
});
const own = (rel) => path.relative(root, rel).split(path.sep).join("/");
const onDisk = walk(path.join(root, "src")).map(own).filter((rel) => !path.basename(rel).startsWith("__"));
const OWN_OUTPUT = "src/bp-paper-mermaid.js"; // copied unchanged; the editor never imports it
// The root is only @imports. The shared tokens are held to their digest by __css_source_graph.
const NOT_AUTHORED = new Set(["src/styles.css", "src/code-tokens.css"]);
const built = () => [...new Set(Object.values(inputs).flat())].filter((rel) => rel.startsWith("src/"));

const support = await import("./__contract_truth_support.mjs");
const missed = (files, scanned, shape = (text) => text) => files.filter((rel) => {
  const text = shape(readFileSync(path.join(root, rel), "utf8")).trim();
  return text && !scanned.includes(text);
});

await check("the contract truth scan holds every package script, by a walk of its own", () => {
  const scripts = onDisk.filter((rel) => rel.endsWith(".js") && rel !== OWN_OUTPUT);
  assert.ok(scripts.includes("src/index.js") && scripts.length > 100, `found ${scripts.length} scripts`);
  assert.deepEqual(missed(scripts, support.rawJs), []);
});

await check("the contract truth scan holds every source the build takes in, whatever its name", () => {
  const taken = built();
  assert.ok(taken.includes("src/index.js") && taken.includes("src/styles.css"), `the build reported ${taken.length} sources`);
  assert.deepEqual(missed(taken.filter((rel) => /\.m?js$/.test(rel) && rel !== OWN_OUTPUT), support.rawJs), []);
  const styles = (inputs["bp-paper-editor.css"] ?? []).filter((rel) => rel.startsWith("src/") && rel.endsWith(".css") && !NOT_AUTHORED.has(rel));
  assert.deepEqual(missed(styles, support.packageCss, support.stripComments), []);
});

if (failures) {
  console.log(`\n${failures} inward read check(s) FAILED`);
  process.exit(1);
}
console.log("\nall inward read checks PASS");
process.exit(0);
