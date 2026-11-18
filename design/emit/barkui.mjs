// design/emit/barkui.mjs — the BarkUI sheet: today's skins under UI SDK's variable names.
// Part of design/emit.mjs, which registers it as a whole generated file.
//
// BarkUI, the shared UI foundation, reads UI SDK's `--ui-*` colour names plus a
// few `--bark-*` names of its own. This module writes every skin in
// design/themes/ under those names, for light and dark, from the same derived
// slots the other surfaces read. Each value is the exact string the Studio
// region writes for its source slot (`hsl(<channels>)`), so the two cannot drift.
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
//     --bark-<tone>-text        the tone as text on the ground or its own soft tint
//   The scheme follows UI SDK: `X-foreground` is what is drawn on an `X` fill.
//   Barkpark's own role names (ok, warn) become success and warning.
//
// The rules
//   Each skin is one rule, `[data-skin="<name>"], [data-bp-theme="<name>"]`,
//   that writes every colour once as `light-dark(<light>, <dark>)`. The two arms
//   are the Studio region's strings for that slot in each mode. The default skin
//   also takes `:root`, so a page with no skin attribute draws it.
//   The scheme is a separate axis that only sets `color-scheme`:
//     :root, [data-color-scheme="system"]               -> light dark (the system setting)
//     [data-color-scheme="light"], [data-theme="light"] -> light
//     [data-color-scheme="dark"], [data-theme="dark"]   -> dark
//   `color-scheme` inherits and light-dark() resolves where a colour is used, so
//   a scheme on any ancestor reaches every skin below it, and a skin on any
//   element works under any scheme, with either naming or a mix. The scheme
//   rules come last so an explicit scheme on the root beats the root's default.

import { DEFAULT_THEME, loadThemes, themePalette } from "./source.mjs";
import { hsl, STATUS_ROLES } from "./vocab.mjs";

const TONE_NAMES = { ok: "success", warn: "warning", danger: "danger", info: "info" };

// [BarkUI name, source slot under tokens.color]. A slot is a dotted path; the
// value at `<slot>.<mode>` is an HSL channel string.
export const BARKUI_NAMES = [
  ["--ui-background", "bg"],
  ["--ui-foreground", "text"],
  ["--ui-muted", "muted-surface"],
  ["--ui-muted-foreground", "muted-text"],
  ["--ui-border", "border"],
  // No 1:1 slot. Barkpark draws control edges with --border (as shadcn, whose
  // --input equals --border), so the input edge takes the border slot.
  ["--ui-input", "border"],
  ["--ui-ring", "ring"],
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

function slotValue(color, slot, mode) {
  let node = color;
  for (const key of slot.split(".")) node = node?.[key];
  const v = node?.[mode];
  if (typeof v !== "string" || !/^[\d.]+ [\d.]+% [\d.]+%$/.test(v))
    throw new Error(`barkui: color.${slot}.${mode} is ${JSON.stringify(v)}, not HSL channels`);
  return hsl(v);
}

const SKINS = (name) => [`[data-skin="${name}"]`, `[data-bp-theme="${name}"]`];

function skinRule(name, spec) {
  const color = themePalette(spec).color;
  const selectors = [...(name === DEFAULT_THEME ? [":root"] : []), ...SKINS(name)];
  const body = BARKUI_NAMES.map(([v, slot]) =>
    `  ${v}: light-dark(${slotValue(color, slot, "light")}, ${slotValue(color, slot, "dark")});`);
  return `${selectors.join(",\n")} {\n${body.join("\n")}\n}`;
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
    ...SCHEME_RULES,
    "",
  ].join("\n");
}
