#!/usr/bin/env node
// breakpoint-sweep.mjs — the CONTINUOUS responsive sweep. Its axes are a
// FUNCTION of the artifact (app.css's own @media set, index.html's own
// section.view set, its own two data-theme modes, scenarios.mjs's own scenario
// list) rather than a list somebody typed, and it REFUSES — in BOTH directions
// — when the artifact grows a value the sweep does not cover, or drops one the
// sweep is still driving.
//
// FIVE AXES, AND WHAT EACH ONE IS WORTH (cch-w16-s2 widened it from two):
//   WIDTH     derived · a real yield axis, and the reason this file exists.
//   SCREEN    derived · every registered section.view must have a live cell.
//   THEME     derived, 2 members · COVERAGE, NOT YIELD. app.css's dark rules
//             touch only background/color/border-color, so the CSS structurally
//             cannot produce a theme-dependent geometry defect. Driven anyway,
//             as a FRESH ?theme= LOAD (never an attribute flip — see legRender),
//             so the day a dark rule changes a box, the sweep is already there.
//             ACCENT IDENTITY (data-bp-theme: charple/ember/evergreen/fjord/
//             iris, five values generated from BP_THEMES — re-derive with
//             `grep -n 'var BP_THEMES' app.js`) is a DIFFERENT axis and this
//             sweep does not claim it — its owner is
//             gr-blk-accent-scenario-sweep. Scoping the derivation to
//             `data-theme` exactly is load-bearing: "any data-*theme* selector"
//             derives SEVEN members and reds on an untouched tree.
//   HEIGHT    declared, derived half VACUOUSLY GREEN · app.css has ZERO
//             height-bearing @media, so the derived refusal refuses nothing
//             today and legA's own output says so. The declared HEIGHTS set
//             carries a written reason per value, and `--height a,b,c` DRIVES
//             any of them — the loop defaults to one (RENDER_HEIGHT) for the
//             render count stated in HEIGHT_REASONS[800], and reconciles what
//             it asked for against the window.innerHeight it measured, so a
//             declared-but-undriven height cannot be reported as covered.
//   SCENARIO  122 scenarios, 24 rendered, 98 in a COMMITTED residue literal.
//             DERIVED, never typed: `scenarioReport({scenarios: SCENARIOS})`
//             prints these on every bare run (the `>> scenarios` line), and
//             the header-census arm in breakpoint-sweep.test.mjs asserts THIS
//             VERY LINE against that report — this file said 100/75 for a
//             wave after the census moved, and no guard read the prose.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS (cch wave 14, slice S1)
// ─────────────────────────────────────────────────────────────────────────────
//  Every instrument this epic owns is wide on ONE axis and pinned on the other:
//    · the 2026-07-20 audit — 84 scenarios, exactly TWO widths;
//    · overflow-guard.mjs   — WIDTHS starts at 721, PHONE_WIDTHS ends at 620,
//                             so 621-720 is swept by NOTHING;
//    · all of them          — ask ONE question (does the page scroll sideways),
//                             which is structurally blind to a control whose
//                             text is cut with no cue and to a screen whose
//                             content starts below the fold.
//  A hand-written width list reopens a hole at the next breakpoint somebody
//  adds; a hand-written route list reopens one at the next screen. Wave 13
//  measured the consequence: 621-768 — every iPad in portrait, every half-
//  screen laptop split — had never been rendered by any instrument in this
//  epic, and seven whole screens had never been rendered at tablet width at
//  all.
//
//  So: DERIVE BOTH AXES, AND REFUSE ON A GAP. A guard that starts at 721 and a
//  guard that starts at 620 both leave a band. A sweep that WALKS the
//  breakpoints is the only shape that does not.
//
// ─────────────────────────────────────────────────────────────────────────────
//  HONEST LIMIT — WHAT THIS PROTECTS TODAY
// ─────────────────────────────────────────────────────────────────────────────
//  Leg A (the coverage refusal) is wired into console-harness.yml's existing
//  Node-20 `console-unit` job. `Console gate` — the aggregator that job reaches
//  branch protection through — is ADVISORY on this repo today: the live
//  required set is `Elixir gate` and `PR references an active task` only. So
//  this leg RUNS on every console-touching PR and its red is VISIBLE, but it
//  does not block a merge by itself. Say that plainly rather than implying
//  otherwise. Leg B (--render) is not wired IN FULL and must not be: it costs
//  MINUTES, not seconds (see COST below). A one-cell one-width SLICE of it is
//  wired — console-harness.yml's `tier-floor-render` job runs `--render --widths
//  901 --cell billing-trial` (`grep -n 'breakpoint-sweep' .github/workflows/
//  console-harness.yml`), which is ~1s. This sentence used to read "wired to
//  NOTHING", which was true when written and stopped being true the day that job
//  landed. Leg T (--tiers5) IS wired to nothing, deliberately, and says so in
//  its own header.
//
// ─────────────────────────────────────────────────────────────────────────────
//  LEG A — THE COVERAGE REFUSAL (default mode; browserless; ~50ms)
// ─────────────────────────────────────────────────────────────────────────────
//  Parses app.css for width-bearing @media preludes and index.html for its
//  registered `section.view` ids, and compares BOTH against the sweep's OWN
//  tables — WIDTHS (the boundary walk Leg B actually drives) and CELLS (the
//  scenario x route table Leg B actually renders). The tables are IMPORTED,
//  never restated: a second literal would make the refusal protect a
//  declaration instead of the sweep, and shrinking the real width loop would
//  leave it green. Shrink WIDTHS and this leg exits 2 — that is the test.
//
//  COMMENT-STRIPPING IS LOAD-BEARING, NOT HYGIENE. app.css:2131 contains the
//  string "@media (max-width: 720px) shell fold" INSIDE a CSS comment.
//  MEASURED ON THIS TREE (cch-w16-s2 corrected these — the previous three
//  numbers had rotted to 21/20/20 while the file was edited around them):
//  `grep -c '@media' app.css` says 23; comment-stripped it is 21; the CSSOM
//  reports 21 media rules. legA prints the raw count from the bytes it just
//  read rather than restating it, so these cannot rot again. A naive regex
//  invents phantom blocks — and the day a comment mentions a width nobody
//  covers, a phantom refusal.
//
//  RANGE SYNTAX AND min-width ARE HANDLED, AND THE UNPARSEABLE IS REFUSED.
//  `@media (width <= 812px)` is the same breakpoint as `(max-width: 812px)` and
//  must be seen as one. Any condition containing the token `width` that the
//  parser cannot resolve to an integer px boundary exits 2 naming it — silent
//  disappearance is the exact failure mode this leg exists to prevent. app.css
//  today is all max-width and has ZERO min-width; that is a fact about today,
//  not a licence.
//
//  `--cssom` asserts the parsed axis equals the axis walked from
//  `document.styleSheets` in a real browser, and exits 2 on parity=DIVERGED.
//
// ─────────────────────────────────────────────────────────────────────────────
//  LEG B — THE RENDER SWEEP (`--render`)
// ─────────────────────────────────────────────────────────────────────────────
//  WIDTH AXIS = a boundary walk B-1 / B / B+1 over every derived breakpoint.
//  That is six breakpoints (620, 720, 740, 768, 830, 899) giving 18 widths. THE
//  WIDTH 900 IS STILL WALKED, as 899+1 — dropping 900 from the axis cost
//  exactly ONE width, 901, and nothing else. (It was five breakpoints and 13
//  widths until cch-w16-s8 deleted app.css's only `max-width: 900px` rule —
//  the `@media (min-width: 900px)` block that remains parses as the boundary
//  899 — four/12 until W17-S6 added `@media (max-width: 830px)`, the
//  breakpoint that keeps the past-due money message whole, and five/15 until
//  W20-S8 added 740, the breakpoint that keeps that same message whole in the
//  shell-fold band below it.)
//
//  SCREEN AXIS = SCENARIO x ROUTE, never section.view alone. Content is
//  scenario-bound: on scen=mixed-fleet the notifications/tokens/env/sites/
//  activity/members screens render EMPTY and #notif-matrix is ABSENT at every
//  width. A view-keyed sweep leaves 79 of 338 cells RENDER-DEAD (78 showing
//  view-overview while asking for operator/instance/site) and every one of them
//  returns a plausible q1=0, q2=0 — for the wrong screen.
//
//  PER-CELL RENDER-LIVENESS REFUSAL, THREE CLAUSES, HARD exit 2 — never a
//  warning: (1) the live section.view id is the one requested, (2) it is not
//  hidden and has non-zero height, AND (3) the cell's SCENARIO-SPECIFIC
//  SENTINEL is present. Clause 3 is not ceremony: a cell pointed at a
//  non-populating scenario reports hidden:false, h:307, textLen:195 — clauses
//  1+2 alone PASS it and then measure an empty-state box. The sentinel table is
//  a MAINTAINED artifact, paired with Leg A so a new screen fails on the
//  sentinel it lacks rather than passing empty.
//
//  THREE QUESTIONS PER CELL
//   Q1 SIDEWAYS            documentElement.scrollWidth > clientWidth.
//   Q2 CLIPPED WITHOUT CUE two corrections it cannot ship without:
//      (a) NATIVE FORM CONTROLS ARE CLASSIFIED BY TAG. A <select> is UA-painted
//          and computes overflow-x: visible no matter how badly its selected
//          option is cut. Two independent CSSOM-keyed prototypes both reported
//          CLIP_NO_CUE = 0 while a person was reading a truncated control.
//          SELECT/INPUT/TEXTAREA/BUTTON compare scrollWidth vs clientWidth
//          directly.
//      (b) THE CUE TEST IS "reserved track > 0 OR an authored edge cue is live"
//          — not "is overflow-x auto", and NOT "a scrollbar rendered". The
//          reserved horizontal track measures 0px at every width under BOTH
//          --hide-scrollbars and real classic scrollbars, so a track test alone
//          would condemn every scroller in the console. An authored cue is a
//          `--*fade*`/`--*cue*` custom property reading > 0 (.set-matrix's
//          --set-matrix-fade is 48px while clipped, 0px when it fits) OR a
//          computed `text-overflow: ellipsis`, which IS the affordance that
//          tells a person the string continues — for NON-form elements only,
//          since a UA-painted control computes an ellipsis it does not
//          necessarily paint and that would silence correction (a).
//          CUE_STUCK (a note, never a failure) reports the IFF half: a cue live
//          on something that FITS — ON THE AXIS THE CUE PAINTS ON, read off the
//          mask's own gradient direction (`to right` = x, `to bottom` = y). A
//          horizontal-only fit test called the folded shell's VERTICAL
//          `--nav-fade` stuck while the strip measured scrollHeight 503 >
//          clientHeight 259: 78 notes on `--cell operator --widths 390,619,720`,
//          0 after. It is asked ONLY of scroll containers (either axis), and
//          only of the element whose OWN computed style carries the cue — both
//          cue properties are registered `inherits: false`, so the descendant
//          copies were `cueOf`'s ancestor walk, not CSS inheritance.
//      SHIPPED GENERAL, WITH NO ALLOWLIST. The measured census over the
//      data-bearing cells is one distinct selector — select#site-theme-select
//      .rail-select, which slice S4 pays. Visually-hidden is handled by a NAMED
//      list of hiding utilities, never a className regex.
//      VISIBLE_SPILL is NOT the failing set. The failing sub-case is
//      cutByViewport > 0, and it takes two qualifiers to mean anything:
//        · CONTAINED elements are excluded. Anything inside a clipping or
//          scrolling ancestor is scrolling, not spilling — .set-matrix's own
//          descendants report 21 spills at 768 and every one of them is the
//          cued matrix doing its job.
//        · THE PAINTED RIGHT EDGE, not the box. A block-level row is clamped
//          to its container's width, so `rect.right` reads "inside the
//          viewport" while its min-content children push the page sideways.
//          Non-clipping elements are measured at rect.left + scrollWidth;
//          clipping ones (and form controls) at rect.right, since that is all
//          they paint. Measured on origin/main at 769: #fleet-body +21,
//          div.fleet-row +20 — the exact cells this sub-case exists for.
//   Q3 BELOW THE FOLD      ONE number — the viewport y of `.content` — against
//      a fraction of viewport height, not a general rule. It measures 745.88px
//      at every width <= 720 and 56 above. Slice S2 fixes that; THIS slice must
//      not wait for it, so Q3 ships with a NAMED PIN in the shape
//      overflow-guard.mjs uses for FLEET_ROW_RESIDUAL: an explicit allowance
//      citing cch-w13-bl-folded-shell-nav-wall that reds if the number GROWS.
//      Pin removal is the follow-up row cch-w14-bl-sweep-navwall-pin-removal.
//
//  DO NOT RAISE app.css:4241. Wave 13 measured that raising the shell fold
//  RELOCATES the cliff and exports a 746px nav wall to every tablet.
//
// ─────────────────────────────────────────────────────────────────────────────
//  COST, HONESTLY
// ─────────────────────────────────────────────────────────────────────────────
//  The fresh-CDP-target-per-cell requirement is what BUYS liveness, and it
//  costs roughly a second per cell (0.73s measured). The full render leg is
//  25 cells x 2 themes x ONE height x 21 boundary widths = 1050 renders: budget
//  MINUTES. The height axis multiplies that and is therefore OPT-IN — all three
//  declared HEIGHTS make it 2700 renders (32.9 min), the number that decided
//  the default loop (HEIGHT_REASONS[800]). The width numeral here is
//  the DERIVED boundary walk (`WIDTHS.length`, printed by `--census` as "21
//  boundary widths"), not the 15 that this file's residue prose still repeats —
//  that stale numeral has no arm and is owned by
//  cch-w63-bl-the-derived-width-axis-has-no-arm-and-its-prose-propagated.
//  Measured, not assumed: `--render --cell inst-update-refused` reports 42
//  renders for ONE cell (21 x 2). The theme axis DOUBLED that, for an
//  axis stated above to be coverage rather than yield — slice it with
//  `--theme light` when you are chasing a width, not a mode. Two traps proven the hard way: Page.navigate to
//  a URL differing only in its hash is a SAME-DOCUMENT navigation, so injected
//  rules and stale stylesheets survive into the next cell (hence a fresh target
//  parked on about:blank per cell); and a double-requestAnimationFrame settle
//  HANGS under headless=new — a plain 16ms sleep does not.
//
//  RUN
//    node cloud/priv/static/__preview__/breakpoint-sweep.mjs            # Leg A
//    node …/breakpoint-sweep.mjs --cssom                # + browser axis parity
//    node …/breakpoint-sweep.mjs --tiers5               # Leg T (5-plan fixture)
//    node …/breakpoint-sweep.mjs --render               # Leg B (minutes)
//    node …/breakpoint-sweep.mjs --render --widths 900 --cell fleet     # slice
//    node …/breakpoint-sweep.mjs --render --cell fleet,billing-trial    # several
//                                     # an unknown name in the list EXITS 2 by
//                                     # name — it never narrows silently
//    BREAKPOINT_SWEEP_ROOT=<dir> …    # measure an exported tree (origin/main)
//    node …/breakpoint-sweep.mjs --render --theme dark   # one theme member
//    node …/breakpoint-sweep.mjs --render --height 390,667,800  # the HEIGHT axis
//                                     # DEFAULT IS ONE HEIGHT (RENDER_HEIGHT
//                                     # 800) and HEIGHT_REASONS[800] carries
//                                     # the render count that decided it. An
//                                     # undeclared value EXITS 2 by name, and
//                                     # every asked-for height is reconciled
//                                     # against the window.innerHeight the
//                                     # cells actually reported.
//    BREAKPOINT_SWEEP_CSS=<file> …    # parse a DIFFERENT app.css than is served
//    BREAKPOINT_SWEEP_HTML=<file> …   # ditto for the shell (the `light` theme
//                                     # member is declared ONLY there, so
//                                     # without this it has no mutation seam)
//    CHROME=/path/to/chrome …         # browser override
//
//  EXIT VOCABULARY (the epic's, unchanged): 0 = clean · 1 = a measured defect
//  · 2 = REFUSED (environment, a coverage gap, an unparseable width, or a dead
//  cell). 1 is a claim about the product; 2 is a claim about the instrument or
//  its inputs, and the two must never be confused.
//
//  ZERO DEPENDENCIES — node builtins plus the Cdp class and findChrome() taken
//  unchanged from cssom-parity.mjs / overflow-guard.mjs.
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { IDS, SCENARIOS } from "./scenarios.mjs";
import { FONT_PIN_JS, fontPinRefusal } from "./font-pin.mjs";
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr } from "./bringup-retry.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(process.env.BREAKPOINT_SWEEP_ROOT || path.resolve(HERE, ".."));
const CSS_PATH = process.env.BREAKPOINT_SWEEP_CSS || path.join(ROOT, "app.css");
// The shell's twin of BREAKPOINT_SWEEP_CSS. Without it a theme member declared
// ONLY in index.html (`light` — app.css has no light selector) has no mutation
// seam at all, so a "the theme axis refuses in both directions" claim could
// only ever be proven for the CSS-side member. Parsing-only, like its twin:
// Leg B still serves and drives the real tree.
const HTML_PATH = process.env.BREAKPOINT_SWEEP_HTML || path.join(ROOT, "index.html");
const PORT = Number(process.env.BREAKPOINT_SWEEP_PORT || 4207);
const BASE = `http://127.0.0.1:${PORT}`;

// ─────────────────────────────────────────────────────────────────────────────
//  THE SWEEP'S OWN TABLES — the ONLY declaration of either axis. Leg A imports
//  these; it does not restate them.
// ─────────────────────────────────────────────────────────────────────────────

// The boundary walk. A breakpoint at B changes behaviour BETWEEN B and B+1, so
// the only widths that can see the change are B-1 (safely below), B (the last
// width on the low side) and B+1 (the first on the high side).
export function boundaryWalk(breakpoints) {
  const out = new Set();
  for (const b of breakpoints) { out.add(b - 1); out.add(b); out.add(b + 1); }
  return [...out].sort((a, b) => a - b);
}

