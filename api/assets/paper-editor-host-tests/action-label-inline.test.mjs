// The live Barkpark shell must keep the standalone action label in place and
// must not restore the removed separate label input.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

for (const [name, path] of [
  ["shell", "../../priv/static/assets/bp-paper-editor-shell.css"],
]) {
  const css = readFileSync(new URL(path, import.meta.url), "utf8");
  assert.match(css, /\.bp-canvas-action \[data-test-id="paper-action-label"\]:empty::before \{ content: attr\(data-placeholder\);/,
    `${name}: an empty in-place label keeps the button shape and names what goes there`);
  assert.doesNotMatch(css, /\.bp-canvas-action-label\b/, `${name}: no separate label input remains`);
}
