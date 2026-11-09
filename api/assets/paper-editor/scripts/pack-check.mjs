#!/usr/bin/env node
// Packs @portable-doc/editor with `npm pack` and checks the tarball.
//
// It runs `prepack` (build, notices --check) and then `npm pack`, so it also proves
// a clean checkout can produce the package. The checks:
//   1. the tarball holds the seven built files, the types, the profile, README.md,
//      EMBED-CONTRACT.md, LICENSE and the third-party notices, and dist/ holds
//      nothing else;
//   2. every path named in package.json `exports`, `main` and `types` is in it;
//   3. no source, test, script or node_modules file leaks in;
//   4. the packed dist/, LICENSE and profile are byte-identical to this package's;
//   5. the packed profile matches what the packed bundle and this package declare;
//   6. the version policy holds: pre-1.0 alpha packages may ship the existing contract, otherwise majors match, and
//      `barkpark.contractVersion` equals CONTRACT_VERSION;
//   7. a version recorded in scripts/releases.json is packed with that release's bytes,
//      file for file, or not at all: a version names one set of bytes.
// It reads nothing outside this package; sync-barkpark.mjs owns the Barkpark sinks.
// Exits 1 on any failure. Prints the file list and the tarball size.
//
// `node scripts/pack-check.mjs --prepack [dir]` is prepack's last step: it holds the
// tracked profile to the dist/ just built, and the files to any release recorded at
// this version, so a bare `npm pack` or `npm publish` cannot ship a stale profile or a
// second, different copy of a released version. It refuses; it never rewrites a file.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath, pathToFileURL } from "node:url";
import { CONTRACT_VERSION } from "../src/contract.js";
import { LOCAL_OUTPUTS } from "./build-local.mjs";
import { validatePackageProfile } from "./surface-package.mjs";
import { packageSurface } from "./surface.mjs";

const SELF = fileURLToPath(import.meta.url);
const packageRoot = path.resolve(path.dirname(SELF), "..");
const PROFILE = "host-profile/surface.json";
const RELEASES = path.join(packageRoot, "scripts/releases.json");

export const REQUIRED = [
  "package.json",
  "README.md",
  "EMBED-CONTRACT.md",
  "LICENSE",
  PROFILE,
  "THIRD-PARTY-NOTICES.txt",
  "third-party-notices.json",
  "index.d.ts",
  "contract.d.ts",
  ...LOCAL_OUTPUTS.map((name) => `dist/${name}`),
];

// Why the profile in `dir` does not match the dist/ beside it, or null when it does.
export async function profileMismatch(dir) {
  try {
    validatePackageProfile(await packageSurface({ dir: path.join(dir, "dist") }), JSON.parse(fs.readFileSync(path.join(dir, PROFILE), "utf8")));
    return null;
  } catch (error) {
    return error.message;
  }
}

export const readReleases = (file = RELEASES) => JSON.parse(fs.readFileSync(file, "utf8")).releases;

// When `version` is a recorded release, the files in `dir` that differ from it: changed,
// missing or extra, over the release's files and `files`. Null for an unreleased version
// or an exact match.
export function releaseMismatch({ dir, version, files, releases = readReleases() }) {
  const release = releases.find((entry) => entry.version === version);
  if (!release) return null;
  const sha = (name) => createHash("sha256").update(fs.readFileSync(path.join(dir, name))).digest("hex");
  const names = [...new Set([...Object.keys(release.files), ...files])].sort();
  const differ = names.filter((name) => !(name in release.files) || !fs.existsSync(path.join(dir, name)) || sha(name) !== release.files[name]);
  return differ.length ? { release, differ } : null;
}
const releaseFailure = ({ release, differ }) =>
  `version ${release.version} is already released (${release.source}, tarball sha256 ${release.tarball.sha256}) and these files differ from it: ${differ.join(", ")}. A version is packed once; bump package.json's version`;

const sameBytes = (a, b) => fs.existsSync(a) && fs.existsSync(b) && fs.readFileSync(a).equals(fs.readFileSync(b));