// W17-S6 ADDED 830. `@media (max-width: 830px)` is where GR116's topbar tighten
// now lives — the width at which the past-due money message ("Payment failed ·
// fix billing", scrollWidth 168) last fits beside the liveness chip. Leg A
// caught its absence exactly as designed: with the rule shipped and this list
// unchanged the sweep exited 2, "UNCOVERED breakpoint 830px — the boundary walk
// is missing 829, 830, 831." A CSS slice that adds a breakpoint owes this list
// an entry, and the sweep will not let it forget.
//
// W20-S8 ADDED 740, and Leg A caught its absence the same way, on the first run
// after the CSS landed: exit 2, "UNCOVERED breakpoint 740px — the boundary walk
// is missing 739, 740, 741." It is the upper edge of
// `@media (min-width: 621px) and (max-width: 740px)`, the block that keeps the
// past-due money message whole across the 721-740 shell-fold band (the guard's
// GR108 leg asserts those widths strictly now, with no tolerance). The prelude's
// LOWER edge costs no entry: 620 is already declared, and 621 is walked as
// 620+1.
//
// Derived from app.css: 620, 720, 740, 768, 830, 899, 904. Declared here as the sweep's
// committed axis so Leg A can refuse when the stylesheet grows a breakpoint
// this list does not carry — and, since cch-w15's phantom half, when it loses
// one. 900 LEFT THIS LIST because cch-w16-s8 deleted app.css's only
// `max-width: 900px` rule (the `.tier-grid { 1fr 1fr }` that forced two tier
// tracks onto every phone). The surviving `@media (min-width: 900px)` block is
// parsed as the boundary 899, which is why 899 stays. THE WIDTH 900 IS STILL
// DRIVEN — boundaryWalk emits 899+1 — so the only width this shrink costs is
// 901.
// 904 JOINED THE LIST via cch-w18-bl. The W20-S9 attention-name band's upper
// edge was `max-width: 899px`, a number DRIVEN against a fixture string the
// control plane does not write: `Registry.mark_offline/1` writes
// `health_status: "unknown"` deliberately, so a degraded box serves "Health
// unknown · Agent offline", three characters and +21px longer than the "Health
// down · Agent offline" the fixture used to carry. On the real string the name
// column is cut from 900 through 904 (67/62 at 900, 67/66 at 904, clean from
// 905), so the band's edge was RE-DERIVED to 904 and this axis grew with it.
// Leg A refusing here is the design working: a breakpoint the stylesheet
// declares and this list does not is a set of widths nothing drives.
export const BREAKPOINTS = [620, 720, 740, 768, 830, 899, 904];
export const WIDTHS = boundaryWalk(BREAKPOINTS);

const INST = IDS.liveInstance;
const SITE = IDS.siteWeb;
const REFUSED = IDS.refusedInstance;

// The screen axis: SCENARIO x ROUTE. `view` is the section.view that MUST be
// live, `ready` is what the driver polls for, and `sentinel` is clause 3 of the
// liveness refusal — a selector that exists ONLY when this scenario actually
// populated this screen. A sentinel that is merely "the screen's container"
// would be satisfied by an empty state, which is the whole failure this table
// exists to catch.
export const CELLS = [
  { name: "overview-fleet", scen: "mixed-fleet", hash: "#overview", view: "view-overview", sentinel: "#overview-body .ov-card, #overview-body .card, #overview-body section" },
  { name: "overview-past-due", scen: "overview-past-due", hash: "#overview", view: "view-overview", sentinel: "#billing-chip:not([hidden])" },
  { name: "fleet", scen: "mixed-fleet", hash: "#fleet", view: "view-fleet", sentinel: ".fleet-row" },
  { name: "fleet-archives", scen: "fleet-archives-stored", hash: "#fleet", view: "view-fleet", sentinel: "#archives-body .archive-row" },
  { name: "billing-trial", scen: "billing-trial", hash: "#settings/billing", view: "view-billing", sentinel: "#billing-tiers:not([hidden]) .tier" },
  { name: "billing-past-due", scen: "billing-past-due", hash: "#settings/billing", view: "view-billing", sentinel: "#billing-manage-section:not([hidden])" },
  { name: "providers-connected", scen: "providers-connected", hash: "#settings/providers", view: "view-providers", sentinel: "#provider-roster .prov-row" },
  { name: "providers-connect", scen: "providers-empty", hash: "#settings/providers", view: "view-providers", sentinel: "#provider-connect .set-section" },
  { name: "notifications", scen: "notif-configured", hash: "#settings/notifications", view: "view-notifications", sentinel: "#notif-matrix" },
  { name: "notifications-error", scen: "notif-deliveries-error", hash: "#settings/notifications", view: "view-notifications", sentinel: "#notif-matrix" },
  { name: "sites", scen: "sites", hash: "#sites", view: "view-sites", sentinel: "#sites-body .site-row, #sites-body .fleet-row" },
  { name: "activity", scen: "activity", hash: "#activity", view: "view-activity", sentinel: "#activity-body .tlv-row" },
  { name: "tokens", scen: "tokens-populated", hash: "#settings/tokens", view: "view-tokens", sentinel: "#token-list .token-row" },
  { name: "tokens-member", scen: "tokens-member", hash: "#settings/tokens", view: "view-tokens", sentinel: "#token-list .token-row" },
  { name: "members", scen: "members-populated", hash: "#settings/members", view: "view-members", sentinel: "#members-body .mem-row, #members-body .set-row" },
  { name: "members-member", scen: "members-member", hash: "#settings/members", view: "view-members", sentinel: "#members-body .mem-row, #members-body .set-row" },
  { name: "operator", scen: "operator-console", hash: "#operator", view: "view-operator", sentinel: "#operator-body .set-section, #operator-body .op-row" },
  { name: "operator-halted", scen: "operator-halted", hash: "#operator", view: "view-operator", sentinel: "#operator-body .set-section, #operator-body .op-row" },
  { name: "instance-detail", scen: "panel-overview", hash: `#instance/${INST}`, view: "view-instance", sentinel: ".detail-grid--instance" },
  { name: "inst-timeline", scen: "timeline", hash: `#instance/${INST}/timeline`, view: "view-instance", sentinel: "#instance-tabpanel .tlv-row" },
  { name: "inst-metrics", scen: "metrics", hash: `#instance/${INST}/metrics`, view: "view-instance", sentinel: "#instance-tabpanel .metrics-grid" },
  { name: "inst-webhooks", scen: "webhooks-panel", hash: `#instance/${INST}/webhooks`, view: "view-instance", sentinel: "#instance-tabpanel .wh-card" },
  { name: "inst-update-refused", scen: "instance-update-credential-refused", hash: `#instance/${REFUSED}`, view: "view-instance", sentinel: '#instance-tabpanel .update-badge[data-update-state="unknown"]' },
  { name: "site-rollback", scen: "rollback", hash: `#site/${SITE}`, view: "view-site", sentinel: ".detail-grid" },
  { name: "site-states", scen: "site-states", hash: `#site/${SITE}`, view: "view-site", sentinel: ".detail-grid" },
];

// The view axis Leg B actually covers, derived from the cell table.
export const COVERED_VIEWS = [...new Set(CELLS.map((c) => c.view))].sort();

// ── AXIS: THEME ──────────────────────────────────────────────────────────────
// The two modes Leg B loads, and the ONLY declaration of that axis. Derived
// census (parseThemeMembers over app.css + index.html) must equal this exactly,
// in BOTH directions.
export const THEMES = ["dark", "light"];

// ── AXIS: HEIGHT ─────────────────────────────────────────────────────────────
// NO ARTIFACT DECLARES A HEIGHT AXIS — app.css has ZERO height-bearing @media
// and its 16 vh-bearing declarations are continuous rules, not boundaries. So
// this set is DECLARED, not derived, and every value carries a written reason.
// The derived half (parseMediaBreakpoints().heights) is the refusal that fires
// the day a height-bearing @media appears; it is VACUOUSLY GREEN today and
// legA says so in its own output rather than letting the tick read as a find.
export const HEIGHTS = [390, 667, 800];
export const HEIGHT_REASONS = {
  390: "LANDSCAPE. 720x390 is the binding height for the fold bar — the shipped 34vh cap read 0.4836 of H here while passing casual inspection at 800, so a height set without it cannot see the defect cch-w15-s1 fixed.",
  667: "SHORT PORTRAIT. iPhone SE / small-phone portrait: the shortest height at which the folded shell is a normal reading posture rather than an edge case.",
  800: "THE DRIVEN DEFAULT, AND THE DEFAULT LOOP IS ONE HEIGHT — DECIDED, WITH THE NUMBER. Leg B renders at 800 unless --height says otherwise, and every Q3 number this epic quotes was taken there. Walking all three declared heights by default would take the full leg from 25 cells x 2 themes x 1 height x 21 widths = 1050 renders (12.8 min at the measured 0.73s/cell) to 3150 (38.3 min), on an axis whose only measured yield so far is the fold number Q3 already prints at every height it is asked for. So the height axis is OPT-IN (--height 390,667,800), the declared set is what --height will accept, and 390/667 are no longer declared-and-undrivable: cch-w16-bl-legb-drives-one-of-three-heights.",
};
// THE EPIC'S HEIGHTS DISAGREE, AND THIS IS THE DISAGREEMENT STATED RATHER THAN
// HIDDEN: modal-oracle/overflow-guard commit to 900, the fold identity is
// asserted at 667/390, and this sweep drives 800. 900 is deliberately NOT in
// HEIGHTS — declaring a height Leg B does not drive would make the set a wish
// list. Reconciling the three is gr-blk-accent-scenario-sweep's neighbour work,
// not this instrument's to assert.
export const UNDRIVEN_HEIGHTS = { 900: "overflow-guard.mjs / modal-oracle drive 900; this sweep does not, so it does not claim it." };
// The height Leg B actually renders at. It used to be a bare module const with
// no flag, no env override and no relation to anything — naming it a MEMBER of
// the declared axis is what makes HEIGHTS a description of the sweep rather
// than a wish (the unit suite pins the membership).
export const RENDER_HEIGHT = 800;
// The heights Leg B walks when the operator names none. ONE member, and the
// cost that bought that decision is in HEIGHT_REASONS[800] above rather than in
// a commit message. `--height a,b,c` selects from HEIGHTS by name and refuses
// an unknown value the way --cell and --theme do.
export const RENDER_HEIGHTS_DEFAULT = [RENDER_HEIGHT];

// Every height Leg B was ASKED to drive, against the viewport heights it
// actually MEASURED (window.innerHeight, read back per cell). A declared height
// that no cell rendered at is the exact defect this function exists to make
// impossible to ship green: the axis said three and the loop drove one.
export function heightDriveReport({ asked, seen }) {
  const askedSet = asked.map(Number);
  const seenSet = new Set([...seen].map(Number));
  const undriven = askedSet.filter((h) => !seenSet.has(h));
  const unasked = [...seenSet].filter((h) => !askedSet.includes(h)).sort((a, b) => a - b);
  return { asked: askedSet, driven: askedSet.filter((h) => seenSet.has(h)), undriven, unasked, ok: !undriven.length && !unasked.length };
}

// ── AXIS: SCENARIO ───────────────────────────────────────────────────────────
// A scenario's FAMILY, derived from the artifact (charter D180): its pathname
// when it has one, else the head of its deepLink, else no-deeplink. The naive
// name-prefix split gives 27 families and does not survive mutation.
export function familyOf(scen) {
  if (!scen) return null;
  if (scen.pathname && scen.pathname !== "/") return `path:${scen.pathname}`;
  if (scen.deepLink) return `hash:${scen.deepLink.split("/")[0]}`;
  return "no-deeplink";
}

// The 13 families the residue falls into, each with the reason Leg B does not
// render it. These are REASONS, not an allowlist: the allowlist is the 96
// name-keyed entries below, which is what makes a 121st scenario refusable.
export const RESIDUE_FAMILY_REASONS = {
  "hash:#instance": "The instance detail screen is swept by five cells (panel-overview/timeline/metrics/webhooks/update-refused). These 26 vary the CONTENT of a panel already rendered at all 18 widths — a new geometry only if the panel's own shape changes, which the five cells would see.",
  "hash:#overview": "#overview is swept by two cells (a populated fleet, a past-due chip). These 12 land there to vary something OTHER than its geometry — sign-in state, first-run emptiness, trial/attention banners, the accent identity, cch-w48-s6's `overview-member-empty-fleet` (the first fixture to combine a MEMBER actor with a zero-instance fleet, so the first able to paint launchFlow's pre-hoc refusal card at all), and cch-w12-followup-login-fixture-gap's `activity-identity-change` (the corpus's ONLY successful-login fixture, a DRIVE through three states rather than a screen — smoke.mjs steps it from Activity to signed out to signed in as another team, and a transition is not a width) — over a grid already walked at all 18 widths. The refusal swaps the runway's form for ONE .empty-state block, the same geometry the `empty` cell's neighbours already walk.",
  "hash:#site": "The site detail screen is swept by two cells (rollback, states). These 13 vary binding/verify content inside the same .detail-grid — plus cch-w48-s6's `site-member`, which moves the ACTOR (the first member ever to enter the site layer) over the exact fixtures the `rollback` cell already walks at all 18 widths. `site-deploy-rail-failed` (cch-w25-s3) is the CRUEL twin of the family: its rail footer holds a 240-char builder error with one unbreakable module path, and content length is overflow-guard's axis, not this sweep's — a fixture built to overflow would red every width of the walk for a reason the walk does not own. It is driven, at 320/390/900 x 2 themes x 2 routes (cruel + kind control), by overflow-guard's W25-deploy-rail-fail-wrap leg. `deploy-detail-cruel` (cch-deploy-detail-render-has-no-cap) is the family's OTHER cruel twin and is here for the same reason wearing the other axis: its 2,000-character live sub-caption is bounded VERTICALLY, and a fixture built to be 81 line-boxes tall would red every width of the walk for a height this sweep does not measure. It is driven at 320/390/620/900/1024/1440 x 2 themes by overflow-guard's W34-deploy-detail-render-bound leg. `site-deploy-rail-live` (cch-w29-bl) is the family's THIRD instrument fixture and the only one that is not cruel at all: it renders the rail's OTHER footer — `.deploy-rail-live`, which no scenario in this harness had ever produced — carrying the site's ordinary 55-character live URL. It is here rather than in a cell because what it exists to measure is one ANCHOR's wrap against its own container at phone widths, which is overflow-guard's axis and not a width walk over a .detail-grid the two cells already sweep at all 18 widths. It is driven at 320/360/390 x 2 themes by overflow-guard's W29-deploy-rail-live-url-wrap leg.",
  "hash:#settings": "The settings screens are swept by EIGHT cells across billing/providers/notifications/tokens/members. These 8 are member-role, ACTOR-IDENTITY, empty-state and cruel-content variants of those same panels: cch-w45-s1's `members-admin-actor` and `members-peer-owner` vary WHICH CONTROLS a row is offered (the rank-relative predicates), not the geometry of the .set-row that carries them — the two members cells already walk that row at all 18 widths, and a row with fewer buttons is strictly narrower than the one they walk.",
  "hash:#": "Routes whose head is a bare `#` — `#/invitations/accept` and `#/auth/reset`. These render a single centred card over the sign-in surface: no shell, no grid, nothing for a breakpoint to fold.",
  "no-deeplink": "The account modal family: no route of its own, opened over whatever screen is live. Modal geometry has its own instrument (modal-oracle) — duplicating it here would double the cost and split the owner. `account-modal-cruel-identity` (cch-w23-bl-cruel-identity-own-scenario) is the family's CRUEL twin, wearing the same axis `fleet-cruel-content` and `deploy-detail-cruel` do: its `.am-name` is a 158-character email local part at the server's own `validate_length(:email, max: 160)` cap, and content length is overflow-guard's axis, not this sweep's. It is driven at 320/360/390/430/620/900/1440 x 2 themes by overflow-guard's W23-account-modal-identity-bounded leg, beside `account-modal` as the kind control.",
  "path:/activate": "The device-activation page is not part of the console shell at all — a different document with its own layout, outside this sweep's screen axis.",
  "path:/new": "The launch/theater page is likewise its own document outside the shell.",
  "hash:#billing": "Billing is swept by two cells (trial tiers, past-due manage) — including the 230px tier floor s3 guards. These 8 vary member-role, cancelling copy, the portal return, cch-w39-s1's `billing-me-unreadable` and its one-shot recovery twin `billing-me-recovers`, and cch-w50-s4's two never-before-minted billing ACTORS (`billing-free-owner`, the unsubscribed owner renderPlanState routes to the upsell card, and `billing-support-plus`, the third catalog tier rendering as a CURRENT plan) inside those same panels — the unreadable pair swaps the Manage section's one-line copy for a single .empty-state block, and the upsell card is the same .card.plan-card the trial-tiers cell already walks at all 18 widths, one .plan-rec badge and one full-width button wider than nothing.",
  "hash:#operator": "The operator console is swept by two cells (console, halted). These 5 vary zero-staging / denied / route-unreadable / me-unreadable / me-recovers states of the same panels — cch-w37-s6's `operator-me-unreadable` renders ONE empty-state block in place of the four cards, a geometry the two cells already walk at all 18 widths, and cch-w37-bl's `operator-me-recovers` is a CLICK fixture: it boots into that same empty-state block and, after the press smoke.mjs drives, settles on the console geometry the `console` cell already sweeps. Neither end state is new to this sweep; only the transition between them is, and a transition is not a width.",
  "hash:#notifications": "Notifications are swept by two cells (configured, deliveries-error). These 2 are the empty and member-role variants of #notif-matrix.",
  "hash:#fleet": "The fleet screen is swept by two cells (mixed fleet, archives). These 2 are the same table with different CONTENT: `fleet-v4` is the v4 row variant, and `fleet-cruel-content` (cch-w21-s3) is the deliberately CRUEL twin — a 253-char custom_host and a 255-char name, both at the server's own validate_length caps. Content length is overflow-guard's axis, not this sweep's: this sweep walks WIDTHS against a fixed corpus, and a fixture built to overflow every width would red every cell of the breakpoint walk for a reason the walk does not own. It is driven, at 11 widths x 2 themes x 2 routes, by overflow-guard's W21-cruel-content-text-bounded leg.",
  "hash:#signup": "The logged-out signup screen: no authed shell, and the sign-in surface is a single centred card with no grid to fold.",
};

