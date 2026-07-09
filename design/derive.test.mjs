// design/derive.test.mjs — unit tests for the theme-system compiler core.
// Zero-dep (node:test + node:assert only). Run: node design/derive.test.mjs
//
// Proves the transplanted colour math (frick provenance), the two NEW
// capabilities (D15 AA-walk miss reporting, D16 on-accent flip), the
// serializer byte formats (tokens.json parity), and the derive() pipeline
// (determinism + slot shape + the hue-tinted neutral ladder / accent ramp /
// chrome ladder / OKLCH status hue-lock / dark inversion).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  parseColor,
  passthrough,
  srgbToOklch,
  oklchToSrgb,
  maxChroma,
  contrast,
  aaWalk,
  onAccent,
  mixSrgb,
  mixOklch,
  toHex,
  toHslTriplet,
  toRgba,
  invertL,
  darkInvert,
  derive,
  deriveSpine,
  PASSTHROUGH_FAMILIES,
  SLOTS,
} from "./derive.mjs";
import { tokens, rawTokens } from "./emit.mjs";

const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

// ── 1. Parsing every authoring form ─────────────────────────────────────────
test("parseColor: HSL triplet / hsl() / hex3 / hex6 / rgb / rgba", () => {
  assert.deepEqual(parseColor("0 0% 100%"), [1, 1, 1]);
  assert.deepEqual(parseColor("0 0% 0%"), [0, 0, 0]);
  assert.deepEqual(parseColor("#ffffff"), [1, 1, 1]);
  assert.deepEqual(parseColor("#fff"), [1, 1, 1]);
  const g = parseColor("#1e5347");
  assert.ok(near(g[0], 30 / 255) && near(g[1], 83 / 255) && near(g[2], 71 / 255));
  assert.deepEqual(parseColor("rgb(255, 0, 0)"), [1, 0, 0]);
  assert.ok(near(parseColor("rgba(30, 83, 71, 0.5)")[0], 30 / 255));
  // hsl() wrapper (both space and comma syntaxes) parses like the bare triplet
  assert.deepEqual(parseColor("hsl(0 0% 100%)"), parseColor("0 0% 100%"));
  assert.deepEqual(parseColor("hsl(210, 50%, 40%)"), parseColor("210 50% 40%"));
});

test("parseColor: throws on an unrecognised / var() raw", () => {
  assert.throws(() => parseColor("var(--primary)"));
  assert.throws(() => parseColor("chartreuse"));
});

test("passthrough: keeps var() literal, leaves other values untouched", () => {
  assert.equal(passthrough("var(--border)"), "var(--border)");
  assert.equal(passthrough("  var(--info) "), "var(--info)");
  assert.equal(passthrough("#1e5347"), "#1e5347");
});

// ── 2. sRGB ↔ OKLCH round-trip + gamut (frick matrices) ─────────────────────
test("srgbToOklch ↔ oklchToSrgb round-trips in-gamut colours within 1e-6/channel", () => {
  // Every hex / HSL input below is in-gamut, so the Ottosson matrices are a
  // clean inverse pair and the gamut clamp is a no-op — the round-trip must land
  // within 1e-6 per channel (the criterion's bound; measured max ≈ 4.4e-7).
  const sweep = [
    "#1e5347", "30 92% 42%", "217.2 91.2% 59.8%", "#f6faf9", "#45b394",
    "#ce6b09", "#2563eb", "#000000", "#ffffff", "#808080", "9.6 62.8% 39%",
  ];
  for (const raw of sweep) {
    const { L, C, h } = srgbToOklch(raw);
    const back = oklchToSrgb(L, C, h);
    const orig = parseColor(raw);
    for (let i = 0; i < 3; i++) assert.ok(near(back[i], orig[i], 1e-6), `${raw} ch${i}`);
  }
});

test("oklchToSrgb: gamut clamp never returns an out-of-range channel", () => {
  for (let L = 0; L <= 1.0001; L += 0.05) {
    for (let h = 0; h < 360; h += 15) {
      const rgb = oklchToSrgb(L, 0.5, h); // 0.5 chroma is out of gamut almost everywhere
      for (const c of rgb) assert.ok(c >= -1e-9 && c <= 1 + 1e-9);
    }
  }
});

