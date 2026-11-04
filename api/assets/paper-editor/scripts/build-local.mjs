#!/usr/bin/env node
// Builds the package from its own sources into dist/ and nowhere else. Seven files:
//   bp-paper-editor.bundle.js  esbuild, src/index.js, BUILD_SHA defined
//   bp-paper-editor.css        esbuild, src/styles.css
//   bp-paper-code.js           esbuild, src/reader-code.js
//   bp-paper-surface.css       esbuild, the assembled src/paper-surface fragments
//   bp-paper-editor-shell.css  the assembled src/editor-shell fragments, unchanged
//   bp-paper-mermaid.js        src/bp-paper-mermaid.js, unchanged
//   contract.js                src/contract.js, unchanged
//
// It reads nothing outside this package and writes no Barkpark file. The explicit
// way out to the host is scripts/sync-barkpark.mjs. host-profile/surface.json is
// tracked metadata that sync composes with the live reader; it is not an output.
//
// A full build then reads the package surface evidence off the fresh bundle, which
// fails on a bundle that lost an element or carries the wrong versions. It compares
// nothing against the tracked profile: a source edit changes BUILD_SHA before sync
// has run, and pack-check and sync --check hold the tracked file to the build.
//
//   node scripts/build-local.mjs         minified
//   node scripts/build-local.mjs --dev   sourcemaps, no evidence read
import { build } from "esbuild";
import { mkdirSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildBundle } from "./build-bundle.mjs";
import { assembleAsset, PACKAGE_ROOT, readPackageFile } from "./source-assets.mjs";
import { packageSurface } from "./surface.mjs";

const SELF = fileURLToPath(import.meta.url);

export const DIST = path.join(PACKAGE_ROOT, "dist");

export const LOCAL_OUTPUTS = Object.freeze([
  "bp-paper-editor.bundle.js",
  "bp-paper-editor.css",
  "bp-paper-code.js",
  "bp-paper-surface.css",
  "bp-paper-editor-shell.css",
  "bp-paper-mermaid.js",
  "contract.js",
]);

// The input census of a build: package source or the package's own node_modules.
// A parent traversal means a build reached a host asset, whatever the file was.
export function assertPackageInputs(metafiles) {
  for (const [output, metafile] of Object.entries(metafiles)) {
    const inputs = Object.keys(metafile.inputs);
    if (inputs.length === 0) throw new Error(`build-local: ${output} reports no inputs`);
    for (const input of inputs) {
      if (!/^(src|node_modules)\//.test(input) || input.split("/").includes(".."))
        throw new Error(`build-local: ${output} read ${input}, which is not package source or package node_modules`);
    }
  }
}

export function assertExactOutputs(dir, { dev = false } = {}) {
  const found = readdirSync(dir).filter((name) => !(dev && name.endsWith(".map"))).sort();
  const want = [...LOCAL_OUTPUTS].sort();
  if (JSON.stringify(found) !== JSON.stringify(want))
    throw new Error(`build-local: ${dir} holds ${JSON.stringify(found)}, expected exactly ${JSON.stringify(want)}`);
}

function assertVersions(evidence) {
  const pkg = JSON.parse(readPackageFile("package.json").toString("utf8"));
  if (evidence.contract !== pkg.barkpark.contractVersion)
    throw new Error(`build-local: bundle contract ${evidence.contract}, package.json says ${pkg.barkpark.contractVersion}`);
  if (evidence.editor !== pkg.version)
    throw new Error(`build-local: bundle editor ${evidence.editor}, package.json says ${pkg.version}`);
}

export async function buildLocal({ outDir = DIST, dev = false, logLevel = "info" } = {}) {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(outDir, { recursive: true });
  const at = (name) => path.join(outDir, name);
  const options = {
    absWorkingDir: PACKAGE_ROOT,
    bundle: true,
    metafile: true,
    logLevel,
    ...(dev ? { sourcemap: true } : { minify: true }),
  };

  const metafiles = {};
  metafiles["bp-paper-editor.bundle.js"] = (await buildBundle({ outfile: at("bp-paper-editor.bundle.js"), dev, logLevel })).metafile;
  metafiles["bp-paper-editor.css"] = (await build({ ...options, entryPoints: ["src/styles.css"], outfile: at("bp-paper-editor.css") })).metafile;
  metafiles["bp-paper-code.js"] = (await build({ ...options, entryPoints: ["src/reader-code.js"], format: "iife", outfile: at("bp-paper-code.js") })).metafile;
  metafiles["bp-paper-surface.css"] = (await build({
    ...options,
    stdin: {
      contents: assembleAsset("paper-surface").toString("utf8"),
      resolveDir: path.join(PACKAGE_ROOT, "src/paper-surface"),
      sourcefile: "assembled.css",
      loader: "css",
    },
    outfile: at("bp-paper-surface.css"),
  })).metafile;
  assertPackageInputs(metafiles);

  writeFileSync(at("bp-paper-editor-shell.css"), assembleAsset("editor-shell"));
  writeFileSync(at("bp-paper-mermaid.js"), readPackageFile("src/bp-paper-mermaid.js"));
  writeFileSync(at("contract.js"), readPackageFile("src/contract.js"));
  assertExactOutputs(outDir, { dev });

  if (dev) return { outDir, metafiles, evidence: null };
  const evidence = await packageSurface({ dir: outDir });
  assertVersions(evidence);
  return { outDir, metafiles, evidence };
}

if (process.argv[1] && realpathSync(process.argv[1]) === SELF) {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== "--dev")) {
    console.error(`build-local: unknown arguments ${JSON.stringify(args)}; usage: node scripts/build-local.mjs [--dev]`);
    process.exit(2);
  }
  const { evidence } = await buildLocal({ dev: args.includes("--dev") });
  console.log(`build-local: ${LOCAL_OUTPUTS.length} files in dist/${evidence ? `, BUILD_SHA ${evidence.build}` : ""}`);
}
