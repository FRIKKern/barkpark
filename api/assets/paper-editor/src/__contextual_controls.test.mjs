import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const styles = readFileSync(new URL("./styles.css", import.meta.url), "utf8");

assert.match(styles, /\[data-test-id="paper-canvas-resume-warning"\]\s*\{[^}]*font-family:\s*var\(--paper-font-ui/s,
  "standalone reconnect recovery uses editor chrome rather than document prose");
assert.match(styles, /\[data-test-id="paper-canvas-resume-warning"\] button\s*\{[^}]*min-height:\s*44px/s,
  "standalone recovery actions have themed touch-sized controls");

const luminance = hex => hex.match(/\w\w/g).map(value => parseInt(value, 16) / 255)
  .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
  .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);

let checked = 0;
for (const [, body] of styles.matchAll(/\{([^{}]*)\}/g)) {
  const background = body.match(/--paper-bg:\s*#([0-9a-f]{6})\s*;/i)?.[1];
  const foreground = body.match(/--paper-ink-soft:\s*#([0-9a-f]{6})\s*;/i)?.[1];
  if (!background || !foreground) continue;
  const [low, high] = [luminance(background), luminance(foreground)].sort((a, b) => a - b);
  assert.ok((high + 0.05) / (low + 0.05) >= 4.5, "standalone theme labels meet normal-text contrast");
  checked += 1;
}
assert.ok(checked >= 2, "standalone checks light and dark authored token pairs");

console.log("PASS contextual controls: standalone recovery typography and light/dark contrast");