// THE RESIDUE — 96 scenarios that exist and are NOT rendered by any cell,
// COMMITTED AS A LITERAL, name-keyed to the family that explains them.
//
// WHY A COMMITTED LITERAL AND NOT A COMPUTED ONE (charter D180). An allowlist
// derived from the current residue is green under EVERY mutation, because it
// grows with the artifact and can never refuse anything: it looks itemised, it
// is even "artifact-derived", and it is 100% vacuous. Typed out, a 121st
// scenario has nowhere to hide.
// WHY NAME-KEYED AND NOT FAMILY-KEYED. A 13-entry family list fails 3 of 4
// mutations — it swallows a new scenario with no deepLink, swallows one inside
// the 22-member `hash:#instance` family, and goes green while its entry rots
// when a multi-member-family scenario gains a cell.
// THE CENSUS THIS RECONCILES AGAINST: 120 scenarios · 25 cells over 24 DISTINCT
// scenarios (mixed-fleet is used twice) · residue exactly 96 · 13 families.
// cch-w21-s3 moved it by one: `fleet-cruel-content` was the 101st scenario and
// the 76th residue entry, and the sweep REFUSED at exit 2 ("UNLISTED scenario
// \"fleet-cruel-content\" (family hash:#fleet)") until that line and the entry
// below were written. That refusal is the literal doing its job, not friction.
// cch-w25-s3 moved it again, and the same refusal fired: `site-deploy-rail-
// failed` is the 102nd scenario and the 77th residue entry, and this sweep
// exited 2 with `UNLISTED scenario "site-deploy-rail-failed" (family
// hash:#site)` until the entry below was written.
// cch-w34-s6 REVIEW moved it: `overview-never-reported` is the 103rd scenario
// and the 78th residue entry — residue, not a cell, the same home its sibling
// `overview-attention` has, so it is rendered and asserted by smoke.mjs
// without claiming a width walk it does not get.
// cch-w37-s6 moved it: `operator-me-unreadable` — the first fixture able to
// fail the /v1/me READ while keeping the account present, and so the first to
// reach meState()=="failed" at all — is the 104th scenario and the 79th
// residue entry, in the family its three siblings already occupy. The sweep
// exited 2 with `UNLISTED scenario "operator-me-unreadable" (family
// hash:#operator)` until the entry above was written.
// cch-w38-s1 moved it: `panel-overview-member` is the 105th scenario and the
// 80th residue entry — residue for the same reason its owner twin
// `panel-overview` is a CELL: it varies the CONTENT of a panel the four
// instance cells already walk at all 18 widths, not its geometry.
// cch-w45-s1 moved it by TWO: `members-admin-actor` and
// `members-peer-owner` — the first fixtures in which the acting principal is
// not the roster's row 0, so the first able to ask a rank-relative predicate
// about a row the actor does NOT outrank — are the 107th and 108th scenarios
// and the 82nd and 83rd residue entries. The sweep exited 2 with `UNLISTED
// scenario "members-admin-actor" (family hash:#settings)` (and the twin) until
// the entries below were written; the four numbers here were then RE-READ from
// `scenarioReport`, never carried from the brief.
// cch-w48-s6 moved it by TWO, and deliberately in ONE commit:
// `overview-member-empty-fleet` (the first fixture combining a member actor with
// a zero-instance fleet — the exact frame launchFlow's pre-hoc refusal exists
// for) and `site-member` (the first member to enter the site layer at all) are
// the 109th and 110th scenarios and the 84th and 85th residue entries. ONE
// owner, ONE merge window, on purpose: main is strict:false, so two green PRs
// each bumping this literal by one merge without conflict and red main on the
// second (the 104->105 precedent). The sweep exited 2 with `UNLISTED scenario
// "overview-member-empty-fleet" (family hash:#overview)` and the twin until the
// entries below were written, and all five numerals were then RE-READ from
// `scenarioReport`, never carried from the brief.
// cchi-w39-bl-mefault-must-be-exhaustible moved it: `billing-me-recovers` —
// the first fixture whose /v1/me fault EXHAUSTS (`times: 1` through the
// per-boot state bag), so the first able to measure the shared retry's
// RECOVERY half rather than its presence — is the 112th scenario and the
// 86th residue entry, in the family its unreadable twin already occupies.
// The sweep exited 2 with `UNLISTED scenario "billing-me-recovers" (family
// hash:#billing)` until the entry below was written; the numbers here were
// RE-READ from `scenarioReport` after the entry landed.
// cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts moved it by TWO, in one
// commit (the strict:false hazard the 104->105 precedent names):
// `members-cruel-content` (the roster's first 160-char email — the members leg
// had only ever measured fixture kindness on .set-row-name) and
// `instance-cruel-detail` (the first deep-link to the CRUEL instance's own
// detail, where the 253-char custom_host finally reaches .detail-url-text) are
// the 113th and 114th scenarios and the 87th and 88th residue entries. The
// sweep exited 2 with `UNLISTED scenario` for each until the entries below
// were written; the numbers here were RE-READ from `scenarioReport`.
// `familyOf` over all 114 gives 15; the two with ZERO residue are `hash:#sites`
// and `hash:#activity`. 88 is the RESIDUE, not the census.
//
// cch-w37-bl-operator-retry-click-undriven moved it by ONE:
// `operator-me-recovers` — the one-shot /v1/me fault whose retry smoke.mjs now
// CLICKS, so the console's recovery is measured rather than asserted — is the
// 115th scenario and the 89th residue entry. The sweep exited 2 with `UNLISTED
// scenario "operator-me-recovers" (family hash:#operator)` until the entry was
// written; the numbers here were RE-READ from `scenarioReport`, and the family
// stays at 13 because `hash:#operator` already had four members.
//
// cch-w29-bl-deploy-rail-live-site-open-still-nowrap moved it by ONE:
// `site-deploy-rail-live` — the first fixture in this harness to render
// `.deploy-rail-live`, the deploy rail's OTHER footer, so the first that can
// measure the site URL inside it at any width — is the 117th scenario and the
// 92nd residue entry (it landed as the 120th/94th; cch-w53-bl's env-var Option A
// then deleted three scenarios and two residue entries beneath it, which is why
// a chronicle ordinal is only ever a landing SLOT and the ceiling arm re-reads
// the census). Both halves refused first, by name: the sweep exited 2
// with `UNLISTED scenario "site-deploy-rail-live" (family hash:#site)` and
// smoke on `CENSUS: 1 committed scenario(s) have NO expectation`. The numbers
// here were RE-READ from `scenarioReport` after the entry landed, never carried
// from the brief — and they are NOT 116/90: four scenarios landed between
// `operator-me-recovers` and this one without writing a chronicle block, so the
// last typed ordinal above is not the census.
//
// cch-w23-bl-cruel-identity-own-scenario moved it by ONE:
// `account-modal-cruel-identity` — the 158-character email local part that used
// to ride `account-modal-revoke` because THIS LITERAL was one of the four
// censuses the wave-23 slice was fenced out of — is the 118th scenario and the
// 94th residue entry (it landed as the 121st/95th; cch-w53-bl's env-var Option A
// then deleted three scenarios and one net residue entry beneath it, which is
// why a chronicle ordinal is only ever a landing SLOT and the ceiling arm
// re-reads the census). That fence is the whole reason the row existed: the
// refusal below is cheap to pay and was instead paid by hiding a cruel identity
// inside a scenario named for a click oracle. RESIDUE, not a cell, for the
// family's standing reason (the account modal has no route of its own) and for
// the cruel-twin reason `fleet-cruel-content` and `deploy-detail-cruel` already
// carry: content length is overflow-guard's axis, not this sweep's, and this
// fixture is driven at 7 widths x 2 themes by W23-account-modal-identity-bounded.
// The sweep exited 2 with `UNLISTED scenario "account-modal-cruel-identity"
// (family no-deeplink)` until the entry below was written; the numbers here were
// RE-READ from `scenarioReport`, and the family stays at 13 because
// `no-deeplink` already had five members.
//
// cch-w50-s4 moved it by TWO, in ONE commit (the strict:false hazard the
// 104->105 precedent names): `billing-free-owner` and `billing-support-plus` —
// the two billing ACTORS the corpus had never held — are the 119th and 120th
// scenarios and the 95th and 96th residue entries. `billing-free-owner` is the
// UNSUBSCRIBED owner, the actor renderPlanState routes to the upsell card, whose
// four unique markers (`plan-continue`, "Optimized for shipping to production",
// "See more plan options", "Recommended") had ZERO hits in a rendered-DOM dump
// of the whole corpus — so any render-layer guard aimed at that card was green
// BY CONSTRUCTION. `billing-support-plus` is the first `support_plus` fixture
// this file has ever carried at all. RESIDUE, not cells: the upsell card and the
// current-plan card are both the .card.plan-card the `billing-trial` cell walks
// at all 18 widths, differing by one .plan-rec badge and one .btn-block — no
// geometry those cells do not already sample. The sweep exited 2 with `UNLISTED
// scenario "billing-free-owner" (family hash:#billing)` and the twin, and smoke
// on `CENSUS: 2 committed scenario(s) have NO expectation`, until the entries
// below and their EXPECTATIONS were written; the numbers here were RE-READ from
// `scenarioReport`, never carried from the brief — which said 110->112/85->87
// against a merge base that already measured 118/94. The family stays at 13
// because `hash:#billing` already had five members.
//
// cch-w49-s7 moved it by ONE: `billing-unconfigured` — the corpus's FIRST
// fixture of any kind to carry D554's `billing_capability` on the
// /v1/subscription 200, so the first from which a rendered-bytes claim about the
// console's consumption of it can be made at all (before it, every consumer of
// that key was green BY CONSTRUCTION, the same hole `billing-free-owner` found
// one arm over) — is the 122nd scenario and the 98th residue entry. RESIDUE, not
// a cell: it is `billing-trial`'s actor with ONE field changed, so it paints the
// same .tier-grid the `billing-trial` cell already walks at all 18 widths, minus
// three buttons and plus one full-width `.tier-omit-note` row — strictly less
// horizontal demand than the geometry that cell measures, and the 230px track
// floor is untouched. The sweep exited 2 with `UNLISTED scenario
// "billing-unconfigured" (family hash:#billing)` until the entry below was
// written, and smoke refused first on `CENSUS: 1 committed scenario(s) have NO
// expectation`. Both numerals were RE-READ from a RUN of `node
// breakpoint-sweep.mjs` on this branch, never by adding one — and the family
// stays at 13 because `hash:#billing` already had seven members.
//
// WHICH ARM OWNS WHICH NUMERAL (cch-w47-s4, D527). The old header here read
// "EVERY NUMBER ON THESE FOUR LINES IS DERIVED, NOT TYPED" over typed numerals
// spanning SEVEN lines, and three of the numbers under it were owned by
// nothing. A COMMENT CANNOT BE DERIVED — it can only be RECOUNTED by an arm
// that reads these bytes. Every numeral in this block is now named by the arm
// that reds when it drifts, all in breakpoint-sweep.test.mjs:
//   * 120 / 25 / 24 / 96 / 13 — "the census reconciles: …", whose TITLE is now
//     built from `scenarioReport` by template literal rather than typed, so the
//     printed line has no second copy left to rot.
//   * 15, and the two ZERO-residue names `hash:#sites` / `hash:#activity` —
//     "the two ZERO-residue families are named, and 15 families over all
//     scenarios is not 13".
//   * each `// <family> — N` group header below, their SUM against the literal,
//     and the header COUNT against the family count (the reformat tripwire) —
//     "every `// <family> — N` header inside SCENARIO_RESIDUE is recounted from
//     the literal itself".
//   * each `These N` in RESIDUE_FAMILY_REASONS above — "every `These N` clause
//     in RESIDUE_FAMILY_REASONS is recounted from the literal". Five reasons
//     spell no count and are honestly SKIPPED by that arm; their membership is
//     covered by the header arm, which spans all 13.
//   * the chronicle ordinals above ("the Nth scenario / Mth residue entry") —
//     "the chronicle's ordinals strictly increase and stay inside the census —
//     in this file and the bare sweep", which reads THESE bytes and reds on a
//     duplicate landing slot, an out-of-order block, or an ordinal past the
//     measured census. It cannot recount which fixture landed where — that
//     stays prose — but a repeat of the 104/79 double-claim now fails by name.
// THE PRECEDENT THIS EXISTS FOR: the prose here once said 99/74 while the
// literal below already held 75 — #8849's `sites-on-instance` moved the census
// and only the TEST literals were updated. A census that two files spell
// differently is the staleness this file exists to make fatal, and until
// cch-w47-s4 this file was carrying two of them: `hash:#billing — 3` over four
// entries, and a `These 9` over ten.
// STALENESS IS FATAL, NEVER A console.log: an entry naming a scenario that no
// longer exists, or one that has since gained a cell, exits 2.
export const SCENARIO_RESIDUE = {
  // hash:#instance — 26
  "sites-on-instance": "hash:#instance",
  "panel-overview-member": "hash:#instance",
  "instance-cruel-detail": "hash:#instance",
  "provisioning": "hash:#instance",
  "usage-quota": "hash:#instance",
  "failed": "hash:#instance",
  "timeline-events-only": "hash:#instance",
  "verify-pass": "hash:#instance",
  "verify-fail": "hash:#instance",
  "verify-never": "hash:#instance",
  "shell-instance": "hash:#instance",
  "timeline-coalesced": "hash:#instance",
  "webhooks-autodisabled": "hash:#instance",
  "metrics-stale": "hash:#instance",
  "metrics-absent": "hash:#instance",
  "fleet-support-provisioning": "hash:#instance",
  "fleet-support-online": "hash:#instance",
  "fleet-support-failed": "hash:#instance",
  "fleet-support-empty": "hash:#instance",
  "offload-filing": "hash:#instance",
  "offload-working": "hash:#instance",
  "offload-done": "hash:#instance",
  "offload-blocked": "hash:#instance",
  // cch-w45-bl — the three instance states no cell renders and no scenario used
  // to produce: a box one release BEHIND (#inst-update), a teardown that FAILED
  // (#inst-remove-retry) and a /verify that answers 404 no_admin_token
  // ([data-vf-reprovision]). They are RENDER-STATE fixtures for smoke.mjs's
  // shim, not geometry: each one paints the same instance-detail layout every
  // hash:#instance cell above already walks at every declared breakpoint, so a
  // cell here would re-measure a geometry this sweep has 23 samples of and add
  // nothing. What they carry that no cell can score is a BUTTON that exists,
  // which is smoke.mjs's axis.
  "instance-behind": "hash:#instance",
  "instance-remove-failed": "hash:#instance",
  "verify-no-credentials": "hash:#instance",
  // hash:#overview — 12
  "loggedout": "hash:#overview",
  "empty": "hash:#overview",
  "fleet-usage": "hash:#overview",
  "shell-root": "hash:#overview",
  "operator-visible": "hash:#overview",
  "identity-iris": "hash:#overview",
  "loggedout-twofactor": "hash:#overview",
  "overview-trial-runway": "hash:#overview",
  "overview-attention": "hash:#overview",
  "overview-never-reported": "hash:#overview",
  "overview-member-empty-fleet": "hash:#overview",
  // cch-w12-followup-login-fixture-gap — a DRIVE fixture, not a screen. It boots
  // the same #overview grid the two cells already walk at all 18 widths and then
  // moves through three states smoke.mjs steps it through by hand (Activity →
  // signed out → signed in as another team → Activity), none of which is a
  // width. What it exists to produce is the only thing this corpus could not:
  // a COMPLETED sign-in, so render()'s logged-out arm can be entered and left
  // with an account change across it. Its terminal geometry is the `activity`
  // cell's, which this sweep already renders.
  "activity-identity-change": "hash:#overview",
  // hash:#site — 13
  "deploy-detail-cruel": "hash:#site",
  "promote-failure": "hash:#site",
  "promote-in-flight": "hash:#site",
  "promote-retry": "hash:#site",
  "promote-migrated": "hash:#site",
  "shell-site": "hash:#site",
  "site-deploy-rail-failed": "hash:#site",
  "site-deploy-rail-live": "hash:#site",
  "site-binding-bound": "hash:#site",
  "site-binding-unknown": "hash:#site",
  "site-binding-mismatch": "hash:#site",
  "site-member": "hash:#site",
  // cch-w53-bl env-var Option A (ruled 2026-09-02): `env-editor` is the SITE
  // env-blob editor (E-03), a different feature from the deleted team env-var
  // page. Its cell drove it at `#settings/env` — the route that no longer
  // exists — so the cell went with the page and the scenario lands here, in the
  // family its own deepLink (`#site/<id>`) has always named. Its geometry is the
  // .detail-grid the `rollback` and `states` cells already walk at all 18 widths.
  "env-editor": "hash:#site",
  // hash:#settings — 8
  "members-admin-actor": "hash:#settings",
  "members-peer-owner": "hash:#settings",
  "members-cruel-content": "hash:#settings",
  "tokens-empty": "hash:#settings",
  "tokens-revoke": "hash:#settings",
  "tokens-reveal": "hash:#settings",
  "providers-unverified": "hash:#settings",
  "providers-member": "hash:#settings",
  // hash:# — 6
  "loggedout-invited": "hash:#",
  "invite-joined": "hash:#",
  "invite-expired": "hash:#",
  "invite-already-member": "hash:#",
  "invite-invalid": "hash:#",
  "loggedout-reset": "hash:#",
  // no-deeplink — 6
  "account-modal": "no-deeplink",
  "account-modal-tall": "no-deeplink",
  "account-modal-revoke": "no-deeplink",
  "account-modal-cruel-identity": "no-deeplink",
  "account-modal-2fa-badcode": "no-deeplink",
  "account-modal-2fa-on": "no-deeplink",
  // path:/activate — 5
  "activate-entry": "path:/activate",
  "activate-confirm": "path:/activate",
  "activate-gone": "path:/activate",
  "activate-rate-limited": "path:/activate",
  "activate-logged-out": "path:/activate",
  // path:/new — 4
  "new-launch": "path:/new",
  "theater-midflight": "path:/new",
  "theater-failed": "path:/new",
  "theater-ready": "path:/new",
  // hash:#billing — 8
  "billing-portal-return": "hash:#billing",
  "billing-member": "hash:#billing",
  "billing-me-unreadable": "hash:#billing",
  "billing-me-recovers": "hash:#billing",
  "billing-cancelling": "hash:#billing",
  "billing-free-owner": "hash:#billing",
  "billing-support-plus": "hash:#billing",
  "billing-unconfigured": "hash:#billing",
  // hash:#operator — 5
  "operator-zero-staging": "hash:#operator",
  "operator-denied": "hash:#operator",
  "operator-unreadable": "hash:#operator",
  "operator-me-unreadable": "hash:#operator",
  "operator-me-recovers": "hash:#operator",
  // hash:#notifications — 2
  "notif-empty": "hash:#notifications",
  "notif-member": "hash:#notifications",
  // hash:#fleet — 2
  "fleet-v4": "hash:#fleet",
  "fleet-cruel-content": "hash:#fleet",
  // hash:#signup — 1
  "loggedout-signup": "hash:#signup",
};

// `--cell a,b,c` — SELECTION, AND A PER-NAME REFUSAL. The per-name check is the
// point, not the split: a comma split that keeps the old `if (!cells.length)`
// guard reds ONLY when EVERY name is unknown, so `--cell fleet,fleeet` quietly
// narrows to ONE cell and prints `verdict clean`, exit 0 — a typo silently
// shrinking the sweep to a fraction of what the operator asked for is exactly
// the false green this epic exists to kill. Returns the selection AND the
// unknown names so the caller can name each one; order follows the FILTER (an
// operator who writes `--cell billing-trial,fleet` gets that order), duplicates
// collapse, and blank members (`--cell fleet,`) are ignored rather than being
// reported as an unknown cell called "".
export function selectNames(all, filter) {
  if (filter == null) return { selected: [...all], unknown: [], asked: null };
  const asked = String(filter).split(",").map((s) => s.trim()).filter(Boolean);
  const known = new Set(all);
  const unknown = asked.filter((n) => !known.has(n));
  const selected = [];
  for (const n of asked) if (known.has(n) && !selected.includes(n)) selected.push(n);
  return { selected, unknown, asked };
}

// The same selection over the cell table, keyed by cell name.
export function selectCells(all, filter) {
  const byName = new Map(all.map((c) => [c.name, c]));
  const r = selectNames([...byName.keys()], filter);
  return { cells: r.selected.map((n) => byName.get(n)), unknown: r.unknown, asked: r.asked };
}

// `.content` must start inside the top FOLD_FRACTION of the viewport, at EVERY
// width — there is no longer an exemption for the widths the shell fold owns.
// 0.4 of 800 = 320px; the measured value above 720 is 56.
//
// THE PIN THAT USED TO LIVE HERE IS GONE (cch-w15-s1, removal row
// cch-w14-bl-sweep-navwall-pin-removal). It allowed `.content` to start 745.88px
// down at every width <= 720 — 2.27x this budget — so the folded shell was the
// one region of the width axis this sweep was not actually measuring, and the
// shipped `34vh` cap (0.34H + 56 = 0.4100 of H at 800, 0.4239 at 667, 0.4836 at
// landscape 390) sat OVER the budget under it, reported green. The fold now
// clears the bar on its own: `max-height: calc(40vh - 60px)` cancels the 56px
// topbar and makes contentTop = 0.4H - 4 an identity at every height.
export const FOLD_FRACTION = 0.4;

