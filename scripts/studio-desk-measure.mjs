#!/usr/bin/env node
//
// studio-desk-measure.mjs — THE INSTRUMENT.
//
// Measures the DEPLOYED Studio desk in a real authenticated browser and prints a
// nine-width x three-FORCED-face matrix. It is the cure for this epic's chronic
// disease: six times a hand-driven, one-shot measurement was recorded as English
// by an agent who then evaporated, and six times a later verifier overturned it
// (charter D35/D36/D38/D40/D72/D75).
//
// CONTRACT — the only one it claims: **it prints a matrix, or it exits non-zero
// naming the thing that failed.** It is NOT a CI gate. It has no pass/fail
// opinion about the numbers. A rotted run is VISIBLY rotted rather than
// silently wrong (charter D81).
//
//   node scripts/studio-desk-measure.mjs            # human table + JSON matrix
//   node scripts/studio-desk-measure.mjs --json     # JSON matrix only
//   node scripts/studio-desk-measure.mjs --doc=<slug>   # measure a NAMED document
//   node scripts/studio-desk-measure.mjs --doc=any      # first row that opens
//   node scripts/studio-desk-measure.mjs --out <path>   # ALSO save the run JSON
//   node scripts/studio-desk-measure.mjs --sha=<sha>    # REFUSE unless the box serves it
//   node scripts/studio-desk-measure.mjs --help
//
// (`BP_DESK_DOC` is the env form of `--doc`. With neither, the drill resolves
//  the NEWEST paper in the pane it just opened and records which one — there is
//  no committed slug to age off; see `resolveDocTarget` below.
//  `BP_DESK_SHA` is the env form of `--sha`/`--ref`. Unpinned by default: a run
//  without it measures whatever guerrilla serves and records it in served_sha.)
//
// A run that is not written to disk survives only as terminal scrollback, and
// this epic has already lost one 54-row sweep that way (D131) — it exists now
// only as prose in a closed task, with one cell blank at byte level. `--out`
// writes the complete run, and committed runs live in `scripts/measurements/`.
//
// ── The designed-in impossibilities ──────────────────────────────────────────
// Each one makes a specific historical overturn structurally unreachable:
//
//   1. SELECTOR MATCH COUNT > 0 IS ASSERTED BEFORE ANY NUMBER IS TRUSTED, and
//      the counts are printed in every record. A vacuous pass — measuring an
//      element that is not there and reporting a confident 0 — is how D31 and
//      D39 happened. `assertSelectors()` throws with the selector's own name.
//
//   2. THE GUTTER IS READ, NEVER COMPUTED (D72/D78). `.bp-paper-surface`'s
//      padding is viewport-@media'd — 56/40, then 48/24 below 767px, then
//      32/16 below 479px — so the hardcoded `element_width - 80` that produced
//      D58's withdrawn "510px = 50.96ch at viewport 640" is wrong in exactly
//      the rows this matrix exists to interrogate. We read
//      getComputedStyle(surface).paddingLeft/paddingRight and print it.
//
//   3. ch IS CONVERTED BY A PROBE SPAN inserted as a CHILD of
//      `.bp-paper-surface`, styled `width: 1ch` (D31/D38/D83) — never by
//      dividing by the chrome font's advance, which is what produced the
//      disproven 67.6ch. The browser's own in-floor `ch` (derived from the
//      resolved `calc(55ch + 80px)`) is printed ALONGSIDE it rather than one
//      being silently chosen; they differ by ~0.107% on the native face and
//      that is enough to move 64.0ch to 63.95ch.
//
//   4. HORIZONTAL OVERFLOW IS TESTED AGAINST `.editor-body.bp-paper-body`'s
//      scrollWidth vs clientWidth (D39's real scroller) — never `.editor-panel`
//      (whose `overflow: hidden` is never reached) and never `body`.
//
// ── Two more, learned this wave ──────────────────────────────────────────────
//
//   5. THE FLOOR-BIND TEST IS AN EXPERIMENT, NOT AN INFERENCE. Rather than
//      comparing the resolved `min-inline-size` against the measured width and
//      guessing, we measure the surface, then set `min-inline-size: 0px` inline,
//      re-measure, and restore. If the width moved, the floor BOUND. There is
//      no arithmetic to get wrong. (D75 says it never binds; this either
//      confirms that per face or refutes it.)
//
//   6. EACH FACE IS ACTUALLY FORCED AND THE WHOLE BOX RE-MEASURED UNDER IT
//      (D75). We never divide one face's box by another face's advance — a
//      verifier who did exactly that reported "1280px fails at 53.95ch Georgia"
//      and it would have been overturn #7. Bare `serif`/`ui-serif` is BANNED as
//      a probe face (D49): it measures narrower than both real faces and
//      INFLATES ch, masking the very bug D39 exists to catch.
//
// ── Three more, learned when this instrument became the seal's SPOF (D97) ────
//
//   7. THE DRILL NAMES ITS DOCUMENT, so a failed run is an INSTRUMENT failure
//      and never a desk fact. It used to click the FIRST `[phx-click="select"]`
//      row in a Papers list that concurrent epic waves rewrite live — 104 rows,
//      newest first, and the newest row changed between two runs. Three
//      independent verifiers hit a 30s `waitForSelector('.bp-paper-surface')`
//      timeout that later passed on the same served SHA. A wave that reads that
//      timeout as a desk fact records a NON-measurement as a measurement, which
//      is this epic's exact disease. Now: `--doc=<slug>` (env `BP_DESK_DOC`)
//      with a committed default targets `[phx-value-id="<slug>"]` directly, the
//      click+wait is retried, and the landed URL is asserted to carry that very
//      slug. `--doc=any` restores the old first-row behaviour but SKIPS rows
//      that yield no paper surface instead of failing on them. Every failure on
//      this path is worded as an instrument failure and lists what it saw.
//
//   8. PROVENANCE IS BRACKETED, NOT STAMPED ONCE. `readProvenance()` used to run
//      once, before the browser launched, and that single snapshot went into all
//      54 records. Caught in the act: a bracketed sweep ran 59.7s and observed
//      `barkpark-slot@green` entering at 00:45:38Z INSIDE the 00:44:51–00:45:50
//      window (blue-only -> blue+green -> green-only across three reads, SHA
//      constant). A same-SHA rotation is benign; a MERGE landing mid-window is
//      equally invisible and would silently misattribute every later row to a
//      commit that no longer matched what was served. Now the SHA and slot are
//      re-read AFTER the sweep, `compareProvenance()` diffs them, and any
//      difference FAILS THE RUN LOUDLY. Every row also carries its own
//      `measured_at`, so a rotation can be located in time rather than inferred.
//
//   9. THE VISIBLE VERDICT IS AUTHORED. `visible_content_px` was measured but
//      the table's `ok?` column was, by its own legend, "the LAYOUT measure
//      against >=55ch — not a verdict on the visible measure", so the number the
//      seal turns on had no verdict at all. Now every record carries
//      `content_ch` / `content_meets_55ch` AND `visible_ch` /
//      `visible_meets_55ch`, and the table prints `lay?` and `vis?` side by
//      side. Both ratios are computed IN-PAGE, in the same face-forced scope
//      that produced the box and the probe, so a cross-face division (D83/D86,
//      overturn #7 averted) is structurally unreachable rather than merely
//      discouraged.
//
// ── Sweep direction ──────────────────────────────────────────────────────────
// DESCENDING, always (D80). `bucket(w, held)` applies its +32px dead-band on
// the WIDEN side only and re-anchors to the bucket currently held, so an
// ASCENDING sweep stamps viewport 640 as `phone`, 1024 as `narrow` and 1280 as
// `standard` — three of these nine widths, and at `phone` the pane columns are
// `display: none` and every floor is neutralised, i.e. a completely different
// layout. Both inspector states sweep descending, and NEITHER reloads mid-sweep:
// the `user-opened` marker is a server assign that a reload would reset, so a
// fresh-nav-per-row shortcut is a DIFFERENT protocol, not an upgrade (D110).
//
// ── Three more, learned when the epic nearly sealed on the wrong table ───────
//
//  10. THE SECOND AXIS IS THE INSPECTOR'S STATE, NOT THE NAVIGATION PATH
//      (D110). This harness used to sweep `entry_state ∈ {drilled, cold-load}`
//      — how the user ARRIVED. That axis was measured twice, at nine widths and
//      three faces, and agreed in 54 of 54 cells across both runs: 27 rows per
//      run re-proving that arrival does not matter, and ZERO rows on the axis
//      that moves the answer by 219px. Meanwhile a grep of this file for any
//      click on the inspector toggle returned nothing — the "two states" were
//      never open vs closed. So: `inspector_state ∈ {default, user-opened}`.
//      `default` is as served. `user-opened` is after a REAL click on
//      `[data-test-id="sidebar-toggle-panel"]` through the live LiveView
//      socket, because the marker the CSS yields to (`data-user-opened`) is
//      SERVER-stamped from the `sidebar_user_opened` assign — a JS-set
//      attribute would prove only that the stylesheet works, which was never
//      in doubt. A click that does not take is an INSTRUMENT failure and the
//      run dies; it is never recorded as a desk fact.
//
//      Two clicks are needed at the top of the sweep and that is not a hack.
//      `sidebar_toggle_panel/1` resolves a click against `width_bucket`: at
//      `wide` (>=1280) the panel is genuinely open, so one click CLOSES it and
//      a second re-opens it — and the re-open is the one that sets
//      `sidebar_user_opened: true`. Below `wide` the panel is painted closed
//      while the assign still says open, and the handler's `painted_closed?`
//      branch makes a single click mean OPEN. The sweep must start at 1440
//      (descending, D80), so it pays the two-click price once and then holds
//      the marker for every row after it — no reload, because a reload builds
//      a new socket and `sidebar_user_opened` seeds back to false.
//
//  11. OCCLUSION IS ATTRIBUTED BY DIFF, NEVER BY A HAND-MAINTAINED LIST
//      (D112). The old test was one line — `iCs.position === 'absolute' ||
//      'fixed'` — with exactly ONE element in its universe. It was honest the
//      day it was written and structurally unable to stay honest: any overlay
//      nobody had thought of yet was invisible to it. It is replaced by a
//      hit-test, and its number is still printed as
//      `legacy_inspector_subtraction_px` so no history is erased.
//
//      THE TRAP, proven live before this was written:
//      `document.elementsFromPoint` structurally skips `pointer-events: none`
//      AND never returns a pseudo-element. The scrim is BOTH
//      (`.editor-with-preview:has(.bp-doc-sidebar.is-open)::after`,
//      `pointer-events: none` deliberately — a click-catching scrim would
//      swallow edits). So with the scrim painted over them, the leftmost
//      samples return the IDENTICAL topmost element they return when no scrim
//      exists at all. Every row is therefore sampled TWICE: once naturally,
//      once with `pointer-events: auto` forced on the scrim via an INJECTED
//      STYLESHEET (a pseudo has no inline style — a real deviation from this
//      file's two existing inline-style mutate-measure-restore uses), and the
//      scrim's footprint is the DIFF between the two.
//
//      Geometric occlusion is an ANCESTRY test, not a name match: at each
//      sample point, is the topmost element the surface or a descendant of it?
//      Anything else is covering the reader, whatever it is called — a modal
//      backdrop, a sticky bar, an overlay nobody has written yet. That is what
//      this design buys, and it is why matching against a known list is
//      refused: `main.bp-paper-surface` is already topmost at one sampled point
//      with no scrim at all, so a list would have to encode exceptions to its
//      own exceptions.
//
//      A NON-VACUITY GUARD IS MANDATORY (D31/D39). An injected rule whose
//      selector drifts out of sync with root.html.heex is a SILENT no-op, and a
//      vacuous pass here would falsify the seal itself. So: in any row where
//      the scrim actually renders, the forced sample MUST differ from the
//      natural one, and a row where it does not kills the run naming the
//      selector.
//
//  12. THE SCRIM DIMS, IT DOES NOT HIDE (D111). When it renders it covers the
//      ENTIRE content box at 55% black. Folding that into `visible_content_px`
//      makes the visible measure 0px at every sub-wide user-opened width, so no
//      seal is ever possible there and the metric can no longer rank an
//      improvement against a regression. Folding it into nothing is the epic's
//      own chronic disease in a new costume. So `visible_content_px` answers
//      one question only — CAN THE READER SEE THE GLYPH AT ALL — and the scrim
//      is reported beside it as `dimmed_content_px` + `scrim_alpha`, named in
//      every row it renders and never summed into the headline. Silence about
//      it is what is forbidden; neither arithmetic alone is.
//
// ── Settling ────────────────────────────────────────────────────────────────
// The width bucket is stamped into `html[data-width-bucket]` pre-paint by an
// inline script, but the SERVER's `width_bucket` assign only arrives after the
// LiveView socket connects and the hook pushes it — and the pane set and the
// phone breadcrumb are both server-rendered from that assign. Measuring before
// that lands reads a transient. `waitForDeskSettled()` waits for the socket,
// then for a structural signature (pane count + widths + crumbs + bucket) to
// hold still, and every row records whether it settled and how long it took. A
// row that never settled says so instead of quietly reporting the transient.
//
// ── Provenance ───────────────────────────────────────────────────────────────
// Every record carries the served SHA (read live over ssh) and the live slot
// (QUERIED — D71 struck the charter's recorded colour twice; the wish that
// spawned this run said "only GREEN exists" and the live read says blue).
// Also: resolved font family per face, selector match counts, sweep direction,
// scrollbar width, and the landed authenticated URL.
//
// ── Reliability — D138 CHARACTERISED (N=22, 2026-09-06) ─────────────────────
//
// D138 said "the instrument is ~80% deterministic and nobody knows why" and
// named two undiagnosed failures. This is the measurement that replaces the
// guess, and the three rulings that follow from it.
//
// THE SWEEP. 22 consecutive invocations against deployed guerrilla, each with
// --retries=0 so the numbers are RAW per-invocation rates rather than the
// retried ones, stderr captured on every single invocation, all on bundled
// Chromium 147.0.7727.15, all drilling one named document. The classification:
//
//     outcome                     count      note
//     completed, 54 rows          19 of 22
//     abort: provenance-bracket    2 of 22   a deploy landed under the sweep
//     abort: browser-race          1 of 22   execution context destroyed
//
// ALL THREE ABORTS FELL INSIDE ONE 6m44s WINDOW, 07:11:11Z-07:17:55Z, during
// which the served SHA moved a99e366f2 -> 0a3886ac6 and the live slot rotated
// blue -> green. Outside that window: 19 of 19 clean. The instrument is not
// ~80% deterministic. It is deterministic, and it fails while the thing it
// measures is being replaced underneath it — which is the correct behaviour and
// exactly what the provenance bracket exists to force.
//
// REPRODUCTION. Within a served SHA, all 54 rows reproduce field for field at
// tolerance zero in 19 of 19 completed runs (scripts/studio-desk-compare.mjs,
// mechanical, keyed, zero tolerance). ACROSS the SHA boundary the only per-row
// fields that differ are `served_sha` and `slot_active` — the provenance
// stamps. Not one geometry field moved across two deployed builds and both
// slots.
//
// ── RULING 1 — a substituted face withdraws its row's verdicts ───────────────
//
// RATE. Zero substitutions in 684 forced-face rows across the 19 completed runs
// (36 forced rows per run: two overridden faces x nine widths x two states).
// With D138's own prior observation that is ONE substitution in ~30 completed
// runs. The honest form is a proportion of runs, and it is small.
//
// REACHABILITY INTO D107's SEVEN — PROVEN POSSIBLE, and not by waiting for it.
// A sweep that never sees the flake proves nothing about where it can land, and
// one that happens to see it at 1280 would settle the question by luck. It is
// settled by reading the path: the face is forced and resolved by one stretch
// of PAGE_MEASURE that reads no viewport quantity at all — no innerWidth, no
// matchMedia, no bucket — and `face_applied` is `winner === wantedFamilies[0]`
// with no width term. Same code, same inputs, at every one of the nine widths.
// A substitution possible at 640 is possible at 1280. Both facts are pinned in
// scripts/studio-desk-instrument-reliability.test.mjs.
//
// SO: rare, and able to land on a ruling cell. A run with `face_applied:false`
// in a forced row does NOT fail — the row does. Its 55ch verdicts go to NULL
// (never FALSE: FALSE would say "this desk fails 55ch on Georgia" when Georgia
// was never on screen), its px measurements stand, and the run carries
// `face_override_integrity`. Killing 53 good rows to withdraw one would produce
// the zero-byte run D138 forbids. A CONSUMER that wants a gate passes
// --fail-on-face-substitution, which exits 2 AFTER the artifact is written; the
// instrument itself keeps no gate authority (D81).
//
// ── RULING 2 — bounded retries belong IN the instrument, on a NAMED list ─────
//
// Yes, and the list matters more than the bound. The wave-9 brief authorised
// retries on ONE abort, so an operator who met any other had to deviate to do
// the obviously right thing. RETRYABLE_ABORTS is the list — six entries, five
// with throw sites in this file and one (`browser-race`) classified at the
// retry layer because playwright raises it, not us. --retries=N defaults to 2.
// Every failed attempt's stderr is printed IN FULL before the next attempt
// starts: failure B went seven weeks undiagnosed for exactly one reason, that
// its stderr was suppressed, and a retry loop that swallowed what it retried
// would rebuild that hole where nobody would think to look.
//
// ── RULING 3 — the browser is provenance ────────────────────────────────────
//
// BP_DESK_BROWSER, defaulting to the bundled Chromium; a missing browser fails
// by name with `npx playwright install chromium`; every run records
// browser_policy / browser_channel / browser_version. See the block above
// resolvePlaywright().
//
// ── WHAT D138 GOT WRONG, on the evidence ────────────────────────────────────
//
//  - "failure C ... The list had rendered only four rows at drill time — a
//    PARTIALLY-LOADED Papers list, not a missing document." Not a partial list.
//    Those four strings are document TYPES: the drill was reading the ROOT
//    pane, because `openPapersPane` waited for QUIESCENCE (800ms of stillness)
//    after clicking, and the pre-click desk is already still. The Papers pane
//    renders exactly 100 rows. Fixed by the edge-triggered `waitForNewPane`,
//    pinned by studio-desk-drill-pane.test.mjs, and 0 of 22 invocations in this
//    sweep aborted in the drill.
//  - "failure B, UNDIAGNOSED." Diagnosed. It is playwright's `Execution context
//    was destroyed` under a blue/green rotation — see isRetryableBrowserRace().
//  - "~80% deterministic." 19 of 22 raw, 19 of 19 outside a deploy window, with
//    every completed run reproducing at tolerance zero.
//
// CLOSED SINCE (#16355), and it was this file's to fix after all: the committed
// DEFAULT_DOC had aged off the Papers pane's newest-100 window, so the no-flag
// invocation aborted 1 of 1 with a correctly-worded drill error naming a slug the
// reader had no way to replace. Every run above therefore passed --doc
// explicitly. There is now no committed slug: the default RESOLVES the newest
// row of the Papers pane the drill has already proven it entered, and the run
// records `measured_doc` + `measured_doc_source`. See `resolveDocTarget`.
//
// ── Playwright resolution ────────────────────────────────────────────────────
// playwright 1.59.1 + chromium-1217 are cached, but they live in the JS
// monorepo's node_modules, and this script sits in scripts/ — and is routinely
// run from a git WORKTREE, which has no node_modules of its own. So we do not
// assume: `resolvePlaywright()` tries a candidate list (env override, this
// script's own tree, then the MAIN checkout derived from `git rev-parse
// --git-common-dir`, which is how a worktree finds the primary clone) and fails
// loudly with every path it tried. No tiny package.json beside the script,
// because that would need its own install to stay true.
//
// Node 22. No dependencies beyond playwright.

import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const JSON_ONLY = process.argv.includes('--json');
/** The round trip runs by default — it is the fidelity question this wave was
 *  filed about — but it is a second pass over every width, so it is opt-OUT
 *  rather than opt-in-and-forgotten. */
const ROUND_TRIP = !process.argv.includes('--no-round-trip');
/** Opt-IN, because it deliberately mutates the page into a state the desk does
 *  not serve. Its row is tagged `positive_control: true` and is NEVER pushed
 *  into `run.rows` — a synthetic row in the matrix would be a fabricated desk
 *  fact, which is the one thing this instrument exists to make impossible. */
const POSITIVE_CONTROL = process.argv.includes('--positive-control');

/** Absolute path, with every symlink on it collapsed. `fs.realpathSync` throws
 *  on a path that does not exist, which is a legitimate state for `argv[1]`
 *  (`node --eval`, a REPL), so it falls back to plain resolution rather than
 *  taking the process down. See the entrypoint guard at the bottom for WHY
 *  this exists — it is the whole of D130. */
function realResolve(p) {
  const abs = path.resolve(p);
  try {
    return fs.realpathSync(abs);
  } catch {
    return abs;
  }
}

/** `--out <path>` / `--out=<path>` — where to write the complete run JSON.
 *  Returns null when the flag is absent (stdout stays the only output, which is
 *  how the instrument behaved for its first two waves — see D131). */
function resolveOutPath(argv = process.argv.slice(2)) {
  const eq = argv.find((a) => a.startsWith('--out='));
  let raw = eq ? eq.slice('--out='.length) : null;
  if (raw === null) {
    const i = argv.indexOf('--out');
    if (i === -1) return null;
    if (i === argv.length - 1) {
      die('--out was the last argument, with no path after it. ' +
          'Pass the file to write: --out scripts/measurements/<name>.json');
    }
    raw = argv[i + 1];
    if (raw.startsWith('-')) {
      die(`--out was followed by \`${raw}\`, which is another flag, not a path. ` +
          `Pass the file to write: --out scripts/measurements/<name>.json`);
    }
  }
  raw = raw.trim();
  if (!raw) die('--out was passed with an empty value — name the file to write the run JSON to');
  return path.resolve(process.cwd(), raw);
}

/** Resolved at the ENTRYPOINT, not here, for two reasons that both bit:
 *
 *  1. `die` is a `const` declared ~80 lines below this point. Calling
 *     `resolveOutPath()` at module scope put every one of its error paths in
 *     `die`'s temporal dead zone, so a malformed `--out` produced a raw
 *     `ReferenceError: Cannot access 'die' before initialization` stack trace
 *     instead of the named, one-line failure it carefully composed. That is the
 *     same class of defect as D130 — the instrument failing in a shape nobody
 *     can read — reintroduced by the fix for it.
 *  2. Parsing `process.argv` at module scope couples IMPORT to the importer's
 *     command line. This file is deliberately importable (the provenance-compare
 *     path has no browser in it); an importer whose own argv happened to carry a
 *     bad `--out` would have died on `import`.
 *
 *  Resolution still happens BEFORE `main()`, so a bad path is rejected in
 *  milliseconds rather than after a ~30-60s authenticated sweep (D115). */
let OUT_PATH = null;

/** The requested revision, parsed at the ENTRYPOINT for both of `OUT_PATH`'s
 *  reasons above: `parseShaPin` calls `die`, and parsing argv at module scope
 *  would couple IMPORT of this file to the importer's command line. */
let SHA_PIN = null;

/** Function, not a const string: it interpolates DEFAULT_DOC, which is declared
 *  below this point and would be in its temporal dead zone at module init. */
function usage() {
  return `
studio-desk-measure.mjs — THE INSTRUMENT (charter D81: no gate authority).

  Measures the DEPLOYED Studio desk in a real authenticated browser and prints a
  matrix of ${WIDTHS.length} widths x ${FACES.length} forced faces x the inspector states that
  APPLY at each width. The row count is COMPUTED, never compiled in: a complete
  run is ${expectedRowCount()} rows when every state is reachable, and the run states its own
  expected count in the artifact and proves it hit it (D121's doctrine, without
  D121's literal — which rotted the moment a third state existed).

  INSPECTOR STATES
${STATES.map((s) => `    ${s.id.padEnd(13)} ${s.has_reading_column ? 'has a reading column' : 'NO reading column — ch is NULL, verdicts render "?"'}
                  applies at ${WIDTHS.filter((w) => s.applies_at(w)).join(', ')}px`).join('\n')}

USAGE
  node scripts/studio-desk-measure.mjs [options]

OPTIONS
  --json              JSON matrix only — suppress the human table on stdout.
  --doc=<slug>        Measure a NAMED document.
  --doc=newest        THE DEFAULT. Measure the newest row of the Papers pane,
                      resolved at run time from the list the drill just opened
                      — never from a committed slug, which ages off the
                      newest-100 window and turns a bare run into an abort
                      (#16355). The run records measured_doc and
                      measured_doc_source; an EMPTY pane REFUSES by name
                      rather than falling back to the root pane.
  --doc=any           Drill the first Papers row that opens a paper surface.
  --out <path>        Write the COMPLETE run JSON (all rows + run-level
                      provenance) to <path>, creating parent directories.
                      Committed runs live in scripts/measurements/. Without
                      this the table exists only as terminal scrollback (D131).
  --sha=<sha>         PIN the run to a deployed revision. Before anything is
  --ref=<sha>         measured, the SHA the box actually serves is read over
                      ssh and compared; a mismatch REFUSES — non-zero, naming
                      both SHAs — with zero rows emitted and nothing written.
                      Abbreviated SHAs match by prefix. Without this a run
                      measures whatever guerrilla serves right now and says so
                      only afterwards, in served_sha (charter D73). \`--sha\`
                      does not deploy, serve or check out anything: it only
                      refuses to measure a build you did not ask for.
  --no-round-trip     Skip the round-trip pass (default -> open -> dismiss on
                      the SAME page instance, asserting the reading column comes
                      back bit-identical per width and face). It costs a second
                      pass over every width; skip it when you only want the
                      matrix.
  --positive-control  Take one extra row with a synthetic scrim FORCED to
                      render, so the non-vacuity guard is seen to FIRE in the
                      same run. Without it, "no scrim because the desk was
                      fixed" and "the guard never ran" produce an identical zero.
  --retries=N         Bounded retries on the NAMED retryable aborts only
                      (default 2, so up to three attempts; 0 disables).
                      Retryable: ${RETRYABLE_ABORTS.map((a) => a.id).join(', ')}.
                      Every failed attempt's stderr is printed IN FULL before
                      the next attempt starts. A terminal failure is never
                      retried at any N.
  --fail-on-face-substitution
                      Exit 2 if any forced-face row measured a different face
                      (D138 failure A). The artifact is still written and those
                      rows' 55ch verdicts are already NULL — this only turns the
                      finding into a non-zero exit for a caller that wants a
                      gate. The instrument itself has no gate authority (D81).
  -h, --help          This text.

BROWSER (provenance, not a detail — \`ch\` is a font measurement)
  Policy: \`${browserPolicy().id}\` (${browserPolicy().source}) — ${browserPolicy().what}.
${Object.entries(BROWSER_POLICIES).map(([id, p]) =>
  `    BP_DESK_BROWSER=${id.padEnd(8)} ${p.what}\n      if missing: ${p.fix}`).join('\n')}
  A missing browser fails by NAME with the install command above, never as a raw
  \`browserType.launch: Executable doesn't exist\` trace — that read as an
  instrument bug to every wave-11 verifier, and the ones who worked around it by
  forcing system Chrome measured on a different browser than the committed
  artifacts, with nothing in either artifact saying so. Every run now records
  \`browser_policy\`, \`browser_channel\` and \`browser_version\`.

ENVIRONMENT
  BP_DESK_BROWSER     bundled (default) | chrome — see BROWSER above.
  BP_DESK_RETRIES     Env form of --retries.
  BP_DESK_SHA         Env form of --sha/--ref.
  BP_DESK_DOC         Env form of --doc. Empty or unset means the default,
                      \`newest\`; the flag wins over it.
                      (BP_DESK_DESTINATION_CONTROL is GONE. It pointed at a
                      control that summons the Tier-3 destination; no such
                      control has ever existed, because the destination is
                      ENTAILED by the server predicate rather than summoned.
                      Rows now carry a derived \`is_destination\`, read from the
                      server's own [data-inspector-destination] marker.)

NOTES
  A full authenticated sweep takes ~30-60s observed (D115) — NOT the ~10 minutes
  older comments claimed. It needs deployed guerrilla, ssh to the box for the
  provenance bracket, and the guerrilla admin token in ~/.config/barkpark.
`;
}

/** `--doc=any` re-enables the old first-row drill, but skipping rows that do not
 *  open a paper surface rather than dying on the first one that does not. */
const ANY_DOC = 'any';

/** `--doc=newest` — THE DEFAULT, and a MODE rather than a slug. */
const NEWEST_DOC = 'newest';

/**
 * THERE IS NO COMMITTED DEFAULT SLUG, AND ITS ABSENCE IS THIS BLOCK (#16355).
 *
 * WHAT WAS HERE. `DEFAULT_DOC = 'studio-space-priority-desk-browser-2026-07-19'`
 * — one of this epic's own sealed wave Papers, chosen under D97 because a NAMED
 * target cannot be moved under the drill by a concurrent wave the way "the first
 * row" can. That reasoning was right about determinism and wrong about time. The
 * Papers pane is a newest-first window of ~100 rows and this epic's own waves
 * publish into it continuously, so a fixed slug does not stay reachable: it aged
 * out, and a bare `node scripts/studio-desk-measure.mjs --json` then aborted
 * 1 of 1 — not a flake, a standing outage — with a correctly-worded drill error
 * naming a slug the reader had no way to replace. Every run of the N=22
 * characterisation above had to pass `--doc` explicitly. An instrument whose
 * documented invocation always fails reads as a broken instrument.
 *
 * WHY NOT JUST A NEWER SLUG. Because the next one ages off on the same clock,
 * and all a hand-bumped constant buys is the date of the next outage. A dated
 * literal in this position is a defect whatever date it carries, which is why
 * `studio-desk-default-doc.test.mjs` FAILS if one reappears in this file.
 *
 * WHAT REPLACES IT. The default is a mode, `newest`, resolved AT RUN TIME from
 * the Papers pane the drill has already proven it entered (`waitForNewPane` —
 * D138's failure C was a ROOT-pane read misdiagnosed for seven weeks as a
 * partially-loaded list). Reachability stops being a claim about the past: the
 * slug is read as the newest row's own `phx-value-id`, out of the very list the
 * click is about to be made in, seconds earlier. What D97 actually forbids is a
 * run that cannot say WHICH document it measured, and that is bought here
 * exactly as a named target buys it — the landed URL is asserted to carry the
 * resolved slug, and `measured_doc` / `measured_doc_source` /
 * `measured_doc_reachability` are recorded in the run and in the flattened
 * artifact beside `served_sha` and `requested_sha`.
 *
 * AND IT REFUSES RATHER THAN DRIFTING. An empty list is the one input that could
 * turn "newest" into "whatever pane I happen to be looking at" — the root-pane
 * read again, wearing a resolver's clothes. `resolveNewestPaperSlug` throws a
 * named MeasureError instead of returning anything at all.
 *
 * PRECEDENCE, unchanged in the two forms that already existed:
 * `--doc=` beats `BP_DESK_DOC` beats the default.
 *
 * PURE, and injected rather than read from `process`, for the same reason
 * `parseShaPin` is: the precedence is the part that rots, and a resolver that
 * can only be exercised through a 30-60s authenticated sweep is a resolver
 * nobody re-checks.
 */
