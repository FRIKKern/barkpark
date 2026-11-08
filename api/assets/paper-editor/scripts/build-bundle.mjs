// Builds bp-paper-editor.bundle.js with __BP_BUILD_SHA__ defined (src/contract.js,
// scripts/build-sha.mjs). dev keeps a sourcemap instead of minifying. Run through
// scripts/build-local.mjs, which owns the output directory.
import { build } from "esbuild";
import { bundleOptions, buildSha } from "./build-sha.mjs";

export async function buildBundle({ outfile = bundleOptions.outfile, dev = false, logLevel = "info" } = {}) {
  return build({
    ...bundleOptions,
    outfile,
    logLevel,
    metafile: true,
    ...(dev ? { sourcemap: true } : { minify: true }),
    define: { __BP_BUILD_SHA__: JSON.stringify(await buildSha()) },
  });
}