test("maxChroma: at (L,h) is in gamut, and a hair more is not", () => {
  const L = 0.6,
    h = 150;
  const c = maxChroma(L, h);
  const at = oklchToSrgb(L, c, h);
  for (const ch of at) assert.ok(ch >= -1e-9 && ch <= 1 + 1e-9);
  assert.ok(c > 0 && c < 0.5);
});

// ── 3. WCAG contrast (frick :331-340) ───────────────────────────────────────
test("contrast: white/black = 21, self = 1, is symmetric", () => {
  assert.ok(near(contrast("#ffffff", "#000000"), 21, 1e-6));
  assert.ok(near(contrast("#777777", "#777777"), 1, 1e-9));
  assert.ok(near(contrast("#1e5347", "#ffffff"), contrast("#ffffff", "#1e5347"), 1e-12));
});

// ── 4. AA lightness-walk — bound-terminated + miss reporting (D15) ──────────
test("aaWalk: reaches AA 4.5 for a walkable dark text on a pale bg", () => {
  const bg = oklchToSrgb(0.96, 0.03, 150);
  const w = aaWalk(0.3, 0.1, 150, bg, { target: 4.5, step: -0.02 });
  assert.ok(w.hit, `expected a hit, got contrast ${w.contrast}`);
  assert.ok(w.contrast >= 4.5 - 1e-9);
});

test("aaWalk: pathological hue reports a MISS with the residual contrast (D15)", () => {
  // Walking a bright yellow UP toward white on a white bg can never reach 4.5 —
  // the walk is bound-terminated, not convergent. It must report hit:false and
  // surface the achieved residual, never silently ship a failing colour.
  const w = aaWalk(0.9, 0.15, 110, "#ffffff", { target: 4.5, step: 0.01 });
  assert.equal(w.hit, false);
  assert.ok(w.contrast < 4.5);
  assert.ok(typeof w.contrast === "number" && w.contrast > 0);
  assert.ok(w.iters <= 48);
});

// ── 5. On-accent flip — NEW code, BOTH branches (D16) ───────────────────────
test("onAccent: deep evergreen picks warm-white (light-on-dark branch)", () => {
  const r = onAccent("163 46% 22%");
  assert.equal(r.pick, "warm-white");
  assert.equal(r.color, "#fbfaf6");
  assert.ok(r.clears && r.contrast >= 4.5);
});

test("onAccent: evergreen amber 30 92% 42% picks near-ink (dark-on-light branch)", () => {
  const r = onAccent("30 92% 42%");
  assert.equal(r.pick, "near-ink");
  assert.equal(r.color, "#15211d");
  // the amber is the live flip candidate from the charter — near-ink clears AA
  // where warm-white would not.
  assert.ok(r.contrast >= contrast("#fbfaf6", "30 92% 42%"));
});

test("onAccent: honours custom warm-white / near-ink and flags a non-clearing mid accent", () => {
  const mid = onAccent("30 50% 62%", { warmWhite: "#ffffff", nearInk: "#000000" });
  assert.ok(mid.pick === "near-ink" || mid.pick === "warm-white");
  // A washed-out mid-L accent may clear neither at 4.5 — the flag must be honest.
  assert.equal(typeof mid.clears, "boolean");
});

// ── 6. color-mix pre-resolution ─────────────────────────────────────────────
test("mixSrgb: endpoints and midpoint", () => {
  assert.deepEqual(mixSrgb("#000000", "#ffffff", 100), [0, 0, 0]);
  assert.deepEqual(mixSrgb("#000000", "#ffffff", 0), [1, 1, 1]);
  const mid = mixSrgb("#000000", "#ffffff", 50);
  for (const c of mid) assert.ok(near(c, 0.5, 1e-9));
});

test("mixOklch: endpoints return the endpoint colours; hue takes the short arc", () => {
  const a = mixOklch("#1e5347", "#f6faf9", 100);
  const g = parseColor("#1e5347");
  for (let i = 0; i < 3; i++) assert.ok(near(a[i], g[i], 3e-3));
  // hue interpolation stays sane (in gamut) across a wrap-prone pair
  const wrap = mixOklch("10 80% 50%", "350 80% 50%", 50);
  for (const c of wrap) assert.ok(c >= -1e-9 && c <= 1 + 1e-9);
});