export function resolveDocTarget(argv = process.argv, env = process.env) {
  const flag = argv.find((a) => typeof a === 'string' && a.startsWith('--doc='));
  if (flag !== undefined) return classifyDocTarget(flag.slice('--doc='.length), '--doc=');
  const fromEnv = env.BP_DESK_DOC;
  if (typeof fromEnv === 'string' && fromEnv.trim() !== '') return classifyDocTarget(fromEnv, 'BP_DESK_DOC');
  return { mode: 'newest', slug: null, source: 'default', resolution: 'newest-paper' };
}

/** One request string -> a target. `resolution` is what the ARTIFACT records as
 *  `measured_doc_source`: how the measured document came to be chosen, which for
 *  `newest`/`any` is NOT the same question as where the request came from. */
function classifyDocTarget(raw, source) {
  const slug = String(raw).trim();
  if (!slug) {
    die(`${source} was passed with an empty value — name a document slug, or \`newest\` (the default: ` +
        `the newest row of the Papers pane, resolved at run time), or \`any\` (the first row that opens ` +
        `a paper surface). Omitting it entirely is also \`newest\`.`);
  }
  if (slug === NEWEST_DOC) return { mode: 'newest', slug: null, source, resolution: 'newest-paper' };
  if (slug === ANY_DOC) return { mode: 'any', slug: null, source, resolution: 'first-openable-row' };
  return { mode: 'named', slug, source, resolution: source };
}

/**
 * The newest row's slug, from the `phx-value-id`s the Papers pane rendered.
 *
 * The list is ordered newest-first (D97 established that while arguing against
 * relying on it), so "newest" is `rows[0]` — but only among rows that actually
 * carry a slug, because a row without one cannot be clicked by id and cannot be
 * asserted against the landed URL, which is the whole determinism story.
 *
 * ZERO IS A REFUSAL, NEVER A FALLBACK. A caller that got `null` here would go on
 * to measure whatever surface happened to be on screen — the root pane, whose
 * rows are document TYPES — and label it a desk fact. That is the exact confound
 * this instrument exists to make unreachable, so the empty case throws a
 * MeasureError naming what it saw and what to pass instead.
 */
export function resolveNewestPaperSlug(rowSlugs) {
  const rows = Array.isArray(rowSlugs) ? rowSlugs : [];
  const usable = rows.filter((s) => typeof s === 'string' && s.trim() !== '');
  if (usable.length === 0) {
    die(`INSTRUMENT FAILURE (drill) — this says NOTHING about the desk's layout.\n\n` +
        `  THE PAPERS PANE OFFERED NO DOCUMENT TO MEASURE: ${rows.length} row(s) were read from the ` +
        `pane and ${rows.length === 0 ? 'none exist' : 'not one carries a phx-value-id'}, so there is ` +
        `no newest paper to resolve the default to.\n\n` +
        `  REFUSING TO FALL BACK. The next thing on screen is the root pane, whose rows are document ` +
        `TYPES rather than documents; measuring it would produce a full matrix of numbers about the ` +
        `wrong surface and label them a desk fact. A pane with no papers is an environment fact, and ` +
        `it is reported as one.\n\n` +
        `  Pass --doc=<slug> to name a document, or --doc=any to take the first row that opens a ` +
        `paper surface, or publish a Paper into this workspace.`);
  }
  return {
    slug: usable[0].trim(),
    source: 'newest-paper',
    rows_considered: rows.length,
    rows_with_slug: usable.length,
  };
}

/** The nine widths, DESCENDING (D80). 500 is the floor this matrix commits to;
 *  sub-500 belongs to spd-b6-sub500-phone-proof. */
const WIDTHS = [1440, 1280, 1024, 900, 800, 764, 700, 640, 500];

/** Three reading faces, each ACTUALLY forced. Bare serif/ui-serif is BANNED
 *  (D49). `native` applies no override and reports which family actually won. */
const FACES = [
  { id: 'native', override: null, note: 'no override — the deployed --paper-font-serif stack' },
  { id: 'georgia', override: "Georgia, 'Times New Roman', serif", note: 'forced Georgia' },
  { id: 'source-serif-4', override: "'Source Serif 4', serif", note: 'forced self-hosted Source Serif 4' },
];

/** The READING COLUMN — the one element every ch figure in this file is derived
 *  from. Named once, because a state is now allowed to declare that it does not
 *  have one, and "the thing that is absent" must have a name to be absent. */
const READING_COLUMN_SELECTOR = '.bp-paper-surface';

// ── failure ──────────────────────────────────────────────────────────────────
//
// Declared HERE, above the band table, and not in a later section: the band
// helpers `die()` on an unknown band name and are called at module init
// (WIDE_BUCKET_MIN_PX below), so a `const die` further down would put the
// instrument's own failure primitive in its temporal dead zone at exactly the
// moment it is needed. A `ReferenceError: Cannot access 'die'` instead of a
// named MeasureError is the same class of defect this wave is closing.

/**
 * THE ONE FAILURE TYPE — now carrying a RETRY CLASS.
 *
 * D138's "the instrument is ~80% deterministic" was never one fault. Every
 * zero-byte exit is an INSTRUMENT FAILURE (never a desk fact), but they split
 * cleanly in two, and the split is what an operator actually needs:
 *
 *   RETRYABLE — the harness lost a race it can win on the next try, and nothing
 *     about the run's own logic is in question: a drill abort, an unreachable
 *     [data-user-opened] marker, a provenance bracket broken by a deploy landing
 *     under the sweep. Re-running is the CORRECT response, not a deviation.
 *
 *   TERMINAL — re-running changes nothing: a banned generic-serif fallback, a
 *     non-vacuity guard failure, a malformed --out, an unparseable in-page
 *     source, a browser that is not installed. These want a human.
 *
 * The class is on the ERROR, at the throw site, because that is the only place
 * that knows. `--retries=N` (below) then acts on it, so "bounded retries on the
 * NAMED fail-closed aborts" is a property of the instrument rather than of
 * operator discipline — which is exactly what the wave-9 brief left unwritten
 * and what an operator meeting a NEW abort had no authority to do.
 */
export class MeasureError extends Error {
  constructor(msg, { retryable = false, abortId = null } = {}) {
    super(msg);
    this.retryable = retryable;
    this.abortId = abortId;
  }
}
const die = (msg, opts) => { throw new MeasureError(msg, opts); };

/**
 * THE RETRYABLE ABORTS, ENUMERATED BY NAME.
 *
 * The wave-9 brief authorised bounded retries on ONE abort — the
 * `[data-user-opened]` marker — so an operator who met any of the other four
 * had no written authority to re-run and had to deviate to do the right thing.
 * A list of one is not a policy. This is the list, and `dieRetryable()` is the
 * only way onto it: an id not in this table throws at the throw site, so the
 * table cannot silently fall behind the code (see
 * `scripts/studio-desk-instrument-reliability.test.mjs`).
 *
 * Every one of these writes ZERO BYTES and exits non-zero. That is by design
 * (D138: a partial matrix is not a matrix) and it is exactly why they must be
 * retried rather than reported: a retryable abort is the absence of a
 * measurement, not a measurement of an absence.
 */
export const RETRYABLE_ABORTS = [
  { id: 'drill',                why: 'the drill never reached a document to measure — pane/list/row race' },
  { id: 'user-opened-marker',   why: 'real clicks never produced [data-user-opened] on .bp-doc-sidebar' },
  { id: 'user-opened-vanished', why: 'the [data-user-opened] marker vanished mid-sweep' },
  { id: 'element-vanished',     why: 'a required element vanished between the settle and the measure' },
  { id: 'provenance-bracket',   why: 'the deployment moved under the sweep — a deploy, not a desk fact' },
  // NOT thrown by this file. Playwright raises it, out of whatever `evaluate`
  // was in flight, when the page navigates or the target closes underneath —
  // which is what a blue/green slot rotation does to an open sweep. It reaches
  // the retry layer as a plain Error, so `isRetryableBrowserRace()` classifies
  // it there rather than at a throw site this file does not own.
  { id: 'browser-race',         why: "playwright's execution context died under a navigation or restart",
    classified_at: 'the retry layer — playwright throws it, not this file' },
];
const RETRYABLE_ABORT_IDS = new Set(RETRYABLE_ABORTS.map((a) => a.id));

/**
 * THE ABORT D138 CALLED "FAILURE B" AND COULD NOT DIAGNOSE, CAUGHT.
 *
 * Failure B was one zero-byte exit-1 whose operator suppressed stderr, so its
 * text is gone and it has sat undiagnosed since. The N=22 characterisation
 * sweep of 2026-09-06 reproduced it WITH stderr intact:
 *
 *     page.evaluate: Execution context was destroyed, most likely because of a
 *     navigation
 *         at waitForDeskSettled (studio-desk-measure.mjs)
 *         at async runB29Probes
 *
 * It arrived in the same minutes as two `provenance-bracket` aborts reporting a
 * LIVE SLOT CHANGE — i.e. guerrilla was rotating blue/green under the sweep. A
 * restart navigates the open page, playwright's execution context dies inside
 * whichever `evaluate` was in flight, and the run exits 1 having written
 * nothing. That is the same deploy-under-the-sweep race the bracket catches at
 * the END of a run, reaching us EARLIER, through a different door.
 *
 * It is not a MeasureError — playwright throws it — so without this it counts
 * as TERMINAL and burns the run. Matching on the message is narrow on purpose:
 * these three strings are playwright's own vocabulary for "the thing you were
 * talking to went away", and nothing about the desk is implied by any of them.
 */
export function isRetryableBrowserRace(err) {
  if (err instanceof MeasureError) return false;
  return /Execution context was destroyed|Target (page, context or browser has been )?closed|Navigation (failed because page was closed|to .* is interrupted)/i
    .test(String(err?.message ?? ''));
}

/** A fail-closed abort the operator is AUTHORISED to re-run, BY NAME. */
const dieRetryable = (id, msg) => {
  if (!RETRYABLE_ABORT_IDS.has(id)) {
    throw new MeasureError(
      `internal: "${id}" is not in RETRYABLE_ABORTS. An abort earns a retry by being NAMED in that ` +
      `table, never by being thrown from a convenient helper.`);
  }
  throw new MeasureError(msg, { retryable: true, abortId: id });
};

/**
 * THE WIDTH BANDS, as ONE table — mirroring the pre-paint stamp in
 * `root.html.heex` verbatim (`EDGES = [640, 1024, 1280]`,
 * `NAMES = ["phone","narrow","standard","wide"]`).
 *
 * WHY A TABLE AND NOT TWO CONSTANTS (this wave's third defect). The destination
 * predicate used to be `(width) => width < WIDE_BUCKET_MIN_PX` with
 * WIDE_BUCKET_MIN_PX = 1280 — which admits SEVEN of these nine widths, INCLUDING
 * 1024. But 1024 stamps `standard`, and the server predicate is an ENUMERATION,
 * `bucket in ["narrow","phone"]`, which REFUSES standard (components.ex:111-113
 * — and refuses it deliberately: the wave-10 ladder made standard + user-opened
 * a real DOCKED state, so `!= "wide"` is forbidden there). Every 1024 row the old
 * predicate admitted was therefore a PRE-LOADED FALSE FAILURE: a row labelled
 * "destination" that the deployed build would never put in that state.
 *
 * The fix is not a second hardcoded edge — a fresh `1024` literal is a new thing
 * that can rot independently of the stamp it is supposed to agree with. Both the
 * bucket name and every threshold below are DERIVED from this one table, so a
 * band edge can only move in one place.
 */
const WIDTH_BANDS = [
  { name: 'phone',    min_px: 0 },
  { name: 'narrow',   min_px: 640 },
  { name: 'standard', min_px: 1024 },
  { name: 'wide',     min_px: 1280 },
];

/** The lower edge of a named band, by NAME — so no caller ever spells an edge. */
function bandMinPx(name) {
  const band = WIDTH_BANDS.find((b) => b.name === name);
  if (!band) die(`unknown width band "${name}" — not in WIDTH_BANDS`);
  return band.min_px;
}

/** Which band a raw width falls in (the RAW band, i.e. `bucket(w)` with no held
 *  bucket — the widen dead-band is a resize-hysteresis concern and this sweep
 *  re-navigates before each state, which re-stamps from the raw band). */
function bandNameFor(width) {
  let name = WIDTH_BANDS[0].name;
  for (const b of WIDTH_BANDS) if (width >= b.min_px) name = b.name;
  return name;
}

/** The `wide` bucket's lower bound — DERIVED, never spelled. */
const WIDE_BUCKET_MIN_PX = bandMinPx('wide');

/**
 * THE DESTINATION PREDICATE, mirroring components.ex:111-113 exactly:
 * `bucket in ["narrow","phone"] and sidebar_user_opened`. Expressed against the
 * band NAMES rather than a width literal, for the same reason the server
 * enumerates rather than negates — `standard` is a docked state, not a
 * destination, and a `< wide` threshold silently swallows that distinction.
 */
const DESTINATION_BUCKETS = ['narrow', 'phone'];
const isDestinationBand = (width) => DESTINATION_BUCKETS.includes(bandNameFor(width));

/**
 * THE STATE TABLE — the second axis, as data rather than as three hardcoded
 * array literals scattered through the printer (D110, and this wave's D153).
 *
 * WHY THIS IS A TABLE AND NOT A LIST OF STRINGS. Three summary loops in
 * `printTable` used to read `['default', 'user-opened']` verbatim. Feeding this
 * instrument a third-state row proved what that costs: 55 rows went in,
 * `destination` appeared ZERO times in the output, and NO error was raised
 * anywhere. A state measured at real cost — an authenticated Chromium sweep,
 * a provenance bracket, a human waiting — vanished from the human table without
 * a word of complaint. That is D130's disease (a run that is silently absent
 * rather than visibly rotted) in a new organ. The loops now derive their order
 * FROM THE ROWS, so dropping a state is structurally impossible, and
 * `assertEveryStateRendered()` is the tripwire that proves the derivation held.
 *
 * `required_selectors` IS PER-STATE, and that is the second half of the fix. It
 * used to be a flat module const asserted for EVERY state before any
 * measurement, with `die()` — a plain throw — as its only outcome. A legitimate
 * state with no reading column therefore aborted the ENTIRE matrix, and because
 * nothing before the provenance bracket writes to disk, a mid-sweep die is 0
 * bytes of stdout, no artifact, and every already-collected row discarded
 * (simulated: exit 1 after 6 good rows, nothing on disk). A state that declares
 * `has_reading_column: false` is recorded `reading_column_present: false` with
 * NULL ch — never 0, because 0 reads as catastrophic occlusion and is exactly
 * the number a seal would turn on.
 *
 * `applies_at` makes the row count a COMPUTATION rather than a literal (D121).
 */
const STATES = [
  {
    id: 'default',
    has_reading_column: true,
    required_selectors: [READING_COLUMN_SELECTOR, '.editor-panel', '.editor-body.bp-paper-body'],
    applies_at: () => true,
    legend: '(as served — below `wide` spd-b29 paints the open panel as a 41px in-flow strip)',
    note: 'the desk exactly as served: no clicks, no reload, descending (D80).',
  },
  {
    id: 'user-opened',
    has_reading_column: true,
    required_selectors: [READING_COLUMN_SELECTOR, '.editor-panel', '.editor-body.bp-paper-body'],
    applies_at: () => true,
    legend: '(after a REAL click on the inspector toggle through the live socket — the state D108 measured)',
    note: 'after a REAL click on [data-test-id="sidebar-toggle-panel"] through the live LiveView ' +
          'socket. `data-user-opened` is SERVER-stamped, so a JS-set attribute would prove only ' +
          'that the CSS works (D110). At `narrow`/`phone` this state IS the Tier-3 destination — ' +
          'see DESTINATION, RETIRED AS A STATE below; such rows carry is_destination:true.',
  },
];

// ── THE THIRD STATE, RETIRED (this wave, charter D177) ───────────────────────
//
// There used to be a `destination` entry here: a summoned Tier-3 state, reached
// by clicking a purpose-built entry control, sweeping its own widths and
// contributing its own rows. It is GONE, and its absence is the correction.
//
// WHAT WAS WRONG. Its entry controls — `[data-test-id="inspector-destination-open"]`
// and `[data-test-id="sidebar-destination"]` — exist NOWHERE on origin/main, and
// they never will, because THE DESTINATION IS NOT SUMMONED BY A CONTROL AT ALL.
// It is ENTAILED by a server predicate: `paper_doc != nil and bucket in
// ["narrow","phone"] and sidebar_user_opened` (components.ex:111-113). Every one
// of those conjuncts is already true of rows this instrument ALREADY takes — the
// `user-opened` sweep at narrow and phone widths IS the destination, measured,
// with provenance, today. The "third state" was therefore a DUPLICATE of the
// second reachable only through an env override, and the instrument was skipping
// it by name and calling that honest reporting.
//
// WHAT REPLACES IT. Nothing is summoned and no state is added. Each row is
// stamped with a DERIVED `is_destination`, read from the SERVER-stamped
// `[data-inspector-destination]` marker that #5014 really does ship
// (components.ex:399) — the same D110 discipline `data-user-opened` is held to,
// because a marker the client could have written proves only that the
// stylesheet works. `isDestinationBand()` gives the band-derived EXPECTATION,
// and the two are cross-checked per row: a disagreement is a warning naming
// both, never a silent preference for one.
//
// Row count therefore returns to 54 (2 states x 9 widths x 3 faces), with 18 of
// them — user-opened at the six sub-1024 widths, x 3 faces — carrying
// is_destination:true.
//
// WHAT SURVIVES THE RETIREMENT, because it was never about the summoned state.
// `has_reading_column` stays a PER-STATE fact and `required_selectors` stays
// per-state: a flat module-level assertion is what let one column-less state
// abort the whole matrix, and that seam is load-bearing regardless of which
// states exist today. And D127 Part 2's rule — that a reading column covered BY
// DESIGN reports NULL, never FALSE — moves onto the destination ROWS, where it
// is now enforced by `suppressVerdictForDestination()` below.

/** The SERVER-stamped marker that proves a row really is in the destination.
 *  Same discipline as `data-user-opened` (D110). */
const DESTINATION_MARKER = '[data-inspector-destination]';

/**
 * D127 PART 2, ENFORCED ON THE ROW. In the destination the inspector covers the
 * viewport (`inset: 0`, opaque) — so the reading column, if the DOM still
 * carries one, is occluded BY DESIGN. `visible_content_px` then measures 0 and
 * `visible_meets_55ch` computes FALSE.
 *
 * A FALSE THERE IS AN INSTRUMENT DEFECT, NOT A DESK FACT. It reports "the reader
 * cannot get 55ch" about a state whose entire purpose is that the reader is
 * deliberately looking at something else — and it is a verdict a seal would turn
 * on. This is the exact trap the retired state's `has_reading_column:false` was
 * invented to prevent, so its protection has to survive the state's retirement.
 * The rule: a column covered by design reports NULL. NEVER FALSE, and never 0's
 * verdict laundered as a pass.
 *
 * The MEASUREMENT is left intact — `visible_content_px` and the scrim figures
 * are real observations and are still worth reading. Only the VERDICT is
 * withdrawn, and the row says in words that it was withdrawn and why, so a
 * NULL here can never be confused with a measurement that failed to happen.
 */
function suppressVerdictForDestination(rec) {
  if (rec.visible_meets_55ch === null || rec.visible_meets_55ch === undefined) return rec;
  return {
    ...rec,
    visible_meets_55ch: null,
    visible_verdict_withdrawn: rec.visible_meets_55ch,
    visible_verdict_withdrawn_reason:
      'IS_DESTINATION. The Tier-3 destination covers the viewport with an opaque inspector by ' +
      'design, so the reading column is occluded on purpose and "does the visible column reach ' +
      '55ch" is not a question this state answers. The raw verdict this run computed is preserved ' +
      'in visible_verdict_withdrawn; the reported verdict is NULL, never FALSE (D127 part 2). A ' +
      'FALSE here would be an instrument defect — it would let a state that is working exactly as ' +
      'designed read as a reading-measure regression, and the seal turns on this column.',
  };
}

/**
 * D171's PRECONDITION, ON EVERY READING (charter D185).
 *
 * THE TRAP. The pre-paint stamp in `root.html.heex` is not `bucket(w)` — it is
 * `bucket(w, cur)`, with a WIDEN-ONLY +32px dead-band:
 * `while (cur < raw && w >= EDGES[cur] + 32) cur++`. Widening from 1024 to 1280
 * therefore stamps `standard`, live-confirmed, because 1280 < 1024 + 32 is false
 * but the loop only advances ONE tier per settle and re-anchors to the bucket
 * currently held. Narrowing has no dead-band at all. So any no-reload sweep that
 * ARRIVES at 1280 or 1024 from below measures the WRONG TIER while every other
 * assertion in the run passes. This sweep descends (D80) precisely to stay out
 * of that hole — but "we descend, therefore we are fine" is an argument, not a
 * measurement, and it is exactly the class of unchecked premise this epic keeps
 * finding under a green run.
 *
 * WHY THE RAW BAND AND NOT A MIRROR OF `bucket(w, cur)`. A held-bucket-aware
 * mirror recomputes what the browser computed, from the same inputs, by the same
 * algorithm — so it agrees BY CONSTRUCTION, including in the one case D171
 * exists to catch (arrive at 1280 from below: the mirror also says `standard`,
 * the check passes, the row still measured the wrong tier). The RAW band is the
 * tier the row CLAIMS to be measuring. Its disagreement with the stamp IS the
 * signal, and nothing else in this file can produce it.
 *
 * REAL INNER WIDTH, NOT THE REQUESTED ONE. `page.setViewportSize` is a request;
 * `window.innerWidth` is what the layout actually got. Deriving the expectation
 * from the request would hide a viewport that never took, which fails the same
 * way and reads the same in the artifact.
 *
 * IT REPORTS, IT NEVER `die()`s. A fatal abort mid-sweep discards every row
 * collected so far and writes ZERO bytes, which D138 rules an INSTRUMENT FAILURE
 * rather than a desk fact. R's criterion 4 imposes a REPORTING duty: warn, NULL
 * that row's verdicts, and let the artifact reach disk carrying the finding.
 */
function bucketPrecondition(requestedWidth, realInnerWidth, stamped) {
  const inner = Number.isFinite(realInnerWidth) ? realInnerWidth : requestedWidth;
  const expected = bandNameFor(inner);
  return {
    requested_viewport_px: requestedWidth,
    real_inner_width: inner,
    expected_raw_band: expected,
    width_bucket_stamped: stamped ?? null,
    bucket_precondition_ok: stamped === expected,
    basis: 'RAW bandNameFor(window.innerWidth) vs the pre-paint [data-width-bucket] stamp — NOT a ' +
           'held-bucket mirror of root.html.heex bucket(w, cur), which would agree by construction ' +
           'in exactly the widen-dead-band case D171 exists to catch.',
  };
}

/** The run-level rollup. `checked`/`agreed` make a zero READABLE: a run with
 *  `checked: 0` never asserted anything, which is a different (and worse) state
 *  than `agreed === checked`. Every failure is named with its full context so a
 *  reader can locate the row without re-running. */
function emptyBucketPrecondition() {
  return {
    checked: 0,
    agreed: 0,
    failures: [],
    note:
      'Every reading in this run asserts that [data-width-bucket] equals the RAW band of the ' +
      'viewport it actually got, as a PRECONDITION of the reading (charter D171/D185). A row that ' +
      'fails carries bucket_precondition_ok:false, has BOTH 55ch verdicts withdrawn to NULL (never ' +
      'FALSE — it measured the wrong tier, it did not measure a bad desk), and is listed here. This ' +
      'never aborts the run: a mid-sweep abort writes zero bytes, which D138 rules an INSTRUMENT ' +
      'FAILURE rather than a desk fact.',
  };
}

function recordBucketPrecondition(run, where, pre) {
  const acc = run.bucket_precondition ??= emptyBucketPrecondition();
  acc.checked += 1;
  if (pre.bucket_precondition_ok) { acc.agreed += 1; return pre; }
  acc.failures.push({ where, ...pre });
  run.warnings.push(
    `BUCKET PRECONDITION FAILED at ${where}: the page stamps [data-width-bucket]=` +
    `"${pre.width_bucket_stamped}" but window.innerWidth ${pre.real_inner_width}px (requested ` +
    `${pre.requested_viewport_px}px) falls in the RAW band "${pre.expected_raw_band}". This row ` +
    `measured a DIFFERENT TIER than it claims — D171's widen-only +32px dead-band, or a viewport ` +
    `that never took. Its 55ch verdicts are withdrawn to NULL; the measurements are left intact and ` +
    `are still readable as observations of whatever tier was actually on screen.`);
  return pre;
}

/**
 * The verdict withdrawal for a failed precondition. Same rule as D127 part 2 and
 * for the same reason: a row that measured the wrong tier must not report FALSE
 * on a criterion the seal turns on. FALSE would say "this desk fails 55ch";
 * the honest sentence is "this reading does not describe the tier it names".
 */
function withdrawVerdictsForBucketPrecondition(rec, pre) {
  return {
    ...rec,
    content_meets_55ch: null,
    visible_meets_55ch: null,
    verdicts_withdrawn_for_bucket_precondition: {
      content_meets_55ch: rec.content_meets_55ch ?? null,
      visible_meets_55ch: rec.visible_meets_55ch ?? null,
      expected_raw_band: pre.expected_raw_band,
      width_bucket_stamped: pre.width_bucket_stamped,
      reason:
        'BUCKET PRECONDITION FAILED. The stamp disagrees with the raw band of the viewport this row ' +
        'actually got, so the row measured a different tier than it names. The raw verdicts are ' +
        'preserved here; the reported verdicts are NULL, never FALSE (D171/D185, same rule as D127 ' +
        'part 2). The measurements themselves are untouched — they are real observations of the ' +
        'tier that was on screen.',
    },
  };
}

/**
 * THE FACE-SUBSTITUTION WITHDRAWAL — D138 failure A, ruled on.
 *
 * WHAT FAILURE A IS. `PAGE_MEASURE` forces a face by setting
 * `--paper-font-serif` INLINE on `.bp-paper-surface`, then reads
 * `getComputedStyle(surface).fontFamily` back as `declared_stack`. If a
 * LiveView patch replaces or re-attributes that node between the set and the
 * read, the inline custom property is gone and the surface is back on the
 * DEPLOYED stack — which is precisely what D138 recorded: `declared_stack` fell
 * back to the native stack, `face_applied` went true -> false, and every
 * ch-derived figure moved with it while the layout box did not move at all
 * (`visible_content_px` and `content_px` identical to the digit). Nothing about
 * that mechanism is width-bound: it is a race with a DOM patch, and a patch can
 * land at any of the nine widths. See RULING 1 in this file's header for the
 * reachability argument and the run evidence.
 *
 * THE RULING, IN CODE. Same shape as the bucket precondition, for the same
 * reason: the row measured something other than what it names, so its 55ch
 * verdicts go to NULL — never FALSE. FALSE would say "this desk fails 55ch on
 * Georgia" when Georgia was never on screen. The measurements themselves stay:
 * they are real observations of whatever face won. And it is NOT a `die()`: a
 * mid-sweep abort writes zero bytes, which D138 rules an instrument failure
 * rather than a desk fact, so killing 53 good rows to withdraw one is the wrong
 * trade. The RUN-level gate lives in `face_override_integrity` and
 * `--fail-on-face-substitution`.
 */
export function withdrawVerdictsForFaceSubstitution(rec, face) {
  return {
    ...rec,
    face_applied_ok: false,
    content_meets_55ch: null,
    visible_meets_55ch: null,
    verdicts_withdrawn_for_face_substitution: {
      content_meets_55ch: rec.content_meets_55ch ?? null,
      visible_meets_55ch: rec.visible_meets_55ch ?? null,
      requested_primary: rec.font.requested_primary,
      resolved_family: rec.font.resolved_family,
      forced_to: face.override,
      declared_stack: rec.font.declared_stack,
      reason:
        'FACE SUBSTITUTION. The forced face did not win: this row\'s ch is a conversion through a ' +
        'DIFFERENT face than the one it names, so its 55ch verdicts are NULL, never FALSE (D138 ' +
        'failure A, same rule as D171/D185 and D127 part 2). The px measurements are untouched.',
    },
  };
}

/** The run-level accumulator behind `--fail-on-face-substitution`. */
export function emptyFaceIntegrity() {
  return {
    forced_rows_checked: 0,
    substitutions: [],
    clean: true,
    ruling:
      'A forced-face row whose face did not apply has its 55ch verdicts withdrawn to NULL and is ' +
      'listed here. The INSTRUMENT still exits 0 (D81: it has no gate authority); a CONSUMER that ' +
      'wants a gate passes --fail-on-face-substitution, which exits non-zero AFTER the artifact is ' +
      'written, so the gate reds without ever producing the zero-byte run D138 forbids.',
  };
}

export function recordFaceSubstitution(run, where, rec, face) {
  const acc = run.face_override_integrity ??= emptyFaceIntegrity();
  acc.forced_rows_checked += 1;
  if (rec.font.face_applied) return rec;
  acc.clean = false;
  acc.substitutions.push({
    where,
    requested_primary: rec.font.requested_primary,
    resolved_family: rec.font.resolved_family,
    declared_stack: rec.font.declared_stack,
    probe_px_per_ch: rec.ch?.probe_px_per_ch ?? null,
  });
  run.warnings.push(
    `FACE SUBSTITUTION at ${where}: asked for ${rec.font.requested_primary}, resolved ` +
    `${rec.font.resolved_family} — this row's ch is NOT the named face, so BOTH its 55ch verdicts ` +
    `are withdrawn to NULL. The px measurements stand.`);
  return withdrawVerdictsForFaceSubstitution(rec, face);
}

/**
 * D186 — THE OVERLAY ASSERTION, NARROWED RATHER THAN DELETED.
 *
 * D108 turned on a real desk observation: below `wide`, an explicitly-opened
 * inspector leaves flow and OVERLAYS the reading column. The wave-10 Tier-2
 * ladder then made that false ON PURPOSE at `standard` — the rail yields and the
 * inspector DOCKS IN FLOW when the panel still has room (measured: panel 980 at
 * viewport 1024). The old predicate was `stamped !== 'wide'`, so it warned on
 * three legitimate 1024/user-opened rows EVERY SINGLE RUN.
 *
 * A permanent unexplained warning is worse than no warning: it teaches the reader
 * that this instrument's warnings are noise, and the next real one gets skipped.
 * DELETING it is worse still — the signal goes entirely, and a reverted ladder
 * would then read as a clean run.
 *
 * So the regime is narrowed to where overlay is still the ruling: narrow/phone
 * always, and `standard` only BELOW the panel width at which the ladder's dock
 * stops being possible. 860px is that edge — the same threshold the scrim flips
 * at (861 -> `none`, 860 -> `""`, forced-container control, charter D153/D176).
 * A `standard` row whose panel came in at or below it has no room to dock, so
 * absolute is still the claim, and this tripwire STILL FIRES if the ladder is
 * reverted or mis-scoped.
 *
 * A null panel_px does NOT assert: the check needs the number it is conditioned
 * on, and a missing measurement is not evidence either way.
 */
const OVERLAY_ABSOLUTE_MAX_PANEL_PX = 860;
const OVERLAY_REGIME =
  `narrow/phone always; standard only when panel_px <= ${OVERLAY_ABSOLUTE_MAX_PANEL_PX}`;

