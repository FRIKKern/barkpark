import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const styles = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
const shell = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
const luminance = hex => hex.match(/\w\w/g).map(value => parseInt(value, 16) / 255)
  .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
  .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);

// Both mounted hosts load the shared shell; standalone supplies the evergreen
// token pairs, while the shell additionally carries warm-theme overrides.
const labels = shell.match(/\.bp-paper-contextual-panel \.bp-paper-edit-fieldlabel\s*\{([^}]*)\}/);
assert.ok(labels, "shared shell scopes the configuration-label rule");
assert.match(labels[1], /color:\s*var\(--paper-ink-soft\)/,
  "small form labels use readable text, not faint decorative text");

for (const [name, css] of [["standalone", styles], ["host shell", shell]]) {
  let checked = 0;
  for (const [, body] of css.matchAll(/\{([^{}]*)\}/g)) {
    const background = body.match(/--paper-bg:\s*#([0-9a-f]{6})\s*;/i)?.[1];
    const foreground = body.match(/--paper-ink-soft:\s*#([0-9a-f]{6})\s*;/i)?.[1];
    if (!background || !foreground) continue;
    const [low, high] = [luminance(background), luminance(foreground)].sort((a, b) => a - b);
    assert.ok((high + 0.05) / (low + 0.05) >= 4.5, `${name} theme labels meet normal-text contrast`);
    checked += 1;
  }
  assert.ok(checked >= 2, `${name} checks light and dark authored token pairs`);
}

console.log("PASS contextual labels: scoped readable token and light/dark contrast");
