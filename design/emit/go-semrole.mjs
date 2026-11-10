// design/emit/go-semrole.mjs — the Go semrole and CLI chrome surfaces.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { DEFAULT_THEME, loadThemes, themePalette, tokens } from "./source.mjs";
import { glyphOf, goAdaptive, hslToHex, INST_ORDER, instRoleChannels, LIFE_ORDER, PROVIDERS, STATUS_ROLES } from "./vocab.mjs";
import { alignEq, alignFields, alignMap, goHeader } from "./go-board.mjs";

// ── surface: Go semrole (internal/semrole/tokens_gen.go) ─────────────────────
// The CLI truecolor source (Decision 3): the four status roles as hex
// AdaptiveColors, the seven lifecycle glyph hues (done/closed stay TEAL, not
// ok-green — Decision 4), and a pinned ANSI-16 SGR floor per role that the
// wave-2 colour ladder degrades to. info → blue (34) is the visible
// cross-surface coherence fix. Additive — no consumer is rewired here.
const SEMROLE_TONES = [["OK", "ok"], ["Info", "info"], ["Warn", "warn"], ["Danger", "danger"]];
const SEMROLE_ANSI16 = { ok: 32, info: 34, warn: 33, danger: 31 }; // green/blue/yellow/red
const pascal = (s) => s.split("_").map((w) => w[0].toUpperCase() + w.slice(1)).join("");

function semroleGo(themes = loadThemes()) {
  const st = tokens.color.status;
  const life = tokens.lifecycle;
  const tone = (name, role) =>
    `\tGen${name} = lipgloss.AdaptiveColor{Light: "${hslToHex(st[role].light)}", Dark: "${hslToHex(st[role].dark)}"}`;
  const hue = (s) =>
    `\tGen${pascal(s)}Hue = lipgloss.AdaptiveColor{Light: "${life[s].color.light}", Dark: "${life[s].color.dark}"}`;
  // One genTones entry per committed theme. evergreen REFERENCES the Gen* maps
  // (byte-identical to today); a non-evergreen theme stamps its status + lifecycle
  // maps as literals from its skin (ANSI16 is a theme-invariant SGR floor).
  const tonesEntry = ({ name, spec }) => {
    if (name === DEFAULT_THEME)
      return [`\t${JSON.stringify(name)}: {StatusTone: GenStatusTone, LifecycleHue: GenLifecycleHue, ANSI16: GenANSI16},`];
    const p = themePalette(spec);
    const pst = p.color.status;
    const plife = p.lifecycle;
    return [
      `\t${JSON.stringify(name)}: {`,
      "\t\tStatusTone: map[string]lipgloss.AdaptiveColor{",
      ...alignMap(SEMROLE_TONES.map(([, role]) => `\t\t\t"${role}": ${goAdaptive(hslToHex(pst[role].light), hslToHex(pst[role].dark))},`)),
      "\t\t},",
      "\t\tLifecycleHue: map[string]lipgloss.AdaptiveColor{",
      ...alignMap(LIFE_ORDER.map((s) => `\t\t\t"${s}": ${goAdaptive(plife[s].color.light, plife[s].color.dark)},`)),
      "\t\t},",
      "\t\tANSI16: map[string]int{",
      ...alignMap(SEMROLE_TONES.map(([, role]) => `\t\t\t"${role}": ${SEMROLE_ANSI16[role]},`)),
      "\t\t},",
      "\t},",
    ];
  };
  return [
    goHeader("semrole"),
    'import "github.com/charmbracelet/lipgloss"',
    "",
    "// Generated semantic status tones (design/tokens.json color.status → hex).",
    "var (",
    ...alignEq(SEMROLE_TONES.map(([name, role]) => tone(name, role))),
    ")",
    "",
    "// Generated lifecycle glyph hues (design/tokens.json lifecycle.*.color).",
    "// done/closed stay TEAL — deliberately distinct from status.ok green.",
    "var (",
    ...alignEq(LIFE_ORDER.map(hue)),
    ")",
    "",
    "// GenStatusTone maps a semantic role to its adaptive tone.",
    "var GenStatusTone = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(SEMROLE_TONES.map(([name, role]) => `\t"${role}": Gen${name},`)),
    "}",
    "",
    "// GenLifecycleHue maps a lifecycle state to its adaptive glyph hue.",
    "var GenLifecycleHue = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(LIFE_ORDER.map((s) => `\t"${s}": Gen${pascal(s)}Hue,`)),
    "}",
    "",
    "// GenANSI16 pins each status role to its basic-16 SGR foreground code — the",
    "// floor the CLI colour ladder degrades to. info → blue (34) is the visible",
    "// cross-surface coherence fix.",
    "var GenANSI16 = map[string]int{",
    ...alignMap(SEMROLE_TONES.map(([, role]) => `\t"${role}": ${SEMROLE_ANSI16[role]},`)),
    "}",
    "",
    // ── theme resolution seam (ts-w4c) ──────────────────────────────────────
    "// DefaultTheme is the built-in evergreen skin every Resolve defaults to for an",
    "// unknown/empty theme id. Adding theme N+1 grows genTones (one keyed entry);",
    "// the RoleColorFor/LifecycleColorFor accessors already thread the id through.",
    `const DefaultTheme = ${JSON.stringify(DEFAULT_THEME)}`,
    "",
    "// ThemeTones bundles one theme's status + lifecycle + ANSI-16 token maps.",
    "type ThemeTones struct {",
    ...alignFields([
      "\tStatusTone map[string]lipgloss.AdaptiveColor",
      "\tLifecycleHue map[string]lipgloss.AdaptiveColor",
      "\tANSI16 map[string]int",
    ]),
    "}",
    "",
    "// genTones keys each theme's tones by id. The evergreen entry REFERENCES the",
    "// Gen* maps above (no re-typed literals) so it is byte-identical to them.",
    "var genTones = map[string]ThemeTones{",
    ...themes.flatMap(tonesEntry),
    "}",
    "",
    "// Resolve returns a theme's status/lifecycle/ANSI-16 token set, defaulting to",
    "// evergreen for an unknown or empty id.",
    "func Resolve(theme string) ThemeTones {",
    "\tif t, ok := genTones[theme]; ok {",
    "\t\treturn t",
    "\t}",
    "\treturn genTones[DefaultTheme]",
    "}",
    "",
    "// Themes lists every generated theme id in dir order (evergreen first). bp style",
    "// and the styleguide showroom enumerate it to iterate skins; it grows by exactly",
    "// one id when theme N+1 ships its file.",
    `func Themes() []string { return []string{${themes.map((t) => JSON.stringify(t.name)).join(", ")}} }`,
    "",
  ].join("\n");
}