/** The two facts the precondition needs, read straight off the live page — for
 *  callers that hold a page but no measured row (the round trip's per-width
 *  loop, whose legs are not `PAGE_MEASURE` reads). */
async function readBucketStamp(page) {
  return page.evaluate(() => ({
    real_inner_width: window.innerWidth,
    width_bucket_stamped: document.documentElement.getAttribute('data-width-bucket'),
  }));
}

function overlayShouldBeAbsolute(rec) {
  const bucket = rec.width_bucket_stamped;
  if (bucket === 'narrow' || bucket === 'phone') return true;
  if (bucket !== 'standard') return false;
  return typeof rec.panel_px === 'number' && rec.panel_px <= OVERLAY_ABSOLUTE_MAX_PANEL_PX;
}

const STATE_IDS = STATES.map((s) => s.id);
const stateById = (id) => STATES.find((s) => s.id === id) ?? null;

/** Which states apply at a given width, restricted to the ones this run is
 *  actually attempting (a skipped state contributes no rows and must not
 *  inflate the expected count). */
function statesApplicableAt(width, stateIds = STATE_IDS) {
  return STATES.filter((s) => stateIds.includes(s.id) && s.applies_at(width));
}

/** D121's doctrine survives; D121's NUMBER does not. The run states its own
 *  expected count and proves it hit it, so a short run is arithmetic rather
 *  than a remembered literal that rots the moment a state or a width is added. */
export function expectedRowCount(stateIds = STATE_IDS) {
  return WIDTHS.reduce((n, w) => n + statesApplicableAt(w, stateIds).length * FACES.length, 0);
}

function rowCountNote(stateIds = STATE_IDS) {
  const perState = STATES.filter((s) => stateIds.includes(s.id)).map((s) => {
    const widths = WIDTHS.filter((w) => s.applies_at(w));
    return `${s.id}: ${widths.length} of ${WIDTHS.length} widths x ${FACES.length} faces = ` +
           `${widths.length * FACES.length}`;
  });
  return `expected_row_count is COMPUTED as sum over widths of ` +
         `(states applicable at that width) x ${FACES.length} faces — never a compiled-in literal. ` +
         `This run: ${perState.join('; ')}. Total ${expectedRowCount(stateIds)}. ` +
         `A state that skipped contributes nothing and is listed in states_skipped, so the expected ` +
         `count always describes the run that actually happened (D121's doctrine, without its number).`;
}

/** How many rows this run expects to carry `is_destination:true`, DERIVED the
 *  same way the flag itself is: the server predicate needs `sidebar_user_opened`
 *  AND a narrow/phone bucket, so it is the user-opened state at exactly the
 *  widths whose raw band is in DESTINATION_BUCKETS, times the faces. Stated so a
 *  run that stamps a different number is arithmetic to check, not a vibe. */
export function expectedDestinationRowCount(stateIds = STATE_IDS) {
  if (!stateIds.includes('user-opened')) return 0;
  return WIDTHS.filter(isDestinationBand).length * FACES.length;
}

function destinationNote() {
  const at = WIDTHS.filter(isDestinationBand);
  const not = WIDTHS.filter((w) => !isDestinationBand(w));
  return `is_destination is DERIVED, not summoned (charter D177). It is stamped from the ` +
         `SERVER-rendered ${DESTINATION_MARKER} marker (components.ex:399) and cross-checked ` +
         `against the band predicate, which mirrors components.ex:111-113 — ` +
         `bucket in [${DESTINATION_BUCKETS.join(', ')}] AND user_opened. Expected true at ` +
         `${at.join(', ')}px (${at.length} widths x ${FACES.length} faces = ` +
         `${expectedDestinationRowCount()} rows) and false at ${not.join(', ')}px. ` +
         `NOTE 1024: it stamps "standard", and the server predicate ENUMERATES the covered ` +
         `buckets rather than negating "wide" precisely so standard + user-opened stays the ` +
         `DOCKED state the wave-10 ladder built. The retired threshold (width < ` +
         `${WIDE_BUCKET_MIN_PX}) admitted 1024 and pre-loaded three false-failure rows; every ` +
         `edge here is now derived from WIDTH_BANDS, the same table the pre-paint stamp uses. ` +
         `Destination rows report visible_meets_55ch as NULL, never FALSE — see ` +
         `suppressVerdictForDestination().`;
}

const SSH = ['-i', path.join(os.homedir(), '.ssh/barkpark_indx'), '-o', 'ConnectTimeout=15',
             '-o', 'StrictHostKeyChecking=accept-new', 'root@157.180.90.121'];

// ── playwright ───────────────────────────────────────────────────────────────

export function resolvePlaywright() {
  const tried = [];
  const candidates = [];

  if (process.env.BP_PLAYWRIGHT_FROM) candidates.push(process.env.BP_PLAYWRIGHT_FROM);
  candidates.push(path.join(REPO, 'js', 'package.json'), path.join(REPO, 'package.json'));

  // A worktree has no node_modules. --git-common-dir points at the primary
  // clone's .git, whose parent is the checkout that DOES have them.
  try {
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { cwd: REPO, encoding: 'utf8' }).trim();
    const primary = path.dirname(common);
    candidates.push(path.join(primary, 'js', 'package.json'), path.join(primary, 'package.json'));
  } catch { /* not a git checkout — the other candidates still apply */ }

  for (const from of candidates) {
    tried.push(from);
    try {
      const require_ = createRequire(from);
      const pw = require_('playwright');
      let version = 'unknown';
      try { version = require_('playwright/package.json').version; } catch { /* keep unknown */ }
      return { pw, resolvedFrom: from, version };
    } catch { /* next */ }
  }
  die(`playwright could not be resolved. Tried, in order:\n  ${tried.join('\n  ')}\n` +
      `Set BP_PLAYWRIGHT_FROM=<path to a package.json that can require("playwright")>.`);
}

/**
 * THE BROWSER IS PROVENANCE TOO.
 *
 * `resolvePlaywright()` is careful about which *library* it loads and then the
 * next line used to be a bare `pw.chromium.launch()` — no channel, no preflight,
 * nothing in the artifact saying which browser produced the numbers. Two costs,
 * both paid:
 *
 *   1. A FRESH HOST FAILS AS THOUGH THE INSTRUMENT WERE BROKEN. Every wave-11
 *      verifier hit `browserType.launch: Executable doesn't exist at
 *      ~/Library/Caches/ms-playwright/chromium_headless_shell-1200/…`, which
 *      reads as an instrument bug, not a missing prerequisite. They worked
 *      around it by forcing `channel: 'chrome'` by hand — i.e. they measured on
 *      a DIFFERENT browser than the committed artifacts did, and nothing in
 *      either artifact says so.
 *   2. A SUCCESSFUL RUN IS PROVENANCE-AMBIGUOUS. Bundled Chromium and system
 *      Chrome are different builds with different font stacks; `ch` is a font
 *      measurement. "Which browser" is not a detail here.
 *
 * So: an explicit POLICY, defaulting to the bundled browser (the reproducible
 * one), overridable to system Chrome by name, recorded in the artifact either
 * way, and a launch failure translated into the exact command that fixes it.
 */
export const BROWSER_POLICIES = {
  bundled: {
    channel: null,
    what: "playwright's own pinned Chromium — the reproducible default",
    fix: 'npx playwright install chromium',
  },
  chrome: {
    channel: 'chrome',
    what: 'the system Google Chrome install (what the wave-11 verifiers fell back to by hand)',
    fix: 'install Google Chrome, or unset BP_DESK_BROWSER to use the bundled Chromium',
  },
};

export function browserPolicy(env = process.env) {
  const raw = (env.BP_DESK_BROWSER ?? 'bundled').trim();
  const chosen = BROWSER_POLICIES[raw];
  if (!chosen) {
    die(`BP_DESK_BROWSER="${raw}" is not a browser policy. Known: ` +
        Object.keys(BROWSER_POLICIES).join(', ') + '.');
  }
  return {
    id: raw,
    channel: chosen.channel,
    what: chosen.what,
    fix: chosen.fix,
    source: env.BP_DESK_BROWSER ? 'BP_DESK_BROWSER' : 'default',
  };
}

/** True for the ONE failure that is a missing prerequisite rather than a bug. */
export function isMissingBrowserError(err) {
  const m = String(err?.message ?? err ?? '');
  return /Executable doesn't exist|playwright install|Chromium distribution|Chrome distribution|channel .* is not installed/i.test(m);
}

/** The message a fresh verifier should get instead of a raw stack. */
export function missingBrowserMessage(err, policy) {
  return `NO BROWSER — nothing was measured, and this says nothing about the desk.\n\n` +
    `  Policy "${policy.id}" (${policy.source}): ${policy.what}.\n` +
    `  Fix it with:\n\n      ${policy.fix}\n\n` +
    `  Or choose the other policy: BP_DESK_BROWSER=` +
    `${Object.keys(BROWSER_POLICIES).filter((k) => k !== policy.id).join('|')}. ` +
    `Both are recorded in the artifact, so a run always says which browser measured it.\n\n` +
    `  Playwright said:\n    ${String(err?.message ?? err).split('\n')[0]}`;
}

/** Launch under the policy, and turn the one prerequisite failure into a fix. */
export async function launchMeasureBrowser(pw, policy, launch = (opts) => pw.chromium.launch(opts)) {
  try {
    return await launch(policy.channel ? { channel: policy.channel } : {});
  } catch (err) {
    if (isMissingBrowserError(err)) die(missingBrowserMessage(err, policy));
    throw err;
  }
}

// ── provenance (queried, never assumed — D71) ────────────────────────────────

function ssh(cmd) {
  return execFileSync('ssh', [...SSH, cmd], { encoding: 'utf8', timeout: 45_000 }).trim();
}

function readProvenance() {
  let servedSha, slotRaw;
  try {
    servedSha = ssh('cd /opt/barkpark && git rev-parse HEAD');
  } catch (e) {
    die(`could not read the served SHA over ssh — refusing to publish a matrix with no provenance ` +
        `(charter D47: "a measurement taken without it certifies the bug the wave is fixing"). ${e.message}`);
  }
  try {
    slotRaw = ssh(`systemctl list-units 'barkpark-slot@*' --all --no-legend`);
  } catch (e) {
    die(`could not query the live slot over ssh (D71 forbids assuming it). ${e.message}`);
  }
  const loaded = slotRaw.split('\n').map((l) => l.trim()).filter(Boolean);
  const active = loaded.filter((l) => /\bactive\b/.test(l) && /\brunning\b/.test(l));
  return {
    read_at: new Date().toISOString(),
    served_sha: servedSha,
    slot_units_loaded: loaded,
    slot_active: active.map((l) => (l.match(/barkpark-slot@(\w+)\.service/) || [null, 'unknown'])[1]),
    slot_read_method: `ssh root@157.180.90.121 "systemctl list-units 'barkpark-slot@*' --all --no-legend"`,
    sha_read_method: 'ssh root@157.180.90.121 "cd /opt/barkpark && git rev-parse HEAD"',
  };
}

/**
 * The bracket (D97). A full authenticated sweep has been observed at 29.8s,
 * 30.9s, 32.8s and 59.7s — call it ~30-60s, and budget ~2min for the worst
 * case, because a slot rotation landing mid-sweep roughly doubles the run
 * (the 59.7s observation IS that case: `barkpark-slot@green` entered inside
 * the window). Whatever the duration, the deployment underneath it is not
 * frozen for our convenience. Returns a list of human-readable differences
 * between the pre-run and post-run reads — EMPTY means every row in between was
 * served by the same code from the same process.
 *
 * (The "~10 minutes" this comment used to claim was never measured and was off
 * by ~20x — D115. It is a live false-blocker in both directions: a builder who
 * believes it aborts a healthy 90s run as 9x over budget, or waits ten minutes
 * before suspecting a genuine hang. Replaced with the observed range AND its
 * worst case rather than one over-confident number swapped for another.)
 *
 * Exported so this can be exercised directly, without a full authenticated
 * run, which is the only way to know the check is not vacuous.
 */
export function compareProvenance(pre, post) {
  const out = [];
  if (pre.served_sha !== post.served_sha) {
    out.push(
      `SERVED SHA CHANGED MID-SWEEP: ${pre.served_sha} (read ${pre.read_at}) -> ` +
      `${post.served_sha} (read ${post.read_at}). A deploy landed inside the measurement window. ` +
      `Rows measured before it describe one build and rows after it describe another, and NOTHING ` +
      `in the matrix says which is which — this is precisely the silent misattribution the bracket exists to catch.`);
  }
  const preSlot = [...pre.slot_active].sort().join(',');
  const postSlot = [...post.slot_active].sort().join(',');
  if (preSlot !== postSlot) {
    out.push(
      `LIVE SLOT CHANGED MID-SWEEP: [${preSlot || 'none'}] (read ${pre.read_at}) -> ` +
      `[${postSlot || 'none'}] (read ${post.read_at}). ` +
      (pre.served_sha === post.served_sha
        ? `The SHA held, so this is most likely a benign same-SHA rotation — but the app RESTARTED under ` +
          `the sweep, so earlier rows were served by a different process than later ones and this run ` +
          `cannot certify a single serving state.`
        : `Combined with the SHA change above, this is a deploy.`));
  }
  return out;
}

/**
 * THE REQUESTED REVISION (`--sha=` / `--ref=`), CHECKED BEFORE ANY ROW EXISTS.
 *
 * The bracket above catches the deployment moving DURING a sweep. It cannot
 * catch the deployment having ALREADY moved before the sweep started, because
 * a run that never says which build it wanted cannot be wrong about it. That
 * is charter D73's whole cost: D60 accused D40 of narrating fiction because a
 * later grep found the cited rule gone, when spd-s4 had simply replaced it in
 * the meantime — and settling it took git archaeology instead of one line in
 * an artifact.
 *
 * So a caller can now NAME the build it intends to measure. If the box serves
 * a different one, the run REFUSES — non-zero, by name, with both SHAs — and
 * it refuses at the PRE half of the bracket, before a browser is launched and
 * long before a row is emitted. Nothing is written, because a matrix of the
 * wrong build is worse than no matrix (D138: a partial matrix is not a matrix;
 * this is its sibling — a matrix of the wrong revision is not a measurement of
 * yours).
 *
 * This is the CHEAP form the task authorised and deliberately not the other
 * one: it does not serve the ref locally, check anything out, or move the
 * deployment. It only refuses to pretend. `--sha` with no deploy of your own
 * is a no-op on a matching box and a loud stop on a moved one.
 *
 * NOT retryable. A moved deployment is not a race the harness lost; re-running
 * it verbatim reproduces the same refusal until someone deploys or changes the
 * requested SHA.
 */
export function parseShaPin(argv = process.argv, env = process.env) {
  const ALIASES = ['--sha', '--ref'];
  let raw = null;
  let source = null;
  for (const flag of ALIASES) {
    const eq = argv.find((a) => typeof a === 'string' && a.startsWith(`${flag}=`));
    if (eq !== undefined) { raw = eq.slice(flag.length + 1); source = `${flag}=`; break; }
    const i = argv.indexOf(flag);
    if (i !== -1) {
      raw = argv[i + 1];
      if (raw === undefined) die(`${flag} was passed with no value — name the commit the box must be serving, e.g. ${flag}=5aad3b917`);
      if (typeof raw === 'string' && raw.startsWith('-')) {
        die(`${flag} was followed by \`${raw}\`, which is another flag, not a SHA. Pass the commit: ${flag}=<sha>`);
      }
      source = flag;
      break;
    }
  }
  if (raw === null || raw === undefined) {
    // Env form, for the same reason BP_DESK_DOC exists: a sweep driven from a
    // script that already knows the SHA should not have to rewrite its argv.
    const fromEnv = env.BP_DESK_SHA;
    if (fromEnv === undefined || String(fromEnv).trim() === '') return null;
    raw = fromEnv;
    source = 'BP_DESK_SHA';
  }
  const requested = String(raw).trim();
  if (!requested) die(`${source} was passed with an empty value — name the commit the box must be serving, or omit the flag`);
  // Abbreviated is fine (that is what a human copies out of `git log`), but it
  // must be a SHA. A branch name would be checked against a 40-hex string and
  // could only ever refuse, which is a refusal about the ARGUMENT dressed up as
  // a refusal about the deployment.
  if (!/^[0-9a-f]{7,40}$/i.test(requested)) {
    die(`${source} must be a hex commit SHA, 7 to 40 characters (got ${JSON.stringify(requested)}). ` +
        `A branch or tag name is NOT accepted: the box reports \`git rev-parse HEAD\`, a 40-hex string, so a ` +
        `name could only ever mismatch — a refusal about your argument wearing the costume of a refusal about ` +
        `the deployment. Resolve it yourself: ${source.replace(/[= ]$/, '')}=$(git rev-parse <ref>).`);
  }
  return { requested: requested.toLowerCase(), source };
}

/**
 * THE COMPARISON. Pure, so it can be exercised without ssh, a browser or a box.
 *
 * The served SHA is whatever `git rev-parse HEAD` printed on the box: 40 hex
 * characters. The requested one is whatever a human pasted, commonly the short
 * form. So a PREFIX match counts, in the one direction that is sound — the
 * requested value is a prefix of the served one. (The mirror direction is
 * accepted too, for a hypothetical abbreviated served read, and it costs one
 * clause.) `startsWith` on the shorter of the two, never a substring test:
 * `includes` would match a SHA in the middle of another and that is not a
 * revision identity.
 */
export function shaPinMatches(requested, served) {
  const a = String(requested ?? '').trim().toLowerCase();
  const b = String(served ?? '').trim().toLowerCase();
  if (!a || !b) return false;
  return a.length <= b.length ? b.startsWith(a) : a.startsWith(b);
}

/** Refuse, by name, before anything is measured. No-op when nothing was pinned. */
export function assertServedShaPinned(pin, served) {
  if (!pin) return;
  if (shaPinMatches(pin.requested, served)) return;
  die(
    `SERVED SHA IS NOT THE PINNED SHA — nothing was measured, and this says nothing about the desk.\n\n` +
    `    requested (${pin.source})  ${pin.requested}\n` +
    `    served    (ssh git rev-parse HEAD)  ${served || '<empty>'}\n\n` +
    `  The box is serving a different build than the one this run was pinned to, so every row it could ` +
    `produce would carry your intent and the box's code and nothing would say they disagreed. That is the ` +
    `confound charter D73 paid for in git archaeology, and it is refused here rather than recorded there.\n\n` +
    `  This is NOT a retryable abort: re-running reproduces it exactly until the deployment moves. Either ` +
    `deploy ${pin.requested} to the box, or drop the pin and let the run measure ${served} on the record.`);
}

// ── auth (D24e login-ticket flow) ────────────────────────────────────────────

function readGuerrillaServer() {
  const p = path.join(os.homedir(), '.config/barkpark/config.json');
  if (!fs.existsSync(p)) die(`no barkpark config at ${p} — cannot read the guerrilla admin token`);
  const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
  const srv = (cfg.known_servers || []).find((s) => s.name === 'guerrilla');
  if (!srv?.token) die(`no guerrilla entry with a token in ${p} (known_servers[] where name=="guerrilla")`);
  const base = String(srv.server || '').replace(/\/+$/, '');
  // The session cookie is Secure. An http:// or bare-IP base is silently
  // dropped and you spend the whole run measuring a login page.
  if (!base.startsWith('https://')) die(`guerrilla server must be an https:// hostname (got ${base || '<empty>'}) — the session cookie carries Secure and an http/IP form is dropped`);
  return { base, token: srv.token };
}

/** Single-use, 60s TTL. Minted immediately before navigating. An `email` in the
 *  body mints a USER-shaped ticket — the body must stay empty. */
async function mintTicket({ base, token }) {
  const res = await fetch(`${base}/v1/auth/login-tickets`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: '{}',
  });
  if (!res.ok) die(`login-ticket mint failed: HTTP ${res.status} ${await res.text()}`);
  const body = await res.json();
  if (!body.ticket) die(`login-ticket response carried no ticket: ${JSON.stringify(body)}`);
  return body.ticket;
}

// ── the in-page measurement ──────────────────────────────────────────────────
//
// Everything below runs in the browser. It is passed the face override and
// returns one fully self-describing record. Nothing here infers a box from
// another box.

