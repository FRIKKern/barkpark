#!/usr/bin/env node
// Copies the files @barkpark/paper-editor ships into dist/ and LICENSE.
//
// `npm run build` writes the bundle and stylesheet into api/priv/static/assets,
// where Phoenix serves them. npm pack can only include files under this
// package, so `prepack` runs this script to copy them in. dist/ and LICENSE
// are build output and are not committed. The copies are byte for byte: a
// consumer of the package runs the same bytes Phoenix serves.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const assets = path.resolve(root, "../../priv/static/assets");
const dist = path.join(root, "dist");

// [source, destination], both relative to their roots.
export const STAGED = [
  [path.join(assets, "bp-paper-editor.bundle.js"), "dist/bp-paper-editor.bundle.js"],
  [path.join(assets, "bp-paper-editor.css"), "dist/bp-paper-editor.css"],
  [path.join(assets, "bp-paper-editor-shell.css"), "dist/bp-paper-editor-shell.css"],
  [path.join(assets, "bp-paper-mermaid.js"), "dist/bp-paper-mermaid.js"],
  [path.join(root, "src/contract.js"), "dist/contract.js"],
  [path.resolve(root, "../../../LICENSE"), "LICENSE"],
];

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  fs.rmSync(dist, { recursive: true, force: true });
  fs.mkdirSync(dist, { recursive: true });
  for (const [src, dest] of STAGED) {
    if (!fs.existsSync(src)) throw new Error(`missing ${src}; run npm run build first`);
    fs.copyFileSync(src, path.join(root, dest));
  }
  console.log(`Staged ${STAGED.length} files for npm pack`);
}