// Q2's named hiding utilities. A className regex would swallow any class with
// "hidden" as a substring (`.is-hidden-until-hover` is not hidden), so the list
// is enumerated.
export const HIDING_UTILITIES = ["visually-hidden", "sr-only", "screen-reader-only", "u-hidden", "is-hidden"];
// Authored edge cues are discovered by walking computed custom properties, but
// a browser that does not enumerate them must not silently report "no cue on
// anything" — these are checked by name as well.
export const NAMED_CUE_PROPS = ["--set-matrix-fade", "--matrix-fade", "--scroll-fade"];

// ─────────────────────────────────────────────────────────────────────────────
//  CUE_STUCK ASKS THE CUE'S OWN AXIS (cch-w15-bl-cuestuck-asks-horizontal-of-a-
//  vertical-cue)
// ─────────────────────────────────────────────────────────────────────────────
//  THE DEFECT, AS MEASURED. CUE_STUCK used to ask ONE question of every cue it
//  found — "does this element fit HORIZONTALLY?" — because the only cue this
//  sweep was built against (`--set-matrix-fade`) is a `to right` mask on an
//  `overflow-x: auto` scroller. The folded shell's `--nav-fade` is the other
//  shape: a `to bottom` mask on an `overflow-y: auto` strip. Driven at 720x800
//  on origin/main, `aside.sidebar.is-nav-clipped` measures scrollHeight 503 >
//  clientHeight 259 — genuinely clipped, cue correctly live — and the sweep
//  called it stuck anyway, because it fits on the axis nobody asked about. A
//  note that is green by the WRONG AXIS is not a green.
//
//  AND THE INHERITANCE WAS THE INSTRUMENT'S, NOT THE CSS'S. The old arm's
//  comment blamed custom-property inheritance for the descendant copies, and
//  that reading is refuted by the artifact: BOTH cue properties are registered
//  `@property … { inherits: false }` (app.css `@property --nav-fade` and
//  `@property --set-matrix-fade`), so `svg.nav-ico` inside the strip computes
//  `--nav-fade: 0px`. The 40px it reported came from `cueOf`'s OWN ancestor
//  walk. So the note now reads the cue off the element's own computed style:
//  for a REGISTERED non-inheriting cue a descendant correctly reads 0 and goes
//  quiet, and for an unregistered `--*fade*` (which really does inherit)
//  `getComputedStyle(child)` still returns the inherited value, so that case
//  keeps the scroll-container guard and the axis test doing the work. `cueOf`'s
//  walk is untouched — CLIP_NO_CUE still uses it.
//
//  MEASURED BOTH WAYS: `--render --cell operator --widths 390,619,720` emitted
//  78 CUE_STUCK notes before this change (39 per theme — the filing's number
//  predates the theme axis doubling the leg) and 0 after, while the note still
//  fires on a cue live over something that fits on the cue's own axis.

// The axis a mask actually paints on, read off the computed `mask-image`. The
// gradient's direction IS the axis: `to right` fades a horizontal scroller,
// `to bottom` a vertical one. Chrome drops the direction token from the
// computed value when it is the default, and the default for `linear-gradient`
// is `to bottom` — so "no direction token" is a vertical answer, not an unknown
// one. Anything this cannot read (a radial mask, a corner gradient, no mask at
// all) returns null and the caller asks BOTH axes, which can never produce a
// note about an axis it did not measure.
export function cueAxisOfMask(mask) {
  if (!mask) return null;
  var m = /linear-gradient\(([^,]*),/.exec(String(mask));
  if (!m) return null;
  var head = m[1].trim().toLowerCase();
  if (head.indexOf("to ") === 0) {
    var w = head.slice(3).trim().split(/\s+/);
    var x = w.indexOf("left") !== -1 || w.indexOf("right") !== -1;
    var y = w.indexOf("top") !== -1 || w.indexOf("bottom") !== -1;
    if (x && y) return "both";
    if (x) return "x";
    if (y) return "y";
    return null;
  }
  var deg = /^(-?[0-9]+(?:\.[0-9]+)?)deg$/.exec(head);
  if (deg) {
    var a = ((parseFloat(deg[1]) % 360) + 360) % 360;
    if (a === 0 || a === 180) return "y";
    if (a === 90 || a === 270) return "x";
    return "both";
  }
  // No direction token: `linear-gradient(<color>, <color>)` is `to bottom`.
  return "y";
}

// Is this element showing an edge cue for an overflow it does not have? The
// question is asked ON THE CUE'S OWN AXIS. `cue` is the value read off the
// element's OWN computed style (see the block above — an inherited-by-the-walk
// value is not this element's cue). An axis this cannot name is asked of BOTH,
// so an unreadable mask makes the note quieter, never louder.
export function cueStuckVerdict(m) {
  if (!(m.cue > 0)) return { note: false, axis: null, why: "no cue on this element's own computed style" };
  var axis = cueAxisOfMask(m.maskImage);
  var asked = (axis === "x" || axis === "y") ? axis : "both";
  var fitsX = !(m.scrollW > m.clientW + 1);
  var fitsY = !(m.scrollH > m.clientH + 1);
  var fits = asked === "x" ? fitsX : asked === "y" ? fitsY : (fitsX && fitsY);
  if (!fits) {
    return {
      note: false, axis: asked,
      why: asked === "x"
        ? "clipped on x (scrollWidth " + m.scrollW + " > clientWidth " + m.clientW + ") — the cue is telling the truth"
        : "clipped on " + asked + " (scrollHeight " + m.scrollH + " > clientHeight " + m.clientH + ") — the cue is telling the truth",
    };
  }
  return {
    note: true, axis: asked,
    why: "fits on " + asked + " (w " + m.scrollW + "/" + m.clientW + ", h " + m.scrollH + "/" + m.clientH + ")",
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  LEG A — parsing
// ─────────────────────────────────────────────────────────────────────────────

// Strip /* … */ comments. CSS comments do not nest; a comment opened and never
// closed swallows the rest of the file (which is exactly bug #4592's shape, and
// __css_check.mjs E10 owns detecting it — here the safe reading is "everything
// after an unterminated opener is a comment", i.e. contributes no breakpoints).
export function stripCssComments(css) {
  let out = "";
  let i = 0;
  while (i < css.length) {
    const open = css.indexOf("/*", i);
    if (open === -1) { out += css.slice(i); break; }
    out += css.slice(i, open);
    const close = css.indexOf("*/", open + 2);
    if (close === -1) break; // unterminated — the rest is comment
    i = close + 2;
  }
  return out;
}

const NUM = "(\\d+(?:\\.\\d+)?)";
const UNIT = "([a-z%]*)";

// Resolve one comparison to the BOUNDARY width — the largest width at which the
// low side of the comparison still holds. max-width:N and (width <= N) are both
// N; min-width:N and (width >= N) are both N-1, because the change happens
// between N-1 and N. Returns null for a unit this parser will not guess at.
export function boundaryOf(kind, value, unit) {
  if (unit !== "px" && unit !== "") return null;
  if (!Number.isInteger(value)) return null;
  switch (kind) {
    case "max": return value;      // (max-width: N) / (width <= N)
    case "lt": return value - 1;   // (width < N)
    case "min": return value - 1;  // (min-width: N) / (width >= N)
    case "gt": return value;       // (width > N)
    default: return null;
  }
}

// Parse ONE media query (one comma-separated clause of a prelude) along ONE
// axis — `width` or `height`. Returns { boundaries: number[], unresolved:
// string[] }. A clause with no token for THIS axis at all
// (prefers-reduced-motion, print, or a pure width query when asked about
// height) contributes nothing and is not unresolved — it is simply not
// axis-bearing.
//
// THE AXIS IS A PARAMETER BECAUSE THE HEIGHT HALF WAS BEING EATEN. Until
// cch-w16-s2 this function was width-only and returned early on
// `!/\bwidth\b/`, so a `@media (max-height: 600px)` prelude was PARSED,
// COUNTED in `rep.preludes.length`, and then silently discarded — and
// `(max-width: 720px) and (max-height: 400px)` was worse: the width eater
// consumed the only `width` token before the residue test, so the height half
// vanished with NO `unresolved` entry at all. Asking the same parser the same
// question about the other axis is what makes the discard impossible.
export function parseAxisClause(clause, axis = "width") {
  const boundaries = [];
  const tok = new RegExp(`\\b${axis}\\b`);
  if (!tok.test(clause)) return { boundaries, unresolved: [] };
  let rest = clause;
  // CONSUME ONLY WHAT WE RESOLVED. `take` returns the boundaries it understood,
  // or null. On null the matched text is left in `rest` ON PURPOSE, so the
  // "still carries the token width" check below fires: an em-based or
  // calc()-based width that the parser eats but cannot resolve would DISAPPEAR
  // SILENTLY, which is precisely the failure this leg exists to prevent
  // (measured: `(max-width: 50em)` originally exited 0 with the axis unchanged).
  const eat = (re, take) => {
    rest = rest.replace(re, (...m) => {
      const b = take(m);
      if (b == null) return m[0];
      for (const x of [].concat(b)) boundaries.push(x);
      return " ";
    });
  };
  const both = (a, b) => (a == null || b == null ? null : [a, b]);
  // (min-width: 700px) / (max-width: 720px)
  eat(new RegExp(`\\(\\s*(min|max)-${axis}\\s*:\\s*${NUM}${UNIT}\\s*\\)`, "gi"),
    (m) => boundaryOf(m[1].toLowerCase(), Number(m[2]), m[3].toLowerCase()));
  // (400px <= width <= 800px) — two-sided range, both edges are breakpoints
  eat(new RegExp(`${NUM}${UNIT}\\s*(<=|<)\\s*${axis}\\s*(<=|<)\\s*${NUM}${UNIT}`, "gi"),
    (m) => both(
      boundaryOf(m[3] === "<=" ? "min" : "gt", Number(m[1]), m[2].toLowerCase()),
      boundaryOf(m[4] === "<=" ? "max" : "lt", Number(m[5]), m[6].toLowerCase()),
    ));
  // (width <= 812px) / (width > 900px)
  eat(new RegExp(`${axis}\\s*(<=|<|>=|>)\\s*${NUM}${UNIT}`, "gi"),
    (m) => boundaryOf({ "<=": "max", "<": "lt", ">=": "min", ">": "gt" }[m[1]], Number(m[2]), m[3].toLowerCase()));
  // (812px >= width) — the mirrored one-sided form
  eat(new RegExp(`${NUM}${UNIT}\\s*(<=|<|>=|>)\\s*${axis}`, "gi"),
    (m) => boundaryOf({ "<=": "min", "<": "gt", ">=": "max", ">": "lt" }[m[3]], Number(m[1]), m[2].toLowerCase()));
  // (width: 800px) — an exact-width query is a boundary on both sides of itself
  eat(new RegExp(`\\(\\s*${axis}\\s*:\\s*${NUM}${UNIT}\\s*\\)`, "gi"),
    (m) => { const b = boundaryOf("max", Number(m[1]), m[2].toLowerCase()); return b == null ? null : [b - 1, b]; });

  // Anything still carrying this axis's token was NOT understood. Refuse rather
  // than drop it — a width this sweep cannot read is a width it cannot cover.
  const unresolved = tok.test(rest) ? [clause.trim()] : [];
  return { boundaries, unresolved };
}

export const parseWidthClause = (clause) => parseAxisClause(clause, "width");
export const parseHeightClause = (clause) => parseAxisClause(clause, "height");

// Every axis-bearing @media prelude in a stylesheet → its boundaries, for BOTH
// axes. `breakpoints`/`unresolved` are the width axis (the names predate the
// height half and the whole epic quotes them); `heights`/`heightUnresolved` are
// the height axis, which on today's app.css is EMPTY — see legA's output, which
// says so out loud rather than printing a green that means nothing.
export function parseMediaBreakpoints(css) {
  const src = stripCssComments(css);
  const preludes = [];
  const re = /@media([^{]*)\{/g;
  let m;
  while ((m = re.exec(src)) !== null) preludes.push(m[1].trim());
  const boundaries = new Set();
  const heights = new Set();
  const unresolved = [];
  const heightUnresolved = [];
  for (const p of preludes) {
    for (const clause of p.split(",")) {
      const r = parseWidthClause(clause);
      for (const b of r.boundaries) boundaries.add(b);
      unresolved.push(...r.unresolved);
      // THE SAME CLAUSE, ASKED AGAIN ABOUT THE OTHER AXIS. This is what stops
      // `(max-width: 720px) and (max-height: 400px)` from losing its height
      // half: the width pass eats the width tokens and reports the clause
      // clean, and this pass reads 400 out of the same string.
      const h = parseHeightClause(clause);
      for (const b of h.boundaries) heights.add(b);
      heightUnresolved.push(...h.unresolved);
    }
  }
  return {
    preludes,
    breakpoints: [...boundaries].sort((a, b) => a - b), unresolved,
    heights: [...heights].sort((a, b) => a - b), heightUnresolved,
  };
}

// The registered screens: `<section class="view" id="view-…">`. Class-first so a
// `<section class="archives-panel">` nested INSIDE a view is not counted.
export function parseViewIds(html) {
  const ids = [];
  const re = /<section\b[^>]*\bclass="view"[^>]*\bid="([^"]+)"/g;
  let m;
  while ((m = re.exec(html)) !== null) ids.push(m[1]);
  return ids;
}

// cch-w46-s7 — THE STATIC SHELL'S OWN CONTROLS, for an instrument that cannot
// otherwise see them.
//
// WHY THIS LIVES HERE AND NOT IN THE SWEEP: it is a pure regex over the SAME
// artifact parseViewIds above already reads, in the same shape, and this file
// is the one place in the harness that owns "what index.html statically
// declares". The member-authority sweep imports it.
//
// WHY IT IS NEEDED AT ALL: smoke.mjs NEVER reads index.html — its only
// readFileSync targets ../app.js and makeDom() synthesizes an EMPTY document.
// So every control the shell authors statically (#overview-launch,
// #fleet-launch) is invisible to a registry-bytes sweep: it has no mount whose
// innerHTML carries it. This reader is the only door to them.
//
// SCOPE, deliberately narrow and stated: id-bearing control tags only. A
// control the shell authors WITHOUT an id is not returned — it has no stable
// identity to account for, and inventing an ordinal one over a hand-authored
// file would red on any reflow. That omission is named in the sweep's header
// as a blind spot rather than hidden here.
const STATIC_CONTROL_TAGS = "button|a|input|select|textarea|summary";
export function parseStaticControlIds(html) {
  const ids = [];
  const re = new RegExp("<(" + STATIC_CONTROL_TAGS + ")\\b([^>]*)>", "gi");
  let m;
  while ((m = re.exec(html)) !== null) {
    const id = /\bid="([^"]+)"/.exec(m[2] || "");
    if (id) ids.push(id[1]);
  }
  return ids;
}

// The THEME axis, derived from the two artifacts and NOTHING else.
//
// SCOPED TO `data-theme` EXPLICITLY, AND THAT SCOPE IS LOAD-BEARING. The console
// carries a SECOND, ORTHOGONAL switch: `data-bp-theme` accent IDENTITY, five
// values in app.css (charple, ember, evergreen, fjord, iris) generated from
// BP_THEMES (`grep -n 'var BP_THEMES' app.js`), and the shell's root element
// carries one of them. A derivation written as "any data-*theme* selector"
// derives SEVEN members, not two, and
// reds on an unmutated tree the day it lands. Identity is a SEPARATE AXIS with
// its own owner — gr-blk-accent-scenario-sweep — and this sweep does not claim
// it.
//
// The `light` member is declared in the SHELL, not the stylesheet: app.css has
// 19 `[data-theme="dark"]` selectors and no light ones, because light is the
// `:root` default that index.html's root element names. Reading both artifacts
// is what makes the census 2 rather than 1.
// The OTHER theme attribute, counted only so the header can name what this
// sweep is NOT claiming. Never part of the theme axis.
export function accentIdentities(css) {
  const out = new Set();
  const re = /\[data-bp-theme\s*=\s*["']?([a-z0-9_-]+)["']?\s*\]/gi;
  let m;
  const src = stripCssComments(css);
  while ((m = re.exec(src)) !== null) out.add(m[1].toLowerCase());
  return [...out].sort();
}

export function parseThemeMembers(css, html) {
  const members = new Set();
  const re = /\[data-theme\s*=\s*["']?([a-z0-9_-]+)["']?\s*\]/gi;
  let m;
  const src = stripCssComments(css);
  while ((m = re.exec(src)) !== null) members.add(m[1].toLowerCase());
  // The shell's ROOT default — read from the <html> tag ONLY, never from the
  // pre-paint script that merely calls setAttribute("data-theme", …).
  const root = html.match(/<html\b[^>]*>/i);
  if (root) {
    const a = root[0].match(/\bdata-theme\s*=\s*["']([^"']+)["']/i);
    if (a) members.add(a[1].toLowerCase());
  }
  return [...members].sort();
}

// ONE helper, BOTH directions, for every axis. `uncovered` = the artifact
// declares a value the sweep does not drive; `phantom` = the sweep drives a
// value the artifact no longer declares.
//
// THE PHANTOM HALF IS NOT SYMMETRY FOR ITS OWN SAKE — it is the whole of
// cch-w15-bl-lega-cannot-refuse-removed-breakpoint. Before this, a stylesheet
// that DROPPED the 900px breakpoint exited 0 while BREAKPOINTS still declared
// it: Leg B kept driving 899/900/901 against a rule that no longer existed, and
// Leg A printed a header whose two halves disagreed — four breakpoints DERIVED
// from the stylesheet against thirteen boundary widths walked from the five the
// literal still declared — under a green coverage tick.
//   THAT EXACT STATE WAS THEN REACHED FOR REAL, and the refusal caught it:
// cch-w16-s8 deleted the `max-width: 900px` tier rule, and with the literal not
// yet shrunk Leg A exited 2 naming `PHANTOM breakpoint 900px`. Four breakpoints
// is now the CORRECT derived count at the time (620/720/768/899 -> 12 widths;
// W17-S6 has since added 830, making it five and 15); the tell was
// never the number four, it was four derived against a thirteen-width walk.
export function axisCoverage(derived, declared) {
  const d = new Set(declared.map(String));
  const s = new Set(derived.map(String));
  return {
    uncovered: derived.filter((x) => !d.has(String(x))),
    phantom: declared.filter((x) => !s.has(String(x))),
  };
}

// The SCENARIO axis: every scenario is either rendered by a cell or carries a
// committed residue entry naming its family. Four refusals, all fatal:
//   · unlisted  — a new scenario with neither a cell nor a residue entry
//   · stale     — a residue entry naming a scenario that no longer exists
//   · promoted  — a residue entry for a scenario that has since gained a cell
//   · drift     — a residue entry whose recorded family is no longer the family
//                 `familyOf` derives (the reason it points at stopped applying)
// plus two on the reason table itself: a family with no written reason, and a
// written reason no entry uses.
export function scenarioReport({ scenarios, cells = CELLS, residue = SCENARIO_RESIDUE, reasons = RESIDUE_FAMILY_REASONS }) {
  const names = Object.keys(scenarios);
  const known = new Set(names);
  const covered = new Set(cells.map((c) => c.scen));
  const listed = Object.keys(residue);

  const unlisted = names.filter((n) => !covered.has(n) && !(n in residue));
  const stale = listed.filter((n) => !known.has(n));
  const promoted = listed.filter((n) => covered.has(n));
  const drift = listed
    .filter((n) => known.has(n) && !covered.has(n))
    .map((n) => ({ name: n, was: residue[n], now: familyOf(scenarios[n]) }))
    .filter((r) => r.was !== r.now);
  const phantomCells = [...covered].filter((s) => !known.has(s));
  const families = [...new Set(listed.map((n) => residue[n]))].sort();
  const unexplained = families.filter((f) => !reasons[f]);
  const staleReasons = Object.keys(reasons).filter((f) => !families.includes(f));

  return {
    total: names.length, cells: cells.length, distinctCovered: covered.size,
    residue: listed.length, families: families.length,
    unlisted, stale, promoted, drift, phantomCells, unexplained, staleReasons,
    ok: !unlisted.length && !stale.length && !promoted.length && !drift.length &&
      !phantomCells.length && !unexplained.length && !staleReasons.length,
  };
}

// The whole of Leg A's judgement, as a pure function of the artifacts and the
// sweep's own tables. Everything the refusal compares against is PASSED IN (the
// caller hands it WIDTHS/CELLS/THEMES/HEIGHTS/…) so the refusal is about what
// the sweep DRIVES, never about a second literal that could drift from it.
export function coverageReport({
  css, html, widths = WIDTHS, cells = CELLS,
  breakpointsDeclared = BREAKPOINTS, themes = THEMES, heights = HEIGHTS,
  scenarios = SCENARIOS, residue = SCENARIO_RESIDUE,
}) {
  const { preludes, breakpoints, unresolved, heights: derivedHeights, heightUnresolved } = parseMediaBreakpoints(css);
  const views = parseViewIds(html);
  const w = new Set(widths);
  const covered = new Set(cells.map((c) => c.view));

  const uncoveredBreakpoints = breakpoints
    .map((b) => ({ b, missing: [b - 1, b, b + 1].filter((x) => !w.has(x)) }))
    .filter((r) => r.missing.length > 0);
  // The other direction: a breakpoint the sweep still declares and drives that
  // the stylesheet has stopped declaring.
  const phantomBreakpoints = axisCoverage(breakpoints, breakpointsDeclared).phantom;
  const uncoveredViews = views.filter((v) => !covered.has(v));
  const phantomViews = [...covered].filter((v) => !views.includes(v));

  const derivedThemes = parseThemeMembers(css, html);
  const theme = axisCoverage(derivedThemes, themes);

  // HEIGHT IS ASYMMETRIC ON PURPOSE. `uncovered` is real: a height-bearing
  // @media the declared set does not carry must refuse. `phantom` is NOT asked
  // — HEIGHTS is a DECLARED axis (no artifact declares one; see the block above
  // HEIGHTS), so every one of its values would read as phantom and the sweep
  // would red permanently on an untouched tree. Saying which half is asked is
  // the difference between an honest instrument and one that looks thorough.
  const height = { uncovered: axisCoverage(derivedHeights, heights).uncovered, derived: derivedHeights };

  const scen = scenarioReport({ scenarios, cells, residue });

  return {
    preludes, breakpoints, views, unresolved,
    widths: [...widths], cells: cells.length,
    uncoveredBreakpoints, phantomBreakpoints, uncoveredViews, phantomViews,
    themes: { derived: derivedThemes, declared: [...themes], ...theme },
    heights: { declared: [...heights], derived: derivedHeights, uncovered: height.uncovered, unresolved: heightUnresolved },
    scenarios: scen,
    ok: unresolved.length === 0 && heightUnresolved.length === 0 &&
      uncoveredBreakpoints.length === 0 && phantomBreakpoints.length === 0 &&
      uncoveredViews.length === 0 && phantomViews.length === 0 &&
      theme.uncovered.length === 0 && theme.phantom.length === 0 &&
      height.uncovered.length === 0 && scen.ok,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
//  browser plumbing (findChrome + Cdp taken from cssom-parity.mjs, unchanged)
// ─────────────────────────────────────────────────────────────────────────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function findChrome() {
  if (process.env.CHROME) {
    try { fs.accessSync(process.env.CHROME, fs.constants.X_OK); return process.env.CHROME; }
    catch { return null; }
  }
  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/google-chrome-stable",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* next */ }
  }
  return null;
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id == null) return;
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.method + ": " + JSON.stringify(msg.error)));
      else p.resolve(msg.result);
    });
    ws.addEventListener("close", () => {
      for (const [, p] of this.pending) p.reject(new Error("CDP socket closed"));
      this.pending.clear();
    });
  }

  static async connect(wsUrl) {
    const ws = new WebSocket(wsUrl);
    await new Promise((resolve, reject) => {
      ws.addEventListener("open", resolve, { once: true });
      ws.addEventListener("error", () => reject(new Error("CDP connect failed: " + wsUrl)), { once: true });
    });
    return new Cdp(ws);
  }

  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    const frame = { id, method, params };
    if (sessionId) frame.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject: (e) => reject(Object.assign(e, { method })) });
      try { this.ws.send(JSON.stringify(frame)); }
      catch (e) { this.pending.delete(id); reject(e); }
    });
  }

  close() { try { this.ws.close(); } catch { /* already gone */ } }
}

