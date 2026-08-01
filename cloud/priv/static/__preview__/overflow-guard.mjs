#!/usr/bin/env node
// overflow-guard.mjs — the browser-geometry guard the seal predicate's clause
// (b) shells out to (seal-predicate.mjs → `node overflow-guard.mjs --defect
// <id>`). A missing or failing run here is NO SEAL, never a pass.
//
// ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS IS A BROWSER MEASUREMENT AND NOT A SOURCE REGEX (GR118)
// ─────────────────────────────────────────────────────────────────────────────
//  The predicate's first draft asserted GR108 as "does a .topbar rule exist
//  inside the 768 block" — the charter's THEORY of the cause. Dry-run both
//  directions it was EXACTLY INVERTED: it printed DEFECT against the correct
//  fix (0/44 overflow) and CLEAN against the broken one (14/16 still
//  overflowing). __app.test.mjs is text-based and passed 640/640 on BOTH
//  patches; cssom-parity.mjs asks whether a selector REACHED the CSSOM, and a
//  cascade-dead rule is present in the CSSOM — it just loses. So the dead-rule
//  class had NO coverage from any instrument in this epic. A source regex
//  tests a story about the pixels; only a browser tests the pixels. This file
//  loads the real SPA through serve.mjs, renders it in headless Chrome, and
//  asserts computed style and geometry.
//
//  THE SWEEP GOES ABOVE 768 OR IT CANNOT FAIL (GR116): the broken band reaches
//  ~782 — 769px measured 775.22 light / 776.92 dark pre-fix — so a sweep that
//  stops at the breakpoint goes green while a live scrollbar sits one pixel
//  above it (measured 13/44 failures once the sweep extended past 768).
//
//  THE THREE DEFECTS IT MEASURES
//    GR108-tablet-topbar-overflow   page-level horizontal overflow at
//        721-1440 x 2 themes x 2 past-due scenarios (44 checks), plus the
//        cosmetic half: the past-due billing chip must NOT be truncated at
//        768 — the unconditional min-width:0 pair alone clips the money
//        message, and shipping it without the 768-block trio trades a
//        scrollbar for a truncated "Payment failed · fix billing".
//    GR109-attention-row-dead-rule  at 768 the stacked .attention-row must
//        compute align-items:flex-start with .attention-acts left-aligned to
//        .attention-main (pre-fix: stacked but CENTRED, acts left 441.28).
//        At 900 the row must still be a row (the stack stays scoped <=768).
//    W12-narrow-viewport-truth      PHONE WIDTHS, which every other case here
//        is blind to (WIDTHS starts at 721 — see the honest limit below). Two
//        halves: (a) the page body must not scroll at 320-620 on #overview —
//        pre-fix 496/390 at a 390px viewport, a 106px overhang on every phone
//        in portrait, because a bare `1fr` mobile track floors at the CARD's
//        min-content (480.203px); (b) the notifications channel matrix must
//        TELL a person it continues past the edge — at 390 three of six
//        channels are fully off-screen at scrollLeft 0, and the OS scrollbar
//        is not the fallback (the reserved track measures 0px even in a
//        CLASSIC-scrollbar run). The cue is asserted to appear ONLY while
//        clipped: at 1440 the matrix fits and the fade must read 0px.
//    W13-detail-route-band          THE ROUTES, which every case above is
//        blind to: GR108 sweeps the 721-1440 band but drives only
//        billing-past-due / overview-past-due, and W12 only mixed-fleet
//        #overview and notif-configured#notifications — so no instrument in
//        this epic had ever driven a DETAIL route at any width. Driven on
//        origin/main bytes, five detail routes plus #fleet scrolled the page
//        sideways at 769-899 (panel-overview scrollWidth pinned 837 against a
//        769 viewport, rollback 838, site-states 861): 56 of 286 cells. This
//        leg drives instance-detail / inst-timeline / inst-metrics /
//        site-rollback / site-states / #fleet across 721-1024 in both themes
//        and asserts BOTH that the page does not scroll AND that the route
//        asked for is the route that rendered — the second half is not
//        ceremony, see the routing trap below.
//    W15-fleet-row-text-bounded     THE CELLS, which every case above is blind
//        to because every case above asserts the PAGE. The W13 leg printed
//        "108 / 108 cells clean" on a tree where, at its own 900 control,
//        eight fleet cells clipped — .fleet-url scrollWidth 144 against
//        clientWidth 60 — and spilled the hostname through the badge chips
//        without moving documentElement.scrollWidth at all. This leg drives
//        mixed-fleet + fleet-v4 + fleet-support-failed at 721/769/899/900/
//        940/983/1000 in both themes and asks FOUR questions per cell: is the
//        text whole, is the money message whole, is the badge column still its
//        own width, and does the PAGE still fit. The second and third exist
//        because the two cheapest "fixes" for the first each score perfectly
//        on it while costing the person something else. The fourth, with 721/
//        769 and the support scenario, is the tripwire for the fix's own
//        scope: the same two declarations unscoped were driven at an 846px
//        page scrollWidth against a 721px viewport, because `flex-wrap: wrap`
//        on the stacked (column) .fleet-row wraps into COLUMNS.
//    W18-overview-card-pill         THE FRONT SCREEN, which every leg above is
//        blind to: W15 measures cells but only on `#fleet`, so it printed
//        "90 / 90 cells clean" on a tree where the LANDING route hid 66.1% of
//        why an instance is degraded (`.instance-card-head .status-pill-detail`
//        56 of 165px at 320 on overview-attention) and 81.0% on mixed-fleet.
//        Drives both front-screen scenarios at 320/360/390/430/620/769/800 in
//        both themes and asserts THREE invariants per cell — the detail is
//        whole, the pill is tall enough for its own text, and the detail's
//        bottom edge is inside the pill's. The last two are what stop the
//        naive detail-only remedy from scoring perfectly while painting the
//        sentence 24px below the capsule.
//    GR115-bpconsole-dead-rule      at 700x800 .bp-console-body must compute
//        the authored 40vh cap (320px) and the 13px legibility floor, same
//        for .bp-console-toggle (pre-fix: 260px/12px/12px — the later base
//        rules discarded the media block's declarations at equal
//        specificity). Includes the .bp-console.is-collapsed twin control.
//
// ─────────────────────────────────────────────────────────────────────────────
//  EVIDENCE HYGIENE, EACH PROVEN LIVE THIS EPIC (GR125)
// ─────────────────────────────────────────────────────────────────────────────
//  (a) SERVED BYTES == DISK BYTES, asserted before anything is measured. A
//      preview server from a FOREIGN worktree once squatted the port and
//      served the primary checkout's origin/main bytes, making a patched run
//      print baseline output. 20 worktrees share this checkout. On mismatch
//      this guard exits non-zero naming the stale server — it never measures
//      the wrong tree silently.
//  (b) Network.setCacheDisabled — Chrome memory-caches app.css across
//      same-URL navigations; without this a mutation phase measures the
//      ORIGINAL stylesheet and reports a false "did not flip".
//  (d) A ROUTE IS NOT A QUERY STRING (W13). `?scen=rollback` alone renders
//      #overview: scenarios.mjs's deepLink is consumed by the CALLER
//      (smoke.mjs:372, shoot.sh:118), never applied by mock.js. A sweep that
//      omits the hash prints a full, plausible table in which every "detail
//      route" is the overview screen. W13 appends the hash itself and asserts
//      the visible section.view id (plus the active .inst-tab, because the
//      three instance routes share one section) in EVERY cell.
//  (c) The GR115 fixture is injected by SELECTOR-built DOM, and mutations to
//      app.css (in the proofs) are selector-anchored — .new-console-body and
//      .bp-console-body are byte-identical declaration blocks, so a plain
//      string replace patches the wrong twin.
//
//  RUN
//    node cloud/priv/static/__preview__/overflow-guard.mjs                 # all four
//    node cloud/priv/static/__preview__/overflow-guard.mjs --defect GR108-tablet-topbar-overflow
//    OVERFLOW_GUARD_PORT=4321 node …                                      # port override
//    CHROME=/path/to/chrome node …
//    OVERFLOW_GUARD_CLASSIC_SCROLLBARS=1 node …                           # drop --hide-scrollbars
//
//  THE CLASSIC-SCROLLBAR SWITCH is a DIAGNOSTIC, not a mode to run the whole
//  file in: with real scrollbars clientWidth no longer equals the emulated
//  width, which is the parity GR108's sweep is written against. It exists so
//  W12's "the OS scrollbar is not the affordance" claim can be measured in the
//  condition it is about — a browser that reserves a classic track — instead of
//  asserted from a run that hid scrollbars in the first place. W12's cue must
//  read identically under both, and the run prints the reserved track width it
//  measured either way.
//
//  HONEST LIMIT — THIS FILE IS RUN BY NO WORKFLOW (charter D109). The sentence
//  that used to stand here — "`grep -rn overflow-guard .github/` returns
//  nothing, exit 1" — WAS STALE when W18 re-ran it: that grep now exits 0 with
//  one hit, console-harness.yml:272, which is a COMMENT citing this very claim
//  and not a step that runs anything. The limit is unchanged and the evidence
//  for it is not the grep any more: no `run:` line in .github/ invokes this
//  file. A header that quotes an exit code has to be re-driven when it is
//  quoted, or the guard's own documentation becomes the untested sentence this
//  guard exists to replace. It is a developer tripwire and the seal predicate's
//  shell-out, NOT a CI gate.
//  That is exactly how a tree whose body scrolled 106px at 390px passed every
//  required context: nothing measured below 700px, and nothing ran this file.
//
//  Exit codes: 0 = every requested defect measured fixed · 1 = a DEFECT WAS
//  MEASURED and is still present · 2 = REFUSED to measure (no/unusable Chrome,
//  unknown --defect, no server, a stale/squatted server, CDP bring-up failed,
//  the probe threw). 1 is a claim about the CSS; 2 is a claim about the
//  environment, and the two must never be confused under a required context.
//
//  ZERO DEPENDENCIES — Node 22 native fetch + native WebSocket speak CDP
//  directly (the Cdp class is cssom-parity.mjs's, unchanged). Teardown is
//  hand-bounded exactly like cssom-parity's: nothing here ever blocks on a
//  child process without a cap.
// ─────────────────────────────────────────────────────────────────────────────

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, ".."); // cloud/priv/static
const PORT = Number(process.env.OVERFLOW_GUARD_PORT || 4199);
const BASE = `http://127.0.0.1:${PORT}`;

const DEFECTS = [
  "GR108-tablet-topbar-overflow",
  "GR109-attention-row-dead-rule",
  "GR115-bpconsole-dead-rule",
  "W12-narrow-viewport-truth",
  "W13-detail-route-band",
  "W15-fleet-row-text-bounded",
  "W18-overview-card-pill",
  "W20-op-gate-pill-bounded",
];