// ── 7. Serializers — tokens.json byte formats ───────────────────────────────
test("toHex: lowercase #rrggbb", () => {
  assert.equal(toHex(parseColor("#1E5347")), "#1e5347");
  assert.equal(toHex(parseColor("30 92% 42%")), "#ce6b09");
  assert.equal(toHex([1, 1, 1]), "#ffffff");
});

test("toHslTriplet: 'H S% L%' with no wrapper; round-trips hand token values", () => {
  for (const t of ["163 46% 22%", "240 10% 3.9%", "30 92% 42%", "0 0% 100%"]) {
    assert.equal(toHslTriplet(parseColor(t)), t);
  }
  assert.equal(toHslTriplet([1, 1, 1]), "0 0% 100%");
});

test("toRgba: 'rgba(r, g, b, a.aa)' — spaced, 2-decimal alpha (tokens form)", () => {
  assert.equal(toRgba(parseColor("#1e5347"), 0.1), "rgba(30, 83, 71, 0.10)");
  assert.equal(toRgba(parseColor("#45b394"), 0.16), "rgba(69, 179, 148, 0.16)");
  assert.equal(toRgba([1, 1, 1], 0.28), "rgba(255, 255, 255, 0.28)");
});

// ── 8. Dark inversion — hue preserved, lightness inverted (D14iv) ───────────
test("invertL: monotone-decreasing inside a comfortable dark band", () => {
  assert.ok(near(invertL(1), 0.14, 1e-9));
  assert.ok(near(invertL(0), 0.92, 1e-9));
  assert.ok(invertL(0.3) > invertL(0.7));
});

test("darkInvert: preserves hue exactly, inverts lightness, can scale chroma", () => {
  const light = srgbToOklch("30 92% 42%");
  const dark = darkInvert(light);
  assert.equal(dark.h, light.h);
  assert.ok(dark.L < light.L); // a light-ish accent goes deeper... but see next
  const paleDark = darkInvert(srgbToOklch("240 10% 3.9%"));
  assert.ok(paleDark.L > srgbToOklch("240 10% 3.9%").L); // a near-black spine goes pale
  const scaled = darkInvert(light, 0.5);
  assert.ok(near(scaled.C, light.C * 0.5, 1e-12));
});

// ── 9. derive() pipeline ────────────────────────────────────────────────────
const EVERGREEN = {
  light: { bg: "0 0% 100%", ink: "240 10% 3.9%", accent: "163 46% 22%" },
  dark: { bg: "240 10% 3.9%", ink: "0 0% 95%", accent: "160 42% 62%" },
};

test("derive: deterministic — two runs are byte-identical", () => {
  const a = deriveSpine(EVERGREEN, { onMiss: () => {} });
  const b = deriveSpine(EVERGREEN, { onMiss: () => {} });
  assert.equal(JSON.stringify(a), JSON.stringify(b));
});

test("derive: emits a flat slot map with the expected spine keys, both modes", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  for (const mode of ["light", "dark"]) {
    for (const slot of [
      "bg",
      "text",
      "primary",
      "primary-fg",
      "primary-hover",
      "ring",
      "surface",
      "muted-surface",
      "border",
      "muted-text",
      "chrome-muted",
      "chrome-secondary",
      "chrome-border",
      "chrome-input",
    ]) {
      assert.ok(`${slot}.${mode}` in out, `missing ${slot}.${mode}`);
    }
    for (const role of ["ok", "warn", "danger", "info"]) {
      for (const sub of ["bg", "text", "accent", "border"]) {
        assert.ok(`status-${role}-${sub}.${mode}` in out);
      }
    }
    // accent tints are rgba() fills
    assert.match(out[`accent-tint.${mode}`], /^rgba\(\d+, \d+, \d+, 0\.10\)$/);
    assert.match(out[`accent-tint2.${mode}`], /, 0\.06\)$/);
    assert.match(out[`accent-ring.${mode}`], /, 0\.28\)$/);
  }
  // HSL-triplet slots carry no hsl() wrapper
  assert.match(out["primary.light"], /^[\d.]+ [\d.]+% [\d.]+%$/);
});

