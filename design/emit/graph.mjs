// design/emit/graph.mjs — the bp-graph.js Canvas palette block.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { loadThemes, tokens } from "./source.mjs";

// ── the bp-graph.js Canvas palette block (task au-r6) ────────────────────────
// Emits the renderer's colour constants from tokens.json. Only COLOUR lives here:
// alphas, radii, zoom-fade multipliers and the font stack stay hand-written in
// bp-graph.js outside the marker, because they are not colour tokens and moving
// them would put non-design geometry under the theme compiler.
export function graphPaletteBlock(t = tokens) {
  const g = t.color.graphCanvas.graph;
  const q = (v) => JSON.stringify(v);
  const L = [];
  const line = (name, value) => L.push(`  var ${name} = ${q(value)};`);

  L.push("  // Obsidian-faithful restyle: small flat dots, thin faint threads, near-");
  L.push("  // monochrome, generous void. Beauty through restraint.");
  line("ACCENT", g.accent);
  // DERIVED from accent, never a second token: a hand-kept `accentRgb` sibling
  // silently survives an `accent` edit (measured — the mutation proof for au-r6
  // changed accent and ACCENT_RGB stayed on the old hue), which is the exact drift
  // this task exists to remove.
  const rgbOf = (hex) => {
    let h = hex.replace("#", "");
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  };
  L.push(`  var ACCENT_RGB = [${rgbOf(g.accent).join(", ")}];`);
  line("A11Y_RING", g.a11yRing);
  line("SLATE", g.slate);
  line("AMBER", g.amber);
  L.push("");
  L.push("  // LIGHT-ground siblings for the four hues above — the only colours this");
  L.push("  // renderer paints RAW on whichever ground is active. The dark values land at");
  L.push("  // 2.53/2.31/2.33/1.52 on BG_LIGHT, all under the 3.0 WCAG non-text floor, and");
  L.push("  // A11Y_RING is the keyboard focus ring. accent()/a11yRing()/slate()/amber()");
  L.push("  // below pick between the pair; dark keeps its original vivid values.");
  line("ACCENT_LIGHT", g.accentLight);
  line("A11Y_RING_LIGHT", g.a11yRingLight);
  line("SLATE_LIGHT", g.slateLight);
  line("AMBER_LIGHT", g.amberLight);
  L.push("");
  L.push("  // Monochrome node tint — one muted desaturated lavender-grey for EVERY node");
  L.push("  // on dark (the default look). Per-type colour is the opt-in \"Full color\" toggle.");
  line("MONO_DARK", g.monoDark);
  line("MONO_LIGHT", g.monoLight);
  line("NODE_WHITE", g.nodeWhite);
  line("NODE_INK_LIGHT", g.nodeInkLight);
  L.push("");
  L.push("  // Flat theme backgrounds (no gradient, no vignette).");
  line("BG_DARK", g.bgDark);
  line("BG_LIGHT", g.bgLight);
  L.push("");
  L.push("  // Link base colour channels — very faint thin threads (alphas stay outside).");
  line("LINK_RGB_DARK", g.linkRgbDark);
  line("LINK_RGB_LIGHT", g.linkRgbLight);
  L.push("");
  L.push("  // Label colours: resting, hovered, and the mix targets a matched label walks to.");
  line("LABEL_COLOR_DARK", g.labelDark);
  line("LABEL_COLOR_LIGHT", g.labelLight);
  line("LABEL_HOT_DARK", g.labelHotDark);
  line("LABEL_HOT_LIGHT", g.labelHotLight);
  line("LABEL_MIX_DARK", g.labelMixDark);
  line("LABEL_MIX_LIGHT", g.labelMixLight);
  line("LABEL_HOV_DARK", g.labelHovDark);
  line("LABEL_SHADOW_DARK", g.labelShadowDark);
  line("LABEL_SHADOW_LIGHT", g.labelShadowLight);
  L.push("");
  L.push("  // Canvas toast pill + the hover tooltip's own glass.");
  line("TOAST_BG_DARK", g.toastBgDark);
  line("TOAST_BG_LIGHT", g.toastBgLight);
  line("TOAST_BORDER", g.toastBorder);
  line("TOOLTIP_TITLE_DARK", g.tooltipTitleDark);
  line("TOOLTIP_TITLE_LIGHT", g.tooltipTitleLight);
  line("TOOLTIP_META_DARK", g.tooltipMetaDark);
  line("TOOLTIP_META_LIGHT", g.tooltipMetaLight);
  line("TOOLTIP_BG_DARK", g.tooltipBgDark);
  line("TOOLTIP_BG_LIGHT", g.tooltipBgLight);
  line("TOOLTIP_BORDER_DARK", g.tooltipBorderDark);
  line("TOOLTIP_BORDER_LIGHT", g.tooltipBorderLight);
  L.push("");
  L.push("  // Per-type hues — painted ONLY under the optional \"Full color\" toggle.");
  L.push("  var TYPE_HEX = {");
  const hues = Object.entries(g.typeHues).filter(([k]) => !k.startsWith("_"));
  for (const [k, v] of hues) L.push(`    ${/^[A-Za-z_$][\w$]*$/.test(k) ? k : q(k)}: ${q(v)},`);
  L.push(`    _unknown: ${q(g.slate)}`);
  L.push("  };");
  L.push("");
  L.push("  // Overlay chrome (legend, zoom strip, toggles, search) — inline styles on the");
  L.push("  // injected DOM, rebuilt by setTheme() so canvas and chrome flip together.");
  L.push("  var CHROME_PALETTE = {");
  for (const mode of ["light", "dark"]) {
    const c = g.chrome[mode];
    L.push(`    ${mode}: {`);
    const keys = Object.keys(c).filter((k) => !k.startsWith("_"));
    for (const k of keys) L.push(`      ${k}: ${q(c[k])},`);
    L.push(`      mono: ${q(mode === "light" ? g.monoLight : g.monoDark)}`);
    L.push(`    }${mode === "light" ? "," : ""}`);
  }
  L.push("  };");
  return L.join("\n");
}

export function bpThemesList(themes = loadThemes()) {
  return "    " + themes.map(({ name }) => JSON.stringify(name)).join(", ");
}
