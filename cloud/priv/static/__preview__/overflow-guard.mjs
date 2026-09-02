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
import { BRINGUP_ATTEMPTS, bringUpChrome, captureStderr } from "./bringup-retry.mjs";
import { assertReadyHostsPaint as assertFloor } from "./ready-host-paint.mjs";
import { selectDefects } from "./defect-selection.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, ".."); // cloud/priv/static
const PORT = Number(process.env.OVERFLOW_GUARD_PORT || 4199);
const BASE = `http://127.0.0.1:${PORT}`;

const DEFECTS = [
  "GR108-tablet-topbar-overflow",
  "W20-phone-band-billing-chip",
  "GR109-attention-row-dead-rule",
  "GR115-bpconsole-dead-rule",
  "W27-deploy-ref-branch-bounded",
  "W12-narrow-viewport-truth",
  "W13-detail-route-band",
  "W25-deploy-rail-fail-wrap",
  "W23-account-modal-identity-bounded",
  "W22-2fa-enroll-phone-band",
  "W15-fleet-row-text-bounded",
  "W18-overview-card-pill",
  "W23-cred-remediation-reachable",
  "W24-cred-dialog-button-alive",
  "W25-launch-catalog-after-connect",
  "W20-op-gate-pill-bounded",
  "W27-failed-retry-reachable-after-flick",
  "W21-inst-head-320-copy-reachable",
  "W21-members-roster-identity-and-remove",
  "W21-cruel-content-text-bounded",
  "W21-detail-url-text-page-bound",
  "W21-token-reveal-readable",
  "W20-attention-name-column",
  "W24-theater-failed-hostname-whole",
  "W26-instance-track-min-content",
  "W26-deploy-fail-clip",
  "W26-cred-sheet-exits",
  "W26-new-ready-and-launch-bounded",
  "W14-site-detail-phone-band",
  "W29-deploy-rail-live-url-wrap",
  "W34-deploy-detail-render-bound",
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

// cchi-w23 — EVERY SUB-HOST THIS LEG ASSERTS ON, AND WHETHER A ROW MAY LACK IT.
// The leg walks `.fleet-row` correctly (`querySelectorAll(...).forEach`) and
// then reads each host with `r.querySelector(s); if (!e) return;` — a SECOND
// level whose zero was never counted and never refused. Driven: renaming
// `.fleet-url`'s four emitting branches, and separately `.fleet-meta`'s sole
// one, each left this leg at rc=0 printing the BYTE-IDENTICAL "✓ 90 / 90 cells
// clean (330 fleet rows measured …) … 0 clipped text cells". 330 text hosts
// deleted, zero measured, zero noticed.
//
// THE STRENGTH OF THE REFUSAL IS READ OFF THE EMITTER, NOT OFF TODAY'S COUNT.
// Four of the six hosts are emitted UNCONDITIONALLY by `fleetRowHtml` —
// `.fleet-name`, the `urlHtml` branch chain (all five branches emit a
// `.fleet-url`), `.status-pill` and `.fleet-badges` — so a row that lacks one is
// a finding at the ROW. Two are conditional and a bare row owes them nothing:
//   `.fleet-meta`          `fleetMetaHtml` ends `return parts.length ? '<div
//                          class="fleet-meta">'… : "";` — a row carrying none of
//                          region/server_type/version/channel/autoupdate/verify/
//                          commit-distance renders no meta line at all.
//   `.status-pill-detail`  `statusPill` emits it as `(s.detail ? … : "")` — a
//                          state with no explanatory sentence renders none.
// Those two are refused at the CELL instead: a selector that stopped being
// emitted reds in all 90 cells, while one legitimately bare row only moves the
// printed count. Both numerator and denominator are printed per selector, so
// 5/5 falling to 3/5 is READ rather than inferred from a total that shifted.
//
// MEASURED ON THESE THREE FIXTURES TODAY: every selector below reads 330/330,
// `.fleet-meta` INCLUDED — the filing's "`.fleet-meta`=240 against rows=330, 90
// rows silently skipped every run" does NOT reproduce on these bytes. The census
// is printed so the next reader inherits the number instead of re-deriving it,
// and `optional` stays calibrated on the emitter so a fixture that does go bare
// is not mistaken for a deleted class.
const FLEET_SUB_HOSTS = [
  { sel: ".fleet-name", optional: false },
  { sel: ".fleet-url", optional: false },
  { sel: ".fleet-meta", optional: true, why: "fleetMetaHtml returns \"\" when a row carries none of region/server_type/version/channel/autoupdate/verify/commit-distance" },
  { sel: ".status-pill-detail", optional: true, why: "statusPill emits it as `(s.detail ? … : \"\")` — a state with no explanatory sentence renders none" },
  { sel: ".status-pill", optional: false },
  { sel: ".fleet-badges", optional: false },
];

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
//
// cchi-w23 — THE RAIL POPULATION IS DECLARED PER ROUTE, NEVER TALLIED AFTER THE
// FACT. The rail half of this leg used to print "36 .detail-rail .status-pill(s)
// measured on both axes" across 108 cells and refuse only the LEG-LEVEL zero
// (`railPills === 0`, after both loops close). 36 is exactly 2 routes x 9 widths
// x 2 themes: FOUR of the six routes contribute nothing, and the aggregate
// cannot tell "four routes structurally carry no rail pill" from "the rail
// stopped rendering on the two that do". The four are not one class, either —
// driven, per cell, on these bytes:
//   `rail: false`  inst-timeline / inst-metrics render `#instance-tabpanel` and
//                  NO `.detail-rail` at all; `#fleet` is a list view with none.
//   `railPill: false`  instance-detail DOES render `<aside class="detail-rail
//                  detail-rail--cards">` (app.js, the Identity/Runtime groups) —
//                  but every rung is `railRow`/`railRowCopy`/`railValue`, i.e.
//                  `<span class="v">` TEXT, so the rail exists and carries zero
//                  `.status-pill`. Only the SITE rail emits one, through
//                  `railRowHtml("Content binding", siteBindingPill(...))`.
// So each route declares BOTH facts and BOTH are asserted per cell in BOTH
// directions: a route that owes a rail and renders none reds, and a route
// declared bare that starts rendering one reds too — the FLEET_KNOWN precedent
// above ("an entry that matches NOTHING is itself a FAILURE"), because an
// annotation that cannot go stale is an annotation that forgives the next drift.
const BAND_ROUTES = [
  { name: "instance-detail", scen: "panel-overview", hash: `#instance/${INST}`, view: "view-instance", tab: "Overview", ready: ".detail-grid--instance",
    rail: true, railPill: false, railWhy: "the instance rail is `.detail-rail--cards`: railRow/railRowCopy/railValue rungs only, no .status-pill anywhere in it" },
  { name: "inst-timeline", scen: "timeline", hash: `#instance/${INST}/timeline`, view: "view-instance", tab: "Timeline", ready: "#instance-tabpanel",
    rail: false, railPill: false, railWhy: "the Timeline sub-tab renders #instance-tabpanel and no .detail-rail at all" },
  { name: "inst-metrics", scen: "metrics", hash: `#instance/${INST}/metrics`, view: "view-instance", tab: "Metrics", ready: "#instance-tabpanel",
    rail: false, railPill: false, railWhy: "the Metrics sub-tab renders #instance-tabpanel and no .detail-rail at all" },
  { name: "site-rollback", scen: "rollback", hash: `#site/${SITE}`, view: "view-site", tab: null, ready: ".detail-grid",
    rail: true, railPill: true, railWhy: null },
  { name: "site-states", scen: "site-states", hash: `#site/${SITE}`, view: "view-site", tab: null, ready: ".detail-grid",
    rail: true, railPill: true, railWhy: null },
  { name: "fleet", scen: "mixed-fleet", hash: "#fleet", view: "view-fleet", tab: null, ready: ".fleet-row",
    rail: false, railPill: false, railWhy: "#fleet is the list view — no detail rail exists on it" },
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

// cch-w14-bl-site-open-phone-overflow, criterion 4: THE SCENARIO AXIS, NOT THE
// WIDTH AXIS, IS WHAT HID THIS DEFECT. PHONE_WIDTHS above ALREADY held 320, 360,
// 375 and 390 while `a.site-open` pinned the site detail page floor at 388px on
// every iPhone in portrait, both themes, all three site fixtures. The W12 leg
// drives `#overview` and `#notifications`; W13 drives the site routes but its
// axis starts at 721. So no leg in this file had ever rendered a DETAIL route at
// a PHONE width, and the row was found by hand. This leg closes the product of
// the two axes, which is the thing that was missing.
//
// 340 IS IN THIS SET AND IS NOT IN PHONE_WIDTHS, and THE FILED BAND IS STALE.
// The row filed 320:+68 340:+48 360:+28 375:+13 388:ok. Re-derived in this
// browser by deleting the W15-S5 rule on today's bytes, the band is WIDER and
// the overhang is roughly double: 320:+126 340:+106 360:+86 375:+71 390:+56
// 412:+34 430:+16, clean from 480 up, identical in both themes. The head's live
// line now renders host AND path ("…barkpark.cloud/sites/a…"), so the floor
// moved from 388 to 446. The filed numbers were FLOORS, as the row itself said;
// they are quoted here as history, never as the pin. 340 earns its place by
// making that band readable as a ladder rather than as one failing corner.
const SITE_PHONE_WIDTHS = [320, 340, 360, 375, 390, 412, 430, 480, 495, 496, 620];
// THREE FIXTURES, AND THE THIRD IS THE CONTROL — NOT, as this leg first
// asserted, the worst case. The row named `site-binding-bound` as the fixture
// still overhanging at 390 (+5); on today's bytes it does not overhang at ANY
// width, in either theme, WITH THE FIX DELETED. It has never deployed
// (`current_deployment_id` absent -> `siteHasEverDeployed()` false — re-derive
// with `grep -n 'function siteHasEverDeployed' cloud/priv/static/app.js`),
// so its detail head emits NO live-URL line at all and there is nothing to
// overhang. That makes it the leg's attribution control: 84 findings land on the
// two fixtures that carry `.site-open` and ZERO on the one that does not, which
// is what shows the mutation measures the LINK and not phone width in general.
// Its 22 cells are still asserted — a page that starts scrolling sideways on a
// never-deployed site is a defect too, and this is the only leg that would see it.
const SITE_PHONE_SCENS = ["rollback", "site-states", "site-binding-bound"];

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
// THIS SET FLOORS AT 721 ON PURPOSE, AND THAT IS NOT A HOLE. Read alone the
// floor looks like one — cch-w22-bl-chip-guard-blind-below-721 was filed on
// exactly that reading ("a regression that re-truncates the trial chip at 320
// would be caught by no committed job"), measured against a tree where it was
// true. It is not true today: the SAME assertion (`#billing-chip` scrollWidth
// <= clientWidth, strict, both themes, both past-due scenarios) runs below 721
// over PHONE_WIDTHS in the W20-phone-band-billing-chip leg, which floors at 320
// and guards app.css's `@media (max-width: 620px)` topbar wrap. Two sets, one
// assertion, disjoint bands — 320-620 phone, 721-830 tablet. Re-derive with
// `grep -n 'W20-phone-band-billing-chip' cloud/priv/static/__preview__/overflow-guard.mjs`.
// Widening THIS set downward would duplicate that leg, not extend coverage.
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

// cchi-w18-bl-overflow-guard-server-cap-and-leaked-child (charter D208): 8000
// manufactured FALSE exit-2 refusals in a chained per-leg sweep on a loaded
// host — three serve.mjs children bound AFTER the cap and were then left
// listening, poisoning the next run through the STALE SERVER path (one bug
// manufacturing the other). Raised, env-tunable, and the value in force is
// printed in the run header so a refusal names the budget it missed.
const SERVER_CAP = Number(process.env.OVERFLOW_GUARD_SERVER_CAP || 15000);
const DEVTOOLS_CAP = 15000;
const RENDER_CAP = 12000;
const EVAL_CAP = 10000;
const BROWSER_CLOSE_CAP = 2000;
const TERM_POLL_CAP = 3000;
const KILL_POLL_CAP = 2000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── args ─────────────────────────────────────────────────────────────────────
// cch-w17-bl-overflow-guard-honours-one-defect-flag. This block used to read
// `const di = argv.indexOf("--defect")`, and `indexOf` returns the FIRST match:
// `--defect A --defect B` measured A, dropped B without a word, and printed
// `OVERFLOW GUARD PASS — A measured fixed in a real browser` at exit 0. A caller
// who asked for two legs got a green covering one, with nothing in the output
// saying so — the defect this guard exists to catch, living in the guard.
//
// EVERY occurrence is honoured now, and NOTHING in argv is ignored: a stray word
// (`--defect A B`) and a valueless `--defect` are exit-2 REFUSALS rather than
// silent drops. The reasoning for accumulating rather than refusing a repeated
// flag, and the safety argument against every live caller, are in
// ./defect-selection.mjs — which is a separate module so the parser can be
// driven WITHOUT a browser, the same reason font-pin / bringup-retry /
// ready-host-paint are siblings. The PASS line below already prints
// `requested.join(", ")`, so an accumulated run states the leg set it covers.
const argv = process.argv.slice(2);
const selection = selectDefects(argv, DEFECTS);
if (selection.refusal) {
  process.stderr.write(selection.refusal);
  process.exit(2);
}
for (const note of selection.notes) process.stdout.write(note);
const requested = selection.requested;

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
  // LAST-DITCH REAPER, on EVERY exit path. The refusal path is supposed to
  // reap through die() -> teardown(), but any path that reaches process.exit
  // without it (a thrown-through exit, a future bare exit — one shipped in a
  // draft of the okLine refusal and its leaked child squatted :4199 for the
  // NEXT run) must still not leak the server. 'exit' handlers run on
  // process.exit(); kill(0-args-sync) is all that is allowed here.
  process.once("exit", () => {
    try { serveChild.kill("SIGKILL"); } catch { /* gone */ }
    try { if (chrome) chrome.kill("SIGKILL"); } catch { /* gone */ }
  });
  process.stdout.write(
    `>> caps: server ${SERVER_CAP}ms` +
    `${process.env.OVERFLOW_GUARD_SERVER_CAP ? " (OVERFLOW_GUARD_SERVER_CAP)" : " (default)"}` +
    ` · render ${RENDER_CAP}ms · eval ${EVAL_CAP}ms · port ${PORT}\n`,
  );

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

  // 1b. THE SERVER IS THIS TREE'S SERVER (cchi-w22-bl-guard-port-contention-
  //     silently-measures-a-foreign-tree). The byte-compare below cannot tell
  //     two IDENTICAL trees apart — measured: with a concurrent worktree's
  //     serve.mjs squatting :4199, an unmodified run here passed every byte
  //     compare and printed OVERFLOW GUARD PASS while never once touching its
  //     own tree's server. Identity is asserted FIRST, from serve.mjs's
  //     /__tree endpoint; bytes are asserted after (a squatter can also be a
  //     stale same-tree server, which identity alone cannot catch).
  //     AUDITED (exit 2): both arms are ENVIRONMENT refusals, never defects.
  {
    let identity = null;
    try {
      const r = await fetch(`${BASE}/__tree`, { cache: "no-store" });
      if (r.ok) identity = await r.json();
    } catch { /* fall through to the refusal below */ }
    if (!identity || typeof identity.root !== "string") {
      return die(
        `UNIDENTIFIABLE SQUATTER on :${PORT} — the server answered /app.css but not /__tree, ` +
        `so it is an older serve.mjs or a foreign process. This guard only measures a server that ` +
        `IDENTIFIES ITSELF as this tree (${ROOT}). Kill the squatter (lsof -nP -iTCP:${PORT} -sTCP:LISTEN) or ` +
        `set OVERFLOW_GUARD_PORT to a free port.`,
      );
    }
    if (path.resolve(identity.root) !== path.resolve(ROOT)) {
      return die(
        `FOREIGN TREE on :${PORT} — the server identifies as\n` +
        `     ${identity.root} (pid ${identity.pid})\n` +
        `   while this run measures\n` +
        `     ${ROOT}\n` +
        `   Identical bytes would pass the byte-compare below, so a run against that server would ` +
        `quote ANOTHER WORKTREE's pixels as this tree's baseline. Refusing to measure.`,
      );
    }
  }

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
  //
  // D101 BRING-UP RETRY (deploy-reliability wave 8). Bounded, a FRESH profile
  // dir per attempt (the dir used to be mkdtemp'd once, so a retry would
  // re-race the same DevToolsActivePort path), and every failed attempt's
  // Chrome stderr is printed — a refusal whose cause was discarded by
  // `stdio: "ignore"` is a refusal nobody can audit.
  //
  // THE LINE THIS RETRY MUST NOT CROSS. cch-w19-bl-gr115's "do not paper over
  // the race" ruling governs exit-1 MEASURED intermittency: the browser came
  // up, the guard measured geometry, and it disagreed with itself between
  // runs. Retrying THAT would discard a real observation. This retries only
  // the exit-2 case where Chrome never came up — not one element was measured,
  // so there is no claim about any screen for a retry to hide. Everything
  // after `devPort` is a measurement and is never retried.
  let attemptSpawnError = null;
  const brought = await bringUpChrome({
    label: "overflow-guard",
    attempts: BRINGUP_ATTEMPTS,
    newProfile: () => fs.mkdtempSync(path.join(os.tmpdir(), "overflow-guard-")),
    launch: (dir) => {
      attemptSpawnError = null;
      const child = spawn(
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
          `--user-data-dir=${dir}`,
          "--remote-debugging-port=0",
          "about:blank",
        ],
        { stdio: ["ignore", "ignore", "pipe"] },
      );
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

  // AUDITED (exit 2): the browser never started, on every bounded attempt.
  // Environment, not CSS. `die` defaults to 2 — a refusal is not a defect.
  if (brought.refusal) return die(brought.refusal.message);
  chrome = brought.child;
  profile = brought.profile;
  const devPort = brought.devPort;

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
  // Successful pin executions THIS RUN. The FONT PINNED evidence lines below
  // are DERIVED from this count — printed BY the act, never narrating it
  // (cchi-w26-bl-font-pinned-evidence-narrates-instead-of-reporting: with the
  // pin probe-bypassed, the old unconditional lines kept printing the full
  // claim while the pin had not been called once).
  let fontPinRuns = 0;
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
    fontPinRuns++;
  };

  // THE RENDERED-HOST FLOOR lives in ready-host-paint.mjs — extracted so its
  // settle mechanics are provable without a browser (ready-host-paint.test.mjs)
  // and so the animating-vs-invisible discrimination has one owner. It is
  // injected with this run's browser and clock; everything it knows about WHY
  // it exists, and why it now settles rather than judging a host mid-fade-in,
  // is documented there.
  const assertReadyHostsPaint = (url, readyExpr) =>
    assertFloor({ url, readyExpr, evalJs, sleep, log: (l) => process.stdout.write(l) });

  // Navigate and poll until `readyExpr` is truthy (the SPA mounts async).
  //
  // HONESTLY BOUNDED, WITH ONE STATED RETRY (cchi-w21-bl-guard-readiness-poll-
  // nondeterministic). Three verifiers watched the old loop refuse on IDENTICAL
  // bytes ("page never became ready") while an independent Chrome found the
  // page ready, and the immediately following run passed. The old loop (a) was
  // ITERATION-counted — `w += 100` per lap — so its printed 12000ms budget was
  // nominal, not wall-clock; (b) swallowed EVERY eval error identically, so a
  // slow asset, a dead session and a genuinely unready page all wore the same
  // sentence; and (c) gave a one-off environment stall the same terminal
  // verdict as a permanent fault. Now: the budget is ELAPSED time; a first
  // timeout re-navigates ONCE and says so in the output (a flaked load is
  // retried where a human would retry it — never more than once, so a real
  // never-ready page still refuses within 2×RENDER_CAP); and the terminal
  // refusal is headlined READINESS TIMEOUT — textually disjoint from the
  // STALE SERVER refusals above, which fire before any navigation — carrying
  // the poll's own diagnosis (expr-false vs eval-threw counts, the last eval
  // error, and a final forced probe of what the page says it is).
  const nav = async (url, readyExpr) => {
    let exprFalse = 0, evalThrew = 0, lastErr = null;
    for (let attempt = 1; attempt <= 2; attempt++) {
      await cdp.send("Page.navigate", { url }, sessionId);
      const t0 = Date.now();
      while (Date.now() - t0 < RENDER_CAP) {
        let ready = false;
        // The pin is called OUTSIDE this catch on purpose: swallowing its refusal
        // as "still navigating" would spend the whole RENDER_CAP and then report
        // a never-ready page — a font fault wearing a timeout's clothes.
        try { ready = !!(await evalJs(`!!(${readyExpr})`)); if (!ready) exprFalse++; }
        catch (e) { evalThrew++; lastErr = e && e.message ? e.message : String(e); }
        if (ready) { await pinFonts(url); await assertReadyHostsPaint(url, readyExpr); return; }
        await sleep(100);
      }
      if (attempt === 1) {
        process.stdout.write(
          `   · readiness timeout after ${Date.now() - t0}ms on ${url} — re-navigating once ` +
          `(stated retry 1/1; a second timeout REFUSES at exit 2)\n`,
        );
      }
    }
    // Terminal: diagnose OUTSIDE the swallowing catch, then refuse.
    let pageSays;
    try {
      pageSays = String(await evalJs(
        `(function(){return location.href+' readyState='+document.readyState+` +
        `' bodyLen='+((document.body&&document.body.innerHTML)||'').length;})()`,
      ));
    } catch (e) { pageSays = `the final probe itself threw: ${e && e.message ? e.message : e}`; }
    throw new Error(
      `READINESS TIMEOUT — the page never became ready within ${RENDER_CAP}ms elapsed, twice (1 stated retry): ${url} (waited on: ${readyExpr})\n` +
      `   poll saw: expr-false ${exprFalse} · eval-threw ${evalThrew}${lastErr ? ` (last: ${lastErr})` : ""}\n` +
      `   page says: ${pageSays}\n` +
      `   NOT the STALE SERVER family — identity and bytes on :${PORT} matched this tree before any navigation.`,
    );
  };

  const failures = [];
  const fail = (defect, msg) => { failures.push({ defect, msg }); process.stdout.write(`   ✗ ${msg}\n`); };
  // ── okLine ARITY REFUSAL (cchi-w27-bl-okline-arity-swallows-a-leg) ────────
  // A keep-both git merge at this file's shared SUCCESS tail produces VALID
  // JS: git treats the surrounding `okLine(` and `);` lines as common context,
  // so the conflict lands INSIDE the argument list and marker-strip keep-both
  // yields either a FLAT `okLine(A, B)` — the second argument, one whole leg's
  // clean claim, is silently DISCARDED (rc 0 on node --check, on import, at
  // runtime) — or a NESTED `okLine(A, okLine(B))`, which prints the two slices
  // in REVERSED order and rides the inner call's return value in as a bogus
  // second argument. Both shapes now REFUSE at the first corrupted call:
  // exactly one argument is the contract, anything else is the merge defect by
  // name, exit 2 (a refusal to measure — the instrument's own bytes are
  // corrupt, so no clean claim it prints can be trusted).
  //
  // HONEST LIMIT: this is a RUNTIME check. It fires in CI because
  // console-harness.yml runs the guard with no --defect flag (every leg's
  // success tail executes on a green run) — but a swallow inside a
  // FAILURE-gated okLine call is invisible on a green run, and a static
  // scanner is refuted: ${} interpolation inside template literals defeats
  // naive paren/comma depth tracking (34 false positives over 57 clean calls).
  const okLine = (...args) => {
    if (args.length !== 1) {
      process.stderr.write(
        `!! GUARD (exit 2): okLine called with ${args.length} argument(s) — it takes exactly ONE. ` +
        `This is the keep-both MERGE DEFECT this refusal exists to catch: a conflict resolved inside ` +
        `okLine's argument list parses as valid JS while silently discarding a leg's clean claim ` +
        `(flat okLine(A, B)) or printing two legs reversed (nested okLine(A, okLine(B))). ` +
        `Re-resolve the merge at this call site by hand. First argument begins: "${String(args[0]).slice(0, 120)}"\n`,
      );
      // THROW, never process.exit: a bare exit here LEAKS the static-server
      // child (measured — a squatter on :4199 survived the first draft of this
      // refusal and made the NEXT run refuse as a foreign tree). The tail
      // catch routes this through die(), which tears down server + browser
      // before exiting 2.
      throw new Error("okLine arity refusal (keep-both merge defect) — the named call is above");
    }
    return process.stdout.write(`   ✓ ${args[0]}\n`);
  };
  // The FONT PINNED sentence is EARNED, never narrated: it prints the number
  // of successful pinFonts() executions this run, and when that number is
  // zero it WITHHOLDS the claim — under a `!`, never a ✓ — instead of
  // printing it.
  const fontPinnedEvidence = (tail) => {
    if (fontPinRuns > 0) {
      okLine(
        `FONT PINNED ${fontPinRuns}x THIS RUN (D218, paid by cch-w22-s1; count measured in pinFonts, not narrated): ` +
        `nav() load()s every declared @font-face, awaits document.fonts.ready and check()s each face before ` +
        `these px are read — a missing face is exit 2. ${tail}`,
      );
    } else {
      process.stdout.write(
        `   ! FONT PIN NOT EXECUTED THIS RUN (0 successful pinFonts() runs) — the FONT PINNED claim is ` +
        `WITHHELD: nothing certifies which faces these px were read under. ${tail}\n`,
      );
    }
  };

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
            // EVERY WIDTH IS ASSERTED STRICTLY. The `+ 1` that used to sit on
            // the >740 side was an UNDECLARED epsilon — no name, no cap, no
            // marker, none of the four properties the retired band-A residual
            // carried — and it once let 740/dark's real 168/167 read as whole
            // (cchi-w18-bl-overflow-guard-chip-epsilon-undeclared, D211). The
            // pixel it forgave was real sub-pixel geometry, not rasterisation:
            // the dark theme-toggle painted ~2px wider than light and squeezed
            // the chip by ~0.44px, which integer scrollWidth/clientWidth
            // report as a whole pixel; OVERFLOW_GUARD_CLASSIC_SCROLLBARS=1
            // reproduced every cell identically. On current bytes the W20-S8
            // 621-740 block and the 830 tighten land ALL 68 cells at 168/168
            // (full intrinsic width, measured both themes), so the epsilon
            // forgave NOTHING and could only hide a one-pixel regression. A
            // future sub-pixel residual must arrive as a NAMED constant with a
            // reason, a cap and a printed marker on every cell it forgives —
            // the band-A shape — never as `+ 1` on the comparison.
            const cut = chip.sw > chip.cw;
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

    // ── W20: THE PHONE BAND'S MONEY MESSAGE — the question PHONE_WIDTHS never
    //    asked (cchi-w20-bl-phone-band-billing-chip-unguarded). GR108 above
    //    asserts #billing-chip across CHIP_WIDTHS, which FLOORS at 721; below
    //    that the chip is kept whole by ONE css block — app.css's
    //    `@media (max-width: 620px)` topbar wrap (`.topbar { flex-wrap: wrap }`
    //    + `.billing-chip { flex: 0 0 auto }`, the W19-S2 block) — and until
    //    this leg by NOTHING ELSE: reverting that block takes the past-due
    //    money message back to 168/85 at 320 while every committed instrument
    //    stays green. The app.css banner states the hole in PROSE ("PHONE_WIDTHS
    //    never asserts #billing-chip"); a comment is not a guard. Anchored to the
    //    SELECTORS of that block, never its line numbers — the filing row's own
    //    :3963 cite had drifted ~850 lines by build time.
    //
    //    STRICT sw <= cw, no epsilon: at every one of the ten PHONE_WIDTHS the
    //    wrap block applies (620 sits ON the max-width: 620px boundary), the
    //    chip holds its full intrinsic width on its own wrapped line, so a
    //    pixel of tolerance could only hide a regression. And the chip must
    //    PAINT: a display:none'd chip reads 0/0 and would sail through the
    //    scroll assertion — hidden is not whole, so a 0px rect is a finding,
    //    not a skip.
    //
    //    THE COUNT IS PRINTED, NOT IMPLIED (cch-w22-bl-chip-guard-blind-below-721,
    //    criterion 3). The ✓ line below used to read "chip whole at all 10 phone
    //    widths 320-620" off `cut === 0` alone — and `cut` is only incremented on
    //    cells the read actually REACHED. A row whose chip went MISSING at nine of
    //    ten widths therefore printed that full-band sentence beside its own nine
    //    ✗ lines: the same "green sentence next to its own failures" shape the
    //    GR108 leg above was corrected for. The claim is now gated on
    //    rowMeasured === PHONE_WIDTHS.length, a partial row prints a `!` naming
    //    what it could NOT reach, and the leg closes with an unconditional
    //    MEASURED n of N line so a reader never has to infer the denominator.
    if (requested.includes("W20-phone-band-billing-chip")) {
      const D = "W20-phone-band-billing-chip";
      const PHONE_SCENS = ["billing-past-due", "overview-past-due"];
      const phoneCells = PHONE_SCENS.length * 2 * PHONE_WIDTHS.length;
      process.stdout.write(`\n${D} — ${PHONE_WIDTHS.length} phone widths x 2 themes x ${PHONE_SCENS.length} past-due scenarios = ${phoneCells} cells\n`);
      let measured = 0;
      for (const scen of PHONE_SCENS) {
        for (const theme of ["light", "dark"]) {
          await setViewport(390);
          await nav(
            `${BASE}/?scen=${scen}&theme=${theme}`,
            `document.querySelector('.topbar') && (function(){var c=document.getElementById('billing-chip');return c && !c.hidden;})()`,
          );
          const row = [];
          let cut = 0, rowMeasured = 0;
          for (const width of PHONE_WIDTHS) {
            await setViewport(width);
            const chip = await evalJs(
              `(function(){var c=document.getElementById('billing-chip');if(!c)return null;` +
              `var r=c.getBoundingClientRect();` +
              `return {sw:c.scrollWidth, cw:c.clientWidth, w:Math.round(r.width*100)/100, text:c.textContent};})()`,
            );
            if (!chip) { fail(D, `${scen}/${theme}@${width}: #billing-chip MISSING — the readiness gate saw it and this read did not`); row.push(`${width}:missing`); continue; }
            if (chip.w <= 0) { fail(D, `${scen}/${theme}@${width}: #billing-chip paints a ${chip.w}px rect — hidden is not whole ("${chip.text}")`); row.push(`${width}:0px`); continue; }
            measured++;
            rowMeasured++;
            const over = chip.sw > chip.cw;
            if (over) { cut++; fail(D, `${scen}/${theme}@${width}: #billing-chip TRUNCATED — scrollWidth ${chip.sw} > clientWidth ${chip.cw} ("${chip.text}")`); }
            row.push(`${width}:${chip.sw}/${chip.cw}${over ? "!" : ""}`);
          }
          process.stdout.write(`   chip ${scen}/${theme}  ${row.join(" ")}\n`);
          if (!cut && rowMeasured === PHONE_WIDTHS.length) {
            okLine(`${scen}/${theme}: chip whole at all ${PHONE_WIDTHS.length} phone widths ${PHONE_WIDTHS[0]}-${PHONE_WIDTHS[PHONE_WIDTHS.length - 1]} (${rowMeasured}/${PHONE_WIDTHS.length} cells MEASURED)`);
          } else if (!cut) {
            // Not a ✓: nothing was cut among the cells this row could READ, but
            // the rest are ✗ above and the band is uncertified for them.
            process.stdout.write(
              `   ! ${scen}/${theme}: no cut among the ${rowMeasured} of ${PHONE_WIDTHS.length} widths this row could MEASURE — ` +
              `the remaining ${PHONE_WIDTHS.length - rowMeasured} are ✗ above and this band is NOT certified\n`,
            );
          }
        }
      }
      // The denominator, printed and not inferred. A leg whose population
      // shrank to a handful of cells reads as a pass on the ✓ lines alone;
      // this line is where that shows.
      process.stdout.write(
        `   MEASURED ${measured} of ${phoneCells} #billing-chip cells ` +
        `(${PHONE_SCENS.length} scenarios x ${PHONE_WIDTHS.length} widths x 2 themes) — ` +
        `the ✓ lines above are claims about THESE cells and no others\n`,
      );
      // A leg that measured nothing certifies nothing — zero cells is a RED,
      // never a tick (the filing criterion's own wording: "FAILS on a zero
      // measured count"). The MISSING/0px arms above fail per-cell; this arm
      // is the backstop that cannot be satisfied by an empty loop.
      if (measured === 0) fail(D, `#billing-chip measured in ZERO cells across 2 scenarios x ${PHONE_WIDTHS.length} widths x 2 themes — the leg no longer reaches the population it certifies`);
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
      const railOwed = BAND_ROUTES.filter((r) => r.railPill).length * BAND_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${BAND_ROUTES.length} routes x ${BAND_WIDTHS.length} widths x 2 themes` +
        ` (${BAND_ROUTES.length * BAND_WIDTHS.length * 2} cells) + .detail-rail .status-pill on both axes` +
        ` (${BAND_ROUTES.filter((r) => r.railPill).length} of the ${BAND_ROUTES.length} routes owe a rail pill — ` +
        `${railOwed} cells — and every cell's rail, pill and label population is asserted, not tallied)\n`,
      );
      let cells = 0, offenders = 0, misrouted = 0, railPills = 0, railBad = 0;
      // cchi-w23: the sub-populations this leg ASSERTS ON, counted so a zero can
      // be refused and printed rather than inferred from a shrinking total.
      let railsSeen = 0, railLabels = 0;
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
              // cchi-w23 SECOND ORDER: whether the LABEL sub-host exists at all
              // is now carried out of the browser. `lsw`/`lcw`/`lh` all degrade
              // to 0 through the ternaries when `l` is null, and `0 > 0` is
              // false — so a rail whose label element vanished measured NOTHING
              // on half this leg's four rail assertions while printing
              // "measured on both axes". The flag is what makes that a finding.
              `    hasLabel:!!l,` +
              `    lsw:l?l.scrollWidth:0,lcw:l?l.clientWidth:0,t:(p.textContent||'').slice(0,40)};});` +
              `return {sw:d.scrollWidth, cw:d.clientWidth, view:v?v.id:'none', rp:rp,` +
              ` rails:document.querySelectorAll('.detail-rail').length,` +
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
            // (3) THE RAIL'S POPULATION, PER CELL AND IN BOTH DIRECTIONS
            // (cchi-w23). The leg-level `railPills === 0` below fires only
            // after both loops close, so it could not tell 36 pills from two
            // routes apart from 36 pills that should have been 108. Each route
            // declares what it owes at BAND_ROUTES and every cell is held to it.
            railsSeen += m.rails;
            const cellPills = m.rp.length;
            if (r.rail && m.rails === 0) {
              fail(D, `${r.name}/${theme}@${width}: zero \`.detail-rail\` in a route declared to render one — the rail stopped rendering, so every rail assertion below measured nothing. This is not a pass.`);
            } else if (!r.rail && m.rails > 0) {
              fail(D, `${r.name}/${theme}@${width}: ${m.rails} \`.detail-rail\` on a route declared to render NONE (${r.railWhy}) — the annotation at BAND_ROUTES has gone stale. Update it rather than letting an unasserted rail ride along.`);
            }
            if (r.railPill && cellPills === 0) {
              fail(D, `${r.name}/${theme}@${width}: zero \`.detail-rail .status-pill\` in a route declared to carry one — "0 outside their own chip" is true of an empty set, which is not what this leg claims. This is not a pass.`);
            } else if (!r.railPill && cellPills > 0) {
              fail(D, `${r.name}/${theme}@${width}: ${cellPills} \`.detail-rail .status-pill\` on a route declared to carry none (${r.railWhy}) — the annotation at BAND_ROUTES has gone stale; this leg's printed rail total silently changed meaning.`);
            }
            // (4) THE RAIL'S PILLS — element geometry, both axes. Counted
            // separately from `cells` so this leg's 108/108 stays 108/108.
            for (const p of m.rp) {
              railPills++;
              // SECOND ORDER, THE `withBtns === 0` SHAPE: two of the four
              // assertions below read the LABEL, and their ternaries degrade a
              // missing label to `0 > 0` — silently false. A pill without its
              // label is therefore HALF-MEASURED, and half-measured is a
              // finding here, not a skip.
              if (!p.hasLabel) {
                fail(D, `${r.name}/${theme}@${width} .detail-rail .status-pill: no \`.status-pill-label\` inside it — \`p.lsw > p.lcw\` and \`p.lh > p.ph + 0.5\` both collapse to \`0 > 0\` through their own ternaries, so HALF this leg's four rail assertions measured nothing while the ok-line still said "on both axes"`);
              } else {
                railLabels++;
              }
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
      // a pill this leg would score 0 rail defects and read as a pass. The
      // per-cell refusals above make this one a backstop rather than the only
      // net — it is kept because it is the one line that survives a future edit
      // that drops every `railPill: true` from BAND_ROUTES.
      if (railPills === 0) {
        fail(D, `zero .detail-rail .status-pill measured across ${cells} cells — the rail pill stopped rendering, so its assertions measured nothing. This is not a pass.`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${railPills} .detail-rail .status-pill(s) measured on both axes — ${railPills}/${railOwed} of the cells that OWE one ` +
          `(${BAND_ROUTES.filter((r) => r.railPill).map((r) => r.name).join(" + ")} x ${BAND_WIDTHS.length} widths x 2 themes), ` +
          `${railLabels} of them carrying a \`.status-pill-label\`, so the label pair (\`lsw > lcw\`, \`lh > ph\`) measured ${railLabels} boxes ` +
          `and not \`0 > 0\`; ${railBad} outside their own chip`,
        );
        okLine(
          `${railsSeen} \`.detail-rail\` across ${cells} cells, DERIVED per route rather than tallied: the other ` +
          `${BAND_ROUTES.filter((r) => !r.railPill).length} routes are declared bare and asserted bare per cell — ` +
          BAND_ROUTES.filter((r) => !r.railPill).map((r) => `${r.name} (${r.railWhy})`).join("; ") +
          `. A route that stops rendering its rail, and a bare route that starts rendering one, both RED here instead of ` +
          `moving the printed total in silence`,
        );
        okLine(
          `${cells} / ${cells} cells clean across ${BAND_WIDTHS[0]}-${BAND_WIDTHS[BAND_WIDTHS.length - 1]}` +
          ` (769/899 are the band edges, 900/1024 the controls above it); ${misrouted} misrouted;` +
          ` no exemptions — #fleet's W13 residual was paid by W14-S3 and its pin is gone`,
        );
      }
    }

    // ── cch-w14-bl-site-open-phone-overflow (criterion 4): SITE DETAIL x PHONE ─
    //    The CSS half of this row shipped in W15-S5 (`.fleet-url .site-open`
    //    drops nowrap and wraps on `overflow-wrap: break-word`). This is the
    //    half that keeps it: an instrument that renders a site DETAIL route at a
    //    PHONE width, which no leg in this file has ever done.
    //
    //    IT ASSERTS TWO THINGS THAT A SINGLE REMEDY CANNOT BUY BOTH OF. A page
    //    that does not scroll sideways is trivially purchasable by clipping the
    //    URL — and the row's own criterion 2 already ruled that out ("the remedy
    //    wraps or truncates with a CUE rather than clipping silently", and WRAP
    //    is the branch that was taken, because a person reads that line to learn
    //    WHERE the site lives). So the page geometry and the link's own
    //    box-vs-content are asserted independently, and the second one is
    //    honestly VACUOUS TODAY: `.site-open` is an inline `<a>`, so its
    //    scrollWidth/clientWidth both read 0 and the comparison cannot fire.
    //    That is the point — it becomes live at exactly the moment someone gives
    //    it `display:block` + `overflow:hidden` to buy the page-level green, and
    //    the measured pair is PRINTED per fixture so no reader mistakes 0/0 for
    //    a measurement of something.
    if (requested.includes("W14-site-detail-phone-band")) {
      const D = "W14-site-detail-phone-band";
      // ROUTES DERIVED, NEVER TRANSCRIBED (charter D228): `?scen=` alone does
      // NOT route, and a transcribed uuid that drifts renders #overview three
      // times and prints an entirely phantom table.
      const { SCENARIOS } = await import("./scenarios.mjs");
      const routes = [];
      for (const key of SITE_PHONE_SCENS) {
        const sc = SCENARIOS[key];
        if (!sc || typeof sc.deepLink !== "string" || !sc.deepLink.startsWith("#site/")) {
          return die(`${D}: SCENARIOS["${key}"] no longer carries a #site/ deepLink — the detail route this leg certifies cannot be reached, so every cell below it would measure #overview`);
        }
        // THE POPULATION IS DERIVED TOO, not counted after the fact. `.site-open`
        // appears in the detail head's `.fleet-url` sub-line only when
        // `siteHasEverDeployed(site)` — `!!s.current_deployment_id`, re-derived with
        // `grep -n 'function siteHasEverDeployed' cloud/priv/static/app.js` —
        // so whether this fixture owes a link is a property of the FIXTURE. A
        // leg that merely tallied what it found would print a happy total while
        // a fixture quietly stopped rendering the element the row is named for.
        const id = sc.deepLink.slice("#site/".length);
        const sites = sc.data && Array.isArray(sc.data.sites) ? sc.data.sites : [];
        const site = sites.find((x) => x && x.id === id);
        if (!site) {
          return die(`${D}: SCENARIOS["${key}"].deepLink points at site ${id}, which is not in its own \`data.sites\` — the fixture and its deep link have drifted apart`);
        }
        routes.push({ name: key, hash: sc.deepLink, owesLink: !!site.current_deployment_id });
      }
      process.stdout.write(
        `\n${D} — ${routes.length} site fixtures x ${SITE_PHONE_WIDTHS.length} phone widths x 2 themes` +
        ` (${routes.length * SITE_PHONE_WIDTHS.length * 2} cells)\n`,
      );
      let cells = 0, misrouted = 0, links = 0, linkBoxed = 0, wrapped = 0;
      for (const r of routes) {
        for (const theme of ["light", "dark"]) {
          // Enter ABOVE the band, like W13: a route that only renders at one
          // width must not read as a route that renders everywhere.
          await setViewport(900);
          await nav(
            `${BASE}/?scen=${r.name}&theme=${theme}${r.hash}`,
            `document.querySelector('.detail-head .fleet-url') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-site';})()`,
          );
          const row = [];
          for (const width of SITE_PHONE_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;var R=function(v){return Math.round(v*100)/100;};` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              `var u=document.querySelector('.detail-head .fleet-url');` +
              `var as=[].slice.call(document.querySelectorAll('.detail-head .fleet-url .site-open')).map(function(a){` +
              `  var rr=a.getBoundingClientRect();var cs=getComputedStyle(a);` +
              `  return {right:R(rr.right),w:R(rr.width),lines:a.getClientRects().length,` +
              `    sw:a.scrollWidth,cw:a.clientWidth,ws:cs.whiteSpace,ov:cs.textOverflow,` +
              `    ow:cs.overflowWrap,t:(a.textContent||'').trim().slice(0,48)};});` +
              `return {sw:d.scrollWidth,cw:d.clientWidth,view:v?v.id:'none',` +
              ` theme:d.getAttribute('data-theme'),` +
              ` urect:u?R(u.getBoundingClientRect().right):null,` +
              ` usw:u?u.scrollWidth:null,ucw:u?u.clientWidth:null,as:as};})()`,
            );
            cells++;
            // (1) THE ROUTE. Without this every number below is phantom.
            if (m.view !== "view-site") {
              misrouted++;
              fail(D, `${r.name}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-site" — the hash did not route, so nothing below this line measures a site detail page`);
            }
            if (m.theme !== theme) fail(D, `${r.name}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // (2) THE PAGE. This is the row's own defect: 320:+68 340:+48
            //     360:+28 375:+13, and 390:+5 on site-binding-bound.
            const overhang = m.sw - m.cw;
            if (overhang > 0) {
              fail(D, `${r.name}/${theme}@${width}#site: documentElement scrollWidth ${m.sw} > clientWidth ${m.cw} — ${overhang}px of the site detail page is off-screen at rest, with no cue, on a phone in portrait`);
            }
            // (3) THE HOST LINE'S OWN BOX. A sub-line that overhangs its own
            //     container while the PAGE stays put is the same defect one
            //     `overflow:hidden` later.
            if (m.usw !== null && m.usw > m.ucw + 1) {
              fail(D, `${r.name}/${theme}@${width}#site: .detail-head .fleet-url scrollWidth ${m.usw} > clientWidth ${m.ucw} — the head's sub-line hides ${m.usw - m.ucw}px of itself`);
            }
            // (4) THE LINK IS THERE, OR IS DERIVABLY ABSENT. Asserted per cell
            //     against the fixture's own `current_deployment_id`, so an
            //     element that stops rendering reds instead of shrinking this
            //     leg's population in silence.
            const wantLinks = r.owesLink ? 1 : 0;
            if (m.as.length !== wantLinks) {
              fail(D, `${r.name}/${theme}@${width}#site: ${m.as.length} .detail-head .fleet-url .site-open, expected ${wantLinks} — the fixture's site ${r.owesLink ? "HAS" : "has NO"} current_deployment_id, so siteHasEverDeployed says the head ${r.owesLink ? "must" : "must not"} carry a live-URL line`);
            }
            // (5) THE LINK'S GEOMETRY. Bounded by the viewport, and NOT bought
            //     by clipping.
            for (const a of m.as) {
              links++;
              if (a.lines > 1) wrapped++;
              if (a.cw > 0) linkBoxed++;
              if (a.right > m.cw + 1) {
                fail(D, `${r.name}/${theme}@${width}#site: .fleet-url .site-open right edge ${a.right} is past the ${m.cw}px viewport — "${a.t}" paints off-screen (white-space:${a.ws}, overflow-wrap:${a.ow}, ${a.lines} line box(es))`);
              }
              if (a.sw > a.cw + 1) {
                fail(D, `${r.name}/${theme}@${width}#site: .fleet-url .site-open scrollWidth ${a.sw} > clientWidth ${a.cw} — the live URL is CLIPPED, not wrapped. This row's criterion 2 took the wrap branch on purpose: a person reads this line to learn where the site lives, so a silent clip trades a scrollbar for a lie`);
              }
            }
            row.push(`${width}:${m.sw}${overhang > 0 ? "!" : ""}`);
          }
          const n = row.length;
          process.stdout.write(`   ${r.name}/${theme}  ${row.join(" ")}\n`);
          if (n !== SITE_PHONE_WIDTHS.length) fail(D, `${r.name}/${theme}: ${n} of ${SITE_PHONE_WIDTHS.length} widths measured`);
        }
      }
      // AN EMPTY POPULATION IS NOT A CLEAN ONE. If the head stops emitting the
      // live URL, every assertion in (4) measures nothing and this leg would
      // print a tick over the element the row is named after.
      if (links === 0) {
        fail(D, `zero .detail-head .fleet-url .site-open measured across ${cells} cells — the live-URL line stopped rendering, so the element this row is named after was never measured. This is not a pass.`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean across ${SITE_PHONE_WIDTHS[0]}-${SITE_PHONE_WIDTHS[SITE_PHONE_WIDTHS.length - 1]}` +
          ` on ${routes.length} site fixtures x 2 themes; ${misrouted} misrouted`,
        );
        const bearers = routes.filter((x) => x.owesLink).map((x) => x.name);
        const controls = routes.filter((x) => !x.owesLink).map((x) => x.name);
        okLine(
          `${links} .fleet-url .site-open link(s) measured on ${bearers.length} fixture(s) (${bearers.join(", ") || "none"});` +
          ` ${controls.length} never-deployed control(s) (${controls.join(", ") || "none"}) assert ZERO links and are page-asserted anyway`,
        );
        okLine(
          `${wrapped} of ${links} link(s) render on more than one line box (the wrap remedy doing its job);` +
          ` ${linkBoxed} with a non-zero clientWidth — the CLIP assertion is inert while that count is 0` +
          ` and goes live the moment the link stops being an inline box, which is exactly how a page-level green would be bought`,
        );
      }
    }

    // ── cch-w29-bl: THE RAIL'S *LIVE* FOOTER, WHICH EVERY LEG ABOVE IS BLIND TO
    //    W25's leg measures `.deploy-rail-fail`; the W14 leg above measures the
    //    detail head's `.fleet-url .site-open`. `deployRailHtml` emits a THIRD
    //    thing neither of them can see — `.deploy-rail-live`, the copyable site
    //    URL once every stage is done — and until `site-deploy-rail-live` landed
    //    beside this leg, NO scenario in this harness produced it at any width.
    //    That is the whole reason the defect survived: #8743 dropped the base
    //    `white-space: nowrap` for `.fleet-url .site-open` and left the rail's
    //    twin emit of the SAME class untouched, and both instruments went green
    //    because neither had a fixture in the live-footer state.
    //
    //    THE PAID TWIN IS THE IN-PAGE CONTROL, NOT A SECOND RUN. The fixture's
    //    site carries `current_deployment_id`, so `siteHasEverDeployed` makes
    //    the detail head render the SAME derived URL through the selector #8743
    //    already paid. Every cell reads both anchors and asserts they hold the
    //    same string first — a comparison between two different strings would
    //    be a table, not evidence. On origin/main bytes that pair reads, at 320
    //    light: rail `white-space: nowrap`, 1 line box, `.deploy-rail-live`
    //    scrollWidth 532 against clientWidth 320; head `normal`, 3 line boxes,
    //    `.fleet-url` 320/320. Same page, same string, same width.
    //
    //    FOUR ASSERTIONS, AND NO ONE REMEDY BUYS ALL FOUR.
    //      (a) the anchor's computed `white-space` is a WRAPPING value. This is
    //          the one a `min-width: 0` or an `overflow: hidden` cannot buy, and
    //          the one that reds the moment the CSS is reverted.
    //      (b) the footer's own box holds its glyphs — `.deploy-rail-live`
    //          scrollWidth == clientWidth. A page-level green alone is buyable
    //          by clipping the URL inside a box that still paints past its
    //          border (W25's leg exists for the same reason).
    //      (c) the PAGE does not scroll sideways, asserted on BOTH
    //          `document.body.scrollWidth` (the row's own criterion) and
    //          `documentElement`. The row measured body 551 against a 320
    //          viewport in the real ancestry — `.detail-grid > .detail-main >
    //          section.deploy-rail`, which is where this fixture mounts it.
    //      (d) IT WRAPPED, IT WAS NOT TRUNCATED. The URL's intrinsic one-line
    //          width is MEASURED at the wide entry width and carried in, so any
    //          cell whose container is narrower than that must show more than
    //          one line box. A `text-overflow` remedy scores clean on (a)-(c)
    //          and reds here — which is deliberate: a person reads this line to
    //          learn where their site now lives, so an ellipsis trades a
    //          scrollbar for a lie (the same branch cch-w14 took for the twin).
    //
    //    THE COPY BUTTON IS MEASURED TOO. `.deploy-rail-live` is a flex row and
    //    the anchor's unbreakable run pushed its `flex: 0 0 auto` sibling off
    //    the screen; a remedy that fixes the text and leaves the control
    //    unreachable has not finished the journey.
    if (requested.includes("W29-deploy-rail-live-url-wrap")) {
      const D = "W29-deploy-rail-live-url-wrap";
      // BLOCK-SCOPED (D247). The phone band the row is about, plus 480/620 as
      // measured CONTROLS above it — on origin/main bytes the nowrap overhangs
      // at every one of them, so the "clean above the band" reading has to be
      // earned by the fix rather than assumed by the axis.
      const LIVE_WIDTHS = [320, 340, 360, 375, 390, 412, 430, 480, 620];
      const { SCENARIOS } = await import("./scenarios.mjs");
      const sc = SCENARIOS["site-deploy-rail-live"];
      // THE ROUTE AND THE URL ARE DERIVED, NEVER TRANSCRIBED (D228): `?scen=`
      // alone does not route, and a pasted uuid rots into "the sites list
      // rendered instead" while printing a full, plausible table.
      if (!sc || typeof sc.deepLink !== "string" || !sc.deepLink.startsWith("#site/")
          || !sc.data || !Array.isArray(sc.data.sites) || !sc.data.sites.length) {
        return die(`${D}: SCENARIOS["site-deploy-rail-live"] no longer carries a #site/ deepLink and a site — the live-footer route cannot be reached, so nothing below would measure the deploy rail`);
      }
      const liveSite = sc.data.sites.find((s) => s && s.id === sc.deepLink.slice("#site/".length));
      if (!liveSite) {
        return die(`${D}: SCENARIOS["site-deploy-rail-live"].deepLink points at a site that is not in its own data.sites — the fixture and its deep link have drifted apart`);
      }
      // The head's twin anchor is a property of the FIXTURE (siteHasEverDeployed
      // is `!!s.current_deployment_id` — re-derive with `grep -n 'function
      // siteHasEverDeployed' cloud/priv/static/app.js`). Without it this leg
      // still measures the rail, but it loses the control that makes the pair
      // a comparison, so its absence is stated rather than silently tolerated.
      if (!liveSite.current_deployment_id) {
        return die(`${D}: the fixture's site no longer carries current_deployment_id, so the detail head renders no \`.fleet-url .site-open\` — this leg's paid-twin control is gone and its central comparison would be against nothing`);
      }
      const READY =
        `document.querySelector('.deploy-rail-live .site-open') && ` +
        `document.querySelector('.detail-head .fleet-url .site-open') && ` +
        `(function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-site';})()`;
      const READ =
        `(function(){var d=document.documentElement;var R=function(v){return Math.round(v*100)/100;};` +
        `var v=document.querySelector('section.view:not([hidden])');` +
        // EVERY anchor of each kind, never a pinned one (D228's fifth clause):
        // querySelector singular cannot tell a footer that rendered nothing
        // from a footer that rendered a clean box.
        // LINE BOXES COME FROM A RANGE, NOT FROM `a.getClientRects()`, and the
        // difference is the whole arm (d). `.deploy-rail-live` is `display:
        // flex`, so its `.site-open` child is a FLEX ITEM — a block box with
        // exactly ONE client rect at every width and a width the flex algorithm
        // resolved, not the text's. Reading `getClientRects().length` there
        // returns 1 for wrapped and unwrapped text alike (measured: 1L at every
        // width in both states) and `getBoundingClientRect().width` returns the
        // COLUMN, not the string. A Range over the anchor's contents reports one
        // rect per LINE BOX and a union width that is the text's own — which is
        // what the wrap/truncate question is actually about. The head's twin is
        // an inline `<a>` where the two agree; it is read the same way anyway so
        // the control and the subject are measured by one instrument.
        `var lb=function(el){var g=document.createRange();g.selectNodeContents(el);` +
        `  var rs=[].slice.call(g.getClientRects());if(g.detach)g.detach();` +
        `  if(!rs.length)return {n:0,w:0,right:0};` +
        `  var L=Math.min.apply(null,rs.map(function(x){return x.left;}));` +
        `  var Rt=Math.max.apply(null,rs.map(function(x){return x.right;}));` +
        `  return {n:rs.length,w:R(Rt-L),right:R(Rt)};};` +
        // THE INTRINSIC ONE-LINE WIDTH, MEASURED PER CELL AND OUT OF FLOW.
        // Arm (d) needs "how wide would this string be if it did not wrap", and
        // once the fix ships there is no width left at which the live footer
        // renders it unwrapped (measured: it already wraps at the 900px entry),
        // so it cannot be read from an entry cell. A clone of the anchor is
        // appended INSIDE the same `.deploy-rail-live` — so it inherits the very
        // rule under measurement, `--mono` and 13px included — positioned
        // absolutely (an out-of-flow box is not a flex item, so it is
        // shrink-to-fit rather than flex-resolved) with `white-space: nowrap`
        // forced. It is removed in the same expression, and `residue` below is
        // asserted so a probe that survived can never be measured as content.
        `var oneLine=function(a,box){if(!box)return null;` +
        `  var c=a.cloneNode(true);c.setAttribute('data-w29-probe','1');` +
        `  c.style.cssText='position:absolute;left:-99999px;top:0;width:auto;max-width:none;white-space:nowrap;';` +
        `  box.appendChild(c);var w=R(c.getBoundingClientRect().width);box.removeChild(c);return w;};` +
        `var read=function(sel,boxSel){return [].slice.call(document.querySelectorAll(sel)).map(function(a){` +
        `  var cs=getComputedStyle(a);var lr=lb(a);` +
        `  var box=a.closest(boxSel);var bcs=box?getComputedStyle(box):null;` +
        `  return {right:lr.right,w:lr.w,lines:lr.n,one:oneLine(a,box),` +
        `    ws:cs.whiteSpace,ow:cs.overflowWrap,wb:cs.wordBreak,ov:cs.textOverflow,` +
        `    bsw:box?box.scrollWidth:null,bcw:box?box.clientWidth:null,` +
        `    box:box?(box.className||'?').toString():null,bov:bcs?bcs.overflowX:null,` +
        `    t:(a.textContent||'').replace(/\\u00a0/g,' ').trim()};});};` +
        `var btn=document.querySelector('.deploy-rail-live .copy-btn');` +
        // The real ancestry the row names, asserted rather than assumed: a rail
        // that stopped mounting inside .detail-main would make every number
        // below a measurement of some other screen.
        `var rail=document.querySelector('.detail-grid > .detail-main > #deploy-rail-slot > section.deploy-rail');` +
        `return {sw:d.scrollWidth,cw:d.clientWidth,bsw:document.body.scrollWidth,bcw:document.body.clientWidth,` +
        ` residue:document.querySelectorAll('[data-w29-probe]').length,` +
        ` view:v?v.id:'none',theme:d.getAttribute('data-theme'),ancestry:!!rail,` +
        ` btnRight:btn?R(btn.getBoundingClientRect().right):null,` +
        ` live:read('.deploy-rail-live .site-open','.deploy-rail-live'),` +
        ` head:read('.detail-head .fleet-url .site-open','.fleet-url')};})()`;
      process.stdout.write(
        `\n${D} — the rail's LIVE footer x ${LIVE_WIDTHS.length} phone/control widths x 2 themes` +
        ` (${LIVE_WIDTHS.length * 2} cells); the head's already-paid \`.fleet-url .site-open\` twin is the IN-PAGE control,` +
        ` and PAGE (body + documentElement), FOOTER BOX, ANCHOR WRAP and COPY BUTTON are asserted in every cell\n`,
      );
      let cells = 0, liveSeen = 0, headSeen = 0, wrapped = 0, boxOver = 0, pageOver = 0, nowrapSeen = 0;
      let intrinsic = null;
      for (const theme of ["light", "dark"]) {
        // Enter WIDE. The rail mounts once, on load, off the deployments fetch;
        // entering narrow would hide a footer that only renders on a phone
        // layout, and the intrinsic width below has to be read where the URL
        // still fits on one line.
        await setViewport(900);
        await nav(`${BASE}/?scen=site-deploy-rail-live&theme=${theme}${sc.deepLink}`, READY);
        // (0) THE ENTRY READ IS AN ANTI-VACUITY CHECK, not a measurement kept:
        // it proves the footer is on the page and that the out-of-flow probe
        // that feeds arm (d) actually returns a width, BEFORE any cell trusts
        // one. The threshold itself is re-derived in every cell.
        const wide = await evalJs(READ);
        if (!wide.live.length || wide.live[0].one === null) {
          return die(`${D}: the 900px entry rendered ${wide.live.length} live-footer anchor(s) and no intrinsic width — the WRAP-not-TRUNCATE arm below would have no derived threshold, so this leg would certify a page it could not read`);
        }
        const row = [];
        for (const width of LIVE_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(READ);
          cells++;
          // (1) THE ROUTE + THE ANCESTRY. Without these every number is phantom.
          if (m.view !== "view-site") {
            fail(D, `${theme}@${width}: rendered section.view "${m.view}", asked for "view-site" — the hash did not route, so nothing below this line measures the deploy rail`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          if (!m.ancestry) {
            fail(D, `${theme}@${width}: no \`.detail-grid > .detail-main > section.deploy-rail\` — the rail is not in the ancestry this row measured (the fixture stopped mounting it there), so the page numbers below are about some other screen`);
          }
          // (2) AUDITED: an absent anchor is not a wrapping anchor. Exactly one
          // of each is owed — the live footer by the fixture's all-done ledger,
          // the head's twin by its current_deployment_id.
          if (m.live.length !== 1) {
            fail(D, `${theme}@${width}: ${m.live.length} \`.deploy-rail-live .site-open\`, expected 1 — the rail's LIVE footer is not on the page, so nothing was measured. This is not a pass.`);
            row.push(`${width}:0live`);
            continue;
          }
          if (m.head.length !== 1) {
            fail(D, `${theme}@${width}: ${m.head.length} \`.detail-head .fleet-url .site-open\`, expected 1 — the PAID twin is gone, so this cell has no control and its central comparison is against nothing`);
          }
          const a = m.live[0], h = m.head[0] || null;
          liveSeen++;
          if (h) headSeen++;
          // (3) ANTI-VACUITY: the two anchors must hold the SAME string. A
          // control carrying some other text is a table, not a comparison.
          if (h && h.t !== a.t) {
            fail(D, `${theme}@${width}: the rail footer holds "${a.t.slice(0, 60)}" while the head's paid twin holds "${h.t.slice(0, 60)}" — they are not the same URL, so the twin cannot serve as this cell's control`);
          }
          if (!/^https?:\/\//.test(a.t) || /\s/.test(a.t.replace(/\s*↗$/, ""))) {
            fail(D, `${theme}@${width}: the footer's anchor holds "${a.t.slice(0, 60)}", which is not one unbreakable absolute URL — a string with a space in it wraps without any remedy, so a green here would be green by construction`);
          }
          // (4) THE ANCHOR'S WRAP. The assertion a `min-width: 0` or an
          // `overflow: hidden` cannot buy, and the one that reds on a revert.
          if (a.ws === "nowrap" || a.ws === "pre") {
            nowrapSeen++;
            fail(D, `${theme}@${width} .deploy-rail-live .site-open: computed white-space is "${a.ws}" — the base \`.site-open\` nowrap still reaches the rail's live footer, so its \`word-break: ${a.wb}\` cannot act and the whole URL is pinned to one ${a.w}px line box (the head's paid twin computes "${h ? h.ws : "n/a"}" on the SAME string in the SAME page)`);
          }
          // (5) THE FOOTER'S OWN BOX. Page-level green is buyable by clipping;
          // this is the metric that cannot be bought that way.
          if (a.bsw !== null && a.bsw > a.bcw) {
            boxOver++;
            fail(D, `${theme}@${width} .deploy-rail-live: scrollWidth ${a.bsw} > clientWidth ${a.bcw} — ${a.bsw - a.bcw}px of the live site URL paints OUTSIDE its own footer (white-space:${a.ws}, word-break:${a.wb}, overflow-x:${a.bov}), through whatever sits beside it`);
          }
          if (a.right > m.cw + 1) {
            fail(D, `${theme}@${width} .deploy-rail-live .site-open: right edge ${a.right} is past the ${m.cw}px viewport — the URL a person is meant to copy paints off-screen`);
          }
          // (6) THE COPY BUTTON — the affordance the overhang pushed off.
          if (m.btnRight === null) {
            fail(D, `${theme}@${width}: no \`.deploy-rail-live .copy-btn\` — the footer's copy affordance stopped rendering, so its reachability measured nothing`);
          } else if (m.btnRight > m.cw + 1) {
            fail(D, `${theme}@${width} .deploy-rail-live .copy-btn: right edge ${m.btnRight} is past the ${m.cw}px viewport — the Copy control is off-screen, so the one gesture this footer exists for cannot be made`);
          }
          // (7) THE PAGE, on BOTH axes the row measured.
          if (m.bsw > m.bcw) {
            pageOver++;
            fail(D, `${theme}@${width}: document.body.scrollWidth ${m.bsw} > clientWidth ${m.bcw} — ${m.bsw - m.bcw}px of the site screen is off-screen sideways, at rest and with no cue, while a person reads the address their site just went live on`);
          }
          if (m.sw > m.cw) {
            fail(D, `${theme}@${width}: documentElement.scrollWidth ${m.sw} > clientWidth ${m.cw} — ${m.sw - m.cw}px past the viewport`);
          }
          // (8) IT WRAPPED, IT WAS NOT TRUNCATED. Threshold DERIVED at 900 in
          // this same run, never typed: a cell whose footer is narrower than the
          // URL's own one-line width owes more than one line box.
          if (a.lines > 1) wrapped++;
          if (a.one === null) {
            fail(D, `${theme}@${width} .deploy-rail-live .site-open: the out-of-flow probe returned no intrinsic width — arm (d) measured nothing in this cell`);
          } else {
            intrinsic = intrinsic === null ? a.one : Math.max(intrinsic, a.one);
            if (a.bcw !== null && a.one > a.bcw && a.lines <= 1) {
              fail(D, `${theme}@${width} .deploy-rail-live .site-open: ${a.lines} line box for a URL whose intrinsic one-line width is ${a.one}px inside a ${a.bcw}px footer — it is being TRUNCATED or clipped, not wrapped (text-overflow:${a.ov}). A person reads this line to learn where their site now lives; an ellipsis trades a scrollbar for a lie, which is the branch cch-w14 refused for the twin`);
            }
          }
          // PROBE HYGIENE: a clone that survived its own read would be measured
          // as page content by every cell after it.
          if (m.residue) {
            fail(D, `${theme}@${width}: ${m.residue} \`[data-w29-probe]\` element(s) still in the DOM — the intrinsic-width probe did not remove itself and later cells would measure a mutated tree`);
          }
          row.push(`${width}:body ${m.bsw}/${m.bcw} box ${a.bsw}/${a.bcw} ${a.lines}L ${a.ws} one${a.one}`);
        }
        process.stdout.write(`   live/${theme}  ${row.join("  ")}\n`);
      }
      // AN EMPTY POPULATION IS NOT A CLEAN ONE.
      if (liveSeen === 0) {
        fail(D, `zero \`.deploy-rail-live .site-open\` measured across ${cells} cells — the rail's live footer stopped rendering, so the element this row is named after was never measured. This is not a pass.`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean across ${LIVE_WIDTHS.join("/")} in both themes on \`site-deploy-rail-live\`, ` +
          `the first fixture in this harness to render \`.deploy-rail-live\` at all; ${pageOver} page overhangs, ${boxOver} footer boxes overflowing their own border`,
        );
        okLine(
          `${liveSeen} rail-footer anchor(s) measured against ${headSeen} in-page control(s) — the head's already-paid ` +
          `\`.fleet-url .site-open\` carrying the SAME derived URL in the SAME page, asserted string-equal per cell; ` +
          `${nowrapSeen} of ${liveSeen} still computing a non-wrapping white-space`,
        );
        okLine(
          `${wrapped} of ${liveSeen} footer anchor(s) render on more than one line box; the WRAP-not-TRUNCATE arm's threshold ` +
          `is the URL's own intrinsic one-line width, re-measured in EVERY cell by an out-of-flow clone inside the same ` +
          `footer (widest ${intrinsic}px this run) and never a typed pixel, so a text-overflow remedy — ` +
          `which passes every page and box metric above — reds on it`,
        );
      }
    }

    // ── W27-S5: THE RECOVERY CONTROL, AFTER THE CRUDEST GESTURE THERE IS ────
    //    Every leg above this one asks whether a box that is ALREADY on screen
    //    holds its own text, and W23's asks where the viewport landed after a
    //    reveal. NONE of them asks the question a person whose provision just
    //    FAILED asks with their thumb: fling to the bottom of the page, and is
    //    the recovery control there.
    //
    //    IT IS NOT, AND THE FILED NUMBER UNDERSTATED IT. `.bp-tl-retry` is the
    //    LAST-BUT-ONE child of `.bp-timeline`, and `.bp-timeline` is not the
    //    last thing on the page: `.detail-grid--instance` follows it inside
    //    `#instance-tabpanel`. On merged-main bytes, scrolled to
    //    `document.body.scrollHeight`, Retry sat at top -725.25 at 320x568 on
    //    the SHIPPED strings (`failed` / `mixed-fleet`) against the cruel
    //    corpus's -563.94, and at -96.06 at 1280x900 — 9 of 9 cells across 3
    //    scenarios x 3 viewports off the TOP of the viewport, hit-testing to
    //    nothing.
    //
    //    THE ROW'S OWN PRESCRIBED REMEDY IS REFUTED AND THIS LEG IS WHAT
    //    REFUTES IT. Re-ordering inside the timeline (emitting `.bp-tl-retry`
    //    AFTER `.bp-console`, the app.js DOM order the row blamed) still reads
    //    -470.98 at 320x568 and -159.22 at 390x844: it buys 254px of a 725px
    //    overshoot, because the overshoot is 993.98px of detail grid BELOW the
    //    timeline, not 254px of console inside it. A leg that asserted DOM
    //    order would have gone green on that and moved the person nowhere.
    //
    //    SO THE ASSERTION IS REACHABILITY, NOT ORDER AND NOT PIXELS. Per cell,
    //    after the flick: the control's rect is INSIDE the viewport on both
    //    axes, and `document.elementFromPoint` at its own centre returns the
    //    control itself — a docked control that something else paints over is
    //    exactly as unreachable as one 725px above the fold, and a top >= 0
    //    check alone cannot see that.
    //
    //    FOUR THINGS THAT CANNOT BE BOUGHT, because each one is how a green
    //    here would be green by construction:
    //      (a) THE FIXTURE MUST SCROLL. If the failed screen ever stops being
    //          taller than the viewport, "flick to the bottom" is a no-op and
    //          every cell passes without measuring anything.
    //      (b) EXACTLY ONE CONTROL. A second, duplicate affordance would let a
    //          singular query land on whichever copy happens to be on screen
    //          while the person's eye is on the other one.
    //      (c) THE PAGE'S OWN TAIL MUST CLEAR IT. A control docked to the
    //          viewport bottom permanently covers whatever the document ends
    //          with — here the identity rail's last rows. Reachability bought
    //          by occluding content is a trade, not a fix, so the lowest
    //          `.rail-row` / `.card` bottom is asserted ABOVE the dock's top.
    //      (d) A NON-FAILED CONTROL CELL. `panel-overview` is a healthy
    //          instance detail route: it must carry ZERO `.bp-tl-retry` and
    //          nothing may be docked over it. A remedy that floated a control
    //          over every instance screen scores perfectly on (a)-(c).
    //
    //    ROUTES ARE DERIVED FROM THE FIXTURES, NEVER TRANSCRIBED (D228's
    //    lesson one level up): each scenario's failed box is found by
    //    `provision_status === "failed"` in its own payload, so a fixture that
    //    stops carrying one REFUSES rather than measuring a healthy screen.
    if (requested.includes("W27-failed-retry-reachable-after-flick")) {
      const D = "W27-failed-retry-reachable-after-flick";
      // BLOCK-SCOPED (D247). [width, height] — HEIGHT is the variable this leg
      // lives on, so it cannot use the file's width sets. 320x568 is the
      // smallest phone still shipped and the worst cell; 390x844 is the
      // ordinary phone; 1280x900 is the desktop cell that proves this is NOT
      // phone-only (merged main: -96.06 there).
      const FLICK_VIEWPORTS = [[320, 568], [390, 844], [1280, 900]];
      const { SCENARIOS } = await import("./scenarios.mjs");
      // THE SCENARIOS, and why these three: `failed` is the solo failed box
      // (the shipped console, 4 real lines), `mixed-fleet` is the same failure
      // inside a real estate (the route the row was re-measured on), and
      // `fleet-support-failed` is a SUPPORT box's failure — a different
      // provision_error, a different console, and the desktop cell that read
      // worst-but-one at 1280.
      const FLICK_SCENS = ["failed", "mixed-fleet", "fleet-support-failed"];
      const flickCells = [];
      for (const key of FLICK_SCENS) {
        const sc = SCENARIOS[key];
        const bps = (sc && sc.data && sc.data.barkparks) || [];
        const bad = bps.find((b) => b && b.provision_status === "failed");
        if (!bad) {
          // AUDITED: a scenario that no longer carries a failed box cannot
          // measure this defect. Refuse loudly rather than drive a healthy
          // route and print a clean row.
          fail(D, `scenario "${key}" carries no barkpark with provision_status "failed" (${bps.length} in the payload) — the route this leg drives would render a healthy instance, and a healthy instance has no Retry to reach`);
          continue;
        }
        flickCells.push({ scen: key, id: bad.id, name: bad.name || bad.slug || bad.id });
      }
      if (flickCells.length !== FLICK_SCENS.length) {
        fail(D, `only ${flickCells.length} of ${FLICK_SCENS.length} scenarios resolved a failed box — the cell table below is incomplete`);
      }
      if (!FLICK_VIEWPORTS.some(([w, h]) => w === 1280 && h === 900)) {
        fail(D, `axis check: 1280x900 is not in the viewport set — merged main put Retry at -96.06 there, and a phone-fenced leg cannot see the desktop half of this defect`);
      }
      process.stdout.write(
        `\n${D} — ${flickCells.length} failed-provision routes x ${FLICK_VIEWPORTS.length} geometries x 2 themes` +
        ` (${flickCells.length * FLICK_VIEWPORTS.length * 2} cells; flick to document.body.scrollHeight, then` +
        ` rect + elementFromPoint on .bp-tl-retry) + a healthy-route control per geometry\n`,
      );
      // The measurement, run AFTER the flick. `inView` is both axes: a control
      // pushed off the left edge is unreachable in exactly the way a control
      // above the top edge is.
      const FLICK_READ =
        `(function(){var R=function(v){return Math.round(v*100)/100;};` +
        `var d=document.documentElement;var vh=window.innerHeight,vw=d.clientWidth;` +
        `var rs=[].slice.call(document.querySelectorAll('.bp-tl-retry'));` +
        `var out={n:rs.length,vw:vw,vh:vh,` +
        ` view:(document.querySelector('section.view:not([hidden])')||{}).id||'none',` +
        ` theme:d.getAttribute('data-theme'),` +
        ` docH:R(Math.max(document.body.scrollHeight,d.scrollHeight)),` +
        ` sy:R(window.scrollY),maxSy:R(Math.max(0,Math.max(document.body.scrollHeight,d.scrollHeight)-vh))};` +
        `if(!rs.length) return out;` +
        `var el=rs[0];var r=el.getBoundingClientRect();` +
        `out.top=R(r.top);out.bottom=R(r.bottom);out.left=R(r.left);out.right=R(r.right);out.h=R(r.height);` +
        `out.pos=getComputedStyle(el).position;` +
        `out.inView=(r.top>=0&&r.bottom<=vh+0.5&&r.left>=0&&r.right<=vw+0.5);` +
        `var hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);` +
        `out.hit=!hit?'OFF-VIEWPORT':((hit===el||el.contains(hit))?'RETRY':String(hit.className||hit.tagName||'?'));` +
        // (c) THE PAGE'S OWN TAIL. Every rail row / card inside the tab panel,
        // lowest bottom wins — the content a viewport-docked control would eat.
        // OVERLAP, not "is anything lower than the control". A control sitting
        // IN FLOW legitimately has content below it; a control DOCKED to the
        // viewport is a defect exactly when its box intersects a content box.
        `var tail=[].slice.call(document.querySelectorAll('#instance-tabpanel .rail-row, #instance-tabpanel .card'));` +
        `var low=null,cov=null;tail.forEach(function(e){var b=e.getBoundingClientRect();if(b.height<=0)return;` +
        ` if(low===null||b.bottom>low.b) low={b:R(b.bottom),n:String(e.className||'').slice(0,40)};` +
        ` var oy=Math.min(r.bottom,b.bottom)-Math.max(r.top,b.top);` +
        ` var ox=Math.min(r.right,b.right)-Math.max(r.left,b.left);` +
        ` if(oy>0.5&&ox>0.5&&(cov===null||oy*ox>cov.a)) cov={a:R(oy*ox),oy:R(oy),ox:R(ox),` +
        `   n:String(e.className||'').slice(0,40),b:R(b.bottom)};});` +
        `out.tail=low;out.cov=cov;out.tailN=tail.length;return out;})()`;
      let cells = 0, offViewport = 0, badHit = 0, occluded = 0;
      for (const cell of flickCells) {
        for (const theme of ["light", "dark"]) {
          const row = [];
          for (const [width, height] of FLICK_VIEWPORTS) {
            // Every cell navigated fresh at its own geometry — a scroll
            // position inherited from the previous cell is not a gesture.
            await setViewport(width, height);
            await nav(
              `${BASE}/?scen=${cell.scen}&theme=${theme}#instance/${cell.id}`,
              `(function(){var v=document.querySelector('section.view:not([hidden])');` +
              `return v && v.id==='view-instance' && document.querySelector('.bp-timeline');})()`,
            );
            // THE FLICK. `scrollTo` to the document's own height is the crudest
            // gesture a person has, and the browser clamps it to the real
            // maximum — which is the point: wherever the bottom is, this lands
            // there.
            await evalJs(`window.scrollTo(0, document.body.scrollHeight); void 0`);
            await sleep(120);
            const m = await evalJs(FLICK_READ);
            cells++;
            if (m.view !== "view-instance") {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: rendered section.view "${m.view}", asked for "view-instance" — nothing below this line measured the failure screen`);
              row.push(`${width}x${height}:!route`);
              continue;
            }
            // (a) THE FIXTURE MUST SCROLL.
            if (m.maxSy <= 0) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: the failure screen is ${m.docH}px in a ${m.vh}px viewport — there is nothing to flick to, so this cell asserts nothing about reachability`);
              row.push(`${width}x${height}:!flat`);
              continue;
            }
            if (m.sy < m.maxSy - 1) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: the flick landed at scrollY ${m.sy} of a possible ${m.maxSy} — the gesture did not reach the bottom, so the reading below is not the bottom of the page`);
            }
            // (b) EXACTLY ONE CONTROL.
            if (m.n !== 1) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: ${m.n} .bp-tl-retry in the document, expected exactly 1 — ${m.n === 0 ? "a failed provision with no recovery control at all" : "a duplicate affordance means a person can be looking at one copy while a singular query measures the other"}`);
              row.push(`${width}x${height}:n=${m.n}`);
              continue;
            }
            const before = failures.length;
            if (!m.inView) {
              offViewport++;
              fail(D, `${cell.scen}/${theme}@${width}x${height}: after a flick to the bottom of a ${m.docH}px document, .bp-tl-retry sits at top ${m.top} / bottom ${m.bottom} / left ${m.left} / right ${m.right} against a ${m.vw}x${m.vh} viewport (position: ${m.pos}) — the person flung to the end of the page looking for the recovery control and landed PAST it, with no cue that it is behind them`);
            }
            if (m.hit !== "RETRY") {
              badHit++;
              fail(D, `${cell.scen}/${theme}@${width}x${height}: elementFromPoint at .bp-tl-retry's own centre returns "${m.hit}", not the control — ${m.hit === "OFF-VIEWPORT" ? "the centre is not on screen at all" : "something paints over it, and a covered control is exactly as unreachable as one above the fold"}`);
            }
            // (c) THE PAGE'S TAIL MUST CLEAR THE DOCK.
            if (!m.tailN) {
              fail(D, `${cell.scen}/${theme}@${width}x${height}: zero .rail-row / .card measured inside #instance-tabpanel — the occlusion control has nothing to measure, and an empty list is not a clean list`);
            } else if (m.cov) {
              occluded++;
              fail(D, `${cell.scen}/${theme}@${width}x${height}: the control's box overlaps "${m.cov.n}" by ${m.cov.ox}x${m.cov.oy}px (${m.cov.a}px², that row ending at ${m.cov.b} against the control's ${m.top}-${m.bottom}) — the recovery control is parked ON TOP of the page's own content. Reachability bought by occlusion is a trade, not a fix`);
            }
            if (failures.length === before) {
              row.push(`${width}x${height}:${m.top}/${m.bottom}✓`);
            } else {
              row.push(`${width}x${height}:${m.top}!`);
            }
          }
          process.stdout.write(`   ${cell.scen}/${cell.name}/${theme}  ${row.join("  ")}\n`);
        }
      }
      // (d) THE HEALTHY CONTROL. A remedy that docked a control over every
      // instance screen — or left one behind after the box recovered — passes
      // every assertion above.
      for (const [width, height] of FLICK_VIEWPORTS) {
        await setViewport(width, height);
        await nav(
          `${BASE}/?scen=panel-overview&theme=light#instance/${INST}`,
          `(function(){var v=document.querySelector('section.view:not([hidden])');` +
          `return v && v.id==='view-instance' && document.querySelector('.detail-grid--instance');})()`,
        );
        await evalJs(`window.scrollTo(0, document.body.scrollHeight); void 0`);
        await sleep(120);
        const ctl = await evalJs(
          `(function(){var d=document.documentElement;` +
          `var rs=[].slice.call(document.querySelectorAll('.bp-tl-retry'));` +
          `var fixedish=[].slice.call(document.querySelectorAll('#instance-tabpanel *')).filter(function(e){` +
          `  var p=getComputedStyle(e).position;return p==='fixed'||p==='sticky';}).map(function(e){` +
          `  return String(e.className||e.tagName).slice(0,40);});` +
          `return {n:rs.length,docked:fixedish,vh:window.innerHeight,` +
          ` docH:Math.round(Math.max(document.body.scrollHeight,d.scrollHeight))};})()`,
        );
        if (ctl.n !== 0) {
          fail(D, `panel-overview@${width}x${height}: ${ctl.n} .bp-tl-retry on a HEALTHY instance detail route — the recovery control is scoped to the failure, or it is furniture`);
        } else if (ctl.docked.length) {
          fail(D, `panel-overview@${width}x${height}: ${ctl.docked.length} fixed/sticky element(s) inside #instance-tabpanel on a healthy route (${ctl.docked.join(", ")}) — a control docked over every instance screen is not this defect's remedy`);
        } else {
          okLine(`panel-overview@${width}x${height}: healthy route carries 0 .bp-tl-retry and 0 docked elements in #instance-tabpanel (${ctl.docH}px document) — the remedy is scoped to the failure state`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells: after a flick to the document bottom .bp-tl-retry is inside the viewport on both axes` +
          ` and hit-tests to ITSELF at its own centre, at 320x568 / 390x844 / 1280x900 across ${flickCells.map((c) => c.scen).join(", ")}` +
          ` — ${offViewport} off-viewport, ${badHit} covered, ${occluded} parked over the page's own tail`,
        );
      }
    }

    // ── W25-S3: THE DEPLOY RAIL'S FAILURE FOOTER — the SECOND head of the
    //    two-headed box wave 24 fixed one head of. `.deploy-rail-fail` is what
    //    app.css itself calls "the danger-soft twin of .bp-tl-fail": identical
    //    padding, border, font-size and line-height, and — until this slice —
    //    no wrap rule and no min-width. Computed in the live SPA it read
    //    `overflow-wrap: normal`, `word-break: normal`, `overflow: visible`,
    //    which is exactly the pre-fix state D279 filed for its twin.
    //
    //    THE PERSON: someone watching their deploy fail. The string in this box
    //    is RAW BY DESIGN — the control plane scrubs console entries for
    //    SECRETS on ["line","detail"] and never humanises them, three lines
    //    away from the failure_reason that IS humanised — so a builder's own
    //    `Cannot find module '/opt/barkpark/sites/<slug>/releases/…'` line,
    //    one unbreakable run carrying the person's own slug, lands here whole.
    //
    //    A FIXTURE IS A PRECONDITION OF THIS LEG, NOT AN EXTRA. Before
    //    cch-w25-s3, `grep -c deploy-rail-fail cloud/priv/static/__preview__/*`
    //    returned 0 everywhere: NO scenario carried a rail STAGE entry at all,
    //    `deployRailLedgerFromConsole` drops every console entry without a
    //    `stage` key, and so the whole rail — head, steps, footer — had never
    //    rendered in this harness at any width. `site-deploy-rail-failed` is
    //    that fixture, and its cruel string is DERIVED from the two shell
    //    producers rather than pasted (see the ledger in scenarios.mjs; the cut
    //    is re-derived from the shell by __app.test.mjs, which reds if the
    //    producer's cap moves — this leg asserts NO length of its own).
    //
    //    TWO ASSERTIONS, BECAUSE THE TWO HALVES OF THE REMEDY FAIL DIFFERENTLY,
    //    and this is where the brief that sent this slice here was NARROWED by
    //    its own fixture. Charter D298 recorded `overflow-wrap: break-word` on
    //    the footer failing at 900 (page 1011) — measured with the cruel string
    //    in the FOOTER ALONE. Driven on a fixture that delivers the string the
    //    way the product does, the SAME detail lands in the footer AND in the
    //    step row's `.new-step-detail`, and the footer's own value then makes
    //    no observable difference: `anywhere` and `break-word` measure
    //    identically (box 248/248 @320, 318/318 @390, 292/292 @900, both
    //    themes). What drove the page to 1070 at 900 was `.new-step-detail`'s
    //    preserved min-content, which wave 24 chose ON PURPOSE so a hostname
    //    stays whole. D298 is MASKED here, not refuted — re-measuring its pair
    //    means neutralising the step caption first. So the shipped remedy is
    //    two declarations, and the MEASURED mutations are these:
    //      revert `.detail-grid` to a bare `1fr` ....... the PAGE reds at 900
    //          (1070 against a 900 viewport, widest `.detail-rail` right
    //          1069.72) while every box stays inside its border.
    //      keep the track, delete the footer's wrap .... the BOX reds at every
    //          width (454 into 248 / 318 / 292) WHILE THE PAGE STAYS GREEN at
    //          900. This is the parent-only remedy, and it is green by
    //          construction to any page-level guard.
    //    THEREFORE THIS LEG ASSERTS BOTH, AT 320/390/900. Drop the box
    //    assertion and the parent-only remedy passes; drop the 900 cell and the
    //    track regression passes. Neither is a spare.
    //
    //    THE KIND CONTROL IS DRIVEN IN THE SAME CELLS, on the same fixture's
    //    other site: an ordinary HEALTH failure ("slot blue on :8081 returned
    //    502 …"), word-broken and short — the sentence this epic distrusts,
    //    measured instead of assumed. A remedy that bought the cruel string by
    //    shredding an ordinary one reds there.
    //
    //    HEIGHT IS REPORTED, NEVER PINNED. The wrap is what makes a 240-char
    //    error readable, and its honest cost is a taller box; a bare pixel pin
    //    on that height would be a claim about THIS string at THIS width, and
    //    this epic has already deleted one of those. The numbers are printed
    //    per cell and live in the PR.
    if (requested.includes("W25-deploy-rail-fail-wrap")) {
      const D = "W25-deploy-rail-fail-wrap";
      // BLOCK-SCOPED (D247). 320/390 are the phone widths every remedy passes;
      // 900 is the DECIDING width — the only one above the 768 escape, and the
      // only cell that can refuse `break-word`.
      const RAIL_WIDTHS = [320, 390, 900];
      const { SCENARIOS, RAIL_FAIL_CRUEL_DETAIL, RAIL_FAIL_KIND_DETAIL } = await import("./scenarios.mjs");
      const sc = SCENARIOS["site-deploy-rail-failed"];
      // The routes are DERIVED from the fixture, never transcribed: a pasted
      // uuid rots silently into "the sites list rendered instead".
      if (!sc || !sc.deepLink || !sc.data || !Array.isArray(sc.data.sites) || sc.data.sites.length < 2) {
        return die(`${D}: SCENARIOS["site-deploy-rail-failed"] no longer carries a deepLink and two sites — the cruel rail and its control cannot both be reached, so nothing was measured`);
      }
      const RAIL_ROUTES = [
        { name: "cruel", hash: sc.deepLink, detail: RAIL_FAIL_CRUEL_DETAIL, cruel: true },
        { name: "kind", hash: "#site/" + sc.data.sites[1].id, detail: RAIL_FAIL_KIND_DETAIL, cruel: false },
      ];
      process.stdout.write(
        `\n${D} — the cruel rail x ${RAIL_WIDTHS.length} widths x 2 themes (${RAIL_WIDTHS.length * 2} cells)` +
        ` + the same axis on the KIND control; PAGE and BOX asserted in every cell` +
        ` (cruel detail ${RAIL_FAIL_CRUEL_DETAIL.length} chars, control ${RAIL_FAIL_KIND_DETAIL.length})\n`,
      );
      let cells = 0, kindCells = 0, boxesSeen = 0, pageOver = 0, boxOver = 0;
      for (const r of RAIL_ROUTES) {
        for (const theme of ["light", "dark"]) {
          // Enter at the WIDEST width — the rail mounts once, on load, from the
          // deployments fetch; entering narrow would hide a route that only
          // renders its footer on a phone layout.
          await setViewport(RAIL_WIDTHS[RAIL_WIDTHS.length - 1]);
          await nav(
            `${BASE}/?scen=site-deploy-rail-failed&theme=${theme}${r.hash}`,
            `document.querySelector('.deploy-rail-fail') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-site';})()`,
          );
          const row = [];
          for (const width of RAIL_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){var d=document.documentElement;` +
              `var v=document.querySelector('section.view:not([hidden])');` +
              // EVERY footer on the page, never a pinned one (D228's fifth
              // clause): `querySelector` singular cannot tell a rail that
              // rendered nothing from a rail that rendered a clean box.
              `var fs=[].slice.call(document.querySelectorAll('.deploy-rail-fail')).map(function(f){` +
              `  var cs=getComputedStyle(f);var t=(f.textContent||'');` +
              `  var runs=t.split(/\\s+/).map(function(w){return w.length;});` +
              `  return {sw:f.scrollWidth,cw:f.clientWidth,h:+f.getBoundingClientRect().height.toFixed(2),` +
              `    ow:cs.overflowWrap,wb:cs.wordBreak,ov:cs.overflowX,len:t.length,` +
              `    run:runs.length?Math.max.apply(null,runs):0,t:t};});` +
              // NAME THE BOX THAT PUSHED THE PAGE. A page-level number alone
              // sends the next reader into DevTools, and on this screen the
              // answer is not always this leg's own element — the rail's step
              // list renders the SAME builder string in `.new-step-detail`.
              `var wide=[];if(d.scrollWidth>d.clientWidth){` +
              `  [].slice.call(document.querySelectorAll('#view-site *')).forEach(function(el){` +
              `    var r=el.getBoundingClientRect();if(r.width>0&&r.right>d.clientWidth+1)` +
              `      wide.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),right:+r.right.toFixed(2),w:+r.width.toFixed(2)});});` +
              `  wide.sort(function(a,b){return b.right-a.right;});wide=wide.slice(0,4);}` +
              `return {sw:d.scrollWidth, cw:d.clientWidth, view:v?v.id:'none', fs:fs, wide:wide,` +
              ` theme:d.getAttribute('data-theme')};})()`,
            );
            if (r.cruel) cells++; else kindCells++;
            // (1) THE ROUTE. Without this the whole table is phantom.
            if (m.view !== "view-site") {
              fail(D, `${r.name}/${theme}@${width}: rendered section.view "${m.view}", asked for "view-site" — the hash did not route, so nothing below this line measures the deploy rail`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `${r.name}/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            // (2) AUDITED: an absent box is not a clean box. A fixture that
            // stopped carrying a stage entry would take the rail with it and
            // this leg would print a perfect table about nothing.
            if (m.fs.length === 0) {
              fail(D, `${r.name}/${theme}@${width}: zero .deploy-rail-fail rendered — the rail's failure footer is not on the page, so nothing was measured. This is not a pass.`);
              row.push(`${width}:0box`);
              continue;
            }
            // (3) ANTI-VACUITY, SECOND ORDER: a cruel cell whose string is not
            // actually cruel proves nothing, and a control that drifted cruel
            // would stop being a control. Both are asserted against the
            // fixture's own exported strings — this leg pins no length of its
            // own, so the producer's cap can move without touching this file.
            for (const f of m.fs) {
              boxesSeen++;
              if (f.t !== r.detail) {
                fail(D, `${r.name}/${theme}@${width} .deploy-rail-fail: rendered ${f.len} chars that are not the fixture's ${r.name} detail (${r.detail.length} chars) — the box under measurement is holding some other string`);
                continue;
              }
              if (r.cruel && f.run < 40) {
                fail(D, `${r.name}/${theme}@${width} .deploy-rail-fail: the longest unbreakable run is ${f.run} chars — the cruel fixture went KIND, so a green here would be green by construction`);
              }
              if (!r.cruel && f.run > 20) {
                fail(D, `${r.name}/${theme}@${width} .deploy-rail-fail: the control's longest run is ${f.run} chars — it has drifted cruel and can no longer answer "did the remedy shred ordinary prose"`);
              }
              // (4) THE BOX. The only assertion that can refuse a bare
              // `min-width: 0`, which takes the PAGE to green while leaving the
              // glyphs painted outside their own border.
              if (f.sw > f.cw) {
                boxOver++;
                fail(D, `${r.name}/${theme}@${width} .deploy-rail-fail: scrollWidth ${f.sw} > clientWidth ${f.cw} — ${f.sw - f.cw}px of the builder's error paints OUTSIDE its own box (overflow-wrap:${f.ow}, word-break:${f.wb}, overflow-x:${f.ov}), through whatever sits beside it`);
              }
            }
            // (5) THE PAGE. The only assertion that can refuse `break-word`,
            // and only at 900 — below the 768 escape it passes.
            if (m.sw > m.cw) {
              pageOver++;
              const widest = (m.wide || []).map((x) => `.${x.cls} right=${x.right}`).join(" | ") || "none inside #view-site";
              fail(D, `${r.name}/${theme}@${width}: documentElement.scrollWidth ${m.sw} > clientWidth ${m.cw} — ${m.sw - m.cw}px of the site screen is off-screen sideways while a person reads why their deploy failed. Widest: ${widest}`);
            }
            // HEIGHT IS PRINTED IN EVERY CELL, NOT ASSERTED (see the comment
            // above this block). A wrap's honest cost is a taller box.
            row.push(`${width}:${m.sw}/${m.cw}px box ${m.fs[0].sw}/${m.fs[0].cw} h${m.fs[0].h}`);
          }
          process.stdout.write(`   ${r.name}/${theme}  ${row.join("  ")}\n`);
        }
      }

      // ── THE PROBE CELL: the shipped `anywhere` gets a leg that can lose ────
      //    (cchi-w26-bl-deploy-rail-fail-value-has-no-leg-that-can-lose /
      //    charter D312-CCH.) On the shipped tree, flipping `.deploy-rail-fail`
      //    from `overflow-wrap: anywhere` to `break-word` is BYTE-IDENTICAL in
      //    all six cells above — #9255 hoisted `minmax(0, 1fr)` onto the base
      //    `.detail-grid`, so the track absorbs either value. The difference
      //    EXISTS and was measured under one named condition: a bare `1fr`
      //    track (the pre-#9255 shape) with `.new-step-detail`'s min-content
      //    neutralised — there `anywhere` holds the page at 900 and
      //    `break-word` drags it (~1050 at filing). This cell reproduces that
      //    condition INSIDE the run, so the shipped value decides a measured
      //    outcome again. Injected-style caveat (D308): an injected <style>
      //    outranks later same-specificity rules at EVERY width, so this probe
      //    runs ONLY at 900 (the ≤899 collapse never competes), scopes to
      //    #view-site, and REMOVES itself — arm (c) asserts the removal.
      //    The mutation stays INSIDE the probe: `.new-step-detail` ships
      //    unchanged (W24-theater-failed-hostname-whole still owns it).
      {
        const PROBE_BASE =
          "#view-site .detail-grid { grid-template-columns: 1fr 260px !important; }" +
          "#view-site .new-step-detail { overflow-wrap: anywhere !important; }";
        const PROBE_FLIP =
          "#view-site .deploy-rail-fail { overflow-wrap: break-word !important; }";
        const probeRead =
          `(function(){var d=document.documentElement;` +
          `var f=document.querySelector('.deploy-rail-fail');` +
          `return {sw:d.scrollWidth, cw:d.clientWidth,` +
          ` ow:f?getComputedStyle(f).overflowWrap:'no-rail',` +
          ` probe:!!document.getElementById('__rail_probe')};})()`;
        for (const theme of ["light", "dark"]) {
          await setViewport(900);
          await nav(
            `${BASE}/?scen=site-deploy-rail-failed&theme=${theme}${sc.deepLink}`,
            `document.querySelector('.deploy-rail-fail') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-site';})()`,
          );
          // (a) probe on, rail value SHIPPED: the cell the shipped value must carry.
          await evalJs(
            `(function(){var s=document.createElement('style');s.id='__rail_probe';` +
            `s.textContent=${JSON.stringify("PROBE_BASE_LIT")};document.head.appendChild(s);return true;})()`
              .replace('"PROBE_BASE_LIT"', JSON.stringify(PROBE_BASE)),
          );
          const a = await evalJs(probeRead);
          if (a.sw > a.cw) {
            fail(D, `probe/${theme}@900: under the probe grid (bare 1fr 260px, step detail neutralised) the page reads ${a.sw}/${a.cw} with the SHIPPED .deploy-rail-fail overflow-wrap "${a.ow}" — the shipped value no longer carries the one cell that can refuse break-word`);
          }
          // (b) positive control: the probe must be able to SEE the difference.
          await evalJs(
            `(function(){var s=document.getElementById('__rail_probe');` +
            `s.textContent+=${JSON.stringify("PROBE_FLIP_LIT")};return true;})()`
              .replace('"PROBE_FLIP_LIT"', JSON.stringify(PROBE_FLIP)),
          );
          const b = await evalJs(probeRead);
          if (b.sw <= b.cw) {
            fail(D, `probe/${theme}@900: POSITIVE CONTROL WENT VACUOUS — forcing overflow-wrap: break-word inside the probe still reads ${b.sw}/${b.cw} (rail computed "${b.ow}"), so this probe can no longer distinguish the values and arm (a) certifies nothing`);
          }
          // (c) hygiene: the probe removes itself and the page returns clean.
          await evalJs(
            `(function(){var s=document.getElementById('__rail_probe');` +
            `if(s)s.parentNode.removeChild(s);return true;})()`,
          );
          const c = await evalJs(probeRead);
          if (c.probe || c.sw > c.cw) {
            fail(D, `probe/${theme}@900: PROBE RESIDUE — style present=${c.probe}, page ${c.sw}/${c.cw} after removal; later cells would measure a mutated tree`);
          }
          process.stdout.write(
            `   probe/${theme}@900  shipped(${a.ow}):${a.sw}/${a.cw}  forced(break-word):${b.sw}/${b.cw}  removed:${c.sw}/${c.cw}\n`,
          );
        }
      }

      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cruel cells clean across ${RAIL_WIDTHS.join("/")} in both themes, plus ${kindCells} ` +
          `KIND-control cells on the same axis (${boxesSeen} .deploy-rail-fail box(es) measured — every one on the ` +
          `page, not a pinned selector); ${pageOver} pages scrolling sideways, ${boxOver} boxes spilling their own border`,
        );
        okLine(
          `BOTH assertions are load-bearing and each refuses a DIFFERENT half of the remedy, both driven: reverting ` +
          `.detail-grid to a bare 1fr reds the PAGE at 900 only (1070/900, widest .detail-rail right=1069.72), and ` +
          `deleting .deploy-rail-fail's wrap reds the BOX at all three widths (454 into 248/318/292) while the page ` +
          `stays GREEN at 900 — the parent-only remedy, green by construction to any page-level guard. Heights are ` +
          `printed per cell and deliberately unpinned — a pixel pin on a wrapped string is a claim about that ` +
          `string at that width`,
        );
      }
    }

    // ── cch-w26-bl-deploy-row-siblings-unwrapped (charter D322): THE BRANCH
    //    NAME A PERSON CHOSE — the DOM SIBLING of the panel W26-deploy-fail-clip
    //    fixed, swallowed by the same card at every width. ────────────────────
    //
    //    THE PERSON: they pushed a branch, the console built a preview for it,
    //    and the row that is supposed to say WHICH BRANCH silently drops the
    //    tail of its name. No scrollbar, no page scroll, no selection: the
    //    glyphs are simply not painted. On the preview card that is the only
    //    place the branch is ever spelled out.
    //
    //    THE TWO STRINGS ON THAT LINE ARE NOT THE SAME RISK, and the row this
    //    slice came from named the wrong one. `previewRow()` (app.js) writes
    //    `<div class="deploy-ref">` <> raw branch <> " → " <> `.preview-url`:
    //      THE HOST IS BOUNDED. `Registry.preview_slug_for/2`
    //        (cloud/lib/barkpark_cloud/registry.ex) clamps the DNS label to 63,
    //        so `preview_host_for/2` can never exceed 78 characters — and it is
    //        hyphen-rich, i.e. full of break opportunities.
    //      THE BRANCH IS UNCAPPED. `cloud/lib/barkpark_cloud/registry/
    //        deployment.ex` declares ZERO `validate_length` on `:branch`, and
    //        the webhook path writes `branch_from_ref("refs/heads/" <> branch)`
    //        verbatim — whatever GitHub sent.
    //    MEASURED BY THIS LEG on origin/main's CSS with the fixture below, 52
    //    findings over 20 cells: `.deploy-ref`'s own box loses pixels at 10 of
    //    10 widths in BOTH themes (464px at 320, still 48px at 1440), the
    //    clipper and the glyphs at 8 of 10 (worst 388.2px at 320 — at 720 and
    //    1440 the run overruns the row without filling the card). `.preview-url`
    //    ALONE sat INSIDE the card edge in all 20 pre-fix cells: on this fixture
    //    the hostname is not the defect at all. (The filing quotes 692.41px and
    //    "url at 2 of 10" from the decide-phase probe — a different fixture,
    //    kept here as provenance, never re-quoted as this leg's measurement.)
    //    Hence one declaration on the PARENT: `overflow-wrap` inherits and
    //    `.deploy-ref .mono` sets only `font-family`, so a single
    //    `overflow-wrap: anywhere` on `.deploy-ref` reaches the branch span AND
    //    the link inside it and SUBSUMES the url fix. THE MIRROR-IMAGE REMEDY IS
    //    THIS LEG'S NEGATIVE CONTROL, driven rather than argued: the same
    //    declaration on `.preview-url` INSTEAD reds at 92 findings — all 52
    //    still standing, plus 40 from assertion (6), which is what a link
    //    styled past a parent that never got the value looks like.
    //
    //    GREEN BY CONSTRUCTION TWICE OVER, WHICH IS WHY THIS LEG EXISTS:
    //      · THE SELECTOR AXIS. `git grep -c 'deploy-ref\|preview-url'
    //        origin/main -- cloud/priv/static/__preview__ .github` exits 1 with
    //        NO OUTPUT: not one committed instrument's selector could reach
    //        either element. Even a cruel corpus could not have caught this.
    //      · THE FIXTURE AXIS. The only preview host committed before this slice
    //        was 42 characters — negative at all ten widths — AND it was the
    //        wrong SHAPE (`draft-nav--acme-web.preview.…`: branch first, plus a
    //        `.preview.` label no producer emits). The corpus is corrected in
    //        scenarios.mjs and the cruel row is DERIVED from the producer.
    //
    //    THE SIGNALS THAT CAN LOSE, all three the shape W26-deploy-fail-clip
    //    proved out one sibling over — and NOT `documentElement`, which reads
    //    clean at every one of these widths because a clip is content thrown
    //    away rather than a page pushed sideways:
    //      (a) THE CLIPPER — `overflow-x != visible` AND `scrollWidth >
    //          clientWidth` on the ancestor found by WALKING UP, never a pinned
    //          selector, so a remedy that moves the clip elsewhere is caught.
    //      (b) THE GLYPHS — the maximum right edge of every painted text rect
    //          (Range.getClientRects) against the clipper's CONTENT edge. This
    //          is the number a person loses. An element rect is already clipped
    //          to its parent, so a rect-based sentinel is green by construction.
    //      (c) THE ELEMENT'S OWN BOX — `scrollWidth > clientWidth` on
    //          `.deploy-ref` itself, which goes green the moment the clip moves
    //          up a level and is therefore not a spare for (a).
    //
    //    THE KIND CONTROL RIDES THE SAME ROUTE: the 9-char `draft/nav` preview
    //    with its 41-char host, asserted present and asserted SHORT in every
    //    cell. A remedy that bought the cruel branch by shredding ordinary
    //    prose reds on it, and a fixture that drifted kind reds instead of
    //    printing a green table about nothing.
    //
    //    HONEST SCOPE — THIS LEG PAYS 2 OF THE 4 SELECTORS ITS ROW NAMED.
    //    `.deploy-ref` and the `.preview-url` inside it are measured here. The
    //    row also named `.deploy-meta` and `deployDetailHtml`'s caption:
    //      `.deploy-meta` on a preview row is `["preview", trigger label,
    //        duration, when]` — four bounded/enum strings, no person-controlled
    //        token, so no fixture in this corpus can make it clip. Filed rather
    //        than asserted, because "cannot be cruel" is a claim about today's
    //        `previewRow()` and wants its own measured row if a producer ever
    //        adds a token to it.
    //      `deployDetailHtml`'s caption renders `d.detail` — the builder's own
    //        stage detail, unbounded, the same producer family as the rail's
    //        cruel string — but only while the row is ACTIVE, and it is a
    //        DIFFERENT element that `overflow-wrap: anywhere` on `.deploy-ref`
    //        does not reach. Paying it means a second declaration and a fourth
    //        preview fixture; it is FILED, not silently counted here.
    //
    //    VERTICAL COST IS REPORTED, NEVER PINNED. The wrap is what makes an
    //    84-character branch readable and its honest cost is a taller row (97.5
    //    → 195px at 320 on this fixture). A pixel pin on a wrapped string is a
    //    claim about THAT string at THAT width, and this epic has already
    //    deleted one of those.
    if (requested.includes("W27-deploy-ref-branch-bounded")) {
      const D = "W27-deploy-ref-branch-bounded";
      // BLOCK-SCOPED (D247). The same ten widths the sibling leg carries — the
      // branch defect is present at ALL of them (the ≤768 single-column
      // collapse widens the main column but the 84-char run outgrows it too),
      // so unlike that leg there are no clean shoulders to name here. 1440 is
      // kept because a remedy that only works below the desktop breakpoint
      // must still red somewhere.
      const REF_WIDTHS = [320, 390, 720, 769, 900, 1000, 1024, 1042, 1043, 1440];
      const { SCENARIOS, PREVIEW_CRUEL_BRANCH, PREVIEW_CRUEL_HOST } = await import("./scenarios.mjs");
      const sc = SCENARIOS["site-states"];
      // The route is DERIVED from the fixture, never transcribed: a pasted uuid
      // rots silently into "the sites list rendered instead".
      if (!sc || !sc.deepLink || !sc.data || !Array.isArray(sc.data.previews) || sc.data.previews.length < 2) {
        return die(`${D}: SCENARIOS["site-states"] no longer carries a deepLink and at least two previews — the cruel branch and its control cannot both be reached, so nothing was measured`);
      }
      // The control is READ OUT OF THE FIXTURE, not typed here: the shortest
      // branch on the card that is not the cruel one. If the fixture stopped
      // carrying an ordinary preview this leg refuses rather than measuring the
      // cruel row twice and calling one of them a control.
      const KIND_BRANCH = sc.data.previews
        .map((p) => p.branch)
        .filter((b) => b && b !== PREVIEW_CRUEL_BRANCH)
        .sort((a, b) => a.length - b.length)[0];
      if (!KIND_BRANCH) {
        return die(`${D}: SCENARIOS["site-states"] carries no ORDINARY preview branch beside the cruel one — the control half of this leg would have measured nothing`);
      }
      // ANTI-VACUITY AT THE SOURCE, before a browser is even asked: a fixture
      // that drifted kind, or a host that stopped being the producer's shape,
      // makes every number below meaningless.
      if (PREVIEW_CRUEL_BRANCH.length < 40 || /[\s\-/]/.test(PREVIEW_CRUEL_BRANCH)) {
        return die(`${D}: PREVIEW_CRUEL_BRANCH is ${PREVIEW_CRUEL_BRANCH.length} chars and carries a break opportunity — the fixture went KIND at the source, so a green run would be green by construction`);
      }
      if (!PREVIEW_CRUEL_HOST.startsWith("acme-web--") || PREVIEW_CRUEL_HOST.length !== 78) {
        return die(`${D}: PREVIEW_CRUEL_HOST is "${PREVIEW_CRUEL_HOST}" (${PREVIEW_CRUEL_HOST.length} chars) — it is no longer the producer's <site_slug>--<branch_slug>-<hash>.barkpark.cloud at the 78-char cap, so the bounded half of this leg's premise is unproven`);
      }
      process.stdout.write(
        `\n${D} — site-states x ${REF_WIDTHS.length} widths x 2 themes (${REF_WIDTHS.length * 2} cells; every ` +
        `.deploy-ref on the page against the CLIPPER it actually sits in, glyph rects and clipper scrollWidth, ` +
        `never documentElement — no committed instrument's selector reached this element before this leg: ` +
        `git grep -c 'deploy-ref|preview-url' origin/main -- cloud/priv/static/__preview__ .github exits 1 with ` +
        `no output). Cruel branch ${PREVIEW_CRUEL_BRANCH.length} chars / host ${PREVIEW_CRUEL_HOST.length} ` +
        `(the producer's cap), KIND control "${KIND_BRANCH}" ${KIND_BRANCH.length}. h= is the row height, ` +
        `REPORTED — the wrap costs vertical room and no pixel is pinned\n`,
      );
      let cells = 0, refs = 0, cruelSeen = 0, kindSeen = 0, clipped = 0, spilled = 0, pageOver = 0;
      // cch-w28-bl (b): the truncation this leg no longer keys on was 40 chars.
      // Print the widest clipper class actually seen so a reader can tell how
      // far the old key was from colliding, instead of taking it on trust.
      let widestClass = 0, clipperIds = 0;
      for (const theme of ["light", "dark"]) {
        // Enter at the WIDEST width — the previews card mounts once, from the
        // previews fetch; entering narrow would measure a layout the mount
        // never saw.
        await setViewport(REF_WIDTHS[REF_WIDTHS.length - 1]);
        await nav(
          `${BASE}/?scen=site-states&theme=${theme}${sc.deepLink}`,
          `document.querySelector('.previews .deploy-ref') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-site';})()`,
        );
        const row = [];
        for (const width of REF_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){var d=document.documentElement;` +
            `var v=document.querySelector('section.view:not([hidden])');` +
            // THE CLIPPER IS FOUND, NOT NAMED (W26-deploy-fail-clip's walk,
            // unchanged): the first ancestor whose overflow-x is not visible is
            // the element doing the swallowing, whatever it is called today.
            `function clipperOf(el){var p=el.parentElement;while(p&&p!==document.documentElement){` +
            `  var cs=getComputedStyle(p);if(cs.overflowX!=='visible')return p;p=p.parentElement;}return null;}` +
            // THE GLYPHS, not the box: Range.getClientRects over every text node
            // in the ref line. An element rect is already clipped to its parent.
            `function glyphRight(el){var max=null;var w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null),n;` +
            `  while((n=w.nextNode())){if(!(n.nodeValue||'').trim())continue;var r=document.createRange();r.selectNodeContents(n);` +
            `    var rs=r.getClientRects();for(var i=0;i<rs.length;i++){if(rs[i].width>0&&(max===null||rs[i].right>max))max=rs[i].right;}}` +
            `  return max;}` +
            `var out={sw:d.scrollWidth,cw:d.clientWidth,view:v?v.id:'none',theme:d.getAttribute('data-theme'),refs:[]};` +
            `var clippers=[];` +
            // EVERY .deploy-ref in the PREVIEWS card, never a pinned one (D228):
            // querySelector singular cannot tell a card that rendered nothing
            // from a card of clean rows. Scoped to `.previews` because the
            // production ladder's own refs are a different subject (short shas)
            // and shouting about them here would bury this row's branch.
            `[].slice.call(document.querySelectorAll('.previews .deploy-ref')).forEach(function(f){` +
            `  var cs=getComputedStyle(f);var t=(f.textContent||'');` +
            // THE BRANCH IS THE FIRST `.mono` SPAN, read on its own. Splitting
            // the WHOLE line on whitespace pools the branch with the 78-char
            // host and makes the KIND control read as "drifted cruel" on the
            // strength of a string this leg does not claim is cruel.
            `  var bs=f.querySelector('.mono');var bt=bs?(bs.textContent||''):'';` +
            `  var runs=bt.split(/\\s+/).map(function(w){return w.length;});` +
            // THE LINK IS INLINE, so scrollWidth/clientWidth are both 0 on it —
            // a `sw > cw` question there is VACUOUS. Its rects are the only
            // thing that can answer where the hostname actually paints.
            `  var u=f.querySelector('.preview-url');var ur=null;` +
            `  if(u){var urs=u.getClientRects();for(var j=0;j<urs.length;j++){if(urs[j].width>0&&(ur===null||urs[j].right>ur))ur=urs[j].right;}}` +
            `  var rec={t:t,bt:bt,len:t.length,run:runs.length?Math.max.apply(null,runs):0,ow:cs.overflowWrap,wb:cs.wordBreak,` +
            `    h:+f.getBoundingClientRect().height.toFixed(2),bsw:f.scrollWidth,bcw:f.clientWidth,` +
            `    ur:ur===null?null:+ur.toFixed(2),ulost:null,uow:u?getComputedStyle(u).overflowWrap:null,` +
            `    gr:null,cl:null,clsw:0,clcw:0,clov:'',edge:null,lost:null,rect:+f.getBoundingClientRect().right.toFixed(2)};` +
            `  var g=glyphRight(f);if(g!==null)rec.gr=+g.toFixed(2);` +
            `  var cl=clipperOf(f);` +
            // cch-w28-bl (b): THE DEDUPE KEY IS THE ELEMENT, NOT ITS CLASS
            // STRING. `.slice(0,40)` made the key a 40-char PREFIX, so two
            // different clipping ancestors agreeing in their first 40 chars
            // collapsed into one Set entry and the second real clipper was
            // SILENCED. `clippers.indexOf(cl)` is element identity and cannot
            // collide however the class lists are spelled. MEASURED HONESTLY:
            // on today's fixtures the clipper classes are 7 and 16 chars, so
            // the truncation has never yet collided — this closes a LATENT
            // hazard, and the leg now prints the widest class string it saw so
            // a reader can tell when that stops being true.
            `  if(cl){var r=cl.getBoundingClientRect();var ci=clippers.indexOf(cl);if(ci<0){ci=clippers.push(cl)-1;}rec.ci=ci;` +
            `    rec.cl=(cl.className||cl.tagName||'?').toString();` +
            `    rec.clsw=cl.scrollWidth;rec.clcw=cl.clientWidth;rec.clov=getComputedStyle(cl).overflowX;` +
            `    rec.edge=+(r.left+cl.clientLeft+cl.clientWidth).toFixed(2);` +
            `    if(rec.gr!==null)rec.lost=+(rec.gr-rec.edge).toFixed(2);` +
            `    if(rec.ur!==null)rec.ulost=+(rec.ur-rec.edge).toFixed(2);}` +
            `  out.refs.push(rec);});` +
            `return out;})()`,
          );
          cells++;
          // (1) THE ROUTE. Without this the whole table is phantom.
          if (m.view !== "view-site") {
            fail(D, `site-states/${theme}@${width}: rendered section.view "${m.view}", asked for "view-site" — the hash did not route, so nothing below this line measures a preview row`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `site-states/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          // (2) AUDITED: an absent row is not a clean row. A fixture that
          // stopped carrying previews would take the whole card with it and
          // this leg would print a perfect table about nothing.
          if (m.refs.length === 0) {
            fail(D, `site-states/${theme}@${width}: zero .previews .deploy-ref rendered — the branch previews card is not on the page, so nothing was measured. This is not a pass.`);
            row.push(`${width}:0ref`);
            continue;
          }
          let cruelHere = 0, kindHere = 0, worst = null;
          // ONE VOICE PER CLIPPER. Three preview rows share the previews card,
          // so an unguarded loop shouts the same clipped card three times and
          // buries WHICH row filled it.
          for (const b of m.refs) {
            if (b.cl) widestClass = Math.max(widestClass, String(b.cl).length);
            if (typeof b.ci === "number") clipperIds = Math.max(clipperIds, b.ci + 1);
          }
          const clippersSaid = new Set();
          for (const b of m.refs) {
            refs++;
            const isCruel = b.bt === PREVIEW_CRUEL_BRANCH;
            const isKind = b.bt === KIND_BRANCH;
            if (isCruel) { cruelSeen++; cruelHere++; }
            if (isKind) { kindSeen++; kindHere++; }
            // (3) ANTI-VACUITY, SECOND ORDER: a cruel row whose branch is not
            // actually cruel proves nothing, and a control that drifted cruel
            // stops being a control. Asserted against the FIXTURE's own
            // strings — this leg pins no length of its own.
            if (isCruel && b.run < 40) {
              fail(D, `site-states/${theme}@${width} .deploy-ref: the cruel row's longest unbreakable run is ${b.run} chars — the fixture went KIND, so a green here would be green by construction`);
            }
            if (isKind && b.run > 20) {
              fail(D, `site-states/${theme}@${width} .deploy-ref: the control's longest run is ${b.run} chars — it has drifted cruel and can no longer answer "did the remedy shred ordinary prose"`);
            }
            // (4) THE CLIPPER. Every ref must sit in one, or the walk found
            // nothing and (a) measured nothing.
            if (!b.cl) {
              fail(D, `site-states/${theme}@${width} .deploy-ref (${b.len} chars): no clipping ancestor found — the walk that finds the element doing the swallowing returned nothing, so the clipper assertion measured nothing`);
              continue;
            }
            if (b.clov !== "visible" && b.clsw > b.clcw && !clippersSaid.has(b.ci)) {
              clippersSaid.add(b.ci);
              clipped++;
              // THE SAME THREE DEFECTS, IN THE SAME SHAPE, ONE LEG UP.
              // cch-w28-bl names only W26-deploy-fail-clip, but this block is a
              // structural clone of it — same `clipperOf` walk, same
              // 40-char-prefix Set key, same `filter(cl).sort(lost)` filler —
              // and the clipper it finds (.previews) likewise holds siblings
              // this leg does not own. Fixing only the named instance would
              // leave the identical false attribution standing here, worded
              // about a BRANCH NAME instead of a failure reason.
              //
              // WHAT IS AND IS NOT PROVEN HERE. The browser re-derivation
              // (16 false findings, anyPanelLost=false) was driven on the W26
              // leg; this leg is repaired by PARITY, and its own mutation proof
              // is the whole-file one below — deleting .deploy-fail's
              // `overflow-wrap: anywhere` makes .deploys spill for real and
              // BOTH legs must keep speaking, W26 attributed and this one
              // silent. It is not claimed that a false report was observed
              // coming out of THIS leg.
              const under = m.refs.filter((x) => x.ci === b.ci);
              const spillers = under.filter((x) => x.lost !== null && x.lost > 0.5);
              if (spillers.length) {
                const filler = spillers.slice().sort((x, y) => y.lost - x.lost)[0];
                fail(D, `site-states/${theme}@${width} .${b.cl}: overflow-x:${b.clov} AND scrollWidth ${b.clsw} > clientWidth ${b.clcw} — ${b.clsw - b.clcw}px of a branch name a person chose is inside a box that clips it, with no scrollbar and no page scroll (${spillers.length} of ${under.length} ref(s) under it lose glyphs; the worst loses ${filler.lost}px past the clip edge — ${filler.len} chars, longest run ${filler.run}, overflow-wrap:${filler.ow}, word-break:${filler.wb})`);
              } else {
                const closest = under.reduce((a, x) => (x.lost !== null && (a === null || x.lost > a) ? x.lost : a), null);
                fail(D, `site-states/${theme}@${width} .${b.cl}: overflow-x:${b.clov} AND scrollWidth ${b.clsw} > clientWidth ${b.clcw} — ${b.clsw - b.clcw}px of this card is swallowed with no scrollbar and no page scroll, and it is UN-ATTRIBUTED: not one of the ${under.length} .deploy-ref line(s) under it loses a glyph (the closest stops ${closest === null ? "?" : Math.abs(closest)}px short of the clip edge). The overflow is real and belongs to a SIBLING in the same card — .preview-url, the status pill or the timestamps — which this leg does not own. Do NOT read this line as a branch name being cut`);
              }
            }
            // (5) THE ELEMENT'S OWN BOX. NOT a spare for the clipper — it goes
            // green the moment a remedy moves the clip up a level — and NOT a
            // spare for the glyphs, which are the pixels a person loses.
            if (b.bsw > b.bcw) {
              spilled++;
              fail(D, `site-states/${theme}@${width} .deploy-ref (${b.len} chars): scrollWidth ${b.bsw} > clientWidth ${b.bcw} — ${b.bsw - b.bcw}px of the branch line paints outside its own box (overflow-wrap:${b.ow}, word-break:${b.wb})`);
            }
            // (6) THE LINK INSIDE IT — the BOUNDED half of the line, measured
            // separately so "one declaration on the parent SUBSUMES the url
            // fix" is a MEASUREMENT and not a sentence about inheritance.
            // `.preview-url` is an inline `<a>`, so scrollWidth and clientWidth
            // are BOTH 0 on it and a `sw > cw` question there is vacuous —
            // hence its client rects against the same clipper edge. The second
            // half is the inheritance itself: `.deploy-ref .mono` sets only
            // font-family, so the link's computed overflow-wrap must EQUAL the
            // row's, or the parent declaration never reached the hostname.
            if (b.uow !== null && b.uow !== b.ow) {
              fail(D, `site-states/${theme}@${width} .preview-url: computed overflow-wrap "${b.uow}" while its .deploy-ref parent computes "${b.ow}" — the value did not inherit, so a declaration on the parent does NOT reach the hostname and the url half is unfixed`);
            }
            if (b.ulost !== null && b.ulost > 0.5) {
              spilled++;
              fail(D, `site-states/${theme}@${width} .preview-url (host capped at ${PREVIEW_CRUEL_HOST.length} chars by preview_slug_for/2): its rects reach x=${b.ur} while .${b.cl}'s content edge sits at ${b.edge} — ${b.ulost}px of the preview hostname a person would click is painted outside the card`);
            }
            // (7) THE GLYPHS. The pixels a person actually loses. Half a pixel
            // of tolerance: sub-pixel text metrics are not a defect.
            if (b.gr === null) {
              fail(D, `site-states/${theme}@${width} .deploy-ref: the row painted no text rects at all — the branch is not on screen, so the glyph half measured nothing`);
              continue;
            }
            if (b.lost !== null && b.lost > 0.5) {
              spilled++;
              if (worst === null || b.lost > worst) worst = b.lost;
              fail(D, `site-states/${theme}@${width} .deploy-ref (${b.len} chars): glyphs reach x=${b.gr} while .${b.cl}'s content edge sits at ${b.edge} — ${b.lost}px of WHICH BRANCH THIS PREVIEW IS is painted outside the card and clipped away silently. The row's own border box reads ${b.rect} (inside the edge), which is why a rect-based test is green here`);
            }
          }
          // (8) BOTH FAMILIES MUST BE ON SCREEN IN EVERY CELL. A cell that lost
          // the cruel row would print a clean number about the control alone.
          if (cruelHere === 0) {
            fail(D, `site-states/${theme}@${width}: the cruel ${PREVIEW_CRUEL_BRANCH.length}-char branch is not among the ${m.refs.length} preview ref(s) on the page — the defect's own fixture is missing, so this cell asserted nothing about it`);
          }
          if (kindHere === 0) {
            fail(D, `site-states/${theme}@${width}: the ${KIND_BRANCH.length}-char KIND control branch is not on the page — a remedy that shreds ordinary prose would pass this cell unmeasured`);
          }
          // THE PAGE IS PRINTED, NEVER ASSERTED: on the defective tree it reads
          // clean at every one of these widths, which is the whole reason this
          // leg measures rows.
          if (m.sw > m.cw) pageOver++;
          const cruel = m.refs.find((b) => b.bt === PREVIEW_CRUEL_BRANCH) || m.refs[0];
          const kind = m.refs.find((b) => b.bt === KIND_BRANCH);
          row.push(
            `${width}:page ${m.sw}/${m.cw} cruel lost${cruel.lost === null ? "?" : cruel.lost} sw/cw ${cruel.bsw}/${cruel.bcw} urlLost${cruel.ulost === null ? "?" : cruel.ulost} h${cruel.h}` +
            (kind ? ` kind lost${kind.lost === null ? "?" : kind.lost} h${kind.h}` : " kind:absent") +
            (worst !== null ? ` WORST ${worst}px` : ""),
          );
        }
        process.stdout.write(`   site-states/${theme}  ${row.join("  ")}\n`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean across ${REF_WIDTHS.join("/")} in both themes (${refs} .previews ` +
          `.deploy-ref row(s) measured — EVERY one on the card, not a pinned selector; ${cruelSeen} carried the ` +
          `cruel ${PREVIEW_CRUEL_BRANCH.length}-char branch beside its ${PREVIEW_CRUEL_HOST.length}-char producer-` +
          `capped host, ${kindSeen} the "${KIND_BRANCH}" control), ${clipped} clipper(s) holding more than they ` +
          `show, ${spilled} box(es) painting glyphs past their own edge`,
        );
        okLine(
          `ATTRIBUTION: every clipper finding above is keyed on the clipping ELEMENT (${clipperIds} distinct one(s) ` +
          `seen in a cell), never on a truncated class string — the widest clipper class measured was ${widestClass} ` +
          `chars against the 40-char prefix this leg used to dedupe on, so the old key was ${40 - widestClass} chars ` +
          `from silencing a second real clipper. A clipper that overflows while no .deploy-ref under it loses a glyph ` +
          `is reported as UN-ATTRIBUTED and names the siblings it could have come from instead`,
        );
        okLine(
          `THE SELECTOR AXIS IS CLOSED BY THIS LEG: before it, git grep -c 'deploy-ref|preview-url' origin/main ` +
          `-- cloud/priv/static/__preview__ .github exited 1 with NO OUTPUT — no committed instrument could reach ` +
          `either element, so the whole corpus was green by construction here no matter how cruel its fixtures. ` +
          `The fixture axis was shut in the same commit: the only preview host in the tree was 42 chars (negative ` +
          `at all ten widths) AND the wrong shape (branch first, a .preview. label no producer emits)`,
        );
        okLine(
          `THE HOST IS BOUNDED AND THE BRANCH IS NOT, which is why the remedy sits on the PARENT: preview_slug_for/2 ` +
          `clamps the DNS label to 63 (host <= 78) while registry/deployment.ex declares no validate_length on ` +
          `:branch. DRIVEN ON THIS TREE, this fixture, this runner — 52 findings pre-fix: the ROW'S OWN BOX lost ` +
          `pixels at 10 of 10 widths in both themes (worst 464px at 320, 48px still at 1440), the CLIPPER at 8 of ` +
          `10 and the GLYPHS at 8 of 10 (worst 388.2px at 320; 720 and 1440 clip inside the row without filling ` +
          `the card). .preview-url's OWN rects sat INSIDE the card edge in all 20 pre-fix cells — on this fixture ` +
          `the hostname is not the defect, the branch is, which is the whole reason the declaration is on the ` +
          `parent and not on the link. One overflow-wrap: anywhere on .deploy-ref reaches both, because it ` +
          `INHERITS and .deploy-ref .mono sets only font-family — assertion (6) MEASURES that (link computed value ` +
          `== row computed value, per cell) rather than asserting it in prose, and the mirror-image remedy on ` +
          `.preview-url alone was driven as the negative control: 92 findings — all 52 standing plus 40 from (6). Heights are ` +
          `printed per cell and deliberately unpinned (the cruel row goes 97.5 -> 156px at 320 and 58.5 -> 117px ` +
          `at 900 — the wrap's honest cost). THIS LEG PAYS 2 OF THE 4 SELECTORS ITS ROW NAMED: .deploy-meta (four ` +
          `bounded/enum strings on a preview row) and deployDetailHtml's caption (unbounded, but ACTIVE-only and a ` +
          `different element) are FILED, not counted here`,
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
        fontPinnedEvidence(
          `\`.am-name\` inherits the UI face, not the mono fallback D248 named, and what is ASSERTED here is ` +
          `face-independent anyway: glyphs inside their own box, and a modal that does not scroll sideways`,
        );
      }
    }


    // ── W22: THE 2FA ENROLL PHASE, AT PHONE WIDTHS, AT REST ────────────────
    //    (cchi-w22-bl-modal-oracle-never-visits-a-phone-width.) THE OWNERSHIP
    //    DECISION, in one sentence: overflow-guard owns modal GEOMETRY because
    //    it is the instrument console-harness actually blocks merges on, while
    //    modal-oracle (1440-only, invoked by ZERO CI jobs — it prints that
    //    itself) stays the behavioural oracle; so the enroll phase is driven
    //    HERE rather than widening an instrument nothing runs.
    //
    //    THE DEFECT CLASS THIS CAN LOSE ON (cch-w22-s4 / D254, measured
    //    pre-fix): the account card carried a ~460.45px min-content floor, the
    //    modal root became a horizontal scroller with no visible affordance,
    //    and at rest the QR sat at x=-135..-17 (@320) with Copy at
    //    416.33..448.45 (@360/390/430) — OFF-SCREEN, while
    //    documentElement.scrollWidth == clientWidth at every width, so every
    //    page-level scorer read clean. The assertions here are therefore
    //    VIEWPORT-RELATIVE RECTS AT REST, per control, plus the root's own
    //    scroll pair — never the page number. Px are font-conditional (D218);
    //    the ORDINAL fact — a control past the viewport edge at rest — is what
    //    is asserted.
    //
    //    THE DRIVE IS REAL: scenario account-modal-2fa-badcode auto-drives
    //    #a2f-start → POST enroll → type 000000 → #a2f-confirm → 422, and
    //    app.js paints #a2f-error. Readiness keys on #a2f-error (the drive's
    //    arrival sentinel — NOT one of the measured hosts), so a drive that
    //    never reached the enroll phase refuses as exit 2 instead of
    //    photographing the wrong screen.
    if (requested.includes("W22-2fa-enroll-phone-band")) {
      const D = "W22-2fa-enroll-phone-band";
      const A2F_WIDTHS = [320, 360, 390, 430, 480];
      // #a2f-copy ("Copy all") deliberately NOT here: it belongs to the
      // recovery-codes phase AFTER a successful confirm — the driven 422 path
      // never renders it (measured: zero matches in this phase). The enroll
      // phase's copy control is #a2f-copy-secret.
      const A2F_HOSTS = [".a2f-qr", "#a2f-secret", "#a2f-copy-secret", "#a2f-confirm"];
      process.stdout.write(
        `\n${D} — the driven enroll phase x ${A2F_WIDTHS.length} phone widths x 2 themes` +
        ` (${A2F_HOSTS.length} controls viewport-checked AT REST in every cell)\n`,
      );
      let a2fCells = 0, a2fChecked = 0;
      for (const theme of ["light", "dark"]) {
        await setViewport(900);
        await nav(
          `${BASE}/?scen=account-modal-2fa-badcode&theme=${theme}&modal=account`,
          `(function(){var r=document.getElementById('modal-root');` +
          `return !!(r && !r.hidden && r.querySelector('.modal-card') && document.getElementById('a2f-error'));})()`,
        );
        const row = [];
        for (const width of A2F_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){var d=document.documentElement;var vw=d.clientWidth;` +
            `var root=document.getElementById('modal-root');` +
            `var hosts=${JSON.stringify(A2F_HOSTS)}.map(function(q){` +
            `  var els=[].slice.call(document.querySelectorAll(q));` +
            `  return {q:q, n:els.length, rects:els.map(function(el){var r=el.getBoundingClientRect();` +
            `    return {l:+r.left.toFixed(2), r:+r.right.toFixed(2), w:+r.width.toFixed(2), h:+r.height.toFixed(2)};})};` +
            `});` +
            `return {vw:vw, psw:d.scrollWidth, pcw:d.clientWidth,` +
            ` rsw:root?root.scrollWidth:0, rcw:root?root.clientWidth:0,` +
            ` rleft:root?root.scrollLeft:0, hosts:hosts};})()`,
          );
          a2fCells++;
          for (const h of m.hosts) {
            // A control that stopped rendering is a finding, never a skip: the
            // enroll phase without its QR (or its Copy) is the defect wearing
            // an emptier costume.
            if (h.n === 0) { fail(D, `${theme}@${width}: ${h.q} matched NOTHING in the driven enroll phase — the control is gone, so nothing below can certify it reachable`); continue; }
            for (const r of h.rects) {
              a2fChecked++;
              if (r.w <= 0 || r.h <= 0) { fail(D, `${theme}@${width}: ${h.q} paints a ${r.w}x${r.h} rect — present but invisible`); continue; }
              // THE ORDINAL ASSERTION: on screen AT REST. scrollLeft is read,
              // not reset — "at rest" is what a person gets.
              if (r.l < 0 || r.r > m.vw) {
                fail(D, `${theme}@${width}: ${h.q} rests at ${r.l}..${r.r} against a ${m.vw}px viewport — OFF-SCREEN AT REST behind a scroll with no visible affordance (root scrollLeft ${m.rleft}, root ${m.rsw}/${m.rcw})`);
              }
            }
          }
          row.push(`${width}:root ${m.rsw}/${m.rcw}${m.rsw > m.rcw ? "!" : ""}`);
        }
        process.stdout.write(`   ${theme}  ${row.join("  ")}\n`);
      }
      if (a2fChecked === 0) {
        fail(D, `ZERO control rects measured across ${a2fCells} cells — the enroll phase never rendered, so this leg certifies nothing`);
      } else if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${a2fChecked} control rect(s) across ${a2fCells} cells: QR, secret, Copy, Confirm all ON SCREEN ` +
          `AT REST at ${A2F_WIDTHS.join("/")} in both themes, in the REAL driven enroll phase (start → enroll → 422). ` +
          `The page number is not consulted — pre-fix, documentElement read clean at every one of these widths ` +
          `while the QR sat at x=-135; the viewport-relative rects are what a person gets`,
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
        ` (${cellCount} cells, ${FLEET_TEXT_SELS.join("/")} + .status-pill-detail + .fleet-badges + .status-pill HEIGHT;` +
        ` all ${FLEET_SUB_HOSTS.length} sub-hosts CENSUSED per row and their zero refused per cell)\n`,
      );
      let cells = 0, clipped = 0, ellipsed = 0, squeezed = 0, pageOver = 0, rowsSeen = 0, overflowed = 0, foreignRows = 0;
      // cchi-w23: per-selector sub-host census, and the count of legitimately
      // bare rows the two conditional emitters account for.
      const subSeen = {};
      let subBare = 0;
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
              `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,rows:0,docRows:document.querySelectorAll('.fleet-row').length,clips:[],ell:[],sq:[],tall:[],sub:{},bare:[]};` +
              // cchi-w23 SECOND ORDER: the census of the sub-hosts this leg
              // asserts on, taken in the SAME walk that measures them. Without
              // it every `r.querySelector(s); if(!e) return;` below is a silent
              // skip, and 330 deleted text hosts print as 330 measured rows.
              `var SUB=${JSON.stringify(FLEET_SUB_HOSTS.map((h) => h.sel))};` +
              `SUB.forEach(function(s){out.sub[s]=0;});` +
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
              `  SUB.forEach(function(s){if(r.querySelector(s)) out.sub[s]++; else out.bare.push({i:i,s:s});});` +
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
            // cchi-w23 — THE SECOND LEVEL, COUNTED AND REFUSED PER CELL. Every
            // assertion below this line reaches its host through
            // `r.querySelector(sel)` and returns on null, so a host that stopped
            // being emitted is measured ZERO times and scored ZERO defects. That
            // is what the `.fleet-url` and `.fleet-meta` rename mutations each
            // proved: byte-identical green with the whole population deleted.
            for (const h of FLEET_SUB_HOSTS) {
              const n = m.sub[h.sel] || 0;
              subSeen[h.sel] = (subSeen[h.sel] || 0) + n;
              if (n === 0) {
                // A CELL with none is a finding for every host, optional or not:
                // "0 clipped text cells" is trivially true of a selector nothing
                // emits, which is not what this leg claims.
                fail(D, `${scen}/${theme}@${width}: zero \`${h.sel}\` across ${m.rows} rendered .fleet-row — the sub-host this leg asserts on is not in the DOM, so its comparisons ran ${m.rows} times against nothing. "0 clipped" is true of an empty set; this is not a pass.`);
              } else if (!h.optional && n < m.rows) {
                // MANDATORY hosts are refused at the ROW, because `fleetRowHtml`
                // emits them unconditionally — a row without one is drift, not a
                // fixture doing nothing wrong.
                const missing = m.bare.filter((b) => b.s === h.sel).map((b) => `row${b.i}`).join(", ");
                fail(D, `${scen}/${theme}@${width}: \`${h.sel}\` present on ${n} of ${m.rows} rows (${missing} carry none) — fleetRowHtml emits it unconditionally, so a bare row means the class was renamed or the branch was dropped, and every assertion on it silently skipped those rows`);
              } else if (h.optional && n < m.rows) {
                subBare += m.rows - n;
              }
            }
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
          // cchi-w23: the SUB-HOST census, printed beside the row count it used
          // to be mistaken for. "330 fleet rows measured" said nothing about how
          // many of them carried the element each assertion actually reads —
          // which is why deleting all 330 `.fleet-url` left this line unchanged.
          `sub-hosts measured per row (not inferred from the row count): ` +
          FLEET_SUB_HOSTS.map((h) => `${h.sel}=${subSeen[h.sel] || 0}/${rowsSeen}${h.optional ? "*" : ""}`).join(", ") +
          `. \`*\` = conditionally emitted, so a bare row is legitimate and refused only at the CELL` +
          (subBare ? ` (${subBare} bare row-host(s) this run)` : ` (0 bare row-hosts this run)`) +
          `; every other selector is emitted unconditionally by fleetRowHtml and a bare ROW reds`,
        );
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

    // ── W24: the credential DIALOG's button actually connects the typed key ─
    //    THE LEG ABOVE IS BLIND TO THE DIALOG, AND THAT IS WHY THIS ONE EXISTS.
    //    W23-cred-remediation-reachable drives `#provider-connect
    //    [data-connect-submit]` — the providers PAGE card, and only ever that.
    //    Nothing in this harness had ever reached the credential MODAL
    //    (`git grep -n 'launch-connect-provider\|openProviderCredential'
    //    cloud/priv/static/__preview__` returned nothing), so the sheet a
    //    person meets FIRST — the launch wizard's "Connect <provider>" door,
    //    which is the only forward caller of `openProviderCredential` — was
    //    measured by no instrument at all. On origin/main bytes its button was
    //    DEAD: `$` is `document.querySelector` and `#view-providers` precedes
    //    `#modal-root` in index.html, so over a painted providers card
    //    `openProviderCredential` bound its submit handler to the PAGE's
    //    button. Zero requests, zero toasts, no disable, and the sheet stayed
    //    open. `openModal` only marks `#app-shell` inert — the page copy is
    //    gone from pointer and AT reach but NOT from `document.querySelector`
    //    — so the collision does not evaporate while the dialog is up.
    //
    //    THE BODY IS THE POSTED BYTES, NEVER "A POST HAPPENED". A leg that
    //    asserted only that a request left the page would go green on a
    //    one-sided fix that binds the dialog's button to the PAGE's fields —
    //    which is the bug as originally FILED (`the modal POSTs the wrong
    //    credential`), i.e. the guard would certify the defect it replaced.
    //    Every cell types a per-cell SENTINEL and asserts the recorded body
    //    carries THAT sentinel.
    //
    //    FOUR CELLS, AND TWO OF THEM ARE THE CONTROL AND THE LEAK:
    //      (a) dialog-over-painted-card — the person body. Both hosts exist.
    //      (b) control-card-never-painted — the same gestures on a route that
    //          never painted the providers card, so exactly ONE host exists.
    //          It POSTed correctly on broken bytes; if this cell ever reds,
    //          the fix RELOCATED the bug instead of removing it.
    //      (c) duplicate-write — `#settings/providers` -> `#scope-launch` ->
    //          Escape -> type -> press the PAGE's button, WITHOUT
    //          re-navigating. On broken bytes the dialog left a second handler
    //          on the page's button: one press, TWO `POST /v1/providers`. The
    //          cell asserts EXACTLY ONE, and it asserts its own honesty first
    //          — a re-navigation calls `loadProviders()`, repaints the card
    //          and clears the leak, so the cell stamps the card node before
    //          opening the modal and FAILS if that same node is not still
    //          mounted at submit time. Without that check the assertion is
    //          green by construction.
    //      (d) show-key-eye — the affordance the same two-host collision
    //          killed twice over: the dialog's eye was dead AND the page's
    //          became a net no-op (two handlers, two toggles). Measured as
    //          `type` TRANSITIONS, baseline first.
    //
    //    THE AXIS IS WIDTH, NOT THEME — stated rather than padded. This leg
    //    measures a BINDING, not a paint: a colour scheme cannot change which
    //    element a handler landed on, and a second theme would double the cell
    //    count while asking the same question twice. Width can: the launch
    //    door is reached through the topbar's scope menu, so a phone where
    //    `#scope-switch` or `#scope-launch` is unreachable is a cell that
    //    proves nothing, and this leg would rather red on that than skip it.
    if (requested.includes("W24-cred-dialog-button-alive")) {
      const D = "W24-cred-dialog-button-alive";
      // BLOCK-SCOPED (D247): these axes belong to this leg alone.
      // `providers-connected` answers POST /v1/providers with the default 201
      // (it carries no `providerConnect` fixture), which is the only scenario
      // shape on which "the sheet CLOSES" can be measured at all — the two
      // `providers-*` scenarios the leg above drives both answer 422 and hold
      // the sheet open by design. It also carries no `catalog`, so the launch
      // wizard resolves `no_provider` and renders the `.launch-connect-provider`
      // door this leg walks through. Nothing is injected: every gesture below
      // is one a person makes.
      const CRED_DIALOG_SCEN = "providers-connected";
      const CRED_DIALOG_VIEWPORTS = [[390, 844], [1000, 800]];
      // ANTI-VACUITY 0 — the axes and the sentinel discipline, so a later edit
      // cannot quietly turn this leg back into "a POST happened somewhere".
      if (!CRED_DIALOG_VIEWPORTS.some(([w]) => w <= 430)) {
        fail(D, `axis check: no phone width is in the viewport set — the launch door is reached through the topbar scope menu, and whether a person can reach it at all is exactly the width-dependent half this leg exists to measure`);
      }
      if (!CRED_DIALOG_VIEWPORTS.some(([w]) => w >= 900)) {
        fail(D, `axis check: no desktop width is in the viewport set — a leg that only ever drove a phone could not tell you the dialog regressed on the geometry most operators connect a provider from`);
      }
      process.stdout.write(
        `\n${D} — ${CRED_DIALOG_VIEWPORTS.length} viewports x 4 cells on ${CRED_DIALOG_SCEN}` +
        ` (the launch wizard's Connect door -> the dialog's own field -> its own button, with the POSTED BODY read back)\n`,
      );

      // EVERY CELL IS A CROSS-DOCUMENT NAVIGATION, AND THAT COSTS A QUERY
      // PARAM. This leg's cells differ from each other only by HASH
      // (`#settings/providers` vs `#overview`), and a navigation that changes
      // nothing but the fragment is a SAME-document navigation: Chrome keeps
      // the DOM. Driven, not predicted — the `#overview` control cell reported
      // TWO `#cred-submit` hosts, because it was still holding the providers
      // card the previous cell had painted. A control that inherited the very
      // condition it is the control FOR is worse than no control. The unique
      // `cell` param forces a real document load; mock.js reads `scen` and
      // nothing else off the page URL.
      const credUrl = (hash, tag) =>
        `${BASE}/?scen=${CRED_DIALOG_SCEN}&theme=light&cell=${encodeURIComponent(tag)}${hash}`;

      // ── the drive, all of it person-gestures ──────────────────────────────
      // Poll an expression until it is truthy. A cell that times out FAILS
      // where it stood and measures nothing further — an unreached screen is
      // never a clean screen.
      const credWait = async (expr) => {
        for (let w = 0; w < RENDER_CAP; w += 100) {
          let v = false;
          try { v = !!(await evalJs(`!!(${expr})`)); } catch { /* mid-render */ }
          if (v) return true;
          await sleep(100);
        }
        return false;
      };
      // THE READER FENCE (wave-23's one cross-slice defect, inverted). This
      // leg reads the POSTED BYTES, and it will not borrow anyone's fixture to
      // do it: nothing under `__preview__/fixtures` or `scenarios.mjs` is
      // touched, so no other oracle's numbers move because this one was added.
      // The recorder is installed per page load, over whatever `window.fetch`
      // mock.js already installed, and it records only the route this leg is
      // about.
      const credArm = () => evalJs(
        `(function(){window.__credPosts=[];` +
        `if(window.__credProbe) return true;` +
        `window.__credProbe=true;var of=window.fetch;` +
        `window.fetch=function(i,init){` +
        `var u=typeof i==='string'?i:((i&&i.url)||'');` +
        `var m=String((init&&init.method)||(i&&i.method)||'GET').toUpperCase();` +
        `if(m==='POST'&&u.indexOf('/v1/providers')>=0)` +
        `window.__credPosts.push({url:u,body:String((init&&init.body)||'')});` +
        `return of.apply(this,arguments);};return true;})()`,
      );
      // Open the launch wizard the way the product does it: the topbar scope
      // menu's "+ Launch instance". NOT a route change — `#settings/providers`
      // stays the rendered view underneath, which is the whole point of (c).
      const credOpenLaunch = () => evalJs(
        `(function(){var sw=document.getElementById('scope-switch');` +
        `if(!sw) return {ok:false,why:'no #scope-switch in the topbar'};` +
        `sw.click();var l=document.getElementById('scope-launch');` +
        `if(!l) return {ok:false,why:'#scope-launch never rendered into the scope menu'};` +
        `l.click();return {ok:true};})()`,
      );
      // The launch wizard's catalog panel resolves `no_provider` and offers the
      // door. This is `openProviderCredential`'s ONLY forward caller.
      const credOpenDialog = async () => {
        if (!await credWait(`document.querySelector('#modal-root .launch-connect-provider')`)) {
          return { ok: false, why: "the launch wizard never rendered a .launch-connect-provider door (its catalog panel did not resolve no_provider)" };
        }
        await evalJs(`document.querySelector('#modal-root .launch-connect-provider').click()`);
        if (!await credWait(`document.querySelector('#modal-root #cred-token')`)) {
          return { ok: false, why: "the credential dialog never rendered its own #cred-token" };
        }
        return { ok: true };
      };
      // What the page is holding once the gesture chain has run. Every id is
      // counted ACROSS THE DOCUMENT (D228), because the count is the finding:
      // two hosts is the condition the defect lives in, and a cell that finds
      // one host on the painted route has not reproduced anything.
      const credRead = () => evalJs(
        `(function(){var root=document.getElementById('modal-root');` +
        `var posts=(window.__credPosts||[]).map(function(p){var t=null,e=null;` +
        `try{var b=JSON.parse(p.body)||{};t=(b.token===undefined?null:b.token);}catch(x){e=String((x&&x.message)||x);}` +
        `return {token:t,parseErr:e,len:p.body.length};});` +
        `return {posts:posts,n:posts.length,` +
        `modalHidden:!!(root&&root.hidden),` +
        // W25 amendment, and the ONLY change this wave makes inside this leg:
        // "the sheet closed" is a SPELLING of the person-facing invariant "the
        // form I already submitted is off my screen", and it stopped being the
        // only spelling. On the modal launch path a 201 now RE-ENTERS the
        // launch wizard into the same `#modal-root` body
        // (resumeLaunchAfterConnect), so the root correctly never goes hidden
        // while the credential form is nonetheless gone. Read both; the
        // assertion below accepts either and still reds when the person is
        // left staring at the form.
        `sheetGone:!document.querySelector('#modal-root #cred-token'),` +
        `tokens:document.querySelectorAll('#cred-token').length,` +
        `submits:document.querySelectorAll('#cred-submit').length,` +
        `cardAlive:!!(window.__credCard&&window.__credCard.isConnected),` +
        `view:(function(){var v=document.querySelector('section.view:not([hidden])');return v?v.id:'none';})(),` +
        `toasts:[].slice.call(document.querySelectorAll('.toast-title')).map(function(t){return (t.textContent||'').trim();})};})()`,
      );

      let credCells = 0, credPosts = 0, credTwoHost = 0;
      let credDead = 0, credWrongBody = 0, credOpenSheet = 0, credDouble = 0, credEyeDead = 0;
      for (const [width, height] of CRED_DIALOG_VIEWPORTS) {
        const row = [];

        // (a) THE PERSON BODY — both hosts exist, the dialog is driven.
        // (b) THE CONTROL — one host exists, identical gestures. `#overview`
        //     never mounts the providers page, so `#cred-*` has a single host
        //     there; this cell POSTed correctly on the broken bytes and is
        //     what proves the fix removed the bug rather than moving it.
        for (const cell of [
          { name: "dialog-over-painted-card", hash: "#settings/providers", painted: true, sentinel: `w24-dialog-key-${width}` },
          { name: "control-card-never-painted", hash: "#overview", painted: false, sentinel: `w24-control-key-${width}` },
        ]) {
          credCells++;
          await setViewport(width, height);
          await nav(
            credUrl(cell.hash, `${cell.name}-${width}`),
            cell.painted
              ? `document.querySelector('#provider-connect [data-connect-submit]')`
              : `(function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-overview';})()`,
          );
          await credArm();
          const opened = await credOpenLaunch();
          if (!opened.ok) {
            credDead++;
            fail(D, `${cell.name}@${width}x${height}: the gesture chain never started — ${opened.why}. The launch wizard is the ONLY door to the credential dialog (openProviderPicker has no forward caller), so a person who cannot reach it here cannot connect a provider at all`);
            row.push(`${cell.name}:!door`);
            continue;
          }
          const reached = await credOpenDialog();
          if (!reached.ok) {
            credDead++;
            fail(D, `${cell.name}@${width}x${height}: ${reached.why}. Nothing below this line was measured`);
            row.push(`${cell.name}:!sheet`);
            continue;
          }
          // Type into the DIALOG's own field, press the DIALOG's own button.
          // Both are resolved inside `#modal-root` here on purpose: the guard
          // must drive the element the PERSON is looking at, or it re-commits
          // the very confusion it is measuring.
          // THE HOST CENSUS IS TAKEN BEFORE THE PRESS, NEVER AFTER. A
          // successful connect closes the sheet (`closeModal` empties
          // `#modal-body`), so counting `#cred-token` after the click always
          // reports ONE host on the painted route — a green-by-construction
          // reading of the very condition this cell has to prove it entered.
          const typed = await evalJs(
            `(function(){var t=document.querySelector('#modal-root #cred-token');` +
            `if(!t) return {ok:false,why:'no #cred-token inside the open dialog'};` +
            `t.value=${JSON.stringify(cell.sentinel)};` +
            `var s=document.querySelector('#modal-root #cred-submit');` +
            `if(!s) return {ok:false,why:'no #cred-submit inside the open dialog'};` +
            `var hosts={tokens:document.querySelectorAll('#cred-token').length,` +
            `submits:document.querySelectorAll('#cred-submit').length,` +
            `labels:document.querySelectorAll('#cred-label').length};` +
            `window.__credCard=document.getElementById('provider-connect');` +
            `s.click();return {ok:true,hosts:hosts};})()`,
          );
          if (!typed.ok) {
            credDead++;
            fail(D, `${cell.name}@${width}x${height}: ${typed.why} — the sheet rendered but the control the person presses is not in it`);
            row.push(`${cell.name}:!ctrl`);
            continue;
          }
          await credWait(`(window.__credPosts||[]).length > 0`);
          const m = await credRead();
          credPosts += m.n;
          const hosts = typed.hosts;
          if (cell.painted) {
            if (hosts.tokens < 2 || hosts.submits < 2 || hosts.labels < 2) {
              fail(D, `${cell.name}@${width}x${height}: at the moment the button was pressed the document held ${hosts.tokens} \`#cred-token\` / ${hosts.submits} \`#cred-submit\` / ${hosts.labels} \`#cred-label\` — the providers card was supposed to be painted UNDER the dialog, so this cell never entered the two-host condition the defect lives in and cannot have reproduced it`);
            } else credTwoHost++;
          } else if (hosts.submits !== 1) {
            fail(D, `${cell.name}@${width}x${height}: the control cell held ${hosts.submits} \`#cred-submit\` — it is only a control while the dialog is the ONLY host, and a second one here means the route painted the providers card after all`);
          }
          if (m.n === 0) {
            credDead++;
            fail(D, `${cell.name}@${width}x${height}: the dialog's button produced ZERO \`POST /v1/providers\` — the person typed their key, pressed "Add provider", and nothing left the page (${m.tokens} #cred-token / ${m.submits} #cred-submit in the document, toasts: ${JSON.stringify(m.toasts)}). A dead button on the only screen that connects a provider`);
            row.push(`${cell.name}:0post`);
            continue;
          }
          if (m.n !== 1) {
            credDouble++;
            fail(D, `${cell.name}@${width}x${height}: ONE press produced ${m.n} \`POST /v1/providers\` — the credential was written more than once`);
          }
          for (const p of m.posts) {
            if (p.parseErr) {
              credWrongBody++;
              fail(D, `${cell.name}@${width}x${height}: the POSTed body (${p.len} bytes) did not parse as JSON — ${p.parseErr}. This leg claims the BYTES carry the typed key, and it cannot claim that about a body it could not read`);
            } else if (p.token !== cell.sentinel) {
              credWrongBody++;
              fail(D, `${cell.name}@${width}x${height}: the POSTed body carries token ${JSON.stringify(p.token)}, but the person typed ${JSON.stringify(cell.sentinel)} INTO THE DIALOG — the request left the page reading the wrong host's field, which is the bug one binding to the left`);
            }
          }
          if (!m.modalHidden && !m.sheetGone) {
            credOpenSheet++;
            fail(D, `${cell.name}@${width}x${height}: the credential succeeded (201) and the sheet is STILL OPEN — the person is left staring at a form they already submitted, with no way to tell it worked (\`#modal-root\` visible AND still holding a \`#cred-token\`)`);
          }
          row.push(`${cell.name}:${m.n}post ${hosts.tokens}tok/${hosts.submits}sub-hosts-at-press tok=${m.posts.map((p) => JSON.stringify(p.token)).join(",")} closed=${m.modalHidden} sheet-gone=${m.sheetGone}`);
        }

        // (c) THE DUPLICATE WRITE. Its honesty check comes FIRST: this cell is
        //     only a measurement if the page card that was on screen before the
        //     modal opened is the SAME node when the button is pressed. A
        //     re-navigation would repaint it (loadProviders) and clear the leak,
        //     and the assertion below would then be green by construction —
        //     wave-23 clause 4, applied to this leg's own fixture-free drive.
        credCells++;
        await setViewport(width, height);
        await nav(
          credUrl("#settings/providers", `duplicate-write-${width}`),
          `document.querySelector('#provider-connect [data-connect-submit]')`,
        );
        await credArm();
        const dupSentinel = `w24-page-key-${width}`;
        const dupOpened = await credOpenLaunch();
        if (!dupOpened.ok) {
          credDead++;
          fail(D, `duplicate-write@${width}x${height}: could not open the launch wizard — ${dupOpened.why}`);
          row.push("duplicate-write:!door");
        } else {
          const dupReached = await credOpenDialog();
          if (!dupReached.ok) {
            credDead++;
            fail(D, `duplicate-write@${width}x${height}: ${dupReached.why}`);
            row.push("duplicate-write:!sheet");
          } else {
            // Stamp the card node, dismiss with Escape (the reflex gesture),
            // then type into the PAGE card and press ITS button. No
            // navigation of any kind happens between the stamp and the press.
            await evalJs(`window.__credCard=document.getElementById('provider-connect')`);
            await evalJs(`document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))`);
            const dismissed = await credWait(`(function(){var r=document.getElementById('modal-root');return !!(r&&r.hidden);})()`);
            const pressed = await evalJs(
              `(function(){var t=document.querySelector('#provider-connect #cred-token');` +
              `if(!t) return {ok:false,why:'no #cred-token in the providers card after the dialog was dismissed'};` +
              `t.value=${JSON.stringify(dupSentinel)};` +
              `var s=document.querySelector('#provider-connect [data-connect-submit]');` +
              `if(!s) return {ok:false,why:'no [data-connect-submit] in the providers card'};` +
              `s.click();return {ok:true};})()`,
            );
            if (!dismissed) fail(D, `duplicate-write@${width}x${height}: Escape did not dismiss the credential dialog — the sequence this cell pins never started`);
            if (!pressed.ok) {
              credDead++;
              fail(D, `duplicate-write@${width}x${height}: ${pressed.why}`);
              row.push("duplicate-write:!ctrl");
            } else {
              await credWait(`(window.__credPosts||[]).length > 0`);
              const m = await credRead();
              credPosts += m.n;
              if (!m.cardAlive) {
                fail(D, `duplicate-write@${width}x${height}: the \`#provider-connect\` node stamped before the modal opened is NO LONGER MOUNTED at submit time — the card repainted, which clears the leaked handler and makes the single-POST assertion below green by construction. This cell asserts nothing until that stops happening`);
              }
              if (m.view !== "view-providers") {
                fail(D, `duplicate-write@${width}x${height}: the rendered view is "${m.view}", not "view-providers" — the sequence re-routed, and a re-render is exactly what this cell must not do`);
              }
              if (m.n === 0) {
                credDead++;
                fail(D, `duplicate-write@${width}x${height}: the page card's button produced ZERO \`POST /v1/providers\` after the dialog had been opened and dismissed — dismissing a sheet must not take the page's own control with it`);
              } else if (m.n !== 1) {
                credDouble++;
                fail(D, `duplicate-write@${width}x${height}: ONE press of "Verify & connect" produced ${m.n} \`POST /v1/providers\` (tokens ${JSON.stringify(m.posts.map((p) => p.token))}) — the dismissed dialog left its handler on the PAGE's button, so the person's credential is written ${m.n} times and they are told about it ${m.toasts.length} times`);
              }
              for (const p of m.posts) {
                if (p.token !== dupSentinel) {
                  credWrongBody++;
                  fail(D, `duplicate-write@${width}x${height}: the POSTed body carries ${JSON.stringify(p.token)}, not the ${JSON.stringify(dupSentinel)} typed into the page card`);
                }
              }
              row.push(`duplicate-write:${m.n}post card=${m.cardAlive ? "same" : "REPAINTED"} tok=${m.posts.map((p) => JSON.stringify(p.token)).join(",")}`);
            }
          }
        }

        // (d) THE SHOW-KEY EYE, measured as `type` transitions and baselined
        //     BEFORE the dialog is ever opened. Both halves are the same
        //     collision: over a painted card the dialog's eye bound nothing,
        //     and the page's collected a SECOND handler, so one press toggled
        //     twice and the page's eye became a net no-op.
        credCells++;
        await setViewport(width, height);
        await nav(
          credUrl("#settings/providers", `show-key-eye-${width}`),
          `document.querySelector('#provider-connect #cred-eye')`,
        );
        const eyeBase = await evalJs(
          `(function(){var t=document.querySelector('#provider-connect #cred-token');` +
          `var e=document.querySelector('#provider-connect #cred-eye');` +
          `if(!t||!e) return {ok:false,why:'the providers card has no #cred-token/#cred-eye pair'};` +
          `var before=t.type;e.click();var after=t.type;e.click();` +
          `return {ok:true,before:before,after:after,back:t.type};})()`,
        );
        if (!eyeBase.ok) {
          fail(D, `show-key-eye@${width}x${height}: ${eyeBase.why} — the baseline could not be taken, so nothing below it means anything`);
          row.push("show-key-eye:!base");
        } else {
          if (!(eyeBase.before === "password" && eyeBase.after === "text" && eyeBase.back === "password")) {
            credEyeDead++;
            fail(D, `show-key-eye@${width}x${height}: the PAGE card's eye does not reveal the key even before a dialog exists — type went ${eyeBase.before} -> ${eyeBase.after} -> ${eyeBase.back}, and "Show key" that shows nothing is a control that lies about itself`);
          }
          const dlg = await credOpenLaunch();
          const reached = dlg.ok ? await credOpenDialog() : { ok: false, why: dlg.why };
          if (!reached.ok) {
            credDead++;
            fail(D, `show-key-eye@${width}x${height}: ${reached.why}`);
            row.push("show-key-eye:!sheet");
          } else {
            const eyeM = await evalJs(
              `(function(){var dt=document.querySelector('#modal-root #cred-token');` +
              `var de=document.querySelector('#modal-root #cred-eye');` +
              `var pt=document.querySelector('#provider-connect #cred-token');` +
              `if(!dt||!de||!pt) return {ok:false,why:'the open dialog has no #cred-token/#cred-eye pair'};` +
              `var dBefore=dt.type,pBefore=pt.type;de.click();` +
              `var out={ok:true,dBefore:dBefore,dAfter:dt.type,pBefore:pBefore,pAfterDialogEye:pt.type};` +
              `document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));` +
              `return out;})()`,
            );
            if (!eyeM.ok) {
              fail(D, `show-key-eye@${width}x${height}: ${eyeM.why}`);
              row.push("show-key-eye:!pair");
            } else {
              if (eyeM.dAfter !== "text") {
                credEyeDead++;
                fail(D, `show-key-eye@${width}x${height}: the DIALOG's "Show key" left its own field at type "${eyeM.dAfter}" (from "${eyeM.dBefore}") — the person cannot see the key they are typing into the sheet they are looking at`);
              }
              if (eyeM.pAfterDialogEye !== eyeM.pBefore) {
                credEyeDead++;
                fail(D, `show-key-eye@${width}x${height}: pressing the DIALOG's eye changed the PAGE card's field from "${eyeM.pBefore}" to "${eyeM.pAfterDialogEye}" — the sheet reached behind itself and revealed a secret on a screen the person is not looking at`);
              }
              await credWait(`(function(){var r=document.getElementById('modal-root');return !!(r&&r.hidden);})()`);
              const eyeAfter = await evalJs(
                `(function(){var t=document.querySelector('#provider-connect #cred-token');` +
                `var e=document.querySelector('#provider-connect #cred-eye');` +
                `if(!t||!e) return {ok:false,why:'the providers card lost its #cred-token/#cred-eye pair'};` +
                `var before=t.type;e.click();return {ok:true,before:before,after:t.type};})()`,
              );
              if (!eyeAfter.ok) {
                fail(D, `show-key-eye@${width}x${height}: ${eyeAfter.why}`);
              } else if (eyeAfter.after === eyeAfter.before) {
                credEyeDead++;
                fail(D, `show-key-eye@${width}x${height}: after the dialog had been opened and dismissed, the PAGE card's eye is a NET NO-OP — one press left the field at "${eyeAfter.after}" (two handlers, two toggles). The baseline above proves it worked a moment earlier, so this is the dialog's residue, not a broken control`);
              }
              row.push(`show-key-eye:base ${eyeBase.before}->${eyeBase.after}->${eyeBase.back} dlg ${eyeM.dBefore}->${eyeM.dAfter} page-after ${eyeAfter.before}->${eyeAfter.after}`);
            }
          }
        }

        process.stdout.write(`   ${width}x${height}  ${row.join("  ")}\n`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${credCells} / ${credCells} cells clean across ${CRED_DIALOG_VIEWPORTS.map(([w, h]) => `${w}x${h}`).join("/")} on ${CRED_DIALOG_SCEN} — ` +
          `${credPosts} \`POST /v1/providers\` recorded and every one of them READ BACK: the body carries the ` +
          `sentinel typed into the host the person was looking at, never merely "a request happened". ` +
          `${credTwoHost} cells confirmed the TWO-HOST condition (>= 2 \`#cred-token\` in the document) before ` +
          `driving the dialog, so the painted cells provably entered the state the defect lives in; the ` +
          `\`#overview\` control has one host and is what proves a fix removed the bug rather than relocating ` +
          `it. ${credDead} dead controls, ${credWrongBody} wrong-host bodies, ${credOpenSheet} sheets left open ` +
          `after a 201, ${credDouble} duplicate writes, ${credEyeDead} dead or self-cancelling show-key eyes`,
        );
        okLine(
          `THE DUPLICATE-WRITE CELL ASSERTS ITS OWN HONESTY FIRST: it stamps the \`#provider-connect\` node ` +
          `before the modal opens and reds if that node is not still mounted at submit time, because a ` +
          `re-navigation repaints the card (loadProviders), clears the leaked handler and would green the ` +
          `single-POST assertion by construction. No fixture and no scenario was edited to build this leg — ` +
          `the recorder wraps \`window.fetch\` in the page for the duration of the cell, so no other oracle ` +
          `reading \`scenarios.mjs\` or \`__preview__/fixtures\` can move because this one was added`,
        );
      }
    }

    // ── W25: THE LAUNCH CATALOG AFTER A CONNECT — the console contradicting
    //    the person about a fact THEY established ten seconds earlier.
    //
    //    THE PERSON BODY. A fresh team has no instances, so the launch wizard
    //    renders INLINE in the overview body (the header launch button is
    //    hidden at that population). They type a name; the hosting panel says
    //    "Connect a Hetzner Cloud account to provision here" and offers the
    //    door; they walk through it, paste a key, and get a 201 and the toast
    //    "Provider connected". The panel behind the toast still says they have
    //    no account, and still offers to connect it. `submitProviderCred`'s
    //    success branch called `loadProviders()`, which repaints
    //    `#view-providers` — a view that is HIDDEN on this route — and never
    //    re-ran the wizard's catalog mount.
    //
    //    THE SECOND BODY, ON THE SAME SEAM. With >= 1 instance the wizard opens
    //    as a MODAL, and `openModal` owns ONE body: pressing the same door
    //    OVERWRITES `#launch-modal-slot`, so the wizard and the typed name
    //    leave the document before the key is even entered. The 201 then left
    //    the person on `#overview` with nothing to carry on from.
    //
    //    NOTHING REACHED ANY OF THIS. `git grep -l launch-connect-provider --
    //    cloud/priv/static/__preview__ .github` named no instrument before this
    //    leg; the only repo pin asserts the button's STRING appears in a
    //    generated fragment, which is a fixture that cannot produce the defect
    //    and a selector that cannot reach it.
    //
    //    THE FIXTURE HAS TO MODEL A SERVER THAT CHANGED. This defect is only
    //    visible if the catalog read ANSWERS DIFFERENTLY after the connect —
    //    on a mock that 404s `no_provider` forever, a panel still offering the
    //    door is HONEST, and a leg asserting otherwise would demand the UI
    //    invent an account. So the cell's own `window.fetch` wrapper (the
    //    W24 recorder's technique, nothing under `__preview__/fixtures` or
    //    `scenarios.mjs` touched) answers the catalog read `404 no_provider`
    //    until a `POST /v1/providers` succeeds and a real priced catalog after
    //    — and that flip is ASSERTED by an independent read per cell, because
    //    a shim that silently stopped flipping would green every assertion
    //    below by construction.
    if (requested.includes("W25-launch-catalog-after-connect")) {
      const D = "W25-launch-catalog-after-connect";
      // BLOCK-SCOPED (D247): these axes belong to this leg alone.
      // `empty` is the ONLY shape the runway body exists on — no instances, no
      // providers fixture, no `catalog` fixture (so the pre-connect read is the
      // honest 404) and no `providerConnect` override (so the POST is the
      // default 201). `providers-connected` carries `liveInstance`, which is
      // what puts the wizard in the MODAL and gives the second body its seat.
      const LCC_RUNWAY_SCEN = "empty";
      const LCC_MODAL_SCEN = "providers-connected";
      const LCC_VIEWPORTS = [[390, 844], [1000, 800]];
      // ANTI-VACUITY 0 — the axes. This leg measures a REMOUNT, not a paint,
      // but width decides whether the person can reach either wizard at all:
      // the modal body is opened through the topbar scope menu, and the runway
      // is the phone-first first-run screen. A leg that drove one width could
      // not tell you which half it had proven.
      if (!LCC_VIEWPORTS.some(([w]) => w <= 430)) {
        fail(D, `axis check: no phone width in the viewport set — the empty-fleet runway is the first screen a new team meets on a phone, and this leg exists to say whether it lies to them there`);
      }
      if (!LCC_VIEWPORTS.some(([w]) => w >= 900)) {
        fail(D, `axis check: no desktop width in the viewport set — the modal wizard is reached through the topbar scope menu, and most operators connect a provider from a laptop`);
      }
      process.stdout.write(
        `\n${D} — ${LCC_VIEWPORTS.length} viewports x 2 cells (${LCC_RUNWAY_SCEN} runway + ${LCC_MODAL_SCEN} modal)` +
        ` (type a name -> the catalog's Connect door -> a real 201 -> what the wizard says about the account that now exists)\n`,
      );

      const lccWait = async (expr) => {
        for (let w = 0; w < RENDER_CAP; w += 100) {
          let v = false;
          try { v = !!(await evalJs(`!!(${expr})`)); } catch { /* mid-render */ }
          if (v) return true;
          await sleep(100);
        }
        return false;
      };
      // A unique `cell` param per navigation: these cells differ only by hash
      // on the modal scenario, and a fragment-only navigation is a SAME-document
      // navigation that keeps the previous cell's DOM (the W24 leg measured
      // exactly that trap).
      const lccUrl = (scen, hash, tag) =>
        `${BASE}/?scen=${scen}&theme=light&cell=${encodeURIComponent(tag)}${hash}`;
      // The server model, installed over whatever mock.js put on `window.fetch`:
      // record the connect, and let the catalog read answer like a control plane
      // that now has a credential. The priced rows are the shape router.ex
      // serves (regions[] + server_types[]); nothing else on the page changes.
      const lccArm = () => evalJs(
        `(function(){window.__lccPosts=[];window.__lccConnected=false;` +
        `if(window.__lccProbe) return true;` +
        `window.__lccProbe=true;var of=window.fetch;` +
        `var CAT={currency:"EUR",regions:[{slug:"fsn1",name:"Falkenstein"}],` +
        `server_types:[{slug:"cx22",cores:2,ram_gb:4,disk_gb:40,monthly_price:4.59}]};` +
        `window.fetch=function(i,init){` +
        `var u=typeof i==='string'?i:((i&&i.url)||'');` +
        `var m=String((init&&init.method)||(i&&i.method)||'GET').toUpperCase();` +
        `if(m==='GET'&&/\\/v1\\/providers\\/[^/]+\\/catalog$/.test(u)&&window.__lccConnected){` +
        `return Promise.resolve(new Response(JSON.stringify(CAT),` +
        `{status:200,headers:{"Content-Type":"application/json"}}));}` +
        `if(m==='POST'&&u.indexOf('/v1/providers')>=0){window.__lccPosts.push(u);` +
        `return of.apply(this,arguments).then(function(res){` +
        `if(res.status===201) window.__lccConnected=true; return res;});}` +
        `return of.apply(this,arguments);};return true;})()`,
      );
      // The shim's own honesty check, per cell: after the 201 the modelled
      // server MUST answer the catalog read 200. If it does not, every
      // assertion below is asking the wizard to paint an account that does not
      // exist, and a stale panel would be the honest answer.
      // Needs its OWN Runtime.evaluate: evalJs omits awaitPromise, so it would
      // hand back an unresolved Promise handle instead of the status.
      const lccFlipped = async () => {
        const r = await cdp.send(
          "Runtime.evaluate",
          { expression: `fetch('/v1/providers/hetzner/catalog').then(function(r){return r.status;})`, returnByValue: true, awaitPromise: true },
          sessionId,
        );
        if (r.exceptionDetails) return -1;
        return r.result.value;
      };
      // Walk the door: press it, land in the credential dialog, type the key
      // into the DIALOG's own field and press the DIALOG's own button. Every
      // gesture is one a person makes.
      // `settle` is what "the sheet is done with them" MEANS on each path, and
      // the two are genuinely different: on the runway the dialog closes and
      // the wizard behind it is still there, while on the modal path the same
      // body is REUSED to re-enter the wizard, so `#modal-root` correctly never
      // goes hidden. Both spellings assert the same thing — the credential form
      // the person already submitted is off their screen.
      const lccConnect = async (scope, sentinel, settle) => {
        const pressed = await evalJs(
          `(function(){var b=document.querySelector(${JSON.stringify(scope)}+' .launch-connect-provider');` +
          `if(!b) return {ok:false,why:'no .launch-connect-provider door in ' + ${JSON.stringify(scope)}};` +
          `b.click();return {ok:true};})()`,
        );
        if (!pressed.ok) return pressed;
        if (!await lccWait(`document.querySelector('#modal-root #cred-token')`)) {
          return { ok: false, why: "the credential dialog never rendered its own #cred-token after the door was pressed" };
        }
        const typed = await evalJs(
          `(function(){var t=document.querySelector('#modal-root #cred-token');` +
          `var s=document.querySelector('#modal-root #cred-submit');` +
          `if(!t||!s) return {ok:false,why:'the open dialog has no #cred-token/#cred-submit pair'};` +
          `t.value=${JSON.stringify(sentinel)};s.click();return {ok:true};})()`,
        );
        if (!typed.ok) return typed;
        if (!await lccWait(`(window.__lccPosts||[]).length > 0`)) {
          return { ok: false, why: "pressing the dialog's button produced ZERO `POST /v1/providers` — nothing was connected, so nothing below could have been about a connected account" };
        }
        if (settle === "closed") {
          if (!await lccWait(`(function(){var r=document.getElementById('modal-root');return !!(r&&r.hidden);})()`)) {
            return { ok: false, why: "the credential sheet never closed after the 201 — the drive stopped where W24 already measured" };
          }
        } else if (!await lccWait(`!document.querySelector('#modal-root #cred-token')`)) {
          return { ok: false, why: "the credential form is STILL on screen after the 201 — the person is staring at a sheet they already submitted, and nothing about where they were returned to can be read off that" };
        }
        return { ok: true };
      };

      let lccCells = 0, lccStale = 0, lccLostName = 0, lccDead = 0;
      for (const [width, height] of LCC_VIEWPORTS) {
        const row = [];

        // ── (a) THE RUNWAY. Inline wizard, survives the sheet: its catalog
        //        must be repainted against the account that now exists.
        lccCells++;
        await setViewport(width, height);
        await nav(
          lccUrl(LCC_RUNWAY_SCEN, "#overview", `runway-${width}`),
          `document.querySelector('#view-overview .launch-form .form-input')`,
        );
        await lccArm();
        const runwaySentinel = `Runway Alpha ${width}`;
        // PRECONDITION: the lie has to be ON SCREEN before the connect, or this
        // cell never entered the state the defect lives in.
        const before = await evalJs(
          `(function(){var v=document.getElementById('view-overview');` +
          `if(!v) return {ok:false,why:'#view-overview is not in the document'};` +
          `var c=v.querySelector('.launch-catalog');` +
          `if(!c) return {ok:false,why:'the runway wizard rendered no .launch-catalog panel'};` +
          `return {ok:true,doors:v.querySelectorAll('.launch-connect-provider').length,` +
          `text:(c.textContent||'').replace(/\\s+/g,' ').trim()};})()`,
        );
        if (!await lccWait(`(function(){var v=document.getElementById('view-overview');return !!(v&&v.querySelector('.launch-connect-provider'));})()`)) {
          lccDead++;
          fail(D, `runway@${width}x${height}: the empty-fleet runway never offered a \`.launch-connect-provider\` door (catalog panel: ${JSON.stringify((before && before.text) || "")}) — the person body starts at that door, so this cell measured nothing`);
          row.push("runway:!door");
        } else {
          const typedName = await evalJs(
            `(function(){var i=document.querySelector('#view-overview .launch-form .form-input');` +
            `if(!i) return {ok:false,why:'the runway wizard has no name field'};` +
            `i.value=${JSON.stringify(runwaySentinel)};return {ok:true};})()`,
          );
          if (!typedName.ok) {
            lccDead++;
            fail(D, `runway@${width}x${height}: ${typedName.why}`);
            row.push("runway:!name");
          } else {
            const walked = await lccConnect("#view-overview", `w25-runway-key-${width}`, "closed");
            if (!walked.ok) {
              lccDead++;
              fail(D, `runway@${width}x${height}: ${walked.why}. Nothing below this line was measured`);
              row.push("runway:!connect");
            } else {
              const status = await lccFlipped();
              if (status !== 200) {
                fail(D, `runway@${width}x${height}: after the 201 the modelled control plane still answers \`GET /v1/providers/hetzner/catalog\` with ${status}, not 200 — a panel that keeps offering to connect would then be TELLING THE TRUTH, and every assertion in this cell would be green-by-construction nonsense. The cell asserts nothing until the server it models changes`);
                row.push(`runway:!flip(${status})`);
              } else {
                // Bounded wait for the remount, then read whatever is there —
                // a timeout must produce the FINDING, never a skip.
                await lccWait(`(function(){var v=document.getElementById('view-overview');return !!(v&&!v.querySelector('.launch-connect-provider'));})()`);
                const after = await evalJs(
                  `(function(){var v=document.getElementById('view-overview');` +
                  `var c=v&&v.querySelector('.launch-catalog');` +
                  `var i=document.querySelector('#view-overview .launch-form .form-input');` +
                  `return {doors:v?v.querySelectorAll('.launch-connect-provider').length:-1,` +
                  `text:c?(c.textContent||'').replace(/\\s+/g,' ').trim():'(no .launch-catalog panel)',` +
                  `region:!!(v&&v.querySelector('.launch-region')),` +
                  `name:i?i.value:null};})()`,
                );
                if (after.doors !== 0 || /Connect a .* account to provision here/.test(after.text)) {
                  lccStale++;
                  fail(D, `runway@${width}x${height}: the person connected the account and the wizard STILL offers to connect it — ${after.doors} \`.launch-connect-provider\` door(s) and the panel reads ${JSON.stringify(after.text)}. Before the connect it read ${JSON.stringify(before.text)} with ${before.doors} door(s), so the screen did not move at all: the console is contradicting the person about the one fact they just established`);
                } else if (!after.region) {
                  lccStale++;
                  fail(D, `runway@${width}x${height}: the Connect door is gone but no \`.launch-region\` took its place — the panel now reads ${JSON.stringify(after.text)}, which is neither the old lie nor the connected account's catalog. A person who just connected still cannot choose where to run`);
                }
                if (after.name !== runwaySentinel) {
                  lccLostName++;
                  fail(D, `runway@${width}x${height}: the typed instance name did not survive the connect — the field reads ${JSON.stringify(after.name)}, the person typed ${JSON.stringify(runwaySentinel)}. The runway wizard is rendered INLINE and is not supposed to be rebuilt by a remount of its catalog`);
                }
                row.push(`runway:doors ${before.doors}->${after.doors} region=${after.region} name=${JSON.stringify(after.name)}`);
              }
            }
          }
        }

        // ── (b) THE MODAL. The sheet DESTROYS this wizard, so the only honest
        //        return is to re-enter it with the name the person typed.
        lccCells++;
        await setViewport(width, height);
        await nav(
          lccUrl(LCC_MODAL_SCEN, "#overview", `modal-${width}`),
          `(function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-overview';})()`,
        );
        await lccArm();
        const modalSentinel = `Modal Alpha ${width}`;
        const opened = await evalJs(
          `(function(){var sw=document.getElementById('scope-switch');` +
          `if(!sw) return {ok:false,why:'no #scope-switch in the topbar'};` +
          `sw.click();var l=document.getElementById('scope-launch');` +
          `if(!l) return {ok:false,why:'#scope-launch never rendered into the scope menu'};` +
          `l.click();return {ok:true};})()`,
        );
        if (!opened.ok || !await lccWait(`document.querySelector('#modal-root .launch-connect-provider')`)) {
          lccDead++;
          fail(D, `modal@${width}x${height}: the modal launch wizard never offered a \`.launch-connect-provider\` door — ${opened.ok ? "the wizard opened but its catalog panel did not resolve no_provider" : opened.why}`);
          row.push("modal:!door");
        } else {
          // Stamp the wizard's own slot: this cell is only a measurement if the
          // sheet really does take the wizard with it. If the slot survives,
          // the premise changed and "the person was returned" would be green
          // by construction.
          const stamped = await evalJs(
            `(function(){var i=document.querySelector('#modal-root .launch-form .form-input');` +
            `if(!i) return {ok:false,why:'the modal wizard has no name field'};` +
            `i.value=${JSON.stringify(modalSentinel)};` +
            `window.__lccSlot=document.getElementById('launch-modal-slot');` +
            `return {ok:!!window.__lccSlot,why:'#launch-modal-slot is not in the document'};})()`,
          );
          if (!stamped.ok) {
            lccDead++;
            fail(D, `modal@${width}x${height}: ${stamped.why}`);
            row.push("modal:!slot");
          } else {
            const walked = await lccConnect("#modal-root", `w25-modal-key-${width}`, "wizard");
            const destroyed = await evalJs(`!(window.__lccSlot && window.__lccSlot.isConnected)`);
            if (!walked.ok) {
              lccDead++;
              fail(D, `modal@${width}x${height}: ${walked.why}. Nothing below this line was measured`);
              row.push("modal:!connect");
            } else if (!destroyed) {
              fail(D, `modal@${width}x${height}: the \`#launch-modal-slot\` stamped before the door was pressed is STILL MOUNTED — the sheet no longer overwrites the wizard, so this cell never entered the condition it exists to measure and its "the person was returned" assertion would pass without proving anything`);
              row.push("modal:!premise");
            } else {
              const status = await lccFlipped();
              if (status !== 200) {
                fail(D, `modal@${width}x${height}: the modelled control plane still answers the catalog read with ${status} after the 201 — see the runway cell's note; nothing here can be asserted against a server that did not change`);
                row.push(`modal:!flip(${status})`);
              } else {
                await lccWait(`document.querySelector('#modal-root .launch-form .form-input')`);
                const back = await evalJs(
                  `(function(){var r=document.getElementById('modal-root');` +
                  `var i=document.querySelector('#modal-root .launch-form .form-input');` +
                  `return {modalHidden:!!(r&&r.hidden),wizard:!!i,name:i?i.value:null,` +
                  `doors:document.querySelectorAll('#modal-root .launch-connect-provider').length,` +
                  `view:(function(){var v=document.querySelector('section.view:not([hidden])');return v?v.id:'none';})()};})()`,
                );
                if (back.modalHidden || !back.wizard) {
                  lccStale++;
                  fail(D, `modal@${width}x${height}: after the 201 the person is NOT back in the launch wizard — modal hidden=${back.modalHidden}, wizard present=${back.wizard}, rendered view "${back.view}". They came to launch an instance, typed its name, connected an account because the console asked them to, and were left on a screen with nothing to carry on from`);
                } else if (back.doors !== 0) {
                  lccStale++;
                  fail(D, `modal@${width}x${height}: the wizard came back but its catalog still offers ${back.doors} Connect door(s) for the account that was just connected`);
                }
                if (back.wizard && back.name !== modalSentinel) {
                  lccLostName++;
                  fail(D, `modal@${width}x${height}: the wizard came back EMPTY — the name field reads ${JSON.stringify(back.name)}, the person typed ${JSON.stringify(modalSentinel)}. Being returned to a form you have to retype is being sent back to the start with extra steps`);
                }
                row.push(`modal:slot=destroyed back=${back.wizard} doors=${back.doors} name=${JSON.stringify(back.name)}`);
              }
            }
          }
        }

        process.stdout.write(`   ${width}x${height}  ${row.join("  ")}\n`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${lccCells} / ${lccCells} cells clean across ${LCC_VIEWPORTS.map(([w, h]) => `${w}x${h}`).join("/")} — ` +
          `on \`${LCC_RUNWAY_SCEN}\` the inline runway's catalog was REPAINTED after the 201 (the Connect door ` +
          `count went to 0, a \`.launch-region\` took its place, and the typed name survived), and on ` +
          `\`${LCC_MODAL_SCEN}\` the wizard the sheet destroyed was RE-ENTERED carrying that name. ` +
          `${lccStale} stale catalogs, ${lccLostName} lost names, ${lccDead} unreachable doors`,
        );
        okLine(
          `EVERY CELL PROVED ITS OWN PREMISE BEFORE ASSERTING ANYTHING: the runway cell reds unless the ` +
          `Connect door was on screen BEFORE the connect, the modal cell reds unless the stamped ` +
          `\`#launch-modal-slot\` really left the document, and BOTH red unless an independent ` +
          `\`GET /v1/providers/hetzner/catalog\` answers 200 after the 201 — because a catalog that is still ` +
          `\`no_provider\` makes "the panel still offers Connect" the TRUTHFUL answer and every assertion here ` +
          `green by construction. No fixture and no scenario was edited: the server model is a \`window.fetch\` ` +
          `wrapper installed in the page for the life of the cell`,
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
      // cchi-w23: the sub-population the containment sentence is ABOUT.
      let tabStrips = 0, tabLinks = 0, stripsOver = 0, stripCells = 0;
      const stripOx = new Set();
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
              `  copies:0,urlCopies:0,worst:0,bad:[],strips:[],tabStrips:0,tabLinks:0};` +
              `[].slice.call(document.querySelectorAll('.copy-btn')).forEach(function(b,i){` +
              `  var r=b.getBoundingClientRect(); out.copies++;` +
              `  if(b.closest('.detail-url')) out.urlCopies++;` +
              `  if(r.right>out.worst) out.worst=+r.right.toFixed(2);` +
              `  if(r.right>d.clientWidth+0.5) out.bad.push({i:i,right:+r.right.toFixed(2),` +
              `    inUrl:!!b.closest('.detail-url'),lbl:(b.getAttribute('aria-label')||b.title||'copy').slice(0,32)});` +
              `});` +
              // The containment claim, measured rather than assumed: any strip
              // wider than its own box must own a non-visible overflow-x.
              //
              // cchi-w23 — `strips` IS A DEFECT LIST, NOT A CENSUS, so it is no
              // longer the only thing carried out. It is pushed ONLY when
              // `sw > cw`, which means an empty `strips` cannot tell "every strip
              // fits" from "there is no strip". Driven: renaming the SOLE
              // emitting template (`<nav class="inst-tabs">`, app.js) left this
              // leg at rc=0 with BYTE-IDENTICAL output — second ok-line and all —
              // while its sentence about `.inst-tabs` had zero elements behind
              // it. `tabStrips` and `tabLinks` are the census the refusals below
              // are built on.
              `[].slice.call(document.querySelectorAll('.inst-tabs')).forEach(function(s){` +
              `  out.tabStrips++; out.tabLinks+=s.querySelectorAll('a.inst-tab').length;` +
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
            // (3) THE CONTAINMENT, asserted rather than allowlisted — AND ITS
            //     POPULATION COUNTED FIRST (cchi-w23). The second ok-line below
            //     is a sentence about `.inst-tabs`; with zero of them in the DOM
            //     it is a claim this leg's selector cannot back, and that is
            //     exactly the state the rename mutation reproduced at rc=0.
            if (m.tabStrips === 0) {
              fail(D, `${scen}/${theme}@${width}: zero \`.inst-tabs\` in the instance workspace — this leg's second ok-line asserts that the tab strip CONTAINS its own scroll, and a claim about an element that is not in the DOM is not a measurement. The strip's absence would also silently retire the a.inst-tab false positive this leg exists to exclude by construction.`);
              row.push(`${width}:0t`);
              continue;
            }
            // SECOND ORDER, the `withBtns === 0` shape: a strip with no tabs in
            // it contains nothing, so "the strip scrolls itself" is true of an
            // empty box. The overflow it is asserted to own comes FROM the tabs.
            if (m.tabLinks === 0) {
              fail(D, `${scen}/${theme}@${width}: ${m.tabStrips} \`.inst-tabs\` carrying ZERO \`a.inst-tab\` — an empty strip trivially satisfies "contains its own scroll" because there is nothing to contain, which is not what this leg claims`);
            }
            tabStrips += m.tabStrips;
            tabLinks += m.tabLinks;
            if (m.strips.length) { stripsOver += m.strips.length; stripCells++; }
            for (const s of m.strips) {
              stripOx.add(s.ox);
              if (s.ox === "visible") {
                fail(D, `${scen}/${theme}@${width} .inst-tabs: scrollWidth ${s.sw} > clientWidth ${s.cw} with computed overflow-x:visible — the tab strip stopped containing its own scroll, so its tabs now push the PAGE instead of scrolling inside it`);
              }
            }
            row.push(`${width}:${m.psw}${m.psw !== m.pcw ? "!" : ""}/c${m.copies}@${m.worst}${m.bad.length ? " !" + m.bad.length : ""}`);
          }
          process.stdout.write(`   ${scen}/${theme}  ${row.join("  ")}\n`);
        }
      }
      // cchi-w23 — THE CONTAINMENT AXIS MUST HAVE FIRED SOMEWHERE. Every strip
      // fitting its box at every width is not a refutation of the claim, it is
      // the claim never being TESTED: `overflow-x` is only decidable where
      // `scrollWidth > clientWidth`, so a run in which no strip ever overflowed
      // would let the strip compute `visible` without a word. This is the
      // leg-level companion to the per-cell presence refusal above, and the
      // reason the width set reaches down to 320 (measured: the strip overflows
      // at 320/360/375/390 and fits from 430 up).
      if (tabStrips > 0 && stripsOver === 0) {
        fail(D, `no \`.inst-tabs\` was WIDER than its own box in any of the ${cells} cells (${tabStrips} strips seen) — the containment assertion (\`overflow-x\` must not compute \`visible\`) is only decidable on an overflowing strip, so it fired nowhere and this leg's second ok-line would be a sentence nothing measured`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${copiesSeen} .copy-btn measured, ${offscreen} outside the viewport, ` +
          `${pageOver} pages scrolling sideways) across ${HEAD_WIDTHS.join("/")} on ${HEAD_SCENS.join(" + ")}; ` +
          `cells print scrollWidth/copy-count@worst-right-edge, so 320's 320/c3@304 reads against the 342/c3@342 ` +
          `it replaced. The band is 320-ONLY: 360-620 are the no-regression control, not padding`,
        );
        okLine(
          `\`a.inst-tab\` at 360-390 is NOT suppressed here — .inst-tabs computes overflow-x:${[...stripOx].join("/") || "n/a"}, so the strip ` +
          `scrolls itself and never moves documentElement.scrollWidth; that containment is asserted per cell ` +
          `(a strip that ever computed overflow-x:visible reds) instead of being allowlisted away. THE POPULATION ` +
          `BEHIND THAT SENTENCE, printed rather than assumed: ${tabStrips} \`.inst-tabs\` and ${tabLinks} \`a.inst-tab\` ` +
          `across ${cells} cells (zero of either, in ANY cell, REDS — renaming the sole emitting template used to leave ` +
          `this line byte-identical with nothing behind it), of which ${stripCells} cell(s) carried a strip actually WIDER ` +
          `than its box, i.e. ${stripsOver} strip(s) on which \`overflow-x\` was decidable at all; zero of those also REDS`,
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
      // cchi-w21-bl-cruel-corpus-does-not-cover-three-hosts: the roster is now
      // ALSO driven at the server's own email cap (one 160-char unbroken
      // address, members-cruel-content) — before this the leg measured
      // .set-row-name at 12-14 fixture-kind characters only.
      const MEM_SCENS = ["members-populated", "members-cruel-content"];
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
              // `overflow` IS THE THIRD LEG OF THE CUE (cch-w29-s3). `ellipsis`
              // paints only where the box actually clips; the model arm below
              // (`ov:cs.overflow`) has always read it, this arm never did.
              // …and the DECIDING axis is read by name. `overflow` is a
              // shorthand: `overflow-x: visible; overflow-y: clip` is a legal
              // pair the spec does NOT blockify, so it serialises as
              // "visible clip" and a shorthand test for the literal "visible"
              // would let a box that does not clip HORIZONTALLY — the only axis
              // a single-line ellipsis cares about — score as a paintable cue.
              // The shorthand is still collected because it is what a reader
              // recognises in the failure sentence.
              `      ov:cs.overflow,ox:cs.overflowX,` +
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
              // A CUE THAT CAN ACTUALLY PAINT, ON ALL THREE LEGS. `text-overflow`
              // is inert unless the line is forbidden to wrap AND the box itself
              // clips — declaring `ellipsis` beside `white-space: normal` is a
              // sentence, and so is declaring it beside `overflow: visible`,
              // where the text simply spills past the box in full view of
              // nothing. `pre-wrap` and `pre-line` WRAP, so they are not on the
              // white-space list; `visible` is the ONLY computed overflow value
              // that suppresses the ellipsis, which is why this leg tests for it
              // by name rather than for "some kind of clip" (cch-w29-s3) — and
              // it tests the X AXIS, because that is the only one a single-line
              // ellipsis truncates on and the shorthand can legally read
              // "visible clip" while the horizontal axis does not clip at all.
              const cuePaints = n.te === "ellipsis" && (n.ws === "nowrap" || n.ws === "pre") && n.ox !== "visible";
              if (n.sw > n.cw && !cuePaints) {
                clipped++;
                // THE SENTENCE NAMES THE LEG THAT ACTUALLY FAILED. Blaming
                // white-space for an `overflow: visible` cause would put this
                // epic's own defect class — a person told the wrong reason —
                // inside the instrument that polices it, so all three computed
                // values are printed and the trailing clause is chosen by which
                // leg is the one standing between the reader and a paintable cue.
                const why = n.ox === "visible"
                  ? `ellipsis is inert while overflow-x computes "visible" — the box does not clip horizontally, so nothing truncates and nothing paints`
                  : `ellipsis is inert unless white-space forbids wrapping`;
                fail(D, `${scen}/${theme}@${width} row${r.i} \`.set-row-name\` "${n.t}": scrollWidth ${n.sw} > clientWidth ${n.cw} — ${n.sw - n.cw}px of the identity is hidden with NO cue that can paint (computed white-space "${n.ws}", text-overflow "${n.te}", overflow "${n.ov}", overflow-x "${n.ox}"; ${why}). This is WHO the row's Remove button acts on`);
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
        fontPinnedEvidence(
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
    //    THE THIRD ROW IS THE FAILED INSTANCE'S OWN DETAIL SCREEN (cch-w24-s2),
    //    and until this wave both rows above were LIST routes — so the one
    //    screen a person opens to read WHY provisioning failed had never been
    //    driven with cruel content by anything in this file. On origin/main
    //    bytes `?scen=fleet-cruel-content#instance/…c2` measured
    //    documentElement.scrollWidth 4040 against 320 and 4280 against 1000,
    //    while this leg printed `88 / 88 cells clean` and the whole guard
    //    exited 0. THREE mechanics that row needed, none of which the pre-w24
    //    table could express:
    //      · A PER-SCENARIO HASH. The failed box exists in ONE fixture, so the
    //        kind control has to live at a DIFFERENT hash (the live instance's
    //        own detail) — with the row's single hash it was exit 2, an
    //        ENVIRONMENT verdict standing in for a missing control.
    //      · A WRAPPER SCOPE PER FINDING. Interpolating `route.sel` put 22 of
    //        44 mutation-run findings on `.instance-card-name`, a clean
    //        bystander; the scope is now MEASURED with `closest()` per element.
    //      · AN EIGHTH CLASS. `provision_error` is admissible AND uncapped at
    //        every layer, which is neither `CRUEL` (no person, no cap) nor
    //        `NONE-POSSIBLE` (a 512-char token paints 3754px, so cruelty has
    //        plenty to measure against) — see `UNCAPPED-DERIVED` below.
    //
    //    FONT PINNED (D218, paid by cch-w22-s1): `nav()` load()s every declared
    //    @font-face, awaits `document.fonts.ready` and check()s each face
    //    before these px are read, so they are taken under a KNOWN face.
    //    The claim this leg stands behind is still the RATIO (0 offending cells
    //    on the kind corpus vs N on the cruel one), not the absolute widths —
    //    and as of cch-w24-s2 BOTH SIDES of that ratio are measured per cell
    //    (`cruelMin` / `kindMax`) instead of asserted by a scenario-name regex.
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
      //   UNCAPPED-DERIVED  (cch-w24-s2) admissible AND uncapped: a machine
      //                   writes the value, NO layer bounds it, and it still
      //                   bites. Distinct from NONE-POSSIBLE, which asserts
      //                   cruelty has nothing to measure against — false here,
      //                   because a 512-char single token paints 3754px. The
      //                   `cap` field therefore cites the ABSENCE BY FILE
      //                   (which migration widened the column, which changeset
      //                   declines to validate it) and the cruel length is the
      //                   SMALLEST MEASURED BITING value rather than the
      //                   largest legal one — with its own load-time refusal in
      //                   the fixture, so the row cannot go kind in silence.
      //                   `provision_error` is the flagship and, today, the only
      //                   member: `provision_jobs.error` is a POSTGRES :text
      //                   column (the `modify :error, :text` migration under
      //                   cloud/priv/repo/migrations) and `ProvisionJob.changeset`
      //                   (registry/provision_job.ex) casts `:error` with ZERO
      //                   `validate_length` among its validations.
      //                   NOT `CRUEL`: that term means a person-typed value AT a
      //                   cap, and there is neither a person nor a cap here.
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
        "BREAKABLE", "ADMIN-ONLY-AT-MINT", "FORMAT-LEGAL", "UNCAPPED-DERIVED",
      ];
      // THE FAILED INSTANCE (cch-w24-s2). Its own detail screen is the ONLY
      // place a person can read WHY provisioning failed, and it is the screen
      // no row above reaches — `#overview` and `#fleet` are LIST routes.
      const CRUEL_FAILED_INST = "5b2c1e00-0000-4000-8000-0000000000c2";
      // TWO FIELDS PER ROW THE PRE-w24 TABLE DID NOT CARRY, and both exist
      // because the axis assertions above are a REGEX OVER THE SCENARIO NAME —
      // a naming rule, not a measurement (D285). Proven: making the KIND
      // control cruel left this leg at exit 0 while it still printed "the KIND
      // corpus (32-char host / 10-char name)", a sentence with its own
      // refutation on the same screen.
      //   cruelMin  the shortest rendered length that still counts as cruel on
      //             this host. A cruel cell below it has GONE KIND.
      //   kindMax   the CEILING the kind control must stay under. There is no
      //             server floor to cite for this number, so it is chosen and
      //             justified per row: it sits comfortably above what the kind
      //             fixture renders today and far below the cruel value, which
      //             is the whole job — it must catch a control that drifted
      //             cruel without tripping on an ordinary edit.
      // `scopes` names the WRAPPER the finding must blame. Blaming `sel` put 22
      // of 44 pre-w24 findings on `.instance-card-name`, a clean bystander.
      const CRUEL_ROUTES = [
        {
          hash: "#fleet", view: "view-fleet", sel: ".fleet-url", ready: ".fleet-row",
          scopes: ".fleet-main, .fleet-status, .fleet-row",
          scens: ["fleet-cruel-content", "mixed-fleet"],
          cap: "barkpark.custom_host <= 253 (registry/barkpark.ex:727) under @external_host_format (:109)",
          class: "CRUEL",
          cruelMin: 253,
          // `mixed-fleet` renders a 32-char host; 64 is double it and a quarter
          // of the cap, so an ordinary hostname edit passes and a drift toward
          // the 253-char twin reds.
          kindMax: 64,
          predicate: "a person reading their fleet can see WHICH HOST a box answers on — the whole value, not the 14% of it that fits",
        },
        {
          hash: "#overview", view: "view-overview", sel: ".instance-card-name", ready: ".instance-card",
          scopes: ".instance-card-head, .instance-card",
          scens: ["fleet-cruel-content", "mixed-fleet"],
          cap: "barkpark.name <= 255 (registry/barkpark.ex:466)",
          class: "INADMISSIBLE",
          cruelMin: 255,
          // `mixed-fleet`'s longest card name is 10 characters. 64 again: the
          // slug cap is 63 and every mint path derives the slug from the name
          // WITHOUT truncation (see INADMISSIBLE above), so a name a person can
          // actually register cannot exceed 63 — which makes 64 the one kind
          // ceiling on this host that is derived rather than picked.
          kindMax: 64,
          predicate: "a person on the overview can tell their instances apart by name. KEPT as an UPPER BOUND, not as a reachability claim: 255 is unreachable (see INADMISSIBLE above), so this row proves the host survives a value CRUELLER than any mint path admits — it does NOT prove anyone can type one",
        },
        {
          // THE DETAIL ROUTE, and it carries a PER-SCENARIO hash because the
          // failed box exists in ONE fixture. `mixed-fleet` has no `…c2`, so a
          // shared hash would not route there at all and the run would die at
          // exit 2 (page never became ready) — an ENVIRONMENT verdict standing
          // in for a missing control. The kind control is the LIVE instance's
          // own detail screen, which both fixtures render.
          //
          // TWO HOSTS IN ONE SELECTOR, on purpose. `.detail-title-row
          // .status-pill-detail` is the pill that CLIPS (the person reads ~30
          // of 512 characters); `.bp-tl-fail` is the timeline's failure box,
          // which does not clip at all — it paints 3754px of ink OUTSIDE itself
          // and DRAGS THE PAGE. Element-hiding bisect on the pre-fix tree:
          // blanking the pill left the page at scrollWidth 4040, blanking
          // `.bp-tl-fail` returned it to 320. A row that measured only the pill
          // would fix the readable half and leave the console scrolling
          // sideways, with `documentElement` as its only witness.
          hash: "#instance/" + CRUEL_FAILED_INST, view: "view-instance", sel: ".detail-title-row .status-pill-detail, .bp-tl-fail",
          ready: ".detail-title-row",
          scopes: ".detail-title-row, .bp-tl-fail, .detail-rail, .attention-row",
          scens: [
            { scen: "fleet-cruel-content" },
            { scen: "mixed-fleet", hash: "#instance/5b2c1e00-0000-4000-8000-0000000000a1" },
          ],
          cap: "provision_jobs.error is UNBOUNDED at every layer — a POSTGRES :text column (the `modify :error, :text` migration under cloud/priv/repo/migrations) and ProvisionJob.changeset (registry/provision_job.ex) casts :error with ZERO validate_length. The row's cruelMin is therefore the smallest MEASURED biting length, not a legal maximum",
          class: "UNCAPPED-DERIVED",
          cruelMin: 512,
          // The kind control is the live instance, whose detail reads "Online"
          // (6 characters). 64 keeps the ceiling identical across all three
          // rows rather than tuning one number per host: any status detail a
          // person is meant to READ AT A GLANCE is a short phrase, and a
          // 64-character one is already past that.
          kindMax: 64,
          predicate: "a person whose instance failed to provision can open its own screen, READ the whole reason, and still use the console — instead of getting an ellipsis in the header and a page dragged 3.7k pixels sideways",
        },
      ];
      // Per-scenario hash, normalized once. A row may hand `scens` a bare
      // scenario name (the hash is the row's) or `{ scen, hash }` (its own).
      const cruelCells = (r) => r.scens.map((s) => (
        typeof s === "string" ? { scen: s, hash: r.hash } : { scen: s.scen, hash: s.hash || r.hash }
      ));
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
        // assertions below able to LOSE in both directions — but a NAME is not
        // a measurement, which is why `cruelMin`/`kindMax` are asserted per
        // CELL further down and required here.
        const cruel = cruelCells(route).filter((c) => /cruel/.test(c.scen));
        const kind = cruelCells(route).filter((c) => !/cruel/.test(c.scen));
        if (!route.scopes) {
          fail(D, `axis check ${at}: the row declares no \`scopes\` — a finding that cannot name the WRAPPER it measured blames the row selector instead, which is how 22 of 44 pre-w24 findings landed on \`.instance-card-name\`, a clean bystander`);
        }
        if (!Number.isFinite(route.cruelMin) || !Number.isFinite(route.kindMax)) {
          fail(D, `axis check ${at}: the row is missing its ${Number.isFinite(route.cruelMin) ? "kindMax ceiling" : "cruelMin floor"} — without both numbers the cruel/kind axis is a REGEX OVER A SCENARIO NAME and nothing measures whether the fixture on either side still is what it is called`);
        } else if (route.kindMax >= route.cruelMin) {
          fail(D, `axis check ${at}: kindMax ${route.kindMax} is not below cruelMin ${route.cruelMin} — the two ceilings overlap, so one string could satisfy BOTH sides of the axis and neither assertion could lose`);
        }
        if (cruel.length === 0) {
          fail(D, `axis check ${at}: this row carries NO cruel fixture (scens: ${cruelCells(route).map((c) => c.scen).join(", ") || "none"}) — a row driven only on kind content measures the corpus every other leg already measures, and its green says nothing about the cap it cites (${route.cap})`);
        }
        if (kind.length === 0) {
          fail(D, `axis check ${at}: this row carries NO kind control (scens: ${cruelCells(route).map((c) => c.scen).join(", ") || "none"}) — without one, a bound that fixes the cruel value by shredding today's rendering scores a clean sweep on this host`);
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
      const CRUEL_SCENS = [...new Set(CRUEL_ROUTES.flatMap((r) => cruelCells(r).map((c) => c.scen)))];
      const cellCount = CRUEL_ROUTES.reduce((n, r) => n + cruelCells(r).length, 0) * CRUEL_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${CRUEL_SCENS.length} scenarios x ${CRUEL_ROUTES.length} routes x ${CRUEL_WIDTHS.length} widths x 2 themes` +
        ` (${cellCount} cells; ${CRUEL_ROUTES.map((r) => r.sel).join(" + ")} scrollWidth vs clientWidth, + documentElement.scrollWidth vs clientWidth)\n`,
      );
      let cells = 0, seen = 0, spilled = 0, pageOver = 0, wentKind = 0, wentCruel = 0;
      for (const route of CRUEL_ROUTES) {
        for (const cell of cruelCells(route)) {
          const scen = cell.scen;
          // The naming rule, restated where it is USED: a fixture is cruel iff
          // it says so in its own name. Both halves of the axis are now
          // asserted per CELL below, so a fixture that drifts across the line
          // reds here instead of quietly re-labelling what this leg measures.
          const isCruel = /cruel/.test(scen);
          for (const theme of ["light", "dark"]) {
            // Enter WIDE and assert the landed view — `?scen=` alone renders
            // #overview and the fleet table goes phantom (the W13/W15 note).
            await setViewport(1000);
            await nav(
              `${BASE}/?scen=${scen}&theme=${theme}${cell.hash}`,
              `document.querySelector('${route.ready}') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='${route.view}';})()`,
            );
            const row = [];
            for (const width of CRUEL_WIDTHS) {
              await setViewport(width);
              const m = await evalJs(
                `(function(){` +
                `var v=document.querySelector('section.view:not([hidden])');` +
                `var d=document.documentElement;` +
                `var out={view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,n:0,bad:[],worst:0,longest:0};` +
                `[].slice.call(document.querySelectorAll(${JSON.stringify(route.sel)})).forEach(function(e,i){` +
                // A node with no text can never clip and must not be counted as
                // a measured assertion (the vacuous-green vector W20-S3 named on
                // `.instance-card-url`: a provisioning box renders the node empty).
                `  var t=(e.textContent||'').trim(); if(!t) return;` +
                `  out.n++;` +
                `  if(t.length>out.longest) out.longest=t.length;` +
                `  if(e.scrollWidth>out.worst) out.worst=e.scrollWidth;` +
                // THE WRAPPER SCOPE, MEASURED RATHER THAN INTERPOLATED (D280).
                // A finding that quotes the ROW selector blames whichever host
                // the row is named after — 22 of 44 pre-w24 findings landed on
                // `.instance-card-name`, a clean bystander — and two rows
                // sharing a selector degrade a derived header to
                // `.status-pill-detail + .status-pill-detail`. `closest()`
                // includes the element itself, so a box that IS its own wrapper
                // (`.bp-tl-fail`) reports itself, which is the truthful answer.
                `  var sc=e.closest(${JSON.stringify(route.scopes || "*")});` +
                `  var scope=(sc&&sc.classList.length)?('.'+sc.classList[0]):(sc?sc.tagName.toLowerCase():'<outside every declared scope>');` +
                `  var cs=getComputedStyle(e);` +
                `  if(e.scrollWidth>e.clientWidth) out.bad.push({i:i,len:t.length,sw:e.scrollWidth,cw:e.clientWidth,t:t.slice(0,28),scope:scope,ow:cs.overflowWrap,ws:cs.whiteSpace,te:cs.textOverflow,ov:cs.overflow});` +
                `});` +
                `return out;})()`,
              );
              cells++;
              if (m.view !== route.view) {
                fail(D, `${scen}/${theme}@${width}${cell.hash}: rendered section.view "${m.view}", asked for "${route.view}" — the hash did not route, so nothing below this line measures ${route.sel}`);
                row.push(`${width}:?`);
                continue;
              }
              if (m.theme !== theme) fail(D, `${scen}/${theme}@${width}${cell.hash}: data-theme is "${m.theme}" — the theme did not apply`);
              if (m.n === 0) {
                fail(D, `${scen}/${theme}@${width}${cell.hash}: zero NON-EMPTY \`${route.sel}\` rendered — nothing was measured, this is not a pass`);
                row.push(`${width}:0`);
                continue;
              }
              seen += m.n;
              // ── THE AXIS, ASSERTED IN BOTH DIRECTIONS (D285) ──────────────
              // The one-sided version — a name regex here, a load-time throw in
              // the fixture that fires only when a CRUEL string SHORTENS — left
              // a demonstrated hole: making the KIND control cruel kept this
              // leg at exit 0 while it printed a sentence about "the KIND
              // corpus" that the numbers on the same screen refuted.
              if (isCruel && m.longest < route.cruelMin) {
                wentKind++;
                fail(D, `${scen}/${theme}@${width}${cell.hash}: the longest \`${route.sel}\` renders ${m.longest} characters, below this row's cruel floor of ${route.cruelMin} (${route.cap}) — the CRUEL fixture has GONE KIND, so every clean line under it is a pass over ordinary content`);
              }
              if (!isCruel && m.longest > route.kindMax) {
                wentCruel++;
                fail(D, `${scen}/${theme}@${width}${cell.hash}: the KIND control renders ${m.longest} characters, above this row's kind ceiling of ${route.kindMax} — a control that has itself gone cruel cannot show the remedy leaves ordinary content alone, and the "the KIND corpus scores the same" line below would be comparing two cruel corpora`);
              }
              if (m.psw > m.pcw) {
                pageOver++;
                fail(D, `${scen}/${theme}@${width}${cell.hash}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the page is off-screen sideways. A host on this route has no bound, so it never clips ITSELF: it pushes the PAGE, which is invisible to an element-only scorer`);
              }
              for (const b of m.bad) {
                spilled++;
                fail(D, `${scen}/${theme}@${width}${cell.hash} el${b.i} in \`${b.scope}\` (matched \`${route.sel}\`): scrollWidth ${b.sw} > clientWidth ${b.cw} — ${Math.round((1 - b.cw / b.sw) * 100)}% of a ${b.len}-character value ("${b.t}…") is not rendered. Computed ON THE MEASURED ELEMENT: overflow-wrap "${b.ow}", white-space "${b.ws}", text-overflow "${b.te}", overflow "${b.ov}". The scope named here is the wrapper a remedy has to be authored against — not the row's selector`);
              }
              row.push(`${width}:${m.n}x${m.worst}${m.bad.length ? "!" + m.bad.length : ""}${m.psw > m.pcw ? "P" + (m.psw - m.pcw) : ""}`);
            }
            process.stdout.write(`   ${cell.hash} ${scen}/${theme}  ${row.join(" ")}\n`);
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
          `the ROBUST claim is the RATIO, and BOTH SIDES OF IT ARE NOW MEASURED (D285): every cruel cell is asserted ` +
          `AT OR ABOVE its row's cruel floor (${CRUEL_ROUTES.map((r) => r.cruelMin).join("/")}) and every kind cell AT OR BELOW its ` +
          `row's kind ceiling (${CRUEL_ROUTES.map((r) => r.kindMax).join("/")}) — ${wentKind} cruel fixtures had gone kind, ${wentCruel} kind ` +
          `controls had gone cruel. Before this, both halves of the axis were a REGEX OVER THE SCENARIO NAME, and a ` +
          `control driven cruel scored a clean sweep under a header still calling it the kind corpus`,
        );
        okLine(
          `each finding names the WRAPPER SCOPE it measured (${CRUEL_ROUTES.map((r) => r.scopes).join(" | ")}) rather than the ` +
          `row selector — a leg that interpolates \`sel\` blames the family it is named after, which is how a mutation ` +
          `run put 22 of 44 findings on \`.instance-card-name\` while the live defect sat in another wrapper. The px ` +
          `above are taken under a PINNED face (D218, paid by cch-w22-s1): nav() load()s every declared @font-face, ` +
          `awaits document.fonts.ready and check()s each one, refusing at exit 2 rather than measuring a fallback`,
        );
      }
    }

    // ── W21-detail-url-text-page-bound (task-df8a6fced3a408a8): THE INSTANCE
    //    DETAIL SCREEN'S OWN ADDRESS, which cchi-w21-bl-cruel-corpus-does-not-
    //    cover-three-hosts found and deliberately left ungated — that PR's own
    //    commit message: "NOT landed here: a permanent overflow-guard.mjs leg
    //    for .detail-url-text... filed as a follow-up task rather than fixed
    //    or gated on here, since gating a currently-unfixed defect into
    //    overflow-guard.mjs's default run would red the whole guard for every
    //    unrelated PR touching this file." The defect is now fixed (two hosts,
    //    not the one originally assumed — see the app.css comments at
    //    `.detail-title-row h1` and the widened `.detail-head--inst` 899
    //    block), so this leg is the gate that makes it stay fixed.
    //
    //    BISECTED, NOT ASSUMED: `instance-cruel-detail` is cruel on TWO
    //    strings at once (`bp.name` at its 255-char cap AND `custom_host` at
    //    its 253-char cap — scenarios.mjs's own comment on `cruelInstance`:
    //    "the ONLY variable is the length of two strings a person is allowed
    //    to type"). Element-hiding bisection on the PRE-fix tree found the H1
    //    was the sole page-level driver at 320-720 (hiding it alone took
    //    documentElement.scrollWidth from 808 to exactly clientWidth; hiding
    //    `.detail-url-text` alone left it at 808, unchanged) while the
    //    `.detail-head--inst` stretch gap independently drove 720-899
    //    (2000-2240 against a 720-899 viewport). BOTH hosts are asserted here,
    //    per cell, so a regression in either one reds by name rather than the
    //    page-only signal laundering which host broke.
    //
    //    MUTATION-PROVED, both halves independently (this branch): reverting
    //    ONLY the `.detail-title-row h1` fix reds at 320/720 (808 vs
    //    320/720, byte-identical to the pre-fix numbers); reverting ONLY the
    //    `.detail-head--inst` 899-widen (back to 620px) reds at 720/830
    //    (2000/2240 vs 720/830, byte-identical to the pre-fix numbers).
    //    Restoring either alone is not enough — both are load-bearing.
    if (requested.includes("W21-detail-url-text-page-bound")) {
      const D = "W21-detail-url-text-page-bound";
      // BLOCK-SCOPED (the `const D` precedent): the 899 straddle is
      // `.detail-head--inst`'s own stacked/row split, the 620 straddle is the
      // phone-fixture threshold the original H1/URL fixes were bisected
      // against, and 1000/1440 are wide controls.
      const DETAIL_WIDTHS = [320, 360, 390, 430, 480, 620, 720, 830, 899, 900, 1000, 1440];
      const cellCount = DETAIL_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — ${DETAIL_WIDTHS.length} widths x 2 themes (${cellCount} cells; instance-cruel-detail's own ` +
        `H1 + .detail-url-text vs the page)\n`,
      );
      let cells = 0, pageOver = 0, h1Uncut = 0, urlUncut = 0;
      for (const theme of ["light", "dark"]) {
        await setViewport(1000);
        await nav(
          `${BASE}/?scen=instance-cruel-detail&theme=${theme}#instance/5b2c1e00-0000-4000-8000-0000000000c1`,
          `document.querySelector('.detail-url-text') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-instance';})()`,
        );
        const row = [];
        for (const width of DETAIL_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){` +
            `var v=document.querySelector('section.view:not([hidden])');` +
            `var d=document.documentElement;` +
            `var h1=document.querySelector('.detail-title-row h1');` +
            `var url=document.querySelector('.detail-url-text');` +
            `return {view:v?v.id:'none',theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,` +
            `h1sw:h1?h1.scrollWidth:null,h1cw:h1?h1.clientWidth:null,` +
            `usw:url?url.scrollWidth:null,ucw:url?url.clientWidth:null};})()`,
          );
          cells++;
          if (m.view !== "view-instance") {
            fail(D, `${theme}@${width}: rendered section.view "${m.view}", asked for "view-instance" — the hash did not route, so nothing below this line measures the instance detail head`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          if (m.h1cw === null) fail(D, `${theme}@${width}: zero .detail-title-row h1 rendered — nothing was measured, this is not a pass`);
          if (m.ucw === null) fail(D, `${theme}@${width}: zero .detail-url-text rendered — nothing was measured, this is not a pass`);
          const over = m.psw > m.pcw;
          if (over) {
            pageOver++;
            fail(D, `${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the instance detail screen drags sideways`);
          }
          // THE ELEMENT-LEVEL ARM, not only the page: a remedy that trades the
          // page bound for an unbounded host that happens to fit THIS
          // viewport would score clean here and red the instant the fixture's
          // strings grow by one character. h1 wraps (overflow-wrap: break-word)
          // so its own scrollWidth may still exceed a narrow clientWidth by a
          // few px at the token's own break granularity — asserted loosely
          // (a hard multiple of its own box, not zero drift); .detail-url-text
          // ellipsises, so ITS scrollWidth is EXPECTED to exceed clientWidth
          // (that is what "not clipped" would look like in reverse — the
          // defect this leg exists for is the page dragging, not the leaf's
          // own scrollWidth, which the ellipsis is designed to exceed).
          if (m.h1cw !== null && m.h1sw > m.h1cw * 3 && m.h1cw > 40) {
            h1Uncut++;
            fail(D, `${theme}@${width}: .detail-title-row h1 scrollWidth ${m.h1sw} vs clientWidth ${m.h1cw} — more than 3x over, break-word is not breaking`);
          }
          if (m.ucw !== null && m.ucw > m.usw) {
            urlUncut++;
            fail(D, `${theme}@${width}: .detail-url-text clientWidth ${m.ucw} > its own scrollWidth ${m.usw} — an impossible box, the measurement itself is broken`);
          }
          const bad = (over ? 1 : 0);
          row.push(`${width}:${m.psw}${bad ? "!" : ""}`);
        }
        process.stdout.write(`   instance-cruel-detail/${theme}  ${row.join("  ")}\n`);
      }
      if (cells !== cellCount) {
        fail(D, `run check: drove ${cells} cells, the table declares ${cellCount} — the loop measured a different corpus than the header announced`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${DETAIL_WIDTHS.join("/")} x 2 themes on instance-cruel-detail — the ` +
          `253-char custom_host and 255-char name fixture) — 0 pages dragging sideways, 0 h1 break-word failures, ` +
          `0 impossible .detail-url-text boxes`,
        );
        okLine(
          `TWO HOSTS, ONE PAGE (task-df8a6fced3a408a8): the original finding named .detail-url-text alone; ` +
          `element-hiding bisection on this branch found .detail-title-row h1 was the actual page driver at ` +
          `320-720 and the un-stretched .detail-head--inst drove 720-899 independently — both fixed, both ` +
          `mutation-proved on this branch, both asserted here so either regressing reds by name`,
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
        fontPinnedEvidence(
          `D248's mono-face exposure lives on this screen. The clipped/not-clipped verdicts and the ` +
          `character RATIOS are what the pin stands behind`,
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

    // ── W24: THE FIRST-RUN FAILURE SCREEN, WHICH NO INSTRUMENT EVER RENDERED ─
    //    `theater-failed` lives in breakpoint-sweep's SCENARIO_RESIDUE as
    //    `path:/new` (re-derive: `grep -n 'theater-failed' cloud/priv/static/
    //    __preview__/*.mjs` — scenarios.mjs defines it, smoke.mjs asserts its
    //    MARKUP, breakpoint-sweep names it only to skip it). So the one screen
    //    a person reaches when their very first provision fails had never been
    //    laid out at any width by anything in this epic, and the width sweep
    //    structurally cannot reach it: its narrowest cell is 619.
    //
    //    THE DEFECT, measured on origin/main bytes at 320: the hostname in the
    //    failure narration — `hugin.barkpark.cloud` — is TORN MID-WORD across
    //    two lines in `.new-step-detail` and in `.new-console-text`, while the
    //    column that could have held it whole sat ~37px WIDER unused and
    //    documentElement.scrollWidth never moved. The mechanism is D165's, but
    //    NOT via `overflow-wrap: anywhere` (this wave measured 196 `anywhere`
    //    element-instances and not one box narrowed): it is `word-break:
    //    break-word`, the deprecated alias, which lowers min-content exactly as
    //    `anywhere` does and which no ruling in this epic had ever covered.
    //    Both elements computed `overflow-wrap: normal` while carrying it.
    //
    //    WHY THE REMEDY IS `overflow-wrap: break-word` AND NOT A DELETION.
    //    Deleting the declaration is what the survey MEASURED, and it fixes the
    //    tear — but it also restores an UNBREAKABLE min-content, and neither
    //    console body nor step rail carries `overflow-x`, so one cruel string
    //    spills the page sideways. This leg therefore asks the question in two
    //    halves and a fix can only pass BOTH: the real hostname must be whole
    //    (half a, which deletion and the replacement both pass), and a 240-char
    //    unbreakable token injected into the SAME text nodes must not push the
    //    page (half b, which the replacement passes and deletion does not).
    //    That second half is the fixture that makes this leg able to lose in
    //    the direction the cheap remedy fails in.
    //
    //    THE OTHER BREAK SITES ARE DISPOSED HERE, NOT CONVERTED. Re-derive the
    //    population WITH ITS COUNTING RULE, because a census quoted without one
    //    is how two numbers get cited as a pair: `grep -c 'word-break:'
    //    cloud/priv/static/app.css` returns 15 LINES on these bytes, of which
    //    THREE are prose (two comments this row authored, one the pre-existing
    //    D165 note) — leaving 12 live declarations, 14 before this row converted
    //    two. The brief said sixteen; sixteen is not reproducible by any rule
    //    against these bytes. Converting the remainder because they share a
    //    property is the exact green-by-construction this wave exists
    //    to refuse — a conversion with no fixture that could make it fail.
    //      FIVE ARE `break-all`, A DIFFERENT DECLARATION: .token-reveal-input,
    //        .new-env-key, .wh-url, .wh-secret-code, .deploy-rail-live
    //        .site-open. Every one wraps an OPAQUE token — a secret, an env
    //        key, a URL — where breaking mid-token IS the reading aid and the
    //        lowered min-content is the point, not the defect. Out of scope by
    //        kind, not by convenience.
    //      SEVEN ARE THE ALIAS ON SURFACES THIS LEG CANNOT REACH, and each is
    //        named with the reason it went unmeasured rather than "it has
    //        always been there":
    //          .rail-row .v          already carries its own `min-width: 0`, so
    //                                the escape the tear needs is present.
    //          .new-step-probe       same screen, same family as the converted
    //                                .new-step-detail — but theaterFailedSteps
    //                                mounts no probe rows, so this screen has
    //                                no fixture that can produce it. Absence
    //                                measured (the leg walks every text node),
    //                                not assumed.
    //          .deploy-console-line, .deploy-detail   site-deploy surface, not
    //                                /new; no fixture here renders them.
    //          .bp-console-line      the instance-detail timeline console; W13
    //                                and W21 drive that route but neither asks
    //                                this property.
    //          .wh-del-err, .tlv-detail   webhooks and timeline detail; no leg
    //                                in this file renders either.
    //        All seven are filed as cch-w24-bl-word-break-alias-remaining-seven
    //        — a POPULATION to triage with a fixture each, never a to-do list
    //        to convert.
    //
    //    D274/D292: no line numbers. Every citation above is a grep or a class.
    if (requested.includes("W24-theater-failed-hostname-whole")) {
      const D = "W24-theater-failed-hostname-whole";
      // BLOCK-SCOPED (precedent: `const D`, NAME_WIDTHS above). 320 and 360 are
      // the DRIVEN band — 320 is where the tear was measured; 390/430 are
      // SHOULDERS, already whole on origin/main, so they cannot detect the tear
      // and exist only to catch a remedy that breaks the phone layout upward.
      const FAIL_WIDTHS = [320, 360, 390, 430];
      // The token is the fixture's own hostname. Re-derive:
      // `grep -n 'hugin.barkpark.cloud' cloud/priv/static/__preview__/scenarios.mjs`.
      // Zero occurrences found at runtime is a REFUSAL below, not a pass — a
      // fixture that stopped naming the host would make this leg unfalsifiable.
      const HOSTNAME = "hugin.barkpark.cloud";
      // The cruel host is the LONGEST LEGAL one, not an arbitrarily huge one:
      // RFC 1035 caps a DNS label at 63 octets, so 63 chars is the widest
      // unbreakable run any real hostname can present, and a stress built past
      // it would be asserting against a string this screen can never receive.
      // Built, never pasted, so its length is a fact of this line.
      const CRUEL = "a".repeat(63) + ".barkpark.cloud";
      // The URL is DERIVED from the scenario, not transcribed: `theater-failed`
      // is reached by a real path plus a `?bp=` id, and a transcribed uuid rots
      // silently into "the /new launch screen rendered instead".
      const { SCENARIOS } = await import("./scenarios.mjs");
      const sc = SCENARIOS["theater-failed"];
      if (!sc || !sc.pathname || !sc.search) {
        return die(`${D}: SCENARIOS["theater-failed"] no longer carries pathname+search — the failure screen cannot be reached, so nothing was measured`);
      }
      const cellCount = FAIL_WIDTHS.length * 2;
      process.stdout.write(
        `\n${D} — theater-failed + theater-midflight x ${FAIL_WIDTHS.length} widths x 2 themes (${cellCount * 2} cells;` +
        ` the hostname's painted line boxes and every theater box against its own client width, then a` +
        ` ${CRUEL.length}-char cruel-token stress at the narrowest width. h= is the failure card / mid-flight track` +
        ` height at ${FAIL_WIDTHS[0]}, REPORTED — the remedy costs vertical room and no pixel is pinned)\n`,
      );
      let cells = 0, hostsSeen = 0, torn = 0, pageOver = 0, stressRuns = 0, stressSpill = 0;
      let boxOver = 0, midCells = 0, midBoxOver = 0, midPageOver = 0;
      for (const theme of ["light", "dark"]) {
        await setViewport(FAIL_WIDTHS[FAIL_WIDTHS.length - 1]);
        await nav(
          `${BASE}${sc.pathname}${sc.search}&scen=theater-failed&theme=${theme}`,
          `document.querySelector('.new-failed') && document.querySelector('.new-step-detail') && document.querySelector('.new-console-text')`,
        );
        const row = [];
        for (const width of FAIL_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){` +
            `var d=document.documentElement;` +
            `var out={failed:!!document.querySelector('.new-failed'),theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,hosts:0,torn:[],boxes:[],h:0};` +
            // cch-w25-s2 — THE ORDINARY-HOSTNAME HALF. Everything above this
            // asks about the cruel string; this asks about the hostname the
            // fixture actually ships, and on origin/main bytes it FAILED:
            // .new-theater-grid measured sw/cw 251/214 at 320 because a bare
            // `1fr` track floors at min-content. The page number never saw it
            // — the card's left offset kept the spill inside 320 — which is
            // why a page-only leg certified a screen that was already
            // dragging its own card. Boxes, not pages, and no cruel fixture
            // required.
            //   .new-step is in this list for a reason a page number can
            // never reach: the reflow's `margin-left` form passes every
            // page-level assertion in this file while opening a silent 34px
            // internal overflow (.new-step 210/176). Only the padding form is
            // contained, and only this cell can tell the two apart.
            `[].slice.call(document.querySelectorAll('.new-theater-grid,.new-theater-rail,.new-step,.new-step-body')).forEach(function(el){` +
            `  if(el.scrollWidth>el.clientWidth+1) out.boxes.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),sw:el.scrollWidth,cw:el.clientWidth});});` +
            // The height is REPORTED, never asserted: the remedy is known to
            // cost vertical room and a bare pixel pin on a reflowing box is a
            // guard that fails on any honest copy edit. Printed so the trade
            // stays quotable.
            `var fb=document.querySelector('.new-failed');if(fb) out.h=+fb.getBoundingClientRect().height.toFixed(2);` +
            // The painted RUN, not the box: a Range over just the hostname's
            // characters reports one client rect per line box it lands on, so
            // >1 IS the tear a person sees. Measuring the element's box instead
            // would score a torn hostname as clean (the box never overflows —
            // that is the whole point of the defect).
            `var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);` +
            `var n;while((n=w.nextNode())){` +
            `  var t=n.nodeValue||'';var i=t.indexOf(${JSON.stringify(HOSTNAME)});if(i<0) continue;` +
            `  var el=n.parentElement;if(!el||!el.getClientRects().length) continue;` +
            `  out.hosts++;` +
            `  var rg=document.createRange();rg.setStart(n,i);rg.setEnd(n,i+${HOSTNAME.length});` +
            `  var rects=[].slice.call(rg.getClientRects());` +
            `  var tops={},lines=0;rects.forEach(function(r){var k=Math.round(r.top);if(!tops[k]){tops[k]=1;lines++;}});` +
            `  if(lines>1){` +
            `    var cs=getComputedStyle(el);` +
            `    out.torn.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),lines:lines,` +
            `      cw:+el.getBoundingClientRect().width.toFixed(2),wb:cs.wordBreak,ow:cs.overflowWrap});` +
            `  }` +
            `}` +
            `return out;})()`,
          );
          cells++;
          if (!m.failed) {
            fail(D, `theater-failed/${theme}@${width}: no .new-failed on the page — the /new failure screen did not render, so nothing below this line measures it`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `theater-failed/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          // AUDITED: an absent hostname is not a whole hostname. If the fixture
          // stopped naming the host, this leg would print a perfect table about
          // nothing at all.
          if (m.hosts === 0) {
            fail(D, `theater-failed/${theme}@${width}: zero rendered text nodes carry "${HOSTNAME}" — nothing was measured, this is not a pass`);
            row.push(`${width}:0h`);
            continue;
          }
          hostsSeen += m.hosts;
          if (m.psw > m.pcw) {
            pageOver++;
            fail(D, `theater-failed/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the failure screen is off-screen sideways`);
          }
          for (const t of m.torn) {
            torn++;
            fail(D, `theater-failed/${theme}@${width} .${t.cls}: "${HOSTNAME}" is painted across ${t.lines} line boxes in a ${t.cw}px box (word-break:${t.wb}, overflow-wrap:${t.ow}) — the host a person must read to fix their failed setup is torn mid-word`);
          }
          for (const b of m.boxes) {
            boxOver++;
            fail(D, `theater-failed/${theme}@${width} .${b.cls}: scrollWidth ${b.sw} > clientWidth ${b.cw} with the ORDINARY hostname — a theater box is wider than the box that holds it, and no cruel string was needed to do it (origin/main bytes: .new-theater-grid 251/214 at 320; the margin-left form of the time reflow: .new-step 210/176)`);
          }
          // The page pair is printed at EVERY width, not only when it fails:
          // "the fix cost no horizontal room" is a claim about the numbers, and
          // a row that prints them only on failure cannot be quoted for it.
          row.push(`${width}:${m.hosts}h ${m.psw}/${m.pcw}px${m.torn.length ? " !" + m.torn.length : ""}${m.boxes.length ? " box!" + m.boxes.length : ""}${width === FAIL_WIDTHS[0] ? ` h=${m.h}` : ""}`);
        }
        // ── the cruel half, at the narrowest width only ──────────────────────
        //   Same text nodes, one unbreakable run, page asserted. This is what
        //   separates the replacement from the deletion: with min-content
        //   restored and no overflow-x anywhere on the rail or the console
        //   body, the deletion drives the page sideways here.
        await setViewport(FAIL_WIDTHS[0]);
        const s = await evalJs(
          `(function(){` +
          `var d=document.documentElement;var hit=0;` +
          `var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);var n,ns=[];` +
          `while((n=w.nextNode())){if((n.nodeValue||'').indexOf(${JSON.stringify(HOSTNAME)})>=0) ns.push(n);}` +
          `ns.forEach(function(x){x.nodeValue=(x.nodeValue||'').split(${JSON.stringify(HOSTNAME)}).join(${JSON.stringify(CRUEL)});hit++;});` +
          `void d.offsetWidth;` +
          `var out={hit:hit,psw:d.scrollWidth,pcw:d.clientWidth,spill:[],wide:[]};` +
          `ns.forEach(function(x){var el=x.parentElement;if(!el) return;` +
          `  if(el.scrollWidth>el.clientWidth+1) out.spill.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),sw:el.scrollWidth,cw:el.clientWidth});});` +
          // NAME THE BOX. A page-level number alone sends the next reader back
          // into DevTools; the widest right edges are the elements that pushed
          // it, and one of them is always the remedy's real address.
          `if(d.scrollWidth>d.clientWidth){` +
          `  [].slice.call(document.querySelectorAll('.new-screen *')).forEach(function(el){` +
          `    var r=el.getBoundingClientRect();if(r.width>0&&r.right>d.clientWidth+1)` +
          `      out.wide.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),right:+r.right.toFixed(2),w:+r.width.toFixed(2)});});` +
          `  out.wide.sort(function(a,b){return b.right-a.right;});out.wide=out.wide.slice(0,4);` +
          `}` +
          `return out;})()`,
        );
        stressRuns++;
        if (s.hit === 0) {
          fail(D, `theater-failed/${theme}@${FAIL_WIDTHS[0]} STRESS: the cruel token replaced nothing — the stress half measured no element, so this leg's second question was not asked`);
        }
        // ASSERTED: every box that HOLDS the cruel host must contain it. This is
        // what separates the remedy from a deletion — on pre-remedy bytes
        // .new-fail-copy measured 569/212 and .new-failed-caption 557/214 here,
        // both now clean, and a deletion of the break declaration reds this the
        // same way. It is the falsifiable half of the stress.
        for (const sp of s.spill) {
          stressSpill++;
          fail(D, `theater-failed/${theme}@${FAIL_WIDTHS[0]} STRESS .${sp.cls}: scrollWidth ${sp.sw} > clientWidth ${sp.cw} — the cruel host overflows its own box, and neither the rail nor the console body scrolls sideways`);
        }
        // cch-w25-s2 — WAS REPORTED, IS NOW ASSERTED. W24 left this number
        // printed and uncertified with an argument that read as final: the
        // escape (`min-width: 0` on .new-theater-rail) takes the cruel page to
        // exactly 320/320 and puts THIS LEG'S OWN DEFECT BACK, .new-step-detail
        // returning to a 92.25px box with the hostname across two line boxes —
        // "the two goals share one lever, so asserting both is unsatisfiable by
        // any patch."
        //   THAT IS FALSE, AND THE REASON IS WORTH KEEPING. The 92.25px box is
        // not a min-content fact, it is a STEP-ROW BUDGET fact: .new-step
        // spends 84px of a 176px row on dot + gaps + a nowrap time column that
        // never shrinks. Escape the track AND reflow the time onto its own line
        // at <=720 and the body gets the full 176px — both halves in one tree.
        // Shipped as `minmax(0,1fr)` + `.new-step{flex-wrap:wrap}` +
        // `.new-step-time{margin-left:0;flex:1 0 100%;padding-left:34px}`.
        //   The number this line now certifies moved 732 -> 320/320 at 320 in
        // both themes. The widest-box list is still printed on failure, because
        // a page number alone sends the next reader back into DevTools.
        const widest = (s.wide || []).map((x) => `.${x.cls} right=${x.right}`).join(" | ") || "none inside .new-screen";
        if (s.psw > s.pcw) {
          pageOver++;
          fail(D, `theater-failed/${theme}@${FAIL_WIDTHS[0]} STRESS: a ${CRUEL.length}-char unbreakable host takes documentElement.scrollWidth to ${s.psw} against ${s.pcw} — ${s.psw - s.pcw}px of the failure screen drags sideways. Widest: ${widest}`);
        }
        row.push(`stress@${FAIL_WIDTHS[0]}:${s.hit}n box-spill:${s.spill.length} page:${s.psw}/${s.pcw}px`);
        process.stdout.write(`   theater-failed/${theme}  ${row.join("  ")}\n`);
      }
      // ── cch-w25-s2: theater-midflight, THE SCREEN EVERY SUCCESSFUL SIGNUP
      //    WATCHES ──────────────────────────────────────────────────────────
      //    It shares .new-theater-grid, .new-theater-rail and the .new-step
      //    rows with the failure screen, so EVERY lever in the <=720 block
      //    moves it — and before this row it appeared zero times in this file
      //    and sits in breakpoint-sweep's unswept scenario residue. A remedy
      //    aimed at the screen a few people reach, silently reshaping the one
      //    everybody reaches, is exactly the blind spot the wave's fifth
      //    standing clause names: a guard whose SELECTOR cannot reach the
      //    defect is green by construction.
      //    It carries no failure copy and no cruel token — nothing here is
      //    about a hostname. What is asserted is the SHARED GEOMETRY: the page
      //    does not drag, and no theater box is wider than its own client
      //    width. Same widths, both themes.
      {
        const mid = SCENARIOS["theater-midflight"];
        if (!mid || !mid.pathname || !mid.search) {
          return die(`${D}: SCENARIOS["theater-midflight"] no longer carries pathname+search — the mid-flight screen cannot be reached, so the shared-geometry half measured nothing`);
        }
        for (const theme of ["light", "dark"]) {
          await setViewport(FAIL_WIDTHS[FAIL_WIDTHS.length - 1]);
          await nav(
            `${BASE}${mid.pathname}${mid.search}&scen=theater-midflight&theme=${theme}`,
            `document.querySelector('.new-theater-grid') && document.querySelector('.new-step')`,
          );
          const row = [];
          for (const width of FAIL_WIDTHS) {
            await setViewport(width);
            const m = await evalJs(
              `(function(){` +
              `var d=document.documentElement;` +
              `var out={grid:!!document.querySelector('.new-theater-grid'),steps:document.querySelectorAll('.new-step').length,` +
              `theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,boxes:[],h:0};` +
              `[].slice.call(document.querySelectorAll('.new-theater-grid,.new-theater-rail,.new-step,.new-step-body')).forEach(function(el){` +
              `  if(el.scrollWidth>el.clientWidth+1) out.boxes.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),sw:el.scrollWidth,cw:el.clientWidth});});` +
              `var g=document.querySelector('.new-theater-grid');if(g) out.h=+g.getBoundingClientRect().height.toFixed(2);` +
              `return out;})()`,
            );
            midCells++;
            // AUDITED: a screen that stopped rendering the rail would print a
            // clean row about an empty page. Both the grid and at least one
            // step row must be present or nothing below counts.
            if (!m.grid || m.steps === 0) {
              fail(D, `theater-midflight/${theme}@${width}: .new-theater-grid present=${m.grid}, .new-step rows=${m.steps} — the mid-flight theater did not render, so nothing was measured`);
              row.push(`${width}:?`);
              continue;
            }
            if (m.theme !== theme) fail(D, `theater-midflight/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
            if (m.psw > m.pcw) {
              midPageOver++;
              fail(D, `theater-midflight/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the screen every successful signup watches is off-screen sideways`);
            }
            for (const b of m.boxes) {
              midBoxOver++;
              fail(D, `theater-midflight/${theme}@${width} .${b.cls}: scrollWidth ${b.sw} > clientWidth ${b.cw} — a box on the screen every successful signup watches is wider than its own client width (on origin/main bytes this cell caught .new-theater-grid 247/214 at 320 AND .new-step 212/209, the nowrap time column overrunning its row at all four widths)`);
            }
            row.push(`${width}:${m.steps}s ${m.psw}/${m.pcw}px${m.boxes.length ? " box!" + m.boxes.length : ""}${width === FAIL_WIDTHS[0] ? ` h=${m.h}` : ""}`);
          }
          process.stdout.write(`   theater-midflight/${theme}  ${row.join("  ")}\n`);
        }
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean (${hostsSeen} rendered "${HOSTNAME}" text runs measured — EVERY one on the ` +
          `screen, not a pinned selector) across ${FAIL_WIDTHS.join("/")} in both themes; ${torn} torn hostnames, ` +
          `${pageOver} pages scrolling sideways. Cells print hosts-found and, when torn, the count`,
        );
        okLine(
          `THE CRUEL HALF RAN ${stressRuns} time(s) at ${FAIL_WIDTHS[0]} with ${stressSpill} box spill(s): a ` +
          `${CRUEL.length}-char host (a 63-octet DNS label, the legal maximum) is substituted into the same text ` +
          `nodes and every box holding it is re-asserted. Deleting the break declaration outright passes the first ` +
          `half and FAILS this one (.new-fail-copy 569/212, .new-failed-caption 557/214) — which is why the remedy ` +
          `is overflow-wrap:break-word, min-content intact and still breakable at the box edge, and not a deletion. ` +
          `The PAGE under that same cruel host is now ASSERTED too (cch-w25-s2): it read 732/320 on W24 bytes and ` +
          `reads ${FAIL_WIDTHS[0]}/${FAIL_WIDTHS[0]} here`,
        );
        okLine(
          `${boxOver + midBoxOver} box overflow(s) with the ORDINARY hostname across theater-failed and ` +
          `theater-midflight (${midCells} mid-flight cells, ${midPageOver} pages dragging): .new-theater-grid, ` +
          `.new-theater-rail, .new-step and .new-step-body are asserted against their OWN client widths, which is ` +
          `the only instrument that can see either the 251/214 track the card's left offset used to hide or the ` +
          `silent 34px .new-step spill the margin-left form of the time reflow opens. theater-midflight — the ` +
          `screen every successful signup watches, and shares every rule this remedy touched — had zero coverage ` +
          `in this file before this row`,
        );
        okLine(
          `320/360 are the DRIVEN widths (the tear was measured at 320); 390/430 are SHOULDERS — already whole on ` +
          `origin/main, so they detect only a remedy that breaks the wider phone layout, never the tear itself`,
        );
      }
    }
    // ── W26-S1: THE INSTANCE WORKSPACE, WHICH DRAGGED 1673px AND NO LEG
    //    MEASURED ────────────────────────────────────────────────────────────
    //    THE PERSON: they open their instance workspace to see the sites running
    //    on it. One site's domain is a real 253-character hostname. The whole
    //    page slides sideways and the Sites card leaves the screen.
    //
    //    THE CAUSE: `.detail-grid--instance` shipped `grid-template-columns:
    //    1fr 340px`. A bare `1fr` is `minmax(auto, 1fr)` — it floors at the
    //    content's min-content width, so the main track measured 1948.94px and
    //    documentElement.scrollWidth read 2573 against a 900px viewport. The
    //    remedy is `minmax(0, 1fr)`, the same escape the base `.detail-grid`
    //    already carries; nothing below 900 moves, because the ≤899 block
    //    single-columns the grid there.
    //
    //    WHY THIS IS A PAGE ASSERTION AND NOT A CELL ONE, which is the whole
    //    reason three earlier filings of this defect measured the wrong thing:
    //    `overflow-wrap: break-word` already ships on `.site-name`, so the cell
    //    never spills — it GROWS and shoves the track. Driven on origin/main
    //    cfc2f2b77, ALL SEVEN `.site-name` cells read scrollWidth == clientWidth
    //    at every width in both themes (the 253-char row: 1555/1555) while the
    //    page was 1673px off-screen. A `sw > cw` leg on `.site-name` is GREEN BY
    //    CONSTRUCTION on the defective tree — the wave's fifth standing clause,
    //    live. This leg therefore asserts documentElement and REPORTS the cells.
    //
    //    THE TWO-EMITTER HAZARD, confirmed to the emitter and carried here
    //    because a ledger keying `.site-name` to one cap misclassifies the other:
    //    the COMPACT `siteRow` (the builder this screen uses) binds
    //    `domains[0]`, capped at 253 by a `validate_change` in
    //    registry/site.ex that a LENGTH CENSUS CANNOT SEE; `globalSiteRow` binds
    //    `s.name`, capped at 255 by a `validate_length` a census reads straight
    //    off. It is the census-invisible emitter that carries the live defect.
    //
    //    1280 APPEARS IN NO INSTRUMENT IN THIS REPO TODAY — this leg is the
    //    first to drive it, and it is not decoration: the defect persists above
    //    every band any other leg sweeps (2577/1280), so a sweep that stops at
    //    1024 certifies a desktop that is still dragging.
    //
    //    THE FIXTURE EXISTED AND NOTHING MEASURED IT: `sites-on-instance` drives
    //    the same rows — including the 253-char cruel domain — through the
    //    compact builder at the instance route, and is an explicit
    //    SCENARIO_RESIDUE entry in breakpoint-sweep.mjs. Only the instrument was
    //    missing.
    //
    //    METHOD, both halves paid for by a lost verifier run each: (1) the lever
    //    is NEVER injected as a <style> block — source order outranks the ≤899
    //    rule and manufactures a catastrophic false negative (two columns forced
    //    at 320, `.site-name` clientWidth 0). It is edited in app.css in place.
    //    (2) The scenario's deepLink is NOT applied by the harness (GR125d), so
    //    the hash is appended here — DERIVED from the scenario, never
    //    transcribed, because a rotted uuid renders the overview screen and
    //    prints a plausible table about the wrong page.
    if (requested.includes("W26-instance-track-min-content")) {
      const D = "W26-instance-track-min-content";
      // BLOCK-SCOPED (precedent: `const D`, FAIL_WIDTHS above). 900/1000/1280
      // are the DRIVEN widths — every one measured broken on origin/main.
      // 320/390/720 are NEGATIVE CONTROLS: the ≤899 block already owns them and
      // they were byte-identical across the fix, so they detect only a remedy
      // that re-shreds the phone layout.
      const TRACK_WIDTHS = [320, 390, 720, 900, 1000, 1280];
      const { SCENARIOS } = await import("./scenarios.mjs");
      const sc = SCENARIOS["sites-on-instance"];
      if (!sc || !sc.deepLink || !sc.deepLink.startsWith("#instance/")) {
        return die(`${D}: SCENARIOS["sites-on-instance"] no longer carries an #instance/ deepLink — the instance workspace cannot be reached, so nothing was measured`);
      }
      process.stdout.write(
        `\n${D} — sites-on-instance at the instance route x ${TRACK_WIDTHS.length} widths x 2 themes ` +
        `(${TRACK_WIDTHS.length * 2} cells; documentElement asserted, .detail-main and every .site-name cell ` +
        `REPORTED — the cells read sw==cw even 1673px off-screen, which is why they cannot be the assertion)\n`,
      );
      let cells = 0, pageOver = 0, misrouted = 0, namesSeen = 0, cellSpill = 0;
      for (const theme of ["light", "dark"]) {
        // Enter at 900 — the narrowest DRIVEN width, above the single-column
        // collapse — so a screen that renders at only one width cannot pass as
        // a screen that renders everywhere.
        await setViewport(900);
        await nav(
          `${BASE}/?scen=sites-on-instance&theme=${theme}${sc.deepLink}`,
          `document.querySelector('.site-name') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-instance';})()`,
        );
        const row = [];
        for (const width of TRACK_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){` +
            `var d=document.documentElement;` +
            `var v=document.querySelector('section.view:not([hidden])');` +
            `var dm=document.querySelector('.detail-main');` +
            `var g=document.querySelector('.detail-grid--instance');` +
            `var names=[].slice.call(document.querySelectorAll('.site-name')).map(function(el){` +
            `  return {sw:el.scrollWidth,cw:el.clientWidth,len:(el.textContent||'').length};});` +
            // NAME THE BOX when the page drags. A page number alone sends the
            // next reader back into DevTools; the widest right edges are the
            // elements that pushed it, and one of them is the remedy's address.
            `var wide=[];if(d.scrollWidth>d.clientWidth){` +
            `  [].slice.call(document.querySelectorAll('#view-instance *')).forEach(function(el){` +
            `    var r=el.getBoundingClientRect();if(r.width>0&&r.right>d.clientWidth+1)` +
            `      wide.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),right:+r.right.toFixed(2)});});` +
            `  wide.sort(function(a,b){return b.right-a.right;});wide=wide.slice(0,3);}` +
            `return {psw:d.scrollWidth,pcw:d.clientWidth,view:v?v.id:'none',theme:d.getAttribute('data-theme'),` +
            ` dm:dm?+dm.getBoundingClientRect().width.toFixed(2):null,gtc:g?getComputedStyle(g).gridTemplateColumns:null,` +
            ` names:names,wide:wide};})()`,
          );
          cells++;
          // (1) THE ROUTE. Without this the whole table is about #overview.
          if (m.view !== "view-instance") {
            misrouted++;
            fail(D, `sites-on-instance/${theme}@${width}: rendered section.view "${m.view}", asked for "view-instance" — the hash did not route, so nothing below this line measures the instance workspace`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `sites-on-instance/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          // AUDITED: zero .site-name cells is not a clean Sites card. If the
          // fixture stopped rendering rows, this leg would print a perfect
          // table about an empty card — the cruel string is the whole point.
          if (m.names.length === 0) {
            fail(D, `sites-on-instance/${theme}@${width}: zero .site-name cells rendered — the Sites card is empty, so the cruel 253-char domain never reached the page and nothing was measured`);
            row.push(`${width}:0n`);
            continue;
          }
          namesSeen += m.names.length;
          // (2) THE PIXELS — documentElement, the ONLY question that can fail
          // on the defective tree.
          if (m.psw > m.pcw) {
            pageOver++;
            const widest = (m.wide || []).map((x) => `.${x.cls} right=${x.right}`).join(" | ") || "none inside #view-instance";
            fail(D, `sites-on-instance/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the instance workspace is off-screen sideways at rest, with the Sites card in it (grid-template-columns computed "${m.gtc}", .detail-main ${m.dm}px). Widest: ${widest}`);
          }
          // (3) THE CELLS — counted and REPORTED, never the pass condition.
          // Printed so the "green by construction" claim stays quotable from a
          // green run instead of resting on this comment.
          cellSpill += m.names.filter((n) => n.sw > n.cw).length;
          const longest = m.names.reduce((a, b) => (b.len > a.len ? b : a), m.names[0]);
          row.push(`${width}:${m.psw}/${m.pcw}px dm=${m.dm} ${m.names.length}n max${longest.len}ch:${longest.sw}/${longest.cw}`);
        }
        process.stdout.write(`   sites-on-instance/${theme}  ${row.join("  ")}\n`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean across ${TRACK_WIDTHS.join("/")} in both themes (${namesSeen} .site-name ` +
          `cells rendered, one carrying the 253-char cruel domain): documentElement.scrollWidth <= clientWidth ` +
          `everywhere. On origin/main cfc2f2b77 this same drive read 2573/900, 2573/1000 and 2577/1280 in BOTH ` +
          `themes — 1673px of the instance workspace dragged sideways`,
        );
        okLine(
          `${cellSpill} .site-name cell(s) with scrollWidth > clientWidth — and that number was ALSO 0 on the ` +
          `defective tree (every cell read sw==cw, the cruel row 1555/1555, while the page was 1673px off-screen). ` +
          `That is why this leg asserts the PAGE and only reports the cells: a cell-level assertion here is green ` +
          `by construction, which is how this defect survived three filings`,
        );
        okLine(
          `900/1000/1280 are the DRIVEN widths (all three measured broken); 320/390/720 are NEGATIVE CONTROLS — ` +
          `the ≤899 block single-columns the grid there and every number was byte-identical across the fix, so ` +
          `they detect only a remedy that re-shreds the phone layout. 1280 is driven by NO other instrument in ` +
          `this repo: the defect outlived every band swept above, and a sweep stopping at 1024 certifies a ` +
          `desktop that is still dragging`,
        );
      }
    }


    // ── cch-w26-s2 (charter D309): THE DEPLOY ROW'S FAILURE PANEL — the
    //    UNFIXED TWIN of the footer the leg above measures, and a regression
    //    #9255 introduced. ────────────────────────────────────────────────────
    //
    //    THE PERSON: their deploy failed. They open site detail — the one
    //    screen that says why — and the red panel silently swallows up to
    //    142px of the reason. No scrollbar, no page scroll, no selection, no
    //    copy: the tail is simply not painted, and hit-testing where it should
    //    be returns the sidebar. On a 1024px laptop it is 18px, which is worse,
    //    because nothing signals that a sentence ended early.
    //
    //    THE MECHANISM, to the line:
    //      `.deploys` (app.css) carries `overflow: hidden`.
    //      `.deploy-fail` declares display/gap/margin/padding/border/background/
    //        color/font-size/line-height and NOTHING about wrapping — computed
    //        `overflow-wrap: normal` — and its text span is a flex item at the
    //        default `min-width: auto`.
    //      #9255 hoisted `minmax(0, 1fr)` onto `.detail-grid`, so the main
    //        track can now shrink BELOW min-content. Before that hoist the same
    //        string pushed the PAGE sideways — ugly, but visible and scrollable
    //        (mutation-driven: reverting the track reads page 1118/900 with
    //        lostPx 0). After it, `.deploys{overflow:hidden}` eats the excess
    //        in silence. The remedy is not the track — the track fixed a real
    //        defect — it is the wrap the panel never had.
    //
    //    WHY THIS LEG CANNOT REST ON `documentElement`, and this is the whole
    //    reason it exists: W13-detail-route-band drives THIS SCENARIO, at
    //    900 and 1024, in both themes, and ran 108/108 CLEAN on the defective
    //    tree. A clip is the exact defect a page-level instrument cannot see —
    //    the page is clean BECAUSE the content was thrown away. The page number
    //    is printed here per cell (it is the proof of that sentence) and is
    //    asserted nowhere.
    //
    //    NOR ON A RECT. A block child's border box is already clipped to its
    //    parent's width while its ink spills, so `box.right <= clipper.right`
    //    is GREEN BY CONSTRUCTION for text overflow — driven as this leg's
    //    negative control (see the mutation note in the task ledger). The two
    //    signals that CAN lose:
    //      (a) THE CLIPPER: `overflow-x != visible` AND `scrollWidth >
    //          clientWidth` on the ancestor that does the clipping — found by
    //          walking up from the panel, never by a pinned selector, so a
    //          remedy that moves the clip somewhere else is still caught.
    //      (b) THE GLYPHS: the maximum right edge of every painted text rect
    //          inside the panel (Range.getClientRects, not the element rect)
    //          against the clipper's CONTENT edge. This is the number a person
    //          loses, in pixels, and it is what `lostPx` reports.
    //
    //    THE FIXTURE IS A PRECONDITION, NOT AN EXTRA. Every `failure_reason`
    //    committed before this slice reduced to two strings, longest 122 chars
    //    with a 9-char longest run — none of them can reach the card edge at
    //    any width. `DEPLOY_FAIL_CRUEL_REASON` (scenarios.mjs) is composed from
    //    the producer chain that actually emits this column —
    //    `build_failure_reason` → `emit()`'s cut → `stage_failure_copy/1` —
    //    and its cruelty is ASSERTED here per cell, so a fixture that drifted
    //    kind reds instead of printing a green table about nothing.
    //
    //    THE KIND CONTROL rides the same route: the 122-char humanized
    //    github-push copy, word-broken throughout, measured in every cell. A
    //    remedy that bought the cruel string by shredding ordinary prose reds
    //    on its width.
    //
    //    HEIGHT IS PRINTED, NEVER PINNED. Wrapping a 255-char error is what
    //    makes it readable and its honest cost is a taller panel; a pixel pin
    //    on a wrapped string is a claim about THAT string at THAT width, and
    //    this epic has already deleted one of those.
    if (requested.includes("W26-deploy-fail-clip")) {
      const D = "W26-deploy-fail-clip";
      // BLOCK-SCOPED (D247). The DRIVEN widths are the ones that MEASURABLY
      // lose pixels on the defective tree: 320 (186.39px) and 390 (116.39px)
      // on the phone, then the desktop band 900 / 1000 / 1024 / 1042
      // (142.39 / 42.39 / 18.39 / 0.39). 1043 straddles the desktop bisection
      // (-0.61) and 1440 is the clean upper shoulder; 720 and 769 are clean by
      // MEASUREMENT, not assumption — below the 768 collapse the main column
      // gets the full width (-173.72 / -14.61). The shoulders cannot detect
      // the clip; they exist to catch a remedy that breaks a width the defect
      // never touched.
      const CLIP_WIDTHS = [320, 390, 720, 769, 900, 1000, 1024, 1042, 1043, 1440];
      const DRIVEN = [320, 390, 900, 1000, 1024, 1042];
      // `failureCopy()` (app.js) re-maps the humanized github-push reason onto
      // its OWN copy, which spells the apostrophe ASCII while the server's
      // fixture carries U+2019 — an idempotent raw→human/human→human mapping,
      // deliberate and pinned by __app.test.mjs. Comparing bytes without this
      // makes the KIND control unfindable on the page and turns the control
      // half of this leg into a permanent red about nothing.
      const norm = (s) => String(s).replace(/’/g, "'");
      const { SCENARIOS, DEPLOY_FAIL_CRUEL_REASON } = await import("./scenarios.mjs");
      const sc = SCENARIOS["site-states"];
      // The route is DERIVED from the fixture, never transcribed: a pasted uuid
      // rots silently into "the sites list rendered instead".
      if (!sc || !sc.deepLink || !sc.data || !Array.isArray(sc.data.deployments)) {
        return die(`${D}: SCENARIOS["site-states"] no longer carries a deepLink and a deployments list — the failed deploy rows cannot be reached, so nothing was measured`);
      }
      // The control is READ OUT OF THE FIXTURE, not typed here: the ordinary
      // humanized github-push copy, whatever it currently says. If the fixture
      // stopped carrying a second, kind failure this leg refuses rather than
      // measuring the cruel row twice and calling one of them a control.
      const KIND = (sc.data.deployments.find(
        (d) => d.status === "failed" && d.failure_reason && d.failure_reason !== DEPLOY_FAIL_CRUEL_REASON &&
          d.failure_reason.length > 60,
      ) || {}).failure_reason;
      if (!KIND) {
        return die(`${D}: SCENARIOS["site-states"] carries no ORDINARY failed row beside the cruel one — the control half of this leg would have measured nothing`);
      }
      process.stdout.write(
        `\n${D} — site-states x ${CLIP_WIDTHS.length} widths x 2 themes (${CLIP_WIDTHS.length * 2} cells; every ` +
        `.deploy-fail on the page against the CLIPPER it actually sits in, glyph rects and clipper scrollWidth, ` +
        `never documentElement — W13 drives this same route at 900/1024 and ran 108/108 clean on the defective ` +
        `tree). Cruel reason ${DEPLOY_FAIL_CRUEL_REASON.length} chars, KIND control ${KIND.length}. h= is the ` +
        `panel height, REPORTED — the wrap costs vertical room and no pixel is pinned\n`,
      );
      let cells = 0, panels = 0, cruelSeen = 0, kindSeen = 0, clipped = 0, spilled = 0, pageOver = 0;
      // cch-w28-bl (b): the truncation this leg no longer keys on was 40 chars.
      // Print the widest clipper class actually seen so a reader can tell how
      // far the old key was from colliding, instead of taking it on trust.
      let widestClass = 0, clipperIds = 0;
      for (const theme of ["light", "dark"]) {
        // Enter at the WIDEST width — the deploy list mounts once, from the
        // deployments fetch; entering narrow would measure a layout the mount
        // never saw.
        await setViewport(CLIP_WIDTHS[CLIP_WIDTHS.length - 1]);
        await nav(
          `${BASE}/?scen=site-states&theme=${theme}${sc.deepLink}`,
          `document.querySelector('.deploy-fail') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-site';})()`,
        );
        const row = [];
        for (const width of CLIP_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){var d=document.documentElement;` +
            `var v=document.querySelector('section.view:not([hidden])');` +
            // THE CLIPPER IS FOUND, NOT NAMED. Walk up from the panel to the
            // first ancestor whose overflow-x is not visible: that is the
            // element doing the swallowing, whatever it is called today.
            `function clipperOf(el){var p=el.parentElement;while(p&&p!==document.documentElement){` +
            `  var cs=getComputedStyle(p);if(cs.overflowX!=='visible')return p;p=p.parentElement;}return null;}` +
            // THE GLYPHS, not the box: Range.getClientRects over every text
            // node in the panel. An element rect is already clipped to its
            // parent — this is the only measurement that can see painted ink
            // outside the card.
            `function glyphRight(el){var max=null;var w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,null),n;` +
            `  while((n=w.nextNode())){if(!(n.nodeValue||'').trim())continue;var r=document.createRange();r.selectNodeContents(n);` +
            `    var rs=r.getClientRects();for(var i=0;i<rs.length;i++){if(rs[i].width>0&&(max===null||rs[i].right>max))max=rs[i].right;}}` +
            `  return max;}` +
            `var out={sw:d.scrollWidth,cw:d.clientWidth,view:v?v.id:'none',theme:d.getAttribute('data-theme'),boxes:[]};` +
            `var clippers=[];` +
            // EVERY panel on the page, never a pinned one (D228): querySelector
            // singular cannot tell a list that rendered nothing from a list of
            // clean panels.
            `[].slice.call(document.querySelectorAll('.deploy-fail')).forEach(function(f){` +
            `  var cs=getComputedStyle(f);var t=(f.textContent||'');` +
            `  var runs=t.split(/\\s+/).map(function(w){return w.length;});` +
            `  var rec={t:t,len:t.length,run:runs.length?Math.max.apply(null,runs):0,ow:cs.overflowWrap,wb:cs.wordBreak,` +
            `    h:+f.getBoundingClientRect().height.toFixed(2),bsw:f.scrollWidth,bcw:f.clientWidth,` +
            `    gr:null,cl:null,clsw:0,clcw:0,clov:'',edge:null,lost:null,rect:+f.getBoundingClientRect().right.toFixed(2)};` +
            `  var g=glyphRight(f);if(g!==null)rec.gr=+g.toFixed(2);` +
            `  var cl=clipperOf(f);` +
            // cch-w28-bl (b): THE DEDUPE KEY IS THE ELEMENT, NOT ITS CLASS
            // STRING. `.slice(0,40)` made the key a 40-char PREFIX, so two
            // different clipping ancestors agreeing in their first 40 chars
            // collapsed into one Set entry and the second real clipper was
            // SILENCED. `clippers.indexOf(cl)` is element identity and cannot
            // collide however the class lists are spelled. MEASURED HONESTLY:
            // on today's fixtures the clipper classes are 7 and 16 chars, so
            // the truncation has never yet collided — this closes a LATENT
            // hazard, and the leg now prints the widest class string it saw so
            // a reader can tell when that stops being true.
            `  if(cl){var r=cl.getBoundingClientRect();var ci=clippers.indexOf(cl);if(ci<0){ci=clippers.push(cl)-1;}rec.ci=ci;` +
            `    rec.cl=(cl.className||cl.tagName||'?').toString();` +
            `    rec.clsw=cl.scrollWidth;rec.clcw=cl.clientWidth;rec.clov=getComputedStyle(cl).overflowX;` +
            `    rec.edge=+(r.left+cl.clientLeft+cl.clientWidth).toFixed(2);` +
            `    if(rec.gr!==null)rec.lost=+(rec.gr-rec.edge).toFixed(2);}` +
            `  out.boxes.push(rec);});` +
            `return out;})()`,
          );
          cells++;
          // (1) THE ROUTE. Without this the whole table is phantom.
          if (m.view !== "view-site") {
            fail(D, `site-states/${theme}@${width}: rendered section.view "${m.view}", asked for "view-site" — the hash did not route, so nothing below this line measures a deploy row`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `site-states/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          // (2) AUDITED: an absent panel is not a clean panel.
          if (m.boxes.length === 0) {
            fail(D, `site-states/${theme}@${width}: zero .deploy-fail panels rendered — the failure copy is not on the page, so nothing was measured. This is not a pass.`);
            row.push(`${width}:0box`);
            continue;
          }
          let cruelHere = 0, kindHere = 0, worst = null;
          // ONE VOICE PER CLIPPER. Three panels share the `.deploys` card, so
          // an unguarded loop shouts the same clipped card three times and buries
          // WHICH panel filled it. The clipper is asserted once, named by the
          // widest panel inside it.
          for (const b of m.boxes) {
            if (b.cl) widestClass = Math.max(widestClass, String(b.cl).length);
            if (typeof b.ci === "number") clipperIds = Math.max(clipperIds, b.ci + 1);
          }
          const clippersSaid = new Set();
          for (const b of m.boxes) {
            panels++;
            const isCruel = norm(b.t) === norm(DEPLOY_FAIL_CRUEL_REASON);
            const isKind = norm(b.t) === norm(KIND);
            if (isCruel) { cruelSeen++; cruelHere++; }
            if (isKind) { kindSeen++; kindHere++; }
            // (3) ANTI-VACUITY, SECOND ORDER: a cruel cell whose string is not
            // cruel proves nothing, and a control that drifted cruel stops
            // being a control. Asserted against the FIXTURE's own strings —
            // this leg pins no length of its own, so the shell's cut can move
            // without touching this file.
            if (isCruel && b.run < 40) {
              fail(D, `site-states/${theme}@${width} .deploy-fail: the cruel row's longest unbreakable run is ${b.run} chars — the fixture went KIND, so a green here would be green by construction`);
            }
            if (isKind && b.run > 20) {
              fail(D, `site-states/${theme}@${width} .deploy-fail: the control's longest run is ${b.run} chars — it has drifted cruel and can no longer answer "did the remedy shred ordinary prose"`);
            }
            // (4) THE CLIPPER. Every panel must sit in a clipper, or the walk
            // found nothing and (a) measured nothing.
            if (!b.cl) {
              fail(D, `site-states/${theme}@${width} .deploy-fail (${b.len} chars): no clipping ancestor found — the walk that finds the element doing the swallowing returned nothing, so the clipper assertion measured nothing`);
              continue;
            }
            if (b.clov !== "visible" && b.clsw > b.clcw && !clippersSaid.has(b.ci)) {
              clippersSaid.add(b.ci);
              clipped++;
              // cch-w28-bl-overflow-guard-clipper-blames-the-wrong-panel (a)
              // and (c): THE PREDICATE WAS ABOUT THE CLIPPER AND THE SENTENCE
              // WAS ABOUT THE PANEL. `b.clsw > b.clcw` is the ANCESTOR card's
              // own overflow. `clipperOf` walks up to the first ancestor whose
              // overflow-x is not visible — measured to be the .deploys card,
              // which also holds .deploy-ref, .preview-url and the timestamps.
              // ANY of those overflowing fired this assertion, and the message
              // blamed the deploy FAILURE REASON.
              //
              // RE-DERIVED IN A BROWSER, never from the source. Delete
              // `.deploy-ref { overflow-wrap: anywhere }` from app.css — a
              // SIBLING regression, and a realistic one, since that declaration
              // is W27-deploy-ref-branch-bounded's own shipped remedy — and
              // this assertion fired 16 times across the 20 cells saying
              // "388px of a failed deploy's reason is inside a box that clips
              // it" while EVERY .deploy-fail under that clipper stopped
              // 106-506px SHORT of the clip edge. Not one pixel of a failure
              // reason was lost in any of the 16.
              //
              // SO ATTRIBUTION IS ASSERTED, NOT ASSUMED — and the assertion is
              // NOT deleted. It is this leg's only signal for content thrown
              // away without a page-scrollWidth change, so it splits instead:
              // some panel under this clipper lost glyphs (ATTRIBUTED, name it
              // by pixels lost), or none did (UN-ATTRIBUTED, and say whose
              // overflow it is not).
              //
              // (c) IS PARTLY REFUTED, AND THE RESIDUE IS THE LABEL. The row
              // said the sort degrades to `boxes[0]` because every `lost` is
              // null. Measured: `lost` is a SIGNED distance, non-null whenever
              // the panel paints any text at all, so the sort was never a
              // no-op — it ranked by proximity to the clip edge and then
              // announced its winner as "widest panel inside it", a different
              // wrong label. Under the sibling mutation it named a 22-char
              // panel whose glyphs stop 106.06px short of the edge as the
              // filler of a 388px overflow. The winner is now selected and
              // DESCRIBED by the same quantity, among spillers only.
              const under = m.boxes.filter((x) => x.ci === b.ci);
              const spillers = under.filter((x) => x.lost !== null && x.lost > 0.5);
              if (spillers.length) {
                const filler = spillers.slice().sort((x, y) => y.lost - x.lost)[0];
                fail(D, `site-states/${theme}@${width} .${b.cl}: overflow-x:${b.clov} AND scrollWidth ${b.clsw} > clientWidth ${b.clcw} — ${b.clsw - b.clcw}px of a failed deploy's reason is inside a box that clips it, with no scrollbar and no page scroll (${spillers.length} of ${under.length} panel(s) under it lose glyphs; the worst loses ${filler.lost}px past the clip edge — ${filler.len} chars, longest run ${filler.run}, overflow-wrap:${filler.ow}, word-break:${filler.wb})`);
              } else {
                const closest = under.reduce((a, x) => (x.lost !== null && (a === null || x.lost > a) ? x.lost : a), null);
                fail(D, `site-states/${theme}@${width} .${b.cl}: overflow-x:${b.clov} AND scrollWidth ${b.clsw} > clientWidth ${b.clcw} — ${b.clsw - b.clcw}px of this card is swallowed with no scrollbar and no page scroll, and it is UN-ATTRIBUTED: not one of the ${under.length} .deploy-fail panel(s) under it loses a glyph (the closest stops ${closest === null ? "?" : Math.abs(closest)}px short of the clip edge). The overflow is real and belongs to a SIBLING in the same card — .deploy-ref, .preview-url or the timestamps — which this leg does not own. Do NOT read this line as a failure reason being cut; W27-deploy-ref-branch-bounded owns the ref line`);
              }
            }
            // (5) THE PANEL'S OWN BORDER. Third signal, and the cheapest: the
            // text span is a flex item at the default `min-width: auto`, so an
            // unwrapped run overruns the panel itself before it reaches the
            // card. It is NOT a spare for the clipper assertion — it goes
            // green the moment a remedy moves the clip up a level — and NOT a
            // spare for the glyphs, which are the only pixels a person loses.
            if (b.bsw > b.bcw) {
              spilled++;
              fail(D, `site-states/${theme}@${width} .deploy-fail (${b.len} chars): scrollWidth ${b.bsw} > clientWidth ${b.bcw} — ${b.bsw - b.bcw}px of the reason paints outside the panel's own red border (overflow-wrap:${b.ow}, word-break:${b.wb})`);
            }
            // (6) THE GLYPHS. The pixels a person actually loses. Half a pixel
            // of tolerance: sub-pixel text metrics are not a defect.
            if (b.gr === null) {
              fail(D, `site-states/${theme}@${width} .deploy-fail: the panel painted no text rects at all — the reason is not on screen, so the glyph half measured nothing`);
              continue;
            }
            if (b.lost !== null && b.lost > 0.5) {
              spilled++;
              if (worst === null || b.lost > worst) worst = b.lost;
              fail(D, `site-states/${theme}@${width} .deploy-fail (${b.len} chars): glyphs reach x=${b.gr} while .${b.cl}'s content edge sits at ${b.edge} — ${b.lost}px of WHY THE DEPLOY FAILED is painted outside the card and clipped away silently. The panel's own border box reads ${b.rect} (inside the edge), which is why a rect-based test is green here`);
            }
          }
          // (7) BOTH FAMILIES MUST BE ON SCREEN IN EVERY CELL. A cell that lost
          // the cruel row would print a clean number about the control alone.
          if (cruelHere === 0) {
            fail(D, `site-states/${theme}@${width}: the cruel ${DEPLOY_FAIL_CRUEL_REASON.length}-char reason is not among the ${m.boxes.length} panel(s) on the page — the defect's own fixture is missing, so this cell asserted nothing about it`);
          }
          if (kindHere === 0) {
            fail(D, `site-states/${theme}@${width}: the ${KIND.length}-char KIND control is not on the page — a remedy that shreds ordinary prose would pass this cell unmeasured`);
          }
          // THE PAGE IS PRINTED, NEVER ASSERTED (see the header): on the
          // defective tree it reads clean at every one of these widths, which
          // is the whole reason this leg measures cells.
          if (m.sw > m.cw) pageOver++;
          const cruel = m.boxes.find((b) => norm(b.t) === norm(DEPLOY_FAIL_CRUEL_REASON)) || m.boxes[0];
          const kind = m.boxes.find((b) => norm(b.t) === norm(KIND));
          row.push(
            `${width}:page ${m.sw}/${m.cw} cruel lost${cruel.lost === null ? "?" : cruel.lost} sw/cw ${cruel.bsw}/${cruel.bcw} h${cruel.h}` +
            (kind ? ` kind lost${kind.lost === null ? "?" : kind.lost} h${kind.h}` : " kind:absent") +
            (worst !== null ? ` WORST ${worst}px` : ""),
          );
        }
        process.stdout.write(`   site-states/${theme}  ${row.join("  ")}\n`);
      }
      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean across ${CLIP_WIDTHS.join("/")} in both themes (${panels} .deploy-fail ` +
          `panel(s) measured — EVERY one on the page, not a pinned selector; ${cruelSeen} carried the cruel ` +
          `${DEPLOY_FAIL_CRUEL_REASON.length}-char stage report, ${kindSeen} the ${KIND.length}-char KIND control), ` +
          `${clipped} clipper(s) holding more than they show, ${spilled} panel(s) painting glyphs past their card`,
        );
        okLine(
          `ATTRIBUTION: every clipper finding above is keyed on the clipping ELEMENT (${clipperIds} distinct one(s) ` +
          `seen in a cell), never on a truncated class string — the widest clipper class measured was ${widestClass} ` +
          `chars against the 40-char prefix this leg used to dedupe on, so the old key was ${40 - widestClass} chars ` +
          `from silencing a second real clipper. A clipper that overflows while no .deploy-fail under it loses a ` +
          `glyph is reported as UN-ATTRIBUTED and names the siblings it could have come from instead`,
        );
        okLine(
          `${DRIVEN.join("/")} are the DRIVEN widths — every one of them LOST PIXELS on the defective tree: 186.39 ` +
          `@320, 116.39 @390, then 142.39 / 42.39 / 18.39 / 0.39 at 900 / 1000 / 1024 / 1042, glyphs at x=489.39 ` +
          `(phone) and x=729.39 (desktop) against .deploys content edges of 303 / 373 / 587 / 687 / 711 / 729. ` +
          `The desktop band bisects between 1042 (lost 0.39 — sub-pixel, the crossing itself) and 1043 (-0.61), ` +
          `both carried here. 720/769 are SHOULDERS by MEASUREMENT, not assumption — the <=768 single-column ` +
          `collapse hands the main column the full width and the same string reads -173.72 / -14.61 there — and ` +
          `1043/1440 are the clean upper shoulders. Shoulders cannot detect the clip; they catch a remedy that ` +
          `breaks a width the defect never touched`,
        );
        okLine(
          `NEITHER SIGNAL IS A SPARE, and NEITHER IS documentElement: the page reads CLEAN at all ten widths on the ` +
          `defective tree (W13-detail-route-band drives this same route at 900/1024 and ran 108/108 green on it), ` +
          `because a clip is content thrown away rather than a page pushed sideways. The clipper assertion catches ` +
          `a remedy that hides the spill somewhere else; the glyph assertion is the only one that can refuse a ` +
          `rect-based sentinel, which measures the panel's own border box — already clipped to the card, and green ` +
          `by construction on the defective bytes. Heights are printed per cell and deliberately unpinned`,
        );
      }
    }



    // ── W26-S4: EVERY EXIT FROM THE CREDENTIAL SHEET, NOT JUST THE ONE THAT
    //    WORKED ────────────────────────────────────────────────────────────
    //    W25's leg above measures the ONE exit that already behaved — the 201.
    //    A driven five-exit census on origin/main bytes found the other four
    //    all leaving the person with no wizard and their typed instance name
    //    orphaned in localStorage:
    //
    //      cred-back   modalHidden=false launchWizardBack=false orphanStash="Exit Probe"
    //      escape      modalHidden=true  launchWizardBack=false orphanStash="Exit Probe"
    //      modal-x     modalHidden=true  launchWizardBack=false orphanStash="Exit Probe"
    //      backdrop    modalHidden=true  launchWizardBack=false orphanStash="Exit Probe"
    //      submit-201  modalHidden=false launchWizardBack=true  orphanStash=null
    //
    //    `#cred-back` is the worst of the four because it is the only exit that
    //    PROMISES A DESTINATION: it read "< Back to providers" and delivered a
    //    provider picker the person never opened, inside a modal, with the
    //    wizard and the name gone. The stash the other three leave behind is
    //    two further bodies, both driven: a GHOST launch modal popping over
    //    `#providers` when the person later connects through that page's own
    //    card, and an unrelated `?checkout=success` return auto-opening a launch
    //    modal prefilled with a name abandoned long ago.
    //
    //    THREE GREEN-BY-CONSTRUCTION TRAPS, EACH MEASURED, EACH AVOIDED HERE:
    //    (1) AN UNSCOPED `.launch-connect-provider` ON `scen=empty` BINDS THE
    //        RUNWAY BUTTON AND PASSES ON PRE-FIX BYTES. Driven: on `scen=empty`
    //        `document.querySelectorAll('.launch-connect-provider')` returns 1
    //        and ZERO of them are inside `#launch-modal-slot` — the first match
    //        lives in `#view-overview`, because the empty-fleet runway renders
    //        the wizard INLINE in the overview body. Pressing THAT door writes
    //        no stash at all (`noteLaunchConnectDetour` stashes only
    //        `if (opts && opts.modal)`; measured `bp_launch_return = null`), and
    //        the inline wizard survives the sheet — so a leg that asserted
    //        "the wizard is back with the name" would have been GREEN on the
    //        DEFECTIVE tree without ever entering the modal path. Hence:
    //        `scen=mixed-fleet` (non-empty), and EVERY query below is scoped to
    //        `#launch-modal-slot`, plus an explicit per-cell assertion that the
    //        runway wizard is NOT present behind the modal.
    //    (2) `scen=providers-empty` carries `providerConnect: {status: 422}`, so
    //        its connect can never 201. `mixed-fleet` names no `providerConnect`
    //        override and defaults to 201 — this leg needs the 201 only for the
    //        control cell, but the trap is recorded so a future widening does
    //        not pick the 422 fixture and print a table about nothing.
    //    (3) `#modal-root` carries NO `data-close` (measured:
    //        `#modal-root[data-close]=false`), so a backdrop cell that clicks it
    //        reports a false "does not close". The real backdrop is
    //        `.modal-backdrop`, which does carry it, and that is what the reflex
    //        half below clicks.
    if (requested.includes("W26-cred-sheet-exits")) {
      const D = "W26-cred-sheet-exits";
      // BLOCK-SCOPED (D247). Phone + desktop for the same reason W25's leg
      // carries both: the modal wizard is reached through the topbar scope menu
      // on a laptop, and the same sheet is what a phone gets.
      const EXIT_VIEWPORTS = [[390, 844], [1000, 800]];
      // NON-EMPTY FLEET — trap (1). `mixed-fleet` renders no runway wizard, so
      // the ONLY `.launch-connect-provider` on the page is the modal one.
      const EXIT_SCEN = "mixed-fleet";
      // The empty-fleet control this leg does NOT drive its assertions on: the
      // runway path, where the correct answer is the OPPOSITE one (close and
      // nothing else). Driven as its own cell at the end.
      const RUNWAY_SCEN = "empty";
      const STASH = "bp_launch_return";

      process.stdout.write(
        `\n${D} — ${EXIT_VIEWPORTS.length} viewports x 5 cells (modal Back / modal Escape / modal × / modal backdrop / runway Back)` +
        ` (type a name -> the catalog's Connect door -> leave the sheet WITHOUT connecting -> is the person still` +
        ` mid-launch, and did the abandoned launch stop haunting the rest of the console)\n`,
      );

      const exitWait = async (expr) => {
        for (let w = 0; w < RENDER_CAP; w += 100) {
          let v = false;
          try { v = !!(await evalJs(`!!(${expr})`)); } catch { /* mid-render */ }
          if (v) return true;
          await sleep(100);
        }
        return false;
      };
      // A unique `cell` param per navigation: these cells differ only by hash,
      // and a fragment-only navigation is a SAME-document navigation that keeps
      // the previous cell's DOM (the trap the W24 leg measured).
      const exitUrl = (scen, hash, tag) =>
        `${BASE}/?scen=${scen}&theme=light&cell=${encodeURIComponent(tag)}${hash}`;
      // Count catalog reads. The runway cell's whole question is whether Back
      // there is `closeModal()` AND NOTHING ELSE: the wrong single-function fix
      // routes the runway through the remount branch, which refetches the
      // catalog of a provider the person just DECLINED and resets
      // `container._launchHosting` to a null region and size — discarding a
      // choice they had already made. A DOM read cannot see that; a request
      // count can.
      const armCatalogCounter = () => evalJs(
        `(function(){window.__w26cat=0;if(window.__w26armed) return true;window.__w26armed=true;` +
        `var of=window.fetch;window.fetch=function(i,init){` +
        `var u=typeof i==='string'?i:((i&&i.url)||'');` +
        `var m=String((init&&init.method)||(i&&i.method)||'GET').toUpperCase();` +
        `if(m==='GET'&&/\\/v1\\/providers\\/[^/]+\\/catalog$/.test(u)) window.__w26cat++;` +
        `return of.apply(this,arguments);};return true;})()`,
      );
      // Open the modal launch wizard the way a person does — the topbar scope
      // menu, a control on every route — and walk to the credential sheet
      // through the wizard's OWN scoped Connect door.
      const openModalSheet = async (sentinel) => {
        const opened = await evalJs(
          `(function(){var sw=document.getElementById('scope-switch');` +
          `if(!sw) return {ok:false,why:'no #scope-switch in the topbar'};sw.click();` +
          `var l=document.getElementById('scope-launch');` +
          `if(!l) return {ok:false,why:'#scope-launch never rendered into the scope menu'};` +
          `l.click();return {ok:true};})()`,
        );
        if (!opened.ok) return opened;
        if (!await exitWait(`document.querySelector('#launch-modal-slot .launch-connect-provider')`)) {
          return { ok: false, why: "the modal launch wizard never offered a `#launch-modal-slot`-scoped `.launch-connect-provider` door — the person body starts at that door, so nothing below it was measured" };
        }
        // TRAP (1), ASSERTED PER CELL rather than trusted from the fixture: if a
        // runway wizard were also on the page, an unscoped selector anywhere in
        // this cell could bind it and every assertion below would be about the
        // wrong button.
        const shape = await evalJs(
          `(function(){var v=document.getElementById('view-overview');` +
          `return {runway:!!(v&&v.querySelector('.launch-form .form-input')),` +
          `scoped:document.querySelectorAll('#launch-modal-slot .launch-connect-provider').length,` +
          `total:document.querySelectorAll('.launch-connect-provider').length};})()`,
        );
        if (shape.runway) {
          return { ok: false, why: `a RUNWAY wizard is mounted behind the modal on \`${EXIT_SCEN}\` (${shape.total} \`.launch-connect-provider\` on the page, ${shape.scoped} of them scoped) — an unscoped query in this cell would bind the runway button, which writes no stash and whose wizard survives the sheet, so this cell would pass on the DEFECTIVE tree` };
        }
        const walked = await evalJs(
          `(function(){var i=document.querySelector('#launch-modal-slot .launch-form .form-input');` +
          `if(!i) return {ok:false,why:'the modal wizard has no name field'};` +
          `i.value=${JSON.stringify(sentinel)};` +
          `window.__w26slot=document.getElementById('launch-modal-slot');` +
          `document.querySelector('#launch-modal-slot .launch-connect-provider').click();return {ok:true};})()`,
        );
        if (!walked.ok) return walked;
        if (!await exitWait(`document.querySelector('#modal-root #cred-back')`)) {
          return { ok: false, why: "the credential sheet never rendered its own `#cred-back` after the door was pressed — the person never reached the screen this leg is about" };
        }
        // PREMISE, both halves. The sheet must really have taken the wizard with
        // it (otherwise "the person was returned" is green by construction), and
        // the modal detour must really have stashed the name (otherwise this is
        // the runway path wearing the modal path's clothes — trap (1) again).
        const premise = await evalJs(
          `(function(){var s=null;try{s=localStorage.getItem(${JSON.stringify(STASH)});}catch(e){}` +
          `return {destroyed:!(window.__w26slot&&window.__w26slot.isConnected),stash:s};})()`,
        );
        if (!premise.destroyed) {
          return { ok: false, why: "the `#launch-modal-slot` stamped before the door was pressed is STILL MOUNTED — the sheet no longer overwrites the wizard, so this cell never entered the condition it exists to measure" };
        }
        if (premise.stash !== sentinel) {
          return { ok: false, why: `the modal detour did not stash the typed name (\`${STASH}\` reads ${JSON.stringify(premise.stash)}, expected ${JSON.stringify(sentinel)}) — the stash is written only \`if (opts && opts.modal)\`, so this cell is on the RUNWAY path and cannot see the defect` };
        }
        return { ok: true };
      };

      let exitCells = 0, exitLost = 0, exitStale = 0, exitDead = 0;
      for (const [width, height] of EXIT_VIEWPORTS) {
        const row = [];

        // ── (a) THE MODAL, BACK. The forward-navigating exit. It must land the
        //        person back in their wizard with the name they typed.
        exitCells++;
        await setViewport(width, height);
        await nav(
          exitUrl(EXIT_SCEN, "#overview", `back-${width}`),
          `(function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-overview';})()`,
        );
        await evalJs(`(function(){try{localStorage.removeItem(${JSON.stringify(STASH)});}catch(e){}return true;})()`);
        const backSentinel = `Exit Probe ${width}`;
        const reachedBack = await openModalSheet(backSentinel);
        if (!reachedBack.ok) {
          exitDead++;
          fail(D, `modal-back@${width}x${height}: ${reachedBack.why}`);
          row.push("back:!reach");
        } else {
          await evalJs(`document.querySelector('#modal-root #cred-back').click()`);
          await exitWait(`document.querySelector('#launch-modal-slot .launch-form .form-input')`);
          const m = await evalJs(
            `(function(){var r=document.getElementById('modal-root');` +
            `var i=document.querySelector('#launch-modal-slot .launch-form .form-input');` +
            `var s=null;try{s=localStorage.getItem(${JSON.stringify(STASH)});}catch(e){}` +
            `return {hidden:!!(r&&r.hidden),wizard:!!i,name:i?i.value:null,stash:s,` +
            `picker:!!document.querySelector('#modal-root .choice-list'),` +
            `title:(function(){var t=document.querySelector('#modal-root .modal-title');return t?t.textContent:null;})()};})()`,
          );
          if (!m.wizard) {
            exitLost++;
            fail(D, `modal-back@${width}x${height}: pressing Back left NO launch wizard — \`#launch-modal-slot\` is ${m.hidden ? "gone and the modal is closed" : "gone with the modal still open"}, the dialog reads ${JSON.stringify(m.title)}${m.picker ? " and a provider picker they never opened is on screen" : ""}. The person is mid-launch and the console has forgotten it (origin/main bytes: launchWizardBack=false, picker=true, title="Connect a provider")`);
          } else if (m.name !== backSentinel) {
            exitLost++;
            fail(D, `modal-back@${width}x${height}: the wizard is back but the typed instance name is not — the field reads ${JSON.stringify(m.name)}, the person typed ${JSON.stringify(backSentinel)}. Returning them to an empty form is asking them to retype what the console already has`);
          }
          if (m.stash !== null) {
            exitStale++;
            fail(D, `modal-back@${width}x${height}: \`${STASH}\` still holds ${JSON.stringify(m.stash)} after the sheet was left — an abandoned launch's name that outlives its launch is consumed later by an UNRELATED \`?checkout=success\` return, which auto-opens a launch modal prefilled with it`);
          }
          row.push(`back:wizard=${m.wizard} name=${JSON.stringify(m.name)} stash=${JSON.stringify(m.stash)} picker=${m.picker}`);
        }

        // ── (b) THE MODAL, EVERY REFLEX EXIT. A reflex exit promises only
        //        "gone" — but it may not leave the launch haunting the rest of
        //        the console.
        //
        //        REVIEW (wave 26): all three ARE routed through one
        //        `reflexClose()` in `wireModal`, and the builder drove all three
        //        in a scratch census — but the shipped leg asserted only Escape
        //        and rested the other two on that structural argument. A guard
        //        whose coverage is an argument about the code it guards is the
        //        thing this wave's standing test refuses: give the × its own
        //        handler tomorrow and an Escape-only leg never notices. All
        //        three are now DRIVEN, each from its own freshly-opened sheet.
        //        Trap (3) is why the backdrop cell clicks `.modal-backdrop` and
        //        not `#modal-root`, which carries no `data-close` at all and
        //        would report a false "does not close".
        const REFLEX_EXITS = [
          ["escape", "Escape Probe", `document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));return {ok:true};`],
          ["x", "Close-X Probe", `var x=document.querySelector('#modal-root .modal-x[data-close]');if(!x) return {ok:false,why:'no \`.modal-x[data-close]\` in the open sheet — the × either lost its close hook or is no longer rendered, so this exit could not be driven'};x.click();return {ok:true};`],
          ["backdrop", "Backdrop Probe", `var b=document.querySelector('#modal-root .modal-backdrop[data-close]');if(!b) return {ok:false,why:'no \`.modal-backdrop[data-close]\` in the open sheet — trap (3): \`#modal-root\` itself carries no \`data-close\`, so without the real backdrop this cell would report a false pass'};b.click();return {ok:true};`],
        ];
        for (const [via, label, clickJs] of REFLEX_EXITS) {
          exitCells++;
          await setViewport(width, height);
          await nav(
            exitUrl(EXIT_SCEN, "#overview", `${via}-${width}`),
            `(function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-overview';})()`,
          );
          await evalJs(`(function(){try{localStorage.removeItem(${JSON.stringify(STASH)});}catch(e){}return true;})()`);
          const reflexSentinel = `${label} ${width}`;
          const reachedReflex = await openModalSheet(reflexSentinel);
          if (!reachedReflex.ok) {
            exitDead++;
            fail(D, `modal-${via}@${width}x${height}: ${reachedReflex.why}`);
            row.push(`${via}:!reach`);
            continue;
          }
          const fired = await evalJs(`(function(){${clickJs}})()`);
          if (!fired.ok) {
            exitDead++;
            fail(D, `modal-${via}@${width}x${height}: ${fired.why}`);
            row.push(`${via}:!control`);
            continue;
          }
          await exitWait(`(function(){var r=document.getElementById('modal-root');return !!(r&&r.hidden);})()`);
          const m = await evalJs(
            `(function(){var r=document.getElementById('modal-root');` +
            `var s=null;try{s=localStorage.getItem(${JSON.stringify(STASH)});}catch(e){}` +
            `return {hidden:!!(r&&r.hidden),stash:s};})()`,
          );
          if (!m.hidden) {
            exitDead++;
            fail(D, `modal-${via}@${width}x${height}: ${via} did not close the dialog at all — nothing about what it leaves behind can be read off a sheet that is still open`);
          }
          if (m.stash !== null) {
            exitStale++;
            fail(D, `modal-${via}@${width}x${height}: \`${STASH}\` still holds ${JSON.stringify(m.stash)} after ${via} — this is the generator of BOTH secondary bodies: a ghost launch modal pops over \`#providers\` the moment the person connects through that page's own card, and a later unrelated \`?checkout=success\` return auto-opens a launch modal prefilled with this abandoned name (origin/main bytes: both driven, prefilled "Ghost Name" and "Abandoned Launch")`);
          }
          row.push(`${via}:hidden=${m.hidden} stash=${JSON.stringify(m.stash)}`);
        }

        // ── (c) THE RUNWAY, BACK. THE ASYMMETRY TRIPWIRE. Here the inline
        //        wizard and the typed name are UNTOUCHED behind the sheet, so
        //        the honest Back is `closeModal()` and NOTHING ELSE. A fix that
        //        routes both paths through one resume takes the remount branch
        //        here, refetching the catalog of a provider the person just
        //        declined and resetting `container._launchHosting` — the
        //        request count is the only instrument that can see it.
        exitCells++;
        await setViewport(width, height);
        await nav(
          exitUrl(RUNWAY_SCEN, "#overview", `runway-${width}`),
          `document.querySelector('#view-overview .launch-form .form-input')`,
        );
        await evalJs(`(function(){try{localStorage.removeItem(${JSON.stringify(STASH)});}catch(e){}return true;})()`);
        const runwaySentinel = `Runway Alpha ${width}`;
        if (!await exitWait(`document.querySelector('#view-overview .launch-connect-provider')`)) {
          exitDead++;
          fail(D, `runway-back@${width}x${height}: the \`${RUNWAY_SCEN}\` runway never offered a \`.launch-connect-provider\` door — the asymmetry control measured nothing`);
          row.push("runway:!door");
        } else {
          await armCatalogCounter();
          await evalJs(
            `(function(){var i=document.querySelector('#view-overview .launch-form .form-input');` +
            `i.value=${JSON.stringify(runwaySentinel)};` +
            `document.querySelector('#view-overview .launch-connect-provider').click();return true;})()`,
          );
          if (!await exitWait(`document.querySelector('#modal-root #cred-back')`)) {
            exitDead++;
            fail(D, `runway-back@${width}x${height}: the credential sheet never rendered its own \`#cred-back\``);
            row.push("runway:!sheet");
          } else {
            // PREMISE: the inline wizard really does survive the sheet. If it
            // did not, "close and nothing else" would be the wrong answer here
            // and this cell would be pinning a lie.
            const alive = await evalJs(
              `(function(){var i=document.querySelector('#view-overview .launch-form .form-input');` +
              `return {behind:!!i,name:i?i.value:null};})()`,
            );
            if (!alive.behind || alive.name !== runwaySentinel) {
              exitDead++;
              fail(D, `runway-back@${width}x${height}: the inline wizard did NOT survive the sheet (present=${alive.behind}, name=${JSON.stringify(alive.name)}) — the runway's premise changed, and "close and nothing else" is no longer the honest answer here`);
              row.push("runway:!premise");
            } else {
              await evalJs(`window.__w26cat=0`); // count only what BACK causes
              await evalJs(`document.querySelector('#modal-root #cred-back').click()`);
              await exitWait(`(function(){var r=document.getElementById('modal-root');return !!(r&&r.hidden);})()`);
              await sleep(400); // let any remount's catalog request leave
              const m = await evalJs(
                `(function(){var r=document.getElementById('modal-root');` +
                `var i=document.querySelector('#view-overview .launch-form .form-input');` +
                `var s=null;try{s=localStorage.getItem(${JSON.stringify(STASH)});}catch(e){}` +
                `return {hidden:!!(r&&r.hidden),wizard:!!i,name:i?i.value:null,stash:s,cat:window.__w26cat,` +
                `picker:!!document.querySelector('#modal-root .choice-list')};})()`,
              );
              if (!m.hidden || m.picker) {
                exitLost++;
                fail(D, `runway-back@${width}x${height}: Back left the person inside a modal (hidden=${m.hidden}, provider picker on screen=${m.picker}) instead of putting them back on the wizard that was behind it the whole time — on origin/main this cell read hidden=false, picker=true`);
              }
              if (!m.wizard || m.name !== runwaySentinel) {
                exitLost++;
                fail(D, `runway-back@${width}x${height}: the inline wizard or its typed name did not survive Back (present=${m.wizard}, name=${JSON.stringify(m.name)}, typed ${JSON.stringify(runwaySentinel)})`);
              }
              if (m.cat !== 0) {
                exitStale++;
                fail(D, `runway-back@${width}x${height}: Back fired ${m.cat} \`GET /v1/providers/*/catalog\` request(s). On the runway the wizard is UNTOUCHED behind the sheet, so Back owes it nothing — a remount here refetches the catalog of a provider the person just DECLINED and resets \`container._launchHosting\` to a null region and server_type, silently discarding a size they had already picked. This is the cell that separates the path-asymmetric fix from the one-function version`);
              }
              if (m.stash !== null) {
                exitStale++;
                fail(D, `runway-back@${width}x${height}: \`${STASH}\` reads ${JSON.stringify(m.stash)} — the runway path writes no stash, so anything here is a record leaking across paths`);
              }
              row.push(`runway:hidden=${m.hidden} wizard=${m.wizard} name=${JSON.stringify(m.name)} catalogGETs=${m.cat}`);
            }
          }
        }

        process.stdout.write(`   ${width}x${height}  ${row.join("  ")}\n`);
      }

      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${exitCells} / ${exitCells} cells clean across ${EXIT_VIEWPORTS.map(([w, h]) => `${w}x${h}`).join(" and ")}: ` +
          `ALL FIVE exits from the credential sheet — Back, Escape, the ×, the backdrop and the runway's Back — ` +
          `either return the person to their launch or clear it, and none leaves it half-remembered. Each reflex ` +
          `exit is DRIVEN from its own freshly-opened sheet rather than inferred from the three sharing one ` +
          `\`reflexClose()\`: a coverage claim that is an argument about the code under test is not coverage. ` +
          `${exitLost} lost launches, ${exitStale} stale records, ${exitDead} cells that could not reach the screen`,
        );
        okLine(
          `THE SCOPE IS THE MEASUREMENT (trap 1). Every query in the modal cells is scoped to \`#launch-modal-slot\` ` +
          `and the fixture is \`${EXIT_SCEN}\`, NOT \`empty\`: driven on \`empty\`, ` +
          `\`document.querySelectorAll('.launch-connect-provider')\` returns 1 with ZERO inside \`#launch-modal-slot\` ` +
          `— the first match is the RUNWAY button in \`#view-overview\`, which writes no stash ` +
          `(\`bp_launch_return = null\`, the stash is written only \`if (opts && opts.modal)\`) and whose wizard ` +
          `SURVIVES the sheet. An unscoped leg on \`empty\` therefore passes on pre-fix bytes. Each modal cell also ` +
          `asserts that no runway wizard is mounted behind the modal, so the fixture cannot drift into that shape ` +
          `silently`,
        );
        okLine(
          `THE RUNWAY CELL IS THE ASYMMETRY TRIPWIRE, and it is a REQUEST count, not a DOM read: Back there must ` +
          `fire ZERO \`GET /v1/providers/*/catalog\`. A one-function fix routing both paths through the resume ` +
          `takes the remount branch here — refetching a declined provider's catalog and nulling ` +
          `\`container._launchHosting\`'s region and server_type — and scores PERFECTLY on every DOM assertion in ` +
          `this leg while doing it`,
        );
      }
    }



    // ── cch-w26-s6: THE TWO /new SCREENS NOBODY EVER MEASURED ───────────────
    //    THE CENSUS, re-derived at origin/main cfc2f2b77 with its counting rule
    //    (`grep -c '<scenario>'` over the three instruments — overflow-guard /
    //    smoke / breakpoint-sweep):
    //      theater-failed     21 / 1 / 1
    //      theater-midflight  12 / 1 / 1
    //      theater-ready       0 / 1 / 1
    //      new-launch          0 / 2 / 1
    //    So both screens on the HAPPY path of the launch journey — the one
    //    every signup starts on and the one every successful signup ends on —
    //    had markup coverage in smoke.mjs and ZERO geometry anywhere, while the
    //    failure screen beside them carries 21 mentions. The width sweep cannot
    //    close it: all four /new scenarios sit in breakpoint-sweep's
    //    SCENARIO_RESIDUE under `path:/new` for an ARCHITECTURAL reason it
    //    states itself — "The launch/theater page is likewise its own document
    //    outside the shell" — and that sweep walks the console SHELL's screen
    //    axis. This leg is the gap's only possible owner.
    //
    //    THE FIXTURES ARE KIND, AND THAT IS THIS LEG'S CENTRAL PROBLEM (the
    //    wave's fourth standing clause: a guard whose FIXTURE cannot produce
    //    the defect is green by construction). `theater-ready`'s longest
    //    rendered run is its own instance URL at 35 chars; `new-launch` renders
    //    no instance at all (`barkparks: []`, `sites: []`) — a template card, a
    //    name field and a Launch button. A leg driven on these fixtures AS THEY
    //    STAND proves nothing, so the KIND baseline below is driven FIRST and
    //    printed with the longest run it found, precisely so the by-construction
    //    green is on the record as a measurement rather than as a claim.
    //
    //    CRUELTY IS INJECTED AT RUNTIME AND DERIVED, NEVER PASTED, copying the
    //    W24 leg's own stress pattern rather than authoring a fixture (which
    //    would have meant touching scenarios.mjs, outside this slice's fence):
    //      · the host is `"a".repeat(63) + ".barkpark.cloud"` — 63 is the RFC
    //        1035 DNS LABEL CAP, so this is the longest unbreakable run any
    //        real host can present and a stress built past it would assert
    //        against a string this screen can never receive.
    //      · the name is `"a".repeat(255)` — 255 is the SERVER'S OWN cap on a
    //        site/instance name (`validate_length max: 255`), the same cap the
    //        cruel-content fixture family is built at. It is the honest worst
    //        case a person can type into `#new-name`, not an arbitrary number.
    //
    //    WHAT IS ASSERTED IS EVERY BOX, NOT A PINNED SELECTOR: every element
    //    under `#new-body` is measured against its OWN client width, because
    //    the W25 finding on the sibling screen was a box (.new-theater-grid
    //    251/214) that the PAGE number never saw. Two kinds of element are
    //    skipped and counted, never silently: form controls (an `<input>`
    //    scrolls its own value by design — that is the control working, not an
    //    overflow) and any box that declares `overflow-x: auto|scroll`, which
    //    has opted into its own scroller. The skipped count is printed so the
    //    exclusion cannot hide a screen.
    //
    //    THE OUTCOME IS SPLIT, AND SAYING SO IS THE POINT.
    //      new-launch is a MEASURED REFUSAL, fully asserted and clean: a
    //        255-char name leaves the page at 320/320 and no box under
    //        #new-body over its own client width. The reason is structural and
    //        worth writing down rather than re-discovering — an `<input>`'s
    //        width does not track its value (it clips and scrolls internally),
    //        so no string a person types into `#new-name` can widen this
    //        screen. That is a real result for a screen that had none, and it
    //        is a refusal, not a fix.
    //      theater-ready BIT, and is now FIXED and ASSERTED. W26 measured the
    //        defect and could only pin it (its fence was this file); W27 landed
    //        the one-declaration remedy in app.css — `overflow-wrap: anywhere`
    //        on the pre-existing `.new-ready .mono` head, the same escape
    //        `.site-meta .mono` already carries — and turned the ceiling into
    //        the unconditional refusal described below. The 78-char host now
    //        leaves the page at 320/320 with ZERO boxes over their own client
    //        width, in both themes.
    //
    //    IT CAN LOSE, AND THAT WAS DRIVEN, NOT ARGUED. Two mutations of the
    //    SHIPPED tree, each applied to app.css, run, and reverted:
    //      `.new-desc { white-space: nowrap }`  → 82 findings, exit 1. It reds
    //        the KIND half of BOTH screens (theater-ready .new-desc 491/214 at
    //        320 with the ordinary 35-char URL; new-launch page 479/320) AND
    //        drags 622px on the cruel half — measured against W26's 408px pin,
    //        and refused outright by the 0px rule that replaced it.
    //      W27 added a third, on the remedy itself: reverting `overflow-wrap:
    //        anywhere` from `.new-ready .mono` on an otherwise-fixed tree →
    //        10 findings, exit 1 (4 box refusals per theme naming each pre-fix
    //        member, plus the drag leg in both themes). Under the subset rule
    //        this file shipped with, the SAME revert scored 2.
    //      `#new-name { width: 140% }`          → 60 findings, exit 1. It reds
    //        the field-containment assertion specifically (`#new-name` right
    //        edge 352.59 against the card's inner edge 267) — the one question
    //        on new-launch that the box sweep cannot ask, because the input is
    //        excluded from it.
    //
    //    D274/D292: no line numbers above. Every citation is a grep or a class.
    if (requested.includes("W26-new-ready-and-launch-bounded")) {
      const D = "W26-new-ready-and-launch-bounded";
      // BLOCK-SCOPED (precedent: `const D`, FAIL_WIDTHS above). The same phone
      // band the theater family is driven at, so a remedy landing on the shared
      // `.new-card` column is seen by both legs at the same widths.
      const W26_WIDTHS = [320, 360, 390, 430];
      // BUILT, never pasted, so the length is a fact of this line: 63 = the RFC
      // 1035 DNS label cap.
      const CRUEL_HOST = "a".repeat(63) + ".barkpark.cloud";
      // 255 = the server's `validate_length max: 255` on a name.
      const NAME_CAP = 255;
      const CRUEL_NAME = "a".repeat(NAME_CAP);
      const { SCENARIOS: S26 } = await import("./scenarios.mjs");

      // ── THE DEFECT THIS LEG FOUND, AND THE REFUSAL THAT REPLACED IT ───────
      //   The cruel host is not a synthetic string on this screen. Barkpark
      //   itself validates `:slug` at `max: 63` and builds the customer-facing
      //   FQDN as `clean_url(slug) = "https://" <> slug <> ".barkpark.cloud"` —
      //   so `https://<63 chars>.barkpark.cloud`, exactly what is injected
      //   below, is the LONGEST URL the control plane can hand this hero, and
      //   a person who names their instance with a long slug gets it.
      //
      //   W26 DROVE IT AND IT BIT: at 320 in both themes documentElement
      //   .scrollWidth read 728 against 320 — 408px of the screen every
      //   successful signup lands on off-screen sideways, the mono run painted
      //   670.81px into a 214px paragraph (456.81px OUTSIDE it) and 4 boxes per
      //   theme over their own client width — because `.new-ready .mono`
      //   carried no wrap escape and neither `.new-card` nor `.new-screen`
      //   scrolls. W26's fence was this file, so it could only PIN those
      //   numbers as a ceiling (task-ee662108818d603c).
      //
      //   W27 LANDED THE REMEDY AND THE CEILING IS GONE. One declaration in the
      //   pre-existing `.new-ready .mono` head in app.css — `overflow-wrap:
      //   anywhere`, the escape `.site-meta .mono` already carries — takes the
      //   cruel half to page 320/320, drag 0, boxes 0, mono 210.61/214, in both
      //   themes, while the shipped 35-char host keeps the EXACT rects it had
      //   (Range widths 109.2|163.81 at 320/360/430, one 273px rect at 390 —
      //   identical before and after). So the ceiling is now a REFUSAL:
      //     · the drag must be 0 (READY_CRUEL_DRAG below), and
      //     · NO box under #new-body may exceed its own client width — an
      //       unconditional rule, not a subset. The pre-fix four are kept as a
      //       NAMED BASELINE so a regressing member reads as "the W26 defect is
      //       back on this box", never as an anonymous stranger.
      //   Deleting the subset rule instead of replacing it would have removed
      //   an assertion — the instrument-weakening this epic is chartered
      //   against. It can lose: see the mutation record above the block.
      const READY_CRUEL_DRAG = 0;
      // The four boxes that overflowed PRE-FIX, at 320 in both themes. Never an
      // allowlist — every entry here is now REQUIRED to be clean; the list
      // exists only so a red names which W26 box came back.
      const READY_PREFIX_BOXES = ["new-body", "new-card card", "new-ready", "new-desc"];

      // EVERY box under #new-body against its own client width. Form controls
      // and declared scrollers are skipped AND COUNTED — an exclusion that is
      // not printed is an exclusion that can hide a screen.
      const BOXES_JS =
        `[].slice.call(document.querySelectorAll('#new-body, #new-body *')).forEach(function(el){` +
        `  var tn=el.tagName;` +
        `  if(tn==='INPUT'||tn==='TEXTAREA'||tn==='SELECT'){out.skipped++;return;}` +
        `  var ox=getComputedStyle(el).overflowX;` +
        `  if(ox==='auto'||ox==='scroll'){out.skipped++;return;}` +
        `  if(el.scrollWidth>el.clientWidth+1) out.boxes.push({cls:(el.className||tn||'?').toString().slice(0,40),sw:el.scrollWidth,cw:el.clientWidth});});`;
      // The LONGEST RENDERED RUN on the screen — the number that makes the kind
      // baseline honest. A whitespace split, so it is the longest token a line
      // breaker cannot break at, measured over rendered text only.
      const LONGEST_JS =
        `var lw=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);var ln;` +
        `while((ln=lw.nextNode())){var lp=ln.parentElement;if(!lp||!lp.getClientRects().length) continue;` +
        `  (ln.nodeValue||'').split(/\\s+/).forEach(function(t){if(t.length>out.longest){out.longest=t.length;out.longestTxt=t.slice(0,48);}});}`;
      // The TIGHTEST margin any measured box has left, so "clean" carries a
      // distance rather than a boolean. Same skip rule as the box sweep.
      const TIGHT_JS =
        `[].slice.call(document.querySelectorAll('#new-body *')).forEach(function(el){` +
        `  var tn=el.tagName;if(tn==='INPUT'||tn==='TEXTAREA'||tn==='SELECT')return;` +
        `  var ox=getComputedStyle(el).overflowX;if(ox==='auto'||ox==='scroll')return;` +
        `  if(el.clientWidth>0){var mg=el.clientWidth-el.scrollWidth;if(mg<out.tight){out.tight=mg;out.tightCls=(el.className||tn||'?').toString().slice(0,40);}}});`;
      // Names the boxes that pushed a dragging page. A page number alone sends
      // the next reader back into DevTools.
      const WIDEST_JS =
        `if(d.scrollWidth>d.clientWidth){` +
        `  [].slice.call(document.querySelectorAll('.new-screen *')).forEach(function(el){` +
        `    var r=el.getBoundingClientRect();if(r.width>0&&r.right>d.clientWidth+1)` +
        `      out.wide.push({cls:(el.className||el.tagName||'?').toString().slice(0,40),right:+r.right.toFixed(2)});});` +
        `  out.wide.sort(function(a,b){return b.right-a.right;});out.wide=out.wide.slice(0,4);}`;
      const widestOf = (m) => (m.wide || []).map((x) => `.${x.cls} right=${x.right}`).join(" | ") || "none inside .new-screen";

      // The URL is DERIVED FROM THE FIXTURE, not transcribed — a transcribed
      // host rots silently into "the leg measured a screen that no longer says
      // it". Zero occurrences at runtime is a REFUSAL below, never a pass.
      const readySc = S26["theater-ready"];
      if (!readySc || !readySc.pathname || !readySc.search) {
        return die(`${D}: SCENARIOS["theater-ready"] no longer carries pathname+search — the ready hero cannot be reached, so nothing was measured`);
      }
      const READY_URL = ((readySc.data && readySc.data.barkparks && readySc.data.barkparks[0]) || {}).url;
      if (!READY_URL) {
        return die(`${D}: SCENARIOS["theater-ready"] no longer carries barkparks[0].url — the run this leg measures is derived from it, so nothing could be stressed`);
      }
      const launchSc = S26["new-launch"];
      if (!launchSc || !launchSc.pathname || !launchSc.search) {
        return die(`${D}: SCENARIOS["new-launch"] no longer carries pathname+search — the launch step cannot be reached, so nothing was measured`);
      }

      process.stdout.write(
        `\n${D} — theater-ready + new-launch x ${W26_WIDTHS.length} widths x 2 themes ` +
        `(${W26_WIDTHS.length * 2 * 2} kind cells + 4 cruel probes; EVERY box under #new-body against its own ` +
        `client width, the page, and the longest rendered run per cell. Cruelty is injected at runtime: a ` +
        `${CRUEL_HOST.length}-char host (63-octet DNS label, the legal maximum) on the ready hero and a ` +
        `${NAME_CAP}-char name in #new-name — the two screens' fixtures are KIND and the kind rows say so)\n`,
      );

      let rdCells = 0, rdUrls = 0, rdBox = 0, rdPage = 0, rdLongestKind = 0;
      let lnCells = 0, lnBox = 0, lnPage = 0, lnLongestKind = 0;
      let cruelRuns = 0, cruelBox = 0, cruelPage = 0, skippedSeen = 0, lnCruelBox = 0, lnCruelPage = 0;
      let rdKindMargin = Infinity, lnKindMargin = Infinity, cruelMargin = Infinity;
      let rdKindTightCls = "", lnKindTightCls = "", lnKindTight = Infinity, lnCruelFieldSw = 0, rdMonoSlack = Infinity, rdCruelMonoOver = 0, rdMonoKind = "", rdMonoCruel = "";

      // ── A. theater-ready — the hero every successful signup lands on ───────
      for (const theme of ["light", "dark"]) {
        await setViewport(W26_WIDTHS[W26_WIDTHS.length - 1]);
        await nav(
          `${BASE}${readySc.pathname}${readySc.search}&scen=theater-ready&theme=${theme}`,
          `document.querySelector('.new-ready') && document.querySelector('.new-ready .mono')`,
        );
        const row = [];
        for (const width of W26_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){` +
            `var d=document.documentElement;` +
            `var out={ready:!!document.querySelector('.new-ready'),theme:d.getAttribute('data-theme'),` +
            `psw:d.scrollWidth,pcw:d.clientWidth,urls:0,boxes:[],skipped:0,longest:0,longestTxt:'',wide:[],tight:1e9,tightCls:'',mono:null};` +
            // The URL must be ON the screen. A hero that stopped naming the
            // instance would let every line below print a perfect table about
            // nothing at all.
            `var uw=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);var un;` +
            `while((un=uw.nextNode())){if((un.nodeValue||'').indexOf(${JSON.stringify(READY_URL)})>=0){` +
            `  var up=un.parentElement;if(up&&up.getClientRects().length) out.urls++;}}` +
            BOXES_JS + TIGHT_JS + LONGEST_JS + WIDEST_JS +
            // The mono run's PAINTED width is REPORTED at every width, not only
            // on failure: "the URL fits with room to spare" is a claim about
            // numbers, and a row that prints them only when red cannot be
            // quoted for it. It is a rect, not scrollWidth — `.new-ready .mono`
            // is an inline span, and scrollWidth on an inline box is 0, which
            // would have read as a perfect fit at every width.
            `var mo=document.querySelector('.new-ready .mono');` +
            `if(mo){var mr=mo.getBoundingClientRect(),mp=mo.parentElement;` +
            `  out.mono={w:+mr.width.toFixed(2),pcw:mp?mp.clientWidth:0};}` +
            `return out;})()`,
          );
          rdCells++;
          if (!m.ready) {
            fail(D, `theater-ready/${theme}@${width}: no .new-ready on the page — the ready hero did not render, so nothing below this line measures it`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `theater-ready/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          if (m.urls === 0) {
            fail(D, `theater-ready/${theme}@${width}: zero rendered text nodes carry "${READY_URL}" — the hero no longer names the instance a person must click, so nothing was measured and this is not a pass`);
            row.push(`${width}:0u`);
            continue;
          }
          rdUrls += m.urls;
          rdLongestKind = Math.max(rdLongestKind, m.longest);
          skippedSeen = Math.max(skippedSeen, m.skipped);
          if (m.psw > m.pcw) {
            rdPage++;
            fail(D, `theater-ready/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the hero every successful signup lands on is off-screen sideways. Widest: ${widestOf(m)}`);
          }
          for (const b of m.boxes) {
            rdBox++;
            fail(D, `theater-ready/${theme}@${width} .${b.cls}: scrollWidth ${b.sw} > clientWidth ${b.cw} with the ORDINARY fixture — a box on the ready hero is wider than the box that holds it, and no cruel string was needed to do it`);
          }
          if (m.tight < rdKindMargin) { rdKindMargin = m.tight; rdKindTightCls = m.tightCls; }
          // The URL's OWN headroom — the number the cruel half destroys, and
          // the only margin on this screen that is about content rather than
          // about a block box exactly filling its parent.
          if (m.mono && width === W26_WIDTHS[0]) {
            rdMonoSlack = Math.min(rdMonoSlack, +(m.mono.pcw - m.mono.w).toFixed(2));
            rdMonoKind = `${m.mono.w} painted into a ${m.mono.pcw}px box`;
          }
          row.push(`${width}:${m.urls}u ${m.psw}/${m.pcw}px mono ${m.mono ? `${m.mono.w}/${m.mono.pcw}` : "-"} run=${m.longest}c tight=${m.tight}px${m.boxes.length ? " box!" + m.boxes.length : ""}`);
        }
        // ── the cruel half, at the narrowest width only ──────────────────────
        //   Same text nodes, one unbreakable 78-char URL. This is the half the
        //   kind fixture cannot ask: 35 chars fit in this column at 320 whether
        //   or not anything wraps — which is exactly why a leg driven on the
        //   shipped fixture would have certified this screen.
        //   It BIT on W26's bytes and is FIXED on these. What is asserted here
        //   is the REFUSAL form described at the top of the block: zero drag,
        //   zero boxes over their own client width.
        await setViewport(W26_WIDTHS[0]);
        const cr = await evalJs(
          `(function(){` +
          `var d=document.documentElement;var hit=0;` +
          `var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);var n,ns=[];` +
          `while((n=w.nextNode())){if((n.nodeValue||'').indexOf(${JSON.stringify(READY_URL)})>=0) ns.push(n);}` +
          `ns.forEach(function(x){x.nodeValue=(x.nodeValue||'').split(${JSON.stringify(READY_URL)}).join(${JSON.stringify("https://" + CRUEL_HOST)});hit++;});` +
          `void d.offsetWidth;` +
          `var out={hit:hit,psw:d.scrollWidth,pcw:d.clientWidth,boxes:[],skipped:0,longest:0,longestTxt:'',wide:[],tight:1e9,tightCls:'',mono:null};` +
          BOXES_JS + TIGHT_JS + LONGEST_JS + WIDEST_JS +
          `var mo=document.querySelector('.new-ready .mono');` +
          `if(mo){var mr=mo.getBoundingClientRect(),mp=mo.parentElement;out.mono={w:+mr.width.toFixed(2),pcw:mp?mp.clientWidth:0};}` +
          `return out;})()`,
        );
        cruelRuns++;
        if (cr.hit === 0) {
          fail(D, `theater-ready/${theme}@${W26_WIDTHS[0]} CRUEL: the ${CRUEL_HOST.length}-char host replaced nothing — the cruel half measured no element, so this leg's only falsifiable question was not asked`);
        }
        // UNCONDITIONAL, not a subset: EVERY box here is a finding. The
        // baseline list only decides which SENTENCE a red gets — a W26 member
        // coming back is a regression of a fixed defect and says so by name; a
        // stranger is a surface the remedy never covered.
        for (const b of cr.boxes) {
          cruelBox++;
          fail(D, READY_PREFIX_BOXES.includes(b.cls)
            ? `theater-ready/${theme}@${W26_WIDTHS[0]} CRUEL .${b.cls}: scrollWidth ${b.sw} > clientWidth ${b.cw} — the ${CRUEL_HOST.length}-char host pushes a box past its own client width again, and .${b.cls} is one of the four W26 measured pre-fix [${READY_PREFIX_BOXES.join(", ")}]: the wrap escape on .new-ready .mono is gone or has been outranked, and the 408px drag on the screen every successful signup lands on is back`
            : `theater-ready/${theme}@${W26_WIDTHS[0]} CRUEL .${b.cls}: scrollWidth ${b.sw} > clientWidth ${b.cw} — a box the W26 defect never touched now overflows under the ${CRUEL_HOST.length}-char host, so the ready hero has a spill the .new-ready .mono remedy does not cover`);
        }
        const drag = cr.psw - cr.pcw;
        if (drag > READY_CRUEL_DRAG) {
          cruelPage++;
          fail(D, `theater-ready/${theme}@${W26_WIDTHS[0]} CRUEL: a ${CRUEL_HOST.length}-char host takes documentElement.scrollWidth to ${cr.psw} against ${cr.pcw} — ${drag}px of drag on the hero every successful signup lands on, against the ${READY_CRUEL_DRAG}px this leg now REFUSES to exceed (W26 measured 408px here and could only pin it; W27 fixed it). Widest: ${widestOf(cr)}`);
        }
        cruelMargin = Math.min(cruelMargin, drag);
        if (cr.mono) { rdCruelMonoOver = Math.max(rdCruelMonoOver, +(cr.mono.w - cr.mono.pcw).toFixed(2)); rdMonoCruel = `${cr.mono.w} painted into the same ${cr.mono.pcw}px box`; }
        row.push(`cruel@${W26_WIDTHS[0]}:${cr.hit}n run=${cr.longest}c mono ${cr.mono ? `${cr.mono.w}/${cr.mono.pcw}` : "-"} box:${cr.boxes.length} page:${cr.psw}/${cr.pcw}px drag=${drag}px(<=${READY_CRUEL_DRAG} REFUSED)`);
        process.stdout.write(`   theater-ready/${theme}  ${row.join("  ")}\n`);
      }

      // ── B. new-launch — the step EVERY signup starts on ────────────────────
      //    It renders no instance at all, so there is nothing on it long enough
      //    to overflow anything: the kind row's `run=` column is the proof of
      //    that, and the cruel probe is the only question worth asking here.
      for (const theme of ["light", "dark"]) {
        await setViewport(W26_WIDTHS[W26_WIDTHS.length - 1]);
        await nav(
          `${BASE}${launchSc.pathname}${launchSc.search}&scen=new-launch&theme=${theme}`,
          `document.querySelector('.new-launch') && document.getElementById('new-name')`,
        );
        const row = [];
        for (const width of W26_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){` +
            `var d=document.documentElement;var f=document.getElementById('new-name');` +
            `var out={launch:!!document.querySelector('.new-launch'),name:!!f,btn:!!document.getElementById('new-launch-btn'),` +
            `theme:d.getAttribute('data-theme'),psw:d.scrollWidth,pcw:d.clientWidth,boxes:[],skipped:0,longest:0,longestTxt:'',wide:[],tight:1e9,tightCls:'',field:null};` +
            BOXES_JS + TIGHT_JS + LONGEST_JS + WIDEST_JS +
            // The FIELD'S OWN CONTAINMENT: an input is excluded from the box
            // sweep (it scrolls its value by design), so it is asked the only
            // question that is really about layout — does its border box stay
            // inside the card that holds it.
            `var card=document.querySelector('.new-card');` +
            `if(f&&card){var fr=f.getBoundingClientRect(),cr2=card.getBoundingClientRect();` +
            `  var cs=getComputedStyle(card);` +
            `  var inner=cr2.right-parseFloat(cs.paddingRight||0)-parseFloat(cs.borderRightWidth||0);` +
            `  out.field={right:+fr.right.toFixed(2),inner:+inner.toFixed(2),cw:f.clientWidth,sw:f.scrollWidth};}` +
            `return out;})()`,
          );
          lnCells++;
          if (!m.launch || !m.name || !m.btn) {
            fail(D, `new-launch/${theme}@${width}: .new-launch=${m.launch}, #new-name=${m.name}, #new-launch-btn=${m.btn} — the launch step did not render, so nothing below this line measures it`);
            row.push(`${width}:?`);
            continue;
          }
          if (m.theme !== theme) fail(D, `new-launch/${theme}@${width}: data-theme is "${m.theme}" — the theme did not apply`);
          lnLongestKind = Math.max(lnLongestKind, m.longest);
          skippedSeen = Math.max(skippedSeen, m.skipped);
          if (m.psw > m.pcw) {
            lnPage++;
            fail(D, `new-launch/${theme}@${width}: documentElement.scrollWidth ${m.psw} > clientWidth ${m.pcw} — ${m.psw - m.pcw}px of the step every signup starts on is off-screen sideways. Widest: ${widestOf(m)}`);
          }
          for (const b of m.boxes) {
            lnBox++;
            fail(D, `new-launch/${theme}@${width} .${b.cls}: scrollWidth ${b.sw} > clientWidth ${b.cw} with the ORDINARY fixture — a box on the step every signup starts on is wider than the box that holds it`);
          }
          if (m.field) {
            if (m.field.right > m.field.inner + 1) {
              lnBox++;
              fail(D, `new-launch/${theme}@${width} #new-name: the field's right edge is ${m.field.right} against the card's inner edge ${m.field.inner} — the one control on this screen paints outside the card that holds it`);
            }
            lnKindMargin = Math.min(lnKindMargin, m.field.inner - m.field.right);
          }
          if (m.tight < lnKindTight) { lnKindTight = m.tight; lnKindTightCls = m.tightCls; }
          row.push(`${width}:${m.psw}/${m.pcw}px field ${m.field ? `${m.field.right}/${m.field.inner}` : "-"} run=${m.longest}c tight=${m.tight}px${m.boxes.length ? " box!" + m.boxes.length : ""}`);
        }
        // ── the cruel half: the longest name a person can actually submit ────
        //   `#new-name` has no maxlength attribute, and the server caps a name
        //   at 255 — so 255 chars of unbroken text is exactly what this control
        //   can receive from a real person. An `input` event is dispatched
        //   because a value set from script does not fire one, and a screen
        //   that reacts to typing must be given the chance to.
        await setViewport(W26_WIDTHS[0]);
        const cn = await evalJs(
          `(function(){` +
          `var d=document.documentElement;var f=document.getElementById('new-name');` +
          `if(!f) return {hit:0};` +
          `f.value=${JSON.stringify(CRUEL_NAME)};` +
          `f.dispatchEvent(new Event('input',{bubbles:true}));` +
          `void d.offsetWidth;` +
          `var out={hit:f.value.length,psw:d.scrollWidth,pcw:d.clientWidth,boxes:[],skipped:0,longest:0,longestTxt:'',wide:[],tight:1e9,tightCls:'',field:null};` +
          BOXES_JS + TIGHT_JS + LONGEST_JS + WIDEST_JS +
          `var card=document.querySelector('.new-card');` +
          `if(card){var fr=f.getBoundingClientRect(),cr2=card.getBoundingClientRect();var cs=getComputedStyle(card);` +
          `  var inner=cr2.right-parseFloat(cs.paddingRight||0)-parseFloat(cs.borderRightWidth||0);` +
          `  out.field={right:+fr.right.toFixed(2),inner:+inner.toFixed(2),cw:f.clientWidth,sw:f.scrollWidth};}` +
          `return out;})()`,
        );
        if (cn.hit !== NAME_CAP) {
          fail(D, `new-launch/${theme}@${W26_WIDTHS[0]} CRUEL: #new-name holds ${cn.hit} chars after a ${NAME_CAP}-char write — the cruel half did not land, so this screen's only falsifiable question was not asked`);
        } else {
          // FULLY ASSERTED, unlike the ready hero's cruel half — this one comes
          // back CLEAN on these bytes, so there is nothing to file and nothing
          // to pin. The control holds its 255 chars internally (scrollWidth
          // ~2037 against a ~212px client box, which is the input doing its
          // job) and pushes neither the card nor the page.
          for (const b of cn.boxes) {
            lnCruelBox++;
            fail(D, `new-launch/${theme}@${W26_WIDTHS[0]} CRUEL .${b.cls}: scrollWidth ${b.sw} > clientWidth ${b.cw} — a ${NAME_CAP}-char project name (the server's own validate_length cap, typeable into this field today) pushes a box on the launch step past its own client width`);
          }
          if (cn.field && cn.field.right > cn.field.inner + 1) {
            lnCruelBox++;
            fail(D, `new-launch/${theme}@${W26_WIDTHS[0]} CRUEL #new-name: the field's right edge is ${cn.field.right} against the card's inner edge ${cn.field.inner} — a ${NAME_CAP}-char name widens the control itself, so the one input on this screen paints outside its card`);
          }
          if (cn.psw > cn.pcw) {
            lnCruelPage++;
            fail(D, `new-launch/${theme}@${W26_WIDTHS[0]} CRUEL: a ${NAME_CAP}-char project name takes documentElement.scrollWidth to ${cn.psw} against ${cn.pcw} — ${cn.psw - cn.pcw}px of the step every signup starts on drags sideways. Widest: ${widestOf(cn)}`);
          }
          if (cn.field) lnCruelFieldSw = Math.max(lnCruelFieldSw, cn.field.sw);
        }
        cruelRuns++;
        row.push(`cruel@${W26_WIDTHS[0]}:${cn.hit}c field ${cn.field ? `${cn.field.right}/${cn.field.inner} sw${cn.field.sw}/cw${cn.field.cw}` : "-"} box:${(cn.boxes || []).length} tight=${cn.tight}px page:${cn.psw}/${cn.pcw}px`);
        process.stdout.write(`   new-launch/${theme}  ${row.join("  ")}\n`);
      }

      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${rdCells + lnCells} / ${rdCells + lnCells} kind cells clean across ${W26_WIDTHS.join("/")} in both ` +
          `themes (${rdCells} theater-ready, ${lnCells} new-launch; ${rdUrls} rendered "${READY_URL}" runs measured, ` +
          `${rdBox + lnBox} box overflows, ${rdPage + lnPage} pages dragging). Both screens had ZERO geometry ` +
          `coverage in this file before this row — the census at origin/main cfc2f2b77 read theater-ready 0/1/1 and ` +
          `new-launch 0/2/1 against theater-failed's 21/1/1`,
        );
        okLine(
          `THE KIND ROWS ARE WHY THE CRUEL HALF EXISTS, and this is the measurement rather than the claim: the ` +
          `longest rendered run is ${rdLongestKind} chars on theater-ready (its own instance URL) and ` +
          `${lnLongestKind} on new-launch, which renders no instance at all. BY HOW MUCH MARGIN: the URL's painted ` +
          `run clears its own paragraph by ${rdMonoSlack === Infinity ? "n/a" : rdMonoSlack + "px"} at the narrowest ` +
          `width (${rdMonoKind} at ${W26_WIDTHS[0]}), and the tightest slack over EVERY measured box is ` +
          `${rdKindMargin === Infinity ? "n/a" : rdKindMargin + "px"} on theater-ready (.${rdKindTightCls}) and ` +
          `${lnKindTight === Infinity ? "n/a" : lnKindTight + "px"} on new-launch (.${lnKindTightCls}) — 0 because a ` +
          `full-width block exactly fills its parent, never because anything is at its limit. Nothing this short ` +
          `can overflow this column at any of these widths, so a leg driven on the SHIPPED fixtures alone would ` +
          `have been green BY CONSTRUCTION and certified both screens`,
        );
        okLine(
          `THE CRUEL HALF RAN ${cruelRuns} time(s) at ${W26_WIDTHS[0]} in both themes. new-launch is a MEASURED ` +
          `REFUSAL and fully asserted: a ${NAME_CAP}-char project name (the server's validate_length cap, typeable ` +
          `into #new-name today, no maxlength on the control) leaves ${lnCruelBox} box overflow(s) and ` +
          `${lnCruelPage} dragging page(s) — the input holds it internally (scrollWidth ${lnCruelFieldSw} against a ` +
          `~212px client box, which is the control working) and the field still clears the card's inner edge by ` +
          `${lnKindMargin === Infinity ? "n/a" : lnKindMargin.toFixed(2) + "px"}`,
        );
        okLine(
          `theater-ready IS A REFUSAL NOW, and W26's measurement is why it is worth one: ${CRUEL_HOST.length} chars ` +
          `of URL — Barkpark's own validate_length(:slug, max: 63) plus clean_url/1's "https://" <> slug <> ` +
          `".barkpark.cloud", i.e. the LONGEST url the control plane can hand this hero — dragged the page 408px at ` +
          `${W26_WIDTHS[0]}, overflowed 4 boxes per theme and painted the URL's run 456.81px OUTSIDE its own 214px ` +
          `paragraph on W26's bytes (those three are LITERALS from the pre-fix run, deliberately not read off this ` +
          `one, which would print 0 and tell the next reader nothing happened here). ON THESE BYTES the same ` +
          `injection drags ${cruelMargin === Infinity ? "n/a" : cruelMargin + "px"} at ${W26_WIDTHS[0]} and overflows ` +
          `${cruelBox} box(es) across the two themes, the run painting ${rdMonoCruel} — ${rdCruelMonoOver}px outside ` +
          `it — because 'overflow-wrap: anywhere' on .new-ready .mono lets a 63-octet DNS label break where nothing ` +
          `else can, while the shipped ${READY_URL.length}-char host keeps the exact rects it had (it clears its ` +
          `paragraph by ${rdMonoSlack === Infinity ? "n/a" : rdMonoSlack + "px"} either way). ASSERTED, NOT PINNED: ` +
          `the drag may not exceed ${READY_CRUEL_DRAG}px (${cruelPage} breach(es) this run) and NO box under ` +
          `#new-body may exceed its own client width — unconditional, with the four W26 measured pre-fix ` +
          `[${READY_PREFIX_BOXES.join(", ")}] kept only as a NAMED BASELINE, so a regressing member reads as the ` +
          `W26 defect returning on that box rather than as an anonymous stranger`,
        );
        okLine(
          `EVERY box under #new-body is measured against its OWN client width, never a pinned selector — the W25 ` +
          `finding on the sibling screen (.new-theater-grid 251/214) was invisible to the page number. Up to ` +
          `${skippedSeen} element(s) per cell are SKIPPED and counted: form controls (an <input> scrolls its value ` +
          `by design) and boxes declaring overflow-x auto|scroll. ${W26_WIDTHS[0]} is the DRIVEN width; ` +
          `${W26_WIDTHS.slice(1).join("/")} are SHOULDERS that can only catch a remedy breaking the wider phone layout`,
        );
      }
    }

    // ── W34-deploy-detail-render-bound ────────────────────────────────────────
    //
    // THE ONE CAPTION ON THE DEPLOY RAIL WITH NO RENDER BOUND. cch-w34-s5
    // widened `deployments.detail` from varchar(255) to :text, which left the
    // shared 2 KB `validate_console_line/1` as the only thing between a worker
    // token and the DOM. D251 rules the effective cap is min(validator, column,
    // every downstream derivation) — and every derivation after the store had
    // NONE: `FailureCopy.humanize/1`/`scrub/1` carry no length bound (grep for
    // String.slice / String.length / any @max in failure_copy.ex: nothing),
    // app.js emits `esc(d.detail)` whole, and `.deploy-detail` (app.css) was
    // font-size + colour + word-break + an animation, with no max-height, no
    // overflow and no line-clamp anywhere in the stylesheet.
    //
    // WHY A BROWSER AND NOT A SOURCE REGEX: the sibling `.status-pill-detail`
    // (app.css) proved the general lesson the hard way — its defect was TOKEN
    // SHAPE, and a length cap was the WRONG remedy. Here it is the opposite:
    // `.deploy-detail` already carries `word-break`, so a 2 KB caption does not
    // drag the page sideways at all. It grows DOWNWARD, and the only instrument
    // that can see that is one that measures painted boxes.
    //
    // THE BOUND IS IN LINE-BOXES, DERIVED, NEVER IN PIXELS. Every assertion
    // below divides the measured height by the element's OWN computed
    // line-height, so a type-scale change moves the pixels and not the verdict.
    //
    // FIVE INVARIANTS PER CELL, and three of them exist to catch a remedy
    // rather than the defect:
    //   (a) the CRUEL caption paints at most DETAIL_MAX_LINES line-boxes;
    //   (b) it is CLIPPED (scrollHeight > clientHeight) — proof the bound is
    //       actually engaging on this fixture rather than the caption having
    //       quietly stopped being long;
    //   (c) the clip is DISCLOSED — computed `-webkit-line-clamp` is a number,
    //       which is what makes the browser paint the ellipsis. A silent
    //       `max-height` + `overflow:hidden` reads as the whole caption and is
    //       refused here by name;
    //   (d) the KIND control — the longest caption the shipped builder actually
    //       emits — is NOT clipped at any width. A clamp tight enough to buy
    //       the cruel caption by shredding an ordinary one reds here;
    //   (e) the STORE is untouched: the DOM still carries all
    //       DEPLOY_DETAIL_STORE_CAP characters, so ops read the full capture in
    //       the row while the rail stays legible. The bound is on DISPLAY only.
    // Plus (f): `data-cap` must not carry a second copy of a long caption —
    // nothing in this tree reads it (`git grep data-cap` over app.css, app.js
    // and the tests: the only readers are the /new step caption's own tests),
    // so a 2 KB attribute beside a 2 KB text node is pure DOM weight.
    //
    // WIDTHS: the rail's column is the thing that decides how many lines 2,000
    // characters become, so the sweep runs the phone band and the desktop band.
    // Narrow is where the defect is worst (a ~250px column turns the caption
    // into ~90 lines) and wide is where a remedy is most likely to be too
    // tight.
    if (requested.includes("W34-deploy-detail-render-bound")) {
      const D = "W34-deploy-detail-render-bound";
      const DD_WIDTHS = [320, 390, 620, 900, 1024, 1440];
      const {
        SCENARIOS, DEPLOY_DETAIL_CRUEL, DEPLOY_DETAIL_KIND, DEPLOY_DETAIL_STORE_CAP,
        DEPLOY_DETAIL_BUILDER_MAX,
      } = await import("./scenarios.mjs");
      // THE NUMBER LIVES IN THE STYLESHEET, and this leg READS it rather than
      // restating it — two copies of a bound drift, and the copy in the
      // instrument always wins the argument while the copy in the product is
      // what a person sees. The CEILING below is this leg's own assertion: a
      // clamp looser than it is not a bound, it is a longer wall.
      const DETAIL_CLAMP_CEILING = 8;
      const ddRule = fs.readFileSync(path.join(ROOT, "app.css"), "utf8").match(/\n\.deploy-detail \{([\s\S]*?)\n\}/);
      if (!ddRule) {
        return die(`${D}: no \`.deploy-detail\` rule found in app.css — the selector this leg measures was renamed, and a run against the new name would have measured nothing`);
      }
      const ddClamp = ddRule[1].match(/-webkit-line-clamp:\s*(\d+)/);
      // ABSENT is the DEFECTIVE tree, and it must MEASURE rather than refuse:
      // a refusal here would report "I could not look" for the exact state this
      // leg exists to catch. It falls back to the ceiling so the pre-fix run
      // prints how far past a bound the caption actually paints.
      const DETAIL_MAX_LINES = ddClamp ? Number(ddClamp[1]) : DETAIL_CLAMP_CEILING;
      if (DETAIL_MAX_LINES > DETAIL_CLAMP_CEILING) {
        return die(`${D}: .deploy-detail declares -webkit-line-clamp: ${DETAIL_MAX_LINES}, looser than this leg's ceiling of ${DETAIL_CLAMP_CEILING}. A clamp that loose is not a bound — either the ceiling moves in this file with the measurement that justifies it, or the rule does`);
      }
      const sc = SCENARIOS["deploy-detail-cruel"];
      // The route is DERIVED from the fixture. A transcribed uuid rots into
      // "the sites list rendered instead" and the leg measures a screen that
      // has no deploy rail on it at all.
      if (!sc || !sc.deepLink || !sc.data || !Array.isArray(sc.data.deployments)) {
        return die(`${D}: SCENARIOS["deploy-detail-cruel"] no longer carries a deepLink and a deployments list — the deploy rail cannot be reached, so nothing was measured`);
      }
      // Both specimens must still be IN the fixture, and still be the lengths
      // that make this leg mean anything. A cruel caption that shrank under the
      // store cap makes (a)-(c) green by construction.
      const cruelRow = sc.data.deployments.find((d) => d.detail === DEPLOY_DETAIL_CRUEL);
      const kindRow = sc.data.deployments.find((d) => d.detail === DEPLOY_DETAIL_KIND);
      if (!cruelRow || !kindRow) {
        return die(`${D}: the fixture no longer carries BOTH an at-the-store-cap caption and an ordinary one — half of this leg would have measured nothing`);
      }
      if (DEPLOY_DETAIL_CRUEL.length !== DEPLOY_DETAIL_STORE_CAP) {
        return die(`${D}: the cruel caption is ${DEPLOY_DETAIL_CRUEL.length} chars against a store cap of ${DEPLOY_DETAIL_STORE_CAP} — it is no longer the longest thing the column can hold, and every number below would understate the defect`);
      }
      process.stdout.write(
        `\n${D} — deploy-detail-cruel x ${DD_WIDTHS.length} widths x 2 themes (${DD_WIDTHS.length * 2} cells; ` +
        `EVERY .deploy-detail on the page, each against its OWN computed line-height). Cruel caption ` +
        `${DEPLOY_DETAIL_CRUEL.length} chars (the store cap), KIND control ${DEPLOY_DETAIL_KIND.length} (the ` +
        `shipped builder's real caption over a 40-char SHA; its ADVERSARIAL ceiling over a varchar(255) ref is ` +
        `${DEPLOY_DETAIL_BUILDER_MAX} — reported, not pinned). lines= is measured height / line-height\n`,
      );
      let cells = 0, seen = 0, cruelSeen = 0, kindSeen = 0;
      let worstLines = 0, worstAt = "", kindWorstLines = 0, pageOver = 0;
      let capAttrWorst = 0;
      for (const theme of ["light", "dark"]) {
        // Enter WIDE — the deploy list mounts once, off the deployments fetch;
        // entering narrow would measure a layout the mount never saw.
        await setViewport(DD_WIDTHS[DD_WIDTHS.length - 1]);
        await nav(
          `${BASE}/?scen=deploy-detail-cruel&theme=${theme}${sc.deepLink}`,
          // READINESS KEYS ON `.deploy-row`, NOT ON THE CAPTION, and that is a
          // MEASUREMENT rather than a convenience: `.deploy-detail` carries
          // `animation: new-detail-in` whose first keyframe is `opacity: 0`, so
          // the rendered-host floor (checkOpacity: true) catches it mid-fade and
          // refuses a screen that is painting perfectly well. The row is the
          // caption's own parent, is not animated, and cannot exist without the
          // deployments fetch having landed. The caption's absence is caught
          // where it belongs — by this leg's own zero-box refusal below, which
          // says which screen was empty instead of blaming a stylesheet.
          `document.querySelector('.deploy-row') && (function(){var v=document.querySelector('section.view:not([hidden])');return v && v.id==='view-site';})()`,
        );
        const row = [];
        for (const width of DD_WIDTHS) {
          await setViewport(width);
          const m = await evalJs(
            `(function(){var d=document.documentElement;` +
            `var out={sw:d.scrollWidth,cw:d.clientWidth,boxes:[]};` +
            // EVERY caption on the page, never a pinned one: querySelector
            // singular cannot tell a rail that rendered nothing from a rail of
            // bounded captions.
            `[].slice.call(document.querySelectorAll('.deploy-detail')).forEach(function(e){` +
            `  var cs=getComputedStyle(e);var r=e.getBoundingClientRect();` +
            `  var lh=parseFloat(cs.lineHeight);` +
            `  if(!isFinite(lh)||lh<=0){lh=parseFloat(cs.fontSize)*1.2;}` +
            `  out.boxes.push({t:(e.textContent||''),len:(e.textContent||'').length,` +
            `    h:+r.height.toFixed(2),lh:+lh.toFixed(2),lines:+(r.height/lh).toFixed(2),` +
            `    sh:e.scrollHeight,ch:e.clientHeight,clamp:cs.webkitLineClamp||cs.getPropertyValue('-webkit-line-clamp')||'none',` +
            `    ov:cs.overflow,cap:(e.getAttribute('data-cap')||'').length});` +
            `});return out;})()`,
          );
          cells++;
          if (m.sw > m.cw) {
            pageOver++;
            fail(D, `${theme}@${width}: documentElement.scrollWidth ${m.sw} > clientWidth ${m.cw} — the page drags sideways`);
          }
          // A rail with no captions on it is not a clean rail, it is an
          // unmeasured one.
          if (!m.boxes.length) {
            fail(D, `${theme}@${width}: ZERO .deploy-detail elements on the page — the rail rendered nothing and this cell certified an empty screen`);
            continue;
          }
          let cruel = null, kind = null;
          for (const b of m.boxes) {
            seen++;
            if (b.t === DEPLOY_DETAIL_CRUEL) { cruel = b; cruelSeen++; }
            else if (b.t === DEPLOY_DETAIL_KIND) { kind = b; kindSeen++; }
          }
          if (!cruel || !kind) {
            fail(D, `${theme}@${width}: the paint carries ${cruel ? "" : "no cruel caption"}${!cruel && !kind ? " and " : ""}${kind ? "" : "no kind control"} — ${m.boxes.length} .deploy-detail box(es) rendered, none of them the specimen this leg exists to measure`);
            continue;
          }
          // (a) BOUNDED.
          if (cruel.lines > DETAIL_MAX_LINES + 0.1) {
            fail(D, `${theme}@${width}: the ${DEPLOY_DETAIL_STORE_CAP}-char caption paints ${cruel.lines} line-boxes (${cruel.h}px at line-height ${cruel.lh}) — the bound is ${DETAIL_MAX_LINES}. The status pill's row is ${(cruel.h - DETAIL_MAX_LINES * cruel.lh).toFixed(2)}px taller than a legible rail allows`);
          }
          // (b) THE BOUND IS ENGAGING.
          if (cruel.sh <= cruel.ch) {
            fail(D, `${theme}@${width}: the cruel caption is NOT clipped (scrollHeight ${cruel.sh} <= clientHeight ${cruel.ch}) — ${DEPLOY_DETAIL_STORE_CAP} characters fit inside the bound, so this cell proves nothing about a bound`);
          }
          // (c) THE CUT IS DISCLOSED.
          if (!/^\d+$/.test(String(cruel.clamp).trim())) {
            fail(D, `${theme}@${width}: computed -webkit-line-clamp is "${cruel.clamp}" — there is NO disclosed cut. ${cruel.len} characters are in the DOM; whatever the box shows, its last visible line ends mid-sentence with nothing saying more follows. A bare max-height + overflow:hidden bounds the same pixels and reads as the whole caption. Clamp it, or offer an explicit expand`);
          }
          // (d) THE KIND CONTROL SURVIVES.
          if (kind.sh > kind.ch) {
            fail(D, `${theme}@${width}: the ORDINARY builder caption ("${DEPLOY_DETAIL_KIND}", ${DEPLOY_DETAIL_KIND.length} chars) is clipped too — scrollHeight ${kind.sh} > clientHeight ${kind.ch} at ${kind.lines} line-boxes. The bound bought the cruel caption by shredding the one a person reads every day`);
          }
          // (e) THE STORE IS UNTOUCHED.
          if (cruel.len !== DEPLOY_DETAIL_STORE_CAP) {
            fail(D, `${theme}@${width}: the DOM carries ${cruel.len} of ${DEPLOY_DETAIL_STORE_CAP} characters — the remedy CUT THE CAPTION instead of bounding its box, and ops can no longer read the capture the store holds`);
          }
          // (f) NO SECOND COPY IN AN ATTRIBUTE NOBODY READS.
          if (cruel.cap >= DEPLOY_DETAIL_STORE_CAP) {
            fail(D, `${theme}@${width}: data-cap carries ${cruel.cap} characters beside a ${cruel.len}-character text node — the caption is in the DOM twice and nothing in this tree reads the attribute`);
          }
          worstLines = Math.max(worstLines, cruel.lines);
          if (worstLines === cruel.lines) worstAt = `${theme}@${width}`;
          kindWorstLines = Math.max(kindWorstLines, kind.lines);
          capAttrWorst = Math.max(capAttrWorst, cruel.cap);
          row.push(`${width}:cruel ${cruel.lines}L ${cruel.h}px sh${cruel.sh}/ch${cruel.ch} clamp=${cruel.clamp} cap=${cruel.cap} | kind ${kind.lines}L sh${kind.sh}/ch${kind.ch}`);
        }
        process.stdout.write(`   deploy-detail/${theme}  ${row.join("  ")}\n`);
      }

      if (!failures.some((f) => f.defect === D)) {
        okLine(
          `${cells} / ${cells} cells clean across ${DD_WIDTHS.join("/")} in both themes — ${cruelSeen} cruel and ` +
          `${kindSeen} kind captions measured out of ${seen} .deploy-detail boxes, ${pageOver} page(s) dragging. ` +
          `The ${DEPLOY_DETAIL_STORE_CAP}-char caption paints at most ${worstLines} line-boxes (worst: ${worstAt}) ` +
          `against a bound of ${DETAIL_MAX_LINES}, and is CLIPPED in every cell — the bound is engaging, not ` +
          `decorative`,
        );
        okLine(
          `THE CUT IS VISIBLE AND THE STORE IS WHOLE: computed -webkit-line-clamp is a number in every cell (which ` +
          `is what paints the ellipsis — a bare max-height + overflow:hidden reads as the whole caption and is ` +
          `refused by name here), while the DOM still carries all ${DEPLOY_DETAIL_STORE_CAP} characters. The bound ` +
          `is on DISPLAY only: no server file is in this leg's diff and nothing truncates what ops read in the row`,
        );
        okLine(
          `THE KIND CONTROL IS WHY THE BOUND IS ${DETAIL_MAX_LINES} AND NOT 2: the longest caption the shipped ` +
          `builder emits ("Starting your build (<sha>)…", ${DEPLOY_DETAIL_KIND.length} chars) reaches ` +
          `${kindWorstLines} line-boxes at ${DD_WIDTHS[0]} and is UNCLIPPED in all ${cells} cells. Its adversarial ` +
          `ceiling over a varchar(255) git_ref is ${DEPLOY_DETAIL_BUILDER_MAX} chars — reported so a future tightening ` +
          `is a decision somebody makes rather than one they discover, and deliberately NOT pinned, because the ` +
          `wrap boundary is a property of the STRING and not of the CSS`,
        );
        okLine(
          `data-cap carries at most ${capAttrWorst} characters beside the ${DEPLOY_DETAIL_STORE_CAP}-char caption. ` +
          `It is asserted rather than deleted because the attribute is the only thing distinguishing the two ` +
          `caption branches in a screenshot — but nothing in this tree READS it (its only readers are the /new step ` +
          `caption's own tests), so a second full copy of the caption in the DOM was pure weight`,
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
  // AUDITED (exit 2): an unhandled crash measured NOTHING — by this guard's own
  // doctrine (every die() path, and the inner measurement catch: "an incomplete
  // run must never be reported as a measured overflow") that is a REFUSAL, not
  // a finding. Exit 1 here made the console-harness wrapper print the
  // MEASURED_DEFECT banner ("a measured geometry defect in a real browser",
  // with selector/number guidance) for a run that never measured a screen.
  // Sibling breakpoint-sweep.mjs maps this identical unhandled shape to 2.
  process.stderr.write(`!! OVERFLOW GUARD crashed (exit 2 — nothing was measured): ${err && err.stack ? err.stack : err}\n`);
  process.exit(2);
});
