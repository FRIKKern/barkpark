// design/emit/vocab.mjs — shared vocabulary, the chrome type ladder, the terminal collapse rule, color helpers, CSS var fragments.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { tokens } from "./source.mjs";

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
// ── the chrome type ladder, DERIVED (task-039d433a1bac63ab) ─────────────────
// TYPE_STEPS used to be the hand-written literal
//
//     export const TYPE_STEPS = ["2xl","xl","lg","base","sm","xs","2xs","3xs"];
//
// under a comment saying it mirrored tokens.type.chrome. It was load-bearing in
// BOTH directions at once: it GENERATES the consumer (chromeTypeVars below, the
// web `chromeType` rows and `chromeTypeOrder`), and it is the list check.mjs
// Part C2 ITERATES. A gate that walks a hand copy and finds each of ITS OWN
// entries present in the source can only ever fail in one direction — a rung
// added to tokens.json and not to the literal is invisible to the very gate
// meant to hold the two in lockstep. PR #17942 added `2xs`/`3xs` and happened to
// update the literal too; nothing would have caught it if it had not. (The same
// defect one level out — a retyped expected side in
// web/__tests__/type-ladder-emitted.test.ts — is what surfaced this one.)
//
// So the step list AND ITS ORDER now come out of tokens.json. ORDER IS NOT KEY
// ORDER: tokens.json lists type.chrome smallest-first, while display order is
// largest → smallest, so the derivation sorts by DESCENDING SIZE — the contract
// the emitted comment already states — and REFUSES a tie, because two steps of
// the same size do not name one order. And it refuses rather than going blind:
// a missing family, a non-object family or a family yielding zero steps would
// derive [] and every downstream assertion would pass vacuously, which is the
// exact failure a ladder gate exists to prevent. check.mjs Part C2 drives all
// of those arms in-process plus a positive control on the derived count.
export const LADDER_REFUSE = "REFUSING TO MEASURE";
export function typeLadderFrom(doc, family) {
  const block = doc?.type?.[family];
  if (!block || typeof block !== "object")
    throw new Error(`${LADDER_REFUSE} — tokens.type.${family} is missing or is not an object`);
  // `_note` prose and scalars like type.reading.headingWeight are not rungs: a
  // rung is an entry carrying a finite positive `size`.
  const steps = Object.entries(block)
    .filter(([k]) => !k.startsWith("_"))
    .map(([k, v]) => [k, v?.size])
    .filter(([, size]) => typeof size === "number" && Number.isFinite(size) && size > 0);
  if (steps.length === 0)
    throw new Error(`${LADDER_REFUSE} — derived ZERO steps from tokens.type.${family}; every ladder assertion downstream would pass vacuously`);
  if (new Set(steps.map(([, size]) => size)).size !== steps.length)
    throw new Error(`${LADDER_REFUSE} — tokens.type.${family} has two steps of the same size, so "largest → smallest" does not name one order`);
  return steps.slice().sort((a, b) => b[1] - a[1]).map(([k]) => k);
}
// Chrome type-scale steps, largest → smallest (display order for the Studio type
// ladder). DERIVED from tokens.type.chrome — never retype it here.
export const TYPE_STEPS = typeLadderFrom(tokens, "chrome");
// The READING ladder's steps, display order (largest → body). Mirrors
// tokens.type.reading; the web TS emitter keys off it so the styleguide can show
// the prose scale the /papers surface actually paints with.
export const READING_STEPS = ["h1", "h2", "h3", "body"];
// The reader AIR ladder (tokens.space.air), lightest opening → heaviest. Emission
// order IS the ladder order design/validate.mjs asserts monotonic, and every step
// here has a consumer in paper-surface.css — an entry with none is a dead token.
export const AIR_STEPS = ["code", "table", "asciicast", "callout", "stats", "figure"];
// ── THE TERMINAL COLLAPSE RULE (canonical home) ──────────────────────────────
// This constant is where the six-rung air ladder's terminal behaviour is
// RECORDED. The web surface can paint 24.2px, 29.9px, 31.9px, 34.1px, 36.1px and
// 40.0px and a reader sees six distinct openings. A terminal cannot: its only
// vertical unit is a ROW, and `space.air.beat` is 22px ≈ exactly one row. So the
// whole ladder lives between 1.1 and 1.82 rows — six web rungs land on TWO honest
// terminal values, and any Go table that spells six different row counts is
// claiming a precision no terminal can render.
//
// AIR_ROW_SPLIT is where the SECOND row is earned. It is a PREDICATE over the
// ratio, not a hand-written list of block kinds: retune a ratio in tokens.json
// (or add a seventh rung) and the Go ladder re-derives instead of silently
// disagreeing with the source. 1.6 sits in the ladder's widest interior gap —
// callout 1.55 to stats 1.64 — so the split falls where the source itself is
// least committed, and every rung is on the same side of it as the measured
// benchmark (tooling/paper-excellence/evidence/erasure.html: code/table/
// asciicast/callout open one row, stats/figure two).
//
// Emitted into internal/pdrender/tokens_gen.go as GenAirRowSplit and applied by
// pdrender.AirRows (internal/pdrender/air.go); design/check.mjs Part P censuses
// both arms so neither the ratios nor the split can land dead.
export const AIR_ROW_SPLIT = 1.6;
// airRows collapses one web air ratio to its honest terminal row count.
export const airRows = (ratio) => (ratio >= AIR_ROW_SPLIT ? 2 : 1);
// ruleGlyph collapses a px rule WEIGHT to the terminal's only means of drawing
// one: the glyph. A terminal line is always one cell tall, so 2px vs 1px cannot
// be a thickness — it is heavy box-drawing vs light. Derived from the px value
// (>= the structural weight is heavy), so retuning space.section.rule or
// space.rule.hairline in tokens.json moves the terminal ladder with it.
export const RULE_HEAVY_PX = 2;
export const ruleGlyph = (px) => (px >= RULE_HEAVY_PX ? "━" : "─");
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
  "bg", "bg-deep", "ink", "ink-soft", "ink-faint", "ink-faint-line", "rule",
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