// ─────────────────────────────────────────────────────────────────────────────
//  the in-page probes
// ─────────────────────────────────────────────────────────────────────────────

// The axis the BROWSER sees: every media rule's conditionText, walked
// recursively (a @media nested in @supports is still a media rule).
const CSSOM_AXIS_JS = `(function(){
  var out=[];
  function walk(rules){
    for (var i=0;i<rules.length;i++){
      var r=rules[i];
      if (r.media && r.conditionText!=null) out.push(r.conditionText);
      if (r.cssRules) walk(r.cssRules);
    }
  }
  for (var s=0;s<document.styleSheets.length;s++){
    var sh=document.styleSheets[s];
    try { walk(sh.cssRules); } catch(e) { /* cross-origin */ }
  }
  return out;
})()`;

function cellProbeJs(cell) {
  const hiding = JSON.stringify(HIDING_UTILITIES);
  const cueProps = JSON.stringify(NAMED_CUE_PROPS);
  // THE SAME FUNCTION, NOT A COPY OF IT. cueAxisOfMask/cueStuckVerdict are
  // injected by source, so the unit suite drives the very code the browser
  // runs — a second implementation in the test file would be a story about
  // the pixels (charter GR118), which is the mistake this file is built to
  // avoid. Neither function may reference module scope or use a template
  // literal: it lands inside this one.
  return `(function(){
  ${cueAxisOfMask.toString()}
  ${cueStuckVerdict.toString()}
  var HIDING=${hiding}, CUEPROPS=${cueProps};
  var FORM={SELECT:1,INPUT:1,TEXTAREA:1,BUTTON:1};
  var CLIPPY={hidden:1,clip:1,auto:1,scroll:1};
  var d=document.documentElement;
  var vw=d.clientWidth;
  function sel(el){
    var s=el.tagName.toLowerCase();
    if (el.id) s+='#'+el.id;
    var cl=(el.getAttribute('class')||'').trim().split(/\\s+/).filter(Boolean).slice(0,2);
    if (cl.length) s+='.'+cl.join('.');
    return s;
  }
  // ── liveness, three clauses ────────────────────────────────────────────────
  var live=null, views=document.querySelectorAll('section.view');
  for (var i=0;i<views.length;i++){ if(!views[i].hidden){ live=views[i]; break; } }
  var want=document.getElementById(${JSON.stringify(cell.view)});
  var liveId = live ? live.id : null;
  var wantBox = want ? want.getBoundingClientRect() : null;
  var sentinel = document.querySelector(${JSON.stringify(cell.sentinel)});
  var liveness = {
    liveId: liveId,
    hidden: want ? !!want.hidden : true,
    h: wantBox ? Math.round(wantBox.height*100)/100 : 0,
    textLen: want ? (want.textContent||'').trim().length : 0,
    sentinel: !!sentinel,
    // what IS present, so a stale sentinel is debuggable rather than opaque
    present: live ? Array.prototype.slice.call(live.querySelectorAll('*'))
        .map(function(e){return sel(e);}).slice(0,25) : [],
  };
  liveness.ok = (liveId===${JSON.stringify(cell.view)}) && !liveness.hidden && liveness.h>0 && liveness.sentinel;

  // ── Q1 sideways ────────────────────────────────────────────────────────────
  var q1={sw:d.scrollWidth, cw:d.clientWidth, over:d.scrollWidth>d.clientWidth};

  // ── Q2 clipped without a cue ───────────────────────────────────────────────
  var q2=[], hiddenSkipped=0;
  var all=document.body.querySelectorAll('*');
  for (var k=0;k<all.length;k++){
    var el=all[k];
    if (el.hasAttribute('hidden')) continue;
    var cs=getComputedStyle(el);
    if (cs.display==='none'||cs.visibility==='hidden') continue;
    var cls=(el.getAttribute('class')||'').split(/\\s+/);
    var hid=false;
    for (var h=0;h<HIDING.length;h++) if (cls.indexOf(HIDING[h])!==-1) hid=true;
    if (hid) { hiddenSkipped++; continue; }
    var r=el.getBoundingClientRect();
    if (r.width<1||r.height<1) continue;
    var isForm=!!FORM[el.tagName];
    // (a) native controls are UA-painted: ask the box directly, never the CSSOM
    var clipped = isForm
      ? (el.scrollWidth > el.clientWidth+1)
      : (!!CLIPPY[cs.overflowX] && el.scrollWidth > el.clientWidth+1);
    // VISIBLE_SPILL's failing sub-case. An element inside a scroller is not
    // spilling — it is scrolling, which is what .set-matrix (correctly cued,
    // gr-backlog-setmatrix-scroll-affordance is done) does with 21 of its own
    // descendants at 768. Only an element with NO clipping ancestor between it
    // and <html> can push the PAGE, and only then does a right edge past the
    // viewport mean a person is looking at a cut-off box.
    // The right edge of what this element actually PAINTS: its own box, or its
    // content when the content is wider than the box. A block-level row is
    // clamped to its container's width, so rect.right alone reads "inside the
    // viewport" while its min-content children push the page 21px sideways —
    // measured on #fleet-body at 769, the exact cell this sub-case exists for.
    // An element that CLIPS its own overflow paints only up to its box (that is
    // what .set-matrix does, correctly cued, with content 29px wider than the
    // viewport at 768). Only a NON-clipping element paints its whole content.
    var paintedRight = (CLIPPY[cs.overflowX] || isForm) ? r.right : Math.max(r.right, r.left + el.scrollWidth);
    var cut = Math.round((paintedRight - vw)*100)/100;
    if (cut > 0.5 && !contained(el)) q2.push({kind:'CUT_BY_VIEWPORT', sel:sel(el), cut:cut});
    if (!clipped) {
      // The IFF half: a cue live on something that FITS is a lie too — ON THE
      // AXIS THE CUE PAINTS ON. Still asked ONLY of scroll containers, now on
      // EITHER axis (a --nav-fade strip scrolls vertically; its overflow-x
      // computes auto only because CSS coerces visible when the other axis is
      // not visible, which is exactly why the horizontal-only guard let 78
      // vertical notes through). cf.own, not cf.cue: see the CUE_STUCK block
      // above the probe.
      if (!isForm && (CLIPPY[cs.overflowX] || CLIPPY[cs.overflowY])) {
        var cf=cueOf(el);
        var vd=cueStuckVerdict({
          cue: cf.own,
          maskImage: cs.maskImage || cs.webkitMaskImage || '',
          scrollW: el.scrollWidth, clientW: el.clientWidth,
          scrollH: el.scrollHeight, clientH: el.clientHeight,
        });
        if (cf.own>0) q2.push({kind: vd.note ? 'CUE_STUCK' : 'CUE_HONEST',
                               sel:sel(el), cue:cf.own, axis:vd.axis, why:vd.why,
                               sw:el.scrollWidth, cw:el.clientWidth,
                               sh:el.scrollHeight, ch:el.clientHeight});
      }
      continue;
    }
    var c=cueOf(el);
    // text-overflow: ellipsis IS an authored cue — the "…" is the affordance
    // that tells a person the string continues — but ONLY when the element can
    // actually PAINT one (ellipsisCanPaint below —
    // cchi-w21-bl-clip-no-cue-exempts-inert-ellipsis). It counts ONLY for
    // non-form elements: a UA-painted <select> computes an ellipsis it does
    // not necessarily paint, which would silence correction (a) — measured on
    // select#site-theme-select.rail-select, the one selector this sweep is
    // supposed to catch.
    if (!isForm && cs.textOverflow==='ellipsis' && ellipsisCanPaint(cs)) c.cue=Math.max(c.cue,1);
    if (c.track<=0 && c.cue<=0) {
      q2.push({kind:'CLIP_NO_CUE', sel:sel(el), tag:el.tagName, sw:el.scrollWidth, cw:el.clientWidth,
               overflowX:cs.overflowX,
               inertEllipsis:(!isForm && cs.textOverflow==='ellipsis'),
               text:(el.tagName==='SELECT'&&el.selectedOptions&&el.selectedOptions[0]?el.selectedOptions[0].text:(el.textContent||'').trim().slice(0,40))});
    }
  }
  // Can a computed text-overflow: ellipsis actually PAINT on this element?
  // DRIVEN, not reasoned — headless-Chrome twin screenshots (te:ellipsis vs
  // te:clip on otherwise-identical boxes; differing pixels = the "…" painted),
  // charter D253's decoded-PNG probe independently agrees. The verdicts:
  //   · a FLEX or GRID container lays out ITEMS, not line boxes, so it has
  //     nothing to ellipsize: a squeezed display:flex chip measures sw 152 >
  //     cw 60 and its twins are pixel-IDENTICAL — whatever white-space says.
  //     app.css's own .billing-chip review comment states exactly this.
  //   · a BLOCK container that measured a HORIZONTAL clip (the only way into
  //     this arm — the clipped gate is sw > cw+1) has, by that measurement,
  //     a line that could not break at the box edge, and Chrome paints the
  //     "…" on an overflowing line REGARDLESS of white-space: nowrap paints,
  //     pre paints, plain normal with an unbreakable token paints (D253's
  //     refutation of the nowrap-only doctrine), and even overflow-wrap:
  //     anywhere paints when the overflow comes from a nowrap child — with
  //     anywhere live and only breakable text, the text wraps and sw never
  //     exceeds cw, so that host never reaches this arm at all.
  //   · display:-webkit-box paints ONLY its live -webkit-line-clamp ellipsis
  //     (driven: clamp vs plain overflow:hidden twins differ); a clamp
  //     declared on any other display does nothing.
  // KNOWN LIMIT, AND IT STAYS HERE ON PURPOSE (cchi-w23-bl-d253-inert-
  // ellipsis-correction-five-sites, the break-opportunity upgrade). A block
  // host whose overflowing line holds ONLY atomic inlines (an inline-block
  // child) paints no "…" yet is exempted here. CONFIRMED on the GATING-PLATFORM
  // re-run of D253's decoded-pixel probe (Ubuntu 24.04.4 LTS, Google Chrome
  // 151.0.7922.71): white-space nowrap + text-overflow ellipsis over one
  // inline-block child, sw 408 / cw 200, inks to x=199 — the box edge — so no
  // marker painted at all. (Byte-identical pixel hash 2ebf2e95 on a Chromium
  // 152 / Debian 12 second run: this host is engine behaviour, not a build.)
  //
  // THE CORRECTION LANDED IN overflow-guard.mjs's MEMBERS LEG, NOT HERE, and
  // the reason is the shape of this function, not the size of the job. The
  // measured predicate needs a MIN-CONTENT WIDTH and a TEXT-RUN WIDTH per
  // element: a hidden width:min-content clone appended into the element's own
  // parent, plus Range rects over its text nodes. The members leg spends that
  // on the handful of .set-row-name elements in 44 cells. cueOf above runs
  // over EVERY element of EVERY page at EVERY width — a forced-layout clone and
  // a Range walk per element would turn a declaration read into an O(n) reflow
  // storm, and this sweep's whole value is that it is cheap enough to run over
  // everything.
  //
  // SO THE PREDICATE HERE IS DELIBERATELY THE CONSERVATIVE HALF. It is exact on
  // the two cases it CAN decide from declarations alone (a flex/grid box has no
  // line boxes to ellipsize; a display:-webkit-box paints only its live clamp),
  // and on everything else it says "assume it paints" — which EXEMPTS, i.e.
  // stays SILENT, rather than accusing. The residue is therefore a MISS, never
  // a false red: an atomic-inline line reaches CLIP_NO_CUE and is not reported.
  // inertEllipsis is recorded on every CLIP_NO_CUE row above precisely so a
  // reader can see which exemptions rode on a declaration this function did not
  // measure.
  function ellipsisCanPaint(cs){
    if (cs.display==='-webkit-box')
      return !!cs.webkitLineClamp && cs.webkitLineClamp!=='none';
    if (cs.display==='flex'||cs.display==='inline-flex'||
        cs.display==='grid'||cs.display==='inline-grid'||
        cs.display==='table'||cs.display==='inline-table') return false;
    return true;
  }
  // Does anything between el and <html> clip or scroll? If so el is CONTAINED:
  // its overhang is the container's business, not the page's.
  function contained(el){
    for (var n=el.parentElement; n && n!==document.documentElement; n=n.parentElement){
      var s=getComputedStyle(n);
      if (CLIPPY[s.overflowX]) return true;
    }
    return false;
  }
  function cueOf(el){
    // (b) the reserved horizontal track — 0px in this console under BOTH
    //     --hide-scrollbars and classic scrollbars, which is exactly why it
    //     cannot be the only cue test.
    var cs=getComputedStyle(el);
    var bl=parseFloat(cs.borderLeftWidth)||0, br=parseFloat(cs.borderRightWidth)||0;
    var track=Math.round((el.offsetWidth - el.clientWidth - bl - br)*100)/100;
    var cue=0, own=0, depth=0;
    for (var n=el; n && n!==document.documentElement; n=n.parentElement, depth++){
      var s=getComputedStyle(n);
      var here=0;
      for (var i=0;i<s.length;i++){
        var p=s[i];
        if (p.slice(0,2)==='--' && /(fade|cue)/.test(p)){
          var v=parseFloat(s.getPropertyValue(p));
          if (v>0) here=Math.max(here,v);
        }
      }
      for (var j=0;j<CUEPROPS.length;j++){
        var v2=parseFloat(s.getPropertyValue(CUEPROPS[j]));
        if (v2>0) here=Math.max(here,v2);
      }
      // own is the cue as CSS sees it on THIS element: a registered
      // inherits:false property computes its initial 0px on a descendant, an
      // unregistered one computes the inherited value. cue keeps the ancestor
      // walk, which is what CLIP_NO_CUE reads.
      if (depth===0) own=here;
      if (here>0) { cue=Math.max(cue,here); break; }
    }
    return {track:track, cue:cue, own:own};
  }

  // ── Q3 below the fold ──────────────────────────────────────────────────────
  var content=document.querySelector('.content');
  var q3={top: content ? Math.round(content.getBoundingClientRect().top*100)/100 : null,
          vh: window.innerHeight};

  // ── the theme this page ACTUALLY loaded ────────────────────────────────────
  // Reported, not assumed. The ?theme= param is seeded into localStorage by mock.js
  // before first paint; if that ever stops working the sweep would render 2N
  // cells of the SAME mode and call it a two-theme run. The body background is
  // carried alongside because it is the cheapest proof that the two loads are
  // not the same pixels — a flipped attribute leaves it unchanged.
  var themeState = {attr: d.getAttribute('data-theme'),
                    bg: getComputedStyle(document.body).backgroundColor};

  return {liveness:liveness, q1:q1, q2:q2, q3:q3, hiddenSkipped:hiddenSkipped,
          themeState: themeState,
          sentinelProp: getComputedStyle(d).getPropertyValue('--bpsweep-cell')};
})()`;
}