// EXPORTED so its syntax can be checked without an authenticated run. This is
// a template STRING, so `node --check` on this file says nothing about it — a
// typo in here used to be discoverable only after ssh, a minted ticket, a login
// and a drill, i.e. at the most expensive possible moment. `new Function(...)`
// over this export parses it in milliseconds and costs nothing.
export const PAGE_MEASURE = /* js */ `
async (faceOverride) => {
  const px = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : null; };
  const round = (n, d = 3) => (n === null ? null : Math.round(n * 10 ** d) / 10 ** d);

  const surface = document.querySelector('.bp-paper-surface');
  const panel   = document.querySelector('.editor-panel');
  const body    = document.querySelector('.editor-body.bp-paper-body');

  const counts = {
    '.bp-paper-surface':          document.querySelectorAll('.bp-paper-surface').length,
    '.editor-panel':              document.querySelectorAll('.editor-panel').length,
    '.editor-body.bp-paper-body': document.querySelectorAll('.editor-body.bp-paper-body').length,
  };
  if (!surface || !panel || !body) return { fatal: true, counts };

  // ── force the face on the surface itself, so its OWN font-family (and every
  //    ch it resolves, including the one inside calc(55ch + 80px)) recomputes.
  const hadInline = surface.style.getPropertyValue('--paper-font-serif');
  const hadInlinePriority = surface.style.getPropertyPriority('--paper-font-serif');
  if (faceOverride) surface.style.setProperty('--paper-font-serif', faceOverride);

  const restore = () => {
    // Value AND priority — restoring without the priority would leave the page
    // in a state this harness invented, for every row after this one.
    if (hadInline) surface.style.setProperty('--paper-font-serif', hadInline, hadInlinePriority);
    else surface.style.removeProperty('--paper-font-serif');
  };

  // ── FORCING A FACE IS NOT THE SAME AS HAVING IT. A self-hosted @font-face is
  //    lazy: until something asks for it, document.fonts.check() is false and
  //    the element silently renders in the NEXT stack entry. Measured on this
  //    very build: a width:1ch probe read 9.000px immediately after forcing
  //    'Source Serif 4' (that is bare fallback serif — the face D49 BANS as a
  //    probe, because it is narrower than both real faces and inflates ch) and
  //    9.171875px once the font was actually loaded. Reporting the first number
  //    would have been overturn #7, produced by this instrument.
  const wantedFamilies = (faceOverride || getComputedStyle(surface).fontFamily)
    .split(',').map((f) => f.trim().replace(/^['"]|['"]$/g, ''))
    .filter((f) => f && !/^(serif|sans-serif|monospace|ui-serif|ui-sans-serif|system-ui)$/.test(f));
  const sizeForLoad = getComputedStyle(surface).fontSize;
  for (const fam of wantedFamilies) {
    try { await document.fonts.load(\`\${sizeForLoad} "\${fam}"\`); } catch { /* not available here */ }
  }
  await document.fonts.ready;
  await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));

  const sCs = getComputedStyle(surface);
  const fontFamilyDeclared = sCs.fontFamily;
  const fontSize = px(sCs.fontSize);

  // Which family actually WON. Advance-width equality against each family in
  // the declared stack, measured in the surface's own font-size. Reported as a
  // method, not asserted as a fact.
  const probeText = 'mmmmmmmmmm0123456789';
  const advanceOf = (family) => {
    const s = document.createElement('span');
    s.textContent = probeText;
    s.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;left:-9999px;';
    s.style.fontSize = sCs.fontSize;
    s.style.fontFamily = family;
    surface.appendChild(s);
    const w = s.getBoundingClientRect().width;
    s.remove();
    return w;
  };
  // Presence probing needs MORE THAN ONE generic. Palatino and Times New Roman
  // both have a '0' advance of exactly 1024/2048 em, so comparing a candidate
  // against plain serif cannot separate "absent, fell back to Times" from
  // "present and metrically identical to Times". Three generics with different
  // metrics make that collision vanishingly unlikely.
  const PRESENCE_GENERICS = ['monospace', 'serif', 'sans-serif'];
  const familyIsPresent = (fam) => PRESENCE_GENERICS.some(
    (g) => Math.abs(advanceOf('"' + fam + '", ' + g) - advanceOf(g)) > 0.01,
  );

  const stackAdvance = advanceOf(fontFamilyDeclared);
  const families = fontFamilyDeclared.split(',').map((f) => f.trim());
  let winner = null;
  for (const f of families) {
    if (Math.abs(advanceOf(f) - stackAdvance) < 0.01) { winner = f.replace(/^['"]|['"]$/g, ''); break; }
  }

  // ── the gutter: READ, never computed (D72/D78).
  const padL = px(sCs.paddingLeft), padR = px(sCs.paddingRight);
  const borL = px(sCs.borderLeftWidth), borR = px(sCs.borderRightWidth);

  // ── ch via a probe span inserted as a CHILD of .bp-paper-surface (D31/D83).
  const chProbe = document.createElement('span');
  chProbe.style.cssText = 'position:absolute;visibility:hidden;display:inline-block;width:1ch;left:-9999px;';
  surface.appendChild(chProbe);
  const chProbePx = chProbe.getBoundingClientRect().width;
  chProbe.remove();

  // ── the floor, and whether it BINDS — by experiment, not arithmetic.
  const minInlineRaw = sCs.minInlineSize;
  const minInlinePx = px(minInlineRaw);
  const maxWidthPx = px(sCs.maxWidth);

  const widthWithFloor = surface.getBoundingClientRect().width;
  const hadMin = surface.style.getPropertyValue('min-inline-size');
  const hadMinPriority = surface.style.getPropertyPriority('min-inline-size');
  surface.style.setProperty('min-inline-size', '0px', 'important');
  const widthWithoutFloor = surface.getBoundingClientRect().width;
  // Restore the PRIORITY too. We overrode with !important; putting the value
  // back without its original priority would silently promote a plain inline
  // declaration to important for the rest of the run.
  if (hadMin) surface.style.setProperty('min-inline-size', hadMin, hadMinPriority);
  else surface.style.removeProperty('min-inline-size');
  const floorBinds = Math.abs(widthWithFloor - widthWithoutFloor) > 0.5;

  // The browser's own in-floor ch, derived from the resolved floor. We only
  // ever see the USED px value, never the authored formula, so the formula is
  // an ASSUMPTION and is named as one. spd-w5-measure-lever-moves is chartered
  // to change it (to calc(55ch + 2 * var(--paper-gutter)), or to retire it), at
  // which point this derivation goes quietly wrong — so the divergence against
  // the probe is checked below and a drift beyond tolerance is REPORTED, not
  // absorbed. Printed ALONGSIDE the probe, never instead of it.
  const FLOOR_CH_MULTIPLIER = 55;
  const FLOOR_ADDEND_PX = 80;
  const chInFloorPx = (minInlinePx && minInlinePx > FLOOR_ADDEND_PX)
    ? (minInlinePx - FLOOR_ADDEND_PX) / FLOOR_CH_MULTIPLIER
    : null;

  // ── the content box. clientWidth excludes borders and includes padding.
  const surfaceBorderBoxPx = surface.getBoundingClientRect().width;
  const contentPx = surface.clientWidth - padL - padR;

  // ── overflow against D39's real scroller, never .editor-panel, never body.
  const bodyScrollW = body.scrollWidth, bodyClientW = body.clientWidth;

  // ── panes, strips, crumbs. VISIBLE counts, not just DOM counts: at phone the
  //    pane columns are display:none, so a bare querySelectorAll overstates the
  //    routes a user actually has.
  const allPanes = [...document.querySelectorAll('.pane-column')];
  const visible = (e) => getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0;
  const paneColumns = allPanes.length;
  const paneColumnsVisible = allPanes.filter(visible).length;
  const paneWidths = allPanes.filter(visible).map((e) => round(e.getBoundingClientRect().width, 1));
  const allStrips = [...document.querySelectorAll('.pane-column--collapsed')];
  const strips = allStrips.length;
  const stripsVisible = allStrips.filter(visible).length;
  const stripIsButton = document.querySelectorAll('button.pane-column--collapsed').length;
  const stripAriaExpanded = allStrips.map((e) => e.getAttribute('aria-expanded'));
  const crumbsHost = document.querySelector('.bp-desk-crumbs');
  const crumbs = document.querySelectorAll('.bp-desk-crumb').length;
  const crumbsVisible = crumbsHost ? getComputedStyle(crumbsHost).display !== 'none' : false;

  // ── the inspector. Its geometry is still REPORTED in full, and the old
  //    subtraction it used to drive is still computed and printed as
  //    \`legacy_inspector_subtraction_px\` — but it no longer AUTHORS
  //    visible_content_px. That is now a hit-test (D112). Nothing here is
  //    erased; the two numbers sit side by side so the delta is readable.
  //
  //    THE DOCKED CASE IS NOT A MISSING SUBTRACTION. When the inspector is IN
  //    FLOW (computed position static/relative) it is a sibling column that
  //    already took its width out of the panel before the surface was laid out,
  //    so the surface's own content box is ALREADY the width the reader sees
  //    and subtracting again would double-count. On the DEPLOYED build this is
  //    the case at EVERY sub-wide width in the default state, not — as this
  //    comment claimed until D115 — "at exactly the two widths (1280, 1440)":
  //    spd-b29 turned the sub-wide overlay into a 41px in-flow strip, so
  //    \`width_px\` reads 300 at 1440/1280 and 41 at 1024 and below. The hit-test
  //    gets this right without being told, which is the point of it.
  const sidebar = document.querySelector('.bp-doc-sidebar');
  const sRect = surface.getBoundingClientRect();
  const padT = px(sCs.paddingTop), padB = px(sCs.paddingBottom);
  const borT = px(sCs.borderTopWidth), borB = px(sCs.borderBottomWidth);
  const contentLeft = sRect.left + borL + padL;
  const contentRight = sRect.right - borR - padR;
  const contentTop = sRect.top + borT + padT;
  const contentBottom = sRect.bottom - borB - padB;

  let inspector = { present: false };
  let legacySubtractionPx = null;
  if (sidebar) {
    const iCs = getComputedStyle(sidebar);
    const iR = sidebar.getBoundingClientRect();
    const overlapSurface = Math.max(0, Math.min(sRect.right, iR.right) - Math.max(sRect.left, iR.left));
    const overlapContent = Math.max(0, Math.min(contentRight, iR.right) - Math.max(contentLeft, iR.left));
    const overlays = iCs.position === 'absolute' || iCs.position === 'fixed';
    legacySubtractionPx = overlays ? contentPx - overlapContent : contentPx;
    inspector = {
      present: true,
      is_open_class: sidebar.classList.contains('is-open'),
      user_opened_marker: sidebar.hasAttribute('data-user-opened'),
      // D115: this used to read "server-default OPEN — this is the state a user
      // lands in". That is now FALSE below \`wide\`. The server assign
      // \`sidebar_open\` is still true, but spd-b29's
      // \`html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened])\`
      // rule paints that same open panel as a 41px in-flow strip with its title
      // and body \`display: none\`. So \`.is-open\` is a class, not a state, and
      // the state a user lands in is READ HERE rather than asserted in prose.
      default_state_note:
        'is_open_class is the CLASS, not the painted state: below the wide bucket spd-b29 paints ' +
        'an .is-open panel WITHOUT [data-user-opened] as a 41px in-flow strip (title/body display:none). ' +
        'inspector_state on this row says which state was actually measured.',
      position: iCs.position,
      display: iCs.display,
      width_px: round(iR.width),
      z_index: iCs.zIndex,
      overlays_surface: overlays,
      overlap_over_surface_px: round(overlapSurface),
      overlap_over_content_box_px: round(overlapContent),
    };
  }

  // ── the scrim is an ::after PSEUDO-ELEMENT on .editor-with-preview, and that
  //    is the whole difficulty: elementsFromPoint never returns a pseudo, and
  //    this one is also pointer-events:none, so it is doubly invisible to a
  //    hit-test until we force it. See the occlusion block below.
  const withPreview = document.querySelector('.editor-with-preview');
  let scrim = { host_present: !!withPreview, renders: false };
  const scrimCsBefore = withPreview ? getComputedStyle(withPreview, '::after') : null;
  const alphaOf = (bg) => {
    const m = String(bg).match(/rgba?\\(([^)]+)\\)/);
    if (!m) return null;
    const parts = m[1].split(/[,/]/).map((s) => parseFloat(s.trim()));
    return parts.length >= 4 && Number.isFinite(parts[3]) ? parts[3] : 1;
  };
  if (withPreview) {
    scrim = {
      host_present: true,
      renders: scrimCsBefore.content !== 'none' && scrimCsBefore.content !== 'normal',
      content: scrimCsBefore.content,
      position: scrimCsBefore.position,
      background: scrimCsBefore.backgroundColor,
      scrim_alpha: alphaOf(scrimCsBefore.backgroundColor),
      pointer_events: scrimCsBefore.pointerEvents,
      z_index: scrimCsBefore.zIndex,
    };
  }

  // ══ OCCLUSION BY DIFF (D112) ═══════════════════════════════════════════════
  //
  // visible_content_px answers exactly one question — CAN THE READER SEE THE
  // GLYPH AT ALL — and it answers it by hit-testing the content box rather than
  // by consulting a hand-maintained list of things that might be on top. The
  // list had exactly one entry and could not stay honest.
  //
  // The classification at each sampled point is an ANCESTRY test, never a name
  // match: if the topmost element is the surface or a descendant of it, the
  // reader sees the surface there. Anything else is covering it, whatever it is
  // called. (A name match would be actively wrong here: main.bp-paper-surface is
  // itself topmost at some sampled points, so a list would need exceptions to
  // its own exceptions.)
  //
  // Three outcomes, not two. A point outside the viewport cannot be hit-tested
  // at all — elementsFromPoint returns [] — and calling that "occluded" would
  // silently merge D113's horizontal-overflow failure into this one. It is
  // counted and reported separately as content_offscreen_px.
  const SCAN_COLUMNS = 48;
  const BISECT_TOL_PX = 0.5;
  const VIS = 0, OCC = 1, OFF = 2;

  const describe = (t) => {
    if (!t) return '(nothing — outside the viewport)';
    return t.tagName.toLowerCase() +
      (t.id ? '#' + t.id : '') +
      (t.className && typeof t.className === 'string'
        ? '.' + t.className.trim().split(/\\s+/).slice(0, 3).join('.') : '');
  };
  const describeAt = (x, y) => {
    if (x < 0 || y < 0 || x > window.innerWidth - 1 || y > window.innerHeight - 1) return '(offscreen)';
    const stack = document.elementsFromPoint(x, y);
    const top = stack[0] || null;
    return describe(top) +
      (top && (top === surface || surface.contains(top)) ? ' [surface or descendant]' : ' [OCCLUDER]');
  };

  const classifyAt = (x, y) => {
    if (x < 0 || y < 0 || x > window.innerWidth - 1 || y > window.innerHeight - 1) return OFF;
    const top = document.elementsFromPoint(x, y)[0] || null;
    if (!top) return OFF;
    return (top === surface || surface.contains(top)) ? VIS : OCC;
  };

  // Sub-pixel edges by bisection between adjacent disagreeing samples. The scan
  // step bounds what can be DETECTED (a feature narrower than one step can be
  // stepped over); the bisection bounds the PRECISION of every edge it finds.
  // Both are reported, because a px figure whose resolution is unstated is a
  // figure nobody can check.
  const scanLineAt = (y) => {
    const L = contentLeft, R = contentRight;
    if (!(R > L)) return null;
    const xs = [];
    for (let i = 0; i < SCAN_COLUMNS; i++) xs.push(L + ((i + 0.5) * (R - L)) / SCAN_COLUMNS);
    const cls = xs.map((x) => classifyAt(x, y));
    const bounds = [L];
    const labels = [];
    const edges = [];
    for (let i = 1; i < SCAN_COLUMNS; i++) {
      if (cls[i] === cls[i - 1]) continue;
      let lo = xs[i - 1], hi = xs[i];
      const loCls = cls[i - 1];
      while (hi - lo > BISECT_TOL_PX) {
        const mid = (lo + hi) / 2;
        if (classifyAt(mid, y) === loCls) lo = mid; else hi = mid;
      }
      const at = (lo + hi) / 2;
      // NAME THE ELEMENT ON EACH SIDE OF THE EDGE. The sampled-column occluder
      // list is 13px-grained and cannot identify a 1px-wide sliver; the first
      // live run found the hit-test edge sitting ~1.04px LEFT of the
      // inspector's own getBoundingClientRect().left and had no way to say
      // what was in the gap. An unexplained systematic offset in the headline
      // metric is exactly the kind of thing this epic has been burned by.
      edges.push({
        at_px: round(at), from: loCls, to: cls[i],
        left_of_edge: describeAt(lo, y),
        right_of_edge: describeAt(hi, y),
      });
      bounds.push(at);
      labels.push(loCls);
    }
    labels.push(cls[SCAN_COLUMNS - 1]);
    bounds.push(R);
    const acc = [0, 0, 0];
    for (let k = 0; k < labels.length; k++) acc[labels[k]] += bounds[k + 1] - bounds[k];
    return {
      y: round(y, 1),
      visible_px: round(acc[VIS]),
      occluded_px: round(acc[OCC]),
      offscreen_px: round(acc[OFF]),
      // What was ON TOP where the reader was covered — DISCOVERED, not matched.
      // This is diagnostic only: nothing above branches on it.
      occluders: [...new Set(xs.filter((x, i) => cls[i] === OCC)
        .map((x) => describe(document.elementsFromPoint(x, y)[0])))],
      edges,
    };
  };

  // ── WHERE TO PUT THE SCANLINES. This is the part that is easy to get wrong
  //    and was, on the first live run: clamping a scanline to the viewport edge
  //    put it on div.studio-footer, which reported 0px visible and — under a
  //    MIN headline — zeroed a row whose other two scanlines both read the
  //    correct 640px. A footer is HORIZONTAL chrome below the text. It does not
  //    narrow the reading COLUMN, which is the only thing this metric measures.
  //
  //    So: the band is the intersection of the content box with the viewport
  //    (never the viewport edge itself), and the lines sit at 10/30/50/70/90%
  //    INSIDE it. Five, not three, so the headline can be a MEDIAN — robust to
  //    two outlying lines, while a genuine full-height overlay (the case this
  //    epic is about) moves all five together and is not smoothed away at all.
  const bandTop = Math.max(contentTop, 0);
  const bandBottom = Math.min(contentBottom, window.innerHeight - 1);
  const bandHeight = bandBottom - bandTop;
  const SCANLINE_FRACTIONS = [0.1, 0.3, 0.5, 0.7, 0.9];
  const scanYs = bandHeight > 2
    ? [...new Set(SCANLINE_FRACTIONS.map((f) => round(bandTop + f * bandHeight, 1)))]
    : [];

  const naturalLines = scanYs.map(scanLineAt).filter(Boolean);

  // ── the forced sample. A pseudo-element has NO inline style, so the two
  //    mutate-measure-restore sites above (which set element.style) cannot
  //    reach it. An injected stylesheet can. This is a real deviation from this
  //    file's established pattern and is deliberate.
  //
  //    THE SELECTOR IS A LIABILITY AND IS TREATED AS ONE. It is copied from
  //    root.html.heex, and if that file's scrim selector moves, this rule
  //    silently matches nothing and every dimming figure quietly becomes zero —
  //    a vacuous pass, which for THIS metric would falsify the seal itself
  //    (D31/D39). The non-vacuity guard below is what makes the drift loud.
  //    THE LIMIT OF THIS, STATED PLAINLY: the forced sample forces exactly ONE
  //    known pointer-events:none occluder — the scrim. An ELEMENT occluder that
  //    is also pointer-events:none, and that nobody has written yet, would be
  //    invisible to BOTH samples and would silently not be subtracted. The
  //    ancestry test catches every normal overlay automatically; it does not
  //    catch an invisible-to-hit-testing one. Forcing pointer-events globally
  //    was considered and rejected: it would make every decorative
  //    pointer-events:none element (icons, gradients, rules) read as an
  //    occluder and the metric would collapse to noise. This is a real
  //    remaining hole and is named here rather than left for a verifier to find.
  const SCRIM_SELECTOR = '.editor-with-preview:has(.bp-doc-sidebar.is-open)::after';

  // Snapshot BEFORE injecting, as STRINGS. getComputedStyle returns a LIVE
  // object: holding one and reading it after the restore would compare the page
  // to itself and pass no matter what happened. That is the exact shape of
  // vacuous check this slice exists to abolish, so it is spelled out here.
  const DUMP_PROPS = ['content', 'position', 'inset', 'top', 'right', 'bottom', 'left',
                      'width', 'height', 'z-index', 'background-color', 'pointer-events'];
  const dump = (el, pseudo) => {
    if (!el) return null;
    const cs = getComputedStyle(el, pseudo || null);
    return DUMP_PROPS.map((p) => p + ':' + cs.getPropertyValue(p)).join(';');
  };
  const hostBeforeDump = dump(withPreview, null);
  const pseudoBeforeDump = dump(withPreview, '::after');

  const styleEl = document.createElement('style');
  styleEl.setAttribute('data-desk-measure', 'scrim-hit-test');
  styleEl.textContent = SCRIM_SELECTOR + ' { pointer-events: auto !important; }';
  document.head.appendChild(styleEl);

  const forcedPointerEvents = withPreview
    ? getComputedStyle(withPreview, '::after').pointerEvents : null;
  const forcedLines = scanYs.map(scanLineAt).filter(Boolean);

  styleEl.remove();

  // ── RESTORE IS ASSERTED, NOT ASSUMED. Byte-identical or the row is poison.
  const restoreCheck = {
    injected_rule: SCRIM_SELECTOR + ' { pointer-events: auto !important; }',
    sheet_removed: !document.querySelector('style[data-desk-measure]'),
    host_before: hostBeforeDump,
    host_after: dump(withPreview, null),
    pseudo_before: pseudoBeforeDump,
    pseudo_after: dump(withPreview, '::after'),
    pointer_events_natural: scrim.pointer_events ?? null,
    pointer_events_forced: forcedPointerEvents,
  };
  restoreCheck.host_identical = restoreCheck.host_before === restoreCheck.host_after;
  restoreCheck.pseudo_identical = restoreCheck.pseudo_before === restoreCheck.pseudo_after;
  restoreCheck.byte_identical =
    restoreCheck.sheet_removed && restoreCheck.host_identical && restoreCheck.pseudo_identical;

  // ── the numbers. visible = GEOMETRIC occlusion only (the natural sample).
  //    The worst scanline is the headline, because the reader reads every line
  //    and the narrowest one is what they actually get; all three are reported
  //    so a partial-height occluder is visible as a disagreement rather than
  //    averaged into invisibility.
  const median = (xs) => {
    const a = [...xs].sort((p, q) => p - q);
    return a.length ? a[Math.floor(a.length / 2)] : null;
  };
  const natVisible = naturalLines.map((l) => l.visible_px);
  const visibleContentPx = natVisible.length ? median(natVisible) : contentPx;
  const offscreenPx = naturalLines.length ? Math.max(...naturalLines.map((l) => l.offscreen_px)) : 0;
  // The spread is REPORTED, never smoothed. Five agreeing lines and five wildly
  // disagreeing ones must not print the same way: a disagreement means some
  // occluder covers part of the column's height, which is a real finding about
  // the desk and is exactly what a lone median would hide.
  const scanlineSpread = {
    min_px: natVisible.length ? Math.min(...natVisible) : null,
    max_px: natVisible.length ? Math.max(...natVisible) : null,
    disagreement_px: natVisible.length ? round(Math.max(...natVisible) - Math.min(...natVisible)) : null,
    all_px: natVisible,
    note:
      'headline is the MEDIAN of the scanlines. A full-height overlay — the case this epic exists ' +
      'for — moves every line together, so median == min == max and nothing is smoothed. A nonzero ' +
      'disagreement_px means something covers only PART of the column height (the first live run ' +
      'found div.studio-footer this way) and the per-line figures below say where.',
  };

  // ── the scrim's footprint IS THE DIFF, and only the diff. Not a name match,
  //    not the host's rect, not an assumption that inset:0 means "everything":
  //    the extra ground the forced sample loses is exactly the ground the scrim
  //    was covering invisibly.
  const dimmedByLine = naturalLines.map((nat, i) => {
    const f = forcedLines[i];
    if (!f) return null;
    return round(Math.max(0, f.occluded_px - nat.occluded_px));
  }).filter((v) => v !== null);
  const dimmedContentPx = dimmedByLine.length ? Math.max(...dimmedByLine) : 0;

  // ── THE NON-VACUITY GUARD (D31/D39). If the scrim renders, forcing its
  //    pointer-events MUST change the hit-test. If it does not, the injected
  //    selector has drifted out of sync with root.html.heex and every dimming
  //    figure in this run is a silent zero. That is not a number to publish
  //    with a caveat — it is a broken instrument, and the run must die.
  const scrimRenders = !!scrim.renders;
  const forcedDiffers = naturalLines.some((nat, i) =>
    forcedLines[i] && forcedLines[i].occluded_px > nat.occluded_px + BISECT_TOL_PX);
  const nonVacuity = {
    scrim_renders: scrimRenders,
    forced_sample_differs: forcedDiffers,
    scanlines_taken: naturalLines.length,
    // The guard only has an opinion where there IS a scrim to detect AND at
    // least one scanline was actually taken. Where the scrim does not render,
    // "no difference" is the CORRECT answer and proves nothing either way —
    // which is stated rather than dressed up as a pass. And where no scanline
    // could be placed (the content box and the viewport barely intersect) there
    // is no sample to differ, so firing the fatal guard there would kill a run
    // over a geometry problem while claiming a selector problem.
    guard_applies: scrimRenders && naturalLines.length > 0,
    guard_passed: (scrimRenders && naturalLines.length > 0) ? forcedDiffers : null,
    natural_occluded_px_by_line: naturalLines.map((l) => l.occluded_px),
    forced_occluded_px_by_line: forcedLines.map((l) => l.occluded_px),
    method:
      'the scrim renders on this row, so forcing pointer-events:auto on ' + SCRIM_SELECTOR +
      ' must make the hit-test lose ground it did not lose naturally. If it does not, the ' +
      'injected selector no longer matches root.html.heex and every dimming figure is a silent zero.',
  };

  scrim.covers_content_fully = scrimRenders && naturalLines.length > 0 &&
    forcedLines.every((l) => l && l.visible_px <= BISECT_TOL_PX);

  const pR = panel.getBoundingClientRect();

  // ── THE VERDICTS. Both are computed HERE, inside the scope that forced this
  //    row's face and measured this row's boxes with this row's own probe span.
  //    That is deliberate and structural: there is no place in this function
  //    where another face's px-per-ch is in scope, so the cross-face division
  //    that manufactured the false "1280 fails at 53.95ch Georgia" (D83/D86,
  //    overturn #7 averted) cannot be written here even by accident.
  //
  //    visible_meets_55ch is the verdict this epic seals on: the measure a
  //    reader actually SEES, against the same >=55ch bar as the layout measure.
  //    Neither is rounded toward the criterion — the comparison is on the raw
  //    ratio and only the REPORTED figure is rounded.
  const CRITERION_CH = 55;
  const contentCh = chProbePx > 0 ? contentPx / chProbePx : null;
  const visibleCh = chProbePx > 0 ? visibleContentPx / chProbePx : null;

  restore();

  return {
    fatal: false,
    // TRUE here by construction: this function returned {fatal:true} above if
    // the reading column was missing, so reaching this point means it is on
    // screen. The no-reading-column states go through PAGE_MEASURE_CHROME and
    // set this false with NULL ch — never 0.
    reading_column_present: true,
    counts,
    font: {
      declared_stack: fontFamilyDeclared,
      resolved_family: winner,
      resolution_method: winner
        ? 'advance-width equality vs each family in the declared stack (10x m + 10 digits, at the surface font-size)'
        : 'NO family in the declared stack reproduced the stack advance — resolved face UNKNOWN',
      font_size_px: round(fontSize),
      stack_advance_20ch_px: round(stackAdvance),
      // Did the face we asked for actually WIN, or did we fall through to a
      // fallback and quietly measure something else? The matrix must never
      // present a fallback reading as the named face.
      requested_primary: wantedFamilies[0] ?? null,
      face_applied: winner !== null && wantedFamilies.length > 0 && winner === wantedFamilies[0],
      // FONT PRESENCE, MEASURED. This was document.fonts.check(), which is not
      // a presence test at all: measured on this build it returns TRUE for
      // every local family it is asked about, including the invented control
      // 'Definitely Not A Real Font XYZQ' — 3 of 8 candidates wrong, every one
      // in the same direction. The consequence is already in the repository:
      // EVERY committed artifact under scripts/measurements/ carries loaded
      // true for all seven families, with no false anywhere in any run —
      // including 'Palatino Linotype' and 'Source Serif 4', neither of which is
      // installed on the measuring Mac (CDP CSS.getPlatformFontsForNode reports
      // Times for both). A column that is always true reads as evidence and
      // carries none, and it misreported precisely the face
      // spd-palatino-linotype-unmeasured exists to flag as never measured.
      //
      // A family is present iff naming it AHEAD of a generic changes the
      // advance versus that generic alone. Scored 8/8 against CDP ground truth
      // where fonts.check scored 5/8, the hard case being Palatino: present,
      // and metrically identical to Times New Roman.
      face_available: wantedFamilies.map((f) => ({ family: f, loaded: familyIsPresent(f) })),
      fell_back_to_generic_serif: winner === null || /^(serif|ui-serif)$/.test(String(winner)),
    },
    ch: {
      probe_px_per_ch: round(chProbePx, 4),
      probe_method: 'span[style="width:1ch"] inserted as a CHILD of .bp-paper-surface',
      in_floor_px_per_ch: round(chInFloorPx, 4),
      in_floor_method: minInlinePx
        ? \`(resolved min-inline-size - \${FLOOR_ADDEND_PX}) / \${FLOOR_CH_MULTIPLIER}\`
        : 'min-inline-size resolved to 0 — no in-floor ch to derive',
      in_floor_formula_assumed: \`calc(\${FLOOR_CH_MULTIPLIER}ch + \${FLOOR_ADDEND_PX}px)\`,
      divergence_pct: (chProbePx && chInFloorPx) ? round(((chInFloorPx - chProbePx) / chProbePx) * 100, 4) : null,
    },
    gutter: {
      padding_left_px: padL, padding_right_px: padR, total_px: padL + padR,
      border_left_px: borL, border_right_px: borR,
      method: 'getComputedStyle(.bp-paper-surface).paddingLeft/paddingRight — READ, never width-80 (D72/D78)',
    },
    panel_px: round(pR.width),
    surface_border_box_px: round(surfaceBorderBoxPx),
    surface_max_width_px: maxWidthPx,
    content_px: round(contentPx),
    visible_content_px: round(visibleContentPx),
    content_offscreen_px: round(offscreenPx),
    dimmed_content_px: round(dimmedContentPx),
    scrim_alpha: scrim.scrim_alpha ?? null,
    legacy_inspector_subtraction_px: legacySubtractionPx === null ? null : round(legacySubtractionPx),
    // The two methods side by side, with their disagreement stated as a number.
    // They are NOT expected to agree to the pixel — the legacy figure is pure
    // rectangle arithmetic on the inspector's own box, while the hit-test asks
    // what is actually on top and therefore also sees anything the arithmetic
    // never knew about. A delta is a FINDING, not noise to be smoothed.
    visible_vs_legacy_delta_px: legacySubtractionPx === null
      ? null : round(visibleContentPx - legacySubtractionPx),
    occlusion: {
      method:
        'hit-test by DIFF (D112). At each sampled point the topmost element is classified by ANCESTRY ' +
        '(is it .bp-paper-surface or a descendant?) — never matched against a list of known occluders. ' +
        'Each scanline is sampled at ' + SCAN_COLUMNS + ' columns across the content box and every ' +
        'class boundary is then bisected to +/-' + BISECT_TOL_PX + 'px.',
      resolution_note:
        'DETECTION is bounded by the scan step (content_px/' + SCAN_COLUMNS + ' px — an occluder ' +
        'narrower than one step can be stepped over entirely); PRECISION of every edge found is ' +
        'bounded by the bisection tolerance, +/-' + BISECT_TOL_PX + 'px. Both bound every px figure here.',
      scan_columns: SCAN_COLUMNS,
      bisect_tolerance_px: BISECT_TOL_PX,
      scan_step_px: round((contentRight - contentLeft) / SCAN_COLUMNS),
      scanlines_natural: naturalLines,
      scanlines_forced: forcedLines,
      scanline_placement:
        'five lines at 10/30/50/70/90% of the INTERSECTION of the content box with the viewport — ' +
        'never at the viewport edge, which on the first live run put a line on div.studio-footer and ' +
        'reported 0px visible for a row whose other lines both read the correct 640px',
      scanline_spread: scanlineSpread,
      headline_rule:
        'visible_content_px is the MEDIAN visible_px across the scanlines. Median, not min: horizontal ' +
        'chrome at the top or bottom of the column (a footer, a toast) does not narrow the reading ' +
        'COLUMN, and under a min rule one such line silently zeroes the row. Median, not mean: a real ' +
        'full-height overlay moves every line together and must not be diluted. scanline_spread carries ' +
        'the min, the max and the disagreement so nothing is hidden by the choice.',
      non_vacuity: nonVacuity,
      restore: restoreCheck,
    },
    measure_note:
      'content_px is the LAYOUT measure. visible_content_px is GEOMETRIC occlusion only, derived by ' +
      'hit-test diff (D112) — can the reader see the glyph at all. dimmed_content_px + scrim_alpha are ' +
      'reported SEPARATELY and are NEVER folded into visible_content_px (D111): the scrim dims, it does ' +
      'not hide, and counting it as occlusion would make visible 0px at every sub-wide user-opened width, ' +
      'so no seal could ever be taken there and the metric could no longer rank an improvement. ' +
      'legacy_inspector_subtraction_px is what the OLD one-entry-list subtraction would have said, kept ' +
      'beside the new number so the delta is readable and no history is erased.',
    criterion_ch: CRITERION_CH,
    content_ch: round(contentCh, 2),
    content_meets_55ch: contentCh === null ? null : contentCh >= CRITERION_CH,
    visible_ch: round(visibleCh, 2),
    visible_meets_55ch: visibleCh === null ? null : visibleCh >= CRITERION_CH,
    verdict_note:
      'Both ch figures divide THIS row\\'s box by THIS row\\'s own probe span, measured under THIS ' +
      'row\\'s forced face (D83/D86 — no cross-face division). visible_meets_55ch is the VISIBLE ' +
      'verdict; content_meets_55ch is the LAYOUT verdict. They are different questions.',
    floor: {
      min_inline_size_raw: minInlineRaw,
      min_inline_size_px: round(minInlinePx),
      binds: floorBinds,
      bind_test: 'measured, then min-inline-size forced to 0px inline and re-measured, then restored — a width change IS the bind',
      width_with_floor_px: round(widthWithFloor),
      width_without_floor_px: round(widthWithoutFloor),
    },
    overflow: {
      scroller: '.editor-body.bp-paper-body',
      scroll_width: bodyScrollW, client_width: bodyClientW,
      horizontal_scroll: bodyScrollW > bodyClientW,
      overflow_px: bodyScrollW - bodyClientW,
    },
    panes: {
      pane_columns: paneColumns,
      pane_columns_visible: paneColumnsVisible,
      visible_pane_widths_px: paneWidths,
      strips: strips,
      strips_visible: stripsVisible,
      strip_is_button: stripIsButton,
      strip_aria_expanded: stripAriaExpanded,
    },
    crumbs: { host_present: !!crumbsHost, visible: crumbsVisible, count: crumbs },
    inspector,
    scrim,
    width_bucket_stamped: document.documentElement.getAttribute('data-width-bucket'),
    scrollbar_width_px: window.innerWidth - document.documentElement.clientWidth,
    viewport_px: window.innerWidth,
  };
}
`;

/**
 * THE NO-READING-COLUMN MEASURE. For a state that legitimately has no
 * `.bp-paper-surface` on screen — the summoned destination being the first one.
 *
 * It is a SEPARATE function, not a branch inside PAGE_MEASURE, and that is a
 * deliberate trade. PAGE_MEASURE is ~600 lines of surface-derived arithmetic —
 * the gutter read, the ch probe, the floor-bind experiment, five bisected
 * scanlines, the scrim diff — every line of which needs the surface to exist.
 * Threading a `has it or not` flag through all of that would put a null-guard on
 * every one of those lines and give a future reader ~600 lines in which to
 * misplace one. Here, the absence is the shape of the function.
 *
 * EVERY READING-COLUMN FIGURE IS NULL, NEVER 0. `content_px: 0` and
 * `content_ch: 0` read as CATASTROPHIC OCCLUSION — the reader sees nothing —
 * which is a devastating claim about the desk and would be a fabricated one.
 * `null` says "there was nothing to measure here", the verdicts render `?`, and
 * a census counts the row as UNMEASURABLE rather than as a failure (D127 Part 2
 * forbids asserting FAIL where no reading column exists).
 *
 * What it DOES measure is real and worth having: the pane set, the strips, the
 * crumbs, the inspector's own geometry, the bucket. Those answer "what did the
 * reader get INSTEAD", which is the whole question a destination state exists
 * to ask.
 */
export const PAGE_MEASURE_CHROME = /* js */ `
() => {
  const px = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : null; };
  const round = (n, d = 3) => (n === null || n === undefined ? null : Math.round(n * 10 ** d) / 10 ** d);

  const surface = document.querySelector('${READING_COLUMN_SELECTOR}');
  const panel   = document.querySelector('.editor-panel');

  const counts = {
    '${READING_COLUMN_SELECTOR}':  document.querySelectorAll('${READING_COLUMN_SELECTOR}').length,
    '.editor-panel':              document.querySelectorAll('.editor-panel').length,
    '.editor-body.bp-paper-body': document.querySelectorAll('.editor-body.bp-paper-body').length,
  };

  const allPanes = [...document.querySelectorAll('.pane-column')];
  const visible = (e) => getComputedStyle(e).display !== 'none' && e.getBoundingClientRect().width > 0;
  const allStrips = [...document.querySelectorAll('.pane-column--collapsed')];
  const crumbsHost = document.querySelector('.bp-desk-crumbs');

  const sidebar = document.querySelector('.bp-doc-sidebar');
  let inspector = { present: false };
  if (sidebar) {
    const iCs = getComputedStyle(sidebar);
    const iR = sidebar.getBoundingClientRect();
    inspector = {
      present: true,
      is_open_class: sidebar.classList.contains('is-open'),
      user_opened_marker: sidebar.hasAttribute('data-user-opened'),
      position: iCs.position,
      display: iCs.display,
      width_px: round(iR.width),
      left_px: round(iR.left),
      z_index: iCs.zIndex,
      // With no reading column there is no surface to overlay. Reporting
      // \`overlays_surface: false\` would read as "it stays out of the reader's
      // way", which is a claim about a relationship that does not exist here.
      overlays_surface: null,
      overlap_over_surface_px: null,
      overlap_over_content_box_px: null,
    };
  }

  const withPreview = document.querySelector('.editor-with-preview');
  const scrimCs = withPreview ? getComputedStyle(withPreview, '::after') : null;
  const alphaOf = (bg) => {
    const m = String(bg).match(/rgba?\\(([^)]+)\\)/);
    if (!m) return null;
    const parts = m[1].split(/[,/]/).map((s) => parseFloat(s.trim()));
    return parts.length >= 4 && Number.isFinite(parts[3]) ? parts[3] : 1;
  };

  return {
    fatal: false,
    reading_column_present: false,
    reading_column_selector: '${READING_COLUMN_SELECTOR}',
    reading_column_absence_note:
      'This state DECLARES no reading column, so its absence is the measurement, not a failure. ' +
      'Every ch and px figure derived from the surface is NULL — never 0, which would read as ' +
      'catastrophic occlusion and is a claim about the desk this row cannot support. The verdicts ' +
      'render "?" (D127 Part 2: no FAIL where there is no reading column to fail).',
    counts,
    font: {
      declared_stack: null, resolved_family: null,
      resolution_method: 'no reading column on screen — no face to resolve',
      font_size_px: null, stack_advance_20ch_px: null,
      requested_primary: null, face_applied: null, face_available: [],
      fell_back_to_generic_serif: false,
    },
    ch: {
      probe_px_per_ch: null,
      probe_method: 'not taken — the ch probe is inserted as a CHILD of ' +
                    '${READING_COLUMN_SELECTOR}, which is not on screen in this state',
      in_floor_px_per_ch: null, in_floor_method: 'not derived', in_floor_formula_assumed: null,
      divergence_pct: null,
    },
    gutter: { padding_left_px: null, padding_right_px: null, total_px: null,
              border_left_px: null, border_right_px: null,
              method: 'not read — no surface to read padding from' },
    panel_px: panel ? round(panel.getBoundingClientRect().width) : null,
    surface_border_box_px: null,
    surface_max_width_px: null,
    content_px: null,
    visible_content_px: null,
    content_offscreen_px: null,
    dimmed_content_px: null,
    scrim_alpha: scrimCs ? alphaOf(scrimCs.backgroundColor) : null,
    legacy_inspector_subtraction_px: null,
    visible_vs_legacy_delta_px: null,
    // Null, not an empty structure: an occlusion block with zeroed scanlines
    // would be counted by the self-checks as a row where the hit-test ran.
    occlusion: null,
    measure_note:
      'chrome-only measurement (PAGE_MEASURE_CHROME). The hit-test, the ch probe, the gutter read, ' +
      'the floor-bind experiment and the scrim diff all require ' + '${READING_COLUMN_SELECTOR}' +
      ' and were not run. What IS measured — panes, strips, crumbs, inspector geometry, bucket — ' +
      'answers what the reader got INSTEAD of the column.',
    criterion_ch: 55,
    content_ch: null,
    content_meets_55ch: null,
    visible_ch: null,
    visible_meets_55ch: null,
    verdict_note:
      'Both verdicts are NULL and render "?". They are not FAIL: there is no reading column here to ' +
      'measure against 55ch, and asserting a failure against an absent element is the vacuous-pass ' +
      'disease (D31/D39) with its sign flipped.',
    floor: { min_inline_size_raw: null, min_inline_size_px: null, binds: null,
             bind_test: 'not run — no surface to force min-inline-size on',
             width_with_floor_px: null, width_without_floor_px: null },
    overflow: { scroller: '.editor-body.bp-paper-body', scroll_width: null, client_width: null,
                horizontal_scroll: null, overflow_px: null },
    panes: {
      pane_columns: allPanes.length,
      pane_columns_visible: allPanes.filter(visible).length,
      visible_pane_widths_px: allPanes.filter(visible).map((e) => round(e.getBoundingClientRect().width, 1)),
      strips: allStrips.length,
      strips_visible: allStrips.filter(visible).length,
      strip_is_button: document.querySelectorAll('button.pane-column--collapsed').length,
      strip_aria_expanded: allStrips.map((e) => e.getAttribute('aria-expanded')),
    },
    crumbs: {
      host_present: !!crumbsHost,
      visible: crumbsHost ? getComputedStyle(crumbsHost).display !== 'none' : false,
      count: document.querySelectorAll('.bp-desk-crumb').length,
    },
    inspector,
    scrim: withPreview
      ? { host_present: true,
          renders: scrimCs.content !== 'none' && scrimCs.content !== 'normal',
          content: scrimCs.content, position: scrimCs.position,
          background: scrimCs.backgroundColor, scrim_alpha: alphaOf(scrimCs.backgroundColor),
          pointer_events: scrimCs.pointerEvents, z_index: scrimCs.zIndex,
          covers_content_fully: null }
      : { host_present: false, renders: false },
    width_bucket_stamped: document.documentElement.getAttribute('data-width-bucket'),
    scrollbar_width_px: window.innerWidth - document.documentElement.clientWidth,
    viewport_px: window.innerWidth,
    surface_present: !!surface,
  };
}
`;

