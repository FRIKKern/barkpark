#!/usr/bin/env node
// The one path from this package out to Barkpark.
//
//   node scripts/sync-barkpark.mjs --check                 read-only; exit 1 names every stale sink
//   node scripts/sync-barkpark.mjs --write                 the same comparison, then writes the stale sinks
//   node scripts/sync-barkpark.mjs --write --surface-only  raw paper surface and tracked profile only
//
// Both compare a fresh temporary build, never dist/, so a stale local build cannot
// vouch for anything. The sinks are read only to compare them: nothing here copies
// a Barkpark file into the package.
//
// --surface-only is for the design writers (design/emit.mjs and
// scripts/status-manifest-check.sh --write), which change one generated span in a
// surface fragment. It leaves the six browser assets alone, so run a full --write
// before committing a rebuilt editor. Design tooling runs without this package's
// node_modules, so with no toolchain it writes the raw surface, says the profile was
// not composed, and leaves the stale state for --check to catch.
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { assembleAsset, PACKAGE_ROOT, readPackageFile } from "./source-assets.mjs";

const SELF = fileURLToPath(import.meta.url);
const REPO = path.resolve(PACKAGE_ROOT, "../../..");

export const RAW_SURFACE_SINK = "api/assets/paper-surface/paper-surface.css";
export const RAW_TOKENS_SINK = "api/assets/paper-surface/code-tokens.css";
export const PROFILE_SINK = "api/assets/paper-editor/host-profile/surface.json";

// Each local output and the Barkpark files that serve it. contract.js has no
// browser sink: it stays a package output.
export const BROWSER_SINKS = Object.freeze({
  "bp-paper-editor.bundle.js": Object.freeze(["api/priv/static/assets/bp-paper-editor.bundle.js", "web/public/bp-paper-editor.bundle.js"]),
  "bp-paper-editor.css": Object.freeze(["api/priv/static/assets/bp-paper-editor.css", "web/public/assets/bp-paper-editor.css"]),
  "bp-paper-code.js": Object.freeze(["api/priv/static/assets/bp-paper-code.js"]),
  "bp-paper-surface.css": Object.freeze(["api/priv/static/assets/bp-paper-surface.css"]),
  "bp-paper-editor-shell.css": Object.freeze(["api/priv/static/assets/bp-paper-editor-shell.css"]),
  "bp-paper-mermaid.js": Object.freeze(["api/priv/static/assets/bp-paper-mermaid.js"]),
});

// A fresh build in a temporary directory: its browser outputs as bytes, and the
// profile composed from its package evidence and the live reader.
export async function freshBuild() {
  const { buildLocal } = await import("./build-local.mjs");
  const { composeBarkparkSurface, liveReaderSource, render } = await import("./surface.mjs");
  const outDir = mkdtempSync(path.join(tmpdir(), "bp-sync-barkpark-"));
  try {
    const { evidence } = await buildLocal({ outDir, logLevel: "warning" });
    const outputs = Object.fromEntries(Object.keys(BROWSER_SINKS).map((name) => [name, readFileSync(path.join(outDir, name))]));
    return { outputs, profile: Buffer.from(render(composeBarkparkSurface(evidence, liveReaderSource())), "utf8") };
  } finally {
    rmSync(outDir, { recursive: true, force: true });
  }
}

// Every sink and the bytes it must hold, in write order. The profile goes last, so
// an interrupted write leaves a profile that still reads as stale.
export function expectedSinks({ built, rawSurface, rawTokens, surfaceOnly = false }) {
  const sinks = [[RAW_SURFACE_SINK, rawSurface]];
  if (!surfaceOnly) {
    sinks.push([RAW_TOKENS_SINK, rawTokens]);
    for (const [name, destinations] of Object.entries(BROWSER_SINKS)) {
      for (const destination of destinations) sinks.push([destination, built.outputs[name]]);
    }
  }
  if (built) sinks.push([PROFILE_SINK, built.profile]);
  return sinks;
}

