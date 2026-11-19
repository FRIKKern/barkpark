// design/emit/barkui.mjs — the BarkUI sheet: today's skins under UI SDK's variable names.
// Part of design/emit.mjs, which registers it as a whole generated file.
//
// BarkUI, the shared UI foundation, reads UI SDK's `--ui-*` colour names plus a
// few `--bark-*` names of its own. This module writes every skin in
// design/themes/ under those names from the same derived slots the other
// surfaces read. Each skin writes every colour once as `light-dark(<light>,
// <dark>)`; each arm is the exact string an existing region writes for that
// slot and mode, so the two cannot drift. That is the Studio region's
// `hsl(<channels>)` for every name but --ui-ring, which is the cloud and login
// regions' --ring-soft, `hsl(<ring channels> / <soft alpha>)`.
// Nothing reads the sheet yet; it changes no page.
//
// The names
//   UI SDK's colours (the names its stylesheet reads):
//     --ui-background, --ui-foreground, --ui-muted, --ui-muted-foreground,
//     --ui-border, --ui-input, --ui-ring, --ui-ring-border, --ui-primary,
//     --ui-primary-foreground, --ui-destructive
//   BarkUI's own:
//     --bark-accent    the brand as readable text
//     --bark-selected  a selected fill, one step past muted
//   Tones, one set per tone in success, warning, danger, info:
//     --bark-<tone>             the tone itself (a dot, an icon, a solid fill)
//     --bark-<tone>-foreground  text on a solid --bark-<tone> fill
//     --bark-<tone>-text        the tone as text on the ground or on its -soft fill
//     --bark-<tone>-soft        a soft fill for a control labelled in -text
//   The scheme follows UI SDK: `X-foreground` is what is drawn on an `X` fill.
//   Barkpark's own role names (ok, warn) become success and warning.
//
// The surface and depth axes (the BarkUI base's names and semantics)
//   Five surfaces, base, raised, sunken, primary and inverse, each carry every
//   role above, as --bark-<surface>-<role> (--ui-destructive as
//   --bark-<surface>-destructive);
//   each also has five depth grounds, --bark-<surface>-depth-<m2|m1|1|2|3>.
//   design/emit/barkui-surfaces.mjs says where each value comes from. Base is
//   the name table below.
//
// The rules
//   Each skin is one rule, `[data-skin="<name>"], [data-bp-theme="<name>"]`,
//   that writes every --bark-<surface>-* value once as
//   `light-dark(<light>, <dark>)`. The base arms are the Studio region's strings
//   for that slot in each mode. The build refuses an arm that is not an hsl()
//   colour, naming the skin, surface, role and mode. The default skin also takes `:root`, so a page
//   with no skin attribute draws it.
//   The axis rules point the names parts read at one surface:
//     :root, [data-skin], [data-bp-theme], [data-surface="base"] -> base
//     [data-surface="raised" | "sunken" | "primary" | "inverse"]  -> that surface
//     [data-depth="-2" | "-1" | "1" | "2" | "3"] -> --ui-background moves to that
//       depth of the current surface
//   A surface nests inside skin, scheme and another surface. A skin element
//   starts its subtree on its own base surface, as in the BarkUI base. Paint
//   rules in :where() give data-skin, surface and depth elements their ground,
//   text and edge colour (not data-bp-theme, which Studio pages carry today and
//   paint themselves), a sunken surface an inset 1px rim in --bark-sunken-rim
//   (written once per skin), and depth 1 to 3 the --ui-shadow; any app rule wins over
//   them. (The base gets the same effect from cascade layers; this sheet has no
//   layers.)
//   The scheme is a separate axis that only sets `color-scheme`:
//     :root, [data-color-scheme="system"]               -> light dark (the system setting)
//     [data-color-scheme="light"], [data-theme="light"] -> light
//     [data-color-scheme="dark"], [data-theme="dark"]   -> dark
//   `color-scheme` inherits and light-dark() resolves where a colour is used, so
//   a scheme on any ancestor reaches every skin below it, and a skin on any
//   element works under any scheme, with either naming or a mix. The scheme
//   rules come last so an explicit scheme on the root beats the root's default.
//   When one element carries both scheme attributes and they disagree, dark wins,
//   because the dark rule comes after the light one.

