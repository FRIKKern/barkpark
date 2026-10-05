#!/usr/bin/env node
// Packs @barkpark/paper-editor with `npm pack` and checks the tarball.
//
// It runs `prepack` (build, notices --check, stage) and then `npm pack`, so
// it also proves a clean checkout can produce the package. The checks:
//   1. the tarball holds the bundle, both stylesheets, the mermaid helper,
//      contract.js, the types, README.md, EMBED-CONTRACT.md, LICENSE and the
//      third-party notices;
//   2. every path named in package.json `exports`, `main` and `types` is in it;
//   3. no source, test, script or node_modules file leaks in;
//   4. the packed bundle and stylesheets are byte-identical to the files
//      Phoenix serves from api/priv/static/assets;
//   5. the version policy holds: package major equals the contract major, and
//      `barkpark.contractVersion` equals CONTRACT_VERSION.
// Exits 1 on any failure. Prints the file list and the tarball size.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CONTRACT_VERSION } from "../src/contract.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const assets = path.resolve(root, "../../priv/static/assets");
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const failures = [];
const fail = (msg) => failures.push(msg);

// Run prepack on its own first: npm prints lifecycle output on stdout, which
// would break the --json parse below. Then pack without scripts.
execFileSync("npm", ["run", "prepack"], { cwd: root, stdio: ["ignore", "inherit", "inherit"] });
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bp-paper-editor-pack-"));
const packed = JSON.parse(
  execFileSync("npm", ["pack", "--json", "--ignore-scripts", "--pack-destination", tmp], {
    cwd: root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }),
)[0];
const tarball = path.join(tmp, packed.filename);
const unpack = path.join(tmp, "unpacked");
fs.mkdirSync(unpack);
execFileSync("tar", ["-xzf", tarball, "-C", unpack]);
const pkgDir = path.join(unpack, "package");
const files = packed.files.map((f) => f.path).sort();

const REQUIRED = [
  "package.json",
  "README.md",
  "EMBED-CONTRACT.md",
  "LICENSE",
  "THIRD-PARTY-NOTICES.txt",
  "third-party-notices.json",
  "index.d.ts",
  "contract.d.ts",
  "dist/bp-paper-editor.bundle.js",
  "dist/bp-paper-editor.css",
  "dist/bp-paper-editor-shell.css",
  "dist/bp-paper-mermaid.js",
  "dist/contract.js",
];
for (const f of REQUIRED) if (!files.includes(f)) fail(`tarball is missing ${f}`);

const targets = new Set([pkg.main, pkg.types]);
const walk = (v) => (typeof v === "string" ? targets.add(v) : v && Object.values(v).forEach(walk));
walk(pkg.exports);
for (const t of targets) {
  const rel = t.replace(/^\.\//, "");
  if (!files.includes(rel)) fail(`package.json points at ${t}, which the tarball does not hold`);
}

for (const f of files) {
  if (/^(src|scripts|node_modules)\//.test(f) || /__.*\.mjs$/.test(f) || f.endsWith(".tgz")) {
    fail(`tarball leaks a file it should not ship: ${f}`);
  }
}

for (const name of ["bp-paper-editor.bundle.js", "bp-paper-editor.css", "bp-paper-editor-shell.css", "bp-paper-mermaid.js"]) {
  const a = fs.readFileSync(path.join(assets, name));
  const b = fs.existsSync(path.join(pkgDir, "dist", name)) ? fs.readFileSync(path.join(pkgDir, "dist", name)) : null;
  if (!b || !a.equals(b)) fail(`dist/${name} differs from api/priv/static/assets/${name}`);
}

const [pkgMajor] = pkg.version.split(".");
const [contractMajor] = CONTRACT_VERSION.split(".");
if (pkgMajor !== contractMajor) fail(`version ${pkg.version} has major ${pkgMajor}; CONTRACT_VERSION ${CONTRACT_VERSION} has major ${contractMajor}`);
if (pkg.barkpark?.contractVersion !== CONTRACT_VERSION) {
  fail(`package.json barkpark.contractVersion is ${pkg.barkpark?.contractVersion}; src/contract.js says ${CONTRACT_VERSION}`);
}
const shipped = await import(pathToFileURL(path.join(pkgDir, "dist/contract.js")).href);
if (shipped.CONTRACT_VERSION !== CONTRACT_VERSION) fail("dist/contract.js does not export the source CONTRACT_VERSION");

console.log(`${packed.name}@${packed.version}  ${packed.filename}`);
for (const f of packed.files) console.log(`  ${String(f.size).padStart(8)}  ${f.path}`);
console.log(`files: ${packed.entryCount}  packed: ${packed.size} bytes  unpacked: ${packed.unpackedSize} bytes`);
fs.rmSync(tmp, { recursive: true, force: true });

if (failures.length) {
  for (const f of failures) console.error(`FAIL  ${f}`);
  process.exit(1);
}
console.log("OK pack-check");