// ── settling ─────────────────────────────────────────────────────────────────
//
// The bucket is stamped pre-paint by an inline script, but the pane set and the
// phone breadcrumb are SERVER-rendered from a `width_bucket` assign that only
// arrives after the LiveView socket connects and the hook pushes it. Measure
// before that and you measure a transient. We wait for a structural signature
// to hold still, and report whether it actually did.

const SETTLE_SIGNATURE = /* js */ `() => {
  const panes = [...document.querySelectorAll('.pane-column')];
  return JSON.stringify({
    b: document.documentElement.getAttribute('data-width-bucket'),
    n: panes.length,
    w: panes.map((e) => Math.round(e.getBoundingClientRect().width)),
    c: document.querySelectorAll('.bp-desk-crumb').length,
    p: Math.round((document.querySelector('.editor-panel')?.getBoundingClientRect().width) || -1),
    // \`window.liveSocket\` is NOT exposed on this build (measured: undefined).
    // LiveView's own marker is the class it puts on the main element.
    connected: !!document.querySelector('[data-phx-main].phx-connected'),
  });
}`;

async function waitForDeskSettled(page, { quietMs = 800, timeoutMs = 20_000 } = {}) {
  const started = Date.now();
  let last = null, lastChange = Date.now(), connected = false;
  while (Date.now() - started < timeoutMs) {
    const sig = await page.evaluate((src) => eval(`(${src})`)(), SETTLE_SIGNATURE);
    const parsed = JSON.parse(sig);
    if (parsed.connected) connected = true;
    if (sig !== last) { last = sig; lastChange = Date.now(); }
    else if (connected && Date.now() - lastChange >= quietMs) {
      return { settled: true, settle_ms: Date.now() - started, live_socket_connected: true, signature: last };
    }
    await page.waitForTimeout(100);
  }
  return {
    settled: false,
    settle_ms: Date.now() - started,
    live_socket_connected: connected,
    signature: last,
    note: connected
      ? 'the desk never held still — this row is a moving target, not a measurement'
      : 'the LiveView socket never reported connected — the server-rendered pane set may be the pre-connect default',
  };
}

// ── entry states ─────────────────────────────────────────────────────────────

/** Every failure inside the drill is an INSTRUMENT failure, never a desk fact
 *  (D97). The wording is not decoration: three verifiers read a drill timeout as
 *  evidence about the desk, which is how a non-measurement gets recorded as a
 *  measurement. */
const drillDie = (msg, seen) =>
  dieRetryable('drill', `INSTRUMENT FAILURE (drill) — this says NOTHING about the desk's layout; ` +
      `the harness never reached a document to measure.\n\n  ${msg}` +
      (seen ? `\n\n  What the drill saw:\n${seen}` : '') +
      `\n\n  This is not a measurement and must not be recorded as one. Re-run, or pass ` +
      `--doc=<slug> to name a different document (--doc=any takes the first row that opens).`);

/** How the drill counts pane columns. A template string for the same reason
 *  PAGE_MEASURE is one — it is evaluated IN THE PAGE. */
export const PANE_COUNT = /* js */ `() => document.querySelectorAll('.pane-column').length`;

/**
 * EDGE-TRIGGERED, because quiescence is not arrival.
 *
 * `waitForDeskSettled()` is a QUIESCENCE detector: it returns as soon as its
 * structural signature has held still for `quietMs` (800ms) with the socket
 * connected. It structurally cannot tell "settled because the patch finished"
 * from "settled because the patch has not started" — and the pre-click desk is
 * already, trivially, still. Measured live against guerrilla on 2026-09-06 at
 * served sha 9a837ed38: after a real click on the "Papers" type row the second
 * `.pane-column` appears between t+1000ms and t+2000ms, i.e. AFTER the 800ms
 * quiet window has already fired. `openPapersPane` then read
 * `.pane-column.last()` and got the ROOT pane back.
 *
 * That is charter D138's "failure C" and its stderr has been misread ever
 * since: the drill reported `4 rows rendered. First 8 slugs: paper / sheet /
 * plugin-doclist-75745103 / rest` and the ledger row calls that "a PARTIALLY-
 * LOADED Papers list". It is not. Those five strings are DOCUMENT TYPES — the
 * root pane's own rows, which reach `[phx-click="select"]` through the `_`
 * catch-all `pane_item` in `studio_live/components.ex:1485`, exactly like a
 * document row does. A Papers list has 100 rows, never 4. The drill was
 * reading the wrong pane and naming the right one.
 *
 * So: read the count BEFORE the click and wait for it to GROW. `now` is
 * injectable so the wait can be proven without a browser — see
 * `scripts/studio-desk-drill-pane.test.mjs`.
 */
export async function waitForNewPane(page, before, opts = {}) {
  const { timeoutMs = 20_000, pollMs = 100, now = () => Date.now() } = opts;
  const started = now();
  for (;;) {
    const panes = await page.evaluate((src) => eval(`(${src})`)(), PANE_COUNT);
    if (panes > before) return { grew: true, panes, waited_ms: now() - started };
    if (now() - started >= timeoutMs) return { grew: false, panes, waited_ms: now() - started };
    await page.waitForTimeout(pollMs);
  }
}

/** Open the Papers list pane. Returns the pane locator. */
async function openPapersPane(page, base) {
  await page.goto(`${base}/w/default/p/default/d/production/studio`, { waitUntil: 'domcontentloaded' });
  await waitForDeskSettled(page);

  const typeItem = page.locator('.pane-column .pane-item', { hasText: 'Papers' }).first();
  if (await typeItem.count() === 0) {
    drillDie('the root desk rendered no "Papers" entry to drill into.');
  }
  const panesBefore = await page.evaluate((src) => eval(`(${src})`)(), PANE_COUNT);
  await typeItem.click();
  const grown = await waitForNewPane(page, panesBefore);
  if (!grown.grew) {
    drillDie(
      `clicking the "Papers" type row never added a pane column — ${panesBefore} before the click, ` +
      `${grown.panes} still after ${grown.waited_ms}ms. Every row the drill could have read would ` +
      `have come from the ROOT pane, whose rows are document TYPES and not documents.`);
  }
  await waitForDeskSettled(page);
  return page.locator('.pane-column').last();
}

/** One click-and-wait attempt at a located row. Resolves to the landed pathname,
 *  or null if no paper surface appeared. Never throws on a miss — a miss is data
 *  the caller uses to try the next candidate. */
async function tryOpenRow(page, row, { timeoutMs = 20_000 } = {}) {
  try {
    await row.click({ timeout: 10_000 });
    await page.waitForSelector('.bp-paper-surface', { timeout: timeoutMs });
    await waitForDeskSettled(page);
    const landed = new URL(page.url()).pathname;
    return /\/studio\/paper\/[^/]+$/.test(landed) ? landed : null;
  } catch {
    return null;
  }
}

/** Drill by CLICKING, exactly as a user does: root desk -> Papers -> document.
 *  Returns the document path the drill landed on, so both inspector states
 *  measure the very same document.
 *
 *  DETERMINISM (D97). The Papers list is ordered newest-first and concurrent
 *  epic waves publish into it continuously, so "the first row" is a moving
 *  target: 104 rows were observed and the first one changed between two runs of
 *  this very script. A named target is matched on `[phx-value-id]` — the slug
 *  the row carries — and the landed URL is asserted to carry that same slug, so
 *  the matrix cannot claim a document it did not measure. */
async function drillToDocument(page, base, requestedTarget) {
  const pane = await openPapersPane(page, base);
  const rows = pane.locator('[phx-click="select"]');
  const rowCount = await rows.count();

  // THE DEFAULT RESOLVES HERE, INSIDE THE PANE THE DRILL PROVED IT ENTERED, and
  // never from a committed slug (#16355 — see resolveDocTarget). It runs BEFORE
  // the generic empty-list check because `resolveNewestPaperSlug` owns that case
  // for this mode and says the one thing the generic message cannot: that the
  // refusal is a refusal to fall back to the root pane.
  //
  // Once resolved it becomes an ordinary NAMED target, so the newest row goes
  // through the same re-locate-per-attempt click, the same three-attempt budget
  // and — the part that matters — the same assertion that the landed URL
  // carries the slug we claim to have measured.
  let target = requestedTarget;
  let newest = null;
  if (target.mode === 'newest') {
    const slugs = await rows.evaluateAll((els) => els.map((e) => e.getAttribute('phx-value-id')));
    newest = resolveNewestPaperSlug(slugs);
    target = {
      mode: 'named',
      slug: newest.slug,
      source: target.source,
      resolution: 'newest-paper',
      requested_mode: 'newest',
    };
  }

  if (rowCount === 0) {
    drillDie('the Papers list pane rendered no [phx-click="select"] document row — nothing to open.');
  }

  /** WHY THE RUN CARRIES THIS AND NOT JUST A SLUG. "Which document" and "why was
   *  it reachable" are different questions, and only the second one survives the
   *  document itself ageing off the window. Recorded next to served_sha /
   *  requested_sha in the flattened artifact. */
  const docProvenance = () => ({
    measured_doc_source: target.resolution,
    measured_doc_requested_from: requestedTarget.source,
    measured_doc_reachability: newest
      ? `RESOLVED AT RUN TIME: the newest of the ${newest.rows_considered} row(s) the Papers pane ` +
        `rendered in this very run (${newest.rows_with_slug} carried a phx-value-id), read seconds ` +
        `before the click. It cannot have aged off a window it was just read from.`
      : requestedTarget.mode === 'any'
        ? `--doc=any: the first of the ${rowCount} rendered rows that opened a paper surface.`
        : `NAMED explicitly via ${requestedTarget.source} and found among the ${rowCount} rows this ` +
          `run's Papers pane rendered; the landed URL was asserted to carry the same slug.`,
    newest_resolution: newest,
  });

  // `select` is the document-open event. The pane header's own buttons
  // (airdrop-open / access-open / new-document) are NOT it — clicking those
  // opens a modal and the drill silently never happens.
  if (target.mode === 'named') {
    const attempts = [];
    for (let attempt = 1; attempt <= 3; attempt++) {
      // Re-locate every attempt: the list re-renders under us, and a handle
      // captured before a patch is exactly what made the old drill flaky.
      const named = pane.locator(`[phx-click="select"][phx-value-id="${target.slug}"]`).first();
      if (await named.count() === 0) {
        const visible = await rows.evaluateAll(
          (els) => els.slice(0, 8).map((e) => e.getAttribute('phx-value-id')));
        // WHICH pane produced these rows is part of the evidence. Without it,
        // a root-pane read (5 type rows) and a real Papers list (100 document
        // rows) print the same sentence — which is how D138's "failure C" was
        // diagnosed as a partially-loaded list for seven weeks.
        const paneCount = await page.evaluate((src) => eval(`(${src})`)(), PANE_COUNT);
        drillDie(
          `the Papers list has no row with phx-value-id="${target.slug}" ` +
          `(target came from the ${target.source}).`,
          `    ${paneCount} pane column(s) on screen; the last one rendered ${rowCount} ` +
          `[phx-click="select"] rows. First 8 phx-value-ids:\n` +
          visible.map((s) => `      ${s}`).join('\n') +
          `\n    A Papers list is ~100 rows, newest first. A handful of rows named after ` +
          `\n    document TYPES (paper / sheet / rest / ...) means this is the ROOT pane and the ` +
          `\n    drill never entered the list at all.` +
          `\n    If the target has simply aged off the 100-row window, pass --doc=<slug> with one of ` +
          `\n    these — or --doc=newest (the DEFAULT since #16355), which resolves the newest row of ` +
          `\n    this same list and so cannot age off it.`);
      }
      const landed = await tryOpenRow(page, named);
      if (landed) {
        const slugInUrl = decodeURIComponent(landed.split('/').pop());
        if (slugInUrl !== target.slug) {
          drillDie(
            `clicked the row for "${target.slug}" but landed on "${slugInUrl}" (${landed}). ` +
            `Refusing to label this run with a document it did not open.`);
        }
        return {
          path: landed,
          slug: slugInUrl,
          attempts: attempt,
          rows_in_list: rowCount,
          ...docProvenance(),
        };
      }
      attempts.push(`attempt ${attempt}: clicked the row, no .bp-paper-surface appeared`);
      await page.goto(`${base}/w/default/p/default/d/production/studio`, { waitUntil: 'domcontentloaded' });
      await waitForDeskSettled(page);
      await openPapersPane(page, base);
    }
    drillDie(
      `three attempts to open "${target.slug}" all failed to produce a .bp-paper-surface.`,
      attempts.map((a) => `      ${a}`).join('\n'));
  }

  // `--doc=any`: the historical first-row behaviour, but a row that does not
  // open a paper surface is SKIPPED rather than fatal. Some documents in this
  // list are not papers and never render the surface.
  const skipped = [];
  const budget = Math.min(rowCount, 10);
  for (let i = 0; i < budget; i++) {
    const row = pane.locator('[phx-click="select"]').nth(i);
    const slug = await row.getAttribute('phx-value-id');
    const landed = await tryOpenRow(page, row);
    if (landed) {
      return {
        path: landed,
        slug: decodeURIComponent(landed.split('/').pop()),
        attempts: i + 1,
        rows_in_list: rowCount,
        skipped_rows: skipped,
        ...docProvenance(),
      };
    }
    skipped.push(slug ?? '(no phx-value-id)');
    await page.goto(`${base}/w/default/p/default/d/production/studio`, { waitUntil: 'domcontentloaded' });
    await waitForDeskSettled(page);
    await openPapersPane(page, base);
  }
  drillDie(
    `none of the first ${budget} of ${rowCount} rows opened a paper surface (--doc=any).`,
    skipped.map((s) => `      skipped ${s}`).join('\n'));
}

// ── the user-opened state, reached the way a user reaches it ─────────────────

/**
 * Click `[data-test-id="sidebar-toggle-panel"]` for real, through the live
 * LiveView socket, until the SERVER stamps `data-user-opened` on the aside.
 *
 * WHY IT CAN TAKE TWO CLICKS, and why that is the handler being right rather
 * than this being a hack. `Handlers.Paper.sidebar_toggle_panel/1` resolves a
 * click against the `width_bucket` assign:
 *
 *   - at `wide` (>=1280) the panel is genuinely open, so the first click means
 *     CLOSE (`sidebar_open: false, sidebar_user_opened: false`) and the second
 *     means OPEN — and it is the second that stamps the marker;
 *   - below `wide` the panel is PAINTED closed while `sidebar_open` is still
 *     true, and the handler's `painted_closed?` branch makes one click mean
 *     OPEN, so the marker lands immediately.
 *
 * The sweep starts at 1440 (descending, D80), so it pays the two-click price
 * once. Rather than hardcode "two clicks at wide" — which would rot the moment
 * the handler changed — we click until the marker appears, with a hard cap, and
 * REPORT how many it took. A cap-exhausting failure is an INSTRUMENT failure
 * (D97): it says the harness never reached the state it names, and nothing
 * whatsoever about the desk's layout.
 */
// REVIEW FIX (wave 10). `fatal` decides whether an unreachable user-opened
// state kills the run or is reported as a named skip, and the two callers want
// OPPOSITE answers for the same reason D97 gives.
//
// The MATRIX sweep keeps `fatal: true`: a user-opened row it could not reach is
// not a desk fact, and inventing one is the thing D97 forbids.
//
// The ROUND TRIP passes `fatal: false`, because there the old behaviour
// reintroduced the exact defect this slice was filed to END. `runRoundTrip`
// runs mid-sweep, and nothing writes to disk until the provenance bracket
// closes — so one `die()` here discarded every row already collected and left
// a ZERO-BYTE run, which D138 rules an INSTRUMENT FAILURE rather than a desk
// fact. A missing toggle at one width must cost the round trip, never the
// matrix. This makes the open leg symmetric with `dismissInspectorByRealClick`,
// which already returned a named skip rather than throwing.
//
// ── AND THE FLAG WAS NOT ENOUGH (this wave, charter D178) ────────────────────
//
// The `fatal` seam above only governs the CONTROLLED exhaustion path inside
// `unreachable()`. It does nothing whatsoever about an exception thrown out of
// `.click()` by Playwright's own auto-wait — and this function used to guarantee
// one. It resolved ONE locator, `[data-test-id="sidebar-toggle-panel"]`, BEFORE
// its retry loop and never re-checked presence, while #5014 renames that same
// physical button to `sidebar-dismiss` the moment the destination predicate goes
// true (components.ex:425). The second iteration then clicked a locator matching
// nothing and sat in auto-wait until it timed out. Driven against a forcing
// fixture in a real chromium:
//
//     THREW after 11093ms / constructor = TimeoutError / instanceof MeasureError = false
//
// A RAW Playwright timeout, not this function's own named skip. And it threw
// IDENTICALLY at 11072ms with `fatal:false` — the exact mode `runRoundTrip`
// passes so that an unreachable toggle costs one pass instead of the matrix.
// `main()` has a `finally` but NO `catch`, and `writeRunArtifact` runs after that
// block exits normally, so the throw propagated to the top-level handler and
// NOTHING reached `--out`: D138's zero-byte run, back through a different door
// than the one wave 10 closed.
//
// WHY THE DISMISS LEG NEVER HAD THIS BUG, stated precisely because the imprecise
// version misleads: NOT because Playwright Locators are lazy (they are, whether
// or not the variable is reused — laziness is why the stale locator times out
// instead of throwing immediately). It is because `DISMISS_CONTROLS` is a
// PRIORITY LIST carrying BOTH spellings, resolved through `firstPresent()`. The
// open leg now has the same shape, and re-resolves INSIDE the loop: a rename
// between iterations is FOLLOWED (it is the same button, and the sweep would
// otherwise fail on a control that is plainly on screen), and a control that has
// vanished entirely routes through `unreachable()` — where `fatal` finally means
// what it says. Verified against the same fixture:
//
//     THREW after 1090ms / constructor = MeasureError / instanceof MeasureError = true
export const OPEN_CONTROLS = [
  { selector: '[data-test-id="sidebar-toggle-panel"]', grammar: 'the inspector toggle — the canonical open affordance' },
  { selector: '[data-test-id="sidebar-dismiss"]',      grammar: 'the SAME button under its Tier-3 destination spelling (#5014, components.ex:425)' },
];

// EXPORTED for the same reason `compareProvenance` is (see its note): a forcing
// repro must drive this leg directly against a fixture that renames the control
// between clicks, because a full authenticated sweep is far too heavy to be the
// only way to see the D178 fix hold. `scripts/measurements/open-leg-repro.mjs`.
export async function openInspectorByRealClick(page, { maxClicks = 3, fatal = true } = {}) {
  const unreachable = (reason) => {
    if (fatal) dieRetryable('user-opened-marker', reason);
    return { reached: false, skip_reason: reason };
  };

  const spellings = OPEN_CONTROLS.map((c) => c.selector).join(' or ');
  const control = await firstPresent(page, OPEN_CONTROLS);
  if (!control) {
    return unreachable(
      `INSTRUMENT FAILURE — no ${spellings} control on the page, so the ` +
      `user-opened state cannot be reached by a real click. This says NOTHING about the desk's ` +
      `layout. (If that control has genuinely gone missing, the inspector is unreachable and THAT ` +
      `is a desk finding — but it is spd-b29's finding to make, with a different instrument.)`);
  }

  const observe = () => page.evaluate(() => {
    const sb = document.querySelector('.bp-doc-sidebar');
    if (!sb) return null;
    const cs = getComputedStyle(sb);
    const r = sb.getBoundingClientRect();
    return {
      user_opened: sb.hasAttribute('data-user-opened'),
      is_open_class: sb.classList.contains('is-open'),
      position: cs.position,
      transform: cs.transform,
      left_px: Math.round(r.left * 100) / 100,
      width_px: Math.round(r.width * 100) / 100,
      z_index: cs.zIndex,
      bucket: document.documentElement.getAttribute('data-width-bucket'),
    };
  });

  const before = await observe();
  const clicks = [];
  const spellingsUsed = [];
  for (let i = 1; i <= maxClicks; i++) {
    // RE-RESOLVE EVERY ITERATION (D178). `firstPresent()` is a non-blocking
    // `.count()` probe across BOTH spellings — it never auto-waits, so a control
    // that is gone is answered in milliseconds instead of after a 10s timeout
    // that this function cannot convert into its own named failure.
    const now = i === 1 ? control : await firstPresent(page, OPEN_CONTROLS);
    if (!now) {
      return unreachable(
        `INSTRUMENT FAILURE — ${spellingsUsed[spellingsUsed.length - 1]} stopped matching after ` +
        `${i - 1} click(s), and neither ${spellings} is on the page any more, so there is no ` +
        `control left to click. The harness never reached the user-opened state, so it has NO ` +
        `user-opened measurement to report (D97). This is an INSTRUMENT fact and says nothing ` +
        `about the desk's layout.\n\n  What it saw after each click:\n` +
        clicks.map((c) => `      click ${c.click}: ${JSON.stringify(c.after)}`).join('\n'));
    }
    spellingsUsed.push(now.selector);
    await page.locator(now.selector).first().click({ timeout: 10_000 });
    // The marker comes back over the socket, not from the click — wait for the
    // round trip rather than for a fixed delay.
    await page.waitForTimeout(150);
    await waitForDeskSettled(page);
    const after = await observe();
    clicks.push({ click: i, control: now.selector, after });
    if (after?.user_opened) {
      return {
        reached: true,
        clicks_needed: i,
        control: now.selector,
        grammar: now.grammar,
        controls_clicked: spellingsUsed,
        method: `real click on ${now.selector} through the live LiveView socket — ` +
                'NOT a JS-set attribute. data-user-opened is server-stamped from the sidebar_user_opened ' +
                'assign, so a simulated attribute would prove only that the CSS works (D110). The ' +
                'control is re-resolved across both deployed spellings before EVERY click (D178), so ' +
                'the Tier-3 rename cannot leave this leg holding a locator that matches nothing.',
        before,
        after,
        click_log: clicks,
        note: i > 1
          ? `${i} clicks: at the wide bucket the panel is genuinely open, so the first click CLOSED it ` +
            `and the next re-opened it as an explicit user request — which is the one that stamps the marker.`
          : 'one click: below the wide bucket the panel is painted closed, so a click means OPEN.',
      };
    }
  }
  return unreachable(
    `INSTRUMENT FAILURE — ${maxClicks} real clicks on ${[...new Set(spellingsUsed)].join(' then ')} ` +
    `never produced [data-user-opened] on .bp-doc-sidebar. The harness never reached the user-opened ` +
    `state, so it has NO user-opened measurement to report — this is not a desk fact and must not be ` +
    `recorded as one (D97).\n\n  What it saw after each click:\n` +
    clicks.map((c) => `      click ${c.click} (${c.control}): ${JSON.stringify(c.after)}`).join('\n'));
}

// ── dismissal, the destination, and the round trip ───────────────────────────

/**
 * The controls that could DISMISS a user-opened inspector, in preference order.
 *
 * THE SWEEP USES TWO OF THESE, NOT ONE — this comment used to say "nothing
 * purpose-built is deployed yet", which stopped being true when #5086 shipped
 * `[data-test-id="sidebar-dismiss"]` on the Tier-3 destination. Today the six
 * destination widths (900 down to 500) dismiss through that purpose-built
 * control, and 1440/1280/1024 fall through to a toggle re-click — still a
 * genuine dismissal (the handler flips `sidebar_open`/`sidebar_user_opened`
 * back off). Which control was used is RECORDED PER WIDTH and rolled up by
 * control, never as one scalar borrowed from the widest row (D183), because
 * "returned bit-identical after a toggle re-click" and "returned bit-identical
 * after the purpose-built dismiss" are different findings about different
 * affordances and the artifact must not blur them.
 */
const DISMISS_CONTROLS = [
  { selector: '[data-test-id="sidebar-dismiss"]',      grammar: 'purpose-built dismiss control' },
  { selector: '[data-test-id="sidebar-close-panel"]',  grammar: 'purpose-built close control' },
  { selector: '[data-test-id="sidebar-toggle-panel"]', grammar: 'toggle re-click — the fallback where no purpose-built dismiss renders (wide/standard)' },
];

// DESTINATION_CONTROLS used to sit here — two selectors that summoned the third
// state, neither of which has ever existed on origin/main, plus a
// BP_DESK_DESTINATION_CONTROL env override to drive a build where they did.
// RETIRED with the state itself (D177): the destination is entailed by a server
// predicate, not summoned by a control, so there was nothing for a control list
// to point at. DESTINATION_MARKER survives, up beside the STATES table, because
// stamping a DERIVED flag from the server's own marker is what replaced it.

async function firstPresent(page, candidates) {
  for (const c of candidates) {
    try {
      if (await page.locator(c.selector).first().count() > 0) return c;
    } catch { /* a malformed selector is "not present", not a crash */ }
  }
  return null;
}

/**
 * Dismiss a user-opened inspector by a REAL click, until the SERVER drops
 * `data-user-opened`. Returns `{ dismissed: false, skip_reason }` rather than
 * throwing when no control is deployed — an absent affordance is a fact about
 * the build under test, not an instrument failure, and killing the run over it
 * would discard every row already collected.
 */
async function dismissInspectorByRealClick(page, { maxClicks = 3 } = {}) {
  const control = await firstPresent(page, DISMISS_CONTROLS);
  if (!control) {
    return {
      dismissed: false,
      skip_reason:
        'NO DISMISS CONTROL DEPLOYED. None of ' +
        DISMISS_CONTROLS.map((c) => c.selector).join(', ') + ' is on the page, so there is no way ' +
        'to leave the user-opened state by a real interaction. The dismissal grammar ships in ' +
        'inspector-dismissal-and-return-grammar; this pass is SKIPPED by name rather than faked ' +
        'with a reload (a reload builds a new socket and re-seeds sidebar_user_opened, which is a ' +
        'DIFFERENT protocol, not a dismissal — D110).',
      controls_tried: DISMISS_CONTROLS.map((c) => c.selector),
    };
  }

  const marker = () => page.evaluate(() =>
    !!document.querySelector('.bp-doc-sidebar[data-user-opened]'));
  const clicks = [];
  for (let i = 1; i <= maxClicks; i++) {
    await page.locator(control.selector).first().click({ timeout: 10_000 });
    await page.waitForTimeout(150);
    await waitForDeskSettled(page);
    const stillOpen = await marker();
    clicks.push({ click: i, user_opened_after: stillOpen });
    if (!stillOpen) {
      return {
        dismissed: true,
        control: control.selector,
        grammar: control.grammar,
        clicks_needed: i,
        click_log: clicks,
        method: 'real click through the live LiveView socket until the SERVER dropped ' +
                '[data-user-opened] — never a JS attribute removal, which would prove only that ' +
                'the CSS reacts (D110).',
      };
    }
  }
  return {
    dismissed: false,
    control: control.selector,
    grammar: control.grammar,
    skip_reason:
      `${maxClicks} real clicks on ${control.selector} never dropped [data-user-opened]. The ` +
      `inspector could not be dismissed by interaction on this build, so the round trip has no ` +
      `return leg to measure. This is a finding about the deployed dismissal grammar, reported ` +
      `rather than made fatal — a fatal here would discard every row already collected.`,
    click_log: clicks,
  };
}

/**
 * OBSERVE whether the desk is CURRENTLY in the Tier-3 destination — the
 * replacement for `enterDestinationState()`, which clicked a control that has
 * never existed (D177).
 *
 * Nothing here interacts. The destination is not somewhere the instrument goes;
 * it is a property of the state the instrument is already in, entailed by the
 * server predicate. So this READS the SERVER-stamped marker and returns it
 * beside the band-derived expectation, WITHOUT reconciling them: the marker is
 * what the row is stamped from (D110 — a client could never have written it),
 * and a disagreement with the predicate is a finding to raise, not a conflict to
 * quietly resolve in favour of either side.
 *
 * BOTH CONJUNCTS, OR NEITHER PREDICTS. The server predicate is `bucket in
 * ["narrow","phone"] AND sidebar_user_opened` — TWO conditions. The band half
 * alone would predict a destination for a DEFAULT-state row at narrow/phone,
 * where the panel was never opened and the server correctly stamps no marker, so
 * every such row would raise a spurious disagreement. `user_opened` is therefore
 * read from the live DOM too (`data-user-opened`, itself server-stamped), and the
 * prediction is the conjunction — mirroring the server exactly.
 */
async function observeDestination(page, width) {
  const { marker_present, user_opened } = await page.evaluate((sel) => ({
    marker_present: !!document.querySelector(sel),
    user_opened: !!document.querySelector('.bp-doc-sidebar[data-user-opened]'),
  }), DESTINATION_MARKER);
  const band_predicts = isDestinationBand(width) && user_opened;
  return {
    is_destination: marker_present,
    marker: DESTINATION_MARKER,
    marker_present,
    user_opened,
    band_predicts,
    band_name: bandNameFor(width),
    agrees: marker_present === band_predicts,
  };
}

/** The fields whose byte-identity IS the round trip's claim. Only reading-column
 *  figures: pane widths legitimately differ when the panel is dismissed at some
 *  widths, and folding those in would make the assertion fail for a reason that
 *  has nothing to do with the reader's column. */
const ROUND_TRIP_FIELDS = [
  ['content_px',   (r) => r.content_px],
  ['content_ch',   (r) => r.content_ch],
  ['px_per_ch',    (r) => r.ch?.probe_px_per_ch ?? null],
  ['visible_content_px', (r) => r.visible_content_px],
  ['visible_ch',   (r) => r.visible_ch],
  ['gutter_px',    (r) => r.gutter?.total_px ?? null],
];