import { DEFAULT_THEME, loadThemes, themePalette } from "./source.mjs";
import { alpha, hsl, softAlpha, STATUS_ROLES } from "./vocab.mjs";
import { depthKey, DEPTHS, pointedName, SURFACE_ROLES, SURFACES, surfaceValues } from "./barkui-surfaces.mjs";

const TONE_NAMES = { ok: "success", warn: "warning", danger: "danger", info: "info" };

// [BarkUI name, source slot under tokens.color, "soft"?]. A slot is a dotted
// path; the value at `<slot>.<mode>` is an HSL channel string. "soft" writes it
// at the soft-tint alpha of that mode.
export const BARKUI_NAMES = [
  ["--ui-background", "bg"],
  ["--ui-foreground", "text"],
  ["--ui-muted", "muted-surface"],
  ["--ui-muted-foreground", "muted-text"],
  ["--ui-border", "border"],
  // The edge of anything a person operates (outlined button, text field,
  // select, checkbox), so it must stand at 3:1 on the ground (WCAG 1.4.11);
  // --ui-border stays the hairline for dividers and panel outlines. Studio's
  // field edge is the hairline (1.01 to 1.34:1), so the edge takes the nearest
  // slot that clears 3:1 on the base, raised and sunken grounds of every skin:
  // fg-dim, Studio's dim neutral (3.84 to 5.28:1), still far quieter than text.
  ["--ui-input", "studioChrome.fg-dim"],
  // UI SDK draws --ui-ring as a 4px solid halo around a focused control, pale
  // on the ground (its defaults: 1.30:1 light, 1.64:1 dark). The halo is the
  // ring at the soft-tint alpha, the --ring-soft the cloud and login regions
  // already write: 1.20 to 1.49:1 against --ui-background across the skins.
  ["--ui-ring", "ring", "soft"],
  // No 1:1 slot. UI SDK draws a focused control's edge in --ui-ring-border;
  // Barkpark draws its focused edges and outlines in --ring.
  ["--ui-ring-border", "ring"],
  ["--ui-primary", "primary"],
  ["--ui-primary-foreground", "primary-fg"],
  ["--ui-destructive", "status.danger"],
  // No 1:1 slot. Barkpark's own `accent` slot is a decorative amber, not the
  // brand; the brand as AA text is onTint.primary-text.
  ["--bark-accent", "onTint.primary-text"],
  // No 1:1 slot. Studio's bg-accent is the neutral fill one step past
  // muted-surface that it uses for hover and selected rows.
  ["--bark-selected", "studioChrome.bg-accent"],
  ...STATUS_ROLES.flatMap((role) => [
    [`--bark-${TONE_NAMES[role]}`, `status.${role}`],
    [`--bark-${TONE_NAMES[role]}-foreground`, `onStatus.${role}-fg`],
    [`--bark-${TONE_NAMES[role]}-text`, `onTint.${role}-text`],
  ]),
];

function slotValue(color, slot, mode, soft) {
  let node = color;
  for (const key of slot.split(".")) node = node?.[key];
  const v = node?.[mode];
  if (typeof v !== "string" || !/^[\d.]+ [\d.]+% [\d.]+%$/.test(v))
    throw new Error(`barkui: color.${slot}.${mode} is ${JSON.stringify(v)}, not HSL channels`);
  return soft ? `hsl(${v} / ${alpha(softAlpha[mode])})` : hsl(v);
}

const SKINS = (name) => [`[data-skin="${name}"]`, `[data-bp-theme="${name}"]`];

const ROLE_BY_NAME = new Map(SURFACE_ROLES.map((r) => [pointedName(r), r]));
for (const [n] of BARKUI_NAMES)
  if (!ROLE_BY_NAME.has(n)) throw new Error(`barkui: ${n} is in the name table but is no surface role`);
// The one colour form the sheet writes: hsl(H S% L%), optionally with an alpha.
const COLOUR = /^hsl\([\d.]+ [\d.]+% [\d.]+%(?: \/ [\d.]+)?\)$/;

