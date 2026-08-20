#!/usr/bin/env node
// open-leg-repro.mjs — THE FORCING REPRO for charter D178 (the open leg's stale
// locator). NOT a gate, NOT part of a sweep: a self-contained proof that
// `openInspectorByRealClick` no longer throws a raw Playwright TimeoutError when
// the Tier-3 rename (#5014, components.ex:425) flips the toggle's data-test-id
// from `sidebar-toggle-panel` to `sidebar-dismiss` mid-loop.
//
// It stands up NO server. Each scenario is a `page.setContent()` fixture that
// carries exactly the two things `openInspectorByRealClick` needs to run offline:
//   • a `.bp-doc-sidebar` element for its `observe()` probe, and
//   • a `[data-phx-main].phx-connected` element so `waitForDeskSettled()` reports
//     the socket connected and settles in ~1s instead of spinning its 20s timeout.
// The toggle button rewrites its own data-test-id on the first click via inline
// JS — that IS the Tier-3 rename, reproduced without a LiveView round trip.
//
// It proves BOTH sides of the fix against the SAME fixture:
//   BEFORE — the pre-D178 code path, reproduced inline (one locator resolved
//            ONCE before the loop, re-clicked): a raw TimeoutError after the full
//            ~10s auto-wait, NOT instanceof MeasureError.
//   AFTER  — the shipped `openInspectorByRealClick`, which re-resolves across both
//            spellings every iteration: its OWN named MeasureError in ~1s.
//
// Run:  node scripts/measurements/open-leg-repro.mjs
// Needs the same playwright the instrument uses (chromium via resolvePlaywright).

import { resolvePlaywright, openInspectorByRealClick } from '../studio-desk-measure.mjs';

const { pw, version } = resolvePlaywright();

// A fixture whose toggle renames ITSELF on the first click and, per `opensOn`,
// either stamps data-user-opened on a later click or never does. `renameTo` is
// the id the button takes after click 1 — `sidebar-dismiss` reproduces the
// Tier-3 rename; a bogus id reproduces a control that vanished entirely.
function fixture({ renameTo, opensOnClick = 0 }) {
  return `<!doctype html><html data-width-bucket="narrow"><body>
    <div data-phx-main class="phx-connected"></div>
    <aside class="bp-doc-sidebar is-collapsed"></aside>
    <button id="tgl" data-test-id="sidebar-toggle-panel">toggle</button>
    <script>
      window.__clicks = 0;
      document.getElementById('tgl').addEventListener('click', function () {
        window.__clicks++;
        // Click 1 renames the control — exactly what #5014 does at Tier 3.
        if (window.__clicks === 1) this.setAttribute('data-test-id', ${JSON.stringify(renameTo)});
        // Optionally the state is genuinely reached on a later click, to prove
        // the fix FOLLOWS the rename rather than merely failing fast.
        if (${opensOnClick} > 0 && window.__clicks >= ${opensOnClick}) {
          document.querySelector('.bp-doc-sidebar').setAttribute('data-user-opened', '');
        }
      });
    </script>
  </body></html>`;
}

// The pre-D178 code path, reproduced verbatim in shape: resolve ONE locator to
// the single spelling BEFORE the loop, then re-click it. This is what shipped
// before this slice; running it here shows what it does to the exact fixture the
// fix survives.
async function preFixOpenLeg(page, { maxClicks = 3 } = {}) {
  const toggle = page.locator('[data-test-id="sidebar-toggle-panel"]').first();
  for (let i = 1; i <= maxClicks; i++) {
    await toggle.click({ timeout: 10_000 });
    await page.waitForTimeout(150);
    const opened = await page.evaluate(() =>
      !!document.querySelector('.bp-doc-sidebar[data-user-opened]'));
    if (opened) return { reached: true, clicks_needed: i };
  }
  return { reached: false };
}