// ─────────────────────────────────────────────────────────────────────────────
//  the run
// ─────────────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f) => { const i = argv.indexOf(f); return i === -1 ? null : argv[i + 1]; };

const out = (s) => process.stdout.write(s);
// A path a human can act on: repo-relative when we are inside the tree, and the
// absolute path when we are measuring an exported one (a ../../../.. chain is
// not a location, it is a puzzle).
const rel = (p) => { const r = path.relative(process.cwd(), p); return !r ? "." : (r.startsWith("..") ? p : r); };
// SYNCHRONOUS stderr. `process.stderr.write` to a PIPE is asynchronous, so a
// refusal that writes and then calls process.exit() loses most of its own
// message the moment anyone runs this under `| tail` — measured: a 6-cell
// dead-cell report printed ONE cell. A refusal nobody can read is a refusal
// that did not happen.
const shout = (msg) => {
  // fs.writeSync to a PIPE can write PARTIALLY — measured: a multi-cell
  // refusal truncated mid-word. Loop until every byte is out.
  const buf = Buffer.from(msg, "utf8");
  let off = 0;
  while (off < buf.length) {
    try { off += fs.writeSync(2, buf, off, buf.length - off); }
    catch (e) { if (e.code === "EAGAIN") continue; process.stderr.write(buf.slice(off).toString("utf8")); return; }
  }
};
const refuse = (msg) => { shout(`\n!! BREAKPOINT SWEEP (exit 2): ${msg}\n`); process.exit(2); };

function readOr(p, what) {
  try { return fs.readFileSync(p, "utf8"); }
  catch { refuse(`cannot read ${what} at ${p}. Environment refusal — nothing has been measured.`); }
}

function legA() {
  const css = readOr(CSS_PATH, "the stylesheet");
  const html = readOr(HTML_PATH, "the shell");
  const rep = coverageReport({ css, html });

  const rawMedia = (css.match(/@media/g) || []).length;
  out(`>> source     ${rel(CSS_PATH)} · ${rel(HTML_PATH)}\n`);
  out(`>> @media     ${rep.preludes.length} preludes (comment-stripped; the raw grep counts ${rawMedia} — app.css:2131 names a breakpoint INSIDE a comment)\n`);
  out(`>> axis       ${rep.breakpoints.length} breakpoints [${rep.breakpoints.join(",")}] -> ${rep.widths.length} boundary widths [${rep.widths.join(",")}]\n`);
  out(`>> screens    ${rep.views.length} registered views · ${rep.cells} scenario x route cells covering ${COVERED_VIEWS.length}\n`);
  out(`>> themes     derived [${rep.themes.derived.join(",")}] vs declared [${rep.themes.declared.join(",")}] — COVERAGE, NOT YIELD: ` +
    `app.css's dark rules touch only background/color/border-color, so the CSS structurally cannot produce a theme-dependent geometry defect. ` +
    `A green here means both modes were LOADED, not that a bug was found. Accent identity (data-bp-theme, ${accentIdentities(css).length} values: ` +
    `${accentIdentities(css).join(",")}) is a SEPARATE axis, owned by gr-blk-accent-scenario-sweep — this sweep does not claim it.\n`);
  out(`>> heights    declared [${rep.heights.declared.join(",")}] · derived ${rep.heights.derived.length} height-bearing @media` +
    (rep.heights.derived.length === 0
      ? ` — VACUOUSLY GREEN: app.css declares ZERO height-bearing @media today, so the derived half refuses NOTHING. It exists for the day one appears.\n`
      : ` [${rep.heights.derived.join(",")}]\n`));
  out(`>> scenarios  ${rep.scenarios.total} scenarios · ${rep.scenarios.distinctCovered} distinct covered by ${rep.scenarios.cells} cells · ` +
    `${rep.scenarios.residue} residue over ${rep.scenarios.families} families (committed literal)\n`);

  const problems = [];
  for (const u of rep.unresolved) problems.push(`UNPARSEABLE width condition: "${u}" — the sweep will not guess at a width it cannot read.`);
  for (const u of rep.heights.unresolved) problems.push(`UNPARSEABLE height condition: "${u}" — the sweep will not guess at a height it cannot read.`);
  for (const r of rep.uncoveredBreakpoints) problems.push(`UNCOVERED breakpoint ${r.b}px — the boundary walk is missing ${r.missing.join(", ")}. Add it to BREAKPOINTS.`);
  for (const b of rep.phantomBreakpoints) problems.push(`PHANTOM breakpoint ${b}px — BREAKPOINTS declares it and Leg B drives ${[b - 1, b, b + 1].join("/")}, but the stylesheet no longer declares it. Dead widths under a green tick is what this refusal exists to stop (cch-w15-bl-lega-cannot-refuse-removed-breakpoint).`);
  for (const v of rep.uncoveredViews) problems.push(`UNCOVERED screen #${v} — no cell in CELLS renders it. Add a scenario x route cell (with a sentinel).`);
  for (const v of rep.phantomViews) problems.push(`PHANTOM screen #${v} — CELLS drives it but index.html no longer registers it.`);
  for (const t of rep.themes.uncovered) problems.push(`UNCOVERED theme "${t}" — the artifacts declare it and Leg B never loads it. Add it to THEMES.`);
  for (const t of rep.themes.phantom) problems.push(`PHANTOM theme "${t}" — THEMES drives it but neither app.css nor the shell declares it any more.`);
  for (const h of rep.heights.uncovered) problems.push(`UNCOVERED height ${h}px — a height-bearing @media the declared HEIGHTS [${rep.heights.declared.join(",")}] does not carry. Add it to HEIGHTS with a written reason.`);
  const S = rep.scenarios;
  for (const n of S.unlisted) problems.push(`UNLISTED scenario "${n}" (family ${familyOf(SCENARIOS[n])}) — no cell renders it and SCENARIO_RESIDUE does not carry it. Give it a cell, or a residue entry naming why not.`);
  for (const n of S.stale) problems.push(`STALE residue entry "${n}" — the literal names a scenario scenarios.mjs no longer defines. Prune it. (This is exit 2, NOT a console.log — __css_check's stale-allowlist reporter exits 0 and that is the one thing not to copy.)`);
  for (const n of S.promoted) problems.push(`STALE residue entry "${n}" — it has GAINED a cell, so the residue reason no longer applies. Remove it from SCENARIO_RESIDUE.`);
  for (const d of S.drift) problems.push(`DRIFTED residue entry "${d.name}" — recorded family ${d.was}, derived family is now ${d.now}. The reason it points at is about a different route.`);
  for (const s of S.phantomCells) problems.push(`PHANTOM cell scenario "${s}" — a cell drives it but scenarios.mjs no longer defines it.`);
  for (const f of S.unexplained) problems.push(`UNEXPLAINED residue family ${f} — entries point at it and RESIDUE_FAMILY_REASONS has no written reason for it.`);
  for (const f of S.staleReasons) problems.push(`STALE residue reason ${f} — RESIDUE_FAMILY_REASONS explains a family no entry uses any more.`);

  if (problems.length) {
    shout(`\n!! BREAKPOINT SWEEP (exit 2): the sweep has no coverage for what the artifact now declares.\n` +
      problems.map((p) => `   · ${p}\n`).join(""));
    process.exit(2);
  }
  out(`   ✓ coverage — every declared breakpoint is boundary-walked (and every walked one is still declared), every registered screen has a cell,\n` +
    `               both theme members are declared and driven, no height-bearing @media is uncovered, and all ${rep.scenarios.total} scenarios are either rendered or named in the residue\n`);
  return rep;
}

// ── shared browser bring-up for --cssom / --render ───────────────────────────
const SERVER_CAP = 8000, DEVTOOLS_CAP = 15000, SETTLE_CAP = 5000, BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000, KILL_POLL_CAP = 2000;

async function withBrowser(fn) {
  const chromeBin = findChrome();
  if (!chromeBin) {
    refuse(process.env.CHROME
      ? `CHROME=${process.env.CHROME} is not an executable file. Environment refusal, not a layout defect.`
      : "no Chrome/Chromium found. Set CHROME=/path/to/chrome.");
  }
  // THE EXPORT'S OWN serve.mjs. serve.mjs roots itself at its own parent
  // directory, so measuring an exported origin/main tree means running THAT
  // tree's server — not this worktree's server pointed elsewhere.
  const serveChild = spawn("node", [path.join(ROOT, "__preview__", "serve.mjs"), "--port", String(PORT)], { stdio: "ignore" });
  let chrome = null, cdp = null, profile = null;
  const alive = (p) => { if (!p || p.pid == null) return false; try { process.kill(p.pid, 0); return true; } catch { return false; } };
  const reap = async (p) => {
    if (!alive(p)) return;
    try { p.kill("SIGTERM"); } catch { /* gone */ }
    let waited = 0;
    while (alive(p) && waited < TERM_POLL_CAP) { await sleep(50); waited += 50; }
    if (alive(p)) {
      try { p.kill("SIGKILL"); } catch { /* gone */ }
      waited = 0;
      while (alive(p) && waited < KILL_POLL_CAP) { await sleep(50); waited += 50; }
      if (alive(p)) process.stderr.write(`!! TEARDOWN SHOUT: pid ${p.pid} SURVIVED SIGKILL. Reap it by hand: kill -9 ${p.pid}\n`);
    }
  };
  const teardown = async () => {
    if (cdp) { await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]); cdp.close(); }
    await reap(chrome);
    await reap(serveChild);
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
  };
  const die = async (msg, code = 2) => { await teardown(); process.stderr.write(`\n!! BREAKPOINT SWEEP (exit ${code}): ${msg}\n`); process.exit(code); };

  let up = false;
  for (let w = 0; w < SERVER_CAP; w += 100) {
    try { const r = await fetch(`${BASE}/app.css`, { cache: "no-store" }); if (r.ok) { up = true; break; } } catch { /* not yet */ }
    await sleep(100);
  }
  if (!up) return die(`no server answered on :${PORT} within ${SERVER_CAP}ms`);

  // SERVED BYTES == DISK BYTES. 20 worktrees share this checkout and a foreign
  // preview server has squatted this port class before, making a patched run
  // print baseline numbers. Refuse rather than certify bytes we did not author.
  for (const rel of ["/app.css", "/app.js", "/__preview__/mock.js", "/__preview__/scenarios.mjs"]) {
    const served = Buffer.from(await (await fetch(`${BASE}${rel}`, { cache: "no-store" })).arrayBuffer());
    const disk = fs.readFileSync(path.join(ROOT, rel.slice(1)));
    if (!served.equals(disk)) {
      // NAME THE DIFFERENCE, NOT THE SIZES. This compares CONTENT, so a
      // length-preserving edit — a digit changed in a width, a token renamed to
      // the same length — used to print "served 233681 B, disk holds 233681 B"
      // and offer two EQUAL numbers as its evidence of inequality. The first
      // differing byte offset (with both bytes) says what actually differs; the
      // lengths follow only when they differ too.
      let at = 0;
      const min = Math.min(served.length, disk.length);
      while (at < min && served[at] === disk[at]) at++;
      const where = at < min
        ? `first differs at byte ${at}: served 0x${served[at].toString(16).padStart(2, "0")}, disk 0x${disk[at].toString(16).padStart(2, "0")}`
        : `identical through ${min} B, then TRUNCATED/EXTENDED`;
      const sizes = served.length === disk.length
        ? `both ${served.length} B`
        : `served ${served.length} B, disk holds ${disk.length} B`;
      return die(`STALE SERVER on :${PORT} — ${rel} differs from disk (${sizes}; ${where}). A server rooted at a DIFFERENT tree is squatting this port; measuring against it would certify the wrong bytes.`);
    }
  }
  out(`>> serve      :${PORT} — served bytes == disk bytes (${rel(ROOT)})\n`);

  // D101 BRING-UP RETRY (deploy-reliability wave 8). Bounded, a FRESH profile
  // dir per attempt (it used to be mkdtemp'd once, so a retry would re-race the
  // same DevToolsActivePort path), and every failed attempt's Chrome stderr is
  // printed — `stdio: "ignore"` discarded exactly the line that says why.
  //
  // THE LINE THIS RETRY MUST NOT CROSS. cch-w19-bl-gr115's "do not paper over
  // the race" ruling governs exit-1 MEASURED intermittency — the browser came
  // up, the sweep measured, and it disagreed with itself between runs. This
  // retries only the exit-2 case where Chrome never came up: no width was
  // rendered, so there is no claim for a retry to hide. Everything after
  // `devPort` is a measurement and is never retried.
  let attemptSpawnError = null;
  const brought = await bringUpChrome({
    label: "breakpoint-sweep",
    attempts: BRINGUP_ATTEMPTS,
    newProfile: () => fs.mkdtempSync(path.join(os.tmpdir(), "breakpoint-sweep-")),
    launch: (dir) => {
      attemptSpawnError = null;
      const child = spawn(chromeBin, [
        "--headless=new", "--disable-gpu", "--no-sandbox", "--disable-dev-shm-usage",
        "--no-first-run", "--no-default-browser-check", "--disable-extensions",
        "--disable-background-networking", "--hide-scrollbars",
        `--user-data-dir=${dir}`, "--remote-debugging-port=0", "about:blank",
      ], { stdio: ["ignore", "ignore", "pipe"] });
      child.on("error", (e) => { attemptSpawnError = e; });
      return { child, readStderr: captureStderr(child) };
    },
    awaitDevToolsPort: async ({ profile: dir }) => {
      const portFile = path.join(dir, "DevToolsActivePort");
      for (let w = 0; w < DEVTOOLS_CAP; w += 100) {
        if (attemptSpawnError) break;
        try {
          const raw = fs.readFileSync(portFile, "utf8").split("\n");
          if (raw[0] && Number(raw[0])) return Number(raw[0]);
        } catch { /* not written yet */ }
        await sleep(100);
      }
      if (attemptSpawnError) {
        throw new Error(`Chrome could not be executed (${attemptSpawnError.code || attemptSpawnError.message}): ${chromeBin}`);
      }
      return null;
    },
    abandon: async ({ profile: dir, child }) => {
      await reap(child);
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
    },
    log: (s) => process.stderr.write(s),
  }).catch((err) => (err && err.refused ? { refusal: err } : Promise.reject(err)));

  // exit 2, `die`'s default: the browser never started on any bounded attempt.
  if (brought.refusal) return die(brought.refusal.message);
  chrome = brought.child;
  profile = brought.profile;
  const devPort = brought.devPort;

  let version;
  try {
    version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    out(`>> chrome     ${version.Browser} · node ${process.version}\n`);
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);
  } catch (err) {
    return die(`CDP bring-up failed: ${err.message}`);
  }

  // A FRESH TARGET PER CELL is what buys liveness: Page.navigate to a URL that
  // differs only in its hash is a SAME-DOCUMENT navigation, so a previous
  // cell's stylesheet state and injected rules survive into the next one.
  const openCell = async () => {
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    await cdp.send("Runtime.enable", {}, sessionId);
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Network.enable", {}, sessionId);
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true }, sessionId);
    return { targetId, sessionId };
  };
  const closeCell = async (targetId) => { try { await cdp.send("Target.closeTarget", { targetId }); } catch { /* gone */ } };
  // Navigate a cell's own target (always cross-document — the target was parked
  // on about:blank) and poll until the screen has PAINTED. The 16ms settle is
  // deliberate: a double-requestAnimationFrame settle HANGS under headless=new.
  //
  // WHAT IS POLLED IS THE CELL'S SENTINEL, NOT A SHELL CONTAINER. Measured the
  // hard way: #token-list, #activity-body, #archives-body and #instance-tabpanel
  // are all STATIC in index.html, so polling them returns true on the first
  // tick — before the SPA has painted anything — and the cell then measures an
  // empty shell. Six cells read DEAD for exactly that reason and passed the
  // moment they were driven alone (a timing artefact, not a content one).
  //
  // A miss RETURNS FALSE rather than throwing: the three-clause liveness
  // refusal below owns the verdict, and its message carries the `present:`
  // diagnostic a bare timeout does not.
  const navSettle = async (sessionId, url, readyExpr, cap = SETTLE_CAP) => {
    await cdp.send("Page.navigate", { url }, sessionId);
    for (let w = 0; w < cap; w += 50) {
      let ready = false;
      // Pinned OUTSIDE the catch: a swallowed refusal would burn the whole cap
      // and then report the three-clause liveness miss — a font fault wearing
      // a dead-cell's clothes.
      try { ready = !!(await evalJs(sessionId, `!!(${readyExpr})`)); } catch { /* navigating */ }
      if (ready) { await pinFonts(sessionId, url); await sleep(16); return true; }
      await sleep(50);
    }
    await sleep(16);
    return false;
  };

  // THE FONT PIN (D218). Every cell height and every clipped-text verdict this
  // sweep prints is a layout of whatever face resolved; until both families are
  // proven present, every green here is font-conditional. See font-pin.mjs for
  // why load() precedes ready (a ready-only pin reports two SHIPPED mono
  // weights false on a perfectly healthy page).
  //
  // THE CORRECTED CI MECHANISM (cchi-w20-bl-breakpoint-sweep-fonts-blind):
  // D218's original story said Inter may not RESOLVE on ubuntu-latest. Wrong
  // half: Inter is SELF-HOSTED (app.css @font-face, src url(fonts/
  // Inter-var.woff2)) and serve.mjs serves the .woff2 off disk on the same
  // origin, so it resolves everywhere. What is not guaranteed is IN TIME —
  // font-display: swap paints fallback metrics first, and under
  // setCacheDisabled/no-store a slow disk or loaded runner re-runs that race
  // on every navigation. The pin does not wait out the race; it forces the
  // load (face.load() before fonts.ready, check() after), which is why it
  // belongs in navSettle and not in a sleep. Mutation-measured on this tree:
  // pin bypassed + Inter-var.woff2 hidden -> rc 0 'clean across 2 cells' (a
  // fiction, measured silently); pin active + same hidden face -> exit 2
  // naming 'Inter=false IBM Plex Mono=true'.
  //
  // It needs its OWN Runtime.evaluate because evalJs below passes
  // `awaitPromise: false` — through that helper the pin would come back as an
  // unresolved Promise handle, i.e. truthy garbage, and the guard would be
  // green by construction.
  //
  // Refusal is exit 2 via die(): a missing woff2 is an ENVIRONMENT fault, not
  // a cell that overflows.
  const pinFonts = async (sessionId, url) => {
    let report = null;
    try {
      const r = await cdp.send(
        "Runtime.evaluate",
        { expression: FONT_PIN_JS, returnByValue: true, awaitPromise: true },
        sessionId,
      );
      if (r.exceptionDetails) {
        return die(fontPinRefusal(url, null) +
          ` The pin itself threw: ${r.exceptionDetails.exception?.description || r.exceptionDetails.text}`);
      }
      report = r.result.value;
    } catch (err) {
      return die(fontPinRefusal(url, null) + ` CDP evaluate failed: ${err.message}`);
    }
    if (!report || !report.ok) return die(fontPinRefusal(url, report));
  };

  const evalJs = async (sessionId, expression) => {
    const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: false }, sessionId);
    if (r.exceptionDetails) throw new Error("page eval threw: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
    return r.result.value;
  };

  try {
    return await fn({ cdp, evalJs, navSettle, openCell, closeCell, die, teardown });
  } finally {
    await teardown();
  }
}