// The tarball checks, over an unpacked package directory and its file list. Returns
// every failure at once. `root` is the package the tarball must equal.
export async function inspectPack({ files, pkgDir, root = packageRoot, contractVersion = CONTRACT_VERSION, releases = readReleases() }) {
  const failures = [];
  const fail = (msg) => failures.push(msg);
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));

  for (const f of REQUIRED) if (!files.includes(f)) fail(`tarball is missing ${f}`);
  for (const f of files) {
    if (f.startsWith("dist/") && !LOCAL_OUTPUTS.includes(f.slice("dist/".length))) fail(`tarball carries ${f}, which the build does not output`);
  }

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

  for (const name of LOCAL_OUTPUTS) {
    if (!sameBytes(path.join(root, "dist", name), path.join(pkgDir, "dist", name))) fail(`dist/${name} differs from this package's dist/${name}`);
  }
  for (const name of ["LICENSE", PROFILE]) {
    if (!sameBytes(path.join(root, name), path.join(pkgDir, name))) fail(`${name} differs from this package's tracked ${name}`);
  }

  if (LOCAL_OUTPUTS.every((name) => files.includes(`dist/${name}`)) && files.includes(PROFILE)) {
    const why = await profileMismatch(pkgDir);
    if (why) fail(`${PROFILE} does not match the packed build (run npm run sync:barkpark:write): ${why}`);
  }

  const [pkgMajor] = pkg.version.split(".");
  const [contractMajor] = contractVersion.split(".");
  const isInitialAlpha = /^0\.\d+\.\d+-alpha\.\d+$/.test(pkg.version);
  if (!isInitialAlpha && pkgMajor !== contractMajor) fail(`version ${pkg.version} has major ${pkgMajor}; CONTRACT_VERSION ${contractVersion} has major ${contractMajor}`);
  if (pkg.barkpark?.contractVersion !== contractVersion) {
    fail(`package.json barkpark.contractVersion is ${pkg.barkpark?.contractVersion}; src/contract.js says ${contractVersion}`);
  }
  const released = releaseMismatch({ dir: pkgDir, version: pkg.version, files, releases });
  if (released) fail(releaseFailure(released));
  const contract = path.join(pkgDir, "dist/contract.js");
  if (fs.existsSync(contract)) {
    const shipped = await import(pathToFileURL(contract).href);
    if (shipped.CONTRACT_VERSION !== contractVersion) fail("dist/contract.js does not export the source CONTRACT_VERSION");
  }
  return failures;
}

const isMain = process.argv[1] && fs.realpathSync(process.argv[1]) === SELF;
if (isMain && process.argv[2] === "--prepack") {
  const dir = path.resolve(process.argv[3] ?? packageRoot);
  const why = await profileMismatch(dir);
  const { version } = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const released = releaseMismatch({ dir, version, files: REQUIRED });
  if (why) console.error(`prepack: REFUSED, nothing packed. ${PROFILE} does not match the build in ${path.join(dir, "dist")}: ${why}. Run npm run sync:barkpark:write, then pack again.`);
  if (released) console.error(`prepack: REFUSED, nothing packed. ${releaseFailure(released)}.`);
  if (why || released) process.exit(1);
  console.log(`prepack: ${PROFILE} matches dist/, and no release recorded at ${version} has other bytes`);
} else if (isMain) {
  const outputDir = process.argv[2];
  // Run prepack on its own first: npm prints lifecycle output on stdout, which
  // would break the --json parse below. Then pack without scripts.
  execFileSync("npm", ["run", "prepack"], { cwd: packageRoot, stdio: ["ignore", "inherit", "inherit"] });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bp-paper-editor-pack-"));
  const packed = JSON.parse(
    execFileSync("npm", ["pack", "--json", "--ignore-scripts", "--pack-destination", tmp], {
      cwd: packageRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    }),
  )[0];
  const tarball = path.join(tmp, packed.filename);
  const unpack = path.join(tmp, "unpacked");
  fs.mkdirSync(unpack);
  execFileSync("tar", ["-xzf", tarball, "-C", unpack]);
  const failures = await inspectPack({ files: packed.files.map((f) => f.path).sort(), pkgDir: path.join(unpack, "package") });

  console.log(`${packed.name}@${packed.version}  ${packed.filename}`);
  for (const f of packed.files) console.log(`  ${String(f.size).padStart(8)}  ${f.path}`);
  console.log(`files: ${packed.entryCount}  packed: ${packed.size} bytes  unpacked: ${packed.unpackedSize} bytes`);
  if (failures.length) {
    fs.rmSync(tmp, { recursive: true, force: true });
    for (const f of failures) console.error(`FAIL  ${f}`);
    process.exit(1);
  }
  if (outputDir) {
    fs.mkdirSync(outputDir, { recursive: true });
    fs.copyFileSync(tarball, path.join(outputDir, packed.filename));
  }
  fs.rmSync(tmp, { recursive: true, force: true });
  console.log("OK pack-check");
}