/**
 * THE ROUND TRIP (net-new this wave). `default -> open -> dismiss`, on the SAME
 * PAGE INSTANCE, asserting the reading column comes back BIT-IDENTICAL per
 * width and face.
 *
 * WHY THE SAME INSTANCE MATTERS, and why this could not be assembled out of the
 * two sweeps that already exist. `default` is only ever measured by FRESH
 * NAVIGATION in this file — the two state sweeps are separated by a `page.goto`.
 * So today the instrument can say "a freshly-loaded desk reads 599px" and "an
 * opened desk reads 380px", and it CANNOT say what a reader gets after opening
 * the panel and closing it again. That is the question a dismissal grammar
 * lives or dies on: a return that leaves the column even 1px off is a desk that
 * quietly degrades every time the reader looks something up, and a reload would
 * paper over it (a reload builds a new socket and re-seeds the assign — a
 * different protocol, not an upgrade, D110).
 *
 * BASELINES AFTER THE FIRST WIDTH ARE THEMSELVES POST-DISMISS STATES, and that
 * is deliberate rather than sloppy: the sweep descends without reloading, so
 * each width's baseline is the desk as the previous round trip left it. Drift
 * that ACCUMULATES across trips shows up as a widening delta instead of being
 * reset away by a fresh load at every step.
 */
async function runRoundTrip(page, measureFace, run) {
  const widths = [];
  let cells = 0, identicalCells = 0, cellsWithdrawn = 0;

  for (const width of WIDTHS) {
    await page.setViewportSize({ width, height: 900 });
    await waitForDeskSettled(page);

    // D171/D185 INSIDE THIS LOOP, not only in the two-state sweep — and this is
    // the leg that needs it most. Every observed row until now came from the
    // sweeps; NO row has ever come from in here, and this pass is the one that
    // descends through nine widths WITHOUT a single reload, which is precisely
    // the shape the widen dead-band ambushes. The baseline is checked before the
    // trip, and again after the dismiss, because a bucket that moved DURING the
    // trip would make the before/after comparison a comparison of two tiers.
    const stampBefore = await readBucketStamp(page);
    const preBefore = recordBucketPrecondition(
      run, `round-trip baseline at viewport ${width}px`,
      bucketPrecondition(width, stampBefore.real_inner_width, stampBefore.width_bucket_stamped));

    const before = {};
    for (const face of FACES) before[face.id] = await measureFace(face);

    // Non-fatal here BY DESIGN — see the note on openInspectorByRealClick. A
    // width whose toggle cannot be reached costs this pass and nothing else;
    // the matrix rows already collected survive and still reach disk.
    const opened = await openInspectorByRealClick(page, { fatal: false });
    if (!opened.reached) {
      return {
        ran: false,
        skipped_at_viewport_px: width,
        skip_reason: opened.skip_reason,
        open_attempt: opened,
        note: 'SKIPPED BY NAME on the OPEN leg, never silently. There is no user-opened state to ' +
              'return from, so there is no round trip to measure. The matrix and every other pass ' +
              'in this run are unaffected, and the run still writes its artifact — a mid-sweep ' +
              'abort here would have discarded every collected row and written ZERO bytes, which ' +
              'D138 rules an INSTRUMENT FAILURE rather than a desk fact.',
      };
    }

    const dismissed = await dismissInspectorByRealClick(page);
    if (!dismissed.dismissed) {
      return {
        ran: false,
        skipped_at_viewport_px: width,
        skip_reason: dismissed.skip_reason,
        dismiss_attempt: dismissed,
        note: 'SKIPPED BY NAME, never silently. No return leg means no round trip to measure; the ' +
              'matrix and every other pass in this run are unaffected.',
      };
    }
    await waitForDeskSettled(page);

    const stampAfter = await readBucketStamp(page);
    const preAfter = recordBucketPrecondition(
      run, `round-trip post-dismiss at viewport ${width}px`,
      bucketPrecondition(width, stampAfter.real_inner_width, stampAfter.width_bucket_stamped));

    // D171/D185 REACHES THE CELLS, NOT JUST THE WARNING. A width whose stamp
    // disagreed with the raw band — on either leg — compared two readings that
    // may describe DIFFERENT TIERS, so its cells are no evidence about
    // round-trip fidelity. Counting them would let `returns_bit_identical` (the
    // headline this wave exists to establish) be computed partly over a
    // comparison of two different desks, which is the exact defect class the
    // sweep's verdict withdrawal already refuses. Withdrawn cells report
    // `identical: null` — never FALSE, the column may well have come back; we
    // simply did not measure it at the tier we name — and they are counted
    // separately so the withdrawal is visible rather than a quietly shrinking
    // denominator.
    const widthPreconditionOk =
      preBefore.bucket_precondition_ok && preAfter.bucket_precondition_ok;

    const faces = [];
    for (const face of FACES) {
      const after = await measureFace(face);
      const diffs = [];
      for (const [name, get] of ROUND_TRIP_FIELDS) {
        const b = get(before[face.id]), a = get(after);
        if (b !== a) diffs.push({ field: name, before: b, after: a });
      }
      if (widthPreconditionOk) {
        cells += 1;
        if (diffs.length === 0) identicalCells += 1;
      } else {
        cellsWithdrawn += 1;
      }
      faces.push({
        face: face.id,
        identical: widthPreconditionOk ? diffs.length === 0 : null,
        diffs,
        ...(widthPreconditionOk ? {} : {
          withdrawn_for_bucket_precondition: {
            expected_raw_band: preBefore.expected_raw_band,
            width_bucket_stamped: preBefore.width_bucket_stamped,
            recomputable_identical: diffs.length === 0,
            reason:
              'BUCKET PRECONDITION FAILED on this width, so this cell is not counted toward ' +
              'cells/identical_cells. The raw before/after figures are intact and the ' +
              'recomputed answer is preserved above, but the two legs may describe different ' +
              'tiers, which makes them no evidence about round-trip fidelity (D171/D185).',
          },
        }),
        before: Object.fromEntries(ROUND_TRIP_FIELDS.map(([n, g]) => [n, g(before[face.id])])),
        after: Object.fromEntries(ROUND_TRIP_FIELDS.map(([n, g]) => [n, g(after)])),
      });
    }

    widths.push({
      viewport_px: width,
      open_clicks: opened.clicks_needed,
      dismiss_clicks: dismissed.clicks_needed,
      dismiss_control: dismissed.control,
      dismiss_grammar: dismissed.grammar,
      bucket_precondition_ok: preBefore.bucket_precondition_ok && preAfter.bucket_precondition_ok,
      expected_raw_band: preBefore.expected_raw_band,
      real_inner_width: preBefore.real_inner_width,
      bucket_precondition_before: preBefore,
      bucket_precondition_after: preAfter,
      faces,
    });
  }

  return {
    ran: true,
    protocol: 'default -> open -> dismiss, on the SAME page instance, no reload at any point',
    // D183 — THE ROLLUP NO LONGER SPEAKS FOR WIDTHS IT NEVER SAW. This used to
    // be two scalars taken from `widths[0]`, which meant one 1440px row's
    // toggle re-click was published as the grammar of the whole sweep — and it
    // was flatly false about two thirds of it: 1440/1280/1024 dismiss via the
    // toggle, while every destination width (900 and below) dismisses via the
    // purpose-built [data-test-id="sidebar-dismiss"] that #5086 shipped. The
    // per-width data was always here; the defect was a summary that hid it.
    dismiss_grammar_by_width: widths.map((w) => ({
      viewport_px: w.viewport_px,
      control: w.dismiss_control,
      grammar: w.dismiss_grammar,
    })),
    dismiss_controls_used: [...new Set(widths.map((w) => w.dismiss_control))].map((control) => ({
      control,
      grammar: widths.find((w) => w.dismiss_control === control)?.dismiss_grammar ?? null,
      widths_px: widths.filter((w) => w.dismiss_control === control).map((w) => w.viewport_px),
    })),
    dismiss_grammar_note:
      'BY WIDTH, never one scalar. "Returned bit-identical after a toggle re-click" and "returned ' +
      'bit-identical after the purpose-built dismiss" are DIFFERENT findings about DIFFERENT ' +
      'affordances, and a sweep that used both must say so or it is claiming a coverage it does ' +
      'not have.',
    compared_fields: ROUND_TRIP_FIELDS.map(([n]) => n),
    cells,
    identical_cells: identicalCells,
    // COVERAGE IS PART OF THE CLAIM. `returns_bit_identical` gates the terminal
    // run, so it may never read true off a PARTIAL sweep: withdrawing a width
    // silently would shrink the denominator until the survivors all agreed and
    // the headline read true over a fraction of the desk. That is D184's
    // disease in a different organ — a thing that did not happen, certified as
    // a pass. Full coverage or the claim is not made. (`cells > 0` already
    // refuses the all-withdrawn case, where the denominator reaches zero.)
    cells_withdrawn_for_bucket_precondition: cellsWithdrawn,
    widths_withdrawn_for_bucket_precondition:
      widths.filter((w) => !w.bucket_precondition_ok).map((w) => w.viewport_px),
    returns_bit_identical: cells > 0 && identicalCells === cells && cellsWithdrawn === 0,
    widths,
    note:
      'Bit-identical means EVERY compared field matched exactly — not "within tolerance". These are ' +
      'the same rounded figures the matrix publishes, so a difference here is a difference a reader ' +
      'would be handed. Baselines after the first width are themselves post-dismiss states (no ' +
      'reload mid-pass), so accumulating drift widens rather than resetting.',
  };
}

/**
 * THE POSITIVE CONTROL — the affordance that makes the non-vacuity guard's zero
 * READABLE (D153).
 *
 * The trap it exists for: after this wave's fix, the scrim stops rendering, so
 * `guard_applies` goes to 0 and `summariseNonVacuity` stamps `vacuous: true`.
 * That zero is the PREDICTED AND REQUIRED outcome of a fixed desk. But "no
 * scrim because the desk was fixed" and "the injected selector drifted and the
 * guard never fired" produce a numerically IDENTICAL zero, and one of those is
 * excellent news while the other means every dimming figure in the run is a
 * silent lie.
 *
 * So: inject a synthetic scrim that DOES render (and is pointer-events:none,
 * exactly like the real one), take one row under it, and remove it. If the guard
 * fires there, the machinery demonstrably works and a zero everywhere else is
 * the desk. If it does NOT fire there, the injected selector has drifted and the
 * zero is instrument rot — which is precisely the discrimination a bare zero
 * cannot make.
 *
 * ITS ROW NEVER ENTERS `run.rows`. A synthetic row in the published matrix would
 * be a fabricated desk fact, which is the one thing this instrument exists to
 * make impossible. It lands in `run.positive_control` and nowhere else.
 */
const POSITIVE_CONTROL_RULE =
  '.editor-with-preview::after { content: "" !important; position: absolute !important; ' +
  'inset: 0 !important; background: rgba(0,0,0,0.55) !important; pointer-events: none !important; ' +
  'z-index: 40 !important; }';

async function runPositiveControl(page, measureFace) {
  const host = await page.locator('.editor-with-preview').first().count();
  if (host === 0) {
    return {
      ran: false,
      skip_reason:
        'no .editor-with-preview on the page to hang a control scrim on. That host selector is the ' +
        'same one the real scrim rule is anchored to, so its absence is itself the finding: the ' +
        'guard could not have fired in ANY row of this run, and a zero elsewhere is instrument ' +
        'drift rather than a fixed desk.',
    };
  }

  const handle = await page.addStyleTag({ content: POSITIVE_CONTROL_RULE });
  let rec;
  try {
    rec = await measureFace(FACES[0]);
  } finally {
    await handle.evaluate((el) => el.remove());
  }
  await waitForDeskSettled(page);

  const nv = rec.occlusion?.non_vacuity ?? null;
  return {
    ran: true,
    injected_rule: POSITIVE_CONTROL_RULE,
    face: FACES[0].id,
    scrim_rendered: !!rec.scrim?.renders,
    guard_applies: nv?.guard_applies ?? null,
    guard_passed: nv?.guard_passed ?? null,
    natural_occluded_px_by_line: nv?.natural_occluded_px_by_line ?? null,
    forced_occluded_px_by_line: nv?.forced_occluded_px_by_line ?? null,
    dimmed_content_px: rec.dimmed_content_px ?? null,
    row_excluded_from_matrix: true,
    verdict: nv?.guard_passed === true
      ? 'THE GUARD FIRES. The injected pointer-events rule demonstrably moves the hit-test on a ' +
        'scrim that renders, so a zero in the real rows means the desk rendered no scrim — not ' +
        'that the machinery is broken.'
      : 'THE GUARD DID NOT FIRE ON A SCRIM THAT DEMONSTRABLY RENDERS. The injected selector has ' +
        'drifted out of sync with root.html.heex and every dimming figure in this run is unproven. ' +
        'Do not read any zero in this run as good news.',
    note:
      'Synthetic by construction and NEVER pushed into run.rows. It answers one question only: is ' +
      'the guard capable of firing at all in this run — which is what tells a zero apart from a lie.',
  };
}

// ── spd-b29's two deferred criteria ──────────────────────────────────────────

/**
 * c2 (NO FLASH) and c3 (REACHABLE), both at viewport 1024, both single
 * observations spd-b29's builder explicitly deferred past merge. Diagnostic
 * output only — this function has no more gate authority than the rest of the
 * instrument (D81).
 *
 * c2 is the one that needs care. D12's refuted shape was a SERVER-seeded close
 * that painted the panel open for ~400ms before collapsing it, so "does it
 * flash" cannot be answered by looking at the settled DOM — by then any flash
 * is over. The sampler is installed at `document_start`, before the document
 * exists, and records the sidebar's painted geometry on EVERY animation frame
 * from first paint onward. A flash would appear as early frames at overlay
 * width followed by a transition to the strip.
 */
