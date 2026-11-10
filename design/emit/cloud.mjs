// design/emit/cloud.mjs — the Cloud SPA surface (app.css) and the styleguide swatch grid.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { loadThemes, THEME_BANNER, themeBlocks, tokens } from "./source.mjs";
import { alpha, hslToHex, INST_ORDER, INST_ROLE_CSS, MOTION_STEPS, motionVarLines, PROVIDERS, softAlpha } from "./vocab.mjs";

// ── surface: Cloud SPA (cloud/priv/static/app.css) ──────────────────────────
// Full base + status contract. Values mirror the committed :root today; this is
// a check-against-committed surface (the generated block is additive and the
// hand-authored :root that follows keeps the live values).
//
// PLUS the cloud-console families (charter azure-hetzner Decision 7): the
// provider IDENTITY tints as --provider-<kind> custom properties (per-theme
// hex), and the instance-lifecycle glyph-tone classes .bp-inst--<state> whose
// colour is READ THROUGH the state's status role (var(--ok/--warn/--danger/
// --info/--muted-text)) — identity never a state voice. Additive: no consumer
// is rewired this slice (statusPill/bucketOf + CLI table renderers land later).
function providerVars(theme, indent) {
  const p = tokens.color.provider;
  return PROVIDERS.map((k) => indent + `--provider-${k}: ${p[k][theme]};`).join("\n");
}

// ── cloudChrome shell vocabulary (GUI-remake GR2) ────────────────────────────
// The designer v4 shell's chrome roles, emitted --cc-<role> into the cloud SPA's
// bare :root / [data-theme=dark] ONLY (identity-INVARIANT passthrough — the v4
// applyTheme() only ever moves the 5 accent vars). check.mjs Part G D25 bans
// --cc-* from every [data-bp-theme] identity block, so this NEVER runs there.
// GR29 dead-var retirement (gr-p3-hygiene-guard): 11 zero-consumer roles removed
// at the SOURCE — azure, backdrop, blue-hover, cloudflare, fg5, github, hetzner,
// on-red, spark-dim, toast, toast-fg (all R2-dead, 0 var() consumers). Regenerate
// the app.css block with `node design/emit.mjs --write` — never hand-edit it.
export const CC_ROLES = [
  "bg", "bg-side", "card", "card2", "modal",
  "fg", "fg2", "fg3", "fg4", "line-rgb",
  "red", "red-strong", "blue", "amber",
];
function cloudChromeVars(theme, indent) {
  const cc = tokens.color.cloudChrome;
  return CC_ROLES.map((r) => indent + `--cc-${r}: ${cc[r][theme]};`).join("\n");
}

// ── GR7 legacy alias bridge ──────────────────────────────────────────────────
// One generated move retints the 123KB hand CSS: the ~consumed legacy shell vars
// map role-for-role onto the designer ladder (GR6 rulings). Identity-INVARIANT,
// so bare :root / [data-theme=dark] only. --dim→fg3 (NEVER fg4: fg4-as-text fails
// 4.5:1 at 3.96/3.41 — fg4 is a meta-only token duty-capped at 3:1). --border is
// a line-rgb/alpha judgment. --primary-hover is RETIRED (0 consumers, proven dead)
// — deliberately absent here. --accent is RETIRED too (GUI-remake GR7 endgame,
// gr-p3-site-detail): its sole consumer (.previews .deploy-row.preview-row
// border) now reads --cc-amber directly — the identical bytes the alias resolved
// to — so the decorative-amber alias carries zero consumers and dies.
function aliasBridge(theme, indent) {
  const borderAlpha = theme === "light" ? "0.12" : "0.14";
  const lines = [
    `--bg: var(--cc-bg);`,
    `--surface: var(--cc-card);`,
    `--muted-surface: var(--cc-card2);`,
    `--text: var(--cc-fg);`,
    `--muted-text: var(--cc-fg2);`,
    `--dim: var(--cc-fg3);`,
    `--border: rgba(var(--cc-line-rgb), ${borderAlpha});`,
  ];
  return lines.map((l) => indent + l).join("\n");
}

