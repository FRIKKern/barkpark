#!/usr/bin/env node
// Builds bp-paper-editor.bundle.js with __BP_BUILD_SHA__ defined (src/contract.js,
// scripts/build-sha.mjs). --dev keeps a sourcemap instead of minifying.
import { build } from "esbuild";
import { bundleOptions, buildSha } from "./build-sha.mjs";

const dev = process.argv.includes("--dev");
await build({
  ...bundleOptions,
  logLevel: "info",
  ...(dev ? { sourcemap: true } : { minify: true }),
  define: { __BP_BUILD_SHA__: JSON.stringify(await buildSha()) },
});