async function legCssom(rep) {
  return withBrowser(async ({ evalJs, navSettle, openCell, closeCell, die }) => {
    const { targetId, sessionId } = await openCell();
    if (!await navSettle(sessionId, `${BASE}/?scen=empty&theme=light`, `document.styleSheets.length>0`)) {
      return die(`the preview shell never loaded a stylesheet — nothing to compare the parsed axis against.`);
    }
    const conditions = await evalJs(sessionId, CSSOM_AXIS_JS);
    await closeCell(targetId);

    const browser = new Set();
    const unresolved = [];
    for (const c of conditions) {
      const r = parseWidthClause(c);
      for (const b of r.boundaries) browser.add(b);
      unresolved.push(...r.unresolved);
    }
    const browserAxis = [...browser].sort((a, b) => a - b);
    const sourceAxis = rep.breakpoints;
    out(`>> cssom      ${conditions.length} media rules -> [${browserAxis.join(",")}]\n`);
    out(`>> source     ${rep.preludes.length} preludes    -> [${sourceAxis.join(",")}]\n`);
    const same = browserAxis.length === sourceAxis.length && browserAxis.every((b, i) => b === sourceAxis[i]);
    if (!same || unresolved.length) {
      out(`   parity=DIVERGED\n`);
      const only = (a, b) => a.filter((x) => !b.includes(x));
      if (only(sourceAxis, browserAxis).length) out(`   · source-only: ${only(sourceAxis, browserAxis).join(",")}\n`);
      if (only(browserAxis, sourceAxis).length) out(`   · browser-only: ${only(browserAxis, sourceAxis).join(",")}\n`);
      for (const u of unresolved) out(`   · UNPARSEABLE in the CSSOM: "${u}"\n`);
      return die(`--cssom parity=DIVERGED — the axis this sweep parses is NOT the axis the browser builds. Nothing has been certified.`);
    }
    out(`   ✓ parity=IDENTICAL — the parsed axis is the axis the browser builds\n`);
    return 0;
  });
}


// ─────────────────────────────────────────────────────────────────────────────
//  THE TIER-CTA TENSE PROBE — billing-trial only, inside the committed job.
// ─────────────────────────────────────────────────────────────────────────────
//  cch-bl-tier-card-free-button-still-future-tense-for-a-lapsed-trial.
//
//  WHY IT LIVES IN legRender AND NOT IN THE tiers5 LEG: `tier-floor-render` in
//  console-harness.yml invokes `--render --widths 901 --cell billing-trial`, and
//  the tiers5 leg is invoked by NO workflow (its own header says so). The row
//  requires the geometry gate to MEASURE the new lapsed-trial label rather than
//  be waved past it, so the measurement has to be reachable from the command CI
//  actually runs.
//
//  WHAT IT MEASURES: the billing-trial scenario carries a LIVE trial, so the
//  screen the generic probe measured shows only "Yours when the trial ends".
//  This probe re-renders the SHIPPED three-plan catalog into the REAL
//  #billing-tiers under the REAL app.css twice — once with the live clock and
//  once with a lapsed one (trialDays 0) — and asks the same question of both:
//  does any CTA clip? Same splice technique the tiers5 leg uses, same stated
//  LIMIT: it proves LAYOUT, never behaviour (splicing bypasses renderTiers, so
//  no click handler is wired).
//
//  NON-VACUITY IS CHECKED, NOT ASSUMED: it refuses unless the two passes really
//  produced two DIFFERENT Free labels. A probe that renders the same label twice
//  and reports "no clipping" would certify the lapsed label without ever having
//  drawn it — the exact way a geometry gate goes blind.
function tierLabelProbeJs() {
  return `(function(){
  var hooks = globalThis.__bpHooks;
  if (!hooks || typeof hooks.tierCardHtml !== 'function' || !Array.isArray(hooks.planCatalog))
    return { refused: '__bpTestHook delivered no tierCardHtml/planCatalog — app.js\\'s export tail changed shape, so the tier CTA tense is measuring nothing' };
  var grid = document.querySelector('#billing-tiers');
  if (!grid || grid.hidden) return { refused: '#billing-tiers is absent or hidden — the billing screen never populated' };
  var catalog = hooks.planCatalog;
  var freeCount = catalog.filter(function (t) { return t.free; }).length;
  if (freeCount !== 1) return { refused: 'the shipped catalog carries ' + freeCount + ' free tier(s); this probe asks about exactly one' };
  var passes = [];
  [['live', undefined], ['lapsed', 0]].forEach(function (pair) {
    grid.innerHTML = catalog.map(function (t) {
      return hooks.tierCardHtml(t, 'trial', false, undefined, pair[1]);
    }).join('');
    var cards = grid.querySelectorAll('.tier');
    var btns = grid.querySelectorAll('.tier .btn');
    var freeBtn = grid.querySelector('.tier-free .btn');
    var clipped = [];
    Array.prototype.forEach.call(btns, function (b) {
      if (b.scrollWidth > b.clientWidth) {
        var tier = b.closest('.tier');
        clipped.push({
          plan: tier ? (tier.querySelector('.tier-name') || {}).textContent : '?',
          sw: b.scrollWidth, cw: b.clientWidth, text: (b.textContent || '').trim(),
        });
      }
    });
    passes.push({
      tense: pair[0],
      cards: cards.length,
      btns: btns.length,
      freeLabel: freeBtn ? (freeBtn.textContent || '').trim() : null,
      freeW: freeBtn ? Math.round(freeBtn.scrollWidth) : null,
      boxW: freeBtn ? Math.round(freeBtn.clientWidth) : null,
      clipped: clipped,
    });
  });
  for (var i = 0; i < passes.length; i++) {
    if (passes[i].cards !== catalog.length || passes[i].btns !== catalog.length)
      return { refused: 'the ' + passes[i].tense + ' pass rendered ' + passes[i].cards + ' cards / ' + passes[i].btns + ' buttons for a ' + catalog.length + '-plan catalog — a card with no control makes this measurement vacuous' };
    if (!passes[i].freeLabel)
      return { refused: 'the ' + passes[i].tense + ' pass rendered no .tier-free CTA at all' };
  }
  if (passes[0].freeLabel === passes[1].freeLabel)
    return { refused: 'both passes rendered the SAME Free CTA (' + JSON.stringify(passes[0].freeLabel) + ') — the lapsed-trial label was never drawn, so a clean verdict here would certify a label nothing measured' };
  return { passes: passes };
})()`;
}

async function legRender(rep) {
  const widthFilter = valOf("--widths");
  const cellFilter = valOf("--cell");
  const widths = widthFilter ? widthFilter.split(",").map(Number) : rep.widths;
  const { cells, unknown } = selectCells(CELLS, cellFilter);
  // NAME EACH UNKNOWN ONE. "matches no cell" over the whole filter is what let a
  // typo narrow the run silently — the operator has to be told WHICH name the
  // sweep did not recognise, and the run must not proceed on the remainder.
  if (unknown.length) {
    refuse(`--cell named ${unknown.length} cell${unknown.length > 1 ? "s" : ""} that do${unknown.length > 1 ? "" : "es"} not exist: ` +
      `${unknown.map((n) => `"${n}"`).join(", ")}. Refusing rather than narrowing to the ${cells.length} that matched — a run over ` +
      `fewer cells than you asked for reports a clean verdict for a sweep that never happened.\n   Known: ${CELLS.map((c) => c.name).join(", ")}`);
  }
  if (!cells.length) refuse(`--cell "${cellFilter}" selected no cell. Known: ${CELLS.map((c) => c.name).join(", ")}`);

  // The THEME axis, sliceable the same way and refusing the same way.
  const themeFilter = valOf("--theme");
  const { selected: themes, unknown: unknownThemes } = selectNames(THEMES, themeFilter);
  if (unknownThemes.length) {
    refuse(`--theme named ${unknownThemes.length} theme${unknownThemes.length > 1 ? "s" : ""} that do${unknownThemes.length > 1 ? "" : "es"} not exist: ` +
      `${unknownThemes.map((t) => `"${t}"`).join(", ")}. Known: ${THEMES.join(", ")}`);
  }
  if (!themes.length) refuse(`--theme "${themeFilter}" selected no theme. Known: ${THEMES.join(", ")}`);

  // The HEIGHT axis, sliceable and refusing on the SAME terms. 390 and 667 were
  // declared with written reasons and never driven — cch-w16-bl-legb-drives-
  // one-of-three-heights. --height is what drives them; the DEFAULT stays at
  // RENDER_HEIGHT for the cost stated in HEIGHT_REASONS[800].
  const heightFilter = valOf("--height");
  if (has("--height") && (heightFilter == null || heightFilter.startsWith("--"))) {
    refuse(`--height was given no value. Naming no height is not "all heights" — it is a run nobody described. Known: ${HEIGHTS.join(", ")}`);
  }
  const { selected: heightNames, unknown: unknownHeights } = selectNames(HEIGHTS.map(String), heightFilter);
  if (unknownHeights.length) {
    refuse(`--height named ${unknownHeights.length} height${unknownHeights.length > 1 ? "s" : ""} that ${unknownHeights.length > 1 ? "are" : "is"} not declared: ` +
      `${unknownHeights.map((h) => `"${h}"`).join(", ")}. Refusing rather than narrowing to the ${heightNames.length} that matched — a height this sweep does not declare has no written reason, ` +
      `and a run at an undeclared height publishes a number for a viewport nobody chose.\n   Known: ${HEIGHTS.map((h) => `${h} (${HEIGHT_REASONS[h].split(".")[0]})`).join(" · ")}`);
  }
  if (!heightNames.length) refuse(`--height "${heightFilter}" selected no height. Known: ${HEIGHTS.join(", ")}`);
  const heights = heightFilter ? heightNames.map(Number) : [...RENDER_HEIGHTS_DEFAULT];

  return withBrowser(async ({ cdp, evalJs, navSettle, openCell, closeCell, die }) => {
    const total = cells.length * themes.length * heights.length * widths.length;
    out(`\n>> render     ${cells.length} cells x ${themes.length} themes x ${heights.length} height${heights.length > 1 ? "s" : ""} [${heights.join(",")}] x ${widths.length} widths = ${total} renders — MINUTES, not seconds\n`);
    if (!heightFilter) {
      out(`              height loop = 1 BY DEFAULT (${RENDER_HEIGHT}px). The full leg is 25x2x1x21 = 1050 renders (12.8 min at 0.73s/cell); walking all ${HEIGHTS.length} declared heights makes it 3150 (38.3 min). Opt in with --height ${HEIGHTS.join(",")}.\n`);
    }
    const dead = [], q1f = [], q2f = [], q3f = [], notes = [], honest = [];
    const tierCtaF = [], tierCtaSeen = [];
    const bgSeen = new Map();
    const t0 = Date.now();
    let done = 0;

    const heightSeen = new Set();
    const q3Worst = new Map();
    for (const cell of cells) {
     for (const theme of themes) {
      for (const height of heights) {
      const row = [];
      for (const width of widths) {
        const { targetId, sessionId } = await openCell();
        try {
          // cch-bl-tier-card — the hook receiver for the tier-CTA tense probe
          // below, installed BEFORE app.js parses and ONLY for the cell that
          // uses it (an accessor, not an assignment: see TIERS5_HOOK_TAP for the
          // measured reason mock.js would otherwise overwrite it). Every other
          // cell renders exactly as it did before.
          if (cell.name === "billing-trial") {
            await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: TIERS5_HOOK_TAP }, sessionId);
          }
          await cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false }, sessionId);
          // A FRESH `?theme=` LOAD PER CELL, NEVER A RUNTIME ATTRIBUTE FLIP.
          // A flip leaves the console lying about itself — a verifier measured
          // the body background UNCHANGED at rgb(244,245,247) after flipping
          // data-theme=dark, and #theme-label reads the opposite string under a
          // flip than under a load (`themeLabelText` — re-derive with
          // `grep -n 'function themeLabelText' app.js`), so a flipped run
          // would measure the wrong control text and could not see a
          // theme-differentiated defect at all. mock.js seeds ?theme= into
          // localStorage before first paint, which is why the load is honest.
          const url = `${BASE}/?scen=${cell.scen}&theme=${theme}${cell.hash}`;
          let m = null;
          try {
            await navSettle(sessionId, url, `document.querySelector(${JSON.stringify(cell.sentinel)})`);
            m = await evalJs(sessionId, cellProbeJs(cell));
          } catch (err) {
            dead.push({ cell: cell.name, theme, width, why: err.message.slice(0, 160), present: [] });
            row.push(`${width}:DEAD`);
            continue;
          }
          // ── the theme axis is DRIVEN, and that is checked ────────────────
          // A cell that asked for dark and rendered light is the theme-axis
          // twin of a render-dead cell: it publishes a plausible number for a
          // mode nobody measured.
          if (m.themeState.attr !== theme) {
            dead.push({
              cell: cell.name, theme, width, present: [],
              why: `asked for ?theme=${theme} and the document loaded data-theme=${m.themeState.attr} — the fresh load did not take, so this cell measured the wrong mode.`,
            });
            row.push(`${width}:DEAD`);
            continue;
          }
          bgSeen.set(theme, m.themeState.bg);

          // ── the height axis is DRIVEN, and that is checked ───────────────
          // The twin of the theme-drive clause above, and the exact defect
          // cch-w16-bl-legb-drives-one-of-three-heights names: the loop can
          // ASK for 390 and the override can silently not take, and every
          // number below would then be a measurement of the wrong viewport
          // published under the right label. window.innerHeight is read back
          // per cell; a mismatch is a DEAD cell, never a warning.
          if (m.q3.vh !== height) {
            dead.push({
              cell: cell.name, theme, width, present: [],
              why: `asked for a ${height}px viewport and the document reported window.innerHeight ${m.q3.vh} — the height override did not take, so this cell measured a viewport nobody chose.`,
            });
            row.push(`${width}:DEAD`);
            continue;
          }
          heightSeen.add(m.q3.vh);

          // ── clause 1+2+3, hard ────────────────────────────────────────────
          if (!m.liveness.ok) {
            const L = m.liveness;
            // THE COUNTER-EXAMPLE, stated in the report rather than left to be
            // inferred: when the right screen is live and populated-LOOKING but
            // the sentinel is absent, a two-clause check (right view + visible)
            // would have PASSED this cell and measured an empty-state box.
            const weakWouldPass = L.liveId === cell.view && !L.hidden && L.h > 0 && !L.sentinel;
            dead.push({
              cell: cell.name, theme, width,
              why: `live view #${L.liveId} (wanted #${cell.view}), hidden:${L.hidden}, h:${L.h}, textLen:${L.textLen}, sentinel(${cell.sentinel}):${L.sentinel}` +
                (weakWouldPass ? `\n     CLAUSE 3 IS WHY THIS IS DEAD: clauses 1+2 alone (right view, hidden:${L.hidden}, h:${L.h}, textLen:${L.textLen}) would have PASSED this cell and measured an empty state.` : ""),
              present: L.present,
            });
            row.push(`${width}:DEAD`);
            continue;
          }
          if (m.q1.over) q1f.push({ cell: cell.name, theme, width, sw: m.q1.sw, cw: m.q1.cw });
          for (const f of m.q2) {
            if (f.kind === "CUE_STUCK") notes.push({ cell: cell.name, theme, width, ...f });
            else if (f.kind === "CUE_HONEST") honest.push({ cell: cell.name, theme, width, ...f });
            else q2f.push({ cell: cell.name, theme, width, ...f });
          }
          const top = m.q3.top;
          if (top != null) {
            // QUOTED WHETHER IT PASSES OR NOT. Q3 used to print only on
            // failure, so the fold number at a height was invisible unless it
            // was already over budget — and "no Q3 line" read the same as
            // "the height was never driven".
            const w = q3Worst.get(height);
            if (!w || top > w.top) q3Worst.set(height, { top, budget: Math.round(FOLD_FRACTION * m.q3.vh), cell: cell.name, theme, width });
            if (top > FOLD_FRACTION * m.q3.vh) {
              q3f.push({ cell: cell.name, theme, width, height, top, budget: Math.round(FOLD_FRACTION * m.q3.vh) });
            }
          }
          // ── the tier-CTA tense probe (billing-trial only) ────────────────
          if (cell.name === "billing-trial") {
            const tl = await evalJs(sessionId, tierLabelProbeJs());
            if (tl.refused) {
              return die(`billing-trial/${theme}@${width}: tier CTA tense probe — ${tl.refused}`);
            }
            for (const pass of tl.passes) {
              tierCtaSeen.push({ theme, width, tense: pass.tense, label: pass.freeLabel, w: pass.freeW, box: pass.boxW });
              for (const c of pass.clipped) tierCtaF.push({ theme, width, tense: pass.tense, ...c });
            }
          }
          row.push(`${width}:${m.q1.sw}${m.q1.over ? "!" : ""}`);
        } finally {
          await closeCell(targetId);
          done++;
        }
      }
      out(`   ${`${cell.name}/${theme}@${height}`.padEnd(30)} ${row.join(" ")}\n`);
      }
     }
    }

    const ms = Date.now() - t0;
    out(`\n>> cost       ${total} cells in ${(ms / 1000).toFixed(1)}s (${(ms / total / 1000).toFixed(2)}s/cell)\n`);

    if (dead.length) {
      // One cell per DISTINCT (cell, reason) — a dead cell is dead at every
      // width, and 13 copies of the same line buries the other five.
      const seen = new Set();
      let msg = `\n!! BREAKPOINT SWEEP (exit 2): ${dead.length}/${total} cells were RENDER-DEAD. A dead cell reports a plausible q1=0/q2=0 for the WRONG SCREEN — refusing to publish any of these numbers.\n`;
      for (const d of dead) {
        const key = `${d.cell}/${d.theme}`;
        if (seen.has(key)) continue;
        seen.add(key);
        msg += `   · ${d.cell}/${d.theme}@${d.width}: ${d.why}\n`;
        if (d.present.length) msg += `     present: ${d.present.slice(0, 16).join(" ")}\n`;
      }
      shout(msg);
      process.exit(2);
    }
    out(`   ✓ liveness — ${total}/${total} cells rendered the screen they asked for, populated (3-clause)\n`);
    // NOT VACUOUS, AND SAID SO WITH A NUMBER: every cell was loaded at the
    // theme it asked for, and these are the body backgrounds those loads
    // produced. Identical values across themes would mean the axis is driving
    // the same pixels twice.
    out(`   ✓ themes — ${[...bgSeen].map(([t, bg]) => `${t} loaded (body ${bg.replace(/\s+/g, "")})`).join(" · ")}\n`);
    // THE HEIGHT AXIS, RECONCILED AGAINST WHAT THE VIEWPORT ACTUALLY WAS. Not
    // "the loop asked for these" — window.innerHeight came back from every
    // cell and this is that set. A height asked for and never measured is a
    // REFUSAL (exit 2): it is the instrument lying about its own coverage,
    // which is a claim about the instrument, not about the product.
    const hd = heightDriveReport({ asked: heights, seen: heightSeen });
    if (!hd.ok) {
      shout(`\n!! BREAKPOINT SWEEP (exit 2): the height axis was ASKED for [${hd.asked.join(",")}] and MEASURED [${[...heightSeen].sort((a, b) => a - b).join(",")}].\n` +
        (hd.undriven.length ? `   · NEVER DRIVEN: ${hd.undriven.join(", ")} — every number above was taken at a height this run claims to have covered and did not.\n` : "") +
        (hd.unasked.length ? `   · DRIVEN BUT NOT ASKED: ${hd.unasked.join(", ")} — the viewport was not the one the loop set.\n` : ""));
      process.exit(2);
    }
    out(`   ✓ heights — ${hd.driven.length}/${hd.asked.length} declared height(s) DRIVEN and read back from window.innerHeight: ${hd.driven.join(", ")}\n`);
    out(`   ✓ Q3 fold — worst .content top per height: ${[...q3Worst].sort((a, b) => a[0] - b[0]).map(([h, w]) => `${h}px -> ${w.top} against a ${w.budget}px budget (${FOLD_FRACTION} of H) [${w.cell}/${w.theme}@${w.width}]`).join(" · ")}\n`);

    for (const f of q1f) out(`   ✗ Q1 SIDEWAYS  ${f.cell}/${f.theme}@${f.width}: scrollWidth ${f.sw} > viewport ${f.cw}\n`);
    for (const f of q2f) {
      if (f.kind === "CLIP_NO_CUE") {
        // Name the blind spot at the point of evidence: a UA-painted control
        // whose computed overflow-x is not a clipping value is invisible to
        // every CSSOM-keyed version of this question.
        const uaBlind = ["SELECT", "INPUT", "TEXTAREA", "BUTTON"].includes(f.tag) && !["hidden", "clip", "auto", "scroll"].includes(f.overflowX);
        out(`   ✗ Q2 CLIP_NO_CUE  ${f.cell}/${f.theme}@${f.width}: ${f.sel} <${f.tag}> scrollWidth ${f.sw} > clientWidth ${f.cw} (overflow-x:${f.overflowX}) "${f.text}"` +
          (uaBlind ? ` — CLASSIFIED BY TAG: a CSSOM-keyed rule (overflow-x in {hidden,clip}) reports 0 for this cell` : "") + `\n`);
      }
      else out(`   ✗ Q2 CUT_BY_VIEWPORT  ${f.cell}/${f.theme}@${f.width}: ${f.sel} extends ${f.cut}px past the viewport\n`);
    }
    for (const f of q3f) out(`   ✗ Q3 BELOW THE FOLD  ${f.cell}/${f.theme}@${f.width}x${f.height}: .content starts ${f.top}px down (budget ${f.budget}px)\n`);
    // WHY THE ZERO IS NOT A BLIND SPOT. CUE_STUCK went from 78 notes to 0 on
    // `--cell operator --widths 390,619,720`, and a note count that falls to
    // zero is indistinguishable from a probe that stopped looking — unless it
    // says what it DID see. Every live cue the arm measured is counted here,
    // split into the ones telling the truth (clipped on the cue's own axis)
    // and the ones that are not. `counting doors is not counting what a door
    // sees`: this line is the door's own report.
    {
      const cueSeen = honest.length + notes.length;
      const byKey = new Map();
      for (const h of honest) { const k = `${h.sel}|${h.axis}`; if (!byKey.has(k)) byKey.set(k, h); }
      out(`   ✓ cue census — ${cueSeen} live edge cue(s) measured across ${total} cells: ${honest.length} honest (clipped on the cue's own axis), ${notes.length} STUCK\n`);
      for (const h of [...byKey.values()].slice(0, 8)) {
        out(`        · ${h.sel} ${h.cue}px ${h.axis === "x" ? "horizontal" : h.axis === "y" ? "vertical" : h.axis} — ${h.why} [${h.cell}/${h.theme}@${h.width}]\n`);
      }
    }
    for (const n of notes) out(`   · note CUE_STUCK  ${n.cell}/${n.theme}@${n.width}: ${n.sel} shows a ${n.cue}px ${n.axis === "x" ? "horizontal" : n.axis === "y" ? "vertical" : "edge"} cue while it FITS on ${n.axis === "both" ? "BOTH axes" : `${n.axis}`} (w ${n.sw}/${n.cw}, h ${n.sh}/${n.ch})\n`);

    // THE TIER CTA IN BOTH TENSES — printed whether it passes or not, for the
    // reason the Q3 line gives: a number that appears only on failure reads the
    // same as a probe that stopped looking.
    if (tierCtaSeen.length) {
      const byTense = new Map();
      for (const t of tierCtaSeen) {
        const w = byTense.get(t.tense);
        if (!w || t.w > w.w) byTense.set(t.tense, t);
      }
      out(`   ✓ tier CTA — ${tierCtaSeen.length} Free-tier CTA measurement(s) across both trial tenses: ` +
        [...byTense].map(([tense, t]) => `${tense} "${t.label}" widest ${t.w}px in a ${t.box}px box [@${t.width}/${t.theme}]`).join(" · ") + `\n`);
    }
    for (const f of tierCtaF) {
      out(`   ✗ TIER CTA CLIPPED  billing-trial/${f.theme}@${f.width} (${f.tense} trial): ${String(f.plan).trim()} "${f.text}" ${f.sw}>${f.cw}\n`);
    }

    const failed = q1f.length + q2f.length + q3f.length + tierCtaF.length;
    if (failed) {
      out(`\n>> verdict    ${failed} measured defects (Q1 ${q1f.length} · Q2 ${q2f.length} · Q3 ${q3f.length} · tier CTA ${tierCtaF.length}) — exit 1\n`);
      return 1;
    }
    out(`\n>> verdict    clean across ${total} cells — exit 0\n`);
    return 0;
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  LEG T — THE FIVE-TIER SEAM (--tiers5)
// ─────────────────────────────────────────────────────────────────────────────
//  NO WORKFLOW INVOKES THIS LEG — IT IS HAND-RUN, AND THAT IS SAID HERE SO A
//  READER NEVER INFERS OTHERWISE (cch-w16-bl-tiers5-leg-runs-nowhere). Re-derive
//  in one command: `git grep -n tiers5 -- .github/` exits 1 with no output. The
//  reason is that this leg guards a catalog that does not exist yet: the shipped
//  PLAN_CATALOG has THREE plans, the two extra tier cards below are a FIXTURE,
//  and the leg's own staleness guard REFUSES (exit 2, "the shipped catalog now
//  has N plans") the day a real fourth plan lands. Wiring a guard whose green
//  certifies a hypothetical, and whose refusal fires on a routine product
//  change, would put a red in front of every console PR that had nothing to do
//  with it — so this is deliberately an instrument you REACH FOR, not one that
//  reaches for you. The committed job that does run on every console PR is
//  `tier-floor-render` in console-harness.yml, which drives the REAL three-plan
//  screen (`--render --widths 901 --cell billing-trial`); this leg answers the
//  different question of what happens when the catalog GROWS.
//    RUN IT BY HAND before adding a plan to the catalog, and after any change to
//  `.tier-grid`'s track floor:
//      node cloud/priv/static/__preview__/breakpoint-sweep.mjs --tiers5
//  COST, measured on this tree and not estimated: 5 renders, ~6s wall including
//  Chrome bring-up (2026-09-02, Chrome 152, node v22.22.0), exit 0 printing
//  `five tier cards fit at every width in [619,901,1040,1200,1700]`. It is
//  cheap enough to wire — the objection is the fixture's staleness, not the
//  seconds — and if the catalog is ever frozen at a known plan count that
//  objection expires and the step belongs in `tier-floor-render`.
//
//  WHY A FIXTURE AT ALL. The shipped catalog has THREE plans, and at wide
//  viewports a three-plan corpus is BLIND to the `.tier-grid` track floor:
//  `auto-fit` collapses the surplus tracks to a literal `0px`, so floors 230
//  and 180 render byte-identically (three cards at 308.664px at 1700). Driven,
//  not reasoned: the 230 value is unguarded across roughly 186-230 at 901 and
//  at EVERY width above it. Adding a fourth plan is a business decision that
//  would today ship a cut CTA at 1700 with every gate green.
//
//  THE GEOMETRY, CORRECTED (D178's arithmetic was off). `.content` caps at
//  1040px and `#billing-plan-section.set-section` adds 20px of padding each
//  side, so the grid box measures 950px — not 992 — at every viewport at or
//  above ~1040. With a 12px gap, n tracks need 242n - 12 px: four 230px tracks
//  need 956px and are UNREACHABLE at any viewport; three fit at 308.664px and
//  five cards wrap 3+2. The real five-track threshold is a floor <= 180.4px
//  (not 188.8): 5 tracks need 5f + 48 <= 950.
//
//  ZERO PRODUCTION CHANGE, AND THE LIMIT THAT BUYS. `tierCardHtml` and
//  `planCatalog` are ALREADY exported on `__bpTestHook`; this leg installs the
//  hook receiver with `Page.addScriptToEvaluateOnNewDocument` BEFORE app.js
//  runs, then splices five hook-rendered cards into the REAL `#billing-tiers`
//  under the REAL app.css. app.js gains no branch on test state (it has zero
//  today and must keep zero), and there is no `GET` plans route to fixture
//  through instead.
//    THE LIMIT, STATED WHERE IT IS INCURRED: splicing bypasses `renderTiers()`,
//  which is what wires `data-plan` / `data-portal-plan` click handlers. This
//  leg therefore proves LAYOUT — that five real tier cards fit without cutting
//  a control — and NEVER behaviour. A five-plan catalog whose cards render but
//  whose Subscribe buttons do nothing would pass this leg.
//
//  WHAT THIS LEG STILL DOES NOT GUARD, DRIVEN: it is a GEOMETRIC guard like
//  the render leg, so it reds where the geometry actually breaks — a 180px
//  floor reds twice (`3trk@185px` at 901, `5trk@180.391px` at 1700, both
//  cutting Free's "Yours when the trial ends") but a 186px floor passes all
//  five widths. Nothing in a browser refuses 186; only the byte-pin in
//  __app.test.mjs refuses the 230 VALUE itself. That is the whole reason the
//  guard ships as a pair plus this seam, and none of the three is redundant.
//
//  Widths are absolute, not boundary-walked: this is a question about the grid
//  box, which only changes at 900 (the two-column @media) and at ~1040 (where
//  `.content` stops growing). 619 is the narrowest cell the sweep drives.
const TIERS5_WIDTHS = [619, 901, 1040, 1200, 1700];