async function runB29Probes(page, base, docPath) {
  const PROBE_WIDTH = 1024;
  const SAMPLE_MS = 2500;

  await page.addInitScript(({ sampleMs }) => {
    window.__b29 = { frames: [], t0: performance.now(), sample_ms: sampleMs };
    const tick = () => {
      const sb = document.querySelector('.bp-doc-sidebar');
      const el = document.documentElement;
      if (sb) {
        const cs = getComputedStyle(sb);
        const r = sb.getBoundingClientRect();
        window.__b29.frames.push({
          t_ms: Math.round(performance.now() - window.__b29.t0),
          position: cs.position,
          width_px: Math.round(r.width * 100) / 100,
          left_px: Math.round(r.left * 100) / 100,
          display: cs.display,
          user_opened: sb.hasAttribute('data-user-opened'),
          is_open_class: sb.classList.contains('is-open'),
          bucket: el.getAttribute('data-width-bucket'),
        });
      }
      if (performance.now() - window.__b29.t0 < sampleMs) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, { sampleMs: SAMPLE_MS });

  await page.setViewportSize({ width: PROBE_WIDTH, height: 900 });
  await page.goto(base + docPath, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.bp-paper-surface', { timeout: 30_000 });
  await waitForDeskSettled(page);
  await page.waitForTimeout(SAMPLE_MS + 250);

  const frames = await page.evaluate(() => (window.__b29?.frames ?? []));

  // A "visible" frame is one where the panel is painted at overlay scale rather
  // than as the 41px strip. The threshold is stated, not hidden: the strip
  // measures ~41px and the overlay 300px, so 100px separates them with room to
  // spare either side.
  const OVERLAY_WIDTH_THRESHOLD_PX = 100;
  const sig = (f) => `${f.position}|${f.width_px}|${f.display}|${f.user_opened}`;
  let transitions = 0;
  for (let i = 1; i < frames.length; i++) if (sig(frames[i]) !== sig(frames[i - 1])) transitions++;
  const visibleFrames = frames.filter((f) => f.width_px >= OVERLAY_WIDTH_THRESHOLD_PX);

  const c2 = {
    criterion: 'spd-b29 c2 — NO FLASH: the inspector must never paint as an overlay before collapsing',
    viewport_px: PROBE_WIDTH,
    sampler: 'installed at document_start via addInitScript, sampling requestAnimationFrame from first paint',
    sample_window_ms: SAMPLE_MS,
    frames_captured: frames.length,
    first_frame: frames[0] ?? null,
    last_frame: frames[frames.length - 1] ?? null,
    overlay_width_threshold_px: OVERLAY_WIDTH_THRESHOLD_PX,
    overlay_frames: visibleFrames.length,
    overlay_frame_times_ms: visibleFrames.map((f) => f.t_ms),
    transitions,
    distinct_states: [...new Set(frames.map(sig))],
    flash_observed: visibleFrames.length > 0,
    note:
      'D12 measured the refuted server-seeded shape at ~400ms of panel-on-text on every document open. ' +
      'A flash would show as early frames at >=' + OVERLAY_WIDTH_THRESHOLD_PX + 'px followed by a ' +
      'transition down to the ~41px strip. overlay_frames counts them.',
  };

  // c3 — REACHABLE. The same real click the user-opened axis performs, taken
  // here at 1024 where the reachability question actually lives, with the
  // resulting geometry recorded.
  const beforeClick = await page.evaluate(() => {
    const sb = document.querySelector('.bp-doc-sidebar');
    const cs = getComputedStyle(sb);
    const r = sb.getBoundingClientRect();
    return { position: cs.position, transform: cs.transform,
             left_px: Math.round(r.left * 100) / 100, width_px: Math.round(r.width * 100) / 100 };
  });
  const opened = await openInspectorByRealClick(page);
  const c3 = {
    criterion: 'spd-b29 c3 — REACHABLE: the inspector must still be reachable at every width, proven by a real click',
    viewport_px: PROBE_WIDTH,
    before_click: beforeClick,
    after_click: opened.after,
    clicks_needed: opened.clicks_needed,
    control: '[data-test-id="sidebar-toggle-panel"]',
    method: opened.method,
  };

  return { c2, c3, probe_note: 'diagnostic only — no gate authority (D81)' };
}

// ── run ──────────────────────────────────────────────────────────────────────

async function main() {
  // ── PARSE THE IN-PAGE SOURCES FIRST, IN MILLISECONDS. Both measure functions
  //    are template STRINGS, so `node --check` on this file says NOTHING about
  //    them: a typo inside one is otherwise discoverable only after ssh, a
  //    minted 60s ticket, a login and a drill — i.e. at the most expensive
  //    possible moment, and (for the chrome measure) only on a build where the
  //    third state is actually reachable, which today is none of them. This
  //    costs nothing and moves that failure to the first millisecond, by name.
  for (const [name, src] of [['PAGE_MEASURE', PAGE_MEASURE], ['PAGE_MEASURE_CHROME', PAGE_MEASURE_CHROME]]) {
    try {
      // eslint-disable-next-line no-new-func
      new Function(`return (${src})`);
    } catch (e) {
      die(`${name} does not parse: ${e.message}\n\n  It is a template string, so \`node --check\` ` +
          `on this file cannot see it. Nothing was measured and nothing about the desk is implied.`);
    }
  }

  const { pw, resolvedFrom, version: pwVersion } = resolvePlaywright();
  const docTarget = resolveDocTarget();
  // PRE half of the bracket (D97). The POST half runs after the sweep and a
  // difference fails the run — see compareProvenance().
  const provenance = readProvenance();
  // THE PIN, CHECKED HERE AND NOWHERE LATER: this is the earliest point at
  // which the served SHA is known, and it is still before the browser launches,
  // before the ticket is minted and long before a row exists. A refusal from
  // here writes zero bytes, which is the whole point.
  assertServedShaPinned(SHA_PIN, provenance.served_sha);
  const srv = readGuerrillaServer();

  const browserPolicyChosen = browserPolicy();
  const browser = await launchMeasureBrowser(pw, browserPolicyChosen);
  const ctx = await browser.newContext({ viewport: { width: WIDTHS[0], height: 900 } });
  const page = await ctx.newPage();

  const run = {
    generated_at: new Date().toISOString(),
    instrument: 'scripts/studio-desk-measure.mjs',
    contract: 'prints a matrix, or exits non-zero naming the failed selector — no gate authority',
    playwright_version: pwVersion,
    playwright_resolved_from: resolvedFrom,
    // WHICH BROWSER MEASURED THIS. `ch` is a font measurement and bundled
    // Chromium is not system Chrome, so a run that does not name its browser
    // cannot be compared to one that does.
    browser_policy: browserPolicyChosen.id,
    browser_policy_source: browserPolicyChosen.source,
    browser_channel: browserPolicyChosen.channel,
    browser_version: browser.version(),
    node_version: process.version,
    platform: `${os.platform()} ${os.arch()}`,
    platform_note:
      'macOS overlay scrollbars: scrollbar_width_px is 0 here. A classic 15px-scrollbar ' +
      'platform removes ~15px from the panel at EVERY width, pushing viewport 1280 further ' +
      'under the criterion and moving gate-reachability from ~764px to ~779px (D83).',
    target: srv.base,
    sweep_direction: 'descending',
    sweep_note:
      'Descending (D80). The width-bucket dead-band is widen-only and re-anchors to the bucket ' +
      'currently held, so an ASCENDING sweep stamps viewport 640 as `phone`, 1024 as `narrow` ' +
      'and 1280 as `standard` — three of these nine widths. BOTH inspector states sweep descending ' +
      'and neither reloads mid-sweep: `user-opened` is a server assign that a reload resets, so a ' +
      'fresh-nav-per-row shortcut is a DIFFERENT protocol, not an upgrade. The one navigation between ' +
      'the states re-enters at 1440 from the raw band, which descending and reload agree on.',
    inspector_states_note:
      'The second axis is `inspector_state` (D110), and it is now a TABLE (`state_plan`) rather than ' +
      'a pair of string literals: each state declares its own required selectors, whether it has a ' +
      'reading column at all, and the widths it applies at. There are TWO of them, not three: the ' +
      'summoned `destination` state is RETIRED (D177) because the Tier-3 destination is ENTAILED by ' +
      'the server predicate rather than summoned, so user-opened rows at narrow/phone ALREADY ARE it ' +
      'and carry a derived `is_destination` with their visible verdict withdrawn to NULL — see ' +
      'destination_derivation. `default` = the desk as served. `user-opened` = ' +
      'after a REAL click on [data-test-id="sidebar-toggle-panel"] through the live LiveView socket — ' +
      'not a JS-set attribute, because `data-user-opened` is stamped by the SERVER from the ' +
      '`sidebar_user_opened` assign and a simulated attribute would prove only that the CSS works. ' +
      'It REPLACED `entry_state` ∈ {drilled, cold-load}, which was measured twice at nine widths and ' +
      'three faces and agreed in 54 of 54 cells both times: 27 rows per run spent re-proving that how ' +
      'the reader arrived does not matter, and zero rows on the axis that moves the answer by 219px. ' +
      'Neither state reloads mid-sweep — the marker is a server assign a reload would reset.',
    occlusion_note:
      'visible_content_px is GEOMETRIC occlusion, derived by HIT-TEST DIFF (D112): the topmost element ' +
      'at each sampled point is classified by ANCESTRY (surface or descendant?), never matched against ' +
      'a list of known occluders — the old list had exactly one entry and could not stay honest. The ' +
      'scrim is pointer-events:none AND a pseudo-element, so elementsFromPoint is doubly blind to it; ' +
      'every row is therefore sampled twice, once naturally and once with pointer-events forced via an ' +
      'INJECTED STYLESHEET, and the scrim\'s footprint is the DIFF. It is reported as dimmed_content_px ' +
      '+ scrim_alpha and NEVER folded into visible_content_px (D111) — the scrim dims, it does not hide. ' +
      'legacy_inspector_subtraction_px preserves what the old subtraction would have said.',
    faces_note:
      'Each face is ACTUALLY forced via --paper-font-serif on .bp-paper-surface and the WHOLE ' +
      'box re-measured under it. No ch figure anywhere divides one face box by another face ' +
      'advance (D75). Bare serif/ui-serif is banned as a probe face (D49).',
    doc_target: docTarget,
    doc_target_note:
      'The drill targets a NAMED document (D97). It used to click the first row of a Papers list ' +
      'that concurrent waves rewrite live, which made a failed run indistinguishable from a desk ' +
      'fact. There is no longer a COMMITTED default slug: one aged off the newest-100 window and ' +
      'made the bare invocation abort 1 of 1 (#16355), and any replacement literal would age off ' +
      'on the same clock. The default `newest` resolves the newest row of the Papers pane the ' +
      'drill just opened, then proceeds as a named target — same click, same assertion that the ' +
      'landed URL carries the slug — and an EMPTY pane refuses by name rather than falling back ' +
      'to the root pane. `--doc=<slug>` / BP_DESK_DOC name a document; `--doc=any` restores ' +
      'first-row behaviour, skipping rows that open no paper surface. Which document was chosen, ' +
      'by which source, and why it was reachable are in measured_doc / measured_doc_source / ' +
      'measured_doc_reachability.',
    provenance,
    // What the CALLER asked to measure, null when unpinned. `served_sha` says
    // what was measured; this says what was intended, so a reader never has to
    // reconstruct the difference from prose (D73).
    requested_sha: SHA_PIN?.requested ?? null,
    requested_sha_source: SHA_PIN?.source ?? null,
    provenance_note:
      'BRACKETED (D97): `provenance` is the PRE-sweep read and `provenance_post` the POST-sweep ' +
      'read of the same two facts. `provenance_bracket.matched` false means the run FAILED — a ' +
      'published matrix always carries a matched bracket. Each row also carries its own ' +
      '`measured_at`, so a mid-sweep rotation can be located in time rather than inferred.',
    // THE RUN PLAN. Which states this run intends to measure, which it skipped
    // and WHY. A skipped state contributes no rows and is subtracted from
    // expected_row_count, so "short because a state was unreachable" and
    // "short because the sweep died" are never the same number.
    state_plan: STATES.map((s) => ({
      id: s.id,
      has_reading_column: s.has_reading_column,
      required_selectors: s.required_selectors,
      applies_at_widths_px: WIDTHS.filter((w) => s.applies_at(w)),
      note: s.note,
    })),
    states_measured: [],
    states_skipped: [],
    state_axis_note:
      'Every state in `state_plan` that produced rows appears in `states_measured` AND in the human ' +
      'table. The table derives its state order FROM THE ROWS rather than from a hardcoded pair, and ' +
      'assertEveryStateRendered() is the tripwire on that derivation: a state present in rows but ' +
      'absent from the printed output is a HARD FAILURE. It used to be a silent drop — a synthetic ' +
      'third-state row went in and "destination" appeared zero times in the output with no error ' +
      'raised anywhere, which is a measurement paid for and then thrown away.',
    // D171/D185. Initialised EMPTY rather than lazily created, so a run that
    // asserted nothing reports `checked: 0` instead of omitting the block — an
    // absent precondition and a satisfied one must never read the same.
    bucket_precondition: emptyBucketPrecondition(),
    warnings: [],
    face_override_integrity: emptyFaceIntegrity(),
    rows: [],
  };

  try {
    // ── authenticate: mint immediately before navigating (60s TTL, single use).
    const ticket = await mintTicket(srv);
    await page.goto(`${srv.base}/login/ticket/${ticket}`, { waitUntil: 'domcontentloaded' });
    // LiveView holds a websocket open forever, so `networkidle` never settles.
    if (/\/login(\b|\/|$)/.test(new URL(page.url()).pathname)) {
      die(`login-ticket flow landed back on ${page.url()} — the session cookie was not set. ` +
          `Every number after this would be a measurement of a login page.`);
    }
    run.landed_authenticated_url = page.url();

    // ── drill in, the way a user reaches a document. This also fixes WHICH
    //    document both inspector states measure.
    await page.setViewportSize({ width: WIDTHS[0], height: 900 });
    const drill = await drillToDocument(page, srv.base, docTarget);
    const docPath = drill.path;
    run.drill = drill;
    run.measured_url = srv.base + docPath;
    // `measured_document` is the long-standing name and stays, byte-identical,
    // for every reader of a committed run in scripts/measurements/.
    // `measured_doc` is its short form and carries the two fields that make it
    // auditable: WHICH source chose it, and WHY that document was reachable.
    run.measured_document = drill.slug;
    run.measured_doc = drill.slug;
    run.measured_doc_source = drill.measured_doc_source ?? null;
    run.measured_doc_reachability = drill.measured_doc_reachability ?? null;

    // A BREADCRUMB ON STDERR, THE MOMENT IT IS KNOWN. The run JSON is written at
    // the very end, so a failure in any later stage (the b29 probe navigates
    // again, and the provenance bracket can still refuse) took the answer to
    // "which document did it measure" down with it — the exact question a
    // resolved default has to keep answering. stderr, never stdout: `--json`
    // promises stdout is nothing but the matrix.
    process.stderr.write(
      `\n  [drill] measured_doc ${run.measured_doc} · source ${run.measured_doc_source}\n` +
      `          ${run.measured_doc_reachability}\n\n`);

    /** One measurement against whatever is currently on screen, under one forced
     *  face. Shared by the sweep, the round trip and the positive control, so
     *  all three read the page through the SAME code path — a round trip that
     *  measured differently from the matrix would be comparing two instruments. */
    const measureFace = async (face) => page.evaluate(
      ({ src, override }) => eval(`(${src})`)(override),
      { src: PAGE_MEASURE, override: face.override },
    );

    /** One (width x face) block against whatever is currently on screen. */
    const sweepRow = async (width, stateId) => {
      const state = stateById(stateId);
      if (!state) die(`unknown inspector state "${stateId}" — not in the STATE table`);

      // PER-STATE (this wave). A state that declares no reading column asserts
      // NOTHING here: the flat module-level list used to assert the surface for
      // every state, so a legitimately column-less state aborted the whole
      // matrix — including the rows already collected, which are then lost
      // because nothing writes before the provenance bracket closes.
      for (const sel of state.required_selectors) {
        const n = await page.locator(sel).count();
        if (n === 0) {
          die(`SELECTOR MATCHED ZERO ELEMENTS at viewport ${width}px, state "${stateId}": \`${sel}\`. ` +
              `Refusing to report a number derived from an element that is not there. ` +
              `(Impossibility #1 — this is how D31 and D39 happened.) This state DECLARES it needs ` +
              `this selector (has_reading_column: ${state.has_reading_column}); a state that does ` +
              `not need it lists it nowhere and is recorded reading_column_present:false instead.`);
        }
      }
      const settle = await waitForDeskSettled(page);
      await page.evaluate(() => document.fonts.ready);

      // DERIVED, NOT SUMMONED (D177). Read once per (width x state) block, from
      // the SERVER's own marker, and cross-checked against the band predicate.
      // A disagreement is WARNED about by name rather than resolved silently:
      // the marker wins the stamp (it is the deployed truth), and the fact that
      // this instrument's model of the predicate disagreed with the server is
      // itself the finding — it means one of the two has drifted.
      const dest = await observeDestination(page, width);
      if (!dest.agrees) {
        run.warnings.push(
          `DESTINATION PREDICATE DISAGREEMENT at viewport ${width}px (band "${dest.band_name}"), ` +
          `state "${stateId}": the server ${dest.marker_present ? 'DID' : 'did NOT'} stamp ` +
          `${DESTINATION_MARKER}, but this instrument's band predicate — bucket in ` +
          `[${DESTINATION_BUCKETS.join(', ')}] AND user_opened, mirroring components.ex:111-113 — ` +
          `says it ${dest.band_predicts ? 'SHOULD' : 'should NOT'} have. Rows are stamped from the ` +
          `MARKER (D110), so the matrix is still honest; but either the deployed predicate moved or ` +
          `WIDTH_BANDS has drifted from the pre-paint stamp, and one of them needs re-reading.`);
      }

      for (const face of FACES) {
        const measured = state.has_reading_column
          ? await measureFace(face)
          : await page.evaluate((src) => eval(`(${src})`)(), PAGE_MEASURE_CHROME);
        // D127 PART 2, on the ROW rather than on a retired state: in the
        // destination the column is covered BY DESIGN, so its visible verdict is
        // WITHDRAWN to NULL. A FALSE there is an instrument defect — see
        // suppressVerdictForDestination().
        let rec = dest.is_destination ? suppressVerdictForDestination(measured) : measured;
        // D171/D185, on THIS row, before anything is read off it: does the tier
        // the page stamps agree with the raw band of the viewport it actually
        // got? A disagreement withdraws this row's verdicts and warns; it never
        // aborts (a mid-sweep abort writes zero bytes — D138).
        const bucketPre = recordBucketPrecondition(
          run, `viewport ${width}px, state "${stateId}", face ${face.id}`,
          bucketPrecondition(width, rec.viewport_px, rec.width_bucket_stamped));
        if (!bucketPre.bucket_precondition_ok) {
          rec = withdrawVerdictsForBucketPrecondition(rec, bucketPre);
        }
        if (rec.fatal) {
          dieRetryable('element-vanished', `a required element vanished mid-measure at viewport ${width}px, state "${stateId}", ` +
              `face ${face.id}: ${JSON.stringify(rec.counts)}`);
        }
        // A no-reading-column row has no ch, no face resolution, no hit-test and
        // no scrim diff, so every check below it would be asserting against
        // nulls. It is recorded as what it is and the row is closed here.
        if (rec.reading_column_present === false) {
          run.rows.push({
            measured_at: new Date().toISOString(),
            viewport_px: width,
            inspector_state: stateId,
            is_destination: dest.is_destination,
            destination_evidence: dest,
            bucket_precondition_ok: bucketPre.bucket_precondition_ok,
            expected_raw_band: bucketPre.expected_raw_band,
            real_inner_width: bucketPre.real_inner_width,
            bucket_precondition: bucketPre,
            user_opened_overlay_asserted: null,
            face: face.id,
            face_forced_to: face.override,
            face_note: 'recorded for matrix symmetry only — with no reading column on screen there ' +
                       'is no face to force and no advance to measure. face_relevant: false.',
            face_relevant: false,
            served_sha: provenance.served_sha,
            slot_active: provenance.slot_active,
            sweep_direction: 'descending',
            settle,
            ...rec,
          });
          continue;
        }
        // Bare serif/ui-serif is a BANNED probe face (D49): it measures
        // narrower than both real faces and INFLATES ch, masking the very bug
        // this matrix exists to catch. If a forced face fell through to it,
        // every ch in that row is poison — refuse rather than publish it.
        if (face.override && rec.font.fell_back_to_generic_serif) {
          die(`face "${face.id}" (${face.override}) fell through to generic serif at viewport ` +
              `${width}px, state "${stateId}". D49 BANS bare serif/ui-serif as a probe face — it ` +
              `inflates ch and would hand the next verifier a free overturn. Availability: ` +
              JSON.stringify(rec.font.face_available));
        }
        // The in-floor ch derivation ASSUMES the authored formula is
        // `calc(55ch + 80px)`; the browser only ever exposes the used px. The
        // two ch readings agree to ~0.107% today (D83). A drift past 2% means
        // the assumption has rotted — almost certainly because the floor's
        // formula changed (spd-w5-measure-lever-moves is chartered to change
        // it) — so it is REPORTED rather than silently published as a number.
        const drift = rec.ch.divergence_pct;
        if (drift !== null && Math.abs(drift) > 2) {
          run.warnings.push(
            `viewport ${width}px / ${stateId} / face "${face.id}": in-floor ch diverges from the ` +
            `probe by ${drift}% (assumed formula ${rec.ch.in_floor_formula_assumed}, resolved ` +
            `${rec.floor.min_inline_size_raw}). The floor's authored formula has probably changed — ` +
            `\`in_floor_px_per_ch\` in these rows is derived from a stale assumption. The probe ch ` +
            `(and every ch in the table above) is unaffected.`);
        }
        // D138 FAILURE A, RULED ON. This used to be a bare warning and the row
        // was published with its verdicts intact — i.e. a ch computed through a
        // face nobody asked for could carry a 55ch FALSE into a ruling cell.
        // Now the verdicts are withdrawn to NULL and the run carries a
        // machine-readable integrity block. See
        // `withdrawVerdictsForFaceSubstitution` and RULING 1 in the header.
        if (face.override) {
          rec = recordFaceSubstitution(run, `viewport ${width}px / ${stateId} / face "${face.id}"`, rec, face);
        }

        // ── THE NON-VACUITY GUARD IS FATAL (D31/D39/D112). Where the scrim
        //    renders, forcing its pointer-events MUST move the hit-test. If it
        //    does not, the injected selector no longer matches root.html.heex,
        //    every dimming figure in this run is a silent zero, and a vacuous
        //    pass on THIS metric would falsify the seal itself. There is no
        //    caveat that makes that publishable.
        const nv = rec.occlusion?.non_vacuity;
        if (nv?.guard_applies && !nv.forced_sample_differs) {
          die(`NON-VACUITY GUARD FAILED at viewport ${width}px, state "${stateId}", face ${face.id}. ` +
              `The scrim RENDERS here (content ${rec.scrim.content}, background ${rec.scrim.background}) ` +
              `but forcing pointer-events:auto on it changed the hit-test by nothing: natural occluded ` +
              `${JSON.stringify(nv.natural_occluded_px_by_line)}px vs forced ` +
              `${JSON.stringify(nv.forced_occluded_px_by_line)}px.\n\n` +
              `  The injected rule is:\n    ${rec.occlusion.restore.injected_rule}\n\n` +
              `  Almost certainly its selector has drifted out of sync with root.html.heex's scrim rule. ` +
              `A drifted selector is a SILENT no-op — every dimmed_content_px in this run would read 0 ` +
              `and look like good news. Re-sync the selector; do not publish this matrix.`);
        }

        // ── RESTORE MUST BE BYTE-IDENTICAL. This harness mutates a live page it
        //    then keeps measuring; a mutation it failed to undo is a state THIS
        //    HARNESS INVENTED, silently inherited by every row after it.
        const rst = rec.occlusion?.restore;
        if (rst && !rst.byte_identical) {
          die(`RESTORE FAILED at viewport ${width}px, state "${stateId}", face ${face.id} — the page was ` +
              `not returned to the state it was found in, so every row after this one would measure a ` +
              `page this harness invented.\n` +
              `  injected sheet removed: ${rst.sheet_removed}\n` +
              `  host identical:         ${rst.host_identical}\n` +
              `    before: ${rst.host_before}\n    after:  ${rst.host_after}\n` +
              `  pseudo identical:       ${rst.pseudo_identical}\n` +
              `    before: ${rst.pseudo_before}\n    after:  ${rst.pseudo_after}`);
        }

        // ── the user-opened state's own assertion. The marker being present is
        //    already fatal upstream (that is "did the click take"). THIS is the
        //    desk observation D108 turned on: below `wide`, an explicitly-opened
        //    inspector leaves flow and overlays the reading column. If that ever
        //    stops being true it is a DESK CHANGE — plausibly the successor
        //    slice's fix landing — so it is reported loudly rather than made
        //    fatal, which would leave the harness unable to measure a fixed desk.
        let overlayAsserted = null;
        if (stateId === 'user-opened' && rec.inspector.present) {
          overlayAsserted = rec.inspector.position === 'absolute';
          if (overlayShouldBeAbsolute(rec) && !overlayAsserted) {
            run.warnings.push(
              `viewport ${width}px / user-opened / face "${face.id}": bucket ` +
              `"${rec.width_bucket_stamped}" with panel ${rec.panel_px}px is inside the OVERLAY ` +
              `REGIME (${OVERLAY_REGIME}) and [data-user-opened] IS present, but the inspector ` +
              `reports position "${rec.inspector.position}", not "absolute". D108 measured absolute ` +
              `here and the Tier-2 ladder does not reach this far down. Either the desk changed or ` +
              `the marker is not doing what it did.`);
          }
        }

        run.rows.push({
          // Per-row wall clock (D97). Without it a bracket mismatch tells you
          // THAT the deployment moved but not WHICH rows straddle it.
          measured_at: new Date().toISOString(),
          viewport_px: width,
          // D110: this axis used to be `entry_state` ∈ {drilled, cold-load} —
          // how the reader ARRIVED — which agreed in 54 of 54 cells across two
          // runs. It is now the inspector's state, which moves the answer by
          // 219px on the single interaction this epic is about.
          inspector_state: stateId,
          // DERIVED from the SERVER's [data-inspector-destination] marker, not
          // from a state this instrument summoned (D177). The Tier-3
          // destination is entailed by the predicate — user-opened at
          // narrow/phone IS it — so it is a PROPERTY of a row, not a row of
          // its own.
          is_destination: dest.is_destination,
          destination_evidence: dest,
          // D171/D185: the tier this row CLAIMS to measure, checked against the
          // tier the page stamps. False withdraws the verdicts above.
          bucket_precondition_ok: bucketPre.bucket_precondition_ok,
          expected_raw_band: bucketPre.expected_raw_band,
          real_inner_width: bucketPre.real_inner_width,
          bucket_precondition: bucketPre,
          user_opened_overlay_asserted: overlayAsserted,
          face: face.id,
          face_forced_to: face.override,
          face_note: face.note,
          face_relevant: true,
          served_sha: provenance.served_sha,
          slot_active: provenance.slot_active,
          sweep_direction: 'descending',
          settle,
          ...rec,
        });
      }
      // Leave the native face on screen for whatever the next step measures.
      await page.evaluate(() => {
        const s = document.querySelector('.bp-paper-surface');
        if (s) s.style.removeProperty('--paper-font-serif');
      });
    };

    // ── STATE A — DEFAULT. As served. Descending (D80), no reload, no clicks.
    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 900 });
      await sweepRow(width, 'default');
    }
    run.states_measured.push('default');

    // ── STATE B — USER-OPENED. The state the epic was filed about: a reader who
    //    opens the panel to check metadata. Reached by a REAL click through the
    //    live socket, because `data-user-opened` is stamped by the SERVER from
    //    the `sidebar_user_opened` assign — setting the attribute from JS would
    //    prove the stylesheet works and nothing else (D110).
    //
    //    Re-navigate first: the sweep must restart at 1440 and widening from 500
    //    would drag the bucket dead-band's anchor up with it (D80). A fresh load
    //    re-stamps the bucket from the raw band, which is the state descending
    //    and reload both agree on.
    await page.setViewportSize({ width: WIDTHS[0], height: 900 });
    await page.goto(srv.base + docPath, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.bp-paper-surface', { timeout: 30_000 });
    if (/\/login(\b|\/|$)/.test(new URL(page.url()).pathname)) {
      die(`the document URL redirected to ${page.url()} — session lost between the two states`);
    }
    await waitForDeskSettled(page);
    run.user_opened_proof = await openInspectorByRealClick(page);

    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 900 });
      // The marker is a server assign and survives a viewport change — but if it
      // ever stops surviving one, every row after that point would silently be a
      // DEFAULT-state row wearing a user-opened label. Re-asserted per row.
      const stillOpen = await page.evaluate(() =>
        !!document.querySelector('.bp-doc-sidebar[data-user-opened]'));
      if (!stillOpen) {
        dieRetryable('user-opened-vanished', `INSTRUMENT FAILURE — the [data-user-opened] marker vanished at viewport ${width}px, ` +
            `between rows of the user-opened sweep. Every row after this would be a DEFAULT-state ` +
            `measurement labelled "user-opened", which is the exact class of mislabelling this ` +
            `axis was added to prevent. This says nothing about the desk's layout.`);
      }
      await sweepRow(width, 'user-opened');
    }
    run.states_measured.push('user-opened');

    // ── THERE IS NO STATE C, and its absence is the correction (D177).
    //    A third pass used to live here: re-navigate, click a purpose-built
    //    entry control, sweep the sub-wide widths as a `destination` state. It
    //    is gone, along with the state and the controls it clicked, because
    //    NONE OF THOSE CONTROLS HAS EVER EXISTED ON origin/main — the Tier-3
    //    destination is entailed by the server predicate (`bucket in
    //    ["narrow","phone"] and sidebar_user_opened`, components.ex:111-113),
    //    not summoned. The user-opened sweep that just ran at 900 through 500
    //    IS the destination, and every one of those rows is stamped
    //    is_destination:true from the server's own [data-inspector-destination]
    //    marker, with its visible verdict withdrawn to NULL rather than FALSE.
    //
    //    So this pass was never measuring a state the second pass missed. It
    //    was a duplicate that could only be reached through an env override,
    //    and its permanent skip-by-name read as diligence.
    //
    //    THE ARITHMETIC MOVES WITH IT. Two states x 9 widths x 3 faces = 54
    //    rows again, of which the six sub-1024 widths x 3 faces = 18 carry
    //    is_destination. Both numbers are DERIVED (expectedRowCount,
    //    expectedDestinationRowCount) and both are asserted below, so a run
    //    that stamps a different count is caught as arithmetic.
    run.destination_derivation = {
      summoned_state_retired: true,
      marker: DESTINATION_MARKER,
      buckets: DESTINATION_BUCKETS,
      expected_destination_rows: expectedDestinationRowCount(run.states_measured),
      note: destinationNote(),
    };

    // ── THE ROUND TRIP. default -> open -> dismiss on the SAME page instance.
    //    Fresh navigation first so the first baseline is a genuine as-served
    //    default rather than whatever the destination attempt left behind.
    if (ROUND_TRIP) {
      await page.setViewportSize({ width: WIDTHS[0], height: 900 });
      await page.goto(srv.base + docPath, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('.bp-paper-surface', { timeout: 30_000 });
      await waitForDeskSettled(page);
      run.round_trip = await runRoundTrip(page, measureFace, run);
    } else {
      run.round_trip = { ran: false, skip_reason: '--no-round-trip was passed' };
    }

    // ── THE POSITIVE CONTROL. Opt-in, synthetic, and never in run.rows.
    if (POSITIVE_CONTROL) {
      await page.setViewportSize({ width: 1024, height: 900 });
      await page.goto(srv.base + docPath, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector('.bp-paper-surface', { timeout: 30_000 });
      await waitForDeskSettled(page);
      run.positive_control = await runPositiveControl(page, measureFace);
    } else {
      run.positive_control = {
        ran: false,
        skip_reason:
          '--positive-control was not passed. Without it, a non-vacuity guard that applies in ZERO ' +
          'rows cannot be told apart from a guard that is broken: "no scrim because the desk was ' +
          'fixed" and "the injected selector drifted" are the same zero. Pass it whenever you intend ' +
          'to quote a zero as good news.',
      };
    }

    // ── spd-b29's two deferred criteria. This is the only authenticated
    //    Chromium in the wave, and both are single observations its builder
    //    could not take before merge. Diagnostic output, no gate authority.
    run.b29_probes = await runB29Probes(page, srv.base, docPath);
  } finally {
    await browser.close();
  }

  // ── CLOSE THE BRACKET (D97). The sweep is over; re-read the two facts every
  //    row was stamped with. If either moved, every row's provenance is a claim
  //    the run cannot support, so the run FAILS rather than publishing a matrix
  //    whose stamps are fiction. A ~30-60s run is cheap enough to discard.
  const provenancePost = readProvenance();
  const mismatches = compareProvenance(provenance, provenancePost);
  run.provenance_post = provenancePost;
  run.provenance_bracket = {
    matched: mismatches.length === 0,
    mismatches,
    window_ms: Date.parse(provenancePost.read_at) - Date.parse(provenance.read_at),
    method: 'served SHA + active slot read over ssh immediately before the browser launched and immediately after the sweep',
  };
  if (mismatches.length) {
    dieRetryable('provenance-bracket', `PROVENANCE BRACKET FAILED — the deployment moved UNDER the sweep, so all ` +
        `${run.rows.length} records carry a provenance stamp this run cannot support. ` +
        `Discarding the matrix.\n\n` +
        mismatches.map((m) => `  - ${m}`).join('\n\n') +
        `\n\n  Window: ${provenance.read_at} -> ${provenancePost.read_at} ` +
        `(${Math.round((Date.parse(provenancePost.read_at) - Date.parse(provenance.read_at)) / 1000)}s). ` +
        `Every row carries its own \`measured_at\`, so a partial salvage is possible — but this ` +
        `harness will not do it silently. Wait for the deploy to finish and re-run.`);
  }

  // The contract is "it prints a matrix". The JSON matrix IS the deliverable;
  // the human table is a convenience rendered from it. A formatting bug in the
  // table (one null where a number was expected, at the very end of an
  // authenticated run) must never destroy the data the run was for — so the
  // table is best-effort and says so on stderr if it fails.
  // ── THE SILENT DROP DIES HERE, OUTSIDE THE TABLE'S TRY/CATCH. The printer's
  //    own assertion is defence in depth, but it runs INSIDE a best-effort
  //    catch that (correctly) refuses to let a formatting bug destroy the data
  //    — which would have downgraded a dropped state back to a stderr note.
  //    A state measured at the cost of an authenticated sweep and then not
  //    shown is a HARD FAILURE, so it is asserted here where nothing catches it.
  assertEveryStateRendered(run, new Set(orderedStates(run)));

  // A short run is a caveat, not a death: every row already collected is good,
  // and dying here would discard the whole matrix — the all-or-nothing abort
  // this wave exists to end. It is stated loudly and carried into the artifact.
  const expectedRows = expectedRowCount(run.states_measured);
  if (run.rows.length !== expectedRows) {
    run.warnings.push(
      `ROW COUNT MISMATCH: collected ${run.rows.length}, expected ${expectedRows} — computed as ` +
      `${WIDTHS.length} widths x ${FACES.length} faces x the states applicable at each width, for ` +
      `the states this run actually measured (${run.states_measured.join(', ') || 'none'}). ` +
      `Skipped states are excluded from the expectation, so this mismatch is NOT a skipped state; ` +
      `something stopped early. ${rowCountNote(run.states_measured)}`);
  }

  if (!JSON_ONLY) {
    try {
      printTable(run);
    } catch (e) {
      process.stderr.write(
        `\n  [table] the human table failed to render: ${e?.message || e}\n` +
        `  The JSON matrix below is unaffected and is the authoritative record.\n\n`);
    }
  }
  if (OUT_PATH) writeRunArtifact(run, OUT_PATH);

  process.stdout.write(JSON.stringify(run, null, 2) + '\n');
  return run;
}

/** Persist the COMPLETE run — every row plus a flattened run-level provenance
 *  block — to disk (D131).
 *
 *  Why this exists: the instrument's first two waves could print a 54-row matrix
 *  and nothing else. The wave-7 sweep therefore survives only as prose pasted
 *  into a closed task's evidence field, with `viewport 500 / user-opened` blank
 *  at byte level — a first-party data gap nobody can now go back and fill. A
 *  table that cannot be retrieved gets re-derived, wrongly, by whoever needs it
 *  next, which is this epic's chronic disease wearing a different hat.
 *
 *  `artifact` is a CONVENIENCE header, not a second source of truth: every field
 *  in it is copied from the record below it, so a reader answering "what SHA,
 *  which slot, how many rows, did the bracket hold" does not have to reassemble
 *  them from four places and get one wrong. The full record stays authoritative.
 *
 *  It writes AFTER the provenance bracket closes, by design: a run that failed
 *  the bracket calls `die()` and never reaches here, so no file on disk can ever
 *  carry an unbracketed matrix. */
function writeRunArtifact(run, outPath) {
  run.artifact = {
    written_to: outPath,
    written_at: new Date().toISOString(),
    // Proof the run came from a real repo checkout and not a copy under /tmp
    // — which, before D130 was fixed, was where it silently did nothing.
    invoked_from_cwd: process.cwd(),
    instrument_realpath: realResolve(fileURLToPath(import.meta.url)),
    argv: process.argv.slice(1),
    row_count: run.rows.length,
    // COMPUTED, from the states this run actually attempted (D121's doctrine
    // without D121's literal — which was `... * 2` and would have quietly
    // under-counted the moment a third state existed).
    expected_row_count: expectedRowCount(run.states_measured),
    expected_row_count_if_no_state_skipped: expectedRowCount(),
    row_count_matches_expected: run.rows.length === expectedRowCount(run.states_measured),
    row_count_note: rowCountNote(run.states_measured),
    // THE DESTINATION IS ARITHMETIC NOW, not a state that either ran or skipped
    // (D177). Stating the expectation beside the observation is the whole point:
    // a run whose marker-derived count differs from the band-derived one is
    // caught as a number, and `destination_verdicts_withdrawn_all_null` is the
    // D127-part-2 tripwire — a single FALSE surviving in a destination row is an
    // INSTRUMENT defect, so it is asserted rather than assumed.
    destination_row_count: run.rows.filter((r) => r.is_destination).length,
    expected_destination_row_count: expectedDestinationRowCount(run.states_measured),
    destination_row_count_matches_expected:
      run.rows.filter((r) => r.is_destination).length ===
      expectedDestinationRowCount(run.states_measured),
    destination_verdicts_withdrawn_all_null:
      run.rows.filter((r) => r.is_destination).every((r) => r.visible_meets_55ch !== false),
    destination_note: destinationNote(),
    bucket_precondition_checked: run.bucket_precondition?.checked ?? 0,
    bucket_precondition_agreed: run.bucket_precondition?.agreed ?? 0,
    bucket_precondition_all_agreed:
      (run.bucket_precondition?.checked ?? 0) > 0 &&
      run.bucket_precondition.checked === run.bucket_precondition.agreed,
    states_measured: run.states_measured,
    states_skipped: run.states_skipped,
    states_in_rows: [...new Set(run.rows.map((r) => r.inspector_state))],
    round_trip: run.round_trip
      ? {
          ran: run.round_trip.ran,
          returns_bit_identical: run.round_trip.returns_bit_identical ?? null,
          identical_cells: run.round_trip.identical_cells ?? null,
          cells: run.round_trip.cells ?? null,
          cells_withdrawn_for_bucket_precondition:
            run.round_trip.cells_withdrawn_for_bucket_precondition ?? null,
          dismiss_controls_used: run.round_trip.dismiss_controls_used ?? null,
          skip_reason: run.round_trip.skip_reason ?? null,
        }
      : null,
    positive_control: run.positive_control
      ? {
          ran: run.positive_control.ran,
          guard_passed: run.positive_control.guard_passed ?? null,
          skip_reason: run.positive_control.skip_reason ?? null,
        }
      : null,
    served_sha: run.provenance?.served_sha ?? null,
    requested_sha: run.requested_sha ?? null,
    slot_active: run.provenance?.slot_active ?? null,
    provenance_pre_read_at: run.provenance?.read_at ?? null,
    provenance_post_read_at: run.provenance_post?.read_at ?? null,
    provenance_bracket_matched: run.provenance_bracket?.matched ?? null,
    sweep_direction: run.sweep_direction,
    doc_target: run.doc_target,
    measured_document: run.measured_document ?? null,
    measured_doc: run.measured_doc ?? run.measured_document ?? null,
    measured_doc_source: run.measured_doc_source ?? null,
    measured_doc_reachability: run.measured_doc_reachability ?? null,
    drill_attempts: run.drill?.attempts ?? null,
    drill_rows_in_list: run.drill?.rows_in_list ?? null,
    non_vacuity_guard: summariseNonVacuity(run),
    warnings: run.warnings,
    face_override_integrity: run.face_override_integrity,
    unsettled_rows: run.rows.filter((r) => !r.settle?.settled).length,
  };

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  const bytes = JSON.stringify(run, null, 2) + '\n';
  fs.writeFileSync(outPath, bytes);

  // stderr, never stdout: `--json` promises stdout is nothing but the matrix,
  // and a helpful line that breaks `| jq` is not helpful.
  process.stderr.write(
    `\n  [artifact] wrote ${run.rows.length} rows (${bytes.length} bytes) to ${outPath}\n` +
    `             sha ${run.artifact.served_sha} · slot ${(run.artifact.slot_active || []).join(', ') || 'NONE'} · ` +
    `bracket ${run.artifact.provenance_bracket_matched ? 'MATCHED' : 'MISMATCH'} · ` +
    `guard ${run.artifact.non_vacuity_guard.applies_in_rows} applies / ${run.artifact.non_vacuity_guard.passed_in_rows} passed\n\n`);
}

/** The non-vacuity guard's standing, as a structure rather than a sentence — so
 *  a later reader can filter on it instead of parsing the human table. `applies`
 *  0 is NOT a pass; it means no scrim rendered anywhere and the guard proved
 *  nothing, which is exactly the state that must never be mistaken for good
 *  news (D31/D39/D112). */
export function summariseNonVacuity(run) {
  // Only rows that actually ran the hit-test can have an opinion. A
  // no-reading-column row has `occlusion: null` and must not sit in the
  // denominator pretending to be a row where the guard could have fired.
  const hitTested = run.rows.filter((r) => r.occlusion?.non_vacuity);
  const applies = hitTested.filter((r) => r.occlusion.non_vacuity.guard_applies);
  const passed = applies.filter((r) => r.occlusion.non_vacuity.forced_sample_differs);

  // ── THE TWO ZEROS. `applies_in_rows: 0` has two utterly different causes and
  //    they are numerically identical, which is why the note has to say which:
  //
  //      A. THE DESK WAS FIXED. The scrim's HOST (.editor-with-preview) is on
  //         screen and the CSS simply chose not to render the ::after. That is
  //         this wave's PREDICTED AND REQUIRED outcome — the successor shape
  //         stops covering the reader — and the zero is good news.
  //      B. THE GUARD NEVER RAN. The host itself is missing, so the injected
  //         rule matched nothing, the diff was structurally zero, and every
  //         dimming figure in the run is unverified. That is instrument rot
  //         wearing the same number.
  //
  //    A POSITIVE CONTROL settles it outright: a synthetic scrim that DOES
  //    render, in the same run, with the guard seen to fire on it. Without one,
  //    the host census below is the best available discrimination and is stated
  //    as evidence rather than as proof.
  const hostPresent = hitTested.filter((r) => r.scrim?.host_present).length;
  const scrimRenders = hitTested.filter((r) => r.scrim?.renders).length;
  const control = run.positive_control ?? null;
  const controlFired = control?.ran === true && control.guard_passed === true;

  let zeroCause = 'not-applicable — the guard applied in at least one row';
  if (applies.length === 0) {
    if (controlFired) {
      zeroCause =
        'DESK-FIXED (proven). The positive control forced a scrim to render in this same run and the ' +
        'guard FIRED on it, so the machinery demonstrably works. Zero real rows therefore means the ' +
        'deployed desk rendered no scrim — which is this wave\'s intended outcome, not a broken check.';
    } else if (hostPresent === 0) {
      zeroCause =
        'GUARD-NEVER-RAN (instrument suspect). The scrim\'s host .editor-with-preview was absent in ' +
        'EVERY hit-tested row, so the injected rule had nothing to attach to and the diff was zero ' +
        'by construction rather than by observation. Do NOT read this zero as a fixed desk. Re-run ' +
        'with --positive-control before quoting any dimming figure from it.';
    } else {
      zeroCause =
        `DESK-FIXED (unproven). The host .editor-with-preview WAS present in ${hostPresent} of ` +
        `${hitTested.length} hit-tested rows and the scrim rendered in none of them, which is what a ` +
        `fixed desk looks like. But no positive control ran, so this run cannot rule out that the ` +
        `injected selector has drifted and the guard is simply incapable of firing. Re-run with ` +
        `--positive-control to convert this from plausible to proven.`;
    }
  }

  return {
    applies_in_rows: applies.length,
    passed_in_rows: passed.length,
    hit_tested_rows: hitTested.length,
    scrim_host_present_in_rows: hostPresent,
    scrim_renders_in_rows: scrimRenders,
    vacuous: applies.length === 0,
    zero_cause: zeroCause,
    positive_control_ran: control?.ran ?? false,
    positive_control_guard_passed: control?.guard_passed ?? null,
    note: applies.length === 0
      ? 'The guard applied in NO row, so it proved nothing on its own — that is NOT a pass. ' +
        'zero_cause says which of the two zeros this is: a desk that stopped rendering a scrim, or ' +
        'a guard that could not have fired. ' + zeroCause
      : 'Where the scrim renders, forcing its pointer-events moved the hit-test; the dimming ' +
        'figures in those rows are derived from a rule that actually matches the deployed CSS.',
  };
}

/** The order the human table walks its states: DERIVED FROM THE ROWS, with the
 *  declared states first (so the familiar reading order holds) and anything
 *  else appended rather than dropped. A state this file has never heard of —
 *  a synthetic row, a state a future wave adds and forgets to register — still
 *  prints. That is the whole fix: the printer can no longer have an opinion
 *  about which states exist. */
export function orderedStates(run) {
  const seen = [...new Set(run.rows.map((r) => r.inspector_state))];
  return [...STATE_IDS.filter((id) => seen.includes(id)), ...seen.filter((id) => !STATE_IDS.includes(id))];
}

/** THE TRIPWIRE. The derivation above makes a silent drop structurally
 *  impossible; this proves the derivation held. A state present in `rows` and
 *  absent from the printed output is a HARD FAILURE, because a row measured at
 *  the cost of an authenticated Chromium sweep and then not shown is a
 *  measurement paid for and thrown away — and it fails SILENTLY, which is the
 *  one failure mode this instrument's whole contract forbids (D81/D130). */
export function assertEveryStateRendered(run, rendered) {
  const inRows = new Set(run.rows.map((r) => r.inspector_state));
  const missing = [...inRows].filter((id) => !rendered.has(id));
  if (missing.length) {
    die(`SILENT STATE DROP — ${missing.length} inspector state(s) produced rows but were never ` +
        `printed: ${missing.join(', ')}. Rows present: ` +
        `${[...inRows].map((s) => `${s} (${run.rows.filter((r) => r.inspector_state === s).length})`).join(', ')}. ` +
        `Rendered: ${[...rendered].join(', ') || 'none'}. This is the defect this wave was filed ` +
        `about: three summary loops hardcoded ['default', 'user-opened'], so a third state vanished ` +
        `from the human table with no error raised anywhere. A measurement that is paid for and then ` +
        `discarded without complaint is worse than a crash.`);
  }
}

// ── human table ──────────────────────────────────────────────────────────────
//
// `printTable`, `orderedStates`, `assertEveryStateRendered`, `summariseNonVacuity`
// and `expectedRowCount` are EXPORTED, for exactly the reason `compareProvenance`
// is: a check that has never been seen to fire is a check nobody can trust, and
// a full authenticated sweep (~30-60s, deployed guerrilla, an admin token) is far
// too heavy to be the only way to see one fire.
//
// This is not hypothetical hygiene. The silent drop this wave fixes was FOUND by
// feeding a synthetic third-state row to the real printer and counting how many
// times "destination" appeared in the output: zero, with no error raised. That
// experiment is only possible because the printer can be called with a
// hand-built run object. Keep these exported.