// W18-S1: THE FRONT SCREEN, WHICH EVERY LEG ABOVE IS BLIND TO. `git grep -c
// instance-card-head -- cloud/priv/static/__preview__ .github` exited 1 with no
// output on origin/main: not one instrument in this epic had ever measured the
// landing route's instance card, while on merged-main bytes
// `.instance-card-head .status-pill-detail` rendered 56 of 165px of "Health
// down · Agent offline" at 320 — 66.1% of WHY the box is degraded, unreadable
// on the most-seen screen in the product. The W15 leg above is the only leg
// that measures a CELL rather than the page, and it drives `#fleet` scenarios
// only, so it printed "90 / 90 cells clean" on that same tree.
//
// TWO SCENARIOS, BECAUSE ONE OF THEM UNDERSTATES THE DEFECT. On `mixed-fleet`
// the same selector hides 81.0% at 320 (45/237, "Payment failed — subscription
// past due") and is STILL cut at 430, where `overview-attention` is already
// clean — a leg driving only the attention fixture would have called 430 a
// clean upper edge and shipped a band that reds on the other front-screen
// scenario.
//
// THREE INVARIANTS PER CELL, and the two vertical ones are the point:
//   (a) detail.scrollWidth <= detail.clientWidth — the defect itself.
//   (b) pill.scrollHeight <= pill.clientHeight  — the wrap's own trap.
//   (c) detail.bottom <= pill.bottom            — where the glyphs actually land.
// (b) and (c) exist because the naive remedy (`.instance-card-head
// .status-pill-detail { white-space: normal; overflow: visible; text-overflow:
// clip }` alone) scores a PERFECT horizontal card on this leg's whole axis —
// clientWidth == scrollWidth at 320/360/390 — while `pill.scrollHeight 47 >
// clientHeight 22` and the sentence paints 24.00px BELOW the capsule. Driven,
// not predicted: that negative control is this leg's mutation proof.
//
// HEIGHTS ARE REPORTED, NOT PINNED. The remedy takes the pill to 42px at 320
// and back to 24px from 620 up ON THIS FIXTURE, and both numbers are in the
// slice's evidence — but the wrap boundary is a property of the STRING, not of
// the CSS: the production-dominant "Health unknown · Agent offline" is three
// characters longer and moves the boundary from 425/430 to 450/460 and 360 to
// 42px. A leg that pinned 24 at 430 would pass on the fixture and red on what
// the server serves, so the pins live in the PR and the INVARIANTS live here.
const CARD_WIDTHS = [320, 360, 390, 430, 620, 769, 800];
const CARD_SCENS = ["overview-attention", "mixed-fleet"];

// W20-S6: THE ATTENTION QUEUE'S OWN PILL — the fourth host, and the one the
// leg below used to be structurally unable to see. GR109 asked its question
// with `querySelector` (SINGULAR): pointed at `mixed-fleet` it would have
// inspected row[0] only — 245/170, 30.6% hidden — and NEVER row[1], where
// "Payment failed — subscription past due" reads 237/139 at 320, 41.4% of the
// money message unrendered, in the SAME DOM at the SAME instant. A successor
// that iterates is not a nicety; the worst cell was the invisible one.
//
// THE ROUTE IS LOAD-BEARING (charter D228). `mixed-fleet`'s own deepLink is
// `#fleet`, where ZERO `.attention-row` render — which is where the filed
// "renders ZERO at any width" universal came from. The hash is PINNED to
// `#overview` below and the landed view id is asserted per cell, so a route
// artifact can never again be read as a fixture fact.
//
// THREE SCENARIOS. `mixed-fleet` carries the worst phone cell (41.4%),
// `overview-attention` the worst tablet cell (165/117 at 769, 29.1%) and
// `overview-past-due` the 769 cell (237/210) the tablet row was filed on. One
// fixture alone understates the band on either axis.
//
// THREE INVARIANTS PER CELL, and the two vertical ones are what make the
// horizontal one mean anything. DRIVEN, not predicted: two negative controls —
// `white-space: normal` alone, and a detail-only wrap — BOTH score a PERFECT
// horizontal 117/117 at 769 while `pill.scrollHeight 29 > clientHeight 22` and
// the detail's bottom edge paints 6px OUTSIDE the capsule. `height: auto` +
// `min-height: 24px` are the declarations that carry it, and a horizontal-only
// guard certifies both wrong fixes.
const ATT_WIDTHS = [320, 360, 375, 390, 430, 620, 769, 800];
const ATT_SCENS = ["mixed-fleet", "overview-attention", "overview-past-due"];

// W15-S4: THE LEG THAT EXISTS BECAUSE THIS FILE WAS BLIND TO ITS OWN SUBJECT.
// Every leg above asserts documentElement.scrollWidth — the PAGE. On the tree
// this leg was written against, the W13 leg printed "108 / 108 cells clean"
// while, at its OWN 900 control, eight fleet cells were clipping: fleet-v4
// row 1's `.fleet-url` measured scrollWidth 144 against clientWidth 60, 58% of
// the hostname unrendered, and because `.fleet-url` computes `overflow:
// visible` the remainder was PAINTED THROUGH the badge chips (box ended
// 482.75, text reached 566.80, badges began 498.75). None of that moves the
// page's scrollWidth by one pixel. A page-level assertion cannot see a cell
// that spills INSIDE the page, so leaning on it certifies the regression.
//
// THREE QUESTIONS PER CELL, each the shape of a thing a person loses:
//   (a) IS THE TEXT WHOLE — no `.fleet-name`/`.fleet-url`/`.fleet-meta`
//       scrollWidth beyond its clientWidth. This is the defect itself.
//   (b) IS THE MONEY MESSAGE WHOLE — no `.status-pill-detail` ellipsed. The
//       cheapest "fix" for (a) is `.fleet-status { max-width }`, which buys
//       the hostname by truncating "Suspended · Payment failed …". GR116
//       exists to stop exactly that, so (a) may never be bought with (b).
//   (c) IS THE BADGE COLUMN STILL ITSELF — `.fleet-badges` is never squeezed
//       narrower than its own content. The other cheap "fix",
//       `.fleet-badges { min-width: 0 }`, scores 0 on every TEXT metric while
//       collapsing the badge box to 29.83px around an unshrinkable 66.33px
//       chip: the mirror image of the shred, and invisible to a clip-only
//       scorer. Asserted as a RELATION (width >= scrollWidth), never as pinned
//       pixels — pinned px would red on any runner with different font metrics
//       and say nothing about the person.
//
// WIDTHS: 900 is the control the defect lived at; 940 and 983 are the two
// other widths that clipped pre-fix; 1000 is above them; 899 is the stacked
// band immediately below.
//
// 721 AND 769 ARE THE TRIPWIRE FOR THE FIX'S OWN SCOPE (review addition,
// cch-w15-s4-r). `flex-wrap: wrap` on the `flex-direction: column` `.fleet-row`
// the `@media (max-width: 899px)` block ships wraps into additional COLUMNS: the
// SAME two declarations UNSCOPED were driven at an 846px page scrollWidth on
// `fleet-support-failed#fleet` at 721 and 769 in both themes — 125px off-screen
// at 721. The slice PROVED that and then guarded it with a comment. A comment is
// not a check, so those two widths and that scenario are in the axis, and the
// per-cell measurement below also reads documentElement.scrollWidth: dropping
// the media query, or raising the 899 stack threshold above 900, now REDS here
// instead of shipping. Filed residue this narrows: cch-bl-w15-fleet-leg-scenario-axis-of-two.
//
// W16-S3 WIDENED THE AXIS DOWN TO THE PHONE, because the leg was STRUCTURALLY
// BLIND TO ITS OWN WORST CELL. The set above started at 721: no phone width at
// all, so the band where `fleet-support-failed`'s money message lost 69% of
// itself (320: `.status-pill-detail` scrollWidth 463 vs clientWidth 142) could
// not be measured, and mixed-fleet + fleet-v4 were ALSO truncating at 320/360/
// 390 with nothing to say so. 800/830/860 close the other hole — the 769..899
// interior was unvisited, and the filed row's own title ("721 and 769")
// understated a band that runs 320-860. Paying a row while leaving the guard
// blind to that row's worst width is this wave's disease; this is the cure.
const FLEET_WIDTHS = [320, 360, 390, 430, 620, 721, 769, 800, 830, 860, 899, 900, 940, 983, 1000];
const FLEET_SCENS = ["mixed-fleet", "fleet-v4", "fleet-support-failed"];
const FLEET_TEXT_SELS = [".fleet-name", ".fleet-url", ".fleet-meta"];

// ITEMISED, ROW-BEARING, AND UNABLE TO ROT (review addition). Widening the axis
// above turned up ONE pre-existing hit this slice's `@media (min-width: 900px)`
// fix cannot reach, in the STACKED band below 899. It is not swept under a
// blanket skip and it is not allowed to hide a new defect: an entry matches one
// scenario + one selector + an explicit width list, every other cell is still
// judged, and an entry that matches NOTHING is itself a FAILURE — so the day the
// row is paid, this guard tells you to delete the entry instead of quietly
// carrying it forever. Measured identically on origin/main and on this branch,
// so the slice introduced none of it.
//
// EMPTY AS OF W16-S3, AND THAT IS THE ALLOWLIST WORKING. The single entry —
// `cch-w15-bl-fleet-support-detail-truncated-stacked-band` @ 721/769 — was
// DELETED IN THE SAME DIFF as its remedy (`.fleet-status .status-pill`'s wrap,
// app.css). With the remedy on disk and the entry still present this guard
// exited 1 with exactly one finding, the stale-allowlist tripwire below saying
// "matched NOTHING" — which is the entry telling its author to delete it. Do
// not re-add a row here to make a red go away: an entry buys silence at exactly
// one scenario/selector/width triple and must be deleted the day it is paid.
const FLEET_KNOWN = [];
const knownHit = (scen, sel, width) =>
  FLEET_KNOWN.find((k) => k.scen === scen && k.sel === sel && k.widths.includes(width));

// W13-S4: the tablet band NOTHING in this file had ever driven a DETAIL ROUTE
// at. 769 and 899 are the two edges of the band; 900 and 1024 are the controls
// above it; 721/768 are below it and prove the fix did not disturb the phone
// and small-tablet shapes GR65/GR116 own.
const BAND_WIDTHS = [721, 768, 769, 790, 830, 860, 899, 900, 1024];

// The six routes. `view` is the section.view that MUST be visible: `?scen=` on
// its own does NOT route (deepLink is applied by the CALLER — smoke.mjs:372,
// shoot.sh:118 — never by mock.js), so a sweep without the hash renders
// #overview six times and prints a plausible, entirely phantom table. The hash
// is appended here AND the landed view is asserted per cell. `tab` additionally
// pins WHICH instance sub-tab landed, because all three instance routes share
// the single #view-instance section.
const INST = "5b2c1e00-0000-4000-8000-0000000000a1";
const SITE = "5b2c1e00-0000-4000-8000-0000000000c1";
const BAND_ROUTES = [
  { name: "instance-detail", scen: "panel-overview", hash: `#instance/${INST}`, view: "view-instance", tab: "Overview", ready: ".detail-grid--instance" },
  { name: "inst-timeline", scen: "timeline", hash: `#instance/${INST}/timeline`, view: "view-instance", tab: "Timeline", ready: "#instance-tabpanel" },
  { name: "inst-metrics", scen: "metrics", hash: `#instance/${INST}/metrics`, view: "view-instance", tab: "Metrics", ready: "#instance-tabpanel" },
  { name: "site-rollback", scen: "rollback", hash: `#site/${SITE}`, view: "view-site", tab: null, ready: ".detail-grid" },
  { name: "site-states", scen: "site-states", hash: `#site/${SITE}`, view: "view-site", tab: null, ready: ".detail-grid" },
  { name: "fleet", scen: "mixed-fleet", hash: "#fleet", view: "view-fleet", tab: null, ready: ".fleet-row" },
];

// W14-S3 RETIRED THE ONE PIN THIS LEG USED TO CARRY. #fleet's 21px overhang at
// 769 was the residual W13 named rather than skipped (FLEET_ROW_RESIDUAL, max
// 21px, cch-w13-fleet-row-band-769-785); its remedy — `.fleet-row`'s stack —
// moved from the 768 block into the 899 block, the band [769,789] measured 0
// offending cells on mixed-fleet AND fleet-v4 in both themes, and the pin,
// its skip branch and its summary sentence went with it. #fleet is now
// asserted like every other route: no exemption, 108/108.

// The sweep envelope. 769/775/780/785 are ABOVE the breakpoint on purpose —
// see the header: a sweep capped at 768 cannot fail on this defect class.
const WIDTHS = [721, 750, 768, 769, 775, 780, 785, 800, 900, 1024, 1440];
// W12: the band NOTHING in this file used to look at. 495/496 straddle the
// measured threshold (overflowed at <=495, clean at >=496 pre-fix), so a run
// that goes green here has crossed the bisection point rather than missed it.
const PHONE_WIDTHS = [320, 360, 375, 390, 412, 430, 480, 495, 496, 620];