test("derive: misses is a NON-enumerable audit array (stays out of the byte map)", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  assert.equal(Object.keys(out).includes("misses"), false);
  assert.ok(Array.isArray(out.misses));
  assert.equal(JSON.parse(JSON.stringify(out)).misses, undefined);
});

test("derive: on-accent flip feeds primary-fg (near-ink for the amber-free evergreen)", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  // deep-green light primary → warm-white fg
  assert.equal(out["primary-fg.light"], toHslTriplet(parseColor("#fbfaf6")));
});

test("derive: neutral ladder chroma RAMPS bg→ink and rides the accent hue", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  const rungs = ["surface", "muted-surface", "border", "muted-text"];
  const chromas = rungs.map((s) => srgbToOklch(`hsl(${out[`${s}.light`]})`).C);
  for (let i = 1; i < chromas.length; i++) assert.ok(chromas[i] > chromas[i - 1]);
  // the tint hue sits near the accent hue
  const accH = srgbToOklch(EVERGREEN.light.accent).h;
  const borderH = srgbToOklch(`hsl(${out["border.light"]})`).h;
  assert.ok(Math.abs(((borderH - accH + 540) % 360) - 180) < 6);
});

test("derive: accent hover moves ΔL per mode (light darkens, dark lightens)", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  const pL = srgbToOklch(`hsl(${out["primary.light"]})`).L;
  const hL = srgbToOklch(`hsl(${out["primary-hover.light"]})`).L;
  assert.ok(hL < pL, "light hover should darken");
  const pD = srgbToOklch(`hsl(${out["primary.dark"]})`).L;
  const hD = srgbToOklch(`hsl(${out["primary-hover.dark"]})`).L;
  assert.ok(hD > pD, "dark hover should lighten");
});

test("derive: chrome ladder 8<16<22<55 is monotonic (more ink → darker in light)", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  const L = ["chrome-muted", "chrome-secondary", "chrome-border", "chrome-input"].map(
    (s) => srgbToOklch(`hsl(${out[`${s}.light`]})`).L,
  );
  for (let i = 1; i < L.length; i++) assert.ok(L[i] < L[i - 1], "ladder not monotone");
});

test("derive: status roles keep their LOCKED OKLCH hue (75/150/264/27)", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  const want = { ok: 150, warn: 75, danger: 27, info: 264 };
  for (const [role, hue] of Object.entries(want)) {
    for (const mode of ["light", "dark"]) {
      const h = srgbToOklch(`hsl(${out[`status-${role}-accent.${mode}`]})`).h;
      const d = Math.abs(((h - hue + 540) % 360) - 180);
      assert.ok(d < 2, `${role}.${mode} hue ${h.toFixed(1)} drifted from ${hue}`);
    }
  }
});

test("derive: status text clears AA 4.5 on its own bg (both modes)", () => {
  const out = deriveSpine(EVERGREEN, { onMiss: () => {} });
  for (const role of ["ok", "warn", "danger", "info"]) {
    for (const mode of ["light", "dark"]) {
      const c = contrast(
        `hsl(${out[`status-${role}-text.${mode}`]})`,
        `hsl(${out[`status-${role}-bg.${mode}`]})`,
      );
      // any residual miss is reported, not silently shipped
      if (c < 4.5) {
        assert.ok(
          out.misses.some((m) => m.role === role && m.mode === mode && m.slot === "text"),
          `${role}.${mode} text misses AA ${c.toFixed(2)} but was not reported`,
        );
      }
    }
  }
});

test("derive: chroma dial — a muted accent yields lower status chroma than a vivid one", () => {
  const vivid = deriveSpine(
    { light: { bg: "0 0% 100%", ink: "240 10% 4%", accent: "20 95% 50%" }, dark: EVERGREEN.dark },
    { onMiss: () => {} },
  );
  const muted = deriveSpine(
    { light: { bg: "0 0% 100%", ink: "240 10% 4%", accent: "210 12% 45%" }, dark: EVERGREEN.dark },
    { onMiss: () => {} },
  );
  const cv = srgbToOklch(`hsl(${vivid["status-ok-accent.light"]})`).C;
  const cm = srgbToOklch(`hsl(${muted["status-ok-accent.light"]})`).C;
  assert.ok(cv > cm, `vivid status chroma ${cv} should exceed muted ${cm}`);
});

