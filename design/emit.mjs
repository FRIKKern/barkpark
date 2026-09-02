#!/usr/bin/env node
// design/emit.mjs — the W1.2 emitter. design/tokens.json is the ONE source of the
// Barkpark Unified Aesthetic; this regenerates EVERY per-surface artifact from it.
// Dependency-free (Node built-ins only), deterministic output. Trusts
// design/validate.mjs to have proven the source well-formed.
//
//   node design/emit.mjs            # default: report drift, write nothing (== --check)
//   node design/emit.mjs --check    # same as default
//   node design/emit.mjs --write    # rewrite every artifact in place
//   node design/emit.mjs --write --force   # rewrite even where content is UNATTRIBUTED
//   node design/emit.mjs --adopt    # bless what is on disk as generated; write nothing
//
// THE WRITE FENCE (charter D21). `--write` used to replace a generated region
// unconditionally, so any hand-written line a developer had put INSIDE the marker
// vanished with no diff, no warning, and no log line naming it — and check.mjs
// then printed a clean PASS, because it compares build() against a file build()
// had just written (a tautology: `current` IS `expected` by construction). That is
// not hypothetical: commit 1d928b3bf deleted 33 hand-written `.bp-lc-*` rules this
// way. The fix lives HERE, at the point of loss, because evaluate() already knows
// `current` and `expected` in the same pass and therefore already knows the delta
// BEFORE writeFileSync — it costs zero new I/O and no external dependency.
//
// The missing ingredient is MEMORY: nothing on disk records what the emitter last
// produced, so a region full of hand-written CSS is indistinguishable from a
// region that is merely stale. design/emit-manifest.json supplies it (the
// side-channel-attribution pattern design/status-manifest.json already
// establishes next door): one SHA-256 per artifact over the GENERATED REGION ONLY,
// rewritten by every successful --write. A region whose digest matches is
// attributable to a prior generation and is safe to replace; a region whose digest
// does not match holds bytes this emitter never wrote, and replacing it destroys
// them. The fence refuses that write, names every line it would have deleted, and
// exits non-zero. `--force` performs it anyway, `--adopt` re-blesses the tree.
//
// THE LEDGER KEY IS `<path>#<artifact name>`, NOT the path alone. One file may
// carry TWO generated regions (the registry below explicitly invites it via
// markerBegin/markerEnd — the cloud SPA's app.js is the first case), and a ledger
// keyed by path alone gives both regions ONE slot: last write wins, the loser
// reads "unattributed" forever, check.mjs reds permanently and --write refuses
// all-or-nothing. The chosen shape is the flat composite `${path}#${name}` (over a
// nested {path: {name: digest}}) because it keeps the manifest one sorted level
// deep — greppable, and a stale entry is one visibly deleted line. The artifact
// `name` is the same string the CLI prints, so a manifest line names the surface a
// refusal names. A unit with NO name (check.mjs' Part I synthetic fixtures, which
// exercise attribute() on invented paths) keys by the bare path.
//
// CSS surfaces are spliced into a BEGIN/END GENERATED: tokens marker block that
// must already exist (mirrors the status-tones precedent). Go surfaces are whole
// generated *_gen.go files. check.mjs imports the builders here for the drift gate
// and the §6 cross-surface parity assertion.
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { evaluateMirror } from "./paper-editor-mirror.mjs";
import { derive } from "./derive.mjs";

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = join(here, "..");

// ── the w4 seam (charter D22) ────────────────────────────────────────────────
// `rawTokens` is design/tokens.json parsed VERBATIM — the frozen structure and,
// for evergreen, the byte-for-byte characterization mirror. `tokens` (the export
// every builder reads) is that raw tree with its color palette swapped for a
// CLONE overlaid by derive(activeTheme): a clone-and-overlay adapter, never a
// tree built from scratch. structuredClone preserves every leaf verbatim; the
// overlay only re-stamps the 156 theme-varying SLOTS derive() emits (dotted paths
// under color.*), so the non-derived leaves survive untouched — status.warn.strong
// (bool, read below to emit --warn-strong), color._convention, and the 11 D21
// passthrough families derive() deliberately does not resolve. With
// activeTheme=evergreen the overlay is byte-identical to the raw color tree
// (check.mjs Part F proves derive(evergreen) === tokens.json), so NOTHING the
// emitter writes moves. Swapping activeTheme is the multitheme switch (w4b+).
export const rawTokens = JSON.parse(readFileSync(join(here, "tokens.json"), "utf8"));
const activeTheme = JSON.parse(readFileSync(join(here, "themes", "evergreen.json"), "utf8"));