// The bp-graph.js Canvas palette (task au-r6). Canvas 2D `ctx.fillStyle` cannot
// consume `var()`, so the force-graph renderer assigns CONCRETE colour strings at
// paint time — which is exactly why it carried a hand-authored JS palette that no
// design gate could reach, exempted-with-rationale in design/exemptions.json. The
// fix is emit-time, not runtime: tokens.json's `color.graphCanvas.graph` is now the
// sole source, and this marker splices the concrete values into the renderer as a
// generated region. Emit-time (not an init-time computed-style probe) because
// bp-graph.js ships as a STATIC asset on four surfaces — two of them starter
// templates with no Barkpark stylesheet to probe — so a runtime resolver would have
// no governed CSS to read and would need a hand-written fallback palette, i.e. the
// very thing this removes. One artifact per copy keeps all four byte-identical.
const GRAPH_PALETTE_MARKER_BEGIN =
  "/* BEGIN GENERATED: bp-graph-palette (design/tokens.json color.graphCanvas.graph via design/emit.mjs — node design/emit.mjs --write; do not hand-edit) */";
const GRAPH_PALETTE_MARKER_END = "/* END GENERATED: bp-graph-palette */";

// Every bp-graph.js copy. scripts/check-bp-graph-drift.sh holds these four
// byte-identical; emitting each one separately from the SAME build() is what keeps
// that true through a token change (a single-copy artifact would red the drift
// tripwire on the next --write).
export const GRAPH_PALETTE_PATHS = [
  "api/priv/static/assets/bp-graph.js",
  "web/public/bp-graph.js",
  "templates/search-starter/public/bp-graph.js",
  "templates/astro-search-starter/public/bp-graph.js",
];

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

// The VERDICT pair (color.verdict) → `--bp-verdict-loss/-soft` +
// `--bp-verdict-peace/-soft` on the PAPER reading surface. Emitted as resolved
// hex, not as an hsl() channel triplet like the status roles: a verdict has no
// alpha-derived `-soft` companion to compose — its soft ground is its OWN derived
// leaf (AA-walked against, not faded out of, the ink), so there is nothing for a
// channel split to buy. `--bp-` and not `--tok-` because the consumers read it
// directly (the `--tok-*`→`--bp-*` bridge exists for the values paper-surface.css
// recomposes; these are read as-is).
const VERDICT_ROLES = ["loss", "loss-soft", "peace", "peace-soft"];
function verdictVars(theme, indent, t = tokens) {
  const v = t.color.verdict;
  return indent + VERDICT_ROLES.map((r) => `--bp-verdict-${r}: ${v[r][theme]};`).join(" ");
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

export { ACTION_LABELS_MARKER_BEGIN, ACTION_LABELS_MARKER_END, alpha, baseVars, BP_THEMES_MARKER_BEGIN, BP_THEMES_MARKER_END, goAdaptive, GRAPH_PALETTE_MARKER_BEGIN, GRAPH_PALETTE_MARKER_END, hsl, kebab, MARKER_BEGIN, MARKER_END, motionVars, primaryVars, softAlpha, statusVars, verdictVars };