function skinRule(name, spec) {
  const color = themePalette(spec).color;
  const selectors = [...(name === DEFAULT_THEME ? [":root"] : []), ...SKINS(name)];
  const perMode = (f) => ({ light: f("light"), dark: f("dark") });
  const base = perMode((mode) => Object.fromEntries(BARKUI_NAMES.map(([n, slot, soft]) => [ROLE_BY_NAME.get(n), slotValue(color, slot, mode, soft)])));
  let v;
  try {
    v = surfaceValues(base, perMode((m) => slotValue(color, "studioChrome.surface-raised", m)),
      perMode((m) => slotValue(color, "primary-fg", m, "soft")));
  } catch (e) {
    throw new Error(e.message.replace(/^barkui: /, `barkui: ${name}/`));
  }
  const pair = (s, key, pick) => {
    const arm = (mode) => {
      const c = pick(v[mode]);
      if (typeof c !== "string" || !COLOUR.test(c))
        throw new Error(`barkui: skin ${name}, surface ${s}, ${key}, ${mode}: ${JSON.stringify(c)} is not an hsl() colour`);
      return c;
    };
    return `  --bark-${s}-${key}: light-dark(${arm("light")}, ${arm("dark")});`;
  };
  const body = [
    ...SURFACES.flatMap((s) => [
      ...SURFACE_ROLES.map((r) => pair(s, r, (m) => m[s][r])),
      ...DEPTHS.map(depthKey).map((k) => pair(s, `depth-${k}`, (m) => m[s].depth[k])),
    ]),
    pair("sunken", "rim", (m) => m.sunken.rim),
  ];
  return `${selectors.join(",\n")} {\n${body.join("\n")}\n}`;
}

// The axes. One rule per surface points the names parts read at that surface;
// base is also the default on the root and on every skin element, so a skin set
// inside a surface starts its subtree on its own base, as in the BarkUI base.
// Each depth rule moves only the background, to the current surface's step.
// The paint rules give a data-skin, surface or depth element its ground, text
// and edge colour; they sit in :where() so any rule an app writes wins over them.
// data-bp-theme gets the variables but no paint: Studio pages carry it today
// and paint their own ground.
function axisRules() {
  const point = (s) => [
    ...SURFACE_ROLES.map((r) => `  ${pointedName(r)}: var(--bark-${s}-${r});`),
    ...DEPTHS.map(depthKey).map((k) => `  --bark-depth-${k}: var(--bark-${s}-depth-${k});`),
  ].join("\n");
  return [
    `:root,\n[data-skin],\n[data-bp-theme],\n[data-surface="base"] {\n${point("base")}\n}`,
    ...SURFACES.slice(1).map((s) => `[data-surface="${s}"] {\n${point(s)}\n}`),
    ...DEPTHS.map((n) => `[data-depth="${n}"] {\n  --ui-background: var(--bark-depth-${depthKey(n)});\n}`),
    ":where([data-skin], [data-surface], [data-depth]) {\n  background-color: var(--ui-background);\n  color: var(--ui-foreground);\n  border-color: var(--ui-border);\n}",
    ':where([data-surface="sunken"]) {\n  box-shadow: inset 0 0 0 1px var(--bark-sunken-rim);\n}',
    ':where([data-depth="1"], [data-depth="2"], [data-depth="3"]) {\n  box-shadow: var(--ui-shadow);\n}',
    // A sunken well with a depth keeps its rim (in dark its only marker) under
    // the depth shadow; with no --ui-shadow on the page the rim still draws.
    ':where([data-surface="sunken"][data-depth="1"], [data-surface="sunken"][data-depth="2"], [data-surface="sunken"][data-depth="3"]) {\n  box-shadow: inset 0 0 0 1px var(--bark-sunken-rim), var(--ui-shadow, 0 0 #0000);\n}',
  ];
}

const SCHEME_RULES = [
  ':root,\n[data-color-scheme="system"] {\n  color-scheme: light dark;\n}',
  '[data-color-scheme="light"],\n[data-theme="light"] {\n  color-scheme: light;\n}',
  '[data-color-scheme="dark"],\n[data-theme="dark"] {\n  color-scheme: dark;\n}',
];

// The whole file. loadThemes() puts the default skin first, so its :root rule
// comes before every other skin's and a skin attribute wins on equal specificity.
export function barkuiSheet(themes = loadThemes()) {
  return [
    "/* GENERATED by design/emit.mjs from design/themes/*.json (design/emit/barkui.mjs).",
    "   Do not edit; regenerate: node design/emit.mjs --write",
    "   Every skin under BarkUI's variable names (UI SDK's --ui-* plus --bark-*), each colour a light-dark() pair. */",
    ...themes.map(({ name, spec }) => skinRule(name, spec)),
    ...axisRules(),
    ...SCHEME_RULES,
    "",
  ].join("\n");
}