async function drive(label, fn, fixtureHtml) {
  const browser = await pw.chromium.launch();
  const page = await browser.newPage();
  await page.setViewportSize({ width: 900, height: 900 });
  await page.setContent(fixtureHtml);
  const t0 = Date.now();
  let outcome;
  try {
    const r = await fn(page);
    outcome = { threw: false, ms: Date.now() - t0, result: r };
  } catch (e) {
    outcome = {
      threw: true,
      ms: Date.now() - t0,
      constructor: e.constructor.name,
      instanceof_MeasureError: e.constructor.name === 'MeasureError',
      message: String(e.message).split('\n')[0].slice(0, 160),
    };
  } finally {
    await browser.close();
  }
  const head = outcome.threw
    ? `THREW after ${outcome.ms}ms / constructor = ${outcome.constructor} / ` +
      `instanceof MeasureError = ${outcome.instanceof_MeasureError}`
    : `RETURNED after ${outcome.ms}ms / ${JSON.stringify(outcome.result)}`;
  console.log(`\n── ${label}`);
  console.log(`   ${head}`);
  if (outcome.threw) console.log(`   message: ${outcome.message}`);
  return outcome;
}

console.log(`open-leg-repro — playwright ${version}, chromium via resolvePlaywright()`);

// BEFORE: the pre-fix single-locator loop against the Tier-3 rename. Expect a raw
// TimeoutError after the full ~10s auto-wait — NOT a MeasureError.
const before = await drive(
  'BEFORE (pre-D178 single-locator loop) — toggle renamed to sidebar-dismiss',
  (page) => preFixOpenLeg(page),
  fixture({ renameTo: 'sidebar-dismiss' }));

// AFTER, scenario 1 — the control VANISHES (renames to a spelling in neither
// OPEN_CONTROLS entry). The shipped fix re-resolves each iteration, finds
// nothing, and routes through unreachable() → its own MeasureError, fast.
const afterVanish = await drive(
  'AFTER (shipped openInspectorByRealClick) — toggle vanished (renamed to a bogus id)',
  (page) => openInspectorByRealClick(page, { fatal: true }),
  fixture({ renameTo: 'sidebar-gone-entirely' }));

// AFTER, scenario 2 — the toggle renames to sidebar-dismiss and click 2 on that
// SAME button stamps data-user-opened. The fix FOLLOWS the rename and REACHES the
// state — where the pre-fix loop, holding a stale sidebar-toggle-panel locator,
// would have timed out. This is the Tier-3 round trip actually completing.
const afterFollow = await drive(
  'AFTER (shipped) — toggle renamed to sidebar-dismiss, opens on click 2 (rename FOLLOWED)',
  (page) => openInspectorByRealClick(page, { fatal: true }),
  fixture({ renameTo: 'sidebar-dismiss', opensOnClick: 2 }));

// AFTER, scenario 3 — fatal:false against the vanished control. Proves criterion
// 3: the round-trip mode yields a NAMED SKIP OBJECT, never an exception, so
// runRoundTrip's already-collected rows survive and writeRunArtifact still runs.
const afterNonFatal = await drive(
  'AFTER (shipped) — fatal:false, toggle vanished (the mode runRoundTrip uses)',
  (page) => openInspectorByRealClick(page, { fatal: false }),
  fixture({ renameTo: 'sidebar-gone-entirely' }));

// ── VERDICT. The repro asserts its own claims so a green run means something.
const checks = [
  ['BEFORE threw a raw Playwright TimeoutError, not a MeasureError',
    before.threw && before.constructor === 'TimeoutError' && !before.instanceof_MeasureError],
  ['BEFORE took the full auto-wait (>= 9s)', before.threw && before.ms >= 9000],
  ['AFTER (vanish) threw its OWN MeasureError', afterVanish.threw && afterVanish.instanceof_MeasureError],
  ['AFTER (vanish) failed FAST (< 4s), not after a 10s auto-wait', afterVanish.threw && afterVanish.ms < 4000],
  ['AFTER (follow) REACHED the state (no throw, reached:true)',
    !afterFollow.threw && afterFollow.result?.reached === true],
  ['AFTER (fatal:false) RETURNED a named skip object, never threw',
    !afterNonFatal.threw && afterNonFatal.result?.reached === false && !!afterNonFatal.result?.skip_reason],
];

console.log('\n── VERDICT');
let ok = true;
for (const [name, pass] of checks) {
  console.log(`   ${pass ? 'PASS' : 'FAIL'}  ${name}`);
  if (!pass) ok = false;
}
console.log(`\n${ok ? 'REPRO GREEN — D178 fix holds.' : 'REPRO RED — a claim did not hold.'}`);
process.exit(ok ? 0 : 1);
