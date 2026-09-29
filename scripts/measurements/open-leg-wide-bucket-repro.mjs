#!/usr/bin/env node
// open-leg-wide-bucket-repro.mjs — THE FORCING REPRO for charter D184's 1440
// wide-bucket open-leg no-op. NOT a gate, NOT part of a sweep.
//
// IT IS NOT D178's CASE, and that is the point. `open-leg-repro.mjs` (next to
// this file) forces the Tier-3 RENAME: the control the loop holds stops
// matching, and the fix is to re-resolve both spellings every iteration. Here
// the control is present, matching and clicked all three times — the desk
// simply does not come back. The two reproductions share a directory and
// nothing else.
//
// WHAT IT RENDERS. A wide-bucket desk in its served default: `sidebar_open`
// true, `sidebar_user_opened` false, the aside painted at 300px against the
// right edge of a 1440 viewport. The toggle runs
// `Handlers.Paper.sidebar_toggle_panel/1` (studio_live/handlers/paper.ex:198-206)
// line for line, so click 1 collapses the rail to the 41px strip exactly as the
// deployed desk does. Clicks 2 and 3 are then SWALLOWED: the collapse re-render
// swaps the button node under the pointer, so the click reaches a node with no
// handler bound and the LiveView server never sees the event. Modelled here
// with a counter, because a real re-render window is a race and a repro that
// only sometimes reproduces is not one.
//
// WHY THAT IS THE ONLY SHAPE THAT FITS THE ARTEFACT. Enumerate the handler over
// its four entry states: `sidebar_user_opened` is assigned the SAME value as
// `sidebar_open` on every pass, and at the wide bucket the branch is a pure
// alternator, so the marker lands within TWO clicks from every one of them.
// There is no state in which a collapsed rail refuses to re-open. A three-click
// failure therefore requires clicks that never reached the handler.
//
// It proves both sides against the same fixture:
//   BEFORE — the blind budget (three clicks, only `after.user_opened` read):
//            the run dies with the artefact's terminal reading.
//   AFTER  — the shipped `openInspectorByRealClick`, which counts LANDED clicks
//            and gives no-transition clicks their own bounded allowance.
//
// Run:  node scripts/measurements/open-leg-wide-bucket-repro.mjs
// Needs the same playwright the instrument uses (chromium via resolvePlaywright).

import { resolvePlaywright, openInspectorByRealClick } from '../studio-desk-measure.mjs';

const { pw, version } = resolvePlaywright();

function fixture({ swallowAfterCollapse }) {
  return `<!doctype html><html data-width-bucket="wide"><head><style>
    * { box-sizing: border-box; }
    body { margin: 0; display: flex; }
    .bp-doc-sidebar { margin-left: auto; width: 41px; background: #eee; }
    .bp-doc-sidebar.is-open { width: 300px; }
    .bp-doc-sidebar__title { display: none; }
    .bp-doc-sidebar.is-open .bp-doc-sidebar__title { display: block; }
  </style></head><body>
    <div data-phx-main class="phx-connected"></div>
    <main style="flex:1"></main>
    <aside id="bp-doc-sidebar" class="bp-doc-sidebar is-open">
      <div class="bp-doc-sidebar__head">
        <button type="button" id="bp-doc-sidebar-toggle" data-test-id="sidebar-toggle-panel">t</button>
      </div>
      <span class="bp-doc-sidebar__title">Document</span>
    </aside>
    <script>
      // The server assigns, not the DOM: sidebar_open / sidebar_user_opened.
      window.__assigns = { open: true, asked: false, bucket: 'wide' };
      window.__swallowsLeft = 0;
      window.__armed = false;
      window.__log = [];
      document.getElementById('bp-doc-sidebar-toggle').addEventListener('click', function () {
        if (window.__swallowsLeft > 0) {
          // The re-render swapped this node under the pointer: the click landed
          // on the page and reached no handler. Nothing changes — which is
          // precisely why the DOM after it is byte-identical.
          window.__swallowsLeft--;
          window.__log.push('swallowed');
          return;
        }
        var a = window.__assigns;
        var wide = a.bucket === null || a.bucket === 'wide';
        var painted_closed = a.open && !a.asked && !wide;
        var next_open = painted_closed ? true : !a.open;
        a.open = next_open; a.asked = next_open;
        window.__log.push(next_open ? 'opened' : 'collapsed');
        var sb = document.querySelector('.bp-doc-sidebar');
        sb.classList.toggle('is-open', next_open);
        if (next_open) sb.setAttribute('data-user-opened', '');
        else sb.removeAttribute('data-user-opened');
        if (!next_open && !window.__armed) {
          window.__armed = true;
          window.__swallowsLeft = ${swallowAfterCollapse};
        }
      });
    </script>
  </body></html>`;
}