// ── surface: Go CLI chrome (internal/semrole/chrome_gen.go) ──────────────────
// The ratified CLI/TUI chrome role set as hex AdaptiveColors, emitted into a
// SIBLING file (NOT tokens_gen.go) so the status/lifecycle artifact stays
// byte-stable and the #1394 board-parity risk is isolated. Nine NEW roles carry
// {light,dark} HEX directly (color.cliChrome[role] = {light,dark}); five REUSE
// roles are 'var(--role)' references RESOLVED here to the target role's hex —
// chrome-primary-cta → evergreen --primary (RECOLOR off the legacy #2563eb
// blue), chrome-on-primary → adaptive --primary-fg. Additive: the 27 call sites
// keep their lit-allows; a later wave threads GenChrome* through them.
const CLI_CHROME_NEW = [
  ["Accent", "chrome-accent"], ["Dim", "chrome-dim"], ["Ink", "chrome-ink"],
  ["TextSecondary", "chrome-text-secondary"], ["SelectionBg", "chrome-selection-bg"],
  ["SelectionFg", "chrome-selection-fg"], ["FieldBorder", "chrome-field-border"],
  ["ToolbarBg", "chrome-toolbar-bg"], ["CursorBg", "chrome-cursor-bg"],
];
const CLI_CHROME_REUSE = [
  ["Border", "chrome-border"], ["BorderActive", "chrome-border-active"],
  ["Label", "chrome-label"], ["PrimaryCta", "chrome-primary-cta"],
  ["OnPrimary", "chrome-on-primary"],
];
// Resolve a 'var(--role)' reference to its {light,dark} HSL channels. Status
// roles live under color.status (var(--info) → color.status.info); base roles
// sit directly on color.*.
function resolveChromeRef(ref, t = tokens) {
  const role = ref.replace(/^var\(--/, "").replace(/\)$/, "");
  return STATUS_ROLES.includes(role) ? t.color.status[role] : t.color[role];
}
// {light,dark} hex for a cliChrome role in palette `t` (default: base tokens →
// byte-identical evergreen). NEW roles are hex already; REUSE roles resolve their
// reference to HSL channels then convert to hex — the whole family re-tints when
// a non-evergreen skin moves --primary / the status roles it points at.
function cliChromeHex(role, t = tokens) {
  const v = t.color.cliChrome[role];
  if (typeof v === "string") { const ch = resolveChromeRef(v, t); return { light: hslToHex(ch.light), dark: hslToHex(ch.dark) }; }
  return { light: v.light, dark: v.dark };
}
function cliChromeGo(themes = loadThemes()) {
  const line = (name, role) => {
    const h = cliChromeHex(role);
    return `\tGenChrome${name} = lipgloss.AdaptiveColor{Light: "${h.light}", Dark: "${h.dark}"}`;
  };
  const all = [...CLI_CHROME_NEW, ...CLI_CHROME_REUSE];
  // One genChrome entry per committed theme. evergreen REFERENCES GenChrome
  // (byte-identical); a non-evergreen theme stamps the whole role map as literals
  // resolved against its own skin (REUSE roles re-tint with --primary / status).
  const chromeEntry = ({ name, spec }) => {
    if (name === DEFAULT_THEME)
      return [`\t${JSON.stringify(name)}: {Chrome: GenChrome},`];
    const p = themePalette(spec);
    return [
      `\t${JSON.stringify(name)}: {Chrome: map[string]lipgloss.AdaptiveColor{`,
      ...alignMap(all.map(([, role]) => { const h = cliChromeHex(role, p); return `\t\t"${role}": ${goAdaptive(h.light, h.dark)},`; })),
      "\t}},",
    ];
  };
  // Cloud-console families (charter azure-hetzner Decision 7), emitted into the
  // SAME sibling (chrome_gen.go) so tokens_gen.go stays byte-stable. Provider
  // IDENTITY marks (hex) + the instance-lifecycle glyph/role/hue map. An
  // instance state's Hue is its status-role tone resolved to hex (role "" →
  // muted-text neutral) — colour is read THROUGH the role, never bespoke.
  const il = tokens.instanceLifecycle;
  const provRows = PROVIDERS.map(
    (k) => `\t"${k}": {Light: "${tokens.color.provider[k].light}", Dark: "${tokens.color.provider[k].dark}"},`,
  );
  const instRows = INST_ORDER.map((s) => {
    const e = il[s];
    const ch = instRoleChannels(e.role);
    return `\t"${s}": {Glyph: "${glyphOf(e.codepoint)}", ASCIIGlyph: ${JSON.stringify(e.asciiGlyph)}, Role: ${JSON.stringify(e.role)}, HueLight: "${hslToHex(ch.light)}", HueDark: "${hslToHex(ch.dark)}"},`;
  });
  return [
    goHeader("semrole"),
    'import "github.com/charmbracelet/lipgloss"',
    "",
    "// Generated CLI/TUI chrome roles (design/tokens.json color.cliChrome → hex).",
    "// Nine NEW hex roles + five REUSE references resolved to their target role's",
    "// hex (chrome-primary-cta = evergreen --primary; chrome-on-primary = --primary-fg).",
    "var (",
    ...alignEq(all.map(([name, role]) => line(name, role))),
    ")",
    "",
    "// GenChrome maps a cliChrome role name to its adaptive colour.",
    "var GenChrome = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(all.map(([name, role]) => `\t"${role}": GenChrome${name},`)),
    "}",
    "",
    // ── theme resolution seam (ts-w4c) ──────────────────────────────────────
    "// ThemeChrome bundles one theme's CLI/TUI chrome role map. Keyed off the same",
    "// DefaultTheme const (tokens_gen.go); ResolveChrome defaults to evergreen for an",
    "// unknown/empty id so ChromeColorFor never returns a partial palette.",
    "type ThemeChrome struct {",
    "\tChrome map[string]lipgloss.AdaptiveColor",
    "}",
    "",
    "// genChrome keys each theme's chrome map by id (evergreen REFERENCES GenChrome).",
    "var genChrome = map[string]ThemeChrome{",
    ...themes.flatMap(chromeEntry),
    "}",
    "",
    "// ResolveChrome returns a theme's chrome role map, defaulting to evergreen.",
    "func ResolveChrome(theme string) ThemeChrome {",
    "\tif c, ok := genChrome[theme]; ok {",
    "\t\treturn c",
    "\t}",
    "\treturn genChrome[DefaultTheme]",
    "}",
    "",
    "// GenProviderMark is the generated cloud-provider IDENTITY palette",
    "// (design/tokens.json color.provider → hex). Identity ONLY (Decision 7):",
    "// tint a chip mark or a chip/row border, NEVER a pill background — the",
    "// status roles stay the only state voice. Unconsumed until a later wave",
    "// threads it through the CLI provider-chip / table renderers.",
    "var GenProviderMark = map[string]lipgloss.AdaptiveColor{",
    ...alignMap(provRows),
    "}",
    "",
    "// GenInstanceLifecycleToken mirrors one design/tokens.json instanceLifecycle",
    "// state. Hue is the state's status-role tone resolved to hex (role \"\" → the",
    "// muted-text neutral); the CLI reads colour THROUGH the role, never a bespoke",
    "// per-state hue (Decision 7).",
    "type GenInstanceLifecycleToken struct {",
    "\tGlyph      string",
    "\tASCIIGlyph string",
    "\tRole       string",
    "\tHueLight   string",
    "\tHueDark    string",
    "}",
    "",
    "// GenInstanceLifecycle is the generated 1:1 mirror of tokens.instanceLifecycle",
    "// (glyph + role + role-derived hue).",
    "var GenInstanceLifecycle = map[string]GenInstanceLifecycleToken{",
    ...alignMap(instRows),
    "}",
    "",
    "// GenInstanceLifecycleOrder is the canonical emission order (matches source).",
    `var GenInstanceLifecycleOrder = []string{${INST_ORDER.map((s) => `"${s}"`).join(", ")}}`,
    "",
  ].join("\n");
}

export { cliChromeGo, semroleGo };
