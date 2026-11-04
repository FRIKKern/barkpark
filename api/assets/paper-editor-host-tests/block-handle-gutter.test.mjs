// The Barkpark host shell carries the same out-of-flow gutter contract as the
// standalone package stylesheet. Runtime placement remains package-owned.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

for (const file of ["../../priv/static/assets/bp-paper-editor-shell.css"]) {
  const css = readFileSync(new URL(file, import.meta.url), "utf8");
  assert.match(css, /(^|\n)bp-paper-canvas\s*\{[^}]*position: relative;/, `${file}: the canvas anchors its gutter chrome`);
  assert.match(css, /\n\.bp-block-handle\s*\{[^}]*position: absolute;/, `${file}: the block handle is out of flow`);
  assert.match(css, /\n\.bp-block-drop\s*\{[^}]*position: absolute;/, `${file}: the drop line is out of flow`);
  // Fixed since task-be754bd628311c5f: out of flow AND out of an overflow:auto
  // host's clip, so a phone's viewport-clamped menu stays reachable.
  assert.match(css, /\n\.bp-block-menu\s*\{[^}]*position: (absolute|fixed);/, `${file}: the block menu is out of flow`);
}