// W17-S6: THE CHIP'S OWN WIDTH SET, BECAUSE THIS FILE USED TO ASK ITS QUESTION
// AT ONE WIDTH. The money-message read below sat behind `await setViewport(768)`
// — the ONLY tablet width where the chip is whole — while the page-overflow loop
// above it walked 769/775/780/785 and then printed a green line naming those
// widths. A reader of that line reasonably concluded the band above the
// breakpoint had been checked; it had been, for the wrong question. Driven on
// pre-fix bytes the chip was cut across TWO disjoint bands: 721-735 (168/160
// down to 168/166 light, one px worse dark) and 769-800 light / 769-805 dark
// (168/153 at 769 — 15px of "Payment failed · fix billing" gone). Both are
// inside this set now, plus 810/820/830 which are CLEAN on pre-fix bytes and so
// pin the upper edge as measured rather than as filed (cch-w14-bl said 769-820;
// 820 and 830 both read 168/168).
const CHIP_WIDTHS = [721, 725, 730, 735, 740, 741, 750, 768, 769, 775, 780, 785, 800, 805, 810, 820, 830];
// THE NAMED RESIDUAL IS GONE (W20-S8). 721-740 used to be exempted here by a
// declared, capped and attributed 9px tolerance (a three-constant band pinned to
// `cch-w17-bl-band-a-shell-fold-cliff`) on the FLEET_ROW_RESIDUAL precedent. It
// was still a green tick over a cut money message, and it was wrong by MORE than
// it admitted: 740 was never in the exempt set at all, so 740/dark's real
// 168/167 was scored WHOLE, and the summary sentence read "13 of 17" in rows
// where 12 was the truth. The band is now paid in CSS (app.css, the 621-740
// block) and every one of these widths is asserted STRICTLY — no band, no cap,
// no exemption. The shortfall it used to tolerate reds like any other cut.
const HEIGHT = 800;
const CLASSIC_SCROLLBARS = process.env.OVERFLOW_GUARD_CLASSIC_SCROLLBARS === "1";

const SERVER_CAP = 8000;
const DEVTOOLS_CAP = 15000;
const RENDER_CAP = 12000;
const EVAL_CAP = 10000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── args ─────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
let only = null;
const di = argv.indexOf("--defect");
if (di !== -1) {
  only = argv[di + 1];
  if (!DEFECTS.includes(only)) {
    process.stderr.write(
      `!! GUARD (exit 2): unknown --defect "${only}". Known: ${DEFECTS.join(", ")}\n`,
    );
    process.exit(2);
  }
}
const requested = only ? [only] : DEFECTS;