// ── cloud status text-voices (GR6) ───────────────────────────────────────────
// warn/danger/info -hsl channels drive the -soft PILL tints (status-hue machinery
// preserved); the TEXT voices ride the designer ramp: --danger→red-strong,
// --info→blue. --warn keeps the status amber (dot/glyph); its -strong TEXT voice
// is a SOLID tuned tone (GR6: light #7d5500 4.10→5.44; dark the light amber that
// reads on the dark pill) — NOT the translucent status tint that failed every
// ramp state at 1.35–2.07:1. Identity-INVARIANT: bare :root / [data-theme=dark].
const WARN_STRONG_SOLID = { light: "#7d5500", dark: "#e8b45a" };
// --danger is red TEXT on a red -soft tint: light = dark-on-light → the DARKER
// red-strong (#b23636, GR6 tuned; designer base #bb4040 fails at 4.31); dark =
// light-on-dark → the LIGHTER plain red (#e57f7f) clears 4.5 where red-strong
// #e56a6a lands at 4.48. Strong-per-direction, both the designer's danger red.
const DANGER_TEXT = { light: "var(--cc-red-strong)", dark: "var(--cc-red)" };
function cloudStatusVars(theme, indent) {
  const st = tokens.color.status;
  const a = alpha(softAlpha[theme]);
  const lines = [
    `--warn-hsl: ${st.warn[theme]}; --danger-hsl: ${st.danger[theme]}; --info-hsl: ${st.info[theme]};`,
    `--warn: hsl(var(--warn-hsl)); --danger: ${DANGER_TEXT[theme]}; --info: var(--cc-blue);`,
    `--warn-soft: hsl(var(--warn-hsl) / ${a}); --danger-soft: hsl(var(--danger-hsl) / ${a}); --info-soft: hsl(var(--info-hsl) / ${a});`,
    `--warn-strong: ${WARN_STRONG_SOLID[theme]};`,
  ];
  return lines.map((l) => indent + l).join("\n");
}

// ── cloud accent block (the BRAND, and only the brand) ───────────────────────
// The per-identity tuple: --primary + its -hsl machinery, the brand ring and the
// ring's soft tint. Emitted in the bare :root (evergreen fallback) AND inside
// each [data-bp-theme] block — the ONLY per-identity vars.
// GR6's "green IS the accent" line has been REVERSED here: the --ok family used
// to live in this function and therefore repainted every success/health surface
// with the brand hue. It now lives in cloudOkVars() below, called only from the
// identity-INVARIANT :root/[data-theme="dark"] pair. See that function's header
// for the measurement (24 screens, 2760 shots) that overturned the ruling.
// Carries NO --cc-* and NO shell roles (D25 / GR2). primary/primary-fg/ring are
// HSL channel strings in tokens.
function cloudAccentVars(theme, indent, t = tokens) {
  const a = alpha(softAlpha[theme]);
  const p = t.color.primary[theme];
  const lines = [
    `--primary: hsl(${p});`,
    `--primary-fg: hsl(${t.color["primary-fg"][theme]});`,
    `--ring: hsl(${t.color.ring[theme]});`,
    `--primary-hsl: ${p};`,
    // --primary-soft UN-RETIRED (cch DEFECT-A). GR22 retired it because its sole
    // consumer, the .size-opt selected tint, could read --ok-soft for the
    // identical channel/alpha while --ok TRACKED accent.primary (GR6). Breaking
    // that binding below breaks GR22's premise with it: --ok-soft is now a green
    // wash, and a SELECTED size is a brand state, not a success state, so it
    // would have rendered a green fill inside an ember border. The token comes
    // back with the consumer it always had. The Studio surface's primaryVars copy
    // is untouched (root.html.heex still consumes it).
    // --ring-hsl/--ring-soft PROMOTED (gr-p5r7-ring-soft-accent-invariant): the
    // focus ring's soft tint was hand-stamped TWICE outside the generated region
    // (evergreen green in both modes), so :focus-visible stayed green under
    // ember/fjord/charple/iris. It now rides the identity's OWN ring channel —
    // the same channel --ring already reads — through the shared softAlpha
    // convention, exactly as the login surface derives it in authRows().
    `--ring-hsl: ${t.color.ring[theme]};`,
    `--ring-soft: hsl(var(--ring-hsl) / ${a});`,
    `--primary-soft: hsl(var(--primary-hsl) / ${a});`,
  ];
  return lines.map((l) => indent + l).join("\n");
}

