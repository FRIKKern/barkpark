// Barkpark's live shell keeps the fleet disclosure out of flow until explicitly opened.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

for (const file of ["../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-fleet-config\s*\{[^}]*bottom: 100%;/s,
    `${file}: a closed fleet disclosure sits in the gap above the block, out of flow`);
  assert.match(css, /\.bp-paper-contextual-controls\.bp-paper-fleet-config\[open\]\s*\{[^}]*position: relative;/s,
    `${file}: an OPENED fleet disclosure takes flow space (an explicit click, never a hover)`);
}
const shell = readFileSync(new URL("../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
assert.match(shell, /\n\.bp-paper-contextual-controls\s*\{[^}]*position: absolute;[^}]*opacity: 0;/s,
  "the closed disclosure is absolutely placed and hidden by opacity, so revealing it moves nothing");

console.log("fleet hover island shell CSS: ok");