export function printTable(run) {
  const L = (s = '') => process.stdout.write(s + '\n');
  // THREE-VALUED, not two. `yn(null)` printed "no", which for `floor?` reads as
  // "the floor was measured and did not bind" when the truth is that no floor
  // was measured at all.
  const yn = (b) => (b === null || b === undefined ? '?' : b ? 'yes' : 'no');
  // ── NULL VERDICTS RENDER '?', NEVER 'FAIL'. The RECORD has always written
  //    `content_meets_55ch: contentCh === null ? null : ...`, and the printer
  //    honoured null for the ch NUMBERS (it already rendered '?') but not for
  //    the VERDICTS — `null ? 'MEET' : 'FAIL'` is FAIL. So a row with no
  //    reading column printed '?' in its ch column and 'FAIL' in the verdict
  //    column of the SAME ROW, which is both self-contradictory and, per D127
  //    Part 2, forbidden: asserting a failure against a reading column that
  //    does not exist is the vacuous-pass disease with its sign flipped.
  const verdict = (v) => (v === null || v === undefined ? '?' : v ? 'MEET' : 'FAIL');
  const num = (v, d = 2) => (typeof v === 'number' ? v.toFixed(d) : '?');
  // Every state this printer actually emitted. assertEveryStateRendered()
  // compares it against the states present in run.rows.
  const rendered = new Set();
  const stateOrder = orderedStates(run);
  const legendFor = (id) => stateById(id)?.legend ?? '(UNDECLARED STATE — not in this file\'s STATE table, printed anyway)';

  L('');
  L('  STUDIO DESK — LIVE MEASURE MATRIX');
  L('  ' + '='.repeat(118));
  L(`  target        ${run.target}`);
  L(`  document      ${run.measured_document}   (${run.measured_doc_source ?? 'source not recorded'})`);
  L(`  landed as     ${run.landed_authenticated_url}`);
  L(`  measured url  ${run.measured_url}`);
  L(`  served SHA    ${run.provenance.served_sha}   (read live over ssh)`);
  L(`  live slot     ${run.provenance.slot_active.join(', ') || 'NONE ACTIVE'}   (queried, never assumed — D71)`);
  L(`  slot units    ${run.provenance.slot_units_loaded.join(' | ') || '(none loaded)'}`);
  if (run.provenance_bracket) {
    L(`  provenance    BRACKETED — pre ${run.provenance.read_at} / post ${run.provenance_post.read_at} ` +
      `(${Math.round(run.provenance_bracket.window_ms / 1000)}s): ` +
      `${run.provenance_bracket.matched ? 'SHA and slot both held across the whole sweep' : 'MISMATCH'} (D97)`);
  }
  L(`  drill target  ${run.doc_target.mode === 'any' ? 'first row that opens (--doc=any)' : run.doc_target.slug} ` +
    `(from the ${run.doc_target.source})` +
    (run.drill ? `; opened on attempt ${run.drill.attempts} of ${run.drill.rows_in_list} rows` : ''));
  L(`  sweep         ${run.sweep_direction} (D80); neither state reloads mid-sweep`);
  if (run.user_opened_proof) {
    L(`  user-opened   reached by ${run.user_opened_proof.clicks_needed} real click(s) on ` +
      `[data-test-id="sidebar-toggle-panel"] via the live socket (D110) — ` +
      `position ${run.user_opened_proof.after.position}, width ${run.user_opened_proof.after.width_px}px`);
  }
  L(`  platform      ${run.platform} — scrollbar ${run.rows[0]?.scrollbar_width_px ?? '?'}px (macOS overlay; D83)`);
  // The row count as ARITHMETIC (D121's doctrine without its literal), stated
  // before the matrix so a short run is obvious at the top rather than tallied
  // out of the table by a reader who may not bother.
  if (run.states_measured) {
    const expected = expectedRowCount(run.states_measured);
    L(`  states        measured: ${run.states_measured.join(', ') || 'none'}` +
      (run.states_skipped?.length ? `; SKIPPED: ${run.states_skipped.map((s) => s.state).join(', ')}` : ''));
    L(`  rows          ${run.rows.length} of ${expected} expected ` +
      `(${WIDTHS.length} widths x ${FACES.length} faces x states applicable at each width — computed, ` +
      `never a compiled-in literal)` +
      (run.rows.length === expected ? ' — COMPLETE' : ' — SHORT, see the caveats below'));
    for (const s of run.states_skipped ?? []) L(`  skipped       ${s.state}: ${s.reason}`);
  }
  L('');

  const cols = [
    ['viewport', 9], ['face', 15], ['bucket', 9], ['panes', 16], ['panel', 7],
    ['gutter', 7], ['content', 8], ['px/ch', 8], ['ch', 7], ['floor?', 7],
    ['xscroll', 8], ['strip', 6], ['crumb', 6], ['insp', 6], ['lay?', 6],
    ['visible', 8], ['vis-ch', 8], ['vis?', 5], ['dimmed', 8], ['legacy', 8],
  ];
  const pad = (v, w) => String(v).padEnd(w);
  // The row's OWN in-page figures. Never recomputed here from another row's
  // px/ch — the table renders verdicts, it does not author them (D83/D86).
  const chOf = (r) => (r.content_ch ?? null);
  const RULE = '  ' + '-'.repeat(150);

  for (const state of stateOrder) {
    const rows = run.rows.filter((r) => r.inspector_state === state);
    if (!rows.length) continue;
    rendered.add(state);
    L(`  INSPECTOR STATE: ${state.toUpperCase()}   ${legendFor(state)}`);
    L('  ' + cols.map(([h, w]) => pad(h, w)).join(''));
    L(RULE);
    let lastVp = null;
    for (const r of rows) {
      if (lastVp !== null && r.viewport_px !== lastVp) L(RULE);
      lastVp = r.viewport_px;
      const ch = chOf(r);
      L('  ' + [
        pad(r.viewport_px + (r.settle.settled ? '' : '*'), 9),
        pad(r.face + (r.face_relevant === false ? '~' : ''), 15),
        pad(r.width_bucket_stamped ?? '(none)', 9),
        pad('[' + r.panes.visible_pane_widths_px.join(',') + ']', 16),
        pad(r.panel_px ?? '?', 7),
        pad(r.gutter.total_px ?? '?', 7),
        pad(r.content_px ?? '?', 8),
        pad(r.ch.probe_px_per_ch ?? '?', 8),
        pad(num(ch), 7),
        pad(yn(r.floor.binds), 7),
        pad(yn(r.overflow.horizontal_scroll), 8),
        pad(r.panes.strips_visible, 6),
        pad(r.crumbs.visible ? r.crumbs.count : 0, 6),
        pad(r.inspector.present
          ? (r.inspector.overlays_surface === null ? 'n/c' : r.inspector.overlays_surface ? 'ovl' : 'dock')
          : 'n/a', 6),
        pad(verdict(r.content_meets_55ch), 6),
        pad(r.visible_content_px ?? '?', 8),
        pad(num(r.visible_ch), 8),
        pad(verdict(r.visible_meets_55ch), 5),
        pad(r.scrim?.renders ? `${r.dimmed_content_px}@${r.scrim_alpha}` : '-', 8),
        pad(r.legacy_inspector_subtraction_px ?? '-', 8),
      ].join(''));
    }
    L('');
  }

  L('  ' + '='.repeat(150));
  L('  content = surface.clientWidth - READ paddingLeft/Right (never width-80 — D72/D78).');
  L('  ch      = content_px / a width:1ch probe span CHILD of .bp-paper-surface, in THAT face (D31/D83).');
  L('  floor?  = min-inline-size forced to 0 and re-measured; a width change IS the bind (not arithmetic).');
  L('  xscroll = .editor-body.bp-paper-body scrollWidth > clientWidth (D39\'s real scroller).');
  L('  insp    = inspector DOCKed (in flow, steals width) vs OVLays (out of flow, covers the column).');
  L('  visible = GEOMETRIC occlusion by HIT-TEST DIFF (D112): at each sampled point, is the topmost');
  L('            element .bp-paper-surface or a descendant? Ancestry, never a list of known occluders.');
  L('            The narrowest scanline is the headline — the reader reads every line.');
  L('  dimmed  = the scrim\'s footprint as `px@alpha`, found by DIFF (natural sample vs one with');
  L('            pointer-events forced on the scrim via an injected sheet — it is pointer-events:none');
  L('            AND a pseudo, so elementsFromPoint is doubly blind to it). NEVER folded into visible:');
  L('            the scrim DIMS, it does not hide (D111). Folding it in would read 0px visible at every');
  L('            sub-wide user-opened width, so no seal could be taken and no improvement could rank.');
  L('  legacy  = what the OLD one-entry-list subtraction would have said. Kept beside the new number');
  L('            so the delta is readable and no history is erased.');
  L('  panes   = VISIBLE .pane-column widths. strip/crumb are VISIBLE counts, not DOM counts.');
  L('  *       = the desk never settled at this width; treat the row as a moving target.');
  L('  lay?    = the LAYOUT verdict: content_px / this row\'s own px/ch, against >=55ch.');
  L('  vis?    = the VISIBLE verdict: visible_content_px / this row\'s own px/ch, against >=55ch.');
  L('            Same bar, different question — vis? is what a reader actually gets. Where the');
  L('            inspector is DOCKED the two agree BY DESIGN: layout already took the inspector\'s');
  L('            width out of the surface, so subtracting it again would double-count (see the');
  L('            comment on the docked case in PAGE_MEASURE — this is not a missing subtraction).');
  L('  Both ch figures divide THIS row\'s box by THIS row\'s probe span under THIS row\'s forced');
  L('  face. No figure anywhere divides one face\'s box by another face\'s advance (D83/D86).');
  L('  ?       = NOT MEASURED or NOT ASKED, never zero and never FAIL. Two ways to get one: a state');
  L('            may declare it has NO reading column, and a row may be in the Tier-3 DESTINATION');
  L('            (is_destination, derived from the server\'s [data-inspector-destination] marker),');
  L('            where an opaque inspector covers the column BY DESIGN so its vis? verdict is');
  L('            WITHDRAWN to ? rather than reported FALSE. A 0 there would read as catastrophic');
  L('            occlusion and a FAIL would assert a reading failure against a state working exactly');
  L('            as designed — D127 Part 2 forbids both, and the seal turns on this column.');
  L('  face~    = the face was forced for matrix symmetry only; with no reading column there is no');
  L('            advance to measure, so the three face rows of such a state are identical by design.');
  L('  insp n/c = the inspector is present but there is no reading column for it to dock beside or');
  L('            overlay, so "does it overlay" has no answer here rather than the answer "no".');
  L('');

  // The visible census — the number this wave's seal ruling turns on, stated as
  // a count rather than left for a reader to tally out of 54 rows.
  for (const state of stateOrder) {
    const rows = run.rows.filter((r) => r.inspector_state === state);
    if (!rows.length) continue;
    rendered.add(state);
    // THREE buckets, not two. A cell with a NULL verdict is neither a MEET nor
    // a FAIL — it is a cell where the question does not arise — and folding it
    // into the fail count would manufacture exactly the FAIL that D127 Part 2
    // forbids, in the census this wave's seal ruling reads.
    const measurable = rows.filter((r) => r.visible_meets_55ch !== null && r.visible_meets_55ch !== undefined);
    const unmeasurable = rows.length - measurable.length;
    const meet = measurable.filter((r) => r.visible_meets_55ch);
    const lay = rows.filter((r) => r.content_meets_55ch === true).length;
    L(`  VISIBLE VERDICT (${state}): ${meet.length} of ${measurable.length} MEASURABLE cells MEET ` +
      `>=55ch of VISIBLE measure (the LAYOUT measure meets in ${lay}).` +
      (unmeasurable
        ? ` ${unmeasurable} of ${rows.length} cells are NOT MEASURABLE — this state has no reading ` +
          `column, so those are "?" and are counted as neither MEET nor FAIL.`
        : ''));
    if (measurable.length === 0) {
      L('    No measurable cell in this state — there is no reading column here to measure. That is');
      L('    the state\'s declared shape, not a failure, and it is NOT evidence either way about 55ch.');
    } else if (meet.length === 0) {
      L('    None — at any width, in any face. Every measurable cell in this state reads under the criterion.');
    } else {
      const byWidth = [...new Set(meet.map((r) => r.viewport_px))].sort((a, b) => b - a);
      for (const w of byWidth) {
        const at = meet.filter((r) => r.viewport_px === w);
        L(`    viewport ${String(w).padStart(4)}px: ${at.map((r) => `${r.face} ${num(r.visible_ch)}ch`).join(', ')}`);
      }
      // `=== false`, not `!`: a null verdict is not a fail and must not be
      // listed as one.
      const missWidths = [...new Set(measurable.filter((r) => r.visible_meets_55ch === false)
        .map((r) => r.viewport_px))]
        .sort((a, b) => b - a);
      L(`    FAIL at: ${missWidths.join(', ')}px (all faces unless listed above).`);
    }
    L('');
  }

  // The epic's own criterion, answered with a number, honestly either way.
  L('  THE EPIC\'S HEADLINE CRITERION — >=55ch of CONTENT at viewport 900px:');
  L('');
  const meets = (v) => (v === null || v === undefined ? 'NOT MEASURABLE' : v ? 'MEETS' : 'FAILS');
  for (const state of stateOrder) {
    const at900 = run.rows.filter((x) => x.viewport_px === 900 && x.inspector_state === state);
    if (!at900.length) continue;
    rendered.add(state);
    for (const r of at900) {
      L(`    ${pad(state, 13)} ${pad(r.face, 16)} content ${String(r.content_px ?? '?').padEnd(7)}px = ` +
        `${num(chOf(r)).padStart(6)}ch  ${meets(r.content_meets_55ch)}   ` +
        `(visible ${String(r.visible_content_px ?? '?').padEnd(6)}px = ${num(r.visible_ch)}ch ` +
        `${meets(r.visible_meets_55ch)})   ` +
        `${r.ch.probe_px_per_ch ?? '?'}px/ch, ${r.font.resolved_family ?? 'UNRESOLVED'} @ ` +
        `${r.font.font_size_px ?? '?'}px`);
    }
    L('');
  }
  L('  Nothing above is rounded toward the criterion. Where states disagree, ALL are printed —');
  L('  the desk genuinely has more than one answer and a matrix that hides one is spin. A state');
  L('  with no reading column reads NOT MEASURABLE, which is a third answer, not a failing one.');
  L('');

  // The protected floor: where, if anywhere, does it actually do something?
  // This is the input `spd-w5-measure-gate-right-box` needs to pick a constant,
  // so it is reported as a census rather than a claim.
  const bound = run.rows.filter((r) => r.floor.binds);
  L(`  DOES THE PROTECTED FLOOR EVER BIND?  ${bound.length} of ${run.rows.length} cells.`);
  if (bound.length === 0) {
    L('    Never — at any width, in any face, in either entry state. The measure is delivered');
    L('    by the surface\'s own max-width, not by min-inline-size.');
  } else {
    for (const r of bound) {
      L(`    viewport ${r.viewport_px}px / ${r.inspector_state} / ${r.face}: ` +
        `floor ${r.floor.min_inline_size_px}px pushed the surface ` +
        `${r.floor.width_without_floor_px} -> ${r.floor.width_with_floor_px}px` +
        (r.overflow.horizontal_scroll
          ? `, and .editor-body.bp-paper-body then overflowed by ${r.overflow.overflow_px}px`
          : ', with no horizontal overflow'));
    }
  }
  L('');

  // ── THE INSTRUMENT'S CHECKS ON ITSELF. A metric that cannot show its own
  //    guard firing is a metric nobody can audit — and for THIS metric a
  //    vacuous pass would falsify the seal, so the census is printed whether it
  //    is interesting or not (D31/D39/D112).
  // DENOMINATOR = rows that actually ran the hit-test. A no-reading-column row
  // has `occlusion: null` and never could have exercised the guard; counting it
  // in the denominator would silently depress every ratio here and make a
  // healthy run look like a degrading one.
  const hitTested = run.rows.filter((r) => r.occlusion?.non_vacuity);
  const scrimRows = hitTested.filter((r) => r.scrim?.renders);
  const guarded = hitTested.filter((r) => r.occlusion.non_vacuity.guard_applies);
  const guardPassed = guarded.filter((r) => r.occlusion.non_vacuity.forced_sample_differs);
  const restored = hitTested.filter((r) => r.occlusion?.restore?.byte_identical);
  const nv = summariseNonVacuity(run);
  const firstHit = hitTested[0];
  L('  OCCLUSION INSTRUMENT — SELF-CHECKS:');
  L(`    hit-tested rows      ${hitTested.length} of ${run.rows.length} ` +
    `(${run.rows.length - hitTested.length} rows have no reading column, so no hit-test — they are ` +
    `excluded from every ratio below rather than counted as failures)`);
  L(`    scan resolution      ${firstHit?.occlusion?.scan_columns ?? '?'} columns per scanline ` +
    `(~${firstHit?.occlusion?.scan_step_px ?? '?'}px step), edges bisected to ` +
    `+/-${firstHit?.occlusion?.bisect_tolerance_px ?? '?'}px. The step bounds DETECTION, the ` +
    `tolerance bounds PRECISION.`);
  L(`    scrim renders in     ${scrimRows.length} of ${hitTested.length} hit-tested rows` +
    (scrimRows.length ? ` (${[...new Set(scrimRows.map((r) => r.inspector_state))].join(', ')})` : '') +
    `; its host .editor-with-preview is present in ${nv.scrim_host_present_in_rows}`);
  L(`    NON-VACUITY GUARD    applies in ${guarded.length} rows, PASSED in ${guardPassed.length}` +
    (guarded.length === 0
      ? ' — it had nothing to prove in this run, which is NOT a pass.'
      : ' — the forced sample genuinely differed from the natural one.'));
  if (guarded.length === 0) {
    // ── THE TWO ZEROS, TOLD APART. "No scrim because the desk was fixed" and
    //    "the guard could not have fired" are the SAME number and opposite
    //    news, so the census never prints the bare zero on its own.
    L('    WHICH ZERO IS THIS?  ' + nv.zero_cause);
  }
  if (run.positive_control) {
    const pc = run.positive_control;
    L(`    POSITIVE CONTROL     ${pc.ran
      ? `ran (synthetic scrim forced to render, face ${pc.face}) — guard ` +
        `${pc.guard_passed === true ? 'FIRED' : 'DID NOT FIRE'}: ${pc.verdict}`
      : `not run — ${pc.skip_reason}`}`);
  }
  // D171/D185 — printed whether it passed or not. A precondition nobody can see
  // in the human output is one nobody checks, and `checked: 0` must be as loud
  // as a failure: it means the run asserted its own tier NOWHERE.
  {
    const bp = run.bucket_precondition ?? emptyBucketPrecondition();
    L(`    BUCKET PRECOND.      ${bp.agreed} of ${bp.checked} readings stamp the RAW band of the ` +
      `viewport they actually got` +
      `${bp.checked === 0 ? ' — ZERO CHECKED, this run asserted its own tier nowhere' : ''}`);
    for (const f of bp.failures) {
      L(`      ${f.where}: stamped "${f.width_bucket_stamped}" but innerWidth ` +
        `${f.real_inner_width}px is raw band "${f.expected_raw_band}" — verdicts withdrawn`);
    }
  }
  L(`    RESTORE byte-ident.  ${restored.length} of ${hitTested.length} hit-tested rows ` +
    `(injected sheet removed, host and ::after computed styles identical before/after)`);
  if (run.round_trip) {
    const rt = run.round_trip;
    // The verdict line must never read as a contradiction. With cells withdrawn
    // you can have `identical === cells` AND `returns_bit_identical false` — the
    // survivors all came back, but the sweep did not cover the desk. "THE COLUMN
    // DOES NOT COME BACK" would be a FALSE accusation there: nothing drifted, we
    // just did not measure everything. Three outcomes, three sentences.
    const rtVerdict = rt.returns_bit_identical
      ? 'the column comes back exactly'
      : (rt.cells_withdrawn_for_bucket_precondition ?? 0) > 0 && rt.identical_cells === rt.cells
        ? 'NO CLAIM — every measured cell came back, but the sweep is INCOMPLETE (see withdrawals below)'
        : 'THE COLUMN DOES NOT COME BACK';
    L(`    ROUND TRIP           ${rt.ran
      ? `${rt.identical_cells} of ${rt.cells} cells returned BIT-IDENTICAL after ` +
        `default -> open -> dismiss on the same page instance — ${rtVerdict}`
      : `SKIPPED — ${rt.skip_reason}`}`);
    // D183: the grammar is printed BY WIDTH. One line per control actually used,
    // naming the widths it dismissed — never widths[0] speaking for the sweep.
    for (const u of rt.dismiss_controls_used ?? []) {
      L(`      dismissed via ${u.control} (${u.grammar}) at ${u.widths_px.join(', ')}px`);
    }
    // D171/D185: withdrawn cells are announced, never just missing from a total.
    if (rt.ran && (rt.cells_withdrawn_for_bucket_precondition ?? 0) > 0) {
      L(`      ${rt.cells_withdrawn_for_bucket_precondition} cell(s) WITHDRAWN at ` +
        `${(rt.widths_withdrawn_for_bucket_precondition ?? []).join(', ')}px — the bucket ` +
        `precondition failed there, so those legs may compare different tiers and are no ` +
        `evidence either way. The fidelity claim is NOT made on a partial sweep.`);
    }
    if (rt.ran && !rt.returns_bit_identical) {
      for (const w of rt.widths) {
        for (const f of w.faces.filter((x) => !x.identical)) {
          L(`      viewport ${String(w.viewport_px).padStart(4)}px ${f.face.padEnd(15)} ` +
            f.diffs.map((d) => `${d.field} ${d.before} -> ${d.after}`).join(', '));
        }
      }
      L('      A column that does not return is a desk that degrades every time the reader looks');
      L('      something up. These are the SAME rounded figures the matrix publishes, so any');
      L('      difference here is a difference a reader would be handed.');
    }
  }

  // ── HIT-TEST vs THE OLD ARITHMETIC, stated as a number. A divergence here is
  //    a finding and is printed whether or not anyone wants it to be.
  const deltas = run.rows.filter((r) => typeof r.visible_vs_legacy_delta_px === 'number');
  const diverged = deltas.filter((r) => Math.abs(r.visible_vs_legacy_delta_px) > 0.5);
  L(`    hit-test vs legacy   ${deltas.length - diverged.length} of ${deltas.length} rows agree within ` +
    `the +/-0.5px bisection tolerance; ${diverged.length} diverge beyond it.`);
  if (diverged.length) {
    const byWidth = new Map();
    for (const r of diverged) {
      const k = `${r.viewport_px}px ${r.inspector_state}`;
      if (!byWidth.has(k)) byWidth.set(k, r.visible_vs_legacy_delta_px);
    }
    for (const [k, d] of byWidth) {
      L(`      ${k.padEnd(24)} hit-test reads ${d > 0 ? '+' : ''}${d}px vs the rectangle arithmetic`);
    }
    L('      A NEGATIVE delta means the hit-test found MORE occlusion than the inspector\'s own box');
    L('      accounts for — i.e. something else is also on top there. Read the `edges` field on the');
    L('      scanlines: it names the element on each side of every boundary it bisected.');
  }
  if (run.b29_probes) {
    const { c2, c3 } = run.b29_probes;
    L(`    spd-b29 c2 NO FLASH  ${c2.frames_captured} rAF frames from document_start at ` +
      `${c2.viewport_px}px: ${c2.overlay_frames} frame(s) >= ${c2.overlay_width_threshold_px}px, ` +
      `${c2.transitions} transition(s) — flash ${c2.flash_observed ? 'OBSERVED' : 'NOT observed'}`);
    L(`    spd-b29 c3 REACHABLE at ${c3.viewport_px}px, ${c3.clicks_needed} real click(s): ` +
      `${c3.before_click.width_px}px -> ${c3.after_click.width_px}px, ` +
      `position ${c3.after_click.position}, left ${c3.after_click.left_px}px, ` +
      `transform ${c3.after_click.transform}`);
  }
  L('');

  const unsettled = run.rows.filter((r) => !r.settle.settled).length;
  const expected = run.states_measured ? expectedRowCount(run.states_measured) : null;
  const short = expected !== null && run.rows.length !== expected;
  if (unsettled || short || run.warnings.length) {
    L('  CAVEATS ON THIS RUN:');
    if (unsettled) L(`    - ${unsettled}/${run.rows.length} rows never settled (marked * above) — those are moving targets.`);
    if (short) {
      L(`    - ROW COUNT MISMATCH: ${run.rows.length} rows collected, ${expected} expected from the ` +
        `states this run measured. The expected count is COMPUTED (widths x faces x states applicable`);
      L(`      at each width), so this is arithmetic, not a remembered literal — something stopped ` +
        `early and the warnings above say what.`);
    }
    for (const w of run.warnings) L(`    - ${w}`);
    L('');
  }

  // Last line of the printer, deliberately: it proves the state derivation held
  // for every loop above rather than only for the first one.
  assertEveryStateRendered(run, rendered);
}

// Run only when INVOKED, so `compareProvenance` can be imported and exercised
// directly. A bracket check that has never been seen to fire is a check nobody
// can trust, and a full authenticated run (~30-60s observed, ~2min worst case,
// and it needs deployed guerrilla plus an admin token) is far too heavy to be
// the only way to see it fire.
//
// BOTH SIDES GO THROUGH REALPATH (D130). This comparison used to be
//
//     path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
//
// which is asymmetric: Node resolves ESM module URLs through realpath, but
// `argv[1]` is whatever the shell handed over, verbatim. macOS `/tmp` is a
// symlink to `/private/tmp`, so `node /tmp/spd-measure.mjs` compared
// '/tmp/…' against '/private/tmp/…', INVOKED_DIRECTLY was false, and the
// process exited 0 having written ZERO bytes to stdout AND stderr. Piped
// through `tee` that yields an empty file at exit 0 — indistinguishable from a
// tooling hiccup and one careless `| tail` from being read as "no failures".
// That is the precise inversion of this instrument's own contract (D81/D97):
// a rotted run must be VISIBLY rotted, never silently absent. Any symlink on
// either path — /tmp, a checkout reached through one, a `ln -s` convenience
// shim — reintroduced it, so the fix is symmetry, not a special case for /tmp.
const INVOKED_DIRECTLY =
  !!process.argv[1] && realResolve(process.argv[1]) === realResolve(fileURLToPath(import.meta.url));

if (INVOKED_DIRECTLY && (process.argv.includes('--help') || process.argv.includes('-h'))) {
  process.stdout.write(usage());
  process.exit(0);
}

/**
 * BOUNDED RETRIES, ON THE NAMED ABORTS ONLY (RULING 2, this file's header).
 *
 * `--retries=N` / `BP_DESK_RETRIES`. Default 2, so the default invocation makes
 * at most three attempts. A TERMINAL failure is never retried, at any N: it
 * would burn two more authenticated sweeps to reprint the same sentence.
 *
 * Every failed attempt's stderr is written BEFORE the next one starts. That is
 * the whole discipline D138 lost — failure B has no diagnosis today for exactly
 * one reason, that its operator suppressed stderr and the text is gone — and a
 * retry loop that swallows the attempts it retried would rebuild that hole
 * inside the instrument, where nobody would even think to look for it.
 */
export function parseRetries(argv = process.argv, env = process.env) {
  const flag = argv.find((a) => typeof a === 'string' && a.startsWith('--retries='));
  const raw = flag ? flag.slice('--retries='.length) : (env.BP_DESK_RETRIES ?? '2');
  const n = Number(raw);
  if (!/^\d+$/.test(String(raw).trim()) || !Number.isInteger(n) || n < 0 || n > 10) {
    die(`--retries must be a whole number 0..10 (got ${JSON.stringify(raw)}). 0 means "one attempt, ` +
        `no retries" — the pre-2026-09 behaviour.`);
  }
  return n;
}

export async function runWithRetries(attemptFn, retries, { onRetry = () => {} } = {}) {
  const attempts = [];
  for (let attempt = 1; ; attempt += 1) {
    try {
      const value = await attemptFn(attempt);
      return { value, attempts, attempt };
    } catch (err) {
      const browserRace = isRetryableBrowserRace(err);
      const retryable = browserRace || (err instanceof MeasureError && err.retryable === true);
      const abortId = browserRace ? 'browser-race' : (err?.abortId ?? null);
      attempts.push({ attempt, retryable, abort_id: abortId, message: err?.message ?? String(err) });
      if (!retryable || attempt > retries) {
        err.attempts = attempts;
        throw err;
      }
      onRetry({ attempt, retries, abort_id: abortId, message: err.message });
    }
  }
}

if (INVOKED_DIRECTLY) {
  const FAIL_ON_FACE_SUBSTITUTION = process.argv.includes('--fail-on-face-substitution');
  // `resolveOutPath` runs INSIDE this chain so a malformed `--out` lands in the
  // same handler as every other MeasureError — one failure shape, by name.
  Promise.resolve()
    .then(() => { OUT_PATH = resolveOutPath(); SHA_PIN = parseShaPin(); })
    .then(() => runWithRetries(main, parseRetries(), {
      onRetry: ({ attempt, retries, abort_id, message }) => {
        process.stderr.write(
          `\nATTEMPT ${attempt} FAILED — retryable abort "${abort_id}". Its stderr, in full, ` +
          `because a swallowed one is how D138's failure B lost its diagnosis:\n\n${message}\n\n` +
          `  Retrying (attempt ${attempt + 1} of ${retries + 1}). ` +
          `Pass --retries=0 to make the first abort final.\n\n`);
      },
    }))
    .then(({ value: run, attempt }) => {
      if (attempt > 1) {
        process.stderr.write(
          `\n  [retry] this matrix came from attempt ${attempt}. The failed attempts' stderr is above ` +
          `and is part of this run's record.\n`);
      }
      const integrity = run?.face_override_integrity;
      if (FAIL_ON_FACE_SUBSTITUTION && integrity && !integrity.clean) {
        process.stderr.write(
          `\nFACE SUBSTITUTION — ${integrity.substitutions.length} of ${integrity.forced_rows_checked} ` +
          `forced-face row(s) measured a face nobody asked for, and --fail-on-face-substitution was ` +
          `passed.\n\n` +
          integrity.substitutions.map((x) =>
            `  - ${x.where}: asked ${x.requested_primary}, got ${x.resolved_family}`).join('\n') +
          `\n\n  Their 55ch verdicts are already NULL in the artifact, which HAS been written — this ` +
          `exit is a gate signal, not a lost run. Re-run; if it recurs at the same cell it is not a ` +
          `race.\n\n`);
        process.exit(2);
      }
    })
    .catch((err) => {
      process.stderr.write('\nMEASURE FAILED — no matrix was produced.\n\n');
      process.stderr.write((err instanceof MeasureError ? err.message : (err?.stack || String(err))) + '\n\n');
      if ((err instanceof MeasureError && err.retryable) || isRetryableBrowserRace(err)) {
        process.stderr.write(
          `  RETRYABLE ABORT "${err.abortId ?? 'browser-race'}" — this is a race the harness lost, not a fact about the ` +
          `desk, and re-running is the CORRECT response rather than a deviation ` +
          `(${(err.attempts || []).length} attempt(s) made). The full list of retryable aborts is ` +
          `RETRYABLE_ABORTS in this file.\n\n`);
      }
      process.exit(1);
    });
}