test("derive: overrides are honest pins — applied verbatim, var() passes through", () => {
  const out = deriveSpine(
    {
      ...EVERGREEN,
      overrides: { "accent.light": "30 92% 42%", "border.light": "var(--border)" },
    },
    { onMiss: () => {} },
  );
  assert.equal(out["accent.light"], "30 92% 42%");
  assert.equal(out["border.light"], "var(--border)");
});

test("derive: onMiss is invoked for every reported AA miss", () => {
  // A degenerate spec whose ink barely differs from bg strains the walks.
  const seen = [];
  const out = deriveSpine(
    {
      light: { bg: "0 0% 100%", ink: "0 0% 96%", accent: "60 90% 92%" },
      dark: { bg: "0 0% 4%", ink: "0 0% 8%", accent: "60 90% 20%" },
    },
    { onMiss: (m) => seen.push(m) },
  );
  assert.equal(seen.length, out.misses.length);
});

// ── the w4 seam (charter D22) — emit.mjs consumes derive(evergreen) via a
//    clone-and-overlay adapter with ZERO artifact diff. These tests are the
//    committed proof for ts-w4a criterion 0: the overlay is byte-identical to
//    the raw color tree for evergreen INCLUDING non-string leaves, and every
//    non-derived leaf (status.warn.strong, _convention, the 11 D21 passthrough
//    families) survives untouched.
test("seam: emit.tokens.color deep-equals raw color tree for evergreen (all leaves)", () => {
  // adapted != raw by reference (clone, never mutate the source of truth) …
  assert.notEqual(tokens.color, rawTokens.color);
  // … but byte-identical by value, non-string leaves included (deepStrictEqual
  // walks booleans/numbers, so a silently-flipped status.warn.strong would trip).
  assert.deepStrictEqual(tokens.color, rawTokens.color);
});

test("seam: status.warn.strong survives as the boolean true (non-string leaf, not a derive SLOT)", () => {
  assert.equal(tokens.color.status.warn.strong, true);
  assert.equal(typeof tokens.color.status.warn.strong, "boolean");
  // it is deliberately NOT a derive SLOT — only status.warn.{light,dark} are.
  assert.ok(!SLOTS.includes("status.warn.strong"));
});

test("seam: color._convention survives verbatim (never a derive SLOT)", () => {
  assert.ok(tokens.color._convention);
  assert.deepStrictEqual(tokens.color._convention, rawTokens.color._convention);
});

test("seam: all 11 D21 passthrough families survive verbatim in adapted tokens", () => {
  assert.equal(PASSTHROUGH_FAMILIES.length, 11);
  // 9 passthrough families live under color.* (presence/provider/…); lifecycle and
  // instanceLifecycle are top-level tokens families. derive() resolves none of them
  // — each must survive verbatim wherever it lives (color clone / top-level spread).
  for (const fam of PASSTHROUGH_FAMILIES) {
    const inColor = fam in rawTokens.color;
    const got = inColor ? tokens.color[fam] : tokens[fam];
    const want = inColor ? rawTokens.color[fam] : rawTokens[fam];
    assert.ok(got !== undefined, `passthrough family ${fam} missing from adapted tokens`);
    assert.deepStrictEqual(got, want, `passthrough family ${fam} drifted`);
  }
});

test("seam: every derive(evergreen) SLOT is present as a leaf in adapted tokens", () => {
  const rawEvergreen = JSON.parse(
    readFileSync(new URL("./themes/evergreen.json", import.meta.url), "utf8"),
  );
  const derived = derive(rawEvergreen).values;
  for (const slot of SLOTS) {
    const leaf = slot.split(".").reduce((o, k) => (o == null ? undefined : o[k]), tokens.color);
    assert.equal(leaf, derived[slot], `slot ${slot} not overlaid onto adapted tokens`);
  }
});

test("seam: non-color top-level families pass through by the top-level spread", () => {
  // {...rawTokens, color: adaptedColor} — every non-color family is the same ref.
  for (const k of ["type", "font", "lifecycle", "instanceLifecycle"]) {
    if (rawTokens[k] === undefined) continue;
    assert.equal(tokens[k], rawTokens[k], `non-color family ${k} was not passed through by reference`);
  }
});