// ── chrome discovery (cssom-parity.mjs's, unchanged) ─────────────────────────
// The accessSync check MUST cover the CHROME env branch, not only the candidate
// sweep. .github/workflows/console-harness.yml pins CHROME=/usr/bin/google-chrome
// for every console run, so on CI the env branch is the ONLY branch taken — an
// unchecked `return process.env.CHROME` makes the exit-2 "no Chrome" GUARD below
// dead code, and a runner image that drops the binary dies instead with a raw
// `spawn … ENOENT` node stack at exit 1. Exit 1 means "a measured overflow";
// a missing browser is an ENVIRONMENTAL REFUSAL and must speak as exit 2.
function findChrome() {
  if (process.env.CHROME) {
    try {
      fs.accessSync(process.env.CHROME, fs.constants.X_OK);
      return process.env.CHROME;
    } catch {
      return null; // fall through to the exit-2 GUARD naming the missing path
    }
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

// The refusal line for a findChrome() miss — names the path that was pinned and
// not found, so a runner-image regression reads as "this binary is gone", never
// as an anonymous red.
function chromeGuardLine() {
  return process.env.CHROME
    ? `!! GUARD (exit 2): CHROME=${process.env.CHROME} is not an executable file. Environment refusal, not an overflow defect.\n`
    : "!! GUARD (exit 2): no Chrome/Chromium found. Set CHROME=/path/to/chrome.\n";
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

// ── the run ──────────────────────────────────────────────────────────────────
async function main() {
  const chromeBin = findChrome();
  if (!chromeBin) {
    process.stderr.write(chromeGuardLine());
    process.exit(2);
  }

  // 1. Serve the tree. If the port is already held, our child dies with
  //    EADDRINUSE — that is fine IF AND ONLY IF whoever holds it serves this
  //    tree's exact bytes; the assertion below decides, never the spawn.
  const serveChild = spawn("node", [path.join(HERE, "serve.mjs"), "--port", String(PORT)], {
    stdio: "ignore",
  });

  let chrome = null;
  let cdp = null;
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

  let profile = null;
  const teardown = async () => {
    if (cdp) {
      await Promise.race([cdp.send("Browser.close").catch(() => {}), sleep(BROWSER_CLOSE_CAP)]);
      cdp.close();
    }
    await reap(chrome);
    await reap(serveChild);
    if (profile) { try { fs.rmSync(profile, { recursive: true, force: true }); } catch { /* best effort */ } }
  };

  // Default 2 = REFUSED TO MEASURE (environment fault), not 1 = a measured
  // overflow defect. Every current call site is environmental — server never
  // came up, a foreign tree squats the port, Chrome never started, CDP failed,
  // the evaluate threw — so all six take this default deliberately. A future
  // site that IS a measured defect must pass 1 explicitly and say why.
  const die = async (msg, code = 2) => {
    await teardown();
    process.stderr.write(`\n!! OVERFLOW GUARD: ${msg}\n`);
    process.exit(code);
  };

  // Wait for SOMETHING to answer on the port (ours or a squatter's).
  let up = false;
  for (let w = 0; w < SERVER_CAP; w += 100) {
    try { const r = await fetch(`${BASE}/app.css`, { cache: "no-store" }); if (r.ok) { up = true; break; } } catch { /* not yet */ }
    await sleep(100);
  }
  // AUDITED (exit 2): the local static server never came up. Environment, not CSS.
  if (!up) return die(`no server answered on :${PORT} within ${SERVER_CAP}ms`);

  // 2. SERVED BYTES == DISK BYTES (GR125a). Compared for every file the
  //    measurement depends on, plus the injected shell "/" against the same
  //    injection serve.mjs performs — so a squatter serving a different
  //    index.html is caught too, not only a different stylesheet.
  const fetchBytes = async (p) => Buffer.from(await (await fetch(`${BASE}${p}`, { cache: "no-store" })).arrayBuffer());
  for (const rel of ["/app.css", "/app.js", "/__preview__/mock.js", "/__preview__/scenarios.mjs"]) {
    const served = await fetchBytes(rel);
    const disk = fs.readFileSync(path.join(ROOT, rel.slice(1)));
    if (!served.equals(disk)) {
      // AUDITED (exit 2): a foreign tree squats the port — we refuse to measure
      // bytes we did not author. Nothing about this tree's CSS has been judged.
      return die(
        `STALE SERVER on :${PORT} — ${rel} served ${served.length} B, disk holds ${disk.length} B.\n` +
        `   A server rooted at a DIFFERENT tree (a foreign worktree?) is squatting this port.\n` +
        `   Measuring against it would certify the wrong bytes — refusing.`,
      );
    }
  }
  {
    const shell = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
    const APP_TAG = '<script src="/app.js"></script>';
    const expected = shell.includes(APP_TAG)
      ? shell.replace(APP_TAG, '<script src="/__preview__/mock.js"></script>\n    ' + APP_TAG)
      : shell;
    const served = (await fetchBytes("/")).toString("utf8");
    if (served !== expected) {
      // AUDITED (exit 2): same squatter refusal, on the injected shell.
      return die(`STALE SERVER on :${PORT} — the injected shell "/" does not match this tree's index.html.`);
    }
  }
  process.stdout.write(`>> serve      :${PORT} — served bytes == disk bytes (app.css, app.js, mock.js, scenarios.mjs, shell)\n`);

  // 3. Chrome.
  profile = fs.mkdtempSync(path.join(os.tmpdir(), "overflow-guard-"));
  chrome = spawn(
    chromeBin,
    [
      "--headless=new",
      "--disable-gpu",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--disable-background-networking",
      // classic-macOS overlay parity: clientWidth == emulated width. Dropped
      // only under OVERFLOW_GUARD_CLASSIC_SCROLLBARS=1 (see the header).
      ...(CLASSIC_SCROLLBARS ? [] : ["--hide-scrollbars"]),
      `--user-data-dir=${profile}`,
      "--remote-debugging-port=0",
      "about:blank",
    ],
    { stdio: "ignore" },
  );

  const portFile = path.join(profile, "DevToolsActivePort");
  let devPort = null;
  for (let w = 0; w < DEVTOOLS_CAP; w += 100) {
    try {
      const raw = fs.readFileSync(portFile, "utf8").split("\n");
      if (raw[0] && Number(raw[0])) { devPort = Number(raw[0]); break; }
    } catch { /* not written yet */ }
    await sleep(100);
  }
  // AUDITED (exit 2): the browser never started. Environment, not CSS.
  if (!devPort) return die("Chrome never wrote DevToolsActivePort — it did not start");

  let sessionId;
  try {
    const version = await (await fetch(`http://127.0.0.1:${devPort}/json/version`)).json();
    process.stdout.write(`>> chrome     ${version.Browser} · node ${process.version}\n`);
    cdp = await Cdp.connect(version.webSocketDebuggerUrl);
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    ({ sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true }));
    await cdp.send("Runtime.enable", {}, sessionId);
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Network.enable", {}, sessionId);
    // GR125(b): Chrome memory-caches app.css across same-URL navigations —
    // without this, a mutated stylesheet measures as the original.
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true }, sessionId);
  } catch (err) {
    // AUDITED (exit 2): the debugger transport failed before any measurement ran.
    return die(`CDP bring-up failed: ${err.message}`);
  }

  const evalJs = async (expression) => {
    const r = await cdp.send("Runtime.evaluate", { expression, returnByValue: true }, sessionId);
    if (r.exceptionDetails) throw new Error("page eval threw: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
    return r.result.value;
  };

  const setViewport = (width, height = HEIGHT) =>
    cdp.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false }, sessionId);

  // Navigate and poll until `readyExpr` is truthy (the SPA mounts async).
  const nav = async (url, readyExpr) => {
    await cdp.send("Page.navigate", { url }, sessionId);
    for (let w = 0; w < RENDER_CAP; w += 100) {
      try { if (await evalJs(`!!(${readyExpr})`)) return; } catch { /* navigating */ }
      await sleep(100);
    }
    throw new Error(`page never became ready: ${url} (waited on: ${readyExpr})`);
  };

  const failures = [];
  const fail = (defect, msg) => { failures.push({ defect, msg }); process.stdout.write(`   ✗ ${msg}\n`); };
  const okLine = (msg) => process.stdout.write(`   ✓ ${msg}\n`);

  try {
    // ── GR108: page-level overflow sweep + the chip's money message ─────────
    if (requested.includes("GR108-tablet-topbar-overflow")) {
      process.stdout.write(`\nGR108-tablet-topbar-overflow — ${WIDTHS.length} widths x 2 themes x 2 scenarios\n`);
      let checks = 0, offenders = 0;
      for (const scen of ["billing-past-due", "overview-past-due"]) {
        for (const theme of ["light", "dark"]) {
          await setViewport(768);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}`,
            `document.querySelector('.topbar') && (function(){var c=document.getElementById('billing-chip');return c && !c.hidden;})()`,
          );
          const row = [];
          for (const width of WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;` +
              `return {sw:d.scrollWidth, cw:d.clientWidth, theme:d.getAttribute('data-theme')};})()`,
            );
            checks++;
            const over = m.sw > m.cw;
            if (over) { offenders++; fail("GR108-tablet-topbar-overflow", `${scen}/${theme}@${width}: scrollWidth ${m.sw} > viewport ${m.cw} — horizontal scrollbar`); }
            row.push(`${width}:${m.sw}${over ? "!" : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join(" ")}\n`);

          // Cosmetic half, across the WHOLE tablet band and not just at the
          // breakpoint (W17-S6 — see CHIP_WIDTHS): the past-due money message
          // must be whole. Correctness-only clips it to ~154.61 of ~169.78px at
          // 768; the 768-block tighten alone leaves it cut from 769 to 805.
          const chipRow = [];
          let chipCut = 0;
          for (const width of CHIP_WIDTHS) {
            await setViewport(width);
            const chip = await evalJs(
              `(function(){var c=document.getElementById('billing-chip');if(!c)return null;` +
              `var r=c.getBoundingClientRect();` +
              `return {sw:c.scrollWidth, cw:c.clientWidth, w:Math.round(r.width*100)/100, text:c.textContent};})()`,
            );
            if (!chip) { fail("GR108-tablet-topbar-overflow", `${scen}/${theme}@${width}: #billing-chip missing`); chipRow.push(`${width}:missing`); continue; }
            // 721-740 IS ASSERTED STRICTLY (W20-S8). The `+ 1` below is the
            // undeclared epsilon owned by
            // `cchi-w18-bl-overflow-guard-chip-epsilon-undeclared`; it is out of
            // scope here and this band deliberately does NOT lean on it — it is
            // what let 740/dark's 168/167 read as whole. With the 621-740 CSS
            // block every one of these cells lands at 168/168 (full intrinsic
            // width), so a pixel of tolerance could only hide a regression.
            const cut = width <= 740 ? chip.sw > chip.cw : chip.sw > chip.cw + 1;
            if (cut) { chipCut++; fail("GR108-tablet-topbar-overflow", `${scen}/${theme}@${width}: billing chip TRUNCATED — scrollWidth ${chip.sw} > clientWidth ${chip.cw} (rect ${chip.w}px, "${chip.text}")`); }
            chipRow.push(`${width}:${chip.sw}/${chip.cw}${cut ? "!" : ""}`);
          }
          process.stdout.write(`   chip ${scen}/${theme}  ${chipRow.join(" ")}\n`);
          // A summary line only when there is something to summarise. A green
          // sentence printed beside its own ✗ lines is how this leg misled a
          // reader for four waves — it does not get to do that again.
          if (chipCut) {
            process.stdout.write(`   ${scen}/${theme}: ${chipCut} of ${CHIP_WIDTHS.length} tablet widths CUT — see the ✗ lines above\n`);
          } else {
            okLine(`${scen}/${theme}: chip whole at all ${CHIP_WIDTHS.length} tablet widths ${CHIP_WIDTHS[0]}-${CHIP_WIDTHS[CHIP_WIDTHS.length - 1]}`);
          }
        }
      }
      if (!failures.some((f) => f.defect === "GR108-tablet-topbar-overflow")) {
        // Says WHICH question it answered. Before W17-S6 this line read as if
        // the band above the breakpoint had been cleared for the chip too; the
        // chip was only ever read at 768. The chip now answers for itself above.
        okLine(`0/${checks} PAGE-overflow cells across ${WIDTHS[0]}-${WIDTHS[WIDTHS.length - 1]} (sweep includes 769/775/780/785 — ABOVE the breakpoint). The chip's own question is answered per-width above, not by this line.`);
      }
    }

    // ── GR109: the stacked attention row is left-aligned, not centred ───────
    if (requested.includes("GR109-attention-row-dead-rule")) {
      process.stdout.write(`\nGR109-attention-row-dead-rule — overview-past-due attention queue\n`);
      await setViewport(768);
      await nav(`${BASE}/?scen=overview-past-due&theme=light`, `document.querySelector('.attention-row .attention-acts')`);
      const m = await evalJs(
        `(function(){var row=document.querySelector('.attention-row');var cs=getComputedStyle(row);` +
        `var main=row.querySelector('.attention-main').getBoundingClientRect();` +
        `var acts=row.querySelector('.attention-acts').getBoundingClientRect();` +
        `return {dir:cs.flexDirection, align:cs.alignItems,` +
        ` mainLeft:Math.round(main.left*100)/100, actsLeft:Math.round(acts.left*100)/100};})()`,
      );
      if (m.dir !== "column") fail("GR109-attention-row-dead-rule", `@768 flex-direction is "${m.dir}", expected "column" — the stack itself died`);
      if (m.align !== "flex-start") fail("GR109-attention-row-dead-rule", `@768 align-items is "${m.align}", expected "flex-start" — the authored rule is cascade-dead (row stacks but stays centred)`);
      if (Math.abs(m.actsLeft - m.mainLeft) > 1) fail("GR109-attention-row-dead-rule", `@768 .attention-acts left ${m.actsLeft} != .attention-main left ${m.mainLeft} — buttons are centred, not left-aligned`);
      if (!failures.some((f) => f.defect === "GR109-attention-row-dead-rule")) {
        okLine(`@768 computed column/flex-start; acts left ${m.actsLeft} == main left ${m.mainLeft}`);
      }
      // The stack must stay scoped to the tablet block — at 900 it is a row.
      await setViewport(900);
      const wide = await evalJs(`getComputedStyle(document.querySelector('.attention-row')).flexDirection`);
      if (wide !== "row") fail("GR109-attention-row-dead-rule", `@900 flex-direction is "${wide}", expected "row" — the tablet stack leaked above its breakpoint`);
      else okLine(`@900 still a row — the stack is scoped to <=768`);

      // ── W20-S6: the row's own status pill, on EVERY row, not the first ──
      // See the note by ATT_WIDTHS. The stack assertions above answer where the
      // BUTTONS land; they say nothing about whether the row still tells the
      // operator WHY the box needs attention. This half does, on both axes.
      const D109 = "GR109-attention-row-dead-rule";
      const attCellCount = ATT_SCENS.length * ATT_WIDTHS.length * 2;
      process.stdout.write(
        `   attention-row pill — ${ATT_SCENS.length} scenarios x ${ATT_WIDTHS.length} widths x 2 themes` +
        ` (${attCellCount} cells; EVERY .attention-row iterated — .status-pill-detail width, .status-pill height, detail bottom edge)\n`,
      );
      let attCells = 0, attPills = 0, attClipped = 0, attTall = 0, attOutside = 0, attPageOver = 0;
      for (const scen of ATT_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter wide and assert the LANDED view — `?scen=` alone does not
          // route, and `mixed-fleet` deep-links `#fleet`, where this queue does
          // not exist at all. The hash is pinned; the view id is checked.
          await setViewport(1000);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#overview`,
            `document.querySelector('.attention-row .status-pill-detail') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-overview';})()`,
          );
          const row = [];
          for (const width of ATT_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var d=document.documentElement;` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,rows:0,pills:0,clips:[],tall:[],out:[],w:[]};` +
              `[].slice.call(document.querySelectorAll('.attention-row')).forEach(function(r,i){` +
              `  out.rows++;` +
              `  var pill=r.querySelector('.status-pill'); if(!pill) return; out.pills++;` +
              `  var pr=pill.getBoundingClientRect();` +
              `  if(pill.scrollHeight>pill.clientHeight) out.tall.push({i:i,sh:pill.scrollHeight,ch:pill.clientHeight,t:(pill.textContent||'').slice(0,44)});` +
              `  var det=r.querySelector('.status-pill-detail'); if(!det) return;` +
              `  out.w.push(det.clientWidth+'/'+det.scrollWidth);` +
              `  if(det.scrollWidth>det.clientWidth) out.clips.push({i:i,sw:det.scrollWidth,cw:det.clientWidth,t:(det.textContent||'').slice(0,48)});` +
              `  var dr=det.getBoundingClientRect();` +
              `  if(dr.bottom>pr.bottom+0.5) out.out.push({i:i,db:+dr.bottom.toFixed(2),pb:+pr.bottom.toFixed(2),t:(det.textContent||'').slice(0,48)});` +
              `});` +
              `return out;})()`,
            );
            attCells++;
            if (m.view !== "view-overview") {
              fail(D109, `${scen}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-overview" — the hash did not route, so nothing below this line measures the attention queue`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D109, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: an empty queue is not a clean queue. Measuring zero
            // elements is the failure this leg's `querySelector` past would
            // have reported as a pass — see the note by ATT_WIDTHS.
            if (m.pills === 0) {
              fail(D109, `${scen}/${theme}@${width}: zero .attention-row .status-pill measured (${m.rows} .attention-row present) — nothing was measured, this is not a pass`);
              row.push(`${width}:0p`);
              continue;
            }
            attPills += m.pills;
            if (m.psw > m.pcw) {
              attPageOver++;
              fail(D109, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the front screen is off-screen sideways`);
            }
            for (const c of m.clips) {
              attClipped++;
              fail(D109, `${scen}/${theme}@${width} row${c.i} .attention-row .status-pill-detail: scrollWidth ${c.sw} > clientWidth ${c.cw} — ${Math.round((1 - c.cw / c.sw) * 100)}% of "${c.t}" is not rendered, so the attention queue does not say WHY this instance needs attention`);
            }
            for (const t of m.tall) {
              attTall++;
              fail(D109, `${scen}/${theme}@${width} row${t.i} .attention-row .status-pill: ${t.sh}px of text in a ${t.ch}px chip — "${t.t}" paints BELOW the capsule. A wrap without \`height: auto\` scores clean on every scrollWidth metric and still puts the words outside the box.`);
            }
            for (const o of m.out) {
              attOutside++;
              fail(D109, `${scen}/${theme}@${width} row${o.i} .attention-row .status-pill-detail: bottom ${o.db} is ${(o.db - o.pb).toFixed(2)}px BELOW the pill's bottom ${o.pb} — "${o.t}" is painted outside its own chip`);
            }
            const bad = m.clips.length + m.tall.length + m.out.length + (m.psw > m.pcw ? 1 : 0);
            row.push(`${width}:${m.pills}p ${m.w.join(",")}${bad ? " !" + bad : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      // AUDITED at the leg level too: a sweep that measured nothing across the
      // whole matrix must exit 1, never print a green summary of zero work.
      if (attPills === 0) {
        fail(D109, `the attention-row sweep measured ZERO pills across all ${attCells} cells — the queue stopped rendering or the selector went stale; a vacuous green is refused`);
      } else if (!failures.some((f) => f.defect === D109)) {
        okLine(
          `${attCells} / ${attCells} attention-row cells clean (${attPills} pills measured on BOTH axes, every row iterated) across ` +
          `${ATT_WIDTHS.join("/")} on ${ATT_SCENS.join(" + ")}, both themes, route pinned #overview; ` +
          `${attClipped} truncated reasons, ${attTall} chips shorter than their own text, ` +
          `${attOutside} details painting below their pill, ${attPageOver} pages scrolling sideways. ` +
          `Per-cell clientWidth/scrollWidth pairs are printed above; no pixel literal is pinned here — ` +
          `the wrap boundary is a property of the fixture STRING`,
        );
      }
    }

    // ── GR115: the 720-block console declarations actually take effect ──────
    if (requested.includes("GR115-bpconsole-dead-rule")) {
      process.stdout.write(`\nGR115-bpconsole-dead-rule — computed console styles at 700x800\n`);
      await setViewport(700, 800);
      await nav(`${BASE}/?scen=empty&theme=light`, `document.querySelector('.topbar')`);
      // The .bp-console mounts on instance-detail timelines; the cascade is a
      // stylesheet property, so a minimal fixture rendered against the REAL
      // served stylesheet measures the same computed values the timeline gets.
      // Both console families are byte-identical declaration blocks (GR125c) —
      // the fixture carries BOTH so the twin proves the reorder fixed the dead
      // one without touching the live one.
      const m = await evalJs(
        `(function(){var host=document.createElement('div');host.id='gr115-fixture';` +
        `host.innerHTML='<div class="bp-console"><button class="bp-console-toggle">` +
        `<span class="bp-console-caret"></span>Console</button>` +
        `<div class="bp-console-body"><div class="bp-console-line">` +
        `<span class="bp-console-text">line</span></div></div></div>` +
        `<div class="new-console"><button class="new-console-toggle">Console</button>` +
        `<div class="new-console-body">line</div></div>';` +
        `document.body.appendChild(host);` +
        `var bp=host.querySelector('.bp-console'),tog=host.querySelector('.bp-console-toggle'),` +
        `body=host.querySelector('.bp-console-body'),caret=host.querySelector('.bp-console-caret'),` +
        `nb=host.querySelector('.new-console-body');` +
        `var out={bpMax:getComputedStyle(body).maxHeight,bpFs:getComputedStyle(body).fontSize,` +
        `togFs:getComputedStyle(tog).fontSize,newMax:getComputedStyle(nb).maxHeight,` +
        `newFs:getComputedStyle(nb).fontSize};` +
        // Twin control (.bp-console.is-collapsed, GR115): transition:none on the
        // caret first, or the synchronous read returns the transition's START
        // value and manufactures a false red.
        `caret.style.transition='none';tog.style.transition='none';` +
        `bp.classList.add('is-collapsed');` +
        `out.togBorderStyle=getComputedStyle(tog).borderBottomStyle;` +
        `out.togBorderWidth=getComputedStyle(tog).borderBottomWidth;` +
        `out.caretTransform=getComputedStyle(caret).transform;` +
        `host.remove();return out;})()`,
      );
      // 40vh of the 800px emulated viewport = 320px; pre-fix computes 260px.
      if (m.bpMax !== "320px") fail("GR115-bpconsole-dead-rule", `.bp-console-body max-height computes ${m.bpMax}, expected 320px (40vh @ 800) — the 720-block cap is cascade-dead`);
      if (m.bpFs !== "13px") fail("GR115-bpconsole-dead-rule", `.bp-console-body font-size computes ${m.bpFs}, expected 13px — the legibility floor ("no theater text falls below 13px") is false`);
      if (m.togFs !== "13px") fail("GR115-bpconsole-dead-rule", `.bp-console-toggle font-size computes ${m.togFs}, expected 13px`);
      if (m.newMax !== "320px" || m.newFs !== "13px") fail("GR115-bpconsole-dead-rule", `.new-console twin regressed: max-height ${m.newMax} font-size ${m.newFs}, expected 320px/13px`);
      // The twin control re-run after the reorder: is-collapsed still wins.
      // REVIEW FIX: this was `&&`, which only fires when BOTH readings are
      // wrong — a toggle computing `solid` at a 0px width would have passed a
      // control whose whole job is to fail. `||` is strictly stronger and still
      // green on the fix (style `none` forces the computed width to `0px`, so
      // both operands are false together).
      if (m.togBorderStyle !== "none" || m.togBorderWidth !== "0px") fail("GR115-bpconsole-dead-rule", `.bp-console.is-collapsed .bp-console-toggle border-bottom is ${m.togBorderStyle}/${m.togBorderWidth}, expected none/0px`);
      const mat = /matrix\(([-\d.e]+),\s*([-\d.e]+),/.exec(m.caretTransform || "");
      if (!mat || Math.abs(Number(mat[1])) > 1e-3 || Math.abs(Number(mat[2]) + 1) > 1e-3) {
        fail("GR115-bpconsole-dead-rule", `.bp-console.is-collapsed caret transform is "${m.caretTransform}", expected rotate(-90deg)`);
      }
      if (!failures.some((f) => f.defect === "GR115-bpconsole-dead-rule")) {
        okLine(`bp-console body ${m.bpMax}/${m.bpFs}, toggle ${m.togFs}; twin ${m.newMax}/${m.newFs}; is-collapsed border ${m.togBorderStyle}, caret ${m.caretTransform}`);
      }
    }
    // ── W12: phone widths — the body must not scroll, and the matrix must
    //    say it continues ───────────────────────────────────────────────────
    if (requested.includes("W12-narrow-viewport-truth")) {
      const D = "W12-narrow-viewport-truth";
      process.stdout.write(
        `\n${D} — ${PHONE_WIDTHS.length} phone widths x 2 themes` +
        ` (scrollbars: ${CLASSIC_SCROLLBARS ? "CLASSIC — reserved track measured" : "hidden"})\n`,
      );

      // (a) the page body itself. The fleet grid is the offender: a bare `1fr`
      //     track cannot go below the CARD's min-content, so the track — not
      //     the card's children — is what overhangs a 358px container.
      for (const theme of ["light", "dark"]) {
        await setViewport(390);
        await nav(
          `${BASE}/?scen=mixed-fleet&theme=${theme}#overview`,
          `document.querySelector('.instances-grid .instance-card')`,
        );
        const row = [];
        for (const width of PHONE_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){var d=document.documentElement;` +
            `var g=document.querySelector('.instances-grid');var c=g&&g.querySelector('.instance-card');` +
            `var r=Math.round((c?c.getBoundingClientRect().width:0)*1000)/1000;` +
            `var gw=Math.round((g?g.getBoundingClientRect().width:0)*1000)/1000;` +
            `return {sw:d.scrollWidth,cw:d.clientWidth,card:r,grid:gw,` +
            ` tracks:g?getComputedStyle(g).gridTemplateColumns:''};})()`,
          );
          const over = m.sw > m.cw;
          if (over) fail(D, `mixed-fleet/${theme}@${width}#overview: body scrollWidth ${m.sw} > clientWidth ${m.cw} (${m.sw - m.cw}px overhang) — track ${m.tracks} on a ${m.grid}px container`);
          else if (m.card > m.grid + 1) fail(D, `mixed-fleet/${theme}@${width}#overview: .instance-card ${m.card}px overhangs its ${m.grid}px grid — the track is still floored at the card's min-content`);
          row.push(`${width}:${m.sw}${over ? "!" : ""}`);
        }
        process.stdout.write(`   mixed-fleet/${theme}  ${row.join(" ")}\n`);
      }

      // (b) the notifications matrix must ADMIT it is clipped. Two independent
      //     cues, both measured: a label column that stays put while the
      //     channels scroll under it, and an edge fade that exists ONLY while
      //     content is hidden. The fade is scroll-driven, so every read is
      //     taken a frame after the scroll that provoked it — a same-tick read
      //     returns the previous frame's value and manufactures a false red.
      // A scroll-driven animation's computed value is produced by the ANIMATION
      // FRAME that follows the scroll, not by the assignment — a same-tick (or
      // even a fixed-sleep) read is a coin flip, and this measurement caught
      // itself flipping: light@768 read 48px and dark@768 read 0px off the same
      // stylesheet. Every read below is taken after two real rAFs have run.
      // TWO FORCED FRAMES. requestAnimationFrame is NOT a frame source here: a
      // headless target that has gone idle simply never calls back (measured —
      // the light pass settled on rAF every time, the dark pass sat through
      // 8000ms and eight re-arms without a single callback, off the same
      // stylesheet). Page.captureScreenshot blocks on a real BeginFrame, so it
      // produces one on demand; the value is read on the frame AFTER the scroll,
      // hence two.
      const settle = async () => {
        for (let i = 0; i < 2; i++) {
          await Promise.race([
            cdp.send("Page.captureScreenshot", { format: "jpeg", quality: 1 }, sessionId).catch(() => {}),
            sleep(EVAL_CAP),
          ]);
        }
      };

      const readMatrix = async () => {
        // Bring the matrix into the viewport FIRST. elementFromPoint answers
        // null for anything below the fold, and the matrix sits well down an
        // 800px-tall #notifications page — measured: the header hit-test read
        // "nothing" identically with the corner 1px tall and with it 55px
        // tall, i.e. a red that fired on both sides of the fix and proved
        // nothing. A hit-test that cannot tell the states apart is not a
        // measurement.
        await evalJs(`(function(){var s=document.querySelector('.set-matrix');if(s){s.scrollIntoView({block:'center'});s.scrollLeft=0;}})()`);
        await settle();
        const rest = await evalJs(
          `(function(){var s=document.querySelector('.set-matrix');if(!s)return null;` +
          `var ev=s.querySelector('.set-matrix-event');var sr=s.getBoundingClientRect();` +
          `var cols=[].slice.call(s.querySelectorAll('.set-matrix-col'));` +
          `return {sw:s.scrollWidth,cw:s.clientWidth,track:s.offsetHeight-s.clientHeight,` +
          ` fade:getComputedStyle(s).getPropertyValue('--set-matrix-fade').trim(),` +
          ` pos:getComputedStyle(ev).position,` +
          ` evLeft:Math.round(ev.getBoundingClientRect().left*100)/100,` +
          ` scLeft:Math.round(sr.left*100)/100,` +
          ` hidden:cols.filter(function(c){return c.getBoundingClientRect().left>=sr.right-0.5;}).length,` +
          ` cols:cols.length};})()`,
        );
        await evalJs(`(function(){var s=document.querySelector('.set-matrix');s.scrollLeft=120;})()`);
        await settle();
        // The hit-test at the HEADER row is not decoration. The grid is
        // `align-items: center`, and the corner cell is EMPTY — left to its
        // content it lays out 1px tall and centred, so the channel headings
        // scroll straight THROUGH the pinned label column while every row
        // below is covered correctly. A screenshot catches that; a position
        // read does not. So: sample the middle of the label column at the
        // middle of the header row and name whatever is actually on top.
        const mid = await evalJs(
          `(function(){var s=document.querySelector('.set-matrix');var ev=s.querySelector('.set-matrix-event');` +
          `var co=s.querySelector('.set-matrix-corner');var cr=co.getBoundingClientRect();` +
          `var hd=s.querySelector('.set-matrix-col').getBoundingClientRect();` +
          `var hit=document.elementFromPoint(cr.left+cr.width/2,hd.top+hd.height/2);` +
          `return {sl:s.scrollLeft,evLeft:Math.round(ev.getBoundingClientRect().left*100)/100,` +
          ` cornerH:Math.round(cr.height*100)/100,headH:Math.round(hd.height*100)/100,` +
          ` onTop:hit?(hit.className||hit.tagName):'nothing'};})()`,
        );
        await evalJs(`(function(){var s=document.querySelector('.set-matrix');s.scrollLeft=s.scrollWidth;})()`);
        await settle();
        const end = await evalJs(
          `(function(){var s=document.querySelector('.set-matrix');` +
          `return {sl:s.scrollLeft,fade:getComputedStyle(s).getPropertyValue('--set-matrix-fade').trim()};})()`,
        );
        return { rest, mid, end };
      };
      const px = (v) => Number(String(v || "0px").replace("px", ""));

      for (const theme of ["light", "dark"]) {
        await setViewport(768);
        await nav(
          `${BASE}/?scen=notif-configured&theme=${theme}#notifications`,
          `document.querySelector('.set-matrix .set-matrix-grid .set-matrix-event')`,
        );
        for (const width of [768, 430, 390]) {
          await setViewport(width);
          const { rest, mid, end } = await readMatrix();
          if (!rest) { fail(D, `notif-configured/${theme}@${width}: .set-matrix missing`); continue; }
          const clipped = rest.sw > rest.cw;
          if (!clipped) { fail(D, `notif-configured/${theme}@${width}: matrix NOT clipped (${rest.sw}/${rest.cw}) — the fixture no longer reproduces the condition`); continue; }
          // Cue 1 — the label column holds its ground while the channels move.
          if (rest.pos !== "sticky") fail(D, `notif-configured/${theme}@${width}: .set-matrix-event position is "${rest.pos}", expected "sticky" — the label column scrolls away with the channels`);
          else if (Math.abs(mid.evLeft - rest.scLeft) > 1.5) fail(D, `notif-configured/${theme}@${width}: sticky label left ${mid.evLeft} != scroller left ${rest.scLeft} after scrolling to ${mid.sl} — sticky is declared but DEAD (an overflow:hidden ancestor is the scrollport)`);
          else if (mid.cornerH < mid.headH - 0.5) fail(D, `notif-configured/${theme}@${width}: the sticky corner is ${mid.cornerH}px tall in a ${mid.headH}px header row — the channel headings scroll THROUGH the pinned label column at the top (align-items:center collapses an empty cell)`);
          else if (!String(mid.onTop).includes("set-matrix-corner")) fail(D, `notif-configured/${theme}@${width}: at the header row the label column is covered by "${mid.onTop}", not .set-matrix-corner`);
          else okLine(`notif-configured/${theme}@${width}: ${rest.hidden}/${rest.cols} channel columns off-screen at rest; label column sticks at ${mid.evLeft} through scrollLeft ${mid.sl}, corner covers the header row (${mid.cornerH}/${mid.headH}px); reserved scrollbar track ${rest.track}px`);
          // Cue 2 — the fade exists while clipped and retracts at the end.
          if (px(rest.fade) <= 0) fail(D, `notif-configured/${theme}@${width}: edge fade is ${rest.fade} while ${rest.sw - rest.cw}px of the matrix is hidden — nothing tells a person there is more`);
          else if (px(end.fade) > 0.5) fail(D, `notif-configured/${theme}@${width}: edge fade still ${end.fade} at scrollLeft ${end.sl} (the end) — the cue lies in the other direction`);
          else okLine(`notif-configured/${theme}@${width}: edge fade ${rest.fade} at rest -> ${end.fade} at the end`);
        }
        // The cue must be ABSENT when nothing is hidden — the control that
        // makes "only while clipped" a measurement rather than a hope.
        await setViewport(1440);
        const wide = await readMatrix();
        if (wide.rest.sw > wide.rest.cw) fail(D, `notif-configured/${theme}@1440: matrix still clipped (${wide.rest.sw}/${wide.rest.cw}) — control invalid`);
        else if (px(wide.rest.fade) > 0.5) fail(D, `notif-configured/${theme}@1440: edge fade ${wide.rest.fade} with nothing hidden — the cue fires when it should not`);
        else okLine(`notif-configured/${theme}@1440: nothing hidden, fade ${wide.rest.fade} — the cue is scoped to the clipped state`);
      }
    }
    // ── W13: the detail routes stop scrolling sideways in the tablet band ──
    //    Five detail routes plus #fleet, 9 widths x 2 themes = 108 cells. Every
    //    cell asserts TWO things: the page does not scroll horizontally, and the
    //    route that was asked for is the route that rendered.
    if (requested.includes("W13-detail-route-band")) {
      const D = "W13-detail-route-band";
      process.stdout.write(
        `\n${D} — ${BAND_ROUTES.length} routes x ${BAND_WIDTHS.length} widths x 2 themes` +
        ` (${BAND_ROUTES.length * BAND_WIDTHS.length * 2} cells) + .detail-rail .status-pill on both axes\n`,
      );
      let cells = 0, offenders = 0, misrouted = 0, railPills = 0, railBad = 0;
      for (const r of BAND_ROUTES) {
        for (const theme of ["light", "dark"]) {
          // Enter at 900 — ABOVE the band — so a route that only renders at one
          // width cannot be mistaken for a route that renders everywhere.
          await setViewport(900);
          await nav(
            `${BASE}/?scen=${r.scen}&theme=${theme}${r.hash}`,
            `document.querySelector('${r.ready}') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='${r.view}';})()`,
          );
          const row = [];
          for (const width of BAND_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var t=document.querySelector('.inst-tab[aria-current="page"]');` +
              // W16-S3: THE RAIL'S OWN PILL, measured in the cells this leg
              // already visits. `cch-w14-bl-status-pill-label-overflows-rail`
              // lived HERE and every leg in this file walked past it: the page
              // never scrolls (the chip clips, it does not push), so a
              // page-level assertion certifies a rail whose label paints 36.52px
              // past its own chip. Both axes, because a wrap fixes the
              // horizontal one and can invent the vertical one.
              `var rp=[].slice.call(document.querySelectorAll('.detail-rail .status-pill')).map(function(p){` +
              `  var pr=p.getBoundingClientRect(); var l=p.querySelector('.status-pill-label');` +
              `  return {sw:p.scrollWidth,cw:p.clientWidth,sh:p.scrollHeight,ch:p.clientHeight,` +
              `    lh:l?+l.getBoundingClientRect().height.toFixed(2):0,ph:+pr.height.toFixed(2),` +
              `    lsw:l?l.scrollWidth:0,lcw:l?l.clientWidth:0,t:(p.textContent||'').slice(0,40)};});` +
              `return {sw:d.scrollWidth, cw:d.clientWidth, view:v?v.id:'none', rp:rp,` +
              ` tab:t?t.textContent:null, theme:d.getAttribute('data-theme')};})()`,
            );
            cells++;
            // (1) THE ROUTE. Without this the whole table is phantom.
            if (m.view !== r.view) {
              misrouted++;
              fail(D, `${r.name}/${theme}@${width}: rendered section.view "${m.view}", asked for "${r.view}" — the hash did not route, so nothing below this line measures ${r.name}`);
            } else if (r.tab && m.tab !== r.tab) {
              misrouted++;
              fail(D, `${r.name}/${theme}@${width}: #view-instance is up but the active sub-tab is "${m.tab}", expected "${r.tab}" — a sibling instance route was measured`);
            }
            if (m.theme !== theme) fail(D, `${r.name}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // (2) THE PIXELS.
            const over = m.sw - m.cw;
            if (over > 0) {
              offenders++;
              fail(D, `${r.name}/${theme}@${width}: scrollWidth ${m.sw} > viewport ${m.cw} — ${over}px of the page is off-screen at rest, with no cue`);
            }
            // (3) THE RAIL'S PILLS — element geometry, both axes. Counted
            // separately from `cells` so this leg's 108/108 stays 108/108.
            for (const p of m.rp) {
              railPills++;
              if (p.sw > p.cw) {
                railBad++;
                fail(D, `${r.name}/${theme}@${width} .detail-rail .status-pill: scrollWidth ${p.sw} > clientWidth ${p.cw} — ${Math.round((1 - p.cw / p.sw) * 100)}% of "${p.t}" renders OUTSIDE its own chip (the label declares no overflow, so it is painted, not clipped) and the page never scrolls, which is why every page-level leg above walks past it`);
              }
              if (p.lsw > p.lcw) {
                railBad++;
                fail(D, `${r.name}/${theme}@${width} .status-pill-label: scrollWidth ${p.lsw} > clientWidth ${p.lcw} — the LABEL's own box does not hold its glyphs. Shrinking the label box alone scores clean on \`label.right - pill.right\` and moves no glyph; this is the metric that cannot be bought that way`);
              }
              if (p.sh > p.ch) {
                railBad++;
                fail(D, `${r.name}/${theme}@${width} .detail-rail .status-pill: ${p.sh}px of text in a ${p.ch}px chip — "${p.t}" paints BELOW the capsule. This is the wrap remedy's own trap: without \`height: auto\` it scores clean on every width metric above`);
              }
              if (p.lh > p.ph + 0.5) {
                railBad++;
                fail(D, `${r.name}/${theme}@${width} .status-pill-label: the label box is ${p.lh}px tall inside a ${p.ph}px pill`);
              }
            }
            row.push(`${width}:${m.sw}${over > 0 ? "!" : ""}`);
          }
          process.stdout.write(`   ${r.name}/${theme}  ${row.join(" ")}\n`);
        }
      }
      // AUDITED: an empty list is not a clean list. If the rail stops rendering
      // a pill this leg would score 0 rail defects and read as a pass.
      if (railPills === 0) {
        fail(D, `zero .detail-rail .status-pill measured across ${cells} cells — the rail pill stopped rendering, so its assertions measured nothing. This is not a pass.`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${railPills} .detail-rail .status-pill(s) measured on both axes, ${railBad} outside their own chip`,
        );
        okLine(
          `${cells} / ${cells} cells clean across ${BAND_WIDTHS[0]}-${BAND_WIDTHS[BAND_WIDTHS.length - 1]}` +
          ` (769/899 are the band edges, 900/1024 the controls above it); ${misrouted} misrouted;` +
          ` no exemptions — #fleet's W13 residual was paid by W14-S3 and its pin is gone`,
        );
      }
    }

    // ── W15: the fleet row's CELLS, which every leg above is blind to ───────
    //    Element-level geometry, not page-level. See the note by FLEET_WIDTHS.
    if (requested.includes("W15-fleet-row-text-bounded")) {
      const D = "W15-fleet-row-text-bounded";
      const cellCount = FLEET_SCENS.length * FLEET_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${FLEET_SCENS.length} scenarios x ${FLEET_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells, ${FLEET_TEXT_SELS.join("/")} + .status-pill-detail + .fleet-badges + .status-pill HEIGHT)\n`,
      );
      let cells = 0, clipped = 0, ellipsed = 0, squeezed = 0, pageOver = 0, rowsSeen = 0, overflowed = 0;
      const knownSeen = new Set();
      for (const scen of FLEET_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter ABOVE the band, like the W13 leg, and assert the landed view —
          // `?scen=` alone renders #overview and the whole table goes phantom.
          await setViewport(1000);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#fleet`,
            `document.querySelector('.fleet-row') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-fleet';})()`,
          );
          const row = [];
          for (const width of FLEET_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var sels=${JSON.stringify(FLEET_TEXT_SELS)};` +
              `var d=document.documentElement;` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,rows:0,clips:[],ell:[],sq:[],tall:[]};` +
              `[].slice.call(document.querySelectorAll('.fleet-row')).forEach(function(r,i){out.rows++;` +
              `  sels.forEach(function(s){var e=r.querySelector(s); if(!e) return;` +
              `    if(e.scrollWidth>e.clientWidth) out.clips.push({i:i,s:s,sw:e.scrollWidth,cw:e.clientWidth,t:(e.textContent||'').slice(0,32)});});` +
              `  var p=r.querySelector('.status-pill-detail');` +
              `  if(p&&p.scrollWidth>p.clientWidth) out.ell.push({i:i,sw:p.scrollWidth,cw:p.clientWidth,t:(p.textContent||'').slice(0,40)});` +
              // W16-S3 (d): IS THE CHIP TALL ENOUGH FOR ITS OWN TEXT. The first
      // VERTICAL question any instrument in __preview__ has ever asked. The
      // remedy for (b) is a WRAP, and a wrap without `height: auto` scores
      // clean on every horizontal metric above while a 36px label sits inside
      // a 24px chip and the second line paints BELOW the capsule — invisible
      // to a scrollWidth-only scorer, which is what every leg in this file was.
      `  var pl=r.querySelector('.status-pill');` +
      `  if(pl){var plr=pl.getBoundingClientRect();` +
      `    if(pl.scrollHeight>pl.clientHeight) out.tall.push({i:i,k:'chip',sh:pl.scrollHeight,ch:pl.clientHeight,t:(pl.textContent||'').slice(0,40)});` +
      `    [].slice.call(pl.children).forEach(function(c){var cr=c.getBoundingClientRect();` +
      `      if(cr.height>plr.height+0.5) out.tall.push({i:i,k:c.className,sh:+cr.height.toFixed(2),ch:+plr.height.toFixed(2),t:(c.textContent||'').slice(0,40)});});}` +
      `  var b=r.querySelector('.fleet-badges');` +
              `  if(b&&b.scrollWidth>0&&b.getBoundingClientRect().width+0.5<b.scrollWidth)` +
              `    out.sq.push({i:i,w:+b.getBoundingClientRect().width.toFixed(2),sw:b.scrollWidth});});` +
              `return out;})()`,
            );
            cells++;
            if (m.view !== "view-fleet") {
              fail(D, `${scen}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-fleet" — the hash did not route, so nothing below this line measures the fleet row`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: an empty list is not a clean list. A scenario that
            // renders zero rows would score 0 clips and read as a pass.
            if (m.rows === 0) fail(D, `${scen}/${theme}@${width}: zero .fleet-row rendered — nothing was measured, this is not a pass`);
            rowsSeen += m.rows;
            // THE SCOPE TRIPWIRE (review addition). Element-level questions are
            // this leg's point, but the fix's own failure mode is PAGE-level and
            // lives BELOW its media query: unscoped, these declarations were
            // driven at 846px against a 721px viewport. Reading the page here
            // costs one property and turns the slice's proof into a check.
            if (m.psw > m.pcw) {
              pageOver++;
              fail(D, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the page is off-screen sideways. Below 900 this is the signature of the fix leaking out of its \`@media (min-width: 900px)\` scope: \`flex-wrap: wrap\` on the stacked (column) .fleet-row wraps into COLUMNS`);
            }
            for (const c of m.clips) {
              clipped++;
              fail(D, `${scen}/${theme}@${width} row${c.i} ${c.s}: scrollWidth ${c.sw} > clientWidth ${c.cw} — ${Math.round((1 - c.cw / c.sw) * 100)}% of "${c.t}" is not rendered, and the box computes overflow:visible so the remainder is painted THROUGH the badge column`);
            }
            for (const e of m.ell) {
              const k = knownHit(scen, ".status-pill-detail", width);
              if (k) {
                knownSeen.add(`${k.row}|${scen}|${width}`);
                process.stdout.write(`   · known  ${k.row}  ${scen}/${theme}@${width} row${e.i} .status-pill-detail ${e.sw}>${e.cw}: ${k.why}\n`);
                continue;
              }
              ellipsed++;
              fail(D, `${scen}/${theme}@${width} row${e.i} .status-pill-detail: scrollWidth ${e.sw} > clientWidth ${e.cw} — the money message "${e.t}" is truncated (GR116)`);
            }
            for (const s of m.sq) {
              squeezed++;
              fail(D, `${scen}/${theme}@${width} row${s.i} .fleet-badges: box ${s.w}px around ${s.sw}px of content — the badge column was collapsed to buy the text room`);
            }
            for (const t of m.tall) {
              overflowed++;
              fail(D, `${scen}/${theme}@${width} row${t.i} ${t.k === "chip" ? ".status-pill" : "." + t.k}: ${t.sh}px of text in a ${t.ch}px chip — "${t.t}" paints BELOW the capsule. A wrap without \`height: auto\` scores clean on every scrollWidth metric and still puts the words outside the box.`);
            }
            const bad = m.clips.length + m.sq.length + m.tall.length + (m.psw > m.pcw ? 1 : 0) +
              m.ell.filter(() => !knownHit(scen, ".status-pill-detail", width)).length;
            row.push(`${width}:${m.rows}r${bad ? "!" + bad : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join(" ")}\n`);
        }
      }
      // A KNOWN ENTRY THAT NO LONGER MATCHES IS A FAILURE, not a tidy-up. Without
      // this the allowlist is write-only: the row gets paid, nobody deletes the
      // entry, and the next real defect at those cells is silently forgiven.
      for (const k of FLEET_KNOWN) {
        const hit = [...knownSeen].some((s) => s.startsWith(`${k.row}|`));
        if (!hit) {
          fail(D, `known-hit entry ${k.row} (${k.scen} ${k.sel} @ ${k.widths.join("/")}) matched NOTHING — either the row was paid and this entry must be DELETED, or the cell stopped rendering. An allowlist that cannot go stale is an allowlist that forgives the next defect.`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${rowsSeen} fleet rows measured, ${knownSeen.size} known-row cells itemised: ${FLEET_KNOWN.map((k) => k.row).join(", ") || "none"}) across ` +
          `${FLEET_WIDTHS.join("/")}; ${clipped} clipped text cells, ${ellipsed} ellipsed money ` +
          `messages, ${squeezed} squeezed badge columns, ${overflowed} chips shorter than their own text, ` +
          `${pageOver} pages scrolling sideways; ` +
          `${FLEET_KNOWN.length} itemised known row(s), every other cell judged`,
        );
      }
    }

    // ── W18: the FRONT SCREEN's instance card, which no leg above drives ────
    //    See the note by CARD_WIDTHS. Element geometry on BOTH axes, on both
    //    front-screen scenarios, because the horizontal score alone certifies
    //    the trap.
    //
    //    W20-S3 EXTENDS THIS LEG IN PLACE with the card's SECOND text host,
    //    `.instance-card-url`. It is the same defect class one element down:
    //    on origin/main bytes the address line ellipsised at 14 of 42 driven
    //    cells (320/360/390 x both scenarios x both themes), and what it drops
    //    is the TAIL — the TLD — so two boxes on two different domains render
    //    as the SAME visible string on the most-seen screen in the product.
    //    `grep -n instance-card-url overflow-guard.mjs` returned nothing on
    //    that tree: the pill half of this very leg was measuring beside a
    //    blind spot.
    //
    //    THE VACUOUS-GREEN VECTOR THIS LEG MUST NOT WALK INTO: `mixed-fleet`
    //    renders FIVE `.instance-card-url` of which TWO are EMPTY (a
    //    provisioning and a failed box render a chip instead of an address, so
    //    the node exists with no text and can never clip). A leg that counted
    //    NODES would score 2 of every 5 assertions about nothing, and would
    //    stay green if the card stopped rendering addresses entirely. So the
    //    non-empty text node is REQUIRED: urls with text are counted per cell
    //    and a cell that measures zero of them FAILS.
    if (requested.includes("W18-overview-card-pill")) {
      const D = "W18-overview-card-pill";
      const cellCount = CARD_SCENS.length * CARD_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${CARD_SCENS.length} scenarios x ${CARD_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; .instance-card-head .status-pill-detail width, .status-pill height, detail bottom edge,` +
        ` .instance-card-url width with a non-empty text node required)\n`,
      );
      let cells = 0, pillsSeen = 0, clipped = 0, tall = 0, outside = 0, pageOver = 0;
      let urlsSeen = 0, urlsEmpty = 0, urlClipped = 0, stressSeen = 0, stressClipped = 0;
      for (const scen of CARD_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter wide and assert the landed view — `?scen=` alone does not
          // route (see the W13 note), and a phantom table is worse than none.
          await setViewport(1000);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#overview`,
            `document.querySelector('.instance-card-head .status-pill-detail') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-overview';})()`,
          );
          const row = [];
          for (const width of CARD_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var d=document.documentElement;` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,pills:0,clips:[],tall:[],out:[],h:[],att:[],urls:0,urlsEmpty:0,urlClips:[],urlH:[],stress:0,stressClips:[]};` +
              // W20-S3: the address line. TEXT-GATED — a node with no text is
              // counted as empty and asserted about NOTHING, and the cell's
              // non-empty count is asserted below so an all-empty render is a
              // failure rather than a clean score.
              `[].slice.call(document.querySelectorAll('.instance-card-url')).forEach(function(e,i){` +
              `  var t=(e.textContent||'').trim();` +
              `  if(!t){ out.urlsEmpty++; return; }` +
              `  out.urls++; out.urlH.push(e.offsetHeight);` +
              `  if(e.scrollWidth>e.clientWidth) out.urlClips.push({i:i,sw:e.scrollWidth,cw:e.clientWidth,t:t.slice(0,60)});` +
              `});` +
              // W20-S3, THE HALF THAT CAN LOSE. The fixture's own addresses are
              // ~32 chars once the scheme is shaved, so on THESE strings the
              // shave alone clears every width here — revert the stylesheet and
              // the loop above still scores clean. That is exactly the vacuity
              // this epic keeps finding: an instrument that only ever sees the
              // easy string certifies a remedy it never tested. `slug` is
              // capped at 63 by the API (validate_length) and `@base_domain` is
              // "barkpark.cloud", so the address a real customer can create is
              // ~85 characters — the length the WRAP, and only the wrap, bounds.
              // Each non-empty address is swapped to that worst case, measured,
              // and RESTORED in the same synchronous pass, so nothing below or
              // after this eval sees a mutated DOM.
              `var CAP=new Array(64).join('a')+'-5b2c1e.barkpark.cloud';` +
              `[].slice.call(document.querySelectorAll('.instance-card-url')).forEach(function(e,i){` +
              `  var t=(e.textContent||'').trim(); if(!t) return;` +
              `  e.textContent=CAP; out.stress++;` +
              `  if(e.scrollWidth>e.clientWidth) out.stressClips.push({i:i,sw:e.scrollWidth,cw:e.clientWidth,n:CAP.length});` +
              `  e.textContent=t;` +
              `});` +
              `[].slice.call(document.querySelectorAll('.instance-card-head')).forEach(function(head,i){` +
              `  var pill=head.querySelector('.status-pill'); if(!pill) return; out.pills++;` +
              `  var pr=pill.getBoundingClientRect();` +
              `  out.h.push(+pr.height.toFixed(2));` +
              `  if(pill.scrollHeight>pill.clientHeight) out.tall.push({i:i,sh:pill.scrollHeight,ch:pill.clientHeight,t:(pill.textContent||'').slice(0,44)});` +
              `  var det=head.querySelector('.status-pill-detail'); if(!det) return;` +
              `  if(det.scrollWidth>det.clientWidth) out.clips.push({i:i,sw:det.scrollWidth,cw:det.clientWidth,t:(det.textContent||'').slice(0,48)});` +
              `  var dr=det.getBoundingClientRect();` +
              `  if(dr.bottom>pr.bottom+0.5) out.out.push({i:i,db:+dr.bottom.toFixed(2),pb:+pr.bottom.toFixed(2),t:(det.textContent||'').slice(0,48)});` +
              `});` +
              // REPORTED, NEVER ASSERTED: `.attention-row`'s pill is a DIFFERENT
              // host in the SAME DOM, clipping in a DIFFERENT band (148/165 at
              // 320, 117/165 at 769) and owned by task-802585b77fc136b1. It is
              // printed so this slice's "we did not disturb it" is a number a
              // reader can check, and it is NOT judged here — asserting another
              // slice's open row would red this leg on merged main.
              `[].slice.call(document.querySelectorAll('.attention-row .status-pill-detail')).forEach(function(e,i){` +
              `  out.att.push(e.clientWidth+'/'+e.scrollWidth);});` +
              `return out;})()`,
            );
            cells++;
            if (m.view !== "view-overview") {
              fail(D, `${scen}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-overview" — the hash did not route, so nothing below this line measures the front screen`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: an empty list is not a clean list. A front screen that
            // stopped rendering instance-card pills would score zero findings.
            if (m.pills === 0) {
              fail(D, `${scen}/${theme}@${width}: zero .instance-card-head .status-pill rendered — nothing was measured, this is not a pass`);
              row.push(`${width}:0p`);
              continue;
            }
            pillsSeen += m.pills;
            if (m.psw > m.pcw) {
              pageOver++;
              fail(D, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the front screen is off-screen sideways`);
            }
            for (const c of m.clips) {
              clipped++;
              fail(D, `${scen}/${theme}@${width} card${c.i} .instance-card-head .status-pill-detail: scrollWidth ${c.sw} > clientWidth ${c.cw} — ${Math.round((1 - c.cw / c.sw) * 100)}% of "${c.t}" is not rendered, so the front screen does not say WHY this instance is degraded`);
            }
            for (const t of m.tall) {
              tall++;
              fail(D, `${scen}/${theme}@${width} card${t.i} .instance-card-head .status-pill: ${t.sh}px of text in a ${t.ch}px chip — "${t.t}" paints BELOW the capsule. A wrap without \`height: auto\` scores clean on every scrollWidth metric and still puts the words outside the box.`);
            }
            // W20-S3: the address line, judged on the SAME cell. The empty
            // count is printed, never asserted — a provisioning box legitimately
            // has no address — but a cell where NOTHING carried text is a
            // measurement that did not happen.
            urlsEmpty += m.urlsEmpty;
            if (m.urls === 0) {
              fail(D, `${scen}/${theme}@${width}: zero NON-EMPTY .instance-card-url rendered (${m.urlsEmpty} empty nodes) — the front screen printed no address at all, so nothing about the address was measured. This is not a pass`);
            }
            urlsSeen += m.urls;
            stressSeen += m.stress;
            for (const s of m.stressClips) {
              stressClipped++;
              fail(D, `${scen}/${theme}@${width} url${s.i} .instance-card-url @ the DNS cap: scrollWidth ${s.sw} > clientWidth ${s.cw} on a ${s.n}-character address (63-char slug + @base_domain, the longest a customer can create) — ${Math.round((1 - s.cw / s.sw) * 100)}% unrendered. The scheme shave alone clears the fixture's short strings and leaves THIS clipping; only the wrap bounds it`);
            }
            for (const u of m.urlClips) {
              urlClipped++;
              fail(D, `${scen}/${theme}@${width} url${u.i} .instance-card-url: scrollWidth ${u.sw} > clientWidth ${u.cw} — ${Math.round((1 - u.cw / u.sw) * 100)}% of "${u.t}" is not rendered. What gets dropped is the TAIL, so two instances on different domains read as the SAME string on the front screen`);
            }
            for (const o of m.out) {
              outside++;
              fail(D, `${scen}/${theme}@${width} card${o.i} .instance-card-head .status-pill-detail: bottom ${o.db} is ${(o.db - o.pb).toFixed(2)}px BELOW the pill's bottom ${o.pb} — "${o.t}" is painted outside its own chip`);
            }
            const bad = m.clips.length + m.tall.length + m.out.length + m.urlClips.length +
              m.stressClips.length + (m.urls === 0 ? 1 : 0) + (m.psw > m.pcw ? 1 : 0);
            row.push(
              `${width}:${m.pills}p h${m.h.join(",")} ${m.urls}u/${m.urlsEmpty}e uh${[...new Set(m.urlH)].join(",")}` +
              `${bad ? " !" + bad : ""}${m.att.length ? " [att " + m.att.join(" ") + "]" : ""}`,
            );
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${pillsSeen} instance-card pills measured on BOTH axes) across ` +
          `${CARD_WIDTHS.join("/")} on ${CARD_SCENS.join(" + ")}; ${clipped} truncated reasons, ` +
          `${tall} chips shorter than their own text, ${outside} details painting below their pill, ` +
          `${pageOver} pages scrolling sideways. Heights are printed (h…) per cell and pinned in the PR, ` +
          `not here: the wrap boundary is a property of the fixture STRING`,
        );
        okLine(
          `.instance-card-url: ${urlsSeen} NON-EMPTY address lines measured (${urlsEmpty} empty nodes counted and ` +
          `deliberately asserted about nothing — a provisioning/failed box renders a chip, not an address), ` +
          `${urlClipped} truncated addresses, and ${stressSeen} of those same lines re-measured at the DNS cap ` +
          `(a 85-character address) with ${stressClipped} truncated — the half that can LOSE, because the scheme ` +
          `shave alone clears the fixture's short strings. A cell measuring zero non-empty addresses FAILS, so the empty ` +
          `nodes cannot manufacture a green. Per-cell "Nu/Me uh…" is the non-empty/empty split and the line ` +
          `heights; the heights are REPORTED — the wrap boundary belongs to the STRING, not the CSS`,
        );
        okLine(
          `[att …] cells are \`.attention-row .status-pill-detail\` — a DIFFERENT host in the same DOM, ` +
          `printed for comparison and deliberately NOT judged here (task-802585b77fc136b1 owns that band)`,
        );
      }
    }

    // ── W20: the OPERATOR GATE pill, on a surface nobody can reach today ────
    //    NO PERSON-FACING SEAT, STATED IN THE INSTRUMENT ITSELF. The operator
    //    console has population ZERO on the running system: PLATFORM_ADMIN_EMAILS
    //    is unset (re-derived by `printenv`'s EXIT CODE inside the one running
    //    control-plane container — NOT by `docker inspect`, whose Config.Env
    //    carries the bare compose-passthrough NAME and reads as a false
    //    positive), the key is absent from the host .env, /v1/operator/fleet
    //    answers 401 while / answers 200, and there is no second source for the
    //    flag: cloud/config/runtime.exs feeds ONE list that both the /v1/me
    //    boolean in router.ex and the operator pipeline in auth.ex read, and
    //    `x in []` is false for every x. This leg is INSTRUMENT work with a
    //    LATENT tail — one env line makes the defect live for a real person at
    //    every phone width and across the tablet band below.
    //
    //    THE DEFECT: `.op-gate` is a flex row and the base `.status-pill`
    //    declares no `flex`, so the chip inherits `flex-shrink: 1` and is
    //    squeezed narrower than the word it contains — the label paints outside
    //    its own capsule. Fixed by ONE declaration, `.op-gate .status-pill {
    //    flex: 0 0 auto }`. The five-declaration wrap recipe the three other
    //    hosts carry was DRIVEN against this host and does NOT fix it (charter
    //    D220): every clipped cell stays clipped. The extraction is refused;
    //    __css_check's E14 measures DIVERGENCE between the copies instead.
    //
    //    THE VACUITY TRAP IS SCENARIO-DEPENDENCE, and it is why this leg pins
    //    its own axes. The defect is NON-MONOTONIC in viewport width, because
    //    the shell folds at 720 and the sidebar returns above it and re-narrows
    //    the column. Driven on origin/main bytes, light, #operator:
    //      • `operator-zero-staging` — red across the phone band, CLEAN at
    //        620/700/720, RED AGAIN across 740-800, clean from 830.
    //      • `operator-halted` — a second band of exactly ONE cell, at 740.
    //      • `operator-console` — NO second band at all.
    //    A leg driving only `operator-console` above 620 reads a clean upper
    //    boundary and ships a vacuous green, so `operator-zero-staging` and a
    //    740-800 cell are ASSERTED PRESENT below, not merely listed. A second
    //    vector: the `operator-visible` scenario renders ZERO `.status-pill` in
    //    the whole document, so a leg scoped to it would exit 0 having measured
    //    nothing — hence the zero-pill FAIL per cell.
    if (requested.includes("W20-op-gate-pill-bounded")) {
      const D = "W20-op-gate-pill-bounded";
      // BLOCK-SCOPED on the `const D` precedent above: these axes belong to
      // this leg alone and must not read as shared file constants.
      const GATE_SCENS = ["operator-console", "operator-halted", "operator-zero-staging"];
      // 14 widths. The phone band, the CLEAN shelf that makes the second band a
      // discontinuity rather than a tail, the second band itself, and 830 as the
      // measured upper edge (clean on pre-fix bytes, so it pins the edge rather
      // than assuming it).
      const GATE_WIDTHS = [320, 360, 390, 430, 480, 620, 700, 720, 740, 760, 768, 780, 800, 830];
      const SECOND_BAND = [740, 800];
      // ANTI-VACUITY 0 — the axes themselves. An edit that drops the
      // scenario-dependent scenario or the second band would leave a leg that
      // passes for the wrong reason; it reds here instead of going quiet.
      if (!GATE_SCENS.includes("operator-zero-staging")) {
        fail(D, `axis check: \`operator-zero-staging\` is not in the scenario set — it is the ONLY scenario red across the whole second band, so without it this leg cannot see 740-800 at all`);
      }
      if (!GATE_WIDTHS.some((w) => w >= SECOND_BAND[0] && w <= SECOND_BAND[1])) {
        fail(D, `axis check: no width in ${SECOND_BAND[0]}-${SECOND_BAND[1]} — the defect is NON-MONOTONIC in width, so a phone-only sweep certifies a clean upper boundary that is not there`);
      }
      const cellCount = GATE_SCENS.length * GATE_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${GATE_SCENS.length} operator scenarios x ${GATE_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; .op-gate .status-pill scrollWidth vs clientWidth, + page overflow)\n`,
      );
      let cells = 0, pillsSeen = 0, squeezed = 0, pageOver = 0;
      for (const scen of GATE_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter wide and assert the LANDED view — `?scen=` alone does not
          // route (see the W13 note), and a phantom console is worse than none.
          await setViewport(1000);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#operator`,
            `document.querySelector('.op-gate .status-pill') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-operator';})()`,
          );
          const row = [];
          for (const width of GATE_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var d=document.documentElement;` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,pills:0,bad:[],m:[]};` +
              `[].slice.call(document.querySelectorAll('.op-gate .status-pill')).forEach(function(p,i){` +
              `  out.pills++;` +
              `  out.m.push(p.clientWidth+'/'+p.scrollWidth);` +
              `  if(p.scrollWidth>p.clientWidth) out.bad.push({i:i,sw:p.scrollWidth,cw:p.clientWidth,t:(p.textContent||'').trim().slice(0,32)});` +
              `});` +
              `return out;})()`,
            );
            cells++;
            if (m.view !== "view-operator") {
              fail(D, `${scen}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-operator" — the hash did not route, so nothing below this line measures the operator console`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: an empty list is not a clean list. `operator-visible`
            // renders zero `.status-pill` in the entire document — scoped there
            // this leg would print a green having measured nothing. Zero pills
            // is a FAILURE, not a pass, at every cell.
            if (m.pills === 0) {
              fail(D, `${scen}/${theme}@${width}: zero \`.op-gate .status-pill\` rendered — nothing was measured, this is not a pass`);
              row.push(`${width}:0p`);
              continue;
            }
            pillsSeen += m.pills;
            if (m.psw > m.pcw) {
              pageOver++;
              fail(D, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the operator console is off-screen sideways`);
            }
            for (const b of m.bad) {
              squeezed++;
              fail(D, `${scen}/${theme}@${width} gate${b.i} \`.op-gate .status-pill\`: scrollWidth ${b.sw} > clientWidth ${b.cw} — the chip is ${b.sw - b.cw}px narrower than its own label "${b.t}", which therefore paints OUTSIDE the capsule`);
            }
            row.push(`${width}:${m.m.join(",")}${m.bad.length ? " !" + m.bad.length : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${pillsSeen} .op-gate .status-pill measured) across ` +
          `${GATE_WIDTHS.join("/")} on ${GATE_SCENS.join(" + ")}; ${squeezed} chips narrower than their ` +
          `own label, ${pageOver} pages scrolling sideways. Cells print clientWidth/scrollWidth so the ` +
          `discontinuity is readable: the second band at ${SECOND_BAND[0]}-${SECOND_BAND[1]} is driven on ` +
          `\`operator-zero-staging\` EXPLICITLY, and zero measured pills fails rather than passes`,
        );
        okLine(
          `this leg is INSTRUMENT work: the operator console has population zero today ` +
          `(PLATFORM_ADMIN_EMAILS unset — re-derive with printenv's EXIT CODE, never docker inspect), ` +
          `so it fills no person-facing seat. One env line makes every cell above person-facing`,
        );
      }
    }
  } catch (err) {
    // AUDITED (exit 2): the probe itself threw, so NOTHING was measured — an
    // incomplete run must never be reported as a measured overflow.
    return die(`measurement broke: ${err.message}`);
  }

  await teardown();

  process.stdout.write("\n");
  if (failures.length) {
    const byDefect = [...new Set(failures.map((f) => f.defect))];
    process.stderr.write(`OVERFLOW GUARD FAIL — ${failures.length} finding(s) in: ${byDefect.join(", ")}\n`);
    process.exit(1);
  }
  process.stdout.write(`OVERFLOW GUARD PASS — ${requested.join(", ")} measured fixed in a real browser\n`);
  process.exit(0);
}

main().catch((err) => {
  process.stderr.write(`!! OVERFLOW GUARD crashed: ${err && err.stack ? err.stack : err}\n`);
  process.exit(1);
});