const staleReason = (repo, destination, bytes) => {
  const at = path.join(repo, destination);
  if (!existsSync(at)) return "missing";
  return readFileSync(at).equals(bytes) ? null : "stale";
};

function writeAtomic(repo, destination, bytes) {
  const at = path.join(repo, destination);
  mkdirSync(path.dirname(at), { recursive: true });
  const temp = `${at}.sync-${process.pid}`;
  try {
    writeFileSync(temp, bytes);
    renameSync(temp, at);
  } finally {
    rmSync(temp, { force: true });
  }
}

// Returns the exit code. `build` and `hasToolchain` are parameters so a synthetic
// tree can prove the write paths without a real build or a real Barkpark checkout.
export async function runSync({
  write = false,
  surfaceOnly = false,
  repo = REPO,
  root = PACKAGE_ROOT,
  build = freshBuild,
  hasToolchain = () => existsSync(path.join(root, "node_modules")),
  log = console.log,
  warn = console.error,
} = {}) {
  if (surfaceOnly && !write) throw new Error("sync-barkpark: --surface-only is a write mode");
  const toolchain = hasToolchain();
  if (!toolchain && !surfaceOnly) throw new Error("sync-barkpark: no node_modules in this package; run npm ci first");
  const built = toolchain ? await build() : null;
  const sinks = expectedSinks({
    built,
    rawSurface: assembleAsset("paper-surface", { root }),
    rawTokens: surfaceOnly ? null : readPackageFile("src/code-tokens.css", { root }),
    surfaceOnly,
  });
  const stale = sinks.flatMap(([destination, bytes]) => {
    const reason = staleReason(repo, destination, bytes);
    return reason ? [{ destination, bytes, reason }] : [];
  });

  if (!write) {
    for (const { destination, reason } of stale) warn(`${reason.toUpperCase()}  ${destination}`);
    if (stale.length) {
      warn(`sync-barkpark --check: ${stale.length} of ${sinks.length} Barkpark sinks differ from a fresh build. Fix: cd api/assets/paper-editor && npm run sync:barkpark:write`);
      return 1;
    }
    log(`sync-barkpark --check: all ${sinks.length} Barkpark sinks match a fresh build`);
    return 0;
  }

  for (const { destination, bytes } of stale) writeAtomic(repo, destination, bytes);
  const unwritten = sinks.filter(([destination, bytes]) => staleReason(repo, destination, bytes));
  if (unwritten.length) throw new Error(`sync-barkpark: ${unwritten.map(([destination]) => destination).join(", ")} did not take the write`);
  for (const { destination } of stale) log(`WROTE  ${destination}`);
  log(`sync-barkpark --write${surfaceOnly ? " --surface-only" : ""}: ${stale.length} of ${sinks.length} sinks written`);
  if (!toolchain) warn("sync-barkpark: no node_modules here, so host-profile/surface.json was not composed. Run npm ci, then npm run sync:barkpark:check in api/assets/paper-editor.");
  return 0;
}

export function parseArgs(args) {
  const known = new Set(["--check", "--write", "--surface-only"]);
  const unknown = args.filter((arg) => !known.has(arg));
  const check = args.includes("--check");
  const write = args.includes("--write");
  const surfaceOnly = args.includes("--surface-only");
  if (unknown.length || check === write || new Set(args).size !== args.length || (surfaceOnly && !write)) return null;
  return { write, surfaceOnly };
}

if (process.argv[1] && realpathSync(process.argv[1]) === SELF) {
  const parsed = parseArgs(process.argv.slice(2));
  if (!parsed) {
    console.error(`sync-barkpark: bad arguments ${JSON.stringify(process.argv.slice(2))}; usage: node scripts/sync-barkpark.mjs --check | --write [--surface-only]`);
    process.exit(2);
  }
  process.exit(await runSync(parsed));
}