// ── the SUCCESS voice, identity-INVARIANT (cch DEFECT-A) ─────────────────────
// OVERTURNS GR6's "green = the accent primary (no standalone green)" and GR90's
// "--ok-hsl is NOT touched (it must keep tracking the brand)" FOR THE CLOUD SPA.
// THE MEASUREMENT that overturns them: gr-backlog-accent-matrix-rereview
// (console-w10, 2026-09-20, 2760 shots, 138 scenarios reviewed by eye at five
// accents) found 24 screens where a HEALTHY state and a FAILED state read as one
// warm hue at ember — because `--ok-hsl: ${p}` above made every success badge,
// tick, meter, deploy rail and summary chip wear accent.primary, while --danger
// stayed the designer red. "Good" and "bad" are the one pair a console may never
// collapse, and a brand that repaints health is a brand that can erase the
// distinction by changing its own hue.
// THE VALUE IS NOT NEW: design/tokens.json has carried color.status.ok
// ("142 72% 26%" / "142 52% 52%") since the token file existed — GR6 shadowed it
// rather than deleting it. This restores the token file's own answer.
// EMITTED HERE, NOT IN cloudStatusVars, so the four declarations keep their
// source position in app.css (after the accent 5-tuple) and the diff is the four
// values only. It is called ONLY from the bare :root / [data-theme="dark"] pair,
// never from cloudThemeBlock — which is exactly what "does not vary with
// [data-bp-theme]" means, and what E20 in __css_check.mjs now proves.
// --ok-strong is the text-on-tint voice; it follows the primary-hover convention
// (darker in light, lighter in dark) applied to the SEMANTIC hue, not the brand's.
const OK_STRONG_L_SHIFT = { light: -6, dark: +8 };
function okStrongTriplet(theme) {
  const [h, sat, lit] = tokens.color.status.ok[theme].trim().split(/\s+/);
  const l = Math.round((parseFloat(lit) + OK_STRONG_L_SHIFT[theme]) * 100) / 100;
  return `${h} ${sat} ${l}%`;
}
function cloudOkVars(theme, indent) {
  const a = alpha(softAlpha[theme]);
  const ok = tokens.color.status.ok[theme];
  const lines = [
    `--ok-hsl: ${ok};`,
    `--ok: hsl(var(--ok-hsl));`,
    `--ok-soft: hsl(var(--ok-hsl) / ${a});`,
    `--ok-strong: hsl(${okStrongTriplet(theme)});`,
  ];
  return lines.map((l) => indent + l).join("\n");
}
function instClasses() {
  const il = tokens.instanceLifecycle;
  return INST_ORDER
    .map((s) => `.bp-inst--${s} { color: var(${INST_ROLE_CSS[il[s].role]}); }`)
    .join("\n");
}
// Cloud theme block: base + primary + status re-declared under the theme
// attribute (light on html[data-bp-theme=X], dark on the +[data-theme=dark]
// compound — equal-idiom to the bare :root/[data-theme=dark] pair, one step more
// specific so the theme wins). Provider tints + .bp-inst-- glyph tones are
// theme-INVARIANT passthrough (Part D counts them positionally) — NOT here (D25).
// Identity block: ONLY the per-identity accent 5-tuple (GR2 — the shell
// vocabulary + status pill machinery are identity-INVARIANT, declared once in the
// bare :root above). Light and dark scopes carry the SAME var set (Part G D26
// tone-pair nesting). No --cc-* / no shell roles reach here (D25).
const cloudThemeBlock = (name, t) => [
  `html[data-bp-theme="${name}"] {`,
  cloudAccentVars("light", "  ", t),
  "}",
  `html[data-bp-theme="${name}"][data-theme="dark"] {`,
  cloudAccentVars("dark", "  ", t),
  "}",
].join("\n");

// The cloud SPA's decision-29 MOTION area (cch-app-css-motion). Three rungs from
// tokens.motion via motionVarLines(), then two cloud-local companions:
//   --ease  is tokens.motion.ease VERBATIM (a token; the schema requires it).
//   --t     is `var(--dur-1) var(--ease)` — the SPA's transition shorthand, spent
//           by ~26 rules. Not a token and not a new value: it is a pure function
//           of the two lines above it, which is why it belongs beside them rather
//           than hand-authored 100 lines downstream where the two could drift.
// Theme-INVARIANT, so this goes on the bare :root only — never inside
// [data-theme="dark"] or a [data-bp-theme] block (D25, the motionVars rule).
function cloudMotionVars(indent, t = tokens) {
  return [
    ...motionVarLines(t),
    `--ease: ${t.motion.ease};`,
    "--t: var(--dur-1) var(--ease);",
  ].map((l) => indent + l).join("\n");
}