// structural deep-equality — used by the seam guard. Compares by shape and
// primitive value (order-independent for objects), so a non-string leaf that
// silently drifted (e.g. status.warn.strong flipping) is caught, not skipped.
function deepEqualColor(a, b, path = "color") {
  if (a === b) return true;
  if (typeof a !== typeof b) throw new Error(`seam guard: type drift at ${path} — ${typeof a} vs ${typeof b}`);
  if (a === null || b === null || typeof a !== "object") {
    if (a !== b) throw new Error(`seam guard: value drift at ${path} — ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
    return true;
  }
  const ak = Object.keys(a), bk = Object.keys(b);
  if (ak.length !== bk.length) throw new Error(`seam guard: key-count drift at ${path} — ${ak.length} vs ${bk.length}`);
  for (const k of ak) {
    if (!Object.prototype.hasOwnProperty.call(b, k)) throw new Error(`seam guard: missing key at ${path}.${k}`);
    deepEqualColor(a[k], b[k], `${path}.${k}`);
  }
  return true;
}

const adaptedColor = structuredClone(rawTokens.color);
{
  const derived = derive(activeTheme).values;
  for (const [slot, value] of Object.entries(derived)) {
    const keys = slot.split(".");
    let node = adaptedColor;
    for (let i = 0; i < keys.length - 1; i++) node = node[keys[i]];
    node[keys[keys.length - 1]] = value;
  }
  // Seam guard: for evergreen the overlay MUST be byte-identical to the raw color
  // tree INCLUDING non-string leaves (status.warn.strong, color._convention). This
  // is what makes the byte-identity proof total — if a derive(evergreen) slot ever
  // drifts from the shipped byte, fail loudly here rather than silently emit a
  // retinted artifact. Guarded on evergreen because a real alternate theme is
  // SUPPOSED to differ from the raw tree (that is the whole point of w4b).
  if ((activeTheme.name || "evergreen") === "evergreen")
    deepEqualColor(adaptedColor, rawTokens.color);
}
export const tokens = { ...rawTokens, color: adaptedColor };

// ── theme identity axis (theme-system Wave 4 — charter D23/D24) ───────────────
// A THEME is an authored design/themes/<name>.json skin (per-mode {bg,ink,accent}
// + overrides + passthrough); design/derive.mjs expands it into a full palette.
// Every CSS surface renders each theme into its OWN [data-bp-theme=<name>] block
// (a light AND a dark mode scope) INSIDE the generated marker, layered over the
// bare/evergreen declarations that render when no attribute is present (the FOUC-
// free fallback). Theme identity (data-bp-theme) and light/dark mode (data-theme
// / prefers-color-scheme) are two ORTHOGONAL switches.
//
// design/themes/ ships evergreen ONLY; the N-theme path is proven with a fixture
// theme injected in tests (D24). loadThemes() is the default source (the real
// dir); tests pass their own theme list straight to themeBlocks().
export const THEMES_DIR = join(here, "themes");

export function loadThemes() {
  return readdirSync(THEMES_DIR)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => {
      const spec = JSON.parse(readFileSync(join(THEMES_DIR, f), "utf8"));
      return { name: spec.name || f.replace(/\.json$/, ""), spec };
    })
    // Default theme FIRST, rest in dir order: every generated enumeration
    // (Go Themes(), Elixir @themes → Tenancy.known_themes → the Studio picker,
    // CSS theme blocks, the showroom) leads with the built-in skin regardless
    // of how theme FILENAMES alphabetize (e.g. ember.json < evergreen.json).
    .sort((a, b) => (b.name === DEFAULT_THEME ? 1 : 0) - (a.name === DEFAULT_THEME ? 1 : 0));
}

// Overlay derive(spec) onto a deep clone of tokens.color → a full tokens-shaped
// palette for one theme. Passthrough families (provider, lifecycle, statusChrome,
// readerInfo, authButton, …) and every non-color token family (type, font) come
// from base tokens UNCHANGED; only the theme-varying SLOTS are swapped. For
// evergreen this equals tokens byte-for-byte (check.mjs Part F proves
// derive(evergreen) === tokens), so the evergreen theme block renders identically
// to the bare fallback — no visual change, only a new attribute hook.
export function themePalette(spec) {
  const t = JSON.parse(JSON.stringify(tokens));
  const { values, slots } = derive(spec);
  for (const slot of slots) {
    const v = values[slot];
    if (v === undefined) continue;
    const parts = slot.split(".");
    let o = t.color;
    for (let i = 0; i < parts.length - 1; i++) o = o[parts[i]];
    o[parts[parts.length - 1]] = v;
  }
  return t;
}

// Render one surface's per-theme [data-bp-theme] blocks. `render(name, palette)`
// returns the block text for a single theme given its derived palette; the
// passthrough families that check.mjs Parts B/D count POSITIONALLY (--life-*,
// --provider-*, .bp-lg--, .bp-inst--) are NEVER re-declared inside these blocks
// (charter D25). Returns "" when no theme is present (older callers stay safe).
export function themeBlocks(themes, render) {
  return themes.map(({ name, spec }) => render(name, themePalette(spec))).join("\n");
}

// A short banner emitted just above the per-theme blocks in each CSS surface, so
// the generated output reads clearly (theme identity vs the evergreen fallback).
const THEME_BANNER =
  "/* ── theme identity (data-bp-theme) — orthogonal to light/dark mode; the bare declarations above are the evergreen fallback (no attribute → renders exactly as today) ── */";

// ── shared vocabulary ───────────────────────────────────────────────────────
export const BASE_ROLES = [
  "primary", "primary-hover", "primary-fg", "bg", "surface", "muted-surface",
  "text", "muted-text", "border", "ring", "accent",
];
export const STATUS_ROLES = ["ok", "warn", "danger", "info"];
export const LIFE_ORDER = [
  "in_progress", "blocked", "done", "closed", "cancelled", "ready", "open",
  // The pre-open thought states (task-lifecycle-visibility epic): a candidate
  // the strategizer just named (considering ◌) → under investigation
  // (researching ◎) → open (ready). Appended so the canonical emission order the
  // whole generated chain reads (Go board/semrole, Studio TokensGen, paper-surface
  // .bp-lg--, root --life-*) extends without renumbering the shipped states.
  "considering", "researching",
];
// Cloud INSTANCE lifecycle emission order (matches tokens.instanceLifecycle).
export const INST_ORDER = [
  "provisioning", "live", "degraded", "stopped", "archived", "decommissioned", "adopted",
];
export const PROVIDERS = ["hetzner", "azure"];
// An instance state's colour is READ THROUGH its status role (Decision 7): the
// role picks a CSS var (SPA) and the {light,dark} channels its Go hue resolves
// from. role "" (neutral: stopped/archived + _default) → the muted-text tone.
export const INST_ROLE_CSS = { ok: "--ok", warn: "--warn", danger: "--danger", info: "--info", "": "--muted-text" };
export const instRoleChannels = (role) =>
  role === "" ? tokens.color["muted-text"] : tokens.color.status[role];
// Chrome type-scale steps, largest → smallest (display order for the Studio type
// ladder). Mirrors tokens.type.chrome; the emitter and check.mjs both key off it.
export const TYPE_STEPS = ["2xl", "xl", "lg", "base", "sm", "xs"];
// The reader AIR ladder (tokens.space.air), lightest opening → heaviest. Emission
// order IS the ladder order design/validate.mjs asserts monotonic, and every step
// here has a consumer in paper-surface.css — an entry with none is a dead token.
export const AIR_STEPS = ["code", "table", "asciicast", "callout", "stats", "figure"];
// The EVIDENCE BAND inputs (tokens.space.evidence), in emission order. Emitted as
// `--tok-evidence-*`; paper-surface.css composes all five into ONE width
// expression, so what ships is the law and not a resolved pixel. Every key here
// has a live consumer — check.mjs Part K refuses a member with none, and
// validate.mjs refuses a member that is not on this list.
export const EVIDENCE_KEYS = ["band", "bandMax", "fill", "gutter", "caption"];
// `fill` is a bare RATIO (it is multiplied by 100cqw) and `caption` is a reading
// MEASURE in characters — neither is a pixel, and emitting them as one would be
// the drift the units exist to prevent.
export const EVIDENCE_UNITS = { band: "px", bandMax: "px", fill: "", gutter: "px", caption: "ch" };
// The SECTION BOUNDARY inputs (tokens.space.section), in emission order. `beat` is
// a ratio of `--tok-air-beat` (so section rhythm and evidence rhythm retune
// together); `rule` and `gap` are pixels — a hairline does not scale with a beat.
// Every key has a live consumer on the `h2` rule of BOTH surfaces; check.mjs
// Part L refuses a member with none, validate.mjs refuses a member not listed here.
export const SECTION_KEYS = ["beat", "rule", "gap"];
export const SECTION_UNITS = { beat: "", rule: "px", gap: "px" };
// The RULE LADDER (tokens.space.rule). `space.section.rule` is the STRUCTURAL
// weight and has its own key above; this is the OTHER rung — the weight every
// line that is not a section boundary draws at. Kept as a token rather than a
// literal `1px` for one reason: a census can only assert "chrome is quieter than
// structure" if both weights are named, and check.mjs Part M reads this list to
// find what the census is allowed to see.
export const RULE_KEYS = ["hairline"];
export const RULE_UNITS = { hairline: "px" };
// The MOTION LADDER (tokens.motion), quickest → slowest. Three durations and
// nothing else: `dur-1` is the chrome tick (a hover, a border warming), `dur-2`
// the state change, `dur-3` the one that has to be SEEN (a panel fading out, a
// column morphing between two widths). Emitted as bare `--dur-N` custom
// properties — the same shape the Studio's chrome type scale ships as
// (`--text-*`), not the `--tok-*`/`--bp-*` bridge the reading surface uses,
// because a duration has no per-surface reinterpretation to bridge THROUGH.
//
// This family was authored in tokens.json and emitted NOWHERE until
// spd-b21: every transition in the Studio was a hand-typed literal, and
// spd-s5 hardcoded 0.15s on `.pane-column` ON PURPOSE because a `var(--dur-1)`
// would have resolved to nothing and silently killed the collapse animation.
// check.mjs Part N is the gate that keeps it honest — it re-asserts these bytes
// against tokens.json on every emitting surface AND ratchets the count of
// hand-typed duration literals that are still outside the ladder.
export const MOTION_STEPS = ["dur-1", "dur-2", "dur-3"];
// Every surface that MUST declare the ladder: it draws a `transition` or an
// `animation` and has a root-equivalent scope to hang a custom property on.
// check.mjs Part N reads this list and proves each entry carries the tokens.json
// bytes exactly once, so the list cannot become a lie in either direction.
//
// Every entry but ONE gets the ladder from the GENERATED block below:
//   • api/assets/paper-editor/src/styles.css receives it through the de-scoping
//     paper-surface mirror rather than an emitter of its own. That is the only
//     surface on this list with no generated declaration of its own.
//
// cloud/priv/static/app.css was the second exception until cch-app-css-motion:
// it DECLARED THE LADDER BY HAND in its decision-29 token area (--dur-1/-2/-3
// with exactly these values, plus --ease, --t and a prefers-reduced-motion
// collapse to 0s), and the emitter deliberately wrote nothing, because the
// generated block sits EARLIER in the file — a hand copy downstream wins the
// cascade and makes the emitted bytes, the ones Part N reads, inert. That is now
// closed in the only order that is safe: cloudBlock() EMITS all five declarations
// plus the reduced-motion collapse, and the hand copy was DELETED in the same
// diff. Each rung is declared exactly once, and the declaration that paints is
// the declaration the gate reads. Part N's exactly-once arm is the tripwire —
// re-adding a hand copy anywhere below the marker reds it immediately, and
// deleting the hand copy WITHOUT this emission would have left four live
// consumers (.fresh-badge x2, modal-in, toast-in) resolving to nothing.
//
// `--ease` is tokens.motion.ease. `--t` (`var(--dur-1) var(--ease)`) is a
// cloud-LOCAL shorthand with ~26 consumers, not a new token — it rides along
// because it is fully DERIVED from the ladder, and leaving it hand-authored
// while the rungs moved is exactly the split this promotion exists to remove.
//
// cloud/priv/static/styleguide.html is absent for a third reason: its generated
// region is a swatch TABLE (markup), with nowhere to put a declaration. Its one
// literal (a 1.4s skeleton shimmer) is ledgered in Part N's ratchet instead.
export const MOTION_SURFACES = [
  "api/lib/barkpark_web/layouts/root.html.heex",
  "api/lib/barkpark_web/layouts/bulldocs.html.heex",
  "api/assets/paper-surface/paper-surface.css",
  "api/assets/paper-editor/src/styles.css",
  "api/lib/barkpark_web/controllers/session_html.ex",
  "cloud/priv/static/app.css",
  "web/app/globals.css",
];
const kebab = (s) => s.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());
// Paper reading-surface `--paper-*` color roles, in emission order. Sourced from
// color.paper.surface for paper-surface.css (paperBlock) and color.paper.reader
// for the bulldocs reader skin (bulldocsBlock). VERBATIM (rgba/hex as-authored).
export const PAPER_ROLES = [
  "bg", "bg-deep", "ink", "ink-soft", "ink-faint", "rule",
  "edit-hover", "accent", "accent-soft", "chrome-bg", "chrome-border",
];
// Callout tones in the SAME order util.ex tone_palette/1 clauses read them, so
// the emitted TokensGen.callout/1 clauses line up with their consumer.
export const CALLOUT_TONES = ["success", "warning", "danger", "info", "neutral"];

const softAlpha = tokens.color._convention.softAlpha;   // { light, dark }
const strongAlpha = tokens.color._convention.strongAlpha; // { light, dark, _note }

const MARKER_BEGIN =
  "/* BEGIN GENERATED: tokens (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) */";
const MARKER_END = "/* END GENERATED: tokens */";

// The cloud SPA's BP_THEMES list (app.js) is GENERATED, not hand-kept (GR12):
// the hand-list had already drifted (charple emitted in CSS but unreachable
// because the JS enum omitted it). emit.mjs owns the theme-id enum now; a hand
// edit reds design/check.mjs Part A the same way a stale CSS surface does. The
// marker is a JS block comment (valid CSS-comment syntax too), so it rides the
// same splice machinery — see the app.js artifact's markerBegin/markerEnd.
const BP_THEMES_MARKER_BEGIN =
  "/* BEGIN GENERATED: bp-theme ids (design/themes/*.json via design/emit.mjs — node design/emit.mjs --write; do not hand-edit) */";
const BP_THEMES_MARKER_END = "/* END GENERATED: bp-theme ids */";

// The cloud SPA's ACTION_LABELS object (app.js) is the SECOND generated region in
// that file — the audit verb table cloud/priv/audit-actions.json owns BOTH the
// closed Elixir @actions vocabulary and the console's human sentence fragments, so
// the two can no longer drift apart by hand (charter cch-w65). Same splice
// machinery, its own marker, its own ledger slot (the `<path>#<name>` key, charter
// D835). The marker string below is the emitter's LOOKUP KEY and is BYTE-PINNED to
// the marker line shipped inside app.js's generated region — cch-w53 repoints both
// to cloud/priv/audit-actions.json (the table moved there in #11781) in one commit:
// the marker text here and the matching hand-edited marker line in app.js.
const ACTION_LABELS_MARKER_BEGIN =
  "/* BEGIN GENERATED: audit action labels (cloud/priv/audit-actions.json via design/emit.mjs — node design/emit.mjs --write; do not hand-edit) */";
const ACTION_LABELS_MARKER_END = "/* END GENERATED: audit action labels */";

// ── color helpers ───────────────────────────────────────────────────────────
const hsl = (ch) => `hsl(${ch})`;
const alpha = (a) => String(a); // 0.15 -> "0.15", 0.2 -> "0.2"

// HSL channels "H S% L%" -> "#rrggbb". Only the Go pdrender tones need hex
// (lipgloss wants hex); CSS surfaces keep hsl() so the soft-tint machinery lives.
export function hslToHex(channels) {
  const m = channels.trim().split(/\s+/);
  const h = parseFloat(m[0]);
  const s = parseFloat(m[1]) / 100;
  const l = parseFloat(m[2]) / 100;
  const c = (1 - Math.abs(2 * l - 1)) * s;
  const hp = h / 60;
  const x = c * (1 - Math.abs((hp % 2) - 1));
  let r = 0, g = 0, b = 0;
  if (hp >= 0 && hp < 1) [r, g, b] = [c, x, 0];
  else if (hp < 2) [r, g, b] = [x, c, 0];
  else if (hp < 3) [r, g, b] = [0, c, x];
  else if (hp < 4) [r, g, b] = [0, x, c];
  else if (hp < 5) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  const m2 = l - c / 2;
  const to = (v) => Math.round((v + m2) * 255).toString(16).padStart(2, "0");
  return `#${to(r)}${to(g)}${to(b)}`;
}

// "U+280B" -> "⠋"
export const glyphOf = (cp) => String.fromCodePoint(parseInt(cp.slice(2), 16));

// A lipgloss.AdaptiveColor{Light,Dark} Go literal — the value a non-evergreen Go
// theme entry stamps directly (the evergreen entry keeps its Gen* var reference,
// so N=1 stays byte-identical; only theme N+1 grows a literal entry per map).
const goAdaptive = (light, dark) => `lipgloss.AdaptiveColor{Light: "${light}", Dark: "${dark}"}`;

// ── CSS var fragments (shared by every CSS surface) ─────────────────────────
// Each helper reads from a tokens-shaped palette `t` (default: the base tokens
// singleton). The bare/evergreen callers pass no `t` and get identical bytes to
// before; the per-theme block builders pass themePalette(spec) so the SAME
// formatting logic produces each theme's values — one code path, zero drift.
const baseVar = (role, theme, t = tokens) => `--${role}: ${hsl(t.color[role][theme])};`;

function statusVars(theme, indent, t = tokens) {
  const st = t.color.status;
  const lines = [
    STATUS_ROLES.map((r) => `--${r}-hsl: ${st[r][theme]};`).join(" "),
    STATUS_ROLES.map((r) => `--${r}: hsl(var(--${r}-hsl));`).join(" "),
    STATUS_ROLES.map((r) => `--${r}-soft: hsl(var(--${r}-hsl) / ${alpha(softAlpha[theme])});`).join(" "),
    STATUS_ROLES
      .filter((r) => st[r].strong === true)
      .map((r) => `--${r}-strong: hsl(var(--${r}-hsl) / ${alpha(strongAlpha[theme])});`)
      .join(" "),
  ];
  return lines.map((l) => indent + l).join("\n");
}

function baseVars(theme, indent, t = tokens) {
  return BASE_ROLES.map((r) => indent + baseVar(r, theme, t)).join("\n");
}

// The motion ladder → `--dur-1/-2/-3`. THEME-INVARIANT (a duration does not flip
// with a palette, exactly as the chrome type scale does not), so every surface
// emits it once, on its root-equivalent scope, and never inside a
// [data-bp-theme] or [data-theme] block — the chromeTypeVars precedent (D25).
// The unit comes from tokens.motion._unit, so a token authored in seconds can
// never be emitted as a bare number.
export const motionVarLines = (t = tokens) =>
  MOTION_STEPS.map((k) => `--${k}: ${t.motion[k]}${t.motion._unit};`);
function motionVars(indent, t = tokens) {
  return motionVarLines(t).map((l) => indent + l).join("\n");
}

// --primary carries the same -hsl/-soft machinery the status roles use, so blue
// accent TINTS being swept off literals have an evergreen --primary-soft to bind
// to. (--primary and --primary-hover themselves are emitted by baseVars via
// BASE_ROLES; this only adds the derived -hsl channel + the soft-tint fill.)
function primaryVars(theme, indent, t = tokens) {
  const ch = t.color.primary[theme];
  const lines = [
    `--primary-hsl: ${ch};`,
    `--primary-soft: hsl(var(--primary-hsl) / ${alpha(softAlpha[theme])});`,
  ];
  return lines.map((l) => indent + l).join("\n");
}

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

// ── cloud accent block (GR6: green IS the accent) ────────────────────────────
// The per-identity 5-tuple: --primary + its -hsl/-soft machinery, the brand ring,
// and the --ok family that now TRACKS accent.primary (no standalone green). NEW
// --ok-strong = accent.hover is the text-on-tint voice (fixes the light evergreen
// 4.06 / ember 4.23 pill-text fails). Emitted in the bare :root (evergreen
// fallback) AND inside each [data-bp-theme] block — the ONLY per-identity vars.
// Carries NO --cc-* and NO shell roles (D25 / GR2). primary/primary-fg/ring/
// primary-hover are HSL channel strings in tokens; --ok-strong reads the hover
// channel WITHOUT re-emitting the retired --primary-hover var.
function cloudAccentVars(theme, indent, t = tokens) {
  const a = alpha(softAlpha[theme]);
  const p = t.color.primary[theme];
  const hover = t.color["primary-hover"][theme];
  const lines = [
    `--primary: hsl(${p});`,
    `--primary-fg: hsl(${t.color["primary-fg"][theme]});`,
    `--ring: hsl(${t.color.ring[theme]});`,
    `--primary-hsl: ${p};`,
    // --primary-soft retired (GUI-remake GR22, gr-p2-launch-theater): its sole
    // consumer (.size-opt selected tint) now reads --ok-soft — the identical
    // channel/alpha, since --ok TRACKS accent.primary (GR6). The Studio
    // surface's primaryVars copy is untouched (root.html.heex still consumes it).
    // --ring-hsl/--ring-soft PROMOTED (gr-p5r7-ring-soft-accent-invariant): the
    // focus ring's soft tint was hand-stamped TWICE outside the generated region
    // (evergreen green in both modes), so :focus-visible stayed green under
    // ember/fjord/charple/iris. It now rides the identity's OWN ring channel —
    // the same channel --ring already reads — through the shared softAlpha
    // convention, exactly as the login surface derives it in authRows().
    `--ring-hsl: ${t.color.ring[theme]};`,
    `--ring-soft: hsl(var(--ring-hsl) / ${a});`,
    `--ok-hsl: ${p};`,
    `--ok: hsl(var(--ok-hsl));`,
    `--ok-soft: hsl(var(--ok-hsl) / ${a});`,
    `--ok-strong: hsl(${hover});`,
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

// ── surface: paper-surface (api/assets/paper-surface/paper-surface.css) ──────
// Reading font + reading type scale + status tones, plus the lifecycle
// glyph-tone classes (.bp-lg--<state>) that give the CSS/GUI half of the §6
// cross-surface parity assertion its hues. Additive (.bp-lg-- is a fresh, un-
// consumed class set; the hand-authored .bp-g-- ladder is untouched).
// The `--paper-*` reading-surface theme colours for ONE theme (color.paper.surface,
// VERBATIM). Emitted on the html[data-theme=…] + bare-fallback token scopes — the
// same three-way structure the hand region used (attr blocks win over the light
// fallback so a pre-paint no-data-theme load still gets the light bp theme).
function paperColorVars(theme, indent, t = tokens) {
  const s = t.color.paper.surface;
  return [
    ...PAPER_ROLES.map((role) => indent + `--paper-${role}: ${s[role][theme]};`),
    // S7 STUB (charter Decision 6): the warm reading accent (color.reading-accent,
    // theme-derived) emitted onto the reading surface but UNCONSUMED — S8 (the
    // article terracotta pullquote/rule) reads it. Additive W1 posture; the
    // paper-editor mirror picks it up automatically.
    indent + `--paper-reading-accent: ${hslToHex(t.color["reading-accent"][theme])};`,
  ].join("\n");
}

// Paper theme block: the `--paper-*` reading-surface skin + status tones under
// the theme attribute. paper-surface is an ATTRIBUTE surface (edit surfaces stamp
// data-theme), so the dark scope keys on [data-theme=dark] (NOT @media) — that
// keeps the reader-dark-parity guard untouched (it scans `html[data-theme="dark"]`
// and prefers-color-scheme blocks; `html[data-bp-theme=X][data-theme=dark]`
// matches neither substring). Reading-type vars are theme-invariant and the
// .bp-lg-- glyph tones are positional passthrough (D25) — both excluded here.
const paperThemeBlock = (name, t) => [
  `html[data-bp-theme="${name}"] .bp-paper-surface, html[data-bp-theme="${name}"] .bp-paper-body {`,
  paperColorVars("light", "  ", t),
  statusVars("light", "  ", t),
  "}",
  `html[data-bp-theme="${name}"][data-theme="dark"] .bp-paper-surface, html[data-bp-theme="${name}"][data-theme="dark"] .bp-paper-body {`,
  paperColorVars("dark", "  ", t),
  statusVars("dark", "  ", t),
  "}",
].join("\n");

function paperBlock(themes = loadThemes()) {
  const r = tokens.type.reading;
  // Each reading step emits size + line-height, and a tracking var ONLY where
  // tokens.json declares a letterSpacing. The tracking leaves were declared in
  // the source and emitted NOWHERE until pe-w1-reader-editorial-typography — the
  // `--bp-*-tracking` vars were hand-authored beside a token that claimed to own
  // them, so the single source was single in name only.
  const step = (name, s) => [
    `--tok-reading-${name}-size: ${s.size}px;`,
    `--tok-reading-${name}-lh: ${s.lineHeight};`,
    ...(s.letterSpacing == null ? [] : [`--tok-reading-${name}-tracking: ${s.letterSpacing}em;`]),
  ];
  // The AIR scale (space.air): the beat an EVIDENCE block opens with. Emitted as
  // a ratio of `--tok-air-beat` rather than a resolved pixel, so the LAW ("evidence
  // opens at 1.1-1.85x the paragraph beat") is what ships — retune the beat and the
  // whole scale moves together instead of eight literals drifting apart.
  const a = tokens.space.air;
  const airVars = [
    `--tok-air-beat: ${a.beat}px;`,
    ...AIR_STEPS.map((k) => `--tok-air-${k}: calc(var(--tok-air-beat) * ${a[k]});`),
  ];
  // The EVIDENCE BAND (space.evidence): how wide a block that improves with width
  // may grow when it steps out of the prose column. Emitted as the four inputs to
  // one law, never as a resolved width — paper-surface.css composes them into a
  // single `--bp-evidence-width` expression, so the band is CONTINUOUS in the
  // available inline space and there is no breakpoint literal to drift.
  // `caption` carries `ch`, not `px`: it is a reading measure, and a caption
  // inside a wide figure must wrap at a character count, not at a pixel.
  const e = tokens.space.evidence;
  const evidenceVars = EVIDENCE_KEYS.map(
    (k) => `--tok-evidence-${kebab(k)}: ${e[k]}${EVIDENCE_UNITS[k]};`,
  );
  // The SECTION BOUNDARY (space.section): the air that ends a section and the rule
  // that opens the next. `beat` emits as a ratio of `--tok-air-beat` — the same
  // anchor the evidence ladder hangs off, so retuning the beat moves section
  // rhythm and evidence rhythm together instead of letting them drift apart.
  // `rule`/`gap` emit as pixels: a hairline is a hairline at any beat.
  const sc = tokens.space.section;
  const sectionVars = SECTION_KEYS.map((k) =>
    k === "beat"
      ? `--tok-section-beat: calc(var(--tok-air-beat) * ${sc.beat});`
      : `--tok-section-${k}: ${sc[k]}${SECTION_UNITS[k]};`,
  );
  // The RULE LADDER (space.rule): the weight of every horizontal line that is
  // NOT a section boundary. Emitted beside the section rule on purpose — the two
  // are one ladder, and a reader who sees them apart is reading a paper where a
  // table header shouts as loud as a chapter break.
  const rl = tokens.space.rule;
  const ruleVars = RULE_KEYS.map((k) => `--tok-rule-${kebab(k)}: ${rl[k]}${RULE_UNITS[k]};`);

  const readingVars = [
    `--tok-reading-font: ${tokens.font.reading.stack};`,
    `--tok-reading-heading-weight: ${r.headingWeight};`,
    ...step("body", r.body),
    ...step("h1", r.h1),
    ...step("h2", r.h2),
    ...step("h3", r.h3),
    ...airVars,
    ...sectionVars,
    ...ruleVars,
    ...evidenceVars,
    // The motion ladder rides the reading surface's own root scope so the
    // paper-editor bundle inherits it through the de-scoping mirror.
    ...motionVarLines(),
  ].map((l) => "  " + l).join("\n");

  const lifeClasses = (theme) =>
    LIFE_ORDER.map((s) => `.bp-lg--${s} { color: ${tokens.lifecycle[s].color[theme]}; }`).join("\n");

  const themed = themeBlocks(themes, paperThemeBlock);
  return [
    "/* ── `--paper-*` reading-surface theme tokens (color.paper.surface — relocated",
    "   from the hand region into this GENERATED block; Barkpark aesthetic-unification:",
    "   cool near-white ground, evergreen accent, replacing the legacy warm parchment).",
    "   Scoped to .bp-paper-surface; the html[data-theme] blocks win over the light",
    "   fallback so a pre-paint no-data-theme load still gets the light bp theme. */",
    'html[data-theme="light"] .bp-paper-surface,',
    'html[data-theme="light"] .bp-paper-body {',
    paperColorVars("light", "  "),
    "}",
    'html[data-theme="dark"] .bp-paper-surface,',
    'html[data-theme="dark"] .bp-paper-body {',
    paperColorVars("dark", "  "),
    "}",
    ".bp-paper-surface, .bp-paper-body {",
    paperColorVars("light", "  "),
    "}",
    ".bp-paper-surface, .bp-paper-body {",
    readingVars,
    statusVars("light", "  "),
    "}",
    "@media (prefers-color-scheme: dark) {",
    "  .bp-paper-surface, .bp-paper-body {",
    statusVars("dark", "    "),
    "  }",
    "}",
    'html[data-theme="light"] .bp-paper-surface, html[data-theme="light"] .bp-paper-body {',
    statusVars("light", "  "),
    "}",
    'html[data-theme="dark"] .bp-paper-surface, html[data-theme="dark"] .bp-paper-body {',
    statusVars("dark", "  "),
    "}",
    "/* lifecycle glyph tones — the CSS half of the §6 GUI/TUI parity assertion */",
    lifeClasses("light"),
    "@media (prefers-color-scheme: dark) {",
    lifeClasses("dark").split("\n").map((l) => "  " + l).join("\n"),
    "}",
    ...(themed ? [THEME_BANNER, themed] : []),
  ].join("\n");
}

// ── surface: Studio (api/lib/barkpark_web/layouts/root.html.heex inline style) ─
// ADOPTION (W2.7): base roles now cascade to the hand-authored html[data-theme]
// blocks that follow — they no longer redefine --primary/--ring, so the emitted
// evergreen primary is live. Light base + status sit on :root; the DARK base is
// keyed on html[data-theme="dark"] (NOT @media) because Studio themes via a
// data-theme toggle, so the dark base must track the attribute (mirrors
// cloudBlock). Status dark stays under @media (unchanged). Emitted inside a
// <style>, hence CSS comment syntax and an extra 4-space indent to sit in block.
// On-fill status foregrounds (--ok-fg/--warn-fg/--danger-fg/--info-fg) + the
// zinc/chrome ladder (--bg-accent/--border-muted/--fg-dim/--fg-accent). Both are
// Studio-ONLY: no other surface consumes them, so they live here (studioBlock),
// NOT in the shared statusVars/baseVars that every CSS surface emits. Chrome
// values are HSL channels OR a bare var(--role) reference (border-muted light =
// --border; fg-accent dark = --text) — the emitter passes a var() through.
const STATUS_FG = ["ok-fg", "warn-fg", "danger-fg", "info-fg"];
const CHROME_ALIASES = ["bg-accent", "border-muted", "fg-dim", "fg-accent", "surface-raised", "border-subtle"];
const chromeVal = (v) => (v.startsWith("var(") ? v : hsl(v));

function onStatusVars(theme, indent, t = tokens) {
  const os = t.color.onStatus;
  return STATUS_FG.map((r) => indent + `--${r}: ${hsl(os[r][theme])};`).join("\n");
}
function chromeVars(theme, indent, t = tokens) {
  const ch = t.color.studioChrome;
  return CHROME_ALIASES.map((r) => indent + `--${r}: ${chromeVal(ch[r][theme])};`).join("\n");
}

// Chrome type scale → --text-<step> / --text-<step>-lh CSS vars (W2.7 gap close,
// Decision D2). Theme-invariant (size/line-height don't flip), so emitted ONLY in
// :root. The Studio styleguide type ladder renders straight off these vars.
function chromeTypeVars(indent) {
  const t = tokens.type.chrome;
  return TYPE_STEPS
    .map((s) => indent + `--text-${s}: ${t[s].size}px; --text-${s}-lh: ${t[s].lineHeight};`)
    .join("\n");
}

// Lifecycle glyph tones → --life-<state> CSS vars (Decision D1). The Studio MIRROR
// of the one lifecycle source (tokens.lifecycle.*.color) — the exact hues the Go
// board + paper-surface .bp-lg-- classes emit from. Theme-specific: light on
// :root, dark on html[data-theme="dark"]. Lets the styleguide colour a lifecycle
// glyph via var(--life-<state>) (an APPLIED-STYLE var, never a copied hex) and
// participates in the §6 cross-surface parity assertion (design/check.mjs Part B).
function lifeVars(theme, indent) {
  const life = tokens.lifecycle;
  return LIFE_ORDER.map((s) => indent + `--life-${s}: ${life[s].color[theme]};`).join("\n");
}

// Studio theme block: base + primary + status + on-status + chrome under the
// theme attribute (all inside the <style>, so the 4-space block indent). The
// dark scope keys on [data-theme=dark] — Studio always seeds data-theme, so the
// toggle carries status dark too (a superset of the bare @media path). Chrome
// type-scale (theme-invariant px) and --life-* glyph tones (positional
// passthrough, Part B) are excluded (D25).
const studioThemeBlock = (name, t) => {
  const ind = "    ";
  return [
    ind + `html[data-bp-theme="${name}"] {`,
    baseVars("light", ind + "  ", t),
    primaryVars("light", ind + "  ", t),
    statusVars("light", ind + "  ", t),
    onStatusVars("light", ind + "  ", t),
    chromeVars("light", ind + "  ", t),
    ind + "}",
    ind + `html[data-bp-theme="${name}"][data-theme="dark"] {`,
    baseVars("dark", ind + "  ", t),
    primaryVars("dark", ind + "  ", t),
    statusVars("dark", ind + "  ", t),
    onStatusVars("dark", ind + "  ", t),
    chromeVars("dark", ind + "  ", t),
    ind + "}",
  ].join("\n");
};

function studioBlock(themes = loadThemes()) {
  const ind = "    ";
  const lines = [
    ind + ":root {",
    baseVars("light", ind + "  "),
    primaryVars("light", ind + "  "),
    statusVars("light", ind + "  "),
    onStatusVars("light", ind + "  "),
    chromeVars("light", ind + "  "),
    chromeTypeVars(ind + "  "),
    motionVars(ind + "  "),
    lifeVars("light", ind + "  "),
    ind + "}",
    ind + 'html[data-theme="dark"] {',
    baseVars("dark", ind + "  "),
    primaryVars("dark", ind + "  "),
    onStatusVars("dark", ind + "  "),
    chromeVars("dark", ind + "  "),
    lifeVars("dark", ind + "  "),
    ind + "}",
    ind + "@media (prefers-color-scheme: dark) {",
    ind + "  :root {",
    statusVars("dark", ind + "    "),
    ind + "  }",
    ind + "}",
  ];
  const themed = themeBlocks(themes, studioThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: web demo (web/app/globals.css — Tailwind v4 @theme) ─────────────
// Light values register in a top-level @theme (Tailwind v4 requires @theme stay
// top-level — you cannot nest it under a selector or media query). Dark is an
// EXPLICIT [data-theme="dark"] override that redefines the same --color-* the
// theme registered; equal specificity to @theme's :root, but it comes LATER so
// it wins the cascade — mirroring cloudBlock()'s :root/[data-theme] pair. The
// OS-only @media block is intentionally dropped: default theme comes from the
// data-theme island (seeded from prefers-color-scheme), so the explicit toggle
// is the single source of truth and always wins.
// Web theme block: the @theme registration must stay TOP-LEVEL (Tailwind v4
// forbids nesting it), so per-theme values are plain [data-bp-theme=X] selectors
// that redefine the same --color-* the theme registered. Light on the attribute,
// dark on the +[data-theme=dark] compound (one step more specific, so it wins
// over both the bare [data-theme=dark] and the theme-light block).
const webThemeBlock = (name, t) => {
  const st = t.color.status;
  return [
    `[data-bp-theme="${name}"] {`,
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(t.color[r].light)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].light)};`),
    "}",
    `[data-bp-theme="${name}"][data-theme="dark"] {`,
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(t.color[r].dark)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].dark)};`),
    "}",
  ].join("\n");
};

function webBlock(themes = loadThemes()) {
  const st = tokens.color.status;
  const lines = [
    "@theme {",
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(tokens.color[r].light)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].light)};`),
    // Theme-INVARIANT always-dark graph canvas (color.graphCanvas, a D21
    // passthrough — single hex, errorPage precedent). Registered in @theme so
    // Tailwind v4 auto-generates bg-graph-canvas; deliberately NO dark/theme
    // override — the Obsidian graph panel never flips.
    `  --color-graph-canvas: ${tokens.color.graphCanvas.canvas};`,
    // Motion ladder — theme-invariant, so it registers once in @theme and is
    // deliberately absent from the [data-theme]/[data-bp-theme] overrides below.
    ...motionVarLines().map((l) => "  " + l),
    "}",
    '[data-theme="dark"] {',
    ...BASE_ROLES.map((r) => `  --color-${r}: ${hsl(tokens.color[r].dark)};`),
    ...STATUS_ROLES.map((r) => `  --color-${r}: ${hsl(st[r].dark)};`),
    "}",
  ];
  const themed = themeBlocks(themes, webThemeBlock);
  if (themed) lines.push(THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: web TS token artifact (web/lib/tokens.gen.ts) ────────────────────
// A whole generated TS module (kind "ts", like the Go files). Exports the LIGHT
// canvas colours listings-map.tsx paints with, so no hex literal lives in the
// component. HSL strings — valid Canvas2D fillStyle/strokeStyle; the component
// composes alpha variants itself. Only the roles the canvas actually consumes
// are exported (no dead tokens).
function webTokensTs() {
  const c = (role) => hsl(tokens.color[role].light);
  const rows = [
    ["primary", "primary"],       // evergreen brand — the map marker
    ["mutedText", "muted-text"],  // a pin filtered out by the active search
    ["surface", "surface"],       // pin outline / basemap paper
    ["primaryFg", "primary-fg"],  // label text on the dark label chip
    ["text", "text"],             // label chip fill + pin shadow (via alpha)
    ["mutedSurface", "muted-surface"], // sea/landless basemap tint
  ];
  // Categorical match-quality SPECTRUM (7 ordered fuzzy→exact stops) → hsl()
  // strings, consumed by finder.tsx's HighlightLegend gradient. Theme-invariant
  // VALUE list, the web analog of the Studio presence/sheet-CF categorical sets.
  const spectrum = tokens.color.matchQuality.spectrum.map((ch) => hsl(ch));
  // Paper CALLOUT tone tints for the /papers reader (portable-doc.tsx) — the
  // web twin of Render.TokensGen.callout/1 + the paper-surface --bp-tone-*
  // pairs. Sourced from color.paperCallout ONLY, never color.status (a
  // DIFFERENT value set — tokens.json forbids the substitution). Tone order
  // mirrors util.ex tone_palette/1 (CALLOUT_TONES); hex verbatim, no HSL hop.
  const pc = tokens.color.paperCallout;
  const calloutRows = CALLOUT_TONES.map(
    (t) =>
      `  ${t}: { light: { bg: "${pc.light[t].bg}", fg: "${pc.light[t].fg}" }, dark: { bg: "${pc.dark[t].bg}", fg: "${pc.dark[t].fg}" } },`,
  );
  return [
    "// Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "// Regenerate: node design/emit.mjs --write",
    "",
    "/** Light-theme canvas colours for listings-map.tsx, mapped from design/tokens.json. */",
    "export const canvas = {",
    ...rows.map(([k, role]) => `  ${k}: "${c(role)}",`),
    "} as const;",
    "",
    "/** Categorical match-quality spectrum (7 ordered stops, fuzzy→exact) for",
    " *  finder.tsx's HighlightLegend gradient. Theme-invariant data-viz palette,",
    " *  NOT a status role — mirrors the presence / Sheets-CF categorical sets. */",
    "export const matchQuality = [",
    ...spectrum.map((s) => `  "${s}",`),
    "] as const;",
    "",
    "/** Paper callout tone tints for portable-doc.tsx (design/tokens.json",
    " *  color.paperCallout — the web twin of the paper-surface --bp-tone-* pairs).",
    " *  {bg,fg} hex per tone, light + dark. NOT the status roles — never",
    " *  substitute color.status for these. */",
    "export const paperCallout = {",
    ...calloutRows,
    "} as const;",
    "",
  ].join("\n");
}

// ── surface: Go board (internal/taskboard/tokens_gen.go) ─────────────────────
// Lifecycle glyph + adaptive hue + braille frames, mirroring theme.go/spinner.go
// values 1:1. Additive: no consumer is rewired — this is the generated twin the
// §6 gate compares against the CSS glyph tones.
// gofmt aligns contiguous map entries and var/const specs. Emit the same
// alignment up-front so gofmt is a no-op and the emitter output IS canonical.
function alignMap(rows) {
  const p = rows.map((r) => { const i = r.indexOf(": "); return { head: r.slice(0, i + 1), tail: r.slice(i + 2) }; });
  const w = Math.max(...p.map((x) => x.head.length));
  return p.map((x) => `${x.head.padEnd(w)} ${x.tail}`);
}
function alignEq(rows) {
  const p = rows.map((r) => { const i = r.indexOf(" = "); return { head: r.slice(0, i), tail: r.slice(i + 3) }; });
  const w = Math.max(...p.map((x) => x.head.length));
  return p.map((x) => `${x.head.padEnd(w)} = ${x.tail}`);
}
// alignFields formats gofmt-canonical struct-field decls ("<name> <type>"): the
// field name is padded so the type column aligns (spaces, exactly like gofmt).
function alignFields(rows) {
  const p = rows.map((r) => { const i = r.indexOf(" "); return { head: r.slice(0, i), tail: r.slice(i + 1).trimStart() }; });
  const w = Math.max(...p.map((x) => x.head.length));
  return p.map((x) => `${x.head.padEnd(w)} ${x.tail}`);
}

// DEFAULT_THEME is the built-in evergreen skin every Go Resolve(theme) defaults
// to for an unknown/empty id. Emitted as a `DefaultTheme` const in each generated
// package. Adding theme N+1 grows the genTheme* maps — one keyed entry — and the
// Resolve seam already threads it to every consumer (charter D28/D30).
const DEFAULT_THEME = "evergreen";

function goHeader(pkg) {
  return [
    "// Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "// Regenerate: node design/emit.mjs --write",
    "",
    `package ${pkg}`,
    "",
  ].join("\n");
}

function taskboardGo(themes = loadThemes()) {
  const life = tokens.lifecycle;
  const rows = LIFE_ORDER.map((s) => {
    const e = life[s];
    return `\t"${s}": {Glyph: "${glyphOf(e.codepoint)}", ASCIIGlyph: ${JSON.stringify(e.asciiGlyph)}, Role: ${JSON.stringify(e.role)}, ColorLight: "${e.color.light}", ColorDark: "${e.color.dark}"},`;
  });
  const frames = life.in_progress.frames.map((f) => `"${glyphOf(f)}"`).join(", ");
  // One genLifecycleThemes entry per committed theme. evergreen REFERENCES the
  // GenLifecycle/GenBrailleFrames/GenBrailleStill vars (byte-identical to today);
  // a non-evergreen theme stamps its lifecycle set as literals from themePalette.
  // Lifecycle hues are theme-INVARIANT passthrough (charter D21), so an alternate
  // theme's values equal evergreen's — the literal entry still proves the loop.
  const themeEntry = ({ name, spec }) => {
    if (name === DEFAULT_THEME)
      return [`\t${JSON.stringify(name)}: {Lifecycle: GenLifecycle, BrailleFrames: GenBrailleFrames, BrailleStill: GenBrailleStill},`];
    const pl = themePalette(spec).lifecycle;
    const litRows = LIFE_ORDER.map((s) => {
      const e = pl[s];
      return `\t\t\t"${s}": {Glyph: "${glyphOf(e.codepoint)}", ASCIIGlyph: ${JSON.stringify(e.asciiGlyph)}, Role: ${JSON.stringify(e.role)}, ColorLight: "${e.color.light}", ColorDark: "${e.color.dark}"},`;
    });
    const litFrames = pl.in_progress.frames.map((f) => `"${glyphOf(f)}"`).join(", ");
    return [
      `\t${JSON.stringify(name)}: {`,
      "\t\tLifecycle: map[string]GenLifecycleToken{",
      ...alignMap(litRows),
      "\t\t},",
      ...alignMap([
        `\t\tBrailleFrames: [10]string{${litFrames}},`,
        `\t\tBrailleStill: "${glyphOf(pl.in_progress.framesStill)}",`,
      ]),
      "\t},",
    ];
  };
  return [
    goHeader("taskboard"),
    "// GenLifecycleToken mirrors one design/tokens.json lifecycle state.",
    "type GenLifecycleToken struct {",
    "\tGlyph      string",
    "\tASCIIGlyph string",
    "\tRole       string",
    "\tColorLight string",
    "\tColorDark  string",
    "}",
    "",
    "// GenLifecycle is the generated 1:1 mirror of tokens.lifecycle (glyph + hue).",
    "var GenLifecycle = map[string]GenLifecycleToken{",
    ...alignMap(rows),
    "}",
    "",
    "// GenLifecycleOrder is the canonical emission order (matches the source).",
    `var GenLifecycleOrder = []string{${LIFE_ORDER.map((s) => `"${s}"`).join(", ")}}`,
    "",
    "// GenBrailleFrames mirrors lifecycle.in_progress.frames (spinner.go).",
    `var GenBrailleFrames = [10]string{${frames}}`,
    "",
    "// GenBrailleStill is the reduced-motion steady frame.",
    `var GenBrailleStill = "${glyphOf(life.in_progress.framesStill)}"`,
    "",
    // ── theme resolution seam (ts-w4c) ──────────────────────────────────────
    "// DefaultTheme is the built-in evergreen skin. Resolve defaults to it for an",
    "// unknown/empty theme id; theme.go's buildPalette reads Resolve(theme).Lifecycle.",
    `const DefaultTheme = ${JSON.stringify(DEFAULT_THEME)}`,
    "",
    "// ThemeLifecycle bundles one theme's lifecycle token map + braille frames.",
    "type ThemeLifecycle struct {",
    ...alignFields([
      "\tLifecycle map[string]GenLifecycleToken",
      "\tBrailleFrames [10]string",
      "\tBrailleStill string",
    ]),
    "}",
    "",
    "// genLifecycleThemes keys each theme's lifecycle set by id (evergreen REFERENCES",
    "// GenLifecycle/GenBrailleFrames/GenBrailleStill — no re-typed literals).",
    "var genLifecycleThemes = map[string]ThemeLifecycle{",
    ...themes.flatMap(themeEntry),
    "}",
    "",
    "// Resolve returns a theme's lifecycle token set, defaulting to evergreen for an",
    "// unknown or empty id.",
    "func Resolve(theme string) ThemeLifecycle {",
    "\tif t, ok := genLifecycleThemes[theme]; ok {",
    "\t\treturn t",
    "\t}",
    "\treturn genLifecycleThemes[DefaultTheme]",
    "}",
    "",
  ].join("\n");
}

// ── surface: Go pdrender (internal/pdrender/tokens_gen.go) ────────────────────
// Reading tokens + the four semantic status tones as hex AdaptiveColors.
// Additive stub — pdrender's hand-tuned tone*/pd* vars are untouched.
function pdrenderGo(themes = loadThemes()) {
  const c = tokens.color;
  const st = c.status;
  const r = tokens.type.reading;
  const tone = (name, role) =>
    `\tGenTone${name} = lipgloss.AdaptiveColor{Light: "${hslToHex(st[role].light)}", Dark: "${hslToHex(st[role].dark)}"}`;
  // Chrome + reading-accent AdaptiveColors (color.* → hex). Unconsumed until
  // wave 2 (S7: pdAccent/L2/links → GenPrimary, pdTerra → GenReadingAccent).
  const chrome = (name, role) =>
    `\tGen${name} = lipgloss.AdaptiveColor{Light: "${hslToHex(c[role].light)}", Dark: "${hslToHex(c[role].dark)}"}`;
  // Code-block tones (color.code → hex; stored as hex directly, no HSL hop).
  // Additive: pdrender's ingress points at GenInk in a later wave.
  const code = (name, sub) =>
    `\tGenCode${name} = lipgloss.AdaptiveColor{Light: "${c.code[sub].light}", Dark: "${c.code[sub].dark}"}`;
  // CLI-chrome tones (color.cliChrome → hex; hex directly). pdrender's OWN copy
  // of the four chrome roles it threads (accent/ink/text-secondary/dim) — it may
  // import only lipgloss+x/ansi+stdlib, so it can NEVER read internal/semrole's
  // GenChrome* twins; these are byte-identical siblings. NOT the color.text/
  // muted-text reading family above (GenInk/GenDim are a DIFFERENT, warmer set).
  const cliChrome = (name, role) =>
    `\tGenChrome${name} = lipgloss.AdaptiveColor{Light: "${c.cliChrome[role].light}", Dark: "${c.cliChrome[role].dark}"}`;
  // Neutral callout tone (color.cliCalloutNeutral → hex) — the neutral peer of
  // the four status tones, consumed by Theme.Callout's "neutral" arm.
  const neut = c.cliCalloutNeutral;
  // The evergreen genPalette entry, byte-for-byte as before (Gen* references so
  // N=1 is byte-identical); a non-evergreen entry stamps literals from its skin.
  const EVERGREEN_FIELDS = [
    "\t\tChromeAccent: GenChromeAccent,",
    "\t\tChromeInk: GenChromeInk,",
    "\t\tChromeTextSecondary: GenChromeTextSecondary,",
    "\t\tChromeDim: GenChromeDim,",
    "\t\tRule: GenRule,",
    "\t\tCodeFg: GenCodeFg,",
    "\t\tCodeBg: GenCodeBg,",
    "\t\tReadingMuted: GenDim,",
    "\t\tReadingAccent: GenReadingAccent,",
    "\t\tToneInfo: GenToneInfo,",
    "\t\tToneOK: GenToneOK,",
    "\t\tToneWarn: GenToneWarn,",
    "\t\tToneDanger: GenToneDanger,",
    "\t\tToneNeutral: GenToneNeutral,",
  ];
  const litFields = (p) => {
    const col = p.color;
    const hx = (o) => goAdaptive(o.light, o.dark);            // stored hex (chrome/code/neutral)
    const hs = (o) => goAdaptive(hslToHex(o.light), hslToHex(o.dark)); // HSL channels → hex
    return [
      `\t\tChromeAccent: ${hx(col.cliChrome["chrome-accent"])},`,
      `\t\tChromeInk: ${hx(col.cliChrome["chrome-ink"])},`,
      `\t\tChromeTextSecondary: ${hx(col.cliChrome["chrome-text-secondary"])},`,
      `\t\tChromeDim: ${hx(col.cliChrome["chrome-dim"])},`,
      `\t\tRule: ${hs(col.border)},`,
      `\t\tCodeFg: ${hx(col.code.fg)},`,
      `\t\tCodeBg: ${hx(col.code.bg)},`,
      `\t\tReadingMuted: ${hs(col["muted-text"])},`,
      `\t\tReadingAccent: ${hs(col["reading-accent"])},`,
      `\t\tToneInfo: ${hs(col.status.info)},`,
      `\t\tToneOK: ${hs(col.status.ok)},`,
      `\t\tToneWarn: ${hs(col.status.warn)},`,
      `\t\tToneDanger: ${hs(col.status.danger)},`,
      `\t\tToneNeutral: ${hx(col.cliCalloutNeutral)},`,
    ];
  };
  const pdThemeEntry = ({ name, spec }) => [
    `\t${JSON.stringify(name)}: {`,
    ...alignMap(name === DEFAULT_THEME ? EVERGREEN_FIELDS : litFields(themePalette(spec))),
    "\t},",
  ];
  return [
    goHeader("pdrender"),
    'import "github.com/charmbracelet/lipgloss"',
    "",
    "// Generated semantic status tones (design/tokens.json color.status → hex).",
    "var (",
    ...alignEq([tone("Info", "info"), tone("OK", "ok"), tone("Warn", "warn"), tone("Danger", "danger")]),
    ")",
    "",
    "// Generated neutral callout tone (design/tokens.json color.cliCalloutNeutral).",
    `var GenToneNeutral = lipgloss.AdaptiveColor{Light: "${neut.light}", Dark: "${neut.dark}"}`,
    "",
    "// Generated chrome + reading-accent tokens (design/tokens.json color.* → hex).",
    "var (",
    ...alignEq([
      chrome("Primary", "primary"), chrome("PrimaryFg", "primary-fg"),
      chrome("Ink", "text"), chrome("Dim", "muted-text"), chrome("Rule", "border"),
      chrome("ReadingAccent", "reading-accent"),
    ]),
    ")",
    "",
    "// Generated CLI-chrome tokens (design/tokens.json color.cliChrome → hex).",
    "// pdrender's own copy (it can't import internal/semrole); referenced by the",
    "// evergreen genPalette entry below and threaded through theme.go's buildTheme",
    "// (pal.ChromeAccent/ChromeInk/ChromeTextSecondary/ChromeDim, via Resolve).",
    "var (",
    ...alignEq([
      cliChrome("Accent", "chrome-accent"), cliChrome("Ink", "chrome-ink"),
      cliChrome("TextSecondary", "chrome-text-secondary"), cliChrome("Dim", "chrome-dim"),
    ]),
    ")",
    "",
    "// Generated code-block tones (design/tokens.json color.code → hex).",
    "var (",
    ...alignEq([code("Fg", "fg"), code("Bg", "bg")]),
    ")",
    "",
    "// Generated reading tokens (design/tokens.json font.reading / type.reading).",
    "const (",
    `\tGenReadingFontStack     = ${JSON.stringify(tokens.font.reading.stack)}`,
    `\tGenReadingHeadingWeight = ${r.headingWeight}`,
    `\tGenReadingBodySize      = ${r.body.size}`,
    ")",
    "",
    "// Generated categorical viz palettes (design/tokens.json color.pdrenderChart /",
    "// color.pdrenderHeatmap → hex). NOT status roles — theme-invariant categorical",
    "// data-viz values (the presence / matchQuality passthrough precedent, D21).",
    "// GenChartSeries is chart.go's per-series TrueColor cycle; GenHeatmapBase/Peak",
    "// are heatmap.go's dark→bright gradient endpoints. Byte-faithful to the former",
    "// hand literals, so the render is unchanged. GenHeatRamp is the 4 discrete shade",
    "// steps (light→full) heatmap.go's quantile dual-encode paints as each glyph bin's",
    "// Foreground — ramp[3] == GenHeatmapPeak so the discrete scale meets the gradient.",
    "var GenChartSeries = []lipgloss.Color{",
    ...tokens.color.pdrenderChart.series.map((h) => `\tlipgloss.Color(${JSON.stringify(h)}),`),
    "}",
    "",
    "var GenHeatRamp = []lipgloss.Color{",
    ...tokens.color.pdrenderHeatmap.ramp.map((h) => `\tlipgloss.Color(${JSON.stringify(h)}),`),
    "}",
    "",
    "const (",
    `\tGenHeatmapBase = ${JSON.stringify(tokens.color.pdrenderHeatmap.base)}`,
    `\tGenHeatmapPeak = ${JSON.stringify(tokens.color.pdrenderHeatmap.peak)}`,
    ")",
    "",
    // ── theme resolution seam (ts-w4c) ──────────────────────────────────────
    "// DefaultTheme is the built-in evergreen skin. Resolve defaults to it for any",
    "// unknown/empty theme id, so today (evergreen-only) every id yields these exact",
    "// bytes — the styleguide golden stays frozen. Adding theme N+1 grows genPalette",
    "// (one keyed entry); theme.go's buildTheme already reads Resolve(themeID).",
    `const DefaultTheme = ${JSON.stringify(DEFAULT_THEME)}`,
    "",
    "// Palette is one theme's resolved pdrender token set. The Chrome* roles are the",
    "// zinc cliChrome family (ChromeInk/ChromeDim are NOT the warmer reading Ink/Dim —",
    "// the decoy guard theme.go documents); ReadingMuted/ReadingAccent are the reading",
    "// family; Tone* are the semantic status tones the Callout builder paints.",
    "type Palette struct {",
    ...alignFields([
      "\tChromeAccent lipgloss.AdaptiveColor",
      "\tChromeInk lipgloss.AdaptiveColor",
      "\tChromeTextSecondary lipgloss.AdaptiveColor",
      "\tChromeDim lipgloss.AdaptiveColor",
      "\tRule lipgloss.AdaptiveColor",
      "\tCodeFg lipgloss.AdaptiveColor",
      "\tCodeBg lipgloss.AdaptiveColor",
      "\tReadingMuted lipgloss.AdaptiveColor",
      "\tReadingAccent lipgloss.AdaptiveColor",
      "\tToneInfo lipgloss.AdaptiveColor",
      "\tToneOK lipgloss.AdaptiveColor",
      "\tToneWarn lipgloss.AdaptiveColor",
      "\tToneDanger lipgloss.AdaptiveColor",
      "\tToneNeutral lipgloss.AdaptiveColor",
    ]),
    "}",
    "",
    "// genPalette keys each theme's Palette by id. Values REFERENCE the Gen* vars",
    "// above (no re-typed literals) so the evergreen skin is byte-identical to them.",
    "var genPalette = map[string]Palette{",
    ...themes.flatMap(pdThemeEntry),
    "}",
    "",
    "// Resolve returns the pdrender Palette for a theme id, defaulting to evergreen",
    "// for an unknown or empty id (never a partial/zero palette).",
    "func Resolve(theme string) Palette {",
    "\tif p, ok := genPalette[theme]; ok {",
    "\t\treturn p",
    "\t}",
    "\treturn genPalette[DefaultTheme]",
    "}",
    "",
  ].join("\n");
}

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

// ── surface: Elixir render tokens (api/.../render/tokens_gen.ex) ──────────────
// Whole generated Elixir module for the paper render surface (emails + article
// palettes): evergreen brand + foreground, rule, the four status tones, the
// tokenized terracotta reading accent, and the reading type. kind "elixir"
// (whole-file, like go/ts): check.mjs Part A byte-compares it. Additive — do
// NOT edit palettes.ex; that consumer lands in wave 2 (Decision 8).
function elixirTokensGen(themes = loadThemes()) {
  const r = tokens.type.reading; // reading type is theme-INVARIANT
  // Every COLOUR-bearing @attr is a per-theme map. Each theme's values come from
  // themePalette(spec) — for evergreen that equals the base tokens byte-for-byte
  // (check.mjs Part F: derive(evergreen) === tokens.json), so N=1 is byte-identical;
  // a non-evergreen theme yields its own literal hex. All Elixir values are LITERAL
  // hex (no Gen* var indirection), so every theme entry is uniform.
  const statusEntry = ({ name, spec }) => {
    const st = themePalette(spec).color.status;
    const h = (role) => hslToHex(st[role].light);
    return `${name}: %{ok: "${h("ok")}", info: "${h("info")}", warn: "${h("warn")}", danger: "${h("danger")}"}`;
  };
  const readingAccentEntry = ({ name, spec }) =>
    `${name}: "${hslToHex(themePalette(spec).color["reading-accent"].light)}"`;
  const EMAIL_KEYS = [
    ["brand", "brand"], ["brand_text", "brand-text"], ["rule", "rule"],
    ["page_bg", "page-bg"], ["paper", "paper"], ["text", "text"],
    ["muted", "muted"], ["code_bg", "code-bg"],
  ];
  const emailEntry = ({ name, spec }, last) => {
    const em = themePalette(spec).color.paperEmail;
    return [
      `    ${name}: %{`,
      ...EMAIL_KEYS.map(([k, src], i) => `      ${k}: "${em[src]}"${i === EMAIL_KEYS.length - 1 ? "" : ","}`),
      `    }${last ? "" : ","}`,
    ];
  };
  const calloutEntry = ({ name, spec }, last) => {
    const co = themePalette(spec).color.paperCallout.light;
    return [
      `    ${name}: %{`,
      ...CALLOUT_TONES.map((t, i) => `      ${t}: %{bg: "${co[t].bg}", fg: "${co[t].fg}"}${i === CALLOUT_TONES.length - 1 ? "" : ","}`),
      `    }${last ? "" : ","}`,
    ];
  };
  const isLast = (i) => i === themes.length - 1;
  return [
    "# Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "# Regenerate: node design/emit.mjs --write",
    "",
    "defmodule Barkpark.PortableDoc.Render.TokensGen do",
    '  @moduledoc """',
    "  Unified Aesthetic tokens for the paper render surface (emails + article",
    "  palettes), generated from design/tokens.json. Regenerate with",
    "  `node design/emit.mjs --write`; never hand-edit. Emits the verbatim",
    "  paper-email skin (email_* — consumed by palettes.ex / data_viz.ex), the",
    "  callout tone tints (callout/2 — util.ex tone_palette/1), the semantic",
    "  status tones, and the tokenized reading accent + reading type. The email",
    "  brand/rule are the verbatim email_* hex, NOT color.primary/border (those",
    "  HSL-derived slots are drifted from the byte-locked email golden; w3",
    "  reconciles the two).",
    "",
    "  ## Theme-keying (charter D28)",
    "",
    "  Every COLOUR-bearing token is theme-keyed: the value lives in a per-theme",
    "  map and the accessor takes an optional `theme` defaulting `:evergreen`.",
    "  `evergreen` is the only theme this wave; an unknown / empty / binary theme",
    "  resolves to `:evergreen` (Resolve semantics). Adding theme N+1 is one more",
    "  key in each map — no accessor changes. Non-colour tokens (reading_font /",
    "  heading weight / body size) are theme-INVARIANT and stay plain.",
    '  """',
    "",
    "  # Known theme ids (evergreen only this wave). resolve/1 folds an unknown /",
    "  # empty / binary theme onto :evergreen so every accessor is total.",
    `  @themes [${themes.map((t) => ":" + t.name).join(", ")}]`,
    "  @doc \"Known theme ids (evergreen this wave).\"",
    "  def themes, do: @themes",
    "  defp resolve(theme) when theme in @themes, do: theme",
    "",
    "  defp resolve(theme) when is_binary(theme),",
    "    do: Enum.find(@themes, :evergreen, &(Atom.to_string(&1) == theme))",
    "",
    "  defp resolve(_), do: :evergreen",
    "",
    "  # Semantic status tones (design/tokens.json color.status, light theme → hex).",
    // One entry per LINE, for the same reason `@reading_font` is an attribute
    // below: `mix format` splits any map literal past 98 columns, and this one
    // crossed that the moment the theme count went from 1 to 5. A single-line
    // emit was a format fixed point at N=1 and silently stopped being one — the
    // drift gate then fires on the NEXT person to run the formatter, blaming
    // them for a latent property of the emitter. Per-line is a fixed point at
    // every N. (Each inner status map stays on one line: ~78 columns at the
    // longest theme name, comfortably under the limit.)
    "  @status %{",
    ...themes.map((t, i) => `    ${statusEntry(t)}${isLast(i) ? "" : ","}`),
    "  }",
    "  def tone_ok(theme \\\\ :evergreen), do: @status[resolve(theme)].ok",
    "  def tone_info(theme \\\\ :evergreen), do: @status[resolve(theme)].info",
    "  def tone_warn(theme \\\\ :evergreen), do: @status[resolve(theme)].warn",
    "  def tone_danger(theme \\\\ :evergreen), do: @status[resolve(theme)].danger",
    "",
    "  # Warm reading accent — the paper terracotta, tokenized.",
    // Per-line for the same reason as `@status` above.
    "  @reading_accent %{",
    ...themes.map((t, i) => `    ${readingAccentEntry(t)}${isLast(i) ? "" : ","}`),
    "  }",
    "  def reading_accent(theme \\\\ :evergreen), do: @reading_accent[resolve(theme)]",
    "",
    "  # Reading type (design/tokens.json font.reading / type.reading). Theme-INVARIANT.",
    // Via a module attribute so the long font-stack literal is a `mix format`
    // fixed point — a bare `def _, do: "<long>"` gets reflowed, which would flap
    // the byte-exact drift gate the moment anyone runs the formatter.
    `  @reading_font ${JSON.stringify(tokens.font.reading.stack)}`,
    "  def reading_font, do: @reading_font",
    `  def reading_heading_weight, do: ${r.headingWeight}`,
    `  def reading_body_size, do: ${r.body.size}`,
    "",
    // ── Paper EMAIL surface skin (theme-system Wave 1 CAPTURE — tokens.json
    // paperEmail). Verbatim hand values, NOT derived from color.primary/border:
    // those HSL-round-tripped brand/rule slots ABOVE (#1e5243/#e4e4e7) are drifted
    // from the live email hexes (#1e5347/#dde7e2), so palettes.ex / data_viz.ex
    // consume THESE instead — zero email-golden retint. w3 reconciles the two.
    "  # Paper email surface — verbatim hand hex (light-only; email has no dark mode).",
    "  @email %{",
    ...themes.flatMap((t, i) => emailEntry(t, isLast(i))),
    "  }",
    '  @doc "The whole per-theme email skin map (palettes.ex / data_viz.ex read it in one shot)."',
    "  def email_skin(theme \\\\ :evergreen), do: @email[resolve(theme)]",
    "  def email_brand(theme \\\\ :evergreen), do: email_skin(theme).brand",
    "  def email_brand_text(theme \\\\ :evergreen), do: email_skin(theme).brand_text",
    "  def email_rule(theme \\\\ :evergreen), do: email_skin(theme).rule",
    "  def email_page_bg(theme \\\\ :evergreen), do: email_skin(theme).page_bg",
    "  def email_paper(theme \\\\ :evergreen), do: email_skin(theme).paper",
    "  def email_text(theme \\\\ :evergreen), do: email_skin(theme).text",
    "  def email_muted(theme \\\\ :evergreen), do: email_skin(theme).muted",
    "  def email_code_bg(theme \\\\ :evergreen), do: email_skin(theme).code_bg",
    "",
    // ── Paper CALLOUT tones (tokens.json paperCallout). The five light {bg,fg}
    // tint pairs util.ex tone_palette/1 emits — a DIFFERENT value set from the
    // status tone_* roles above; never fold them together.
    "  # Callout tone tints — verbatim {bg, fg} pairs (util.ex tone_palette/1).",
    "  @callout %{",
    ...themes.flatMap((t, i) => calloutEntry(t, isLast(i))),
    "  }",
    "  def callout(tone, theme \\\\ :evergreen)",
    ...CALLOUT_TONES.map(
      (t) => `  def callout(:${t}, theme), do: @callout[resolve(theme)].${t}`,
    ),
    "end",
    "",
  ].join("\n");
}

// ── surface: Studio categorical tokens (api/.../studio/tokens_gen.ex) ─────────
// Whole generated Elixir module for the STUDIO surface's CATEGORICAL palettes:
// the 8 presence-avatar hues + the two Sheets-CF swatch lists (pastel cell/rule
// backgrounds + saturated per-tab dots). These are HEX VALUE lists, not status
// roles and not CSS vars — the swatch hex is PERSISTED DATA (stored on the
// cell/rule/tab, compared for selection, echoed in data-test-id), so the
// concrete literal must survive. kind "elixir" (whole-file, like the render
// TokensGen); check.mjs Part A byte-compares it. Distinct module from the
// paper-render TokensGen — different layer, different consumer.
function studioTokensGen() {
  const p = tokens.color.presence.palette;
  const cf = tokens.color.sheetCf;
  const sh = tokens.color.statusHealth;
  const fs = tokens.color.fleetStatus;
  const list = (arr) => arr.map((h) => `"${h}"`).join(", ");
  const life = tokens.lifecycle;
  const lifeRows = LIFE_ORDER.map((s) => {
    const e = life[s];
    return `      %{state: "${s}", glyph: "${glyphOf(e.codepoint)}", ascii: ${JSON.stringify(e.asciiGlyph)}, light: "${e.color.light}", dark: "${e.color.dark}"}`;
  }).join(",\n");
  const frames = life.in_progress.frames.map(glyphOf).join(" ");
  return [
    "# Code generated by design/emit.mjs from design/tokens.json. DO NOT EDIT.",
    "# Regenerate: node design/emit.mjs --write",
    "",
    "defmodule BarkparkWeb.Studio.TokensGen do",
    '  @moduledoc """',
    "  Unified Aesthetic Studio-surface tokens, generated from design/tokens.json.",
    "  Regenerate with `node design/emit.mjs --write`; never hand-edit.",
    "",
    "  Two families live here, both as returned VALUES (not CSS vars):",
    "",
    "    * CATEGORICAL identity swatches (presence + Sheets-CF hex lists): presence",
    "      hues index by a phash2 of the user id, and the Sheets-CF swatches are",
    "      PERSISTED DATA (stored on the cell/rule/tab, compared for selection,",
    "      echoed in data-test-id) — the concrete hex must survive.",
    "    * The LIFECYCLE mirror (glyph / ascii / adaptive hue per state) — the",
    "      Studio twin of the ONE lifecycle source (tokens.lifecycle) the Go board",
    "      + paper-surface CSS also emit from. It feeds the living styleguide's",
    "      lifecycle row (glyph + braille + colour label); the applied glyph COLOUR",
    "      comes from the emitted --life-<state> CSS var, so no hex is ever painted",
    "      inline. design/check.mjs §6 gates this mirror against Go + CSS + tokens.",
    '  """',
    "",
    "  # Presence-avatar palette (presence_state.ex @colors) — 8 fixed categorical",
    "  # hues; a phash2 of the user id picks one.",
    `  def presence_palette, do: ~w(${p.join(" ")})`,
    "",
    "  # Sheets conditional-format cell/rule backgrounds — the pastel fills",
    "  # (sheet_grid.ex bg-swatch loop). PERSISTED as phx-value-bg.",
    `  def sheet_cf_backgrounds, do: ~w(${cf.background.join(" ")})`,
    "",
    "  # Sheets per-tab colors — the saturated dot strip (sheet_grid.ex tab-color",
    "  # picker). Read best more vivid than the pastel cell backgrounds.",
    `  def sheet_tab_colors, do: ~w(${cf.tab.join(" ")})`,
    "",
    "  # Public status-page health-severity DATA tones (status_controller.ex",
    "  # @labels + component dots) — inline-style hex conveying OUTAGE SEVERITY,",
    "  # NOT a CSS role. partial_outage is an out-of-model tone between warn-amber",
    "  # (degraded) and danger-red (major_outage): the severity distinction must",
    "  # survive, so it is NOT recolored onto --warn/--danger.",
    // Emitted in the mix-format-STABLE multi-line shape: the one-line
    // `def status_health, do: %{…}` exceeds the 98-col default and mix format
    // wraps it, so a one-line emission made the drift gate and the Format gate
    // permanently disagree (only one could pass). Emit the wrapped form both
    // agree on.
    "  def status_health,",
    "    do: %{",
    `      operational: "${sh.operational}",`,
    `      degraded: "${sh.degraded}",`,
    `      partial_outage: "${sh.partial_outage}",`,
    `      major_outage: "${sh.major_outage}"`,
    "    }",
    "",
    "  # Neutral gray fallback for an unrecognised / missing status.",
    `  def status_health_unknown, do: "${sh.unknown}"`,
    "",
    "  # Personal Dev Fleet listener-status DATA tones (fleet_live.ex @pills dot +",
    "  # track tint at /admin/fleet) — the PDF-D23 vocabulary as inline-style hex,",
    "  # categorical listener-liveness DATA, not a CSS role. STRING keys: the",
    "  # consumer keys by the runtime status string; an unrecognised status falls",
    "  # back to \"idle\" in FleetLive.pill/1.",
    "  def fleet_status,",
    "    do: %{",
    `      "working" => "${fs.working}",`,
    `      "idle" => "${fs.idle}",`,
    `      "blocked" => "${fs.blocked}",`,
    `      "provisioning" => "${fs.provisioning}",`,
    `      "offline" => "${fs.offline}"`,
    "    }",
    "",
    "  # Lifecycle mirror — one row per state, canonical emission order. glyph +",
    "  # ascii are text CONTENT; light/dark are the adaptive hue LABELS (the applied",
    "  # colour is var(--life-<state>) from the GENERATED CSS block). Mirrors",
    "  # tokens.lifecycle 1:1; done/closed stay TEAL, distinct from status.ok green.",
    "  def lifecycle do",
    "    [",
    lifeRows,
    "    ]",
    "  end",
    "",
    "  # in_progress braille spinner frames (spinner.go / tokens.lifecycle frames).",
    `  def lifecycle_frames, do: ~w(${frames})`,
    "end",
    "",
  ].join("\n");
}

// ── page-scoped surfaces (self-contained Studio pages) ───────────────────────
// The login / error / status / sheets pages each carry their OWN scoped <style>
// (:root or a scoped selector) — the root-layout emitted tokens do NOT cascade
// in — so each de-literalizes onto its OWN page-scoped marker-splice block.
// These are CSS artifacts like the surfaces above, but their marker sits inside
// an .ex/.heex <style> (heredoc or ~H), so each builder bakes the page's own
// indentation. An "hsl OR var() OR #hex passthrough" value formatter lets a
// value be a token channel (→ hsl()), a var(--role) reference, or a raw hex.
const pageVal = (v) => (v.startsWith("var(") || v.startsWith("#") ? v : hsl(v));

// ── surface: login (api/lib/barkpark_web/controllers/session_html.ex) ────────
// The auth pages' brand override — evergreen --primary/--ring (the exact emitted
// primary/ring tokens) + the decoupled auth button fills (color.authButton),
// scoped under .bp-auth. Light on the scoped selector; dark keyed on
// html[data-theme="dark"] .bp-auth (Studio themes via the data-theme attribute).
// Indented 6 spaces to sit inside the ~H <style>. The ring-soft alpha reuses the
// shared softAlpha convention (0.15 light / 0.2 dark).
// The auth brand-override rows for one mode, from a palette `t`. primary/primary-
// fg/ring are theme-varying; the --btn-* auth-button fills are theme-invariant
// passthrough (color.authButton), but they are NOT positionally counted by
// check.mjs, so they are safely re-declared in the per-theme block (D25 only bans
// --life-*/--provider-*/.bp-lg--/.bp-inst--).
const authRows = (theme, t = tokens) => {
  const c = t.color;
  const ab = c.authButton;
  return [
    `--primary: ${hsl(c.primary[theme])};`,
    `--primary-fg: ${hsl(c["primary-fg"][theme])};`,
    `--ring: ${hsl(c.ring[theme])};`,
    `--ring-soft: hsl(${c.ring[theme]} / ${alpha(softAlpha[theme])});`,
    `--btn-bg: ${pageVal(ab.bg[theme])};`,
    `--btn-fg: ${pageVal(ab.fg[theme])};`,
    `--btn-bg-hover: ${pageVal(ab.bgHover[theme])};`,
  ];
};

const sessionAuthThemeBlock = (name, t) => {
  const ind = "      ";
  return [
    ind + `html[data-bp-theme="${name}"] .bp-auth {`,
    ...authRows("light", t).map((l) => ind + "  " + l),
    ind + "}",
    ind + `html[data-bp-theme="${name}"][data-theme="dark"] .bp-auth {`,
    ...authRows("dark", t).map((l) => ind + "  " + l),
    ind + "}",
  ].join("\n");
};

function sessionAuthBlock(themes = loadThemes()) {
  const ind = "      ";
  const lines = [
    ind + ".bp-auth {",
    ...authRows("light").map((l) => ind + "  " + l),
    // Motion ladder on the login card's own root scope (the page has no other):
    // `.bp-auth-btn` is a descendant, so the ladder reaches it by inheritance.
    ...motionVarLines().map((l) => ind + "  " + l),
    ind + "}",
    ind + 'html[data-theme="dark"] .bp-auth {',
    ...authRows("dark").map((l) => ind + "  " + l),
    ind + "}",
  ];
  const themed = themeBlocks(themes, sessionAuthThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: error page (api/lib/barkpark_web/controllers/error_html.ex) ─────
// The 404/500 page is INTENTIONALLY ALWAYS-DARK (a stark error card, no theme
// switch). De-literalized WITHOUT becoming theme-aware: a single fixed-dark
// :root carrying color.errorPage (bg/fg/muted, single values). Indented 10
// spaces to sit inside the heredoc <style>.
function errorPageBlock() {
  const e = tokens.color.errorPage;
  const ind = "          ";
  return [
    ind + ":root {",
    ind + `  --err-bg: ${e.bg};`,
    ind + `  --err-fg: ${e.fg};`,
    ind + `  --err-muted: ${e.muted};`,
    ind + "}",
  ].join("\n");
}

// ── surface: status page (api/lib/barkpark_web/controllers/status_controller.ex)
// The public /status page's self-contained chrome palette (color.statusChrome,
// theme-aware via prefers-color-scheme). color-scheme + the health-severity DATA
// tones stay OUTSIDE this block — the tones are inline-style DATA emitted via
// BarkparkWeb.Studio.TokensGen.status_health/0. Indented 6 spaces (heredoc
// <style>). Hex passthrough (bespoke zinc, byte-preserving the chrome).
// statusChrome is a theme-INVARIANT passthrough family (charter D21), so the
// per-theme block re-declares the same bespoke zinc under the attribute hook —
// the structural guarantee that theme identity reaches every surface even where
// its palette does not vary. MEDIA surface: mode stays prefers-color-scheme, so
// the per-theme dark re-declaration nests inside the same @media idiom.
const statusChromeVars = (sc, theme) =>
  ["bg", "fg", "muted", "card", "line"].map((r) => `--${r}:${sc[r][theme]};`).join(" ");

const statusChromeThemeBlock = (name, t) => {
  const sc = t.color.statusChrome;
  const ind = "      ";
  return [
    ind + `html[data-bp-theme="${name}"] { ${statusChromeVars(sc, "light")} }`,
    ind + `@media (prefers-color-scheme: dark){ html[data-bp-theme="${name}"]{ ${statusChromeVars(sc, "dark")} } }`,
  ].join("\n");
};

function statusChromeBlock(themes = loadThemes()) {
  const sc = tokens.color.statusChrome;
  const ind = "      ";
  const lines = [
    ind + `:root { ${statusChromeVars(sc, "light")} }`,
    ind + `@media (prefers-color-scheme: dark){ :root{ ${statusChromeVars(sc, "dark")} } }`,
  ];
  const themed = themeBlocks(themes, statusChromeThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: /sheets reader (api/lib/barkpark_web/layouts/sheets.html.heex) ──
// The parchment reader's info-blue link + focus ring (color.readerInfo): a
// WCAG-safe darker blue-600 on the light parchment, lifting to info-role
// blue-500 on the dark parchment. --ring binds to --info so the reader's focus
// rings stay blue (their prior hardcoded fallback intent). Indented 4 spaces
// (heex <style>). Sits AFTER the hand-authored parchment :root; global :root
// vars, so they cascade to .sheet-link / .btn / .sheet-* focus rules.
// readerInfo is a theme-INVARIANT passthrough family (charter D21); the per-theme
// block carries the same info-blue under the attribute hook. MEDIA surface: the
// per-theme dark re-declaration nests inside the same prefers-color-scheme idiom.
const sheetsThemeBlock = (name, t) => {
  const ri = t.color.readerInfo;
  const ind = "    ";
  return [
    ind + `html[data-bp-theme="${name}"] { --info: ${ri.light}; --ring: var(--info); }`,
    ind + `@media (prefers-color-scheme: dark) { html[data-bp-theme="${name}"] { --info: ${ri.dark}; } }`,
  ].join("\n");
};

function sheetsBlock(themes = loadThemes()) {
  const ri = tokens.color.readerInfo;
  const ind = "    ";
  const lines = [
    ind + `:root { --info: ${ri.light}; --ring: var(--info); }`,
    ind + `@media (prefers-color-scheme: dark) { :root { --info: ${ri.dark}; } }`,
  ];
  const themed = themeBlocks(themes, sheetsThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: /papers reader skin (api/lib/barkpark_web/layouts/bulldocs.html.heex)
// The reader article's `--paper-*` skin overrides (color.paper.reader) PLUS the
// mail-client popup chrome (color.mailChrome, the ONLY --mail-* copy, relocated
// into this one marker region). The reader is a HYBRID surface: default mode
// follows prefers-color-scheme, but the reader's dark/light toggle stamps
// html[data-theme] (pre-paint, localStorage `barkpark_theme` shared with
// Studio) and the explicit stamp wins — so every mode pair emits THREE ways:
// bare light fallback, @media dark (the no-JS/first-paint owner), and
// [data-theme] companions. The reader DELIBERATELY diverges from the shared
// paper-surface skin on --paper-rule (solid vs rgba) — never collapsed onto the
// shared tokens this wave (charter D4). The load-bearing rationale comments are
// emitted VERBATIM so `emit --write` preserves them; the callout --bp-tone-*
// dark re-stamps are sourced from color.paperCallout.dark (the light pairs feed
// TokensGen.callout/1) — byte-identical emission, single-sourced tone values.
// Indented 4 spaces to sit inside the reader <style>; the marker block is CSS
// comments, invisible to the browser.
// Bulldocs reader theme block. The reader defaults to the OS scheme, so the
// per-theme dark re-declarations nest inside the same @media idiom, prefixed
// with the theme attribute — PLUS `[data-theme]` companions (two attrs, so a
// toggled mode beats both the theme-light block and the base [data-theme]
// blocks that precede the themed region in the cascade). The reader page never
// stamps data-bp-theme today, so this block is the structural hook (a theme
// swap reaches the reader skin the moment a surface sets the attribute);
// reader-dark-parity stays green because the guard's edit-side scan reads
// paper-surface.css only, and the reader-coverage scan still finds these dark
// re-skins inside prefers-color-scheme blocks.
// PRINT — the reader's paged output. A paper prints as ink on white whatever
// the screen was wearing, and BOTH dark routes survive into paged output: a
// print preview keeps the OS `prefers-color-scheme` AND keeps whatever
// `data-theme` the pre-paint toggle stamped. The reader's @media print block
// (the hand region of bulldocs.html.heex) forces a white ground but never
// re-stamped the ink, so an OS-dark reader printed the DARK palette's ink onto
// that white — #e7ede9 on #fff, ~1.2:1, a page that looks blank.
//
// This re-stamps the LIGHT palette under print, from the SAME token data the
// light blocks above emit — never a hand-copy, so a palette edit reaches print
// with the rest of it (and the values stay inside the GENERATED marker, where
// check.mjs Part E's literal ledger does not count them).
//
// TWO selector shapes because the dark palette arrives two ways:
//   * the bare pair matches the `@media (prefers-color-scheme: dark)` block's
//     specificity exactly and wins on source order (it is emitted later);
//   * the `[data-theme]` pair matches `[data-theme="dark"]`'s specificity, so a
//     reader who explicitly toggled dark prints light as well.
// `root` is the ROOT-element selector the palette hangs off: `html` for the base
// palette, `html[data-bp-theme="x"]` for a theme. `[data-theme]` is appended as a
// COMPOUND (no space) because data-bp-theme and data-theme both sit on <html>.
const printRestamp = (root, lightLines) => {
  const sel = (tail) => `      ${root} ${tail}`;
  const selStamped = (tail) => `      ${root}[data-theme] ${tail}`;
  const art = "body:has(.bp-paper-article)";
  const shell = `${art} .bp-paper-shell.bp-paper-article`;
  return [
    "    /* PRINT: the LIGHT palette, re-stamped from the same token data as the",
    "       light blocks above — paged output is ink on white whatever the screen",
    "       scheme or the stamped [data-theme] was. See printRestamp in",
    "       design/emit.mjs; the white ground + chrome hiding stay in the hand",
    "       region's @media print block further down this sheet. */",
    "    @media print {",
    sel(art + ","),
    sel(shell + ","),
    selStamped(art + ","),
    selStamped(shell + " {"),
    ...lightLines.map((l) => "        " + l.trim()),
    "      }",
    "    }",
  ];
};

const bulldocsThemeBlock = (name, t) => {
  const rl = t.color.paper.reader.light;
  const rd = t.color.paper.reader.dark;
  const mc = t.color.mailChrome;
  const cd = t.color.paperCallout.dark;
  const p = `html[data-bp-theme="${name}"]`;
  // S7 stub: the warm reading accent (color.reading-accent, theme-derived),
  // UNCONSUMED until S8 reads it for the article terracotta.
  const ra = (theme) => `--paper-reading-accent: ${hslToHex(t.color["reading-accent"][theme])};`;
  const readerVars = (r, theme, extra = []) =>
    [
      `--paper-bg: ${r["bg"]};`,
      `--paper-bg-deep: ${r["bg-deep"]};`,
      `--paper-ink: ${r["ink"]};`,
      `--paper-ink-soft: ${r["ink-soft"]};`,
      `--paper-rule: ${r["rule"]};`,
      `--paper-accent: ${r["accent"]};`,
      `--paper-accent-soft: ${r["accent-soft"]};`,
      ra(theme),
      ...extra,
    ].map((l) => "        " + l);
  const darkExtra = [
    `--paper-ink-faint: ${rd["ink-faint"]};`,
    `--paper-chrome-bg: ${rd["chrome-bg"]};`,
    `--paper-chrome-border: ${rd["chrome-border"]};`,
    `--bp-tone-info-bg: ${cd.info.bg}; --bp-tone-info-fg: ${cd.info.fg};`,
    `--bp-tone-success-bg: ${cd.success.bg}; --bp-tone-success-fg: ${cd.success.fg};`,
    `--bp-tone-warning-bg: ${cd.warning.bg}; --bp-tone-warning-fg: ${cd.warning.fg};`,
    `--bp-tone-danger-bg: ${cd.danger.bg}; --bp-tone-danger-fg: ${cd.danger.fg};`,
    `--bp-tone-neutral-bg: ${cd.neutral.bg}; --bp-tone-neutral-fg: ${cd.neutral.fg};`,
  ];
  // The [data-theme="light"] companion must re-declare every token the reader's
  // @media dark block re-skins — the media block's selector outranks the bare
  // paper-surface light fallbacks, so a forced-light reader under an OS-dark
  // scheme would otherwise keep DARK callout tones / faint ink / chrome (the
  // mirror image of the #1217 bug). Light values come from the shared surface
  // family + paperCallout.light — the same values the un-stamped light path
  // resolves through paper-surface.css.
  const sf = t.color.paper.surface;
  const cl = t.color.paperCallout.light;
  const lightExtra = [
    `--paper-ink-faint: ${sf["ink-faint"].light};`,
    `--paper-chrome-bg: ${sf["chrome-bg"].light};`,
    `--paper-chrome-border: ${sf["chrome-border"].light};`,
    `--bp-tone-info-bg: ${cl.info.bg}; --bp-tone-info-fg: ${cl.info.fg};`,
    `--bp-tone-success-bg: ${cl.success.bg}; --bp-tone-success-fg: ${cl.success.fg};`,
    `--bp-tone-warning-bg: ${cl.warning.bg}; --bp-tone-warning-fg: ${cl.warning.fg};`,
    `--bp-tone-danger-bg: ${cl.danger.bg}; --bp-tone-danger-fg: ${cl.danger.fg};`,
    `--bp-tone-neutral-bg: ${cl.neutral.bg}; --bp-tone-neutral-fg: ${cl.neutral.fg};`,
  ];
  const mailVars = (theme) =>
    [
      `--mail-paper: ${mc.paper[theme]}; --mail-bar: ${mc.bar[theme]}; --mail-rule: ${mc.rule[theme]};`,
      `--mail-ink: ${mc.ink[theme]}; --mail-soft: ${mc.soft[theme]}; --mail-accent: ${mc.accent[theme]};`,
    ].map((l) => "      " + l);
  return [
    `    ${p} body:has(.bp-paper-article),`,
    `    ${p} body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rl, "light").map((l) => l.replace(/^ {8}/, "      ")),
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    `      ${p} body:has(.bp-paper-article),`,
    `      ${p} body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rd, "dark", darkExtra),
    "      }",
    "    }",
    `    ${p} #bp-mailapp {`,
    ...mailVars("light"),
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    `      ${p} #bp-mailapp {`,
    ...mailVars("dark").map((l) => "  " + l),
    "      }",
    "    }",
    `    ${p}[data-theme="light"] body:has(.bp-paper-article),`,
    `    ${p}[data-theme="light"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rl, "light", lightExtra).map((l) => l.replace(/^ {8}/, "      ")),
    "    }",
    `    ${p}[data-theme="dark"] body:has(.bp-paper-article),`,
    `    ${p}[data-theme="dark"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rd, "dark", darkExtra).map((l) => l.replace(/^ {8}/, "      ")),
    "    }",
    `    ${p}[data-theme="light"] #bp-mailapp {`,
    ...mailVars("light"),
    "    }",
    `    ${p}[data-theme="dark"] #bp-mailapp {`,
    ...mailVars("dark"),
    "    }",
    ...printRestamp(p, readerVars(rl, "light", lightExtra)),
  ].join("\n");
};

function bulldocsBlock(themes = loadThemes()) {
  const rl = tokens.color.paper.reader.light;
  const rd = tokens.color.paper.reader.dark;
  const mc = tokens.color.mailChrome;
  const cd = tokens.color.paperCallout.dark; // dark callout tone re-stamps
  const cl = tokens.color.paperCallout.light; // light re-stamps for [data-theme="light"]
  const sfl = Object.fromEntries(
    ["ink-faint", "chrome-bg", "chrome-border"].map((r) => [r, tokens.color.paper.surface[r].light])
  );
  // S7 stub: the warm reading accent (color.reading-accent), UNCONSUMED until S8.
  const ra = (theme) => hslToHex(tokens.color["reading-accent"][theme]);
  const themed = themeBlocks(themes, bulldocsThemeBlock);
  return [
    "    /* MOTION ladder (tokens.motion) — theme-invariant, so it sits on the",
    "       page root rather than inside any of the reader's palette scopes. The",
    "       reader's own chrome (view toggle, action bar, mail popup) is the",
    "       consumer; a duration does not flip with a skin. */",
    "    :root {",
    motionVars("      "),
    "    }",
    "    /* Article chrome — applied only when BulldocsLive marks the doc as",
    "       `content[\"style\"] == \"article\"` (the LiveView stamps the",
    "       `.bp-paper-article` class on its <main>). Cool bp-theme page, a",
    "       centered ~720px reading column (incl. padding), serif base — so the",
    "       inline-styled article blocks sit on a proper page, not bare white",
    "       full-width. Non-article papers keep the dark chrome above, untouched.",
    "",
    "       READER SKIN: token overrides layered over the canonical paper-surface",
    "       source (embedded above). These `--paper-*` values are the historical",
    "       bp-theme reader look. They are set on the <body> AND on the reader",
    "       <main> (`.bp-paper-shell.bp-paper-article`, which now also carries",
    "       `bp-paper-surface`) so they WIN over the shared source's fallback",
    "       `.bp-paper-surface { --paper-* }` block — otherwise render.ex's inline",
    "       `var(--paper-*, hex)` block HTML would resolve to the Studio defaults on",
    "       the reader on the bp-theme (a shared ink #15211d, rule #dde7e2,",
    "       etc.). Dark-mode note: the reader stamps `html[data-theme]` only via",
    "       its pre-paint toggle script (localStorage `barkpark_theme`, shared",
    "       with Studio); before that script runs — and with JS off — the",
    "       `prefers-color-scheme: dark` block below (also carried onto <main>)",
    "       owns reader dark mode, flipping the palette to cool bp-dark with",
    "       light ink so the inline `var(--paper-*)` HTML stays readable. The",
    "       `html[data-theme]` companions further down repeat both palettes so an",
    "       explicit toggle beats the OS scheme. Without the <main>-scoped",
    "       override the shared light fallback would paint dark ink on the",
    "       browser's dark theme — the visibility bug. */",
    "    body:has(.bp-paper-article),",
    "    body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {",
    `      --paper-bg:         ${rl["bg"]};`,
    `      --paper-bg-deep:    ${rl["bg-deep"]};`,
    `      --paper-ink:        ${rl["ink"]};`,
    `      --paper-ink-soft:   ${rl["ink-soft"]};`,
    `      --paper-rule:       ${rl["rule"]};`,
    `      --paper-accent:     ${rl["accent"]};`,
    "      /* Link border-bottom tone (`.bp-paper-surface a` + walk.ex inline links",
    "         read it). Light value matches the shared source's fallback; the dark",
    "         block below MUST re-skin it — otherwise dark-mode link borders resolve",
    "         to this light rgba and vanish against the dark page. */",
    `      --paper-accent-soft: ${rl["accent-soft"]};`,
    `      --paper-reading-accent: ${ra("light")}; /* S7 stub — S8 consumes */`,
    "    }",
    "    body:has(.bp-paper-article) {",
    "      background: var(--paper-bg-deep);",
    "      color: var(--paper-ink);",
    "      font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Charter, Georgia, 'Source Serif 4', serif;",
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    "      body:has(.bp-paper-article),",
    "      body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {",
    `        --paper-bg:         ${rd["bg"]};`,
    `        --paper-bg-deep:    ${rd["bg-deep"]};`,
    `        --paper-ink:        ${rd["ink"]};`,
    `        --paper-ink-soft:   ${rd["ink-soft"]};`,
    `        --paper-rule:       ${rd["rule"]};`,
    `        --paper-accent:     ${rd["accent"]};`,
    "        /* Warm-dark link border (same value as Studio's html[data-theme=dark]",
    "           block in paper-surface.css) — without it links keep the light-theme",
    "           rgba(162,57,37,0.10) border, invisible on the dark page. */",
    `        --paper-accent-soft: ${rd["accent-soft"]};`,
    `        --paper-reading-accent: ${ra("dark")}; /* S7 stub — S8 consumes */`,
    "        /* Callout TONE tokens + faint ink + chrome — the SAME reason as the",
    "           --paper-* above: paper-surface.css keys their DARK values on",
    "           `html[data-theme=\"dark\"]`, which the reader stamps only after its",
    "           pre-paint toggle script runs, so an OS-dark reader (no JS / first",
    "           paint) was left with the LIGHT callout tones (#eff6ff on a #131d19",
    "           page — a light box on the dark article). Re-skin them here,",
    "           byte-mirroring the dark values in paper-surface.css's",
    "           `html[data-theme=\"dark\"] .bp-paper-surface` block. Edit surfaces",
    "           stamp data-theme and get those directly; this is the reader's",
    "           prefers-color-scheme companion. */",
    `        --paper-ink-faint:    ${rd["ink-faint"]};`,
    `        --paper-chrome-bg:    ${rd["chrome-bg"]};`,
    `        --paper-chrome-border: ${rd["chrome-border"]};`,
    `        --bp-tone-info-bg:    ${cd.info.bg}; --bp-tone-info-fg:    ${cd.info.fg};`,
    `        --bp-tone-success-bg: ${cd.success.bg}; --bp-tone-success-fg: ${cd.success.fg};`,
    `        --bp-tone-warning-bg: ${cd.warning.bg}; --bp-tone-warning-fg: ${cd.warning.fg};`,
    `        --bp-tone-danger-bg:  ${cd.danger.bg}; --bp-tone-danger-fg:  ${cd.danger.fg};`,
    `        --bp-tone-neutral-bg: ${cd.neutral.bg}; --bp-tone-neutral-fg: ${cd.neutral.fg};`,
    "      }",
    "    }",
    "    /* Mail-client popup chrome (color.mailChrome) — the --mail-* window skin",
    "       for the Email view, relocated here (from #bp-mailapp) so the reader",
    "       palette + the mail chrome are single-sourced in ONE marker region; the",
    "       #bp-mailapp consumers stay below. Theme-aware like a real dark mail",
    "       client showing a light HTML email; the served email bytes never change",
    "       with the theme. */",
    "    #bp-mailapp {",
    `      --mail-paper: ${mc.paper.light}; --mail-bar: ${mc.bar.light}; --mail-rule: ${mc.rule.light};`,
    `      --mail-ink: ${mc.ink.light}; --mail-soft: ${mc.soft.light}; --mail-accent: ${mc.accent.light};`,
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    "      #bp-mailapp {",
    `        --mail-paper: ${mc.paper.dark}; --mail-bar: ${mc.bar.dark}; --mail-rule: ${mc.rule.dark};`,
    `        --mail-ink: ${mc.ink.dark}; --mail-soft: ${mc.soft.dark}; --mail-accent: ${mc.accent.dark};`,
    "      }",
    "    }",
    "    /* Explicit mode stamp — html[data-theme] companions to the light",
    "       fallback + prefers-color-scheme pair above. The reader's pre-paint",
    "       <head> script stamps data-theme from localStorage `barkpark_theme`",
    "       (shared with Studio) or the OS scheme, and the dark/light toggle",
    "       pill rewrites it — one attribute of extra specificity, so a toggled",
    "       choice beats the @media blocks in BOTH directions. The @media pair",
    "       stays byte-complete as the no-JS / first-paint fallback (it is also",
    "       what the reader-dark-parity guard scans for coverage). */",
    '    html[data-theme="light"] body:has(.bp-paper-article),',
    '    html[data-theme="light"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {',
    `      --paper-bg:         ${rl["bg"]};`,
    `      --paper-bg-deep:    ${rl["bg-deep"]};`,
    `      --paper-ink:        ${rl["ink"]};`,
    `      --paper-ink-soft:   ${rl["ink-soft"]};`,
    `      --paper-rule:       ${rl["rule"]};`,
    `      --paper-accent:     ${rl["accent"]};`,
    `      --paper-accent-soft: ${rl["accent-soft"]};`,
    `      --paper-reading-accent: ${ra("light")}; /* S7 stub — S8 consumes */`,
    "      /* Light re-declarations for every token the @media dark block above",
    "         re-skins — its selector outranks the bare paper-surface light",
    "         fallbacks, so WITHOUT these a forced-light reader under an OS-dark",
    "         scheme keeps dark callout tones / faint ink / chrome (the mirror",
    "         image of the #1217 bug). Values match the un-stamped light path. */",
    `      --paper-ink-faint:    ${sfl["ink-faint"]};`,
    `      --paper-chrome-bg:    ${sfl["chrome-bg"]};`,
    `      --paper-chrome-border: ${sfl["chrome-border"]};`,
    `      --bp-tone-info-bg:    ${cl.info.bg}; --bp-tone-info-fg:    ${cl.info.fg};`,
    `      --bp-tone-success-bg: ${cl.success.bg}; --bp-tone-success-fg: ${cl.success.fg};`,
    `      --bp-tone-warning-bg: ${cl.warning.bg}; --bp-tone-warning-fg: ${cl.warning.fg};`,
    `      --bp-tone-danger-bg:  ${cl.danger.bg}; --bp-tone-danger-fg:  ${cl.danger.fg};`,
    `      --bp-tone-neutral-bg: ${cl.neutral.bg}; --bp-tone-neutral-fg: ${cl.neutral.fg};`,
    "    }",
    '    html[data-theme="dark"] body:has(.bp-paper-article),',
    '    html[data-theme="dark"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {',
    `      --paper-bg:         ${rd["bg"]};`,
    `      --paper-bg-deep:    ${rd["bg-deep"]};`,
    `      --paper-ink:        ${rd["ink"]};`,
    `      --paper-ink-soft:   ${rd["ink-soft"]};`,
    `      --paper-rule:       ${rd["rule"]};`,
    `      --paper-accent:     ${rd["accent"]};`,
    `      --paper-accent-soft: ${rd["accent-soft"]};`,
    `      --paper-reading-accent: ${ra("dark")}; /* S7 stub — S8 consumes */`,
    `      --paper-ink-faint:    ${rd["ink-faint"]};`,
    `      --paper-chrome-bg:    ${rd["chrome-bg"]};`,
    `      --paper-chrome-border: ${rd["chrome-border"]};`,
    `      --bp-tone-info-bg:    ${cd.info.bg}; --bp-tone-info-fg:    ${cd.info.fg};`,
    `      --bp-tone-success-bg: ${cd.success.bg}; --bp-tone-success-fg: ${cd.success.fg};`,
    `      --bp-tone-warning-bg: ${cd.warning.bg}; --bp-tone-warning-fg: ${cd.warning.fg};`,
    `      --bp-tone-danger-bg:  ${cd.danger.bg}; --bp-tone-danger-fg:  ${cd.danger.fg};`,
    `      --bp-tone-neutral-bg: ${cd.neutral.bg}; --bp-tone-neutral-fg: ${cd.neutral.fg};`,
    "    }",
    '    html[data-theme="light"] #bp-mailapp {',
    `      --mail-paper: ${mc.paper.light}; --mail-bar: ${mc.bar.light}; --mail-rule: ${mc.rule.light};`,
    `      --mail-ink: ${mc.ink.light}; --mail-soft: ${mc.soft.light}; --mail-accent: ${mc.accent.light};`,
    "    }",
    '    html[data-theme="dark"] #bp-mailapp {',
    `      --mail-paper: ${mc.paper.dark}; --mail-bar: ${mc.bar.dark}; --mail-rule: ${mc.rule.dark};`,
    `      --mail-ink: ${mc.ink.dark}; --mail-soft: ${mc.soft.dark}; --mail-accent: ${mc.accent.dark};`,
    "    }",
    ...printRestamp("html", [
      `--paper-bg:         ${rl["bg"]};`,
      `--paper-bg-deep:    ${rl["bg-deep"]};`,
      `--paper-ink:        ${rl["ink"]};`,
      `--paper-ink-soft:   ${rl["ink-soft"]};`,
      `--paper-rule:       ${rl["rule"]};`,
      `--paper-accent:     ${rl["accent"]};`,
      `--paper-accent-soft: ${rl["accent-soft"]};`,
      `--paper-reading-accent: ${ra("light")}; /* S7 stub — S8 consumes */`,
      `--paper-ink-faint:    ${sfl["ink-faint"]};`,
      `--paper-chrome-bg:    ${sfl["chrome-bg"]};`,
      `--paper-chrome-border: ${sfl["chrome-border"]};`,
      `--bp-tone-info-bg:    ${cl.info.bg}; --bp-tone-info-fg:    ${cl.info.fg};`,
      `--bp-tone-success-bg: ${cl.success.bg}; --bp-tone-success-fg: ${cl.success.fg};`,
      `--bp-tone-warning-bg: ${cl.warning.bg}; --bp-tone-warning-fg: ${cl.warning.fg};`,
      `--bp-tone-danger-bg:  ${cl.danger.bg}; --bp-tone-danger-fg:  ${cl.danger.fg};`,
      `--bp-tone-neutral-bg: ${cl.neutral.bg}; --bp-tone-neutral-fg: ${cl.neutral.fg};`,
    ]),
    ...(themed ? ["    " + THEME_BANNER, themed] : []),
  ].join("\n");
}

// The cloud SPA theme-id enum (app.js `var BP_THEMES = [ … ]`). loadThemes()
// leads with the default skin (evergreen) then dir order, so the emitted list is
// the SAME ordering every other generated enumeration uses (Go Themes(), the
// Studio picker, the CSS blocks). Indented 4 spaces to sit inside the array
// literal in the IIFE; no trailing comma or newline (the marker's END line
// carries the newline). This kills the GR12 drift: the SPA's identity picker
// reads BP_THEMES at runtime, so a new design/themes/<id>.json reaches the picker
// the moment `emit --write` runs — no second hand-list to forget.
export function bpThemesList(themes = loadThemes()) {
  return "    " + themes.map(({ name }) => JSON.stringify(name)).join(", ");
}

// ── the audit verb table (charter cch-w65; moved into the image cch-w69-s1) ──
// cloud/priv/audit-actions.json is the SOLE authority for the audit register's
// verb vocabulary. It lives under cloud/priv — NOT design/ — because its Elixir
// consumer compile-time-reads it inside the control-plane image build, and that
// image is built from cloud/ alone (D841/D842: the design/ home broke every cp
// deploy). Two artifacts read it and NEITHER reads the other:
//
//   • cloud/lib/barkpark_cloud/accounts/audit_event.ex derives @actions from
//     `actions[].verb` at COMPILE time (@external_resource + Jason.decode!), so
//     validate_inclusion(:action, @actions) still enforces the identical closed set.
//   • cloud/priv/static/app.js's ACTION_LABELS is the generated region below,
//     built from `actions[].label`.
//
// A row IS the declaration and its label rides ON that row, so there is no place
// to write a label for a verb the vocabulary does not declare — the shape makes
// that state unrepresentable rather than merely checked. `label: null` is the
// honest case charter D582 blessed (humanAction falls back to the raw dotted
// slug), but a null must CARRY its rationale: `reason_code` from the closed set
// the manifest itself declares, plus a `reason` that names the open row owning
// the copy (or, for a producerless verb, the census allowlist excusing it). That
// turns "unlabelled on purpose" from a discipline into a gate.
export const AUDIT_ACTIONS_PATH = "cloud/priv/audit-actions.json";
const VERB_RE = /^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/;
const REASON_MIN = 60;
// Per-code predicates the `reason` prose must satisfy. A minimum length alone
// buys mush; each code has to point at something that can rot loudly — the same
// property the Elixir census's @producerless anchor/blocker pair carries.
const REASON_MUST_CITE = {
  "d582-copy-not-written": {
    re: /cch-w\d+-[a-z0-9-]+/,
    what: "the `cch-w…` slug of the open row that owns the copy",
  },
  "no-producer": {
    re: /@producerless/,
    what: "`@producerless` — the census allowlist that already excuses the verb by name",
  },
};

let auditActionsCache = null;
export function auditActions() {
  if (auditActionsCache) return auditActionsCache;
  const abs = join(repoRoot, AUDIT_ACTIONS_PATH);
  let table;
  try { table = JSON.parse(readFileSync(abs, "utf8")); }
  catch (e) { throw new Error(`${AUDIT_ACTIONS_PATH} is unreadable or not valid JSON: ${e.message}`); }
  const codes = table.reason_codes;
  if (!codes || typeof codes !== "object")
    throw new Error(`${AUDIT_ACTIONS_PATH} declares no \`reason_codes\` object — the closed set every null label must name.`);
  for (const code of Object.keys(codes)) {
    if (!REASON_MUST_CITE[code])
      throw new Error(`${AUDIT_ACTIONS_PATH} declares reason_code ${JSON.stringify(code)} with no predicate in emit.mjs' REASON_MUST_CITE — a code nothing checks is a sentence with no exit code.`);
  }
  const rows = table.actions;
  if (!Array.isArray(rows) || rows.length === 0)
    throw new Error(`${AUDIT_ACTIONS_PATH} has no \`actions\` array — the whole vocabulary would read as empty and every downstream gate would go vacuous.`);

  const seen = new Set();
  for (const row of rows) {
    const at = `${AUDIT_ACTIONS_PATH} row ${JSON.stringify(row?.verb ?? row)}`;
    if (!row || typeof row !== "object" || Array.isArray(row))
      throw new Error(`${AUDIT_ACTIONS_PATH}: every entry of \`actions\` must be an object; found ${JSON.stringify(row)}.`);
    if (typeof row.verb !== "string" || !VERB_RE.test(row.verb))
      throw new Error(`${at}: \`verb\` must be a dotted <noun>.<verb> slug matching ${VERB_RE}.`);
    if (seen.has(row.verb))
      throw new Error(`${at}: declared twice. The vocabulary is a set; a duplicate row means one of the two labels is dead.`);
    seen.add(row.verb);
    if (!("label" in row))
      throw new Error(`${at}: no \`label\` key at all. Every declared verb states its console label EXPLICITLY — a string, or null WITH \`reason_code\` + \`reason\`. An absent key is the silent third state this table exists to remove.`);
    if (row.label !== null && (typeof row.label !== "string" || row.label.trim() === ""))
      throw new Error(`${at}: \`label\` must be a non-empty string or null; found ${JSON.stringify(row.label)}.`);
    if (row.label === null) {
      const code = row.reason_code;
      if (!code || !Object.prototype.hasOwnProperty.call(codes, code))
        throw new Error(`${at}: \`label\` is null, so it needs a \`reason_code\` from the declared set [${Object.keys(codes).join(", ")}]; found ${JSON.stringify(code)}.`);
      if (typeof row.reason !== "string" || row.reason.trim().length < REASON_MIN)
        throw new Error(`${at}: \`label\` is null, so it needs a \`reason\` of at least ${REASON_MIN} characters saying why. Found ${JSON.stringify(row.reason)}.`);
      const { re, what } = REASON_MUST_CITE[code];
      if (!re.test(row.reason))
        throw new Error(`${at}: reason_code ${JSON.stringify(code)} requires the \`reason\` to cite ${what} (${re}). It does not, so the excuse points at nothing and cannot rot loudly.`);
    } else if ("reason_code" in row || "reason" in row) {
      throw new Error(`${at}: carries a label AND a reason_code/reason. A labelled verb needs no excuse — drop them, or the next reader cannot tell which state is live.`);
    }
    if ("note" in row && !(Array.isArray(row.note) && row.note.every((l) => typeof l === "string")))
      throw new Error(`${at}: \`note\` must be an array of single-line strings (each is emitted as one \`//\` comment above the entry).`);
  }
  auditActionsCache = rows;
  return rows;
}

// The cloud SPA's ACTION_LABELS body (app.js). Only LABELLED verbs get an entry —
// humanAction(a) returns ACTION_LABELS[a] || a, so a null row is served by that
// documented fallback and needs no key (D582). The unlabelled count is emitted as
// ONE derived comment line rather than a hand-typed figure, so the number in the
// shipped artifact cannot drift from the table the way 55-vs-56 did. Indented 4
// spaces to sit inside the object literal in the IIFE; no trailing comma and no
// trailing newline (the marker's END line carries it).
export function auditActionLabels(rows = auditActions()) {
  const labelled = rows.filter((r) => r.label !== null);
  const lines = [
    `    // ${rows.length - labelled.length} of the ${rows.length} declared verbs have no entry here: they render`,
    `    // as their raw dotted slug through humanAction's fallback below, each one`,
    // This line is part of the generated region shipped in app.js; it is now
    // repointed to cloud/priv/audit-actions.json (the table moved there in
    // #11781) by cch-w53 in the same commit that hand-edits the marker line.
    `    // declared unlabelled ON PURPOSE with a reason in ${AUDIT_ACTIONS_PATH}`,
    `    // (charter D582 — ugly, not false).`,
  ];
  labelled.forEach((r, i) => {
    for (const l of r.note ?? []) lines.push(`    // ${l}`);
    lines.push(`    ${JSON.stringify(r.verb)}: ${JSON.stringify(r.label)}${i === labelled.length - 1 ? "" : ","}`);
  });
  return lines.join("\n");
}

// ── artifact registry ────────────────────────────────────────────────────────
// kind "css"             : splice content between a marker block. The shared
//                          BEGIN/END GENERATED: tokens marker by default; an
//                          artifact may override with markerBegin/markerEnd to
//                          own a DISTINCT marker in a file that also carries the
//                          tokens block elsewhere (the cloud SPA's app.js).
// kind "go"/"ts"/"elixir": the build() is the WHOLE file.
export const ARTIFACTS = [
  { name: "cloud SPA", path: "cloud/priv/static/app.css", kind: "css", build: cloudBlock },
  { name: "cloud SPA theme ids", path: "cloud/priv/static/app.js", kind: "css",
    markerBegin: BP_THEMES_MARKER_BEGIN, markerEnd: BP_THEMES_MARKER_END, build: bpThemesList },
  { name: "cloud SPA audit action labels", path: "cloud/priv/static/app.js", kind: "css",
    markerBegin: ACTION_LABELS_MARKER_BEGIN, markerEnd: ACTION_LABELS_MARKER_END, build: auditActionLabels },
  { name: "paper-surface", path: "api/assets/paper-surface/paper-surface.css", kind: "css", build: paperBlock },
  { name: "Studio", path: "api/lib/barkpark_web/layouts/root.html.heex", kind: "css", build: studioBlock },
  { name: "/papers reader skin", path: "api/lib/barkpark_web/layouts/bulldocs.html.heex", kind: "css", build: bulldocsBlock },
  { name: "web demo", path: "web/app/globals.css", kind: "css", build: webBlock },
  { name: "web TS tokens", path: "web/lib/tokens.gen.ts", kind: "ts", build: webTokensTs },
  { name: "Go board", path: "internal/taskboard/tokens_gen.go", kind: "go", build: taskboardGo },
  { name: "Go pdrender", path: "internal/pdrender/tokens_gen.go", kind: "go", build: pdrenderGo },
  { name: "Go semrole", path: "internal/semrole/tokens_gen.go", kind: "go", build: semroleGo },
  { name: "Go CLI chrome", path: "internal/semrole/chrome_gen.go", kind: "go", build: cliChromeGo },
  { name: "Elixir render tokens", path: "api/lib/barkpark/portable_doc/render/tokens_gen.ex", kind: "elixir", build: elixirTokensGen },
  { name: "Elixir Studio categorical tokens", path: "api/lib/barkpark_web/studio/tokens_gen.ex", kind: "elixir", build: studioTokensGen },
  { name: "login (session_html)", path: "api/lib/barkpark_web/controllers/session_html.ex", kind: "css", build: sessionAuthBlock },
  { name: "error page (error_html)", path: "api/lib/barkpark_web/controllers/error_html.ex", kind: "css", build: errorPageBlock },
  { name: "status page chrome", path: "api/lib/barkpark_web/controllers/status_controller.ex", kind: "css", build: statusChromeBlock },
  { name: "/sheets reader", path: "api/lib/barkpark_web/layouts/sheets.html.heex", kind: "css", build: sheetsBlock },
  { name: "living styleguide swatches", path: "cloud/priv/static/styleguide.html", kind: "html", build: styleguideSwatches },
];

// Tolerant of leading indentation on the marker lines (Studio's markers sit
// indented inside a <style> block); the captured groups preserve that whitespace.
const markerRe = new RegExp(
  `([ \\t]*${escapeRe(MARKER_BEGIN)}\\n)([\\s\\S]*?)(\\n[ \\t]*${escapeRe(MARKER_END)})`
);
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }

// The kind "html" splice target: an HTML-comment marker (the swatch grid lives
// inside styleguide.html's [data-sg-swatches] host, not a <style> block, so a CSS
// comment can't mark it). Same tolerant leading-indent capture as markerRe.
const HTML_MARKER_BEGIN =
  "<!-- BEGIN GENERATED: swatches (design/tokens.json — regenerate: node design/emit.mjs --write; do not hand-edit) -->";
const HTML_MARKER_END = "<!-- END GENERATED: swatches -->";
const htmlMarkerRe = new RegExp(
  `([ \\t]*${escapeRe(HTML_MARKER_BEGIN)}\\n)([\\s\\S]*?)(\\n[ \\t]*${escapeRe(HTML_MARKER_END)})`
);

// Compute {expected, current, path, kind, name} for one artifact. `expected` is
// the desired full file text; `current` is what's on disk. A missing marker for a
// css artifact is a hard error (surface not prepared with the marker block).
//
// Also returns the GENERATED REGION on both sides — `currentRegion` (what the
// marker holds on disk right now) and `expectedRegion` (what build() produced).
// The write fence attributes on the REGION, never the whole file: for a css/html
// artifact everything outside the marker is legitimately hand-written and must not
// affect attribution, and for a whole-file (go/ts/elixir) artifact the region IS
// the file. Both are always the exact bytes that a --write would swap.
export function evaluate(a) {
  const abs = join(repoRoot, a.path);
  let current;
  try { current = readFileSync(abs, "utf8"); }
  catch { current = null; }
  const content = a.build();

  if (a.kind === "html") {
    // html: splice into the HTML-comment marker of the CURRENT file (same
    // mechanism as css, different marker). A missing marker is a hard error.
    const base = current == null ? "" : current;
    const m = base.match(htmlMarkerRe);
    if (!m) {
      return { ...a, abs, current, expected: null, error: `no BEGIN/END GENERATED: swatches marker in ${a.path}` };
    }
    const expected = base.slice(0, m.index) + m[1] + content + m[3] + base.slice(m.index + m[0].length);
    return { ...a, abs, current, expected, currentRegion: m[2], expectedRegion: content };
  }
  if (a.kind !== "css") {
    // whole-file artifacts (Go, TS): the build() output IS the entire file, so
    // the generated region is the file — nothing here is hand-writable, and a
    // --write overwrites more bluntly than any marker splice.
    return { ...a, abs, current, expected: content, currentRegion: current, expectedRegion: content };
  }
  // css: splice into the marker block of the CURRENT file. Most surfaces share
  // the tokens marker; an artifact may name its OWN marker (markerBegin/End) to
  // splice a distinct region in a file that carries the tokens block elsewhere.
  const base = current == null ? "" : current;
  const re = a.markerBegin
    ? new RegExp(`([ \\t]*${escapeRe(a.markerBegin)}\\n)([\\s\\S]*?)(\\n[ \\t]*${escapeRe(a.markerEnd)})`)
    : markerRe;
  const m = base.match(re);
  if (!m) {
    return { ...a, abs, current, expected: null, error: `no ${a.markerBegin || "BEGIN/END GENERATED: tokens"} marker in ${a.path}` };
  }
  const expected = base.slice(0, m.index) + m[1] + content + m[3] + base.slice(m.index + m[0].length);
  return { ...a, abs, current, expected, currentRegion: m[2], expectedRegion: content };
}

export function evaluateAll() { return ARTIFACTS.map(evaluate); }

// ── the write fence: attribution by generated-region digest (charter D21) ────
// design/emit-manifest.json maps `<path>#<artifact name>` → SHA-256 of the region
// this emitter last wrote there. It is written ONLY by --write and --adopt, and it
// is the emitter's entire memory of its own output. Committed alongside the
// artifacts, exactly like the 18 generated files themselves: change tokens.json,
// run --write, commit the artifacts AND the manifest.
export const MANIFEST_PATH = "design/emit-manifest.json";
const MANIFEST_ABS = join(here, "emit-manifest.json");

// The ledger key: an artifact's IDENTITY, not its path. Two ARTIFACTS entries may
// share one file (distinct markerBegin/markerEnd), and both must own a slot — see
// the header note for why the shape is a flat `${path}#${name}` composite. A unit
// without a name (synthetic fixtures) keys by path alone, which is what it is.
export function regionKey(u) {
  return u.name ? `${u.path}#${u.name}` : u.path;
}

export function regionDigest(region) {
  return region == null ? null : createHash("sha256").update(region, "utf8").digest("hex");
}

export function readManifest() {
  let raw;
  try { raw = readFileSync(MANIFEST_ABS, "utf8"); }
  catch { return null; } // absent entirely — a first run, handled as UNKNOWN below
  try { return JSON.parse(raw).regions ?? {}; }
  catch (e) { throw new Error(`${MANIFEST_PATH} is not valid JSON (${e.message}); repair it or re-bless with: node design/emit.mjs --adopt`); }
}

// Exported so the paper-editor mirror CLI (design/paper-editor-mirror.mjs), the
// OTHER writer of a generated region, records its write in the SAME ledger —
// one manifest, one fence, no second implementation.
export function writeManifest(regions) {
  const sorted = {};
  for (const k of Object.keys(regions).sort()) sorted[k] = regions[k];
  writeFileSync(MANIFEST_ABS, JSON.stringify({
    $comment:
      "GENERATED ATTRIBUTION LEDGER — do not hand-edit. One SHA-256 per artifact, " +
      "keyed `<path>#<artifact name>` (NOT path alone: one file may carry two " +
      "generated regions, and each owns its own slot), taken " +
      "over the GENERATED REGION ONLY (the marker interior for css/html surfaces, " +
      "the whole file for go/ts/elixir). design/emit.mjs --write refuses to replace " +
      "a region whose digest does not match, because those bytes were never emitted " +
      "and replacing them destroys hand-written work (see commit 1d928b3bf). " +
      "Rewritten by `node design/emit.mjs --write`; re-bless the tree with --adopt.",
    regions: sorted,
  }, null, 2) + "\n");
}

// Attribute what is on disk RIGHT NOW against the ledger. Three outcomes:
//   "attributed"   — the region is byte-identical to what this emitter last wrote;
//                    replacing it loses nothing.
//   "unattributed" — the region holds bytes the emitter never produced. A --write
//                    would DELETE them. This is the case the fence exists for.
//   "unknown"      — no ledger entry (a brand-new artifact, or a missing manifest).
//                    Treated as unsafe: refusing a write on an unrecorded region is
//                    the milder failure, and --adopt clears it in one command.
export function attribute(r, regions) {
  if (r.error || r.currentRegion == null) return "unknown";
  const recorded = regions?.[regionKey(r)];
  if (recorded === undefined) return "unknown";
  return recorded === regionDigest(r.currentRegion) ? "attributed" : "unattributed";
}

// The lines a --write would remove from the region and NOT put back. Multiset
// difference, so a legitimate token edit (`--x: #aaa` → `--x: #bbb`) reports the
// one line it truly drops rather than the whole block, and a hand-written rule
// that exists nowhere in the new output is always reported.
export function lostLines(currentRegion, expectedRegion) {
  const keep = new Map();
  for (const l of (expectedRegion ?? "").split("\n")) keep.set(l, (keep.get(l) ?? 0) + 1);
  const lost = [];
  for (const l of (currentRegion ?? "").split("\n")) {
    const n = keep.get(l) ?? 0;
    if (n > 0) keep.set(l, n - 1);
    else if (l.trim() !== "") lost.push(l);
  }
  return lost;
}

// Report the exact bytes a --write would have destroyed. The old --write printed
// only `WROTE <name>`, which named the artifact and never the delta — the single
// property that let 33 hand-written rules disappear unnoticed.
function reportUnattributed(u, label = "REFUSED") {
  console.error(`  ${label} ${u.name} (${u.path})`);
  const why = u.attribution === "unknown"
    ? `no entry in ${MANIFEST_PATH} — this emitter has no record of ever generating this region`
    : `the region on disk does not match what this emitter last wrote there`;
  console.error(`    ${why}.`);
  const lost = lostLines(u.currentRegion, u.expectedRegion);
  if (lost.length === 0) {
    console.error(`    A --write would rewrite it, dropping no whole line — but the bytes are still unattributed.`);
  } else {
    console.error(`    A --write would DELETE ${lost.length} line(s) that do not appear in the regenerated output:`);
    for (const l of lost.slice(0, 12)) console.error(`      - ${l}`);
    if (lost.length > 12) console.error(`      … and ${lost.length - 12} more`);
  }
}

function run(mode, { force = false } = {}) {
  const results = evaluateAll();
  const regions = readManifest() ?? {};
  let changed = 0, errored = 0;

  // The mirror is a SECOND generation hop off the just-emitted paper-surface.css,
  // so its write must run after the artifact loop. Its attribution, however, is a
  // property of the bundle on disk (a different file the loop never touches), so
  // it is safe — and necessary — to pre-flight it here with everything else.
  const mr = evaluateMirror(repoRoot);
  const mirrorUnit = mr.error ? null : {
    ...mr, currentRegion: mr.currentBlock, expectedRegion: mr.generatedBlock,
  };

  // ── --adopt: bless what is on disk as this emitter's own output ─────────────
  // The one sanctioned escape from a refusal that is NOT a destructive write:
  // after relocating hand-written rules outside the marker (the fix 55d61ab4c
  // applied by hand), or after a merge left the ledger behind its artifacts.
  if (mode === "adopt") {
    const next = { ...regions };
    let adopted = 0;
    for (const u of [...results, ...(mirrorUnit ? [mirrorUnit] : [])]) {
      if (u.error || u.currentRegion == null) { console.error(`  skip  ${u.name}: ${u.error ?? "region unreadable"}`); continue; }
      const d = regionDigest(u.currentRegion);
      const k = regionKey(u);
      if (next[k] !== d) { next[k] = d; console.log(`  adopt ${u.name} (${u.path})`); adopted++; }
      else console.log(`  ok    ${u.name} (already blessed)`);
    }
    writeManifest(next);
    console.log(`\nemit --adopt: ${adopted} region(s) newly blessed in ${MANIFEST_PATH}. Nothing was rewritten.`);
    return;
  }

  // ── the write fence: pre-flight EVERY unit before writing ANY of them ───────
  // All-or-nothing on purpose. A per-artifact refusal mid-loop would leave the
  // tree half-regenerated, which is its own honesty problem: some surfaces new,
  // some old, and a check.mjs run that cannot tell you which.
  const units = [...results, ...(mirrorUnit ? [mirrorUnit] : [])];
  for (const u of units) {
    u.drift = !u.error && u.current !== u.expected;
    u.attribution = u.error ? "unknown" : attribute(u, regions);
    // Only a write that REPLACES bytes can destroy them. A region already equal to
    // what we would emit is not at risk, whatever the ledger says about it.
    u.blocked = u.drift && u.attribution !== "attributed";
  }
  if (mode === "write") {
    const blocked = units.filter((u) => u.blocked);
    if (blocked.length && !force) {
      console.error(`emit --write: REFUSED — ${blocked.length} region(s) hold content this emitter cannot attribute to a prior generation.\n`);
      for (const u of blocked) reportUnattributed(u);
      console.error(`
  Nothing was written. ${units.filter((u) => u.drift).length} artifact(s) drifted; none were touched.

  This is the fence that commit 1d928b3bf drove through: hand-written rules placed
  INSIDE a generated marker are deleted by regeneration, and the drift gate then
  passes over the wreckage. Pick one:

    • Hand-written content?  MOVE it outside the BEGIN/END GENERATED marker, then
      re-run. That is the durable fix (precedent: 55d61ab4c).
    • Legitimately generated, just unrecorded (new artifact, or a merge that left
      ${MANIFEST_PATH} behind)?  node design/emit.mjs --adopt
    • Certain the listed lines are expendable?  node design/emit.mjs --write --force
`);
      process.exit(1);
    }
    if (blocked.length && force) {
      console.error(`emit --write --force: OVERRIDING the fence on ${blocked.length} region(s) — the lines below are being DELETED.\n`);
      for (const u of blocked) reportUnattributed(u, "DELETING");
      console.error("");
    }
  }

  const nextRegions = { ...regions };
  for (const r of results) {
    if (r.error) { console.error(`  ERROR ${r.name}: ${r.error}`); errored++; continue; }
    if (mode === "write") {
      if (r.drift) { writeFileSync(r.abs, r.expected); console.log(`  WROTE ${r.name} (${r.path})`); changed++; }
      else { console.log(`  ok    ${r.name} (already current)`); }
      nextRegions[regionKey(r)] = regionDigest(r.expectedRegion);
    } else {
      if (r.drift) { console.error(`  DRIFT ${r.name} (${r.path})`); changed++; }
      else if (r.attribution !== "attributed") { console.error(`  UNATTRIBUTED ${r.name} (${r.path}) — in sync with tokens.json, but ${MANIFEST_PATH} has no matching record`); changed++; }
      else { console.log(`  ok    ${r.name}`); }
    }
  }
  // Post-step: the paper-editor token mirror. It is DERIVED from the just-emitted
  // paper-surface.css (a second generation hop), so it runs AFTER the artifact
  // loop has written paper-surface.css to disk. One shared transform with
  // design/check.mjs + scripts/paper-editor-mirror-check.sh — they can't disagree.
  // Re-evaluated here (not reusing the pre-flight copy) because the surface it
  // derives from may have just changed on disk.
  if (mr.error) {
    console.error(`  ERROR ${mr.name}: ${mr.error}`);
    errored++;
  } else {
    const post = evaluateMirror(repoRoot);
    const drift = post.current !== post.expected;
    if (mode === "write") {
      if (drift) { writeFileSync(post.abs, post.expected); console.log(`  WROTE ${post.name} (${post.path})`); changed++; }
      else { console.log(`  ok    ${post.name} (already current)`); }
      nextRegions[regionKey(post)] = regionDigest(post.generatedBlock);
    } else {
      if (drift) { console.error(`  DRIFT ${post.name} (${post.path})`); changed++; }
      else if (mirrorUnit.attribution !== "attributed") { console.error(`  UNATTRIBUTED ${post.name} (${post.path}) — in sync, but ${MANIFEST_PATH} has no matching record`); changed++; }
      else { console.log(`  ok    ${post.name}`); }
    }
  }

  if (errored) { console.error(`emit: ${errored} artifact(s) missing their marker block.`); process.exit(1); }
  if (mode === "write") writeManifest(nextRegions);
  if (mode !== "write" && changed) {
    console.error(`\nemit --check: ${changed} artifact(s) DRIFTED from design/tokens.json or are UNATTRIBUTED. Fix: node design/emit.mjs --write`);
    process.exit(1);
  }
  const total = results.length + 1; // + paper-editor mirror
  console.log(mode === "write"
    ? `emit --write: ${changed} artifact(s) regenerated, ${total - changed} already current; ${MANIFEST_PATH} updated.`
    : `emit --check: all ${total} artifacts in sync (${results.length} surfaces + paper-editor mirror), every generated region attributed.`);
}

// CLI
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const mode = process.argv.includes("--adopt") ? "adopt"
    : process.argv.includes("--write") ? "write"
    : "check";
  run(mode, { force: process.argv.includes("--force") });
}
