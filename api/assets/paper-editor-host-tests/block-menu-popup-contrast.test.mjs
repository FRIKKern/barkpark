// The Barkpark shell owns the slash menu's active-row ink and theme tokens.
// Run directly from any working directory:
//   node api/assets/paper-editor-host-tests/block-menu-popup-contrast.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

let failures = 0, ran = 0;
function check(name, fn) { ran += 1; try { fn(); console.log(`PASS  ${name}`); } catch (e) { failures += 1; console.log(`FAIL  ${name}`); console.log(`      ${e.message}`); } }

// WCAG 2.x contrast.
const hex = (h) => { h = h.replace("#", ""); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };
const rgba = (s) => { const m = s.match(/rgba\(\s*(\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\)/); return { c: [+m[1], +m[2], +m[3]], a: +m[4] }; };
const lum = (c) => { const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }; return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]); };
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const over = (fg, a, bg) => fg.map((v, i) => Math.round(v * a + bg[i] * (1 - a)));
const tokens = (css, selector) => {
  const at = css.indexOf(selector + " {");
  assert.ok(at >= 0, `rule ${selector}`);
  const body = css.slice(at, css.indexOf("}", at));
  const get = (k) => (body.match(new RegExp(`${k}:\\s*([^;]+);`)) || [])[1].trim();
  return { soft: get("--paper-ink-soft"), accentSoft: get("--paper-accent-soft"), chrome: get("--paper-chrome-bg") };
};

try {
  const shell = readFileSync(new URL("../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
  check("the active slash row shows its faint text in the soft ink", () => {
    assert.match(shell, /\.bp-slash-item\.is-active \.bp-slash-desc \{ color: var\(--paper-ink-soft\); \}/);
  });
  for (const [label, sel] of [["light", 'html[data-theme="light"] .bp-slash-menu'], ["dark", 'html[data-theme="dark"] .bp-slash-menu']]) {
    check(`${label}: soft ink on the active slash row meets AA 4.5:1`, () => {
      const t = tokens(shell, sel);
      const a = rgba(t.accentSoft);
      const bg = over(a.c, a.a, hex(t.chrome));
      const r = ratio(hex(t.soft), bg);
      assert.ok(r >= 4.5, `${r.toFixed(2)}:1`);
    });
  }
} catch (e) {
  failures += 1;
  console.log(`FAIL  setup threw: ${e.message}`);
} finally {
  if (ran !== 3) { failures += 1; console.log(`FAIL  ran ${ran} of 3 checks`); }
}
if (failures) { console.log(`${failures} failure(s)`); process.exit(1); }
console.log("Barkpark block menu popup contrast passed");