// The reduced-motion collapse, GENERATED with the ladder rather than left beside
// it. Two reasons, in order of weight:
//   1. It is DERIVED from MOTION_STEPS, so a fourth rung added to tokens.json is
//      zeroed automatically. The hand block listed three rungs by name; adding
//      dur-4 would have shipped a rung that ignores the user's setting, silently.
//   2. It is emitted LAST in the region — after the theme blocks — so it wins the
//      cascade over every declaration this emitter writes, which is the property
//      that makes it a collapse rather than one more shadow.
// `0s` is written literally, not as `0${t.motion._unit}`: check.mjs Part N's
// exactly-once arm exempts a re-declaration by the exact VALUE "0s" (that is what
// keeps the exemption from being stretched to cover a literal that paints), so the
// byte the gate recognises is the byte we emit. Zero is zero in any time unit.
// --t needs no entry: var() inside a custom property substitutes at computed-value
// time on the element that DECLARES it, so --t recomputes to `0s ease` on :root.
// Spinner keyframes keep their literal durations on purpose — a progress
// indicator is state, not decoration.
function cloudReducedMotion() {
  return [
    "/* Motion collapses when the user asks for it (decision 29). Only the token",
    "   durations go to 0 — spinner keyframes keep their literal duration because",
    "   a progress indicator is state, not decoration. --t follows for free. */",
    "@media (prefers-reduced-motion: reduce) {",
    "  :root {",
    ...MOTION_STEPS.map((k) => `    --${k}: 0s;`),
    "  }",
    "}",
  ].join("\n");
}

function cloudBlock(themes = loadThemes()) {
  const lines = [
    ":root {",
    cloudChromeVars("light", "  "),
    aliasBridge("light", "  "),
    cloudStatusVars("light", "  "),
    cloudAccentVars("light", "  "),
    cloudOkVars("light", "  "),
    providerVars("light", "  "),
    "  /* Motion (decision 29) — durations + easing + the --t shorthand. Theme-",
    "     invariant, so :root only; the reduced-motion collapse is at the end of",
    "     this region. */",
    cloudMotionVars("  "),
    "}",
    '[data-theme="dark"] {',
    cloudChromeVars("dark", "  "),
    aliasBridge("dark", "  "),
    cloudStatusVars("dark", "  "),
    cloudAccentVars("dark", "  "),
    cloudOkVars("dark", "  "),
    providerVars("dark", "  "),
    "}",
    "/* instance-lifecycle glyph tones — colour READ THROUGH the state's status",
    "   role (Decision 7: identity is never a state voice); theme-invariant since",
    "   the referenced role var flips per theme. A later wave rewires statusPill/",
    "   bucketOf onto these. */",
    instClasses(),
  ];
  const themed = themeBlocks(themes, cloudThemeBlock);
  if (themed) lines.push(THEME_BANNER, themed);
  // LAST in the region on purpose — see cloudReducedMotion()'s note.
  lines.push(cloudReducedMotion());
  return lines.join("\n");
}

// ── surface: living styleguide swatch grid (cloud/priv/static/styleguide.html) ─
// The agency spec's "01 · Tokens" swatch table, byte-spliced into styleguide.html
// so a chip label can never drift from design/tokens.json. Each cell renders its
// CSS var LIVE (background: var(--cc-*)/var(--primary)) — the styleguide clones
// each pane into a light and a dark scope, so the chip resolves per theme — while
// the value line is the CANONICAL tokens.json truth (light · dark). The 11 slots
// mirror the agency's own list: the cloudChrome passthrough family (identity-
// invariant, so one light+dark pair each — GR2) plus the accent slot --primary
// (per-identity; the evergreen value is shown, labelled). An HTML-comment marker
// (kind "html") is the splice target, mirroring the CSS surfaces' BEGIN/END block.
const SWATCH_TOKENS = [
  { css: "--cc-bg", cc: "bg" },
  { css: "--cc-card", cc: "card" },
  { css: "--cc-card2", cc: "card2" },
  { css: "--cc-fg", cc: "fg" },
  { css: "--cc-fg2", cc: "fg2" },
  { css: "--cc-fg3", cc: "fg3" },
  { css: "--cc-fg4", cc: "fg4" },
  { css: "--primary", accent: true }, // the mint/evergreen accent (restyles per identity)
  { css: "--cc-amber", cc: "amber" },
  { css: "--cc-red", cc: "red" },
  { css: "--cc-blue", cc: "blue" },
];

function styleguideSwatches() {
  const cc = tokens.color.cloudChrome;
  const cell = (css, light, dark) =>
    [
      `              <div class="sg-swatch">`,
      `                <div class="sg-swatch-chip" style="background: var(${css});"></div>`,
      `                <div class="sg-swatch-meta">`,
      `                  <div class="sg-swatch-name">${css}</div>`,
      `                  <div class="sg-swatch-val">${light} · ${dark}</div>`,
      `                </div>`,
      `              </div>`,
    ].join("\n");
  return SWATCH_TOKENS.map((s) => {
    if (s.accent) {
      const p = tokens.color.primary;
      return cell(s.css, hslToHex(p.light), hslToHex(p.dark));
    }
    return cell(s.css, cc[s.cc].light, cc[s.cc].dark);
  }).join("\n");
}

export { cloudBlock, styleguideSwatches };
