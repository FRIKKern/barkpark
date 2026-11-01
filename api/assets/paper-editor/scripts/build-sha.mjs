// The bundle's esbuild options and its BUILD_SHA: the first 12 hex of the sha-256
// over esbuild's version and every input file of the bundle, listed by a metafile
// pass that writes nothing. The sha depends only on what goes into the bundle, so
// a rebuild of the same source gives the same bytes (CI's freshness check), and a
// test-only change leaves it alone.
import { build, version } from "esbuild";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

export const bundleOptions = {
  absWorkingDir: root,
  entryPoints: ["src/index.js"],
  bundle: true,
  format: "iife",
  outfile: "../../priv/static/assets/bp-paper-editor.bundle.js",
};

export async function buildSha() {
  const { metafile } = await build({ ...bundleOptions, write: false, metafile: true, logLevel: "silent" });
  const hash = createHash("sha256").update(`esbuild ${version}\0`);
  for (const input of Object.keys(metafile.inputs).sort()) {
    hash.update(`${input}\0`).update(readFileSync(path.join(root, input))).update("\0");
  }
  return hash.digest("hex").slice(0, 12);
}