// This leg's OWN render height, deliberately not the module-level one it used to
// borrow. cch-w16-s2 lands in this same file and renames that bare `HEIGHT` const
// to `RENDER_HEIGHT` as a member of a declared height axis — a rename git merges
// CLEANLY against this leg, leaving `HEIGHT is not defined` at run time with no
// conflict marker and no test to catch it (driven on a trial merge of the two
// branches: `!! BREAKPOINT SWEEP (exit 2): unhandled — ReferenceError: HEIGHT is
// not defined`). The height is not a shared axis question here: this leg asks
// about the grid BOX, which is a width question, and 800 only has to be tall
// enough that five cards are laid out rather than reflowed by a scrollbar.
const TIERS5_HEIGHT = 800;

// The two plans that do not exist. Shaped exactly like PLAN_CATALOG's entries
// (`grep -n 'var PLAN_CATALOG' app.js`) so `tierCardHtml` renders them through
// the real path; the copy
// is deliberately plausible-length rather than adversarially long — the point
// is the TRACK WIDTH, not a pathological string.
const TIERS5_EXTRA = [
  { plan: "team", name: "Team", price: "$1,499", per: "/mo", note: "Shared ownership and audit trails.", instances: 25 },
  { plan: "scale", name: "Scale", price: "$3,999", per: "/mo", note: "Dedicated capacity and a support SLA.", instances: 100 },
];

// Runs at document start, before mock.js and before app.js. See the call site
// for why this is an accessor rather than an assignment.
const TIERS5_HOOK_TAP = `(function () {
  var downstream = null;
  Object.defineProperty(globalThis, '__bpTestHook', {
    configurable: true,
    get: function () {
      return function (h) {
        globalThis.__bpHooks = h;
        if (typeof downstream === 'function') downstream(h);
      };
    },
    set: function (fn) { downstream = fn; },
  });
})()`;

function tiers5ProbeJs() {
  return `(function(){
  var hooks = globalThis.__bpHooks;
  if (!hooks || typeof hooks.tierCardHtml !== 'function' || !Array.isArray(hooks.planCatalog))
    return { refused: '__bpTestHook delivered no tierCardHtml/planCatalog — app.js\\'s export tail changed shape, so this fixture is measuring nothing'
      + ' (receiver typeof=' + (typeof globalThis.__bpTestHook) + ', hooks typeof=' + (typeof globalThis.__bpHooks)
      + ', keys=' + (globalThis.__bpHooks ? Object.keys(globalThis.__bpHooks).length : 0) + ')' };
  var grid = document.querySelector('#billing-tiers');
  if (!grid || grid.hidden) return { refused: '#billing-tiers is absent or hidden — the billing screen never populated' };
  var catalog = hooks.planCatalog;
  if (catalog.length !== 3) return { refused: 'the shipped catalog now has ' + catalog.length + ' plans; this fixture adds 2 to reach FIVE and its arithmetic assumes 3' };
  var five = catalog.concat(${JSON.stringify(TIERS5_EXTRA)});
  // 'trial' is the active plan: that is the ONE state in which a person sees
  // the Free tier's "Yours when the trial ends" — the widest CTA in the deck
  // and the exact control D178 measured cut.
  grid.innerHTML = five.map(function (t) { return hooks.tierCardHtml(t, 'trial', false); }).join('');
  var cards = grid.querySelectorAll('.tier');
  var btns = grid.querySelectorAll('.tier .btn');
  if (cards.length !== 5 || btns.length !== 5)
    return { refused: 'the fixture rendered ' + cards.length + ' cards / ' + btns.length + ' buttons, not 5/5 — a card with no control makes this assertion vacuous' };
  var cs = getComputedStyle(grid);
  var tracks = cs.gridTemplateColumns.split(' ').filter(function (s) { return s; });
  var round = function (n) { return Math.round(n * 1000) / 1000; };
  var clipped = [];
  Array.prototype.forEach.call(btns, function (b) {
    if (b.scrollWidth > b.clientWidth) {
      var tier = b.closest('.tier');
      clipped.push({
        plan: tier ? (tier.querySelector('.tier-name') || {}).textContent : '?',
        sw: b.scrollWidth, cw: b.clientWidth, text: (b.textContent || '').trim(),
      });
    }
  });
  return {
    gridW: round(grid.getBoundingClientRect().width),
    tracks: tracks,
    trackW: round(cards[0].getBoundingClientRect().width),
    rows: new Set(Array.prototype.map.call(cards, function (c) { return Math.round(c.getBoundingClientRect().top); })).size,
    clipped: clipped,
  };
})()`;
}

async function legTiers5() {
  return withBrowser(async ({ cdp, evalJs, navSettle, openCell, closeCell, die }) => {
    const cell = CELLS.filter((c) => c.name === "billing-trial")[0];
    if (!cell) return die(`the billing-trial cell is gone from CELLS — this leg has nothing to splice into.`);
    out(`\n>> tiers5     the 3-plan catalog + 2 fixture plans, spliced through __bpTestHook.tierCardHtml\n`);
    out(`              LAYOUT ONLY — splicing bypasses renderTiers(), so data-plan/data-portal-plan wiring is NOT proven here\n`);

    const bad = [];
    for (const width of TIERS5_WIDTHS) {
      const { targetId, sessionId } = await openCell();
      try {
        // Install the hook receiver BEFORE app.js parses. app.js calls
        // globalThis.__bpTestHook(...) at the tail of its IIFE if it is a
        // function; nothing else about its behaviour changes.
        //
        // AN ACCESSOR, NOT AN ASSIGNMENT — measured, not defensive. mock.js
        // installs its OWN `globalThis.__bpTestHook = …` — re-derive it with
        // `grep -n '__bpTestHook' __preview__/mock.js` — keeping the hooks in a
        // module-private `appHooks` to drive the account modal, and it loads
        // AFTER this document-start script, so a plain assignment here is
        // silently overwritten: the first attempt reported
        // `receiver typeof=function, hooks typeof=undefined` — a receiver that
        // was installed, replaced, and never called. The accessor lets both
        // observers win: mock.js's function is remembered by the setter and
        // still invoked, and this leg gets its copy.
        await cdp.send("Page.addScriptToEvaluateOnNewDocument", { source: TIERS5_HOOK_TAP }, sessionId);
        await cdp.send("Emulation.setDeviceMetricsOverride",
          { width, height: TIERS5_HEIGHT, deviceScaleFactor: 1, mobile: false }, sessionId);
        const url = `${BASE}/?scen=${cell.scen}&theme=light${cell.hash}`;
        if (!await navSettle(sessionId, url, `document.querySelector(${JSON.stringify(cell.sentinel)})`)) {
          return die(`billing-trial@${width}: the tier grid never populated — refusing to publish a measurement of an empty screen.`);
        }
        const m = await evalJs(sessionId, tiers5ProbeJs());
        if (m.refused) return die(`billing-trial@${width}: ${m.refused}`);
        const line = `   ${String(width).padEnd(5)} grid ${String(m.gridW).padEnd(9)} ${m.tracks.length}trk@${m.trackW}px  ${m.rows} row(s)`;
        if (m.clipped.length) {
          out(`${line}  ✗ ${m.clipped.length} clipped\n`);
          for (const c of m.clipped) {
            out(`         ✗ CLIPPED CTA  ${String(c.plan).trim()} "${c.text}" ${c.sw}>${c.cw}\n`);
            bad.push({ width, ...c, tracks: m.tracks.length, trackW: m.trackW });
          }
        } else {
          out(`${line}  ✓\n`);
        }
      } finally {
        await closeCell(targetId);
      }
    }

    if (bad.length) {
      out(`\n>> verdict    ${bad.length} clipped control(s) across ${TIERS5_WIDTHS.length} widths — a FIVE-plan catalog would ship a cut CTA today. exit 1\n`);
      return 1;
    }
    out(`\n>> verdict    five tier cards fit at every width in [${TIERS5_WIDTHS.join(",")}] — exit 0\n`);
    return 0;
  });
}

async function main() {
  const rep = legA();
  let code = 0;
  if (has("--cssom")) code = (await legCssom(rep)) || code;
  if (has("--render")) code = (await legRender(rep)) || code;
  if (has("--tiers5")) code = (await legTiers5()) || code;
  process.exit(code);
}

// Importable (the test file imports the pure half) — only run when executed.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => { process.stderr.write(`\n!! BREAKPOINT SWEEP (exit 2): unhandled — ${err && err.stack ? err.stack : err}\n`); process.exit(2); });
}
