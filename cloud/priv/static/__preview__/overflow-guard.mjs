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
//  HONEST SCOPE — A WORKFLOW DOES RUN THIS FILE, AND IT IS NOT A REQUIRED CHECK
//  (corrects charter D109, which this header carried as "THIS FILE IS RUN BY NO
//  WORKFLOW" long after it stopped being true). Re-derived, by line:
//  `.github/workflows/console-harness.yml:487` declares the `overflow-guard:`
//  job ("Overflow guard (rendered)"), whose `run:` block opens at :508 and
//  invokes `node cloud/priv/static/__preview__/overflow-guard.mjs` at :511, one
//  invocation with no `--defect`, on every console-touching PR. What remains
//  true is the WEAKER sentence, and only that one: the job reaches branch
//  protection through `Console gate`, which is ADVISORY — the live required set
//  is `Elixir gate` and `PR references an active task`, and `grep -n "Overflow
//  guard" .github/required-checks.json` returns nothing. So its red is VISIBLE
//  and does not by itself block a merge. It is also still a developer tripwire
//  and the seal predicate's shell-out. A header that quotes a workflow — or an
//  exit code — has to be re-driven when it is quoted, or the guard's own
//  documentation becomes the untested sentence this guard exists to replace.
//  The history is worth keeping straight: a tree whose body scrolled 106px at
//  390px passed every required context because nothing measured below 700px and
//  nothing ran this file. The second half of that has since been fixed.
//
//  THE SELECTOR CENSUS OF THIS FILE, with the counting rule beside it, because a
//  census quoted without its rule is how two irreconcilable numbers get cited as
//  one pair. The patterns below are written with a bracketed paren ON PURPOSE —
//  as regexes they match exactly what the bare string does, but they do not
//  themselves match, so quoting the census here does not move it:
//    grep -o 'querySelector[(]'    | wc -l  →  68  OCCURRENCES
//    grep -c 'querySelector[(]'             →  55  LINES carrying at least one
//    grep -o 'querySelectorAll[(]' | wc -l  →  15  (grep -c agrees: 15)
//  The two patterns are disjoint — `querySelectorAll[(]` does not match
//  `querySelector[(]`. Charter D258's "65 / 20 per CALL" is refuted here: 65 is
//  unreproducible by any rule against these bytes, and 20 is this file's 15
//  POOLED with breakpoint-sweep.mjs's 5. Quote 68/55/15, never a mixed pair.
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
import { FONT_PIN_JS, fontPinRefusal } from "./font-pin.mjs";

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
  "W23-account-modal-identity-bounded",
  "W15-fleet-row-text-bounded",
  "W18-overview-card-pill",
  "W23-cred-remediation-reachable",
  "W20-op-gate-pill-bounded",
  "W21-inst-head-320-copy-reachable",
  "W21-members-roster-identity-and-remove",
  "W21-cruel-content-text-bounded",
  "W21-token-reveal-readable",
  "W20-attention-name-column",
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

  // THE FONT PIN (D218). Every width this file asserts is a layout of whatever
  // face resolved, so until both families are proven present every green here
  // is font-conditional. Runs AFTER the ready poll and BEFORE any measurement:
  // load() every declared weight, await fonts.ready, then check() — see
  // font-pin.mjs for why load() is necessary rather than belt-and-braces.
  //
  // Needs its OWN Runtime.evaluate: evalJs above omits awaitPromise, so it
  // would hand back an unresolved Promise handle instead of the verdict.
  //
  // A refusal is exit 2 via die() — a missing woff2 is an ENVIRONMENT fault,
  // never a measured overflow.
  const pinFonts = async (url) => {
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
    // DELIBERATELY SILENT on success. A healthy run's output must stay
    // BYTE-IDENTICAL to the pre-pin baseline, so that the diff proving "zero
    // baselines re-measured" is a real proof and not a re-read of a changed
    // format. The pin speaks only when it refuses.
    if (!report || !report.ok) return die(fontPinRefusal(url, report));
  };

  // Navigate and poll until `readyExpr` is truthy (the SPA mounts async).
  const nav = async (url, readyExpr) => {
    await cdp.send("Page.navigate", { url }, sessionId);
    for (let w = 0; w < RENDER_CAP; w += 100) {
      let ready = false;
      // The pin is called OUTSIDE this catch on purpose: swallowing its refusal
      // as "still navigating" would spend the whole RENDER_CAP and then report
      // a never-ready page — a font fault wearing a timeout's clothes.
      try { ready = !!(await evalJs(`!!(${readyExpr})`)); } catch { /* navigating */ }
      if (ready) { await pinFonts(url); return; }
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

      // (a) the page body, AND EVERY CARD IN THE GRID, ON FOUR FIXTURES. The
      //     fleet grid is the offender: a bare `1fr` track cannot go below the
      //     CARD's min-content, so the track — not the card's children — is
      //     what overhangs a 358px container.
      //
      // W23-S5 — WHAT THIS HALF USED TO ASSERT, AND WHY IT COULD NOT LOSE.
      // It read ONE card (`g.querySelector('.instance-card')`) on ONE scenario
      // (mixed-fleet) and asked `card > grid + 1`. Both halves of that were
      // dead, and only one of them for the obvious reason:
      //
      //  * THE PREDICATE CANNOT FIRE, EVER. `.instance-card` is a stretched
      //    grid item under `grid-template-columns: minmax(0, 1fr)`
      //    (app.css:3509, inside `@media (max-width: 620px)` — and every one of
      //    the ten PHONE_WIDTHS is <= 620), so the card's border-box width IS
      //    the track BY CONSTRUCTION. Measured over 4 scenarios x 10 widths x 2
      //    themes: card[288..288]/grid288 at 320, card[588..588]/grid588 at 620,
      //    identical in all 80 cells. `card > grid + 1` scored ZERO hits under
      //    the reproduced historical defect (54 findings) AND under a 200-char
      //    synthetic token (160 findings). CARD-RECT vs GRID-RECT is the same
      //    vacuity wearing a rect: `cardRect.right > gridRect.right + 1` also
      //    scored zero in both runs. Neither is asserted here.
      //  * SO querySelectorAll ALONE BUYS NOTHING HERE — a homogeneous
      //    population cannot produce a width spread. It is still what this leg
      //    does, because the count is the honest thing to print, and `walked`
      //    is asserted non-zero: a selector that stops matching must red rather
      //    than sail through zero iterations.
      //  * THE LOAD-BEARING FIX IS THE CORPUS. Under the reproduced defect all
      //    54 findings land on `fleet-cruel-content` — this epic's own
      //    worst-case fixture, which had NEVER reached this assertion — and
      //    zero on mixed-fleet. The leg drove mixed-fleet only.
      //
      // WHAT DOES FIRE, 18/18 CELLS EACH: the NAME's rect against its own
      // CARD's rect (nameRect.right 536.219 > cardRect.right 304) and the
      // card-local scroll (card.scrollWidth 517 > clientWidth 284). Note the
      // name element is itself blind to element-local scrollWidth (497/497), so
      // the rect comparison must cross the element boundary — child rect
      // against PARENT rect — to see anything at all.
      const CARD_SCENS = ["mixed-fleet", "fleet-cruel-content", "overview-attention", "overview-past-due"];
      // 320..496 is the defect band; 620 is CLEAN on pre-fix bytes (a 588px
      // track holds the 497px name), so a width list that stopped at the widest
      // phone would have measured nothing at all.
      const BAND_TOP = 496;
      let walked = 0;
      let bandCards = 0;
      let bandHits = 0;
      let wideCards = 0;
      let wideHits = 0;
      const scenCounts = [];
      for (const scen of CARD_SCENS) {
        let scenN = null;
        for (const theme of ["light", "dark"]) {
          await setViewport(390);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#overview`,
            `document.querySelector('.instances-grid .instance-card')`,
          );
          const row = [];
          for (const width of PHONE_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;var R=function(v){return Math.round(v*1000)/1000;};` +
              `var g=document.querySelector('.instances-grid');` +
              `var cards=g?[].slice.call(g.querySelectorAll('.instance-card')):[];` +
              `var hits=[];` +
              `cards.forEach(function(c,i){var cr=c.getBoundingClientRect();` +
              ` [].slice.call(c.querySelectorAll('*')).forEach(function(el){` +
              `   var er=el.getBoundingClientRect();if(er.width<=0)return;` +
              `   if(er.right>cr.right+1)hits.push({i:i,how:'rect',what:'.'+String(el.className||el.tagName).split(' ')[0],` +
              `     a:R(er.right),b:R(cr.right)});});` +
              ` if(c.scrollWidth>c.clientWidth+1)hits.push({i:i,how:'scroll',what:'.instance-card',` +
              `   a:c.scrollWidth,b:c.clientWidth});});` +
              `var gw=R(g?g.getBoundingClientRect().width:0);` +
              `return {sw:d.scrollWidth,cw:d.clientWidth,n:cards.length,grid:gw,hits:hits.slice(0,4),` +
              ` hitN:hits.length,tracks:g?getComputedStyle(g).gridTemplateColumns:''};})()`,
            );
            walked += m.n;
            if (scenN === null) scenN = m.n;
            const inBand = width <= BAND_TOP;
            if (inBand) { bandCards += m.n; bandHits += m.hitN; } else { wideCards += m.n; wideHits += m.hitN; }
            const over = m.sw > m.cw;
            // The page and the cards are asked INDEPENDENTLY — an `else if`
            // here would let a body that already overhangs hide every
            // element-level finding underneath it.
            if (over) fail(D, `${scen}/${theme}@${width}#overview: body scrollWidth ${m.sw} > clientWidth ${m.cw} (${m.sw - m.cw}px overhang) — track ${m.tracks} on a ${m.grid}px container`);
            for (const h of m.hits) {
              if (h.how === "rect") fail(D, `${scen}/${theme}@${width}#overview: .instance-card[${h.i}] ${h.what} rect right ${h.a} overhangs its card's right edge ${h.b} (${Math.round((h.a - h.b) * 10) / 10}px past) — the name pushes the card it lives in`);
              else fail(D, `${scen}/${theme}@${width}#overview: .instance-card[${h.i}] scrollWidth ${h.a} > clientWidth ${h.b} (${h.a - h.b}px of the card is unreachable)`);
            }
            if (m.hitN > m.hits.length) fail(D, `${scen}/${theme}@${width}#overview: ${m.hitN - m.hits.length} further overhang(s) in this cell, not printed`);
            row.push(`${width}:${m.sw}${over || m.hitN ? "!" : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  n${scenN}  ${row.join(" ")}\n`);
        }
        scenCounts.push(`${scen} n${scenN}`);
      }
      // A selector that stops matching must RED, not sail through zero
      // iterations printing a tick.
      if (walked === 0) fail(D, `#overview: .instances-grid .instance-card matched NOTHING across ${CARD_SCENS.length} scenarios x ${PHONE_WIDTHS.length} widths x 2 themes — the selector no longer reaches the population it certifies`);
      else okLine(`instance cards: walked ${walked} = ${CARD_SCENS.length} scenarios (${scenCounts.join(", ")}) x ${PHONE_WIDTHS.length} widths x 2 themes; defect band 320-${BAND_TOP} ${bandCards} cards ${bandHits} overhangs, 620 ${wideCards} cards ${wideHits} overhangs`);

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
        //
        // W23-S5 — THE HEADER ROW IS 55px, NOT COLUMN 0's 35px. This probe used
        // to take `hd` — the row height AND the hit-test y — from
        // `s.querySelector('.set-matrix-col')`, i.e. COLUMN 0, while the census
        // above it already walked ALL of them. Measured across all six cells
        // (light/dark x 768/430/390): heights [35, 35, 35, 55, 55, 35] — two of
        // the six channel headings wrap to two lines. col0 35, tallest 55,
        // corner 55. So the shipped ok-line read "corner covers the header row
        // (55/35px)" — a 20px margin that does not exist, against a row height
        // that is not the row's. The true margin is ZERO.
        //
        // AND THE GAP WAS REACHABLE. Regressing the exact remedy this assertion
        // certifies — `.set-matrix-corner` (app.css:2157) from `align-self:
        // stretch` to `align-self: center; height: 40px` — left the old probe
        // GREEN, printing "(40/35px)", while 7.5px of both 55px headings stood
        // uncovered top and bottom and scrolled through the pinned label
        // column. A 20px window (corner 35..55) in which this guard passed with
        // the pin broken. `headH` is now the MAX over every column.
        //
        // THE HIT-TEST HALF IS BARREN AND SAYS SO. `align-items: center` puts
        // every column's midpoint on the same y, so all six per-column probes
        // answer identically — converting one elementFromPoint into six finds
        // nothing, by construction, and the count is printed rather than
        // dressed up. What is NOT barren is the TALL column's TOP EDGE: at
        // `tall.top + 2` a centred 40px corner is simply not there, so that one
        // extra probe measures the uncovered band the height arithmetic only
        // implies.
        const mid = await evalJs(
          `(function(){var R=function(v){return Math.round(v*100)/100;};` +
          `var s=document.querySelector('.set-matrix');var ev=s.querySelector('.set-matrix-event');` +
          `var co=s.querySelector('.set-matrix-corner');var cr=co.getBoundingClientRect();` +
          `var cx=cr.left+cr.width/2;` +
          `var cols=[].slice.call(s.querySelectorAll('.set-matrix-col')).map(function(c){return c.getBoundingClientRect();});` +
          `var tall=cols.reduce(function(a,b){return b.height>a.height?b:a;},cols[0]);` +
          `var name=function(el){return el?String(el.className||el.tagName):'nothing';};` +
          `var probes=cols.map(function(h){return name(document.elementFromPoint(cx,h.top+h.height/2));});` +
          `return {sl:s.scrollLeft,evLeft:R(ev.getBoundingClientRect().left),` +
          ` cornerH:R(cr.height),headH:R(tall.height),col0H:R(cols[0].height),` +
          ` heights:cols.map(function(h){return R(h.height);}),` +
          ` probes:probes,probeMiss:probes.filter(function(p){return p.indexOf('set-matrix-corner')<0;}).length,` +
          ` edge:name(document.elementFromPoint(cx,tall.top+2))};})()`,
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
          else {
            // Three INDEPENDENT reads, not a chain: the height shortfall and
            // the top-edge hit-test are different measurements of the same
            // break, and an `else if` would print only the first — exactly the
            // reason the shipped ok-line went unexamined for so long.
            const before = failures.length;
            if (mid.cornerH < mid.headH - 0.5) fail(D, `notif-configured/${theme}@${width}: the sticky corner is ${mid.cornerH}px tall in a ${mid.headH}px header row (columns ${mid.heights.join("/")}; column 0 alone reads ${mid.col0H}px) — the channel headings scroll THROUGH the pinned label column at the top (align-items:center collapses an empty cell)`);
            if (mid.probeMiss) fail(D, `notif-configured/${theme}@${width}: at the header row ${mid.probeMiss}/${mid.probes.length} column midpoints are covered by something other than .set-matrix-corner (${mid.probes.join(", ")})`);
            if (!mid.edge.includes("set-matrix-corner")) fail(D, `notif-configured/${theme}@${width}: 2px below the top of the ${mid.headH}px header cell the label column is covered by "${mid.edge}", not .set-matrix-corner — a corner shorter than the TALLEST column leaves the heading scrolling through above it`);
            if (failures.length === before) okLine(`notif-configured/${theme}@${width}: ${rest.hidden}/${rest.cols} channel columns off-screen at rest; label column sticks at ${mid.evLeft} through scrollLeft ${mid.sl}, corner covers the header row (${mid.cornerH}/${mid.headH}px, columns ${mid.heights.join("/")}); ${mid.probes.length} column midpoints + the tall column's top edge all hit .set-matrix-corner; reserved scrollbar track ${rest.track}px`);
          }
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

    // ── W23-S2: THE ACCOUNT MODAL, which no leg in this file has ever seen ──
    //    `git grep -c am-name -- cloud/priv/static/__preview__` returned 0 on
    //    origin/main: every instrument in this epic measures a ROUTE, and the
    //    account modal has none — it is click-opened over whatever screen is
    //    live (mock.js's `?modal=account` is the seam, the same one shoot.sh
    //    derives from the `account-modal` name prefix).
    //
    //    WHAT IS BROKEN. `.am-name` (app.css:5631) renders `accountModel()`'s
    //    `name`, which is `email.split("@")[0]` (accountModel() — re-derive with
    //    `grep -n 'function accountModel' cloud/priv/static/app.js`) — the person's own
    //    email LOCAL PART, not a display name. The rule carried font-size,
    //    font-weight and line-height and nothing else, while its sibling
    //    `.am-line` (:5632) carries the full ellipsis triple. At the DERIVED cap
    //    of 158 characters (`validate_length(:email, max: 160)`,
    //    cloud/lib/barkpark_cloud/accounts/user.ex:165, minus "@" and one domain
    //    character — see the cruelAccountEmail ledger in scenarios.mjs, and note
    //    that the filed 255 is INADMISSIBLE because the server would reject it)
    //    pre-fix bytes measured `.am-name` scrollWidth 1276 against clientWidth
    //    172 @320 and 297 @1440 — the SAME 1276 at both, a CONTENT defect, not a
    //    responsive one, which is why 1440 is in the width list. (The slice brief
    //    and the backlog row quote 1362/1461/~1141: same 158-char cap, a
    //    DIFFERENT stem. These numbers are THIS fixture's, re-driven on this
    //    tree by stripping the remedy — 1276 at every width, `.modal-root`
    //    1374@320 rising to 1811@1440. The px are stem-conditional; the ordinal
    //    fact — a name outside its own box and a modal scrolling sideways — is
    //    not. Reviewer re-derivation, cch-w23 review.)
    //
    //    WHY NO EXISTING LEG COULD HAVE SEEN IT, TWICE OVER:
    //      · THE PAGE NEVER SCROLLS. `documentElement.scrollWidth ==
    //        clientWidth` in every cell (320/320 …): the overflow is confined to
    //        `.modal-root` (app.css:1114 — `overflow-y: auto` makes overflow-x
    //        compute `auto`, and it declares no x control), which scrolls
    //        sideways — measured 1054px at 320 on this fixture, 371px at 1440.
    //        Every page-level leg above reads clean.
    //      · RECT-BLINDNESS. `getBoundingClientRect().width` on `.am-name` reads
    //        172 at 320 while `scrollWidth` reads 1276 — the box is inside its
    //        container and the glyphs are not. A rect-against-container scan
    //        returns ZERO on this defect, so this leg reads scrollWidth against
    //        clientWidth ON THE ELEMENT.
    //
    //    THE FIFTH CLAUSE (D228): every host is `querySelectorAll` and every
    //    population is COUNTED, PRINTED, and REFUSED at zero. There is exactly
    //    one `.am-name` in an open account modal today — but "one" is a fact
    //    about the current markup, not a licence to write `querySelector`: the
    //    singular form cannot tell a modal that renders nothing from a modal
    //    that renders a clean name, and that is precisely the green-by-
    //    construction this wave exists to remove. A cell that measures zero
    //    `.am-name`, zero `.modal-root`, or a `.modal-root` that never opened is
    //    a NAMED FAILURE here, never a pass.
    //
    //    ANTI-VACUITY, SECOND ORDER (the `withBtns === 0` shape from the members
    //    leg at :1878): a cruel cell whose name is not actually cruel proves
    //    nothing, so the cruel scenario asserts its rendered name is AT the
    //    derived cap, and the kind scenario asserts its own is short. A fixture
    //    that goes kind reds this leg instead of greening it.
    //
    //    THE KIND CONTROL IS DRIVEN IN THE SAME CELLS: `account-modal` still
    //    ships `ada@acme.com` (three glyphs). A remedy that bought the cruel
    //    name by shredding an ordinary one reds on it.
    if (requested.includes("W23-account-modal-identity-bounded")) {
      const D = "W23-account-modal-identity-bounded";
      // BLOCK-SCOPED (D247): these axes belong to this leg alone.
      //   account-modal-revoke = the CRUEL twin (158-char local part)
      //   account-modal        = the KIND control (ada@acme.com)
      const AM_SCENS = [
        { scen: "account-modal-revoke", cruel: true },
        { scen: "account-modal", cruel: false },
      ];
      // The phone band, the fold, and 1440. The defect is width-independent, so
      // a list that stopped at 620 would understate it as a mobile problem.
      const AM_WIDTHS = [320, 360, 390, 430, 620, 900, 1440];
      // The derived cap, restated here so the leg refuses a fixture that drifted
      // BELOW it rather than measuring whatever it is handed.
      const AM_NAME_CAP = 158;
      // ANTI-VACUITY 0 — the axis itself.
      for (const need of [320, 1440]) {
        if (!AM_WIDTHS.includes(need)) {
          fail(D, `axis check: ${need} is not in the width set — this defect measures the same 1276px at 320 and at 1440, and a set missing either end cannot show that it is a CONTENT defect rather than a responsive one`);
        }
      }
      if (!AM_SCENS.some((s) => s.cruel) || !AM_SCENS.some((s) => !s.cruel)) {
        fail(D, "axis check: the scenario set needs BOTH the cruel twin and a kind control — cruel alone cannot see a remedy that shreds ordinary names, kind alone cannot see the defect");
      }
      const cellCount = AM_SCENS.length * AM_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${AM_SCENS.length} account scenarios x ${AM_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; every .am-name and every .modal-root iterated: scrollWidth vs clientWidth` +
        ` on the ELEMENT, + the page as a tripwire)\n`,
      );
      let cells = 0, namesSeen = 0, rootsSeen = 0, nameOver = 0, rootOver = 0, pageOver = 0;
      for (const s of AM_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter wide, and wait for the REAL modal: mock.js opens it only after
          // /v1/me has painted the account chip, so there is no load event to
          // key on. The predicate waits for the modal to be OPEN and NOTHING
          // MORE — deliberately. Waiting on `.am-name` here would put the very
          // population this leg counts inside its own readiness gate, and a DOM
          // that stopped emitting the identity would time out as exit 2 (an
          // ENVIRONMENT verdict) instead of reaching the zero-population refusal
          // below at exit 1. A guard must not gate on the thing it measures.
          await setViewport(900);
          await nav(
            `${BASE}/?scen=${s.scen}&theme=${theme}&modal=account`,
            `(function(){var r=document.getElementById('modal-root');` +
            `return !!(r && !r.hidden && r.querySelector('.modal-card'));})()`,
          );
          const row = [];
          for (const width of AM_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;` +
              `var r=document.getElementById('modal-root');` +
              // ITERATED, NEVER SAMPLED (D228) — both hosts. `.modal-root` is a
              // single id today; asking for it as a POPULATION is what makes a
              // second modal root (or none) reportable instead of invisible.
              `var names=[].slice.call(document.querySelectorAll('.am-name')).map(function(n){` +
              `  var cs=getComputedStyle(n);` +
              `  return {sw:n.scrollWidth,cw:n.clientWidth,ow:cs.overflowWrap,ws:cs.whiteSpace,te:cs.textOverflow,` +
              `    len:(n.textContent||'').trim().length,t:(n.textContent||'').trim().slice(0,24)};});` +
              `var roots=[].slice.call(document.querySelectorAll('.modal-root')).map(function(x){` +
              `  return {sw:x.scrollWidth,cw:x.clientWidth,hidden:!!x.hidden};});` +
              `return {psw:d.scrollWidth,pcw:d.clientWidth,theme:d.getAttribute('data-theme'),` +
              ` open:!!(r && !r.hidden && r.querySelector('.modal-card')), names:names, roots:roots};})()`,
            );
            cells++;
            if (m.theme !== theme) fail(D, `${s.scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: a closed modal is not a clean modal.
            if (!m.open) {
              fail(D, `${s.scen}/${theme}@${width}: the account modal is not open (#modal-root hidden or carrying no .modal-card) — nothing below this line measures the account modal, and a leg that scored this cell clean would be certifying an empty screen`);
              row.push(`${width}:closed`);
              continue;
            }
            // AUDITED: zero identities is not a clean identity.
            if (m.names.length === 0) {
              fail(D, `${s.scen}/${theme}@${width}: zero \`.am-name\` rendered inside an OPEN account modal — the person's identity is absent, and "nothing overflowed" is true of nothing. This is not a pass`);
              row.push(`${width}:0n`);
              continue;
            }
            if (m.roots.length === 0) {
              fail(D, `${s.scen}/${theme}@${width}: zero \`.modal-root\` matched while the modal reports open — the container this defect's sideways scroll actually lives in was never measured`);
              row.push(`${width}:0r`);
              continue;
            }
            namesSeen += m.names.length;
            rootsSeen += m.roots.length;
            // SECOND ORDER: a cruel cell whose name is not cruel is a fixture
            // that went kind, and it would green this leg against a live defect.
            const longest = Math.max(...m.names.map((n) => n.len));
            if (s.cruel && longest < AM_NAME_CAP) {
              fail(D, `${s.scen}/${theme}@${width}: the longest \`.am-name\` is ${longest} characters, below the derived cap of ${AM_NAME_CAP} (email max 160 at cloud/lib/barkpark_cloud/accounts/user.ex:165, minus "@" and one domain char) — the cruel fixture has GONE KIND, so every clean line below it means nothing`);
            }
            if (!s.cruel && longest > 40) {
              fail(D, `${s.scen}/${theme}@${width}: the kind control's \`.am-name\` is ${longest} characters — this scenario exists to prove an ordinary name survives the remedy, and it is no longer ordinary`);
            }
            for (const n of m.names) {
              if (n.sw > n.cw) {
                nameOver++;
                fail(D, `${s.scen}/${theme}@${width} \`.am-name\` "${n.t}…": scrollWidth ${n.sw} > clientWidth ${n.cw} — ${Math.round((1 - n.cw / n.sw) * 100)}% of the name of the person who is signed in renders outside its own box (computed overflow-wrap "${n.ow}", white-space "${n.ws}", text-overflow "${n.te}"). This is an email LOCAL PART, so it is the person's own address, and getBoundingClientRect() reads it as fitting`);
              }
            }
            for (const x of m.roots) {
              if (x.sw > x.cw) {
                rootOver++;
                fail(D, `${s.scen}/${theme}@${width} \`.modal-root\`: scrollWidth ${x.sw} > clientWidth ${x.cw} — the MODAL scrolls sideways by ${x.sw - x.cw}px (app.css:1114 declares overflow-y:auto, which computes overflow-x:auto, with no x control of its own). The page does not scroll, which is why every page-level leg in this file reads clean here`);
              }
            }
            // THE PAGE IS A TRIPWIRE, NOT THE DEFECT: it measures 320/320 both
            // before and after the fix. It is asserted so that a remedy which
            // moves the overflow OUT of the modal and onto the document cannot
            // pass as a fix.
            if (m.psw > m.pcw) {
              pageOver++;
              fail(D, `${s.scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — the remedy pushed the overflow out of the modal and onto the page, which is a different defect, not a fix`);
            }
            const nm = m.names.map((n) => `${n.cw}/${n.sw}@${n.len}c`).join(",");
            const rt = m.roots.map((x) => `${x.cw}/${x.sw}`).join(",");
            row.push(
              `${width}:${m.names.length}n[${nm}] root[${rt}] psw${m.psw}` +
              (m.names.some((n) => n.sw > n.cw) ? `!name` : ``) +
              (m.roots.some((x) => x.sw > x.cw) ? `!root` : ``),
            );
          }
          process.stdout.write(`   ${s.scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean — ${namesSeen} \`.am-name\` and ${rootsSeen} \`.modal-root\` ITERATED ` +
          `(querySelectorAll on both, counted per cell, zero refused by name) across ${AM_WIDTHS.join("/")} ` +
          `x light+dark on ${AM_SCENS.map((s) => s.scen + (s.cruel ? " (cruel)" : " (kind)")).join(" + ")}: ` +
          `${nameOver} identities outside their own box, ${rootOver} modals scrolling sideways, ${pageOver} pages ` +
          `scrolling sideways. The cruel cells are asserted to still BE cruel (a rendered name at the derived ` +
          `${AM_NAME_CAP}-char cap) and the kind cells to still be ordinary, so a fixture that drifts reds this leg ` +
          `rather than greening it`,
        );
        okLine(
          `FONT PINNED (D218, paid by cch-w22-s1): nav() load()s every declared @font-face, awaits ` +
          `document.fonts.ready and check()s each face before these px are read — a missing face is exit 2. ` +
          `\`.am-name\` inherits the UI face, not the mono fallback D248 named, and what is ASSERTED here is ` +
          `face-independent anyway: glyphs inside their own box, and a modal that does not scroll sideways`,
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
      let cells = 0, clipped = 0, ellipsed = 0, squeezed = 0, pageOver = 0, rowsSeen = 0, overflowed = 0, foreignRows = 0;
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
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,rows:0,docRows:document.querySelectorAll('.fleet-row').length,clips:[],ell:[],sq:[],tall:[]};` +
              // cch-w24-s5 — THE WALK IS SCOPED TO THE VIEW IT JUST COMPUTED.
              // It used to compute `v` and then iterate `document.querySelectorAll`,
              // using the scope only to LABEL the output. `.fleet-row` is a
              // four-anatomy class: `#view-overview` paints its own activity rows
              // under the same class, carrying no `.fleet-url`, no `.status-pill`
              // and no `.fleet-badges`, so every sub-read below is swallowed by
              // `if(!e) return` and the rows are counted having been measured for
              // nothing. Driven on `mixed-fleet`, a hash-nav `#overview` -> `#fleet`
              // — what a PERSON clicks — leaves 8 rows document-wide against 5 in
              // view, `document.querySelector('.fleet-row')` resolving into the
              // HIDDEN `#view-overview`, and per-row `.status-pill` counts
              // [0,0,0,1,1,1,1,1]. The leg survived only because `nav()` always
              // changes the query string and reloads, which is a property of the
              // harness, not of the leg.
              `[].slice.call(v?v.querySelectorAll('.fleet-row'):[]).forEach(function(r,i){out.rows++;` +
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
            if (m.rows === 0) fail(D, `${scen}/${theme}@${width}: zero .fleet-row rendered IN THE VISIBLE VIEW — nothing was measured, this is not a pass`);
            rowsSeen += m.rows;
            // cch-w24-s5 — the rows the walk REFUSED, counted and named rather
            // than silently dropped: a scope that cannot report what it excluded
            // is indistinguishable from a scope that excluded nothing.
            foreignRows += m.docRows - m.rows;
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
          `${cells} / ${cells} cells clean (${rowsSeen} fleet rows measured IN THE VISIBLE VIEW, ` +
          `${foreignRows} .fleet-row(s) elsewhere in the document refused, ${knownSeen.size} known-row cells itemised: ${FLEET_KNOWN.map((k) => k.row).join(", ") || "none"}) across ` +
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

    // ── W23-S6: THE FIX-IT INSTRUCTION, AND WHERE THE VIEWPORT LANDS ────────
    //    Every leg above measures a box that is ALREADY on screen: it asks
    //    whether text fits inside its own element, or whether the page scrolls
    //    sideways. Not one of them asks the vertical question — is the thing
    //    the SPA just revealed anywhere a person can see it. So a credential
    //    failure at 390x390 could put the server's entire fix-it instruction
    //    off the top of the phone and every cell in this file stayed green:
    //    the box is not clipped, its text is whole, the page does not scroll
    //    sideways, and the person still cannot read the sentence that tells
    //    them what to do next.
    //
    //    THE DEFECT, driven at 390x390 on `providers-empty#settings/providers`
    //    with the real Azure copy: box h=154, top=-21, bottom=132 against a
    //    390px viewport — the FIRST LINE 21px above the top edge, with no cue
    //    that anything is above. The gesture that produces it is the natural
    //    one: reveal the copy, then scroll the BUTTON the person just pressed
    //    into view — and the copy renders ABOVE that button.
    //
    //    THE FIXTURE IS THE FIRST HALF OF THIS LEG (wave-23 clause 4). The
    //    shipped `providers-unverified` copy is a 168-character PARAPHRASE and
    //    it measures CLEAN at every geometry here: on that string the defect
    //    cannot be produced, so a leg driving it would be green by
    //    construction with a perfectly real browser. `providers-empty` — the
    //    scenario the defect was reproduced on — therefore now carries
    //    `connect_remediation("azure")` VERBATIM, 275 characters, the longest
    //    clause the server can send (cloud/lib/barkpark_cloud/failure_copy.ex
    //    :361-375, whose four clauses measure 169/275/206/88). The length is
    //    ASSERTED per cell against that number — a corpus that understates the
    //    server is a corpus that certifies nothing — and the paraphrase is
    //    kept as the labelled SHORT control so a regression on ordinary copy
    //    is still visible.
    //
    //    D228, AND IT BITES TWICE HERE. `#cred-remediation` is rendered by TWO
    //    hosts — the providers page's connect card and the credential modal —
    //    and `#modal-root` sits AFTER `#view-providers` in index.html, so
    //    `document.querySelector('#cred-remediation')` is the PAGE's box
    //    whether or not a dialog is open. Every `#cred-remediation` and every
    //    `#cred-submit` in the document is walked, the counts are printed, and
    //    a cell that finds zero boxes — or zero REVEALED boxes — FAILS: an
    //    instruction that never appeared is not an instruction on screen.
    //
    //    THREE ASSERTIONS PER REVEALED BOX, and the third is the one a
    //    top >= 0 check alone cannot make:
    //      (a) top >= 0            — the first line is not above the viewport.
    //      (b) top <= viewportH - one line — it is not below the fold either;
    //          the same "no gesture at all" bug pushes the box off the BOTTOM
    //          when the button sat low, which scores a perfect (a).
    //      (c) the first line is not COVERED. `.topbar` is `position: sticky;
    //          top: 0` (56px, app.css:794), so a fix that aligns the box to
    //          the scrollport's start edge lands it at top 0 UNDER the bar and
    //          passes (a) and (b) while the person reads nothing.
    //          `elementFromPoint` over the first line is what sees that.
    //    Plus the button: `#cred-submit` must still intersect the viewport, so
    //    a gesture that buys the instruction by scrolling the control away is
    //    a red here and not a trade.
    if (requested.includes("W23-cred-remediation-reachable")) {
      const D = "W23-cred-remediation-reachable";
      // BLOCK-SCOPED (D247): these axes belong to this leg alone.
      // Two kinds because they are the only two `available: true` providers in
      // app.js's PROVIDERS list and they render DIFFERENT credential forms
      // (four fields vs one token); two scenarios because a fixture carries ONE
      // `providerConnect` response and `route()` never sees the request body,
      // so the string is a property of the SCENARIO, not of the kind.
      //   · `providers-empty` — the scenario the defect was reproduced on —
      //     now carries `connect_remediation("azure")` VERBATIM: 275 chars, the
      //     longest the server can send.
      //   · `providers-unverified` keeps its 168-character PARAPHRASE and is
      //     driven here as the SHORT control, labelled as such. It is one
      //     character under the real hetzner clause (169), so it does not
      //     materially understate it — but it is NOT the server's string, and
      //     that is written down rather than papered over:
      //     cch-w23-bl-real-hetzner-remediation-scenario owns
      //     giving the real 169 its own key (a new `SCENARIOS` key is refused
      //     by breakpoint-sweep.mjs's census, which this slice is fenced out
      //     of). A leg that only ever drove the worst string could not tell
      //     you the shorter one regressed, which is why the short cell is here
      //     at all.
      const CRED_CELLS = [
        { scen: "providers-empty", kind: "azure", chars: 275, src: "connect_remediation(\"azure\"), verbatim" },
        { scen: "providers-unverified", kind: "hetzner", chars: 168, src: "the 168-char paraphrase, driven as the SHORT control" },
      ];
      // [width, height]. HEIGHT IS THE VARIABLE HERE, which is why this leg
      // cannot use the file's width sets: 390x390 is the filed reproduction,
      // 390x844 is the same phone in portrait (a taller viewport that must not
      // be bought at its expense), and 320x568 is the smallest phone still
      // shipped — the geometry where the box is tallest and the fold lowest.
      const CRED_VIEWPORTS = [[390, 390], [390, 844], [320, 568]];
      // ANTI-VACUITY 0 — the axes themselves, so a later edit cannot quietly
      // drop the geometry the defect was measured at.
      if (!CRED_VIEWPORTS.some(([w, h]) => w === 390 && h === 390)) {
        fail(D, `axis check: 390x390 is not in the viewport set — it is the geometry the defect was reproduced at (top -21), and without it this leg cannot see it`);
      }
      if (!CRED_CELLS.some((c) => c.kind === "azure" && c.chars === 275)) {
        fail(D, `axis check: the 275-character azure clause is not in the cell set — it is the longest string \`connect_remediation/1\` can send, and the only one the shipped 168-character fixture understates`);
      }
      if (!CRED_CELLS.some((c) => c.chars < 200)) {
        fail(D, `axis check: no SHORT string is in the cell set — a leg that only ever drives the worst copy cannot tell you a shorter one regressed, which is the failure this file keeps finding in its own instruments`);
      }
      const credCellCount = CRED_CELLS.length * CRED_VIEWPORTS.length * 2;
      process.stdout.write(
        `\n${D} — ${CRED_CELLS.length} provider kinds x ${CRED_VIEWPORTS.length} phone geometries x 2 themes` +
        ` (${credCellCount} cells; the REAL verify-before-save gesture chain, then every #cred-remediation` +
        ` and every #cred-submit in the document measured against the viewport)\n`,
      );
      let cells = 0, boxesSeen = 0, revealedSeen = 0, submitsSeen = 0;
      let above = 0, below = 0, covered = 0, buttonGone = 0, shortCopy = 0;
      for (const cell of CRED_CELLS) {
        for (const theme of ["light", "dark"]) {
          const row = [];
          for (const [width, height] of CRED_VIEWPORTS) {
            // EVERY CELL IS NAVIGATED FRESH. The verifier's dark iteration
            // inherited the light run's DOM and its numbers were not
            // independent; a gesture leg is worse than a geometry leg in that
            // respect, because the box it measures is a state the previous
            // cell already produced. Viewport first, then a full navigation,
            // then the gesture — nothing here re-uses a rendered box.
            await setViewport(width, height);
            await nav(
              `${BASE}/?scen=${cell.scen}&theme=${theme}#settings/providers`,
              `(function(){var v=document.querySelector('section.view:not([hidden])');` +
              `return v && v.id==='view-providers' && document.querySelector('#provider-connect [data-connect-submit]');})()`,
            );
            // THE REAL GESTURE CHAIN: arm the kind, fill the form the way a
            // person does, press the button. Nothing is injected — the copy
            // arrives through the mock's 422 and app.js's own paint path.
            const armed = await evalJs(
              `(function(){` +
              `var seg=[].slice.call(document.querySelectorAll('#provider-connect [data-connect-kind="${cell.kind}"]'));` +
              `if(!seg.length) return {ok:false,why:'no [data-connect-kind="${cell.kind}"] segment in the connect card'};` +
              `seg[0].click();` +
              `var t=document.getElementById('cred-token'); if(t) t.value='guard-probe-token';` +
              `['tenant_id','client_id','client_secret','subscription_id'].forEach(function(k){` +
              `  var e=document.getElementById('cred-az-'+k); if(e) e.value='00000000-0000-4000-8000-000000000001';});` +
              `var sub=[].slice.call(document.querySelectorAll('#provider-connect [data-connect-submit]'));` +
              `if(!sub.length) return {ok:false,why:'no [data-connect-submit] in the connect card'};` +
              `sub[0].click();` +
              `return {ok:true};})()`,
            );
            cells++;
            if (!armed.ok) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: the gesture chain never started — ${armed.why}. Nothing below this line was measured, and an unreached screen is not a clean screen`);
              row.push(`${width}x${height}:!chain`);
              continue;
            }
            let revealed = false;
            for (let w = 0; w < RENDER_CAP; w += 100) {
              revealed = await evalJs(
                `[].slice.call(document.querySelectorAll('#cred-remediation'))` +
                `.some(function(b){return !b.hidden && (b.textContent||'').trim().length>0;})`,
              );
              if (revealed) break;
              await sleep(100);
            }
            if (!revealed) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: the verify-before-save chain never revealed a remediation box (422 provider_unverified -> showCredRemediation) — nothing below was measured`);
              row.push(`${width}x${height}:!reveal`);
              continue;
            }
            const m = await evalJs(
              `(function(){` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var d=document.documentElement;` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),vw:d.clientWidth,vh:d.clientHeight,` +
              `  boxes:0,shown:[],submits:0,btns:[]};` +
              // EVERY #cred-remediation in the document, never a singular query
              // (D228) — the id has TWO hosts and index.html orders the page's
              // before the dialog's.
              `[].slice.call(document.querySelectorAll('#cred-remediation')).forEach(function(b,i){` +
              `  out.boxes++;` +
              `  var txt=(b.textContent||'').trim(); if(b.hidden||!txt.length) return;` +
              `  var r=b.getBoundingClientRect();` +
              `  var body=b.querySelector('.cred-remediation-body');` +
              // The COPY's length, not the box's: the box also carries the "!"
              // icon glyph, and a count that included it would score a
              // 274-character string as satisfying a 275-character source.
              `  var copy=((body?body.textContent:txt)||'').trim();` +
              `  var cs=getComputedStyle(body||b);` +
              `  var line=parseFloat(cs.lineHeight)||parseFloat(cs.fontSize)*1.45||18;` +
              // (c) IS THE FIRST LINE ACTUALLY VISIBLE — the sticky topbar
              // covers the scrollport's own start edge, so a box at top 0 can
              // be perfectly "in the viewport" and still unreadable. Probed at
              // the first line's vertical middle, at the body's left inset.
              `  var br=(body||b).getBoundingClientRect();` +
              `  var px=Math.min(Math.max(br.left+4,1),d.clientWidth-1);` +
              `  var py=r.top+Math.min(line,r.height)/2;` +
              `  var hit=(py>=0&&py<=d.clientHeight-1)?document.elementFromPoint(px,py):null;` +
              `  out.shown.push({i:i,top:+r.top.toFixed(2),bottom:+r.bottom.toFixed(2),h:+r.height.toFixed(2),` +
              `    line:+line.toFixed(2),len:copy.length,` +
              `    hit:hit?(hit.className||hit.tagName):'none',` +
              `    covered:!!(hit && !b.contains(hit))});` +
              `});` +
              // The button, on the SAME cell and by the same rule: a fix that
              // wins the instruction by scrolling the control off is not a fix.
              `[].slice.call(document.querySelectorAll('#cred-submit')).forEach(function(s,i){` +
              `  out.submits++;` +
              `  var sr=s.getBoundingClientRect();` +
              `  out.btns.push({i:i,top:+sr.top.toFixed(2),bottom:+sr.bottom.toFixed(2),` +
              `    vis:(sr.height>0&&sr.bottom>0&&sr.top<d.clientHeight)});` +
              `});` +
              `return out;})()`,
            );
            if (m.view !== "view-providers") {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: rendered section.view "${m.view}", asked for "view-providers" — the hash did not route, so nothing below this line measures the credential flow`);
              row.push(`${width}x${height}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${cell.scen}/${theme}@${width}x${height}: data-theme is "${m.theme}" — the theme did not apply`);
            // THE ZERO-POPULATION REFUSALS. Both are named, and both are
            // per-cell: a screen that renders no box, or renders one and never
            // reveals it, has measured NOTHING and must not score a green.
            if (m.boxes === 0) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: zero \`#cred-remediation\` in the document — the credential form did not render its remediation slot at all, so nothing about the instruction was measured. This is not a pass`);
              row.push(`${width}x${height}:0b`);
              continue;
            }
            boxesSeen += m.boxes;
            if (m.shown.length === 0) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: ${m.boxes} \`#cred-remediation\` present and NOT ONE is revealed with text — "the instruction is on screen" would be true of an empty box, which is not what this leg claims`);
              row.push(`${width}x${height}:${m.boxes}b/0shown`);
              continue;
            }
            revealedSeen += m.shown.length;
            submitsSeen += m.submits;
            if (m.submits === 0) {
              buttonGone++;
              fail(D, `${cell.scen}/${theme}@${width}x${height}: zero \`#cred-submit\` in the document — the control the person needs to retry does not exist on the screen the instruction was painted onto`);
            }
            for (const s of m.btns) {
              if (!s.vis) {
                buttonGone++;
                fail(D, `${cell.scen}/${theme}@${width}x${height} submit${s.i}: \`#cred-submit\` sits at top ${s.top} / bottom ${s.bottom} against a ${m.vh}px viewport — the button the person must press again is OFF-SCREEN. The instruction may not be bought with the control`);
              }
            }
            for (const b of m.shown) {
              // The corpus may never understate the server.
              if (b.len < cell.chars) {
                shortCopy++;
                fail(D, `${cell.scen}/${theme}@${width}x${height} box${b.i}: the remediation renders ${b.len} characters, but \`connect_remediation("${cell.kind}")\` sends ${cell.chars} (failure_copy.ex) — the fixture understates the string this screen must place`);
              }
              if (b.top < 0) {
                above++;
                fail(D, `${cell.scen}/${theme}@${width}x${height} box${b.i}: the remediation's top edge is ${b.top} — the FIRST LINE of a ${b.len}-character instruction is ${Math.abs(b.top).toFixed(2)}px ABOVE the viewport top (box h=${b.h}, bottom=${b.bottom}, viewportH=${m.vh}). The person reads the middle of a sentence whose beginning is off-screen, with no cue that anything is above`);
              } else if (b.top > m.vh - b.line) {
                below++;
                fail(D, `${cell.scen}/${theme}@${width}x${height} box${b.i}: the remediation's top edge is ${b.top} against a ${m.vh}px viewport — the whole instruction is BELOW the fold (box h=${b.h}). Revealing copy the viewport never travels to is the same defect with the sign flipped`);
              } else if (b.covered) {
                covered++;
                fail(D, `${cell.scen}/${theme}@${width}x${height} box${b.i}: the first line sits at top ${b.top} and \`elementFromPoint\` over it returns "${b.hit}" — something (the sticky .topbar, app.css:794) is PAINTED ON TOP of the instruction. top >= 0 is not the same as readable`);
              }
            }
            const tops = m.shown.map((b) => `${b.top}+${b.h}`).join(",");
            const btns = m.btns.map((b) => `${b.top}${b.vis ? "" : "!off"}`).join(",");
            row.push(
              `${width}x${height}:${m.boxes}b/${m.shown.length}shown ` +
              `${m.shown.map((b) => b.len).join(",")}ch top[${tops}]<=${m.vh} ` +
              `${m.submits}s btn[${btns}]`,
            );
          }
          process.stdout.write(`   ${cell.scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean — ${boxesSeen} \`#cred-remediation\` walked in total, ` +
          `${revealedSeen} of them REVEALED through the real verify-before-save chain (arm the kind -> fill ` +
          `the form -> press the button -> 422 provider_unverified), and ${submitsSeen} \`#cred-submit\` ` +
          `measured beside them, across ${CRED_VIEWPORTS.map(([w, h]) => `${w}x${h}`).join("/")} x light+dark ` +
          `on ${CRED_CELLS.map((c) => `${c.kind}(${c.chars}ch)`).join(" + ")}: ${above} instructions starting ` +
          `above the viewport, ${below} below the fold, ${covered} painted under the sticky topbar, ` +
          `${buttonGone} unreachable submit buttons, ${shortCopy} cells whose copy understated the server. ` +
          `EVERY box and EVERY button in the document is walked (D228) — the id \`#cred-remediation\` has two ` +
          `hosts and index.html orders the page's before the dialog's, so a singular query is structurally ` +
          `unable to see one of them. A cell with zero boxes, or zero revealed boxes, FAILS`,
        );
        okLine(
          `THE STRINGS, ASSERTED PER CELL AND ATTRIBUTED: ` +
          `${CRED_CELLS.map((c) => `${c.scen} ${c.kind} >= ${c.chars}ch (${c.src})`).join("; ")}. ` +
          `The azure number is re-derived from cloud/lib/barkpark_cloud/failure_copy.ex:361-375, whose four ` +
          `clauses measure 169/275/206/88 — NOT the 89 the filed row cites, and NOT at the \`registry/\` path it ` +
          `cites, which does not exist. The 168-character paraphrase measures CLEAN at every geometry here: ` +
          `driving it ALONE is green by construction (wave-23 clause 4), which is why it is the short control ` +
          `and never the only cell. No length bound was added anywhere — the copy is the product, and the ` +
          `remedy is where the viewport lands`,
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

    // ── W21: the instance workspace HEAD at 320, and whether the address Copy
    //    control is reachable at rest ────────────────────────────────────────
    //    THE HOLE THIS FILLS. W13 drives the detail routes but its envelope
    //    starts at 721; W12 drives 320-620 but only `#overview` and
    //    `#notifications`. So the intersection — a DETAIL route at PHONE width
    //    — had never been driven by any leg in this file, and on origin/main
    //    bytes `#instance/<id>` scrolled the page 22px sideways at 320 on the
    //    SHIPPED `mixed-fleet` fixture with no cruel content at all, putting
    //    `.copy-btn`'s right edge at 342 against a 320 viewport: the one
    //    control that hands a person their instance address, off-screen at
    //    rest, on a route `applyRoute` dispatches to every signed-in reader.
    //
    //    THE BAND IS 320-ONLY AND THAT IS WHY THE WIDTH SET RUNS PAST IT.
    //    360/375/390/430/620 all read `docsw == vp` before AND after the
    //    remedy; they are here as the no-regression control, because the
    //    cheapest "fix" for 320 is a width cap that quietly narrows every
    //    phone above it.
    //
    //    THE CONTAINED-SCROLL FALSE POSITIVE IS EXCLUDED BY CONSTRUCTION, NOT
    //    BY ALLOWLIST. At 360-390 `a.inst-tab` ("Metrics") has a right edge of
    //    342-407, past the viewport — but it lives in `.inst-tabs`, which
    //    computes `overflow-x: auto` (scrollWidth 391 vs clientWidth 288 at
    //    320): a CONTAINED strip that scrolls itself and never moves
    //    `documentElement.scrollWidth`. This leg asserts the PAGE and the COPY
    //    CONTROLS, so that element cannot red here; and the containment is
    //    asserted POSITIVELY per cell (an overflowing strip that ever computed
    //    `overflow-x: visible` would become a page defect, and reds) rather
    //    than suppressed by naming the selector.
    //
    //    EVERY COPY CONTROL, NOT THE FIRST. `panel-overview` renders SEVEN
    //    `.copy-btn` (the bp-CLI chips) against `mixed-fleet`'s three; a
    //    `querySelector` here would inspect the head's button on one fixture
    //    and a CLI chip on the other. The worst right edge over ALL of them is
    //    what a person meets, and zero measured controls FAILS — an empty list
    //    is not a clean list (the GR109 singular-selector lesson, W20-S6).
    if (requested.includes("W21-inst-head-320-copy-reachable")) {
      const D = "W21-inst-head-320-copy-reachable";
      // BLOCK-SCOPED on the `const D` precedent above: these axes belong to
      // this leg alone and must never read as shared file constants (D247).
      const HEAD_SCENS = ["mixed-fleet", "panel-overview"];
      const HEAD_WIDTHS = [320, 360, 375, 390, 430, 620, 769];
      // ANTI-VACUITY 0 — the axis itself. The defect band is 320-ONLY, so an
      // edit that drops 320 leaves a leg that passes having never visited the
      // one width where the page scrolls. It reds here instead of going quiet.
      if (!HEAD_WIDTHS.includes(320)) {
        fail(D, `axis check: 320 is not in the width set — the band is 320-ONLY (360-620 read \`docsw == vp\` on pre-fix bytes), so without it this leg cannot see the defect at all`);
      }
      const cellCount = HEAD_SCENS.length * HEAD_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${HEAD_SCENS.length} scenarios x ${HEAD_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; #instance/<id> page overflow + EVERY .copy-btn's right edge)\n`,
      );
      let cells = 0, copiesSeen = 0, offscreen = 0, pageOver = 0;
      for (const scen of HEAD_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter at 900 — ABOVE the band — and pin the hash: `?scen=` alone
          // renders #overview (the W13 routing trap), and an overview screen
          // measured under an instance-route heading is a phantom table.
          await setViewport(900);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#instance/${INST}`,
            `document.querySelector('.detail-head-main') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-instance';})()`,
          );
          const row = [];
          for (const width of HEAD_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var d=document.documentElement;` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,` +
              `  copies:0,urlCopies:0,worst:0,bad:[],strips:[]};` +
              `[].slice.call(document.querySelectorAll('.copy-btn')).forEach(function(b,i){` +
              `  var r=b.getBoundingClientRect(); out.copies++;` +
              `  if(b.closest('.detail-url')) out.urlCopies++;` +
              `  if(r.right>out.worst) out.worst=+r.right.toFixed(2);` +
              `  if(r.right>d.clientWidth+0.5) out.bad.push({i:i,right:+r.right.toFixed(2),` +
              `    inUrl:!!b.closest('.detail-url'),lbl:(b.getAttribute('aria-label')||b.title||'copy').slice(0,32)});` +
              `});` +
              // The containment claim, measured rather than assumed: any strip
              // wider than its own box must own a non-visible overflow-x.
              `[].slice.call(document.querySelectorAll('.inst-tabs')).forEach(function(s){` +
              `  if(s.scrollWidth>s.clientWidth) out.strips.push({ox:getComputedStyle(s).overflowX,sw:s.scrollWidth,cw:s.clientWidth});` +
              `});` +
              `return out;})()`,
            );
            cells++;
            if (m.view !== "view-instance") {
              fail(D, `${scen}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-instance" — the hash did not route, so nothing below this line measures the instance workspace`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: an empty list is not a clean list. If the head stops
            // rendering its address control this leg would score zero
            // off-screen buttons and read as a pass.
            if (m.copies === 0 || m.urlCopies === 0) {
              fail(D, `${scen}/${theme}@${width}: ${m.copies} \`.copy-btn\` and ${m.urlCopies} inside \`.detail-url\` — the address copy control is not in the DOM, so nothing was measured. This is not a pass.`);
              row.push(`${width}:0c`);
              continue;
            }
            copiesSeen += m.copies;
            // (1) THE PAGE. Strict equality: a viewport-sized page is the whole
            // claim, and `>=` would tolerate the 22px this leg exists for.
            if (m.psw !== m.pcw) {
              pageOver++;
              fail(D, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} != clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the instance workspace is off-screen sideways at rest, with no cue`);
            }
            // (2) THE CONTROL. Every copy button, not the first.
            for (const b of m.bad) {
              offscreen++;
              fail(D, `${scen}/${theme}@${width} .copy-btn[${b.i}]${b.inUrl ? " (the ADDRESS control)" : ""}: right edge ${b.right} is outside the ${m.pcw}px viewport — a person cannot reach "${b.lbl}" without scrolling the page sideways`);
            }
            // (3) THE CONTAINMENT, asserted rather than allowlisted.
            for (const s of m.strips) {
              if (s.ox === "visible") {
                fail(D, `${scen}/${theme}@${width} .inst-tabs: scrollWidth ${s.sw} > clientWidth ${s.cw} with computed overflow-x:visible — the tab strip stopped containing its own scroll, so its tabs now push the PAGE instead of scrolling inside it`);
              }
            }
            row.push(`${width}:${m.psw}${m.psw !== m.pcw ? "!" : ""}/c${m.copies}@${m.worst}${m.bad.length ? " !" + m.bad.length : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${copiesSeen} .copy-btn measured, ${offscreen} outside the viewport, ` +
          `${pageOver} pages scrolling sideways) across ${HEAD_WIDTHS.join("/")} on ${HEAD_SCENS.join(" + ")}; ` +
          `cells print scrollWidth/copy-count@worst-right-edge, so 320's 320/c3@304 reads against the 342/c3@342 ` +
          `it replaced. The band is 320-ONLY: 360-620 are the no-regression control, not padding`,
        );
        okLine(
          `\`a.inst-tab\` at 360-390 is NOT suppressed here — .inst-tabs computes overflow-x:auto, so the strip ` +
          `scrolls itself and never moves documentElement.scrollWidth; that containment is asserted per cell ` +
          `(a strip that ever computed overflow-x:visible reds) instead of being allowlisted away`,
        );
      }
    }

    // ── W21-S1: THE MEMBERS ROSTER — WHO you are removing, and whether the
    //    Remove button is on the screen at all. `#settings/members` is the
    //    highest-stakes-per-mistake screen this epic owns and NO leg above has
    //    ever navigated to it: every leg before this one drives `#`, `#fleet`,
    //    `#billing`, a detail route or `#operator`.
    //
    //    THE DEFECT, three stacked failures in the GR33 row grammar:
    //      (a) app.css `.set-row-main { min-width: 0; flex: 1 1 auto }` next to
    //          `.set-row-side { flex: 0 0 auto }` makes the IDENTITY the only
    //          shrinkable column — the role chip, Change role and Remove never
    //          yield, so the column holding WHO the row is about absorbs the
    //          whole deficit.
    //      (b) `.set-row-name` declares `overflow: hidden; text-overflow:
    //          ellipsis` and never `white-space: nowrap`, so the ellipsis is
    //          INERT: an email is a single unbreakable word, it overflows a
    //          21px column, and `overflow: hidden` hides it with NO cue.
    //      (c) there is no `@media` anywhere in app.css touching `.set-row*` —
    //          the roster has ONE layout at every width.
    //
    //    WHY BOTH ASSERTIONS AND NOT JUST PAGE OVERFLOW: the two failures are
    //    independent. At 320 the action cluster leaves the viewport (page
    //    overflow catches it); at 390 the page does NOT scroll sideways and the
    //    identity is still clipped 77px with no cue, which every page-level leg
    //    above is structurally blind to. A leg asserting only `documentElement`
    //    would go green at 390 on the pre-fix bytes.
    //
    //    ROWS ARE ITERATED, NEVER SAMPLED (D228). Row 0 is `ada@acme.com
    //    (you)` — no action buttons, and CLEAN at every width on the pre-fix
    //    bytes. A `querySelector('.set-row')` leg reads row 0, measures the one
    //    row that works, and certifies the screen. So every `.set-row` under
    //    `#members-body` is walked and the walked COUNT is asserted non-zero
    //    and printed, and the number of rows carrying an action cluster is
    //    asserted non-zero too — an all-read-only roster (the `members-member`
    //    scenario) would satisfy "no button off-screen" having measured no
    //    button at all.
    //
    //    THE CUE PREDICATE IS THE POINT, and it is deliberately not "does the
    //    element declare text-overflow: ellipsis". `text-overflow` paints only
    //    when the line cannot wrap, i.e. when `white-space` computes to a
    //    non-wrapping value. Declaring it beside `white-space: normal` is a
    //    sentence, not a cue — which is exactly the pre-fix state. So a row
    //    passes when the identity FITS (scrollWidth <= clientWidth) or when a
    //    cue can ACTUALLY PAINT, never when one is merely declared.
    //
    //    FONT PINNED (D218, paid by cch-w22-s1): `nav()` now load()s EVERY
    //    declared @font-face, awaits `document.fonts.ready` and check()s each
    //    face before a single px below is read — a missing or substituted face
    //    is exit 2, not a silent re-measure. The px are therefore taken under a
    //    KNOWN face rather than whatever arrived. They are still not pinned:
    //    the INVARIANTS are what is asserted — "the button's right edge is
    //    inside the viewport" and "the text fits or is cued" hold for any face.
    if (requested.includes("W21-members-roster-identity-and-remove")) {
      const D = "W21-members-roster-identity-and-remove";
      // BLOCK-SCOPED (D247): these axes belong to this leg alone and must never
      // read as shared file constants.
      const MEM_SCENS = ["members-populated"];
      // The phone band where the row is broken, the fold, and 900 as a measured
      // upper edge on pre-fix bytes so the band's top is pinned rather than
      // assumed.
      const MEM_WIDTHS = [320, 360, 390, 430, 480, 620, 700, 720, 760, 800, 900];
      // ANTI-VACUITY 0 — the axis itself. The brief's four driven widths must
      // survive any later edit to the list above.
      for (const need of [320, 360, 390, 430]) {
        if (!MEM_WIDTHS.includes(need)) {
          fail(D, `axis check: ${need} is not in the width set — the roster is broken across the whole phone band and a set missing one of 320/360/390/430 cannot see it`);
        }
      }
      if (!MEM_SCENS.includes("members-populated")) {
        fail(D, `axis check: \`members-populated\` is not in the scenario set — it is the only members fixture that renders action buttons at all, so without it this leg measures a read-only roster and certifies nothing about Remove`);
      }
      const cellCount = MEM_SCENS.length * MEM_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${MEM_SCENS.length} members scenario x ${MEM_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; every #members-body .set-row iterated: action-cluster right edge vs viewport,` +
        ` .set-row-name scrollWidth vs clientWidth with a cue that can actually paint, + page overflow)\n`,
      );
      let cells = 0, rowsSeen = 0, actionRows = 0, offScreen = 0, clipped = 0, pageOver = 0;
      for (const scen of MEM_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter wide and assert the LANDED view — `?scen=` alone does not
          // route (see the W13 note), and a phantom roster is worse than none.
          await setViewport(1000);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#settings/members`,
            `document.querySelector('#members-body .set-row') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-members';})()`,
          );
          const row = [];
          for (const width of MEM_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var d=document.documentElement;` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,rows:[]};` +
              // EVERY row, in document order — never a sample (D228). Row 0
              // carries no buttons and is clean at every width, so a sampled
              // leg certifies the screen off the one row that works.
              `[].slice.call(document.querySelectorAll('#members-body .set-row')).forEach(function(r,i){` +
              `  var rec={i:i,btns:[],side:null,name:null};` +
              `  var side=r.getElementsByClassName('set-row-side')[0];` +
              `  if(side){var sr=side.getBoundingClientRect();rec.side=Math.round(sr.right*100)/100;}` +
              `  [].slice.call(r.querySelectorAll('.set-row-side .btn')).forEach(function(b){` +
              `    var br=b.getBoundingClientRect();` +
              `    rec.btns.push({t:(b.textContent||'').trim(),right:Math.round(br.right*100)/100});` +
              `  });` +
              `  var n=r.getElementsByClassName('set-row-name')[0];` +
              `  if(n){var cs=getComputedStyle(n);` +
              `    rec.name={sw:n.scrollWidth,cw:n.clientWidth,ws:cs.whiteSpace,te:cs.textOverflow,` +
              `      t:(n.textContent||'').trim().slice(0,40)};}` +
              `  out.rows.push(rec);` +
              `});` +
              `return out;})()`,
            );
            cells++;
            if (m.view !== "view-members") {
              fail(D, `${scen}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-members" — the hash did not route, so nothing below this line measures the roster`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: an empty roster is not a clean roster.
            if (m.rows.length === 0) {
              fail(D, `${scen}/${theme}@${width}: zero \`#members-body .set-row\` rendered — nothing was measured, this is not a pass`);
              row.push(`${width}:0r`);
              continue;
            }
            rowsSeen += m.rows.length;
            const withBtns = m.rows.filter((r) => r.btns.length > 0).length;
            actionRows += withBtns;
            if (withBtns === 0) {
              fail(D, `${scen}/${theme}@${width}: ${m.rows.length} rows rendered and NOT ONE carries an action button — "no Remove off-screen" would be true of an empty set, which is not what this leg claims`);
            }
            if (m.psw > m.pcw) {
              pageOver++;
              fail(D, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the roster is off-screen sideways`);
            }
            for (const r of m.rows) {
              for (const b of r.btns) {
                if (b.right > m.pcw) {
                  offScreen++;
                  fail(D, `${scen}/${theme}@${width} row${r.i} "${b.t}": right edge ${b.right} > viewport ${m.pcw} — the control is OFF-SCREEN by ${Math.round((b.right - m.pcw) * 100) / 100}px, so the person cannot reach it`);
                }
              }
              if (r.side != null && r.side > m.pcw) {
                offScreen++;
                fail(D, `${scen}/${theme}@${width} row${r.i} \`.set-row-side\`: right edge ${r.side} > viewport ${m.pcw} — the whole action cluster leaves the viewport`);
              }
              const n = r.name;
              if (!n) continue;
              // A CUE THAT CAN ACTUALLY PAINT. `text-overflow` is inert unless
              // the line is forbidden to wrap — declaring `ellipsis` beside
              // `white-space: normal` is a sentence, not a cue.
              // `pre-wrap` and `pre-line` WRAP, so they are not on this list.
              const cuePaints = n.te === "ellipsis" && (n.ws === "nowrap" || n.ws === "pre");
              if (n.sw > n.cw && !cuePaints) {
                clipped++;
                fail(D, `${scen}/${theme}@${width} row${r.i} \`.set-row-name\` "${n.t}": scrollWidth ${n.sw} > clientWidth ${n.cw} — ${n.sw - n.cw}px of the identity is hidden with NO cue that can paint (computed white-space "${n.ws}", text-overflow "${n.te}"; ellipsis is inert unless white-space forbids wrapping). This is WHO the row's Remove button acts on`);
              }
            }
            // The cell string carries the NUMBERS, not a verdict glyph: the
            // page's own scrollWidth, the right edge of every action button
            // that exists (against the viewport), and every identity's
            // clientWidth/scrollWidth. A reader can re-derive both assertions
            // from the clean line alone, which is what makes a green here
            // quotable rather than merely trusted.
            const rm = m.rows.flatMap((r) => r.btns.map((b) => b.right)).join(",");
            const id = m.rows.map((r) => (r.name ? `${r.name.cw}/${r.name.sw}` : "-")).join(",");
            row.push(
              `${width}:${m.rows.length}r/${withBtns}a psw${m.psw}` +
              (rm ? ` act[${rm}]<=${m.pcw}` : ` act[none]`) +
              ` id[${id}]` + (m.psw > m.pcw ? `!page` : ``),
            );
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean — ${rowsSeen} \`#members-body .set-row\` iterated in total ` +
          `(${actionRows} of them carrying an action cluster, asserted non-zero per cell) across ` +
          `${MEM_WIDTHS.join("/")} x light+dark on ${MEM_SCENS.join(" + ")}: ${offScreen} controls past the ` +
          `viewport edge, ${clipped} identities hidden with no cue that can paint, ${pageOver} pages ` +
          `scrolling sideways. Every row is walked, never sampled — row 0 is the self row, has no buttons, ` +
          `and is clean on the PRE-FIX bytes, so a sampled leg certifies the screen off the one row that works`,
        );
        okLine(
          `FONT PINNED (D218, paid by cch-w22-s1): nav() load()s every declared @font-face, awaits ` +
          `document.fonts.ready and check()s each face before these px are read — a missing face is exit 2. ` +
          `What is ASSERTED is face-independent anyway — a control's right edge inside the viewport, and ` +
          `text that either fits or carries a paintable cue`,
        );
      }
    }

    // ── W21-S3: CONTENT IS THE VARIABLE, and every leg above is blind to it ──
    //    Every leg in this file drives the KIND corpus: the longest host any
    //    fixture ships is 32 characters and the longest name is 10. The server
    //    admits 253 and 255 (`validate_length(:custom_host, max: 253)` at
    //    registry/barkpark.ex:727, `validate_length(:name, min: 1, max: 255)`
    //    at :466) and `publicUrl()` (`grep -n "function publicUrl" app.js`)
    //    PREFERS `custom_host` over `url` —
    //    so the DOMINANT real input on the fleet row was the one input
    //    no instrument had ever driven. `fleet-cruel-content` (scenarios.mjs)
    //    is that input, committed; this leg is what makes it bite.
    //
    //    TWO HOSTS, TWO DIFFERENT FAILURE SHAPES, which is why one assertion
    //    could not have caught both:
    //      · `.fleet-url` (app.css:954) CLIPS ITSELF — it is font/colour/mono/
    //        margin only, and its only wrap declaration (:1560) is scoped to
    //        `.fleet-url .site-open`, the Visit chip, not the URL text. Driven
    //        on pre-fix bytes it measured scrollWidth 1822 against clientWidth
    //        250 and the remainder painted THROUGH the neighbouring column
    //        (`overflow: visible`, exactly the SPILL app.css:2220 records).
    //      · `.instance-card-name` (app.css:3134) NEVER CLIPS ITSELF — it has
    //        no bound at all, so there is nothing for a per-element scrollWidth
    //        check to see. It pushes the PAGE instead: documentElement
    //        .scrollWidth 2395 against a 320 viewport, 2075px of sideways
    //        scroll on the most-seen screen in the product. A leg that asked
    //        only the element question would have scored this host PERFECT.
    //    Hence BOTH assertions on BOTH hosts at every cell: the element bound
    //    AND `document.documentElement.scrollWidth <= clientWidth`.
    //
    //    D228 (ITERATE, NEVER querySelector). `fleet-cruel-content` renders a
    //    cruel row and a KIND one (`liveInstance`, 32/10) in the same DOM, in
    //    that order — a singular query would inspect the cruel row and miss
    //    the regression a bound could inflict on the kind neighbour, and the
    //    reverse ordering would miss the defect entirely. Every `.fleet-url`
    //    and every `.instance-card-name` in the document is measured.
    //
    //    THE KIND CORPUS IS DRIVEN HERE TOO, and not as decoration: `mixed-fleet`
    //    is in the scenario set so the same cells prove the bound did not buy
    //    the cruel row at the kind row's expense. That is the "shredded the
    //    person rather than fitting them" failure (D165) stated as an assertion.
    //
    //    ANTI-VACUITY: a cell that measures zero elements FAILS. Both hosts are
    //    counted per cell and a zero on either is a refusal, not a pass —
    //    `#fleet` renders no `.instance-card-name` and `#overview` renders no
    //    `.fleet-url`, so the count is asserted PER ROUTE against what that
    //    route is supposed to render, never against the union.
    //
    //    FONT PINNED (D218, paid by cch-w22-s1): `nav()` load()s every declared
    //    @font-face, awaits `document.fonts.ready` and check()s each face
    //    before these px are read, so they are taken under a KNOWN face.
    //    The claim this leg stands behind is still the RATIO (0 offending cells
    //    on the kind corpus vs N on the cruel one), not the absolute widths.
    if (requested.includes("W21-cruel-content-text-bounded")) {
      const D = "W21-cruel-content-text-bounded";
      // BLOCK-SCOPED (D247): these axes belong to this leg alone.
      // The phone band where the page overflow is worst, the two boundary
      // widths either side of the 899 stacked/side-by-side split (the fleet row
      // changes flex-direction there, so a bound proven on one side proves
      // nothing about the other), and 1000 as the wide control. ONE shared width
      // axis — the 899 straddle is a property of `.fleet-row`, not of a family.
      const CRUEL_WIDTHS = [320, 360, 390, 430, 620, 720, 768, 830, 898, 900, 1000];
      //
      // ── THE CRUELTY LEDGER (D260 slice A / D269 / D271) ────────────────────
      // A row is no longer "a selector and a hash". It is a CLAIM about ONE text
      // host, carrying the evidence that makes the claim checkable:
      //   hash/view/ready  how to reach the screen and how to know it landed
      //   sel              the host measured — EVERY match, never the first
      //   scens            THIS row's scenario axis: >=1 CRUEL fixture and >=1
      //                    KIND control. PER-ROW, because a fixture that renders
      //                    a cruel `.fleet-url` need not render a cruel
      //                    `.instance-card-name`. As one leg-wide constant, "this
      //                    host is driven cruel" was unfalsifiable per host: the
      //                    axis assertions below never read the route table at
      //                    all, so an EMPTY table still printed "cells clean".
      //   cap              the server cap the cruel string is cut to, cited to
      //                    the file that enforces it. A cruel string is cruel
      //                    only while it still matches its cap.
      //   class            WHY this family is or is not admissible (vocabulary
      //                    below) — the verdict is RECORDED, never a silent gap.
      //   predicate        the person-facing sentence this row buys.
      //
      // THE CLASS VOCABULARY — one admissible verdict and six refusals. A family
      // that cannot be made cruel does not vanish from the ledger; it lands here
      // with its reason, in the fixture, not in a charter:
      //   CRUEL           a person-typed value AT the cap reaches this host, so
      //                   the row is a live measurement and pays rent.
      //   INADMISSIBLE    no person-typed write path reaches the field at ANY
      //                   rung. `.fleet-meta`'s region/server_type (barkpark.ex
      //                   :469/:470, max 255) are the flagship — the provisioner
      //                   writes them. `barkpark.name`'s 255 (barkpark.ex:466) is
      //                   inadmissible too, and NOT because of a role: every mint
      //                   path derives `slug = slugify(name)` with NO truncation
      //                   (router.ex:7892 go-live, :8115 resurrect, :2120
      //                   register; slugify at :11243), and slug is capped at 63
      //                   (barkpark.ex:468) — so a 255-char name 422s with
      //                   `slug: should be at most 63 character(s)` even for an
      //                   admin holding a real `deploy` PAT.
      //   NONE-POSSIBLE   the field carries no cap at all, so no string is
      //                   maximal and "cruel" has nothing to be measured against.
      //   GONE-KIND       a string this file still calls cruel no longer matches
      //                   the cap it cites — the cap moved, or the fixture was
      //                   edited. The row then measures a KIND value under a
      //                   cruel name, which is the quietest green there is.
      //   BREAKABLE       maximal but still self-wrapping: the value hits the cap
      //                   and the host wraps it anyway, so the cell cannot fail.
      //                   W21's own builder shipped one by accident (a
      //                   hyphen-rich 253-char host: every hyphen is a line-break
      //                   opportunity). A BREAKABLE row is honest only while it
      //                   says so.
      //   ADMIN-ONLY-AT-MINT  reachable only through a grant frozen at mint: an
      //                   admin-minted `deploy` PAT survives its holder's
      //                   demotion to member and still returns 201, because the
      //                   PAT branch encodes the ability at mint time and never
      //                   re-checks the role at use time. Reachable — but not by
      //                   the demoted person whose screen this is.
      //   FORMAT-LEGAL    the cap is enforced by `validate_change` + a regex, not
      //                   by length alone, so a LENGTH-ONLY generator records a
      //                   FALSE NONE-POSSIBLE. `site.domains` (site.ex:431-435)
      //                   refuses a 212-char SINGLE label with 422 because
      //                   @domain_format (site.ex:28) caps every label at 63; its
      //                   admissible maximum is 3 x 63-char labels + "." + a
      //                   61-char label = exactly 253.
      // A CRUEL row's fixture proves its own cap and format at load
      // (scenarios.mjs:1433-1442 throws on GONE-KIND and on a format the server
      // would reject), so those two refusals are enforced upstream of this table.
      // SCOPE OF THIS SHAPE (cch-w23-s4): the row shape, the vocabulary and the
      // two refusals only. ZERO new cruel families are added here — widening the
      // ledger to the ~30 caps across the 8 schemas is later work, and only where
      // a twin proves rent. Deliberately NOT built: a name-keyed ledger module, a
      // per-assertion scoring refactor, and the three consumer rewrites
      // (cch-w22-s7 criteria 1-5 and 9-14) — a different animal, still open.
      const CRUEL_CLASSES = [
        "CRUEL", "INADMISSIBLE", "NONE-POSSIBLE", "GONE-KIND",
        "BREAKABLE", "ADMIN-ONLY-AT-MINT", "FORMAT-LEGAL",
      ];
      const CRUEL_ROUTES = [
        {
          hash: "#fleet", view: "view-fleet", sel: ".fleet-url", ready: ".fleet-row",
          scens: ["fleet-cruel-content", "mixed-fleet"],
          cap: "barkpark.custom_host <= 253 (registry/barkpark.ex:727) under @external_host_format (:109)",
          class: "CRUEL",
          predicate: "a person reading their fleet can see WHICH HOST a box answers on — the whole value, not the 14% of it that fits",
        },
        {
          hash: "#overview", view: "view-overview", sel: ".instance-card-name", ready: ".instance-card",
          scens: ["fleet-cruel-content", "mixed-fleet"],
          cap: "barkpark.name <= 255 (registry/barkpark.ex:466)",
          class: "INADMISSIBLE",
          predicate: "a person on the overview can tell their instances apart by name. KEPT as an UPPER BOUND, not as a reachability claim: 255 is unreachable (see INADMISSIBLE above), so this row proves the host survives a value CRUELLER than any mint path admits — it does NOT prove anyone can type one",
        },
      ];
      // ANTI-VACUITY 0 — the axes. A leg that lost the cruel scenario, or the
      // kind control, or the sub-899 band, or its whole route table, passes for
      // the wrong reason.
      //
      // THE EMPTY-TABLE REFUSAL (D271). This is the hole the shape change alone
      // does NOT close: on the pre-ledger bytes the three axis assertions read
      // only the scenario/width constants, so `CRUEL_ROUTES = []` walked zero
      // cells, printed `0 / 0 cells clean`, and exited 0 — a PASS over an empty
      // corpus, under a header naming two selectors it never measured.
      if (CRUEL_ROUTES.length === 0) {
        fail(D, `axis check: the route table is EMPTY — this leg would walk zero cells and still print "0 / 0 cells clean". A ledger with no rows measures nothing, and nothing measured is a refusal, not a pass`);
      }
      for (const route of CRUEL_ROUTES) {
        const at = `${route.hash} \`${route.sel}\``;
        // A cruel fixture is named for what it is; anything else in the row's
        // axis is a KIND control. That naming rule is what makes the two
        // assertions below able to LOSE in both directions.
        const cruel = route.scens.filter((s) => /cruel/.test(s));
        const kind = route.scens.filter((s) => !/cruel/.test(s));
        if (cruel.length === 0) {
          fail(D, `axis check ${at}: this row carries NO cruel fixture (scens: ${route.scens.join(", ") || "none"}) — a row driven only on kind content measures the corpus every other leg already measures, and its green says nothing about the cap it cites (${route.cap})`);
        }
        if (kind.length === 0) {
          fail(D, `axis check ${at}: this row carries NO kind control (scens: ${route.scens.join(", ") || "none"}) — without one, a bound that fixes the cruel value by shredding today's rendering scores a clean sweep on this host`);
        }
        if (!CRUEL_CLASSES.includes(route.class)) {
          fail(D, `axis check ${at}: class "${route.class}" is not in the ledger vocabulary (${CRUEL_CLASSES.join(", ")}) — an unclassified row is a family with no recorded verdict`);
        }
        if (!route.cap || !route.predicate) {
          fail(D, `axis check ${at}: the row is missing its ${!route.cap ? "cap citation" : "person-facing predicate"} — a cruel row that cannot say which cap it is cut to, or which person it is for, is a fixture with no claim attached`);
        }
      }
      if (!CRUEL_WIDTHS.some((w) => w <= 899) || !CRUEL_WIDTHS.some((w) => w >= 900)) {
        fail(D, `axis check: the width set does not straddle 899 — \`.fleet-row\` is column-direction below and row-direction above, so a bound proven on one side is unproven on the other`);
      }
      // Derived, never hardcoded: the corpus, the selector list and the cell
      // budget all come off the table, so a row added or dropped moves the
      // header with it instead of leaving it lying about what was measured.
      const CRUEL_SCENS = [...new Set(CRUEL_ROUTES.flatMap((r) => r.scens))];
      const cellCount = CRUEL_ROUTES.reduce((n, r) => n + r.scens.length, 0) * CRUEL_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${CRUEL_SCENS.length} scenarios x ${CRUEL_ROUTES.length} routes x ${CRUEL_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; ${CRUEL_ROUTES.map((r) => r.sel).join(" + ")} scrollWidth vs clientWidth, + documentElement.scrollWidth vs clientWidth)\n`,
      );
      let cells = 0, seen = 0, spilled = 0, pageOver = 0;
      for (const route of CRUEL_ROUTES) {
        for (const scen of route.scens) {
          for (const theme of ["light", "dark"]) {
            // Enter WIDE and assert the landed view — `?scen=` alone renders
            // #overview and the fleet table goes phantom (the W13/W15 note).
            await setViewport(1000);
            await nav(
              `${BASE}/?scen=${scen}&theme=${theme}${route.hash}`,
              `document.querySelector('${route.ready}') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='${route.view}';})()`,
            );
            const row = [];
            for (const width of CRUEL_WIDTHS) {
              await setViewport(width);
              const m = await evalJs(
                `(function(){` +
                `var v=document.querySelector('section.view:not([hidden])');` +
                `var d=document.documentElement;` +
                `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,n:0,bad:[],worst:0};` +
                `[].slice.call(document.querySelectorAll(${JSON.stringify(route.sel)})).forEach(function(e,i){` +
                // A node with no text can never clip and must not be counted as
                // a measured assertion (the vacuous-green vector W20-S3 named on
                // `.instance-card-url`: a provisioning box renders the node empty).
                `  var t=(e.textContent||'').trim(); if(!t) return;` +
                `  out.n++;` +
                `  if(e.scrollWidth>out.worst) out.worst=e.scrollWidth;` +
                `  if(e.scrollWidth>e.clientWidth) out.bad.push({i:i,len:t.length,sw:e.scrollWidth,cw:e.clientWidth,t:t.slice(0,28)});` +
                `});` +
                `return out;})()`,
              );
              cells++;
              if (m.view !== route.view) {
                fail(D, `${scen}/${theme}@${width}${route.hash}: rendered section.view "${m.view}", asked for "${route.view}" — the hash did not route, so nothing below this line measures ${route.sel}`);
                row.push(`${width}:?`);
                continue;
              }
              if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}${route.hash}: data-theme is "${m.theme}" — the theme did not apply`);
              if (m.n === 0) {
                fail(D, `${scen}/${theme}@${width}${route.hash}: zero NON-EMPTY \`${route.sel}\` rendered — nothing was measured, this is not a pass`);
                row.push(`${width}:0`);
                continue;
              }
              seen += m.n;
              if (m.psw > m.pcw) {
                pageOver++;
                fail(D, `${scen}/${theme}@${width}${route.hash}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the page is off-screen sideways. \`${route.sel}\` has no bound, so it never clips ITSELF: it pushes the PAGE, which is invisible to an element-only scorer`);
              }
              for (const b of m.bad) {
                spilled++;
                fail(D, `${scen}/${theme}@${width}${route.hash} el${b.i} \`${route.sel}\`: scrollWidth ${b.sw} > clientWidth ${b.cw} — ${Math.round((1 - b.cw / b.sw) * 100)}% of a ${b.len}-character value ("${b.t}…") is not rendered, and the box computes overflow:visible so the remainder paints THROUGH its neighbour`);
              }
              row.push(`${width}:${m.n}x${m.worst}${m.bad.length ? "!" + m.bad.length : ""}${m.psw > m.pcw ? "P" + (m.psw - m.pcw) : ""}`);
            }
            process.stdout.write(`   ${route.hash} ${scen}/${theme}  ${row.join(" ")}\n`);
          }
        }
      }
      // THE RUN CHECK (D271). The header declares a cell budget off the table;
      // the loop drives cells. If those two numbers disagree the "cells clean"
      // line below is scored against a population that was never walked — a row
      // skipped, a scenario list mutated mid-run, a `continue` that ran early.
      if (cells !== cellCount) {
        fail(D, `run check: drove ${cells} cells, the table declares ${cellCount} — the loop measured a different corpus than the header announced, so a "cells clean" line here would be counted over ${Math.abs(cellCount - cells)} cell(s) nobody drove`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${seen} non-empty ${CRUEL_ROUTES.map((r) => r.sel).join(" / ")} measured) across ` +
          `${CRUEL_WIDTHS.join("/")} on ${CRUEL_SCENS.join(" + ")}; ${spilled} text hosts wider than their own box, ` +
          `${pageOver} pages scrolling sideways. Cells print count x worst scrollWidth, so a bound that merely HIDES ` +
          `the overflow is readable as a worst number that never falls`,
        );
        okLine(
          `the ROBUST claim is the RATIO — the KIND corpus (\`mixed-fleet\`, 32-char host / 10-char name) and the ` +
          `CRUEL one (253/255, the server's own caps) now score the SAME on both assertions. The px above are ` +
          `taken under a PINNED face (D218, paid by cch-w22-s1): nav() load()s every declared @font-face, awaits ` +
          `document.fonts.ready and check()s each one, refusing at exit 2 rather than measuring a fallback`,
        );
      }
    }

    // ── W21: THE WRITE-ONCE TOKEN, on the one screen whose own copy says
    //    "This is the only time you'll see this token." A READ defect, stated
    //    plainly: the Copy button IS reachable in every driven cell and the old
    //    <input> scrolled internally, so nothing was unclickable — but a person
    //    told to save a secret they can only see 22 characters of cannot verify
    //    they saved the right one.
    //
    //    WHY NO INSTRUMENT SAW IT. `git grep -c token-reveal --
    //    cloud/priv/static/__preview__` hit ZERO on origin/main: the sweep, the
    //    modal oracle and this guard all missed the reveal, and smoke.mjs pinned
    //    it only as a STRING (`hooks.tokenRevealHtml`), never laid out at any
    //    viewport. A node-pinned string can assert the token is PRESENT; only a
    //    browser can assert it is READABLE.
    //
    //    THE MECHANISM AND ITS REMEDY. `.token-reveal` is a flex row and the
    //    secret lived in an `<input>`, which can only ever scroll — no CSS makes
    //    an input wrap, so the remedy had to move the plaintext into a `<code>`
    //    text node (break-all is honest for an OPAQUE token where it would not
    //    be for a hostname) and demote the input to an off-screen copy buffer.
    //    Measured Δ0 CSSOM heads: every declaration folded into a rule that
    //    already existed (D230/D231/D232 abstention — this leg's slice does not
    //    hold the baseline).
    //
    //    THE VACUITY TRAPS, each asserted rather than assumed:
    //      (a) THE FIXTURE UNDERSTATED THE SERVER. scenarios.mjs minted a
    //          50-character token; the real PAT is 51 (accounts.ex:857 +
    //          `defp generate_token` = "bpc_pat_" + 43 base64url chars). The
    //          per-cell `len >= 51` assertion below makes a corpus that drifts
    //          BACK to a shorter secret red here, so the fix cannot be undone by
    //          quietly shortening the string it is measured against.
    //      (b) A REACHABLE COPY BUTTON IS NOT A READABLE TOKEN. Both are
    //          asserted per cell; the pre-fix tree passed the copy half at every
    //          one of the 32 cells and failed the read half at all 32.
    //      (c) ZERO HOSTS IS NOT A CLEAN HOST. A cell that reaches no reveal at
    //          all FAILS — the gesture chain is the real one (#token-add →
    //          #token-name → .token-ab → #token-submit → 201 → revealToken()),
    //          so a routing or mock regression cannot manufacture a green.
    //      (d) LEGIBILITY BOUGHT WITH SMALLER TYPE IS NOT LEGIBILITY (D240).
    //          The host's COMPUTED font-size is read per cell and anything below
    //          12px fails — this epic already ships 228 sub-12px instances
    //          against its own contract and must not buy the 229th here.
    //
    //    FONT PINNED (D218/D248, paid by cch-w22-s1): `nav()` load()s every
    //    declared @font-face, awaits `document.fonts.ready` and check()s each
    //    face before these px are read — a missing woff2 is exit 2, not a
    //    silently re-measured fallback. The RATIOS and the clipped/not-clipped
    //    verdicts remain what this leg stands behind.
    if (requested.includes("W21-token-reveal-readable")) {
      const D = "W21-token-reveal-readable";
      // BLOCK-SCOPED (the `const D` precedent): these axes belong to this leg.
      // Two scenarios because they mint DIFFERENT fixture paths — `tokens-reveal`
      // answers the scenario's own `tokenMint` override, `tokens-member` falls
      // through to scenarios.mjs's default mint body — and because the member
      // form renders no `.token-ab` checkboxes, so the gesture chain is exercised
      // in both of its shapes.
      const TOK_SCENS = ["tokens-reveal", "tokens-member"];
      const TOK_WIDTHS = [320, 360, 390, 430];
      // The length the SERVER mints. Not a fixture fact — a source fact.
      const PAT_LEN = 51;
      // ANTI-VACUITY 0 — the axes themselves.
      if (!TOK_WIDTHS.includes(320)) {
        fail(D, `axis check: 320 is not in the width set — it is the width at which more than half the secret was hidden, so without it this leg cannot see the defect at its worst`);
      }
      if (!TOK_SCENS.includes("tokens-member")) {
        fail(D, `axis check: \`tokens-member\` is not in the scenario set — it is the only cell that drives the DEFAULT mint body and the member form (no .token-ab), so without it half the mint path is unmeasured`);
      }
      const tokCells = TOK_SCENS.length * TOK_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${TOK_SCENS.length} token scenarios x ${TOK_WIDTHS.length} widths x 2 themes` +
        ` (${tokCells} cells; every character of the ${PAT_LEN}-char PAT readable, Copy on screen, type >= 12px)\n`,
      );
      let cells = 0, hostsSeen = 0, unreadable = 0, clipped = 0, offscreen = 0, tinyType = 0, pageOver = 0;
      for (const scen of TOK_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter at the widest driven width and assert the LANDED view before
          // touching anything — `?scen=` alone does not route.
          await setViewport(430);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#settings/tokens`,
            `(function(){var v=document.querySelector('section.view:not([hidden])');` +
            `return v && v.id==='view-tokens' && document.getElementById('token-add');})()`,
          );
          // THE REAL MINT GESTURE CHAIN, not the tokenRevealHtml hook.
          await evalJs(
            `(function(){` +
            `document.getElementById('token-add').click();` +
            `var n=document.getElementById('token-name'); n.value='Guard probe key';` +
            `var ab=document.querySelector('.token-ab'); if(ab) ab.checked=true;` +
            `document.getElementById('token-submit').click();` +
            `return true;})()`,
          );
          let revealed = false;
          for (let w = 0; w < RENDER_CAP; w += 100) {
            if (await evalJs(`!!(document.getElementById('token-reveal-text')||document.getElementById('token-reveal-value'))`)) { revealed = true; break; }
            await sleep(100);
          }
          if (!revealed) {
            fail(D, `${scen}/${theme}: the mint flow never reached the reveal (#token-add -> #token-name -> .token-ab -> #token-submit -> 201) — nothing below was measured, and an unreached screen is not a clean screen`);
            continue;
          }
          const row = [];
          for (const width of TOK_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var d=document.documentElement;` +
              `var text=document.getElementById('token-reveal-text');` +
              `var input=document.getElementById('token-reveal-value');` +
              `var host=text||input;` +
              `var out={theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,kind:host?(text?'code':'input'):'none'};` +
              `if(!host) return out;` +
              `var r=host.getBoundingClientRect(); var cs=getComputedStyle(host);` +
              `var val=text?(text.textContent||''):(input.value||'');` +
              `out.len=val.length; out.fs=Math.round(parseFloat(cs.fontSize)*100)/100;` +
              `out.sw=host.scrollWidth; out.cw=host.clientWidth; out.sh=host.scrollHeight; out.ch=host.clientHeight;` +
              `out.right=Math.round(r.right); out.bottom=Math.round(r.bottom);` +
              `out.vis=(r.width>0 && r.height>0 && cs.visibility!=='hidden' && cs.display!=='none');` +
              `var probe=document.createElement('span');` +
              `probe.style.cssText='position:absolute;left:-9999px;top:0;white-space:pre;visibility:hidden';` +
              `probe.style.font=cs.font||(cs.fontStyle+' '+cs.fontWeight+' '+cs.fontSize+'/'+cs.lineHeight+' '+cs.fontFamily);` +
              `probe.textContent=val||'x'; document.body.appendChild(probe);` +
              `var full=probe.getBoundingClientRect().width; probe.parentNode.removeChild(probe);` +
              `out.adv=val.length?full/val.length:0;` +
              `var lh=parseFloat(cs.lineHeight)||(out.fs*1.5);` +
              `var perLine=out.adv?Math.floor(out.cw/out.adv):0;` +
              // An <input> is single-line BY CONSTRUCTION — it can only ever
              // scroll — so its readable count is one line's worth. A wrapping
              // text host gets the lines its own box actually shows. Nothing is
              // clipped ⇒ every character is laid out; that case is exact, the
              // clipped case is a monospace-advance ESTIMATE and says so.
              `var linesShown=text?Math.max(1,Math.floor((out.ch+1)/lh)):1;` +
              `out.visChars=(out.sw<=out.cw+1 && out.sh<=out.ch+1) ? val.length : Math.min(val.length, perLine*linesShown);` +
              `var copy=document.getElementById('token-copy');` +
              `if(copy){var cr=copy.getBoundingClientRect();` +
              `out.copyRight=Math.round(cr.right); out.copyVis=(cr.width>0&&cr.height>0);` +
              `out.gapX=Math.round(cr.left-r.right); out.gapY=Math.round(cr.top-r.bottom);}` +
              `return out;})()`,
            );
            cells++;
            if (m.kind === "none") {
              fail(D, `${scen}/${theme}@${width}: no token host in the document — nothing was measured, this is not a pass`);
              row.push(`${width}:none`);
              continue;
            }
            hostsSeen++;
            if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            if (!m.vis) {
              fail(D, `${scen}/${theme}@${width}: the token host (<${m.kind}>) is not rendered — a secret nobody can see is not a readable secret`);
            }
            // (a) the corpus may never understate the server.
            if (m.len < PAT_LEN) {
              fail(D, `${scen}/${theme}@${width}: the minted token is ${m.len} characters, but the server mints ${PAT_LEN} ("bpc_pat_" + 43 base64url chars) — the fixture understates the string this screen must render`);
            }
            // (d) legibility floor.
            if (!(m.fs >= 12)) {
              tinyType++;
              fail(D, `${scen}/${theme}@${width}: the token renders at ${m.fs}px — below the type scale's --text-xs 12px floor (D240). Readability bought with smaller type is not readability`);
            }
            // the defect itself, on BOTH axes.
            if (m.sw > m.cw + 1 || m.sh > m.ch + 1) {
              clipped++;
              fail(D, `${scen}/${theme}@${width}: the token host clips — scrollWidth ${m.sw} vs clientWidth ${m.cw}, scrollHeight ${m.sh} vs clientHeight ${m.ch}`);
            }
            if (m.visChars < m.len) {
              unreadable++;
              fail(D, `${scen}/${theme}@${width}: ${m.visChars} of ${m.len} characters of the write-once token are readable — ${m.len - m.visChars} are hidden on the one screen that says you will never see it again`);
            }
            if (m.right > m.pcw + 1) {
              offscreen++;
              fail(D, `${scen}/${theme}@${width}: the token host's right edge is at ${m.right} against a ${m.pcw}px viewport — ${m.right - m.pcw}px of the secret is off-screen sideways`);
            }
            // (b) the copy half, asserted separately so a readable token can
            //     never buy a green for an unreachable button (or the reverse).
            if (!m.copyVis) {
              fail(D, `${scen}/${theme}@${width}: no rendered Copy control beside the token`);
            } else if (m.copyRight > m.pcw + 1) {
              fail(D, `${scen}/${theme}@${width}: Copy's right edge is at ${m.copyRight} against a ${m.pcw}px viewport — ${m.copyRight - m.pcw}px off-screen`);
            }
            if (m.psw > m.pcw) {
              pageOver++;
              fail(D, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — the reveal pushes the page sideways`);
            }
            row.push(`${width}:${m.visChars}/${m.len}c ${m.cw}/${m.sw}px @${m.fs}px cp${m.copyRight}(x${m.gapX},y${m.gapY})`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${hostsSeen} token hosts reached through the REAL mint chain) across ` +
          `${TOK_WIDTHS.join("/")} on ${TOK_SCENS.join(" + ")}; ${unreadable} cells hiding characters, ` +
          `${clipped} clipping hosts, ${offscreen} secrets off-screen, ${tinyType} cells below the 12px floor, ` +
          `${pageOver} pages scrolling sideways. Cells print readable/total characters, clientWidth/scrollWidth, ` +
          `and Copy's right edge with its (x,y) gap to the token — so a fix that wins readability by pushing ` +
          `the button away is visible in the same line`,
        );
        okLine(
          `FONT PINNED (D218/D248, paid by cch-w22-s1): nav() load()s every declared @font-face, awaits ` +
          `document.fonts.ready and check()s each face before these px are read, refusing at exit 2 on a ` +
          `missing one. The clipped/not-clipped verdicts and the character RATIOS are what it stands behind`,
        );
      }
    }

    // ── W20: WHICH box needs an operator, in the tablet band ────────────────
    //    Every leg above measures a REASON, a PILL or a PAGE. Not one measures
    //    `.attention-name` — `git grep -c attention-name -- cloud/priv/static/
    //    __preview__ .github` exited 1 with no output on origin/main — so the
    //    attention queue's IDENTITY column has never been instrumented, and the
    //    W18 leg's `[att …]` line prints the neighbouring pill while the name
    //    beside it measured 0px wide and scored nothing.
    //
    //    THE DEFECT THIS LEG EXISTS TO CATCH, driven on origin/main bytes: at
    //    769 and 800 `.attention-main` measured 0.00px and `.attention-name`
    //    read scrollWidth 67 / clientWidth 0 — the row said THAT something
    //    needs attention and not WHICH box. Below 769 the GR109 stack saves it;
    //    the band above it was never filed until this row.
    //
    //    THREE INVARIANTS, and the third is the one a width-only leg misses:
    //      (a) name.clientWidth > 0        — the column exists at all.
    //      (b) name.scrollWidth <= clientWidth — its text is not cut.
    //      (c) the painted TEXT RUN (a Range over the name's contents, NOT its
    //          box) does not intersect the first button's rect. A collapsed box
    //          with no `overflow: hidden` scores (a) and (b) the instant a
    //          floor is added and still paints glyphs across "View instance";
    //          only the rect-intersection sees that, and it is what the
    //          ellipsis half of the remedy is for.
    if (requested.includes("W20-attention-name-column")) {
      const D = "W20-attention-name-column";
      // BLOCK-SCOPED on purpose (precedent: `const D` above): these widths are
      // this row's band, not a shared vocabulary, and hoisting them into the
      // constants region is how two slices start editing one line.
      const NAME_WIDTHS = [320, 430, 768, 769, 800, 830, 860, 890, 900, 1000];
      const NAME_SCENS = ["overview-attention", "mixed-fleet"];
      const cellCount = NAME_SCENS.length * NAME_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${NAME_SCENS.length} scenarios x ${NAME_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; .attention-name box + text run vs the row's first action button)\n`,
      );
      let cells = 0, namesSeen = 0, collapsed = 0, clipped = 0, painted = 0, pageOver = 0;
      for (const scen of NAME_SCENS) {
        for (const theme of ["light", "dark"]) {
          // Enter wide and assert the landed view — `?scen=` alone does not
          // route (see the W13 note); a phantom table is worse than none.
          await setViewport(1000);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}#overview`,
            `document.querySelector('.attention-row .attention-name') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-overview';})()`,
          );
          const row = [];
          for (const width of NAME_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var d=document.documentElement;` +
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,names:0,zero:[],cut:[],hit:[]};` +
              `[].slice.call(document.querySelectorAll('.attention-row')).forEach(function(r,i){` +
              `  var name=r.querySelector('.attention-name'); if(!name) return; out.names++;` +
              `  var label=(name.textContent||'').trim().slice(0,32);` +
              `  if(name.clientWidth<=0) out.zero.push({i:i,cw:name.clientWidth,sw:name.scrollWidth,t:label});` +
              `  else if(name.scrollWidth>name.clientWidth) out.cut.push({i:i,cw:name.clientWidth,sw:name.scrollWidth,t:label});` +
              // The painted run, not the box: a Range over the name's contents
              // reports where the GLYPHS land even when the box is 0px wide.
              `  var btn=r.querySelector('.attention-acts button, .attention-acts a'); if(!btn) return;` +
              `  var rg=document.createRange(); rg.selectNodeContents(name);` +
              `  var tr=rg.getBoundingClientRect(), br=btn.getBoundingClientRect();` +
              `  var ix=Math.min(tr.right,br.right)-Math.max(tr.left,br.left);` +
              `  var iy=Math.min(tr.bottom,br.bottom)-Math.max(tr.top,br.top);` +
              `  if(ix>0.5&&iy>0.5) out.hit.push({i:i,x:+ix.toFixed(2),y:+iy.toFixed(2),t:label,b:(btn.textContent||'').trim().slice(0,20)});` +
              `});` +
              `return out;})()`,
            );
            cells++;
            if (m.view !== "view-overview") {
              fail(D, `${scen}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-overview" — the hash did not route, so nothing below this line measures the attention queue`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // AUDITED: an empty list is not a clean list. An attention queue
            // that stopped rendering rows would score zero findings, and this
            // leg's whole subject would vanish while it printed a pass.
            if (m.names === 0) {
              fail(D, `${scen}/${theme}@${width}: zero .attention-row .attention-name rendered — nothing was measured, this is not a pass`);
              row.push(`${width}:0n`);
              continue;
            }
            namesSeen += m.names;
            if (m.psw > m.pcw) {
              pageOver++;
              fail(D, `${scen}/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the overview is off-screen sideways`);
            }
            for (const z of m.zero) {
              collapsed++;
              fail(D, `${scen}/${theme}@${width} row${z.i} .attention-name: clientWidth ${z.cw} for ${z.sw}px of "${z.t}" — the name column collapsed to nothing, so the queue says THAT a box needs an operator and not WHICH one`);
            }
            for (const c of m.cut) {
              clipped++;
              fail(D, `${scen}/${theme}@${width} row${c.i} .attention-name: scrollWidth ${c.sw} > clientWidth ${c.cw} — ${Math.round((1 - c.cw / c.sw) * 100)}% of "${c.t}" is not rendered`);
            }
            for (const h of m.hit) {
              painted++;
              fail(D, `${scen}/${theme}@${width} row${h.i} .attention-name: the text run of "${h.t}" overlaps the "${h.b}" button by ${h.x} x ${h.y}px — the name is painting THROUGH the row's own actions, not merely truncated`);
            }
            const bad = m.zero.length + m.cut.length + m.hit.length + (m.psw > m.pcw ? 1 : 0);
            row.push(`${width}:${m.names}n${bad ? " !" + bad : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${namesSeen} .attention-name(s) measured — EVERY row of the queue, ` +
          `not a pinned one) across ${NAME_WIDTHS.join("/")} on ${NAME_SCENS.join(" + ")}; ` +
          `${collapsed} collapsed name columns, ${clipped} cut names, ${painted} names painting through their own ` +
          `action buttons, ${pageOver} pages scrolling sideways`,
        );
        okLine(
          `769-899 is the DRIVEN band (mixed-fleet was cut through 860, overview-attention through 880); ` +
          `768 and 900/1000 are carried as SHOULDERS — they were already clean on origin/main, so they cannot ` +
          `detect a band block leaking sideways, only a remedy that breaks the stack or the desktop row`,
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