const observe = (page) => page.evaluate(() => {
  const sb = document.querySelector('.bp-doc-sidebar');
  const cs = getComputedStyle(sb);
  const r = sb.getBoundingClientRect();
  return {
    user_opened: sb.hasAttribute('data-user-opened'),
    is_open_class: sb.classList.contains('is-open'),
    left_px: Math.round(r.left * 100) / 100,
    width_px: Math.round(r.width * 100) / 100,
    bucket: document.documentElement.getAttribute('data-width-bucket'),
  };
});

/** The blind budget that shipped before this fix: three clicks, one field read. */
async function blindBudgetOpenLeg(page, { maxClicks = 3 } = {}) {
  const seen = [];
  for (let i = 1; i <= maxClicks; i++) {
    await page.locator('[data-test-id="sidebar-toggle-panel"]').first().click({ timeout: 10_000 });
    await page.waitForTimeout(150);
    const after = await observe(page);
    seen.push({ click: i, after });
    if (after.user_opened) return { reached: true, clicks_needed: i, click_log: seen };
  }
  return { reached: false, click_log: seen };
}

async function drive(label, fn, swallowAfterCollapse) {
  const browser = await pw.chromium.launch();
  const page = await browser.newPage();
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.setContent(fixture({ swallowAfterCollapse }));
  const before = await observe(page);
  const t0 = Date.now();
  let out;
  try {
    out = { threw: false, result: await fn(page) };
  } catch (e) {
    out = { threw: true, error: `${e?.constructor?.name}: ${String(e?.message).split('\n')[0]}` };
  }
  const serverLog = await page.evaluate(() => window.__log);
  await browser.close();

  console.log(`\n=== ${label} (swallow ${swallowAfterCollapse} click(s) after the collapse) ===`);
  console.log(`  ms: ${Date.now() - t0}`);
  console.log(`  before:            ${JSON.stringify(before)}`);
  for (const c of out.result?.click_log ?? []) {
    console.log(`  click ${c.click}${c.outcome ? ` [${c.outcome}]` : ''}: ${JSON.stringify(c.after)}`);
  }
  if (out.threw) console.log(`  THREW: ${out.error}`);
  else {
    console.log(`  reached: ${out.result.reached}` +
      (out.result.reached ? `  clicks_needed=${out.result.clicks_needed}` +
        (out.result.clicks_landed !== undefined
          ? `  landed=${out.result.clicks_landed} swallowed=${out.result.clicks_swallowed}` : '')
        : ''));
    if (out.result.skip_reason) console.log(`  SKIP: ${out.result.skip_reason}`);
  }
  console.log(`  what the "server" saw: ${JSON.stringify(serverLog)}`);
  return out;
}

console.log(`playwright ${version} — chromium, viewport 1440x900, wide bucket`);

// 1. The control. No swallowing: the handler alone reaches the marker in two
//    clicks, so the collapse is NOT the defect.
await drive('CONTROL — faithful handler, nothing swallowed', (p) =>
  openInspectorByRealClick(p, { fatal: false }), 0);

// 2. The artefact's case under the OLD blind budget.
await drive('BEFORE — blind three-click budget', (p) =>
  blindBudgetOpenLeg(p), 2);

// 3. The same fixture under the shipped fix.
await drive('AFTER — landed-click budget + bounded swallow allowance', (p) =>
  openInspectorByRealClick(p, { fatal: false }), 2);

// 4. Past the allowance: the fix must still STOP, and say which world it is in.
await drive('AFTER — swallowing past the bounded allowance', (p) =>
  openInspectorByRealClick(p, { fatal: false }), 99);
