#!/usr/bin/env node
// Builds bp-paper-editor.bundle.js with its BUILD_SHA (src/contract.js).
//
// A first esbuild pass lists the bundle's input files without writing; their
// bytes and esbuild's version hash into BUILD_SHA, and the second pass writes the
// bundle with it defined. The sha depends only on what goes into the bundle, so
// a rebuild of the same source gives the same bytes (CI's freshness check), and
// a test-only change leaves it alone.
import { build, version } from "esbuild";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dev = process.argv.includes("--dev");
const options = {
  absWorkingDir: root,
  entryPoints: ["src/index.js"],
  bundle: true,
  format: "iife",
  outfile: "../../priv/static/assets/bp-paper-editor.bundle.js",
  logLevel: "info",
  ...(dev ? { sourcemap: true } : { minify: true }),
};

export async function buildSha() {
  const { metafile } = await build({ ...options, write: false, metafile: true, logLevel: "silent" });
  const hash = createHash("sha256").update(`esbuild ${version}\0`);
  for (const input of Object.keys(metafile.inputs).sort()) {
    hash.update(`${input}\0`).update(readFileSync(path.join(root, input))).update("\0");
  }
  return hash.digest("hex").slice(0, 12);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await build({ ...options, define: { __BP_BUILD_SHA__: JSON.stringify(await buildSha()) } });
}
